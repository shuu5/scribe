#!/usr/bin/env bash
# scribe-resume-fetch.sh — /scribe:resume の機械層 fetch engine（bd sc-8eyw・resume cycle core の scribe 層 hoist）
#
# 役割（機械=fetch / LLM=judgment）: admin respawn / compaction 後の resume 時に、judgment に必要な生データ
#   （DATA）を **read-only** で fetch し、行頭 marker 付きの構造化ブロックとして stdout へ emit する。
#   judgment（brief 生成・推奨・consumed 化の実行）は skill（skills/resume/SKILL.md）が担う。
#
# 本 script が担う **generic core 4 項目のみ**（bd sc-8eyw 設計cut②。以下の 4 つ以外は担わない）:
#   (1) WM主張↔bd現在値 diff : current sid の Working Memory「命令・制約」節が言及する bead の主張 status を、
#                              自台帳の bd 現在 status と突合し乖離を surface（等価化で消失＝非空虚）。
#   (2) orphan WM surface     : working-memory.<sid>.md（exact・以降 suffix 無し）∧ sid≠current の未 consumed WM を
#                              loud surface（別 session 残置）。**consumed sibling の有無は条件にしない**（後述 ★）。
#   (3) auto-compact 強制回復 mode 切替判定 : marker の有無で MODE を normal / force-recovery に切替える **判定だけ**
#                              （marker の write / PostCompact hook 新設は本 script の scope 外）。
#   (4) consumed 化対象の特定 : current sid の WM file の found/missing を surface する（read-only）。
#                              consume（.md → .consumed.md の mv）自体は skill の責務＝本 script は一切 write しない。
#
# **hoist しないもの（層の fence・bd sc-8eyw notes F3）**: STALE compose / clean-state-probe GREEN gate /
#   gate-pending 列挙 は orchestrator overlay ゆえ本 core は持たない（欲しい層が自分で compose する）。
#   BD-COUNT は open/in_progress/blocked のみ（generic）＝gate-pending count は overlay ゆえ含めない。
#   本 core は scriptorium 側 script を path 参照しない（越境しない＝別 repo の deploy に依存しない）。
#
# ★ orphan 規則（bd sc-8eyw acceptance(3)・参照実装のバグ修正を含む）:
#   consume は **mv(rename)** ゆえ、plain `working-memory.<sid>.md` の存在それ自体が「未 consume の内容が在る」
#   ことを意味する。よって `.consumed.md` sibling の存在は orphan 判定の材料にならない（sibling が在るのは
#   「過去に 1 度 consume した」痕跡に過ぎず、その後 **再** 外部化された新しい .md を silent mask してはならない）。
#   参照実装（scriptorium/scripts/orch-resume-fetch.sh:479）は `[ -f …consumed.md ] && continue` で
#   この再外部化 WM を握り潰していた。本 core は **sibling 条件を削除**して是正する（＝本 core が canonical）。
#   非 orphan として除外するのは次の 3 つだけ: current sid の WM（consume 対象＝orphan でない）/ `.consumed.md`
#   それ自体（mid が `.consumed` で終わる）/ 非標準 suffix（`.md` でない＝glob に不一致）。
#
# read-only（write-isolation）: bd は list/show のみ（--json）、WM は file read のみ。**本 script は一切 write しない**。
#   fetch 母集団は walk-up で解決した自台帳 prefix に限定する（連結 substrate hydrate の foreign copy を混ぜない）。
#
# 前提（別途 enable が要る・bd sc-8eyw notes F7）: WM の path 解決・2 節 schema の SSOT は **cc-session
#   (session plugin) の lib**（session-env.sh / working-memory.sh）。cc-session は project 同居ではなく
#   **user-scope で enable** する plugin ゆえ、本 script を使う前に enable されている必要がある。lib 不在は
#   **fail-loud（exit 1）**＝silent skip で「異常なし」を騙らない。lib が「在るが記号が無い」版ずれも同様に
#   fail-loud（存在チェックだけでは版ずれを取り逃し「乖離なし」を騙るため・後述の記号 gate）。
#
# **fail-loud 経路の一覧（すべて exit 1・対称であること自体が契約）**: ①共有 lib(mailbox-common.sh) 不在
#   ②anchor 未解決 ③anchor 直下の .beads/metadata.json 不在 / dolt_database 未確定（祖先の別台帳へ束ねない）
#   ④cc-session lib 不在 ⑤同 lib の記号（extract_effort_directives）不在＝版ずれ ⑥**bd read 失敗**
#   （bd 不在 / 非 0 終了 / timeout / JSON parse 不能） ⑦**JSON parser（jq / python3）が双方不在**
#   ⑧**WM / WM dir が「在るが読めない」**（所有権・権限ずれ）。いずれも「識別/取得できなかった」を
#   「異常なし（乖離なし・BD-COUNT=0）」に化けさせないための死に方＝黙って degrade しない。
#   ⑥ で空台帳を巻き込まないこと: `bd list --limit 0 --json` は空台帳でも rc=0 + `[]` を返す（実測）ので、
#   判定は「出力の空虚さ」でなく **rc と JSON 形状**で行う（`[]` は正当な空＝成功扱い）。
#
# **「WM を突合していない」を「乖離なし」と呼ばない（[DIFF-UNKNOWN] / [WM-CANDIDATE]）**: WM file は
#   `working-memory.<sid>.md` と **sid で scope** される（cc-session un-gcu）。`/clear` は session_id を変え
#   （cc-session compaction-memory-model.md が verified と明記）、respawn は新プロセスゆえ a fortiori で新 sid。
#   よって「前 session が退避した WM は在るのに current sid では exact 一致しない」は **例外でなく既定経路**
#   （cc-session 自身 session-start-clear.sh:44-63 が非 consumed WM の mtime 降順列挙でこれを拾っている）。
#   ここで WM_CLAIMS="" のまま `[DIFF-NONE] 乖離なし` を emit すると、実在する乖離を **boot path で積極的に
#   否認**する（本 header が ①〜⑧ で名指し禁止している当の欺瞞）。したがって:
#     - current sid の WM が無いときは `[DIFF-NONE]` を **emit しない** → `[DIFF-UNKNOWN]`（突合していない）。
#     - 未 consumed の WM を `[WM-CANDIDATE]`（mtime 降順・最新が先頭）として復元候補に surface する。
#   採用（どれを読むか / consume するか）は判断ゆえ skill 層に委ねる＝fetch は read-only のまま。
#   `[ORPHAN-WM]` と母集団は重なるが役割が違う（orphan=残置の hygiene 警告 / candidate=復元源の提示）。
#   cc-session の規律に倣い原因は断定しない（「sid が変わった自 session」か「別 session の残置」かは区別不能）。
#
# 環境変数（seam・すべて上書き可・bats を hermetic に保つ）:
#   SCRIBE_RESUME_ANCHOR   resume 対象 repo root（既定: cwd から walk-up で最初に見つかる `.beads/` を持つ dir）。
#                          bd read と WM dir はここへ pin する（cwd 依存の誤読・台帳不在の false 空を封じる）。
#   SCRIBE_RESUME_WM_DIR   Working Memory dir（既定: <ANCHOR>/.claude-session ＝ anchor 配下へ pin）。
#   SCRIBE_RESUME_SID      current session id（既定: WM_SESSION_ID > CLAUDE_CODE_SESSION_ID > stdin JSON .session_id）。
#   SCRIBE_RESUME_BD       bd 実体（既定: PATH 上の bd）。read-only（list --json のみ）。read 失敗は fail-loud。
#   SCRIBE_RESUME_BD_TIMEOUT  bd 1 呼出の timeout 秒（既定 20）。dolt lock 競合での無期限 hang を防ぐ。
#   SCRIBE_RESUME_AUTOCOMPACT_MARKER  auto-compact 発火 marker の path（既定: <WM_DIR>/.auto-compacted）。存在→force-recovery。
#   SCRIBE_RESUME_SESSION_LIB  cc-session lib dir（既定: ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/session/scripts/lib）。
#                          CLAUDE_CONFIG_DIR を見るのは scribe が --account で config dir を切替えるため（F7）。
#
# 検証: tests/scribe-resume-fetch.bats（hermetic・3 陽性 modality〔diff / orphan / force-recovery〕+ mutation 非空虚 +
#   SELF_PREFIX walk-up の 2 台帳実測 + CLAUDE_CONFIG_DIR override + fail-loud 経路）。

set -uo pipefail

# ── SELF_DIR（script 実体の dir・symlink 解決） ───────────────────────────────
_scribe_resume_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd "$(dirname "$_scribe_resume_real")" 2>/dev/null && pwd || printf '%s' "$(dirname "$_scribe_resume_real")")"

# ── scribe 既存 walk-up primitive を source（台帳解決の単一 SSOT・再実装しない） ──
# mbx_resolve_ledger_root（cwd→上方向で最初の `.beads/` を持つ dir）/ mbx_resolve_self_db（同 walk-up で
# `.beads/metadata.json` の dolt_database）を提供する。BASH_SOURCE 相対で実 lib を解決するので bats が
# seam override しても実 lib を確実に見つける。
_SCRIBE_MAILBOX_LIB="$SELF_DIR/hooks/lib/mailbox-common.sh"
if [ -r "$_SCRIBE_MAILBOX_LIB" ]; then
    # shellcheck source=hooks/lib/mailbox-common.sh
    . "$_SCRIBE_MAILBOX_LIB"
fi
if ! command -v mbx_resolve_self_db >/dev/null 2>&1; then
    echo "[scribe-resume-fetch] FATAL: 台帳 resolver（mbx_resolve_self_db）不在＝共有 lib（$_SCRIBE_MAILBOX_LIB）を解決できず自台帳を識別できない → fail-closed で実行しない" >&2
    exit 1
fi

# ── anchor 解決（resume 対象 repo root・env override 最優先） ─────────────────
ANCHOR="${SCRIBE_RESUME_ANCHOR:-$(mbx_resolve_ledger_root "$PWD" 2>/dev/null || true)}"
if [ -z "$ANCHOR" ] || [ ! -d "$ANCHOR" ]; then
    echo "[scribe-resume-fetch] FATAL: resume 対象 anchor（.beads/ を持つ repo root）を cwd='$PWD' から walk-up で解決できない → 実行しない（SCRIBE_RESUME_ANCHOR で明示指定可）" >&2
    exit 1
fi

# ── 自台帳 prefix（SELF_PREFIX）の per-project 動的解決 ───────────────────────
# **hardcode しない**（bd sc-8eyw notes F4）: 定数にすると (a) 他 project で silent no-op（prefix 不一致ゆえ
# WM 言及 bead を 1 件も拾わず「乖離なし」と騙る）か (b) 他台帳の bead を自台帳と誤集計する。よって
# anchor の `.beads/metadata.json` を walk-up して dolt_database を実解決し、fetch 母集団をその戻り値へ束ねる。
#
# **旧 self-scope gate の意味の再定義（F4）**: 参照実装（orchestrator 専用の道具）は「cwd の台帳 == 自台帳定数」
# を満たさない foreign session での誤実行を弾く gate を持っていた。本 core は per-project generic ゆえ SELF_PREFIX
# 自体を cwd/anchor から導出する＝`cwd_db == SELF_PREFIX` は **恒真**になり gate として無意味（「安全弁あり」と
# 報告したら false safety）。したがって恒真 gate は **撤去**し、その teeth を次へ移す:
#   walk-up で dolt_database を確定できないとき（.beads/metadata.json 不在・読取/parse 失敗・キー欠落・空値）は
#   **fail-loud（exit 1）**。空 prefix のまま続行すれば全 bead が母集団から漏れて「乖離なし」を騙るため、
#   識別不能は silent no-op でなく loud death にする（これが本 core の fail-closed 点）。
#
# **anchor 直下へ pin する（祖先の別台帳へ束ねない・F4）**: `mbx_resolve_self_db` は metadata.json を持たない
# `.beads/` を素通りして **祖先へ walk-up し続ける**（mailbox-common.sh の仕様）。一方 anchor は
# `mbx_resolve_ledger_root` が「最初の `.beads/`」で止めて決めている。この非対称を放置すると
# 「`.beads/` は在るが metadata.json が無い」anchor で **祖先の別台帳の dolt_database** が SELF_PREFIX になり、
# F4 が名指しで禁じた他台帳誤集計（＝母集団外へ落ちた自 bead が「乖離なし」に化ける）が起きる。
# anchor 決定で walk-up は済んでいるので、self_db の再 walk-up は不要＝anchor 直下の実在を先に強制する。
if [ ! -f "$ANCHOR/.beads/metadata.json" ]; then
    echo "[scribe-resume-fetch] FATAL: anchor='$ANCHOR' 直下に .beads/metadata.json が無い＝台帳識別子（dolt_database）を確定できない → 実行しない（祖先の別台帳へ束ねると他台帳を自台帳と誤集計し『乖離なし』を騙るため fail-loud）" >&2
    exit 1
fi
SELF_PREFIX="$(mbx_resolve_self_db "$ANCHOR" 2>/dev/null || true)"
if [ -z "$SELF_PREFIX" ]; then
    echo "[scribe-resume-fetch] FATAL: anchor='$ANCHOR' の台帳識別子（.beads/metadata.json の dolt_database）を walk-up で確定できない＝fetch 母集団を束ねられない → 実行しない（空 prefix で続行すると全 bead を取り漏らし『乖離なし』を騙るため fail-loud）" >&2
    exit 1
fi

BD="${SCRIBE_RESUME_BD:-bd}"

# ── JSON parser 要件（jq → python3 の 2 段のみ・双方不在は fail-loud） ───────
# **粗 grep の 3 段目を持たない**: 以前は `grep -oE '"(id|status)":"…"' | paste - -` を degraded fallback として
# 出荷していたが、`paste - -` は **TAB** 区切りで出すのに受け手が `IFS=' '`（空白のみ）で read するため
# id 側に `sc-aaa\tclosed` が丸ごと入り status は空になる（実測）。結果 (a) 実 id の lookup が全て空振り＝
# **全 bead が `bd=未検出` の捏造 DRIFT**、(b) `_count_status` がどの status とも一致せず **BD-COUNT 全 0**。
# しかも lines は非空（TAB 連結ゴミ）ゆえ _parse_or_die は parse 成功と判定し FATAL を出さない＝
# 本 header が ①〜⑧ で名指し禁止している欺瞞（「読めなかった」を「異常なし」に化けさせる）が
# **fail-loud 網の外側で成立**していた。加えて粗 grep は id→status の隣接を仮定するため、直せたとしても
# key 順が違う bd 出力で誤対応する残存リスクがある（＝JSON を正規に parse していない）。
# よって「壊れた degraded mode を黙って使う」より「parser が無いことを loud に言う」を選ぶ（fail-closed）。
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
    # marker literal を診断文に埋め込まない（消費側の行頭 marker 判定に偽陽性を作らないため・下の WM dir gate 参照）。
    echo "[scribe-resume-fetch] FATAL: JSON parser（jq / python3）が双方とも不在＝bd の --json 出力を確定的に parse できない → 実行しない（粗 grep で近似すると全 bead を『bd に存在しない』扱いの捏造乖離にし、bd の件数を全て 0 と騙るため fail-loud。jq か python3 を入れよ）" >&2
    exit 1
fi

# ── session id 解決（env override 優先・stdin JSON .session_id は hook 経路の fallback） ──
_stdin_session_id() {
    # tty（対話起動）なら stdin JSON は無い。piped stdin（SessionStart hook）のみ .session_id を試みる。
    [ -t 0 ] && return 0
    local json sid
    json="$(cat 2>/dev/null)" || return 0
    [ -n "$json" ] || return 0
    sid="$(printf '%s' "$json" | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/' | head -n1)"
    printf '%s' "$sid"
}
SID="${SCRIBE_RESUME_SID:-${WM_SESSION_ID:-${CLAUDE_CODE_SESSION_ID:-}}}"
[ -z "$SID" ] && SID="$(_stdin_session_id)"
# slug 化（session-env.sh と同型・[A-Za-z0-9-] のみ・path traversal 不能・64 文字上限）。
SID="${SID//[^A-Za-z0-9-]/}"
SID="${SID:0:64}"

# ── WM を anchor 配下へ pin してから cc-session lib を source（cwd 依存の誤読を封じる） ──
# WORKING_MEMORY_DIR / WM_SESSION_ID を先に export → session-env.sh が scoped file 名を導出する。
export WORKING_MEMORY_DIR="${SCRIBE_RESUME_WM_DIR:-$ANCHOR/.claude-session}"
export WM_SESSION_ID="$SID"
# **ambient を叩き落としてから source する（seam 貫通の封じ・必須）**: session-env.sh は
# `WORKING_MEMORY_FILE="${WORKING_MEMORY_FILE:-$_wm_default_file}"` と **ambient 優先** で解決する。
# 対になる /session:ready-compaction は同じ lib を Bash tool 上で source して同 3 変数を export するため、
# 同一 session の shell に値が残っていると **pin した ANCHOR / WM_DIR / SID より ambient が勝つ**——
# [ANCHOR] と orphan scan は anchor のまま、[WM] と [CONSUME-TARGET] だけ foreign repo を指す split-brain になり、
# SKILL.md §4 の「[CONSUME-TARGET] を verbatim mv せよ」に従うと **別 repo の WM を mv する誤 write** に直結する
# （read-only な fetch が誤 write を教唆する形）。unset して必ず pin 値から lib に導出させる。
unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE
SESSION_LIB="${SCRIBE_RESUME_SESSION_LIB:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/session/scripts/lib}"
if [ ! -r "$SESSION_LIB/session-env.sh" ] || [ ! -r "$SESSION_LIB/working-memory.sh" ]; then
    echo "[scribe-resume-fetch] FATAL: cc-session lib 不在（$SESSION_LIB/{session-env,working-memory}.sh）＝WM path/節抽出の SSOT を解決できない。cc-session(session plugin) は user-scope enable が前提（silent skip しない・SCRIBE_RESUME_SESSION_LIB で override 可）" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$SESSION_LIB/session-env.sh"
# shellcheck source=/dev/null
. "$SESSION_LIB/working-memory.sh"
# session-env.sh は既定を $PWD/.claude-session にするが、上で WORKING_MEMORY_DIR を export 済みゆえ anchor 配下に pin される。

# ── lib は「在る」だけでなく「使う記号を持つ」ことまで検証する（版ずれの fail-loud 化） ──
# 上の存在チェックは `-r` による **ファイル可読性** しか見ない。cc-session は user-scope で **独立に版管理**
# される外部 plugin ゆえ、file は在るが関数が rename/移設された版とは容易にすれ違う。`set -e` は使っていないので
# その場合 `extract_effort_directives` は rc 127 で空文字を返して素通りし、DIFF 節が「主張が無い」と解釈して
# **[DIFF-NONE] 乖離なし** を名乗る（＝「乖離なし」と「WM を読めなかった」が区別できない）。
# 自前の共有 lib には既に `command -v mbx_resolve_self_db` の記号検証を課しているので、より版ずれしやすい
# 外部 lib にこそ同じ teeth を課す（防御の非対称を解消する）。
for _f in extract_effort_directives; do
    command -v "$_f" >/dev/null 2>&1 || {
        echo "[scribe-resume-fetch] FATAL: cc-session lib の API（$_f）が $SESSION_LIB に無い＝版ずれ（file は在るが記号が無い）。WM「命令・制約」節を抽出できず『乖離なし』を騙るため実行しない（cc-session を更新/再 enable せよ）" >&2
        exit 1
    }
done
if [ -z "${WORKING_MEMORY_FILE:-}" ] || [ -z "${WORKING_MEMORY_CONSUMED_FILE:-}" ]; then
    echo "[scribe-resume-fetch] FATAL: cc-session lib が WORKING_MEMORY_FILE / WORKING_MEMORY_CONSUMED_FILE を定義しない＝WM path の SSOT を解決できない（版ずれ）→ 実行しない" >&2
    exit 1
fi

AUTOCOMPACT_MARKER="${SCRIBE_RESUME_AUTOCOMPACT_MARKER:-$WORKING_MEMORY_DIR/.auto-compacted}"

# ── WM dir は「在る」だけでなく「読める・辿れる」ことまで検証する（fail-loud ⑧・file 側 gate との対称化） ──
# **dir の可読性を見ないと orphan scan と WM 検出が同時に silent な偽全クリアを出す**（実測 2 variant）:
#   (a) dir が `000`（r も x も無い）: glob `working-memory.*.md` が展開されず全件 skip → `[ORPHAN-NONE]` を
#       rc=0 で権威値として emit。同時に `[ -f "$WORKING_MEMORY_FILE" ]` も stat 不能で false になるため、
#       WM 側に張った `[ ! -r ]` の FATAL（fail-loud ⑧）へ **到達しない** → `[WM] missing` 扱い。
#       disk 上に drift する WM と orphan が両方在るのに **完全な偽の全クリア**。
#   (b) dir が `111`（search-only）: `[WM] found` と `[DIFF-DRIFT]` は正しく出るのに `[ORPHAN-NONE]` だけ嘘になる。
#       他の marker が健全に見えるため誰も異常を疑わない＝(a) より発見困難。
# fail-loud ⑧ を file にだけ張って dir に張り忘れていた（その rationale が挙げた動機＝「別 uid 由来の
# .claude-session」はまさに **dir** の所有権ずれで、本 repo の host/container 分業では container root が
# mount 先へ `.claude-session` を作る経路が現実にある）。resume は boot path ゆえ他経路と対称に死ぬ。
# dir が **存在しない**のは正当（新規 project / 退避未実施）＝ここでは死なない（missing と unreadable を弁別する）。
if [ -d "$WORKING_MEMORY_DIR" ] && { [ ! -r "$WORKING_MEMORY_DIR" ] || [ ! -x "$WORKING_MEMORY_DIR" ]; }; then
    # **FATAL 文に marker literal を書かない**: 消費側（skill / bats / 運用の grep）は行頭 marker で判定するため、
    # 診断文へ marker を verbatim 埋め込むと「死んだのに marker が在る」偽陽性を作る（自分で嘘を撒く）。
    echo "[scribe-resume-fetch] FATAL: WM dir は在るが読めない/辿れない（$WORKING_MEMORY_DIR）＝WM の実在も orphan の有無も確定できない → 実行しない（『WM なし・orphan なし・乖離なし』を名乗ると偽の全クリアになるため。権限/所有者を直してから再実行せよ）" >&2
    exit 1
fi

# ── bd fetch helper（read-only・自台帳に限定・anchor へ pin） ────────────────
# WM 読取と同じ『cwd 非依存』原則を bd 読取にも適用する: worktree（`.beads/embeddeddolt` が gitignore で不在）を
# cwd に起動されると bd が台帳不在で空/foreign を返し、WM 言及 bead が false『bd=未検出』DRIFT になる。
# subshell で anchor へ cd してから叩く。
#
# **bd read 失敗は fail-loud（header ①〜⑧ と対称・最重要）**: 以前はここで rc も stderr も捨てていたため、
# bd 不在 / dolt lock 競合 / 台帳破損 / 壊れた JSON のいずれでも空 map のまま rc=0 で続行し、
# `[BD-COUNT] open=0 …` と `[DIFF-NONE] 乖離なし`（あるいは全 bead の false『bd=未検出』DRIFT）を
# **権威値として** emit していた。これは本 header が「空 prefix で続行すると全 bead を取り漏らし
# 『乖離なし』を騙るため fail-loud」と宣言して exit 1 させている当の欺瞞そのもので、
# 「prefix 解決不能は loud death / 実行時に最も起きやすい bd read 失敗は silent degrade」という非対称だった。
# resume は admin respawn の第一手（boot path）＝この DATA が brief の一次判断根拠になるため、
# 「読めなかった」を「異常なし」に化けさせない。空台帳の正当な `[]`（rc=0）とは rc で区別する（後述）。
# dolt lock 競合での無期限 hang を避けるため mailbox-common.sh の既存 idiom に倣い timeout で包む。
BD_TIMEOUT_SECS="${SCRIBE_RESUME_BD_TIMEOUT:-20}"
#
# **データチャネル(stdout)と診断チャネル(stderr)を分離する（`2>&1` で畳み込まない）**: bd は rc=0・正当 JSON の
# まま stderr へ **良性 warning** を出す（bd 1.1.0 実測: `warning: beads.role not configured (GH#2950)` /
# `Warning: <path>/.beads has permissions 0775 (recommended: 0700)`）。stderr を stdout へ merge すると
# out が `warning: …\n[{…}]` になり、**rc=0 ゆえ rc gate を素通りして** _parse_or_die の jq が先頭 warning で
# 落ちる → 台帳も bd も健全なのに「JSON を parse できない＝台帳が壊れている」と誤診して resume が死ぬ
# （boot path の brick かつ診断が admin を存在しない台帳破損の修理へ誤誘導する）。しかも該当条件は
# `git config beads.role` 未設定 / `.beads` が 0700 でない＝**新規 project の既定状態**（/scribe:setup も
# どちらも設定しない）ゆえ、本 core が狙う「全 scribe project で使える generic core」が既定構成で不成立になる。
# header が「判定は『出力の空虚さ』でなく **rc と JSON 形状**で行う」と契約している以上、payload に診断を
# 混ぜてはならない。stderr は **rc≠0 のときの FATAL 要旨用にだけ** 保持する（原因の surface は維持）。
_bd_json() {
    local out rc err errf
    errf="$(mktemp "${TMPDIR:-/tmp}/scribe-resume-bderr.XXXXXX" 2>/dev/null)" || errf=""
    if [ -z "$errf" ]; then
        echo "[scribe-resume-fetch] FATAL: 一時ファイルを作成できない（bd の stderr を stdout と分離して捕捉するのに必要）→ 実行しない（stderr を JSON へ混ぜると健全な read を parse 不能と誤診するため）" >&2
        exit 1
    fi
    if command -v timeout >/dev/null 2>&1; then
        out="$( ( cd "$ANCHOR" && timeout "$BD_TIMEOUT_SECS" "$BD" "$@" --json ) 2>"$errf" )"; rc=$?
    else
        out="$( ( cd "$ANCHOR" && "$BD" "$@" --json ) 2>"$errf" )"; rc=$?
    fi
    err="$(cat "$errf" 2>/dev/null)"
    rm -f "$errf"
    if [ "$rc" -ne 0 ]; then
        echo "[scribe-resume-fetch] FATAL: bd read 失敗（rc=$rc・anchor=$ANCHOR・args='$*'）＝bd 現在値を取得できない → 実行しない（空 map で続行すると全 bead を取り漏らし『乖離なし / BD-COUNT=0』を騙るため fail-loud）: ${err:-${out:-（出力なし）}}" >&2
        exit 1
    fi
    printf '%s' "$out"
}

# JSON 配列 1 個を "id status" 行へ落とす（parse 不能は FATAL・空配列は正当な空台帳）。
# **空台帳と read 失敗を混同しない**: `bd list --limit 0 --json` は空台帳でも rc=0 + `[]` を返す（実測）ので、
# 判定は「出力の空虚さ」ではなく rc と JSON 形状で行う。`[]` / `null` / 空白のみ → 正当な空（0 行を返す）。
# それ以外で 1 行も取り出せなければ **parse 不能**＝台帳が壊れているか bd の出力仕様が変わった → fail-loud。
_parse_or_die() {
    local json="$1" label="$2" compact lines
    compact="$(printf '%s' "$json" | tr -d '[:space:]')"
    case "$compact" in ''|'[]'|'null') return 0 ;; esac   # 正当な空台帳＝0 行（FATAL でない）
    lines="$(printf '%s' "$json" | _parse_id_status)"
    if [ -z "$lines" ]; then
        echo "[scribe-resume-fetch] FATAL: bd の JSON 出力を parse できない（$label・anchor=$ANCHOR）＝bd 現在値を確定できない → 実行しない（空 map で続行すると『乖離なし / BD-COUNT=0』を騙るため fail-loud）: $(printf '%s' "$json" | head -c 200)" >&2
        exit 1
    fi
    printf '%s\n' "$lines"
}

# stdin(bd --json の **配列 1 個**) → "id status" 行（jq → python3 の 2 段のみ・上の parser gate が双方不在を弾く）。
# 配列は 1 個ずつ渡す（2 個を連結して流すと python3 fallback の json.load が落ちて 0 行を返す＝silent 空）。
_parse_id_status() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[]? | "\(.id) \(.status)"' 2>/dev/null
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for o in (d or []):
    print(o.get("id",""), o.get("status",""))' 2>/dev/null
    else
        # 到達不能（起動時の parser gate が jq/python3 双方不在で既に exit 1 している）。防御的に死ぬだけで、
        # ここで近似 parse に落ちない＝壊れた degraded mode を fail-loud 網の外側に作らない。
        echo "[scribe-resume-fetch] FATAL: JSON parser（jq / python3）不在（parser gate を素通りした＝内部不整合）→ 実行しない" >&2
        exit 1
    fi
}

# 自台帳 id→status map を構築（active = 非 closed + closed を合流）。SELF_PREFIX filter（動的解決値）。
#
# **pipeline を使わない**: `_bd_json | … | while …` の形だと各段が subshell で回るため、_bd_json / _parse_or_die の
# `exit 1`（fail-loud）が **subshell だけを殺して script は rc=0 で続行** してしまう＝fail-loud が無効化される。
# よって bd 出力を先に変数へ取り（command substitution の rc は `|| exit 1` で親へ伝播する）、
# 突合は herestring で回す。副次的に、pipeline 回避のための tmp file + trap も不要になる。
declare -A BD_STATUS
_build_bd_status_map() {
    local active closed parsed id st
    active="$(_bd_json list --limit 0)" || exit 1
    closed="$(_bd_json list --status closed --limit 0)" || exit 1
    parsed="$( { _parse_or_die "$active" "list --limit 0"; _parse_or_die "$closed" "list --status closed --limit 0"; } )" || exit 1
    while IFS=' ' read -r id st; do
        [ -n "$id" ] || continue
        case "$id" in "${SELF_PREFIX}-"*) BD_STATUS["$id"]="$st" ;; esac
    done <<< "$parsed"
}

# ── WM「命令・制約」節の主張 status 正規化 ───────────────────────────────────
# WM 行が bead を「言及」し、かつ同一行に status 語があれば主張 status とみなす。status 語が無ければ「言及のみ」。
_normalize_status() {
    # $1 = 1 行のテキスト。認識した正規 status（in_progress/closed/blocked/open）or 空（status 語なし）を返す。
    # 優先順（部分一致の食い合いを避ける・終端 status を先に判定）: closed → blocked → in_progress → open。
    local line lower; line="$1"; lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in *closed*|*done*|*クローズ*|*完了*) echo closed; return ;; esac
    case "$line"  in *クローズ*|*完了*)                 echo closed; return ;; esac
    case "$lower" in *blocked*|*block*)                 echo blocked; return ;; esac
    case "$line"  in *ブロック*)                        echo blocked; return ;; esac
    case "$lower" in *in_progress*|*in-progress*|*wip*) echo in_progress; return ;; esac
    case "$line"  in *進行中*|*実装中*|*作業中*)         echo in_progress; return ;; esac
    case "$lower" in *open*)                            echo open; return ;; esac
    case "$line"  in *未着手*|*オープン*)               echo open; return ;; esac
    echo ""
}

# ── main: DATA ブロックを emit ────────────────────────────────────────────
_build_bd_status_map

# (3) MODE 判定（auto-compact marker の有無だけを見る＝判定のみ・marker write は scope 外）。
if [ -e "$AUTOCOMPACT_MARKER" ]; then
    RESUME_MODE="force-recovery"
else
    RESUME_MODE="normal"
fi

echo "=== [scribe-resume-fetch] resume DATA (機械層 fetch・bd sc-8eyw・read-only) ==="
echo "[RESUME-MODE] $RESUME_MODE"
if [ "$RESUME_MODE" = "force-recovery" ]; then
    echo "  ⚠ auto-compact 発火 marker 検出（$AUTOCOMPACT_MARKER）＝WM の退避が間に合わなかった疑い。bd の現在値を一次 truth とし、WM 主張より bd を優先して再ブリーフせよ。"
fi
echo "[ANCHOR] $ANCHOR"
echo "[LEDGER] $SELF_PREFIX（.beads/metadata.json dolt_database を walk-up で動的解決）"
if [ -n "$SID" ]; then echo "[SID] $SID"; else echo "[SID] none  ⚠ session id 未解決（legacy 非 scoped WM を参照）"; fi

# ── 復元候補（未 consumed WM の mtime 降順列挙・read-only） ──────────────────
# cc-session の session-start-clear.sh:44-63（`_collect_working_memory`）と同型: 非 consumed の
# `working-memory.*.md` を mtime 降順で返す。最新 1 件でなく全件返すのは、自分の古い pre-clear ファイルが
# 並走 session の新しいファイルの陰に隠れる発見ギャップ（cc-session un-gcu corr-2）を防ぐため。
# subprocess を使わず `-nt` の selection sort で回す（小 n 前提・cc-session と同じ idiom）。
_wm_candidates() {
    [ -d "$WORKING_MEMORY_DIR" ] || return 0
    local files=() f b n i j sel tmp
    shopt -s nullglob
    for f in "$WORKING_MEMORY_DIR"/working-memory.*.md; do
        b="$(basename "$f")"
        case "$b" in *.consumed.md) continue ;; esac   # consume 済み＝復元候補でない
        [ "$b" = "$(basename "$WORKING_MEMORY_FILE")" ] && continue   # current sid（この分岐では不在だが二重防御）
        files+=("$f")
    done
    shopt -u nullglob
    n=${#files[@]}
    [ "$n" -eq 0 ] && return 0
    for ((i = 0; i < n; i++)); do
        sel=$i
        for ((j = i + 1; j < n; j++)); do
            [ "${files[$j]}" -nt "${files[$sel]}" ] && sel=$j
        done
        if [ "$sel" -ne "$i" ]; then tmp="${files[$i]}"; files[$i]="${files[$sel]}"; files[$sel]="$tmp"; fi
    done
    printf '%s\n' "${files[@]}"
}

# ── (4) consumed 化対象の特定（current sid の WM file・read-only＝mv は skill 層） ──
echo ""
echo "── (4) consumed 化対象（current sid の WM・read-only／consume の実行は skill 層） ──"
WM_CAND_N=0
if [ -f "$WORKING_MEMORY_FILE" ]; then
    # **可読性まで見る（`-f` だけでは fail-open）**: extract_effort_directives は内部 awk を握り潰して
    # 「読めなかった」でも空文字 + rc=0 を返すため、`-f` だけを gate にすると WM が在るのに読めない
    # （root が書いた WM / 別 uid 由来の .claude-session 等の所有権ずれ）とき、**[DIFF-NONE] 乖離なし** を
    # 権威値として名乗る＝header が ①〜⑧ で名指し禁止している当の欺瞞そのもの。版ずれ（記号不在→rc127→空文字）
    # には既に teeth を張っている以上、同じ「空文字が返る」variant である不可読も対称に fail-loud させる
    # （dir 側の同型 modality は上の WM dir gate が対称に受け持つ＝file にだけ張る非対称を作らない）。
    if [ ! -r "$WORKING_MEMORY_FILE" ]; then
        echo "[scribe-resume-fetch] FATAL: WM は在るが読めない（$WORKING_MEMORY_FILE）＝WM 主張を抽出できず『乖離なし』を騙るため実行しない（権限/所有者を直してから再実行せよ）" >&2
        exit 1
    fi
    echo "[WM] file=$WORKING_MEMORY_FILE found"
    echo "[CONSUME-TARGET] $WORKING_MEMORY_FILE → $WORKING_MEMORY_CONSUMED_FILE（brief 提示後に skill が mv する）"
    WM_CLAIMS="$(extract_effort_directives "$WORKING_MEMORY_FILE")"
    WM_FOUND=1
else
    echo "[WM] file=$WORKING_MEMORY_FILE missing"
    echo "[CONSUME-NONE] current sid の WM 不在＝consume 対象なし（新規 session / 退避未実施 / **sid が変わった**）"
    WM_CLAIMS=""
    WM_FOUND=0
    # **respawn / `/clear` の既定経路をここで surface する（header 参照）**: WM は sid で scope されるため、
    # 新 sid では前 session の退避物と exact 一致しない＝「WM が在るのに missing と出る」が常態。
    # 復元候補を出さずに黙ると、この後の diff 節が『乖離なし』を名乗って boot path で作業放棄を招く。
    while IFS= read -r _cand; do
        [ -n "$_cand" ] || continue
        WM_CAND_N=$((WM_CAND_N+1))
        echo "[WM-CANDIDATE] $(basename "$_cand")  ← 復元候補（未 consumed・mtime 降順＝先頭が最新）"
        [ "$WM_CAND_N" -eq 1 ] && echo "  ⚠ current sid の WM は不在だがこの WM は未 consumed＝『sid が変わった自 session（respawn / \`/clear\`）の退避物』か『別 session の残置』のいずれか（fetch には **区別できない**）。復元するなら内容を Read し、bd と突合するなら SCRIBE_RESUME_SID=<候補の sid> で再 fetch せよ（採用/consume の判断は skill 層）。"
    done <<< "$(_wm_candidates)"
    [ "$WM_CAND_N" -eq 0 ] && echo "[WM-CANDIDATE-NONE] 復元候補なし（未 consumed の WM が 1 件も無い＝退避物自体が存在しない）"
fi

# ── bd 現在値サマリ（generic count のみ。gate-pending count は overlay ゆえ持たない＝F3） ──
echo ""
echo "── bd 現在値（自台帳 ${SELF_PREFIX}-・read-only） ──"
_count_status() { local want="$1" n=0 id; for id in "${!BD_STATUS[@]}"; do [ "${BD_STATUS[$id]}" = "$want" ] && n=$((n+1)); done; echo "$n"; }
echo "[BD-COUNT] open=$(_count_status open) in_progress=$(_count_status in_progress) blocked=$(_count_status blocked)"

# ── (1) WM主張 ↔ bd現在値 diff ─────────────────────────────────────────────
echo ""
echo "── (1) WM↔bd diff（WM 主張 status vs bd 現在 status・乖離を surface） ──"
_drift_n=0
_seen_ids=""
declare -A WM_CLAIM_OF
#
# **id 抽出には前方の語境界を課す**: `grep -oE "${SELF_PREFIX}-[a-z0-9]+"` は語境界を持たないため、
# SELF_PREFIX がより長いトークンの **末尾** に現れると部分一致して存在しない bead を捏造する
# （実測: SELF_PREFIX=un の台帳で散文 `run-tests` → `un-tests` を拾い `[DIFF-DRIFT] un-tests bd=未検出` を emit）。
# `run-`/`misc-`/`disc-` は工学散文で頻出し、SELF_PREFIX は動的解決ゆえ任意の短い prefix を取り得る＝
# generic core としての正しさの問題。捏造 DRIFT は brief に載って admin に存在しない bead を追わせ、
# SKILL.md §3 の hygiene tripwire（乖離 3 件以上＝運用崩壊の警告）を偽陽性で焚きつける。
_wm_bead_ids() {
    # $1 = 1 行。行内の bead id を「直前が id 構成文字でない」ものだけ拾う（先頭の区切り文字は落とす）。
    printf '%s' "$1" | grep -oE "(^|[^A-Za-z0-9_-])${SELF_PREFIX}-[a-z0-9]+" | sed -E 's/^[^A-Za-z0-9_-]//' | sort -u
}
#
# **status 主張を持つ行を優先する（行順の first-wins にしない）**: dedup の意図は「id ごとに 1 回 report」
# であって「status 主張 < 言及」ではない。素朴な first-wins だと、同一 bead を語る先行の「言及のみ」行が
# id を焼き付け、status 主張を持つ後続行が捨てられて **実在する DRIFT が沈黙し [DIFF-NONE] を名乗る**
# （実測: `- sc-aaa mention only` / `- sc-aaa in_progress keep going` + bd=closed で DRIFT が 1 件も出ない）。
# 「命令・制約」節は同一 bead を方針行 + 状態行の複数行で語るのが自然で、cc-session の carry-forward が
# 項目を機械的に積み増すため行数はサイクルごとに増える＝時間が経つほど踏む。よって 1st pass で
# id→claim を「非空 claim が勝つ / 非空同士は先勝ち」で畳み、2nd pass で id ごとに 1 行 emit する。
if [ -n "$WM_CLAIMS" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        _line_claim="$(_normalize_status "$line")"
        # 1 行に複数 bead id があり得る（全て走査）。
        for bid in $(_wm_bead_ids "$line"); do
            case " $_seen_ids " in *" $bid "*) ;; *) _seen_ids="${_seen_ids:-} $bid" ;; esac
            if [ -n "$_line_claim" ] && [ -z "${WM_CLAIM_OF[$bid]:-}" ]; then
                WM_CLAIM_OF["$bid"]="$_line_claim"
            fi
        done
    done <<< "$WM_CLAIMS"
fi
for bid in $_seen_ids; do
    claim="${WM_CLAIM_OF[$bid]:-}"
    cur="${BD_STATUS[$bid]:-}"
    if [ -z "$claim" ]; then
        echo "[DIFF-MENTION] $bid WM=（status語なし・言及のみ） bd=${cur:-未検出}"
    elif [ -z "$cur" ]; then
        echo "[DIFF-DRIFT] $bid WM=$claim bd=未検出  ⚠乖離（WM が言及する bead が bd 自台帳に無い）"
        _drift_n=$((_drift_n+1))
    elif [ "$claim" != "$cur" ]; then
        echo "[DIFF-DRIFT] $bid WM=$claim bd=$cur  ⚠乖離"
        _drift_n=$((_drift_n+1))
    else
        echo "[DIFF-OK] $bid WM=$claim bd=$cur（一致）"
    fi
done
# **突合していないことを『乖離なし』と呼ばない（header 参照）**: current sid の WM が無い＝WM_CLAIMS が
# 空なのは「一致した」ではなく「**比べていない**」。respawn / `/clear` は sid を変えるため、これは例外でなく
# 既定経路であり、ここで [DIFF-NONE] を出すと実在する乖離を boot path で積極的に否認する（fail-open）。
# fail-loud 群と同じ規律（「読めなかった」を「異常なし」に化けさせない）を、死ぬまでもない本経路では
# **別 marker で識別可能にする**ことで満たす。
if [ "$WM_FOUND" -eq 0 ]; then
    # 案内文にも marker literal を書かない（既存 FATAL 群と同規律）: 候補が 0 件でも本行が
    # 「WM-CANDIDATE」の字面を含むと、行頭 marker を grep する消費側が「候補が在る」と誤読する。
    if [ "$WM_CAND_N" -gt 0 ]; then
        echo "[DIFF-UNKNOWN] 突合していない（current sid の WM 不在＝WM 主張が無い。これは『乖離なし』ではない）  → 上に復元候補 $WM_CAND_N 件（先頭が最新）。SCRIBE_RESUME_SID=<候補の sid> で再 fetch すれば突合できる"
    else
        echo "[DIFF-UNKNOWN] 突合していない（current sid の WM 不在＝WM 主張が無い。これは『乖離なし』ではない）  → 復元候補も無し＝退避物が存在しない（真に新規 session）"
    fi
elif [ "$_drift_n" -eq 0 ]; then
    echo "[DIFF-NONE] 乖離なし（WM 主張と bd 現在値は一致・または WM に status 主張なし）"
else
    echo "[DIFF-COUNT] 乖離=$_drift_n 件"
fi

# ── (2) orphan WM surface ─────────────────────────────────────────────────
# 判定規則（★ header 参照・参照実装の consumed-sibling skip バグを是正済み）: working-memory.<sid>.md（exact）で
# sid≠current なら **無条件に orphan**。consume は mv ゆえ plain .md の存在自体が未 consume 内容の存在を意味し、
# `.consumed.md` sibling の存在は「過去に 1 度 consume した」痕跡に過ぎない（その後の再外部化を mask しない）。
echo ""
echo "── (2) orphan WM（working-memory.<sid>.md・sid≠current＝別 session の未 consumed 残置） ──"
_orphan_n=0
if [ -d "$WORKING_MEMORY_DIR" ]; then
    for f in "$WORKING_MEMORY_DIR"/working-memory.*.md; do
        [ -e "$f" ] || continue
        base="$(basename "$f")"
        mid="${base#working-memory.}"; mid="${mid%.md}"
        # `.consumed.md` それ自体（mid が .consumed で終わる）は consume 済みの痕跡＝orphan でない。
        # 非標準 suffix（`.md` でない）は glob に不一致ゆえ元から対象外（二重防御は不要）。
        case "$mid" in *.consumed) continue ;; esac
        [ -n "$mid" ] || continue                 # legacy working-memory.md は glob に不一致だが二重防御。
        [ "$mid" = "$SID" ] && continue           # current sid の WM は consume 対象＝orphan でない。
        echo "[ORPHAN-WM] $base  ⚠orphan（未 consumed・sid=$mid≠current）"
        _orphan_n=$((_orphan_n+1))
    done
fi
if [ "$_orphan_n" -eq 0 ]; then echo "[ORPHAN-NONE] orphan WM なし"; else echo "[ORPHAN-COUNT] orphan=$_orphan_n 件"; fi

echo ""
echo "=== end resume DATA ==="

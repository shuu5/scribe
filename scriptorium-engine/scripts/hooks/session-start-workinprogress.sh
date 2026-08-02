#!/usr/bin/env bash
# session-start-workinprogress.sh — orchestrator SessionStart で「仕掛かり」を自動表示（bd orch-7py / orch-c8p F）
#
# 役割（orch-c8p grill G3② 採択・doobidoo f4888921）: fresh な orchestrator session の起動時に、
#   仕掛かり中の作業を自動 surface する。respawn 既定化(E)と対になる「fresh orchestrator の仕掛かり
#   自動表示」＝orchestrator が session を建て直すたびに、gate 待ち cell と degraded/suspect cell を
#   手で叩かずとも context へ流し込む。具体的には次の 4 つを **read-only** で自動実行する:
#     (1) gate-pending pull : scripts/orch-dispatch.sh --gate-pending
#         （gate 待ち cell 一覧＝self-dev 直 gate / 外部 repo cell の 2 バケット + foreign 鮮度警告）
#     (2) degraded-watch    : scripts/orch-degraded-watch.sh
#         （spawn cell の構造3核 suspect/salvage＝窓消失した cell の取りこぼしを surface）
#     (3) needs-orch handoff: scripts/orch-handoff-scan.sh --no-freshness
#         （foreign→orchestrator 検知線＝hydrated orch DB の needs-orch ラベル foreign bead を surface・
#           bd orch-jmu / orch-am1 論点6。鮮度警告は第1セクションに委譲するため --no-freshness で呼ぶ＝
#           同一 hook 出力での二重表示を避ける・orch-jmu notes p3）
#     (4) 配送観測          : scripts/orch-delivery-observe.sh（bd orch-4js9・top-spec §1.1:85 / §5.4:246）
#         （各 admin〔宛先 X〕への for:X 便の cycle 境界 proxy / 推論配送 3 値 / 呼び鈴 proposal-only /
#           auto-compact marker read を surface。proxy scope〔heartbeat 非依存で単独成立〕・read-only・fail-open）。
#         ★surface 分担（fence9・doc-only）: 配送観測（mailbox / 便滞留の read-only 監視）は **本 hook** が担い、
#           hygiene tripwire（同期ズレ・仕掛かり整合の点検）は別便 **/scriptorium:orch-rebrief brief**（orch-x1ae・
#           未 land ゆえ forward 参照）が担う。配送観測は §1.2 ① の無条件能動側＝wake（③）ではない（呼び鈴は
#           「提案のみ」で push=wake は人間 go・本 hook は push を発火しない・top-spec §5.4:246「配送観測 ≠ wake」）。
#   Claude Code は SessionStart hook の stdout を session context へ注入する仕様ゆえ、4 script の
#   stdout をそのまま出す（spec-inject / guard-health と同経路・plain stdout）。
#
# self-scope（最重要・spec-inject / guard-health と同型）: 本 hook を plugin として global enable すると
#   SessionStart は **全セッション**で発火する。orchestrator session（cwd から walk-up した最初の
#   .beads/metadata.json の dolt_database が SELF_PREFIX(orch)に完全一致）でのみ発火し、foreign
#   （scribe 'sc' / cc-session 'ccs' …）・判定不能は無出力で exit 0（no-op・誤注入ゼロ）。
#   前方一致 'orchX'(orch2 等)は完全一致比較で弾く。判定機構は bd-write-guard.py(un-mbz)/ spec-inject の
#   walk-up と同一・同一 SELF_PREFIX を共有する。metadata 在るが parse 失敗(present-but-unreadable)は
#   spec-inject と同様 fail-open（無表示・誤注入ゼロ優先）＝本 hook の出力は cosmetic な surface ゆえ moat
#   維持の fail-closed（guard 群）とは別方針で良い（walk-up/SELF_PREFIX 自体は同一）。
#
# cwd 第2軸（anchor だけ発火・orch-1r7 grill G3・SCRIBE_ROLE 非依存・spec-inject と同型）: 上の self-scope
#   （台帳=orch）は「この repo が orchestrator か」を判定するが、orchestrator repo の **worktree**（自己開発
#   worker cell）は台帳 walk-up が anchor の .beads(dolt_database=orch)へ届くため self-scope を通過してしまう。
#   だが worker worktree は scribe worker protocol で動く別 role であり、そこへ「gate 待ち一覧」を注入するのは
#   誤配（worker は自 issue のみ扱い・gate は admin/anchor の責務）。よって self-scope と直交する第2軸として、
#   hook cwd が `.worktrees/` または `.claude/worktrees/`(CC-native worktree)配下なら orch session でも
#   **no-op** する（anchor〔非 worktree〕だけ発火）。この軸は SCRIBE_ROLE 値に依存しない純 cwd 判定。
#
# fail-open（全セッション破壊の防止・acceptance 3）: 判定不能・script 不在・script 内部エラーでもセッションを
#   壊さない。set -e は使わず常に exit 0（degrade）。参照 script（orch-dispatch.sh / orch-degraded-watch.sh）が
#   不在/非実行可能なら skip note を出して continue、存在時は `|| true` で内部エラーを握り潰す（hooks.json の
#   二重 fail-safe 指示と整合）。両 script は read-only（bd/foreign 台帳を mutate しない）ゆえ本 hook 経由の
#   自動実行が write-isolation を侵すことはない。
#
# 表示層 trim（bd sc-v0ao・inline 復帰「上位 N 行 + 全件 pointer」）: 本 hook の stdout はハーネスの UTF-16 cliff
#   （10,000 u16）で truncate され、末尾の節が丸ごと落ちていた（独立再測 13,759 u16）。**データ取得は全件のまま**
#   （子 script の呼出し引数は不変＝截断禁止/全件の既存 teeth を抜かない）で、**表示層だけ**を予算駆動で切り詰める。
#   詳細な設計と定数は下の「表示層 trim」節を参照。`--full` で trim を外した全件を出す（pointer の指す経路）。
#
# plugin 反映（acceptance 5・CLAUDE.md「plugin 反映」節）: 本 hook は plugin として live 化する。反映には
#   **新規 cld session が必須**（`/reload-plugins` は起動引数 replay のみで hooks を再列挙しない）。既存 session
#   では効かない＝新しい orchestrator session を建て直して初めて自動表示が効く。
#
# --self-test（hermetic・fail-closed・orch-7py）: 引数 `--self-test` で自己完結テストを走らせる。temp に
#   fixture plugin root（stub orch-dispatch.sh / orch-degraded-watch.sh が sentinel を echo）と台帳 fixture
#   （orch anchor / orch worktree(.worktrees・.claude/worktrees) / foreign）を作り、各 cwd を stdin JSON で
#   与えて本 script を subprocess 起動し、anchor→両 sentinel 表示 / worktree→no-op / foreign→no-op を assert
#   する。非vacuity: anchor→両 sentinel が出ることが「no-op 群が常時空でない」証明（cwd/台帳 軸が識別している）。
#   加えて stub 削除 mutation で anchor でも sentinel が消え skip note + exit0 になる（fail-open 非vacuous）。
#   assert が 1 つでも落ちれば非 0。
#
# 検証: tests/scenarios/session-start-workinprogress.bats（hermetic E2E）+ 本 file の `--self-test` +
#   selftest-orch-7py.local.sh（worktree 直下・untracked・fail-closed）。

# 自台帳 prefix（.beads/metadata.json dolt_database="orch" / orchestrator CLAUDE.md SSOT）。
# bd-write-guard.py / spec-inject の SELF_PREFIX="orch" と同一値を共有する（session self-scope の台帳判定）。
SELF_PREFIX="orch"

# --- plugin root / 参照 script パス解決（CLAUDE_PLUGIN_ROOT 優先・無ければ script 位置から導出） ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    # scripts/hooks/ の 2 つ上 = plugin root
    PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
DISPATCH="$PLUGIN_ROOT/scripts/orch-dispatch.sh"
DEGRADED="$PLUGIN_ROOT/scripts/orch-degraded-watch.sh"
HANDOFF="$PLUGIN_ROOT/scripts/orch-handoff-scan.sh"
DELIVERY="$PLUGIN_ROOT/scripts/orch-delivery-observe.sh"   # 第4節 配送観測（bd orch-4js9・read-only）
RERATIFY="$PLUGIN_ROOT/scripts/orch-stale-scan.sh"         # 第5節 re-ratify sweep（bd orch-cqf4 Leg-A・PR#147 engine 反映・read-only）
SLATE_SURFACE="$PLUGIN_ROOT/scripts/lib/orch_slate.sh"     # 第5節 open slate surface（bd orch-cqf4 Leg-A・read-only）

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・SSOT = scripts/hooks/lib/orch_session.sh） ---
# _extract_cwd / _json_is_valid / _ledger_dolt_database / _is_orch_session / _is_worktree_cwd を提供する。
# ★実 script 位置（BASH_SOURCE 相対 = $_SCRIPT_DIR）で解決するので、bats / --self-test が CLAUDE_PLUGIN_ROOT を
#   fixture へ向けても実 lib を確実に見つける（fixture 無改変で green を保つ）。_is_orch_session は上で定義した
#   SELF_PREFIX を参照する（lib の SELF_PREFIX 契約）。_json_is_valid の guard parity（破損 orch トークン誤発火防止）
#   や present-but-unreadable の fail-open など意味論は従来の verbatim 定義と同一（lib header 参照）。
# lib 不在は fail-open（無表示・誤注入ゼロ優先＝本 hook の cosmetic 性に合致）で exit 0 する。
_ORCH_SESSION_LIB="$_SCRIPT_DIR/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "[orchestrator/SessionStart] warning: 共有 self-scope lib 不在（$_ORCH_SESSION_LIB）・仕掛かり自動表示を skip（fail-open continue）" >&2
    exit 0
fi

# === 表示層 trim（bd sc-v0ao・inline 復帰: 上位 N 行 + 全件 pointer）===================================
# 設計（正本 orch-db47 leg(2) の依頼形）:
#   - 単位は「件」でなく **行**。固定 N でなく **予算駆動**（残予算 / 残 block 数）+ floor（節 10 行・予算不足時
#     のみ 5 行まで下げる。5 行未満へは落とさない）。
#   - **優先行**（滞留 / 呼び鈴 / 警告 / RED / suspect / salvage / 集計: / TRIPWIRE / 節見出し / fail-open skip
#     note）は N 枠を消費せず **常に全保持**。N 枠は非 actionable な record 行にのみ適用する。
#   - 優先行は **2 rank** に分ける（sc-v0ao review major-1/2）。rank-A = 🔔 呼び鈴 / `集計:` / `[…-RED]` /
#     TRIPWIRE / 警告 ＝ 1 block に数行しか出ないが最も actionable な **総覧・呼び鈴**行。rank-B = `[滞留]` /
#     SUSPECT / SALVAGE のように **大量に出る** record 系優先行。実 producer（配送観測）は便 record 行が全行
#     `[滞留]`＝節が丸ごと優先クラスになり、しかも rank-A（🔔 / `── 集計:`）を **block 末尾**へ置く。優先行を
#     一律 index 順に採ると先頭の record 行だけで節の取り分を食い切り、末尾の rank-A が構造的に必ず落ちる
#     （実測: 🔔 0 件 / 集計 0 件・cap まで ~5,000 u16 余らせたまま）。よって hard-cap は rank-A を **節予算に
#     先立って先取り**する（下の _wip_hc_build pass 0・節あたり上限 $WIP_RANKA_MAX 行で上界も持たせる）。
#   - 省略が出た block の末尾に **隣接して** 「… 残り <数> 行を省略・全件: <実行可能な完全コマンド>」を 1 行出す
#     （省略 0 の block では出さない）。pointer に絶対 path literal は書かず、実行時に変数（$DISPATCH 等）から
#     組み立てる（公開 repo の leak battery が deploypath 系統を fail-closed で RED 化するため）。
#   - 優先行の全保持は上界を持たないため、emit 最終段で u16 を実測する **hard-cap**（$WIP_HARDCAP_U16）を終端
#     guard として置く＝これが予算保証の本体。到達時は末尾を切って「… 予算到達により以降 M 行省略（全件: …）」の
#     1 行へ置換し、**予算警告は body より前（stdout 先頭）** に出す。
#   - 子 script の stdout は **全量を変数へ受けてから** bash 側で切る。`子 script | head` 型は禁止（engine copy は
#     SIGPIPE 修理が未同期ゆえ早期 close で rc=141 → fail-open 分岐が誤発火し内容も理由行も壊れる）。
#   - データ取得は全件のまま（子 script の引数は不変＝`--limit 0` 等の全件契約・截断禁止 teeth を抜かない）。
#     削るのは表示層だけであり、削った分は全件 pointer から常に辿れる。
WIP_HARDCAP_U16=8000     # 終端 hard-cap（emit 最終段で実測・予算保証の本体。合格上限 9,800 の手前に置く目標値）
WIP_PLAN_U16=6800        # 予算駆動 N の配分原資（hard-cap 手前に見出し/省略行/警告行の余白を残す）
WIP_FLOOR_LINES=10       # 節あたり表示行数の下限
WIP_FLOOR_MIN=5          # 予算不足時に限り下げてよい最小値（これ未満へは落とさない）
WIP_RANKA_MAX=40         # hard-cap の rank-A 先取り上限（節あたり行数・優先行の無上界保持で cap が破れるのを防ぐ）
WIP_TRIM=1               # 0 = 表示層 trim を外す（--full）
_WIP_SELF="$_SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"   # 全件 pointer 用（絶対 path literal を書かない）

# UTF-16 code unit 数（ハーネス cliff と同じ単位）。python3 不在時のみ codepoint 近似へ degrade（fail-open）。
_wip_u16len() {  # $1=text → u16 数を stdout
    local _s="$1" _n=""
    if command -v python3 >/dev/null 2>&1; then
        _n="$(printf '%s' "$_s" | python3 -c 'import sys
_d = sys.stdin.buffer.read().decode("utf-8", "replace").strip()
sys.stdout.write(str(len(_d.encode("utf-16-le")) // 2))' 2>/dev/null)"
    fi
    case "$_n" in ''|*[!0-9]*) _n="${#_s}" ;; esac
    printf '%s' "$_n"
}

_wip_count_lines() {  # $1=text → 行数を stdout
    local _c=0 _l
    while IFS= read -r _l; do _c=$((_c + 1)); done <<<"$1"
    printf '%s' "$_c"
}

# 節見出し判定（行頭アンカー）。hard-cap が **無条件保持**する行＝節の完全消失を構造的に禁じる anchor。
# 子 script の record 行は必ず行頭空白から始まるので、本文行と衝突しない（本 hook が自分で積む見出しだけを拾う）。
_wip_is_section_head() {  # $1=line → 節見出しなら rc=0
    case "$1" in "── "*|"==="*) return 0 ;; esac
    return 1
}

# 優先クラス判定（N 枠を消費せず常に全保持する行）。actionable / 集計 / 見出し / fail-open 理由行を守る。
# ★大小無視で照合する: 実 producer は bracket token を **大文字**で吐く（degraded-watch の `[SUSPECT]` /
#   `[SALVAGE]`、stale-scan の `[RERATIFY-TRIPWIRE]` / `[COMPLETENESS-RED]`）。小文字 glob だけだと
#   `[SUSPECT]` 行が非優先に落ち、actionable な degraded cell が N 枠に食われる（実 producer 文字列で実測）。
# ★RED は token 境界で絞る: 素の `*RED*` は SHARED / REQUIRED / DEFERRED を優先誤検知し、優先枠を膨張させて
#   hard-cap の発火を早める（＝節消失を悪化させる方向に効く）。実 producer の RED 出力は `[…-RED]` 形のみ。
# ★rank-A（優先クラスの中の最優先・sc-v0ao review major-1/2）: 🔔 呼び鈴 / `集計:` / `[…-RED]` / TRIPWIRE / 警告。
#   「1 block に数行しか出ないが、その block の総覧そのもの」＝実 producer が **block 末尾**へ置く行の集合
#   （orch-delivery-observe の `── 集計:` と `🔔 呼び鈴打ちますか？`、orch-stale-scan の `[RERATIFY-TRIPWIRE]` /
#   `[COMPLETENESS-RED]`、orch_slate の `[SLATE-TRIPWIRE]`）。hard-cap はこの集合を節予算に **先立って**先取りする。
#   ★素の「呼び鈴」語（🔔 なし）は rank-A に**入れない**: record 行が「閾値 未満＝呼び鈴 point 未達」のように
#     説明語として持つため、rank-A へ入れると大量発生系が最優先枠を占め rank-A の意味（少数・総覧）が壊れる。
#     実 producer の呼び鈴 surface は必ず 🔔 marker 付き（proposal-only 行）＝marker 側で拾えば十分。
_wip_is_rank_a() {  # $1=line → rank-A なら rc=0
    local _u="${1^^}"
    case "$1" in
        *"🔔"*|*"集計:"*|*"警告"*) return 0 ;;
    esac
    case "$_u" in
        *TRIPWIRE*) return 0 ;;
        *"-RED]"*|*"[RED]"*|*"[RED "*|*" RED "*|*" RED:"*|*"=RED"*) return 0 ;;
    esac
    return 1
}

# 優先クラス = rank-A ∪ rank-B（rank-B = 大量発生する record 系優先行 + 節見出し + fail-open 理由行）。
# 集合としての優先クラスは従前と同一（rank 分割は hard-cap 内の**採る順序**だけを変え、N 枠の意味論は不変）。
_wip_is_priority() {  # $1=line → 優先なら rc=0
    local _u="${1^^}"
    _wip_is_rank_a "$1" && return 0
    case "$1" in
        *"滞留"*|*"呼び鈴"*|*"【"*) return 0 ;;
    esac
    _wip_is_section_head "$1" && return 0
    case "$_u" in
        *SUSPECT*|*SALVAGE*|*"FAIL-OPEN"*) return 0 ;;
    esac
    return 1
}

# 予算駆動 N: 残予算を残 block 数で割った取り分を、その block の平均行コストで割る。floor は 10 行、
# 10 行が取り分に収まらないときだけ 5 行まで下げる（5 行未満へは落とさない）。
_wip_plan_n() {  # $1=block の u16 $2=block の行数 → N を stdout
    local _u="$1" _lines="$2" _share _avg _n
    _share=$(( _WIP_REM / (_WIP_LEFT > 0 ? _WIP_LEFT : 1) ))
    [ "$_share" -lt 1 ] && _share=1
    _avg=$(( _u / (_lines > 0 ? _lines : 1) ))
    [ "$_avg" -lt 1 ] && _avg=1
    _n=$(( _share / _avg ))
    if [ "$_n" -lt "$WIP_FLOOR_LINES" ]; then
        if [ $(( WIP_FLOOR_LINES * _avg )) -le "$_share" ]; then
            _n="$WIP_FLOOR_LINES"                                    # 10 行が取り分に収まる → floor まで戻す
        elif [ "$_n" -lt "$WIP_FLOOR_MIN" ]; then
            _n="$WIP_FLOOR_MIN"                                      # 予算不足でも 5 行未満へは落とさない
        fi
    fi
    printf '%s' "$_n"
}

# 1 block の trim。優先行は素通し、非優先行は先頭 N 行だけ残し、省略が出たら末尾に隣接して省略行を 1 行足す。
_wip_trim_block() {  # $1=body $2=N $3=全件 pointer → trim 済み body を stdout
    local _body="$1" _n="$2" _ptr="$3" _line _out="" _kept=0 _omit=0
    while IFS= read -r _line; do
        if _wip_is_priority "$_line"; then
            _out="$_out$_line"$'\n'
        elif [ "$_kept" -lt "$_n" ]; then
            _out="$_out$_line"$'\n'; _kept=$((_kept + 1))
        else
            _omit=$((_omit + 1))
        fi
    done <<<"$_body"
    if [ "$_omit" -gt 0 ]; then
        _out="$_out$(printf '  … 残り %d 行を省略・全件: %s' "$_omit" "$_ptr")"$'\n'
    fi
    printf '%s' "$_out"
}

# 1 block を実行 → 全量変数受け → trim → _WIP_BODY へ append（予算の残りと残 block 数を更新）。
# fail-open: 不在/非実行可能なら skip note、非0終了なら（部分出力は保持したまま）理由行を足して continue。
_wip_emit_block() {  # $1=表示名 $2=script $3..=args
    local _name="$1" _script="$2"; shift 2
    local _raw _rc=0 _disp _blk _n
    _disp="$_name${*:+ $*}"
    if [ -x "$_script" ]; then
        _raw="$("$_script" "$@" 2>/dev/null)" || _rc=$?
        if [ "$_rc" -ne 0 ]; then
            [ -n "$_raw" ] && _raw="$_raw"$'\n'
            _raw="$_raw  （$_disp が非0終了・skip＝fail-open）"
        fi
    else
        _raw="  （$_name 不在/非実行可能: $_script・skip＝fail-open）"
    fi
    # 節生存（acceptance 3）: 空 block でも「本文 1 行以上」を必ず持たせ、節が完全消失しないようにする。
    [ -n "$_raw" ] || _raw="  （$_disp: 出力なし）"
    if [ "$WIP_TRIM" -eq 1 ]; then
        _n="$(_wip_plan_n "$(_wip_u16len "$_raw")" "$(_wip_count_lines "$_raw")")"
        _blk="$(_wip_trim_block "$_raw" "$_n" "$_script${*:+ $*}")"
    else
        _blk="$_raw"
    fi
    _WIP_BODY="$_WIP_BODY$_blk"$'\n'
    _WIP_LEFT=$(( _WIP_LEFT - 1 ))
    _WIP_REM=$(( _WIP_REM - $(_wip_u16len "$_blk") ))
}

# 行別 u16 を **1 プロセスで実測**して _WIP_COST[] へ入れる（入力 = _WIP_LINE[]）。
# ★行長比による按分推定は使わない: 按分は body 内の u16/文字 密度が一様な場合しか成り立たず、ASCII 濃い行と
#   日本語濃い行と astral 文字（🔔 は 2 u16 だが ${#} では 1）が混在する実 stdout では予算保証が fail-open する
#   （非 UTF-8 locale では ${#} が byte 数になり尺度がさらにずれる）。python3 1 起動で行別に実測すれば
#   subprocess は行数によらず 1 個で済み、密度が偏っても cap が効く。
# python3 不在 / 出力不正のときだけ ${#line} へ degrade する（fail-open）。degrade 時の誤差は _wip_hardcap の
#   「実測 → 超過なら予算を縮めて再試行」収束ループが吸収する（fail-closed 側の保険）。
_wip_line_costs() {  # 入力=_WIP_LINE[] → _WIP_COST[]（行末改行を含まない素の u16）
    local _raw="" _v _bad=0
    _WIP_COST=()
    if command -v python3 >/dev/null 2>&1 && [ "${#_WIP_LINE[@]}" -gt 0 ]; then
        _raw="$(printf '%s\n' "${_WIP_LINE[@]}" | python3 -c 'import sys
_ls = sys.stdin.buffer.read().decode("utf-8", "replace").split("\n")[:-1]
sys.stdout.write("".join(str(len(_x.encode("utf-16-le")) // 2) + "\n" for _x in _ls))' 2>/dev/null)"
        _raw="${_raw%$'\n'}"
    fi
    if [ -n "$_raw" ]; then
        while IFS= read -r _v; do
            case "$_v" in ''|*[!0-9]*) _bad=1 ;; esac
            _WIP_COST+=("$_v")
        done <<<"$_raw"
    fi
    if [ "$_bad" -ne 0 ] || [ "${#_WIP_COST[@]}" -ne "${#_WIP_LINE[@]}" ]; then
        _WIP_COST=()
        for _v in "${_WIP_LINE[@]}"; do _WIP_COST+=("${#_v}"); done
    fi
}

# hard-cap の 1 回分の組み立て（$1=本文行に配れる予算 $2=行数 $3=節数）。_WIP_OUT / _WIP_CAPPED を書く。
# 節構造を保つ: 節見出し・空行・既存の省略行は **無条件保持**（固定費として先取り済み）。行の採取は 3 pass:
# pass 0 = rank-A（🔔 / 集計: / […-RED] / TRIPWIRE / 警告）を節予算に**先立って**先取り（節あたり
# $WIP_RANKA_MAX 行・総額 avail 以内）、pass 1 = rank-B 優先行（[滞留] / SUSPECT / SALVAGE 等）、
# pass 2 = 非優先行。pass 1/2 は残予算を節ごとに等分（余剰は後続節へ繰越）した share 内で採る。
# ★pass 0 が要る理由（実測・review major-1/2）: 実 producer は block 全行が rank-B（配送観測の便 record 行は
#   全行 [滞留]）で、最も actionable な rank-A を **block 末尾**に置く。pass を 1/2 の 2 段にすると先頭の
#   rank-B が share を食い切り、末尾の 🔔 / 集計: が cap まで ~5,000 u16 余らせたまま必ず落ちた。
# 落とした節には省略行を必ず持たせる＝acceptance (3)
# 「全節見出しが残り、各節は本文 1 行以上か省略行のいずれかを必ず持つ」を構造的に満たす。
# ★drop 集計は **節単位でなく block（既存省略行の所有範囲）単位**（sc-v0ao review major-1/3）: 1 節に既存省略行が
#   2 本並ぶ形（実形の第5節 = orch-stale-scan block + orch_slate block）で節単位に集計すると、節全体の drop が
#   両方の省略行へ **それぞれ全額** 加算され「省略件数 == 実省略行数」（acceptance (2)）が壊れる。_WIP_OWN[i] が
#   「行 i を畳んだ省略行の index（同一節内で i 以降の最初の省略行・無ければ -1）」を持ち、drop は所有者へ 1 件ずつ
#   加算する。所有者を持たない drop（末尾側の未所有領域 / 省略行の無い節）だけが節末尾の新規 1 行へ集約される。
_wip_hc_build() {  # $1=avail $2=行数 $3=節数
    local _avail="$1" _n="$2" _nsec="$3"
    local _rem="$_avail" _left="$_nsec" _share _used _sec _pass _i _c _drop=0 _line _out="" _ptr _own
    local _pre _post _num _ra_used=0 _ra_cnt
    local -a _keep=() _secdrop=() _blkdrop=()
    for (( _i = 0; _i < _n; _i++ )); do _keep[_i]=0; _blkdrop[_i]=0; done
    for (( _sec = 0; _sec < _nsec; _sec++ )); do _secdrop[_sec]=0; done
    # pass 0（sc-v0ao review major-1/2）: rank-A（🔔 / 集計: / […-RED] / TRIPWIRE / 警告）を **節予算に先立って**
    # 先取りする。実 producer は rank-A を block 末尾へ置くため、節取り分の中で index 順に採ると先頭の record 行
    # （全行 [滞留]＝rank-B）で share を食い切り、末尾の rank-A が構造的に必ず落ちる（実測 🔔 0 / 集計 0）。
    # 上界も持たせる: 節あたり $WIP_RANKA_MAX 行 かつ 総額 $_avail 以内（rank-A の無上界保持で cap が破れない＝
    # 収束ループが必ず効く）。ここで先取りした分だけ _rem を減らして通常配分へ渡す。
    for (( _sec = 0; _sec < _nsec; _sec++ )); do
        _ra_cnt=0
        for _i in ${_WIP_SL[_sec]}; do
            [ "${_WIP_PROT[_i]}" -eq 0 ] || continue
            _wip_is_rank_a "${_WIP_LINE[_i]}" || continue
            [ "$_ra_cnt" -lt "$WIP_RANKA_MAX" ] || break
            _c=$(( ${_WIP_COST[_i]} + 1 ))
            [ $(( _ra_used + _c )) -le "$_avail" ] || break
            _keep[_i]=1; _ra_used=$(( _ra_used + _c )); _ra_cnt=$(( _ra_cnt + 1 ))
        done
    done
    _rem=$(( _avail - _ra_used )); [ "$_rem" -lt 0 ] && _rem=0
    for (( _sec = 0; _sec < _nsec; _sec++ )); do
        [ "$_left" -gt 0 ] || _left=1
        _share=$(( _rem / _left )); [ "$_share" -lt 0 ] && _share=0
        _used=0
        for _pass in 1 2; do
            for _i in ${_WIP_SL[_sec]}; do
                [ "${_WIP_PROT[_i]}" -eq 0 ] || continue
                [ "${_keep[_i]}" -eq 0 ] || continue
                if [ "$_pass" -eq 1 ]; then
                    _wip_is_priority "${_WIP_LINE[_i]}" || continue
                else
                    _wip_is_priority "${_WIP_LINE[_i]}" && continue
                fi
                _c=$(( ${_WIP_COST[_i]} + 1 ))
                [ $(( _used + _c )) -le "$_share" ] || break
                _keep[_i]=1; _used=$(( _used + _c ))
            done
        done
        _rem=$(( _rem - _used )); _left=$(( _left - 1 ))
        for _i in ${_WIP_SL[_sec]}; do
            if [ "${_WIP_PROT[_i]}" -eq 0 ] && [ "${_keep[_i]}" -eq 0 ]; then
                _own=${_WIP_OWN[_i]}
                # 所有者（その行を畳んだ既存省略行）へ 1 件加算。所有者無しだけを節末尾の新規行へ回す。
                if [ "$_own" -ge 0 ]; then _blkdrop[_own]=$(( ${_blkdrop[_own]} + 1 ))
                else _secdrop[_sec]=$(( ${_secdrop[_sec]} + 1 )); fi
                _drop=$(( _drop + 1 ))
            fi
        done
    done
    # 既存省略行は **自 block の drop 件数だけ** を加算更新する（節全体の drop を全省略行へ配ると
    # 「省略件数 == 実省略行数」の機械照合が壊れる＝review major-1/3）。所有者を持たない drop がある節にだけ
    # 新規 1 行を節末尾へ挿入する（既存省略行と併存してよい＝件数が互いに素なので総和は実省略行数と一致する）。
    _ptr="bash $_WIP_SELF --full"
    for (( _i = 0; _i < _n; _i++ )); do
        _sec=${_WIP_SEC[_i]}
        if [ "${_WIP_PROT[_i]}" -eq 1 ] || [ "${_keep[_i]}" -eq 1 ]; then
            _line="${_WIP_LINE[_i]}"
            if [ "${_blkdrop[_i]}" -gt 0 ] && [[ "$_line" == *"残り "*" 行を省略・全件: "* ]]; then
                _pre="${_line%%残り *}"; _post="${_line#*残り }"
                _num="${_post%% 行を省略*}"; _post="${_post#* 行を省略}"
                case "$_num" in ''|*[!0-9]*) _num=0 ;; esac
                _line="${_pre}残り $(( _num + ${_blkdrop[_i]} )) 行を省略${_post}"
            fi
            _out="$_out$_line"$'\n'
        fi
        if [ "${_secdrop[_sec]}" -gt 0 ] && [ "${_WIP_INS[_sec]:--1}" -eq "$_i" ]; then
            _out="$_out$(printf '  … 残り %d 行を省略・全件: %s' "${_secdrop[_sec]}" "$_ptr")"$'\n'
        fi
    done
    _WIP_CAPPED=$_drop
    _WIP_OUT="$_out$(printf '  … 予算到達により以降 %d 行省略（全件: %s）' "$_drop" "$_ptr")"$'\n'
}

# 終端 hard-cap（予算保証の本体）: 優先行の全保持は上界を持たないため、最終段で u16 を実測して切る。
# 結果は _WIP_OUT、切り詰めた行数は _WIP_CAPPED（0 なら未発火）へ返す（command substitution だと global が
# subshell に閉じるので stdout 返しにしない）。
# ★「末尾を一律に切る」形は採らない: 優先行主体の入力（配送観測の便 record 行は全行が [滞留] を含む＝実運用形）
#   では先頭 block が予算を食い切り、後続の **節見出しごと**落ちる＝本 hook が直そうとした元症状（末尾の節が
#   丸ごと消える）が閾値だけ前倒しで再現する。よって節構造を保つ配分型にする（_wip_hc_build）。
_wip_hardcap() {  # $1=body
    local _body="$1" _line _i _s=0 _n _nsec _fixed=0 _avail _measured _attempt=0 _own _cursec
    _WIP_OUT="$_body"; _WIP_CAPPED=0
    _measured="$(_wip_u16len "$_body")"
    [ "$_measured" -lt "$WIP_HARDCAP_U16" ] && return 0

    _WIP_LINE=()
    while IFS= read -r _line; do _WIP_LINE+=("$_line"); done <<<"${_body%$'\n'}"
    _n=${#_WIP_LINE[@]}
    _wip_line_costs

    # 節分割 + 無条件保持（節見出し / 空行 / 既存の省略行）の固定費先取り。
    _WIP_SEC=(); _WIP_PROT=(); _WIP_SL=(); _WIP_INS=()
    for (( _i = 0; _i < _n; _i++ )); do
        if _wip_is_section_head "${_WIP_LINE[_i]}" && [ "$_i" -gt 0 ]; then _s=$(( _s + 1 )); fi
        _WIP_SEC[_i]=$_s
        _WIP_SL[_s]="${_WIP_SL[_s]:-} $_i"
        if _wip_is_section_head "${_WIP_LINE[_i]}" || [ -z "${_WIP_LINE[_i]}" ] \
           || [[ "${_WIP_LINE[_i]}" == *"行を省略・全件: "* ]]; then
            _WIP_PROT[_i]=1; _fixed=$(( _fixed + ${_WIP_COST[_i]} + 1 ))
        else
            _WIP_PROT[_i]=0
        fi
        [ -n "${_WIP_LINE[_i]}" ] && _WIP_INS[_s]=$_i   # 節末尾の非空行＝省略行の挿入位置（節に隣接させる）
    done
    _nsec=$(( _s + 1 ))
    # block 所有（sc-v0ao review major-1/3）: per-block trim は「その block を畳んだ省略行」を block 末尾へ
    # 隣接して置く。よって行 i の所有者 = 同一節内で i 以降にある最初の省略行（無ければ -1＝未所有）。
    # 後ろから 1 passで解ける。節境界で所有者をリセットし、隣節の省略行へ漏れないようにする。
    _WIP_OWN=(); _own=-1; _cursec=-1
    for (( _i = _n - 1; _i >= 0; _i-- )); do
        if [ "${_WIP_SEC[_i]}" -ne "$_cursec" ]; then _cursec=${_WIP_SEC[_i]}; _own=-1; fi
        [[ "${_WIP_LINE[_i]}" == *"行を省略・全件: "* ]] && _own=$_i
        _WIP_OWN[_i]=$_own
    done
    # 予約: 節ごとに新規省略行 1 本（pointer 込みで ~160 u16）+ 末尾の予算到達行。
    _avail=$(( WIP_HARDCAP_U16 - _fixed - _nsec * 160 - 240 ))
    [ "$_avail" -lt 0 ] && _avail=0

    # 実測収束ループ（按分推定の代わり）: 組んだ結果を実測し、超過していれば予算を実測比で縮めて組み直す。
    # 行別 u16 が実測できていれば 1 回で収まる。degrade 経路（python3 不在）でも数回で cap 以下へ落ちる。
    while :; do
        _wip_hc_build "$_avail" "$_n" "$_nsec"
        _measured="$(_wip_u16len "$_WIP_OUT")"
        [ "$_measured" -le "$WIP_HARDCAP_U16" ] && break
        _attempt=$(( _attempt + 1 )); [ "$_attempt" -ge 6 ] && break
        _avail=$(( _avail * WIP_HARDCAP_U16 / (_measured > 0 ? _measured : 1) - 200 ))
        [ "$_avail" -lt 0 ] && _avail=0
    done
}

# --- 仕掛かり自動表示の本体（self-scope/cwd-axis を通過した orch anchor session でのみ到達） ---
# fail-open: 参照 script が不在/非実行可能なら skip note・存在時は内部エラーを握り潰して continue。
# cd "$1"（検証済み orch anchor cwd）してから各 script を実行し、bd（dispatch）/ degraded の self-scope gate
# （共有 _ledger_dolt_database・orch-t9z で lib へ統一）が hook_cwd を起点に一貫解決するようにする（全 script read-only）。
# ★出力は逐次 echo でなく _WIP_BODY へ組んでから最終段で一括 emit する（予算警告を body より前に出すため）。
_emit_workinprogress() {
    local anchor_cwd="$1"
    cd "$anchor_cwd" 2>/dev/null || true

    _WIP_BODY=""; _WIP_LEFT=6; _WIP_REM="$WIP_PLAN_U16"; _WIP_OUT=""; _WIP_CAPPED=0

    _WIP_BODY="$_WIP_BODY=== [orchestrator/SessionStart] 仕掛かり自動表示（gate-pending + degraded-watch・self-scope: orch anchor のみ） ==="$'\n\n'

    _WIP_BODY="$_WIP_BODY── (1) gate-pending（gate 待ち cell・read-only） ──"$'\n'
    _wip_emit_block "orch-dispatch.sh" "$DISPATCH" --gate-pending
    _WIP_BODY="$_WIP_BODY"$'\n'

    _WIP_BODY="$_WIP_BODY── (2) degraded-watch（窓消失 cell の suspect/salvage・read-only） ──"$'\n'
    _wip_emit_block "orch-degraded-watch.sh" "$DEGRADED"
    _WIP_BODY="$_WIP_BODY"$'\n'

    # (3) needs-orch handoff（foreign→orchestrator 検知線・bd orch-jmu / orch-am1 論点6）。鮮度警告は
    #     第1セクション（gate-pending pull）へ委譲するため --no-freshness で呼ぶ（同一 hook 出力の二重表示回避・p3）。
    _WIP_BODY="$_WIP_BODY── (3) needs-orch handoff（foreign→orchestrator 検知線・read-only） ──"$'\n'
    _wip_emit_block "orch-handoff-scan.sh" "$HANDOFF" --no-freshness
    _WIP_BODY="$_WIP_BODY"$'\n'

    # (4) 配送観測（delivery observation・bd orch-4js9・top-spec §1.1:85 / §5.4:246）。各 admin（宛先 X）への
    #     for:X 便の cycle 境界 proxy / 推論配送 3 値 / 呼び鈴 proposal-only / auto-compact marker read を surface
    #     する（proxy scope・read-only・fail-open）。滞留検知（配送観測）は wake でなく §1.2 ① の無条件能動側＝
    #     呼び鈴は「提案のみ」で push（wake=③）は人間 go（本 hook は push を発火しない）。hygiene tripwire は別便
    #     /scriptorium:orch-rebrief brief（orch-x1ae）が担う分担（surface 分担: 配送観測=本 hook / tripwire=orch-rebrief）。
    _WIP_BODY="$_WIP_BODY── (4) 配送観測（cycle 境界 proxy / 推論配送 / 呼び鈴提案・read-only） ──"$'\n'
    _wip_emit_block "orch-delivery-observe.sh" "$DELIVERY"
    _WIP_BODY="$_WIP_BODY"$'\n'

    # (5) re-ratify sweep + open slate surface（bd orch-cqf4 Leg-A・PR#147 engine 反映・第5節）。
    #     死角クラスの re-ratify 候補 sweep（orch-stale-scan --re-ratify）と open 計画 slate の薄い read-only surface
    #     （orch_slate --surface）を各 [ -x ] fail-open guard で守る（両者 read-only・bd/foreign 台帳を mutate しない）。
    #     独立 sentinel（RERATIFY-SWEEP / SLATE-SURFACE）を割当てる（既存 4 sentinel と別の 5th/6th）。
    #     ★needs-user 呼び鈴（裁定(3)）: re-ratify 出力中の 🔔 行（needs-user 併存への呼び鈴マーク）はそのまま stdout へ
    #       流す＝surface のみで push しない（本 hook は wake を発火しない・top-spec §5.4「配送観測 ≠ wake」と同方針）。
    #       🔔 行は表示層 trim でも優先クラス（常に全保持）ゆえ N 枠に食われない。終端 hard-cap が発火した場合も
    #       🔔 は rank-A（_wip_is_rank_a）として節予算に先立って先取りされる＝block 末尾に置かれていても
    #       先頭の rank-B record 行（[滞留] 等）に押し出されない（review major-1/2 の実測で入れた pass 0）。
    _WIP_BODY="$_WIP_BODY── (5) re-ratify sweep + open slate surface（死角クラス re-ratify 候補 / open slate・read-only） ──"$'\n'
    _wip_emit_block "orch-stale-scan.sh" "$RERATIFY" --re-ratify
    _WIP_BODY="$_WIP_BODY"$'\n'
    _wip_emit_block "orch_slate.sh" "$SLATE_SURFACE" --surface

    _WIP_OUT="$_WIP_BODY"
    [ "$WIP_TRIM" -eq 1 ] && _wip_hardcap "$_WIP_BODY"
    # 予算警告は body より前（stdout 先頭）に出す（本文を読む前に「切られている」と分かるように）。
    [ "$_WIP_CAPPED" -gt 0 ] && printf '%s\n' "  ⚠ 警告: 表示予算 $WIP_HARDCAP_U16 u16 到達により末尾 $_WIP_CAPPED 行を切り詰めた（全件: bash $_WIP_SELF --full）"
    printf '%s' "$_WIP_OUT"
}

# === --self-test: hermetic 自己完結テスト（fail-closed・orch-7py） ===
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t wip-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    # fixture plugin root（stub が sentinel を echo）。sentinel に起動時 PWD（本体の load-bearing な
    # cd "$anchor_cwd" を pin）と受領 args（dispatch は --gate-pending / degraded は無引数=scan mode /
    # handoff は --no-freshness=第1セクションへ鮮度委譲・orch-jmu p3）を含める。
    mkdir -p "$st_tmp/plugin/scripts"
    printf '#!/usr/bin/env bash\necho "GATE-PENDING-SENTINEL pwd=$PWD args=[$*]"\n'   > "$st_tmp/plugin/scripts/orch-dispatch.sh"
    printf '#!/usr/bin/env bash\necho "DEGRADED-WATCH-SENTINEL pwd=$PWD args=[$*]"\n' > "$st_tmp/plugin/scripts/orch-degraded-watch.sh"
    printf '#!/usr/bin/env bash\necho "HANDOFF-SCAN-SENTINEL pwd=$PWD args=[$*]"\n'   > "$st_tmp/plugin/scripts/orch-handoff-scan.sh"
    printf '#!/usr/bin/env bash\necho "DELIVERY-OBSERVE-SENTINEL pwd=$PWD args=[$*]"\n' > "$st_tmp/plugin/scripts/orch-delivery-observe.sh"
    # 第5節 stub（orch-cqf4 Leg-A）: re-ratify sweep（scripts/）と slate surface（scripts/lib/）。独立 sentinel を echo。
    mkdir -p "$st_tmp/plugin/scripts/lib"
    printf '#!/usr/bin/env bash\necho "RERATIFY-SWEEP-SENTINEL pwd=$PWD args=[$*]"\n' > "$st_tmp/plugin/scripts/orch-stale-scan.sh"
    printf '#!/usr/bin/env bash\necho "SLATE-SURFACE-SENTINEL pwd=$PWD args=[$*]"\n'  > "$st_tmp/plugin/scripts/lib/orch_slate.sh"
    chmod +x "$st_tmp/plugin/scripts/orch-dispatch.sh" "$st_tmp/plugin/scripts/orch-degraded-watch.sh" \
             "$st_tmp/plugin/scripts/orch-handoff-scan.sh" "$st_tmp/plugin/scripts/orch-delivery-observe.sh" \
             "$st_tmp/plugin/scripts/orch-stale-scan.sh" "$st_tmp/plugin/scripts/lib/orch_slate.sh"

    # 台帳 fixture。
    mkdir -p "$st_tmp/anchor/.beads";  printf '{"dolt_database":"orch"}' > "$st_tmp/anchor/.beads/metadata.json"
    mkdir -p "$st_tmp/foreign/.beads"; printf '{"dolt_database":"un"}'   > "$st_tmp/foreign/.beads/metadata.json"
    mkdir -p "$st_tmp/anchor/.worktrees/spawn/wt"        # 台帳 walk-up は anchor(orch)へ届く worktree
    mkdir -p "$st_tmp/anchor/.claude/worktrees/wt2"      # CC-native worktree

    # hazard-faithful stub tmux（consult 経路・fence7 b・spec-inject.sh の M2 teeth と同型）。`-t <pane>` 明示時のみ
    # 「その pane の窓名」= $STUB_WNAME を返す（空なら非0=取得失敗を模す）。`-t <value>` 不在（bare 形 = mutation）は
    # focused 別窓を模し非 consult 名 orchestrator を返す → _is_consult_window の -t "$TMUX_PANE" 明示を pin する。
    mkdir -p "$st_tmp/bin"
    cat > "$st_tmp/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
have_t=0; prev=""
for a in "$@"; do
    if [ "$prev" = "-t" ] && [ -n "$a" ]; then have_t=1; fi
    prev="$a"
done
if [ "$have_t" -eq 1 ]; then
    [ -n "${STUB_WNAME:-}" ] || exit 1
    printf '%s\n' "$STUB_WNAME"
else
    printf '%s\n' "orchestrator"
fi
TMUXEOF
    chmod +x "$st_tmp/bin/tmux"

    # $1=cwd → fixture plugin root で本 script を fresh 起動し stdout を返す（非 consult 経路）。exit code は呼出側が
    # `out="$(_st_run ...)"; rc=$?` で受ける（command substitution の $? = pipeline 末尾 bash "$0" の rc）。
    # ★env -u TMUX -u TMUX_PANE（fence7 a）: self-test を実 tmux window 内で回したとき、新設 consult gate の
    #   _is_consult_window が実 tmux を叩いて実窓名に依存するのを遮断する（既存 modality を実窓名非依存に保つ・byte 不変）。
    _st_run() {
        printf '{"cwd":"%s"}' "$1" | env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" bash "$0"
    }
    # consult 経路（fence7 b）: TMUX + stub tmux 付きで起動（$2=窓名・空→tmux 失敗を模す）。
    _st_run_consult() {  # $1=cwd $2=window-name
        printf '{"cwd":"%s"}' "$1" | env CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" \
            PATH="$st_tmp/bin:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" bash "$0"
    }
    _st_both() {  # $1=label $2=cwd : 6 sentinel + cd anchor + degraded 無引数 + handoff --no-freshness + 第5節 re-ratify/surface + exit0 を期待
        local out rc expect; out="$(_st_run "$2")"; rc=$?; expect="$(cd "$2" 2>/dev/null && pwd)"
        # cd "$anchor_cwd"（load-bearing）を pin: stub の起動時 PWD が anchor と一致。degraded/delivery は無引数(scan)。
        # handoff は --no-freshness（鮮度を第1セクションへ委譲・orch-jmu p3）で呼ばれることを pin。
        # ★第5節（orch-cqf4 Leg-A）: re-ratify は --re-ratify / slate surface は --surface で呼ばれる独立 sentinel を
        #   5th/6th として明示 assert（既存 4-sentinel の流用では 5th/6th 破損を検知しない＝vacuous を塞ぐ・F7）。
        if printf '%s' "$out" | grep -qF "GATE-PENDING-SENTINEL pwd=$expect args=[--gate-pending]" \
            && printf '%s' "$out" | grep -qF "DEGRADED-WATCH-SENTINEL pwd=$expect args=[]" \
            && printf '%s' "$out" | grep -qF "HANDOFF-SCAN-SENTINEL pwd=$expect args=[--no-freshness]" \
            && printf '%s' "$out" | grep -qF "DELIVERY-OBSERVE-SENTINEL pwd=$expect args=[]" \
            && printf '%s' "$out" | grep -qF "RERATIFY-SWEEP-SENTINEL pwd=$expect args=[--re-ratify]" \
            && printf '%s' "$out" | grep -qF "SLATE-SURFACE-SENTINEL pwd=$expect args=[--surface]" \
            && [ "$rc" -eq 0 ]; then echo "ok: $1"
        else echo "FAIL: $1 — cd anchor + degraded/delivery 無引数 + handoff --no-freshness + 第5節 re-ratify/surface + 6 sentinel + exit0 を期待したが不一致（rc=$rc・expect_pwd=$expect）: [$out]" >&2; st_fail=1; fi
    }
    _st_noop() {  # $1=label $2=cwd : no-op（無出力）+ exit0 を期待（非 consult 経路）
        local out rc; out="$(_st_run "$2")"; rc=$?
        if [ -z "$out" ] && [ "$rc" -eq 0 ]; then echo "ok: $1"
        else echo "FAIL: $1 — no-op(無出力)+exit0 を期待したが不一致（rc=$rc）: [$out]" >&2; st_fail=1; fi
    }
    _st_emit_c() {  # $1=label $2=cwd $3=wname : consult 経路で 4 sentinel 表示（＝gate 通過し emit）を期待
        local out; out="$(_st_run_consult "$2" "$3")"
        if printf '%s' "$out" | grep -qF "GATE-PENDING-SENTINEL" \
            && printf '%s' "$out" | grep -qF "DELIVERY-OBSERVE-SENTINEL"; then echo "ok: $1"
        else echo "FAIL: $1 — consult 経路で emit（sentinel 表示）を期待したが不一致: [$out]" >&2; st_fail=1; fi
    }
    _st_noop_c() {  # $1=label $2=cwd $3=wname : consult 経路で no-op（無出力）を期待
        local out; out="$(_st_run_consult "$2" "$3")"
        if [ -z "$out" ]; then echo "ok: $1"
        else echo "FAIL: $1 — consult no-op を期待したが出力あり: [$out]" >&2; st_fail=1; fi
    }

    _st_both "orch anchor cwd → 6 sentinel 表示（gate-pending / degraded / handoff / delivery / re-ratify / slate-surface）"  "$st_tmp/anchor"
    _st_noop "orch worktree(.worktrees/) → no-op"                 "$st_tmp/anchor/.worktrees/spawn/wt"
    _st_noop "orch worktree(.claude/worktrees/) → no-op"          "$st_tmp/anchor/.claude/worktrees/wt2"
    _st_noop "foreign 台帳 → no-op（self-scope）"                  "$st_tmp/foreign"

    # consult 窓 第3軸（orch-z4z7 / fence7 b・spec-inject と同型）。
    _st_noop_c "consult 窓(consult-*) → anchor cwd でも no-op（全4節一括 gating・gate 削除 mutation で RED）" "$st_tmp/anchor" "consult-abc"
    _st_emit_c "非 consult 窓(orchestrator) → emit（4 sentinel 表示）"                                       "$st_tmp/anchor" "orchestrator"
    _st_noop_c "foreign 台帳 + consult 窓 → no-op（self-scope 先勝ち）"                                       "$st_tmp/foreign" "consult-abc"
    # TMUX 未設定 → 非 consult 扱い（fail-safe・emit 継続）は _st_both（env -u TMUX）が既に pin 済み（anchor→4 sentinel）。

    # 非vacuity(mutation): stub を消すと anchor でも 全 6 sentinel が消え skip note + exit0（fail-open・非vacuous）。
    # ★第5節 stub（orch-stale-scan.sh / lib/orch_slate.sh）も削除対象へ含め、5th/6th の消失も独立に見る（F7・vacuous 回避）。
    rm -f "$st_tmp/plugin/scripts/orch-dispatch.sh" "$st_tmp/plugin/scripts/orch-degraded-watch.sh" \
          "$st_tmp/plugin/scripts/orch-handoff-scan.sh" "$st_tmp/plugin/scripts/orch-delivery-observe.sh" \
          "$st_tmp/plugin/scripts/orch-stale-scan.sh" "$st_tmp/plugin/scripts/lib/orch_slate.sh"
    _st_mut_out="$(_st_run "$st_tmp/anchor")"; _st_mut_rc=$?
    if [ "$_st_mut_rc" -eq 0 ] \
        && ! printf '%s' "$_st_mut_out" | grep -q 'GATE-PENDING-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'DEGRADED-WATCH-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'HANDOFF-SCAN-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'DELIVERY-OBSERVE-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'RERATIFY-SWEEP-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'SLATE-SURFACE-SENTINEL' \
        && printf '%s' "$_st_mut_out" | grep -q 'fail-open'; then
        echo "ok: mutation: stub 不在 → anchor でも 6 sentinel 消失 + skip note + exit0（fail-open・非vacuous）"
    else
        echo "FAIL: mutation: stub 不在 fail-open を期待したが不一致（rc=$_st_mut_rc）: [$_st_mut_out]" >&2; st_fail=1
    fi

    # ── leak battery（F3・orch-cqf4 Leg-A public-safe hardening）────────────────────────
    # engine は PUBLIC 配布物ゆえ、本 diff で追加した第5節（_emit_workinprogress のソースを declare -f で live 抽出
    # ＝hermetic・base 非依存）に deploy 主体名 / 内部短名 codename / 絶対 deploy-path を混入していないことを 4 系統
    # fail-closed で assert する。実 leak は 0（admin 実測）＝battery は保険。緑=歯無しの取り違えを各系統 1 mutation
    # （positive fixture を added-content へ注入→必ず RED 化）で塞ぐ。
    #   (2) 短名は bare codename のみ検出しハイフン付き ledger-ID（foreign fixture un-xxx / pk-xxx）は非該当
    #       （ハイフンを token 文字に含める＝short-name leak の本来意味・pre-existing foreign fixture を誤爆しない）。
    _leak_scan() {  # $1=text : leak 検出→系統名を echo し rc=1 / clean→rc=0
        local _t="$1"
        # ★自己参照回避（realname 系統）: 兄弟 literal も char class で分断し、公開 source へ verbatim 識別子を残さない
        #   （`black[0-9]`/deploy-path 分断と一貫。分断後も real leak（実 codename/実ホスト名/email 断片の実出現）は
        #   依然マッチ＝検出器の歯は不変・acceptance-6 の literal grep=0 を realname 兄弟にも及ぼす）。
        grep -qwE 'shu[u]5|black[0-9]|phit[o]|ipath[o]|doobido[o]|blackco[w]|gmai[l]' <<<"$_t" && { echo realname; return 1; }
        grep -qE '(^|[^-A-Za-z0-9_])(pk|scp|un|scm|cs)([^-A-Za-z0-9_]|$)' <<<"$_t" && { echo shortname; return 1; }
        # ★自己参照回避: 検出器パターン自身が acceptance-6 の deploy-path grep に自己ヒットしないよう、対象 literal を
        #   正規表現 character class で分断する（`scriptoriu[m]` は real leak を変わらず検出・grader の literal grep には非マッチ）。
        grep -qE 'local-projects/scriptoriu[m]|/home/[a-z]' <<<"$_t" && { echo deploypath; return 1; }
        return 0
    }
    # ★走査対象は本 script が定義する **全 top-level 関数**（sc-v0ao: 新設関数の編入漏れを塞ぐ）。_LK_FNS が
    #   明示列挙で、直下の coverage assert が「列挙 == 実定義集合」を機械照合する（列挙漏れ＝FAIL）。
    _LK_FNS="_emit_workinprogress _wip_count_lines _wip_emit_block _wip_hardcap _wip_hc_build _wip_is_priority _wip_is_rank_a _wip_is_section_head _wip_line_costs _wip_plan_n _wip_trim_block _wip_u16len"
    _lk_sample=""
    for _lk_f in $_LK_FNS; do _lk_sample="$_lk_sample$(declare -f "$_lk_f")"$'\n'; done
    # 編入漏れ検知（新設関数を _LK_FNS へ足し忘れると RED）: 実定義集合 = 本 script の行頭 `name() {` 定義。
    _lk_scanned="$(printf '%s\n' $_LK_FNS | sort -u)"
    _lk_defined="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$_WIP_SELF" | sed 's/()$//' | sort -u)"
    if [ "$_lk_scanned" = "$_lk_defined" ]; then echo "ok: leak-battery coverage: 走査対象の関数名集合＝本 script の定義関数集合（新設関数の編入漏れ無し）"
    else echo "FAIL: leak-battery coverage: 走査対象[$(printf '%s' "$_lk_scanned" | tr '\n' ' ')] != 定義集合[$(printf '%s' "$_lk_defined" | tr '\n' ' ')]" >&2; st_fail=1; fi
    # coverage 系統の teeth（1 mutation）: 列挙から 1 つ落とすと必ず不一致になる（assert が vacuous でない）。
    _lk_mut="$(printf '%s\n' $_LK_FNS | sort -u | tail -n +2)"
    if [ "$_lk_mut" = "$_lk_defined" ]; then echo "FAIL: leak-battery coverage 系統に歯が無い（1 関数を落としても一致した）" >&2; st_fail=1
    else echo "ok: leak-battery coverage 系統に歯あり（列挙から 1 関数を落とす mutation を RED 化）"; fi
    # 系統1-2-4 green（追加した第5節ソースは 3 系統とも clean）
    if _leak_scan "$_lk_sample" >/dev/null; then echo "ok: leak-battery: 第5節ソースは realname/shortname/deploypath clean"
    else echo "FAIL: leak-battery: 第5節ソースに leak（系統=$(_leak_scan "$_lk_sample")）" >&2; st_fail=1; fi
    # 系統1-2-4 teeth（各系統 1 mutation・注入した positive fixture を必ず検出）
    _inj="shu""u5"; if _leak_scan "$_lk_sample"$'\nleaked by '"$_inj"$' here\n'  >/dev/null; then echo "FAIL: leak-battery realname 系統に歯が無い（${_inj} を見逃した）" >&2; st_fail=1; else echo "ok: leak-battery realname 系統に歯あり（${_inj} mutation を RED 化）"; fi
    if _leak_scan "$_lk_sample"$'\nthe un project note\n'   >/dev/null; then echo "FAIL: leak-battery shortname 系統に歯が無い（bare un を見逃した）" >&2; st_fail=1; else echo "ok: leak-battery shortname 系統に歯あり（bare un mutation を RED 化）"; fi
    if _leak_scan "$_lk_sample"$'\nfallback=/home/someone/x\n' >/dev/null; then echo "FAIL: leak-battery deploypath 系統に歯が無い（/home/ を見逃した）" >&2; st_fail=1; else echo "ok: leak-battery deploypath 系統に歯あり（/home/ mutation を RED 化）"; fi
    # 系統3 dangling-lib: 本 hook が source する共有 lib（orch_session.sh）の実在検証 + 非実在 mutation。
    _leak_libcheck() { [ -r "$1" ]; }  # 実在 rc=0 / 非実在 rc=1
    if _leak_libcheck "$_ORCH_SESSION_LIB"; then echo "ok: leak-battery dangling-lib: source 先 orch_session.sh は実在"
    else echo "FAIL: leak-battery dangling-lib: source 先 lib が dangling（$_ORCH_SESSION_LIB 不在）" >&2; st_fail=1; fi
    if _leak_libcheck "$st_tmp/nonexistent-lib-$$.sh"; then echo "FAIL: leak-battery dangling-lib 系統に歯が無い（非実在 lib を実在と判定）" >&2; st_fail=1; else echo "ok: leak-battery dangling-lib 系統に歯あり（非実在 lib mutation を RED 化）"; fi

    # ── 表示層 trim / hard-cap 単体（sc-v0ao・in-process）─────────────────────────────────────
    # bats 側（T1-T4）は e2e で見るが、終端 guard（hard-cap）は e2e の合成負荷では通常発火しない設計ゆえ
    # ここで関数単体として fail-closed に pin する（優先行が予算を食い潰す最悪ケースの保証）。
    _hc_line="  記録 $(printf 'あ%.0s' $(seq 1 60))"
    _hc_body=""; for _i in $(seq 1 400); do _hc_body="$_hc_body$_hc_line $_i"$'\n'; done
    _WIP_REM="$WIP_PLAN_U16"; _WIP_LEFT=6
    _wip_hardcap "$_hc_body"
    _hc_u16="$(_wip_u16len "$_WIP_OUT")"
    if [ "$_WIP_CAPPED" -gt 0 ] && [ "$_hc_u16" -le "$WIP_HARDCAP_U16" ] \
        && grep -q '予算到達により以降 [0-9][0-9]* 行省略（全件: ' <<<"$_WIP_OUT"; then
        echo "ok: hard-cap: 予算超過 body を $WIP_HARDCAP_U16 u16 以下へ切り詰め + 置換行（切詰 $_WIP_CAPPED 行 / after=$_hc_u16 u16）"
    else
        echo "FAIL: hard-cap: 切詰め/置換行を期待したが不一致（capped=$_WIP_CAPPED after=$_hc_u16）" >&2; st_fail=1
    fi
    # teeth: 予算内 body では発火しない（無条件切詰め mutation を RED 化）。
    _wip_hardcap "  短い本文行"$'\n'"  もう 1 行"
    if [ "$_WIP_CAPPED" -eq 0 ] && [ "$_WIP_OUT" = "  短い本文行"$'\n'"  もう 1 行" ]; then
        echo "ok: hard-cap 系統に歯あり（予算内 body は無改変・未発火）"
    else
        echo "FAIL: hard-cap: 予算内 body を改変した（capped=$_WIP_CAPPED）: [$_WIP_OUT]" >&2; st_fail=1
    fi
    # floor: 予算を使い果たしても表示 N は $WIP_FLOOR_MIN 行未満へ落とさない（■3 floor 契約）。
    _WIP_REM=1; _WIP_LEFT=6
    _fl_n="$(_wip_plan_n 24000 200)"
    if [ "$_fl_n" -ge "$WIP_FLOOR_MIN" ]; then echo "ok: floor: 予算枯渇でも N=$_fl_n（>= $WIP_FLOOR_MIN 行）"
    else echo "FAIL: floor: N=$_fl_n が $WIP_FLOOR_MIN 行未満へ落ちた" >&2; st_fail=1; fi
    # 優先行は N 枠を消費せず全保持され、非優先行だけが省略行へ畳まれる（trim 本体の単体 pin）。
    _tb_body="  滞留 A"$'\n'"  rec 1"$'\n'"  rec 2"$'\n'"  rec 3"$'\n'"  🔔 呼び鈴 B"
    _tb_out="$(_wip_trim_block "$_tb_body" 1 'CMD --x')"
    if grep -q '滞留 A' <<<"$_tb_out" && grep -q '呼び鈴 B' <<<"$_tb_out" \
        && grep -qF '  … 残り 2 行を省略・全件: CMD --x' <<<"$_tb_out" && ! grep -q 'rec 3' <<<"$_tb_out"; then
        echo "ok: trim: 優先行(滞留/呼び鈴)は N 枠外で全保持・非優先の余剰 2 行が省略行へ畳まれた"
    else
        echo "FAIL: trim: 優先行保持 + 省略行(残り 2 行)を期待したが不一致: [$_tb_out]" >&2; st_fail=1
    fi

    # ── 節生存（acceptance 3）: 優先行主体の過負荷でも節見出しが 1 つも消えない ─────────────────
    # ★実 live 形を模す: 配送観測の便 record 行は閾値未満の通常行でさえ「[滞留]」を含む＝節が丸ごと優先クラスに
    #   なる。この regime では N 枠の trim が 1 行も畳めず、削減の全負荷が hard-cap に落ちる。末尾一括切りだと
    #   後半の節が **見出しごと** 消えるので、ここで「全節見出し実在 + 各節が本文 1 行以上か省略行を持つ」を pin する。
    #   bats 側の追加 test は ■6 で 4 本（T1-T4）に固定されており、この regime は関数単体でしか踏めない。
    _sv_body="=== [orchestrator/SessionStart] 仕掛かり自動表示（self-test 合成） ==="$'\n\n'
    for _i in 1 2 3 4 5; do
        _sv_body="$_sv_body── ($_i) 合成節 $_i（self-test 過負荷・優先行主体） ──"$'\n'
        for _j in $(seq 1 60); do
            _sv_body="$_sv_body$(printf '    便 SVREC%03d 宛先 admin [滞留] age %d 分（閾値 30 分 未満＝呼び鈴 point 未達）記録の詳細説明' "$_j" "$_j")"$'\n'
        done
        _sv_body="$_sv_body"$'\n'
    done
    _wip_hardcap "$_sv_body"
    _sv_u16="$(_wip_u16len "$_WIP_OUT")"
    _sv_sec=0; _sv_bad=0; _sv_n=0
    while IFS= read -r _sv_l; do
        case "$_sv_l" in
            "── "*)
                [ "$_sv_sec" -gt 0 ] && [ "$_sv_n" -eq 0 ] && _sv_bad=$(( _sv_bad + 1 ))
                _sv_sec=$(( _sv_sec + 1 )); _sv_n=0 ;;
            "==="*|"") ;;
            *) _sv_n=$(( _sv_n + 1 )) ;;
        esac
    done <<<"$_WIP_OUT"
    [ "$_sv_sec" -gt 0 ] && [ "$_sv_n" -eq 0 ] && _sv_bad=$(( _sv_bad + 1 ))
    if [ "$_WIP_CAPPED" -gt 0 ] && [ "$_sv_u16" -le "$WIP_HARDCAP_U16" ] \
        && [ "$_sv_sec" -eq 5 ] && [ "$_sv_bad" -eq 0 ]; then
        echo "ok: hard-cap 節生存: 優先行主体の過負荷でも全 5 節見出しが残り各節が本文/省略行を保持（after=$_sv_u16 u16・切詰 $_sv_bad 空節 / $_WIP_CAPPED 行）"
    else
        echo "FAIL: hard-cap 節生存: 節見出し消失 or 空節 or 予算超過（見出し=$_sv_sec 空節=$_sv_bad after=$_sv_u16 capped=$_WIP_CAPPED）" >&2; st_fail=1
    fi

    # ── 非一様密度（行長比 按分の破綻を RED 化）─────────────────────────────────────────────
    # latin 濃い行と 日本語 + astral（1 文字 = 2 u16）濃い行を混ぜ、順序を入れ替えた 2 通りで cap 以下を pin する。
    # 「総 u16 を行長比で按分する」実装だと密度が偏った側で予算保証が fail-open する（行別 u16 実測が必要）。
    _nu_a=""; _nu_b=""
    for _i in $(seq 1 90); do
        _nu_a="$_nu_a$(printf '  plain-latin record row %03d :: xyzxyz-plain-latin-padding-row-xyzxyz-plain-latin-padding-row' "$_i")"$'\n'
        _nu_b="$_nu_b  🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩🧩 astral と日本語が濃い記録行 $_i"$'\n'
    done
    _nu_fail=0
    for _nu_body in "$_nu_a$_nu_b" "$_nu_b$_nu_a"; do
        _wip_hardcap "$_nu_body"
        _nu_u16="$(_wip_u16len "$_WIP_OUT")"
        if [ "$_nu_u16" -gt "$WIP_HARDCAP_U16" ]; then
            _nu_fail=1; echo "FAIL: hard-cap 非一様密度: after=$_nu_u16 u16 が cap $WIP_HARDCAP_U16 を超過（按分推定の破綻）" >&2; st_fail=1
        fi
    done
    [ "$_nu_fail" -eq 0 ] && echo "ok: hard-cap 非一様密度: latin 濃い / astral+日本語 濃い の混在 body をどちらの順序でも cap 以下（行別 u16 実測）"

    # ── 優先クラス判定を **実 producer 文字列**で表照合（合成の「滞留 A」だけでは vacuous）───────
    _pc_fail=0
    _pc_prio=(
        "  [SUSPECT] orch-aaaa    窓消失 × CLOSED不在（commit=2・delivery したが未終端の疑い）  branch=b quiet=3h"
        "  [SALVAGE] orch-bbbb    窓消失 × CLOSED不在 × commit=0（degraded 濃厚・要 salvage 介入）  branch=b quiet=9h"
        "    便 orch-cccc   宛先 admin  [滞留] age 42 分(>閾値 30)・宛先窓 admin:admin live"
        "      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go）｜根拠: 滞留 42 分 > 閾値 30 分"
        "  [COMPLETENESS-RED] 分類合計 3 ≠ open 総数 4（分類漏れ＝要調査）"
        "[RERATIFY-TRIPWIRE] 死角クラス re-ratify 候補:2（threshold=30d・push なし・write ゼロ）"
        "  集計: delivered(推論)=1 undelivered(滞留)=2 呼び鈴提案=1"
    )
    _pc_norm=(
        "  記録 orch-dddd SHARED ラベル付きの通常 record 行（優先ではない）"
        "  記録 orch-eeee REQUIRED 項目を含む通常 record 行（優先ではない）"
        "  記録 orch-ffff DEFERRED 状態の通常 record 行（優先ではない）"
    )
    for _pc_l in "${_pc_prio[@]}"; do
        if ! _wip_is_priority "$_pc_l"; then
            _pc_fail=1; echo "FAIL: 優先クラス: 実 producer の actionable 行を非優先と判定: [$_pc_l]" >&2; st_fail=1
        fi
    done
    for _pc_l in "${_pc_norm[@]}"; do
        if _wip_is_priority "$_pc_l"; then
            _pc_fail=1; echo "FAIL: 優先クラス: 通常 record 行を優先と誤検知: [$_pc_l]" >&2; st_fail=1
        fi
    done
    [ "$_pc_fail" -eq 0 ] && echo "ok: 優先クラス: 実 producer の 7 行を PRIO・SHARED/REQUIRED/DEFERRED を含む 3 行を NORM と分類（大小無視 + RED の token 境界）"
    # rank 分割の表照合（review major-1/2）: rank-A = 総覧・呼び鈴系のみ / rank-B（[滞留] 等）は rank-A でない。
    _ra_fail=0
    for _pc_l in "  集計: delivered(推論)=1 undelivered(滞留)=2 呼び鈴提案=1" \
                 "      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go）" \
                 "  [COMPLETENESS-RED] 分類合計 3 ≠ open 総数 4" \
                 "[RERATIFY-TRIPWIRE] 死角クラス re-ratify 候補:2"; do
        _wip_is_rank_a "$_pc_l" || { _ra_fail=1; echo "FAIL: rank-A: 総覧/呼び鈴系を rank-A と判定しなかった: [$_pc_l]" >&2; st_fail=1; }
    done
    for _pc_l in "    便 orch-cccc 宛先 admin  [滞留] age 42 分(>閾値 30)" \
                 "  [SUSPECT] orch-aaaa 窓消失 × CLOSED不在" \
                 "    便 orch-dddd [滞留] age 5 分（閾値 30 分 未満＝呼び鈴 point 未達）"; do
        if _wip_is_rank_a "$_pc_l"; then
            _ra_fail=1; echo "FAIL: rank-A: 大量発生する record 系（rank-B）を rank-A と誤判定: [$_pc_l]" >&2; st_fail=1
        fi
        _wip_is_priority "$_pc_l" || { _ra_fail=1; echo "FAIL: rank-B: 優先クラスから漏れた（rank 分割で集合が変わった）: [$_pc_l]" >&2; st_fail=1; }
    done
    [ "$_ra_fail" -eq 0 ] && echo "ok: rank 分割: 集計/🔔/RED/TRIPWIRE を rank-A・[滞留]/[SUSPECT]/「呼び鈴 point 未達」を rank-B（優先集合は不変）"

    # ── hard-cap rank-A 生存（review major-1/2）─────────────────────────────────────────────
    # ★実 producer 形を模す: 配送観測 block は **全行が [滞留]（＝rank-B 優先）** で、最も actionable な
    #   🔔 呼び鈴 / `── 集計:` を **block 末尾**へ置く。この regime では per-block trim は 1 行も畳めず
    #   （全行が優先クラス）、削減の全負荷が hard-cap に落ちる。優先行を一律 index 順で採ると先頭の record 行が
    #   節の取り分を食い切り、末尾の rank-A が構造的に必ず落ちる（修正前の実測: 🔔 0 件 / 集計 0 件）。
    _ra_pad='便が滞留している宛先の記録であり表示予算を消費するための埋草テキストである'
    _ra_body="=== [orchestrator/SessionStart] 仕掛かり自動表示（self-test 合成 rank-A 生存） ==="$'\n\n'
    for _ra_s in 1 2 3 4 5 6; do
        _ra_body="$_ra_body── ($_ra_s) 合成節 $_ra_s（配送観測 形・全行 rank-B + 末尾 rank-A） ──"$'\n'
        for _i in $(seq 1 120); do
            _ra_body="$_ra_body$(printf '    便 SEC%dREC%03d 宛先 admin [滞留] age %d 分(>閾値 30)%s' "$_ra_s" "$_i" "$_i" "$_ra_pad")"$'\n'
        done
        for _i in 1 2 3; do
            _ra_body="$_ra_body$(printf '      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go）｜根拠: SEC%d-%d' "$_ra_s" "$_i")"$'\n'
        done
        _ra_body="$_ra_body$(printf '  ── 集計: delivered(推論)=1 undelivered(滞留)=120 呼び鈴提案=3（SEC%d）' "$_ra_s")"$'\n\n'
    done
    _wip_hardcap "$_ra_body"
    _ra_u16="$(_wip_u16len "$_WIP_OUT")"
    _ra_bell="$(grep -c '🔔' <<<"$_WIP_OUT")"; _ra_sum="$(grep -c '── 集計:' <<<"$_WIP_OUT")"
    if [ "$_WIP_CAPPED" -gt 0 ] && [ "$_ra_u16" -le "$WIP_HARDCAP_U16" ] \
        && [ "$_ra_bell" -eq 18 ] && [ "$_ra_sum" -eq 6 ]; then
        echo "ok: hard-cap rank-A 生存: 全行 [滞留] + 末尾 🔔3/集計1 × 6 節でも 🔔 18 件・集計 6 件を全保持（after=$_ra_u16 u16・切詰 $_WIP_CAPPED 行）"
    else
        echo "FAIL: hard-cap rank-A 生存: 🔔=$_ra_bell（期待 18）集計=$_ra_sum（期待 6）after=$_ra_u16 capped=$_WIP_CAPPED" >&2; st_fail=1
    fi
    # teeth（非vacuity）: rank-A 先取り（pass 0）を無効化する mutation で上の assert が RED 化する。
    _ra_save="$WIP_RANKA_MAX"; WIP_RANKA_MAX=0
    _wip_hardcap "$_ra_body"
    _ra_bell_m="$(grep -c '🔔' <<<"$_WIP_OUT")"; _ra_sum_m="$(grep -c '── 集計:' <<<"$_WIP_OUT")"
    WIP_RANKA_MAX="$_ra_save"
    if [ "$_ra_bell_m" -lt 18 ] || [ "$_ra_sum_m" -lt 6 ]; then
        echo "ok: hard-cap rank-A 系統に歯あり（先取り上限 0 行の mutation で 🔔 $_ra_bell_m/18・集計 $_ra_sum_m/6 へ欠落＝RED 化）"
    else
        echo "FAIL: hard-cap rank-A 系統に歯が無い（先取りを外しても 🔔 $_ra_bell_m・集計 $_ra_sum_m が全保持された）" >&2; st_fail=1
    fi

    # ── 1 節 2 block × hard-cap 発火時の「省略件数 == 実省略行数」（acceptance 2・review major-1/3）──────
    # ★実形の第5節は 1 節に per-block 省略行が 2 本並ぶ（orch-stale-scan block + orch_slate block）。drop 集計が
    #   節単位だと節全体の drop が両方の省略行へ **それぞれ全額** 加算され、申告件数が実省略行数と一致しなくなる。
    #   T1 の件数一致 assert は hard-cap 未発火 regime しか通らないため、この regime の歯はここにしか無い。
    _2b_pad='仕掛かり記録の詳細説明テキストであり表示予算を消費するための埋草である'
    _2b_body="=== [orchestrator/SessionStart] 仕掛かり自動表示（self-test 合成 1 節 2 block） ==="$'\n\n'
    _2b_body="$_2b_body── (5) 合成節（per-block 省略行 2 本・hard-cap 二重加算の RED 化） ──"$'\n'
    for _i in $(seq 1 100); do _2b_body="$_2b_body$(printf '  BLKA%03d %s%s%s' "$_i" "$_2b_pad" "$_2b_pad" "$_2b_pad")"$'\n'; done
    _2b_body="$_2b_body  … 残り 10 行を省略・全件: CMD-A"$'\n\n'
    for _i in $(seq 1 100); do _2b_body="$_2b_body$(printf '  BLKB%03d %s%s%s' "$_i" "$_2b_pad" "$_2b_pad" "$_2b_pad")"$'\n'; done
    _2b_body="$_2b_body  … 残り 20 行を省略・全件: CMD-B"$'\n'
    _wip_hardcap "$_2b_body"
    _2b_sa="$(grep -c 'BLKA' <<<"$_WIP_OUT" || true)"; _2b_sb="$(grep -c 'BLKB' <<<"$_WIP_OUT" || true)"
    _2b_oa="$(sed -n 's/.*残り \([0-9][0-9]*\) 行を省略・全件: CMD-A.*/\1/p' <<<"$_WIP_OUT")"
    _2b_ob="$(sed -n 's/.*残り \([0-9][0-9]*\) 行を省略・全件: CMD-B.*/\1/p' <<<"$_WIP_OUT")"
    # 未所有 drop 用の新規行（本 fixture では 0 件が正・出たら件数を総和へ含めて照合する）。
    _2b_ox="$(sed -n 's/.*残り \([0-9][0-9]*\) 行を省略・全件: bash .*/\1/p' <<<"$_WIP_OUT")"; : "${_2b_ox:=0}"
    case "$_2b_oa$_2b_ob" in ''|*[!0-9]*) _2b_oa=-1; _2b_ob=-1 ;; esac
    # 非vacuity: hard-cap が実際に発火し（capped>0）かつ 両 block が drop を負っている（both>元値）こと。
    if [ "$_WIP_CAPPED" -gt 0 ] && [ "$_2b_oa" -gt 10 ] && [ "$_2b_ob" -gt 20 ] \
        && [ "$(( _2b_sa + _2b_oa ))" -eq 110 ] && [ "$(( _2b_sb + _2b_ob ))" -eq 120 ] \
        && [ "$(( _2b_oa + _2b_ob + _2b_ox ))" -eq "$(( 230 - _2b_sa - _2b_sb ))" ]; then
        echo "ok: hard-cap 件数整合: 1 節 2 block でも省略件数は block 所有で加算（A: $_2b_sa+$_2b_oa=110 / B: $_2b_sb+$_2b_ob=120・未所有 $_2b_ox）"
    else
        echo "FAIL: hard-cap 件数整合: 1 節 2 block で申告件数が実省略行数と不一致（A: shown=$_2b_sa omit=$_2b_oa / B: shown=$_2b_sb omit=$_2b_ob / 未所有=$_2b_ox / capped=$_WIP_CAPPED）" >&2; st_fail=1
    fi

    # ── 配線 assert（review major-2）: hard-cap が emit 経路へ実際に繋がっている ─────────────────────
    # ★bats（T1/T3）の合成負荷は per-block trim が畳み切るので hard-cap を発火させない＝配線を外した mutant
    #   （`[ "$WIP_TRIM" -eq 1 ] && _wip_hardcap ...` を到達不能化）でも e2e が 1 byte も変わらず素通りする
    #   （実測）。よってここで **優先行主体の stub 6 本**（per-block trim が 1 行も畳めない live 形）を実 emit
    #   経路へ通し、hard-cap の発火と stdout 先頭の警告行を pin する＝配線ごと歯を持たせる。
    mkdir -p "$st_tmp/wire/lib"
    cat > "$st_tmp/wire/prio-stub.sh" <<'WIREEOF'
#!/usr/bin/env bash
tag="$(basename "$0" .sh)"
pad='便が滞留している宛先の記録であり表示予算を消費するための埋草テキストである'
i=1
while [ $i -le 200 ]; do
    printf '  [滞留] %s-%03d %s%s\n' "$tag" "$i" "$pad" "$pad"
    i=$((i + 1))
done
# 実 producer と同型に rank-A（🔔 呼び鈴 / ── 集計:）を **block 末尾**へ置く（review major-1/2 の regime）。
printf '      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go）｜根拠: %s-A\n' "$tag"
printf '      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go）｜根拠: %s-B\n' "$tag"
printf '  ── 集計: delivered(推論)=1 undelivered(滞留)=200 呼び鈴提案=2（%s）\n' "$tag"
WIREEOF
    chmod +x "$st_tmp/wire/prio-stub.sh"
    for _w in orch-dispatch orch-degraded-watch orch-handoff-scan orch-delivery-observe orch-stale-scan; do
        cp "$st_tmp/wire/prio-stub.sh" "$st_tmp/wire/$_w.sh"
    done
    cp "$st_tmp/wire/prio-stub.sh" "$st_tmp/wire/lib/orch_slate.sh"
    DISPATCH="$st_tmp/wire/orch-dispatch.sh";        DEGRADED="$st_tmp/wire/orch-degraded-watch.sh"
    HANDOFF="$st_tmp/wire/orch-handoff-scan.sh";     DELIVERY="$st_tmp/wire/orch-delivery-observe.sh"
    RERATIFY="$st_tmp/wire/orch-stale-scan.sh";      SLATE_SURFACE="$st_tmp/wire/lib/orch_slate.sh"
    # command substitution = subshell ゆえ _emit_workinprogress の cd / global 汚染を親へ持ち込まない。
    _wire_out="$(_emit_workinprogress "$st_tmp/anchor")"
    _wire_head="$(head -n 1 <<<"$_wire_out")"
    _wire_u16="$(_wip_u16len "$(tail -n +2 <<<"$_wire_out")")"   # 警告行を除いた body が cap 以下
    # ★rank-A 生存も **実 emit 経路**で見る（review major-1/2）: stub は 6 本とも block 末尾に 🔔 2 行 + 集計 1 行を
    #   置くので、健全形では 🔔 12 件・集計 6 件が丸ごと残る（落ちるのは rank-B の [滞留] record 行だけ）。
    _wire_bell="$(grep -c '🔔' <<<"$_wire_out")"; _wire_sum="$(grep -c '── 集計:' <<<"$_wire_out")"
    if [ "$_wire_u16" -le "$WIP_HARDCAP_U16" ] \
        && [[ "$_wire_head" == *"⚠ 警告: 表示予算"*"到達により末尾"*"行を切り詰めた"* ]] \
        && grep -q '予算到達により以降 [0-9][0-9]* 行省略（全件: ' <<<"$_wire_out" \
        && [ "$_wire_bell" -eq 12 ] && [ "$_wire_sum" -eq 6 ]; then
        echo "ok: 配線: 優先行主体 stub 6 本を実 emit 経路へ通し hard-cap が発火（stdout 先頭に警告行・body=$_wire_u16 u16・末尾 rank-A は 🔔 12/集計 6 を全保持）"
    else
        echo "FAIL: 配線: _emit_workinprogress の hard-cap 経路が不正（body=$_wire_u16 u16・🔔=$_wire_bell（期待 12）集計=$_wire_sum（期待 6）・head=[$_wire_head]）" >&2; st_fail=1
    fi
    # 配線 teeth（source 照合）: emit 本体の定義に _wip_hardcap 呼出しが字面で実在する（unwire を RED 化）。
    if declare -f _emit_workinprogress | grep -q '_wip_hardcap'; then
        echo "ok: 配線 teeth: _emit_workinprogress の定義に _wip_hardcap 呼出しが実在（unwire mutation を RED 化）"
    else
        echo "FAIL: 配線 teeth: _emit_workinprogress が _wip_hardcap を呼んでいない（配線切れ）" >&2; st_fail=1
    fi

    if [ "$st_fail" -eq 0 ]; then echo "workinprogress --self-test: PASS"; exit 0
    else echo "workinprogress --self-test: FAIL" >&2; exit 1; fi
fi

# === --full: 表示層 trim を外して全件を出す（省略行 / hard-cap の pointer が指す経路・sc-v0ao） ===
# self-scope / cwd 第2軸 / consult 第3軸は素通ししない（gate は trim と直交で不変）。手打ち起動（tty）では
# stdin JSON が無いので _extract_cwd が空を返し $PWD へ落ちる（lib の tty guard・block しない）。
if [ "${1:-}" = "--full" ]; then
    WIP_TRIM=0
fi

# === self-scope: 非 orchestrator session は無出力で exit 0（no-op） ===
hook_cwd="$(_extract_cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
if ! _is_orch_session "$hook_cwd"; then
    exit 0   # 他 project / 判定不能 session へは一切表示しない（誤注入ゼロ）
fi

# === cwd 第2軸（orch-1r7 G3）: orch worktree（自己開発 worker cell）には仕掛かり一覧を表示しない ===
if _is_worktree_cwd "$hook_cwd"; then
    exit 0
fi

# === consult 窓 第3軸（orch-z4z7 / orch-qcqz Finding H 同型 leak・fence7）: consult 窓へは仕掛かり一覧を注入しない ===
# consult は anchor 同居（cwd=anchor）ゆえ self-scope(orch)と cwd 第2軸を素通りするが、別 role（read-only 相談役）で
# gate-pending / degraded / handoff / 配送観測の仕掛かり表示は誤配（orchestrator 文脈漏れ）。spec-inject.sh:195 と
# 同一配置で全 4 節を一括 gating する（第4節限定に置かない）。判定は共有 lib の _is_consult_window（qcqz PR#87 で
# 既 land・orch_session.sh は touch しない）。取得不能（tmux 不在 / $TMUX 未設定 / 窓名取得不能）は非 consult 扱い＝
# 注入継続（fail-safe・b-4「不能→no-op」は既存 anchor 挙動を壊す誤り）。
if _is_consult_window; then
    exit 0
fi

# === orchestrator anchor session: 仕掛かりを自動表示（fail-open） ===
_emit_workinprogress "$hook_cwd"

exit 0

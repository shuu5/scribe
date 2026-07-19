#!/usr/bin/env bash
# orch_session.sh — orchestrator session の self-scope / 台帳 walk-up 共有 shell lib（bd orch-t9z）
#
# 役割: SessionStart hook 群（session-start-spec-inject.sh / session-start-workinprogress.sh）と
#   read-only watcher（orch-degraded-watch.sh）が verbatim 重複させていた「cwd から上方向へ walk-up して
#   最初の .beads/metadata.json の dolt_database を読み self-scope（当該 session が orchestrator か）を判定する」
#   5 helper を**単一 SSOT**へ抽出したもの。3 consumer が `source` でこの lib を consume する（orch-7py gate
#   follow-up・wf_2e14d02c upheld minor×2 の恒久解）。
#
# 抽出した helper（consumer は必要なものだけ使う）:
#   _extract_cwd            — hook stdin JSON から cwd を抽出（jq → sed フォールバック・tty なら読まない）。
#   _json_is_valid <meta>   — metadata.json が妥当 JSON かを jq/python3/node の OR 合成で肯定確認。
#   _ledger_dolt_database <cwd>  — walk-up で .beads/metadata.json の dolt_database を解決（sed 経路は
#                                  _json_is_valid gate 済み）。見つからない/読めない/不正 JSON は空文字。
#   _is_orch_session <cwd>  — 当該 session が orchestrator か（dolt_database == $SELF_PREFIX 完全一致）。
#   _is_worktree_cwd <cwd>  — cwd 第2軸（orch-1r7 G3）: cwd が `.worktrees/` / `.claude/worktrees/` 配下か。
#   _is_consult_window      — 第3軸（orch-qcqz）: tmux window 名が consult-* prefix か（scribe-spawn --consult 弁別）。
#                             取得不能（tmux 不在 / $TMUX 未設定 / 窓名取得失敗）は非 consult（false）＝consumer 側で
#                             inject/発火を継続する fail-safe（「不能→no-op」は既存 anchor 挙動を壊す誤り・b-4）。
#
# additive 契約（orch-qcqz）: `_is_consult_window` は既存 5 helper の契約・挙動を一切変えずに **追加**したもの。
#   spec-inject が self-scope(orch) → cwd 第2軸(worktree 除外) の後に第3 gate として consume する。既存 consumer
#   （workinprogress / degraded-watch / vo2 統一 5 script）は本 helper を呼ばないので無影響。
#
# SELF_PREFIX 契約（重要）: `_is_orch_session` は global `SELF_PREFIX`（自台帳 prefix = "orch"）を**caller が
#   定義したもの**として参照する（dynamic scoping）。本 lib は SELF_PREFIX を**定義しない**——各 consumer が
#   従来どおり自身の `SELF_PREFIX="orch"` を持ち、それを共有する（CLAUDE.md「hardcode 集約の refactor は別 bead」
#   ＝本 bead は walk-up helper の dedup に限定し SELF_PREFIX hardcode の集約はしない）。consumer は
#   `_is_orch_session` を呼ぶ前に SELF_PREFIX を定義しておくこと（本 lib の `--self-test` は自前で定義する）。
#
# Python orch_session.py との関係（別 SSOT・意図的相違）: guard 群（bd/file/bash-file-write-guard.py）が import する
#   Python 版 `lib/orch_session.py` は present-but-unreadable（metadata 在るが parse 失敗）を **fail-closed**
#   （moat 維持・作動継続）に畳むが、本 shell lib は SessionStart hook の cosmetic な surface が主 consumer ゆえ
#   **fail-open**（無注入・誤注入ゼロ優先）に畳む。この fail-open/closed 相違は意図的で、両者を統一しない
#   （orch-t9z は「shell 側だけで shared lib へ抽出」＝Python 版に触れない）。walk-up 機構・SELF_PREFIX 値・
#   sed/jq 抽出ロジック自体は Python 版と同一方向。
#
# `_json_is_valid` の安全側（load-bearing・guard parity）: sed フォールバックは正規表現で
#   `"dolt_database":"orch"` トークンを 1 行抽出するだけで JSON 妥当性を検査しない。ゆえに
#   `{ "dolt_database": "orch", THIS IS BROKEN`（破損しているが orch トークンを含む）metadata で、gate 無しだと
#   shell だけが「orch」と誤解決してしまう。よって sed 抽出前に metadata 全体の JSON 妥当性を検査し、不正なら
#   トークンを不採用（空 db）にする。検査器は jq/python3/node を順に試し**いずれか 1 つでも妥当を肯定確認できたら
#   妥当**とする（OR 合成）——『jq は在るが壊れている/exit 1 を返す』hazard で jq の偽陰性が妥当 JSON を誤って
#   不採用にする回帰を python3/node が救う。どの検査器も妥当を肯定できない場合のみ『不正/判定不能』へ倒す。
#   ★orch-degraded-watch.sh はこの gate を欠いた drift（旧 _resolve_dolt_database）を抱えていた＝本 lib を
#     consume することで drift が解消し、破損 orch-token metadata での誤 self-scope（誤台帳起動）を fail-closed で弾く。
#
# 空 db（判定不能）の consumer 側の落ち先（同一挙動・別 framing）:
#   - spec-inject / workinprogress : `_is_orch_session` が false → 無注入で exit 0（no-op・fail-open・誤注入ゼロ）。
#   - degraded-watch               : DB != "orch" → self-scope refuse（exit 非0・fail-closed・誤台帳起動を弾く）。
#   どちらも各 consumer の安全側へ倒れる（判定不能を「orch とみなして発火」しない）。
#
# never-die 契約: 全 helper は filesystem stat/read と外部コマンドの 2>/dev/null のみで、例外で die しない
#   （判定不能 → 空文字/false へ degrade）。`set -u` 下（degraded-watch は `set -uo pipefail`）で source/呼出しても
#   安全なよう、位置引数は `${1:-}` で受ける。
#
# source 方法（consumer は実 script 位置 = BASH_SOURCE 相対で解決すること）:
#   spec-inject / workinprogress（scripts/hooks/）: `. "$_SCRIPT_DIR/lib/orch_session.sh"`
#   degraded-watch（scripts/）                    : `. "$_SCRIPT_DIR/hooks/lib/orch_session.sh"`
#   ★CLAUDE_PLUGIN_ROOT ではなく BASH_SOURCE 相対で解決するのは、bats / --self-test が
#     CLAUDE_PLUGIN_ROOT を fixture へ向けても実 script 位置は実 repo を指すため、fixture を書き換えずに
#     実 lib を確実に見つけられるから（既存 bats fixture 無改変で green を保つ）。
#
# 検証: 本 lib の `--self-test`（直接実行時のみ・hermetic・fail-closed）+ 3 consumer の bats/--self-test
#   （spec-inject-cwd-axis / session-start-workinprogress / fleet-degraded-watch 全 green＝意味論不変）。

# --- stdin の hook JSON から cwd を抽出（jq → sed フォールバック）。tty なら読まない（block 回避） ---
# 全 hook の stdin JSON 共通フィールドに cwd が含まれる。抽出不能なら無出力（consumer 側で $PWD フォールバック）。
_extract_cwd() {
    [ -t 0 ] && return 0
    local input cwd
    input="$(cat 2>/dev/null)"
    [ -z "$input" ] && return 0
    if command -v jq >/dev/null 2>&1; then
        cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
    fi
    if [ -z "${cwd:-}" ]; then
        cwd="$(printf '%s' "$input" \
            | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n1)"
    fi
    [ -n "${cwd:-}" ] && printf '%s' "$cwd"
    return 0
}

# --- metadata.json が妥当 JSON か検査（guard parity: 不正 JSON → 判定不能）。詳細は header の load-bearing 節 ---
_json_is_valid() {
    local meta="${1:-}"
    if command -v jq >/dev/null 2>&1; then
        jq -e . "$meta" >/dev/null 2>&1 && return 0
    fi
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$meta" >/dev/null 2>&1 \
            && return 0
    fi
    if command -v node >/dev/null 2>&1; then
        node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$meta" >/dev/null 2>&1 \
            && return 0
    fi
    return 1   # どの検査器も妥当を肯定できない → 判定不能（consumer の安全側へ degrade）
}

# --- .beads/metadata.json の dolt_database を walk-up で解決（session self-scope・bd 自身の台帳解決と同 walk-up） ---
# cwd から上方向へ最初に見つかる .beads/metadata.json の dolt_database を読む（subprocess 非依存）。
# 見つからない/読めない/不正 JSON/欠落は空文字を返す（判定不能）。例外で die しない（stat/read のみ・
# jq 不在は _json_is_valid gate 済み sed フォールバック）。
_ledger_dolt_database() {
    local dir meta db arg
    arg="${1:-}"
    dir="$arg"
    [ -n "$dir" ] || dir="$PWD"
    # 相対 → 絶対（cd 失敗時は与えられた値のまま walk・最終的に判定不能へ degrade）。
    dir="$(cd "$dir" 2>/dev/null && pwd)" || dir="$arg"
    while [ -n "$dir" ]; do
        meta="$dir/.beads/metadata.json"
        if [ -f "$meta" ]; then
            db=""
            if command -v jq >/dev/null 2>&1; then
                db="$(jq -r '.dolt_database // empty' "$meta" 2>/dev/null)"
            fi
            if [ -z "$db" ]; then
                # sed フォールバック（jq 失敗/不在）経路。破損 JSON（orch トークンを含んでも）は
                # _json_is_valid gate で不採用にし『metadata 全体が妥当 JSON』のときのみトークンを採用する。
                if _json_is_valid "$meta"; then
                    db="$(sed -n 's/.*"dolt_database"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta" 2>/dev/null | head -n1)"
                fi
            fi
            printf '%s' "$db"
            return 0
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    return 0
}

# --- session self-scope 判定: 当該 session が orchestrator session か（dolt_database == $SELF_PREFIX 完全一致） ---
# ★SELF_PREFIX は caller が定義した global を参照する（header の SELF_PREFIX 契約）。
_is_orch_session() {
    local db
    db="$(_ledger_dolt_database "${1:-}" 2>/dev/null)"
    [ "$db" = "$SELF_PREFIX" ]   # 完全一致（前方一致 orchX は弾く）
}

# --- cwd 第2軸（orch-1r7 G3）: hook cwd が worktree 配下か（self-scope と直交・SCRIBE_ROLE 非依存） ---
# `.worktrees/`（scribe/cld worktree）または `.claude/worktrees/`（CC-native worktree）配下なら worktree。
# anchor（非 worktree）だけ発火させるための軸。raw cwd の glob 判定。
_is_worktree_cwd() {
    case "${1:-}" in
        */.worktrees/*|*/.claude/worktrees/*) return 0 ;;
        *) return 1 ;;
    esac
}

# --- 第3軸（orch-qcqz）: consult 窓判定（tmux window 名が consult-* prefix か・self-scope/cwd 軸と直交） ---
# scriptorium anchor 発の scribe-spawn --consult は anchor 同居ゆえ self-scope(orch)と cwd 第2軸を素通りする
# （consult 窓の cwd = anchor 自身）。だが consult は別 role（read-only 相談役）で top-layer primer を注入すると
# orchestrator 文脈が漏れる（orch-qcqz Finding）。env SCRIBE_ROLE は G1 の settings.json project 層 none が
# 子プロセスへ優先適用され潰されるため弁別に使えない（verified）。よって tmux window 名（scribe-spawn.sh の
# consult-* 命名規約）を signal にする。
#   取得規律: 必ず `-t "$TMUX_PANE"` 明示（背景 spawn 中に human が別窓 focus すると bare 形は誤窓名を返す・
#     verified hazard）。command -v tmux と $TMUX 存在を先に gate し、非0 exit / 空出力 / tmux 不在 / 窓名取得不能は
#     **非 consult 扱い（false）**＝consumer 側で inject/発火を継続する fail-safe（b-4・「不能→no-op」は誤り）。
#   既知限界（low・許容）: automatic-rename / 手動 rename で false-negative しうるが安全側（over-inject・operative
#     契約は spawn prompt が担保）。fleet-monitor が consult-* 完全一致に既依存＝同前提を踏襲。
_is_consult_window() {
    [ -n "${TMUX:-}" ] || return 1               # tmux 外 session → 非 consult（fail-safe: inject 継続）
    command -v tmux >/dev/null 2>&1 || return 1  # tmux 不在 → 非 consult（fail-safe）
    local wname
    wname="$(tmux display-message -p -t "${TMUX_PANE:-}" '#W' 2>/dev/null)" || return 1
    [ -n "$wname" ] || return 1                  # 窓名取得不能 → 非 consult（fail-safe）
    case "$wname" in
        consult-*) return 0 ;;
        *) return 1 ;;
    esac
}

# === --self-test: 直接実行時のみの hermetic 自己完結テスト（fail-closed・orch-t9z） ===
# source 時（BASH_SOURCE[0] != $0）はこのブロックを skip する（consumer の $1 継承で誤発火しない）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" != "--self-test" ]; then
        echo "orch_session.sh は source して使う共有 lib です（--self-test で自己検証）。" >&2
        exit 0
    fi

    SELF_PREFIX="orch"   # self-test は caller を持たないので自前で定義（header の SELF_PREFIX 契約）。
    st_fail=0
    st_tmp="$(mktemp -d -t orch-session-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    # --- 台帳 fixture ---
    mkdir -p "$st_tmp/anchor/.beads";  printf '{"dolt_database":"orch"}' > "$st_tmp/anchor/.beads/metadata.json"
    mkdir -p "$st_tmp/foreign/.beads"; printf '{"dolt_database":"un"}'   > "$st_tmp/foreign/.beads/metadata.json"
    mkdir -p "$st_tmp/anchor/.worktrees/spawn/wt"
    mkdir -p "$st_tmp/anchor/.claude/worktrees/wt2"
    mkdir -p "$st_tmp/broken/.beads"; printf '{"dolt_database":"orch"'   > "$st_tmp/broken/.beads/metadata.json"  # 未閉じ = 破損
    mkdir -p "$st_tmp/nobeads"        # .beads 無し = 判定不能

    # --- _ledger_dolt_database ---
    [ "$(_ledger_dolt_database "$st_tmp/anchor")" = "orch" ] \
        && _ok "_ledger_dolt_database: anchor → orch" || _fail "_ledger_dolt_database: anchor → orch を期待"
    [ "$(_ledger_dolt_database "$st_tmp/foreign")" = "un" ] \
        && _ok "_ledger_dolt_database: foreign → un" || _fail "_ledger_dolt_database: foreign → un を期待"
    [ -z "$(_ledger_dolt_database "$st_tmp/nobeads")" ] \
        && _ok "_ledger_dolt_database: .beads 無し → 空（判定不能）" || _fail "_ledger_dolt_database: 空を期待"
    # worktree 配下の cwd は walk-up で anchor(orch)へ届く（台帳 self-scope は通過する＝cwd 軸で別途弾く設計）。
    [ "$(_ledger_dolt_database "$st_tmp/anchor/.worktrees/spawn/wt")" = "orch" ] \
        && _ok "_ledger_dolt_database: worktree 配下 → anchor へ walk-up し orch" \
        || _fail "_ledger_dolt_database: worktree walk-up → orch を期待"

    # --- _json_is_valid gate（drift fix の核心・load-bearing） ---
    _json_is_valid "$st_tmp/anchor/.beads/metadata.json" \
        && _ok "_json_is_valid: 妥当 JSON → 0" || _fail "_json_is_valid: 妥当 JSON → 0 を期待"
    if _json_is_valid "$st_tmp/broken/.beads/metadata.json"; then
        _fail "_json_is_valid: 破損 JSON → 非0 を期待したが 0"
    else
        _ok "_json_is_valid: 破損 JSON → 非0"
    fi
    # ★drift fix teeth: 破損 orch-token metadata は _json_is_valid gate で不採用 → 空 db（誤 self-scope しない）。
    #   （jq が在れば jq -r が破損で空を返し gate へ・jq 不在でも sed 前に gate が止める）。
    if [ -z "$(_ledger_dolt_database "$st_tmp/broken")" ]; then
        _ok "_ledger_dolt_database: 破損 orch-token → 空（_json_is_valid gate が誤 self-scope を防ぐ・drift fix）"
    else
        _fail "_ledger_dolt_database: 破損 orch-token → 空を期待（drift fix）が非空"
    fi

    # --- _is_orch_session ---
    _is_orch_session "$st_tmp/anchor"  && _ok "_is_orch_session: anchor → true" || _fail "_is_orch_session: anchor → true を期待"
    _is_orch_session "$st_tmp/foreign" && _fail "_is_orch_session: foreign → false を期待" || _ok "_is_orch_session: foreign → false"
    # 前方一致 orchX は完全一致で弾く。
    mkdir -p "$st_tmp/orch2/.beads"; printf '{"dolt_database":"orch2"}' > "$st_tmp/orch2/.beads/metadata.json"
    _is_orch_session "$st_tmp/orch2" && _fail "_is_orch_session: orch2（前方一致）→ false を期待" || _ok "_is_orch_session: orch2 → false（完全一致）"

    # --- _is_worktree_cwd ---
    _is_worktree_cwd "$st_tmp/anchor/.worktrees/spawn/wt" && _ok "_is_worktree_cwd: .worktrees/ → true" || _fail "_is_worktree_cwd: .worktrees/ → true を期待"
    _is_worktree_cwd "$st_tmp/anchor/.claude/worktrees/wt2" && _ok "_is_worktree_cwd: .claude/worktrees/ → true" || _fail "_is_worktree_cwd: .claude/worktrees/ → true を期待"
    _is_worktree_cwd "$st_tmp/anchor" && _fail "_is_worktree_cwd: anchor → false を期待" || _ok "_is_worktree_cwd: anchor → false"

    # --- _extract_cwd（stdin JSON） ---
    [ "$(printf '{"cwd":"/x/y"}' | _extract_cwd)" = "/x/y" ] \
        && _ok "_extract_cwd: JSON cwd 抽出" || _fail "_extract_cwd: /x/y 抽出を期待"

    # --- _is_consult_window（orch-qcqz 第3軸）: window 名 signal・取得不能は fail-safe(非 consult) ---
    # hazard-faithful stub tmux（M2 teeth）。`-t <pane>` 明示時のみ「その pane の窓名」= $STUB_WNAME を返す
    # （空なら非0=取得失敗を模す）。`-t <value>` 不在（bare 形 = mutation M2）は focused 別窓を模し非 consult 名
    # orchestrator を返す → -t "$TMUX_PANE" を落とすと consult 判定が焦点窓へ倒れ consult-* ケースが false へ落ちる
    # （-t 明示が verified hazard 対策として load-bearing であることを teeth に pin）。
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
    # TMUX 未設定 → tmux を呼ばず false（fail-safe: inject 継続）。
    ( unset TMUX; _is_consult_window ) \
        && _fail "_is_consult_window: TMUX 未設定 → false を期待" \
        || _ok "_is_consult_window: TMUX 未設定 → false(fail-safe)"
    # consult-* 窓 → true。
    ( export TMUX="/tmp/fake,1,0" TMUX_PANE="%9" PATH="$st_tmp/bin:$PATH" STUB_WNAME="consult-xyz"; _is_consult_window ) \
        && _ok "_is_consult_window: consult-* 窓 → true" \
        || _fail "_is_consult_window: consult-* 窓 → true を期待"
    # 非 consult 窓 → false。
    ( export TMUX="/tmp/fake,1,0" TMUX_PANE="%9" PATH="$st_tmp/bin:$PATH" STUB_WNAME="orchestrator"; _is_consult_window ) \
        && _fail "_is_consult_window: 非 consult 窓 → false を期待" \
        || _ok "_is_consult_window: 非 consult 窓 → false"
    # 窓名取得失敗（stub exit1）→ false（fail-safe: inject 継続）。
    ( export TMUX="/tmp/fake,1,0" TMUX_PANE="%9" PATH="$st_tmp/bin:$PATH" STUB_WNAME=""; _is_consult_window ) \
        && _fail "_is_consult_window: 窓名取得失敗 → false を期待" \
        || _ok "_is_consult_window: 窓名取得失敗 → false(fail-safe)"

    if [ "$st_fail" -eq 0 ]; then echo "orch_session.sh --self-test: PASS"; exit 0
    else echo "orch_session.sh --self-test: FAIL" >&2; exit 1; fi
fi

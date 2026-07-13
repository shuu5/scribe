# shellcheck shell=bash
# mailbox-common.sh — 下り mailbox hook 群の共有 lib（source 専用・sc-b6w / orch-0yof ①②）
#
# 役割: scriptorium orch 台帳の **direct read**（`for:<self>` 平ラベル完全一致・open のみ）と、
#       その周辺（hook stdin JSON 解釈 / self 台帳 walk-up 解決 / role 判定 / dedupe state）を
#       **単一実装**として提供する。consumer は 3 本:
#         - session-start-mailbox-scan.sh   （SessionStart 配送点・sc-p2o）
#         - user-prompt-mailbox-scan.sh     （UserPromptSubmit 中間配送点・sc-b6w / 裁定-delivery-guarantee②）
#         - session-boundary-heartbeat.sh   （admin heartbeat・sc-b6w / 裁定-cycle-signal。self 解決と role 判定のみ利用）
#       ★二重実装しない（orch-0yof ①「既存 SessionStart mailbox 注入 hook の発見ロジックを共通化して再利用」）。
#
# ★hydrate 禁止（top-spec §5.3 会計②・orch-ufz）: 本 lib は orch 台帳へ `bd ... list --readonly` の
#   **read しか発行しない**（`bd repo sync` / `bd repo add` を絶対に呼ばない）。orch 台帳は恒久 private で、
#   public repo の `.beads` へ写しが入ると git 経由で漏洩する。direct read は writable copy を作らない。
#
# fail-safe 契約（全 consumer 共通）: 本 lib の関数は **die しない**（set -e を張らない・エラーは戻り値で返す）。
#   呼び手は「解決不能 → 無出力 exit 0 degrade」を守る（global hook ゆえセッションを決して壊さない）。
#
# 依存: bash / coreutils のみ。jq は **任意**（不在なら sed / python3 フォールバック）。

# --- 既定 orch anchor（per-machine・env SCRIBE_ORCH_ANCHOR で上書き可）---
MBX_DEFAULT_ORCH_ANCHOR="/home/shuu5/projects/local-projects/scriptorium"

# ============================ hook stdin JSON ============================

# stdin の hook JSON 全文を MBX_HOOK_JSON へ載せる（tty なら読まない＝block 回避）。
# stdin は一度しか読めないため **必ず本関数で 1 回だけ読み**、以後は mbx_json_field で field を引く。
mbx_read_stdin() {
    MBX_HOOK_JSON=""
    [ -t 0 ] && return 0
    MBX_HOOK_JSON="$(cat 2>/dev/null)"
    return 0
}

# MBX_HOOK_JSON から top-level の文字列 field を取り出す（jq → sed フォールバック）。
# 抽出不能なら空文字（呼び手が既定値へフォールバックする）。
mbx_json_field() {
    local name="$1" v=""
    [ -n "${MBX_HOOK_JSON:-}" ] || return 0
    if command -v jq >/dev/null 2>&1; then
        v="$(printf '%s' "$MBX_HOOK_JSON" | jq -r --arg k "$name" '.[$k] // empty' 2>/dev/null)"
    else
        v="$(printf '%s' "$MBX_HOOK_JSON" \
            | sed -n "s/.*\"$name\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
            | head -n1)"
    fi
    [ -n "$v" ] && printf '%s' "$v"
    return 0
}

# ============================ 台帳 self 解決 ============================

# .beads/metadata.json から dolt_database 値を読む（jq → sed フォールバック）
mbx_read_dolt_db() {
    local f="$1" v=""
    [ -f "$f" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        v="$(jq -r '.dolt_database // empty' "$f" 2>/dev/null)"
    else
        v="$(sed -n 's/.*"dolt_database"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1)"
    fi
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# cwd から上方向へ walk-up し、最初に見つかる `.beads/` を持つディレクトリ（＝台帳 root）を返す。
# bd と同じ walk-up（scribe_session.py `_resolve_ledger` の bash 版）。見つからなければ 1。
mbx_resolve_ledger_root() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
    while [ -n "$dir" ]; do
        if [ -d "$dir/.beads" ]; then
            printf '%s' "$dir"
            return 0
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

# cwd から walk-up して最初に見つかる .beads/metadata.json の dolt_database を返す。
# metadata が present-but-unreadable（.beads は在るが dolt_database 欠落）なら 1 を返す
# ＝識別不能 → 呼び手は no-op（fail-safe 方向）。
mbx_resolve_self_db() {
    local dir="$1" meta db
    [ -n "$dir" ] || return 1
    dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
    while [ -n "$dir" ]; do
        meta="$dir/.beads/metadata.json"
        if [ -f "$meta" ]; then
            db="$(mbx_read_dolt_db "$meta")" && { printf '%s' "$db"; return 0; }
            return 1  # 発見したが読めない → 識別不能（no-op）
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

# ============================ role 判定 ============================

# role を admin|worker|consult|none で返す（判定 SSOT = docs/role-context-spec.md §1・
# 実装 SSOT = session-start-role-inject.sh。本 lib は同型の最小判定を提供し、hook 群で共有する）。
#   ① SCRIBE_ROLE=none        → none（既知 opt-out・orchestrator 等の別レイヤ）
#   ② SCRIBE_ROLE=consult     → consult
#   ③ SCRIBE_ROLE=worker      → worker
#   ④ cwd が .worktrees/ ・.claude/worktrees/ 配下 → worker
#   ⑤ 既定（anchor 無印）     → admin
mbx_role() {
    local cwd="$1"
    case "${SCRIBE_ROLE:-}" in
        none)    printf 'none';    return 0 ;;
        consult) printf 'consult'; return 0 ;;
        worker)  printf 'worker';  return 0 ;;
    esac
    case "$cwd" in
        */.worktrees/*|*/.claude/worktrees/*) printf 'worker'; return 0 ;;
    esac
    printf 'admin'
    return 0
}

# ============================ orch 台帳 direct read ============================

# orch anchor（env > 既定・per-machine）。`.beads` が無ければ 1（呼び手は no-op）。
mbx_orch_anchor() {
    local anchor="${SCRIBE_ORCH_ANCHOR:-$MBX_DEFAULT_ORCH_ANCHOR}"
    [ -d "$anchor/.beads" ] || return 1
    printf '%s' "$anchor"
    return 0
}

# orch 台帳を direct read し `for:<self>` の open bead を JSON で返す（read-only・hydrate せず）。
#   $1 = orch anchor / $2 = label（`for:<self>`）/ $3 = timeout 秒（既定 8）
# --limit 0 = 全件（bd 既定の --limit 50 は mailbox を黙って上限打ち切りする＝silent cap 回避）。
# bd 不在・read 失敗・timeout は rc!=0（呼び手は degrade）。
mbx_direct_read() {
    local anchor="$1" label="$2" secs="${3:-8}" raw rc
    command -v bd >/dev/null 2>&1 || return 1
    if command -v timeout >/dev/null 2>&1; then
        raw="$(timeout "$secs" bd -C "$anchor" list --label "$label" --status open --limit 0 --readonly --json 2>/dev/null)"
        rc=$?
    else
        raw="$(bd -C "$anchor" list --label "$label" --status open --limit 0 --readonly --json 2>/dev/null)"
        rc=$?
    fi
    [ "$rc" -eq 0 ] || return 1
    [ -n "$raw" ] || return 1
    printf '%s' "$raw"
    return 0
}

# stdin の bd --json を「`  - <id> [P<pri>] <title>`」行へ整形（jq → python3）。
# 0 を返したときだけ ≥1 行 print 済み。空配列・parse 不能は 1（fail-safe）。
#
# ★不変条件「1 bead = 1 行」を **構造で保証する**（sc-b6w self-review [major] fix・load-bearing）:
#   title / id / priority に含まれる CR・LF は空白へ潰してから emit する。潰さないと 1 bead が複数行へ割れ、
#   (a) 継続行から id を再抽出できず dedupe（mbx_filter_unseen）が素通し＝**毎 TTL 窓で永久に再注入**され、
#   (b) 継続行が整形リストの行フォーマット（`  - <id> [P<n>] <title>`）を自由に騙れる＝orch 台帳の
#       文字列 1 つで surface リストへ任意の偽 bead 行を注入できる（UserPromptSubmit は毎 turn の context へ
#       stdout を注入するため露出が大きい）。行分割の禁止は「1 行 = 1 bead」に依存する下流全体の前提。
mbx_emit() {
    if command -v jq >/dev/null 2>&1; then
        jq -e -r '
            def flat: (. // "") | tostring | gsub("[\r\n]"; " ");
            if (type=="array" and length>0)
            then (.[] | "  - \(.id|flat) [P\(.priority|flat)] \(.title|flat)")
            else empty end
        ' 2>/dev/null
        return $?
    elif command -v python3 >/dev/null 2>&1; then
        # プログラムは -c で渡す（`python3 -` の heredoc だと stdin がプログラム本文に奪われ、
        # パイプで渡した bd --json が json.load(sys.stdin) に届かず常に JSONDecodeError→exit1 になる）。
        python3 -c '
import sys, json
def flat(v, d="?"):
    if v is None:
        v = d
    return str(v).replace("\r", " ").replace("\n", " ")
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, list) or not d:
    sys.exit(1)
for b in d:
    if not isinstance(b, dict):
        continue
    print("  - %s [P%s] %s" % (flat(b.get("id"), "?"), flat(b.get("priority"), "?"), flat(b.get("title"), "")))
sys.exit(0)
'
        return $?
    fi
    return 1  # jq も python3 も無い → surface を諦める（fail-safe・無出力）
}

# 整形行（mbx_emit 出力）から bead id だけを抜く（1 行 1 id）。
mbx_ids_from_lines() {
    sed -n 's/^[[:space:]]*-[[:space:]]*\([^[:space:]]*\).*/\1/p'
}

# ============================ dedupe / TTL state ============================
#
# 「既報 bead を再通知しない」（裁定-delivery-guarantee②）の state。**session 単位**で持つ:
#   <state-dir>/<session>__<self_db>.seen  … surface 済み bead id（1 行 1 id）
#   <state-dir>/<session>__<self_db>.scan  … 最終 scan 時刻（mtime が stamp・中身は使わない）
# session_id が取れないときは state を持てない＝**dedupe も TTL も効かない**ため、毎 prompt hook は
# no-op へ degrade する（呼び手の責務・spam と 0.8s/prompt の二重事故を避ける）。
# 置き場所は repo 外（XDG state）＝git を汚さず、worker sandbox の書込境界外でも degrade するだけ。

mbx_state_dir() {
    printf '%s' "${SCRIBE_MAILBOX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/scribe/mailbox}"
}

# state key を安全な文字だけに畳む（session_id は外部由来＝path traversal / glob を構造排除）
mbx_sanitize_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-128
}

# state ファイル prefix（`<dir>/<session>__<self_db>`）。dir を作れなければ 1（呼び手は degrade）。
mbx_state_prefix() {
    local session="$1" self_db="$2" dir
    [ -n "$session" ] || return 1
    dir="$(mbx_state_dir)"
    mkdir -p "$dir" 2>/dev/null || return 1
    printf '%s/%s__%s' "$dir" "$(mbx_sanitize_key "$session")" "$(mbx_sanitize_key "$self_db")"
    return 0
}

# ファイル mtime（epoch 秒）。取得不能なら 1。GNU stat → BSD stat → date -r の順。
mbx_mtime_epoch() {
    local f="$1" v=""
    [ -f "$f" ] || return 1
    v="$(stat -c %Y "$f" 2>/dev/null)" || v=""
    [ -z "$v" ] && v="$(stat -f %m "$f" 2>/dev/null)" || true
    [ -z "$v" ] && v="$(date -r "$f" +%s 2>/dev/null)" || true
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# TTL gate: 最終 scan から TTL 秒未満なら 0（＝skip すべき）。TTL 経過 or 未 scan なら 1（＝scan する）。
# TTL 既定 300 秒（bd direct read の実測 0.74-0.89s／毎 prompt 発火ゆえ間引く・裁定「軽量性必須」）。
mbx_within_ttl() {
    local scan_file="$1" ttl="${2:-300}" last now
    [ "$ttl" -gt 0 ] 2>/dev/null || return 1   # TTL<=0 / 非数値 → gate 無効（毎回 scan）
    last="$(mbx_mtime_epoch "$scan_file")" || return 1
    now="$(date +%s 2>/dev/null)" || return 1
    [ $((now - last)) -lt "$ttl" ] && return 0
    return 1
}

# scan stamp を更新（mtime を now へ）。失敗しても呼び手を止めない。
mbx_touch_scan() {
    : > "$1" 2>/dev/null || return 1
    return 0
}

# seen ファイルに id が在るか（完全一致）
mbx_seen_has() {
    local seen_file="$1" id="$2"
    [ -f "$seen_file" ] || return 1
    grep -Fxq -- "$id" "$seen_file" 2>/dev/null
}

# 整形行（stdin）のうち **未報告のものだけ**を stdout へ通し、通した id を seen へ記録する。
# 1 行も通らなければ 1 を返す（＝新着なし → 呼び手は無出力 exit 0）。
# seen_file が空文字なら dedupe せず全通し（記録もしない＝state 無しでの surface 用）。
#
# ★dedupe は **fail-closed**（sc-b6w self-review [major] fix）: seen_file が有るのに id を抽出できない行は
#   **落とす**（surface しない）。id が無い行は seen へ記録できず＝既報判定が永久に効かないため、素通しすると
#   毎 TTL 窓で同じ行が再注入される（fail-open）。mbx_emit が「1 bead = 1 行」を構造保証した今、この経路へ
#   来る行は原理上存在しないが、上流が壊れたときに **spam でなく静粛へ倒す**ための二重の底（配送保証の
#   バックストップは SessionStart 配送点が担う）。
mbx_filter_unseen() {
    local seen_file="$1" line id emitted=0
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        id="$(printf '%s' "$line" | mbx_ids_from_lines)"
        if [ -n "$seen_file" ]; then
            [ -n "$id" ] || continue                              # id 不明 → dedupe 不能 → 落とす（fail-closed）
            mbx_seen_has "$seen_file" "$id" && continue           # 既報 → 再通知しない
        fi
        printf '%s\n' "$line"
        emitted=1
        [ -n "$seen_file" ] && [ -n "$id" ] && printf '%s\n' "$id" >> "$seen_file" 2>/dev/null
    done
    [ "$emitted" -eq 1 ] && return 0
    return 1
}

# 整形行（stdin）の id を **surface せずに** seen へ記録する（SessionStart の seed 用）。
mbx_seed_seen() {
    local seen_file="$1" id
    [ -n "$seen_file" ] || return 0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        mbx_seen_has "$seen_file" "$id" || printf '%s\n' "$id" >> "$seen_file" 2>/dev/null
    done
    return 0
}

# 古い state を掃除（既定 7 日・SessionStart から呼ぶ）。find 不在・失敗は無視（best-effort）。
mbx_prune_state() {
    local dir days="${1:-7}"
    dir="$(mbx_state_dir)"
    [ -d "$dir" ] || return 0
    command -v find >/dev/null 2>&1 || return 0
    find "$dir" -maxdepth 1 -type f -mtime "+$days" -delete 2>/dev/null || true
    return 0
}

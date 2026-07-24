#!/bin/bash
# =============================================================================
# session-context-meter.sh — session context 使用量の read-only meter primitive
#
# 対象 Claude Code session の context 使用量（used%・絶対 tokens・context window
# size）を外形から決定論取得する。ファイル・tmux・台帳への書込は一切しない
# （read-only primitive・courier orch-xstc / bd ccs-ehk）。
#
# Usage:
#   session-context-meter.sh --target <tmux-target> [--source auto|pane|jsonl]
#   session-context-meter.sh --sid <session-id>    [--source auto|jsonl]
#   session-context-meter.sh --target <t> --sid <s>   # pane 失敗時に指定 sid で jsonl へ
#
#   <tmux-target> は次のいずれか:
#     - pane id（%N）                    … そのまま capture 対象
#     - session:window（名前 or index）  … session-state.sh resolve_target で解決
#     - bare window 名                   … 同上（全 session 横断で最初の一致）
#     - bare session 名                  … window 解決に失敗した場合の fallback
#                                          （session の active pane を capture）
#
# 出力（機械可読・1 行・固定順 key=value・不明値は '-'）:
#   used_pct=<int|-> used_tokens=<int|-> window_tokens=<int|-> source=<pane|jsonl> sid=<sid|-> target=<target|->
#
# Exit codes:
#   0 = 計測成立（used_pct / used_tokens の少なくとも一方が数値）
#   2 = usage error（引数不正・sid 形式不正）
#   3 = source 解決失敗（tmux target 不在・pane-map 不一致・transcript 不在）
#   4 = 計測不能（source は解決できたが値が取れない）
#
# Source の意味論:
#   pane  = tmux capture-pane の statusline line2『NN% XXXk/YM …』を parse。
#           attached/detached/processing すべてで render される（orch-h1nc prebake
#           3 session 実測）。粒度: % は整数 floor・tokens は fmt_tokens の k/M 丸め
#           （1M 窓の実用域では ~1k）。フォーマット SSOT は
#           ubuntu-note-system/claude/statusline-command.sh line2（cross-repo
#           coupling: 同 script の表示形式変更時は本 parser の追随が必要）。
#           claude 非稼働 pane（detect_state = idle/exited）では画面に残った
#           stale statusline を「現在値」と誤読しうるため pane source を信頼せず
#           jsonl へ fallback する（jsonl は「最終観測値」として意味論が正直）。
#   jsonl = transcript jsonl の最新の非 sidechain assistant message の
#           input_tokens + cache_creation_input_tokens + cache_read_input_tokens 和。
#           絶対 tokens は正確・/clear / compact 後も最新 1 turn 読みで自然追随。
#           % と窓サイズは jsonl から算出不能 → '-'。
#   auto（既定）= --target あり: pane → 失敗時 pane-map(pane_id→sid) 経由で jsonl。
#                 --sid のみ: jsonl。
#
# 消費者契約（orch-fleet-cap.sh 等）: 非 0 exit・出力不成立は fail-open
# （cap 未達扱い）にすること。本 script は誤検知側（偽の高値）へ倒れない:
# 値が取れないときは必ず非 0 exit し、捏造値を出力しない。
#
# 環境変数 seam（すべて test 用 override 可）:
#   SESSION_METER_PANE_MAP      pane_id→sid map の明示 path（設定時はこれのみ使用）
#   SESSION_METER_PROJECT_DIRS  transcript 探索 root（コロン区切り。各 dir 直下の
#                               <proj>/<sid>.jsonl を探す）。既定は
#                               ~/.claude/projects と ~/.claude-accounts/*/projects
#   SESSION_METER_TAIL_BYTES    jsonl 末尾走査バイト数（既定 10485760 = 10MiB）
# =============================================================================
set -euo pipefail

_SCM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/session-env.sh
source "$_SCM_DIR/lib/session-env.sh"
# resolve_target（session:window / bare window 名の解決 SSOT）を再利用する。
# session-state.sh は source 時に dispatch を skip する設計（同 script 末尾参照）。
# shellcheck source=session-state.sh
source "$_SCM_DIR/session-state.sh"

usage() {
    sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2
}

# --- statusline line2 の tokens 表記（fmt_tokens の逆写像）を整数化 ---------
# 320k → 320000 / 1M → 1000000 / 800 → 800。不正形式は非 0 return。
tok2int() {
    local t="$1"
    case "$t" in
        *k) [[ "${t%k}" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$(( ${t%k} * 1000 ))" ;;
        *M) [[ "${t%M}" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$(( ${t%M} * 1000000 ))" ;;
        *)  [[ "$t" =~ ^[0-9]+$ ]] || return 1; printf '%s' "$t" ;;
    esac
}

# --- pane source: capture-pane から statusline line2 を parse ----------------
# 成功: グローバル P_PCT / P_USED / P_WINDOW を設定し 0。失敗: 非 0。
# 実 TUI は statusline を先頭空白付きで render する（live 実測 2026-07-24:
# 『  19% 190k/1M Fable 5 [xhigh] …』）ため先頭空白は許容し trim する。
# 『NN% <tok>/<tok>』の複合形状で誤爆を抑え、複数一致時は最終行
# （= pane 最下部の statusline 側）を採る。transcript 本文が同形状の行を
# 含む場合の誤読は理論上残る（read-only 外形観測の既知限界・header 参照）。
P_PCT="" P_USED="" P_WINDOW=""
parse_pane() {
    local target="$1" captured line used_tok win_tok
    captured=$(tmux capture-pane -p -t "$target" 2>/dev/null) || return 1
    line=$(grep -E '^[[:space:]]*[0-9]+% [0-9]+[kM]?/[0-9]+[kM]?( |$)' <<<"$captured" | tail -n 1)
    [ -n "$line" ] || return 1
    line="${line#"${line%%[![:space:]]*}"}"   # 先頭空白 trim（TUI render の indent）
    P_PCT="${line%%\%*}"
    used_tok="${line#* }"; used_tok="${used_tok%%/*}"
    win_tok="${line#*/}";  win_tok="${win_tok%% *}"
    P_USED=$(tok2int "$used_tok") || return 1
    P_WINDOW=$(tok2int "$win_tok") || return 1
    [[ "$P_PCT" =~ ^[0-9]+$ ]] || return 1
    return 0
}

# --- pane_id → sid（pane-map 逆引き） ---------------------------------------
# SESSION_METER_PANE_MAP 設定時はそれのみ（hermetic test 用の排他 override）。
# 未設定時は SESSION_MAP_DIR（本 plugin namespace）→ legacy live writer
# （ubuntu-note-system claude-session-save.sh の ~/.local/state/claude）の順で、
# 「key を含む最初の map」を採る。同一 key 重複時は最終行が勝つ（追記耐性）。
panemap_sid() {
    local pane_id="$1" f sid candidates=()
    if [ -n "${SESSION_METER_PANE_MAP:-}" ]; then
        candidates=("$SESSION_METER_PANE_MAP")
    else
        candidates=("$SESSION_MAP_DIR/tmux-pane-map.tsv"
                    "$HOME/.local/state/claude/tmux-pane-map.tsv")
    fi
    for f in "${candidates[@]}"; do
        [ -f "$f" ] || continue
        sid=$(awk -F'\t' -v k="$pane_id" '$1 == k { v = $2 } END { if (v != "") print v }' "$f")
        if [ -n "$sid" ]; then printf '%s' "$sid"; return 0; fi
    done
    return 1
}

# --- sid → transcript jsonl path（複数候補は mtime 最新を採る） -------------
find_transcript() {
    local sid="$1" d cand m best="" best_m=0
    local dirs=()
    if [ -n "${SESSION_METER_PROJECT_DIRS:-}" ]; then
        IFS=':' read -r -a dirs <<< "$SESSION_METER_PROJECT_DIRS"
    else
        dirs=("$HOME/.claude/projects")
        for d in "$HOME"/.claude-accounts/*/projects; do
            [ -d "$d" ] && dirs+=("$d")
        done
    fi
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for cand in "$d"/*/"$sid".jsonl; do
            [ -f "$cand" ] || continue
            m=$(stat -c %Y "$cand" 2>/dev/null) || m=0
            if [ "$m" -ge "$best_m" ]; then best="$cand"; best_m="$m"; fi
        done
    done
    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

# --- jsonl source: 最新の非 sidechain assistant message の usage 和 ----------
# 末尾 SESSION_METER_TAIL_BYTES だけ走査（最新 message は必ずファイル末尾側に
# ある）。chunk 先頭の行断片は fromjson? が黙って捨てる。chunk 内に対象が
# 無ければ全量走査へ 1 回だけ fallback。pipeline は全 stream を消費し切る形
# （早期 exit なし）なので pipefail 下でも SIGPIPE 偽失敗しない。
JSONL_FILTER='fromjson?
  | select(.type == "assistant" and .isSidechain != true)
  | .message.usage | select(. != null)
  | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))'
extract_jsonl() {
    local file="$1" tail_bytes="${SESSION_METER_TAIL_BYTES:-10485760}" sum
    sum=$(tail -c "$tail_bytes" "$file" 2>/dev/null | jq -R -r "$JSONL_FILTER" | tail -n 1)
    if [ -z "$sum" ]; then
        sum=$(jq -R -r "$JSONL_FILTER" "$file" 2>/dev/null | tail -n 1)
    fi
    [[ "$sum" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$sum"
}

emit() {
    # 固定順 key=value 1 行（機械可読契約。列追加は末尾のみ＝後方互換）
    printf 'used_pct=%s used_tokens=%s window_tokens=%s source=%s sid=%s target=%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6"
}

# =============================================================================
# main
# =============================================================================
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

TARGET="" SID="" SOURCE="auto"
while [ $# -gt 0 ]; do
    case "$1" in
        --target) TARGET="${2:-}"; [ -n "$TARGET" ] || usage; shift 2 ;;
        --sid)    SID="${2:-}";    [ -n "$SID" ]    || usage; shift 2 ;;
        --source) SOURCE="${2:-}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Error: unknown option '$1'" >&2; usage ;;
    esac
done

case "$SOURCE" in auto|pane|jsonl) ;; *) echo "Error: invalid --source '$SOURCE'" >&2; usage ;; esac
[ -n "$TARGET" ] || [ -n "$SID" ] || usage
if [ "$SOURCE" = "pane" ] && [ -z "$TARGET" ]; then
    echo "Error: --source pane requires --target" >&2; usage
fi
# sid は path 構成要素になるため slug を構造検証（session-env.sh の slug 規約と同一）
if [ -n "$SID" ] && ! [[ "$SID" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
    echo "Error: invalid --sid format" >&2; usage
fi

RESOLVED=""
if [ -n "$TARGET" ]; then
    if [[ "$TARGET" =~ ^%[0-9]+$ ]]; then
        RESOLVED="$TARGET"
    else
        # window 解決（SSOT = session-state.sh resolve_target）→ 失敗時のみ
        # bare session 名として fallback（active pane を capture 対象にする）
        RESOLVED=$(resolve_target "$TARGET" 2>/dev/null) || RESOLVED=""
        if [ -z "$RESOLVED" ] && [[ "$TARGET" != *:* ]] \
            && [[ "$TARGET" =~ ^[A-Za-z0-9_./-]+$ ]] \
            && tmux has-session -t "=$TARGET" 2>/dev/null; then
            RESOLVED="$TARGET"
        fi
        if [ -z "$RESOLVED" ] && [ -z "$SID" ]; then
            echo "Error: cannot resolve tmux target '$TARGET'" >&2
            exit 3
        fi
    fi
fi

# --- primary: pane ---
if [ -n "$RESOLVED" ] && { [ "$SOURCE" = "auto" ] || [ "$SOURCE" = "pane" ]; }; then
    # stale-screen gate: claude 非稼働 pane の画面残渣を現在値として読まない
    # （判定 SSOT = session-state.sh detect_state。idle/exited のみ不信頼化）
    STATE=$(detect_state "$RESOLVED" 2>/dev/null) || STATE=""
    if [ "$STATE" != "idle" ] && [ "$STATE" != "exited" ] && parse_pane "$RESOLVED"; then
        emit "$P_PCT" "$P_USED" "$P_WINDOW" "pane" "${SID:--}" "$RESOLVED"
        exit 0
    fi
    if [ "$SOURCE" = "pane" ]; then
        echo "Error: no live statusline context line in pane '$RESOLVED' (state=${STATE:-unknown})" >&2
        exit 4
    fi
fi

# --- fallback / direct: jsonl ---
if [ -z "$SID" ]; then
    # target 経由: pane_id → pane-map → sid
    PANE_ID=$(tmux display-message -p -t "$RESOLVED" '#{pane_id}' 2>/dev/null) || PANE_ID=""
    if [ -z "$PANE_ID" ]; then
        echo "Error: cannot resolve pane id for '$RESOLVED'" >&2
        exit 3
    fi
    SID=$(panemap_sid "$PANE_ID") || {
        echo "Error: no sid mapping for pane '$PANE_ID' (pane-map miss)" >&2
        exit 3
    }
    if ! [[ "$SID" =~ ^[A-Za-z0-9-]{1,64}$ ]]; then
        echo "Error: pane-map returned invalid sid" >&2
        exit 3
    fi
fi

TRANSCRIPT=$(find_transcript "$SID") || {
    echo "Error: transcript not found for sid '$SID'" >&2
    exit 3
}
SUM=$(extract_jsonl "$TRANSCRIPT") || {
    echo "Error: no usable assistant usage entry in '$TRANSCRIPT'" >&2
    exit 4
}
emit "-" "$SUM" "-" "jsonl" "$SID" "${RESOLVED:-${TARGET:--}}"
exit 0

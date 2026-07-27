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
#                                          （session 内で claude が走る唯一の pane を
#                                          対象に採る。0 件は解決失敗・複数件は曖昧
#                                          ＝pane では計測しない fail-closed。--sid
#                                          併用時はいずれも jsonl へ落ちる。claude
#                                          判定は cmd==claude ∨ pgid 内 comm=claude
#                                          の 2 経路〔detect_state と同 SSOT・
#                                          cld-spawn の wrapper bash pane 対応〕）
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
#           （表示丸め自体は 1k 単位だが、上流の報告粒度によりさらに粗くなりうる
#           〔live 実測で 10k 単位の量子化を観測〕。精密値が要るなら jsonl source）。
#           フォーマット SSOT は
#           ubuntu-note-system/claude/statusline-command.sh line2（cross-repo
#           coupling: 同 script の表示形式変更時は本 parser の追随が必要）。
#           claude 非稼働 pane では画面に残った stale statusline を「現在値」と
#           誤読しうるため pane source を信頼せず jsonl へ fallback する（判定は
#           計測対象 pane 厳密の pane_alive_claude・jsonl は「最終観測値」として
#           意味論が正直）。parse は誤爆対策として「入力ボックス（最後の '❯'
#           行）より下」のみ探索（無ければ末尾 6 非空行へ fallback）・window
#           token は k/M 必須・健全性 bound（pct<=100 ∧ used<=window ∧
#           window>=100k）外は不成立として扱う（捏造値を出さない側へ倒す）。
#   jsonl = transcript jsonl の最新の非 sidechain assistant message の
#           input_tokens + cache_creation_input_tokens + cache_read_input_tokens 和。
#           絶対 tokens は正確・/clear / compact 後も最新 1 turn 読みで自然追随。
#           % と窓サイズは jsonl から算出不能 → '-'。usage 全 0 の synthetic
#           entry（API error 等）は計測情報を持たないため skip し最新の非 0 値を
#           採る（全 entry が 0 なら exit 4＝捏造 0 を出さない。実測: 234/5472
#           transcript で最終 entry が全 0）。jsonl は「最終観測値」であり session
#           の生存・鮮度は保証しない（pane-map 経由の sid 解決は map の鮮度に依存）。
#   auto（既定）= --target あり: pane → 失敗時 pane-map(pane_id→sid) 経由で jsonl。
#                 --sid のみ: jsonl。
#
# 消費者契約（orch-fleet-cap.sh 等）: 非 0 exit・出力不成立は fail-open
# （cap 未達扱い＝no-action。「制限を開放する」の意ではない）にすること。
# 誠実性の主張は source 別: pane source は値が取れないとき必ず非 0 exit し
# 捏造値を出力しない。jsonl source は「最終観測値」であり session の生存・
# 鮮度は保証しない（現在値としての解釈は consumer 側の判断）。stdout に出る
# のは成功時の 1 行 key=value のみ（usage/診断は stderr・target field は
# 空白等を '_' に無害化して emit する）。orch-fleet-cap の seam（単一 word
# command + 位置引数 1 個・stdout「<pct> <abs>」）へは同 dir の
# session-context-meter-capfmt.sh を指すこと（consumer が action する
# <session>:<window>〔既定 admin・SESSION_METER_WINDOW で上書き〕を
# --source pane 固定で計測する adapter）。
#
# 環境変数 seam（すべて test 用 override 可）:
#   SESSION_METER_PANE_MAP      pane_id→sid map の明示 path（設定時はこれのみ使用）
#   SESSION_METER_PROJECT_DIRS  transcript 探索 root（コロン区切り。各 dir 直下の
#                               <proj>/<sid>.jsonl を探す）。既定は
#                               ~/.claude/projects と ~/.claude-accounts/*/projects
#   SESSION_METER_TAIL_BYTES    jsonl 末尾走査バイト数（既定 10485760 = 10MiB）
# =============================================================================
set -euo pipefail

_SCM_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib/session-env.sh
source "$_SCM_DIR/lib/session-env.sh"
# resolve_target（session:window / bare window 名の解決 SSOT）を再利用する。
# session-state.sh は source 時に dispatch を skip する設計（同 script 末尾参照）。
# shellcheck source=session-state.sh
source "$_SCM_DIR/session-state.sh"

usage() {
    # stderr へ出す: stdout は成功時の 1 行 key=value 専用（機械可読契約を汚さない）
    sed -n '/^# Usage:/,/^# Exit codes:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
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
# 誤爆対策（R2/R3 gate finding）:
#   (1) 探索域は「入力ボックス（最後の '❯' を含む行）より下」の非空行に限定する。
#       本文/dialog の decoy 行は常に入力ボックスより上に居るため構造的に除外
#       される。'❯' が無い画面（dialog・特殊状態）は末尾 6 非空行へ fallback
#       （有界窓・R3 実測: 旧 tail -3 は workflow 進捗行等の trailing UI で
#       live margin 0 になり、footer 1 行増で恒久 exit 4 化した）
#   (2) window token は k/M suffix 必須（SSOT の fmt_tokens 上、実在する
#       window が suffix 無しになることはない＝『3/4 done』等の prose を弾く）
#   (3) 健全性 bound: pct<=100 ∧ used<=window ∧ window>=100k。外れたら
#       parse 失敗（fail-closed・捏造値を consumer へ流さない）
# 複数一致時は最終行（= pane 最下部の statusline 側）を採る。
P_PCT="" P_USED="" P_WINDOW=""
parse_pane() {
    local target="$1" captured nonempty anchored line used_tok win_tok
    captured=$(tmux capture-pane -p -t "$target" 2>/dev/null) || return 1
    nonempty=$(sed '/^[[:space:]]*$/d' <<<"$captured")
    anchored=$(awk 'index($0,"❯"){n=NR} {a[NR]=$0}
        END{s = n ? n+1 : (NR>6 ? NR-5 : 1); for(i=s;i<=NR;i++) print a[i]}' <<<"$nonempty")
    # 桁数上限つき ERE: tok2int の bash 算術 overflow（負値 emit）を入力段で遮断
    # （R4 gate finding。pct<=3 桁・tokens<=9 桁で実在域を全て覆う）
    line=$(grep -E '^[[:space:]]*[0-9]{1,3}% [0-9]{1,9}[kM]?/[0-9]{1,9}[kM]( |$)' <<<"$anchored" | tail -n 1)
    [ -n "$line" ] || return 1
    line="${line#"${line%%[![:space:]]*}"}"   # 先頭空白 trim（TUI render の indent）
    P_PCT="${line%%\%*}"
    used_tok="${line#* }"; used_tok="${used_tok%%/*}"
    win_tok="${line#*/}";  win_tok="${win_tok%% *}"
    P_USED=$(tok2int "$used_tok") || return 1
    P_WINDOW=$(tok2int "$win_tok") || return 1
    [[ "$P_PCT" =~ ^[0-9]+$ ]] || return 1
    [ "$P_PCT" -le 100 ] || return 1
    [ "$P_USED" -ge 0 ] || return 1
    [ "$P_WINDOW" -gt 0 ] || return 1
    [ "$P_USED" -le "$P_WINDOW" ] || return 1
    [ "$P_WINDOW" -ge 100000 ] || return 1
    return 0
}

# --- claude 稼働 pane 判定（pane 単位・fail-closed） -------------------------
# SSOT = session-state.sh detect_state の 2 経路判定と同一手法:
#   pane_current_command == claude、または pane_pid の process group 内に
#   comm=claude が存在する。cld-spawn 由来 pane は wrapper bash が foreground
#   leader に残り pane_current_command=bash になる（R2 gate CONFIRMED）ため、
#   文字列一致だけでは本番 spawn 経路の claude を構造的に見落とす。
# detect_state 自体を使わないのは、同関数の list-panes が window 先頭 pane を
# 判定する（pane 指定でも window スコープ）ため、gate 対象と計測対象が
# multi-pane window で乖離するから（本関数は display-message で pane 厳密）。
pane_alive_claude() {
    local pane="$1" info dead pid cmd pgid
    info=$(tmux display-message -p -t "$pane" '#{pane_dead} #{pane_pid} #{pane_current_command}' 2>/dev/null) || return 1
    read -r dead pid cmd <<< "$info" || true
    [ "$dead" = "0" ] || return 1
    [ "$cmd" = "claude" ] && return 0
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
    [ -n "$pgid" ] || return 1
    # detect_state の「pgid 内に claude」判定と同じ意味論を pgrep 単発で行う
    # （pgrep|xargs ps 連鎖は xargs が外部 ps を exec するため bats の関数 mock が
    # 効かず、hermetic に検証できない）
    pgrep -g "$pgid" -x claude >/dev/null 2>&1
}

# --- 出力 field の無害化 -----------------------------------------------------
# 未検証の TARGET 文字列が emit 行へ素通りすると、空白入り値で後置の偽
# key=value token を注入できる（R2 gate finding）。許可文字以外を '_' へ潰す。
safe_field() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_.:/%-' '_'
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
# usage 全 0 の entry（API error 等の synthetic）は計測情報を持たないため
# select(. > 0) で skip する。skip しないと「直前まで数十万 tokens だった session」
# へ used_tokens=0 を exit 0 で返す（実測: 234/5472 transcript で最終 entry が全 0）。
JSONL_FILTER='fromjson?
  | select(.type == "assistant" and .isSidechain != true)
  | .message.usage | select(. != null)
  | ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
  | select(. > 0)'
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
        --source) SOURCE="${2:-}"; [ -n "$SOURCE" ] || usage; shift 2 ;;
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
        # colon 形（session:window）は session 部を exact 検証してから resolve する。
        # resolve_target 内部の has-session/list-windows は '=' を付けない＝tmux の
        # prefix 一致に乗るため、存在しない session 名（例 'pap'）が別 session
        # （'paper'）へ解決され「他 session の実測値を exit 0 で返す」false
        # attribution が起きる（R3 gate CONFIRMED・bare 経路の exact 規律と統一）。
        if [[ "$TARGET" == *:* ]] && ! tmux has-session -t "=${TARGET%%:*}" 2>/dev/null; then
            echo "Error: session '${TARGET%%:*}' not found (exact match)" >&2
            exit 3
        fi
        # window 解決（SSOT = session-state.sh resolve_target）→ 失敗時のみ
        # bare session 名として fallback。fallback は「session 内で claude が走る
        # 唯一の pane」を対象に据える — tmux の -t <session> 既定解決（active
        # window の active pane）は、worker spawn（cld-spawn の new-window は
        # -d 無し）で active が移った瞬間に測定対象がすり替わるため採らない
        # （consumer は bare session 名を渡す契約 = orch-fleet-cap。R1 gate CONFIRMED）。
        # claude 判定は pane_alive_claude（cmd 一致 ∨ pgid 内 comm=claude）＝
        # cld-spawn 由来 pane（pane_current_command=bash）も正しく拾う（R2 gate
        # CONFIRMED の修正）。claude pane 0 件は解決失敗・複数件は曖昧＝どれを
        # 測るか推測しない fail-closed（いずれも --sid 併用時のみ jsonl へ落ちる）。
        # なお fleet-cap 経由は capfmt が <session>:<window> 形を組むため本
        # fallback を通らない（consumer の action 対象との一致は capfmt 側で担保）。
        RESOLVED=$(resolve_target "$TARGET" 2>/dev/null) || RESOLVED=""
        if [ -z "$RESOLVED" ] && [[ "$TARGET" != *:* ]] \
            && [[ "$TARGET" =~ ^[A-Za-z0-9_./-]+$ ]] \
            && tmux has-session -t "=$TARGET" 2>/dev/null; then
            _claude_panes=()
            while IFS= read -r _p; do
                [ -n "$_p" ] || continue
                if pane_alive_claude "$_p"; then _claude_panes+=("$_p"); fi
            done < <(tmux list-panes -s -t "=$TARGET" -F '#{pane_id}' 2>/dev/null)
            if [ "${#_claude_panes[@]}" -eq 1 ]; then
                RESOLVED="${_claude_panes[0]}"
            elif [ "${#_claude_panes[@]}" -gt 1 ] && [ -z "$SID" ]; then
                echo "Error: ambiguous bare session target '$TARGET' (${#_claude_panes[@]} claude panes)" >&2
                exit 3
            fi
        fi
        if [ -z "$RESOLVED" ] && [ -z "$SID" ]; then
            echo "Error: cannot resolve tmux target '$TARGET'" >&2
            exit 3
        fi
    fi
fi

# --- 解決済み target の pane 確定と window 実在照合 --------------------------
# tmux の display-message は「実在 session : 不在の数値 window index」の -t を
# session の active window へ silent fallback させる（R4 gate CONFIRMED・例:
# sc:999 → sc:1 の pane）。resolve_target の numeric 分岐は index の実在を検証
# しないため、要求 window と実解決 window の同一性をここで照合する。不一致は
# 解決失敗（--sid 併用時のみ jsonl へ・それ以外は exit 3）。pane id はここで
# 一度だけ確定し、gate / capture / 監査痕跡 / pane-map 逆引きの全てで同じ id
# を使う（source に依らない照合＝--source jsonl でも誤 pane を掴まない）。
RESOLVED_PANE=""
if [ -n "$RESOLVED" ]; then
    _rinfo=$(tmux display-message -p -t "$RESOLVED" '#{pane_id} #{session_name}:#{window_index}' 2>/dev/null) || _rinfo=""
    read -r RESOLVED_PANE _actual_win <<< "$_rinfo" || true
    if [[ "$RESOLVED" == *:* ]] && [ "${_actual_win:-}" != "$RESOLVED" ]; then
        if [ -z "$SID" ]; then
            echo "Error: window '$RESOLVED' not found (exact match)" >&2
            exit 3
        fi
        RESOLVED=""
        RESOLVED_PANE=""
    fi
fi

# --source pane は pane 以外を決して出さない（source 固定契約）。target 解決が
# 不成立のまま --sid 併用で jsonl へ落ちる経路を塞ぐ（R3 gate finding）。
if [ "$SOURCE" = "pane" ] && [ -z "$RESOLVED" ]; then
    echo "Error: pane source has no resolved target" >&2
    exit 3
fi

# --- primary: pane ---
if [ -n "$RESOLVED" ] && { [ "$SOURCE" = "auto" ] || [ "$SOURCE" = "pane" ]; }; then
    # stale-screen gate: claude 非稼働 pane の画面残渣を現在値として読まない。
    # 判定は計測対象 pane に厳密化する（display-message で対象 pane を確定し
    # pane_alive_claude で判定。旧 detect_state 直用は window 先頭 pane を見る
    # ため multi-pane window で gate と capture が乖離した = R2 gate finding）。
    # gate / capture / 監査痕跡（target field）を単一の pane id に固定する
    # （window target のまま capture すると gate と capture の間で active pane が
    # 変わる TOCTOU が残る = R3 gate finding。%N は上の照合節で確定済み）
    GATE_PANE="$RESOLVED_PANE"
    if [ -n "$GATE_PANE" ] && pane_alive_claude "$GATE_PANE" && parse_pane "$GATE_PANE"; then
        emit "$P_PCT" "$P_USED" "$P_WINDOW" "pane" "${SID:--}" "$(safe_field "$GATE_PANE")"
        exit 0
    fi
    if [ "$SOURCE" = "pane" ]; then
        echo "Error: pane source not usable for '$RESOLVED' (no live claude statusline)" >&2
        exit 4
    fi
fi

# --- fallback / direct: jsonl ---
if [ -z "$SID" ]; then
    # target 経由: pane_id → pane-map → sid（pane id は照合節で確定済みの
    # RESOLVED_PANE を再利用＝再解決による TOCTOU・silent fallback を作らない）
    PANE_ID="$RESOLVED_PANE"
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
emit "-" "$SUM" "-" "jsonl" "$SID" "$(safe_field "${RESOLVED:-${TARGET:--}}")"
exit 0

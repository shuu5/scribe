#!/bin/bash
# =============================================================================
# session-context-meter-capfmt.sh — fleet-cap seam 適合 adapter（thin shim）
#
# scriptorium orch-fleet-cap.sh の env seam ORCH_FLEETCAP_METER_CMD は
# 「単一 word の command を位置引数 1 個（session 名）で呼び、stdout 1 行
# 『<pct> <abs_tokens>』（両方 ^[0-9]+$）だけを consume する」契約
# （orch-fleet-cap.sh header・_eval_cap: out="$("$METER_CMD" "$sess")" →
#   read -r pct abs _）。canonical meter（session-context-meter.sh）は
# --target flag + rich key=value 出力ゆえ seam から直接は指せない。
# 本 shim が位置引数を --target へ変換し、used_pct / used_tokens の 2 値
# だけを cap 形式で出力する。rich な key=value 契約（canonical・拡張可能）
# は温存し、seam 適合だけをこの薄い層が担う。
#
# 計測対象（R2 gate CONFIRMED の設計）: consumer が nudge/kill の action を
# 打つ対象は常に <session>:admin（orch-fleet-cap header）。計測対象を action
# 対象と一致させるため、本 shim は『<session>:<SESSION_METER_WINDOW（既定
# admin）>』を組んで resolve_target の厳密経路で測る。meter の bare-session
# fallback（claude pane heuristic）へは落とさない — 別 window の claude を
# 「その session の値」として返す false-high を構造的に排除するため、window
# 解決失敗はそのまま非 0 exit（consumer は cap unknown = no-action）とする。
#
# --source pane 固定: seam は pct/abs 両整数を要求し、jsonl source は pct を
# 原理的に出せない（'-'）ため、jsonl fallback の結果は 100% 捨てられる。
# 無価値な transcript 走査を避けるため pane source に固定する。
#
# Usage:
#   session-context-meter-capfmt.sh <tmux-session>
#     <tmux-session> = fleet-cap が渡す session 短名（例: sc）。
#     実際の計測 target は "<session>:${SESSION_METER_WINDOW:-admin}"。
#
# 出力: 成功時のみ stdout 1 行「<used_pct> <used_tokens>」（両方整数）。
#       失敗・片欠測時は stdout 無出力（部分出力を出さない）。
#       監査痕跡として meter の 1 行 key=value を stderr へ echo する
#       （どの pane を測ったかの事後監査用。consumer は stderr を捨てる）。
#
# Exit codes:
#   0 = 2 値とも整数で出力成立
#   2 = usage error（引数個数不正・空引数）
#   4 = meter は exit 0 だが 2 値が揃わない（防御・pane source では通常出ない）
#   他 = canonical meter の exit code をそのまま伝播（2/3/4・意味は meter header）
#
# 消費者契約: 非 0 exit・出力不成立は consumer が fail-open（cap unknown →
# cap 未達扱い・no-action。「制限を開放する」の意ではない）にする。本 shim は
# 捏造値を出さない（片欠測を 0 で埋めない）。
#
# 環境変数 seam:
#   SESSION_METER_BIN     canonical meter の path（test 用 override。既定は
#                         本 script と同 dir の session-context-meter.sh）
#   SESSION_METER_WINDOW  計測する window 名（既定 admin。fleet の admin
#                         window 命名が異なる環境で上書きする）
# =============================================================================
set -euo pipefail

_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
METER_BIN="${SESSION_METER_BIN:-$_DIR/session-context-meter.sh}"
METER_WINDOW="${SESSION_METER_WINDOW:-admin}"

if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: session-context-meter-capfmt.sh <tmux-session>" >&2
    exit 2
fi

rc=0
out="$("$METER_BIN" --target "$1:$METER_WINDOW" --source pane)" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# meter 出力（1 行固定順 key=value）から used_pct / used_tokens を抽出。
# 防御: 万一の複数行出力は 1 行目のみ採用（契約は 1 行固定）。未知 key は
# 無視（meter 契約の「列追加は末尾のみ」に対する前方互換）。
IFS= read -r line <<< "$out" || true
printf 'capfmt: %s\n' "$line" >&2   # 監査痕跡（何をどの pane で測ったか）
pct="" used=""
read -r -a kvs <<< "$line"
for kv in "${kvs[@]}"; do
    case "$kv" in
        used_pct=*)    pct="${kv#used_pct=}" ;;
        used_tokens=*) used="${kv#used_tokens=}" ;;
    esac
done

if [[ "$pct" =~ ^[0-9]+$ ]] && [[ "$used" =~ ^[0-9]+$ ]]; then
    printf '%s %s\n' "$pct" "$used"
    exit 0
fi
exit 4

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
# Usage:
#   session-context-meter-capfmt.sh <tmux-target>
#     <tmux-target> = canonical meter の --target と同じ解釈
#     （fleet-cap からは tmux session 名が渡る）
#
# 出力: 成功時のみ stdout 1 行「<used_pct> <used_tokens>」（両方整数）。
#       失敗・片欠測時は stdout 無出力（部分出力を出さない）。
#
# Exit codes:
#   0 = 2 値とも整数で出力成立
#   2 = usage error（引数個数不正・空引数）
#   4 = meter は exit 0 だが 2 値が揃わない（例: jsonl fallback で used_pct='-'）
#   他 = canonical meter の exit code をそのまま伝播（2/3/4・意味は meter header）
#
# 消費者契約: 非 0 exit・出力不成立は consumer が fail-open（cap unknown →
# cap 未達扱い・無動作）にする。本 shim は捏造値を出さない: 片欠測（jsonl
# fallback の used_pct='-' 等)を 0 で埋めると「0% を実測した」という嘘の
# 主張になるため、unknown（非 0 exit）の正直さを優先する。
#
# 環境変数 seam:
#   SESSION_METER_BIN  canonical meter の path（test 用 override。既定は
#                      本 script と同 dir の session-context-meter.sh）
# =============================================================================
set -euo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
METER_BIN="${SESSION_METER_BIN:-$_DIR/session-context-meter.sh}"

if [ $# -ne 1 ] || [ -z "$1" ]; then
    echo "Usage: session-context-meter-capfmt.sh <tmux-target>" >&2
    exit 2
fi

rc=0
out="$("$METER_BIN" --target "$1")" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# meter 出力（1 行固定順 key=value）から used_pct / used_tokens を抽出。
# 防御: 万一の複数行出力は 1 行目のみ採用（契約は 1 行固定）。未知 key は
# 無視（meter 契約の「列追加は末尾のみ」に対する前方互換）。
IFS= read -r line <<< "$out" || true
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

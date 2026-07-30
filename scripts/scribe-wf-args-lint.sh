#!/usr/bin/env bash
# scribe-wf-args-lint.sh — dynamic workflow script の args preamble lint（sc-4t3t / L0a）
#
# ■ 何を見るか
#   「必須 args が欠落・undefined・空・"[undefined]" のまま agent() を起動していないか」＝ WF が undefined を
#   掴んだまま silent 完走する事故（実害: anchor=undefined のまま 1,435,749 token / 54.9 分）を機械で塞ぐ線。
#   判定 logic は本 script に持たせない（bash 文字列に埋めない＝TS 移植可能形）。実体は scripts/lib/wf-args-probe.mjs。
#   本 script の責務は 3 つだけ: (a) 引数正規化 (b) probe の封じ込め (c) rc マッピング。
#
# ■ 使い方
#   scribe-wf-args-lint.sh --mode skeleton|adhoc (--file <path> | --stdin) [options]
#     --mode skeleton   骨格（workflows/*.workflow.js）: 挙動 probe + SCARGS block の sha256 byte-pin（--snippet 指定時）
#     --mode adhoc      ad-hoc script: 挙動 probe のみ
#     --mode 未指定は rc=2（path 推測に依存しない＝呼出元が対象種別を宣言する）
#   options:
#     --snippet <path>       canonical snippet（workflows/lib/args-preamble.snippet.js）= byte-pin の照合元
#     --expect canonical|legacy
#                            canonical（既定）= 病的 args で throw + agentCalls=0 を要求（P0-2 裁定）
#                            legacy           = agentCalls=0 のみ要求（escalate return 形の既存骨格用）
#     --probe-args <json>    病的 args を呼出元が verbatim 指定する（骨格別 allowlist の経路。指定時は宣言不要）
#     --required <a,b,c>     必須 args 集合を呼出元が指定する（宣言を持たない既存骨格用）
#     --base-args <json>     病的形を当てない残りの必須 args の埋め値（既定は非空の filler 文字列）
#     --label <text>         出力に載せる対象名（既定は --file の値）
#     --timeout <seconds>    probe の wall-clock 上限（env SCRIBE_WF_ARGS_LINT_TIMEOUT でも指定可）
#
# ■ rc 契約（**hook の exit code とは別物**）
#   0 = 合格 / 対象外（対象外は stdout へ `SKIP <path> <理由>` + stderr へ理由 1 行 + summary の skipped=N）
#   1 = 違反（stdout へ `VIOLATION <ID> ...`）
#   2 = 判定不能（stdout へ `INCONCLUSIVE <ID> ...`。parse 不能 / timeout / driver 起動失敗 / 宣言の静的動的不一致）
#   rc=2 を rc=0 へ丸めない（fail-open は本 leg が潰す失敗様式そのもの）。
#   Phase1(warn) / Phase2(deny) への写像（rc=2 をどちらへ倒すか）は**後続の hook wire leg の責務**であり、
#   本 engine は未裁定のまま素の 3 値を返す（engine 側で先取りして畳まない）。
#
# ■ probe の封じ込め（notes ■10）
#   probe は未レビュー script を素の node process で評価する面を持つ（node v18 系は権限フラグ非対応）。
#   よって timeout + 出力破棄 + 空 cwd + env 最小化 + **追加封じ込め(bwrap)** を必須とし、
#   それらを用意できない環境では probe を実行せず rc=2（INCONCLUSIVE PROBE_UNCONTAINED）に倒す。
#   本 leg の probe 対象は repo 内 script と bats fixture のみ。
#   任意 script を probe する hook wire は別 leg（PreToolUse probe (a) の結果次第）へ回す。
#
#   【封じ込めが守るもの／守らないもの（既知の穴・trusted-input 前提）】
#     上記の封じ込め（bwrap / env -i / 空 cwd / 出力破棄 / timeout）が抑えるのは**ホスト側の被害**であって、
#     **判定の真正性**ではない。被検査 script は probe runner と同一 node process 内で評価されるため、
#     process.argv から --report の path を読め、WORK_DIR は bwrap で書込可、process.exit も呼べる。
#     つまり被検査 script は判定チャネル（REPORT file）を掌握でき、`RC 0` / `OUT OK ...` を自分で書いて
#     VIOLATION を rc=0 に偽造できる（実測・tests/wf-args-lint.bats の forge tooth が現状仕様として pin する）。
#     よって **本 engine の入力は trusted（repo 内 script と bats fixture）に限る**。
#     任意 script を probe する hook wire leg の前提条件は「判定チャネルの分離」（シナリオ評価を子 process へ
#     出し、対象コードを一切 eval しない親だけが report を書く／report を fd 継承にして argv・env から path を消す）
#     であり、その実装は本 leg の射程外（別 leg）。
#
#   【notes ■10 の緊張点と、本 engine が採った読み（silently choose 回避のため明記する）】
#     ■10 は「追加の封じ込め（bwrap 等）が使えない環境では probe を rc=2 に落として実行しない」と定める。
#     一方 acceptance(2) は bats の green を要求するので、bwrap 非搭載ホストでは全 probe が rc=2 になり
#     bats が RED になる（＝両立しない読みが在る）。本 engine は **■10 の literal（fail-closed）を採る**:
#       - bwrap 不在 / 起動不能 → rc=2 で probe を実行しない（env 変数等の fail-open な escape hatch は置かない）。
#       - 空 cwd は fs 隔離ではない（実測: 対象 script が絶対パスで cwd の外へ書ける）ため、
#         実行側も bwrap で包む（/ は読取専用・書込は一時 WORK_DIR のみ・net 遮断）。
#     帰結として本 lint は bwrap 搭載ホストでのみ green になる。CI/他ホストへ広げる際は
#     「bwrap を前提に置く」か「■10 を緩める裁定を取る」かの選択が要る（後者は admin/裁定の領分・本 leg では未裁定）。

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROBE_MJS="$SCRIPT_DIR/lib/wf-args-probe.mjs"
# 既定 timeout（秒）。決め打ちを避けるため --timeout / SCRIBE_WF_ARGS_LINT_TIMEOUT で常に上書きできる。
readonly DEFAULT_TIMEOUT_SECONDS=60

MODE=""
FILE=""
USE_STDIN=0
SNIPPET=""
EXPECT=""
LABEL=""
TIMEOUT_SECONDS="${SCRIBE_WF_ARGS_LINT_TIMEOUT:-$DEFAULT_TIMEOUT_SECONDS}"
PROBE_ARGS_SET=0
PROBE_ARGS=""
REQUIRED_SET=0
REQUIRED=""
BASE_ARGS_SET=0
BASE_ARGS=""

die_inconclusive() {
  # $1 = ID, $2 = 詳細
  printf 'INCONCLUSIVE %s %s %s\n' "$1" "${LABEL:-${FILE:-(stdin)}}" "$2"
  exit 2
}

# probe は空 cwd で走らせるため、呼出元 cwd 基準の相対パスを先に絶対化しておく（相対のままだと ENOENT）。
abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$(pwd)" "$1" ;;
  esac
}

while [ $# -gt 0 ]; do
  # 値を取る option は、値が無いまま `shift 2` すると set -e で無出力 rc=1（＝偽 VIOLATION）になる。
  # rc 契約（1 は必ず stdout の `VIOLATION <ID>` を伴う）を破らないよう、使い方の誤りは rc=2 の
  # BAD_USAGE へ倒す（未知引数と同じ経路）。
  case "$1" in
    --mode|--file|--snippet|--expect|--label|--timeout|--probe-args|--required|--base-args)
      [ $# -ge 2 ] || die_inconclusive "BAD_USAGE" "$1 に値がない（値を取る option です）" ;;
  esac
  case "$1" in
    --mode) MODE="${2:-}"; shift 2 ;;
    --file) FILE="${2:-}"; shift 2 ;;
    --stdin) USE_STDIN=1; shift ;;
    --snippet) SNIPPET="${2:-}"; shift 2 ;;
    --expect) EXPECT="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --probe-args) PROBE_ARGS_SET=1; PROBE_ARGS="${2:-}"; shift 2 ;;
    --required) REQUIRED_SET=1; REQUIRED="${2:-}"; shift 2 ;;
    --base-args) BASE_ARGS_SET=1; BASE_ARGS="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die_inconclusive "BAD_USAGE" "未知の引数: $1" ;;
  esac
done

# --mode は必須（path から種別を推測しない）
if [ "$MODE" != "skeleton" ] && [ "$MODE" != "adhoc" ]; then
  die_inconclusive "MODE_UNSET" "--mode は skeleton|adhoc が必須（受領: ${MODE:-(none)}）"
fi
if [ "$USE_STDIN" -eq 0 ] && [ -z "$FILE" ]; then
  die_inconclusive "NO_INPUT" "--file または --stdin が必要"
fi

# 封じ込めの前提（timeout / node / env / bwrap / 一時 dir）が揃わない環境では probe を実行しない
NODE_BIN="$(command -v node || true)"
TIMEOUT_BIN="$(command -v timeout || true)"
ENV_BIN="$(command -v env || true)"
BWRAP_BIN="$(command -v bwrap || true)"
[ -n "$NODE_BIN" ] || die_inconclusive "PROBE_UNCONTAINED" "node が見つからない（probe を実行できない）"
[ -n "$TIMEOUT_BIN" ] || die_inconclusive "PROBE_UNCONTAINED" "timeout(1) が見つからない（封じ込め不能ゆえ probe を実行しない）"
[ -n "$ENV_BIN" ] || die_inconclusive "PROBE_UNCONTAINED" "env(1) が見つからない（env 最小化ができないゆえ probe を実行しない）"
[ -n "$BWRAP_BIN" ] || die_inconclusive "PROBE_UNCONTAINED" "追加封じ込め(bwrap)が無い環境ゆえ probe を実行しない（notes ■10）"
[ -f "$PROBE_MJS" ] || die_inconclusive "PROBE_UNCONTAINED" "probe runner が不在: $PROBE_MJS"
# 0 を弾く: GNU timeout は duration 0 を「上限なし」と解釈する（実測 `timeout 0 sleep 8` は 8s 完走 rc=0）。
# 受理すると「timeout が在るふりをして実際には無い」状態を env 変数 1 つで外から作れ、封じ込めの必須条件
# （notes ■10）が無言で無効化される。上限「値」の決め打ちではなく「正の整数であること」の検査なので
# 数値決め打ち禁止の fence には抵触しない。
case "$TIMEOUT_SECONDS" in
  ''|*[!0-9]*) die_inconclusive "BAD_USAGE" "--timeout は秒数（正の整数）: ${TIMEOUT_SECONDS}" ;;
esac
case "$TIMEOUT_SECONDS" in
  *[!0]*) : ;;
  *) die_inconclusive "BAD_USAGE" "--timeout に 0 は使えない（timeout(1) は 0 を『上限なし』と解釈し封じ込めが無効化される）: ${TIMEOUT_SECONDS}" ;;
esac

WORK_DIR="$(mktemp -d 2>/dev/null || true)"
[ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ] || die_inconclusive "PROBE_UNCONTAINED" "一時 dir を作れない（空 cwd を用意できないゆえ probe を実行しない）"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

if [ "$USE_STDIN" -eq 1 ]; then
  FILE="$WORK_DIR/stdin-source.js"
  cat > "$FILE"
  [ -n "$LABEL" ] || LABEL="(stdin)"
fi
[ -f "$FILE" ] || die_inconclusive "NO_INPUT" "対象 file が読めない: $FILE"
[ -n "$LABEL" ] || LABEL="$FILE"
FILE="$(abs_path "$FILE")"
if [ -n "$SNIPPET" ]; then
  [ -f "$SNIPPET" ] || die_inconclusive "NO_INPUT" "--snippet が読めない: $SNIPPET"
  SNIPPET="$(abs_path "$SNIPPET")"
fi

REPORT="$WORK_DIR/report.txt"
AGENT_MARKER="$WORK_DIR/agent-calls.txt"
: > "$AGENT_MARKER"
# probe の作業 cwd は空の dir（対象 script が相対パスで repo を触れないようにする）
EMPTY_CWD="$WORK_DIR/cwd"
mkdir -p "$EMPTY_CWD"

set -- --mode "$MODE" --file "$FILE" --report "$REPORT" --agent-marker "$AGENT_MARKER" --label "$LABEL"
[ -n "$EXPECT" ] && set -- "$@" --expect "$EXPECT"
[ -n "$SNIPPET" ] && set -- "$@" --snippet "$SNIPPET"
[ "$PROBE_ARGS_SET" -eq 1 ] && set -- "$@" --probe-args "$PROBE_ARGS"
[ "$REQUIRED_SET" -eq 1 ] && set -- "$@" --required "$REQUIRED"
[ "$BASE_ARGS_SET" -eq 1 ] && set -- "$@" --base-args "$BASE_ARGS"

# bwrap の追加封じ込め（fs 読取専用 + 書込は WORK_DIR のみ + net 遮断 + 空 cwd）。
# 引数の順序が意味を持つ: --ro-bind / / で全体を読取専用にした後に --bind "$WORK_DIR" で報告先だけ書込可にする。
BWRAP_ARGS=(--ro-bind / / --dev /dev --proc /proc --bind "$WORK_DIR" "$WORK_DIR" --chdir "$EMPTY_CWD" --unshare-net --die-with-parent)
# bwrap が在っても user namespace が塞がれた環境では起動できない。その場合も「封じ込め不能」として
# rc=2 に倒す（DRIVER_ERROR に化けさせない）。
"$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- "$ENV_BIN" -i "$NODE_BIN" --version >/dev/null 2>/dev/null ||
  die_inconclusive "PROBE_UNCONTAINED" "bwrap を起動できない（user namespace 不可等）ゆえ probe を実行しない"

# 封じ込め実行: bwrap + 空 cwd + env 最小化 + timeout + 出力破棄（判定は REPORT file 経由で回収する）
probe_status=0
"$TIMEOUT_BIN" "$TIMEOUT_SECONDS" \
  "$BWRAP_BIN" "${BWRAP_ARGS[@]}" -- "$ENV_BIN" -i "$NODE_BIN" "$PROBE_MJS" "$@" >/dev/null 2>/dev/null ||
  probe_status=$?

if [ "$probe_status" -eq 124 ] || [ "$probe_status" -eq 137 ]; then
  # timeout。ただし timeout 前に agent() が起動していれば「起動した」という実測は確定している（fail-closed）。
  if [ -s "$AGENT_MARKER" ]; then
    printf 'VIOLATION AGENT_STARTED_BEFORE_FAILFAST %s probe が timeout(%ss) したが、その前に agent() 起動を実測した\n' "$LABEL" "$TIMEOUT_SECONDS"
    exit 1
  fi
  die_inconclusive "TIMEOUT" "probe が ${TIMEOUT_SECONDS}s で終わらなかった（agent() 起動の実測は無し）"
fi

if [ ! -s "$REPORT" ]; then
  if [ -s "$AGENT_MARKER" ]; then
    printf 'VIOLATION AGENT_STARTED_BEFORE_FAILFAST %s probe runner が報告前に落ちた(exit=%s)が、agent() 起動を実測した\n' "$LABEL" "$probe_status"
    exit 1
  fi
  die_inconclusive "DRIVER_ERROR" "probe runner が報告を残さず終了（exit=${probe_status}）"
fi

# 報告の転記（RC/OUT/ERR の 3 種のみ。判定は runner 側で確定している＝ここは機械的な写経）
rc=""
while IFS= read -r line; do
  case "$line" in
    "RC "*) rc="${line#RC }" ;;
    "OUT "*) printf '%s\n' "${line#OUT }" ;;
    "ERR "*) printf '%s\n' "${line#ERR }" >&2 ;;
  esac
done < "$REPORT"

case "$rc" in
  0|1|2) exit "$rc" ;;
  *) die_inconclusive "DRIVER_ERROR" "probe runner の報告に有効な RC が無い（rc='${rc}' exit=${probe_status}）" ;;
esac

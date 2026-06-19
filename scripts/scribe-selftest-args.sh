#!/usr/bin/env bash
# scribe-selftest-args.sh — worker 自己点検用 cell-quality args(JSON) を組み立てる道具（D4・un-3yc）。
#
# worker は独立セッションで自分の issue を実装したあと、cell-quality WF を **自己点検** で 1 回呼ぶ
# （docs/protocol.md §2: 「cell-quality WF を worker が直接呼び出す」）。その args を LLM 任せで組むと
# 必須観点の欠落・autoFix ゲートの抜けが起きる（grill 合意 e5d79cc9 D4「現状 worker LLM 任せの穴」）。
# 本道具は worker 自己点検 args の **確定形** をコード化してその穴を塞ぐ。
#
# admin gate 版（scribe-gate-args.sh）との非対称（責務が違う）:
#   - gate-args = admin の一次監査 = read-only 固定（doImplement/autoFix/doPlan=false）。
#   - selftest-args = worker の自己点検 = **doImplement:false**（worker が自分で実装済み・WF に実装させない）
#     + **autoFix:true**（confirmed のみ gated 修正・worker cell 文脈）+ **selfTestCmd 必須**（fail-closed ゲート）。
#   どちらも snapshot 合成で worktree 指定→base...HEAD diff 自動取得（diff 静的供給は不要）。
#
# dimensions（D3）: 既定では渡さない → WF 本体が必須4観点（correctness/robustness-security/
#   integration-ops/completeness-critic）を補完する（worker 自己点検=4必須）。--add-dimension で
#   追加観点（key:focus）を積める（worker は focus 調整+追加観点が可）。WF 側が必須4へマージする。
# maxConcurrency（D2）: opus 経路（review/verify fan-out）の同時実行 cap。worker 自己点検は bounded
#   戦術 fan-out ゆえ既定 4（必須4観点と揃う安全既定）。--max-concurrency で上書き可。
#
# 出力: cell-quality WF へ渡す args JSON を stdout へ。
#
# Usage:
#   scribe-selftest-args.sh [options] <bd-id>
# Options:
#   --worktree PATH       自己点検対象 worktree（必須）
#   --self-test CMD       selfTestCmd = autoFix の fail-closed ゲート（必須）
#   --base REF            baseRef（既定: origin/main）
#   --anchor PATH         bd graph の所在（bd show 用・既定: cwd）
#   --model MODEL         review/verify モデル（既定: opus／fable 厳禁）
#   --max-concurrency N   opus 経路の同時実行 cap（正整数・既定: 4）
#   --task-type TYPE      task-type（既定: 未指定=WF が classify）
#   --add-dimension K:F   追加観点 key:focus（複数指定可・必須4へ WF がマージ）
#   --dry-run             bd show を省きプレースホルダで JSON を組む（実 bd 不要・構造検証用）
#   -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage: scribe-selftest-args.sh [options] <bd-id>
Options:
  --worktree PATH       自己点検対象 worktree（必須）
  --self-test CMD       selfTestCmd = autoFix の fail-closed ゲート（必須）
  --base REF            baseRef（既定: origin/main）
  --anchor PATH         bd graph の所在（bd show 用・既定: cwd）
  --model MODEL         review/verify モデル（既定: opus／fable 厳禁）
  --max-concurrency N   opus 経路の同時実行 cap（正整数・既定: 4）
  --task-type TYPE      task-type（既定: 未指定=WF が classify）
  --add-dimension K:F   追加観点 key:focus（複数指定可・必須4へ WF がマージ）
  --dry-run             bd show を省きプレースホルダで JSON を組む（実 bd 不要・構造検証用）
  -h | --help
EOF
  exit "${1:-0}"
}

WORKTREE=""
SELFTEST=""
BASE="origin/main"
ANCHOR="$(pwd)"
MODEL="opus"
MAX_CONCURRENCY="4"
TASK_TYPE=""
DIMS_RAW=""
DRY_RUN=0
BD_ID=""

# 値必須オプションのガードは lib の scribe_need_val（全道具共通・sc-2m0 facet1 で集約）。
# 「非空 かつ 先頭が '-' でない」を要求し、値を省いて次フラグを書いた場合の silent 消費を弾く。
# とりわけ --self-test は autoFix の fail-closed ゲートで WF の fixPrompt に生埋めされるため、bogus な
# gate コマンドへすり替わると fail-closed ゲートが silent 破壊される。先頭 '-' を弾いて fail-loud にする。
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)       scribe_need_val "${2:-}" --worktree; WORKTREE="$2"; shift 2 ;;
    --self-test)      scribe_need_val "${2:-}" --self-test; SELFTEST="$2"; shift 2 ;;
    --base)           scribe_need_val "${2:-}" --base; BASE="$2"; shift 2 ;;
    --anchor)         scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
    --model)          scribe_need_val "${2:-}" --model; MODEL="$2"; shift 2 ;;
    --max-concurrency)scribe_need_val "${2:-}" --max-concurrency; MAX_CONCURRENCY="$2"; shift 2 ;;
    --task-type)      scribe_need_val "${2:-}" --task-type; TASK_TYPE="$2"; shift 2 ;;
    --add-dimension)
      scribe_need_val "${2:-}" --add-dimension
      # focus/key に改行・タブが混ざると DIMS_RAW(タブ区切り・改行終端)が壊れ別観点へ silent に化ける。上流で弾く。
      case "$2" in *$'\n'*|*$'\t'*) scribe_die "--add-dimension に改行/タブは使えません(DIMS_RAW 区切りが壊れる): '$2'" ;; esac
      # 最初の ':' で key / focus を分割（focus 側に ':' を残す）。':' 不在は弾く。
      _k="${2%%:*}"; _f="${2#*:}"
      [[ "$2" == *:* && -n "$_k" ]] || scribe_die "--add-dimension は key:focus 形式（':' 必須・key 非空）: '$2'"
      # 必須4観点 key は追加扱いにしない（WF が必須枠で扱う）。誤用を上流で弾く。
      case "$_k" in
        correctness|robustness-security|integration-ops|completeness-critic)
          scribe_die "--add-dimension に必須4観点 key '$_k' は指定不可（WF が必須枠で扱う・追加は別 key で）" ;;
      esac
      DIMS_RAW+="$_k"$'\t'"$_f"$'\n'
      shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -h|--help)        usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  [[ -z "$BD_ID" ]] || scribe_die "bd id は 1 つだけ指定してください"; BD_ID="$1"; shift ;;
  esac
done
if [[ -z "$BD_ID" && $# -gt 0 ]]; then BD_ID="$1"; fi

[[ -n "$BD_ID" ]]   || scribe_die "bd id（必須引数）がありません。Usage は --help。"
[[ -n "$WORKTREE" ]] || scribe_die "--worktree（必須）がありません。"
[[ -n "$SELFTEST" ]] || scribe_die "--self-test（必須・autoFix の fail-closed ゲート）がありません。"
# worker は opus 必須（protocol.md §1）。fable 系は拒否（gate-args と対称）。
case "$MODEL" in *[Ff][Aa][Bb][Ll][Ee]*) scribe_die "--model に fable 系は使えません（worker は opus・protocol.md §1）" ;; esac
# max-concurrency は正整数（cap=並列上限）。0/負/非数は弾く（無 cap にしたいなら本道具を使わず WF へ直接）。
[[ "$MAX_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || scribe_die "--max-concurrency は正整数で指定してください: '$MAX_CONCURRENCY'"

ID="$(scribe_normalize_bd_id "$BD_ID")" || scribe_die "bd id の形式が不正です: '$BD_ID'"

# --- issue から taskTitle / goal / acceptance を合成 ---
TITLE="$ID"
DESC=""
if [[ "$DRY_RUN" -eq 1 ]]; then
  DESC="(dry-run: bd show 省略)"
  TITLE="$ID (dry-run)"
else
  SCRIBE_ANCHOR="$ANCHOR" scribe_bd_id_exists "$ID" \
    || scribe_die "bd issue が存在しません: '$ID'"
  DESC="$( ( cd "$ANCHOR" 2>/dev/null && "${SCRIBE_BD:-bd}" show "$ID" 2>/dev/null ) || true )"
  [[ -n "$DESC" ]] || DESC="(bd show 取得不可)"
fi

GOAL="self-review of $ID（worker 自己点検）: worktree=$WORKTREE の base...HEAD diff を review→verify→gated autoFix で点検する。契約 SSOT = bd $ID description。"
ACCEPTANCE="(1) 契約に対する diff の整合 (2) スコープ外編集ゼロ (3) self-test green（fail-closed ゲート） (4) confirmed blocking を gated autoFix で解消し loop-until-dry で収束。"

# --- args JSON を組む。doImplement/doPlan は false（worker 実装済）・autoFix は true（worker cell 文脈）固定 ---
# JSON エスケープは python3 に委譲（description の改行・引用符・追加観点を安全に通す）。
DESC="$DESC" TITLE="$TITLE" WORKTREE="$WORKTREE" BASE="$BASE" GOAL="$GOAL" \
ACCEPTANCE="$ACCEPTANCE" MODEL="$MODEL" SELFTEST="$SELFTEST" \
MAX_CONCURRENCY="$MAX_CONCURRENCY" TASK_TYPE="$TASK_TYPE" DIMS_RAW="$DIMS_RAW" python3 - <<'PY'
import json, os
desc = os.environ["DESC"]
ctx = ("scribe worker 自己点検（protocol.md §2: cell-quality WF を worker が直接呼び出す）。"
       "snapshot 合成で worktree 指定→base...HEAD diff 自動取得（diff 静的供給は不要）。"
       "doImplement=false（worker が自分で実装済み）/ autoFix=true（confirmed のみ gated 修正）。"
       "契約 description（抜粋）:\n" + desc[:1200])

args = {
    "taskTitle": os.environ["TITLE"],
    "worktree": os.environ["WORKTREE"],
    "baseRef": os.environ["BASE"],
    "goal": os.environ["GOAL"],
    "acceptance": os.environ["ACCEPTANCE"],
    "context": ctx,
    "selfTestCmd": os.environ["SELFTEST"],
    "model": os.environ["MODEL"],
    "maxConcurrency": int(os.environ["MAX_CONCURRENCY"]),
    # ↓ worker 自己点検の確定形: worker は自分で実装済み → 実装はさせず、confirmed のみ gated autoFix。
    "doPlan": False,
    "doImplement": False,
    "autoFix": True,
}

# task-type は指定時のみ載せる（未指定なら WF が classify）。
tt = os.environ.get("TASK_TYPE", "")
if tt:
    args["taskType"] = tt

# 追加観点（D3）: 指定時のみ dimensions を載せる（WF が必須4へマージ）。未指定なら WF が DEFAULT4 を補完。
dims_raw = os.environ.get("DIMS_RAW", "")
dimensions = []
for line in dims_raw.split("\n"):
    if not line.strip():
        continue
    key, _, focus = line.partition("\t")
    dimensions.append({"key": key, "focus": focus})
if dimensions:
    args["dimensions"] = dimensions

print(json.dumps(args, ensure_ascii=False, indent=2))
PY

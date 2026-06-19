#!/usr/bin/env bash
# scribe-gate-args.sh — gate review 用 cell-quality args(JSON) を組み立てる道具。
#
# admin の gate funnel（docs/protocol.md §5 step 2: cell-quality gate review = read-only・worktree 指定）
# で使う args JSON を、issue から worktree / goal / acceptance を合成して生成する。
# **read-only 固定が肝**: gate は実装も autoFix もしない一次監査なので、
#   doImplement:false / autoFix:false / doPlan:false を **ハードコードで固定** する（上書き不可）。
#   snapshot 合成（PR#346）により worktree 指定で WF が base...HEAD diff を自動取得するため diff 供給は不要。
#
# 出力: cell-quality WF へ渡す args JSON を stdout へ。
#
# Usage:
#   scribe-gate-args.sh [options] <bd-id>
# Options:
#   --worktree PATH  gate review 対象 worktree（必須）
#   --base REF       baseRef（既定: origin/main）
#   --anchor PATH    bd graph の所在（bd show 用・既定: cwd）
#   --model MODEL    review/verify モデル（既定: opus／fable 厳禁）
#   --dry-run        bd show を省きプレースホルダで JSON を組む（実 bd 不要・構造検証用）
#   -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage: scribe-gate-args.sh [options] <bd-id>
Options:
  --worktree PATH  gate review 対象 worktree（必須）
  --base REF       baseRef（既定: origin/main）
  --anchor PATH    bd graph の所在（bd show 用・既定: cwd）
  --model MODEL    review/verify モデル（既定: opus／fable 厳禁）
  --dry-run        bd show を省きプレースホルダで JSON を組む（実 bd 不要・構造検証用）
  -h | --help
EOF
  exit "${1:-0}"
}

WORKTREE=""
BASE="origin/main"
ANCHOR="$(pwd)"
MODEL="opus"
DRY_RUN=0
BD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) scribe_need_val "${2:-}" --worktree; WORKTREE="$2"; shift 2 ;;
    --base)     scribe_need_val "${2:-}" --base; BASE="$2"; shift 2 ;;
    --anchor)   scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
    --model)    scribe_need_val "${2:-}" --model; MODEL="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  [[ -z "$BD_ID" ]] || scribe_die "bd id は 1 つだけ指定してください"; BD_ID="$1"; shift ;;
  esac
done
if [[ -z "$BD_ID" && $# -gt 0 ]]; then BD_ID="$1"; fi

[[ -n "$BD_ID" ]] || scribe_die "bd id（必須引数）がありません。Usage は --help。"
[[ -n "$WORKTREE" ]] || scribe_die "--worktree（必須）がありません。"
case "$MODEL" in *fable*) scribe_die "--model に fable 系は使えません（gate は opus・protocol.md §1）" ;; esac

ID="$(scribe_normalize_bd_id "$BD_ID")" || scribe_die "bd id の形式が不正です: '$BD_ID'"

# --- issue から taskTitle / DESC を合成（lib に集約・DRY・sc-2m0 facet2）---
# scribe_synthesize_issue_desc が TITLE\0DESC を返す（DESC が最後・複数行ゆえ NUL 区切り）。
# dry-run 分岐・実在検証 die・取得不可 sentinel は関数内に閉じ込め済み（caller は 1 呼出）。
# 合成が die（bd 不在等）すると stdout が空→最初の read が EOF→非0 で caller も fail-loud に倒れる。
{ IFS= read -r -d '' TITLE && IFS= read -r -d '' DESC; } \
  < <(scribe_synthesize_issue_desc "$ID" "$DRY_RUN" "$ANCHOR") \
  || scribe_die "issue description の合成に失敗しました: '$ID'"

GOAL="gate review of $ID（read-only）: worktree=$WORKTREE の base...HEAD diff を一次監査する。契約 SSOT = bd $ID description。"
ACCEPTANCE="(1) 契約に対する diff の整合 (2) スコープ外編集ゼロ (3) self-test/bats green (4) findings は adversarial verify で refute 検証。gate は read-only=実装/autoFix しない。"

# --- args JSON を組む。doImplement/autoFix/doPlan は read-only 固定（ハードコード）---
# JSON エスケープは python3 に委譲（description の改行・引用符を安全に通す）。
DESC="$DESC" TITLE="$TITLE" WORKTREE="$WORKTREE" BASE="$BASE" GOAL="$GOAL" \
ACCEPTANCE="$ACCEPTANCE" MODEL="$MODEL" python3 - <<'PY'
import json, os
desc = os.environ["DESC"]
ctx = ("scribe gate review（admin gate funnel §5 step2）。"
       "snapshot 合成で worktree 指定→base...HEAD diff 自動取得（diff 静的供給は不要）。"
       "契約 description（抜粋）:\n" + desc[:1200])
args = {
    "taskTitle": os.environ["TITLE"],
    "worktree": os.environ["WORKTREE"],
    "baseRef": os.environ["BASE"],
    "goal": os.environ["GOAL"],
    "acceptance": os.environ["ACCEPTANCE"],
    "context": ctx,
    "taskType": "code",
    "model": os.environ["MODEL"],
    # ↓ read-only 固定（gate は実装も自動修正もしない一次監査）
    "doPlan": False,
    "doImplement": False,
    "autoFix": False,
}
print(json.dumps(args, ensure_ascii=False, indent=2))
PY

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
# effort（sc-7ac・sc-dc9 申し送り・sc-94z per-stage 化）: env CLAUDE_CODE_EFFORT_LEVEL（spawn が worker env へ
#   注入する実効 effort）を読んで args.effort へ焼く。フラグではない（worker 実効値を追随させる派生ノブ）。
#   allowlist(low|medium|high|xhigh|max)外・未設定は焼かず WF 側 fail-safe（既定 high）に委ねる。
#   ※sc-94z: WF 側で args.effort は「cell effort」へ再定義され **Plan/Implement 段にのみ**効く（guard 段
#   Review/Verify/Fix は high 固定で cell effort の一括下げから構造独立）。worker 自己点検は doImplement=false ゆえ
#   焼いた effort は主に返り値監査値・実装段が走る場合の追随値として効く。medium worker を模しても guard 段は
#   high に留まる（tests/cell-quality-selftest.bats の sc-o10 errata assert が e2e で pin）。
# reviewEffort/verifyEffort（sc-94z・guard 段の個別 opt-in knob）: 高リスク cell で guard 段（Review/Verify）を
#   xhigh 等へ上げたいとき --review-effort / --verify-effort で明示指定する（reviewModel/verifyModel と同流儀）。
#   明示フラグゆえ allowlist 外は fail-loud で die（env 由来 effort の fail-soft と posture が逆）。未指定は
#   焼かず WF 既定 high。検証は SSOT validator（scribe_effort_is_valid ← sc-ax4）を再利用し新検証路を作らない。
#   **上げる方向のみ opt-in**（sc-2wv）: guard 段は既定 high 固定で「gate 側を下げない」（methodology §1.1 但し書き
#   (1)）ゆえ high 未満（low/medium）は floor（scribe_effort_meets_guard_floor）未満で fail-loud に die する。
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
#   --review-effort LVL   review 段 effort の opt-in（既定: 未指定=WF 既定 high）。allowlist 完全一致・high 以上のみ（下げ不可・sc-2wv）
#   --verify-effort LVL   verify 段 effort の opt-in（既定: 未指定=WF 既定 high）。allowlist 完全一致・high 以上のみ（下げ不可・sc-2wv）
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
  --review-effort LVL   review 段 effort の opt-in（既定: 未指定=WF 既定 high）。allowlist 完全一致・high 以上のみ（下げ不可・sc-2wv）
  --verify-effort LVL   verify 段 effort の opt-in（既定: 未指定=WF 既定 high）。allowlist 完全一致・high 以上のみ（下げ不可・sc-2wv）
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
REVIEW_EFFORT="" # (sc-94z) review 段 per-stage effort の opt-in（未指定=WF 既定 high）
VERIFY_EFFORT="" # (sc-94z) verify 段 per-stage effort の opt-in（未指定=WF 既定 high）
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
    --review-effort)  scribe_need_val "${2:-}" --review-effort; REVIEW_EFFORT="$2"; shift 2 ;;
    --verify-effort)  scribe_need_val "${2:-}" --verify-effort; VERIFY_EFFORT="$2"; shift 2 ;;
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
# worker は opus 必須（protocol.md §1）。fable 系は拒否（gate-args / spawn と 3 兄弟対称）。
# case-insensitive を ${MODEL,,} 流へ統一（旧 glob `*[Ff][Aa]...` から・挙動は同値・sc-vuu facet4）。
case "${MODEL,,}" in *fable*) scribe_die "--model に fable 系は使えません（worker は opus・protocol.md §1）" ;; esac
# max-concurrency は正整数（cap=並列上限）。0/負/非数は弾く（無 cap にしたいなら本道具を使わず WF へ直接）。
[[ "$MAX_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || scribe_die "--max-concurrency は正整数で指定してください: '$MAX_CONCURRENCY'"
# reviewEffort/verifyEffort（sc-94z・guard 段の per-stage effort opt-in knob）: 明示フラグゆえ allowlist 外は
# fail-loud で弾く（env 由来 effort の fail-soft とは posture が逆＝admin/worker の明示指定だから）。SSOT validator
# （scribe_effort_is_valid ← sc-ax4）を再利用し新検証路を作らない。未指定は焼かず WF 既定 high に委ねる。
# guard 段は **上げる方向のみ opt-in**（sc-2wv）: guard 段（Review/Verify）は既定 high 固定で「gate 側を下げない」
# （methodology §1.1 但し書き(1)）。high 未満（low/medium）への下げは規約に存在しないため floor（scribe_effort_
# meets_guard_floor ← SCRIBE_GUARD_EFFORT_FLOOR=high）未満を明示フラグ posture のまま fail-loud で die する
# （WF 側は args 直叩き経路の二重防御として fail-safe→high+warn だが、こちらは admin/worker の明示指定ゆえ loud）。
if [[ -n "$REVIEW_EFFORT" ]]; then
  scribe_effort_is_valid "$REVIEW_EFFORT" || scribe_die "--review-effort は allowlist（$(scribe_effort_allowlist_join '|')）のいずれか完全一致: '$REVIEW_EFFORT'"
  scribe_effort_meets_guard_floor "$REVIEW_EFFORT" || scribe_die "--review-effort は guard 段の下限フロア（$SCRIBE_GUARD_EFFORT_FLOOR）未満へ下げられません（gate 側を下げない・methodology §1.1 但し書き(1)/sc-2wv）: '$REVIEW_EFFORT'。guard 段は既定 high 固定で、xhigh 等へ上げる方向のみ opt-in できます。"
fi
if [[ -n "$VERIFY_EFFORT" ]]; then
  scribe_effort_is_valid "$VERIFY_EFFORT" || scribe_die "--verify-effort は allowlist（$(scribe_effort_allowlist_join '|')）のいずれか完全一致: '$VERIFY_EFFORT'"
  scribe_effort_meets_guard_floor "$VERIFY_EFFORT" || scribe_die "--verify-effort は guard 段の下限フロア（$SCRIBE_GUARD_EFFORT_FLOOR）未満へ下げられません（gate 側を下げない・methodology §1.1 但し書き(1)/sc-2wv）: '$VERIFY_EFFORT'。guard 段は既定 high 固定で、xhigh 等へ上げる方向のみ opt-in できます。"
fi

# --- effort 伝播（sc-7ac・sc-dc9 申し送り）---
# worker の実効 effort（CC 正規名 CLAUDE_CODE_EFFORT_LEVEL・spawn が worker env へ後勝ち注入済み）を読んで
# cell-quality WF の args.effort へ焼く。目的: admin が --effort xhigh で spawn した worker の WF agent が
# selftest-args 経由だと args.effort 未供給で WF 既定 high のまま揃わない穴を塞ぐ（worker=high の既定ケースは
# もともと整合するが、xhigh worker で WF fan-out まで xhigh を通したい場合に効く）。
# allowlist(low|medium|high|xhigh|max)外・未設定は **焼かない**（EFFORT_LEVEL="" のまま）。WF 側は args.effort
# 欠落を既定 high へ倒す fail-safe を持つ（cell-quality.workflow.js の EFFORT_ALLOWED 判定）ため、上流で無理に
# fail-loud にせず「焼かない＝WF fail-safe に委譲」で二重防御と整合させる（spawn 側は spawn 時に fail-loud 済み）。
EFFORT_LEVEL=""
# allowlist 判定は scribe-lib の単一 SSOT（scribe_effort_is_valid ← SCRIBE_EFFORT_ALLOWLIST・sc-ax4）へ委譲。
# 一致時のみ焼き、未設定・allowlist 外は焼かず WF fail-safe（既定 high）に委ねる（従来挙動を保存）。
if scribe_effort_is_valid "${CLAUDE_CODE_EFFORT_LEVEL:-}"; then
  EFFORT_LEVEL="$CLAUDE_CODE_EFFORT_LEVEL"
fi

ID="$(scribe_normalize_bd_id "$BD_ID")" || scribe_die "bd id の形式が不正です: '$BD_ID'"

# --- issue から taskTitle / DESC を合成（lib に集約・DRY・sc-2m0 facet2）---
# scribe_synthesize_issue_desc が TITLE\0DESC を返す（DESC が最後・複数行ゆえ NUL 区切り）。
# dry-run 分岐・実在検証 die・取得不可 sentinel は関数内に閉じ込め済み（caller は 1 呼出）。
# 合成が die（bd 不在等）すると stdout が空→最初の read が EOF→非0 で caller も fail-loud に倒れる。
{ IFS= read -r -d '' TITLE && IFS= read -r -d '' DESC; } \
  < <(scribe_synthesize_issue_desc "$ID" "$DRY_RUN" "$ANCHOR") \
  || scribe_die "issue description の合成に失敗しました: '$ID'"

GOAL="self-review of $ID（worker 自己点検）: worktree=$WORKTREE の base...HEAD diff を review→verify→gated autoFix で点検する。契約 SSOT = bd $ID description。"
ACCEPTANCE="(1) 契約に対する diff の整合 (2) スコープ外編集ゼロ (3) self-test green（fail-closed ゲート） (4) confirmed blocking を gated autoFix で解消し loop-until-dry で収束。"

# --- args JSON を組む。doImplement/doPlan は false（worker 実装済）・autoFix は true（worker cell 文脈）固定 ---
# JSON エスケープは python3 に委譲（description の改行・引用符・追加観点を安全に通す）。
DESC="$DESC" TITLE="$TITLE" WORKTREE="$WORKTREE" BASE="$BASE" GOAL="$GOAL" \
ACCEPTANCE="$ACCEPTANCE" MODEL="$MODEL" SELFTEST="$SELFTEST" \
MAX_CONCURRENCY="$MAX_CONCURRENCY" TASK_TYPE="$TASK_TYPE" DIMS_RAW="$DIMS_RAW" \
EFFORT_LEVEL="$EFFORT_LEVEL" REVIEW_EFFORT="$REVIEW_EFFORT" VERIFY_EFFORT="$VERIFY_EFFORT" \
SCRIBE_ADD="$SCRIPT_DIR/scribe-add" python3 - <<'PY'
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
    # scribeAddPath（sc-u4u）: WF の gated autoFix が confirmed を修正後にコミットする際、Fix/implement agent が
    # stage に使う道具パス。CC sandbox は cwd の既知 dotfile/.claude を /dev/null character device 化し
    # `git add -A` を rc=128 で落とす（sc-yqa）。WF はこの値を受けると Fix/implement の stage を `git add -A`
    # でなく scribe-add（非通常ファイルを型で弾く薄ラッパ）に固定する。scribe-add は `git add -A` の安全上位互換
    # （通常ファイルでは等価・device のみ弾く）ゆえ SCRIBE_SANDBOX 検出に依らず常に渡せる＝どの hop でも
    # sandbox 判定が要らず決定論的（default-on への移行を SCRIBE_SANDBOX フラグから decouple する）。
    "scribeAddPath": os.environ["SCRIBE_ADD"],
    # ↓ worker 自己点検の確定形: worker は自分で実装済み → 実装はさせず、confirmed のみ gated autoFix。
    "doPlan": False,
    "doImplement": False,
    "autoFix": True,
}

# effort（sc-7ac）: allowlist を通った worker 実効 effort のみ載せる（未設定/allowlist 外は空→載せない）。
# 載せない場合は WF 側が args.effort 欠落を既定 high へ倒す fail-safe に委ねる（二重防御の整合）。
eff = os.environ.get("EFFORT_LEVEL", "")
if eff:
    args["effort"] = eff

# reviewEffort/verifyEffort（sc-94z）: 指定時のみ載せる（guard 段 Review/Verify を xhigh 等へ opt-in）。
# 未指定は載せず WF 既定 high に委ねる。値は上流で SSOT validator（scribe_effort_is_valid）を通過済み。
rev_eff = os.environ.get("REVIEW_EFFORT", "")
if rev_eff:
    args["reviewEffort"] = rev_eff
ver_eff = os.environ.get("VERIFY_EFFORT", "")
if ver_eff:
    args["verifyEffort"] = ver_eff

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

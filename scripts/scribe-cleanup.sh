#!/usr/bin/env bash
# scribe-cleanup.sh — merge 後の後片付けチェックリストを実行する道具。
#
# admin の gate funnel（docs/protocol.md §5 step7 cleanup / step8 dolt push 同期点）を 1 コマンド化。
# 掃除対象: worktree remove / branch -d / window kill / `bd dolt push` リマインド。
#
# 安全規律（CLAUDE.md 破壊的操作の禁止・protocol.md）:
#   - 破壊操作は **確認プロンプト付き**（--yes で一括承認）。
#   - **force 系は使わない**: branch は安全削除（merge 済み判定が要る削除）のみ・
#     worktree の force remove・履歴の hard reset・tmux サーバ破壊は **一切しない**。
#   - window kill は window ID @N を解決してから -t に渡す（dotted bd id の -t 衝突回避・protocol.md §1）。
#   - `bd dolt push` は admin 専用の同期点なので **自動実行せずリマインドのみ**（worker は push 禁止）。
#
# Usage:
#   scribe-cleanup.sh [options] <bd-id>
# Options:
#   --repo PATH      git リポジトリ（worktree/branch 操作の対象・
#                    既定: --worktree の所属リポを導出→無ければ cwd・bd un-c4s）
#   --worktree PATH  remove する worktree（既定: <repo>/.worktrees/spawn/<id>-* を案内）
#   --branch NAME    削除する branch（安全削除のみ・既定: 案内のみ）
#   --window NAME    kill する window 名（既定: wt-<id>）
#   --yes            確認プロンプトを省略（非対話・一括承認）
#   --dry-run        実行するはずのコマンド列を arg-echo するだけ
#   -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage: scribe-cleanup.sh [options] <bd-id>
Options:
  --repo PATH      git リポジトリ（worktree/branch 操作の対象・
                   既定: --worktree の所属リポを導出→無ければ cwd）
  --worktree PATH  remove する worktree
  --branch NAME    削除する branch（安全削除のみ）
  --window NAME    kill する window 名（既定: wt-<id>）
  --yes            確認プロンプトを省略（非対話・一括承認）
  --dry-run        実行するはずのコマンド列を arg-echo するだけ
  -h | --help
EOF
  exit "${1:-0}"
}

REPO=""
REPO_EXPLICIT=0     # --repo が明示指定されたか（明示は導出より優先・least-surprise）
WORKTREE=""
BRANCH=""
WINDOW=""
ASSUME_YES=0
DRY_RUN=0
BD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     scribe_need_val "${2:-}" --repo; REPO="$2"; REPO_EXPLICIT=1; shift 2 ;;
    --worktree) scribe_need_val "${2:-}" --worktree; WORKTREE="$2"; shift 2 ;;
    --branch)   scribe_need_val "${2:-}" --branch; BRANCH="$2"; shift 2 ;;
    --window)   scribe_need_val "${2:-}" --window; WINDOW="$2"; shift 2 ;;
    --yes)      ASSUME_YES=1; shift ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  [[ -z "$BD_ID" ]] || scribe_die "bd id は 1 つだけ指定してください"; BD_ID="$1"; shift ;;
  esac
done
if [[ -z "$BD_ID" && $# -gt 0 ]]; then BD_ID="$1"; fi

[[ -n "$BD_ID" ]] || scribe_die "bd id（必須引数）がありません。Usage は --help。"
ID="$(scribe_normalize_bd_id "$BD_ID")" || scribe_die "bd id の形式が不正です: '$BD_ID'"

[[ -n "$WINDOW" ]] || WINDOW="$(scribe_window_name "$ID")"   # 既定 wt-<id>

# --- REPO 解決（bd un-c4s: cross-repo cleanup の cwd 文脈依存バグ修正）---
# 優先順位: 明示 --repo > --worktree の所属リポ導出 > cwd。
# 既定を cwd 固定にすると、anchor cwd から別リポの worktree を掃除したとき
# git worktree remove / branch -d が anchor(cwd)に対して走り 'branch not found' で安全失敗する。
# --worktree が指定されていれば、そのパスが属するリポ（main worktree）を権威として導出する。
if [[ "$REPO_EXPLICIT" -eq 1 ]]; then
  :   # 明示指定を尊重（導出しない）
elif [[ -n "$WORKTREE" ]]; then
  if REPO="$(scribe_owning_repo "$WORKTREE")"; then
    echo "[cleanup] --repo 未指定 → --worktree の所属リポを導出: $REPO"
  else
    REPO="$(pwd)"
    echo "[cleanup] warn: --worktree '$WORKTREE' の所属リポを導出できず cwd を使用: $REPO（手動で --repo 指定を検討）"
  fi
else
  REPO="$(pwd)"
fi

# confirm <prompt> — DRY_RUN/--yes を尊重しつつ破壊操作の確認を取る **三値関数**（sc-vuu facet1）。
#   0 = 承認 / 1 = ユーザー拒否（N 等）/ 2 = EOF（確認入力が閉じている＝非対話・パイプ切れ）。
# EOF を拒否(1)と区別するのが肝: 区別しないと EOF も run_step の "skip" へ落ち exit 0 で
# 「未確認なのに成功扱い」する fail-open になる（lib の `read … || return 1`＝EOF fail-loud
# イディオムとの非対称が残り、将来の非対話 cleanup 機械化で黙って skip→成功扱いが再燃する）。
#   --dry-run/--yes は先行 return で read 不到達ゆえ三値化の影響なし（tests:824 不変）。
#   read が EOF で非0 を返しても、改行欠落で何か入力されていれば（ans 非空）通常回答として評価し、
#   何も入力されていない（ans 空）ときだけ EOF(2) に倒す（末尾改行欠落だけで EOF 扱いにしない）。
confirm() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local ans
  if ! read -r -p "scribe-cleanup: $1 を実行しますか? [y/N] " ans; then
    [[ -z "$ans" ]] && return 2   # 確認入力が閉じている（非対話/パイプ切れ）= EOF。skip と区別して fail-loud へ。
  fi
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# run_step <label> <cmd...> — dry-run は plan を echo、real は確認後に実行。
run_step() {
  local label="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[plan] $label: $*"
    return 0
  fi
  # confirm の三値（0/1/2）を取る。set -e 下では `confirm; rc=$?` が非0で中断するため `|| rc=$?` で捕捉。
  local rc=0
  confirm "$label" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    echo "→ $label: $*"
    # set -euo pipefail 下でも 1 step の失敗でチェックリストを中断させない。
    # 例: force 無しの `git worktree remove` は dirty で安全失敗するのが意図だが、bare 実行だと
    # その非 0 で script 全体が中断し、後続 step（window kill / dolt push リマインド）が出ない。
    # → 失敗を握って集計し、最後に終了コードへ反映する（fail-safe だが歩き切る）。force 系は導入しない。
    if ! "$@"; then
      echo "  warn: $label が失敗（安全失敗の可能性・手動対応を確認）"
      FAILED=$((FAILED + 1))
    fi
  elif [[ "$rc" -eq 2 ]]; then
    # EOF: 確認入力が EOF（非対話/パイプ切れ）＝未確認のため未実行。user-N の skip(exit0) と区別し
    # FAILED 計上で fail-loud（exit 非0）。run_step を歩き切る思想は保つ（即 die しない）。
    echo "  warn: $label の確認入力が EOF（非対話/パイプ切れ）＝未確認につき未実行。FAILED 計上で fail-loud。"
    FAILED=$((FAILED + 1))
  else
    echo "  skip: $label"
  fi
}

FAILED=0   # run_step が握った失敗の件数（最後に終了コードへ反映）
echo "[cleanup] issue=$ID（破壊操作は確認プロンプト付き・force 系は使わない）"

# --- 1. worktree remove（worktree 解決後）---
# --worktree 未指定なら .worktrees/spawn/<id>-* を案内（複数 HHMMSS があり得るので自動 remove しない）。
if [[ -n "$WORKTREE" ]]; then
  run_step "worktree remove" git -C "$REPO" worktree remove "$WORKTREE"
else
  echo "[checklist] worktree: --worktree 未指定。候補 → $REPO/.worktrees/spawn/$ID-*（確認の上 --worktree で指定）"
fi

# --- 2. branch 安全削除（merge 済みのみ通る -d。force 削除はしない）---
if [[ -n "$BRANCH" ]]; then
  run_step "branch 安全削除" git -C "$REPO" branch -d "$BRANCH"
else
  echo "[checklist] branch: --branch 未指定。候補 → spawn/$ID-*（merge 済みを確認の上 --branch で指定）"
fi

# --- 3. window kill（window ID @N を解決してから -t に渡す・protocol.md §1）---
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[plan] window kill（window ID @N 参照・dotted id の tmux -t 衝突回避）:"
  echo "         WID=\$(tmux list-windows -F '#{window_id} #{window_name}' | awk -v n='$WINDOW' '\$2==n{print \$1; exit}')   # → @N"
  echo "         tmux kill-window -t \"\$WID\"   # 名前ではなく ID で kill"
else
  WID="$(tmux list-windows -F '#{window_id} #{window_name}' 2>/dev/null | awk -v n="$WINDOW" '$2==n{print $1; exit}' || true)"
  if [[ -n "$WID" ]]; then
    run_step "window kill (@N=$WID)" tmux kill-window -t "$WID"
  else
    echo "[checklist] window: '$WINDOW' は見つからない（既に閉じている可能性）。skip。"
  fi
fi

# --- 4. dolt push 同期点（admin 専用＝自動実行しない・リマインドのみ・protocol.md §3/§5）---
echo "[checklist] 同期点: 一連の funnel が片付いたら admin が手動で 'bd dolt push'（worker/自動は push しない）"

# チェックリストは最後まで歩いた上で、握った失敗があれば終了コードに反映する（fail-closed）。
if [[ "$FAILED" -gt 0 ]]; then
  echo "[cleanup] done（issue=$ID・$FAILED 件の step が失敗＝手動確認が必要）"
  exit 1
fi
echo "[cleanup] done（issue=$ID）"

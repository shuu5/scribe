#!/usr/bin/env bash
# scribe-cleanup.sh — merge 後の後片付けチェックリストを実行する道具。
#
# admin の gate funnel（docs/protocol.md §5 step6 cleanup / step7 dolt push 同期点）を 1 コマンド化。
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
#   --repo PATH      git リポジトリ（worktree/branch 操作の対象・既定: cwd）
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
  --repo PATH      git リポジトリ（worktree/branch 操作の対象・既定: cwd）
  --worktree PATH  remove する worktree
  --branch NAME    削除する branch（安全削除のみ）
  --window NAME    kill する window 名（既定: wt-<id>）
  --yes            確認プロンプトを省略（非対話・一括承認）
  --dry-run        実行するはずのコマンド列を arg-echo するだけ
  -h | --help
EOF
  exit "${1:-0}"
}

REPO="$(pwd)"
WORKTREE=""
BRANCH=""
WINDOW=""
ASSUME_YES=0
DRY_RUN=0
BD_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)     [[ -n "${2:-}" ]] || scribe_die "--repo にパスを指定してください"; REPO="$2"; shift 2 ;;
    --worktree) [[ -n "${2:-}" ]] || scribe_die "--worktree にパスを指定してください"; WORKTREE="$2"; shift 2 ;;
    --branch)   [[ -n "${2:-}" ]] || scribe_die "--branch に名前を指定してください"; BRANCH="$2"; shift 2 ;;
    --window)   [[ -n "${2:-}" ]] || scribe_die "--window に名前を指定してください"; WINDOW="$2"; shift 2 ;;
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

# confirm <prompt> — DRY_RUN/--yes を尊重しつつ破壊操作の確認を取る。承認なら 0。
confirm() {
  [[ "$DRY_RUN" -eq 1 ]] && return 0
  [[ "$ASSUME_YES" -eq 1 ]] && return 0
  local ans
  read -r -p "scribe-cleanup: $1 を実行しますか? [y/N] " ans || return 1
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# run_step <label> <cmd...> — dry-run は plan を echo、real は確認後に実行。
run_step() {
  local label="$1"; shift
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[plan] $label: $*"
    return 0
  fi
  if confirm "$label"; then
    echo "→ $label: $*"
    # set -euo pipefail 下でも 1 step の失敗でチェックリストを中断させない。
    # 例: force 無しの `git worktree remove` は dirty で安全失敗するのが意図だが、bare 実行だと
    # その非 0 で script 全体が中断し、後続 step（window kill / dolt push リマインド）が出ない。
    # → 失敗を握って集計し、最後に終了コードへ反映する（fail-safe だが歩き切る）。force 系は導入しない。
    if ! "$@"; then
      echo "  warn: $label が失敗（安全失敗の可能性・手動対応を確認）"
      FAILED=$((FAILED + 1))
    fi
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

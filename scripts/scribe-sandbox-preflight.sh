#!/usr/bin/env bash
# scribe-sandbox-preflight.sh — SCRIBE_SANDBOX worker の OS sandbox 機構 deps を検査する道具（sc-u53）。
#
# 二役:
#   1. **spawn の seam**: scribe-spawn.sh が default-on（sc-u53）で worktree を作る前にこれを呼び、deps 欠如を
#      検出する。欠如時の方針（fail-loud / fallback）は spawn 側が決める（本道具は検査だけ＝policy を持たない）。
#      テスト時は SCRIBE_SANDBOX_PREFLIGHT で stub 差し替え可（SCRIBE_SANDBOX_GEN / SCRIBE_CLD_SPAWN と同型 seam）。
#   2. **ops 用 fleet チェック**: 人間が host で直接叩き「この host は sandbox 化できるか」を確認する。
#
# 出力契約（spawn の seam として機械可読）:
#   - 充足 → exit 0・stdout 空（friendly な OK は stderr へ）。
#   - 欠如 → **欠落理由を stdout に 1 行**・exit 1（spawn がこの stdout を fail-loud/fallback メッセージへ織り込む）。
#
# 判定の実体は scribe-lib.sh の scribe_sandbox_preflight（bubblewrap + socat + jq〔gen-sandbox-settings.sh の hard 依存〕
# + userns 実プローブ。global sysctl は読まず「実際に userns を作れるか」だけを見る＝targeted apparmor profile 方式でも信頼できる）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

if reason="$(scribe_sandbox_preflight)"; then
  echo "scribe-sandbox-preflight: OK（bubblewrap + socat + jq + userns 充足。この host は worker を sandbox 化できます）" >&2
  exit 0
else
  # 欠落理由は stdout（spawn の seam が捕捉する）。人間向けの文脈は stderr。
  printf '%s\n' "$reason"
  echo "scribe-sandbox-preflight: FAIL — $reason（詳細・導入手順は $SCRIPT_DIR/sandbox-spike/README.md）" >&2
  exit 1
fi

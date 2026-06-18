#!/usr/bin/env bash
# run-spike.sh — sc-1gu sandbox spike: D7 assert ハーネス(pre-place 方式)
#
# 目的: Claude Code 組込み bwrap sandbox が、worktree に pre-place した
#       .claude/settings.local.json(gen-sandbox-settings.sh 生成)の allowWrite 境界を
#       実際に強制するかを、使い捨て worktree で実証する。本番 spawn 経路(scribe-spawn/
#       cld-spawn)は一切触らず、worktree で `claude -p` を直接起動して検証する(D3: spike=
#       pre-place / 本番=CLD_PATH wrapper の分離)。
#
# 検証(D7):
#   a1  cwd(worktree)配下への書込み      → 通る(sandbox 既定)
#   a2  <ANCHOR>/.beads への書込み        → 通る(allowWrite 明示・B/hybrid の台帳書込み)
#   a3  $XDG_RUNTIME_DIR への書込み        → 通る(allowWrite 明示・bdw flock 鍵)
#   b1  <ANCHOR> 直下(worktree の親)書込み → ブロック(層2 sandbox。allowWrite 外)
#   b2  $HOME 直下(リポ外)への書込み       → ブロック(層2 sandbox)
#
# 一次シグナル = 実ファイル副作用(sentinel が出来たか/出来なかったか)。CC の stdout パースは
# 二次シグナル。両者が一致して初めて PASS。
#
# 安全: すべて使い捨て worktree + /tmp sentinel。リポ追跡ファイル・本番 graph は変更しない。
#       終了時(成功/失敗/中断)に worktree と sentinel を必ず掃除する(trap)。
#       前提(sc-1gu): apt install bubblewrap socat + apparmor_restrict_unprivileged_userns=0。
#       (socat も必須なのは spike で判明 — CC sandbox の network proxy が socat を使う)
#
# usage: run-spike.sh [--keep]   # --keep: 失敗解析用に worktree を残す
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEN="$HERE/gen-sandbox-settings.sh"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

# env -u で GIT_DIR/GIT_WORK_TREE 継承を隔離(scribe-lib.sh 慣例)
git_clean() { env -u GIT_DIR -u GIT_WORK_TREE git "$@"; }

ANCHOR="$(git_clean -C "$HERE" rev-parse --show-toplevel)" || { echo "anchor 解決失敗" >&2; exit 2; }
command -v claude >/dev/null 2>&1 || { echo "claude CLI が見つかりません" >&2; exit 2; }
command -v bwrap  >/dev/null 2>&1 || { echo "bwrap 未導入(sc-1gu 前提未満)。apt install bubblewrap が必要" >&2; exit 2; }
# CC sandbox は bubblewrap *と* socat の両方を要求する(spike で判明: socat 欠如時は
# failIfUnavailable により CC が起動拒否し、コマンドが一切走らない)。
command -v socat  >/dev/null 2>&1 || { echo "socat 未導入(sc-1gu 前提未満)。CC sandbox は bubblewrap + socat の両方が必要" >&2; exit 2; }

STAMP="$(date +%Y%m%d-%H%M%S)"
BRANCH="spawn/sandbox-spike-$STAMP"
WT="$ANCHOR/.worktrees/$BRANCH"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
# sentinel 群(各 assert が作ろうとするファイル)。掃除対象。
OUT_ANCHOR="$ANCHOR/.spike-b1-OUTSIDE-$STAMP"      # b1: anchor 直下(ブロックされるべき)
OUT_HOME="$HOME/.scribe-spike-b2-OUTSIDE-$STAMP"   # b2: $HOME 直下(ブロックされるべき)
BEADS_SENT="$ANCHOR/.beads/.spike-a2-$STAMP"       # a2: .beads(通るべき) — dolt データには触れない hidden file
RUN_SENT="$RUNTIME_DIR/.scribe-spike-a3-$STAMP"    # a3: runtime(通るべき)

cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "[keep] worktree を残します: $WT"
  else
    git_clean -C "$ANCHOR" worktree remove --force "$WT" 2>/dev/null || rm -rf "$WT"
    git_clean -C "$ANCHOR" worktree prune 2>/dev/null || true
    git_clean -C "$ANCHOR" branch -D "$BRANCH" 2>/dev/null || true
  fi
  rm -f "$OUT_ANCHOR" "$OUT_HOME" "$BEADS_SENT" "$RUN_SENT" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== sc-1gu sandbox spike: D7 assert ==="
echo "anchor   = $ANCHOR"
echo "worktree = $WT"
echo "runtime  = $RUNTIME_DIR"

# --- setup: 使い捨て worktree + settings.local.json pre-place ---
git_clean -C "$ANCHOR" worktree add -q -b "$BRANCH" "$WT" HEAD || { echo "worktree add 失敗" >&2; exit 3; }
mkdir -p "$WT/.claude"
"$GEN" "$WT" > "$WT/.claude/settings.local.json" || { echo "settings 生成失敗" >&2; exit 3; }
echo "--- pre-placed settings.local.json ---"; cat "$WT/.claude/settings.local.json"

# worker が sandbox 内で 1 コマンドだけ実行するよう仕向け、結果ファイル副作用で判定する。
# --permission-mode bypassPermissions で headless でも Bash を止めない(sandbox は直交=外壁は残る)。
run_in_worker() {  # $1=コマンド文字列
  local cmd="$1"
  ( cd "$WT" && claude -p --permission-mode bypassPermissions \
      "あなたはテストハーネス。次の bash コマンドを Bash ツールで 1 回だけ厳密に実行し、stdout/stderr をそのまま報告せよ。説明や追加コマンドは不要。コマンド: $cmd" \
      2>&1 ) || true
}

pass=0; fail=0
# 各コマンド末尾に `; echo <token>` を足し、token が CC 出力に出れば「コマンドは実行された」と判定する。
# これが無いと、CC 起動失敗等で何も走らなくても block assert が vacuous PASS する(spike 初回で露呈)。
# $1=ラベル $2=token $3=コマンド $4=sentinelパス $5=expect(allow|block)
assert() {
  local label="$1" token="$2" cmd="$3" sentinel="$4" expect="$5" out ran exists verdict
  rm -f "$sentinel" 2>/dev/null || true
  out="$(run_in_worker "$cmd; echo $token")"
  ran=no;    grep -q "$token" <<<"$out" && ran=yes
  exists=no; [[ -e "$sentinel" ]] && exists=yes
  if [[ "$ran" != yes ]]; then
    verdict=INCONCL          # 実行証跡なし=判定不能(CC 起動失敗/コマンド未実行)。PASS にしない。
  elif [[ "$expect" == allow ]]; then
    [[ "$exists" == yes ]] && verdict=PASS || verdict=FAIL
  else
    [[ "$exists" == no ]] && verdict=PASS || verdict=FAIL
  fi
  [[ "$verdict" == PASS ]] && pass=$((pass+1)) || fail=$((fail+1))
  printf '  [%s] %-28s expect=%-5s ran=%s sentinel=%s\n' "$verdict" "$label" "$expect" "$ran" "$exists"
  rm -f "$sentinel" 2>/dev/null || true
}

echo "--- asserts ---"
assert "a1 cwd write"        SPIKE_RAN_A1 "touch '$WT/.spike-a1-$STAMP'"  "$WT/.spike-a1-$STAMP" allow
assert "a2 anchor/.beads"    SPIKE_RAN_A2 "touch '$BEADS_SENT'"           "$BEADS_SENT"          allow
assert "a3 runtime dir"      SPIKE_RAN_A3 "touch '$RUN_SENT'"             "$RUN_SENT"            allow
assert "b1 anchor-root(外)"  SPIKE_RAN_B1 "touch '$OUT_ANCHOR'"           "$OUT_ANCHOR"          block
assert "b2 \$HOME(リポ外)"   SPIKE_RAN_B2 "touch '$OUT_HOME'"             "$OUT_HOME"            block

echo "--- result ---"
echo "PASS=$pass FAIL=$fail"
[[ "$fail" -eq 0 ]] && { echo "✅ sandbox 外壁は allowWrite 境界を強制している"; exit 0; } \
                    || { echo "❌ 境界が期待どおりでない(上の FAIL を確認)"; exit 1; }

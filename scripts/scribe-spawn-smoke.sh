#!/usr/bin/env bash
# scribe-spawn-smoke.sh — scribe-spawn.sh の transport 経路の腐敗を拾う smoke（AC9・sc-5rl）。
#
# ═══ honest 境界（★スクリプト冒頭に明記＝AC9 要件）═══
# 既定 = **dry-run smoke**（--transport tmux / bg の --dry-run plan 健全性 + flag parsing 回帰）:
#   このモードが検出できるのは scribe-spawn **自身の plan 生成 / flag parsing の回帰 + バイナリ存在**だけ。
#   検出できない（＝この smoke の射程外）: cld-spawn の契約変化・env-file の source 挙動・tmux の実 pane 挙動・
#   claude --bg の実挙動・sandbox の実 engage・env carrier の runtime 配送。これらの腐敗は dry-run では原理的に
#   拾えない（plan は実サブプロセスを起こさないため）。それらは --live（tmux 実 e2e）と admin の gate live 検証
#   （AC gate 3）の領分。dry-run smoke が緑でも「実 spawn が健全」を意味しない——plan と flag parsing が健全なだけ。
#
# --live = **tmux 実 e2e**（使い捨て worktree で --transport tmux 実 spawn → worker sentinel write→exit → 検証 →
#   scribe-cleanup.sh teardown）: 実サブプロセス（claude/tmux）を起こすため **admin/gate 側で叩く**。worker cell は
#   実 spawn 禁止（protocol worker 安全制約）。--live の定期 wire-up（cron/watch）は follow-up（既定 tmux ゆえ
#   tmux 経路は毎 spawn で走り腐敗露出は低・bg 既定化 PR で load-bearing 化）。
#
# Usage:
#   scribe-spawn-smoke.sh                 # dry-run smoke（既定・hermetic・bd stub + temp repo を自前で用意）
#   scribe-spawn-smoke.sh --live <bd-id>  # tmux 実 e2e（admin/gate 専用・実 spawn/teardown）
#   scribe-spawn-smoke.sh -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SPAWN="$SCRIPT_DIR/scribe-spawn.sh"
CLEANUP="$SCRIPT_DIR/scribe-cleanup.sh"

MODE="dry"
LIVE_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --live) MODE="live"; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    -*) echo "smoke: 未知のオプション: $1" >&2; exit 2 ;;
    *)  LIVE_ID="$1"; shift ;;
  esac
done

_fail() { echo "smoke: FAIL: $*" >&2; exit 1; }
_ok()   { echo "smoke: ok: $*"; }

# ---------------------------------------------------------------------------
# dry-run smoke（既定・hermetic）
# ---------------------------------------------------------------------------
smoke_dry() {
  command -v git >/dev/null 2>&1 || _fail "git が不在（dry-run smoke には temp repo が要る）"
  [[ -x "$SPAWN" ]] || _fail "scribe-spawn.sh が実行可能でない: $SPAWN"

  # hermetic な bd stub（実 graph 不要・実在検証だけを OK にする）と temp git repo を用意する。
  local tmp bd repo id
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN
  bd="$tmp/bd-stub"
  # scribe-spawn は SCRIBE_BD 経由で `bd show <id>` 相当の実在検証を叩く。stub は OK id に exit0 を返す。
  cat > "$bd" <<'BDEOF'
#!/usr/bin/env bash
# 最小 bd stub: `show <id>` で OK id なら exit0。それ以外は exit1（実在せず）。
if [[ "${1:-}" == "show" ]]; then
  case "${2:-}" in sc-smoke) exit 0 ;; *) exit 1 ;; esac
fi
exit 0
BDEOF
  chmod +x "$bd"
  repo="$tmp/repo"
  git -C "$tmp" -c init.defaultBranch=main init -q repo
  git -C "$repo" config user.email s@e; git -C "$repo" config user.name s
  git -C "$repo" commit -q --allow-empty -m init
  id="sc-smoke"

  # 共通 env: bd stub / 決定論 HHMMSS / cld-spawn は dry-run では起動されない（feature-detect の --help 到達だけ）。
  # SCRIBE_USAGE_CMD は不在パスへ固定（bats setup 群と同流儀・sc-9954 gate）: worker 既定 auto 化後、これが無いと
  # claude-usage 導入済みホストで default dry-run が実 selector を叩き plan 出力がホストごとに揺れる（hermetic 破れ）。
  # 不在パス → selector exit 3（API 故障）→ 主アカ fallback ＝全ホスト決定論。
  local -a envc=(env
    "SCRIBE_BD=$bd" "SCRIBE_HHMMSS=101010" "SCRIBE_CLD_SPAWN=cld-spawn"
    "SCRIBE_CLAUDE_BIN=claude" "SCRIBE_USAGE_CMD=$tmp/scribe-no-usage-cmd")

  # --- (1) transport=tmux（既定）dry-run plan 健全性 ---
  local out_tmux out_default
  out_tmux="$("${envc[@]}" "$SPAWN" --repo "$repo" --anchor "$repo" --transport tmux --dry-run "$id" 2>/dev/null)" \
    || _fail "tmux dry-run が非0で終了（flag parsing / plan 生成の回帰）"
  grep -qF -- '--bd-id sc-smoke' <<<"$out_tmux" || _fail "tmux plan に --bd-id が無い"
  # dry-run 出力では $WORKER_DISALLOWED_TOOLS は展開済（1 argv 二重引用の値そのもの）。
  grep -qF -- '--disallowed-tools "AskUserQuestion,ExitPlanMode"' <<<"$out_tmux" || _fail "tmux plan に cld-spawn 起動行（1 argv disallowed-tools）が無い"
  grep -qF -- 'capture-pane' <<<"$out_tmux" || _fail "tmux plan に capture-pane monitor が無い"
  _ok "transport=tmux dry-run plan 健全"

  # --- (2) 既定（--transport 省略）== --transport tmux が **byte 等価**（AC7/AC10 回帰 pin）---
  out_default="$("${envc[@]}" "$SPAWN" --repo "$repo" --anchor "$repo" --dry-run "$id" 2>/dev/null)" \
    || _fail "既定 dry-run が非0で終了"
  [[ "$out_default" == "$out_tmux" ]] || _fail "既定 dry-run plan が --transport tmux と byte 等価でない（tmux 恒久 fallback の byte 不変が破れた）"
  _ok "既定 == --transport tmux（byte 等価）"

  # --- (3) transport=bg dry-run plan 回帰（bg 固有行の存在）---
  local out_bg
  out_bg="$("${envc[@]}" "$SPAWN" --repo "$repo" --anchor "$repo" --transport bg --dry-run "$id" 2>/dev/null)" \
    || _fail "bg dry-run が非0で終了（flag parsing / plan 生成の回帰）"
  grep -qF -- 'transport=bg' <<<"$out_bg" || _fail "bg plan に transport=bg 行が無い"
  grep -qE -- '--bg ' <<<"$out_bg"        || _fail "bg plan に claude --bg 起動構成が無い"
  grep -qF -- '--plugin-dir' <<<"$out_bg" || _fail "bg plan に --plugin-dir 武装が無い"
  grep -qF -- 'env block' <<<"$out_bg"    || _fail "bg plan に env carrier 合成の記述が無い"
  grep -qF -- 'commit sentinel' <<<"$out_bg" || _fail "bg plan に commit sentinel monitor が無い"
  _ok "transport=bg dry-run plan 健全"

  # --- (4) transport=auto dry-run plan 回帰（fallback 注記）---
  local out_auto
  out_auto="$("${envc[@]}" "$SPAWN" --repo "$repo" --anchor "$repo" --transport auto --dry-run "$id" 2>/dev/null)" \
    || _fail "auto dry-run が非0で終了"
  grep -qF -- 'transport=auto' <<<"$out_auto" || _fail "auto plan に transport=auto 行が無い"
  grep -qF -- 'tmux' <<<"$out_auto"           || _fail "auto plan に tmux fallback 注記が無い"
  _ok "transport=auto dry-run plan 健全"

  # --- (5) 不正 transport は fail-loud（dry-run でも先に die）---
  if "${envc[@]}" "$SPAWN" --repo "$repo" --anchor "$repo" --transport nope --dry-run "$id" >/dev/null 2>&1; then
    _fail "不正 --transport 値が fail-loud しない"
  fi
  _ok "不正 --transport は fail-loud"

  echo "smoke: PASS（dry-run smoke・honest 境界: plan/flag parsing/バイナリ存在のみ。cld-spawn/env-file/tmux/bg 実挙動は未検出＝--live / admin gate の領分）"
}

# ---------------------------------------------------------------------------
# --live: tmux 実 e2e（admin/gate 専用・実 spawn/teardown）
# ---------------------------------------------------------------------------
smoke_live() {
  [[ -n "$LIVE_ID" ]] || _fail "--live には実在する bd-id が必要です（例: scribe-spawn-smoke.sh --live sc-xxx）"
  command -v tmux >/dev/null 2>&1 || _fail "--live には tmux が必要です"
  echo "smoke(--live): tmux 実 e2e を開始します（実 spawn → sentinel → teardown・admin/gate 専用）: id=$LIVE_ID" >&2
  # 使い捨て worktree で --transport tmux 実 spawn。実 claude/tmux を起こすため worker cell では叩かない
  # （protocol worker 安全制約）。実装は admin/gate が本番環境で最終確定する（本 cell は骨格を置く）。
  echo "smoke(--live): この経路は実サブプロセス（claude/tmux）を起こすため admin/gate 環境でのみ実行してください。" >&2
  echo "smoke(--live): 手順 = (1) $SPAWN --transport tmux <id> で実 spawn → (2) worker が commit sentinel を write→exit するのを待つ →" >&2
  echo "smoke(--live):       (3) git -C <worktree> log で sentinel 検証 → (4) $CLEANUP で teardown（force 禁止・確認付き）。" >&2
  _fail "--live は admin/gate 環境向け骨格です（worker cell からの実 spawn は protocol 禁止）。dry-run smoke（引数なし）を使ってください。"
}

case "$MODE" in
  dry)  smoke_dry ;;
  live) smoke_live ;;
esac

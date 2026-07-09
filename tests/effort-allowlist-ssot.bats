#!/usr/bin/env bats
# effort allowlist の単一 SSOT（scripts/lib/scribe-lib.sh の SCRIBE_EFFORT_ALLOWLIST・sc-ax4）と
# その consumer 群の整合を pin する drift 検知テスト。従来 low|medium|high|xhigh|max が
# scribe-spawn.sh / scribe-selftest-args.sh / cell-quality.workflow.js に literal 重複していたのを
# lib へ集約し、JS mirror（WF sandbox で source 不可ゆえ literal 複製）の drift をここで fail-loud にする。
# 目的（sc-7ac→sc-ax4 申し送り）: CC が新 effort tier を足した際の「同時更新漏れ」を検知可能にする。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/scribe-lib.sh"
  SPAWN="$REPO_ROOT/scripts/scribe-spawn.sh"
  SELFTEST="$REPO_ROOT/scripts/scribe-selftest-args.sh"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  # SSOT（変数・関数）を得るため lib を source する（source 専用ヘルパゆえ副作用なし・set -e は張らない）。
  # shellcheck source=../scripts/lib/scribe-lib.sh
  source "$LIB"
}

# ── SSOT 実体: CC 正規 5 値・順序どおり ──
@test "sc-ax4: SCRIBE_EFFORT_ALLOWLIST が CC 正規 5 値（low medium high xhigh max）である" {
  [ "${#SCRIBE_EFFORT_ALLOWLIST[@]}" -eq 5 ]
  [ "$(scribe_effort_allowlist_join ' ')" = "low medium high xhigh max" ]
  [ "$(scribe_effort_allowlist_join '|')" = "low|medium|high|xhigh|max" ]
}

# ── validator: 完全一致のみ受理 ──
@test "sc-ax4: scribe_effort_is_valid は allowlist 完全一致（5 値）を受理する" {
  for v in low medium high xhigh max; do
    scribe_effort_is_valid "$v"
  done
}

@test "sc-ax4: scribe_effort_is_valid は allowlist 外・空・大文字・空白混じりを拒否する" {
  for v in ultra "" HIGH " high" "high " xhi highmax; do
    run scribe_effort_is_valid "$v"
    [ "$status" -ne 0 ]
  done
}

# ── bash consumer が SSOT validator を経由する（生 literal case を再導入していない）──
@test "sc-ax4: scribe-spawn.sh の effort 検証は SSOT validator を経由する" {
  grep -q 'scribe_effort_is_valid "\$EFFORT"' "$SPAWN"
  # 旧 case-arm literal（`low|medium|high|xhigh|max) ;;`）が消えていること（doc/help の prose 出現は許す）。
  ! grep -qE 'low\|medium\|high\|xhigh\|max\)[[:space:]]*;;' "$SPAWN"
}

@test "sc-ax4: scribe-selftest-args.sh の effort 焼き込みは SSOT validator を経由する" {
  grep -q 'scribe_effort_is_valid "\${CLAUDE_CODE_EFFORT_LEVEL:-}"' "$SELFTEST"
  # 旧 case-arm literal（`low|medium|high|xhigh|max) EFFORT_LEVEL=...`）が消えていること。
  ! grep -qE 'low\|medium\|high\|xhigh\|max\)[[:space:]]*EFFORT_LEVEL=' "$SELFTEST"
}

# ── JS mirror ↔ bash SSOT: drift 検知（本 issue の核） ──
@test "sc-ax4: cell-quality.workflow.js の EFFORT_ALLOWED が bash SSOT と完全一致する（drift 検知）" {
  [ -f "$WF" ]
  local js_line js_members bash_members
  # `EFFORT_ALLOWED = new Set([...])` の中身を 1 行抽出（[^]]* で最初の ']' まで＝集合内に ']' なし）。
  js_line="$(grep -oE "EFFORT_ALLOWED = new Set\(\[[^]]*\]\)" "$WF")"
  [ -n "$js_line" ]
  # クオート語を取り出し、'' を剥がして sort し集合比較（順序非依存）。抽出は tier の文字種に依存しない
  # 一般クオート語 '[^']+' で行う（将来 CC が数字/ハイフン/大文字入り tier を JS だけに足し bash SSOT に
  # 足し忘れた場合でも JS メンバを取りこぼさず真の drift を検知する＝fail-open を残さない・sc-ax4 verify 指摘）。
  js_members="$(printf '%s' "$js_line" | grep -oE "'[^']+'" | tr -d "'" | sort | tr '\n' ' ')"
  bash_members="$(printf '%s\n' "${SCRIBE_EFFORT_ALLOWLIST[@]}" | sort | tr '\n' ' ')"
  [ "$js_members" = "$bash_members" ]
}

# === guard 段 effort 下限フロア（sc-2wv）: rank/floor ヘルパ + JS mirror の順序 drift 検知 ==========
# guard knob（reviewEffort/verifyEffort）を high 未満へ下げさせない floor の SSOT を pin する。rank は
# EFFORT_ALLOWED（集合）とは別概念だが同じ順序付き配列 SCRIBE_EFFORT_ALLOWLIST から index として導く。

# ── rank: allowlist の intensity 順位（index）を返す・allowlist 外は非0 ──
@test "sc-2wv: scribe_effort_rank が intensity 昇順 index を返す（allowlist 外・空は非0）" {
  [ "$(scribe_effort_rank low)" = "0" ]
  [ "$(scribe_effort_rank medium)" = "1" ]
  [ "$(scribe_effort_rank high)" = "2" ]
  [ "$(scribe_effort_rank xhigh)" = "3" ]
  [ "$(scribe_effort_rank max)" = "4" ]
  for v in ultra "" HIGH " high"; do
    run scribe_effort_rank "$v"
    [ "$status" -ne 0 ]
  done
}

# ── floor: guard 下限フロア（high）以上のみ受理・low/medium 拒否 ──
@test "sc-2wv: scribe_effort_meets_guard_floor は high 以上のみ受理（low/medium・allowlist 外を拒否）" {
  [ "$SCRIBE_GUARD_EFFORT_FLOOR" = "high" ]
  for v in high xhigh max; do
    scribe_effort_meets_guard_floor "$v"
  done
  for v in low medium ultra "" HIGH; do
    run scribe_effort_meets_guard_floor "$v"
    [ "$status" -ne 0 ]
  done
}

# ── JS mirror ↔ bash SSOT: EFFORT_RANK_ORDER の順序込み drift 検知（rank は index 依存ゆえ順序を pin）──
@test "sc-2wv: cell-quality.workflow.js の EFFORT_RANK_ORDER が bash SSOT と順序込みで一致する（rank drift 検知）" {
  [ -f "$WF" ]
  local js_line js_members bash_members
  js_line="$(grep -oE "EFFORT_RANK_ORDER = \[[^]]*\]" "$WF")"
  [ -n "$js_line" ]
  # 順序を保って抽出（sort しない）＝rank は配列 index 依存ゆえ集合一致でなく順序一致を要求する。
  js_members="$(printf '%s' "$js_line" | grep -oE "'[^']+'" | tr -d "'" | tr '\n' ' ')"
  bash_members="$(printf '%s ' "${SCRIBE_EFFORT_ALLOWLIST[@]}")"
  [ "$js_members" = "$bash_members" ]
}

# ── WF の guard floor 定数が bash SSOT floor と一致する（policy 値の drift 検知）──
@test "sc-2wv: cell-quality.workflow.js の GUARD_EFFORT_FLOOR が bash SCRIBE_GUARD_EFFORT_FLOOR と一致する" {
  [ -f "$WF" ]
  grep -q "const GUARD_EFFORT_FLOOR = '$SCRIBE_GUARD_EFFORT_FLOOR'" "$WF"
}

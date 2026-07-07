#!/usr/bin/env bats
# scribe-selftest-args.sh の effort 伝播（sc-7ac・sc-dc9 申し送り）を pin する専用 bats。
# 共有の tests/scribe-tools.bats を編集せず新規ファイルで足す（並走 lane との衝突回避＝sc-7ac スコープ）。
# 検証: worker 実効 effort（CLAUDE_CODE_EFFORT_LEVEL）が allowlist 内なら args.effort へ焼け、
#       未設定 / allowlist 外なら **焼かない**（WF 側 fail-safe に委譲）＝effort キーの有無 2 系。
# 実 spawn・実 bd はしない（--dry-run + プレースホルダのみ）。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  SELFTEST="$SCRIPTS/scribe-selftest-args.sh"
  # dry-run 経路ゆえ実 bd は不要だが、ホスト側の effort env が漏れてテストを汚さないよう毎回落とす。
  unset CLAUDE_CODE_EFFORT_LEVEL
}

# ヘルパ: dry-run で args JSON を出し、effort キーの有無/値を python で読む。
_effort_of() {
  echo "$1" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("effort","<absent>"))'
}
_has_effort() {
  echo "$1" | python3 -c 'import json,sys; print("effort" in json.load(sys.stdin))'
}

# --- 系1: allowlist 内は焼ける（正規 5 値すべて） ---
@test "selftest-args(sc-7ac): CLAUDE_CODE_EFFORT_LEVEL が allowlist 内なら args.effort へ焼ける（5 値）" {
  for lvl in low medium high xhigh max; do
    CLAUDE_CODE_EFFORT_LEVEL="$lvl" run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' un-4nm
    [ "$status" -eq 0 ]
    echo "$output" | python3 -m json.tool >/dev/null              # valid JSON
    [ "$(_has_effort "$output")" = "True" ]
    [ "$(_effort_of "$output")" = "$lvl" ]
  done
}

# --- 系2a: 未設定なら effort キーを載せない（WF fail-safe に委譲） ---
@test "selftest-args(sc-7ac): CLAUDE_CODE_EFFORT_LEVEL 未設定なら effort キーを載せない" {
  # setup で unset 済み。念のため env から外して起動。
  run env -u CLAUDE_CODE_EFFORT_LEVEL "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(_has_effort "$output")" = "False" ]
}

# --- 系2b: allowlist 外（bogus / 空）なら焼かない＝fail-loud にせず WF fail-safe に委譲 ---
@test "selftest-args(sc-7ac): CLAUDE_CODE_EFFORT_LEVEL が allowlist 外なら焼かず（die せず）出力は成功" {
  CLAUDE_CODE_EFFORT_LEVEL="ultra" run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' un-4nm
  [ "$status" -eq 0 ]                     # 上流で fail-loud にしない（spawn 側が spawn 時に検証済み）
  [ "$(_has_effort "$output")" = "False" ]

  CLAUDE_CODE_EFFORT_LEVEL="" run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' un-4nm
  [ "$status" -eq 0 ]
  [ "$(_has_effort "$output")" = "False" ]

  # 大文字/前後空白などの近縁 bogus も allowlist（完全一致）を外れる＝焼かない。
  CLAUDE_CODE_EFFORT_LEVEL="HIGH" run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' un-4nm
  [ "$status" -eq 0 ]
  [ "$(_has_effort "$output")" = "False" ]
}

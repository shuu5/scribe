#!/usr/bin/env bats
# scribe-gate-args.sh / scribe-selftest-args.sh の --context-file 配線（sc-eqvv・sc-mbcm follow-up）を pin する専用 bats。
# 共有の tests/scribe-tools.bats を編集せず新規ファイルで足す（selftest-args-effort.bats と同じ衝突回避方針）。
#
# 検証（両 builder 対称）:
#   [1] 妥当な readable ファイル → args JSON に contextFile キーが path そのままで載る
#   [2] 未指定 → contextFile キーを載せない（既存呼出元への回帰なし）
#   [3] 安全文字クラス外の path（空白等）→ 非ゼロ die（WF 側は silent 破棄する graceful ゆえ builder が fail-loud）
#   [4] 実在しない/読めない path → 非ゼロ die（typo を WF 起動前に捕捉）
# 実 spawn・実 bd はしない（--dry-run + プレースホルダのみ）。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  GATE="$SCRIPTS/scribe-gate-args.sh"
  SELFTEST="$SCRIPTS/scribe-selftest-args.sh"
  TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/scribe-ctxfile-XXXXXX")"
  CTX_OK="$TEST_TMPDIR/brief.md"
  printf 'context body\n' > "$CTX_OK"
}

teardown() {
  [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# ヘルパ: JSON から contextFile キーの有無/値を読む（selftest-args-effort.bats の _has_key/_val_of と同型）。
_has_ctx() {
  echo "$1" | python3 -c 'import json,sys; print("contextFile" in json.load(sys.stdin))'
}
_ctx_of() {
  echo "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("contextFile","<absent>"))'
}

# --- [1] 妥当 path → 載る ---
@test "gate-args(sc-eqvv): --context-file 妥当 path は args.contextFile へそのまま載る" {
  run "$GATE" --dry-run --worktree /tmp/wt --context-file "$CTX_OK" sc-xxx
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(_has_ctx "$output")" = "True" ]
  [ "$(_ctx_of "$output")" = "$CTX_OK" ]
}

@test "selftest-args(sc-eqvv): --context-file 妥当 path は args.contextFile へそのまま載る" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' --context-file "$CTX_OK" sc-xxx
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(_has_ctx "$output")" = "True" ]
  [ "$(_ctx_of "$output")" = "$CTX_OK" ]
}

# --- [2] 未指定 → 載せない（回帰なし） ---
@test "gate-args(sc-eqvv): --context-file 未指定なら contextFile キーを載せない" {
  run "$GATE" --dry-run --worktree /tmp/wt sc-xxx
  [ "$status" -eq 0 ]
  [ "$(_has_ctx "$output")" = "False" ]
}

@test "selftest-args(sc-eqvv): --context-file 未指定なら contextFile キーを載せない" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' sc-xxx
  [ "$status" -eq 0 ]
  [ "$(_has_ctx "$output")" = "False" ]
}

# --- [3] 安全文字クラス外 → fail-loud die（WF の silent 破棄に先回り） ---
@test "gate-args(sc-eqvv): 安全文字クラス外 path（空白入り）は非ゼロ die し安全文字クラスのメッセージ" {
  local bad="$TEST_TMPDIR/ctx dir/brief.md"
  mkdir -p "$TEST_TMPDIR/ctx dir"; printf 'x\n' > "$bad"
  run "$GATE" --dry-run --worktree /tmp/wt --context-file "$bad" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"安全文字クラス外"* ]]
}

@test "selftest-args(sc-eqvv): 安全文字クラス外 path（空白入り）は非ゼロ die し安全文字クラスのメッセージ" {
  local bad="$TEST_TMPDIR/ctx dir/brief.md"
  mkdir -p "$TEST_TMPDIR/ctx dir"; printf 'x\n' > "$bad"
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' --context-file "$bad" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"安全文字クラス外"* ]]
}

# --- [4] 実在しない path → fail-loud die（typo の早期捕捉） ---
@test "gate-args(sc-eqvv): 実在しない path は非ゼロ die し読めない旨のメッセージ" {
  run "$GATE" --dry-run --worktree /tmp/wt --context-file "$TEST_TMPDIR/no-such.md" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"読める通常ファイルではありません"* ]]
}

@test "selftest-args(sc-eqvv): 実在しない path は非ゼロ die し読めない旨のメッセージ" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' --context-file "$TEST_TMPDIR/no-such.md" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"読める通常ファイルではありません"* ]]
}

# --- [5] 非通常ファイル（ディレクトリ）→ -f 分岐で die（wf_3667b17e confirmed minor の pin） ---
@test "gate-args(sc-eqvv): ディレクトリ path は非ゼロ die（-f 分岐・文字クラスは通過する）" {
  mkdir -p "$TEST_TMPDIR/ctxdir"
  run "$GATE" --dry-run --worktree /tmp/wt --context-file "$TEST_TMPDIR/ctxdir" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"読める通常ファイルではありません"* ]]
}

@test "selftest-args(sc-eqvv): ディレクトリ path は非ゼロ die（-f 分岐・文字クラスは通過する）" {
  mkdir -p "$TEST_TMPDIR/ctxdir"
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' --context-file "$TEST_TMPDIR/ctxdir" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"読める通常ファイルではありません"* ]]
}

# --- [6] 存在するが読めない（chmod 000）→ -r 分岐で die（`[[ -f && -r ]]`→`[[ -f ]]` mutant を殺す） ---
# root 実行環境では chmod 000 でも -r が true になり分岐へ到達できないため skip（flake 防止）。
@test "gate-args(sc-eqvv): 読めないファイル（chmod 000）は非ゼロ die（-r 分岐）" {
  [ "$(id -u)" -ne 0 ] || skip "root は chmod 000 でも読めるため -r 分岐を検証できない"
  printf 'x\n' > "$TEST_TMPDIR/noread.md"; chmod 000 "$TEST_TMPDIR/noread.md"
  run "$GATE" --dry-run --worktree /tmp/wt --context-file "$TEST_TMPDIR/noread.md" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"読める通常ファイルではありません"* ]]
}

@test "selftest-args(sc-eqvv): 読めないファイル（chmod 000）は非ゼロ die（-r 分岐）" {
  [ "$(id -u)" -ne 0 ] || skip "root は chmod 000 でも読めるため -r 分岐を検証できない"
  printf 'x\n' > "$TEST_TMPDIR/noread.md"; chmod 000 "$TEST_TMPDIR/noread.md"
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' --context-file "$TEST_TMPDIR/noread.md" sc-xxx
  [ "$status" -ne 0 ]
  [[ "$output" == *"読める通常ファイルではありません"* ]]
}

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
# ヘルパ（sc-94z）: 任意 key の有無/値を読む（reviewEffort/verifyEffort の焼き込みを effort と対称に pin）。
_has_key() {
  echo "$2" | KEY="$1" python3 -c 'import json,os,sys; print(os.environ["KEY"] in json.load(sys.stdin))'
}
_val_of() {
  echo "$2" | KEY="$1" python3 -c 'import json,os,sys; print(json.load(sys.stdin).get(os.environ["KEY"],"<absent>"))'
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

# === reviewEffort/verifyEffort（sc-94z・guard 段の個別 opt-in knob）=================================
# env 由来 effort（fail-soft）と posture が逆で、明示フラグゆえ allowlist 外は fail-loud で die する。
# 系3: 指定時は args.reviewEffort/verifyEffort へ **floor(high)以上**の値が焼ける（上げ方向のみ opt-in）。
# 系3-floor（sc-2wv）: high 未満（low/medium）は guard floor 未満ゆえ fail-loud で die（gate 側を下げない）。
# 系4: 未指定なら key を載せない（effort と対称の有無 2 系）。
# 系5: allowlist 外指定は非ゼロ die し stderr に allowlist メッセージ（SSOT 由来）を出す（fail-loud）。

# --- 系3: --review-effort/--verify-effort は floor(high)以上なら焼ける（high/xhigh/max） ---
@test "selftest-args(sc-94z/sc-2wv): --review-effort/--verify-effort が floor(high)以上なら args へ焼ける（high/xhigh/max）" {
  for lvl in high xhigh max; do
    run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' \
      --review-effort "$lvl" --verify-effort "$lvl" un-4nm
    [ "$status" -eq 0 ]
    echo "$output" | python3 -m json.tool >/dev/null              # valid JSON
    [ "$(_has_key reviewEffort "$output")" = "True" ]
    [ "$(_has_key verifyEffort "$output")" = "True" ]
    [ "$(_val_of reviewEffort "$output")" = "$lvl" ]
    [ "$(_val_of verifyEffort "$output")" = "$lvl" ]
  done
}

# --- 系3-floor（sc-2wv）: guard 段は上げる方向のみ opt-in。high 未満（low/medium）は fail-loud で die ---
@test "selftest-args(sc-2wv): --review-effort が floor(high)未満（low/medium）なら非ゼロ die し floor メッセージ" {
  for lvl in low medium; do
    run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --review-effort "$lvl" un-4nm
    [ "$status" -ne 0 ]                          # allowlist 内だが floor 未満＝die（焼かない）
    [[ "$output" == *"--review-effort"* ]]
    [[ "$output" == *"下限フロア"* ]]            # floor 由来メッセージ（allowlist メッセージと弁別）
  done
}

@test "selftest-args(sc-2wv): --verify-effort が floor(high)未満（low/medium）なら非ゼロ die し floor メッセージ" {
  for lvl in low medium; do
    run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --verify-effort "$lvl" un-4nm
    [ "$status" -ne 0 ]
    [[ "$output" == *"--verify-effort"* ]]
    [[ "$output" == *"下限フロア"* ]]
  done
}

# --- 系3b: 片側のみ指定でも独立に焼ける（もう片側は載せない） ---
@test "selftest-args(sc-94z): --review-effort のみ指定なら reviewEffort だけ焼け verifyEffort は載せない" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --review-effort xhigh un-4nm
  [ "$status" -eq 0 ]
  [ "$(_has_key reviewEffort "$output")" = "True" ]
  [ "$(_val_of reviewEffort "$output")" = "xhigh" ]
  [ "$(_has_key verifyEffort "$output")" = "False" ]
}

# --- 系4: 未指定なら reviewEffort/verifyEffort key を載せない（effort と対称の有無 2 系） ---
@test "selftest-args(sc-94z): --review-effort/--verify-effort 未指定なら key を載せない（WF 既定 high に委譲）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(_has_key reviewEffort "$output")" = "False" ]
  [ "$(_has_key verifyEffort "$output")" = "False" ]
}

# --- 系5: allowlist 外は fail-loud で die（env fail-soft と posture が逆）+ allowlist メッセージ ---
@test "selftest-args(sc-94z): allowlist 外 --review-effort は非ゼロ die し stderr に allowlist メッセージ" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --review-effort ultra un-4nm
  [ "$status" -ne 0 ]                          # fail-loud（焼かず素通しではなく die）
  [[ "$output" == *"--review-effort"* ]]       # どのフラグが弾かれたか
  [[ "$output" == *"low|medium|high|xhigh|max"* ]]  # SSOT 由来 allowlist メッセージ（scribe_effort_allowlist_join）
}

@test "selftest-args(sc-94z): allowlist 外 --verify-effort は非ゼロ die し stderr に allowlist メッセージ" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --verify-effort HIGH un-4nm
  [ "$status" -ne 0 ]                          # 大文字は完全一致を外れる＝die
  [[ "$output" == *"--verify-effort"* ]]
  [[ "$output" == *"low|medium|high|xhigh|max"* ]]
}

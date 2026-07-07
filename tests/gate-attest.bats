#!/usr/bin/env bats
# scripts/scribe-gate-attest.sh（gate ground-truth 証跡プロデューサ・sc-ex2）を検証する。
# **実 bd write・実 admin gate はしない**（probe は read-only／record は --dry-run のみ・コスト大ゆえ）。
# 道具がコード化する規約の SSOT = docs/protocol.md §5「gate の義務」+ 幻影 backstop 追補。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  GA="$REPO_ROOT/scripts/scribe-gate-attest.sh"

  # 対象 worktree を temp git repo で作る（base=root commit + 1 work commit）。
  WT="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$WT" -c init.defaultBranch=main init -q
  git -C "$WT" config user.email t@e; git -C "$WT" config user.name t
  git -C "$WT" commit -q --allow-empty -m init
  BASE="$(git -C "$WT" rev-list --max-parents=0 HEAD)"
  mkdir -p "$WT/docs"
  echo "hello" > "$WT/file-a.txt"
  echo "spec"  > "$WT/docs/protocol.md"
  git -C "$WT" add -A; git -C "$WT" commit -q -m work
  printf '{"type":"tool_use","name":"Bash"}\n{"type":"tool_result"}\n{"type":"tool_use","name":"Read"}\nMARKERTOK line\n' > "$WT/ts.jsonl"
  printf 'acc item one\nacc item two\n' > "$WT/acc.txt"
}

teardown() {
  [[ -n "${WT:-}" ]] && rm -rf "$WT"
  return 0
}

@test "gate-attest: bash -n 構文 OK" {
  run bash -n "$GA"
  [ "$status" -eq 0 ]
}

@test "gate-attest(probe): 四点 + touch-check + scaffold を emit し exit 0" {
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'echo ok; true' --id sc-ex2 \
        --transcript "$WT/ts.jsonl" --marker-regex 'MARKERTOK' \
        --acceptance-file "$WT/acc.txt" --acceptance-path 'docs/*.md'
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SCRIBE-GATE-ATTEST v1] id=sc-ex2 "* ]]
  [[ "$output" =~ self-test:\ exit=0\ out-sha256=[0-9a-f]{64}\ cmd-sha256=[0-9a-f]{64} ]]
  [[ "$output" == *"count=1"* ]]
  [[ "$output" == *"changed-files (2):"* ]]
  [[ "$output" == *"file-a.txt"* ]]
  [[ "$output" == *"transcript: tool_use=2 tool_result=1 marker-hits=1"* ]]
  [[ "$output" == *"touch-check: acceptance-path 一致 1/2"* ]]
  [[ "$output" == *"[ ] acc item one"* ]]
}

@test "gate-attest(§6 衛生): marker regex を渡しても件数のみ・生 marker 行を焼かない" {
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'true' \
        --transcript "$WT/ts.jsonl" --marker-regex 'MARKERTOK'
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker-hits=1"* ]]
  # 生 marker 行（MARKERTOK を含む transcript の行）が出力へ漏れていない。
  [[ "$output" != *"MARKERTOK line"* ]]
}

@test "gate-attest(§6 衛生): 出力に完了/blocked/degraded 検知文字列を verbatim で焼かない" {
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'echo x; true' --id sc-ex2
  [ "$status" -eq 0 ]
  # 監視 monitor が読む検知文字列を証跡へ焼かない（自作証跡が monitor を誤発火させない）。
  [[ "$output" != *"gate-pending"* ]]
  [[ "$output" != *"ENV_DEGRADED"* ]]
  run bash -c '"$1" probe --worktree "$2" --base "$3" --self-test "true" | grep -c "^STATUS:"' _ "$GA" "$WT" "$BASE"
  [ "$output" = "0" ]
}

@test "gate-attest(probe): --acceptance-path 未指定は touch-check を manual にする" {
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'true'
  [ "$status" -eq 0 ]
  [[ "$output" == *"touch-check: manual"* ]]
}

@test "gate-attest(probe): 既定は selftest 失敗でも証跡を出して exit 0（証跡が本務）" {
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'false'
  [ "$status" -eq 0 ]
  [[ "$output" == *"self-test: exit=1"* ]]
}

@test "gate-attest(probe --strict): selftest 失敗=6 / 0-commit=7 / 健全=0" {
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'false' --strict
  [ "$status" -eq 6 ]
  HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"
  run "$GA" probe --worktree "$WT" --base "$HEAD_SHA" --self-test 'true' --strict
  [ "$status" -eq 7 ]
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'true' --strict
  [ "$status" -eq 0 ]
}

@test "gate-attest(probe): 必須引数欠落 / 解決不能 base で fail-loud" {
  run "$GA" probe --base "$BASE" --self-test 'true'
  [ "$status" -ne 0 ]
  run "$GA" probe --worktree "$WT" --self-test 'true'
  [ "$status" -ne 0 ]
  run "$GA" probe --worktree "$WT" --base "$BASE"
  [ "$status" -ne 0 ]
  run "$GA" probe --worktree "$WT" --base deadbeefdeadbeef --self-test 'true'
  [ "$status" -ne 0 ]
}

@test "gate-attest(need-val): --worktree の値省略で次フラグを誤消費せず fail-loud" {
  run "$GA" probe --worktree --base "$BASE" --self-test 'true'
  [ "$status" -ne 0 ]
}

@test "gate-attest(probe): read-only＝git HEAD/worktree 状態が不変" {
  before="$(git -C "$WT" rev-parse HEAD)$(git -C "$WT" status --porcelain)"
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'echo x; true'
  [ "$status" -eq 0 ]
  after="$(git -C "$WT" rev-parse HEAD)$(git -C "$WT" status --porcelain)"
  [ "$before" = "$after" ]
}

@test "gate-attest(record --dry-run): bdw invocation の形を可視化し本文を焼かない・空拒否" {
  run bash -c 'printf "ATTEST BODY xyz\n" | "$1" record --id sc-ex2 --anchor "$2" --dry-run' _ "$GA" "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN record:"* ]]
  [[ "$output" == *"update sc-ex2 --append-notes"* ]]
  [[ "$output" != *"ATTEST BODY xyz"* ]]
  run bash -c 'printf "" | "$1" record --id sc-ex2 --anchor "$2" --dry-run' _ "$GA" "$WT"
  [ "$status" -ne 0 ]
}

@test "gate-attest(record): --id 未指定で fail-loud" {
  run bash -c 'printf "x\n" | "$1" record --dry-run' _ "$GA"
  [ "$status" -ne 0 ]
}

@test "gate-attest: 未知モード / 未知オプションで fail-loud" {
  run "$GA" bogus
  [ "$status" -ne 0 ]
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'true' --nope
  [ "$status" -ne 0 ]
}

@test "gate-attest(probe): 不正な --marker-regex は fail-loud（silent に marker-hits=0 としない）" {
  # 不正 ERE（未閉の '['）は grep exit 2。従来は 0 件と区別不能な marker-hits=0 に握り潰されていた
  # （scan 未実行の偽陰性＝幻影 backstop の無音無効化）。上流検証で die することを固定する。
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'true' \
        --transcript "$WT/ts.jsonl" --marker-regex '['
  [ "$status" -ne 0 ]
  [[ "$output" == *"--marker-regex"* ]]
  # 妥当な regex の真の 0 件は従来どおり件数 0 を emit する（fail-loud の巻き添えにしない）。
  run "$GA" probe --worktree "$WT" --base "$BASE" --self-test 'true' \
        --transcript "$WT/ts.jsonl" --marker-regex 'NO_SUCH_MARKER_ZZZ'
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker-hits=0"* ]]
}

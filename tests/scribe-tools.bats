#!/usr/bin/env bats
# scribe 道具（spawn ヘルパー / gate 支援 / cleanup）の dry-run arg-echo を検証する。
# **実 spawn・実 tmux・実 claude 起動はしない**（dry-run + bd スタブのみ・コスト大ゆえ）。
# 道具がコード化する規約の SSOT = docs/protocol.md。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  GATE="$SCRIPTS/scribe-gate-args.sh"
  CLEANUP="$SCRIPTS/scribe-cleanup.sh"
  # bd を実在検証スタブへ差し替え（実 graph 不要）。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm un-consult un-3sh.3.5"
  # cld-spawn は dry-run では実行されない。echo を決定論化するため固定値を入れる。
  export SCRIBE_CLD_SPAWN="cld-spawn"
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true
}

# ---------- bash -n（全 script 構文）----------
@test "bash -n: 全 script が構文 OK" {
  for f in "$SPAWN" "$GATE" "$CLEANUP" "$SCRIPTS/lib/scribe-lib.sh"; do
    run bash -n "$f"
    [ "$status" -eq 0 ]
  done
}

# ---------- spawn: fail-loud ----------
@test "spawn: 実在しない bd id で fail-loud（exit 非 0・spawn コマンド列を出さない）" {
  run "$SPAWN" --dry-run un-nope
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  [[ "$output" != *"--bd-id"* ]]
}

@test "spawn: 形式不正な bd id（path traversal）で fail-loud" {
  run "$SPAWN" --dry-run "../evil"
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  [[ "$output" != *"--bd-id"* ]]
}

@test "spawn: bd id 引数なしで fail-loud" {
  run "$SPAWN" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" != *"--bd-id"* ]]
}

# ---------- spawn: 正常系 dry-run ----------
@test "spawn: dry-run の arg-echo に --bd-id / --model opus / spawn/<id>- / window ID @N が含まれる" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"--bd-id un-4nm"* ]]
  [[ "$output" == *"--model opus"* ]]
  [[ "$output" == *"spawn/un-4nm-"* ]]
  [[ "$output" == *"@N"* ]]
  [[ "$output" == *"window_id"* ]]
}

@test "spawn: window 名は wt-<id>・worktree は .worktrees/ 配下" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt-un-4nm"* ]]
  [[ "$output" == *"/.worktrees/spawn/un-4nm-"* ]]
}

@test "spawn: dotted 階層 id（un-3sh.3.5）も命名規約どおり通る" {
  run "$SPAWN" --dry-run un-3sh.3.5
  [ "$status" -eq 0 ]
  [[ "$output" == *"--bd-id un-3sh.3.5"* ]]
  [[ "$output" == *"spawn/un-3sh.3.5-"* ]]
}

# ---------- spawn: consult モード ----------
@test "spawn: consult モードで SCRIBE_ROLE=consult が env-file に焼き込まれる" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_ROLE=consult"* ]]
  [[ "$output" == *"--env-file"* ]]
}

@test "spawn: consult の env-file は anchor working tree 外（/tmp・mktemp）で anchor リポを汚さない" {
  # 実在する anchor（repo root）を明示し、その配下に .scribe-consult.env を作る計画が出ないことを assert。
  run "$SPAWN" --dry-run --consult --anchor "$REPO_ROOT" un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"mktemp /tmp/scribe-consult-"* ]]
  # anchor 直下の .scribe-consult.env を生成する計画は出してはならない（anchor リポ汚染防御）。
  [[ "$output" != *"$REPO_ROOT/.scribe-consult.env"* ]]
  [[ "$output" != *".scribe-consult.env"* ]]
  # spawn 後に rm して anchor/外部にも残さない計画が出る。
  [[ "$output" == *"rm -f"* ]]
}

@test "spawn: consult は worktree も worker prompt も出さない（role-context-spec §2.3 契約）" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  # consult は anchor 同居・read-only。worktree spawn は design §14 で禁止。
  [[ "$output" != *"worktree add"* ]]
  # cld-spawn 起動行に --bd-id を渡さない（説明文中の言及や anchor パスは無視し、起動行だけを検査）。
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  [[ "$cld_line" != *"--bd-id"* ]]
  # worker prompt（実装/bdw/cell-quality/selftest）は consult に同居させない。
  [[ "$output" != *"end-to-end で完遂"* ]]
  [[ "$output" != *"bdw"* ]]
  [[ "$output" != *"cell-quality"* ]]
  [[ "$output" != *"selftest-"* ]]
  # consult テンプレの肝（read-only 規律・記憶系のみ write）は出る。
  [[ "$output" == *"設計議論"* ]]
  [[ "$output" == *"read-only"* ]]
}

@test "spawn: consult は bd id 省略でも起動できる（議題参照は任意）" {
  run "$SPAWN" --dry-run --consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_ROLE=consult"* ]]
  # cld-spawn 起動行に --bd-id を渡さない。
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  [[ "$cld_line" != *"--bd-id"* ]]
}

@test "spawn: consult で存在しない議題 id は fail-loud" {
  run "$SPAWN" --dry-run --consult un-nope
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn: 非 consult では env-file を注入しない" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCRIBE_ROLE=consult"* ]]
  [[ "$output" != *"--env-file"* ]]
}

# ---------- spawn: 防御 ----------
@test "spawn: 未知オプションを拒否する（cld-spawn の PROMPT 落下バグ防御・un-ivb）" {
  run "$SPAWN" --dry-run --bogus-opt un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn: worker は --model fable 系を拒否する（worker は opus 必須・protocol.md §1）" {
  run "$SPAWN" --dry-run --model claude-fable-5 un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  # case-insensitive: 大文字混在（CLAUDE-FABLE-5 等）も取りこぼさず die する。
  run "$SPAWN" --dry-run --model CLAUDE-FABLE-5 un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn: consult は --model fable を許容する（role-context-spec §2.3 の例外・worker との非対称）" {
  # consult は admin と同じ main-loop 系統ゆえ fable 起動が許される唯一の例外。
  # 同じ fable 指定でも worker（上テスト）は die・consult は通る＝道具が規約を変えない証拠。
  run "$SPAWN" --dry-run --consult --model claude-fable-5 un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_ROLE=consult"* ]]
  [[ "$output" == *"--model claude-fable-5"* ]]
}

@test "spawn: prompt テンプレに cell-quality WF / receivedArgs / bdw / 禁止が含まれる" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"cell-quality"* ]]
  [[ "$output" == *"receivedArgs"* ]]
  [[ "$output" == *"bdw"* ]]
  [[ "$output" == *"bd create"* ]]
}

# ---------- gate 支援 ----------
@test "gate-args: 出力 JSON が valid で doImplement:false / autoFix:false / doPlan:false 固定" {
  run "$GATE" --dry-run --worktree /tmp/wt un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doImplement"])')" = "False" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["autoFix"])')" = "False" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doPlan"])')" = "False" ]
}

@test "gate-args: worktree / baseRef / taskTitle / model が JSON に入る" {
  run "$GATE" --dry-run --worktree /tmp/wt --base origin/main un-4nm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree"])')" = "/tmp/wt" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["baseRef"])')" = "origin/main" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')" = "opus" ]
  [[ "$output" == *"un-4nm"* ]]
}

@test "gate-args: --worktree 未指定で fail-loud" {
  run "$GATE" --dry-run un-4nm
  [ "$status" -ne 0 ]
}

@test "gate-args: --model fable 系を拒否する" {
  run "$GATE" --dry-run --worktree /tmp/wt --model claude-fable-5 un-4nm
  [ "$status" -ne 0 ]
}

# ---------- cleanup ----------
@test "cleanup: dry-run に禁止操作（branch -D / reset --hard / kill-server）が含まれない" {
  run "$CLEANUP" --dry-run --repo /tmp/repo --worktree /tmp/wt --branch spawn/un-4nm-101010 un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"branch -D"* ]]
  [[ "$output" != *"reset --hard"* ]]
  [[ "$output" != *"kill-server"* ]]
}

@test "cleanup: dry-run は安全操作のみ（branch -d / kill-window / worktree remove）+ window ID @N 参照" {
  run "$CLEANUP" --dry-run --repo /tmp/repo --worktree /tmp/wt --branch spawn/un-4nm-101010 un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch -d"* ]]
  [[ "$output" == *"kill-window"* ]]
  [[ "$output" == *"worktree remove"* ]]
  [[ "$output" == *"@N"* ]]
  [[ "$output" == *"window_id"* ]]
}

@test "cleanup: dolt push は自動実行せずリマインドのみ（[plan] 実行行に出さない）" {
  run "$CLEANUP" --dry-run --repo /tmp/repo un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"dolt push"* ]]
  # dolt push を含む行が実行 plan（^[plan]）であってはならない＝checklist リマインドのみ
  ! echo "$output" | grep -E '^\[plan\].*dolt push'
}

@test "cleanup: window 既定は wt-<id>" {
  run "$CLEANUP" --dry-run --repo /tmp/repo un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt-un-4nm"* ]]
}

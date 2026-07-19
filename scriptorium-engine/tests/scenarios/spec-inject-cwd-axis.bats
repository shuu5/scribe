#!/usr/bin/env bats
# tests/scenarios/spec-inject-cwd-axis.bats
#
# session-start-spec-inject.sh の cwd 第2軸(orch-1r7 grill G3)の hermetic E2E テスト。
#
# 検証する不変条件(G3=A):
#   - orch anchor(非 worktree)cwd → primer 注入(従来挙動を維持)。
#   - orch worktree(cwd が `.worktrees/` 配下)→ **no-op**(台帳 self-scope は通過するが cwd 軸で弾く)。
#   - orch worktree(cwd が `.claude/worktrees/` = CC-native worktree 配下)→ **no-op**。
#   - foreign 台帳 → no-op(self-scope・従来)。
#   - 非vacuity(mutation): anchor→注入が valid doc で PASS する = no-op 群が常時空でない証明。
#     さらに sentinel 破壊 fixture で anchor すら no-op = doc 依存(fail-open)を pin。
#   - 本体 `--self-test` が green。bash -n が通る。
#
# 方式: temp に fixture plugin root(sentinel 付き top-spec)と台帳 fixture を作り、hook payload の
#   cwd を stdin JSON で与え、CLAUDE_PLUGIN_ROOT を fixture へ向けて実 script を subprocess 起動して
#   stdout を assert する($HOME 非依存・実台帳/実 doc 非依存の hermetic E2E)。
#
# 実行: bats tests/scenarios/spec-inject-cwd-axis.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/hooks/session-start-spec-inject.sh"
    TEST_TMPDIR=$(mktemp -d -t spec-inject-cwd-bats-XXXXXX)

    # fixture plugin root(sentinel 付き top-spec)。注入内容は fixture 固有トークンで判別する。
    PLUGIN="$TEST_TMPDIR/plugin"
    mkdir -p "$PLUGIN/docs"
    printf '# fixture\n<!-- spec-inject:begin -->\nPRIMER-FIXTURE-CONTENT\n<!-- spec-inject:end -->\n' \
        > "$PLUGIN/docs/scriptorium-top-spec.md"

    # 台帳 fixture(walk-up で .beads/metadata.json の dolt_database を解決)。
    ANCHOR="$TEST_TMPDIR/anchor"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$ANCHOR/.beads";  printf '{"dolt_database":"orch"}' > "$ANCHOR/.beads/metadata.json"
    mkdir -p "$FOREIGN/.beads"; printf '{"dolt_database":"un"}'   > "$FOREIGN/.beads/metadata.json"
    mkdir -p "$ANCHOR/.worktrees/spawn/wt"        # 台帳 walk-up は anchor(orch)へ届く worktree
    mkdir -p "$ANCHOR/.claude/worktrees/wt2"      # CC-native worktree

    # hazard-faithful stub tmux(consult 窓判定 = orch-qcqz 第3軸 用・M2 teeth)。
    # `-t <pane>` 明示時のみ「その pane の窓名」= $STUB_WNAME を返す(空なら非0 exit=窓名取得失敗を模す)。
    # `-t <value>` 不在(bare 形 = mutation M2)は「human が focus 中の別窓名」を模して非 consult 名 orchestrator を
    # 返す → _is_consult_window が -t "$TMUX_PANE" を落とすと consult 判定が focused 窓へ倒れ consult test(b-1)が
    # inject 側へ落ちて RED になる(-t 明示が load-bearing = verified hazard 対策であることを teeth に pin)。
    STUBBIN="$TEST_TMPDIR/bin"
    mkdir -p "$STUBBIN"
    cat > "$STUBBIN/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
have_t=0; prev=""
for a in "$@"; do
    if [ "$prev" = "-t" ] && [ -n "$a" ]; then have_t=1; fi
    prev="$a"
done
if [ "$have_t" -eq 1 ]; then
    [ -n "${STUB_WNAME:-}" ] || exit 1
    printf '%s\n' "$STUB_WNAME"
else
    printf '%s\n' "orchestrator"   # -t 不在(bare)= focused 別窓を模す(非 consult)
fi
TMUXEOF
    chmod +x "$STUBBIN/tmux"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# hook payload の cwd を stdin で与え、fixture plugin root で script を起動する。
# NOTE: bats の `run` はパイプ下流に置くと $status/$output を親テストへ伝播しない。
#   stdin はファイル経由で与え、`run` を最外(リダイレクト付き simple command)に置く。
run_inject() {  # $1=cwd
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    # TMUX を剥がす: bats を実 tmux window 内で回したときに consult gate(第3軸)が実 tmux を呼ばないよう遮断し、
    # 非 consult 経路(既存 modality)を hermetic に固定する(実窓名依存の flake を排除)。
    run env -u TMUX -u TMUX_PANE bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

# consult 経路(orch-qcqz 第3軸): TMUX + stub tmux を付けて起動する。$2=window 名(空→tmux 失敗を模す)。
run_inject_consult() {  # $1=cwd $2=window-name
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    run env PATH="$STUBBIN:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" \
        bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

@test "orch anchor cwd → primer 注入(従来挙動を維持)" {
    run_inject "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRIMER-FIXTURE-CONTENT"* ]]
}

@test "orch worktree(.worktrees/ 配下)→ no-op(台帳は orch でも cwd 軸で弾く)" {
    run_inject "$ANCHOR/.worktrees/spawn/wt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "orch worktree(.claude/worktrees/ = CC-native 配下)→ no-op" {
    run_inject "$ANCHOR/.claude/worktrees/wt2"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "foreign 台帳 → no-op(self-scope・従来)" {
    run_inject "$FOREIGN"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "非vacuity(mutation): sentinel を壊すと anchor でも primer 注入されない(fail-open・doc 依存を pin)" {
    printf '# broken\n(no sentinels here)\n' > "$PLUGIN/docs/scriptorium-top-spec.md"
    run_inject "$ANCHOR"
    [ "$status" -eq 0 ]
    # primer は注入されない(anchor→注入は doc 依存)。bats `run` は fail-open 警告(stderr)を $output に
    # 混ぜるため「完全に空」ではなく「fixture primer を含まない」で判定する。
    [[ "$output" != *"PRIMER-FIXTURE-CONTENT"* ]]
}

@test "consult 窓(consult-*)→ anchor cwd でも no-op(b-1・第3軸で弾く)" {
    run_inject_consult "$ANCHOR" "consult-abc"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "非 consult 窓(orchestrator)→ 注入(b-2・consult gate が anchor 注入を潰さない)" {
    run_inject_consult "$ANCHOR" "orchestrator"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRIMER-FIXTURE-CONTENT"* ]]
}

@test "tmux 窓名取得不能(stub 失敗)→ 注入(b-4 fail-safe・「不能→no-op」でない)" {
    run_inject_consult "$ANCHOR" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRIMER-FIXTURE-CONTENT"* ]]
}

@test "foreign 台帳 + consult 窓 → no-op(b-3・self-scope 先勝ちで不変)" {
    run_inject_consult "$FOREIGN" "consult-abc"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "本体 --self-test が green(fail-closed)" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "bash -n(構文)が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

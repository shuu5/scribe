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
#   - TOP_SPEC env seam(sc-300x/orch-ocbx): ORCH_SPEC_INJECT_TOP_SPEC 設定時は指定 doc から注入
#     (default 不使用・default 破壊でも注入=engine 単独稼働 modality の非vacuous teeth)。seam 経路でも
#     path 不在/sentinel 欠落/重複/空区間の fail-open が同一に効く。未設定は byte 不変(既存 test 群)。
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

    # TOP_SPEC seam 用 alt fixture(sc-300x): private 配備層が供給する別 path の spec doc を模す。
    ALT="$TEST_TMPDIR/private"
    mkdir -p "$ALT"
    printf '# alt\n<!-- spec-inject:begin -->\nSEAM-FIXTURE-CONTENT\n<!-- spec-inject:end -->\n' \
        > "$ALT/top-spec.md"

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
    # ORCH_SPEC_INJECT_TOP_SPEC も剥がす(sc-300x): 外来 env の seam 供給(orch-supply 済み環境で bats を
    # 回す等)が default 経路の pin を汚さない hermetic 化。
    run env -u TMUX -u TMUX_PANE -u ORCH_SPEC_INJECT_TOP_SPEC bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

# TOP_SPEC seam 経路(sc-300x): ORCH_SPEC_INJECT_TOP_SPEC を supply して起動する。$2=seam が指す path。
run_inject_seam() {  # $1=cwd $2=spec doc path
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    run env -u TMUX -u TMUX_PANE ORCH_SPEC_INJECT_TOP_SPEC="$2" bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

# consult 窓 + seam 併用(sc-300x gate 追補・3 軸目の非迂回 pin): seam を供給しても consult gate が先に効く
# (TOP_SPEC 読取りは consult gate より後)ことを、将来の gate 順序変更への回帰網として pin する。
run_inject_consult_seam() {  # $1=cwd $2=window-name $3=spec doc path
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    run env ORCH_SPEC_INJECT_TOP_SPEC="$3" PATH="$STUBBIN:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" \
        bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

# consult 経路(orch-qcqz 第3軸): TMUX + stub tmux を付けて起動する。$2=window 名(空→tmux 失敗を模す)。
run_inject_consult() {  # $1=cwd $2=window-name
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    run env -u ORCH_SPEC_INJECT_TOP_SPEC PATH="$STUBBIN:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" \
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

# ---- TOP_SPEC env seam(sc-300x/orch-ocbx): private 配備層が spec doc path を供給する override ----
@test "seam: ORCH_SPEC_INJECT_TOP_SPEC 設定 → 指定 doc の sentinel 区間を注入(default doc は使わない)" {
    run_inject_seam "$ANCHOR" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SEAM-FIXTURE-CONTENT"* ]]
    [[ "$output" != *"PRIMER-FIXTURE-CONTENT"* ]]
}

@test "seam 非vacuity: default doc 不在でも seam の doc から注入(engine 単独稼働 modality=G4 gap 解消)" {
    # engine tree に規約 doc が同梱されない carve-out 後を模す: default path を除去。
    # seam 解決を no-op 化する mutation はここが fail-open no-op に落ちて RED になる(teeth)。
    rm -f "$PLUGIN/docs/scriptorium-top-spec.md"
    run_inject_seam "$ANCHOR" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SEAM-FIXTURE-CONTENT"* ]]
}

@test "seam fail-open: 指す path 不在 → 注入なし(既存 [ ! -r ] 分岐が seam 経路でも効く)" {
    run_inject_seam "$ANCHOR" "$TEST_TMPDIR/nonexistent.md"
    [ "$status" -eq 0 ]
    # fail-open 警告(stderr)が $output に混ざるため「注入内容を含まない」で判定(既存 mutation test と同形)。
    [[ "$output" != *"FIXTURE-CONTENT"* ]]
    [[ "$output" != *"=== [orchestrator/SessionStart] role 文脈注入"* ]]
}

@test "seam fail-open: sentinel 欠落 doc → 注入なし" {
    printf '# broken\n(no sentinels here)\n' > "$ALT/top-spec.md"
    run_inject_seam "$ANCHOR" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" != *"FIXTURE-CONTENT"* ]]
    [[ "$output" != *"=== [orchestrator/SessionStart] role 文脈注入"* ]]
}

@test "seam fail-open: sentinel 重複(2 組) doc → 注入なし(over-inject 防止が seam 経路でも効く)" {
    printf '<!-- spec-inject:begin -->\nDUP-A\n<!-- spec-inject:end -->\n<!-- spec-inject:begin -->\nDUP-B\n<!-- spec-inject:end -->\n' \
        > "$ALT/top-spec.md"
    run_inject_seam "$ANCHOR" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" != *"DUP-A"* ]]
    [[ "$output" != *"DUP-B"* ]]
}

@test "seam fail-open: 空 sentinel 区間 doc → 注入なし" {
    printf '<!-- spec-inject:begin -->\n<!-- spec-inject:end -->\n' > "$ALT/top-spec.md"
    run_inject_seam "$ANCHOR" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" != *"=== [orchestrator/SessionStart] role 文脈注入"* ]]
}

@test "seam は self-scope/cwd 軸を迂回しない: seam 設定でも foreign 台帳・worktree cwd は no-op" {
    run_inject_seam "$FOREIGN" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run_inject_seam "$ANCHOR/.worktrees/spawn/wt" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "seam は consult 第3軸も迂回しない: seam 設定 + consult 窓 → no-op(alt doc を注入しない)" {
    run_inject_consult_seam "$ANCHOR" "consult-abc" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # 対の陽性 pin(非vacuity): 同じ seam 供給でも非 consult 窓なら alt doc から注入される
    # = 上の no-op が「seam が常に死んでいる」せいではないことの teeth。
    run_inject_consult_seam "$ANCHOR" "orchestrator" "$ALT/top-spec.md"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SEAM-FIXTURE-CONTENT"* ]]
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

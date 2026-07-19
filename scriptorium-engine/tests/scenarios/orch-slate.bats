#!/usr/bin/env bats
# tests/scenarios/orch-slate.bats
#
# 計画 slate 機構（bd orch-vswk・orch-6srt 裁定-safeguards(3)）の hermetic テスト。
#
# 対象: 共有 lib scripts/lib/orch_slate.sh（記録 helper + 参照 interlock の SSOT）と、それを consume する
#   orch-dispatch.sh（run_spawn）/ orch-spawn-admin.sh（spawn 実行経路）の slate interlock。
#
# 方式: bd / bdw / scribe-spawn / cld-spawn / session-state を env/PATH スタブで差替え、実 script を gate 有効
#   （bypass seam を敢えて外す）で実行して assert する hermetic E2E。実 bd / 実 spawn / network は一切叩かない。
#   - bd スタブ: `list --label slate` → $SLATE_LIST_JSON / `show orch-slate*` → $SLATE_SHOW_JSON /
#                他 list → $BD_LIST_JSON / 他 show → $BD_SHOW_JSON（契約 G1/G7 read）。argv を $BD_ARGS_FILE へ記録。
#   - scribe-spawn / cld-spawn スタブ: argv を echo するだけ（実 spawn しない）。
#
# 検証する不変条件（bd orch-vswk 契約）:
#   (A) lib 本体 --self-test が green（記録/参照/fail-closed の単体）。
#   (B) dispatch spawn: slate-present∧member→pass（scribe-spawn forward）/ slate-absent→fail-closed die /
#       slate-present∧non-member→fail-closed die（空虚 interlock でなく集合照合）。mutation 非空虚（die 行 no-op 化で緑→赤反転）。
#   (C) spawn-admin: target project ∈ slate targets→pass（dry-run plan）/ absent→fail-closed / non-member→fail-closed。
#   (D) read-only mode / dry-run: --gate-pending は slate 無し∧gate 有効でも従来どおり成功（run_spawn を通らない）／
#       spawn --dry-run は read-only 照合を掛ける（slate 無しで fail-closed＝「dry-run では slate skip」の逆解釈を封じる）。
#   (E) 予約検知線への誤検知ゼロ: slate 生成（SLATE_LIST_JSON set）で --gate-pending 出力が byte 不変。
#       + 識別子（label slate / sentinel [ORCH-SLATE v1]）が予約 token（[SPAWNED-- / gate-pending / for: 等）と非衝突。
#   (F) syntax teeth: 変更した 3 script が bash -n を通る。
#
# private 配備層の docs/systemd drift teeth は配備層側 residual bats が担う（engine copy は mechanism teeth のみ）。
#
# 実行: bats tests/scenarios/orch-slate.bats

setup() {
    REPO_ROOT="$BATS_TEST_DIRNAME/../.."
    SCRIPT_DISPATCH="$REPO_ROOT/scripts/orch-dispatch.sh"
    SCRIPT_ADMIN="$REPO_ROOT/scripts/orch-spawn-admin.sh"
    SLATE_LIB="$REPO_ROOT/scripts/lib/orch_slate.sh"

    TEST_TMPDIR=$(mktemp -d -t orch-slate-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
    export ANCHOR="$TEST_TMPDIR/anchor"; mkdir -p "$ANCHOR/.beads"
    printf '{"dolt_database":"orch"}' > "$ANCHOR/.beads/metadata.json"

    export BD_ARGS_FILE="$TEST_TMPDIR/bd-args.txt"; : > "$BD_ARGS_FILE"

    # 契約 G1/G7 の正常 bead（acceptance + verification 欄あり）。slate gate と独立に spawn 入口 gate を通す。
    export VALID_BEAD_JSON='[{"id":"orch-test","acceptance_criteria":"(1) foo (2) bar","description":"検証方針。\nverification: bash selftest.local.sh"}]'

    # ── bd スタブ（slate read / 契約 read を id・label で出し分け）──
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_FILE"
[ -n "${BD_FAIL:-}" ] && exit 1
while [ "${1:-}" = "-C" ] || [ "${1:-}" = "--directory" ]; do shift 2; done
sub="${1:-}"; shift 2>/dev/null || true
case "$sub" in
  list)
    case " $* " in
      *" --label slate "*|*" -l slate "*) printf '%s' "${SLATE_LIST_JSON:-[]}" ;;
      *)                                   printf '%s' "${BD_LIST_JSON:-[]}" ;;
    esac ;;
  show)
    case "${1:-}" in
      orch-slate*) printf '%s' "${SLATE_SHOW_JSON:-[]}" ;;
      *)           printf '%s' "${BD_SHOW_JSON:-[]}" ;;
    esac ;;
  *) printf '%s' "[]" ;;
esac
exit 0
STUB
    chmod +x "$BIN/bd"

    # ── scribe-spawn / cld-spawn / bdw / session-state スタブ ──
    cat > "$BIN/scribe-spawn-stub" <<'STUB'
#!/usr/bin/env bash
echo "SPAWN-ARGS: $*"
exit 0
STUB
    cat > "$BIN/cld-spawn-stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$BIN/bdw-stub" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    cat > "$BIN/session-state-stub" <<'STUB'
#!/usr/bin/env bash
echo processing
STUB
    chmod +x "$BIN/scribe-spawn-stub" "$BIN/cld-spawn-stub" "$BIN/bdw-stub" "$BIN/session-state-stub"

    # spawn-admin の project fixture（cwd 実在・footgun 非該当＝dolt_database≠orch）。
    export TBDIR="$TEST_TMPDIR/proj-tb"; mkdir -p "$TBDIR/.beads"
    printf '{"dolt_database":"tb"}' > "$TBDIR/.beads/metadata.json"

    # 既定 slate fixture（orch-slate1 が members: orch-test, tb を列挙）。個別 test が上書きする。
    export SLATE_LIST_JSON='[{"id":"orch-slate1"}]'
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"bundle x\n[ORCH-SLATE v1] members: orch-test, tb"}]'
    export BD_LIST_JSON='[]'
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# 実 orch-dispatch.sh を gate 有効（bypass 外し）で spawn 実行。
run_dispatch_gate() {
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
    ORCH_DISPATCH_SCRIPTORIUM="$ANCHOR" \
    ORCH_DISPATCH_BD="$BIN/bd" \
    ORCH_DISPATCH_BDW="$BIN/bdw-stub" \
    ORCH_DISPATCH_SKIP_SLATE_GATE=0 \
    ORCH_DISPATCH_POLL_INTERVAL=0 \
    BD_SHOW_JSON="${BD_SHOW_JSON:-$VALID_BEAD_JSON}" \
        run bash "$SCRIPT_DISPATCH" "$@"
}

# 実 orch-spawn-admin.sh を gate 有効で dry-run（gate は dry-run にも掛かる）。
run_admin_gate() {
    PATH="$BIN:$PATH" \
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" \
    ORCH_ADMIN_PROJECTS="tb=$TBDIR" \
    ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE=0 \
    ORCH_SPAWN_ADMIN_BD="$BIN/bd" \
    ORCH_SPAWN_ADMIN_SCRIPTORIUM="$ANCHOR" \
    ORCH_SPAWN_ADMIN_FABLE_PREFLIGHT=1 \
    ORCH_SPAWN_ADMIN_SESSION_STATE="$BIN/session-state-stub" \
    ORCH_SPAWN_ADMIN_VERIFY_SETTLE=0 \
        run bash "$SCRIPT_ADMIN" "$@"
}

# ==============================================================================
# (A) lib 本体 --self-test
# ==============================================================================

@test "(A) orch_slate.sh --self-test が green（記録/参照/fail-closed 単体）" {
    run bash "$SLATE_LIB" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(A-noargs) orch_slate.sh を直接 no-arg 実行は source 促し exit 0（誤発火しない）" {
    run bash "$SLATE_LIB"
    [ "$status" -eq 0 ]
    [[ "$output" == *"source して使う共有 lib"* ]]
}

# ==============================================================================
# (B) dispatch spawn の slate interlock
# ==============================================================================

@test "(B-present) slate present ∧ member: dispatch は scribe-spawn へ forward（pass）" {
    run_dispatch_gate orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]                # scribe-spawn へ到達
    [[ "$output" == *"orch-test"* ]]
}

@test "(B-absent) slate absent: dispatch は fail-closed で拒否（scribe-spawn を呼ばない）" {
    export SLATE_LIST_JSON='[]'
    run_dispatch_gate orch-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"計画外 dispatch を拒否"* ]] || [[ "$output" == *"slate"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]               # spawn へ到達しない（副作用ゼロで弾く）
}

@test "(B-nonmember) slate present だが対象が members に無い: fail-closed 拒否（空虚 interlock でなく集合照合）" {
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"[ORCH-SLATE v1] members: orch-other, tb"}]'
    run_dispatch_gate orch-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"members 集合に属さない"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "(B-stray-members) sentinel 行外の stray prose members: は interlock へ混入しない（sentinel 行束縛・false-green 封鎖）" {
    # slate notes に「sentinel 行の members(orch-other)」と「別行の設計 prose members: orch-test」を共存させる。
    #   reader が sentinel 行に束縛されず全行を走査すると、prose 由来の orch-test を members へ誤取り込みし
    #   計画外 dispatch(orch-test) を false-green で pass させる（load-bearing interlock の fail-open 化）。
    #   正しくは sentinel 行の orch-other のみが member ＝ orch-test は非属で fail-closed。
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"設計 prose の記述: members: orch-test, orch-evil\n[ORCH-SLATE v1] members: orch-other, tb"}]'
    run_dispatch_gate orch-test
    [ "$status" -ne 0 ]                              # ★prose members: を拾えば pass してしまう＝reject が sentinel 行束縛の teeth
    [[ "$output" == *"members 集合に属さない"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "(B-readfail) slate read 失敗（bd 障害）: fail-closed 拒否（read 不能を pass にしない）" {
    export BD_FAIL=1
    run_dispatch_gate orch-test
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "(B-mut) mutation 非空虚: membership die を no-op 化した mutant は non-member でも pass（緑→赤反転）" {
    # 実 script を sed 変異させ、共有 lib を BASH_SOURCE 相対で解決させるため scripts/lib を sandbox へ symlink する
    #   （orch-dispatch.bats の mut-sandbox と同型。orch_anchor.sh の ../hooks/lib は kernel が symlink 追跡後に解決）。
    local sb="$TEST_TMPDIR/mut"; mkdir -p "$sb"
    ln -s "$(cd "$REPO_ROOT/scripts/lib" && pwd)" "$sb/lib"
    local mutant="$sb/orch-dispatch.sh"
    # membership die 行（1 行）を no-op（:）へ置換＝slate は在るが対象が members に無くても reject しなくなる。
    sed 's/^            die ".*members 集合に属さない.*/            :/' "$SCRIPT_DISPATCH" > "$mutant"
    # 非空虚: 原本に die 行が在り mutant からは消えている。
    grep -q 'members 集合に属さない' "$SCRIPT_DISPATCH"
    ! grep -q 'die ".*members 集合に属さない' "$mutant"
    # slate は present（orch-other を members に持つ・orch-test は非 member）。real なら reject / mutant なら pass。
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"[ORCH-SLATE v1] members: orch-other"}]'
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
    ORCH_DISPATCH_SCRIPTORIUM="$ANCHOR" \
    ORCH_DISPATCH_BD="$BIN/bd" \
    ORCH_DISPATCH_BDW="$BIN/bdw-stub" \
    ORCH_DISPATCH_SKIP_SLATE_GATE=0 \
    ORCH_DISPATCH_POLL_INTERVAL=0 \
    BD_SHOW_JSON="$VALID_BEAD_JSON" \
        run bash "$mutant" orch-test
    [ "$status" -eq 0 ]                              # ★die を殺すと non-member でも spawn へ到達（membership die が load-bearing）
    [[ "$output" == *"SPAWN-ARGS:"* ]]
}

# ==============================================================================
# (C) spawn-admin の slate interlock（照合キー = target project）
# ==============================================================================

@test "(C-present) target project ∈ slate targets: spawn-admin dry-run が plan へ到達（pass）" {
    run_admin_gate tb --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"would spawn"* ]]
}

@test "(C-absent) slate absent: spawn-admin は fail-closed で拒否" {
    export SLATE_LIST_JSON='[]'
    run_admin_gate tb --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"計画外 spawn を拒否"* ]] || [[ "$output" == *"slate"* ]]
}

@test "(C-nonmember) target project が members に無い: fail-closed 拒否（集合照合）" {
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"[ORCH-SLATE v1] members: orch-test, other-proj"}]'
    run_admin_gate tb --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"members 集合に属さない"* ]]
}

# ==============================================================================
# (D) read-only mode / dry-run 照合の非対称
# ==============================================================================

@test "(D-gatepending) --gate-pending は slate 無し∧gate 有効でも従来どおり成功（run_spawn を通らない）" {
    export SLATE_LIST_JSON='[]'
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SCRIPTORIUM="$ANCHOR" \
    ORCH_DISPATCH_BD="$BIN/bd" \
    ORCH_DISPATCH_SKIP_SLATE_GATE=0 \
    ORCH_DISPATCH_POLL_INTERVAL=0 \
        run bash "$SCRIPT_DISPATCH" --gate-pending
    [ "$status" -eq 0 ]                              # gate は spawn 実行経路のみ＝read-only mode を brick しない
}

@test "(D-dryrun-applies) spawn --dry-run は read-only 照合を掛ける: slate 無しで fail-closed（skip の逆解釈を封じる）" {
    export SLATE_LIST_JSON='[]'
    run_dispatch_gate --dry-run orch-test
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "(D-dryrun-pass) spawn --dry-run は slate present なら pass（dry-run でも gate 通過を pin）" {
    run_dispatch_gate --dry-run orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]
    [[ "$output" == *"--dry-run"* ]]
}

# ==============================================================================
# (E) 予約検知線への誤検知ゼロ
# ==============================================================================

@test "(E-byte-invariant) slate 生成（SLATE_LIST_JSON set）で --gate-pending 出力が byte 不変" {
    export BD_LIST_JSON='[{"id":"orch-gp1","title":"gate 待ち cell"}]'
    # slate 有りの --gate-pending 出力
    SLATE_LIST_JSON='[{"id":"orch-slate1"}]' \
    PATH="$BIN:$PATH" ORCH_DISPATCH_SCRIPTORIUM="$ANCHOR" ORCH_DISPATCH_BD="$BIN/bd" \
    ORCH_DISPATCH_SKIP_SLATE_GATE=0 ORCH_DISPATCH_POLL_INTERVAL=0 \
        run bash "$SCRIPT_DISPATCH" --gate-pending
    local with_slate="$output"
    # slate 無しの --gate-pending 出力
    SLATE_LIST_JSON='[]' \
    PATH="$BIN:$PATH" ORCH_DISPATCH_SCRIPTORIUM="$ANCHOR" ORCH_DISPATCH_BD="$BIN/bd" \
    ORCH_DISPATCH_SKIP_SLATE_GATE=0 ORCH_DISPATCH_POLL_INTERVAL=0 \
        run bash "$SCRIPT_DISPATCH" --gate-pending
    local without_slate="$output"
    [ "$with_slate" = "$without_slate" ]            # slate 機構は gate-pending 検知線を perturbate しない
}

@test "(E-no-collision) slate 識別子が予約 token と非衝突（label slate / sentinel [ORCH-SLATE v1]）" {
    # 識別子は予約 label/sentinel を踏まない（誤検知ゼロの構造保証）。
    grep -q 'ORCH_SLATE_LABEL="slate"' "$SLATE_LIB"
    grep -q 'ORCH_SLATE_SENTINEL="\[ORCH-SLATE v1\]"' "$SLATE_LIB"
    # 予約 sentinel（[SPAWNED-- / [ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT）や予約 label を識別子に採用していない。
    [ "$(grep -c 'ORCH_SLATE_SENTINEL=' "$SLATE_LIB")" -ge 1 ]
    ! grep -q 'ORCH_SLATE_LABEL="gate-pending"' "$SLATE_LIB"
    ! grep -q 'ORCH_SLATE_SENTINEL=".*SPAWNED' "$SLATE_LIB"
    ! grep -q 'ORCH_SLATE_SENTINEL=".*ACCEPTANCE-SNAPSHOT' "$SLATE_LIB"
}

# ==============================================================================
# (F) syntax teeth
# ==============================================================================

@test "(F-bash-n) 変更した 3 script が bash -n を通る" {
    run bash -n "$SLATE_LIB"; [ "$status" -eq 0 ]
    run bash -n "$SCRIPT_DISPATCH"; [ "$status" -eq 0 ]
    run bash -n "$SCRIPT_ADMIN"; [ "$status" -eq 0 ]
}

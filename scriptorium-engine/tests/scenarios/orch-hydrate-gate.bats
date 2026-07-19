#!/usr/bin/env bats
# tests/scenarios/orch-hydrate-gate.bats
#
# orch-hydrate-gate.sh（systemd user timer 用 staleness-gated wrapper・bd orch-7ute）の hermetic テスト。
# gate ロジックを stub orch-hydrate + 決定論 NOW + env-seam marker で回し、fence 由来の不変条件を assert する。
#
# private 配備層の docs/systemd drift teeth は配備層側 residual bats が担う（engine copy は mechanism teeth のみ）。
#
# 検証する契約不変条件:
#   (SKIP)      fresh(5分) marker → GATE-SKIP・exit 0・orch-hydrate 非呼出。
#   (SKIP-NOSTAMP)  fence-gate-semantics(b): skip 枝で marker mtime **不変**（gate は stamp しない）。
#   (SYNC)      stale(40分) marker → GATE-SYNC-DONE・orch-hydrate(stub)呼出。
#   (UNKNOWN)   marker 不在 → sync（fail-safe＝unknown を古い側に倒す）。
#   (SYNC-FAIL) hydrate rc≠0 → gate が rc=1 出力 + 非0 exit（service failed 伝播＝backstop 可観測性）。
#   (GATE-FAIL) HYDRATE 非実行可 → GATE-FAIL・非0 exit（fail-closed・silent skip しない）。
#   (MEASURE-A) fence-gate-semantics(a): measure は last-sync marker（env seam）を使う＝marker mtime を
#               動かすと decision が反転する（export-state 等の別ソースに依存しない）。
#   (ROUTE)     fence-invariant: 実 sync は orch-hydrate.sh(stub)経由＝生 `bd repo sync` を叩かない。
#   (INV-OK)    fence-invariant: 既定 THRESHOLD25+PERIOD30=55<60＝GATE-INVARIANT-WARN 非点灯。
#   (INV-WARN)  誤設定 THRESHOLD40+PERIOD30=70>=60＝GATE-INVARIANT-WARN 点灯（非空虚）。
#   (DUR-ON)    fence-flock: sleep1 hydrate + DURATION_WARN_SEC=0 → GATE-DURATION-TRIPWIRE 点灯。
#   (DUR-OFF)   fence-flock: sleep1 hydrate + DURATION_WARN_SEC=3600 → tripwire 非点灯（非空虚・実測駆動の証明）。
#   (DRY)       --dry-run は orch-hydrate を呼ばず plan のみ・exit 0。
#   (SELFTEST)  本体 --self-test が green（多重防御）。
#   (EXEC)      distribution 契約: gate script に実行ビット。
#
# 実行: bats tests/scenarios/orch-hydrate-gate.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-hydrate-gate.sh"
    REPO_ROOT="$BATS_TEST_DIRNAME/../.."
    TEST_TMPDIR=$(mktemp -d -t hydrate-gate-bats-XXXXXX)
    export FIX="$TEST_TMPDIR"
    MARKER="$TEST_TMPDIR/last-sync"
    HYD="$TEST_TMPDIR/orch-hydrate.sh"
    HYD_RAN="$TEST_TMPDIR/hyd-ran"
    NOW=1000000000

    # stub orch-hydrate: 呼ばれたら HYD_RAN に touch ＋ marker を stamp（sync 成功模擬）。
    #   SLEEP env で wall-clock 注入（tripwire）・EXIT_RC env で rc 注入（sync 失敗伝播）。
    cat > "$HYD" <<STUB
#!/usr/bin/env bash
touch "$HYD_RAN"
[ -n "\${SLEEP:-}" ] && sleep "\$SLEEP"
printf 'stamped\n' > "$MARKER"
exit "\${EXIT_RC:-0}"
STUB
    chmod +x "$HYD"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

_gate() { # gate を共通 env で回す
    ORCH_HYDRATE_GATE_MARKER="$MARKER" \
    ORCH_HYDRATE_GATE_HYDRATE="$HYD" \
    ORCH_HYDRATE_GATE_NOW="$NOW" \
    bash "$SCRIPT" "$@"
}
_stamp_age_min() { # $1=分前に marker mtime をセット
    printf 'x\n' > "$MARKER"; touch -d "@$(( NOW - $1*60 ))" "$MARKER"
}

@test "(SKIP) fresh 5分 → GATE-SKIP・orch-hydrate 非呼出" {
    _stamp_age_min 5; rm -f "$HYD_RAN"
    run _gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-SKIP"* ]]
    [ ! -f "$HYD_RAN" ]
}

@test "(SKIP-NOSTAMP) skip 枝で marker mtime 不変（gate 非 stamp・fence-gate-semantics b）" {
    _stamp_age_min 5
    local before after
    before="$(stat -c %Y "$MARKER")"
    run _gate
    after="$(stat -c %Y "$MARKER")"
    [ "$before" = "$after" ]
}

@test "(SYNC) stale 40分 → GATE-SYNC-DONE・orch-hydrate 呼出" {
    _stamp_age_min 40; rm -f "$HYD_RAN"
    run _gate
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-SYNC-DONE"* ]]
    [ -f "$HYD_RAN" ]
}

@test "(UNKNOWN) marker 不在 → sync（fail-safe）" {
    rm -f "$MARKER" "$HYD_RAN"
    run _gate
    [[ "$output" == *"GATE-SYNC-DONE"* ]]
    [ -f "$HYD_RAN" ]
}

@test "(MEASURE-A) measure は last-sync marker mtime＝mtime を動かすと decision 反転" {
    _stamp_age_min 5;  run _gate; [[ "$output" == *"GATE-SKIP"* ]]
    _stamp_age_min 40; run _gate; [[ "$output" == *"GATE-SYNC-DONE"* ]]
}

@test "(ROUTE) 実 sync は orch-hydrate.sh(stub)経由＝生 bd repo sync を叩かない" {
    # stub orch-hydrate は bd を一切呼ばない。gate 自身も bd を直接呼ばないことを本体 grep で pin。
    _stamp_age_min 40; rm -f "$HYD_RAN"
    run _gate
    [ -f "$HYD_RAN" ]
    # コメント行（先頭空白 + #）を除いた実コードに生 bd repo sync 呼出が無いことを pin。
    run bash -c "grep -vE '^[[:space:]]*#' '$SCRIPT' | grep -qE 'bd[[:space:]]+repo[[:space:]]+sync'"
    [ "$status" -ne 0 ]   # gate 実コードに生 bd repo sync が無い
}

@test "(INV-OK) 既定 25+30<60 → GATE-INVARIANT-WARN 非点灯" {
    _stamp_age_min 5
    run _gate
    [[ "$output" != *"GATE-INVARIANT-WARN"* ]]
}

@test "(INV-WARN) 誤設定 40+30>=60 → GATE-INVARIANT-WARN 点灯（非空虚）" {
    _stamp_age_min 5
    run env ORCH_HYDRATE_GATE_THRESHOLD_MIN=40 ORCH_HYDRATE_GATE_MARKER="$MARKER" \
        ORCH_HYDRATE_GATE_HYDRATE="$HYD" ORCH_HYDRATE_GATE_NOW="$NOW" bash "$SCRIPT"
    [[ "$output" == *"GATE-INVARIANT-WARN"* ]]
}

@test "(DUR-ON) sleep1 + DURATION_WARN_SEC=0 → tripwire 点灯" {
    _stamp_age_min 40
    run env SLEEP=1 ORCH_HYDRATE_GATE_DURATION_WARN_SEC=0 ORCH_HYDRATE_GATE_MARKER="$MARKER" \
        ORCH_HYDRATE_GATE_HYDRATE="$HYD" ORCH_HYDRATE_GATE_NOW="$NOW" bash "$SCRIPT"
    [[ "$output" == *"GATE-DURATION-TRIPWIRE"* ]]
}

@test "(DUR-OFF) sleep1 + DURATION_WARN_SEC=3600 → tripwire 非点灯（実測駆動・非空虚）" {
    _stamp_age_min 40
    run env SLEEP=1 ORCH_HYDRATE_GATE_DURATION_WARN_SEC=3600 ORCH_HYDRATE_GATE_MARKER="$MARKER" \
        ORCH_HYDRATE_GATE_HYDRATE="$HYD" ORCH_HYDRATE_GATE_NOW="$NOW" bash "$SCRIPT"
    [[ "$output" != *"GATE-DURATION-TRIPWIRE"* ]]
}

@test "(SYNC-FAIL) hydrate rc≠0 → gate が rc=1 出力 + 非0 exit（service failed 伝播）" {
    _stamp_age_min 40
    run env EXIT_RC=1 ORCH_HYDRATE_GATE_MARKER="$MARKER" ORCH_HYDRATE_GATE_HYDRATE="$HYD" \
        ORCH_HYDRATE_GATE_NOW="$NOW" bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"rc=1"* ]]
}

@test "(GATE-FAIL) HYDRATE 非実行可 → GATE-FAIL・非0 exit（fail-closed・silent skip しない）" {
    _stamp_age_min 40
    run env ORCH_HYDRATE_GATE_MARKER="$MARKER" ORCH_HYDRATE_GATE_HYDRATE="$TEST_TMPDIR/nonexistent-hyd" \
        ORCH_HYDRATE_GATE_NOW="$NOW" bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"GATE-FAIL"* ]]
}

@test "(DRY) --dry-run は orch-hydrate 非呼出・plan のみ・exit 0" {
    _stamp_age_min 40; rm -f "$HYD_RAN"
    run _gate --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [ ! -f "$HYD_RAN" ]
}

@test "(SELFTEST) 本体 --self-test が green" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALL PASS"* ]]
}

@test "(EXEC) gate script に実行ビット" {
    [ -x "$SCRIPT" ]
}

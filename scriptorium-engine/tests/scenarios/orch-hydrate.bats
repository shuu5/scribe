#!/usr/bin/env bats
# tests/scenarios/orch-hydrate.bats
#
# orch-hydrate.sh（連結 substrate の冪等 bootstrap・un-aoa / orch-vo2 で共有 lib 統合）の hermetic 回帰。
# orch-jwr（vo2 follow-up）: 5 script 中 hydrate 系 2 script のみ bats が皆無で、共有 lib
#   scripts/hooks/lib/orch_session.sh 統合（`source` 解決・_ledger_dolt_database gate・foreign refuse）の
#   自動回帰保護がゼロだった。他 consumer（clean-state-probe HGATE2 / reconciliation-parity / discovery-nudge）
#   と同水準の teeth を揃える。orch-hydrate は 5 script 中唯一 write（bdw repo add|sync）を伴うため
#   source ブロック不備の影響が大きい。
#
# 方式（既存 bats の hermetic 先例に従う）:
#   - 実 dolt/bd/bdw を一切呼ばない。self-scope 用の fake 台帳（.beads/metadata.json）を temp に作り、
#     その cwd から**実 script**を起動する（実 script は BASH_SOURCE 相対で実 lib を解決する＝source 解決を pin）。
#   - project list は ORCH_HYDRATE_PROJECTS で存在しない fake path に全置換し実 project を触らない。
#   - write を伴う経路（bdw repo add|sync）には触れないよう **--dry-run** のみで実行する（bdw 非呼出）。
#
# 検証する契約不変条件（orch-jwr acceptance）:
#   (anchor) orch anchor（dolt_database=orch）から --dry-run が exit 0・source 解決＋gate 通過を pin。
#   (scope)  foreign cwd（dolt_database≠orch）は refuse・exit1（誤台帳 write 防止 fail-closed）。
#   (HGATE2) 破損 orch-token metadata（orch トークン在るが JSON 破損）→ refuse・exit1
#            （共有 lib の _json_is_valid gate が誤 self-scope を防ぐ・clean-state-probe HGATE2 同型）。
#   (mut)    gate 素通し変異（_json_is_valid→常時 true）で破損 orch-token が refuse しなくなる＝
#            HGATE2 の refuse が「gate によるもの」であることの非vacuity teeth（orch-jwr acceptance 3）。
#   (lib)    共有 self-scope lib 不在なら fail-closed exit1（source 解決の fail-closed 枝を pin）。
#   (projlist-die)      project list seam: env 未供給 ∧ private registry 不在 → fail-loud die exit1
#                       （engine tree は値の hardcode を持たない＝配備層 registry or env のみが SSOT）。
#   (projlist-registry) env 未供給でも registry があれば source して die しない（registry seam の source 枝）。
#   (syntax) bash -n（構文）が通る。
#
# 注（engine copy）: engine tree は private 配備層 registry（scripts/lib/orch-projects.sh・実名 project list）を
#   同梱しない。本 bats は実 registry を copy せず、合成 registry fixture（projalpha/projbeta・存在しない path）を
#   テスト内で生成して source 枝を検証する。private 配備層の docs/systemd drift teeth は配備層側 residual bats が
#   担う（engine copy は mechanism teeth のみ）。
#
# 実行: bats tests/scenarios/orch-hydrate.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-hydrate.sh"
    REAL_SESSION_LIB="$REPO/scripts/hooks/lib/orch_session.sh"
    # engine tree は private registry（実名 project list）を同梱しない。テストは REAL registry を
    # copy せず、_gen_registry が合成 registry fixture（projalpha/projbeta・存在しない path）を生成して
    # deploy 層の scripts/lib/orch-projects.sh を代替する（seam = env or registry or fail-loud）。

    TEST_TMPDIR="$(mktemp -d -t orch-hydrate-bats-XXXXXX)"

    # self-scope 用 fake orch 台帳（dolt_database=orch）。この cwd から script を走らせる。
    ORCH="$TEST_TMPDIR/orch"
    mkdir -p "$ORCH/.beads"
    printf '{"dolt_database":"orch"}\n' > "$ORCH/.beads/metadata.json"

    # 実 project を一切触らせない（存在しない fake path へ全置換）。
    export ORCH_HYDRATE_PROJECTS="fake=/nonexistent/orch-jwr-hydrate-xyz"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fake orch 台帳の cwd で実 script を hermetic に実行（--dry-run 固定で write 経路を封じる）。
run_in_orch() {
    run bash -c "cd '$ORCH' && bash '$SCRIPT' \"\$@\"" -- "$@"
}

# 合成 private registry fixture を生成する（engine tree は実 registry を持たない）。
# script は `source` された registry に DEFAULT_PROJECTS=(...) が設定されることを期待する。
# 全 path は /nonexistent ゆえ実 project を触らない（env ORCH_HYDRATE_PROJECTS が set のときは env 優先）。
_gen_registry() {
    cat > "$1" <<'EOF'
# synthetic private registry fixture — engine copy has no real registry
DEFAULT_PROJECTS=(
    "projalpha=/nonexistent/orch-jwr-hydrate-projalpha"
    "projbeta=/nonexistent/orch-jwr-hydrate-projbeta"
)
EOF
}

# 実 script + 共有 lib を temp sandbox へ複製し、mutated（gate 素通し）版 lib を差し込む。
# 実 lib は BASH_SOURCE 相対（env override 無し）ゆえ、mutated lib を食わせるには script を lib の隣へ複製する。
#   $1 = "plain" | "mutate"（mutate は _json_is_valid を常時 return 0 にして gate を無効化）
#   $2 = sandbox dir
_build_sandbox() {
    local mode="$1" sb="$2"
    mkdir -p "$sb/hooks/lib" "$sb/lib"
    cp "$SCRIPT" "$sb/orch-hydrate.sh"
    _gen_registry "$sb/lib/orch-projects.sh"
    if [ "$mode" = "mutate" ]; then
        # gate 素通し変異: _json_is_valid を関数先頭で `return 0` へ短絡（破損 JSON を妥当扱いにする）。
        sed 's/^_json_is_valid() {/_json_is_valid() { return 0 # MUTATED: gate bypass/' \
            "$REAL_SESSION_LIB" > "$sb/hooks/lib/orch_session.sh"
    else
        cp "$REAL_SESSION_LIB" "$sb/hooks/lib/orch_session.sh"
    fi
}

# ==============================================================================
# (anchor) orch anchor から --dry-run が exit 0（source 解決 + self-scope gate 通過を pin）
# ==============================================================================
@test "(anchor) orch 台帳 cwd から --dry-run は exit0・summary を出す（source 解決 + gate 通過）" {
    run_in_orch --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-hydrate (DRY-RUN)"* ]]
    [[ "$output" == *"dolt_database=orch"* ]]      # gate が cwd 台帳を orch と解決した証跡
    [[ "$output" != *"refusing to run"* ]]
    [[ "$output" == *"summary:"* ]]
}

# ==============================================================================
# (scope) foreign cwd（dolt_database≠orch）は refuse・exit1（誤台帳 write 防止 fail-closed）
# ==============================================================================
@test "(scope) foreign 台帳 cwd（dolt_database≠orch）は refuse・exit1" {
    local FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$FOREIGN/.beads"
    printf '{"dolt_database":"un"}\n' > "$FOREIGN/.beads/metadata.json"
    run bash -c "cd '$FOREIGN' && bash '$SCRIPT' --dry-run"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"orch-hydrate (DRY-RUN)"* ]]  # gate 前に抜けるので DRY-RUN body に入らない
}

# ==============================================================================
# (HGATE2) 破損 orch-token metadata → refuse・exit1（_json_is_valid gate が誤 self-scope を防ぐ）
# ==============================================================================
@test "(HGATE2) 破損 orch-token metadata（orch トークン在るが JSON 破損）→ refuse・exit1" {
    # clean-state-probe HGATE2 同型: 旧 inline _resolve_dolt_database（gate なし sed 直抽出）は破損 JSON でも
    # orch トークンを拾い誤 self-scope した。共有 lib の gate 済み _ledger_dolt_database は _json_is_valid で
    # 破損を検出し空 db に畳む＝refuse 側（fail-closed）へ倒す。
    local BROKEN="$TEST_TMPDIR/broken"
    mkdir -p "$BROKEN/.beads"
    printf '{"dolt_database":"orch"' > "$BROKEN/.beads/metadata.json"   # 未閉じ = 破損 JSON（orch トークン在）
    run bash -c "cd '$BROKEN' && bash '$SCRIPT' --dry-run"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"orch-hydrate (DRY-RUN)"* ]]
}

# ==============================================================================
# (mut) gate 素通し変異で破損 orch-token が refuse しなくなる＝HGATE2 の非vacuity teeth（acceptance 3）
# ==============================================================================
@test "(mut) gate 素通し変異（_json_is_valid→true）で破損 orch-token が refuse しなくなる（HGATE2 非vacuity）" {
    local BROKEN="$TEST_TMPDIR/broken-mut"
    mkdir -p "$BROKEN/.beads"
    printf '{"dolt_database":"orch"' > "$BROKEN/.beads/metadata.json"   # 未閉じ = 破損 JSON（orch トークン在）

    # baseline: 変異なし複製は HGATE2 と同じく refuse する（複製経路が実挙動を再現していることの sanity）。
    local SB_PLAIN="$TEST_TMPDIR/sb-plain"
    _build_sandbox plain "$SB_PLAIN"
    run bash -c "cd '$BROKEN' && bash '$SB_PLAIN/orch-hydrate.sh' --dry-run"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]

    # mutate: gate を素通しにすると破損 orch-token が 'orch' と解決され self-scope を通過＝refuse しなくなる（RED flip）。
    local SB_MUT="$TEST_TMPDIR/sb-mut"
    _build_sandbox mutate "$SB_MUT"
    grep -q "MUTATED: gate bypass" "$SB_MUT/hooks/lib/orch_session.sh"   # 変異が実際に効いていること（非vacuity）
    run bash -c "cd '$BROKEN' && bash '$SB_MUT/orch-hydrate.sh' --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" != *"refusing to run"* ]]
    [[ "$output" == *"orch-hydrate (DRY-RUN)"* ]]   # gate 通過後の body に到達（refuse が gate 由来だった証明）
}

# ==============================================================================
# (lib) 共有 self-scope lib 不在なら fail-closed exit1（source 解決の fail-closed 枝を pin）
# ==============================================================================
@test "(lib) 共有 self-scope lib 不在なら fail-closed exit1（source 解決 pin）" {
    local SB="$TEST_TMPDIR/sb-nolib"
    mkdir -p "$SB/lib"
    cp "$SCRIPT" "$SB/orch-hydrate.sh"
    _gen_registry "$SB/lib/orch-projects.sh"
    # hooks/lib/orch_session.sh を意図的に置かない → source 解決が fail-closed で die するはず。
    run bash -c "cd '$ORCH' && bash '$SB/orch-hydrate.sh' --dry-run"
    [ "$status" -ne 0 ]
    [[ "$output" == *"共有 self-scope lib 不在"* ]]
}

# ==============================================================================
# (projlist-die) project list seam: env 未供給 ∧ private registry 不在 → fail-loud die exit1
#   engine tree は実 registry（値の hardcode）を持たない。env ORCH_HYDRATE_PROJECTS も unset なら
#   「未供給（fail-loud）」で die する（degraded 続行しない＝値の SSOT は配備層 or env のみ）。
#   実 SCRIPT の隣（$REPO/scripts/lib）に orch-projects.sh は無い（engine copy）ので実 script で検証できる。
# ==============================================================================
@test "(projlist-die) env 未供給 ∧ registry 不在 → project list 未供給で fail-loud exit1" {
    run bash -c "cd '$ORCH' && unset ORCH_HYDRATE_PROJECTS && bash '$SCRIPT' --dry-run"
    [ "$status" -ne 0 ]
    [[ "$output" == *"project list 未供給（fail-loud）"* ]]
    [[ "$output" != *"orch-hydrate (DRY-RUN)"* ]]   # die は list 解決段＝body に入らない
}

# ==============================================================================
# (projlist-registry) env 未供給でも private registry があれば source して die しない（registry seam）
#   sandbox の lib/orch-projects.sh（合成 registry・DEFAULT_PROJECTS 設定）が env 不在を埋め、
#   fail-loud die 枝へ入らず DRY-RUN body へ到達する（registry があれば source の枝を pin）。
# ==============================================================================
@test "(projlist-registry) env 未供給でも registry があれば source して die しない（registry seam）" {
    local SB="$TEST_TMPDIR/sb-registry"
    _build_sandbox plain "$SB"   # 合成 registry(projalpha/projbeta) を lib/ に生成する
    run bash -c "cd '$ORCH' && unset ORCH_HYDRATE_PROJECTS && bash '$SB/orch-hydrate.sh' --dry-run"
    [ "$status" -eq 0 ]
    [[ "$output" != *"project list 未供給（fail-loud）"* ]]  # registry があるので die しない
    [[ "$output" == *"orch-hydrate (DRY-RUN)"* ]]           # source 成功 → body へ到達
}

# ==============================================================================
# (EXEC) distribution 契約: SCRIPT に実行ビットがある（bare path 単発起動・orch-jwr errata E2）
#   orch-hydrate は top-spec §228 / orch-dispatch.sh の連結 substrate bootstrap から bare path
#   （`scripts/orch-hydrate.sh`）で起動される配布形。非実行(100644)だと全ホストで Permission denied。
#   self-test/bats は `bash "$SCRIPT"` 経由ゆえ exec-bit 欠落を検知しない＝この assert が唯一のゲート
#   （orch-clean-state-probe.bats の (EXEC) test と同型）。
# ==============================================================================
@test "(EXEC) SCRIPT に実行ビットがある（bare path 単発起動が動く・distribution 契約）" {
    [ -x "$SCRIPT" ]
}

# ==============================================================================
# (syntax) bash -n（構文）が通る
# ==============================================================================
@test "(syntax) bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

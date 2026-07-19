#!/usr/bin/env bats
# tests/scenarios/orch-architecture-hydrate.bats
#
# orch-architecture-hydrate.sh（folio inventory read-channel・orch-2ax / orch-vo2 で共有 lib 統合）の hermetic 回帰。
# orch-jwr（vo2 follow-up）: hydrate 系 2 script のみ bats が皆無だったため、共有 lib
#   scripts/hooks/lib/orch_session.sh 統合（`source` 解決・_ledger_dolt_database gate・foreign refuse）の
#   自動回帰保護を他 consumer（clean-state-probe HGATE2 / reconciliation-parity / discovery-nudge）と同水準に揃える。
#   本 channel は read-only（writable foreign copy を作らない）ゆえ、pin する核は self-scope gate の健全性。
#
# 方式（既存 bats の hermetic 先例に従う）:
#   - 実 dolt/bd/folio inventory を一切用いない。self-scope 用の fake 台帳（.beads/metadata.json）を temp に作り、
#     その cwd から**実 script**を起動する（実 script は BASH_SOURCE 相対で実 lib を解決＝source 解決を pin）。
#   - project list は ORCH_ARCH_PROJECTS で存在しない fake path に全置換し実 project/inventory を触らない。
#   - merge engine（python3）を要さない **--list** モードで実行する（gate は list/merge 両モードで走る）。
#   - session gate 検査が目的ゆえ ORCH_ARCH_SKIP_SESSION_GATE は**設定しない**（gate を有効なまま exercise する）。
#
# 検証する契約不変条件（orch-jwr acceptance）:
#   (anchor) orch anchor（dolt_database=orch）から --list が exit 0・source 解決＋gate 通過を pin。
#   (scope)  foreign cwd（dolt_database≠orch）は refuse・exit1（誤台帳 read 防止・self-scope 一貫性 fail-closed）。
#   (HGATE2) 破損 orch-token metadata（orch トークン在るが JSON 破損）→ refuse・exit1
#            （共有 lib の _json_is_valid gate が誤 self-scope を防ぐ・clean-state-probe HGATE2 同型）。
#   (mut)    gate 素通し変異（_json_is_valid→常時 true）で破損 orch-token が refuse しなくなる＝
#            HGATE2 の refuse が「gate によるもの」であることの非vacuity teeth（orch-jwr acceptance 3）。
#   (lib)    共有 self-scope lib 不在なら fail-closed exit1（source 解決の fail-closed 枝を pin）。
#   (syntax) bash -n（構文）が通る。
#
# 実行: bats tests/scenarios/orch-architecture-hydrate.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-architecture-hydrate.sh"
    REAL_SESSION_LIB="$REPO/scripts/hooks/lib/orch_session.sh"
    # engine tree は private 配備層 registry overlay（scripts/lib/orch-projects.sh）を持たない＝project list は
    #   env seam ORCH_ARCH_PROJECTS で供給する（下記 export）。sandbox 複製も engine layout に倣い overlay を
    #   置かない（overlay は「配備層が配置した場合のみ source」＝env 供給時は未到達で inert）。

    TEST_TMPDIR="$(mktemp -d -t orch-arch-hydrate-bats-XXXXXX)"

    # self-scope 用 fake orch 台帳（dolt_database=orch）。この cwd から script を走らせる。
    ORCH="$TEST_TMPDIR/orch"
    mkdir -p "$ORCH/.beads"
    printf '{"dolt_database":"orch"}\n' > "$ORCH/.beads/metadata.json"

    # 実 project/inventory を一切触らせない（存在しない fake path へ全置換）。
    export ORCH_ARCH_PROJECTS="fake=/nonexistent/orch-jwr-arch-xyz"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fake orch 台帳の cwd で実 script を hermetic に実行（merge engine を要さない --list 固定）。
run_in_orch() {
    run bash -c "cd '$ORCH' && bash '$SCRIPT' \"\$@\"" -- "$@"
}

# 実 script + 共有 lib を temp sandbox へ複製し、mutated（gate 素通し）版 lib を差し込む。
# 実 lib は BASH_SOURCE 相対（env override 無し）ゆえ、mutated lib を食わせるには script を lib の隣へ複製する。
#   $1 = "plain" | "mutate"（mutate は _json_is_valid を常時 return 0 にして gate を無効化）
#   $2 = sandbox dir
_build_sandbox() {
    local mode="$1" sb="$2"
    mkdir -p "$sb/hooks/lib"
    cp "$SCRIPT" "$sb/orch-architecture-hydrate.sh"
    # private registry overlay は複製しない（engine layout どおり不在）＝project list は ORCH_ARCH_PROJECTS env 供給。
    if [ "$mode" = "mutate" ]; then
        # gate 素通し変異: _json_is_valid を関数先頭で `return 0` へ短絡（破損 JSON を妥当扱いにする）。
        sed 's/^_json_is_valid() {/_json_is_valid() { return 0 # MUTATED: gate bypass/' \
            "$REAL_SESSION_LIB" > "$sb/hooks/lib/orch_session.sh"
    else
        cp "$REAL_SESSION_LIB" "$sb/hooks/lib/orch_session.sh"
    fi
}

# ==============================================================================
# (anchor) orch anchor から --list が exit 0（source 解決 + self-scope gate 通過を pin）
# ==============================================================================
@test "(anchor) orch 台帳 cwd から --list は exit0・summary を出す（source 解決 + gate 通過）" {
    run_in_orch --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"summary:"* ]]
    [[ "$output" != *"refusing to run"* ]]
    # fake project が inventory 不在で graceful skip されたことを behavioral に pin する（orch-jwr errata E1）。
    # 旧 `*"absent"* ` は summary 行が projects 数に関係なく無条件で "absent(skip)=" を含むため空振りだった。
    # per-source SKIP 行（fake project 名を含む）と summary の present/absent count で present と弁別する。
    [[ "$output" == *"SKIP (inventory absent): fake"* ]]
    [[ "$output" == *"present=0 absent(skip)=1"* ]]
}

# ==============================================================================
# (scope) foreign cwd（dolt_database≠orch）は refuse・exit1（誤台帳 read 防止・self-scope 一貫性）
# ==============================================================================
@test "(scope) foreign 台帳 cwd（dolt_database≠orch）は refuse・exit1" {
    local FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$FOREIGN/.beads"
    printf '{"dolt_database":"un"}\n' > "$FOREIGN/.beads/metadata.json"
    run bash -c "cd '$FOREIGN' && bash '$SCRIPT' --list"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"summary:"* ]]                # gate 前に抜けるので summary に到達しない
}

# ==============================================================================
# (HGATE2) 破損 orch-token metadata → refuse・exit1（_json_is_valid gate が誤 self-scope を防ぐ）
# ==============================================================================
@test "(HGATE2) 破損 orch-token metadata（orch トークン在るが JSON 破損）→ refuse・exit1" {
    # clean-state-probe HGATE2 同型: 破損 JSON は _json_is_valid gate で不採用→空 db→refuse（fail-closed）。
    local BROKEN="$TEST_TMPDIR/broken"
    mkdir -p "$BROKEN/.beads"
    printf '{"dolt_database":"orch"' > "$BROKEN/.beads/metadata.json"   # 未閉じ = 破損 JSON（orch トークン在）
    run bash -c "cd '$BROKEN' && bash '$SCRIPT' --list"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"summary:"* ]]
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
    run bash -c "cd '$BROKEN' && bash '$SB_PLAIN/orch-architecture-hydrate.sh' --list"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]

    # mutate: gate を素通しにすると破損 orch-token が 'orch' と解決され self-scope を通過＝refuse しなくなる（RED flip）。
    local SB_MUT="$TEST_TMPDIR/sb-mut"
    _build_sandbox mutate "$SB_MUT"
    grep -q "MUTATED: gate bypass" "$SB_MUT/hooks/lib/orch_session.sh"   # 変異が実際に効いていること（非vacuity）
    run bash -c "cd '$BROKEN' && bash '$SB_MUT/orch-architecture-hydrate.sh' --list"
    [ "$status" -eq 0 ]
    [[ "$output" != *"refusing to run"* ]]
    [[ "$output" == *"summary:"* ]]                # gate 通過後の body に到達（refuse が gate 由来だった証明）
}

# ==============================================================================
# (lib) 共有 self-scope lib 不在なら fail-closed exit1（source 解決の fail-closed 枝を pin）
# ==============================================================================
@test "(lib) 共有 self-scope lib 不在なら fail-closed exit1（source 解決 pin）" {
    local SB="$TEST_TMPDIR/sb-nolib"
    mkdir -p "$SB"
    cp "$SCRIPT" "$SB/orch-architecture-hydrate.sh"
    # private registry overlay は複製しない（engine layout どおり不在・project list は ORCH_ARCH_PROJECTS 供給）。
    # hooks/lib/orch_session.sh を意図的に置かない → source 解決が fail-closed で die するはず。
    run bash -c "cd '$ORCH' && bash '$SB/orch-architecture-hydrate.sh' --list"
    [ "$status" -ne 0 ]
    [[ "$output" == *"共有 self-scope lib 不在"* ]]
}

# ==============================================================================
# (EXEC) distribution 契約: SCRIPT に実行ビットがある（bare path 単発起動・orch-jwr errata E2）
#   orch-architecture-hydrate は top-spec §228 / orch-dispatch.sh の architecture-hydrate channel から
#   bare path（`scripts/orch-architecture-hydrate.sh`）で起動される配布形。非実行(100644)だと全ホストで
#   Permission denied。self-test/bats は `bash "$SCRIPT"` 経由ゆえ exec-bit 欠落を検知しない＝この assert が
#   唯一のゲート（orch-clean-state-probe.bats の (EXEC) test と同型）。
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

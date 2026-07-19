#!/usr/bin/env bats
# tests/scenarios/orch-discovery-nudge.bats
#
# orch-discovery-nudge.sh（orch-s8c courier nudge / orch-3d4 Step B 横断 silent-failure 対策）の決定的テスト。
#
# 方式: bd / tmux / session-comm を env スタブで差し替え、self-scope 用 fake ledger（.beads dolt_database=orch）
#   から実 script を実行する hermetic E2E。実 dolt / tmux / inject を一切使わない（selftest-orch-s8c の durable 版）。
#   - bd          : ORCH_NUDGE_BD で差替（list -l needs-grill --json で $BD_SCAN_JSON を返す）。
#   - tmux        : ORCH_NUDGE_TMUX で差替（list-windows -a -F → $TMUX_WINDOWS の行を出す＝window 存在の制御）。
#   - session-comm: ORCH_NUDGE_SESSION_COMM で差替（argv を $SC_ARGS_FILE に記録 + $SC_RC で exit code 注入）。
#   - prefix map  : ORCH_NUDGE_PREFIX_MAP="tu=testproj" で hermetic 化（既定 map 変更から decouple）。
#
# 検証する契約不変条件（top-spec §5.2 横断 (a)(b) + bd orch-3d4 Step B = ratify 済契約）:
#   (B1) 配送 cmd は必ず --confirm-receipt / --wait を含む（送達 read-back を無効化させない）。
#   (B2) session-comm が exit 4（受理未確認）を返したら failure に数え非 0 終了（silent success にしない＝twill 教訓）。
#   (B3) 配送安全 flag 秒が非正整数なら起動時 die（fail-closed＝confirm-receipt を黙って無効化させない）。
#   (B4) session-comm が exit 0（確認済）なら injected・exit 0。
#   (B5) self-scope: 非 orch 台帳からは何もせず非 0（foreign 誤 scan 防止 fail-closed）。
#   (B6) needs-grill 無は no-op で exit 0。
#   (B7) --dry-run: 配送予定 cmd に --confirm-receipt を含むが session-comm を実行しない。
#   (B8) live window 不在は人間 notice を print し session-comm を呼ばない（exit 0）。
#   (B9) bash -n（構文）が通る。
#
# 実行: bats tests/scenarios/orch-discovery-nudge.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-discovery-nudge.sh"
    TEST_TMPDIR=$(mktemp -d -t orch-nudge-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    # self-scope 用 fake ledger（dolt_database=orch）。cwd をここにして script を走らせる。
    LEDGER="$TEST_TMPDIR/orch-ledger"
    mkdir -p "$LEDGER/.beads"
    printf '{"dolt_database":"orch"}\n' > "$LEDGER/.beads/metadata.json"

    # session-comm の呼び出し argv 記録先（空＝未呼出を assert できる）。
    export SC_ARGS_FILE="$TEST_TMPDIR/sc-args.txt"
    : > "$SC_ARGS_FILE"

    # ── stub: bd（list -l needs-grill --json で $BD_SCAN_JSON を返す）──
    cat > "$BIN/bd-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${BD_SCAN_JSON:-[]}"
exit 0
STUB

    # ── stub: tmux（list-windows -a -F → $TMUX_WINDOWS の各行を format 尊重で出す）──
    #   orch-riz1 topology: 実 script は format を `#{session_name}:#{window_name}` で叩く。stub は -F を parse し、
    #   session_name を含む format なら session:window 形、そうでなければ window_name のみを emit する（＝bare-name 退行
    #   mutation〔`#{window_name}` へ戻す〕で 2-session の素 admin 窓が曖昧化し teeth が RED になる非vacuity を担保）。
    #   フィクスチャ TMUX_WINDOWS は session:window 形（colon 無しは bare window として TMUX_DEFAULT_SESSION を合成）。
    cat > "$BIN/tmux-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    shift
    fmt=""; prevf=""
    for a in "$@"; do [ "$prevf" = "-F" ] && fmt="$a"; prevf="$a"; done
    for w in ${TMUX_WINDOWS:-}; do
      case "$w" in
        *:*) sess="${w%%:*}"; win="${w#*:}" ;;
        *)   sess="${TMUX_DEFAULT_SESSION:-orch}"; win="$w" ;;
      esac
      case "$fmt" in
        *session_name*) printf '%s:%s\n' "$sess" "$win" ;;
        *)              printf '%s\n' "$win" ;;
      esac
    done
    ;;
esac
exit 0
STUB

    # ── stub: session-comm（argv 記録 + SC_RC で exit code 注入＝exit 4 等の未確認を模倣）──
    cat > "$BIN/session-comm-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SC_ARGS_FILE"
exit "${SC_RC:-0}"
STUB

    chmod +x "$BIN/bd-stub" "$BIN/tmux-stub" "$BIN/session-comm-stub"

    # tool スタブ path は全テスト共通（export して run へ継承）。per-test 変数は各テストで export する。
    export ORCH_NUDGE_BD="$BIN/bd-stub"
    export ORCH_NUDGE_TMUX="$BIN/tmux-stub"
    export ORCH_NUDGE_SESSION_COMM="$BIN/session-comm-stub"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# fake orch ledger の cwd で実 script を hermetic に実行（export 済 env を継承）。
run_nudge() {
    run bash -c "cd \"$LEDGER\" && exec bash \"$SCRIPT\" \"\$@\"" -- "$@"
}

# ==============================================================================
# (B1) 配送 cmd は必ず --confirm-receipt / --wait を含む
# ==============================================================================
@test "(B1) 配送 cmd は必ず --confirm-receipt と --wait を含む（送達 read-back を無効化させない）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="testproj:admin"   # session:window 正準形（session=project=testproj・素 admin 窓・orch-riz1）
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    grep -q -- '--confirm-receipt' "$SC_ARGS_FILE"
    grep -q -- '--wait' "$SC_ARGS_FILE"
}

# ==============================================================================
# (B2) exit 4（未確認）は failure・非 0 終了（silent success にしない＝twill 教訓「fallback が真実を隠す」）
# ==============================================================================
@test "(B2) session-comm が exit 4（受理未確認）を返したら failure に数え非 0 終了（silent success にしない）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="testproj:admin"   # session:window 正準形（session=project=testproj・素 admin 窓・orch-riz1）
    export SC_RC=4
    run_nudge
    [ "$status" -ne 0 ]                       # 未確認を成功で隠さず非 0 で surface
    [[ "$output" == *"FAIL"* ]]
    [[ "$output" == *"failures=1"* ]]
    [[ "$output" == *"injected=0"* ]]         # exit 4 を injected に数えない（核心 acceptance）
    [[ "$output" != *"failures=0"* ]]
}

# ==============================================================================
# (B3) 配送安全 flag 秒が非正整数なら起動時 die（fail-closed）
# ==============================================================================
@test "(B3a) ORCH_NUDGE_CONFIRM_SECONDS=0 は起動時 die（confirm-receipt を無効化させない）" {
    export ORCH_NUDGE_CONFIRM_SECONDS=0
    export BD_SCAN_JSON='[]'
    run_nudge
    [ "$status" -ne 0 ]
    [[ "$output" == *"confirm-receipt"* ]]
}

@test "(B3b) ORCH_NUDGE_CONFIRM_SECONDS が非数値は起動時 die" {
    export ORCH_NUDGE_CONFIRM_SECONDS="abc"
    export BD_SCAN_JSON='[]'
    run_nudge
    [ "$status" -ne 0 ]
    [[ "$output" == *"confirm-receipt"* ]] || [[ "$output" == *"CONFIRM"* ]]
}

@test "(B3c) ORCH_NUDGE_WAIT_SECONDS が非正整数は起動時 die" {
    export ORCH_NUDGE_WAIT_SECONDS="0"
    export BD_SCAN_JSON='[]'
    run_nudge
    [ "$status" -ne 0 ]
    [[ "$output" == *"WAIT"* ]] || [[ "$output" == *"wait"* ]]
}

# ==============================================================================
# (B4) exit 0（確認済）は injected・exit 0
# ==============================================================================
@test "(B4) session-comm が exit 0（確認済）なら injected・exit 0" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="testproj:admin"   # session:window 正準形（session=project=testproj・素 admin 窓・orch-riz1）
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    [[ "$output" == *"failures=0"* ]]
}

# ==============================================================================
# (B5) self-scope: 非 orch 台帳からは何もせず非 0（foreign 誤 scan 防止）
# ==============================================================================
@test "(B5) 非 orch 台帳からは refusing で非 0（誤 scan 防止 fail-closed）" {
    local foreign="$TEST_TMPDIR/foreign-ledger"
    mkdir -p "$foreign/.beads"
    printf '{"dolt_database":"un"}\n' > "$foreign/.beads/metadata.json"
    export BD_SCAN_JSON='[{"id":"un-1","title":"x"}]'
    run bash -c "cd \"$foreign\" && exec bash \"$SCRIPT\""
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing"* ]]
}

# ==============================================================================
# (B6) needs-grill 無は no-op で exit 0
# ==============================================================================
@test "(B6) needs-grill 無は no-op で exit 0" {
    export BD_SCAN_JSON='[]'
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"no needs-grill"* ]]
    [[ "$output" == *"injected=0"* ]]
}

# ==============================================================================
# (B7) --dry-run: 配送予定 cmd に --confirm-receipt を含むが session-comm を実行しない
# ==============================================================================
@test "(B7) --dry-run: 配送予定 cmd に --confirm-receipt を含み session-comm を実行しない" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="testproj:admin"   # session:window 正準形（session=project=testproj・素 admin 窓・orch-riz1）
    : > "$SC_ARGS_FILE"
    run_nudge --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"--confirm-receipt"* ]]
    [ ! -s "$SC_ARGS_FILE" ]                  # session-comm は一度も呼ばれない
}

# ==============================================================================
# (B8) live window 不在は人間 notice を print し session-comm を呼ばない
# ==============================================================================
@test "(B8) live window 不在は人間 notice を print し session-comm を呼ばない（exit 0）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS=""                     # admin-testproj 不在
    : > "$SC_ARGS_FILE"
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTICE"* ]]
    [[ "$output" == *"orch-spawn-admin testproj"* ]]
    [ ! -s "$SC_ARGS_FILE" ]                  # 人間 notice 路では session-comm を呼ばない
}

# ==============================================================================
# (B10) topology orch-riz1: session:window 正準形 `<project>:admin` で一意到達 + 正準形 inject
# ==============================================================================
@test "(B10a) 正準形 inject: live admin を検知したら session-comm の宛先は <project>:admin（旧 bare admin-<project> でない）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="testproj:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    grep -qF 'testproj:admin' "$SC_ARGS_FILE"        # 宛先正準形で inject（透過の非vacuity）
    ! grep -qF 'admin-testproj' "$SC_ARGS_FILE"       # 旧 bare 形は使わない（bare-name 退行封鎖）
}

@test "(B10b) 一意到達: 2 session が共に素 admin 窓を持っても <project>:admin で狙った側だけへ inject する（session 修飾で曖昧回避）" {
    # 素 admin 窓（window 名=admin）が 2 session（projalpha / projbeta）に併存する。session 名=project 名が識別を
    #   担うため宛先 `projbeta:admin`（prefix tu→project projbeta）で projalpha 側に触れず一意到達する。bare-name
    #   退行 mutation（format を `#{window_name}` に戻す）では両窓が `admin` に潰れ target `admin-projbeta` 不一致
    #   →NOTICE→injected=0 で RED。
    export ORCH_NUDGE_PREFIX_MAP="tu=projbeta"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="projalpha:admin projbeta:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    grep -qF 'projbeta:admin' "$SC_ARGS_FILE"          # 狙った側へ到達
    ! grep -qF 'projalpha:admin' "$SC_ARGS_FILE"       # 別 session の同名窓には触れない
    ! grep -qF 'admin-projbeta' "$SC_ARGS_FILE"        # 旧 bare 形は使わない
}

# ==============================================================================
# (B11) engine seam: 既定 prefix map は allowlist（orch/sc/ccs）のみ＝private 配備層の連結先を持たない
#   ORCH_NUDGE_PREFIX_MAP 未供給時の DEFAULT_PREFIX_MAP は orch=orchestrator / sc=scribe / ccs=cc-session の
#   3 entry のみ（private project 連結先は配備層が ORCH_NUDGE_PREFIX_MAP で full 供給する）。allowlist prefix は
#   canonical project へ解決し、非 allowlist prefix（合成 xx）は「未知の prefix（registry 未登録）」へ倒れる。
#   非vacuity: 既定 map に foreign entry を足す mutant では xx が解決して "未知の prefix 'xx'" が消え RED、
#   allowlist entry を落とす mutant では該当 prefix が "未知" 化し canonical 解決 assert が RED。
# ==============================================================================
@test "(B11) 既定 map（env 未供給）は allowlist orch/sc/ccs のみを canonical project へ解決し foreign prefix を registry 未登録へ倒す" {
    # ORCH_NUDGE_PREFIX_MAP を export しない＝DEFAULT_PREFIX_MAP を exercise する。
    export BD_SCAN_JSON='[{"id":"orch-1","title":"g"},{"id":"sc-1","title":"g"},{"id":"ccs-1","title":"g"},{"id":"xx-1","title":"g"}]'
    export TMUX_WINDOWS=""            # live 窓なし＝mapped prefix は「admin を建てて grill」notice（project 名を含む）へ倒れる
    run_nudge
    [ "$status" -eq 0 ]
    # allowlist prefix が canonical project 名へ解決している（既定 map の内容 pin）。
    [[ "$output" == *"orch-spawn-admin orchestrator で"* ]]
    [[ "$output" == *"orch-spawn-admin scribe で"* ]]
    [[ "$output" == *"orch-spawn-admin cc-session で"* ]]
    # foreign prefix は既定 map に無く registry 未登録へ倒れる（allowlist が閉じている証明）。
    [[ "$output" == *"未知の prefix 'xx'"* ]]
    # allowlist prefix は「未知」扱いにならない（解決されている＝閉じた map が allowlist を含む）。
    [[ "$output" != *"未知の prefix 'orch'"* ]]
    [[ "$output" != *"未知の prefix 'sc'"* ]]
    [[ "$output" != *"未知の prefix 'ccs'"* ]]
}

# ==============================================================================
# (B9) bash -n（構文）が通る
# ==============================================================================
@test "(B9) bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

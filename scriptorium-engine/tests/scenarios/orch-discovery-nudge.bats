#!/usr/bin/env bats
# tests/scenarios/orch-discovery-nudge.bats
#
# orch-discovery-nudge.sh（orch-s8c courier nudge / orch-3d4 Step B 横断 silent-failure 対策 /
#   orch-b52a 二役分離）の決定的テスト。
#
# 方式: bd / tmux / session-comm を env スタブで差し替え、self-scope 用 fake ledger（.beads dolt_database=orch）
#   から実 script を実行する hermetic E2E。実 dolt / tmux / inject を一切使わない（selftest-orch-s8c の durable 版）。
#   - bd          : ORCH_NUDGE_BD で差替（list -l needs-grill --json で $BD_SCAN_JSON を返す）。
#   - tmux        : ORCH_NUDGE_TMUX で差替（list-windows -a -F → $TMUX_WINDOWS の行を出す＝window 存在の制御）。
#   - session-comm: ORCH_NUDGE_SESSION_COMM で差替（argv を $SC_ARGS_FILE に、notice 本文を $SC_BODY_FILE に
#                   記録 + $SC_RC で exit code 注入）。
#   - prefix map  : ORCH_NUDGE_PREFIX_MAP="tu=testproj" で hermetic 化（既定 map 変更から decouple）。
#                   ★fixture は **prefix≠registry**（tu≠testproj）を必ず保つ。value==prefix の縮退 fixture
#                   （tu=tu 等）は二役分離が無検証になる（discriminator 破壊）ため禁止。
#   ★ambient 汚染回避: setup で ORCH_NUDGE_PREFIX_MAP を unset する（orchestrator 実環境では供給 seam
#     が本 env を export しうる＝既定 map teeth の false-green を機械排除）。
#
# 検証する契約不変条件（top-spec §5.2 横断 (a)(b) + bd orch-3d4 Step B + bd orch-b52a = ratify 済契約）:
#   (B1) 配送 cmd は必ず --confirm-receipt / --wait を含む（送達 read-back を無効化させない）。
#   (B2) session-comm が exit 4（受理未確認）を返したら failure に数え非 0 終了（silent success にしない＝twill 教訓）。
#   (B3) 配送安全 flag 秒が非正整数なら起動時 die（fail-closed＝confirm-receipt を黙って無効化させない）。
#   (B4) session-comm が exit 0（確認済）なら injected・exit 0。
#   (B5) self-scope: 非 orch 台帳からは何もせず非 0（foreign 誤 scan 防止 fail-closed）。
#   (B6) needs-grill 無は no-op で exit 0。
#   (B7) --dry-run: 配送予定 cmd に --confirm-receipt を含むが session-comm を実行しない。
#   (B8) live window 不在は人間 notice を print し session-comm を呼ばない（exit 0）。
#   (B9) bash -n（構文）が通る。
#   (B10) topology orch-riz1: 宛先は session:window 正準形で一意到達する（bare-name 退行封鎖）。
#   (B11) engine seam: 既定 prefix map は allowlist（orch/sc/ccs）のみ＝private 配備層の連結先を持たない。
#   ── orch-b52a（二役分離: addressing=台帳短名(prefix) / notice=registry(map 値)）──
#   (B11c) coupled: 1 run 内で (α) inject 宛先=<prefix>:admin かつ map 値 addressing 不在、
#         (β) 窓不在 bead の human notice=orch-spawn-admin <registry 名> を両方 assert（両側の非空虚は
#         (B11-MUT-A)/(B11-MUT-B) の mutant が担保）。
#   (B12) decouple: map 未収録 prefix でも live 窓が在れば inject する / 窓不在なら registry 名を捏造しない。
#   (B13) production DEFAULT_PREFIX_MAP: 値は registry 名（notice 経路）で、addressing は台帳短名。
#   (B14) 自 prefix orch は addressing 対象外（自台帳 2 人目 admin の footgun 誘導を増やさない）。
#   (B15) DESIGN-PIN static fence（DONE gate grep 0 hit / addressing 実装形）。
#   (B16) doc drift: script header が「registry 名 addressing」へ逆行していない。
#   (B18e) DEFAULT_PREFIX_MAP 厳密 3-entry 集合 pin（private 4th entry 再混入を封じる静的 fence・
#          B11 の closure は exactness を証明しないため PR#129 B18〔12-entry pin〕の engine 代替として置く）。
#
# 実行: bats tests/scenarios/orch-discovery-nudge.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-discovery-nudge.sh"
    TEST_TMPDIR=$(mktemp -d -t orch-nudge-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    # ambient 汚染排除（供給 seam が export しうる＝(B13)/(B14) の既定 map teeth を守る）。
    unset ORCH_NUDGE_PREFIX_MAP

    # self-scope 用 fake ledger（dolt_database=orch）。cwd をここにして script を走らせる。
    LEDGER="$TEST_TMPDIR/orch-ledger"
    mkdir -p "$LEDGER/.beads"
    printf '{"dolt_database":"orch"}\n' > "$LEDGER/.beads/metadata.json"

    # session-comm の呼び出し argv / notice 本文の記録先（空＝未呼出を assert できる）。
    export SC_ARGS_FILE="$TEST_TMPDIR/sc-args.txt"
    export SC_BODY_FILE="$TEST_TMPDIR/sc-body.txt"
    : > "$SC_ARGS_FILE"
    : > "$SC_BODY_FILE"

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

    # ── stub: session-comm（argv 記録 + notice 本文記録 + SC_RC で exit code 注入＝exit 4 等の未確認を模倣）──
    cat > "$BIN/session-comm-stub" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SC_ARGS_FILE"
# inject-file <window> <notice-file> …: notice 本文も控える（orch-b52a の非捏造 assert 用）。
if [ "${1:-}" = "inject-file" ] && [ -f "${3:-}" ]; then
    cat "$3" >> "${SC_BODY_FILE:-/dev/null}"
fi
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

# 共有 lib を symlink した sandbox に mutant copy を置いて起動する（mutation 非空虚用・orch-b52a）。
#   $1=sed 式（残りは script 引数）。実 script は BASH_SOURCE 相対で hooks/lib/orch_session.sh を source する
#   ため、sandbox に hooks を symlink する（実 lib をそのまま使う＝mutant は本 script のみ）。
run_mutant() {  # $1=sed-expr [args...]
    local expr="$1"; shift
    local sb="$TEST_TMPDIR/mut-$RANDOM"
    mkdir -p "$sb"
    ln -s "$REPO/scripts/hooks" "$sb/hooks"
    sed "$expr" "$SCRIPT" > "$sb/orch-discovery-nudge.sh"
    run bash -c "cd \"$LEDGER\" && exec bash \"$sb/orch-discovery-nudge.sh\" \"\$@\"" -- "$@"
}

# 否定 assert を **位置非依存**にする helper（self-review fix・orch-b52a）。
#   bash/bats(1.13) の set -e は「`!` で戻り値を反転された command」を errexit 免除する（実測）。ゆえに
#   `! cmd` を test の**途中**に書くと違反しても test は緑のまま＝空虚 teeth になる（末尾行だけは bats が
#   最終 status を見るので効く）。本 helper は関数戻り値で失敗させるため mid-test でも正しく RED になる。
#   `run` を使わない＝先行 assert が参照する $output / $status を壊さない。
refute() {  # $@ = 成功してはならないコマンド
    if "$@" >/dev/null 2>&1; then
        printf 'refute: expected failure but command succeeded: %s\n' "$*" >&2
        return 1
    fi
    return 0
}

# ==============================================================================
# (B1) 配送 cmd は必ず --confirm-receipt / --wait を含む
# ==============================================================================
@test "(B1) 配送 cmd は必ず --confirm-receipt と --wait を含む（送達 read-back を無効化させない）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="tu:admin"        # addressing=台帳短名（bead id prefix）・orch-b52a 二役分離
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
    export TMUX_WINDOWS="tu:admin"        # addressing=台帳短名（orch-b52a）
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
    export TMUX_WINDOWS="tu:admin"        # addressing=台帳短名（orch-b52a）
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
    export TMUX_WINDOWS="tu:admin"        # addressing=台帳短名（orch-b52a）
    : > "$SC_ARGS_FILE"
    run_nudge --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"--confirm-receipt"* ]]
    [[ "$output" == *"tu:admin"* ]]           # 配送予定の宛先も短名（map 値 addressing でない）
    [ ! -s "$SC_ARGS_FILE" ]                  # session-comm は一度も呼ばれない
}

# ==============================================================================
# (B8) live window 不在は人間 notice を print し session-comm を呼ばない
#      （notice は registry 名＝map 値を使う＝役②は不変）
# ==============================================================================
@test "(B8) live window 不在は人間 notice を print し session-comm を呼ばない（exit 0）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS=""                     # tu:admin 不在
    : > "$SC_ARGS_FILE"
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"NOTICE"* ]]
    [[ "$output" == *"orch-spawn-admin testproj"* ]]
    [ ! -s "$SC_ARGS_FILE" ]                  # 人間 notice 路では session-comm を呼ばない
}

# ==============================================================================
# (B10) topology orch-riz1: session:window 正準形 `<台帳短名>:admin` で一意到達 + 正準形 inject
# ==============================================================================
@test "(B10a) 正準形 inject: live admin を検知したら session-comm の宛先は <台帳短名>:admin（旧 bare admin-<project> でも map 値でもない）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="tu:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    grep -qF 'tu:admin' "$SC_ARGS_FILE"              # 宛先正準形で inject（透過の非vacuity）
    refute grep -qF 'admin-tu' "$SC_ARGS_FILE"       # 旧 bare 形は使わない（bare-name 退行封鎖）
    ! grep -qF 'testproj:admin' "$SC_ARGS_FILE"      # map 値を addressing に使わない（orch-b52a 二役分離）
}

@test "(B10b) 一意到達: 2 session が共に素 admin 窓を持っても <台帳短名>:admin で狙った側だけへ inject する（session 修飾で曖昧回避）" {
    # 素 admin 窓（window 名=admin）が 2 session（ax / tu）に併存する。session 名=台帳短名が識別を担うため
    #   宛先 `tu:admin`（bead id prefix）で ax 側に触れず一意到達する。bare-name 退行 mutation（format を
    #   `#{window_name}` に戻す）では両窓が `admin` に潰れ target `tu:admin` 不一致→NOTICE→injected=0 で RED。
    #   fixture は prefix(tu)≠registry(tb) を維持する（map 値 addressing の退行も同時に封じる）。
    export ORCH_NUDGE_PREFIX_MAP="tu=tb"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="ax:admin tu:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    grep -qF 'tu:admin' "$SC_ARGS_FILE"               # 狙った側へ到達
    refute grep -qF 'ax:admin' "$SC_ARGS_FILE"        # 別 session の同名窓には触れない
    refute grep -qF 'admin-tu' "$SC_ARGS_FILE"        # 旧 bare 形は使わない
    ! grep -qF 'tb:admin' "$SC_ARGS_FILE"             # map 値（registry 名）を addressing に使わない
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
# (B18e) DEFAULT_PREFIX_MAP 厳密 3-entry 集合 pin（private 再混入封鎖・fence leak-check #2）
#   PUBLIC engine の既定 map は {orch=orchestrator, sc=scribe, ccs=cc-session} の厳密 3-entry である。
#   B11 は closure（未知 prefix→registry 未登録）のみを証明し exactness を証明しない＝4 個目の private
#   entry を焼き込んでも B11 は全 GREEN を通す（fail-open）。本 teeth は naive re-sync（byte-copy）による
#   private 名の再焼き込み——まさに sc-qqms surgical port が防ぐ失敗様式——を封じる静的回帰ガード。
#   PR#129 の唯一の件数 pin だった B18（12-entry）は非移植ゆえ、engine 適正な 3-entry pin へここで置換する。
# ==============================================================================
@test "(B18e) DEFAULT_PREFIX_MAP は allowlist 3-entry 厳密一致（private 再混入封鎖）" {
    # DEFAULT_PREFIX_MAP=( ... ) の中身（"prefix=registry" 行）だけを抽出する。
    local block
    block="$(awk '/^DEFAULT_PREFIX_MAP=\(/{f=1;next} f&&/^\)/{f=0} f{print}' "$SCRIPT")"
    # 件数=3（entry 行のみ数える＝空行/コメントを除外）。4th private entry の混入をここで検知する。
    local count
    count="$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*"[^"]+"[[:space:]]*$')"
    [ "$count" -eq 3 ]
    # entry 完全一致（cs=/cm= 等の部分一致 false-positive を避け行全体で判定＝fence leak-check 注記どおり）。
    #   件数=3 かつ下記 3 entry が各々在る ⇒ 集合は厳密に {orch,sc,ccs}（4 個目の余地なし・否定で表現）。
    printf '%s\n' "$block" | grep -qE '^[[:space:]]*"orch=orchestrator"[[:space:]]*$'
    printf '%s\n' "$block" | grep -qE '^[[:space:]]*"sc=scribe"[[:space:]]*$'
    printf '%s\n' "$block" | grep -qE '^[[:space:]]*"ccs=cc-session"[[:space:]]*$'
}

# ==============================================================================
# (B11c) 二役分離 coupled teeth（orch-b52a）: 1 run 内で addressing=短名 / notice=registry を両方 pin
#   fixture は prefix≠registry を 2 組（tu=testproj / ww=widgetproj）保つ。窓は tu 側のみ live。
# ==============================================================================
@test "(B11c) coupled: 同一 run で (α) inject 宛先=<短名> かつ map 値不使用、(β) 窓不在 bead の notice=registry 名" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj ww=widgetproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"live 窓あり"},{"id":"ww-1","title":"窓なし"}]'
    export TMUX_WINDOWS="tu:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    [[ "$output" == *"noticed=1"* ]]
    # (α) addressing は台帳短名（map 値は宛先に現れない）
    grep -qF 'tu:admin' "$SC_ARGS_FILE"
    refute grep -qF 'testproj:admin' "$SC_ARGS_FILE"
    # (β) human notice は registry 名（短名を orch-spawn-admin 引数にしない）
    [[ "$output" == *"orch-spawn-admin widgetproj"* ]]
    [[ "$output" != *"orch-spawn-admin ww "* ]]
}

@test "(B11-BODY) notice 本文も二役分離: mapped case は project=registry 名 / 宛先表記=<短名>:admin（registry 流用なし）" {
    # mandate ■doc scope の「_write_notice の (%s:admin) 表記も prefix へ分離（registry 流用を残さない）」の teeth。
    #   B12a は unmapped case（registry 未登録）の本文しか見ないため、mapped case の本文は無防備だった（self-review minor）。
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="tu:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    grep -qF 'project : testproj (tu:admin)' "$SC_BODY_FILE"   # 役②=registry 名 / 役①=短名 が同一行で分離
    refute grep -qF 'testproj:admin' "$SC_BODY_FILE"           # 宛先表記へ registry 名を流用しない
    grep -qF 'この testproj admin セッション' "$SC_BODY_FILE"   # 本文の呼びかけは registry 名（人間可読側）
    refute grep -qF 'registry 未登録' "$SC_BODY_FILE"          # mapped case で未登録扱いへ倒れない
}

@test "(B11-BODY-MUT) mutation 非空虚: 宛先表記を registry 名へ戻すと (B11-BODY) が RED になる" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="tu:admin"
    export SC_RC=0
    # _write_notice の mapped 枝を旧形（(%s:admin) に project を流用）へ差し戻す。
    run_mutant "s|printf 'project : %s (%s:admin)\\\\n' \"\\\$project\" \"\\\$prefix\"|printf 'project : %s (%s:admin)\\\\n' \"\\\$project\" \"\\\$project\"|"
    [ "$status" -eq 0 ]
    grep -qF 'testproj:admin' "$SC_BODY_FILE"                  # mutant では registry 流用が復活する
    refute grep -qF 'project : testproj (tu:admin)' "$SC_BODY_FILE"
}

@test "(B11-MUT-A) mutation 非空虚: addressing を map 値（registry 名）へ戻すと (α) が RED になる" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj ww=widgetproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"live 窓あり"},{"id":"ww-1","title":"窓なし"}]'
    export TMUX_WINDOWS="tu:admin"
    export SC_RC=0
    run_mutant 's|^    window="[^"]*"|    window="$project:admin"|'
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=0"* ]]         # 旧実装（registry addressing）では live 窓 tu:admin に届かない
    ! grep -qF 'tu:admin' "$SC_ARGS_FILE"     # (α) の grep が RED になる＝teeth は load-bearing
}

@test "(B11-MUT-B) mutation 非空虚: human notice を短名（prefix）へ変えると (β) が RED になる" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj ww=widgetproj"
    export BD_SCAN_JSON='[{"id":"tu-1","title":"live 窓あり"},{"id":"ww-1","title":"窓なし"}]'
    export TMUX_WINDOWS="tu:admin"
    export SC_RC=0
    run_mutant 's|orch-spawn-admin [$]project|orch-spawn-admin $prefix|'
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-spawn-admin ww "* ]]              # 短名が registry 名の位置に出る
    [[ "$output" != *"orch-spawn-admin widgetproj"* ]]       # (β) の assert が RED になる
}

# ==============================================================================
# (B12) decouple teeth（orch-b52a 設計裁定）: addressing は map membership に依存しない
# ==============================================================================
@test "(B12a) map 未登録 prefix でも live <短名>:admin が在れば inject する（map coverage の穴で呼び鈴を殺さない）" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"   # zz は未登録
    export BD_SCAN_JSON='[{"id":"zz-1","title":"未登録 prefix"}]'
    export TMUX_WINDOWS="zz:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    grep -qF 'zz:admin' "$SC_ARGS_FILE"
    # notice 本文は registry 名を捏造しない（未登録と明示する）
    grep -qF 'registry 未登録' "$SC_BODY_FILE"
    ! grep -qF 'testproj' "$SC_BODY_FILE"
}

@test "(B12b) map 未登録 prefix で窓も不在なら registry 名を捏造しない fallback notice へ倒れる" {
    export ORCH_NUDGE_PREFIX_MAP="tu=testproj"
    export BD_SCAN_JSON='[{"id":"zz-1","title":"未登録 prefix"}]'
    export TMUX_WINDOWS=""
    : > "$SC_ARGS_FILE"
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"noticed=1"* ]]
    [[ "$output" == *"registry 未登録"* ]]
    [[ "$output" == *"'zz'"* ]]
    [[ "$output" != *"orch-spawn-admin zz "* ]]   # 短名を registry 名として渡させない
    [ ! -s "$SC_ARGS_FILE" ]
}

# ==============================================================================
# (B13) production DEFAULT_PREFIX_MAP（override せず既定 map を使う経路）
# ==============================================================================
@test "(B13a) 既定 map の値は registry 名（notice 経路）: sc-* の窓不在 notice は orch-spawn-admin scribe" {
    export BD_SCAN_JSON='[{"id":"sc-1","title":"grill 待ち"}]'   # ORCH_NUDGE_PREFIX_MAP は setup で unset
    export TMUX_WINDOWS=""
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-spawn-admin scribe"* ]]
    ! printf '%s\n' "$output" | grep -qE 'orch-spawn-admin sc[[:space:]]'   # 短名は引数にしない
}

@test "(B13b) 既定 map 経路でも addressing は台帳短名: sc-* は sc:admin へ inject（scribe:admin でない）" {
    export BD_SCAN_JSON='[{"id":"sc-1","title":"grill 待ち"}]'
    export TMUX_WINDOWS="sc:admin"
    export SC_RC=0
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"injected=1"* ]]
    grep -qF 'sc:admin' "$SC_ARGS_FILE"
    ! grep -qF 'scribe:admin' "$SC_ARGS_FILE"
}

# ==============================================================================
# (B14) 自 prefix orch は addressing 対象外（自台帳 2 人目 admin の footgun 誘導を増やさない）
# ==============================================================================
@test "(B14) orch- bead は live orch:admin が在っても inject せず人間 notice へ倒れる" {
    export BD_SCAN_JSON='[{"id":"orch-1","title":"自台帳の grill 待ち"}]'
    export TMUX_WINDOWS="orch:admin"
    : > "$SC_ARGS_FILE"
    run_nudge
    [ "$status" -eq 0 ]
    [[ "$output" == *"noticed=1"* ]]
    [[ "$output" == *"injected=0"* ]]
    [[ "$output" == *"orch-spawn-admin orchestrator"* ]]
    [ ! -s "$SC_ARGS_FILE" ]                  # 自台帳へは inject しない
}

# ==============================================================================
# (B15) DESIGN-PIN static fence（orch-b52a DONE gate）
# ==============================================================================
@test "(B15) DESIGN-PIN: addressing は id prefix 直参照・台帳 runtime 解決や registry addressing を持ち込まない" {
    # DONE gate（bd orch-b52a）: addressing 目的の台帳 runtime 解決 / registry runtime addressing は 0 hit。
    #   （scriptorium 原版は private registry lib 名も alternation していたが、engine には該当 lib が無く
    #     public source へ private 名を焼かない方針〔sc-qqms surgical port〕ゆえ generic guard のみ残す。）
    refute grep -nE '_ledger_dolt_database.*project|_SELF_LEDGER_DB' "$SCRIPT"
    grep -qF 'window="$prefix:admin"' "$SCRIPT"      # 役① = bead id prefix（台帳短名）
    ! grep -qF 'window="$project:admin"' "$SCRIPT"   # 役② の値を addressing に使わない
}

# ==============================================================================
# (B16) doc drift: script header が「registry 名 addressing」へ逆行していない
#   engine には CLAUDE.md が無いため（scriptorium 版の CLAUDE.md 参照 2 本は非移植）、script header の
#   二役分離 landed 文字列 pin のみを残す（orch-b52a・sc-qqms surgical port の engine 版 rewrite）。
# ==============================================================================
@test "(B16) doc drift teeth: script header が二役分離の landed 状態を述べている" {
    # header: 二役分離の key 語が在る / 旧移行注記（未 land・admin-<project> 形）は残っていない。
    grep -qF 'addressing=台帳短名(prefix) / notice=registry(map 値)' "$SCRIPT"
    refute grep -qF 'admin-<project>' "$SCRIPT"
    refute grep -qF '本便では land しない' "$SCRIPT"
}

# ==============================================================================
# (B9) bash -n（構文）が通る
# ==============================================================================
@test "(B9) bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

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
#   (H) status 集合（bd orch-1dcd・dispatch 後の空集合化 fix / engine 同期 bd sc-xy9n）: 活動中 slate は
#       **`bd list --help` の 5 値のうち非 closed の 4 値**（open / in_progress / blocked / deferred）で列挙する
#       （`bd statuses` の built-in は pinned / hooked を含む実 7 値ゆえ**全非 closed ではない**＝lib header の
#       既知限界）。in_progress slate（dispatch→worker --claim 後）は surface / interlock の双方で生存し、
#       status だけを closed に変えた対は双方で除外される（over-permit と under-permit を同一 fixture 対で
#       同時に RED 化）。mutation 非空虚（lib copy を open 固定へ戻すと surface 側・interlock 側の両方が
#       RED flip）／stub 自身の非空虚（status-blind stub では mutation が緑のまま＝空虚）／bd argv pin
#       （--status は高々 1 回・完全一致・--limit 0 在り・--all 非出現）／status token 実在性／status リテラルは
#       コード中 1 箇所（surface と interlock が同一 filter を共有する構造 pin）／lib header の doc pin
#       （採用集合・既知限界・2 コピー同期義務 + **本便が同期したのは status filter のみ**という残存 drift の明記＝
#       members 抽出の行頭 sentinel アンカー〔bd orch-3d07〕は本 copy 未同期で、散文が sentinel を行内引用した行の
#       members: を harvest する over-permit が生きている）。
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
    # ★status-aware（bd orch-1dcd）: 実 bd の `--status <csv>` filter を模し、指定 status の行のみ返す。
    #   status を無視する stub は「open 固定 query でも in_progress slate が返る」偽環境を作り、本 filter の
    #   teeth も mutation も空虚化する（status-blind stub では未修正コードでも緑・(H-stub-nonvacuous) が pin）。
    #   契約: --status/-s の csv を行 status で filter／未指定は実 bd 既定＝closed 以外／status field を持たない
    #   fixture 行は open 扱い（既存 fixture 互換）／flag repeat は最後の値のみ（実 bd の silently-overwrite）／
    #   未知 status token は rc=1（実 bd と同じ）。show は id 指定 read ゆえ status filter しない。
    #   KNOWN は `bd statuses` の built-in **実 7 値**（pinned / hooked 込み・実 bd 照会 verified 2026-07-25）で
    #   `bd list --help` の 5 値ではない＝(a) 未知 token 判定を実 bd と同義にし (b) 将来 filter へ pinned / hooked を
    #   足したとき stub が rc=1 で正しい拡張を封鎖する逆流を消す。
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_FILE"
[ -n "${BD_FAIL:-}" ] && exit 1
while [ "${1:-}" = "-C" ] || [ "${1:-}" = "--directory" ]; do shift 2; done
_status=""; _prev=""
for _a in "$@"; do
  case "$_prev" in --status|-s) _status="$_a" ;; esac   # repeat は最後の値のみ採用
  _prev="$_a"
done
sub="${1:-}"; shift 2>/dev/null || true
case "$sub" in
  list)
    case " $* " in
      *" --label slate "*|*" -l slate "*) _src="${SLATE_LIST_JSON:-[]}" ;;
      *)                                   _src="${BD_LIST_JSON:-[]}" ;;
    esac
    if [ -n "${BD_STUB_STATUS_BLIND:-}" ]; then       # (H-stub-nonvacuous) 用の status-blind 退行モード
      printf '%s' "$_src"; exit 0
    fi
    ORCH_SLATE_STUB_STATUS="$_status" python3 - "$_src" <<'PY'
import json, os, sys
KNOWN = {"open", "in_progress", "blocked", "deferred", "closed", "pinned", "hooked"}  # bd statuses 実 7 値
raw = os.environ.get("ORCH_SLATE_STUB_STATUS", "")
if raw:
    allowed = {t for t in raw.split(",") if t}
    bad = allowed - KNOWN
    if bad:
        sys.stderr.write("stub bd: unknown status: %s\n" % ",".join(sorted(bad)))
        sys.exit(1)
else:
    allowed = KNOWN - {"closed"}          # 実 bd 既定＝closed 以外
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.stdout.write("[]"); sys.exit(0)
rows = data if isinstance(data, list) else []
out = [r for r in rows if (not isinstance(r, dict)) or r.get("status", "open") in allowed]
sys.stdout.write(json.dumps(out))
PY
    exit $? ;;
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

# ==============================================================================
# (G) --surface read-only mode（bd orch-cqf4 Leg-A・open slate 列挙）
# ==============================================================================

# 実 orch_slate.sh を --surface（standalone read-only）で走らせる。bd/anchor は env seam で hermetic 注入。
run_surface() {
    PATH="$BIN:$PATH" \
    ORCH_SLATE_BD="$BIN/bd" \
    ORCH_SLATE_ANCHOR="$ANCHOR" \
        run bash "$SLATE_LIB" --surface
}

@test "(G-present) --surface: open slate と members を列挙し tripwire 集計（members を実読＝非空虚）" {
    run_surface
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SLATE] orch-slate1"* ]]
    [[ "$output" == *"members: orch-test, tb"* ]]                # members を実読（読まなければ union:0 に落ちる）
    [[ "$output" == *"[SLATE-TRIPWIRE] open slate:1 members(union):2"* ]]
}

@test "(G-none) --surface: open slate 無し → [SLATE-NONE]・tripwire open slate:0" {
    export SLATE_LIST_JSON='[]'
    run_surface
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SLATE-NONE]"* ]]
    [[ "$output" == *"[SLATE-TRIPWIRE] open slate:0 members(union):0"* ]]
}

@test "(G-readfail) --surface: bd read 失敗 → [SLATE-UNKNOWN]・fail-open exit 0（brick しない）" {
    export BD_FAIL=1
    run_surface
    [ "$status" -eq 0 ]                              # read-only surfacing は brick しない（fail-open）
    [[ "$output" == *"[SLATE-UNKNOWN]"* ]]
}

@test "(G-foreign) --surface: foreign copy（非 orch-）は open slate 列挙から排除（schema SSOT 再利用）" {
    export SLATE_LIST_JSON='[{"id":"un-slate9"},{"id":"orch-slate1"}]'
    run_surface
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SLATE] orch-slate1"* ]]
    [[ "$output" != *"un-slate9"* ]]                # foreign filter（_orch_slate_open_ids の SELF_PREFIX）
    [[ "$output" == *"[SLATE-TRIPWIRE] open slate:1 "* ]]
}

@test "(G-readonly) --surface: bd 呼出は list/show のみ（write verb 非出現＝surfacing 専任）" {
    run_surface
    [ -f "$BD_ARGS_FILE" ]
    ! grep -qE '(^| )(update|create|close|dep|assign|delete|import|dolt) ' "$BD_ARGS_FILE" || false
    ! grep -qE -- '--add-label|--append-notes' "$BD_ARGS_FILE"
}

@test "(G-anchor-fallback) --surface: ORCH_SLATE_ANCHOR 未指定→engine は fail-loud で [SLATE-UNKNOWN]・exit0（hardcode fallback 無し）" {
    # 人間/hook が env seam 無しで叩く standalone --surface。engine は deploy-layout hardcode fallback を持たず、
    #   同 dir の orch_anchor.sh を lazy source して _resolve_scriptorium を試みる（E2 検証付き）。engine hermetic
    #   環境（scriptorium deploy-layout 非在）では anchor 解決不能ゆえ [SLATE-UNKNOWN] fail-loud を stderr へ出し
    #   exit 0（read-only surfacing は brick しないが、誤った hardcode anchor を黙って使わない＝F2b scrub の帰結）。
    #   ※ scriptorium 本体では _resolve_scriptorium が解決し SLATE header へ到達するが、engine copy は fail-loud 構造。
    PATH="$BIN:$PATH" ORCH_SLATE_BD="$BIN/bd" \
        run bash "$SLATE_LIB" --surface
    [ "$status" -eq 0 ]                              # fail-loud でも brick しない（read-only surfacing・exit0）
    [[ "$output" == *"[SLATE-UNKNOWN]"* ]]           # anchor 解決不能を fail-loud で surface（hardcode しない）
    [[ "$output" == *"anchor 解決不能"* ]]
}

# ==============================================================================
# (H) status 集合 = 活動中 slate（bd orch-1dcd・dispatch 後の空集合化 fix / engine 同期 bd sc-xy9n）
# ==============================================================================
#
# 背景（実測 2026-07-25）: 契約 bead 自身に slate を焼いて dispatch すると、worker cell の `--claim` で
#   slate bead が in_progress へ遷移し、`--status open` 固定 query から外れて members 和集合が空になり、
#   以降の dispatch/spawn が全て fail-closed 拒否された（bundle の自殺）。surface path と interlock path が
#   同じ blind を共有していた（二重 blind）。fix は「`bd list --help` 5 値のうち非 closed の 4 値を明示列挙」
#   （pinned / hooked は列挙外＝同型 brick が latent に残る・採否は follow-up。lib header の 既知限界 が SSOT）。
# engine 側の意味（bd sc-xy9n）: SessionStart 第5節の slate surface は **engine copy 単独**が担う boot path
#   ゆえ、engine が status-blind のままだと「interlock は通るが人間には見えない」非対称が deployment に残る。
#   本節は engine copy でも同一意味論が成立することを機械 pin する。

# 実 lib を copy して status filter を **open 固定へ戻した mutant** を sandbox に作る（原本は触らない＝
#   in-place sed 禁止・失敗時に mutant が worktree へ残らない）。consumer 経路の mutant も同 sandbox で成立
#   させるため scripts/lib 一式 + scripts/hooks/lib を実 copy する（symlink だと mutant を混ぜられない）。
# $1=sandbox dir。戻り値: mutant lib は "$1/lib/orch_slate.sh"。
make_mut_sandbox() {
    local sb="$1"
    mkdir -p "$sb/lib" "$sb/hooks/lib"
    cp "$REPO_ROOT/scripts/lib/"*.sh "$sb/lib/"
    cp "$REPO_ROOT/scripts/hooks/lib/orch_session.sh" "$sb/hooks/lib/orch_session.sh"
    # 非空虚の前提: 原本に新リテラルが在り、mutant からは消えている。
    grep -q -- '--status open,in_progress,blocked,deferred' "$SLATE_LIB"
    sed 's/--status open,in_progress,blocked,deferred/--status open/' \
        "$SLATE_LIB" > "$sb/lib/orch_slate.sh"
    ! grep -q -- '--status open,in_progress,blocked,deferred' "$sb/lib/orch_slate.sh" || false
    grep -q -- '--status open --limit 0' "$sb/lib/orch_slate.sh"
    chmod +x "$sb/lib/orch_slate.sh"
}

# lib 関数を直接呼ぶ runner（source して helper を叩く・direct-exec 分岐は通らない）。
run_members() {
    local lib="${1:-$SLATE_LIB}"
    PATH="$BIN:$PATH" run bash -c '. "$1"; _orch_slate_open_members "$2" "$3"' _ "$lib" "$BIN/bd" "$ANCHOR"
}

# --- (H-alive) in_progress slate は生存（surface / interlock / members の 3 点）-------------------

@test "(H-alive-members) in_progress slate: _orch_slate_open_members が members を返す（open 固定なら空）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    run_members
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-test"* ]]
    [[ "$output" == *"tb"* ]]
}

@test "(H-alive-surface) in_progress slate: --surface が [SLATE] 行を出す（tripwire も計上）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    run_surface
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SLATE] orch-slate1"* ]]
    [[ "$output" == *"members: orch-test, tb"* ]]
    [[ "$output" == *"[SLATE-TRIPWIRE] open slate:1 members(union):2"* ]]
    [[ "$output" != *"[SLATE-NONE]"* ]]
}

@test "(H-alive-dispatch) in_progress slate: dispatch interlock が pass（dispatch 後の bundle 自殺が解消）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    run_dispatch_gate --dry-run orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]
}

@test "(H-alive-admin) in_progress slate: spawn-admin interlock が pass（target project 照合）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    run_admin_gate tb --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]] || [[ "$output" == *"would spawn"* ]]
}

# --- (H-closed) 除外の対: members 同一・status だけ closed（over-permit の RED 化）----------------

@test "(H-closed-surface) closed slate: --surface は [SLATE-NONE]・tripwire 0（bundle 完了後は消える）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"closed"}]'
    run_surface
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SLATE-NONE]"* ]]
    [[ "$output" == *"[SLATE-TRIPWIRE] open slate:0 members(union):0"* ]]
    [[ "$output" != *"[SLATE] orch-slate1"* ]]
}

@test "(H-closed-members) closed slate: members 和集合は空（closed 混入の over-permit を封鎖）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"closed"}]'
    run_members
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(H-closed-dispatch) closed slate: dispatch は fail-closed 拒否（旧 slate は interlock を通さない）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"closed"}]'
    run_dispatch_gate --dry-run orch-test
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "(H-closed-admin) closed slate: spawn-admin も fail-closed 拒否（両 consumer 対称）" {
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"closed"}]'
    run_admin_gate tb --dry-run
    [ "$status" -ne 0 ]
}

# --- (H-mut) mutation 非空虚: open 固定へ戻すと surface 側・interlock 側の両方が RED flip -----------

@test "(H-mut-surface) mutation: lib copy を --status open 固定へ戻すと in_progress slate が surface から消える" {
    local sb="$TEST_TMPDIR/mut-status"; make_mut_sandbox "$sb"
    local before; before="$(sha256sum "$SLATE_LIB" | cut -d' ' -f1)"
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    # 原本: surface する（(H-alive-surface) と同条件）。
    run_surface
    [[ "$output" == *"[SLATE] orch-slate1"* ]]
    # mutant: open 固定ゆえ status-aware stub が in_progress 行を返さず [SLATE-NONE] へ落ちる（RED flip）。
    PATH="$BIN:$PATH" ORCH_SLATE_BD="$BIN/bd" ORCH_SLATE_ANCHOR="$ANCHOR" \
        run bash "$sb/lib/orch_slate.sh" --surface
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SLATE-NONE]"* ]]
    [[ "$output" != *"[SLATE] orch-slate1"* ]]
    # 原本は書き換えていない（in-place sed 禁止の teeth）。
    [ "$(sha256sum "$SLATE_LIB" | cut -d' ' -f1)" = "$before" ]
}

@test "(H-mut-interlock) mutation: open 固定 mutant lib を source する dispatch / spawn-admin が in_progress slate を reject" {
    local sb="$TEST_TMPDIR/mut-status-consumer"; make_mut_sandbox "$sb"
    local before; before="$(sha256sum "$SLATE_LIB" | cut -d' ' -f1)"
    cp "$SCRIPT_DISPATCH" "$sb/orch-dispatch.sh"
    cp "$SCRIPT_ADMIN" "$sb/orch-spawn-admin.sh"
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    # dispatch: 原本は pass（(H-alive-dispatch)）／mutant は members 空で fail-closed 拒否（RED flip）。
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
    ORCH_DISPATCH_SCRIPTORIUM="$ANCHOR" \
    ORCH_DISPATCH_BD="$BIN/bd" \
    ORCH_DISPATCH_BDW="$BIN/bdw-stub" \
    ORCH_DISPATCH_SKIP_SLATE_GATE=0 \
    ORCH_DISPATCH_POLL_INTERVAL=0 \
    BD_SHOW_JSON="$VALID_BEAD_JSON" \
        run bash "$sb/orch-dispatch.sh" --dry-run orch-test
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
    # spawn-admin: 同じく mutant は reject（interlock path も同一 filter を共有する＝非対称が無い）。
    PATH="$BIN:$PATH" \
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" \
    ORCH_ADMIN_PROJECTS="tb=$TBDIR" \
    ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE=0 \
    ORCH_SPAWN_ADMIN_BD="$BIN/bd" \
    ORCH_SPAWN_ADMIN_SCRIPTORIUM="$ANCHOR" \
    ORCH_SPAWN_ADMIN_SESSION_STATE="$BIN/session-state-stub" \
    ORCH_SPAWN_ADMIN_VERIFY_SETTLE=0 \
        run bash "$sb/orch-spawn-admin.sh" tb --dry-run
    [ "$status" -ne 0 ]
    [ "$(sha256sum "$SLATE_LIB" | cut -d' ' -f1)" = "$before" ]
}

@test "(H-stub-nonvacuous) stub 自身の非空虚: status-blind stub へ戻すと mutation が緑のまま（teeth が空虚化する）" {
    # ★この case が守るもの: bd stub が --status を解釈しないと「open 固定 mutant でも in_progress slate が
    #   返る」偽環境になり、(H-mut-*) の RED flip が起きず mutation teeth 全体が空虚になる。
    local sb="$TEST_TMPDIR/mut-stub"; make_mut_sandbox "$sb"
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    # status-aware stub（正）: mutant は [SLATE-NONE]＝flip する。
    PATH="$BIN:$PATH" ORCH_SLATE_BD="$BIN/bd" ORCH_SLATE_ANCHOR="$ANCHOR" \
        run bash "$sb/lib/orch_slate.sh" --surface
    [[ "$output" == *"[SLATE-NONE]"* ]]
    # status-blind stub（退行）: mutant でも slate が surface され flip しない＝teeth が何も主張しなくなる。
    PATH="$BIN:$PATH" ORCH_SLATE_BD="$BIN/bd" ORCH_SLATE_ANCHOR="$ANCHOR" BD_STUB_STATUS_BLIND=1 \
        run bash "$sb/lib/orch_slate.sh" --surface
    [[ "$output" == *"[SLATE] orch-slate1"* ]]
    [[ "$output" != *"[SLATE-NONE]"* ]]
}

# --- (H-argv/token/single) query 形の機械 pin ----------------------------------------------------

@test "(H-argv) bd argv pin: --status は高々 1 回・完全一致 csv・--limit 0 在り・--all 非出現" {
    run_surface
    [ "$status" -eq 0 ]
    [ -f "$BD_ARGS_FILE" ]
    # 完全一致（`--status open` の部分一致で false-pass しないよう csv 全体を assert）。
    grep -q -- '--status open,in_progress,blocked,deferred' "$BD_ARGS_FILE"
    ! grep -qE -- '--status open( |$)' "$BD_ARGS_FILE" || false
    # 禁止形: 同じ flag の 2 回渡し（bd は silently overwrite し先の値が消える）。
    ! grep -qE -- '--status .*--status' "$BD_ARGS_FILE" || false
    ! grep -qE -- '(--status|-s) .*(--status|-s) ' "$BD_ARGS_FILE" || false
    # 截断禁止（bd list 既定 limit 50 で活動中 slate が silent に落ちるのを封じる）。
    grep -q -- '--limit 0' "$BD_ARGS_FILE"
    # 全件取得 + reader 側 closed 落としは禁止形。
    ! grep -q -- '--all' "$BD_ARGS_FILE" || false
}

@test "(H-token) status token 実在性: lib のリテラルが bd の実 status 集合に属す（hermetic）" {
    local lit
    lit="$(grep -o -- '--status [A-Za-z_,]*' "$SLATE_LIB" | sed 's/^--status //')"
    [ -n "$lit" ]
    [ "$(printf '%s\n' "$lit" | grep -c .)" -eq 1 ]     # リテラルは 1 箇所（(H-single-filter) と対）
    # 許容集合は `bd statuses` の built-in **実 7 値**（pinned / hooked 込み・実 bd 照会 verified 2026-07-25）。
    #   `bd list --help` の 5 値ではない。実集合に揃えないと、将来 filter へ pinned / hooked を足す
    #   **正しい拡張**が「unknown status token」で FAIL し teeth が正解を封鎖する（逆流）。
    #   なお本 case は literal ⊆ 実集合の一方向しか主張しない＝「非 closed を全網羅しているか」は
    #   主張しない（pinned / hooked 非採用は lib header の 既知限界＝follow-up）。
    # ★engine 側の意図的差分（bd sc-xy9n）: 配備層 local copy の同名 case は「実 bd + 実 anchor へ read-only
    #   list を 1 回投げる presence-skip smoke」を併せ持つが engine copy は持たない。engine bats は
    #   「実 bd / 実 spawn / network を一切叩かない」hermetic 契約（本 file 冒頭 方式 節）で、engine は任意
    #   ホストで走る PUBLIC 配布物ゆえ実 bd 依存 case は常時 LOUD-SKIP のノイズかホスト依存 FAIL に化ける。
    #   リテラルが実 bd に受理される receipt は配備層側 residual bats が担う（header の責務分割と同型）。
    local tok
    for tok in ${lit//,/ }; do
        case "$tok" in
            open|in_progress|blocked|deferred|closed|pinned|hooked) : ;;
            *) echo "unknown status token: $tok" >&2; false ;;
        esac
    done
    [[ "$lit" != *"closed"* ]] || [[ "$lit" == *"in_progress"* ]]   # closed 単独指定でない
}

@test "(H-single-filter) status リテラルはコード中 1 箇所（surface と interlock が同一 filter を共有する構造 pin）" {
    [ "$(grep -c -- '--status open,in_progress,blocked,deferred' "$SLATE_LIB")" -eq 1 ]
    # 旧 open 固定形が残っていない（部分一致で緑にならないよう query 行の形で assert）。
    ! grep -qE -- 'list --label .* --status open( |$)' "$SLATE_LIB" || false
}

# --- (H-libheader) 新しい意味論の doc pin（engine は lib header が SSOT・docs-land は配備層側）--------

@test "(H-libheader) lib header が採用 status 集合・既知限界・2 コピー同期義務・残存 drift を明記（engine 固有 doc pin）" {
    grep -q 'open,in_progress,blocked,deferred' "$SLATE_LIB"
    grep -q 'orch-1dcd' "$SLATE_LIB"
    grep -q '既知限界' "$SLATE_LIB"
    # pinned / hooked が列挙外＝全非 closed ではない、という限界の明示（false な「全非 closed」主張を封じる）。
    grep -q 'pinned' "$SLATE_LIB"
    grep -q 'hooked' "$SLATE_LIB"
    # engine 固有: boot path 側 copy であることと 2 コピー同期義務（本 drift の再発防止 doc）。
    grep -q '2 コピー同期義務' "$SLATE_LIB"
    grep -q 'session-start-workinprogress.sh' "$SLATE_LIB"
    # ★残存 drift の明示（本便で同期したのは status filter のみ）: members 抽出の行頭 sentinel アンカー
    #   （bd orch-3d07）は本 copy 未同期で、散文が sentinel を **行内引用** した行の members: を harvest する
    #   over-permit（fail-open）が生きている。この 2 語が header から消えたら RED＝「2 コピー同期義務」だけを
    #   読んだ後続 agent が parity 達成と誤読する形へ戻すことを封じる（drift 解消便では doc と本 pin を同便で畳む）。
    grep -q 'orch-3d07' "$SLATE_LIB"
    grep -q '行内引用' "$SLATE_LIB"
    # 既存 pin は消えていない（意味論更新で旧 pin を壊さない）。
    grep -q 'ORCH-SLATE v1' "$SLATE_LIB"
    grep -q '1 slate=1 bundle' "$SLATE_LIB"
}

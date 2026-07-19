#!/usr/bin/env bash
# orch-hydrate-gate.sh — staleness-gated wrapper for orch-hydrate.sh（systemd user timer 用・orch-7ute）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   systemd user timer（orch-hydrate.timer・OnCalendar=*:0/30・Persistent=true）が周期起動する
#   ExecStart 実体。timer は「起動間隔」を刻むだけで、実 sync を毎回打つかは本 gate が
#   .beads/last-sync（sync 専用鮮度マーカー）の age で判定する:
#     age >= THRESHOLD_MIN（既定 25 分）→ orch-hydrate.sh を起動（＝bdw flock 直列化経由で bd repo sync）。
#     age <  THRESHOLD_MIN               → skip（last-sync に一切触れない）。
#   gate の主目的は load 削減でなく **Persistent catch-up の重複 de-dup**（host 復帰後に溜まった
#   missed run が短時間に連続発火しても、last-sync が fresh なら 2 回目以降を skip する）。
#   sync 自体は実測 13.1s（8 repo・2026-07-14 計測）で trivial ゆえ THRESHOLD は小さく取ってよい。
#
# staleness measure の semantic（fence-gate-semantics・最重要） ─────────────────────
#   (a) 判定に使う age は backstop（orch-dispatch --gate-pending / workinprogress 第1節）と **同一の**
#       .beads/last-sync（sync 専用マーカー）の mtime age。export-state.json（any-write proxy）/任意 DB
#       mtime/新規 heartbeat marker は使わない（orch-dispatch.sh:568-620 の freshness-soundness と同型）。
#   (b) gate は last-sync を **一切 stamp しない**（skip でも run でも touch しない）。stamp は sync 成功
#       直後の orch-hydrate.sh:353-361 の成功枝のみが行う＝「last-sync == 最後の成功 sync 時刻」semantic を
#       壊さない。gate が skip 時に stamp すると「sync してないのに fresh」の false-green を生む（禁止）。
#   (c) backstop の参照先（last-sync）は差し替えない。本 gate は last-sync を read のみ（age 算出）。
#   marker 不在/読取不可 = 「最後の成功 sync の証跡なし」→ **stale 扱いで sync する**（fail-safe＝
#   unknown を古い側に倒す。skip して silent に古いままにしない）。
#
# 実効不変条件（fence-invariant） ───────────────────────────────────────────────
#   docs 明文化する不変条件は period 単独でなく **実効最大 staleness**:
#       実効最大 staleness ≈ THRESHOLD_MIN + PERIOD_MIN  <  ORCH_DISPATCH_SYNC_STALE_MIN（60 分）
#   （worst case: age が THRESHOLD 直下で 1 回 skip → 次の周期まで PERIOD 分老化 → sync 直前で
#   ≈ THRESHOLD+PERIOD。これが backstop の警告閾値 60 分を超えると恒常 stale-warn＝真の異常の信号品質が
#   壊れる）。既定 25+30=55 < 60 ✓。THRESHOLD=30 は境界に接し jitter で spurious 化しうる・
#   THRESHOLD=60 揃えは max≈90 分で恒常誤警告＝誤り。本 gate は起動時に THRESHOLD+PERIOD >= STALE_LIMIT を
#   検出したら **loud 警告**して継続する（sync は安全側ゆえ止めない・fail-safe）。
#
# 実 sync 経路（fence-invariant・single-writer 衝突防止） ──────────────────────────
#   実 sync 起動は必ず orch-hydrate.sh（内部で同梱 bdw の flock で orchestrator write と直列化）。
#   生 `bd repo sync` で flock を迂回しない（並行 orchestrator write との lost-update 防止）。
#
# flock headroom + >60s tripwire（fence-flock） ─────────────────────────────────
#   bd repo sync は bdw WRITE path で直列化・実測 13.1s < BDW_LOCK_TIMEOUT 60s ゆえ現状は ~13s 待ちで成功＝
#   契約の「60s 超なら分割/loud retry」は不発（余裕 ≒47s）。将来 registered repo 増で 60s に接近すると
#   fail-closed が始まるため、本 gate は orch-hydrate.sh の wall-clock を実測し DURATION_WARN_SEC（既定 60）を
#   超えたら **loud tripwire** を出す（分割/loud retry 再検討の signal）。>60s 分岐は live コード＝self-test は
#   hydrate を stub して duration を実注入し tripwire 点灯/非点灯を非空虚に検証する。
#
# 前提（fence-workdir・fence-path） ────────────────────────────────────────────
#   private 配備層の scheduler が anchor（main checkout）ディレクトリを WorkingDirectory に設定して起動する
#   前提。orch-hydrate.sh:226 の self-scope gate は cwd 台帳 dolt_database==orch を要求し、cwd が台帳外だと
#   silent refuse（no-op）になるため。marker 既定も $PWD 起点（anchor）で orch-hydrate.sh の SYNC_MARKER 既定と
#   一致する。.service は Environment=PATH に %h/.local/bin を含める（bd は ~/.local/bin・systemd user 既定 PATH に無い）。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）  gate 判定 → run なら orch-hydrate.sh 起動 / skip なら何もしない。
#   --dry-run gate 判定と実行予定のみ print（orch-hydrate.sh を呼ばない・last-sync も触らない＝hermetic）。
#   --self-test  bats 非依存の内蔵 hermetic 検証（fail-closed＝assert 1 つでも落ちたら非0）。
#   --help    使い方。
#
# env override（主に hermetic self-test / bats 用）────────────────────────────────
#   ORCH_HYDRATE_GATE_MARKER          staleness measure marker（既定: $PWD/.beads/last-sync）。fence-gate-semantics(a)。
#   ORCH_HYDRATE_GATE_THRESHOLD_MIN   sync を打つ age 閾値（分・既定 25）。
#   ORCH_HYDRATE_GATE_PERIOD_MIN      timer 周期（分・既定 30・実効 staleness 不変条件の算出に使う）。
#   ORCH_HYDRATE_GATE_STALE_LIMIT_MIN backstop 警告閾値 ORCH_DISPATCH_SYNC_STALE_MIN の写し（分・既定 60）。
#   ORCH_HYDRATE_GATE_HYDRATE         orch-hydrate.sh 実体パス（既定: 本 script と同 dir の orch-hydrate.sh）。
#   ORCH_HYDRATE_GATE_DURATION_WARN_SEC  hydrate wall-clock の tripwire 閾値（秒・既定 60）。
#   ORCH_HYDRATE_GATE_NOW             現在時刻 epoch を注入（既定: date +%s）。self-test で age を決定論化。
#
# 検証: tests/scenarios/orch-hydrate-gate.bats（hermetic E2E）＋ 本 script --self-test。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

THRESHOLD_MIN="${ORCH_HYDRATE_GATE_THRESHOLD_MIN:-25}"
PERIOD_MIN="${ORCH_HYDRATE_GATE_PERIOD_MIN:-30}"
STALE_LIMIT_MIN="${ORCH_HYDRATE_GATE_STALE_LIMIT_MIN:-60}"
DURATION_WARN_SEC="${ORCH_HYDRATE_GATE_DURATION_WARN_SEC:-60}"
HYDRATE="${ORCH_HYDRATE_GATE_HYDRATE:-$SELF_DIR/orch-hydrate.sh}"

DRY_RUN=false
SELF_TEST=false
case "${1:-}" in
    --dry-run)   DRY_RUN=true ;;
    --self-test) SELF_TEST=true ;;
    --help|-h)
        sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0 ;;
    "" ) : ;;
    * )  echo "orch-hydrate-gate: 未知の引数: $1（--dry-run / --self-test / --help のみ）" >&2; exit 2 ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# --self-test: bats 非依存の内蔵 hermetic 検証（fail-closed＝assert 1 つでも落ちたら非0）
#   temp fixture に last-sync marker と stub orch-hydrate を組み、以下の modality を検証する:
#     [inv]  実効不変条件 THRESHOLD+PERIOD<STALE_LIMIT を assert（既定 25+30=55<60）＋ 誤設定で
#            GATE-INVARIANT-WARN が点灯する非空虚（40+30=70>=60）。
#     [a]    measure は last-sync mtime を使う（marker を fresh に touch → skip / 古く → sync）。
#     [b]    skip 枝で marker mtime が **不変**（gate は stamp しない）／sync 枝は stub が stamp（gate 非関与）。
#     [c]    unknown（marker 不在）→ sync（fail-safe）。
#     [dur+] hydrate を sleep stub で duration 実注入し、DURATION_WARN_SEC 低→tripwire 点灯／高→非点灯（非空虚）。
#     [route] sync 経路は orch-hydrate.sh（stub）を呼ぶ＝生 bd repo sync を叩かない。
# ─────────────────────────────────────────────────────────────────────────────
run_self_test() {
    local tmp fails=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/orch-hydrate-gate-selftest.XXXXXX")" || { echo "self-test: mktemp 失敗" >&2; return 1; }
    trap 'rm -rf "$tmp"' RETURN
    local self="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
    local marker="$tmp/last-sync"
    local hyd="$tmp/orch-hydrate.sh"
    local hyd_ran="$tmp/hyd-ran"

    # stub orch-hydrate: 呼ばれたら hyd_ran に touch（呼出証跡）＋ marker を stamp（成功 sync の模擬）。
    #   SLEEP env で wall-clock を注入（tripwire modality）。EXIT_RC env で rc を注入（sync 失敗伝播 modality）。
    cat > "$hyd" <<STUB
#!/usr/bin/env bash
touch "$hyd_ran"
[ -n "\${SLEEP:-}" ] && sleep "\$SLEEP"
printf 'stamped\n' > "$marker"
exit "\${EXIT_RC:-0}"
STUB
    chmod +x "$hyd"

    local now=1000000000   # 決定論 epoch

    _run() { # 追加 env は呼出側で export。gate を subprocess で回し stdout+stderr を捕捉。
        ORCH_HYDRATE_GATE_MARKER="$marker" \
        ORCH_HYDRATE_GATE_HYDRATE="$hyd" \
        ORCH_HYDRATE_GATE_NOW="$now" \
        bash "$self" "$@" 2>&1
    }
    _assert() { # $1=cond(0/1) $2=name
        if [ "$1" -eq 0 ]; then echo "  ok: $2"; else echo "  FAIL: $2" >&2; fails=$((fails+1)); fi
    }

    # [inv] 既定不変条件が満たされ、誤設定で警告点灯 ────────────────────────────
    local out
    printf 'x\n' > "$marker"; touch -d "@$(( now - 60*60 ))" "$marker"   # 60 分前（sync 側）
    out="$(_run --dry-run)"
    _assert "$([ "$(( 25 + 30 ))" -lt 60 ] && echo 0 || echo 1)" "[inv] 既定 25+30<60"
    printf '%s' "$out" | grep -q 'GATE-INVARIANT-WARN' && _assert 1 "[inv] 既定で警告非点灯" || _assert 0 "[inv] 既定で警告非点灯"
    out="$(ORCH_HYDRATE_GATE_THRESHOLD_MIN=40 _run --dry-run)"
    printf '%s' "$out" | grep -q 'GATE-INVARIANT-WARN' && _assert 0 "[inv] 40+30>=60 で警告点灯（非空虚）" || _assert 1 "[inv] 40+30>=60 で警告点灯（非空虚）"

    # [a][b] marker fresh → skip・mtime 不変 ────────────────────────────────
    printf 'x\n' > "$marker"; touch -d "@$(( now - 5*60 ))" "$marker"   # 5 分前（fresh）
    rm -f "$hyd_ran"
    local mt_before mt_after
    mt_before="$(stat -c %Y "$marker")"
    out="$(_run)"
    mt_after="$(stat -c %Y "$marker")"
    printf '%s' "$out" | grep -q 'GATE-SKIP' && _assert 0 "[a] fresh(5分)→skip" || _assert 1 "[a] fresh(5分)→skip"
    _assert "$([ "$mt_before" = "$mt_after" ] && echo 0 || echo 1)" "[b] skip 枝で marker mtime 不変（gate 非 stamp）"
    _assert "$([ ! -f "$hyd_ran" ] && echo 0 || echo 1)" "[b] skip 枝で orch-hydrate を呼ばない"

    # [a] marker 古い → sync・orch-hydrate 呼出 ──────────────────────────────
    printf 'x\n' > "$marker"; touch -d "@$(( now - 40*60 ))" "$marker"   # 40 分前（stale）
    rm -f "$hyd_ran"
    out="$(_run)"
    printf '%s' "$out" | grep -q 'GATE-SYNC-DONE' && _assert 0 "[a] stale(40分)→sync" || _assert 1 "[a] stale(40分)→sync"
    _assert "$([ -f "$hyd_ran" ] && echo 0 || echo 1)" "[route] sync は orch-hydrate.sh(stub)を呼ぶ"

    # [c] marker 不在 → sync（fail-safe）─────────────────────────────────────
    rm -f "$marker" "$hyd_ran"
    out="$(_run)"
    printf '%s' "$out" | grep -q 'GATE-SYNC-DONE' && _assert 0 "[c] marker 不在→sync（fail-safe）" || _assert 1 "[c] marker 不在→sync（fail-safe）"

    # [dur+] duration tripwire: sleep 1 の hydrate を DURATION_WARN_SEC=0（点灯）/=3600（非点灯）─────
    printf 'x\n' > "$marker"; touch -d "@$(( now - 40*60 ))" "$marker"
    out="$(SLEEP=1 ORCH_HYDRATE_GATE_DURATION_WARN_SEC=0 _run)"
    printf '%s' "$out" | grep -q 'GATE-DURATION-TRIPWIRE' && _assert 0 "[dur+] 実測>閾値0→tripwire 点灯" || _assert 1 "[dur+] 実測>閾値0→tripwire 点灯"
    printf 'x\n' > "$marker"; touch -d "@$(( now - 40*60 ))" "$marker"
    out="$(SLEEP=1 ORCH_HYDRATE_GATE_DURATION_WARN_SEC=3600 _run)"
    printf '%s' "$out" | grep -q 'GATE-DURATION-TRIPWIRE' && _assert 1 "[dur+] 実測<閾値3600→tripwire 非点灯（非空虚）" || _assert 0 "[dur+] 実測<閾値3600→tripwire 非点灯（非空虚）"

    # [rc] sync 失敗（hydrate rc≠0）を gate が伝播する（rc=1 出力 + 非0 exit＝service failed 伝播）────
    #   _run は HYDRATE を hyd に固定するため env を直書きして gate を走らせ $? を捕捉する。
    #   ★非0 exit を捕捉するため `&& rc=0 || rc=$?` パターン（`out=$()` 直代入は set -e で発火する）。
    local rc
    printf 'x\n' > "$marker"; touch -d "@$(( now - 40*60 ))" "$marker"
    out="$(EXIT_RC=1 ORCH_HYDRATE_GATE_MARKER="$marker" ORCH_HYDRATE_GATE_HYDRATE="$hyd" ORCH_HYDRATE_GATE_NOW="$now" bash "$self" 2>&1)" && rc=0 || rc=$?
    printf '%s' "$out" | grep -q 'rc=1' && _assert 0 "[rc] sync 失敗 rc=1 を出力" || _assert 1 "[rc] sync 失敗 rc=1 を出力"
    _assert "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "[rc] sync 失敗で gate が非0 exit（service failed 伝播）"

    # [fail] HYDRATE 非実行可 → GATE-FAIL・非0（fail-closed＝silent skip しない）─────────
    printf 'x\n' > "$marker"; touch -d "@$(( now - 40*60 ))" "$marker"
    out="$(ORCH_HYDRATE_GATE_MARKER="$marker" ORCH_HYDRATE_GATE_HYDRATE="$tmp/nonexistent-hydrate" ORCH_HYDRATE_GATE_NOW="$now" bash "$self" 2>&1)" && rc=0 || rc=$?
    printf '%s' "$out" | grep -q 'GATE-FAIL' && _assert 0 "[fail] HYDRATE 非実行可→GATE-FAIL" || _assert 1 "[fail] HYDRATE 非実行可→GATE-FAIL"
    _assert "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "[fail] HYDRATE 非実行可→非0 exit（fail-closed）"

    if [ "$fails" -eq 0 ]; then echo "self-test: ALL PASS"; return 0; else echo "self-test: $fails FAIL" >&2; return 1; fi
}

if [ "$SELF_TEST" = true ]; then
    run_self_test
    exit $?
fi

# ── 実効不変条件チェック（fence-invariant・runtime loud 化）─────────────────────
# THRESHOLD+PERIOD >= STALE_LIMIT だと実効 staleness が backstop 警告閾値を超え恒常誤警告になる。
# sync 自体は安全ゆえ止めず loud 警告して継続する（fail-safe）。整数でない env は既定へ縮退。
_is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }
for _v in THRESHOLD_MIN PERIOD_MIN STALE_LIMIT_MIN DURATION_WARN_SEC; do
    if ! _is_int "${!_v}"; then
        echo "orch-hydrate-gate: warn: $_v が非整数（${!_v}）→既定へ縮退" >&2
        case "$_v" in
            THRESHOLD_MIN) THRESHOLD_MIN=25 ;;
            PERIOD_MIN) PERIOD_MIN=30 ;;
            STALE_LIMIT_MIN) STALE_LIMIT_MIN=60 ;;
            DURATION_WARN_SEC) DURATION_WARN_SEC=60 ;;
        esac
    fi
done
EFFECTIVE_MAX=$(( THRESHOLD_MIN + PERIOD_MIN ))
if [ "$EFFECTIVE_MAX" -ge "$STALE_LIMIT_MIN" ]; then
    echo "GATE-INVARIANT-WARN: 実効最大 staleness ≈ THRESHOLD($THRESHOLD_MIN)+PERIOD($PERIOD_MIN)=$EFFECTIVE_MAX 分 >= STALE_LIMIT($STALE_LIMIT_MIN 分)。" >&2
    echo "  backstop（orch-dispatch --gate-pending）が恒常 stale-warn になり真の異常の信号品質が壊れる。THRESHOLD+PERIOD < $STALE_LIMIT_MIN を満たすよう調整せよ。" >&2
fi

# ── staleness measure（fence-gate-semantics(a)・read-only）──────────────────────
MARKER="${ORCH_HYDRATE_GATE_MARKER:-$PWD/.beads/last-sync}"
NOW="${ORCH_HYDRATE_GATE_NOW:-$(date +%s 2>/dev/null)}"

# age_min を算出。marker 不在/読取不可/時刻不能 → "unknown"（＝stale 扱いで sync する fail-safe）。
_compute_age_min() {
    AGE_MIN="unknown"
    if [ ! -f "$MARKER" ]; then return 0; fi
    local mtime
    mtime="$(stat -c %Y "$MARKER" 2>/dev/null)" || return 0
    _is_int "$mtime" || return 0
    _is_int "$NOW" || return 0
    local age_sec=$(( NOW - mtime ))
    [ "$age_sec" -lt 0 ] && age_sec=0   # clock skew（未来 mtime）→ fresh 側へ丸める
    AGE_MIN=$(( age_sec / 60 ))
}
_compute_age_min

# ── 判定 ────────────────────────────────────────────────────────────────────
DECISION="skip"
if [ "$AGE_MIN" = "unknown" ]; then
    DECISION="sync"; REASON="last-sync 不在/読取不可＝成功 sync の証跡なし（fail-safe で sync）"
elif [ "$AGE_MIN" -ge "$THRESHOLD_MIN" ]; then
    DECISION="sync"; REASON="age=${AGE_MIN}分 >= THRESHOLD=${THRESHOLD_MIN}分"
else
    DECISION="skip"; REASON="age=${AGE_MIN}分 < THRESHOLD=${THRESHOLD_MIN}分（fresh・de-dup skip）"
fi

echo "GATE: marker=$MARKER age=${AGE_MIN} THRESHOLD=${THRESHOLD_MIN}分 PERIOD=${PERIOD_MIN}分 → decision=$DECISION（$REASON）"

if [ "$DECISION" = "skip" ]; then
    # fence-gate-semantics(b): skip 時は last-sync を一切 touch しない（stamp は orch-hydrate 成功枝のみ）。
    echo "GATE-SKIP: sync を打たない（last-sync は touch しない）"
    exit 0
fi

# ── sync（fence-invariant: 必ず orch-hydrate.sh 経由＝bdw flock 直列化）─────────────
if [ "$DRY_RUN" = true ]; then
    echo "DRY-RUN: would exec: $HYDRATE   # bdw flock 直列化経由で hydrate（stamp は hydrate の成功枝のみ）"
    exit 0
fi

if [ ! -x "$HYDRATE" ]; then
    echo "GATE-FAIL: orch-hydrate.sh が実行可能でない: $HYDRATE" >&2
    exit 1
fi

_start="$(date +%s 2>/dev/null || echo 0)"
set +e
"$HYDRATE"
_rc=$?
set -e
_end="$(date +%s 2>/dev/null || echo 0)"
_elapsed=$(( _end - _start ))
[ "$_elapsed" -lt 0 ] && _elapsed=0

# fence-flock: wall-clock が DURATION_WARN_SEC を超えたら tripwire（>60s 分岐は live）。
if [ "$_elapsed" -gt "$DURATION_WARN_SEC" ]; then
    echo "GATE-DURATION-TRIPWIRE: orch-hydrate 実行 ${_elapsed}s > ${DURATION_WARN_SEC}s。" >&2
    echo "  registered repo 増で bdw flock（BDW_LOCK_TIMEOUT 60s）に接近＝分割/loud retry を再検討せよ（fence-flock tripwire）。" >&2
fi

echo "GATE-SYNC-DONE: orch-hydrate rc=$_rc elapsed=${_elapsed}s"
exit "$_rc"

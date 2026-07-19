#!/usr/bin/env bats
# tests/scenarios/orch-rebrief.bats
#
# /scriptorium:orch-rebrief の機械層 fetch engine（scripts/orch-rebrief-fetch.sh・bd orch-noio・旧 orch-resume-fetch.sh）の
#   hybrid bats。本 script は **薄 overlay shim**（generic core を scribe canonical scribe-rebrief-fetch.sh へ委譲し、
#   orchestrator 固有 compose〔STALE / gate-pending / GATE〕を overlay で足す）。
#
# **hybrid 方式（bd orch-noio 裁定・HIGH hermetic seam）**:
#   (i) overlay 契約（self-scope gate / env seam 翻訳 / marker passthrough / overlay compose / envelope / fail-loud）は
#       **stub canonical**（ORCH_RESUME_REBRIEF_FETCH で差替・固定 rebrief DATA emit）で hermetic pin する
#       ＝実 canonical・実 cc-session lib に**依存しない**（skip 偽 green を作らない）。
#   (ii) 実 canonical との意味論一致（orphan sibling 反転〔orch-d73a 回帰〕/ DIFF-DRIFT）は
#       **presence-skip 付き smoke**（実 canonical / cc-lib 不到達=skip・pass と偽らない）。
#
# 検証する契約不変条件:
#   (passthrough) stub canonical の rebrief DATA を envelope 内へ通す。
#   (xlate)       ORCH_RESUME_* → SCRIBE_REBRIEF_* 翻訳（anchor/sid/wm_dir/bd/lib/marker）。SCRIPTORIUM→ANCHOR。
#   (overlay)     [STALE] / [GATE-PENDING] count+list / [GATE] を compose（各 mutation 非空虚）。
#   (envelope)    overlay compose は footer の内側・footer は 1 個（案B）。
#   (gate)        self-scope：foreign cwd → no-op（DATA 非出力・exit0）。SKIP=1 で bypass。
#   (mode)        auto-compact marker 翻訳：marker 有→force-recovery / 無→normal（stub canonical が翻訳 marker を読む）。
#   (fail-loud)   canonical 非実行可能 → rc≠0 + FATAL（偽全クリアなし）。
#   (fail-closed) resolver 不在（共有 lib 無い isolated copy）→ rc1（clean-state-probe 同型）。
#   (anchor-loud) anchor 解決不能（ORCH_RESUME_SCRIPTORIUM/ORCH_ANCHOR/ORCH_ANCHOR_CONFIG 全未供給）→ rc≠0 + fail-loud
#                 （engine は deploy-layout hardcode fallback を持たず解決不能を die させる）。
#   (ro)          read-only：実行後に WM dir の内容が不変。
#   (self)        本体 --self-test green。
#   (syntax)      bash -n。
#   (smoke)       実 canonical：orphan sibling 反転（sidDONE.md+.consumed.md 併存でも surface）+ mutation + DIFF-DRIFT。
#
# private 配備層の docs/systemd drift teeth は配備層側 residual bats が担う（engine copy は mechanism teeth のみ）。
#
# 実行: bats tests/scenarios/orch-rebrief.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-rebrief-fetch.sh"
    REAL_CANON="$HOME/.claude/plugins/scribe/scripts/scribe-rebrief-fetch.sh"
    CC_LIB="$HOME/.claude/plugins/session/scripts/lib"

    TEST_TMPDIR="$(mktemp -d -t orch-rebrief-bats-XXXXXX)"
    ANCHOR="$TEST_TMPDIR/anchor"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$ANCHOR/.beads";  printf '{"dolt_database":"orch"}' > "$ANCHOR/.beads/metadata.json"
    mkdir -p "$FOREIGN/.beads"; printf '{"dolt_database":"un"}'   > "$FOREIGN/.beads/metadata.json"
    WMDIR="$ANCHOR/.claude-session"; mkdir -p "$WMDIR"
    CUR="sidCUR"
    FAKELIB="$TEST_TMPDIR/fake-lib"

    # stub bd: gate-pending に orch-gp1 / closed に orch-aaa / list に orch-bbb（in_progress）。
    BDSTUB="$TEST_TMPDIR/bd-stub.sh"
    cat > "$BDSTUB" <<'BDEOF'
#!/usr/bin/env bash
case "$*" in
  *"--label gate-pending"*) echo '[{"id":"orch-gp1","status":"open"}]' ;;
  *"--status closed"*)      echo '[{"id":"orch-aaa","status":"closed"}]' ;;
  *"list"*)                 echo '[{"id":"orch-bbb","status":"in_progress"}]' ;;
  *)                        echo '[]' ;;
esac
BDEOF
    chmod +x "$BDSTUB"

    # stub canonical: 受領 SCRIBE_REBRIEF_* を echo しつつ rebrief 系 envelope の固定 DATA を emit。
    # auto-compact marker 翻訳を検証するため、SCRIBE_REBRIEF_AUTOCOMPACT_MARKER の実在で mode を決める。
    CANONSTUB="$TEST_TMPDIR/canon-stub.sh"
    cat > "$CANONSTUB" <<'CANEOF'
#!/usr/bin/env bash
mode=normal
[ -n "${SCRIBE_REBRIEF_AUTOCOMPACT_MARKER:-}" ] && [ -e "$SCRIBE_REBRIEF_AUTOCOMPACT_MARKER" ] && mode=force-recovery
echo "=== [scribe-rebrief-fetch] rebrief DATA (stub) ==="
echo "[REBRIEF-MODE] $mode"
echo "[ANCHOR] ${SCRIBE_REBRIEF_ANCHOR:-<none>}"
echo "[LEDGER] orch"
echo "[SID] ${SCRIBE_REBRIEF_SID:-<none>}"
echo "[XLATE] WM_DIR=${SCRIBE_REBRIEF_WM_DIR:-<none>} BD=${SCRIBE_REBRIEF_BD:-<none>} LIB=${SCRIBE_REBRIEF_SESSION_LIB:-<none>} MARKER=${SCRIBE_REBRIEF_AUTOCOMPACT_MARKER:-<none>}"
echo "[BD-COUNT] open=1 in_progress=1 blocked=0"
echo "[DIFF-NONE] 乖離なし"
echo "[ORPHAN-NONE] orphan WM なし"
echo "=== end rebrief DATA ==="
CANEOF
    chmod +x "$CANONSTUB"

    # stub probe: GREEN。stub stale: 整数 3。
    PROBESTUB="$TEST_TMPDIR/probe-stub.sh"
    printf '#!/usr/bin/env bash\necho "STUB-PROBE GREEN"\nexit 0\n' > "$PROBESTUB"; chmod +x "$PROBESTUB"
    STALESTUB="$TEST_TMPDIR/stale-int.sh"
    printf '#!/usr/bin/env bash\necho 3\nexit 0\n' > "$STALESTUB"; chmod +x "$STALESTUB"

    # WM fixture（current sid）: orch-aaa を in_progress と主張（bd=closed ゆえ drift・実 canonical smoke 用）。
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] orch-aaa を in_progress で継続実装
WMEOF
    printf 'x\n' > "$WMDIR/working-memory.sidORPHAN.md"                  # orphan（sibling 無）
    printf 'x\n' > "$WMDIR/working-memory.sidDONE.md"                    # sibling 有 → canonical は反転で surface
    printf 'x\n' > "$WMDIR/working-memory.sidDONE.consumed.md"
    printf 'x\n' > "$WMDIR/working-memory.sidARCH.archived-superseded"   # 非標準 suffix → 非検出
    MARKER="$TEST_TMPDIR/marker"   # 既定は不在（normal）
}

teardown() { [ -n "${TEST_TMPDIR:-}" ] && rm -rf "$TEST_TMPDIR"; }

require_real_canonical() {
    [ -x "$REAL_CANON" ] || skip "実 canonical（$REAL_CANON）不在＝実 canonical smoke を skip（post-land human smoke へ defer・pass ではない）"
    { [ -r "$CC_LIB/session-env.sh" ] && [ -r "$CC_LIB/working-memory.sh" ]; } \
        || skip "cc-session lib 不在（$CC_LIB）＝実 canonical smoke を skip（環境依存）"
}

# stub canonical で overlay を hermetic 駆動（gate SKIP・stdin 塞ぐ）。
run_fetch() {
    ORCH_RESUME_SKIP_SESSION_GATE=1 \
    ORCH_RESUME_SCRIPTORIUM="$ANCHOR" \
    ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" \
    ORCH_RESUME_BD="$BDSTUB" \
    ORCH_RESUME_PROBE="$PROBESTUB" \
    ORCH_RESUME_STALE_SCAN="$STALESTUB" \
    ORCH_RESUME_SESSION_LIB="$FAKELIB" \
    ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" \
    ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    run bash "$SCRIPT" </dev/null
}

# 実 canonical で overlay を駆動（REBRIEF_FETCH は既定＝実 canonical・cc-lib は実 lib）。
run_fetch_real() {
    ORCH_RESUME_SKIP_SESSION_GATE=1 \
    ORCH_RESUME_SCRIPTORIUM="$ANCHOR" \
    ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" \
    ORCH_RESUME_BD="$BDSTUB" \
    ORCH_RESUME_PROBE="$PROBESTUB" \
    ORCH_RESUME_STALE_SCAN="$STALESTUB" \
    ORCH_RESUME_SESSION_LIB="$CC_LIB" \
    ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    run bash "$SCRIPT" </dev/null
}

# ── (i) hermetic（stub canonical）: overlay 契約 ─────────────────────────────

@test "(passthrough) stub canonical の rebrief DATA を envelope 内へ通す" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]
    [[ "$output" == *"[REBRIEF-MODE] normal"* ]]
    [[ "$output" == *"[BD-COUNT] open=1 in_progress=1 blocked=0"* ]]
    [[ "$output" == *"[DIFF-NONE]"* ]]
    [[ "$output" == *"[ORPHAN-NONE]"* ]]
}

@test "(xlate) ORCH_RESUME_* → SCRIBE_REBRIEF_* 翻訳（anchor/sid/wm_dir/bd/lib）" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ANCHOR] $ANCHOR"* ]]
    [[ "$output" == *"[SID] $CUR"* ]]
    [[ "$output" == *"WM_DIR=$WMDIR "* ]]
    [[ "$output" == *"BD=$BDSTUB "* ]]
    [[ "$output" == *"LIB=$FAKELIB "* ]]
}

@test "(overlay) [STALE]/[GATE-PENDING] count+list/[GATE] を compose" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STALE] 停滞疑い(actionable created_at>14d)=3"* ]]
    [[ "$output" == *"[GATE-PENDING] count=1"* ]]
    [[ "$output" == *"gate-pending: orch-gp1"* ]]
    [[ "$output" == *"[GATE] GREEN"* ]]
}

@test "(overlay mutation) gate-pending bd=[] → count=0・列挙なし（非空虚）" {
    cat > "$BDSTUB" <<'BDEOF'
#!/usr/bin/env bash
echo '[]'
BDEOF
    chmod +x "$BDSTUB"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[GATE-PENDING] count=0"* ]]
    [[ "$output" != *"gate-pending: orch-gp1"* ]]
}

@test "(overlay mutation) STALE 整数→[STALE]=M / 不在→SKIP / 非整数→SKIP（0 と偽らない）" {
    run_fetch
    [[ "$output" == *"[STALE] 停滞疑い(actionable created_at>14d)=3"* ]]

    ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$PROBESTUB" \
    ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    ORCH_RESUME_STALE_SCAN="$TEST_TMPDIR/no-such-scan.sh" \
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STALE] SKIP"* ]]

    local badscan="$TEST_TMPDIR/stale-bad.sh"
    printf '#!/usr/bin/env bash\necho "oops not-a-number"\nexit 0\n' > "$badscan"; chmod +x "$badscan"
    ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$PROBESTUB" \
    ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    ORCH_RESUME_STALE_SCAN="$badscan" \
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STALE] SKIP"* ]]
    [[ "$output" != *"停滞疑い(actionable created_at>14d)=0"* ]]
}

@test "(overlay mutation) probe rc≠0 → [GATE] RED（advisory・footer は最後まで出る）" {
    local redprobe="$TEST_TMPDIR/probe-red.sh"
    printf '#!/usr/bin/env bash\necho "STUB-PROBE RED reason"\nexit 3\n' > "$redprobe"; chmod +x "$redprobe"
    ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$redprobe" \
    ORCH_RESUME_STALE_SCAN="$STALESTUB" ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" \
    ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[GATE] RED"* ]]
    [[ "$output" == *"=== end rebrief DATA ==="* ]]
}

@test "(overlay) probe 不在/非実行可能 → [GATE] SKIP" {
    ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$TEST_TMPDIR/no-such-probe.sh" \
    ORCH_RESUME_STALE_SCAN="$STALESTUB" ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" \
    ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[GATE] SKIP"* ]]
}

@test "(envelope) overlay compose は footer の内側・footer は 1 個（案B）" {
    run_fetch
    [ "$status" -eq 0 ]
    # footer 1 個。
    local nfoot; nfoot="$(printf '%s\n' "$output" | grep -cE '^=== end rebrief DATA ===$')"
    [ "$nfoot" -eq 1 ]
    # [GATE-PENDING] 行は footer より前（内側）。
    local gpline footline
    gpline="$(printf '%s\n' "$output" | grep -nE '^\[GATE-PENDING\]' | tail -n1 | cut -d: -f1)"
    footline="$(printf '%s\n' "$output" | grep -nE '^=== end rebrief DATA ===$' | tail -n1 | cut -d: -f1)"
    [ -n "$gpline" ] && [ -n "$footline" ] && [ "$gpline" -lt "$footline" ]
}

@test "(mode) auto-compact marker 有 → force-recovery / 無 → normal（marker 翻訳）" {
    run_fetch
    [[ "$output" == *"[REBRIEF-MODE] normal"* ]]
    [[ "$output" != *"[REBRIEF-MODE] force-recovery"* ]]
    : > "$MARKER"
    run_fetch
    [[ "$output" == *"[REBRIEF-MODE] force-recovery"* ]]
}

@test "(gate) self-scope: foreign cwd（dolt≠orch）→ no-op（DATA 非出力・exit0）" {
    cd "$FOREIGN"
    ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" ORCH_RESUME_SID="$CUR" \
    ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$PROBESTUB" ORCH_RESUME_STALE_SCAN="$STALESTUB" \
    ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    run bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]
    [[ "$output" == *"self-scope"* ]]
}

@test "(gate) SKIP=1 は self-scope を bypass（DATA 出力・非vacuity 対照）" {
    cd "$FOREIGN"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]
}

@test "(fail-loud) canonical 非実行可能 → rc≠0 + FATAL（偽全クリアなし）" {
    ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$PROBESTUB" \
    ORCH_RESUME_STALE_SCAN="$STALESTUB" ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    ORCH_RESUME_REBRIEF_FETCH="$TEST_TMPDIR/no-such-canonical.sh" \
    run bash "$SCRIPT" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" != *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]
}

@test "(fail-loud) canonical 実行可能だが rc≠0（partial 出力）→ rc 伝播 + FATAL（偽全クリアなし）" {
    # 別 modality（non-executable ではなく『実行されたが内部 rc≠0』）: canonical が partial DATA を stdout に吐きつつ
    # 非0 で落ちる。overlay は (a) canonical の非0 rc を propagate、(b) partial 出力を envelope+footer で包んだ
    # 偽全クリアを出さない、を pin する。stub は header だけ吐いて rc=7 で終える（footer は出さない）。
    local rcfail="$TEST_TMPDIR/canon-rcfail.sh"
    cat > "$rcfail" <<'RCEOF'
#!/usr/bin/env bash
echo "=== [scribe-rebrief-fetch] rebrief DATA (stub partial) ==="
echo "[REBRIEF-MODE] normal"
echo "canonical-internal-failure" >&2
exit 7
RCEOF
    chmod +x "$rcfail"
    ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" \
    ORCH_RESUME_SID="$CUR" ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$PROBESTUB" \
    ORCH_RESUME_STALE_SCAN="$STALESTUB" ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    ORCH_RESUME_REBRIEF_FETCH="$rcfail" \
    run bash "$SCRIPT" </dev/null
    # (a) canonical の非0 rc を propagate（`exit "$_canon_rc"`）。
    [ "$status" -eq 7 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"rc=7"* ]]
    # (b) footer 付き偽全クリアを出さない（partial DATA を envelope に畳んで exit0 にしない）。
    [[ "$output" != *"=== end rebrief DATA ==="* ]]
    # overlay compose（GATE-PENDING 等）も出さない＝partial body の後に付け足さない。
    [[ "$output" != *"[GATE-PENDING]"* ]]
}

@test "(fail-closed) resolver 不在（共有 lib 無い isolated copy）→ rc1（clean-state-probe 同型）" {
    ISO="$TEST_TMPDIR/iso"; mkdir -p "$ISO"
    cp "$SCRIPT" "$ISO/orch-rebrief-fetch.sh"
    cd "$ANCHOR"
    ORCH_RESUME_SCRIPTORIUM="$ANCHOR" ORCH_RESUME_WM_DIR="$WMDIR" ORCH_RESUME_SID="$CUR" \
    ORCH_RESUME_BD="$BDSTUB" ORCH_RESUME_PROBE="$PROBESTUB" ORCH_RESUME_STALE_SCAN="$STALESTUB" \
    ORCH_RESUME_REBRIEF_FETCH="$CANONSTUB" ORCH_RESUME_AUTOCOMPACT_MARKER="$MARKER" \
    run bash "$ISO/orch-rebrief-fetch.sh" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* && "$output" == *"resolver"* ]]
    [[ "$output" != *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]
}

@test "(ro) read-only: 実行後に WM dir の内容が不変（overlay は write しない）" {
    before="$(cd "$WMDIR" && ls -1 | sort | md5sum)"
    run_fetch
    [ "$status" -eq 0 ]
    after="$(cd "$WMDIR" && ls -1 | sort | md5sum)"
    [ "$before" = "$after" ]
}

@test "(self) 本体 --self-test が green" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(anchor-loud) anchor 解決不能（anchor env 全未供給）→ rc≠0 + fail-loud（hardcode fallback 無し）" {
    # engine は deploy-layout hardcode fallback を持たない。ORCH_RESUME_SCRIPTORIUM / ORCH_ANCHOR /
    # ORCH_ANCHOR_CONFIG を全て外し、動的導出も効かない isolated 非 git cwd から起動すると die する。
    local iso="$TEST_TMPDIR/no-anchor-cwd"; mkdir -p "$iso"
    cd "$iso"
    run env -u ORCH_RESUME_SCRIPTORIUM -u ORCH_ANCHOR -u ORCH_ANCHOR_CONFIG \
        ORCH_RESUME_SKIP_SESSION_GATE=1 bash "$SCRIPT" </dev/null
    [ "$status" -ne 0 ]
    [[ "$output" == *"anchor 解決不能"* ]]
    [[ "$output" != *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]   # 偽全クリアを出さない
}

@test "(syntax) bash -n が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

# ── (ii) 実 canonical presence-skip smoke（意味論一致・orch-d73a 回帰） ───────

@test "(smoke) 実 canonical: orphan sibling 反転（.consumed.md 併存でも surface）+ DIFF-DRIFT + rebrief marker" {
    require_real_canonical
    run_fetch_real
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== [scribe-rebrief-fetch] rebrief DATA"* ]]
    # orch-d73a 回帰: sidDONE.md は .consumed.md sibling 併存でも surface される（旧 sibling-skip の反転）。
    [[ "$output" == *"[ORPHAN-WM] working-memory.sidDONE.md"* ]]
    [[ "$output" == *"[ORPHAN-WM] working-memory.sidORPHAN.md"* ]]
    [[ "$output" != *"sidARCH"* ]]                                   # 非標準 suffix は非検出
    [[ "$output" == *"[DIFF-DRIFT] orch-aaa WM=in_progress bd=closed"* ]]
    [[ "$output" == *"[GATE-PENDING] count=1"* ]]                    # overlay compose も出る
    [[ "$output" == *"[STALE] 停滞疑い(actionable created_at>14d)=3"* ]]
}

@test "(smoke mutation) 実 canonical: sidDONE.md 除去 → sidDONE 非 surface（非空虚）" {
    require_real_canonical
    rm -f "$WMDIR/working-memory.sidDONE.md"
    run_fetch_real
    [ "$status" -eq 0 ]
    [[ "$output" != *"[ORPHAN-WM] working-memory.sidDONE.md"* ]]
    [[ "$output" == *"[ORPHAN-WM] working-memory.sidORPHAN.md"* ]]   # 他 orphan は残る
}

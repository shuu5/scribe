#!/usr/bin/env bash
# orch-rebrief-fetch.sh — /scriptorium:orch-rebrief の機械層 fetch engine（bd orch-noio・旧 orch-resume-fetch.sh の後継）
#
# 役割（clean-state-probe と同哲学＝機械=fetch / LLM=judgment）: orchestrator の resume/rebrief（startup / clear /
#   respawn 全経路共用）時に、judgment に必要な生データ（DATA）を **read-only** で fetch し、行頭 marker 付きの
#   構造化ブロックとして stdout へ emit する。judgment（brief 生成・推奨・consumed 化の実行）は skill
#   （skills/orch-rebrief/SKILL.md）が担う。
#
# **本 script は薄 overlay shim**（bd orch-noio・orch-2qzl 設計cut③・bdw/orch-8z0 cutover 同型）:
#   - generic core（(1) WM主張↔bd現在値 diff / (2) orphan WM surface / (3) auto-compact 強制回復 mode 切替判定 /
#     (4) consumed 化対象の特定）は **scribe canonical `scribe-rebrief-fetch.sh` へ委譲**する（重複実装しない＝
#     canonical が SSOT。orch-d73a 修正〔orphan の .consumed.md sibling-skip バグ是正〕も canonical 側が正）。
#   - orchestrator 固有 compose（overlay の付加価値）だけを本 script が足す＝**3 点のみ**:
#       [STALE]        created_at ベース停滞疑い M（orch-stale-scan.sh を env seam で --emit-count compose）
#       [GATE-PENDING] gate-pending ラベル bead の count + 列挙（generic BD-COUNT に無い＝overlay が別行 compose）
#       [GATE]         clean-state-probe の GREEN/RED advisory（RED でも brief は出す）
#     配送観測（live 窓実況 / 滞留 age）は orch-4js9 の workinprogress 責務ゆえ本 script では fetch しない・
#     compose は skill 層の責務（fetch へ足さない・scope fence）。
#   - canonical が per-project generic 化で **撤去** した安全弁（self-scope gate / main-repo anchor pin）を
#     overlay 側で **保持** し、canonical へ anchor を渡して bd read / WM / CONSUME-TARGET を scriptorium main
#     repo へ pin する（worktree cwd 起動での canonical bd-read fail-loud brick と foreign WM 誤 mv を封じる）。
#
# **marker envelope=案B（rebrief 系 marker を採用・bd orch-noio 裁定(2)）**: header/footer/mode marker は canonical の
#   rebrief 系（`=== [scribe-rebrief-fetch] rebrief DATA … ===` / `[REBRIEF-MODE]` / `=== end rebrief DATA ===`）を
#   そのまま envelope とし、overlay compose 3 行はその footer の **内側** に挿入する（1 envelope に畳む）。
#
# **canonical 参照は env seam + fail-loud（bd orch-noio 裁定(5)・scripts/bdw:22 前例）**:
#   ORCH_RESUME_REBRIEF_FETCH（既定 ~/.claude/plugins/scribe/scripts/scribe-rebrief-fetch.sh）を実行し、
#   非実行可能なら loud die（silent degrade で偽全クリアを出さない）。CLAUDE_PLUGIN_ROOT は scriptorium を
#   指し scribe を指さないので使わない。
#
# **env seam 翻訳（bd orch-noio 裁定・HIGH/MEDIUM）**: overlay 内部 seam ORCH_RESUME_* は **改名しない**
#   （ORCH_RESUME_STALE_SCAN は CLAUDE.md / top-spec でリテラル結線＝改名で cross-script 契約破れ・rename は
#   user 可視 UI 名〔skill dir / slash command〕に限定＝最小 blast）。canonical invoke 時に受領した
#   ORCH_RESUME_{SCRIPTORIUM(anchor),WM_DIR,SID,BD,SESSION_LIB,AUTOCOMPACT_MARKER} を
#   SCRIBE_REBRIEF_{ANCHOR,WM_DIR,SID,BD,SESSION_LIB,AUTOCOMPACT_MARKER} へ明示翻訳する（SCRIPTORIUM→ANCHOR の
#   名称差に注意）。overlay 固有 seam（_PROBE / _STALE_SCAN / _SKIP_SESSION_GATE / _REBRIEF_FETCH）は canonical へ渡さない。
#
# read-only（write-isolation・verb discipline）: bd は list のみ（--json）、probe / stale-scan は read-only 委譲。
#   **本 script は一切 write しない**（consumed 化＝.md→.consumed.md の mv は skill の責務）。foreign 台帳へ触れない。
#
# 環境変数（seam・すべて上書き可・bats を hermetic に保つ）:
#   ORCH_RESUME_SCRIPTORIUM       scriptorium anchor root（既定: 共有 lib _resolve_scriptorium〔ORCH_ANCHOR /
#                                 ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き〕・解決不能は fail-loud）。canonical anchor pin。
#   ORCH_RESUME_WM_DIR            Working Memory dir（既定: <anchor>/.claude-session）。canonical へ WM_DIR として翻訳。
#   ORCH_RESUME_SID              current session id（既定は canonical 側で WM_SESSION_ID > CLAUDE_CODE_SESSION_ID > stdin）。
#   ORCH_RESUME_BD               bd 実体（既定: PATH 上の bd）。read-only。gate-pending 読取と canonical へ翻訳。
#   ORCH_RESUME_PROBE            orch-clean-state-probe.sh の path（既定: 本 script と同ディレクトリ）。GATE advisory。
#   ORCH_RESUME_STALE_SCAN       orch-stale-scan.sh の path（既定: 本 script と同ディレクトリ・bd orch-gg9q Leg B）。
#                                created_at ベース停滞疑い M を --emit-count で compose（scan LOGIC は scan 側 SSOT・fail-open）。
#   ORCH_RESUME_AUTOCOMPACT_MARKER  auto-compact 発火 marker の path（既定は canonical が <WM_DIR>/.auto-compacted 導出）。
#   ORCH_RESUME_SESSION_LIB      cc-session lib dir（canonical へ翻訳・WM 節抽出の SSOT）。
#   ORCH_RESUME_REBRIEF_FETCH    canonical fetch core の path（既定: ~/.claude/plugins/scribe/scripts/scribe-rebrief-fetch.sh）。
#   ORCH_RESUME_SKIP_SESSION_GATE=1  self-scope gate を skip（hermetic self-test / bats 用・clean-state-probe と同型）。
#
# 検証: 本 script の `--self-test`（hermetic・fail-closed・stub canonical で overlay 部のみ exercise）+
#   tests/scenarios/orch-rebrief.bats（stub canonical で overlay 契約を hermetic pin + 実 canonical presence-skip smoke）。
#   実 /scriptorium:orch-rebrief の live 実行は post-land human smoke（worker sandbox では plugin skill 未反映）。

set -uo pipefail

SELF_PREFIX="orch"

# =============================================================================
# --self-test dispatch（main より前・hermetic・fail-closed・bd orch-noio）
# =============================================================================
# 本 script は main を無条件実行するため、self-test は本 script自身を seam で駆動する別プロセスとして走る。
# **overlay 部のみ exercise する**（generic core の検証は canonical 側 self-test の責務で本 shim には移せない）:
#   stub canonical（ORCH_RESUME_REBRIEF_FETCH）が固定 rebrief DATA を emit → overlay が (a) canonical DATA を
#   envelope 内へ passthrough、(b) env seam を SCRIBE_REBRIEF_* へ翻訳、(c) overlay compose 3 行を footer 内へ挿入、
#   (d) canonical 非実行可能で fail-loud、を pin する。cc-session lib 非依存＝環境に依らず走る（stub が代替）。
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t orch-rebrief-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT
    _st_ok()   { echo "ok: $1"; }
    _st_fail() { echo "FAIL: $1" >&2; st_fail=1; }

    # anchor 台帳 fixture（orch）。self-scope gate は SKIP=1 で無効化（cwd 判定は bats の領分）。
    mkdir -p "$st_tmp/anchor/.beads"; printf '{"dolt_database":"orch"}' > "$st_tmp/anchor/.beads/metadata.json"
    _wmdir="$st_tmp/anchor/.claude-session"; mkdir -p "$_wmdir"

    # stub canonical（seam）: 受領した SCRIBE_REBRIEF_* を echo しつつ、rebrief 系 envelope の固定 DATA を emit。
    _canon="$st_tmp/canon-stub.sh"
    cat > "$_canon" <<'CANEOF'
#!/usr/bin/env bash
echo "=== [scribe-rebrief-fetch] rebrief DATA (機械層 fetch・bd sc-8eyw・read-only) ==="
echo "[REBRIEF-MODE] normal"
echo "[ANCHOR] ${SCRIBE_REBRIEF_ANCHOR:-<none>}"
echo "[LEDGER] orch"
echo "[SID] ${SCRIBE_REBRIEF_SID:-<none>}"
echo "[XLATE] WM_DIR=${SCRIBE_REBRIEF_WM_DIR:-<none>} BD=${SCRIBE_REBRIEF_BD:-<none>} LIB=${SCRIBE_REBRIEF_SESSION_LIB:-<none>} MARKER=${SCRIBE_REBRIEF_AUTOCOMPACT_MARKER:-<none>}"
echo "[BD-COUNT] open=1 in_progress=1 blocked=0"
echo "[DIFF-NONE] 乖離なし"
echo "[ORPHAN-NONE] orphan WM なし"
echo "=== end rebrief DATA ==="
CANEOF
    chmod +x "$_canon"

    # stub bd（seam）: gate-pending に orch-gp1 を返す（列挙 assert 用）。
    _bdstub="$st_tmp/bd-stub.sh"
    cat > "$_bdstub" <<'BDEOF'
#!/usr/bin/env bash
case "$*" in
  *"--label gate-pending"*) echo '[{"id":"orch-gp1","status":"open"}]' ;;
  *)                        echo '[]' ;;
esac
BDEOF
    chmod +x "$_bdstub"

    # stub probe（seam）: GREEN（rc0）。
    _probestub="$st_tmp/probe-stub.sh"
    printf '#!/usr/bin/env bash\necho "STUB-PROBE GREEN"\nexit 0\n' > "$_probestub"; chmod +x "$_probestub"

    _st_run() {  # 追加 env は呼出側が export 済み。
        ORCH_RESUME_SKIP_SESSION_GATE=1 \
        ORCH_RESUME_SCRIPTORIUM="$st_tmp/anchor" \
        ORCH_RESUME_WM_DIR="$_wmdir" \
        ORCH_RESUME_SID="sidCUR" \
        ORCH_RESUME_BD="$_bdstub" \
        ORCH_RESUME_PROBE="$_probestub" \
        ORCH_RESUME_SESSION_LIB="$st_tmp/lib" \
        ORCH_RESUME_AUTOCOMPACT_MARKER="$st_tmp/nonexistent-marker" \
        ORCH_RESUME_REBRIEF_FETCH="$_canon" \
        bash "$0" </dev/null 2>&1
    }

    out="$(_st_run)"

    # (a) canonical DATA passthrough（envelope + 主要 marker）。
    if printf '%s' "$out" | grep -qE '^=== \[scribe-rebrief-fetch\] rebrief DATA' \
       && printf '%s' "$out" | grep -qE '^\[REBRIEF-MODE\] normal' \
       && printf '%s' "$out" | grep -qE '^\[DIFF-NONE\]' \
       && printf '%s' "$out" | grep -qE '^\[ORPHAN-NONE\]'; then
        _st_ok "passthrough: canonical rebrief DATA を envelope 内へ通す"
    else
        _st_fail "passthrough: canonical DATA marker を期待: [$out]"
    fi

    # (b) env seam 翻訳（ORCH_RESUME_* → SCRIBE_REBRIEF_*）。stub canonical が echo した [XLATE] / [ANCHOR] で照合。
    if printf '%s' "$out" | grep -qE "^\[ANCHOR\] $st_tmp/anchor" \
       && printf '%s' "$out" | grep -qE "^\[SID\] sidCUR" \
       && printf '%s' "$out" | grep -qE "WM_DIR=$_wmdir " \
       && printf '%s' "$out" | grep -qE "BD=$_bdstub "; then
        _st_ok "xlate: ORCH_RESUME_* を SCRIBE_REBRIEF_* へ翻訳（anchor/sid/wm_dir/bd）"
    else
        _st_fail "xlate: env seam 翻訳を期待: [$out]"
    fi

    # (c) overlay compose 3 行が footer の **内側** に挿入される。
    if printf '%s' "$out" | grep -qE '^\[GATE\] GREEN' \
       && printf '%s' "$out" | grep -qE '^\[GATE-PENDING\] count=1' \
       && printf '%s' "$out" | grep -qE '^  gate-pending: orch-gp1'; then
        _st_ok "overlay: [GATE]/[GATE-PENDING]/列挙 を compose"
    else
        _st_fail "overlay: compose 3 行を期待: [$out]"
    fi
    # footer は overlay compose の **後** に 1 度だけ出る（envelope 内へ畳んだ）。
    _last="$(printf '%s\n' "$out" | grep -nE '^=== end rebrief DATA ===$' | tail -n1 | cut -d: -f1)"
    _gpline="$(printf '%s\n' "$out" | grep -nE '^\[GATE-PENDING\] count=1' | tail -n1 | cut -d: -f1)"
    _nfoot="$(printf '%s\n' "$out" | grep -cE '^=== end rebrief DATA ===$')"
    if [ -n "$_last" ] && [ -n "$_gpline" ] && [ "$_gpline" -lt "$_last" ] && [ "$_nfoot" -eq 1 ]; then
        _st_ok "envelope: overlay compose は footer 内・footer は 1 個"
    else
        _st_fail "envelope: footer(行$_last・個数$_nfoot) の内側に GATE-PENDING(行$_gpline) を期待: [$out]"
    fi

    # (STALE) 整数 emit → [STALE] 停滞疑い=M / 不在 → SKIP（fail-open）。
    _stale_int="$st_tmp/stale-int.sh"; printf '#!/usr/bin/env bash\necho 7\n' > "$_stale_int"; chmod +x "$_stale_int"
    out_si="$(ORCH_RESUME_STALE_SCAN="$_stale_int" _st_run)"
    if printf '%s' "$out_si" | grep -qE '^\[STALE\] 停滞疑い\(actionable created_at>14d\)=7'; then
        _st_ok "stale: 整数 emit → [STALE] 停滞疑い=7 を compose"
    else
        _st_fail "stale: 整数 M=7 の compose を期待: [$out_si]"
    fi
    out_sm="$(ORCH_RESUME_STALE_SCAN="$st_tmp/nonexistent-stale-scan.sh" _st_run)"
    if printf '%s' "$out_sm" | grep -qE '^\[STALE\] SKIP'; then
        _st_ok "stale: 不在 → [STALE] SKIP（fail-open）"
    else
        _st_fail "stale: 不在 path で SKIP を期待: [$out_sm]"
    fi

    # (d) canonical 非実行可能 → fail-loud（rc≠0 + FATAL・偽全クリアを出さない）。
    # _st_run は内部で REBRIEF_FETCH を固定するため、ここは直接 invoke で不在 canonical を渡す。
    out_nc="$(ORCH_RESUME_SKIP_SESSION_GATE=1 ORCH_RESUME_SCRIPTORIUM="$st_tmp/anchor" ORCH_RESUME_WM_DIR="$_wmdir" \
        ORCH_RESUME_SID="sidCUR" ORCH_RESUME_BD="$_bdstub" ORCH_RESUME_PROBE="$_probestub" \
        ORCH_RESUME_REBRIEF_FETCH="$st_tmp/no-such-canonical.sh" \
        bash "$0" </dev/null 2>&1)"; rc_nc=$?
    if [ "$rc_nc" -ne 0 ] && printf '%s' "$out_nc" | grep -qE 'FATAL' \
       && ! printf '%s' "$out_nc" | grep -qE '^=== \[scribe-rebrief-fetch\] rebrief DATA'; then
        _st_ok "fail-loud: canonical 非実行可能 → rc≠0 + FATAL（偽全クリアなし）"
    else
        _st_fail "fail-loud: canonical 不在で fail-loud を期待（rc=$rc_nc）: [$out_nc]"
    fi

    if [ "$st_fail" -eq 0 ]; then echo "orch-rebrief-fetch.sh --self-test: PASS"; exit 0
    else echo "orch-rebrief-fetch.sh --self-test: FAIL" >&2; exit 1; fi
fi

# ── SELF_DIR（script 実体の dir・symlink 解決） ───────────────────────────────
_orch_rebrief_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
SELF_DIR="$(cd "$(dirname "$_orch_rebrief_real")" 2>/dev/null && pwd || printf '%s' "$(dirname "$_orch_rebrief_real")")"

# ── 共有 lib orch_anchor.sh を source（SCRIPTORIUM 代入の**前**・E2 検証に _ledger_dolt_database が要る） ──
# _resolve_scriptorium（E2 anchor 検証付き）/ _ledger_dolt_database（transitive）を提供する。BASH_SOURCE 相対で
# 実 lib を解決するので bats / --self-test が seam override しても実 lib を確実に見つける（clean-state-probe と同型）。
_ORCH_ANCHOR_LIB="$SELF_DIR/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
    # shellcheck source=lib/orch_anchor.sh
    . "$_ORCH_ANCHOR_LIB"
fi
# self-scope gate に使う _ledger_dolt_database を明示 source（orch_anchor が transitive source 済みでも冗長に確保）。
_ORCH_SESSION_LIB_SH="$SELF_DIR/hooks/lib/orch_session.sh"
if ! command -v _ledger_dolt_database >/dev/null 2>&1 && [ -r "$_ORCH_SESSION_LIB_SH" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB_SH"
fi

# ── anchor 解決（env override 最優先・engine は hardcode fallback を持たず解決不能は fail-loud） ──
# overlay 側で anchor を確定し、canonical へ SCRIBE_REBRIEF_ANCHOR として渡して bd read / WM / CONSUME-TARGET を
# scriptorium main repo へ pin する（canonical は per-project generic で anchor pin を撤去済み＝overlay が保持する）。
if command -v _resolve_scriptorium >/dev/null 2>&1; then
    SCRIPTORIUM="${ORCH_RESUME_SCRIPTORIUM:-$(_resolve_scriptorium || true)}"
else
    # 共有 lib 不在の縮退経路でも seam（ORCH_ANCHOR）は直接読む（engine は hardcode fallback を持たない）。
    SCRIPTORIUM="${ORCH_RESUME_SCRIPTORIUM:-${ORCH_ANCHOR:-}}"
fi
if [ -z "$SCRIPTORIUM" ]; then
    echo "orch-rebrief-fetch: anchor 解決不能（fail-loud）: env ORCH_RESUME_SCRIPTORIUM / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ（engine は hardcode fallback を持たない）。" >&2
    exit 1
fi

BD="${ORCH_RESUME_BD:-bd}"
PROBE="${ORCH_RESUME_PROBE:-$SELF_DIR/orch-clean-state-probe.sh}"
# 停滞 scan（bd orch-gg9q Leg B）: created_at ベース停滞疑い M を compose する env seam（scan LOGIC は
# orch-stale-scan.sh が単一 SSOT・本 script は --emit-count で M を注入するだけ＝再実装しない・[TRIPWIRE]）。
STALE_SCAN="${ORCH_RESUME_STALE_SCAN:-$SELF_DIR/orch-stale-scan.sh}"
# canonical generic core（scribe-rebrief-fetch.sh）の path seam。CLAUDE_PLUGIN_ROOT は scriptorium を指し scribe を
# 指さないので使わない（bd orch-noio 裁定(5)）。scripts/bdw:22 の canonical 参照 seam 前例と同型。
CANON="${ORCH_RESUME_REBRIEF_FETCH:-$HOME/.claude/plugins/scribe/scripts/scribe-rebrief-fetch.sh}"

# ── self-scope gate（cwd の台帳 = orch のみ通す・ORCH_RESUME_SKIP_SESSION_GATE=1 で skip＝hermetic 用） ──
# orch-rebrief は orchestrator anchor session の道具。foreign session（un/sc/ccs…）での誤実行を fail-closed で弾く
# （clean-state-probe と同型）。canonical は per-project generic ゆえこの gate を持たない＝overlay が保持する。
# resolver（_ledger_dolt_database）が無い（両共有 lib が読めない壊れた deploy）なら self-scope を判定できない
# ＝clean-state-probe と同じく fail-closed で弾く（silent skip で foreign session に DATA を出す fail-open bypass を封じる）。
if [ "${ORCH_RESUME_SKIP_SESSION_GATE:-0}" != "1" ]; then
    if ! command -v _ledger_dolt_database >/dev/null 2>&1; then
        echo "[orch-rebrief-fetch] FATAL: self-scope resolver（_ledger_dolt_database）不在＝共有 lib（$_ORCH_ANCHOR_LIB / $_ORCH_SESSION_LIB_SH）を解決できず self-scope 判定不能 → fail-closed で実行しない（clean-state-probe と同型・ORCH_RESUME_SKIP_SESSION_GATE=1 で hermetic bypass 可）" >&2
        exit 1
    fi
    _cwd_db="$(_ledger_dolt_database "$PWD" 2>/dev/null || true)"
    if [ "$_cwd_db" != "$SELF_PREFIX" ]; then
        echo "[orch-rebrief-fetch] self-scope: cwd の台帳 dolt_database='${_cwd_db:-<none>}' が自台帳（$SELF_PREFIX）でない → 実行しない（no-op・exit 0）" >&2
        exit 0
    fi
fi

# ── canonical generic core の存在検査（fail-loud・非実行可能なら偽全クリアを出さず loud die） ──
if [ ! -x "$CANON" ]; then
    echo "[orch-rebrief-fetch] FATAL: canonical generic core（$CANON）が実行可能でない＝WM↔bd diff / orphan / mode / consume-target を委譲できない → 実行しない（silent degrade で『乖離なし』を騙らない・ORCH_RESUME_REBRIEF_FETCH で override 可・scribe plugin が user-scope enable されているか確認せよ）" >&2
    exit 1
fi

# ── canonical generic core を invoke（env seam 翻訳・ORCH_RESUME_* → SCRIBE_REBRIEF_*） ───────────
# overlay 固有 seam（_PROBE / _STALE_SCAN / _SKIP_SESSION_GATE / _REBRIEF_FETCH）は canonical へ渡さない。
# anchor は overlay 解決値（SCRIPTORIUM）を SCRIBE_REBRIEF_ANCHOR へ pin する（worktree cwd 起動での canonical
# bd-read fail-loud brick と foreign WM 誤 mv を封じる）。stdin（hook JSON の .session_id fallback）は subshell が継承。
_canon_errf="$(mktemp -t orch-rebrief-canonerr-XXXXXX)" || { echo "[orch-rebrief-fetch] FATAL: mktemp 失敗（canonical stderr の捕捉に必要）" >&2; exit 1; }
trap 'rm -f "$_canon_errf"' EXIT
_canon_out="$(
    export SCRIBE_REBRIEF_ANCHOR="$SCRIPTORIUM"
    export SCRIBE_REBRIEF_WM_DIR="${ORCH_RESUME_WM_DIR:-$SCRIPTORIUM/.claude-session}"
    [ -n "${ORCH_RESUME_SID:-}" ]                && export SCRIBE_REBRIEF_SID="$ORCH_RESUME_SID"
    [ -n "${ORCH_RESUME_BD:-}" ]                 && export SCRIBE_REBRIEF_BD="$ORCH_RESUME_BD"
    [ -n "${ORCH_RESUME_SESSION_LIB:-}" ]        && export SCRIBE_REBRIEF_SESSION_LIB="$ORCH_RESUME_SESSION_LIB"
    [ -n "${ORCH_RESUME_AUTOCOMPACT_MARKER:-}" ] && export SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$ORCH_RESUME_AUTOCOMPACT_MARKER"
    bash "$CANON" 2>"$_canon_errf"
)"
_canon_rc=$?
_canon_err="$(cat "$_canon_errf" 2>/dev/null)"
if [ "$_canon_rc" -ne 0 ]; then
    echo "[orch-rebrief-fetch] FATAL: canonical generic core（$CANON）が rc=$_canon_rc で失敗＝generic core（WM↔bd diff / orphan / mode / consume-target）を取得できない → 実行しない（overlay compose だけ出して『乖離なし』を騙らない・fail-loud を伝播する）: ${_canon_err:-（stderr なし）}" >&2
    exit "$_canon_rc"
fi
# canonical が rc=0 で stderr に良性 warning を出した場合も原因は surface する（DATA には混ぜない）。
[ -n "$_canon_err" ] && printf '%s\n' "$_canon_err" >&2

# ── canonical DATA を envelope 内へ passthrough（footer を一旦剥がして overlay compose を内側へ入れる・案B） ──
_footer="=== end rebrief DATA ==="
if [ "${_canon_out##*$'\n'}" = "$_footer" ]; then
    _body="${_canon_out%$'\n'"$_footer"}"      # 末尾 footer を剥がす（overlay compose の後に 1 度だけ再出力）
else
    _body="$_canon_out"                         # canonical が footer を出さない異常時も防御的に続行
fi
printf '%s\n' "$_body"

# =============================================================================
# overlay 固有 compose（orchestrator の付加価値・3 点のみ・bd orch-noio 裁定 LOW L1#9）
#   [STALE] / [GATE-PENDING] / [GATE]。配送観測 compose は skill 層の責務ゆえ fetch へ足さない。
# =============================================================================
echo ""
echo "── (overlay) orchestrator 固有 compose（STALE / gate-pending / GATE・bd orch-noio） ──"

# ── bd fetch helper（read-only・自台帳 orch- に限定・anchor へ pin） ─────────────
# gate-pending 列挙だけに使う（generic diff/orphan は canonical が担う）。worktree cwd 起動でも anchor へ cd して
# 叩き SCRIPTORIUM 台帳へ pin する（cd 失敗＝anchor 不在なら `&&` 短絡で空出力＝fail-safe）。
_bd_json() { ( cd "$SCRIPTORIUM" 2>/dev/null && "$BD" "$@" --json ) 2>/dev/null; }
_parse_ids() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[]?.id' 2>/dev/null
    else
        grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/\1/'
    fi
}

# ── [STALE] 停滞疑い M（created_at ベース・orch-stale-scan.sh を --emit-count で compose・[TRIPWIRE]） ──
# scan LOGIC の単一 SSOT は orch-stale-scan.sh（fetch は compute せず compose）。fail-open: scan 不在/失敗は
# SKIP note で継続（resume を止めない）。fetch は既に self-scope gate 済ゆえ scan は SKIP=1 で bypass し anchor へ pin。
if [ -x "$STALE_SCAN" ]; then
    _stale_m="$(ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$SCRIPTORIUM" ORCH_STALE_BD="$BD" \
        "$STALE_SCAN" --emit-count 2>/dev/null)"
    if printf '%s' "$_stale_m" | grep -qE '^[0-9]+$'; then
        echo "[STALE] 停滞疑い(actionable created_at>14d)=$_stale_m（詳細は orch-stale-scan.sh・held/defer/tracker は除外）"
    else
        echo "[STALE] SKIP（orch-stale-scan --emit-count が整数を返さず・fail-open）"
    fi
else
    echo "[STALE] SKIP（orch-stale-scan.sh 不在/非実行可能: $STALE_SCAN・fail-open＝別便配線でなく本便 land 済想定）"
fi

# ── [GATE-PENDING] gate-pending ラベル bead の count + 列挙（generic BD-COUNT に無い＝overlay 別行 compose・裁定(2)） ──
_gp_ids="$(_bd_json list --label gate-pending --limit 0 | _parse_ids | grep -E "^${SELF_PREFIX}-" || true)"
_gp_n="$(printf '%s\n' "$_gp_ids" | grep -c . || true)"
echo "[GATE-PENDING] count=$_gp_n"
if [ -n "$_gp_ids" ]; then
    printf '%s\n' "$_gp_ids" | while IFS= read -r id; do [ -n "$id" ] && echo "  gate-pending: $id"; done
fi

# ── [GATE] GREEN gate（clean-state-probe・advisory＝RED でも brief は出す） ─────
if [ -x "$PROBE" ]; then
    _probe_out="$("$PROBE" 2>&1)"; _probe_rc=$?
    if [ "$_probe_rc" -eq 0 ]; then echo "[GATE] GREEN（respawn 可・clean-state-probe rc0）"; else echo "[GATE] RED（要片付け・clean-state-probe rc$_probe_rc）"; fi
    printf '%s\n' "$_probe_out" | sed 's/^/  /'
else
    echo "[GATE] SKIP（probe 不在/非実行可能: $PROBE）"
fi

# ── envelope footer を最後に 1 度だけ再出力（overlay compose を rebrief DATA 内へ畳んだ・案B） ──
echo ""
echo "$_footer"

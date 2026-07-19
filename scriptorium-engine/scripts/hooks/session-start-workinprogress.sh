#!/usr/bin/env bash
# session-start-workinprogress.sh — orchestrator SessionStart で「仕掛かり」を自動表示（bd orch-7py / orch-c8p F）
#
# 役割（orch-c8p grill G3② 採択・doobidoo f4888921）: fresh な orchestrator session の起動時に、
#   仕掛かり中の作業を自動 surface する。respawn 既定化(E)と対になる「fresh orchestrator の仕掛かり
#   自動表示」＝orchestrator が session を建て直すたびに、gate 待ち cell と degraded/suspect cell を
#   手で叩かずとも context へ流し込む。具体的には次の 4 つを **read-only** で自動実行する:
#     (1) gate-pending pull : scripts/orch-dispatch.sh --gate-pending
#         （gate 待ち cell 一覧＝self-dev 直 gate / 外部 repo cell の 2 バケット + foreign 鮮度警告）
#     (2) degraded-watch    : scripts/orch-degraded-watch.sh
#         （spawn cell の構造3核 suspect/salvage＝窓消失した cell の取りこぼしを surface）
#     (3) needs-orch handoff: scripts/orch-handoff-scan.sh --no-freshness
#         （foreign→orchestrator 検知線＝hydrated orch DB の needs-orch ラベル foreign bead を surface・
#           bd orch-jmu / orch-am1 論点6。鮮度警告は第1セクションに委譲するため --no-freshness で呼ぶ＝
#           同一 hook 出力での二重表示を避ける・orch-jmu notes p3）
#     (4) 配送観測          : scripts/orch-delivery-observe.sh（bd orch-4js9・top-spec §1.1:85 / §5.4:246）
#         （各 admin〔宛先 X〕への for:X 便の cycle 境界 proxy / 推論配送 3 値 / 呼び鈴 proposal-only /
#           auto-compact marker read を surface。proxy scope〔heartbeat 非依存で単独成立〕・read-only・fail-open）。
#         ★surface 分担（fence9・doc-only）: 配送観測（mailbox / 便滞留の read-only 監視）は **本 hook** が担い、
#           hygiene tripwire（同期ズレ・仕掛かり整合の点検）は別便 **/scriptorium:orch-rebrief brief**（orch-x1ae・
#           未 land ゆえ forward 参照）が担う。配送観測は §1.2 ① の無条件能動側＝wake（③）ではない（呼び鈴は
#           「提案のみ」で push=wake は人間 go・本 hook は push を発火しない・top-spec §5.4:246「配送観測 ≠ wake」）。
#   Claude Code は SessionStart hook の stdout を session context へ注入する仕様ゆえ、4 script の
#   stdout をそのまま出す（spec-inject / guard-health と同経路・plain stdout）。
#
# self-scope（最重要・spec-inject / guard-health と同型）: 本 hook を plugin として global enable すると
#   SessionStart は **全セッション**で発火する。orchestrator session（cwd から walk-up した最初の
#   .beads/metadata.json の dolt_database が SELF_PREFIX(orch)に完全一致）でのみ発火し、foreign
#   （scribe 'sc' / cc-session 'ccs' …）・判定不能は無出力で exit 0（no-op・誤注入ゼロ）。
#   前方一致 'orchX'(orch2 等)は完全一致比較で弾く。判定機構は bd-write-guard.py(un-mbz)/ spec-inject の
#   walk-up と同一・同一 SELF_PREFIX を共有する。metadata 在るが parse 失敗(present-but-unreadable)は
#   spec-inject と同様 fail-open（無表示・誤注入ゼロ優先）＝本 hook の出力は cosmetic な surface ゆえ moat
#   維持の fail-closed（guard 群）とは別方針で良い（walk-up/SELF_PREFIX 自体は同一）。
#
# cwd 第2軸（anchor だけ発火・orch-1r7 grill G3・SCRIBE_ROLE 非依存・spec-inject と同型）: 上の self-scope
#   （台帳=orch）は「この repo が orchestrator か」を判定するが、orchestrator repo の **worktree**（自己開発
#   worker cell）は台帳 walk-up が anchor の .beads(dolt_database=orch)へ届くため self-scope を通過してしまう。
#   だが worker worktree は scribe worker protocol で動く別 role であり、そこへ「gate 待ち一覧」を注入するのは
#   誤配（worker は自 issue のみ扱い・gate は admin/anchor の責務）。よって self-scope と直交する第2軸として、
#   hook cwd が `.worktrees/` または `.claude/worktrees/`(CC-native worktree)配下なら orch session でも
#   **no-op** する（anchor〔非 worktree〕だけ発火）。この軸は SCRIBE_ROLE 値に依存しない純 cwd 判定。
#
# fail-open（全セッション破壊の防止・acceptance 3）: 判定不能・script 不在・script 内部エラーでもセッションを
#   壊さない。set -e は使わず常に exit 0（degrade）。参照 script（orch-dispatch.sh / orch-degraded-watch.sh）が
#   不在/非実行可能なら skip note を出して continue、存在時は `|| true` で内部エラーを握り潰す（hooks.json の
#   二重 fail-safe 指示と整合）。両 script は read-only（bd/foreign 台帳を mutate しない）ゆえ本 hook 経由の
#   自動実行が write-isolation を侵すことはない。
#
# plugin 反映（acceptance 5・CLAUDE.md「plugin 反映」節）: 本 hook は plugin として live 化する。反映には
#   **新規 cld session が必須**（`/reload-plugins` は起動引数 replay のみで hooks を再列挙しない）。既存 session
#   では効かない＝新しい orchestrator session を建て直して初めて自動表示が効く。
#
# --self-test（hermetic・fail-closed・orch-7py）: 引数 `--self-test` で自己完結テストを走らせる。temp に
#   fixture plugin root（stub orch-dispatch.sh / orch-degraded-watch.sh が sentinel を echo）と台帳 fixture
#   （orch anchor / orch worktree(.worktrees・.claude/worktrees) / foreign）を作り、各 cwd を stdin JSON で
#   与えて本 script を subprocess 起動し、anchor→両 sentinel 表示 / worktree→no-op / foreign→no-op を assert
#   する。非vacuity: anchor→両 sentinel が出ることが「no-op 群が常時空でない」証明（cwd/台帳 軸が識別している）。
#   加えて stub 削除 mutation で anchor でも sentinel が消え skip note + exit0 になる（fail-open 非vacuous）。
#   assert が 1 つでも落ちれば非 0。
#
# 検証: tests/scenarios/session-start-workinprogress.bats（hermetic E2E）+ 本 file の `--self-test` +
#   selftest-orch-7py.local.sh（worktree 直下・untracked・fail-closed）。

# 自台帳 prefix（.beads/metadata.json dolt_database="orch" / orchestrator CLAUDE.md SSOT）。
# bd-write-guard.py / spec-inject の SELF_PREFIX="orch" と同一値を共有する（session self-scope の台帳判定）。
SELF_PREFIX="orch"

# --- plugin root / 参照 script パス解決（CLAUDE_PLUGIN_ROOT 優先・無ければ script 位置から導出） ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    # scripts/hooks/ の 2 つ上 = plugin root
    PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
DISPATCH="$PLUGIN_ROOT/scripts/orch-dispatch.sh"
DEGRADED="$PLUGIN_ROOT/scripts/orch-degraded-watch.sh"
HANDOFF="$PLUGIN_ROOT/scripts/orch-handoff-scan.sh"
DELIVERY="$PLUGIN_ROOT/scripts/orch-delivery-observe.sh"   # 第4節 配送観測（bd orch-4js9・read-only）

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・SSOT = scripts/hooks/lib/orch_session.sh） ---
# _extract_cwd / _json_is_valid / _ledger_dolt_database / _is_orch_session / _is_worktree_cwd を提供する。
# ★実 script 位置（BASH_SOURCE 相対 = $_SCRIPT_DIR）で解決するので、bats / --self-test が CLAUDE_PLUGIN_ROOT を
#   fixture へ向けても実 lib を確実に見つける（fixture 無改変で green を保つ）。_is_orch_session は上で定義した
#   SELF_PREFIX を参照する（lib の SELF_PREFIX 契約）。_json_is_valid の guard parity（破損 orch トークン誤発火防止）
#   や present-but-unreadable の fail-open など意味論は従来の verbatim 定義と同一（lib header 参照）。
# lib 不在は fail-open（無表示・誤注入ゼロ優先＝本 hook の cosmetic 性に合致）で exit 0 する。
_ORCH_SESSION_LIB="$_SCRIPT_DIR/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "[orchestrator/SessionStart] warning: 共有 self-scope lib 不在（$_ORCH_SESSION_LIB）・仕掛かり自動表示を skip（fail-open continue）" >&2
    exit 0
fi

# --- 仕掛かり自動表示の本体（self-scope/cwd-axis を通過した orch anchor session でのみ到達） ---
# fail-open: 参照 script が不在/非実行可能なら skip note・存在時は `|| true` で内部エラーを握り潰す。
# cd "$1"（検証済み orch anchor cwd）してから両 script を実行し、bd（dispatch）/ degraded の self-scope gate
# （共有 _ledger_dolt_database・orch-t9z で lib へ統一）が hook_cwd を起点に一貫解決するようにする（両 script は read-only）。
_emit_workinprogress() {
    local anchor_cwd="$1"
    cd "$anchor_cwd" 2>/dev/null || true

    echo "=== [orchestrator/SessionStart] 仕掛かり自動表示（gate-pending + degraded-watch・self-scope: orch anchor のみ） ==="
    echo ""

    echo "── (1) gate-pending（gate 待ち cell・read-only） ──"
    if [ -x "$DISPATCH" ]; then
        "$DISPATCH" --gate-pending 2>/dev/null || echo "  （orch-dispatch --gate-pending が非0終了・skip＝fail-open）"
    else
        echo "  （orch-dispatch.sh 不在/非実行可能: $DISPATCH・skip＝fail-open）"
    fi
    echo ""

    echo "── (2) degraded-watch（窓消失 cell の suspect/salvage・read-only） ──"
    if [ -x "$DEGRADED" ]; then
        "$DEGRADED" 2>/dev/null || echo "  （orch-degraded-watch.sh が非0終了・skip＝fail-open）"
    else
        echo "  （orch-degraded-watch.sh 不在/非実行可能: $DEGRADED・skip＝fail-open）"
    fi
    echo ""

    # (3) needs-orch handoff（foreign→orchestrator 検知線・bd orch-jmu / orch-am1 論点6）。鮮度警告は
    #     第1セクション（gate-pending pull）へ委譲するため --no-freshness で呼ぶ（同一 hook 出力の二重表示回避・p3）。
    echo "── (3) needs-orch handoff（foreign→orchestrator 検知線・read-only） ──"
    if [ -x "$HANDOFF" ]; then
        "$HANDOFF" --no-freshness 2>/dev/null || echo "  （orch-handoff-scan.sh が非0終了・skip＝fail-open）"
    else
        echo "  （orch-handoff-scan.sh 不在/非実行可能: $HANDOFF・skip＝fail-open）"
    fi
    echo ""

    # (4) 配送観測（delivery observation・bd orch-4js9・top-spec §1.1:85 / §5.4:246）。各 admin（宛先 X）への
    #     for:X 便の cycle 境界 proxy / 推論配送 3 値 / 呼び鈴 proposal-only / auto-compact marker read を surface
    #     する（proxy scope・read-only・fail-open）。滞留検知（配送観測）は wake でなく §1.2 ① の無条件能動側＝
    #     呼び鈴は「提案のみ」で push（wake=③）は人間 go（本 hook は push を発火しない）。hygiene tripwire は別便
    #     /scriptorium:orch-rebrief brief（orch-x1ae）が担う分担（surface 分担: 配送観測=本 hook / tripwire=orch-rebrief）。
    echo "── (4) 配送観測（cycle 境界 proxy / 推論配送 / 呼び鈴提案・read-only） ──"
    if [ -x "$DELIVERY" ]; then
        "$DELIVERY" 2>/dev/null || echo "  （orch-delivery-observe.sh が非0終了・skip＝fail-open）"
    else
        echo "  （orch-delivery-observe.sh 不在/非実行可能: $DELIVERY・skip＝fail-open）"
    fi
}

# === --self-test: hermetic 自己完結テスト（fail-closed・orch-7py） ===
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t wip-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    # fixture plugin root（stub が sentinel を echo）。sentinel に起動時 PWD（本体の load-bearing な
    # cd "$anchor_cwd" を pin）と受領 args（dispatch は --gate-pending / degraded は無引数=scan mode /
    # handoff は --no-freshness=第1セクションへ鮮度委譲・orch-jmu p3）を含める。
    mkdir -p "$st_tmp/plugin/scripts"
    printf '#!/usr/bin/env bash\necho "GATE-PENDING-SENTINEL pwd=$PWD args=[$*]"\n'   > "$st_tmp/plugin/scripts/orch-dispatch.sh"
    printf '#!/usr/bin/env bash\necho "DEGRADED-WATCH-SENTINEL pwd=$PWD args=[$*]"\n' > "$st_tmp/plugin/scripts/orch-degraded-watch.sh"
    printf '#!/usr/bin/env bash\necho "HANDOFF-SCAN-SENTINEL pwd=$PWD args=[$*]"\n'   > "$st_tmp/plugin/scripts/orch-handoff-scan.sh"
    printf '#!/usr/bin/env bash\necho "DELIVERY-OBSERVE-SENTINEL pwd=$PWD args=[$*]"\n' > "$st_tmp/plugin/scripts/orch-delivery-observe.sh"
    chmod +x "$st_tmp/plugin/scripts/orch-dispatch.sh" "$st_tmp/plugin/scripts/orch-degraded-watch.sh" \
             "$st_tmp/plugin/scripts/orch-handoff-scan.sh" "$st_tmp/plugin/scripts/orch-delivery-observe.sh"

    # 台帳 fixture。
    mkdir -p "$st_tmp/anchor/.beads";  printf '{"dolt_database":"orch"}' > "$st_tmp/anchor/.beads/metadata.json"
    mkdir -p "$st_tmp/foreign/.beads"; printf '{"dolt_database":"un"}'   > "$st_tmp/foreign/.beads/metadata.json"
    mkdir -p "$st_tmp/anchor/.worktrees/spawn/wt"        # 台帳 walk-up は anchor(orch)へ届く worktree
    mkdir -p "$st_tmp/anchor/.claude/worktrees/wt2"      # CC-native worktree

    # hazard-faithful stub tmux（consult 経路・fence7 b・spec-inject.sh の M2 teeth と同型）。`-t <pane>` 明示時のみ
    # 「その pane の窓名」= $STUB_WNAME を返す（空なら非0=取得失敗を模す）。`-t <value>` 不在（bare 形 = mutation）は
    # focused 別窓を模し非 consult 名 orchestrator を返す → _is_consult_window の -t "$TMUX_PANE" 明示を pin する。
    mkdir -p "$st_tmp/bin"
    cat > "$st_tmp/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
have_t=0; prev=""
for a in "$@"; do
    if [ "$prev" = "-t" ] && [ -n "$a" ]; then have_t=1; fi
    prev="$a"
done
if [ "$have_t" -eq 1 ]; then
    [ -n "${STUB_WNAME:-}" ] || exit 1
    printf '%s\n' "$STUB_WNAME"
else
    printf '%s\n' "orchestrator"
fi
TMUXEOF
    chmod +x "$st_tmp/bin/tmux"

    # $1=cwd → fixture plugin root で本 script を fresh 起動し stdout を返す（非 consult 経路）。exit code は呼出側が
    # `out="$(_st_run ...)"; rc=$?` で受ける（command substitution の $? = pipeline 末尾 bash "$0" の rc）。
    # ★env -u TMUX -u TMUX_PANE（fence7 a）: self-test を実 tmux window 内で回したとき、新設 consult gate の
    #   _is_consult_window が実 tmux を叩いて実窓名に依存するのを遮断する（既存 modality を実窓名非依存に保つ・byte 不変）。
    _st_run() {
        printf '{"cwd":"%s"}' "$1" | env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" bash "$0"
    }
    # consult 経路（fence7 b）: TMUX + stub tmux 付きで起動（$2=窓名・空→tmux 失敗を模す）。
    _st_run_consult() {  # $1=cwd $2=window-name
        printf '{"cwd":"%s"}' "$1" | env CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" \
            PATH="$st_tmp/bin:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" bash "$0"
    }
    _st_both() {  # $1=label $2=cwd : 4 sentinel + cd anchor + degraded 無引数 + handoff --no-freshness + exit0 を期待
        local out rc expect; out="$(_st_run "$2")"; rc=$?; expect="$(cd "$2" 2>/dev/null && pwd)"
        # cd "$anchor_cwd"（load-bearing）を pin: stub の起動時 PWD が anchor と一致。degraded/delivery は無引数(scan)。
        # handoff は --no-freshness（鮮度を第1セクションへ委譲・orch-jmu p3）で呼ばれることを pin。
        if printf '%s' "$out" | grep -qF "GATE-PENDING-SENTINEL pwd=$expect args=[--gate-pending]" \
            && printf '%s' "$out" | grep -qF "DEGRADED-WATCH-SENTINEL pwd=$expect args=[]" \
            && printf '%s' "$out" | grep -qF "HANDOFF-SCAN-SENTINEL pwd=$expect args=[--no-freshness]" \
            && printf '%s' "$out" | grep -qF "DELIVERY-OBSERVE-SENTINEL pwd=$expect args=[]" \
            && [ "$rc" -eq 0 ]; then echo "ok: $1"
        else echo "FAIL: $1 — cd anchor + degraded/delivery 無引数 + handoff --no-freshness + 4 sentinel + exit0 を期待したが不一致（rc=$rc・expect_pwd=$expect）: [$out]" >&2; st_fail=1; fi
    }
    _st_noop() {  # $1=label $2=cwd : no-op（無出力）+ exit0 を期待（非 consult 経路）
        local out rc; out="$(_st_run "$2")"; rc=$?
        if [ -z "$out" ] && [ "$rc" -eq 0 ]; then echo "ok: $1"
        else echo "FAIL: $1 — no-op(無出力)+exit0 を期待したが不一致（rc=$rc）: [$out]" >&2; st_fail=1; fi
    }
    _st_emit_c() {  # $1=label $2=cwd $3=wname : consult 経路で 4 sentinel 表示（＝gate 通過し emit）を期待
        local out; out="$(_st_run_consult "$2" "$3")"
        if printf '%s' "$out" | grep -qF "GATE-PENDING-SENTINEL" \
            && printf '%s' "$out" | grep -qF "DELIVERY-OBSERVE-SENTINEL"; then echo "ok: $1"
        else echo "FAIL: $1 — consult 経路で emit（sentinel 表示）を期待したが不一致: [$out]" >&2; st_fail=1; fi
    }
    _st_noop_c() {  # $1=label $2=cwd $3=wname : consult 経路で no-op（無出力）を期待
        local out; out="$(_st_run_consult "$2" "$3")"
        if [ -z "$out" ]; then echo "ok: $1"
        else echo "FAIL: $1 — consult no-op を期待したが出力あり: [$out]" >&2; st_fail=1; fi
    }

    _st_both "orch anchor cwd → 4 sentinel 表示（gate-pending / degraded / handoff / delivery）"  "$st_tmp/anchor"
    _st_noop "orch worktree(.worktrees/) → no-op"                 "$st_tmp/anchor/.worktrees/spawn/wt"
    _st_noop "orch worktree(.claude/worktrees/) → no-op"          "$st_tmp/anchor/.claude/worktrees/wt2"
    _st_noop "foreign 台帳 → no-op（self-scope）"                  "$st_tmp/foreign"

    # consult 窓 第3軸（orch-z4z7 / fence7 b・spec-inject と同型）。
    _st_noop_c "consult 窓(consult-*) → anchor cwd でも no-op（全4節一括 gating・gate 削除 mutation で RED）" "$st_tmp/anchor" "consult-abc"
    _st_emit_c "非 consult 窓(orchestrator) → emit（4 sentinel 表示）"                                       "$st_tmp/anchor" "orchestrator"
    _st_noop_c "foreign 台帳 + consult 窓 → no-op（self-scope 先勝ち）"                                       "$st_tmp/foreign" "consult-abc"
    # TMUX 未設定 → 非 consult 扱い（fail-safe・emit 継続）は _st_both（env -u TMUX）が既に pin 済み（anchor→4 sentinel）。

    # 非vacuity(mutation): stub を消すと anchor でも 全 sentinel が消え skip note + exit0（fail-open・非vacuous）。
    rm -f "$st_tmp/plugin/scripts/orch-dispatch.sh" "$st_tmp/plugin/scripts/orch-degraded-watch.sh" \
          "$st_tmp/plugin/scripts/orch-handoff-scan.sh" "$st_tmp/plugin/scripts/orch-delivery-observe.sh"
    _st_mut_out="$(_st_run "$st_tmp/anchor")"; _st_mut_rc=$?
    if [ "$_st_mut_rc" -eq 0 ] \
        && ! printf '%s' "$_st_mut_out" | grep -q 'GATE-PENDING-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'DEGRADED-WATCH-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'HANDOFF-SCAN-SENTINEL' \
        && ! printf '%s' "$_st_mut_out" | grep -q 'DELIVERY-OBSERVE-SENTINEL' \
        && printf '%s' "$_st_mut_out" | grep -q 'fail-open'; then
        echo "ok: mutation: stub 不在 → anchor でも 4 sentinel 消失 + skip note + exit0（fail-open・非vacuous）"
    else
        echo "FAIL: mutation: stub 不在 fail-open を期待したが不一致（rc=$_st_mut_rc）: [$_st_mut_out]" >&2; st_fail=1
    fi

    if [ "$st_fail" -eq 0 ]; then echo "workinprogress --self-test: PASS"; exit 0
    else echo "workinprogress --self-test: FAIL" >&2; exit 1; fi
fi

# === self-scope: 非 orchestrator session は無出力で exit 0（no-op） ===
hook_cwd="$(_extract_cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
if ! _is_orch_session "$hook_cwd"; then
    exit 0   # 他 project / 判定不能 session へは一切表示しない（誤注入ゼロ）
fi

# === cwd 第2軸（orch-1r7 G3）: orch worktree（自己開発 worker cell）には仕掛かり一覧を表示しない ===
if _is_worktree_cwd "$hook_cwd"; then
    exit 0
fi

# === consult 窓 第3軸（orch-z4z7 / orch-qcqz Finding H 同型 leak・fence7）: consult 窓へは仕掛かり一覧を注入しない ===
# consult は anchor 同居（cwd=anchor）ゆえ self-scope(orch)と cwd 第2軸を素通りするが、別 role（read-only 相談役）で
# gate-pending / degraded / handoff / 配送観測の仕掛かり表示は誤配（orchestrator 文脈漏れ）。spec-inject.sh:195 と
# 同一配置で全 4 節を一括 gating する（第4節限定に置かない）。判定は共有 lib の _is_consult_window（qcqz PR#87 で
# 既 land・orch_session.sh は touch しない）。取得不能（tmux 不在 / $TMUX 未設定 / 窓名取得不能）は非 consult 扱い＝
# 注入継続（fail-safe・b-4「不能→no-op」は既存 anchor 挙動を壊す誤り）。
if _is_consult_window; then
    exit 0
fi

# === orchestrator anchor session: 仕掛かりを自動表示（fail-open） ===
_emit_workinprogress "$hook_cwd"

exit 0

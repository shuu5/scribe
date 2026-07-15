#!/usr/bin/env bats
# scribe-rebrief-fetch.bats — rebrief cycle core（機械層 fetch）の検証（bd sc-8eyw）
#
# カバレッジ（bd sc-8eyw acceptance / notes fence 対応）:
#   - 構文(bash -n)
#   - (1) WM↔bd diff: drift 陽性 / 等価化で消失（mutation 非空虚）/ 言及のみ /
#         先行 mention が後続 status 主張を握り潰さない(1e) / 散文語の部分一致で bead を捏造しない(1f) +
#         語境界の過剰縮小の裏 assert(1g)
#   - (2) orphan WM: ★consumed sibling 併存でも検出（F1 のバグ修正＝参照実装の assertion を反転）/
#                    回帰 3 ケース（current sid ・ consumed のみ ・ 非標準 suffix は非検出）/ mutation で ORPHAN-NONE
#   - (3) force-recovery: marker 不在→normal / 有→force-recovery（toggle 非空虚）
#   - (4) consumed 化対象: current WM found→[CONSUME-TARGET] / missing→[CONSUME-NONE]
#   - SELF_PREFIX の per-project walk-up 実測（F4/F5）: dolt_database=sc と =ccs の 2 fixture で
#     母集団が解決値へ束ねられること（定数 "sc" 流用なら ccs fixture が落ちる＝teeth）
#   - fail-loud（F4/F6/F7）: 台帳識別不能 / anchor 解決不能 / cc-session lib 不在 は exit 1（silent skip しない）
#   - fail-loud の対称性（自己点検 fix）: bd 実体不在(FL4) / bd 非 0 終了+stderr(FL5) / 壊れ JSON(FL6) /
#     lib 版ずれ＝記号不在(FL8) / anchor 直下 metadata 不在→祖先台帳へ束ねない(FL9) も exit 1。
#     いずれも「[BD-COUNT]/[DIFF-NONE] を名乗らない」ことまで assert する（fail-open 回帰の teeth）。
#     WM が「在るが読めない」も同様に exit 1（FL11・`-f` だけの gate では [DIFF-NONE] を騙る）。
#     WM **dir** が読めない(000)/辿れるだけ(111) も同型ゆえ exit 1（FL12/FL13・`[ -d ]` だけの gate では
#     glob が空振りして [ORPHAN-NONE] が嘘になる。dir 不在は正当＝FL14 が過剰 fail-closed の裏を張る）。
#     JSON parser（jq/python3）双方不在も exit 1（FL15・粗 grep 近似に落ちない。FL16 が python3 単独経路を
#     jq baseline と同一出力で pin し、FL17 が degraded mode の非再導入を張る）。
#   - respawn / `/clear`（sid 変化）経路（R1-R5）: 前 session の WM に真の乖離が在る状態で新 sid で回すと
#     [DIFF-NONE] を名乗らず [DIFF-UNKNOWN] + [WM-CANDIDATE]（mtime 降順）を出す。候補 sid で再 fetch すれば
#     DRIFT が surface する（回復手順の実効性）。R4/R5 が過剰警告・過剰置換の裏を張る。
#     過剰 fail-closed の裏 assert として空台帳 `[]` は rc0 で通す(FL7)、および bd が rc=0 + stderr warning
#     （beads.role 未設定 / .beads perms＝新規 project の既定）を出しても rc0 で DATA を出す(FL10)。
#   - seam 貫通の封じ(AMB): ambient WORKING_MEMORY_FILE が pin に勝たない（foreign WM の誤 mv 教唆を防ぐ）
#   - CLAUDE_CONFIG_DIR override 下の lib 解決（F7）
#   - read-only 契約: 実行で WM dir が mutate されない
#
# cc-session lib は fixture として **供給** する（F6: SKIP を green と数えない）。供給できない環境は
# skip でなく FAIL させる＝cc-session の user-scope enable は本 core の前提（F7）。

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/scribe-rebrief-fetch.sh"

    CUR="sidCUR"

    # ── suite を ambient WM env から隔離する（hermetic 性の前提） ──
    # cc-session の session-env.sh は WORKING_MEMORY_FILE を **ambient 優先** で解決し、対になる
    # /session:ready-compaction は同 lib を Bash tool 上で source して export する。これらが環境に残ったまま
    # suite を回すと seam pin が効かず (1a)(4a)(4b)(F7a) が落ちる＝test の緑が環境依存になる。
    # test 側でも叩き落として「どこで回しても同じ結果」を保証する（script 側の unset との二重防御）。
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE

    # ── cc-session lib を fixture へ供給（F6: 陽性 modality を SKIP に落とさない） ──
    CC_LIB="$BATS_TEST_TMPDIR/cc-lib"
    mkdir -p "$CC_LIB"
    _cc_src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/session/scripts/lib"
    if [ -r "$_cc_src/session-env.sh" ] && [ -r "$_cc_src/working-memory.sh" ]; then
        cp "$_cc_src/session-env.sh" "$_cc_src/working-memory.sh" "$CC_LIB/"
    else
        # SKIP しない（bd sc-8eyw notes F6）: 陽性 modality が skip で緑になると vacuous＝偽 DONE の温床。
        echo "FATAL(fixture): cc-session lib を供給できない（探索元: $_cc_src）。cc-session(session plugin) は本 core の前提＝user-scope で enable せよ。F6 により SKIP せず FAIL する。" >&2
        return 1
    fi

    # ── bd stub（seam・返す JSON は env で駆動＝台帳ごとに差し替える） ──
    BDSTUB="$BATS_TEST_TMPDIR/bd-stub.sh"
    cat > "$BDSTUB" <<'BDEOF'
#!/usr/bin/env bash
# 本 core が発行する read は `list --limit 0 --json` と `list --status closed --limit 0 --json` の 2 種のみ。
case "$*" in
  *"--status closed"*) printf '%s' "${BD_STUB_CLOSED_JSON:-[]}" ;;
  *"list"*)            printf '%s' "${BD_STUB_ACTIVE_JSON:-[]}" ;;
  *)                   printf '%s' '[]' ;;
esac
BDEOF
    chmod +x "$BDSTUB"

    # ── 既定 fixture: 台帳 sc の anchor + WM 群 ──
    ANCHOR="$BATS_TEST_TMPDIR/proj-sc"
    make_ledger "$ANCHOR" "sc"
    WMDIR="$ANCHOR/.claude-session"
    mkdir -p "$WMDIR"

    # current sid の WM: sc-aaa を in_progress と主張（bd stub は closed を返す＝drift）。
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
---
externalized_at: "2026-07-15"
trigger: manual
lifecycle: temporary
---

## 計画弧・次のステップ
- sc-8eyw を実装中

## この effort を貫く命令・制約
- [auto] sc-aaa を in_progress で継続実装
WMEOF

    # orphan fixtures（★ sidDONE の期待は参照実装と **逆**＝F1 のバグ修正）:
    printf 'x\n' > "$WMDIR/working-memory.sidORPHAN.md"                     # 別 sid・consumed 無 → 検出
    printf 'x\n' > "$WMDIR/working-memory.sidDONE.md"                       # 別 sid・consumed 併存 → ★検出（修正後）
    printf 'x\n' > "$WMDIR/working-memory.sidDONE.consumed.md"
    printf 'x\n' > "$WMDIR/working-memory.sidCONSUMED.consumed.md"          # consumed のみ（.md 無）→ 非検出
    printf 'x\n' > "$WMDIR/working-memory.sidARCH.archived-superseded"      # 非標準 suffix → 非検出

    MARKER="$BATS_TEST_TMPDIR/marker"   # 既定は不在（normal）

    # bd stub の既定応答（台帳 sc）: sc-aaa=closed / sc-bbb=in_progress。
    export BD_STUB_CLOSED_JSON='[{"id":"sc-aaa","status":"closed"}]'
    export BD_STUB_ACTIVE_JSON='[{"id":"sc-bbb","status":"in_progress"}]'
}

# make_ledger <dir> <dolt_database>: 合成 .beads/metadata.json を持つ台帳 root を作る。
make_ledger() {
    mkdir -p "$1/.beads"
    printf '{"dolt_database":"%s"}' "$2" > "$1/.beads/metadata.json"
}

# seam 付きで機械層 script を駆動（stdin は塞ぐ＝sid は seam 指定）。
run_fetch() {
    run env \
        SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
}

# ─────────────────────────── 構文 ───────────────────────────

@test "(syntax) scribe-rebrief-fetch.sh が bash -n を通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "(syntax) script が実行可能ビットを持つ" {
    [ -x "$SCRIPT" ]
}

# ────────────────── (1) WM主張 ↔ bd現在値 diff ──────────────────

@test "(1a) diff-drift: WM=in_progress ↔ bd=closed の乖離を surface" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
    [[ "$output" == *"[DIFF-COUNT] 乖離=1 件"* ]]
}

@test "(1b) diff-equal mutation: WM を closed 主張へ変えると乖離が消える（非空虚）" {
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] sc-aaa は closed 済み
WMEOF
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"[DIFF-DRIFT] sc-aaa"* ]]
    [[ "$output" == *"[DIFF-OK] sc-aaa WM=closed bd=closed"* ]]
    [[ "$output" == *"[DIFF-NONE]"* ]]
}

@test "(1c) diff-mention: status 語の無い言及は DRIFT でなく MENTION" {
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] sc-bbb の設計方針を維持する
WMEOF
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-MENTION] sc-bbb WM=（status語なし・言及のみ） bd=in_progress"* ]]
    [[ "$output" == *"[DIFF-NONE]"* ]]
}

@test "(1e) diff: 先行の言及のみ行が後続の status 主張を握り潰さない（first-wins dedup の fail-open 封じ）" {
    # dedup の意図は「id ごとに 1 回 report」であって「status 主張 < 言及」ではない。素朴な行順 first-wins だと
    # 先行の mention 行が id を焼き付け、実在する DRIFT（WM=in_progress ↔ bd=closed）が沈黙して
    # [DIFF-NONE] 乖離なし を名乗る＝boot path で brief が積極的に嘘をつく。
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] sc-aaa の設計方針を維持する
- [auto] sc-aaa は in_progress で継続実装
WMEOF
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
    [[ "$output" == *"[DIFF-COUNT] 乖離=1 件"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
    # 「id ごとに 1 回」は保つ（二重報告に退行しない）。
    [ "$(printf '%s\n' "$output" | grep -c 'sc-aaa')" -eq 1 ]
}

@test "(1f) diff: 散文語からの部分一致で存在しない bead を捏造しない（語境界・prefix=un 台帳）" {
    # grep -oE "${SELF_PREFIX}-[a-z0-9]+" は語境界を持たないため、SELF_PREFIX がより長いトークンの末尾に
    # 現れると部分一致する（実測: `run-tests` → `un-tests`）。`run-` は工学散文で頻出し un は実在台帳ゆえ
    # 空想でなく発火する。捏造 DRIFT は brief に載って admin に存在しない bead を追わせる。
    ANCHOR="$BATS_TEST_TMPDIR/proj-un"
    make_ledger "$ANCHOR" "un"
    WMDIR="$ANCHOR/.claude-session"; mkdir -p "$WMDIR"
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] run-tests を完了させる
- [auto] fun-facts は触らない
- [auto] misc-notes と disc-log は対象外
WMEOF
    export BD_STUB_CLOSED_JSON='[]'
    export BD_STUB_ACTIVE_JSON='[]'
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[LEDGER] un（"* ]]
    # 散文語は 1 件も bead id として拾われない。
    [[ "$output" != *"un-tests"* ]]
    [[ "$output" != *"un-facts"* ]]
    [[ "$output" != *"[DIFF-DRIFT]"* ]]
    [[ "$output" != *"[DIFF-MENTION]"* ]]
    [[ "$output" == *"[DIFF-NONE]"* ]]
}

@test "(1g) diff: 語境界を課しても実 bead id は区切り文字の直後で拾える（過剰縮小の裏 assert）" {
    # (1f) の boundary 修正が「id を拾わなくなる」方向へ効きすぎていないことの teeth。
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] (sc-aaa) は in_progress、**sc-bbb** も継続
WMEOF
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
    [[ "$output" == *"sc-bbb"* ]]
}

@test "(1d) diff: WM が言及する bead が bd に無ければ 未検出 DRIFT" {
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] sc-zzz を実装中
WMEOF
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-DRIFT] sc-zzz WM=in_progress bd=未検出"* ]]
}

# ────────────────── (2) orphan WM（F1 のバグ修正） ──────────────────

@test "(2a) ★orphan: consumed sibling が併存していても未 consumed の .md を検出（F1 修正・参照実装は握り潰していた）" {
    # 参照実装（orch-resume-fetch.sh:479）は .consumed.md sibling 既在で continue し sidDONE.md を silent mask した。
    # consume は mv ゆえ plain .md の存在自体が「再外部化された未 consume 内容」の証拠＝検出が正。
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ORPHAN-WM] working-memory.sidDONE.md"* ]]
}

@test "(2b) orphan: 別 sid・consumed 無しを検出（既存挙動の回帰）" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ORPHAN-WM] working-memory.sidORPHAN.md"* ]]
}

@test "(2c) orphan 回帰: current sid / consumed のみ / 非標準 suffix は非検出" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"[ORPHAN-WM] working-memory.$CUR.md"* ]]
    [[ "$output" != *"[ORPHAN-WM] working-memory.sidCONSUMED.consumed.md"* ]]
    [[ "$output" != *"sidARCH"* ]]
}

@test "(2d) orphan count: 検出は sidORPHAN と sidDONE の 2 件（F1 修正で 1→2）" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ORPHAN-COUNT] orphan=2 件"* ]]
}

@test "(2e) orphan mutation: orphan .md を全て除去 → ORPHAN-NONE（非空虚）" {
    rm -f "$WMDIR/working-memory.sidORPHAN.md" "$WMDIR/working-memory.sidDONE.md"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ORPHAN-NONE]"* ]]
    [[ "$output" != *"[ORPHAN-WM]"* ]]
}

@test "(2f) orphan mutation: sidDONE の .md だけ除去 → consumed sibling が残っても非検出" {
    # F1 修正が「sibling を無視する」であって「consumed 自体を orphan 化する」ではないことの teeth。
    rm -f "$WMDIR/working-memory.sidDONE.md"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"sidDONE"* ]]
    [[ "$output" == *"[ORPHAN-COUNT] orphan=1 件"* ]]
}

# ────────────────── (3) auto-compact 強制回復 mode ──────────────────

@test "(3a) mode: marker 不在 → normal" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REBRIEF-MODE] normal"* ]]
}

@test "(3b) mode toggle: marker 有 → force-recovery（非空虚）" {
    : > "$MARKER"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[REBRIEF-MODE] force-recovery"* ]]
    [[ "$output" == *"auto-compact 発火 marker 検出"* ]]
}

# ────────────────── (4) consumed 化対象の特定 ──────────────────

@test "(4a) consume: current sid の WM 実在 → [CONSUME-TARGET] に mv 元/先を提示" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WM] file=$WMDIR/working-memory.$CUR.md found"* ]]
    [[ "$output" == *"[CONSUME-TARGET] $WMDIR/working-memory.$CUR.md → $WMDIR/working-memory.$CUR.consumed.md"* ]]
}

@test "(4b) consume mutation: current sid の WM 不在 → [CONSUME-NONE]（非空虚）" {
    rm -f "$WMDIR/working-memory.$CUR.md"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WM] file=$WMDIR/working-memory.$CUR.md missing"* ]]
    [[ "$output" == *"[CONSUME-NONE]"* ]]
}

@test "(4c) read-only 契約: fetch は consume しない（.md は mv されず consumed も作られない）" {
    run_fetch
    [ "$status" -eq 0 ]
    [ -f "$WMDIR/working-memory.$CUR.md" ]
    [ ! -e "$WMDIR/working-memory.$CUR.consumed.md" ]
}

# ────────── SELF_PREFIX の per-project walk-up 実測（F4 / F5・2 台帳 fixture） ──────────

@test "(P1) SELF_PREFIX walk-up: dolt_database=sc の台帳では sc- が母集団になる" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[LEDGER] sc（"* ]]
    [[ "$output" == *"[BD-COUNT] open=0 in_progress=1 blocked=0"* ]]
}

@test "(P2) SELF_PREFIX walk-up: dolt_database=ccs の別台帳では ccs- が母集団になる（定数 sc 流用なら落ちる）" {
    ANCHOR="$BATS_TEST_TMPDIR/proj-ccs"
    make_ledger "$ANCHOR" "ccs"
    WMDIR="$ANCHOR/.claude-session"; mkdir -p "$WMDIR"
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] ccs-aaa を in_progress で継続実装
WMEOF
    export BD_STUB_CLOSED_JSON='[{"id":"ccs-aaa","status":"closed"}]'
    export BD_STUB_ACTIVE_JSON='[{"id":"ccs-bbb","status":"in_progress"}]'
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[LEDGER] ccs（"* ]]
    [[ "$output" == *"[DIFF-DRIFT] ccs-aaa WM=in_progress bd=closed"* ]]
    [[ "$output" == *"[BD-COUNT] open=0 in_progress=1 blocked=0"* ]]
}

@test "(P3) SELF_PREFIX 束縛: ccs 台帳で bd が返す sc- bead は母集団に混ざらない（他台帳の誤集計を封じる）" {
    ANCHOR="$BATS_TEST_TMPDIR/proj-ccs2"
    make_ledger "$ANCHOR" "ccs"
    WMDIR="$ANCHOR/.claude-session"; mkdir -p "$WMDIR"
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] ccs-aaa を実装中
WMEOF
    # 連結 substrate の foreign copy を模す: bd が sc- と ccs- を混ぜて返す。
    export BD_STUB_CLOSED_JSON='[]'
    export BD_STUB_ACTIVE_JSON='[{"id":"ccs-aaa","status":"in_progress"},{"id":"sc-bbb","status":"open"},{"id":"sc-ccc","status":"open"}]'
    run_fetch
    [ "$status" -eq 0 ]
    # sc- 2 件は open だが自台帳(ccs)でないゆえ count に入らない。
    [[ "$output" == *"[BD-COUNT] open=0 in_progress=1 blocked=0"* ]]
    [[ "$output" == *"[DIFF-OK] ccs-aaa WM=in_progress bd=in_progress"* ]]
}

@test "(P4) SELF_PREFIX walk-up: 既定 anchor は cwd から .beads を walk-up して解決する（env 無し）" {
    sub="$ANCHOR/deep/nested"; mkdir -p "$sub"
    run env -u SCRIBE_REBRIEF_ANCHOR \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash -c "cd '$sub' && bash '$SCRIPT'" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ANCHOR] $ANCHOR"* ]]
    [[ "$output" == *"[LEDGER] sc（"* ]]
    # WM_DIR 既定（<ANCHOR>/.claude-session）へ pin されるので current WM を拾う。
    [[ "$output" == *"[CONSUME-TARGET]"* ]]
}

# ────────────────── fail-loud 経路（F4 / F6 / F7・silent skip しない） ──────────────────

@test "(FL1) fail-loud: 台帳識別子（dolt_database）を確定できない → rc1 + FATAL（空 prefix で『乖離なし』を騙らない）" {
    bad="$BATS_TEST_TMPDIR/proj-nometa"; mkdir -p "$bad/.beads"   # .beads は在るが metadata.json 無し
    run env SCRIBE_REBRIEF_ANCHOR="$bad" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"dolt_database"* ]]
}

@test "(FL2) fail-loud: anchor（.beads を持つ root）を walk-up で解決できない → rc1 + FATAL" {
    outside="$BATS_TEST_TMPDIR/outside"; mkdir -p "$outside"
    run env -u SCRIBE_REBRIEF_ANCHOR \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        bash -c "cd '$outside' && bash '$SCRIPT'" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"anchor"* ]]
}

@test "(FL3) fail-loud: cc-session lib 不在 → rc1 + FATAL（silent skip で green にしない）" {
    run env SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$BATS_TEST_TMPDIR/no-such-lib" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"cc-session lib 不在"* ]]
}

# ────────────────── CLAUDE_CONFIG_DIR override 下の lib 解決（F7） ──────────────────

@test "(F7a) lib 解決: SCRIBE_REBRIEF_SESSION_LIB 無しでも CLAUDE_CONFIG_DIR 配下の lib を解決する" {
    cfg="$BATS_TEST_TMPDIR/altconfig"
    mkdir -p "$cfg/plugins/session/scripts/lib"
    cp "$CC_LIB/session-env.sh" "$CC_LIB/working-memory.sh" "$cfg/plugins/session/scripts/lib/"
    run env -u SCRIBE_REBRIEF_SESSION_LIB \
        CLAUDE_CONFIG_DIR="$cfg" \
        SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
}

@test "(FL4) fail-loud: bd 実体が不在 → rc1 + FATAL（BD-COUNT=0 / 乖離なし を騙らない）" {
    run env SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BATS_TEST_TMPDIR/no-such-bd" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"bd read 失敗"* ]]
    # 権威値を騙らないこと（これが本 test の眼目）。
    [[ "$output" != *"[BD-COUNT]"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
    [[ "$output" != *"bd=未検出"* ]]
}

@test "(FL5) fail-loud: bd が stderr + exit 1（dolt lock / DB 破損相当）→ rc1 + FATAL（stderr を要旨に含む）" {
    failbd="$BATS_TEST_TMPDIR/bd-fail.sh"
    cat > "$failbd" <<'EOF'
#!/usr/bin/env bash
echo "error: dolt: database locked" >&2
exit 1
EOF
    chmod +x "$failbd"
    run env SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$failbd" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"bd read 失敗"* ]]
    [[ "$output" == *"database locked"* ]]   # 握り潰さず原因を surface する
    [[ "$output" != *"[BD-COUNT]"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
}

@test "(FL6) fail-loud: bd が壊れた JSON を返す → rc1 + FATAL（parse 不能を空台帳に化けさせない）" {
    badbd="$BATS_TEST_TMPDIR/bd-badjson.sh"
    cat > "$badbd" <<'EOF'
#!/usr/bin/env bash
printf '%s' '{not json'
EOF
    chmod +x "$badbd"
    run env SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$badbd" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"parse できない"* ]]
    [[ "$output" != *"[BD-COUNT]"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
}

@test "(FL7) 空台帳は fail-loud に巻き込まない: bd が [] を返す → rc0 + BD-COUNT 全 0（正当な空）" {
    # fail-loud の判定が「出力の空虚さ」でなく rc / JSON 形状であることの teeth。
    # ここが落ちると新規台帳（bead 0 件）で rebrief が使えなくなる＝過剰 fail-closed の回帰検知。
    export BD_STUB_CLOSED_JSON='[]'
    export BD_STUB_ACTIVE_JSON='[]'
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[BD-COUNT] open=0 in_progress=0 blocked=0"* ]]
    # WM は sc-aaa を主張するが台帳が空＝真に未検出ゆえ DRIFT で正しい（bd 失敗と違い rc=0 で surface）。
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=未検出"* ]]
}

@test "(FL10) bd が rc=0 + stderr warning を出しても正常に DATA を出す（診断をデータチャネルへ混ぜない）" {
    # bd 1.1.0 は rc=0・正当 JSON のまま stderr へ良性 warning を出す（beads.role 未設定 / .beads perms 0775
    # ＝新規 project の既定状態）。`2>&1` で畳み込むと out が "warning:…\n[{…}]" になり rc gate を素通りして
    # jq が先頭 warning で落ち、健全な台帳なのに「parse できない＝台帳が壊れている」と誤診して rebrief が死ぬ。
    warnbd="$BATS_TEST_TMPDIR/bd-warn.sh"
    cat > "$warnbd" <<'EOF'
#!/usr/bin/env bash
echo "Warning: /x/.beads has permissions 0775 (recommended: 0700). Run: chmod 700 /x/.beads" >&2
echo "warning: beads.role not configured (GH#2950)." >&2
echo "Fix: git config beads.role maintainer" >&2
case "$*" in
  *"--status closed"*) printf '%s' "${BD_STUB_CLOSED_JSON:-[]}" ;;
  *"list"*)            printf '%s' "${BD_STUB_ACTIVE_JSON:-[]}" ;;
  *)                   printf '%s' '[]' ;;
esac
EOF
    chmod +x "$warnbd"
    run env SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$warnbd" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"FATAL"* ]]
    [[ "$output" == *"[BD-COUNT] open=0 in_progress=1 blocked=0"* ]]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
}

@test "(FL11) fail-loud: WM は在るが読めない → rc1 + FATAL（[DIFF-NONE] 乖離なし を騙らない）" {
    # `-f`（存在）だけを gate にすると、extract_effort_directives が「読めなかった」でも空文字 + rc=0 を
    # 返すため [DIFF-NONE] を権威値として名乗る＝header が名指しで禁じている fail-open。
    chmod 000 "$WMDIR/working-memory.$CUR.md"
    run_fetch
    chmod 644 "$WMDIR/working-memory.$CUR.md"   # 後続 test / cleanup のため戻す
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"読めない"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
    [[ "$output" != *"[DIFF-COUNT]"* ]]
}

@test "(FL8) fail-loud: cc-session lib は在るが extract_effort_directives 不在（版ずれ）→ rc1 + FATAL" {
    # file 可読性だけを見る gate では取り逃す modality。set -e 非適用ゆえ以前は rc127→空文字→[DIFF-NONE] を騙っていた。
    skew="$BATS_TEST_TMPDIR/skew-lib"; mkdir -p "$skew"
    cp "$CC_LIB/session-env.sh" "$skew/"
    printf '#!/usr/bin/env bash\n# 版ずれ模擬: extract_effort_directives を持たない working-memory.sh\n' > "$skew/working-memory.sh"
    run env SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$skew" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"extract_effort_directives"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
}

@test "(FL9) fail-loud: anchor 直下に metadata.json が無い → 祖先の別台帳へ束ねず rc1 + FATAL" {
    # mbx_resolve_self_db は metadata 無しの .beads/ を素通りして祖先へ walk-up する（mailbox-common.sh の仕様）。
    # anchor は「最初の .beads/」で止まるため、この非対称を放置すると祖先の FOREIGN 台帳へ母集団が束ねられる（F4 禁止）。
    parent="$BATS_TEST_TMPDIR/anc-parent"
    make_ledger "$parent" "FOREIGN"
    child="$parent/child"; mkdir -p "$child/.beads"   # .beads は在るが metadata.json 無し
    run env SCRIBE_REBRIEF_ANCHOR="$child" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"dolt_database"* ]]
    [[ "$output" != *"FOREIGN"* ]]       # 祖先台帳を自台帳として名乗らない
    [[ "$output" != *"[LEDGER]"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
}

# ────── respawn / `/clear`（sid 変化）経路: 突合していないを『乖離なし』と呼ばない ──────
# WM は sid で scope される（cc-session un-gcu）。`/clear` は session_id を変え（cc-session
# compaction-memory-model.md が verified と明記）、respawn は新プロセスゆえ a fortiori で新 sid。
# ＝「前 session の WM は在るのに current sid では exact 一致しない」は例外でなく **既定経路**。
# 旧実装はここで WM_CLAIMS="" のまま [DIFF-NONE] 乖離なし を emit し、実在する乖離を boot path で否認した。

@test "(R1) respawn: sid≠current の WM に真の乖離があっても [DIFF-NONE] 乖離なし を名乗らない" {
    # fixture: 既定の current WM（sc-aaa=in_progress 主張・bd=closed＝真の乖離）を「前 session の退避物」に見立て、
    # 新 sid で fetch する＝respawn 直後の実態。旧実装の出力は [WM] missing / [DIFF-NONE] 乖離なし だった。
    CUR="sessionB"        # respawn で sid が変わった
    run_fetch
    [ "$status" -eq 0 ]
    # 突合していないことを『乖離なし』と偽らない（本 test の眼目）。
    [[ "$output" != *"[DIFF-NONE]"* ]]
    [[ "$output" == *"[DIFF-UNKNOWN]"* ]]
    # 前 session の退避物を復元候補として surface する（読取りを止めない）。
    [[ "$output" == *"[WM-CANDIDATE] working-memory.sidCUR.md"* ]]
}

@test "(R2) respawn: 候補 sid で再 fetch すると実在 DRIFT が surface する（SKILL.md §2-b の回復手順が実効）" {
    # (R1) の候補 sid を SCRIBE_REBRIEF_SID に渡す＝skill が案内する回復手順そのもの。
    # ここが赤いと「候補は出るが突合する術が無い」＝復元 cycle が閉じない。
    CUR="sidCUR"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
    [[ "$output" != *"[DIFF-UNKNOWN]"* ]]
}

@test "(R3) respawn: 候補は mtime 降順（先頭が最新）で列挙する" {
    # 自分の古い pre-clear ファイルが並走 session の新しいファイルの陰に隠れる発見ギャップ（cc-session
    # un-gcu corr-2）を防ぐため全件返す。順序が壊れると skill が最初に読む候補を誤る。
    CUR="sessionB"
    touch -d '2020-01-01 00:00' "$WMDIR/working-memory.sidORPHAN.md"
    touch -d '2020-01-02 00:00' "$WMDIR/working-memory.sidDONE.md"
    touch -d '2020-01-03 00:00' "$WMDIR/working-memory.sidCUR.md"   # 最新
    run_fetch
    [ "$status" -eq 0 ]
    # 行頭 marker で引く（散文中の字面に引っかからないこと自体が消費側の契約）。
    first="$(printf '%s\n' "$output" | grep -E '^\[WM-CANDIDATE\] ' | head -n1)"
    [[ "$first" == *"working-memory.sidCUR.md"* ]]
    last="$(printf '%s\n' "$output" | grep -E '^\[WM-CANDIDATE\] ' | tail -n1)"
    [[ "$last" == *"working-memory.sidORPHAN.md"* ]]
    [ "$(printf '%s\n' "$output" | grep -cE '^\[WM-CANDIDATE\] ')" -eq 3 ]
}

@test "(R4) 新規 session: 未 consumed WM が 1 件も無ければ [WM-CANDIDATE-NONE]（過剰警告の裏 assert）" {
    # 「候補なし」と「候補が在るのに黙る」を弁別する teeth。真に新規なら skill は復元不要と要約してよい。
    rm -f "$WMDIR"/working-memory.*.md
    CUR="sessionB"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WM-CANDIDATE-NONE]"* ]]
    # 候補 marker を 1 行も出さない。**案内文の字面も含めて**出さない（marker を grep する消費側に
    # 「候補が在る」と誤読させないため＝FATAL 群と同じ「診断文に marker literal を書かない」規律）。
    [[ "$output" != *"[WM-CANDIDATE]"* ]]
    # 候補が無くても「突合していない」ことは変わらない＝『乖離なし』は名乗らない。
    [[ "$output" == *"[DIFF-UNKNOWN]"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
}

@test "(R5) WM found のときは [DIFF-NONE] を出せる（DIFF-UNKNOWN への過剰置換の裏 assert）" {
    # 「読めた上で主張が無い / 一致した」は正当に『乖離なし』＝UNKNOWN で塗り潰さない。
    cat > "$WMDIR/working-memory.$CUR.md" <<'WMEOF'
## この effort を貫く命令・制約
- [auto] sc-aaa は closed 済み
WMEOF
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" == *"[DIFF-NONE]"* ]]
    [[ "$output" != *"[DIFF-UNKNOWN]"* ]]
    [[ "$output" != *"[WM-CANDIDATE]"* ]]   # current WM が在るなら候補提示は不要（ノイズにしない）
}

# ────── WM dir の可読性（FL12/FL13・file 側 gate との対称化） ──────
# orphan scan は `[ -d ]` しか見ないと dir の可読性を検証せず、glob が展開されないまま
# [ORPHAN-NONE] を rc=0 で権威値として emit する（＝FL11 の dir 側 modality が丸ごと無防備だった）。

@test "(FL12) fail-loud: WM dir が読めない(000) → rc1 + FATAL（偽の全クリアを名乗らない）" {
    chmod 000 "$WMDIR"
    run_fetch
    chmod 755 "$WMDIR"   # 後続 test / cleanup のため戻す
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"WM dir"* ]]
    # disk 上には drift する WM も orphan も在る＝これらを名乗ったら偽の全クリア。
    [[ "$output" != *"[ORPHAN-NONE]"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
    [[ "$output" != *"[WM] "* ]]
}

@test "(FL13) fail-loud: WM dir が search-only(111) → rc1 + FATAL（[ORPHAN-NONE] だけが嘘になる経路）" {
    # (a) 000 と違い [WM] found / [DIFF-DRIFT] は正しく出るため、他の marker が健全に見えて誰も異常を疑わない
    # ＝000 より発見困難。glob だけが静かに空振りする。
    chmod 111 "$WMDIR"
    run_fetch
    chmod 755 "$WMDIR"
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"WM dir"* ]]
    [[ "$output" != *"[ORPHAN-NONE]"* ]]
}

@test "(FL14) WM dir が存在しないのは正当（missing と unreadable を弁別する・過剰 fail-closed の裏 assert）" {
    # 新規 project / 退避未実施では dir 自体が無い＝ここで死ぬと rebrief が使えなくなる。
    WMDIR="$BATS_TEST_TMPDIR/no-such-wm-dir"
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"FATAL"* ]]
    [[ "$output" == *"[WM] file=$WMDIR/working-memory.$CUR.md missing"* ]]
    [[ "$output" == *"[WM-CANDIDATE-NONE]"* ]]
}

# ────── JSON parser（jq / python3）の要件と degraded mode の廃止 ──────
# 粗 grep fallback は `paste - -` が TAB 区切りで出すのに受け手が IFS=' ' で read するため、id 側に
# "sc-aaa\tclosed" が丸ごと入り status が空になる（実測）→ 全 bead が捏造 DRIFT・BD-COUNT 全 0。
# lines は非空（TAB 連結ゴミ）ゆえ _parse_or_die は FATAL を出さない＝fail-loud 網の外側の欺瞞だった。

# minimal_path: jq/python3 を含まない最小 PATH を **絶対 path の symlink** で構成する。
# `command -v grep` は shell function を返し得るので使わない（dangling symlink による偽陽性の元）。
_make_minimal_path() {
    local bindir="$BATS_TEST_TMPDIR/minbin-$$"; rm -rf "$bindir"; mkdir -p "$bindir"
    local u p
    for u in bash sh env readlink dirname basename cat grep sed sort head tail tr mktemp rm timeout awk stat touch chmod cut wc paste date ls; do
        p="$(type -P "$u" 2>/dev/null)" || true
        [ -n "$p" ] && ln -sf "$p" "$bindir/$u"
    done
    printf '%s' "$bindir"
}

@test "(FL15) fail-loud: jq も python3 も PATH に無い → rc1 + FATAL（捏造 DRIFT / BD-COUNT=0 を騙らない）" {
    minbin="$(_make_minimal_path)"
    # 前提の健全性: この最小 PATH に jq/python3 が実際に居ないこと（居たら test が空虚になる）。
    [ ! -e "$minbin/jq" ]
    [ ! -e "$minbin/python3" ]
    run env -i PATH="$minbin" HOME="$HOME" TMPDIR="$BATS_TEST_TMPDIR" \
        SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        BD_STUB_ACTIVE_JSON="$BD_STUB_ACTIVE_JSON" \
        BD_STUB_CLOSED_JSON="$BD_STUB_CLOSED_JSON" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"FATAL"* ]]
    [[ "$output" == *"JSON parser"* ]]
    # 旧 degraded mode の症状を 1 つも出さないこと（これが本 test の眼目）。
    [[ "$output" != *"[BD-COUNT]"* ]]
    [[ "$output" != *"bd=未検出"* ]]
    [[ "$output" != *"[DIFF-NONE]"* ]]
}

@test "(FL16) python3 のみ（jq 不在）で jq baseline と同一の DATA を出す（2 段目 fallback を pin）" {
    minbin="$(_make_minimal_path)"
    p="$(type -P python3 2>/dev/null)"; [ -n "$p" ]
    ln -sf "$p" "$minbin/python3"
    [ ! -e "$minbin/jq" ]
    run env -i PATH="$minbin" HOME="$HOME" TMPDIR="$BATS_TEST_TMPDIR" \
        SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        BD_STUB_ACTIVE_JSON="$BD_STUB_ACTIVE_JSON" \
        BD_STUB_CLOSED_JSON="$BD_STUB_CLOSED_JSON" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    # (1a)/(P1) の jq baseline と完全一致する DATA（degraded しない）。
    [[ "$output" == *"[BD-COUNT] open=0 in_progress=1 blocked=0"* ]]
    [[ "$output" == *"[DIFF-DRIFT] sc-aaa WM=in_progress bd=closed"* ]]
}

@test "(FL17) core は粗 grep の JSON 近似 parse を持たない（degraded mode の非再導入）" {
    # `paste - -` による id→status の隣接仮定は key 順が違う出力で誤対応する残存リスクを持つ＝直しても残さない。
    run grep -nE '^[^#]*paste[[:space:]]+-' "$SCRIPT"
    [ "$status" -ne 0 ]
}

# ────────────────── seam の貫通防止（ambient env が pin に勝たない） ──────────────────

@test "(AMB) ambient WORKING_MEMORY_FILE が在っても anchor 側の WM を指す（seam 貫通の封じ）" {
    # session-env.sh は WORKING_MEMORY_FILE を ambient 優先で解決するため、unset しないと
    # [WM]/[CONSUME-TARGET] だけ foreign repo を指す split-brain になり、SKILL.md §4 の verbatim mv が
    # 「別 repo の WM を mv する」誤 write に化ける。
    other="$BATS_TEST_TMPDIR/other-repo"; mkdir -p "$other"
    printf 'ambient\n' > "$other/working-memory.OTHER.md"
    run env WORKING_MEMORY_FILE="$other/working-memory.OTHER.md" \
        WORKING_MEMORY_CONSUMED_FILE="$other/working-memory.OTHER.consumed.md" \
        SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        SCRIBE_REBRIEF_SESSION_LIB="$CC_LIB" \
        SCRIBE_REBRIEF_AUTOCOMPACT_MARKER="$MARKER" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 0 ]
    [[ "$output" != *"other-repo"* ]]                                    # foreign を一切指さない
    [[ "$output" == *"[WM] file=$WMDIR/working-memory.$CUR.md found"* ]]  # pin した anchor 側を指す
    [[ "$output" == *"[CONSUME-TARGET] $WMDIR/working-memory.$CUR.md → $WMDIR/working-memory.$CUR.consumed.md"* ]]
}

@test "(F7b) lib 解決: CLAUDE_CONFIG_DIR が lib を持たなければ rc1 + FATAL（\$HOME/.claude へ暗黙 fallback しない）" {
    cfg="$BATS_TEST_TMPDIR/emptyconfig"; mkdir -p "$cfg"
    run env -u SCRIBE_REBRIEF_SESSION_LIB \
        CLAUDE_CONFIG_DIR="$cfg" \
        SCRIBE_REBRIEF_ANCHOR="$ANCHOR" \
        SCRIBE_REBRIEF_WM_DIR="$WMDIR" \
        SCRIBE_REBRIEF_SID="$CUR" \
        SCRIBE_REBRIEF_BD="$BDSTUB" \
        bash "$SCRIPT" </dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"cc-session lib 不在"* ]]
    [[ "$output" == *"$cfg/plugins/session/scripts/lib"* ]]
}

# ────────────────── 層の fence（F3: overlay を持ち込まない） ──────────────────

@test "(F3) overlay 非混入: STALE / GREEN gate / gate-pending は core の DATA に出ない" {
    run_fetch
    [ "$status" -eq 0 ]
    [[ "$output" != *"[STALE]"* ]]
    [[ "$output" != *"[GATE]"* ]]
    [[ "$output" != *"gate-pending"* ]]
}

@test "(F3) 越境なし: core は scriptorium の path を参照しない" {
    # header の由来注記（行頭 # のコメント）のみ許容し、実行コードでの path 参照は禁止。
    run grep -nE '^[^#]*scriptorium' "$SCRIPT"
    [ "$status" -ne 0 ]
}

# ────────────────── skill の存在と最小規約 ──────────────────

@test "(skill) skills/rebrief/SKILL.md が在り frontmatter name=rebrief を持つ" {
    [ -f "$REPO/skills/rebrief/SKILL.md" ]
    run head -3 "$REPO/skills/rebrief/SKILL.md"
    [[ "$output" == *"name: rebrief"* ]]
}

@test "(skill) SKILL.md が fetch core を invoke し cc-session の enable 前提を明記する（F7）" {
    grep -qF "scripts/scribe-rebrief-fetch.sh" "$REPO/skills/rebrief/SKILL.md"
    grep -qF "user-scope" "$REPO/skills/rebrief/SKILL.md"
}

@test "(skill) SKILL.md の fetch 起動は \${CLAUDE_PLUGIN_ROOT} で解決する（人間向け placeholder を弾く）" {
    # scribe は per-project opt-in の user-scope plugin ゆえ、cwd 相対や "<scribe plugin root>" 等の
    # placeholder では他 project で verbatim 実行できず、LLM に path 推測の余地を与える（既存 skill は
    # consult/setup とも ${CLAUDE_PLUGIN_ROOT} で統一）。literal 部分一致だけの assert は placeholder を通すため teeth 化する。
    grep -qF '${CLAUDE_PLUGIN_ROOT}/scripts/scribe-rebrief-fetch.sh' "$REPO/skills/rebrief/SKILL.md"
    ! grep -qF '<scribe plugin root>' "$REPO/skills/rebrief/SKILL.md"
}

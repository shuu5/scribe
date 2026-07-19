#!/usr/bin/env bats
# tests/scenarios/orch-stale-scan.bats
#
# orch-stale-scan.sh（自台帳 orch- open の created_at ベース停滞 scan・bd orch-gg9q Leg B）の
# 決定的 hermetic テスト。orch-clean-state-probe.bats と同型で bd を PATH/env スタブに差し替え、実 script を
# 走らせて「3 クラス分類 / actionable のみ停滞 gate / defer 済み非計上 / completeness / mutation 非空虚」を assert する E2E。
#
# 検証する契約不変条件（acceptance (1)-(3) + fence [SCOPE]/[CLASSIFY]/[THRESHOLD]/[MAPPING]/[DEDUP]）:
#   (CLASS1..)  [CLASSIFY]: held→held-defer / courier,coord→tracker / for:*→tracker(mailbox) / follow-up,seam→held-defer
#               / deferred status→held-defer / label 無し→actionable(default)。curated allowlist の各枝を exercise。
#   (COMPOUND)  [MAPPING]: courier+follow-up compound は優先順で tracker（両属を単一クラスへ確定）。
#   (SCOPE)     [SCOPE]: foreign(pk-/un-) は SELF_PREFIX filter で母集団非混入（分類も停滞判定もしない）。
#   (STALE1)    [THRESHOLD]: actionable かつ created_at>14d → [STALE] 停滞疑い。
#   (STALE2)    [THRESHOLD]: actionable かつ created_at<14d → 非停滞。
#   (DEFER)     [THRESHOLD]: held/follow-up/seam は created_at が古くても M に非計上（既存検知線/再裁定が見張る）。
#   (ORDER)     [THRESHOLD] 順序: 先に classify → actionable クラスのみ年齢 gate（tracker 古くても非計上）。
#   (TRIP)      tripwire 集計行 open/actionable/held-defer/tracker/停滞疑い が母集団と一致。
#   (COMPLETE)  [CLASSIFY] completeness: 全件ちょうど 1 クラス（分類合計==total・COMPLETENESS-RED 非出現）。
#   (COUNT)     --emit-count は M の整数のみ（seam 用・compose 側が parse する契約）。
#   (MUT-A)     mutation 非空虚: 閾値巨大化 → 停滞 0（gate が実効）。
#   (MUT-B)     mutation 非空虚: now を未来へ → actionable 全件停滞（年齢計算が生きている）。
#   (UNKNOWN)   [CLASSIFY] parse 失敗融合禁止: created_at 解析不能な actionable → [STALE-UNKNOWN]・停滞に非計上。
#   (EMPTY)     open 0 件 → tripwire open:0・停滞疑い:0（空 graceful）。
#   (HGATE)     self-scope gate: foreign cwd（dolt_database≠orch）は refuse・exit1・分類テーブルを出さない。
#   (HGATE-SKIP) ORCH_STALE_SKIP_SESSION_GATE=1 で gate bypass（hermetic 用）。
#   (RO)        read-only verb discipline（無人実行で guard 射程外＝test が唯一のモート）: bd=list のみ
#               （show/update/create/close/label 等の非 read verb が出たら RED）。
#   (DRY)       --dry-run は plan のみ・bd を一切叩かない（read すらしない設計＝計画表示専任）。
#   (EXEC)      distribution: SCRIPT に実行ビット（bare path 単発起動）。
#   (SELFTEST)  本体 --self-test が green（内蔵 hermetic 検証の二重化）。

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-stale-scan.sh"
    TEST_TMPDIR=$(mktemp -d -t stale-scan-bats-XXXXXX)
    export FIX_DIR="$TEST_TMPDIR"
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"

    ANCHOR="$TEST_TMPDIR/anchor"
    mkdir -p "$ANCHOR/.beads"
    printf '{"dolt_database":"orch"}\n' > "$ANCHOR/.beads/metadata.json"

    # ── stub: bd（list --status open,deferred --json のみを想定）──
    #   全 argv を bd-invocations.log へ記録（RO discipline が list 以外の verb を RED 化）。
    #   STUB_ROWS（1 行 = id|status|labels_csv|created_at）を JSON 配列へ変換して emit。
    #   labels_csv="null" → labels:null（null 吸収を exercise）。
    #   ★--status <csv> を尊重して実 bd の相互排他 status 挙動を模す（指定 status の行のみ emit）。
    #     deferred 行は query が open,deferred を要求したときだけ返る＝deferred は deferred-scan 由来（母集団が
    #     --status open のみだと deferred は返らず、CLASS5(deferred status→held-defer) は現実の入力形で検証される）。
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/bd-invocations.log"
_statuses=""; _prev=""
for _a in "$@"; do
    [ "$_prev" = "--status" ] && { _statuses="$_a"; break; }
    _prev="$_a"
done
_in_status() { # $1=行 status（未指定 --status は全 status 許可）
    [ -z "$_statuses" ] && return 0
    local _s IFS=','
    for _s in $_statuses; do [ "$_s" = "$1" ] && return 0; done
    return 1
}
printf '['
first=1
while IFS='|' read -r id status labels created; do
    [ -n "$id" ] || continue
    _in_status "$status" || continue
    [ $first -eq 1 ] || printf ','
    first=0
    if [ "$labels" = "null" ]; then
        printf '{"id":"%s","status":"%s","labels":null,"created_at":"%s"}' "$id" "$status" "$created"
    else
        lj=""; IFS=',' read -ra la <<< "$labels"; lfirst=1
        for x in "${la[@]}"; do [ -n "$x" ] || continue; [ $lfirst -eq 1 ] || lj="$lj,"; lj="$lj\"$x\""; lfirst=0; done
        printf '{"id":"%s","status":"%s","labels":[%s],"created_at":"%s"}' "$id" "$status" "$lj" "$created"
    fi
done <<< "${STUB_ROWS:-}"
printf ']'
STUB
    chmod +x "$BIN/bd"

    # 代表 fixture（now=2026-07-20 基準・閾値 14d）: 3 クラス + foreign + compound + defer 済み。
    ROWS="orch-act-old|open||2026-07-01T00:00:00Z
orch-act-new|open||2026-07-18T00:00:00Z
orch-held|open|held|2026-06-01T00:00:00Z
orch-fu|open|follow-up|2026-06-01T00:00:00Z
orch-seam|open|seam|2026-06-01T00:00:00Z
orch-cour|open|courier|2026-06-01T00:00:00Z
orch-coord|open|coord|2026-06-01T00:00:00Z
orch-for|open|for:sc|2026-06-01T00:00:00Z
orch-cmp|open|courier,follow-up|2026-06-01T00:00:00Z
orch-defst|deferred||2026-06-01T00:00:00Z
orch-nulllab|open|null|2026-07-01T00:00:00Z
orch-foohd|open|foo,held|2026-06-01T00:00:00Z
orch-multiact|open|foo,bar|2026-07-01T00:00:00Z
pk-foreign|open||2026-06-01T00:00:00Z
un-foreign|open|held|2026-06-01T00:00:00Z"
    NOW="2026-07-20T00:00:00Z"
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# 共通 runner: report モード（既定 fixture ROWS/NOW を使う・追加 env は呼出側で export）。
run_scan() {
    ORCH_STALE_SKIP_SESSION_GATE=1 \
    ORCH_STALE_SCRIPTORIUM="$ANCHOR" \
    ORCH_STALE_BD="$BIN/bd" \
    ORCH_STALE_NOW="${NOW}" \
    STUB_ROWS="$ROWS" \
    run bash "$SCRIPT" "$@"
}

# ==============================================================================
# [CLASSIFY] 3 クラス分類（curated allowlist の各枝）
# ==============================================================================
@test "(CLASS1) held ラベル → held-defer" {
    run_scan
    [ "$status" -eq 0 ]
    [[ "$output" == *"[CLASS] orch-held"*"held-defer"*"held ラベル"* ]]
}

@test "(CLASS2) courier / coord → tracker-delegated" {
    run_scan
    [[ "$output" == *"[CLASS] orch-cour"*"tracker-delegated"*"courier ラベル"* ]]
    [[ "$output" == *"[CLASS] orch-coord"*"tracker-delegated"*"coord ラベル"* ]]
}

@test "(CLASS3) for:* → tracker-delegated（mailbox §5.3）" {
    run_scan
    [[ "$output" == *"[CLASS] orch-for"*"tracker-delegated"*"for:sc（mailbox"* ]]
}

@test "(CLASS4) follow-up / seam → held-defer" {
    run_scan
    [[ "$output" == *"[CLASS] orch-fu"*"held-defer"*"follow-up ラベル"* ]]
    [[ "$output" == *"[CLASS] orch-seam"*"held-defer"*"seam ラベル"* ]]
}

@test "(CLASS5) deferred status → held-defer（status 経路）" {
    run_scan
    [[ "$output" == *"[CLASS] orch-defst"*"held-defer"*"deferred status"* ]]
}

# 母集団が `--status open,deferred` を要求する回帰（deferred branch の到達性を lock-in）。
# status-aware な bd stub は deferred 行を「query が deferred を含む時だけ」返すため、母集団を `--status open` へ
# 退行させると orch-defst が返らず CLASS5 は落ちる＝deferred の held-defer 分類が vacuous に green 化しない teeth。
@test "(DEFERRED-POP) 母集団 query は --status open,deferred を要求する（deferred 到達性 lock-in）" {
    run_scan
    [ -f "$FIX_DIR/bd-invocations.log" ]
    grep -qE -- '--status open,deferred' "$FIX_DIR/bd-invocations.log"
    # deferred 行が実際に母集団へ入り held-defer として surface されている（到達性の end-to-end 確認）。
    [[ "$output" == *"[CLASS] orch-defst"*"held-defer"* ]]
}

@test "(CLASS6) label 無し / labels:null → actionable(default)" {
    run_scan
    [[ "$output" == *"[CLASS] orch-act-old"*"actionable"*"default"* ]]
    [[ "$output" == *"[CLASS] orch-nulllab"*"actionable"*"default"* ]]
}

# ==============================================================================
# [MAPPING] compound（両属を優先順で単一クラス化）
# ==============================================================================
@test "(COMPOUND) courier,follow-up compound → tracker(優先順・follow-up より前)" {
    run_scan
    # 該当 CLASS 行のみを取り出して単一クラス化を検査（output 全体跨ぎの誤マッチを避ける）。
    local line
    line=$(printf '%s\n' "$output" | grep '\[CLASS\] orch-cmp ')
    [[ "$line" == *"tracker-delegated"* ]]
    [[ "$line" != *"held-defer"* ]]
}

# ==============================================================================
# [SCOPE] foreign 非混入
# ==============================================================================
@test "(SCOPE) foreign(pk-/un-) は SELF_PREFIX filter で非検出" {
    run_scan
    [[ "$output" != *"pk-foreign"* ]]
    [[ "$output" != *"un-foreign"* ]]
    # tripwire の open 総数に foreign を数えていない（orch- のみ 13 件）
    [[ "$output" == *"[STALE-TRIPWIRE] open:13 "* ]]
}

# ==============================================================================
# [THRESHOLD] actionable のみ停滞 gate・順序・defer 非計上
# ==============================================================================
@test "(STALE1) actionable かつ created_at>14d → 停滞疑い" {
    run_scan
    [[ "$output" == *"[STALE] orch-act-old"*"⚠停滞疑い"* ]]
}

@test "(STALE2) actionable かつ created_at<14d → 非停滞" {
    run_scan
    [[ "$output" != *"[STALE] orch-act-new"* ]]
}

@test "(DEFER) held/follow-up/seam は created_at が古くても M 非計上" {
    run_scan
    [[ "$output" != *"[STALE] orch-fu"* ]]
    [[ "$output" != *"[STALE] orch-held"* ]]
    [[ "$output" != *"[STALE] orch-seam"* ]]
}

@test "(ORDER) tracker は created_at が古くても停滞 gate 適用外(先 classify)" {
    run_scan
    [[ "$output" != *"[STALE] orch-cour"* ]]
    [[ "$output" != *"[STALE] orch-for"* ]]
    [[ "$output" != *"[STALE] orch-cmp"* ]]
}

# ==============================================================================
# multi-label separator 衝突回帰（jq labels join が field 区切り | と衝突する bug の gap 塞ぎ）
# ==============================================================================
@test "(MULTI-HELD) allowlist label が非先頭の multi-label（foo,held）→ held-defer（actionable 誤分類しない）" {
    run_scan
    local line
    line=$(printf '%s\n' "$output" | grep '\[CLASS\] orch-foohd ')
    [[ "$line" == *"held-defer"* ]]
    [[ "$line" != *"actionable"* ]]
    # held/defer ゆえ停滞にも計上されない
    [[ "$output" != *"[STALE] orch-foohd"* ]]
}

@test "(MULTI-ACT) 非 allowlist 2 label の actionable（foo,bar・19d）→ created_at 破損せず停滞判定" {
    run_scan
    [[ "$output" == *"[CLASS] orch-multiact"*"actionable"* ]]
    [[ "$output" == *"[STALE] orch-multiact"*"⚠停滞疑い"* ]]
    # created_at が labels 混入で破損せず STALE-UNKNOWN へ落ちない
    [[ "$output" != *"[STALE-UNKNOWN] orch-multiact"* ]]
}

# ==============================================================================
# tripwire / completeness
# ==============================================================================
@test "(TRIP) tripwire 集計が母集団と一致（open:13 actionable:4 held-defer:5 tracker:4 停滞疑い:3）" {
    run_scan
    # orch- 13件: actionable=act-old,act-new,nulllab,multiact=4 / held-defer=held,fu,seam,defst,foohd=5 / tracker=cour,coord,for,cmp=4
    # 停滞疑い= actionable ∩ >14d = act-old(07-01,19d)+nulllab(07-01,19d)+multiact(07-01,19d)=3（act-new 07-18,2d は非停滞）
    [[ "$output" == *"[STALE-TRIPWIRE] open:13 actionable:4 held-defer:5 tracker:4 停滞疑い:3"* ]]
}

@test "(COMPLETE) completeness: 分類合計==total（COMPLETENESS-RED 非出現）" {
    run_scan
    [[ "$output" != *"COMPLETENESS-RED"* ]]
}

# ==============================================================================
# --emit-count（seam 用）
# ==============================================================================
@test "(COUNT) --emit-count は M の整数のみ" {
    run_scan --emit-count
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

# ==============================================================================
# mutation 非空虚
# ==============================================================================
@test "(MUT-A) 閾値巨大化 → 停滞 0（gate 実効）" {
    ORCH_STALE_THRESHOLD_DAYS=9999
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" ORCH_STALE_THRESHOLD_DAYS=9999 STUB_ROWS="$ROWS" \
        run bash "$SCRIPT" --emit-count
    [ "$output" = "0" ]
}

@test "(MUT-B) now を未来へ → actionable 全件停滞（年齢計算が生きている）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="2026-09-01T00:00:00Z" STUB_ROWS="$ROWS" \
        run bash "$SCRIPT" --emit-count
    # actionable 4件（act-old/act-new/nulllab/multiact）とも >14d → 4
    [ "$output" = "4" ]
}

# ==============================================================================
# [CLASSIFY] parse 失敗融合禁止
# ==============================================================================
@test "(UNKNOWN) created_at 解析不能な actionable → STALE-UNKNOWN・停滞に非計上" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="orch-bad|open||not-a-date" \
        run bash "$SCRIPT"
    [[ "$output" == *"[STALE-UNKNOWN] orch-bad"* ]]
    [[ "$output" != *"[STALE] orch-bad "* ]]
    [[ "$output" == *"停滞疑い:0"* ]]
    [[ "$output" == *"age不明:1"* ]]
}

# ==============================================================================
# 空 graceful
# ==============================================================================
@test "(EMPTY) open 0 件 → open:0・停滞疑い:0（空 graceful）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="" \
        run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STALE-TRIPWIRE] open:0 actionable:0 held-defer:0 tracker:0 停滞疑い:0"* ]]
}

# ==============================================================================
# self-scope gate
# ==============================================================================
@test "(HGATE) foreign cwd（dolt_database≠orch）は refuse・exit1・分類テーブル非出力" {
    FOREIGN="$TEST_TMPDIR/foreign"; mkdir -p "$FOREIGN/.beads"
    printf '{"dolt_database":"un"}\n' > "$FOREIGN/.beads/metadata.json"
    run env ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" STUB_ROWS="$ROWS" \
        bash -c "cd '$FOREIGN' && exec bash '$SCRIPT'"
    [ "$status" -eq 1 ]
    [[ "$output" != *"[CLASS]"* ]]
    [[ "$output" == *"refusing to run"* ]]
}

@test "(HGATE-SKIP) SKIP=1 で gate bypass（分類テーブルを出す）" {
    FOREIGN="$TEST_TMPDIR/foreign2"; mkdir -p "$FOREIGN/.beads"
    printf '{"dolt_database":"un"}\n' > "$FOREIGN/.beads/metadata.json"
    run env ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$ROWS" bash -c "cd '$FOREIGN' && exec bash '$SCRIPT'"
    [[ "$output" == *"[STALE-TRIPWIRE]"* ]]
}

# ==============================================================================
# read-only verb discipline
# ==============================================================================
@test "(RO) bd 呼出は list のみ（show/update/create/close/label 等の非 read verb 非出現）" {
    run_scan
    [ -f "$FIX_DIR/bd-invocations.log" ]
    # 全 bd 呼出が "list" を含む
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ "$line" == *"list"* ]]
    done < "$FIX_DIR/bd-invocations.log"
    # 破壊 verb が一切出ていない
    ! grep -qE '(^| )(update|create|close|dep|assign|delete|import|dolt) ' "$FIX_DIR/bd-invocations.log"
    ! grep -qE -- '--add-label|--label ' "$FIX_DIR/bd-invocations.log"
}

@test "(DRY) --dry-run は bd を一切叩かない（plan のみ）" {
    rm -f "$FIX_DIR/bd-invocations.log"
    run_scan --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [ ! -f "$FIX_DIR/bd-invocations.log" ]
}

# ==============================================================================
# distribution / 内蔵検証
# ==============================================================================
@test "(EXEC) SCRIPT に実行ビット（bare path 単発起動）" {
    [ -x "$SCRIPT" ]
}

@test "(SELFTEST) 本体 --self-test が green" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(BASHN) bash -n（構文健全性）" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

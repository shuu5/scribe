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
    #   STUB_ROWS（1 行 = id|status|labels_csv|created_at[|title]）を JSON 配列へ変換して emit。
    #   title は任意 5 列目（re-ratify 表示用・省略時空）。labels_csv="null" → labels:null（null 吸収を exercise）。
    #   ★--status <csv> を尊重して実 bd の相互排他 status 挙動を模す（指定 status の行のみ emit）。
    #     deferred 行は query が open,deferred を要求したときだけ返る＝deferred は deferred-scan 由来（母集団が
    #     --status open のみだと deferred は返らず、CLASS5(deferred status→held-defer) は現実の入力形で検証される）。
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/bd-invocations.log"
[ -n "${BD_FAIL:-}" ] && exit 1
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
while IFS='|' read -r id status labels created title; do
    [ -n "$id" ] || continue
    _in_status "$status" || continue
    [ $first -eq 1 ] || printf ','
    first=0
    if [ "$labels" = "null" ]; then
        printf '{"id":"%s","status":"%s","labels":null,"created_at":"%s","title":"%s"}' "$id" "$status" "$created" "$title"
    else
        lj=""; IFS=',' read -ra la <<< "$labels"; lfirst=1
        for x in "${la[@]}"; do [ -n "$x" ] || continue; [ $lfirst -eq 1 ] || lj="$lj,"; lj="$lj\"$x\""; lfirst=0; done
        printf '{"id":"%s","status":"%s","labels":[%s],"created_at":"%s","title":"%s"}' "$id" "$status" "$lj" "$created" "$title"
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

    # re-ratify 死角クラス fixture（now=2026-07-20・reratify threshold=7d・title 付き行あり）。
    #   target（死角クラス ∩ age>7d）: cour/held/seam/fu/coord/defst/courfor/bell = 8
    #   excluded: ng(needs-grill 併存)/fed(federate-publish 併存)/act(actionable)/foronly(for:* 単独)
    #   age gate 落ち: fresh(courier だが 2d<7)  / foreign: pk-rr
    RR_ROWS="orch-rr-cour|open|courier|2026-07-01T00:00:00Z|配送後に長期 open な courier bead
orch-rr-held|open|held|2026-07-01T00:00:00Z|人間 re-ratify 待ち held
orch-rr-seam|open|seam|2026-07-01T00:00:00Z
orch-rr-fu|open|follow-up|2026-07-01T00:00:00Z
orch-rr-coord|open|coord|2026-07-01T00:00:00Z
orch-rr-defst|deferred||2026-07-01T00:00:00Z
orch-rr-courfor|open|courier,for:sc|2026-07-01T00:00:00Z
orch-rr-bell|open|held,needs-user|2026-07-01T00:00:00Z|人間判断が要る held
orch-rr-ng|open|needs-grill,held|2026-07-01T00:00:00Z
orch-rr-fed|open|federate-publish,courier|2026-07-01T00:00:00Z
orch-rr-act|open||2026-07-01T00:00:00Z
orch-rr-foronly|open|for:sc|2026-07-01T00:00:00Z
orch-rr-fresh|open|courier|2026-07-18T00:00:00Z
pk-rr|open|courier|2026-07-01T00:00:00Z"
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
# [RE-RATIFY] 死角クラス re-ratify sweep（bd orch-cqf4 Leg-A・別軸・別閾値 7d・別表示）
# ==============================================================================

# re-ratify モード runner（RR_ROWS/NOW を使う・追加 env は呼出側で export）。
run_reratify() {
    ORCH_STALE_SKIP_SESSION_GATE=1 \
    ORCH_STALE_SCRIPTORIUM="$ANCHOR" \
    ORCH_STALE_BD="$BIN/bd" \
    ORCH_STALE_NOW="${NOW}" \
    STUB_ROWS="$RR_ROWS" \
    run bash "$SCRIPT" "$@"
}

@test "(RR-HEADER) --re-ratify は「re-ratify sweep（死角クラス）」header を出す（stale 用語と非衝突）" {
    run_reratify --re-ratify
    [ "$status" -eq 0 ]
    [[ "$output" == *"re-ratify sweep（死角クラス）"* ]]
}

@test "(RR-TARGET) 死角クラス（courier/held/seam/follow-up/coord∨deferred）∩ age>7d を surface" {
    run_reratify --re-ratify
    [[ "$output" == *"[RERATIFY] orch-rr-cour"*"(courier)"* ]]
    [[ "$output" == *"[RERATIFY] orch-rr-held"*"(held)"* ]]
    [[ "$output" == *"[RERATIFY] orch-rr-seam"*"(seam)"* ]]
    [[ "$output" == *"[RERATIFY] orch-rr-fu"*"(follow-up)"* ]]
    [[ "$output" == *"[RERATIFY] orch-rr-coord"*"(coord)"* ]]
    [[ "$output" == *"[RERATIFY] orch-rr-defst"*"(deferred)"* ]]
}

@test "(RR-COURFOR) courier∩for:* は re-ratify に含める（override ii・配送後長期 open こそ穴の実体）" {
    run_reratify --re-ratify
    [[ "$output" == *"[RERATIFY] orch-rr-courfor"*"(courier)"* ]]
}

@test "(RR-BELL) needs-user 併存 bead に呼び鈴対象マーク（push はしない）" {
    run_reratify --re-ratify
    local line
    line=$(printf '%s\n' "$output" | grep 'orch-rr-bell')
    [[ "$line" == *"🔔呼び鈴対象"* ]]
    [[ "$line" == *"push はしない"* ]]
}

@test "(RR-TITLE) title 冒頭を per-bead 行へ表示" {
    run_reratify --re-ratify
    [[ "$output" == *"配送後に長期 open な courier bead"* ]]
}

@test "(RR-EXCL-LIVE) needs-grill/needs-orch/federate-publish/reconcile-published 併存は除外（二重 surface 禁止）" {
    run_reratify --re-ratify
    [[ "$output" != *"orch-rr-ng"* ]]                 # needs-grill 併存 → 除外優先 first-match
    [[ "$output" != *"orch-rr-fed"* ]]                # federate-publish 併存 → 除外
}

@test "(RR-EXCL-ACT) actionable 域 / for:* 単独は re-ratify 対象外（for:* は除外条件にしない側の裏）" {
    run_reratify --re-ratify
    [[ "$output" != *"orch-rr-act"* ]]                # label 無し actionable → 対象外
    [[ "$output" != *"orch-rr-foronly"* ]]            # for:* 単独 → 対象外
}

@test "(RR-AGEGATE) 死角クラスでも age<7d は非 surface（reratify 閾値 gate 実効）" {
    run_reratify --re-ratify
    [[ "$output" != *"orch-rr-fresh"* ]]              # courier だが 2d<7d
}

@test "(RR-SCOPE) foreign（pk-）は SELF_PREFIX filter で非検出" {
    run_reratify --re-ratify
    [[ "$output" != *"pk-rr"* ]]
}

@test "(RR-TRIP) re-ratify tripwire 候補数が母集団と一致（8）" {
    run_reratify --re-ratify
    [[ "$output" == *"[RERATIFY-TRIPWIRE] 死角クラス re-ratify 候補:8"* ]]
}

@test "(RR-COUNT) --emit-reratify-count は候補の整数のみ（--emit-count と別 seam）" {
    run_reratify --emit-reratify-count
    [ "$status" -eq 0 ]
    [ "$output" = "8" ]
}

@test "(RR-SEAM-SEPARATION) 同一母集団で --emit-count(actionable stale) と --emit-reratify-count(死角) は別軸" {
    # RR_ROWS の actionable stale は orch-rr-act(07-01,19d>14) の 1 件のみ＝emit-count=1（re-ratify 8 と別）。
    run_reratify --emit-count
    [ "$output" = "1" ]
}

@test "(RR-MUT-THRESHOLD) reratify 閾値巨大化 → 候補 0（死角 gate が実効・mutation 非空虚）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" ORCH_STALE_RERATIFY_THRESHOLD_DAYS=9999 STUB_ROWS="$RR_ROWS" \
        run bash "$SCRIPT" --emit-reratify-count
    [ "$output" = "0" ]
}

@test "(RR-THRESHOLD-INDEP) reratify 閾値は STALE_THRESHOLD_DAYS を流用しない（別 env・独立）" {
    # STALE_THRESHOLD_DAYS を 9999 にしても re-ratify 候補は不変（8）＝閾値が独立している teeth。
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" ORCH_STALE_THRESHOLD_DAYS=9999 STUB_ROWS="$RR_ROWS" \
        run bash "$SCRIPT" --emit-reratify-count
    [ "$output" = "8" ]
}

@test "(RR-UNKNOWN) created_at 解析不能な死角クラス → RERATIFY-UNKNOWN・候補に非計上" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="orch-rrbad|open|courier|not-a-date" \
        run bash "$SCRIPT" --re-ratify
    [[ "$output" == *"[RERATIFY-UNKNOWN] orch-rrbad"* ]]
    [[ "$output" != *"[RERATIFY] orch-rrbad "* ]]
    [[ "$output" == *"re-ratify 候補:0"* ]]
    [[ "$output" == *"age不明:1"* ]]
}

@test "(RR-NONE) 死角クラス 0 件 → RERATIFY-NONE・tripwire 候補:0（空 graceful）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="orch-onlyact|open||2026-07-01T00:00:00Z" \
        run bash "$SCRIPT" --re-ratify
    [ "$status" -eq 0 ]
    [[ "$output" == *"[RERATIFY-NONE]"* ]]
    [[ "$output" == *"[RERATIFY-TRIPWIRE] 死角クラス re-ratify 候補:0"* ]]
}

# jq だけを不在にした PATH（symlink farm）を $TEST_TMPDIR/nojq へ組む（bash 等の実 tool は温存し jq のみ除外）。
#   PATH=$BIN だけだと bash/readlink/dirname 等が見つからず exit127 になるため、必要 tool を実体へ symlink する。
_build_nojq_path() {
    local nojq="$TEST_TMPDIR/nojq"; mkdir -p "$nojq"
    local t p
    for t in bash env date sort cut grep awk sed mktemp readlink dirname cat head tail tr basename printf; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$nojq/$t"
    done
    printf '%s' "$BIN:$nojq"   # bd stub は $BIN・実 tool は nojq・jq はどちらにも無い
}

@test "(RR-FAILOPEN-JQ) jq 不在でも --re-ratify は fail-open（exit 0・判定不能 note）" {
    local p; p="$(_build_nojq_path)"
    run env PATH="$p" ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" \
        ORCH_STALE_BD="$BIN/bd" ORCH_STALE_NOW="$NOW" STUB_ROWS="$RR_ROWS" \
        bash "$SCRIPT" --re-ratify
    [ "$status" -eq 0 ]                               # 既存モードは fail-closed(exit1)・re-ratify は fail-open
    [[ "$output" == *"判定不能"* ]]
}

@test "(RR-FAILOPEN-JQ-COUNT) jq 不在の --emit-reratify-count は無出力（整数不能時契約）・exit 0" {
    local p; p="$(_build_nojq_path)"
    run env PATH="$p" ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" \
        ORCH_STALE_BD="$BIN/bd" ORCH_STALE_NOW="$NOW" STUB_ROWS="$RR_ROWS" \
        bash "$SCRIPT" --emit-reratify-count
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                 # 整数不能時 無出力
}

@test "(RR-FAILOPEN-JQ-CLOSED) 既存モード(report)は jq 不在で fail-closed(exit1)＝re-ratify fail-open の非対称 pin" {
    local p; p="$(_build_nojq_path)"
    run env PATH="$p" ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" \
        ORCH_STALE_BD="$BIN/bd" ORCH_STALE_NOW="$NOW" STUB_ROWS="$RR_ROWS" \
        bash "$SCRIPT"
    [ "$status" -eq 1 ]                               # report/count/dry は従来どおり fail-closed（byte 不変）
    [[ "$output" == *"fail-closed"* ]] || [[ "$output" == *"jq が PATH に無い"* ]]
}

@test "(RR-FAILOPEN-NOW) now 解決不能（date 障害）→ run_reratify fail-open exit 0・判定不能 note" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="totally-not-a-valid-date" STUB_ROWS="$RR_ROWS" \
        run bash "$SCRIPT" --re-ratify
    [ "$status" -eq 0 ]
    [[ "$output" == *"判定不能"* ]]
}

@test "(RR-FAILOPEN-NOW-COUNT) now 解決不能の --emit-reratify-count は無出力・exit 0（date 障害 × count 分岐）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="totally-not-a-valid-date" STUB_ROWS="$RR_ROWS" \
        run bash "$SCRIPT" --emit-reratify-count
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(RR-FAILOPEN-BD) bd read 失敗（BD_FAIL）→ 判定不能 note・RERATIFY-NONE へ silent 畳まない（bd/空台帳を弁別）" {
    # acceptance(7) は bd 失敗を fail-open 明示列挙。bd outage を『候補なし(RERATIFY-NONE)』と混同すると
    #   re-ratify sweep の目的（silent 滞留検出）と自己矛盾する＝bd rc 弁別の teeth。slate --surface と対称。
    BD_FAIL=1 ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$RR_ROWS" \
        run bash "$SCRIPT" --re-ratify
    [ "$status" -eq 0 ]                               # fail-open（brick しない）
    [[ "$output" == *"判定不能（bd read 失敗"* ]]
    [[ "$output" != *"[RERATIFY-NONE]"* ]]            # bd 失敗を空台帳へ silent 畳み込みしない
}

@test "(RR-FAILOPEN-BD-COUNT) bd read 失敗の --emit-reratify-count は無出力・exit 0（整数不能時契約）" {
    BD_FAIL=1 ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$RR_ROWS" \
        run bash "$SCRIPT" --emit-reratify-count
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(RR-BD-VS-EMPTY) bd 正常・空台帳は RERATIFY-NONE（bd 失敗との弁別が空虚でない＝mutation 非空虚）" {
    # BD_FAIL 無し・死角クラス 0 件 → RERATIFY-NONE（判定不能 と別）。BD_FAIL 版(RR-FAILOPEN-BD)と対で
    #   「rc≠0 のときだけ判定不能へ落ちる」ことを pin（rc 弁別を no-op 化した mutant は両者を混同して赤化）。
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="orch-onlyact|open||2026-07-01T00:00:00Z" \
        run bash "$SCRIPT" --re-ratify
    [ "$status" -eq 0 ]
    [[ "$output" == *"[RERATIFY-NONE]"* ]]
    [[ "$output" != *"判定不能"* ]]                   # 空台帳は「判定不能」ではない（bd rc=0）
}

@test "(RR-RO) re-ratify の bd 呼出も list のみ（write verb 非出現・surfacing 専任）" {
    rm -f "$FIX_DIR/bd-invocations.log"
    run_reratify --re-ratify
    [ -f "$FIX_DIR/bd-invocations.log" ]
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ "$line" == *"list"* ]]
    done < "$FIX_DIR/bd-invocations.log"
    ! grep -qE '(^| )(update|create|close|dep|assign|delete|import|dolt) ' "$FIX_DIR/bd-invocations.log" || false
    ! grep -qE -- '--add-label|--label ' "$FIX_DIR/bd-invocations.log"
}

@test "(RR-BYTE-INVARIANT) --re-ratify は既存 [STALE-TRIPWIRE] 行を出さない（別 tripwire＝既存出力を perturbate しない）" {
    run_reratify --re-ratify
    [[ "$output" != *"[STALE-TRIPWIRE]"* ]]          # 停滞 scan の tripwire は re-ratify モードに漏れない
    [[ "$output" != *"[CLASS]"* ]]                   # 分類テーブルも出さない（別軸別表示）
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

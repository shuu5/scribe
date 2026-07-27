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
#   (TW-*)      --emit-tripwire seam（bd orch-myn0）: 1 行のみ emit / report 行と byte 一致（同一 pass＝二重実装でない）
#               / **bd 呼出は 1 回・report と同数（＝呼出増ゼロ）を invocation log の行数で直接 pin する（TW-ONEPASS）
#               ＝byte 一致だけでは決定論 fixture 下で二重 pass 実装が素通りするため、契約の中核をここで赤化させる**
#               / age不明 付き形 / jq 不在は fail-closed（reratify 群の fail-open へ混ぜない）/ 既存 --emit-count・report を
#               perturbate しない / bd=list のみ / usage 列挙 / **bd read 失敗（BD_FAIL）も jq parse 失敗
#               （BD_BADJSON＝bd rc=0 でも出力が不正 JSON）も tripwire 行を出さず [STALE-TRIPWIRE-UNKNOWN] へ倒す
#               （『全クラス 0 件』へ融合しない・発火 trigger は 2 本とも見張る）・空台帳 rc=0 は open:0 を emit
#               （弁別が空虚でない）・count/report は rc 非参照で従来挙動**。
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
# ★BD_BADJSON: bd 自体は exit 0 だが stdout が JSON として不正（lock 警告の前置ノイズが混じる degraded 形）。
#   契約「bd read **/ jq parse** 失敗は UNKNOWN へ倒す」の 2 本目の発火 trigger を作る（BD_FAIL は bd rc≠0 経路
#   のみを exercise するため、jq 段の rc を捨てる変異が素通りする）。TW-JQPARSE が使う。
[ -n "${BD_BADJSON:-}" ] && { printf 'warning: dolt lock held by another process\n[]'; exit 0; }
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
# --emit-tripwire（bd orch-myn0・orch-rebrief-fetch の [STALE]+[CLASSES] 両取り seam）
#   ★同一 pass 由来（report が組む文字列を emit するだけ）＝invocation 増ゼロ・既存出力 byte 不変が核。
# ==============================================================================
@test "(TW-ONLY) --emit-tripwire は [STALE-TRIPWIRE] 行 1 行のみを stdout へ（exit 0）" {
    run_scan --emit-tripwire
    [ "$status" -eq 0 ]
    [ "$output" = "[STALE-TRIPWIRE] open:13 actionable:4 held-defer:5 tracker:4 停滞疑い:3" ]
    # report の他行（分類テーブル / grouping / header）は一切出さない＝parse 側の contract を単純に保つ。
    [[ "$output" != *"[CLASS]"* ]]
    [[ "$output" != *"grouping"* ]]
    [ "$(printf '%s\n' "$output" | grep -c .)" -eq 1 ]
}

@test "(TW-PARITY) --emit-tripwire の行は report の [STALE-TRIPWIRE] 行と byte 一致（同一 pass・二重実装でない）" {
    run_scan --emit-tripwire
    local tw="$output"
    run_scan
    local in_report; in_report="$(printf '%s\n' "$output" | grep -F '[STALE-TRIPWIRE]')"
    [ "$tw" = "$in_report" ]
}

@test "(TW-ONEPASS) --emit-tripwire の bd 呼出は 1 回・report と同数（同一 pass＝呼出増ゼロの直接 teeth）" {
    # ★契約の中核「report が既に計算済みの行を emit するだけ＝**invocation 増ゼロ**」を数で pin する。
    #   TW-PARITY（tripwire 行 == report 行の byte 一致）は決定論 fixture 下では **二重 pass 実装でも成立**し、
    #   呼出数を一切証明しない（同じ入力を 2 回読めば同じ行が出る）。TW-RO も verb（list か）しか見ず数は見ない。
    #   ここを空けたままだと `tripwire) run_scan count >/dev/null; run_scan tripwire ;;` 型の回帰＝anchor 実台帳へ
    #   dolt read を 2 回撃つ退行を、どの net も赤化できない。stub の invocation log は 1 呼出 = 1 行ゆえ行数が呼出数。
    rm -f "$FIX_DIR/bd-invocations.log"
    run_scan --emit-tripwire
    [ "$status" -eq 0 ]
    [ -f "$FIX_DIR/bd-invocations.log" ]
    local n_tw; n_tw="$(grep -c . "$FIX_DIR/bd-invocations.log")"
    [ "$n_tw" -eq 1 ]

    # report 側の基準値（tripwire が「report と同一 pass」を名乗る以上、両者は同数でなければならない）。
    rm -f "$FIX_DIR/bd-invocations.log"
    run_scan
    [ "$status" -eq 0 ]
    [ -f "$FIX_DIR/bd-invocations.log" ]
    local n_rep; n_rep="$(grep -c . "$FIX_DIR/bd-invocations.log")"
    [ "$n_rep" -eq 1 ]
    [ "$n_tw" -eq "$n_rep" ]
}

@test "(TW-AGEUNK) age不明 付き（解析不能 actionable 混在）でも同形で 1 行 emit（consumer parser が許容すべき形）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="orch-bad|open||not-a-date
orch-act-old|open||2026-07-01T00:00:00Z" \
        run bash "$SCRIPT" --emit-tripwire
    [ "$status" -eq 0 ]
    [ "$output" = "[STALE-TRIPWIRE] open:2 actionable:2 held-defer:0 tracker:0 停滞疑い:1 age不明:1" ]
}

@test "(TW-JQ-CLOSED) jq 不在の --emit-tripwire は fail-closed（exit1）＝reratify 群の fail-open へ混ぜない" {
    local p; p="$(_build_nojq_path)"
    run env PATH="$p" ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" \
        ORCH_STALE_BD="$BIN/bd" ORCH_STALE_NOW="$NOW" STUB_ROWS="$ROWS" \
        bash "$SCRIPT" --emit-tripwire
    [ "$status" -eq 1 ]
    [[ "$output" != *"[STALE-TRIPWIRE]"* ]]           # 分類不能を「内訳 0」と騙らない
}

@test "(TW-BYTE-INVARIANT) --emit-tripwire 追加後も --emit-count / report の出力は不変（既存 seam を perturbate しない）" {
    # A2 の bats 側 pin（固定 fixture 比較）。git HEAD 版との byte 比較は selftest 側が担う。
    run_scan --emit-count
    [ "$output" = "3" ]
    run_scan
    [[ "$output" == *"[STALE-TRIPWIRE] open:13 actionable:4 held-defer:5 tracker:4 停滞疑い:3"* ]]
    [[ "$output" == *"[CLASS] orch-held"* ]]          # 分類テーブルは従来どおり report にのみ出る
    [[ "$output" == *"── grouping"* ]]
}

@test "(TW-RO) --emit-tripwire の bd 呼出も list のみ（read-only verb discipline）" {
    # 本 test が見張るのは verb（read-only か）だけ＝**呼出の回数は TW-ONEPASS が pin する**（役割分担）。
    rm -f "$FIX_DIR/bd-invocations.log"
    run_scan --emit-tripwire
    [ -f "$FIX_DIR/bd-invocations.log" ]
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        [[ "$line" == *"list"* ]]
    done < "$FIX_DIR/bd-invocations.log"
    ! grep -qE '(^| )(update|create|close|dep|assign|delete|import|dolt) ' "$FIX_DIR/bd-invocations.log" || false
}

@test "(TW-USAGE) 不明オプション message / usage が --emit-tripwire を列挙（発見可能性）" {
    run_scan --no-such-option
    [ "$status" -eq 1 ]
    # ★2 つの surface を **別々に** 見る（output 全体への部分一致だと、usage 本文（ヘッダ）に seam 名が
    #   在るだけで green になり、不明オプション message 側の列挙が欠けても弁別できない＝非弁別 assert）。
    local msg_line usage_line
    msg_line="$(printf '%s\n' "$output" | grep -F '不明なオプション: --no-such-option')"
    [ -n "$msg_line" ]                                    # message 自体が出ている
    [[ "$msg_line" == *"--emit-tripwire"* ]]              # message 行が seam を列挙
    usage_line="$(printf '%s\n' "$output" | grep -F 'orch-stale-scan.sh --emit-tripwire')"
    [ -n "$usage_line" ]                                  # usage（ヘッダ）側にも seam 行がある
}

@test "(TW-FAILOPEN-BD) bd read 失敗（BD_FAIL）→ tripwire 行を出さない（『全クラス 0 件』へ融合しない）" {
    # self-review major#1/#2: 新 seam が bd rc を捨てると台帳/anchor 障害が [CLASSES] の「残り 0 件・今すぐ着手 0」
    #   という偽 all-clear へ収束する（俯瞰 skill 側は [CLASSES] を「残り」の唯一の出所と定め数え直しを禁じるため
    #   裏取りが効かない）。RR-FAILOPEN-BD と対称の rc 弁別 teeth。
    BD_FAIL=1 ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$ROWS" \
        run bash "$SCRIPT" --emit-tripwire
    [ "$status" -eq 0 ]                                   # brick しない（surfacing 専任）
    # ★`|| false` は load-bearing: set -e は「`!` で反転された command」を免除するため、末尾以外の
    #   bare `!` assert は違反を検出しても test を赤化しない（inert）。中核 teeth ゆえ明示的に赤化させる。
    ! printf '%s\n' "$output" | grep -qE '^\[STALE-TRIPWIRE\] ' || false   # consumer の正規形を名乗らない
    [[ "$output" != *"open:0"* ]]                         # 0 件と断言しない
    [[ "$output" == *"[STALE-TRIPWIRE-UNKNOWN]"* ]]       # 判定不能は判定不能として surface
}

@test "(TW-JQPARSE) bd rc=0 でも jq parse 失敗 → tripwire 行を出さず [STALE-TRIPWIRE-UNKNOWN]" {
    # 契約 2 本目の発火 trigger: bd は成功する（exit 0）が stdout が JSON として不正な degraded 形（lock 警告の
    #   前置ノイズ）。BD_FAIL 経路だけを見張ると `_open_rows` の **jq 段 rc** を捨てる変異（例:
    #   `_stale_bd_json | { _rows_from_json || true; }`）が生存し、台帳障害が
    #   `[STALE-TRIPWIRE] open:0 actionable:0 …` という偽 all-clear へ融合する（本 bead が禁じた融合そのもの）。
    BD_BADJSON=1 ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$ROWS" \
        run bash "$SCRIPT" --emit-tripwire
    [ "$status" -eq 0 ]                                   # brick しない（surfacing 専任）
    # ★`|| false` は load-bearing（TW-FAILOPEN-BD と同理由: 末尾以外の bare `!` は set -e の免除対象で inert）。
    ! printf '%s\n' "$output" | grep -qE '^\[STALE-TRIPWIRE\] ' || false   # consumer の正規形を名乗らない
    [[ "$output" != *"open:0"* ]]                         # 0 件と断言しない
    [[ "$output" == *"[STALE-TRIPWIRE-UNKNOWN]"* ]]       # 判定不能は判定不能として surface

    # 非空虚: この fixture で bd 自体は exit 0（＝BD_FAIL 経路の焼き直しでなく jq 段 rc を見ている裏取り）。
    BD_BADJSON=1 STUB_ROWS="$ROWS" run "$BIN/bd" list --status open,deferred --json
    [ "$status" -eq 0 ]
    [[ "$output" == *"warning"* ]]
}

@test "(TW-BD-VS-EMPTY) 空台帳（rc=0）は open:0 の tripwire 行を emit（bd 失敗との弁別が空虚でない）" {
    # BD_FAIL 無し・open 0 件 → 正規 tripwire 行（rc 弁別を「常に UNKNOWN」へ潰した mutant はここで赤化）。
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="" \
        run bash "$SCRIPT" --emit-tripwire
    [ "$status" -eq 0 ]
    [ "$output" = "[STALE-TRIPWIRE] open:0 actionable:0 held-defer:0 tracker:0 停滞疑い:0" ]
    [[ "$output" != *"UNKNOWN"* ]]
}

@test "(TW-FAILOPEN-BYTE) bd 失敗でも --emit-count / report は従来挙動（rc 弁別は tripwire 限定＝A2 据置）" {
    BD_FAIL=1 ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$ROWS" \
        run bash "$SCRIPT" --emit-count
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]
    BD_FAIL=1 ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="$ROWS" \
        run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[STALE-TRIPWIRE] open:0 "* ]]       # report 側は従来どおり（byte 不変の据置）
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
    #   ★`|| false` は load-bearing: bats の set -e は「`!` で反転された command」を免除するため、末尾以外の
    #     bare `!` assert は違反を検出しても test を赤化しない（inert）＝local SSOT と同形へ揃える。
    ! grep -qE '(^| )(update|create|close|dep|assign|delete|import|dolt) ' "$FIX_DIR/bd-invocations.log" || false
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

# (RR-BELL) の negative teeth（sc-ohik m0）: 🔔 マークが needs-user 併存 bead **にだけ** 載ることを pin する。
#   RR-BELL は positive 側（bell 行に 🔔 がある）しか見ないため、`case ",$labels," in *,needs-user,*)` の guard を
#   外して bell を無条件付与する mutant を素通しする＝marker の load-bearing 性が空虚だった。本 test は
#   needs-user 非併存の死角クラス 7 件に 🔔 が無いこと + 🔔 行がちょうど 1 行であることを assert し、
#   常時付与 mutant（7 件にも 🔔・🔔 行 8 行）を RED 化する。
@test "(RR-BELL-NEG) needs-user 非併存の死角クラスには呼び鈴マークを付けない（bell 常時付与 mutant を RED 化）" {
    run_reratify --re-ratify
    local id line
    for id in orch-rr-cour orch-rr-held orch-rr-seam orch-rr-fu orch-rr-coord orch-rr-defst orch-rr-courfor; do
        line=$(printf '%s\n' "$output" | grep "\[RERATIFY\] $id ")
        [ -n "$line" ]                                   # surface 済（grep 空振りで vacuous に green 化しない）
        [[ "$line" != *"🔔"* ]]
        [[ "$line" != *"呼び鈴対象"* ]]
    done
    # 🔔 は候補 8 件中ちょうど 1 行（orch-rr-bell のみ）＝常時付与 mutant は 8 行になり RED。
    [ "$(printf '%s\n' "$output" | grep -c '🔔呼び鈴対象')" -eq 1 ]
}

@test "(RR-TITLE) title 冒頭を per-bead 行へ表示" {
    run_reratify --re-ratify
    [[ "$output" == *"配送後に長期 open な courier bead"* ]]
}

# age 降順 sort の teeth（sc-ohik m1）: 既定 RR_ROWS は死角クラスの created_at が全件同日（age 全件 19d）で、
#   順序を pin する assert も無いため `sort -t'\t' -k1,1nr` を外しても全 test が green＝sort が空虚だった。
#   本 test は入力を **age 昇順**（9d→19d→33d）に並べた専用 fixture（同一 courier group）で出力の age 降順を
#   pin する。RED 化する mutant: (a) sort 除去（cut のみ→入力順 9/19/33 の昇順）(b) `-r` 落ち（昇順）
#   (c) `-n` 落ち（lexical で "9" > "33" > "19"＝1 桁×2 桁を跨ぐ fixture ゆえ numeric 性も同時に pin）。
@test "(RR-SORT) 同一 group 内は age 降順で print（入力が昇順でも並べ替わる＝sort 非空虚）" {
    ORCH_STALE_SKIP_SESSION_GATE=1 ORCH_STALE_SCRIPTORIUM="$ANCHOR" ORCH_STALE_BD="$BIN/bd" \
        ORCH_STALE_NOW="$NOW" STUB_ROWS="orch-rr-young|open|courier|2026-07-11T00:00:00Z
orch-rr-mid|open|courier|2026-07-01T00:00:00Z
orch-rr-old|open|courier|2026-06-17T00:00:00Z" \
        run bash "$SCRIPT" --re-ratify
    [ "$status" -eq 0 ]
    local ids ages
    ids=$(printf '%s\n' "$output" | grep -o 'orch-rr-[a-z]*' | tr '\n' ' ')
    ages=$(printf '%s\n' "$output" | grep -o 'age=[0-9]*d' | tr '\n' ' ')
    [ "$ids" = "orch-rr-old orch-rr-mid orch-rr-young " ]   # 入力順 young→mid→old の逆＝実際に並べ替わった
    [ "$ages" = "age=33d age=19d age=9d " ]                 # 数値降順（lexical なら 9d,33d,19d）
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

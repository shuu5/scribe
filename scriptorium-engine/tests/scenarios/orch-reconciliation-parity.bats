#!/usr/bin/env bats
# tests/scenarios/orch-reconciliation-parity.bats
#
# orch-reconciliation-parity.sh（bd orch-b4b・実装1+実装2）の **hermetic 回帰**。
# 実 dolt/bd/tmux を一切使わず、fake bd（PATH/env スタブ）と fixture 台帳で parity 判定の
# 不変条件を pin する（fleet-monitor-board.bats / guard-health-banner.bats と同型の hermetic E2E）。
#
# 検証する契約不変条件（SSOT=docs/orch-b4b-reconciliation-runbook.md テスト節 / bd orch-b4b）:
#   ① 未 ingest 候補（F にあり P に無い）  = GAP surface     （取り込み漏れを surface する）。
#   ② ingest 済（F にあり P にある）       = non-gap         （gap に出さない）。
#   ③ stale（取込後に foreign が更新）     = DRIFT surface   （鮮度劣化を surface する）。
#   ④ 公開面は exact-match（regex 誤ヒットしない）           （near-miss ラベルを surface しない）。
#   ⑤ foreign read-only                    （write verb を foreign 台帳に一切発行しない）。
#   (json)   --json が valid JSON + 正しい counts を出し exit 0。
#   (scope)  非 orch 台帳 cwd では fail-closed（exit≠0・誤 scan しない）。
#   (exit)   issue があれば既定モードは非 0（fail-loud）/ 健全なら 0。
#
# 方式（fake bd は --label を無視し fixture をそのまま返す＝スクリプト側 exact-match 再検査を検証）。
#
# 実行: bats tests/scenarios/orch-reconciliation-parity.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-reconciliation-parity.sh"

    TEST_TMPDIR="$(mktemp -d -t recon-parity-bats-XXXXXX)"

    # --- self-scope cwd: dolt_database=orch の台帳 + 自台帳公開面 fixture ---
    ORCH="$TEST_TMPDIR/orch"
    mkdir -p "$ORCH/.beads"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH/.beads/metadata.json"

    # 自台帳 published surface（P）fixture。
    #   orch-1: reconcile-published / dep un-100 / updated 2026-06-01  -> un-100 OK
    #   orch-2: reconcile-published / dep sc-200 / updated 2026-06-01  -> sc-200 DRIFT（foreign 後更新）
    #   orch-3: reconcile-published / dep un-999 / updated 2026-06-10  -> un-999 ORPHAN（F に無い）
    #   orch-4: reconcile-published / dep なし    / updated 2026-06-01  -> BROKEN（cross-rig dep 無し）
    #   orch-9: reconcile-published-draft（near-miss・surface 扱いしない・④ self 側）
    #   orch-5: ラベル other（surface でない）
    cat > "$ORCH/.beads/fixture.json" <<'JSON'
[
  {"id":"orch-1","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published"],"dependencies":[{"issue_id":"orch-1","depends_on_id":"un-100"}]},
  {"id":"orch-2","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published"],"dependencies":[{"issue_id":"orch-2","depends_on_id":"sc-200"}]},
  {"id":"orch-3","status":"open","updated_at":"2026-06-10T00:00:00Z","labels":["reconcile-published"],"dependencies":[{"issue_id":"orch-3","depends_on_id":"un-999"}]},
  {"id":"orch-4","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published"],"dependencies":[]},
  {"id":"orch-9","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published-draft"],"dependencies":[{"issue_id":"orch-9","depends_on_id":"un-777"}]},
  {"id":"orch-5","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["other"],"dependencies":[{"issue_id":"orch-5","depends_on_id":"un-100"}]}
]
JSON

    # --- foreign 台帳 fixture ---
    PROJALPHA="$TEST_TMPDIR/projalpha"
    SCRIBE="$TEST_TMPDIR/scribe"
    mkdir -p "$PROJALPHA/.beads" "$SCRIBE/.beads"
    printf '{"database":"dolt","dolt_database":"un"}' > "$PROJALPHA/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"sc"}' > "$SCRIBE/.beads/metadata.json"

    # projalpha: un-100 OK / un-101 GAP / un-102 near-miss(④) / un-103 closed(除外)
    cat > "$PROJALPHA/.beads/fixture.json" <<'JSON'
[
  {"id":"un-100","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["federate-publish"],"dependencies":[]},
  {"id":"un-101","status":"open","updated_at":"2026-06-05T00:00:00Z","labels":["federate-publish"],"dependencies":[]},
  {"id":"un-102","status":"open","updated_at":"2026-06-05T00:00:00Z","labels":["federate-publish-draft"],"dependencies":[]},
  {"id":"un-103","status":"closed","updated_at":"2026-06-05T00:00:00Z","labels":["federate-publish"],"dependencies":[]}
]
JSON

    # scribe: sc-200 DRIFT（foreign updated 2026-06-20 > orch-2 updated 2026-06-01）
    cat > "$SCRIBE/.beads/fixture.json" <<'JSON'
[
  {"id":"sc-200","status":"open","updated_at":"2026-06-20T00:00:00Z","labels":["federate-publish"],"dependencies":[]}
]
JSON

    # --- fake bd（--label 無視・fixture をそのまま返す。全呼出を log し write verb を検出） ---
    STUBDIR="$TEST_TMPDIR/stub"
    mkdir -p "$STUBDIR"
    BD_CALLLOG="$TEST_TMPDIR/bd-calls.log"
    export BD_CALLLOG
    cat > "$STUBDIR/bd" <<'STUB'
#!/usr/bin/env bash
# fake bd: list を fixture から返す read-only スタブ。全呼出を BD_CALLLOG へ記録。
printf '%s\n' "$*" >> "${BD_CALLLOG:-/dev/null}"
_path=""; _prev=""
for a in "$@"; do
  [ "$_prev" = "-C" ] && _path="$a"
  _prev="$a"
done
if [ -n "$_path" ]; then
  cat "$_path/.beads/fixture.json" 2>/dev/null || echo "[]"
else
  cat "$PWD/.beads/fixture.json" 2>/dev/null || echo "[]"
fi
exit 0
STUB
    chmod +x "$STUBDIR/bd"

    export ORCH_RECON_BD="$STUBDIR/bd"
    export ORCH_RECON_PROJECTS="projalpha=$PROJALPHA scribe=$SCRIBE"
    # 既定ラベルを使う（PUBLISH=reconcile-published / FOREIGN=federate-publish）。

    # foreign fixture の read-only 検証用に事前チェックサム。
    PROJALPHA_SUM_BEFORE="$(md5sum "$PROJALPHA/.beads/fixture.json" | awk '{print $1}')"
    SCRIBE_SUM_BEFORE="$(md5sum "$SCRIBE/.beads/fixture.json" | awk '{print $1}')"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# orch cwd で script を起動する helper（self-scope を満たす）。
run_in_orch() {
    ( cd "$ORCH" && "$SCRIPT" "$@" )
}

@test "① 未 ingest 候補（un-101）は GAP に surface される" {
    run run_in_orch
    [ "$status" -ne 0 ]                       # issue ありゆえ fail-loud
    echo "$output" | grep -q "GAP"
    echo "$output" | grep -q "un-101"
}

@test "② ingest 済（un-100）は non-gap（gap 行に出ない・ok にカウント）" {
    run run_in_orch --json
    [ "$status" -eq 0 ]
    # un-100 は ok 配列にあり gap 配列に無い。
    echo "$output" | jq -e '.ok[]?.foreign_id | select(. == "un-100")' >/dev/null
    run bash -c "echo '$output' | jq -e '.gap[]?.foreign_id | select(. == \"un-100\")'"
    [ "$status" -ne 0 ]   # un-100 は gap に無い
}

@test "③ stale（sc-200・取込後に foreign 更新）は DRIFT に surface される" {
    run run_in_orch --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.drift[]?.foreign_id | select(. == "sc-200")' >/dev/null
    echo "$output" | jq -e '.counts.drift == 1' >/dev/null
}

@test "④ exact-match: near-miss ラベル（federate-publish-draft / reconcile-published-draft）を surface しない" {
    run run_in_orch --json
    [ "$status" -eq 0 ]
    # un-102（federate-publish-draft）はどの集合にも出ない。
    run bash -c "echo '$output' | grep -F 'un-102'"
    [ "$status" -ne 0 ]
    # orch-9 が指す un-777（reconcile-published-draft は surface でない）も ORPHAN に出ない。
    run bash -c "echo '$output' | grep -F 'un-777'"
    [ "$status" -ne 0 ]
}

# allowlist 方式（M3）: log の各 `-C <path> <verb>` 行の verb が read-only（list/show）のみか検査。
# denylist（既知 write verb を列挙）は tag/assign/label/comment/delete 等を取りこぼすため allowlist へ反転。
# returns 0 if 全 foreign 呼出が read-only / 1 if read-only でない verb を 1 つでも検出。
foreign_verbs_readonly_only() {
    local logf="$1" line verb bad=0
    while IFS= read -r line; do
        case " $line " in
            *" -C "*)
                verb="$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i=="-C"){print $(i+2); exit}}')"
                case "$verb" in
                    list|show) ;;                       # read-only allowlist
                    *) bad=1; echo "FOREIGN NON-READ VERB: '$verb' in: $line" >&2 ;;
                esac
                ;;
        esac
    done < "$logf"
    return "$bad"
}

@test "⑤ foreign read-only(allowlist): foreign(-C) 呼出の verb は list/show のみ・fixture 不変" {
    run run_in_orch --json
    [ "$status" -eq 0 ]
    # allowlist 方式で foreign 呼出を検査（denylist の取りこぼしを排除・M3）。
    foreign_verbs_readonly_only "$BD_CALLLOG"
    # fixture 内容も不変。
    local after_projalpha after_scribe
    after_projalpha="$(md5sum "$PROJALPHA/.beads/fixture.json" | awk '{print $1}')"
    after_scribe="$(md5sum "$SCRIBE/.beads/fixture.json" | awk '{print $1}')"
    [ "$after_projalpha" = "$PROJALPHA_SUM_BEFORE" ]
    [ "$after_scribe" = "$SCRIBE_SUM_BEFORE" ]
}

@test "⑤-teeth allowlist は denylist が取りこぼす write verb（tag/assign/label/delete/update）を検出する" {
    # 非vacuity 証明: 合成ログ（foreign への各種 write verb）を allowlist 検査に通すと必ず fail する。
    # 旧 denylist では tag/assign/label/delete が EVADES だった（errata M3 PROBE 実測）。
    local synth="$TEST_TMPDIR/synth.log"
    for v in tag assign label comment delete reopen start block update close; do
        printf -- '-C /x/projalpha %s un-1 --foo\n' "$v" > "$synth"
        run foreign_verbs_readonly_only "$synth"
        [ "$status" -ne 0 ]   # write verb を検出（fail）
    done
    # read-only verb は通る（false-positive でないこと）。
    printf -- '-C /x/projalpha list --label federate-publish\n-C /x/projalpha show un-1\n' > "$synth"
    run foreign_verbs_readonly_only "$synth"
    [ "$status" -eq 0 ]
}

@test "(json) --json は valid JSON + 正しい counts を出し exit 0" {
    run run_in_orch --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.' >/dev/null                      # valid JSON
    echo "$output" | jq -e '.counts.gap == 1' >/dev/null       # un-101
    echo "$output" | jq -e '.counts.ok == 1' >/dev/null        # un-100
    echo "$output" | jq -e '.counts.drift == 1' >/dev/null     # sc-200
    echo "$output" | jq -e '.counts.orphan == 1' >/dev/null    # un-999
    echo "$output" | jq -e '.counts.broken == 1' >/dev/null    # orch-4
}

@test "(scope) 非 orch 台帳 cwd では fail-closed（誤 scan しない）" {
    run bash -c "cd '$PROJALPHA' && '$SCRIPT'"
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "refusing to run"
}

@test "(notice) --notice は print-notice 様式で gap/drift を出す（live inject しない）" {
    run run_in_orch --notice
    [ "$status" -ne 0 ]   # issue ありゆえ fail-loud
    echo "$output" | grep -q "NOTICE \[gap\]"
    echo "$output" | grep -q "NOTICE \[drift\]"
    echo "$output" | grep -q "notice のみ"
}

@test "(exit) issue 無しなら既定モードは exit 0（fail-loud しない）" {
    # foreign を空にし、公開面の dep も全て F に一致 & 非 stale な単純ケース。
    printf '[]' > "$PROJALPHA/.beads/fixture.json"
    printf '[]' > "$SCRIBE/.beads/fixture.json"
    # 公開面も空にすれば issue=0。
    printf '[]' > "$ORCH/.beads/fixture.json"
    run run_in_orch
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "issues=0"
}

@test "(dry-run) --dry-run は実 bd を呼ばず計画のみ print" {
    run run_in_orch --dry-run
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "DRY-RUN"
    echo "$output" | grep -q "foreign read-only"
    # bd は呼ばれない（log 空 or 未作成）。
    [ ! -s "$BD_CALLLOG" ]
}

@test "(help) --help はヘッダを出す" {
    run run_in_orch --help
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "published-interface parity"
}

@test "(report surface) ORPHAN(un-999)/BROKEN(orch-4) が report テキストに surface される" {
    run run_in_orch
    [ "$status" -ne 0 ]   # issue ありゆえ fail-loud
    echo "$output" | grep -q "ORPHAN"
    echo "$output" | grep -q "un-999"
    echo "$output" | grep -q "BROKEN"
    echo "$output" | grep -q "orch-4"
}

@test "(notice surface) ORPHAN/BROKEN が notice 行に surface される" {
    run run_in_orch --notice
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "NOTICE \[orphan\]"
    echo "$output" | grep -q "un-999"
    echo "$output" | grep -q "NOTICE \[broken\]"
    echo "$output" | grep -q "orch-4"
}

@test "(errored surface) foreign scan rc!=0 は silent swallow せず errored に計上し WARN を出す" {
    # .beads は在るが bd -C list が rc!=0 を返す project を sim（一過性 bd/dolt 障害）。
    FAILSTUB="$TEST_TMPDIR/stub-fail"
    mkdir -p "$FAILSTUB"
    cat > "$FAILSTUB/bd" <<'STUB'
#!/usr/bin/env bash
_path=""; _prev=""
for a in "$@"; do [ "$_prev" = "-C" ] && _path="$a"; _prev="$a"; done
if [ -n "$_path" ]; then exit 3; fi          # foreign scan は必ず失敗
cat "$PWD/.beads/fixture.json" 2>/dev/null || echo "[]"   # self は成功
STUB
    chmod +x "$FAILSTUB/bd"
    # foreign は空・公開面も空にして issue を errored 由来のみに絞る。
    printf '[]' > "$ORCH/.beads/fixture.json"
    # 注: bats の run は stdout+stderr を統合するため、json 取得時は WARN(stderr) を捨てる。
    run env ORCH_RECON_BD="$FAILSTUB/bd" ORCH_RECON_PROJECTS="projalpha=$PROJALPHA" bash -c "cd '$ORCH' && '$SCRIPT' --json 2>/dev/null"
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.counts.projects_errored == 1' >/dev/null
    # report モードでも WARN が出て exit 3（DEGRADED）＝'clean'(exit0) と区別される。
    run env ORCH_RECON_BD="$FAILSTUB/bd" ORCH_RECON_PROJECTS="projalpha=$PROJALPHA" bash -c "cd '$ORCH' && '$SCRIPT' 2>&1"
    [ "$status" -eq 3 ]   # 評価不能 ≠ clean（exit3・非vacuity: 旧 exit0 なら fail）
    echo "$output" | grep -q "errored=1"
    echo "$output" | grep -q "WARN"
}

@test "M1 ORPHAN false-positive 防止: ingest 済 dep の owning project が ERRORED のとき ORPHAN でなく INDETERMINATE" {
    # 公開面に un-500 を ingest 記録（reconcile-published・cross-rig dep un-500）。foreign projalpha は scan 失敗。
    cat > "$ORCH/.beads/fixture.json" <<'JSON'
[
  {"id":"orch-50","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published"],"dependencies":[{"issue_id":"orch-50","depends_on_id":"un-500"}]}
]
JSON
    FAILSTUB="$TEST_TMPDIR/stub-fail-m1"
    mkdir -p "$FAILSTUB"
    cat > "$FAILSTUB/bd" <<'STUB'
#!/usr/bin/env bash
_path=""; _prev=""
for a in "$@"; do [ "$_prev" = "-C" ] && _path="$a"; _prev="$a"; done
if [ -n "$_path" ]; then exit 3; fi
cat "$PWD/.beads/fixture.json" 2>/dev/null || echo "[]"
STUB
    chmod +x "$FAILSTUB/bd"
    run env ORCH_RECON_BD="$FAILSTUB/bd" ORCH_RECON_PROJECTS="projalpha=$PROJALPHA" bash -c "cd '$ORCH' && '$SCRIPT' --json 2>/dev/null"
    [ "$status" -eq 0 ]
    # owning project(un=projalpha) が errored ゆえ un-500 は ORPHAN にしない（評価不能）。
    echo "$output" | jq -e '.counts.orphan == 0' >/dev/null
    echo "$output" | jq -e '.counts.indeterminate >= 1' >/dev/null
    echo "$output" | jq -e '.indeterminate[]?.foreign_id | select(. == "un-500")' >/dev/null
    # report モードは exit 3（DEGRADED）— 旧実装なら un-500=ORPHAN で exit 1（fail-loud）になり non-vacuous。
    run env ORCH_RECON_BD="$FAILSTUB/bd" ORCH_RECON_PROJECTS="projalpha=$PROJALPHA" bash -c "cd '$ORCH' && '$SCRIPT' 2>/dev/null"
    [ "$status" -eq 3 ]
}

@test "M1 ORPHAN false-positive 防止: owning project が SKIPPED(.beads 不在)のとき ORPHAN でなく INDETERMINATE" {
    # pk-600 を ingest 記録。pk project は ORCH_RECON_PROJECTS に居ない＝未スキャン（prefix 'pk' ∉ scanned）。
    cat > "$ORCH/.beads/fixture.json" <<'JSON'
[
  {"id":"orch-60","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published"],"dependencies":[{"issue_id":"orch-60","depends_on_id":"pk-600"}]}
]
JSON
    printf '[]' > "$PROJALPHA/.beads/fixture.json"
    run run_in_orch --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.counts.orphan == 0' >/dev/null
    echo "$output" | jq -e '.indeterminate[]?.foreign_id | select(. == "pk-600")' >/dev/null
}

@test "M2 jq 不在は degraded として surface（issues=0 でも clean(exit0) と区別＝exit3）" {
    # jq を含まない PATH を構成（必要ツールのみ symlink）。script は jq 不在で評価劣化する。
    # ★python3/node は含める（orch-vo2）: 共有 lib の self-scope gate（_ledger_dolt_database → _json_is_valid）は
    #   jq/python3/node の OR で metadata の JSON 妥当性を確認してから dolt_database を採る。jq を抜いた本 PATH に
    #   python3/node も無いと、妥当な {"dolt_database":"orch"} まで gate で不採用→空 db→self-scope refuse(exit1) になり、
    #   本テストが pin したい「jq 劣化 surface=exit3」でなく起動拒否で RED 化する。本テストの意図は『jq 不在の
    #   評価劣化』を pin することであり『全検証器不在』ではない（clean-state-probe の _mk_nojq_path と同型の含め方）。
    NOJQ="$TEST_TMPDIR/nojqbin"
    mkdir -p "$NOJQ"
    for t in bash sh env date sed awk head dirname cat mktemp rm grep md5sum tr cut python3 node; do
        src="$(command -v "$t" 2>/dev/null)" && [ -n "$src" ] && ln -sf "$src" "$NOJQ/$t"
    done
    ln -sf "$STUBDIR/bd" "$NOJQ/bd"
    # jq が PATH に無いことを確認（テスト前提）。
    PATH="$NOJQ" command -v jq && skip "jq が NOJQ PATH に紛れた（環境依存）"
    run env -i PATH="$NOJQ" ORCH_RECON_BD="$STUBDIR/bd" ORCH_RECON_PROJECTS="projalpha=$PROJALPHA" HOME="$TEST_TMPDIR" "$NOJQ/bash" -c "cd '$ORCH' && '$SCRIPT' 2>&1"
    [ "$status" -eq 3 ]                       # 評価不能＝clean(exit0) でない（非vacuity: 旧実装なら exit0）
    echo "$output" | grep -qi "jq"           # jq 劣化を本文に surface
}

@test "m4 timestamp parse 失敗（date 不能→0）は OK に混ぜず INDETERMINATE で surface" {
    # un-700 を ingest 済（公開面 valid ts）。foreign un-700 の updated_at が unparseable。
    cat > "$ORCH/.beads/fixture.json" <<'JSON'
[
  {"id":"orch-70","status":"open","updated_at":"2026-06-01T00:00:00Z","labels":["reconcile-published"],"dependencies":[{"issue_id":"orch-70","depends_on_id":"un-700"}]}
]
JSON
    cat > "$PROJALPHA/.beads/fixture.json" <<'JSON'
[
  {"id":"un-700","status":"open","updated_at":"NOT-A-VALID-DATE","labels":["federate-publish"],"dependencies":[]}
]
JSON
    printf '[]' > "$SCRIBE/.beads/fixture.json"
    run run_in_orch --json
    [ "$status" -eq 0 ]
    # un-700 は ingest 済だが鮮度評価不能＝OK でも drift でもなく INDETERMINATE（非vacuity: 旧実装なら ok）。
    echo "$output" | jq -e '.indeterminate[]?.foreign_id | select(. == "un-700")' >/dev/null
    run bash -c "echo '$output' | jq -e '.ok[]?.foreign_id | select(. == \"un-700\")'"
    [ "$status" -ne 0 ]   # un-700 は ok に無い
}

#!/usr/bin/env bats
# tests/scenarios/orch-handoff-scan.bats
#
# orch-handoff-scan.sh（needs-orch 検知線・foreign→orchestrator self-surface・bd orch-jmu / orch-am1 論点6）の
# hermetic bats。bd を PATH stub で差し替え、実 dolt を一切使わずに scan 契約を pin する。
#
# 背景: hydrated orch DB を `needs-orch` 平ラベルで完全一致 scan し orchestrator 自身が引き取るべき foreign
#   bead を surface する read-only 検知線。scan は `bd list -l needs-orch --json --no-pager --limit 0`（截断禁止・
#   単数 -l）。needs-grill を併存する bead は per-bead で「triage 保留」表示（DB 全体保留ではない）。foreign 鮮度
#   （last-sync stale）は standalone のみ emit・hook 統合(--no-freshness)は第1セクションへ委譲。
#
# 検証する契約不変条件（SSOT=orch-jmu acceptance / script header / orch-am1 論点2,3,6）:
#   (1)  正例: needs-orch 3 件を surface（scanned=3）。
#   (2)  per-bead 保留: needs-grill 併存 bead のみ TRIAGE 保留・非併存 bead は actionable（actionable=2 triage-hold=1）。
#   (3)  負例: scan 空（needs-orch なし）→「なし」no-op・scanned=0・非0 にしない。
#   (4)  截断禁止(p1)/単数ラベル(p2): bd 呼出しに `-l needs-orch` と `--limit 0` が含まれる（default-limit 截断禁止）。
#   (5)  self-scope: foreign 台帳 cwd（gate 有効）→ refuse・非0（誤台帳 scan を fail-closed で弾く）。
#   (6)  鮮度: stale marker → standalone は⚠警告 / --no-freshness は無警告（第1セクションへ委譲・p3）。
#   (7)  鮮度 unknown: marker 不在 → ⚠警告（sync 未成立の可能性を最安全側に surface）。
#   (8)  parser OR 合成: jq 破損(exit1)でも python3 フォールバックで labels を正しく解釈し per-bead 保留が効く。
#   (9)  本体 `--self-test` が green（コミット済 coverage を durable に pin）。
#   (10) bash -n（構文）が通る。
#   (11) 鮮度: fresh marker（recent mtime）→ standalone でも無警告（always-warn 型偽陽性回帰を捕捉・fresh 分岐 pin）。
#   (12) self-scope 肯定側: orch 台帳 cwd（SKIP なし）→ gate 通過し scan が走る（always-refuse 回帰を捕捉・(5) の対）。
#   (13) scan 失敗（bd rc≠0）→ standalone は非0 で終了（run_scan return 1 を pin・errata E2）。
#
# ★fixture bd は real bd の `-l <label>` exact-match フィルタを模す（errata E1）: -l 値を parse し exact label を
#   持つ bead だけ返す。ゆえに SCAN_LABEL の superset typo（needs-orch-TYPO）は 0 件になり test(1) が RED になる
#   （旧・固定 JSON 無条件 cat + substring assert では typo が素通りしていた穴を封鎖）。
#
# mutation 非vacuity（acceptance 5・独立 mutation。実 RED 出力は bd orch-jmu notes へ append）:
#   M1: scan の `--limit 0` を削除 → (4) 截断禁止テストが RED（default-limit 截断を招く回帰を捕捉）。
#   M2: triage 保留の per-bead 判定 `[ "$grill" = "1" ]` を無条件 true 化 → (2) が RED（非併存 bead を誤保留）。
#   M3: 鮮度閾値を無条件 warn 化 → (11) が RED / M4: self-scope を無条件 refuse 化 → (12) が RED。
#   M5(E1): SCAN_LABEL を needs-orch-TYPO へ変更 → fixture bd が 0 件を返し (1)/(2) が RED（誤ラベル素通しを封鎖）。
#   M6(E2): run_scan の scan-fail 分岐 `return 1` を `return 0` へ → (13) が RED（検知不能を green と偽らない）。
#
# 実行: bats tests/scenarios/orch-handoff-scan.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-handoff-scan.sh"

    TEST_TMPDIR="$(mktemp -d -t handoff-bats-XXXXXX)"
    BINDIR="$TEST_TMPDIR/bin"; mkdir -p "$BINDIR"

    # fake bd: 受領した全引数を FAKE_BD_ARGS へ記録し、FAKE_BD_JSON の中身を stdout に返す（read-only・list 相当）。
    # fake bd: 受領全引数を FAKE_BD_ARGS へ記録し、real bd の `-l <label>` **exact-match フィルタ**を模す
    #   （orch-jmu errata E1）。旧実装は固定 JSON を無条件 cat したため、SCAN_LABEL の superset typo
    #   （例 needs-orch-TYPO）でも同じ JSON を返し test が素通りしていた。ここで -l 値を parse し、その
    #   exact label を labels 配列に含む bead だけ返す＝誤ラベルなら 0 件→ test(1) の scanned=3 が落ちる。
    cat > "$BINDIR/bd" <<'BDEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_BD_ARGS"
label=""; prev=""
for a in "$@"; do
  if [ "$prev" = "-l" ] || [ "$prev" = "--label" ]; then label="$a"; fi
  prev="$a"
done
LABEL="$label" python3 -c '
import json, os
label = os.environ.get("LABEL", "")
data = json.load(open(os.environ["FAKE_BD_JSON"]))
if not isinstance(data, list):
    data = []
if label:
    out = [it for it in data
           if isinstance(it, dict) and isinstance(it.get("labels"), list) and label in it["labels"]]
else:
    out = data
print(json.dumps(out))
'
BDEOF
    chmod +x "$BINDIR/bd"

    export FAKE_BD_ARGS="$TEST_TMPDIR/bd-args.log"; : > "$FAKE_BD_ARGS"
    export FAKE_BD_JSON="$TEST_TMPDIR/scan.json"

    # 既定 fixture JSON: needs-orch 3 件（sc-bbb は needs-grill 併存）。bd の -l needs-orch フィルタ相当を模す。
    cat > "$FAKE_BD_JSON" <<'JSON'
[
  {"id":"un-aaa","title":"foreign A needs orch","labels":["needs-orch"]},
  {"id":"sc-bbb","title":"foreign B needs orch and grill","labels":["needs-orch","needs-grill"]},
  {"id":"pk-ccc","title":"foreign C needs orch","labels":["needs-orch","other"]}
]
JSON

    # foreign 台帳 fixture（self-scope gate 用）。
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$FOREIGN/.beads"; printf '{"dolt_database":"un"}' > "$FOREIGN/.beads/metadata.json"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# gate skip + fake bd + marker 不在（既定）で scan を走らせる。$@ は追加引数。
run_scan() {
    run env ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$BINDIR/bd" \
        ORCH_HANDOFF_SYNC_MARKER="$TEST_TMPDIR/no-such-marker" \
        bash "$SCRIPT" "$@"
}

@test "(1) 正例: needs-orch 3 件を surface・scanned=3・exit0" {
    run_scan --no-freshness
    [ "$status" -eq 0 ]
    [[ "$output" == *"un-aaa"* ]]
    [[ "$output" == *"sc-bbb"* ]]
    [[ "$output" == *"pk-ccc"* ]]
    [[ "$output" == *"scanned=3"* ]]
}

@test "(2) per-bead 保留: needs-grill 併存のみ TRIAGE 保留・非併存は actionable(actionable=2 triage-hold=1)" {
    run_scan --no-freshness
    [ "$status" -eq 0 ]
    # ★行スコープで判定する（$output 全体 glob は複数行に跨って誤マッチするため per-line で確認）。
    #   併存 bead（sc-bbb）の行は [TRIAGE 保留]・非併存 bead（un-aaa/pk-ccc）の行は [needs-orch]。
    [[ "$(printf '%s\n' "$output" | grep -F 'sc-bbb')" == *"[TRIAGE 保留]"* ]]
    [[ "$(printf '%s\n' "$output" | grep -F 'un-aaa')" == *"[needs-orch]"* ]]
    [[ "$(printf '%s\n' "$output" | grep -F 'pk-ccc')" == *"[needs-orch]"* ]]
    # 非併存 bead の行が誤って保留になっていないこと（DB 全体保留ではない・per-bead）。
    [[ "$(printf '%s\n' "$output" | grep -F 'un-aaa')" != *"保留"* ]]
    [[ "$(printf '%s\n' "$output" | grep -F 'pk-ccc')" != *"保留"* ]]
    [[ "$output" == *"actionable=2 triage-hold=1"* ]]
}

@test "(3) 負例: scan 空(needs-orch なし)→「なし」no-op・scanned=0・exit0" {
    printf '[]' > "$FAKE_BD_JSON"
    run_scan --no-freshness
    [ "$status" -eq 0 ]
    [[ "$output" == *"needs-orch: なし"* ]]
    [[ "$output" == *"scanned=0"* ]]
}

@test "(4) 截断禁止(p1)/単数ラベル(p2): bd 呼出しに -l needs-orch(exact) と --limit 0" {
    run_scan --no-freshness
    [ "$status" -eq 0 ]
    # ★境界一致（errata E1）: `-l needs-orch` の直後は空白か行末（superset typo `-l needs-orch-TYPO` を弾く）。
    #   旧 substring grep は typo を素通ししていた（SCAN_LABEL mutation が RED にならない穴）。
    grep -qE -- "(^| )-l needs-orch( |\$)" "$FAKE_BD_ARGS"
    grep -qE -- "(^| )--limit 0( |\$)" "$FAKE_BD_ARGS"
    grep -qF -- "--no-pager" "$FAKE_BD_ARGS"
}

@test "(5) self-scope: foreign 台帳 cwd(gate 有効)→ refuse・非0(fail-closed)" {
    cd "$FOREIGN"
    run env ORCH_HANDOFF_BD="$BINDIR/bd" bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
}

@test "(6) 鮮度: stale marker → standalone は⚠警告 / --no-freshness は無警告(第1へ委譲・p3)" {
    MARKER="$TEST_TMPDIR/last-sync"; printf 'old\n' > "$MARKER"
    touch -d '3 hours ago' "$MARKER" 2>/dev/null || touch "$MARKER"
    run env ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$BINDIR/bd" \
        ORCH_HANDOFF_SYNC_MARKER="$MARKER" ORCH_HANDOFF_STALE_MIN=60 bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"鮮度警告"* ]]

    run env ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$BINDIR/bd" \
        ORCH_HANDOFF_SYNC_MARKER="$MARKER" ORCH_HANDOFF_STALE_MIN=60 bash "$SCRIPT" --no-freshness
    [ "$status" -eq 0 ]
    [[ "$output" != *"鮮度警告"* ]]
}

@test "(7) 鮮度 unknown: marker 不在 → ⚠警告(sync 未成立の可能性を surface)" {
    run env ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$BINDIR/bd" \
        ORCH_HANDOFF_SYNC_MARKER="$TEST_TMPDIR/absent-marker" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"鮮度警告"* ]]
    [[ "$output" == *"一度も成功していない可能性"* ]]
}

@test "(8) parser OR 合成: jq 破損(exit1)でも python3 フォールバックで per-bead 保留が効く" {
    # 壊れた jq（常に exit1）を PATH 前置 → _parse_scan は jq 失敗を検出し python3 フォールバックへ。
    mkdir -p "$TEST_TMPDIR/fakebin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_TMPDIR/fakebin/jq"
    chmod +x "$TEST_TMPDIR/fakebin/jq"
    run env PATH="$TEST_TMPDIR/fakebin:$PATH" ORCH_HANDOFF_SKIP_SESSION_GATE=1 \
        ORCH_HANDOFF_BD="$BINDIR/bd" ORCH_HANDOFF_SYNC_MARKER="$TEST_TMPDIR/nomarker" \
        bash "$SCRIPT" --no-freshness
    [ "$status" -eq 0 ]
    [[ "$output" == *"scanned=3"* ]]
    [[ "$output" == *"actionable=2 triage-hold=1"* ]]   # labels を python3 が正しく解釈（sc-bbb のみ保留）
}

@test "(11) 鮮度: fresh marker(recent mtime)→ standalone でも無警告(always-warn 偽陽性回帰を捕捉)" {
    # fresh 分岐（marker 存在 ∧ age &lt;= STALE_MIN → silent return）を pin。閾値比較を無条件 true 化する
    # always-warn 回帰は stale/unknown テストを素通りするため、この正常系が守る（cell-quality finding）。
    MARKER="$TEST_TMPDIR/last-sync-fresh"; printf 'now\n' > "$MARKER"   # touch=現在時刻ゆえ age≈0（fresh）。
    run env ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$BINDIR/bd" \
        ORCH_HANDOFF_SYNC_MARKER="$MARKER" ORCH_HANDOFF_STALE_MIN=60 bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"鮮度警告"* ]]
}

@test "(12) self-scope 肯定側: orch 台帳 cwd(SKIP なし)→ gate 通過し scan が走る(always-refuse 回帰を捕捉)" {
    # foreign→refuse(5) の対の肯定パス。gate 比較を無条件 refuse 化する回帰（orch session でも動かなくなる）は
    # (5) を素通りするため、この正常系が守る（cell-quality finding）。--no-freshness で git/_resolve_scriptorium を回避。
    ORCHDIR="$TEST_TMPDIR/orch"; mkdir -p "$ORCHDIR/.beads"
    printf '{"dolt_database":"orch"}' > "$ORCHDIR/.beads/metadata.json"
    cd "$ORCHDIR"
    run env ORCH_HANDOFF_BD="$BINDIR/bd" ORCH_HANDOFF_SYNC_MARKER="$TEST_TMPDIR/nomarker" bash "$SCRIPT" --no-freshness
    [ "$status" -eq 0 ]
    [[ "$output" != *"refusing to run"* ]]
    [[ "$output" == *"scanned=3"* ]]
}

@test "(13) scan 失敗(bd rc≠0)→ standalone は非0 で終了(run_scan return 1 を pin・errata E2)" {
    # bd list が rc≠0（台帳障害等）を返したとき、standalone は「⚠ scan 失敗」で非0 終了する（検知不能を
    # green と偽らない fail-closed）。この分岐が未テストだと run_scan の return 1 を return 0 に変えても全
    # green で素通りする（gate 実測）。hook 統合側は fail-open（|| skip note）のままでよい。
    cat > "$BINDIR/bd-fail" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
    chmod +x "$BINDIR/bd-fail"
    run env ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$BINDIR/bd-fail" \
        ORCH_HANDOFF_SYNC_MARKER="$TEST_TMPDIR/no-such-marker" bash "$SCRIPT" --no-freshness
    [ "$status" -ne 0 ]
    [[ "$output" == *"scan 失敗"* ]]
}

@test "(9) 本体 --self-test が green(durable coverage pin・fail-closed)" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(10) bash -n(構文)が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

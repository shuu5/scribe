#!/usr/bin/env bats
# sc-pyab (M0 波1 L1b-Leg1) — cell-quality の **内側ループ**（収束/終端の判定）の behavioral 恒久回帰テスト。
#
# 対象は 3 点:
#   [L-A] goal-anchored severity（項目1）: severity の基準を「acceptance / fence を脅かすか」1 本へ固定した
#         rubric literal が review / verify の **双方**へ届き、verify には goal / acceptance も届く。
#   [L-B] 系統A（項目3）: hard cap 到達 = 未収束 ではない。最終 round が真にクリーン（blocking 0 かつ
#         machinery 健全）なら converged へ昇格する。過剰一般化（machineryFailed 連言外し / capFinalize の
#         後置）は否定対照が捕える。
#   [L-C] driver の round 別 stub knob（項目4）: 未設定時の挙動が **byte 単位で従来と同一**であること。
#
# 【本 file が持たないもの = churn（旧契約 ■6・admin 裁定で Leg-2 へ移送済み）】
#   churn（正味前進なし round の loud 打切り）は **本 leg の scope 外**。受入条件 v2（2026-08-01 の churn 移送
#   裁定）が旧 v1 を supersede し、churn は Leg-2 = bd sc-psuq（review barrier 化 + global dedup + global
#   severity top-K）へ移された。よって本 file に churn の tooth は **意図して 1 本も無い**（穴の放置ではなく
#   scope 分界。skip も置かない＝skip は空虚 green を作る）。
#   移送の根拠（worker 実測 → admin 裁定）: 契約どおりの述語（当 round blocking>0 ∧ dedup キー基準で前 round
#   集合と完全一致 ∧ 新規 confirmed 0）を実装すると、tests/cell-quality-cap.bats の
#   "K2': cap 未指定時の agent 呼出し列が base 木と完全一致する" の scenario 'autofix'（全 round 同一 findings・
#   全 confirmed）で round 2 に発火し、callSeq が base 木（不変 SHA 46958e5d…）と一致しなくなる
#   （実測: rounds 3→2 / agentCallTotal 56→37 / RED 1 本・他 54 本は green）。churn は **ループを早期終端させて
#   agent 呼出し列を変える**ため、landed guard K2' の期待値変更＝Leg-2 の K2' 再契約と同じ裁定束に入る。
#   （対して本 leg の系統A は呼出し列を変えず終端 flag のみ変えるので K2' を割らない＝両者の弁別根拠。）
#   churn が Leg-2 で land する際は「churn 打切り run は最終 round ではない」を系統A の連言へ足すこと（L-B4 参照）。
#
# 規律（protocol §2 / cap.bats と同じ）:
#   - 各 tooth に assertion inventory row（invariant / polarity / mutant_fingerprint）を併記する。
#     書式 SSOT = tests/wf-args-lint.bats:13（実例 :197-338）。
#   - 変異注入は BATS_TEST_TMPDIR の copy 木へ行う（実 file を変異させたまま commit しない）。
#   - pipefail 下の `producer | grep -q` を書かない（SIGPIPE で rc=141 の偽 RED になる）。herestring を使う。
#   - skip は 1 本も置かない。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"

  # worker-cell 形の基底 args（autoFix + selfTestCmd + taskType 指定＝classify を回さない決定論形）。
  # goal / acceptance は prompt 到達を grep するための sentinel（実文言に依存しない）。goal だけでなく
  # acceptance も渡す: goalAnchorBlock() は goal と refinedAcceptance の 2 要素を返すので、acceptance を
  # 渡さない args だと acceptance 分岐が一度も実行されず「受入基準が独立反証者へ届く」半分が無検証になる。
  ARGS_BASE='{"taskTitle":"loop-cell","worktree":"/tmp/wt","goal":"GOALSENTINEL-PYAB","acceptance":"ACCSENTINEL-PYAB","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable"}'
  # blocking 1 件（round を駆動する最小形）。
  FINDING_BLOCKING='[{"title":"AAA","severity":"critical","location":"a.js:1","rationale":"boundary"}]'
  # placeholder 形の finding = degFindings が発火し review が null 化する＝reviewFailed>0 を env だけで駆動できる
  # 唯一の非 cap 経路（cap 指紋例外で駆動すると capExceeded が terminal を先に倒し、系統A の連言を観測できない）。
  FINDING_DEGENERATE='[{"title":"test","severity":"critical","location":"x","rationale":"todo"}]'

  # ── driver 既定不変の対照 ref（不変 SHA へ pin・可動 ref を使わない） ──────────────
  # knob 導入前の driver を持つ **公開済み**の不変 SHA。cap.bats の CAP_BASE_REF と同じ思想:
  # 可動 ref（origin/main）にすると本 diff の land と同時に対照が HEAD 自身になり、driver 既定不変の比較が
  # 自己比較＝vacuous pass に化ける。※この pin は更新しない。
  # 【公開済み祖先であること自体が load-bearing】6d012af は origin/main（PR #156 の squash commit）であり
  # fresh clone / 他ホストでも必ず読める。本 cell の分岐点 354c706 は anchor ローカルの取込 merge で origin に
  # 存在せず（`git for-each-ref --contains` が remote-tracking ref を 1 本も返さない＝実測）、そこへ pin すると
  # L-C1 の fail-loud 分岐が anchor 以外の全ホストで恒久 RED になる。対照 blob は byte 同一
  # （tests/cell-quality-selftest.driver.mjs の sha256 が 354c706 / 6d012af とも 935ef05b…）ゆえ比較内容は不変。
  LOOP_PREV_REF="${SC_PYAB_PREV_REF:-6d012af324d0aef24f6f4841951ed0f5f21015ca}"
}

# K 行から値を取り出す（herestring 経由＝pipefail 下の SIGPIPE 偽 RED を作らない）。
kval() {
  local out="$1" key="$2"
  sed -n "s/^K ${key} //p" <<< "$out"
}

# ARGS_BASE へ JSON 片をマージする（args を手組みせず 1 経路で作る）。
lq_args() {
  node -e 'const a=JSON.parse(process.argv[1]);Object.assign(a,JSON.parse(process.argv[2]||"{}"));console.log(JSON.stringify(a))' "$ARGS_BASE" "$1"
}

# 変異木を BATS_TEST_TMPDIR に作る: WF の literal を sed で置換し、driver は最終木のものを使う。
plant_wf_mutant() {
  local dir="$1" pattern="$2" replacement="$3"
  mkdir -p "$dir/workflows" "$dir/tests"
  cp "$DRIVER" "$dir/tests/driver.mjs"
  sed "s|${pattern}|${replacement}|" "$WF" > "$dir/workflows/cell-quality.workflow.js"
  # 変異が実際に入った（no-op でない）ことを確認する＝空虚な mutation tooth を作らない。
  ! cmp -s "$WF" "$dir/workflows/cell-quality.workflow.js"
}

# driver 側の変異木（WF は現物・driver だけを変異させる）。
plant_driver_mutant() {
  local dir="$1" pattern="$2" replacement="$3"
  mkdir -p "$dir/workflows" "$dir/tests"
  cp "$WF" "$dir/workflows/cell-quality.workflow.js"
  sed "s|${pattern}|${replacement}|" "$DRIVER" > "$dir/tests/driver.mjs"
  ! cmp -s "$DRIVER" "$dir/tests/driver.mjs"
}

# ─────────────────────────────────────────────────────────────────────────────
# [L-A] goal-anchored severity（項目1）
# ─────────────────────────────────────────────────────────────────────────────

# ── L-A1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=severity rubric literal が review と verify の **両方**の prompt へ届く
#          | polarity=positive（RED→GREEN: 実装前は verify に rubric が無く promptGrepLabels が review のみ）
#          | mutant_fingerprint=WF の `${SEVERITY_RUBRIC}` 補間 2 箇所を削除（rubric 欠落）→ promptGrepCount 0
#            かつ labels から review: / verify: が消えて RED（**実走で確認する**＝文書化だけの指紋にしない）
@test "sc-pyab L-A1: severity rubric literal が review / verify 双方の prompt へ焼かれている" {
  local rubric='severity は acceptance / fence を脅かすかを唯一の基準に付与する'
  run env CQ_ARGS="$(lq_args '{}')" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=true \
      CQ_PROMPT_GREP="$rubric" node "$DRIVER" run
  [ "$status" -eq 0 ]
  local labels
  labels="$(kval "$output" promptGrepLabels)"
  [ "$(kval "$output" promptGrepCount)" -gt 0 ]
  [[ "$labels" == *"review:"* ]]
  [[ "$labels" == *"verify:"* ]]
  # 非空虚性: verify 段が実際に走っている（0 本なら上の判定は空虚に通りうる）。
  [ "$(kval "$output" verifyCallCount)" -gt 0 ]

  # 変異（rubric 欠落）: 補間 2 箇所を削除すると rubric literal がどの prompt にも届かなくなる。
  # const 定義そのものは残る＝「定義は在るが焼かれていない」という最も見落としやすい退行形を駆動する。
  local mut="$BATS_TEST_TMPDIR/mu-a1"
  plant_wf_mutant "$mut" '\${SEVERITY_RUBRIC}' ''
  run env CQ_ARGS="$(lq_args '{}')" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=true \
      CQ_PROMPT_GREP="$rubric" node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" promptGrepCount)" -eq 0 ]
  labels="$(kval "$output" promptGrepLabels)"
  [[ "$labels" != *"review:"* ]]
  [[ "$labels" != *"verify:"* ]]
  # 変異木でも verify 段は走っている（＝rubric が消えたことだけを観測している）。
  [ "$(kval "$output" verifyCallCount)" -gt 0 ]
}

# ── L-A2 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=verify prompt へ goal **と acceptance の 2 つとも**（＝受入の定義）が届く
#            （goal-anchored severity の前提。goal だけ pin すると acceptance 要素の脱落を検知できない）
#          | polarity=positive（RED→GREEN: 実装前の verifyPrompt は finding + diff だけで goal も acceptance も持たない）
#          | mutant_fingerprint=(a) verifyPrompt 冒頭の `${goalAnchorBlock()}` を削除 → verify: が labels から消え RED
#            / (b) goalAnchorBlock() の `refinedAcceptance ? ... : ''` を `''` にする（acceptance 要素だけ落とす）
#            → acceptance sentinel 側の run で verify: が消え RED（実走で確認する）
@test "sc-pyab L-A2: verify prompt へ goal / acceptance（受入の定義）が両方届く" {
  local a
  a="$(lq_args '{}')"
  local sentinel
  for sentinel in GOALSENTINEL-PYAB ACCSENTINEL-PYAB; do
    echo "# sentinel: $sentinel"
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=true \
        CQ_PROMPT_GREP="$sentinel" node "$DRIVER" run
    [ "$status" -eq 0 ]
    local labels
    labels="$(kval "$output" promptGrepLabels)"
    [[ "$labels" == *"verify:"* ]]
    [[ "$labels" == *"review:"* ]]
    # 非空虚性: verify 段が実際に走っている。
    [ "$(kval "$output" verifyCallCount)" -gt 0 ]
  done

  # 変異: goalAnchorBlock の acceptance 要素だけを落とすと acceptance sentinel が verify へ届かなくなる
  # （goal 側は届いたままなので「goal だけ pin」では検知できない＝本 tooth が acceptance を実際に守っている証拠）。
  local mut="$BATS_TEST_TMPDIR/mu-a2"
  # 置換対象は goalAnchorBlock の行だけ（ctxBlock の同型式は行末が `,` ゆえ一致しない＝review 側は変異させない）。
  plant_wf_mutant "$mut" "refinedAcceptance ? \`acceptance(受入基準):.n\${refinedAcceptance}\` : '']" "'']"
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=true \
      CQ_PROMPT_GREP='ACCSENTINEL-PYAB' node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  labels="$(kval "$output" promptGrepLabels)"
  [[ "$labels" != *"verify:"* ]]
  # goal 側は変異後も届く（変異が acceptance 要素だけを落としたことの確認＝過剰な変異でない）。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=true \
      CQ_PROMPT_GREP='GOALSENTINEL-PYAB' node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  labels="$(kval "$output" promptGrepLabels)"
  [[ "$labels" == *"verify:"* ]]
}

# ── L-A3 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=goal-anchor は **contextFile を verify へ持ち込まない**（sc-mbcm [2] の独立性設計を壊さない）
#          | polarity=negative（交差 file tests/cell-quality-contextfile.bats の landed tooth と同じ不変条件を
#            本 leg 側でも pin する＝本 diff が独立反証者へ大文脈を漏らしていない証拠）
#          | mutant_fingerprint=goalAnchorBlock() を ctxBlock() に置換 → verify: が labels に現れ RED
@test "sc-pyab L-A3: goal-anchor は verify prompt へ contextFile を持ち込まない（独立性設計の維持）" {
  run env CQ_ARGS="$(lq_args '{"contextFile":"/tmp/ctx/brief.md"}')" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" \
      CQ_VERIFY_REFUTED=true CQ_PROMPT_GREP='context file: /tmp/ctx/brief.md' node "$DRIVER" run
  [ "$status" -eq 0 ]
  local labels
  labels="$(kval "$output" promptGrepLabels)"
  [[ "$labels" == *"review:"* ]]
  [[ "$labels" != *"verify:"* ]]
  [ "$(kval "$output" verifyCallCount)" -gt 0 ]
}

# ── L-A4 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=rubric の SSOT が 1 箇所（const SEVERITY_RUBRIC）で review/verify はそれを参照する
#            ＝2 箇所へ文言を書き写して drift させていない
#          | polarity=positive（静的 pin）
#          | mutant_fingerprint=`const SEVERITY_RUBRIC = ` を削除（＝各 prompt へ文言を直書き）→ 本 tooth が RED
@test "sc-pyab L-A4: rubric は単一 const を review/verify が参照する（文言の二重管理をしない）" {
  [ "$(grep -Fc 'const SEVERITY_RUBRIC = ' "$WF")" -eq 1 ]
  # 参照は 2 箇所（reviewPrompt / verifyPrompt）。
  [ "$(grep -Fc '${SEVERITY_RUBRIC}' "$WF")" -eq 2 ]
  # rubric 骨子の 2 文（契約 ■scope 1 の literal）が SSOT 側に在る。
  local body
  body="$(sed -n '/^const SEVERITY_RUBRIC = /,/^$/p' "$WF")"
  grep -qF 'severity は acceptance / fence を脅かすかを唯一の基準に付与する' <<< "$body"
  grep -qF 'args の acceptance が定型文の場合は contextFile を優先する' <<< "$body"
}

# ─────────────────────────────────────────────────────────────────────────────
# [L-B] 系統A（項目3）: hard cap 到達 ≠ 未収束
# ─────────────────────────────────────────────────────────────────────────────

# ── L-B1（正方向・唯一の RED→GREEN tooth）───────────────────────────────────
# inventory: invariant=hard cap へ自然到達した最終 round が真にクリーンなら converged（＝「2 度目のゼロを
#            確認する round が残っていなかっただけ」を未収束へ倒さない）
#          | polarity=positive（RED→GREEN。実装前の実測: converged=false / escalate=true / gatePrefix=ESCALATE /
#            ESCALATE_REASON='hard cap 3 到達・未収束(critical/major が 2 連続ゼロに至らず)'）
#          | mutant_fingerprint=`round >= effectiveCap && !capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1`
#            → `false`（系統A 昇格の除去）→ converged=false で RED
@test "sc-pyab L-B1: round3 で初めてクリーンになった loop run は converged（系統A）" {
  local a
  a="$(lq_args '{}')"
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND='{"3":[]}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" rounds)" -eq 3 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
  # 非空虚性: round1/2 では実際に blocking を検出して fix を回している（＝最初からクリーンな run ではない）。
  [ "$(kval "$output" blockingCount)" -gt 0 ]
  grep -qF 'autofix r2' <<< "$(kval "$output" callSeq)"

  # 変異: 系統A 昇格を除去すると従来どおり ESCALATE へ倒れる（本 tooth が空虚でない証拠）。
  local mut="$BATS_TEST_TMPDIR/mu-b1"
  plant_wf_mutant "$mut" 'round >= effectiveCap \&\& !capTerminatedEarly(round, effectiveCap) \&\& zeroStreak >= 1' 'false'
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND='{"3":[]}' node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "true" ]
}

# ── L-B2（否定対照 1）────────────────────────────────────────────────────────
# inventory: invariant=最終 round が blocking=0 でも machinery 失敗（reviewFailed>0）なら converged を立てず
#            escalate へ倒す（machinery 失敗 round の 0 は「クリーン」ではない）
#          | polarity=negative / mutant-RED（現 main で既に GREEN ゆえ baseline-RED を要求しない）
#          | mutant_fingerprint=`capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1`
#            → `capTerminatedEarly(round, effectiveCap) && lastH.confirmedBlocking === 0`
#            （machineryFailed 連言を外す過剰一般化）→ converged=true / escalate=false で RED
@test "sc-pyab L-B2: 最終 round が blocking=0 でも reviewFailed>0 なら converged を立てない" {
  local a
  a="$(lq_args '{}')"
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND="{\"3\":$FINDING_DEGENERATE}" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" rounds)" -eq 3 ]
  # 前提の非空虚性: 最終 round は blocking=0 かつ reviewFailed>0（＝この tooth が狙う modality に居る）。
  local last
  last="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const h=JSON.parse(m[1]).history;const l=h[h.length-1];console.log(`${l.confirmedBlocking},${l.reviewFailed}`)' "$output")"
  [ "$last" = "0,4" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]

  # 変異: machineryFailed 連言を外す（lastH.confirmedBlocking === 0 の単独条件へ過剰一般化）と誤収束する。
  local mut="$BATS_TEST_TMPDIR/mu-b2"
  plant_wf_mutant "$mut" 'capTerminatedEarly(round, effectiveCap) \&\& zeroStreak >= 1' \
      'capTerminatedEarly(round, effectiveCap) \&\& lastH.confirmedBlocking === 0'
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND="{\"3\":$FINDING_DEGENERATE}" node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" converged)" = "true" ]
}

# ── L-B3（否定対照 2）────────────────────────────────────────────────────────
# inventory: invariant=最終 round が真にクリーン（blocking 0 ∧ unverified 0 ∧ machinery 健全）でも
#            capExceeded=true なら系統A の昇格をしない＝終端は **escalate 網**（gatePrefix=ESCALATE）で
#            確定する（cap 発火 run は「幅を落として走った」＝真にクリーンだと主張できない）
#          | polarity=negative / mutant-RED
#          | mutant_fingerprint=昇格の連言から `!capExceeded && ` を削除 → 昇格が converged=true を立てて
#            直下の escalate 網（zeroStreak < 2）を丸ごと skip し、capFinalize が converged だけを剥がすため
#            converged=false ∧ escalate=false = **gatePrefix OPEN**（sc-k33c errata が封鎖した loop-mode
#            fail-open）へ落ちる＝本 tooth が RED（実走で確認する）
#
# 【シナリオ選定の load-bearing な注意】throw を round 限定しない（CQ_THROW_AT_ROUND 未設定）と、全 round の
# verify が落ちて毎 round が blocking 0 ∧ machineryFailed false になり zeroStreak が 2 に達して **rounds=2 で
# ループ内 converged が立つ**（実測）。その run は round < effectiveCap ゆえ系統A の昇格 if を評価すらせず、
# capFinalize が zeroStreak 由来の converged を落とすだけの経路になる＝`!capExceeded` 連言の behavioral tooth に
# ならない（空虚 tooth）。よって throw は **round1 に限定**し、round2 で blocking を再検出して zeroStreak を
# 0 へ戻してから round3 で初めてクリーンにする＝hard cap へ自然到達した最終 round で昇格 if が実際に評価される
# 状態を作る（実測 rounds=3 / capExceeded=true / 最終 round は blocking 0・unverified 0・reviewFailed 0）。
@test "sc-pyab L-B3: 最終 round が clean でも capExceeded なら converged を立てず escalate（昇格が cap 網に負ける）" {
  local a
  a="$(lq_args '{}')"
  # round1 の verify だけ cap 指紋例外 → capExceeded=true かつ round1 は unverified 行き（blocking 0）。
  # round2 は既定どおり blocking 4 を confirm（zeroStreak を 0 へ戻す）。round3 は findings 空＝真にクリーン。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND='{"3":[]}' CQ_THROW_AT_LABEL='verify:' CQ_THROW_AT_ROUND=1 \
      CQ_THROW_KIND=quota node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 前提の非空虚性: hard cap へ自然到達し（rounds=3）、最終 round は `!capExceeded` 以外の昇格連言をすべて
  # 満たす（blocking 0 / unverified 0 / reviewFailed 0）＝昇格 if が実際に評価され `!capExceeded` だけで落ちる。
  [ "$(kval "$output" rounds)" -eq 3 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  local last
  last="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const h=JSON.parse(m[1]).history;const l=h[h.length-1];console.log(`${l.confirmedBlocking},${l.unverified},${l.reviewFailed}`)' "$output")"
  [ "$last" = "0,0,0" ]
  [ "$(kval "$output" converged)" = "false" ]
  # converged=false だけでは capFinalize の落とし直しと区別できない（OPEN 退行を見逃す）ため終端も pin する。
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]

  # 変異: 昇格の連言から `!capExceeded` を外すと、cap 発火 run を「真にクリーン」と誤読して converged=true を
  # 立て、直下の escalate 網を飛ばす。capFinalize が converged を false へ戻すので終端は
  # converged=false ∧ escalate=false = gatePrefix OPEN（fail-open）になる。
  local mut="$BATS_TEST_TMPDIR/mu-b3"
  plant_wf_mutant "$mut" '!capExceeded \&\& ' ''
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND='{"3":[]}' CQ_THROW_AT_LABEL='verify:' CQ_THROW_AT_ROUND=1 \
      CQ_THROW_KIND=quota node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" gatePrefix)" = "OPEN" ]
}

# ── L-B4（否定対照 3）────────────────────────────────────────────────────────
# inventory: invariant=cap 由来の早期打切り run は「最終 round」ではない＝0 blocking でも converged を立てず、
#            終端は **capLoopEscalate 経由**（escalateReason='cap 由来の早期打切り(round N/3・reason=cap)…'）で
#            確定する（＝系統A の昇格が escalate 分岐を飛び越していない）
#            （churn 打切り run も land 時は同じ扱いにする＝連言へ churnTerminatedEarly を足すこと）
#          | polarity=negative / mutant-RED
#          | mutant_fingerprint=`!capExceeded && round >= effectiveCap && !capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1`
#            → `zeroStreak >= 1`（cap 網 + 自然到達の連言を外す過剰一般化）→ 昇格が escalate 分岐を飛ばし、終端文言が
#            capFinalize 経由の 'cap 発火(reason=cap)で blocking 級 …' へ変わる（'cap 由来の早期打切り' が消える）
#            ＝本 tooth が RED（実走で確認する）
@test "sc-pyab L-B4: cap 由来の早期打切り run は 0 blocking でも converged を立てない" {
  # totalBudget を絞り round 頭 gate（層2-①）で打ち切らせる。findings は空＝各 round は真にクリーン。
  # 免除段下限（self-test 2 + round1 snapshot 1）+ review 4 + reserve 1 を跨ぐ値を掃引する。
  local tb reason
  for tb in 8 9 10; do
    echo "# totalBudget=$tb"
    run env CQ_ARGS="$(lq_args "{\"totalBudget\":$tb}")" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true node "$DRIVER" run
    [ "$status" -eq 0 ]
    # 早期打切り（rounds < maxRounds=3）かつ cap 発火。
    [ "$(kval "$output" rounds)" -lt 3 ]
    [ "$(kval "$output" capExceeded)" = "true" ]
    [ "$(kval "$output" converged)" = "false" ]
    # 終端の**経路**を pin する: capLoopEscalate（＝loop 終端の escalate 分岐）を通っていること。
    # converged=false だけでは昇格が escalate 分岐を飛ばした場合と区別できない（capFinalize が converged を
    # 落とし直すため同値になる）＝この文言 assert が本 tooth の mutant-RED 極性を担保する。
    reason="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).escalateReason||"")' "$output")"
    grep -qF 'cap 由来の早期打切り' <<< "$reason"
  done

  # 変異: 自然到達の連言（round >= effectiveCap ∧ !capTerminatedEarly）を外して zeroStreak 単独へ過剰一般化すると、
  # 昇格が converged=true を立てて escalate 分岐を丸ごと飛ばす。capFinalize が converged を false へ戻すため
  # converged 値だけは同値に見えるが、escalateReason が capFinalize 経由の文言へ変わる＝そこで捕える。
  local mut="$BATS_TEST_TMPDIR/mu-b4"
  plant_wf_mutant "$mut" '!capExceeded \&\& round >= effectiveCap \&\& !capTerminatedEarly(round, effectiveCap) \&\& zeroStreak >= 1' 'zeroStreak >= 1'
  for tb in 8 9 10; do
    echo "# mutant totalBudget=$tb"
    run env CQ_ARGS="$(lq_args "{\"totalBudget\":$tb}")" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true node "$mut/tests/driver.mjs" run
    [ "$status" -eq 0 ]
    reason="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).escalateReason||"")' "$output")"
    ! grep -qF 'cap 由来の早期打切り' <<< "$reason"
  done
}

# ── L-B5 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=系統A の判定は「その round の confirmed」だけを見る＝監査用累積 allBlocking を混ぜない
#            / 数値既定（maxRounds=3・zeroStreak>=2）は不変 / 昇格は capFinalize 呼出より前
#          | polarity=positive（静的 pin）
#          | mutant_fingerprint=昇格の if を capFinalize 呼出の後ろへ移動 → 行番号順序の assert が RED
@test "sc-pyab L-B5: 系統A の静的不変条件（allBlocking 非混入 / 数値既定不変 / capFinalize より前）" {
  # 数値既定は不変（構造のみ変更）。
  grep -qF 'A.maxRounds > 0 ? A.maxRounds : 3' "$WF"
  [ "$(grep -Fc 'if (zeroStreak >= 2) {' "$WF")" -eq 1 ]
  # 系統A の昇格行に allBlocking を混ぜていない（union 非縮小化＝監査用累積を判定へ入れない）。
  local line
  line="$(grep -F 'round >= effectiveCap && !capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1' "$WF")"
  [ -n "$line" ]
  [[ "$line" != *"allBlocking"* ]]
  # 昇格は capFinalize 呼出より前（後置すると capExceeded → converged=false の強制を上書きする）。
  local promote finalize
  promote="$(grep -Fn 'round >= effectiveCap && !capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1' "$WF" | cut -d: -f1)"
  finalize="$(grep -Fn 'const capFinal = capFinalize(' "$WF" | cut -d: -f1)"
  [ -n "$promote" ] && [ -n "$finalize" ]
  [ "$promote" -lt "$finalize" ]
}

# ── L-B6 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=single / light 経路は系統A で 1 mm も変わらない（昇格は loop モードの分岐内に閉じる）
#          | polarity=negative
#          | mutant_fingerprint=昇格の if を `if (canAutoFix && !LIGHT_TYPES.has(taskType)) {` ブロックの外へ
#            出す → single モードの blocking 有り run が converged=true になり RED
@test "sc-pyab L-B6: single / light モードの終端は系統A の影響を受けない" {
  # single モード（autoFix なし・静的 diff 供給）で blocking あり → 従来どおり OPEN。
  run env CQ_ARGS='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n","taskType":"testable"}' \
      CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" autoFix)" = "false" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" gatePrefix)" = "OPEN" ]
  # light type（monitoring）は effectiveCap=1 の 1 round のみ＝clean なら従来どおり CONVERGED。
  run env CQ_ARGS="$(lq_args '{"taskType":"monitoring"}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" rounds)" -eq 1 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
}

# ── L-B7（否定対照 4）────────────────────────────────────────────────────────
# inventory: invariant=最終 round に confirmed blocking が残る run は converged を立てず escalate=true
#            （系統A の昇格が「最終 round を無条件 converged にする」方向へ過剰一般化されると、confirmed
#            blocking を抱えたままの silent ship が起きる。他の否定対照は最終 round blocking=0 の modality
#            しか覆っていないので、blocking>0 側はこの tooth だけが守る）
#          | polarity=negative / mutant-RED（現 main で既に GREEN ゆえ baseline-RED を要求しない）
#          | mutant_fingerprint=昇格の連言
#            `!capExceeded && round >= effectiveCap && !capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1 && !(lastH.unverified > 0)`
#            → `round >= effectiveCap`（最終 round を無条件 converged にする過剰一般化）
#            → converged=true / escalate=false / gatePrefix=CONVERGED で RED
@test "sc-pyab L-B7: 最終 round に blocking が残る run は converged を立てず escalate（silent ship 禁止）" {
  local a
  a="$(lq_args '{}')"
  # round 別 knob 無し＝全 round で blocking 4 件が confirmed される（cap 引数も無し＝既定路）。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" rounds)" -eq 3 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
  # 前提の非空虚性: 最終 round は blocking>0（この tooth が狙う modality に居る）。
  local lastBlocking
  lastBlocking="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const h=JSON.parse(m[1]).history;console.log(h[h.length-1].confirmedBlocking)' "$output")"
  [ "$lastBlocking" -gt 0 ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]

  # 変異: 系統A を「最終 round なら無条件 converged」へ過剰一般化する（＝連言をすべて外す）と、
  # confirmed blocking を抱えたまま CONVERGED が出る。
  local mut="$BATS_TEST_TMPDIR/mu-b7"
  plant_wf_mutant "$mut" \
      '!capExceeded \&\& round >= effectiveCap \&\& !capTerminatedEarly(round, effectiveCap) \&\& zeroStreak >= 1 \&\& !(lastH.unverified > 0)' \
      'round >= effectiveCap'
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
}

# ── L-B8（否定対照 5）────────────────────────────────────────────────────────
# inventory: invariant=verify 段が落ちて unverified が残る round は「真にクリーン」ではない＝blocking 0 でも
#            converged を立てず escalate（zeroStreak が含意する machineryFailed は reviewFailed / snapshotFailed
#            だけで **verify 段の失敗を含まない**＝この穴を昇格の連言 `!(lastH.unverified > 0)` が塞ぐ）
#          | polarity=negative / mutant-RED
#          | mutant_fingerprint=昇格の連言から ` && !(lastH.unverified > 0)` を削除
#            → converged=true / escalate=false / gatePrefix=CONVERGED で RED
@test "sc-pyab L-B8: verify 全滅で unverified が残る round は clean ではない（converged を立てない）" {
  local a
  a="$(lq_args '{}')"
  # round1/2 は blocking 4 を confirm、round3 だけ verify が **非 cap(plain)例外**で全滅する
  # → verdict:null → unverified 4 / confirmed 0 / reviewFailed 0（＝blocking 0 かつ machineryFailed false）。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_THROW_AT_LABEL='verify:' CQ_THROW_KIND=plain CQ_THROW_AT_ROUND=3 node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" rounds)" -eq 3 ]
  # 前提の非空虚性: cap 経路ではない（plain=cap 指紋なし）＝この tooth は unverified 連言だけを駆動している。
  [ "$(kval "$output" capExceeded)" = "false" ]
  local last
  last="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const h=JSON.parse(m[1]).history;const l=h[h.length-1];console.log(`${l.confirmedBlocking},${l.unverified},${l.reviewFailed}`)' "$output")"
  [ "$last" = "0,4,0" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]

  # 変異: unverified 連言を外すと「反証機構が全滅した round」を真にクリーンと誤読して CONVERGED を返す。
  local mut="$BATS_TEST_TMPDIR/mu-b8"
  plant_wf_mutant "$mut" ' \&\& !(lastH.unverified > 0)' ''
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_THROW_AT_LABEL='verify:' CQ_THROW_KIND=plain CQ_THROW_AT_ROUND=3 node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [L-C] driver の round 別 stub knob（項目4）
# ─────────────────────────────────────────────────────────────────────────────

# ── L-C1（既定不変の behavioral pin・cap.bats base 対照を守る核）──────────────
# inventory: invariant=round 別 knob 未設定時、driver の出力（K 行 + RESULT）が knob 導入前の driver と
#            **byte 単位で同一**（cap.bats の base 木対照 3 本は HEAD driver を base 木へ cp する現物対現物
#            比較ゆえ、既定挙動が 1 mm でも変わると base 対照が false RED になる）
#          | polarity=positive
#          | mutant_fingerprint=`byRound(REVIEW_FINDINGS_BY_ROUND, label, REVIEW_FINDINGS)`
#            → `byRound(REVIEW_FINDINGS_BY_ROUND, label, [])`（knob 未設定時の既定を変える）→ 対照 driver と
#            出力が食い違い RED（**実走で確認する**＝この変異こそ cap.bats base 対照 3 本を false RED にする形）
@test "sc-pyab L-C1: round 別 knob 未設定時の driver 出力は導入前と byte 一致（cap.bats base 対照を割らない）" {
  local prev="$BATS_TEST_TMPDIR/prevdrv"
  mkdir -p "$prev/tests" "$prev/workflows"
  # 対照 = 不変 SHA の driver（knob 導入前）。到達不能なら skip でなく loud fail（対照の空虚化を許さない）。
  if ! git -C "$REPO_ROOT" cat-file -e "${LOOP_PREV_REF}:tests/cell-quality-selftest.driver.mjs" 2>/dev/null; then
    echo "# FATAL: 対照 ref '${LOOP_PREV_REF}' から driver を読めない（shallow clone / gc / 別リポ）。" >&2
    echo "#        対照が消えたまま green を返すのは fail-open。SC_PYAB_PREV_REF で本 diff の base を指定せよ。" >&2
    return 1
  fi
  git -C "$REPO_ROOT" show "${LOOP_PREV_REF}:tests/cell-quality-selftest.driver.mjs" > "$prev/tests/driver.mjs"
  # 対照 driver が knob 未導入であること（＝自己比較になっていない非空虚性の確認）。
  ! grep -qF 'CQ_REVIEW_FINDINGS_BY_ROUND' "$prev/tests/driver.mjs"
  # WF は **現物**（HEAD）を使う: 比較対象は driver の既定挙動のみで、WF 側の変更差分は両者に等しく効く。
  cp "$WF" "$prev/workflows/cell-quality.workflow.js"

  local scenario a findings refuted prev_out head_out
  for scenario in clean autofix single; do
    echo "# scenario: $scenario"
    case "$scenario" in
      clean)   a="$(lq_args '{}')"; findings='[]'; refuted=true ;;
      autofix) a="$(lq_args '{}')"; findings="$FINDING_BLOCKING"; refuted=false ;;
      single)  a='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n","taskType":"testable"}'; findings="$FINDING_BLOCKING"; refuted=true ;;
    esac
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$findings" CQ_VERIFY_REFUTED="$refuted" node "$prev/tests/driver.mjs" run
    [ "$status" -eq 0 ]
    prev_out="$output"
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$findings" CQ_VERIFY_REFUTED="$refuted" node "$DRIVER" run
    [ "$status" -eq 0 ]
    head_out="$output"
    [ -n "$prev_out" ]
    [ "$prev_out" = "$head_out" ]
  done

  # 変異（driver knob 既定変更）: 未設定時の既定を [] へ変えると、対照 driver との byte 一致が崩れる。
  # ＝本 tooth が「既定不変」を実際に守っている証拠であり、同時に cap.bats の base 木対照 3 本
  # （HEAD driver を base 木へ cp する現物対現物比較）が false RED になる形そのもの。
  local mut="$BATS_TEST_TMPDIR/mu-c1"
  plant_driver_mutant "$mut" 'byRound(REVIEW_FINDINGS_BY_ROUND, label, REVIEW_FINDINGS)' \
      'byRound(REVIEW_FINDINGS_BY_ROUND, label, [])'
  a="$(lq_args '{}')"
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false node "$prev/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  prev_out="$output"
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$prev_out" != "$output" ]
}

# ── L-C2 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=既定不変が「knob を読んでいないから」ではなく「未設定時だけ既定へ倒す」ことによる
#            （knob を設定すれば round 別に効く＝L-C1 が空虚 green でない証拠）+ 未知 round は既定へ倒す
#          | polarity=positive
#          | mutant_fingerprint=`byRound(VERIFY_REFUTED_BY_ROUND, label, VERIFY_REFUTED)`
#            → `VERIFY_REFUTED`（verify 側 knob の無効化）→ round 別 refuted が効かず RED
@test "sc-pyab L-C2: round 別 knob は設定時にのみ round 単位で効く（未指定 round は既定へ倒す）" {
  local a
  a="$(lq_args '{}')"
  # review knob: round2 だけ clean にする → round1 blocking / round2 clean / round3 blocking（既定へ復帰）。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_REVIEW_FINDINGS_BY_ROUND='{"2":[]}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  local per_round
  per_round="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).history.map(h=>h.confirmedBlocking).join(","))' "$output")"
  [ "$per_round" = "4,0,4" ]
  # verify knob: round1 だけ refute（＝confirmed 0）にする → round1 は clean、round2 以降は既定（confirmed）。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_VERIFY_REFUTED_BY_ROUND='{"1":true}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  per_round="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).history.map(h=>h.confirmedBlocking).join(","))' "$output")"
  [ "$per_round" = "0,4,4" ]

  # 変異: verify 側 knob を無効化すると round 別指定が効かなくなる（本 tooth が空虚でない証拠）。
  local mut="$BATS_TEST_TMPDIR/mu-c2"
  plant_driver_mutant "$mut" 'byRound(VERIFY_REFUTED_BY_ROUND, label, VERIFY_REFUTED)' 'VERIFY_REFUTED'
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_BLOCKING" CQ_VERIFY_REFUTED=false \
      CQ_VERIFY_REFUTED_BY_ROUND='{"1":true}' node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  per_round="$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).history.map(h=>h.confirmedBlocking).join(","))' "$output")"
  [ "$per_round" != "0,4,4" ]
}

#!/usr/bin/env bats
# cell-quality.workflow.js の「selfTestCmd 常時実行へ昇格」(sc-jx8)の driver-harness テスト。
#
# 検証対象(受入 B1-B5):
#   B1: 返り値 JSON に baseline selfTestCmd ログ(実行有無 + 生ログ + pass/fail 判定)が載る。
#   B2: 返り値 JSON に終了時(final) selfTestCmd ログが載る。
#   B3: selfTestCmd 未定義 bead では baseline/final を graceful skip(fail-open・skip を JSON へ明示)。
#   B4: 既存利用箇所の回帰なし(autoFix fail-closed ゲート / read-only gate 経路 / escalate 判定 / snapshot 合成)。
#       — 特に baseline/final は【情報ログ専用】で escalate/converged を駆動しないこと(red でも収束が変わらない)。
#   B5: runnable な driver harness(本 file + cell-quality-selftest.driver.mjs)。node --check も通す。
#
# cell-quality.workflow.js は Workflow tool 専用モジュール(top-level await/return + export ゆえ生ファイルは
# node import/`node --check` 不可)。driver は Workflow tool の wrapping を再現(export 剥がし → async 関数で包み →
# agent/log/phase 等を stub 注入 → return 値を捕捉)して挙動を実走検証する(消失していた cell-quality-*-driver.mjs
# 方式・doobidoo 9bf589cd)。stub の agent 応答は CQ_* 環境変数で制御する。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  SELFTEST="$REPO_ROOT/scripts/scribe-selftest-args.sh" # (sc-94z) 標準 worker 経路の args 生成器(e2e sc-o10 assert 用)
  # worker-cell(autoFix)の完全な args(fail-fast を通過する最小充足)。
  ARGS_WORKER='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable"}'
  # single モード(autoFix off)= selfTestCmd 未定義。静的 diff を渡してレビュー対象を確保。
  ARGS_NOSELF='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","taskType":"testable","diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-o\n+n\n"}'
}

# ── B5(iv): wrap 済みソースが構文的に valid(node --check 相当) ─────────────────
@test "sc-jx8 B5: wrap 済みソースが node --check を通る(生ファイルは top-level await/return で不可ゆえ wrap 後を検証)" {
  [ -f "$DRIVER" ]
  [ -f "$WF" ]
  wrapped="$BATS_TEST_TMPDIR/cq-wrapped.mjs"
  node "$DRIVER" emit-wrapped > "$wrapped"
  [ -s "$wrapped" ]
  run node --check "$wrapped"
  [ "$status" -eq 0 ]
}

# ── B1/B2: selfTestCmd 定義時 baseline+final の生ログ+実行有無+pass/fail が返り値に載る ──────────
@test "sc-jx8 B1/B2: selfTestCmd 定義時 baseline/final の生ログ・実行有無・pass/fail が返り値 JSON に載る" {
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  # baseline(B1): 存在・実行有無 ran・生ログ有・pass 判定
  [[ "$output" == *"K selfTestBaseline.present true"* ]]
  [[ "$output" == *"K selfTestBaseline.ran true"* ]]
  [[ "$output" == *"K selfTestBaseline.skipped false"* ]]
  [[ "$output" == *"K selfTestBaseline.hasRawLog true"* ]]
  [[ "$output" == *"K selfTestBaseline.passed true"* ]]
  # final(B2): 同上
  [[ "$output" == *"K selfTestFinal.present true"* ]]
  [[ "$output" == *"K selfTestFinal.ran true"* ]]
  [[ "$output" == *"K selfTestFinal.skipped false"* ]]
  [[ "$output" == *"K selfTestFinal.hasRawLog true"* ]]
  [[ "$output" == *"K selfTestFinal.passed true"* ]]
  # 生ログが実体(RESULT JSON に stub の生ログ文字列が入っている)。
  [[ "$output" == *"STUB_BASELINE_LOG"* ]]
  [[ "$output" == *"STUB_FINAL_LOG"* ]]
}

# ── baseline は「実装前」= implement/review より前に実行される(regression 起点) ────────────────
@test "sc-jx8: baseline は review より前・final より前に実行される(実装前=regression 起点・順序)" {
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K baselineBeforeReview true"* ]]
  [[ "$output" == *"K baselineBeforeFinal true"* ]]
  # baseline + final の 2 回だけ selfTest runner が呼ばれる(過剰実行しない)。
  [[ "$output" == *"K selftestAgentCalls 2"* ]]
}

# ── 核心 invariant を pin(cell-quality gate minor 対応): baseline は Implement agent より前に走る ─────
# ARGS_WORKER(doImplement 未設定)経路では implement agent が走らず baselineBeforeImplement='na' になり、
# 「baseline を Implement 後へ動かす」退行を全テストが緑のまま見逃す(cell-quality WF completeness-critic 指摘)。
# doImplement:true 経路を明示的に敷き、runSelfTest('baseline') が `if(doImplement)` 分岐より前に在る
# =「実装前=regression 起点」という本変更の核心 invariant を behavioral に固定する。
@test "sc-jx8: baseline は doImplement=true 経路で Implement agent より前に実行される(実装前=regression 起点の核心 invariant を pin)" {
  # doImplement:true(WF が実装も回す)+ selfTestCmd 定義(baseline を実走させる)。autoFix 無し=single モード。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","doImplement":true,"taskType":"testable"}' \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # baseline が Implement agent より前(=実装前)であることを behavioral に固定する('na' でなく true)。
  [[ "$output" == *"K baselineBeforeImplement true"* ]]
  [[ "$output" == *"K baselineBeforeReview true"* ]]
  # baseline/final は依然両方走り、shape も維持。
  [[ "$output" == *"K selfTestBaseline.ran true"* ]]
  [[ "$output" == *"K selfTestFinal.ran true"* ]]
}

# ── B3: selfTestCmd 未定義 → graceful skip(fail-open・agent を一切起動しない) ──────────────────
@test "sc-jx8 B3: selfTestCmd 未定義 bead は baseline/final を graceful skip(fail-open・skip を JSON へ明示)" {
  run env CQ_ARGS="$ARGS_NOSELF" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K selfTestBaseline.present true"* ]]
  [[ "$output" == *"K selfTestBaseline.skipped true"* ]]
  [[ "$output" == *"K selfTestBaseline.ran false"* ]]
  [[ "$output" == *"K selfTestFinal.skipped true"* ]]
  [[ "$output" == *"K selfTestFinal.ran false"* ]]
  # fail-open: skip 時は self-test runner agent を一切起動しない。
  [[ "$output" == *"K selftestAgentCalls 0"* ]]
  # 未定義でも WF 自体は正常収束する(baseline/final 欠如は escalate を招かない)。
  [[ "$output" == *"K converged true"* ]]
  [[ "$output" == *"K escalate false"* ]]
}

# ── B4-a: 既存 autoFix fail-closed ゲートが不変(confirmed blocking + self-test 失敗 → escalate) ──────
@test "sc-jx8 B4: 既存 autoFix fail-closed ゲートが不変(Fix の self-test 失敗で escalate・baseline/final は別途実行)" {
  run env CQ_ARGS="$ARGS_WORKER" \
    CQ_REVIEW_FINDINGS='[{"title":"bug A","severity":"critical","location":"x:1","rationale":"boom"}]' \
    CQ_VERIFY_REFUTED=false CQ_FIX_SELFTEST_PASSED=false \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 既存の Fix agent 内 fail-closed ゲートが発火して escalate(挙動不変)。
  [[ "$output" == *"K escalate true"* ]]
  [[ "$output" == *"K gatePrefix ESCALATE"* ]]
  [[ "$output" == *"self-test 失敗/未実行(fail-closed)"* ]]
  # かつ新設 baseline/final は Fix ゲートとは別に実行されている(温存=独立追加)。
  [[ "$output" == *"K selfTestBaseline.ran true"* ]]
  [[ "$output" == *"K selfTestFinal.ran true"* ]]
}

# ── B4-b(核心): baseline/final が red でも escalate/converged を駆動しない(情報ログ専用) ───────────
@test "sc-jx8 B4: baseline/final の self-test が red(passed=false)でも escalate せず収束する(情報ログ専用=escalate 判定不変)" {
  run env CQ_ARGS="$ARGS_WORKER" \
    CQ_BASELINE_PASSED=false CQ_FINAL_PASSED=false \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # baseline/final は red だが、review が clean なら従来通り収束(baseline/final は制御フローを動かさない)。
  [[ "$output" == *"K selfTestBaseline.passed false"* ]]
  [[ "$output" == *"K selfTestFinal.passed false"* ]]
  [[ "$output" == *"K converged true"* ]]
  [[ "$output" == *"K escalate false"* ]]
}

# ── B4-c: self-test runner agent の失敗は fail-open(WF は止めず error を JSON へ明示) ──────────────
@test "sc-jx8 B4: baseline runner agent の失敗は fail-open(error を明示し WF は収束を続行)" {
  run env CQ_ARGS="$ARGS_WORKER" CQ_SELFTEST_AGENT_FAIL=baseline node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K selfTestBaseline.error true"* ]]
  [[ "$output" == *"K selfTestBaseline.ran false"* ]]
  # runner 失敗でも WF 本体は収束(baseline 取得失敗は情報欠落であって escalate 事由でない)。
  [[ "$output" == *"K converged true"* ]]
  [[ "$output" == *"K escalate false"* ]]
  # final は独立に実行される。
  [[ "$output" == *"K selfTestFinal.ran true"* ]]
}

# ── (sc-pfn4) defensive parse 失敗は【早期 return でなく throw】で run を殺す(canonical block・P0-2) ──
# 旧形は escalate=true の return で「返り値 shape の一貫性」(selfTestBaseline/Final の skip 搭載)を見ていた。
# canonical cutover で return path 自体が消え、不変条件は「agent を 1 体も起動せず run が死ぬ」へ移る。
# よって assert は rc の exact 一致(=1)+ DRIVER_ERROR + canonical marker + agent 0 起動の 4 点で書く
# (「status が 0 でない」で書かない=126/127 を RED 扱いしない規律)。
@test "sc-pfn4: defensive parse 失敗は canonical block が throw して run を殺す(rc=1・canonical marker・agent 0 起動)" {
  run env CQ_ARGS_STRING='{bad json,,' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[SCARGS fail-fast]"* ]]
  [[ "$output" == *"parse 不能"* ]]
  # agent が 1 体も起動していない(fail-fast より前に仕事を始めていない)。
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
  # 旧 return path が残存していない(escalate return へ後戻りしていない)。
  [[ "$output" != *"K escalate true"* ]]
}

# ── (sc-pfn4) 必須 args(worktree)欠落も canonical block の throw(旧 args fail-fast return の置換) ──────
@test "sc-pfn4: 必須 args(worktree)欠落は canonical block が throw して run を殺す(rc=1・canonical marker・agent 0 起動)" {
  run env CQ_ARGS='{"autoFix":true}' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[SCARGS fail-fast]"* ]]
  [[ "$output" == *"必須 args 欠落/未解決: worktree"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
  [[ "$output" != *"K escalate true"* ]]
}

# ── (sc-pfn4) block の【外】の意味的 fail-fast: canonical marker を含まない別 prefix で throw する ─────
# 3 面: (a) sentinel '(current worktree)' 拒否(block の不在判定は sentinel を素通りさせるため block 外が要る)
#       (b) goal / acceptance のいずれか(平坦な AND では block に表現不能) (c) autoFix 時の selfTestCmd。
# canonical marker を含めない別 prefix は engine の帰属弁別面(preamble 由来 throw と骨格固有の意味検証を
# 混同させない)なので、marker の【不在】も併せて assert する。
@test "sc-pfn4 P2: sentinel '(current worktree)' は block 外の意味的 fail-fast が throw で拒否する(canonical marker を含まない)" {
  run env CQ_ARGS='{"worktree":"(current worktree)","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true}' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[cell-quality args fail-fast]"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
  # canonical marker は含まない(帰属を弁別できる形)。
  [[ "$output" != *"[SCARGS fail-fast]"* ]]
}

@test "sc-pfn4 P2: goal/acceptance 双方欠落(worker-cell)は block 外の意味的 fail-fast が throw する" {
  run env CQ_ARGS='{"worktree":"/tmp/wt","doImplement":true}' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[cell-quality args fail-fast]"* ]]
  [[ "$output" == *"goal/acceptance のいずれか"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
  [[ "$output" != *"[SCARGS fail-fast]"* ]]
}

@test "sc-pfn4 P2: autoFix 要求で selfTestCmd 欠落は block 外の意味的 fail-fast が throw する" {
  run env CQ_ARGS='{"worktree":"/tmp/wt","goal":"do x","autoFix":true}' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[cell-quality args fail-fast]"* ]]
  [[ "$output" == *"selfTestCmd(autoFix 時)"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
  [[ "$output" != *"[SCARGS fail-fast]"* ]]
}

# ── (sc-pfn4) 対照: 発火条件は isWorkerCell のまま(無条件化していない) ────────────────────────────
# 無条件化すると正常 args の positive control でも必ず throw し、engine が二面宣言を機械照合できる走行が
# 1 つも無くなる(POSITIVE_THROW_UNATTRIBUTED)。read-only 軽量用途(doImplement/autoFix なし)で worktree だけを
# 与えた run が throw せず agent へ到達することを behavioral に固定する。
@test "sc-pfn4 P2 対照: read-only 軽量用途(worktree のみ)は意味的 fail-fast を発火せず agent へ到達する" {
  run env CQ_ARGS='{"worktree":"/tmp/wt","diff":"diff --git a/x b/x"}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" != *"DRIVER_ERROR"* ]]
  # agent が実際に起動している(classify 段が走った)。
  [[ "$output" == *"K effortStage.classify medium"* ]]
}

# ── 構造 pin(source-level): baseline/final の常時実行機構と情報ログ専用性 ────────────────────────
@test "sc-jx8: WF ソースが runSelfTest / selfTestBaseline / selfTestFinal の常時実行機構を持つ" {
  [ -f "$WF" ]
  grep -q 'async function runSelfTest' "$WF"
  grep -q "runSelfTest('baseline')" "$WF"
  grep -q "runSelfTest('final')" "$WF"
  grep -q 'SELFTEST_RUN_SCHEMA' "$WF"
  # result オブジェクトに両フィールドが載る。
  grep -Eq '^\s*selfTestBaseline,' "$WF"
  grep -Eq '^\s*selfTestFinal,' "$WF"
  # graceful skip(fail-open): selfTestCmd 無しなら skip(agent を起動しない)。
  grep -q 'skipped: true' "$WF"
}

# ── per-stage effort(sc-94z・SSOT=sc-npa 論点5): sc-dc9 の「全 agent 一律 pin」を段別へ分化 ────────────
# guard 段(Review/Verify/Fix)は cell effort の一括下げから構造独立に high 固定・mechanical 段(Self-test/
# Classify/Snapshot)は medium 固定・実装系(Plan/Implement)のみ cell effort(=再定義 args.effort)に従う。
# 露出 knob は reviewEffort/verifyEffort の 2 つのみ。effort pin 自体(sc-dc9)= settings.json 非依存は不変。

@test "sc-94z: 既定 cell effort で mechanical 段=medium・guard 段(Review/Verify)=high(段別分化・behavioral)" {
  # taskType 未指定で classify を走らせ、finding 1 件を refute させて review+verify も走らせる(fix は不発=clean 収束)。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true}' \
    CQ_REVIEW_FINDINGS='[{"title":"x","severity":"critical","location":"a:1","rationale":"r"}]' \
    CQ_VERIFY_REFUTED=true \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 全 agent 呼出しに effort が届く(undefined 無し)=sc-dc9 の pin 自体は不変。
  [[ "$output" == *"K effortAllPinned true"* ]]
  # mechanical 段 = medium 固定(behavioral)。
  [[ "$output" == *"K effortStage.classify medium"* ]]
  [[ "$output" == *"K effortStage.selftest medium"* ]]
  [[ "$output" == *"K effortStage.snapshot medium"* ]]
  # guard 段(Review/Verify) = 既定 high(behavioral)。
  [[ "$output" == *"K effortStage.review high"* ]]
  [[ "$output" == *"K effortStage.verify high"* ]]
  # 返り値 per-stage 要約(呼出元監査面)。
  [[ "$output" == *"K resultEffort.cell high"* ]]
  [[ "$output" == *"K resultEffort.fix high"* ]]
  [[ "$output" == *"K resultEffort.classify medium"* ]]
  [[ "$output" == *"K resultEffort.selfTest medium"* ]]
  [[ "$output" == *"K resultEffort.snapshot medium"* ]]
}

@test "sc-94z ④: Plan/Implement は cell effort(args.effort)に従う(medium cell → plan/implement=medium)" {
  # doPlan+doImplement を有効化し effort=medium(cell effort)を渡す。single モード(autoFix 無し)+ 静的 diff。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","taskType":"testable","effort":"medium","doPlan":true,"doImplement":true,"diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-o\n+n\n"}' \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 実装系の段 = cell effort(medium)に追随(behavioral)。
  [[ "$output" == *"K effortStage.plan medium"* ]]
  [[ "$output" == *"K effortStage.implement medium"* ]]
  # 返り値の cell フィールドも medium。
  [[ "$output" == *"K resultEffort.cell medium"* ]]
}

@test "sc-94z ①(核心): guard 段は cell effort の一括下げから独立(effort=medium でも Review/Verify=high)" {
  # cell effort=medium を渡しても guard 段(Review/Verify)は high を保つ=但し書き(1)の WF 内対応物。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"effort":"medium"}' \
    CQ_REVIEW_FINDINGS='[{"title":"x","severity":"critical","location":"a:1","rationale":"r"}]' \
    CQ_VERIFY_REFUTED=true \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # cell effort=medium だが guard 段は high(構造独立)。
  [[ "$output" == *"K effortStage.review high"* ]]
  [[ "$output" == *"K effortStage.verify high"* ]]
  # mechanical 段は medium・cell も medium。
  [[ "$output" == *"K effortStage.classify medium"* ]]
  [[ "$output" == *"K resultEffort.cell medium"* ]]
  [[ "$output" == *"K resultEffort.review high"* ]]
  [[ "$output" == *"K resultEffort.verify high"* ]]
  [[ "$output" == *"K resultEffort.fix high"* ]]
}

@test "sc-94z(sc-o10 errata): scribe-selftest-args.sh 経由で medium worker を模しても Review/Verify/Fix が high に留まる" {
  # sc-o10 gate errata の再発防止(sc-7ac 伝播が前提): 標準 worker 経路(selftest-args)で medium worker を模し、
  # 生成 args を WF driver に流して guard 段(Review/Verify/Fix)が high に留まることを e2e で確認する。
  # confirmed blocking(refuted=false)+ self-test pass で fix 段も走らせて high を観測する。
  local ARGS
  ARGS="$(CLAUDE_CODE_EFFORT_LEVEL=medium "$SELFTEST" --dry-run --worktree /tmp/wt \
    --self-test 'bats tests/x.bats' --task-type testable sc-94z)"
  # selftest-args が effort=medium を焼いた(cell effort)ことを前提として担保する。
  echo "$ARGS" | python3 -c 'import json,sys; assert json.load(sys.stdin).get("effort")=="medium", "selftest-args が effort=medium を焼いていない"'
  run env CQ_ARGS="$ARGS" \
    CQ_REVIEW_FINDINGS='[{"title":"x","severity":"critical","location":"a:1","rationale":"boom"}]' \
    CQ_VERIFY_REFUTED=false CQ_FIX_SELFTEST_PASSED=true \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # medium worker(cell effort=medium)でも guard 段は high に留まる(核心 assert・sc-o10 再発防止)。
  [[ "$output" == *"K effortStage.review high"* ]]
  [[ "$output" == *"K effortStage.verify high"* ]]
  [[ "$output" == *"K effortStage.fix high"* ]]
  # cell effort は medium へ追随(返り値 cell フィールドで確認)。
  [[ "$output" == *"K resultEffort.cell medium"* ]]
}

@test "sc-94z ①: reviewEffort/verifyEffort knob で guard 段を xhigh へ opt-in できる" {
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"reviewEffort":"xhigh","verifyEffort":"xhigh"}' \
    CQ_REVIEW_FINDINGS='[{"title":"x","severity":"critical","location":"a:1","rationale":"r"}]' \
    CQ_VERIFY_REFUTED=true \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K effortStage.review xhigh"* ]]
  [[ "$output" == *"K effortStage.verify xhigh"* ]]
  [[ "$output" == *"K resultEffort.review xhigh"* ]]
  [[ "$output" == *"K resultEffort.verify xhigh"* ]]
  # Fix は knob を持たず high 固定(reviewEffort/verifyEffort に引きずられない)。
  [[ "$output" == *"K resultEffort.fix high"* ]]
}

@test "sc-94z: allowlist 外の effort/reviewEffort は既定へ fail-safe(warn log で可視化)" {
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"effort":"bogus","reviewEffort":"ultra"}' \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # cell effort は既定 high・review は既定 high(いずれも fail-safe)。
  [[ "$output" == *"K resultEffort.cell high"* ]]
  [[ "$output" == *"K resultEffort.review high"* ]]
  # fail-safe を warn log で可視化(silent に倒さない)=behavioral に発火を確認。
  [[ "$output" == *"K effortFailSafeWarned true"* ]]
  # allowlist 外(fallback=high)は floor を満たすゆえ floor-clamp 経路は発火しない(=別経路の弁別)。
  [[ "$output" == *"K effortFloorClamped false"* ]]
}

@test "sc-2wv: guard knob(reviewEffort/verifyEffort)を floor(high)未満で渡すと WF は fail-safe で high へ引き上げ warn" {
  # WF 直叩き経路(scribe-selftest-args を経ない)の二重防御: allowlist 内だが high 未満(low/medium)の guard knob は
  # 黙って下げず floor(high)へ引き上げ、'下限フロア' warn を発火する(gate 側を下げない=但し書き(1)の機械 enforce)。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"reviewEffort":"medium","verifyEffort":"low"}' \
    CQ_REVIEW_FINDINGS='[{"title":"x","severity":"critical","location":"a:1","rationale":"r"}]' \
    CQ_VERIFY_REFUTED=true \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  # guard 段は floor(high)へ clamp(下げ拒否・behavioral)。
  [[ "$output" == *"K effortStage.review high"* ]]
  [[ "$output" == *"K effortStage.verify high"* ]]
  [[ "$output" == *"K resultEffort.review high"* ]]
  [[ "$output" == *"K resultEffort.verify high"* ]]
  # floor-clamp の warn が発火(silent に下げない)。'許可外'(allowlist 外)経路とは別マーカーで弁別。
  [[ "$output" == *"K effortFloorClamped true"* ]]
}

# ── WF 本体の静的 pin 検査: per-stage effort 定数 + 各段割当て(sc-dc9 一律 pin から分化) ──
@test "sc-94z: WF 本体が per-stage effort 定数と各段割当てを持つ(静的)" {
  [ -f "$WF" ]
  # EFFORT_ALLOWED(sc-ax4 SSOT mirror)は温存(検証路の単一 SSOT・drift 検知は effort-allowlist-ssot.bats)。
  grep -q "EFFORT_ALLOWED = new Set(\['low', 'medium', 'high', 'xhigh', 'max'\])" "$WF"
  # 旧・一律 pin の `const EFFORT =` / `effort: EFFORT` は撤去済み(段別へ分化)。
  ! grep -qE 'const EFFORT =' "$WF"
  ! grep -qE 'effort: EFFORT\b' "$WF"
  # 新検証路を作らず既存 allowlist を再利用する単一 resolver(consistency (a))。
  grep -q 'const resolveEffort = ' "$WF"
  grep -q 'EFFORT_ALLOWED.has(t)' "$WF"
  # guard 段 floor(sc-2wv): guard knob 専用 resolver は共通 resolveEffort を内部再利用しつつ high 未満を clamp する。
  grep -q 'const resolveGuardEffort = ' "$WF"
  grep -q "const GUARD_EFFORT_FLOOR = 'high'" "$WF"
  grep -q 'const EFFORT_RANK_ORDER = ' "$WF"
  # per-stage 定数が存在する。
  grep -q 'const CELL_EFFORT = resolveEffort' "$WF"
  # guard knob は floor 付き resolver(resolveGuardEffort)経由(下げ拒否)。
  grep -q 'const reviewEffort = resolveGuardEffort' "$WF"
  grep -q 'const verifyEffort = resolveGuardEffort' "$WF"
  grep -qE "const FIX_EFFORT = 'high'" "$WF"
  grep -qE "const CLASSIFY_EFFORT = 'medium'" "$WF"
  grep -qE "const SELFTEST_EFFORT = 'medium'" "$WF"
  grep -qE "const SNAPSHOT_EFFORT = 'medium'" "$WF"
  # 各段が正しい per-stage 定数へ割り当たる(guard=knob/固定・mechanical=medium)。
  grep -q 'effort: reviewEffort,' "$WF"
  grep -q 'effort: verifyEffort,' "$WF"
  grep -q 'effort: FIX_EFFORT,' "$WF"
  grep -q 'effort: CLASSIFY_EFFORT,' "$WF"
  grep -q 'effort: SELFTEST_EFFORT,' "$WF"
  grep -q 'effort: SNAPSHOT_EFFORT,' "$WF"
  # Plan/Implement は cell effort(2 箇所)。
  local n
  n="$(grep -c 'effort: CELL_EFFORT,' "$WF")"
  [ "$n" -ge 2 ]
  # 返り値 effort は per-stage 要約 object。
  grep -q 'effort: effortSummary,' "$WF"
  # CLAUDE_EFFORT(非正規名)を WF が使わない(念のため・WF は env を書かないが方針として)。
  ! grep -q 'CLAUDE_EFFORT\b' "$WF"
}

# ═══════════════════════════════════════════════════════════════════════════════
# (sc-pfn4) canonical args 契約 cutover の teeth
# ═══════════════════════════════════════════════════════════════════════════════

# ── P2(5): 二面宣言の集合一致(engine の DECL_MISMATCH を bwrap 非依存で先取りする) ──────────────────
# engine の DECL_MISMATCH 判定は --probe-args 指定時に評価されない(wf-args-probe.mjs の分岐)。cell 内で回せる
# probe 走行は骨格別 legacy allowlist 経由=--probe-args 付きゆえ、二面宣言の集合一致は engine 走行の rc=0 では
# 一切保証されない(完全不一致でも rc=0 になることを合成 fixture で実測済み)。よって bwrap 非依存の独立 tooth で
# 集合一致そのものを pin する。
@test "sc-pfn4 P2: meta の必須 args 宣言と body の const REQUIRED_ARGS が同一集合(二面宣言)" {
  run node -e '
    const fs = require("fs")
    const s = fs.readFileSync(process.argv[1], "utf8")
    const m = /requiredArgs:\s*\[([^\]]*)\]/.exec(s)
    const b = /const\s+REQUIRED_ARGS\s*=\s*\[([^\]]*)\]/.exec(s)
    if (!m || !b) { console.log("DECL_MISSING meta=" + !!m + " body=" + !!b); process.exit(1) }
    const parse = (t) => [...t.matchAll(/[\x27"]([^\x27"]*)[\x27"]/g)].map((x) => x[1]).sort()
    const A = parse(m[1]), B = parse(b[1])
    console.log("META " + JSON.stringify(A))
    console.log("BODY " + JSON.stringify(B))
    console.log(JSON.stringify(A) === JSON.stringify(B) ? "SETS_MATCH" : "SETS_DIFFER")
  ' "$WF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SETS_MATCH"* ]]
  # 集合の実体も pin する(goal / acceptance を含めない=「いずれか」要件は平坦な AND で表現不能ゆえ block 外)。
  [[ "$output" == *'META ["worktree"]'* ]]
  [[ "$output" == *'BODY ["worktree"]'* ]]
}

# ── P6: byte-pin の bwrap 非依存な代替 tooth(複製 block を切り出し sha256 を snippet と直接比較) ──────
# engine の bytePin は probe 走行(bwrap 封じ込め)を伴うため、封じ込めが使えない cell では走らない。block の
# byte 同一性そのものは probe 不要で確かめられるので、独立 tooth として置く(SNIPPET_BLOCK_DRIFT の先取り)。
@test "sc-pfn4 P6: WF へ複製した SCARGS block が canonical snippet と sha256 一致(bwrap 非依存)" {
  local snippet="$REPO_ROOT/workflows/lib/args-preamble.snippet.js"
  [ -f "$snippet" ]
  local wfb="$BATS_TEST_TMPDIR/wf-block.txt"
  local snb="$BATS_TEST_TMPDIR/sn-block.txt"
  awk '/^\/\/SCARGS_BLOCK_START$/{f=1} f{print} /^\/\/SCARGS_BLOCK_END$/{if(f) exit}' "$WF" > "$wfb"
  awk '/^\/\/SCARGS_BLOCK_START$/{f=1} f{print} /^\/\/SCARGS_BLOCK_END$/{if(f) exit}' "$snippet" > "$snb"
  # 切り出せている(空でない・marker 両端が在る)。
  [ -s "$wfb" ]
  [ -s "$snb" ]
  run head -n 1 "$wfb"
  [ "$output" = "//SCARGS_BLOCK_START" ]
  run tail -n 1 "$wfb"
  [ "$output" = "//SCARGS_BLOCK_END" ]
  # marker 行はそれぞれちょうど 1 本(engine の MARKER_MALFORMED 相当を先取り)。
  [ "$(grep -c '^//SCARGS_BLOCK_START$' "$WF")" -eq 1 ]
  [ "$(grep -c '^//SCARGS_BLOCK_END$' "$WF")" -eq 1 ]
  # sha256 の直接比較(1 byte でも動けば RED)。
  local wfsha snsha
  wfsha="$(sha256sum "$wfb" | awk '{print $1}')"
  snsha="$(sha256sum "$snb" | awk '{print $1}')"
  [ -n "$wfsha" ]
  [ "$wfsha" = "$snsha" ]
  # snippet 側は 1 byte も編集していない(self-pin と同じ値=波0 で焼いた canonical sha)。
  # ※ここは末尾改行込みの file sha ではなく engine と同じ「改行 join・末尾改行なし」の block sha を取る。
  run node -e '
    const fs = require("fs"), c = require("crypto")
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n")
    const s = lines.findIndex((l) => l.trim() === "//SCARGS_BLOCK_START")
    const e = lines.findIndex((l) => l.trim() === "//SCARGS_BLOCK_END")
    const block = lines.slice(s, e + 1).join("\n")
    console.log(c.createHash("sha256").update(block, "utf8").digest("hex"))
  ' "$snippet"
  [ "$status" -eq 0 ]
  [ "$output" = "67602a094a1f3c3eeaeaf0ad1d735640a8e8b3db3752985085ee7685c2ce699d" ]
}

# ── P3: receivedArgs.roAgentType(block の後の property 代入)が監査面として載り上書きに追随する ────────
# cutover 前は block 内に相当する field が在ったが、canonical block は全 WF で byte 一致でなければならないため
# WF 固有 field は block の【後】で property 代入する。この代入を落としても既存 tooth は全 green のままだった
# (現行 tests に receivedArgs.roAgentType を assert する tooth は 0 本=無 guard 条項)ので専用 tooth で塞ぐ。
@test "sc-pfn4 P3: receivedArgs.roAgentType が既定 scribe:explore で載り args.roAgentType の上書きに追随する" {
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roAgentType":"scribe:explore"'* ]]
  # 上書き(escape hatch 'none')に追随する=解決値が載っている(literal 固定でない)。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable","roAgentType":"none"}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roAgentType":"none"'* ]]
  # 任意の型指定にも追随する(既定/none の 2 値だけを返す実装への退行を塞ぐ)。
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable","roAgentType":"general-purpose"}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roAgentType":"general-purpose"'* ]]
}

# ── P4: 監査 3 field が「載っていない return path が 0 本」(behavioral + 直下限定の構造 pin) ────────────
# cutover で早期 return が消え result-level の return path は 1 本になった。grep による return path 列挙は
# 到達不能 return の dead code 温存でも通ってしまうため、behavioral(複数シナリオの RESULT を実際に読む)で
# 網羅を確かめ、加えて監査 field が helper 関数の return に紛れていない(result 直下にのみ在る)ことを pin する。
@test "sc-pfn4 P4: 監査 3 field(receivedArgs/schemaHealth/roFallbackActive)が全シナリオの RESULT に載る" {
  # (1) 正常収束
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K converged true"* ]]
  [[ "$output" == *'"receivedArgs":{'* ]]
  [[ "$output" == *'"schemaHealth":{'* ]]
  [[ "$output" == *'"roFallbackActive":'* ]]
  # (2) escalate(Fix の self-test 失敗で fail-closed)
  run env CQ_ARGS="$ARGS_WORKER" \
    CQ_REVIEW_FINDINGS='[{"title":"bug A","severity":"critical","location":"x:1","rationale":"boom"}]' \
    CQ_VERIFY_REFUTED=false CQ_FIX_SELFTEST_PASSED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K escalate true"* ]]
  [[ "$output" == *'"receivedArgs":{'* ]]
  [[ "$output" == *'"schemaHealth":{'* ]]
  [[ "$output" == *'"roFallbackActive":'* ]]
  # (3) roAgentType 上書き(fallback 経路の最終状態が載る)
  run env CQ_ARGS="$ARGS_WORKER" CQ_RO_NOTFOUND=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K roFallbackActive true"* ]]
  [[ "$output" == *'"receivedArgs":{'* ]]
  [[ "$output" == *'"schemaHealth":{'* ]]
  [[ "$output" == *'"roFallbackActive":true'* ]]
}

@test "sc-pfn4 P4: 監査 3 field は result 直下にのみ在る(helper 関数の return に載せない)" {
  # result-level の return は 1 本のみ=各 field はちょうど 1 箇所。helper(runSelfTest / dimension 合成等)の
  # return に紛れ込むと呼出元の監査面が二重化し「どの object を読めばよいか」が壊れる。
  [ "$(grep -cE '^[[:space:]]*receivedArgs,' "$WF")" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]*schemaHealth: \{' "$WF")" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]*roFallbackActive,' "$WF")" -eq 1 ]
  # 旧早期 return の literal 形(escalate return 形の残骸)が残っていない。
  [ "$(grep -c 'roFallbackActive: false' "$WF")" -eq 0 ]
  # helper の return 行に監査 field が現れない(直下限定の裏取り: 該当行はいずれも result 組立の内側)。
  ! grep -nE '^[[:space:]]*return \{.*receivedArgs' "$WF"
  ! grep -nE '^[[:space:]]*return \{.*schemaHealth' "$WF"
  ! grep -nE '^[[:space:]]*return \{.*roFallbackActive' "$WF"
}

# ── P5: 変異注入 — canonical block の必須 args 判定を除去すると対応 tooth が RED になる(非空虚性) ───────
# mutant_fingerprint: `if (__scargsParseFailed || __scargsMissing.length > 0) {` → `if (false) {`
# 変異は BATS_TEST_TMPDIR の copy 木へ当てる(実 file を変異させたまま commit しない)。driver は自分の位置から
# ../workflows/cell-quality.workflow.js を読むので、copy 木は tests/ と workflows/ の 2 段を作る。
@test "sc-pfn4 P5: 変異注入(canonical block の必須 args 判定を除去)で canonical marker の tooth が RED になる" {
  local mut="$BATS_TEST_TMPDIR/mut"
  mkdir -p "$mut/tests" "$mut/workflows"
  cp "$DRIVER" "$mut/tests/"
  sed 's/if (__scargsParseFailed || __scargsMissing.length > 0) {/if (false) {/' "$WF" > "$mut/workflows/cell-quality.workflow.js"
  # 変異が実際に当たったこと(diff 非空 = 1 行の置換)を rc と diff で確認する。
  run diff "$WF" "$mut/workflows/cell-quality.workflow.js"
  [ "$status" -eq 1 ]
  [[ "$output" == *"if (false) {"* ]]

  # base(未変異): 必須 args 欠落は canonical marker 付きで throw する。
  run env CQ_ARGS='{"autoFix":true}' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"[SCARGS fail-fast]"* ]]

  # 変異後: canonical block が黙って通り、block 外の意味的 fail-fast まで落ちる=canonical marker が消える
  # (=上の tooth が RED になる)。agent は依然 0 起動だが「preamble が必須 args を見ている」証拠は失われる。
  run env CQ_ARGS='{"autoFix":true}' node "$mut/tests/cell-quality-selftest.driver.mjs" run
  [ "$status" -eq 1 ]
  [[ "$output" != *"[SCARGS fail-fast]"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
}

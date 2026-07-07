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

# ── 返り値 shape の一貫性: 早期 return(defensive parse 失敗)でも selfTestBaseline/Final(skip)が載る ──
@test "sc-jx8: defensive parse 失敗の早期 return でも selfTestBaseline/Final(skip)が返り値に載る(shape 一貫性)" {
  run env CQ_ARGS_STRING='{bad json,,' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K escalate true"* ]]
  [[ "$output" == *"K selfTestBaseline.present true"* ]]
  [[ "$output" == *"K selfTestBaseline.skipped true"* ]]
  [[ "$output" == *"K selfTestFinal.present true"* ]]
  [[ "$output" == *"K selfTestFinal.skipped true"* ]]
}

# ── 返り値 shape の一貫性: 早期 return(args fail-fast=必須欠落)でも selfTestBaseline/Final(skip)が載る ──
@test "sc-jx8: args fail-fast の早期 return でも selfTestBaseline/Final(skip)が返り値に載る(agent 未起動)" {
  run env CQ_ARGS='{"autoFix":true}' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K escalate true"* ]]
  [[ "$output" == *"K selfTestBaseline.skipped true"* ]]
  [[ "$output" == *"K selfTestFinal.skipped true"* ]]
  [[ "$output" == *"K selftestAgentCalls 0"* ]]
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

# ── effort 統制(sc-dc9): 全 agent() に opts.effort が pin される ──────────────────────
@test "sc-dc9: 既定(args.effort 未指定)で全 agent 呼出しが effort=high で pin される" {
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 全 agent 呼出しに effort が届き(undefined 無し)、distinct 値は 'high' のみ=全箇所 pin かつ既定 high。
  [[ "$output" == *"K effortAllPinned true"* ]]
  [[ "$output" == *"K effortDistinct high"* ]]
  # 返り値サマリにも解決 effort が載る(呼出元監査用)。
  [[ "$output" == *"K resultEffort high"* ]]
}

@test "sc-dc9: args.effort=xhigh で全 agent が xhigh に pin される(settings.json 非依存で args 上書きが効く)" {
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable","effort":"xhigh"}' \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K effortAllPinned true"* ]]
  [[ "$output" == *"K effortDistinct xhigh"* ]]
  [[ "$output" == *"K resultEffort xhigh"* ]]
}

@test "sc-dc9: allowlist 外の args.effort は既定 high へ fail-safe(WF は止めず警告 log・spawn の fail-loud と二重化)" {
  run env CQ_ARGS='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable","effort":"bogus"}' \
    node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K effortDistinct high"* ]]
  [[ "$output" == *"K resultEffort high"* ]]
  # fail-safe を warn log で可視化する(silent に既定へ倒さない)=behavioral に発火を確認。
  [[ "$output" == *"K effortFailSafeWarned true"* ]]
}

# ── WF 本体の静的 pin 検査: 全 agent()/roAgent()/runAgent() opts に effort が明示されている ──
@test "sc-dc9: WF 本体の agent 呼出し全箇所に effort: EFFORT が明示 pin されている(静的)" {
  [ -f "$WF" ]
  # EFFORT 解決(allowlist + fail-safe high)が存在する。
  grep -q "const EFFORT = EFFORT_ALLOWED.has" "$WF"
  grep -q "EFFORT_ALLOWED = new Set(\['low', 'medium', 'high', 'xhigh', 'max'\])" "$WF"
  # agent 呼出し 8 箇所 + result 2 箇所 = effort: EFFORT が 10 回以上。
  local n
  n="$(grep -c 'effort: EFFORT' "$WF")"
  [ "$n" -ge 10 ]
  # CLAUDE_EFFORT(非正規名)を WF が使わない(念のため・WF は env を書かないが方針として)。
  ! grep -q 'CLAUDE_EFFORT\b' "$WF"
}

#!/usr/bin/env bats
# sc-j32 schema 強制 agent ガードの behavioral 恒久回帰テスト(tracked)。
#
# 背景: dynamic WF の schema 付き agent は StructuredOutput を「作業完了後に一度だけ・実データで」呼ぶべきだが、
# 実発(wf_c2cd03d4)で (a) 試し打ち placeholder の初回最終値化 / (b) retry 上限超過の null 死 を観測。sc-j32 は
# 両骨格(cell-quality / needs-user-prebake)に schemaAgent ラッパ + degenerate 検知 + schemaHealth 集計を導入し
# 既存の失敗経路へ fail-closed で倒す。本 bats はその挙動を tracked に固定する(従来 selftest-sc-j32.local.sh の
# node ハーネスは untracked=CI に載らなかった=ship されない・sc-j32 review finding 3/4 の是正)。
#
# 検証:
#   [A] 両骨格の SCJ32 ブロックを実 eval し schemaAgent の null 死記録 / degenerate 記録 / passthrough / throw 透過
#       と degenerate 述語(cell-quality: degFindings 他 / prebake: degFacet/degSynth)を behaviorally 固定
#       (tests/schema-guard.driver.mjs)。
#   [B] cell-quality の full-workflow で「review 出力が全 placeholder」のとき degenerate → review 不採用
#       (reviewFailed 経路)→ result.schemaHealth.degenerate 非空 → gate に schemaNote 付与 → escalate を実走で固定。
#   [C] 対照: 正常な review(実 finding)では schemaHealth は空・schemaNote 無し(degenerate 誤検知しない=回帰ガード)。
#
# [B]/[C] は cell-quality driver(逐次 review 経路)で回す。prebake の facet は parallel 起動ゆえ full-workflow の
# 逐次再現が構造上不達(sc-xyw の判断と同じ)=prebake は [A] のブロック eval で behavioral に固定する。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  SG_DRIVER="$REPO_ROOT/tests/schema-guard.driver.mjs"
  CQ_DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  PREBAKE="$REPO_ROOT/workflows/needs-user-prebake.workflow.js"
  ARGS_WORKER='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable"}'
  # 全 finding が placeholder 形状(試し打ちの最終値化)= degFindings が true になる review 出力。
  FINDING_DEGENERATE='[{"title":"test","severity":"critical","location":"test","rationale":"test"}]'
  # 実 finding(confirmed 化するよう verify を refute しない)= degenerate ではない対照。
  FINDING_REAL='[{"title":"Off-by-one","severity":"critical","location":"a.js:10","rationale":"boundary read past end"}]'
}

# ── [A] cell-quality 骨格: ブロック eval の behavioral 固定 ──────────────────────────────────────────
@test "sc-j32 [A]: cell-quality の schemaAgent/degenerate/isPlaceholderStr が behavioral に green" {
  run node "$SG_DRIVER" "$WF" cell-quality
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS (cell-quality)"* ]]
}

# ── [A] prebake 骨格: ブロック eval の behavioral 固定(finding 3 是正: prebake 側も挙動検証) ────────────
@test "sc-j32 [A]: needs-user-prebake の schemaAgent/degFacet/degSynth が behavioral に green" {
  run node "$SG_DRIVER" "$PREBAKE" prebake
  echo "$output"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL PASS (prebake)"* ]]
}

# ── [B] full-workflow: 全 placeholder review → degenerate → schemaHealth + schemaNote + escalate ──────
@test "sc-j32 [B]: 全 placeholder review は degenerate 化し reviewFailed 経路へ倒れ schemaHealth+schemaNote が付く" {
  run env CQ_ARGS="$ARGS_WORKER" CQ_REVIEW_FINDINGS="$FINDING_DEGENERATE" node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  # review 出力が placeholder → schemaAgent が null → review 不採用 → machinery 失敗 → escalate。
  [[ "$output" == *"K escalate true"* ]]
  [[ "$output" == *"K gatePrefix ESCALATE"* ]]
  # 返り値の schemaHealth.degenerate が非空で当該 review label を含む(RESULT JSON を grep)。
  [[ "$output" == *'"degenerate":['* ]]
  [[ "$output" == *'review:correctness r1'* ]]
  # gate に schemaNote(schema 健全性)が付与され silent ship を防ぐ。
  [[ "$output" == *"schema 健全性"* ]]
  [[ "$output" == *"degenerate=12"* ]]
}

# ── [C] 対照: 実 finding は degenerate 化しない(schemaHealth 空・schemaNote 無し=誤検知しない回帰ガード) ──
@test "sc-j32 [C]: 実 finding の review は degenerate 化せず schemaHealth 空・schemaNote 無し(誤検知回帰ガード)" {
  # verify を refute しない(CQ_VERIFY_REFUTED=false)で confirmed 化させ、review 段が採用される正常経路。
  run env CQ_ARGS="$ARGS_WORKER" CQ_REVIEW_FINDINGS="$FINDING_REAL" CQ_VERIFY_REFUTED=false node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  # review が採用され verify が走った(degenerate で潰されていない)。
  [[ "$output" == *'"degenerate":[]'* ]]
  [[ "$output" == *'"nullDeaths":[]'* ]]
  # schemaNote は付かない(degenerate/nullDeaths 双方空)。
  [[ "$output" != *"schema 健全性"* ]]
}

# ── [D] full-workflow: 実 finding→confirmed→fix summary=placeholder → degFix → escalate + schemaHealth.degenerate ──
# 発端事例(fix summary="test" の最終値化)の end-to-end 回帰ガード(admin gate errata・sc-j32)。[B] は review 段で
# degenerate→escalate に達し **fix 段へ届かない**ため degFindings 配線のみ担保し、degFix の呼出サイト配線
# (schemaAgent(agent,…,degFix))は未カバーだった。ここは実 finding を confirmed 化して fix 段へ到達させ、autofix
# stub の summary を placeholder('test')へ差し替え(CQ_FIX_SUMMARY)て degFix を駆動する。fix 呼出サイトから第4引数
# degFix を落とす回帰が起きると、placeholder summary が truthy のまま fix 採用され escalate せず degenerate も
# 記録されない=本テストが RED になり回帰を捕える。
@test "sc-j32 [D]: 実 finding→confirmed→fix summary=placeholder は degFix で escalate し schemaHealth.degenerate に autofix label が載る" {
  run env CQ_ARGS="$ARGS_WORKER" CQ_REVIEW_FINDINGS="$FINDING_REAL" CQ_VERIFY_REFUTED=false CQ_FIX_SUMMARY=test node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  # fix stub の summary=placeholder → degFix → schemaAgent が null → if(!fix) で escalate(fail-closed)。
  [[ "$output" == *"K escalate true"* ]]
  [[ "$output" == *"K gatePrefix ESCALATE"* ]]
  # 返り値 schemaHealth.degenerate に autofix 系 label が載る(fix 段の degenerate 配線が生きている証跡)。
  [[ "$output" == *'"degenerate":["autofix r1"]'* ]]
  [[ "$output" == *'"nullDeaths":[]'* ]]
  # gate に schemaNote が付き silent ship を防ぐ。
  [[ "$output" == *"schema 健全性"* ]]
  [[ "$output" == *"degenerate=1"* ]]
}

# ── [D対照] fix summary が非 placeholder のとき degFix は不発火(fix 段の誤検知回帰ガード) ──────────────────
# [D] と対称。実 finding→confirmed→fix 段到達まで同じだが、fix summary を非 placeholder にすると degFix は
# 発火せず fix が採用される=degFix が正当な fix summary を試し打ちと誤断定しないことを固定する(false-positive ガード)。
# stub は毎ラウンド同一の実 finding を返すため hard cap まで回り最終的に escalate(未収束)するが、ここでは degFix の
# 非発火(schemaHealth 空・schemaNote 無し)のみを assert する。
@test "sc-j32 [D対照]: fix summary が非 placeholder のとき degFix は不発火(schemaHealth 空・誤検知しない)" {
  run env CQ_ARGS="$ARGS_WORKER" CQ_REVIEW_FINDINGS="$FINDING_REAL" CQ_VERIFY_REFUTED=false CQ_FIX_SUMMARY="applied real boundary fix" node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  # degFix 不発火 → degenerate 記録なし・schemaNote 無し(fix 段の false-positive を作らない)。
  [[ "$output" == *'"degenerate":[]'* ]]
  [[ "$output" == *'"nullDeaths":[]'* ]]
  [[ "$output" != *"schema 健全性"* ]]
}

# ── 構造 pin: 全 schema 呼出サイトが degenerate 述語(第4引数)を配線している ────────────────────────────
# [B]/[D] は full-workflow で degFindings(review 段)/degFix(fix 段)の配線を behavioral に固定するが、
# verify/classify/plan の呼出サイトは full-workflow の逐次経路で individual に到達させにくい(review/fix が先に
# escalate/収束を決めうる)。残る配線は呼出サイトの第4引数を grep で pin する=degX を落とす回帰を fail-closed で
# 捕える軽量 backstop(正当なリファクタで呼出形が変わればここも更新する前提=配線の「存在」を明示固定する)。
@test "sc-j32 構造 pin: 全 schema 呼出サイトが degenerate 述語(第4引数 degX)を配線している" {
  # cell-quality: 5 呼出サイト(classify/plan/review/verify/fix)。
  grep -q ', degClassify)' "$WF"
  grep -q ', degPlan)' "$WF"
  grep -q ', degFindings)' "$WF"
  grep -q ', degVerdict)' "$WF"
  grep -q ', degFix)' "$WF"
  # prebake: facet は `, degFacet)`、synthesize は複数行呼出しゆえ独立行 `degSynth,`。
  grep -q ', degFacet)' "$PREBAKE"
  grep -q 'degSynth,' "$PREBAKE"
}

# ── 構造 pin(両骨格): schemaAgent 導入・schemaHealth 返り値搭載・isPlaceholderStr の長さ撤去 ──────────────
@test "sc-j32 構造 pin: 両骨格が schemaAgent/schemaHealth を持ち isPlaceholderStr が長さヒューリスティックを使わない" {
  for f in "$WF" "$PREBAKE"; do
    [ -f "$f" ]
    grep -q 'async function schemaAgent' "$f"
    grep -q 'const schemaHealth = {' "$f"
    grep -q 'SCHEMA_DISCIPLINE' "$f"
    # (sc-j32 errata) 長さヒューリスティックは撤去済=`t.length < 2` を含まない・`t.length < 1` を使う。
    ! grep -q 't.length < 2' "$f"
    grep -q 't.length < 1' "$f"
    # 全 return 経路に schemaHealth を載せる(下限)。
    [ "$(grep -c 'schemaHealth: {' "$f")" -ge 3 ]
  done
}

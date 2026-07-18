#!/usr/bin/env bats
# sc-mbcm contextFile(args 約 4KB 上限のファイル渡し経路)の behavioral 回帰テスト。
#
# 背景(orch-v7pf=un-cw0z 中継): Workflow tool へ渡す args は全体約 4KB で切り詰められる実測がある。
# 対策 = (a) meta.whenToUse/header への上限明文化 + (b) contextFile(path を渡し各段 agent が Read する
# prompt-level indirection)。本 bats は (b) の配線と (a) の記載を固定する:
#
#   [1] 妥当 path → ctxBlock 経由で prompt へ「context file: <path>」+ Read 指示が注入される
#       (single/review 経路で必ず走る review: 段に届く)。
#   [2] verify prompt へは注入しない(独立反証者は finding + diff だけを見る独立性設計の維持)。
#   [3] 不正 path(空白等・安全文字クラス外)は '' へ倒れ、注入が一切起きない(graceful)。
#   [4] 未供給では注入ゼロ(回帰対照=既存呼出元への影響なし)。
#   [5] meta.whenToUse に 4KB 上限と回避経路(baseRef/contextFile)が明文化されている(静的 pin)。
#
# 観測面 = tests/cell-quality-selftest.driver.mjs の CQ_PROMPT_GREP 軸(K promptGrepCount/promptGrepLabels)。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CQ_DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  # single モード(doImplement/autoFix なし=review のみ)の最小 args。
  ARGS_BASE='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","taskType":"testable"'
  # verify 段を走らせるための実 finding(placeholder でない=degenerate 誤検知しない)。
  FINDING_REAL='[{"title":"Off-by-one","severity":"critical","location":"a.js:10","rationale":"boundary read past end"}]'
}

@test "sc-mbcm [1]: 妥当な contextFile は review prompt へ「context file: <path>」として注入される" {
  run env CQ_ARGS="${ARGS_BASE},\"contextFile\":\"/tmp/ctx/brief.md\"}" \
      CQ_PROMPT_GREP='context file: /tmp/ctx/brief.md' node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  # 注入が 1 箇所以上(review 段は single 経路で必ず走る)
  local count
  count="$(echo "$output" | sed -n 's/^K promptGrepCount //p')"
  [ -n "$count" ] && [ "$count" -ge 1 ]
  echo "$output" | grep '^K promptGrepLabels ' | grep -q 'review:'
}

@test "sc-mbcm [2]: verify prompt へは contextFile を注入しない(独立反証者の独立性維持)" {
  run env CQ_ARGS="${ARGS_BASE},\"contextFile\":\"/tmp/ctx/brief.md\"}" \
      CQ_REVIEW_FINDINGS="$FINDING_REAL" CQ_VERIFY_REFUTED=true \
      CQ_PROMPT_GREP='context file: /tmp/ctx/brief.md' node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  # verify 段は実際に走っている(review+verify 呼出が 0 でない)前提を非空虚に確認
  echo "$output" | grep '^K reviewVerifyCalls ' | grep -qv ' 0$'
  local labels_line
  labels_line="$(echo "$output" | grep '^K promptGrepLabels ')"
  [[ "$labels_line" == *"review:"* ]]
  [[ "$labels_line" != *"verify:"* ]]
}

@test "sc-mbcm [3]: 安全文字クラス外の path(空白入り)は '' へ倒れ注入されない(graceful)" {
  run env CQ_ARGS="${ARGS_BASE},\"contextFile\":\"/tmp/ctx dir/brief.md\"}" \
      CQ_PROMPT_GREP='context file:' node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^K promptGrepCount 0$'
}

@test "sc-mbcm [4]: contextFile 未供給では注入ゼロ(既存呼出元への回帰なし)" {
  run env CQ_ARGS="${ARGS_BASE}}" CQ_PROMPT_GREP='context file:' node "$CQ_DRIVER" run
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^K promptGrepCount 0$'
}

@test "sc-mbcm [5]: meta.whenToUse に args 約 4KB 上限と回避経路(baseRef/contextFile)が明文化されている" {
  # meta ブロック(ファイル先頭〜phases)に上限と両経路の記載があることを静的に pin する。
  local head_block
  head_block="$(sed -n '1,/phases:/p' "$WF")"
  echo "$head_block" | grep -q '4KB'
  echo "$head_block" | grep -q 'baseRef'
  echo "$head_block" | grep -q 'contextFile'
  # parse 部の実体(sanitizer)が存在する(doc だけで実装が消える half-land を防ぐ)
  grep -q 'A.contextFile' "$WF"
}

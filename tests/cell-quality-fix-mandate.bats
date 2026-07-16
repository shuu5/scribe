#!/usr/bin/env bats
# sc-o7q7: cell-quality WF の write 系 agent prompt(Implement/Fix) への push 禁止焼込の string pin。
#
# 背景: sc-8eyw gate で実発——autoFix(Fix) agent が acceptance 充足の一環で branch を origin へ push し
# worker mandate(PR/push は admin の gate 後)に違反、r3 amend で remote が stale 化(doobidoo b3fac93b)。
# 従来の禁止行は「force push」のみで plain `git push` と remote への write が未封鎖だった。
# 恒久封鎖として implementPrompt / fixPrompt の両方へ remote write 全面禁止を焼き込み、本 bats が
# 文言の実在を pin する(prompt は agent へ渡すデータゆえ string pin が適切な検証水準。挙動側の防御は
# gate 型の remote-stale 照合=ls-remote vs local HEAD が別途担う)。
#
# 検証:
#   [A] implementPrompt / fixPrompt の関数本体それぞれに禁止文言(git push・remote への write・一切しない・
#       gate 後)が実在する(片方だけの焼込=書込系 agent の取りこぼしを検知)。
#   [B] 編集後も WF が ESM として構文妥当(template literal のバッククォート escape 崩れを検知)。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
}

# 関数本体を切り出す(function 宣言行から col0 の } まで)
extract() { awk "/^function $1\(/,/^}/" "$WF"; }

@test "sc-o7q7 [A]: implementPrompt に push/remote write 禁止が焼かれている" {
  body="$(extract implementPrompt)"
  [ -n "$body" ]
  [[ "$body" == *"git push"* ]]
  [[ "$body" == *"remote への write"* ]]
  [[ "$body" == *"一切しない"* ]]
  [[ "$body" == *"gate 後"* ]]
}

@test "sc-o7q7 [A]: fixPrompt に push/remote write 禁止が焼かれている" {
  body="$(extract fixPrompt)"
  [ -n "$body" ]
  [[ "$body" == *"git push"* ]]
  [[ "$body" == *"remote への write"* ]]
  [[ "$body" == *"一切しない"* ]]
  [[ "$body" == *"gate 後"* ]]
}

@test "sc-o7q7 [B]: 焼込後も WF が script body として構文妥当" {
  # WF script は harness が async 文脈で wrap する body(top-level return/await が合法・`export const meta` のみ
  # 特別扱い)。素の ESM/CJS どちらの node --check も通らない(ESM=top-level return 不法/CJS=export 不法)ため、
  # harness と同じ形(export 剥ぎ + async IIFE wrap)へ変換して構文検査する(template literal の escape 崩れ検知)。
  { printf '(async () => {\n'; sed 's/^export //' "$WF"; printf '\n})\n'; } > "$BATS_TEST_TMPDIR/cq-body.js"
  run node --check "$BATS_TEST_TMPDIR/cq-body.js"
  echo "$output"
  [ "$status" -eq 0 ]
}

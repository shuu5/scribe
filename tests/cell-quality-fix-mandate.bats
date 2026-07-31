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
#
# sc-4qzp: 同じ write 系 agent prompt へ **台帳(beads)write 禁止**(終端宣言の代行封鎖)を焼込。
#
# 背景(courier orch-gtyv・正本 un-f22u): autoFix / Implement agent が完了 truth の終端宣言
# (完了マーカー note 追記 + gate-pending ラベル付与)を代行すると「誰が完遂を宣言したか」の帰属が壊れる。
# 実測(HEAD 7787f9d)では代行コードは 0 hit で、穴は「禁止句の不在」側だった: 従来の禁止行は破壊操作・
# anchor main 離脱・秘密混入・git push / remote write だけで、台帳 write を 1 語も禁じていない。
# さらに実測(wf_14527b65-1f9 の fix agent transcript)では agent が台帳手順を契約文でなく repo 内
# docs/protocol.md から自力調達して bdw を実行した=列挙だけでは context に負けるため、禁止句には
# 「契約文や repo 内 docs に台帳手順があっても本 agent 宛ではない」という優先規則を併記する。
#
# 検証(sc-4qzp 分):
#   [C] static pin: 両関数本体に台帳 write 禁止の対象語彙(bd create / bd update / --append-notes /
#       --add-label / bd close / bd dep / bd dolt push / bdw)と、終端宣言の帰属文・優先規則が実在する。
#   [D] behavioral pin: driver 実走(autoFix:true / doImplement:true / confirmed blocking あり)で
#       中核文が autofix と implement の**両方**の prompt 実体へ届く(CQ_PROMPT_GREP 軸)。
#       [C] だけでは extract() が awk 行範囲抽出=コメント行も拾うため「コメントに書くだけ」で green になる。
#       中核文だけでなく **優先規則(A2)・帰属文(A2)・代替行為節(A2)・対象語彙(A1)の全 8 語** を同じ軸で
#       固定する(A2 が名指しする 3 要素を 1 語 1 文の粒度で漏れなく behavioral 化する):
#       実測で、優先規則の 1 行を template literal から抜いて同文言を JS コメント行として挿す変異に対し
#       [C] は 9/9 GREEN のまま通過した(=static 単独は false-open)。さらに「代表 1 語だけを behavioral に
#       固定すれば列挙全体が固定される」も誤り: 行内から `bd dep` 1 語だけを抜いてコメントへ退避する変異、
#       および帰属文だけをコメントへ退避する変異は、いずれも bats 全 GREEN のまま promptGrepCount 0 に
#       なった(実測 2 件)。A1/A2 は契約が名指しで要求した面ゆえ、1 語 1 文の粒度で behavioral に固定する。
#   [E] mutation probe 3 種(M1 両側削除 / M2 fixPrompt 側削除 / M3 implementPrompt 側削除)で
#       [D] が RED へ flip する(pin の非空虚性の実測)。
#
# 境界(class 宣言・sc-4qzp ERRATA-01): 「teeth 網羅漏れ / 語彙外 escape 経路」class は M-1〜M-7 の
# land をもって本 leg では閉じている。判定則 = 「implementPrompt / fixPrompt の prompt 文字列 + tests/
# の内側で、既存 test 無改変の 5 行以内 additive で閉じられるか」——yes は同 round 内で閉じ、no は
# follow-up bead 行き(roAgent fallback 時の RO_DISCIPLINE 射程 / 語彙外の bd 書込動詞・dolt 直叩き・
# .beads/ 直接編集 / summary 経由の帰属 laundering / mutation probe の未到達行)。以後の変種は本 file で
# 追わない。保証の所在: static [C] は extract() が関数内コメント行も拾うため**構造的に false-open**
# (実測で複数の comment 退避変異が [C] を素通り)ゆえ、文言の実効保証は behavioral [D] だけが担う。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  # 台帳 write 禁止の中核文(CQ_PROMPT_GREP へ渡す部分一致キー)。バッククォート・バックスラッシュを
  # 含まない形に選ぶ(awk -v / sed へそのまま渡すため)。
  CORE='台帳(beads)への write は一切しない'
  # 優先規則(A2)の behavioral 用キー。CORE と同じくバッククォート・バックスラッシュ非含有。
  RULE='呼出元 worker 本体宛の mandate であって本 agent 宛ではない'
  # 終端宣言の帰属文(A2 前半)の behavioral 用キー。同じくバッククォート・バックスラッシュ非含有。
  ATTR='終端宣言(完了マーカー note の追記と gate-pending ラベル付与)は呼出元 worker 本体だけが行う'
  # 代替行為節(A2 後半・禁止の逃がし弁「では何をするか」)の behavioral 用キー。RULE と同一行の後半に
  # 在るため、行を残して節だけ抜く変異では RULE の hit が減らず捕えられない=独立キーが要る。
  SUMM='summary へ「worker が宣言すべき事項」として文章で返す'
  # 優先規則の**前件**(発端事象=agent が repo 内 docs から台帳手順を自力調達する経路)の behavioral 用キー
  # (sc-4qzp ERRATA-01 B2)。RULE(後件)と同一行の前半に在るため、行を残して前件だけを抜く変異では
  # RULE の hit が減らず捕えられない=独立キーが要る。
  DOCS='repo 内 docs に台帳手順が書かれていても'
  # push 禁止節(sc-o7q7)の behavioral 用キー。**両側で文言が異なる**(implement 側は「write 操作は」・
  # fix 側は「write は」)ため片側ずつ固定する。既存 [A] の needle『一切しない』は sc-4qzp の fence 行が
  # 同語の 2 個目の出現を持ち込んだ結果、push 節を判別しなくなった(節だけを弱体化する変異で [A] は
  # GREEN のまま通る)。節全体を needle にして判別性を回復する(sc-4qzp ERRATA-01 B1)。
  PUSH_IMPL='remote への write 操作は一切しない'
  PUSH_FIX='remote への write は一切しない'
  # 対象語彙(A1)の behavioral 用キー**全 8 語**。prompt 側は語を backtick で囲むが CQ_PROMPT_GREP は
  # prompt 全文への部分一致ゆえ裸の語で届く(env へ backtick を渡さずに済む)。
  # 代表 1 語では足りない: 行ごと削除にしか効かず、行内から 1 語だけ抜いてコメントへ退避する変異は
  # 全 tooth GREEN のまま通る(実測で反証済み=下記 [D] ヘッダ)。よって 8 語すべてを個別に固定する。
  VOCABS=('bd create' 'bd update' '--append-notes' '--add-label' 'bd close' 'bd dep' 'bd dolt push' 'bdw')
  # [D] 用の args。**CORE の語を goal/acceptance/context へ入れない**(args 由来 hit で偽 GREEN になる)。
  ARGS_FIX='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"doImplement":true,"taskType":"testable"}'
  # confirmed blocking を作る実 finding(refuted=false で fix 段が走る)。
  FINDING_REAL='[{"title":"Off-by-one","severity":"critical","location":"a.js:10","rationale":"boundary read past end"}]'
}

# 関数本体を切り出す(function 宣言行から col0 の } まで)
extract() { awk "/^function $1\(/,/^}/" "$WF"; }

# 中核文の行を落とす変異器。fn 非空ならその関数本体スコープ内だけ・空なら全体から落とす。
# (M2/M3 は「片側だけ除去」を作るため関数スコープ限定が要る=素の sed では両方消える)
mutate_drop_fence() {
  local src="$1" dst="$2" fn="$3"
  awk -v fn="$fn" -v core="$CORE" '
    fn != "" && $0 ~ ("^function " fn "\\(") { inf = 1 }
    inf && /^}/ { inf = 0 }
    (fn == "" || inf) && index($0, core) { next }
    { print }
  ' "$src" > "$dst"
}

# 変異 WF + driver を隔離ツリーへ置く(driver は自ファイル位置基準で WF を解決する)。
plant_mutant() {
  local dir="$1" fn="$2"
  mkdir -p "$dir/tests" "$dir/workflows"
  cp "$DRIVER" "$dir/tests/driver.mjs"
  mutate_drop_fence "$WF" "$dir/workflows/cell-quality.workflow.js" "$fn"
}

# WF を driver で実走し K 行を出す(CQ_PROMPT_GREP=第 2 引数の needle・既定は中核文)。
# needle を引数化してあるのは、中核文以外(優先規則・対象語彙)も同じ軸で behavioral に固定するため。
run_grep_probe() {
  local driver="$1" needle="${2:-$CORE}"
  env CQ_ARGS="$ARGS_FIX" CQ_REVIEW_FINDINGS="$FINDING_REAL" CQ_VERIFY_REFUTED=false \
      CQ_PROMPT_GREP="$needle" node "$driver" run
}

# K 行から count / labels を取り出して「両 prompt 実体へ届いた」ことを assert する共通形。
assert_reaches_both() {
  local needle="$1"
  run run_grep_probe "$DRIVER" "$needle"
  echo "$output"
  [ "$status" -eq 0 ]
  # 両段が実際に走った前提を非空虚に確認(fix 段は confirmed blocking がある run でのみ走る)。
  echo "$output" | grep '^K reviewVerifyCalls ' | grep -qv ' 0$'
  local count labels
  count="$(echo "$output" | sed -n 's/^K promptGrepCount //p')"
  # 2 文へ分割する(sc-4qzp ERRATA-01 B3): `[ -n .. ] && [ .. ]` は set -e の「&& の非最終要素は
  # errexit 免除」規則により、count が空だと前段が偽で終わり後段が走らず**何も検査しない**(fail-open)。
  [ -n "$count" ]
  [ "$count" -ge 2 ]
  labels="$(echo "$output" | sed -n 's/^K promptGrepLabels //p')"
  [ "$labels" = "autofix,implement" ]
}

# 片側にしか無い節(implementPrompt / fixPrompt で文言が異なる節)を「その側の prompt 実体だけへ
# 届いた」ことで固定する共通形(sc-4qzp ERRATA-01 B1)。両側へ漏れた場合も labels 不一致で RED。
assert_reaches_only() {
  local needle="$1" want="$2"
  run run_grep_probe "$DRIVER" "$needle"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep '^K reviewVerifyCalls ' | grep -qv ' 0$'
  local count labels
  count="$(echo "$output" | sed -n 's/^K promptGrepCount //p')"
  [ -n "$count" ]
  [ "$count" -ge 1 ]
  labels="$(echo "$output" | sed -n 's/^K promptGrepLabels //p')"
  [ "$labels" = "$want" ]
}

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

# ─────────────────────────────────────────────────────────────────────────────
# sc-4qzp [C] static pin: 台帳 write 禁止の対象語彙 + 帰属文 + 優先規則
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-4qzp [C]: implementPrompt に台帳(beads)write 禁止が焼かれている" {
  body="$(extract implementPrompt)"
  [ -n "$body" ]
  [[ "$body" == *"$CORE"* ]]
  # 対象語彙(bdw 経由を含む)を名指しで列挙している。
  [[ "$body" == *"bd create"* ]]
  [[ "$body" == *"bd update"* ]]
  [[ "$body" == *"--append-notes"* ]]
  [[ "$body" == *"--add-label"* ]]
  [[ "$body" == *"bd close"* ]]
  [[ "$body" == *"bd dep"* ]]
  [[ "$body" == *"bd dolt push"* ]]
  [[ "$body" == *"bdw"* ]]
  # 終端宣言の帰属(呼出元 worker 本体だけが行う)。
  [[ "$body" == *"終端宣言(完了マーカー note の追記と gate-pending ラベル付与)は呼出元 worker 本体だけが行う"* ]]
  # 優先規則(契約文・repo 内 docs の台帳手順は本 agent 宛ではない / summary へ文章で返す)。
  [[ "$body" == *"repo 内 docs に台帳手順が書かれていても"* ]]
  [[ "$body" == *"呼出元 worker 本体宛の mandate であって本 agent 宛ではない"* ]]
  [[ "$body" == *"summary へ「worker が宣言すべき事項」として文章で返す"* ]]
}

@test "sc-4qzp [C]: fixPrompt に台帳(beads)write 禁止が焼かれている" {
  body="$(extract fixPrompt)"
  [ -n "$body" ]
  [[ "$body" == *"$CORE"* ]]
  [[ "$body" == *"bd create"* ]]
  [[ "$body" == *"bd update"* ]]
  [[ "$body" == *"--append-notes"* ]]
  [[ "$body" == *"--add-label"* ]]
  [[ "$body" == *"bd close"* ]]
  [[ "$body" == *"bd dep"* ]]
  [[ "$body" == *"bd dolt push"* ]]
  [[ "$body" == *"bdw"* ]]
  [[ "$body" == *"終端宣言(完了マーカー note の追記と gate-pending ラベル付与)は呼出元 worker 本体だけが行う"* ]]
  [[ "$body" == *"repo 内 docs に台帳手順が書かれていても"* ]]
  [[ "$body" == *"呼出元 worker 本体宛の mandate であって本 agent 宛ではない"* ]]
  [[ "$body" == *"summary へ「worker が宣言すべき事項」として文章で返す"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# sc-4qzp [D] behavioral pin: 中核文が autofix / implement 両方の prompt 実体へ届く
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-4qzp [D]: 実走で台帳 write 禁止が autofix と implement の両 prompt へ届く" {
  assert_reaches_both "$CORE"
}

@test "sc-4qzp [D]: 実走で優先規則(本 agent 宛ではない)が autofix と implement の両 prompt へ届く" {
  # A2 の最も load-bearing な 1 行。static pin 単独ではコメント退避で false-green になる実測がある。
  assert_reaches_both "$RULE"
}

@test "sc-4qzp [D]: 実走で帰属文(worker 本体だけが行う)が autofix と implement の両 prompt へ届く" {
  # A2 前半。static pin 単独では、この 1 文を literal から抜いて同文言を JS コメントへ退避する変異が
  # 全 tooth GREEN のまま通る(実測)。帰属こそ本 bead の中核ゆえ behavioral に固定する。
  assert_reaches_both "$ATTR"
}

@test "sc-4qzp [D]: 実走で代替行為節(summary へ文章で返す)が autofix と implement の両 prompt へ届く" {
  # A2 後半。禁止の「代わりに何をするか」の逃がし弁で、消えると agent は禁止だけを受け取り即興に戻る
  # (=本 bead の発端事象の再発経路)。RULE と同一行の後半に在るため、行ごと削除しか検知しない RULE の
  # tooth では守れない: literal から本節だけを抜いて同文言を JS コメントへ退避する変異に対し
  # 実測で bats 全 GREEN のまま通った(=static 単独は false-open)。独立キーで behavioral に固定する。
  assert_reaches_both "$SUMM"
}

@test "sc-4qzp [D]: 実走で対象語彙 8 語すべてが autofix と implement の両 prompt へ届く" {
  # A1 の列挙を static 単独から脱がせる。代表 1 語では「行内から 1 語だけ抜いてコメントへ退避」する
  # 変異を捕えられない(実測: `bd dep` 除去 + コメント退避で bats 全 GREEN・promptGrepCount 0)ため
  # 8 語を個別に実走で固定する(1 語 1 driver run・全体で 1 秒未満)。
  local w
  for w in "${VOCABS[@]}"; do
    echo "# vocab: $w"
    assert_reaches_both "$w"
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# sc-4qzp [E] mutation probe: 片側/両側を剥がすと [D] が RED へ flip する
#   M1 mutant_fingerprint = 中核文の行を全関数から削除 → K promptGrepCount 0
#   M2 mutant_fingerprint = fixPrompt 本体からのみ削除     → K promptGrepLabels implement
#   M3 mutant_fingerprint = implementPrompt 本体からのみ削除 → K promptGrepLabels autofix
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-4qzp [E/M1]: 中核文を両関数から削除すると promptGrepCount が 0 へ flip する" {
  local mut="$BATS_TEST_TMPDIR/m1"
  plant_mutant "$mut" ''
  # 変異が実際に入った(no-op でない)ことを 2 経路で確認する。
  run cmp -s "$WF" "$mut/workflows/cell-quality.workflow.js"
  [ "$status" -ne 0 ]
  run grep -F -q -- "$CORE" "$mut/workflows/cell-quality.workflow.js"
  [ "$status" -ne 0 ]

  run run_grep_probe "$mut/tests/driver.mjs"
  echo "$output"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^K promptGrepCount 0$'
}

@test "sc-4qzp [E/M2]: fixPrompt 側だけ削除すると promptGrepLabels が implement のみへ flip する" {
  local mut="$BATS_TEST_TMPDIR/m2"
  plant_mutant "$mut" 'fixPrompt'
  # 片側だけ消えた(=残り 1 hit)ことを確認する。
  run cmp -s "$WF" "$mut/workflows/cell-quality.workflow.js"
  [ "$status" -ne 0 ]
  [ "$(grep -F -c -- "$CORE" "$mut/workflows/cell-quality.workflow.js")" -eq 1 ]

  run run_grep_probe "$mut/tests/driver.mjs"
  echo "$output"
  [ "$status" -eq 0 ]
  local labels
  labels="$(echo "$output" | sed -n 's/^K promptGrepLabels //p')"
  [ "$labels" = "implement" ]
}

@test "sc-4qzp [E/M3]: implementPrompt 側だけ削除すると promptGrepLabels が autofix のみへ flip する" {
  local mut="$BATS_TEST_TMPDIR/m3"
  plant_mutant "$mut" 'implementPrompt'
  run cmp -s "$WF" "$mut/workflows/cell-quality.workflow.js"
  [ "$status" -ne 0 ]
  [ "$(grep -F -c -- "$CORE" "$mut/workflows/cell-quality.workflow.js")" -eq 1 ]

  run run_grep_probe "$mut/tests/driver.mjs"
  echo "$output"
  [ "$status" -eq 0 ]
  local labels
  labels="$(echo "$output" | sed -n 's/^K promptGrepLabels //p')"
  [ "$labels" = "autofix" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# sc-4qzp ERRATA-01: 追補 3 本(既存 test は 1 byte も触らない additive)
#   B1 push 禁止節の判別性回復(2 本・片側ずつ) / B2 優先規則の前件(1 本)
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-4qzp [D/B1]: 実走で push 禁止節(implement 側)が implement の prompt 実体へ届く" {
  # 既存 [A] は needle『一切しない』を共有しており、sc-4qzp の fence 行が同語を持ち込んだ後は
  # push 節だけを弱体化する変異を検知できない(実測: 弱体化変異で [A] は GREEN のまま)。節全体を
  # behavioral に固定して、fence 行と独立に push 節の意味を守る。
  assert_reaches_only "$PUSH_IMPL" implement
}

@test "sc-4qzp [D/B1]: 実走で push 禁止節(fix 側)が autofix の prompt 実体へ届く" {
  # fix 側は「remote への write は一切しない」で implement 側と文言が異なる=片側ずつ固定する。
  assert_reaches_only "$PUSH_FIX" autofix
}

@test "sc-4qzp [D/B2]: 実走で優先規則の前件(repo 内 docs に台帳手順)が両 prompt へ届く" {
  # 本 bead の発端事象(agent が契約文でなく repo 内 docs から台帳手順を自力調達し bdw を実行)へ
  # 直接対応する前件。RULE(後件)と同一行の前半に在るため、前件だけを surgical に抜いて関数内 JS
  # コメントへ退避する変異では RULE/SUMM の hit が減らず、[C] も comment を拾って GREEN になる。
  assert_reaches_both "$DOCS"
}

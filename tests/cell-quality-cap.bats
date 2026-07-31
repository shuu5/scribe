#!/usr/bin/env bats
# sc-k33c (M0 波1 L1a=C1a) — cell-quality の 3 層 cap（幅の制御）の behavioral 恒久回帰テスト。
#
# 背景: cell-quality の fan-out は「観点数 × finding 数 × round 数」で伸び、上限が harness 任せ（min(16,cores-2)）
# だった。totalBudget（**単位 = agent 本数**）と perRoundVerifyTopK（観点単位 top-K）を opt-in で入れ、
#   層1 = args 正規化 + fail-fast（不正値を既定へ黙って倒さない＝silent fail-open を作らない）
#   層2 = admission control 4 点（round 頭 / review 前 / verify 前 / fix 前。snapshot・self-test・classify は免除）
#   層3 = cap 系例外（WorkflowBudgetExceededError / WorkflowAgentCapError）を capExceeded へ正規化
#         （＝「result を返さず run が消える」現状の解消）
# を配線した。数値既定は現状維持で、fail-loud 表面（capExceeded / capReport / capDropped / gate の capNote）
# だけが既定 ON。
#
# 【後方互換の保証面（claim を実挙動へ揃える・sc-k33c self-review errata）】cap 未指定（totalBudget 未指定＝
# 実運用 100% の既定路）が保証するのは **agent 呼出し列（callSeq）が base 木と完全一致すること** であって、
# 「終端状態まで完全に base と同一」ではない。cap 指紋（'token budget' / 'agent cap' 等の部分文字列一致）を
# 持つ例外を捕捉した run は、cap を頼んでいなくても capExceeded=true となり converged を立てない
# （fail-closed 側＝**意図した非互換**）。ただし escalate は blocking 級 drop があるときだけ立てる
# （K1 項目5）。この差分は [H] の "terminal 非互換の明示 pin" tooth が base 木対照で明示的に固定する
# （＝将来この分岐が fail-open 側へ倒れたら suite が RED になる）。
#
# 検証の建て付け:
#   [A] static pin  — sentinel / 単位契約 verbatim / message 指紋 literal / return path / gate 連結
#   [B] behavioral  — 正方向 3 tooth（総数 ≤ N / 観点単位 top-K / capDropped と unverified の非二重計上）+ terminal
#   [C] reason 3 値（'cap' / 'quota' / 'error'）がそれぞれ立つ経路 + capReport 最小 field
#   [D] 層3 の 6 call site + parallel/pipeline 入口 + 非 cap 例外の fail-closed
#   [E] 決定論（stage1 解決順を入れ替えても admit 集合が同一＝共有カウンタ先着順にしていない証拠）
#   [F] 後方互換（cap 未指定時の agent 呼出し列が base 木と完全一致・minor/nit も全部 verify される）
#   [G] 変異注入 8 種（6 call site の catch + K1b(i)(ii) の 2 catch）＝正方向 tooth の非空虚性
#   [H] self-review errata（B4 不変条件 / round gate の escalate / 必須4観点 all-or-nothing /
#       capCatch fail-closed の behavioral 面 / 例外経路の後方互換〔callSeq〕/ terminal 非互換の明示 pin /
#       spentEstimate 監査 / reserveFix / 縮退順の『非 blocking のみ round』modality）
#       + 変異注入 MU9・MU10・MU11・MU12
#
# 変異注入は必ず BATS_TEST_TMPDIR の copy 木へ行う（実 file を変異させたまま commit しない）。
# base 木対照 tooth（[F] 2 本 + [H] terminal pin）の base は **可動 ref でなく不変 SHA**（setup() の
# CAP_BASE_REF）。理由は setup() のコメント参照＝可動 ref だと本 diff の land と同時に (a) 呼出し列比較が
# 自己比較で空虚化 / (b) terminal pin が決定論的に RED、という恒久回帰 suite の自己破壊が起きる。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"

  # worker-cell 形の基底 args（autoFix + selfTestCmd + taskType 指定＝classify を回さない決定論形）。
  ARGS_BASE='{"taskTitle":"cap-cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable"}'
  # severity 混在の finding 集合（決定論 tie-break の観測に使う: critical AAA > major CCC > minor BBB）。
  FINDINGS_MIX='[{"title":"AAA","severity":"critical","location":"a.js:1","rationale":"boundary"},{"title":"BBB","severity":"minor","location":"b.js:2","rationale":"style"},{"title":"CCC","severity":"major","location":"c.js:3","rationale":"fail-open"}]'
  # minor/nit のみ（後方互換 F2 と「blocking 級でない drop は escalate させない」terminal の観測）。
  FINDINGS_MINOR='[{"title":"MMM","severity":"minor","location":"m.js:1","rationale":"naming"},{"title":"NNN","severity":"nit","location":"n.js:2","rationale":"spacing"}]'
  # 非 blocking のみ 3 件（縮退順「critical/major 限定」段の適用条件〔blocking が在るときだけ限定する〕を踏む）。
  FINDINGS_NONBLOCKING='[{"title":"MMM","severity":"minor","location":"m.js:1","rationale":"naming"},{"title":"NNN","severity":"nit","location":"n.js:2","rationale":"spacing"},{"title":"OOO","severity":"minor","location":"o.js:3","rationale":"naming2"}]'

  # ── base 木の指し先は【不変 SHA へ pin】する（可動 ref を使わない） ─────────────
  # 契約 K2' の literal は `git show origin/main:...` だが、origin/main は **可動 ref** である。本 diff が
  # main へ land した瞬間に origin/main は cap 入りの木を指し、base 木 == HEAD 木になる。その結果:
  #   (a) 呼出し列比較の 2 本（K2' / K2'(例外経路)）は自分自身との比較になり **vacuous pass**
  #       ＝後方互換 guard が sound に green のまま何も守らなくなる（guard の fail-open）。
  #   (b) "terminal 非互換の明示 pin" は base 側にも cap 分岐が入るため base=OPEN となり **決定論的に RED**
  #       ＝file 冒頭が名乗る「behavioral 恒久回帰テスト」が land と同時に自己破壊する。
  # → 「base 木」の実体である **cap 実装前の凍結点**（Leg-A land commit 46958e5＝本 bead の実 base。契約 K2'
  #   が求める「base 木から driver 実走で生成」を満たす）の不変 SHA を既定にする。本リポの既存流儀
  #   （tests/blob-revive-guard.bats は fixture の origin/main を update-ref で **固定** する）とも揃う。
  #   ※この pin は更新しない（origin/main へ戻すと上の (a)(b) が再発する）。
  CAP_BASE_REF="${SC_K33C_BASE_REF:-46958e5}"
}

# base 木（cap 実装前）の WF + driver を dir へ materialize する。
# 到達不能なら **skip でなく loud fail**（base 対照 tooth を silent に無効化しない＝fail-closed）。
# base 木が既に cap 入りなら base==HEAD の自己比較＝空虚ゆえ同じく loud fail（空虚化を silent にしない）。
materialize_base_tree() {
  local dir="$1"
  mkdir -p "$dir/workflows" "$dir/tests"
  if ! git -C "$REPO_ROOT" cat-file -e "${CAP_BASE_REF}:workflows/cell-quality.workflow.js" 2>/dev/null; then
    echo "# FATAL: base ref '${CAP_BASE_REF}' から workflows/cell-quality.workflow.js を読めない" >&2
    echo "#        (shallow clone / gc / 別リポ等)。base 対照 tooth は skip せず fail する" >&2
    echo "#        = 対照が消えたまま green を返すのは fail-open。SC_K33C_BASE_REF で cap 実装前の commit を指定せよ。" >&2
    return 1
  fi
  git -C "$REPO_ROOT" show "${CAP_BASE_REF}:workflows/cell-quality.workflow.js" > "$dir/workflows/cell-quality.workflow.js"
  if grep -q '^//SCCAP_BLOCK_START$' "$dir/workflows/cell-quality.workflow.js"; then
    echo "# FATAL: base 木 (${CAP_BASE_REF}) が既に cap 入り（//SCCAP_BLOCK_START が在る）＝ base==HEAD の自己比較で" >&2
    echo "#        tooth が空虚化する。可動 ref を base に使っていないか確認し、cap 実装前の commit を指定せよ。" >&2
    return 1
  fi
  cp "$DRIVER" "$dir/tests/driver.mjs"
}

# ARGS_BASE へ JSON 片をマージする（args を手組みせず 1 経路で作る）。
cq_args() {
  node -e 'const a=JSON.parse(process.argv[1]);Object.assign(a,JSON.parse(process.argv[2]||"{}"));console.log(JSON.stringify(a))' "$ARGS_BASE" "$1"
}

# K 行から値を取り出す（herestring 経由＝pipefail 下の SIGPIPE 偽 RED を作らない）。
kval() {
  local out="$1" key="$2"
  sed -n "s/^K ${key} //p" <<< "$out"
}

# 変異木を BATS_TEST_TMPDIR に作る: WF の literal を sed で置換し、driver は最終木のものを使う。
plant_cap_mutant() {
  local dir="$1" pattern="$2" replacement="$3"
  mkdir -p "$dir/workflows" "$dir/tests"
  cp "$DRIVER" "$dir/tests/driver.mjs"
  sed "s|${pattern}|${replacement}|" "$WF" > "$dir/workflows/cell-quality.workflow.js"
  # 変異が実際に入った（no-op でない）ことを確認する＝空虚な mutation tooth を作らない。
  ! cmp -s "$WF" "$dir/workflows/cell-quality.workflow.js"
}

# ─────────────────────────────────────────────────────────────────────────────
# [A] static pin
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c K8: cap 判定コードが //SCCAP_BLOCK_START〜//SCCAP_BLOCK_END の 1 ブロックに閉じている" {
  [ "$(grep -c '^//SCCAP_BLOCK_START$' "$WF")" -eq 1 ]
  [ "$(grep -c '^//SCCAP_BLOCK_END$' "$WF")" -eq 1 ]
  # START が END より前に在る（sentinel の順序が壊れていない）。
  local s e
  s="$(grep -n '^//SCCAP_BLOCK_START$' "$WF" | cut -d: -f1)"
  e="$(grep -n '^//SCCAP_BLOCK_END$' "$WF" | cut -d: -f1)"
  [ "$s" -lt "$e" ]
  # cap の判定ヘルパ定義がブロックの内側に在る（外へ漏れていない）。call site は helper を呼ぶだけ。
  local body
  body="$(sed -n "${s},${e}p" "$WF")"
  grep -q 'const capAdmit = ' <<< "$body"
  grep -q 'const capRoundGate = ' <<< "$body"
  grep -q 'const capVerifyQuotaPerDim = ' <<< "$body"
  grep -q 'const capSelectVerify = ' <<< "$body"
  grep -q 'const capClassify = ' <<< "$body"
  grep -q 'const capCatch = ' <<< "$body"
  grep -q 'const capReclassify = ' <<< "$body"
  # 定義はブロック内に 1 個ずつ（外側に重複定義を置いていない）。
  [ "$(grep -c 'const capClassify = ' "$WF")" -eq 1 ]
  [ "$(grep -c 'const capSelectVerify = ' "$WF")" -eq 1 ]
}

@test "sc-k33c K1: totalBudget の単位契約（agent 本数・token ではない）が verbatim で焼かれている" {
  run grep -F -q -- 'totalBudget の単位は **agent 本数** である(token ではない)' "$WF"
  [ "$status" -eq 0 ]
  # 返り値側の単位表明（呼出元が返り値だけで単位を読める）。
  run grep -F -q -- "unit: 'agent-calls'" "$WF"
  [ "$status" -eq 0 ]
  # token は判定に使わない（情報ログ併走のみ）ことの明示。
  run grep -F -q -- '情報ログ併走のみ(判定に使わない)' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-k33c K1b(iii): cap 例外の指紋（name 2 種 + message 5 種）が literal で drift pin されている" {
  # name 側（harness の例外クラス名）。
  run grep -F -q -- 'WorkflowBudgetExceededError' "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- 'WorkflowAgentCapError' "$WF"
  [ "$status" -eq 0 ]
  # message 側の実測指紋（実機の文言が変わったらこの tooth が RED になる＝drift 検知面）。
  local fp
  for fp in 'budget exceeded' 'token budget' 'agent cap' 'agent limit' 'exceeded the agent'; do
    echo "# fingerprint: $fp"
    run grep -F -q -- "{ pat: '$fp'" "$WF"
    [ "$status" -eq 0 ]
  done
  # AND 禁止: name 一致で即 return（message を見ずに確定する）経路が在る＝OR 構造の機械証跡。
  run grep -F -q -- 'if (CAP_ERROR_NAMES[name]) return CAP_ERROR_NAMES[name]' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-k33c K1: cap の新 field が【実在する全 return path】に載る（載っていない return が 0 本）" {
  # Leg-A の canonical cutover 後、result-level の return は 1 本（`return result`）だけ。
  # 「3 つの return path」は契約 literal の旧値ゆえ、実在本数を機械で数えて読む。
  [ "$(grep -cE '^return ' "$WF")" -eq 1 ]
  run grep -qE '^return result$' "$WF"
  [ "$status" -eq 0 ]
  # result 組立に 3 field がちょうど 1 回ずつ（helper の return へ紛れ込ませない＝監査面を二重化しない）。
  [ "$(grep -cE '^[[:space:]]*capExceeded,$' "$WF")" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]*capReport,$' "$WF")" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]*capDropped,$' "$WF")" -eq 1 ]
  ! grep -nE '^[[:space:]]*return \{.*capReport' "$WF"
  ! grep -nE '^[[:space:]]*return \{.*capDropped' "$WF"
  # 実走でも 3 field が返り値 JSON に載る（static だけで満足しない）。
  run env CQ_ARGS="$(cq_args '{}')" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"capExceeded":'* ]]
  [[ "$output" == *'"capReport":{'* ]]
  [[ "$output" == *'"capDropped":['* ]]
}

@test "sc-k33c K8: capNote は 3 分岐とも schemaNote 直後（末尾）に連結し gate prefix は不変" {
  # 4 つ目の note がちょうど 3 箇所（CONVERGED/ESCALATE/OPEN）へ連結されている。
  [ "$(grep -F -c -- '+ unvNote + machNote + schemaNote + capNote' "$WF")" -eq 3 ]
  # 既存 3 note の連結順（schemaNote までの並び）を壊していない＝sc-tx8s の pin と両立する。
  [ "$(grep -F -c -- '+ unvNote + machNote + schemaNote' "$WF")" -eq 3 ]
  # gate 3 分岐の prefix は不変。
  run grep -F -q -- "? 'CONVERGED: " "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- "? 'ESCALATE: " "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- ": 'OPEN: " "$WF"
  [ "$status" -eq 0 ]
  # canonical 3-クラス block（CANON_SHA256 pin 対象）を触っていない＝18 行がそのまま在る。
  [ "$(grep -c '^//      │' "$WF")" -eq 18 ]
}

@test "sc-k33c 層1: 新 args の不正値は fail-fast（silent fallback しない・agent を 1 体も起動しない）" {
  local bad
  for bad in '{"totalBudget":0}' '{"totalBudget":-1}' '{"totalBudget":"8"}' '{"totalBudget":2.5}' '{"perRoundVerifyTopK":0}' '{"perRoundVerifyTopK":"2"}' '{"perRoundVerifyTopK":[]}'; do
    echo "# bad args: $bad"
    run env CQ_ARGS="$(cq_args "$bad")" node "$DRIVER" run
    [ "$status" -ne 0 ]
    [[ "$output" == *'[cell-quality cap args fail-fast]'* ]]
    # canonical preamble の marker とは別 prefix（帰属を弁別できる）。
    [[ "$output" != *'[SCARGS fail-fast]'* ]]
    # agent は 1 体も起動していない。
    [[ "$output" == *'DRIVER_AGENT_CALLS 0'* ]]
  done
}

@test "sc-k33c 層1: 免除段の下限を下回る totalBudget は fail-fast（守れない cap を受けない）" {
  # selfTestCmd 供給 + taskType 指定 + round1 snapshot ＝ 免除段 3 本。3+1 未満は保証不能ゆえ throw。
  run env CQ_ARGS="$(cq_args '{"totalBudget":3}')" node "$DRIVER" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'[cell-quality cap args fail-fast]'* ]]
  [[ "$output" == *'免除段下限'* ]] || [[ "$output" == *'免除段'* ]]
  [[ "$output" == *'DRIVER_AGENT_CALLS 0'* ]]
  # 下限ちょうど（4）は throw しない（境界の両側を押さえる）。
  run env CQ_ARGS="$(cq_args '{"totalBudget":4}')" node "$DRIVER" run
  [ "$status" -eq 0 ]
}

@test "sc-k33c 層1: 新 args の fail-fast は【全モード】で発火する（worker-cell 限定にしない）" {
  # single モード（autoFix/doImplement なし＝isWorkerCell=false）でも不正値で throw する。
  local single='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x","totalBudget":-5}'
  run env CQ_ARGS="$single" node "$DRIVER" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'[cell-quality cap args fail-fast]'* ]]
  [[ "$output" == *'DRIVER_AGENT_CALLS 0'* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# [B] behavioral 中核（正方向 3 tooth + terminal）
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c K3-1: totalBudget=N のとき実 agent 呼出し総数が N 以下（callSeq を数える）" {
  # (sc-k33c errata) 小予算 5/6/7 を必ず含める。8/12/16 だけだと **どの run でも 4 観点すべてが admit され**、
  # 層2-②（review 前 admission）が常に inert な regime でしか「総数 ≤ N」を検証していなかった＝admission を
  # 丸ごとバイパスする変異でも suite が green のままだった（MU10 が RED になる予算域をここで踏む）。
  local n out total
  for n in 5 6 7 8 12 16; do
    echo "# totalBudget=$n"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
        CQ_VERIFY_REFUTED=false node "$DRIVER" run
    [ "$status" -eq 0 ]
    out="$output"
    total="$(kval "$out" agentCallTotal)"
    # callSeq の実要素数とも突き合わせる（K agentCallTotal 単独の自己申告にしない）。
    local seq_count
    seq_count="$(awk -F'|' '{print NF}' <<< "$(kval "$out" callSeq)")"
    [ "$total" -eq "$seq_count" ]
    [ "$total" -le "$n" ]
    # 非空虚: cap 無しなら総数はこれを超える（＝この tooth は「元から N 以下」で受かっていない）。
    [ "$(kval "$out" capExceeded)" = "true" ]
    # 落とした分は必ず capDropped[] に列挙される（capStages だけに痕跡が残る fail-open を作らない）。
    [ "$(kval "$out" capDroppedCount)" -gt 0 ]
    [ -n "$(kval "$out" capDroppedReasons)" ]
  done
  # 対照: cap 未指定なら総数は 16 を超える（上の n=16 が実際に縮退していた証拠）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" agentCallTotal)" -gt 16 ]
}

@test "sc-k33c K3-2: perRoundVerifyTopK=K で観点別 verify 数が min(K, 対象数) になる" {
  # 観点(dimension)単位 top-K（共有カウンタ先着順ではない）。既定 4 観点 × 1 round 分を観点別に数える。
  # K=2・対象 3 件 → 各観点 2 件、K=5・対象 3 件 → 各観点 3 件（min の両側）。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":2,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=2,correctness=2,integration-ops=2,robustness-security=2" ]
  [ "$(kval "$output" verifyCallCount)" -eq 8 ]
  # 落ちたのは severity 最下位（minor BBB）＝決定論 tie-break（severity 降順）の証跡。
  [ "$(kval "$output" capDroppedTitles)" = "BBB;BBB;BBB;BBB" ]
  [ "$(kval "$output" capDroppedReasons)" = "perRoundVerifyTopK" ]

  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":5,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=3,correctness=3,integration-ops=3,robustness-security=3" ]
  # K > 対象数 なら 1 件も落とさない（cap は発火しない）。
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
}

@test "sc-k33c K3-3: 縮退分は capDropped[] に列挙され unverified と二重計上されない" {
  # topK で BBB を落としつつ、残る AAA/CCC の verify agent は cap 例外で verdict:null（＝unverified）にする。
  # 「verify を起動しなかった（capDropped）」と「verdict が取れなかった（unverified）」は別事象＝集合が交わらない。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":2,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_THROW_AT_STAGE=element-budget node "$DRIVER" run
  [ "$status" -eq 0 ]
  local dropped unverified
  dropped="$(kval "$output" capDroppedTitles)"
  unverified="$(kval "$output" unverifiedTitles)"
  # 落とした側には BBB（minor）だけ、unverified 側には AAA/CCC（起動したが verdict 不成立）。
  grep -q 'BBB' <<< "$dropped"
  [ "$unverified" = "AAA;CCC" ]
  ! grep -q 'BBB' <<< "$unverified"
  # unverified の件数（4 観点 × 2 件）と capDropped の件数が独立に立っている。
  [ "$(kval "$output" unverifiedCount)" -eq 8 ]
  [ "$(kval "$output" capDroppedCount)" -gt 0 ]
}

@test "sc-k33c terminal: capExceeded なら converged を立てず、blocking 級 drop 時のみ escalate する" {
  # (a) blocking 級（critical/major）を落とした → escalate。
  run env CQ_ARGS="$(cq_args '{"totalBudget":8}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" capDroppedBlocking)" -gt 0 ]
  [ "$(kval "$output" gateHasCapNote)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]

  # (b) minor/nit だけを落とした → converged は立てないが escalate はしない（escalate の安売り防止）。
  # maxRounds は既定のまま（1 に絞ると autoFix loop が zeroStreak>=2 に届かず【従来の】hard cap escalate が
  # 立ってしまい、cap 由来かどうかを弁別できなくなる＝この tooth が空虚になる）。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MINOR" \
      CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" capDroppedBlocking)" -eq 0 ]
  [ "$(kval "$output" gateHasCapNote)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "OPEN" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [C] K1a: capReport の最小 field と reason 3 値
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c K1a: capReport の最小 field（limit/unit/spentEstimate/stages/reason/droppedAgents）+ history 件数" {
  run env CQ_ARGS="$(cq_args '{"totalBudget":8}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capLimit)" -eq 8 ]
  [ "$(kval "$output" capUnit)" = "agent-calls" ]
  [ "$(kval "$output" capSpentEstimate)" -gt 0 ]
  [ "$(kval "$output" capStagesCount)" -gt 0 ]
  [ "$(kval "$output" capDroppedAgents)" -gt 0 ]
  [ "$(kval "$output" capReason)" = "cap" ]
  # description 項目3 の history 件数が capReport から辿れる（result.history の実長と一致）。
  local hc rounds
  hc="$(kval "$output" capHistoryCount)"
  [ "$hc" -ge 1 ]
  [ "$hc" -eq "$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).history.length)' "$output")" ]
}

@test "sc-k33c K1a: reason='cap'（自前 admission）が立つ経路" {
  run env CQ_ARGS="$(cq_args '{"totalBudget":8}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capReason)" = "cap" ]
  [ "$(kval "$output" capExceeded)" = "true" ]
}

@test "sc-k33c K1a: reason='quota'（harness の token budget 例外）が name/message 両経路で立つ" {
  local mode
  for mode in name message; do
    echo "# CAP_ERR_MODE=$mode"
    run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='review:' CQ_THROW_KIND=quota \
        CQ_CAP_ERR_MODE="$mode" node "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(kval "$output" capReason)" = "quota" ]
    [ "$(kval "$output" capExceeded)" = "true" ]
    [ "$(kval "$output" converged)" = "false" ]
  done
}

@test "sc-k33c K1a: reason='error'（harness の agent cap 例外）が name/message 両経路で立つ" {
  local mode
  for mode in name message; do
    echo "# CAP_ERR_MODE=$mode"
    run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='review:' CQ_THROW_KIND=error \
        CQ_CAP_ERR_MODE="$mode" node "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(kval "$output" capReason)" = "error" ]
    [ "$(kval "$output" capExceeded)" = "true" ]
  done
}

@test "sc-k33c K1b(v): budget.total 未設定（null）でも判定は本数で成立し token は情報ログのみ" {
  # budget.total=null（実機の既定）— tokenDelta は 0（spent 増分なし）だが cap 判定は本数で効く。
  run env CQ_ARGS="$(cq_args '{"totalBudget":8}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capBudgetTotal)" = "null" ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  # budget.total を与えた場合は値が載り、token delta も情報として出る（判定は変わらない＝本数のまま）。
  run env CQ_ARGS="$(cq_args '{"totalBudget":8}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_BUDGET_TOTAL=100000 CQ_SPEND_PER_AGENT=1000 node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capBudgetTotal)" -eq 100000 ]
  [ "$(kval "$output" capTokenDelta)" -gt 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [D] 層3: 6 call site + 入口 throw + 非 cap の fail-closed
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c K1b: 無防備だった 6 call site が cap 例外で run を消さず result を返す" {
  # classify / plan / implement / snapshot / pipeline 入口 / fix。いずれも throw が出ても driver は rc=0 で
  # RESULT を返す（＝「result を返さず消える」現状の解消）。
  local case_args case_label
  # classify（taskType を渡さない形）
  run env CQ_ARGS='{"taskTitle":"c","worktree":"/tmp/wt","goal":"g","selfTestCmd":"true","autoFix":true}' \
      CQ_THROW_AT_LABEL='classify' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [[ "$output" == *'RESULT {'* ]]

  # plan
  run env CQ_ARGS="$(cq_args '{"doPlan":true}')" CQ_THROW_AT_LABEL='plan' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]

  # implement
  run env CQ_ARGS="$(cq_args '{"doImplement":true}')" CQ_THROW_AT_LABEL='implement' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]

  # snapshot
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]

  # fix（confirmed blocking が在る run でのみ走る）
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false \
      CQ_THROW_AT_LABEL='autofix' node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" converged)" = "false" ]

  # pipeline 入口（同期 throw）
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_STAGE=pipeline node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "error" ]
}

@test "sc-k33c K1b(ii): parallel/pipeline 入口 throw が reviewFailed へ誤帰属しない" {
  # parallel 入口（stage2 内）: review は成功しているので reviewFailed は立てず、cap 側で記録する。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_THROW_AT_STAGE=parallel node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "quota" ]
  # 誤帰属していれば history の reviewFailed が観点数分立つ。0 であることを RESULT から直読する。
  [ "$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const h=JSON.parse(m[1]).history;console.log(h.map(x=>x.reviewFailed).join(","))' "$output")" = "0" ]
  # review は実際に走っている（空虚でない）。
  [ "$(kval "$output" reviewCallCount)" -gt 0 ]

  # pipeline 入口: 同じく reviewFailed へ倒さず、落とした観点を capDropped[] に列挙する。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_THROW_AT_STAGE=pipeline node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const h=JSON.parse(m[1]).history;console.log(h.map(x=>x.reviewFailed).join(","))' "$output")" = "0" ]
  grep -q 'entry-throw' <<< "$(kval "$output" capDroppedReasons)"
}

@test "sc-k33c K1b(iii): cap 指紋に非一致な例外は cap 扱いせず従来経路へ倒す（fail-closed）" {
  # 無防備 call site（snapshot）で cap でない throw → 再 throw され run が死ぬ（＝従来挙動を 1 mm も変えない）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_SELFTEST_AGENT_FAIL=baseline node "$DRIVER" run
  [ "$status" -eq 0 ] # self-test は既存 catch を持つので死なない（対照）
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" selfTestBaseline.error)" = "true" ]

  # 既存 catch を持つ review 段の非 cap throw は従来どおり reviewFailed へ（cap には計上しない）。
  local mut="$BATS_TEST_TMPDIR/nc"
  mkdir -p "$mut/tests"
  cp "$DRIVER" "$mut/tests/driver.mjs"
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_RO_NOTFOUND=false CQ_REVIEW_FINDINGS='[{"title":"test","severity":"critical","location":"test","rationale":"test"}]' \
      node "$DRIVER" run
  [ "$status" -eq 0 ]
  # degenerate（placeholder）は cap ではない → capExceeded=false のまま schemaHealth 側で捕まる。
  [ "$(kval "$output" capExceeded)" = "false" ]
  [[ "$output" == *'"degenerate":['* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# [E] K1c: 決定論（共有カウンタ先着順にしていない）
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c K1c: stage1 の解決順を入れ替えても admit 集合が同一（観点別固定枠＝先着順でない）" {
  local normal reverse
  run env CQ_ARGS="$(cq_args '{"totalBudget":12,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  normal="$(kval "$output" verifyLabels)"
  [ -n "$normal" ]

  run env CQ_ARGS="$(cq_args '{"totalBudget":12,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false CQ_REVIEW_ORDER=reverse node "$DRIVER" run
  [ "$status" -eq 0 ]
  reverse="$(kval "$output" verifyLabels)"

  [ "$normal" = "$reverse" ]
  # 各観点が同じ本数を得ている（先着順なら早い観点が枠を食い潰して偏る）。
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=1,correctness=1,integration-ops=1,robustness-security=1" ]
  # 残した 1 件は severity 最上位（critical AAA）＝決定論 tie-break の証跡。
  grep -q 'AAA' <<< "$normal"
  ! grep -q 'BBB' <<< "$normal"
}

# ─────────────────────────────────────────────────────────────────────────────
# [F] K2' 後方互換
#   【保証面の明示】K2' が保証するのは **agent 呼出し列（callSeq）** と「cap 表面が既定 OFF」であって、
#   終端状態（converged/escalate/gatePrefix）の完全一致ではない。cap 指紋を持つ例外を捕捉した run は
#   cap 未指定でも fail-closed 側（converged=false・blocking 級 drop があれば escalate）へ倒れる＝意図した
#   非互換。その差分は [H] の "terminal 非互換の明示 pin" tooth が base 木対照で固定する。
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c K2': cap 未指定時の agent 呼出し列が base 木（cap 実装前の固定 SHA）と完全一致する" {
  # golden を literal で焼かず、base 木の WF を driver で実走して生成する（＝現物対現物の比較）。
  # base の指し先は setup() の CAP_BASE_REF（不変 SHA）= 可動 ref を使わない理由は setup() のコメント参照
  # （land 後に base==HEAD となりこの比較が自己比較＝vacuous pass に化けるため）。
  local base="$BATS_TEST_TMPDIR/base"
  materialize_base_tree "$base"

  local scenario base_seq head_seq
  # 代表シナリオを複数（clean 収束 / confirmed 有り autoFix / single モード）走らせて列を突き合わせる。
  for scenario in 'clean' 'autofix' 'single'; do
    echo "# scenario: $scenario"
    local a findings refuted
    case "$scenario" in
      clean)   a="$(cq_args '{}')"; findings='[]'; refuted=true ;;
      autofix) a="$(cq_args '{}')"; findings="$FINDINGS_MIX"; refuted=false ;;
      single)  a='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n","taskType":"testable"}'; findings="$FINDINGS_MIX"; refuted=true ;;
    esac
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$findings" CQ_VERIFY_REFUTED="$refuted" node "$base/tests/driver.mjs" run
    [ "$status" -eq 0 ]
    base_seq="$(kval "$output" callSeq)"
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$findings" CQ_VERIFY_REFUTED="$refuted" node "$DRIVER" run
    [ "$status" -eq 0 ]
    head_seq="$(kval "$output" callSeq)"
    [ -n "$base_seq" ]
    [ "$base_seq" = "$head_seq" ]
    # cap の表面は既定 OFF（数値既定を変えていない）。
    [ "$(kval "$output" capExceeded)" = "false" ]
    [ "$(kval "$output" capLimit)" -eq 0 ]
    [ "$(kval "$output" gateHasCapNote)" = "false" ]
  done
}

@test "sc-k33c K2': cap 未指定なら minor/nit を含む全 finding が verify される（D3 縮退を既定へ持ち込まない）" {
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 4 観点 × 3 finding = 12 本すべて verify されている（minor BBB も落ちない）。
  [ "$(kval "$output" verifyCallCount)" -eq 12 ]
  grep -q 'BBB' <<< "$(kval "$output" verifyLabels)"
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [G] 変異注入 8 種（正方向 tooth の非空虚性）
#   mutant_fingerprint（いずれも BATS_TEST_TMPDIR の copy 木へ sed で注入）:
#     MU1 classify  : `.catch(capCatch('classify', null))`                     → 削除
#     MU2 plan      : `.catch(capCatch('plan', null))`                         → 削除
#     MU3 implement : `.catch(capCatch('implement', null))`                    → 削除
#     MU4 snapshot  : `.catch(capCatch(\`snapshot r${round}\`, null))`         → 削除
#     MU5 fix       : `.catch(capCatch(\`autofix r${round}\`, null))`          → 削除
#     MU6 pipeline  : `perDim = capCatch('pipeline', ...)` の catch 節         → 再 throw 化
#     MU7 review    : `capReclassify(\`review:${d.key}\`, ...)`（K1b(i)）      → 素の catch へ戻す
#     MU8 parallel  : stage2 の `if (!capClassify(e)) throw e`（K1b(ii)）      → 無条件 throw 化
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c MU1: classify の cap catch を外すと run が result を返さず死ぬ" {
  local mut="$BATS_TEST_TMPDIR/mu1"
  plant_cap_mutant "$mut" "\.catch(capCatch('classify', null))" ""
  run env CQ_ARGS='{"taskTitle":"c","worktree":"/tmp/wt","goal":"g","selfTestCmd":"true","autoFix":true}' \
      CQ_THROW_AT_LABEL='classify' node "$mut/tests/driver.mjs" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
}

@test "sc-k33c MU2: plan の cap catch を外すと run が result を返さず死ぬ" {
  local mut="$BATS_TEST_TMPDIR/mu2"
  plant_cap_mutant "$mut" "\.catch(capCatch('plan', null))" ""
  run env CQ_ARGS="$(cq_args '{"doPlan":true}')" CQ_THROW_AT_LABEL='plan' node "$mut/tests/driver.mjs" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
}

@test "sc-k33c MU3: implement の cap catch を外すと run が result を返さず死ぬ" {
  local mut="$BATS_TEST_TMPDIR/mu3"
  plant_cap_mutant "$mut" "\.catch(capCatch('implement', null))" ""
  run env CQ_ARGS="$(cq_args '{"doImplement":true}')" CQ_THROW_AT_LABEL='implement' node "$mut/tests/driver.mjs" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
}

@test "sc-k33c MU4: snapshot の cap catch を外すと run が result を返さず死ぬ" {
  local mut="$BATS_TEST_TMPDIR/mu4"
  plant_cap_mutant "$mut" "\.catch(capCatch(\`snapshot r\${round}\`, null))" ""
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' node "$mut/tests/driver.mjs" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
}

@test "sc-k33c MU5: fix の cap catch を外すと run が result を返さず死ぬ" {
  local mut="$BATS_TEST_TMPDIR/mu5"
  plant_cap_mutant "$mut" "\.catch(capCatch(\`autofix r\${round}\`, null))" ""
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false \
      CQ_THROW_AT_LABEL='autofix' node "$mut/tests/driver.mjs" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
}

@test "sc-k33c MU6: pipeline 入口の cap catch を再 throw 化すると run が死ぬ" {
  local mut="$BATS_TEST_TMPDIR/mu6"
  plant_cap_mutant "$mut" "perDim = capCatch('pipeline'" "throw e; perDim = capCatch('pipeline'"
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_STAGE=pipeline node "$mut/tests/driver.mjs" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
}

@test "sc-k33c MU7 (K1b(i)): review 既存 catch の cap 再分類を外すと cap が machinery 失敗に化ける" {
  local mut="$BATS_TEST_TMPDIR/mu7"
  plant_cap_mutant "$mut" "capReclassify(\`review:\${d.key}\`, () => ({ findings: \[\], __reviewFailed: true }))" \
      "() => ({ findings: [], __reviewFailed: true })"
  # 変異前: cap 例外は capExceeded/reason=quota として別勘定になる。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_THROW_AT_LABEL='review:' CQ_THROW_KIND=quota node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "quota" ]
  # 変異後: cap が観測されず（capExceeded=false）machinery 失敗としてのみ現れる＝別勘定が消える。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_THROW_AT_LABEL='review:' CQ_THROW_KIND=quota node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" gateHasCapNote)" = "false" ]
}

@test "sc-k33c MU8 (K1b(ii)): parallel 入口の cap 判定を無条件 throw 化すると reviewFailed へ誤帰属する" {
  local mut="$BATS_TEST_TMPDIR/mu8"
  plant_cap_mutant "$mut" "if (!capClassify(e)) throw e // 非 cap" "throw e // 変異: 無条件 throw // 非 cap"
  # 変異前: reviewFailed は 0（誤帰属しない）。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_THROW_AT_STAGE=parallel node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).history.map(x=>x.reviewFailed).join(","))' "$output")" = "0" ]
  # 変異後: pipeline が要素を null 化し、観点数分の reviewFailed が立つ（＝誤帰属が復活する）。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_THROW_AT_STAGE=parallel node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);console.log(JSON.parse(m[1]).history.map(x=>x.reviewFailed).join(","))' "$output")" = "4" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H] self-review errata（confirmed blocking の恒久回帰 tooth）
#   mutant_fingerprint 追加分:
#     MU9  capCatch fail-closed : `if (!reason) throw e`                        → `if (false) throw e`
#     MU10 review 前 admission  : `if (__capReviewAdmitted < dimensions.length) {` → `if (false) {`
#     MU11 verify 二重計上防止  : `{ alreadySurfaced: true }`                    → `{}`
#     MU12 縮退順の限定条件     : `blockingOnly.length > 0 && `                  → 削除
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c B4: self-test 段の cap 例外は converged/escalate を一切駆動しない（情報ログ専用）" {
  # 【回帰の中身】runSelfTest の catch を capReclassify へ差し替えた際、self-test runner agent が投げた cap 系
  # 例外が capExceeded=true + severity='unknown' の capDropped を積み、terminal で converged=false /
  # escalate=true を強制していた。WF 自身が runSelfTest 冒頭と final 呼出しで「返り値は情報ログ専用で
  # converged/escalate を一切駆動しない(B4)」と明記しており、この不変条件が破れていた。
  # (a) 完全 clean な loop run の selftest:final で投げても converged は反転しない。
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      CQ_THROW_AT_LABEL='selftest:final' CQ_THROW_KIND=quota node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
  # terminal を駆動しないだけで **可視化は残る**（silent に握り潰していない＝この tooth が空虚でない証拠）。
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" capSelfTestExceptions)" -eq 1 ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" gateHasCapNote)" = "false" ]

  # (b) selftest:baseline で投げても capRoundGate を駆動しない＝review を 1 本も落とさず round loop が回る。
  # （回帰時は capReason='quota' が立ち round 1 の頭で打ち切られて callSeq が selftest 2 本だけに縮退した。）
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      CQ_THROW_AT_LABEL='selftest:baseline' CQ_THROW_KIND=quota node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" reviewCallCount)" -gt 0 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" capSelfTestExceptions)" -eq 1 ]
}

@test "sc-k33c terminal: totalBudget で round を打ち切った未収束 loop run は escalate する（fail-open 封鎖）" {
  # 【回帰の中身】capRoundGate は残量不足時に capStages へ 1 行積むだけで capDrop を呼ばず、さらに round-- で
  # post-loop の `round >= effectiveCap` も外していた。結果 rounds=1・confirmed blocking 修正済み・未収束の
  # loop run が converged=false かつ escalate=false（gate=OPEN）という base に存在しない終端状態へ落ちていた。
  local tb out
  for tb in 12 13 20; do
    echo "# totalBudget=$tb"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$tb}")" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
        CQ_VERIFY_REFUTED=false node "$DRIVER" run
    [ "$status" -eq 0 ]
    out="$output"
    [ "$(kval "$out" converged)" = "false" ]
    [ "$(kval "$out" escalate)" = "true" ]
    [ "$(kval "$out" gatePrefix)" = "ESCALATE" ]
    # 落とした round は capDropped[] に載る（gate 文が「capDropped を直読せよ」と促すのに空、という自己矛盾を封鎖）。
    [ "$(kval "$out" capDroppedCount)" -gt 0 ]
    [ "$(kval "$out" capDroppedAgents)" -gt 0 ]
    [ "$(kval "$out" capDroppedBlocking)" -gt 0 ]
    grep -q 'round-gate' <<< "$(kval "$out" capDroppedReasons)"
    # ESCALATE_REASON が空でない（呼出元/gate 機械が鍵にする面が立っている）。
    [[ "$out" == *'ESCALATE_REASON cap 由来の早期打切り'* ]] || [[ "$out" == *'ESCALATE_REASON hard cap'* ]] || \
      [[ "$out" == *'ESCALATE_REASON cap 発火'* ]]
  done
}

@test "sc-k33c K8 fence: 必須4観点は totalBudget で縮められない（all-or-nothing・dimensions 削減不採用）" {
  # 【回帰の中身】review 前 admission が dimensions.slice(0, admitted) で配列末尾から観点を切り捨てていた。
  # 配列順は「必須4 → worker が --add-dimension で明示指定した追加観点」ゆえ、予算逼迫時に最初に消えるのは
  # ユーザー意図の追加観点と completeness-critic であり、un-mpv/un-aq5 で撤廃済みの slice 切り詰めの復活
  # かつ「admin gate は必須4観点固定」(D3/D4) を args 供給の totalBudget が縮める経路だった。
  local n rc
  for n in 5 6 7 8; do
    echo "# totalBudget=$n"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
        CQ_VERIFY_REFUTED=false node "$DRIVER" run
    [ "$status" -eq 0 ]
    rc="$(kval "$output" reviewCallCount)"
    # round あたり 4 観点。走るなら 4 の倍数（＝部分実行が無い）。1〜3 本だけ走る regime は存在してはならない。
    [ $(( rc % 4 )) -eq 0 ]
    # 観点を落とすときは round 丸ごと（capDropped に全 4 観点が列挙される）。
    if [ "$rc" -eq 0 ]; then
      local titles
      titles="$(kval "$output" capDroppedTitles)"
      grep -q 'correctness' <<< "$titles"
      grep -q 'robustness-security' <<< "$titles"
      grep -q 'integration-ops' <<< "$titles"
      grep -q 'completeness-critic' <<< "$titles"
      [ "$(kval "$output" capExceeded)" = "true" ]
      [ "$(kval "$output" escalate)" = "true" ]
    fi
  done
}

@test "sc-k33c MU10: review 前 admission（層2-②）をバイパスすると totalBudget を破る" {
  # 非空虚性: 層2-② を無効化した木は totalBudget=6 に対し agent 7 本走る（cap 破り）。
  local mut="$BATS_TEST_TMPDIR/mu10"
  plant_cap_mutant "$mut" "if (__capReviewAdmitted < dimensions.length) {" "if (false) {"
  local a="$(cq_args '{"totalBudget":6}')"
  local f='[{"title":"AAA","severity":"critical","location":"a.js:1","rationale":"b"}]'
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$f" CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" agentCallTotal)" -le 6 ]
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$f" CQ_VERIFY_REFUTED=false node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" agentCallTotal)" -gt 6 ]
}

@test "sc-k33c K1b(iii) behavioral: 非 cap 例外は capCatch が再 throw して run が死ぬ（fail-closed）" {
  # 【回帰の中身】K1b(iii) を名乗る既存 tooth は capReclassify 経路と degenerate placeholder しか駆動しておらず、
  # capCatch を **非 cap 例外** で通す経路を一度も踏んでいなかった（driver にも非 cap throw の knob が無く、
  # CQ_THROW_KIND の 'quota'/'error' はどちらも cap 指紋を持つ）。CQ_THROW_KIND=plain で 6 call site を個別に狙う。
  local label
  for label in 'snapshot' 'autofix' 'plan' 'implement'; do
    echo "# non-cap throw at: $label"
    local a
    case "$label" in
      plan)      a="$(cq_args '{"doPlan":true}')" ;;
      implement) a="$(cq_args '{"doImplement":true}')" ;;
      *)         a="$(cq_args '{}')" ;;
    esac
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false \
        CQ_THROW_AT_LABEL="$label" CQ_THROW_KIND=plain node "$DRIVER" run
    [ "$status" -ne 0 ]
    [[ "$output" == *'DRIVER_ERROR'* ]]
  done
  # classify（taskType を渡さない形）も同じ。
  run env CQ_ARGS='{"taskTitle":"c","worktree":"/tmp/wt","goal":"g","selfTestCmd":"true","autoFix":true}' \
      CQ_THROW_AT_LABEL='classify' CQ_THROW_KIND=plain node "$DRIVER" run
  [ "$status" -ne 0 ]
  [[ "$output" == *'DRIVER_ERROR'* ]]
  # 対照（非空虚性）: 同じ label でも cap 指紋付きなら run は死なず result を返す。
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' CQ_THROW_KIND=quota node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
}

@test "sc-k33c MU9: capCatch の fail-closed 再 throw を無効化すると非 cap 例外を飲み込む" {
  local mut="$BATS_TEST_TMPDIR/mu9"
  plant_cap_mutant "$mut" "if (!reason) throw e" "if (false) throw e"
  # 変異前: 非 cap 例外は再 throw され run が死ぬ。
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' CQ_THROW_KIND=plain node "$DRIVER" run
  [ "$status" -ne 0 ]
  # 変異後: 6 call site が非 cap 例外まで飲み込み run が生き残る（＝完全 fail-open 退行）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' CQ_THROW_KIND=plain node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
}

@test "sc-k33c K2'(例外経路): cap 未指定なら cap 系例外が起きても呼出し列が base 木と完全一致する" {
  # 【回帰の中身】層3 の quota/error 早期打ち切りが `if (!CAP_ON) return true` より **前** に在り、cap を一切
  # 頼んでいない run でも発火していた。指紋は 'token budget' 等の汎用部分文字列一致ゆえ、誤分類された一過性の
  # machinery 失敗 1 件で既定構成の run から round 2-3 の adversarial review が丸ごと消える単一障害点だった
  # （実測: base=rounds 3/agent 17 本 に対し HEAD=rounds 1/agent 7 本）。K2' の既存 tooth は throw の無い
  # 3 シナリオしか比較しておらず、この差分を 1 本も pin していなかった。
  # 【この tooth の保証面は callSeq のみ】終端状態（converged/escalate/gatePrefix）は cap 指紋例外を捕捉した
  # 時点で fail-closed 側へ倒れる＝base と一致しない（意図した非互換）。終端の差分は次の
  # "terminal 非互換の明示 pin" tooth が base 木対照で固定する。
  # base の指し先は setup() の CAP_BASE_REF（不変 SHA）＝可動 ref だと land 後に自己比較で空虚化する。
  local base="$BATS_TEST_TMPDIR/base-exc"
  materialize_base_tree "$base"

  local kind label base_seq head_seq
  for kind in quota error; do
    for label in 'review:' 'verify:'; do
      echo "# kind=$kind label=$label"
      run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false \
          CQ_THROW_AT_LABEL="$label" CQ_THROW_KIND="$kind" node "$base/tests/driver.mjs" run
      [ "$status" -eq 0 ]
      base_seq="$(kval "$output" callSeq)"
      run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false \
          CQ_THROW_AT_LABEL="$label" CQ_THROW_KIND="$kind" node "$DRIVER" run
      [ "$status" -eq 0 ]
      head_seq="$(kval "$output" callSeq)"
      [ -n "$base_seq" ]
      [ "$base_seq" = "$head_seq" ]
    done
  done
}

@test "sc-k33c K2'(terminal 非互換の明示 pin): cap 未指定でも cap 指紋例外は終端を fail-closed 側へ倒す（base=CONVERGED / HEAD=OPEN）" {
  # 【なぜ要るか】cap.bats header と capRoundGate errata コメントが表明していた「cap 未指定＝完全な後方互換」
  # 「cap を頼んでいない run の制御フローは例外経路でも 1 mm も変えない」は、**終端状態については偽**である
  # （callSeq は一致するが converged/gatePrefix は変わる）。既存 K2'(例外経路) tooth は callSeq 文字列しか
  # 比較せず、K1a reason='quota' tooth は label='review:' ゆえ base 側も reviewFailed で非収束＝base/HEAD を
  # 弁別しない。結果、未検証の claim が diff 内に残り、将来この分岐が fail-open 側へ倒れても suite が沈黙した。
  # → base=CONVERGED になる唯一の形（cap 未指定・minor のみ・refuted=true・verify: の quota 例外）で
  #   base 木と HEAD の終端を **両方読み**、意図した非互換を記録として固定する。
  # 【固定する意図】(a) capExceeded の run は converged を立てない（見ていない finding が在るので clean を
  #   主張しない）。(b) しかし escalate は立てない — verify agent は実際に起動しており当該 finding は
  #   unverified[] に一次面を持つので、capDropped[] へ二重計上して blocking 級 drop を捏造しない
  #   （K3-3 の別枠 + K1 項目5「blocking 級を落とした時のみ escalate」= escalate の安売り防止）。
  # 【回帰の中身】この tooth を書いた時点の HEAD は (b) を破っており、capRecordException が call site の既知
  #   severity を使わず一律 'unknown' を焼いて droppedBlocking=8 → ESCALATE を強制していた（実測）。
  # 【base の指し先】setup() の CAP_BASE_REF（cap 実装前の凍結 SHA）。可動 ref（origin/main）を使うと本 diff が
  # land した瞬間に base 側も cap 入りになり base=OPEN → この tooth が **決定論的に RED** へ反転する
  # （merge 前の gate では原理的に検出できない booby trap）。ゆえにこの pin は更新しない。
  local base="$BATS_TEST_TMPDIR/base-term"
  materialize_base_tree "$base"

  local a f base_seq base_total
  a="$(cq_args '{}')" # totalBudget 未指定＝実運用 100% の既定路
  f='[{"title":"MMM","severity":"minor","location":"m.js:1","rationale":"naming"}]'

  # base 木: cap 機構が無いので verify 例外は unverified に載るだけ＝CONVERGED（対照の非空虚性）。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$f" CQ_VERIFY_REFUTED=true \
      CQ_THROW_AT_LABEL='verify:' CQ_THROW_KIND=quota node "$base/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
  base_seq="$(kval "$output" callSeq)"
  base_total="$(kval "$output" agentCallTotal)"
  [ -n "$base_seq" ]

  # HEAD: 同一 args・同一 stub で終端だけが fail-closed 側（OPEN）へ倒れる。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$f" CQ_VERIFY_REFUTED=true \
      CQ_THROW_AT_LABEL='verify:' CQ_THROW_KIND=quota node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "quota" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "false" ]   # ← blocking 級 drop は無い＝escalate を安売りしない
  [ "$(kval "$output" gatePrefix)" = "OPEN" ]
  # 二重計上していない: 同じ finding は unverified に載り、capDropped[] へは積まれない（K3-3）。
  [ "$(kval "$output" unverifiedCount)" -gt 0 ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" capDroppedBlocking)" -eq 0 ]
  # 非互換は **terminal のみ**に閉じている（K2' の保証面＝呼出し列は base と完全一致のまま）。
  [ "$(kval "$output" callSeq)" = "$base_seq" ]
  [ "$(kval "$output" agentCallTotal)" -eq "$base_total" ]
  # silent に倒していない: gate 文へ cap 注記が載る（人手が capReport を直読できる）。
  [ "$(kval "$output" gateHasCapNote)" = "true" ]
}

@test "sc-k33c MU11: verify 段の alreadySurfaced を外すと二重計上が復活し既定路が ESCALATE 化する" {
  # 非空虚性: 上の terminal pin が「元から OPEN」で受かっていないことを示す。opts を空にした変異木では
  # capRecordException が severity='unknown' の capDrop を焼き、同一 finding が unverified と capDropped の
  # 両面に載って droppedBlocking>0 → escalate 強制（cap を一切頼んでいない run が ESCALATE 化する）。
  local mut="$BATS_TEST_TMPDIR/mu11"
  plant_cap_mutant "$mut" "{ alreadySurfaced: true }" "{}"
  local a f
  a="$(cq_args '{}')"
  f='[{"title":"MMM","severity":"minor","location":"m.js:1","rationale":"naming"}]'
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$f" CQ_VERIFY_REFUTED=true \
      CQ_THROW_AT_LABEL='verify:' CQ_THROW_KIND=quota node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]
  [ "$(kval "$output" capDroppedBlocking)" -gt 0 ]
  # 二重計上の証跡: unverified と capDropped の件数が同時に立つ（変異前は capDropped=0）。
  [ "$(kval "$output" unverifiedCount)" -gt 0 ]
  [ "$(kval "$output" capDroppedCount)" -gt 0 ]
}

@test "sc-k33c K1a: spentEstimate が実 agent 呼出し総数と一致する（cap on/off とも）" {
  # 【回帰の中身】capAdmit が CAP_ON=false のとき capSpent へ加算せず want を返していたため、review（既定
  # 4 本/round）と fix（1 本/round）が spentEstimate から丸ごと欠落していた。fail-loud 表面は既定 ON ゆえ、
  # cap を使わない全 run（admin gate・worker 自己点検の実運用 100%）で監査値が系統的に過小になり、
  # totalBudget の実運用値を決める calibration（M0）と下流 sc-46kv の「WF 消費値札の bd 記録」を誤らせる。
  local scenario args findings refuted
  # cap 未指定（既定路・実運用形）/ cap 指定 / minor のみ / single モード。
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]
  # 非空虚: この run は review/fix を実際に含む（＝欠落していれば必ず不一致になる規模）。
  [ "$(kval "$output" reviewCallCount)" -gt 0 ]
  [ "$(kval "$output" agentCallTotal)" -gt 10 ]

  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]

  run env CQ_ARGS="$(cq_args '{"totalBudget":16}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]

  run env CQ_ARGS='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x","taskType":"testable"}' \
      CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]
}

@test "sc-k33c K1 層2-④: fix 用 1 本は reserveFix が常に確保する（fix 前 admission は防御的 guard）" {
  # 層2-④（fix 前 admission）は capVerifyQuotaPerDim が reserveFix=1 を先に差し引いてから floor 分配するため
  # 通常は到達しない dead branch。K1 の 4 点目の実効保証は **reserve 側** が担う＝teeth をそこに置く。
  # static: reserve が quota 計算から差し引かれている（この 1 行が消えると fix が予算に食われる）。
  run grep -F -q -- 'const reserveFix = canAutoFix ? 1 : 0' "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- '- CAP_EXEMPT_RESERVE - reserveFix' "$WF"
  [ "$status" -eq 0 ]
  # behavioral: confirmed blocking が立つ小〜中予算を掃引しても autoFix は必ず 1 本起動し、
  # 「予算不足で autoFix を起動できない」ログは 1 度も出ない（＝reserve が効いている）。
  local n out seq
  for n in 12 13 14 16 20; do
    echo "# totalBudget=$n"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" \
        CQ_REVIEW_FINDINGS='[{"title":"AAA","severity":"critical","location":"a.js:1","rationale":"b"}]' \
        CQ_VERIFY_REFUTED=false node "$DRIVER" run
    [ "$status" -eq 0 ]
    out="$output"
    [[ "$out" != *'予算不足で autoFix を起動できない'* ]]
    seq="$(kval "$out" callSeq)"
    grep -q 'autofix' <<< "$seq"
    # 総数は cap を守ったまま（reserve は cap 破りの言い訳にならない）。
    [ "$(kval "$out" agentCallTotal)" -le "$n" ]
  done
}

@test "sc-k33c K1 縮退順: 非 blocking のみの round では『critical/major 限定』段を適用しない（枠が余っているのに 0 本 verify しない）" {
  # 【回帰の中身】縮退順の「verify を critical/major に限定」段は `blockingOnly.length > 0 &&` を適用条件に
  # 持つ（WF 自身のコメントが「blocking が 1 件も無い round で限定すると admit=0 になり『枠が余っているのに
  # 何も verify しない』退行」と名指しで警告している）。ところが既存 tooth の totalBudget 経路は FINDINGS_MIX
  # （critical/major を必ず含む）でしか駆動されておらず、**非 blocking のみの round × 予算 quota** という
  # modality が丸ごと欠けていた（FINDINGS_MINOR を使う既存 tooth は perRoundVerifyTopK 経路でこの分岐を
  # 通らない）＝この適用条件を消す変異が 42 tooth 全緑を通過した（実測）。
  local pair n want out
  # 非 blocking 3 件 × 予算 quota で縮退が発火する域（12→各観点 1 本 / 16→各観点 2 本 = min(quota, 対象数)）。
  for pair in '12:1' '16:2'; do
    n="${pair%%:*}"
    want="${pair##*:}"
    echo "# totalBudget=$n (期待: 各観点 $want 本)"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" CQ_REVIEW_FINDINGS="$FINDINGS_NONBLOCKING" \
        CQ_VERIFY_REFUTED=true node "$DRIVER" run
    [ "$status" -eq 0 ]
    out="$output"
    # 全観点が非ゼロ（＝「枠が余っているのに 1 本も verify しない」に落ちていない）。
    [ "$(kval "$out" verifyByDim)" = "completeness-critic=$want,correctness=$want,integration-ops=$want,robustness-security=$want" ]
    [ "$(kval "$out" verifyCallCount)" -gt 0 ]
    # 縮退は severity top-K 段だけで起きる。blocking が 0 件の round で 'severity-limited' が立ったら、
    # 「critical/major 限定」を無条件適用した＝admit が空になる退行そのもの。
    grep -q 'severity-topk' <<< "$(kval "$out" capDroppedReasons)"
    ! grep -q 'severity-limited' <<< "$(kval "$out" capDroppedReasons)"
    # 予算は守ったまま（この tooth が cap 破りで受かっていない）。
    [ "$(kval "$out" agentCallTotal)" -le "$n" ]
  done
}

@test "sc-k33c MU12: 縮退順の『blocking が在るときだけ限定する』条件を外すと非 blocking round の verify が全滅する" {
  # 非空虚性: 上の正方向 tooth が「元から全観点非ゼロ」で受かっていないことを示す（MU12 ↔ 正方向 1:1）。
  local mut="$BATS_TEST_TMPDIR/mu12"
  plant_cap_mutant "$mut" "blockingOnly.length > 0 && " ""
  local n
  for n in 12 16; do
    echo "# MU12 totalBudget=$n"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" CQ_REVIEW_FINDINGS="$FINDINGS_NONBLOCKING" \
        CQ_VERIFY_REFUTED=true node "$mut/tests/driver.mjs" run
    [ "$status" -eq 0 ]
    # 変異後: 非 blocking のみの round で admit=0 へ落ち、verify が 1 本も走らない（幅の制御の暴走）。
    [ "$(kval "$output" verifyByDim)" = "" ]
    [ "$(kval "$output" verifyCallCount)" -eq 0 ]
    grep -q 'severity-limited' <<< "$(kval "$output" capDroppedReasons)"
  done
}

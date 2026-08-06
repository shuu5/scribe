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
#   [F] 後方互換（K2'v2・sc-spp1 再契約: 既定 tail-K の不発域〔尾(minor/nit) ≤ K〕で agent 呼出し列が
#       base 木と完全一致・minor/nit も全部 verify される。発火域の挙動は [B'] が pin する）
#   [B'] sc-spp1 既定有限化 — perRoundVerifyTopK 未指定 = K=4・尾(minor/nit)のみ・critical/major は floor
#       （T1/T2 正方向 + MU-T1/MU-T2 非空虚性）
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
  # (sc-spp1) 尾(minor/nit)が既定 K=4 を超える集合＝既定有限化の発火域を駆動する: floor 1(MAJ) + 尾 5(m1..m4,NIT)。
  FINDINGS_TAILY='[{"title":"MAJ","severity":"major","location":"j.js:1","rationale":"fail-open"},{"title":"m1","severity":"minor","location":"t.js:1","rationale":"naming"},{"title":"m2","severity":"minor","location":"t.js:2","rationale":"naming"},{"title":"m3","severity":"minor","location":"t.js:3","rationale":"naming"},{"title":"m4","severity":"minor","location":"t.js:4","rationale":"naming"},{"title":"NIT","severity":"nit","location":"t.js:5","rationale":"spacing"}]'
  # (sc-spp1) blocking 集中形＝floor の観測用: major 3 が K=1 を超えても major は 1 本も落ちないこと。
  FINDINGS_MAJHEAVY='[{"title":"MJ1","severity":"major","location":"h.js:1","rationale":"r"},{"title":"MJ2","severity":"major","location":"h.js:2","rationale":"r"},{"title":"MJ3","severity":"major","location":"h.js:3","rationale":"r"},{"title":"mm1","severity":"minor","location":"h.js:4","rationale":"r"},{"title":"mm2","severity":"minor","location":"h.js:5","rationale":"r"}]'

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
  # 【契約 literal からの意図的逸脱・admin ratify 済み】契約 K2' は `git show origin/main:...` と literal で
  # 書いているが、上記 (a)(b) のとおり可動 ref では land 後に guard が自己破壊するため、同じ木を指す不変 SHA
  # へ固定した（＝逸脱は「base 木から driver 実走で生成する」という K2' の目的を守るためのもの）。
  # SHA は短縮形でなく 40 桁で持つ（短縮は将来の衝突・曖昧解決に晒される＝pin の意味が弱まる）。
  CAP_BASE_REF="${SC_K33C_BASE_REF:-46958e5d4e08b760c0960c52eb3cd4f4f3099be7}"
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

# (sc-spp1) capReport の field を RESULT JSON から直読する。driver へ新 K 行を足すと loop.bats L-C1
# （knob 導入前 driver との byte 一致対照）を割るため、sc-spp1 の新規観測軸（tailTopK 等）は driver を
# 変えずこの経路で取る。
crval() {
  local out="$1" key="$2"
  node -e 'const m=process.argv[1].match(/RESULT (.*)$/m);const v=JSON.parse(m[1]).capReport[process.argv[2]];console.log(v===undefined?"<absent>":String(v))' "$out" "$key"
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
  # message 側の指紋。★**未実測の保守的な列挙**であり、この tooth が検知できるのは自リポ内 literal の改変
  # だけ（実機文言との突合はしていない＝実機 drift は検知できない）。実機指紋の確定は follow-up 側の仕事。
  # （ERRATA-01 B2）語境界一致（\b…\b）へ絞ったので、pin も正規表現 literal の形で見る。
  local fp
  for fp in 'budget exceeded' 'token budget' 'agent cap' 'agent limit' 'exceeded the agent'; do
    echo "# fingerprint: $fp"
    run grep -F -q -- "{ re: /\\b$fp\\b/" "$WF"
    [ "$status" -eq 0 ]
  done
  # 素の substring 一致（旧形）へ戻す退行を静的にも塞ぐ。
  run grep -F -q -- 'msg.includes(fp.pat)' "$WF"
  [ "$status" -ne 0 ]
  run grep -F -q -- 'fp.re.test(msg)' "$WF"
  [ "$status" -eq 0 ]
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
    # (ERRATA-01 B3) 縮退が実際に起きているこの予算域で **spentEstimate == 実呼出し総数** も押さえる。
    # ★ `capSpentEstimate -eq $n`（= totalBudget）形は誤り: 縮退で早く打ち切った run では
    #   spentEstimate < totalBudget が正常（HEAD 実測で tb=5/6/8 が該当）。正は実呼出し数との一致。
    [ "$(kval "$out" capSpentEstimate)" -eq "$total" ]
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

@test "sc-k33c K3-2 (sc-spp1 v2): perRoundVerifyTopK=K は尾(minor/nit)にのみ効き、観点別 verify 数が floor + min(K, 尾数) になる" {
  # 観点(dimension)単位 top-K（共有カウンタ先着順ではない）。sc-spp1 severity ゲート: K が切るのは尾(minor/nit)
  # だけで、critical/major は floor(全数 verify)。TAILY = floor 1(MAJ) + 尾 5(m1..m4,NIT)。
  # K=2 → 各観点 1+2=3 本・尾の下位 3 件(m3/m4/NIT)が落ちる。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":2,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=3,correctness=3,integration-ops=3,robustness-security=3" ]
  [ "$(kval "$output" verifyCallCount)" -eq 12 ]
  # 落ちるのは尾の severity 最下位側（minor m3/m4 と nit NIT）＝決定論 tie-break の証跡。floor(MAJ)は落ちない。
  [ "$(kval "$output" capDroppedTitles)" = "NIT;NIT;NIT;NIT;m3;m3;m3;m3;m4;m4;m4;m4" ]
  [ "$(kval "$output" capDroppedReasons)" = "perRoundVerifyTopK" ]
  [ "$(kval "$output" capDroppedBlocking)" -eq 0 ]

  # K ≥ 尾数 なら 1 件も落とさない（cap は発火しない）＝明示大 K が「無 cap 相当」の opt-out 経路（sc-spp1）。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":9,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=6,correctness=6,integration-ops=6,robustness-security=6" ]
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(crval "$output" tailTopKDefaulted)" = "false" ]
}

@test "sc-k33c K3-3: 縮退分は capDropped[] に列挙され unverified と二重計上されない" {
  # topK で尾の下位（m3/m4/NIT）を落としつつ、残る MAJ/m1/m2 の verify agent は cap 例外で verdict:null
  # （＝unverified）にする。「verify を起動しなかった（capDropped）」と「verdict が取れなかった（unverified）」は
  # 別事象＝集合が交わらない。(sc-spp1 v2: fixture を TAILY 化＝K=2 は尾のみ切るため MIX では cut が起きない)
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":2,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_THROW_AT_STAGE=element-budget node "$DRIVER" run
  [ "$status" -eq 0 ]
  local dropped unverified
  dropped="$(kval "$output" capDroppedTitles)"
  unverified="$(kval "$output" unverifiedTitles)"
  # 落とした側には尾の下位（m3/m4/NIT）だけ、unverified 側には MAJ/m1/m2（起動したが verdict 不成立）。
  grep -q 'm3' <<< "$dropped"
  grep -q 'NIT' <<< "$dropped"
  [ "$unverified" = "MAJ;m1;m2" ]
  ! grep -q 'm3' <<< "$unverified"
  ! grep -q 'NIT' <<< "$unverified"
  # unverified の件数（4 観点 × 3 件）と capDropped の件数が独立に立っている。
  [ "$(kval "$output" unverifiedCount)" -eq 12 ]
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
  # (sc-spp1 v2) 既定 tail-K=4 が生きていても、本シナリオ群（MIX=尾 1/観点・空 findings）は不発域（尾 ≤ K）
  # ＝「落とさない run は並べ替えもしない」不変量により呼出し列は base 木と同一のまま。この tooth は
  # 不変量そのものを恒久 pin し続ける（発火域の挙動は [B'] sc-spp1 tooth 群が別途 pin）。
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

@test "sc-k33c K2'v2 (sc-spp1): 既定 tail-K の不発域（尾 ≤ K）では minor/nit を含む全 finding が verify される" {
  # 旧 pin「cap 未指定 = 無 cap（D3 縮退を既定へ持ち込まない）」は sc-spp1 で再契約: 未指定 = 既定 K=4
  # （尾のみ・severity ゲート）。MIX は尾 1 ≤ 4 の不発域ゆえ全 finding verify は維持される＝この tooth は
  # 「不発域では既定が挙動を変えない」ことを pin する（発火域は [B'] sc-spp1 T1 が pin）。
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  # 4 観点 × 3 finding = 12 本すべて verify されている（minor BBB も落ちない）。
  [ "$(kval "$output" verifyCallCount)" -eq 12 ]
  grep -q 'BBB' <<< "$(kval "$output" verifyLabels)"
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
  # 既定は「生きているが不発」＝実効 K=4・既定由来であることを表面で確認（既定が消えた退行と弁別する）。
  [ "$(crval "$output" tailTopK)" = "4" ]
  [ "$(crval "$output" tailTopKDefaulted)" = "true" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [B'] sc-spp1: perRoundVerifyTopK の既定有限化（severity ゲート付き尾 top-K）
#   契約: 未指定 = K=4（観点単位・尾(minor/nit)のみ）。critical/major/severity 不明 = floor（全数 verify）。
#   明示 0 は従来どおり fail-fast（[A] の層1 tooth が pin＝「K=0 を頼んだのに無制限で走る」fail-open 防止）。
#   無 cap 相当は「明示大 K」（K3-2 v2 第 2 分岐が pin）。数値既定(4)の根拠と再較正条件は bd sc-spp1 notes。
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-spp1 T1: 未指定でも尾 > 4 なら既定 K=4 が発火し、drop は尾のみ・escalate しない" {
  # maxRounds は既定のまま（1 に絞ると autoFix loop の hard cap escalate が立ち、cap 由来かどうかを
  # 弁別できなくなる＝上の terminal(b) tooth と同じ理由）。既定 loop は zeroStreak で 2 round 走る＝
  # 各観点 5 本/round × 2 round・NIT drop も round ごと（4 観点 × 2 round = 8 件）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  # floor 1(MAJ) + 尾 top-4(m1..m4) = 5 本/観点/round。NIT（尾の最下位）だけが落ちる。
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=10,correctness=10,integration-ops=10,robustness-security=10" ]
  [ "$(kval "$output" capDroppedTitles)" = "NIT;NIT;NIT;NIT;NIT;NIT;NIT;NIT" ]
  [ "$(kval "$output" capDroppedReasons)" = "perRoundVerifyTopK" ]
  [ "$(crval "$output" tailTopK)" = "4" ]
  [ "$(crval "$output" tailTopKDefaulted)" = "true" ]
  # 既定 cut は構造的に非 blocking のみ＝escalate を駆動しない（安売り防止が既定でも成立）。
  # converged は cap 発火ゆえ立てない（fail-loud 側＝「幅を落として走った run」を clean と混同させない。
  # 既定発火 run の終端が OPEN+capNote になるのは sc-spp1 裁定で意図した非互換＝bd notes に記録済み）。
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capDroppedBlocking)" -eq 0 ]
  [ "$(kval "$output" escalate)" = "false" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" gateHasCapNote)" = "true" ]
}

@test "sc-spp1 T2: major は K を超えて集中しても floor で全数 verify される（blocking 級は K で落ちない）" {
  # MAJHEAVY = major 3 + minor 2。K=1 → floor 3 + 尾 top-1(mm1) = 4 本/観点/round・落ちるのは mm2(minor)のみ。
  # 旧実装（severity 混在 top-K）なら K=1 で major 2 本が落ちて escalate していた＝W8-b 留意点(3)の罠の弁別点。
  # maxRounds は既定のまま（T1 と同じ理由＝hard cap escalate との弁別）。既定 loop は 2 round 走る。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MAJHEAVY" \
      CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=8,correctness=8,integration-ops=8,robustness-security=8" ]
  [ "$(kval "$output" capDroppedTitles)" = "mm2;mm2;mm2;mm2;mm2;mm2;mm2;mm2" ]
  [ "$(kval "$output" capDroppedBlocking)" -eq 0 ]
  [ "$(kval "$output" escalate)" = "false" ]
}

@test "sc-spp1 MU-T1: 既定値を 0 化する変異で既定 cut が死ぬ（T1 の非空虚性）" {
  local mut="$BATS_TEST_TMPDIR/mu-spp1a"
  plant_cap_mutant "$mut" "const CAP_TAIL_TOPK_DEFAULT = 4" "const CAP_TAIL_TOPK_DEFAULT = 0"
  run env CQ_ARGS="$(cq_args '{"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_VERIFY_REFUTED=true node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  # 変異後: 既定が死に旧 opt-in 挙動へ退行＝6 本すべて verify・drop なし（T1 が「元から不発」で受かっていない証拠）。
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=6,correctness=6,integration-ops=6,robustness-security=6" ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
}

@test "sc-spp1 MU-T2: 尾フィルタを外す変異で floor が死に blocking 級が K で落ちる（T2 の非空虚性）" {
  local mut="$BATS_TEST_TMPDIR/mu-spp1b"
  plant_cap_mutant "$mut" "const tail = admit.filter(capIsTail)" "const tail = admit"
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":1,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_MAJHEAVY" \
      CQ_VERIFY_REFUTED=true node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  # 変異後: severity 混在 top-K に退化し K=1 で major(MJ2/MJ3) が落ちる＝droppedBlocking が立つ。
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=1,correctness=1,integration-ops=1,robustness-security=1" ]
  [ "$(kval "$output" capDroppedBlocking)" -gt 0 ]
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
  # mutant_fingerprint（ERRATA-01 B5 で判定を capCatchSync へ移送したため変異点も移動した）:
  #   `return capCatchSync(\`verify-entry:${d.key}\`, ...)` の直前へ無条件 throw を挿入する。
  plant_cap_mutant "$mut" "return capCatchSync(\`verify-entry:" "throw e; return capCatchSync(\`verify-entry:"
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
  # (ERRATA-01 B1) 予約は「本数 × 実呼出しコスト」で引く形になった（RO fallback の 2 度目呼出しを予約へ含める）。
  run grep -F -q -- '(CAP_EXEMPT_RESERVE + reserveFix) * cost' "$WF"
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

# ─────────────────────────────────────────────────────────────────────────────
# [H] gate errata（自己点検 WF の指摘反映・sc-k33c）
#   H1 = K1c の決定論式が locale 非依存であること（旧: localeCompare + 恒真 0 の dead comparator）
#   H2 = K8「cap 判定コードは 1 ブロックに閉じ」に terminal 判定 / capReport 組立 / capNote 生成も含めること
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c H1 (K1c): tie-break が locale 非依存の code-unit 順で、dimension キー比較が dead comparator でない" {
  # localeCompare は ICU/locale 依存でホストが変わると順序が変わりうる＝「決定論式」を満たさない。
  # comparator から localeCompare の【呼出し】が消えていること（静的・解説コメント中の語は許容するため
  # 呼出し形 `localeCompare(` で見る）。
  run grep -n 'localeCompare(' "$WF"
  [ "$status" -ne 0 ]
  # 第2キーが「要素ごとの dim 同士」の比較であること（旧実装は dimKey 同士＝恒真 0 の no-op だった）。
  run grep -F -q -- 'if (a.dim !== b.dim) return a.dim < b.dim ? -1 : 1' "$WF"
  [ "$status" -eq 0 ]

  # behavioral: 同 severity で title が "B-item"(0x42) と "a-item"(0x61) のとき、code-unit 順なら "B-item" が
  # 先に admit される（en_US の照合順なら "a-item" が先＝旧実装との弁別点）。LC_ALL を振っても結果は不変。
  # (sc-spp1 v2) severity を minor 化: critical は floor（K の対象外）になったため、tie-break の観測は
  # K が実際に切る尾(minor/nit)で行う（挙動の観測点は同一＝capOrderFindings の第 3 キー）。
  local F='[{"title":"a-item","severity":"minor","location":"x:1","rationale":"r"},{"title":"B-item","severity":"minor","location":"x:2","rationale":"r"}]'
  local out_c out_en
  run env LC_ALL=C CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":1,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$F" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  out_c="$(kval "$output" capDroppedTitles)"
  # 落ちるのは "a-item"（= admit されたのは "B-item"）＝code-unit 順。
  [ "$out_c" = "a-item;a-item;a-item;a-item" ]

  run env LC_ALL=en_US.UTF-8 CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":1,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$F" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  out_en="$(kval "$output" capDroppedTitles)"
  [ "$out_en" = "$out_c" ]
}

@test "sc-k33c H2 (K8): terminal 判定 / capReport 組立 / capNote 生成も SCCAP ブロック内に閉じている" {
  local s e body outside
  s="$(grep -n '^//SCCAP_BLOCK_START$' "$WF" | cut -d: -f1)"
  e="$(grep -n '^//SCCAP_BLOCK_END$' "$WF" | cut -d: -f1)"
  body="$(sed -n "${s},${e}p" "$WF")"
  outside="$(sed -n "1,$((s - 1))p;$((e + 1)),\$p" "$WF")"

  # 判定本体はブロック内に 1 個だけ在る。
  grep -q 'const capFinalize = ' <<< "$body"
  [ "$(grep -c 'const capFinalize = ' "$WF")" -eq 1 ]
  # capReport の組立と capNote の文言生成もブロック内（外側には literal が無い）。
  grep -q "unit: 'agent-calls'" <<< "$body"
  ! grep -q "unit: 'agent-calls'" <<< "$outside"
  grep -q '※cap 発火' <<< "$body"
  ! grep -q '※cap 発火' <<< "$outside"
  # 外側に残るのは「呼んで適用するだけ」の薄い call site（capFinalize 呼出しはちょうど 1 箇所）。
  [ "$(grep -F -c -- 'capFinalize({ converged, escalate, escalateReason })' "$WF")" -eq 1 ]
  grep -q 'capFinalize({ converged, escalate, escalateReason })' <<< "$outside"

  # (ERRATA-01 B5) ブロック外に **判定コード** が残っていないこと。解説コメントは許容するので行頭 // を落として
  # から見る（旧実装は parallel 入口で capCatch の中身を再実装し capClassify を 2 度呼び、terminal では
  # capEarlyBreak / escalateReason の文言をブロック外で組み立てていた）。
  local outside_code
  outside_code="$(grep -v '^[[:space:]]*//' <<< "$outside")"
  ! grep -q 'capClassify(' <<< "$outside_code"
  ! grep -q 'capRecordException(' <<< "$outside_code"
  ! grep -q 'cap 由来の早期打切り' <<< "$outside_code"
  ! grep -q 'capEarlyBreak' <<< "$outside_code"
  # 同期 throw 側の入口もブロック内に在り、呼出サイトはそれを使うだけ。
  grep -q 'const capCatchSync = ' <<< "$body"
  grep -q 'capCatchSync(`verify-entry:' <<< "$outside_code"
  # loop 終端の判定/文言もブロック内。
  grep -q 'const capTerminatedEarly = ' <<< "$body"
  grep -q 'const capLoopEscalate = ' <<< "$body"

  # 実走で terminal の意味論が保たれている（リファクタで挙動を変えていない）。
  run env CQ_ARGS="$(cq_args '{"totalBudget":8}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" converged)" = "false" ]
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gateHasCapNote)" = "true" ]
  [ "$(kval "$output" capUnit)" = "agent-calls" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [I] ERRATA-01 B1: cap 中核保証を roAgent fallback 経路込みで成立させる
#   目的 = (i) 実呼出し総数 ≤ totalBudget  (ii) capReport.spentEstimate == 実呼出し総数
#   機序 = roAgent は not-found 検知後に agentType 無しで **2 度目の実呼出し** をする。旧実装は論理段だけを
#          計上していたため cap ON で総数超過（gate 実測: CQ_RO_NOTFOUND=true + totalBudget=7 → 実 8）、
#          cap OFF でも spentEstimate が 1 本少なかった（33 実呼出しに対し 32）。
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c I-B1: RO fallback 経路でも 実呼出し ≤ totalBudget かつ spentEstimate == 実呼出し（cap ON 掃引）" {
  local n out actual spent
  for n in 5 6 7 8 12 16; do
    echo "# totalBudget=$n (CQ_RO_NOTFOUND=true)"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" CQ_RO_NOTFOUND=true \
        CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false node "$DRIVER" run
    [ "$status" -eq 0 ]
    out="$output"
    actual="$(kval "$out" agentCallTotal)"
    spent="$(kval "$out" capSpentEstimate)"
    # (i) 実呼出し総数が cap を破らない。
    [ "$actual" -le "$n" ]
    # (ii) spentEstimate は実呼出し総数と一致する（論理段の見積りではない）。
    [ "$spent" -eq "$actual" ]
    # fallback が実際に発火している run であること（空虚な green を作らない）。
    [ "$(kval "$out" roFallbackActive)" = "true" ]
  done
}

@test "sc-k33c I-B1: cap OFF でも spentEstimate == 実呼出し（RO fallback の 2 度目呼出しを取りこぼさない）" {
  local out
  run env CQ_ARGS="$(cq_args '{}')" CQ_RO_NOTFOUND=true CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" roFallbackActive)" = "true" ]
  [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]
  # 対照: fallback 無しでも一致する（一致 pin が fallback 専用の特別扱いになっていない）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" roFallbackActive)" = "false" ]
  [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]
}

@test "sc-k33c MU14: roAgent fallback の 2 度目呼出しの計上を外すと spentEstimate が実呼出しから外れる" {
  # mutant_fingerprint: `capCountCall(label) // fallback の 2 度目の実呼出し` → 削除
  local mut="$BATS_TEST_TMPDIR/mu14"
  plant_cap_mutant "$mut" "capCountCall(label) // fallback の 2 度目の実呼出し" "// 変異: 計上を外した"
  run env CQ_ARGS="$(cq_args '{}')" CQ_RO_NOTFOUND=true CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
      CQ_VERIFY_REFUTED=false node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  # 変異後は spentEstimate < 実呼出し（＝旧実装の取りこぼしが復活する）。
  [ "$(kval "$output" capSpentEstimate)" -lt "$(kval "$output" agentCallTotal)" ]
}

@test "sc-k33c MU15: 予約コスト（capCallCost）を 1 固定にすると RO 未解決の並列 admission で総数が cap を破る" {
  # mutant_fingerprint: `const capCallCost = () => (capRoResolved ? 1 : 2)` → `const capCallCost = () => 1`
  #
  # 発火条件（実測で特定）: RO agentType の解決状態が **未確定のまま** 並列 admission へ入る経路。
  # worker-cell 形（self-test baseline や snapshot が先に走る）では先頭の RO 呼出しが解決を確定させるため
  # 到達しない。single モード（静的 diff 供給 + autoFix off ＝ snapshot も self-test も走らない）では
  # review 4 観点が最初の RO 呼出しになり、4 本が同時に not-found → それぞれ 2 度目を呼ぶ（実 8 本）。
  local single_args='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n","taskType":"testable"'
  local mut="$BATS_TEST_TMPDIR/mu15"
  plant_cap_mutant "$mut" "const capCallCost = () => (capRoResolved ? 1 : 2)" "const capCallCost = () => 1"

  local n out over=0
  for n in 4 5 6; do
    echo "# totalBudget=$n"
    # HEAD: 4 観点分の枠（1 本あたり 2 本ぶん）が取れないので round を回さない＝実呼出し 0（cap を破らない）。
    run env CQ_ARGS="${single_args},\"totalBudget\":$n}" CQ_RO_NOTFOUND=true node "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(kval "$output" agentCallTotal)" -le "$n" ]
    # 変異後: 1 本ぶんしか予約しないので 4 観点を admit し、実 8 本で cap を破る。
    run env CQ_ARGS="${single_args},\"totalBudget\":$n}" CQ_RO_NOTFOUND=true node "$mut/tests/driver.mjs" run
    [ "$status" -eq 0 ]
    out="$output"
    if [ "$(kval "$out" agentCallTotal)" -gt "$n" ]; then over=1; echo "# violation at totalBudget=$n: actual=$(kval "$out" agentCallTotal)"; fi
  done
  [ "$over" -eq 1 ]
}

@test "sc-k33c I-B1: RO 未解決の並列 admission でも 実呼出し ≤ totalBudget（single モード・境界の両側）" {
  local single_args='{"taskTitle":"c","worktree":"/tmp/wt","diff":"diff --git a/x b/x\n@@ -1 +1 @@\n-a\n+b\n","taskType":"testable"'
  local n
  for n in 4 5 6 8 12; do
    echo "# totalBudget=$n"
    run env CQ_ARGS="${single_args},\"totalBudget\":$n}" CQ_RO_NOTFOUND=true node "$DRIVER" run
    [ "$status" -eq 0 ]
    [ "$(kval "$output" agentCallTotal)" -le "$n" ]
    [ "$(kval "$output" capSpentEstimate)" -eq "$(kval "$output" agentCallTotal)" ]
  done
  # 枠が足りる側（8）では実際に 4 観点 × 2 実呼出し = 8 本走る（空虚に 0 本で通していない）。
  run env CQ_ARGS="${single_args},\"totalBudget\":8}" CQ_RO_NOTFOUND=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" agentCallTotal)" -eq 8 ]
  # fallback 下では 1 論理 review = 実呼出し 2 本（同じ label が 2 度記録される）＝4 観点で 8 本。
  # これが「論理段の計上では取りこぼす 1 本ずつ」の正体で、B1 の予約コスト 2 はこれを見込んでいる。
  [ "$(kval "$output" reviewCallCount)" -eq 8 ]
  [ "$(kval "$output" roFallbackActive)" = "true" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [J] ERRATA-01 B2: 指紋の過剰一致（fail-closed 迂回）の封鎖
#   目的 = cap でない machinery 例外が capExceeded へ吸われないこと。
#   gate 実測の退行形 = 'agent capability probe returned malformed payload' が reason='error' に吸収され、
#   既定路（無防備 call site）の fail-closed 再 throw が exit 0 / ESCALATE へ化けていた。
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-k33c J-B2: 指紋の near-miss は cap 判定されず fail-closed 再 throw に倒れる（negative tooth）" {
  local kind
  for kind in near-capability near-capacity near-exceededness near-limitless; do
    echo "# near-miss kind: $kind"
    # 無防備 call site（snapshot）へ near-miss 文言の例外を投げる。cap でないので capCatch は再 throw し、
    # run は従来どおり死ぬ（＝fail-closed）。cap へ吸われていれば exit 0 + capExceeded=true になる。
    run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' CQ_THROW_KIND="$kind" node "$DRIVER" run
    [ "$status" -ne 0 ]
    [[ "$output" == *'DRIVER_ERROR'* ]]
  done
  # 対照: 語境界に一致する本物の cap 文言は従来どおり cap として捕捉される（negative tooth が
  # 「何でも非 cap にする」退行で通っていない＝非空虚性）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' CQ_THROW_KIND=error \
      CQ_CAP_ERR_MODE=message node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "error" ]
}

@test "sc-k33c MU16: 指紋を素の substring 一致へ戻すと near-miss が cap へ吸われ fail-closed が迂回される" {
  # mutant_fingerprint: `if (fp.re.test(msg)) return fp.reason` → `if (msg.includes(String(fp.re).slice(3, -3))) ...`
  # （語境界 \b…\b を外した素の部分一致へ戻す変異＝gate が実測した退行そのもの）
  local mut="$BATS_TEST_TMPDIR/mu16"
  plant_cap_mutant "$mut" "if (fp.re.test(msg)) return fp.reason" \
      "if (msg.includes(String(fp.re).slice(3, -3))) return fp.reason"
  # 変異後: 'agent capability …' が reason='error' として吸われ、run が死なずに終わる（fail-closed 迂回）。
  run env CQ_ARGS="$(cq_args '{}')" CQ_THROW_AT_LABEL='snapshot' CQ_THROW_KIND=near-capability \
      node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "error" ]
}

@test "sc-k33c MU17 (B3): admission が実呼出し counter を触ると縮退域で spentEstimate が実本数から外れる" {
  # mutant_fingerprint: `capBooked += admitted * cost` → `capBooked += admitted * cost; capSpent += admitted`
  # （＝旧実装の「予約と実本数を 1 本の counter で兼用する」形へ戻す変異。K3-1 掃引の spentEstimate 一致
  #   assert が縮退発生域で効くことの非空虚性を示す）
  local mut="$BATS_TEST_TMPDIR/mu17"
  plant_cap_mutant "$mut" "capBooked += admitted \* cost" "capBooked += admitted * cost; capSpent += admitted"
  local n out
  for n in 5 8 12; do
    echo "# totalBudget=$n"
    run env CQ_ARGS="$(cq_args "{\"totalBudget\":$n}")" CQ_REVIEW_FINDINGS="$FINDINGS_MIX" \
        CQ_VERIFY_REFUTED=false node "$mut/tests/driver.mjs" run
    [ "$status" -eq 0 ]
    out="$output"
    # 変異後は spentEstimate > 実呼出し（K3-1 掃引の一致 assert が RED になる形）。
    [ "$(kval "$out" capSpentEstimate)" -gt "$(kval "$out" agentCallTotal)" ]
  done
}

@test "sc-k33c MU13 (B4): perRoundVerifyTopK の cut を無効化すると尾 top-K と capDropped が消える" {
  # mutant_fingerprint: `if (needTopK) {` → `if (false) {`（sc-spp1 v2 で cut 分岐の条件式が変わったため追随）
  #
  # (ERRATA-01 B4) 旧 note の「K3-2↔MU12 / K3-3↔MU11」は誤対応だった（gate 実測: MU12 は tooth 10 を、
  # MU11 は tooth 11 を RED にしない）。K3-2 / K3-3 の実 catcher はこの変異で、ここでは同じ変異を driver
  # 実走で behavioral に固定する（bats 全数の入れ子実行はしない）。
  local mut="$BATS_TEST_TMPDIR/mu13"
  plant_cap_mutant "$mut" "if (needTopK) {" "if (false) {"

  # HEAD: perRoundVerifyTopK=2・TAILY（floor 1 + 尾 5）→ 各観点 3 本・尾下位 3 件が capDropped[] へ。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":2,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_VERIFY_REFUTED=false node "$DRIVER" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=3,correctness=3,integration-ops=3,robustness-security=3" ]
  [ "$(kval "$output" capDroppedTitles)" = "NIT;NIT;NIT;NIT;m3;m3;m3;m3;m4;m4;m4;m4" ]
  [ "$(kval "$output" capExceeded)" = "true" ]

  # 変異後: cut が起きず 6 本すべて verify され、capDropped は空・cap も発火しない（尾 top-K が死ぬ）。
  run env CQ_ARGS="$(cq_args '{"perRoundVerifyTopK":2,"maxRounds":1}')" CQ_REVIEW_FINDINGS="$FINDINGS_TAILY" \
      CQ_VERIFY_REFUTED=false node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [ "$(kval "$output" verifyByDim)" = "completeness-critic=6,correctness=6,integration-ops=6,robustness-security=6" ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
}

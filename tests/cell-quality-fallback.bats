#!/usr/bin/env bats
# roAgent() fallback(sc-7bv 導入)の恒久回帰テスト(sc-xyw)。
#
# 背景: read-only 段の agentType('scribe:explore')が registry で解決不能な session(scribe plugin 未ロード /
# merge 前の worker session / 将来の registry drift)では、roAgent が probe 形状の "not found" throw を検知して
# agentType 省略へ後退し read-only 規律を prompt で代替する(fleet 全滅の恒久 fail-safe)。sc-7bv 導入時点では
# executable coverage がゼロ(driver の agentStub は agentType を無視し reject しない=催行系で fallback 分岐が
# 一度も走らなかった)。本 bats は driver に「agentType 付き呼出しを probe 形状 not found で reject し、降格後の
# agentType 無し呼出しは resolve」する stub シナリオ(CQ_RO_NOTFOUND=true)を敷き、fallback を実走で固定する。
#
# 検証(受入 acceptance 1 の a/b/c):
#   (a) WF が escalate せず完走し review/verify 経路が生きる。
#   (b) [RO-FALLBACK] loud log がちょうど 1 回(降格が後続段へ伝播し、再検知が起きていない)。
#   (c) 降格後の agent 呼出しに agentType が付かない(=agentType 付き呼出しは初回の 1 回のみ=降格 flag の後続伝播)。
# 加えて acceptance 3(返り値 JSON に roFallbackActive を全 return 経路で一貫して載せる)を実走で固定する。
#
# stub は「agentType 付きなら常に not found で reject」する(初回限定でない)。これにより降格の後続伝播が壊れた退行
# (各 read-only 段が毎回 agentType を付け直す)は「[RO-FALLBACK] が複数回・agentType 付き呼出しが複数」として
# behavioral に検出される(source-level grep では捕まらない伝播バグを実走で捕捉する)。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  PREBAKE="$REPO_ROOT/workflows/needs-user-prebake.workflow.js"
  # worker-cell(autoFix)の完全な args(fail-fast を通過する最小充足)。
  ARGS_WORKER='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable"}'
  FINDING='[{"title":"x","severity":"minor","location":"a:1","rationale":"r"}]'
}

# ── acceptance 1 (a/b/c) の中核: not found → 降格し escalate せず完走・log 1 回・降格後 agentType 無し ──────
@test "sc-xyw a/b/c: roAgent not found → 降格し escalate せず完走・[RO-FALLBACK] 1 回・降格後 agentType 無し" {
  run env CQ_ARGS="$ARGS_WORKER" CQ_RO_NOTFOUND=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  # (a) fallback しても WF は escalate せず収束する(review/verify machinery が生きて回った)。
  [[ "$output" == *"K escalate false"* ]]
  [[ "$output" == *"K converged true"* ]]
  # (b) [RO-FALLBACK] loud log がちょうど 1 回=降格が後続段へ伝播し、各段で再検知していない。
  [[ "$output" == *"K roFallbackLogCount 1"* ]]
  # (c) 降格後の agent 呼出しに agentType が付かない=agentType 付き呼出しは初回の 1 回のみ(降格 flag の後続伝播)。
  [[ "$output" == *"K agentTypeCallCount 1"* ]]
  # 返り値に最終降格状態(roFallbackActive=true)が載る(acceptance 3・fallback が発火した run と読める)。
  [[ "$output" == *"K roFallbackActive true"* ]]
}

# ── acceptance 1 (a) を強める: fallback 降格後も verify 経路が実走する(findings を渡すと verify 段が増える) ──
@test "sc-xyw a: fallback 降格後も review→verify machinery が生きる(findings を渡すと verify 段が追加で走る)" {
  # findings なし fallback: review 段のみ(finding 0 で verify は走らない)。基準値を取る。
  run env CQ_ARGS="$ARGS_WORKER" CQ_RO_NOTFOUND=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  rv_nofind="$(echo "$output" | awk '/^K reviewVerifyCalls / {print $3}')"
  # findings 1 件 fallback: review + verify 両方走る=reviewVerifyCalls が増える。
  run env CQ_ARGS="$ARGS_WORKER" CQ_RO_NOTFOUND=true CQ_REVIEW_FINDINGS="$FINDING" CQ_VERIFY_REFUTED=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K escalate false"* ]]
  rv_find="$(echo "$output" | awk '/^K reviewVerifyCalls / {print $3}')"
  # verify が実際に走った証拠(fallback 降格後も review→verify 経路が生きている)。
  [ -n "$rv_nofind" ] && [ -n "$rv_find" ]
  [ "$rv_find" -gt "$rv_nofind" ]
  # findings があっても降格伝播は不変(fallback は 1 回・agentType 付き呼出しは 1 回)。
  [[ "$output" == *"K roFallbackLogCount 1"* ]]
  [[ "$output" == *"K agentTypeCallCount 1"* ]]
}

# ── 対照実験: 正常時(agentType 解決可)は fallback せず read-only 段が全て agentType 付きで走る ──────────────
@test "sc-xyw 対照: 正常時は fallback せず全 read-only 段が agentType 付きで走る(fallback シナリオと明確に対照)" {
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K roFallbackActive false"* ]]
  [[ "$output" == *"K roFallbackLogCount 0"* ]]
  # 正常時は複数の read-only 段が agentType 付きで呼ばれる(>1)=fallback シナリオの「1」と明確に対照。
  atc="$(echo "$output" | awk '/^K agentTypeCallCount / {print $3}')"
  [ -n "$atc" ]
  [ "$atc" -gt 1 ]
}

# ── acceptance 3(sc-pfn4 で throw 形へ改修): roFallbackActive の搭載面と、消えた早期 return の throw 化 ──
# cutover 前は defensive-parse 失敗 / args fail-fast も escalate=true の【早期 return】で、そこにも
# roFallbackActive が載ることを見ていた。canonical cutover でその 2 経路は throw になり return path 自体が
# 消えたので、acceptance 3 は「実在する return path(=result-level の 1 本)に載る」+「消えた 2 経路は agent を
# 1 体も起動せず run が死ぬ」の 2 本立てへ書き換える(下限を下げるのでなく、消えた面の不変条件を移す)。
@test "sc-xyw acceptance3(sc-pfn4 改修): roFallbackActive が実在 return path に載り、消えた 2 経路は throw で死ぬ" {
  # 通常経路(実在する唯一の result-level return)
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K roFallbackActive false"* ]]
  [[ "$output" == *'"roFallbackActive"'* ]]
  # fallback 発火経路でも最終降格状態が載る(true 側も実走で固定=literal false への退行を塞ぐ)。
  run env CQ_ARGS="$ARGS_WORKER" CQ_RO_NOTFOUND=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"roFallbackActive":true'* ]]
  # 旧・defensive parse 失敗の早期 return → canonical block の throw(rc=1・canonical marker・agent 0 起動)
  run env CQ_ARGS_STRING='{bad json,,' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[SCARGS fail-fast]"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
  # 旧・args fail-fast の早期 return(必須 args 欠落)→ 同上
  run env CQ_ARGS='{"autoFix":true}' node "$DRIVER" run
  [ "$status" -eq 1 ]
  [[ "$output" == *"DRIVER_ERROR"* ]]
  [[ "$output" == *"[SCARGS fail-fast]"* ]]
  [[ "$output" == *"DRIVER_AGENT_CALLS 0"* ]]
}

# ── 構造 pin(両骨格・source-level): fallback 機構と全 return 経路への roFallbackActive 搭載 ──────────────────
@test "sc-xyw 構造 pin: 両骨格が roAgent fallback 機構を持ち全 return 経路に roFallbackActive を載せる" {
  for f in "$WF" "$PREBAKE"; do
    [ -f "$f" ]
    # fallback 機構の 3 要素。
    grep -q 'let roFallbackActive' "$f"
    grep -q '\[RO-FALLBACK\]' "$f"
    grep -q 'isAgentTypeNotFound' "$f"
    # 変数 shorthand(helper 定義後の各 return)。
    grep -Eq '^[[:space:]]*roFallbackActive,' "$f"
  done
  # (sc-pfn4) 早期中断経路(helper 定義前)の literal false は prebake 専用の面になった。cell-quality は canonical
  # cutover で helper 定義前の早期 return が throw へ置換され、literal 形の return path が 0 本になったため
  # (WF から assert を削除するのでなく PREBAKE 側へ移設する=prebake 側の面は 1 byte も緩めない)。
  grep -q 'roFallbackActive: false' "$PREBAKE"
  [ "$(grep -c 'roFallbackActive: false' "$WF")" -eq 0 ]
  # (sc-pfn4) shorthand 出現数は per-file に分離し、それぞれ実在 return path 数へ焼き直す。
  #   cell-quality: cutover 後の result-level return は 1 本のみ(早期 return 2 本が throw 化)= 実在数 1 で exact 固定。
  #     「載っていない return path が 0 本」は tests/cell-quality-selftest.bats の behavioral tooth が別に pin する
  #     (下限だけを下げると到達不能 return の dead code 温存で grep pin だけ通る抜け道が残るため)。
  #   prebake: 非接触ゆえ現行実測(4)の下限を維持する。
  [ "$(grep -cE '^[[:space:]]*roFallbackActive,' "$WF")" -eq 1 ]
  [ "$(grep -cE '^[[:space:]]*roFallbackActive,' "$PREBAKE")" -ge 4 ]
  # meta.whenToUse に roAgentType(acceptance 2)。
  grep -A2 'whenToUse:' "$WF" | grep -q 'roAgentType'
  grep -A2 'whenToUse:' "$PREBAKE" | grep -q 'roAgentType'
}

# ── (sc-xyw errata) 中核安全機構の behavioral 固定: 降格後の read-only 段呼出しに RO_DISCIPLINE 前置が付く ──────
# confirmed-minor(sc-7bv gate wf_05bc3204-cc8): agentType の構造強制(書込ツール非所持)を fallback 降格後は prompt の
# read-only 規律(RO_DISCIPLINE 前置=`prompt + RO_DISCIPLINE`)が代替する。この前置が消えても既存の log/agentType/converged
# 系 assert は全て green のまま=fallback が完全 fail-open へ silent 退行しうる(前任 gate の confirmed minor)。
# driver は各呼出しの prompt に前置マーカー(/agentType 構造強制の代替/)が付いたかを K roDisciplineCallCount へ露出するので、
# fallback シナリオで >0・正常時(agentType 解決可)で 0 を対照実験で固定し、この silent 退行を behavioral に捕捉する。
@test "sc-xyw errata: fallback 降格後の read-only 段呼出しに RO_DISCIPLINE 前置が付く(対照: 正常時は付かない)" {
  # fallback シナリオ: 降格後の read-only 段(classify/plan/snapshot/selftest/review/verify)は prompt に RO_DISCIPLINE を前置される。
  run env CQ_ARGS="$ARGS_WORKER" CQ_RO_NOTFOUND=true node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K escalate false"* ]]
  disc_fb="$(echo "$output" | awk '/^K roDisciplineCallCount / {print $3}')"
  [ -n "$disc_fb" ]
  # 降格後に read-only 規律が prompt で代替されている証拠(前置が消えれば 0 に落ちてここで fail)。
  [ "$disc_fb" -gt 0 ]
  # 対照: 正常時(agentType 解決可)は降格せず RO_DISCIPLINE 前置は一度も付かない(=前置は fallback 経路固有)。
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K roDisciplineCallCount 0"* ]]
}

# ── (sc-xyw errata) 構造 pin(両骨格・source-level): RO_DISCIPLINE 定義と降格経路での前置(prompt + RO_DISCIPLINE) ──
# 上の behavioral test は cell-quality driver(逐次経路)でしか回らない。prebake の read-only 段(facet 分析)は parallel()
# 起動ゆえ driver の逐次再現が構造上届かない=behavioral 検証不能。よって prebake は source-level grep で fallback の
# 中核安全機構(RO_DISCIPLINE 前置)を pin し、cell-quality と対称に守る。
# 注意: [RO-FALLBACK] log=1 の invariant は「逐次先頭の read-only 段が最初に fallback を確定する」cell-quality 固有の性質で、
# facet を parallel 起動する prebake へは流用しない(並行 race で複数 facet が確定前に not found を踏み log>1 になりうる=無害だが 1 に pin できない)。
@test "sc-xyw errata 構造 pin: 両骨格が RO_DISCIPLINE を定義し降格経路で prompt へ前置する(prebake は behavioral 不達ゆえ pin で固定)" {
  for f in "$WF" "$PREBAKE"; do
    [ -f "$f" ]
    # RO_DISCIPLINE 前置文の定義。
    grep -qF 'const RO_DISCIPLINE' "$f"
    # 降格経路で prompt に前置する呼出し(中核安全機構)=2 箇所(降格済 short-circuit + not found 検知直後)。
    grep -qF 'prompt + RO_DISCIPLINE' "$f"
    # 前置マーカー(driver の behavioral 検出 /agentType 構造強制の代替/ と同一の目印=消えれば behavioral と pin が同時に落ちる)。
    grep -qF 'agentType 構造強制の代替' "$f"
  done
}

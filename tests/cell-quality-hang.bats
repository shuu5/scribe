#!/usr/bin/env bats
# sc-foqe（[c1df leg2]）— cell-quality 骨格の **per-agent timeout**（agent hang 対策）の behavioral 恒久回帰テスト。
#
# 【塞ぐ失敗（一次事象）】orch-c1df (2): 33 agent 中 32 done のまま 1 本が約 2h 未返 → WF run 自体が terminal に
# 達せず、呼出元 worker の待機が無限化した。本 file が pin するのは **WF script が有限時間で return すること**
# （＝実機 harness 上の hang 解消は主張しない・driver 忠実性ギャップは既知 bug sc-ojom）。
#
# 検証の建て付け（acceptance 3 点連言に 1:1 対応）:
#   [H-A] (1) fan-out 中の 1 本だけが返らない状況で run が有限時間 terminal に達し、返り値 timedOut[] に
#             当該 label が載る（review 面 / verify 面の 2 本）。
#   [H-B] (2) その timeout は clean と区別され、timeout が立った round で converged が立たない
#             （同一 args・stuck 無しでは CONVERGED になる形で対照を取る＝非空虚）。
#   [H-C] (3-i) 非空虚性: timeout 機構を 1 箇所潰した変異木で同 tooth が RED（rc=124＝有限時間 return しない）
#             へ flip する。＝「修正前骨格では同じ模擬で有限時間 return しない」を **同一 tooth** で示す。
#   [H-D] (3-ii) 負方向弁別: 既存 reject seam（CQ_THROW_AT_LABEL / CQ_BUDGET_THROW_AT / CQ_AGENT_CAP）は
#             即 settle する失敗であって stuck ではない＝timedOut[] が立たない。
#   [H-E] limiter 不変条件: timeout は limiter thunk の **内側**にあり、timeout 後も後続 agent が起動できる
#             （外側に掛けるとスロットが恒久リークする）。
#   [H-F] 静的 guard: WF に Date.now( / 引数なし new Date() / Math.random( が 0 hit（harness の静的 lint は
#             inline script 経路でしか走らず scriptPath 経路では launch 前に弾かれないため repo 側で pin する）。
#   [H-G] 上限秒が決め打ちでない（args.agentTimeoutMs が実効・0 = 明示 opt-out）。
#   [H-H] 既定 no-op: CQ_STUCK_AT_LABEL 未設定なら timeout 表面は一切立たない。
#
# 規律（protocol §2 / cap.bats・loop.bats と同じ）:
#   - 各 tooth に assertion inventory row（invariant / polarity / mutant_fingerprint）を併記する。
#   - 変異注入は BATS_TEST_TMPDIR の copy 木へ行う（実 file を変異させたまま commit しない）。
#   - pipefail 下の `producer | grep -q` を書かない（SIGPIPE で rc=141 の偽 RED になる）。herestring / file-arg
#     grep を使う。grep は /usr/bin/grep をフルパス固定（不在なら fail-loud）。
#   - skip は 1 本も置かない。
#   - **rc 単独で判定しない**: 有限時間 return の oracle は「rc≠124 かつ stdout 非空かつ RESULT 行実在かつ
#     新観測軸が期待値」の連言（assert_finite_return + 個別 assert）。rc=0 だけを見ると driver の早期死
#     （素の未解決 Promise 注入で node が 0.05 秒 / 0 byte / rc=0 で終わる形）を green と誤読する。
#
# 【suite 暴走の防止】本 file は「返らない agent」を意図的に作るため、tooth 単位の hard timeout を張る
# （既存 cell-quality 系 bats 8 本に BATS_TEST_TIMEOUT は 0 hit＝本 file が最初）。Bats 1.13.0 で有効。
BATS_TEST_TIMEOUT="${SC_FOQE_BATS_TEST_TIMEOUT:-120}"

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  GREP=/usr/bin/grep

  # ── 決め打ち禁止: 壁時計上限も WF 側 per-agent 上限も env 上書き可の変数で持つ ────────────────
  # WALL       … 有限 return を期待する run の壁時計上限（秒）。TMO=300ms なので実測 ~1s、十分な余裕。
  # HANG_WALL  … hang を期待する run（変異木 / opt-out）の壁時計上限（秒）。短くして suite を速く保つ。
  # TMO        … WF の args.agentTimeoutMs（ms）。stub agent は即返るので、この値だけが timeout 発火を決める。
  WALL="${SC_FOQE_WALL:-30}"
  HANG_WALL="${SC_FOQE_HANG_WALL:-5}"
  TMO="${SC_FOQE_TIMEOUT_MS:-300}"

  # loop モードの基底 args（autoFix + selfTestCmd + taskType 指定＝classify を回さない決定論形）。
  LOOP_BASE="{\"taskTitle\":\"hang-cell\",\"worktree\":\"/tmp/wt\",\"goal\":\"do x\",\"selfTestCmd\":\"bats tests/x.bats\",\"autoFix\":true,\"taskType\":\"testable\",\"agentTimeoutMs\":${TMO},\"maxRounds\":1}"
  # single モードの基底 args（静的 diff 供給・snapshot を回さない）。**stuck 無しなら CONVERGED になる**形
  # （minor 1 件・refuted=true）＝[H-B] の false CONVERGED 封鎖を非空虚に観測できる唯一の対照。
  SINGLE_BASE="{\"taskTitle\":\"hang-single\",\"worktree\":\"/tmp/wt\",\"diff\":\"diff --git a/x b/x\\n@@ -1 +1 @@\\n-a\\n+b\\n\",\"taskType\":\"testable\",\"agentTimeoutMs\":${TMO}}"
  FINDING_MINOR='[{"title":"MMM","severity":"minor","location":"m.js:1","rationale":"naming"}]'
}

# K 行から値を取り出す（herestring 経由＝pipefail 下の SIGPIPE 偽 RED を作らない）。
kval() {
  local out="$1" key="$2"
  sed -n "s/^K ${key} //p" <<< "$out"
}

# 基底 args へ JSON 片をマージする（args を手組みせず 1 経路で作る）。
hq_args() {
  node -e 'const a=JSON.parse(process.argv[1]);Object.assign(a,JSON.parse(process.argv[2]||"{}"));console.log(JSON.stringify(a))' "$LOOP_BASE" "$1"
}
sq_args() {
  node -e 'const a=JSON.parse(process.argv[1]);Object.assign(a,JSON.parse(process.argv[2]||"{}"));console.log(JSON.stringify(a))' "$SINGLE_BASE" "$1"
}

# 任意 title の finding 1 件を JSON で作る（title は **review agent が書く自由文** の模擬＝WF が制御しない入力）。
# severity は引数 2（既定 major＝blocking で loop が回る形）。
finding_titled() {
  node -e 'console.log(JSON.stringify([{title:process.argv[1],severity:process.argv[2]||"major",location:"m.js:1",rationale:"r"}]))' \
    "$1" "${2:-major}"
}

# RESULT JSON を JS 式で直読する（timedOut[] は K 行に無い新規 field＝driver へ無条件の新 K 行を足すと
# loop.bats L-C1「knob 導入前 driver との byte 一致」を割るため、cap.bats の crval() と同じ思想で
# RESULT JSON 側から取る）。RESULT 行が無ければ **loud fail**（空虚 green を作らない）。
rjson() {
  local out="$1" expr="$2"
  node -e '
    const m = process.argv[1].match(/RESULT (.*)$/m)
    if (!m) { console.error("FATAL: RESULT 行が無い（driver が result を返していない）"); process.exit(3) }
    const r = JSON.parse(m[1])
    const v = new Function("r", "return (" + process.argv[2] + ")")(r)
    console.log(v === undefined ? "<absent>" : typeof v === "object" ? JSON.stringify(v) : String(v))
  ' "$out" "$expr"
}

# 有限時間 return の oracle（rc 単独で判定しない・連言）。
#  - rc≠124: `timeout` が撃っていない＝壁時計内に終わった。
#  - stdout 非空 + RESULT 行実在: 「node が早期に死んで 0 byte / rc=0」を green と誤読しない。
assert_finite_return() {
  [ "$status" -ne 124 ]
  [ -n "$output" ]
  [[ "$output" == *'RESULT {'* ]]
}

# 【重要・本 file の assert 規律】bats では `! cmd` の失敗が **テスト失敗にならない**（POSIX: `!` で反転された
# コマンドの戻り値に対して set -e は発火しない。本 host の Bats 1.13.0 で `! true` が ok になることを実測）。
# ゆえに本 file は否定 assert に `! cmd` を **使わない** — `assert_no_match` / `assert_differs` のように
# 明示的に fail させるヘルパか、`[ ... ]` / `[[ ... != ... ]]`（反転ではなく比較）で書く。
# （既存 cell-quality 系 bats に残る `! cmp -s` / `! grep -q` 形は同じ空虚性を持つが、本 cell の編集可
#   スコープ外ゆえ触らない＝admin への申し送りとして bd notes に記録する。）

# file に pattern が **無い**ことを assert する（grep は file-arg・pipefail 下の SIGPIPE を作らない）。
assert_no_match() {
  local file="$1"; shift
  if "$GREP" -q "$@" "$file"; then
    echo "# FATAL: '$*' が $file に hit した（0 hit を期待）" >&2
    return 1
  fi
}
# file に pattern が **在る**ことを assert する。
assert_match() {
  local file="$1"; shift
  if ! "$GREP" -q "$@" "$file"; then
    echo "# FATAL: '$*' が $file に hit しない（在ることを期待）" >&2
    return 1
  fi
}
# 2 file が **異なる**ことを assert する（変異が no-op でないことの確認＝空虚な mutation tooth を作らない）。
assert_differs() {
  if cmp -s "$1" "$2"; then
    echo "# FATAL: 変異が no-op（sed pattern が一致していない）: $2" >&2
    return 1
  fi
}

# 変異木を BATS_TEST_TMPDIR に作る: WF の literal を sed で置換し、driver は最終木のものを使う。
plant_wf_mutant() {
  local dir="$1" pattern="$2" replacement="$3"
  mkdir -p "$dir/workflows" "$dir/tests"
  cp "$DRIVER" "$dir/tests/driver.mjs"
  sed "s|${pattern}|${replacement}|" "$WF" > "$dir/workflows/cell-quality.workflow.js"
  assert_differs "$WF" "$dir/workflows/cell-quality.workflow.js"
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-A] acceptance (1): fan-out の 1 本だけが返らない状況で run が有限時間 terminal に達する
# ─────────────────────────────────────────────────────────────────────────────

# ── H-A1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=review fan-out の 1 本が keep-alive 付きで居座っても run は有限時間で terminal に達し、
#            返り値 timedOut[] に当該 label / stage / dimension / round が載る
#          | polarity=positive（RED→GREEN: 実装前は同じ模擬で run が返らず rc=124）
#          | mutant_fingerprint=[H-C1] が `Promise.race([p, timeoutP])` → `p` の変異木で rc=124 へ flip
@test "sc-foqe H-A1: review fan-out の 1 本が stuck でも run は有限時間で return し timedOut[] に載る" {
  run env CQ_ARGS="$(hq_args '{}')" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return

  # timedOut[] は **1 本だけ**（「fan-out 中の 1 本だけが返らない」状況の忠実な再現であることの pin）。
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 1 ]
  [ "$(rjson "$output" 'r.timedOut[0].label')" = "review:correctness r1" ]
  [ "$(rjson "$output" 'r.timedOut[0].stage')" = "review" ]
  [ "$(rjson "$output" 'r.timedOut[0].dimension')" = "correctness" ]
  [ "$(rjson "$output" 'r.timedOut[0].round')" -eq 1 ]
  [ "$(rjson "$output" 'r.timedOut[0].timeoutMs')" -eq "$TMO" ]

  # 非空虚性: 残り 3 観点は実際に起動して返っている（＝「全部止めた」ではなく 1 本だけの模擬）。
  [ "$(kval "$output" reviewCallCount)" -eq 4 ]
  # review 段 timeout は既存の失敗正規化（{findings:[], __reviewFailed:true}）へ合流している。
  [ "$(rjson "$output" 'r.history[0].reviewFailed')" -eq 1 ]
  # cap 系とは別枠（timeout を cap 指紋へ誤分類していない）。
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
}

# ── H-A2 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=verify fan-out の 1 本が stuck でも有限時間 return し、当該 finding は verdict:null →
#            unverified[] へ載る（capDropped[] へは積まない＝K3-3 の二重計上禁止を timeout でも守る）
#          | polarity=positive
#          | mutant_fingerprint=[H-C1] と同じ（race 撤去で rc=124）。二重計上側は capDroppedCount -eq 0 が pin
@test "sc-foqe H-A2: verify fan-out の 1 本が stuck でも有限時間 return し unverified へ載る（capDropped へは積まない）" {
  run env CQ_ARGS="$(sq_args '{}')" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$FINDING_MINOR" CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return

  [ "$(rjson "$output" 'r.timedOut.length')" -eq 1 ]
  [ "$(rjson "$output" 'r.timedOut[0].stage')" = "verify" ]
  [ "$(rjson "$output" 'r.timedOut[0].dimension')" = "correctness" ]
  [[ "$(rjson "$output" 'r.timedOut[0].label')" == verify:correctness:* ]]

  # 非空虚性: 4 観点ぶんの verify が起動している（1 本だけが返らなかった）。
  [ "$(kval "$output" verifyCallCount)" -eq 4 ]
  # verdict:null → unverified 行き。capDropped[] へは積まない（起動した ≠ そもそも起動しなかった）。
  [ "$(kval "$output" unverifiedCount)" -eq 1 ]
  [ "$(kval "$output" capDroppedCount)" -eq 0 ]
  [ "$(kval "$output" capExceeded)" = "false" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-B] acceptance (2): timeout は clean と区別され converged を立てない
# ─────────────────────────────────────────────────────────────────────────────

# ── H-B1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=同一 args で stuck 無しなら CONVERGED になる run が、verify 1 本の timeout で
#            converged=false へ倒れる（false CONVERGED の封鎖）。timeout は silent に倒さず gate へ注記が載る
#          | polarity=positive（対照 = 同一 args・stuck 無しの CONVERGED run＝空虚でないことを同一 tooth で示す）
#          | mutant_fingerprint=WF の `if (timedOut.length > 0) {` → `if (false) {`（terminal 正規化の無効化）
#            → converged=true / gatePrefix=CONVERGED へ戻り RED（**実走で確認する**）
@test "sc-foqe H-B1: timeout が立った round で converged が立たない（false CONVERGED の封鎖）" {
  local a
  a="$(sq_args '{}')"

  # 対照（非空虚性）: 同一 args・stuck 無しでは CONVERGED になる形であること。
  run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_MINOR" CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 0 ]

  # 本番: verify 1 本だけを stuck にすると終端が fail-closed 側へ倒れる。
  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$FINDING_MINOR" CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 1 ]
  [ "$(kval "$output" converged)" = "false" ]
  # 終端は **ESCALATE を exact で** pin する（`!= CONVERGED` だけだと OPEN へ倒す退行を素通しする。
  # OPEN は「呼出元が confirmed を修正して再 invoke せよ」の意味であり、machinery が返らなかった run に
  # 与えてよい終端ではない＝fail-open の穴になる）。
  [ "$(kval "$output" escalate)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "ESCALATE" ]
  [[ "$(rjson "$output" 'r.escalateReason')" == *'per-agent timeout'* ]]
  # timeout が立った round は timedOut[].round から機械で特定できる（この run は 1 round）。
  [ "$(rjson "$output" 'r.timedOut[0].round')" -eq "$(kval "$output" rounds)" ]
  # silent に倒していない: gate 文へ timeout 注記が載る（人手が timedOut[] を直読できる）。
  [[ "$(rjson "$output" 'r.gate')" == *'per-agent timeout='* ]]
}

# ── H-B2（非空虚性・変異注入）───────────────────────────────────────────────
# inventory: invariant=terminal 正規化（timeout → converged 否定）を潰すと H-B1 の封鎖が消える
#          | polarity=negative（mutant で CONVERGED へ戻る）
#          | mutant_fingerprint=`if (timedOut.length > 0) {` → `if (false) {`
@test "sc-foqe H-B2: terminal 正規化を潰すと timeout run が CONVERGED へ戻る（H-B1 の非空虚性）" {
  local mut="$BATS_TEST_TMPDIR/mu-b2"
  plant_wf_mutant "$mut" 'if (timedOut.length > 0) {' 'if (false) {'

  run env CQ_ARGS="$(sq_args '{}')" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$FINDING_MINOR" CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  # timeout 自体は起きている（＝変異が「timeout を止めた」のではなく「終端正規化だけを外した」ことの確認）。
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 1 ]
  # 封鎖が外れて false CONVERGED が復活する。
  [ "$(kval "$output" converged)" = "true" ]
  [ "$(kval "$output" gatePrefix)" = "CONVERGED" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-C] acceptance (3-i): 非空虚性 — timeout 機構を潰すと同じ模擬で有限時間 return しない
# ─────────────────────────────────────────────────────────────────────────────

# ── H-C1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=timeout 機構（Promise.race）を 1 箇所潰すと、H-A1 と同一の模擬・同一 args で run が
#            壁時計内に返らない（rc exact 124 / stdout 0 byte）＝「修正前骨格では有限時間 return しない」
#          | polarity=negative（同一 tooth 内で HEAD=有限 return / mutant=hang を **両方**実走して対比する）
#          | mutant_fingerprint=`return Promise.race([p, timeoutP]).then(` → `return p.then(`
@test "sc-foqe H-C1: timeout 機構（Promise.race）を潰すと同じ模擬で有限時間 return しない（rc=124）" {
  local a
  a="$(hq_args '{}')"

  # HEAD（現物）: 同一模擬で有限時間 return する。
  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$HANG_WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 1 ]

  # 変異木: race を外して agent 側 promise だけを待つ ＝ stuck 1 本で run 全体が返らなくなる。
  local mut="$BATS_TEST_TMPDIR/mu-c1"
  plant_wf_mutant "$mut" 'return Promise.race(\[p, timeoutP\]).then(' 'return p.then('

  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$HANG_WALL" node "$mut/tests/driver.mjs" run
  # rc は exact 124（`timeout` が撃った）。127/126（engine 不在・非実行）を hang 扱いしない。
  [ "$status" -eq 124 ]
  # stdout が空＝「返らないまま壁時計に殺された」ことの二次確認（RESULT 行も出ていない）。
  [[ "$output" != *'RESULT {'* ]]
}

# ── H-C2 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=timedOut[] への記録を潰すと、有限時間 return はしても観測面（当該 label）が消える
#          | polarity=negative
#          | mutant_fingerprint=`timedOut.push({ label,` → `void ({ label,`（台帳への記録だけを無効化）
@test "sc-foqe H-C2: timedOut[] への記録を潰すと観測面が消える（H-A1 の観測軸の非空虚性）" {
  local mut="$BATS_TEST_TMPDIR/mu-c2"
  plant_wf_mutant "$mut" 'timedOut.push({ label,' 'void ({ label,'

  run env CQ_ARGS="$(hq_args '{}')" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  # run は返るが台帳が空＝H-A1 の `timedOut.length -eq 1` が RED へ flip する。
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-D] acceptance (3-ii): 負方向弁別 — 既存 reject seam は stuck ではない
# ─────────────────────────────────────────────────────────────────────────────

# ── H-D1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=即 settle する既存 reject seam（CQ_THROW_AT_LABEL / CQ_BUDGET_THROW_AT / CQ_AGENT_CAP）の
#            run では timedOut[] が 1 件も立たない（reject を根拠にした acceptance 主張の封鎖）
#          | polarity=negative（timeout 側が立たないことを assert）
#          | mutant_fingerprint=WF の `if (!(agentTimeoutMs > 0)) return Promise.resolve().then(thunk)` を削って
#            全 reject を timeout 扱いへ…ではなく、driver の stuck 判定を `label.startsWith` → `true` へ広げると
#            reject seam の run でも timedOut が立ち本 tooth が RED（下の H-D2 が実走で確認）
@test "sc-foqe H-D1: 既存 reject seam（throw/budget/agent-cap）の run では timedOut[] が立たない" {
  local a seam
  a="$(sq_args '{}')"
  for seam in 'CQ_THROW_AT_LABEL=verify:' 'CQ_BUDGET_THROW_AT=5' 'CQ_AGENT_CAP=5'; do
    echo "# seam: $seam"
    run env CQ_ARGS="$a" CQ_REVIEW_FINDINGS="$FINDING_MINOR" CQ_VERIFY_REFUTED=true "$seam" \
        timeout "$WALL" node "$DRIVER" run
    assert_finite_return
    # 非空虚性: seam は実際に駆動されている（capExceeded が立つ）。立たなければ「何も起きない run」で
    # timedOut=0 は空虚に通る。
    [ "$(kval "$output" capExceeded)" = "true" ]
    # 弁別: 即 settle する失敗は timeout ではない。
    [ "$(rjson "$output" 'r.timedOut.length')" -eq 0 ]
  done
}

# ── H-D2 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=H-D1 の弁別が空虚でない（stuck 判定を広げれば timedOut は実際に立つ）
#          | polarity=negative（driver 側の変異）
#          | mutant_fingerprint=driver の `STUCK_AT_LABEL && label.startsWith(STUCK_AT_LABEL)` →
#            `label.startsWith("verify:")`（knob 無視で常時 stuck 化）
@test "sc-foqe H-D2: stuck 判定を広げれば timedOut は立つ（H-D1 の弁別の非空虚性）" {
  local mut="$BATS_TEST_TMPDIR/mu-d2"
  mkdir -p "$mut/workflows" "$mut/tests"
  cp "$WF" "$mut/workflows/cell-quality.workflow.js"
  sed 's|STUCK_AT_LABEL \&\& label.startsWith(STUCK_AT_LABEL)|label.startsWith("verify:")|' \
      "$DRIVER" > "$mut/tests/driver.mjs"
  assert_differs "$DRIVER" "$mut/tests/driver.mjs"

  # CQ_STUCK_AT_LABEL を渡していないのに（＝knob 未設定なのに）verify 段が stuck 化する変異木。
  run env CQ_ARGS="$(sq_args '{}')" CQ_REVIEW_FINDINGS="$FINDING_MINOR" CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  [ "$(rjson "$output" 'r.timedOut.length')" -gt 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-E] limiter 不変条件: timeout は limiter thunk の内側（スロットを恒久リークさせない）
# ─────────────────────────────────────────────────────────────────────────────

# ── H-E1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=maxConcurrency=1（スロット 1 本）で 1 agent が stuck しても、timeout でスロットが解放され
#            後続 agent（同 round の残り観点・次 round）が起動できる。timeout するのは **stuck 観点だけ**
#            （round ごとに 1 本＝2 round で 2 本）で、巻き添えの timeout が出ない
#          | polarity=positive
#          | mutant_fingerprint=WF の `opusLimiter(() => withAgentTimeout(opts, () => roAgent(prompt, opts)))` →
#            `withAgentTimeout(opts, () => opusLimiter(() => roAgent(prompt, opts)))`（timeout を limiter の外へ）
#            → スロットが恒久リークし後続も全て timeout（実測 2 → 8 件・他観点まで巻き添え）→ RED
#          | 実測（node v18.19.1 / maxConcurrency=1・maxRounds=2）: HEAD=2 件（review:correctness r1/r2 のみ）/
#            mutant=8 件（全 4 観点 × 2 round）
@test "sc-foqe H-E1: timeout 後も後続 agent が起動できる（limiter スロットを恒久リークさせない）" {
  local a
  a="$(hq_args '{"maxConcurrency":1,"maxRounds":2}')"

  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  # スロットは解放され、timeout したのは stuck 観点だけ（round ごとに 1 本＝2 round で 2 本）。
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 2 ]
  # 巻き添えゼロ: timedOut[] の label が全て stuck 観点（他観点は 1 本も timeout していない）。
  [ "$(rjson "$output" 'r.timedOut.every((t) => t.label.startsWith("review:correctness"))')" = "true" ]
  # 同 round の後続観点が起動している（callSeq に stuck より後の label が在る）。
  local seq
  seq="$(kval "$output" callSeq)"
  [[ "$seq" == *'review:completeness-critic r1'* ]]
  # 次 round も回っている（timeout 後も fan-out が生きている＝「1 本の hang で全体が止まる」の否定）。
  [[ "$seq" == *'review:completeness-critic r2'* ]]
  [ "$(kval "$output" rounds)" -eq 2 ]
  # opus limiter が実際に effective だった run であること（非空虚性＝limiter 不在なら本 tooth は空虚に通る）。
  [ "$(rjson "$output" 'r.opusCapped')" = "true" ]
  [ "$(rjson "$output" 'r.maxConcurrency')" -eq 1 ]
}

# ── H-E2（非空虚性・変異注入）───────────────────────────────────────────────
# inventory: invariant=timeout を limiter の **外**へ出すとスロットが恒久リークし、後続 agent も全て timeout する
#          | polarity=negative
#          | mutant_fingerprint=上記 H-E1 の fingerprint と同一（内側→外側の入れ替え）
@test "sc-foqe H-E2: timeout を limiter の外へ出すとスロットが恒久リークする（H-E1 の非空虚性）" {
  local mut="$BATS_TEST_TMPDIR/mu-e2"
  plant_wf_mutant "$mut" \
      'opusLimiter(() => withAgentTimeout(opts, () => roAgent(prompt, opts)))' \
      'withAgentTimeout(opts, () => opusLimiter(() => roAgent(prompt, opts)))'

  run env CQ_ARGS="$(hq_args '{"maxConcurrency":1,"maxRounds":2}')" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  # スロットが返らないので、後続の agent も自分の timeout でしか進めない＝stuck 以外の観点まで timeout する
  # （H-E1 の「巻き添えゼロ」assert が RED へ flip する形）。実測 8 件（全 4 観点 × 2 round）。
  [ "$(rjson "$output" 'r.timedOut.length')" -gt 2 ]
  [ "$(rjson "$output" 'r.timedOut.every((t) => t.label.startsWith("review:correctness"))')" = "false" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-F] 静的 guard: WF に禁止 clock API が 0 hit
# ─────────────────────────────────────────────────────────────────────────────

# ── H-F1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=workflows/cell-quality.workflow.js に Date.now( / 引数なし new Date() / Math.random( が
#            0 hit（harness の vm は resume 決定性のためこれらを throw させる。静的 lint は inline script 経路
#            でしか走らず scriptPath 直指定経路では launch 前に弾かれないので repo 側で pin する）
#          | polarity=positive（0 hit を assert）
#          | mutant_fingerprint=変異木へ `Date.now()` を植えると同じ grep が hit する（同一 tooth 内で実走）
#          | 注: setTimeout / clearTimeout は **禁止対象に含めない**（vm context へ露出＝本 leg の主機構）
@test "sc-foqe H-F1: WF に Date.now( / 引数なし new Date() / Math.random( が 0 hit（vm 禁止 API の静的 guard）" {
  [ -x "$GREP" ]

  # file-arg grep（pipefail 下の `producer | grep -q` を使わない）。否定 assert は `! grep` で書かない
  # （bats では `!` 反転の失敗が set -e を発火させず **空虚 green** になる・本 file 冒頭の規律参照）。
  # 【0 hit はコメントも含む】guard は literal grep ゆえ、説明コメント中に書いても hit する。
  assert_no_match "$WF" -F 'Date.now('
  assert_no_match "$WF" -E 'new[[:space:]]+Date\([[:space:]]*\)'
  assert_no_match "$WF" -F 'Math.random('

  # 非空虚性: 同じ grep が植えた違反を実際に検出することを同一 tooth で示す（grep が常に空振りする
  # 書き方＝空虚 green になっていないことの確認）。
  local mut="$BATS_TEST_TMPDIR/mu-f1"
  mkdir -p "$mut"
  sed 's|const timedOut = \[\]|const timedOut = []; const __mut = Date.now() + Math.random(); const __d = new Date()|' \
      "$WF" > "$mut/wf.js"
  assert_differs "$WF" "$mut/wf.js"
  assert_match "$mut/wf.js" -F 'Date.now('
  assert_match "$mut/wf.js" -E 'new[[:space:]]+Date\([[:space:]]*\)'
  assert_match "$mut/wf.js" -F 'Math.random('

  # 主機構（vm へ露出している timer API）は禁止対象ではない＝実在することを対で pin する
  # （「clock API を全部消した」形の過剰適用で timeout 機構ごと消える退行を検出する）。
  assert_match "$WF" -F 'setTimeout('
  assert_match "$WF" -F 'clearTimeout('
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-G] 上限秒が決め打ちでない（args で上書き可・0 = 明示 opt-out）
# ─────────────────────────────────────────────────────────────────────────────

# ── H-G1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=per-agent 上限は args.agentTimeoutMs で上書きでき、返り値 agentTimeoutMs に実効値が載る。
#            0 は明示 opt-out（timeout 無効）で、同じ模擬が hang する＝上限が決め打ちでないことの behavioral 証拠
#          | polarity=positive（上書きが実効）+ negative（0 で機構が止まる）
#          | mutant_fingerprint=WF の `const raw = A.agentTimeoutMs` → `const raw = undefined`（args を無視して
#            常に既定へ倒す＝決め打ち化）→ opt-out が効かず rc≠124 になり RED（H-G2 が実走で確認）
@test "sc-foqe H-G1: per-agent 上限は args.agentTimeoutMs で上書き可（0 = 明示 opt-out で hang する）" {
  # (a) 上書きが実効: 別値を渡すと返り値へその値が載り、timedOut[].timeoutMs も一致する。
  local other=$((TMO + 111))
  run env CQ_ARGS="$(hq_args "{\"agentTimeoutMs\":${other}}")" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(rjson "$output" 'r.agentTimeoutMs')" -eq "$other" ]
  [ "$(rjson "$output" 'r.timedOut[0].timeoutMs')" -eq "$other" ]

  # (b) 0 = 明示 opt-out: 機構が止まり、同じ模擬で有限時間 return しない（rc exact 124 / RESULT 行なし）。
  run env CQ_ARGS="$(hq_args '{"agentTimeoutMs":0}')" CQ_STUCK_AT_LABEL='review:correctness' \
      CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$HANG_WALL" node "$DRIVER" run
  [ "$status" -eq 124 ]
  [[ "$output" != *'RESULT {'* ]]

  # (c) 不正値は fail-safe で **既定値へ** 倒し、silent に 0（無効）へ倒さない。
  # 【rc=124 では証明にならない】不正値を 0 へ倒した実装でも同じ模擬は hang して rc=124 になるため、
  # 「hang したこと」は『既定へ倒した』の証拠にならない（主張過大）。実効値そのものを返り値から読んで
  # **未指定（既定）の run と一致すること**を比較で pin する（既定値の literal も焼かない）。
  # stuck を注入しない run にするのは、実効値だけを読むのに timeout を待つ必要が無いため。
  run env CQ_ARGS="$(hq_args '{"agentTimeoutMs":null}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  local dflt
  dflt="$(rjson "$output" 'r.agentTimeoutMs')"
  [ "$dflt" -gt 0 ] # 未指定は「timeout 無効」ではない（既定で機構が生きている）

  run env CQ_ARGS="$(hq_args '{"agentTimeoutMs":"soon"}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(rjson "$output" 'r.agentTimeoutMs')" -eq "$dflt" ] # 不正値 → 既定へ（0 へ倒していたらここで RED）

  # 負値も同じく既定へ倒す（0 と負値を混同して無効化しない）。
  run env CQ_ARGS="$(hq_args '{"agentTimeoutMs":-1}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(rjson "$output" 'r.agentTimeoutMs')" -eq "$dflt" ]

  # (d) 非空虚性（変異）: 不正値を 0（無効）へ倒す実装にすると (c) が RED へ flip する。
  local mut="$BATS_TEST_TMPDIR/mu-g1"
  plant_wf_mutant "$mut" 'return AGENT_TIMEOUT_MS_DEFAULT$' 'return 0'
  run env CQ_ARGS="$(hq_args '{"agentTimeoutMs":"soon"}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  [ "$(rjson "$output" 'r.agentTimeoutMs')" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-H] 既定 no-op: knob 未設定なら timeout 表面は一切立たない
# ─────────────────────────────────────────────────────────────────────────────

# ── H-H1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=CQ_STUCK_AT_LABEL 未設定の通常 run では timedOut[]=[] かつ gate へ timeout 注記が載らない
#            （新機構が既定路の終端・注記面を汚さない）
#          | polarity=positive
#          | mutant_fingerprint=WF の timeoutNote 三項を無条件文字列へ（`timedOut.length ?` → `true ?`）→
#            既定 run の gate に注記が載り RED
@test "sc-foqe H-H1: stuck 未注入の通常 run では timedOut[]=[] で gate に timeout 注記が載らない" {
  run env CQ_ARGS="$(hq_args '{}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [ "$(rjson "$output" 'r.timedOut.length')" -eq 0 ]
  [[ "$(rjson "$output" 'r.gate')" != *'per-agent timeout='* ]]

  # 非空虚性（変異）: 注記を無条件化すると既定 run にも載る。
  local mut="$BATS_TEST_TMPDIR/mu-h1"
  plant_wf_mutant "$mut" 'const timeoutNote = timedOut.length' 'const timeoutNote = true'
  run env CQ_ARGS="$(hq_args '{}')" CQ_REVIEW_FINDINGS='[]' CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  [[ "$(rjson "$output" 'r.gate')" == *'per-agent timeout='* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-I] 本 file 自身の assert 規律（空虚 green の構造封鎖）
# ─────────────────────────────────────────────────────────────────────────────

# ── H-I1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=本 file は否定 assert を `! cmd` で書かない（bats では `!` 反転の失敗が set -e を
#            発火させず、その行は **常に通る**＝空虚 green になる。本 host Bats 1.13.0 で `! true` が ok に
#            なることを実測。POSIX の「`!` で反転されたコマンドに -e は適用しない」規定どおり）
#          | polarity=positive（0 hit を assert）
#          | mutant_fingerprint=本 file へ `  ! true` 行を植えた copy で同じ grep が hit する（同一 tooth 内で実走）
#          | 申し送り: 既存 cell-quality 系 bats / wf-args-lint にも `! cmp -s` / `! grep -q` 形が在り同じ空虚性を
#            持つ。本 cell の編集可スコープ外ゆえ触らず、bd sc-foqe notes へ admin 起票候補として記録した。
# 【@test 名に backtick を書かない】bats は test description を shell の word として評価するため、backtick が
# command substitution として実行される（実測: 本 tooth 名に含めていた時、TAP のテスト名から当該 literal が
# 消え、`cmd: command not found` が 1 tooth につき 2 回 stderr へ出た）。以降 @test 名では引用符を使う。
@test "sc-foqe H-I1: 本 file は否定 assert を '! cmd' 形で書かない（bats で空虚 green になる形の封鎖）" {
  [ -x "$GREP" ]
  # 行頭（インデント可）の `!` 反転コマンド = 空虚 assert の形。
  assert_no_match "$BATS_TEST_FILENAME" -E '^[[:space:]]*![[:space:]]*[A-Za-z_"$]'

  # 非空虚性: 同じ grep が植えた違反を実際に検出する。
  local mut="$BATS_TEST_TMPDIR/mu-i1.bats"
  { cat "$BATS_TEST_FILENAME"; printf '\n@test "planted" {\n  ! true\n}\n'; } > "$mut"
  assert_differs "$BATS_TEST_FILENAME" "$mut"
  assert_match "$mut" -E '^[[:space:]]*![[:space:]]*[A-Za-z_"$]'
}

# ─────────────────────────────────────────────────────────────────────────────
# [H-J] timeout 例外が **agent 生成テキストで制御フローを分岐させない**（cap 誤分類の封鎖）
#
# 動機: verify 段の label は `verify:<dim>:<shortTitle(f)> r<N>`＝review agent が書いた finding title の
# 先頭 32 字を含む**自由文**（WF が内容を制御しない）。この label を timeout 例外の message へ内挿すると、
# title に cap 指紋語（budget exceeded / token budget / agent cap / agent limit / exceeded the agent）が
# 入った run で capClassify が timeout を cap 例外へ再分類し、(a) CAP_ON では capRoundGate の早期打切りで
# autoFix loop の round が削られ、(b) capReport へ「budget 枯渇で blocking を落とした」という事実に反する
# 記録が焼かれる。H-A1/H-A2 の capExceeded=false は title="MMM"（指紋なし）でしか回っておらず、この
# 不変条件を pin できていない（データ依存の green）ので専用 tooth を置く。
# ─────────────────────────────────────────────────────────────────────────────

# ── H-J1 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=finding title に cap 指紋語が入っていても timeout は cap へ誤分類されず、cap 面
#            （capExceeded / capReason / capStages / capDropped）が 1 mm も汚れない。かつ CAP_ON の loop で
#            round 数が指紋なし対照と一致する（agent 生成テキストが制御フローを分岐させない）
#          | polarity=positive（対照 = 同一 args・指紋なし title の run＝同一 tooth 内で実走して比較）
#          | mutant_fingerprint=timeout 例外の message へ label を戻す
#            （`within ${ms}ms — sc-foqe` → `within ${ms}ms (label=${label}) — sc-foqe`）→ 指紋 title の run で
#            capExceeded=true / capReason=quota|error / rounds が 3→1 へ落ちて RED（H-J2 が実走で確認）
@test "sc-foqe H-J1: finding title の cap 指紋語で timeout が cap 誤分類されない（cap 面と round 数が対照と一致）" {
  local a base_rounds t
  # CAP_ON（totalBudget 指定）+ 複数 round の loop 形＝capRoundGate の早期打切りが観測できる唯一の構成。
  # totalBudget は十分大きく取り、**真の cap は起きない**（cap 面が立てば誤分類由来だと言い切れる）。
  a="$(hq_args '{"maxRounds":3,"totalBudget":200}')"

  # 対照: cap 指紋語を含まない title。ここで rounds>1 であることが本 tooth の非空虚性の前提
  # （1 round しか回らない構成では round 喪失を検出できない）。
  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$(finding_titled '境界条件の誤り')" CQ_VERIFY_REFUTED=false \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  base_rounds="$(kval "$output" rounds)"
  [ "$base_rounds" -gt 1 ]
  [ "$(kval "$output" capExceeded)" = "false" ]

  # 本番: title だけを cap 指紋語入りへ差し替える（他の args / env は 1 byte も変えない）。
  for t in 'token budget の扱い' 'agent cap の誤分類' 'budget exceeded の再現'; do
    echo "# title: $t"
    run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='verify:correctness' \
        CQ_REVIEW_FINDINGS="$(finding_titled "$t")" CQ_VERIFY_REFUTED=false \
        timeout "$WALL" node "$DRIVER" run
    assert_finite_return
    # 非空虚性: 当該 run で timeout が実際に起きている（起きていなければ cap 面が綺麗なのは空虚）。
    [ "$(rjson "$output" 'r.timedOut.length')" -gt 0 ]
    # cap 面が汚れない（timeout は machinery 失敗であって cap ではない）。
    [ "$(kval "$output" capExceeded)" = "false" ]
    [ "$(kval "$output" capReason)" = "<empty>" ]
    [ "$(kval "$output" capStagesCount)" -eq 0 ]
    [ "$(kval "$output" capDroppedCount)" -eq 0 ]
    # 制御フローが title に依存しない（capRoundGate の早期打切りで round が削られていない）。
    [ "$(kval "$output" rounds)" -eq "$base_rounds" ]
    # gate 文へ偽の cap 注記が載らない（capNote は cap 発火時のみ）。
    [[ "$(rjson "$output" 'r.gate')" != *'cap 発火'* ]]
  done
}

# ── H-J2（非空虚性・変異注入）───────────────────────────────────────────────
# inventory: invariant=timeout 例外の message へ label（＝自由文 title を含む）を内挿すると H-J1 が RED へ flip する
#          | polarity=negative
#          | mutant_fingerprint=`within ${ms}ms — sc-foqe per-agent timeout` →
#            `within ${ms}ms (label=${label}) — sc-foqe per-agent timeout`
#          | 実測（node v18.19.1・maxRounds=3 / totalBudget=200）: mutant で title='token budget の扱い' は
#            rounds=1 / capExceeded=true / capReason=quota / capStagesCount=1 / capDroppedCount=4、
#            title='agent cap の誤分類' は capReason=error。指紋なし対照は rounds=3 / capExceeded=false のまま
@test "sc-foqe H-J2: message へ label を内挿すると指紋 title の run が cap へ誤分類される（H-J1 の非空虚性）" {
  local mut a
  mut="$BATS_TEST_TMPDIR/mu-j2"
  plant_wf_mutant "$mut" \
      'within ${ms}ms — sc-foqe per-agent timeout' \
      'within ${ms}ms (label=${label}) — sc-foqe per-agent timeout'
  a="$(hq_args '{"maxRounds":3,"totalBudget":200}')"

  # 変異木でも指紋なし title なら健全（＝変異が「timeout 機構を壊した」のではなく「文言だけを戻した」ことの確認）。
  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$(finding_titled '境界条件の誤り')" CQ_VERIFY_REFUTED=false \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  [ "$(kval "$output" capExceeded)" = "false" ]
  [ "$(kval "$output" rounds)" -eq 3 ]

  # 同一 args で title だけを 'token budget' 入りへ替えると cap 面が捏造され、round が削られる。
  run env CQ_ARGS="$a" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$(finding_titled 'token budget の扱い')" CQ_VERIFY_REFUTED=false \
      timeout "$WALL" node "$mut/tests/driver.mjs" run
  assert_finite_return
  [ "$(kval "$output" capExceeded)" = "true" ]
  [ "$(kval "$output" capReason)" = "quota" ]
  [ "$(kval "$output" rounds)" -eq 1 ]
}

# ── H-J3 ─────────────────────────────────────────────────────────────────────
# inventory: invariant=timeout 例外の message は **固定文言**（label / 自由文を内挿しない）で、診断用の label は
#            非 message プロパティ（e.agentLabel）と timedOut[] に載る＝観測面を失わずに分類面だけを守る
#          | polarity=positive（静的 0 hit + 動的 message 実体の 2 面）
#          | mutant_fingerprint=H-J2 と同じ内挿を戻すと同じ grep が hit する（同一 tooth 内で実走）
@test "sc-foqe H-J3: timeout 例外 message は固定文言（label 内挿なし）で、label は e.agentLabel / timedOut[] に載る" {
  [ -x "$GREP" ]
  # 静的: makeAgentTimeoutError の message へ label を内挿していない。
  assert_no_match "$WF" -F 'ms (label=${label})'
  # 静的: 診断用の非 message プロパティは在る（「label を単に消した」だけの過剰適用で観測面が消える退行の検出）。
  assert_match "$WF" -F 'e.agentLabel'

  # 非空虚性: 内挿を戻した copy では同じ grep が hit する。
  local mut="$BATS_TEST_TMPDIR/mu-j3"
  plant_wf_mutant "$mut" \
      'within ${ms}ms — sc-foqe per-agent timeout' \
      'within ${ms}ms (label=${label}) — sc-foqe per-agent timeout'
  assert_match "$mut/workflows/cell-quality.workflow.js" -F 'ms (label=${label})'

  # 動的: timeout が立った run でも label は timedOut[] から読める（診断性は失われていない）。
  run env CQ_ARGS="$(sq_args '{}')" CQ_STUCK_AT_LABEL='verify:correctness' \
      CQ_REVIEW_FINDINGS="$(finding_titled 'token budget の扱い' 'minor')" CQ_VERIFY_REFUTED=true \
      timeout "$WALL" node "$DRIVER" run
  assert_finite_return
  [[ "$(rjson "$output" 'r.timedOut[0].label')" == *'token budget'* ]]
  [ "$(kval "$output" capExceeded)" = "false" ]
}

#!/usr/bin/env bats
# mandate-verify.workflow.js（sc-ihdy・orch-u3fk relay）の凍結骨格 pin。
#
# WF script は top-level return / export を持つため raw では node --check 不可（cell-quality driver ヘッダ参照）。
# 本 bats は Workflow tool の wrapping を再現する AsyncFunction compile で構文を固定し、
# 骨格の構造不変条件（read-only 構造強制・model 明示・fail-closed・run 識別 log・args 形の文書化）を grep で pin する。
# 負論理 pin は `!` 前置でなく run + 明示 assert 形で書き、mutation probe で pin 自身の非空虚性も固定する
# （sc-ihdy gate B1-B3: `!` 前置の中間コマンドは bats の失敗検知から免除され pin が silent no-op 化する・実測 verified）。
# fail-fast/args-parse は pure ロジックゆえ AsyncFunction compile + stub agent の behavioral probe で実挙動を pin する
# （gate r2: grep pin は guard 節除去を検知できない——pin 文字列は reason 文面にも出現するため・実測 verified）。
# lens/synthesize の substantive な実挙動（実 agent での催行）は運用 run が検証面（5 run 実証済みの凍結）。

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/mandate-verify.workflow.js"
}

@test "sc-ihdy: AsyncFunction wrap で compile が通る（Workflow tool wrapping の再現・構文 pin）" {
  run node -e '
    const { readFileSync } = require("node:fs");
    const src = readFileSync(process.argv[1], "utf8").replace(/^export /m, "");
    const AsyncFunction = (async () => {}).constructor;
    new AsyncFunction("args","agent","parallel","pipeline","phase","log","budget","workflow", src);
    console.log("COMPILE-OK");
  ' "$WF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPILE-OK"* ]]
}

@test "sc-ihdy: meta が name/whenToUse を持ち args 形（targetBead/lenses）を文書化している（bead 検証行の実体）" {
  grep -q "name: 'mandate-verify'" "$WF"
  grep -q "whenToUse:" "$WF"
  # whenToUse に args 形が載る（orch-u3fk の bead 検証行「meta.whenToUse に args 形が記載」）
  grep -q "targetBead: 対象 bead id（必須）" "$WF"
  grep -q "lenses: \[{key, q}\]（必須" "$WF"
}

@test "sc-ihdy: 全 agent 呼び出しが model 明示（既定 opus）＝fable 継承のコスト事故封鎖" {
  # MODEL 既定が opus（admin main-loop=fable のセッションでも WF agent は継承しない）
  grep -q "A.model === 'string' && A.model.trim()) || 'opus'" "$WF"
  # roAgent の内部実装（RO_DISCIPLINE 前置 or agentType 注入の 3 呼出し）以外に素の agent( 呼出しが無い＝
  # unguarded agent( の再混入（fable 継承・read-only 迂回）を封鎖する。
  # 注意: `!` 前置の中間コマンドは bats(set -e) の失敗検知から免除され pin が no-op 化する（sc-ihdy gate
  # B1-B3・実測 verified）ため、run + 明示 assert 形で書く。regex は roAgent( を語境界で除外する。
  run bash -c 'grep -nE "(^|[^a-zA-Z])agent\(" "$1" | grep -vE "RO_DISCIPLINE|agentType: RO_AGENT_TYPE"' _ "$WF"
  [ -z "$output" ]
  # 全 agent 呼出しサイトが model: MODEL を明示（Verify lens + Synthesize の 2 サイト）
  [ "$(grep -c "model: MODEL" "$WF")" -ge 2 ]
}

@test "sc-ihdy: model 明示 pin は rogue agent( 追加を実際に検知する（pin の非空虚性・mutation probe）" {
  # gate B1-B3 の教訓: pin は「違反を実際に検知できるか」まで固定しないと filter drift で silent no-op 化する。
  TMP="$BATS_TEST_TMPDIR/wf-rogue.js"
  cp "$WF" "$TMP"
  printf '\nawait agent("x", { label: "rogue" })\n' >> "$TMP"
  run bash -c 'grep -nE "(^|[^a-zA-Z])agent\(" "$1" | grep -vE "RO_DISCIPLINE|agentType: RO_AGENT_TYPE"' _ "$TMP"
  [ -n "$output" ]
  [[ "$output" == *rogue* ]]
}

@test "sc-ihdy: read-only 構造強制（scribe:explore 既定 + RO-FALLBACK 降格 + none 強制）が骨格にある" {
  grep -q "RO_AGENT_TYPE = _rawRoAgentType || 'scribe:explore'" "$WF"
  grep -q "RO_FORCE_NONE = RO_AGENT_TYPE === 'none'" "$WF"
  grep -q "\[RO-FALLBACK\]" "$WF"
  grep -q "RO_DISCIPLINE" "$WF"
}

@test "sc-ihdy: fail-closed の 4 経路（args 不備 / 不正形 lens 混入 / 全 lens 欠損 / 部分欠損 verdict 倒し）が骨格にある" {
  # (1) 必須 args 欠落は agent を起動せず escalate
  grep -q "必須 args 欠落" "$WF"
  # (2) 不正形 lens の混入は drop せず fail-fast（検証軸の黙殺=false-OK 経路の封鎖・gate B4）
  grep -q "lenses に不正形が" "$WF"
  grep -q "droppedLenses > 0" "$WF"
  # (3) 全 lens 欠損は Synthesize を回さず NEEDS-FIX
  grep -q "全 lens が欠損" "$WF"
  # (4) 部分欠損は Synthesize prompt で fail-closed へ倒す指示
  grep -q "fail-closed（NEEDS-FIX 側）に倒せ" "$WF"
}

@test "sc-ihdy: run 識別 log（args 解決直後・targetBead 束縛）がある（同名 WF 並走の識別手段）" {
  grep -q 'mandate-verify: lenses=' "$WF"
}

@test "sc-ihdy: defensive args parse（string 到達の JSON.parse 吸収 + receivedArgs 一次監査）がある" {
  grep -q "typeof args === 'string'" "$WF"
  grep -q "receivedArgs" "$WF"
  grep -q "parseFailed" "$WF"
}

@test "sc-ihdy: B4 fail-fast の behavioral probe（不正形 lens 混入→agent 未起動 escalate / 全 valid→過剰発火なし）" {
  # gate r2 blocking: grep pin は guard 節（|| droppedLenses > 0）の除去回帰を検知できない——pin 文字列は
  # reason 文面（ternary/message）にも出現し guard を落としても grep が拾い続けるため。fail-fast は pure
  # ロジック（agent 不要）なので AsyncFunction compile + stub agent で実挙動を両方向 pin する。
  cat > "$BATS_TEST_TMPDIR/b4probe.js" <<'JS'
const { readFileSync } = require("node:fs");
const src = readFileSync(process.argv[2], "utf8").replace(/^export /m, "");
const AsyncFunction = (async () => {}).constructor;
const fn = new AsyncFunction("args","agent","parallel","pipeline","phase","log","budget","workflow", src);
let agentCalls = 0;
const agent = async () => { agentCalls++; return "## [minor] probe\nverdict: OK"; };
const parallel = async (thunks) => Promise.all(thunks.map((t) => t().catch(() => null)));
const noop = () => {};
fn(JSON.parse(process.argv[3]), agent, parallel, null, noop, noop, null, null).then((r) => {
  console.log(JSON.stringify({ escalate: !!(r && r.escalate), agentCalls, lensCount: r ? r.lensCount : null }));
});
JS
  # (a) 1 valid + 1 malformed（key 空）→ fail-fast: escalate=true・agent 未起動（silent drop 回帰＝B4 の検知）
  run node "$BATS_TEST_TMPDIR/b4probe.js" "$WF" '{"anchor":"/tmp/x","targetBead":"sc-probe","lenses":[{"key":"a","q":"q1"},{"key":"","q":"q2"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"escalate":true,"agentCalls":0,"lensCount":0}' ]
  # (b) 全 valid → 過剰発火なし: escalate=false・lens 2 + synthesize 1 = agent 3 呼出し・lensCount=2
  run node "$BATS_TEST_TMPDIR/b4probe.js" "$WF" '{"anchor":"/tmp/x","targetBead":"sc-probe","lenses":[{"key":"a","q":"q1"},{"key":"b","q":"q2"}]}'
  [ "$status" -eq 0 ]
  [ "$output" = '{"escalate":false,"agentCalls":3,"lensCount":2}' ]
}

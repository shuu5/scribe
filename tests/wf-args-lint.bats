#!/usr/bin/env bats
# tests/wf-args-lint.bats — WF args preamble lint（sc-4t3t / L0a）の teeth。
#
# 対象: scripts/scribe-wf-args-lint.sh（wrapper）+ scripts/lib/wf-args-probe.mjs（判定本体）
#       + workflows/lib/args-preamble.snippet.js（canonical SSOT）
#
# ■ 非空虚性の規律（notes ■7）
#   - skip を 1 つも使わない（依存不在は skip でなく fail させる存在確認 tooth を置く＝T1）。
#   - RED 判定は「status が 0 でない」で書かない。rc の exact 一致（違反=1 / 判定不能=2）と stdout の
#     違反 ID marker 一致の AND で assert する。engine 不在の 127 / 非実行ビットの 126 を RED 扱いしない
#     tooth を置く（T7）。
#   - 各 tooth に assertion inventory row（invariant / polarity / mutant_fingerprint）を併記する。
#   - grep は /usr/bin/grep をフルパス固定（不在なら fail-loud）。pipefail 下の `producer | grep -q` は
#     使わない（SIGPIPE で rc=141 の偽 RED になる・protocol §2）。substring 判定は bats の $output で行う。
#
# ■ rc と hook exit code は同一でない
#   本 bats が assert するのは **engine の rc**（0=合格/対象外 / 1=違反 / 2=判定不能）であって、
#   PreToolUse hook の exit code（0=通過 / 2=deny）ではない。Phase1(warn)→Phase2(deny) への写像
#   （とくに rc=2 をどちらへ倒すか）は後続の hook wire leg の責務で、本 leg では未裁定。
#
# ■ byte-pin の位置づけ（notes ■9・■追補 P0-2 帰結）
#   主 = 挙動 probe（必須 args 欠落で agentCalls=0 のまま run が非 0 で死ぬ、という不変条件）。
#        + positive control（正常 args では throw せず agent が起動する = 対の不変条件・T21）。片側だけ pin すると
#          「args と無関係に常に throw する preamble」＝全 run を殺す壊れた fail-fast が合格する。
#   従 = SCARGS marker + sha256 の byte-pin（drift 検知のみ・invariant を守る力は無い）。
#   波0 は複製先が無いので snippet 単体の self-pin と marker literal 固定に限定する。
#   複製照合（骨格 3 本の block が canonical と byte 一致すること）の有効化は波1（sc-k33c 項目6）。
#   【TS 化で無効】orch-lxgy v3 compile 後、本 byte-pin は意味を失う → 挙動 probe 側へ一本化して撤去する。
#
# ■ 骨格判定の 2 面（notes ■1）
#   (A) legacy = 「その骨格が必須 args を要求するモードで、宣言必須 args を欠く args を渡すと agentCalls=0」。
#       probe args は骨格ごとに verbatim 固定（空 object の一律適用は false-RED ゆえ禁止）。
#   (B) canonical = P0-2（欠落・undefined・空・"[undefined]" で即 throw）では 3 骨格は**現状 RED が正**。
#       skip/xfail で書かず EXPECTED_CANONICAL_RED の集合一致 assert として焼く。波1 が throw 形へ置換した
#       瞬間に本 tooth が RED になり気づける向き（＝設計上の tripwire・退行ではない）。

bats_require_minimum_version 1.5.0 # `run -126` / `run -127`（期待 exit code 指定）を使うため

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  ENGINE="$REPO_ROOT/scripts/scribe-wf-args-lint.sh"
  PROBE="$REPO_ROOT/scripts/lib/wf-args-probe.mjs"
  SNIPPET="$REPO_ROOT/workflows/lib/args-preamble.snippet.js"
  GREP=/usr/bin/grep

  # canonical block の self-pin（snippet を 1 byte でも動かせば RED になる drift 検知）。
  # 更新手順: 意図した改訂なら `node tests-helper block-sha` 相当の出力（下の helper）で貼り直す。
  SELF_PIN_SHA256="67602a094a1f3c3eeaeaf0ad1d735640a8e8b3db3752985085ee7685c2ce699d"

  # 骨格別 legacy probe args（notes ■1 の verbatim 固定表 = bats 側の legacy allowlist。
  # engine に固定 path をハードコードしない＝表は呼出元が持つ）。
  SKEL_CELL_QUALITY="$REPO_ROOT/workflows/cell-quality.workflow.js"
  SKEL_MANDATE_VERIFY="$REPO_ROOT/workflows/mandate-verify.workflow.js"
  SKEL_NEEDS_USER="$REPO_ROOT/workflows/needs-user-prebake.workflow.js"
  ARGS_CELL_QUALITY='{"doImplement":true}'
  ARGS_MANDATE_VERIFY='{}'
  ARGS_NEEDS_USER='{}'

  FIX="$BATS_TEST_TMPDIR/fx"
  mkdir -p "$FIX"

  # probe timeout の検査に使う秒数。engine 側と同じく決め打ちにせず env で上書きできる形にする
  # （notes fence「数値決め打ち禁止（timeout 秒数等は args/env 化）」）。
  PROBE_TIMEOUT="${SC4T3T_BATS_PROBE_TIMEOUT:-2}"

  # helper: engine 自身の抽出関数で canonical block を取り出す（block 定義を bats 側に二重化しない）。
  HELPER="$BATS_TEST_TMPDIR/block-helper.mjs"
  cat > "$HELPER" <<'HELPER_EOF'
import { readFileSync } from 'node:fs'
const probe = await import(process.argv[2])
const src = readFileSync(process.argv[3], 'utf8')
const b = probe.extractMarkerBlock(src)
if (!b.present || b.malformed) {
  process.stderr.write(`marker block 不正: present=${b.present} malformed=${b.malformed} starts=${b.starts} ends=${b.ends}\n`)
  process.exit(3)
}
if (process.argv[4] === 'sha') process.stdout.write(probe.sha256(b.block) + '\n')
else if (process.argv[4] === 'lines') process.stdout.write(String(b.block.split('\n').length) + '\n')
else process.stdout.write(b.block + '\n')
HELPER_EOF
}

emit_block() { node "$HELPER" "$PROBE" "$SNIPPET" block; }
block_sha() { node "$HELPER" "$PROBE" "$SNIPPET" sha; }

# 準拠 fixture（canonical 合格形）: 二面宣言 + canonical block verbatim + その後に agent 呼出。
mk_good() {
  {
    printf "export const meta = {\n  name: 'fx-good',\n  requiredArgs: ['anchor', 'targetBead'],\n}\n"
    printf "const REQUIRED_ARGS = ['anchor', 'targetBead']\n"
    emit_block
    printf "\nawait agent('work', { label: 'w' })\nreturn { ok: true, receivedArgs }\n"
  } > "$1"
}

# ── T1 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=依存(node/timeout/env/bwrap/engine/probe/snippet)の実在と engine の実行ビット
#          | polarity=positive
#          | mutant_fingerprint=`chmod -x scripts/scribe-wf-args-lint.sh` → 本 tooth が RED
@test "sc-4t3t T1: 依存の存在確認（不在は skip でなく fail させる＝skip 0 本の担保）" {
  [ -x "$GREP" ]
  run command -v node
  [ "$status" -eq 0 ]
  run command -v timeout
  [ "$status" -eq 0 ]
  run command -v env
  [ "$status" -eq 0 ]
  # bwrap は probe の追加封じ込め（notes ■10）の必須依存。不在ホストでは engine が全件 rc=2 に倒れる
  # ＝本 lint は bwrap 搭載ホストでのみ green（engine ヘッダに明記した読み）。skip で逃がさず fail させる。
  run command -v bwrap
  [ "$status" -eq 0 ]
  [ -x "$ENGINE" ]
  [ -f "$PROBE" ]
  [ -f "$SNIPPET" ]
}

# ── T2 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=canonical 準拠 script は rc=0（8 シナリオすべてで agentCalls=0 + throw）
#          | polarity=positive
#          | mutant_fingerprint=snippet block の `if (__scargsParseFailed || __scargsMissing.length > 0) {`
#            を `if (false) {` へ反転 → rc 0→1（VIOLATION AGENT_STARTED_BEFORE_FAILFAST）
@test "sc-4t3t T2: engine 単体 green — canonical 準拠 fixture は rc=0 / agentCalls=0 / bytePin=match" {
  mk_good "$FIX/good.workflow.js"
  run "$ENGINE" --mode skeleton --file "$FIX/good.workflow.js" --snippet "$SNIPPET" --label fx-good
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK fx-good"* ]]
  [[ "$output" == *"agentCalls=0"* ]]
  [[ "$output" == *"bytePin=match"* ]]
  # 病的形 4 種 × 必須 2 個 = 8 シナリオを実際に回していること（空回り green の封鎖）
  [[ "$output" == *"scenarios=8"* ]]
  [[ "$output" == *"summary: checked=1 skipped=0 violations=0 inconclusive=0"* ]]
}

# ── T3 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=fail-fast より前に agent() を起動する script は rc=1（違反 ID 一致）
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の `if (started.length > 0)` を `if (false)` へ → 本 tooth RED
@test "sc-4t3t T3: engine 単体 RED — agent 先行起動は rc exact 1 + VIOLATION AGENT_STARTED_BEFORE_FAILFAST" {
  {
    printf "export const meta = { name: 'fx-bad-agent', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "await agent('early', { label: 'early' })\n"
    emit_block
    printf "\nreturn { ok: true }\n"
  } > "$FIX/bad-agent.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/bad-agent.workflow.js" --label fx-bad-agent
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
}

# ── T4 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=病的 args を検出しても throw せず return する形は canonical では rc=1
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の `if (expect === 'canonical')` を `if (false)` へ → 本 tooth RED
@test "sc-4t3t T4: engine 単体 RED — escalate return 形（throw なし）は rc exact 1 + VIOLATION NO_THROW_ON_MISSING_ARGS" {
  cat > "$FIX/escalate.workflow.js" <<'EOF'
export const meta = { name: 'fx-escalate', requiredArgs: ['anchor'] }
const REQUIRED_ARGS = ['anchor']
const A = args && typeof args === 'object' && !Array.isArray(args) ? args : {}
const absent = (v) => {
  if (v === undefined || v === null) return true
  if (typeof v === 'string') { const t = v.trim(); return t === '' || t === 'undefined' || t === '[undefined]' }
  return false
}
if (REQUIRED_ARGS.some((k) => absent(A[k]))) {
  return { escalate: true, reason: '必須 args 欠落' }
}
await agent('work')
return { ok: true }
EOF
  run "$ENGINE" --mode adhoc --file "$FIX/escalate.workflow.js" --label fx-escalate
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION NO_THROW_ON_MISSING_ARGS"* ]]
  # 「agent が起動した」ではなく「throw しなかった」で落ちていること（違反 ID の取り違え封鎖）
  [[ "$output" != *"AGENT_STARTED_BEFORE_FAILFAST"* ]]
}

# ── T5 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=判定不能は rc=2 で表明され 0 に丸められない（宣言の静的動的不一致 / --mode 未指定）
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の DECL_MISMATCH 分岐を `requiredArgs = declBody || declMeta`
#            の救済へ書き換える（fail-open 化）→ 本 tooth RED
@test "sc-4t3t T5: rc=2 判定不能 — 片面宣言/集合不一致/--mode 未指定はすべて INCONCLUSIVE（0 に丸めない）" {
  printf "export const meta = { name: 'fx-decl', requiredArgs: ['anchor'] }\nconst A = args || {}\nreturn { A }\n" > "$FIX/decl-one-sided.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/decl-one-sided.workflow.js" --label fx-decl
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE DECL_MISMATCH"* ]]

  {
    printf "export const meta = { name: 'fx-set', requiredArgs: ['anchor', 'x'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    emit_block
    printf "\nreturn { ok: true }\n"
  } > "$FIX/decl-set.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/decl-set.workflow.js" --label fx-set
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE DECL_MISMATCH"* ]]

  run "$ENGINE" --file "$FIX/decl-set.workflow.js" --label fx-nomode
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE MODE_UNSET"* ]]
}

# ── T6 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=args 参照 0 hit の script は対象外（rc=0）だが黙って落とさず SKIP 行 + skipped=1 を出す
#          | polarity=positive
#          | mutant_fingerprint=wf-args-probe.mjs の `out.push(\`SKIP ...\`)` を削除 → 本 tooth RED
@test "sc-4t3t T6: 対象外の可視化 — args 参照 0 hit は rc=0 + SKIP 行 + summary skipped=1（silent skip 禁止）" {
  printf "export const meta = { name: 'fx-noargs' }\n// args の話はコメントにだけ出る\nreturn { ok: true }\n" > "$FIX/noargs.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/noargs.workflow.js" --label fx-noargs
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP fx-noargs"* ]]
  [[ "$output" == *"summary: checked=0 skipped=1"* ]]
}

# ── T7 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=engine 不在(127)/非実行ビット(126) を「違反(1)」「判定不能(2)」と混同しない
#          | polarity=negative
#          | mutant_fingerprint=他 tooth の `[ "$status" -eq 1 ]` を `[ "$status" -ne 0 ]` へ緩めると
#            126/127 を RED 扱いする空虚化が起きる（本 tooth はその混同が起きうる値域を固定する）
@test "sc-4t3t T7: 126/127 を RED 扱いしない — 実行できない engine は rc 1/2 のどちらでもない" {
  run -127 "$BATS_TEST_TMPDIR/no-such-engine.sh" --mode adhoc --file "$SNIPPET"
  [ "$status" -eq 127 ]
  cp "$ENGINE" "$BATS_TEST_TMPDIR/noexec.sh"
  chmod -x "$BATS_TEST_TMPDIR/noexec.sh"
  run -126 "$BATS_TEST_TMPDIR/noexec.sh" --mode adhoc --file "$SNIPPET"
  [ "$status" -eq 126 ]
}

# ── T8 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=3 骨格は legacy 面（骨格別 verbatim probe args）で agentCalls=0
#          | polarity=positive
#          | mutant_fingerprint=cell-quality の isWorkerCell gate を除去（`if (isWorkerCell)` → `if (false)`）
#            → cell-quality の legacy 判定が rc 0→1（AGENT_STARTED_BEFORE_FAILFAST）
@test "sc-4t3t T8: 骨格 (A) legacy — 骨格別 verbatim probe args で 3 本とも agentCalls=0（rc=0）" {
  local pass=""
  run "$ENGINE" --mode skeleton --file "$SKEL_CELL_QUALITY" --expect legacy --probe-args "$ARGS_CELL_QUALITY" --label cell-quality
  [ "$status" -eq 0 ]
  [[ "$output" == *"agentCalls=0"* ]]
  pass="$pass cell-quality"
  run "$ENGINE" --mode skeleton --file "$SKEL_MANDATE_VERIFY" --expect legacy --probe-args "$ARGS_MANDATE_VERIFY" --label mandate-verify
  [ "$status" -eq 0 ]
  [[ "$output" == *"agentCalls=0"* ]]
  pass="$pass mandate-verify"
  run "$ENGINE" --mode skeleton --file "$SKEL_NEEDS_USER" --expect legacy --probe-args "$ARGS_NEEDS_USER" --label needs-user-prebake
  [ "$status" -eq 0 ]
  [[ "$output" == *"agentCalls=0"* ]]
  pass="$pass needs-user-prebake"
  [ "$pass" = " cell-quality mandate-verify needs-user-prebake" ]
}

# ── T9 ───────────────────────────────────────────────────────────────────────
# inventory: invariant=canonical 面で RED になる骨格集合が EXPECTED_CANONICAL_RED と完全一致
#          | polarity=negative（現状 RED が正・波1 の throw 化で本 tooth が RED になるのは設計上の tripwire）
#          | mutant_fingerprint=いずれか 1 本を throw 形へ置換 → 集合一致が崩れて本 tooth RED
@test "sc-4t3t T9: 骨格 (B) canonical — EXPECTED_CANONICAL_RED の集合一致（skip/xfail で書かない）" {
  # 波1（sc-k33c 項目6 / C1a・L1c）が canonical snippet へ置換した瞬間にここが RED になる向き＝退行検知でなく
  # 「置換が land した」ことの tripwire。RED になったら EXPECTED_CANONICAL_RED から当該骨格を外す。
  local expected="cell-quality mandate-verify needs-user-prebake"
  local red=""
  run "$ENGINE" --mode skeleton --file "$SKEL_CELL_QUALITY" --expect canonical --probe-args "$ARGS_CELL_QUALITY" --label cell-quality
  if [ "$status" -eq 1 ] && [[ "$output" == *"VIOLATION NO_THROW_ON_MISSING_ARGS"* ]]; then red="$red cell-quality"; fi
  run "$ENGINE" --mode skeleton --file "$SKEL_MANDATE_VERIFY" --expect canonical --probe-args "$ARGS_MANDATE_VERIFY" --label mandate-verify
  if [ "$status" -eq 1 ] && [[ "$output" == *"VIOLATION NO_THROW_ON_MISSING_ARGS"* ]]; then red="$red mandate-verify"; fi
  run "$ENGINE" --mode skeleton --file "$SKEL_NEEDS_USER" --expect canonical --probe-args "$ARGS_NEEDS_USER" --label needs-user-prebake
  if [ "$status" -eq 1 ] && [[ "$output" == *"VIOLATION NO_THROW_ON_MISSING_ARGS"* ]]; then red="$red needs-user-prebake"; fi
  [ "${red# }" = "$expected" ]
}

# ── T10 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=fail-fast の意味反転（最小編集 1 箇所）で engine の判定が green→RED に flip する
#          | polarity=negative（非空虚性の実証）
#          | mutant_fingerprint=`if (__scargsParseFailed || __scargsMissing.length > 0) {` → `if (false) {`
@test "sc-4t3t T10: mutation で RED flip — fail-fast 条件の意味反転 1 箇所で rc 0→1（diff 命中も確認）" {
  mk_good "$FIX/mut-base.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/mut-base.workflow.js" --label mut-base
  [ "$status" -eq 0 ]

  sed 's/if (__scargsParseFailed || __scargsMissing.length > 0) {/if (false) {/' \
    "$FIX/mut-base.workflow.js" > "$FIX/mut-flip.workflow.js"
  # 変異が実際に当たったこと（diff 非空 = 1 行の置換）を確認する。対話 grep でなく diff と rc で確認する規律。
  run diff "$FIX/mut-base.workflow.js" "$FIX/mut-flip.workflow.js"
  [ "$status" -eq 1 ]
  [[ "$output" == *"if (false) {"* ]]

  run "$ENGINE" --mode adhoc --file "$FIX/mut-flip.workflow.js" --label mut-flip
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
}

# ── T11 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=loader は meta 宣言を「まるごと」切除する（実ハーネス準拠）＝meta 参照 body は RED
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の stripMeta を「`export ` を剥がすだけ」の旧方式へ戻す
#            → meta 参照 fixture が通ってしまい本 tooth RED
@test "sc-4t3t T11: meta 切除の pin — body の meta 参照は ReferenceError として RED（sc-ojom ギャップの封鎖）" {
  {
    printf "export const meta = { name: 'fx-meta-ref', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "log('run ' + meta.name)\n"
    emit_block
    printf "\nreturn { ok: true }\n"
  } > "$FIX/meta-ref.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/meta-ref.workflow.js" --label fx-meta-ref
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION RUNTIME_REFERENCE_ERROR"* ]]
  [[ "$output" == *"meta is not defined"* ]]
}

# ── T12 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=snippet の必須 3 部（defensive parse / receivedArgs.type / fail-fast=throw）と
#            marker literal・置き場の規約（export const meta を持たない）
#          | polarity=positive
#          | mutant_fingerprint=block 内の `throw new Error(` を `return {` へ → 本 tooth RED
@test "sc-4t3t T12: snippet の必須 3 部と marker 規約（throw 在中・type field・meta 非搭載・compile 可）" {
  # marker は行完全一致で各 1 個（散文中の言及を marker と数えない）
  run node "$HELPER" "$PROBE" "$SNIPPET" lines
  [ "$status" -eq 0 ]
  [ "$output" -gt 10 ]

  run emit_block
  [ "$status" -eq 0 ]
  local block="$output"
  # (1) defensive parse / (2) receivedArgs（field 名 type）/ (3) fail-fast=throw
  [[ "$block" == *"JSON.parse(args)"* ]]
  [[ "$block" == *"const receivedArgs = {"* ]]
  [[ "$block" == *"type: __scargsRawType"* ]]
  [[ "$block" == *"throw new Error("* ]]
  # 4 つの病的形をすべて拒否する判定が block 内に在る
  [[ "$block" == *"'undefined'"* ]]
  [[ "$block" == *"'[undefined]'"* ]]
  # snippet は export const meta を持たない（workflows/lib/ 配下＝カタログ面に載せない置き場の規約）
  run "$GREP" -c "^export const meta" "$SNIPPET"
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
  # block 単体が構文として通る（AsyncFunction wrap = 実ハーネスの評価形式）
  printf "const REQUIRED_ARGS = ['anchor']\n%s\n" "$block" > "$FIX/block-only.js"
  run node -e 'const {readFileSync}=require("node:fs");const AF=Object.getPrototypeOf(async function(){}).constructor;new AF("agent","parallel","pipeline","log","phase","args","budget","workflow",readFileSync(process.argv[1],"utf8"));console.log("COMPILE-OK")' "$FIX/block-only.js"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COMPILE-OK"* ]]
}

# ── T13 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=none (drift-detection only)  ← 従＝byte-pin は不変条件を守らない。正直に書く。
#          | polarity=positive
#          | mutant_fingerprint=snippet block 内のコメントを 1 文字変える → sha 不一致で本 tooth RED
#   【TS 化（orch-lxgy v3 compile）で本 pin は無効】→ 挙動 probe（T2/T10）側へ一本化して撤去する。
@test "sc-4t3t T13: snippet self-pin — canonical block の sha256 が固定値と一致（drift 検知のみ）" {
  run block_sha
  [ "$status" -eq 0 ]
  [ "$output" = "$SELF_PIN_SHA256" ]
}

# ── T14 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=骨格の本数 pin（3 本）。cell-gate land 時にここが RED になるのは**退行でなく
#            設計上の tripwire**（新骨格に legacy allowlist / canonical 期待集合を足す合図）
#          | polarity=positive
#          | mutant_fingerprint=workflows/ に .workflow.js を 1 本足す → 本 tooth RED
@test "sc-4t3t T14: count pin — workflows/*.workflow.js は 3 本（新骨格 land の tripwire）" {
  run bash -c 'ls "$1"/workflows/*.workflow.js | wc -l' _ "$REPO_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" -eq 3 ]
}

# ── T15 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=SCARGS block を複製した script が canonical から byte drift したら検出する（従）
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の sha 比較を `if (false)` へ → 本 tooth RED
@test "sc-4t3t T15: byte-pin（従）— 複製 block の 1 byte drift を SNIPPET_BLOCK_DRIFT で検出" {
  mk_good "$FIX/drift.workflow.js"
  # 意味を変えない編集（block 内コメントの 1 語）だけを入れる＝挙動 probe は素通り、byte-pin だけが鳴る
  sed 's|// (2) receivedArgs: |// (2) receivedArgsX: |' "$FIX/drift.workflow.js" > "$FIX/drift-mut.workflow.js"
  run diff "$FIX/drift.workflow.js" "$FIX/drift-mut.workflow.js"
  [ "$status" -eq 1 ]
  run "$ENGINE" --mode skeleton --file "$FIX/drift-mut.workflow.js" --snippet "$SNIPPET" --label fx-drift
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION SNIPPET_BLOCK_DRIFT"* ]]
}

# ── T16 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=本 bats は skip を 1 つも持たない（依存不在を skip で逃がさない・notes ■7）
#          | polarity=positive
#          | mutant_fingerprint=どこかの tooth に `skip` を 1 行足す → 本 tooth RED
@test "sc-4t3t T16: 本 bats に skip が 0 本（非空虚性の自己 assert）" {
  run "$GREP" -c -E "^[[:space:]]*skip([[:space:]]|$)" "$BATS_TEST_FILENAME"
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

# ── T17 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=使い方の誤り（値を取る option の値欠落）は rc exact 2 + INCONCLUSIVE BAD_USAGE。
#            rc=1 は必ず stdout の `VIOLATION <ID>` を伴う（無出力 rc=1 = 偽 VIOLATION を出さない）
#          | polarity=negative
#          | mutant_fingerprint=wrapper の `[ $# -ge 2 ] || die_inconclusive "BAD_USAGE" ...` を削除
#            → `shift 2` が set -e で落ち、無出力 rc=1 になって本 tooth RED
@test "sc-4t3t T17: 値欠落 option は rc exact 2 + INCONCLUSIVE BAD_USAGE（無出力 rc=1 の偽 VIOLATION を出さない）" {
  run "$ENGINE" --mode
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE BAD_USAGE"* ]]

  run "$ENGINE" --mode adhoc --file
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE BAD_USAGE"* ]]

  run "$ENGINE" --mode adhoc --file "$SNIPPET" --timeout
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE BAD_USAGE"* ]]

  # timeout 0 は「上限なし」（実測: `timeout 0 sleep 8` は 8s 完走 rc=0）＝封じ込めの必須条件を無言で外す形。
  # option 経路と env 経路の両方を弾くことを pin する（env 経路は外部から 1 変数で発火できるため）。
  run "$ENGINE" --mode adhoc --file "$SNIPPET" --timeout 0
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE BAD_USAGE"* ]]

  run env SCRIBE_WF_ARGS_LINT_TIMEOUT=0 "$ENGINE" --mode adhoc --file "$SNIPPET"
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE BAD_USAGE"* ]]
}

# ── T18 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=probe は timeout を実際に掛け、timeout 時は fail-closed に倒れる
#            （agent 起動の実測が無ければ rc=2 INCONCLUSIVE TIMEOUT / 在れば rc=1 VIOLATION）
#          | polarity=negative
#          | mutant_fingerprint=wrapper の `"$TIMEOUT_BIN" "$TIMEOUT_SECONDS"` を外す → 本 tooth が
#            無限ハングして RED（bats の timeout で落ちる）。124/137 分岐の削除でも RED
@test "sc-4t3t T18: 封じ込め(timeout) — hang は rc exact 2 + INCONCLUSIVE TIMEOUT / agent 先行 hang は rc exact 1" {
  # 未解決 Promise だけでは node が exit 13 で即死する（＝hang しない）ので、pending timer で本当に居座らせる。
  {
    printf "export const meta = { name: 'fx-hang', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "if (!args.anchor) { await new Promise((r) => setTimeout(r, 3600000)) }\n"
    emit_block
    printf "\nawait agent('work', { label: 'w' })\nreturn { ok: true }\n"
  } > "$FIX/hang.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/hang.workflow.js" --timeout "$PROBE_TIMEOUT" --label fx-hang
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE TIMEOUT"* ]]

  {
    printf "export const meta = { name: 'fx-agent-hang', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "await agent('early', { label: 'early' })\n"
    printf "if (!args.anchor) { await new Promise((r) => setTimeout(r, 3600000)) }\n"
    emit_block
    printf "\nreturn { ok: true }\n"
  } > "$FIX/agent-hang.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/agent-hang.workflow.js" --timeout "$PROBE_TIMEOUT" --label fx-agent-hang
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
}

# ── T19 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=probe の封じ込め 4 条件（空 cwd / env 最小化 / 出力破棄 / bwrap の fs 隔離）が
#            実際に効いている（被検査 script から観測して assert する）
#          | polarity=positive
#          | mutant_fingerprint=wrapper の `"$ENV_BIN" -i` を外す → env 非空で agent 起動 → rc 0→1 で RED。
#            bwrap 一式を外す → escape canary が生成されて RED。`>/dev/null 2>/dev/null` を外す → canary 混入で RED
@test "sc-4t3t T19: 封じ込め(空 cwd / env 最小化 / 出力破棄 / fs 隔離) — 被検査 script から実測して pin" {
  local escape="$BATS_TEST_TMPDIR/escape-canary.txt"
  rm -f "$escape"
  {
    printf "export const meta = { name: 'fx-contain', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "const __fs = await import('node:fs')\n"
    # 出力破棄: engine の stdout/stderr に混ざったら bats の \$output に現れる
    printf "console.log('LEAK-STDOUT-CANARY')\n"
    printf "console.error('LEAK-STDERR-CANARY')\n"
    # fs 隔離: 封じ込めが無ければ空 cwd の外（BATS_TEST_TMPDIR）へ書けてしまう
    printf "try { __fs.writeFileSync('%s', 'escaped') } catch (e) {}\n" "$escape"
    # env 最小化 / 空 cwd: 破れていたら agent を起動する＝rc=1 に倒れる（rc で機械判定できる形にする）
    printf "if (Object.keys(process.env).length > 0) { await agent('env-not-minimal', { label: 'env' }) }\n"
    printf "if (__fs.readdirSync(process.cwd()).length > 0) { await agent('cwd-not-empty', { label: 'cwd' }) }\n"
    emit_block
    printf "\nawait agent('work', { label: 'w' })\nreturn { ok: true }\n"
  } > "$FIX/contain.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/contain.workflow.js" --label fx-contain
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK fx-contain"* ]]
  [[ "$output" != *"LEAK-STDOUT-CANARY"* ]]
  [[ "$output" != *"LEAK-STDERR-CANARY"* ]]
  [ ! -f "$escape" ]
}

# ── T20 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=args を `${}` 補間だけで使う script を「args 参照 0 hit」で対象外にしない
#            （mask がテンプレート補間の**コード**まで潰すと、本 leg が潰す当の fail-open を engine が作る）
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の maskSource テンプレート分岐で `${` 以降を
#            `stack.push('interp'); out.push('${')` から旧方式（中身を blank）へ戻す → SKIP rc=0 になり本 tooth RED
@test "sc-4t3t T20: mask の過剰潰し封鎖 — args を \${} 補間だけで使う fail-fast 無し script は SKIP されず rc exact 1" {
  {
    printf "export const meta = { name: 'fx-tmpl', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "await agent(\`review \${args.anchor} now\`, { label: 'r' })\n"
    printf "return { ok: true }\n"
  } > "$FIX/tmpl.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/tmpl.workflow.js" --label fx-tmpl
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
  [[ "$output" != *"SKIP fx-tmpl"* ]]

  # 文字列/コメント内だけの args は従来どおり対象外（過剰補正で T6 の向きを壊していないことの確認）
  printf "export const meta = { name: 'fx-strargs' }\nlog('args は文字列の中にだけ出る')\nreturn { ok: true }\n" > "$FIX/strargs.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/strargs.workflow.js" --label fx-strargs
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP fx-strargs"* ]]
}

# ── T21 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=positive control（正常 args では throw せず agent が起動する）。病的側だけを見ると
#            「args と無関係に常に throw する preamble」＝全 run を殺す fail-fast が合格する
#          | polarity=negative
#          | mutant_fingerprint=snippet block の `if (__scargsParseFailed || __scargsMissing.length > 0) {`
#            を `if (true) {` へ反転 → rc 0→1（VIOLATION FAILFAST_FALSE_POSITIVE）。
#            engine 側なら `if (pr.threw || pr.agentCalls < 1)` を `if (false)` へ → 本 tooth RED
@test "sc-4t3t T21: positive control — 正常 args で agent 到達を要求し、常時 throw preamble は rc exact 1" {
  # (1) 準拠 fixture は正常 args で agent 起動まで到達する
  mk_good "$FIX/pos-base.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/pos-base.workflow.js" --label fx-pos
  [ "$status" -eq 0 ]
  [[ "$output" == *"positiveControl=ok(agentCalls=1)"* ]]

  # (2) args と無関係に常に throw する preamble は違反（病的側は「throw + agentCalls=0」を満たしてしまう）
  {
    printf "export const meta = { name: 'fx-always', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "const A = args || {}\n"
    printf "throw new Error('[SCARGS fail-fast] 常に throw する壊れた preamble')\n"
  } > "$FIX/always-throw.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/always-throw.workflow.js" --label fx-always
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION FAILFAST_FALSE_POSITIVE"* ]]

  # (3) 変異注入: 準拠 block の fail-fast 条件を `if (true)` へ反転（意味反転の最小編集 1 箇所）→ rc 0→1
  sed 's/if (__scargsParseFailed || __scargsMissing.length > 0) {/if (true) {/' \
    "$FIX/pos-base.workflow.js" > "$FIX/pos-flip.workflow.js"
  run diff "$FIX/pos-base.workflow.js" "$FIX/pos-flip.workflow.js"
  [ "$status" -eq 1 ]
  [[ "$output" == *"if (true) {"* ]]
  run "$ENGINE" --mode adhoc --file "$FIX/pos-flip.workflow.js" --label fx-pos-flip
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION FAILFAST_FALSE_POSITIVE"* ]]
}

# ── T22 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=positive control は「agent 到達**前**の throw」だけを違反とする。
#            agent 到達**後**の下流 throw（stub 返り値の形状差）は違反ではなく、throw も agent 到達も
#            起きない形は違反ではなく判定不能（rc=2）。3 事象を 1 つの違反 ID に畳まない（false-RED 封鎖）
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の positive control 判定を
#            `if (pr.threw || pr.agentCalls < 1)`（3 事象を畳む旧形）へ戻す → (1)(2) とも RED
@test "sc-4t3t T22: positive control の射程 — 下流 throw は rc exact 0 / agent 未到達は rc exact 2（違反に畳まない）" {
  # (1) ② agent 到達**後**の throw（agent stub が {} を返すため r.text が undefined → SyntaxError）。
  #     canonical block を verbatim 複製した完全準拠 script なので rc=0 でなければならない。
  {
    printf "export const meta = { name: 'fx-downstream', requiredArgs: ['anchor', 'targetBead'] }\n"
    printf "const REQUIRED_ARGS = ['anchor', 'targetBead']\n"
    emit_block
    printf "\nconst r = await agent('work', { label: 'w' })\nconst parsed = JSON.parse(r.text)\nreturn { ok: true, parsed, receivedArgs }\n"
  } > "$FIX/downstream-throw.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/downstream-throw.workflow.js" --label fx-downstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK fx-downstream"* ]]
  [[ "$output" == *"positiveControl=ok(agentCalls=1"* ]]
  [[ "$output" != *"FAILFAST_FALSE_POSITIVE"* ]]

  # (2) ③ throw も agent 到達も起きない形（filler 値では骨格自身の意味的検証で早期 return する実骨格）。
  #     「fail-fast が発火した」と断定できないので違反(1) ではなく判定不能(2)。
  run "$ENGINE" --mode skeleton --file "$SKEL_MANDATE_VERIFY" --expect legacy --required anchor,targetBead --label mv-unreached
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE POSITIVE_UNREACHED"* ]]
  [[ "$output" != *"VIOLATION"* ]]
}

# ── T23 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=必須 args 配列**内**のコメントに引用符付き語が在っても必須 args に混入しない
#            （混入すると準拠 script に phantom key の病的シナリオが当たり偽 VIOLATION = false-RED）
#          | polarity=positive
#          | mutant_fingerprint=extractArrayAfter の要素走査を masked から raw へ戻す
#            （`re.exec(maskedSlice)` → `re.exec(raw.slice(open, i + 1))`）→ 二面とも
#            required=["anchor","oldName","targetBead"] と誤認して phantom key の病的シナリオを当て、
#            準拠 script が（当然 throw しないため）rc 0→1（VIOLATION AGENT_STARTED_BEFORE_FAILFAST）
#            になり本 tooth RED（実測済み）
@test "sc-4t3t T23: 宣言抽出の mask 適用 — 配列内コメントの引用符付き語を必須 args にしない（rc exact 0）" {
  {
    printf "export const meta = {\n  name: 'fx-arrcomment',\n"
    printf "  requiredArgs: ['anchor', /* 旧名 'oldName' は廃止 */ 'targetBead'],\n}\n"
    printf "const REQUIRED_ARGS = ['anchor', /* 旧名 'oldName' は廃止 */ 'targetBead']\n"
    emit_block
    printf "\nawait agent('work', { label: 'w' })\nreturn { ok: true, receivedArgs }\n"
  } > "$FIX/arr-comment.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/arr-comment.workflow.js" --label fx-arrcomment
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK fx-arrcomment"* ]]
  [[ "$output" == *'required=["anchor","targetBead"]'* ]]
  [[ "$output" != *"oldName"* ]]
  # 病的形 4 種 × 必須 2 個 = 8（phantom key が混入すると 12 になる）
  [[ "$output" == *"scenarios=8"* ]]
}

# ── T24 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=none (既知の穴の可視化のみ) — 封じ込めは**ホスト側の被害**を抑えるが
#            **判定の真正性**は守らない。被検査 script は同一 process 内で評価され process.argv から
#            --report の path を読めるため rc=0 OK を偽造できる。よって本 engine の入力は
#            trusted（repo 内 script / bats fixture）に限る、を現状仕様として pin する
#          | polarity=positive（現状仕様の pin。判定チャネル分離が入ったら RED になり、
#            そのときは「偽造検知で rc=2」を要求する向きへ本 tooth を書き換える＝設計上の tripwire）
#          | mutant_fingerprint=判定チャネルを子 process へ分離（親は対象コードを eval しない）→ 本 tooth RED
@test "sc-4t3t T24: 判定チャネルの既知の穴 — 被検査 script は report を掌握して OK を偽造できる（trusted-input 前提の pin）" {
  {
    printf "export const meta = { name: 'fx-forge', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "const A = args || {}\n"
    printf "const __fs = await import('node:fs')\n"
    printf "const __i = process.argv.indexOf('--report')\n"
    printf "__fs.writeFileSync(process.argv[__i + 1], 'RC 0\\\\nOUT OK fx-forge FORGED-VERDICT\\\\n')\n"
    printf "process.exit(0)\n"
  } > "$FIX/forge.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/forge.workflow.js" --label fx-forge
  [ "$status" -eq 0 ]
  [[ "$output" == *"FORGED-VERDICT"* ]]
}

# ── T25 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=canonical block の (1) defensive parse が挙動として効く
#            （args が JSON 文字列で到達する modality で parse 結果が A へ入り必須 args が満たされる）
#          | polarity=negative（fail-fast しない＝agent 到達を rc=1 で観測する向き）
#          | mutant_fingerprint=block の `A = __scargsParsed && ...` 代入を削る（`A = {}` 固定）→
#            必須 args が満たされず throw して rc 1→0 になり本 tooth RED
@test "sc-4t3t T25: defensive parse の挙動 pin — JSON 文字列 args は parse され A へ入る（rc exact 1）" {
  mk_good "$FIX/parse-ok.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/parse-ok.workflow.js" \
    --probe-args '"{\"anchor\":\"a1\",\"targetBead\":\"b1\"}"' --label fx-parse-ok
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
}

# ── T26 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=canonical block の (1) parse 失敗が **単独で** (3) の throw へ落ちる
#            （黙って {} にせず fail-fast する）。object 経路だけの probe では一度も実行されない modality
#          | polarity=positive
#          | mutant_fingerprint=block の `__scargsParseFailed = true` 代入を潰す（= false）→ parse 失敗が
#            素通りして agent 到達 → rc 0→1（VIOLATION AGENT_STARTED_BEFORE_FAILFAST）で本 tooth RED（実測済み）
#   ★ 必須 args を持つ fixture では A={} のまま「必須欠落」判定に吸収され、parseFailed を潰しても
#     依然 throw する（＝mutant が flip しない空虚な tooth になる）。よって **REQUIRED_ARGS を空**にして
#     parse 失敗だけが唯一の fail-fast 発火源になる形で pin する。
@test "sc-4t3t T26: parse 失敗の挙動 pin — parse 不能な文字列 args は単独で fail-fast する（rc exact 0）" {
  {
    printf "export const meta = { name: 'fx-parse-bad', requiredArgs: [] }\n"
    printf "const REQUIRED_ARGS = []\n"
    emit_block
    printf "\nawait agent('work', { label: 'w' })\nreturn { ok: true, receivedArgs }\n"
  } > "$FIX/parse-bad.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/parse-bad.workflow.js" --probe-args '"not-json{"' --label fx-parse-bad
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK fx-parse-bad"* ]]
  [[ "$output" == *"agentCalls=0"* ]]

  # 対の向き: 同じ fixture へ **正常な** JSON 文字列を与えると（必須 args が空なので）throw せず agent へ到達する
  # ＝上の rc=0 が「常に throw する block」による空虚 green でないことの証明。
  run "$ENGINE" --mode adhoc --file "$FIX/parse-bad.workflow.js" --probe-args '"{\"anchor\":\"a1\"}"' --label fx-parse-ref
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
}

# ── T27 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=宣言 token を**コメント/文字列でだけ**言及する script は「宣言なし」＝対象外(rc=0)。
#            交差検査（tokenMissed）の検査面を raw source にすると、maskSource が正しく働いた結果を
#            「mask の取りこぼし」と誤って報告して rc=2 に倒れ、notes ■2（双方とも無い script は rc=0・
#            宣言が無いことを理由に落とさない）と ■6（コメント/文字列を除去してから探す）の双方に反する
#          | polarity=positive
#          | mutant_fingerprint=wf-args-probe.mjs の `tokenMissed` の検査面を masked（codeText）から
#            raw（`test(src)`）へ戻す → rc 0→2（INCONCLUSIVE MASK_AMBIGUOUS）で本 tooth RED（実測済み）
@test "sc-4t3t T27: 交差検査の検査面 — コメント言及だけの宣言なし script は rc exact 0 + SKIP（rc=2 に倒さない）" {
  {
    printf "export const meta = { name: 'fx-commentonly' }\n"
    printf "// 将来 meta.requiredArgs / REQUIRED_ARGS の二面宣言を持つ予定（今は宣言なし）\n"
    printf "const A = args || {}\n"
    printf "return { ok: true, A }\n"
  } > "$FIX/comment-only.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/comment-only.workflow.js" --label fx-commentonly
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP fx-commentonly"* ]]
  [[ "$output" == *"summary: checked=0 skipped=1"* ]]
  [[ "$output" != *"MASK_AMBIGUOUS"* ]]

  # 文字列リテラルでの言及も同じ（コメントだけの特例にしていないことの確認）
  {
    printf "export const meta = { name: 'fx-stronly' }\n"
    printf "const A = args || {}\n"
    printf "log('requiredArgs / REQUIRED_ARGS はまだ宣言していない')\n"
    printf "return { ok: true, A }\n"
  } > "$FIX/string-only.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/string-only.workflow.js" --label fx-stronly
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP fx-stronly"* ]]
}

# ── T28 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=交差検査は空虚化していない — 宣言 token が**コード面**（mask 後）に在るのに
#            regex が抽出できない形（shorthand property 等の想定外の宣言形）は rc exact 2 +
#            INCONCLUSIVE MASK_AMBIGUOUS（黙って対象外 rc=0 にしない）。T27 の対の向き
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の tokenMissed 分岐（MASK_AMBIGUOUS 判定）を削除する
#            → 宣言なし扱いの SKIP へ落ちて rc 2→0 になり本 tooth RED
@test "sc-4t3t T28: 交差検査の非空虚性 — コード面に宣言 token が在るが抽出不能なら rc exact 2 + MASK_AMBIGUOUS" {
  {
    printf "export const meta = { name: 'fx-shorthand', requiredArgs }\n"
    printf "const A = args || {}\n"
    printf "await agent('work', { label: 'w' })\n"
    printf "return { ok: true, A }\n"
  } > "$FIX/shorthand-decl.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/shorthand-decl.workflow.js" --label fx-shorthand
  [ "$status" -eq 2 ]
  [[ "$output" == *"INCONCLUSIVE MASK_AMBIGUOUS"* ]]
}

# ── T29 ──────────────────────────────────────────────────────────────────────
# inventory: invariant=「fail-fast より前に仕事を始めない」の観測面は agent() だけでなく workflow() も含む
#            （nested workflow は agent 木ごと起動する＝本 lint が塞ぐ「undefined を掴んだまま完走して
#            token を溶かす」事故と同一クラスの副作用。agent() 単独の不変条件では modality 違いで素通りする）
#          | polarity=negative
#          | mutant_fingerprint=wf-args-probe.mjs の workflow stub を無計数（`async () => null`）へ戻す
#            または `started` 判定から `r.workflowCalls > 0` を落とす → rc 1→0 で本 tooth RED（実測済み）
@test "sc-4t3t T29: 仕事開始の modality — fail-fast 前の nested workflow() 起動は rc exact 1（agent 0 回でも違反）" {
  {
    printf "export const meta = { name: 'fx-nested-wf', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    printf "await workflow('cell-quality', { doImplement: true })\n"
    emit_block
    printf "\nawait agent('work', { label: 'w' })\nreturn { ok: true, receivedArgs }\n"
  } > "$FIX/nested-wf.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/nested-wf.workflow.js" --label fx-nested-wf
  [ "$status" -eq 1 ]
  [[ "$output" == *"VIOLATION AGENT_STARTED_BEFORE_FAILFAST"* ]]
  # agent は 1 度も呼ばれていない（workflow 単独で違反になっていること＝modality の追加を pin）
  [[ "$output" == *"agent()=0 回"* ]]

  # 対の向き: canonical block を先に置けば（workflow 呼出が block の**後**なら）rc=0
  # ＝「workflow を呼ぶ script を一律に落とす」空虚な判定になっていないことの証明。
  {
    printf "export const meta = { name: 'fx-nested-wf-ok', requiredArgs: ['anchor'] }\n"
    printf "const REQUIRED_ARGS = ['anchor']\n"
    emit_block
    printf "\nawait workflow('cell-quality', { doImplement: true })\nawait agent('work', { label: 'w' })\nreturn { ok: true, receivedArgs }\n"
  } > "$FIX/nested-wf-ok.workflow.js"
  run "$ENGINE" --mode adhoc --file "$FIX/nested-wf-ok.workflow.js" --label fx-nested-wf-ok
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK fx-nested-wf-ok"* ]]
  [[ "$output" == *"workflowCalls=0"* ]]
}

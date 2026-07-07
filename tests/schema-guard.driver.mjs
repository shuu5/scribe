// schema-guard.driver.mjs — sc-j32 schema 強制 agent ガードの behavioral 検証ハーネス(tracked)。
//
// 対象: workflows/{cell-quality,needs-user-prebake}.workflow.js の `//SCJ32_BLOCK_START…END` ブロック
// (SCHEMA_DISCIPLINE / isPlaceholderStr / schemaHealth / degenerate 述語 / schemaAgent ラッパ)。
//
// これらの WF は Workflow tool 専用モジュール(export const meta + top-level await/return)ゆえ素の import 不可。
//本ハーネスは実ソースから SCJ32 ブロックだけを切り出し `new Function` で eval して **実コードを走らせ**(再実装
// でなく)、schemaAgent の null 死記録 / degenerate 記録 / passthrough / throw 透過、および degenerate 述語の
// true/false を behaviorally 検証する。両骨格(cell-quality / prebake)で degenerate 判定フィールドが異なるため
// kind で分岐する。selftest-sc-j32.local.sh の node ハーネスの tracked 版(committed=CI で回る)。
//
// 使い方: node schema-guard.driver.mjs <workflow-file> <cell-quality|prebake>
//   assert が 1 つでも落ちたら非 0 で exit(fail-closed)。

import { readFileSync } from 'node:fs'
import { basename } from 'node:path'

let fails = 0
const T = (name, cond) => {
  if (cond) console.log('  ok  - ' + name)
  else { fails++; console.log('  FAIL- ' + name) }
}

function extractBlock(src) {
  const s = src.indexOf('//SCJ32_BLOCK_START')
  const e = src.indexOf('//SCJ32_BLOCK_END')
  if (s < 0 || e < 0 || e < s) return null
  return src.slice(s, e)
}

// ブロックを log スタブ注入で eval し、内部の関数/状態を取り出す(実コードを走らせる)。
function loadBlock(block, logs) {
  const runBlock = new Function('log', block + `
    return {
      schemaAgent: (typeof schemaAgent!=='undefined')?schemaAgent:undefined,
      isPlaceholderStr: (typeof isPlaceholderStr!=='undefined')?isPlaceholderStr:undefined,
      schemaHealth: (typeof schemaHealth!=='undefined')?schemaHealth:undefined,
      SCHEMA_DISCIPLINE: (typeof SCHEMA_DISCIPLINE!=='undefined')?SCHEMA_DISCIPLINE:undefined,
      degFindings: (typeof degFindings!=='undefined')?degFindings:undefined,
      degVerdict: (typeof degVerdict!=='undefined')?degVerdict:undefined,
      degFix: (typeof degFix!=='undefined')?degFix:undefined,
      degClassify: (typeof degClassify!=='undefined')?degClassify:undefined,
      degPlan: (typeof degPlan!=='undefined')?degPlan:undefined,
      degFacet: (typeof degFacet!=='undefined')?degFacet:undefined,
      degSynth: (typeof degSynth!=='undefined')?degSynth:undefined,
    };
  `)
  return runBlock((m) => logs.push(String(m)))
}

// ── 両骨格共通: isPlaceholderStr / SCHEMA_DISCIPLINE / schemaAgent の中核挙動 ─────────────────────────
async function testCommon(M) {
  const ip = M.isPlaceholderStr
  const sh = M.schemaHealth

  T('isPlaceholderStr defined', typeof ip === 'function')
  T("isPlaceholderStr('test')=true (既知 placeholder 語)", ip('test') === true)
  T("isPlaceholderStr(' Test ')=true (trim+lower)", ip(' Test ') === true)
  T("isPlaceholderStr('')=true (空文字=退化)", ip('') === true)
  T("isPlaceholderStr('   ')=true (whitespace→空)", ip('   ') === true)
  // (sc-j32 errata の核: 長さヒューリスティック撤去) terse だが正当な実データは placeholder ではない。
  T("isPlaceholderStr('x')=false (terse≠placeholder)", ip('x') === false)
  T("isPlaceholderStr('r')=false (fallback fixture rationale)", ip('r') === false)
  T("isPlaceholderStr('OK')=false (legit short)", ip('OK') === false)
  T("isPlaceholderStr(real)=false", ip('off by one boundary error') === false)
  T('isPlaceholderStr(null)=false (非 string)', ip(null) === false)
  T('isPlaceholderStr(5)=false (非 string)', ip(5) === false)

  T('SCHEMA_DISCIPLINE mentions StructuredOutput+一度だけ',
    typeof M.SCHEMA_DISCIPLINE === 'string' && /StructuredOutput/.test(M.SCHEMA_DISCIPLINE) && /一度だけ/.test(M.SCHEMA_DISCIPLINE))

  const sa = M.schemaAgent
  T('schemaAgent defined', typeof sa === 'function')
  T('schemaHealth shape', sh && Array.isArray(sh.nullDeaths) && Array.isArray(sh.degenerate))

  // (1) null 死 → null + nullDeaths 記録 + prompt に SCHEMA_DISCIPLINE 前置。
  let captured = null
  const r1 = await sa(async (p) => { captured = p; return null }, 'BASE_PROMPT', { label: 'unit-null' })
  T('null death → null 返却', r1 === null)
  T('null death → schemaHealth.nullDeaths に label 記録', sh.nullDeaths.includes('unit-null'))
  T('SCHEMA_DISCIPLINE が prompt に前置される',
    typeof captured === 'string' && captured.startsWith('BASE_PROMPT') && /StructuredOutput/.test(captured))

  // (2) degenerate → null + degenerate 記録(述語を注入して wrapper 機構を単離)。
  const r2 = await sa(async () => ({ placeholder: true }), 'P', { label: 'unit-deg' }, () => true)
  T('degenerate → null 返却', r2 === null)
  T('degenerate → schemaHealth.degenerate に label 記録', sh.degenerate.includes('unit-deg'))

  // (3) 正常 → passthrough(同一オブジェクト)・新規記録なし。
  const nBefore = sh.nullDeaths.length, dBefore = sh.degenerate.length
  const good = { ok: 1 }
  const r3 = await sa(async () => good, 'P', { label: 'unit-good' }, () => false)
  T('good → passthrough(同一 object)', r3 === good)
  T('good → nullDeaths 不変', sh.nullDeaths.length === nBefore)
  T('good → degenerate 不変', sh.degenerate.length === dBefore)

  // (4) runner throw → 透過(既存 .catch 失敗正規化を壊さない=握り潰さない)。
  let threw = false
  try { await sa(async () => { throw new Error('boom') }, 'P', { label: 'unit-throw' }, () => false) }
  catch (e) { threw = /boom/.test(e.message) }
  T('runner throw → 透過(握り潰さない)', threw === true)

  // (4b) label 省略時は 'schema-agent' 既定で記録される(null 経路)。
  const shBefore = sh.nullDeaths.length
  await sa(async () => null, 'P', {})
  T('label 省略時は schema-agent 既定で記録', sh.nullDeaths.length === shBefore + 1 && sh.nullDeaths.includes('schema-agent'))
}

// ── cell-quality 固有: 5 述語 + fallback 回帰ガード ──────────────────────────────────────────────
function testCellQuality(M) {
  T('degFindings([]) = false (clean ≠ degenerate)', M.degFindings({ findings: [] }) === false)
  T('degFindings(all placeholder) = true', M.degFindings({ findings: [{ title: 'test', location: 'test', rationale: 'test' }] }) === true)
  T('degFindings(real) = false', M.degFindings({ findings: [{ title: 'Off-by-one', location: 'a.js:10', rationale: 'boundary read past end' }] }) === false)
  // (sc-j32 errata 回帰ガード) fallback 回帰テスト fixture の terse finding を degenerate 化しない。
  T('degFindings(fallback fixture {x,a:1,r}) = false (回帰ガード)', M.degFindings({ findings: [{ title: 'x', location: 'a:1', rationale: 'r' }] }) === false)
  T('degFindings(mixed real+placeholder) = false', M.degFindings({ findings: [{ title: 'test', location: 'test', rationale: 'test' }, { title: 'Real', location: 'b.js:2', rationale: 'genuine issue here' }] }) === false)
  T('degVerdict(test) = true', M.degVerdict({ reasoning: 'test' }) === true)
  T('degVerdict(real) = false', M.degVerdict({ reasoning: 'confirmed: the diff drops the guard' }) === false)
  T('degFix(test) = true', M.degFix({ summary: 'test' }) === true)
  T('degFix(real) = false', M.degFix({ summary: 'applied boundary fix and reran self-test' }) === false)
  T('degClassify(test) = true', M.degClassify({ rationale: 'test' }) === true)
  T('degClassify(real) = false', M.degClassify({ rationale: 'this is a testable bugfix task' }) === false)
  T('degPlan(test) = true', M.degPlan({ acceptance: 'test' }) === true)
  T('degPlan(real) = false', M.degPlan({ acceptance: 'the guard rejects placeholder shapes' }) === false)
}

// ── prebake 固有: degFacet / degSynth ───────────────────────────────────────────────────────────
function testPrebake(M) {
  T('degFacet(test) = true', M.degFacet({ currentState: 'test' }) === true)
  T('degFacet(real) = false', M.degFacet({ currentState: 'the current hook fires twice due to double-registration' }) === false)
  T('degFacet(terse legit) = false', M.degFacet({ currentState: 'no' }) === false)
  T('degSynth(test) = true', M.degSynth({ briefMarkdown: 'test' }) === true)
  T('degSynth(real) = false', M.degSynth({ briefMarkdown: '# Brief\nstatus: complete\n...' }) === false)
}

;(async () => {
  const [file, kind] = process.argv.slice(2)
  if (!file || !kind) { console.error('usage: schema-guard.driver.mjs <workflow-file> <cell-quality|prebake>'); process.exit(2) }
  console.log('-- ' + kind + ' (' + basename(file) + ') --')
  const src = readFileSync(file, 'utf8')
  const block = extractBlock(src)
  T('SCJ32 block extractable', !!block)
  if (!block) { console.log('\nFAILED: block not found'); process.exit(1) }
  const logs = []
  let M
  try { M = loadBlock(block, logs) } catch (e) { T('block evals without error: ' + e.message, false); console.log('\nFAILED'); process.exit(1) }
  T('block evals', !!M)

  await testCommon(M)
  if (kind === 'cell-quality') testCellQuality(M)
  else if (kind === 'prebake') testPrebake(M)
  else { console.error('unknown kind: ' + kind); process.exit(2) }

  if (fails) { console.log('\nFAILED: ' + fails + ' assertion(s)'); process.exit(1) }
  console.log('\nALL PASS (' + kind + ')')
})().catch((e) => { console.error('harness error:', e); process.exit(2) })

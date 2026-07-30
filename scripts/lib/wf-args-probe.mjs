#!/usr/bin/env node
// scripts/lib/wf-args-probe.mjs — WF args preamble lint の判定エンジン本体（sc-4t3t / L0a）
//
// ■ 位置づけ
//   scripts/scribe-wf-args-lint.sh（薄い wrapper: 引数正規化・封じ込め・rc マッピングのみ）から呼ばれ、
//   判定 logic の全部をここに持つ。bash 文字列（heredoc / -e）に判定を埋めない＝TS 移植可能形
//   （素の関数 export・meta 非参照・外部依存なし）で書く（追補 orch-lxgy 取込条件）。
//
// ■ 判定の主従（sc-4t3t notes ■9）
//   主 = 挙動 probe（病的 args で agent() が 0 回のまま run が fail-fast する、という不変条件の実測）。
//        + positive control（正常 args では throw せず agent が起動する、という対の不変条件）。
//        対を pin しないと「args と無関係に常に throw する preamble」＝全 run を殺す壊れた fail-fast が
//        病的側だけの判定を満たして合格する（違反 ID = FAILFAST_FALSE_POSITIVE）。
//   従 = marker + sha256 の byte-pin（canonical block からの drift 検知の補助）。両方実装しどちらも撤去しない。
//
// ■ probe の実行面（notes ■3・■10）
//   WF 本体は top-level return / top-level await / export を持つため、素の `node --input-type=module` で
//   直接評価すると必ず SyntaxError になる。実ハーネス準拠に:
//     1) source から `export const meta = {...}` を宣言まるごと（metaNode.end 相当）切り落とす
//     2) 残り body を new AsyncFunction(...INJECTED_GLOBALS, body) で wrap（compile 自体が構文検査）
//     3) agent stub は呼ばれたら計数して即 resolve する（**throw させない**＝「agent が呼ばれた事実」と
//        「fail-fast の throw」を混同しない）。nested workflow() stub も同様に計数する（modality 2 面）
//     4) 1 シナリオごとに threw / errorName / errorMessage / agentCalls / workflowCalls /
//        returnedType / returnedKeys を回収する（ERRATA-1 m4 で fence ■3 の 4 値と実装を突き合わせて訂正）。
//        - returned は**生値を回収しない**: WF の返り値は数百 KB になりうるうえ、判定行へ被検査 script が
//          任意文字列を差し込む面にもなるため、型と key 一覧（先頭 12 件）だけを取る。
//        - exitCode は in-process 評価には存在しない概念なので**シナリオ単位では回収しない**。process 単位の
//          exit code は wrapper が probe_status として回収し、124/137=timeout・report 不在=DRIVER_ERROR に写像する
//          （＝fence ■3 の「exitCode」は wrapper 層の責務として実装されている）。
//   `node --input-type=module` は probe runner（本 file）の実行形式であって WF 本体の評価形式ではない。
//   未レビュー script を素の node process で実行する面を持つ（node v18 系は権限フラグ非対応＝vm でも隔離にならない）ため、
//   timeout・出力破棄・空 cwd・env 最小化は wrapper 側が必須で与える。それらが与えられない環境では probe を
//   実行せず rc=2 に倒す（wrapper 側の責務）。
//
// ■ 本 leg の probe 対象は repo 内 script と bats fixture のみ。任意 script を probe する hook wire は
//   別 leg（probe (a) の結果次第）へ回す。
//
// ■ rc 契約（wrapper と共有・hook の exit code とは別物）
//   0 = 合格 / 対象外（理由を stderr へ 1 行 + stdout へ SKIP 行）
//   1 = 違反（stdout へ `VIOLATION <ID>` 行）
//   2 = 判定不能（stdout へ `INCONCLUSIVE <ID>` 行）。rc=2 を rc=0 へ丸めない（fail-open は本 leg が潰す失敗様式）。

import { readFileSync, appendFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'

// ─────────────────────────────────────────────────────────────────────────────
// 定数
// ─────────────────────────────────────────────────────────────────────────────

// 実ハーネスが body へ注入する global の順序（driver 群と同一）。
export const INJECTED_GLOBALS = ['agent', 'parallel', 'pipeline', 'log', 'phase', 'args', 'budget', 'workflow']

// 病的 args の 4 形（canonical fail-fast はこれらを等しく拒否しなければならない）。
export const PATHOLOGICAL_FORMS = ['omit', 'literal-undefined', 'empty-string', 'bracket-undefined']

export const MARKER_START = '//SCARGS_BLOCK_START'
export const MARKER_END = '//SCARGS_BLOCK_END'

// canonical block が throw する Error message の先頭 marker。positive control で「agent 到達前の throw」を
// args preamble 由来と帰属できるかの唯一の機械照合面（帰属できない throw は違反にせず rc=2 へ倒す）。
export const FAILFAST_MARKER = '[SCARGS fail-fast]'

// 病的でない値（対象キー以外を埋める）。空文字・undefined 等の病的形と衝突しない非空文字列。
export const PROBE_FILLER = 'scribe-wf-args-lint-probe'

// ─────────────────────────────────────────────────────────────────────────────
// 1. source masking（行コメント・ブロックコメント・文字列リテラル/テンプレートの**リテラル文字**を空白へ潰す）
//    目的: 「args 参照」「REQUIRED_ARGS 宣言」「meta の範囲」をコメント/文字列に惑わされず判定する。
//    潰せない（未終端など）ときは ok=false を返し、呼出側は rc=2 へ倒す（黙って対象外にしない）。
//
//    ★ テンプレートリテラルの `${ ... }` の中身は**コードであって文字列リテラルではない**ので潰さない。
//      潰すと `await agent(\`review ${args.anchor}\`)` のように args を補間だけで使う script が
//      「args 参照 0 hit」で対象外 SKIP（rc=0）になる＝本 leg が潰す当の fail-open を engine 自身が作る。
//      契約 notes ■6 の「行コメント・ブロックコメント・文字列リテラルを除去して語境界付きで args を探す」
//      にも、${} 内コードの除去は含まれない。
// ─────────────────────────────────────────────────────────────────────────────

const REGEX_PREV_CHARS = new Set(['(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '^', '~', '<', '>', '\n'])
const REGEX_PREV_KEYWORDS = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'case', 'do', 'else', 'yield', 'await'])

// 直前の有意コード（既に mask 済みの部分列）から、次の '/' が正規表現リテラルの開始かを判定する。
function regexAllowedHere(maskedSoFar) {
  let i = maskedSoFar.length - 1
  while (i >= 0 && /\s/.test(maskedSoFar[i])) i--
  if (i < 0) return true
  const ch = maskedSoFar[i]
  if (REGEX_PREV_CHARS.has(ch)) return true
  if (/[A-Za-z0-9_$]/.test(ch)) {
    let j = i
    while (j >= 0 && /[A-Za-z0-9_$]/.test(maskedSoFar[j])) j--
    const word = maskedSoFar.slice(j + 1, i + 1)
    return REGEX_PREV_KEYWORDS.has(word)
  }
  return false
}

export function maskSource(src) {
  const out = []
  const n = src.length
  let i = 0
  const blank = (ch) => (ch === '\n' ? '\n' : ' ')
  // 文脈スタック。最上位が現在の文脈:
  //   'code'   最上位のコード
  //   'block'  コード中の { } （interp の終端を取り違えないために積む）
  //   'interp' テンプレートの ${ } 内（**コードとして保持**する区間）
  //   'tmpl'   テンプレートのリテラル文字区間（潰す）
  // ${ } と { } は開き括弧・閉じ括弧とも masked 側へ verbatim で出すので brace balance は保たれる
  // （findMetaRange / extractArrayAfter は masked の括弧数を数える）。
  const stack = ['code']
  while (i < n) {
    const mode = stack[stack.length - 1]
    const c = src[i]
    const c2 = src[i + 1]

    // ── テンプレートのリテラル文字区間 ─────────────────────────────────────────
    if (mode === 'tmpl') {
      if (c === '\\') { out.push(' '); out.push(blank(c2 === undefined ? ' ' : c2)); i += 2; continue }
      if (c === '`') { stack.pop(); out.push('`'); i++; continue }
      if (c === '$' && c2 === '{') { stack.push('interp'); out.push('${'); i += 2; continue }
      out.push(blank(c)); i++; continue
    }

    // ── ここから下はコード文脈（'code' / 'block' / 'interp'）───────────────────
    // 行コメント
    if (c === '/' && c2 === '/') {
      while (i < n && src[i] !== '\n') { out.push(blank(src[i])); i++ }
      continue
    }
    // ブロックコメント
    if (c === '/' && c2 === '*') {
      const end = src.indexOf('*/', i + 2)
      if (end === -1) return { masked: out.join(''), ok: false, reason: '未終端のブロックコメント' }
      for (let k = i; k < end + 2; k++) out.push(blank(src[k]))
      i = end + 2
      continue
    }
    // 通常文字列
    if (c === '"' || c === "'") {
      out.push(c)
      i++
      let closed = false
      while (i < n) {
        const d = src[i]
        if (d === '\\') { out.push(' '); out.push(blank(src[i + 1] === undefined ? ' ' : src[i + 1])); i += 2; continue }
        if (d === c) { out.push(c); i++; closed = true; break }
        if (d === '\n') break // 素の文字列は改行で終わらない＝構文破綻
        out.push(blank(d))
        i++
      }
      if (!closed) return { masked: out.join(''), ok: false, reason: '未終端の文字列リテラル' }
      continue
    }
    // テンプレートリテラルの開始（リテラル区間だけを潰し、${} 内はコードとして続きを読む）
    if (c === '`') { stack.push('tmpl'); out.push('`'); i++; continue }
    // 波括弧（${ } の終端を取り違えないために文脈を積む）
    if (c === '{') { stack.push('block'); out.push('{'); i++; continue }
    if (c === '}') {
      if (mode === 'block' || mode === 'interp') stack.pop()
      out.push('}'); i++; continue
    }
    // 正規表現リテラル
    if (c === '/' && regexAllowedHere(out.join(''))) {
      const start = i
      out.push('/')
      i++
      let inClass = false
      let closed = false
      while (i < n) {
        const d = src[i]
        if (d === '\\') { out.push('  '); i += 2; continue }
        if (d === '\n') break
        if (d === '[') { inClass = true; out.push(' '); i++; continue }
        if (d === ']') { inClass = false; out.push(' '); i++; continue }
        if (d === '/' && !inClass) { out.push('/'); i++; closed = true; break }
        out.push(blank(d)); i++
      }
      if (!closed) {
        // 除算だった可能性がある＝判定不能へ倒す（誤 mask で黙って対象外にしない）
        return { masked: out.join(''), ok: false, reason: `正規表現リテラルか除算か判別不能（offset ${start}）` }
      }
      continue
    }
    out.push(c)
    i++
  }
  // 未終端のテンプレート（`  や ${ が閉じずに EOF）は「潰せない」＝rc=2 へ倒す材料にする。
  // 波括弧だけの不均衡は本当の構文破綻であり compile 段（AsyncFunction wrap）が捕まえるので倒さない。
  if (stack.includes('tmpl') || stack.includes('interp')) {
    return { masked: out.join(''), ok: false, reason: '未終端のテンプレートリテラル' }
  }
  return { masked: out.join(''), ok: true, reason: '' }
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. meta 宣言の切除（実ハーネス準拠: 宣言まるごと落とす。`export ` を剥がすだけの旧 driver 方式は
//    meta 参照が実機で ReferenceError になるギャップを覆い隠す＝sc-ojom）
// ─────────────────────────────────────────────────────────────────────────────

// masked 上で `export const meta` を探し、続く `{` から対応する `}` までを宣言範囲とする。
export function findMetaRange(masked) {
  const m = /(^|\n)\s*export\s+const\s+meta\b/.exec(masked)
  if (!m) return null
  const declStart = m.index + (m[1] ? m[1].length : 0)
  const brace = masked.indexOf('{', m.index + m[0].length - 4)
  if (brace === -1) return null
  let depth = 0
  for (let i = brace; i < masked.length; i++) {
    const c = masked[i]
    if (c === '{') depth++
    else if (c === '}') {
      depth--
      if (depth === 0) {
        let end = i + 1
        // 宣言末尾の `;` と直後の改行までを含める
        while (end < masked.length && (masked[end] === ';' || masked[end] === '\r')) end++
        if (masked[end] === '\n') end++
        return { start: declStart, end }
      }
    }
  }
  return null
}

// meta 宣言を切除した body を返す（切除位置は改行で埋めて行番号を保つ）。
export function stripMeta(src, masked) {
  const range = findMetaRange(masked)
  if (!range) return { body: src, maskedBody: masked, hadMeta: false, metaSource: '' }
  const filler = src.slice(range.start, range.end).replace(/[^\n]/g, '')
  return {
    body: src.slice(0, range.start) + filler + src.slice(range.end),
    maskedBody: masked.slice(0, range.start) + filler + masked.slice(range.end),
    hadMeta: true,
    metaSource: src.slice(range.start, range.end),
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. 宣言の抽出（静的 = meta.requiredArgs / 動的 = body の const REQUIRED_ARGS）
// ─────────────────────────────────────────────────────────────────────────────

// masked 上で key の直後にある配列リテラルの範囲を求め、raw から文字列要素を取り出す。
//
// ★ 要素の走査も **masked 上で行う**（raw 上で走査してはならない）。maskSource は raw と offset が 1:1 で、
//   文字列リテラルの引用符**そのもの**は保持し中身だけを空白化する一方、コメントは引用符ごと空白化する。
//   よって masked を走査すればコメント内の引用符付き語は構造的に混入しない。raw を走査すると
//   `requiredArgs: ['anchor', /* 旧名 'oldName' は廃止 */ 'targetBead']` の 'oldName' を必須 args と誤認し、
//   完全準拠 script に phantom key の病的シナリオを当てて偽 VIOLATION を出す（false-RED・notes ■1 が禁じる形）。
//   中身は masked では空白なので、得た offset で **raw を slice** して実文字列を取り出す。
function extractArrayAfter(raw, masked, keyIndex) {
  const open = masked.indexOf('[', keyIndex)
  if (open === -1) return null
  let depth = 0
  for (let i = open; i < masked.length; i++) {
    const c = masked[i]
    if (c === '[') depth++
    else if (c === ']') {
      depth--
      if (depth === 0) {
        const maskedSlice = masked.slice(open, i + 1)
        const items = []
        const re = /'[^'\n]*'|"[^"\n]*"/g
        let m
        while ((m = re.exec(maskedSlice)) !== null) {
          const from = open + m.index + 1
          const to = open + m.index + m[0].length - 1
          items.push(raw.slice(from, to))
        }
        return items
      }
    }
  }
  return null
}

// meta 宣言内の requiredArgs: [...] を静的に読む。未宣言は null。
export function extractMetaRequiredArgs(metaRaw, metaMasked) {
  const m = /(^|[\s,{])requiredArgs\s*:/.exec(metaMasked)
  if (!m) return null
  return extractArrayAfter(metaRaw, metaMasked, m.index)
}

// body の const REQUIRED_ARGS = [...] を読む。未宣言は null。
export function extractBodyRequiredArgs(bodyRaw, bodyMasked) {
  const m = /(^|[\s;{])(?:const|let|var)\s+REQUIRED_ARGS\s*=/.exec(bodyMasked)
  if (!m) return null
  return extractArrayAfter(bodyRaw, bodyMasked, m.index)
}

export function sameSet(a, b) {
  if (!Array.isArray(a) || !Array.isArray(b)) return false
  const sa = [...new Set(a)].sort()
  const sb = [...new Set(b)].sort()
  return sa.length === sb.length && sa.every((v, i) => v === sb[i])
}

// args 参照（語境界付き・小文字 args のみ）の件数。
export function countArgsRefs(text) {
  const m = text.match(/\bargs\b/g)
  return m ? m.length : 0
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. marker block の抽出と sha256（従＝drift 検知）
// ─────────────────────────────────────────────────────────────────────────────

// marker は「行全体が marker literal と一致する行」だけを数える（散文で marker literal に言及した
// 行を marker と誤認しないため。複製規約も『marker 行ごと verbatim 複製』ゆえ行単位が正しい単位）。
export function extractMarkerBlock(src) {
  const lines = src.split('\n')
  const startIdx = []
  const endIdx = []
  lines.forEach((l, i) => {
    const t = l.trim()
    if (t === MARKER_START) startIdx.push(i)
    if (t === MARKER_END) endIdx.push(i)
  })
  const starts = startIdx.length
  const ends = endIdx.length
  if (starts === 0 && ends === 0) return { present: false, malformed: false, starts, ends, block: '' }
  if (starts !== 1 || ends !== 1 || endIdx[0] < startIdx[0]) return { present: true, malformed: true, starts, ends, block: '' }
  return { present: true, malformed: false, starts, ends, block: lines.slice(startIdx[0], endIdx[0] + 1).join('\n') }
}

export function sha256(text) {
  return createHash('sha256').update(text, 'utf8').digest('hex')
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. 挙動 probe
// ─────────────────────────────────────────────────────────────────────────────

const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor

export function compileBody(body) {
  return new AsyncFunction(...INJECTED_GLOBALS, body)
}

// positive control の args: 必須 args を全て非病的 filler（または呼出元指定の base）で埋めた 1 件。
// 「病的 args で死ぬ」だけを見ると、args と無関係に常に throw する preamble（＝全 run を殺す壊れた
// fail-fast）が合格してしまう。対の不変条件「正常 args では throw せず agent が起動する」を pin する。
export function buildPositiveArgs(requiredArgs, baseArgs) {
  const a = {}
  for (const k of requiredArgs) a[k] = baseArgs && baseArgs[k] !== undefined ? baseArgs[k] : PROBE_FILLER
  return a
}

// 病的 args シナリオの生成: 必須 args それぞれ × 4 形。
export function buildScenarios(requiredArgs, baseArgs) {
  const base = buildPositiveArgs(requiredArgs, baseArgs)
  const scenarios = []
  for (const target of requiredArgs) {
    for (const form of PATHOLOGICAL_FORMS) {
      const a = { ...base }
      if (form === 'omit') delete a[target]
      else if (form === 'literal-undefined') a[target] = 'undefined'
      else if (form === 'empty-string') a[target] = ''
      else if (form === 'bracket-undefined') a[target] = '[undefined]'
      scenarios.push({ name: `${target}:${form}`, args: a })
    }
  }
  return scenarios
}

// 1 シナリオを stub 環境で走らせ {agentCalls, workflowCalls, threw, errorName, errorMessage, returnedType,
// returnedKeys} を返す。
//
// ★ workflow() も計数する: nested workflow は agent 木ごと起動する＝本 lint が塞ごうとしている
//   「undefined を掴んだまま完走して token を溶かす」事故と同一クラスの副作用である。agent() だけを
//   不変条件の観測面にすると、fail-fast より前に nested WF を起動する形（modality 違い）が素通りする。
// ★ onStart(kind, label) は「仕事を始めた」の 2 modality（'agent' / 'workflow'）から等しく呼ばれる。
//   wrapper 側の timeout backstop（hang して報告が残らない経路）が両 modality を拾えるようにするため
//   （ERRATA-1 m2: agent のみ記録だと workflow() 起動 → hang が rc=1 でなく rc=2 に化ける）。
export async function runScenario(compiled, scenarioArgs, onStart) {
  let agentCalls = 0
  let workflowCalls = 0
  const notifyStart = (kind, label) => {
    if (typeof onStart === 'function') onStart(kind, label)
  }
  const agent = async (_prompt, opts) => {
    agentCalls++
    notifyStart('agent', (opts && opts.label) || '')
    return {} // throw させない（agent 起動の事実と fail-fast の throw を混同しない・notes ■3）
  }
  const parallel = async (thunks) =>
    Promise.all((Array.isArray(thunks) ? thunks : []).map((t) => Promise.resolve().then(t).catch(() => null)))
  const pipeline = async (items, ...stages) =>
    Promise.all(
      (Array.isArray(items) ? items : []).map(async (item, index) => {
        let cur = item
        for (const stage of stages) {
          try {
            cur = await stage(cur, item, index)
          } catch (e) {
            return null
          }
        }
        return cur
      })
    )
  const log = () => {}
  const phase = () => {}
  const budget = { total: null, spent: () => 0, remaining: () => Infinity }
  const workflow = async (nameOrRef) => {
    workflowCalls++
    notifyStart('workflow', typeof nameOrRef === 'string' ? nameOrRef : '(ref)')
    return null // agent stub と同じく throw させない（起動の事実と fail-fast の throw を混同しない）
  }

  let threw = false
  let errorName = ''
  let errorMessage = ''
  // ERRATA-1 m4: 返り値も回収する。ただし生値は載せない（WF の返り値は数百 KB になりうるうえ、
  // 被検査 script が判定行へ任意文字列を差し込む面にもなる）。型と shape（object なら key 一覧）だけを取る。
  let returnedType = 'undefined'
  let returnedKeys = []
  try {
    const returned = await compiled(agent, parallel, pipeline, log, phase, scenarioArgs, budget, workflow)
    returnedType = returned === null ? 'null' : Array.isArray(returned) ? 'array' : typeof returned
    if (returned && typeof returned === 'object' && !Array.isArray(returned)) {
      returnedKeys = Object.keys(returned).slice(0, 12)
    }
  } catch (e) {
    threw = true
    errorName = (e && e.name) || 'Error'
    errorMessage = String((e && e.message) || e).slice(0, 200).replace(/\s+/g, ' ')
  }
  return { agentCalls, workflowCalls, threw, errorName, errorMessage, returnedType, returnedKeys }
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. 判定本体（純関数 + probe 実行）: {rc, out[], err[]} を返す
// ─────────────────────────────────────────────────────────────────────────────

export async function lint(opts) {
  const out = []
  const err = []
  const label = opts.label || opts.file || '(stdin)'
  const inconclusive = (id, detail) => {
    out.push(`INCONCLUSIVE ${id} ${label} ${detail}`)
    return { rc: 2, out, err }
  }
  const violation = (id, detail) => {
    out.push(`VIOLATION ${id} ${label} ${detail}`)
    return { rc: 1, out, err }
  }

  if (opts.mode !== 'skeleton' && opts.mode !== 'adhoc') {
    return inconclusive('MODE_UNSET', `--mode は skeleton|adhoc のいずれかが必須（受領: ${opts.mode || '(none)'}）`)
  }

  const src = opts.source
  const masked = maskSource(src)
  if (!masked.ok) return inconclusive('MASK_FAILED', `コメント/文字列を除去できない: ${masked.reason}`)

  const stripped = stripMeta(src, masked.masked)
  const metaRaw = stripped.metaSource
  const metaMasked = stripped.hadMeta ? maskSource(metaRaw) : { masked: '', ok: true }
  if (!metaMasked.ok) return inconclusive('MASK_FAILED', `meta 宣言を mask できない: ${metaMasked.reason}`)

  // 構文検査（実ハーネス準拠の wrap）。ここで落ちるものは判定不能（mask 誤り・本当の構文破綻の両方を捕まえる）。
  let compiled
  try {
    compiled = compileBody(stripped.body)
  } catch (e) {
    return inconclusive('PARSE_FAILED', `AsyncFunction wrap の compile 失敗: ${String((e && e.message) || e).replace(/\s+/g, ' ').slice(0, 160)}`)
  }

  // ── 対象外判定 1: args 参照 0 hit ───────────────────────────────────────────
  const maskedRefs = countArgsRefs(stripped.maskedBody)
  if (maskedRefs === 0) {
    const rawRefs = countArgsRefs(stripped.body)
    const reason = `args 参照 0 hit（コメント/文字列を除いた body での実参照。raw では ${rawRefs} hit）`
    out.push(`SKIP ${label} ${reason}`)
    err.push(`skip: ${label}: ${reason}`)
    out.push(`summary: checked=0 skipped=1 violations=0 inconclusive=0`)
    return { rc: 0, out, err }
  }

  // ── 必須 args の確定（宣言 or 呼出元の明示指定） ─────────────────────────────
  const declMeta = stripped.hadMeta ? extractMetaRequiredArgs(metaRaw, metaMasked.masked) : null
  const declBody = extractBodyRequiredArgs(stripped.body, stripped.maskedBody)
  let requiredArgs = null
  let requiredSource = ''

  if (opts.explicitRequired || opts.explicitProbeArgsObject !== undefined) {
    // 呼出元（bats の legacy allowlist 等）が probe args / 必須集合を明示した経路。
    // 宣言を持たない既存骨格を検査する唯一の入口＝表は呼出元が持つ（engine に path をハードコードしない）。
    requiredArgs = opts.explicitRequired || []
    requiredSource = opts.explicitRequired ? 'caller-supplied' : 'caller-supplied probe-args(必須集合は非申告)'
  } else {
    // mask 誤検知の交差検査: **コード面**（mask 後）に宣言 token が在るのに抽出できない = 判定不能へ倒す。
    //
    // ★ 検査面は raw ではなく masked でなければならない。raw を見ると「コメント/文字列で token に言及した」
    //   だけの script（宣言は一切無い）が MASK_AMBIGUOUS(rc=2) に倒れ、notes ■2 の「双方とも無い script は
    //   対象外＝rc=0・宣言が無いことを理由に落とさない」に反する（かつ maskSource が正しく働いた結果を
    //   「mask の取りこぼし」と誤って報告する＝masking の意味を自ら打ち消す）。実宣言なら token は masked
    //   にも残るので、交差検査の目的（regex が実在宣言を取りこぼしたかの検知）は masked だけで達成できる。
    const codeText = `${stripped.maskedBody}\n${metaMasked.masked || ''}`
    const tokenMissed = (token, found) => new RegExp(`\\b${token}\\b`).test(codeText) && !found
    if (tokenMissed('REQUIRED_ARGS', declBody !== null) || tokenMissed('requiredArgs', declMeta !== null)) {
      return inconclusive('MASK_AMBIGUOUS', '宣言 token がコード面（mask 後）に在るが抽出できない（宣言形が regex の想定外）')
    }
    if (declMeta === null && declBody === null) {
      const reason = '必須 args 宣言なし（meta.requiredArgs / body の REQUIRED_ARGS とも不在）＝対象外'
      out.push(`SKIP ${label} ${reason}`)
      err.push(`skip: ${label}: ${reason}`)
      out.push(`summary: checked=0 skipped=1 violations=0 inconclusive=0`)
      return { rc: 0, out, err }
    }
    if (declMeta === null || declBody === null) {
      return inconclusive(
        'DECL_MISMATCH',
        `必須 args 宣言が片面のみ（meta.requiredArgs=${declMeta === null ? '不在' : JSON.stringify(declMeta)} / REQUIRED_ARGS=${declBody === null ? '不在' : JSON.stringify(declBody)}）。二面宣言と集合一致が必要`
      )
    }
    if (!sameSet(declMeta, declBody)) {
      return inconclusive(
        'DECL_MISMATCH',
        `静的宣言と動的宣言の集合が不一致（meta.requiredArgs=${JSON.stringify(declMeta)} / REQUIRED_ARGS=${JSON.stringify(declBody)}）`
      )
    }
    requiredArgs = declBody
    requiredSource = 'declared(two-faced)'
  }

  // ── シナリオ生成 ────────────────────────────────────────────────────────────
  let scenarios
  if (opts.explicitProbeArgsObject !== undefined) {
    scenarios = [{ name: 'caller-supplied', args: opts.explicitProbeArgsObject }]
  } else {
    if (!requiredArgs || requiredArgs.length === 0) {
      return inconclusive('NO_SCENARIOS', '必須 args 集合が空で病的 args を組めない（--probe-args か宣言が必要）')
    }
    scenarios = buildScenarios(requiredArgs, opts.baseArgs)
  }

  // ── 挙動 probe（主）────────────────────────────────────────────────────────
  const expect = opts.expect === 'legacy' ? 'legacy' : 'canonical'
  const results = []
  for (const sc of scenarios) {
    // marker は「hang して報告が残らない」経路の backstop。agent / workflow の**両 modality**から書く
    // （ERRATA-1 m2: workflow() 起動 → hang が rc=2 に化けるのを塞ぐ）。
    const r = await runScenario(compiled, sc.args, (kind) => {
      if (opts.agentMarkerPath) {
        try {
          appendFileSync(opts.agentMarkerPath, `${kind === 'workflow' ? 'WORKFLOW_CALLED' : 'AGENT_CALLED'} ${sc.name}\n`)
        } catch (e) {
          /* marker は timeout 時の backstop。書けなくても probe 自体は続ける */
        }
      }
    })
    results.push({ ...r, name: sc.name })
  }

  // 「仕事を始めた」の観測面は agent() と workflow() の 2 modality（nested workflow は agent 木ごと起動する）。
  const started = results.filter((r) => r.agentCalls > 0 || r.workflowCalls > 0)
  if (started.length > 0) {
    const s = started[0]
    return violation(
      'AGENT_STARTED_BEFORE_FAILFAST',
      `病的 args（${s.name}）で agent()=${s.agentCalls} 回 / workflow()=${s.workflowCalls} 回 起動した（fail-fast より前に仕事を始めている）。expect=${expect} required=${JSON.stringify(requiredArgs)}(${requiredSource})`
    )
  }

  // ReferenceError での「throw」は意図した fail-fast ではない（meta 参照等が実機で落ちている形）。
  const refErr = results.find((r) => r.threw && r.errorName === 'ReferenceError')
  if (refErr) {
    return violation(
      'RUNTIME_REFERENCE_ERROR',
      `病的 args（${refErr.name}）で ReferenceError が出た（意図した fail-fast ではない。meta 切除後に body が meta 等を参照している可能性）: ${refErr.errorMessage}`
    )
  }

  if (expect === 'canonical') {
    const noThrow = results.filter((r) => !r.threw)
    if (noThrow.length > 0) {
      return violation(
        'NO_THROW_ON_MISSING_ARGS',
        `病的 args ${noThrow.length}/${results.length} 件（例: ${noThrow[0].name}）で throw せず完走した（agentCalls=0 だが escalate return 形＝P0-2 canonical 不適合）。returned=${noThrow[0].returnedType}${noThrow[0].returnedKeys.length ? `[${noThrow[0].returnedKeys.join(',')}]` : ''}`
      )
    }
  }

  // ── positive control（主の対の不変条件）────────────────────────────────────
  // 「正常 args では throw せず agent が起動する」。これを見ないと、args と無関係に常に throw する
  // preamble（全 run を殺す壊れた fail-fast）が「病的 args で agentCalls=0 かつ throw」を満たして合格する。
  // 呼出元が probe args を verbatim 指定した経路（骨格別 legacy allowlist）では適用しない
  // ＝表の意味（その args でどう振る舞うか）を engine 側で書き換えないため（notes ■1）。
  //
  //   ★ 違反として判定できるのは「agent 到達**前**に throw した」場合だけである（不変条件は
  //     「正常 args で fail-fast しない」であって「body 全体が stub 環境で完走する」ではない）。
  //     3 事象を 1 つの違反 ID に畳まないこと（畳むと準拠 script に偽 VIOLATION が出る＝false-RED）:
  //       ① threw && agentCalls===0 → 本来の不変条件違反の候補（ただし下記の帰属確認が要る）
  //       ② threw && agentCalls>0   → agent 到達**後**の下流 throw（stub の返り値形状差など）。
  //                                   positive control の射程外＝違反ではない。
  //       ③ !threw && agentCalls===0 → filler 値では骨格自身の意味的検証に落ちて agent へ届かない形。
  //                                   違反ではなく**判定不能**（rc=2・実値を --base-args で与えよ、の誘導）。
  //     ① のうち throw が args preamble 由来であること（message に FAILFAST_MARKER を含む）まで
  //     機械照合できたものだけを VIOLATION とし、帰属できない throw は rc=2 に倒す（rc=0 へは丸めない）。
  //
  //   ★ ただし ReferenceError だけは先に分岐する（ERRATA-1 m1）。canonical 配置（block が body 先頭・
  //     meta 参照はその後段）では、病的 args のシナリオは block で必ず throw して meta 参照へ到達しないため、
  //     sc-ojom ギャップ（実ハーネスが meta 宣言を切り落とすので meta 参照は実機で ReferenceError になる）は
  //     **positive 経路でしか観測できない**。ここを「帰属できない throw」として rc=2 に畳むと、
  //     本 leg が塞ぐべき実機 crash が判定不能に化け、しかも誘導文（--base-args を与えよ）が誤導になる。
  let positiveLine = 'positiveControl=skipped(caller-supplied probe-args)'
  if (opts.explicitProbeArgsObject === undefined) {
    const positiveArgs = buildPositiveArgs(requiredArgs, opts.baseArgs)
    // agent marker は「病的 args で agent が起動した」ことの backstop なので positive では書かない。
    const pr = await runScenario(compiled, positiveArgs, null)
    const posDetail = `expect=${expect} required=${JSON.stringify(requiredArgs)}(${requiredSource}) positiveArgs=${JSON.stringify(positiveArgs)}`
    if (pr.threw && pr.errorName === 'ReferenceError') {
      return violation(
        'RUNTIME_REFERENCE_ERROR',
        `正常 args で ReferenceError が出た（意図した fail-fast ではない。実ハーネスは meta 宣言を body から切り落とすため、body の meta 参照等はここでのみ観測される＝sc-ojom ギャップ）: ${pr.errorMessage}。${posDetail}`
      )
    }
    if (pr.threw && pr.agentCalls === 0) {
      if (pr.errorMessage.includes(FAILFAST_MARKER)) {
        return violation(
          'FAILFAST_FALSE_POSITIVE',
          `正常 args でも args preamble の fail-fast が発火した（${pr.errorName}: ${pr.errorMessage}）＝fail-fast が args と無関係に発火している（全 run を殺す preamble）。${posDetail}`
        )
      }
      return inconclusive(
        'POSITIVE_THROW_UNATTRIBUTED',
        `正常 args で agent 到達前に throw したが、args preamble 由来（message に ${FAILFAST_MARKER}）と機械照合できない（${pr.errorName}: ${pr.errorMessage}）。実値を --base-args で与えて再実行せよ。${posDetail}`
      )
    }
    if (!pr.threw && pr.agentCalls === 0) {
      return inconclusive(
        'POSITIVE_UNREACHED',
        `正常 args で throw も agent 到達も起きなかった（filler 値では骨格自身の意味的検証で早期 return した形）＝positive control を判定できない。実値を --base-args で与えて再実行せよ。${posDetail}`
      )
    }
    positiveLine = pr.threw
      ? `positiveControl=ok(agentCalls=${pr.agentCalls},downstreamThrow=${pr.errorName}:射程外,returned=${pr.returnedType})`
      : `positiveControl=ok(agentCalls=${pr.agentCalls},returned=${pr.returnedType}${pr.returnedKeys.length ? `[${pr.returnedKeys.join(',')}]` : ''})`
  }

  // ── byte-pin（従・skeleton mode のみ）──────────────────────────────────────
  let pinLine = 'bytePin=skipped(snippet 未指定 or adhoc)'
  if (opts.mode === 'skeleton' && opts.snippetSource !== undefined) {
    const target = extractMarkerBlock(src)
    const canonical = extractMarkerBlock(opts.snippetSource)
    if (!canonical.present || canonical.malformed) {
      return inconclusive('SNIPPET_MALFORMED', `canonical snippet の marker block が不正（start=${canonical.starts} end=${canonical.ends}）`)
    }
    if (!target.present) {
      pinLine = `bytePin=absent(SCARGS marker 未複製・波1 sc-k33c 項目6 で複製予定) canonicalSha=${sha256(canonical.block).slice(0, 12)}`
    } else if (target.malformed) {
      return violation('MARKER_MALFORMED', `SCARGS marker が不正（start=${target.starts} end=${target.ends}・各 1 個が必要）`)
    } else if (sha256(target.block) !== sha256(canonical.block)) {
      return violation(
        'SNIPPET_BLOCK_DRIFT',
        `SCARGS block が canonical snippet と byte 不一致（target=${sha256(target.block).slice(0, 12)} canonical=${sha256(canonical.block).slice(0, 12)}）`
      )
    } else {
      pinLine = `bytePin=match(${sha256(canonical.block).slice(0, 12)})`
    }
  }

  // 病的シナリオの返り値型（ERRATA-1 m4 の回収面。canonical 準拠なら全件 throw ゆえ undefined に潰れる）
  const pathReturned = [...new Set(results.map((r) => (r.threw ? `throw:${r.errorName}` : r.returnedType)))].join('|')
  out.push(
    `OK ${label} expect=${expect} scenarios=${results.length} agentCalls=0 workflowCalls=0 pathReturned=${pathReturned} ${positiveLine} required=${JSON.stringify(requiredArgs)}(${requiredSource}) ${pinLine}`
  )
  out.push(`summary: checked=1 skipped=0 violations=0 inconclusive=0`)
  return { rc: 0, out, err }
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. CLI（wrapper から呼ばれる。報告は --report file へ `RC n` / `OUT ...` / `ERR ...` 行で書き出す
//    ＝probe 対象の stdout/stderr は wrapper 側で破棄されるため、判定結果を別経路で運ぶ）
// ─────────────────────────────────────────────────────────────────────────────

function parseArgv(argv) {
  const o = { mode: '', file: '', report: '', agentMarker: '', expect: 'canonical', snippet: '', stdinFile: '' }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    const next = () => argv[++i]
    if (a === '--mode') o.mode = next()
    else if (a === '--file') o.file = next()
    else if (a === '--report') o.report = next()
    else if (a === '--agent-marker') o.agentMarker = next()
    else if (a === '--expect') o.expect = next()
    else if (a === '--snippet') o.snippet = next()
    else if (a === '--probe-args') o.probeArgs = next()
    else if (a === '--required') o.required = next()
    else if (a === '--base-args') o.baseArgs = next()
    else if (a === '--label') o.label = next()
  }
  return o
}

function writeReport(reportPath, rc, out, err) {
  const lines = [`RC ${rc}`]
  for (const l of out) lines.push(`OUT ${String(l).replace(/[\r\n]+/g, ' ')}`)
  for (const l of err) lines.push(`ERR ${String(l).replace(/[\r\n]+/g, ' ')}`)
  if (reportPath) writeFileSync(reportPath, lines.join('\n') + '\n')
  else process.stdout.write(lines.join('\n') + '\n')
}

async function main() {
  const o = parseArgv(process.argv.slice(2))
  try {
    if (!o.file) {
      writeReport(o.report, 2, ['INCONCLUSIVE NO_INPUT (none) --file が空（wrapper が stdin を一時 file 化して渡す）'], [])
      return
    }
    const source = readFileSync(o.file, 'utf8')
    let explicitProbeArgsObject
    if (o.probeArgs !== undefined) {
      try {
        explicitProbeArgsObject = JSON.parse(o.probeArgs)
      } catch (e) {
        writeReport(o.report, 2, [`INCONCLUSIVE BAD_PROBE_ARGS ${o.label || o.file} --probe-args が JSON として parse 不能`], [])
        return
      }
    }
    const explicitRequired = o.required ? o.required.split(',').map((s) => s.trim()).filter(Boolean) : null
    let baseArgs
    if (o.baseArgs !== undefined) {
      try {
        baseArgs = JSON.parse(o.baseArgs)
      } catch (e) {
        writeReport(o.report, 2, [`INCONCLUSIVE BAD_BASE_ARGS ${o.label || o.file} --base-args が JSON として parse 不能`], [])
        return
      }
    }
    const r = await lint({
      mode: o.mode,
      source,
      snippetSource: o.snippet ? readFileSync(o.snippet, 'utf8') : undefined,
      label: o.label || o.file,
      expect: o.expect,
      explicitProbeArgsObject,
      explicitRequired,
      baseArgs,
      agentMarkerPath: o.agentMarker,
    })
    writeReport(o.report, r.rc, r.out, r.err)
  } catch (e) {
    writeReport(o.report, 2, [`INCONCLUSIVE DRIVER_ERROR ${o.label || o.file || '(unknown)'} ${String((e && e.message) || e).replace(/\s+/g, ' ').slice(0, 200)}`], [])
  }
}

// CLI として起動されたときだけ main を走らせる（import 時は純関数群だけを提供する＝TS 移植可能形）。
if (process.argv[1] && process.argv[1].endsWith('wf-args-probe.mjs')) {
  await main()
}

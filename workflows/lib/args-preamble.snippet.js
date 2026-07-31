// workflows/lib/args-preamble.snippet.js — dynamic workflow の args preamble canonical SSOT
// （sc-4t3t / L0a・P0-2 裁定 2026-07-31 = orch-wnt4 反映）
//
// ■ これは何か
//   Workflow tool の script（骨格・ad-hoc とも）が body 冒頭に置くべき「args 受け取り規律」の唯一の正本。
//   3 部構成: (1) defensive parse と正規化 / (2) receivedArgs（呼出元の一次監査面）/ (3) 必須 args fail-fast。
//
// ■ なぜ throw なのか（P0-2 裁定）
//   args 解決段（＝最初の agent() 呼出より前）の必須 args 欠落・undefined・空・"[undefined]" は【即 throw】して
//   run を殺す。escalate return 形は「undefined を掴んだまま完走」を構造的に止められない（実害: anchor=undefined の
//   まま 1,435,749 token / 54.9 分を silent 完走した事故）。agent 起動後の in-run 失敗は従来どおり
//   return {escalate:true, ...} = 呼出元の一次監査に載せる設計を維持する（本 snippet の射程外）。
//
// ■ なぜ meta を実行時参照しないのか
//   実ハーネスは `export const meta = {...}` 宣言を body から切り落としてから body を評価する。meta を実行時参照すると
//   テスト用 driver（`export ` を剥がすだけの旧方式）では通り、実機でだけ ReferenceError になる（sc-ojom の既知
//   ギャップ）。よって必須 args は body 側の REQUIRED_ARGS を直に読む。
//
// ■ 複製規約（波1 = sc-k33c 項目6 が実施）
//   //SCARGS_BLOCK_START 〜 //SCARGS_BLOCK_END の間（marker 行を含む）を **verbatim** で複製する。
//   block 内には固有物を一切書かない＝block は全 WF で byte 一致する（scripts/scribe-wf-args-lint.sh の
//   sha256 byte-pin の照合面）。WF 固有の必須 args は block の**直前**に REQUIRED_ARGS として宣言し、
//   同じ集合を `export const meta` の requiredArgs にも置く（engine の静的面・二面宣言 = 集合一致を要求）。
//
// ■ 下の REQUIRED_ARGS はサンプル（複製先が自分の必須 args へ差し替える。block の外＝byte-pin の対象外）。
const REQUIRED_ARGS = ['anchor', 'targetBead']

//SCARGS_BLOCK_START
// (1) defensive parse と正規化: string 到達（呼出元が args を JSON 文字列化した経路）は JSON.parse で吸収し、
//     object でないもの（'null' / '42' / 配列）は空 object へ倒す。parse 失敗は黙って {} にせず (3) で throw する。
const __scargsRawType = args === null ? 'null' : Array.isArray(args) ? 'array' : typeof args
let __scargsParseFailed = false
let __scargsParseError = ''
let A = {}
if (typeof args === 'string') {
  try {
    const __scargsParsed = JSON.parse(args)
    A = __scargsParsed && typeof __scargsParsed === 'object' && !Array.isArray(__scargsParsed) ? __scargsParsed : {}
  } catch (e) {
    __scargsParseFailed = true
    __scargsParseError = e && e.message ? e.message : 'invalid JSON'
  }
} else if (args && typeof args === 'object' && !Array.isArray(args)) {
  A = args
}

// (2) receivedArgs: 「何が届いたか」を呼出元が一次監査するための要約。field 名は **type** に統一する
//     （rawType 等に割れると監査 harness が読めない＝sc-4t3t で統一を確定）。
const receivedArgs = {
  type: __scargsRawType,
  parseFailed: __scargsParseFailed,
  keys: Object.keys(A),
  keyTypes: Object.fromEntries(Object.keys(A).map((k) => [k, Array.isArray(A[k]) ? 'array' : typeof A[k]])),
}

// (3) 必須 args fail-fast（throw 形）: 欠落 / literal "undefined" / 空文字 / "[undefined]" / 空配列を等しく
//     「不在」と判定する。非空判定だけでは literal "undefined" が素通りする（mandate-verify.workflow.js:50 の実測）。
const __scargsAbsent = (v) => {
  if (v === undefined || v === null) return true
  if (typeof v === 'string') {
    const t = v.trim()
    return t === '' || t === 'undefined' || t === '[undefined]'
  }
  if (Array.isArray(v)) return v.length === 0
  return false
}
const __scargsMissing = REQUIRED_ARGS.filter((k) => __scargsAbsent(A[k]))
if (__scargsParseFailed || __scargsMissing.length > 0) {
  const __scargsReason = __scargsParseFailed
    ? 'args が JSON 文字列として届いたが parse 不能: ' + __scargsParseError
    : '必須 args 欠落/未解決: ' + __scargsMissing.join(' / ')
  throw new Error('[SCARGS fail-fast] ' + __scargsReason + ' / received=' + JSON.stringify(receivedArgs))
}
//SCARGS_BLOCK_END

// ここから下は複製先 WF の本体（args を A から読む・receivedArgs を返り値に載せる）。

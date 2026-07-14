export const meta = {
  name: 'mandate-verify',
  description:
    'dispatch 前の mandate（bead 契約）忠実性敵対検証の凍結骨格: 対象 bead の契約を複数 lens が並列に実測検証（read-only 構造強制・opus）し、opus 統合 agent が severity 降順 findings + verdict（OK/NEEDS-FIX）+ そのまま --append-notes へ渡せる scope-fence 文案を返す。固有物（anchor/targetBead/riderBead/lenses/rulingRef/facts/cellConstraints）は args で差し込む（骨格は再利用・orch-thgx program 5 run 実証形の凍結＝orch-u3fk/sc-ihdy）。',
  whenToUse:
    'orchestrator/admin が worker cell へ bead 契約を dispatch する前に、契約の罠（偽 DONE/偽 BLOCKED/acceptance 達成不能/退行/per-leg 分割要）を敵対的に洗いたいとき。args={anchor: 台帳 anchor 絶対パス（必須）, targetBead: 対象 bead id（必須）, lenses: [{key, q}]（必須・相互独立な検証軸。q は lens 固有の指示文）, riderBead?: 相乗り bead id（本体と同時に read）, rulingRef?: 裁定一次 SSOT の指し先（例: 「bd show orch-thgx」notes の裁定-topology 行）, facts?: 実測済み前提事実（そのまま前提にさせる）, cellConstraints?: worker cell 制約の列挙（既定=bwrap sandbox・git worktree・外向き spawn 不可・foreign 台帳 write 不可）, model?: agent model（既定 opus）, roAgentType?: read-only agentType 上書き（既定 scribe:explore・"none" で agentType 無し強制）}。返り値 synthesis を呼出元が一次監査し、fence 文案を bead notes へ追記してから dispatch する。',
  phases: [
    { title: 'Verify', detail: '各 lens を並列 read-only agent が敵対検証（bd show 契約読解 → 実測 → findings）', model: 'opus' },
    { title: 'Synthesize', detail: '全 lens findings を severity 降順で統合し verdict + scope-fence 文案を返す', model: 'opus' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────────
// 設計の核(維持すること):
//  (1) 全段 read-only。lens agent は観測・実測(bd show / grep / 実ファイル読解)だけを行い、bd write・
//      ファイル編集・spawn を一切しない(agentType 'scribe:explore' の構造強制 + roAgent fallback=sc-7bv 同型)。
//  (2) lens は相互独立な検証軸(multi-modal sweep)。互いの結論を見ずに独立検証し、統合は Synthesize に一元化。
//  (3) fail-closed: lens 欠損(agent null 死)は Synthesize prompt に明記させ verdict を NEEDS-FIX 側へ倒す。
//      全 lens 欠損なら Synthesize を呼ばず escalate=true で即 return(空データからの false-OK を構造封鎖)。
//  (4) defensive args parse(cell-quality/prebake と同型・un-2yy): string 到達は JSON.parse で吸収、parse 失敗・
//      必須欠落(anchor/targetBead/lenses)・**lens 不正形(key/q 欠落)の混入**は agent を一切起動せず
//      escalate=true + 明示 reason で即 return。不正形 lens を silent drop して残りだけで回すと「呼出元が意図した
//      検証軸が黙殺されたまま verdict=OK」という false-OK 経路になる(sc-ihdy gate B4)ため、drop でなく fail-fast。
//      返り値へ receivedArgs 要約(受信型 + キー一覧)を載せ、呼出元が「何が届いたか」を一次監査できるようにする。
//  (5) run 識別: meta.name は純リテラル制約で run ごとに変えられないため、args 解決直後に log('[<targetBead>] …')
//      を必ず出す(同名 WF 並走時に /workflows 進行ビューで run を区別する唯一の手段)。
//  (6) 凍結の由来: scriptorium orch-thgx program(2026-07-13〜14)の手書き 5 run
//      (wf_85574420/wf_47846a7e/wf_82c16055/wf_244e36cb/wf_2c64f047)が全て CRITICAL/HIGH の実在罠
//      (per-leg 分割勧告 2・acceptance 達成不能 3・退行罠 2)を dispatch 前に捕捉した収束形。run ごとに変わるのは
//      lens 本文・対象 bead・前提事実という「データ」だけ=args 化(methodology D5: 骨格ロジックは汎用・固有はデータ)。
// ─────────────────────────────────────────────────────────────────────────────

// ── defensive args parse(設計核(4)) ─────────────────────────────────────────
const __rawArgsType = args === null ? 'null' : Array.isArray(args) ? 'array' : typeof args
let A = {}
let __parseFailed = false
if (typeof args === 'string') {
  // string 到達 = 呼出元が args を JSON 文字列化した経路。parse して object へ正規化する。
  try {
    const parsed = JSON.parse(args)
    A = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
  } catch (e) {
    __parseFailed = true
  }
} else if (args && typeof args === 'object' && !Array.isArray(args)) {
  A = args
}
const receivedArgs = { rawType: __rawArgsType, keys: Object.keys(A), parseFailed: __parseFailed }

const anchor = typeof A.anchor === 'string' ? A.anchor.trim() : ''
const targetBead = typeof A.targetBead === 'string' ? A.targetBead.trim() : ''
const riderBead = typeof A.riderBead === 'string' ? A.riderBead.trim() : ''
const rulingRef = typeof A.rulingRef === 'string' ? A.rulingRef.trim() : ''
const facts = typeof A.facts === 'string' ? A.facts.trim() : ''
const cellConstraints =
  (typeof A.cellConstraints === 'string' && A.cellConstraints.trim()) ||
  'bwrap sandbox・git worktree・外向き spawn 不可・foreign 台帳 write 不可'
const MODEL = (typeof A.model === 'string' && A.model.trim()) || 'opus'
const rawLenses = Array.isArray(A.lenses) ? A.lenses : []
const lenses = rawLenses.filter(
  (l) =>
    l && typeof l === 'object' &&
    typeof l.key === 'string' && l.key.trim() &&
    typeof l.q === 'string' && l.q.trim()
)
const droppedLenses = rawLenses.length - lenses.length

// fail-fast: 契約が不明なまま agent を起動しない(silent 暴走根治)。不正形 lens の混入(droppedLenses>0)も
// fail-fast する——silent drop で残り lens だけで回すと、呼出元が意図した検証軸が黙殺されたまま
// verdict=OK になる false-OK 経路が開く(設計核(4)・sc-ihdy gate B4)。
if (__parseFailed || !anchor || !targetBead || lenses.length === 0 || droppedLenses > 0) {
  const reason = __parseFailed
    ? 'args が JSON 文字列として届いたが parse 不能(呼出元 serialization 破損)'
    : lenses.length > 0 && droppedLenses > 0
      ? `lenses に不正形が ${droppedLenses} 件混入(key/q が欠落 or 空)。検証軸の黙殺(false-OK)を防ぐため drop せず fail-fast する——呼出元は全 lens を {key, q} の非空文字列で渡し直すこと。`
      : `必須 args 欠落: ${[
          !anchor && 'anchor',
          !targetBead && 'targetBead',
          lenses.length === 0 && 'lenses({key,q} の有効な要素が 1 件も無い)',
        ]
          .filter(Boolean)
          .join(' / ')}`
  log(`[mandate-verify] fail-fast: ${reason}`)
  return {
    escalate: true,
    reason,
    verdict: 'NEEDS-FIX',
    synthesis: null,
    lensCount: 0,
    expectedLenses: rawLenses.length,
    droppedLenses,
    receivedArgs,
  }
}

// ── run 識別(設計核(5)・CLAUDE.md「args 受け取り型 WF は起動直後に識別子を log」) ──
// ここに到達した時点で lenses は全件有効(不正形は上の fail-fast で弾いた=silent 縮退なし)。
log(
  `[${targetBead}] mandate-verify: lenses=${lenses.length}(${lenses.map((l) => l.key).join(',')})` +
    `${riderBead ? ` rider=${riderBead}` : ''}`
)

// ── read-only agentType の fallback(sc-7bv/sc-xyw 同型・prebake から転写) ────
// 'scribe:explore' が registry で解決不能な session(scribe plugin 未ロード / registry drift)では agentType 省略へ
// 後退し read-only 規律を prompt で代替する。args.roAgentType で差し替え・'none' で最初から agentType 無し強制。
const _rawRoAgentType = typeof A.roAgentType === 'string' ? A.roAgentType.trim() : ''
const RO_AGENT_TYPE = _rawRoAgentType || 'scribe:explore'
const RO_FORCE_NONE = RO_AGENT_TYPE === 'none' // 'none' = 最初から agentType を付けない強制
let roFallbackActive = RO_FORCE_NONE // not found を一度検知したら以降降格(flag・並行 race は同じ降格へ収束=無害)

const RO_DISCIPLINE =
  '\n\n## 厳守（read-only・agentType 構造強制の代替）\n' +
  'あなたは read-only の観測・分析役。ファイル編集(Write/Edit)・git write(commit/push/add)・bd write・deploy・' +
  '別 agent の spawn を一切しない。Bash は読取り・検証実行(git read / bd show 等)に限り、コード・状態を変えない。' +
  '返り値(検証結果テキスト)だけを返す(呼出元が一次監査する)。'

// registry から agentType が解決できなかった throw かを判定(probe verified のエラー形状)。not found 以外は透過。
const isAgentTypeNotFound = (e) => {
  const m = e && e.message ? String(e.message) : String(e == null ? '' : e)
  return /agent type\b[\s\S]*\bnot found/i.test(m) || /not found\. Available agents:/i.test(m)
}

async function roAgent(prompt, opts) {
  const base = { ...(opts || {}) }
  delete base.agentType // agentType の管理は roAgent に一元化(呼出サイトは指定しない)
  if (roFallbackActive) return agent(prompt + RO_DISCIPLINE, base)
  try {
    return await agent(prompt, { ...base, agentType: RO_AGENT_TYPE })
  } catch (e) {
    if (isAgentTypeNotFound(e)) {
      roFallbackActive = true
      log(
        `[RO-FALLBACK] read-only agentType '${RO_AGENT_TYPE}' が registry で解決不能(${e && e.message ? String(e.message).slice(0, 120) : 'not found'})。agentType 省略へ後退し read-only 規律を prompt で代替する。`
      )
      return agent(prompt + RO_DISCIPLINE, base)
    }
    throw e // not found 以外は透過(parallel の null 正規化=設計核(3) の欠損検知に乗せる)
  }
}

// ── 共通 preamble(5 run 収束形の凍結・run 固有部は args から差し込み) ─────────
const common = `
あなたは dispatch 前の mandate（bead 契約）忠実性敵対検証 agent。read-only 規律: ファイル編集・bd write・spawn・ホスト状態変更は一切しない（Bash は読取り・grep・bd show/list 等の read のみ）。
対象: 台帳 bead ${targetBead}${riderBead ? `（本体）+ ${riderBead}（相乗り rider）` : ''}。anchor = ${anchor}（cwd はここ）。
まず「bd show ${targetBead}」${riderBead ? `「bd show ${riderBead}」` : ''}を読み、契約（description/notes/acceptance）を把握せよ。${rulingRef ? `裁定の一次 SSOT は ${rulingRef}。` : ''}
${facts ? `実測済み事実（そのまま前提にせよ）: ${facts}\n` : ''}この契約を worker cell（${cellConstraints}）へそのまま渡した場合に、worker が「偽 DONE / 偽 BLOCKED / 誤実装 / false-green / 台帳汚染」に陥る芽を敵対的に探せ。
出力形式: 各 finding を「## [severity] タイトル」「**根拠(verified/deduced/inferred)**: 実測（ファイル:行番号・grep 結果・実出力）」「**修正提案文（notes へ追記可能な形）**」の 3 部で。事実(verified)と推測(inferred)を必ず区別。finding が無い軸は「問題なし＋確認した根拠」を明記。最後に verdict（OK / NEEDS-FIX）と一行理由。
`

// ── Verify: 全 lens を並列敵対検証(設計核(2)) ────────────────────────────────
phase('Verify')
const results = await parallel(
  lenses.map((l) => () =>
    roAgent(common + '\n' + l.q, {
      label: `verify:${l.key}`,
      phase: 'Verify',
      model: MODEL,
    })
  )
)

// ── Synthesize: 統合 + verdict + scope-fence 文案(設計核(3) fail-closed) ─────
phase('Synthesize')
const valid = results.filter(Boolean)
const missing = lenses.length - valid.length
log(`[${targetBead}] lens 完了: ${valid.length}/${lenses.length}（欠損 ${missing}）`)

if (valid.length === 0) {
  // 全 lens 欠損 = 検証データ不在。空データから Synthesize が OK を作文する経路を構造封鎖する。
  return {
    escalate: true,
    reason: '全 lens が欠損(agent null 死)＝検証データ不在。false-OK を防ぐため Synthesize を回さず NEEDS-FIX で返す。',
    verdict: 'NEEDS-FIX',
    synthesis: null,
    lensCount: 0,
    expectedLenses: lenses.length,
    roFallbackActive,
    receivedArgs,
  }
}

const synthesis = await roAgent(
  `あなたは mandate 敵対検証の統合 agent。以下は ${targetBead}${riderBead ? `（+rider ${riderBead}）` : ''} の ${valid.length}/${lenses.length} lens 検証結果である。read-only。
重複を統合し severity 降順で単一 findings 文書（markdown）へ。各 finding に「notes へ追記可能な修正提案文」を必ず残せ。
末尾に: (1) 総合 verdict（OK / NEEDS-FIX）と理由 (2) dispatch 前に bead notes へ追記すべき scope-fence 文案の完成形（■ 見出し形式・コードフェンス記号は使わない・そのまま --append-notes へ渡せる plain text）。per-leg 分割（実行主体の分離・acceptance の worker 到達不能部の切出し等）が必要なら fence でなく分割案として明示せよ。
${missing > 0 ? `lens 欠損が ${missing} 件ある＝検証は不完全。欠損を明記し verdict を fail-closed（NEEDS-FIX 側）に倒せ。` : 'lens 欠損なし。'}

${valid.map((r, i) => `===== LENS ${i + 1} =====\n${r}`).join('\n\n')}`,
  { label: 'synthesize', phase: 'Synthesize', model: MODEL }
)

return {
  synthesis,
  lensCount: valid.length,
  expectedLenses: lenses.length,
  roFallbackActive,
  receivedArgs,
}

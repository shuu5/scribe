export const meta = {
  name: 'needs-user-prebake',
  description:
    'needs-user タスクの pre-bake WF（admin が回す）: 並列 read-only facet 分析 → 各 facet が「現状調査(read-only・事実/推測を区別)→決定木→選択肢+トレードオフ→admin 起票候補」を構造化 brief で返す → opus が単一の構造化 brief へ統合し admin に返す。grill は含まない(対話 grill は grill-consult が別途行う=protocol §7)。F2 構造解消: WF は admin にデータを返すだけで自己 pre-bake を grill しない。固有物(taskRef/taskTitle/anchor/facets/model/roAgentType)は args で差し込む(骨格は再利用)。',
  whenToUse:
    'admin が needs-user タスク(人間判断依存)の grill 準備として pre-bake brief を作りたいとき。相互独立な複数の決定軸(facet)を並列 read-only 分析する。返り値の brief を admin が file へ書き grill-consult へ `scribe-spawn --consult --context <brief> <grill-issue>` で渡す(protocol §7)。1 facet なら admin インラインで足り fan-out 不要。roAgentType は read-only 段の agentType 上書き escape hatch(既定 scribe:explore・"none" で agentType 無し強制)。',
  // phases は phase() 呼び出し / opts.phase と同名で対応させる(タイトル完全一致でグループ化)。
  // 全 substantive agent は model:'opus'(args.model 既定)。facet 分析は read-only だが「決定木構築・
  // 選択肢起草」= 設計分析(thinking)ゆえ opus(CLAUDE.md model 階層: opus=思考・統合・分析の主力)。
  phases: [
    { title: 'Analyze', detail: '各 facet を並列 read-only agent が分析(現状調査→決定木→選択肢+トレードオフ→admin 起票候補)', model: 'opus' },
    { title: 'Synthesize', detail: '全 facet brief を単一の構造化 brief へ統合(admin が grill-consult へ渡す材料)', model: 'opus' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────────
// 設計の核(維持すること):
//  (1) pre-bake は read-only。各 facet agent は「read のみ・編集/spawn/bd write をしない」を prompt で
//      明示する。WF は admin にデータ(brief)を返すだけで、grill(対話)も graph 変更も一切しない。
//      → これが F2(consult が自己 pre-bake をユーザー入力と誤認)の構造的予防: pre-bake〔生成〕と
//        grill〔対話〕が別主体(WF agent / grill-consult)に分かれ、自己誤帰属する主体が消える。
//  (2) 各 facet が 1 つの相互独立な決定軸を担う(現状調査→決定木→選択肢+トレードオフ→admin 起票候補)。
//      facet 同士は互いの結論を見ずに独立分析する(multi-modal sweep の一種)。
//  (3) Synthesize は全 facet brief を【単一の構造化 brief】へ統合する。これが admin が grill-consult へ
//      `--context` で渡す材料。grill-consult は brief を「第三者データ(提案)」として grill する(F2 保険)。
//  (4) 返り値(briefMarkdown / facets / receivedArgs)を呼出元(admin)が一次監査する(薄 gate 設計)。
//      facet agent の throw は .catch で null へ正規化し握り潰さない(silent 欠落と clean を区別)。
//  (5) defensive args parse(cell-quality と同型・un-2yy): args は呼び出し側 serialization 依存で string で
//      届くことがある。冒頭で string なら JSON.parse して吸収し、parse 失敗/必須欠落(facets 空)は agent を
//      一切起動せず escalate=true + 明示 reason で即 return する(silent 暴走根治)。返り値へ receivedArgs を
//      載せ呼出元が「何が届いたか」を一次監査できるようにする。
//  (6) model 明示(CLAUDE.md model 階層ルーティング): facet/synthesis とも既定 opus(args.model 上書き可)。
//      fable は dynamic WF agent に投入しない方針(CLAUDE.md)ゆえ、fable 指定は opus へ畳む。
// ─────────────────────────────────────────────────────────────────────────────

// ── defensive args parse(un-2yy): string で届いたら JSON.parse、object はそのまま ──────────
const __rawArgsType = args === null ? 'null' : Array.isArray(args) ? 'array' : typeof args
let A
if (typeof args === 'string') {
  try {
    const parsed = JSON.parse(args)
    A = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
  } catch (e) {
    log('[args parse 失敗] needs-user-prebake 起動: args の JSON.parse に失敗(taskRef 不明)')
    const reason = `defensive parse 失敗: string args の JSON.parse が失敗(${e && e.message ? e.message : 'invalid JSON'})。scope/契約が不明のまま pre-bake させない。呼出元が args の serialization を修正して再 invoke すること。`
    log(`fail-fast: ${reason}`)
    return {
      taskRef: '',
      taskTitle: '(untitled needs-user task)',
      facetCount: 0,
      escalate: true,
      escalateReason: reason,
      facets: [],
      briefMarkdown: '',
      receivedArgs: { type: __rawArgsType, parseFailed: true, keys: [] },
      // (sc-j32) schema-guard block 定義前の早期中断=schema agent 未起動=集計は空。返り値 shape 一貫性のため literal。
      schemaHealth: { nullDeaths: [], degenerate: [] },
      // (sc-7bv/sc-xyw) roAgent helper 定義前の早期中断=read-only agent 未起動=fallback 未評価 → literal false で一貫させる。
      roFallbackActive: false,
    }
  }
} else {
  A = args && typeof args === 'object' && !Array.isArray(args) ? args : {}
}

// ── (sc-7bv) read-only agent 起動 helper: builtin 'Explore' 消失(harness breaking change)への恒久 fix ──
// 旧 facet/synthesize agent は builtin の read-only agent 型 'Explore'(書込ツールを持たない型)を agentType に
// 指定して read-only を構造強制していたが、Claude Code registry から 'Explore' が削除され spawn 前に即 throw する
// (prebake は全 facet null→escalate)。代わりに scribe plugin の read-only custom agent(agentType 'scribe:explore'
// =agents/explore.md)を指す。registry から解決不能な session(scribe plugin 未ロード / 将来の registry drift)では
// agentType 省略へ後退して read-only 規律を prompt で代替する(fallback)。args.roAgentType で RO agent type を差し替え
// 可能・'none' で agentType 無しを強制する(運用 escape hatch)。roAgent が管理する agentType は各呼出サイトでは指定しない。
const _rawRoAgentType = typeof A.roAgentType === 'string' ? A.roAgentType.trim() : ''
const RO_AGENT_TYPE = _rawRoAgentType || 'scribe:explore'
const RO_FORCE_NONE = RO_AGENT_TYPE === 'none' // 'none' = 最初から agentType を付けない強制
let roFallbackActive = RO_FORCE_NONE // not found を一度検知したら以降降格(flag・並行 race は同じ降格へ収束=無害)

// fallback 時、agentType の構造強制(書込ツール非所持)を prompt の read-only 規律で代替する(前置文)。
const RO_DISCIPLINE =
  '\n\n## 厳守（read-only・agentType 構造強制の代替）\n' +
  'あなたは read-only の観測・分析役。ファイル編集(Write/Edit)・git write(commit/push/add)・bd write・deploy・' +
  '別 agent の spawn を一切しない。Bash は読取り・検証実行(git read / bd show 等)に限り、コード・状態を変えない。' +
  '返り値(構造化データ)だけを返す(呼出元が一次監査する)。'

// registry から agentType が解決できなかった throw かを判定(probe verified のエラー形状:
// "agent({agentType}): agent type 'X' not found. Available agents: ...")。not found 以外は透過する。
const isAgentTypeNotFound = (e) => {
  const m = e && e.message ? String(e.message) : String(e == null ? '' : e)
  return /agent type\b[\s\S]*\bnot found/i.test(m) || /not found\. Available agents:/i.test(m)
}

// roAgent(prompt, opts): read-only 段の agent() 代替。RO_AGENT_TYPE を注入し、not found なら agentType 省略へ後退。
// - 降格済/強制 none: agentType 無し + read-only 規律 prompt 前置。
// - not found 検知: [RO-FALLBACK] を loud に log し降格 flag を立て、以降の facet/synthesize も agentType 無しへ。
// - not found 以外の throw: そのまま透過(呼出元の既存 .catch 意味論=設計核(4)を変えない)。
// 返り値は agent() と同一の Promise(.then/.catch 互換)。
async function roAgent(prompt, opts) {
  const base = { ...(opts || {}) }
  delete base.agentType // agentType の管理は roAgent に一元化(呼出サイトは指定しない)
  if (roFallbackActive) return agent(prompt + RO_DISCIPLINE, base)
  try {
    return await agent(prompt, { ...base, agentType: RO_AGENT_TYPE })
  } catch (e) {
    if (isAgentTypeNotFound(e)) {
      roFallbackActive = true
      log(`[RO-FALLBACK] read-only agentType '${RO_AGENT_TYPE}' が registry で解決不能(${e && e.message ? String(e.message).slice(0, 120) : 'not found'})。agentType 省略へ後退し read-only 規律を prompt で代替する。以降の read-only 段も降格(scribe plugin 未ロード session / registry drift の可能性=merge 後の fresh session で解消)。`)
      return agent(prompt + RO_DISCIPLINE, base)
    }
    throw e // not found 以外は透過(既存 .catch 意味論を保つ)
  }
}

//SCJ32_BLOCK_START
// ── (sc-j32) schema 強制 agent の placeholder 最終値化 / null 死ガード ──── [self-test anchor: sc-j32:schema-guard]
// dynamic WF の schema 付き agent は StructuredOutput(構造化出力)を「作業完了後に一度だけ・実データで」呼ぶべき
// だが、実発(wf_c2cd03d4)で 2 故障を観測した: (a) 試し打ちの placeholder が **初回呼出しで最終値化**(初回が確定
// し上書き不能)、(b) schema 検証 retry 上限(5)超過で **null 死**。対策(cell-quality と共通骨格):
//  (1) 全 schema prompt に SCHEMA_DISCIPLINE を前置(試し打ち禁止・完了後に一度だけ・実データで)。
//  (2) 骨格側で degenerate(placeholder 形状)を検知して既存の失敗経路(null 相当)へ倒す=fail-closed。
//  (3) null(retry 超過)/degenerate を success 扱いせず schemaHealth へ記録し返り値へ載せる(receivedArgs と対称)。
const SCHEMA_DISCIPLINE =
  '\n\n## StructuredOutput 規律（厳守・sc-j32）\n' +
  'この応答は schema で構造化出力(StructuredOutput)を強制される。StructuredOutput ツールは **作業を完了し実データが' +
  '揃ってから一度だけ** 呼ぶこと。試し打ち・動作確認・placeholder(例: currentState="test"・空/仮の配列で仮確定)で' +
  '呼んではならない。**初回の呼出しが最終値として確定し後から上書きできない** ため、値が確定するまで呼ばないこと。'

// placeholder 文字列の検知(試し打ちの典型値 or 空文字)。substantive であるべき string フィールドに使う。
// (sc-j32 errata) 長さヒューリスティック(旧 `t.length < 2`)は撤去した — 'x'/'r' のような terse だが正当な実データ
// を『試し打ち』と誤断定する false-positive を招くため(cell-quality と共通骨格)。退化とみなすのは trim 後の空文字か
// 既知 placeholder 語のみ(短さでは落とさない)。
const __PLACEHOLDER_STRINGS = new Set([
  'test', 'todo', 'tbd', 'placeholder', 'foo', 'bar', 'baz', 'qux', 'xxx',
  'sample', 'example', 'dummy', 'asdf', 'lorem', 'string',
])
const isPlaceholderStr = (s) => {
  if (typeof s !== 'string') return false
  const t = s.trim().toLowerCase()
  return t.length < 1 || __PLACEHOLDER_STRINGS.has(t)
}

// schema 健全性の集計(返り値 audit 用・receivedArgs と対称)。null 死 / degenerate を label 付きで記録する。
const schemaHealth = { nullDeaths: [], degenerate: [] }

// 各 schema の degenerate 判定(placeholder 形状=試し打ちの最終値化)。substantive フィールドが placeholder なら true。
const degFacet = (r) => isPlaceholderStr(r && r.currentState) // 現状調査が placeholder=試し打ち
const degSynth = (r) => isPlaceholderStr(r && r.briefMarkdown) // 統合 brief が placeholder(空は既存 trim チェックが別途捕捉)

// schemaAgent: schema 付き agent 呼出しの共通ラッパ。
//  - prompt に SCHEMA_DISCIPLINE を前置。
//  - runner(roAgent)を await。null(retry 超過=StructuredOutput 未確定)は握り潰さず schemaHealth.nullDeaths へ
//    記録し null を返す(呼出元の既存 null 失敗経路を温存)。
//  - degenerate(placeholder 形状)検知時は schemaHealth.degenerate へ記録し null を返す(既存の失敗経路
//    =fail-closed へ倒す=placeholder を最終値として下流に流さない)。
//  - throw はそのまま透過(呼出元の既存 .catch 失敗正規化=設計核(4)を壊さない)。
// 返り値型を「有効な schema オブジェクト or null」に保つため、各呼出サイトの `.then(b => b ? ... : null)` /
// `if (!synth ...)` 分岐を一切変えずに null/degenerate が既存の失敗網へ合流する。
async function schemaAgent(runner, prompt, opts, degenerate) {
  const label = (opts && opts.label) || 'schema-agent'
  const r = await runner(prompt + SCHEMA_DISCIPLINE, opts)
  if (r == null) {
    schemaHealth.nullDeaths.push(label)
    log(`[schema-null] ${label}: agent が null(retry 上限超過で StructuredOutput 未確定)。success 扱いせず失敗経路へ(sc-j32)。`)
    return null
  }
  if (typeof degenerate === 'function' && degenerate(r)) {
    schemaHealth.degenerate.push(label)
    log(`[schema-degenerate] ${label}: placeholder 形状(試し打ちの最終値化)を検知。reject して失敗経路へ倒す(sc-j32 fail-closed)。`)
    return null
  }
  return r
}
//SCJ32_BLOCK_END

const receivedArgs = {
  type: __rawArgsType,
  parseFailed: false,
  keys: Object.keys(A),
  keyTypes: Object.fromEntries(Object.keys(A).map((k) => [k, Array.isArray(A[k]) ? 'array' : typeof A[k]])),
  roAgentType: RO_AGENT_TYPE, // (sc-7bv) 解決した read-only agentType(既定 'scribe:explore' / override / 'none')
}

// ── args(固有物)。骨格は不変、ここだけ差し替える ───────────────────────────
const str = (v, d) => (typeof v === 'string' ? v : d)
const taskRef = str(A.taskRef, '').trim()
const taskTitle = str(A.taskTitle, '').trim() || (taskRef ? `needs-user ${taskRef}` : '(untitled needs-user task)')
const anchor = str(A.anchor, '').trim() // bd graph 所在(facet agent が read 用に bd show するなら使う)
// model: 既定 opus。fable は dynamic WF agent に投入しない(CLAUDE.md)ゆえ opus へ畳む。
const rawModel = str(A.model, 'opus').trim() || 'opus'
const model = /fable/i.test(rawModel) ? 'opus' : rawModel

log(`[${taskTitle}] needs-user-prebake 起動(taskRef=${taskRef || '(none)'} / model=${model})`)

// facets: 相互独立な決定軸の配列。各 facet = { key, question, context? }。
// key=識別子 / question=その facet で人間が裁定すべき問い / context=admin が焼く事前材料(任意)。
const facets = (Array.isArray(A.facets) ? A.facets : [])
  .map((f, i) => {
    if (!f || typeof f !== 'object') return null
    const key = str(f.key, '').trim() || `facet-${i + 1}`
    const question = str(f.question, '').trim()
    const context = str(f.context, '').trim()
    return question ? { key, question, context } : null
  })
  .filter(Boolean)

// 必須欠落(facets 空)は agent を一切起動せず escalate(silent 暴走根治)。
if (facets.length === 0) {
  const reason =
    'facets が空(または全要素が question 欠落)。pre-bake する決定軸が 1 つも無いため agent を起動しない。' +
    'args.facets=[{key,question,context?}] を 1 つ以上指定して再 invoke すること(protocol §7: 各 facet=相互独立な決定軸)。'
  log(`fail-fast: ${reason}`)
  return {
    taskRef,
    taskTitle,
    facetCount: 0,
    escalate: true,
    escalateReason: reason,
    facets: [],
    briefMarkdown: '',
    receivedArgs,
    schemaHealth: { nullDeaths: schemaHealth.nullDeaths.slice(), degenerate: schemaHealth.degenerate.slice() }, // (sc-j32) facets 空 fail-fast=schema agent 未起動ゆえ空
    roFallbackActive, // (sc-xyw) read-only agentType fallback の最終状態(facets 空 fail-fast=agent 未起動ゆえ RO_FORCE_NONE 以外は false)
  }
}

// ── facet brief の構造化 schema(各 read-only agent が返す) ─────────────────────
const FACET_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['facetKey', 'currentState', 'decisionTree', 'options', 'adminTicketCandidates'],
  properties: {
    facetKey: { type: 'string', description: 'この facet の識別子(args.facets[].key と一致させる)' },
    currentState: {
      type: 'string',
      description: '現状調査(read-only)。事実(verified/deduced)と推測(inferred/uncertain)を明示的に区別する。',
    },
    decisionTree: {
      type: 'array',
      description: '決めるべき枝を上流→下流に並べた決定木(grill の全体地図)。',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['node', 'question'],
        properties: {
          node: { type: 'string', description: '決定ノード名(例 D0/D1)' },
          question: { type: 'string', description: 'このノードで決めるべき問い' },
          dependsOn: { type: 'array', items: { type: 'string' }, description: '上流ノード名(あれば)' },
        },
      },
    },
    options: {
      type: 'array',
      description: '各決定の取りうる案を対等に並べトレードオフを付す(推奨は理由付きで後置・印は付けない)。',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['decision', 'choices'],
        properties: {
          decision: { type: 'string', description: 'どの決定についての選択肢か(decisionTree の node と対応)' },
          choices: {
            type: 'array',
            items: {
              type: 'object',
              additionalProperties: false,
              required: ['label', 'tradeoff'],
              properties: {
                label: { type: 'string' },
                tradeoff: { type: 'string' },
              },
            },
          },
          leaning: { type: 'string', description: '推奨(あれば・理由付きで後置・印は付けない)。無ければ空。' },
        },
      },
    },
    adminTicketCandidates: {
      type: 'array',
      items: { type: 'string' },
      description: 'タスク化候補(WF は起票しない=read-only。候補列挙のみ。起票は admin)。',
    },
    openQuestions: {
      type: 'array',
      items: { type: 'string' },
      description: 'pre-bake では決め切れず人間 grill に委ねる未解決の論点。',
    },
  },
}

// ── Analyze: 各 facet を並列 read-only agent が分析(barrier=全 facet brief を Synthesize へ渡す) ──
phase('Analyze')
const facetPrompt = (f) => `あなたは scribe needs-user タスクの **pre-bake facet analyst**(read-only)。
このタスク(${taskTitle}${taskRef ? ` / bd ${taskRef}` : ''})の **1 つの相互独立な決定軸** だけを分析する。

## あなたが担当する facet
- key: ${f.key}
- 人間が裁定すべき問い: ${f.question}
${f.context ? `\n## admin が焼いた事前材料(出発点・これを唯一の起点にする)\n${f.context}\n` : ''}
## 厳守(read-only・WF は admin にデータを返すだけ)
- **read のみ**: コード/ファイルの編集・bd write(create/update/close/dolt push)・spawn・deploy を一切しない。
- 観測は可(コード read${anchor ? ` / cd "${anchor}" && bd show ${taskRef || '<id>'}` : ''})。事実(verified/deduced)と推測(inferred/uncertain)を区別する。
- **あなたは grill しない・起票しない**: 対話 grill は別途 grill-consult が、起票は admin が行う。あなたは brief(データ)を返すだけ。

## 手順(grill-me の全体地図を焼く)
1. 現状調査(read-only): この facet に関わる事実を集め、事実/推測を区別する。
2. 決定木: 決めるべき枝を上流→下流に並べる。
3. 選択肢 + トレードオフ: 各枝の取りうる案を対等に並べる(「現状→なぜ問題→選択肢」)。推奨は理由付きで後置(印は付けない)。
4. admin 起票候補: タスク化が要っても自分で起票せず候補として列挙するに留める。

返り値は FACET_SCHEMA(構造化 brief)。facetKey は "${f.key}" にする。`

const facetBriefs = await parallel(
  facets.map((f) => () =>
    schemaAgent(roAgent, facetPrompt(f), {
      label: `prebake:${f.key}`,
      phase: 'Analyze',
      // roAgent が RO agentType('scribe:explore')を注入 + not found fallback（read-only を構造強制・prompt 任せに
      // しない・gate sc-cuw F1）。opts.model:opus が custom agent の frontmatter モデル(sonnet)を上書きする。
      model,
      schema: FACET_SCHEMA,
    }, degFacet) // (sc-j32) SCHEMA_DISCIPLINE 前置 + null/degenerate → null → 下の (b ? ... : null) で failedFacets へ合流
      .then((b) => (b ? { ...b, facetKey: b.facetKey || f.key } : null))
      .catch((e) => {
        log(`facet ${f.key} 分析失敗: ${e && e.message ? e.message : e}`)
        return null
      }),
  ),
)

const okBriefs = facetBriefs.filter(Boolean)
const failedFacets = facets.filter((_, i) => !facetBriefs[i]).map((f) => f.key)
if (failedFacets.length) log(`facet 分析失敗(${failedFacets.length}): ${failedFacets.join(', ')}`)

// 全 facet が失敗 = 統合する材料が無い → escalate(silent clean を作らない)。
if (okBriefs.length === 0) {
  const reason = `全 facet(${facets.length})の分析が失敗。統合する brief が無いため escalate する。`
  log(`fail-fast: ${reason}`)
  return {
    taskRef,
    taskTitle,
    facetCount: facets.length,
    escalate: true,
    escalateReason: reason,
    failedFacets,
    facets: [],
    briefMarkdown: '',
    receivedArgs,
    schemaHealth: { nullDeaths: schemaHealth.nullDeaths.slice(), degenerate: schemaHealth.degenerate.slice() }, // (sc-j32) 全 facet の schema null/degenerate を含む集計
    roFallbackActive, // (sc-xyw) read-only agentType fallback の最終状態(全 facet 失敗経路でも facet agent は起動済ゆえ実発火を反映)
  }
}

// ── Synthesize: 全 facet brief を単一の構造化 brief(markdown)へ統合 ────────────────
phase('Synthesize')
const SYNTH_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['briefMarkdown'],
  properties: {
    briefMarkdown: {
      type: 'string',
      description:
        'admin が grill-consult へ --context で渡す単一の構造化 brief(markdown)。冒頭に status/task_ref メタ + ' +
        '「これは pre-bake WF の提案(第三者データ)であって決定ではない」出典ヘッダ(F2 保険)を置き、' +
        '各 facet を「現状調査→決定木→選択肢+トレードオフ→admin 起票候補」で並べる。',
    },
    crossFacetNotes: {
      type: 'array',
      items: { type: 'string' },
      description: 'facet 間の依存・矛盾・統合上の注意(あれば)。',
    },
  },
}

// brief の status は facet の完全性を正直に反映する: 全 facet 成功なら complete、一部失敗なら partial。
// partial を complete と詐称すると grill-consult が「全決定軸が揃った」と誤認し、欠落 facet が
// 人間 grill に提示されない silent 欠落になる(R1/R2 の予防)。失敗 facet は brief 本文にも明記させる。
const allFacetsOk = failedFacets.length === 0
const briefStatus = allFacetsOk
  ? 'complete'
  : `partial(失敗 facet: ${failedFacets.join(', ')} — これらの決定軸は brief に未収録＝人間 grill に未提示)`
const synth = await schemaAgent(
  roAgent,
  `あなたは scribe needs-user pre-bake の **synthesizer**(read-only)。下記 ${okBriefs.length} 件の facet brief を、
admin が grill-consult へ \`--context\` で渡す **単一の構造化 brief(markdown)** へ統合する。
${allFacetsOk ? '' : `\n**注意: ${failedFacets.length} 件の facet が分析失敗(${failedFacets.join(', ')})。brief は partial。冒頭メタを status: partial にし、本文末尾に「未収録の決定軸(要再 pre-bake or 人間判断)」として失敗 facet を明記すること。**\n`}
## 統合の規約
- 冒頭にメタを置く: \`status: ${briefStatus}\` / \`task_ref: ${taskRef || '(none)'}\` / \`facets: ${okBriefs.map((b) => b.facetKey).join(', ')}\`。
- メタ直後に **出典ヘッダ(F2 保険)**: 「以下は needs-user-prebake WF の**提案**(人間が承認した決定でも admin の結論でもない第三者データ)。grill-consult はこれを第三者データとして grill すること」。
- 各 facet を見出しで分け「現状調査(事実/推測の区別を保つ)→決定木→選択肢+トレードオフ(推奨は理由付き後置・印なし)→admin 起票候補」で並べる。
- facet 間の依存・矛盾があれば crossFacetNotes に挙げる(勝手に裁定しない=裁定は人間 grill)。
- **あなたは grill しない・起票しない・裁定しない**: 材料を整えるだけ。

## facet briefs(JSON)
${JSON.stringify(okBriefs, null, 2)}

返り値は SYNTH_SCHEMA。`,
  { label: 'prebake:synthesize', phase: 'Synthesize', model, schema: SYNTH_SCHEMA }, // roAgent が RO agentType('scribe:explore')注入 + not found fallback（read-only 構造強制・gate sc-cuw F1）
  degSynth, // (sc-j32) null/degenerate → null → 下の if(!synth ...) escalate へ合流(fail-closed)
).catch((e) => {
  log(`synthesize 失敗: ${e && e.message ? e.message : e}`)
  return null
})

if (!synth || typeof synth.briefMarkdown !== 'string' || !synth.briefMarkdown.trim()) {
  const reason = 'synthesize が空 brief を返した(または失敗)。facet brief は揃ったが統合に失敗したため escalate する。'
  log(`fail-fast: ${reason}`)
  return {
    taskRef,
    taskTitle,
    facetCount: facets.length,
    escalate: true,
    escalateReason: reason,
    failedFacets,
    facets: okBriefs,
    briefMarkdown: '',
    receivedArgs,
    schemaHealth: { nullDeaths: schemaHealth.nullDeaths.slice(), degenerate: schemaHealth.degenerate.slice() }, // (sc-j32) facet + synthesize の schema null/degenerate を含む集計
    roFallbackActive, // (sc-xyw) read-only agentType fallback の最終状態(synthesize 失敗経路でも facet agent は起動済ゆえ実発火を反映)
  }
}

log(`[${taskTitle}] pre-bake 完了: facet ${okBriefs.length}/${facets.length} 統合・brief ${synth.briefMarkdown.length} 文字`)

return {
  taskRef,
  taskTitle,
  facetCount: facets.length,
  escalate: false,
  partial: !allFacetsOk, // 一部 facet 失敗=brief は partial(admin が grill-consult へ渡す前に再 pre-bake 判断)
  failedFacets,
  facets: okBriefs, // 各 facet の構造化 brief(admin の一次監査用)
  briefMarkdown: synth.briefMarkdown, // admin が file へ書き grill-consult へ --context で渡す材料
  crossFacetNotes: Array.isArray(synth.crossFacetNotes) ? synth.crossFacetNotes : [],
  receivedArgs,
  // (sc-j32) schema 強制 agent の健全性(retry 超過の null 死 / placeholder 試し打ち検知)。非空なら当該 facet/synth の
  // 出力は不採用(既存の失敗経路へ倒れ facet は failedFacets に落ちる)=admin が schemaHealth を直読して人手確認。
  schemaHealth: { nullDeaths: schemaHealth.nullDeaths.slice(), degenerate: schemaHealth.degenerate.slice() },
  roFallbackActive, // (sc-7bv/sc-xyw) read-only agentType fallback が最終的に発火したか(true=agentType 解決不能で降格した run)。receivedArgs.roAgentType は解決した型だけで発火有無は読めないため別途載せる。
}

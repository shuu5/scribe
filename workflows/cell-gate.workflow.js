export const meta = {
  name: 'cell-gate',
  description:
    'worker cell 成果物の独立敵対 gate の凍結骨格: 既定 5 lens（tests-green/fence-compliance/false-green-hunt/regression/scope-creep）が worktree の diff と契約 fence を並列敵対検証（実 suite 実行込み・read-only 構造強制・opus）し、opus 統合 agent が PASS/PASS-with-notes/FAIL（+gate 側判定不能時 INCONCLUSIVE）verdict + merge routing 判定 + そのまま --append-notes へ渡せる gate 判定要約を返す。mandate-verify（dispatch 前）と対になる post-implementation gate。固有物（anchor/targetBead/worktree/commit/suites/scopeForbidden 等）は args で差し込む（骨格は再利用・scriptorium orch-ctzr=wf_ef0d846a / orch-vswk=wf_719166c1 の同型 2 run 実証形の凍結＝orch-ieun）。',
  whenToUse:
    'orchestrator/admin が worker cell の DONE/gate-pending 宣言を merge 前に独立再検証したいとき（worker 自己申告と selftest PASS を信用せず、実 suite 実行と fence 突合で裏取りする）。args={anchor: 台帳 anchor 絶対パス（必須）, targetBead: 対象 bead id（必須）, worktree: cell worktree 絶対パス（必須）, commit?: 対象 commit（既定 HEAD）, suites: tests-green lens で実行する検証コマンドの列挙 string[]（既定 lens 使用時は必須・bats/bash -n/--self-test 等）, diffNote?: diff の人間向け要約（例「main..HEAD の 1 commit・8 files +742」）, fenceNote?: fence 節への追記特記（省略時も bead notes の DISPATCH SCOPE-FENCE ■ 節群を常に参照・特殊な所在/確定値があれば追記）,scopeForbidden?: diff ゼロを実証すべき禁触 file/領域 string[], lensExtras?: {lens-key: 追記文}（既定 5 lens への per-run 追加観点・未知 key は fail-fast）, lenses?: [{key, q}] 完全 override（既定 5 lens を使わない escape hatch・指定時は suites/lensExtras/scopeForbidden と併用不可。override 時は実行系 lens〔実 suite/bats/self-test を実走する lens〕を呼出元が最低 1 本含める責務を負う＝含めないと「実 red→FAIL」が空虚化し実 suite 未実行のまま PASS 到達可能）,synthesisExtra?: Synthesize の (4) 番目として返させる per-run 追加 deliverable の指示文（例「Leg-2 post-land smoke checklist を fence から機械抽出」「land 後 cutover checklist」。post-gate の次アクション checklist が要る run では必ず渡す＝未指定だと (4) は出ない・追加 deliverable は 1 枠上限）,model?: agent model（既定 opus）, roAgentType?: read-only agentType 上書き（既定 scribe:explore・"none" で agentType 無し強制）}。既定 5 lens は generic 骨格＝元 cell 相当の gate 強度には run 固有の fence 点/実装検証点を lensExtras へ必ず転記すること（空 lensExtras は generic-only gate＝ad-hoc 手書き gate より弱い）。container 型の誤り（非配列 suites/lenses 等）は fail-fast する。返り値 synthesis を呼出元が一次監査し、gate 判定要約を bead notes へ追記してから verdict に従い merge / 差し戻し / gate 再実行する。',
  phases: [
    { title: 'Verify', detail: '各 lens を並列 read-only agent が敵対検証（契約+fence 読解 → diff 突合・実 suite 実行 → findings）', model: 'opus' },
    { title: 'Synthesize', detail: '全 lens findings を severity 降順で統合し verdict + merge routing + gate 判定要約を返す', model: 'opus' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────────
// 設計の核(維持すること):
//  (1) 全段 read-only。lens agent は観測・実測(bd show / grep / diff 精読)と「状態を変えない検証実行」
//      (bats / bash -n / --self-test)だけを行い、bd write・ファイル編集・spawn・git push を一切しない
//      (agentType 'scribe:explore' の構造強制 + roAgent fallback=mandate-verify 同型)。
//  (2) lens は相互独立な検証軸(multi-modal sweep)。互いの結論を見ずに独立検証し、統合は Synthesize に一元化。
//  (3) fail-closed: 検証実行系 lens の実 red 1 本 → verdict は必ず FAIL。lens 欠損(agent null 死)は
//      Synthesize prompt に欠損 lens 名ごと明記させ PASS を禁止——ただし欠損は gate/infra 側の失敗であって
//      worker 実欠陥ではないため、worker 起因の実 red が無い部分欠損は FAIL(worker 差し戻し)でなく
//      INCONCLUSIVE(gate 再実行)へ倒す(誤帰属防止)。全 lens 欠損なら Synthesize を呼ばず escalate=true +
//      verdict INCONCLUSIVE で即 return(空データからの false-PASS を構造封鎖・merge 不可)。Synthesize agent
//      自体の null 死/空応答も同様に escalate=true + INCONCLUSIVE(最終決定段だけ成功形で返す fail-open を禁止)。
//  (4) defensive args parse(mandate-verify/cell-quality と同型): string 到達は JSON.parse で吸収、parse 失敗・
//      必須欠落・不正形(lens の key/q 欠落・suites/scopeForbidden の非文字列混入・lensExtras の未知 key・
//      container 型違い=非配列 lenses/suites/scopeForbidden・非 object lensExtras・空配列 lenses)は
//      agent を一切起動せず escalate=true + 明示 reason で即 return。不正形を silent drop して残りで回すと
//      「呼出元が意図した検証軸が黙殺されたまま verdict=PASS」という false-PASS 経路になるため、drop でなく
//      fail-fast。lenses 完全 override と既定 lens 用 args(suites/lensExtras/scopeForbidden)の併用も、どちらの
//      意図か曖昧なまま片方を黙殺する経路ゆえ fail-fast。返り値へ receivedArgs 要約を載せ呼出元が一次監査する。
//  (5) run 識別: meta.name は純リテラル制約で run ごとに変えられないため、args 解決直後に log('[<targetBead>] …')
//      を必ず出す(同名 WF 並走時に /workflows 進行ビューで run を区別する唯一の手段)。
//  (6) 凍結の由来: scriptorium の手書き 2 run(orch-ctzr=wf_ef0d846a / orch-vswk=wf_719166c1)が共に
//      worker 宣言の裏取り(実 bats 実行・fence 突合・mutation 非空虚検証)で merge 判定を支えた収束形。
//      run ごとに変わるのは対象 worktree/commit/suite 列挙/fence 内容という「データ」だけ=args 化。
//      ad-hoc 2 run に潜在した「lens 欠損時に findings と lens key の対応がずれる」バグ(filter 後の index で
//      LENSES[i] を引く)は、filter 前に key を pair する形で本骨格が是正済み(維持すること)。
// ─────────────────────────────────────────────────────────────────────────────

// ── defensive args parse(設計核(4)) ─────────────────────────────────────────
const __rawArgsType = args === null ? 'null' : Array.isArray(args) ? 'array' : typeof args
let A = {}
let __parseFailed = false
if (typeof args === 'string') {
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
const worktree = typeof A.worktree === 'string' ? A.worktree.trim() : ''
const commit = (typeof A.commit === 'string' && A.commit.trim()) || 'HEAD'
const diffNote = typeof A.diffNote === 'string' ? A.diffNote.trim() : ''
const fenceNote = typeof A.fenceNote === 'string' ? A.fenceNote.trim() : ''
const synthesisExtra = typeof A.synthesisExtra === 'string' ? A.synthesisExtra.trim() : ''
const MODEL = (typeof A.model === 'string' && A.model.trim()) || 'opus'

// string[] args の検証: 非配列は空扱い、配列なら全要素が非空文字列であることを要求(不正混入は fail-fast へ)
const __strArray = (v) => (Array.isArray(v) ? v : [])
const rawSuites = __strArray(A.suites)
const suites = rawSuites.filter((s) => typeof s === 'string' && s.trim())
const rawForbidden = __strArray(A.scopeForbidden)
const scopeForbidden = rawForbidden.filter((s) => typeof s === 'string' && s.trim())
const rawExtras = A.lensExtras && typeof A.lensExtras === 'object' && !Array.isArray(A.lensExtras) ? A.lensExtras : {}
const DEFAULT_LENS_KEYS = ['tests-green', 'fence-compliance', 'false-green-hunt', 'regression', 'scope-creep']
const extrasUnknownKeys = Object.keys(rawExtras).filter((k) => !DEFAULT_LENS_KEYS.includes(k))
const extrasBadValues = Object.keys(rawExtras).filter(
  (k) => !(typeof rawExtras[k] === 'string' && rawExtras[k].trim())
)
const rawOverride = Array.isArray(A.lenses) ? A.lenses : []
const overrideLenses = rawOverride.filter(
  (l) =>
    l && typeof l === 'object' &&
    typeof l.key === 'string' && l.key.trim() &&
    typeof l.q === 'string' && l.q.trim()
)
const droppedOverride = rawOverride.length - overrideLenses.length
const useOverride = rawOverride.length > 0
// override と既定 lens 用 args の併用は意図曖昧(どちらかが黙殺される)ゆえ fail-fast(設計核(4))
const overrideConflicts = useOverride
  ? [rawSuites.length > 0 && 'suites', Object.keys(rawExtras).length > 0 && 'lensExtras', rawForbidden.length > 0 && 'scopeForbidden'].filter(Boolean)
  : []
// 呼出元の一次監査用: 何がどう解決されたかを機械可視化(lensExtras の効き漏れ・override 誤認を検出可能に)
receivedArgs.useOverride = useOverride
receivedArgs.lensExtrasKeys = Object.keys(rawExtras)
receivedArgs.overrideKeys = overrideLenses.map((l) => l.key)

// fail-fast: 契約が不明・不正形が混入したまま agent を起動しない(silent 黙殺 → false-PASS の根治)
const failReasons = []
// container 型違いは __strArray/object 正規化で silent に空へ縮退し以降の検査が全て不発になる
// (例: 非配列 lenses + 有効 suites → override 意図が黙殺されたまま既定 5 lens が silent 稼働=検証すり替え)。
// 正規化「前」の raw 値で型を検査し fail-fast する(ungated=override 経路の同型盲点も同時に塞ぐ)。
if (A.lenses != null && !Array.isArray(A.lenses))
  failReasons.push('lenses は [{key,q}] の配列で渡すこと（object/string 単体は不可）。override 不要なら省略して既定 5 lens を使う。')
if (Array.isArray(A.lenses) && A.lenses.length === 0)
  failReasons.push('lenses が空配列（override 意図なら {key,q} 要素を入れ、既定 5 lens を使うなら lenses ごと省略せよ）。')
if (A.suites != null && !Array.isArray(A.suites))
  failReasons.push('suites は string[] で渡すこと（単一 string 不可＝["cmd"] 形）。')
if (A.scopeForbidden != null && !Array.isArray(A.scopeForbidden))
  failReasons.push('scopeForbidden は string[] で渡すこと（単一 file でも ["path"]）。')
if (A.lensExtras != null && (typeof A.lensExtras !== 'object' || Array.isArray(A.lensExtras)))
  failReasons.push('lensExtras は {lens-key: 追記文} の plain object で渡すこと（配列/string 不可）。')
if (__parseFailed) failReasons.push('args が JSON 文字列として届いたが parse 不能(呼出元 serialization 破損)')
if (!anchor) failReasons.push('必須 args 欠落: anchor')
if (!targetBead) failReasons.push('必須 args 欠落: targetBead')
if (!worktree) failReasons.push('必須 args 欠落: worktree')
if (useOverride && droppedOverride > 0)
  failReasons.push(`lenses に不正形が ${droppedOverride} 件混入(key/q が欠落 or 空)。検証軸の黙殺を防ぐため drop せず fail-fast——全 lens を {key, q} の非空文字列で渡し直すこと。`)
if (useOverride && overrideConflicts.length > 0)
  failReasons.push(`lenses(完全 override)と既定 lens 用 args(${overrideConflicts.join('/')})の併用は不可(どちらの検証意図かが曖昧なまま片方が黙殺される)。override に一本化するか、既定 5 lens + lensExtras へ寄せること。`)
if (!useOverride && suites.length === 0)
  failReasons.push('suites が空(既定 tests-green lens は実行すべき検証コマンドの明示列挙が必須。空のまま回すと「何も実行せず green」の空虚 lens になる)。')
if (!useOverride && rawSuites.length !== suites.length)
  failReasons.push(`suites に非文字列/空要素が ${rawSuites.length - suites.length} 件混入。全要素を非空文字列で渡し直すこと。`)
if (!useOverride && rawForbidden.length !== scopeForbidden.length)
  failReasons.push(`scopeForbidden に非文字列/空要素が ${rawForbidden.length - scopeForbidden.length} 件混入。全要素を非空文字列で渡し直すこと。`)
if (!useOverride && extrasUnknownKeys.length > 0)
  failReasons.push(`lensExtras に未知 key: ${extrasUnknownKeys.join(', ')}(有効 key=${DEFAULT_LENS_KEYS.join('/')})。未知 key の silent 無視は検証意図の黙殺ゆえ fail-fast。`)
if (!useOverride && extrasBadValues.length > 0)
  failReasons.push(`lensExtras の値が非空文字列でない key: ${extrasBadValues.join(', ')}。`)
if (failReasons.length > 0) {
  const reason = failReasons.join(' / ')
  log(`[cell-gate] fail-fast: ${reason}`)
  return {
    escalate: true,
    reason,
    verdict: 'INCONCLUSIVE',
    synthesis: null,
    lensCount: 0,
    // fail-fast の expectedLenses は「呼出元が意図した raw 数」(dropped 込み)。以降の return は解決後の数。
    expectedLenses: useOverride ? rawOverride.length : DEFAULT_LENS_KEYS.length,
    droppedOverride,
    receivedArgs,
  }
}

// ── lens 確定(既定 5 lens or 完全 override) ─────────────────────────────────
const defaultLenses = [
  {
    key: 'tests-green',
    q: `検証実行 lens: worktree ${worktree} で次を実際に実行し、生の合否を報告せよ（宣言の green を信用しない）: ${suites.map((s, i) => `(${i + 1}) ${s}`).join(' ')}。各コマンドの exit code・test 総数・fail した test 名を verbatim で列挙。1 本でも red なら critical。timeout・実行不能はその事実をそのまま報告せよ（green と偽らない）。`,
  },
  {
    key: 'fence-compliance',
    q: `fence 準拠 lens: 契約 bead の fence（■ 節群）を全節列挙し、diff を各節と 1 対 1 で突合せよ。各節の遵守/違反をコード・grep・行位置の実測で実証する（worker 宣言の引用は実証にならない）。逆方向も確認: fence に根拠を持たない挙動変更・追加が diff に混入していないか。`,
  },
  {
    key: 'false-green-hunt',
    q: `false-green 狩り lens: (a) 新規/変更 test の mutation 非空虚が本物か＝各 assert が実装の該当 fail-closed/分類/順序ロジックを殺すと実際に赤へ反転する構造かをコードで検証し、自己充足（vacuous）assert を炙り出せ (b) stub/fixture が検証対象の実経路を通しているか＝検証対象そのものを stub で差し替えて空転していないか (c) worker 終端宣言に過大 claim（live 検証済/merged/実環境 green 等）が無いか、宣言文と実物を突合せよ。`,
  },
  {
    key: 'regression',
    q: `回帰 lens: (a) diff が既存挙動・既存 consumer・既存 test の意味論を壊していないか精読 (b) 既存 test の変更が「fixture 追加・narrow」に留まり、assert の弱化・期待値反転・test 削除が紛れていないか (c) 命名・env seam・fail-open/fail-closed 方針が既存 convention と整合か (d) 非対話実行（systemd/hook 経由等）で新コードが hang し得る箇所（対話 prompt・tty 依存）が無いか。`,
  },
  {
    key: 'scope-creep',
    q: `scope 境界 lens: diff が契約が触ってよいと定めた物だけに触れているか。${scopeForbidden.length > 0 ? `特に次への diff ゼロを git/grep で実証せよ: ${scopeForbidden.join(' / ')}。` : ''}新規コードに契約外の副作用（実 network・実台帳 write・guard 迂回・ホスト状態変更）が無いか実装精読。docs/規約 file への diff は実装と一致する事実記述かを精読し、merge-ratify 該当（規約 file・全ホスト配布物）を判定材料として報告せよ。`,
  },
]
const lenses = useOverride
  ? overrideLenses
  : defaultLenses.map((l) =>
      rawExtras[l.key] ? { key: l.key, q: `${l.q}\n追加観点（per-run）: ${rawExtras[l.key].trim()}` } : l
    )

// ── run 識別(設計核(5)・CLAUDE.md「args 受け取り型 WF は起動直後に識別子を log」) ──
log(
  `[${targetBead}] cell-gate: lenses=${lenses.length}(${lenses.map((l) => l.key).join(',')}) worktree=${worktree} commit=${commit}`
)

// ── read-only agentType の fallback(mandate-verify 同型・sc-7bv/sc-xyw 系譜) ──
const _rawRoAgentType = typeof A.roAgentType === 'string' ? A.roAgentType.trim() : ''
const RO_AGENT_TYPE = _rawRoAgentType || 'scribe:explore'
const RO_FORCE_NONE = RO_AGENT_TYPE === 'none'
let roFallbackActive = RO_FORCE_NONE

const RO_DISCIPLINE =
  '\n\n## 厳守（read-only・agentType 構造強制の代替）\n' +
  'あなたは read-only の観測・検証役。ファイル編集(Write/Edit)・git write(commit/push/add)・bd write・deploy・' +
  '別 agent の spawn を一切しない。Bash は読取り・grep・状態を変えない検証実行(bats/self-test/git read/bd show)に限る。' +
  '返り値(検証結果テキスト)だけを返す(呼出元が一次監査する)。'

const isAgentTypeNotFound = (e) => {
  const m = e && e.message ? String(e.message) : String(e == null ? '' : e)
  return /agent type\b[\s\S]*\bnot found/i.test(m) || /not found\. Available agents:/i.test(m)
}

async function roAgent(prompt, opts) {
  const base = { ...(opts || {}) }
  delete base.agentType
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
    throw e
  }
}

// ── 共通 preamble(2 run 収束形の凍結・run 固有部は args から差し込み) ─────────
// (sc-ezn1) rm 変数 path 規約: harness built-in の dangerous-rm 検知(binary 焼込・allowlist/bypass とも抑止不能)は
// 「変数で始まり / の直後が〔* | 別変数 | / | 引用符 | 行末〕」形の rm/rmdir で permission picker を出し、無人 WF が
// 構造 stall する(sc-8bhc gate の mutation 手順＝"$S/$name" への素の rm -rf で 30 分超停止の実測・orch-ypk9)。${VAR:?} 形は
// brace 内の : ? が検知 regex に不一致=免除、かつ未設定/空で abort する bash 標準 guard=空展開事故も bash 層で封鎖。
// literal 到達 tooth: tests/workflow-rm-var-guard.bats
const common = `あなたは worker cell 成果物の独立敵対 gate agent。read-only 規律: ファイル編集・bd write・spawn・ホスト状態変更・git push は一切しない（Bash は読取り・grep・検証 suite/self-test の実行・git read のみ可）。
Bash 規律(rm・厳守): rm / rm -rf / rmdir の対象に変数 path を使うときは必ず \${VAR:?} 形（未設定/空で abort する bash 標準 guard）で書く（例: rm -rf "\${S:?}/\${name:?}"）。素の \$VAR/\$VAR2・\$VAR/* 形は harness built-in の dangerous-rm 検知が permission picker を出し WF が無人 stall する（allowlist・bypass とも抑止不能）。\${VAR:?} 形は検知免除かつ空展開事故を bash 層で構造封鎖する（mutation 検証・一時複製の掃除も同様）。
対象: bead ${targetBead} の成果物 = worktree ${worktree} の commit ${commit}${diffNote ? `（${diffNote}）` : ''}。
まず (cd ${anchor} && bd show ${targetBead} | cat) で契約・DISPATCH SCOPE-FENCE（■ 節群${fenceNote ? `・${fenceNote}` : ''}）・worker 終端宣言を読み、git -C ${worktree} show ${commit} で diff 全文を読め。
worker の宣言は信用せず実測で裏取りせよ。finding は severity(critical/high/med/low) + 根拠(verified/deduced/inferred) 付きで返せ。問題が無い軸は「問題なし(根拠)」と明記。`

// ── Verify: 全 lens を並列敵対検証(設計核(2)) ────────────────────────────────
phase('Verify')
const results = await parallel(
  lenses.map((l) => () =>
    roAgent(`${common}\n\n== lens: ${l.key} ==\n${l.q}\n\n最終出力: findings（severity 降順・根拠タグ付き）+ この lens の verdict（OK / NEEDS-FIX / FAIL）。`, {
      label: `gate:${l.key}`,
      phase: 'Verify',
      model: MODEL,
    }).then((r) => ({ key: l.key, r }))
  )
)

// ── Synthesize: 統合 + verdict + merge routing + gate 判定要約(設計核(3)) ────
phase('Synthesize')
// 設計核(6): parallel の null(agent 死)を filter する前に key を pair 済み＝欠損があっても key 対応はずれない
const valid = results.filter((x) => x && x.r)
const missing = lenses.length - valid.length
const missingKeys = lenses.filter((l) => !valid.some((v) => v.key === l.key)).map((l) => l.key)
log(`[${targetBead}] gate lens 完了: ${valid.length}/${lenses.length}（欠損 ${missing}${missing > 0 ? `: ${missingKeys.join(',')}` : ''}）`)

if (valid.length === 0) {
  return {
    escalate: true,
    reason: '全 lens が欠損(agent null 死)＝検証データ不在。false-PASS を防ぐため Synthesize を回さず INCONCLUSIVE で返す(merge 不可)。',
    verdict: 'INCONCLUSIVE',
    synthesis: null,
    lensCount: 0,
    expectedLenses: lenses.length,
    roFallbackActive,
    receivedArgs,
  }
}

const synthesis = await roAgent(
  `あなたは gate 統合 agent。以下は bead ${targetBead} 成果物（worktree ${worktree}・commit ${commit}）への ${valid.length}/${lenses.length} lens 独立敵対 gate の findings 全文である。read-only。重複を統合し severity 降順で単一化し、次を返せ:
(1) 総合 verdict: PASS（merge 可）/ PASS-with-notes（merge 可・軽微 note を bead へ記帳）/ FAIL（worker へ差し戻し・具体的差し戻し指示付き）/ INCONCLUSIVE（gate 側 lens 欠損等で判定不能・gate 再実行）。「検証実行系 lens」とは findings 中で実際にコマンド実行の exit code / test 合否を報告している lens を指す（既定では tests-green・override では suite を実走する lens）。検証実行系 lens で 1 本でも実 red があれば必ず FAIL。lens 欠損があり worker 起因の実 red が無い場合は FAIL（worker 差し戻し）でなく INCONCLUSIVE（gate 再実行）へ倒せ。
(2) merge routing 判定: diff が規約 file（CLAUDE.md・docs/*.md 等）・全ホスト配布物（plugin scripts/hooks/設定）に触れるかの事実確認と、人間 ratify が必要な範囲の明示（該当なしならその旨を明記）。
(3) bead notes へそのまま --append-notes できる gate 判定要約（plain text・コードフェンス記号を使わない・auto-merge 証跡形式: gate 判定要約 + 各 lens verdict + 残 note）。
${synthesisExtra ? `(4) ${synthesisExtra}\n` : ''}${missing > 0 ? `検証は不完全＝lens 欠損 ${missing} 件（欠損: ${missingKeys.join(', ')}／完了: ${valid.map((v) => v.key).join(', ')}）。欠損 lens 名を要約へ明記し verdict を PASS にしない（fail-closed・PASS-with-notes も不可）。欠損は gate/infra 側 agent 死の可能性があり worker 実欠陥とは限らない＝worker 起因の実 red が無ければ INCONCLUSIVE へ倒せ。` : 'lens 欠損なし。'}

== findings ==
${valid.map((v) => `---- lens ${v.key} ----\n${v.r}`).join('\n\n')}`,
  { label: 'gate:synthesize', phase: 'Synthesize', model: MODEL }
)

// 設計核(3): 最終決定段の fail-open 禁止＝Synthesize agent の null 死/空応答を成功形で返さない
const _synText = typeof synthesis === 'string' ? synthesis.trim() : synthesis
if (_synText == null || _synText === '') {
  return {
    escalate: true,
    reason: 'Synthesize agent が null 死 or 空応答＝gate verdict 生成不能。merge 不可（gate 再実行）。',
    verdict: 'INCONCLUSIVE',
    synthesis: null,
    lensCount: valid.length,
    expectedLenses: lenses.length,
    partialMissing: missing > 0,
    roFallbackActive,
    receivedArgs,
  }
}

return {
  synthesis,
  lensCount: valid.length,
  expectedLenses: lenses.length,
  partialMissing: missing > 0,
  roFallbackActive,
  receivedArgs,
}


export const meta = {
  name: 'cell-quality',
  description:
    '1 issue = 1 実装セルの品質WF: task-type routing → [Plan] → [Implement] → perspective-diverse な Opus review → 各 finding を独立 Opus が adversarial refute-verify → gated autoFix(confirmed のみ+self-test fail-closed+amend) → loop-until-dry 収束。返り値を呼出元(worker/admin)が一次監査する薄 gate 設計。固有物は args で差し込む(骨格は再利用)。',
  whenToUse:
    'worker worktree で substantive な per-issue 実装の品質を担保したいとき。固有物(taskTitle/worktree/goal/acceptance/diff/selfTestCmd/dimensions/model/maxRounds/autoFix/doPlan/doImplement/taskType/target/context/probe)は args で渡す。autoFix は既定 off(共有 fail-safe)、worker cell 文脈は autoFix:true を渡す。',
  // phases は phase() 呼び出し / opts.phase と同名で対応させる(タイトル完全一致でグループ化)。
  // substantive な全 agent は model:'opus'(args.model 既定)= read-only agent(scribe:explore)の frontmatter 弱モデル退化を根治。
  phases: [
    { title: 'Classify', detail: 'task-type を判定し verify 戦略を選ぶ(testable/executable/docs/config/monitoring/notes)', model: 'opus' },
    { title: 'Plan', detail: '[任意] goal から受入基準を導出/精緻化', model: 'opus' },
    { title: 'Self-test', detail: 'selfTestCmd を worktree で実行し baseline(実装前)/final(終了時)の生ログ+pass/fail を返り値へ載せる(mechanical run=sonnet・selfTestCmd 未定義なら graceful skip)', model: 'sonnet' },
    { title: 'Implement', detail: '[任意] worktree で実装', model: 'opus' },
    { title: 'Review', detail: 'perspective-diverse な並列 Opus review(correctness/robustness-security/integration-ops/completeness-critic)', model: 'opus' },
    { title: 'Verify', detail: '各 finding を独立 Opus が adversarial に refute-verify(過剰提案を排除)', model: 'opus' },
    { title: 'Fix', detail: 'confirmed のみ gated autoFix + self-test fail-closed + amend', model: 'opus' },
  ],
}

// ─────────────────────────────────────────────────────────────────────────────
// 出典: doobidoo e7240589(dynamic-workflow methodology)/833f61e0(un-dja 設計) +
//       消失試作 cycle-opus.workflow.js / iterative-opus-review.workflow.js の設計核。
// 確定 spec: bd un-bs0(grill 2026-06-09)。受入: bd un-dja(最小スコープ)。
//
// 設計の核(必ず維持すること):
//  (1) 全 review/verify/fix/plan/classify/snapshot agent に model:'opus' を明示。read-only 段は roAgent 経由で
//      agentType 'scribe:explore'(agents/explore.md=書込ツール非所持)を注入し read-only を構造強制する。
//      旧 builtin 'Explore' は registry から削除された(harness breaking change=sc-7bv)ため、roAgent が解決
//      不能(scribe plugin 未ロード session / registry drift)を検知したら agentType 省略へ後退し read-only
//      規律を prompt で代替する(fallback)。custom agent の frontmatter model(sonnet)は opts.model が上書きする
//      ため read-only tools + Opus reasoning が両立する。これが最重要。
//  (2) 各ラウンド頭の snapshot が worktree diff を inline 供給 → 「この diff のみ対象」で
//      スコープ固定 = reviewer の anchor ドリフト根治。
//  (3) autoFix は confirmed のみ適用 + self-test fail-closed(失敗=即停止+escalate)+ amend。
//      self-test gate が無い(selfTestCmd 未指定)なら autoFix を無効化(fail-closed)。
//  (4) 返り値 history/blocking/refuted/diff を呼出元が一次監査(verdict を鵜呑みにしない)
//      → admin は薄 gate(merge 権限 + outward/risk 人間確認 + 収束証跡確認)のみ、再 review しない。
//  (5) machinery の silent 失敗を「真に clean」と区別する(除去禁止の不変条件):
//      review/verify/snapshot の agent() throw は .catch で観測可能な値へ正規化し、握り潰さない。
//      review 失敗(reviewFailed)/snapshot 失敗(snapshotFailed)の round は blocking=0 でも clean 扱い
//      しない=収束させず escalate へ倒す。この硬化を外すと false CONVERGED(silent ship)が再発する。
//  (6) per-stage model 上書き(reviewModel/verifyModel・既定=MODEL=opus=完全後方互換)+ fable→opus 降格(un-1kb):
//      新モデル方針(2026-06-10=dynamic WF に fable 禁止)を機械的に強制する。reviewModel/verifyModel の解決値が
//      fable(明示指定 or MODEL=claude-fable-5 継承の fail-open=spawn worker が --model opus を怠った経路)なら
//      demoteFable で opus へ畳む = review/verify は fable で一切走らない。sonnet/haiku 等の意図的な安価指定は
//      素通し(降格は fable のときだけ)。非 fable は既定経路の並列度・各 agent の model:opus 明示が不変
//      (回帰なし=既定で全 substantive agent が MODEL のまま)。fable ≤2 cap(FABLE_MAX_CONCURRENCY・共有
//      limiter・runAgent)は降格漏れ時の最終防壁=defense-in-depth として残置するが、降格後は fable agent が
//      流れず通常経路は no-op(fableCapped は常に false)。理由(cap 残置): fable は実コスト 2×Opus 超で、
//      ハーネスに fable 専用の自動同時実行制限が無い(verified)。
//  (7) args fail-fast(un-8c4 吸収): worker-cell 実行(doImplement か autoFix 要求)で必須 args
//      (worktree・goal/acceptance のいずれか・autoFix 時 selfTestCmd)を欠く場合、agent を一切起動せず
//      escalate=true + 明示 reason で即 return(silent 暴走根治)。読み取り専用の軽量用途(diff 供給+
//      single モード=doImplement/autoFix なし)はゲート対象外=従来の柔軟性を保つ。
//  (8) defensive args parse(un-2yy 吸収): args の string/object は呼び出し側 serialization 依存で
//      非決定的(object 到達もあれば JSON 文字列化して届くこともある)。冒頭で typeof args==='string' なら
//      JSON.parse して吸収する。parse 失敗(壊れた JSON 等)は scope/契約が一切不明=agent を一切起動せず
//      escalate=true + 明示 reason で即 return する。さらに返り値へ receivedArgs 要約(キー一覧 + 受信型)を
//      載せ、呼出元が「何が届いたか」を一次監査できるようにする(非決定的 serialization の可視化)。
//      加えて single モード(autoFix off)でも、静的 diff 未指定 + snapshot=EMPTY_DIFF は「レビュー対象不在」=
//      machinery 失敗扱いにして converged を立てず escalate へ倒す(clean と区別)。
//  (9) snapshot 合成で round 内 commit に頑健化(un-2f1 吸収): Implement/Fix agent が round1 で commit すると
//      以降の `git diff HEAD` が空になり、F4 fail-closed が hard cap まで空回りして false-escalate する
//      (un-x3o: 9 findings 全 refuted でも escalate / un-iur: autoFix amend 済で全 round snapshotFailed)。
//      設計選択 = snapshot を base...HEAD(commit 済)+ git diff HEAD(未 commit)の【合成】にする。
//      理由: Fix の fail-closed ゲートは「self-test PASS 時に実装コミットへ amend」する=commit の存在が前提で、
//      Implement に「commit するな」と指示すると Fix の amend と矛盾する。よって「commit したかに依らず」セル
//      全差分を捕捉する合成が一貫する(指示遵守に依存しない恒久修正)。escalateReason には「snapshot 空=
//      commit 済の可能性」ヒントを含め、既知 artifact かどうかを呼出元が見分けられるようにする。
// (10) selfTestCmd 常時実行へ昇格(sc-jx8): 従来 selfTestCmd は autoFix 経路(Fix agent 内)の fail-closed
//      ゲートでのみ走り、WF 自体は独立実行しなかった。これを baseline(実装前=regression 起点)+ final(終了時)
//      の 2 点で【常時】実行し、両者の生ログ + 実行有無 + pass/fail 判定を返り値 JSON(selfTestBaseline/
//      selfTestFinal)へ載せる=gate/orchestrator が actor 報告に依存せず self-test 状態を直読できる。WF 本体は
//      Bash 非所持ゆえ各々 cheap agent(worktree で cd し selfTestCmd を 1 回実行・生ログを返す read-only=roAgent
//      経由で scribe:explore + model:sonnet=mechanical run)に委譲する。設計上の不変条件(回帰なし=受入 B4):
//        - baseline/final は【情報ログ専用】= converged/escalate 判定を一切駆動しない(既存の Fix agent 内
//          fail-closed self-test ゲートとは別物・温存)。escalate/収束は従来ロジックのまま。
//        - 発火条件は selfTestCmd の有無のみ。未定義 bead(admin read-only gate=scribe-gate-args.sh は
//          selfTestCmd を渡さない)では graceful skip(fail-open・skip を JSON へ明示)=read-only gate 経路が不変。
//        - snapshot 合成・autoFix fail-closed ゲート・escalate 判定は一切触らない(独立追加)。
// ─────────────────────────────────────────────────────────────────────────────

// ── (8) defensive args parse(un-2yy): string で届いたら JSON.parse、object はそのまま ──────────
// 受信型を記録(parse 前)= 呼出元の serialization 経路を返り値で可視化する。
const __rawArgsType = args === null ? 'null' : Array.isArray(args) ? 'array' : typeof args
let A
if (typeof args === 'string') {
  // string 到達 = 呼出元が args を JSON 文字列化した経路。parse して object へ正規化する。
  try {
    const parsed = JSON.parse(args)
    // JSON.parse は 'null'/'42'/'"x"' 等も成功させる → object でなければ args 不在と同義で扱う。
    A = parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed : {}
  } catch (e) {
    // parse 失敗 = scope/契約が一切判定不能。agent を一切起動せず即 escalate(silent 暴走根治)。
    // un-y4t: taskTitle が確定できない経路でも、最初の log で「これは cell-quality の run である」と
    // 識別可能にする(同名 WF 並走時の進行ビュー識別。meta.name は純リテラル制約で run ごとに変えられない=
    // ハーネス制約ゆえ log 行が達成可能な上限)。taskTitle 不明のため起動マーカーのみを冠する。
    log('[args parse 失敗] cell-quality 起動: args の JSON.parse に失敗(taskTitle 不明)')
    const reason = `defensive parse 失敗: string args の JSON.parse が失敗(${e && e.message ? e.message : 'invalid JSON'})。scope/契約が不明のまま実装/レビューさせない。呼出元が args の serialization を修正して再 invoke すること。`
    log(`fail-fast: ${reason}`)
    return {
      taskTitle: '(untitled cell)',
      taskType: '',
      verifyStrategy: '',
      mode: 'single',
      converged: false,
      escalate: true,
      escalateReason: reason,
      rounds: 0,
      maxRounds: 0,
      autoFix: false, // 起動前に中断=自動修正は一切走っていない
      reviewModel: 'opus',
      verifyModel: 'opus',
      fableCapped: false,
      maxConcurrency: 0, // (D2) args 不明=cap 計算前。0=無 cap
      opusCapped: false,
      blocking: [],
      minor: [],
      refuted: [],
      unverified: [],
      history: [],
      diff: '',
      machineryFailedLastRound: false,
      // (10) sc-jx8: 起動前中断=self-test は一切走っていない。返り値 shape の一貫性のため skip を明示。
      selfTestBaseline: { ran: false, skipped: true, skipReason: 'WF 起動前に中断(args parse 失敗)', passed: null, exitCode: null, rawLog: '' },
      selfTestFinal: { ran: false, skipped: true, skipReason: 'WF 起動前に中断(args parse 失敗)', passed: null, exitCode: null, rawLog: '' },
      receivedArgs: { type: __rawArgsType, parseFailed: true, keys: [] },
      gate: `ESCALATE: ${reason}`,
    }
  }
} else {
  A = args && typeof args === 'object' && !Array.isArray(args) ? args : {}
}

// ── (sc-7bv) read-only agent 起動 helper: builtin 'Explore' 消失(harness breaking change)への恒久 fix ──
// 旧 read-only 段(classify/plan/snapshot/review/verify/self-test 実行)は builtin の read-only agent 型 'Explore'(書込
// ツールを持たない型)を agentType に指定して read-only を構造強制していたが、Claude Code registry から 'Explore' が削除され spawn
// 前に即 throw する(fleet 全滅)。代わりに scribe plugin の read-only custom agent(agentType 'scribe:explore'
// =agents/explore.md)を指す。registry から解決不能な session(scribe plugin 未ロード / merge 前の worker
// session / 将来の registry drift)では agentType 省略へ後退して read-only 規律を prompt で代替する(fallback)。
// args.roAgentType で RO agent type を差し替え可能・'none' で agentType 無しを強制する(運用 escape hatch)。
// roAgent が管理する agentType は各呼出サイトでは指定しない(roAgent へ一元化)。
const _rawRoAgentType = typeof A.roAgentType === 'string' ? A.roAgentType.trim() : ''
const RO_AGENT_TYPE = _rawRoAgentType || 'scribe:explore'
const RO_FORCE_NONE = RO_AGENT_TYPE === 'none' // 'none' = 最初から agentType を付けない強制
let roFallbackActive = RO_FORCE_NONE // not found を一度検知したら以降降格(flag・並行 race は同じ降格へ収束=無害)

// fallback 時、agentType の構造強制(書込ツール非所持)を prompt の read-only 規律で代替する(前置文)。
const RO_DISCIPLINE =
  '\n\n## 厳守（read-only・agentType 構造強制の代替）\n' +
  'あなたは read-only の観測・分析役。ファイル編集(Write/Edit)・git write(commit/push/add)・bd write・deploy・' +
  '別 agent の spawn を一切しない。Bash は読取り・検証実行(self-test 実行 / git read / bd show 等)に限り、コード・' +
  '状態を変えない。返り値(構造化データ)だけを返す(呼出元が一次監査する)。'

// registry から agentType が解決できなかった throw かを判定(probe verified のエラー形状:
// "agent({agentType}): agent type 'X' not found. Available agents: ...")。not found 以外は透過する。
const isAgentTypeNotFound = (e) => {
  const m = e && e.message ? String(e.message) : String(e == null ? '' : e)
  return /agent type\b[\s\S]*\bnot found/i.test(m) || /not found\. Available agents:/i.test(m)
}

// roAgent(prompt, opts): read-only 段の agent() 代替。RO_AGENT_TYPE を注入し、not found なら agentType 省略へ後退。
// - 降格済/強制 none: agentType 無し + read-only 規律 prompt 前置。
// - not found 検知: [RO-FALLBACK] を loud に log し降格 flag を立て、以降の read-only 段も agentType 無しへ。
// - not found 以外の throw: そのまま透過(呼出元の既存 .catch 意味論=不変条件(5)を変えない)。
// 返り値は agent() と同一の Promise(.then/.catch 互換)。runAgent(limiter 経由)も内部でこれを呼ぶ。
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

// receivedArgs 要約: キー一覧 + 各キーの受信型 + 生の受信型(parse 前)。呼出元監査用に返り値へ載せる。
const receivedArgs = {
  type: __rawArgsType, // 'string'(parse 済)/'object'/'undefined'/'null'/'array' 等(parse 前の生型)
  parseFailed: false,
  keys: Object.keys(A),
  keyTypes: Object.fromEntries(Object.keys(A).map((k) => [k, Array.isArray(A[k]) ? 'array' : typeof A[k]])),
  roAgentType: RO_AGENT_TYPE, // (sc-7bv) 解決した read-only agentType(既定 'scribe:explore' / override / 'none')
}

// ── args(固有物)。骨格は不変、ここだけ差し替える ───────────────────────────
// un-2yy: defensive parse は args 容器(string/object)を正規化するが、個別フィールドの型までは保証しない。
// JSON.parse 経由では数値/真偽等が紛れうる(例: diff:5)。後段で string メソッド(.trim 等)を呼ぶ scalar
// 文字列フィールドは typeof ガードで正規化し、非文字列は「未指定(既定値)」と等価に倒す。これで壊れた入力でも
// crash させず、必須欠落なら fail-fast、対象不在なら EMPTY_DIFF escalate の網に収める(defensive parse の趣旨を貫く)。
const str = (v, d) => (typeof v === 'string' ? v : d)
const taskTitle = str(A.taskTitle, '(untitled cell)')
// un-y4t: taskTitle 確定直後・全 return path より前に、taskTitle を冠した起動 log を最初の narrator 行として出す。
// 同名 WF(meta.name は純リテラル制約で run ごとに変えられない=ハーネス制約)の並走 run を進行ビューで識別する
// 唯一の手段。これより後ろの早期 return(args fail-fast 等)はすべて自分の log を持つが、この行が必ず log[0] になる。
log(`[${taskTitle}] cell-quality 起動`)
const worktree = str(A.worktree, '(current worktree)')
const goal = str(A.goal, '')
const acceptance = str(A.acceptance, '')
const context = str(A.context, '')
const diff = str(A.diff, '') // 静的に渡された diff。空ならラウンド毎に snapshot で取得
const probe = str(A.probe, '') // executable 系の実証手順(dry-run/arg-echo/実機)
const selfTestCmd = str(A.selfTestCmd, '') // autoFix ゲートの self-test コマンド
const target = str(A.target, '') // スコープ対象の説明(snapshot/review のアンカー)
// un-2f1: snapshot 合成の base ref。worktree のセル diff は「base からの commit 済 + 未 commit」の和。
// 既定 = origin/main(無ければ main)との merge-base = セルが分岐した起点。Implement/Fix が round 内で commit
// しても `git diff HEAD` だけでは消えてしまう差分を base...HEAD で回収する(false EMPTY_DIFF 根治)。
const _rawBaseRef = (typeof A.baseRef === 'string' && A.baseRef.trim()) || ''
// baseRef は snapshotPrompt で `BASE="${baseRef}"`（二重引用符内）として bash へ埋め込まれる(sc-38w hardening)。
// 二重引用符内で危険なのは " $ ` \ と空白/改行のみ。git ref 安全文字(英数 . _ / - ~ ^ @ {} ＝HEAD~1/HEAD^/
// HEAD@{1} 等の正当 ref を含む)だけ許可し、それ以外を含む不正値は空扱い→merge-base フォールバックへ倒す
// (trust boundary 内ゆえ RCE でないが、malformed ref の self-inflicted な壊れた bash / false EMPTY_DIFF を防ぐ)。
const baseRef = /^[A-Za-z0-9._/~^@{}-]+$/.test(_rawBaseRef) ? _rawBaseRef : ''
// scribeAddPath(sc-u4u): gated autoFix が confirmed を修正後コミットする際、Fix/implement agent が stage に
// 使う道具パス。CC sandbox は cwd の既知 dotfile/.claude を /dev/null character device 化し `git add -A` を
// rc=128 で落とす(sc-yqa)。供給時は Fix/implement の stage を `git add -A` でなく scribe-add(非通常ファイルを型で
// 弾く薄ラッパ)に固定する=default-on で全 worker が踏む autoFix 経路の degraded(取りこぼし/失敗)を deterministic
// に塞ぐ。selftest-args が常時供給(scribe-add は git add -A の安全上位互換ゆえ SCRIBE_SANDBOX 検出に依らず渡せる)。
// 未供給(直接呼出・admin の read-only gate=Fix 非発火)は現挙動を維持(完全後方互換)。プロンプトに埋め agent が
// shell 実行するため、baseRef と同じく path 安全文字のみ許可し不正値は空へ倒す(self-inflicted な壊れた command を防ぐ)。
// baseRef と同じ trim 変種で正規化する(whitespace-only を未供給=空へ畳み warn しない=同種 path フィールドの対称)。
const _rawScribeAdd = (typeof A.scribeAddPath === 'string' && A.scribeAddPath.trim()) || ''
const scribeAddPath = /^[A-Za-z0-9._/-]+$/.test(_rawScribeAdd) ? _rawScribeAdd : ''
// 供給されたが検証を外れた場合(非空 かつ regex 不一致=稀な空白/非ASCII を含む exotic install path 等)は loud に warn
// する(sc-u4u gate の有用提案)。空 fallback は「未供給=意図的 legacy(後方互換)」と「供給されたが reject」を同一に縮退
// させ、後者では scribe-add 固定が無音で外れる。これを silent にせず可視化する。【posture 明示】これは warn のみで
// autoFix は止めず legacy 経路で続行する fail-open(selfTestCmd 欠落で canAutoFix=false=autoFix 自体を無効化する
// fail-closed とは failure-posture が逆。両者は「log で可視化する」点だけが同形)。よって『決定論』は『reject されても
// degraded を loud に表面化し silent にしない(可視化)』の意味で、reject を防ぐ強い保証ではない。退行の最終 salvage は
// §5 step1/§6 の 0-commit 検出網。許可集合は trust-boundary 内ゆえ意図的に保守的(worktree も未 quote 補間=同 posture)。
if (_rawScribeAdd && !scribeAddPath) {
  log(`警告: scribeAddPath が path 安全文字を外れ無効化(${_rawScribeAdd.slice(0, 60)})。autoFix/implement が走る run では stage が scribe-add 固定でなく旧経路へ後退する(sandbox では git add -A の rc=128 死 risk・fail-open=autoFix は続行)。install path を ASCII-clean にするか args を見直すこと。`)
}
const MODEL = A.model || 'opus' // substantive 既定 = opus(cheap→opus 格上げ)
const maxRounds = Number.isInteger(A.maxRounds) && A.maxRounds > 0 ? A.maxRounds : 3 // hard cap
// ── (D2) opus 並列 cap(un-3yc): review fan-out / verify parallel(= opus 経路)の同時実行を args で絞る。
// 未指定(0)=無 cap=従来どおり harness の min(16,cores-2)が実効上限(後方互換=安全既定。設計核(6)の「既定
// 経路の並列度は不変」を破らない)。正整数指定時のみ opusLimiter を作り、runAgent 経由の opus agent を
// ≤ maxConcurrency に絞る。逐次段(classify/plan/implement/snapshot/fix)は agent() 直呼びで runAgent を
// 通らない=cap は opus 経路にのみ効き、他フェーズの逐次性・.catch 正規化(不変条件(5))に干渉しない。
const maxConcurrency = Number.isInteger(A.maxConcurrency) && A.maxConcurrency > 0 ? A.maxConcurrency : 0
const wantAutoFix = A.autoFix === true // 共有既定 off(fail-safe)。worker cell は true を渡す
const doPlan = A.doPlan === true
const doImplement = A.doImplement === true
let taskType = typeof A.taskType === 'string' ? A.taskType : '' // 空なら classify する
let refinedAcceptance = acceptance // Plan で精緻化されたら更新(review/verify/fix の ctxBlock に伝播)

// ── (1) per-stage model 上書き + fable→opus 降格(新方針=dynamic WF から fable 全廃) ─────────────
// fable 判定は per-stage model の解決(下)より前に置く必要がある(降格を解決値へ適用するため)。
// 判定は **部分一致** `/fable/i`= ツール層(scribe-{gate,selftest}-args.sh / scribe-spawn.sh の `*fable*`)と
// 兄弟 WF(needs-user-prebake.workflow.js の `/fable/i`)に意味を揃える。旧 exact-match 集合だと
// `claude-fable-5-preview` 等の派生名を WF 直叩き経路(gate-args を通さず args 直投入)で取りこぼし、
// demoteFable も ≤2 cap(共に isFable 依存)も外れた二重 fail-open で silent にフルコスト fable が走る(sc-tl3)。
// 部分一致なら新 variant 名の列挙保守が不要(根治)。'fable' は Anthropic のモデル系統名ゆえ偽陽性はまず無い
// (ツール層・兄弟 WF も同じ risk を受容済み)。大小文字ゆらぎは /i で吸収する。
const isFable = (m) => /fable/i.test(m || '')
const FABLE_MAX_CONCURRENCY = 2

// un-1kb: 解決済み model 値が fable なら opus へ降格する単一ヘルパ。新モデル方針(2026-06-10 改訂=dynamic WF
// に fable 禁止)を機械的に強制する。降格は fable のときだけ=sonnet/haiku 等の意図的な安価指定は尊重して素通し。
// 降格時は warn log で可視化する(明示 fable 指定でも MODEL=fable 継承の fail-open でも、同じ降格に倒す)。
const demoteFable = (m, stage) => {
  if (isFable(m)) {
    log(`model 降格: ${stage}=${m} を opus へ降格(新方針=dynamic WF から fable 全廃。review/verify は fable で走らせない)。`)
    return 'opus'
  }
  return m
}

// reviewModel/verifyModel = per-stage の model 上書き。既定 = MODEL(= A.model = opus)= 完全後方互換
// (per-stage args を渡さなければ review/verify は従来どおり MODEL のまま=既定経路で全 agent が opus)。
// 解決値に demoteFable を適用: 明示 fable 指定も、per-stage 未指定で MODEL=claude-fable-5 を継承した fail-open
// 経路(spawn worker が --model opus を怠った場合)も、review/verify が fable で走らないよう opus へ畳む。
const reviewModel = demoteFable((typeof A.reviewModel === 'string' && A.reviewModel) || MODEL, 'reviewModel')
const verifyModel = demoteFable((typeof A.verifyModel === 'string' && A.verifyModel) || MODEL, 'verifyModel')

// 逐次段(Classify/Plan/Implement/Snapshot/Fix)の model。これら 5 段は本質的に逐次(同時 1)だが、un-bs0 改訂 spec
// 「Implement/Fix/Classify/Plan/Snapshot は Opus 維持」とコスト都合(fable=実コスト 2×Opus 超)で fable は opus へ
// 降格する。sonnet/haiku 等の意図的な安価指定は尊重して素通し(降格は MODEL が fable のときだけ)。
const stageModel = demoteFable(MODEL, 'stageModel(MODEL)')

// fable ≤2 同時実行 cap 機構(defense-in-depth)。un-1kb で reviewModel/verifyModel は demoteFable で opus へ
// 畳まれるため通常経路に fable agent は流れない=この limiter は実質 no-op だが、将来 fable が runAgent へ直接
// 到達した場合(降格漏れ等)の最終防壁として残置する。理由: fable は名目 2×Opus 単価 + tokenizer 差で実コスト
// 2 倍超、かつハーネスに fable 専用の自動同時実行制限が無い(verified)。広 fan-out は予算を急速に消費する。
//
// 最小の concurrency limiter(セマフォ): max 並列までに絞り、超過分は FIFO で待たせる。
// thunk の reject はそのまま伝播する → review/verify 側の .catch による失敗正規化(不変条件(5))を壊さない。
function makeLimiter(max) {
  let active = 0
  const queue = []
  const pump = () => {
    while (active < max && queue.length) {
      active++
      const { thunk, resolve, reject } = queue.shift()
      Promise.resolve()
        .then(thunk)
        .then(
          (v) => {
            active--
            pump()
            resolve(v)
          },
          (e) => {
            active--
            pump()
            reject(e)
          }
        )
    }
  }
  return (thunk) =>
    new Promise((resolve, reject) => {
      queue.push({ thunk, resolve, reject })
      pump()
    })
}
// review(観点=最大4)と verify(finding 数=可変)を【貫く単一の共有 limiter】。pipeline が観点を
// interleave しても「同時実行 fable agent ≤2」を全体で保証する(stage 別 limiter では観点間の重なりを
// 取りこぼす)。デッドロックは起きない: 各 agent は 1 スロットを取得→実行→解放で完結し、スロット保持中に
// 別スロットの取得を待つ入れ子が無い(stage1 review はスロット解放後に stage2 verify が走る)。
const fableLimiter = makeLimiter(FABLE_MAX_CONCURRENCY)

// ── (D2) opus 経路(review fan-out / verify parallel)を貫く単一の共有 limiter ─────────────────
// maxConcurrency 未指定(0)なら null=素通し(後方互換=harness 任せ)。指定時のみ作り、review(観点)と
// verify(finding)を interleave しても「同時実行 opus agent ≤ maxConcurrency」を全体で保証する(fableLimiter
// と同じ単一共有セマフォ思想=stage 別 limiter では観点間の重なりを取りこぼす)。makeLimiter は thunk の
// reject を透過するため review/verify 側の .catch 失敗正規化(不変条件(5))を壊さない。デッドロックは起きない:
// 各 agent は 1 スロット取得→実行→解放で完結し、スロット保持中に別スロットの取得を待つ入れ子が無い
// (stage1 review はスロット解放後に stage2 verify が走る=fableLimiter と同じ無デッドロック証明)。
const opusLimiter = maxConcurrency > 0 ? makeLimiter(maxConcurrency) : null

// agent() を model に応じてラップ: fable 指定のみ共有 limiter 経由(≤2 cap)、それ以外は素通し。
// un-1kb 後は reviewModel/verifyModel が demoteFable で opus へ畳まれるため通常は fable 分岐に入らない(素通し)が、
// 降格漏れの最終防壁として cap 分岐を残す(defense-in-depth)。返り値は agent() と同一の Promise(.then/.catch 互換)。
// (D2) fable 指定は fableLimiter(≤2・defense-in-depth)経由。非 fable(=通常 opus)は opusLimiter があれば
// それ経由(≤ maxConcurrency)、無ければ素通し(従来=harness 任せ)。runAgent は review/verify(read-only 段)でのみ
// 呼ばれる(逐次段は agent()/roAgent() 直呼び)ため、opusLimiter の cap は opus 経路にのみ効き他フェーズの逐次性に
// 干渉しない。read-only 段ゆえ内部は roAgent 経由で RO agentType('scribe:explore')注入 + not found fallback を
// 通す(sc-7bv)。roAgent の fallback(2 回目の agent 呼出)は同一 thunk 内で完結し limiter スロットを 1 個保持した
// ままなのでデッドロックしない(スロット保持中に別スロット取得を待つ入れ子が無い)。
function runAgent(prompt, opts) {
  if (isFable(opts.model)) return fableLimiter(() => roAgent(prompt, opts))
  if (opusLimiter) return opusLimiter(() => roAgent(prompt, opts))
  return roAgent(prompt, opts)
}

// dimensions は文字列配列でもオブジェクト配列でも受ける。既定 = perspective-diverse 4 観点。
const DEFAULT_DIMENSIONS = [
  { key: 'correctness', focus: 'ロジック誤り・境界条件・受入基準未達・回帰・仕様逸脱' },
  { key: 'robustness-security', focus: 'fail-open/bypass・入力検証・エラーパス・破壊的操作・権限・秘密混入' },
  { key: 'integration-ops', focus: '他モジュール/hook/deploy/配布スコープへの影響・SSOT 整合・boot path・全ホスト波及' },
  { key: 'completeness-critic', focus: '抜け(未検証の claim・未達の受入基準・触れていない modality)= 何が欠けているか' },
]
// ── (D3) dimensions 枠分業(un-3yc): 必須4観点(枠)を WF 本体で必ず含める + 追加観点 ─────────────
// 呼出元 LLM が観点を落としても WF が補完する=「worker LLM 任せの穴」を二重に塞ぐ(admin gate=固定4 /
// worker 自己点検=4必須+追加可)。受け取った A.dimensions は: 必須4 key と同名なら focus を上書き(worker の
// focus 調整)、未知 key は追加観点として末尾に積む(worker の追加観点)。admin gate(scribe-gate-args.sh)は
// dimensions を渡さない → 必須4のみ=固定4。worker(scribe-selftest-args.sh)は必須4+追加を渡す。
const __normDim = (d) => (typeof d === 'string' ? { key: d, focus: '' } : d)
const __provided = (Array.isArray(A.dimensions) ? A.dimensions : [])
  .map(__normDim)
  .filter((d) => d && typeof d.key === 'string' && d.key)
const __providedByKey = new Map(__provided.map((d) => [d.key, d]))
const __requiredKeys = new Set(DEFAULT_DIMENSIONS.map((d) => d.key))
// 必須4: 同名 provided があれば focus を上書き採用(非空 string のみ)、無ければ DEFAULT の focus を保つ。
const __requiredDims = DEFAULT_DIMENSIONS.map((d) => {
  const p = __providedByKey.get(d.key)
  const focus = p && typeof p.focus === 'string' && p.focus ? p.focus : d.focus
  return { key: d.key, focus }
})
// 追加観点: 必須4 key 以外(順序維持・key 重複は最初のみ)。
const __seenExtra = new Set()
const __extraDims = __provided.filter((d) => {
  if (__requiredKeys.has(d.key) || __seenExtra.has(d.key)) return false
  __seenExtra.add(d.key)
  return true
})
const dimensions = [...__requiredDims, ...__extraDims]
// (un-mpv・案a) dimensions は切り詰めない: 追加観点(--add-dimension)を slice で落とすと、ユーザー意図の
// 観点が黙って消える(silent no-op)。review fan-out の並列コスト爆発は dimension【数】を削ることではなく
// opusLimiter(同時実行 cap=maxConcurrency)で防ぐ — 追加観点は review/verify の共有 limiter に積まれるだけで
// 「同時実行 opus agent ≤ maxConcurrency」を破らない(キューされ順次処理されるだけ)。旧 dimCap=max(必須4,
// maxConcurrency)切り詰めは既定 maxConcurrency=4(scribe-selftest-args.sh)のとき総数4で頭打ちし、追加観点
// (総数>4)を全て黙殺していた(un-aq5 gate F1)ため撤廃した。コスト制御は opusLimiter に一元化する(dimension
// 数による冗長な二重制御を排し、ユーザー意図の追加観点を lossy に切り捨てない)。

// task-type → verify 戦略(un-bs0 Q1)。
const VERIFY_STRATEGY = {
  testable:
    'TDD red→green: bats 等で失敗テストを先に書き、実装で green 化する。self-test が pass/fail の明確なゲート。',
  executable:
    'launcher/hook/deploy 等の実行系: dry-run・arg-echo・実機で実証する(静的 diff で終わらせない)。',
  docs:
    'docs: 相互参照の整合・SSOT 一貫性・リンク切れ・記述と実体(コード/設定)の一致を verify する。',
  config:
    'config: 相互参照の整合・SSOT 一貫性・記述と実体の一致を verify する(配布スコープにも注意)。',
  monitoring: 'monitoring: 軽量チェック(記述妥当性・破壊性なし)。重い verify loop は回さない。',
  notes: 'notes: 軽量チェック(整合・破壊性なし)。重い verify loop は回さない。',
}
const LIGHT_TYPES = new Set(['monitoring', 'notes'])

// ── schema 定義 ───────────────────────────────────────────────────────────────
const CLASSIFY_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['taskType', 'rationale'],
  properties: {
    taskType: { type: 'string', enum: ['testable', 'executable', 'docs', 'config', 'monitoring', 'notes'] },
    rationale: { type: 'string' },
  },
}

const PLAN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['acceptance'],
  properties: {
    acceptance: { type: 'string', description: '導出/精緻化した受入基準(箇条書き可)' },
    notes: { type: 'string' },
  },
}

const FINDINGS_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['title', 'severity', 'location', 'rationale'],
        properties: {
          title: { type: 'string' },
          severity: { type: 'string', enum: ['critical', 'major', 'minor', 'nit'] },
          location: { type: 'string', description: 'file:line 等' },
          rationale: { type: 'string' },
          suggestedFix: { type: 'string' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['refuted', 'confidence', 'reasoning'],
  properties: {
    refuted: {
      type: 'boolean',
      description: 'true=この finding は誤検出/無効/過剰提案。確証が無ければ refuted=true 寄りにする。',
    },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    reasoning: { type: 'string' },
  },
}

const FIX_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['applied', 'selfTestRan', 'selfTestPassed', 'summary'],
  properties: {
    applied: { type: 'array', items: { type: 'string' }, description: '適用した fix の要約リスト' },
    selfTestRan: { type: 'boolean', description: 'self-test を実際に実行したか' },
    selfTestPassed: { type: 'boolean', description: 'self-test の pass/fail。未実行なら false。' },
    amended: { type: 'boolean', description: 'self-test pass 時に実装コミットへ amend したか' },
    summary: { type: 'string' },
    newDiff: { type: 'string', description: 'fix 適用後の worktree diff(任意・参考)' },
  },
}

// (10) selfTestCmd 常時実行(sc-jx8): baseline/final の cheap runner agent が返す構造化結果。
// WF 本体は Bash 非所持ゆえ worktree で selfTestCmd を 1 回実行し、実行有無/pass-fail/生ログを返す。
const SELFTEST_RUN_SCHEMA = {
  type: 'object',
  additionalProperties: false,
  required: ['ran', 'passed', 'rawLog'],
  properties: {
    ran: { type: 'boolean', description: 'selfTestCmd を実際に実行できたか(true=実行した)' },
    passed: { type: 'boolean', description: '終了コード 0 なら true(exit != 0 は false)' },
    exitCode: { type: 'integer', description: '終了コード(取得できた場合)' },
    rawLog: { type: 'string', description: 'stdout+stderr を合わせた生ログ(長大時は末尾優先で切り詰め可)' },
  },
}

// ── prompt builders(固有物を文脈として注入) ─────────────────────────────────
function ctxBlock() {
  return [
    `# セル: ${taskTitle}`,
    `worktree: ${worktree}`,
    goal ? `goal:\n${goal}` : '',
    refinedAcceptance ? `acceptance(受入基準):\n${refinedAcceptance}` : '',
    context ? `context:\n${context}` : '',
  ]
    .filter(Boolean)
    .join('\n\n')
}

function classifyPrompt() {
  return `${ctxBlock()}

このセルの作業種別を分類せよ。区分の定義:
- testable: script/guard/deploy 等、自動テスト(bats 等)で pass/fail が決まるもの。
- executable: launcher/hook/deploy 等、dry-run・arg-echo・実機でしか実証できない実行系。
- docs: ドキュメントの追加/更新。
- config: 設定ファイル(yaml/json/conf 等)の変更。
- monitoring: 監視・観測系の軽微な変更。
- notes: メモ・台帳等の軽微な記録。
JSON で {taskType, rationale} を返せ。`
}

function planPrompt() {
  return `${ctxBlock()}

このセルの受入基準を導出/精緻化せよ。検証可能(testable/falsifiable)な箇条書きにすること。
編集はせず、読み取り調査のみ。JSON で {acceptance, notes} を返せ。`
}

function implementPrompt(refinedAcceptance) {
  // commitNote: scribeAddPath 供給時は stage を `git add -A` でなく scribe-add に固定する(sc-u4u)。
  // sandbox では `git add -A` が /dev/null device 化された dotfile で rc=128 死し commit を取りこぼす。
  const commitNote = scribeAddPath
    ? `受入基準を満たすことを目標にする。コミットはこの段階で行ってよい(worktree 内)。**stage は \`git add -A\` を使わず \`${scribeAddPath}\`** で行う(CC sandbox は cwd の既知 dotfile/.claude を /dev/null device 化し \`git add -A\` を rc=128 で落とす・sc-yqa。scribe-add は非通常ファイルを型で弾く sandbox-safe な薄ラッパ): \`cd "${worktree}" && "${scribeAddPath}" && git commit -m ...\` の形で stage→commit する。`
    : `受入基準を満たすことを目標にする。コミットはこの段階で行ってよい(worktree 内)。`
  return `${ctxBlock()}
${refinedAcceptance ? `\n精緻化された受入基準:\n${refinedAcceptance}\n` : ''}
このセルを worktree ${worktree} で実装せよ。
- 既存コードの規約(命名・コメント密度・イディオム)に合わせる。
- ${commitNote}
- 破壊的操作・anchor の main 離脱は禁止。秘密情報を混入しない。
完了したら何を実装したか簡潔に返せ。`
}

function snapshotPrompt() {
  // un-2f1: セルの全差分 = 「base からの commit 済差分」+「未 commit 差分」の和。Implement/Fix が round 内で
  // commit すると `git diff HEAD` だけでは commit 済分が消え、snapshot が false EMPTY_DIFF になって fail-closed
  // が hard cap まで空回り → false escalate する(un-x3o/un-iur の再現条件)。よって base...HEAD で commit 済分を
  // 回収し、未 commit 分と合成して「commit したかに依らず」セル全体を捕捉する。
  const baseExpr = baseRef
    ? `BASE="${baseRef}"`
    : // base 未指定: origin/main(無ければ main)との merge-base を起点にする。どちらも無ければ HEAD の親へ退避。
      `BASE="$(git -C "${worktree}" merge-base HEAD origin/main 2>/dev/null || git -C "${worktree}" merge-base HEAD main 2>/dev/null || echo HEAD~1)"`
  return `worktree ${worktree} の「このセルの全作業差分」を取得せよ。重要: 実装/修正 agent が round 内で commit
していても差分が消えないよう、**base からの commit 済差分**と**未 commit 差分**を合成して取得すること。

以下を実行して合成 diff の生テキストを返せ(編集・commit は一切するな):
\`\`\`bash
${baseExpr}
# (a) base からの commit 済差分(round 内で commit されても残る) + (b) 未 commit 差分(staged 含む)
git -C "${worktree}" diff "$BASE"...HEAD
git -C "${worktree}" diff HEAD
\`\`\`
${target ? `特にスコープ対象「${target}」を含む ` : ''}上記 (a)+(b) を結合した **生 diff テキストのみ** を返せ
(説明文・前置き・コードフェンス・要約を一切付けない。'diff --git ...' から始まる生の diff をそのまま出す)。
両方とも空(=base からの commit も未 commit 変更も無い)のときだけ、他の語を一切付けず "EMPTY_DIFF" の一語だけを返せ。
注意: 一方が空でも他方に差分があれば EMPTY_DIFF ではない(必ず両方を確認すること)。`
}

function reviewPrompt(d, round, roundDiff) {
  return `${ctxBlock()}

あなたは観点「${d.key}」専任のレビュアー(read-only)。${d.focus ? `重点: ${d.focus}` : ''}
verify 戦略(task-type=${taskType || 'unknown'}): ${VERIFY_STRATEGY[taskType] || '一般的なコードレビュー基準で評価する。'}
${probe ? `\n実証手順(executable 系の確認に使う): ${probe}` : ''}

【スコープ固定】以下の diff のみを対象にレビューせよ(anchor 全体に拡張しない):
<diff round=${round}>
${roundDiff || '(diff 未供給。worktree の現状を read-only で確認してよい)'}
</diff>

観点「${d.key}」に該当する問題のみを挙げよ。各 finding に severity(critical/major/minor/nit)を厳密に付与すること。
- critical/major = 収束ループを駆動する(受入未達・回帰・fail-open・破壊性・boot path 等)。
- minor/nit = 記録のみ(ループさせない)。過剰提案・好みの指摘は出さない。
JSON で {findings:[{title,severity,location,rationale,suggestedFix?}]} を返せ。問題が無ければ findings:[]。`
}

function verifyPrompt(f, dimKey, roundDiff) {
  return `あなたは独立した検証者(read-only)。下記 finding を **反証(refute)** せよ。
立証責任は finding 側にある: diff/ソースに照らして具体的・実害ありと確証できる場合のみ refuted=false。
少しでも不確か・再現不能・過剰提案・スコープ外なら refuted=true にせよ(デフォルトは refuted=true 寄り)。

観点: ${dimKey}
finding:
- title: ${f.title}
- severity: ${f.severity}
- location: ${f.location}
- rationale: ${f.rationale}
${f.suggestedFix ? `- suggestedFix: ${f.suggestedFix}` : ''}

対象 diff:
<diff>
${roundDiff || '(diff 未供給。worktree を read-only で確認してよい)'}
</diff>

JSON で {refuted, confidence, reasoning} を返せ。`
}

function fixPrompt(confirmedBlocking, roundDiff) {
  const list = confirmedBlocking
    .map((f, i) => `${i + 1}. [${f.severity}] ${f.title} @ ${f.location}\n   理由: ${f.rationale}${f.suggestedFix ? `\n   提案: ${f.suggestedFix}` : ''}`)
    .join('\n')
  // stageStep: scribeAddPath 供給時は stage を `git add -A` でなく scribe-add に固定する(sc-u4u)。
  // sandbox では `git add -A` が /dev/null device 化された dotfile で rc=128 死し amend が失敗→degraded。
  // 正確なコマンド形で渡し agent の compliance を最大化する(snapshotPrompt と同じ明示コマンド方式)。
  const stageStep = scribeAddPath
    ? `PASS したら実装コミットへ取り込む(amended=true)。**stage は \`git add -A\` を使うな**——CC sandbox では cwd の既知 dotfile/.claude が /dev/null character device 化され \`git add -A\` が rc=128 で落ちる(sc-yqa)。次の正確なコマンドで stage→amend せよ: \`cd "${worktree}" && "${scribeAddPath}" && git commit --amend --no-edit\`(直前に自分のコミットが無ければ \`git commit --amend\` でなく \`git commit -m ...\`)。\`${scribeAddPath}\` は非通常ファイルを型で弾いて通常ファイル/symlink のみ stage する sandbox-safe な薄ラッパ。`
    : `PASS したら実装コミットへ \`git commit --amend --no-edit\`(無ければ通常コミット)で取り込む(amended=true)。`
  return `${ctxBlock()}

worktree ${worktree} で、以下の **confirmed(反証されなかった) critical/major findings のみ** を修正せよ。
それ以外(minor/nit/refuted)は触るな。スコープを広げるな。

confirmed findings:
${list}

対象 diff:
<diff>
${roundDiff || '(worktree の現状を確認して修正)'}
</diff>

手順(fail-closed ゲート):
1. confirmed findings を修正する。
2. self-test を実行する: \`${selfTestCmd}\`
   - ${stageStep}
   - FAIL したら **amend せず停止**し、selfTestPassed=false で報告する(回避策を打たない=fail-closed)。
3. 破壊的操作・force push・anchor の main 離脱は禁止。

JSON で {applied, selfTestRan, selfTestPassed, amended, summary, newDiff?} を返せ。`
}

// (10) selfTestCmd 常時実行(sc-jx8): baseline/final を worktree で 1 回実行する cheap runner の prompt。
// read-only(編集・commit 禁止)= self-test を「観測」するだけ。Fix agent 内の fail-closed ゲート(修正→amend)とは別物。
function selfTestRunPrompt(when) {
  return `worktree ${worktree} で self-test コマンドを **1 回だけ実行**し、その生ログと結果を返せ(${when} 計測)。
これは観測専用: **編集・commit・stage は一切するな**(read-only)。コマンドを改変・回避・分割せず、そのまま実行する。

実行するコマンド:
\`\`\`bash
cd "${worktree}" && ${selfTestCmd}
\`\`\`

- 終了コードを記録する(exit 0 = pass=true / それ以外 = false)。
- stdout と stderr を合わせた**生ログ**を rawLog に入れる(長すぎる場合は末尾を優先して切り詰めてよい)。
- コマンドが起動できない/見つからない等で実行不能なら ran=false・passed=false・理由を rawLog に入れる。
JSON で {ran, passed, exitCode, rawLog} を返せ。`
}

// selfTestCmd を worktree で 1 回実行し {ran, skipped, passed, exitCode, rawLog} に正規化する。
// selfTestCmd 未定義なら graceful skip(fail-open=WF は止めず skip を明示)。agent 失敗/skip も観測可能な値へ正規化。
// 【重要・回帰なし(B4)】返り値は情報ログ専用で converged/escalate を一切駆動しない。
async function runSelfTest(when) {
  if (!selfTestCmd) {
    return { ran: false, skipped: true, skipReason: 'selfTestCmd 未指定(graceful skip=fail-open)', passed: null, exitCode: null, rawLog: '' }
  }
  const r = await roAgent(selfTestRunPrompt(when), {
    label: `selftest:${when}`,
    phase: 'Self-test',
    // mechanical run(substantive reasoning でない)。read-only(roAgent=scribe:explore: Bash あり/Edit・Write
    // なし=self-test を実行するが編集はできない)tools + sonnet。roAgent が RO agentType を注入 + not found fallback。
    model: 'sonnet',
    schema: SELFTEST_RUN_SCHEMA,
  }).catch(() => null)
  if (!r) {
    // agent 失敗/skip(schema 枯渇/terminal death)。fail-open で WF は続行するが、実行不能を JSON に明示する
    // (gate/orchestrator が「self-test 状態が取れなかった」を actor 報告に頼らず読めるように)。
    return { ran: false, skipped: false, error: true, skipReason: `self-test runner agent 失敗/skip(${when})`, passed: null, exitCode: null, rawLog: '' }
  }
  return {
    ran: r.ran !== false,
    skipped: false,
    passed: r.passed === true,
    exitCode: Number.isInteger(r.exitCode) ? r.exitCode : null,
    rawLog: typeof r.rawLog === 'string' ? r.rawLog : '',
  }
}

// severity 判定
const isBlocking = (f) => f && (f.severity === 'critical' || f.severity === 'major')
const isMinor = (f) => f && (f.severity === 'minor' || f.severity === 'nit')
const shortTitle = (f) => (f && f.title ? String(f.title).slice(0, 32) : 'finding')

// ── (2) args fail-fast(un-8c4 吸収): worker-cell の必須 args 欠落を【agent 起動前】に検出 ────────
// 不変条件: doImplement か autoFix を要求する worker-cell は worktree(scope)と goal/acceptance(契約)を
// 必ず持つ。autoFix 要求時はさらに selfTestCmd(fail-closed ゲート)が要る。欠けたまま走ると scope 不定・
// gate 不在で編集が暴走する(un-8c4: args 未着→全デフォルト化→自動 amend の rabbit-hole)。よって agent を
// 一切起動せず escalate=true + 明示 reason で即 return する。読み取り専用の軽量用途(diff 供給 + single
// モード = doImplement/autoFix なし)はこのゲート対象外=必須 args を課さず従来の柔軟性を保つ。
const isWorkerCell = doImplement || wantAutoFix
if (isWorkerCell) {
  const missing = []
  const hasWorktree =
    typeof A.worktree === 'string' && A.worktree.trim() && A.worktree.trim() !== '(current worktree)'
  if (!hasWorktree) missing.push('worktree')
  if (!((goal && goal.trim()) || (acceptance && acceptance.trim()))) missing.push('goal/acceptance のいずれか')
  if (wantAutoFix && !(selfTestCmd && selfTestCmd.trim())) missing.push('selfTestCmd(autoFix 時)')
  if (missing.length) {
    const reason = `必須 args 欠落(worker-cell=doImplement/autoFix): ${missing.join(' / ')}。scope/契約/gate 不在のまま実装させない(un-8c4 silent 暴走根治)。`
    log(`fail-fast: ${reason}`)
    // F3: 通常 result とフィールドを揃える(呼出元監査の一貫性)。rounds は 0(agent 未起動)。
    return {
      taskTitle,
      taskType,
      verifyStrategy: '',
      mode: wantAutoFix ? 'loop' : 'single',
      converged: false,
      escalate: true,
      escalateReason: reason,
      rounds: 0,
      maxRounds,
      autoFix: false, // 起動前に中断=自動修正は一切走っていない
      reviewModel,
      verifyModel,
      fableCapped: isFable(reviewModel) || isFable(verifyModel),
      maxConcurrency, // (D2) opus 経路 cap(監査用)。0=無 cap
      opusCapped: maxConcurrency > 0,
      blocking: [],
      minor: [],
      refuted: [],
      unverified: [],
      history: [],
      diff: '',
      machineryFailedLastRound: false,
      // (10) sc-jx8: 必須 args 欠落で agent 未起動=self-test は走っていない。返り値 shape 一貫性のため skip を明示。
      selfTestBaseline: { ran: false, skipped: true, skipReason: 'args fail-fast(必須 args 欠落)で agent 未起動', passed: null, exitCode: null, rawLog: '' },
      selfTestFinal: { ran: false, skipped: true, skipReason: 'args fail-fast(必須 args 欠落)で agent 未起動', passed: null, exitCode: null, rawLog: '' },
      receivedArgs, // 何が届いたか(キー一覧 + 受信型)を呼出元監査用に明示
      gate: `ESCALATE: ${reason} 呼出元/人間が args を補って再 invoke すること。`,
    }
  }
}

// ── 0. Classify(verify 戦略の決定) ────────────────────────────────────────────
phase('Classify')
let verifyStrategy = ''
if (!taskType) {
  const c = await roAgent(classifyPrompt(), {
    label: 'classify',
    phase: 'Classify',
    model: stageModel, // roAgent が RO agentType('scribe:explore')注入 + not found fallback(read-only 段)
    schema: CLASSIFY_SCHEMA,
  })
  taskType = (c && c.taskType) || 'executable'
  log(`task-type = ${taskType}${c && c.rationale ? ` (${c.rationale})` : ''}`)
} else {
  log(`task-type = ${taskType} (args 指定)`)
}
verifyStrategy = VERIFY_STRATEGY[taskType] || VERIFY_STRATEGY.executable

// ── 1. Plan(任意): 受入基準の導出/精緻化 ─────────────────────────────────────
if (doPlan) {
  phase('Plan')
  const p = await roAgent(planPrompt(), {
    label: 'plan',
    phase: 'Plan',
    model: stageModel, // roAgent が RO agentType('scribe:explore')注入 + not found fallback(read-only 段)
    schema: PLAN_SCHEMA,
  })
  if (p && p.acceptance) {
    refinedAcceptance = p.acceptance
    log('受入基準を精緻化した')
  }
}

// ── (10) self-test baseline(sc-jx8): 実装前に selfTestCmd を実行し「開始時点の green/red」を記録 ──────
// regression 起点。selfTestCmd 未定義なら graceful skip(fail-open)。情報ログ専用=converged/escalate を駆動しない
// (既存の Fix agent 内 fail-closed ゲートとは別物・温存)。返り値 selfTestBaseline へ載せる。
const selfTestBaseline = await runSelfTest('baseline')
if (selfTestBaseline.skipped) {
  log('self-test baseline: skip(selfTestCmd 未指定=fail-open)')
} else {
  log(`self-test baseline: ran=${selfTestBaseline.ran} passed=${selfTestBaseline.passed}${selfTestBaseline.error ? ' (runner agent 失敗)' : ''}`)
}

// ── 2. Implement(任意): worktree で実装 ───────────────────────────────────────
if (doImplement) {
  phase('Implement')
  const impl = await agent(implementPrompt(refinedAcceptance), {
    label: 'implement',
    phase: 'Implement',
    model: stageModel, // 編集するので roAgent(read-only agentType)を使わず agent() 直呼び(全ツール)
  })
  log(`implement: ${impl ? String(impl).slice(0, 120) : '(no output)'}`)
}

// ── autoFix ゲートの fail-closed 判定 ─────────────────────────────────────────
// self-test gate が無い状態での自動適用は不可(ゲートできない=危険) → autoFix 無効化。
const canAutoFix = wantAutoFix && !!selfTestCmd
if (wantAutoFix && !selfTestCmd) {
  log('autoFix 要求されたが selfTestCmd 未指定 → fail-closed で autoFix 無効化(confirmed を呼出元へ返す)')
}

// ── 3. loop-until-dry: review → verify → (gated) fix → 再 review ──────────────
let round = 0
let zeroStreak = 0
let converged = false
let escalate = false
let escalateReason = ''
const history = []
const allBlocking = [] // 累積 confirmed blocking(呼出元監査用)
const allMinor = [] // 記録のみ(ループ非駆動)
const allRefuted = [] // 累積 refuted(sc-38w: allBlocking 同様に全ラウンド累積し逆監査情報を欠落させない)
const allUnverified = [] // 累積 unverified(同上)
let lastDiff = diff

// light type(monitoring/notes)はループを回さず 1 ラウンドの軽量チェックのみ。
const effectiveCap = LIGHT_TYPES.has(taskType) ? 1 : maxRounds

// un-2yy: 呼出元が静的 diff を渡したか。渡していれば EMPTY_DIFF な snapshot は無関係(roundDiff が静的 diff を
// 保持)。渡していない(diff='')なら snapshot だけがレビュー対象の供給源 = EMPTY_DIFF は「レビュー対象不在」で
// あって「clean」ではない。single モードでもこれを machinery 失敗扱いにして converged を立てない(下記)。
const staticDiffProvided = !!(diff && diff.trim())

while (round < effectiveCap) {
  round++

  // (2) snapshot: スコープ固定用に diff を inline 取得(静的 diff 指定かつ autoFix off なら再取得しない)
  phase('Review')
  let roundDiff = diff
  // F4: loop mode で snapshot が無効(null/空/EMPTY_DIFF)だと roundDiff='' に縮退し reviewPrompt が
  // 「diff 未供給」フォールバックへ化けて scope 固定が壊れ、reviewers が findings:[] → false converged。
  // un-2f1: かつて EMPTY_DIFF は round1 で commit 済だと `git diff HEAD` が空になって日常的に起き、F4 が
  // hard cap まで空回りして false-escalate していた(un-x3o/un-iur)。snapshotPrompt を base...HEAD(commit 済)
  // + git diff HEAD(未 commit)の合成へ移行し、commit したかに依らず差分を捕捉する。それでもなお空(=base 推定
  // ミス/真の空)なら snapshot 失敗としてマークし、後段の収束判定で clean 扱いから除外する(silent ship 防止)。
  let snapshotFailed = false
  if (!roundDiff || canAutoFix) {
    const snap = await roAgent(snapshotPrompt(), {
      label: `snapshot r${round}`,
      phase: 'Review',
      model: stageModel, // roAgent が RO agentType('scribe:explore')注入 + not found fallback(read-only 段)
    })
    // snapshot agent には「生 diff のみ・空なら EMPTY_DIFF の一語」を指示しているが、LLM は説明文を前置しがち
    // (例: "Both (a) and (b) are empty.\n\nEMPTY_DIFF")。exact-match(snap.trim()!=='EMPTY_DIFF')だと説明文付きの
    // 空応答を取りこぼし、roundDiff に説明文が入って snapshotFailed=false → false converged になる(= un-2yy が
    // 塞ぐ当の false-CONVERGED。検証 wf_2cd7cd9d-c45 で実証=説明文付き EMPTY が converged 扱いされた)。よって
    // 「実際の diff 内容を含むか」= 'diff --git' マーカーの有無で頑健に判定する(git diff の非空出力は必ず
    // 'diff --git' を含み、説明文や EMPTY_DIFF 応答には現れない=説明文を前置されても誤判定しない・fail-closed)。
    const snapOk = !!(snap && snap.includes('diff --git'))
    if (snapOk) {
      roundDiff = snap
    } else if (canAutoFix) {
      // loop mode は新鮮な diff(autoFix amend 後の差分)に依存する。取得不能=scope 固定不能=異常。
      snapshotFailed = true
    } else if (!staticDiffProvided) {
      // un-2yy: single モード(autoFix off)でも、静的 diff 未指定 + snapshot=EMPTY_DIFF はレビュー対象不在。
      // 従来は roundDiff='' へ縮退 → reviewers が「diff 未供給」フォールバックで findings:[] → false converged。
      // これを「真に clean」と区別するため snapshotFailed=true でマークし、後段の収束判定が converged を否定して
      // escalate へ倒す(レビュー対象が無い ≠ クリーン)。呼出元が diff を供給する場合(staticDiffProvided)は対象外。
      snapshotFailed = true
    }
    // single モード + staticDiffProvided の EMPTY_DIFF は従来通り(呼出元が roundDiff 供給済=対象あり)で変えない。
  }
  lastDiff = roundDiff

  // un-2yy: single モードでレビュー対象が確定的に不在(snapshot=EMPTY_DIFF かつ静的 diff 未供給)なら、
  // review/verify を一切起動せず即 escalate へ短絡する。理由: 対象なしで 4 観点 review を回すのは無駄(最小コスト)
  // かつ roundDiff='' の「diff 未供給」フォールバックは reviewer(read-only agent)を worktree/anchor へ彷徨わせ off-target
  // findings を生む(設計核(2)の scope 固定=anchor ドリフト防止に反する)。machinery 失敗の history を 1 件残して
  // loop を抜け、後段の single 収束判定が converged を否定し escalate を立てる。loop モード(canAutoFix)は
  // 新鮮 diff 依存で再試行に賭けるため短絡しない(従来通り次ラウンドへ)。
  if (snapshotFailed && !canAutoFix && !staticDiffProvided) {
    history.push({
      round,
      total: 0,
      confirmedBlocking: 0,
      confirmedMinor: 0,
      refuted: 0,
      unverified: 0,
      reviewFailed: 0,
      snapshotFailed: true,
    })
    log(`round ${round}: snapshot=EMPTY_DIFF(レビュー対象不在) → review を起動せず escalate(un-2yy 最小コスト)`)
    break
  }

  // perspective-diverse review(並列) → 各 finding を独立に refute-verify(pipeline; barrier 無し)
  // F1/F2/F3: agent() は skip/terminal death では null を返すが、schema 検証枯渇/stall では throw しうる。
  // throw を放置すると pipeline/parallel が要素を null 化し filter(Boolean) が握り潰す(痕跡ゼロの silent 縮退)。
  // → review/verify の両方に .catch を付け、失敗を「観測可能な値」へ正規化する:
  //   - review throw → {findings:[], __reviewFailed:true}(null 返却と合わせて「観点欠落」として集計)
  //   - verify throw → {...f, verdict:null}(unverified に乗せ、本物 blocking の消滅を防ぎ unvNote を立てる)
  const perDim = await pipeline(
    dimensions,
    (d) =>
      runAgent(reviewPrompt(d, round, roundDiff), {
        label: `review:${d.key} r${round}`,
        phase: 'Review',
        model: reviewModel, // 既定=MODEL(opus)。fable 指定時のみ runAgent が ≤2 cap を適用。runAgent 内 roAgent が RO agentType 注入 + fallback
        schema: FINDINGS_SCHEMA,
      }).catch(() => ({ findings: [], __reviewFailed: true })),
    (review, d) => {
      // review が null(skip/枯渇)/__reviewFailed(throw)のいずれも「観点が実行できなかった」=痕跡を残す。
      const reviewFailed = !review || review.__reviewFailed === true
      const findings = (review && review.findings) || []
      return parallel(
        findings.map((f) => () =>
          runAgent(verifyPrompt(f, d.key, roundDiff), {
            label: `verify:${d.key}:${shortTitle(f)} r${round}`,
            phase: 'Verify',
            model: verifyModel, // 既定=MODEL(opus)。fable 指定時のみ runAgent が ≤2 cap を適用。runAgent 内 roAgent が RO agentType 注入 + fallback
            schema: VERDICT_SCHEMA,
          })
            .then((v) => ({ ...f, dimension: d.key, verdict: v }))
            .catch(() => ({ ...f, dimension: d.key, verdict: null }))
        )
      ).then((verifiedArr) => ({ dimension: d.key, reviewFailed, verified: verifiedArr.filter(Boolean) }))
    }
  )

  // pipeline 要素が万一 null(stage2 自体の脱落)でも観点欠落として扱う(no-op-without-trace を作らない)。
  const dimResults = perDim.map((r, i) =>
    r || { dimension: (dimensions[i] && dimensions[i].key) || `dim${i}`, reviewFailed: true, verified: [] }
  )
  const reviewFailedCount = dimResults.filter((r) => r.reviewFailed).length
  const verified = dimResults.flatMap((r) => r.verified || []).filter(Boolean)
  const confirmed = verified.filter((f) => f.verdict && f.verdict.refuted === false)
  const refuted = verified.filter((f) => f.verdict && f.verdict.refuted === true)
  const unverified = verified.filter((f) => !f.verdict) // verdict 取得失敗/throw = 鵜呑みにせず別枠で返す
  const blocking = confirmed.filter(isBlocking)
  const minor = confirmed.filter(isMinor)
  // machinery(review fan-out / snapshot)が silent 失敗した round は「真に clean」と区別する=この round の
  // blocking=0 を信頼しない(false converged 防止。un-bs0「未収束は silent ship せず escalate」の不変条件)。
  const machineryFailed = reviewFailedCount > 0 || snapshotFailed

  allMinor.push(...minor)
  allRefuted.push(...refuted)
  allUnverified.push(...unverified)
  history.push({
    round,
    total: verified.length,
    confirmedBlocking: blocking.length,
    confirmedMinor: minor.length,
    refuted: refuted.length,
    unverified: unverified.length,
    reviewFailed: reviewFailedCount, // 実行できなかった観点数(0=健全)
    snapshotFailed, // loop mode で diff 取得不能だったか
  })
  log(
    `round ${round}: blocking=${blocking.length} minor=${minor.length} refuted=${refuted.length} unverified=${unverified.length} reviewFailed=${reviewFailedCount} snapshotFailed=${snapshotFailed}`
  )

  if (blocking.length === 0 && !machineryFailed) {
    // 真にクリーンなラウンド(blocking=0 かつ machinery 健全)。critical/major 2 連続ゼロで収束(un-bs0 Q3)。
    zeroStreak++
    if (zeroStreak >= 2) {
      converged = true
      break
    }
    if (!canAutoFix || LIGHT_TYPES.has(taskType)) {
      // autoFix off(=呼出元がループを駆動)/ light type は同一 diff の再 review を回さず break。
      // single モード: この 1 ラウンドがクリーンなら下流で converged を立てる。
      break
    }
    // autoFix on + streak 1: 修正対象は無いが、非決定的 review の確証のため次ラウンドで 2 度目のゼロを確認。
    continue
  }

  if (blocking.length === 0 && machineryFailed) {
    // F3/F4: blocking=0 だが review/snapshot machinery が silent 失敗 → この 0 は信頼できない。
    // clean 扱いせず zeroStreak をリセット(連続ゼロを断つ)。fix 対象も無い。
    zeroStreak = 0
    if (!canAutoFix || LIGHT_TYPES.has(taskType)) {
      // single/light: 失敗を surface して返す(下流の single 収束判定が machinery 失敗で converged を否定)。
      break
    }
    // loop mode: flaky な agent の再試行に賭けて次ラウンドへ。真にクリーンな round を確保できないまま
    // cap 到達すれば後段で escalate(silent ship させない)。
    continue
  }

  // blocking あり
  zeroStreak = 0
  allBlocking.push(...blocking)

  if (!canAutoFix) {
    // 自動修正できない(共有既定 off / self-test gate 無し)→ confirmed を呼出元へ返す(single モード)。
    break
  }

  // gated autoFix: confirmed blocking のみ + self-test fail-closed + amend
  phase('Fix')
  const fix = await agent(fixPrompt(blocking, roundDiff), {
    label: `autofix r${round}`,
    phase: 'Fix',
    model: stageModel, // 編集するので roAgent(read-only agentType)を使わず agent() 直呼び(全ツール)
    schema: FIX_SCHEMA,
  })
  if (!fix) {
    escalate = true
    escalateReason = `round ${round}: autoFix agent 失敗/skip`
    break
  }
  if (fix.selfTestPassed !== true) {
    // fail-closed: self-test が pass でなければ即停止 + escalate(silent ship させない)
    escalate = true
    escalateReason = `round ${round}: self-test 失敗/未実行(fail-closed): ${fix.summary || ''}`
    break
  }
  log(`round ${round}: autoFix 適用 ${fix.applied ? fix.applied.length : 0} 件 (self-test PASS${fix.amended ? ', amended' : ''})`)
  // 次ラウンド頭で snapshot し直すので diff の手当ては不要
}

// ── 収束/escalate 判定の確定 ──────────────────────────────────────────────────
const lastH = history[history.length - 1] || {}
if (canAutoFix && !LIGHT_TYPES.has(taskType)) {
  // loop モード: zeroStreak>=2 で converged 済み。未達 & cap 到達なら escalate(silent ship 禁止)。
  // F3/F4: machinery 失敗で真にクリーンな round を確保できなかった場合も同じく escalate へ倒す。
  if (!converged && !escalate && round >= effectiveCap && zeroStreak < 2) {
    escalate = true
    // un-2f1: snapshot 空が全 round で続いた = Implement/Fix が round1 で commit し `git diff HEAD` が空になった
    // 可能性が高い(snapshot は base...HEAD 合成へ移行済だが、base 推定が外れる/commit が base より前等の縁では
    // なお空になりうる)。escalateReason に「snapshot 空=commit 済の可能性」ヒントを含め、既知 artifact かどうかを
    // 呼出元が見分けられるようにする(un-x3o/un-iur の false-escalate の見分け)。
    const allSnapFailed = history.length > 0 && history.every((h) => h.snapshotFailed)
    const why =
      lastH.reviewFailed || lastH.snapshotFailed
        ? `review/snapshot machinery 失敗(reviewFailed=${lastH.reviewFailed || 0}, snapshotFailed=${!!lastH.snapshotFailed})で真にクリーンな round を確保できず` +
          (allSnapFailed
            ? `。全 round で snapshot 空=実装/修正が既に commit 済の可能性が高い(base...HEAD 合成でも空=base 推定要確認・既知 artifact かを findings 直読で判断)`
            : !!lastH.snapshotFailed
              ? `。snapshot 空=commit 済 or レビュー対象不在の可能性`
              : '')
        : `critical/major が 2 連続ゼロに至らず`
    escalateReason = escalateReason || `hard cap ${effectiveCap} 到達・未収束(${why})`
  }
} else {
  // single モード(autoFix off / light): この 1 ラウンドが真にクリーン(blocking=0 かつ machinery 健全)なら converged。
  // machinery が silent 失敗していたら blocking=0 でも converged を立てない(false converged 防止)。
  converged = lastH.confirmedBlocking === 0 && !lastH.reviewFailed && !lastH.snapshotFailed
  // un-2yy: single モードで blocking=0 だが machinery 失敗(snapshot=EMPTY_DIFF/review 脱落)した場合は
  // converged でないだけでなく escalate へ倒す。OPEN(=呼出元が confirmed を修正して再 invoke)は「直すべき
  // finding がある」状態を指すが、レビュー対象不在(EMPTY_DIFF)は「直す対象が無い」=setup/machinery の異常で
  // あって fix-and-retry では解けない。clean と区別して人手判断へ送る(レビュー対象不在 ≠ clean)。
  if (!converged && !escalate && lastH.confirmedBlocking === 0 && (lastH.reviewFailed || lastH.snapshotFailed)) {
    escalate = true
    escalateReason =
      escalateReason ||
      `single モード: blocking=0 だが machinery 失敗(reviewFailed=${lastH.reviewFailed || 0}, snapshotFailed=${!!lastH.snapshotFailed})。` +
        (lastH.snapshotFailed
          ? `snapshot=EMPTY_DIFF=レビュー対象不在(${staticDiffProvided ? 'diff 供給済' : 'diff 未供給'})。空 diff は実装が既に commit 済の可能性(git diff HEAD が空)= un-2f1 参照。clean と区別し人手確認。`
          : 'review が実行できず真にクリーンな round を確保できず。')
  }
}

// ── (10) self-test final(sc-jx8): 終了時に selfTestCmd を再実行し「最終 green/red」を記録 ──────
// autoFix loop 完了後(amend 反映後)の状態。baseline との差分で loop が self-test 状態を変えたかを gate が読める。
// 情報ログ専用=converged/escalate を駆動しない(B4)。escalate/converged は上の判定で確定済み(不変)。
const selfTestFinal = await runSelfTest('final')
if (selfTestFinal.skipped) {
  log('self-test final: skip(selfTestCmd 未指定=fail-open)')
} else {
  log(`self-test final: ran=${selfTestFinal.ran} passed=${selfTestFinal.passed}${selfTestFinal.error ? ' (runner agent 失敗)' : ''}`)
}

// ── 返り値: 呼出元(worker/admin)が一次監査する。verdict を鵜呑みにしない ──────────
const result = {
  taskTitle,
  taskType,
  verifyStrategy,
  mode: canAutoFix && !LIGHT_TYPES.has(taskType) ? 'loop' : 'single',
  converged,
  escalate,
  escalateReason,
  rounds: round,
  maxRounds: effectiveCap,
  autoFix: canAutoFix,
  reviewModel, // per-stage model(既定=MODEL)。監査用に明示
  verifyModel,
  fableCapped: isFable(reviewModel) || isFable(verifyModel), // fable ≤2 cap が効いた経路か
  maxConcurrency, // (D2) opus 経路 cap(0=無 cap=harness 任せ)。監査用
  opusCapped: maxConcurrency > 0, // (D2) opus limiter が effective だった経路か
  // 監査対象: confirmed blocking は verdict ごと直読して妥当性を確認(過剰却下/誤検出を自分で判断)
  blocking: allBlocking,
  minor: allMinor, // 記録のみ
  refuted: allRefuted, // 誤検出として落とした finding(本当に無効か逆監査・全ラウンド累積)
  unverified: allUnverified, // verdict 取得失敗 = 人手確認(全ラウンド累積)
  history,
  diff: lastDiff,
  machineryFailedLastRound: !!(lastH.reviewFailed || lastH.snapshotFailed), // F3/F4: review/snapshot silent 失敗の有無
  // (10) sc-jx8: selfTestCmd 常時実行の baseline(実装前)/final(終了時)。各 {ran, skipped, passed, exitCode, rawLog}。
  // gate/orchestrator が actor 報告に依存せず self-test 状態を直読する。情報ログ専用(escalate/converged を駆動しない)。
  selfTestBaseline,
  selfTestFinal,
  receivedArgs, // un-2yy: 何が届いたか(キー一覧 + 受信型 + 生の受信型)を呼出元監査用に明示
}

// admin 薄 gate の指針(再 review はしない)。unverified(verdict 取得失敗/throw)や machinery 失敗が
// あれば converged でも人手確認が要る = silent ship させない注記を必ず付ける。
const unvNote = allUnverified.length ? ` ※unverified=${allUnverified.length} は要人手確認(verdict 鵜呑み禁止)。` : ''
const machNote =
  lastH.reviewFailed || lastH.snapshotFailed
    ? ` ※machinery 失敗(reviewFailed=${lastH.reviewFailed || 0}, snapshotFailed=${!!lastH.snapshotFailed})= この round の blocking=0 は信頼不可、人手確認。`
    : ''
result.gate = escalate
  ? 'ESCALATE: 未収束/self-test 失敗/machinery 失敗。silent ship 禁止 — 人間が判断すること。' + unvNote + machNote
  : converged
    ? 'CONVERGED: 収束。outward/risk(boot-path/全ホスト/破壊的)があれば merge 前に人間 ratify。' + unvNote + machNote
    : 'OPEN: 呼出元が confirmed を修正し再 invoke(single モードのループ駆動)。' + unvNote + machNote

log(`cell-quality done: ${result.gate}`)
return result

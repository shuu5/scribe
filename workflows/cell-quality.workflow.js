export const meta = {
  name: 'cell-quality',
  description:
    '1 issue = 1 実装セルの品質WF: task-type routing → [Plan] → [Implement] → perspective-diverse な Opus review → 各 finding を独立 Opus が adversarial refute-verify → gated autoFix(confirmed のみ+self-test fail-closed+amend) → loop-until-dry 収束。返り値を呼出元(worker/admin)が一次監査する薄 gate 設計。固有物は args で差し込む(骨格は再利用)。',
  whenToUse:
    'worker worktree で substantive な per-issue 実装の品質を担保したいとき。固有物(taskTitle/worktree/goal/acceptance/diff/baseRef/contextFile/selfTestCmd/dimensions/model/maxRounds/autoFix/doPlan/doImplement/taskType/target/context/probe/roAgentType/snapshotInlineLimitBytes)は args で渡す。★args は Workflow tool 経路で【全体約 4KB】に切り詰められる実測がある(un-cw0z)ため inline を小さく保つこと: 大きい diff は baseRef(commit 済差分を snapshot 合成が worktree で直接取得=インライン転記不要)、大きい文脈は contextFile(readable な path を渡し各段 agent が Read)で渡す。autoFix は既定 off(共有 fail-safe)、worker cell 文脈は autoFix:true を渡す。roAgentType は read-only 段の agentType 上書き escape hatch(既定 scribe:explore・"none" で agentType 無し強制)。★worktree は【必須】= 欠落/空/undefined/"[undefined]" は agent を 1 体も起動せず throw して run を殺す(sc-pfn4 の canonical args 契約。read-only の軽量用途=diff 供給 + doImplement/autoFix なし でも同じ=diff だけ渡す ad-hoc 直叩きは通らない)。sentinel "(current worktree)" も worker-cell 実行では別 prefix で throw する。',
  // (sc-pfn4) 必須 args の【静的】宣言。body の const REQUIRED_ARGS と同一集合であること(engine の二面宣言
  // 要求。片面/不一致は rc=2 DECL_MISMATCH)。集合は body 側の宣言コメントに理由を書く(ここは mirror)。
  requiredArgs: ['worktree'],
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
//      → admin は薄 gate(merge 権限 + 収束証跡確認 + 3 クラス該当判定)のみ、再 review しない。
//      承認体制の裁定(bd sc-tx8s / 裁定 SSOT = bd orch-vhiu)により、人間確認の【発火条件】だけが
//      旧カテゴリ判定から「3 クラス該当時のみ」へ縮小した(admin の責務は減っていない=列挙は 3 項のまま)。
//      以下は裁定本文の canonical 3-クラス block v2 の verbatim 転記(言い換え禁止・reflow/行結合/箇条書き
//      記号の付加も禁止・本 repo の実行時 carrier で唯一の設置箇所。配布 template 側の carrier は
//      skills/setup/PRIME.template.md)。※搬送の byte 同一性は「各行から定数接頭辞 `//      │ `(空行は末尾
//      スペース無し)を除いた結果の sha256 が正本 18 行と一致する」ことで定義され、teeth =
//      tests/cell-quality-verdict.bats の CANON_SHA256 pin(sc-8ak7)。長い行は折り返さず 1 行で保持する。
//      ※実行時 carrier(result.gate 文字列 / bd notes / 報告)では裸の (a)/(b)/(c) を使わず
//      「3 クラス(消す/出す/使う)」と語で書く(protocol §5.4 の park トリガ記号と衝突するため。
//      §5.4 の park トリガを指す場合だけは「protocol §5.4(c)」と修飾付きで書く=裸参照ではない)。
//      ※【発火条件の縮小は 3 クラス軸に限る】: protocol §5.4(c)「acceptance snapshot mismatch =
//      auto-merge 資格剥奪 → 人間 ratify 昇格」は 3 クラス分類と直交する独立の機械 fail-closed トリガ
//      (契約が dispatch 後にすり替わった検知)であり、本裁定では廃止も縮小もされていない。ゆえに
//      CONVERGED 文字列の排他(「のみ」)は 3 クラス軸内の排他であって §5.4(c) を打ち消さない=
//      carve-out を必ず併記する(欠かすと契約すり替え cell が auto-merge へ fail-open する)。
//      ┌──── canonical 3-クラス block v2(verbatim・言い換え禁止/reflow・行結合・記号付加も禁止) ────
//      │ 【人間確認が要るのは「取り消せない」3 クラスのみ】
//      │ (a) 消す — データ / repo / 履歴 / live 成果物の破壊（第一防衛線は機械 guard 層）
//      │ (b) 出す — public 化・外部公開・外部サービスへの送信（scriptorium 核② private 保証はこの型）。判定単位は repo でなく「情報」＝public 面の情報集合を増やすかで判定する。private 配備層から public engine への同期のような境界事案は機械 2 条件〔① 配備層 file を touch しない ② private 実名 DATA literal が 0 hit〕が両方 green なら非該当（AI 判断で merge）・どちらかが赤 or 機械照合できないなら (b) として人間確認へ倒す fail-safe。「既に public な repo だから非該当」という repo 単位の断定は禁止（public repo の中に private 由来の同期先が在りうる＝実例 scribe 内 scriptorium-engine）。〔裁定 R-A・2026-07-26〕
//      │ (c) 使う — 追加課金が発生する操作（従量課金 API 呼出 / 有料サービスの新規契約 / クラウド資源の課金発生）。定額プラン内は対象外＝token 消費それ自体は非該当（Workflow を何 M token 回しても (c) に当たらない）。旧文言「大きな金銭コスト（承認でなく予算上限で制御）」は観測できず死文化するため廃止した。〔裁定 R-B・2026-07-26〕
//      │
//      │ それ以外（規約ファイル・全ホスト配布物・事前合意逸脱を含む）は AI 敵対 gate 通過をもって AI 判断で merge する。
//      │
//      │ 【聞かないこと】順序・選択肢の是認だけを求める問いは出さない（AI が推奨を出し、決めて進む）。
//      │ 【上げること】複数の妥当な設計が併存し、選択が人間の目的・価値観に依存するとき＝承認要求ではなく grill 提案として上げる。事実で決まるなら止めない。
//      │
//      │ 【本裁定で緩めないもの（fence）】
//      │ AI 敵対 gate / write-isolation（foreign 台帳 write 禁止）/ 完了 truth=bd（終端宣言）/ 破壊操作の機械 guard / 核② private 保証（orch-ufz・orch-xkec boundary）/ gate 分離（worker は自己 merge しない・gate-pending funnel）/ 承認要求の可視性様式（🔴 バナー・AskUserQuestion 最優先・安売り禁止）
//      │ ※様式は存続。変わるのは発火条件（④ 該当 → 3 クラス該当）だけ。
//      │
//      │ 【必ず添える 3 つの誤読防止句】
//      │ 1. 人間承認を外しても gate は外さない（gate が実効安全弁になったので強化側）。
//      │ 2. 「worker が自己 merge してよい」ではない（gate 分離＝独立レビューは不変）。
//      │ 3. front-load / バナーは廃止でなく scope 縮小（user 裁定 2026-07-17 の可視性要件を壊さない）。
//      └────────────────────────────────────────────
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
//  (7) args fail-fast(un-8c4 吸収 → sc-pfn4 で throw 形へ cutover): 必須 args(worktree)は canonical block が
//      【無条件】に見て欠落なら即 throw する = 読み取り専用の軽量用途(diff 供給 + single モード)も worktree
//      必須になった(「diff だけ渡す ad-hoc 直叩き経路」を殺す仕様変更)。worker-cell 固有の契約
//      (goal/acceptance のいずれか・autoFix 時 selfTestCmd・sentinel '(current worktree)' 拒否)は block の
//      【外】で意味的に fail-fast し、canonical marker を含まない別 prefix で throw する。いずれも agent を
//      一切起動しない。旧 escalate=true return 形は「undefined を掴んだまま完走」を止められず廃止(P0-2)。
//  (8) defensive args parse(un-2yy 吸収 → sc-pfn4 で canonical block へ移管): args の string/object は
//      呼び出し側 serialization 依存で非決定的(object 到達もあれば JSON 文字列化して届くこともある)。block が
//      typeof args==='string' なら JSON.parse して吸収し、parse 失敗(壊れた JSON 等)は scope/契約が一切不明=
//      agent を一切起動せず throw する。block は receivedArgs 要約(受信型 + キー一覧 + 各キーの型)も組み立て、
//      呼出元が「何が届いたか」を一次監査できるようにする(非決定的 serialization の可視化)。WF 固有の監査
//      field(roAgentType)は block を 1 byte も汚さないよう block の後で property 代入する。
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
// (11) per-stage effort(sc-94z・SSOT=sc-npa 論点5): sc-dc9 の「全 agent へ args.effort を一律 pin」を段別へ
//      分化した。背骨原理『強度は gate 捕捉性 × confab でスケール』(methodology §1.1)の WF 内対応物=guard 段
//      (Review/Verify/Fix)は cell effort の一括下げから構造独立に high 固定・mechanical guard 段(Self-test/
//      Classify/Snapshot)は medium 固定・実装系(Plan/Implement)のみ再定義された args.effort(=cell effort)に
//      従う。露出 knob は reviewEffort/verifyEffort の 2 つのみ(guard を xhigh へ opt-in)。effort 検証は
//      sc-dc9 の EFFORT_ALLOWED(sc-ax4 SSOT mirror)を resolveEffort 経由で再利用し新検証路を作らない。
//      返り値 effort は per-stage 要約 object{cell,review,verify,fix,classify,selfTest,snapshot}=呼出元が
//      「guard 段が high に留まったか」を一次監査できる(receivedArgs/schemaHealth と対称の audit 面)。
// (12) args 約 4KB 上限とファイル渡し(sc-mbcm・orch-v7pf=un-cw0z 中継の吸収): Workflow tool へ渡す args は
//      【全体で約 4KB】に切り詰められる実測がある(uns un-cw0z)。切り詰めは骨格からは検知できない
//      (途中で切れた JSON は (8) の canonical block が [SCARGS fail-fast] で throw して run を殺すのが唯一の
//      観測面で、有効 JSON のままフィールドが欠ける形は silent)。よって呼出元が inline args を小さく保つのが一次対策で、大きな
//      供給物は参照渡しにする: 大きい diff → baseRef((9) の snapshot 合成が worktree で直接取得)/
//      大きい文脈(goal・acceptance の詳細・review 前提資料) → contextFile(readable な path)。
//      contextFile は ctxBlock 経由で classify/plan/implement/review/fix の各 prompt へ「まず Read せよ」
//      指示として注入する(WF script は fs 非アクセスゆえ prompt-level indirection が正しい形。agent が
//      実バイトを Read するため模型経由の再転記で内容が劣化しない)。verify prompt へは注入しない
//      (独立反証者は finding + diff だけを見る独立性設計を維持)。path は baseRef と同じ安全文字クラスのみ
//      許可し不正値は '' へ倒す(空白入り path は非対応=呼出元が安全な path を選ぶ)。
// ─────────────────────────────────────────────────────────────────────────────

// ── (sc-pfn4) args 受け取り規律: canonical preamble の verbatim 複製 ──────────────────────────────
// 本 WF の必須 args【動的】宣言。meta の同名 field と同一集合であること(engine が二面宣言 + 集合一致を要求し、
// 片面/不一致は rc=2 DECL_MISMATCH)。集合を worktree 1 本に絞る理由:
//   - worktree: scope そのもの。欠けたまま走ると「どの木を読むか」が不定で全段が無意味になる(un-8c4)。
//     ここで【無条件】必須にすることで「diff だけ渡す ad-hoc 直叩き経路」を殺す(P0-2 の throw 形 fail-fast)。
//   - taskTitle は既定値を持つ非致命 arg ゆえ含めない。
//   - goal / acceptance は「いずれか」要件で平坦な AND では表現不能・selfTestCmd は autoFix 時のみ必須ゆえ、
//     どちらも block の【外】で意味的 fail-fast する(下記 isWorkerCell ゲート・canonical marker を含まない別 prefix)。
const REQUIRED_ARGS = ['worktree']

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

// ↑ ここまでが canonical block の verbatim 複製(workflows/lib/args-preamble.snippet.js が SSOT)。1 byte でも
// 変えると engine が SNIPPET_BLOCK_DRIFT で落ちる。block 内へ WF 固有の field を足さない(足すなら block の後で
// property 代入する = 下記 receivedArgs.roAgentType)。

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
// (sc-pfn4) canonical block は全 WF で byte 一致でなければならない = WF 固有の監査 field は block の【後】で
// property 代入して足す。roAgentType(解決した read-only agentType)は呼出元の一次監査面ゆえ receivedArgs に載せる
// (block 内へ field を足すと SNIPPET_BLOCK_DRIFT・落とすと roAgentType の監査面が消える)。
receivedArgs.roAgentType = RO_AGENT_TYPE
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
// (sc-k33c ERRATA-01 B1) 本関数は「1 論理 agent = 実呼出し 1〜2 回」の唯一の発生源(not-found 検知時に
// agentType 無しで 2 度目を呼ぶ)。cap の計上を実呼出しへ合わせるため、**全 return path** で capCountCall()
// を通す(判定ロジック自体は SCCAP ブロック内=ここは薄い計上フックのみ)。併せて解決状態が確定した時点で
// capMarkRoResolved() を呼び、以降の予約コストを 1 本へ戻す(未確定の間は 2 本を保守的に予約している)。
async function roAgent(prompt, opts) {
  const base = { ...(opts || {}) }
  delete base.agentType // agentType の管理は roAgent に一元化(呼出サイトは指定しない)
  const label = (opts && opts.label) || 'ro-agent'
  if (roFallbackActive) {
    capMarkRoResolved()
    capCountCall(label)
    return agent(prompt + RO_DISCIPLINE, base)
  }
  try {
    capCountCall(label)
    const r = await agent(prompt, { ...base, agentType: RO_AGENT_TYPE })
    capMarkRoResolved() // agentType が解決した = 以降 1 論理 agent は実呼出し 1 回で足りる
    return r
  } catch (e) {
    if (isAgentTypeNotFound(e)) {
      roFallbackActive = true
      capMarkRoResolved() // 降格が確定 = 以降は最初から agentType 無し(実呼出し 1 回)
      log(`[RO-FALLBACK] read-only agentType '${RO_AGENT_TYPE}' が registry で解決不能(${e && e.message ? String(e.message).slice(0, 120) : 'not found'})。agentType 省略へ後退し read-only 規律を prompt で代替する。以降の read-only 段も降格(scribe plugin 未ロード session / registry drift の可能性=merge 後の fresh session で解消)。`)
      capCountCall(label) // fallback の 2 度目の実呼出し(旧実装が取りこぼしていた 1 本)
      return agent(prompt + RO_DISCIPLINE, base)
    }
    throw e // not found 以外は透過(既存 .catch 意味論を保つ)
  }
}

//SCJ32_BLOCK_START
// ── (sc-j32) schema 強制 agent の placeholder 最終値化 / null 死ガード ──── [self-test anchor: sc-j32:schema-guard]
// dynamic WF の schema 付き agent は StructuredOutput(構造化出力)を「作業完了後に一度だけ・実データで」呼ぶべき
// だが、実発(wf_c2cd03d4)で 2 故障を観測した: (a) 試し打ちの placeholder(summary=test 等)が **初回呼出しで
// 最終値化**(StructuredOutput は初回が確定し上書き不能)、(b) schema 検証 retry 上限(5)超過で **null 死**。対策:
//  (1) 全 schema prompt に SCHEMA_DISCIPLINE を前置(試し打ち禁止・完了後に一度だけ・実データで)。
//  (2) 骨格側で degenerate(placeholder 形状)を検知して既存の失敗経路(null 相当)へ倒す=fail-closed。
//  (3) null(retry 超過)/degenerate を success 扱いせず schemaHealth へ記録し返り値へ載せる(receivedArgs と対称)。
const SCHEMA_DISCIPLINE =
  '\n\n## StructuredOutput 規律（厳守・sc-j32）\n' +
  'この応答は schema で構造化出力(StructuredOutput)を強制される。StructuredOutput ツールは **作業を完了し実データが' +
  '揃ってから一度だけ** 呼ぶこと。試し打ち・動作確認・placeholder(例: summary="test"・空/仮の配列で仮確定)で' +
  '呼んではならない。**初回の呼出しが最終値として確定し後から上書きできない** ため、値が確定するまで呼ばないこと。'

// placeholder 文字列の検知(試し打ちの典型値 or 空文字)。substantive であるべき string フィールドに使う。
// (sc-j32 errata) 長さヒューリスティック(旧 `t.length < 2`)は撤去した — 'x'/'r' のような terse だが正当な実データ
// を『試し打ち』と誤断定し、正当な finding を degenerate 化して検証経路ごと落とす false-positive を招いた(既存
// fallback 回帰テストを RED 化)。退化とみなすのは trim 後の空文字か既知 placeholder 語のみ(短さでは落とさない)。
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
// findings は「空(=clean)」を degenerate にしない=非空かつ全 finding が placeholder のときだけ試し打ちと見なす。
const __findingIsPlaceholder = (f) =>
  f && isPlaceholderStr(f.rationale) && (isPlaceholderStr(f.title) || isPlaceholderStr(f.location))
const degClassify = (r) => isPlaceholderStr(r && r.rationale) // taskType は enum 制約ゆえ rationale で見る
const degPlan = (r) => isPlaceholderStr(r && r.acceptance)
const degFindings = (r) =>
  Array.isArray(r && r.findings) && r.findings.length > 0 && r.findings.every(__findingIsPlaceholder)
const degVerdict = (r) => isPlaceholderStr(r && r.reasoning)
const degFix = (r) => isPlaceholderStr(r && r.summary)

// schemaAgent: schema 付き agent 呼出しの共通ラッパ。
//  - prompt に SCHEMA_DISCIPLINE を前置。
//  - runner(roAgent/runAgent/agent)を await。null(retry 超過=StructuredOutput 未確定)は握り潰さず
//    schemaHealth.nullDeaths へ記録し null を返す(呼出元の既存 null 失敗経路を温存)。
//  - degenerate(placeholder 形状)検知時は schemaHealth.degenerate へ記録し null を返す(既存の失敗経路
//    =fail-closed へ倒す=placeholder を最終値として下流に流さない)。
//  - throw はそのまま透過(呼出元の既存 .catch 失敗正規化=不変条件(5)を壊さない)。
// 返り値型を「有効な schema オブジェクト or null」に保つため、各呼出サイトの `x && x.field` / `if (!x)` /
// `.then(v => ...)` 分岐を一切変えずに null/degenerate が既存の失敗網へ合流する。
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
// (12) contextFile: 大文脈のファイル渡し経路(sc-mbcm・args 全体約 4KB 切り詰めの回避路)。prompt へ path として
// 埋め込むため baseRef と同じ安全文字クラスのみ許可し、不正値(空白/引用符/バッククォート等)は '' へ倒す=
// 未供給と同義(graceful・呼出元は returnedArgs のキー一覧と prompt 注入の有無で一次監査できる)。
const _rawContextFile = (typeof A.contextFile === 'string' && A.contextFile.trim()) || ''
const contextFile = /^[A-Za-z0-9._/~^@{}-]+$/.test(_rawContextFile) ? _rawContextFile : ''
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
// ── per-stage effort 統制(sc-dc9 起源・sc-94z で per-stage 分化): 段ごとに effort を分けて pin する。────
// 目的(sc-dc9): machine-global settings.json の "effortLevel":"xhigh" が dynamic WF の全 agent へ無差別波及
// するのを断つ(worker の xhigh 幻覚事例の根治=doobidoo 1e98254c)。opts.effort は Workflow tool が受理する
// (admin 実証済み)。roAgent/runAgent は opts を透過するため(base={...opts}, delete は agentType のみ)効く。
// per-stage 分化(sc-94z・SSOT=sc-npa 論点5): 従来の「全 agent へ args.effort を一律 pin」を、背骨原理
// 『強度は gate 捕捉性 × confab リスクでスケール』(methodology §1.1)に沿って段別へ分ける。段の割当:
//   - Review/Verify/Fix = guard 段(WF 内の gate その物)= 但し書き(1) の WF 内対応物ゆえ **high 固定**。
//     args.effort(cell effort)の一括下げから【構造的に独立】(cell effort を下げても guard は下がらない)。
//     xhigh 化は reviewEffort/verifyEffort の個別 opt-in knob(reviewModel/verifyModel と同じ流儀)。Fix は
//     knob を持たず high 固定(論点5①: 露出 knob は reviewEffort/verifyEffort の 2 つに絞る)。
//   - Self-test/Classify/Snapshot = **medium 固定**。self-test は guard 連鎖の一部ゆえ low でなく medium 止まり
//     (論点5②)。classify は誤分類が劣化止まり=gate 捕捉圏内ゆえ medium(③)。snapshot は契約(sc-94z)が段区分を
//     明示しないが、self-test と同じ mechanical な read-only(git diff 収集)で、その失敗は snapshotFailed 網が
//     gate で拾う(不変条件(5))ゆえ model litmus『純 read-only 探索』(methodology §1.1)で self-test と同区分に
//     グルーピングし medium とする(sc-94z 実装判断・契約が明示せぬ段の解釈)。
//   - Plan/Implement = **cell effort に従う**(args.effort を「実装系の段だけに効く cell effort」へ再定義・④)。
// allowlist(low|medium|high|xhigh|max)外・未設定は既定へ **fail-safe**(warn log)= 壊れた args でも WF を止めず
// 安全側へ倒す(scribe-spawn.sh の allowlist は spawn 時に fail-loud で弾くが、WF 直叩き経路の防御として二重化)。
// SSOT-MIRROR(sc-ax4): この集合は bash 側 SSOT `SCRIBE_EFFORT_ALLOWLIST`(scripts/lib/scribe-lib.sh)の
// mirror。WF sandbox は実行時に lib を source 不可(filesystem 非公開)ゆえ literal で複製する。両者の
// drift は tests/effort-allowlist-ssot.bats が fail-loud で検知する(CC 新 tier 追加時の同時更新漏れ検知)。
const EFFORT_ALLOWED = new Set(['low', 'medium', 'high', 'xhigh', 'max'])
// effort 解決の単一路(sc-94z consistency (a)=sc-ax4 SSOT 再利用): 全 effort は EFFORT_ALLOWED(=bash 側
// allowlist の mirror)で検証し、allowlist 外・未設定は fallback へ fail-safe する。新 knob 用に別 validator を
// 作らない(検証路を一本化=新検証路の増殖を防ぐ)。fallback を warn log で可視化する(silent に倒さない)。
const resolveEffort = (raw, fallback, label) => {
  const t = typeof raw === 'string' ? raw.trim() : ''
  if (t && !EFFORT_ALLOWED.has(t)) {
    log(`警告: ${label}='${t}' は許可外(low|medium|high|xhigh|max)。既定 ${fallback} へ fail-safe(sc-94z)。`)
  }
  return EFFORT_ALLOWED.has(t) ? t : fallback
}
// cell effort(sc-94z ④): 再定義された args.effort。Plan/Implement(実装系の段)にのみ効く。既定 high。
const CELL_EFFORT = resolveEffort(A.effort, 'high', 'effort')
// guard 段 effort 下限フロア(sc-2wv・sc-94z gate 申し送り): guard 段(Review/Verify)は high 未満へ下げられない
// (但し書き(1)=gate 側を下げない)。従来 resolveEffort(A.reviewEffort,'high') は allowlist 全値を受理し明示指定なら
// guard を low/medium へ下げられる doc/impl 非対称があった。EFFORT_RANK_ORDER(=EFFORT_ALLOWED と同メンバの
// intensity 昇順配列・rank は集合とは別概念)で floor を機械 enforce する。bash 側(scribe-selftest-args)は明示
// フラグゆえ fail-loud die・WF 側は args 直叩き経路の二重防御として fail-safe(floor へ clamp + warn)。allowlist
// SSOT(sc-ax4)自体は不変。SSOT-MIRROR(sc-ax4): EFFORT_RANK_ORDER も bash SCRIBE_EFFORT_ALLOWLIST の順序 mirror で
// effort-allowlist-ssot.bats が順序込みで drift を検知する(cell effort は下げてよいが guard は下げない=段で posture 差)。
const EFFORT_RANK_ORDER = ['low', 'medium', 'high', 'xhigh', 'max']
const GUARD_EFFORT_FLOOR = 'high'
const effortRank = (v) => EFFORT_RANK_ORDER.indexOf(v)
// guard knob 専用 resolver: 共通 resolveEffort(allowlist 検証・fallback high)を通した後、floor(high)未満なら
// fail-safe で floor へ引き上げ warn する(silent に下げない)。fallback=high 経路(allowlist 外)は floor を満たすので
// 追加 warn せず既存 '許可外' warn のみ。resolveEffort の fallback も GUARD_EFFORT_FLOOR で一貫させる。
const resolveGuardEffort = (raw, label) => {
  const r = resolveEffort(raw, GUARD_EFFORT_FLOOR, label)
  if (effortRank(r) < effortRank(GUARD_EFFORT_FLOOR)) {
    log(`警告: ${label}='${r}' は guard 段の下限フロア(${GUARD_EFFORT_FLOOR})未満。floor へ引き上げ(sc-2wv・gate 側を下げない=但し書き(1))。`)
    return GUARD_EFFORT_FLOOR
  }
  return r
}
// guard 段 knob(sc-94z ①): Review/Verify は既定 high 固定・reviewEffort/verifyEffort で xhigh 等へ opt-in する。
// 既定は CELL_EFFORT でなく 'high'(cell effort の一括下げから構造独立=guard を道連れに下げない=但し書き(1))。
// high 未満への下げは floor(sc-2wv)が fail-safe で high へ引き上げる(上げ方向 opt-in のみ)。
const reviewEffort = resolveGuardEffort(A.reviewEffort, 'reviewEffort')
const verifyEffort = resolveGuardEffort(A.verifyEffort, 'verifyEffort')
// 固定 effort 段(sc-94z ①②③): Fix=high 固定(guard・knob 無し)。Classify/Self-test/Snapshot=medium 固定。
const FIX_EFFORT = 'high'
const CLASSIFY_EFFORT = 'medium'
const SELFTEST_EFFORT = 'medium'
const SNAPSHOT_EFFORT = 'medium'
// 返り値監査用の per-stage effort 要約(呼出元/admin が「guard 段が high に留まったか」を返り値から直読する)。
const effortSummary = {
  cell: CELL_EFFORT, // Plan/Implement(実装系の段)
  review: reviewEffort, // 既定 high・reviewEffort knob で opt-in
  verify: verifyEffort, // 既定 high・verifyEffort knob で opt-in
  fix: FIX_EFFORT, // high 固定(guard・knob 無し)
  classify: CLASSIFY_EFFORT, // medium 固定
  selfTest: SELFTEST_EFFORT, // medium 固定
  snapshot: SNAPSHOT_EFFORT, // medium 固定
}
const maxRounds = Number.isInteger(A.maxRounds) && A.maxRounds > 0 ? A.maxRounds : 3 // hard cap
// ── (sc-vtf8) snapshot の inline 上限(bytes)。3 値契約の 3 つ目(DIFF_TOO_LARGE_FOR_INLINE_RETURN)の閾値。──
// 【未指定(0)= 弁別を行わない完全後方互換】: 閾値が無ければ snapshotPrompt に上限節を **焼かない** =
// agent は従来どおり 2 値(生 diff / EMPTY_DIFF)しか返さず、WF の判定も従来と同一の分岐しか踏まない。
// 数値決め打ち禁止(bd sc-vtf8 (d))ゆえ既定値は持たせない = 呼出元が明示した run でだけ弁別が効く。
// 不正値は **fail-fast**(cap args の __capIntArg と同じ posture): 「上限弁別を頼んだのに黙って無弁別で走る」
// silent fail-open は、まさに本 leg が塞ぐ誤分類(非空 143KB diff を EMPTY_DIFF と呼ぶ)を再生産するため。
// maxRounds/maxConcurrency の「不正値は既定へ黙って倒す」流儀を採らないのはこの非対称による(opt-in 弁別 knob)。
const snapshotInlineLimitBytes = (() => {
  const raw = A.snapshotInlineLimitBytes
  if (raw === undefined || raw === null) return 0 // 未指定 = 弁別しない(現状維持)
  if (typeof raw !== 'number' || !Number.isInteger(raw) || raw <= 0) {
    throw new Error(
      `[cell-quality args fail-fast] snapshotInlineLimitBytes は正整数(単位=bytes)で渡すこと。received=${JSON.stringify(raw)}(type=${Array.isArray(raw) ? 'array' : typeof raw})。` +
        ' 不正値を既定へ黙って倒すと「inline 上限の弁別を頼んだのに無弁別で走る」silent fail-open になるため fail-fast する(sc-vtf8)。'
    )
  }
  return raw
})()
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

//SCCAP_BLOCK_START
// ── (sc-k33c) 3 層 cap: 幅(fan-out)の制御。cap の判定コードはこの 1 ブロックに閉じる ────────────────
// 【単位契約(verbatim)】totalBudget の単位は **agent 本数** である(token ではない)。token(budget.spent())は
// 情報ログとしてのみ併走させ、admission の判定には一切使わない(判定=本数 / 情報=token)。turn token budget は
// 呼出元が設定しないと budget.total=null で観測できず、本数なら WF 自身が数えられる=判定面として決定論的。
//
// 層1(args 正規化・L456 隣の maxConcurrency と同じ Number.isInteger イディオム): ただし maxConcurrency の
//   「不正値は既定へ黙って倒す」ではなく **不正値は fail-fast(throw)** にする(silent fallback 禁止=「cap を
//   頼んだのに無 cap で走る」fail-open を作らない)。未指定(undefined/null)だけが「無 cap=現状維持」で、これが
//   cap 機構全体の opt-in 既定(数値既定を変えない fence)。この fail-fast は【全モード】で発火する
//   (isWorkerCell 条件を付けない)。goal/acceptance の「いずれか」要件は従来どおり isWorkerCell ゲート側に残す。
// 層2(admission control 4 点): round 頭 / review 前 / verify 前 / fix 前。snapshot・self-test・classify は
//   **免除**(監査面=落とすと gate が状態を直読できなくなる)。ただし総数保証のため消費は計上する(capAccount)。
//   縮退順は「verify を critical/major に限定 → severity top-K(決定論 tie-break) → loud drop」。
//   effort 降格と dimensions 削減は不採用(裁定済み)。
// 層3(cap 系例外の正規化): 無防備 call site の throw で run が result を返さず消える現状を解消する。
//   判定は name **または** message の指紋(AND 禁止)。指紋は **未実測の保守的な列挙**であって実機文言の実測
//   ではない(実機の cap 例外を観測できていない=K9 留保(5))。どちらにも非一致なら cap ではない=従来の失敗正規化/
//   透過(machinery 失敗)へ倒す fail-closed。
const CAP_SEVERITY_RANK = { critical: 0, major: 1, minor: 2, nit: 3 }
const capIsBlocking = (f) => !!f && (f.severity === 'critical' || f.severity === 'major')
// 落とした対象のうち「blocking 級」= critical/major、および severity 不明(観点丸ごと欠落 / 例外停止)。
// 不明を blocking 級に数えるのは fail-closed(欠落した観点に blocking が無かったと主張できないため)。
const CAP_BLOCKING_DROP_SEVERITIES = new Set(['critical', 'major', 'unknown'])

// ── 層1: 新 args の正規化 + fail-fast ────────────────────────────────────────────
const __capIntArg = (raw, name) => {
  if (raw === undefined || raw === null) return 0 // 未指定 = 無 cap(opt-in 既定=現状維持)
  if (typeof raw !== 'number' || !Number.isInteger(raw) || raw <= 0) {
    throw new Error(
      `[cell-quality cap args fail-fast] ${name} は正整数(単位=agent 本数)で渡すこと。received=${JSON.stringify(raw)}(type=${Array.isArray(raw) ? 'array' : typeof raw})。` +
        ' 不正値を既定へ黙って倒すと「cap を頼んだのに無 cap で走る」silent fail-open になるため fail-fast する(sc-k33c 層1)。'
    )
  }
  return raw
}
const totalBudget = __capIntArg(A.totalBudget, 'totalBudget') // 0 = 無 cap。単位 = agent 本数
const perRoundVerifyTopK = __capIntArg(A.perRoundVerifyTopK, 'perRoundVerifyTopK') // 0 = 無 cap。観点(dimension)単位の top-K
const CAP_ON = totalBudget > 0
// 免除段(admission を通さない段)の最小本数: self-test baseline+final(selfTestCmd 供給時のみ 2)+ classify
// (taskType 未指定時 1)+ plan(doPlan 時 1)+ implement(doImplement 時 1)+ round1 snapshot(1)。
// totalBudget がこれ + 1(gated 段が最低 1 本走る余地)を下回ると「実呼出し総数 ≤ totalBudget」を保証できない
// ので fail-fast する(保証できない cap を黙って受けて、守れない約束を返り値に載せない)。
const CAP_EXEMPT_FLOOR = (selfTestCmd ? 2 : 0) + (taskType ? 0 : 1) + (doPlan ? 1 : 0) + (doImplement ? 1 : 0) + 1
if (CAP_ON && totalBudget < CAP_EXEMPT_FLOOR + 1) {
  throw new Error(
    `[cell-quality cap args fail-fast] totalBudget=${totalBudget} は本 run の免除段下限(${CAP_EXEMPT_FLOOR} 本: self-test baseline/final・classify・plan・implement・round1 snapshot のうち発火する段)+ gated 段 1 本を下回る。` +
      ' 免除段(監査面)は admission で落とさない設計ゆえ、この値では「実呼出し総数 ≤ totalBudget」を保証できない(sc-k33c 層1・保証できない cap は受けない)。'
  )
}
// 終盤の監査面(self-test final)1 本を常に予約し、gated 段がそれを食い潰さないようにする。
const CAP_EXEMPT_RESERVE = selfTestCmd ? 1 : 0

// ── cap 状態(返り値の fail-loud 表面へそのまま載る) ──────────────────────────────
let capExceeded = false
let capReason = '' // 'cap'(自前 totalBudget の admission)|'quota'(harness の token budget 例外)|'error'(harness の agent cap 例外)
// (sc-k33c ERRATA-01 B1) 計上を 2 本立てにする。旧実装は 1 本の counter を「admission の予約」と「起動本数の
// 見積り」に兼用しており、roAgent の not-found fallback(WF 上部・agentType 付き呼出しが失敗したあと agentType
// 無しで **2 度目の実呼出し**をする)を取りこぼした。結果 (a) 実呼出し総数 > totalBudget(gate 実測: RO fallback +
// totalBudget=7 で実呼出し 8)、(b) spentEstimate < 実呼出し総数(cap OFF でも 33 実呼出しに対し 32)。
//   - capSpent  = **実際に agent() を呼んだ回数**。capCountCall() が実呼出しの現場でだけ加算する。
//                 これが capReport.spentEstimate であり「spentEstimate == 実呼出し総数」を構造的に保証する。
//   - capBooked = admission の予約(論理段の帳簿)。判定はこちらで行う。1 論理 agent の予約コストは
//                 capCallCost()= RO agentType の解決状態が未確定なら 2(fallback の 2 度目呼出し分)・確定後は 1。
// 各 agent の実コスト ≤ 予約コストなので **capSpent ≤ capBooked ≤ totalBudget** が成り立つ(= 実呼出し総数の
// 上限保証)。予約は起動前に積む(fallback が起きても予約済みの枠内に収まる)。
let capSpent = 0 // 実呼出し回数(capCountCall のみが加算)= spentEstimate
let capBooked = 0 // admission の予約(判定用の帳簿)
const capStages = [] // [{round, stage, requested, admitted, dropped, reason}] = どの段でどれだけ落としたか
const capDropped = [] // 縮退で落とした対象。**unverified とは別枠**(verdict 取得失敗とは意味が違う=二重計上しない)
const capTokenStart = budget && typeof budget.spent === 'function' ? budget.spent() : null

// RO agentType の解決状態。roAgent が「agentType 付きで成功」or「fallback へ降格済み」を通知したら確定＝
// 以降 1 論理 agent の実呼出しは 1 回に収まる。未確定の間は 2 回(probe + fallback)を予約する(保守側)。
let capRoResolved = RO_FORCE_NONE // 'none' 強制は最初から agentType を付けない=常に 1 回
const capMarkRoResolved = () => {
  capRoResolved = true
}
const capCallCost = () => (capRoResolved ? 1 : 2)
// 実呼出しの現場から呼ぶ唯一の計上点(roAgent の全 return path + agent() 直呼び段)。
const capCountCall = (stage) => {
  capSpent += 1
  return capSpent
}
// agent() 直呼び段(implement / fix)用の薄いラッパ: 実呼出しを計上してから素の agent() を呼ぶ。
const capAgent = (prompt, opts) => {
  capCountCall((opts && opts.label) || 'agent')
  return agent(prompt, opts)
}

// 免除段(classify / self-test / snapshot / plan / implement)= 拒否しないが、予約だけは積む(総数保証のため)。
// 実呼出しの計上は capCountCall が行うので、ここでは帳簿(capBooked)だけを動かす。
const capAccount = (n, stage) => {
  capBooked += n * capCallCost()
  return n
}
// 落とした対象を loud に列挙する(silent に消さない)。severity 不明は 'unknown'(blocking 級として fail-closed)。
const capDrop = (stage, dimension, title, severity, reason) => {
  capDropped.push({ stage, dimension: dimension || '', title: String(title || '(no title)').slice(0, 120), severity: severity || 'unknown', reason })
}
const capMarkExceeded = (reason) => {
  capExceeded = true
  if (!capReason) capReason = reason
}
// 帳簿を実測へ同期する。**in-flight の agent が 1 体も無い地点でだけ**呼んでよい(= admission の各点。
// WF は段の間で必ず await するので、round 頭 / review 前 / fix 前では実呼出しが確定している)。これを入れないと
// 「RO 解決前に 2 本で予約した免除段が、実際は 1 本で済んだ」分の過剰予約が恒久的に残り、予算が実質目減りする
// (= 同じ totalBudget で従来より admit が減る退行)。verify 枠の計算点では review が未起動＝予約が生きている
// ので **同期しない**(そこで同期すると review の予約が消えて二重に admit できてしまう)。
const capReconcile = () => {
  capBooked = capSpent
}
// admission: want 本のうち予算内に収まる本数を返す(0=全落とし)。免除段の予約分は残量から差し引く。
const capAdmit = (want, stage, round) => {
  capReconcile()
  // (sc-k33c errata) cap 未指定(opt-in OFF)でも **消費は計上する**。ここで早期 return して加算を飛ばすと
  // review(既定 4 本/round)と fix(1 本/round)が capReport.spentEstimate から丸ごと欠落し、cap を使わない
  // 全 run(= 実運用の 100%)で「起動本数の見積り」が系統的に過小になる。spentEstimate は totalBudget の
  // 実運用値を決める calibration の一次データ(M0)かつ下流 sc-46kv が bd へ焼く値ゆえ、on/off いずれでも
  // 「spentEstimate == 実 agent 呼出し総数」を保つ(判定は CAP_ON のときだけ効く=既定路の制御フローは不変)。
  if (!CAP_ON) {
    capBooked += want * capCallCost()
    return want
  }
  const cost = capCallCost()
  const remaining = totalBudget - capBooked - CAP_EXEMPT_RESERVE * cost
  const admitted = Math.max(0, Math.min(want, Math.floor(remaining / cost)))
  capBooked += admitted * cost
  if (admitted < want) {
    capMarkExceeded('cap')
    capStages.push({ round: round || 0, stage, requested: want, admitted, dropped: want - admitted, reason: 'cap' })
    log(`[cap] ${stage}${round ? ` r${round}` : ''}: 予算不足で縮退(requested=${want} admitted=${admitted} dropped=${want - admitted} / limit=${totalBudget} agent 本数・booked=${capBooked} spent=${capSpent})。落とした分は capDropped[] に列挙する(silent に消さない)。`)
  }
  return admitted
}
// round 丸ごとの欠落を capDropped[] へ loud に列挙する(観点 1 つの欠落より強い blocking 級の事象なのに
// capStages にしか痕跡が無いと、terminal の escalate 条件〔capDroppedBlocking>0〕が立たず fail-open になる)。
// severity='unknown' = 落とした先に blocking が無かったとは主張できない(コード自身の fail-closed 規約と同じ)。
const capDropRound = (round, reason) => {
  const dims = Array.isArray(dimensions) && dimensions.length ? dimensions : [{ key: '(dimensions 未解決)' }]
  for (const d of dims) {
    capDrop('round', d.key, `(round r${round} を丸ごと回さず観点 ${d.key} を review/verify していない)`, 'unknown', reason)
  }
}
// 層2-① round 頭: この round の snapshot(免除 1)+ review 最低 1 本が入らなければ round に入らない。
const capRoundGate = (round) => {
  // (sc-k33c errata) **CAP_ON ガードを最初に置く**。cap を頼んでいない run(totalBudget 未指定)の制御フローは
  // 例外経路でも 1 mm も変えない(K2' = cap 未指定時の agent 呼出し列が base 木と完全一致する)。以前はこの
  // 早期 return が CAP_ON より前に在り、指紋に部分一致した machinery 例外 1 件で既定構成の run から review
  // 段が丸ごと消える単一障害点になっていた(cap 未指定 run で rounds 3→1・agent 17→7 本の実測差)。
  // (sc-k33c errata 追記) 「1 mm も変えない」の射程は **制御フロー(= agent 呼出し列)** に限る。終端状態は
  // 別: cap 指紋を持つ例外を捕捉した run は cap 未指定でも capExceeded=true ゆえ converged を立てない
  // (fail-closed 側への **意図した非互換**。escalate は blocking 級 drop があるときだけ=K1 項目5)。
  // 差分は tests/cell-quality-cap.bats の "terminal 非互換の明示 pin" tooth が base 木対照で固定している。
  if (!CAP_ON) return true
  capReconcile()
  // 例外由来の cap(quota/error)は「実際に走れなかった」事実ゆえ、次 round を回しても同じ throw を繰り返す。
  // 自前 admission 由来('cap')は topK 縮退等で立つこともあるので、これだけでは打ち切らない(残量で判定する)。
  if (capReason === 'quota' || capReason === 'error') {
    capDropRound(round, 'round-gate-exception')
    log(`[cap] round r${round}: 直前に cap 系例外(reason=${capReason})を捕捉済み。次 round を回さず打ち切る(収束は主張しない)。落とした round 分は capDropped[] に列挙する。`)
    return false
  }
  const gateCost = capCallCost()
  const need = 2 * gateCost // このラウンドの snapshot(免除 1)+ review 最低 1 本の【予約コスト】
  const remaining = totalBudget - capBooked - CAP_EXEMPT_RESERVE * gateCost
  if (remaining < need) {
    capMarkExceeded('cap')
    capStages.push({ round, stage: 'round', requested: need, admitted: 0, dropped: need, reason: 'cap' })
    // (sc-k33c errata) capStages へ 1 行積むだけでは capDropped[]=[] / droppedBlocking=0 となり、gate 文が
    // 「capDropped を直読して落とした観点を人手確認せよ」と促すのに中身が空という自己矛盾になっていた。
    capDropRound(round, 'round-gate')
    log(`[cap] round r${round}: 残 ${remaining} 本では 1 round(snapshot+review 最低 1)を回せない(limit=${totalBudget} agent 本数・booked=${capBooked} spent=${capSpent})。round に入らず打ち切る(収束は主張しない)。落とした round 分は capDropped[] に列挙する。`)
    return false
  }
  return true
}
// 層2-③ verify の観点別固定枠: **共有カウンタ先着順にしない**(到着順で食い合うと stage1 の解決順で admit 集合が
// 変わり非決定になる=K1c 禁止)。round 頭で残量を観点数で等分した固定枠を配る=解決順を入れ替えても同じ集合。
const capVerifyQuotaPerDim = (dimCount) => {
  if (!CAP_ON) return Infinity
  const cost = capCallCost()
  const reserveFix = canAutoFix ? 1 : 0
  const avail = Math.max(0, totalBudget - capBooked - (CAP_EXEMPT_RESERVE + reserveFix) * cost)
  // 枠は【本数】で返す(予約コストで割る)。呼出元は「観点あたり何本 verify してよいか」として使う。
  return dimCount > 0 ? Math.floor(avail / cost / dimCount) : 0
}
// 決定論 tie-break: severity 降順(critical→nit) → dimension key 昇順 → title 安定順(昇順・同値は元順)。
// 観点単位で呼ぶため dimension key は定数だが、比較器に含めて cross-dimension でも同じ全順序になるようにする。
const capOrderFindings = (findings, dimKey) =>
  findings
    .map((f, i) => ({ f, i, dim: String((f && f.dimension) || dimKey || '') }))
    .sort((a, b) => {
      const sa = CAP_SEVERITY_RANK[a.f && a.f.severity] !== undefined ? CAP_SEVERITY_RANK[a.f.severity] : 4
      const sb = CAP_SEVERITY_RANK[b.f && b.f.severity] !== undefined ? CAP_SEVERITY_RANK[b.f.severity] : 4
      if (sa !== sb) return sa - sb
      // 第2キー: dimension key 昇順。**比較対象は要素ごとの dim**(finding.dimension があればそれ・無ければ
      // 呼出し時の観点 key)。旧実装は dimKey 同士を比べており恒真 0 の dead comparator だった(=第2キーが
      // 実装されていない)。観点単位で呼ぶ限り実値は定数だが、比較器としては全順序を成立させる。
      if (a.dim !== b.dim) return a.dim < b.dim ? -1 : 1
      // 第3キー: title 昇順。**locale 非依存の code-unit 順**で比較する(localeCompare は ICU/locale 依存で
      // ホストが変わると順序が変わりうる=K1c が要求する「決定論式」を満たさない)。
      const ta = String((a.f && a.f.title) || '')
      const tb = String((b.f && b.f.title) || '')
      if (ta !== tb) return ta < tb ? -1 : 1
      return a.i - b.i // 第4キー: 元順(安定ソート)
    })
    .map((x) => x.f)
// 層2-③ 縮退順の本体: (1) perRoundVerifyTopK(観点単位 top-K)→ (2) 予算枠で critical/major 限定 →
// (3) severity top-K(決定論 tie-break)→ (4) loud drop(枠 0)。落とした分は capDropped[] へ列挙する。
const capSelectVerify = (findings, dimKey, round, quota) => {
  // 【後方互換の要】実際に 1 件も落とさない round では **並べ替えもしない** = 既定経路(cap 未指定)の verify
  // 呼出し列が base 木と 1 mm も変わらない(severity 順への恒常ソートは呼出し列を変える退行だった=K2' 実測)。
  const needTopK = perRoundVerifyTopK > 0 && findings.length > perRoundVerifyTopK
  const needBudget = CAP_ON && findings.length > quota
  if (!needTopK && !needBudget) {
    capBooked += findings.length * capCallCost()
    return findings
  }
  const ordered = capOrderFindings(findings, dimKey)
  let admit = ordered
  const dropAll = (list, reason) => {
    for (const f of list) capDrop('verify', dimKey, f && f.title, f && f.severity, reason)
  }
  if (perRoundVerifyTopK > 0 && admit.length > perRoundVerifyTopK) {
    const cut = admit.slice(perRoundVerifyTopK)
    dropAll(cut, 'perRoundVerifyTopK')
    admit = admit.slice(0, perRoundVerifyTopK)
    capMarkExceeded('cap')
    capStages.push({ round, stage: `verify:${dimKey}`, requested: ordered.length, admitted: admit.length, dropped: cut.length, reason: 'cap' })
    log(`[cap] verify:${dimKey} r${round}: perRoundVerifyTopK=${perRoundVerifyTopK} で ${cut.length} 件を verify せず落とした(観点単位 top-K・決定論 tie-break)。capDropped[] を直読すること。`)
  }
  if (CAP_ON && admit.length > quota) {
    const before = admit.length
    const blockingOnly = admit.filter(capIsBlocking)
    // (縮退順 1) verify を critical/major に限定する。blocking が 1 件も無い round で限定すると admit=0 に
    // なり「枠が余っているのに何も verify しない」退行になるので、blocking が在るときだけ限定する。
    if (blockingOnly.length > 0 && blockingOnly.length < admit.length) {
      dropAll(admit.filter((f) => !capIsBlocking(f)), 'severity-limited')
      admit = blockingOnly
    }
    if (admit.length > quota) {
      dropAll(admit.slice(quota), quota === 0 ? 'budget-drop' : 'severity-topk')
      admit = admit.slice(0, quota)
    }
    capMarkExceeded('cap')
    capStages.push({ round, stage: `verify:${dimKey}`, requested: before, admitted: admit.length, dropped: before - admit.length, reason: 'cap' })
    log(`[cap] verify:${dimKey} r${round}: 予算枠 ${quota} 本へ縮退(要求 ${before} → admit ${admit.length})。縮退順=critical/major 限定 → severity top-K → loud drop。落とした分は capDropped[]。`)
  }
  capBooked += admit.length * capCallCost()
  return admit
}

// ── 層3: cap 系例外の判定と正規化 ───────────────────────────────────────────────
// name **または** message で判定する(AND 禁止=片方一致で cap 扱い)。message 指紋は tests/ に literal で
// literal 化される。★この pin が検知できるのは **自リポ内の literal 改変**だけで、実機文言の drift は検知
// できない(tests は WF の literal と突き合わせるだけで実機と突き合わせていない)。指紋自体が未実測の保守的
// 列挙である点は K9 留保(5)と follow-up(実機指紋の確定)に記録してある。どちらにも非一致 = cap ではない。
const CAP_ERROR_NAMES = { WorkflowBudgetExceededError: 'quota', WorkflowAgentCapError: 'error' }
// (sc-k33c ERRATA-01 B2) 指紋は **語境界一致**(\b…\b)で見る。旧実装は素の substring 一致で、cap でない
// machinery 例外を capExceeded へ吸い込んだ(gate 実測: 'agent capability probe returned malformed payload' が
// reason='error' に化け、既定路の fail-closed 再 throw が exit 0 / ESCALATE へ迂回した)。'agent cap' が
// 'agent capability' / 'agent capacity' に、'budget exceeded' が 'budget exceededness' に部分一致していた。
// 語境界にすると これらの near-miss は非一致になり、cap でない例外は従来経路(再 throw / 既存の失敗正規化)へ
// 倒れる=fail-closed が保たれる。
const CAP_MESSAGE_FINGERPRINTS = [
  { re: /\bbudget exceeded\b/, reason: 'quota' },
  { re: /\btoken budget\b/, reason: 'quota' },
  { re: /\bagent cap\b/, reason: 'error' },
  { re: /\bagent limit\b/, reason: 'error' },
  { re: /\bexceeded the agent\b/, reason: 'error' },
]
const capClassify = (e) => {
  const name = e && e.name ? String(e.name) : ''
  if (CAP_ERROR_NAMES[name]) return CAP_ERROR_NAMES[name]
  const msg = (e && e.message ? String(e.message) : String(e == null ? '' : e)).toLowerCase()
  for (const fp of CAP_MESSAGE_FINGERPRINTS) if (fp.re.test(msg)) return fp.reason
  return '' // cap 系でない = 呼出サイトの従来経路へ(fail-closed)
}
// (sc-k33c errata) self-test 段(監視専用)で捕捉した cap 系例外の情報欄。**terminal 判定も round gate も
// 駆動しない**(B4 不変条件「self-test の返り値は情報ログ専用で converged/escalate を一切駆動しない」)。
const capSelfTestExceptions = []
// informOnly=true(self-test 段専用): 可視化だけ行い capExceeded / capReason / capDropped[] を触らない。
// これらを触ると (a) capExceeded → converged 強制 false、(b) capDropped の severity='unknown' →
// droppedBlocking≥1 → escalate 強制 true、(c) capReason='quota' → capRoundGate 早期打切り、の 3 経路で
// 監視専用段が終端判定を反転させてしまう(実測: clean 収束 run が selftest:final の例外 1 発で ESCALATE 化)。
// (sc-k33c errata) alreadySurfaced=true(verify 要素段 専用): capExceeded / capReason / capStages と log は
// 打つが **capDropped[] へは積まない**。理由は 2 つ。(a) この段の verify agent は **実際に起動しており**、
// 例外を捕捉した finding は従来どおり verdict:null へ正規化されて unverified[] という一次面に載る。ここで
// capDrop も打つと同一事象が capDropped と unverified の両面へ二重計上され、コード自身の規約
// 「capDropped[] は unverified とは別枠(verdict 取得失敗 ≠ そもそも verify を起動しなかった)」(K3-3)と
// escalateReason の「verify/fix せず落とした」が事実に反する。(b) capDrop の severity='unknown' は
// CAP_BLOCKING_DROP_SEVERITIES に入るため droppedBlocking を押し上げ、「blocking 級を落とした時のみ
// escalate」(K1 項目5)を破る。実測: cap 未指定(実運用 100% の既定路)・minor 1 件・verify: の quota 例外で
// base=CONVERGED / HEAD=ESCALATE と終端が反転していた(同じ「nit/minor を verify できなかった」事象を
// perRoundVerifyTopK 経由で起こすと f.severity が使われ escalate しない＝経路で終端が食い違っていた)。
// 修正後の終端は converged=false / escalate=false(gate=OPEN)= K1 項目5 の literal どおり。
// review 段(観点丸ごと欠落＝findings 自体が取れず一次面が無い)と self-test 段(informOnly)は現行のまま。
const capRecordException = (stage, reason, e, opts) => {
  if (opts && opts.informOnly === true) {
    capSelfTestExceptions.push({ stage, reason, name: (e && e.name) || '' })
    log(`[cap] ${stage}: cap 系例外(reason=${reason} name=${(e && e.name) || ''})を捕捉したが、self-test は情報ログ専用段ゆえ converged/escalate も round gate も駆動しない(B4 不変条件)。capReport.selfTestExceptions で可視化する。`)
    return
  }
  capExceeded = true
  capReason = reason // 例外(実際に走れなかった)は自前 admission より強い事実ゆえ上書きする
  capStages.push({ round: 0, stage, requested: 1, admitted: 0, dropped: 1, reason })
  const alreadySurfaced = !!(opts && opts.alreadySurfaced === true)
  if (!alreadySurfaced) capDrop(stage, '', `(${stage} が cap 系例外で停止)`, 'unknown', reason)
  log(
    `[cap] ${stage}: cap 系例外(reason=${reason} name=${(e && e.name) || ''})を捕捉し capExceeded へ正規化した。run を消さず result を返す(sc-k33c 層3)。` +
      (alreadySurfaced
        ? ' 当該 finding は従来どおり verdict:null → unverified[] に載る一次面を持つので capDropped[] へは積まない(二重計上禁止=K3-3・severity 不明の捏造で escalate を安売りしない=K1 項目5)。'
        : '')
  )
}
// 無防備だった 6 call site 用: cap 系なら正規化値を返し、cap 系でなければ **再 throw**(従来挙動を変えない)。
const capCatch = (stage, fallback) => (e) => {
  const reason = capClassify(e)
  if (!reason) throw e
  capRecordException(stage, reason, e)
  return typeof fallback === 'function' ? fallback() : fallback
}
// (sc-k33c ERRATA-01 B5) 同期 throw を try/catch で受けた場所から使う入口。意味は capCatch と同じで、
// **capClassify は 1 回しか走らない**(呼出サイトで判定を再実装して classify を 2 度呼ぶ形を禁止する)。
// これを置くことで「cap の判定コードは SCCAP ブロックに閉じる」(K8)を try/catch 側でも守れる。
const capCatchSync = (stage, fallback, opts) => capCatch(stage, fallback, opts)
// loop モードの終端で使う 2 つの判定/文言生成(呼出サイトは結果を使うだけ)。
//  - capTerminatedEarly: cap 由来の早期打切り(hard cap 未達なのに打ち切った)か。hard-cap 網へ合流させる述語。
//  - capLoopEscalate: escalateReason の文言生成。cap 由来の早期打切りを「hard cap 到達」と書くと事実に反する
//    (round < effectiveCap)ので弁別して書く。
const capTerminatedEarly = (round, effectiveCap) => capExceeded && round < effectiveCap
const capLoopEscalate = (round, effectiveCap, why) =>
  `${capTerminatedEarly(round, effectiveCap) ? `cap 由来の早期打切り(round ${round}/${effectiveCap}・reason=${capReason || 'cap'})` : `hard cap ${effectiveCap} 到達`}・未収束(${why})`
// 既存 3 catch(review / verify / runSelfTest)用: 従来の失敗正規化は温存しつつ、cap 系だけ別勘定にする
// (machinery 失敗と cap 縮退を混同させない)。非 cap でも従来どおり正規化値を返す(= .catch の意味論は不変)。
// opts.informOnly=true(self-test 段)は可視化のみ = terminal/round gate を駆動しない(B4)。
// opts.alreadySurfaced=true(verify 要素段)は capDropped[] へ積まない = unverified との二重計上を作らない(K3-3)。
const capReclassify = (stage, fallback, opts) => (e) => {
  const reason = capClassify(e)
  if (reason) capRecordException(stage, reason, e, opts)
  return typeof fallback === 'function' ? fallback() : fallback
}

// ── terminal 判定 + fail-loud 表面の確定(K8: cap の判定コードは本ブロックに閉じる) ────────────────
// 呼出サイト(WF 末尾)は本関数を呼んで返り値を適用するだけ = cap の判定ロジックがブロック外へ散らない
// (旧実装は terminal 判定 / capReport 組立 / capNote 生成の 3 つがブロック外に在り K8 の閉包に反していた)。
// 不変条件: cap が発火した run は「幅を落として走った」= 見ていない観点/finding が在るので **converged を
// 立てない**(clean と cap 縮退を混同させない)。escalate は **blocking 級を落としたときだけ**立てる
// (minor/nit を perRoundVerifyTopK で落としただけの run まで人手判断へ送らない=escalate の安売り防止)。
// self-test final(免除段)まで走り終えた後に呼ぶ = spentEstimate が実際の総本数を反映する。
const capFinalize = (state) => {
  let converged = state.converged
  let escalate = state.escalate
  let escalateReason = state.escalateReason
  const droppedBlocking = capDropped.filter((d) => CAP_BLOCKING_DROP_SEVERITIES.has(d.severity)).length
  if (capExceeded) {
    converged = false
    if (droppedBlocking > 0 && !escalate) {
      escalate = true
      escalateReason =
        escalateReason ||
        `cap 発火(reason=${capReason})で blocking 級 ${droppedBlocking} 件(critical/major/観点丸ごと欠落)を verify/fix せず落とした。落とした先に blocking が無かったとは主張できない(fail-closed)=人手確認。`
    }
  }
  // token は **情報ログ専用**(判定は agent 本数)。budget.total は呼出元が turn budget を設定しないと null な
  // ので null ガードする(null を 0 と読んで「予算ゼロ」に誤断定しない)。
  const budgetTotal = budget && budget.total != null ? budget.total : null
  const tokenEnd = budget && typeof budget.spent === 'function' ? budget.spent() : null
  const tokenDelta = capTokenStart !== null && tokenEnd !== null ? tokenEnd - capTokenStart : null
  log(
    `[cap-token] budget.total=${budgetTotal === null ? 'null(未設定)' : budgetTotal} spent-delta=${tokenDelta === null ? 'n/a' : tokenDelta} / cap 判定は agent 本数(limit=${totalBudget || '無 cap'} booked=${capBooked} spent=${capSpent})で行い、token は情報ログ併走のみ(判定に使わない)。`
  )
  const capReport = {
    limit: totalBudget, // 0 = 無 cap(opt-in 既定)
    unit: 'agent-calls', // 【単位契約】totalBudget の単位は agent 本数(token ではない)
    spentEstimate: capSpent, // 免除段(classify/self-test/snapshot/plan/implement)も含む起動本数の見積り
    stages: capStages, // どの段でどれだけ落としたか([{round,stage,requested,admitted,dropped,reason}])
    reason: capReason || '', // 'quota'(harness token budget 例外)|'cap'(自前 admission)|'error'(harness agent cap 例外)
    droppedAgents: capDropped.length, // 起動しなかった agent 相当数(= capDropped[] の件数)
    droppedBlocking, // うち blocking 級(critical/major/severity 不明)= escalate の駆動値
    historyCount: history.length, // (項目3) history 件数も capReport から辿れる
    // (sc-k33c errata) self-test 段(情報ログ専用=B4)で捕捉した cap 系例外。**terminal も round gate も駆動しない**
    // ゆえ capExceeded/capReason/capDropped[] には載らず、可視化はここだけ(監視専用段が終端判定を反転させない)。
    selfTestExceptions: capSelfTestExceptions,
    tokenDelta, // 情報ログ専用(判定に使わない)
    budgetTotal, // null = 呼出元が turn budget を設定していない(層3 は実機では発火しない)
  }
  // 4 つ目の note。cap が発火した run は幅を落として走った=見ていない観点/finding が在るので、収束/escalate に
  // 関わらず注記して silent ship させない(unvNote/machNote/schemaNote と同じ思想)。呼出サイトで 3 分岐とも
  // schemaNote の【直後・末尾】へ連結する(CONVERGED/ESCALATE/OPEN の prefix と本文は不変)。
  const capNote = capExceeded
    ? ` ※cap 発火(reason=${capReport.reason}, limit=${capReport.limit} ${capReport.unit}, spentEstimate=${capReport.spentEstimate}, dropped=${capReport.droppedAgents}(うち blocking 級 ${capReport.droppedBlocking}))= 幅を落として走った run。capReport/capDropped を直読し、落とした観点/finding を人手確認(網羅性を主張しない)。`
    : ''
  return { converged, escalate, escalateReason, capReport, capNote, capDroppedBlocking: droppedBlocking }
}
//SCCAP_BLOCK_END

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
// (sc-pyab 項目1) goal-anchored severity の rubric。review / verify の **双方へ同一 literal** を焼く。
// 収束ループの終了条件の固定点は「acceptance / fence を脅かす重大欠陥ゼロ」であって「レビュアーが何も
// 言わなくなること」ではない。severity が好み・一般論で付くと (a) 受入に無関係な指摘が blocking として
// ループを駆動し churn を生む / (b) 受入を脅かす欠陥が minor に埋もれて silent ship する、の両方向に外れる。
// ゆえに severity の基準を「受入(acceptance / fence)を脅かすか」1 本へ固定し、prompt に literal で焼く。
// literal 到達は tests/cell-quality-loop.bats の CQ_PROMPT_GREP 軸 tooth が pin する(消えたら RED)。
const SEVERITY_RUBRIC = `【severity rubric(goal-anchored)】severity は acceptance / fence を脅かすかを唯一の基準に付与する。
- critical/major = acceptance 未達・fence 違反・回帰・fail-open・破壊性・boot path 等、受入を脅かすもの(収束ループを駆動する)。
- minor/nit = 受入を脅かさない指摘(記録のみ・ループさせない)。過剰提案・好みの指摘は出さない。
- args の acceptance が定型文の場合は contextFile を優先する(定型文を根拠に severity を上下させない)。`

function ctxBlock() {
  return [
    `# セル: ${taskTitle}`,
    `worktree: ${worktree}`,
    goal ? `goal:\n${goal}` : '',
    refinedAcceptance ? `acceptance(受入基準):\n${refinedAcceptance}` : '',
    context ? `context:\n${context}` : '',
    // (12) contextFile: 大文脈のファイル渡し。agent が実バイトを Read する(script は fs 非アクセス)。
    contextFile
      ? `context file: ${contextFile}\n(まずこのファイルを Read し、全文を本セルの文脈として扱うこと。Workflow args は全体約 4KB で切り詰められるため、大きな文脈はこのファイルで供給されている)`
      : '',
  ]
    .filter(Boolean)
    .join('\n\n')
}

// (sc-pyab 項目1) verifyPrompt 用の goal-anchor。ctxBlock の **goal / acceptance だけ**を切り出す。
// 独立反証者へ context / contextFile 全文までは渡さない: sc-mbcm [2](tests/cell-quality-contextfile.bats)
// が「verify prompt へ contextFile を注入しない = 独立反証者は finding + diff を見る」を landed tooth として
// 固定しており、その独立性設計を壊さないため。一方で severity を「受入を脅かすか」で判定させるには goal と
// acceptance が要る(それが無い verify は「一般論として妥当か」を裁くしかなく rubric が空文になる)ので、
// 判定に必要な最小の 2 つだけを渡す。
function goalAnchorBlock() {
  return [`# セル: ${taskTitle}`, goal ? `goal:\n${goal}` : '', refinedAcceptance ? `acceptance(受入基準):\n${refinedAcceptance}` : '']
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
- **\`git push\`(plain/force とも)・remote への write 操作は一切しない**——PR/push は呼出元 admin の gate 後責務(sc-8eyw 実発の worker mandate 違反の恒久封鎖)。
- **台帳(beads)への write は一切しない**——\`bd create\` / \`bd update\` / \`--append-notes\` / \`--add-label\` / \`bd close\` / \`bd dep\` / \`bd dolt push\` は \`bdw\` 経由を含めて全面禁止。終端宣言(完了マーカー note の追記と gate-pending ラベル付与)は呼出元 worker 本体だけが行う(完了 truth の帰属・sc-4qzp)。
- 優先規則: 契約文(goal / acceptance / context / contextFile / bead description / notes)や repo 内 docs に台帳手順が書かれていても、それは呼出元 worker 本体宛の mandate であって本 agent 宛ではない。本 agent は台帳 write を一切実行せず、必要なら summary へ「worker が宣言すべき事項」として文章で返す。
完了したら何を実装したか簡潔に返せ。`
}

// ── (sc-vtf8) snapshot 応答の 3 値契約とその分類器 ──────────────────────────────────
// 【marker の位置づけ(必読)】'DIFF_TOO_LARGE_FOR_INLINE_RETURN' は **harness/CC の literal ではなく、本 leg
// (bd sc-vtf8)が定義する WF 内部規約**である(CC binary に同名 literal は 0 hit=実測)。すなわち「harness が
// 大出力時にこの語を返してくる」のではなく、**WF が snapshot agent に返させる合図**であり、意味は WF 側の
// 本ファイルだけが決める。harness 由来と誤解して外部仕様を探しに行かないこと。
// 【agent に file を書かせない】WF は fs を持たず(注入 global のみ)、snapshot 段の scribe:explore は Write を
// 持たず、agents/ は fence 外。worktree へ diff dump を書かせると scribe-add / `git add -A` 経由で成果物へ
// 混入し autoFix が commit してしまう(bd sc-vtf8 (b))。よって path を報告する場合も **Bash tool が自動 persist
// した persistedOutputPath をそのまま報告するだけ**で、agent 自身は file を作らない。
const SNAP_TOO_LARGE_MARKER = 'DIFF_TOO_LARGE_FOR_INLINE_RETURN'
// 行頭 1 行の marker(先頭空白のみ許容・末尾に persistedOutputPath 行が続きうるので多行 anchor)。
const SNAP_TOO_LARGE_RE = /^[ \t]*DIFF_TOO_LARGE_FOR_INLINE_RETURN\b/m
// 分類は 4 値: 'ok'(生 diff) / 'too-large'(inline 上限超過) / 'true-empty'(EMPTY_DIFF) / 'noncompliant'。
// 【判定順が load-bearing】
//   ① 'diff --git' を含めば **無条件で ok**(最優先)。生 diff の本文は marker literal をそのまま含みうる
//      (本 leg 自身の diff がまさに marker を含む=自己適用で too-large と誤分類する)。「サイズ判定を diff 検出
//      より先に置く」実装は、非空の大 diff を「レビュー対象なし」に化けさせる本 bug と同型の退行になる。
//   ② 行頭 marker → 'too-large'(差分は在るが inline 返却できなかった=未レビュー)。
//   ③ 'EMPTY_DIFF' を含む → 'true-empty'(un-2f1: 説明文を前置されても取りこぼさない substring 判定)。
//   ④ どれでもない(null / 空 / 説明文だけ) → 'noncompliant'。**'true-empty' へ丸めない**: 空だと断定できない
//      応答を「レビュー対象不在」と名乗ると偽の一次診断(sc-u9tj / orch-4c0a の実害)を再生産する。
// 分類自体は snapshotInlineLimitBytes の指定有無で切り替えない(未指定時は上限節を prompt へ焼かない=②は
// 到達しないため後方互換は保たれる。逆に gate すると、marker を受け取っても「EMPTY_DIFF=対象不在」と
// 名乗る誤診断が残ってしまう)。
function classifySnapshot(snap) {
  const s = typeof snap === 'string' ? snap : ''
  if (s.includes('diff --git')) return 'ok'
  if (SNAP_TOO_LARGE_RE.test(s)) return 'too-large'
  if (s.includes('EMPTY_DIFF')) return 'true-empty'
  return 'noncompliant'
}
// kind 別の escalateReason 断片。「レビュー対象不在」「commit 済の可能性」を名乗ってよいのは 'true-empty' だけ
// (それ以外で名乗ると二次誤診の芽になる= bd sc-vtf8 notes (2))。
function snapshotKindNote(kind, staticDiff) {
  if (kind === 'too-large')
    return (
      `snapshot=inline 上限超過(${SNAP_TOO_LARGE_MARKER} / limit=${snapshotInlineLimitBytes} bytes)。` +
      `差分は **存在する** が inline 返却できず未レビュー(空 diff とは別事象であり、EMPTY_DIFF 系の診断を当てはめてはならない)。` +
      `target/baseRef で範囲を絞るか snapshotInlineLimitBytes を見直して再実行すること。`
    )
  if (kind === 'noncompliant')
    return (
      `snapshot 応答が 3 値契約(生 diff / EMPTY_DIFF / ${SNAP_TOO_LARGE_MARKER})のいずれにも一致せず(空 or 説明文のみ)= ` +
      `snapshot machinery 異常。差分の有無は **未確定**(空だと断定できない)= 人手確認。`
    )
  // 'true-empty': 従来文言(un-2f1/un-2yy)を維持する。
  return `snapshot=EMPTY_DIFF=レビュー対象不在(${staticDiff ? 'diff 供給済' : 'diff 未供給'})。空 diff は実装が既に commit 済の可能性(git diff HEAD が空)= un-2f1 参照。clean と区別し人手確認。`
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
注意: 一方が空でも他方に差分があれば EMPTY_DIFF ではない(必ず両方を確認すること)。${tooLargeClause(baseExpr)}`
}

// (sc-vtf8) 3 値契約の 3 つ目 = inline 上限超過節。**閾値未指定(0)では空文字**を返す = prompt は従来の 2 値
// 契約のまま(完全後方互換・弁別を行わない)。marker の位置づけ(harness literal ではなく WF 内部規約)と
// 「agent に file を作らせない」理由は classifySnapshot 直上のブロックコメントを参照。
function tooLargeClause(baseExpr) {
  if (!(snapshotInlineLimitBytes > 0)) return ''
  return `
ただし合成 diff が **${snapshotInlineLimitBytes} bytes を超える**ときは、diff 本文を一切返さず、他の語を一切付けずに
次の 1 行だけを **行頭から** 返せ(EMPTY_DIFF とは別物であり、絶対に混同するな):
${SNAP_TOO_LARGE_MARKER} bytes=<実測バイト数>
実測バイト数は次で測れ: \`{ ${baseExpr}; git -C "${worktree}" diff "$BASE"...HEAD; git -C "${worktree}" diff HEAD; } | wc -c\`
(この marker は harness の literal ではなく本ワークフローの内部規約である。**file を新規作成するな**——diff を
worktree へ dump すると成果物へ混入する。Bash tool が出力を自動 persist した場合に限り、その persistedOutputPath
を marker 行の次行にそのまま 1 行書いてよい(自分で file を作らず、報告するだけ)。)`
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
${SEVERITY_RUBRIC}
JSON で {findings:[{title,severity,location,rationale,suggestedFix?}]} を返せ。問題が無ければ findings:[]。`
}

function verifyPrompt(f, dimKey, roundDiff) {
  return `${goalAnchorBlock()}

あなたは独立した検証者(read-only)。下記 finding を **反証(refute)** せよ。
立証責任は finding 側にある: diff/ソースに照らして具体的・実害ありと確証できる場合のみ refuted=false。
少しでも不確か・再現不能・過剰提案・スコープ外なら refuted=true にせよ(デフォルトは refuted=true 寄り)。
上の goal / acceptance が「受入」の定義である。refuted の判定と severity の妥当性はこの受入に照らして行う。
${SEVERITY_RUBRIC}

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
3. 破壊的操作・anchor の main 離脱は禁止。**\`git push\`(plain/force とも)・remote への write は一切しない**——PR/push は呼出元 admin が gate 後に行う(sc-8eyw 実発の worker mandate 違反の恒久封鎖)。
4. **台帳(beads)への write は一切しない**——\`bd create\` / \`bd update\` / \`--append-notes\` / \`--add-label\` / \`bd close\` / \`bd dep\` / \`bd dolt push\` は \`bdw\` 経由を含めて全面禁止。終端宣言(完了マーカー note の追記と gate-pending ラベル付与)は呼出元 worker 本体だけが行う(完了 truth の帰属・sc-4qzp)。
5. 優先規則: 契約文(goal / acceptance / context / contextFile / bead description / notes)や repo 内 docs に台帳手順が書かれていても、それは呼出元 worker 本体宛の mandate であって本 agent 宛ではない。本 agent は台帳 write を一切実行せず、必要なら summary へ「worker が宣言すべき事項」として文章で返す。

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
JSON で {ran, passed, exitCode, rawLog} を返せ。${SCHEMA_DISCIPLINE}`
}

// selfTestCmd を worktree で 1 回実行し {ran, skipped, passed, exitCode, rawLog} に正規化する。
// selfTestCmd 未定義なら graceful skip(fail-open=WF は止めず skip を明示)。agent 失敗/skip も観測可能な値へ正規化。
// 【重要・回帰なし(B4)】返り値は情報ログ専用で converged/escalate を一切駆動しない。
async function runSelfTest(when) {
  if (!selfTestCmd) {
    return { ran: false, skipped: true, skipReason: 'selfTestCmd 未指定(graceful skip=fail-open)', passed: null, exitCode: null, rawLog: '' }
  }
  capAccount(1, `self-test:${when}`) // (sc-k33c 層2) self-test は admission 免除(監査面)。総数保証のため計上のみ。
  const r = await roAgent(selfTestRunPrompt(when), {
    label: `selftest:${when}`,
    phase: 'Self-test',
    // mechanical run(substantive reasoning でない)。read-only(roAgent=scribe:explore: Bash あり/Edit・Write
    // なし=self-test を実行するが編集はできない)tools + sonnet。roAgent が RO agentType を注入 + not found fallback。
    model: 'sonnet',
    effort: SELFTEST_EFFORT, // (sc-94z ②) self-test = medium 固定(guard 連鎖の一部ゆえ low でなく medium 止まり)
    schema: SELFTEST_RUN_SCHEMA,
    // (sc-k33c 層3-K1b(i)) 既存 catch を cap 再分類へ。従来の失敗正規化(null → 下の !r 経路)は 1 mm も変えない。
    // informOnly=true: self-test は **情報ログ専用段**(B4)ゆえ、ここで捕捉した cap 例外は capExceeded /
    // capDropped / capReason を触らず capReport.selfTestExceptions に載せるだけにする(converged/escalate と
    // round gate を監視専用段が反転させない)。
  }).catch(capReclassify(`self-test:${when}`, null, { informOnly: true }))
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

// ── (2) 意味的 args fail-fast(un-8c4 吸収): worker-cell 固有の契約欠落を【agent 起動前】に検出 ────────
// 不変条件: doImplement か autoFix を要求する worker-cell は worktree(scope)と goal/acceptance(契約)を
// 必ず持つ。autoFix 要求時はさらに selfTestCmd(fail-closed ゲート)が要る。欠けたまま走ると scope 不定・
// gate 不在で編集が暴走する(un-8c4: args 未着→全デフォルト化→自動 amend の rabbit-hole)。
//
// (sc-pfn4) ここは canonical block の【外】に置く意味的 fail-fast で、block とは役割が違う:
//   - worktree の「不在」は block(REQUIRED_ARGS)が【無条件】に見る = doImplement/autoFix を伴わない
//     読み取り専用の軽量用途(diff 供給 + single モード)でも worktree は必須になった。すなわち「diff だけ
//     渡す ad-hoc 直叩き経路」は throw で殺される(P0-2 の仕様変更・従来の『ゲート対象外』は撤回)。
//   - block が見られないのは (a) sentinel '(current worktree)' の拒否(block の不在判定は空/undefined/
//     '[undefined]'/空配列しか見ないので sentinel は素通りする=un-8c4 guard の silent 弱体化を防ぐ)、
//     (b) 「goal / acceptance のいずれか」(平坦な AND では表現不能)、(c) autoFix 時のみ必須の selfTestCmd。
//   - 発火条件は isWorkerCell のまま(無条件化しない)。無条件化すると正常 args の positive control でも
//     必ず throw し、engine が二面宣言を機械照合できる走行が 1 つも無くなる(POSITIVE_THROW_UNATTRIBUTED)。
//   - throw の message には canonical marker('[SCARGS fail-fast]')を含めない別 prefix を使う = engine が
//     「preamble 由来の throw」と「骨格固有の意味検証由来の throw」を帰属で弁別できるようにする。
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
    // (sc-pfn4) escalate return 形をやめ throw で run を殺す(P0-2)。return 形は「undefined を掴んだまま完走」を
    // 構造的に止められず、呼出元が返り値を読まない経路では silent に流れる。prefix は canonical marker と
    // 別語にする(engine の帰属弁別面)。agent は 1 体も起動していない。
    throw new Error(
      '[cell-quality args fail-fast] ' + reason + ' 呼出元/人間が args を補って再 invoke すること。 / received=' + JSON.stringify(receivedArgs)
    )
  }
}

// ── 0. Classify(verify 戦略の決定) ────────────────────────────────────────────
phase('Classify')
let verifyStrategy = ''
if (!taskType) {
  capAccount(1, 'classify') // (sc-k33c 層2) classify は admission 免除(監査面)。計上のみ。
  const c = await schemaAgent(roAgent, classifyPrompt(), {
    label: 'classify',
    phase: 'Classify',
    model: stageModel, // roAgent が RO agentType('scribe:explore')注入 + not found fallback(read-only 段)
    effort: CLASSIFY_EFFORT, // (sc-94z ③) classify = medium 固定(誤分類は劣化止まり=gate 捕捉圏内)
    schema: CLASSIFY_SCHEMA,
  }, degClassify) // (sc-j32) SCHEMA_DISCIPLINE 前置 + null/degenerate → null(下の (c && c.taskType) fallback へ合流)
    // (sc-k33c 層3) 無防備 call site: cap 系例外を null(既存 fallback 経路)へ正規化する。非 cap は再 throw=従来どおり。
    .catch(capCatch('classify', null))
  taskType = (c && c.taskType) || 'executable'
  log(`task-type = ${taskType}${c && c.rationale ? ` (${c.rationale})` : ''}`)
} else {
  log(`task-type = ${taskType} (args 指定)`)
}
verifyStrategy = VERIFY_STRATEGY[taskType] || VERIFY_STRATEGY.executable

// ── 1. Plan(任意): 受入基準の導出/精緻化 ─────────────────────────────────────
if (doPlan) {
  phase('Plan')
  capAccount(1, 'plan') // (sc-k33c 層2) plan は admission 4 点に含まれない(実装系)。計上のみ。
  const p = await schemaAgent(roAgent, planPrompt(), {
    label: 'plan',
    phase: 'Plan',
    model: stageModel, // roAgent が RO agentType('scribe:explore')注入 + not found fallback(read-only 段)
    effort: CELL_EFFORT, // (sc-94z ④) plan = cell effort に従う(args.effort=実装系の段に効く cell effort)
    schema: PLAN_SCHEMA,
  }, degPlan) // (sc-j32) null/degenerate → null(下の (p && p.acceptance) で精緻化スキップへ合流)
    // (sc-k33c 層3) 無防備 call site: cap 系例外を null(既存 fallback 経路)へ正規化する。非 cap は再 throw=従来どおり。
    .catch(capCatch('plan', null))
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
  capAccount(1, 'implement') // (sc-k33c 層2) implement は admission 4 点に含まれない(実装系)。計上のみ。
  // (sc-k33c ERRATA-01 B1) roAgent を通らない直呼び段は capAgent(実呼出し計上つき agent)を使う。
  const impl = await capAgent(implementPrompt(refinedAcceptance), {
    label: 'implement',
    phase: 'Implement',
    model: stageModel, // 編集するので roAgent(read-only agentType)を使わず agent() 直呼び(全ツール)
    effort: CELL_EFFORT, // (sc-94z ④) implement = cell effort に従う(args.effort=実装系の段に効く cell effort)
    // (sc-k33c 層3) 無防備 call site: cap 系例外を null(下の impl ? ... : '(no output)' 経路)へ正規化する。
  }).catch(capCatch('implement', null))
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

  // ── (sc-k33c 層2-①) admission 4 点の 1 つ目 = round 頭 ────────────────────────
  // このラウンドの snapshot(免除 1 本)+ review 最低 1 本すら予算に入らないなら round に入らない。
  // round を消費しなかったので rounds カウンタを戻してから抜ける(実行していない round を計上しない)。
  if (!capRoundGate(round)) {
    round--
    break
  }

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
  // (sc-vtf8) この round の snapshot 応答の分類('ok'/'too-large'/'true-empty'/'noncompliant'/''=未実行)。
  // history と escalateReason へ伝播させ、「snapshot が失敗した」だけでなく **どう失敗したか** を呼出元/gate が
  // 直読できるようにする(EMPTY_DIFF と inline 上限超過を同じ文言で報告しないための一次データ)。
  let snapshotKind = ''
  if (!roundDiff || canAutoFix) {
    capAccount(1, 'snapshot') // (sc-k33c 層2) snapshot は admission 免除(監査面)。計上のみ。
    const snap = await roAgent(snapshotPrompt(), {
      label: `snapshot r${round}`,
      phase: 'Review',
      model: stageModel, // roAgent が RO agentType('scribe:explore')注入 + not found fallback(read-only 段)
      effort: SNAPSHOT_EFFORT, // (sc-94z) snapshot = medium 固定(mechanical read-only=git diff 収集・失敗は snapshotFailed 網が gate で拾う=self-test と同区分)
      // (sc-k33c 層3) 無防備 call site: cap 系例外を null(下の snapOk=false → snapshotFailed 網)へ正規化する。
    }).catch(capCatch(`snapshot r${round}`, null))
    // snapshot agent には「生 diff のみ・空なら EMPTY_DIFF の一語」を指示しているが、LLM は説明文を前置しがち
    // (例: "Both (a) and (b) are empty.\n\nEMPTY_DIFF")。exact-match(snap.trim()!=='EMPTY_DIFF')だと説明文付きの
    // 空応答を取りこぼし、roundDiff に説明文が入って snapshotFailed=false → false converged になる(= un-2yy が
    // 塞ぐ当の false-CONVERGED。検証 wf_2cd7cd9d-c45 で実証=説明文付き EMPTY が converged 扱いされた)。よって
    // 「実際の diff 内容を含むか」= 'diff --git' マーカーの有無で頑健に判定する(git diff の非空出力は必ず
    // 'diff --git' を含み、説明文や EMPTY_DIFF 応答には現れない=説明文を前置されても誤判定しない・fail-closed)。
    // (sc-vtf8) 単一値判定(snap.includes('diff --git'))を 3 値契約の分類へ置換する。ok の定義は **不変**
    // ('diff --git' を含むか)ゆえ既存経路の挙動は変わらず、失敗側だけが too-large / true-empty / noncompliant
    // へ弁別される(下の snapshotFailed 網の分岐条件も不変=どの失敗 kind でも fail-closed のまま)。
    snapshotKind = classifySnapshot(snap)
    const snapOk = snapshotKind === 'ok'
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
  // (sc-vtf8) 短絡自体は 3 kind 共通(対象が inline で得られない以上、roundDiff='' で reviewer を彷徨わせない)。
  // 変えるのは **log の名乗り** だけ: 「レビュー対象不在」を名乗ってよいのは true-empty のみ。
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
      snapshotKind,
    })
    log(
      snapshotKind === 'true-empty'
        ? `round ${round}: snapshot=EMPTY_DIFF(レビュー対象不在) → review を起動せず escalate(un-2yy 最小コスト)`
        : `round ${round}: snapshot=${snapshotKind}(レビュー対象不在ではない) → review を起動せず escalate。${snapshotKindNote(snapshotKind, staticDiffProvided)}`
    )
    break
  }

  // perspective-diverse review(並列) → 各 finding を独立に refute-verify(pipeline; barrier 無し)
  // F1/F2/F3: agent() は skip/terminal death では null を返すが、schema 検証枯渇/stall では throw しうる。
  // throw を放置すると pipeline/parallel が要素を null 化し filter(Boolean) が握り潰す(痕跡ゼロの silent 縮退)。
  // → review/verify の両方に .catch を付け、失敗を「観測可能な値」へ正規化する:
  //   - review throw → {findings:[], __reviewFailed:true}(null 返却と合わせて「観点欠落」として集計)
  //   - verify throw → {...f, verdict:null}(unverified に乗せ、本物 blocking の消滅を防ぎ unvNote を立てる)
  // ── (sc-k33c 層2-②) admission 4 点の 2 つ目 = review 前【all-or-nothing】────────
  // fence(K8「dimensions 削減は不採用」)と先行裁定 un-mpv/un-aq5(上の dimensions 定義直下のコメント)に従い、
  // **観点は 1 つも切り捨てない**。旧実装は dimensions.slice(0, admitted) で配列末尾から切っており、配列順が
  // 「必須4 → worker が --add-dimension で明示指定した追加観点」ゆえ、予算逼迫時に最初に消えるのがユーザー
  // 意図の追加観点と completeness-critic という、まさに un-aq5 gate F1 で撤廃された挙動を復活させていた
  // (「配列そのものは削らず本数だけ絞る」は挙動上同一の言い換え)。加えて args 供給の totalBudget が D3/D4 の
  // 「admin gate は必須4観点固定」floor を縮める経路になっていた。
  // → 全観点分の枠が確保できなければ **この round に入らない**(幅の制御は verify 側 quota に閉じる)。
  const __capReviewAdmitted = capAdmit(dimensions.length, 'review', round)
  if (__capReviewAdmitted < dimensions.length) {
    capBooked -= __capReviewAdmitted * capCallCost() // 部分 admit は使わないので【予約】を戻す(実呼出しは capCountCall が数えるので spentEstimate には影響しない)
    capDropRound(round, 'budget-drop')
    log(`[cap] review r${round}: 全 ${dimensions.length} 観点分の枠(admit=${__capReviewAdmitted})が確保できないため観点を切り捨てず round を打ち切る(dimensions 削減は不採用の裁定=K8 fence)。落とした round 分は capDropped[]。`)
    break
  }
  const roundDims = dimensions
  // ── (sc-k33c 層2-③) admission 4 点の 3 つ目 = verify 前の観点別【固定枠】 ────────
  // 共有カウンタ先着順にしない(到着順で食い合うと stage1 の解決順で admit 集合が変わり非決定になる)。
  // round 頭で残量を観点数で等分した固定枠を配るので、解決順を入れ替えても admit 集合は同一(K1c 決定論)。
  const verifyQuota = capVerifyQuotaPerDim(roundDims.length)
  // (sc-k33c 層3) pipeline 呼出し【自体】の入口 throw を try/catch で包む(.catch だけでは同期 throw を
  // 取りこぼす)。cap 系なら「観点は落とした」として capDropped[] へ列挙し reviewFailed は立てない(誤帰属封鎖)。
  // 非 cap は capCatch が再 throw する = 従来どおり run が死ぬ(現状維持)。
  let perDim
  try {
    perDim = await pipeline(
    roundDims,
    (d) =>
      schemaAgent(runAgent, reviewPrompt(d, round, roundDiff), {
        label: `review:${d.key} r${round}`,
        phase: 'Review',
        model: reviewModel, // 既定=MODEL(opus)。fable 指定時のみ runAgent が ≤2 cap を適用。runAgent 内 roAgent が RO agentType 注入 + fallback
        effort: reviewEffort, // (sc-94z ①) review = guard 段ゆえ既定 high 固定(cell effort 一括下げから独立)・reviewEffort knob で xhigh opt-in
        schema: FINDINGS_SCHEMA,
        // (sc-k33c 層3-K1b(i)) 既存 catch を cap 再分類へ。従来の正規化値(__reviewFailed)は 1 mm も変えない。
      }, degFindings).catch(capReclassify(`review:${d.key}`, () => ({ findings: [], __reviewFailed: true }))), // (sc-j32) null/degenerate → null → 下の reviewFailed=!review へ合流(machinery 失敗=escalate)
    async (review, d) => {
      // review が null(skip/枯渇)/__reviewFailed(throw)のいずれも「観点が実行できなかった」=痕跡を残す。
      const reviewFailed = !review || review.__reviewFailed === true
      const findings = (review && review.findings) || []
      // (sc-k33c 層2-③) 縮退順(perRoundVerifyTopK → critical/major 限定 → severity top-K → loud drop)を
      // 観点単位の固定枠で適用する。落とした finding は capDropped[] へ列挙し **unverified には積まない**
      // (verdict 取得失敗=unverified と、そもそも verify を起動しなかった=capDropped は別事象・二重計上しない)。
      const admitted = capSelectVerify(findings, d.key, round, verifyQuota)
      // (sc-k33c 層3-K1b(ii)) parallel 呼出し【自体】の入口 throw を catch で包む。包まないと cap 例外が
      // pipeline に要素 null 化として吸われ、上の dimResults フォールバックで reviewFailed=true へ **誤帰属**
      // する(review は成功していたのに「観点が実行できなかった」と記録される)。cap 系は reviewFailed を
      // 立てずに verified:[] で返し、非 cap は再 throw して従来経路(pipeline の null 化)を 1 mm も変えない。
      let verifiedArr
      try {
        verifiedArr = await parallel(
        admitted.map((f) => () =>
          schemaAgent(runAgent, verifyPrompt(f, d.key, roundDiff), {
            label: `verify:${d.key}:${shortTitle(f)} r${round}`,
            phase: 'Verify',
            model: verifyModel, // 既定=MODEL(opus)。fable 指定時のみ runAgent が ≤2 cap を適用。runAgent 内 roAgent が RO agentType 注入 + fallback
            effort: verifyEffort, // (sc-94z ①) verify = guard 段ゆえ既定 high 固定(cell effort 一括下げから独立)・verifyEffort knob で xhigh opt-in
            schema: VERDICT_SCHEMA,
          }, degVerdict) // (sc-j32) null/degenerate → null → verdict:null(unverified=verdict 鵜呑み禁止へ合流)
            .then((v) => ({ ...f, dimension: d.key, verdict: v }))
            // (sc-k33c 層3-K1b(i)) 既存 catch を cap 再分類へ。従来の正規化値(verdict:null)は変えない。
            // (sc-k33c errata) alreadySurfaced=true: この finding は verdict:null → **unverified[] に載る**
            // ので capDropped[] へは積まない(二重計上禁止=K3-3)。積むと severity='unknown' が
            // droppedBlocking を押し上げ、cap を一切頼んでいない既定路の終端が CONVERGED→ESCALATE へ
            // 反転する(K1 項目5「blocking 級を落とした時のみ escalate」違反・base 対照で実測)。
            .catch(capReclassify(`verify:${d.key}`, () => ({ ...f, dimension: d.key, verdict: null }), { alreadySurfaced: true }))
        )
        )
      } catch (e) {
        // (sc-k33c ERRATA-01 B5) 判定は SCCAP ブロック内の capCatchSync に一本化する(旧実装はここで capCatch の
        // 中身を再実装し capClassify を 2 度呼んでいた)。cap 系なら reviewFailed を立てずに verified:[] で返し
        // (誤帰属封鎖)、非 cap は capCatchSync が再 throw する = 従来どおり pipeline が要素を null 化する。
        return capCatchSync(`verify-entry:${d.key}`, () => ({ dimension: d.key, reviewFailed, verified: [] }))(e)
      }
      return { dimension: d.key, reviewFailed, verified: verifiedArr.filter(Boolean) }
    }
    )
  } catch (e) {
    perDim = capCatch('pipeline', () =>
      roundDims.map((d) => {
        capDrop('review', d.key, `(観点 ${d.key} を pipeline 入口 throw で落とした)`, 'unknown', 'entry-throw')
        return { dimension: d.key, reviewFailed: false, verified: [] }
      })
    )(e)
  }

  // pipeline 要素が万一 null(stage2 自体の脱落)でも観点欠落として扱う(no-op-without-trace を作らない)。
  const dimResults = perDim.map((r, i) =>
    r || { dimension: (roundDims[i] && roundDims[i].key) || `dim${i}`, reviewFailed: true, verified: [] }
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
    snapshotKind, // (sc-vtf8) どう失敗したか('ok'/'too-large'/'true-empty'/'noncompliant'/''=snapshot 未実行)
  })
  log(
    `round ${round}: blocking=${blocking.length} minor=${minor.length} refuted=${refuted.length} unverified=${unverified.length} reviewFailed=${reviewFailedCount} snapshotFailed=${snapshotFailed}${snapshotKind ? ` snapshotKind=${snapshotKind}` : ''}`
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

  // ── (sc-k33c 層2-④) admission 4 点の 4 つ目 = fix 前 ─────────────────────────
  // fix 1 本すら予算に入らないなら fix を起動せず打ち切る。confirmed blocking を抱えたまま落とすので
  // これは必ず blocking 級 drop(= 後段 terminal で escalate)になる。silent に「修正済み」へ倒さない。
  // 【到達性の明示(sc-k33c errata)】この分岐は **通常は到達しない防御的 guard** である: capVerifyQuotaPerDim
  // が `reserveFix = canAutoFix ? 1 : 0` を先に差し引いてから観点別枠を floor 分配するため、verify を通って
  // blocking が生まれた時点で fix 用の 1 本が必ず残る(totalBudget=4..30 を全掃引しても本 log は 0 hit)。
  // つまり K1 が数える admission 4 点のうち fix 前の実効保証は **reserve 側(reserveFix)** が担っており、
  // ここは reserve が将来壊れた場合に silent ship させないための二重化。teeth は reserve 側に置く
  // (「予算が逼迫しても fix 1 本は必ず確保される」の behavioral pin)。
  if (capAdmit(1, 'fix', round) < 1) {
    for (const f of blocking) capDrop('fix', f.dimension || '', f.title, f.severity, 'budget-drop')
    log(`[cap] fix r${round}: 予算不足で autoFix を起動できない(confirmed blocking=${blocking.length} 件を未修正のまま残す)。収束は主張しない。`)
    break
  }

  // gated autoFix: confirmed blocking のみ + self-test fail-closed + amend
  phase('Fix')
  // (sc-k33c ERRATA-01 B1) runner は capAgent(実呼出し計上つき)= schemaAgent 経由でも計上が漏れない。
  const fix = await schemaAgent(capAgent, fixPrompt(blocking, roundDiff), {
    label: `autofix r${round}`,
    phase: 'Fix',
    model: stageModel, // 編集するので roAgent(read-only agentType)を使わず agent() 直呼び(全ツール)
    effort: FIX_EFFORT, // (sc-94z ①) fix = guard 段ゆえ high 固定(knob 無し・cell effort 一括下げから独立)
    schema: FIX_SCHEMA,
  }, degFix) // (sc-j32) null/degenerate(summary=test 等)→ null → 下の if(!fix) escalate へ合流(fail-closed)
    // (sc-k33c 層3) 無防備 call site: cap 系例外を null(既存の escalate 経路)へ正規化する。非 cap は再 throw。
    .catch(capCatch(`autofix r${round}`, null))
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
  // ── (sc-pyab 系統A) hard cap 到達は「未収束」の同義ではない ──────────────────────
  // 旧実装は「zeroStreak >= 2 に至らないまま cap へ到達」を一律 escalate にしていた。しかし最終 round が
  // **真にクリーン**(blocking 0 かつ machinery 健全)だった run は、単に「2 度目のゼロを確認する round が
  // 残っていなかった」だけであり、cap があと 1 round 多ければ converged していた。この構造欠陥で「直す対象が
  // 無いのに ESCALATE」が量産されていた(本 anchor 実測 3 例: sc-4qzp / sc-k33c 本体 / sc-k33c ERRATA 前。
  // 正本 scm-qrqg・folio-coas でも独立観測)。
  // 昇格は次の連言でのみ立てる(literal な `lastH.confirmedBlocking === 0` の単独条件で立ててはならない
  // = machinery 失敗 round の 0 blocking を「クリーン」と誤読して silent ship する):
  //   (i)  hard cap へ **自然到達**した最終 round であること(round >= effectiveCap かつ cap 由来の早期打切り
  //        でない)。cap 早期打切り run・snapshot EMPTY_DIFF break の run は「最終 round」ではない。
  //   (ii) その round の blocking が 0 / (iii) その round の machinery が健全(reviewFailed=0 かつ snapshotFailed=false)。
  // (ii)(iii) は zeroStreak が既に含意する: zeroStreak は `blocking.length === 0 && !machineryFailed` の
  // round でのみ ++ され、それ以外の全経路で 0 へ戻る ⇒ 「zeroStreak >= 1」= 直近 round は真にクリーンだった。
  // ゆえに最小差分は「hard cap 到達時は zeroStreak >= 1 を converged とみなす」形にする(数値既定 maxRounds=3 /
  // zeroStreak >= 2 は不変・構造のみ変更)。
  // 挿入位置は **capFinalize 呼出より前**(後置すると capExceeded → converged=false の強制を上書きし fence 違反。
  // 前置なら「最終 round は clean だが capExceeded」の run は capFinalize が converged を落とす=fail-closed 維持)。
  // ── 昇格を **狭める** 2 つの連言(新規の閾値・回数定数は導入しない=数値決め打ち禁止を守る) ──
  // (A) `!capExceeded`: capFinalize は capExceeded の run で converged を false へ戻すが、escalate は
  //     droppedBlocking>0 のときしか立てない。ゆえに昇格が converged=true を立てると **直下の escalate 網
  //     (zeroStreak < 2)が丸ごと skip され**、capFinalize で converged だけが剥がれて converged=false ∧
  //     escalate=false = gatePrefix OPEN(sc-k33c errata が封鎖した loop-mode fail-open)へ落ちる。
  //     実測(cap 引数なしの既定路・verify 1 観点に quota 例外・最終 round clean): base=ESCALATE / 昇格のみ=OPEN。
  //     cap 発火 run は「幅を落として走った」= 真にクリーンだと主張できないので昇格の対象外にする。
  // (B) `!(lastH.unverified > 0)`: zeroStreak が含意する machineryFailed は reviewFailed / snapshotFailed だけで
  //     **verify 段の失敗を含まない**。verify agent が非 cap 例外で全滅した round は verdict:null → unverified 行き
  //     ゆえ confirmed=0 になり、blocking 0 ∧ machineryFailed false で「真にクリーン」と誤読される。
  //     unverified が残る round は「反証機構が動いた結果の 0」ではないので昇格しない(fail-closed)。
  if (!converged && !escalate && !capExceeded && round >= effectiveCap && !capTerminatedEarly(round, effectiveCap) && zeroStreak >= 1 && !(lastH.unverified > 0)) {
    converged = true
    log(
      `収束(系統A): hard cap ${effectiveCap} 到達だが最終 round は真にクリーン(zeroStreak=${zeroStreak}・blocking=0・machinery 健全)` +
        `= 「2 度目のゼロを確認する round が残っていなかった」だけであり未収束ではない。`
    )
  }
  // loop モード: zeroStreak>=2 で converged 済み。未達 & cap 到達なら escalate(silent ship 禁止)。
  // F3/F4: machinery 失敗で真にクリーンな round を確保できなかった場合も同じく escalate へ倒す。
  // (sc-k33c errata) `round >= effectiveCap` だけだと **cap 由来の早期打切り**(round gate / review 前
  // all-or-nothing / fix 前 admission による break)が hard-cap 網を迂回し、未修正 confirmed blocking を
  // 抱えたまま converged=false かつ escalate=false という base に存在しなかった終端状態へ落ちる。
  // cap で早期に打ち切った未収束 loop run は「hard cap 到達・未収束」と同じ強度で扱う(silent ship 禁止)。
  if (!converged && !escalate && (round >= effectiveCap || capTerminatedEarly(round, effectiveCap)) && zeroStreak < 2) {
    escalate = true
    // un-2f1: snapshot 空が全 round で続いた = Implement/Fix が round1 で commit し `git diff HEAD` が空になった
    // 可能性が高い(snapshot は base...HEAD 合成へ移行済だが、base 推定が外れる/commit が base より前等の縁では
    // なお空になりうる)。escalateReason に「snapshot 空=commit 済の可能性」ヒントを含め、既知 artifact かどうかを
    // 呼出元が見分けられるようにする(un-x3o/un-iur の false-escalate の見分け)。
    const allSnapFailed = history.length > 0 && history.every((h) => h.snapshotFailed)
    // (sc-vtf8) 「snapshot 空=commit 済の可能性」ヒントを名乗ってよいのは **true-empty のみ**。inline 上限超過
    // (差分は在る)や非 compliant 応答(有無が未確定)でこれを名乗ると偽の一次診断になる(bd sc-vtf8 notes (2))。
    const lastSnapKind = lastH.snapshotKind || ''
    const allSnapTrueEmpty = allSnapFailed && history.every((h) => h.snapshotKind === 'true-empty')
    const why =
      lastH.reviewFailed || lastH.snapshotFailed
        ? `review/snapshot machinery 失敗(reviewFailed=${lastH.reviewFailed || 0}, snapshotFailed=${!!lastH.snapshotFailed}${lastSnapKind ? `, snapshotKind=${lastSnapKind}` : ''})で真にクリーンな round を確保できず` +
          (!lastH.snapshotFailed
            ? ''
            : lastSnapKind === 'too-large' || lastSnapKind === 'noncompliant'
              ? `。${snapshotKindNote(lastSnapKind, staticDiffProvided)}`
              : allSnapTrueEmpty
                ? `。全 round で snapshot 空=実装/修正が既に commit 済の可能性が高い(base...HEAD 合成でも空=base 推定要確認・既知 artifact かを findings 直読で判断)`
                : `。snapshot 空=commit 済 or レビュー対象不在の可能性`)
        : `critical/major が 2 連続ゼロに至らず`
    // (sc-k33c ERRATA-01 B5) 文言生成は SCCAP ブロック内の capLoopEscalate が持つ(cap 由来の早期打切りと
    // hard cap 到達の弁別もそこ)。ここは結果を使うだけ = cap の判定コードがブロック外へ散らない(K8)。
    escalateReason = escalateReason || capLoopEscalate(round, effectiveCap, why)
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
    // (sc-vtf8) single モードも同じ規律: 「EMPTY_DIFF=レビュー対象不在」を名乗るのは true-empty のときだけ。
    // too-large(差分は在るが inline 返却不能)/ noncompliant(有無が未確定)は専用の中立文言へ分岐する。
    const lastSnapKind = lastH.snapshotKind || ''
    escalateReason =
      escalateReason ||
      `single モード: blocking=0 だが machinery 失敗(reviewFailed=${lastH.reviewFailed || 0}, snapshotFailed=${!!lastH.snapshotFailed}${lastSnapKind ? `, snapshotKind=${lastSnapKind}` : ''})。` +
        (lastH.snapshotFailed
          ? snapshotKindNote(lastSnapKind, staticDiffProvided)
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

// ── (sc-k33c) cap の terminal 判定 + fail-loud 表面の確定 ────────────────────────
// 判定ロジックは SCCAP ブロック内の capFinalize に閉じている(K8)。ここは「self-test final まで走り終えた
// 時点で 1 回呼び、返り値を適用する」だけの薄い呼出サイト = cap 判定コードがブロック外へ散らない。
const capFinal = capFinalize({ converged, escalate, escalateReason })
converged = capFinal.converged
escalate = capFinal.escalate
escalateReason = capFinal.escalateReason
const capReport = capFinal.capReport
const capDroppedBlocking = capFinal.capDroppedBlocking

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
  // (sc-vtf8) snapshot inline 上限(0=未指定=弁別なし)。escalateReason の too-large 分岐が「何 bytes を超えたと
  // 主張しているのか」を呼出元/gate が args を再構成せずに直読できるようにする(監査面)。
  snapshotInlineLimitBytes,
  autoFix: canAutoFix,
  reviewModel, // per-stage model(既定=MODEL)。監査用に明示
  verifyModel,
  effort: effortSummary, // (sc-94z) per-stage effort 要約{cell,review,verify,fix,classify,selfTest,snapshot}。呼出元監査用(guard 段が high か直読)
  reviewEffort, // (sc-94z) review 段の解決 effort(既定 high・knob 上書き可)。監査用に明示
  verifyEffort, // (sc-94z) verify 段の解決 effort(既定 high・knob 上書き可)
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
  // (sc-j32) schema 強制 agent の健全性(retry 超過の null 死 / placeholder 試し打ち検知)。receivedArgs と対称の
  // 一次監査面: 非空なら当該 schema agent の出力は不採用(既存の失敗経路へ倒れている)=呼出元/gate が人手確認する。
  schemaHealth: { nullDeaths: schemaHealth.nullDeaths.slice(), degenerate: schemaHealth.degenerate.slice() },
  // (sc-k33c) 3 層 cap の fail-loud 表面。capExceeded=true の run は「幅を落として走った」= converged を
  // 立てない。capDropped[] は **unverified とは別枠**(verdict 取得失敗 ≠ そもそも verify を起動しなかった)。
  capExceeded,
  capReport,
  capDropped,
  roFallbackActive, // (sc-7bv/sc-xyw) read-only agentType fallback が最終的に発火したか(true=agentType 解決不能で降格した run)。receivedArgs.roAgentType は「解決した型」だけで発火有無は読めないため別途載せる。
}

// admin 薄 gate の指針(再 review はしない)。unverified(verdict 取得失敗/throw)や machinery 失敗が
// あれば converged でも人手確認が要る = silent ship させない注記を必ず付ける。
const unvNote = allUnverified.length ? ` ※unverified=${allUnverified.length} は要人手確認(verdict 鵜呑み禁止)。` : ''
const machNote =
  lastH.reviewFailed || lastH.snapshotFailed
    ? ` ※machinery 失敗(reviewFailed=${lastH.reviewFailed || 0}, snapshotFailed=${!!lastH.snapshotFailed})= この round の blocking=0 は信頼不可、人手確認。`
    : ''
// (sc-j32) schema 強制 agent の retry 超過 null / placeholder 試し打ちが起きた run は、当該 agent の出力が不採用
// (既存の失敗経路へ倒れている)=収束/escalate に関わらず注記して silent ship させない。
const schemaNote =
  schemaHealth.nullDeaths.length || schemaHealth.degenerate.length
    ? ` ※schema 健全性: nullDeaths=${schemaHealth.nullDeaths.length}, degenerate=${schemaHealth.degenerate.length}(StructuredOutput の retry 超過/試し打ち検知=当該 agent の出力は不採用・schemaHealth を直読して人手確認)。`
    : ''
// (sc-k33c) 4 つ目の note。文言生成は capFinalize(SCCAP ブロック内)が持ち、ここは 3 分岐へ連結するだけ。
// cap が発火した run は幅を落として走った=見ていない観点/finding が在るので、収束/escalate に関わらず注記して
// silent ship させない(unvNote/machNote/schemaNote と同じ思想)。連結位置は schemaNote の【直後・末尾】で、
// CONVERGED/ESCALATE/OPEN の prefix と本文は不変。
const capNote = capFinal.capNote
result.gate = escalate
  ? 'ESCALATE: 未収束/self-test 失敗/machinery 失敗。silent ship 禁止 — 人間が判断すること。' + unvNote + machNote + schemaNote + capNote
  : converged
    ? 'CONVERGED: 収束。人間 ratify が要るのは 3 クラス(消す/出す/使う)該当時のみ(＋ acceptance snapshot mismatch は protocol §5.4(c) の独立 fail-closed としてそのまま人間 ratify 昇格)、非該当は AI 敵対 gate 通過をもって AI 判断で merge。gate 分離は不変(worker は自己 merge しない)。収束証跡は呼出元が直読して一次監査。' + unvNote + machNote + schemaNote + capNote
    : 'OPEN: 呼出元が confirmed を修正し再 invoke(single モードのループ駆動)。' + unvNote + machNote + schemaNote + capNote

log(`cell-quality done: ${result.gate}`)
return result

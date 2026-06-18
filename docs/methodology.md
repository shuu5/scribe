# scribe ワークフロー方法論（汎用方法論 home）

> **このファイルの位置づけ**
> scribe で multi-agent ワークフロー（戦術 fan-out・gate review/verify・調査 sweep 等）を**どの強度で・どんな品質パターンで・どう回すか**の方法論を蓄積する SSOT。
> orchestration の **how（admin が踏む手順）= `docs/protocol.md`** / 設計の **why = `docs/scribe-design.md`** / **方法論（強度の選び方・パターンの組み方・戦術層 D1-D7 の運用）= 本書**、で三分する。
>
> **「転記でなく参照」の規律**: 品質パターンの**機械的フック**（`agent()`/`parallel()`/`pipeline()`/`schema`/loop の書き方）は **Workflow tool 自身が SSOT**、**凍結された適用形**は `~/.claude/workflows/cell-quality.workflow.js` が SSOT、**モデル階層ルーティング**は `~/.claude/CLAUDE.md`「Workflow モデル階層ルーティング」節が SSOT、**D1-D7 の決定全文**は doobidoo `e5d79cc9` + 設計 why は scribe-design.md §18 が SSOT。本書はそれらの実体を**転記せず**、「いつ・どの強度で・どのパターンを選ぶか」という判断の方法論だけを蓄積する（蓄積庫であって複製庫ではない＝ドリフト防止）。
>
> **信頼度の凡例**: `verified`（実機で確認済）/ `deduced`（実証ログ・spec から導出）/ `inferred`（推測）。

---

## 1. ultracode 強度キャリブレーション（規模 × 不確実性 × リスク）

ultracode（multi-agent fan-out で網羅性・確信度・スケールを買う運用）は、**全部入り＝最善ではない**。fan-out は wall-clock でなく **rate（5h 枠）と token を実消費する**ため、案件に対して強度を**意識的に選ぶ**のが方法論の核心。3 軸で見積もる:

| 軸 | 何を測るか | 上げると効く対象（lever） |
|---|---|---|
| **規模（scale）** | 触る面積・サイト数・読む量（files / 探索空間の広さ） | **fan-out の幅**（finder 数 / `pipeline()` の item 数 / 探索 sweep の modality 数） |
| **不確実性（uncertainty）** | 解空間の未知さ・false finding の出やすさ・「これで網羅したか」の自信のなさ | **検証の深さ**（single-vote → 3〜5 票 adversarial → perspective-diverse）+ **loop-until-dry** の収束回数 |
| **リスク（risk）** | blast radius・不可逆性・outward 性（規約変更・全ホスト配布・外部公開） | **gate の厳しさ**（read-only gate・merge 前ユーザー確認・refute 多数決の閾値・completeness critic） |

**運用ヒューリスティック**（Workflow tool 方法論 + un-8q5 pilot 実測の統合）:

- 「とりあえずバグを見て」級（小規模・低不確実・低リスク）→ **finder 少数 + single-vote verify**。fan-out を盛らない。
- 「徹底監査して」「網羅的に」級（広規模・高不確実・高リスク）→ **finder pool を厚く + 3〜5 票 adversarial verify + synthesis 段 + completeness critic**。
- **research / review / audit 系は thoroughness 寄り、quick check 系は brevity 寄り**に倒すのが既定。迷ったら規模×不確実性×リスクのどれが効いているかに戻る。
- **「ユーザーが要求した強度に合わせる」が上限**: ultracode はユーザーの明示 opt-in（"ultracode" キーワード / 直接依頼 / それを呼ぶ skill）がある時だけ。opt-in なしで強度を勝手に盛らない（コスト事故になる）。

**コスト現実（verified・un-8q5 pilot 2026-06-10）**: **fable を verify 段に投入した（≤2 cap 遵守）gate review/verify ×2** で **5h rate を 53%→80% まで消費**した実測がある（doobidoo `c06ab15b` milestone / `6d11f667` GOTCHA）。この 53→80% は **fable 起因のコスト**（fable は実コストが 2×Opus 超 = tokenizer 差）で、≤2 cap でも重かったことが **dynamic WF からの fable 全廃（§4）の根拠**になった数値である — **現在の opus 経路の gate コストとは別物**として読むこと（27pt をそのまま opus gate×2 のコストと誤読しない）。いずれにせよ **fan-out の本数・票数・loop 回数はすべて rate を食う**ので、**強度キャリブレーション = rate 予算の配分**である。token 予算を loop 条件に使う dynamic scaling（Workflow tool の `budget` 機能＝loop-until-budget・§2）がその制御点（**具体 API シグネチャは Workflow tool が SSOT・本書は転記しない**）。

> 一次出典: Workflow tool 方法論（"Scale to what the user asked for"・quality patterns）/ doobidoo `c06ab15b`（un-8q5 pilot milestone・rate 53→80%）・`6d11f667`（un-8q5 GOTCHA）/ doobidoo `e5d79cc9`（2026-06-15 grill: 強度キャリブレーション = 規模×不確実性×リスク）。

---

## 2. quality patterns（カタログ）

multi-agent で「網羅性・確信度・スケール」を買うための組み方の語彙。**機械的フックの SSOT は Workflow tool（`agent`/`parallel`/`pipeline`/`schema`）と cell-quality WF（凍結された適用形）**。本書は各パターンを**いつ選ぶか**だけを蓄積する。

| パターン | 効く軸 | いつ選ぶか（方法論） |
|---|---|---|
| **adversarial verify** | 不確実性 | finding ごとに独立 skeptic を N 体立て、**反証（refute）を default** にして多数決で殺す。plausible-but-wrong を本線へ通さない。cell-quality の verify 段がこれ。 |
| **perspective-diverse verify** | 不確実性 | finding が複数の壊れ方をするとき、N 体を同一でなく**別レンズ**（correctness / security / repro / perf）で検証。冗長より多様で failure mode を広く拾う。 |
| **judge panel** | 規模（解空間が広い設計） | 異なる角度（MVP-first / risk-first / user-first）の独立案を N 本生成 → 並列 judge で採点 → 勝者から合成 + 次点の良所を graft。一発生成の反復より広い解空間を当てる。 |
| **loop-until-dry** | 不確実性（未知サイズの発見） | バグ・エッジケース等**個数が読めない発見**で、K 連続ラウンド「新規ゼロ」まで finder を回す。単純な `count < N` は tail を取りこぼす。**dedup は `seen` に対して**行う（`confirmed` に対してやると却下済みが毎回再来して収束しない）。 |
| **multi-modal sweep** | 規模（探索の広さ） | 一つの検索角度では拾えないとき、by-container / by-content / by-entity / by-time 等**互いに盲目な複数角度**を並列に。 |
| **completeness critic** | リスク（見落とし） | 最終段で「何が欠けているか — 走らせていない modality・未検証の主張・未読のソース」を問う agent。出たものが次ラウンドの作業。 |
| **no silent caps** | リスク（誠実性） | top-N / no-retry / sampling で網羅を切ったら必ず `log()` で**何を落としたか**を出す。silent truncation は「全部見た」と誤読される。 |

**合成の既定形**（cell-quality WF が体現する shape）: `task-type routing → [Plan] → [Implement] → perspective-diverse review → 各 finding を独立 agent が adversarial refute-verify → gated autoFix（confirmed のみ + self-test fail-closed + amend）→ loop-until-dry 収束`。これは「find → verify を pipeline で、dimension ごとに review が終わり次第 verify が走る（barrier を置かない）」の典型で、barrier（`parallel()` で全段同期）は**全 finding を一度に必要とする時だけ**（dedup・0 件 early-exit・相互参照）正当化される。

**consult fan-out（pre-bake・session 級）**: 上表・上記は WF agent のパターン。これと別に、人間判断待ちの **needs-user タスクが複数（≥2）溜まったとき**、各タスクを 1 つの **consult main-loop セッション**が並列に pre-bake（現状調査 → 決定木 → 選択肢 + トレードオフ → doobidoo brief）→ admin 集約 → 人間は **admin の場で** grill に集中（grill トポロジ = 案 B・consult は pre-bake 専任で対話 grill に入らない）、という **session 級 fan-out** がある（WF agent と混同しない）。いつ選ぶか = needs-user バックログの throughput。手順 SSOT = `protocol.md` §7（dogfood 実証済み: sc-in9）。

> 一次出典: Workflow tool 方法論（quality patterns / composing patterns / pipeline vs barrier）/ `~/.claude/workflows/cell-quality.workflow.js`（凍結された適用形）。

---

## 3. D1-D7 運用方法論（戦術層の回し方）

scribe の worker/workflow を**2 層**で捉える（doobidoo `e5d79cc9`・2026-06-15 grill 確定）:

- **背骨層（確定済・設計余地なし）**: worker = 独立した完全な対話 CC セッション + persona/契約プロンプト + beads。**worker 自身が実装する**（「workflow ファイルを渡される agent」ではない）。scribe-design.md §3/§12 の verified 事実。
- **戦術層（設計余地・D1-D7 で確定）**: worker タスク**内**の bounded な fan-out（cell-quality gate / 調査 sweep 等）をどう組むか。動的 ultracode は**禁止ではないが背骨でもない** — 戦術 fan-out 限定。

D1-D7 は戦術層の**運用方法論**。決定の why は scribe-design.md §18、決定全文は doobidoo `e5d79cc9`（本書は運用面だけを蓄積・転記しない）:

- **D1 戦術層の背骨 = ハイブリッド**: 不変骨格（cell-quality.workflow.js）+ worker が args 供給。動的 ultracode は bounded 戦術 fan-out のみで背骨にしない。→ **運用**: 新しい品質要件は「骨格を書き直す」前に「args で差せないか」を先に問う（`~/.claude/CLAUDE.md`「Workflow 骨格の再利用」と整合）。
- **D2 opus 並列 cap = args 化**: `A.maxConcurrency` + 安全既定で渡せるようにする（`makeLimiter` は既に max 引数の汎用セマフォ。現状 opus 経路は無 cap で harness の `min(16, cores-2)` が実効上限）。→ **運用**: rate 逼迫時は cap を明示で絞る（cap 注入は **S2 = bd の実装課題**・本 S1 時点では未配線）。
- **D3 dimensions 権限 = 枠分業**: `dimensions` は `{key, focus}` 配列・長さ = review agent 数。**admin gate = 必須 4 観点固定**（correctness / robustness-security / integration-ops / completeness-critic）+ 上限固定。**worker 自己点検 = 4 必須 + focus 調整 + 追加観点可**。→ **運用**: admin は固定 4 を崩さない、worker はタスク特性で focus を寄せ追加レンズを足す。
- **D4 固定/可変境界 = 両方**: **絶対不変**（read-only な doPlan/doImplement/autoFix・収束硬化・demoteFable）は **WF 本体にハードコード維持**、**固有合成**は**外部ラッパー**（`scripts/scribe-gate-args.sh` 型）。→ **運用**: 一次監査の不変条件（gate が実装/autoFix に化けない）をラッパーで上書きさせない。
- **D5 汎用/固有の写像**: 骨格（cell-quality.workflow.js）+ 汎用ラッパー（gate-args）= **scribe**（`~/.claude/workflows`・全 project 共有）。固有「**データ**」（selfTestCmd・追加 dimensions・probe）= **project**（CLAUDE.md or project 設定）。→ **運用**: ラッパーの**ロジックは汎用**、固有なのは**データだけ**。固有ロジックを骨格へ混ぜない。
- **D6 per-project WF ファイル = 不要**: 汎用 1 本 + args/ラッパーで吸収する。骨格自体（フェーズ順序・ループ流れ）が違う要件が将来出たら作る留保（その時 (3)昇格 か (2)二層 を判断）。→ **運用**: 「project 専用 WF を切りたい」衝動は、まず args/ラッパーで足りるかを潰してから。
- **D7 ready-compaction = run 固有の WF 呼出を参照保持**: run 固有の WF 呼び出し（`scriptPath` + args）は Working Memory「命令・制約」節に `[auto]` 参照として残す（新 carrier を足さない＝責務境界を壊さない）。durable な project 固有は CLAUDE.md carrier、骨格は git carrier。

**呼び出しの2系統**（同じ骨格・別文脈）: ① **worker 自己点検** = worker がタスク内で cell-quality WF を `autoFix:true` で 1 回直接呼ぶ（named-WF 明示・`scriptPath` 直指定）。② **admin gate** = admin が funnel（protocol.md §5）で **read-only**（doPlan/doImplement/autoFix を固定 off）で worktree 指定呼出。**返り値 JSON + `receivedArgs` を呼出元が一次監査する**のが薄 gate 設計の肝（args 解決の成否を机上でなく値で確認する）。

> 一次出典: doobidoo `e5d79cc9`（D1-D7 決定全文・2 層モデル）/ scribe-design.md §18（設計 why）/ §12（worker substrate / dynamic-workflow の位置づけ）/ `~/.claude/workflows/cell-quality.workflow.js`（`makeLimiter`/`FABLE_MAX_CONCURRENCY`/`demoteFable`/`dimensions {key,focus}`/`receivedArgs` の実体・verified）/ protocol.md §2・§5（呼び出し2系統の how）。

---

## 4. モデル階層ルーティング（参照ポインタ）

dynamic workflow の各 agent への model 割り当ては、本書ではなく **`~/.claude/CLAUDE.md`「Workflow モデル階層ルーティング」節が SSOT**（フルマッピングはそこを一次情報として読む・ここに散文で転記しない＝ドリフト防止）。強度キャリブレーション（§1）と load-bearing に絡む要点だけ:

- **dynamic workflow（Workflow tool の agent）は sonnet / opus のみ。fable は使わない**（read-only な大規模探索 = sonnet / 思考・統合・review・verify = opus）。
- **cell-quality は review/verify 段の解決 model が fable なら opus へ機械的に降格**（`demoteFable`・明示 fable 指定でも fail-open 継承でも review/verify は fable で走らない）。fable ≤2 cap（`FABLE_MAX_CONCURRENCY`）は降格漏れ時の defense-in-depth。
- **fan-out agent は model を必ず明示**（既定継承はコスト事故 — 新規セッション既定 `claude-fable-5` を継承すると実コスト 2 倍超）。
- **fable = admin/consult の main-loop 専用**、subagent / workflow agent には投入しない。

> 一次出典: `~/.claude/CLAUDE.md`「Workflow モデル階層ルーティング」節（SSOT・un-8q5 pilot 2026-06-10 改訂根拠込み）/ `cell-quality.workflow.js`（`demoteFable`/`FABLE_MAX_CONCURRENCY` の実体・verified）。

---

## 出所（まとめ）

| 出典 | 内容 |
|---|---|
| doobidoo `e5d79cc9` | 2026-06-15 grill 確定（D1-D7 戦術層・2 層モデル・強度キャリブレーション = 規模×不確実性×リスク・methodology.md = 汎用方法論 home）。**決定全文の一次 SSOT** |
| doobidoo `c06ab15b` / `6d11f667` | un-8q5 pilot（gate review ×2 で 5h rate 53→80%・コスト現実の実測） |
| Workflow tool 方法論 | quality patterns / composing patterns / pipeline vs barrier / "Scale to what the user asked for"。**機械的フックの一次 SSOT** |
| `~/.claude/workflows/cell-quality.workflow.js` | 凍結された適用形（task-type routing → review → adversarial verify → gated autoFix → loop-until-dry）。**戦術層骨格の一次 SSOT** |
| `~/.claude/CLAUDE.md`「Workflow モデル階層ルーティング」 | model 割り当ての**一次 SSOT**（本書は要点参照のみ） |
| scribe-design.md §18 | D1-D7 の設計 why（本書は運用 how を担う） |

> 方法論の細部に疑義が出たら、本書ではなく上記の一次 SSOT（doobidoo 原典・Workflow tool・cell-quality.workflow.js・CLAUDE.md 該当節）を確認すること（本書は判断の方法論を蓄積する庫であって、実体の複製ではない）。

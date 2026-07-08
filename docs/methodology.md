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
| **リスク（risk）** | blast radius・不可逆性・outward 性（規約変更・全ホスト配布・外部公開） | **gate の厳しさ**（read-only gate・merge gate〔`protocol.md` §5.4 二段判定〕の確認閾値・refute 多数決の閾値・completeness critic） |

**運用ヒューリスティック**（Workflow tool 方法論 + un-8q5 pilot 実測の統合）:

- 「とりあえずバグを見て」級（小規模・低不確実・低リスク）→ **finder 少数 + single-vote verify**。fan-out を盛らない。
- 「徹底監査して」「網羅的に」級（広規模・高不確実・高リスク）→ **finder pool を厚く + 3〜5 票 adversarial verify + synthesis 段 + completeness critic**。
- **research / review / audit 系は thoroughness 寄り、quick check 系は brevity 寄り**に倒すのが既定。迷ったら規模×不確実性×リスクのどれが効いているかに戻る。
- **「ユーザーが要求した強度に合わせる」が上限**: ultracode はユーザーの明示 opt-in（"ultracode" キーワード / 直接依頼 / それを呼ぶ skill）がある時だけ。opt-in なしで強度を勝手に盛らない（コスト事故になる）。

**コスト現実（verified・un-8q5 pilot 2026-06-10）**: **fable を verify 段に投入した（≤2 cap 遵守）gate review/verify ×2** で **5h rate を 53%→80% まで消費**した実測がある（doobidoo `c06ab15b` milestone / `6d11f667` GOTCHA）。この 53→80% は **fable 起因のコスト**（fable は実コストが 2×Opus 超 = tokenizer 差）で、≤2 cap でも重かったことが **dynamic WF からの fable 全廃（§4）の根拠**になった数値である — **現在の opus 経路の gate コストとは別物**として読むこと（27pt をそのまま opus gate×2 のコストと誤読しない）。いずれにせよ **fan-out の本数・票数・loop 回数はすべて rate を食う**ので、**強度キャリブレーション = rate 予算の配分**である。token 予算を loop 条件に使う dynamic scaling（Workflow tool の `budget` 機能＝loop-until-budget・§2）がその制御点（**具体 API シグネチャは Workflow tool が SSOT・本書は転記しない**）。

> 一次出典: Workflow tool 方法論（"Scale to what the user asked for"・quality patterns）/ doobidoo `c06ab15b`（un-8q5 pilot milestone・rate 53→80%）・`6d11f667`（un-8q5 GOTCHA）/ doobidoo `e5d79cc9`（2026-06-15 grill: 強度キャリブレーション = 規模×不確実性×リスク）。

### 1.1 effort ルーティング（worker/WF agent の推論強度・sc-dc9 / 強度キャリブ = sc-npa）

強度キャリブレーションの**もう一つの制御軸が effort**（推論に費やす思考量）。fan-out の幅・票数とは独立に、**1 エージェントあたりの推論深度**を選ぶ。既定は **high**。settings.json の `"effortLevel":"xhigh"` を全 worker/WF agent へ無差別波及させない（xhigh の超長単一ターンは confabulation＝幻影ツール結果を誘発した実害がある・doobidoo `1e98254c`。gate funnel は diff 欠陥の二次防御で、diff が生成されない幻影は捕捉外ゆえ effort=high 化の一次便益は「幻覚の予防」）。

#### 背骨原理（強度は gate 捕捉性 × confab リスクでスケール・sc-npa 論点1）

強度（model × effort）は **失敗が gate で拾えるか（gate 捕捉性）× confabulation リスク**でスケールする。gate が拾う失敗（初回実装力の不足）は安くてよく、gate 外の失敗（confabulation・security 境界の誤り）は高いまま保つ。effort 軸（gate で拾えるか）と後述の model 軸（事実か判断か）はこの一つの原理の二つの投影である。但し書き 2 点を必ず併読する:

- **(1) gate 強度不変が前提条件**: worker effort を下げてよい根拠は「失敗を gate/review が拾う」ことゆえ、worker と **gate 側（cell-quality の review/verify 段）を同時に下げない**（下げると根拠が消える）。この WF 内対応物が後述の per-stage 表で Review/Verify/Fix を high 固定にする理由。
- **(2) confab 減少の実証は xhigh→high のみ・high→medium は外挿**: 「effort を下げると幻影が減る」の実証範囲は xhigh→high（doobidoo `1e98254c`）。**high→medium は外挿**であって実証ではない——medium がさらに幻影を減らす保証はなく、medium の便益は「実装力を案件相応へ適正化する（コスト側）」であって「幻影のさらなる予防」ではない、と区別して読む。

#### worker effort の選び方（2 枝決定木・判定は spawn 前・sc-npa 論点2）

default=high は維持する。medium へ落とすかは次の 2 枝を **spawn 前に issue 記述から予見**して判定する（判定手順の成文化 = `protocol.md` §1 の 2 問チェックリスト）:

- **high 必須（medium 禁止）**: **security / 認可 / 入力パース / sandbox・hook enforce 系（`scripts/hooks/`・enforce-policy・apparmor）/ secrets / 不可逆・データ移行（bd migrate・dolt schema・破壊的 script）** に触れると予見されるとき。これらは gate 外失敗（confab・security 境界）の巣ゆえ実装力を落とさない。
- **medium 可**: 上記 high 必須領域に触れず、かつ『**新規制御フロー無し・docs/config/機械的修正色・局所変更**』を満たすとき。**security について書くだけの docs 変更は medium 可**（実行経路に触れず gate 捕捉圏内）。
- **tie-breaker =『迷ったら high』を維持**（medium 肯定条件の crisp さが「何でも high」への回帰を防ぐ防波堤）。判定は issue 自然言語からの予見ゆえ完全機械化しない・純裁量にもしない（`protocol.md` §1 の非対称 override が中間案）。spawn 前予見の取りこぼしは gate 側の事後 escalation（`protocol.md` §4）が fail-closed で拾う。

#### effort の選択メニュー = medium / high / xhigh の 3 値（sc-npa 論点5 メタ決定）

方針として**選ぶ** effort はこの 3 値のみ（`low`・`max` は方針メニューに入れない）。**技術層 allowlist（`low|medium|high|xhigh|max`・sc-ax4 SSOT・CLOSED）はフェイルセーフ検証用に不変**——本メニューは policy 層の縛りであって allowlist を縮小するものではない（allowlist は縮小禁止）。

| タスク種別 | effort | 指定方法 |
|---|---|---|
| docs 追補 / 軽微修正（上記 medium 可を満たす） | **medium** | admin が `scribe-spawn --effort medium`（or `SCRIBE_WORKER_EFFORT=medium`） |
| 標準実装 cell | **high（既定）** | 無指定でよい（既定 high） |
| probe / 調査 | **high** | 無指定でよい（既定 high） |
| 大規模設計 / 高不確実 / 高リスク | **xhigh** | admin が `scribe-spawn --effort xhigh` を**明示**（opt-in なしで盛らない原則と整合） |

#### per-stage effort 方針（cell-quality WF・sc-npa 論点5）

cell-quality の段別 effort は uniform でなく gate 捕捉性で分ける（実装 SSOT = `~/.claude/workflows/cell-quality.workflow.js`・本表は方針）:

| 段 | effort | 理由 |
|---|---|---|
| **Review / Verify / Fix** | **high 固定**（`args.effort` 一括下げから構造独立） | WF 内の gate その物＝但し書き(1) の WF 内対応物。「gate に守られる側」でなく「gate 側」ゆえ下げ対象外。xhigh は `reviewEffort`/`verifyEffort` の個別 opt-in knob（`reviewModel`/`verifyModel` と同じ流儀） |
| **Self-test** | **medium** | guard 連鎖の一部ゆえ low でなく medium 止まり |
| **Classify** | **medium** | 誤分類は劣化止まり＝gate 捕捉圏内 |
| **Plan / Implement** | **cell effort に従う** | `args.effort` を「実装系の段だけに効く cell effort」へ再定義 |

arg 露出は全段でなく個別 knob 2 つ（`reviewEffort` / `verifyEffort`）に絞る。**本表は決定済みの方針であって現行実装ではない**——実装は別 cell（sc-94z）で、それが着地するまで `cell-quality.workflow.js` は全 `agent()` へ `args.effort` を**一律**に適用する（`reviewEffort`/`verifyEffort` knob も guard 段の独立も未実装）。したがって sc-94z 着地までは **cell-quality へ `args.effort` で下げた effort を渡さない**（渡すと Review/Verify/Fix も一律下がり但し書き(1)＝gate 側を下げないに抵触する）。`scribe-spawn --effort` は worker 本体の effort であって WF の `args.effort` へ自動伝播しないため、既定運用では抵触しない。

#### model litmus（事実か判断か・sc-npa 論点6）

段の model（sonnet vs opus）は次の litmus で判定する — 段の出力が **事実の収集・転記・機械的実行の報告**で正しさを機械/下流が検証できる → **sonnet**。出力が **判断・統合・生成**でその質が下流を直接規定する（gate でしか裁けない）→ **opus**。cell-quality 適用例:

| 段 | model |
|---|---|
| Self-test 実行 / 純 read-only 探索 | **sonnet** |
| Classify / Plan / Implement / Review / Verify / Fix | **opus** |

境界則: **fable は WF agent へ不投入**（既存維持・§4）・**haiku は使い捨て実験のみ**。フルマッピングの SSOT は §4 と `~/.claude/CLAUDE.md`「Workflow モデル階層ルーティング」節（本表は litmus からの再導出例＝新規 WF へ汎化可）。

#### CALIB 監査ループ（軽量構造化記録・sc-npa 論点1 追加要素 / 論点4）

基準の妥当性を継続検証する軽量記録。gate close 時に固定文法 1 行を当該 issue の bd notes へ焼く（手順 = `protocol.md` §4）:

```
CALIB: effort=<medium|high|xhigh> type=<タスク種別> gateRounds=<gate 収束ラウンド数> confab=<幻影観測 有/無> escalate=<medium→high 事後 escalation 有/無>
```

`escalate` フィールドは gate 側で medium→high の事後 escalation（`protocol.md` §4）が発生したか（`有`/`無`）を記録する slot——spawn 前予見の取りこぼしを gate が拾った回数を CALIB 行の 1 フィールドとして残す（別行にせず同一行に焼く）。

**見直しトリガーは時間でなく件数 = medium cell が 5 本到達した時点**で基準を見直す（流量が細い時期の空振り・検知遅れを防ぐ）。集計は不足したら初めて別 cell でスクリプト化する（本格的な幻影自動検出器は未存在ゆえ却下・軽量記録に留める＝基盤構築が節約を食う逆転を避ける）。

#### 指定方法の mechanics（sc-dc9）

- **worker（spawn）**: `scribe-spawn.sh --effort <LEVEL>`（既定 high・env `SCRIBE_WORKER_EFFORT` で既定上書き・allowlist `low|medium|high|xhigh|max`）。CC 正規名 `CLAUDE_CODE_EFFORT_LEVEL` を worker env-file へ後勝ち注入する（`CLAUDE_EFFORT` は CC **非正規名で silent no-op** ゆえ使わない）。cld-spawn への `--effort` flag passthrough は feature-detect（`--help` に実在時のみ・un-ivb 防御）。
- **WF agent（cell-quality）**: 全 `agent()` 呼出しが `opts.effort` を既定 high で pin する（settings.json 依存を断つ）。`args.effort` で上書き可。上記 per-stage 方針は `args.effort` を「実装系の段だけに効く cell effort」へ再定義し guard 段を独立させる**決定**だが、これは sc-94z 着地後に有効になる方針であって現行実装は全段一律（前段 per-stage 表の caveat 参照）。allowlist 外は既定 high へ fail-safe。
- **admin session は不変**（settings.json の xhigh のまま）: この統制は worker/WF agent への波及のみを止める。opt-in なしで xhigh を盛らない（コスト事故＋幻覚リスク）。

> 一次出典: doobidoo `1e98254c`（xhigh worker の confabulation 3/3 再現）/ bd `sc-dc9`（effort 統制の機構訂正: 真因 = machine-global settings.json の xhigh を admin/worker 双方が読む・process env の `CLAUDE_EFFORT` は CC 非正規名）/ **bd `sc-npa`（強度キャリブレーション再設計 grill 7/7 確定: 背骨原理B〔gate 捕捉性 × confab・但し書き 2 点〕・medium 2 枝決定木・3 値メニュー・per-stage effort・model litmus・CALIB 監査ループ。SSOT = sc-npa notes 論点1-7）** / CC 正規 precedence: `--effort` フラグ > `CLAUDE_CODE_EFFORT_LEVEL` env > `settings.effortLevel` > model 既定。

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

**consult / needs-user pre-bake fan-out（session 級）**: 上表・上記は WF agent のパターン。これと別に、人間判断待ちの **needs-user タスクで相互独立な決定軸（facet）が複数（≥2）あるとき**、admin が回す dynamic Workflow（`workflows/needs-user-prebake.workflow.js`）が各 facet を **並列 read-only agent** で pre-bake 分析（現状調査〔read-only〕→ 決定木 → 選択肢 + トレードオフ → admin 起票候補）し、opus が単一の構造化 brief へ統合して admin に返す（WF は grill しない・graph を触らない・doobidoo 保存もしない）。grill〔対話〕は別主体 ＝ admin が brief を `--context` で渡して spawn する **grill-consult** が **ユーザーと対話 grill** し、確定した決定を own grill-issue の **bd notes** へ handoff する（**pre-bake〔生成〕= WF agent / grill〔対話〕= grill-consult** と別主体に分かれ、自己 pre-bake を誤帰属する主体が消えて旧 F2 が構造解消する）。いつ選ぶか = 1 つの needs-user issue 内に相互独立な決定軸（facet）が ≥2 あるとき（1 facet なら admin インラインで足り fan-out 不要）。手順 SSOT = `protocol.md` §7（dogfood 実証済み: sc-in9）。

> 一次出典: Workflow tool 方法論（quality patterns / composing patterns / pipeline vs barrier）/ `~/.claude/workflows/cell-quality.workflow.js`（凍結された適用形）。

---

## 3. D1-D7 運用方法論（戦術層の回し方）

scribe の worker/workflow を**2 層**で捉える（doobidoo `e5d79cc9`・2026-06-15 grill 確定）:

- **背骨層（確定済・設計余地なし）**: worker = 独立した完全な対話 CC セッション + persona/契約プロンプト + beads。**worker 自身が実装する**（「workflow ファイルを渡される agent」ではない）。scribe-design.md §3/§12 の verified 事実。
- **戦術層（設計余地・D1-D7 で確定）**: worker タスク**内**の bounded な fan-out（cell-quality gate / 調査 sweep 等）をどう組むか。動的 ultracode は**禁止ではないが背骨でもない** — 戦術 fan-out 限定。

D1-D7 は戦術層の**運用方法論**。決定の why は scribe-design.md §18、決定全文は doobidoo `e5d79cc9`（本書は運用面だけを蓄積・転記しない）:

- **D1 戦術層の背骨 = ハイブリッド**: 不変骨格（cell-quality.workflow.js）+ worker が args 供給。動的 ultracode は bounded 戦術 fan-out のみで背骨にしない。→ **運用**: 新しい品質要件は「骨格を書き直す」前に「args で差せないか」を先に問う（`~/.claude/CLAUDE.md`「Workflow 骨格の再利用」と整合）。
- **D2 opus 並列 cap = args 化**: `A.maxConcurrency` で opus 経路（review/verify fan-out）の同時実行を絞る（`makeLimiter`/`opusLimiter` は cell-quality.workflow.js に配線済・未指定 0 = 無 cap で harness の `min(16, cores-2)` が実効上限）。→ **運用（経路別の実状）**: **worker 自己点検**（`scripts/scribe-selftest-args.sh`）は `--max-concurrency`（既定 **4** = 必須 4 観点と揃う安全既定）で cap を注入済＝effective。**admin gate**（`scripts/scribe-gate-args.sh`）は read-only 一次監査ゆえ cap を渡さず harness 既定に委ねる。rate 逼迫時は worker 側 `--max-concurrency` を明示で絞る。
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

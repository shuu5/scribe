<!--
═══════════════════════════════════════════════════════════════════════════════
コピー元注記（scribe リポ移設・2026-06-11）
─────────────────────────────────────────────────────────────────────────────
本ファイルは ubuntu-note-system の `docs/scribe-design.md`（PR#354 改訂版・bd un-5ez
で v0 決定を反映した単一 SSOT）を、scribe リポ作成セル（bd un-led / un-it7 epic 第 1
cell）で 2026-06-11 にコピーしたもの。

- **コピー元**: ubuntu-note-system `docs/scribe-design.md`（改訂版・staging 置き場）
- **コピー日**: 2026-06-11
- **以後の参照先**: 本ファイル（scribe リポ側）が **実装リポの初期設計ドキュメント**。
  設計の細部に疑義が出たら本書ではなく §17 の doobidoo 原典を recall して確認する
  （本書は統合・整形版）。ubuntu-note-system 側は staging にすぎず、着手後は
  本リポへのポインタに縮小される（§16 堀フェーズ チェックリスト末項）。
- 移設時は本文無改変（注記ブロック追加のみ）だったが、**その後 v0 実装に追従して本文を更新済み**（§33 の「本文は常に現行の真のみ」規律に従う・sc-aop）。設計判断の SSOT として現行を保つ。
═══════════════════════════════════════════════════════════════════════════════
-->

# scribe 設計ドキュメント（概念設計 SSOT + v0 実装完了版）

> **このファイルの位置づけ**
> scribe は **v0 実装完了済みで稼働中のプロジェクト**（リポ `~/projects/local-projects/scribe/`・sc-aop で「未作成の将来プロジェクト」記述を訂正）。
> 本書は概念設計（§1〜§13）の統合 SSOT であり、かつ v0 スコープ（§14）の SSOT でもある。
> **実装の現行 SSOT は `docs/protocol.md`（admin プロトコル）/ `docs/role-context-spec.md`（role 注入）/ `docs/methodology.md`** で、本書は設計の why を保持する。
>
> - **着手戦略 = 段階着手（2026-06-10 改訂）**: 旧「folio 1.0.0 / folio-architect 完成を待って着手（不変）」条項は**撤回**。
>   §5 graceful degradation の**軽量モード（spec プロバイダ抽象・堀 OFF）を入口に今から着手**する。folio backend と堀（in-loop hook 強制）は後付け（v1+）。詳細スコープは §14、移行手順は §16。
> - **知識の出所（doobidoo）**: 概念設計 = conversation_id `scribe-redesign-grill-2026-06-04`（5件）/ v0 段階着手 = `scribe-v0-grill-2026-06-10`（hash `13447a54`）。ハッシュは §17 を参照。本書はこれらを統合・整形したもの。設計の一次根拠は doobidoo 側。
> - **本書 vs ubuntu-note-system**: ubuntu-note-system はこの設計の *staging* 置き場にすぎない。
>   実装は scribe リポで行う。ここに置くのは「git 追跡＋マシン間同期される唯一の安全な置き場」だから。
> - **旧 "scribe = 論文執筆層 / thesis-scribe リポ" の定義は破棄**された。`thesis-scribe` は**無関係の論文プロジェクト**で、本 scribe とは別物。

> **改訂経緯（このブロックは履歴・本文は常に現行の真のみ）**
> - **2026-06-04**（概念設計確定 grill）: §1〜§13 の概念設計を全周確定。当時の着手条件は **「folio 1.0.0 / folio-architect 完成を待って着手（不変）。先行着手しない」**（← この引用は履歴であって現行条件ではない。現行は上記「段階着手」）。
> - **2026-06-10**（v0 段階着手 grill・7 論点完走・ユーザー ratify 済）: 上記「待ち（不変）」条項を**撤回**し段階着手へ。**撤回理由 = 手動 admin プロトコル（spawn / bdw / cell-quality gate funnel / errata 規約 / close→gate）が 2026-06-10 Wave1+2 の 10 PR 分で実証済み**＝§5 graceful degradation の軽量モード（堀 OFF）が動作実績を持つ入口になった。決定の一次記録 = doobidoo `13447a54`（`scribe-v0-grill-2026-06-10`）+ bd un-3v9 notes。v0 スコープは §14、v0 チェックリストは §16、出所は §17。
> - **概念設計 §1〜§13 の設計内容は不変**（v0 で何を「先に作るか / 後回しにするか」の注記だけ追加。設計判断そのものは変えていない）。

---

## 0. TL;DR

**scribe = per-project・Claude Code ネイティブの「実装 administrator（ユーザー代理 AI）」プラグイン。**
folio が著作した architecture/spec を唯一の anchor とし、人間は「要望を出す」だけ、それ以外の段取り・分割・セッション制御・跨ぎメタ認知をすべて administrator が代理する。

> **成果物形態・制約**: 個人用ファースト（配布しない）。ただし in-loop hook を使う以上 **plugin 形態は必須**（"配布しない" と "plugin にしない" は別物）。「安全に長期メンテ」が硬い制約 → **新規性の低い既存資産の合成を優先**（substrate を compose し新規 engineering を最小化、§3）。

差別化の堀（moat）= **in-loop で hook 強制される folio-spec 順守**。Claude Code の PreToolUse hook が Edit/Write を permission 判定より前に `exit 2` で block できる（`--dangerously-skip-permissions` でも効く）ため、**外部委譲型オーケストレータ（Hermes / OpenClaw）には構造的に真似できない**。

「作る」プラグインは **scribe 1枚だけ**。実装層（旧 phaser/worker）は first-class plugin にせず、persona prompt + dynamic-workflow テンプレ + folio gate に「溶ける」。cc-session / beads / doobidoo / folio は **compose する substrate**。

---

## 1. administrator = ユーザー代理（per-project）

- 人間が行うのは **「要望を出す」だけ**。それ以外を administrator が担う:
  - 具体指示への翻訳
  - セッションの生成 / 折りたたみ / reset / compact
  - 「ここまで検証」「docs 作成」等の段取り判断・作業分割
  - **跨セッション / 跨 compaction のメタ認知保持**
- **プロジェクト横断しない**。Claude Code を project root で開く前提で、実際の境界は context / permission / CLAUDE.md / hooks / beads / spec の scope。
- administrator 自身も CC セッションとして compact する → 自前のメタ認知は外部記憶（beads + doobidoo + folio spec + working-memory）に置く（`session:ready-compaction` の部品を流用）。
- **administrator が指揮する 3 lane**:
  | lane | 担い手 | 役割 |
  |---|---|---|
  | **spec lane** | folio-architect 駆動 | 設計・概念の壁打ち・spec 著作/更新 |
  | **impl lane** | scribe 実装 worker（worktree 並列） | コード実装 |
  | **verify lane** | scribe 検証/sandbox worker（read-only + sandbox 権限） | spec を真として検査 |
- **唯一の anchor = folio architecture/spec**。メタ認知・done 判定・検証すべて spec 基準。
- **requirement を変える要望は spec-first**: administrator が spec lane で spec 更新 → impl → verify（spec 基準）。docs / 検証 / 純粋 refactor 等 requirement を変えない作業のみ直行可。

### 自律度ダイヤル

administrator の spec elicitation は可変自律:
1. **対話**: grill-me を人間へ中継（デフォルト。spec 部分はユーザーに grill-me）
2. **監督付き自律**: 自答 → spec ドラフト → requirement 差分を人間が ratify
3. **完全自律**: 根源要望のみから自答、仮定を非同期レビューキューへ（ユーザーが明示的に指示したときのみ）

- **needs-user タスク**: worker 着手不可の理由が人間判断に依存する状態（自律度ダイヤルが人間 grill へ倒れる側のタスク）。駐車ラベル（タスク属性）であり、解決機構（admin が回す WF pre-bake + grill-consult）とは別物。orchestration 上の扱い = `protocol.md` §7（dogfood 実証済み: sc-in9）。

---

## 2. 差別化の堀 = in-loop hook 強制の folio-spec 順守（CC-native）

- CC は編集ループ内で強制できる: **PreToolUse hook が Edit/Write を `exit 2` で、permission 判定より前に block**（bypassPermissions / `--dangerously-skip-permissions` でも効く）。Hermes は外部委譲で結果しか見えず**構造的に真似不可**。
- admin + worker が folio plugin と同じ CC ランタイムで動くので、folio の既存 hook を **path 参照で再利用**できる:
  - `check-caller-marker.sh` / `check-path-boundary.sh`（PreToolUse, `exit 2`, jq 無でも fail-closed）
  - `check-jsonld-lint.sh` / `check-readme-index.sh`（PostToolUse）
  - 共有 `plugin-lib.sh`（`folio_deny` 等）
  - + scribe の diagnostics PostToolUse（pyright/tsc/ruff、§9）を chain
- **帰結: worker は CC に統一必須**（非 CC 委譲で堀が消える）。16K 組込バイアスで coding 品質も最高、と整合。

---

## 3. 分解・コンポーネント境界（A 案で確定）

3層スタック:

- **基層 substrate（既存・standalone・compose される側）**
  - **cc-session**: spawn / fork / session-comm（= 操舵注入）/ session-state / window-manifest + ready-compaction + enforce。README で「常駐監視・マルチウィンドウ統括は範囲外」と明記 → **administrator はこの上に乗る別物**。
  - **beads**: per-project タスク台帳（§8）。tasks=bd / knowledge=doobidoo。
  - **doobidoo**: 知識ストア。
  - **folio**: Layer0 spec 著作 + in-loop spec-gate hooks。
- **orchestration（新規・作る対象）= scribe(administrator)**
  - substrate を compose し worker を spawn / observe / comm、beads でタスク、folio spec を anchor、doobidoo で知識。
  - = `docs/session-orchestration-strategy.md` の "Supervisor パターン" の製品化（cc-session が scope 外にした supervision を scribe が実装）。
- **implementation（溶ける層）**
  - worker = cc-session セッション + persona prompt（administrator が渡す）+ folio in-loop gate +（必要なら）dynamic-workflow テンプレ。
  - phaser / worker は first-class role plugin に **しない**。worker 種別（impl / 設計 / 検証）は substrate 同一（独立セッション）で、prompt / context / 権限が違うだけ。

**根拠**: ubuntu-note-system 自体が monolithic plugin → script + hook + workflow + persona 合成へ脱皮中（dotfiles→modctl, env→hooks, twill 25-skill→folio minimal, loom 凍結）。composable 哲学＝既存の確立方向。

---

## 4. ゲートの2分割（Gate α / Gate β）

- **Gate α = spec の整合・意図ゲート**
  - 誰が spec を編集可・schema・**provenance（ai-proposed / user-confirmed）・確定/署名 ratification**。
  - **所有 = folio capability**（scribe が駆動）。
  - 理由: provenance は spec 要素のプロパティ＝folio の spec フォーマットに乗る / folio が既に spec-edit hook 所有 / folio 憲法が Ask-first（P-9/P-10）/ 各 plugin は自分の artifact のゲートを持つ原則。
  - 実装: provenance schema + 確定検証を **folio 側共有ライブラリ（SSOT）** に置き両者が source（cc-session の `enforce-policy.sh` 共有パターンと同型）。`confirm` / 署名検証は folio capability、scribe は「いつ人間に聞くか」を判断して駆動するだけ。
- **Gate β = 実装の準拠ゲート**
  - コードが確定済み spec に準拠か + diagnostics（pyright/tsc/ruff）。
  - **所有 = scribe**。worker のコード Edit/Write 時に in-loop 発火、folio spec（provenance 込み）を oracle に読む。
- **cross-plugin 依存（重要）**: scribe の intent-fidelity の堀（α）は **folio が provenance/確定サポートを得て初めて完成** → **folio に provenance ADR を1本起こし、folio の provenance 対応を scribe の確定フローより先に sequence する必要**（§15-1）。

---

## 5. scribe↔folio の境界 = spec プロバイダ抽象

administrator は folio に直接依存せず、**「spec プロバイダ」抽象**に話す。実装が差し替わる:

| backend | 性質 | 堀 |
|---|---|---|
| **folio backend** | 厳格（HTML/JSON-LD spec・in-loop hook・provenance・署名確定） | **ON** |
| **scribe 内蔵 backend** | 軽量（docs 一枚・簡易 ai-proposed/user-confirmed タグ・確定は docs 追記＝人間が書けば user-confirmed 扱い・署名なし） | **OFF** |

- **最小コントラクト**: `read_requirements` / `done_criteria` / `provenance` / `propose` / `confirm` / `on_spec_change`。
- 先例: cc-session の session-comm も backend pluggable（`session-comm-backend-tmux.sh`）＝同型・低新規性・保守容易。
- **administrator をシンプルに保つ核**: rigor 差は backend が吸収、administrator は抽象越しに呼ぶだけ。

### Graceful degradation（仕様）

- **folio あり** → 厳格・堀 ON（in-loop conformance + provenance + 署名確定）。
- **folio なし**（小プロジェクトで folio 不要時） → scribe 単独で軽量 spec を作り docs 保存して実装。**堀 OFF・provenance/署名(A/B) も OFF**。
- これはバグでなく仕様: 強度を案件に合わせる。**casual モードでは intent drift し得るのを意識的に受容**。Gate β（準拠検証）は両モード共通で ON、Gate α 厳格部（署名・in-loop schema 強制）は folio backend 限定。

### 他 spec ソース（OSS/別 plugin）を SSoT にできるか（非必須・確認のみ）

**可能。spec プロバイダ抽象の直接的配当**（folio は数ある backend の1つ）:
- `read_requirements` / `done_criteria` / `on_spec_change` / in-loop Gate β = **広く一般化**（OpenSpec / Kiro / Spec Kit / 手書き PRD でも要件読み・beads タスク化・impl/verify・準拠強制が回る＝scribe の価値の大半）。
- provenance/署名確定（Gate α）= **folio 固有**。多くの OSS は持たない → foreign 時は軽量 intent-fidelity を受容 or scribe overlay。
- Gate β の "強さ" は foreign spec の機械可読度に比例（EARS/JSON-LD = 厳密 / 散文 PRD = LLM 判定で弱い）。
- **方針**: spec-source-agnosticism は hard goal にしない。contract は generic + capability-negotiated に設計（backend が対応機能を申告、scribe が degrade）。**実装は folio backend + scribe 内蔵 backend の2つだけ**、OSS backend は必要時まで作らない。

---

## 6. provenance 安全ハーネス + 昇格メカニズム（ratification）

### provenance ハーネス

- 各 spec 要素に **`provenance: ai-proposed | user-confirmed`**。AI 起源 Write は **ai-proposed 強制（fail-closed）**。
- AI が決めた要件は常に「仮定: X（理由・確信度）」として明示記録。
- **done も provenance 継承**: ai-proposed 準拠 = 暫定done / user-confirmed 準拠 = 真done（verify lane が区別表示）。

### 深い risk（要件版 verify-laundering）

堀は impl↔spec を airtight にするが、administrator が grill-me を自答すると **spec↔ユーザー意図** が新たな（より悪質な）drift 面になる＝「間違った要件を完璧に spec 準拠で実装」。folio の存在意義（intent を忘れさせない）+ Ask-first 憲法（P-9/P-10）と衝突。→ 上記 provenance ハーネスがガードレール。

### 昇格 = A 運用 / B 対応

**決定的事実**: 単一 uid + `--dangerously-skip-permissions`（起動経路 `cld exec claude --dangerously-skip-permissions`）では、**ローカルの marker/file/prompt は暗号的に偽装不能にできない**（AI が同権限）。`session:enforce` の marker は honor-system（設計が自認）。AskUserQuestion / plan-mode / transcript-hook も偽装可。PermissionRequest dialog は偽装不能だが bypassPermissions でスキップされる。**真に偽装不能なのは「AI が持たない秘密/デバイス」を要する手段＝git commit 署名（SSH Ed25519/gitsign、人間 touch 保護鍵）**。業界 HITL（LangGraph/CrewAI/AutoGen/OpenAI SDK）は全部 stdin 読むだけで偽装可＝production 実装は空白地帯。

**決定: B 対応で設計・A から運用。A↔B はアーキ不変、"検証述語" と "鍵強度" だけ変わる。flip = config 1個 + 鍵差し替え、rework ゼロ。**

共通アーキ（A・B 不変）:
1. 各 spec 要素（@id）に `provenance` + `confirmed-hash`（正規化内容ハッシュ）。default=ai-proposed、不明も ai-proposed（fail-closed）。
2. 単一の昇格口 `scribe confirm <element-id>` → 確定コミット作成、`{id, content-hash, who, when}` を `.scribe/confirmations.jsonl` に append + commit。
3. user-confirmed は**派生状態**: gate が「署名/真正性 OK かつ content-hash 一致の確定エントリ存在」で判定。確定後に要素が変われば hash 不一致 → **自動で ai-proposed に降格**。
4. in-loop hook が「AI 起源 Write の user-confirmed 直書き」を禁止（fail-closed）。
5. verify lane が provenance 併記（暫定done/真done）。
6. CI gate（push 時）が全確定エントリの署名/整合を再検証（in-loop 擦り抜けを捕捉、B の crypto が真に効く点）。

A↔B 差分（ここだけ）:
| 項目 | A（運用開始） | B（最終対応） |
|---|---|---|
| `scribe confirm` | 人間 author コミット | **署名付き**コミット（SSH Ed25519/gitsign） |
| gate 述語 | metadata 信頼 | **署名検証必須**（git verify-commit） |
| 鍵保護 | 無/passphrase | **hardware-touch**（YubiKey/Secure Enclave） |
| 偽装耐性 | うっかり防止（honor + audit） | 意図的偽装も阻止（真の壁） |

- **再確認粒度 = 正規内容ハッシュ基準**: 規範内容（REQ 本文・受入条件）が変わった時のみ降格、cosmetic/非規範編集は確定維持。
- **脅威モデル**: A = 自分の agent のうっかり過信（solo の現実的脅威）/ B = 意図的偽装（hardware-touch 署名のみが壁）。方針 = 最終的に B 対応・まず A 運用・B の設計も今やる。
- **worker OS sandbox の境界（sc-451・正直な明示）**: worker の bwrap sandbox は **Bash write 境界**であって完全隔離ではない（read は host 全体・network egress は非封鎖・built-in Edit/Write は tool 層 guard〔sc-649〕が別レイヤで縛る）。**admin/consult は非 sandbox のまま worker 生成物を ingest する非対称**があり、これは上記脅威モデルで言えば A（うっかり）運用の信頼前提＝B（意図的偽装・敵対 worker）への壁ではない。gate funnel の ground-truth verify（protocol §5）が現行の運用補償で、B 対応は provenance 署名 lane（本節上部）の領分。守る/守らないの全体像 SSOT = `scripts/sandbox-spike/README.md`「脅威モデル」節。

---

## 7. Hermes は別レイヤー（scribe スコープ外）

- 構図: 人間 →(要望)→ **Hermes**（横断・top 層・採用済み） → **scribe administrator**（per-project） → **worker**。層が違うので競合しない。
- Hermes を top 層に使う場合は **dispatch + I/O + scheduling に厳格に bound**（Hermes の自律メモリ/自己改善スキルは「学んで drift する」設計で、folio の「drift させない」anchor と思想衝突 → lobotomize 必須。`delegate_task` は親ターン拘束で長命 spawn 不可 → cron/terminal backend）。
- 代替: cc-session の "recursive administrator" が local dispatch の ~90% を既に持つ。Hermes 固有の価値は遠隔マルチチャネル/dashboard/cron/跨マシンのみ。
- **結論**: Hermes は別概念として scribe 設計から切り離し済み（両方作って人間が Hermes 経由で administrator を操作する構図はあり得るが、scribe の設計には影響しない）。

---

## 8. beads タスク管理（worker↔beads = B/hybrid で確定）

### 実リポ検証で確定した事実

- `embeddeddolt/` / `.dolt/` / `.beads/issues.jsonl` / `.beads/interactions.jsonl` は **gitignore**。issues.jsonl は **可読エクスポートであって同期チャネルではない**（Dolt が SSOT、`refs/dolt/data` で同期）。
- bd は **worktree redirect 機構**（`.beads/redirect` = anchor の `.beads/` への相対パス）→ **全 worktree が anchor の単一 embeddeddolt を auto-share**（siloed ではない）。
- **マシン間同期は実在**: origin に `refs/dolt/data` が存在。`bd dolt push`/`pull` で同期（git 同様の明示 push/pull）。**bd のバージョンは pin しない**（upgrade 前に migration のマルチマシン同期破壊が無いか検証してから上げる人間ポリシー。旧・v1.0.4 ピンは撤廃。参考: v1.0.5+ の migration 0043 が #4259 で同期破壊した経緯）。

### 確定（worker↔beads = B/hybrid）

- **administrator(anchor)** が所有: issue 作成・依存グラフ・assignment・最終判断・**`bd dolt push`/remote 同期点**。
- **worker(worktree)** は自分が claim した issue の進捗/status を **auto-share DB に直接書く**（`bd update --claim` / `--append-notes` / `gate-pending` ラベル付与・sc-4kb: 破壊的 `--notes` でなく追記の `--append-notes`）。**自 issue の close はしない**（admin が gate+merge 後に close＝orch-ol0 反転・protocol §4）。
- ＝ **beads 自体が live なタスク共有ボード**。supervise ループ（§10）は `bd ready`/status を主信号に read。
- 競合は bd の dolt-server が serialize + worktree-native + hash-ID 衝突回避で 3-5 worker は想定内。bottleneck 化したら **admin-batched 書込（A 案）に fallback**。
- 却下 A（admin 単一 writer・worker は issue ID 参照のみ）: 保守的・実証済み（ubuntu-note-system 現行）だが、LLM 実装 worker は「自分で claim して進捗を書く」が自然なので B 採用。

### スコープ

- scribe 1インスタンス内: administrator + worker は**同一マシン**（anchor + その worktree 群、単一 embeddeddolt を redirect 共有）。
- マシン**間**: ① dolt 同期で継続性（昨日マシン X → 今日マシン Y、anchor↔anchor）② live な分散 worker は Hermes top 層の仕事（scribe スコープ外）。

---

## 9. 通信モデル = 2チャネルのハイブリッド

「mailbox（point-to-point 配送/キュー）」という単一概念は **誤り**。実態は2チャネル（名称「mailbox」は retire）:

1. **共有ボード（blackboard・PULL）= 状態・結果**
   worker が durable な共有場所に書き、administrator が自分のタイミングで read（`--lines` 制限で必要分だけ）。**P2（context ノイズ隔離）に最適**（push されず、file なので compaction 生存）。
2. **ステアリング注入（PUSH）= プロンプトインジェクション・操舵**
   admin が特定 worker の入力へ cc-session `wait-ready` + `inject-file`（flock）で確実配送。**admin の context には載らない**（worker の pane で起きる）。

- 純 point-to-point mailbox / broker / pub-sub は **3-5 worker 規模で YAGNI**。
- 既存の documented パターン Observer(pull)/Coordinator(state-check+inject)/Bridge(shared-file)/Supervisor(observe→decide→act) と一致（`docs/session-orchestration-strategy.md`）。research=Bridge+Observer、trading=Observer+Coordinator の実例あり。

### substrate へのマッピング（"mailbox" は既存資産に溶ける）

| 用途 | 担い手 | push/pull |
|---|---|---|
| タスク state・進捗・status（誰が何を・依存・done） | **beads**（live タスク共有ボード native。**task-state 用の別ファイル板は不要**） | pull |
| bulk 成果物・ログ等（beads に載せない payload） | **薄い共有ファイル板**（Bridge。task-state でなく bulk payload 専用に縮小） | pull |
| 知識 | **doobidoo** | pull |
| 操舵・プロンプト注入 | **cc-session session-comm inject** | push |
| 協調プロトコル・監視ループ・判断 | **scribe(administrator)** | — |

> **§8 ↔ §9 の関係**: beads が task-state（status/進捗/依存/done）の live 共有ボードを native に担うため（§8 の B/hybrid 確定の帰結）、task-state 用の別ファイル板は作らない。共有ファイル板は beads に載せない bulk 成果物・ログ専用に縮小する。

→ scribe は重い mailbox を作らず、beads + cc-session inject + 薄い status ファイル板を **compose** するだけ。

> **`session_msg recv`/`ack`/`list` stub = 意図的未実装（mailbox-as-store 棄却・sc-pp9 論点5）**: cc-session session-comm の双方向 mailbox 相当（`session_msg recv` / `ack` / `list`）は **stub のまま意図的に未実装**として維持する（未実装は欠陥でなく設計判断）。sc-pp9 論点5 で「mailbox を worker↔admin 通信の**保管庫（store）として二重化する案B（cc-session mailbox 拡張）」を棄却したため——上記 2 チャネル（PUSH=操舵 inject／PULL=beads ボード）で足り、永続 store + id + poll + ack 台帳という新サブシステムの実コストに見合う純増価値は**構造化 ack のみ**で薄く、CC native の agent teams Mailbox が GA 化すれば再発明が陳腐化するリスクも大きい。**再評価トリガは並列規模が 3-5 worker を大幅に超過したときのみ**（それ未満では本 2 チャネル compose で YAGNI＝§8「3-5 worker は想定内」と整合）。決定 SSOT = bd sc-pp9 論点5 notes。

---

## 10. 監視ループ機構 = (b) 薄い背景 supervisor

scribe 自身は turn ベースで compact する LLM セッションなので「observe→decide→act ループを誰が回すか」が難所。

- **採用 (b)**: **薄い背景 supervisor スクリプト（非LLM）** が `session-state.sh list --json` で全 worker 状態を cheap に polling + beads/board を watch → 「done/stuck/error」検知 → **compact digest を生成して scribe に escalate**（or scribe が turn 頭で digest read）。機械的作業は非 LLM、**判断だけ scribe の LLM**。→ scribe の context クリーン（P2）。
- **実装は段階的**: 最初は (a) 最小（scribe が Monitor/in-session polling）で動かし、context 圧が問題化したら (b) 背景 supervisor に切り出す（A/B 昇格と同じ "後で硬くする" 戦略）。
- **Hermes の gateway daemon / claw-code の clawhip のローカル・scribe 所有版**（既存 repo に無い、新規 engineering）。
- 却下 (a 恒久): scribe の turn/context を食う。

---

## 11. code-intelligence スタック

層状スタック（決定済み）:

- **text 層**: ripgrep（組込 Grep / Bash、既存）
- **syntactic 層**: ast-grep（CLI, bash, zero-context）
- **semantic 層 = diagnostics に集約**: pyright（`--outputjson`）/ tsc（`--noEmit`）/ ruff を **plugin root `hooks/hooks.json` の PostToolUse hook で Edit/Write 後に自動起動**
- **生成・編集**: 組込 Edit/Write（16K 組込ツールバイアスと同調、Serena と違い逆風にならない）
- **escalation（稀）**: Serena を *非plugin* user-level agent（`.claude/agents/`）経由でのみ。常用しない

**native LSP は採用しない**。**Serena を plugin 内で常用しない**。どちらも CLI diagnostics + hook に dominated。

### 検証済みの決定的制約

- 公式 sub-agents docs:「plugin subagents は `hooks` / `mcpServers` / `permissionMode` frontmatter を**サポートしない**（無視される）」。
  - 含意: plugin 配布する scribe の subagent frontmatter で Serena（mcpServers）や hooks や permissionMode を指定しても無視される。
  - **ただし plugin root の `hooks/hooks.json` で定義する hook（PreToolUse/PostToolUse/SessionStart 等）は機能する**（folio が現に採用） → scribe-as-plugin で **CLI diagnostics 自動起動は確実に実装可能**。
  - Serena 採用経路は **非plugin の `.claude/agents/<name>.md` のみ**（一体配布の利点を失う）。
- PostToolUse は observational がデフォルト。**生成を停止させたい時は `exit 2` + stderr**（`exit 1` は non-blocking で無効化される頻出バグ）。
- SessionStart の `matcher: "compact"` で「Edit 後は diagnostics を確認する」指示を再注入し compaction 耐性を持たせる。
- 採用率の決定的事実: 単純 CLAUDE.md 記載 = 20% / PreToolUse フック = 84% / **PostToolUse 自動実行 = 100%**（LLM recall 非依存）。CLI（bash）は context を食わない（MCP と違い tool 定義を context に乗せない）。
- **大原則**: Claude Code に code-intelligence を与えるとき、勝ち筋は常に「**適所の CLI を hook で強制起動する**」。

### 推奨 PostToolUse hook 雛形（plugin root `hooks/hooks.json`）

```json
{
  "hooks": {
    "PostToolUse": [{
      "matcher": "Edit|Write",
      "hooks": [{
        "type": "command",
        "command": "f=$(jq -r '.tool_input.file_path'); case \"$f\" in *.py) ruff check \"$f\" 2>&1 | head -20; pyright --outputjson \"$f\" 2>&1 | head -40;; *.ts|*.tsx) npx tsc --noEmit 2>&1 | head -40; npx eslint \"$f\" 2>&1 | head -20;; *.sh) shellcheck \"$f\" 2>&1 | head -20;; esac"
      }]
    }]
  }
}
```

---

## 12. worker substrate / dynamic-workflow の位置づけ

- 持続・並列・相互通信する worker fleet = **独立 CC セッション（cc-session/worktree）**。dynamic-workflow subagent は不可（親ターンで死ぬ・フラット・途中入力不可）。
- **dynamic workflow = worker タスク内の bounded 戦術 fan-out 専用**（例: impl→review→verify を1回回す）。**背骨ではない**。
- orchestration の SSOT = **folio spec + administrator skill + hook ゲート + beads**（workflow script ではない）。

---

## 13. twill からの継承（原則のみ、コードは流用しない）

twill 資産は **コードを流用せず原則のみ継承**:

- **ADR-021 決定論 orchestration**: LLM 判断ゼロの status gate。
- **Pattern X'**: PR 完全廃止 + hooks + Task tool/spawn で reviewer 機械起動 + LLM 判断ゼロ status gate。worktree HEAD をレビュー単位として reviewer 起動を hooks + Task tool で機械化。「LLM が判断ゼロで status gate を管理する」が核心。
  - 検証済み要点: Stop hook `decision: "block"` で claude 自動継続 / SubagentStop の `agent_transcript_path` 経由で verdict 取得（end_turn wait-loop 必須）/ review trail は event bead（child issue + `discovered-from` dep）で永続化（`bd update --notes` 上書き対策）/ shell `grep -qE "^PASS"` で LLM 判断ゼロ status 遷移。
- **Beads**: `bd ready --json` が DAG 走査 + unblocked + priority 順を ~630 tokens（GitHub MCP の 1/87）。10 種の型付き dependency。worktree native。

> 参考: 旧 twill の Beads feasibility 研究は doobidoo `a47de93a` / `4af8d45a`（twl2 §9 clean-slate 計画 = scribe の前駆的詳細設計）。旧 twill repo は freeze 維持で、実装適用は scribe で行う方針。

---

## 14. v0 スコープ（段階着手の入口・2026-06-10 確定）

> §1〜§13 は概念設計の全体像（最終形 = 堀 ON・folio backend・自動判断層・背景 supervisor まで）。本節 §14 は**その全体像のうち v0 で「先に作る」薄い切り出し**を定義する。§1〜§13 の設計判断は不変で、ここでは「v0 で含む / v1+ へ後回しにする」境界だけを切る。下流の v0 実装 epic（bd un-it7）はこの §14 を設計 SSOT として参照する。

### v0 で作るもの（3 本柱）

1. **手動 admin プロトコルの成文化**: 2026-06-10 Wave1+2 の 10 PR で実証済みの手順（spawn 規約・close→gate→errata・worker prompt 規約・監視 busy regex・B/hybrid graph 所有境界）を **scribe plugin の docs に同梱して SSOT 化**する。project CLAUDE.md は本文重複を持たずポインタへ縮小（縮小自体は別 PR）。
2. **道具（`scripts/`）**: 手順をコード化する薄いヘルパー群。
   - spawn ヘルパー（bd id → worktree + task prompt 生成 + cld-spawn + monitor 起動。window 参照は **ID（`@N`）捕捉**で行う＝bd 子 issue id のドット（例 `un-3sh.3.5`）が `tmux -t` ターゲット構文と衝突する live finding の回避。bd un-cbi notes 参照）。
   - gate 起動ヘルパー（cell-quality WF 呼出）。
   - cleanup（worktree / branch / window 掃除）。
3. **role 判定つき SessionStart 文脈注入（3 role）**: admin / worker / consult の 3 role それぞれに必要な文脈だけを SessionStart hook で注入する。SessionStart hook に role 宣言機構は無いため**実行時 guard で分離**する: worker = cwd が `.worktrees/` 配下か判定 / consult = 明示シグナル（env or window 名）/ admin = anchor。
   - **2 本目の SessionStart hook = plugin health-check（`session-start-guard-health.py`・bd sc-ovq）**: scribe が consume する canonical plugin（cmdtokens / beads-bdw）の不在を loud 化する。cmdtokens 不在で git/rm destructive guard が fail-open（破壊コマンド素通し）に、beads-bdw 不在で `scripts/bdw` が fail-closed（bd write 不可・sandbox-off worker は zombie 化）に silent 劣化するため、scribe session（`dolt_database=='sc'`）でのみ ⚠️ banner を stdout 注入する（self-scope helper = `scripts/hooks/lib/scribe_session.py`・常に exit0 degrade）。orchestrator 側 scriptorium の同型 guard-health hook（cmdtokens 版・bd orch-hos）を port し beads-bdw probe を加えたもの。全ホスト配布物（固いカテゴリ③）。

### 3 role と role 別 PRIME 分割

v0 の最重要設計判断。**role 別に注入内容を分割する**:

| role | 配置 | 注入内容（要旨） |
|---|---|---|
| **admin** | anchor | プロトコル全文（graph 所有 = `bd create`/`dep`/assignment / gate funnel / errata 規約 / `bd dolt push` = 同期点） |
| **worker** | worktree（`.worktrees/<branch>`） | 自 issue の write のみ（`bd update --claim` / `--append-notes` / `gate-pending` ラベル・**close はしない**＝admin が merge 後）+ bdw 並列直列化規律 + **`bd create` / `bd dep` / `bd dolt push` / `bd close` の明示禁止** |
| **consult** | anchor 同居可（read-only セッション） | 設計議論・grill 専用。記憶系（doobidoo + auto-memory）のみ write 可。bd・リポ tracked ファイル・`bd dolt push`・spawn は禁止。相談サマリ保存義務。**緩和**: grill-consult（admin が `--context` brief で spawn）のみ自 grill-issue の `bd update --claim`/`--append-notes` を bdw 経由 write 可（close は admin 専有）＝ role-context-spec §2.3。起動テンプレの SSOT は role-context-spec §2.3（scribe plugin へ移設完了・sc-aop。docs/session-orchestration-strategy.md §6 は原典トレース用） |

**role 別分割の根拠（verified・構造原因の発見）**: 現状 `bd prime` の SessionStart hook が**全セッション（worker 含む）へ無条件**に「非自明な作業は着手前に `bd create`」を注入している。これは B/hybrid の「worker は graph を操作しない（`bd create`/`dep` しない・notes 提案 → admin 起票）」と**矛盾**しており、**worker の `bd create` 逸脱の構造原因**である（2026-06-10 に 1 件の逸脱を prompt 明記で解消した実績がある＝注入の問題と確認）。対処 = role 別注入（上表）。`bd prime` の一律注入と role 別注入の重複解消（PRIME 縮小 or 注入順序）は **案 A（PRIME を bd 基礎へ縮小 + role 別注入）で決定・実装済**（SSOT = role-context-spec §0・本リポ PRIME は role 中立・sc-aop）。

### v0 で作らないもの（v1+ へ後回し）

- **判断層の自動化**: findings 直読・merge 確認などの gate 判断は **v0 では自動化しない**（admin の手動判断のまま）。
- **背景 supervisor**: §10 の (b) 薄い背景 supervisor は **v1 以降**（v0 は (a) 最小 = admin が手動監視）。
- **堀（in-loop hook 強制の folio-spec 順守）**: §2 の堀は **v0 では OFF**。§5 graceful degradation の軽量モード（scribe 内蔵 backend・docs 一枚・provenance/署名なし）で動かす。folio backend と Gate α 厳格部は v1+ の後付け。
- **folio backend**: §5 の folio backend 実装は v1+。v0 は scribe 内蔵 backend のみ。

> **v0 の堀の状態 = OFF**（意識的受容）。§5「casual モードでは intent drift し得るのを意識的に受容」に従い、v0 は軽量モードの drift リスクを受容して着手速度を優先する。Gate β（準拠検証）相当の手動レビュー（adversarial review + cell-quality gate）は手動プロトコルとして既に回っている。

---

## 15. 残る open 枝（堀フェーズ・v1+ / scribe repo 着手後）

優先度順:

1. **folio に provenance/確定 ADR を起票（cross-plugin 依存・最優先）**
   scribe の確定フローより **先行が必要**。folio リポ側の作業（ubuntu-note-system の bd 管轄外）。Gate α は folio が provenance 対応を得て初めて完成する。
2. **administrator↔cc-session の supervision interface**（唯一の本当に新しい engineering）
   cc-session が scope 外にした「常駐・マルチウィンドウ統括」を scribe がどう実装するか（cc-session primitives 上の supervision ループ / ルーティング / worker ライフサイクル管理 / §10 の (a)→(b) 段階実装）。
3. **scribe⇔folio plugin 合成**
   scribe-architect skill を folio-architect と並行配置、folio hook を path 参照 or peer-plugin 依存で再利用。
4. **worker persona（impl/設計/検証）+ dynamic-workflow テンプレの具体実装**。
5. **administrator の制御ループ詳細**。
6. **twill 原則継承の具体**（ADR-021 / Pattern X' / Beads の scribe 実装への落とし込み）。

---

## 16. 実 scribe リポ作成時の移行チェックリスト

> 段階着手（§14）に合わせ **v0（堀 OFF・軽量モード）で今すぐ着手できる項目**と、**堀フェーズ（v1+）= folio 完成を要する項目**に分離した。v0 項を先に回し、堀フェーズ項は §14 の「v0 で作らないもの」と §15 の open 枝に対応する後付け。

### v0 チェックリスト（堀 OFF・今すぐ着手）

- [ ] `~/projects/local-projects/scribe/` を新規作成（`thesis-scribe` とは別物・無関係）。
- [ ] beads 導入は **`/scribe:setup` skill 経由**（`bd init` 直叩き禁止）。
- [ ] 本書 `docs/scribe-design.md` を scribe リポにコピーし初期設計ドキュメントとする。
- [ ] plugin 構造を起こす（`.claude-plugin/plugin.json` + `hooks/hooks.json` + `skills/` + `scripts/` + `docs/`）。実装形式 = **plugin**（skill は scripts 同梱のみ可・hooks/agents/MCP 同梱は plugin 専用＝一次情報 verified）。`claude/plugins/scribe` symlink 登録（session/folio と同型・ubuntu-note-system 側は別 PR）。
- [ ] **手動 admin プロトコルを plugin docs へ成文化**（§14: spawn 規約・close→gate→errata・worker prompt 規約・監視 busy regex・B/hybrid graph 所有境界）。project CLAUDE.md のポインタ縮小は別 PR。
- [ ] **role 判定つき SessionStart 文脈注入（admin / worker / consult）を実装**（§14）。実行時 guard で role 分離（worker = cwd `.worktrees/` 判定 / consult = 明示シグナル / admin = anchor）。**role 別 PRIME 分割**で worker への `bd create` 一律注入を止める（worker = 自 issue write + create/dep/push 禁止）。`bd prime` 注入との重複解消はここで決定。
- [ ] **道具（`scripts/`）を実装**（§14: spawn ヘルパー〔window は `@N` 捕捉で参照〕/ gate 起動ヘルパー〔cell-quality WF 呼出〕/ cleanup）。
- [ ] worker = cc-session セッション + persona、操舵 = session-comm inject、タスク = beads（B/hybrid）、知識 = doobidoo を compose。
- [ ] spec プロバイダ抽象（§5）は **scribe 内蔵 backend（軽量・docs 一枚・堀 OFF）だけを v0 で起こす**。

### 堀フェーズ チェックリスト（v1+・folio 完成を要する）

- [ ] **folio provenance ADR を folio リポで先に着手**（§15-1 / cross-plugin 依存ゆえ scribe 実装より前。Gate α は folio が provenance 対応を得て初めて完成）。
- [ ] plugin root `hooks/hooks.json` に §11 の PostToolUse diagnostics hook を実装（folio の既存 hook を path 参照で chain）。
- [ ] spec プロバイダ抽象（§5 コントラクト）の **folio backend** を追加（v0 の scribe 内蔵 backend に堀 ON 実装を足す）。
- [ ] provenance ハーネス + `scribe confirm`（A 運用・B 対応設計）を §6 に従って実装。
- [ ] supervise ループを (a) 最小から (b) 背景 supervisor へ切り出す（§10・context 圧で）。
- [ ] 着手後、ubuntu-note-system 側の本書はリポへのポインタに縮小可（`docs/plugin-system-spec.md` §4 と同期）。

---

## 17. 出所（doobidoo SSOT）

### 概念設計（§1〜§13）= conversation_id `scribe-redesign-grill-2026-06-04`

grill-me 一周で確定、実コード調査で grounding 済み:

| hash | 内容 |
|---|---|
| `e36e3046` | administrator 幹（user 代理 / anchor=folio spec / 堀=in-loop hook / 自律ダイヤル / A・B 署名昇格） |
| `23bfdac8` | 分解・境界（scribe 1枚 / impl 溶ける / Gate α=folio・β=scribe / spec プロバイダ抽象 / capability-negotiation） |
| `c71741c3` | 通信（共有ボード pull + ステアリング注入 push）/ 監視 = (b) 背景 supervisor |
| `b219ac98` | beads タスク管理 = B/hybrid（worker 自己直書き・admin が dolt push 所有・beads=live 共有ボード） |
| `5297cec9` | code-intelligence スタック（ripgrep + ast-grep + PostToolUse diagnostics、native LSP/Serena 常用不採用） |

### v0 段階着手（冒頭改訂経緯 + §14 + §15/§16 の v0/堀フェーズ分割）= conversation_id `scribe-v0-grill-2026-06-10`

2026-06-10 grill（7 論点完走・ユーザー ratify 済）の決定全文:

| hash | 内容 |
|---|---|
| `13447a54` | scribe v0 grill 確定（段階着手 = folio 待ち撤回 / v0 スコープ = 成文化+道具+role 別 SessionStart 注入 / 実装形式 = plugin〔skill は hooks 同梱不可 verified〕/ 並列独立リポ + symlink / consult = 第 3 role / 規約 SSOT = scribe plugin / scribe-design.md 改訂で単一 SSOT 維持 / role 別 PRIME 分割 = bd prime 一律注入が worker bd create 逸脱の構造原因という発見） |

> bd の一次記録: 決定の議事 = bd un-3v9 notes / 本改訂セル = bd un-5ez / v0 実装 epic = bd un-it7。

参考: `a47de93a`（Beads feasibility・Pattern X'）/ `4af8d45a`（twl2 clean-slate 計画）/ `d0afa13b`（code-intelligence 研究 differential）。

### 戦術層 D1-D7（§18）= 2026-06-15 grill

| hash | 内容 |
|---|---|
| `e5d79cc9` | worker/workflow モデル設計確定（戦術層 D1-D7・2 層モデル〔背骨層 = 独立セッション+プロンプト+beads / 戦術層 = 設計余地〕）+ project CLAUDE.md 整理方針。**§18 の決定全文の一次 SSOT**。運用方法論は `docs/methodology.md` §3、強度キャリブレーション = 規模×不確実性×リスクは同 §1 |

> bd の一次記録: 本 doc 化セル（D1-D7 を scribe へ記録 + methodology.md 新設）= bd un-av0 / 実装セル（D2 cap + D3 + D4 worker 側ラッパー）= S2。

> 設計の細部に疑義が出たら、本書ではなく上記 doobidoo の原典を recall して確認すること（本書は統合・整形版）。

---

## 18. 戦術層（tactical layer）の設計判断 — D1-D7（2026-06-15 grill）

> §12（worker substrate / dynamic-workflow の位置づけ）と §14（v0 スコープ）が引いた **2 層**を、戦術層の具体設計まで掘り下げて確定したのが本節。決定全文の一次 SSOT は doobidoo `e5d79cc9`（§17）、**運用方法論（how to operate）は `docs/methodology.md` §3**、本節は **設計 why（なぜその選択か・何を却下したか・構造的理由）** を担う（why ↔ how ↔ 方法論 の三分の規律は `docs/protocol.md` 前文・`docs/methodology.md` 前文が SSOT＝protocol.md ↔ scribe-design.md と同じ関心分離）。**本記録セル（bd un-av0）は決定の doc 化のみ**で、D2 cap・D3 dimensions 分業・D4 worker 側ラッパーの**実装は後続 S2 セル**に属する。

### 18.0 前提訂正 — 2 層で考える（why）

grill で最初に正した誤解: scribe worker は「workflow ファイルを渡される agent」ではない。**worker = 独立した完全な対話 CC セッション + persona/契約プロンプト + beads**（§3/§12 verified）であり、**worker 自身が実装する**。cell-quality WF は worker が自己点検で 1 回呼ぶ**戦術ツール**にすぎない。

→ ゆえに設計は **2 層に分けて**考える: **背骨層**（独立セッション + プロンプト + beads＝§3/§12/§14 で確定済・設計余地なし）と **戦術層**（worker タスク内の bounded fan-out をどう組むか＝設計余地）。**動的 ultracode は禁止ではないが背骨でもない**（§12 の「dynamic workflow = bounded 戦術 fan-out 専用・背骨ではない」の再確認）。D1-D7 はすべて**戦術層の中**の判断であり、背骨層を揺らさない。

### 18.1 D1 戦術層の背骨 = ハイブリッド（why）

**決定**: 不変骨格（cell-quality.workflow.js）+ worker が args 供給。動的 ultracode は bounded 戦術 fan-out のみ。
**why**: 骨格を毎回書き下ろすと収束硬化（loop-until-dry・escalate）や read-only 不変条件が worker の自由記述に溶けて再現性を失う。一方で全要件を骨格に焼くと固有物のたびに骨格分岐が増える。**「不変な品質構造は骨格・固有物は args」**の分担が、再現性（骨格）と柔軟性（args）を両取りする。`~/.claude/CLAUDE.md`「Workflow 骨格の再利用」（骨格を二度書かない・固有物は args で差す）と同じ思想。

### 18.2 D2 opus 並列 cap = args 化（why）

**決定**: `A.maxConcurrency` + 安全既定で渡せるようにする（実装 = S2）。
**why**: 現状 opus 経路は**無 cap**で、harness の `min(16, cores-2)` が実効上限になっているだけ（rate 逼迫時に絞る制御点が無い）。`makeLimiter` は既に max 引数の汎用セマフォとして存在する（fable ≤2 cap で使用中）ので、**新規機構でなく既存セマフォへ opus 経路を通すだけ**で cap が入る（低新規性 = §0「新規性の低い既存資産の合成を優先」と整合）。cap を**ハードコードでなく args** にするのは、rate 予算が案件ごとに違う（強度キャリブレーション §1）ため。

### 18.3 D3 dimensions 権限 = 枠分業（why）

**決定**: `dimensions` = `{key, focus}` 配列（長さ = review agent 数）。**admin gate = 必須 4 観点固定**（correctness / robustness-security / integration-ops / completeness-critic）+ 上限固定 / **worker 自己点検 = 4 必須 + focus 調整 + 追加観点可**。
**why**: admin の gate は**一次監査の最低保証**ゆえ観点が worker 任せで揺らいではいけない（固定 4 で監査の床を保証）。一方 worker の自己点検は**タスク特性を一番知っている主体**ゆえ focus を寄せ追加レンズを足せる方が検出力が上がる。**「監査の床は admin が固定・検出力の上積みは worker が調整」**の非対称が、gate の信頼性と self-check の鋭さを両立する。完全 admin 固定（worker に裁量なし）は worker の文脈知識を捨て、完全 worker 任せは gate の床を崩すため両端を却下。

### 18.4 D4 固定/可変境界 = 両方（why）

**決定**: **絶対不変**（read-only な doPlan/doImplement/autoFix・収束硬化・demoteFable）は **WF 本体にハードコード維持**、**固有合成**は**外部ラッパー**（`scripts/scribe-gate-args.sh` 型）。
**why**: 一次監査の安全条件（admin gate が実装/autoFix に化けない・review/verify が fable で走らない・loop が収束する）は**ラッパーから上書きされては困る**ので骨格本体に固定する（fail-safe を外部化しない）。逆に「どの worktree・どの selfTestCmd・追加 dimensions」のような**固有合成はラッパーで吸収**すれば骨格を触らずに済む。**「安全の核は内・固有合成は外」**の二分が、改竄耐性（内）と再利用性（外）を分離する。protocol.md §5 の `scribe-gate-args.sh`（doPlan/doImplement/autoFix を read-only にハードコード）がこの型の実例。

### 18.5 D5 汎用/固有の写像（why）

**決定**: 骨格（cell-quality.workflow.js）+ 汎用ラッパー（gate-args）= **scribe**（`~/.claude/workflows`・全 project 共有）/ 固有「**データ**」（selfTestCmd・追加 dimensions・probe）= **project**（CLAUDE.md or project 設定）。
**why**: **ラッパーの「ロジック」は汎用で、固有なのは「データ」だけ**という見極めが肝。固有データを骨格やラッパーの**ロジック**へ混ぜると、project ごとに WF/ラッパーが fork して保守が割れる（§0「安全に長期メンテ」が硬い制約）。データ（何をテストするか・どの観点を足すか）を外から注げば、汎用ロジックは 1 本で全 project を回せる。配置の境界は「全 project 共有か = scribe / その project 固有か = project」で決まる。

### 18.6 D6 per-project WF ファイル = 不要（why）

**決定**: 汎用 1 本 + args/ラッパーで吸収。骨格自体（フェーズ順序・ループ流れ）が違う要件が出たら作る留保。
**why**: D1-D5 の帰結として、固有物が args とラッパー（データ）で吸収できる限り **project 専用 WF を切る理由が無い**（per-project ファイルは骨格の重複 = ドリフト源）。例外は「骨格の形そのもの（phase 順序 / loop 構造）が違う」要件だが、それは未だ現れていないので**作らない**（YAGNI）。現れたら昇格（汎用化）か二層化を**その時**判断する留保を残す。

### 18.7 D7 ready-compaction = run 固有 WF 呼出を参照保持（why）

**決定**: run 固有の WF 呼び出し（`scriptPath` + args）は Working Memory「命令・制約」節に `[auto]` 参照として残す（新 carrier を足さない）。durable な project 固有は CLAUDE.md carrier、骨格は git carrier。
**why**: ready-compaction は carrier 別に責務が分かれている（effort 一時層 = Working Memory / 恒久命令 = CLAUDE.md / 横断事実 = doobidoo / 骨格 = git）。run 固有の WF 呼出は**その run 限りの effort 状態**なので Working Memory が正しい carrier であり、**新 carrier を作ると責務境界が壊れる**。骨格・durable 固有は既存 carrier（git / CLAUDE.md）に既に乗るので二重持ちしない。

> 一次出典: doobidoo `e5d79cc9`（§17・D1-D7 決定全文・2 層モデル）/ scribe-design.md §3・§12・§14（背骨層の確定）/ `docs/methodology.md` §3（D1-D7 運用方法論）・§1（強度キャリブレーション）/ `~/.claude/CLAUDE.md`「Workflow 骨格の再利用」「Workflow モデル階層ルーティング」/ `~/.claude/workflows/cell-quality.workflow.js`（`makeLimiter`/`demoteFable`/`dimensions`/read-only gate の実体・verified）。

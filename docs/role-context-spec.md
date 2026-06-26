# scribe role 別 SessionStart 文脈注入 — 内容仕様（C2 への設計引き渡し）

> **このファイルの位置づけ**
> scribe-design.md §14 の v0 第 3 本柱「role 判定つき SessionStart 文脈注入（3 role）」の **内容仕様 SSOT**。
> 本セル（bd un-led / C1）は仕様を起こした。**実装は後続 cell C2（bd un-ck2）で完了済み**＝`scripts/hooks/session-start-role-inject.sh`（executable・25+ 回帰テスト `session-start-role-inject.bats`・`hooks/hooks.json` の SessionStart wire が `[ -x ]` ガード付きで live 参照）。本書は以後その**内容仕様 SSOT** として機能し、実装メモは §3 に置く（sc-gub: 旧「後続 C2・現状 no-op」記述を実装済みへ訂正）。
>
> 各 role の「何を伝え／何を禁止するか」を定める。注入する規約本文の how は `docs/protocol.md`（規約 SSOT）から引く（本書で重複させない＝ドリフト防止）。

---

## 0. なぜ role 別に分割するか（構造原因）

現状 `bd prime` の SessionStart hook が **全セッション（worker 含む）へ無条件**に「非自明な作業は着手前に `bd create`」を注入している。これは B/hybrid（worker は graph を操作しない・`bd create`/`dep` しない・notes 提案 → admin 起票）と**矛盾**し、worker の `bd create` 逸脱の**構造原因**である（2026-06-10 に 1 件の逸脱を prompt 明記で解消した実績＝注入の問題と確認・`verified`）。

→ 対処 = **role 別注入**（下表）。`bd prime` の一律注入と role 別注入の重複解消は **案 A 責務分割**で確定: PRIME は bd 基礎へ縮小し、役割規約は scribe 注入が SSOT になる（PRIME の bd 基礎への縮小・注入 live はいずれも実施済＝本リポの `bd prime` 出力は role 中立・SessionStart 注入は live。経緯 = 別 cell C4 / bd un-0c6）。

> 一次出典: doobidoo `13447a54`（role 別 PRIME 分割 = 構造原因の発見）/ `e2addec8`（PRIME 重複 = 案 A 責務分割）/ scribe-design.md §14「role 別分割の根拠」。

---

## 1. role 判定仕様（2026-06-11 grill 確定）

### 1.0 注入の前提ガード（.beads opt-in・bd un-7hx）

役割判定の**前段**に、そもそもこのセッションが scribe 管轄かを判定する opt-in ガードを置く。SessionStart hook はグローバル登録され**ホストの全セッションで発火**するため、ガード無しでは scribe を使わない無関係プロジェクト（paper 等）にまで admin 規約（数千 token）を注入してしまう。

- **判定**: 解決した cwd（`SessionStart` JSON の `.cwd`、無ければ `$PWD`）の**直下に `.beads/` ディレクトリが存在する**か、または**その git toplevel に `.beads/` が存在する**ときだけ注入する。
- **代理マーカーの妥当性**: `.beads` = scribe opt-in の代理マーカー。beads は scribe の前提 substrate（issue グラフ無しに scribe は成立しない）ゆえ「`.beads` あり ⇔ scribe 管轄」が一致する。
- **git toplevel フォールバックの理由**: cwd が repo のサブディレクトリ（例 `anchor/docs/`）のとき `.beads/` は直下に無いが toplevel にはある。これを拾うため `git rev-parse --show-toplevel` で補う（git 不在・非 repo では無害に失敗し「`.beads` 無し」へ倒れる＝fail-safe）。
- **ガード不成立時の挙動**: role 判定すら行わず、**stdout/stderr とも無出力で `exit 0`**（現行 fail-safe を維持し、無関係セッションを一切汚さない）。
- **適用順**: このガードは `SCRIBE_ROLE` env 明示より**外側**（最優先）。明示 role があっても `.beads/` が無ければ注入しない（scribe 管轄外で role を騙る誤注入を防ぐ。正規の consult/admin は `.beads` を持つ anchor で動くため実害なし）。
- **本ガードと scribe 自身（自己管理）**: scribe repo は現在**自身の `.beads/`（prefix `sc-`）を持ち scribe 自身で自己管理する**（CLAUDE.md 冒頭が SSOT）。ゆえに本ガードを通過し、**素の scribe checkout を直接開いた anchor セッションは admin 注入が発火する**（`.beads` あり = scribe 管轄・anchor 無印 = admin）。`.worktrees/` 配下の scribe-code worker セッションは worker 判定となり、その役割文脈は `scribe-spawn.sh` 生成の spawn prompt が主担体（注入は protocol §2/§3/§4 のみ）。注入を残したい satellite repo があれば、その repo に `.beads/`（redirect でも可）を置けば opt-in できる。（歴史的経緯: 旧くは scribe を ubuntu-note-system 側の beads で管理し `.beads/` を持たなかったため、本ガード後に注入ゼロ＝自己抑制となっていた。scribe 自身を `.beads/` で自己管理する構成に移行して解消した。）

> 一次出典: bd un-7hx（grill 確定: doobidoo `2ad028a2` + 2026-06-11 設計議論。背景＝ガード無しで全ホストへ admin 注入が漏れる）。実装は `scripts/hooks/session-start-role-inject.sh` の `_scribe_has_beads()`。

### 1.1 role 判定（前段ガード通過後）

SessionStart hook には role 宣言機構が無いため、**実行時 guard** で 3 role を分離する。優先順位（上から評価し最初に当たったもの）:

| 優先 | 判定 | role | 根拠 |
|---|---|---|---|
| 1（最優先） | 環境変数 `SCRIBE_ROLE=consult` が明示されている | **consult** | env シグナルを一次に（doobidoo `e2addec8` で確定）。anchor 同居の read-only セッションを誤って admin 扱いしないため、明示シグナルを最上位に置く |
| 2 | cwd が `.worktrees/` 配下（worktree セッション） | **worker** | worktree = worker の構造的マーカー（scribe-design.md §14） |
| 3（既定） | 上記いずれにも当たらない（anchor・無印） | **admin** | anchor 無印 = admin 既定（2026-06-11 grill 確定） |

- **`SCRIBE_ROLE` は consult の明示にのみ使う**のが一次。worker の admin/consult 上書きが必要なら env で明示できる設計にしてよいが、**既定の流れは `SCRIBE_ROLE`(consult) > cwd(.worktrees → worker) > 無印(admin)**。
- window 名は**表示のみ**（判定には使わない）。判定を window 名に依存させると spawn 命名規約（`docs/protocol.md` §1）との結合が増えるため。
- **`SCRIBE_ROLE=none` は既知の opt-out**: role を抑止し hook は無出力で `exit 0` する（未知値の degrade＝cwd/既定 admin 注入とは異なり、warning も出さない）。自前の `.beads/`（別 prefix）を持つ別レイヤ（orchestrator 等）が `.beads` opt-in ガードを通過してもなお「どの scribe role 注入も受けない」ことを機械保証するための明示シグナル。これは **advisory**（表示・文脈注入の抑止）であり、実隔離（別レイヤが foreign 台帳を書かないこと）は scribe role 注入の中身に依存せず**その層自身の guard が担う**（doobidoo `bfe0ce39` の提案を `115521de` が「cosmetic/advisory・nice-to-have」と確定）。

> 一次出典: doobidoo `e2addec8`（consult 識別 = env var `SCRIBE_ROLE` 一次・anchor 無印 = admin 既定・window 名は表示のみ）/ scribe-design.md §14（worker = cwd `.worktrees/` 判定 / consult = 明示シグナル / admin = anchor）。

---

## 2. role 別 注入内容仕様

### 2.1 admin（anchor / orchestrator セッション）

**伝える**: プロトコル全文（`docs/protocol.md` 全節）。admin は graph の所有者であり funnel の実行者なので、全手順を持つ。

- graph 所有: `bd create` / `bd dep`（依存 wire）/ assignment / 最終判断（§3 admin の所有）。
- cross-ledger 境界（複数台帳併存・federated）: **write は自 `sc-` 台帳のみ**・他 project 台帳（`un-`/`cc-`）は read+provenance 保持・機密本文は durable copy 禁止・doobidoo を SPOF にしない（SSOT = `docs/protocol.md` §8。admin 専用ゆえ worker/consult 注入には含めない）。
- gate funnel 手順（§5）: worker 報告監査 → cell-quality gate review（read-only・worktree 指定）→ findings 直読 → merge gate（§5.4 二段判定・merge 自体は非トリガー）→ squash / 条件付き auto-merge → go-live → cleanup。
- errata 規約（§4）: close 後 findings は notes-append・closed のまま追補・substantive のみ reopen。
- `bd dolt push` = 同期点（§3・§5 末）。**push できるのは admin だけ**。
- spawn 規約（§1）・監視（§6）。
- **方法論ポインタ（薄い）**: multi-agent fan-out（cell-quality gate review / 調査 sweep 等）を **orchestrate する前に `docs/methodology.md` を確認する**（強度キャリブレーション = 規模×不確実性×リスク・quality patterns・D1-D7 運用方法論）。注入は本文転記でなく**ポインタ 1 行**に留める（方法論 SSOT は methodology.md・規約 how は protocol.md）。

**禁止**: 特になし（admin は full 権限）。ただし **merge gate（§5.4 二段判定・orch-8is ratify）** は admin の義務として注入する——**merge 自体は非トリガー**で、(a) 不可逆カテゴリ（規約ファイル / 全ホスト配布物 / 新規 outward への diff touch）は機械判定で無条件ユーザー確認、(b) それ以外の実装ズレは AI gate が「事前合意からの明確な逸脱」と高確信した時のみ確認（グレーは fail-open 通過）。無確認 auto-merge 時は対象 bd notes に証跡（`auto-merged: …`）を残す。

### 2.2 worker（worktree セッション）

**伝える**: 自 issue の write だけ（B/hybrid・`docs/protocol.md` §3）。

- 自分が claim した issue の `bd update --claim` / `--append-notes` / `bd close`。**write は必ず `bdw` 経由**（`cd <anchor> && scripts/bdw <subcmd>`・flock 直列化で lost-update 防止）。
- worker prompt 規約（§2）: tests 同梱・selfTest fail-closed・cell-quality WF 直接呼出・報告に WF 返り値 JSON + `receivedArgs` 必須。
- close → gate の順序（§4）: PR-up で自己申告 close、gate は admin が後で回す。

**禁止（明示・定型で注入）**:
- `bd create` / `bd dep` / assignment（graph は admin の所有物・worker は触らない）。
- `bd dolt push`（同期点は admin 専用）。
- GitHub への push / `gh repo create` / admin window への tmux inject / 編集可スコープ外の編集。
- **follow-up の bd create**: タスク化が要っても自分で起票せず、自 issue の notes に「admin への起票候補」として書き出す（起票は admin）。

> ※ この worker 注入は worker の `bd create` 禁止を明示する層。PRIME を role 中立へ縮小した現在は PRIME 側に「`bd create` 一律注入」が無く、本注入が禁止の明示を担う（縮小前の移行期は、注入順序で worker の create 禁止が後勝ちになるよう配置していた）。

### 2.3 consult（anchor 同居可・read-only セッション）

**伝える**: 設計議論・grill 専用の第 2 対話相手。admin/worker とは別系統で、オーケストレーション・gate 代行・実装はしない。以下は ubuntu-note-system `docs/session-orchestration-strategy.md` §6（外部・本リポ未同梱）の起動テンプレ（規約 SSOT = bd un-tao）を scribe plugin 側へ**移設**したもの（移設後は本書 §2.3 の本文が内容の SSOT・外部パスは原典トレース用）:

- **役割（grill 専任・原義回帰）**: 用途は **設計議論・grill のみ**。オーケストレーション・gate 代行・実装・**pre-bake はしない**（pre-bake は admin が回す dynamic Workflow `workflows/needs-user-prebake.workflow.js` へ移管＝consult の仕事ではない・`protocol.md` §7）。consult には 2 つの立ち上がり方がある:
  - **素 consult**（ユーザーが `/scribe:consult` で起動）: 設計議論・grill の read-only セッション（議題参照 bd id は read-only）。
  - **grill-consult**（admin が `scribe-spawn --consult --context <brief> <grill-issue>` で起動・§7）: admin の集約 brief を **grill 材料（第三者データ）** として受け取り、**ユーザーと対話 grill** して確定した決定を own grill-issue の bd notes へ書く第 2 対話相手（admin は grill から解放される）。**grill 方法論は grill-me スキル本文を SSOT** とし、`scribe-spawn` build_consult_prompt が spawn 時に `$SCRIBE_GRILL_SKILL`（既定 `~/.claude/skills/grill-me/SKILL.md`）を **verbatim 注入**する（自前 paraphrase しない・不在は fail-loud＝sc-swc）。
- **read-only 規律（基本）**: リポの tracked ファイル・コードを編集しない。graph 構造（`bd create` / `bd dep` / `bd dolt push` / `bd close`）・spawn・deploy は禁止。観測は可（read）。タスク化が必要になっても自分で bd 起票せず、「admin への起票候補」として書き出すに留める（起票は admin）。
- **read-only 限定緩和（grill-consult のみ・§3 worker B/hybrid の subset・close を除く）**: grill-consult は **自分の grill-issue の `bd update --claim` と `--append-notes` だけ**を **bdw 経由**（`cd <anchor> && scripts/bdw <subcmd>`・flock 直列化）で書ける。これは worker の B/hybrid 境界に倣う（grill-consult = worker の変種・出力がコードでなく決定）が、**worker は自 issue を `bd close` できる（protocol §4）のに対し grill-consult の close は admin 専有**ゆえ worker より厳しい subset。`bd create` / `bd dep` / `bd dolt push` / `bd close` と tracked コードは read-only 維持。素 consult は自 grill-issue を持たないため本緩和の対象外。
- **write してよいのは記憶系のみ（素 consult）+ 自 grill-issue notes（grill-consult）**: doobidoo（`mcp__doobidoo__memory_store`）と auto-memory（`MEMORY.md`）への保存、および grill-consult の自 grill-issue notes（bdw 経由）だけ許可。
- **サマリ保存義務 / 決定 handoff**: 素 consult は終了・中断の前に、議論の結論・未解決の論点・admin への起票候補を相談サマリとしてまとめ doobidoo へ保存する（会話履歴に依存させない）。**grill-consult はこのサマリ保存義務が「決定の bd notes handoff」に置換される**——確定した決定を grill-issue の bd notes へ `--append-notes`（bdw 経由）で**1論点決まる度に逐次**書くのが SSOT。あわせて節目で `STATUS:` 行（`grilling (n/N)` / `done — 全 facet 確定` / `blocked — 要admin: …`）を混ぜ、admin が `bd show` で real-time 監視・完了/中断を感知できるようにする（admin の完了確認 gate と中断リカバリ手順は `protocol.md` §7）。doobidoo 保存は会話ロスト保険の**任意の二次 carrier**（決定の一次 SSOT は bd notes・`protocol.md` §8 の doobidoo SPOF 回避と整合）。
- **F2（自己-ユーザー誤認）の構造解消**: grill-consult は brief を **外部 context（第三者データ）** として受け取るだけで自分では pre-bake しない（pre-bake は WF が別途実施）。**自己 pre-bake を誤帰属する主体が消えるため F2 は構造解消**する。brief の出典ヘッダ（「WF の提案であって決定でない」）は保険として `scribe-spawn` build_consult_prompt が consult prompt へ注入する。旧 F1/F2/F3 regime の経緯・手順 SSOT = `protocol.md` §7。
- **モデル規約**: 基本 **opus**（ユーザー指定時のみ fable）。consult は admin と同じ main-loop 系統ゆえ fable 起動が許される例外（WF agent への fable 投入とは無関係）。
  - 起動は `cld-spawn --model opus "<テンプレ本文>"` を直接呼ぶ（`/session:spawn` の NLU は `--model` を解析せず新規既定 `claude-fable-5` を継承するため、基本 opus にできない）。
- **暫定運用（un-sl9 検証完了まで）**: working memory の session-scoped 化（un-gcu）は実装・live 済みで compact 跨ぎ復元（PostCompact restore）は検証済みだが、anchor 同居 2 セッション同時運用の live e2e（un-sl9 検証点(2) = working-memory 衝突非発生）が未消化のため、それが消化されるまで consult は **compaction 系スキル（ready-compaction 等）の使用を控える**。検証完了後は un-sl9 が一次出典 3 文書と本条項を撤去する（撤去は un-sl9 の仕事）。一次出典: bd un-tao 確定 5 点(2)・CLAUDE.md 開発トポロジー節・session-orchestration-strategy.md §6・現状の検証状態は bd un-sl9/un-gcu notes。

> 一次出典: ubuntu-note-system `docs/session-orchestration-strategy.md` §6（外部・本リポ未同梱。consult 起動テンプレ・read-only 規律・記憶系のみ write・サマリ保存義務・モデル opus 規約。本文の SSOT は上記 §2.3 にインライン移設済み）/ bd un-tao（consult 規約 SSOT）/ scribe-design.md §14（consult = 第 3 role・docs §6 テンプレを scribe plugin へ移設）/ bd sc-cuw（grill 専任への再編・pre-bake の Workflow 化・read-only 限定緩和＝自 grill-issue notes・F2 構造解消。手順 SSOT = `protocol.md` §7）。

---

## 3. C2（bd un-ck2）実装メモ（実装済み = `session-start-role-inject.sh`）

> **状態（sc-gub）**: 本節は元は C2 への future handoff だった。C2 は実装完了済み（`scripts/hooks/session-start-role-inject.sh`・executable・25+ 回帰テスト）。以下は実装の **decision record** として残す（未着手 TODO ではない）。

- 実装先: `scripts/hooks/session-start-role-inject.sh`（`hooks/hooks.json` の SessionStart wire が `[ -x ]` ガードで参照済み）。
- §1 の判定で role を解決し、§2 の role 別内容を `docs/protocol.md` から引いて SessionStart 出力（additionalContext）として注入する。**規約本文は protocol.md を SSOT とし、注入 script は「どの節を出すか」だけを持つ**（本文を script に二重化しない）。
- PRIME 重複の解消（案 A 責務分割・PRIME を bd 基礎へ縮小）は実施済＝本リポの `bd prime` は role 中立（経緯 = 別 cell C4 / bd un-0c6）。縮小前の移行期は注入順序で worker の create 禁止が後勝ちになるよう配置していた。
- v0 は堀 OFF。PostToolUse diagnostics hook（scribe-design.md §11）は配線しない（v1+）。
- **C2 着手時の selftest 強化（C1 gate からの引き継ぎ）**: C1 の `selftest-<id>.local.sh` は hooks.json の安全性を「ガード idiom（`[ -x`/`test -x`）の存在」の部分一致で検査する。これは見せかけガード + 末尾無条件実行（`[ -x "$S" ] && "$S"; evil.sh` 等）を false-PASS しうる脆い判定（C1 gate finding・出荷物 hooks.json 自体は真に no-op で安全のため C1 では minor 据置）。C2 は `session-start-role-inject.sh` を実装し wire を編集する際、selftest の hook 検査を「各 command を `;`/`&&`/`||` で分割し、`${CLAUDE_PLUGIN_ROOT}` script 参照を含む実行 token が必ず直前ガードに支配される」or「`CLAUDE_PLUGIN_ROOT` を未存在パスにして実行し副作用ゼロ・exit 0 をドライラン観測」する dynamic assertion へ**強化した（実施済・`session-start-role-inject.bats` の「安全形 dynamic」テスト）**。

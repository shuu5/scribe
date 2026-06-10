# scribe role 別 SessionStart 文脈注入 — 内容仕様（C2 への設計引き渡し）

> **このファイルの位置づけ**
> scribe-design.md §14 の v0 第 3 本柱「role 判定つき SessionStart 文脈注入（3 role）」の **内容仕様 SSOT**。
> 本セル（bd un-led / C1）は仕様だけを起こす。**実装（role guard + role 別 SessionStart 注入の hook script）は後続 cell C2（bd un-ck2）**。`hooks/hooks.json` の SessionStart wire は `scripts/hooks/session-start-role-inject.sh` を `[ -x ]` ガード付きで参照済み（未実装の現状は no-op）。
>
> 各 role の「何を伝え／何を禁止するか」を定める。注入する規約本文の how は `docs/protocol.md`（規約 SSOT）から引く（本書で重複させない＝ドリフト防止）。

---

## 0. なぜ role 別に分割するか（構造原因）

現状 `bd prime` の SessionStart hook が **全セッション（worker 含む）へ無条件**に「非自明な作業は着手前に `bd create`」を注入している。これは B/hybrid（worker は graph を操作しない・`bd create`/`dep` しない・notes 提案 → admin 起票）と**矛盾**し、worker の `bd create` 逸脱の**構造原因**である（2026-06-10 に 1 件の逸脱を prompt 明記で解消した実績＝注入の問題と確認・`verified`）。

→ 対処 = **role 別注入**（下表）。`bd prime` の一律注入と role 別注入の重複解消は **案 A 責務分割**で確定: PRIME は bd 基礎へ縮小し、役割規約は scribe 注入が SSOT になる（縮小は注入 live 後・別 cell C4）。

> 一次出典: doobidoo `13447a54`（role 別 PRIME 分割 = 構造原因の発見）/ `e2addec8`（PRIME 重複 = 案 A 責務分割）/ scribe-design.md §14「role 別分割の根拠」。

---

## 1. role 判定仕様（2026-06-11 grill 確定）

SessionStart hook には role 宣言機構が無いため、**実行時 guard** で 3 role を分離する。優先順位（上から評価し最初に当たったもの）:

| 優先 | 判定 | role | 根拠 |
|---|---|---|---|
| 1（最優先） | 環境変数 `SCRIBE_ROLE=consult` が明示されている | **consult** | env シグナルを一次に（doobidoo `e2addec8` で確定）。anchor 同居の read-only セッションを誤って admin 扱いしないため、明示シグナルを最上位に置く |
| 2 | cwd が `.worktrees/` 配下（worktree セッション） | **worker** | worktree = worker の構造的マーカー（scribe-design.md §14） |
| 3（既定） | 上記いずれにも当たらない（anchor・無印） | **admin** | anchor 無印 = admin 既定（2026-06-11 grill 確定） |

- **`SCRIBE_ROLE` は consult の明示にのみ使う**のが一次。worker の admin/consult 上書きが必要なら env で明示できる設計にしてよいが、**既定の流れは `SCRIBE_ROLE`(consult) > cwd(.worktrees → worker) > 無印(admin)**。
- window 名は**表示のみ**（判定には使わない）。判定を window 名に依存させると spawn 命名規約（`docs/protocol.md` §1）との結合が増えるため。

> 一次出典: doobidoo `e2addec8`（consult 識別 = env var `SCRIBE_ROLE` 一次・anchor 無印 = admin 既定・window 名は表示のみ）/ scribe-design.md §14（worker = cwd `.worktrees/` 判定 / consult = 明示シグナル / admin = anchor）。

---

## 2. role 別 注入内容仕様

### 2.1 admin（anchor / orchestrator セッション）

**伝える**: プロトコル全文（`docs/protocol.md` 全節）。admin は graph の所有者であり funnel の実行者なので、全手順を持つ。

- graph 所有: `bd create` / `bd dep`（依存 wire）/ assignment / 最終判断（§3 admin の所有）。
- gate funnel 手順（§5）: worker 報告監査 → cell-quality gate review（read-only・worktree 指定）→ findings 直読 → merge 前ユーザー確認 → squash merge → go-live → cleanup。
- errata 規約（§4）: close 後 findings は notes-append・closed のまま追補・substantive のみ reopen。
- `bd dolt push` = 同期点（§3・§5 末）。**push できるのは admin だけ**。
- spawn 規約（§1）・監視（§6）。

**禁止**: 特になし（admin は full 権限）。ただし「merge 前ユーザー確認」（規約/全ホスト影響/outward）は admin の義務として注入する。

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

> ※ この worker 注入が、§0 の「`bd prime` 一律 `bd create` 注入」を打ち消す層。PRIME 縮小（C4）前は注入順序で worker の create 禁止が後勝ちになるよう配置する。

### 2.3 consult（anchor 同居可・read-only セッション）

**伝える**: 設計議論・grill 専用の第 2 対話相手。admin/worker とは別系統で、オーケストレーション・gate 代行・実装はしない。以下は ubuntu-note-system `docs/session-orchestration-strategy.md` §6（外部・本リポ未同梱）の起動テンプレ（規約 SSOT = bd un-tao）を scribe plugin 側へ**移設**したもの（移設後は本書 §2.3 の本文が内容の SSOT・外部パスは原典トレース用）:

- **役割と禁止**:
  - 用途は設計議論・grill のみ。オーケストレーション・gate 代行・実装はしない。
  - **read-only 規律**: リポの tracked ファイル・コードを編集しない。bd の write（create/update/close/dolt push）・spawn・deploy は禁止。
  - 観測は可（read）。タスク化が必要になっても自分で bd 起票せず、相談サマリに「admin への起票候補」として書き出すに留める（起票は admin）。
- **write してよいのは記憶系のみ**: doobidoo（`mcp__doobidoo__memory_store`）と auto-memory（`MEMORY.md`）への保存だけ許可。
- **サマリ保存義務（必須）**: 終了・中断の前に、議論の結論・未解決の論点・admin への起票候補を相談サマリとしてまとめ、doobidoo へ保存する（会話履歴に依存させない）。
- **モデル規約**: 基本 **opus**（ユーザー指定時のみ fable）。consult は admin と同じ main-loop 系統ゆえ fable 起動が許される例外（WF agent への fable 投入とは無関係）。
  - 起動は `cld-spawn --model opus "<テンプレ本文>"` を直接呼ぶ（`/session:spawn` の NLU は `--model` を解析せず新規既定 `claude-fable-5` を継承するため、基本 opus にできない）。

> 一次出典: ubuntu-note-system `docs/session-orchestration-strategy.md` §6（外部・本リポ未同梱。consult 起動テンプレ・read-only 規律・記憶系のみ write・サマリ保存義務・モデル opus 規約。本文の SSOT は上記 §2.3 にインライン移設済み）/ bd un-tao（consult 規約 SSOT）/ scribe-design.md §14（consult = 第 3 role・docs §6 テンプレを scribe plugin へ移設）。

---

## 3. C2（bd un-ck2）への実装メモ

- 実装先: `scripts/hooks/session-start-role-inject.sh`（`hooks/hooks.json` の SessionStart wire が `[ -x ]` ガードで参照済み）。
- §1 の判定で role を解決し、§2 の role 別内容を `docs/protocol.md` から引いて SessionStart 出力（additionalContext）として注入する。**規約本文は protocol.md を SSOT とし、注入 script は「どの節を出すか」だけを持つ**（本文を script に二重化しない）。
- PRIME 重複の解消（案 A 責務分割・PRIME を bd 基礎へ縮小）は注入 live 後・別 cell（C4 = bd un-0c6）。それまでは注入順序で worker の create 禁止が後勝ちになるよう配置する。
- v0 は堀 OFF。PostToolUse diagnostics hook（scribe-design.md §11）は配線しない（v1+）。
- **C2 着手時の selftest 強化（C1 gate からの引き継ぎ）**: C1 の `selftest-<id>.local.sh` は hooks.json の安全性を「ガード idiom（`[ -x`/`test -x`）の存在」の部分一致で検査する。これは見せかけガード + 末尾無条件実行（`[ -x "$S" ] && "$S"; evil.sh` 等）を false-PASS しうる脆い判定（C1 gate finding・出荷物 hooks.json 自体は真に no-op で安全のため C1 では minor 据置）。C2 が `session-start-role-inject.sh` を実装して wire を編集する際は、selftest の hook 検査を「各 command を `;`/`&&`/`||` で分割し、`${CLAUDE_PLUGIN_ROOT}` script 参照を含む実行 token が必ず直前ガードに支配される」or「`CLAUDE_PLUGIN_ROOT` を未存在パスにして実行し副作用ゼロ・exit 0 をドライラン観測」する dynamic assertion へ強化すること。

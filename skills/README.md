# scribe/skills

scribe plugin の skill 群を置くディレクトリ。各サブディレクトリの `SKILL.md` が plugin 機構で自動検出され、
`/scribe:<skill 名>` 名前空間で出る（plugin.json への明示登録は不要）。

## 現在の skill（bd un-01h / C6b で新設）

- **`consult/`** → `/scribe:consult`: 設計議論・grill 専用の第 2 対話相手（consult role）を起動する。
  `scripts/scribe-spawn.sh --consult` の薄い wrapper。ユーザーが consult を能動起動する唯一の入口。
  役割・禁止・モデル規約の SSOT は `docs/role-context-spec.md` §2.3。
- **`setup/`** → `/scribe:setup`: scribe を使い始めるプロジェクトの beads(bd) セットアップを我々の正しい構成へ
  冪等収束させ、scribe role 別 SessionStart 注入を opt-in 成立させる reconciler（旧 ubuntu-note-system
  `beads-init` を移管）。`PRIME.template.md`（role 中立版）を同梱する。
- **`resume/`** → `/scribe:resume`（bd sc-8eyw で新設）: admin respawn / compaction 後の**第一手**。退避した
  Working Memory と bd の現在値を突合し、brief〔判定根拠 / 推奨 / 次アクション / hygiene tripwire〕を定型出力して
  current session の WM を consumed 化する（`.md`→`.consumed.md` の mv）。機械層（DATA の read-only fetch）は
  `scripts/scribe-resume-fetch.sh`、判断と consume が本 skill＝**機械 fetch / LLM judgment** の分担。
  退避側の対は cc-session の `/session:ready-compaction`（cc-session は **user-scope enable が前提**）。

## 配置規約

- skill は scripts 同梱のみ可。hooks/agents/MCP の同梱は plugin 専用（一次情報 verified・scribe-design.md §16 v0 チェックリスト）。よって scribe は plugin 形態を採る。
- 注意: spawn/gate/cleanup は **skill 化しない**（実行主体 = admin AI・注入 + protocol ポインタで解決 = C6a。bd un-01h 方針確認）。skill 化するのは「ユーザーが能動起動する入口」（consult）と「opt-in セットアップ」（setup）のみ。

→ skill 設計の SSOT は `docs/protocol.md`（成文化された手動プロトコル）と `docs/role-context-spec.md`（role 別注入仕様）。

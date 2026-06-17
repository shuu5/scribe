# scribe — プロジェクト CLAUDE.md

scribe は per-project opt-in の Claude Code plugin（admin / worker / consult の役割別オーケストレーション基盤）。本リポは scribe **自身のソース**であると同時に、`.beads/` を持つことで scribe 自身で自己管理される（scribe role 別 SessionStart 注入が本リポでも発火する＝anchor 既定で admin）。

## タスク追跡 = beads (bd) / 知識 = doobidoo

- **タスク → bd（beads, prefix `sc-`）**: 永続・横断の作業は bd issue で追跡。SessionStart hook が `bd prime` で基礎文脈を毎セッション注入する（SSOT = `.beads/PRIME.md`）。bd は **v1.0.4 にピン**（`bd upgrade` / `npm install -g @beads/bd` 禁止・upstream #4259）。
- **知識・知見 → doobidoo**（`mcp__doobidoo__memory_store` / `memory_search`）。**`bd remember` / `bd recall` / `bd memories` は使わない**（consolidation 機構が無く肥大化する）。beads はタスク専用。

## 役割規約の SSOT（CLAUDE.md に本文を重複させない）

役割を帯びた規約（誰が `bd create` / `dep` / `dolt push` / close するか・gate funnel・終了プロトコル）の本文 SSOT は **本リポの `docs/` と role 別 SessionStart 注入**。CLAUDE.md はポインタのみを持つ（`docs/protocol.md` 前文・`docs/role-context-spec.md` §0 が「CLAUDE.md は本文重複を持たずポインタに縮小」と規定）。

- **役割判定**（実装 `scripts/hooks/session-start-role-inject.sh` / 仕様 SSOT `docs/role-context-spec.md`）: ① `SCRIBE_ROLE=consult` → consult、② cwd が `.worktrees/` 配下 → worker、③ anchor 無印 → admin（既定）。
- **admin プロトコル手順（how）** = `docs/protocol.md`（spawn / worker prompt 規約 / B-hybrid 境界 / close→gate→errata / gate funnel / 監視）。
- **ワークフロー方法論**（ultracode 強度・品質パターン・D1–D7）= `docs/methodology.md`。
- **設計の why** = `docs/scribe-design.md`（scribe 側が現行 SSOT）。
- **B/hybrid 境界**: admin が graph を所有（`bd create` / `dep` / `bd dolt push` = 唯一の同期点）。worker は自 issue の `bd update --claim` / `--append-notes` / `bd close` のみ。並列 worker 時の bd write は flock で直列化（`scripts/bdw`）。

## 他プロジェクトへの導入

他リポで scribe を導入・収束させるには `/scribe:setup`（冪等 reconciler）。bd 既定の汚染・二重発火・旧役割入り PRIME を検出・是正し、未導入なら正しく入れる。

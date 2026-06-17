[bd prime] このリポの永続タスク台帳のワークフロー文脈。ポリシーの SSOT はこの `.beads/PRIME.md`（`bd prime` 出力を上書き）。出力が切れていたら全文を読んでから続行すること。

# Beads Workflow Context (scribe)

> SessionStart hook が `bd prime` を自動実行し、この内容を注入する（新規・resume・clear・compaction 後の再開）。compaction 後は PostCompact(ready-compaction) で Working Memory が、SessionStart で本文脈が復元される。

## 役割分担（最重要）
- **タスク → beads**: 着手中 / 保留 / 依存のある作業は bd issue で追跡。セッションを跨いで永続する。
- **知識・知見 → doobidoo**: `mcp__doobidoo__memory_store` / `mcp__doobidoo__memory_search` を使う。**`bd remember` / `bd recall` / `bd memories` は使わない**（consolidation 機構が無く肥大化するため）。beads はタスク専用。
- 一時的なセッション内 TODO（TodoWrite）や workflow / Agent オーケストレーションは併用してよい。ただし**セッションを越えて残すべき作業は必ず bd issue 化**する。

## セッション終了時の bd（role 中立の基礎）
- 完了した issue は `bd close <id> [--reason "..."]` で閉じる。
- コードは標準 PR ワークフロー（`main` へ直 push しない）。

> **役割を帯びた規約の SSOT は scribe plugin の role 別 SessionStart 注入**（admin / worker / consult）。「誰が `bd create` / `bd dep` / `bd dolt push` / close するか・残作業のフォローアップ起票の可否・終了プロトコルの全手順・close→gate の順序」は role ごとに scribe が配る（規約本文は scribe plugin の `docs/protocol.md`）。本 PRIME は role 中立な bd 基礎のみを持ち、役割を帯びた指示を全セッションへ一律注入しない（案 A 責務分割＝worker への過剰注入が `bd create` 逸脱の構造原因。scribe `docs/role-context-spec.md` §0）。scribe plugin を導入していないプロジェクトでは、本節は「単独 worker は素の bd で運用」と読み替えてよい。

## ⚙️ バージョン固定・保守（重要）
- **bd は v1.0.4 にピン**。`bd upgrade` や `npm install -g @beads/bd`(latest) を実行しないこと。v1.0.5+ は migration 0043 がマルチマシン同期を破壊する（upstream #4259）。
- このプロジェクトの beads は `bd init --skip-agents --skip-hooks` で導入済（bd に CLAUDE.md/AGENTS.md を汚染させない）。本 PRIME.md がポリシー SSOT で、bd は再生成しない。

## Core Rules
- 着手する issue は `bd update <id> --claim` で in_progress 化する（新規 issue の起票 `bd create`・依存 wire は role 規約に従う＝上記の scribe role 注入を参照）。
- セッション開始時は `bd ready` で着手可能タスクを確認。
- `bd edit` は使わない（$EDITOR を開きエージェントをブロックする）→ `bd update <id> --description/--title/--notes` でインライン更新。
- priority は 0-4 / P0-P4（0=critical, 2=medium, 4=backlog）。"high"/"medium"/"low" は不可。
- 依存は blocks / parent-child 等。`bd ready` をブロックするのは blocking 系（blocks/parent-child/conditional-blocks/waits-for）のみ。
- **並列 spawn（同一マシンで複数 worker が同時稼働）時は bd の write（`--claim` / `--notes` / `close` 等）を直列化**する（embeddeddolt は single-writer ＝同時 write は lost-update）。anchor リポに flock ラッパ（`scripts/bdw` 等）があればそれ経由で write する。逐次 1-worker は素の bd で可、read-only worker は `bd --readonly`。

## Essential Commands（要点。全コマンド・詳細は `bd --help` / `bd <cmd> --help`）
- 探す: `bd ready`（着手可能）/ `bd list [--status=open|in_progress]` / `bd show <id>` / `bd search <query>` / `bd blocked`
- 作る/更新: `bd create --title="..." --description="..." --type=task|bug|feature --priority=2` / `bd update <id> --claim`（in_progress 化）/ `bd update <id> --description/--notes/--title`（インライン更新）
- 完了/依存: `bd close <id> [--reason="..."]` / `bd dep add <issue> <depends-on>`（issue が depends-on に依存）
- 同期/健全: `bd dolt push` / `bd dolt pull`（refs/dolt/data 同期）/ `bd stats` / `bd doctor`

<!-- beads-init-template v:1 — このファイルは scribe:setup（旧 beads-init）skill 由来。skill はこの marker の `v:N` バージョン番号で「我々の版か」と「role 中立版か（N が現行 role 中立版の最小バージョン以上か）」を判定する（本文の自然言語フレーズには依存しない）。この行（特に `v:N`）を残せば手動編集しても上書きされない。役割を帯びた規約は scribe plugin の role 別 SessionStart 注入が SSOT（本 PRIME は role 中立）。 -->

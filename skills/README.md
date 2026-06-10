# scribe/skills

scribe plugin の skill 群を置くディレクトリ。

**v0(bd un-led)時点では placeholder**。skill の実体は後続 cell で追加される:

- administrator skill / consult 起動 skill 等の配置先（scribe-design.md §3「orchestration 層」）。
- skill は scripts 同梱のみ可。hooks/agents/MCP の同梱は plugin 専用（一次情報 verified・scribe-design.md §16 v0 チェックリスト）。よって scribe は plugin 形態を採る。

→ skill 設計の SSOT は `docs/protocol.md`（成文化された手動プロトコル）と `docs/role-context-spec.md`（role 別注入仕様）。

# scribe/scripts

scribe plugin の道具（手順をコード化する薄いヘルパー群）と hook script を置くディレクトリ。

**v0(bd un-led)時点では placeholder**。実装は後続 cell:

- `hooks/session-start-role-inject.sh` — role 判定 + role 別 SessionStart 文脈注入。**C2(bd un-ck2)が実装**。`hooks/hooks.json` の SessionStart wire は本 script を `[ -x ]` ガード付きで参照済み（未実装でも no-op）。仕様 = `docs/role-context-spec.md`。
- spawn ヘルパー（bd id → worktree + task prompt 生成 + cld-spawn + monitor 起動。window 参照は ID `@N` 捕捉）。**C3(bd un-4nm)が実装**。
- gate 起動ヘルパー（cell-quality WF 呼出）。**C3 が実装**。
- cleanup（worktree / branch / window 掃除）。**C3 が実装**。

→ 道具がコード化する手順の SSOT は `docs/protocol.md`。scribe-design.md §14 の「道具」3 本柱に対応。

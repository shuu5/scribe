# scribe/scripts

scribe plugin の道具（手順をコード化する薄いヘルパー群）と hook script を置くディレクトリ。
**道具は規約をコード化するだけ**で規約を変えない。コード化する手順の SSOT は `docs/protocol.md`。

## 道具（C3 = bd un-4nm・実装済み）

admin の手作業（protocol.md §1/§2/§5）を 1 コマンド化する 3 点。**全 script に `--dry-run`**（実行するはずのコマンド列を arg-echo・実 spawn はコスト大）。

- `scribe-spawn.sh [opts] <bd-id>` — spawn ヘルパー（worker モード）。`bd show` で実在を事前検証（**fail-loud**＝cld-spawn の不正 id silent fallback を上流で塞ぐ）→ `git worktree add`（`spawn/<id>-HHMMSS`）→ task prompt 生成（契約=bd description 参照・cell-quality WF 起動・bdw 規律・禁止事項）→ `cld-spawn --bd-id <id> --model opus` → monitor（window ID `@N` 参照＝dotted id の `-t` 衝突回避）。
  - `--consult` で **consult モード**に分岐（`docs/role-context-spec.md` §2.3 / scribe-design.md §14 の契約どおり）: consult は anchor 同居・read-only セッションなので **worktree も worker prompt も `--bd-id` も作らない**。anchor で `cld-spawn --model opus --env-file <SCRIBE_ROLE=consult> "<consult テンプレ>"`（設計議論/grill 専用・記憶系のみ write・サマリ保存義務）を出す。bd id は consult では任意の議題参照（read-only な実在検証のみ）。`SCRIBE_ROLE=consult` は C2 の role 判定が最優先で読む side。
    - **env-file は anchor working tree の外（`/tmp` 配下を `mktemp`）に作り spawn 後に `rm`** する＝anchor リポ（admin orchestrator の cwd）を汚さない。read-only 契約の起動器が自身は anchor に artifact を残さない自浄。万一の漏れに備え `.gitignore` にも `.scribe-consult.env` を登録（defense-in-depth）。
    - **モデル規約は worker と非対称**: worker は fable 厳禁（opus 必須・protocol.md §1）。consult は基本 opus・**ユーザー指定時のみ `--model fable` 可**（role-context-spec §2.3＝consult は admin と同じ main-loop 系統ゆえ fable 起動が許される唯一の例外。道具はこの規約を変えない）。
- `scribe-gate-args.sh [opts] --worktree <path> <bd-id>` — gate 支援。gate review 用 cell-quality args(JSON) を issue から合成し stdout へ。**`doPlan`/`doImplement`/`autoFix` は read-only 固定**（gate は一次監査・実装も autoFix もしない）。
- `scribe-cleanup.sh [opts] <bd-id>` — cleanup。merge 後の worktree remove / branch 安全削除 / window kill（`@N` 参照）/ `bd dolt push` リマインドのチェックリスト。**破壊操作は確認プロンプト付き**（`--yes` で一括承認）・**force 系（force 削除 / hard reset / tmux サーバ破壊）は使わない**。
- `lib/scribe-lib.sh` — 共有ヘルパー（bd id 正規化・実在検証・命名）。source 専用。

テスト: `tests/scribe-tools.bats`（dry-run arg-echo を assert・実 spawn しない。bd は `tests/fixtures/bd-stub.sh` でスタブ）。worker 自身の fail-closed self-test は `selftest-<id>.local.sh`（untracked）。

## hook script（C2 = bd un-ck2 領分・本 cell は触らない）

- `hooks/session-start-role-inject.sh` — role 判定 + role 別 SessionStart 文脈注入。**C2 が実装**。`hooks/hooks.json` の SessionStart wire は本 script を `[ -x ]` ガード付きで参照済み（未実装でも no-op）。仕様 = `docs/role-context-spec.md`。

→ scribe-design.md §14 の「道具」3 本柱に対応。

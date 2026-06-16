# scribe/scripts

scribe plugin の道具（手順をコード化する薄いヘルパー群）と hook script を置くディレクトリ。
**道具は規約をコード化するだけ**で規約を変えない。コード化する手順の SSOT は `docs/protocol.md`。

## 道具（C3 = bd un-4nm / un-3yc・実装済み）

admin / worker の手作業（protocol.md §1/§2/§5）を 1 コマンド化する道具群。**spawn/gate-args/selftest-args/cleanup には `--dry-run`**（実行するはずのコマンド列を arg-echo・実 spawn はコスト大）。

- `scribe-spawn.sh [opts] <bd-id>` — spawn ヘルパー（worker モード）。`bd show` で実在を事前検証（**fail-loud**＝cld-spawn の不正 id silent fallback を上流で塞ぐ）→ `git worktree add`（`spawn/<id>-HHMMSS`）→ task prompt 生成（契約=bd description 参照・cell-quality WF 起動・bdw 規律・禁止事項）→ `cld-spawn --bd-id <id> --model opus` → monitor（window ID `@N` 参照＝dotted id の `-t` 衝突回避）。
  - `--consult` で **consult モード**に分岐（`docs/role-context-spec.md` §2.3 / scribe-design.md §14 の契約どおり）: consult は anchor 同居・read-only セッションなので **worktree も worker prompt も `--bd-id` も作らない**。anchor で `cld-spawn --model opus --env-file <SCRIBE_ROLE=consult> "<consult テンプレ>"`（設計議論/grill 専用・記憶系のみ write・サマリ保存義務）を出す。bd id は consult では任意の議題参照（read-only な実在検証のみ）。`SCRIBE_ROLE=consult` は C2 の role 判定が最優先で読む side。
    - **env-file は anchor working tree の外（`/tmp` 配下を `mktemp`）に作り、`trap EXIT` + spawn 後 `rm` で必ず除去**する＝anchor リポ（admin orchestrator の cwd）には一切作らない。read-only 契約の起動器が自身は anchor に artifact を残さない自浄。ファイル名も実体は `/tmp/scribe-consult-XXXXXX.env`（mktemp）なので、`.gitignore` への登録は不要（リポに生成され得ない）。
    - **モデル規約は worker と非対称**: worker は fable 厳禁（opus 必須・protocol.md §1）。consult は基本 opus・**ユーザー指定時のみ `--model fable` 可**（role-context-spec §2.3＝consult は admin と同じ main-loop 系統ゆえ fable 起動が許される唯一の例外。道具はこの規約を変えない）。
- `scribe-gate-args.sh [opts] --worktree <path> <bd-id>` — gate 支援（admin・protocol.md §5）。gate review 用 cell-quality args(JSON) を issue から合成し stdout へ。**`doPlan`/`doImplement`/`autoFix` は read-only 固定**（gate は一次監査・実装も autoFix もしない）。
- `scribe-selftest-args.sh [opts] --worktree <path> --self-test <cmd> <bd-id>` — worker 自己点検 支援（worker・protocol.md §2）。自己点検用 cell-quality args(JSON) を issue から合成し stdout へ。**`doImplement`/`doPlan`=false・`autoFix`=true 固定 + `selfTestCmd` 必須**（worker は実装済み・confirmed のみ gated 修正・fail-closed ゲート）。gate-args と対称だが**責務だけ非対称**（gate=read-only / 自己点検=gated autoFix）。手作業で args を組まず道具を使うこと。
- `scribe-cleanup.sh [opts] <bd-id>` — cleanup。merge 後の worktree remove / branch 安全削除 / window kill（`@N` 参照）/ `bd dolt push` リマインドのチェックリスト。**破壊操作は確認プロンプト付き**（`--yes` で一括承認）・**force 系（force 削除 / hard reset / tmux サーバ破壊）は使わない**。
- `scribe-origin-guard.sh {capture,verify,restore} --worktree <path>` — origin 健全性ガード（bd un-1n1）。worktree は anchor と `.git/config`（remotes）を共有し、worker が origin を mutate すると anchor+全 worktree の origin が壊れる（un-v5x 実害）。`capture`（spawn 時・`scribe-spawn.sh` が `git worktree add` 直後に自動実行）で canonical origin URL を **per-worktree marker**（`.git/worktrees/<name>/scribe-origin.marker`＝共有 config と別物・working tree 外）へ捕捉し、`verify`（admin gate funnel §5・push 前）で現在 origin と照合（健全=exit 0 / 汚染=exit 非0・canonical URL を stdout）。`verify --restore` or `restore` で marker から復元。
- `lib/scribe-lib.sh` — 共有ヘルパー（bd id 正規化・実在検証・命名・origin 健全性 capture/verify/restore）。source 専用。

テスト: `tests/scribe-tools.bats`（dry-run arg-echo を assert・実 spawn しない。bd は `tests/fixtures/bd-stub.sh` でスタブ）。worker 自身の fail-closed self-test は `selftest-<id>.local.sh`（untracked）。

## hook script（C2 = bd un-ck2 領分・本 cell は触らない）

- `hooks/session-start-role-inject.sh` — role 判定 + role 別 SessionStart 文脈注入。**C2 が実装**。`hooks/hooks.json` の SessionStart wire は本 script を `[ -x ]` ガード付きで参照済み（未実装でも no-op）。仕様 = `docs/role-context-spec.md`。

→ scribe-design.md §14 の「道具」3 本柱（spawn / gate-args / cleanup）に対応。worker 自己点検の `scribe-selftest-args.sh` は un-3yc で追加した 4 点目（protocol.md §2 の自己点検 args を 1 コマンド化）。`scribe-origin-guard.sh` は un-1n1 で追加した 5 点目（protocol.md §1 spawn 捕捉 / §5 push 前 verify で共有 .git/config の origin 汚染を防ぐ）。

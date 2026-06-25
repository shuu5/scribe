# sandbox-spike (sc-1gu) — sandbox opt-in 本番ヘルパー + 実証 spike 記録

> ディレクトリ名は `sandbox-spike` のまま据え置く（sc-2m0 facet3・案C軽量）が、`gen-sandbox-settings.sh`
> は実証 spike を経て **本番反映済みの opt-in 本番ヘルパー**（下記「本番反映」節）。本ファイルは
> その本番ヘルパーの仕様 + 実証 spike（2026-06-18 検証済み）の記録を兼ねる。

scribe worker を **OS レベル sandbox**(Claude Code 組込み bubblewrap)で封じ込められるか、
かつ正当な cross-dir 作業(anchor の bd 台帳書込み)を壊さないかを、使い捨て worktree で実証する spike。

## 前提(ホスト)

CC 組込み sandbox は次の3つを要求する(spike で実測):

1. `bubblewrap`(`apt install bubblewrap`)
2. **`socat`**(`apt install socat`) — network proxy 用。**欠けると `failIfUnavailable` で CC が起動拒否**し
   コマンドが一切走らない(spike 初回はこれで全 assert が無効化された)。
3. `kernel.apparmor_restrict_unprivileged_userns=0`(Ubuntu 24.04)。`/etc/sysctl.d/` に置いて
   `sudo sysctl --system`。**ホスト全体の userns ハードニングを外す**ため、マルチユーザーホストでは
   security トレードオフを承知の上で。ロールバック = その conf を rm して再 `sysctl --system`。

## スクリプト

- `gen-sandbox-settings.sh <worktree>` — worker 用 `.claude/settings.local.json` を stdout 出力。
  worktree から anchor を逆算し、`sandbox.filesystem.allowWrite` に
  `<ANCHOR>/.beads`(台帳) と `$HOME/.cache/bdw-locks`(bdw flock 鍵の専用 lock dir・既定値は
  scribe 以外の bd writer と byte 一致する収束点・sc-xs2。parent を丸ごとでなく専用 dir のみ最小化) を絶対パスで入れる。
  cwd(worktree) と linked worktree の共有 `.git` は sandbox 既定で writable(列挙不要)。

> spike ハーネス `run-spike.sh` は spike 目的達成後 deadcode として削除した(commit 71bf862 で凍結・sc-18q)。
> 本番反映は下記「本番反映」節のとおり `gen-sandbox-settings.sh` の direct-gen が担う。

## 検証済み(2026-06-18)

spike ハーネス(commit 71bf862)で 5/5 PASS(全て ran=yes ＝ genuine):

| assert | 期待 | 結果 |
|---|---|---|
| a1 cwd 書込み | allow | PASS |
| a2 `<ANCHOR>/.beads` 書込み | allow | PASS(明示 allowWrite が効く) |
| a3 `$XDG_RUNTIME_DIR` 書込み | allow | PASS |
| b1 anchor 直下(worktree の親) | block | PASS(層2 外壁) |
| b2 `$HOME`(リポ外) | block | PASS(層2 外壁) |

⟹ CC sandbox は worktree-local `settings.local.json` の allowWrite 境界を OS レベルで強制する。
正当な cross-dir 書込み(cwd/.beads/専用 lock dir)は通り、外への書込みは封じる。

> **sc-da0 → sc-xs2（grant 最小化 + lock_dir 収束・上表 a3 の更新）**: spike 当時(2026-06-18)は
> `$XDG_RUNTIME_DIR` を丸ごと allowWrite に入れていたが、bdw が要るのは flock 鍵 1 ファイルのみ。
> sc-da0 で専用サブdir のみへ最小化し、**sc-xs2(2026-06-21)で lock_dir を `$HOME/.cache/bdw-locks`
> （scribe 以外の bd writer = orch/uns bdw と byte 一致）へ収束**させた（旧 `$XDG_RUNTIME_DIR/scribe-bdw`
> は base 違い + subdir 付与で構造分岐し lost-update を生んでいた）。grant は依然この専用 lock dir
> （bdw の `scribe_bdw_lock_dir()` と同式）のみで parent を丸ごと開けない。bwrap の bind-before-exist の
> ため `scribe-spawn.sh` が worker 起動前にこの dir を事前生成する。

## 本番反映(実装済み: direct-gen)

`SCRIBE_SANDBOX=1` opt-in 時、`scripts/scribe-spawn.sh` が `git worktree add` 後に
`gen-sandbox-settings.sh` で worktree の `.claude/settings.local.json` を**直接生成**する
(`CLD_PATH`/cld-spawn/launcher は触らない＝opt-in 未指定時は本番経路 byte 不変)。生成した
settings は worktree の git exclude(`info/exclude`)へ冪等追記して ephemeral に保つ
(worker の `git add -A` で巻き込まない・全マシン/全ユーザーで効かせる)。

> decision② の元案「CLD_PATH wrapper」は撤回: worker 経路は ENV_FILE を使わず tmux new-window が
> server 環境で走るため wrapper へ本物の cld パスを渡せず複雑化する。direct-gen の方が単純で
> ratified 本質(opt-in / byte 不変 / failIfUnavailable / D1 穴)を保つ。

検証: bats(SCRIBE_SANDBOX gating + spawn 行 full-line byte 同一)。

**旧「残」項目は完了済み（sc-jqd で source of record と突合）**:
- ✅ live opt-in の end-to-end spawn 実証(D7 c/d): `sc-1gu` で「live e2e で worker が sandboxed に boot」を実証済（commit 71bf862 / 4d16943 / 5bbd57a）。
- ✅ docs(protocol.md)へ socat 前提 + opt-in 反映済: `docs/protocol.md` の「sandbox opt-in」節が `bubblewrap`+`socat` 必須・apparmor userns 緩和のトレードオフを明記。

この spike-record に未完項目は残っていない（本番反映は上記「本番反映(実装済み: direct-gen)」節＝production・後続の最小化は sc-da0）。

## sandbox 内の実操作 e2e (sc-7n1)

spike の境界 assert(上表 a1/a2/b1/b2)は**生ファイル書込み**までだった。`verify-sandbox-e2e.sh` は
その先 — sandboxed worker の**実操作**が allowWrite 境界を通って*永続*するか — を埋める:

- **git commit → 共有 .git に永続**（linked worktree の `.git` は `$ANCHOR/.git`＝cwd の外だが、CC
  sandbox 既定で writable。allowWrite への列挙不要を**実証**＝gen-sandbox の前提が正しいことを裏取り）。
- **bd close → `<ANCHOR>/.beads` に永続**（明示 allowWrite + lock_dir grant が効く）。
- **block-side control → allowWrite 外（anchor 直下）への書込みが外壁に拒否される**（spike の b1 を 1 点継承）。
  これが無いと sandbox を無効化しても上 2 つは PASS し『境界を*通って*永続』を実証できない（boundary-vacuous）。
  3 つ揃って初めて「外壁が genuine に効いた状態で実操作が永続する」を意味する。

方式は spike 同様 **実 Claude Code(`claude -p`)を worktree で起動**し CC 自身の bwrap を適用させる
（自前 bwrap を組まない＝CC 実体との乖離なし）。完全 hermetic（`mktemp -d` の使い捨て temp anchor +
独立 bd 台帳。実 scribe の repo/.beads は触らない）。前提が欠ければ rc=77 で skip。

```
bash scripts/sandbox-spike/verify-sandbox-e2e.sh          # 単発（deps 要・PASS=4 FAIL=0 が green）
SCRIBE_SANDBOX_E2E=1 bats tests/scribe-tools.bats         # 回帰の opt-in lane で実走
```

既定の `bats tests/scribe-tools.bats` は CC を起動せずハーネスの契約のみ host 非依存に lock する。

### sandbox 下の stage は `scribe-add` で（sc-yqa・B 方式）

CC sandbox は worker cwd の既知 dotfile（`.bash_profile` `.bashrc` `.gitconfig` `.gitmodules` `.profile`
`.zprofile` `.zshrc` `.mcp.json` `.idea` `.vscode` `.ripgreprc`＝11）と `.claude/` 設定（`agents` `commands`
`hooks` `skills` `workflows` `routines` `launch.json` `scheduled_tasks.json` `settings.json`＝9）を
**`/dev/null` character device** として null-mount し無害化する（CC のセキュリティ機構・**設定で外せない**＝
verified・GH#17258/#17087）。git は device の add を拒否するため、素の `git add -A` / `git add .` は rc=128 で
失敗し空 commit を生む。

**対策（B）**: worker は `git add -A` でなく **`scripts/scribe-add`** で stage する。scribe-add は未追跡の
**通常ファイルと symlink** を型で選んで stage し（`[ -h ] || [ -f ]` で char/block device 等の非通常ファイルにだけ
`git add` をかけない。`[ -f ]` 単独だと dangling/→dir symlink を deref して黙って落とすため `[ -h ]` を OR する）、
追跡変更は `git add -u --ignore-errors` で拾う。型ベースゆえ **CC が null-mount リストを 20→N 個に増やしても
壊れない**（名前リストに結合しない）。共有 `info/exclude` を汚さないので **非 sandbox worktree への漏れもゼロ**
（論点3 を完全に解消）。worker prompt には SCRIBE_SANDBOX 時のみ scribe-add 規律を注入する。
（限界: 未追跡のネスト git repo は stage しない＝worker はネスト repo を作らない前提。）

本ハーネスは commit 経路に **scribe-add を実走**し、sandbox 下で device を弾いて commit が共有 .git に永続する
ことを実証する。加えて **negative control** として素の `git add -A` も 1 度走らせ、それが実 sandbox の char-device で
rc=128 失敗することを assert する（scribe-add の必要性＝退行は loud fail を counterfactual で実証・gate blocking#1）。
CC が null-mount を増やしても scribe-add は型ベースで壊れない（sc-yqa 4b の番人）。

> 旧 E 案（info/exclude に dotfile を列挙）は、CC が `.claude/*`（普通にコミットされる設定）も null-mount する
> ことが e2e で判明し、共有 exclude の漏れが広いうえ CC のリスト churn に脆く、真の per-worktree 化は共有
> `.git/config` mutate（un-1n1 違反）を要するため B 案へ切替えた（sc-yqa grill）。

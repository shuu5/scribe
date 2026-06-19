# sandbox-spike (sc-1gu)

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
  `<ANCHOR>/.beads`(台帳) と `$XDG_RUNTIME_DIR`(bdw flock 鍵) を絶対パスで入れる。
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
正当な cross-dir 書込み(cwd/.beads/runtime)は通り、外への書込みは封じる。

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
残: live opt-in の end-to-end spawn 実証(c/d) / docs(protocol.md 等)へ socat 前提 + opt-in を反映。

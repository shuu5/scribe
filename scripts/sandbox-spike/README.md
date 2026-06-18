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
- `run-spike.sh [--keep]` — D7 assert ハーネス。使い捨て worktree に settings を pre-place し、
  `claude -p` を sandbox 内で起動して allowWrite 境界を検証する。一次シグナルは実ファイル副作用。
  各コマンドに `; echo <token>` を付け「コマンドが実際に走ったか(ran)」を確認する(無いと block
  assert が vacuous PASS する — spike で露呈し修正)。

## 検証済み(2026-06-18)

`run-spike.sh` 5/5 PASS(全て ran=yes ＝ genuine):

| assert | 期待 | 結果 |
|---|---|---|
| a1 cwd 書込み | allow | PASS |
| a2 `<ANCHOR>/.beads` 書込み | allow | PASS(明示 allowWrite が効く) |
| a3 `$XDG_RUNTIME_DIR` 書込み | allow | PASS |
| b1 anchor 直下(worktree の親) | block | PASS(層2 外壁) |
| b2 `$HOME`(リポ外) | block | PASS(層2 外壁) |

⟹ CC sandbox は worktree-local `settings.local.json` の allowWrite 境界を OS レベルで強制する。
正当な cross-dir 書込み(cwd/.beads/runtime)は通り、外への書込みは封じる。

## 残(本番反映・別フェーズ)

spike は pre-place 方式。本番は `SCRIBE_SANDBOX=1` opt-in 時に `CLD_PATH` wrapper が
worktree の settings.local.json を自動生成する(seam = `scripts/scribe-spawn.sh` の `$CLD_SPAWN`
呼出し直前で `export CLD_PATH=<wrapper>`・cld-spawn は byte 不変)。
残 assert: (c)opt-in 未指定時 launcher byte 同一 /(d)bwrap・socat 不在で opt-in worker 起動失敗。

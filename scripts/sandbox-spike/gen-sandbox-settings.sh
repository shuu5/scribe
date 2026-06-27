#!/usr/bin/env bash
# gen-sandbox-settings.sh — sc-1gu sandbox の本番ヘルパー（既定 on・opt-out=SCRIBE_SANDBOX=0・sc-u53）: worker の .claude/settings.local.json
# (Claude Code 組込み bwrap sandbox 設定) を stdout へ出力する（scribe-spawn.sh が既定で生成・SCRIBE_SANDBOX=0 で opt-out）。
#
# scribe worker(cwd=worktree) の Bash subprocess を OS レベルで封じ、書込みを次へ限定する:
#   - cwd(worktree) + 配下           … sandbox 既定で writable(列挙不要)
#   - linked worktree の共有 .git     … sandbox 既定で writable(hooks/ と config は拒否のまま)
#   - <ANCHOR>/.beads                … 明示(bd/bdw の台帳書込み = B/hybrid。worktree subtree 外ゆえ絶対パス必須)
#   - bdw のロック dir(BDW_LOCK_DIR:-$HOME/.cache/bdw-locks) … 明示(bdw の flock 鍵 bd-write-<repo>.lock の置き場・bdw と同式・sc-xs2)
# 上記以外への書込みは sandbox 外壁(層2)が拒否する。
#
# キー名は CC 公式 docs で verified(code.claude.com/docs/en/sandboxing.md / settings.md):
#   sandbox.enabled(bool) / sandbox.failIfUnavailable(bool・bwrap 不在で起動失敗=D6 fail-loud)
#   sandbox.allowUnsandboxedCommands(bool・false=dangerouslyDisableSandbox を無効化する strict)
#   sandbox.filesystem.allowWrite(string[]・複数スコープで union merge)
# 注: permissions.additionalDirectories(built-in Read/Edit/Write 用の別レイヤ)は bwrap 外壁に
#     無関係ゆえ spike からは外す。production worker が built-in tool で .beads を触る場合のみ
#     追加を検討する(キー形状を要 verify)。
#
# usage: gen-sandbox-settings.sh <worktree-path>
#   <ANCHOR> は <worktree-path> から `git worktree list --porcelain` 1 行目で逆算する
#   (scribe-lib.sh:scribe_owning_repo と同等。GIT_DIR/GIT_WORK_TREE 継承は env -u で隔離)。
set -euo pipefail

# scribe-lib.sh を source するのは scribe_owning_repo(下の anchor 逆算)のためのみ(sc-vae cutover で
# lock_dir 共有目的の source は不要化。lock_dir の SSOT は canonical bdw＝下の `bdw lock-dir` 参照)。
_GEN_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../lib/scribe-lib.sh
source "$_GEN_DIR/../lib/scribe-lib.sh"

wt="${1:?usage: gen-sandbox-settings.sh <worktree-path>}"
[[ -d "$wt" ]] || { echo "gen-sandbox-settings: ディレクトリではありません: $wt" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "gen-sandbox-settings: jq が必要です" >&2; exit 2; }

# anchor(main worktree)を逆算。GIT_DIR/GIT_WORK_TREE の継承干渉を隔離(scribe-lib.sh 慣例)。
anchor="$(scribe_owning_repo "$wt")" \
  || { echo "gen-sandbox-settings: anchor 逆算に失敗(git worktree 外?): $wt" >&2; exit 3; }

uid="$(id -u)"
# bdw(scripts/bdw)が flock 鍵を置く dir を**そのまま** consume する(sc-vae cutover: lock_dir の SSOT は
# canonical bdw に一本化＝`bdw lock-dir` が解決済み dir を stdout に出す contract。旧 scribe-lib.sh の
# ローカル lock_dir 解決関数の手書き複製は drift 源ゆえ廃止し、bdw 自身に問い合わせて構造的に byte 一致させる)。
# `$_GEN_DIR/../bdw` = scripts/bdw shim→canonical へ exec。set -euo pipefail 下ゆえ失敗時は自動 fail-closed。
# grant は専用 lock dir(既定 $HOME/.cache/bdw-locks・sc-xs2 で orch/uns bdw と収束)のみ＝parent(`$HOME/.cache`
# 等)を丸ごと grant せず、sandboxed worker が触れる範囲を最小化する。bwrap が bind 前に path 存在を要求しうる
# ため、scribe-spawn.sh が worker 起動前にこの dir を mkdir する。
lock_dir="$("$_GEN_DIR/../bdw" lock-dir)"
beads_dir="$anchor/.beads"

jq -n \
  --arg beads "$beads_dir" \
  --arg lockdir "$lock_dir" \
  '{
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      filesystem: {
        allowWrite: [ $beads, $lockdir ]
      }
    }
  }'

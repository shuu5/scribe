#!/usr/bin/env bash
# gen-sandbox-settings.sh — sc-1gu sandbox opt-in の本番ヘルパー: worker の .claude/settings.local.json
# (Claude Code 組込み bwrap sandbox 設定) を stdout へ出力する（SCRIBE_SANDBOX=1 で scribe-spawn.sh が起動）。
#
# scribe worker(cwd=worktree) の Bash subprocess を OS レベルで封じ、書込みを次へ限定する:
#   - cwd(worktree) + 配下           … sandbox 既定で writable(列挙不要)
#   - linked worktree の共有 .git     … sandbox 既定で writable(hooks/ と config は拒否のまま)
#   - <ANCHOR>/.beads                … 明示(bd/bdw の台帳書込み = B/hybrid。worktree subtree 外ゆえ絶対パス必須)
#   - bdw のロック dir(BDW_LOCK_DIR:-XDG_RUNTIME_DIR:-/tmp) … 明示(bdw の flock 鍵 bd-write-<repo>.lock の置き場・bdw と同式)
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

wt="${1:?usage: gen-sandbox-settings.sh <worktree-path>}"
[[ -d "$wt" ]] || { echo "gen-sandbox-settings: ディレクトリではありません: $wt" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "gen-sandbox-settings: jq が必要です" >&2; exit 2; }

# anchor(main worktree)を逆算。GIT_DIR/GIT_WORK_TREE の継承干渉を隔離(scribe-lib.sh 慣例)。
anchor="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" worktree list --porcelain 2>/dev/null \
  | sed -n '1{s/^worktree //p;q;}')"
[[ -n "$anchor" ]] || { echo "gen-sandbox-settings: anchor 逆算に失敗(git worktree 外?): $wt" >&2; exit 3; }

uid="$(id -u)"
# bdw(scripts/bdw)が flock 鍵を置く dir と**同式**で導出する。bdw は
#   lock_dir="${BDW_LOCK_DIR:-${XDG_RUNTIME_DIR:-/tmp}}/scribe-bdw"
# なので、ここを XDG だけに依ると XDG 未設定の劣化環境で bdw=/tmp / sandbox=/run/user とズレ、
# sandbox 有効時だけ bdw の flock 作成がブロックされて bd write が壊れる(env 依存で気付きにくい)。
# sc-da0: runtime dir 丸ごと(/run/user/<uid>)でなく専用サブdir scribe-bdw のみを allowWrite に入れ、
# 他の runtime socket(dbus/wayland/agent)を sandboxed worker が clobber できる範囲を最小化する。
# bwrap が bind 前に path 存在を要求しうるため、scribe-spawn.sh が worker 起動前にこの subdir を mkdir する。
runtime_dir="${BDW_LOCK_DIR:-${XDG_RUNTIME_DIR:-/tmp}}/scribe-bdw"
beads_dir="$anchor/.beads"

jq -n \
  --arg beads "$beads_dir" \
  --arg runtime "$runtime_dir" \
  '{
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      filesystem: {
        allowWrite: [ $beads, $runtime ]
      }
    }
  }'

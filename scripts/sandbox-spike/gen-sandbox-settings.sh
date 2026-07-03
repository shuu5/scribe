#!/usr/bin/env bash
# gen-sandbox-settings.sh — sc-1gu sandbox の本番ヘルパー（既定 on・opt-out=SCRIBE_SANDBOX=0・sc-u53）: worker の .claude/settings.local.json
# (Claude Code 組込み bwrap sandbox 設定) を stdout へ出力する（scribe-spawn.sh が既定で生成・SCRIBE_SANDBOX=0 で opt-out）。
#
# scribe worker(cwd=worktree) の Bash subprocess を OS レベルで封じ、書込みを次へ限定する:
#   - cwd(worktree) + 配下           … sandbox 既定で writable(列挙不要)
#   - linked worktree の共有 .git     … sandbox 既定で writable(hooks/ と config は拒否のまま)
#   - <ANCHOR>/.beads                … 明示(bd/bdw の台帳書込み = B/hybrid。worktree subtree 外ゆえ絶対パス必須)
#   - bdw のロック dir(BDW_LOCK_DIR:-$HOME/.cache/bdw-locks) … 明示(bdw の flock 鍵 bd-write-<repo>.lock の置き場・bdw と同式・sc-xs2)
# 上記以外への **Bash subprocess の**書込みは sandbox 外壁(層2)が拒否する。ただし bwrap が封じるのは
# Bash 経路のみ＝built-in の Edit/Write/NotebookEdit は permission 層(bypassPermissions で素通し)で動き
# bwrap では縛れない。worker の Edit/Write は別レイヤの PreToolUse guard(scripts/hooks/edit-write-guard.py・
# sc-649)が worktree 境界へ縛る(security-audit SBX-ESC-1)。
#
# キー名は CC 公式 docs で verified(code.claude.com/docs/en/sandboxing.md / settings.md):
#   sandbox.enabled(bool) / sandbox.failIfUnavailable(bool・bwrap 不在で起動失敗=D6 fail-loud)
#   sandbox.allowUnsandboxedCommands(bool・false=dangerouslyDisableSandbox を無効化する strict)
#   sandbox.filesystem.allowWrite(string[]・複数スコープで union merge)
# 注: permissions.additionalDirectories(built-in Read/Edit/Write 用の別レイヤ)は bwrap 外壁に
#     無関係ゆえ spike からは外す。production worker が built-in tool で .beads を触る場合のみ
#     追加を検討する(キー形状を要 verify)。
#
# usage: gen-sandbox-settings.sh <worktree-path> [<anchor-path>]
#   <anchor-path> は bd graph の所在(= scribe-spawn の --anchor)。**明示渡しが正**(sc-lkg)。
#     省略時のみ <worktree-path> から `git worktree list --porcelain` 1 行目で逆算する
#     (scribe-lib.sh:scribe_owning_repo と同等。GIT_DIR/GIT_WORK_TREE 継承は env -u で隔離)。
#   cross-repo cell(scribe-spawn --repo X --anchor Y・X≠Y)では worktree は repo X 側に在り、
#     逆算 anchor=X になるが真の bd graph は Y ゆえ allowWrite が誤った .beads を grant する
#     (sc-lkg / doobidoo 4c24ac54)。呼出し元が真の anchor を知る場合は第2引数で明示すること。
set -euo pipefail

# scribe-lib.sh を source するのは scribe_owning_repo(anchor 未指定時の逆算)のためのみ(sc-vae cutover で
# lock_dir 共有目的の source は不要化。lock_dir の SSOT は canonical bdw＝下の `bdw lock-dir` 参照)。
_GEN_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=../lib/scribe-lib.sh
source "$_GEN_DIR/../lib/scribe-lib.sh"

wt="${1:?usage: gen-sandbox-settings.sh <worktree-path> [<anchor-path>]}"
[[ -d "$wt" ]] || { echo "gen-sandbox-settings: ディレクトリではありません: $wt" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "gen-sandbox-settings: jq が必要です" >&2; exit 2; }

anchor_arg="${2:-}"
if [[ -n "$anchor_arg" ]]; then
  # 明示 anchor(呼出し元が真の bd graph 所在を知る場合・cross-repo で正しい)。逆算に頼らず直接使う。
  [[ -d "$anchor_arg" ]] \
    || { echo "gen-sandbox-settings: --anchor のパスがディレクトリではありません: $anchor_arg" >&2; exit 2; }
  anchor="$(cd "$anchor_arg" && pwd)" \
    || { echo "gen-sandbox-settings: anchor パスの絶対解決に失敗: $anchor_arg" >&2; exit 2; }
else
  # 後方互換フォールバック(anchor 未指定): 逆算する。同一リポ(repo=anchor)なら結果は明示渡しと一致。
  # GIT_DIR/GIT_WORK_TREE の継承干渉を隔離(scribe-lib.sh 慣例)。
  anchor="$(scribe_owning_repo "$wt")" \
    || { echo "gen-sandbox-settings: anchor 逆算に失敗(git worktree 外?): $wt" >&2; exit 3; }
fi

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

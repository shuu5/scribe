#!/usr/bin/env bash
# scribe-lib.sh — scribe 道具の共有ヘルパー（source 専用・直接実行しない）。
#
# これらの道具がコード化する手順の SSOT は docs/protocol.md。
#   - 命名規約（wt-<id> / spawn/<id>-HHMMSS）= protocol.md §1
#   - tmux 参照は window ID @N（dotted bd id の -t 衝突回避）= protocol.md §1
#   - bd id 事前検証で cld-spawn の不正 id silent fallback を上流で塞ぐ = protocol.md §1（un-cbi 引き継ぎ）
#
# producer 側（実 spawn を行う cc-session 道具）は ~/.claude/plugins/session/scripts/session-name.sh。
# 本リポの道具は cc-session を **CLI 越し（cld-spawn）にだけ** 呼ぶ薄いラッパなので、命名は
# protocol.md §1 の契約を直接コード化する（cc-session 内部関数へは結合しない）。
#
# Note: set -e はここでは張らない（source 元のオプションに干渉しないため）。

# scribe_die <message...> — stderr へ出して非 0 終了（fail-loud）。
scribe_die() {
  printf 'scribe: error: %s\n' "$*" >&2
  exit 1
}

# scribe_normalize_bd_id <raw> — bd id を正規化・検証する（protocol.md §1 / session-name.sh producer 準拠）。
#   - 許容: 英数始まり + 英数 '.' '-'（dotted 階層 id un-3sh.3.5 を通す）。先頭 '#' は剥がす。
#   - 拒否: path traversal（'..' を含む・'/' を含む）= path/window 名へ埋め込むため構造的に防御。
# 正規化済み id を echo。不正なら空 + 非 0。
scribe_normalize_bd_id() {
  local raw="${1:-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"   # 先頭空白除去
  raw="${raw%"${raw##*[![:space:]]}"}"   # 末尾空白除去
  raw="${raw#\#}"                          # 先頭 '#' 剥がし
  [[ "$raw" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || return 1
  [[ "$raw" == *".."* ]] && return 1
  [[ "$raw" == *"/"* ]] && return 1
  printf '%s' "$raw"
}

# scribe_bd_id_exists <id> — bd issue の実在を事前検証（fail-loud gate・protocol.md §1）。
#   bd バイナリは $SCRIBE_BD（既定 bd）、graph 所在は $SCRIBE_ANCHOR（既定 cwd）。
#   `bd show <id>` の exit をそのまま返す（READ なので bdw を介さない＝protocol.md §3）。
scribe_bd_id_exists() {
  local id="$1"
  ( cd "${SCRIBE_ANCHOR:-.}" 2>/dev/null && "${SCRIBE_BD:-bd}" show "$id" >/dev/null 2>&1 )
}

# scribe_window_name <id> → wt-<id>（protocol.md §1 命名規約）。
scribe_window_name() { printf 'wt-%s' "$1"; }

# scribe_branch_name <id> [hhmmss] → spawn/<id>-HHMMSS（protocol.md §1）。
#   並列 spawn 衝突回避の -HHMMSS サフィックスは規約として維持する。
#   hhmmss はテスト決定論のため注入可（既定 date +%H%M%S）。
scribe_branch_name() {
  local id="$1" hhmmss="${2:-${SCRIBE_HHMMSS:-}}"
  [[ -z "$hhmmss" ]] && hhmmss=$(date +%H%M%S)
  printf 'spawn/%s-%s' "$id" "$hhmmss"
}

# scribe_owning_repo <worktree-path> → その worktree が属する main worktree（primary repo root）。
#   cross-repo cleanup の安全失敗（bd un-c4s）対策。cwd 文脈に依存せず worktree 自身に
#   「どのリポに属すか」を git へ問う。`git worktree list` の先頭行は常に main worktree であり、
#   linked worktree から問うても同じ main を返す（verified: git 2.43）。
#   worktree remove / branch -d は linked worktree 自身からは走らせられない（自分自身は消せない・
#   checked-out branch は -d 不可）ため、main worktree を操作の基点にするのが正しい。
#   継承 GIT_DIR/GIT_WORK_TREE から隔離する（session-start-role-inject.sh と同系の過剰解決防止）。
#   解決できた絶対パスを echo。worktree でない／git 不在なら空 + 非 0（呼び出し側が cwd 等へフォールバック）。
scribe_owning_repo() {
  local wt="${1:-}"
  [[ -n "$wt" ]] || return 1
  local main
  # porcelain の 1 行目は常に `worktree <main path>`。1 行目だけ前置詞を剥がして即 quit する
  # （`head` を挟まず pipefail+SIGPIPE の相互作用を避ける）。空白入りパスもそのまま通す。
  main="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$wt" worktree list --porcelain 2>/dev/null \
            | sed -n '1{s/^worktree //p;q;}')" || true
  [[ -n "$main" ]] || return 1
  printf '%s' "$main"
}

# scribe_linked_worktree_main <path> → <path> が linked（副）worktree のとき所属 main worktree の絶対パスを
#   echo + exit 0。main worktree 自身／非 worktree／git 不在なら空 + 非 0（呼び出し側はガード不発火）。
#   既定 anchor/repo が副 worktree のときの誤認（worktree ネスト・誤 base）を上流で塞ぐ判定（bd un-ag7）。
#   検出は **git plumbing のみ**（naming 規約 /.worktrees/ には依存しない）:
#     scribe_owning_repo（porcelain 先頭行 = main worktree）と `git rev-parse --show-toplevel`（当該 worktree
#     root）の差分。git はどちらも canonical 絶対パスを返すため、linked なら show-toplevel != main で判定できる。
#   継承 GIT_DIR/GIT_WORK_TREE から隔離する（scribe_owning_repo と同系の過剰解決防止）。
scribe_linked_worktree_main() {
  local path="${1:-}"
  [[ -n "$path" ]] || return 1
  local main top
  main="$(scribe_owning_repo "$path")" || return 1
  top="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$top" ]] || return 1
  [[ "$top" != "$main" ]] || return 1   # show-toplevel == main → main worktree 自身（linked ではない）
  printf '%s' "$main"
}

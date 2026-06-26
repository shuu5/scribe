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

# scribe_need_val <value> <flag-name> — 値必須オプションのガード（fail-loud・全道具の parse loop 共通）。
# 値が「非空 かつ 先頭が '-' でない」ことを要求する。非空チェックだけ([[ -n ]])だと、値を省いて
# 次フラグを書いた場合に次フラグを silent に消費する（例: `--worktree --base X` が worktree='--base'
# を載せて exit 0 で bogus 値のまま進む silent-misparse）。先頭 '-' を弾いて fail-loud にする。
# 消費し得る値（path/ref/branch/model/window/file）はいずれも '-' で始まらないため over-rejection は
# 実用上起きない。'-' 始まりの値が正当に必要化したら `--` セパレータで後付けする（escape hatch は無し）。
scribe_need_val() {
  [[ -n "${1:-}" && "$1" != -* ]] || scribe_die "$2 に値を指定してください（値の欠落・次フラグの誤消費を防止）"
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

# scribe_synthesize_issue_desc <id> <dry_run> <anchor> — gate-args / selftest-args 共通の
#   「issue から taskTitle / description を合成」する手順を 1 関数に集約する（DRY・sc-2m0 facet2）。
#   <dry_run>: 1=dry-run（bd show 省略・プレースホルダ＋title-suffix）/ それ以外=実 bd 参照。
#   実 bd 参照では scribe_bd_id_exists で実在を事前検証し、不在なら **関数内で fail-loud**
#     （scribe_die・早期失敗）。bd show 本文が空なら sentinel '(bd show 取得不可)' へ fallback する。
#   env seam（スタブ差し替え点）: bd バイナリ=$SCRIBE_BD（既定 bd）/ graph 所在=<anchor>
#     （scribe_bd_id_exists の SCRIBE_ANCHOR と bd show の cd 先の双方に効く）。
#   返却（D2）: TITLE と DESC を **NUL 区切りで stdout**（DESC を最後・末尾も NUL 終端）。DESC は
#     複数行ゆえ command substitution（NUL 不可・末尾改行 strip）では受けられないため NUL 区切りにする。
#   caller は 1 呼出で受ける（DESC が最後ゆえ末尾 NUL まで読めば 2 値が揃う）:
#     { IFS= read -r -d '' TITLE && IFS= read -r -d '' DESC; } < <(scribe_synthesize_issue_desc …) \
#       || scribe_die '…'
#   合成が die すると stdout が空になり最初の read が EOF→非0 → caller の `|| scribe_die` が
#   fail-loud に倒れる（process substitution の subshell 越しでも早期失敗が caller へ伝播する）。
scribe_synthesize_issue_desc() {
  local id="${1:?id required}" dry_run="${2:?dry_run flag required}" anchor="${3:?anchor required}"
  local title="$id" desc
  if [[ "$dry_run" -eq 1 ]]; then
    desc="(dry-run: bd show 省略)"
    title="$id (dry-run)"
  else
    SCRIBE_ANCHOR="$anchor" scribe_bd_id_exists "$id" \
      || scribe_die "bd issue が存在しません: '$id'"
    # bd show の本文（description）を合成材料に使う。取得不可（空）時はプレースホルダ sentinel。
    desc="$( ( cd "$anchor" 2>/dev/null && "${SCRIBE_BD:-bd}" show "$id" 2>/dev/null ) || true )"
    [[ -n "$desc" ]] || desc="(bd show 取得不可)"
  fi
  printf '%s\0%s\0' "$title" "$desc"
}

# scribe_window_name <id> → wt-<id>（protocol.md §1 命名規約）。
scribe_window_name() { printf 'wt-%s' "$1"; }

# scribe_bdw_lock_dir → bdw の flock 鍵を置く専用 dir（gen-sandbox の sandbox allowWrite と**同一**＝
# 全 bd writer + sandbox 外壁の D4 合意の SSOT・sc-imu で集約）。
#   既定 `$HOME/.cache/bdw-locks` は scribe **以外**の bd writer（orch/uns の scripts/bdw）と byte 完全一致
#   させる（sc-xs2: 旧 `${XDG_RUNTIME_DIR:-/tmp}/scribe-bdw` は base 違い＋`/scribe-bdw` subdir 付与で
#   構造分岐し、同一台帳へ同時 write する scribe worker と非 scribe writer が別 lock を掴んで flock 直列化が
#   黙って破れ lost-update する P1 を生んでいた。`BDW_LOCK_DIR` override も subdir を足さず直接使う＝
#   env で base を揃えれば確実に収束する）。`$HOME/.cache/bdw-locks` は専用の狭い lock dir ゆえ sandbox
#   allowWrite の最小化原則（旧 sc-da0：runtime dir 丸ごとを grant しない）は維持される。
# 呼び出し側は結果に対し必要なら mkdir/段階フォールバックを行う（runtime 挙動は呼び出し側の責務）。
scribe_bdw_lock_dir() { printf '%s' "${BDW_LOCK_DIR:-$HOME/.cache/bdw-locks}"; }

# scribe_git <git-args...> → GIT_DIR/GIT_WORK_TREE の継承干渉を隔離して git を呼ぶ（sc-e1w で集約。
# worker 等が GIT_DIR を export した環境でも -C 指定先のリポを正しく解く＝隔離の付け忘れを構造防止）。
scribe_git() { env -u GIT_DIR -u GIT_WORK_TREE git "$@"; }

# scribe_sandbox_write_exclude <worktree> → sandbox worker の settings.local.json を <worktree> の info/exclude へ
#   **冪等**追記する（sc-1gu・worker の stage に巻き込まない）。本番 scribe-spawn と test verify-sandbox-e2e が共有。
#   info/exclude は共有 common-dir（解決は scribe_git で GIT_DIR/GIT_WORK_TREE 継承隔離）。解決不能なら no-op(return 0)。
#   注（sc-yqa）: CC sandbox の null-mount dotfile/.claude 設定（char-device）への対処は **info/exclude でなく**
#     `scripts/scribe-add`（非通常ファイルを型で弾く stage ラッパ）が担う。E 案（info/exclude に dotfile を列挙）は
#     CC が `.claude/*`（普通にコミットされる設定）も null-mount すると e2e で判明し、共有 exclude の漏れが広く
#     CC のリスト churn に脆いため B 案（scribe-add）へ切替えた（sc-yqa grill）。本関数は settings.local.json のみ扱う。
scribe_sandbox_write_exclude() {
  local wt="${1:?worktree required}"
  local excl
  excl="$(scribe_git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$excl" ]] || return 0
  mkdir -p "$(dirname "$excl")" 2>/dev/null || true
  grep -qxF '**/.claude/settings.local.json' "$excl" 2>/dev/null \
    || printf '%s\n' '**/.claude/settings.local.json' >> "$excl"
}

# scribe_window_id <window-name> → tmux window 名から window_id(@N) を解決（無ければ空。dotted bd id の
# `-t` 区切り衝突を避けるため以後の tmux -t は @N で行う・protocol.md §1。sc-e1w で spawn/cleanup から集約）。
scribe_window_id() { tmux list-windows -F '#{window_id} #{window_name}' 2>/dev/null | awk -v n="$1" '$2==n{print $1; exit}' || true; }

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
  main="$(scribe_git -C "$wt" worktree list --porcelain 2>/dev/null \
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
  top="$(scribe_git -C "$path" rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -n "$top" ]] || return 1
  [[ "$top" != "$main" ]] || return 1   # show-toplevel == main → main worktree 自身（linked ではない）
  printf '%s' "$main"
}

# === origin 健全性ガード（bd un-1n1）=========================================
# worktree は `.git/config`（remotes）を anchor と **共有** する（git-common-dir 配下の単一 config）。
# worker が origin を mutate（push-gate 試験で実 push 回避用に dummy origin を設定 等）すると
# anchor+全 worktree の origin が壊れ、admin の push が破綻する（2026-06-16 un-v5x funnel 実害）。
# 対策: spawn 時に canonical origin を **per-worktree** marker へ捕捉し、admin が push 前（gate funnel §5）に
#   現在の origin と照合する。汚染（不一致）なら fail-loud し、marker から復元してから push する。
# marker は per-worktree の private git dir（`.git/worktrees/<name>/`）に置く＝(a)共有 config と別物ゆえ
#   worker の config 汚染を生き延び (b)worktree の working tree 外ゆえ worker の編集スコープ外・誤コミット不可。

# scribe_origin_marker_path <worktree> → marker ファイルの絶対パスを echo + exit 0。
#   per-worktree git dir（`rev-parse --absolute-git-dir`）配下に置く（共有でない・untracked・working tree 外）。
#   git worktree でない／git 不在なら空 + 非0。継承 GIT_DIR/GIT_WORK_TREE から隔離する（過剰解決防止）。
scribe_origin_marker_path() {
  local wt="${1:-}"
  [[ -n "$wt" ]] || return 1
  local gitdir
  gitdir="$(scribe_git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [[ -n "$gitdir" ]] || return 1
  printf '%s/scribe-origin.marker' "$gitdir"
}

# scribe_capture_origin <repo> <worktree> → <repo> の canonical origin URL を marker へ捕捉（spawn 時）。
#   origin remote が無ければ「保護対象なし」として no-op（exit 0・marker は作らない）。
#   marker パスが解決できない（非 worktree 等）なら非0。継承 GIT_DIR/GIT_WORK_TREE から隔離する。
scribe_capture_origin() {
  local repo="${1:-}" wt="${2:-}"
  local marker url
  marker="$(scribe_origin_marker_path "$wt")" || return 1
  url="$(scribe_git -C "$repo" remote get-url origin 2>/dev/null)" || url=""
  [[ -n "$url" ]] || return 0   # origin 無し → 捕捉対象なし（no-op）
  printf '%s\n' "$url" > "$marker" || return 1
}

# scribe_verify_origin <repo> <worktree> → spawn 時の marker と現在の origin URL を照合（gate 時・push 前）。
#   exit 0 = 健全（一致／marker 無し=照合不能ゆえ skip・stderr に warn）。
#   exit 非0 = **汚染**（不一致 or origin 消失）。canonical URL を stdout（復元用）・差分を stderr（fail-loud）へ。
#   照合は共有 config の origin を読む（worktree/repo どちらから読んでも同一・config 共有のため）。
scribe_verify_origin() {
  local repo="${1:-}" wt="${2:-}"
  local marker expected current
  marker="$(scribe_origin_marker_path "$wt")" || return 1
  if [[ ! -f "$marker" ]]; then
    printf 'scribe: warn: origin marker が無く照合できません（spawn 時の捕捉なし）: %s\n' "$wt" >&2
    return 0   # baseline 不在 → 照合不能（skip・但し warn を surface）
  fi
  expected="$(cat "$marker")"
  current="$(scribe_git -C "$repo" remote get-url origin 2>/dev/null)" || current=""
  if [[ "$current" != "$expected" ]]; then
    printf 'scribe: error: origin URL 汚染を検知（push 前に復元が必要）: 現在=%s 期待=%s\n' \
      "${current:-<none>}" "$expected" >&2
    printf '%s\n' "$expected"   # stdout = canonical URL（復元用に machine-readable で返す）
    return 1
  fi
  return 0
}

# scribe_restore_origin <repo> <worktree> → marker の canonical URL で <repo> の origin を復元（汚染検知後）。
#   marker が無い／空なら復元不可で fail-loud（非0）。共有 config を書く＝anchor+全 worktree に効く。
#   worker が URL を書換えた場合（origin 存在）は set-url、`git remote remove origin` で削除した場合は add
#   へ分岐する（set-url は存在しない remote を作れず「No such remote」で失敗するため・un-1n1 gate finding）。
scribe_restore_origin() {
  local repo="${1:-}" wt="${2:-}"
  local marker expected
  marker="$(scribe_origin_marker_path "$wt")" || return 1
  [[ -f "$marker" ]] || { printf 'scribe: error: origin marker が無く復元できません: %s\n' "$wt" >&2; return 1; }
  expected="$(cat "$marker")"
  [[ -n "$expected" ]] || { printf 'scribe: error: origin marker が空で復元できません: %s\n' "$marker" >&2; return 1; }
  # 先に git リポジトリか確認（sc-gfm: get-url の exit128=非git を exit2=remote 不在と混同し『削除ケース』へ
  # 誤分岐するのを防ぐ。非git は復元不能ゆえ fail-loud で根本原因を明示する）。
  scribe_git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 \
    || { printf 'scribe: error: origin 復元先が git リポジトリではありません: %s\n' "$repo" >&2; return 1; }
  if scribe_git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    scribe_git -C "$repo" remote set-url origin "$expected"   # 書換ケース
  else
    scribe_git -C "$repo" remote add origin "$expected"       # 削除ケース（再作成）
  fi
}

# scribe_sandbox_preflight → SCRIBE_SANDBOX worker の OS sandbox **機構** deps を検査（sc-u53・default-on の安全弁）。
#   揃えば exit 0（stdout 何も出さない）。欠ければ **最初の欠落理由を stdout に machine-readable で echo** して非0
#   （caller が fail-loud / fallback のメッセージに織り込めるように）。
#   検査対象は sandbox を成立させる前提のみ:
#     - bubblewrap（外壁本体）
#     - socat（CC sandbox の network proxy。欠けると failIfUnavailable で worker が一切起動しない＝sc-1gu 実測）
#     - jq（settings 生成器 gen-sandbox-settings.sh の **hard 依存**＝jq 不在で gen が exit 2。spawn で jq を無条件に
#       使うのは sandbox materialization 経路〔gen 呼出〕のみで非 sandbox 経路は jq を一切使わない＝jq は sandbox
#       機構固有の前提。これを preflight が見落とすと『bwrap/socat/userns は揃うが jq 不在』host で worktree add 後に
#       gen が落ち orphan worktree を残す＝preflight の orphan 防止不変条件を破る・sc-u53 round3 gate confirmed）
#     - userns を **実プローブ**で確認（`bwrap --ro-bind / / --unshare-user true`）。
#   userns は global sysctl（kernel.apparmor_restrict_unprivileged_userns）を **読まない**: host が
#   targeted apparmor profile 方式（sysctl=1 のまま bwrap だけ userns 許可）でも sysctl 緩和方式でも、
#   「実際に userns を作れるか」だけを見る＝両方式で信頼できる唯一の signal（sysctl 読みは profile 方式で
#   false-negative を出す）。verify-sandbox-e2e.sh の skip プローブと同じ判定式。
#   claude/bd 等の worker 一般 deps はここでは検査しない（sandbox の有無に依らず要る＝sandbox 可否の gate ではない。
#   jq は上記のとおり sandbox materialization 固有の hard 依存ゆえ検査対象に含める）。
scribe_sandbox_preflight() {
  local b
  for b in bwrap socat jq; do
    command -v "$b" >/dev/null 2>&1 || { printf '%s が不在' "$b"; return 1; }
  done
  # userns 実プローブ（apparmor profile / sysctl どちらの方式でも、通れば OK）。
  bwrap --ro-bind / / --unshare-user true 2>/dev/null \
    || { printf 'bwrap が userns を作れない（apparmor profile / sysctl 緩和が未反映）'; return 1; }
  return 0
}

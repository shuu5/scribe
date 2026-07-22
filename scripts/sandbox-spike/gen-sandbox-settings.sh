#!/usr/bin/env bash
# gen-sandbox-settings.sh — sc-1gu sandbox の本番ヘルパー（既定 on・opt-out=SCRIBE_SANDBOX=0・sc-u53）: worker の .claude/settings.local.json
# (Claude Code 組込み bwrap sandbox 設定) を stdout へ出力する（scribe-spawn.sh が既定で生成・SCRIBE_SANDBOX=0 で opt-out）。
#
# scribe worker(cwd=worktree) の Bash subprocess を OS レベルで封じ、書込みを次へ限定する:
#   - cwd(worktree) + 配下           … sandbox 既定で writable(列挙不要・CC 既定・sc-kxec D2)
#   - worker の git commit write-set … **明示 grant**（私有 gitdir + 共有 objects/refs/logs の 4 集合・sc-kxec）。
#       旧: 共有 .git は「CC 既定で writable(列挙不要)」に依存していたが、この既定は CC version で不安定に変わり
#       (2.1.217 下で git-dir 書込が非永続化＝worker commit が silent に失われた incident・sc-ghjc)。恒久 fix と
#       して commit write-set を明示 allowWrite 列挙し CC 挙動から決定論化する。**`.git` 直下・`.git/config`・
#       `.git/hooks` は列挙しない**＝denylist なしに un-1n1 fence(共有 config の remotes / hooks の mutate 禁止)を
#       構造保証する(allowlist 設計)。導出は rev-parse 動的導出＝下記本体参照。
#   - <ANCHOR>/.beads の runtime サブパスのみ … 明示(bd/bdw の台帳書込み = B/hybrid。worktree subtree 外ゆえ絶対パス
#       必須)。**丸ごとでなく** governance denylist(PRIME.md/metadata.json/config.yaml/README.md/.gitignore)を除いた
#       present 直下エントリ(embeddeddolt/ 等 dolt runtime)だけを grant し tracked 統治ファイルを read-only に守る(OG-1・sc-nd6。下記本体参照)
#   - bdw の flock 鍵 file(${lock_dir}/bd-write-<repo_id>.lock) … 明示(自リポ鍵 **file 単位**・OG-4/sc-mcx で lock dir 丸ごと grant から狭化＝同 dir 内の他リポ鍵に触れない)
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
# bdw(scripts/bdw)が flock 鍵を置く **file** を consume する(OG-4・sc-mcx: lock **dir** 丸ごとでなく自リポの
# flock 鍵 file 単位へ狭める＝sandboxed worker が同 dir 内の他リポ鍵に一切触れない)。lock_file の SSOT は
# canonical bdw に一本化＝`bdw lock-file` が `${lock_dir}/bd-write-${repo_id}.lock`(repo_id=git common-dir の
# sha256 先頭16)を stdout に出す contract(Leg-A・orch-7ti 着地済)。repo_id 導出を手書き複製すると drift(bdw が
# 導出を変えると worker の bd write が fail-closed で壊れる)ゆえ再実装せず bdw に問い合わせ構造的に byte 一致させる。
# `$_GEN_DIR/../bdw` = scripts/bdw shim→canonical へ exec。set -euo pipefail 下ゆえ失敗時は自動 fail-closed。
# repo_id は bdw が **プロセス cwd** の git common-dir(sha256 先頭16)から導く(canonical は BDW_REPO_DIR override を
# 持つが repo_id 解決には効かない＝cwd 依存・verified)。cross-repo cell(--repo X --anchor Y・X≠Y)では真の bd graph
# は anchor(Y)で worker も `cd Y && bdw` して書くため、gen 側も **anchor(Y)を cwd に** して repo_id を出す必要がある
# (gen の cwd は anchor と限らない)。よって subshell `(cd "$anchor" && bdw lock-file)` で worker の bd write と同一
# invocation にし、byte 一致の repo_id 鍵を grant する(worktree と anchor が common-dir 共有な同一リポ cell では
# どちらでも同値ゆえ安全側)。bwrap が bind 前に path 存在を要求しうるため、scribe-spawn.sh が worker 起動前にこの
# file を pre-create(touch)する(parent lock dir も mkdir・汎用 mkdir では file を dir 化するため専用 touch)。
lock_file="$(cd "$anchor" && "$_GEN_DIR/../bdw" lock-file)"
beads_dir="$anchor/.beads"

# --- OG-1(sc-nd6): .beads を丸ごとでなく runtime サブパスだけ grant（tracked 統治ファイルを read-only に守る）---
# 旧: allowWrite=[<anchor>/.beads, <lock_dir>] は .beads 直下の **tracked 統治ファイル**（PRIME.md=policy SSOT /
#   metadata.json=台帳 identity / config.yaml / README.md / .gitignore）まで worker の Bash に書込み可能にして
#   いた（B/hybrid 境界が OS 層で無強制・bd write に不要な規約まで改竄可能・security-audit OG-1 high）。
# 新: governance denylist を除いた .beads 直下エントリ（= dolt/bd の runtime データ）だけを grant する。統治
#   ファイルは read-only になり worker の Bash から改変も削除もできない（削除は親 dir write が要るが .beads dir
#   自体は grant しないため）。runtime write-set は実測で確定（mtime 差分・doobidoo）: bd create/close は
#   embeddeddolt/**（dolt DB）+ interactions.jsonl + last-touched（+ issues.jsonl / export-state.json）のみを
#   書き、governance には触れない（governance を a-w 化しても create/close は exit0=検証済）。dir（embeddeddolt/
#   backup/）は再帰 grant ゆえ dolt 内部のファイル増減に強い。present な直下のみ列挙＝全 grant は実在パス
#   （bwrap は bind 前に path 存在を要求しうるため bind-safe）。established anchor（spawn の常態）では runtime
#   エントリは既在。session 中の新規 top-level エントリ生成は稀で、起きれば fail-loud（worker が気付く）。
# 残存（OG-1 の到達限界）: embeddeddolt を dir grant する以上 worker は dolt DB を raw 書換でき、他 issue 改竄は
#   OS 層では防げない（tool 層の universal beads-bdw guard=PreToolUse + bdw-write-outside-sandbox 案が別レイヤ・
#   scribe bespoke の bd-write-guard は撤去され堀は beads-bdw plugin へ移管済＝un-2uap Leg-R-sc・脅威モデル
#   の正直な文書化は sc-451）。lock 鍵の **file 単位** grant（OG-4・sc-mcx）は下記 lock_file で実装済（lock dir
#   丸ごとを grant しないため同 dir 内の他リポ鍵 file には触れない＝残存 DoS を消す defense-in-depth）。
_beads_governance=( PRIME.md metadata.json config.yaml README.md .gitignore )
_beads_grants=()
shopt -s nullglob dotglob
for _e in "$beads_dir"/*; do
  _n="${_e##*/}"
  _skip=0
  for _g in "${_beads_governance[@]}"; do [[ "$_n" == "$_g" ]] && { _skip=1; break; }; done
  [[ "$_skip" -eq 0 ]] && _beads_grants+=( "$_e" )
done
shopt -u nullglob dotglob
# fail-closed: grant 可能な runtime エントリが皆無（.beads が空/不在/統治ファイルのみ）＝worker の bd write が
# 全滅する異常 anchor。黙って空 allowWrite を出さず止める（established anchor では必ず embeddeddolt 等が在る）。
if [[ "${#_beads_grants[@]}" -eq 0 ]]; then
  echo "gen-sandbox: .beads に grant 可能な runtime エントリがありません（anchor 異常? 空 .beads?）: $beads_dir" >&2
  exit 2
fi

# --- sc-kxec: worker の git commit write-set(.git 系)を明示 allowWrite する（CC 既定 auto-grant 依存を廃止） ---
# 従来 linked worktree の共有 .git への書込みは CC 組込み sandbox の「暗黙 default writable」に依存していた（旧
# ヘッダ前提）。この default は CC version で不安定に変わり（2.1.217 下で git-dir 書込が非永続化＝worker commit が
# silent に失われる incident・sc-ghjc: working-tree 書込は永続・git-dir 書込は非永続の非対称）。よって commit
# write-set を **明示 grant** して CC 挙動から決定論化する。grant は 4 集合のみ:
#   ① 私有 gitdir（per-worktree・index/HEAD/logs/ORIG_HEAD の所在＝commit の index/HEAD 更新先）
#   ② 共有 objects（loose/pack object の書込先） ③ 共有 refs（branch ref 前進の書込先） ④ 共有 logs（reflog）
# **`.git` 直下・`.git/config`・`.git/hooks` を grant する経路は作らない**＝denylist なしに un-1n1 fence（共有
# config の remotes / hooks を worker が mutate すると anchor+全 worktree の origin/hook が壊れる・un-v5x 実害）を
# **構造保証** する（objects/refs/logs と私有 gitdir だけを allowlist・config/hooks はそもそも列挙しないので到達不能）。
# ★fence の唯一の穴＝primary(非linked) worktree: そこでは `--absolute-git-dir` が共有 `.git` を**丸ごと**返す
#   （私有 gitdir==共有 common-dir）ため、私有 gitdir grant が `.git` 直下（config/hooks 含む）を writable にして
#   fence を破る。よって下記本体で primary worktree を検出したら fail-loud で弾く（`.git` 丸ごとを絶対 emit しない）。
# 導出は rev-parse 動的導出（D1a）: `$anchor` 由来の `.git/worktrees/<name>` 文字列組立は cross-repo cell
#   （worktree=repo X・anchor=Y・X≠Y）で誤 path を指すため禁止。worker は worktree の実 repo（X）の .git に commit
#   するゆえ .git grant は **$wt から** 導出する（.beads grant は anchor=Y 由来だが .git grant は wt=X 由来＝分離が正）。
# refs/logs は dir 丸ごと grant（per-branch 狭化しない・D1b）。残存 blast radius（worker が他 branch の loose ref/
#   reflog も書ける）は脅威モデル A（うっかり前提）で許容する（worker は既に objects を書けるため ref 単独狭化の
#   実利は限定的）。present-only emission（実在サブパスのみ・D1c）＝bwrap の bind-before-exist / failIfUnavailable=
#   true と整合（不在 path で worker 起動不能を防ぐ・.beads の present-only glob と同契約）。scribe-spawn.sh の FO-2
#   attestation は本 grant（私有 gitdir + 共有 objects/refs）の存在を launch 前に fail-loud 検査する（**同一 rev-parse
#   導出** で byte 一致・欠落なら die＝gen drift/stub の backstop。両者は同じ導出で書かれているので改変時は平仄を保つ）。
_git_grants=()
# ★物理正規化（cd && pwd -P）を私有 gitdir/共有 common-dir の**両方**に適用する（sc-kxec finding#1）: 旧実装は
#   _priv_gitdir=`--absolute-git-dir`（symlink 解決）と _common_dir=`--git-common-dir` の logical `pwd` 絶対化
#   （symlink 保持）が非対称で、symlink 経路の primary worktree（例 /link → /repo）を渡すと `--absolute-git-dir`=
#   `/repo/.git`・絶対化 common=`/link/.git` と食い違い、下の primary 検出 `==` が FALSE になって primary を検出できず
#   共有 `.git` 丸ごと（config/hooks 含む）を私有 gitdir として emit＝un-1n1 fence が破れた（FO-2 も同じ非対称で
#   backstop にならず）。両者を **同一の物理正規化** に通し `==` 比較・allowWrite emit・FO-2 index 照合を like-for-like
#   の物理パスで行う（`--absolute-git-dir` の symlink 解決が git version 依存で揺れても物理化で吸収）。scribe-spawn.sh
#   の _fo2_gd/_fo2_common も同一正規化を共有し byte 一致を保つ（両者は必ず平仄を保つこと）。
# 私有 gitdir（git が canonical 絶対で返す）。継承 GIT_DIR/GIT_WORK_TREE は scribe_git（env -u）で隔離する。
_priv_gitdir="$(scribe_git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null || true)"
if [[ -n "$_priv_gitdir" ]]; then
  _priv_gitdir="$(cd "$_priv_gitdir" 2>/dev/null && pwd -P)" || _priv_gitdir=""
fi
# 共有 common-dir。`--git-common-dir` は cwd 相対で返りうる（main worktree で `.git`）ため $wt 起点で絶対化しつつ
# 物理正規化する（絶対 path でも symlink component を含みうる＝例 /link/.git ゆえ cd → pwd -P で一律に物理化する。
# FO-2 attestation と同一導出＝byte 一致の前提）。
_common_dir="$(scribe_git -C "$wt" rev-parse --git-common-dir 2>/dev/null || true)"
if [[ -n "$_common_dir" ]]; then
  _common_dir="$(cd "$wt" 2>/dev/null && cd "$_common_dir" 2>/dev/null && pwd -P)" || _common_dir=""
fi
# un-1n1 fence の構造保証: primary(非linked) worktree 入力を fail-loud で弾く（**私有 gitdir grant の追加より前**）。
# primary worktree / repo root では `--absolute-git-dir` が共有 `.git` を**丸ごと**返す（私有 gitdir==共有 common-dir・
# 実測 verified）。それを allowWrite に足すと `.git` 直下（config/hooks/info 等すべて）が writable になり un-1n1 fence
# （共有 config の remotes / hooks を worker が mutate すると anchor+全 worktree の origin/hook が壊れる・un-v5x 実害）が
# 破れる。しかも primary では index/HEAD が `.git` 直下に在るため、`.git` 丸ごとを grant せずに commit を通す術が無い＝
# fence を保ったまま安全に sandbox する解が存在しない。scribe worker は常に linked worktree で走る契約ゆえ primary 入力は
# 契約違反。ここで検出して停止する（`.git` 丸ごとを構造的に絶対 emit しない＝fence の唯一の穴を塞ぐ）。
if [[ -n "$_priv_gitdir" && -n "$_common_dir" && "$_priv_gitdir" == "$_common_dir" ]]; then
  echo "gen-sandbox: worktree が primary(非linked)です（私有 gitdir == 共有 .git）。.git 丸ごと grant は un-1n1 fence を破るため拒否します。scribe worker は linked worktree でのみ走ります: $wt" >&2
  exit 2
fi
# present-only emission（実在サブパスのみ・D1c）＝bwrap の bind-before-exist / failIfUnavailable=true と整合。
[[ -n "$_priv_gitdir" && -e "$_priv_gitdir" ]] && _git_grants+=( "$_priv_gitdir" )
if [[ -n "$_common_dir" ]]; then
  for _sub in objects refs logs; do
    [[ -e "$_common_dir/$_sub" ]] && _git_grants+=( "$_common_dir/$_sub" )
  done
fi

# allowWrite = [<.beads runtime サブパス...>, <lock_file>, <.git commit write-set...>]。--args で positional
# 配列化（空白/メタ文字パス安全・verified）。空配列 `"${_git_grants[@]}"` は set -u 下でも安全（bash の空配列展開）。
jq -n --args '{
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false,
      filesystem: {
        allowWrite: $ARGS.positional
      }
    }
  }' "${_beads_grants[@]}" "$lock_file" "${_git_grants[@]}"

#!/usr/bin/env bash
# verify-sandbox-e2e.sh — sc-7n1: SCRIBE_SANDBOX worker が sandbox 内で実際に
#   `git commit`(共有 .git へ)と `bd close`(.beads dolt へ)を end-to-end で永続できるかを、
#   完全 hermetic に実証する true-e2e ハーネス。
#
# 位置づけ: sc-1gu spike(run-spike.sh・削除済 commit 71bf862)は生ファイル書込みの *境界*
#   (a1 cwd allow / a2 <ANCHOR>/.beads allow / b1,b2 外壁 block)までを assert した。
#   本ハーネスはその先 — sandboxed worker の **実操作**(git commit / bd close)が allowWrite
#   境界(cwd+配下 / linked worktree の共有 .git / <ANCHOR>/.beads / lock_dir)を通って
#   *永続*するか — を埋める(sc-7n1)。README「未 assert」項の解消。
#
# 方式(spike 踏襲): 自前で bwrap を組まず、**実 Claude Code(`claude -p`)を worktree で起動**し
#   CC 自身の bwrap sandbox を適用させる(= CC 実体との乖離が無い真の e2e)。一次シグナル =
#   実副作用(commit が共有 .git に出来たか / issue が closed か)。CC stdout の token は二次
#   シグナル(コマンドが実際に走ったかの vacuous-PASS guard。spike 初回はこれが無く起動失敗が
#   block assert を偽 PASS させた)。
#
# 完全 hermetic(blast radius ゼロ): すべて mktemp -d 配下の **使い捨て temp anchor repo +
#   独立 bd 台帳**で行う。実 scribe の repo / .beads 台帳は一切 mutate しない。gen-sandbox-
#   settings.sh が temp worktree から temp anchor を逆算するので allowWrite は temp anchor の
#   .beads を指す。共有する実資源は $HOME/.cache/bdw-locks(bdw flock 鍵・無害)のみ。
#
# 前提(sc-1gu): bubblewrap + socat + kernel.apparmor_restrict_unprivileged_userns 緩和
#   (multi-user host は host 全体 sysctl=0 でなく bwrap 標的 apparmor profile 方式)。いずれか
#   欠ければ rc=77(skip 規約)で抜ける — 本回帰を host 非依存に保つ(deps が在る host でのみ実走)。
#
# cleanup 注意(load-bearing): temp scaffold は git repo + .beads/.dolt を含むため、`rm -rf` を
#   **Claude Code の Bash tool で直叩きすると** 破壊的削除を block する PreToolUse[Bash] hook が止める
#   — リポ同梱の rm-destructive-guard(git repo を含む tree の削除)/ git-destructive-guard に加え、
#   環境によっては user-global(~/.claude)の beads-destructive-guard(.beads/.dolt の削除)も発火しうる。
#   本ハーネスは cleanup を自分の subprocess 内で行うので、いずれの hook の走査対象外(hook は親 Bash
#   tool のコマンド文字列だけを見る)。`bash verify-sandbox-e2e.sh` として起動する限り cleanup は通る
#   (bats からの起動も同様 — bats 行に rm/.beads トークンが無い)。
#
# usage: verify-sandbox-e2e.sh [--keep]
#   --keep: 失敗解析用に temp scaffold を残す(掃除されない)
# exit: 0=PASS / 1=FAIL / 77=SKIP(前提未満) / 2=setup エラー
set -uo pipefail

KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

# env -u で GIT_DIR/GIT_WORK_TREE 継承を隔離(scribe-lib.sh 慣例)。worker 役の git は production と
# 同じく plain git だが、ハーネス側(anchor 構築・assert)は継承干渉を避けるため隔離 git を使う。
gitc() { env -u GIT_DIR -u GIT_WORK_TREE git "$@"; }

HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
GEN="$HERE/gen-sandbox-settings.sh"
SADD="$HERE/../scribe-add"   # sc-yqa B: sandbox 下の git add -A 代替(型で device を弾く stage ラッパ)。worker が実走する。
# shellcheck source=../lib/scribe-lib.sh
source "$HERE/../lib/scribe-lib.sh"

# --- 前提チェック(欠けたら skip=77。本回帰を deps 非依存に保つ) ---
skip() { echo "SKIP(sc-7n1 前提未満): $1" >&2; exit 77; }
command -v claude >/dev/null 2>&1 || skip "claude CLI 不在"
command -v bwrap  >/dev/null 2>&1 || skip "bubblewrap 不在(apt install bubblewrap)"
command -v socat  >/dev/null 2>&1 || skip "socat 不在(CC sandbox の network proxy に必須)"
command -v bd     >/dev/null 2>&1 || skip "bd 不在"
command -v jq     >/dev/null 2>&1 || skip "jq 不在"
# userns が実際に使えるか(apparmor profile / sysctl のどちらの方式でも、これが通れば OK)。
bwrap --ro-bind / / --unshare-user true 2>/dev/null || skip "bwrap が userns を作れない(apparmor profile / sysctl 緩和 未反映)"

# --- 使い捨て temp scaffold(完全 hermetic) ---
TMP="$(mktemp -d)"
ANCHOR="$TMP/anchor"
WT="$ANCHOR/.worktrees/e2e"
cleanup() {
  if [[ "$KEEP" -eq 1 ]]; then
    echo "[keep] temp scaffold を残します: $TMP" >&2
  else
    # subprocess 内なので rm/git/beads destructive-guard の走査対象外(上のヘッダ参照)。git repo + .beads/.dolt を含む。
    rm -rf "$TMP" 2>/dev/null || true
  fi
}
trap cleanup EXIT

die() { echo "setup エラー: $1" >&2; exit 2; }

echo "=== sc-7n1 sandbox e2e: git commit + bd close 永続 assert ==="
echo "temp anchor = $ANCHOR"
echo "worktree    = $WT"

# 1) temp anchor git repo + 独立 bd 台帳 + throwaway issue
gitc init -q "$ANCHOR" || die "git init 失敗"
gitc -C "$ANCHOR" config user.email e2e@scribe.test
gitc -C "$ANCHOR" config user.name  scribe-e2e
gitc -C "$ANCHOR" commit -q --allow-empty -m "init" || die "初期 commit 失敗"
( cd "$ANCHOR" && bd init --skip-agents --skip-hooks >/dev/null 2>&1 ) || die "bd init 失敗"
ISSUE="$( cd "$ANCHOR" && bd create --title "sandbox e2e throwaway" --type task -p 4 2>/dev/null \
          | sed -n 's/.*Created issue: \([^ ]*\).*/\1/p' )"
[[ -n "$ISSUE" ]] || die "throwaway issue の作成/ID 捕捉に失敗"
echo "throwaway issue = $ISSUE"

# 2) linked worktree + sandbox settings.local.json(gen が temp anchor の .beads を grant)
gitc -C "$ANCHOR" worktree add -q "$WT" -b e2e-branch >/dev/null 2>&1 || die "worktree add 失敗"
mkdir -p "$WT/.claude"
"$GEN" "$WT" > "$WT/.claude/settings.local.json" || die "settings 生成失敗"
# settings.local.json を info/exclude へ除外する(sc-1gu・本番 scribe-spawn と同じ)。CC null-mount device の件は
# 下の WORKER_CMD が scribe-add(型で弾く stage ラッパ・sc-yqa B)を実走して扱う＝それが効くこと、かつ CC が
# null-mount を増やしても scribe-add は型ベースゆえ壊れないことを実 sandbox で実証する(sc-yqa 4b の robust 版)。
scribe_sandbox_write_exclude "$WT"
# bwrap の bind-before-exist 対策: grant 済 lock dir を worker 起動前に実在させる(本番 scribe-spawn と同じ)。
mkdir -p "$(scribe_bdw_lock_dir)" 2>/dev/null || true
echo "--- settings.local.json ---"; cat "$WT/.claude/settings.local.json"

# 3) sandboxed worker(実 CC)に 1 コマンドを走らせる。allow-side(git commit/bd close)と block-side
#    (allowWrite 外への書込みが拒否される)を1度に実行する。各操作の実行証跡を token で可視化する(vacuous-PASS
#    guard)。block-side control が無いと sandbox を無効化しても allow-side は同一に PASS し『境界を *通って* 永続』を
#    実証できない(boundary-vacuous)。spike の b1/b2 外壁 block を 1 点継承する。
TOK_GIT="SC7N1_GIT_RAN"
TOK_BD="SC7N1_BD_RAN"
COMMIT_MSG="sc7n1-e2e-commit-$$"
# worker は **scribe-add**(sc-yqa B・非通常ファイルを型で弾く stage ラッパ)を使う。素の `git add -A` は CC の
# null-mount char-device(.bashrc / .claude/agents 等)で rc=128 死する。scribe-add は device に `git add` を一切
# かけず(型で除外)marker だけ stage→commit が共有 .git に永続する。CC が null-mount を増やしても型ベースゆえ壊れない(4b robust)。
# negative control(gate blocking#1): scribe-add の前に **素の git add -A** を 1 度走らせ rc を NEGCTL に記録する。
# これで『scribe-add が必須(git add -A は実 sandbox の char-device で rc=128 死)』と『退行=loud fail(検出網が捕捉)』を
# counterfactual で実証する。git reset で index を戻してから scribe-add(positive)へ進むので positive path は汚さない。
MARKER="sc7n1-e2e-marker.txt"
# block-side control: cwd($WT)の外かつ allowWrite([<anchor>/.beads, lock_dir])外の anchor 直下。
# sandbox 外壁が効いていれば書込みは拒否され OUTSIDE は出来ない(spike の b1=anchor-root と同型)。$TMP 配下ゆえ無害。
OUTSIDE="$ANCHOR/sc7n1-OUTSIDE-marker.txt"
# block-side の positive 信号は **stdout token でなく実ファイル(INBOUND)** にする(allow-side の commit/close と同型の
# real artifact backstop)。理由: block-side の一次シグナル「OUTSIDE 不在」は『genuine 拒否』と『未実行』で同一ゆえ
# execution 証跡が要る。だが stdout token は WORKER_CMD が prompt へ焼かれる以上 CC の command-echo で literal が紛れ、
# genuine 拒否なのに WROTE 相当が立つ false-FAIL を生む(gate round3)。INBOUND は cwd 内(sandbox writable)の実ファイルで
# worker が書込み成否を自己判定して 'blocked'/'wrote' を残す。narration は stdout を汚すだけでファイルは作らないので
# false-FAIL が消え、判定は「INBOUND==blocked かつ OUTSIDE 不在」の連言=分岐順非依存になる。
INBOUND="$WT/sc7n1-blockresult.txt"
NEGCTL="$WT/sc-yqa-negctl-rc.txt"   # negative control: 素の git add -A の rc を worker が書く(sc-yqa gate blocking#1)
# printf は外壁で *失敗* するのが期待値ゆえ `&&` で繋がず `;` で必ず自己判定へ進む(失敗を AND ゲートすると INBOUND が
# 永久に書かれず 全 PASS が達成不能)。worker が OUTSIDE 実在を自己判定し INBOUND に blocked/wrote を書く。
WORKER_CMD="cd '$WT' && printf 'e2e\n' > '$MARKER'; git add -A >/dev/null 2>&1; printf '%s' \$? > '$NEGCTL'; git reset -q >/dev/null 2>&1; '$SADD' && git commit -q -m '$COMMIT_MSG' && echo $TOK_GIT; bd close '$ISSUE' >/dev/null 2>&1 && echo $TOK_BD; printf x > '$OUTSIDE' 2>/dev/null; [ -e '$OUTSIDE' ] && printf wrote > '$INBOUND' || printf blocked > '$INBOUND'"

before="$(gitc -C "$WT" rev-parse HEAD)"
echo "--- 実 CC を sandbox で起動(git commit + bd close + 外壁 block control)---"
CC_OUT="$( cd "$WT" && claude -p --permission-mode bypassPermissions \
  "あなたはテストハーネス。次の bash コマンドを Bash ツールで 1 回だけ厳密に実行し、stdout/stderr をそのまま報告せよ。説明や追加コマンドは不要。コマンド: $WORKER_CMD" \
  2>&1 )" || true

# 4) assert(一次=実副作用 / 二次=token)。bd show はフレーク回避のため 1 度だけ捕捉して判定。
after="$(gitc -C "$WT" rev-parse HEAD)"
git_ran=no;  grep -q "$TOK_GIT" <<<"$CC_OUT" && git_ran=yes
bd_ran=no;   grep -q "$TOK_BD"  <<<"$CC_OUT" && bd_ran=yes
commit_msg="$(gitc -C "$WT" log -1 --format=%s 2>/dev/null || true)"
issue_state="$( cd "$ANCHOR" && bd show "$ISSUE" 2>/dev/null || true )"
# block-side の execution 証跡 = worker が cwd 内 INBOUND に残した実ファイル(narration では作られない)。
block_result="$(cat "$INBOUND" 2>/dev/null || true)"
# negative control の実行証跡 = worker が NEGCTL に書いた 素の git add -A の rc(空=未実行)。
negctl_rc="$(cat "$NEGCTL" 2>/dev/null || true)"

pass=0; fail=0; verdict() { [[ "$1" == PASS ]] && pass=$((pass+1)) || fail=$((fail+1)); printf '  [%s] %s\n' "$1" "$2"; }

echo "--- asserts ---"
# git commit: token が出て(=実行)・HEAD が前進し・新 HEAD のメッセージが一致 → 共有 .git に永続。
if [[ "$git_ran" != yes ]]; then
  verdict FAIL "git commit: CC が走った証跡(token)なし — sandbox boot 失敗の疑い(vacuous-PASS 防止)"
elif [[ "$before" != "$after" && "$commit_msg" == "$COMMIT_MSG" ]]; then
  verdict PASS "git commit: 共有 .git に永続($before -> $after / msg='$commit_msg')"
else
  verdict FAIL "git commit: 反映されず(before=$before after=$after msg='$commit_msg')"
fi
# bd close: token が出て・anchor 側 bd show が CLOSED → .beads dolt に永続。
if [[ "$bd_ran" != yes ]]; then
  verdict FAIL "bd close: CC が走った証跡(token)なし(vacuous-PASS 防止)"
elif grep -qi 'closed' <<<"$issue_state"; then
  verdict PASS "bd close: anchor .beads に永続($ISSUE = CLOSED)"
else
  verdict FAIL "bd close: closed 化が永続せず(state: $(grep -iE 'open|closed' <<<"$issue_state" | head -1))"
fi
# block-side control: PASS は『worker が INBOUND に blocked を残した(=実行され書込みが拒否された)』かつ『外側から見ても
# OUTSIDE 不在』の **連言**のみ(分岐順非依存・narration 耐性)。それ以外は FAIL: INBOUND==wrote か OUTSIDE 実在=外壁未強制、
# INBOUND 空=未実行(vacuous 閉塞)。この PASS が成って初めて上 2 つの allow-side PASS が『境界を *通って* 永続』を意味する。
if [[ "$block_result" == blocked && ! -e "$OUTSIDE" ]]; then
  verdict PASS "block-side control: allowWrite 外への書込みを外壁が拒否=sandbox genuine($OUTSIDE 不在・worker 自己判定 blocked)"
elif [[ "$block_result" == wrote || -e "$OUTSIDE" ]]; then
  verdict FAIL "block-side control: allowWrite 外へ書けた=sandbox 外壁が効いていない(boundary 未強制・allow-side PASS は無意味)"
else
  verdict FAIL "block-side control: 実行証跡(INBOUND)なし=未実行の疑い(vacuous-PASS 防止・block_result='$block_result')"
fi

# negative control(sc-yqa gate blocking#1): 素の git add -A が同一 sandbox の null-mount char-device で *失敗* する
# ことを実走で示す。これが無いと『scribe-add が効いた』と『git add -A でも通った』を区別できず B の必要性が
# 未実証(boundary-vacuous)。rc!=0=失敗=退行は loud(0-commit 検出網が捕捉)/ rc==0=git add -A でも通る(B 不要の懸念)。
if [[ -n "$negctl_rc" && "$negctl_rc" != 0 ]]; then
  verdict PASS "negative control: 素の git add -A は null-mount char-device で rc=$negctl_rc 失敗(=scribe-add 必須・退行は loud fail→0-commit 検出網)"
elif [[ "$negctl_rc" == 0 ]]; then
  verdict FAIL "negative control: 素の git add -A が rc=0 で通った=B の必要性が未実証(boundary-vacuous)"
else
  verdict FAIL "negative control: rc 記録なし=未実行の疑い(vacuous-PASS 防止)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "--- 診断: CC 出力(sandbox 内の実行ログ) ---"
  printf '%s\n' "$CC_OUT" | sed 's/^/  | /'
  echo "  (flags: git_ran=$git_ran bd_ran=$bd_ran block_result='$block_result' negctl_rc='$negctl_rc' outside_exists=$([[ -e "$OUTSIDE" ]] && echo yes || echo no))"
fi

echo "--- result ---"
echo "PASS=$pass FAIL=$fail"
if [[ "$fail" -eq 0 ]]; then
  echo "✅ sandbox 外壁 genuine(block-side PASS)かつ sandboxed worker は git commit(共有 .git) + bd close(.beads) を境界を通って永続できる"
  exit 0
else
  echo "❌ sandbox 内の実操作が永続していない(上の FAIL / CC 出力を確認)"
  [[ "$KEEP" -eq 0 ]] && echo "   再現解析は --keep で temp scaffold を保持して再実行する" >&2
  exit 1
fi

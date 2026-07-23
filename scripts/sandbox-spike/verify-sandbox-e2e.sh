#!/usr/bin/env bash
# verify-sandbox-e2e.sh — sc-7n1: SCRIBE_SANDBOX worker が sandbox 内で実際に
#   `git commit`(共有 .git へ)と `bd close`(.beads dolt へ)を end-to-end で永続できるかを、
#   完全 hermetic に実証する true-e2e ハーネス。
#
# 位置づけ: sc-1gu spike(run-spike.sh・削除済 commit 71bf862)は生ファイル書込みの *境界*
#   (a1 cwd allow / a2 <ANCHOR>/.beads allow / b1,b2 外壁 block)までを assert した。
#   本ハーネスはその先 — sandboxed worker の **実操作**(git commit / bd close)が allowWrite
#   境界(cwd+配下〔CC 既定〕/ .git commit write-set〔私有 gitdir + 共有 objects/refs/logs・明示 grant・sc-kxec〕/
#   <ANCHOR>/.beads / lock_dir)を通って *永続*するか — を埋める(sc-7n1)。README「未 assert」項の解消。
#   注(sc-kxec): 共有 .git は旧「CC 既定 writable・列挙不要」前提だったが、この既定が CC version で不安定に変わり
#   commit が silent に非永続化した(sc-ghjc・2.1.217)ため、gen が commit write-set を **明示 allowWrite grant** する
#   ように変更した。本 e2e は gen を直呼びするので、その明示 grant 経由で commit が共有 .git へ永続することを実証する。
#   注(sc-1d95): 上記「明示 grant *経由で* 永続」の裏返しとして、counterfactual 負 control(.git grant 4 集合を strip した
#   変種 settings で 2nd commit を試み HEAD 不変を assert)を加え、grant が load-bearing(無ければ非永続)であることを実証し
#   boundary-vacuous を閉じる。永続してしまったら「CC default auto-grant 復活の疑い(CC version drift)」で loud FAIL に倒す
#   (両向き drift を fail-closed)。加えて出力ヘッダに `claude --version` を in-band 自己捕捉し drift 調査の attribution を独立化する。
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
BDW_SHIM="$HERE/../bdw"      # sc-vae: bd write は bdw shim 経由(shim→canonical plugin)。allow-side で実走し、bwrap sandbox 内から
                             # canonical($HOME/.claude/plugins/beads-bdw/bin/bdw)を read/exec して直列化 write できるか(in-sandbox 到達)を直接 pin する。
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
# CC version 自己捕捉(sentinel・sc-1d95): PASS/FAIL どちらの記録にも実測 version を in-band で残し、将来の drift
# 調査で attribution(どの CC で観測されたか)を out-of-band 情報に頼らず独立に成立させる。head -1 で余分行を落とす。
CC_VERSION="$(claude --version 2>/dev/null | head -1 || true)"; [[ -n "$CC_VERSION" ]] || CC_VERSION="unknown"
echo "--- CC version: $CC_VERSION ---"
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
# 真の anchor を明示渡し（sc-lkg・本番 scribe-spawn と同経路）。同一リポ e2e なので逆算でも一致するが、
# 明示パスを実走して gen の第2引数 contract を e2e でも exercise する。
"$GEN" "$WT" "$ANCHOR" > "$WT/.claude/settings.local.json" || die "settings 生成失敗"
# settings.local.json を info/exclude へ除外する(sc-1gu・本番 scribe-spawn と同じ)。CC null-mount device の件は
# 下の WORKER_CMD が scribe-add(型で弾く stage ラッパ・sc-yqa B)を実走して扱う＝それが効くこと、かつ CC が
# null-mount を増やしても scribe-add は型ベースゆえ壊れないことを実 sandbox で実証する(sc-yqa 4b の robust 版)。
scribe_sandbox_write_exclude "$WT"
# bwrap の bind-before-exist 対策: grant 済 lock 鍵 file を worker 起動前に実在させる(本番 scribe-spawn と同じ)。
# lock file は canonical bdw に問い合わせる(OG-4・sc-mcx: lock dir 丸ごとから **file 単位** grant へ狭化・
# gen-sandbox の allowWrite と同 contract)。file 単位 grant では parent(lock dir)を grant しないため、mkdir -p で
# 親を作り file を **touch** で先在させる(mkdir -p では file を dir 化し flock が壊れる)。repo_id は cwd 依存
# (BDW_REPO_DIR override は効かない・verified)ゆえ subshell `(cd "$ANCHOR" && bdw lock-file)` で gen/worker と同一
# invocation にし byte 一致の鍵を得る。
_e2e_lock_file="$( (cd "$ANCHOR" && "$HERE/../bdw" lock-file) 2>/dev/null || true)"
if [[ -n "$_e2e_lock_file" ]]; then
  mkdir -p "$(dirname "$_e2e_lock_file")" 2>/dev/null && touch "$_e2e_lock_file" 2>/dev/null || true
fi
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
# block-side control: cwd($WT)の外かつ allowWrite([<anchor>/.beads runtime, lock 鍵 file])外の anchor 直下。
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
# bd close は **bdw shim 経由**($BDW_SHIM close→shim が canonical を exec して flock 直列化)で実走する(sc-vae: in-sandbox の
# canonical 到達+書込みを直接 pin。bare `bd close` だと shim→plugin を通らず到達性を検証できなかった)。
WORKER_CMD="cd '$WT' && printf 'e2e\n' > '$MARKER'; git add -A >/dev/null 2>&1; printf '%s' \$? > '$NEGCTL'; git reset -q >/dev/null 2>&1; '$SADD' && git commit -q -m '$COMMIT_MSG' && echo $TOK_GIT; '$BDW_SHIM' close '$ISSUE' >/dev/null 2>&1 && echo $TOK_BD; printf x > '$OUTSIDE' 2>/dev/null; [ -e '$OUTSIDE' ] && printf wrote > '$INBOUND' || printf blocked > '$INBOUND'"

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

# 5) counterfactual 負 control(sc-1d95): 上の正 control 群(commit が明示 grant *経由で* 永続すること)の裏返し —
#    gen の生成 settings から **.git grant 4 集合(私有 gitdir + 共有 objects/refs/logs)だけを strip** した変種で
#    第2の sandboxed CC commit を試み、共有 .git の HEAD が **不変(before==after)** であることを assert する。これで
#    「.git grant は load-bearing(無ければ commit は永続しない)」を counterfactual 実証し boundary-vacuous を閉じる。
#    判定は **rc でなく HEAD 比較**: CC 2.1.217 の silent rc=0 消失(commit が黙って非永続)にも 2.1.211 系の loud EROFS
#    にも同じ判定式が成立する(rc 非依存)。もし strip しても commit が永続してしまったら FAIL とし、文言で「CC default
#    auto-grant 復活の疑い(CC version drift)」を名指す — 明示 grant の load-bearing 性が崩れた合図。どちら向きの drift
#    (grant が効かず正 control が落ちる / grant 無しでも通り負 control が落ちる)も loud fail-closed で倒す(silent 化の
#    再演防止=本 bead の趣意)。strip は jq で allowWrite から共有 .git 配下 path のみ除去し **.beads/lock grant は残す**
#    (負 control が「sandbox 全体の故障」でなく「.git grant の欠如」だけを isolate する)。
TOK_CF="SC1D95_CF_RAN"
CF_MARKER="sc1d95-cf-marker.txt"
CF_MSG="sc1d95-cf-commit-$$"
# 共有 .git common-dir を物理正規化(pwd -P)で取る。gen の .git grant(私有 gitdir + objects/refs/logs)は全て この
# common-dir 配下の物理 path として emit される(gen 本体と同一導出)ため、この prefix startswith で 4 集合を漏れなく
# 特定できる(.beads は $ANCHOR/.beads・lock 鍵は $HOME/.cache 配下ゆえ prefix 外=strip されない=isolate 成立)。
cf_git_common="$(gitc -C "$WT" rev-parse --git-common-dir 2>/dev/null || true)"
[[ -n "$cf_git_common" ]] && cf_git_common="$(cd "$WT" && cd "$cf_git_common" 2>/dev/null && pwd -P || true)"
[[ -n "$cf_git_common" ]] || die "counterfactual: 共有 .git common-dir の解決に失敗"
_cf_settings="$WT/.claude/settings.local.json"
# 正 control で使った settings から共有 .git 配下 grant だけを strip(.beads/lock は保持)。同 dir 内 temp→mv で atomic。
jq --arg gd "$cf_git_common/" '.sandbox.filesystem.allowWrite |= map(select(startswith($gd)|not))' \
   "$_cf_settings" > "$_cf_settings.cf" || die "counterfactual: settings strip(jq)失敗"
mv "$_cf_settings.cf" "$_cf_settings"
# isolate の検証(fail-closed): strip 後 allowWrite に .git 配下は 0 件・.beads grant は 1 件以上残ることを確認する。
# これが崩れると負 control が「.git grant 欠如」でなく別要因を測る恐れがあるため die する(strip が空振り/過剰の検出)。
cf_n_git="$(jq --arg gd "$cf_git_common/" '[.sandbox.filesystem.allowWrite[]|select(startswith($gd))]|length' "$_cf_settings")"
cf_n_beads="$(jq '[.sandbox.filesystem.allowWrite[]|select(contains("/.beads/"))]|length' "$_cf_settings")"
[[ "$cf_n_git" -eq 0 && "$cf_n_beads" -ge 1 ]] \
  || die "counterfactual: strip の isolate 不成立(.git 残=$cf_n_git .beads 残=$cf_n_beads)＝.git 4 集合のみ除去の前提が崩れた"
echo "--- counterfactual settings(.git grant 4 集合を strip 済・.beads/lock grant は保持) ---"; cat "$_cf_settings"
# HEAD before を **2nd CC 直前に再取得**する(1回目の成功 commit が baseline を汚染しないよう before を取り直す)。
cf_before="$(gitc -C "$WT" rev-parse HEAD)"
# 2nd sandboxed worker: 新規 marker を作り scribe-add→commit を試みる(1回目と同型・commit 試行のみ・bd close は不要=
# isolate 対象は git 永続だけ)。`;` 区切りで TOK_CF は commit 成否に依らず必ず echo する(CC boot 失敗の vacuous-PASS
# guard)。.git grant を strip したので index/objects/refs 書込は外壁で拒否され commit は非永続化するのが期待値。
# ★2nd run にも block-side witness を同梱する(sc-1d95): counterfactual の一次シグナル「HEAD 不変/変化」は、2nd sandbox が
# genuine に効いた前提でのみ「.git grant の load-bearing 性」を測る。もし 2nd run の sandbox が silent に無効化していれば
# HEAD 変化は「.git auto-grant」でなく「sandbox off」を意味しうる(偽 drift alarm)。よって 1st run と同じ anchor 直下への
# 書込みを試み CF_INBOUND(cwd 内・narration 非依存の実ファイル)に blocked/wrote を残させ、2nd run でも外壁が genuine
# (anchor 直下 blocked)であることを独立に witness する。これで「sandbox genuine かつ .git commit 永続」= 真の CC
# auto-grant drift、「sandbox off」= 判定不能、を分離し FAIL の attribution を airtight にする。
CF_OUTSIDE="$ANCHOR/sc1d95-cf-OUTSIDE.txt"    # 2nd-run block-side: allowWrite 外(anchor 直下)。外壁 genuine なら書けない。
CF_INBOUND="$WT/sc1d95-cf-blockresult.txt"    # 2nd-run block witness: worker が自己判定した blocked/wrote(cwd 内実ファイル)。
CF_WORKER_CMD="cd '$WT' && printf 'cf\n' > '$CF_MARKER'; '$SADD' >/dev/null 2>&1; git commit -q -m '$CF_MSG' >/dev/null 2>&1; printf x > '$CF_OUTSIDE' 2>/dev/null; [ -e '$CF_OUTSIDE' ] && printf wrote > '$CF_INBOUND' || printf blocked > '$CF_INBOUND'; echo $TOK_CF"
echo "--- 実 CC を sandbox で起動(counterfactual: .git grant 無しで commit 試行 + 2nd-run block witness)---"
CF_OUT="$( cd "$WT" && claude -p --permission-mode bypassPermissions \
  "あなたはテストハーネス。次の bash コマンドを Bash ツールで 1 回だけ厳密に実行し、stdout/stderr をそのまま報告せよ。説明や追加コマンドは不要。コマンド: $CF_WORKER_CMD" \
  2>&1 )" || true
cf_after="$(gitc -C "$WT" rev-parse HEAD)"
cf_ran=no; grep -q "$TOK_CF" <<<"$CF_OUT" && cf_ran=yes
# 2nd-run の外壁 genuine witness: worker が cwd 内 CF_INBOUND に残した実ファイル(narration では作られない)+ 外側から見た
# CF_OUTSIDE の不在。両者が「blocked かつ OUTSIDE 不在」なら 2nd sandbox は genuine に効いている。
cf_block_result="$(cat "$CF_INBOUND" 2>/dev/null || true)"

pass=0; fail=0; drift=0
# sc-1d95 裁定改訂(2026-07-23): DRIFT = CC 側 auto-grant 復活の検出。FAIL でなく loud 表示のみ(rc 非影響)。
# 根拠: 有害方向(grant 有りで非永続)は正 control が FAIL で守る/auto-grant 復活時は明示 grant が冗長になるだけで無害/
# CC は 8 日で 4 回 flip しており(2.1.211 EROFS→215/216 persist→217 silent loss→218 persist)、上流都合で配布 lane を
# 長期 RED にすると RED 慣れを生む。DRIFT は毎 run in-band で surface し人間 review を促す(黙殺はしない)。
verdict() {
  case "$1" in
    PASS)  pass=$((pass+1)) ;;
    DRIFT) drift=$((drift+1)) ;;
    *)     fail=$((fail+1)) ;;
  esac
  printf '  [%s] %s\n' "$1" "$2"
}

echo "--- asserts ---"
# git commit: token が出て(=実行)・HEAD が前進し・新 HEAD のメッセージが一致 → 共有 .git に永続。
if [[ "$git_ran" != yes ]]; then
  verdict FAIL "git commit: CC が走った証跡(token)なし — sandbox boot 失敗の疑い(vacuous-PASS 防止)"
elif [[ "$before" != "$after" && "$commit_msg" == "$COMMIT_MSG" ]]; then
  verdict PASS "git commit: 共有 .git に永続($before -> $after / msg='$commit_msg')"
else
  verdict FAIL "git commit: 反映されず(before=$before after=$after msg='$commit_msg')"
fi
# bd close(bdw shim 経由): token が出て・anchor 側 bd show が CLOSED → sandbox 内から canonical plugin を exec して
#   flock 直列化 write が .beads dolt に永続(sc-vae: in-sandbox の canonical 到達+書込みを実証)。
if [[ "$bd_ran" != yes ]]; then
  verdict FAIL "bdw close: CC が走った証跡(token)なし(vacuous-PASS 防止／in-sandbox で canonical 不到達の疑い)"
elif grep -qi 'closed' <<<"$issue_state"; then
  verdict PASS "bdw close(shim→canonical): sandbox 内から plugin 到達+直列化 write が anchor .beads に永続($ISSUE = CLOSED)"
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

# counterfactual 負 control(sc-1d95): .git grant 4 集合を strip したら 2nd commit が **非永続**(HEAD 不変)=明示 grant は
# load-bearing。判定は rc 非依存の HEAD before==after だが、2nd sandbox が genuine に効いている前提でのみ意味を持つゆえ
# block-side witness(cf_block_result==blocked かつ CF_OUTSIDE 不在)を connective として要求し attribution を airtight にする:
#   - cf_ran!=yes            → 2nd CC boot 失敗(HEAD 不変が未実行か genuine block か判別不能)= fail-closed
#   - 2nd sandbox not genuine → CF_INBOUND!=blocked か CF_OUTSIDE 実在 = sandbox off の疑いで HEAD 判定不能 = fail-closed
#   - genuine かつ HEAD 不変  → 明示 grant は load-bearing(strip で非永続)= PASS
#   - genuine かつ HEAD 変化  → sandbox は genuine なのに .git commit が永続 = CC default auto-grant 復活(CC version drift)
#                               の **確定**。裁定改訂(2026-07-23): FAIL でなく loud **DRIFT**(rc 非影響)。明示 grant は
#                               現 CC では冗長(無害・belt-and-suspenders 維持)で、有害方向は正 control が FAIL で検知する。
if [[ "$cf_ran" != yes ]]; then
  verdict FAIL "counterfactual: 2nd CC が走った証跡(token)なし=boot 失敗の疑い(vacuous-PASS 防止・HEAD 不変が genuine block か未実行か判別不能)"
elif [[ "$cf_block_result" != blocked || -e "$CF_OUTSIDE" ]]; then
  verdict FAIL "counterfactual: 2nd run の sandbox が genuine に効いていない(block witness='$cf_block_result' outside_exists=$([[ -e "$CF_OUTSIDE" ]] && echo yes || echo no))=HEAD 判定が sandbox-off で汚染される疑い(判定不能・fail-closed)"
elif [[ "$cf_before" == "$cf_after" ]]; then
  verdict PASS "counterfactual: 2nd sandbox genuine(anchor 直下 blocked)下で .git grant 4 集合を strip すると commit 非永続(HEAD 不変 $cf_before)=明示 grant は load-bearing(無ければ永続しない)"
else
  verdict DRIFT "counterfactual: 2nd sandbox genuine(anchor 直下 blocked)下で .git grant を strip しても commit が永続($cf_before -> $cf_after)=CC default auto-grant の復活を検出(CC version drift・CC $CC_VERSION)。明示 grant は現 CC では非 load-bearing(冗長だが無害)。有害方向(grant 有りで非永続)は正 control が FAIL で検知する(sc-1d95 裁定改訂)"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "--- 診断: CC 出力(正 control・sandbox 内の実行ログ) ---"
  printf '%s\n' "$CC_OUT" | sed 's/^/  | /'
  echo "--- 診断: CC 出力(counterfactual・.git grant strip 済) ---"
  printf '%s\n' "$CF_OUT" | sed 's/^/  | /'
  echo "  (flags: git_ran=$git_ran bd_ran=$bd_ran block_result='$block_result' negctl_rc='$negctl_rc' outside_exists=$([[ -e "$OUTSIDE" ]] && echo yes || echo no) cf_ran=$cf_ran cf_block_result='$cf_block_result' cf_outside_exists=$([[ -e "$CF_OUTSIDE" ]] && echo yes || echo no) cf_before=$cf_before cf_after=$cf_after CC=$CC_VERSION)"
fi

echo "--- result ---"
echo "PASS=$pass FAIL=$fail DRIFT=$drift"
if [[ "$fail" -eq 0 ]]; then
  echo "✅ sandbox 外壁 genuine(block-side PASS)かつ sandboxed worker は git commit(共有 .git) + bd close(.beads) を境界を通って永続できる"
  if [[ "$drift" -eq 0 ]]; then
    echo "   .git grant 4 集合を strip すると commit は非永続(counterfactual PASS)＝明示 grant は load-bearing(CC $CC_VERSION)"
  else
    echo "⚠ DRIFT: CC default auto-grant の復活を検出(CC $CC_VERSION)＝明示 grant は現 CC では冗長(無害・belt-and-suspenders として維持)。"
    echo "   CC が再び auto-grant を外せば counterfactual は PASS へ戻る。grant 破損(有害方向)は正 control が FAIL で検知する(sc-1d95 裁定改訂)。"
  fi
  exit 0
else
  echo "❌ sandbox 内の実操作が永続していない(上の FAIL / CC 出力を確認)"
  [[ "$KEEP" -eq 0 ]] && echo "   再現解析は --keep で temp scaffold を保持して再実行する" >&2
  exit 1
fi

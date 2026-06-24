#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook: 破壊的 git コマンドをブロックし、コマンド別の代替ルートを stderr に返す（exit 2）。
# 由来: uns git-destructive-guard (設計 bd un-0gu) を scribe plugin へ re-home (sc-erd)。scribe は
#   hooks/hooks.json の PreToolUse[Bash] から ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/ 経由で起動する。
#   _is_live_anchor に scribe 署名 (.claude-plugin/plugin.json の name=='scribe') を追加し、uns 非導入ホストへ
#   配布したときも scribe-anchor の branch-switch 保護を成立させる。
#
# 方式（bd un-0gu）: コマンド文字列を shlex トークン化（共有 lib cmdtokens）し、**本物の `git` 呼び出しの
#   トークン列にのみ**ルールを適用する。これにより旧 .sh の substring/正規表現・全体一致が起こしていた
#   誤検出を構造的に排除する:
#     - `bd dolt push && rm -f x` … 別コマンドの語の共起で force-push 誤検出 → 解消（push は bd の語、-f は rm の語）。
#     - `echo "git checkout x"` / `grep "git switch" f` … クォート内データを実コマンド扱い → 解消（echo/grep の引数）。
#   ランチャ(sudo/env/timeout/flock...) / `bash -c "..."` / eval / su -c 等の経由も lib が貫通する。
#
# 検出対象（旧 .sh と機能等価。token 単位で精密化）:
#   force push(--force-with-lease は許可) / git clean -f / reset --hard / branch -D / stash drop|clear /
#   作業ツリー全体の checkout|restore(pathspec '.' / './' / ':/' / ':(top)' / '*' 等の全ツリーセレクタ; sc-oem) /
#   フック・署名の無効化(--no-verify/--no-gpg-sign/
#   core.hooksPath/commit.gpgsign=false) / live anchor の非main checkout|switch。
#
# 失敗時方針: 入力解析・guard 内部・lib ロードのいずれの例外でも **fail-open(exit 0)**＝複雑化した guard が
#   全 Bash を exit2 で brick しない（rm-guard と同方針）。deploy はツリー一括同期で lib 欠落は非現実。
# 検証: `python3 git-destructive-guard.py --self-test`（hermetic）。

import sys
import os
import re
import json
import subprocess

# cmdtokens consume preamble（テンプレ ~/.claude/plugins/cmdtokens/templates/cmdtokens-consume.py を inline）。
# canonical cmdtokens(cmdtokens plugin の単一 SSOT)を解決して import するだけの薄い層。CMDTOKENS_LIB で
# 上書き可（既定 = plugin 標準配置）。非絶対値は os.path.isabs で弾き既定へ落とす＝非空の相対値が expanduser
# 後も相対のまま sys.path に入り cwd 相対解決され、警告すら出ず誤った cmdtokens.py を load する silent poison
# import を回避（orch-a9y/bd-write-guard の独立 gate で検出した欠陥の修正）。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")
_cmdtokens_lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
if not os.path.isabs(_cmdtokens_lib):  # 非絶対(空/相対/whitespace) → cwd 相対 poison を避け既定へ
    _cmdtokens_lib = _CMDTOKENS_DEFAULT_LIB
try:
    sys.path.insert(0, _cmdtokens_lib)
    from cmdtokens import iter_commands, long_opt_abbrev
except Exception as e:  # lib ロード不能 → fail-open（guard 無効化を loud に通知）
    sys.stderr.write(f"[git-guard] cannot load cmdtokens lib, failing open: {e}\n")
    sys.exit(0)

GIT_GLOBAL_VAL = {"-C", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                  "--config-env", "--super-prefix"}
GPGSIGN_FALSE = re.compile(r"commit\.gpgsign\s*=\s*false", re.I)
# checkout/switch で必ず現ブランチ(main)を離脱するフラグ（新ブランチ作成/detach/tracking）。短フラグ
# (単一文字)はそのまま、長フラグ(--orphan/--detach/--track)は getopt 短縮も拾う(sc-i13: long_opt_abbrev)。
ANCHOR_LEAVE_SHORT = {"-b", "-B", "-c", "-C", "-t"}
ANCHOR_LEAVE_LONG = ("orphan", "detach", "track")

# 作業ツリー全体を復元する pathspec セレクタ（完全一致で判定; sc-oem）。`.` だけでなく `./`・repo-root
# magic `:/`・`:(top)`・glob `*` も全ツリー復元になり、いずれも実機で未コミット変更を破壊する（`.` のみの
# 完全一致 block を回避していた）。`:/f.txt`・`./src/x`・`*.txt` 等の**特定ファイル/部分スコープは完全一致
# しないので含めない**（誤爆ゼロ＝over-block 安全側）。`:/.` は git 自身が reject(exit1) するため無害＝集合外。
WHOLE_TREE_PATHSPECS = {".", "./", ":/", ":(top)", "*"}


def _is_whole_tree_pathspec(token):
    """token が作業ツリー全体を指す pathspec セレクタと完全一致するか（sc-oem）。"""
    return token in WHOLE_TREE_PATHSPECS


def _short_flags(tok):
    """`-fd` 形式の短縮フラグクラスタの文字列を返す（`-fd`→`fd`）。長opt(--)/非フラグ/`-`は空。"""
    if not tok.startswith("-") or tok.startswith("--") or tok == "-":
        return ""
    return tok[1:].split("=", 1)[0]


def _parse_git(args):
    """git のグローバルオプションを消費し (sub, sub_args, git_C, c_configs) を返す。
    sub はサブコマンド（無ければ None）。`-C path` と `-c key=val` を尊重して取り出す。"""
    git_C = None
    c_configs = []
    i = 0
    while i < len(args):
        t = args[i]
        if t == "-C" and i + 1 < len(args):
            git_C = args[i + 1]
            i += 2
            continue
        if t == "-c" and i + 1 < len(args):
            c_configs.append(args[i + 1])
            i += 2
            continue
        if t.startswith("-c") and len(t) > 2:  # 念のため glued `-ckey=val`
            c_configs.append(t[2:])
            i += 1
            continue
        if t in GIT_GLOBAL_VAL and i + 1 < len(args):
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t, args[i + 1:], git_C, c_configs
    return None, [], git_C, c_configs


def _git_toplevel(target):
    try:
        out = subprocess.run(["git", "-C", target, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=3)
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return ""


def _is_live_anchor(top):
    """top(=git toplevel) が live anchor 作業ツリーか。#329 と同一の 2 段判定 + scribe 署名。
    主判定: sentinel(~/.claude/CLAUDE.md の実体)が top 配下（symlink 健全時）。
    ﾌｫｰﾙﾊﾞｯｸ1(uns): sentinel が sever/欠落でも、top が「この設定リポの主作業ツリー」署名
              （.git がディレクトリ=worktree でない + modules.yaml + 本 guard）を持てば anchor。
    ﾌｫｰﾙﾊﾞｯｸ2(scribe plugin): top が scribe 主作業ツリー署名（.git=dir + .claude-plugin/plugin.json
              の name=='scribe'）を持てば anchor。uns 非導入ホストへ配布したとき主判定も
              ﾌｫｰﾙﾊﾞｯｸ1 も成立しないが、この署名で scribe-anchor を保護する(sc-erd)。
              identity は plugin name で弁別する(docs/protocol.md 単独だと他 plugin と衝突しうる)。"""
    try:
        sentinel = os.path.realpath(os.path.expanduser("~/.claude/CLAUDE.md"))
    except Exception:
        sentinel = ""
    if top and sentinel and sentinel.startswith(top.rstrip("/") + os.sep):
        return True
    if top and os.path.isdir(os.path.join(top, ".git")) \
       and os.path.isfile(os.path.join(top, "modules.yaml")) \
       and (os.path.isfile(os.path.join(top, "claude", "scripts", "git-destructive-guard.py"))
            or os.path.isfile(os.path.join(top, "claude", "scripts", "git-destructive-guard.sh"))):
        return True
    # scribe plugin anchor 署名: 主作業ツリー(.git=dir=worktree でない) かつ
    # .claude-plugin/plugin.json の name=='scribe'(canonical identity・doc 構成変更に不依存)。
    if top and os.path.isdir(os.path.join(top, ".git")) \
       and os.path.isdir(os.path.join(top, ".claude-plugin")):
        try:
            with open(os.path.join(top, ".claude-plugin", "plugin.json"), encoding="utf-8") as _fh:
                if json.load(_fh).get("name") == "scribe":
                    return True
        except Exception:
            pass
    return False


def _anchor_switch_allowed(sub, sub_args, args):
    """live anchor 上の checkout/switch を ALLOW してよいか（安全側=判断不能は False=block）。
    トークン存在の有無でなく**オペランド構造**で判定する（main/master を start-point に置く新ブランチ作成や
    末尾 `--` での偽装を塞ぐ）。True を返す安全形のみ:
      - --help / --version
      - `--` の後に pathspec を伴うファイル復元（ブランチ切替でない）
      - checkout <tree-ish> <pathspec...>（positional >=2）の path checkout（切替でない）
      - ターゲットが唯一の positional でかつ厳密に main/master の単純切替
    新ブランチ作成(-b/-B/-c/-C/--orphan)・detach・tracking(-t/--track)・`-`(直前ブランチ)・
    detached ref への切替は常に False（main 離脱）。anchor 限定なので過剰ブロックは worktree 利用へ誘導するだけ。"""
    if "--help" in args or "--version" in args:
        return True
    if "--" in sub_args:
        dd = sub_args.index("--")
        pre, post = sub_args[:dd], sub_args[dd + 1:]
    else:
        pre, post = list(sub_args), None
    for a in pre:
        flag = a.split("=", 1)[0]
        if flag in ANCHOR_LEAVE_SHORT or any(long_opt_abbrev(flag, lo) for lo in ANCHOR_LEAVE_LONG):
            return False  # 新ブランチ作成/detach/tracking は常に main を離脱（長フラグ短縮も sc-i13）
    # positional オペランド（非フラグ。`-`=直前ブランチは positional 扱い＝target 不明で block 方向）
    positionals = [a for a in pre if (not a.startswith("-")) or a == "-"]
    if post is not None and len(post) >= 1:
        return True  # `checkout [<ref>] -- <pathspec>` ファイル復元（切替でない）
    if sub == "checkout" and len(positionals) >= 2:
        return True  # `checkout <tree-ish> <pathspec...>` path checkout（切替でない）
    if len(positionals) == 1:
        return positionals[0] in ("main", "master")  # 単純切替: target が main/master のみ
    if len(positionals) == 0:
        return True  # bare checkout/switch（target 無し）= 切替なし/無害
    return False


def check_git(core, seg_cwd):
    """git コマンドの token 列を判定。ブロック理由(str) か None。"""
    args = core[1:]
    sub, sub_args, git_C, c_configs = _parse_git(args)

    # フック/署名の無効化（サブコマンド非依存・グローバル -c でも指定されうる）
    for t in args:
        if long_opt_abbrev(t, "no-verify") or long_opt_abbrev(t, "no-gpg-sign"):
            return "フック/署名の無効化(--no-verify/--no-gpg-sign)は禁止。フック失敗や署名設定の問題を調査・修正する。"
    # `-c key=val` グローバル注入のみを検査対象にする（sc-9j2: 旧 `c_configs + args` は args=サブコマンド
    # 以降の全トークン=commit メッセージ値・ファイル名・mv オペランドまで同列スキャンし、core.hooksPath/gpgsign
    # を含む正当操作を誤ブロックしていた。real 注入 `-c core.hooksPath=...` は c_configs で捕捉維持）。
    for cfg in c_configs:
        if "core.hooksPath" in cfg or GPGSIGN_FALSE.search(cfg):
            return "フック/署名の無効化(core.hooksPath/commit.gpgsign=false)は禁止。設定問題を調査・修正する。"
    # `git config core.hooksPath ...` の永続設定も同じ無効化ベクタ（config サブコマンドの引数に限定＝
    # データ文字列の誤ブロックを避けつつ永続的フック無効化は捕捉維持）。
    if sub == "config" and any("core.hooksPath" in a or GPGSIGN_FALSE.search(a) for a in sub_args):
        return "フック/署名の無効化(core.hooksPath/commit.gpgsign=false)は禁止。設定問題を調査・修正する。"

    if sub is None:
        return None

    if sub == "push":
        lease = any(a == "--force-with-lease" or a.startswith("--force-with-lease=")
                    or a == "--force-if-includes" or a.startswith("--force-if-includes=")
                    for a in sub_args)
        forced = any(a == "--force" or "f" in _short_flags(a) for a in sub_args)
        if forced and not lease:
            return "force push は禁止。--force-with-lease を使うか、PR ワークフロー経由で。"
        # 先頭 `+` の明示 refspec は非fast-forward(force) push（--force-with-lease で無害化できない）。
        if any(a.startswith("+") and len(a) > 1 for a in sub_args):
            return "force push(+refspec)は禁止。先頭 + の refspec は非fast-forward push。PR ワークフロー経由で。"

    if sub == "clean":
        if any(long_opt_abbrev(a, "force") or "f" in _short_flags(a) for a in sub_args):
            return "git clean -f は禁止。git clean -n で確認後、削除はユーザーに委譲。"

    if sub == "reset" and any(long_opt_abbrev(a, "hard") for a in sub_args):
        return "git reset --hard は禁止。git restore --staged <file> か git stash で退避。"

    if sub == "branch":
        if any("D" in _short_flags(a) for a in sub_args):
            return "git branch -D（強制削除）は禁止。マージ済みなら git branch -d。"
        # 小文字 -d と -f の併用（-d -f / -fd / -df / --delete --force）= force delete ＝ -D 等価（sc-1yz root#4）。
        # -d / --delete 単独（force なし）は安全削除ゆえ ALLOW 維持。
        _has_del = any("d" in _short_flags(a) or long_opt_abbrev(a, "delete") for a in sub_args)
        _has_force = any("f" in _short_flags(a) or long_opt_abbrev(a, "force") for a in sub_args)
        if _has_del and _has_force:
            return "git branch --delete --force（強制削除）は禁止。マージ済みなら git branch -d。"

    if sub == "stash" and ("drop" in sub_args or "clear" in sub_args):
        return "stash の破棄は禁止。残すか、削除はユーザーに委譲。"

    # 作業ツリー全体の復元（`.` / `./` / `:/` / `:(top)` / `*` 等の全ツリー pathspec; sc-oem）。
    # 個別ファイル/部分スコープ（`:/foo`・`./src/x`・`*.txt`・`-- <file>`）は完全一致でないので弾かない。
    if sub in ("checkout", "restore") and any(_is_whole_tree_pathspec(a) for a in sub_args):
        return "作業ツリー全体の復元は禁止。git restore <specific-file> で個別に。"

    # live anchor のブランチ切替（worktree 運用での anchor 誤乗っ取り防止）
    if sub in ("checkout", "switch"):
        if git_C:
            target = git_C if os.path.isabs(git_C) else os.path.normpath(os.path.join(seg_cwd, git_C))
        else:
            target = seg_cwd
        top = _git_toplevel(target)
        if top and _is_live_anchor(top) and not _anchor_switch_allowed(sub, sub_args, args):
            return ("live anchor のブランチ切替は禁止。worktree で作業せよ"
                    "（git worktree add .worktrees/<branch> または /session:spawn --worktree）。"
                    "desktop の live テストは人間が生シェルで checkout すること。")
    return None


def render(reason):
    return f"DENIED(git): {reason}\n"


def decide(cmd, cwd):
    if not cmd:
        return 0, ""
    for core, seg_cwd in iter_commands(cmd, cwd):
        if not core or os.path.basename(core[0]) != "git":
            continue
        reason = check_git(core, seg_cwd)
        if reason:
            return 2, render(reason)
    return 0, ""


def main():
    if "--self-test" in sys.argv:
        return run_self_test()
    try:
        # stdin.read() も try 内に置く（sc-a7t: 非UTF-8 raw バイトの UnicodeDecodeError を捕捉して
        # 整形 fail-open(exit0)へ倒す。try 外だと未捕捉例外で exit1 化し fail-open 経路と不整合になる）。
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        data = json.loads(raw) if raw.strip() else {}
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
        cwd = data.get("cwd") or os.getcwd()
    except Exception as e:
        sys.stderr.write(f"[git-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg = decide(cmd, cwd)
    except Exception as e:
        sys.stderr.write(f"[git-guard] internal error, failing open: {e}\n")
        return 0
    if msg:
        sys.stderr.write(msg)
    return code


# --- self-test（hermetic: tempdir に fixture repo を作り判定だけ検証。実破壊しない） ----
def run_self_test():
    import tempfile

    tmp = os.path.realpath(tempfile.mkdtemp(prefix="gitguard-selftest-"))

    def _g(repo, args):
        subprocess.run(["git", "-C", repo] + args, capture_output=True, text=True, timeout=5)

    def mkrepo(path, anchor_sig=False, plugin_name=None):
        os.makedirs(path, exist_ok=True)
        _g(path, ["init", "-q"])
        _g(path, ["config", "user.email", "t@t"])
        _g(path, ["config", "user.name", "t"])
        if anchor_sig:
            open(os.path.join(path, "modules.yaml"), "w").write("x\n")
            os.makedirs(os.path.join(path, "claude", "scripts"), exist_ok=True)
            open(os.path.join(path, "claude", "scripts", "git-destructive-guard.py"), "w").write("x\n")
        if plugin_name is not None:  # plugin fixture: plugin.json(name) が署名の弁別子。docs/protocol.md は realistic な付随物で _is_live_anchor は読まない(sc-ekd)
            os.makedirs(os.path.join(path, ".claude-plugin"), exist_ok=True)
            open(os.path.join(path, ".claude-plugin", "plugin.json"), "w").write(json.dumps({"name": plugin_name}) + "\n")
            os.makedirs(os.path.join(path, "docs"), exist_ok=True)
            open(os.path.join(path, "docs", "protocol.md"), "w").write("x\n")
        open(os.path.join(path, "f.txt"), "w").write("x\n")
        _g(path, ["add", "-A"])
        _g(path, ["commit", "-qm", "init"])
        return path

    anchor = mkrepo(os.path.join(tmp, "anchor"), anchor_sig=True)        # 署名あり=anchor 扱い
    plain = mkrepo(os.path.join(tmp, "plain"), anchor_sig=False)         # 署名なし
    # anchor の worktree（.git はファイル）→ 非 anchor
    wt = os.path.join(tmp, "anchor-wt")
    subprocess.run(["git", "-C", anchor, "worktree", "add", "-q", "-b", "wtbranch", wt],
                   capture_output=True, text=True, timeout=5)
    # scribe plugin 署名 anchor とその worktree（.git ファイル=非 anchor）
    scribe_anchor = mkrepo(os.path.join(tmp, "scribe-anchor"), plugin_name="scribe")
    scribe_wt = os.path.join(tmp, "scribe-anchor-wt")
    subprocess.run(["git", "-C", scribe_anchor, "worktree", "add", "-q", "-b", "scwt", scribe_wt],
                   capture_output=True, text=True, timeout=5)
    # name != scribe の他 plugin リポ（.claude-plugin + docs/protocol.md を持つが non-anchor 期待）
    notscribe = mkrepo(os.path.join(tmp, "other-plugin"), plugin_name="other")

    B, A = 2, 0
    cases = [
        # --- force push ---
        ("git push -f", tmp, B, "push -f"),
        ("git push --force", tmp, B, "push --force"),
        ("git push --force-with-lease", tmp, A, "push --force-with-lease allowed"),
        ("git push --force-with-lease=origin/main", tmp, A, "lease=ref allowed"),
        ("git push -f --force-with-lease", tmp, A, "lease present overrides -f"),
        ("git push origin main", tmp, A, "normal push"),
        ("git push -u origin main", tmp, A, "push -u (not force)"),
        ("git push origin -f", tmp, B, "force flag after remote"),
        ("sudo git push --force", tmp, B, "launcher: sudo"),
        ('bash -c "git push -f"', tmp, B, "launcher: bash -c"),
        ("git push origin +main", tmp, B, "F12: +refspec force push"),
        ("git push origin +refs/heads/main", tmp, B, "F12: +refs/heads force"),
        ("git push origin +HEAD:main", tmp, B, "F12: +HEAD:main force"),
        ("git push origin main:main", tmp, A, "normal refspec (no +)"),
        ("git push origin +refs/heads/main:refs/heads/main", tmp, B, "old.sh-bypass: full +refspec force"),
        ("git push origin HEAD:+main", tmp, A, "boundary: + on dst side is not force (allow)"),
        ('echo $(git push -f)', tmp, B, "F14: substitution body runs git push -f"),
        ('git push $(echo -f)', tmp, A, "F14: dynamic-arg fail-open (documented)"),
        # --- FP regressions (核心) ---
        ("bd dolt push && rm -f x", tmp, A, "FP: push word + rm -f co-occur"),
        ('echo "git push -f"', tmp, A, "FP: echo containing git push -f"),
        ('grep "git checkout" file', tmp, A, "FP: grep git checkout"),
        ("git ls-files | cut -f1", tmp, A, "FP: ls-files + cut -f"),
        ("tmux new-window && git status", tmp, A, "FP: tmux co-occur, git status benign"),
        # --- clean / reset / branch / stash ---
        ("git clean -fd", tmp, B, "clean -fd"),
        ("git clean -n", tmp, A, "clean -n dry-run"),
        ("git clean -nf", tmp, B, "clean -nf (has f)"),
        ("git clean -x", tmp, A, "clean -x (no f)"),
        ("git clean -d -f", tmp, B, "old.sh-bypass: clean -d -f (f not first token)"),
        ("git clean -x -d -f", tmp, B, "old.sh-bypass: clean -x -d -f"),
        ("git clean -d --force", tmp, B, "old.sh-bypass: clean -d --force"),
        ("git reset --hard", tmp, B, "reset --hard"),
        ("git reset --hard HEAD~1", tmp, B, "reset --hard ref"),
        ("git reset --soft HEAD~1", tmp, A, "reset --soft"),
        ("git restore --staged f.txt", tmp, A, "restore --staged file (no dot)"),
        ("git branch -D feature", tmp, B, "branch -D"),
        ("git branch -d feature", tmp, A, "branch -d (safe)"),
        ("git branch --delete --force feature", tmp, B, "branch --delete --force"),
        ("git branch -fD feature", tmp, B, "old.sh-bypass: branch -fD cluster (D not first)"),
        ("git branch -rD origin/x", tmp, B, "old.sh-bypass: branch -rD cluster"),
        ("git stash drop", tmp, B, "stash drop"),
        ("git stash clear", tmp, B, "stash clear"),
        ("git stash", tmp, A, "stash (save)"),
        ("git stash list", tmp, A, "stash list"),
        # --- whole-tree checkout/restore ---
        ("git checkout .", tmp, B, "checkout . whole tree"),
        ("git checkout -- .", tmp, B, "checkout -- . whole tree"),
        ("git restore .", tmp, B, "restore . whole tree"),
        # --- sc-oem: `.` 以外の全ツリー pathspec も block / 特定ファイル・部分スコープは allow ---
        ("git restore ./", tmp, B, "sc-oem: restore ./ whole tree"),
        ("git restore :/", tmp, B, "sc-oem: restore :/ (repo-root magic) whole tree"),
        ("git checkout :/", tmp, B, "sc-oem: checkout :/ whole tree"),
        ("git restore ':(top)'", tmp, B, "sc-oem: restore ':(top)' (quoted magic) whole tree"),
        (r"git restore :\(top\)", tmp, B, "sc-oem: restore :\\(top\\) (escaped magic) whole tree"),
        ("git restore '*'", tmp, B, "sc-oem: restore '*' glob whole tree"),
        ("git restore -- :/", tmp, B, "sc-oem: restore -- :/ (位置非依存)"),
        # 未クォート :(top) は実 bash で構文err・cmdtokens も `(` を subshell 分割 → 非実行=非対象(allow)
        ("git restore :(top)", tmp, A, "sc-oem: 未クォート :(top) は非実行(subshell分割/構文err)=allow"),
        ("git restore :/f.txt", tmp, A, "sc-oem: :/f.txt は特定ファイル(allow)"),
        ("git restore ./src/x.c", tmp, A, "sc-oem: ./src/x.c は部分スコープ(allow)"),
        ("git restore '*.txt'", tmp, A, "sc-oem: *.txt 部分 glob(allow)"),
        ("git restore :/.", tmp, A, "sc-oem: :/. は git reject ゆえ集合外(allow)"),
        # --- hooks/sign disable ---
        ("git commit --no-verify -m x", tmp, B, "--no-verify"),
        ("git commit --no-gpg-sign -m x", tmp, B, "--no-gpg-sign"),
        ("git -c core.hooksPath=/dev/null commit -m x", tmp, B, "core.hooksPath via -c"),
        ("git -c commit.gpgsign=false commit -m x", tmp, B, "commit.gpgsign=false via -c"),
        ("git commit -m x", tmp, A, "normal commit"),
        # sc-9j2: commit メッセージ/ファイル名の hooksPath/gpgsign 文字列を誤ブロックしない（-c 注入と config 永続設定は維持）
        ("git commit -m 'disable core.hooksPath in tests'", tmp, A, "sc-9j2: hooksPath in commit msg = allow"),
        ("git add core.hooksPath", tmp, A, "sc-9j2: hooksPath as filename = allow"),
        ("git commit -m 'set commit.gpgsign=false later'", tmp, A, "sc-9j2: gpgsign in commit msg = allow"),
        ("git config core.hooksPath /dev/null", tmp, B, "sc-9j2: git config core.hooksPath = block 維持"),
        # --- anchor branch-switch guard ---
        (f"git -C {anchor} switch feature", tmp, B, "anchor: switch feature"),
        (f"git -C {anchor} checkout -b feature", tmp, B, "anchor: checkout -b new"),
        (f"git -C {anchor} switch -c feature", tmp, B, "anchor: switch -c new"),
        (f"git -C {anchor} switch main", tmp, A, "anchor: switch back to main allowed"),
        (f"git -C {anchor} checkout master", tmp, A, "anchor: checkout master allowed"),
        (f"git -C {anchor} checkout -- f.txt", tmp, A, "anchor: file restore allowed"),
        (f"git -C {anchor} switch --help", tmp, A, "anchor: --help allowed"),
        (f"git -C {anchor} switch -c feat main", tmp, B, "anchor F1: new-branch from main start-point"),
        (f"git -C {anchor} checkout -b feat main", tmp, B, "anchor F1: checkout -b from main"),
        (f"git -C {anchor} checkout -b main", tmp, B, "anchor F1: create branch named main"),
        (f"git -C {anchor} checkout feature --", tmp, B, "anchor F2: trailing -- bypass"),
        (f"git -C {anchor} switch feature --", tmp, B, "anchor F2: switch trailing --"),
        (f"git -C {anchor} checkout main -- f.txt", tmp, A, "anchor: file checkout from main (no switch)"),
        (f"git -C {anchor} checkout main f.txt", tmp, A, "anchor: 2-positional path checkout (no switch)"),
        (f"git -C {anchor} checkout -", tmp, B, "anchor: switch to previous branch"),
        (f"git -C {anchor} checkout HEAD~1", tmp, B, "anchor: detach at commit"),
        (f"git -C {anchor} checkout --detach", tmp, B, "anchor: --detach"),
        (f"git -C {anchor} checkout -t origin/feat", tmp, B, "anchor: -t tracking new branch"),
        (f"git -C {plain} switch feature", tmp, A, "non-anchor repo: switch allowed"),
        (f"git -C {wt} switch feature", tmp, A, "worktree(.git file): switch allowed"),
        (f"cd {anchor} && git switch feature", tmp, B, "anchor via cd (eff cwd)"),
        (f"cd {plain} && git switch feature", tmp, A, "non-anchor via cd"),
        # --- scribe plugin anchor 署名 (sc-erd: .claude-plugin/plugin.json name=='scribe') ---
        (f"git -C {scribe_anchor} switch feature", tmp, B, "scribe-anchor: switch feature"),
        (f"git -C {scribe_anchor} checkout -b feature", tmp, B, "scribe-anchor: checkout -b new"),
        (f"git -C {scribe_anchor} switch -c feat main", tmp, B, "scribe-anchor: new-branch from main"),
        (f"git -C {scribe_anchor} switch main", tmp, A, "scribe-anchor: switch back to main allowed"),
        (f"git -C {scribe_anchor} checkout -- f.txt", tmp, A, "scribe-anchor: file restore allowed"),
        (f"git -C {scribe_wt} switch feature", tmp, A, "scribe worktree(.git file): switch allowed"),
        (f"cd {scribe_anchor} && git switch feature", tmp, B, "scribe-anchor via cd (eff cwd)"),
        (f"git -C {notscribe} switch feature", tmp, A, "other-plugin(name!=scribe): switch allowed (誤判定しない)"),
        # --- sc-i13: 長オプション短縮形(getopt 曖昧でない接頭辞)も完全形と同様に block ---
        ("git reset --har HEAD~1", tmp, B, "sc-i13: reset --har (=--hard abbrev)"),
        ("git reset --ha HEAD~1", tmp, B, "sc-i13: reset --ha abbrev"),
        ("git reset --hardx HEAD~1", tmp, A, "sc-i13: --hardx は接頭辞でない -> 非--hard(allow)"),
        ("git clean -d --for", tmp, B, "sc-i13: clean --for (=--force abbrev)"),
        ("git clean -d --forc", tmp, B, "sc-i13: clean --forc abbrev"),
        ("git branch --del --forc feat", tmp, B, "sc-i13: branch --del --forc abbrev"),
        ("git branch --delete --forc feat", tmp, B, "sc-i13: branch --delete --forc"),
        ("git commit --no-veri -m x", tmp, B, "sc-i13: commit --no-veri (=--no-verify abbrev)"),
        ("git commit --no-gpg-si -m x", tmp, B, "sc-i13: --no-gpg-si (=--no-gpg-sign abbrev)"),
        ("git push --force-with-lease", tmp, A, "sc-i13: lease は force 接頭辞でなく温存(allow)"),
        (f"git -C {anchor} checkout --det", tmp, B, "sc-i13: anchor --det (=--detach abbrev)"),
        (f"git -C {anchor} checkout --orph feat", tmp, B, "sc-i13: anchor --orph (=--orphan abbrev)"),
        (f"git -C {anchor} switch --tra feat", tmp, B, "sc-i13: anchor --tra (=--track abbrev)"),
        # --- sc-1yz: shlex/bash 発散バイパス4形態（全て BLOCK）+ 安全対照（ALLOW 維持）---
        ("bash -c $'git push --force'", tmp, B, "sc-1yz#1: ANSI-C $'...' bypass"),
        (r"bash -c $'\x67it push --force'", tmp, B, "sc-1yz#1: ANSI-C escape \\x67 bypass"),
        ("bash <<<'git push --force'", tmp, B, "sc-1yz#2: glued here-string bypass"),
        ("bash --init-file /dev/null -c 'git push --force'", tmp, B, "sc-1yz#3: --init-file value-opt bypass"),
        ("bash -O extglob -c 'git push --force'", tmp, B, "sc-1yz#3: -O value-opt bypass"),
        ("git branch -d -f feature", tmp, B, "sc-1yz#4: branch -d -f force-delete"),
        ("git branch -fd feature", tmp, B, "sc-1yz#4: branch -fd clustered"),
        ("git branch -df feature", tmp, B, "sc-1yz#4: branch -df clustered"),
        ("git branch -d feature", tmp, A, "sc-1yz#4: branch -d alone (safe・allow 維持)"),
        ("git branch --delete feature", tmp, A, "sc-1yz#4: branch --delete alone (safe)"),
        ("bash -c 'git push --force'", tmp, B, "sc-1yz: space -c は従来通り block（回帰なし）"),
    ]

    failures = []
    for cmd, cwd, want, label in cases:
        try:
            code, _ = decide(cmd, cwd)
        except Exception as e:
            failures.append(f"[EXC] {label}: {cmd!r} -> {e}")
            continue
        if code != want:
            failures.append(f"[{'BLOCK' if want == 2 else 'ALLOW'} expected] {label}: {cmd!r} -> got {code}")

    import shutil
    shutil.rmtree(tmp, ignore_errors=True)
    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"git-guard self-test: {len(failures)}/{len(cases)} FAILED")
        return 1
    print(f"git-guard self-test: {len(cases)}/{len(cases)} OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

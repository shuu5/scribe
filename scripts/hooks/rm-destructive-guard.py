#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook: 復旧不能パスへの再帰削除を強制ブロックし、LLM に差し戻す。
#
# 由来: uns rm-destructive-guard(設計 bd un-2h7) を scribe plugin へ re-home(sc-nfs)。cmdtokens lib は
#   sc-erd(git-guard)で同梱済を共用。hooks/hooks.json の PreToolUse[Bash] から
#   ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/ 経由で git-guard と同居起動する。DATA_ROOTS はマシン固有ゆえ
#   配布 plugin では既定空 + SCRIBE_RM_GUARD_DATA_ROOTS env opt-in に変更(下記)。構造的保護
#   (system/HOME-subtree/git/gitignored)は DATA_ROOTS と独立に host-agnostic で機能する。
#
# 背景・設計（2026-06-08 grilling 確定。bd: un-2h7）:
#   bypassPermissions 下では Claude Code の workspace 書込み制限が外れ、worker/サブエージェントが
#   実ホストの任意パスを無確認で削除できる（実機検証済）。trust / additionalDirectories は Bash を
#   縛らない。組込み circuit breaker は `rm -rf /` と `rm -rf ~` のみ。本 hook はその穴を埋める。
#
#   PreToolUse hook の exit 2 は「permission 評価より前」に走り circuit breaker も先取りするため、
#   貴重パスへの rm を exit 2 で止めると《人間プロンプトを出さずに》LLM へ stderr で差し戻せる。
#
# 方針（grilling 合意）:
#   - philosophy = default-allow + protected-paths(denylist)。原則「復旧不能なものを守る」。
#   - 復旧可能 = git が tracked & committed。tracked-clean な削除は allow（git で戻せる）。
#   - 復旧不能 = git untracked/ignored の実データ。ただし「再生成物(node_modules 等)」は allow
#     （ただし repo 内に限る・nested .git を内包する dir は実 repo 内包の恐れがあり block）。
#   - 検出 = 方式2: クォート認識でコマンド分割 → トークン正規化(shlex)で本物の rm/find 呼出のみ判定
#            （substring 誤検出 ＝ echo "rm -rf"/ tmux&&rm -f を構造的に無視）→ 絶対パス正規化。
#            brace 展開 / 透過ランチャ / bash -c / eval / xargs / 制御構文 / here-string を貫通。
#   - 解決不能(変数/コマンド置換) = fail-open。ただし「空変数→ルート化」パターンだけ block。
#   - guard 自身がエラー = fail-open（複雑な guard が全 Bash を exit2 で brick するのを防ぐ）。
#   - v1 範囲 = rm 再帰系(-r/-R/--recursive) + sudo rm + find -delete/-exec rm。
#              git clean は既存 git-destructive-guard.py に委譲。
#
# v1 既知残存ギャップ（adversarial 2 ラウンド後・意図的に範囲外。honest-mistake 保護が目的で、
#   determined-adversary 用の真の隔離は sandbox スパイク bd:un-4ci が担う）:
#   - $(...)/backtick コマンド置換・$VAR ターゲットの値（fail-open）。
#   - ループ変数経由（for x in <precious>/*; do rm -rf "$x"; done）の dataflow。
#   - python -c "...shutil.rmtree..." / perl -e 等インタプリタ文字列での削除。
#   - 非再帰 rm -f 単体・shred・dd・>上書き・mv（blast radius 小／誤検出大）。
#   いずれも circuit breaker(~,/) と DATA_ROOTS/HOME 直下/system 保護が最終 backstop。
#
# 入力: Claude Code は hook 入力を stdin に JSON で渡す（tool_input.command / cwd）。
# 出力: 貴重判定で stderr に理由+代替を書き exit 2。それ以外/判定不能/自己エラーは exit 0。
#       例外: 解析資源上限到達時=brace 2^n 膨張/巨大トークン(shlex 暴走)/解析予算(per-target git fanout)
#       超過 は fail-CLOSED で、削除動詞を含みうる場合のみ exit 2（DoS→hook timeout→fail-open バイパス根治, un-uog）。

import sys
import os
import re
import json
import shlex
import glob as globmod
import fnmatch
import subprocess
import time

# 共有コマンドトークナイザ（bd un-0gu / 統合 un-x3o）。git guard と同じ lib(cmdtokens)を import し、
# パーサ部品(parse_statements/peel/shlex_safe/strip_redirections/track_cd/long_opt_abbrev)と本 guard が
# 直接参照する定数(SHELLS/VAR_OR_SUBST)を取り込む。透過ランチャ/制御構文の定数群の SSOT は cmdtokens 側に
# あり、rm-guard は使う名前のみ import する（sc-ekd: 未使用だった 9 定数を整理）。旧来は本ファイルに同一
# ロジックを複製しており、トークナイザを直す際に rm と git の検出が静かに乖離するセキュリティ境界の保守
# ハザードだった（un-0gu F13）。これを import 一本化で解消。
# lib ロード不能 → fail-open（guard 無効化を loud に通知。複雑な guard が全 Bash を brick するのを防ぐ）。
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
    from cmdtokens import (
        SHELLS, VAR_OR_SUBST,
        parse_statements, peel, shlex_safe, strip_redirections, track_cd,
        long_opt_abbrev,
    )
except Exception as e:  # lib ロード不能 → fail-open（guard 無効化を loud に通知）
    sys.stderr.write(f"[rm-guard] cannot load cmdtokens lib, failing open: {e}\n")
    sys.exit(0)

HOME = os.path.realpath(os.path.expanduser("~"))

# --- protected / disposable 定義 ---------------------------------------------

SYSTEM_ROOTS = {
    "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib32", "/lib64",
    "/libx32", "/media", "/mnt", "/opt", "/proc", "/root", "/run", "/sbin",
    "/srv", "/sys", "/usr", "/var",
}
# これらの配下も保護（/usr/local, /var/log, /etc/X 等）。scratch は除外。
SYSTEM_PREFIXES = (
    "/usr", "/etc", "/boot", "/bin", "/sbin", "/lib", "/lib64", "/lib32",
    "/libx32", "/opt", "/srv", "/root", "/sys", "/proc", "/run", "/dev", "/var", "/media",
)
SYSTEM_SCRATCH = ("/var/tmp", "/var/cache", "/dev/shm")

HOME_TOPLEVEL_ALLOW = {".cache", ".npm"}
HOME_TOPLEVEL_ALLOW_GLOBS = [".Trash-*"]

ALLOW_SUBTREE_ROOTS = [
    os.path.join(HOME, ".cache"),
    os.path.join(HOME, ".npm"),
    os.path.join(HOME, ".local", "share", "Trash"),
]

# DATA_ROOTS: git 管理外の保護データ木（再帰削除を無条件 block）。配布 plugin ゆえマシン固有パスを
# ハードコードしない（既定 = 空）。利用者は SCRIBE_RM_GUARD_DATA_ROOTS（コロン区切り絶対パス）で
# 自分のデータ木を opt-in 追加できる。このマシンでは global(~/.claude) rm-guard が固有 DATA_ROOTS を
# 引き続きカバーするため、本 plugin guard の既定空は二重発火で additive（弱体化なし）。
DATA_ROOTS = [p for p in os.environ.get("SCRIBE_RM_GUARD_DATA_ROOTS", "").split(":") if p]

DISPOSABLE_NAMES = {
    "node_modules", "dist", "build", ".next", ".nuxt", ".turbo", ".svelte-kit",
    "coverage", "__pycache__", ".venv", "venv", ".pytest_cache", ".mypy_cache",
    ".ruff_cache", ".tox", "target", ".gradle", "out", "vendor", "bin",
    ".cache", "tmp", ".terraform",
}
DISPOSABLE_GLOBS = ["*.egg-info"]

CONTAINS_REPO_MAXDEPTH = 6
MAX_BRACE_EXPANSION = 64
MAX_BRACE_WORK = 256          # brace 展開の総作業量(queue+results)・反復の上限。多段 brace の 2^n 膨張を阻止(un-uog)
MAX_SEG_LEN = 262144          # 単一セグメントの上限(256KB)。shlex.split が準2乗で暴走する巨大トークンを保守的 block(un-uog)。
                              # 256KB の shlex.split は約1.1s（< ANALYZE_BUDGET_SEC=3s）に収まり、128KB より誤検出面が小さい。
MAX_CMD_LEN = 1048576         # コマンド全体の上限(1MB)。parse_statements/多数 segment の budget 前段暴走を parse 前に保守的 block(un-uog)
ANALYZE_BUDGET_SEC = 3.0      # analyze 全体の wall-clock 予算。超過は fail-CLOSED で block(per-target git fanout/多数文 DoS 耐性, un-uog)
_ANALYZE_DEADLINE = None      # decide() がセットする wall-clock 期限(module global)。check_target/文ループが参照し fail-closed に block
_BUDGET_FINDING = ("(コマンド全体)", "解析予算超過: 安全に解析しきれないため保守的に block（DoS 耐性・fail-closed）")
_HUGE_SEG_FINDING = ("(巨大トークン)", "単一トークンが解析上限超過: shlex 暴走回避のため保守的に block（fail-closed）")


def _budget_expired():
    # 解析予算(wall-clock)を超過したか。decide() がセットする module global _ANALYZE_DEADLINE を
    # 参照する純述語。classify/check_target/文ループの fail-closed 判定が共有する(inline 展開時と挙動不変)。
    return _ANALYZE_DEADLINE is not None and time.monotonic() > _ANALYZE_DEADLINE

# 巨大コマンド/セグメントの安全弁。本 guard の範囲は削除(rm/find)のみ(ヘッダ参照)なので、解析上限を
# 超えた入力でも「削除の可能性すら無い」ものまで一律 block すると、削除でない巨大コマンド(base64 画像・
# JSON/SQL dump・curl -d ペイロード等)を削除テーマの誤メッセージで弾く scope 違反になる(un-uog F2)。
# そこで上限超過時は《削除動詞を含みうるか》だけ安価に substring 判定し、含む場合のみ fail-CLOSED で block、
# 含まなければ削除ではないと確定できるので fail-OPEN で通す。判定は意図的に広め(部分一致)＝迷ったら block。
_DELETION_HINT_RE = re.compile(r"\brm\b|\bfind\b|--recursive|-delete")
# 通常経路は shlex でトークン正規化するため r""m / r"m" / r''m / "r"m / \rm / fi"n"d 等の難読化を
# rm/find に畳んで検出できる。上限超過経路は shlex を呼べない(準2乗暴走回避)が、ここで raw 文字列の
# まま hint regex を当てると同じ難読化が \brm\b/\bfind\b の単語境界を崩して fail-OPEN にすり抜ける(un-uog F1/F3 回帰)。
# そこで shlex のクォート畳み込みを線形に模し、全クォート(" ')とバックスラッシュを除去してから regex を
# 当てる。空クォート対(""/'')だけでなく中身入りクォート(r"m"/r'm'/"r"m/fi"n"d)も rm/find に畳む必要がある
# ＝shlex は中身入りクォートも除去してトークンを連結するため(verified: shlex.split('r"m" -rf X')==['rm',...])。
# 除去は意図的に広め(過検出は fail-closed 方針に合致)＝上限超過(>256KB/>1MB)の極端経路で削除でない文字列が
# クォート内に rm/find を含む場合(grep "rm" 等)に block しうるが「迷ったら block」と一貫(un-uog F1/F3)。
_OBFUSC_RE = re.compile(r"[\"'\\]")


def _maybe_deletion(s):
    """上限超過時の保守判定: 文字列が削除(rm/find/-delete/--recursive)を含みうるか。
    含まなければ削除ではないと確定でき fail-open 可。含む(または曖昧)なら fail-closed で block。
    通常経路の shlex 正規化を模し、全クォート(" ')/バックスラッシュを除去してから判定することで
    r""m / r"m" / r''m / "r"m / \\rm / fi""nd / fi"n"d 等の難読化が上限超過経路をすり抜ける fail-OPEN を防ぐ(un-uog F1/F3)。"""
    return bool(_DELETION_HINT_RE.search(_OBFUSC_RE.sub("", s)))


# 透過ランチャ / シェル / -c 委譲ランチャ / 制御キーワード等の定数は cmdtokens から import 済（上記）。
# （旧来ここに同一定義を複製していたが un-x3o で SSOT 化＝import 一本化。peel/parse_statements 等が参照する。）


# --- git ヘルパ ---------------------------------------------------------------

def _git(repo, args, timeout=2):  # 2s: 健全 FS では ms 完了。hang(NFS stale 等)時の単一 classify 暴走を予算+timeout で抑制(un-uog)
    try:
        r = subprocess.run(["git", "-C", repo] + args,
                           capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout, r.stderr
    except Exception:
        return 1, "", "git-failed"


def repo_root_of(path):
    d = path if os.path.isdir(path) else os.path.dirname(path)
    if not d:
        return None
    code, out, _ = _git(d, ["rev-parse", "--show-toplevel"])
    if code == 0 and out.strip():
        return os.path.realpath(out.strip())
    return None


def is_repo_root(path):
    try:
        return os.path.exists(os.path.join(path, ".git"))
    except Exception:
        return False


def contains_git_repo(path):
    if not os.path.isdir(path):
        return False
    try:
        r = subprocess.run(
            ["find", path, "-maxdepth", str(CONTAINS_REPO_MAXDEPTH),
             "-name", ".git", "-print", "-quit"],
            capture_output=True, text=True, timeout=2)
        return bool(r.stdout.strip())
    except Exception:
        return False


def git_recoverable(repo, path):
    code, out, _ = _git(repo, ["status", "--porcelain", "--ignored", "--", path])
    if code != 0:
        return False
    return out.strip() == ""


# --- パス解決 -----------------------------------------------------------------

# VAR_OR_SUBST は cmdtokens から import 済（resolve_targets / track_cd が共用）。
# 破滅形のみ: ターゲット全体が $VAR / ${VAR} に / や /* が付くだけ（空変数なら / や /* 化）。
# `$VAR/subdir` 等の正当な変数パスは対象外（fail-open）＝過剰ブロック回避。
EMPTY_VAR_ROOT = re.compile(r'^\$\{?\w+\}?/\*?$')
BRACE_RE = re.compile(r"\{([^{}]*,[^{}]*)\}")


def brace_expand(s):
    """簡易 brace 展開: {a,b} / {,} を展開。返り値 (results, truncated)。
    FIFO 処理で先頭記載メンバーを優先保持。cap 超過時は truncated=True を返し、
    呼び元が保守的に block する（先頭の precious メンバー取りこぼしによる under-block 防止）。"""
    if "{" not in s:
        return [s], False
    results = []
    queue = [s]
    truncated = False
    iterations = 0
    while queue:
        # 結果数だけでなく総作業量(queue+results)・反復回数も上限化する。多段/ネスト brace
        # （x{a,b}{a,b}...）は brace-free 文字列が 2^n 段目まで現れず results 上限に達しないため、
        # queue が 2^n へ膨張し hook timeout 超過→exit2 を返せず fail-open する DoS を招く(un-uog)。
        # cap 超過は truncated=True ＝呼出側で保守的 block（先頭メンバー取りこぼしによる under-block 防止）。
        if len(results) >= MAX_BRACE_EXPANSION \
           or len(queue) + len(results) >= MAX_BRACE_WORK \
           or iterations >= MAX_BRACE_WORK:
            truncated = True
            break
        iterations += 1
        cur = queue.pop(0)  # FIFO（先頭記載メンバーを先に確定）
        m = BRACE_RE.search(cur)
        if not m:
            results.append(cur)
            continue
        pre, body, post = cur[:m.start()], m.group(1), cur[m.end():]
        for part in body.split(","):
            queue.append(pre + part + post)
    if queue:
        truncated = True
    if not results:
        results = [s]
    return results, truncated


def _safe_islink(p):
    try:
        return os.path.islink(p)
    except Exception:
        return False


def _canon(path, follow_last=True):
    path = path.rstrip("/") or "/"
    try:
        if follow_last:
            rp = os.path.realpath(path)
        else:
            parent = os.path.realpath(os.path.dirname(path))
            rp = os.path.join(parent, os.path.basename(path))
    except Exception:
        rp = os.path.abspath(path)
    if not os.path.isabs(rp):
        rp = os.path.abspath(rp)
    return rp


def _resolve_one(s, eff_cwd):
    a = os.path.expanduser(s)
    if any(c in a for c in "*?["):
        base = a if os.path.isabs(a) else os.path.join(eff_cwd, a)
        try:
            matches = globmod.glob(base)
        except Exception:
            matches = []
        return [("path", _canon(m, follow_last=True)) for m in matches]
    if not os.path.isabs(a):
        a = os.path.join(eff_cwd, a)
    bare = a.rstrip("/")
    follow_last = s.endswith("/") or not _safe_islink(bare)
    return [("path", _canon(a, follow_last=follow_last))]


_HOME_VAR_RE = re.compile(r'\$\{HOME\}|\$HOME(?![A-Za-z0-9_])')
_PWD_VAR_RE = re.compile(r'\$\{PWD\}|\$PWD(?![A-Za-z0-9_])')


def _subst_known_vars(s, eff_cwd):
    """値が確定する既知変数のみ展開（$HOME=hook の HOME / $PWD=入力 cwd）。最頻出の
    `rm -rf "$HOME/..."` を解決可能にする。未知変数は据え置き（fail-open のまま）。"""
    s = _HOME_VAR_RE.sub(HOME, s)
    s = _PWD_VAR_RE.sub(eff_cwd, s)
    return s


def resolve_targets(arg, eff_cwd):
    """ターゲット引数を (kind, value) 群に解決。kind ∈ {path, unresolvable, root-risk}。"""
    s = arg.strip()
    if not s:
        return []
    s = _subst_known_vars(s, eff_cwd)
    # 空のコマンド置換 $() / ${} / `` は除去（`rm -rf /precious$()` 難読化バイパス対策）。
    # 中身のある $(...) / ${VAR} / `cmd` は残す（→ unresolvable で fail-open）。
    s2 = re.sub(r'\$\(\s*\)|\$\{\s*\}|``', '', s)
    if VAR_OR_SUBST.search(s2):
        if EMPTY_VAR_ROOT.match(s2.strip('"').strip("'")):
            return [("root-risk", s)]
        return [("unresolvable", s)]
    out = []
    expansions, truncated = brace_expand(s2)
    if truncated:
        out.append(("root-risk", s))  # 大規模 brace は展開しきれない → 保守的に block
    for expanded in expansions:
        out.extend(_resolve_one(expanded, eff_cwd))
    return out


# --- 分類 ---------------------------------------------------------------------

def classify(p):
    p = p.rstrip("/") or "/"

    if p == "/" or p in SYSTEM_ROOTS:
        return True, "system/root path"
    if p == HOME:
        return True, "$HOME itself"

    for ar in ALLOW_SUBTREE_ROOTS:
        if p == ar or p.startswith(ar + os.sep):
            return False, ""

    # system 配下（/usr/local, /var/log 等）。ただし scratch は除外。
    if not any(p == sc or p.startswith(sc + os.sep) for sc in SYSTEM_SCRATCH):
        for pre in SYSTEM_PREFIXES:
            if p == pre or p.startswith(pre + os.sep):
                return True, "system path"

    base = os.path.basename(p)

    # HOME 配下: 使い捨て top-level（.cache/.npm/.Trash-*）は subtree allow。
    # それ以外は下の code(git)/disposable 判定へ落とし、最後に「user data/config/credentials」保護。
    under_home = (p == HOME) or p.startswith(HOME + os.sep)
    if under_home:
        rel = p[len(HOME):].lstrip(os.sep)
        top = rel.split(os.sep)[0] if rel else ""
        if top and (top in HOME_TOPLEVEL_ALLOW or any(fnmatch.fnmatch(top, g) for g in HOME_TOPLEVEL_ALLOW_GLOBS)):
            return False, ""

    for dr in DATA_ROOTS:
        if p == dr or p.startswith(dr + os.sep):
            return True, "protected non-git data tree (unrecoverable)"

    # ここから先は git/find subprocess(各 2s timeout)を最大3回発行する。予算切れなら subprocess を
    # 一切起動せず保守的 block（hang 中の classify が予算超過後も最大6s 走り続ける worst-case を抑え、
    # 10s hook timeout に対する真の margin を確保・un-uog F4）。判定は単純化のため再生不能と見なす。
    if _budget_expired():
        return True, _BUDGET_FINDING[1]

    repo = repo_root_of(p)
    in_repo_descendant = repo is not None and p != repo and p.startswith(repo + os.sep)

    if is_repo_root(p):
        return True, "git repository root (history loss is irreversible)"

    if _budget_expired():
        return True, _BUDGET_FINDING[1]
    # 配下に git repo を内包するなら disposable 名でも block（vendor/bin/out 等に実 repo を
    # 持つケースの誤許可を防ぐ。contains_git_repo を disposable allow より前に評価）。
    if contains_git_repo(p):
        return True, "deleting this would remove git repositories beneath it"

    is_disposable = base in DISPOSABLE_NAMES or any(fnmatch.fnmatch(base, g) for g in DISPOSABLE_GLOBS)

    if in_repo_descendant:
        # repo 内: 再生成物(node_modules/build 等)・tracked-clean は allow、
        # それ以外(gitignore/untracked の実データ)は block。
        if is_disposable:
            return False, ""
        if _budget_expired():
            return True, _BUDGET_FINDING[1]
        if git_recoverable(repo, p):
            return False, ""
        return True, "contains gitignored/untracked data that git cannot restore"

    # repo 外で HOME 配下 ＝ ユーザーデータ/設定/資格情報（~/.ssh/*, ~/.config/1Password,
    # ~/bin, ~/Pictures/... 等）→ subtree 保護。disposable 名(bin/tmp 等)でも HOME 直下は
    # 個人データの可能性があるので allow しない（repo 内の再生成物のみ allow）。
    if under_home and repo is None:
        return True, "protected directory under $HOME (user data / config / credentials)"

    # repo 外・HOME 外（/tmp 等のスクラッチ）は allow。
    return False, ""


def check_target(arg, eff_cwd):
    # 予算超過時は保守的に block（per-target の git subprocess fanout DoS 耐性・fail-closed・un-uog）
    if _budget_expired():
        return [_BUDGET_FINDING]
    out = []
    for kind, val in resolve_targets(arg, eff_cwd):
        # per-path 予算: 単一 glob/brace 引数が数千パスに展開した場合も classify 毎に検査(fail-closed・un-uog)
        if _budget_expired():
            out.append(_BUDGET_FINDING)
            break
        if kind == "root-risk":
            out.append((val, "target begins with an unresolved variable; if empty it expands toward a root path"))
        elif kind == "unresolvable":
            continue
        else:
            block, reason = classify(val)
            if block:
                out.append((val, reason))
    return out


# --- コマンド解析 -------------------------------------------------------------
#
# パーサ部品(parse_statements / shlex_safe / strip_redirections / peel / track_cd)を cmdtokens から
# import 済（ファイル冒頭。redirection 定数 REDIR_BARE/REDIR_GLUED は strip_redirections が cmdtokens 側で
# 使うため rm-guard は直接 import しない＝sc-ekd で未使用 import を整理）。
# 旧来ここに git guard と同一ロジックを複製していたが un-x3o で SSOT 化した。以降の
# is_recursive_rm / rm_targets / is_destructive_find / find_start_paths / analyze 等は
# import した部品を呼ぶ（高レベル駆動 analyze は rm-guard 固有なので本ファイルに残す）。


def is_recursive_rm(words):
    if not words or os.path.basename(words[0]) != "rm":
        return False
    for w in words[1:]:
        if w == "--":
            break
        # 長オプション短縮（--r/--re/.../--recursive）も再帰削除として扱う（sc-x4h: GNU rm は曖昧でない
        # 接頭辞を --recursive として受理＝完全一致のみだと rm --r -f <保護パス> が素通しされていた）。
        if long_opt_abbrev(w, "recursive"):
            return True
        if w.startswith("-") and not w.startswith("--"):
            if "r" in w or "R" in w:
                return True
    return False


def rm_targets(words):
    words = strip_redirections(words)
    targets, after_dd = [], False
    for w in words[1:]:
        if after_dd:
            targets.append(w)
            continue
        if w == "--":
            after_dd = True
            continue
        if w.startswith("-"):
            continue
        targets.append(w)
    return targets


def is_destructive_find(words):
    if not words or os.path.basename(words[0]) != "find":
        return False
    if "-delete" in words:
        return True
    for i, w in enumerate(words):
        if w in ("-exec", "-execdir", "-ok", "-okdir"):
            # 直後が rm、または shell(-c に rm を含む) なら破壊的
            rest = words[i + 1:]
            for k, t in enumerate(rest):
                if t in (";", "+", "\\;"):
                    break
                tb = os.path.basename(t)
                if tb == "rm":
                    return True
                if tb in SHELLS:
                    for u in rest[k:]:
                        if "rm" in u:
                            return True
    return False


FIND_GLOBAL_VALUE = {"-D"}


def find_start_paths(words):
    words = strip_redirections(words)
    i = 1
    while i < len(words):
        t = words[i]
        if t in ("-H", "-L", "-P"):
            i += 1
            continue
        if t in FIND_GLOBAL_VALUE:
            i += 2
            continue
        if t.startswith("-O"):
            i += 1
            continue
        break
    paths = []
    while i < len(words):
        t = words[i]
        if t.startswith("-") or t in ("(", ")", "!", ","):
            break
        paths.append(t)
        i += 1
    return paths or ["."]


SOURCE_CMDS = {"find", "ls", "echo", "printf", "cat", "stat", "readlink", "realpath", "dirname", "basename"}


def _pathlike(t):
    return t.startswith(("/", "~")) or t.startswith("./") or t.startswith("../")


def analyze(cmd, cwd, depth=0):
    findings = []
    if depth > 6:
        return findings
    # 予算/セグメント cap は parse_statements・shlex の後段でしか効かない。巨大コマンドは parse 前段で
    # 暴走しうる(parse_statements はリスト全構築、多数 segment の shlex 累積)ため、コマンド長を先に上限化する。
    # ただし本 guard の範囲は削除のみ。削除動詞を含まない巨大コマンドは削除ではないと確定でき fail-OPEN で通す
    # (削除テーマ block での scope 違反・誤検出を回避・un-uog F2)。削除を含みうる場合のみ fail-CLOSED block。
    if len(cmd) > MAX_CMD_LEN:
        return [_BUDGET_FINDING] if _maybe_deletion(cmd) else []
    # 空のコマンド置換 $() / ${} / `` をパース前に除去（`rm -rf /precious$()` 難読化バイパス対策。
    # parse_statements が ( ) を文分割で食う前に行う必要がある）。中身のあるものは残す。
    cmd = re.sub(r'\$\(\s*\)|\$\{\s*\}|``', '', cmd)
    eff = {"cwd": cwd}
    for statement in parse_statements(cmd):
        if _budget_expired():
            findings.append(_BUDGET_FINDING)  # 予算超過 → 残り文は解析せず保守的 block(fail-closed・un-uog)
            break
        seg_words = []
        for seg in statement:
            if _budget_expired():
                findings.append(_BUDGET_FINDING)  # pipeline 多数 segment の shlex 累積を予算で fail-closed(un-uog)
                break
            if len(seg) > MAX_SEG_LEN:
                # shlex 準2乗暴走回避。ただし削除動詞を含まない巨大セグメントは削除ではないと確定でき
                # skip=fail-OPEN（削除でない巨大トークンを削除メッセージで弾く scope 違反を回避・un-uog F2）。
                # 含みうる場合のみ shlex を呼ばず保守的 block=fail-CLOSED。
                if _maybe_deletion(seg):
                    findings.append(_HUGE_SEG_FINDING)
                continue
            w = shlex_safe(seg)
            if w:
                seg_words.append(w)
        if not seg_words:
            continue
        track_cd(seg_words[0], eff)

        pipeline_xargs_rm = False
        for words in seg_words:
            core, inline, is_xargs, cwd_ovr = peel(words)
            if cwd_ovr:
                seg_cwd = cwd_ovr if os.path.isabs(cwd_ovr) else os.path.normpath(os.path.join(eff["cwd"], cwd_ovr))
            else:
                seg_cwd = eff["cwd"]
            if inline is not None:
                findings.extend(analyze(inline, seg_cwd, depth + 1))
                continue
            core = strip_redirections(core)
            if not core:
                continue
            if is_xargs:
                if is_recursive_rm(core):
                    pipeline_xargs_rm = True
                    for t in rm_targets(core):
                        findings.extend(check_target(t, seg_cwd))
                continue
            if is_recursive_rm(core):
                for t in rm_targets(core):
                    findings.extend(check_target(t, seg_cwd))
            elif is_destructive_find(core):
                for t in find_start_paths(core):
                    findings.extend(check_target(t, seg_cwd))

        if pipeline_xargs_rm:
            for words in seg_words:
                core, _, is_xargs, _ = peel(words)
                core = strip_redirections(core)
                if is_xargs or not core:
                    continue
                b = os.path.basename(core[0])
                if b == "find":
                    for t in find_start_paths(core):
                        findings.extend(check_target(t, eff["cwd"]))
                elif b in SOURCE_CMDS:
                    for t in core[1:]:
                        if not t.startswith("-") and _pathlike(t):
                            findings.extend(check_target(t, eff["cwd"]))
    return findings


# --- メッセージ ---------------------------------------------------------------

def render(findings):
    seen, uniq = set(), []
    for tgt, reason in findings:
        if (tgt, reason) not in seen:
            seen.add((tgt, reason))
            uniq.append((tgt, reason))
    lines = ["DENIED(rm-guard): 復旧不能になりうる削除をブロックしました。盲目的に再試行しないこと。"]
    for tgt, reason in uniq:
        lines.append(f"  ✗ {tgt}\n     理由: {reason}")
    lines += [
        "",
        "代替（自己修正の指針）:",
        "  - git 管理下なら履歴で戻せる範囲か確認。repo root/worktree は `git worktree remove` 等を使う。",
        "  - 残したい/不確実なデータは削除でなく退避: `mv <target> /tmp/backup.$(date +%s)`。",
        "  - 本当に消すべき再生成物なら、保護対象でない明示パス/サブディレクトリを指定し直す。",
        "  - 判断がつかなければ administrator（親セッション/ユーザー）にエスカレートする。",
    ]
    return "\n".join(lines) + "\n"


# --- エントリポイント ---------------------------------------------------------

def decide(cmd, cwd):
    global _ANALYZE_DEADLINE
    if not cmd:
        return 0, ""
    _ANALYZE_DEADLINE = time.monotonic() + ANALYZE_BUDGET_SEC
    try:
        findings = analyze(cmd, cwd)
    finally:
        _ANALYZE_DEADLINE = None
    if findings:
        return 2, render(findings)
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
        sys.stderr.write(f"[rm-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg = decide(cmd, cwd)
    except Exception as e:
        sys.stderr.write(f"[rm-guard] internal error, failing open: {e}\n")
        return 0
    if msg:
        sys.stderr.write(msg)
    return code


# --- self-test（hermetic: tempdir に fixture を作って判定だけ検証。実削除しない） ----

def run_self_test():
    import tempfile
    import shutil
    global DATA_ROOTS, ALLOW_SUBTREE_ROOTS
    # fixture 置き場は **$HOME の外** に固定する（un-x3o）。tempfile.mkdtemp は既定で $TMPDIR を尊重するため、
    # TMPDIR=~/.claude/tmp 等で実行すると scratch fixture が HOME 配下へ落ち、guard が仕様通り
    # 「HOME 配下の user data」として block する＝expected-allow ケースが環境依存で誤 FAIL する。
    # ここで明示的に dir= を渡して TMPDIR を無視し、HOME 外の scratch 領域へ固定する（検出強度は不変＝
    # guard が block すべき HOME 配下を allow へ緩めるのではなく、テスト fixture を現実の scratch 位置へ移す）。
    base_dir = None
    for cand in ("/tmp", "/var/tmp", "/dev/shm"):
        rp = os.path.realpath(cand)
        # 候補が実在・書込可能で、かつ $HOME 配下でないこと（realpath で symlink 経由の HOME 流入も排除）。
        if os.path.isdir(rp) and os.access(rp, os.W_OK) and not (rp == HOME or rp.startswith(HOME + os.sep)):
            base_dir = rp
            break
    if base_dir is None:
        sys.stderr.write("[rm-guard self-test] no HOME-external scratch dir (/tmp 等)が見つからず "
                         "環境非依存にテストできません。FAIL.\n")
        return 1
    tmp = tempfile.mkdtemp(prefix="rmguard-selftest-", dir=base_dir)
    failures = []

    def mkrepo(path, ignored=None, tracked=None, nested_git=None):
        os.makedirs(path, exist_ok=True)
        _git(path, ["init", "-q"])
        _git(path, ["config", "user.email", "t@t"])
        _git(path, ["config", "user.name", "t"])
        if ignored:
            with open(os.path.join(path, ".gitignore"), "w") as f:
                f.write("\n".join(ignored) + "\n")
        for rel in (tracked or []):
            fp = os.path.join(path, rel)
            os.makedirs(os.path.dirname(fp), exist_ok=True)
            open(fp, "w").write("x")
        for rel in (ignored or []):
            d = os.path.join(path, rel.rstrip("/*"))
            os.makedirs(d, exist_ok=True)
            open(os.path.join(d, "data.bin"), "w").write("x")
        for ng in (nested_git or []):
            os.makedirs(os.path.join(path, ng, ".git"), exist_ok=True)
        _git(path, ["add", "-A"])
        _git(path, ["commit", "-qm", "init"])

    repo = os.path.join(tmp, "myrepo")
    mkrepo(repo, ignored=["rawdata/", "node_modules/", "dist/"],
           tracked=["src/main.py", "README.md"], nested_git=["node_modules/pkg"])
    parent_of_repos = os.path.join(tmp, "many")
    mkrepo(os.path.join(parent_of_repos, "r1"), tracked=["a"])
    mkrepo(os.path.join(parent_of_repos, "r2"), tracked=["b"])
    # disposable 名だが配下に実 repo を内包する dir（vendor）。どの repo にも属さない位置。
    vendor_with_repo = os.path.join(tmp, "vendor")
    mkrepo(os.path.join(vendor_with_repo, "realproj"), tracked=["x"])
    scratch = os.path.join(tmp, "scratch")
    os.makedirs(os.path.join(scratch, "stuff"), exist_ok=True)
    cachefix = os.path.join(tmp, "cachefix")
    mkrepo(os.path.join(cachefix, "tool"), tracked=["c"])
    datafix = os.path.join(tmp, "datafix")
    os.makedirs(os.path.join(datafix, "rawset"), exist_ok=True)
    dataA = os.path.join(tmp, "dataA")
    dataB = os.path.join(tmp, "dataB")
    os.makedirs(dataA, exist_ok=True)
    os.makedirs(dataB, exist_ok=True)
    DATA_ROOTS = DATA_ROOTS + [datafix, dataA, dataB]
    ALLOW_SUBTREE_ROOTS = ALLOW_SUBTREE_ROOTS + [cachefix]

    B, A = 2, 0
    cases = [
        (f"rm -rf {repo}", tmp, B, "repo root"),
        (f"rm -rf {repo}/rawdata", tmp, B, "gitignored data"),
        (f"rm -rf {repo}/node_modules", tmp, B, "PR#328: disposable WITH nested .git -> block"),
        (f"rm -rf {repo}/dist", tmp, A, "disposable WITHOUT nested .git inside repo -> allow"),
        (f"rm -rf {repo}/src", tmp, A, "tracked & clean"),
        (f"rm -rf {parent_of_repos}", tmp, B, "ancestor of repos"),
        (f"rm -rf {scratch}/stuff", tmp, A, "scratch"),
        ("rm -rf /", tmp, B, "root"),
        (f"rm -rf {HOME}", tmp, B, "home"),
        (f"rm -rf {HOME}/.cache", tmp, A, "disposable top-level"),
        ("sudo rm -rf /etc", tmp, B, "sudo system"),
        (f"cd {repo} && rm -rf rawdata", tmp, B, "cd+relative gitignored"),
        (f"cd {scratch} && rm -rf stuff", tmp, A, "cd+relative scratch"),
        (f'echo "rm -rf {repo}"', tmp, A, "FP: echo containing rm -rf"),
        (f"true && rm -f {scratch}/stuff/x", tmp, A, "FP: non-recursive rm"),
        (f"grep -r rm {repo}/src", tmp, A, "FP: grep rm"),
        (f"find {repo}/rawdata -delete", tmp, B, "find -delete gitignored"),
        (f"find {scratch} -name '*.tmp' -delete", tmp, A, "find -delete scratch"),
        ('rm -rf "$UNSETVAR/sub"', tmp, A, "$VAR/sub fail-open (EMPTY_VAR_ROOT narrowed)"),
        ('rm -rf "/tmp/$RUNID"', tmp, A, "mid-var fail-open"),
        (f"rm -rf {repo}/rawdata {scratch}/stuff", tmp, B, "mixed targets"),
        # round-1 回帰
        (f"echo start\nrm -rf {repo}", tmp, B, "newline"),
        (f"timeout 60 rm -rf {repo}", tmp, B, "timeout"),
        (f"nice -n 10 rm -rf {repo}", tmp, B, "nice -n N"),
        (f"setsid rm -rf {repo}", tmp, B, "setsid"),
        (f"ionice -c 3 rm -rf {repo}", tmp, B, "ionice -c N"),
        (f'bash -lc "rm -rf {repo}"', tmp, B, "bash -lc"),
        (f"env -i rm -rf {repo}", tmp, B, "env -i"),
        (f"env -u FOO rm -rf {repo}", tmp, B, "env -u NAME"),
        (f"find -L {repo}/rawdata -delete", tmp, B, "find -L global opt"),
        (f"echo {parent_of_repos} | xargs rm -rf", tmp, B, "echo|xargs"),
        (f"find {parent_of_repos} -maxdepth 1 -type d | xargs rm -rf", tmp, B, "find|xargs"),
        (f"pushd {repo} && rm -rf rawdata", tmp, B, "pushd"),
        (f'eval "rm -rf {repo}"', tmp, B, "eval"),
        (f"cd /nonexistent-xyz ; rm -rf rawdata", repo, B, "failed cd keeps cwd"),
        (f"rm -rf {cachefix}/tool", tmp, A, "allow-subtree git repo"),
        (f"rm -rf {datafix}/rawset", tmp, B, "data-root subtree"),
        (f"rm -rf {scratch}/stuff > {tmp}/log.txt", tmp, A, "redirection"),
        # round-2 回帰（bypass fixes）
        (f"rm -rf {{{dataA},{dataB}}}".replace("{{", "{").replace("}}", "}"), tmp, B, "brace expansion -> 2 data roots"),
        (f"flock /tmp/lock rm -rf {repo}", tmp, B, "flock launcher"),
        (f'flock -w 5 /tmp/lock -c "rm -rf {repo}"', tmp, B, "flock -c inline"),
        (f'su -c "rm -rf {repo}"', tmp, B, "su -c"),
        (f"runuser -u root -- rm -rf {repo}", tmp, B, "runuser -- "),
        (f"watch -n 1 rm -rf {repo}", tmp, B, "watch -n N"),
        (f"systemd-run rm -rf {repo}", tmp, B, "systemd-run"),
        # sc-1yz: shlex/bash 発散バイパス（cmdtokens 共有ゆえ rm でも BLOCK）
        (f"bash -c $'rm -rf {repo}'", tmp, B, "sc-1yz#1: ANSI-C $'...' bypass (rm)"),
        (f"bash <<<'rm -rf {repo}'", tmp, B, "sc-1yz#2: glued here-string bypass (rm)"),
        (f"bash --rcfile /dev/null -c 'rm -rf {repo}'", tmp, B, "sc-1yz#3: --rcfile value-opt bypass (rm)"),
        (f"bash -O extglob -c 'rm -rf {repo}'", tmp, B, "sc-1yz#3: -O value-opt bypass (rm)"),
        (f'r""m -rf {repo}', tmp, B, "obfuscation r\"\"m"),
        (f'fi""nd {repo}/rawdata -delete', tmp, B, "obfuscation fi\"\"nd"),
        (f"{{ rm -rf {repo}; }}", tmp, B, "brace-group"),
        (f"if true; then rm -rf {repo}; fi", tmp, B, "if/then"),
        (f"for x in 1; do rm -rf {repo}; done", tmp, B, "for/do literal"),
        (f"env --chdir={os.path.join(tmp)} rm -rf myrepo", tmp, B, "env --chdir relative"),
        (f"env -C {tmp} rm -rf myrepo", tmp, B, "env -C relative"),
        (f'find {datafix} -exec sh -c "rm -rf $0" {{}} \\;', tmp, B, "find -exec sh -c rm"),
        (f'bash <<< "rm -rf {repo}"', tmp, B, "here-string"),
        ("rm -rf /usr/local", tmp, B, "system prefix /usr/local"),
        ("sudo rm -rf /var/log", tmp, B, "system prefix /var/log"),
        ("rm -rf /var/tmp/scratch", tmp, A, "system scratch /var/tmp"),
        # round-2 FP fixes
        ("printf '%s\\n' /tmp/a /tmp/b | xargs rm -rf", tmp, A, "FP: printf format string not a path"),
        ("printf '%s\\0' /tmp/a | xargs -0 rm -rf", tmp, A, "FP: printf NUL format"),
        ("stat -c %n /tmp/x | xargs rm -rf", tmp, A, "FP: stat format operand"),
        (f"find {repo}/dist -type f | xargs rm -rf", tmp, A, "FP: xargs cleanup of disposable (no nested git)"),
        # round-3 回帰（launcher tail + 実バグ）
        (f"exec rm -rf {repo}", tmp, B, "exec launcher"),
        (f"builtin rm -rf {repo}", tmp, B, "builtin launcher"),
        (f"pkexec rm -rf {repo}", tmp, B, "pkexec launcher"),
        (f'su root -c "rm -rf {repo}"', tmp, B, "su USER -c"),
        (f'su -s /bin/bash -c "rm -rf {repo}"', tmp, B, "su -s SHELL -c"),
        (f'sg users -c "rm -rf {repo}"', tmp, B, "sg group -c"),
        (f'script -c "rm -rf {repo}" /dev/null', tmp, B, "script -c"),
        (f"find {parent_of_repos} -maxdepth 1 -type d | parallel rm -rf", tmp, B, "find|parallel (stdin)"),
        (f"parallel rm -rf ::: {repo}", tmp, B, "parallel ::: inline"),
        (f"taskset 0x1 rm -rf {repo}", tmp, B, "taskset hex mask"),
        (f"taskset -c 0 rm -rf {repo}", tmp, B, "taskset -c value-opt"),
        (f"ssh-agent rm -rf {repo}", tmp, B, "ssh-agent launcher"),
        (f"dbus-run-session rm -rf {repo}", tmp, B, "dbus-run-session launcher"),
        (f"mpirun -np 4 rm -rf {repo}", tmp, B, "mpirun -np N"),
        (f"srun -n 4 rm -rf {repo}", tmp, B, "srun -n N"),
        (f"fakeroot rm -rf {repo}", tmp, B, "fakeroot launcher"),
        # EMPTY_VAR_ROOT 狭小化: $VAR/subdir は通す、$VAR/ と $VAR/* は止める
        ('rm -rf "$TMPDIR/scratch"', tmp, A, "FP-FIX: $VAR/subdir fail-open (was over-blocked)"),
        ('rm -rf "$BUILD_DIR/out"', tmp, A, "FP-FIX: $VAR/out fail-open"),
        ('rm -rf "$X/"', tmp, B, "root-risk: $VAR/ (empty->/)"),
        ('rm -rf $UNSET/*', tmp, B, "root-risk: $VAR/* (empty->/*)"),
        # 既知変数 $HOME / $PWD の展開
        ('rm -rf "$HOME/.ssh"', tmp, B, "$HOME expanded -> protected top-level"),
        ("rm -rf $HOME", tmp, B, "$HOME expanded -> home itself"),
        (f'rm -rf "$PWD/stuff"', scratch, A, "$PWD expanded -> scratch (cwd=scratch)"),
        ('rm -rf "$HOMElab/x"', tmp, A, "unknown var $HOMElab -> fail-open (no false subst)"),
        # round-4 回帰: HOME subtree 保護（葉のみ→prefix 化）
        (f"rm -rf {HOME}/.ssh/id_rsa", tmp, B, "ROUND4: ~/.ssh/<child> (was leaf-only gap)"),
        (f"rm -rf {HOME}/.config/1Password", tmp, B, "ROUND4: ~/.config/1Password subtree"),
        (f"rm -rf {HOME}/.gnupg/secring", tmp, B, "ROUND4: ~/.gnupg subtree"),
        (f'cd {HOME}/.ssh && rm -rf known_hosts', tmp, B, "ROUND4: cd ~/.ssh then relative child"),
        (f"rm -rf {HOME}/.cache/uv/sdists", tmp, A, "no-regress: ~/.cache subtree still allow"),
        # PR #328 Opus レビュー修正の回帰
        (f"rm -rf {vendor_with_repo}", tmp, B, "PR#328[1]: disposable-named dir CONTAINING a repo -> block"),
        (f"rm -rf {HOME}/bin", tmp, B, "PR#328[10]: ~/bin (disposable name but HOME personal) -> block"),
        ("rm -rf /tmp/buildcache", tmp, A, "PR#328: non-HOME disposable scratch -> allow"),
        (f"rm -rf {repo}/rawdata$()", tmp, B, "PR#328[4]: empty $() appended -> still classified (no bypass)"),
        ("rm -rf /tmp/x$()", tmp, A, "PR#328[4]: empty $() on scratch -> allow"),
        (f"rm -rf /tmp/y$(echo)", tmp, A, "PR#328[4]: non-empty subst -> unresolvable fail-open"),
        ("rm -rf {" + ",".join([datafix] + ["/tmp/s%02d" % i for i in range(80)]) + "}", tmp, B,
         "PR#328[2]: >64-member brace, precious FIRST -> truncation->block"),
        (f"env -S 'rm -rf {repo}' ", tmp, B, "PR#328[11]: env -S inline command -> block"),
        ("env --chdir=myrepo rm -rf rawdata", tmp, B, "PR#328[3]: relative env --chdir joined to cwd"),
        # un-uog: brace bomb（多段ネスト）= queue 2^n 膨張を上限で阻止し高速に truncation->block
        ("rm -rf /tmp/scratch" + "{a,b}" * 20, tmp, B, "un-uog: 20-deep nested brace bomb -> truncated block"),
        ("find /tmp/d" + "{a,b}" * 20 + " -delete", tmp, B, "un-uog: brace bomb on find -delete path"),
        # 正常な複数メンバー brace は従来通り展開（回帰なし）
        (f"rm -rf {scratch}/" + "{a,b,c}", tmp, A, "un-uog: legit multi-member brace on scratch -> allow"),
        ("rm -rf /tmp/" + "a" * (MAX_SEG_LEN + 100), tmp, B, "un-uog: oversize single segment -> shlex DoS avoided, block"),
        ("rm -rf /tmp/x" + " ;true" * 200000, tmp, B, "un-uog: oversized whole command(>1MB) -> length cap block(parse 前)"),
        # un-uog F2: 上限超過でも削除動詞を含まない巨大コマンドは fail-OPEN（削除テーマ block の scope 違反/誤検出を回避）
        ("echo " + "a" * (MAX_SEG_LEN + 100) + " > /tmp/out.txt", tmp, A,
         "un-uog F2: oversize NON-deletion segment(echo blob) -> fail-open(not blocked)"),
        ("curl -d " + "x" * (MAX_SEG_LEN + 100) + " https://example.com", tmp, A,
         "un-uog F2: oversize curl -d payload(no rm/find) -> fail-open"),
        ("printf '%s' " + "z" * 1100000 + " > /tmp/blob", tmp, A,
         "un-uog F2: >1MB NON-deletion command(printf blob) -> fail-open(length cap not deletion-block)"),
        # 削除動詞を含む巨大入力は引き続き fail-CLOSED で block（保守判定の回帰防止）
        ("psql -c 'INSERT' && rm -rf /tmp/" + "a" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F2: oversize segment that DOES contain rm -> still block(fail-closed)"),
        # un-uog F1/F3: 上限超過経路でも難読化削除動詞(r""m / fi""nd / \rm)は block（_maybe_deletion が
        # shlex を模した正規化で空クォート対/バックスラッシュを畳んで検出。小サイズで shlex が block するのと
        # 同一契約を上限超過でも維持。pad は inert なコメント=実行されるのは本物の削除）。
        (f'r""m -rf {repo} #' + "x" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F1: oversize obfuscated rm (r\"\"m) seg -> still block(fail-closed)"),
        (f"r''m -rf {repo} #" + "x" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F1: oversize obfuscated rm (r''m) seg -> still block(fail-closed)"),
        (f'fi""nd {repo}/rawdata -exec r""m {{}} + #' + "x" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F1: oversize obfuscated find+rm (fi\"\"nd) seg -> still block(fail-closed)"),
        (f'r""m -rf {repo} #' + "x" * (MAX_CMD_LEN + 10), tmp, B,
         "un-uog F3: oversize WHOLE cmd(>1MB) obfuscated rm -> still block(fail-closed)"),
        # un-uog F1/F3 (中身入りクォート): r"m" / r'm' / "r"m / fi"n"d は shlex が rm/find に畳むため小サイズで
        # block されるが、上限超過経路でも同一契約を維持する(全クォート除去の正規化が中身入りクォートも畳む)。
        (f'r"m" -rf {repo} #' + "x" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F1: oversize content-quoted rm (r\"m\") seg -> still block(fail-closed)"),
        (f"r'm' -rf {repo} #" + "x" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F1: oversize content-quoted rm (r'm') seg -> still block(fail-closed)"),
        (f'"r"m -rf {repo} #' + "x" * (MAX_SEG_LEN + 100), tmp, B,
         'un-uog F1: oversize content-quoted rm ("r"m) seg -> still block(fail-closed)'),
        (f'fi"n"d {repo}/rawdata -exec r"m" {{}} + #' + "x" * (MAX_SEG_LEN + 100), tmp, B,
         "un-uog F1: oversize content-quoted find+rm (fi\"n\"d) seg -> still block(fail-closed)"),
        (f'r"m" -rf {repo} #' + "x" * (MAX_CMD_LEN + 10), tmp, B,
         "un-uog F3: oversize WHOLE cmd(>1MB) content-quoted rm (r\"m\") -> still block(fail-closed)"),
        # sc-x4h: --recursive の長オプション短縮形（GNU は曖昧でない接頭辞を受理）も再帰削除として block。
        (f"rm --r -f {repo}", tmp, B, "sc-x4h: rm --r (=--recursive abbrev) -> block"),
        (f"rm --re -f {repo}/rawdata", tmp, B, "sc-x4h: rm --re abbrev -> block"),
        (f"rm --rec -fd {repo}", tmp, B, "sc-x4h: rm --rec abbrev -> block"),
        (f"rm --recursiv -f {repo}", tmp, B, "sc-x4h: rm --recursiv abbrev -> block"),
        (f"rm --recursive -f {repo}", tmp, B, "sc-x4h: full --recursive still blocks"),
        (f"rm --recursivex -f {repo}", tmp, A, "sc-x4h: --recursivex は接頭辞でない -> 非recursive(allow)"),
    ]

    for cmd, cwd, expected, note in cases:
        try:
            code, _ = decide(cmd, cwd)
        except Exception as e:
            code = f"EXC:{e}"
        ok = (code == expected)
        if not ok:
            failures.append((note, cmd, expected, code))
        print(f"[{'ok' if ok else 'FAIL'}] exit={code} expect={expected}  {note}")

    # un-uog: 単一文の指数膨張(brace bomb)が hook timeout(10s)未満で確定することを実測表明。
    # 修正前は n=24 で 2^24 展開→数百秒ハング。MAX_BRACE_WORK 上限で <1ms に収まる。
    t0 = time.monotonic()
    decide("rm -rf /tmp/bomb" + "{a,b}" * 24, tmp)
    dt = time.monotonic() - t0
    print(f"[timing] 24-deep brace bomb decided in {dt * 1000:.1f}ms (must be < 1000ms)")
    if dt > 1.0:
        failures.append(("un-uog timing", "24-deep brace bomb", "<1s", f"{dt:.2f}s"))

    # un-uog: 予算超過は fail-CLOSED で block する（順序依存バイパス回帰防止）。実時間 3s を消費せず、
    # module global deadline を期限切れにして fail-closed 経路（文ループ・per-target）を直接検証する。
    global _ANALYZE_DEADLINE
    _ANALYZE_DEADLINE = time.monotonic() - 1.0  # 既に期限切れ
    f_stmt = analyze(f"true ; rm -rf {repo}/rawdata", tmp)  # 文ループで予算切れ → 保守的 block
    f_tgt = check_target(f"{repo}/rawdata", tmp)            # per-target 予算切れ → 保守的 block
    f_glob = check_target(f"{repo}/*", tmp)                 # 単一 glob 引数(展開後 per-path)も予算切れで block
    _ANALYZE_DEADLINE = None
    print(f"[budget] expired-deadline fail-closed: stmt={'block' if f_stmt else 'OPEN'} "
          f"target={'block' if f_tgt else 'OPEN'} glob={'block' if f_glob else 'OPEN'}")
    if not f_stmt:
        failures.append(("un-uog budget", "expired deadline (statement loop)", "block", "EMPTY=fail-OPEN"))
    if not f_tgt:
        failures.append(("un-uog budget", "expired deadline (check_target)", "block", "EMPTY=fail-OPEN"))
    if not f_glob:
        failures.append(("un-uog budget", "expired deadline (glob arg)", "block", "EMPTY=fail-OPEN"))

    shutil.rmtree(tmp, ignore_errors=True)
    print("")
    if failures:
        print(f"SELF-TEST FAILED: {len(failures)}/{len(cases)} cases")
        for note, cmd, exp, got in failures:
            print(f"  - {note}: expected {exp} got {got} :: {cmd!r}")
        return 1
    print(f"SELF-TEST PASSED: {len(cases)}/{len(cases)} cases")
    return 0


if __name__ == "__main__":
    sys.exit(main())

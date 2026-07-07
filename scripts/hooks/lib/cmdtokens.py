#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 共有コマンドトークナイザ（bd un-0gu）。
#
# 目的: bash コマンド文字列を「本物のコマンド呼び出し」のトークン列へ分解する SSOT パーサ。
#   substring/正規表現の全体一致が引き起こす誤検出（無関係コマンドの語の共起・クォート内データ・
#   コメント偽装）を、クォート認識の文分割 + shlex トークン化 + 透過ランチャ peel で構造的に排除する。
#   git-destructive-guard.py / rm-destructive-guard.py が共用する。
#
# パーサ部品（parse_statements/shlex_safe/strip_redirections/peel/_find_dash_c_inline/track_cd）と
#   透過ランチャ/制御構文の定数群は本 lib が SSOT。git-destructive-guard.py（un-0gu）に続き
#   rm-destructive-guard.py も本 lib を import する（un-x3o で統合・複製解消済）。高レベル駆動 iter_commands は
#   本 lib のみ（rm-guard は独自の analyze ループで同等処理＝部品は import で共有）。トークナイザを直す際は
#   本 lib だけを直せば 3 guard すべてへ反映される（旧来の「複製で検出が静かに乖離する保守ハザード」を解消）。
#
# 公開 API:
#   iter_commands(cmd, cwd=None, depth=0) -> generator of (core_words, eff_cwd)
#       クォート認識で文(&& || ; & | 改行 ( ))分割 → 各 segment を shlex トークン化 →
#       透過ランチャ(sudo/env/timeout/flock/xargs/parallel...)・シェル・su/runuser 等を peel →
#       bash -c / eval / su -c / here-string / env -S 等の inline コマンド文字列は再帰展開 →
#       リダイレクト除去後の「実コマンドのトークン列」を eff_cwd（cd / env --chdir 追跡済）と共に yield。
#       本物のコマンド先頭語のみを返すので、echo "git ..." や A && B の B の語は混入しない。
#   parse_statements / shlex_safe / peel / strip_redirections : 低レベル部品（テスト用にも公開）。
#   long_opt_abbrev(token, optname) : 長オプション短縮の over-block 述語（guard 共有・sc-x4h/sc-i13）。
#
# 例外は握り潰さない（呼び出し側 guard の main が try/except で fail-open する＝全 Bash を brick しない）。

import os
import re
import shlex

# --- 透過ランチャ / 制御構文 定義（rm-guard と同一） --------------------------
LAUNCHERS = {
    "sudo", "doas", "pkexec", "env", "nohup", "time", "timeout", "nice", "ionice",
    "stdbuf", "setsid", "taskset", "chrt", "command", "exec", "builtin", "nocache",
    "watch", "chronic", "unbuffer", "systemd-run", "systemd-inhibit", "busybox",
    "proxychains", "proxychains4", "firejail", "fakeroot", "cpulimit", "ts", "ccache",
    "catchsegv", "ssh-agent", "dbus-run-session", "xvfb-run", "rlwrap", "mpirun",
    "mpiexec", "srun",
}
LAUNCHER_VALUE_OPTS = {
    "sudo": {"-u", "-g", "-p", "-C", "-r", "-t", "-U", "-h"},
    "pkexec": {"-u", "--user"},
    "env": {"-u", "--unset", "-S", "--split-string"},
    "timeout": {"-s", "--signal", "-k", "--kill-after"},
    "nice": {"-n", "--adjustment"},
    "ionice": {"-c", "--class", "-n", "--classdata", "-p", "--pid"},
    "stdbuf": {"-i", "--input", "-o", "--output", "-e", "--error"},
    "taskset": {"-c", "--cpu-list", "-p"},
    "chrt": {"-T", "-P"},
    "exec": {"-a"},
    "cpulimit": {"-l", "--limit", "-p", "--pid", "-e", "--exe"},
    "watch": {"-n", "--interval", "-d", "--differences"},
    "systemd-run": {"-p", "--property", "--unit", "-u", "--on-active", "--on-calendar",
                     "-E", "--setenv", "-M", "--machine", "--uid", "--gid", "--slice"},
    "firejail": {"--profile", "--private", "--whitelist", "--read-only"},
    "xvfb-run": {"-n", "--server-num", "-s", "--server-args", "-e", "--error-file",
                  "-f", "--auth-file", "-w", "--wait"},
    "rlwrap": {"-a", "-b", "-f", "-H", "-l", "-m", "-P", "-q", "-s", "-t", "-z", "-C", "-D"},
    "mpirun": {"-np", "-n", "--np", "-host", "--host", "-hostfile", "--hostfile",
                "-machinefile", "--machinefile", "-x", "--map-by", "--bind-to"},
    "mpiexec": {"-np", "-n", "--np", "-host", "--host", "-hostfile", "--hostfile"},
    "srun": {"-n", "--ntasks", "-N", "--nodes", "-c", "--cpus-per-task", "-w",
              "--nodelist", "-p", "--partition", "-t", "--time", "-A", "--account"},
}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
# シェルが -c より前に取る「値取りオプション」（値トークンを飛ばして -c へ到達するため。sc-1yz root#3）。
# over-block 安全側: 未知オプは飛ばさず -c 探索を継続する（取りこぼしても従来挙動＝後退しない）。
SHELL_VALUE_OPTS = {
    "bash": {"--init-file", "--rcfile", "-O", "+O", "-o", "+o"},
    "zsh": {"--emulate", "-o", "+o"},
    "sh": {"-o", "+o"}, "dash": {"-o", "+o"}, "ksh": {"-o", "+o"},
}
# -c "文字列" で委譲するランチャ（全引数から -c を走査して inline 化）
CMD_STRING_LAUNCHERS = {"su", "runuser", "sg", "script"}
TASKSET_MASK_RE = re.compile(r"^(0x)?[0-9a-fA-F]+$")  # taskset の CPU マスク
KEYWORDS = {"{", "}", "!", "if", "then", "else", "elif", "fi", "for", "while",
            "until", "do", "done", "case", "esac", "select", "function", "in"}
DURATION_RE = re.compile(r"^\d+(\.\d+)?[smhd]?$")
VAR_ASSIGN_RE = re.compile(r"^\w+=")
VAR_OR_SUBST = re.compile(r"[$`]")


# --- パーサ部品 ---------------------------------------------------------------
def parse_statements(cmd):
    """クォート認識で statement(=pipeline) 群に分割。各 statement は segment 文字列のリスト。
    クォート外の && || ; & 改行 ( ) で statement 分割、| で pipeline segment 分割。
    （{ } や制御キーワードはトークン段で strip するのでここでは分割しない）。"""
    cmd = cmd.replace("\\\n", " ")
    statements, cur_pipe, cur = [], [], []
    quote = None
    i, n = 0, len(cmd)

    def flush_seg():
        s = "".join(cur).strip()
        if s:
            cur_pipe.append(s)
        cur.clear()

    def flush_stmt():
        flush_seg()
        if cur_pipe:
            statements.append(list(cur_pipe))
        cur_pipe.clear()

    while i < n:
        c = cmd[i]
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ('"', "'"):
            quote = c
            cur.append(c)
            i += 1
            continue
        if c == "\\" and i + 1 < n:
            cur.append(c)
            cur.append(cmd[i + 1])
            i += 2
            continue
        two = cmd[i:i + 2]
        if two in ("&&", "||", ";;"):
            flush_stmt()
            i += 2
            continue
        if c in (";", "\n", "&"):
            flush_stmt()
            i += 1
            continue
        if c == "|":
            flush_seg()
            i += 1
            continue
        if c in "()":
            flush_stmt()
            i += 1
            continue
        cur.append(c)
        i += 1
    flush_stmt()
    return statements


# ANSI-C / locale ドルクォート（$'...' / $"..."）の正規化（sc-1yz root#1）。shlex(posix) は $ を残し
# `$'git push -f'` を `$git push -f` と誤解釈する → basename が git/rm でなく guard 不発火。bash は $ を剥がし
# ANSI-C エスケープ(\x67/\147 等)を復号して実行するため、shlex 前にここで復号して token を正規化する。
_DOLLAR_SQ = re.compile(r"\$'((?:[^'\\]|\\.)*)'")
_DOLLAR_DQ = re.compile(r'\$"((?:[^"\\]|\\.)*)"')
_ANSI_C_SIMPLE = {"a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f",
                  "n": "\n", "r": "\r", "t": "\t", "v": "\v", "\\": "\\",
                  "'": "'", '"': '"', "?": "?"}


def _decode_ansi_c(s):
    """bash $'...' の ANSI-C エスケープを best-effort 復号（guard 脱難読化用・安全側）。"""
    out, i, n = [], 0, len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            nxt = s[i + 1]
            if nxt in _ANSI_C_SIMPLE:
                out.append(_ANSI_C_SIMPLE[nxt]); i += 2; continue
            if nxt == "x":
                m = re.match(r"[0-9a-fA-F]{1,2}", s[i + 2:i + 4])
                if m:
                    out.append(chr(int(m.group(), 16))); i += 2 + len(m.group()); continue
            if nxt in "01234567":
                m = re.match(r"[0-7]{1,3}", s[i + 1:i + 4])
                out.append(chr(int(m.group(), 8) & 0xFF)); i += 1 + len(m.group()); continue
            if nxt in "uU":
                width = 4 if nxt == "u" else 8
                m = re.match(r"[0-9a-fA-F]{1,%d}" % width, s[i + 2:i + 2 + width])
                if m:
                    out.append(chr(int(m.group(), 16))); i += 2 + len(m.group()); continue
            out.append(nxt); i += 2; continue  # 未知エスケープ: バックスラッシュを落とし文字を残す（安全側）
        out.append(c); i += 1
    return "".join(out)


def _normalize_dollar_quotes(seg):
    """セグメント中の $'...'(ANSI-C) / $"..."(locale) を復号し shlex 安全な単一トークンへ置換。"""
    if "$'" not in seg and '$"' not in seg:
        return seg
    seg = _DOLLAR_SQ.sub(lambda m: shlex.quote(_decode_ansi_c(m.group(1))), seg)
    seg = _DOLLAR_DQ.sub(lambda m: shlex.quote(m.group(1)), seg)
    return seg


def shlex_safe(seg):
    try:
        return shlex.split(_normalize_dollar_quotes(seg), posix=True)
    except ValueError:
        return None


REDIR_BARE = re.compile(r"^(\d*>>?|\d*<|<<|<<<|>\||&>>?)$")
REDIR_GLUED = re.compile(r"^(\d*[<>]|&>)")


def strip_redirections(words):
    out, i = [], 0
    while i < len(words):
        w = words[i]
        if REDIR_BARE.match(w):
            i += 2
            continue
        if REDIR_GLUED.match(w):
            i += 1
            continue
        out.append(w)
        i += 1
    return out


# --- 長オプション短縮の正規化（guard 共有述語・sc-x4h/sc-i13） -------------------
def long_opt_abbrev(token, optname):
    """token が長オプション --<optname> に該当するか（GNU/getopt の曖昧でない接頭辞短縮を含む）。
    safe-side over-block: token が '--' + optname の【非空接頭辞】なら True。曖昧な接頭辞（複数
    オプションに一致）は実ツール自身が reject するため、実害ある誤検出はゼロ（証明: optname の接頭辞 p が
    別の安全オプション S に曖昧でなく解決されるなら optname は p で始まれない=矛盾）。rm-guard / git-guard が
    --recursive / --hard / --force / --delete / --no-verify 等を完全一致でしか見ず短縮形（rm --r /
    git reset --har 等）に素通しされていた穴を SSOT 述語で一掃する（un-0gu F13 の「複製で検出が乖離する」
    保守ハザードを避け、両 guard が同一正規化を共用する）。'--'（オプション終端）単独や optname より長い
    文字列（例 --force-with-lease vs force）は False。末尾 '=value' は剥がして判定する。"""
    if not token.startswith("--") or token == "--":
        return False
    name = token[2:].split("=", 1)[0]
    return bool(name) and optname.startswith(name)


def _find_dash_c_inline(words, start, shell=None):
    """words[start:] から -c / -lc 等のクラスタ -c を探し、その次トークン(inline)を返す。
    shell が値取りオプション(--init-file/--rcfile/-O 等)を持つ場合は値トークンを飛ばして -c へ到達する
    （sc-1yz root#3: `bash --init-file /dev/null -c '...'` / `bash -O extglob -c '...'` のバイパス対策）。"""
    vopts = SHELL_VALUE_OPTS.get(shell, set())
    j = start
    while j < len(words):
        t = words[j]
        if t == "-c" or (t.startswith("-") and not t.startswith("--") and "c" in t):
            return words[j + 1] if j + 1 < len(words) else None, True
        if t.startswith("-"):
            flag = t.split("=", 1)[0]
            if flag in vopts and "=" not in t:
                j += 2  # 値取りオプション: 値トークンを飛ばして -c 探索継続
            else:
                j += 1
            continue
        break
    return None, False


def peel(words, env_out=None):
    """透過ランチャ / VAR= / 制御キーワードを剥がして実コマンドへ。
    返り値: (core_words, inline_cmd_or_None, is_xargs, cwd_override)。
    env_out に list を渡すと、剥がしたコマンド前置の VAR=VALUE 代入（＝実コマンドの環境になる代入）を
    そこへ順に append する（後方互換の out-param・既定 None で従来動作。sc-dn3: env prefix 経由の config
    注入検出用。peel 自身の skip 規則で拾うため `X=v git` も `env X=v git` も同一に捕捉できる）。"""
    i = 0
    cwd_override = None
    # 先頭の制御キーワード（{ } if then else for while do ... ）を除去
    while i < len(words) and words[i] in KEYWORDS:
        i += 1
    while i < len(words):
        w = words[i]
        b = os.path.basename(w)
        if VAR_ASSIGN_RE.match(w) and not w.startswith("/"):
            if env_out is not None:
                env_out.append(w)  # コマンド前置の環境代入（sc-dn3: env prefix 経由 config 注入検出）
            i += 1
            continue
        if i < len(words) and words[i] in KEYWORDS:
            i += 1
            continue
        if b in SHELLS:
            inline, found = _find_dash_c_inline(words, i + 1, b)
            if found:
                return [], inline, False, cwd_override
            # here-string: bash <<< "rm ..."（独立 <<<）/ bash <<<"rm ..."（glued・sc-1yz root#2）
            for k in range(i + 1, len(words)):
                if words[k] == "<<<" and k + 1 < len(words):
                    return [], words[k + 1], False, cwd_override
                if words[k].startswith("<<<") and len(words[k]) > 3:
                    return [], words[k][3:], False, cwd_override
            return words[i:], None, False, cwd_override
        if b in CMD_STRING_LAUNCHERS:
            # su/runuser/sg/script: 全引数から -c を走査して inline 化（user 名・-s 値op を貫通）
            for k in range(i + 1, len(words)):
                if words[k] in ("-c", "--command"):
                    return [], (words[k + 1] if k + 1 < len(words) else None), False, cwd_override
            # runuser -u USER -- rm ... : `--` の後がコマンド本体
            if "--" in words[i + 1:]:
                i = words.index("--", i + 1) + 1
                continue
            return words[i:], None, False, cwd_override
        if b == "eval":
            return [], " ".join(words[i + 1:]), False, cwd_override
        if b == "parallel":
            j = i + 1
            vopts = {"-j", "--jobs", "-n", "-N", "-L", "-I", "--replace", "-d",
                     "--delimiter", "-P", "--max-procs", "-a", "--arg-file", "--colsep", "-C"}
            while j < len(words) and words[j].startswith("-"):
                flag = words[j].split("=", 1)[0]
                if flag in vopts and "=" not in words[j]:
                    j += 2
                else:
                    j += 1
            return words[j:], None, True, cwd_override
        if b == "xargs":
            j = i + 1
            vopts = {"-I", "-i", "-n", "--max-args", "-P", "--max-procs",
                     "-L", "-s", "--max-chars", "-d", "--delimiter", "-E", "--eof", "-a", "--arg-file"}
            while j < len(words) and words[j].startswith("-"):
                flag = words[j].split("=", 1)[0]
                if flag in vopts and "=" not in words[j]:
                    j += 2
                else:
                    j += 1
            return words[j:], None, True, cwd_override
        if b == "flock":
            j = i + 1
            while j < len(words) and words[j].startswith("-"):
                flag = words[j]
                if flag in ("-c", "--command"):
                    return [], (words[j + 1] if j + 1 < len(words) else None), False, cwd_override
                if flag in ("-w", "--timeout", "-E", "--conflict-exit-code"):
                    j += 2
                else:
                    j += 1
            if j < len(words) and not words[j].startswith("-"):
                j += 1  # lockfile/fd オペランド
            if j < len(words) and words[j] in ("-c", "--command"):
                return [], (words[j + 1] if j + 1 < len(words) else None), False, cwd_override
            i = j
            continue
        if b in LAUNCHERS:
            vopts = LAUNCHER_VALUE_OPTS.get(b, set())
            i += 1
            while i < len(words):
                t = words[i]
                if t.startswith("-"):
                    if b == "env" and t in ("-S", "--split-string"):
                        # env -S "rm -rf X": 値はシェル再分割されるコマンド文字列 → 再帰解析
                        return [], (words[i + 1] if i + 1 < len(words) else None), False, cwd_override
                    if b == "env" and (t.startswith("--split-string=") or (t.startswith("-S") and len(t) > 2)):
                        return [], (t.split("=", 1)[1] if "=" in t else t[2:]), False, cwd_override
                    if b == "env" and (t == "--chdir" or t == "-C"):
                        if i + 1 < len(words):
                            cwd_override = words[i + 1]
                        i += 2
                        continue
                    if t.startswith("--chdir=") and b == "env":
                        cwd_override = t.split("=", 1)[1]
                        i += 1
                        continue
                    flag = t.split("=", 1)[0]
                    if flag in vopts and "=" not in t:
                        i += 2
                    else:
                        i += 1
                    continue
                if VAR_ASSIGN_RE.match(t) and not t.startswith("/"):
                    if env_out is not None:
                        env_out.append(t)  # launcher(env/sudo…)後続の環境代入（sc-dn3）
                    i += 1
                    continue
                if DURATION_RE.match(t):
                    i += 1
                    continue
                break
            if b == "taskset" and i < len(words) and TASKSET_MASK_RE.match(words[i]) and i + 1 < len(words):
                i += 1  # CPU マスクオペランド（0x1/ff/3 等）
            continue
        break
    return words[i:], None, False, cwd_override


def track_cd(words, eff):
    """`cd DIR` / `pushd DIR`（リテラルパス）で eff['cwd'] を更新。変数/置換を含む遷移は無視。"""
    if not words:
        return
    if os.path.basename(words[0]) in ("cd", "pushd") and len(words) >= 2 and not words[1].startswith("-"):
        tgt = words[1]
        if VAR_OR_SUBST.search(tgt):
            return
        cand = os.path.expanduser(tgt)
        final = cand if os.path.isabs(cand) else os.path.normpath(os.path.join(eff["cwd"], cand))
        if os.path.isdir(final):
            eff["cwd"] = final


def iter_commands(cmd, cwd=None, depth=0, with_env=False, _parent_env=()):
    """cmd 中の「本物のコマンド呼び出し」を (core_words, eff_cwd) で逐次 yield する。

    - クォート認識で文/パイプライン分割 → shlex トークン化 → 透過ランチャ/シェル peel。
    - bash -c / eval / su -c / here-string / env -S 等の inline コマンド文字列は再帰展開。
    - `cd DIR &&` / `env --chdir` を追跡し、各コマンドの実効 cwd を返す（anchor 判定等で使用）。
    - shlex 解析不能 segment（壊れたクォート等）は skip（= その segment は fail-open。rm-guard と同方針）。
    - 空コマンド置換 $()/${}/`` は難読化バイパス対策で除去してから解析。

    with_env=True のとき yield は (core_words, eff_cwd, env_assigns) の 3-tuple になる（sc-dn3・後方互換
    オプション。既定 False は従来の 2-tuple を維持＝rm-guard 等の既存呼出しは無改変）。env_assigns は当該
    コマンドが実際に受け取る "K=V" 環境代入 list（GIT_CONFIG_KEY 経由の config 注入を guard が検出するため）。
    シェルの VAR=値 前置代入はそのコマンドの環境になり子プロセス（`bash -c '...'` 等）へ継承されるため、
    inline 展開へも env prefix を伝播させる（`GIT_CONFIG_KEY_0=... sh -c 'git commit'` の hooksPath 注入が
    inline 側へ素通る fail-open を塞ぐ）。_parent_env は内部再帰用（呼出側は渡さない）。
    """
    if cwd is None:
        cwd = os.getcwd()
    if depth > 6:
        return
    cmd = re.sub(r'\$\(\s*\)|\$\{\s*\}|``', '', cmd)
    eff = {"cwd": cwd}
    for statement in parse_statements(cmd):
        seg_words = []
        for seg in statement:
            w = shlex_safe(seg)
            if w:
                seg_words.append(w)
        if not seg_words:
            continue
        track_cd(seg_words[0], eff)
        for words in seg_words:
            env_out = [] if with_env else None
            core, inline, _is_xargs, cwd_ovr = peel(words, env_out)
            if cwd_ovr:
                seg_cwd = cwd_ovr if os.path.isabs(cwd_ovr) else os.path.normpath(os.path.join(eff["cwd"], cwd_ovr))
            else:
                seg_cwd = eff["cwd"]
            # この segment の実効 env = 親から継承した prefix + 当該 segment 前置の代入（sc-dn3）。
            seg_env = list(_parent_env) + env_out if with_env else ()
            if inline is not None:
                # inline（bash -c 等）は前置 env を継承する子プロセス → seg_env を伝播（sc-dn3: ラッパ 1 枚での
                # env bypass を塞ぐ）。
                yield from iter_commands(inline, seg_cwd, depth + 1,
                                         with_env=with_env, _parent_env=seg_env)
                continue
            core = strip_redirections(core)
            if not core:
                continue
            if with_env:
                yield core, seg_cwd, seg_env
            else:
                yield core, seg_cwd


# --- 軽量サニティ（python3 cmdtokens.py --self-test） --------------------------
def _self_test():
    def cmds(c, cwd="/x"):
        return [tuple(core) for core, _ in iter_commands(c, cwd)]

    cases = [
        # (cmd, expected first-token of each yielded command)
        ("git push -f", [["git", "push", "-f"]]),
        ("bd dolt push && rm -f x", [["bd", "dolt", "push"], ["rm", "-f", "x"]]),
        ('echo "git checkout x"', [["echo", "git checkout x"]]),
        ('gh pr create --body "tmux -f stuff"', [["gh", "pr", "create", "--body", "tmux -f stuff"]]),
        ("sudo git push --force", [["git", "push", "--force"]]),
        ('bash -c "git push -f"', [["git", "push", "-f"]]),
        ("find . | xargs git checkout", [["find", "."], ["git", "checkout"]]),
        # sc-1yz: ドルクォート復号 / glued here-string / 値取りオプ跨ぎ -c が inline を正しく抽出・正規化する
        ("bash -c $'git push -f'", [["git", "push", "-f"]]),
        (r"bash -c $'\x67it push -f'", [["git", "push", "-f"]]),       # ANSI-C \x67=g 復号
        ("bash <<<'git push -f'", [["git", "push", "-f"]]),            # glued here-string
        ("bash --init-file /dev/null -c 'git push -f'", [["git", "push", "-f"]]),
        ("bash -O extglob -c 'git push -f'", [["git", "push", "-f"]]),
    ]
    fails = []
    for c, expect in cases:
        got = cmds(c)
        if got != [tuple(e) for e in expect]:
            fails.append(f"{c!r}: got {got} expected {expect}")

    # long_opt_abbrev（over-block 述語）の単体検証（sc-x4h/sc-i13）
    abbr_cases = [
        ("--recursive", "recursive", True), ("--r", "recursive", True),
        ("--rec", "recursive", True), ("--recursiv", "recursive", True),
        ("--hard", "hard", True), ("--har", "hard", True), ("--h", "hard", True),
        ("--force", "force", True), ("--forc", "force", True),
        ("--force-with-lease", "force", False),  # lease は force の接頭辞でない=温存
        ("--", "recursive", False), ("-r", "recursive", False),  # 終端/短フラグは対象外
        ("--hardcore", "hard", False), ("--delete", "force", False),
        ("--no-verify", "no-verify", True), ("--no-veri", "no-verify", True),
        ("--no-verb", "no-verify", False),  # verbose 側は no-verify の接頭辞でない=温存
        ("--detach", "detach", True), ("--det", "detach", True), ("--orph", "orphan", True),
    ]
    for tok, name, exp in abbr_cases:
        if long_opt_abbrev(tok, name) != exp:
            fails.append(f"long_opt_abbrev({tok!r},{name!r}): got {long_opt_abbrev(tok, name)} expected {exp}")

    # sc-dn3: with_env=True の env prefix 収集（実コマンド名より前の VAR= のみ・launcher 貫通・
    # クォート内/引数側の VAR= 風は拾わない）を検証。
    def cmds_env(c, cwd="/x"):
        return [(tuple(core), env) for core, _cwd, env in iter_commands(c, cwd, with_env=True)]

    env_cases = [
        ("GIT_CONFIG_KEY_0=core.hooksPath git commit",
         [(("git", "commit"), ["GIT_CONFIG_KEY_0=core.hooksPath"])]),
        ("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null git commit",
         [(("git", "commit"), ["GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=core.hooksPath", "GIT_CONFIG_VALUE_0=/dev/null"])]),
        ("env GIT_CONFIG_KEY_0=x git commit",
         [(("git", "commit"), ["GIT_CONFIG_KEY_0=x"])]),       # env launcher 貫通（"env" は VAR= でない）
        ("FOO=bar rm -rf x", [(("rm", "-rf", "x"), ["FOO=bar"])]),
        ("git commit -m 'GIT_CONFIG_KEY_0=x'",
         [(("git", "commit", "-m", "GIT_CONFIG_KEY_0=x"), [])]),  # 引数側 VAR= 風は env でない
        ("git status", [(("git", "status"), [])]),
        # sc-dn3: env prefix が inline（bash/sh -c）へ継承される（子プロセスが前置 env を継承）→ 伝播を検証。
        ("GIT_CONFIG_KEY_0=core.hooksPath sh -c 'git commit'",
         [(("git", "commit"), ["GIT_CONFIG_KEY_0=core.hooksPath"])]),
        ("GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null bash -c 'git commit'",
         [(("git", "commit"), ["GIT_CONFIG_COUNT=1", "GIT_CONFIG_KEY_0=core.hooksPath", "GIT_CONFIG_VALUE_0=/dev/null"])]),
        ("env GIT_CONFIG_KEY_0=x sudo bash -c 'git commit'",   # launcher 貫通 + inline 伝播の合成
         [(("git", "commit"), ["GIT_CONFIG_KEY_0=x"])]),
        ("X=1 bash -c 'git a; git b'",                          # inline 内の全コマンドが env を継承
         [(("git", "a"), ["X=1"]), (("git", "b"), ["X=1"])]),
        ("sh -c 'git status'", [(("git", "status"), [])]),      # env 無しラッパは空（over-collect しない）
    ]
    for c, expect in env_cases:
        got = cmds_env(c)
        want = [(tuple(t), e) for t, e in expect]
        if got != want:
            fails.append(f"env {c!r}: got {got} expected {want}")

    if fails:
        for f in fails:
            print("FAIL:", f)
        print(f"cmdtokens self-test: {len(fails)} FAILED")
        return 1
    print(f"cmdtokens self-test: {len(cases)}/{len(cases)} OK")
    return 0


if __name__ == "__main__":
    import sys
    if "--self-test" in sys.argv:
        sys.exit(_self_test())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook（B1-L3・defense-in-depth）: orchestrator session が **非 bd の Bash file 変異**
#   （sed -i / tee / cp|mv|install|ln の宛先 / dd of= / truncate / touch / `>`|`>>`|`2>`|`&>` redirect 等）で
#   **foreign 台帳配下の file** を変異させることを best-effort で deny する（exit 2）。
#
# 層の位置（top-spec §4 / research B1・staged rollout）:
#   - L1 = read-only hydrate（`bd repo sync` で foreign を読むだけ・そもそも write 経路を作らない）。
#   - L2 = file-write-guard.py（orch-w88）= PreToolUse[Edit|Write|MultiEdit|NotebookEdit] の構造化編集ツール経由 write。
#   - L3 = 本 guard（orch-2o6）= L2 の射程外＝**Bash 経由の file 変異**。主モートは L1/L2 で、本層は
#          defense-in-depth。よって「全 Bash を完璧に止める」ことは目標にしない（J6 と同型の『解決不能 modality』
#          問題＝変数/コマンド置換で静的に宛先が決まらない write は **under-block 許容 + loud log**）。
#
# 由来: orch-2o6（親 orch-4r3 / orch-w88(L2) 後続）。bd-write-guard.py（bd write）/ file-write-guard.py
#   （Edit/Write）と同じ write-isolation 不変条件「orchestrator は foreign を write しない」を、bd でも
#   構造化編集ツールでもない **plain Bash の file 変異経路**へ拡張する（top-spec §4・SSOT=research B1 修正(b)）。
#
# 脅威モデル: orchestrator session（連結 substrate で foreign repo を hydrate して read する）が、hydrate 先
#   や worktree 経由で foreign repo の file を **Bash で**直接書く（`sed -i ... /foreign/x` / `echo y > /foreign/x` /
#   `cp a /foreign/x` …）owner 2人違反を、静的に解決できる範囲で機械的に止める。
#
# session self-scope（bd-write-guard.py / file-write-guard.py と同一機構・共有 lib orch_session が SSOT）:
#   plugin として global enable すると PreToolUse[Bash] は**全セッション**で発火する。非 orchestrator session
#   （scribe / cc-session …）で発火しても他 project の Bash を一切壊さないよう、guard 冒頭で
#   _is_orch_session(session_cwd) を見て非該当なら一切判定せず exit 0（no-op）で抜ける。判定は session cwd
#   （hook payload top-level cwd）基準で、書込先 path が orch 配下かとは独立。
#
# 方式（2 パス。tokenizer は publish 済 cmdtokens plugin の canonical lib を consume＝下記 preamble）:
#   Pass A（operand 系変異）: cmdtokens.iter_commands でコマンド列を取り（透過ランチャ sudo/env/timeout/flock…
#     を peel・bash -c / eval 等の inline を再帰展開・`cd`/`env --chdir` で実効 cwd を追跡）、本物のコマンド
#     basename が file 変異コマンドなら **宛先 operand のみ**を抽出し実効 cwd で台帳判定する。read operand
#     （cp の src・dd の if=・sed の script 文字列）は判定対象にしない＝foreign を **read する**のは許可だから。
#   Pass B（redirection）: iter_commands は `strip_redirections` で `>`/`file` 対を core から落とすため
#     operand 経路では redirect の宛先を観測できない。よって parse_statements + shlex_safe + track_cd で
#     セグメントを **stripせずに**走査し、write 系 redirect（`>` `>>` `n>` `n>>` `>|` `&>` `&>>` `<>`）の
#     宛先のみを実効 cwd で台帳判定する（`<` `<<` `<<<` の read redirect は対象外）。さらに Pass A と同型に
#     peel() で透過ランチャ（sudo/env/flock…）を剥がし `bash -c`/`eval`/`sh -c` の inline 文字列は
#     _scan_redirections を再帰させる＝`sudo sh -c 'echo x > /foreign'` のような **inline 内 redirect** も
#     検査される（finding#1 修正・以前は inline redirect が silent fail-open だった）。
#
# 判定（file-write-guard.py と同一の三値・gate-ratified 誤検出境界）:
#   1. _is_orch_session(session_cwd) が False → no-op（exit 0）。
#   2. 宛先 token を実効 cwd 基準で絶対化（~ 展開）し realpath で symlink 解決 → 親から walk-up で
#      .beads/metadata.json dolt_database を解決。
#   3. dolt_database == SELF_PREFIX（orch）            → allow（自台帳＝scriptorium 自リポ配下の正当変異）。
#      dolt_database is None（台帳外＝/tmp・/dev/null・scratchpad・~/.claude/projects〔実 dir〕等）→ allow。
#      dolt_database != SELF_PREFIX（foreign 台帳配下＝scribe/cc-session/folio 等 if .beads）→ deny(exit2)。
#   ★~/.claude の扱い（file-write-guard.py gate F1-a と整合）: `echo x > ~/.claude/CLAUDE.md`（symlink 実体は
#     foreign project 所有）は realpath 後に foreign 判定で deny される＝編集は所有 project の admin 経由。
#   ★宛先 token に変数/コマンド置換（`$` / backtick）があると静的解決不能 → **under-block（allow）+ loud log**
#     （L3 は defense-in-depth・主モートは L1/L2 ゆえ取りこぼしを許容し、その旨を stderr へ loud に残す）。
#
# JUDGMENT CALLS（contract から一意に決まらず deduce・review/admin 監査対象。bd-write-guard の J* と同精神）:
#   K1 file 変異コマンドの宛先抽出 = コマンド別の 3 パターンに正規化する:
#       - DEST_LAST  (cp/mv/install/ln): 最後の positional が宛先。`-t DIR`/`--target-directory[=DIR]` 指定時は
#                    その DIR。先行 src は read ゆえ判定しない（foreign を read→自台帳へ copy するのは許可）。
#       - ALL_POS    (tee/truncate/touch): 全 positional が宛先（複数 file をまとめて変異する）。
#       - DD         (dd): `of=PATH` のみ宛先（`if=` は read）。
#       - sed        : `-i`/`--in-place` がある時のみ変異。宛先=positional 全部（script 文字列も含むが、相対
#                      文字列ゆえ実効 cwd 配下＝orch/None に解決され allow に落ちる＝無害。foreign script
#                      文字列は実在しないため false-deny を生まない）。
#   K2 redirect 宛先は write 系演算子の直後 token（bare）または glued path（`>file`）のみ。read redirect
#       （`<` `<<` `<<<`）は対象外＝foreign を read するのは許可。注: parse_statements は `&` を文区切り
#       にするため `cmd &> f` は `cmd` と `> f` に分割され、redirect は bare `>` として後段で拾われる
#       （宛先 f は確実に検査される）。
#   K3 quoting / tokenizer 限界:
#       (a) ★redirect 演算子のクォート認識（admin gate BLOCKER 修正済）: Pass B の redirect 判定はかつて
#           `shlex_safe`（posix=True）でクォートを落とし、`grep '>' /foreign/x`（`'>'`=クォート済みデータ・純 read）
#           を裸 `>` redirect と誤認して **foreign read を誤 deny** していた（orchestrator の主要動作を brick）。
#           現在は posix=False トークン（クォート保持）で判定し、`"'>'"` は bare 演算子正規表現にマッチしない
#           ＝data として skip する（_qa_tokens / _redirect_targets）。本物の裸 `> /foreign/x` は従来どおり deny。
#       (b) heredoc 本文の over-block（既知・据置・別 root cause）: parse_statements は heredoc を解さず
#           `<<EOF … EOF` の本文行を独立 statement として走査するため、**自台帳宛 heredoc でも本文に絶対
#           foreign パスの redirect 様文字列があると false-deny** になる（`cat > /orch/out <<EOF` … 本文
#           `… > /foreign/x` … `EOF`）。これは (a) のクォート認識修正では解消しない（heredoc 本文の `> /foreign/x` は
#           クォート無しの裸演算子に見えるため）。直すには `<<DELIM`/`<<-`/`<<"DELIM"` を検出し delimiter 行まで
#           本文を redirect 走査から除外する heredoc-aware プリパスが要るが、quoted delimiter / `<<-` / 複数
#           heredoc の edge で脆く、best-effort 層では over-block（安全側）を許容し doc 化する（→ admin 起票候補）。
#   K4 under-block 許容範囲: L3 は best-effort ゆえ以下は取りこぼす（『解決不能 modality を完璧に止めない』=
#       J6 と同精神・主モート L1/L2 が被覆）。**loud log が出るのは (a)(b) で、(c) は silent**:
#       (a) 変数/コマンド置換（`$`/backtick）を含む宛先 → _underblock_note で **loud log**（_classify_path が
#           code=None を返す経路）。これが contract の「静的解決不能は under-block 許容だが loud log」の核。
#       (b) ★parse_statements が壊す construct（admin gate Medium/Low 修正済・silent→loud）: process
#           substitution `>(…)`/`<(…)`（`tee >(cat) /foreign` 等・`(` `)` 分割で宛先が別 fragment へ leak）と
#           `>&PATH`（非数値 word への combined-fd-to-file redirect・`&` 分割で宛先が次 statement へ leak）は
#           _risky_construct_notes で **loud log**（heuristic・deny はしない＝クォート内データの誤検出を避ける）。
#           fd-dup `>&2`/`>&-` は数値/`-` ゆえ対象外（file write でない）。
#       (c) silent under-block（loud log なし・検出器に乗らない）: 非 CORE 変異コマンド（`rm`/`gzip`/`chmod`/
#           `mkdir`/`rsync`/`tar -C` 等・K5）、heredoc 本文経由の宛先、その他 parse_statements が壊す稀分割形。
#       ★finding#1/#2(F1/F2) 修正済（以前は silent fail-open だった経路を deny 化）: (1) `>|`/`2>|`（force-clobber。
#       parse_statements が `|` で分割し宛先が次 segment へ spill）を _ends_with_dangling_write_redirect で
#       次 segment 先頭へ継承して検査する。(2) Pass B も Pass A と同型に peel() で透過ランチャを剥がし
#       `bash -c`/`eval`/`sh -c` inline へ _scan_redirections を再帰させる＝`sudo sh -c 'echo x > /foreign'`
#       等の inline redirect も検査される（inline があっても外側 redirect も検査＝continue しない）。
#   K5 変異コマンド集合は保守的・拡張可能（CORE = contract 明記の sed -i/tee/redirect/cp|mv/dd of=、+ 明白な
#       追加 install/ln/truncate/touch）。未知の変異コマンドは under-block（loud log なし＝検出器に乗らない）。
#
# 失敗時方針: 入力解析・guard 内部・lib ロードのいずれの例外でも fail-open（exit 0）＝guard が全 Bash を
#   brick しない（bd-write-guard.py / file-write-guard.py と同方針・hooks.json の二重 fail-safe 指示に従う）。
# 検証: `python3 bash-file-write-guard.py --self-test`（hermetic temp ledger fixture・subprocess 非依存。
#   mutation testing で deny ロジックの非vacuous を証明する）。

import sys
import os
import re
import json
import shlex

# cmdtokens consume preamble（bd-write-guard.py と同一・logic ゼロの薄い解決層）:
#   canonical cmdtokens（standalone cmdtokens plugin の単一 SSOT）を sys.path 解決して import する。
#   CMDTOKENS_LIB が未設定/空/非絶対なら plugin 標準配置へ fallback。env 値・default とも expanduser する。
#   取り込む公開 API は Pass A の iter_commands と Pass B の parse_statements / shlex_safe / track_cd /
#   peel のみ（peel = Pass B でも透過ランチャを剥がし bash -c/eval/sh -c inline へ再帰するため・finding#1 修正）。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")
_cmdtokens_lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
if not os.path.isabs(_cmdtokens_lib):  # 非絶対 → cwd 相対 poison を避け既定へ
    _cmdtokens_lib = _CMDTOKENS_DEFAULT_LIB
_cmdtokens_load_error = None
try:
    sys.path.insert(0, _cmdtokens_lib)
    from cmdtokens import iter_commands, parse_statements, shlex_safe, track_cd, peel
except Exception as e:  # lib ロード不能 → fail-open（guard 無効化を loud に通知）
    iter_commands = parse_statements = shlex_safe = track_cd = peel = None
    _cmdtokens_load_error = e
    if "--self-test" not in sys.argv:
        sys.stderr.write(f"[bash-file-guard] cannot load cmdtokens lib, failing open: {e}\n")
        sys.exit(0)

# 自台帳 prefix / session・台帳 判定は共有 lib（scripts/hooks/lib/orch_session.py・orch-w88 抽出）を SSOT
#   とする。bd-write-guard / file-write-guard と同一の SELF_PREFIX / walk-up 台帳解決 / orch session 判定を
#   共有する。本 import は logic ゼロの薄い解決層: 同梱 lib/ を sys.path 解決して import するだけ。
_orch_session_load_error = None
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
    from orch_session import SELF_PREFIX, SELF_PFX, _resolve_ledger, _LEDGER_UNREADABLE, _is_orch_session
except Exception as e:  # 同梱 lib ロード不能 → fail-open（guard 無効化を loud に通知）
    _orch_session_load_error = e
    SELF_PREFIX = "orch"
    SELF_PFX = SELF_PREFIX + "-"
    _LEDGER_UNREADABLE = object()    # fallback（import 成功時は lib の sentinel に上書きされ未使用）

    def _resolve_ledger(cwd):        # fallback（import 成功時は from-import に上書きされ未使用）
        return None

    def _is_orch_session(cwd):       # fallback: 常に no-op 側（False）= guard 無効化 = fail-open
        return False
    if "--self-test" not in sys.argv:
        sys.stderr.write(f"[bash-file-guard] cannot load orch_session lib, failing open: {e}\n")
        sys.exit(0)


# 静的解決不能（変数 $ / コマンド置換 backtick）の検出＝under-block 対象。cmdtokens.VAR_OR_SUBST と同義だが
# 本 guard 内に閉じた定義にして coupling を最小化する（preamble は実使用 API のみ import する方針）。
_VAR_OR_SUBST = re.compile(r"[$`]")

# write 系 redirect 演算子（read redirect `<` `<<` `<<<` は含めない＝foreign read は許可）。
#   bare 形: `>` `>>` `2>` `2>>` `>|` `&>` `&>>` `<>`（次 token が宛先）。
_WRITE_REDIR_BARE = re.compile(r"^(\d*>>?|>\||&>>?|<>)$")
#   glued 形: `>file` `>>file` `2>file` `&>file` `<>file`（演算子直後に宛先が glue）。
_WRITE_REDIR_GLUED = re.compile(r"^(\d*>>?|>\||&>>?|<>)(.+)$")

# 静的解決不能 modality の loud-log 検出（finding Medium / Low・silent→loud）:
#   process substitution `>(…)` / `<(…)` は parse_statements が `(` `)` `&` `|` で無条件分割するため
#   real な file 宛先が別 fragment へ飛び、どの pass にも乗らず silent leak する。これを検出して loud log。
_PROCSUB_RE = re.compile(r"[<>]\(")
#   `>&PATH` / `n>&PATH`（非数値 word への combined-fd-to-file redirect）: `&` 分割で宛先が次 statement へ
#   spill し silent leak する。fd-dup（`>&2` / `>&-`）は数値/`-` ゆえ除外する（file write でない）。
#   quote-naive な heuristic（loud log 専用＝deny しない＝クォート内データの誤検出は無害な note のみ）。
_AMP_REDIR_PATH_RE = re.compile(r"\d*>&\s*([^\s\d&|;()<>-][^\s&|;()<>]*)")

# --- file 変異コマンドの宛先抽出（K1） ---------------------------------------------------------------
# DEST_LAST: 最後の positional（または -t/--target-directory の値）が宛先。先行 positional は src=read。
DEST_LAST_CMDS = {"cp", "mv", "install", "ln"}
# ALL_POS: 全 positional が宛先。
ALL_POS_CMDS = {"tee", "truncate", "touch"}
# -t/--target-directory（宛先 dir を明示する flag）。DEST_LAST 系で値を宛先として拾う。
TD_FLAGS = {"-t", "--target-directory"}

# 各コマンドの「値を取る flag」（その次 token は positional ではなく flag 値＝宛先でも src でもない）。
# 保守的に列挙（未知フラグは値を取らない＝次 token は positional 扱いで安全側に拾う）。
VALUE_FLAGS = {
    "cp": {"-S", "--suffix", "-t", "--target-directory"},
    "mv": {"-S", "--suffix", "-t", "--target-directory"},
    "install": {"-S", "--suffix", "-t", "--target-directory", "-m", "--mode",
                "-o", "--owner", "-g", "--group"},
    "ln": {"-S", "--suffix", "-t", "--target-directory"},
    "tee": set(),
    "truncate": {"-s", "--size", "-r", "--reference"},   # -r reference は read（値 skip）
    "touch": {"-d", "--date", "-r", "--reference", "-t"},
    "sed": {"-e", "--expression", "-f", "--file", "-l", "--line-length"},
}


def _positionals(words, value_flags):
    """words[1:]（コマンド名以降）から positional token を順序保持で抽出する。
    `--` 以降は全 positional。value_flags の bare flag は次 token を値として skip（`--flag=val` glued は
    `=` を含むため値 skip 不要）。未知 flag は値を取らない（次 token を positional 扱い＝取りこぼし防止）。"""
    out = []
    i, n = 1, len(words)
    while i < n:
        a = words[i]
        if a == "--":
            out.extend(words[i + 1:])
            break
        if a.startswith("-") and len(a) > 1:
            base = a.split("=", 1)[0]
            if base in value_flags and "=" not in a:
                i += 2
            else:
                i += 1
            continue
        out.append(a)
        i += 1
    return out


def _dest_last(words, value_flags):
    """DEST_LAST 系（cp/mv/install/ln）の宛先を返す。
    `-t DIR` / `--target-directory[=DIR]` / glued `-tDIR` があればその DIR、無ければ最後の positional。
    先行 positional（src）は判定しない（foreign を read して自台帳へ copy するのは許可）。"""
    tdir = None
    pos = []
    i, n = 1, len(words)
    while i < n:
        a = words[i]
        if a == "--":
            pos.extend(words[i + 1:])
            break
        if a.startswith("-") and len(a) > 1:
            base = a.split("=", 1)[0]
            # -t / --target-directory（値=宛先 dir）
            if base in TD_FLAGS:
                if "=" in a:
                    tdir = a.split("=", 1)[1]
                    i += 1
                elif i + 1 < n:
                    tdir = words[i + 1]
                    i += 2
                else:
                    i += 1
                continue
            # glued 短縮 `-tDIR`
            if a.startswith("-t") and not a.startswith("--") and len(a) > 2:
                tdir = a[2:]
                i += 1
                continue
            if base in value_flags and "=" not in a:
                i += 2
                continue
            i += 1
            continue
        pos.append(a)
        i += 1
    if tdir is not None:
        return [tdir]
    if pos:
        return [pos[-1]]
    return []


def _sed_inplace(words):
    """sed が in-place（file を変異）モードか。`--in-place`[=SUFFIX] か、短縮クラスタに `i` を含む
    （`-i` / `-i.bak` / `-ni` 等）なら True。over-detect（実は read-only な sed を in-place 判定）は
    安全側 over-block で許容する。"""
    for w in words[1:]:
        if w == "--":
            break
        if w == "--in-place" or w.startswith("--in-place="):
            return True
        if w.startswith("-") and not w.startswith("--") and "i" in w[1:]:
            return True
    return False


def _command_targets(cmdname, words):
    """file 変異コマンドの宛先 token 列を返す（変異コマンドでない/変異モードでないなら []）。
    words = strip_redirections 済の core（iter_commands が返す）。"""
    if cmdname == "sed":
        if not _sed_inplace(words):
            return []
        return _positionals(words, VALUE_FLAGS["sed"])
    if cmdname == "dd":
        return [w[3:] for w in words[1:] if w.startswith("of=") and len(w) > 3]
    if cmdname in ALL_POS_CMDS:
        return _positionals(words, VALUE_FLAGS.get(cmdname, set()))
    if cmdname in DEST_LAST_CMDS:
        return _dest_last(words, VALUE_FLAGS.get(cmdname, set()))
    return []


def _qa_tokens(seg, quote_aware=True):
    """セグメント文字列を redirect 判定用にトークン化する（finding BLOCKER 修正）。
    quote_aware=True（既定・本物）: posix=False でクォートを**保持**する。これにより `grep '>' foreign` の
        `'>'`（クォート済みデータ）は `"'>'"`（両端クォート付きトークン）になり、bare 演算子正規表現に
        マッチしない＝redirect 演算子と誤認しない（純 read を誤 deny しない）。
    quote_aware=False（mutation seam・self-test 専用）: posix=True でクォートを落とす＝旧バグ挙動
        （`'>'`→`>` で redirect 誤検出）。self-test がこの 2 値を弁別し、クォート認識が load-bearing で
        ある（テストが非vacuous）ことを証明する。
    壊れたクォートは None（呼出側 skip = fail-open）。"""
    try:
        return shlex.split(seg, posix=(not quote_aware))
    except ValueError:
        return None


def _posix_unquote(tok):
    """posix=False トークンの論理値（両端/内部クォートを除去した path 文字列）を返す。
    redirect 宛先の台帳判定前に `'/foreign/f'`→`/foreign/f` のように unquote する。posix split が割れる/
    失敗するときは素の strip で degrade（fail-open 側）。"""
    if tok is None:
        return ""
    try:
        parts = shlex.split(tok, posix=True)
        return parts[0] if parts else ""
    except ValueError:
        return tok.strip("'\"")


def _redirect_targets(qa_words):
    """quote-aware（posix=False）トークン列から write 系 redirect の宛先（unquote 済）を返す。
    bare 演算子は次トークン、glued（`>file`）は演算子直後の path を宛先とする。read redirect（`<` `<<`
    `<<<`）は対象外。**クォート済み演算子（`"'>'"` 等）は bare/glued 正規表現にマッチしない**ため data
    として skip される（BLOCKER 修正の核心）。"""
    out = []
    i, n = 0, len(qa_words)
    while i < n:
        w = qa_words[i]
        if _WRITE_REDIR_BARE.match(w):
            if i + 1 < n:
                out.append(_posix_unquote(qa_words[i + 1]))
            i += 2
            continue
        m = _WRITE_REDIR_GLUED.match(w)
        if m:
            out.append(_posix_unquote(m.group(2)))
            i += 1
            continue
        i += 1
    return out


def _risky_construct_notes(cmd):
    """parse_statements が壊し file 宛先が silent leak しうる construct を検出し loud-log note を返す
    （finding Medium/Low・silent→loud。loud-log 専用＝deny しない・defense-in-depth・主モートは L1/L2）。"""
    notes = []
    if _PROCSUB_RE.search(cmd):
        notes.append("[bash-file-guard] process substitution `>(…)`/`<(…)` を検出 — parse_statements が "
                     "`(` `)` で分割し file 宛先（例 `tee >(cat) /foreign`）が静的に解決できず under-block "
                     "（loud log・defense-in-depth・主モートは L1/L2）。\n")
    m = _AMP_REDIR_PATH_RE.search(cmd)
    if m:
        notes.append("[bash-file-guard] `>&PATH`（非数値 word への combined-fd-to-file redirect）を検出 — "
                     "`&` 分割で宛先が静的に解決できず under-block（loud log・heuristic。fd-dup `>&2`/`>&-` は "
                     "対象外）。target≈" + repr(m.group(1)) + "。\n")
    return notes


def _ends_with_dangling_write_redirect(words):
    """セグメント末尾が宛先を伴わない bare write redirect 演算子（`>` `>>` `>|` `&>` `2>` …）かを返す。
    parse_statements は `>|` の `|` を pipe 区切りとして無条件分割するため、`cmd >| dest` は
    segment `[...,'>']`（末尾 bare 演算子・同 segment 内に宛先なし）と segment `['dest', ...]`
    に割れる。この場合 redirect の宛先は **次 segment 先頭 token** に spill しているので、呼出側
    （_scan_redirections）が次 segment 先頭を宛先として継承する必要がある（`>|` covered の欠落修正）。
    末尾 token が bare write redirect 演算子なら True（＝宛先は次 segment へ spill）。"""
    return bool(words) and bool(_WRITE_REDIR_BARE.match(words[-1]))


# --- 台帳判定 ---------------------------------------------------------------------------------------
def render(kind, target, dolt_db):
    # present-but-unreadable は foreign 確定ではない（台帳識別不能＝**orch 自台帳の metadata 破損**も含む）。
    #   foreign 前提の「admin を spawn せよ」は orch 自破損時に誤誘導（admin spawn は無意味/実行不能＝
    #   degraded-state lockout・gate errata #1）。状態整合な metadata 修復路を案内し remediation を分岐する。
    #   sentinel は str() が非決定的 address になるため文面でも生 str 化しない。
    if dolt_db is _LEDGER_UNREADABLE:
        return ("DENIED(bash-file): " + str(kind) + " の書込先 " + str(target) + " の台帳が present-but-unreadable"
                "（壊れ/未読 metadata で識別不能）ゆえ安全側 deny。書込先台帳の `.beads/metadata.json` を修復"
                "してから再試行せよ（orch 自台帳なら raw shell で修復・foreign なら当該 project の admin 経由）。"
                "read（cp の src・`<` redirect・`sed` の非-i 等）は許可。\n")
    return ("DENIED(bash-file): foreign 台帳配下への Bash file 変異は禁止。" + str(kind) + " の書込先 " +
            str(target) + " は別台帳（dolt_database=" + str(dolt_db) + "）配下で、orchestrator が write して"
            "よいのは自台帳（prefix '" + SELF_PFX + "' / dolt_database='" + SELF_PREFIX + "'）配下のみ。owner "
            "2人違反になるため foreign リポの file 変異は当該 project の admin を spawn して行え"
            "（orch-spawn-admin）。read（cp の src・`<` redirect・`sed` の非-i 等）は許可。\n")


def _underblock_note(kind, token):
    return ("[bash-file-guard] 静的解決不能な書込先を under-block（defense-in-depth・主モートは L1/L2）: " +
            str(kind) + " target=" + repr(token) + " に変数/コマンド置換あり → 台帳判定 skip（allow）。\n")


def _classify_path(token, base_cwd, _enforce=True):
    """宛先 token を base_cwd 基準で解決し判定する。返り値 (code, target_realpath, dolt_db)。
    code: 0=allow / 2=deny / None=静的解決不能（変数/置換＝under-block・呼出側で loud log）。
    台帳四値（orch-8dl）: 自台帳(orch)=allow / 台帳外(None)=allow / foreign(他 dolt_database)=deny /
    present-but-unreadable(`_LEDGER_UNREADABLE` sentinel)=deny。最後の present-but-unreadable deny が
    orch-8dl の核心: 壊れ/未読 metadata（nested shadow 含む）で識別不能な書込先を、従来の None 畳み込み
    （allow）でなく deny 側へ倒す（session 判定 `_is_orch_session` の fail-closed と対称）。sentinel は
    `== SELF_PREFIX`/`is None` のいずれにもマッチせず deny 分岐へ自然に落ちる。
    _enforce は mutation-testing seam（self-test 専用）: False で deny 分岐を撤去した mutant 挙動になり
    foreign / present-but-unreadable ケースが allow(0) に落ちる。本物（_enforce=True・production 既定）では
    deny(2) する。"""
    if not token:
        return 0, None, None
    if _VAR_OR_SUBST.search(token):
        return None, None, None
    try:
        base = base_cwd or os.getcwd()
        target = os.path.realpath(os.path.join(base, os.path.expanduser(token)))
        start = target if os.path.isdir(target) else os.path.dirname(target)
        # orch-8dl: _resolve_ledger（三値）で解決し present-but-unreadable を deny に倒す
        #   （_ledger_dolt_database の str|None 畳み込みは sentinel を None=allow に潰すため使わない）。
        dolt_db = _resolve_ledger(start)
    except Exception:
        return 0, None, None  # 解決中の例外は fail-open（allow）
    if dolt_db == SELF_PREFIX:
        return 0, target, dolt_db        # 自台帳（orch）配下 → allow
    if dolt_db is None:
        return 0, target, dolt_db        # 台帳外（/tmp・/dev/null・~/.claude/projects 等）→ allow
    if not _enforce:
        return 0, target, dolt_db        # mutation seam: deny 撤去 mutant → allow（self-test 弁別用）
    # foreign 台帳配下 or present-but-unreadable（後者は orch-8dl で deny 化＝session 判定と対称）→ deny
    return 2, target, dolt_db


def _scan_operands(cmd, session_cwd, _enforce=True):
    """Pass A: iter_commands で operand 系変異の宛先を判定。(code, msg, notes) を返す。"""
    notes = []
    for core, seg_cwd in iter_commands(cmd, session_cwd):
        if not core:
            continue
        cmdname = os.path.basename(core[0])
        targets = _command_targets(cmdname, core)
        for tk in targets:
            code, tgt, db = _classify_path(tk, seg_cwd, _enforce=_enforce)
            if code is None:
                notes.append(_underblock_note(cmdname, tk))
            elif code == 2:
                return 2, render(cmdname + " operand", tgt, db), notes
    return 0, "", notes


def _scan_redirections(cmd, session_cwd, _enforce=True, depth=0, _quote_aware=True):
    """Pass B: redirect 宛先を判定（iter_commands は strip するため別走査）。track_cd で statement を
    またぐ `cd` を追跡し実効 cwd を更新する（iter_commands と同一機構）。

    finding#1(F2) 修正: inline（`bash -c`/`eval`/`sh -c`）内 redirect を再帰検査する（peel 後の inline 文字列
    へ _scan_redirections を再帰）。inline があっても外側 redirect（`bash -c '..' > /foreign`）も検査するため
    continue しない（raw 走査と inline 再帰を additive に重ねる）。
    finding BLOCKER 修正: redirect 演算子判定を **quote-aware**（posix=False トークン）にする。`shlex_safe`
    （posix=True）はクォートを落とし `grep '>' foreign` の `'>'` を裸 `>` と誤認して純 read を誤 deny した。
    posix=False で `'>'`→`"'>'"` のままにし、クォート済み演算子は redirect と見なさない（_redirect_targets）。
    peel/track_cd は構造解析ゆえ従来どおり posix=True トークン（shlex_safe）を使い、redirect 抽出のみ
    posix=False トークンを使う（2 系統を per-segment で併用）。
    finding Medium/Low: procsub `>(…)`/`<(…)` と `>&PATH` は parse_statements が壊し宛先が leak するため
    depth==0 で loud-log（_risky_construct_notes・silent→loud）。"""
    notes = []
    if depth > 6:
        return 0, "", notes
    if depth == 0:
        notes.extend(_risky_construct_notes(cmd))
    eff = {"cwd": session_cwd or os.getcwd()}
    for statement in parse_statements(cmd):
        seg_posix = []   # posix=True トークン（peel/inline/track_cd 用＝構造解析）
        seg_raw = []     # 元 segment 文字列（quote-aware redirect 抽出用）
        for seg in statement:
            w = shlex_safe(seg)
            if w:
                seg_posix.append(w)
                seg_raw.append(seg)
        if not seg_posix:
            continue
        track_cd(seg_posix[0], eff)
        # 各 segment の quote-aware トークン（posix=False・redirect 演算子のクォート認識用）。
        seg_qa = [(_qa_tokens(s, _quote_aware) or []) for s in seg_raw]
        for si, words in enumerate(seg_posix):
            # peel 透過ランチャ → inline 文字列があれば実効 cwd 込みで再帰（inline 内 redirect 検査）。
            try:
                core, inline, _is_xargs, cwd_ovr = peel(words)
            except Exception:
                core, inline, cwd_ovr = words, None, None
            if cwd_ovr:
                seg_cwd = cwd_ovr if os.path.isabs(cwd_ovr) else os.path.normpath(os.path.join(eff["cwd"], cwd_ovr))
            else:
                seg_cwd = eff["cwd"]
            if inline is not None:
                code, msg, n = _scan_redirections(inline, seg_cwd, _enforce=_enforce,
                                                  depth=depth + 1, _quote_aware=_quote_aware)
                notes.extend(n)
                if code == 2:
                    return 2, msg, notes
                # inline があっても外側 redirect（`bash -c '..' > /foreign`）も検査するため continue しない。
            # quote-aware（posix=False）トークンから redirect 宛先抽出（BLOCKER 修正）。
            qa = seg_qa[si]
            targets = list(_redirect_targets(qa))
            # `>|`（force-clobber）等は parse_statements が `|` で分割し、宛先が次 segment 先頭 token に
            # spill する。末尾 bare write redirect 演算子を検出したら次 segment 先頭を宛先として継承する
            # （これが無いと `cmd >| /foreign` の宛先が一度も台帳判定されず silent fail-open になる）。
            if qa and _ends_with_dangling_write_redirect(qa) and si + 1 < len(seg_qa):
                nxt = seg_qa[si + 1]
                if nxt:
                    targets.append(_posix_unquote(nxt[0]))
            for tk in targets:
                code, tgt, db = _classify_path(tk, seg_cwd, _enforce=_enforce)
                if code is None:
                    notes.append(_underblock_note("redirect", tk))
                elif code == 2:
                    return 2, render("redirect", tgt, db), notes
    return 0, "", notes


def analyze(cmd, session_cwd, _enforce=True, _quote_aware=True):
    """最終判定。(code, msg, notes) を返す（code: 0=allow / 2=deny / notes: under-block の loud log 行）。
    非 orchestrator session は no-op。各パスの例外は fail-open（その分を取りこぼすだけで全 Bash を brick しない）。
    _quote_aware は BLOCKER 修正の mutation seam（self-test 専用）: False で Pass B の redirect 判定が
    クォートを落とす旧バグ挙動になり `grep '>' foreign` が誤 deny に戻る（self-test が弁別＝非vacuous）。"""
    notes = []
    if not cmd:
        return 0, "", notes
    try:
        if not _is_orch_session(session_cwd):
            return 0, "", notes          # 非 orchestrator session → no-op
    except Exception:
        return 0, "", notes
    # Pass A（operand 系変異）
    try:
        code, msg, n = _scan_operands(cmd, session_cwd, _enforce=_enforce)
        notes.extend(n)
        if code == 2:
            return 2, msg, notes
    except Exception as e:
        notes.append(f"[bash-file-guard] operand scan error, failing open: {e}\n")
    # Pass B（redirection）
    try:
        code, msg, n = _scan_redirections(cmd, session_cwd, _enforce=_enforce, _quote_aware=_quote_aware)
        notes.extend(n)
        if code == 2:
            return 2, msg, notes
    except Exception as e:
        notes.append(f"[bash-file-guard] redirection scan error, failing open: {e}\n")
    return 0, "", notes


def main():
    if "--self-test" in sys.argv:
        if _cmdtokens_load_error is not None:
            print(f"FAIL: [preamble] cmdtokens lib load 失敗: {_cmdtokens_load_error}")
            print("bash-file-guard self-test: ABORTED (cmdtokens 未 load)")
            return 1
        if _orch_session_load_error is not None:
            print(f"FAIL: [preamble] orch_session lib load 失敗: {_orch_session_load_error}")
            print("bash-file-guard self-test: ABORTED (orch_session 未 load)")
            return 1
        return run_self_test()
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    try:
        data = json.loads(raw) if raw.strip() else {}
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
        cwd = data.get("cwd") or os.getcwd()
    except Exception as e:
        sys.stderr.write(f"[bash-file-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg, notes = analyze(cmd, cwd)
    except Exception as e:
        sys.stderr.write(f"[bash-file-guard] internal error, failing open: {e}\n")
        return 0
    for note in notes:
        sys.stderr.write(note)        # under-block の loud log（exit code は変えない）
    if msg:
        sys.stderr.write(msg)
    return code


# --- self-test（hermetic: temp .beads/metadata.json fixture・subprocess も実 DB も触らない） ----------
# file-write-guard.py の self-test と同型。orch/foreign/bare(.beads無)/broken(不正JSON) の台帳を共通 base 下に
# 作り、Pass A（各変異コマンド）・Pass B（redirect）・cd 追跡・launcher peel・inline 再帰・under-block・
# read operand 許可・非 orch no-op を実証する。最後に mutation testing で deny ロジックの非vacuous を証明する。
def run_self_test():
    import tempfile
    import shutil

    failures = []
    checks = 0
    base = tempfile.mkdtemp(prefix="bashfileguard-st-")
    try:
        def mk(name, dolt_db):
            """dolt_db=None → .beads 無し（台帳外）/ '__broken__' → 不正 JSON(parse 失敗=①)/
            '__nondict__' → parse 成功だが非 dict(JSON 配列・②境界＝`else None`=fail-open 側)/
            '__nokey__' → parse 成功・dict だが dolt_database キー欠落(②境界＝`.get`→None=fail-open 側。
            __nondict__ と同じ None/fail-open へ畳むが **別 code path**)。"""
            root = os.path.join(base, name)
            os.makedirs(root)
            if dolt_db is not None:
                os.makedirs(os.path.join(root, ".beads"))
                with open(os.path.join(root, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
                    if dolt_db == "__broken__":
                        f.write("{ this is not valid json")
                    elif dolt_db == "__nondict__":
                        json.dump([1, 2, 3], f)  # parse 成功だが非 dict → `else None`（②境界・fail-open）
                    elif dolt_db == "__nokey__":
                        json.dump({"database": "dolt"}, f)  # dict だが dolt_database 欠落 → `.get`→None（②境界・fail-open）
                    else:
                        json.dump({"database": "dolt", "dolt_database": dolt_db}, f)
            return root

        orch = mk("orch", "orch")
        foreign = mk("foreign", "un")
        bare = mk("bare", None)
        broken = mk("broken", "__broken__")
        nondict = mk("nondict", "__nondict__")
        nokey = mk("nokey", "__nokey__")
        os.makedirs(os.path.join(orch, "sub"))
        os.makedirs(os.path.join(foreign, "sub"))
        # orch-8dl nested shadow fixture: orch 祖先（orch）配下に壊れ metadata の子台帳。書込先がこの子配下だと
        #   walk-up が壊れ子の present-but-unreadable で打ち切られ祖先 orch に到達せず deny（present-but-unreadable
        #   deny の shadow サブケース＝_resolve_ledger 直利用への切替で deny 化）。
        nested_shadow = os.path.join(orch, "nestedbroken")
        os.makedirs(os.path.join(nested_shadow, ".beads"))
        with open(os.path.join(nested_shadow, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            f.write("{ broken nested metadata")

        F = os.path.join(foreign, "f.txt")
        FD = os.path.join(foreign, "sub")          # foreign dir（-t 宛先用）
        O = os.path.join(orch, "g.txt")
        FSRC = os.path.join(foreign, "src.txt")

        # (cmd, session_cwd, expect_code, label)
        DENY, ALLOW = 2, 0
        cases = [
            # --- Pass A: sed -i ---
            (f"sed -i 's/x/y/' {F}", orch, DENY, "sed -i foreign → deny"),
            (f"sed -i 's/x/y/' {O}", orch, ALLOW, "sed -i orch → allow"),
            (f"sed --in-place -e 's/x/y/' {F}", orch, DENY, "sed --in-place -e foreign → deny (-e 値 skip)"),
            (f"sed -i.bak 's/x/y/' {F}", orch, DENY, "sed -i.bak foreign → deny"),
            (f"sed -n 's/x/y/p' {F}", orch, ALLOW, "sed 非-i (read) foreign → allow"),
            (f"sed -i 's/x/y/' {O} {F}", orch, DENY, "sed -i 複数: 1つ foreign → deny"),
            # --- Pass A: tee ---
            (f"tee {F}", orch, DENY, "tee foreign → deny"),
            (f"tee -a {F}", orch, DENY, "tee -a foreign → deny"),
            (f"tee {O}", orch, ALLOW, "tee orch → allow"),
            # --- Pass A: cp / mv（dest のみ・src read 許可） ---
            (f"cp a {F}", orch, DENY, "cp dest foreign → deny"),
            (f"cp {FSRC} {O}", orch, ALLOW, "cp src=foreign dest=orch → allow（foreign read OK）"),
            (f"cp -t {FD} x", orch, DENY, "cp -t foreign-dir → deny"),
            (f"cp -t{FD} x", orch, DENY, "cp -tDIR glued foreign → deny"),
            (f"mv a {F}", orch, DENY, "mv dest foreign → deny"),
            (f"mv {FSRC} {O}", orch, ALLOW, "mv src=foreign dest=orch → allow"),
            (f"install -m 755 a {F}", orch, DENY, "install dest foreign (-m 値 skip) → deny"),
            (f"ln -s a {F}", orch, DENY, "ln -s linkname foreign → deny"),
            (f"ln -s {FSRC} {O}", orch, ALLOW, "ln -s target=foreign linkname=orch → allow"),
            # --- Pass A: dd of= ---
            (f"dd if=/dev/zero of={F}", orch, DENY, "dd of= foreign → deny"),
            (f"dd if={FSRC} of={O}", orch, ALLOW, "dd if=foreign of=orch → allow（if read OK）"),
            # --- Pass A: truncate / touch ---
            (f"truncate -s 0 {F}", orch, DENY, "truncate -s foreign → deny"),
            (f"touch {F}", orch, DENY, "touch foreign → deny"),
            (f"touch -r {FSRC} {O}", orch, ALLOW, "touch -r ref=foreign target=orch → allow"),
            # --- Pass B: redirections ---
            (f"echo x > {F}", orch, DENY, "redirect > foreign → deny"),
            (f"echo x >> {F}", orch, DENY, "redirect >> foreign → deny"),
            (f"echo x > {O}", orch, ALLOW, "redirect > orch → allow"),
            ("echo x > /dev/null", orch, ALLOW, "redirect > /dev/null（台帳外）→ allow"),
            (f"cat a 2> {F}", orch, DENY, "redirect 2> foreign → deny"),
            (f"cmd &> {F}", orch, DENY, "redirect &> foreign → deny（& 文区切り後 bare > で捕捉）"),
            (f"echo x >| {F}", orch, DENY, "redirect >| force-clobber foreign → deny（| 分割越し継承）"),
            (f"echo x >|{F}", orch, DENY, "redirect >|glued force-clobber foreign → deny"),
            (f"echo x >| {O}", orch, ALLOW, "redirect >| force-clobber orch → allow（over-block しない）"),
            (f"echo x >{F}", orch, DENY, "redirect >glued foreign → deny"),
            (f"cat < {F}", orch, ALLOW, "read redirect < foreign → allow"),
            (f"cat <<< 'x' > {O}", orch, ALLOW, "herestring + orch redirect → allow"),
            (f"bd export > {F}", orch, DENY, "非変異 cmd でも redirect 宛先 foreign → deny"),
            # --- cd 追跡（実効 cwd で解決） ---
            (f"cd {foreign} && echo x > f.txt", orch, DENY, "cd foreign && redirect 相対 → deny"),
            (f"cd {foreign} && sed -i s/x/y/ f.txt", orch, DENY, "cd foreign && sed -i 相対 → deny"),
            (f"cd {orch} && echo x > g.txt", orch, ALLOW, "cd orch && redirect 相対 → allow"),
            # --- launcher peel / inline 再帰（Pass A） ---
            (f"sudo tee {F}", orch, DENY, "launcher sudo tee foreign → deny"),
            (f'bash -c "sed -i s/x/y/ {F}"', orch, DENY, "inline bash -c sed -i foreign → deny（再帰）"),
            (f'flock /tmp/l cp a {F}', orch, DENY, "launcher flock cp dest foreign → deny"),
            # --- Pass B: inline 内 redirect 再帰 + launcher peel（finding#1 修正・以前は silent fail-open） ---
            (f'bash -c "echo x > {F}"', orch, DENY, "inline bash -c redirect foreign → deny（再帰）"),
            (f'sh -c "echo x > {F}"', orch, DENY, "inline sh -c redirect foreign → deny（再帰）"),
            (f"sudo sh -c 'echo x > {F}'", orch, DENY, "finding#1: launcher sudo sh -c redirect foreign → deny"),
            (f"sudo bash -c 'echo x >> {F}'", orch, DENY, "finding#1: sudo bash -c append redirect foreign → deny"),
            (f"eval 'echo x > {F}'", orch, DENY, "inline eval redirect foreign → deny（再帰）"),
            (f'bash -c "echo x > {F}; sed -i s/a/b/ {O}"', orch, DENY, "inline 複合: redirect foreign → deny"),
            (f'bash -c "echo x > {O}"', orch, ALLOW, "inline bash -c redirect orch → allow（over-block しない）"),
            (f"sudo sh -c 'echo x > {O}'", orch, ALLOW, "launcher sudo sh -c redirect orch → allow"),
            (f"sudo cat a > {F}", orch, DENY, "launcher 前置 + segment-level redirect foreign → deny"),
            # --- under-block（変数/置換）: allow + loud note ---
            ("sed -i s/x/y/ $TARGET", orch, ALLOW, "under-block: sed -i 変数宛先 → allow"),
            ("echo x > $OUT", orch, ALLOW, "under-block: redirect 変数宛先 → allow"),
            ("cp a $(get_dest)", orch, ALLOW, "under-block: cp コマンド置換宛先 → allow"),
            # --- 非 orchestrator session → no-op（書込先 foreign でも allow） ---
            (f"sed -i s/x/y/ {F}", foreign, ALLOW, "非 orch session(foreign cwd): sed -i foreign → no-op allow"),
            (f"echo x > {F}", foreign, ALLOW, "非 orch session(foreign cwd): redirect foreign → no-op allow"),
            (f"echo x > {F}", bare, ALLOW, "非 orch session(.beads 無 cwd): → no-op allow"),
            (f"echo x > {F}", broken, DENY, "present-but-unreadable session(壊れ metadata cwd)→ fail-closed orch session → foreign redirect deny(orch-5yl 波及)"),
            (f"echo x > {F}", nondict, ALLOW, "②境界: 非 dict metadata session(parse 成功)→ fail-open 非 orch → foreign redirect でも no-op allow（`else None`→UNREADABLE 反転を捕捉する恒久 pin・orch-5yl）"),
            (f"echo x > {F}", nokey, ALLOW, "②境界(別 path): nokey metadata session(dict・dolt_database 欠落・parse 成功)→ fail-open 非 orch → foreign redirect でも no-op allow（__nondict__ の `else None` とは別 code path の `.get`→None 分岐を pin・① 取り違え反転で RED・orch-ehg）"),
            # --- 非変異コマンド + foreign operand は read 扱いで allow ---
            (f"cat {F}", orch, ALLOW, "cat foreign（read）→ allow"),
            (f"grep x {F}", orch, ALLOW, "grep foreign（read）→ allow"),
            # --- 台帳外/壊れ宛先は allow ---
            # orch-8dl: **書込先**が present-but-unreadable（壊れ metadata 配下）でも deny する（旧 KNOWN
            #   RESIDUAL UNDER-BLOCK を解消）。書込先解決を `_resolve_ledger` 直利用に切り替え、
            #   `_LEDGER_UNREADABLE`（sentinel）を None=allow に畳まず `_classify_path` の deny 分岐へ落とす
            #   ＝session 判定 _is_orch_session の fail-closed=deny と対称。`_ledger_dolt_database` の None 畳み込み
            #   へ回帰すると allow に反転しここで RED（= `_resolve_ledger` 直利用が load-bearing である pin）。
            (f"echo x > {os.path.join(broken, 'x')}", orch, DENY, "orch-8dl: 壊れ metadata 配下を**宛先**に(session は orch)→ present-but-unreadable deny（旧 under-block を解消・session 経路の fail-closed と対称）"),
            # orch-8dl nested shadow: orch 祖先（orch）配下に壊れ子台帳。書込先がこの子配下だと walk-up が壊れ子の
            #   present-but-unreadable で打ち切られ祖先 orch に到達せず deny（present-but-unreadable deny の shadow
            #   サブケース）。`_ledger_dolt_database` 回帰だと None=台帳外と誤分類され allow に反転し RED。
            (f"echo x > {os.path.join(nested_shadow, 'x')}", orch, DENY, "orch-8dl: nested shadow（orch 祖先 + 壊れ子 metadata）を宛先に → deny（walk-up が壊れ子で打ち切られ祖先 orch に到達せず）"),
            ("echo x > /tmp/orch-l3-st-xyz", orch, ALLOW, "tmp 宛先 → allow"),
            # --- admin gate BLOCKER: クォート済み '>' は data＝純 read を誤 deny しない（quote-aware） ---
            (f"grep '>' {F}", orch, ALLOW, "BLOCKER: grep '>' foreign（純 read・'>'=data）→ allow"),
            (f'grep ">" {F}', orch, ALLOW, "BLOCKER: grep \">\" foreign（純 read・dquote data）→ allow"),
            (f"grep -E '>>' {F}", orch, ALLOW, "BLOCKER: grep -E '>>' foreign（純 read）→ allow"),
            (f"grep '>' {O}", orch, ALLOW, "BLOCKER: grep '>' orch（純 read）→ allow"),
            ("echo '>'", orch, ALLOW, "BLOCKER: echo '>'（data のみ・redirect 無し）→ allow"),
            (f"grep '>' {F} > {O}", orch, ALLOW, "BLOCKER: grep '>' foreign(read) + > orch(self write) → allow"),
            (f"grep '>' {O} > {F}", orch, DENY, "BLOCKER 境界: data '>' は skip だが本物の > foreign は deny 維持"),
            (f"echo x > {F}", orch, DENY, "BLOCKER 境界: 本物の裸 > foreign は deny 維持（quote-aware で誤検出回避≠取りこぼし）"),
            # --- admin gate Medium: procsub は under-block だが loud log（silent→loud） ---
            (f"tee >(cat) {F}", orch, ALLOW, "Medium: tee >(cat) foreign → under-block allow（loud log は別 assert）"),
            (f"cp a >(cat) {F}", orch, ALLOW, "Medium: cp procsub foreign → under-block allow"),
            # --- admin gate Low: >&PATH は under-block だが loud log / >&2 は fd-dup ゆえ対象外 ---
            (f"echo x >& {F}", orch, ALLOW, "Low: >&PATH foreign → under-block allow（loud log は別 assert）"),
            ("echo x >&2", orch, ALLOW, "Low: >&2 fd-dup（file でない）→ allow（誤検出しない）"),
        ]
        for cmd, cwd, want, label in cases:
            checks += 1
            try:
                code, _msg, _notes = analyze(cmd, cwd)
            except Exception as e:
                failures.append(f"[EXC] {label}: {cmd!r}@{cwd!r} -> {e}")
                continue
            if code != want:
                failures.append(f"[code {want} expected] {label}: {cmd!r}@{cwd!r} -> got {code}")

        # under-block は loud note を必ず出す（取りこぼしを silent にしない＝検出器が非vacuous）。
        checks += 1
        _c, _m, notes_var = analyze("sed -i s/x/y/ $TARGET", orch)
        if not notes_var:
            failures.append("[under-block] 変数宛先で loud note が空（silent 取りこぼし）")
        checks += 1
        _c, _m, notes_red = analyze("echo x > $OUT", orch)
        if not notes_red:
            failures.append("[under-block] redirect 変数宛先で loud note が空")

        # deny 時は必ず説明 msg を出す。
        checks += 1
        code_d, msg_d, _n = analyze(f"echo x > {F}", orch)
        if code_d != 2 or "DENIED(bash-file)" not in msg_d:
            failures.append(f"[deny-msg] foreign deny の説明 msg が欠落: code={code_d} msg={msg_d!r}")

        # mutation testing（非vacuous 証明）: deny ロジック(_enforce)撤去 mutant では foreign が allow(0)に
        # 落ち、本物(_enforce=True)では deny(2)。operand 経路と redirect 経路の両方で弁別する。
        for label, cmd in [("operand", f"sed -i s/x/y/ {F}"), ("redirect", f"echo x > {F}")]:
            checks += 1
            r_code, _rm, _rn = analyze(cmd, orch, _enforce=True)
            m_code, _mm, _mn = analyze(cmd, orch, _enforce=False)
            if r_code != 2:
                failures.append(f"[mutation/{label}] 本物の foreign deny が 2 でない: {r_code}")
            if m_code != 0:
                failures.append(f"[mutation/{label}] mutant(deny 撤去)で foreign が allow(0)に落ちない＝vacuous: {m_code}")

        # orch-8dl mutation: present-but-unreadable 宛先の deny も load-bearing（_enforce seam が sentinel も
        #   制御する）。operand 経路（sed -i）と redirect 経路（>）の両方で、本物=deny(2) / mutant(deny 撤去)=allow(0)
        #   を弁別する（present-but-unreadable deny が vacuous でない＝検出器が空でない証明）。
        bdest = os.path.join(broken, "mut")
        for label, cmd in [("operand", f"sed -i s/x/y/ {bdest}"), ("redirect", f"echo x > {bdest}")]:
            checks += 1
            r_code, _rm, _rn = analyze(cmd, orch, _enforce=True)
            m_code, _mm, _mn = analyze(cmd, orch, _enforce=False)
            if r_code != 2:
                failures.append(f"[mutation/unreadable/{label}] 本物の present-but-unreadable deny が 2 でない: {r_code}")
            if m_code != 0:
                failures.append(f"[mutation/unreadable/{label}] mutant(deny 撤去)で unreadable が allow(0)に落ちない＝vacuous: {m_code}")

        # orch-8dl errata #1: present-but-unreadable deny の message は metadata 修復を案内し admin-spawn 一辺倒で
        #   ない（orch 自台帳破損の degraded-state lockout で foreign admin spawn へ誤誘導しないことを pin）。
        checks += 1
        c_bmsg, m_bmsg, _n_bmsg = analyze(f"echo x > {os.path.join(broken, 'x')}", orch)
        if c_bmsg != 2 or "修復" not in m_bmsg or "spawn" in m_bmsg:
            failures.append(
                f"[errata#1] present-but-unreadable deny message が修復案内でない/admin-spawn 誘導が残る: code={c_bmsg} msg={m_bmsg!r}")

        # admin gate BLOCKER の mutation testing（クォート認識が load-bearing である非vacuous 証明）:
        #   本物(_quote_aware=True)では `grep '>' foreign`（'>'=data・純 read）が allow(0)、quote 認識を外した
        #   mutant(_quote_aware=False=旧バグ posix=True)では裸 `>` 誤検出で deny(2) に戻る＝この差が「クォート
        #   認識を入れたことで誤 deny が消えた」ことを弁別する（テストが空でない）。
        checks += 1
        real_qa, _rm, _rn = analyze(f"grep '>' {F}", orch, _quote_aware=True)
        mut_qa, _mm, _mn = analyze(f"grep '>' {F}", orch, _quote_aware=False)
        if real_qa != 0:
            failures.append(f"[mutation/quote] 本物(quote-aware)で grep'>'foreign が allow(0)でない: {real_qa}")
        if mut_qa != 2:
            failures.append(f"[mutation/quote] mutant(quote 認識撤去)で grep'>'foreign が deny(2)に戻らない＝vacuous: {mut_qa}")

        # admin gate Medium/Low: silent→loud。procsub と >&PATH は under-block(allow)だが loud note を出す。
        #   >&2(fd-dup)は note を出さない（file write でないため誤検出しない）＝note の弁別力を pin。
        checks += 1
        c_ps, _m, notes_ps = analyze(f"tee >(cat) {F}", orch)
        if c_ps != 0 or not any("process substitution" in n for n in notes_ps):
            failures.append(f"[procsub] tee >(cat) foreign の loud note 欠落: code={c_ps} notes={notes_ps}")
        checks += 1
        c_amp, _m, notes_amp = analyze(f"echo x >& {F}", orch)
        if c_amp != 0 or not any(">&PATH" in n for n in notes_amp):
            failures.append(f"[>&PATH] echo x >& foreign の loud note 欠落: code={c_amp} notes={notes_amp}")
        checks += 1
        _c, _m, notes_fddup = analyze("echo x >&2", orch)
        if any(">&PATH" in n for n in notes_fddup):
            failures.append(f"[>&PATH] >&2(fd-dup)で誤って >&PATH note を出した（弁別力欠如）: {notes_fddup}")

        # symlink: orch 配下の file が foreign を指す → realpath 解決後の実宛先(foreign)で deny。
        checks += 1
        link = os.path.join(orch, "evil-link.txt")
        try:
            os.symlink(F, link)
            sym_ok = True
        except Exception:
            sym_ok = False
        if sym_ok:
            code_s, _m, _n = analyze(f"echo x > {link}", orch)
            if code_s != 2:
                failures.append(f"[symlink] orch 配下 symlink→foreign の redirect が deny でない: {code_s}")
        else:
            print("NOTE: symlink 作成不可の環境ゆえ symlink ケースを skip（checks は維持）")

        # never-die: session_cwd=None でも例外で死なない。
        checks += 1
        try:
            analyze("echo x > /tmp/y", None)
        except Exception as e:
            failures.append(f"[EXC none-cwd] session_cwd=None で die: {e}")

    finally:
        shutil.rmtree(base, ignore_errors=True)

    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bash-file-guard self-test: {len(failures)} FAILED (of {checks} checks)")
        return 1
    print(f"bash-file-guard self-test: {checks}/{checks} OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

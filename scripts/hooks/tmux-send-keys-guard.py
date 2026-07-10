#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook: 管理窓（非 'wt-' window）への **生 tmux send-keys** を機械 block（exit 2）し、
#   session 間送信を送達確認つき `scripts/scribe-inject.sh` 経由へ funnel する（transport 構造封鎖）。
# 由来: sc-164（orch-eaj courier 荷6 = sc-flk attention-hub 裁定の B「transport 構造封鎖」の scribe 分担）。
#   正本 = scriptorium top-spec §5.3 末尾「sc-flk との突合」＋ consult 裁定 doobidoo 3e91c1e1。
#   背景 incident（sc-6vj）: 生 send-keys は bracketed-paste 滞留・誤『送信済み』判定・Enter 未押下で silent に
#   未送達となり、2026-07-08/09 に admin 操舵注入の未送達が実発生した。scribe-inject.sh は送達確認（残留検知）
#   つきの唯一の正路で、失敗を exit 3(RESIDUAL=未送達)/exit 4(INCONCLUSIVE=確認不能)で fail-loud する。本 guard は
#   その必須化の「機械実体」＝生 send-keys を PreToolUse 層で塞ぐ（scribe-inject 内部の send-keys は subprocess
#   ゆえ PreToolUse は再発火せず自然に通る＝この構造が「scribe-inject 必須化」を成す・下記 J4）。
#
# 構造は既存 3 guard（git-destructive-guard.py / rm-destructive-guard.py / bd-write-guard.py）を踏襲する:
#   - トークナイザは publish 済 cmdtokens plugin の canonical lib を consume する（下記 consume preamble）。
#   - session self-scope（scribe_session._is_scribe_guard_session・fail-closed）で dolt_database=='sc' session
#     のみ発火し、foreign（orchestrator の 'orch' 等）session では exit0 no-op＝orchestrator 自身の spawn/inject
#     運用を絶対に brick しない（sc-164 admin 裁定 2）。
#
# KNOWN RISK（consume 設計の既知性質・全 guard 共通）: cmdtokens plugin 不在ホストでは lib ロードに失敗し guard が
#   fail-open（exit 0・loud stderr）で素通しになる（transport 封鎖が silent に無効化）。SessionStart guard-health
#   banner は cmdtokens 不在を loud 化するが、その列挙は例示的で本 guard 名を含まない（bd-write-guard も同様に
#   未列挙＝banner は cmdtokens consumer の網羅リストではない・precedent 準拠）。
#
# 方式（sc-164 admin 裁定 3/7・token 検査は send-keys の位置に依存しない）: コマンド文字列を共有
#   lib(cmdtokens.iter_commands)で shlex トークン化し、**本物の `tmux` 呼び出しのトークン列にのみ**ルールを
#   適用する。パイプ/セミコロン/改行で紛れても検出し（`x | tmux send-keys …`・`a; tmux send …`）、launcher
#   (sudo/env/timeout/flock…) / `bash -c "…"` / eval / su -c 等の経由も lib が貫通する。クォート内データ
#   （`echo "tmux send-keys …"`）は shlex が 1 トークン化＝basename が echo になり誤検出しない（cmdtokens が構造
#   的に排除）。send-keys の documented alias `send` も対象に含める。**capture-pane（read-only 監視）・
#   paste-buffer 等 send-keys 以外の tmux subcommand は対象外**（admin の pane 監視を絶対に壊さない。paste-buffer
#   経由の別 transport は本契約の scope 外＝follow-up 候補として notes 起票提案）。
#
# 境界判定（sc-164 admin 裁定 3・block 対象 = -t target が 'wt-' 接頭辞でない window）:
#   worker 窓（wt-*）への steering は封鎖対象外・管理窓（admin/orchestrator/consult 等）への送信を block する。
#   worker 窓は dotted bd id 衝突回避で **window ID `@N` 参照が規約**（protocol.md §1）ゆえ、target は名前が
#   直接見えないことが多い。判定は:
#     1. target の window 指定子が literal に 'wt-' で始まる（`wt-sc-1` / `sess:wt-sc-1` / `=wt-…` / dotted
#        `wt-un-3sh.3.5`）→ **allow**（tmux read 不要の fast-path・worker 窓明示）。
#     2. それ以外（`@N` / `session:index` / `%pane` / bare session 名 / -t 無し）→ tmux で window 名を解決:
#        - 解決成功 & 'wt-' 接頭辞 → allow / 非 'wt-' → **deny**。
#        - 解決不能だが tmux server 到達可 → **deny（fail-closed）**（発火後の判定不能は deny・裁定 5）。
#        - tmux server 到達不能（tmux 外 / server 無 / tmux バイナリ不在）→ **allow**: guard が tmux を読めない
#          環境では対象 send-keys 自体も実行不能ゆえ素通しで実害なし（裁定 3）。
#   過剰 false-positive（管理窓の誤 deny）は容認する（代替 = scribe-inject or ファイル化・裁定 7）。
#
# fail-mode 三値（edit-write-guard と同じ整理・裁定 5）: 非 scribe session は発火せず（foreign を brick しない）/
#   scribe session で発火後の target 判定不能（tmux 到達可なのに解決不能）は deny（fail-closed）/ guard クラッシュ
#   （予期せぬ例外）は fail-open（exit0+warn）。**guard ゆえ hooks.json の command に `|| true` を付けない**
#   （exit2=block を伝播・script 不在/非実行時のみ hooks.json 側 if/else で exit0=fail-open）。
#
# 設計（依存: os/sys/re/json/subprocess + consume lib）: 入力解析例外・内部例外は握り潰して fail-open(exit0)。
#   tmux 解決は subprocess（read-only な display-message のみ・timeout 付き）で、テスト seam は SCRIBE_TMUX。

import sys
import os
import re
import json
import subprocess

# --- cmdtokens consume preamble（bd-write-guard と同一の薄い解決層）---------------------------------------
#   canonical cmdtokens（standalone cmdtokens plugin の単一 SSOT）を sys.path 解決して import するだけ。
#   CMDTOKENS_LIB が未設定/空/非絶対なら plugin 標準配置へ fallback（相対値の cwd 相対 poison を os.path.isabs で弾く）。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")
_cmdtokens_lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
if not os.path.isabs(_cmdtokens_lib):
    _cmdtokens_lib = _CMDTOKENS_DEFAULT_LIB
_cmdtokens_load_error = None
try:
    sys.path.insert(0, _cmdtokens_lib)
    from cmdtokens import iter_commands  # guard が実使用する公開 API はこれだけ
except Exception as e:  # lib ロード不能 → fail-open（guard 無効化を loud に通知）
    iter_commands = None
    _cmdtokens_load_error = e
    # self-test / introspection では exit せず main に RED 報告させ silent-green を断つ（bd-guard と同形）。
    if "--self-test" not in sys.argv and "--print-cmdtokens-lib" not in sys.argv:
        sys.stderr.write(f"[tmux-guard] cannot load cmdtokens lib, failing open: {e}\n")
        sys.exit(0)

# --- scribe_session lib（session self-scope・bd-write-guard と同一 SSOT）--------------------------------
_scribe_session_load_error = None
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
    from scribe_session import _is_scribe_guard_session
except Exception as e:  # 同梱 lib ロード不能 → fail-open（guard 無効化を loud に通知）
    _scribe_session_load_error = e

    def _is_scribe_guard_session(cwd):  # fallback: 常に False = guard 無効化 = fail-open
        return False
    if "--self-test" not in sys.argv and "--print-cmdtokens-lib" not in sys.argv:
        sys.stderr.write(f"[tmux-guard] cannot load scribe_session lib, failing open: {e}\n")
        sys.exit(0)

# worker 窓の接頭辞（protocol.md §1 命名規約 `wt-<id>`）。これ以外の window は管理窓とみなす。
WORKER_WINDOW_PREFIX = "wt-"

# tmux の global option のうち **次トークンを値として消費する** flag 文字（subcommand 同定で値を skip する）。
#   `tmux -L socket send-keys …` / `tmux -S /path send-keys …` / `tmux -T features send-keys …` 等の前置を
#   貫通する。これを欠くと値取り flag の次トークン（値）を subcommand と誤同定し管理窓 send-keys が fail-open
#   bypass する（sc-164 finding2）。判定は末尾 1 文字ヒューリスティックでなく `-` の後を左から char-scan する
#   （_global_flag_takes_value）: getopt は value-less global flag を束ねて末尾に値取り flag を置け（`-2T
#   features`＝2 が boolean, T が末尾→次が値）、値取り flag に値を glue もできる（`-f/x/tmux.conf` /
#   `-Tfeatures`＝f/T の後に残り文字→glued 値）。両者は末尾 1 文字では区別できず、glued 値が偶然 L/S/f/c/T で
#   終わると（`.conf` の末尾 `f` 等）誤って次トークンを消費し subcommand を誤同定する fail-open を生む
#   （sc-164 self-review finding1）。
TMUX_GLOBAL_VAL_FLAG_TAILS = frozenset("LSfcT")

# send-keys 判定は SEND_KEYS の exact set ではなく _is_send_keys_subcmd() 述語で行う（man tmux の
#   「shortest unambiguous form of a command is accepted」＝略記 send-k*/send-ke/send-key を漏らさないため）。

# send-keys の target フラグ `-t` を getopt バンドル短縮形まで含めて拾う正規表現（sc-164 finding1）。
#   value-less 短フラグ群 [FHKlMRX]（man tmux synopsis の -FHKlMRX 全 7 個）を任意個束ねた末尾に `t`、その後に
#   glued 値（あれば group1）。例: `-t`→group1='' / `-tADMIN`→'ADMIN' / `-lt`→'' / `-lRt`→'' / `-Xt`→'' /
#   `-ltADMIN`→'ADMIN'。value-less 群から `X`（copy-mode コマンド送出）を落とすと `-Xt admin:0` / `-lXt admin:0`
#   が fullmatch に失敗し target 抽出が空→現在窓解決に落ちて管理窓 send-keys を allow する fail-open だった
#   （sc-164 self-review finding2）。-N（値取り）は束に含めない＝`-Nt` は -N の値が `t` で target ではないため
#   fullmatch させない。
_SEND_KEYS_BUNDLED_T_RE = re.compile(r"-[FHKlMRX]*t(.*)")

# `-t` が全く無い send-keys（現在窓＝管理窓の可能性）を表す sentinel（None は「-t はあるが値欠落」に使う）。
_NO_TARGET = object()

# deny メッセージ（stderr・exit2 と対に出す）。scribe-inject 誘導と exit 3/4 握りつぶし禁止を含める（裁定 6）。
def _render(target):
    return (
        "DENIED(tmux): 管理窓（非 '" + WORKER_WINDOW_PREFIX + "' window）への生 tmux send-keys は禁止"
        "（transport 構造封鎖・sc-164）。対象 target: " + str(target) + "\n"
        "session 間送信は送達確認つき scribe-inject を必須とせよ: "
        "`scripts/scribe-inject.sh send --target <PANE> (--file F | --text T)`。"
        "生 send-keys は bracketed-paste 滞留・誤『送信済み』判定・Enter 未押下で silent に未送達となり得る"
        "（2026-07-08/09 の注入未送達 incident・sc-6vj）。scribe-inject の失敗コード "
        "exit 3(RESIDUAL=未送達) / exit 4(INCONCLUSIVE=確認不能) を握りつぶして成功扱いにするな"
        "（必ず fail-loud で対処）。worker 窓（'" + WORKER_WINDOW_PREFIX + "*'）への steering は封鎖対象外だが "
        "scribe-inject を推奨。\n"
    )


def _is_send_keys_subcmd(subcmd):
    """subcmd が send-keys か（documented alias `send` と、曖昧さの無い略記 send-k* / send-ke / send-key を含む）。
    man tmux: 「the shortest unambiguous form of a command is accepted」。send-* 系は send-keys / send-prefix の
    2 つのみゆえ 'send-k' 接頭辞は send-keys に一意解決する（'send-p' 系は send-prefix ＝非対象）。'send' は
    send-keys の documented alias（exact）。exact set 判定だと send-key/send-ke/send-k が deny を素通りする
    fail-open ホールになる（sc-164 finding1）。"""
    if not isinstance(subcmd, str) or not subcmd:
        return False
    if subcmd == "send":
        return True
    # send-keys の曖昧さ無し略記（send-k 以上・send-keys の接頭辞）。send-prefix は send-p ゆえ拾わない。
    return subcmd.startswith("send-k") and "send-keys".startswith(subcmd)


def _global_flag_takes_value(tok):
    """global option トークン（先頭 '-'）が **次トークンを値として消費する**か判定する。
    末尾 1 文字ヒューリスティックは bundled boolean+値flag（`-2T`＝次が値）と glued 値flag（`-f/x/tmux.conf`＝
    値内包で次を消費しない）を区別できず、glued 値が偶然 L/S/f/c/T で終わると誤って次トークンを消費し
    subcommand を誤同定する fail-open を生む（sc-164 self-review finding1: `.conf` の末尾 `f` 衝突）。先頭 '-'
    の後を左から走査し、最初に値取り flag 文字（L/S/f/c/T）へ当たった時点で分岐する: その文字が末尾なら次
    トークンが値（True）・残り文字があれば glued 値（False＝次を消費しない）。値取り flag に当たらなければ
    全 boolean 束（`-2u` 等）＝消費しない（False）。"""
    for idx in range(1, len(tok)):
        if tok[idx] in TMUX_GLOBAL_VAL_FLAG_TAILS:
            return idx == len(tok) - 1
    return False


def _subcommand_of(tokens):
    """tmux サブ invocation のトークン列（'tmux' を除いた argv、または `;` 区切りの 1 セグメント）から
    (subcmd, rest_args) を返す。global option とその値を skip して最初の非オプショントークンを subcommand と
    みなす。subcommand が無ければ (None, [])。"""
    i = 0
    n = len(tokens)
    while i < n:
        tok = tokens[i]
        if tok.startswith("-") and tok != "-":
            # 値取り global flag（末尾に置かれ次トークンが値）は次トークンを値として skip。glued 値flag
            # （`-Tfeatures` / `-f/x/tmux.conf`）は値内包ゆえ次を消費しない（_global_flag_takes_value）。
            i += 2 if _global_flag_takes_value(tok) else 1
            continue
        return tok, tokens[i + 1:]
    return None, []


def _tmux_subcommand(core):
    """core（basename=='tmux' の argv）の **最初の** サブ invocation の (subcmd, rest_args) を返す
    （global option とその値を skip）。subcommand が無ければ (None, [])。"""
    return _subcommand_of(core[1:])


def _iter_tmux_invocations(core):
    """core（basename=='tmux' の argv）を tmux 内 `;` トークンで分割し、各サブ invocation の
    (subcmd, rest_args) を yield する。tmux は 1 回の起動で `;`（shell では `\\;` / `';'`）区切りの複数
    コマンドを実行できる標準機能を持つため、最初の subcommand だけ見ると後続 `; send-keys …` が素通りする
    fail-open になる（sc-164 finding2）。cmdtokens.iter_commands は `\\;` を同一 command 内の literal
    トークン `;` として保持するので、それを境界に分割して全セグメントを走査する。"""
    seg = []
    for tok in core[1:]:
        if tok == ";":
            yield _subcommand_of(seg)
            seg = []
        else:
            seg.append(tok)
    yield _subcommand_of(seg)


def _extract_targets(rest):
    """send-keys の args 列から **すべての** `-t` の値をリストで返す。`-t VALUE`（分離）・`-tVALUE`（glued）に
    加え、getopt バンドル短縮形（`-lt VALUE` / `-lRt VALUE` / `-ltVALUE`）へも対応する。`-t` が値欠落なら
    要素 None（malformed → 解決不能扱い）。target 指定が全く無ければ空リスト。
    tmux(send-keys) の getopt は value-less 短フラグ（-F/-H/-K/-l/-M/-R/-X）を束ねられ、束の末尾に値取りの `-t`
    を置ける（`-l`＝literal は send-keys 最頻フラグ）。`-t` 完全一致か `-t` glued 接頭辞しか拾わない旧実装は
    `-lt admin:0` を target 空と誤読し管理窓 send-keys が deny を素通りする fail-open ホールだった（sc-164
    finding1）。value-less 群から `X` を落とすと `-Xt admin:0` も同じ fail-open になる（sc-164 self-review
    finding2）。値取り短フラグは -N と -t のみで、-N を束末尾に許すと次トークンが -N の値になり target 抽出を
    誤らせるため、束は value-less 群 [FHKlMRX] の後に `t` が来る形（_SEND_KEYS_BUNDLED_T_RE）に限定する。
    tmux(send-keys) の getopt は `-t` を後勝ちで上書きするため（`-t wt-x -t admin:0` の実効 target は admin:0）、
    最初の `-t` だけを採ると管理窓 send-keys が素通りする fail-open になる（sc-164 finding3）。決定は
    _decide_send_keys 側で「全 `-t` が worker 窓なら allow・非 worker 候補が 1 つでもあれば解決して判定」と
    fail-closed に倒す。全 `-t` を採る（過剰採取＝keys 領域の literal `-t` 相当を拾っても deny 方向で安全）。"""
    out = []
    i = 0
    n = len(rest)
    while i < n:
        tok = rest[i]
        if tok.startswith("--"):  # 長オプション（tmux は send-keys に持たない）は素通し
            i += 1
            continue
        m = _SEND_KEYS_BUNDLED_T_RE.fullmatch(tok)
        if m is not None:
            glued = m.group(1)
            if glued:  # `-tVALUE` / `-ltVALUE`（束末尾 `t` に値が glued）
                out.append(glued)
                i += 1
            else:      # `-t` / `-lt` / `-lRt`（値は分離＝次トークン）
                out.append(rest[i + 1] if i + 1 < n else None)
                i += 2 if i + 1 < n else 1
            continue
        i += 1
    return out


def _literal_worker_target(target):
    """target の window 指定子が literal に 'wt-' で始まる（tmux read 不要の fast-path allow）か。
    window 指定子 = 最後の ':' の後ろ（`session:window`）で、exact-match の '=' 接頭辞は剥ぐ。dotted 名
    （`wt-un-3sh.3.5`）も接頭辞一致で拾う。allow 方向専用（誤分類でも tmux 解決へ落ちるだけ＝安全）。"""
    if not isinstance(target, str) or not target:
        return False
    win = target.rsplit(":", 1)[-1]
    if win.startswith("="):
        win = win[1:]
    return win.startswith(WORKER_WINDOW_PREFIX)


def _tmux_bin():
    return os.environ.get("SCRIBE_TMUX") or "tmux"


def _run_tmux(args, timeout=4):
    """tmux を read-only で起動。到達/実行不能（バイナリ不在・timeout 等）は None を返す。"""
    try:
        return subprocess.run(
            [_tmux_bin(), *args], capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def _tmux_reachable():
    """tmux server へ到達可能か（tmux 外/ server 無/ バイナリ不在なら False）。target 不要の probe。"""
    p = _run_tmux(["display-message", "-p", "#{socket_path}"])
    return p is not None and p.returncode == 0


def _resolve_window_name(target):
    """target の window 名を tmux で解決する。解決不能（rc!=0・空・到達不能・malformed）は None。
    -t 無し（_NO_TARGET）は現在窓の #{window_name} を引く。"""
    if target is _NO_TARGET:
        args = ["display-message", "-p", "#{window_name}"]
    elif not target:  # None（-t 値欠落）→ 解決不能
        return None
    else:
        args = ["display-message", "-p", "-t", target, "#{window_name}"]
    p = _run_tmux(args)
    if p is not None and p.returncode == 0:
        name = p.stdout.strip()
        return name or None
    return None


def _decide_single_target(target):
    """単一 target（str / None / _NO_TARGET）を tmux 解決して (block, reason_target) を返す。
    literal 'wt-' の fast-path 判定は呼び元（_decide_send_keys）が担うため、ここでは常に解決を試みる。"""
    name = _resolve_window_name(target)
    if name is not None:
        if name.startswith(WORKER_WINDOW_PREFIX):
            return False, ""      # worker 窓 → 封鎖対象外
        return True, name          # 管理窓 → deny
    # 解決不能: 到達不能（allow・実行不能ゆえ実害なし）と 到達可だが判定不能（deny・fail-closed）を弁別。
    if not _tmux_reachable():
        return False, ""
    return True, (target if isinstance(target, str) else "<current-window>")


def _decide_send_keys(targets):
    """send-keys の全 `-t` 値リスト（_extract_targets の返り）から (block: bool, reason_target: str) を返す。
    block=True → deny(exit2)。判定（sc-164 finding3・tmux getopt は `-t` 後勝ち）:
      - `-t` 無し（空リスト）→ 現在窓を解決して判定（管理窓 or 解決不能&到達可 → deny）。
      - `-t` が **すべて** literal 'wt-' → allow（worker 窓明示・tmux read 不要の fast-path）。
      - それ以外（非 worker 候補が混在）→ 各非 literal-worker 候補を tmux 解決し、1 つでも管理窓/解決不能&到達可
        なら deny（fail-closed・過剰採取した keys 領域の候補も deny 方向で安全）。実効 target が管理窓でも
        first-`-t` を採る旧実装は allow 素通ししていた（finding3）。"""
    if not targets:
        return _decide_single_target(_NO_TARGET)
    # fast-path allow: すべての `-t` が literal 'wt-' 指定子（tmux read 不要・worker 窓明示）。
    if all(isinstance(t, str) and _literal_worker_target(t) for t in targets):
        return False, ""
    # 混在: 非 literal-worker 候補を解決。1 つでも deny 該当なら deny（fail-closed）。
    for t in targets:
        if isinstance(t, str) and _literal_worker_target(t):
            continue  # この候補は worker 窓確定 → skip
        block, tgt = _decide_single_target(t)
        if block:
            return True, tgt
    return False, ""


def classify(cmd, cwd):
    """cmd 中の最初に違反する tmux send-keys を (2, reason) で返す。違反無し/解析不能は (0, "")。
    session 非依存の純判定（self-scope は main_decide が別層で被せる）。"""
    if not cmd or iter_commands is None:
        return 0, ""
    for core, _seg_cwd in iter_commands(cmd, cwd):
        if not core or os.path.basename(core[0]) != "tmux":
            continue  # tmux 以外（scribe-inject.sh 等）は対象外＝そのまま通過
        # tmux 内 `;` 区切りの各サブ invocation を走査（後続 `; send-keys …` の bypass を塞ぐ・finding2）。
        for subcmd, rest in _iter_tmux_invocations(core):
            if not _is_send_keys_subcmd(subcmd):
                continue  # send-keys/send（略記含む）以外（capture-pane 等 read）は対象外
            block, tgt = _decide_send_keys(_extract_targets(rest))
            if block:
                return 2, _render(tgt)
    return 0, ""


def main_decide(cmd, cwd):
    """session self-scope を被せた最終判定（裁定 2）。非 scribe session（dolt_database!='sc'・判定不能含む）
    では一切判定せず (0, "") で no-op（plugin global enable 時に foreign session を brick しない）。
    判定基準は session cwd（hook payload top-level cwd）。present-but-unreadable は fail-closed。"""
    if not _is_scribe_guard_session(cwd):
        return 0, ""
    return classify(cmd, cwd)


def main():
    # consume preamble introspection（preamble self-test が subprocess 経由で問う隠しフラグ）。
    if "--print-cmdtokens-lib" in sys.argv:
        if iter_commands is None:
            sys.stderr.write(f"[tmux-guard] cmdtokens load failed: {_cmdtokens_load_error}\n")
            return 1
        sys.stdout.write(sys.modules["cmdtokens"].__file__ + "\n")
        return 0
    if "--self-test" in sys.argv:
        if iter_commands is None:
            print(f"FAIL: [preamble] cmdtokens load 失敗（既定/解決 path 不正）: {_cmdtokens_load_error}")
            print("tmux-guard self-test: ABORTED (cmdtokens 未 load)")
            return 1
        return run_self_test()
    try:
        # 非UTF-8 raw stdin の UnicodeDecodeError も含め入力解析例外は fail-open(exit0)へ倒す（bd-guard と同方針）。
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        data = json.loads(raw) if raw.strip() else {}
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
        cwd = data.get("cwd") or os.getcwd()
    except Exception as e:
        sys.stderr.write(f"[tmux-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg = main_decide(cmd, cwd)
    except Exception as e:  # guard クラッシュは fail-open（exit0+warn・裁定 5）。
        sys.stderr.write(f"[tmux-guard] internal error, failing open: {e}\n")
        return 0
    if msg:
        sys.stderr.write(msg)
    return code


# ==========================================================================================
# in-process 自己テスト（python3 tmux-send-keys-guard.py --self-test）。
#   純パーサ（subcommand/target 抽出・literal fast-path）+ session self-scope（temp ledger）+ 完全判定
#   （stub tmux を SCRIBE_TMUX で差し替え・解決/到達 の分岐を実走）を hermetic に pin する。
# ==========================================================================================
def _write_stub_tmux(path, resolves, reachable=True):
    """stub tmux を path に書く。resolves = {target: window_name}（未登録 target は解決失敗=exit1）。
    reachable=False なら socket probe も exit1（到達不能）。SCRIBE_TMUX 経由で guard が起動する。"""
    lines = ["#!/usr/bin/env bash", 'args="$*"']
    if reachable:
        lines.append('case "$args" in *"#{socket_path}"*) echo /tmp/stub-sock; exit 0 ;; esac')
    else:
        lines.append('case "$args" in *"#{socket_path}"*) exit 1 ;; esac')
    # -t の値を拾う。
    lines += [
        'tgt=""; prev=""',
        'for a in "$@"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; done',
        'case "$tgt" in',
    ]
    for tk, name in resolves.items():
        lines.append(f'  {tk}) echo "{name}"; exit 0 ;;')
    lines += ['  *) exit 1 ;;', 'esac']
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(path, 0o755)


def run_self_test():
    import tempfile
    import shutil

    failures = []

    def check(cond, label):
        if not cond:
            failures.append(label)

    # --- (1) 純パーサ: subcommand 同定 --------------------------------------------------------------
    check(_tmux_subcommand(["tmux", "send-keys", "-t", "x", "y"]) == ("send-keys", ["-t", "x", "y"]),
          "(1) 素の send-keys subcommand 同定")
    check(_tmux_subcommand(["tmux", "-L", "sock", "send-keys", "-t", "x"])[0] == "send-keys",
          "(1) global -L 値付き前置を貫通して send-keys 同定")
    check(_tmux_subcommand(["tmux", "-2", "-u", "capture-pane", "-p"])[0] == "capture-pane",
          "(1) bool global flag 前置を貫通して capture-pane 同定")
    # finding2 回帰: 値取り global flag `-T features`（tmux 3.4）とその bundled 短縮 `-2T` を skip して同定。
    check(_tmux_subcommand(["tmux", "-T", "256", "send-keys", "-t", "x"])[0] == "send-keys",
          "(1/f2) global -T 値付き前置を貫通して send-keys 同定")
    check(_tmux_subcommand(["tmux", "-2T", "256", "send-keys", "-t", "x"])[0] == "send-keys",
          "(1/f2) bundled -2T 値付き前置を貫通して send-keys 同定")
    # self-review finding1 回帰: glued 値flag（末尾が値取り flag 文字 L/S/f/c/T と衝突）を値内包扱いし誤同定しない。
    check(_global_flag_takes_value("-2T") is True, "(1/sr1) -2T 末尾 T→次トークンが値（消費する）")
    check(_global_flag_takes_value("-L") is True, "(1/sr1) -L 末尾 L→次トークンが値（消費する）")
    check(_global_flag_takes_value("-f/x/tmux.conf") is False,
          "(1/sr1) -f/x/tmux.conf は f の後に残り文字→glued 値（次を消費しない）")
    check(_global_flag_takes_value("-Tfeatures") is False,
          "(1/sr1) -Tfeatures は T の後に残り文字→glued 値（次を消費しない）")
    check(_global_flag_takes_value("-2u") is False, "(1/sr1) -2u 全 boolean 束→消費しない")
    check(_tmux_subcommand(["tmux", "-f/x/tmux.conf", "send-keys", "-t", "x"])[0] == "send-keys",
          "(1/sr1) glued 値flag `-f/x/tmux.conf`（末尾 f 衝突）を貫通して send-keys 同定")
    check(_tmux_subcommand(["tmux", "-Tfeatures", "send-keys", "-t", "x"])[0] == "send-keys",
          "(1/sr1) glued 値flag `-Tfeatures` を貫通して send-keys 同定")

    # --- (2) 純パーサ: target 抽出（全 `-t` を採る・finding3）----------------------------------------
    check(_extract_targets(["-t", "admin:0", "hi", "Enter"]) == ["admin:0"], "(2) -t 分離 target 抽出")
    check(_extract_targets(["-tadmin:0", "hi"]) == ["admin:0"], "(2) -t glued target 抽出")
    check(_extract_targets(["-l", "hi"]) == [], "(2) -t 無し → 空リスト")
    check(_extract_targets(["-t"]) == [None], "(2) -t 値欠落 → [None]")
    check(_extract_targets(["-t", "wt-x", "-t", "admin:0"]) == ["wt-x", "admin:0"],
          "(2/f3) 複数 -t を全採取（last-wins 判定は decide 層）")
    # finding1 回帰: getopt バンドル短縮形（-lt / -lRt / -ltVALUE）でも target を採取する。
    check(_extract_targets(["-lt", "admin:0", "hi", "Enter"]) == ["admin:0"],
          "(2/f1) バンドル -lt 分離 target 抽出")
    check(_extract_targets(["-lRt", "@3", "hi"]) == ["@3"], "(2/f1) バンドル -lRt 分離 target 抽出")
    check(_extract_targets(["-ltadmin:0", "hi"]) == ["admin:0"], "(2/f1) バンドル -lt glued target 抽出")
    check(_extract_targets(["-Nt", "5"]) == [], "(2/f1) -Nt は -N の値=t で target 非該当（誤採取しない）")
    # self-review finding2 回帰: value-less 束に -X（copy-mode）を含める。
    check(_extract_targets(["-Xt", "admin:0", "hi"]) == ["admin:0"], "(2/sr2) バンドル -Xt 分離 target 抽出")
    check(_extract_targets(["-lXt", "admin:0", "hi"]) == ["admin:0"], "(2/sr2) バンドル -lXt 分離 target 抽出")
    check(_extract_targets(["-Xtadmin:0", "hi"]) == ["admin:0"], "(2/sr2) バンドル -Xt glued target 抽出")

    # --- (2b) send-keys 略記/alias 判定（finding1）--------------------------------------------------
    check(_is_send_keys_subcmd("send-keys") is True, "(2b) send-keys → 対象")
    check(_is_send_keys_subcmd("send") is True, "(2b) alias send → 対象")
    check(_is_send_keys_subcmd("send-key") is True, "(2b/f1) 略記 send-key → 対象")
    check(_is_send_keys_subcmd("send-ke") is True, "(2b/f1) 略記 send-ke → 対象")
    check(_is_send_keys_subcmd("send-k") is True, "(2b/f1) 略記 send-k → 対象")
    check(_is_send_keys_subcmd("send-prefix") is False, "(2b/f1) send-prefix → 非対象")
    check(_is_send_keys_subcmd("send-p") is False, "(2b/f1) send-p（send-prefix 略記）→ 非対象")
    check(_is_send_keys_subcmd("capture-pane") is False, "(2b) capture-pane → 非対象")

    # --- (2c) tmux `;` コマンド列の分割走査（finding2）---------------------------------------------
    _seq = ["tmux", "select-window", "-t", "admin", ";", "send-keys", "-t", "admin:0", "hi", "Enter"]
    _subs = [sc for sc, _ in _iter_tmux_invocations(_seq)]
    check("select-window" in _subs and any(_is_send_keys_subcmd(s) for s in _subs),
          "(2c/f2) `;` 列の後続 send-keys を分割走査で検出")

    # --- (3) literal 'wt-' fast-path allow ---------------------------------------------------------
    check(_literal_worker_target("wt-sc-164") is True, "(3) literal wt- 名 → allow")
    check(_literal_worker_target("sess:wt-sc-164") is True, "(3) session:wt- → allow")
    check(_literal_worker_target("=wt-sc-164") is True, "(3) =wt- exact → allow")
    check(_literal_worker_target("wt-un-3sh.3.5") is True, "(3) dotted wt- 名 → allow")
    check(_literal_worker_target("admin:0") is False, "(3) admin:0 は fast-path 非該当")
    check(_literal_worker_target("@3") is False, "(3) @3 は fast-path 非該当")

    # --- (4) 完全判定: stub tmux（解決 & 到達分岐）--------------------------------------------------
    _root = tempfile.mkdtemp(prefix="tmux-guard-st-")
    _saved_tmux = os.environ.get("SCRIBE_TMUX")
    try:
        stub_ok = os.path.join(_root, "tmux-reachable")
        _write_stub_tmux(stub_ok, {"@3": "admin", "@7": "wt-sc-1", "admin:0": "admin"}, reachable=True)
        stub_unreach = os.path.join(_root, "tmux-unreachable")
        _write_stub_tmux(stub_unreach, {}, reachable=False)

        os.environ["SCRIBE_TMUX"] = stub_ok
        check(_decide_send_keys(["@3"])[0] is True, "(4) @3→admin（管理窓）→ deny")
        check(_decide_send_keys(["@7"])[0] is False, "(4) @7→wt-sc-1（worker 窓）→ allow")
        check(_decide_send_keys(["admin:0"])[0] is True, "(4) admin:0→admin → deny")
        check(_decide_send_keys(["wt-sc-164"])[0] is False, "(4) literal wt- fast-path → allow(tmux 未使用)")
        # 到達可だが未登録 target（解決不能）→ fail-closed deny。
        check(_decide_send_keys(["@99"])[0] is True, "(4) 到達可 & 解決不能 → deny(fail-closed)")
        # -t 無し（現在窓解決不能・到達可）→ deny。
        check(_decide_send_keys([])[0] is True, "(4) -t 無し & 到達可 & 解決不能 → deny")
        # finding3 回帰: 複数 -t は tmux getopt last-wins。first が wt- でも非 worker 候補があれば deny。
        check(_decide_send_keys(["wt-sc-1", "admin:0"])[0] is True,
              "(4/f3) -t wt-sc-1 -t admin:0（混在）→ deny（旧 first-t allow の穴）")
        check(_decide_send_keys(["wt-sc-1", "@7"])[0] is False,
              "(4/f3) -t wt-sc-1 -t @7（両 worker 窓）→ allow")
        check(_decide_send_keys(["wt-sc-1", "wt-x"])[0] is False,
              "(4/f3) 全 -t が literal wt- → allow(fast-path)")

        os.environ["SCRIBE_TMUX"] = stub_unreach
        check(_decide_send_keys(["@3"])[0] is False, "(4) tmux 到達不能 → allow(実行不能ゆえ実害なし)")
        check(_decide_send_keys([])[0] is False, "(4) 到達不能 & -t 無し → allow")

        # --- (5) classify e2e（compound / launcher / read subcmd / scribe-inject / 難読化）----------
        os.environ["SCRIBE_TMUX"] = stub_ok
        _scw = os.path.join(_root, "scdir")
        os.makedirs(os.path.join(_scw, ".beads"))
        with open(os.path.join(_scw, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            json.dump({"database": "dolt", "dolt_database": "sc"}, f)

        def blocks(cmd, cwd=_scw):
            return main_decide(cmd, cwd)[0] == 2

        check(blocks("tmux send-keys -t @3 hi Enter"), "(5) 素の管理窓 send-keys → block")
        check(blocks("echo x && tmux send-keys -t admin:0 hi Enter"), "(5) compound (&&) 中でも block")
        check(blocks("bash -c 'tmux send-keys -t @3 hi Enter'"), "(5) bash -c 経由でも block")
        check(blocks("a; tmux send -t @3 hi"), "(5) send alias + `;` 難読化でも block")
        # finding1 回帰: send-keys の曖昧さ無し略記/alias（send-key/send-ke/send-k）も block。
        check(blocks("tmux send-key -t @3 hi Enter"), "(5/f1) 略記 send-key → block")
        check(blocks("tmux send-ke -t admin:0 hi Enter"), "(5/f1) 略記 send-ke → block")
        check(blocks("tmux send-k -t @3 hi Enter"), "(5/f1) 略記 send-k → block")
        check(not blocks("tmux send-prefix -t @3"), "(5/f1) send-prefix は非対象 → allow")
        # finding2 回帰: tmux `;` コマンド列の後続 send-keys（管理窓）も block。
        check(blocks(r"tmux select-window -t @7 \; send-keys -t admin:0 evil Enter"),
              "(5/f2) tmux `;` 列の後続 send-keys（管理窓）→ block")
        # finding3 回帰: 複数 -t の実効 target（last-wins）が管理窓なら block。
        check(blocks("tmux send-keys -t wt-sc-164 -t admin:0 hi Enter"),
              "(5/f3) -t wt- -t admin:0（実効 admin:0）→ block")
        # self-review finding1 回帰: getopt バンドル短縮形（-lt / -lRt / -ltVALUE）実効 target が管理窓 → block。
        check(blocks("tmux send-keys -lt admin:0 hi Enter"),
              "(5/bundle) -lt admin:0（束 -l+-t）→ block")
        check(blocks("tmux send-keys -lRt @3 evil Enter"),
              "(5/bundle) -lRt @3（束 -l-R+-t）→ block")
        check(blocks("tmux send-keys -ltadmin:0 hi Enter"),
              "(5/bundle) -ltadmin:0（束+glued 値）→ block")
        check(not blocks("tmux send-keys -lt wt-sc-164 hi Enter"),
              "(5/bundle) -lt wt-sc-164（worker 窓）→ allow")
        # self-review finding2 回帰: value-less 束の -X（copy-mode）を含む短縮形でも管理窓 → block。
        check(blocks("tmux send-keys -Xt admin:0 evil Enter"),
              "(5/sr2) -Xt admin:0（束 -X+-t）→ block")
        check(blocks("tmux send-keys -lXt admin:0 evil Enter"),
              "(5/sr2) -lXt admin:0（束 -l-X+-t）→ block")
        check(not blocks("tmux send-keys -Xt wt-sc-164 hi Enter"),
              "(5/sr2) -Xt wt-sc-164（worker 窓）→ allow")
        # self-review finding1 回帰: glued 値flag（末尾 f/L/S/c/T 衝突）前置でも管理窓 send-keys → block。
        check(blocks(r"tmux -f/x/tmux.conf send-keys -t admin:0 evil Enter"),
              "(5/sr1) glued 値flag -f/x/tmux.conf 前置でも管理窓 send-keys → block")
        # finding2 回帰: 値取り global flag `-T` とその bundled 短縮 `-2T` 前置でも管理窓 → block。
        check(blocks("tmux -T 256 send-keys -t admin:0 evil Enter"),
              "(5/globalT) -T 前置でも管理窓 send-keys → block")
        check(blocks("tmux -2T 256 send-keys -t @3 evil Enter"),
              "(5/globalT) bundled -2T 前置でも管理窓 send-keys → block")
        check(not blocks("tmux send-keys -t @7 hi Enter"), "(5) worker 窓(@7→wt-) → allow")
        check(not blocks("tmux send-keys -t wt-sc-164 hi Enter"), "(5) literal wt- 窓 → allow")
        check(not blocks("tmux capture-pane -p -t @3"), "(5) capture-pane(read) → allow")
        check(not blocks('echo "tmux send-keys -t admin:0 hi"'),
              "(5) echo クォート内 send-keys は誤検出しない")
        check(not blocks("scripts/scribe-inject.sh send --target admin:0 --text hi"),
              "(5) scribe-inject 呼出行（basename!=tmux）は通す")

        # --- (6) session self-scope: foreign session では管理窓 send-keys も no-op --------------------
        _fw = os.path.join(_root, "orchdir")
        os.makedirs(os.path.join(_fw, ".beads"))
        with open(os.path.join(_fw, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            json.dump({"database": "dolt", "dolt_database": "orch"}, f)
        check(main_decide("tmux send-keys -t admin:0 hi Enter", _fw)[0] == 0,
              "(6) foreign(orch) session → no-op（orchestrator を brick しない）")

        # --- (7) 非vacuous 弁別: 同 cmd が sc では block・orch では allow ------------------------------
        check(blocks("tmux send-keys -t @3 hi Enter") and
              main_decide("tmux send-keys -t @3 hi Enter", _fw)[0] == 0,
              "(7) self-scope が非vacuous（sc=block / orch=no-op）")
    finally:
        if _saved_tmux is None:
            os.environ.pop("SCRIBE_TMUX", None)
        else:
            os.environ["SCRIBE_TMUX"] = _saved_tmux
        shutil.rmtree(_root, ignore_errors=True)

    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"tmux-guard self-test: {len(failures)} FAILED")
        return 1
    print("tmux-guard self-test: ALL PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

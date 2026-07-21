#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook: 管理窓（非 'wt-' window）への **生 tmux transport**（send-keys / paste-buffer /
#   load-buffer / run-shell / pipe-pane -I ＋ それらを payload に包む exec carrier）を機械 block（exit 2）し、
#   session 間送信を送達確認つき `scripts/scribe-inject.sh` 経由へ funnel する（transport 構造封鎖）。
#   ファイル名は sc-164 由来の歴史的名称（現在の scope は send-keys に限らない＝下記 transport 表）。
# 由来: sc-164（orch-eaj courier 荷6 = sc-flk attention-hub 裁定の B「transport 構造封鎖」の scribe 分担）。
#   sc-2g3: send-keys 以外の transport（paste-buffer / load-buffer / run-shell 等）へ同一境界判定を拡張。
#   正本 = scriptorium top-spec §5.3 末尾「sc-flk との突合」＋ consult 裁定 doobidoo 3e91c1e1。
#   背景 incident（sc-6vj）: 生 send-keys は bracketed-paste 滞留・誤『送信済み』判定・Enter 未押下で silent に
#   未送達となり、2026-07-08/09 に admin 操舵注入の未送達が実発生した。scribe-inject.sh は送達確認（残留検知）
#   つきの唯一の正路で、失敗を exit 3(RESIDUAL=未送達)/exit 4(INCONCLUSIVE=確認不能)で fail-loud する。本 guard は
#   その必須化の「機械実体」＝生 send-keys を PreToolUse 層で塞ぐ（scribe-inject 内部の send-keys は subprocess
#   ゆえ PreToolUse は再発火せず自然に通る＝この構造が「scribe-inject 必須化」を成す・下記 J4）。
#
# 構造は既存 guard（git-destructive-guard.py / rm-destructive-guard.py）を踏襲する。本 guard の設計時点では
#   bespoke な bd-write-guard.py も同構造の 3 本目として在ったが、bd write の堀は universal beads-bdw plugin 側
#   へ移管され bespoke 版は撤去済（un-2uap Leg-R-sc）＝現行 scribe の PreToolUse[Bash] guard は上記 2 本 + 本 guard:
#   - トークナイザは publish 済 cmdtokens plugin の canonical lib を consume する（下記 consume preamble）。
#   - session self-scope（scribe_session._is_scribe_guard_session・fail-closed）で dolt_database=='sc' session
#     のみ発火し、foreign（orchestrator の 'orch' 等）session では exit0 no-op＝orchestrator 自身の spawn/inject
#     運用を絶対に brick しない（sc-164 admin 裁定 2）。
#
# KNOWN RISK（consume 設計の既知性質・全 guard 共通）: cmdtokens plugin 不在ホストでは lib ロードに失敗し guard が
#   fail-open（exit 0・loud stderr）で素通しになる（transport 封鎖が silent に無効化）。SessionStart guard-health
#   banner は cmdtokens 不在を loud 化するが、その列挙は例示的で本 guard 名を含まない（かつて同居した bespoke
#   bd-write-guard も同様に未列挙だった＝banner は cmdtokens consumer の網羅リストではない・precedent 準拠）。
#
# 方式（sc-164 admin 裁定 3/7・token 検査は subcommand の位置に依存しない）: コマンド文字列を共有
#   lib(cmdtokens.iter_commands)で shlex トークン化し、**本物の `tmux` 呼び出しのトークン列にのみ**ルールを
#   適用する。パイプ/セミコロン/改行で紛れても検出し（`x | tmux send-keys …`・`a; tmux send …`）、launcher
#   (sudo/env/timeout/flock…) / `bash -c "…"` / eval / su -c 等の経由も lib が貫通する。クォート内データ
#   （`echo "tmux send-keys …"`）は shlex が 1 トークン化＝basename が echo になり誤検出しない（cmdtokens が構造
#   的に排除）。documented alias（`send` / `pasteb` / `run` …）と曖昧さの無い略記も対象に含める。
#   **capture-pane（read-only 監視）は対象外**＝admin の pane 監視を絶対に壊さない。
#
# transport 表（sc-2g3・send-keys 以外の transport 封鎖）: 管理窓への非確認送信路は send-keys だけではない。
#   下表の subcommand を **同一の境界判定**（wt- 接頭辞 / self-scope / fail-closed）で封鎖する。flag 表は
#   man tmux(3.4) の synopsis を verified に転記したもの（getopt 束を正しく解くのに必須＝下記 _scan_opts）:
#     send-keys   [-FHKlMRX] [-c target-client] [-N repeat-count] [-t target-pane] key …   (alias: send)
#     paste-buffer[-dpr] [-b buffer-name] [-s separator] [-t target-pane]                  (alias: pasteb)
#     load-buffer [-w] [-b buffer-name] [-t target-client] path                            (alias: loadb)
#     run-shell   [-bC] [-c start-directory] [-d delay] [-t target-pane] [shell-command]   (alias: run)
#     pipe-pane   [-IOo] [-t target-pane] [shell-command]                                  (alias: pipep)
#   - **paste-buffer**: buffer の中身を対象 pane へ「貼る」＝生 send-keys と等価な入力注入（`-t` は pane）。
#   - **load-buffer**: `-t` は **target-client**（pane ではない）で、`-w` 時にその client のクリップボードへ送る
#     だけ＝pane への配送を持たない。よって **`-t` 無しの load-buffer は allow**（＝buffer への staging のみ。
#     配送は paste-buffer が担い、それが管理窓宛なら deny されるので二段ベクタ〔load→paste〕は閉じる）。ここを
#     deny にすると worker 窓宛の正当な合成フロー（`load-buffer … && paste-buffer -t wt-x`）まで壊れる。
#     `-t <client>` 付きは client の現在 window を解決し、管理窓なら deny（同一境界）。
#   - **run-shell**: `-t` 管理窓は deny。ただし `-t` は format 展開の文脈でしかなく **実効の注入先を縛らない**ため
#     target 判定だけでは不十分（`run-shell -t wt-x 'tmux send-keys -t admin:0 evil'` が素通りする）→ payload の
#     再帰検査（下記 exec carrier）で塞ぐ。**`-t` 無しの bare run-shell は allow**（no_target='allow'・sc-2g3
#     self-review）＝配送先を持たず pane へ何も注入しない（実注入は payload で exec carrier 再帰が担う）。現在窓
#     （admin）解決 deny にすると `tmux run-shell 'cmd'` の正当な運用を壊す over-block 回帰になるため。
#   - **pipe-pane は `-I` のときだけ transport**（man: 「with -I stdout is connected (so anything shell-command
#     prints is written to the pane as if it were typed)」＝typed 相当の直接注入）。`-O`/既定は pane 出力の
#     read piping ＝**read 系ゆえ allow**（監視を壊さない）。
#
# exec carrier の payload 再帰（sc-2g3）: tmux が payload を /bin/sh（`-C` 時は tmux コマンド）として実行する
#   subcommand（run-shell / if-shell / new-window / split-window / new-session / respawn-pane / respawn-window /
#   display-popup / pipe-pane）は、その payload 内の `tmux send-keys …` を **PreToolUse 非再発火のまま**実行できる
#   ＝guard の完全な迂回路になる。よって payload 引数を (a) shell 文字列 (b) tmux コマンド文字列（`tmux ` を前置＝
#   `-C` / if-shell の command 引数用）の両解釈で **同じ classify に再帰**させる（深さ上限 MAX_NEST_DEPTH）。
#   再帰は **新たな無条件 deny を一切増やさない**（payload 自体が管理窓 transport のときだけ deny）ゆえ
#   false-positive は構造的に増えない。
#
# KNOWN GAP（本 guard は構造 funnel であって airtight sandbox ではない・follow-up 候補）: 遅延実行の command
#   carrier（`bind-key` / `set-hook` / `command-prompt` / `confirm-before`）と `source-file`（外部ファイル内の
#   tmux コマンドは静的に読めない）は未封鎖。payload が静的に解けない形（`tmux run-shell "$CMD"`）も、素の shell
#   での `bash -c "$CMD"` と同じく貫通する（トークナイザの原理的限界＝既存 guard 群と同じ性質）。
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
# 設計（依存: os/sys/json/subprocess + consume lib）: 入力解析例外・内部例外は握り潰して fail-open(exit0)。
#   tmux 解決は subprocess（read-only な display-message のみ・timeout 付き）で、テスト seam は SCRIBE_TMUX。

import sys
import os
import json
import subprocess

# --- cmdtokens consume preamble（撤去済 bespoke bd-write-guard 由来の薄い解決層・全 guard 共通形）-----------
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

# --- scribe_session lib（session self-scope の共有 SSOT・撤去済 bespoke bd-write-guard 由来）--------------
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

# subcommand 別の短オプション表（man tmux 3.4 synopsis を verified 転記・_scan_opts が getopt 束を解くのに使う）。
#   VALUELESS = 値を取らない boolean 短フラグ（束ねられる）/ VALUETAKING = 次トークンまたは glued 文字列を値として
#   取る短フラグ（束の末尾にしか置けない）。両者を subcommand ごとに正しく持たないと `-t` 抽出が壊れる:
#   value-less 群の取りこぼしは `-lt admin:0` 等の束を読めず target 空→ fail-open（sc-164 finding1/self-review
#   finding2 と同型）、値取り flag の取りこぼしは その値（例 `-b t`）を flag と誤読して target を誤採取する。
_SEND_KEYS_VALUELESS, _SEND_KEYS_VALUETAKING = "FHKlMRX", "cNt"        # -c=target-client, -N=repeat-count
_PASTE_BUFFER_VALUELESS, _PASTE_BUFFER_VALUETAKING = "dpr", "bst"      # -b=buffer, -s=separator
_LOAD_BUFFER_VALUELESS, _LOAD_BUFFER_VALUETAKING = "w", "bt"           # -t=target-**client**（pane ではない）
_RUN_SHELL_VALUELESS, _RUN_SHELL_VALUETAKING = "bC", "cdt"             # -C=tmux コマンド解釈, -d=delay
_PIPE_PANE_VALUELESS, _PIPE_PANE_VALUETAKING = "IOo", "t"              # -I=pane 入力へ書込（typed 相当）

# `-t` が全く無い呼出（現在窓＝管理窓の可能性）を表す sentinel（None は「-t はあるが値欠落」に使う）。
_NO_TARGET = object()

# deny メッセージ（stderr・exit2 と対に出す）。scribe-inject 誘導と exit 3/4 握りつぶし禁止を含める（裁定 6）。
def _render(target, subcmd="send-keys"):
    return (
        "DENIED(tmux): 管理窓（非 '" + WORKER_WINDOW_PREFIX + "' window）への生 tmux " + str(subcmd) + " は禁止"
        "（transport 構造封鎖・sc-164/sc-2g3）。対象 target: " + str(target) + "\n"
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


def _scan_opts(rest, valueless, valuetaking, target_flag="t"):
    """subcommand の args 列を getopt 規則で左から走査し (targets, flags) を返す（sc-2g3 で汎用化）。
      - targets: `target_flag`（既定 `-t`）の値を **出現順に全て**（分離 `-t V` / glued `-tV` / 束末尾 `-ltV`）。
        値欠落は要素 None（malformed → 解決不能扱い）。target 指定が無ければ空リスト。
      - flags: 出現した value-less flag 文字の集合（pipe-pane の `-I` 必須判定に使う）。
    tmux の getopt は value-less 短フラグを束ねられ、束の末尾にのみ値取りフラグを置ける（`-lt admin:0`＝
    `-l`＋`-t`。`-l`＝literal は send-keys 最頻フラグ）。`-t` 完全一致か glued 接頭辞しか拾わない実装は
    `-lt admin:0` を target 空と誤読し管理窓 send-keys が deny を素通りする fail-open だった（sc-164 finding1・
    value-less 群から `X` を落とした self-review finding2 も同型）。値取りフラグ（send-keys の `-N`/`-c`・
    paste-buffer の `-b`/`-s` 等）は **その値がフラグに見えても値として消費**する（`-b t` の `t` を target と
    誤採取しない）。逆に値取りフラグに glued した値（`-Nt`＝`-N` の値が `t`）を target と読まない。
    tmux の getopt は `-t` を後勝ちで上書きするため（`-t wt-x -t admin:0` の実効 target は admin:0）、最初の
    `-t` だけを採ると管理窓宛が素通りする fail-open になる（sc-164 finding3）→ 全採取し、決定は _decide_targets
    側で「全 `-t` が worker 窓なら allow・非 worker 候補が 1 つでもあれば解決して判定」と fail-closed に倒す。
    未知のフラグ文字は value-less とみなして走査を続ける（過剰採取＝deny 方向で安全）。"""
    targets = []
    flags = set()
    i = 0
    n = len(rest)
    while i < n:
        tok = rest[i]
        if not tok.startswith("-") or tok == "-" or tok.startswith("--"):
            i += 1  # 非オプション（keys / path / shell-command）と長オプション（tmux は持たない）は素通し
            continue
        j = 1
        consumed_next = False
        while j < len(tok):
            ch = tok[j]
            if ch in valuetaking:  # 値取りフラグ＝束はここで終端（残りは glued 値 or 次トークンが値）
                glued = tok[j + 1:]
                if glued:
                    val = glued
                else:
                    val = rest[i + 1] if i + 1 < n else None
                    consumed_next = i + 1 < n
                if ch == target_flag:
                    targets.append(val)
                break
            flags.add(ch)  # value-less（未知文字も value-less 扱いで走査継続＝deny 方向）
            j += 1
        i += 2 if consumed_next else 1
    return targets, flags


def _extract_targets(rest):
    """send-keys の args 列から全 `-t` 値を返す（互換 seam・_scan_opts の send-keys 特化ラッパ）。"""
    return _scan_opts(rest, _SEND_KEYS_VALUELESS, _SEND_KEYS_VALUETAKING)[0]


def _is_abbrev_of(subcmd, names, min_len=2):
    """subcmd が names（canonical + documented alias）のいずれかの接頭辞（長さ >= min_len）か。
    man tmux:「the shortest unambiguous form of a command is accepted」＝exact 一致だけの判定は略記
    （`pasteb` / `pa` / `run` / `ru`）を素通りさせる fail-open になる（send-keys の sc-164 finding1 と同型）。
    tmux 自身が曖昧として拒否する短さ（`p` 等）まで拾う over-inclusion は **deny 方向で無害**（tmux が実行
    できないコマンドを guard が拒むだけ）ゆえ min_len=2 で保守的に拾う。"""
    if not isinstance(subcmd, str) or len(subcmd) < min_len:
        return False
    return any(n.startswith(subcmd) for n in names)


class _Transport(object):
    """封鎖対象 transport の 1 行（ヘッダ transport 表の機械表現）。
      matcher: subcmd → bool（送信系 subcommand か）/ valueless・valuetaking: getopt 表（_scan_opts 用）
      kind: 'pane'（`-t` が target-pane）| 'client'（load-buffer の `-t` は target-client）
      no_target: `-t` 無しのときの扱い（'current'=現在窓を解決して判定 / 'allow'=配送先なしゆえ allow）
      require_flag: このフラグが無ければ transport でない（pipe-pane の `-I`＝pane 入力へ書込むときだけ注入）"""

    def __init__(self, canon, matcher, valueless, valuetaking, kind="pane", no_target="current",
                 require_flag=None):
        self.canon = canon
        self.matcher = matcher
        self.valueless = valueless
        self.valuetaking = valuetaking
        self.kind = kind
        self.no_target = no_target
        self.require_flag = require_flag


TRANSPORTS = (
    # send-keys は既存判定を **一切変えない**（sc-2g3 acceptance「既存 send-keys 判定と非干渉」）＝専用述語を温存。
    _Transport("send-keys", _is_send_keys_subcmd, _SEND_KEYS_VALUELESS, _SEND_KEYS_VALUETAKING),
    _Transport("paste-buffer", lambda s: _is_abbrev_of(s, ("paste-buffer", "pasteb")),
               _PASTE_BUFFER_VALUELESS, _PASTE_BUFFER_VALUETAKING),
    # run-shell の bare 呼出（`-t` 無し）は pane へ何も注入しない＝配送先を持たない（`-t` は format 展開文脈に
    #   すぎず実効の注入先を縛らない）。実注入は payload であり exec carrier 再帰で捕捉されるため、bare run-shell の
    #   直接 transport 扱いは security 価値ゼロで false-positive のみを生む → no_target='allow'（sc-2g3 self-review）。
    #   明示 `-t <管理窓>` は従来どおり deny（配送先が明示されたときのみ現在窓判定に載せる）。
    _Transport("run-shell", lambda s: _is_abbrev_of(s, ("run-shell", "run")),
               _RUN_SHELL_VALUELESS, _RUN_SHELL_VALUETAKING, no_target="allow"),
    # pipe-pane は `-I`（コマンド stdout を pane 入力へ＝typed 相当）のときだけ transport。`-O`/既定は read piping。
    _Transport("pipe-pane", lambda s: _is_abbrev_of(s, ("pipe-pane", "pipep")),
               _PIPE_PANE_VALUELESS, _PIPE_PANE_VALUETAKING, require_flag="I"),
    # load-buffer の `-t` は target-**client**（pane 配送を持たない）。`-t` 無し＝staging のみ → allow（ヘッダ参照）。
    _Transport("load-buffer", lambda s: _is_abbrev_of(s, ("load-buffer", "loadb")),
               _LOAD_BUFFER_VALUELESS, _LOAD_BUFFER_VALUETAKING, kind="client", no_target="allow"),
)

# payload を /bin/sh（`-C` 時は tmux コマンド）として **即時実行**する carrier（＝guard の完全迂回路）。
#   これらの payload は同じ classify へ再帰させる（ヘッダ「exec carrier の payload 再帰」）。遅延実行系
#   （bind-key / set-hook / command-prompt / confirm-before）と source-file は KNOWN GAP（ヘッダ参照）。
EXEC_CARRIERS = (
    ("run-shell", "run"), ("if-shell", "if"), ("new-window", "neww"), ("split-window", "splitw"),
    ("new-session", "new"), ("respawn-pane", "respawnp"), ("respawn-window", "respawnw"),
    ("display-popup", "popup"), ("pipe-pane", "pipep"),
)

# payload 再帰の深さ上限（`run-shell 'tmux run-shell "…"'` の入れ子爆発を止める安全弁）。
MAX_NEST_DEPTH = 2


def _match_transport(subcmd):
    """subcmd に該当する _Transport を返す（無ければ None）。"""
    for tp in TRANSPORTS:
        if tp.matcher(subcmd):
            return tp
    return None


def _is_exec_carrier(subcmd):
    """subcmd が payload を即時実行する carrier か（payload 再帰の対象）。"""
    return any(_is_abbrev_of(subcmd, names) for names in EXEC_CARRIERS)


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


def _resolve_window_name(target, kind="pane"):
    """target の window 名を tmux で解決する。解決不能（rc!=0・空・到達不能・malformed）は None。
    kind='pane'（send-keys/paste-buffer/run-shell/pipe-pane の `-t`）は target-pane として引く。
    kind='client'（load-buffer の `-t` は **target-client**）は `-c` で client 文脈の現在 window を引く。
    target 無し（_NO_TARGET）は現在窓の #{window_name} を引く。"""
    if target is _NO_TARGET:
        args = ["display-message", "-p", "#{window_name}"]
    elif not target:  # None（-t 値欠落）→ 解決不能
        return None
    elif kind == "client":
        args = ["display-message", "-p", "-c", target, "#{window_name}"]
    else:
        args = ["display-message", "-p", "-t", target, "#{window_name}"]
    p = _run_tmux(args)
    if p is not None and p.returncode == 0:
        name = p.stdout.strip()
        return name or None
    return None


def _decide_single_target(target, kind="pane"):
    """単一 target（str / None / _NO_TARGET）を tmux 解決して (block, reason_target) を返す。
    literal 'wt-' の fast-path 判定は呼び元（_decide_targets）が担うため、ここでは常に解決を試みる。"""
    name = _resolve_window_name(target, kind)
    if name is not None:
        if name.startswith(WORKER_WINDOW_PREFIX):
            return False, ""      # worker 窓 → 封鎖対象外
        return True, name          # 管理窓 → deny
    # 解決不能: 到達不能（allow・実行不能ゆえ実害なし）と 到達可だが判定不能（deny・fail-closed）を弁別。
    if not _tmux_reachable():
        return False, ""
    return True, (target if isinstance(target, str) else "<current-window>")


def _decide_targets(targets, kind="pane", no_target="current"):
    """transport の全 `-t` 値リスト（_scan_opts の返り）から (block: bool, reason_target: str) を返す。
    block=True → deny(exit2)。判定（sc-164 finding3・tmux getopt は `-t` 後勝ち）:
      - `-t` 無し（空リスト）→ no_target='current' なら現在窓を解決して判定（管理窓 or 解決不能&到達可 → deny）/
        no_target='allow' なら allow（load-buffer＝配送先を持たない staging・ヘッダ transport 表）。
      - `-t` が **すべて** literal 'wt-' → allow（worker 窓明示・tmux read 不要の fast-path）。kind='client' では
        client 指定子（tty パス）は window 名でないため fast-path を使わず常に解決する。
      - それ以外（非 worker 候補が混在）→ 各非 literal-worker 候補を tmux 解決し、1 つでも管理窓/解決不能&到達可
        なら deny（fail-closed・過剰採取した keys 領域の候補も deny 方向で安全）。実効 target が管理窓でも
        first-`-t` を採る旧実装は allow 素通ししていた（finding3）。"""
    if not targets:
        if no_target == "allow":
            return False, ""
        return _decide_single_target(_NO_TARGET, kind)
    # fast-path allow: すべての `-t` が literal 'wt-' 指定子（tmux read 不要・worker 窓明示）。
    if kind == "pane" and all(isinstance(t, str) and _literal_worker_target(t) for t in targets):
        return False, ""
    # 混在: 非 literal-worker 候補を解決。1 つでも deny 該当なら deny（fail-closed）。
    for t in targets:
        if kind == "pane" and isinstance(t, str) and _literal_worker_target(t):
            continue  # この候補は worker 窓確定 → skip
        block, tgt = _decide_single_target(t, kind)
        if block:
            return True, tgt
    return False, ""


def _decide_send_keys(targets):
    """send-keys の判定（互換 seam・_decide_targets の pane/current 特化ラッパ）。"""
    return _decide_targets(targets, "pane", "current")


def _tmux_command_candidates(payload):
    """payload を tmux コマンド文字列（`-C` / if-shell の command 引数）として解釈した classify 候補群を返す。
    tmux はコマンド文字列内の `;`（および改行）を **tmux コマンド区切り**として扱う（shell の `;` とは別レイヤ）。
    payload 全体に一度だけ `tmux ` を前置すると、`display-message x ; send-keys -t admin:0 evil` の `;` 以降が
    basename=send-keys になり tmux invocation と認識されず素通りする fail-open だった（sc-2g3 self-review
    finding: if-shell / -C の `;` 連鎖）。よって tmux 区切り（`;` / 改行）で分割し **各セグメントに `tmux ` を
    前置**してから classify する。クォート内の `;` まで割る over-split は deny 方向で安全（先頭セグメントが実効
    target を保持する）。"""
    out = []
    for chunk in payload.replace("\n", ";").split(";"):
        chunk = chunk.strip()
        if chunk:
            out.append("tmux " + chunk)
    return out


def _classify_nested(rest, cwd, depth):
    """exec carrier の payload 引数を **同じ判定で再帰検査**し、違反があれば deny メッセージを返す（無ければ None）。
    tmux は payload を /bin/sh（`-C` 時は tmux コマンド）として実行するが、その実行は PreToolUse を再発火しない
    ため、target 判定だけでは `run-shell -t wt-x 'tmux send-keys -t admin:0 evil'`（target=worker 窓・実効注入先=
    管理窓）が素通りする。各引数を (a) shell 文字列 (b) tmux コマンド文字列（tmux `;` 区切りで分割し各セグメントに
    `tmux ` 前置＝`-C` / if-shell の command 引数）の両解釈で classify し直す。フラグや target 等の非 payload 引数も
    再帰対象に含むが、再帰は **payload が明示 `-t` で管理窓を指す transport のときだけ deny**（in_nested=True で
    no_target='current' の現在窓 deny を無効化）＝新たな無条件 deny を増やさない。これを欠くと window/session 名
    （`-n run` / `-s pa` 等・transport 略記と衝突）が `tmux <名>` と再解釈され `-t` 無し→現在窓(admin)→誤 deny する
    false-positive 回帰になる（sc-2g3 self-review finding: 正当な new-window/new-session を誤 block）。"""
    if depth <= 0:
        return None
    for arg in rest:
        if not isinstance(arg, str) or not arg:
            continue
        # (a) shell 文字列解釈（iter_commands が shell の `;` を正しく分割）＋(b) tmux コマンド文字列解釈
        #     （tmux `;` 区切りで分割し各セグメントに `tmux ` 前置）。
        for nested in [arg, *_tmux_command_candidates(arg)]:
            code, msg = _classify(nested, cwd, depth - 1, in_nested=True)
            if code == 2:
                return msg
    return None


def _classify(cmd, cwd, depth, in_nested=False):
    """cmd 中の最初に違反する tmux transport を (2, reason) で返す。違反無し/解析不能は (0, "")。
    session 非依存の純判定（self-scope は main_decide が別層で被せる）。depth は payload 再帰の残り深さ。
    in_nested=True（exec carrier の payload 再帰内）では transport の `-t` 無し（現在窓）解決 deny を無効化する
    ＝payload の現在窓は guard の窓（admin）と別物で管理窓宛の証拠にならず、非 payload 引数（window/session 名）を
    transport と誤読した誤 deny を生むため（明示 `-t` で管理窓を指す実 vector は変わらず deny される）。"""
    if not cmd or iter_commands is None:
        return 0, ""
    for core, _seg_cwd in iter_commands(cmd, cwd):
        if not core or os.path.basename(core[0]) != "tmux":
            continue  # tmux 以外（scribe-inject.sh 等）は対象外＝そのまま通過
        # tmux 内 `;` 区切りの各サブ invocation を走査（後続 `; send-keys …` の bypass を塞ぐ・finding2）。
        for subcmd, rest in _iter_tmux_invocations(core):
            if not subcmd:
                continue
            tp = _match_transport(subcmd)  # send-keys / paste-buffer / run-shell / pipe-pane -I / load-buffer
            if tp is not None:
                targets, flags = _scan_opts(rest, tp.valueless, tp.valuetaking)
                if tp.require_flag is None or tp.require_flag in flags:
                    # 再帰内は現在窓 deny を無効化（`-t` 無し→ allow）＝window/session 名の誤読 FP を防ぐ。
                    no_target = "allow" if in_nested else tp.no_target
                    block, tgt = _decide_targets(targets, tp.kind, no_target)
                    if block:
                        return 2, _render(tgt, tp.canon)
            # exec carrier（run-shell / if-shell / new-window …）の payload を同じ判定へ再帰（迂回路封鎖）。
            if _is_exec_carrier(subcmd):
                msg = _classify_nested(rest, cwd, depth)
                if msg:
                    return 2, msg
    return 0, ""


def classify(cmd, cwd):
    """cmd 中の最初に違反する tmux transport を (2, reason) で返す（payload 再帰の入口・深さ上限つき）。"""
    return _classify(cmd, cwd, MAX_NEST_DEPTH)


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
    guard が引く display-message の `-t`（target-pane）と `-c`（target-client・load-buffer 用）の**両方**を
    同じ表で解決する。reachable=False なら socket probe も exit1（到達不能）。SCRIBE_TMUX 経由で guard が起動。"""
    lines = ["#!/usr/bin/env bash", 'args="$*"']
    if reachable:
        lines.append('case "$args" in *"#{socket_path}"*) echo /tmp/stub-sock; exit 0 ;; esac')
    else:
        lines.append('case "$args" in *"#{socket_path}"*) exit 1 ;; esac')
    # -t（pane）/ -c（client）の値を拾う。
    lines += [
        'tgt=""; prev=""',
        'for a in "$@"; do case "$prev" in -t|-c) tgt="$a" ;; esac; prev="$a"; done',
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

    # --- (2b2) transport 述語: 新 transport の canonical/alias/略記（sc-2g3）------------------------
    check(_match_transport("paste-buffer").canon == "paste-buffer", "(2b2) paste-buffer → transport")
    check(_match_transport("pasteb").canon == "paste-buffer", "(2b2) alias pasteb → transport")
    check(_match_transport("pa").canon == "paste-buffer", "(2b2) 略記 pa → paste-buffer transport")
    check(_match_transport("load-buffer").canon == "load-buffer", "(2b2) load-buffer → transport")
    check(_match_transport("loadb").canon == "load-buffer", "(2b2) alias loadb → transport")
    check(_match_transport("run-shell").canon == "run-shell", "(2b2) run-shell → transport")
    check(_match_transport("run").canon == "run-shell", "(2b2) alias run → transport")
    check(_match_transport("pipe-pane").canon == "pipe-pane", "(2b2) pipe-pane → transport")
    check(_match_transport("capture-pane") is None, "(2b2) capture-pane(read) → 非 transport")
    check(_match_transport("list-panes") is None, "(2b2) list-panes(read) → 非 transport")
    check(_match_transport("send-prefix") is None, "(2b2) send-prefix → 非 transport")
    check(_is_exec_carrier("if-shell") and _is_exec_carrier("if"), "(2b2) if-shell/if → exec carrier")
    check(_is_exec_carrier("new-window") and _is_exec_carrier("splitw"), "(2b2) new-window/splitw → exec carrier")
    check(not _is_exec_carrier("capture-pane"), "(2b2) capture-pane → 非 exec carrier")

    # --- (2b3) subcommand 別 getopt 表（_scan_opts・値取り flag の値を target と誤採取しない）---------
    check(_scan_opts(["-b", "x", "-t", "admin:0"], _PASTE_BUFFER_VALUELESS, _PASTE_BUFFER_VALUETAKING)[0]
          == ["admin:0"], "(2b3) paste-buffer -b x -t admin:0 → target 採取")
    check(_scan_opts(["-b", "t", "-t", "wt-x"], _PASTE_BUFFER_VALUELESS, _PASTE_BUFFER_VALUETAKING)[0]
          == ["wt-x"], "(2b3) paste-buffer -b の値 't' を target と誤採取しない")
    check(_scan_opts(["-dpr", "-s", "X", "-t", "@3"], _PASTE_BUFFER_VALUELESS, _PASTE_BUFFER_VALUETAKING)[0]
          == ["@3"], "(2b3) paste-buffer value-less 束 -dpr と値取り -s を貫通して target 採取")
    check(_scan_opts(["-b", "x", "/tmp/f"], _LOAD_BUFFER_VALUELESS, _LOAD_BUFFER_VALUETAKING)[0] == [],
          "(2b3) load-buffer -t 無し（staging のみ）→ target 空")
    check(_scan_opts(["-w", "-t", "/dev/pts/9", "/tmp/f"], _LOAD_BUFFER_VALUELESS, _LOAD_BUFFER_VALUETAKING)[0]
          == ["/dev/pts/9"], "(2b3) load-buffer -w -t <client> → client 採取")
    check(_scan_opts(["-b", "-c", "/tmp", "-t", "@3", "cmd"], _RUN_SHELL_VALUELESS, _RUN_SHELL_VALUETAKING)[0]
          == ["@3"], "(2b3) run-shell -b(bool) と -c <dir>(値取り) を貫通して target 採取")
    _pp_t, _pp_f = _scan_opts(["-I", "-t", "@3", "cmd"], _PIPE_PANE_VALUELESS, _PIPE_PANE_VALUETAKING)
    check(_pp_t == ["@3"] and "I" in _pp_f, "(2b3) pipe-pane -I -t @3 → target 採取 + -I フラグ検出")
    check("I" not in _scan_opts(["-o", "-t", "@3", "cmd"], _PIPE_PANE_VALUELESS, _PIPE_PANE_VALUETAKING)[1],
          "(2b3) pipe-pane -o（read piping）→ -I 非検出")

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
        _write_stub_tmux(stub_ok, {
            "@3": "admin", "@7": "wt-sc-1", "admin:0": "admin",
            # client 指定子（load-buffer の `-t`＝target-client）: guard は `-c` で現在 window を引く。
            "/dev/pts/9": "admin", "/dev/pts/7": "wt-sc-1",
        }, reachable=True)
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

        # --- (5b) sc-2g3: send-keys 以外の transport（paste-buffer / load-buffer / run-shell / pipe-pane）---
        # paste-buffer（buffer 経由の間接送信）: 管理窓 deny / worker 窓・literal wt- allow / 略記・alias も deny。
        check(blocks("tmux paste-buffer -t @3"), "(5b/pb) 管理窓 paste-buffer → block")
        check(blocks("tmux pasteb -b evil -t admin:0"), "(5b/pb) alias pasteb（管理窓）→ block")
        check(blocks("tmux pa -t @3"), "(5b/pb) 略記 pa（管理窓）→ block")
        check(blocks("tmux paste-buffer -b evil"), "(5b/pb) -t 無し（現在窓・解決不能&到達可）→ block(fail-closed)")
        check(blocks("tmux paste-buffer -dpr -s X -t admin:0"),
              "(5b/pb) value-less 束 -dpr + 値取り -s を貫通して管理窓 → block")
        check(not blocks("tmux paste-buffer -t @7"), "(5b/pb) worker 窓 → allow")
        check(not blocks("tmux paste-buffer -b x -t wt-sc-164"), "(5b/pb) literal wt- 窓 → allow")
        # load-buffer: `-t` は target-client。staging（-t 無し）は allow・client の窓が管理窓なら deny。
        check(not blocks("tmux load-buffer -b x /tmp/f"),
              "(5b/lb) -t 無し load-buffer（配送先なしの staging）→ allow")
        check(not blocks("tmux load-buffer -b x /tmp/f && tmux paste-buffer -b x -t wt-sc-1"),
              "(5b/lb) worker 窓宛の合成フロー（load→paste）→ allow（正当な steering を壊さない）")
        check(blocks("tmux load-buffer -b x /tmp/f && tmux paste-buffer -b x -t admin:0"),
              "(5b/lb) 管理窓宛の二段ベクタは delivery(paste-buffer) で block")
        check(blocks("tmux load-buffer -w -t /dev/pts/9 /tmp/f"),
              "(5b/lb) -t <client>（現在窓=admin）→ block")
        check(not blocks("tmux load-buffer -w -t /dev/pts/7 /tmp/f"),
              "(5b/lb) -t <client>（現在窓=wt-sc-1）→ allow")
        check(blocks("tmux loadb -t @99 /tmp/f"), "(5b/lb) alias loadb・解決不能&到達可 → block(fail-closed)")
        # run-shell: 管理窓 target は deny / worker 窓でも **payload に管理窓 transport があれば deny**（再帰）。
        check(blocks("tmux run-shell -t @3 'echo hi'"), "(5b/rs) 管理窓 target の run-shell → block")
        check(not blocks("tmux run-shell -t @7 'echo hi'"), "(5b/rs) worker 窓 target + 無害 payload → allow")
        # bare run-shell（`-t` 無し）: 配送先を持たず pane へ何も注入しない → allow（no_target='allow'・sc-2g3
        #   self-review。現在窓=admin へ誤 deny する over-block 回帰を pin。実注入は payload で exec carrier 再帰が担う）。
        check(not blocks("tmux run-shell 'echo hi'"), "(5b/rs) bare run-shell（-t 無し・無害 payload）→ allow")
        check(not blocks("tmux run -c /tmp 'echo hi'"), "(5b/rs) run -c <dir>（-t 無し）→ allow")
        # bare run-shell でも payload が管理窓 transport なら再帰で block（no_target='allow' は payload 検査に非干渉）。
        check(blocks("tmux run-shell 'tmux send-keys -t admin:0 evil Enter'"),
              "(5b/rs) bare run-shell でも payload が管理窓 send-keys → block（再帰は不変）")
        check(blocks("tmux run-shell -t @7 'tmux send-keys -t admin:0 evil Enter'"),
              "(5b/rs) worker 窓 target でも payload が管理窓 send-keys → block（再帰・target 判定の穴）")
        check(blocks("tmux run -C -t wt-sc-1 'send-keys -t admin:0 evil Enter'"),
              "(5b/rs) -C（payload=tmux コマンド）でも管理窓 send-keys → block（tmux コマンド解釈の再帰）")
        check(blocks("tmux run-shell -t wt-sc-1 'tmux paste-buffer -t admin:0'"),
              "(5b/rs) payload が管理窓 paste-buffer → block（transport 表 × 再帰の合成）")
        # pipe-pane: -I（pane 入力へ書込＝typed 相当）だけが transport。-O/既定（read piping）は allow。
        check(blocks("tmux pipe-pane -I -t @3 'cat /tmp/payload'"),
              "(5b/pp) -I（入力注入）で管理窓 → block")
        check(not blocks("tmux pipe-pane -o -t @3 'cat >> /tmp/log'"),
              "(5b/pp) -o/-O（出力 piping=read 系）は管理窓でも allow（監視を壊さない）")
        check(not blocks("tmux pipe-pane -I -t @7 'echo hi'"), "(5b/pp) -I でも worker 窓 → allow")
        # exec carrier（run-shell 以外）: payload 再帰のみ（新たな無条件 deny を作らない）。
        check(blocks("tmux if-shell -b true 'send-keys -t admin:0 evil Enter'"),
              "(5b/ex) if-shell の tmux command 引数が管理窓 send-keys → block")
        check(blocks("tmux new-window 'tmux send-keys -t admin:0 evil Enter'"),
              "(5b/ex) new-window の shell payload が管理窓 send-keys → block")
        check(blocks("tmux split-window -t wt-sc-1 'tmux pasteb -t @3'"),
              "(5b/ex) split-window payload の管理窓 paste-buffer → block")
        check(not blocks("tmux new-window -n wt-sc-9 htop"), "(5b/ex) 無害 payload の new-window → allow")
        check(not blocks("tmux new-window -t admin -n tools 'less /tmp/log'"),
              "(5b/ex) 管理窓での window 作成自体は transport でない → allow（無条件 deny を増やさない）")
        check(not blocks("tmux if-shell 'test -f /tmp/x' 'display-message ok'"),
              "(5b/ex) 無害な if-shell → allow")

        # --- (5c) sc-2g3 self-review: exec carrier 再帰の FP 非増加（window/session 名が transport 略記と衝突）--
        # `-n run`/`-s pa` 等の名前が `tmux <名>` と再解釈され `-t` 無し→現在窓(admin)→誤 deny する回帰を pin。
        # 再帰内は現在窓 deny を無効化するので、これら正当な new-window/new-session は allow に戻る。
        check(not blocks("tmux new-window -n run htop"),
              "(5c/fp) new-window -n run（run-shell 略記衝突）→ allow（誤 deny 回帰）")
        check(not blocks("tmux new-window -n send"),
              "(5c/fp) new-window -n send（send-keys alias 衝突）→ allow")
        check(not blocks("tmux new-window -n pa htop"),
              "(5c/fp) new-window -n pa（paste-buffer 略記衝突）→ allow")
        check(not blocks("tmux new-session -s run -d"),
              "(5c/fp) new-session -s run → allow")
        check(not blocks("tmux new-session -s pa"),
              "(5c/fp) new-session -s pa（paste-buffer 略記衝突）→ allow")
        # 実 vector（payload が明示 `-t admin` で管理窓を指す）は上記 FP 修正後も変わらず block。
        check(blocks("tmux new-window -n run 'tmux send-keys -t admin:0 evil'"),
              "(5c/fp) 名前衝突 window でも payload が管理窓 send-keys → block（実 vector は維持）")

        # --- (5d) sc-2g3 self-review: tmux コマンド payload の `;` 連鎖 fail-open（if-shell / -C）------------
        # `tmux ` 前置を payload 全体に一度だけ足すと `;` 以降が tmux invocation と認識されず素通りしていた。
        # tmux `;` 区切りで分割し各セグメントに `tmux ` 前置してから classify することで塞ぐ。
        check(blocks("tmux if-shell true 'x ; send-keys -t admin:0 evil'"),
              "(5d/semi) if-shell の tmux command `;` 連鎖後続 send-keys（管理窓）→ block（fail-open 回帰）")
        check(blocks("tmux run -C -t wt-sc-1 'display-message hi ; send-keys -t admin:0 evil'"),
              "(5d/semi) run -C の `;` 連鎖後続 send-keys（管理窓）→ block")
        check(blocks("tmux if-shell true 'display-message a ; pasteb -t @3'"),
              "(5d/semi) if-shell の `;` 連鎖後続 paste-buffer（管理窓）→ block")
        check(not blocks("tmux if-shell true 'display-message a ; display-message b'"),
              "(5d/semi) 無害な `;` 連鎖（display-message のみ）→ allow（新 deny を増やさない）")

        # --- (6) session self-scope: foreign session では管理窓 send-keys も no-op --------------------
        _fw = os.path.join(_root, "orchdir")
        os.makedirs(os.path.join(_fw, ".beads"))
        with open(os.path.join(_fw, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            json.dump({"database": "dolt", "dolt_database": "orch"}, f)
        check(main_decide("tmux send-keys -t admin:0 hi Enter", _fw)[0] == 0,
              "(6) foreign(orch) session → no-op（orchestrator を brick しない）")
        check(main_decide("tmux paste-buffer -t admin:0", _fw)[0] == 0,
              "(6/sc-2g3) foreign session では新 transport(paste-buffer) も no-op")
        check(main_decide("tmux run-shell -t @3 'tmux send-keys -t admin:0 evil'", _fw)[0] == 0,
              "(6/sc-2g3) foreign session では exec carrier 再帰も no-op")

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

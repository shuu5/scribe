#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Bash) hook: scribe の bd write を「自台帳(prefix sc-)のみ・bdw 経由」へ機械強制する（exit 2）。
# 由来: sc-wdr（scriptorium scripts/hooks/bd-write-guard.py を scribe 台帳(sc)向けに faithful port）。orch 版の
#   散文規律「1台帳=owner 1人」「write は bdw 経由」を PreToolUse(Bash) hook へ昇格した機構を、scribe の
#   .beads/metadata.json dolt_database="sc"（prefix sc-）向けに移植する。scribe plugin の hooks/hooks.json が
#   PreToolUse[Bash] から ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/bd-write-guard.py を起動する（script 不在時は
#   hooks.json 側の if/else が exit0 で fail-open）。構造は scribe git-destructive-guard.py / rm-destructive-guard.py
#   を踏襲。トークナイザは publish 済 cmdtokens plugin の canonical lib（GitHub shuu5/cmdtokens・
#   ~/.claude/plugins/cmdtokens/lib）を consume する（下記 consume preamble・全 guard が canonical を consume）。
#
# KNOWN RISK（consume 設計の既知性質・全 guard 共通）: 本 guard は cmdtokens plugin の enable を運用前提とする。
#   plugin 不在ホストでは lib ロードに失敗し guard が fail-open（exit 0・loud stderr）で素通し＝write-isolation
#   moat が silent に無効化される。同 repo の scripts/hooks/lib/cmdtokens.py は当面残置（override self-test の
#   対象・撤去は全ホスト plugin enable 確認後の別 step＝defense-in-depth）。
#
# 方式: コマンド文字列を共有 lib(cmdtokens.iter_commands)で shlex トークン化し、**本物の `bd` 呼び出しの
#   トークン列にのみ**ルールを適用する。substring/正規表現の全体一致が起こす誤検出（`echo "bd update x"`・
#   `bd dolt push && rm -f x` の語の共起・クォート内データ）を構造的に排除する。ランチャ(sudo/env/timeout/
#   flock...) / `bash -c "..."` / eval / su -c 等の経由も lib が貫通する。直列化ラッパ `bdw` は basename が
#   `bd` でない（"bdw"）ため guard 対象外＝bdw 経由 write はそのまま通過する（bdw の内部 bd 呼び出しは subprocess
#   ゆえ PreToolUse hook は再発火しない）。scribe は scripts/bdw を既に持つ（beads-bdw plugin canonical bdw を
#   consume する薄い shim）ため kind 'c' funnel は既存 infra で成立する（新規直列化 infra 不要）。
#
# 脅威モデル（orch 版 un-4sf 由来）: foreign write による owner 2人違反 + 自台帳並行 write による lost-update を
#   機械で止める。自台帳 = prefix `sc`（.beads/metadata.json dolt_database="sc" / CLAUDE.md・metadata SSOT）。
#   embedded Dolt は single-writer ゆえ bare bd write を並行すると last-writer-wins で lost-update（bdw flock
#   直列化で防ぐ）。
#
# session self-scope（D1・plugin global enable の必須前提）: この guard を plugin として global enable すると
#   PreToolUse[Bash] が**全セッション**で発火する。prefix 規則だけだと orch(orch-)/uns(un-)/cc-session(ccs-)
#   の bare bd write が rule (b) で deny され、それら project の bd 操作を全破壊する。対策として guard 冒頭で
#   **当該 session が scribe(sc)session か**を判定し、非該当なら一切判定せず exit 0(no-op)で抜ける
#   （defense-in-depth）。判定は共有 lib scribe_session._is_scribe_guard_session（session cwd から上方向に
#   最初に見つかる .beads/metadata.json の dolt_database が SELF_PREFIX(sc)か・bd 自身の台帳解決と同じ walk-up・
#   subprocess 非依存）。**fully-dynamic（cwd 台帳を実行時に self とする）にはしない**（D1）: scribe plugin は
#   ~/.claude/plugins/scribe symlink で global enable され本 hook が全セッションで発火するため、fully-dynamic
#   だと bdw を持たない無関係 project の bare bd write まで kind 'c' で funnel し、その project の bd write を
#   brick する（+ scribe の直列化ポリシーを machine-wide に押し付ける）。既存 scribe_session.py の banner が
#   dolt_database=='sc' 厳密 scoping を選んだ precedent と同じ判断＝SELF_PREFIX を単一 knob で持つ。これは
#   **prefix 規則の緩和ではなく session 判定の追加**であり、scribe session 内では (a)(b)(c) 挙動を一切変えない。
#   判定の基準は**session cwd**（hook payload の top-level cwd）であって compound 内の `cd` 先(segment cwd)では
#   ない＝scribe session が `cd /uns && bd update un-1` しても従来どおり deny。判定不能のうち **.beads 皆無・
#   git 外は fail-open で no-op(exit0)**（区別ルール②不変）だが、**`.beads/metadata.json` は在るが読取/parse
#   失敗(present-but-unreadable)は fail-closed**＝scribe session とみなし deny 継続（self ledger が在るのに
#   metadata を一過性に読めないだけで moat を瞬間的に開かない・区別ルール①）。session 判定に用いる
#   `_is_scribe_guard_session` は banner 用 `_is_scribe_session`（fail-open）と意図的に分岐した guard 用
#   fail-closed 版（scribe_session.py D2）。決して例外で die しない（filesystem walk を try で囲み、皆無/非 dict/
#   key 欠落は False=no-op、present-but-unreadable のみ True=fail-closed）。
#   **cross-plugin 共存 note**: 稀な present-but-unreadable-in-foreign-session（foreign の orch 等 session で
#   metadata が一過性に読めない）では scribe fail-closed guard が foreign(orch 等)の write を一時 over-block
#   しうるが、fail-safe（deny＝bad write を通さない・foreign 側 owner は read か bdw で回避可能）ゆえ許容。
#
# guard rule（orch 版 (a)(b)(c) 由来・全 block は exit2・台帳非依存の純トークン判定）:
#   (a) -C/--directory/--db/--global を伴う write は deny。foreign 台帳を write 対象にする＝owner 2人違反。
#       read は対象外（--readonly / read-only subcmd は許可。foreign read は bd --readonly 経由が安全）。
#   (b) global flag 無しの primary DB write でも、対象 bead が非 sc- prefix なら deny。
#       hydrate された foreign bead の copy を mutate すると source と乖離する（write routing 無し）。
#       create 等の id を引数に取らない write は sc- 自動付与ゆえ (b) を通過し (c) へ。
#   (c) 上記を通過した自台帳(sc-)への bare bd write は block し bdw 経由へ差し戻す（lost-update 防止）。
#
# JUDGMENT CALLS（orch 版 J1-J7 を移植。台帳非依存の純トークン判定ゆえ分類ロジックは orch と同一）:
#   J1 write 同定 = READ allowlist 方式（READ_SUBCMDS 以外を write 候補扱い・未知 subcmd は安全側 write 扱い）。
#      脅威モデル「foreign write を機械で確実に止める」は取りこぼし不可ゆえ。fail-open は例外処理層で担保。
#   J2 dolt 系は同期点として bare allow・foreign(-C/--db/--global)のみ deny。lost-update は bead-RMW 対象で
#      dolt push は同期（house policy「同期点は bd dolt push」と整合）ゆえ (c) bdw 差し戻し対象外。
#   J3 dep の cross-rig dep を許容: dependent(依存を持つ側)が sc- なら depends-on が foreign でも (c) 止まり
#      （deny しない）。連結 substrate の正当操作 `bd dep add sc-<id> <foreign-bead>` を壊さない。
#   J4 -C/--db/--global 付き write は自台帳指定でも一律 deny（over-block）。自台帳 DB の絶対パスを plugin hook 内で
#      堅牢に特定するのは cwd 依存・複数 worktree で困難ゆえ。実害は「global flag 無しで触れ」の誘導のみ。
#      副次的に subprocess 不要となり self-test が完全 hermetic（fixture repo 不要）。
#   J5 (b) の bead operand 抽出 = operands 全体から positional を走査（interspersed flag を貫通）。
#      bd(cobra/pflag)は flag と positional を interspersed に許すため subcmd 直後の連続 positional だけ
#      見る方式（lead 打ち切り）だと `bd update --status closed un-9` 等で foreign id を取りこぼし
#      deny されず最弱の kind 'c'=bdw 経由許可へ落ちる fail-open になる（取りこぼし不可=J1 違反）。
#      `--assignee un-bot` 等フラグ値の偶発 id 誤検出は SUBCMD_VAL_FLAGS allowlist の値 skip で回避する。
#   J6 sql/batch/import = id を positional 引数で取らない高危険 write ゆえ専用 deny(kind 'a')。対象 bead が
#      SQL 文字列(`bd sql "UPDATE ... WHERE id='un-1'"`)・別ファイル(`bd batch -f x`)・stdin(`bd import`)
#      内にあり (a)(b) の positional foreign 判定を素通りして最弱 kind 'c' へ落ちる＝foreign を確実に
#      mutate でき owner 2人違反を機械で止められない。自台帳指定でも一律 deny し read(--readonly SELECT)/
#      id 明示 write(bd update|dep を bdw 経由)へ差し戻す。SELECT-only sql の over-block は read 代替提示で許容。
#      repo は別途 sub-action 分類（repo list=read allow / repo add|remove|sync=bdw・連結 substrate 正路）。
#   J7 create/q/create-form = 新規作成 write。sc- 自動採番・positional は title/本文ゆえ既存 bead を mutate
#      しない。(b) prefix 判定を適用すると bare title 中の id 形語を foreign 誤認し自台帳作成を over-block
#      する（cell-quality minor）。bd は自台帳 prefix 固定で foreign 採番不能ゆえ (b) を飛ばし (c) へ。
#
# 失敗時方針: 入力解析・guard 内部・lib ロードのいずれの例外でも fail-open(exit 0)＝guard が全 Bash を brick
#   しない（scribe git/rm guard と同方針・hooks.json コメントの二重 fail-safe 指示に従う）。
# 検証: `python3 bd-write-guard.py --self-test`（token 判定 self-test は hermetic・subprocess 非依存。
#   ただし末尾の preamble self-test のみ guard を subprocess 起動し env 別挙動を観測する＝consume cutover の
#   (a)/(override)/(c) 表面を機械化する。sc-wdr）。

import sys
import os
import re
import json

# cmdtokens consume preamble（logic ゼロの薄い解決層・orch bd-write-guard の consume preamble を移植）:
#   canonical cmdtokens（standalone cmdtokens plugin の単一 SSOT）を sys.path 解決して import するだけ。
#   CMDTOKENS_LIB が未設定/空文字/非絶対値なら plugin 標準配置へ fallback。env 値・default とも
#   expanduser で ~ を展開する。取り込む公開 API は guard が実使用する iter_commands のみ。
#   `or` は空文字しか塞がず、非空の相対値は expanduser 後も相対のまま sys.path に入り cwd 相対解決される
#   （警告すら出ず foreign write を silent に素通し）。よって os.path.isabs で非絶対値（空/相対/whitespace）
#   を弾き既定（絶対 path）へ落とす。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")
_cmdtokens_lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
if not os.path.isabs(_cmdtokens_lib):  # 非絶対 → cwd 相対 poison を避け既定へ
    _cmdtokens_lib = _CMDTOKENS_DEFAULT_LIB
_cmdtokens_load_error = None
try:
    sys.path.insert(0, _cmdtokens_lib)
    from cmdtokens import iter_commands  # guard が実際に使う公開 API はこれだけ
except Exception as e:  # lib ロード不能 → fail-open（guard 無効化を loud に通知）
    iter_commands = None
    _cmdtokens_load_error = e
    # 既定 path 回帰の silent-green 防止: import 時 exit すると --self-test 親プロセスが test battery 到達前に
    #   死に、既定 path 破壊が exit0 で silent-green 化する。self-test / introspection モードでは exit せず
    #   main() に RED 報告させる。通常の hook 経路（フラグ無し）は従来どおり即 fail-open（exit 0）で Bash を
    #   brick しない。
    if "--self-test" not in sys.argv and "--print-cmdtokens-lib" not in sys.argv:
        sys.stderr.write(f"[bd-guard] cannot load cmdtokens lib, failing open: {e}\n")
        sys.exit(0)

# 自台帳 prefix と session/台帳 判定は共有 lib（scripts/hooks/lib/scribe_session.py）を SSOT とする。
#   banner hook(session-start-guard-health.py)と本 guard が同一の SELF_PREFIX / walk-up 台帳解決を共有し、
#   scribe .beads/metadata.json / CLAUDE.md と同一値（"sc"）を指す。ただし session 判定は用途で分岐する:
#   banner は _is_scribe_session（fail-open）、本 guard は _is_scribe_guard_session（fail-closed・moat 維持）
#   を使う（scribe_session.py D2）。SELF_PREFIX は 2 つの役割を兼ねる: (1) bead id prefix 規則の自台帳判定
#   （sc- か否か）、(2) session self-scope の台帳判定（session cwd の dolt_database == SELF_PREFIX か）。
#   本 import は logic ゼロの薄い解決層（cmdtokens consume preamble と同方針）: 同梱 lib/ を sys.path 解決して
#   import するだけ。lib ロード不能は fail-open（通常 hook 経路は exit0 で Bash を brick しない・self-test/
#   introspection は exit せず main へ RED 報告させ silent-green を断つ＝cmdtokens preamble と同形）。
_scribe_session_load_error = None
try:
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib"))
    from scribe_session import SELF_PREFIX, SELF_PFX, _ledger_dolt_database, _is_scribe_guard_session
except Exception as e:  # 同梱 lib ロード不能 → fail-open（guard 無効化を loud に通知）
    _scribe_session_load_error = e
    SELF_PREFIX = "sc"           # MSG_* の module-level 定義が SELF_PFX を参照するため fallback で必須
    SELF_PFX = SELF_PREFIX + "-"

    def _ledger_dolt_database(cwd):  # fallback（import 成功時は from-import に上書きされ未使用）
        return None

    def _is_scribe_guard_session(cwd):  # fallback: 常に no-op 側（False）= guard 無効化 = fail-open
        return False
    if "--self-test" not in sys.argv and "--print-cmdtokens-lib" not in sys.argv:
        sys.stderr.write(f"[bd-guard] cannot load scribe_session lib, failing open: {e}\n")
        sys.exit(0)

# bd の id トークン形（<prefix>-<suffix>。sc-1a2 / un-4sf / pk-037 / orch-xyz）。title 等の英単語ハイフン
# （read-only 等）も形上はマッチしうるが、(b) は subcmd 直後の positional にのみ適用するため誤検出は限定的。
BD_ID_RE = re.compile(r"^[a-z][a-z0-9]*-[0-9a-z]+$")

# グローバル値フラグ（次トークンを値として消費）/ glued・= 形も扱う。
GLOBAL_VAL_FLAGS = {"-C", "--directory", "--db", "--actor", "--dolt-auto-commit"}
# グローバル bool フラグ（値を取らない）。
GLOBAL_BOOL_FLAGS = {"--global", "--readonly", "--json", "-q", "--quiet", "--profile", "-h", "--help"}

# 明確に DB を mutate しない read-only subcommand（保守的列挙＝J1 allowlist）。これ以外は write 候補扱い。
# 注: "comment"(単数=append=write)は意図的に除外。"comments"(複数=view)のみ read 側に置く。
READ_SUBCMDS = {
    "show", "list", "ready", "blocked", "search", "query", "count", "children",
    "comments", "history", "diff", "find-duplicates", "duplicates",
    "lint", "stale", "status", "statuses", "types", "graph", "export",
    "context", "info", "where", "memories", "recall", "prime", "quickstart",
    "human", "version", "help", "completion", "ping", "preflight", "orphans",
    "state", "onboard", "find", "blocked-by", "init-safety",
}

# dep のサブアクション分類。
DEP_READ = {"list", "tree", "cycles"}
DEP_WRITE = {"add", "remove", "relate", "unrelate"}

# repo のサブアクション分類（連結 substrate hydrate）。`repo list`(+ bare `repo`/`repo --help`)は
# read で allow、`repo add`/`repo remove`/`repo sync` は self-config / local-DB mutate ゆえ write
# 扱い。注: `repo sync`(pull hydrate)は連結 substrate の正規手順で、本 guard の MSG_A も read 代替として
# 案内する核中操作ゆえ、deny(kind 'a') ではなく bdw 直列化(kind 'c')へ落とす（local DB を mutate するため
# --readonly では bd 自身がエラーになり escape 不能・bdw 経由が唯一の正路）。
REPO_READ = {"list"}

# 高危険 write（J6）: id を positional 引数で取らず、対象 bead が SQL 文字列 / 別ファイル / stdin 内に
# あるため (a)(b) の positional ベース foreign 判定を素通りする modality。`bd sql` は INSERT/UPDATE/DELETE
# で storage 層 bypass、`bd batch` は任意 id で close/update/dep 実行、`bd import` は任意 bead を投入できる。
# foreign を確実に mutate できてしまうため、自台帳指定でも一律 deny(kind 'a')し read/id 明示 write へ差し戻す。
HIGH_DANGER_WRITE = {"sql", "batch", "import"}

# 新規作成 write（J7）: sc- を自動採番し、positional は title/本文で既存 bead id ではない。(b) prefix
# 判定を適用すると bare title 中の id 形語（`bd q implement un-9 handler`）を foreign bead と誤認し自台帳
# 作成を over-block する。bd は自台帳 prefix 固定で foreign prefix の新規採番自体できない（→ (b) スキップで
# under-block は生じない）ため (b) を飛ばし bdw 直列化(c)へ。
CREATE_LIKE = {"create", "q", "create-form"}

# subcmd 固有の値フラグ（次トークンを値として消費する＝その値は positional/bead operand ではない）。
# bd(cobra/pflag)は flag と positional を interspersed に許すため、foreign bead が値フラグの後ろに
# 来ても取りこぼさないよう、positional 抽出時にこれら value-flag の次トークンを skip する（J5 の
# 「フラグ値の偶発 id 誤検出回避」を、lead 打ち切りではなく value-flag skip allowlist で達成する）。
# bool フラグ（値を取らない）はここに含めない＝次トークンが positional なら拾われる。保守的に
# 「未知の値フラグ」は値消費しない（=その次の bead-id は positional 扱いで安全側に拾う）。
SUBCMD_VAL_FLAGS = {
    "--status", "-s", "--reason", "-r", "--priority", "-p", "--notes", "-n",
    "--assignee", "-a", "--owner", "--title", "-t", "--type", "--design",
    "--acceptance", "--message", "-m", "--with", "--label", "-l", "--milestone",
    "--parent", "--estimate", "--actor", "--limit", "--format", "--sort",
    "--from", "--to", "--depends-on", "--blocked-by", "--description", "-d",
}

# stderr 案内（git-guard 同様 block は exit2 + 代替提示）。
MSG_A = ("foreign 台帳(-C/--directory/--db/--global)への bd write は禁止(owner 2人違反)。scribe が "
         "write してよいのは自台帳(prefix '" + SELF_PFX + "')のみ。foreign bead は read 専用で参照せよ"
         "(bd --readonly <subcmd> / bd show|list ...)。連結は `bd repo sync`(pull hydrate)で行う。")
MSG_B = ("非 '" + SELF_PFX + "' prefix bead への bd write は禁止。hydrate された foreign bead は自 DB 内の copy で、"
         "mutate すると source と乖離する(write routing 無し)。foreign bead は read 専用、write は自台帳"
         "('" + SELF_PFX + "')issue にのみ。対象: ")
MSG_C = ("自台帳('" + SELF_PFX + "')への bd write は直列化ラッパ bdw 経由で実行せよ。embedded Dolt は single-writer で、"
         "bare bd write を並行すると lost-update が起きる(bdw が flock で直列化する)。例: `scripts/bdw <subcmd>`"
         "(scripts/bdw は beads-bdw plugin の canonical bdw を consume する薄い shim)。")
MSG_D = ("bd sql(非SELECT) / batch / import は id を引数で取らず対象 bead を SQL 文字列・別ファイル・stdin に持つため、"
         "foreign 台帳(非 '" + SELF_PFX + "' bead)を機械検査できず owner 2人違反を取りこぼす。これら高危険 write は禁止。"
         "read は `bd sql` の SELECT を `bd --readonly` 経由で、write は `bd update`/`bd dep` 等の id 明示形(自台帳 '" + SELF_PFX +
         "' bead に限定)を bdw 経由で実行せよ。")


def _parse_bd(args):
    """bd のグローバルフラグを消費し (sub, operands, foreign, has_readonly) を返す。
    sub = サブコマンド(無ければ None)。operands = sub 以降の token 列(グローバルフラグは除去済)。
    foreign = -C/--directory/--db/--global いずれか付与。has_readonly = --readonly 付与。
    グローバル persistent flag は sub の前後どちらにも置ける(cobra)ため args 全体を走査する。"""
    has_C = has_db = has_global = has_readonly = False
    sub = None
    operands = []
    i, n = 0, len(args)
    while i < n:
        t = args[i]
        if t in ("-C", "--directory"):
            has_C = True
            i += 2
            continue
        if t == "--db":
            has_db = True
            i += 2
            continue
        if t in ("--actor", "--dolt-auto-commit"):
            i += 2  # グローバル値フラグ(write 判定に無関係)＝値ごと消費
            continue
        if t.startswith("--directory=") or (t.startswith("-C") and len(t) > 2):
            has_C = True
            i += 1
            continue
        if t.startswith("--db="):
            has_db = True
            i += 1
            continue
        if t.startswith("--actor=") or t.startswith("--dolt-auto-commit="):
            i += 1
            continue
        if t == "--global":
            has_global = True
            i += 1
            continue
        if t == "--readonly":
            has_readonly = True
            i += 1
            continue
        if t in GLOBAL_BOOL_FLAGS:
            i += 1
            continue
        if t.startswith("-"):
            # sub 確定前の未知フラグはグローバル bool 扱いで消費(過剰な値スキップを避ける)。
            # sub 確定後の subcmd 固有フラグは operands に残す。
            if sub is None:
                i += 1
            else:
                operands.append(t)
                i += 1
            continue
        # 非フラグ token
        if sub is None:
            sub = t
        else:
            operands.append(t)
        i += 1
    return sub, operands, (has_C or has_db or has_global), has_readonly


def _positional_operands(operands):
    """operands 全体から positional token を順序保持で抽出する（フラグと値を除外）。
    bd(cobra/pflag)は flag と positional を interspersed に許すため、subcmd 直後の連続 positional
    だけを見る lead 抽出では `bd update --status closed un-9` のように値フラグの後ろに置かれた
    foreign bead を取りこぼす（→ deny されず最弱の kind 'c'=bdw 経由許可へ落ちる fail-open）。
    SUBCMD_VAL_FLAGS の値（次トークン）を skip して positional のみ集めることで、`--assignee un-bot`
    等の偶発 id 誤検出（J5）を避けつつ取りこぼしを防ぐ。`--flag=value` glued 形は値が glued ゆえ
    次トークン消費不要で自然に除外される。未知の値フラグは値を消費しない＝その次の bead-id は
    positional 扱いで安全側に拾う（取りこぼし不可を優先）。"""
    out = []
    i, n = 0, len(operands)
    while i < n:
        a = operands[i]
        if a.startswith("-"):
            # bare value-flag（glued = 形は除く）なら次トークンを値として skip。
            if a in SUBCMD_VAL_FLAGS and "=" not in a:
                i += 2
            else:
                i += 1
            continue
        out.append(a)
        i += 1
    return out


def _blocks_value(operands):
    """dep の --blocks / -b の値(= dependency を受ける blocked 側 = dependent)を返す(無ければ None)。"""
    for i, a in enumerate(operands):
        if a in ("--blocks", "-b"):
            return operands[i + 1] if i + 1 < len(operands) else None
        if a.startswith("--blocks="):
            return a.split("=", 1)[1]
        if a.startswith("-b") and len(a) > 2 and not a.startswith("-b="):
            return a[2:]
        if a.startswith("-b="):
            return a.split("=", 1)[1]
    return None


def _foreign_beads(ids):
    """id 群のうち bd-id 形かつ非 sc- prefix のもの。"""
    return [t for t in ids if BD_ID_RE.match(t) and not t.startswith(SELF_PFX)]


def _check_dep(operands, foreign, is_link=False):
    """bd dep / bd link の判定。返り値 (kind, reason) or None。
    positional は _positional_operands で interspersed flag を貫通して抽出する（順序保持）ため、
    `bd dep add --type blocks un-1 sc-2` のように flag が前置されても dependent(第1 positional)を
    取りこぼさない。

    is_link=True: `bd link <id1> <id2>` は bd 自身のヘルプで「Shorthand for 'bd dep add <id1> <id2>'」
    と明記された dep add の完全な同義サブコマンド（id1=dependent, id2=depends-on）。link には
    sub-action token（add/remove 等）が無く第1 positional が即 dependent ゆえ、`add` 意味論を直接適用する
    （dependent=pos[0] のみ (b) 判定、depends-on=pos[1:] は cross-rig 許容=J3）。`--type` は SUBCMD_VAL_FLAGS
    に含まれ _positional_operands が値を skip するため positional 抽出に混入しない。これにより `bd link`
    が generic write 経路へ落ちて J3 が保護する cross-rig 連結操作を誤 deny する回帰を解消する。"""
    pos = _positional_operands(operands)
    if is_link:
        # link は action 無し＝pos[0] が即 dependent。`bd dep add <pos...>` と同一に扱うため
        # 仮想 action 'add' を前置して以降の add 分岐へ合流させる（dependent=pos[0]=add の pos[1]）。
        pos = ["add"] + pos
    action = pos[0] if pos else None
    if not is_link and action in DEP_READ:
        return None  # dep list/tree/cycles = read（link には read sub-action は無い）
    if foreign:
        return ("a", MSG_A)
    blocks_val = None if is_link else _blocks_value(operands)
    if action in ("add", "remove"):
        # `bd dep add|remove <dependent> <depends-on...>`: 依存を持つ側 = 第1 operand(pos[1])。
        # depends-on(pos[2:])は cross-rig で foreign 可ゆえ (b) 判定対象外(J3)。
        targets = pos[1:2]
    elif action in ("relate", "unrelate"):
        # 双方向 relates_to。両 operand が mutate されるため全 operand を判定対象にする。
        targets = pos[1:]
    elif blocks_val is not None:
        # 直接形 `bd dep <blocker> --blocks <blocked>` = add <blocked> <blocker>: dependent = blocked。
        targets = [blocks_val]
    else:
        # action 不明・--blocks 無しの直接形等 → 安全側で全 bd-id を判定対象。
        targets = [a for a in pos if BD_ID_RE.match(a)]
    fb = _foreign_beads(targets)
    if fb:
        return ("b", MSG_B + " ".join(fb))
    return ("c", MSG_C)


def _check_repo(operands, foreign):
    """bd repo の判定。返り値 (kind, reason) or None(allow)。
    `repo list`(+ bare `repo` / `repo --help`)は read として allow、`repo add`/`repo remove`/
    `repo sync` は self-config / local-DB mutate ゆえ bdw 直列化(kind 'c')へ。foreign(-C/--db/--global)
    は repo sub-action 問わず一律 deny(kind 'a')＝guard 全体の (a) ルールを repo にも貫かせる。
    repo は config/local-DB を対象にし foreign bead を operand に取らないため (b) prefix 判定は適用しない。"""
    pos = _positional_operands(operands)
    action = pos[0] if pos else None
    if action is None or action in REPO_READ:
        return None  # bare repo / repo list / repo --help = read
    if foreign:
        return ("a", MSG_A)
    return ("c", MSG_C)  # repo add / remove / sync = local-DB mutate → bdw 直列化（連結正路を壊さない）


def check_bd(core):
    """bd コマンドの token 列を判定。(kind, reason) を返す(kind: 'a'|'b'|'c')か None(allow)。"""
    sub, operands, foreign, has_readonly = _parse_bd(core[1:])
    if sub is None:
        return None  # bd 単体 / --help / --version 等
    if has_readonly:
        return None  # --readonly は bd 自身が write を block する＝read 強制ゆえ allow(foreign read 安全)
    if sub in READ_SUBCMDS:
        return None

    if sub == "dolt":
        # J2: dolt は同期系。自台帳の同期点(push/commit/status)は allow、foreign のみ deny。
        if foreign:
            return ("a", MSG_A)
        return None

    if sub == "dep":
        return _check_dep(operands, foreign)

    if sub == "link":
        # `bd link <id1> <id2>` = bd 自身が「Shorthand for 'bd dep add <id1> <id2>'」と明記する dep add
        # の同義サブコマンド。dep と同じ cross-rig(J3)判定へ振り向け、`bd link sc-1 un-2`(=連結 substrate の
        # 正路)を generic write 経路の誤 deny(kind 'b')から救う。
        return _check_dep(operands, foreign, is_link=True)

    if sub == "repo":
        # 連結 substrate hydrate。list=read allow / add|remove|sync=bdw。
        return _check_repo(operands, foreign)

    if sub in HIGH_DANGER_WRITE:
        # J6: sql/batch/import は id を引数(positional)で取らず、対象 bead が SQL 文字列・別ファイル・
        # stdin 内にあるため (a)(b) の id ベース foreign 判定を素通りし最弱 kind 'c' へ落ちていた
        # （bd sql は INSERT/UPDATE/DELETE で storage 層 bypass・bd batch は任意 id で close/update/dep
        # を実行可＝foreign を確実に mutate できる write modality）。脅威モデル「foreign write を機械で
        # 確実に止める」が成立しないため、自台帳指定でも一律 deny(kind 'a')し『foreign を触りうる id 不明
        # write は --readonly か bd dep/update の id 明示形に限定せよ』へ差し戻す（取りこぼし不可=J1 整合）。
        return ("a", MSG_D)

    # その他 write 候補(bead-RMW + maintenance + 未知 subcmd = J1 安全側 write 扱い)
    if foreign:
        return ("a", MSG_A)
    if sub in CREATE_LIKE:
        # J7: 新規作成は sc- 自動採番・positional は title/本文ゆえ既存 foreign bead を mutate しない。
        # (b) を適用すると bare title 中の id 形語を foreign 誤認し over-block するため (b) を飛ばし (c) へ。
        return ("c", MSG_C)
    pos = _positional_operands(operands)
    fb = _foreign_beads(pos)
    if fb:
        return ("b", MSG_B + " ".join(fb))
    return ("c", MSG_C)


def classify(cmd, cwd):
    """cmd 中の最初に違反する bd 呼び出しを (code, kind, reason) で返す。違反無しは (0, None, "")。
    注: classify/decide は **session 非依存の純 prefix-rule**（cwd は iter_commands の segment cwd 用のみ）。
    session self-scope は main_decide で別層として被せる（既存 self-test を hermetic に保つため）。"""
    if not cmd:
        return 0, None, ""
    for core, _seg_cwd in iter_commands(cmd, cwd):
        if not core or os.path.basename(core[0]) != "bd":
            continue  # bdw 等(basename != "bd")は guard 対象外＝そのまま通過
        res = check_bd(core)
        if res:
            kind, reason = res
            return 2, kind, reason
    return 0, None, ""


def render(reason):
    return f"DENIED(bd): {reason}\n"


def decide(cmd, cwd):
    code, _kind, reason = classify(cmd, cwd)
    return code, (render(reason) if code else "")


def main_decide(cmd, cwd):
    """session self-scope を被せた最終判定（hook の実エントリが使う・D1）。
    非 scribe session（cwd の台帳 dolt_database != SELF_PREFIX・判定不能を含む）では prefix-rule を
    一切適用せず (0, "") で no-op（plugin global enable 時に他 project の bd 操作を壊さない）。scribe
    session のみ従来の prefix-rule 判定(decide)を適用する。判定は session cwd（hook payload top-level cwd）
    基準であって segment cwd ではない。present-but-unreadable は fail-closed（scribe session とみなす）。"""
    if not _is_scribe_guard_session(cwd):
        return 0, ""
    return decide(cmd, cwd)


def main():
    # consume preamble の introspection（preamble self-test が subprocess 経由で
    # 「どの cmdtokens lib が load されたか」を guard 本体に問うための隠しフラグ）。
    # import 前文（上部の consume preamble）が解決した cmdtokens.__file__ をそのまま返す。
    if "--print-cmdtokens-lib" in sys.argv:
        if iter_commands is None:  # 解決 path で import 失敗（既定 path 破壊 等）→ silent exit0 を防ぐ
            sys.stderr.write(f"[bd-guard] cmdtokens load failed: {_cmdtokens_load_error}\n")
            return 1
        sys.stdout.write(sys.modules["cmdtokens"].__file__ + "\n")
        return 0
    if "--self-test" in sys.argv:
        # 既定（CMDTOKENS_LIB 未設定で本プロセスが引いた）path で tokenizer が load 不能なら、他 battery は
        #   iter_commands 依存で crash するため即 RED 終了（silent-green を断つ）。
        if iter_commands is None:
            print(f"FAIL: [preamble] cmdtokens load 失敗（既定/解決 path 不正）: {_cmdtokens_load_error}")
            print("bd-guard self-test: ABORTED (cmdtokens 未 load)")
            return 1
        rc = run_self_test()
        rc_session = run_session_self_test()
        rc_preamble = run_preamble_self_test()
        return rc or rc_session or rc_preamble
    try:
        # stdin.read() も try 内に置く（sc-a7t: 非UTF-8 raw バイトの UnicodeDecodeError を捕捉して
        # 整形 fail-open(exit0)へ倒す。try 外だと未捕捉例外で exit1 化し fail-open 経路と不整合になる）。
        # 本 guard の失敗時方針=入力解析例外は fail-open exit0（上記 header・scribe git/rm guard と同方針）を
        # honour する（orch 版は try 外だが scribe の git/rm guard は sc-a7t で try 内へ収めており、本 guard も
        # 同 family として揃える＝criterion 5 の wire fail-open を非UTF-8 stdin でも成立させる・sc-wdr gate）。
        raw = sys.stdin.read() if not sys.stdin.isatty() else ""
        data = json.loads(raw) if raw.strip() else {}
        cmd = (data.get("tool_input") or {}).get("command", "") or ""
        cwd = data.get("cwd") or os.getcwd()
    except Exception as e:
        sys.stderr.write(f"[bd-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg = main_decide(cmd, cwd)
    except Exception as e:
        sys.stderr.write(f"[bd-guard] internal error, failing open: {e}\n")
        return 0
    if msg:
        sys.stderr.write(msg)
    return code


# --- self-test（hermetic: トークン判定のみ検証。subprocess も実 DB も触らない） -----------------
def run_self_test():
    CWD = "/home/shuu5/projects/local-projects/scribe"
    B, A = 2, 0
    # (cmd, expected_code, expected_kind_or_None, label)
    cases = [
        # --- (a) foreign target write は deny（read 対象外） ---
        ("bd -C /other/repo update un-1", B, "a", "foreign -C update"),
        ("bd --directory /x close un-2", B, "a", "foreign --directory close"),
        ("bd --db /foreign.db create --title x", B, "a", "foreign --db create"),
        ("bd --global update sc-1", B, "a", "global write (sc bead でも foreign target)"),
        ("bd -C /other update sc-1", B, "a", "foreign -C は sc bead でも deny"),
        ("bd -Cother update sc-1", B, "a", "foreign -C glued"),
        ("bd --db=/x.db close sc-1", B, "a", "foreign --db= glued"),
        ("bd update sc-1 -C /other", B, "a", "foreign -C after subcmd (cobra persistent)"),
        ("bd -C /other dolt push", B, "a", "foreign dolt push deny"),
        # --- foreign read は許可 ---
        ("bd -C /other show un-1", A, None, "foreign read: show"),
        ("bd -C /other list", A, None, "foreign read: list"),
        ("bd --db /x.db ready", A, None, "foreign read: ready"),
        ("bd -C /other --readonly update un-1", A, None, "readonly forces read → allow"),
        ("bd --readonly update sc-1", A, None, "readonly allow (self bead)"),
        ("bd --readonly dep add un-1 un-2", A, None, "readonly dep allow"),
        # --- (b) 非 sc- bead への bare write は deny ---
        ("bd update un-4sf --notes x", B, "b", "non-sc update"),
        ("bd close un-1 un-2", B, "b", "non-sc close multi"),
        ("bd note pk-037 -m x", B, "b", "non-sc note"),
        ("bd update un-1 sc-2", B, "b", "mixed: one non-sc → deny"),
        ("bd reopen un-9", B, "b", "non-sc reopen"),
        ("bd delete un-3", B, "b", "non-sc delete"),
        ("bd comment un-5 -m x", B, "b", "non-sc comment (write)"),
        ("bd supersede un-1 --with un-2", B, "b", "non-sc supersede"),
        ("bd defer un-7", B, "b", "non-sc defer"),
        # --- (b) foreign id が subcmd 固有フラグの後ろ(interspersed)でも deny（取りこぼし不可・J5） ---
        ("bd update --status closed un-9", B, "b", "flag-first: foreign id after --status → deny"),
        ("bd close --reason dup un-1", B, "b", "flag-first: foreign id after --reason → deny"),
        ("bd update --priority 1 pk-7", B, "b", "flag-first: foreign id after --priority → deny"),
        ("bd note -m hi un-5", B, "b", "flag-first: foreign id after -m → deny"),
        ("bd update --notes y un-1", B, "b", "flag-first: foreign id after --notes → deny"),
        ("bd update --status open -m note un-2", B, "b", "flag-first: foreign id after 2 value-flags → deny"),
        ("bd update --status closed --assignee me un-3", B, "b", "flag-first: skip --assignee value, catch un-3 → deny"),
        # --- (c) 自台帳(sc-)への bare write は bdw 経由へ block ---
        ("bd update sc-1 --notes x", B, "c", "sc bare update → bdw"),
        ("bd close sc-1 sc-2", B, "c", "sc bare close multi → bdw"),
        ("bd create --title x --type task", B, "c", "create (id 無し sc- 付与) → bdw"),
        ("bd q new thing here", B, "c", "q quick-create → bdw"),
        ("bd q implement un-9 handler", B, "c", "J7: q bare title with id-form word → c (not b over-block)"),
        ("bd q fix un-9 bug", B, "c", "J7: q title id token → c"),
        ("bd create implement un-9 handler", B, "c", "J7: create bare title id token → c"),
        ("bd create-form", B, "c", "J7: create-form → c"),
        ('bd q "fix un-9 bug"', B, "c", "J7: q quoted title → c (regression guard)"),
        ("bd note sc-5 -m x", B, "c", "sc note → bdw"),
        ("bd reopen sc-9", B, "c", "sc reopen → bdw"),
        ("bd update sc-1 --assignee un-bot", B, "c", "J5: flag value un-bot は誤検出しない(sc bead → c)"),
        ("bd update --assignee un-bot sc-1", B, "c", "J5: flag value un-bot は誤検出しない(flag-first, sc bead → c)"),
        ("bd update --status closed sc-9", B, "c", "flag-first: sc bead after --status → bdw (c, regress 無し)"),
        ("bd frobnicate sc-1", B, "c", "J1: 未知 subcmd は write 扱い(sc bead → c)"),
        ("bd frobnicate un-1", B, "b", "J1: 未知 subcmd + foreign bead → deny"),
        # --- (J6) sql/batch/import = id を引数で取らない高危険 write は一律 deny(a)（foreign 取りこぼし阻止） ---
        ("bd sql \"UPDATE issues SET status='closed' WHERE id='un-1'\"", B, "a", "J6: sql foreign UPDATE は positional に id 無し → deny(a)"),
        ("bd sql \"SELECT * FROM issues\"", B, "a", "J6: sql は SELECT でも一律 deny(over-block, read 代替案内) → a"),
        ("bd batch -f x", B, "a", "J6: batch file は任意 id を別ファイルに持つ → deny(a)"),
        ("bd batch < ops.txt", B, "a", "J6: batch stdin → deny(a)"),
        ("bd import < dump.jsonl", B, "a", "J6: import は任意 bead 投入で foreign 触りうる → deny(a)"),
        ("bd sql -C /other \"UPDATE issues SET x=1\"", B, "a", "J6: foreign sql も deny(a)"),
        # --- read subcmd は許可 ---
        ("bd show un-1", A, None, "show read (foreign id でも read は allow)"),
        ("bd list --status open", A, None, "list read"),
        ("bd ready", A, None, "ready read"),
        ("bd blocked", A, None, "blocked read"),
        ("bd search foo", A, None, "search read"),
        ("bd graph sc-1", A, None, "graph read"),
        ("bd export", A, None, "export read"),
        ("bd status", A, None, "status read"),
        ("bd history sc-1", A, None, "history read"),
        ("bd", A, None, "bd 単体 (sub None)"),
        ("bd --help", A, None, "bd --help"),
        ("bd version", A, None, "version read"),
        # --- dolt 同期点(自台帳)は許可 ---
        ("bd dolt push", A, None, "dolt push self = sync point allow"),
        ("bd dolt commit -m x", A, None, "dolt commit self allow"),
        ("bd dolt status", A, None, "dolt status read allow"),
        # --- repo: 連結 substrate hydrate（read/mutate を sub-action で分類） ---
        ("bd repo list", A, None, "repo list = read allow (誤検出解消)"),
        ("bd repo", A, None, "bare repo = read allow"),
        ("bd repo --help", A, None, "repo --help = read allow"),
        ("bd repo sync", B, "c", "repo sync = local-DB mutate → bdw (deny(a) せず連結正路を保つ)"),
        ("bd repo add project /path", B, "c", "repo add = self-config mutate → bdw"),
        ("bd repo remove project", B, "c", "repo remove = self-config mutate → bdw"),
        ("bd -C /other repo sync", B, "a", "foreign repo target → deny(a)"),
        ("bd repo sync && bd ready", B, "c", "compound: repo sync(c) は read 前に block"),
        # --- dep: read / cross-rig(J3) / foreign dependent ---
        ("bd dep list sc-1", A, None, "dep list read"),
        ("bd dep tree sc-1", A, None, "dep tree read"),
        ("bd dep cycles", A, None, "dep cycles read"),
        ("bd dep add sc-1 un-2", B, "c", "J3 cross-rig: sc depends on foreign → block(c) bdw (deny せず)"),
        ("bd dep add un-1 sc-2", B, "b", "dep add: foreign dependent → deny(b)"),
        ("bd dep add --type blocks un-1 sc-2", B, "b", "dep add flag-first: foreign dependent after --type → deny(b)"),
        ("bd dep add --type blocks sc-1 un-2", B, "c", "dep add flag-first: sc dependent + foreign depends-on → cross-rig (c)"),
        ("bd dep add sc-1 sc-2", B, "c", "dep add self↔self → bdw"),
        ("bd dep remove un-1 sc-2", B, "b", "dep remove: foreign dependent → deny"),
        ("bd dep sc-1 --blocks sc-2", B, "c", "direct form: blocked sc-2 dependent → bdw"),
        ("bd dep sc-1 --blocks un-2", B, "b", "direct form: blocked un-2 (foreign dependent) → deny"),
        ("bd dep relate un-1 sc-2", B, "b", "relate bidirectional: foreign operand → deny"),
        ("bd dep relate sc-1 sc-2", B, "c", "relate self↔self → bdw"),
        ("bd -C /x dep add sc-1 sc-2", B, "a", "foreign dep target → deny(a)"),
        # --- link: dep add の公式 shorthand。dep と対称な cross-rig(J3)判定 ---
        ("bd link sc-1 un-2", B, "c", "link = dep add shorthand: sc dependent + foreign depends-on → cross-rig (c) bdw"),
        ("bd link sc-1 un-9", B, "c", "link cross-rig: sc depends on foreign → block(c) (dep add と対称)"),
        ("bd link un-1 sc-2", B, "b", "link: foreign dependent(id1) → deny(b)"),
        ("bd link un-9 sc-1", B, "b", "link: foreign dependent(id1) → deny(b) (dep add と対称)"),
        ("bd link sc-1 sc-2", B, "c", "link self↔self → bdw"),
        ("bd link --type related sc-1 un-2", B, "c", "link --type: 値フラグ skip, sc dependent + foreign depends-on → cross-rig (c)"),
        ("bd link --type related un-1 sc-2", B, "b", "link --type: foreign dependent → deny(b) (--type 値 skip 後)"),
        ("bd -C /x link sc-1 un-2", B, "a", "foreign link target → deny(a)"),
        # --- launcher / inline / 透過経路 ---
        ("sudo bd update un-1", B, "b", "launcher: sudo"),
        ('bash -c "bd update un-1"', B, "b", "launcher: bash -c"),
        ("cd /foreign && bd update un-1", B, "b", "cd 先は無関係・bd update un-1 で deny"),
        ("cd /x && bd update sc-1", B, "c", "cd + sc bare → bdw"),
        ("flock /tmp/l bd update un-1", B, "b", "launcher: flock"),
        # --- FP regressions: bd 以外 / クォート内 / bdw 経由 は通す ---
        ("bdw update sc-1", A, None, "bdw wrapper bypasses guard (basename != bd)"),
        ("scripts/bdw close sc-1", A, None, "scripts/bdw path bypasses guard"),
        ('echo "bd update un-1"', A, None, "FP: echo containing bd update"),
        ('grep "bd close" file', A, None, "FP: grep bd close"),
        ("bd dolt push && rm -f x", A, None, "FP: dolt push allow + rm(non-bd) skip"),
        ("git commit -m 'bd update sc-1'", A, None, "FP: git with bd-looking message"),
        ("bd ready && bd show un-1", A, None, "FP: two reads"),
        ("bd show un-1 && bd update sc-9", B, "c", "compound: read ok, then sc write → bdw"),
    ]
    failures = []
    for cmd, want_code, want_kind, label in cases:
        try:
            code, kind, _reason = classify(cmd, CWD)
        except Exception as e:
            failures.append(f"[EXC] {label}: {cmd!r} -> {e}")
            continue
        if code != want_code:
            failures.append(f"[code {want_code} expected] {label}: {cmd!r} -> got code={code} kind={kind}")
        elif want_kind is not None and kind != want_kind:
            failures.append(f"[kind {want_kind!r} expected] {label}: {cmd!r} -> got kind={kind!r}")
    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bd-guard self-test: {len(failures)}/{len(cases)} FAILED")
        return 1
    print(f"bd-guard self-test: {len(cases)}/{len(cases)} OK")
    return 0


# --- session self-scope self-test（hermetic: temp .beads/metadata.json fixture・subprocess 非依存） ----
# D1: scribe(sc)session のみ guard を効かせ、非 sc session（orch/uns 'un' 等）では no-op する判定を、
# temp repo を2種(dolt_database=sc / un 相当)＋裸 cwd＋壊れた metadata で実証する。観点 (i)-(iv) を網羅:
# (i) 非 sc cwd の foreign write → exit0 / (ii) sc cwd の foreign write → deny / (iii) sc cwd の sc- bare →
# bdw 差し戻し / (iv) git 外・非 .beads cwd → exit0。_is_scribe_guard_session(fail-closed)を検証対象にする。
def run_session_self_test():
    import tempfile
    import shutil

    failures = []
    tmpdirs = []

    def mk_ledger(dolt_db):
        """dolt_database=<dolt_db> の .beads/metadata.json を持つ temp repo を作る。
        dolt_db=None なら .beads 無しの裸ディレクトリ、dolt_db='__broken__' なら不正 JSON(parse 失敗=①)、
        dolt_db='__nondict__' なら parse 成功だが非 dict(JSON 配列・②境界＝`else None` 分岐=fail-open 側)、
        dolt_db='__nokey__' なら parse 成功・dict だが dolt_database キー欠落(②境界＝`.get` が None を返す
        分岐=fail-open 側。__nondict__ と同じ None/fail-open へ畳まれるが **別 code path**)を書く。"""
        root = tempfile.mkdtemp(prefix="bdguard-st-")
        tmpdirs.append(root)
        if dolt_db is None:
            return root  # .beads 無し（git 外・非 beads cwd 相当）
        os.makedirs(os.path.join(root, ".beads"))
        meta = os.path.join(root, ".beads", "metadata.json")
        with open(meta, "w", encoding="utf-8") as f:
            if dolt_db == "__broken__":
                f.write("{ this is not valid json")
            elif dolt_db == "__nondict__":
                json.dump([1, 2, 3], f)  # parse 成功だが非 dict → `else None`（②境界・fail-open）
            elif dolt_db == "__nokey__":
                json.dump({"database": "dolt"}, f)  # dict だが dolt_database 欠落 → `.get`→None（②境界・fail-open）
            else:
                json.dump({"database": "dolt", "dolt_database": dolt_db}, f)
        return root

    try:
        sc_root = mk_ledger("sc")
        un_root = mk_ledger("un")
        bare_root = mk_ledger(None)
        broken_root = mk_ledger("__broken__")
        nondict_root = mk_ledger("__nondict__")
        nokey_root = mk_ledger("__nokey__")
        # 自前 .beads を持たない subdir → walk-up で親台帳を解決する。
        sc_sub = os.path.join(sc_root, "a", "b")
        os.makedirs(sc_sub)
        un_sub = os.path.join(un_root, "x")
        os.makedirs(un_sub)

        # (cwd, expect_is_scribe_guard, label)
        scope_cases = [
            (sc_root, True, "sc ledger root → scribe guard session"),
            (sc_sub, True, "sc subdir(自前 .beads 無)→ walk-up で sc"),
            (un_root, False, "un ledger root → 非 sc(no-op)"),
            (un_sub, False, "un subdir → 非 sc(no-op)"),
            (bare_root, False, ".beads 皆無の裸 cwd → fail-open(非 sc・区別ルール②不変)"),
            (broken_root, True, "不正 JSON metadata(present-but-unreadable)→ fail-closed(sc とみなし moat 維持・区別ルール①)"),
            (nondict_root, False, "非 dict JSON(parse 成功・②境界)→ fail-open(非 sc)。`else None` 分岐の恒久回帰 pin: ① と取り違え `_LEDGER_UNREADABLE` に倒すと True に反転しここで RED 化する"),
            (nokey_root, False, "dict だが dolt_database キー欠落(parse 成功・②境界)→ fail-open(非 sc)。`.get(\"dolt_database\")`→None 分岐の恒久回帰 pin（__nondict__ の `else None` とは別 code path で同じ None/fail-open へ畳む）: ① と取り違え `_LEDGER_UNREADABLE` に倒すと True に反転しここで RED 化する"),
        ]
        for cwd, want, label in scope_cases:
            try:
                got = _is_scribe_guard_session(cwd)
            except Exception as e:  # 決して die しない契約の検証
                failures.append(f"[EXC is_scribe_guard] {label}: {cwd!r} -> {e}")
                continue
            if got != want:
                failures.append(f"[is_scribe_guard {want} expected] {label}: {cwd!r} -> {got}")
        # cwd=None は main() が os.getcwd() へ解決後に main_decide へ渡すため production では到達しない経路だが、
        # _resolve_ledger が None で例外死しない（never-die 契約）ことだけ確認する（boolean 値は getcwd 依存＝
        # 非 hermetic ゆえ assert しない）。
        try:
            _ = _is_scribe_guard_session(None)
        except Exception as e:
            failures.append(f"[EXC is_scribe_guard] cwd=None で die: {e}")

        # 統合判定: main_decide が session-scope を正しく被せるか（観点 i-iv）。
        FOREIGN_WRITE = "bd update un-1 --notes x"   # sc session なら kind b で deny(2)
        SC_BARE = "bd update sc-1 --notes x"          # sc session なら kind c で bdw 差し戻し(2)
        # (cwd, cmd, expect_code, label)
        integ_cases = [
            (un_root, FOREIGN_WRITE, 0, "(i) 非 sc cwd の foreign write → exit0 allow(no-op)"),
            (un_root, SC_BARE, 0, "(i') 非 sc cwd では sc- bare write も no-op"),
            (sc_root, FOREIGN_WRITE, 2, "(ii) sc cwd の foreign write → deny 継続"),
            (sc_root, SC_BARE, 2, "(iii) sc cwd の sc- bare → bdw 差し戻し継続"),
            (sc_root, "bd show un-1", 0, "(ii') sc cwd でも foreign read は allow（回帰無し）"),
            (bare_root, FOREIGN_WRITE, 0, "(iv) 非 .beads cwd の foreign write → exit0 allow"),
            (broken_root, FOREIGN_WRITE, 2, "(iv') 不正 metadata cwd(present-but-unreadable)→ fail-closed sc session → foreign write deny(区別ルール①)"),
            (nondict_root, FOREIGN_WRITE, 0, "(iv'') 非 dict metadata cwd(②境界)→ fail-open 非 sc → foreign write は no-op allow（broken=deny と対の②側 end-to-end pin）"),
            (nokey_root, FOREIGN_WRITE, 0, "(iv''') nokey metadata cwd(dict・dolt_database 欠落・②境界)→ fail-open 非 sc → foreign write は no-op allow（nondict と同方向だが `.get`→None の別 code path・broken=deny と対の②側 end-to-end pin）"),
            (sc_sub, FOREIGN_WRITE, 2, "sc subdir の foreign write → walk-up で deny"),
            # 核心 security 不変条件の end-to-end pin: session 判定は session cwd 基準であって compound
            # 内の `cd` 先(segment cwd)に左右されない＝sc session が `cd <foreign> && bd update un-1`
            # しても従来どおり deny（session-gating + segment-cwd の相互作用を main_decide 経由で固定）。
            (sc_root, "cd " + un_root + " && bd update un-1 --notes x", 2,
             "sc session の compound cd→foreign write は segment cwd に左右されず deny"),
        ]
        for cwd, cmd, want_code, label in integ_cases:
            try:
                code, _msg = main_decide(cmd, cwd)
            except Exception as e:
                failures.append(f"[EXC main_decide] {label}: {cmd!r}@{cwd!r} -> {e}")
                continue
            if code != want_code:
                failures.append(f"[code {want_code} expected] {label}: {cmd!r}@{cwd!r} -> got {code}")
    finally:
        for d in tmpdirs:
            shutil.rmtree(d, ignore_errors=True)

    total = 9 + 11  # scope_cases 8 + cwd=None never-die 1 = 9 / integ_cases 11（②境界 nondict + nokey を各々追加）
    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bd-guard session self-test: {len(failures)}/{total} FAILED")
        return 1
    print(f"bd-guard session self-test: {total}/{total} OK")
    return 0


# --- consume preamble self-test（cmdtokens consume cutover 表面を pin） -----------------
# 上部 consume preamble（CMDTOKENS_LIB → 既定 plugin path 解決 + fail-open）の挙動回帰ガード。
# preamble は module import 時=プロセス起動時に env 依存で 1 度だけ走るため、in-process では再検証できない。
# よって guard 自身を subprocess で起動し env を変えて挙動を観測する（契約 (a)(c) を機械化）。
# 検証する 3 観点（plugin 不在ホストでも (override)/(c) が実 load 経路を検証する＝tautology を排除する）:
#   (a) CMDTOKENS_LIB 空/未設定 → plugin 標準配置（~/.claude/plugins/cmdtokens/lib）から load し、
#       ローカル scripts/hooks/lib には依存しない（plugin 配置ありホストのみ・--print-cmdtokens-lib で確認）。
#   (override) CMDTOKENS_LIB を有効 dir（残置 local lib）へ向け → そこから実 load される（env override 成功
#       パス）。全ホストで実 load を検証＝plugin 不在ホストでも空回りしない回帰ガード。
#   (c) CMDTOKENS_LIB が存在しない path → import 失敗 → exit 0（fail-open）+ loud stderr 警告（全ホスト）。
# session self-test は temp fixture ゆえ本 preamble self-test（実 lib 配置依存）とは非依存。
def run_preamble_self_test():
    import subprocess

    failures = []
    checks = 0
    guard = os.path.realpath(__file__)
    plugin_lib_dir = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")
    expected_plugin_file = os.path.realpath(os.path.join(plugin_lib_dir, "cmdtokens.py"))
    local_lib_dir = os.path.join(os.path.dirname(guard), "lib")
    local_lib_file = os.path.realpath(os.path.join(local_lib_dir, "cmdtokens.py"))

    def _resolved_lib(env):
        """guard を subprocess 起動し、preamble が load した cmdtokens.__file__ を realpath で返す。"""
        p = subprocess.run(
            [sys.executable, guard, "--print-cmdtokens-lib"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        return os.path.realpath(p.stdout.strip()) if p.stdout.strip() else ""

    # (a) plugin 配置ありホストのみ: CMDTOKENS_LIB 未設定で既定 plugin path から load し local lib に依存しない。
    if os.path.isdir(plugin_lib_dir):
        checks += 1
        env_a = {k: v for k, v in os.environ.items() if k != "CMDTOKENS_LIB"}
        try:
            loaded = _resolved_lib(env_a)
        except Exception as e:
            loaded = ""
            failures.append(f"[EXC a] 既定解決 introspection 起動失敗: {e}")
        if loaded != expected_plugin_file:
            failures.append(
                f"[a] CMDTOKENS_LIB 未設定の解決先が plugin path でない: "
                f"got {loaded!r} want {expected_plugin_file!r}")
        if loaded.startswith(os.path.realpath(local_lib_dir) + os.sep):
            failures.append(
                f"[a] ローカル lib/ を引いている（plugin 非依存に反する）: {loaded!r}")

    # (override) 全ホスト: CMDTOKENS_LIB を有効 dir（残置 local lib）へ向け、そこから実 load されること。
    #   plugin 不在ホストでも env override 成功パスを実検証する（tautology 排除）。
    checks += 1
    if not os.path.isfile(local_lib_file):
        failures.append(f"[override] 残置 local lib が無い（KEEP 契約違反の疑い）: {local_lib_file!r}")
    else:
        env_o = dict(os.environ)
        env_o["CMDTOKENS_LIB"] = local_lib_dir
        try:
            loaded_o = _resolved_lib(env_o)
            if loaded_o != local_lib_file:
                failures.append(
                    f"[override] CMDTOKENS_LIB 指定 dir から load していない: "
                    f"got {loaded_o!r} want {local_lib_file!r}")
        except Exception as e:
            failures.append(f"[EXC override] env override introspection 起動失敗: {e}")

    # (c) 全ホスト: 存在しない CMDTOKENS_LIB → fail-open（exit 0）+ loud stderr 警告。
    #   cwd は hermetic な temp sc ledger（dolt_database=sc）にする。sc cwd なら「正常 lib＝foreign write
    #   deny(exit 2) / lib 不能＝fail-open(exit 0)」で exit-code が真に弁別する（vacuous 化しない）。
    import tempfile
    import shutil
    checks += 1
    _c_root = tempfile.mkdtemp(prefix="bdguard-pre-c-")
    try:
        os.makedirs(os.path.join(_c_root, ".beads"))
        with open(os.path.join(_c_root, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            json.dump({"database": "dolt", "dolt_database": "sc"}, f)
        _c_input = json.dumps(
            {"tool_input": {"command": "bd update un-1 --status closed"}, "cwd": _c_root})
        env_c = dict(os.environ)
        env_c["CMDTOKENS_LIB"] = f"/nonexistent/cmdtokens/path/{os.getpid()}"
        p = subprocess.run(
            [sys.executable, guard], input=_c_input,
            env=env_c, capture_output=True, text=True, timeout=30,
        )
        if p.returncode != 0:
            failures.append(f"[c] fail-open でない: exit {p.returncode}（期待 0）")
        if "cannot load cmdtokens lib, failing open" not in p.stderr:
            failures.append(f"[c] loud stderr 警告が出ていない: stderr={p.stderr!r}")
        # 弁別力の pin: 同じ sc cwd + 同入力で「正常 lib」なら foreign write deny(exit 2) になるはず
        #   ＝exit-code が fail-open を真に判別する（vacuous でない）ことを保証。
        p_ok = subprocess.run(
            [sys.executable, guard], input=_c_input,
            env={k: v for k, v in os.environ.items() if k != "CMDTOKENS_LIB"},
            capture_output=True, text=True, timeout=30,
        )
        if p_ok.returncode != 2:
            failures.append(
                f"[c] 弁別力欠如: 正常 lib + sc cwd で foreign write が deny(2) でない: exit {p_ok.returncode}")
    except Exception as e:
        failures.append(f"[EXC c] fail-open 起動失敗: {e}")
    finally:
        shutil.rmtree(_c_root, ignore_errors=True)

    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"bd-guard preamble self-test: {len(failures)} FAILED (of {checks} checks)")
        return 1
    print(f"bd-guard preamble self-test: {checks}/{checks} OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

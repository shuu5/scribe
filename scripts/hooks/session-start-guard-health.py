#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# session-start-guard-health.py — scribe の plugin 不在を loud 化する SessionStart health-check（sc-ovq）。
#
# 役割（単一責務ゆえ role-inject に混ぜず別ファイル）: scribe session の起動時に、scribe が **canonical
#   plugin を consume する 2 つの依存** がロード可能かを検査し、不能なら ⚠️ banner を SessionStart stdout
#   （= context 注入）へ loud 化して復旧法を提示する。plugin 不在ホストでは両依存が **silent に劣化**する:
#
#   - probe A = cmdtokens: git/rm の destructive guard は consume preamble で canonical cmdtokens lib を
#     import する。不在なら両 guard は preamble の **fail-open（exit 0）で破壊コマンドを素通し**＝セキュリティ
#     後退が無警告（moat が黙って消える）。
#   - probe B = beads-bdw: `scripts/bdw`（shim→canonical beads-bdw plugin）は不在なら **fail-closed** で
#     bd write 不可。sandbox-ON worker は sc-vae の preflight が worktree add 前に止めるが、起動時の可視
#     警告は無い。sandbox-OFF worker は preflight を通らず起動し、全 bd write が shim fail-closed で台帳に
#     残らない **zombie worker** になる（その spawn 前 fail-loud は scribe-spawn.sh 側＝sc-ovq(2) で別途封鎖）。
#   - probe B2 = beads-bdw の PreToolUse **wire**（sc-8e7i）: bd-write moat（bare `bd` write を止める
#     canonical bd-write-guard）は probe B が見る bin/bdw とは **別ファイル・別系統**。sc-q2kn で scribe
#     同梱の bespoke guard を撤去した結果 moat は wire 1 本に依存する構造になったが、wire が両経路とも
#     切れても `bdw lock-dir` は rc==0 のまま＝**moat 消失が banner 無音**（撤去で新たに開いた面）。
#     probe B2 は「canonical guard へ届く PreToolUse[Bash] wire が 1 本以上あるか」を read-only で検査する。
#
# port 元: scriptorium scripts/hooks/session-start-guard-health.py（cmdtokens 版・bd orch-hos の案A loud 化）。
#   本 hook は同 pattern を scribe へ port し、**cmdtokens に加え beads-bdw も 1 本で probe する**。
#
# self-scope（最重要・誤注入ゼロ）: 本 hook を plugin として global enable すると SessionStart は **全
#   セッション**で発火する。scribe session（cwd walk-up の `.beads/metadata.json` dolt_database == "sc"）で
#   のみ banner を出し、foreign（orchestrator の orch session・uns 'un'…）・台帳外・判定不能は無出力 exit0。
#   orchestrator の orch session も `.beads` を持つが、そこは orch-hos の guard-health が既に warn するため、
#   scribe の banner が orch session で二重発火しないよう **dolt_database=='sc' で厳密に絞る**（role-inject の
#   `.beads` opt-in より厳密＝台帳 identity ベース）。判定は共有 lib scripts/hooks/lib/scribe_session.py の
#   `_is_scribe_session` を使う（positive-match＝確定 self だけ firing・banner ゆえ過小発火＝安全側）。
#
# fail-safe（全セッション破壊の防止）: 判定不能・例外でもセッションを壊さない。**常に exit 0（degrade）**。
#   scribe_session lib をロードできない（session 判定不能）ときは banner を出さず no-op（誤注入ゼロを優先）。
#   本 hook は決して die しない。orch-hos と同型の fail-safe を厳守する。
#
# probe fidelity（残置 copy への silent fallback 防止・orch-hos と同型）: scripts/hooks/lib/ には cmdtokens の
#   残置 copy（lib/cmdtokens.py・defense-in-depth）が在る。import 後に hook lib dir を sys.path から外し、
#   canonical 不在時に残置 copy へ silent fallback して「load 可」と誤判定するのを防ぐ。guard の consume
#   preamble は cmdtokens を hook lib dir 追加**前**に import するため残置へ fallback しない＝health-check も
#   同順序を再現する（scribe_session は sys.modules に載った後ゆえ path 除去で unload されない）。
#
# 検証: tests/guard-health-banner.bats（hermetic E2E + hooks.json wire）+ 本 file の `--self-test`（in-process・
#   fail-closed・非vacuous）。

import sys
import os
import json
import re
import subprocess

# --- scribe_session 共有 lib（session self-scope の SSOT） -------------------------------------------------
# logic ゼロの薄い解決層: 同梱 lib/ を sys.path 解決して import するだけ。ロード不能なら session 判定が
# できない → banner を誤発火させないため no-op に倒す（フラグで記録し _run が見る）。
# import 後に hook lib dir を path から外す（probe fidelity・上記ヘッダ参照）。
_HOOK_LIB_DIR = os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib")
_scribe_session_load_error = None
try:
    sys.path.insert(0, _HOOK_LIB_DIR)
    from scribe_session import SELF_PREFIX, _is_scribe_session  # noqa: E402
except Exception as e:  # 同梱 lib ロード不能 → session 判定不能 → no-op（誤注入ゼロ・fail-safe）
    _scribe_session_load_error = e
    SELF_PREFIX = "sc"

    def _is_scribe_session(cwd):  # fallback（import 成功時は from-import に上書きされ未使用）
        return False
finally:
    try:
        sys.path.remove(_HOOK_LIB_DIR)  # 残置 cmdtokens copy を probe から不可視化（guard と同順序）
    except ValueError:
        pass


# === probe A: cmdtokens（git/rm destructive guard の consume 依存） ========================================
# cmdtokens 解決の既定（git-guard / rm-guard の consume preamble と同一値）。env CMDTOKENS_LIB > 既定。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")

# 両 guard が consume preamble で import する公開 API の **和集合**（両 guard load の正確な代理）:
#   - git-destructive-guard.py : iter_commands, long_opt_abbrev
#   - rm-destructive-guard.py  : SHELLS, VAR_OR_SUBST, parse_statements, peel, shlex_safe,
#                                strip_redirections, track_cd, long_opt_abbrev
# どちらか一方でも欠ければ該当 guard が fail-open で無効化されるため、和集合の全 API を要求する。
_CMDTOKENS_API = (
    "iter_commands", "long_opt_abbrev",
    "SHELLS", "VAR_OR_SUBST", "parse_statements", "peel", "shlex_safe",
    "strip_redirections", "track_cd",
)


def _resolve_cmdtokens_lib():
    """cmdtokens lib dir を consume preamble と同一規則で解決する（env CMDTOKENS_LIB|既定・非絶対は既定へ）。
    env 値・default とも expanduser する。"""
    lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
    if not os.path.isabs(lib):  # 非絶対（空/相対/whitespace）→ cwd 相対 poison を避け既定へ（preamble と同一）
        lib = _CMDTOKENS_DEFAULT_LIB
    return lib


def _probe_cmdtokens():
    """cmdtokens plugin lib をロードできるか probe する。(ok: bool, lib_path: str, error|None) を返す。
    consume preamble と同一の解決・同一 API 集合（和集合）の import を試行する。sys.modules / sys.path を
    probe 前後でリセット/復元し、複数回 probe（self-test）でも毎回 fresh 解決になるようにする。"""
    lib = _resolve_cmdtokens_lib()
    sys.modules.pop("cmdtokens", None)  # 既存 cache を落として fresh 解決を保証
    saved_path = list(sys.path)
    try:
        # probe path = [lib] + (現 path から hook lib dir を除外)。module top で除去済だが、防御的に
        # 残置 copy（scripts/hooks/lib/cmdtokens.py）を確実に不可視化し canonical のみで loadability を判定。
        sys.path = [lib] + [p for p in sys.path
                            if os.path.abspath(p) != os.path.abspath(_HOOK_LIB_DIR)]
        mod = __import__("cmdtokens")
        missing = [name for name in _CMDTOKENS_API if not hasattr(mod, name)]
        if missing:
            return False, lib, "cmdtokens に必須 API 欠落: " + ", ".join(missing)
        return True, lib, None
    except Exception as e:  # lib 不在 / import 失敗 → 両 guard が fail-open で無効化される状態
        return False, lib, e
    finally:
        sys.path = saved_path
        sys.modules.pop("cmdtokens", None)  # probe で載せた module を残さない（次 probe の fresh 解決）


# === probe B: beads-bdw（scripts/bdw shim→canonical の到達性） =============================================
def _resolve_bdw():
    """`scripts/bdw` shim の絶対パスを返す（hook は scripts/hooks/ ゆえ ../bdw）。sc-vae preflight と
    **同一の解決経路**（shim→canonical→resolve_lock_dir）を踏ませて drift を避ける。"""
    return os.path.join(os.path.dirname(os.path.realpath(__file__)), "..", "bdw")


def _probe_bdw():
    """canonical beads-bdw が到達可能か probe する。(ok: bool, bdw_path: str, error|None) を返す。
    sc-vae の preflight と同一に `scripts/bdw lock-dir`（shim→canonical）を実行し rc==0 を確認する
    （単なる存在チェックより強く、BEADS_BDW 解決→canonical→resolve_lock_dir の chain 全体を検査＝gen と
    drift しない）。subprocess は例外を握り潰し、何があっても die しない（fail-safe）。"""
    bdw = _resolve_bdw()
    try:
        if not (os.path.isfile(bdw) and os.access(bdw, os.X_OK)):
            return False, bdw, "scripts/bdw shim が存在しない/実行不可"
        proc = subprocess.run(
            [bdw, "lock-dir"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=8,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or b"").decode("utf-8", "replace").strip() or "bdw lock-dir が非0 で終了"
            return False, bdw, detail
        return True, bdw, None
    except Exception as e:  # 実行不能 / timeout → canonical 未配備 or 解決失敗とみなす
        return False, bdw, e


# === probe B2: bd-write moat（PreToolUse[Bash] wire の実配線） =============================================
# probe B（上）は `scripts/bdw lock-dir` = bd write の **実行系**（直列化 funnel の到達性）しか見ない。
# だが「bare `bd` write を止める moat」はそれとは別系統で、universal な canonical guard
#   `beads-bdw/scripts/hooks/bd-write-guard.py` へ PreToolUse[Bash] から届く wire が担う。sc-q2kn で
# scribe 同梱の bespoke bd-write-guard を撤去した結果、moat は **この wire だけ** が支える構造になった。
# probe B は wire が両方切れても rc==0 のまま（bin/bdw と guard は別ファイル）＝moat 消失が **banner 無音**
# になる面が新たに開いた（sc-8e7i）。本 probe はその面を塞ぐ。既知の wire 経路は 2 種:
#   (a) settings.json 経由 shim: PreToolUse[Bash] → $HOME/.claude/scripts/bd-write-guard.py → execvp canonical
#       （本ホストの deny 発生元・un-hf2l）。plugin enablement / cld ラッパに非依存な universal net。
#   (b) beads-bdw plugin の hooks/hooks.json: PreToolUse[Bash] → ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/…
# どちらか 1 本でも canonical へ届いていれば moat は生きている＝silent。両方欠けたときだけ loud 化する。
#
# 検査は **read-only**（設定ファイルの読取のみ・$HOME/.claude/** への write もプロセス起動もしない）。
# canonical の解決規則は settings shim と **byte 同義**（env BD_WRITE_GUARD > 既定 plugin 標準配置）に保つ。
#
# 可用性 gate は **wire 経路ごとに実配線と極性を揃える**（両者は同一ではない・verified 2026-07-21）:
#   (a) settings shim: `test -f "$HOME/.claude/scripts/bd-write-guard.py" && python3 …` で **shim 本体**を起動し、
#       shim は `isfile(CANON) and access(CANON, R_OK)` で gate して `execvp python3 CANON` する。
#       ⇒ live 条件 = 「command が参照する shim 本体が isfile+R_OK」かつ「canonical が isfile+R_OK」。
#          shim 本体が消えていれば `test -f` が偽で && が短絡し guard は一切起動しない＝moat は死んでいる。
#   (b) plugin hooks.json: `SCRIPT=…; if [ -x "$SCRIPT" ]; then python3 "$SCRIPT"; else exit 0; fi`
#       ⇒ gate は **X_OK**。canonical が 0644（読めるが非実行）だと plugin hook は exit0 で fail-open。
#          ⇒ live 条件 = 「canonical が isfile+R_OK かつ X_OK」。
#       ⇒ 探索先は **$CLAUDE_CONFIG_DIR/plugins/beads-bdw**（CC の plugin enablement は config dir ごとに
#          独立ゆえ ~/.claude 固定では追従できない・sc-8e7i の false-silent 修正）。詳細 = _plugin_root()。
# どちらか 1 本でも live なら moat は生きている＝silent（和集合）。全経路が非 live のときだけ loud 化する。
# ＝「各経路が fail-open する条件をそのまま moat 消失と読む」（経路をまたいで gate を混同すると検出器自身が
#   false-silent になる: R_OK だけを見ると (b) 単独構成の 0644 canonical を、宣言だけを見ると (a) の shim 不在を
#   それぞれ見逃す）。
_BD_WRITE_GUARD_DEFAULT = os.path.expanduser("~/.claude/plugins/beads-bdw/scripts/hooks/bd-write-guard.py")


def _resolve_bd_write_guard():
    """canonical bd-write-guard の絶対パスを settings shim と同一規則で解決する（env BD_WRITE_GUARD > 既定）。
    非絶対（空/相対/whitespace）は cwd 相対 poison を避け既定へ落とす（_resolve_cmdtokens_lib と同型）。"""
    p = os.path.expanduser(os.environ.get("BD_WRITE_GUARD") or _BD_WRITE_GUARD_DEFAULT)
    if not os.path.isabs(p):
        return _BD_WRITE_GUARD_DEFAULT
    return p


def _config_dir():
    """CC が user settings を読む config dir（env CLAUDE_CONFIG_DIR > ~/.claude）。非絶対は既定へ。"""
    d = os.path.expanduser(os.environ.get("CLAUDE_CONFIG_DIR") or "~/.claude")
    if not os.path.isabs(d):
        return os.path.expanduser("~/.claude")
    return d


def _plugin_root():
    """CC が **その session で実際に load する** beads-bdw plugin root を返す（sc-8e7i の false-silent 修正）。

    CC の plugin enablement は config dir ごとに独立（scribe-spawn.sh の preflight(c) も `$_d/plugins/$_p`
    実在を config dir 単位で検査する＝本リポ自身が前提にしている事実）。本ホストは全 session が
    per-account config dir（CLAUDE_CONFIG_DIR）で走るため、~/.claude 固定で読むと **その session が決して
    load しない hooks.json** を根拠に「moat 生存」と誤判定して silent になる（＝検出器自身の false-silent）。
    ゆえに plugin 経路の root は _config_dir() から導出する。

    BD_WRITE_GUARD を明示したときだけ従来どおり env を単一起点にする（canonical を移すと wire 検査先も
    一緒に移る＝fixture 等の意図的な差し替えを尊重）。settings 経路の canonical は shim が hardcode する
    ~/.claude/plugins/… のままで正しい（shim と byte 同義を維持）ゆえ _resolve_bd_write_guard() 側に残す。
    """
    env = os.environ.get("BD_WRITE_GUARD")
    if env and os.path.isabs(os.path.expanduser(env)):
        canon = _resolve_bd_write_guard()
        return os.path.dirname(os.path.dirname(os.path.dirname(canon)))
    return os.path.join(_config_dir(), "plugins", "beads-bdw")


def _matcher_covers_bash(matcher):
    """PreToolUse group の matcher が Bash を含むか。空/'*' は全 tool matcher とみなす（CC 既定意味論）。
    matcher は "Read|Glob|Grep|Bash" のような alternation 文字列ゆえ部分一致で足りる。"""
    if not matcher:
        return True
    return matcher == "*" or "Bash" in matcher


def _bd_write_wire_commands(hooks_doc):
    """hooks 設定 dict の PreToolUse[Bash] から bd-write-guard を参照する command 文字列を列挙する。
    read-only な純関数。空 list = wire 宣言なし（旧 _declares_bd_write_wire の False に対応）。"""
    cmds = []
    try:
        groups = (hooks_doc.get("hooks") or {}).get("PreToolUse") or []
        for group in groups:
            if not _matcher_covers_bash(group.get("matcher")):
                continue
            for h in group.get("hooks") or []:
                cmd = h.get("command") or ""
                if "bd-write-guard" in cmd:
                    cmds.append(cmd)
    except Exception:
        return []  # 想定外の形（list でない等）→ wire 無しとみなす（安全側＝over-warn）
    return cmds


# command 中の guard script path を静的に取り出す regex。先頭境界を要求して `${CLAUDE_PLUGIN_ROOT}/scripts/...`
# のような **変数直後の相対断片** を絶対 path と誤読しない（誤読すると存在しない /scripts/... を見て over-warn する）。
_GUARD_PATH_RE = re.compile(
    r"""(?:^|(?<=[\s"'=;|&(]))((?:\$\{HOME\}|\$HOME|~|/)[^\s"';|&()]*bd-write-guard[^\s"';|&()]*\.py)""")


def _referenced_guard_paths(command):
    """command 文字列が起動する guard script の絶対 path を静的に取り出す（$HOME/${HOME}/~ のみ expand）。
    展開しきれない変数を含む path は「静的に決定できない」として捨てる＝判定は呼び元で live 側へ倒す。"""
    out = []
    for m in _GUARD_PATH_RE.finditer(command or ""):
        p = m.group(1).replace("${HOME}", "~").replace("$HOME", "~")
        p = os.path.expanduser(p)
        if os.path.isabs(p) and "$" not in p:
            out.append(p)
    return out


def _entrypoint_reachable(command):
    """settings wire の **起動対象**（shim 本体）が実在し読めるか。実配線の `test -f … && python3 …` と同極性。
    path を静的に取り出せない command は True（従来どおり live 扱い＝over-warn を増やさない安全側）。"""
    paths = _referenced_guard_paths(command)
    if not paths:
        return True
    return any(os.path.isfile(p) and os.access(p, os.R_OK) for p in paths)


def _load_json(path):
    """JSON を読む。読めない/壊れている場合は None（die しない）。"""
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _probe_bdw_wire():
    """bd-write moat（PreToolUse[Bash] → canonical bd-write-guard）が実配線されているか probe する。
    (ok: bool, canonical_path: str, detail: str, sources: list[str]) を返す。read-only・die しない。

    ok の条件は「**live な wire が 1 本以上ある**」。wire が live かは経路ごとの実 gate で判定する:
      (a) settings 経路: 起動される shim 本体が isfile+R_OK、かつ canonical が isfile+R_OK（shim の gate と同極性）。
      (b) plugin 経路 : **その session の config dir 配下の** plugin canonical が isfile+R_OK かつ X_OK
                        （hooks.json の `[ -x ]` gate と同極性）。root 導出は _plugin_root() を参照。
    宣言が在っても gate が不成立なら hook は exit0 で fail-open＝moat は消失しているので live と数えない。
    canonical は経路ごとに別物でありうる（settings=shim が hardcode する ~/.claude 側 / plugin=config dir 側）。
    """
    canon = _resolve_bd_write_guard()
    sources = []
    try:
        canon_readable = os.path.isfile(canon) and os.access(canon, os.R_OK)
        live = []

        # (a) settings.json / settings.local.json 経由 shim（CC が実際に読む config dir のみを見る）。
        cfg = _config_dir()
        for name in ("settings.json", "settings.local.json"):
            path = os.path.join(cfg, name)
            doc = _load_json(path)
            if doc is None:
                continue
            cmds = _bd_write_wire_commands(doc)
            if not cmds:
                continue
            if not any(_entrypoint_reachable(c) for c in cmds):
                # 宣言はあるが起動対象の shim 本体が不在/読取不可＝`test -f` が偽で && が短絡し guard は起動しない。
                sources.append("settings:SHIM-MISSING:" + path)
            elif not canon_readable:
                sources.append("settings:NO-CANON:" + path)  # shim は起動するが canonical へ届かず exit0。
            else:
                sources.append("settings:" + path)
                live.append("settings:" + path)

        # (b) beads-bdw plugin の hooks/hooks.json。root は **CC がその session で load する** config dir 配下
        #     （BD_WRITE_GUARD 明示時のみ canonical から 2 段上る＝env が単一起点）。~/.claude 固定で読むと
        #     per-account config dir 環境で「load されない hooks.json」を根拠に silent になる（sc-8e7i）。
        #     canonical も plugin root 配下のものを見る（settings 経路の canonical とは別物でありうる）。
        root = _plugin_root()
        plugin_canon = os.path.join(root, "scripts", "hooks", "bd-write-guard.py")
        plugin_canon_readable = os.path.isfile(plugin_canon) and os.access(plugin_canon, os.R_OK)
        plugin_canon_exec = plugin_canon_readable and os.access(plugin_canon, os.X_OK)
        plugin_hooks = os.path.join(root, "hooks", "hooks.json")
        doc = _load_json(plugin_hooks)
        if doc is not None and _bd_write_wire_commands(doc):
            if _plugin_explicitly_disabled(cfg, os.path.basename(root)):
                # 宣言はあるが settings の enabledPlugins で **明示 false**＝CC は hooks を load しない。
                # （symlink 配置の auto-discover plugin は既定 enable ゆえ、entry 不在は disable ではない。
                #   「明示 false のときだけ無効と読む」＝観測できない enablement を推測しない honest な判定。）
                sources.append("plugin:DISABLED:" + plugin_hooks)
            elif not plugin_canon_readable:
                sources.append("plugin:NO-CANON:" + plugin_hooks)
            elif not plugin_canon_exec:
                # hooks.json の gate は `[ -x "$SCRIPT" ]`＝非実行 canonical では else 枝の exit0 に落ちる。
                sources.append("plugin:NOEXEC:" + plugin_hooks)
            else:
                sources.append("plugin:" + plugin_hooks)
                live.append("plugin:" + plugin_hooks)

        if live:
            return True, canon, "", live
        if not sources:
            return False, canon, ("PreToolUse[Bash] → bd-write-guard の wire が 1 本も宣言されていない"
                                  "（plugin root: %s）" % root), sources
        if not canon_readable and not plugin_canon_readable:
            return False, canon, "canonical bd-write-guard が存在しない/読取不可（shim・plugin hook とも fail-open）", sources
        return False, canon, ("宣言された wire は全て可用性 gate 不成立（plugin 経路は canonical の実行権限[-x]、"
                              "settings 経路は起動される shim 本体の実在が要る）"), sources
    except Exception as e:  # 何があっても die しない（fail-safe）
        return False, canon, "wire 検査で例外: %s" % e, sources


def _plugin_explicitly_disabled(cfg_dir, plugin_name):
    """settings の enabledPlugins で当該 plugin が **明示 false** かを見る（entry 不在は disable ではない）。
    key の形は "<name>@<marketplace>"。読めない設定は「無効化されていない」に倒す（over-warn を避ける）。"""
    for name in ("settings.json", "settings.local.json"):
        doc = _load_json(os.path.join(cfg_dir, name))
        if not isinstance(doc, dict):
            continue
        enabled = doc.get("enabledPlugins")
        if not isinstance(enabled, dict):
            continue
        for key, val in enabled.items():
            if str(key).split("@", 1)[0] == plugin_name and val is False:
                return True
    return False


# === banner（stdout＝context 注入。不在の probe ごとに節を出す） ===========================================
def _build_banner(ct, bdw, wire):
    """probe 結果から ⚠️ banner を組む。ct/bdw は (ok, path, err)・wire は (ok, canon, detail, sources)。
    いずれか 1 つでも ok=False のとき呼ばれる。節は「失敗した probe の分だけ」区切り線で連結する。"""
    header = [
        "",
        "⚠️ ==================================================================",
        "⚠️  [scribe/SessionStart] PLUGIN HEALTH WARNING — canonical plugin 不在",
        "⚠️ ------------------------------------------------------------------",
    ]
    sections = []
    lines = []
    if not ct[0]:
        # over-attribution は意図的な safe-side（per-guard ground truth ではない）: probe は両 guard import の
        # 和集合 API を 1 回試行するため、部分ロード（片方の guard が要る API だけ欠落）でも両 guard を DISABLED
        # と列挙しうる。これは安全側（over-warn）で、**guard が実際に落ちるのに「OK」と言う false-negative は
        # 構造的に出ない**（和集合のどれか 1 つでも欠ければ banner を出す）。per-guard の厳密判定は本 hook の
        # 目的（silent な無効化を loud 化する）に対して過剰ゆえ採らない。
        lines += [
            "⚠️  [cmdtokens] plugin lib をロードできません。これに依存する destructive",
            "⚠️  guard が **DISABLED（fail-open＝破壊コマンド素通し）** で silent に無効化:",
            "⚠️    - git-destructive-guard  (破壊的 git コマンドを block)",
            "⚠️    - rm-destructive-guard   (保護 path への rm を block)",
            "⚠️  → cmdtokens 不在時、両 guard は consume preamble の fail-open(exit0)で黙って",
            "⚠️    無効化され、破壊コマンドを素通しします（セキュリティ後退が無警告）。",
            "⚠️  解決した lib path: %s" % ct[1],
            "⚠️  load error      : %s" % ct[2],
            "⚠️  復旧: cmdtokens plugin を配備する（手動 symlink・新ホストで忘れがち）:",
            "⚠️    ln -sfn ~/projects/local-projects/cmdtokens ~/.claude/plugins/cmdtokens",
            "⚠️    または lib dir を環境変数で直接指定: export CMDTOKENS_LIB=/abs/path/to/cmdtokens/lib",
        ]
        sections.append(lines)
    lines = []
    if not bdw[0]:
        lines += [
            "⚠️  [beads-bdw] canonical bdw に到達できません。scripts/bdw shim は",
            "⚠️  **fail-closed** で停止します（bd write 不可）:",
            "⚠️    - 直列化された bd write（--claim / --append-notes / close 等）が一切実行不可",
            "⚠️    - sandbox-ON worker は spawn の preflight が worktree add 前に停止",
            "⚠️    - sandbox-OFF worker は spawn 前 fail-loud で停止（zombie worker 化を封鎖・sc-ovq）",
            "⚠️  解決した bdw: %s" % bdw[1],
            "⚠️  probe error  : %s" % bdw[2],
            "⚠️  復旧: beads-bdw plugin を配備する（手動 symlink・新ホストで忘れがち）:",
            "⚠️    ln -sfn ~/projects/local-projects/beads-bdw ~/.claude/plugins/beads-bdw",
            "⚠️    または canonical bin/bdw を環境変数で直接指定: export BEADS_BDW=/abs/path/to/beads-bdw/bin/bdw",
        ]
        sections.append(lines)
    lines = []
    if not wire[0]:
        # moat 消失（sc-8e7i）: bd write が「実行できる」ことと「無検査の bare write が止まる」ことは別。
        # ここが落ちているとき、bdw funnel 自体は生きている（＝probe B は緑）が誰も強制していない。
        lines += [
            "⚠️  [beads-bdw/PreToolUse] bd-write moat が **配線されていません**。bare `bd`",
            "⚠️  write（他台帳への誤 write / bdw を迂回した直列化外し）が **無検査で素通し**:",
            "⚠️    - 自台帳 prefix 外への write が block されない（foreign 台帳を汚染しうる）",
            "⚠️    - bdw funnel を迂回した並列 write が block されない（lost-update が silent 復活）",
            "⚠️  ※ この probe は probe B（bdw lock-dir）とは独立: bdw が実行できても moat は消えうる。",
            "⚠️  canonical guard: %s" % wire[1],
            "⚠️  検査結果      : %s" % wire[2],
            "⚠️  検出した wire : %s" % (", ".join(wire[3]) if wire[3] else "(無し)"),
            "⚠️  復旧: beads-bdw plugin を配備する（plugin hooks.json が PreToolUse[Bash] を wire）:",
            "⚠️    ln -sfn ~/projects/local-projects/beads-bdw ~/.claude/plugins/beads-bdw",
            "⚠️    plugin 経路は canonical を **実行権限** で gate する（[ -x ]）: chmod +x %s" % wire[1],
            "⚠️    または settings.json の PreToolUse[Bash] へ shim を wire（plugin 非依存の universal net）:",
            '⚠️      test -f "$HOME/.claude/scripts/bd-write-guard.py" && python3 "$HOME/.claude/scripts/bd-write-guard.py"',
            "⚠️    ※ settings 経路は shim 本体（起動対象）が実在しないと `test -f` で短絡し何も起動しない。",
            "⚠️    canonical を直接指定する場合: export BD_WRITE_GUARD=/abs/path/to/bd-write-guard.py",
        ]
        sections.append(lines)
    body = []
    for i, sec in enumerate(sections):
        if i:
            body.append("⚠️ ------------------------------------------------------------------")
        body += sec
    return "\n".join(header + body + [
        "⚠️ ==================================================================",
        "",
    ])


def _run(cwd):
    """この session で stdout に出すべき文字列を返す（空文字 = silent/no-op）。
    順序が重要: self-scope を先に判定し、foreign/判定不能は probe せず no-op。scribe session かつ
    いずれかの probe が load 失敗のときだけ banner を返す。"""
    # session 判定 lib がロードできない → 判定不能 → 誤注入回避で no-op（fail-safe）。
    if _scribe_session_load_error is not None:
        return ""
    try:
        if not _is_scribe_session(cwd):
            return ""  # foreign / 台帳外 / 判定不能 session → 一切出さない（誤注入ゼロ）
    except Exception:
        return ""  # 判定で例外 → no-op（die しない）
    ct = _probe_cmdtokens()
    bdw = _probe_bdw()
    wire = _probe_bdw_wire()
    if ct[0] and bdw[0] and wire[0]:
        return ""  # 全 probe 健全 → 無音（stdout ノイズゼロ）
    return _build_banner(ct, bdw, wire)


def _safe_cwd():
    """os.getcwd() は cwd が削除済みだと FileNotFoundError を投げる。main() の except 経路では
    getcwd が try の外にあり、cwd 削除済み + garbage/空 stdin の degenerate edge で例外が伝播して
    traceback+exit1 で die しうる（「常に exit0・決して die しない」契約違反・orch-k33）。例外時は
    必ず存在する "/" へ degrade する（walk-up が即 root 到達で no-op＝silent・誤注入なし）。"""
    try:
        return os.getcwd()
    except Exception:
        return "/"


def main():
    if "--self-test" in sys.argv:
        return run_self_test()
    # SessionStart hook JSON を stdin から読む（cwd を抽出）。tty なら読まない（block 回避）。
    # **closed stdin（fd 0 が閉じた状態で起動）への防御**: CPython は fd 0 が閉じていると sys.stdin=None で
    # 初期化するため、素の sys.stdin.isatty() は AttributeError を送出し sys.exit(main()) まで伝播して die する
    # （「決して die しない・常に exit0」契約違反・sc-ovq orchestrator gate で実機再現）。None ガード + try/except
    # で空文字に degrade する（空/garbage/huge//dev/null は元から正常 degrade・die するのは closed stdin のみ）。
    try:
        raw = "" if (sys.stdin is None or sys.stdin.isatty()) else sys.stdin.read()
    except Exception:
        raw = ""
    try:
        data = json.loads(raw) if raw.strip() else {}
        cwd = data.get("cwd") or _safe_cwd()
    except Exception:
        cwd = _safe_cwd()  # parse 失敗 / cwd 削除 → fail-open で safe cwd（die しない）
    try:
        out = _run(cwd)
    except Exception:
        out = ""  # 何があっても die しない（fail-safe・全セッション破壊の防止）
    if out:
        sys.stdout.write(out + "\n")
    return 0  # 常に exit 0（degrade）


# --- self-test（hermetic: temp .beads/metadata.json + cmdtokens stub + bdw stub・実 plugin/DB 非依存）------
# fail-closed: assert が 1 つでも落ちたら非0（return 1）。env-degraded による誤 PASS を塞ぐため、
# present↔absent / scribe↔foreign を弁別する非vacuous な assertion で構成する。
def run_self_test():
    import tempfile
    import shutil

    failures = []

    def check(cond, label):
        if not cond:
            failures.append(label)
            print("FAIL: " + label)
        else:
            print("ok  : " + label)

    base = tempfile.mkdtemp(prefix="scribe-guard-health-selftest-")
    saved_ct = os.environ.get("CMDTOKENS_LIB")
    saved_bdw = os.environ.get("BEADS_BDW")
    saved_guard = os.environ.get("BD_WRITE_GUARD")
    saved_cfg = os.environ.get("CLAUDE_CONFIG_DIR")
    try:
        # 台帳 fixture: scribe(self) と foreign(orch)。walk-up で dolt_database を解決。
        scribe_dir = os.path.join(base, "scribe")
        foreign = os.path.join(base, "foreign")
        for root, db in ((scribe_dir, "sc"), (foreign, "orch")):
            os.makedirs(os.path.join(root, ".beads"))
            os.makedirs(os.path.join(root, "sub"))
            with open(os.path.join(root, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
                f.write('{"database":"dolt","dolt_database":"%s"}' % db)
        scribe_cwd = os.path.join(scribe_dir, "sub")
        foreign_cwd = os.path.join(foreign, "sub")

        # cmdtokens stub fixture(present)= 両 guard が import する和集合 API を定義する最小 module。
        ct_present = os.path.join(base, "cmdtokens-present")
        os.makedirs(ct_present)
        with open(os.path.join(ct_present, "cmdtokens.py"), "w", encoding="utf-8") as f:
            f.write("".join(
                "def %s(*a, **k):\n    return None\n" % name
                for name in ("iter_commands", "long_opt_abbrev", "parse_statements",
                             "peel", "shlex_safe", "strip_redirections", "track_cd")
            ) + "SHELLS = ()\nVAR_OR_SUBST = None\n")
        ct_absent = os.path.join(base, "cmdtokens-absent")  # 空 dir → import 失敗
        os.makedirs(ct_absent)

        # bdw stub fixture(present)= `lock-dir` で dir を出し exit0 する canonical bdw stub。BEADS_BDW で
        # scripts/bdw shim の canonical 解決先を切り替える（shim→canonical chain を実走＝sc-vae と同一経路）。
        bdw_present = os.path.join(base, "bdw-canonical-present")
        with open(bdw_present, "w", encoding="utf-8") as f:
            f.write('#!/usr/bin/env bash\n[ "$1" = lock-dir ] && { echo "%s/locks"; exit 0; }\nexit 0\n' % base)
        os.chmod(bdw_present, 0o755)
        bdw_absent = os.path.join(base, "no-such-canonical-bdw")  # 不在 → shim が fail-closed(exit1)

        # bd-write moat fixture(probe B2・sc-8e7i)。canonical guard の位置から plugin root を 2 段上って
        # hooks/hooks.json を探す実装ゆえ、fixture も同じ layout（<root>/scripts/hooks/ と <root>/hooks/）で作る。
        #   canonical の mode は **実配線の gate と同じ意味を持つ**（plugin hooks.json は `[ -x ]` で gate する）ため
        #   健全 fixture は 0755 で作る。0644 の fixture は「読めるが非実行」＝plugin 経路が fail-open する構成。
        def make_plugin(name, with_hooks_json, mode=0o755):
            root = os.path.join(base, name)
            os.makedirs(os.path.join(root, "scripts", "hooks"))
            guard = os.path.join(root, "scripts", "hooks", "bd-write-guard.py")
            with open(guard, "w", encoding="utf-8") as f:
                f.write("# canonical bd-write-guard stub\n")
            os.chmod(guard, mode)
            if with_hooks_json:
                os.makedirs(os.path.join(root, "hooks"))
                with open(os.path.join(root, "hooks", "hooks.json"), "w", encoding="utf-8") as f:
                    json.dump({"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
                        {"type": "command",
                         "command": 'SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/hooks/bd-write-guard.py"; '
                                    'if [ -x "$SCRIPT" ]; then python3 "$SCRIPT"; else exit 0; fi'},
                    ]}]}}, f)
            return root, guard

        # plugin wire 有(=hooks.json あり) / 無(=canonical だけ在って誰も起動しない) / 非実行 canonical(0644)。
        wired_root, guard_wired = make_plugin("bdw-plugin-wired", True)
        _, guard_unwired = make_plugin("bdw-plugin-unwired", False)
        _, guard_noexec = make_plugin("bdw-plugin-noexec", True, mode=0o644)
        guard_absent = os.path.join(base, "no-such-bd-write-guard.py")

        # settings 経路の **起動対象**（shim 本体）fixture。実配線は `test -f <shim> && python3 <shim>` ゆえ
        # shim の実在が live の必要条件。hermetic に保つため $HOME ではなく fixture 内絶対 path を wire する。
        shim_present = os.path.join(base, "shim-bd-write-guard.py")
        with open(shim_present, "w", encoding="utf-8") as f:
            f.write("# shim stub（canonical へ execvp する想定）\n")
        shim_missing = os.path.join(base, "no-such-shim-bd-write-guard.py")

        # config dir fixture: 空(wire 宣言なし) / settings 経由 shim wire あり / shim 本体が消えた wire /
        #                     plugin を明示 disable。
        def make_cfg(name, settings):
            d = os.path.join(base, name)
            os.makedirs(d)
            if settings is not None:
                with open(os.path.join(d, "settings.json"), "w", encoding="utf-8") as f:
                    json.dump(settings, f)
            return d

        def shim_wire_settings(shim):
            return {"hooks": {"PreToolUse": [
                {"matcher": "Read|Glob|Grep|Bash", "hooks": [{"type": "command", "command": "bash other.sh"}]},
                {"matcher": "Bash", "hooks": [{"type": "command", "command":
                    'test -f "%s" && python3 "%s"' % (shim, shim)}]},
            ]}}

        # config dir 配下の plugin 実配置 fixture（BD_WRITE_GUARD 非 pin 時の plugin root 追従を pin する）。
        #   CC は $CLAUDE_CONFIG_DIR/plugins/<name> を load するため、probe もそこを見なければならない。
        cfg_plugin = os.path.join(base, "cfg-plugin")
        os.makedirs(cfg_plugin)
        cfg_plugin_root, _ = make_plugin(os.path.join("cfg-plugin", "plugins", "beads-bdw"), True)

        cfg_empty = make_cfg("cfg-empty", None)
        cfg_wired = make_cfg("cfg-wired", shim_wire_settings(shim_present))
        cfg_shim_gone = make_cfg("cfg-shim-gone", shim_wire_settings(shim_missing))
        cfg_disabled = make_cfg("cfg-disabled", {
            "enabledPlugins": {os.path.basename(wired_root) + "@local": False}})

        def set_env(ct, bdw, guard=None, cfg=None):
            os.environ["CMDTOKENS_LIB"] = ct
            os.environ["BEADS_BDW"] = bdw
            # probe B2 は既定で host 実設定を読む。self-test は hermetic 必須ゆえ常に fixture へ pin する
            # （既定 = 健全構成: plugin wire 有 + config dir は空＝plugin 経路単独で moat 成立）。
            os.environ["BD_WRITE_GUARD"] = guard or guard_wired
            os.environ["CLAUDE_CONFIG_DIR"] = cfg or cfg_empty

        def set_env_unpinned_guard(cfg):
            """BD_WRITE_GUARD を **外して** config dir だけ pin する（plugin root の config dir 追従を検査する
            唯一の軸。env で canonical を pin している間は root が env 起点になり、この軸を一度も踏めない）。"""
            os.environ["CMDTOKENS_LIB"] = ct_present
            os.environ["BEADS_BDW"] = bdw_present
            os.environ.pop("BD_WRITE_GUARD", None)
            os.environ["CLAUDE_CONFIG_DIR"] = cfg

        # (i) 両 present + scribe session → banner 無(silent)。
        set_env(ct_present, bdw_present)
        out_ok = _run(scribe_cwd)
        check(out_ok == "", "(i) cmdtokens+bdw present + scribe → silent(banner 無)")

        # (ii) cmdtokens absent（bdw present）+ scribe → banner 有 + 両 guard 名 + DISABLED + 解決 path。
        set_env(ct_absent, bdw_present)
        out_ct = _run(scribe_cwd)
        check(out_ct != "", "(ii) cmdtokens absent + scribe → banner 有")
        check("git-destructive-guard" in out_ct, "(ii) banner に git-destructive-guard を含む")
        check("rm-destructive-guard" in out_ct, "(ii) banner に rm-destructive-guard を含む")
        check("DISABLED" in out_ct, "(ii) banner に DISABLED を明示")
        check(ct_absent in out_ct, "(ii) banner に解決 cmdtokens lib path を含む")
        check("ln -sfn" in out_ct, "(ii) banner に復旧(symlink)hint を含む")
        # bdw present ゆえ cmdtokens 単独不在では bdw 節を出さない（probe の独立性）。
        check("beads-bdw" not in out_ct, "(ii) bdw present 時は banner に bdw 節を出さない")

        # (iii) bdw absent（cmdtokens present）+ scribe → banner 有 + bdw 節（fail-closed/zombie/復旧）。
        set_env(ct_present, bdw_absent)
        out_bdw = _run(scribe_cwd)
        check(out_bdw != "", "(iii) bdw absent + scribe → banner 有")
        check("beads-bdw" in out_bdw, "(iii) banner に beads-bdw 節を含む")
        check("fail-closed" in out_bdw, "(iii) banner に fail-closed を明示")
        check("zombie" in out_bdw, "(iii) banner に zombie(sandbox-off)を明示")
        check("BEADS_BDW" in out_bdw, "(iii) banner に bdw 復旧 hint(BEADS_BDW)を含む")
        # cmdtokens present ゆえ bdw 単独不在では guard 節を出さない（probe の独立性）。
        check("git-destructive-guard" not in out_bdw, "(iii) cmdtokens present 時は banner に guard 節を出さない")

        # (iv) 両 absent + scribe → banner に両節（cmdtokens guard + bdw）。
        set_env(ct_absent, bdw_absent)
        out_both = _run(scribe_cwd)
        check("git-destructive-guard" in out_both and "beads-bdw" in out_both,
              "(iv) 両 absent → banner に両節（guard + bdw）")

        # (v) cmdtokens absent + foreign session → no-op(banner 無)。self-scope が先に効く。
        set_env(ct_absent, bdw_absent)
        check(_run(foreign_cwd) == "", "(v) absent+foreign → no-op(誤注入ゼロ・self-scope 先行)")

        # (vi) 両 present + foreign session も no-op(self-scope で弾く)。
        set_env(ct_present, bdw_present)
        check(_run(foreign_cwd) == "", "(vi) present+foreign → no-op")

        # (vii) 台帳外（.beads 皆無）session → no-op（dolt_database 解決不能＝誤注入ゼロ）。
        outside = os.path.join(base, "outside")
        os.makedirs(outside)
        set_env(ct_absent, bdw_absent)
        check(_run(outside) == "", "(vii) 台帳外(.beads 皆無) → no-op")

        # (viii) _safe_cwd: os.getcwd() が例外でも die せず "/" へ degrade(deleted-cwd 契約・orch-k33)。
        #   非vacuous: 例外時は "/" / 正常時は実 cwd を返す＝degrade と正常を弁別する。
        def _raise_fnf(*a, **k):
            raise FileNotFoundError("cwd deleted (self-test)")
        _real_getcwd = os.getcwd
        try:
            os.getcwd = _raise_fnf
            check(_safe_cwd() == "/", "(viii) _safe_cwd: getcwd 例外時 '/' へ degrade(die しない)")
        finally:
            os.getcwd = _real_getcwd
        check(_safe_cwd() == os.getcwd(),
              "(viii) _safe_cwd: 正常時は実 cwd を返す(non-vacuous・degrade と弁別)")

        # --- probe B2: bd-write moat の PreToolUse wire（sc-8e7i） ------------------------------------
        # 検査意図: bd write の「実行系」(probe B) が緑でも moat は独立に消えうる。両者の独立性も pin する。

        # (ix) plugin wire 単独で moat 成立（config dir に宣言が無くても silent）。
        set_env(ct_present, bdw_present, guard_wired, cfg_empty)
        check(_run(scribe_cwd) == "", "(ix) plugin hooks.json wire 単独 → silent(moat 成立)")

        # (x) 失敗モード: canonical は在るが wire が 1 本も無い（plugin hooks.json 無し + settings 宣言無し）
        #     → probe B は緑のまま moat だけが消える面。banner で loud 化されること。
        set_env(ct_present, bdw_present, guard_unwired, cfg_empty)
        out_wire = _run(scribe_cwd)
        check(out_wire != "", "(x) wire 皆無 → banner 有(moat 消失を loud 化)")
        check("bd-write moat" in out_wire, "(x) banner に bd-write moat 節を含む")
        check("PreToolUse" in out_wire, "(x) banner に PreToolUse wire 欠落を明示")
        check("(無し)" in out_wire, "(x) banner に「検出した wire: (無し)」を含む")
        check("BD_WRITE_GUARD" in out_wire, "(x) banner に moat 復旧 hint を含む")
        # probe の独立性: bdw(lock-dir) present ゆえ probe B の節は出さない＝両者が独立に報告される。
        check("fail-closed" not in out_wire, "(x) probe B present 時は banner に bdw(fail-closed)節を出さない")
        check("git-destructive-guard" not in out_wire, "(x) cmdtokens present 時は guard 節を出さない")

        # (xi) settings.json 経由 shim wire 単独でも moat 成立（plugin hooks.json 不在でも silent）。
        #      = plugin enablement 非依存の universal net が生きている構成を誤検知しない。
        set_env(ct_present, bdw_present, guard_unwired, cfg_wired)
        check(_run(scribe_cwd) == "", "(xi) settings 経由 shim wire 単独 → silent(誤検知しない)")

        # (xii) wire は宣言されているが canonical guard が不在 → shim/plugin hook は fail-open＝moat 消失。
        #       「宣言の有無」だけを見る素朴な検査では緑になる面を pin する。
        set_env(ct_present, bdw_present, guard_absent, cfg_wired)
        out_canon = _run(scribe_cwd)
        check(out_canon != "", "(xii) wire 宣言有 + canonical 不在 → banner 有(fail-open を検出)")
        check("bd-write moat" in out_canon, "(xii) banner に bd-write moat 節を含む")
        check(guard_absent in out_canon, "(xii) banner に解決した canonical path を含む")

        # (xiii) 失敗モード(i): plugin hooks.json は在るが settings の enabledPlugins で **明示 false**
        #        → CC は hooks を load しない＝moat 消失。宣言の実在に騙されないことを pin する。
        set_env(ct_present, bdw_present, guard_wired, cfg_disabled)
        out_dis = _run(scribe_cwd)
        check(out_dis != "", "(xiii) plugin 明示 disable + settings wire 無 → banner 有")
        check("DISABLED" in out_dis, "(xiii) banner に DISABLED な plugin wire を明示")

        # (xv) 経路別 gate: canonical が 0644（読めるが **非実行**）+ plugin wire 単独 → plugin hooks.json の
        #      `[ -x "$SCRIPT" ]` が偽になり hook は exit0＝moat 消失。R_OK だけを見る検査器はここを silent に
        #      取りこぼす（検出器自身の false-negative）。banner が出ることを pin する。
        set_env(ct_present, bdw_present, guard_noexec, cfg_empty)
        out_noexec = _run(scribe_cwd)
        check(out_noexec != "", "(xv) 非実行 canonical(0644) + plugin wire 単独 → banner 有(X_OK gate)")
        check("bd-write moat" in out_noexec, "(xv) banner に bd-write moat 節を含む")
        check("NOEXEC" in out_noexec, "(xv) banner に NOEXEC な plugin wire を明示")
        check(os.access(guard_noexec, os.R_OK) and not os.access(guard_noexec, os.X_OK),
              "(xv) fixture 前提: 0644 canonical は R_OK かつ非 X_OK(non-vacuous)")
        # 対偶: 同じ構成で mode だけ 0755 なら silent＝判定しているのは実行権限のみ（他要因ではない）。
        os.chmod(guard_noexec, 0o755)
        check(_run(scribe_cwd) == "", "(xv) chmod +x すると silent へ戻る(gate は X_OK だけに依存)")
        os.chmod(guard_noexec, 0o644)

        # (xvi) 経路別 gate: settings wire は宣言されているが **起動対象の shim 本体が不在** → `test -f` が偽で
        #       && が短絡し guard は一切起動しない＝moat 消失。宣言の実在だけを live と数える検査器は silent に
        #       取りこぼす。canonical は在る（＝canonical 側の gate では捕まらない面）ことも同時に pin する。
        set_env(ct_present, bdw_present, guard_unwired, cfg_shim_gone)
        out_shim = _run(scribe_cwd)
        check(out_shim != "", "(xvi) settings wire 宣言有 + shim 本体不在 → banner 有")
        check("SHIM-MISSING" in out_shim, "(xvi) banner に SHIM-MISSING な settings wire を明示")
        check(os.path.isfile(guard_unwired),
              "(xvi) 前提: canonical は実在(canonical 側 gate では捕まらない面・non-vacuous)")
        # 対偶: 同じ settings 形で shim 本体が在れば silent＝判定しているのは起動対象の実在のみ。
        set_env(ct_present, bdw_present, guard_unwired, cfg_wired)
        check(_run(scribe_cwd) == "", "(xvi) shim 本体が在れば silent(gate は起動対象の実在だけに依存)")

        # (xvii) 静的に解決できない path（${CLAUDE_PLUGIN_ROOT} 等）は live 扱い＝over-warn を増やさない安全側。
        check(_entrypoint_reachable('python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/bd-write-guard.py"'),
              "(xvii) 変数未解決 path は live 扱い(相対断片を絶対 path と誤読しない)")
        check(_referenced_guard_paths('python3 "${CLAUDE_PLUGIN_ROOT}/scripts/hooks/bd-write-guard.py"') == [],
              "(xvii) ${CLAUDE_PLUGIN_ROOT} 直後の断片を path として拾わない(non-vacuous)")
        check(_referenced_guard_paths('test -f "%s" && python3 "%s"' % (shim_present, shim_present))
              == [shim_present, shim_present],
              "(xvii) 絶対 path は静的に抽出する(non-vacuous)")
        check(_entrypoint_reachable('python3 "%s"' % shim_missing) is False,
              "(xvii) 抽出できた path が不在なら非 live と判定")

        # (xviii) plugin root は **CC がその session で load する config dir** に追従する（sc-8e7i）。
        #   BD_WRITE_GUARD を pin している限りこの軸は一度も踏めない（root が env 起点になる）ため、
        #   env を外した状態で「config dir に plugin 不在 + settings wire 無 → banner」を pin する。
        #   ~/.claude 固定で読む実装は、当該 session が決して load しない hooks.json を根拠に silent になる
        #   ＝検出器自身の false-silent。本 case はまさにその面を RED にする。
        set_env_unpinned_guard(cfg_empty)
        out_cfg = _run(scribe_cwd)
        check(out_cfg != "", "(xviii) config dir に plugin 不在 + settings wire 無 → banner 有(config dir 追従)")
        check("bd-write moat" in out_cfg, "(xviii) banner に bd-write moat 節を含む")
        check("(無し)" in out_cfg, "(xviii) 検出した wire = (無し)（~/.claude 側 plugin を live と数えない）")
        # 対偶: 同じ env 状態で config dir 配下に plugin を置けば silent＝判定は config dir だけに依存。
        set_env_unpinned_guard(cfg_plugin)
        check(_run(scribe_cwd) == "",
              "(xviii) config dir 配下に plugin 実在 → silent(対偶・判定は config dir に依存)")
        check(_plugin_root() == os.path.join(cfg_plugin, "plugins", "beads-bdw"),
              "(xviii) _plugin_root: env 無 pin では $CLAUDE_CONFIG_DIR/plugins/beads-bdw を返す")
        check(os.path.isfile(os.path.join(cfg_plugin_root, "hooks", "hooks.json")),
              "(xviii) fixture 前提: config dir 配下 plugin に hooks.json 実在(non-vacuous)")
        # BD_WRITE_GUARD 明示時は従来どおり env が単一起点（root は canonical から 2 段上）。
        set_env(ct_present, bdw_present, guard_wired, cfg_empty)
        check(_plugin_root() == wired_root,
              "(xviii) _plugin_root: BD_WRITE_GUARD 明示時は canonical 起点(env が単一起点・non-vacuous)")

        # (xiv) enablement は「明示 false のときだけ無効」と読む（entry 不在 = auto-discover 既定 enable）。
        #       観測できない enablement を推測して over-warn しないことを pin する（(ix) の対偶側）。
        check(_plugin_explicitly_disabled(cfg_disabled, os.path.basename(wired_root)),
              "(xiv) enabledPlugins の明示 false を disable と判定")
        check(not _plugin_explicitly_disabled(cfg_empty, os.path.basename(wired_root)),
              "(xiv) entry 不在は disable と判定しない(non-vacuous・over-warn 排除)")

        # 非vacuous: 同一 scribe session で present は無音・absent は banner = 検出器が状態を弁別する。
        set_env(ct_present, bdw_present)
        check(out_ok == "" and out_ct != "" and out_bdw != "" and out_wire != "",
              "non-vacuous: present↔absent を弁別(env-degraded 誤 PASS を排除)")

        # 解決規則: 非絶対 BD_WRITE_GUARD / CLAUDE_CONFIG_DIR は既定へ落とす（cwd 相対 poison の排除）。
        os.environ["BD_WRITE_GUARD"] = "relative/not/abs"
        check(_resolve_bd_write_guard() == _BD_WRITE_GUARD_DEFAULT,
              "解決: 非絶対 BD_WRITE_GUARD → 既定へ fallback")
        os.environ["BD_WRITE_GUARD"] = guard_wired
        check(_resolve_bd_write_guard() == guard_wired,
              "解決: 絶対 BD_WRITE_GUARD は尊重(non-vacuous)")
        os.environ["CLAUDE_CONFIG_DIR"] = "relative/not/abs"
        check(_config_dir() == os.path.expanduser("~/.claude"),
              "解決: 非絶対 CLAUDE_CONFIG_DIR → 既定へ fallback")

        # matcher 意味論: 空/'*'/alternation は Bash を覆い、Bash を含まない matcher は覆わない。
        check(_matcher_covers_bash("Bash") and _matcher_covers_bash("Read|Glob|Grep|Bash")
              and _matcher_covers_bash("*") and _matcher_covers_bash(None),
              "matcher: Bash/alternation/'*'/空 は Bash を覆う")
        check(not _matcher_covers_bash("Read|Write"),
              "matcher: Bash を含まない matcher は覆わない(non-vacuous)")

        # 解決規則: 非絶対 CMDTOKENS_LIB は既定へ落とす(consume preamble と同一)。
        os.environ["CMDTOKENS_LIB"] = "relative/not/abs"
        check(_resolve_cmdtokens_lib() == _CMDTOKENS_DEFAULT_LIB,
              "解決: 非絶対 CMDTOKENS_LIB → 既定へ fallback")
    finally:
        for key, saved in (("CMDTOKENS_LIB", saved_ct), ("BEADS_BDW", saved_bdw),
                           ("BD_WRITE_GUARD", saved_guard), ("CLAUDE_CONFIG_DIR", saved_cfg)):
            if saved is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = saved
        shutil.rmtree(base, ignore_errors=True)

    if failures:
        print("scribe guard-health self-test: FAILED (%d)" % len(failures))
        return 1
    print("scribe guard-health self-test: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

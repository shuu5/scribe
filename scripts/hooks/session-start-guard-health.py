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


# === banner（stdout＝context 注入。不在の probe ごとに節を出す） ===========================================
def _build_banner(ct, bdw):
    """probe 結果から ⚠️ banner を組む。ct/bdw は (ok, path, err)。少なくとも一方が ok=False のとき呼ばれる。"""
    lines = [
        "",
        "⚠️ ==================================================================",
        "⚠️  [scribe/SessionStart] PLUGIN HEALTH WARNING — canonical plugin 不在",
        "⚠️ ------------------------------------------------------------------",
    ]
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
    if not ct[0] and not bdw[0]:
        lines.append("⚠️ ------------------------------------------------------------------")
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
    lines += [
        "⚠️ ==================================================================",
        "",
    ]
    return "\n".join(lines)


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
    if ct[0] and bdw[0]:
        return ""  # 両 probe ともロード可 → 無音（stdout ノイズゼロ）
    return _build_banner(ct, bdw)


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

        def set_env(ct, bdw):
            os.environ["CMDTOKENS_LIB"] = ct
            os.environ["BEADS_BDW"] = bdw

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

        # 非vacuous: 同一 scribe session で present は無音・absent は banner = 検出器が状態を弁別する。
        check(out_ok == "" and out_ct != "" and out_bdw != "",
              "non-vacuous: present↔absent を弁別(env-degraded 誤 PASS を排除)")

        # 解決規則: 非絶対 CMDTOKENS_LIB は既定へ落とす(consume preamble と同一)。
        os.environ["CMDTOKENS_LIB"] = "relative/not/abs"
        check(_resolve_cmdtokens_lib() == _CMDTOKENS_DEFAULT_LIB,
              "解決: 非絶対 CMDTOKENS_LIB → 既定へ fallback")
    finally:
        for key, saved in (("CMDTOKENS_LIB", saved_ct), ("BEADS_BDW", saved_bdw)):
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

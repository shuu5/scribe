#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# session-start-guard-health.py — guard health-check（cmdtokens loadability の loud 化・bd orch-hos）
#
# 役割（単一責務ゆえ spec-inject に混ぜず別ファイル・AC1 推奨構造）:
#   orchestrator session の起動時に、bd write guard / bash file-write guard が consume する
#   **cmdtokens plugin lib がロード可能か**を検査する。ロードできないと両 guard は consume preamble の
#   fail-open（exit 0）で **silent に無効化**され、foreign 台帳への write を取りこぼす（moat が黙って
#   消える）。本 hook はその silent 無効化を SessionStart stdout（= context 注入）に ⚠️ banner として
#   loud 化し、復旧法を提示する。
#
# 設計確定（bd orch-hos NOTES・grill+人間 ratify 2026-06-27）: 案A（loud 化）採用。fail-open は維持し
#   （cmdtokens 不在ホストを brick しない）、SessionStart で目立つ警告を必ず出して silent を解消する。
#   案B（local fallback copy）・案C（fail-closed で全 write brick）は grill で退けた。
#
# self-scope（最重要・spec-inject と同型）: 本 hook を plugin として global enable すると SessionStart は
#   **全セッション**で発火する。orchestrator session（cwd walk-up の .beads/metadata.json dolt_database
#   == SELF_PREFIX）でのみ banner を出し、foreign（scribe 'sc' / cc-session 'ccs' …）・判定不能は無出力 exit0
#   （誤注入ゼロ）。判定は共有 lib scripts/hooks/lib/orch_session.py の `_is_orch_session` を再利用する
#   （bd-write-guard / bash-file-write-guard / spec-inject と同一機構・同一 SELF_PREFIX）。
#
# cmdtokens 解決（consume preamble と同一・AC1(b)）: env CMDTOKENS_LIB（未設定/空/非絶対は既定
#   ~/.claude/plugins/cmdtokens/lib へ fallback・env 値/default とも expanduser）で sys.path 解決し
#   `from cmdtokens import iter_commands, parse_statements, shlex_safe, track_cd, peel` を試行する
#   （guard が実際に import する公開 API と同一集合＝guard が load できるかを正確に代理判定する）。
#
# 影響 guard（cmdtokens を consume する 2 本のみ・file-write-guard は path-based ゆえ無依存）:
#   - bd-write-guard.py        : bd write を自台帳 orch- のみへ機械強制（un-4sf）
#   - bash-file-write-guard.py : 非bd Bash file 変異の foreign 台帳宛先を deny（orch-2o6）
#
# fail-safe（全セッション破壊の防止・spec-inject と同型）: 判定不能・例外でもセッションを壊さない。
#   常に exit 0（degrade）。orch_session lib をロードできない（session 判定不能）ときは banner を出さず
#   no-op（誤注入ゼロを優先・foreign に誤発火しないため）。本 hook は決して die しない。
#
# 検証: tests/scenarios/guard-health-banner.bats（hermetic E2E）+ 本 file の `--self-test`（in-process・
#   fail-closed）+ selftest-orch-hos.local.sh（worktree 直下・untracked・fail-closed）。

import sys
import os
import json

# --- orch_session 共有 lib（session self-scope の SSOT・bd-write-guard / bash-file-write-guard と共有） ---
# logic ゼロの薄い解決層: 同梱 lib/ を sys.path 解決して import するだけ。ロード不能なら session 判定が
# できない → banner を誤発火させないため no-op に倒す（フラグで記録し _run が見る）。
#
# 重要(probe fidelity): import 後に hook lib dir を sys.path から外す。同 dir には cmdtokens の残置 copy
#   (scripts/hooks/lib/cmdtokens.py・orch-wzu 案Y の defense-in-depth)が在り、これを sys.path に載せたまま
#   にすると下の _probe_cmdtokens が canonical plugin 不在時に残置 copy へ silent fallback し「load 可」と
#   誤判定する。guard の consume preamble は cmdtokens を hook lib dir 追加**前**に import するため残置へ
#   fallback しない(orch-iqz cutover の意図・grill で option B 残置 fallback は『古版ゆえ誤解析』で却下)。
#   health-check も同順序を再現するため、orch_session 取り込み後に hook lib dir を path から除去する
#   (orch_session は sys.modules に載った後ゆえ path 除去で unload されない)。
_HOOK_LIB_DIR = os.path.join(os.path.dirname(os.path.realpath(__file__)), "lib")
_orch_session_load_error = None
try:
    sys.path.insert(0, _HOOK_LIB_DIR)
    from orch_session import SELF_PREFIX, _is_orch_session  # noqa: E402
except Exception as e:  # 同梱 lib ロード不能 → session 判定不能 → no-op（誤注入ゼロ・fail-open）
    _orch_session_load_error = e
    SELF_PREFIX = "orch"

    def _is_orch_session(cwd):  # fallback（import 成功時は from-import に上書きされ未使用）
        return False
finally:
    try:
        sys.path.remove(_HOOK_LIB_DIR)  # 残置 cmdtokens copy を probe から不可視化(guard と同順序)
    except ValueError:
        pass


# cmdtokens 解決の既定（consume preamble と同一値）。env CMDTOKENS_LIB > 既定。
_CMDTOKENS_DEFAULT_LIB = os.path.expanduser("~/.claude/plugins/cmdtokens/lib")

# guard が consume preamble で import する公開 API の集合（同一集合で probe する＝guard load の正確な代理）。
_CMDTOKENS_API = ("iter_commands", "parse_statements", "shlex_safe", "track_cd", "peel")


def _resolve_cmdtokens_lib():
    """cmdtokens lib dir を consume preamble と同一規則で解決する（env CMDTOKENS_LIB|既定・非絶対は既定へ）。
    env 値・default とも expanduser する。"""
    lib = os.path.expanduser(os.environ.get("CMDTOKENS_LIB") or _CMDTOKENS_DEFAULT_LIB)
    if not os.path.isabs(lib):  # 非絶対 → cwd 相対 poison を避け既定へ（preamble と同一）
        lib = _CMDTOKENS_DEFAULT_LIB
    return lib


def _probe_cmdtokens():
    """cmdtokens plugin lib をロードできるか probe する。(ok: bool, lib_path: str, error|None) を返す。
    consume preamble と同一の解決・同一 API 集合の import を試行する。sys.modules / sys.path を probe 前に
    リセット/復元し、複数回 probe（self-test）でも毎回 fresh 解決になるようにする（production は 1 回のみ）。"""
    lib = _resolve_cmdtokens_lib()
    # 既存の cmdtokens import cache を落として fresh 解決を保証（self-test で別 lib を順に probe するため）。
    sys.modules.pop("cmdtokens", None)
    saved_path = list(sys.path)
    try:
        # probe path = [lib] + (現 path から hook lib dir を除外)。module top で除去済だが、防御的に
        # 残置 copy(scripts/hooks/lib/cmdtokens.py)を確実に不可視化し canonical のみで loadability を判定。
        sys.path = [lib] + [p for p in sys.path
                            if os.path.abspath(p) != os.path.abspath(_HOOK_LIB_DIR)]
        mod = __import__("cmdtokens")
        missing = [name for name in _CMDTOKENS_API if not hasattr(mod, name)]
        if missing:
            return False, lib, "cmdtokens に必須 API 欠落: " + ", ".join(missing)
        return True, lib, None
    except Exception as e:  # lib 不在 / import 失敗 → guard が fail-open で無効化される状態
        return False, lib, e
    finally:
        sys.path = saved_path
        sys.modules.pop("cmdtokens", None)  # probe で載せた module を残さない(次 probe の fresh 解決)


def _build_banner(lib_path, err):
    """cmdtokens 不在時の ⚠️ banner（stdout＝context 注入）。影響 guard 名（DISABLED）+ 解決 path + 復旧 hint。"""
    return "\n".join([
        "",
        "⚠️ ==================================================================",
        "⚠️  [orchestrator/SessionStart] GUARD HEALTH WARNING — cmdtokens 不在",
        "⚠️ ------------------------------------------------------------------",
        "⚠️  cmdtokens plugin lib をロードできません。これに依存する write-isolation",
        "⚠️  guard が **DISABLED（fail-open）** で silent に無効化されています:",
        "⚠️    - bd-write-guard         (bd write を自台帳 orch- のみへ機械強制)",
        "⚠️    - bash-file-write-guard  (非bd Bash file 変異の foreign 台帳宛先を deny)",
        "⚠️  → cmdtokens 不在時、両 guard は consume preamble の fail-open(exit0)で黙って",
        "⚠️    無効化され、foreign 台帳への write を取りこぼします(moat が消える)。",
        "⚠️    (file-write-guard は path-based で cmdtokens 無依存ゆえ影響なし)",
        "⚠️  解決した lib path: %s" % lib_path,
        "⚠️  load error      : %s" % err,
        "⚠️  復旧: cmdtokens plugin を配備する(手動 symlink 配備・新ホストで忘れがち):",
        "⚠️    ln -sfn <cmdtokens-checkout> ~/.claude/plugins/cmdtokens",
        "⚠️    (例: ln -sfn <cmdtokens repo の実 path> ~/.claude/plugins/cmdtokens)",
        "⚠️  または lib dir を環境変数で直接指定:",
        "⚠️    export CMDTOKENS_LIB=/abs/path/to/cmdtokens/lib",
        "⚠️ ==================================================================",
        "",
    ])


def _run(cwd):
    """この session で stdout に出すべき文字列を返す（空文字 = silent/no-op）。
    順序が重要(AC3 iii): self-scope を先に判定し、foreign/判定不能は cmdtokens を probe せず no-op。
    orchestrator session かつ cmdtokens load 失敗のときだけ banner を返す。"""
    # session 判定 lib がロードできない → 判定不能 → 誤注入回避で no-op（spec-inject と同型の fail-open）。
    if _orch_session_load_error is not None:
        return ""
    try:
        if not _is_orch_session(cwd):
            return ""  # foreign / 判定不能 session → 一切出さない（誤注入ゼロ）
    except Exception:
        return ""  # 判定で例外 → no-op（die しない）
    ok, lib_path, err = _probe_cmdtokens()
    if ok:
        return ""  # cmdtokens ロード可 → 無音(stdout ノイズゼロ・AC1 d)
    return _build_banner(lib_path, err)


def _safe_cwd():
    """os.getcwd() は cwd が削除済みだと FileNotFoundError を投げる。main() の except 経路では
    getcwd が try の外にあり、cwd 削除済み + garbage/空 stdin の degenerate edge で例外が伝播して
    traceback+exit1 で die しうる(「常に exit0・決して die しない」契約違反・orch-k33)。例外時は
    必ず存在する "/" へ degrade する(walk-up が即 root 到達で no-op＝silent・誤注入なし)。"""
    try:
        return os.getcwd()
    except Exception:
        return "/"


def main():
    if "--self-test" in sys.argv:
        return run_self_test()
    # SessionStart hook JSON を stdin から読む(cwd を抽出)。tty なら読まない(block 回避)。
    # fd 0 が閉じた状態(`0<&-`)では CPython が sys.stdin=None で初期化し isatty() が AttributeError を
    # 送出するため、try/except + None ガードで握り潰す(本 hook の「常に exit0・決して die しない」契約・orch-3z9)。
    # さらに cwd 削除済みでは os.getcwd() が FileNotFoundError を投げる(下の except 経路では getcwd が
    # try 外＝die 経路)ため _safe_cwd() で "/" へ degrade する(orch-k33)。
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
        out = ""  # 何があっても die しない(fail-safe・全セッション破壊の防止)
    if out:
        sys.stdout.write(out + "\n")
    return 0  # 常に exit 0(spec-inject と同じ fail-safe・degrade)


# --- self-test(hermetic: temp .beads/metadata.json + cmdtokens stub fixture・実 plugin/DB 非依存) -------
# fail-closed: assert が 1 つでも落ちたら非0(return 1)。env-degraded による誤 PASS を塞ぐため、
# present↔absent / orch↔foreign を弁別する非vacuous な assertion で構成する。
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

    base = tempfile.mkdtemp(prefix="guard-health-selftest-")
    saved_env = os.environ.get("CMDTOKENS_LIB")
    try:
        # 台帳 fixture: orch(self) と foreign(un)。walk-up で dolt_database を解決。
        orch = os.path.join(base, "orch")
        foreign = os.path.join(base, "foreign")
        for root, db in ((orch, "orch"), (foreign, "un")):
            os.makedirs(os.path.join(root, ".beads"))
            os.makedirs(os.path.join(root, "sub"))
            with open(os.path.join(root, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
                f.write('{"database":"dolt","dolt_database":"%s"}' % db)
        orch_cwd = os.path.join(orch, "sub")
        foreign_cwd = os.path.join(foreign, "sub")

        # cmdtokens stub fixture(present)= guard が import する 5 API を定義する最小 module。
        present_lib = os.path.join(base, "cmdtokens-present")
        os.makedirs(present_lib)
        with open(os.path.join(present_lib, "cmdtokens.py"), "w", encoding="utf-8") as f:
            f.write(
                "def iter_commands(*a, **k):\n    return []\n"
                "def parse_statements(*a, **k):\n    return []\n"
                "def shlex_safe(*a, **k):\n    return None\n"
                "def track_cd(*a, **k):\n    return None\n"
                "def peel(*a, **k):\n    return (None, None, False, None)\n"
            )
        # 空 dir(absent)= cmdtokens.py を含まない → import 失敗。
        absent_lib = os.path.join(base, "cmdtokens-absent")
        os.makedirs(absent_lib)

        # (i) cmdtokens present + orch session → banner 無(silent)。
        os.environ["CMDTOKENS_LIB"] = present_lib
        out_present = _run(orch_cwd)
        check(out_present == "", "(i) present+orch → silent(banner 無)")

        # (ii) cmdtokens absent + orch session → banner 有 + 両 guard 名 + DISABLED + 解決 path。
        os.environ["CMDTOKENS_LIB"] = absent_lib
        out_absent = _run(orch_cwd)
        check(out_absent != "", "(ii) absent+orch → banner 有")
        check("bd-write-guard" in out_absent, "(ii) banner に bd-write-guard を含む")
        check("bash-file-write-guard" in out_absent, "(ii) banner に bash-file-write-guard を含む")
        check("DISABLED" in out_absent, "(ii) banner に DISABLED を明示")
        check(absent_lib in out_absent, "(ii) banner に解決 lib path を含む")
        check("ln -sfn" in out_absent, "(ii) banner に復旧(symlink)hint を含む")

        # (iii) cmdtokens absent + foreign session → no-op(banner 無)。self-scope が先に効く。
        os.environ["CMDTOKENS_LIB"] = absent_lib
        out_foreign = _run(foreign_cwd)
        check(out_foreign == "", "(iii) absent+foreign → no-op(誤注入ゼロ)")

        # (iv) present + foreign session も no-op(self-scope で弾く)。
        os.environ["CMDTOKENS_LIB"] = present_lib
        check(_run(foreign_cwd) == "", "(iv) present+foreign → no-op")

        # 非vacuous: 同一 orch session で present は無音・absent は banner = 検出器が状態を弁別する。
        check(out_present == "" and out_absent != "",
              "non-vacuous: present↔absent を弁別(env-degraded 誤 PASS を排除)")

        # 解決規則: 非絶対 CMDTOKENS_LIB は既定へ落とす(consume preamble と同一)。
        os.environ["CMDTOKENS_LIB"] = "relative/not/abs"
        check(_resolve_cmdtokens_lib() == _CMDTOKENS_DEFAULT_LIB,
              "解決: 非絶対 CMDTOKENS_LIB → 既定へ fallback")

        # (v) _safe_cwd: os.getcwd() が例外でも die せず "/" へ degrade(deleted-cwd 契約・orch-k33)。
        #   非vacuous: 例外時は "/" / 正常時は実 cwd を返す＝degrade と正常を弁別する。
        def _raise_fnf(*a, **k):
            raise FileNotFoundError("cwd deleted (self-test)")

        _real_getcwd = os.getcwd
        try:
            os.getcwd = _raise_fnf
            check(_safe_cwd() == "/", "(v) _safe_cwd: getcwd 例外時 '/' へ degrade(die しない)")
        finally:
            os.getcwd = _real_getcwd
        check(_safe_cwd() == os.getcwd(),
              "(v) _safe_cwd: 正常時は実 cwd を返す(non-vacuous・degrade と弁別)")
    finally:
        if saved_env is None:
            os.environ.pop("CMDTOKENS_LIB", None)
        else:
            os.environ["CMDTOKENS_LIB"] = saved_env
        shutil.rmtree(base, ignore_errors=True)

    if failures:
        print("guard-health self-test: FAILED (%d)" % len(failures))
        return 1
    print("guard-health self-test: PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())

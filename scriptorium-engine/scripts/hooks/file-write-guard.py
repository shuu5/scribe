#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse[Edit|Write|MultiEdit|NotebookEdit] hook: orchestrator session が **foreign 台帳配下の file** を
#   構造化編集ツール（Edit/Write/MultiEdit/NotebookEdit）で書くことを deny する（exit 2）。bd-write-guard.py
#   （bd 台帳 write）と対称の、plain architecture/file write に対する write-isolation moat。
#   ★scope（orch-w88 gate F3）: 本 guard は上記**編集ツール経由**の write のみカバーする。Bash 経由の file
#     変異（sed -i / tee / リダイレクト / cp / mv …）は射程外＝orch-2o6（B1-L3・defense-in-depth）の領分で、
#     「任意 file」は「編集ツール経由の任意 file」の意（全変異経路の網羅ではない）。
# 由来: orch-w88（B1 一般化 L2）。現 bd-write-guard.py は bd コマンドのみ検査し、folio inventory.json 等の
#   plain architecture file は orchestrator が Edit/Write で foreign を書けてしまい中核不変条件
#   「orchestrator は foreign を write しない」が新 artifact クラスで機械担保ゼロだった（research B1）。
#   本 guard は書込先 file_path を walk-up し、その台帳 dolt_database が SELF_PREFIX（orch）でなければ deny する。
#
# 脅威モデル: orchestrator session（連結 substrate で foreign repo を hydrate して read する）が、hydrate 先や
#   worktree 経由で foreign repo の file を直接 Edit/Write し owner 2人違反を起こすのを機械で止める。bd 台帳の
#   write-isolation（bd-write-guard.py）を、台帳に紐づく**任意 file**へ一般化する（top-spec §4）。
#
# session self-scope（bd-write-guard.py と同一機構・共有 lib orch_session を SSOT）: plugin として global
#   enable すると PreToolUse[Edit|Write|MultiEdit] は**全セッション**で発火する。非 orchestrator session
#   （scribe / cc-session …）で発火しても他 project の file 編集を一切壊さないよう、guard 冒頭で
#   _is_orch_session(session_cwd) を見て非該当なら一切判定せず exit 0（no-op）で抜ける。判定は session cwd
#   （hook payload top-level cwd）基準で、書込先 file_path が orch 配下かとは独立。
#
# 判定（三値・gate-ratified 誤検出境界）:
#   1. _is_orch_session(session_cwd) が False → no-op（exit 0）。
#   2. file_path を session cwd 基準で絶対化し realpath で symlink 解決 → その親から walk-up で
#      .beads/metadata.json dolt_database を解決。
#   3. dolt_database == SELF_PREFIX（orch）        → allow（自台帳＝scriptorium 自リポ配下の正当編集）。
#      dolt_database is None（台帳外＝/tmp・scratchpad・~/.claude/projects〔実 dir〕等）→ allow。
#      dolt_database != SELF_PREFIX（foreign 台帳配下＝scribe/cc-session/folio 等 if .beads）→ deny(exit2)。
#   ★~/.claude の扱い（orch-w88 gate F1-a）: 当初コメントは「~/.claude=台帳外→allow」と書いていたが誤り。
#     ~/.claude/CLAUDE.md・skills・plugins・scripts・settings.json 等は **symlink 実体が foreign project（例
#     scribe）所有**で、realpath 解決後に foreign 判定となり（設計通り正しく）deny される＝編集は所有 project の
#     admin 経由（foreign deploy 配布モデルと整合）。台帳外として allow されるのは ~/.claude/projects（実 dir・
#     orchestrator のメモリ保存先）や /tmp・scratchpad 等、realpath 後に foreign 台帳を持たない path のみ。
#   帰結: orchestrator session は foreign リポの file を直接 Edit/Write 不可（編集は当該 project の admin spawn）。
#
# 失敗時方針: 入力解析・guard 内部・lib ロードのいずれの例外でも fail-open（exit 0）＝guard が全 Edit/Write を
#   brick しない（bd-write-guard.py と同方針・hooks.json の二重 fail-safe 指示に従う）。symlink は realpath
#   解決後に walk-up する（orch 配下の symlink が foreign file を指す経路を実書込先で判定する）。
# 検証: `python3 file-write-guard.py --self-test`（hermetic temp ledger fixture・subprocess 非依存。
#   mutation testing で deny ロジックの非vacuous を証明する）。

import sys
import os
import json

# 自台帳 prefix / session・台帳 判定は共有 lib（scripts/hooks/lib/orch_session.py・orch-w88 抽出）を SSOT
#   とする。bd-write-guard と同一の SELF_PREFIX / walk-up 台帳解決 / orch session 判定を共有する。本 import
#   は logic ゼロの薄い解決層: 同梱 lib/ を sys.path 解決して import するだけ。lib ロード不能は fail-open
#   （通常 hook 経路は exit0 で Edit/Write を brick しない・self-test は exit せず main へ RED 報告させる）。
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
        sys.stderr.write(f"[file-guard] cannot load orch_session lib, failing open: {e}\n")
        sys.exit(0)


def render(target, dolt_db):
    # present-but-unreadable は foreign 確定ではない（台帳識別不能＝**orch 自台帳の metadata 破損**も含む）。
    #   foreign 前提の「admin を spawn せよ」は orch 自破損時に誤誘導（admin spawn は無意味/実行不能＝
    #   degraded-state lockout・gate errata #1）。状態整合な metadata 修復路を案内し remediation を分岐する。
    #   sentinel は str() が非決定的 address になるため文面でも生 str 化しない。
    if dolt_db is _LEDGER_UNREADABLE:
        return ("DENIED(file): 書込先 " + str(target) + " の台帳が present-but-unreadable（壊れ/未読 metadata で"
                "識別不能）ゆえ安全側 deny。書込先台帳の `.beads/metadata.json` を修復してから再試行せよ"
                "（orch 自台帳なら raw shell で修復・foreign なら当該 project の admin 経由）。read は許可。\n")
    return ("DENIED(file): foreign 台帳配下の file への Edit/Write/MultiEdit は禁止。書込先 " + str(target) +
            " は別台帳（dolt_database=" + str(dolt_db) + "）配下で、orchestrator が write してよいのは自台帳"
            "（prefix '" + SELF_PFX + "' / dolt_database='" + SELF_PREFIX + "'）配下のみ。owner 2人違反になるため "
            "foreign リポの file 編集は当該 project の admin を spawn して行え（orch-spawn-admin）。read は許可。\n")


def _classify_target(dolt_db, target, _enforce=True):
    """`_resolve_ledger` で解決した書込先台帳 dolt_db から (code, msg) を返す。code: 0=allow / 2=deny。
    四値判定（gate-ratified 誤検出境界・orch-8dl）: 自台帳(orch)=allow / 台帳外(None)=allow /
    foreign(他 dolt_database)=deny / present-but-unreadable(`_LEDGER_UNREADABLE` sentinel)=deny。
    最後の present-but-unreadable deny が orch-8dl の核心: 壊れ/未読 metadata（nested shadow 含む）で
    台帳が識別不能な書込先を、従来の None 畳み込み（allow）でなく deny 側へ倒す（session 判定
    `_is_orch_session` の fail-closed と対称）。sentinel は `== SELF_PREFIX`/`is None` のいずれにも
    マッチせず deny 分岐へ自然に落ちる。
    _enforce は mutation-testing seam（self-test 専用）: False で deny 分岐を撤去した mutant 挙動になり、
    foreign / present-but-unreadable ケースが allow(0) に落ちる。本物（_enforce=True・production 既定）では
    deny(2) する。self-test がこの 2 値を弁別することで deny ロジックが load-bearing（非vacuous）であると証明する。"""
    if dolt_db == SELF_PREFIX:
        return 0, ""                       # 自台帳（orch）配下 → allow（scriptorium 自リポの正当編集）
    if dolt_db is None:
        return 0, ""                       # 台帳外（/tmp・scratchpad・~/.claude/projects 等）→ allow（~/.claude/* の symlink 実体は foreign で deny 側・F1-a）
    if not _enforce:
        return 0, ""                       # mutation seam: deny 撤去 mutant → allow（self-test 弁別用）
    # foreign 台帳配下 or present-but-unreadable（後者は orch-8dl で deny 化＝session 判定と対称）→ deny
    return 2, render(target, dolt_db)


def decide_file(file_path, session_cwd, _enforce=True):
    """PreToolUse[Edit|Write|MultiEdit] の最終判定。(code, msg) を返す（code: 0=allow / 2=deny）。
    全例外は fail-open（0, ""）で握り潰す＝guard が Edit/Write を brick しない。"""
    try:
        if not _is_orch_session(session_cwd):
            return 0, ""                   # 非 orchestrator session → no-op（他 project を壊さない）
        if not file_path:
            return 0, ""                   # file_path 不明 → 判定不能 fail-open
        base = session_cwd or os.getcwd()
        # 相対は session cwd 基準で絶対化（os.path.join は file_path が絶対ならそれを返す）→ realpath で
        # symlink 解決（存在しない末尾は素通し）。これにより orch 配下 symlink→foreign の実書込先を判定する。
        target = os.path.realpath(os.path.join(base, file_path))
        # walk-up 起点: 通常 file は dirname（親ディレクトリ）から walk-up する。ただし target が
        #   ディレクトリ自身（台帳ルートを file_path に渡す異常ケース・symlink→dir 等）なら dirname で
        #   親へ上がると foreign 台帳の .beads/metadata.json を読み飛ばすため、target 自身から walk-up
        #   する（R1-F2: walk-up 起点ずれ防止・gate finding errata）。
        start = target if os.path.isdir(target) else os.path.dirname(target)
        # orch-8dl: 書込先台帳は _resolve_ledger（三値）で解決し present-but-unreadable を deny に倒す
        #   （_ledger_dolt_database の str|None 畳み込みは sentinel を None=allow に潰すため使わない）。
        dolt_db = _resolve_ledger(start)
        return _classify_target(dolt_db, target, _enforce=_enforce)
    except Exception as e:
        sys.stderr.write(f"[file-guard] internal error, failing open: {e}\n")
        return 0, ""


def extract_target_path(tool_input):
    """PreToolUse tool_input から書込先 path を取り出す（orch-w88 gate F2）。Edit/Write/MultiEdit は
    file_path、NotebookEdit は notebook_path を使う。最初の非空を返し、無ければ ""。file_path を優先
    （両方ある異常入力でも安定）。dict でない入力は "" に degrade（fail-open 側）。"""
    if not isinstance(tool_input, dict):
        return ""
    return tool_input.get("file_path") or tool_input.get("notebook_path") or ""


def main():
    if "--self-test" in sys.argv:
        if _orch_session_load_error is not None:
            print(f"FAIL: [preamble] orch_session lib load 失敗: {_orch_session_load_error}")
            print("file-write-guard self-test: ABORTED (orch_session 未 load)")
            return 1
        return run_self_test()
    raw = sys.stdin.read() if not sys.stdin.isatty() else ""
    try:
        data = json.loads(raw) if raw.strip() else {}
        tool_input = data.get("tool_input") or {}
        # 書込先 path 抽出（orch-w88 gate F2 errata）: Edit/Write/MultiEdit は tool_input.file_path、
        #   NotebookEdit は tool_input.notebook_path を書込先に持つ。旧実装は file_path のみ読み、
        #   NotebookEdit が file_path 空のまま fail-open allow ですり抜けた。両キーを見る extract_target_path
        #   に集約してテスト可能化した（self-test が notebook_path 読みの非vacuous を弁別）。MultiEdit も
        #   単一 file + edits[] で 1 コール複数 file は編集しない。将来 1 コール複数 file 編集 tool が出たら
        #   全 path キー（file_path・edits[].file_path 等）を集め各々判定する拡張が要る（R1-F4・現状 YAGNI）。
        file_path = extract_target_path(tool_input)
        cwd = data.get("cwd") or os.getcwd()
    except Exception as e:
        sys.stderr.write(f"[file-guard] input parse error, failing open: {e}\n")
        return 0
    try:
        code, msg = decide_file(file_path, cwd)
    except Exception as e:
        sys.stderr.write(f"[file-guard] internal error, failing open: {e}\n")
        return 0
    if msg:
        sys.stderr.write(msg)
    return code


# --- self-test（hermetic: temp .beads/metadata.json fixture・subprocess も実 DB も触らない） ----------
# bd-write-guard.py の session self-test と同型。orch/foreign/bare(.beads無)/broken(不正JSON) の 4 台帳を
# 共通 base 下に作り、相対 path・symlink・walk-up subdir を含めて三値判定を実証する。最後に mutation testing
# で「deny ロジック撤去で foreign テストが RED になる」非vacuous を証明する（orch-w88 acceptance）。
def run_self_test():
    import tempfile
    import shutil

    failures = []
    checks = 0
    base = tempfile.mkdtemp(prefix="filewriteguard-st-")
    try:
        def mk(name, dolt_db):
            """base/<name> を作り、dolt_db に応じて .beads/metadata.json を置く。
            dolt_db=None → .beads 無し（台帳外）/ '__broken__' → 不正 JSON(parse 失敗=①)/
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

        orch_root = mk("orch", "orch")
        foreign_root = mk("foreign", "un")
        bare_root = mk("bare", None)
        broken_root = mk("broken", "__broken__")
        nondict_root = mk("nondict", "__nondict__")
        nokey_root = mk("nokey", "__nokey__")
        orch_deep = os.path.join(orch_root, "docs", "sub")
        os.makedirs(orch_deep)
        foreign_deep = os.path.join(foreign_root, "src", "deep")
        os.makedirs(foreign_deep)
        # orch-8dl nested shadow fixture: orch 祖先（orch_root）配下に壊れ metadata の子台帳を置く。書込先が
        #   この子配下だと walk-up が壊れ子の present-but-unreadable で打ち切られ祖先 orch に到達せず deny する
        #   （shadow も present-but-unreadable deny の同一経路サブケース＝_resolve_ledger 直利用への切替で deny 化）。
        nested_shadow = os.path.join(orch_root, "nestedbroken")
        os.makedirs(os.path.join(nested_shadow, ".beads"))
        with open(os.path.join(nested_shadow, ".beads", "metadata.json"), "w", encoding="utf-8") as f:
            f.write("{ broken nested metadata")

        # (file_path, session_cwd, expect_code, label)
        cases = [
            (os.path.join(orch_root, "inventory.json"), orch_root, 0,
             "orch session: orch 配下 file → allow"),
            (os.path.join(foreign_root, "inventory.json"), orch_root, 2,
             "orch session: foreign 配下 file → deny"),
            (os.path.join(bare_root, "x.txt"), orch_root, 0,
             "orch session: 台帳外(.beads 無) file → allow"),
            # orch-8dl: **書込先**が present-but-unreadable（壊れ metadata 配下）でも deny する（旧 KNOWN
            #   RESIDUAL UNDER-BLOCK を解消）。書込先解決を `_resolve_ledger` 直利用に切り替え、
            #   `_LEDGER_UNREADABLE`（sentinel）を None=allow に畳まず `_classify_target` の deny 分岐へ落とす
            #   ＝session 判定 _is_orch_session の fail-closed=deny と対称。`_ledger_dolt_database` の None 畳み込み
            #   へ回帰すると allow に反転しここで RED（= `_resolve_ledger` 直利用が load-bearing である pin）。
            (os.path.join(broken_root, "x.json"), orch_root, 2,
             "orch session: 壊れ metadata 配下を**書込先**に → deny（orch-8dl で present-but-unreadable を deny 化＝session 判定と対称）"),
            # orch-8dl nested shadow: orch 祖先（orch_root）配下に壊れ子台帳。書込先がこの子配下だと walk-up が
            #   壊れ子の present-but-unreadable で打ち切られ祖先 orch に到達せず deny（present-but-unreadable deny
            #   の shadow サブケース）。`_ledger_dolt_database` 回帰だと None=台帳外と誤分類され allow に反転し RED。
            (os.path.join(nested_shadow, "x.json"), orch_root, 2,
             "orch session: nested shadow（orch 祖先 + 壊れ子 metadata）を書込先に → deny（orch-8dl・walk-up が壊れ子で打ち切られ祖先 orch に到達せず）"),
            (os.path.join(orch_deep, "x.md"), orch_root, 0,
             "orch session: orch deep subdir → walk-up allow"),
            (os.path.join(foreign_deep, "x.py"), orch_root, 2,
             "orch session: foreign deep subdir → walk-up deny"),
            # 非 orchestrator session（session cwd が foreign / 台帳外）→ 書込先に関わらず no-op allow
            (os.path.join(foreign_root, "x.json"), foreign_root, 0,
             "非 orch session(foreign cwd): foreign file でも no-op allow"),
            (os.path.join(foreign_root, "x.json"), bare_root, 0,
             "非 orch session(.beads 無 cwd): no-op allow"),
            (os.path.join(orch_root, "x.json"), foreign_root, 0,
             "非 orch session(foreign cwd): orch file でも no-op allow"),
            # orch-5yl 波及: session cwd の metadata が present-but-unreadable(壊れ JSON)→ _is_orch_session が
            #   fail-closed で True(orch session とみなす)→ foreign 書込先は従来通り deny。皆無(.beads 無)cwd の
            #   fail-open(上の bare_root session ケース)と対になる区別ルール①の file-guard 波及 pin。
            (os.path.join(foreign_root, "x.json"), broken_root, 2,
             "present-but-unreadable session(壊れ metadata cwd)→ fail-closed orch session → foreign file deny (orch-5yl 波及)"),
            # orch-5yl ②境界の恒久回帰 pin: session cwd の metadata が parse 成功だが非 dict(JSON 配列)
            #   → _is_orch_session は fail-open(False=非 orch)→ foreign 書込先でも no-op allow。`else None` を
            #   ① と取り違え _LEDGER_UNREADABLE へ倒すと orch session 化し deny(2) に反転＝ここで RED 化する。
            (os.path.join(foreign_root, "x.json"), nondict_root, 0,
             "②境界: 非 dict metadata session(parse 成功)→ fail-open 非 orch → foreign file でも no-op allow (orch-5yl)"),
            # orch-ehg(a) ②境界の独立 pin: session cwd の metadata が parse 成功・dict だが dolt_database
            #   キー欠落(nokey) → _is_orch_session は fail-open(False=非 orch)。__nondict__(非dict・`else None`)
            #   とは **別 code path**(`.get("dolt_database")`→None)だが同じ no-op allow へ畳む。① と取り違え
            #   _LEDGER_UNREADABLE へ倒すと orch session 化し deny(2) に反転＝ここで RED 化する（nondict と独立）。
            (os.path.join(foreign_root, "x.json"), nokey_root, 0,
             "②境界(別 path): nokey metadata session(dict・dolt_database 欠落・parse 成功)→ fail-open 非 orch → foreign file でも no-op allow (orch-ehg)"),
            # R1-F2 errata: 台帳ルート dir 自身を file_path に渡すケース（walk-up 起点が dirname で親へ
            #   上がると foreign metadata を読み飛ばす経路の回帰ガード）。isdir 分岐で target 自身から walk-up。
            (foreign_root, orch_root, 2,
             "orch session: foreign 台帳ルート dir 自身を file_path → deny (R1-F2)"),
            (orch_root, orch_root, 0,
             "orch session: orch 台帳ルート dir 自身を file_path → allow (R1-F2)"),
        ]
        for fp, cwd, want, label in cases:
            checks += 1
            try:
                code, _msg = decide_file(fp, cwd)
            except Exception as e:
                failures.append(f"[EXC] {label}: {fp!r}@{cwd!r} -> {e}")
                continue
            if code != want:
                failures.append(f"[code {want} expected] {label}: {fp!r}@{cwd!r} -> got {code}")

        # relative file_path: orch session(cwd=orch_root)で相対 path が foreign / orch を指す → session cwd
        # 基準で解決される（絶対化が cwd 依存でなく session_cwd 依存であることを pin）。
        checks += 1
        rel_to_foreign = os.path.relpath(os.path.join(foreign_root, "rel.json"), orch_root)
        try:
            code, _ = decide_file(rel_to_foreign, orch_root)
            if code != 2:
                failures.append(
                    f"[relative] 相対 file_path が foreign 解決 deny でない: {rel_to_foreign!r}@{orch_root!r} -> {code}")
        except Exception as e:
            failures.append(f"[EXC relative-foreign] {e}")
        checks += 1
        rel_to_orch = os.path.relpath(os.path.join(orch_root, "rel2.json"), orch_root)
        try:
            code, _ = decide_file(rel_to_orch, orch_root)
            if code != 0:
                failures.append(f"[relative] 相対 file_path が orch 解決 allow でない: {code}")
        except Exception as e:
            failures.append(f"[EXC relative-orch] {e}")

        # symlink: orch 配下の file symlink が foreign file を指す → realpath 解決後の実書込先(foreign)で deny。
        checks += 1
        link_path = os.path.join(orch_root, "evil-link.json")
        try:
            os.symlink(os.path.join(foreign_root, "real.json"), link_path)
            sym_ok = True
        except Exception:
            sym_ok = False
        if sym_ok:
            try:
                code, _ = decide_file(link_path, orch_root)
                if code != 2:
                    failures.append(f"[symlink] orch 配下 symlink→foreign が realpath 後 deny でない: {code}")
            except Exception as e:
                failures.append(f"[EXC symlink] {e}")
        else:
            print("NOTE: symlink 作成不可の環境ゆえ symlink ケースを skip（checks は維持）")

        # mutation testing（非vacuous 証明・orch-w88 acceptance）: deny ロジック(_enforce)を撤去した mutant
        #   では foreign file が allow(0) に落ち、本物(_enforce=True)では deny(2) になる＝foreign deny ケースが
        #   deny ロジックの有無を真に弁別する（テストが空でない）。walk-up を含むフルパスで弁別する。
        checks += 1
        ff = os.path.join(foreign_root, "mut.json")
        try:
            real_code, _ = decide_file(ff, orch_root, _enforce=True)
            mut_code, _ = decide_file(ff, orch_root, _enforce=False)
            if real_code != 2:
                failures.append(f"[mutation] 本物の foreign deny が 2 でない: {real_code}")
            if mut_code != 0:
                failures.append(
                    f"[mutation] mutant(deny 撤去)で foreign が allow(0)に落ちない＝テスト vacuous: {mut_code}")
        except Exception as e:
            failures.append(f"[EXC mutation] {e}")

        # orch-8dl mutation: present-but-unreadable 書込先の deny も load-bearing（_enforce seam が sentinel も
        #   制御する）。本物(_enforce=True)では壊れ metadata 配下が deny(2)、mutant(deny 撤去)では allow(0)に
        #   落ちる＝present-but-unreadable deny がテストで弁別される（vacuous でない）。
        checks += 1
        ub = os.path.join(broken_root, "mut.json")
        try:
            real_ub, _ = decide_file(ub, orch_root, _enforce=True)
            mut_ub, _ = decide_file(ub, orch_root, _enforce=False)
            if real_ub != 2:
                failures.append(f"[mutation/unreadable] 本物の present-but-unreadable deny が 2 でない: {real_ub}")
            if mut_ub != 0:
                failures.append(
                    f"[mutation/unreadable] mutant(deny 撤去)で unreadable が allow(0)に落ちない＝vacuous: {mut_ub}")
        except Exception as e:
            failures.append(f"[EXC mutation/unreadable] {e}")

        # orch-8dl errata #1: present-but-unreadable deny の message は metadata 修復を案内し admin-spawn 一辺倒で
        #   ない（orch 自台帳破損の degraded-state lockout で foreign admin spawn へ誤誘導しないことを pin）。
        checks += 1
        c_msg, m_msg = decide_file(os.path.join(broken_root, "x.json"), orch_root)
        if c_msg != 2 or "修復" not in m_msg or "spawn" in m_msg:
            failures.append(
                f"[errata#1] present-but-unreadable deny message が修復案内でない/admin-spawn 誘導が残る: code={c_msg} msg={m_msg!r}")

        # never-die 契約: session_cwd=None でも例外で死なない（main は os.getcwd() に解決後渡すため production
        #   では到達しないが、boolean 値は getcwd 依存ゆえ assert せず die しないことだけ確認）。
        checks += 1
        try:
            decide_file("x.json", None)
        except Exception as e:
            failures.append(f"[EXC none-cwd] session_cwd=None で die: {e}")

        # F2 errata 回帰: 書込先 path 抽出が NotebookEdit の notebook_path を読む（旧実装は file_path のみ＝
        #   NotebookEdit が空 path で fail-open すり抜けた）。notebook_path ケースが load-bearing＝抽出から
        #   notebook_path 分岐を外すと "" になりこのテストが RED（非vacuous）。file_path 優先も pin する。
        checks += 1
        if extract_target_path({"file_path": "/a/b.py"}) != "/a/b.py":
            failures.append("[extract] file_path 抽出が一致しない")
        checks += 1
        if extract_target_path({"notebook_path": "/a/n.ipynb"}) != "/a/n.ipynb":
            failures.append("[extract] notebook_path 抽出が一致しない（NotebookEdit すり抜け回帰・F2）")
        checks += 1
        if extract_target_path({}) != "":
            failures.append("[extract] 空 tool_input は空文字であるべき")
        checks += 1
        if extract_target_path({"file_path": "/a", "notebook_path": "/b"}) != "/a":
            failures.append("[extract] file_path を優先すべき（両キー入力）")
        checks += 1
        if extract_target_path("not-a-dict") != "":
            failures.append("[extract] 非 dict 入力は空文字に degrade すべき")

        # F2 end-to-end: NotebookEdit が foreign 配下 notebook を指す → extract→decide で deny(2) になる
        #   （抽出と判定の結線回帰）。orch session・foreign 配下 .ipynb を notebook_path で渡す。
        checks += 1
        nb_input = {"notebook_path": os.path.join(foreign_root, "nb.ipynb")}
        try:
            code_nb, _ = decide_file(extract_target_path(nb_input), orch_root)
            if code_nb != 2:
                failures.append(f"[notebook-e2e] foreign 配下 NotebookEdit が deny でない: {code_nb}")
        except Exception as e:
            failures.append(f"[EXC notebook-e2e] {e}")

    finally:
        shutil.rmtree(base, ignore_errors=True)

    if failures:
        for f in failures:
            print("FAIL:", f)
        print(f"file-write-guard self-test: {len(failures)} FAILED (of {checks} checks)")
        return 1
    print(f"file-write-guard self-test: {checks}/{checks} OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 共有 lib: scribe session 判定 + 台帳 dolt_database 解決。
#
# 由来: scriptorium scripts/hooks/lib/orch_session.py（orchestrator の同型機構＝SELF_PREFIX / walk-up 台帳
#   解決 / session 判定）を scribe 向けに port。**本 module は用途の異なる 2 種の session 判定を提供する**:
#     - _is_scribe_session       : banner hook（session-start-guard-health.py）用・**fail-open**。
#     - _is_scribe_guard_session : write guard（bd-write-guard.py・sc-wdr）用・**fail-closed**。
#   両者は同一の SELF_PREFIX / walk-up 台帳解決（_resolve_ledger）を共有しつつ、present-but-unreadable
#   （`.beads/metadata.json` は在るが読取/parse 失敗）の扱いだけが**意図的に逆**である（下記）。
#   orch は単一 orch_session の _is_orch_session（fail-closed）を banner と guard で共用するが、scribe は
#   意図的に分岐する（sc-wdr / D2）。banner は firing＝context への警告注入ゆえ誤注入ゼロを最優先し
#   fail-open（確定 self だけ firing）、guard は firing＝write moat の維持ゆえ fail-closed（不確実なら self
#   とみなし moat を瞬間的に開かない）。
#
# banner(fail-open) vs guard(fail-closed) の非対称（sc-wdr で明文化・D2）:
#   - banner(_is_scribe_session): dolt_database == "sc" と **確定**したときだけ self とみなし firing する。
#     foreign（'orch'/'un'…）・台帳外・**present-but-unreadable**・判定不能はすべて False（無出力 no-op）。
#     理由（kickoff 死守＝誤注入ゼロ）: 本 hook は警告 banner を stdout（context）へ注入するだけで、
#     不確実なときに firing する必要はない。むしろ foreign session への誤注入をゼロにする方が重要ゆえ、
#     確定 self だけで firing する（過小発火＝安全側）。
#   - guard(_is_scribe_guard_session): banner と逆に **present-but-unreadable を fail-closed**（self とみなす）。
#     self ledger（sc）が在るのに metadata を一過性に読めない/JSON 不正なだけで write-isolation moat を
#     瞬間的に開かない（foreign write を一過性に通さない）。orch_session の _is_orch_session と同型。
#
# self-scope の理由（最重要）: 本 lib を consume する hook を plugin として global enable すると全セッションで
#   発火する。orchestrator の orch session も `.beads` を持つため、dolt_database=='sc' の台帳 identity で
#   絞り込む（**fully-dynamic に cwd 台帳を self にはしない**＝D1。無関係 project の bare bd write まで
#   guard が funnel すると当該 project の bd 操作を brick する）。これは role-inject の `.worktrees/` cwd 判定
#   より厳密な、台帳 identity ベースの絞り込みである。
#   **cross-plugin 共存 note**: 稀な present-but-unreadable-in-foreign-session（foreign の orch 等 session で
#   metadata が一過性に読めない）では、guard の fail-closed が foreign(orch 等)の write を一時 over-block
#   しうる。ただし fail-safe（deny＝bad write を通さない・foreign 側 owner は read か bdw で回避可能）ゆえ許容。
#
# 設計（依存ゼロ＝os/json のみ・subprocess 非依存で完全 hermetic）: filesystem の stat/read だけで判定し、
#   例外は内部で握り潰して決して伝播させない（hook が session/台帳 判定で die しない契約）。

import os
import json

# 自台帳 prefix（.beads/metadata.json dolt_database="sc" / scribe CLAUDE.md・metadata SSOT）。
# SELF_PREFIX は 2 つの役割を兼ねる: (1) bead id prefix 規則の自台帳判定（`sc-` か否か）、(2) session
#   self-scope の台帳判定（session cwd の dolt_database == SELF_PREFIX か）。
SELF_PREFIX = "sc"
SELF_PFX = SELF_PREFIX + "-"

# 三値 walk-up 解決の sentinel（orch-5yl から port）: walk-up で `.beads/metadata.json` ファイルは見つかったが
#   その識別子（dolt_database）を **読取/parse 失敗** で確定できなかった状態を表す。str でない一意 object
#   ゆえ実在の dolt_database 値と衝突しない。`None`（= ファイル自体が walk-up に皆無＝台帳外/他 project）
#   とは明確に別状態である点が本 sentinel の存在理由（session 判定の fail-closed/fail-open を分岐させる）。
_LEDGER_UNREADABLE = object()


def _resolve_ledger(cwd):
    """cwd が属する bd 台帳を walk-up で三値解決する（orch_session._resolve_ledger から port）。
    cwd から上方向へ最初に見つかる `.beads/metadata.json` を読む（bd 自身の台帳解決と同じ walk-up・
    subprocess 非依存＝filesystem stat/read のみで hermetic）。返り値は次の三状態:

      - dolt_database 文字列 : metadata がファイルとして存在し、読取・JSON parse に成功し dict で
                              dolt_database キーを持つ（正常）。**空文字列 '' も str ゆえ本状態**
                              （`.get` が '' をそのまま返す＝None 化しない・pre-existing 挙動不変。
                              後段 _ledger_dolt_database も '' を str として通す）。
      - _LEDGER_UNREADABLE  : metadata が **ファイルとして存在するが open/read もしくは JSON parse が
                              例外を投げた**（一過性に読めない / JSON 不正＝区別ルール①）。
                              parse は成功したが非 dict / dolt_database キー欠落は **含めない**
                              （parse 成功＝「読取/parse 失敗」でないため従来通り None に倒す）。
      - None               : (a) walk-up 上に `.beads/metadata.json` が **皆無**（git 外 / .beads 無し
                              ＝他 project・区別ルール②＝不変）、または (b) ファイルは在って parse は
                              成功したが非 dict もしくは dolt_database キー欠落（識別不能だが parse 失敗
                              ではない＝従来の fail-open を保つ）。空文字列 '' は上記 str 状態であって
                              本 None 状態ではない（'' を返す・pre-existing）。

    例外は内部で握り潰し決して伝播させない（hook が台帳判定で die しない契約）。本関数を
    `_ledger_dolt_database`（外部契約 str|None を維持・banner が間接利用）と `_is_scribe_guard_session`
    （present-but-unreadable を fail-closed 化・guard 用）が共有する。"""
    try:
        d = os.path.abspath(cwd or os.getcwd())
    except Exception:
        return None
    prev = None
    while d and d != prev:
        meta = os.path.join(d, ".beads", "metadata.json")
        try:
            present = os.path.isfile(meta)
        except Exception:
            return None  # presence 判定すら不能 → 従来通り None（fail-open・過剰 block を避ける）
        if present:
            try:
                with open(meta, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                # ファイルは在るが読取/parse 失敗（区別ルール①）→ present-but-unreadable。
                # guard(_is_scribe_guard_session)は self ledger とみなし fail-closed、
                # _ledger_dolt_database(banner 経由)は None に畳む。
                return _LEDGER_UNREADABLE
            # parse 成功: 非 dict / dolt_database キー欠落は「読取/parse 失敗」でないので従来通り None。
            # ただし dolt_database が空文字列 '' のときは `.get` が '' を返す＝'' をそのまま通す
            # （None 化しない・pre-existing 挙動不変。banner 判定は ''!="sc" で False）。
            return (data or {}).get("dolt_database") if isinstance(data, dict) else None
        prev, d = d, os.path.dirname(d)
    return None  # walk-up で `.beads/metadata.json` を発見せず（台帳外・他 project＝区別ルール②）


def _ledger_dolt_database(cwd):
    """cwd が属する bd 台帳の dolt_database を返す（**外部契約 str|None** の薄いプリミティブ）。
    `_resolve_ledger` の三値を str|None へ畳む。見つからない（git 外 / .beads 無し）・読めない・
    JSON 不正・非 dict・dolt_database キー欠落のいずれも None を返す（= 識別不能 → 呼出側で no-op）。
    ただし dolt_database が空文字列 '' の場合は '' をそのまま返す（str ゆえ None 化しない・pre-existing
    挙動不変）。非 str スカラ `dolt_database`〔例 `123`＝corruption/手編集 corner〕は None へ正規化する
    （実 metadata は常に str ゆえ negligible・方向は under-block・stated 契約 str|None を honour する）。
    例外は内部で握り潰し決して伝播させない。"""
    db = _resolve_ledger(cwd)
    return db if isinstance(db, str) else None


def _is_scribe_session(cwd):
    """banner 用・**fail-open**。当該 session(cwd)が scribe session か。**dolt_database == SELF_PREFIX("sc")
    と確定**したときだけ True。foreign（'orch'/'un' 等）・台帳外・**present-but-unreadable**・判定不能は
    すべて False（無出力 no-op＝誤注入ゼロ）。present-but-unreadable は _ledger_dolt_database が
    _LEDGER_UNREADABLE を None へ畳むため None=="sc" で False に落ちる＝byte-outcome 不変（D2）。
    例外で die しない契約は `_resolve_ledger` が内部で握り潰すことで担保。"""
    return _ledger_dolt_database(cwd) == SELF_PREFIX


def _is_scribe_guard_session(cwd):
    """guard 用・**fail-closed**。当該 session(cwd)が scribe(sc)台帳 session か。banner(_is_scribe_session)と
    逆に **present-but-unreadable を fail-closed**（self とみなす）＝write moat を瞬間的に開かない。
    orch_session の _is_orch_session と同型（sc-wdr で banner と分岐・D2）。

      - 正常解決で dolt_database == SELF_PREFIX → True（scribe session）。
      - present-but-unreadable（`.beads/metadata.json` は在るが読取/parse 失敗・区別ルール①）→ True
        （fail-closed＝moat 維持）。識別子を読めない以上 self ledger かもしれず、moat を瞬間的に開かない。
      - 正常解決で foreign（dolt_database が 'orch'/'un'/'ccs' 等）→ False（no-op）。
      - `.beads/metadata.json` が walk-up に皆無（他 project / git 外・区別ルール②）→ False（fail-open・
        plugin global enable 時も他 project を一切壊さない・**②不変厳守**）。
      - 非 dict / dolt_database キー欠落（parse 成功だが識別不能）→ False（従来の fail-open を保つ）。
      - dolt_database が空文字列 '' → ''!=SELF_PREFIX ゆえ False。

    例外で die しない契約は `_resolve_ledger` が内部で握り潰すことで担保。"""
    db = _resolve_ledger(cwd)
    if db is _LEDGER_UNREADABLE:
        return True  # present-but-unreadable → self ledger とみなし fail-closed（区別ルール①）
    return db == SELF_PREFIX

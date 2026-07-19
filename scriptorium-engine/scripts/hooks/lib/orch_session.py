#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 共有 lib: orchestrator session 判定 + 台帳 dolt_database 解決。
# 由来: orch-w88（B1 一般化）で bd-write-guard.py（un-mbz の session self-scope）から抽出。
#   write-isolation を機械強制する 2 つの guard ——
#     - bd-write-guard.py    : PreToolUse[Bash] の bd write guard（un-4sf）
#     - file-write-guard.py  : PreToolUse[Edit|Write|MultiEdit] の file write guard（orch-w88）
#   —— が同一の SELF_PREFIX / walk-up 台帳解決 / orch session 判定を共有するための単一 SSOT。
#
# SELF_PREFIX SSOT（orch-w88 で本 module に一本化）: 自台帳 prefix は本 module を SSOT とし、両 guard /
#   docs/scriptorium-top-spec.md §4 / CLAUDE.md「SELF_PREFIX が SSOT」節が同一値（"orch"）を指す。
#   prefix を変えるときは本 module・.beads/metadata.json の dolt_database・CLAUDE.md の 3 点を揃える。
#   この `SELF_PREFIX` は bead id prefix 規則の自台帳判定（`orch-` か）と session self-scope の台帳判定
#   （`dolt_database == "orch"` か）の両方を兼ねる。
#
# 設計（依存ゼロ＝os/json のみ・subprocess 非依存で完全 hermetic）: filesystem の stat/read だけで判定し、
#   例外は内部で握り潰して決して伝播させない（guard が session/台帳 判定で die しない契約）。

import os
import json

# 自台帳 prefix（.beads/metadata.json dolt_database="orch" / orchestrator CLAUDE.md SSOT）。
SELF_PREFIX = "orch"
SELF_PFX = SELF_PREFIX + "-"

# 三値 walk-up 解決の sentinel（orch-5yl）: walk-up で `.beads/metadata.json` ファイルは見つかったが
#   その識別子（dolt_database）を **読取/parse 失敗** で確定できなかった状態を表す。str でない一意 object
#   ゆえ実在の dolt_database 値と衝突しない。`None`（= ファイル自体が walk-up に皆無＝台帳外/他 project）
#   とは明確に別状態である点が本 sentinel の存在理由（session 判定の fail-closed/fail-open を分岐させる）。
_LEDGER_UNREADABLE = object()


def _resolve_ledger(cwd):
    """cwd が属する bd 台帳を walk-up で三値解決する（orch-5yl で `_ledger_dolt_database` から分離した中核）。
    cwd から上方向へ最初に見つかる `.beads/metadata.json` を読む（bd 自身の台帳解決と同じ walk-up・
    subprocess 非依存＝filesystem stat/read のみで hermetic）。返り値は次の三状態:

      - dolt_database 文字列 : metadata がファイルとして存在し、読取・JSON parse に成功し dict で
                              dolt_database キーを持つ（正常）。**空文字列 '' も str ゆえ本状態**
                              （`.get` が '' をそのまま返す＝None 化しない・pre-existing 挙動で
                              orch-5yl 不変。後段 _ledger_dolt_database も '' を str として通す）。
      - _LEDGER_UNREADABLE  : metadata が **ファイルとして存在するが open/read もしくは JSON parse が
                              例外を投げた**（一過性に読めない / JSON 不正＝orch-5yl 区別ルール①）。
                              parse は成功したが非 dict / dolt_database キー欠落は **含めない**
                              （parse 成功＝「読取/parse 失敗」でないため従来通り None に倒す）。
      - None               : (a) walk-up 上に `.beads/metadata.json` が **皆無**（git 外 / .beads 無し
                              ＝他 project・orch-5yl 区別ルール②＝不変）、または (b) ファイルは在って
                              parse は成功したが非 dict もしくは dolt_database キー欠落（識別不能だが
                              parse 失敗ではない＝従来の fail-open を保つ）。空文字列 '' は上記 str 状態
                              であって本 None 状態ではない（'' を返す・pre-existing）。

    例外は内部で握り潰し決して伝播させない（guard が台帳判定で die しない契約）。本関数を `_ledger_dolt_database`
    （外部契約 str|None を維持）と `_is_orch_session`（present-but-unreadable を fail-closed 化）が共有する。"""
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
                # _is_orch_session は self ledger とみなし fail-closed、_ledger_dolt_database は None に畳む。
                return _LEDGER_UNREADABLE
            # parse 成功: 非 dict / dolt_database キー欠落は「読取/parse 失敗」でないので従来通り None。
            # ただし dolt_database が空文字列 '' のときは `.get` が '' を返す＝'' をそのまま通す
            # （None 化しない・pre-existing 挙動で orch-5yl 不変。session 判定は ''!=「orch」で False、
            #  書込先解決は ''!=None ゆえ deny 側＝旧 _ledger_dolt_database と同一）。
            return (data or {}).get("dolt_database") if isinstance(data, dict) else None
        prev, d = d, os.path.dirname(d)
    return None  # walk-up で `.beads/metadata.json` を発見せず（台帳外・他 project＝区別ルール②）


def _ledger_dolt_database(cwd):
    """cwd が属する bd 台帳の dolt_database を返す（**外部契約 str|None** の薄いプリミティブ）。
    `_resolve_ledger` の三値を str|None へ畳む。見つからない（git 外 / .beads 無し）・読めない・
    JSON 不正・dolt_database キー欠落のいずれも None を返す（= 識別不能）。ただし dolt_database が
    空文字列 '' の場合は '' をそのまま返す（str ゆえ None 化しない・pre-existing で orch-5yl 無回帰）。
    非 str スカラ `dolt_database`〔例 `123`＝corruption/手編集 corner〕は None へ正規化する（実 metadata は
    常に str ゆえ negligible・方向は under-block）。

    USED BY: 現状 **live caller は無い**（file/bash guard は orch-8dl で書込先解決を `_resolve_ledger`
    直利用へ移行・session 判定 `_is_orch_session` も `_resolve_ledger` の sentinel を直接見る・下記
    RESOLVED 参照）。bd-write-guard.py:123 が import するため symbol は保持する（**削除時は同 import も
    併せて更新**）。str|None 契約は将来利用者向けに維持。dead code の実撤去（bd-write-guard の unused
    import 併せ）は本変更の対象外＝別 step。

    RESOLVED（旧 KNOWN RESIDUAL UNDER-BLOCK・present-but-unreadable→None→allow を orch-8dl で deny 化）:
      かつて書込先解決は本関数経由で `_LEDGER_UNREADABLE`（非 str sentinel）を None に畳み、file/bash guard
      の `_classify_*` が `dolt_db is None`＝「台帳外＝allow」と扱って、present-but-unreadable
      （読取/parse 失敗）な foreign 書込先への変異を **deny できず素通し（under-block）**していた。これは
      session 判定（`_is_orch_session`）が同じ present-but-unreadable を fail-closed（deny 側）に倒すのと
      **非対称**だった。nested 構成で foreign repo の壊れ metadata が walk-up 上の readable な orch 祖先を
      **shadow** する（walk-up は最初の壊れ metadata で `_LEDGER_UNREADABLE` を返して打ち切られ祖先 orch に
      到達しない）ケースも、同じ present-but-unreadable→None→台帳外→allow の**サブケース**だった。
      orch-8dl でこの非対称を解消: **書込先解決は `_resolve_ledger` を直接呼び**、`_LEDGER_UNREADABLE`
      （present-but-unreadable・shadow 含む）を `_classify_*` の deny 分岐へ落として **deny 側へ倒す**
      （session 判定と対称・fail-closed）。正常 readable な台帳（orch=allow / 台帳外 None=allow /
      foreign=deny）の挙動は不変＝over-block ゼロ。`_ledger_dolt_database` 自体の str|None 契約も不変
      （本関数は書込先解決経路から外れただけ）。"""
    db = _resolve_ledger(cwd)
    return db if isinstance(db, str) else None


def _is_orch_session(cwd):
    """当該 session(cwd)が orchestrator session か。orch-5yl で **moat 厳格化**: self ledger が在るのに
    metadata を一過性に読めない/JSON 不正なだけで guard を無効化しない（fail-closed）。

      - 正常解決で dolt_database == SELF_PREFIX → True（従来通り・orchestrator session）。
      - present-but-unreadable（`.beads/metadata.json` は在るが読取/parse 失敗・区別ルール①）→ True
        （fail-closed＝moat 維持）。識別子を読めない以上 self ledger かもしれず、moat を瞬間的に開かない。
      - 正常解決で foreign（dolt_database が 'un'/'sc'/'ccs' 等）→ False（従来通り no-op）。
      - `.beads/metadata.json` が walk-up に皆無（他 project / git 外・区別ルール②）→ False（fail-open・
        従来通り no-op＝plugin global enable 時も他 project を一切壊さない・**②不変厳守**）。
      - 非 dict / dolt_database キー欠落（parse 成功だが識別不能）→ False（従来の fail-open を保つ）。
      - dolt_database が空文字列 '' → ''!=SELF_PREFIX ゆえ False（session 判定としては fail-open と同結果・
        pre-existing。書込先解決側だけは ''!=None で deny に倒れる非対称が残るが orch-5yl 無回帰）。

    例外で die しない契約は `_resolve_ledger` が内部で握り潰すことで担保（un-mbz・live 化前提）。"""
    db = _resolve_ledger(cwd)
    if db is _LEDGER_UNREADABLE:
        return True  # present-but-unreadable → self ledger とみなし fail-closed（区別ルール①）
    return db == SELF_PREFIX

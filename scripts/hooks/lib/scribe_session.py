#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 共有 lib: scribe session 判定 + 台帳 dolt_database 解決（session-start-guard-health.py の self-scope）。
#
# 由来: scriptorium scripts/hooks/lib/orch_session.py（orchestrator の同型機構＝SELF_PREFIX / walk-up 台帳
#   解決 / session 判定）を scribe 向けに port。**ただし用途が banner hook（write guard ではない）ゆえ
#   self-scope を positive-match に厳格化する**: dolt_database == "sc" と **確定**したときだけ self とみなし、
#   foreign（'orch'/'un'…）・台帳外・読取不能・判定不能はすべて False（無出力 no-op）に倒す。
#   理由（kickoff 死守＝誤注入ゼロ）: orch_session は guard（bd/file write の moat）と共用するため
#   present-but-unreadable を fail-closed＝self とみなして moat を維持するが、本 hook は **警告 banner を
#   stdout（context）へ注入するだけ**で、不確実なときに firing する必要はない。むしろ foreign session への
#   誤注入をゼロにする方が重要ゆえ、確定 self だけで firing する（過小発火＝安全側）。
#
# self-scope の理由（最重要）: 本 hook を plugin として global enable すると SessionStart は **全セッション**
#   で発火する。orchestrator の orch session も `.beads` を持つ（そこは orch-hos の guard-health が既に warn
#   する）ため、scribe の banner は dolt_database=='sc' に絞って二重発火/誤注入を防ぐ。これは role-inject の
#   `.beads` opt-in 判定（`.worktrees/` cwd 等）より厳密な、台帳 identity ベースの絞り込みである。
#
# 設計（依存ゼロ＝os/json のみ・subprocess 非依存で完全 hermetic）: filesystem の stat/read だけで判定し、
#   例外は内部で握り潰して決して伝播させない（hook が session/台帳 判定で die しない契約）。

import os
import json

# 自台帳 prefix（.beads/metadata.json dolt_database="sc" / scribe CLAUDE.md・metadata SSOT）。
SELF_PREFIX = "sc"


def _ledger_dolt_database(cwd):
    """cwd が属する bd 台帳の dolt_database を walk-up で解決し str|None を返す。
    cwd から上方向へ最初に見つかる `.beads/metadata.json` を読む（bd 自身の台帳解決と同じ walk-up・
    subprocess 非依存＝filesystem stat/read のみで hermetic）。次のいずれも None を返す（＝識別不能 →
    呼出側で no-op）: walk-up 上に metadata が皆無 / 読取・JSON parse 失敗 / 非 dict / dolt_database キー欠落。
    例外は内部で握り潰し決して伝播させない。"""
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
            return None  # presence 判定すら不能 → None（無出力 no-op）
        if present:
            try:
                with open(meta, "r", encoding="utf-8") as f:
                    data = json.load(f)
            except Exception:
                return None  # ファイルは在るが読取/parse 失敗 → 識別不能 → None（banner は無出力に倒す）
            return data.get("dolt_database") if isinstance(data, dict) else None
        prev, d = d, os.path.dirname(d)
    return None  # walk-up で `.beads/metadata.json` を発見せず（台帳外・他 project）


def _is_scribe_session(cwd):
    """当該 session(cwd)が scribe session か。**dolt_database == SELF_PREFIX("sc") と確定**したときだけ True。
    foreign（'orch'/'un' 等）・台帳外・読取不能・判定不能はすべて False（無出力 no-op＝誤注入ゼロ）。
    例外で die しない契約は `_ledger_dolt_database` が内部で握り潰すことで担保。"""
    return _ledger_dolt_database(cwd) == SELF_PREFIX

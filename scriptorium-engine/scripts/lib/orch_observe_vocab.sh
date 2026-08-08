#!/usr/bin/env bash
# orch_observe_vocab.sh — observe 層が「観測していない / 判定できない」を表すときの統一語彙の単一 SSOT（bd orch-ygbz C1）
#
# 役割 ─────────────────────────────────────────────────────────────────────────
#   orch-handoff-scan.sh（needs-orch 検知線）と orch-delivery-observe.sh（配送観測）は、どちらも
#   「観測していないこと」を「観測して不在」と潰す欠陥を持っていた（orch-ygbz A 群 / B 群）。修正後の
#   両 script は第 3 の状態＝**判定不能**を surface するが、読み手は同一の orchestrator であり、2 script で
#   語彙が割れると同じ状態を別物と誤読する。ゆえに当該語を **1 定数**に固定し両 script が consume する。
#
#   ORCH_OBSERVE_UNDECIDABLE — 「観測できていないので断定しない」状態を表す唯一の語。
#     適用対象（orch-ygbz notes fence ■7 の裁定）:
#       - B 群 cross-host: local tmux から宛先窓を観測できない / local 窓一覧に不在（観測射程外）。
#       - A 群 fail 経路 : 自台帳の全文走査が失敗・parse 不能で重複便の有無を決められない。
#     適用しないもの: 観測して確定した状態（A 群の triage-hold＝既存便を確認済み・[TRIAGE 保留]＝
#       needs-grill 併存を確認済み・[未確認]＝配送 3 値の unknown）。既存語は改名しない（pin 済み）。
#
# drift 検知 ────────────────────────────────────────────────────────────────────
#   本定数を書き換えると **両 script の正常経路 stdout が同時に変わる**ことを
#   tests/scenarios/orch-delivery-observe.bats の (vocab-drift) が pin する（片方の script が literal を
#   直書きしていると mutant 実行で旧値が残り RED＝両方向の drift teeth）。
#
# engine 同期の注意（boot-path）─────────────────────────────────────────────────
#   本 lib は boot-path keep-set の 2 script（orch-handoff-scan.sh / orch-delivery-observe.sh）が
#   **fail-closed で source** する。engine copy（~/.claude/plugins/scriptorium-engine）へ script だけを
#   同期して本 lib を運び忘れると、当該 2 節が「共有 lib 不在」で exit 1 する。同期は必ず lib 込みで行う。
#
# 検証: 本 file の `--self-test`（直接実行時のみ・hermetic・fail-closed）+ consumer の bats。

# 「観測できていないので断定しない」状態の統一語（両 script が printf の一部として consume する）。
ORCH_OBSERVE_UNDECIDABLE="判定不能"

# === --self-test: 直接実行時のみの hermetic 自己完結テスト（fail-closed・orch-ygbz C1） ===
# source 時（BASH_SOURCE[0] != $0）はこのブロックを skip する（consumer の $1 継承で誤発火しない）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" != "--self-test" ]; then
        echo "orch_observe_vocab.sh は source して使う共有 lib です（--self-test で自己検証）。" >&2
        exit 0
    fi
    st_fail=0
    if [ "$ORCH_OBSERVE_UNDECIDABLE" = "判定不能" ]; then
        echo "ok: 統一語彙が定義されている（ORCH_OBSERVE_UNDECIDABLE）"
    else
        echo "FAIL: ORCH_OBSERVE_UNDECIDABLE の値が想定外: [$ORCH_OBSERVE_UNDECIDABLE]" >&2; st_fail=1
    fi
    # 非空虚: 空文字/未定義だと consumer の printf が状態語を落として無言化する（fail-closed で弾く）。
    if [ -n "${ORCH_OBSERVE_UNDECIDABLE:-}" ]; then
        echo "ok: 非空（consumer の printf が状態語を落とさない）"
    else
        echo "FAIL: ORCH_OBSERVE_UNDECIDABLE が空" >&2; st_fail=1
    fi
    if [ "$st_fail" -eq 0 ]; then echo "orch_observe_vocab.sh --self-test: PASS"; exit 0
    else echo "orch_observe_vocab.sh --self-test: FAIL" >&2; exit 1; fi
fi

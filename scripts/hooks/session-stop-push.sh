#!/usr/bin/env bash
# session-stop-push.sh — universal sync Layer2 の **Stop hook 薄 wrapper**（sc-fz5i / orch-ptaq relay / orch-klca 論点5）
#
# 役割: admin（anchor）の Stop（毎 turn 末）で自台帳を throttle 付きで push するための **policy 前段**。
#   実体（throttle / write-signal / remote / bdw funnel push / marker stamp）は独立 script
#   `scripts/scribe-sync-push.sh` が持つ（seam ④＝Layer4 が同じ実体を呼べる）。本 wrapper は
#   ①stdin JSON 解釈 ②role gate（admin のみ）③自台帳 walk-up 解決 の policy だけを担い、
#   解決した ledger_root を実体 script へ渡す。
#
# ★Stop hook session-safety（最重要・SessionEnd と非対称）: Stop hook の **exit 2 = 会話を block して
#   admin turn を強制継続（無限 loop / brick）**。本 wrapper は全経路で明示 exit 0 し、実体 script の rc も
#   終了コードへ絶対に漏らさない（`|| true` + `exit 0`）。hooks.json 側も banner 系（`[ -x ]`+`|| true`）で wire
#   する（guard 系 `if...then...else exit0` は使わない＝exit2=block を伝播させないため）。
#
# 発火 role: **admin（anchor）のみ**（⑧ MACHINE 軸＝role 規律不変。worker/consult/none は no-op で
#   worker/consult の no-push を維持。role 判定は共有 lib mbx_role＝二重 SSOT を作らない）。
#   自台帳 == orch 台帳（orchestrator 自身）の skip（旧 rollout gate）は **解除済み**＝orch 台帳も
#   他台帳と同扱いで push する（解除条件 un-10h5 実層 Seq-2/5 GREEN 充足・orch-ueiv 第2段で実測。
#   orch-t4oo relay / sc-i4xc。旧裁定 = orch-klca 不変条件② + 論点8/10）。
#
# fail-safe: 全経路 exit 0 degrade（set -e は使わない）。lib 不在・台帳未解決・実体 script 不在でも
#   セッションを壊さない。

# --- 共有 lib（不在なら no-op degrade）---
_MBX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=lib/mailbox-common.sh
. "$_MBX_DIR/lib/mailbox-common.sh" 2>/dev/null || exit 0

# 実体 script（scripts/hooks/ の 1 つ上 = scripts/scribe-sync-push.sh）
SYNC_PUSH="$_MBX_DIR/../scribe-sync-push.sh"

# ============================ main ============================

mbx_read_stdin
hook_cwd="$(mbx_json_field cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"

# 1) role gate: admin（anchor）のみ（最初・最も安価な early return＝subprocess を払わない）
[ "$(mbx_role "$hook_cwd")" = "admin" ] || exit 0

# 2) 自台帳（.beads opt-in）を walk-up 1 回で解決。dolt_database の読取りと orch 比較は行わない
#    （旧 orch-skip の解除＝sc-i4xc。remote 未設定台帳の no-op は実体 script の remote gate が担う＝invariant⑦）。
ledger_root="$(mbx_resolve_ledger_root "$hook_cwd")" || exit 0
[ -n "$ledger_root" ] || exit 0

# 3) 実体（独立 script）へ委譲。rc は握りつぶし、常に exit 0（Stop hook brick 防止）。
[ -x "$SYNC_PUSH" ] && "$SYNC_PUSH" "$ledger_root" || true

exit 0

#!/usr/bin/env bash
# user-prompt-mailbox-scan.sh — 下り mailbox の **UserPromptSubmit 中間配送点**（sc-b6w / orch-0yof ①）
#
# 役割（裁定-delivery-guarantee② verbatim）: 「scribe へ UserPromptSubmit 中間配送点を courier 起票
#   （毎 prompt の軽量 mailbox チェック・dedupe＋open-only＋完全一致で noise 抑制・長時間対話 session の
#   滞留保険）」。SessionStart 配送点（session-start-mailbox-scan.sh）は **bundle 境界でしか発火しない**ため、
#   長寿命 admin session では下り便が最大で **セッション寿命ぶん滞留する**（実 incident: for:sc 4 本が
#   2 日滞留・orch-thgx 実測診断①「SessionStart のみ配送 × 長寿命 session」）。本 hook はその**滞留保険**で、
#   毎 user prompt で軽量に mailbox を覗き、**新着だけ**を surface する。
#
# 設計制約（裁定が規定した 3 点 + 軽量性）:
#   - **dedupe**: 既報 bead を再通知しない。SessionStart で surface 済みの bead も既報として扱う
#     （両配送点が session 単位の seen state を共有する・lib mbx_state_prefix）。
#   - **open-only** / **ラベル完全一致（`for:<self>`）**: direct read の条件は SessionStart と同一（共有 lib）。
#   - **軽量性**: bd direct read は **実測 0.74-0.89s**（embeddeddolt open 込み・ipatho-server-2 2026-07-13）で、
#     毎 prompt 同期実行すると user 体感を確実に損なう。ゆえに **TTL staleness-gate** を噛ませ、
#     最終 scan から `SCRIBE_MAILBOX_TTL_SEC`（既定 300 秒）未満の prompt では **bd を呼ばず即 exit 0**
#     （裁定「毎 prompt 発火ゆえ軽量性必須。実測し、重ければ staleness-gate/TTL で間引く設計も可」）。
#     TTL 内 skip の実コストは **実測 25-65ms/prompt**（hook プロセスの bash+jq 起動込み・機械負荷で変動。
#     hook 内部の判定自体は stat 1 回）——回避する bd direct read の **0.74-0.89s に対して約 1/10-1/30**。
#     滞留上限は TTL（=既定 5 分）に縮まり、2 日滞留は構造的に消える。
#     **scan stamp は read の成否に関わらず前進させる**（gate 通過直後に焼く）——read 成功時にだけ焼くと、
#     bd が degrade（dolt lock 競合・DB busy・hang → `timeout 5`）した間だけ gate が fail-open し、毎 prompt が
#     5s を再支払いする（＝最も重い失敗モードでだけ間引きが消える）。失敗も「見た」として TTL 分 backoff する。
#     急ぎ便は呼び鈴 push（裁定-delivery-guarantee①）が別経路で担うため TTL の粗さは許容される。
#
# 発火 role: **admin（anchor）のみ**（orch-0yof ①「role=admin(anchor) のみ発火・worker/consult では no-op」）。
#   worker は自 issue 契約に無関係な noise になり（毎 prompt ゆえ SessionStart より害が大きい）、consult は
#   read-only の議論役で mailbox triage の主体ではない（triage は admin の領分・protocol §8 受信優先順位）。
#   role 判定は共有 lib `mbx_role`（判定 SSOT = docs/role-context-spec.md §1 と同型）。
#
# ★hydrate 禁止（top-spec §5.3 会計②・orch-ufz）: 共有 lib の direct read（`bd -C <orch> list --readonly`）
#   しか呼ばない。`bd repo sync` / `repo add` は絶対に実行しない（orch 台帳は恒久 private・写しは git 漏洩経路）。
#
# 出力（UserPromptSubmit の stdout は **その turn の context に注入される**）: 新着があるときだけ、
#   最小の surface（header + 該当 bead 行 + triage 導線）。新着ゼロ・TTL 内・role 不一致・degrade は **無出力**。
#
# fail-safe: 全経路 **exit 0 degrade**（set -e は使わない）。UserPromptSubmit hook の exit 2 は
#   **user prompt そのものを block する**ため、本 hook は決して非 0 で終わらない（lib 不在・bd 不在・
#   read 失敗・JSON 壊れ・state 書込不能でも無出力 exit 0）。wire 側も `[ -x ]` + `|| true` で二重に守る。
#
# state 不在時の degrade（load-bearing）: session_id が取れない／state dir を作れないときは **no-op**。
#   state 無しでは dedupe も TTL も効かず、「毎 prompt 0.8s + 同じ bead を毎 prompt 再通知」という
#   二重事故（重い × spam）になるため、**配送より静粛を選ぶ**（SessionStart 配送点が backstop に残る）。

# --- 共有 lib（不在なら no-op degrade）---
_MBX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=lib/mailbox-common.sh
. "$_MBX_DIR/lib/mailbox-common.sh" 2>/dev/null || exit 0

# ============================ main ============================

mbx_read_stdin
hook_cwd="$(mbx_json_field cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
session_id="$(mbx_json_field session_id)"

# 発火は admin（anchor）のみ（worker / consult / none は no-op）
[ "$(mbx_role "$hook_cwd")" = "admin" ] || exit 0

# self 台帳 dolt_database（.beads opt-in ＋ self 特定）。解決不能 = 管轄外/識別不能 → no-op
self_db="$(mbx_resolve_self_db "$hook_cwd")" || exit 0
[ -n "$self_db" ] || exit 0

# dedupe/TTL state が持てないなら no-op（上記「state 不在時の degrade」）
[ -n "$session_id" ] || exit 0
prefix="$(mbx_state_prefix "$session_id" "$self_db")" || exit 0

# --- TTL staleness-gate（毎 prompt の重い direct read を間引く）---
ttl="${SCRIBE_MAILBOX_TTL_SEC:-300}"
mbx_within_ttl "${prefix}.scan" "$ttl" && exit 0

# orch anchor 解決（env > 既定・per-machine）。不在なら no-op
ORCH_ANCHOR="$(mbx_orch_anchor)" || exit 0

# 自台帳 == orch 台帳なら発信側自身 → skip（SessionStart 配送点と同一規則）
orch_db="$(mbx_read_dolt_db "$ORCH_ANCHOR/.beads/metadata.json" 2>/dev/null || true)"
[ -n "$orch_db" ] && [ "$orch_db" = "$self_db" ] && exit 0

# --- TTL stamp を **direct read の前** に前進させる（成否に関わらず「今 scan を試みた」を記録）---
# ★load-bearing（sc-b6w self-review [major]）: stamp を read 成功後にだけ焼くと、bd が degrade した状態
#   （orch 台帳の dolt lock 競合・embeddeddolt open 失敗・timeout=rc124 等）では stamp が永久に前進せず、
#   TTL gate が **最も重い失敗モードでだけ fail-open** する——毎 user prompt が `timeout 5` を再支払いし
#   backoff が一切効かない（実測: mock bd を hang させて 3 連続 prompt → 各 5.02s・stamp ゼロ）。
#   「毎 prompt 発火ゆえ軽量性必須」（裁定）は成功経路だけでなく失敗経路でも成立せねばならないため、
#   gate 通過直後に stamp を焼き、失敗時も次 TTL 窓まで静かにする（滞留上限は TTL のまま不変・
#   配送保証のバックストップは SessionStart 配送点が担う）。
mbx_touch_scan "${prefix}.scan"

# --- direct read（read-only・hydrate せず。毎 prompt 経路ゆえ timeout は短め）---
label="for:${self_db}"
raw="$(mbx_direct_read "$ORCH_ANCHOR" "$label" 5)" || exit 0

# 整形 → 既報を除いた **新着のみ**（通した id は seen へ記録される）
lines="$(printf '%s' "$raw" | mbx_emit)" || exit 0
[ -n "$lines" ] || exit 0
new="$(printf '%s\n' "$lines" | mbx_filter_unseen "${prefix}.seen")" || exit 0
[ -n "$new" ] || exit 0

echo "=== [scribe/UserPromptSubmit] 📬 下り mailbox 新着（scriptorium → ${self_db}・direct read / hydrate せず） ==="
echo ""
echo "\`${label}\` の open bead のうち、**本セッションで未報告のもの**です（既報は再通知しません・中間配送点 sc-b6w）。"
echo ""
echo "$new"
echo ""
echo "（詳細は \`bd -C \"${ORCH_ANCHOR}\" show <id> --readonly\`。**park-by-default**＝即実行せず自台帳 bead へ外部化し、現 atomic step 完了後に triage してください＝protocol §8 受信優先順位。hydrate 禁止＝\`bd repo sync\`/\`repo add\` を呼ばないこと・orch-ufz。）"

exit 0

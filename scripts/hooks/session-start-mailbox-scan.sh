#!/usr/bin/env bash
# session-start-mailbox-scan.sh — scriptorium 下り mailbox の direct read scan（sc-p2o / top-spec §5.3）
#
# 役割: SessionStart で scriptorium orch 台帳を **direct read** し、自 project 宛
#       （`for:<self>` 平ラベル・完全一致）の open bead を surface する（pull 型・下り知識中継）。
#       orchestrator 側の workinprogress hook（orch-7py）の**対向形**（発信は orch 自台帳 write /
#       受信は各 project 側 SessionStart の pull direct read）。正本 = scriptorium
#       docs/scriptorium-top-spec.md §5.3 の mailbox-routing sentinel 区間（会計②）。
#
# ★発見ロジックの実体は共有 lib `lib/mailbox-common.sh`（sc-b6w で抽出）: hook stdin JSON 解釈 /
#   self 台帳 walk-up / role 判定 / orch anchor 解決 / direct read / 整形 / dedupe state は**単一実装**で、
#   本 hook（SessionStart 配送点）と user-prompt-mailbox-scan.sh（UserPromptSubmit 中間配送点・sc-b6w）が
#   共有する（orch-0yof ①「既存 hook の発見ロジックを共通化して再利用＝二重実装しない」）。
#
# ★hydrate 禁止（top-spec §5.3 会計②・orch-ufz / orch-am1 論点10）:
#   `bd repo sync` / `bd repo add`（pull hydrate = 自 DB への写し取り込み）は**絶対に実行しない**。
#   orch 台帳は恒久 private（連携先 portfolio 名・infra 地形・cross-project 設計を**構造集約**）で、
#   public repo の `.beads` へ写しが入ると **git 経由で漏洩**する。direct read（`bd -C <orch-anchor>`）は
#   writable copy を作らない読み取りゆえ漏洩経路にならない（§3.1 architecture-hydrate の「原本は相手に
#   置いたまま read」と同型の read-only モート）。本 script が orch 台帳へ発行するのは
#   `bd -C <orch-anchor> list --readonly` の **read だけ**である（write サブコマンドを一切呼ばない）。
#   注: embeddeddolt backend は read でも orch 台帳自身の `.beads` 配下に LOCK を取得しうるが、これは
#   orch **private repo 内**の transient lockfile であって「自 public repo の .beads への写し」ではない
#   ＝hydrate（漏洩経路）とは別物。`bd -C` 直読は同一マシン foreign を race-free に読む正路（§2/§3 で既定）。
#
# per-machine 前提（top-spec §5.3 限界・未解決）:
#   direct read は**同一マシン前提**（現行 fleet 全同居で成立。cross-machine project が出たら別途設計）。
#   orch anchor path は per-machine 設定（runtime 解決の既存 helper 無し=orchestrator 確認済み）。
#   解決順:  env `SCRIBE_ORCH_ANCHOR` > 既知 path（lib の MBX_DEFAULT_ORCH_ANCHOR・本マシン=
#   /home/shuu5/projects/local-projects/scriptorium）。この既定は per-machine ゆえホスト間で不変ではない。
#
# opt-in / self-scope:
#   role-inject（session-start-role-inject.sh）と同じく **`.beads` opt-in** で scribe 管轄セッションに
#   限定する（.beads 無し = scribe 未使用 project ゆえ無出力 exit 0）。self = 自台帳 `dolt_database` 値
#   （既定 "sc"・.beads/metadata.json から walk-up 解決）で、`for:<self>` を**フル文字列完全一致**で scan する
#   （human-readable 変種 `for:scribe` 等は既定では拾わない＝self-contained・§5.1 整合）。
#   除外: ① SCRIBE_ROLE=none（既知 opt-out・orchestrator 等の別レイヤ）② worker セッション
#   （cwd が .worktrees/ ・.claude/worktrees/ 配下 or SCRIBE_ROLE=worker）——mailbox は project 単位の
#   coordination 知識で、受信点は bundle 境界 respawn の **admin/consult SessionStart**（orch-9dv・§5.3
#   Tier1）。ephemeral な実装 worker cell を毎 spawn 汎注すると contract に無関係な noise になるため surface
#   しない（role 判定は lib `mbx_role` が SSOT 同型）。③ 自台帳 == orch 台帳（self_db == orch anchor の
#   dolt_database）——orchestrator 自身は下り mailbox の**発信側**であって受信側でないため skip。
#
# dedupe seed（sc-b6w）: surface した bead id を **session 単位の seen state** へ記録する。これにより
#   UserPromptSubmit 中間配送点（user-prompt-mailbox-scan.sh）が「SessionStart で既に見せた bead」を
#   再通知しない（裁定-delivery-guarantee② の dedupe 要件）。state 書込に失敗しても surface は行う
#   （fail-safe: 配送 > 静粛）。
#
# fail-safe: 全経路 **exit 0 degrade**（set -e は使わない）。orch anchor 不在・bd 不在・read 失敗・
#            JSON parse 不能・自台帳識別不能・lib 不在でも**無出力**で正常終了しセッションを壊さない
#            （global hook ゆえ決して die しない＝role-inject / guard-health と同じ fail-safe ethos）。
#
# /scribe:setup（reconciler）への反映: **不要**。本 hook は scribe plugin の hooks/hooks.json に
#   （role-inject / guard-health と同列で）wire され、plugin global enable + 上記 .beads opt-in で
#   全 scribe 管轄 project へ自動到達する。

# --- 共有 lib（不在なら no-op degrade）---
_MBX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=lib/mailbox-common.sh
. "$_MBX_DIR/lib/mailbox-common.sh" 2>/dev/null || exit 0

# ============================ main ============================

# self-scope: SCRIBE_ROLE=none（既知 opt-out）は無出力 exit 0（role-inject と同型）
[ "${SCRIBE_ROLE:-}" = "none" ] && exit 0

mbx_read_stdin
hook_cwd="$(mbx_json_field cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
session_id="$(mbx_json_field session_id)"

# worker セッションは surface しない（mailbox 受信点は admin/consult SessionStart・上記ヘッダ参照）
case "$(mbx_role "$hook_cwd")" in
    worker|none) exit 0 ;;
esac

# self 台帳 dolt_database を解決（.beads opt-in ＋ self 特定を兼ねる）。解決不能 = 管轄外/識別不能 → no-op
self_db="$(mbx_resolve_self_db "$hook_cwd")" || exit 0
[ -n "$self_db" ] || exit 0

# 古い state の掃除は **surface の有無に依らず**ここで行う（sc-b6w self-review [minor]）。
# 下り便ゼロが常態の project では surface 経路に置くと prune が一度も走らず XDG state が永久に伸びるため、
# 「この session が scribe 管轄と判った時点」で回す（best-effort・find 不在でも no-op）。
mbx_prune_state 7

# orch anchor 解決（env > 既定・per-machine）。不在なら no-op
ORCH_ANCHOR="$(mbx_orch_anchor)" || exit 0

# 自台帳 == orch 台帳なら発信側（orchestrator 自身）＝受信 scan は無意味 → skip
orch_db="$(mbx_read_dolt_db "$ORCH_ANCHOR/.beads/metadata.json" 2>/dev/null || true)"
[ -n "$orch_db" ] && [ "$orch_db" = "$self_db" ] && exit 0

# --- direct read（read-only・hydrate せず）---
label="for:${self_db}"
raw="$(mbx_direct_read "$ORCH_ANCHOR" "$label" 8)" || exit 0

# read できた時点で TTL stamp を前進（**新着ゼロでも**）。UserPromptSubmit 中間配送点は直後の prompt で
# 同じ read を撃ち直さない（両配送点は同一 state を共有する・軽量性）。
prefix=""
if [ -n "$session_id" ]; then
    prefix="$(mbx_state_prefix "$session_id" "$self_db")" && mbx_touch_scan "${prefix}.scan"
fi

# 整形表示を組み立て（≥1 件のときだけ header + list を出す）
body="$(printf '%s' "$raw" | mbx_emit)" || exit 0
[ -n "$body" ] || exit 0

# dedupe seed（surface した id を既報として記録＝中間配送点が再通知しない・best-effort）
[ -n "$prefix" ] && printf '%s\n' "$body" | mbx_ids_from_lines | mbx_seed_seen "${prefix}.seen"

echo "=== [scribe/SessionStart] 📬 下り mailbox（scriptorium → ${self_db}・direct read / hydrate せず） ==="
echo ""
echo "scriptorium orchestrator が \`${label}\` で宛先付けした open な coord/knowledge bead です（pull 型・top-spec §5.3）。"
echo "read-only surface（自台帳へ hydrate していません）。内容を triage し、必要なら admin が対応してください（下り知識中継＝情報の受け取り。作業 dispatch・foreign spawn は人間 go・§5.3）。"
echo ""
echo "$body"
echo ""
echo "（詳細は \`bd -C \"${ORCH_ANCHOR}\" show <id> --readonly\` で読めます。orch 台帳は恒久 private ゆえ \`bd repo sync\`/\`repo add\` で hydrate しないこと＝git 経由の漏洩防止・orch-ufz。）"

exit 0

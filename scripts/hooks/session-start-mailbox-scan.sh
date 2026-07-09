#!/usr/bin/env bash
# session-start-mailbox-scan.sh — scriptorium 下り mailbox の direct read scan（sc-p2o / top-spec §5.3）
#
# 役割: SessionStart で scriptorium orch 台帳を **direct read** し、自 project 宛
#       （`for:<self>` 平ラベル・完全一致）の open bead を surface する（pull 型・下り知識中継）。
#       orchestrator 側の workinprogress hook（orch-7py）の**対向形**（発信は orch 自台帳 write /
#       受信は各 project 側 SessionStart の pull direct read）。正本 = scriptorium
#       docs/scriptorium-top-spec.md §5.3 の mailbox-routing sentinel 区間（会計②）。
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
#   解決順:  env `SCRIBE_ORCH_ANCHOR` > 既知 path（下記 DEFAULT_ORCH_ANCHOR・本マシン=
#   /home/shuu5/projects/local-projects/scriptorium）。この既定は per-machine ゆえホスト間で不変ではない。
#
# opt-in / self-scope:
#   role-inject（session-start-role-inject.sh）と同じく **`.beads` opt-in** で scribe 管轄セッションに
#   限定する（.beads 無し = scribe 未使用 project ゆえ無出力 exit 0）。self = 自台帳 `dolt_database` 値
#   （既定 "sc"・.beads/metadata.json から walk-up 解決）で、`for:<self>` を**フル文字列完全一致**で scan する
#   （human-readable 変種 `for:scribe` 等は既定では拾わない＝self-contained・§5.1 整合。将来 pin する場合は
#   self metadata と突合する・§5.3 限界）。
#   除外: ① SCRIBE_ROLE=none（既知 opt-out・orchestrator 等の別レイヤ）② worker セッション
#   （cwd が .worktrees/ ・.claude/worktrees/ 配下 or SCRIBE_ROLE=worker）——mailbox は project 単位の
#   coordination 知識で、受信点は bundle 境界 respawn の **admin/consult SessionStart**（orch-9dv・§5.3
#   Tier1）。ephemeral な実装 worker cell を毎 spawn 汎注すると contract に無関係な noise になるため surface
#   しない（worker 検出は role-inject が SSOT・本 script は同型の最小判定を複製する）。③ 自台帳 == orch 台帳
#   （self_db == orch anchor の dolt_database）——orchestrator 自身は下り mailbox の**発信側**であって受信側で
#   ないため、自台帳への `for:<self>` scan は無意味＝skip する。
#
# fail-safe: 全経路 **exit 0 degrade**（set -e は使わない）。orch anchor 不在・bd 不在・read 失敗・
#            JSON parse 不能・自台帳識別不能でも**無出力**で正常終了しセッションを壊さない（global hook ゆえ
#            決して die しない＝role-inject / guard-health と同じ fail-safe ethos）。警告は stderr のみ。
#
# /scribe:setup（reconciler）への反映: **不要**。本 hook は scribe plugin の hooks/hooks.json に
#   （role-inject / guard-health と同列で）wire され、plugin global enable + 上記 .beads opt-in で
#   全 scribe 管轄 project へ自動到達する。/scribe:setup は per-project の .beads bootstrap + PRIME.md +
#   project-local `bd prime` hook 除去のみを収束させ、plugin 側 hooks.json は管理しない（setup SKILL.md
#   「グローバル hook は machine 全体で有効・本 skill はプロジェクト側のみ収束」）。ゆえに配布は plugin 更新で足り
#   setup 変更は生じない（sc-p2o 実装時判断・top-spec §5.3 会計②「各 project 側 hook」= plugin が配る hook）。

# --- 既定 orch anchor（per-machine・env で上書き可）---
DEFAULT_ORCH_ANCHOR="/home/shuu5/projects/local-projects/scriptorium"

# --- stdin の hook JSON から cwd を抽出（jq → sed フォールバック）。tty なら読まない(block 回避) ---
# role-inject と同型（全 hook の stdin JSON 共通フィールド cwd）。抽出不能なら空 → $PWD へフォールバック。
_mbx_extract_cwd() {
    [ -t 0 ] && return 0
    local input cwd
    input="$(cat 2>/dev/null)"
    [ -z "$input" ] && return 0
    if command -v jq >/dev/null 2>&1; then
        cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
    else
        cwd="$(printf '%s' "$input" \
            | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n1)"
    fi
    [ -n "$cwd" ] && printf '%s' "$cwd"
    return 0
}

# --- .beads/metadata.json から dolt_database 値を読む（jq → sed フォールバック）---
_mbx_read_dolt_db() {
    local f="$1" v=""
    [ -f "$f" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        v="$(jq -r '.dolt_database // empty' "$f" 2>/dev/null)"
    else
        v="$(sed -n 's/.*"dolt_database"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n1)"
    fi
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# --- cwd から上方向へ最初に見つかる .beads/metadata.json の dolt_database を返す（bd と同じ walk-up）---
# scribe_session.py `_resolve_ledger` の bash 版（本 hook は bash ゆえ python 非依存で self を解決する）。
# metadata が present-but-unreadable なら 1 を返す（識別不能 → 呼出側で no-op・fail-safe 方向）。
_mbx_resolve_self_db() {
    local dir="$1" meta db
    [ -n "$dir" ] || return 1
    dir="$(cd "$dir" 2>/dev/null && pwd)" || return 1
    while [ -n "$dir" ]; do
        meta="$dir/.beads/metadata.json"
        if [ -f "$meta" ]; then
            db="$(_mbx_read_dolt_db "$meta")" && { printf '%s' "$db"; return 0; }
            return 1  # 発見したが読めない → 識別不能（no-op）
        fi
        [ "$dir" = "/" ] && break
        dir="$(dirname "$dir")"
    done
    return 1
}

# --- direct read の JSON を「非空なら整形表示・空/parse不能なら1」で emit（jq → python3）---
# stdin = bd --json 出力。0 を返したときだけ ≥1 件を print 済み。fail-safe（parse 不能は 1）。
_mbx_emit() {
    if command -v jq >/dev/null 2>&1; then
        jq -e -r '
            if (type=="array" and length>0)
            then (.[] | "  - \(.id) [P\(.priority)] \(.title)")
            else empty end
        ' 2>/dev/null
        return $?
    elif command -v python3 >/dev/null 2>&1; then
        # プログラムは -c で渡す（`python3 -` の heredoc だと stdin がプログラム本文に奪われ、
        # パイプで渡した bd --json が json.load(sys.stdin) に届かず常に JSONDecodeError→exit1 になる）。
        # -c ならプログラムは引数で渡り stdin はパイプのまま残るので json.load(sys.stdin) が $raw を読める。
        python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, list) or not d:
    sys.exit(1)
for b in d:
    print("  - %s [P%s] %s" % (b.get("id","?"), b.get("priority","?"), b.get("title","")))
sys.exit(0)
'
        return $?
    fi
    return 1  # jq も python3 も無い → surface を諦める（fail-safe・無出力）
}

# ============================ main ============================

# self-scope: SCRIBE_ROLE=none（既知 opt-out）は無出力 exit 0（role-inject と同型）
[ "${SCRIBE_ROLE:-}" = "none" ] && exit 0

hook_cwd="$(_mbx_extract_cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"

# worker セッションは surface しない（mailbox 受信点は admin/consult SessionStart・上記ヘッダ参照）
case "${SCRIBE_ROLE:-}" in
    worker) exit 0 ;;
esac
case "$hook_cwd" in
    */.worktrees/*|*/.claude/worktrees/*) exit 0 ;;
esac

# self 台帳 dolt_database を解決（.beads opt-in ＋ self 特定を兼ねる）。解決不能 = scribe 管轄外/識別不能 → no-op
self_db="$(_mbx_resolve_self_db "$hook_cwd")" || exit 0
[ -n "$self_db" ] || exit 0

# orch anchor 解決（env > 既定・per-machine）。不在なら no-op
ORCH_ANCHOR="${SCRIBE_ORCH_ANCHOR:-$DEFAULT_ORCH_ANCHOR}"
[ -d "$ORCH_ANCHOR/.beads" ] || exit 0

# 自台帳 == orch 台帳なら発信側（orchestrator 自身）＝受信 scan は無意味 → skip
orch_db="$(_mbx_read_dolt_db "$ORCH_ANCHOR/.beads/metadata.json" 2>/dev/null || true)"
[ -n "$orch_db" ] && [ "$orch_db" = "$self_db" ] && exit 0

# bd 不在なら no-op
command -v bd >/dev/null 2>&1 || exit 0

# --- direct read（read-only・hydrate せず）。timeout があれば被せて SessionStart を長引かせない ---
# --limit 0 = 全件（bd 既定の --limit 50 は mailbox を黙って上限打ち切りする＝silent cap 回避・sc-p2o minor）。
label="for:${self_db}"
if command -v timeout >/dev/null 2>&1; then
    raw="$(timeout 8 bd -C "$ORCH_ANCHOR" list --label "$label" --status open --limit 0 --readonly --json 2>/dev/null)"
    rc=$?
else
    raw="$(bd -C "$ORCH_ANCHOR" list --label "$label" --status open --limit 0 --readonly --json 2>/dev/null)"
    rc=$?
fi
# bd がエラー（read 失敗・timeout 等）→ degrade（無出力 exit 0）。fail-safe。
[ "$rc" -eq 0 ] || exit 0
[ -n "$raw" ] || exit 0

# 整形表示を組み立て（≥1 件のときだけ header + list を出す）
body="$(printf '%s' "$raw" | _mbx_emit)" || exit 0
[ -n "$body" ] || exit 0

echo "=== [scribe/SessionStart] 📬 下り mailbox（scriptorium → ${self_db}・direct read / hydrate せず） ==="
echo ""
echo "scriptorium orchestrator が \`${label}\` で宛先付けした open な coord/knowledge bead です（pull 型・top-spec §5.3）。"
echo "read-only surface（自台帳へ hydrate していません）。内容を triage し、必要なら admin が対応してください（下り知識中継＝情報の受け取り。作業 dispatch・foreign spawn は人間 go・§5.3）。"
echo ""
echo "$body"
echo ""
echo "（詳細は \`bd -C \"${ORCH_ANCHOR}\" show <id> --readonly\` で読めます。orch 台帳は恒久 private ゆえ \`bd repo sync\`/\`repo add\` で hydrate しないこと＝git 経由の漏洩防止・orch-ufz。）"

exit 0

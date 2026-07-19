#!/usr/bin/env bash
# orch-architecture-hydrate.sh — architecture-hydrate channel（folio inventory read-channel・orch-2ax / C1）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   §27 orchestrator read-up の新規経路。既存=bd-ledger pull hydrate（orch-hydrate.sh・top-spec §3）
#   とは別に、各 project の folio `inventory.json` を **read-only で読み**、横断統合（名前空間付与・
#   (project-id, sha, @id) 三つ組グローバルキー・重複解決・relations graph merge）した
#   「揮発 on-demand assembly」を stdout へ出す（中央に統合 architecture を**永続化しない**）。
#   横断統合本体は scripts/lib/orch_architecture_merge.py（B2＝scriptorium 自前責務）。
#
# read-only 担保（最強モート・契約 NOTES B1-L1）─────────────────────────────────────
#   inventory は merge engine が `open(path)` で読むだけ。**writable foreign copy を一切作らない**
#   （cp / sed -i / 書き戻し無し・本 channel に foreign への write 経路は無い）。出力は派生 assembly。
#
# graceful skip（契約 acceptance）─────────────────────────────────────────────────
#   path 不在 / `.beads` ならぬ inventory 不在 / 破損 JSON は per-source error として記録し skip
#   （orch-hydrate.sh の no-.beads skip と同型）。folio は現状 inventory.json を未出力ゆえ、初期状態は
#   **全 project で inventory 不在 skip** になるのが正常（contract NOTES の前提）。
#
# project list SSOT 一本化（契約 acceptance・二重 SSOT 回避）────────────────────────
#   project root list は orch-hydrate.sh と同一解決（env seam ORCH_ARCH_PROJECTS >
#   private 配備層 registry overlay [scripts/lib/orch-projects.sh・配備層が配置した場合のみ] > fail-loud）。
#   engine tree は registry（実名 list）を同梱しない（mechanism=public / value=private の分離）。
#   inventory の相対位置だけ別 knob
#   （INVENTORY_RELPATH・folio rollout の path 規約が確定するまでの防御的設計）。
#
# orchestrator session 前提（誤台帳 read の防止・read だが self-scope は保つ）──────────
#   orch-hydrate / guard / spec-inject と同一機構で「cwd から walk-up した最初の .beads/metadata.json
#   の dolt_database が orch か」を検査し、非該当なら何もせず非 0 で抜ける（self-scope 一貫性）。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）  各 project の inventory を解決→存在するもののみ merge engine に渡し assembly を stdout。
#   --list    解決した (project, inventory-path, 存在/不在) を print のみ（merge しない・診断用）。
#   --help    使い方。
#
# env override（主に self-test 用）:
#   ORCH_ARCH_PROJECTS    project list を全置換（空白区切り `name=path` 列・path に空白不可）。
#                         未指定なら private 配備層 registry overlay（無ければ fail-loud）。
#   INVENTORY_RELPATH     project root からの inventory 相対パス（既定: inventory.json）。
#   ORCH_ARCH_MERGE_PY    merge engine の実体パス（既定: 本スクリプトと同 dir の lib/orch_architecture_merge.py）。
#   ORCH_ARCH_SKIP_SESSION_GATE=1  session self-scope gate を skip（hermetic self-test 用）。
#
# 検証: selftest-orch-2ax.local.sh（worktree 直下・untracked・fail-closed・hermetic 合成 fixture）。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard と同一値を共有）。
SELF_PREFIX="orch"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・orch-vo2 で 5 script も統一） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。旧 inline _resolve_dolt_database は
# _json_is_valid gate を欠く drift（破損 orch-token metadata で誤 self-scope＝誤台帳起動しうる）だったため
# 撤去し、gate 済みの共有関数へ統一する（orch-vo2 acceptance・orch-degraded-watch と同型）。self-scope gate は
# fail-closed 方針ゆえ、gate 追加で破損 orch-token metadata は self とみなされず refuse 側へ倒れる（安全側）。
# ★実 script 位置（BASH_SOURCE 相対）で解決するので bats/--self-test が実 lib を確実に見つける。
_ORCH_SESSION_LIB="$SCRIPT_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-architecture-hydrate: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
MODE="merge"
for arg in "$@"; do
    case "$arg" in
        --list) MODE="list" ;;
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "orch-architecture-hydrate: unknown arg: $arg（--list / --help のみ）" >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# ヘルパ（orch-hydrate.sh と同型・self-scope 一貫性）
# ─────────────────────────────────────────────────────────────────────────────
_strip_trailing_slash() {
    local p="$1"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    printf '%s' "$p"
}

# cwd の台帳 dolt_database の walk-up 解決（_ledger_dolt_database）は共有 lib scripts/hooks/lib/orch_session.sh
# が提供する（上で source 済み・orch-vo2）。旧 inline _resolve_dolt_database は _json_is_valid gate を欠く
# drift だったため撤去し、gate 済みの _ledger_dolt_database へ統一した（破損 orch-token metadata での誤
# self-scope を fail-closed で弾く・orch-degraded-watch と同型）。

# ─────────────────────────────────────────────────────────────────────────────
# 前提検査: orchestrator session（cwd の台帳 dolt_database == orch）でなければ何もしない
#   read 操作だが self-scope を保つ（誤台帳起動を fail-closed で弾く・guard と一貫）。
# ─────────────────────────────────────────────────────────────────────────────
if [ "${ORCH_ARCH_SKIP_SESSION_GATE:-}" != "1" ]; then
    DB="$(_ledger_dolt_database "$PWD")"
    if [ "$DB" != "$SELF_PREFIX" ]; then
        echo "orch-architecture-hydrate: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
        echo "  orchestrator session（cwd=orchestrator）から実行せよ。self-scope の fail-closed。" >&2
        exit 1
    fi
fi

# merge engine 実体パス。
MERGE_PY="${ORCH_ARCH_MERGE_PY:-$LIB_DIR/orch_architecture_merge.py}"
if [ "$MODE" = "merge" ] && [ ! -f "$MERGE_PY" ]; then
    echo "orch-architecture-hydrate: merge engine not found: $MERGE_PY（ORCH_ARCH_MERGE_PY で差替可）" >&2
    exit 1
fi
if [ "$MODE" = "merge" ] && ! command -v python3 >/dev/null 2>&1; then
    echo "orch-architecture-hydrate: python3 が必要（横断統合 engine の実行に）" >&2
    exit 1
fi

# inventory 相対パス（folio rollout の path 規約確定までの単一 knob）。
INVENTORY_RELPATH="${INVENTORY_RELPATH:-inventory.json}"

# project list 解決（env override 優先・空白区切り name=path）。未指定なら共有 lib の DEFAULT_PROJECTS。
PROJECTS=()
if [ -n "${ORCH_ARCH_PROJECTS:-}" ]; then
    read -ra PROJECTS <<< "$ORCH_ARCH_PROJECTS"
else
    # private 配備層 registry overlay（engine は値の hardcode を持たない・不在/空は fail-loud）。
    DEFAULT_PROJECTS=()
    if [ -f "$LIB_DIR/orch-projects.sh" ]; then
        # shellcheck source=lib/orch-projects.sh
        # shellcheck disable=SC1091
        source "$LIB_DIR/orch-projects.sh"
    fi
    if [ "${#DEFAULT_PROJECTS[@]}" -eq 0 ]; then
        echo "orch-architecture-hydrate: project list 未供給（fail-loud）: env ORCH_ARCH_PROJECTS を設定するか、" >&2
        echo "  private 配備層 registry を $LIB_DIR/orch-projects.sh へ配置すること（engine は値の hardcode を持たない）。" >&2
        exit 1
    fi
    PROJECTS=("${DEFAULT_PROJECTS[@]}")
fi

# ─────────────────────────────────────────────────────────────────────────────
# 各 project の inventory path を解決（存在するもののみ merge engine の --source に積む）。
# ─────────────────────────────────────────────────────────────────────────────
SOURCE_ARGS=()
present=0; absent=0
for entry in "${PROJECTS[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    if [ -z "$name" ] || [ -z "$path" ] || [ "$name" = "$entry" ]; then
        [ "$MODE" = "list" ] && echo "SKIP (malformed entry): '$entry'"
        continue
    fi
    path="$(_strip_trailing_slash "$path")"
    inv="$path/$INVENTORY_RELPATH"

    if [ -f "$inv" ]; then
        present=$((present + 1))
        SOURCE_ARGS+=(--source "$name=$inv")
        [ "$MODE" = "list" ] && echo "PRESENT: $name -> $inv"
    else
        # graceful skip（inventory 不在＝orch-hydrate の no-.beads skip と同型）。
        absent=$((absent + 1))
        [ "$MODE" = "list" ] && echo "SKIP (inventory absent): $name -> $inv"
    fi
done

if [ "$MODE" = "list" ]; then
    echo "----------------------------------------------------------------------"
    echo "summary: projects=${#PROJECTS[@]} present=$present absent(skip)=$absent relpath=$INVENTORY_RELPATH"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 横断統合: present な inventory を merge engine に渡し、揮発 assembly を stdout へ。
#   present=0 でも engine は空 assembly（全 source skip）を出す＝graceful（初期状態の正常形）。
# ─────────────────────────────────────────────────────────────────────────────
exec python3 "$MERGE_PY" "${SOURCE_ARGS[@]}"

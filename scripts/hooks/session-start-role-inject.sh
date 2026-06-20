#!/usr/bin/env bash
# session-start-role-inject.sh — scribe SessionStart role 別文脈注入（bd un-ck2 / v0-C2）
#
# 役割: SessionStart で role(admin/worker/consult)を実行時 guard で判定し、role 別の
#       規約文脈を stdout へ注入する。SessionStart hook は stdout を session の context へ
#       注入する仕様（Claude Code）に従うため、ここでは plain stdout に出力する。
#
# opt-in ガード（docs/role-context-spec.md §1.0・bd un-7hx）:
#   本 script はグローバル hook として**ホストの全 SessionStart で発火**する。scribe を
#   使わないプロジェクト（paper 等）へ規約を注入しないよう、cwd（または git toplevel）に
#   `.beads/` が存在するときだけ注入する。`.beads` = scribe opt-in の代理マーカー（beads は
#   scribe の前提 substrate ゆえ「.beads あり ⇔ scribe 管轄」が一致する）。無ければ role
#   判定すら行わず無出力で exit 0（現行 fail-safe を維持）。
#
# role 判定（docs/role-context-spec.md §1 と整合・優先順は上から最初に当たったもの）:
#   1. env SCRIBE_ROLE が認識可能な role(admin|worker|consult) → それを採用
#      （一次は consult の明示焼き込み=C3 ヘルパーが --env-file で行う。worker の
#        admin/consult 上書きが必要なら env で明示できる設計でよい・spec §1 注記）
#   2. cwd が .worktrees/ 配下 → worker（worktree = worker の構造的マーカー）
#   3. 既定（上記いずれにも当たらない・anchor 無印） → admin
#   ※ SCRIBE_ROLE=none は既知の opt-out: role 注入を抑止し無出力 exit 0（degrade せず warning も出さない）。
#     別レイヤ(自前 .beads の orchestrator 等)が scribe role 注入を受けないための明示シグナル（spec §1.1）
#   ※ window 名は判定に使わない（表示規約のみ・spec §1）
#
# 注入内容の SSOT（本文を script に二重化しない・spec §3。script は「どの file/節を
#                  出すか」だけを持ち、本文は doc から cat する）:
#   admin   = docs/protocol.md 全文（graph 所有・gate funnel・errata 規約・dolt push 同期点）
#   worker  = docs/protocol.md §2(worker prompt 規約)+§3(B/hybrid 役割境界)+§4(close→gate→errata)
#   consult = docs/role-context-spec.md §2.3（read-only・記憶系のみ write・サマリ保存義務・暫定運用）
#             ※ consult の規約 SSOT は protocol.md ではなく role-context-spec.md §2.3 にインライン
#               移設済み（un-tao テンプレ移設版）。
#
# fail-safe: 判定不能・doc 不在・本文抽出器(awk)不在でもセッションを壊さない。set -e は使わず
#            常に exit 0(degrade)、警告は stderr。これは「全セッション破壊の防止」の核心。
#            awk 不在時(worker/consult)は header のみのサイレント部分注入を避け、明示 warning を
#            出して何も注入しない(admin は cat 経路で awk 非依存=無傷)。

# --- plugin root / doc パス解決（CLAUDE_PLUGIN_ROOT 優先・無ければ script 位置から導出） ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    # scripts/hooks/ の 2 つ上 = plugin root
    PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
PROTOCOL_DOC="$PLUGIN_ROOT/docs/protocol.md"
SPEC_DOC="$PLUGIN_ROOT/docs/role-context-spec.md"

# --- stdin の hook JSON から cwd を抽出（jq → sed フォールバック）。tty なら読まない(block 回避) ---
# 全 hook の stdin JSON 共通フィールドに cwd が含まれる（session_id/transcript_path/cwd/...）。
# 抽出不能なら無出力 → 呼び出し側で $PWD へフォールバック。
_scribe_extract_cwd() {
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

# --- protocol.md の top-level セクション(## N.)を抽出（want = 空白区切りの番号列・portable awk） ---
_scribe_emit_protocol_sections() {
    local file="$1" want="$2"
    awk -v want="$want" '
        BEGIN { k=split(want, a, " "); for (i=1;i<=k;i++) wanted[a[i]]=1; inseg=0 }
        /^## / {
            inseg=0
            hdr=$0; sub(/^## /,"",hdr); num=hdr; sub(/[^0-9].*/,"",num)
            if (num != "" && (num in wanted)) inseg=1
        }
        inseg { print }
    ' "$file"
}

# --- role-context-spec.md の §2.3 サブセクションを抽出（### 2.3 〜 次の --- 直前） ---
_scribe_emit_consult_section() {
    local file="$1"
    awk '
        /^### 2\.3/ { inseg=1 }
        inseg && /^---[[:space:]]*$/ { inseg=0 }
        inseg { print }
    ' "$file"
}

# --- .beads opt-in マーカー検出（cwd 直下 → git toplevel フォールバック・bd un-7hx） ---
# scribe は beads を前提 substrate とするため、.beads/ の存在を「この cwd は scribe 管轄」
# の opt-in 代理判定に使う。cwd 直下に無くても、cwd が repo のサブディレクトリなら
# git toplevel に .beads/ がありうるためフォールバック確認する（git 不在/非 repo は無害に
# 失敗し false を返す＝fail-safe）。実体は anchor/worktree とも .beads ディレクトリ。
# 堅牢化（gate self-check・bd un-7hx）: 本 script はホスト全 SessionStart で発火するため、
# 親プロセスが GIT_DIR/GIT_WORK_TREE を export していると `rev-parse --show-toplevel` が
# 継承 env に従って無関係 repo の toplevel を解決し**過剰注入**しうる（実測再現・過剰注入は
# 本ガードの設計目的に反する UNSAFE 方向）。toplevel 解決を継承 git env から隔離する。
_scribe_has_beads() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    [ -d "$dir/.beads" ] && return 0
    local top
    top="$(cd "$dir" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$top" ] && [ -d "$top/.beads" ] && return 0
    return 1
}

# === role 判定 ===
hook_cwd="$(_scribe_extract_cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"

# === .beads opt-in guard（scribe 管轄外セッションには何も注入しない・bd un-7hx） ===
# cwd（または git toplevel）に .beads/ が無ければ scribe を使っていないプロジェクトと
# みなし、role 判定すら行わず無出力で exit 0 する。これがグローバル hook の規約注入を
# scribe opt-in したプロジェクトに限定し、無関係セッション（paper 等）への漏洩を塞ぐ。
# 注入漏れ防止が目的ゆえ stderr 警告も出さない（無関係セッションを汚さない）。
if ! _scribe_has_beads "$hook_cwd"; then
    exit 0
fi

role=""
detect_basis=""
case "${SCRIBE_ROLE:-}" in
    admin|worker|consult)
        role="$SCRIBE_ROLE"; detect_basis="env SCRIBE_ROLE" ;;
    "")
        : ;;  # 未設定 → cwd/既定判定へ
    none)
        # 既知の opt-out 値: 別レイヤ(自前 .beads を持つ orchestrator 等)が「どの scribe role 注入も
        # 受けない」を機械保証するための明示シグナル。未知値(*)と異なり degrade(cwd/既定 admin 注入)
        # せず、warning も出さず無出力で exit 0 する(意図的 opt-out ゆえ正常終了)。.beads opt-in ガードを
        # 通過済でも role 注入を抑止する(bfe0ce39 / decision 115521de: advisory な隔離・実隔離は別途 guard)。
        exit 0 ;;
    *)
        echo "[scribe/SessionStart] warning: 未知の SCRIBE_ROLE='${SCRIBE_ROLE}' を無視し cwd/既定判定へ degrade" >&2 ;;
esac

if [ -z "$role" ]; then
    case "$hook_cwd" in
        */.worktrees/*) role="worker"; detect_basis="cwd .worktrees/" ;;
        *)              role="admin";  detect_basis="既定(anchor 無印)" ;;
    esac
fi

# === role 別 注入 ===
_scribe_header() {
    echo "=== [scribe/SessionStart] role=$role (判定: $detect_basis) ==="
    echo ""
}

case "$role" in
    admin)
        if [ ! -r "$PROTOCOL_DOC" ]; then
            echo "[scribe/SessionStart] warning: protocol.md 不在($PROTOCOL_DOC)・admin 文脈注入を skip(degrade)" >&2
            exit 0
        fi
        _scribe_header
        echo "あなたは scribe admin(anchor / orchestrator セッション)です。graph の所有者・gate funnel の実行者・唯一の bd dolt push 同期点です。以下のプロトコル全文が役割規約の SSOT です。"
        echo ""
        cat "$PROTOCOL_DOC"
        ;;
    worker)
        if [ ! -r "$PROTOCOL_DOC" ]; then
            echo "[scribe/SessionStart] warning: protocol.md 不在($PROTOCOL_DOC)・worker 文脈注入を skip(degrade)" >&2
            exit 0
        fi
        # 本文抽出は awk 単一依存(フォールバック非実装はスコープ判断)。awk 不在ホストでは
        # 「header のみ・規約本文ゼロ」のサイレント部分注入を避け、明示 warning を出して degrade する。
        if ! command -v awk >/dev/null 2>&1; then
            echo "[scribe/SessionStart] warning: awk not found — worker 規約本文(protocol.md §2-4)を注入できません。SSOT: docs/protocol.md §2-4 を手動参照" >&2
            exit 0
        fi
        _scribe_header
        echo "あなたは scribe worker(worktree セッション)です。自 issue の write だけを行い graph は触りません(B/hybrid)。bd create / bd dep / bd dolt push は禁止、follow-up は notes で提案します。以下は protocol.md の worker 関連節(§2 prompt 規約 / §3 役割境界 / §4 close→gate→errata)です。"
        echo ""
        _scribe_emit_protocol_sections "$PROTOCOL_DOC" "2 3 4"
        ;;
    consult)
        if [ ! -r "$SPEC_DOC" ]; then
            echo "[scribe/SessionStart] warning: role-context-spec.md 不在($SPEC_DOC)・consult 文脈注入を skip(degrade)" >&2
            exit 0
        fi
        # 本文抽出は awk 単一依存。awk 不在ホストではサイレント部分注入を避け明示 warning で degrade。
        if ! command -v awk >/dev/null 2>&1; then
            echo "[scribe/SessionStart] warning: awk not found — consult 規約本文(role-context-spec.md §2.3)を注入できません。SSOT: docs/role-context-spec.md §2.3 を手動参照" >&2
            exit 0
        fi
        _scribe_header
        echo "あなたは scribe consult(設計議論・grill 専用の read-only セッション)です。オーケストレーション・gate 代行・実装はしません。write してよいのは記憶系(doobidoo / auto-memory)のみで、終了前のサマリ保存が義務です。以下が役割規約(role-context-spec.md §2.3)です。"
        echo ""
        _scribe_emit_consult_section "$SPEC_DOC"
        ;;
    *)
        # 到達不能（role は必ず上で確定する）。万一の保険として degrade。
        echo "[scribe/SessionStart] warning: role 判定不能・文脈注入を skip(degrade)" >&2
        exit 0
        ;;
esac

exit 0

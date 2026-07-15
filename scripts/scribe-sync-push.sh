#!/usr/bin/env bash
# scribe-sync-push.sh — universal sync Layer2 の **実体（独立 script・seam ④）**
#
# 役割（orch-klca 論点5 / orch-ptaq relay / sc-fz5i）: 与えられた台帳 root に対し
#   「書き込み有時のみ + 最短間隔 N 分」throttle で **bdw funnel 経由の bd dolt push** を 1 回発火する。
#   Stop hook（session-stop-push.sh）が本 script の唯一の現行呼び手だが、role/orch-skip といった
#   **policy は呼び手が担い**、本 script は throttle / write-signal / remote 検出 / push / marker stamp の
#   **機構（mechanism）だけ**を持つ独立入口＝Layer4（将来の統一入口）が同じ実体を呼べる seam（orch-klca ④）。
#
# 呼び出し: scribe-sync-push.sh <ledger_root>
#   <ledger_root> = `.beads/` を持つ台帳ディレクトリ（絶対パス推奨）。呼び手が walk-up 解決済で渡す。
#
# 契約不変条件（sc-fz5i scope-fence）:
#   • **全経路 exit 0**（Stop hook から呼ばれる＝非0 を漏らすと会話 block／admin loop。push subprocess の
#     rc を終了コードへ絶対に漏らさない。失敗は stderr の warn のみ・stdout は常に無出力）。
#   • **throttle**: marker.mtime から N 分未満なら stat だけで即 return（bd/bdw subprocess を起動しない）。
#     marker 不在／mtime 取得不能は「窓外（push 候補）」側へ倒す（false-negative 防止・恒常 no-op を作らない）。
#   • **write-signal は read で bump されない痕跡のみ**: `.beads/last-touched` は bd の READ でも bump するため
#     使わない。**write-only 痕跡** = auto-export mirror `.beads/issues.jsonl`（主）+ `.beads/embeddeddolt`
#     の更新痕跡（副・BDW_NO_AUTOEXPORT=1 で mirror 凍結時のフォールバック）。いずれも marker.mtime より
#     新しければ「書込あり」。marker 不在は「書込あり」側へ倒す。
#   • **push は必ず bdw funnel 経由**（`scripts/bdw dolt push`＝flock 直列化）。bare `bd dolt push` を叩かない
#     （invariant③・runtime guard backstop 無し＝ここが唯一の enforcement）。
#   • **remote 未設定は silent no-op**（warn を出さない・invariant⑦）。push 前に remote 有無を 1 回だけ確認し
#     無ければ静かに return。remote 確認 subprocess は throttle/write-signal gate を通過した後段でのみ払う（hot path 保護）。
#   • **marker stamp discipline**: marker（最終 push 時刻）は **実 push 成功経路でのみ** atomic rename で前進させる。
#     bdw dolt push 成功は auto-export（issues.jsonl bump）を伴うため、marker は push 復帰後に stamp し
#     marker.mtime >= issues.jsonl.mtime を保証（自己 bump loop を塞ぐ）。push 失敗時は marker を前進させない
#     （次回 Stop が窓を跨いだ時点で再試行＝後続回収・write を落とさない）。
#
# marker 名（env 上書き可＝テスト seam。値は bats で pin せず設定点として持つ）:
#   `<ledger>/.beads/scribe-push-throttle` — .beads/last-sync / .beads/scribe-heartbeat / bd-native runtime
#   （last-touched / push-state.json / sync-state.json / export-state.json / .local_version）と字面 disjoint。
#
# 既知の限界（scope-fence）: 閉場時（session 終了）の未 push write は、次 session の Stop が throttle 窓を
#   跨ぐまで滞留しうる。SessionEnd heartbeat は stamp のみで push しない（配送観測用の backstop であって
#   閉場時 push ではない）。閉場時 push は un-10h5（Layer1・non-blocking）の領分＝本 script の scope 外。

# fail-safe: set -e は張らない（全経路 exit 0 degrade）。
set -uo pipefail 2>/dev/null || true

# --- 設定（env 上書き可＝テスト seam）---
THROTTLE_MIN="${SCRIBE_PUSH_THROTTLE_MIN:-10}"                       # 閾値 N 分（既定 10・値は非 pin）
MARKER_FILENAME="${SCRIBE_PUSH_THROTTLE_FILENAME:-scribe-push-throttle}"
PUSH_TIMEOUT="${SCRIBE_PUSH_TIMEOUT:-20}"                            # push subprocess の上限秒（hook 外枠 30s の手前。gate live 実射で典型 2.85s・cold 時 >8s を実測＝8 は変動幅に薄い・sc-fz5i gate）
REMOTE_TIMEOUT="${SCRIBE_PUSH_REMOTE_TIMEOUT:-5}"                    # remote 確認 subprocess の上限秒

# --- helpers ---------------------------------------------------------------

# ファイル/ディレクトリの mtime（epoch 秒）。取得不能なら 1。GNU stat → BSD stat → date -r。
# 注: 共有 lib の mbx_mtime_epoch は file 専用（[ -f ]）ゆえ embeddeddolt（dir）に使えない。
#     本 helper は file/dir 両対応（[ -e ]）＝lib を変更せず自足する（append-only 規律）。
_sp_path_mtime() {
    local p="$1" v=""
    [ -e "$p" ] || return 1
    v="$(stat -c %Y "$p" 2>/dev/null)" || v=""
    [ -z "$v" ] && v="$(stat -f %m "$p" 2>/dev/null)" || true
    [ -z "$v" ] && v="$(date -r "$p" +%s 2>/dev/null)" || true
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
    return 1
}

# throttle gate: marker.mtime から N 分未満なら 0（＝窓内 → skip）。窓経過 or marker 不在なら 1（＝push 候補）。
_sp_within_throttle() {
    local marker="$1" min="$2" last now
    [ "$min" -gt 0 ] 2>/dev/null || return 1        # N<=0 / 非数値 → throttle 無効（毎回 push 候補・テスト seam）
    last="$(_sp_path_mtime "$marker")" || return 1  # marker 不在/取得不能 → 窓外（push 候補側へ倒す）
    now="$(date +%s 2>/dev/null)" || return 1
    [ $((now - last)) -lt $((min * 60)) ] && return 0
    return 1
}

# write-signal gate: 前回 push（marker.mtime）以降に write があれば 0（＝push 候補）。無ければ 1（＝skip）。
# read で bump される .beads/last-touched は **使わない**（write-only 痕跡のみ）。
_sp_has_write_since() {
    local marker="$1" beads_dir="$2" mmark mw
    mmark="$(_sp_path_mtime "$marker")" || return 0     # marker 不在 → 書込あり扱い（false-negative 防止）
    # (1) 主 signal: auto-export mirror（cheap stat・短絡）。marker より新しければ書込あり。
    mw="$(_sp_path_mtime "$beads_dir/issues.jsonl")" && [ "$mw" -gt "$mmark" ] && return 0
    # (2) 副 signal: embeddeddolt（BDW_NO_AUTOEXPORT=1 で mirror 凍結時のフォールバック）。
    #     marker より新しいエントリが 1 つでもあれば書込あり（find -newer は -quit で最初の一致で停止＝安価。
    #     write が無い場合のみ full traversal だが、この経路は throttle 通過後＝最短 N 分に 1 度に限られる）。
    if [ -e "$beads_dir/embeddeddolt" ] && command -v find >/dev/null 2>&1; then
        [ -n "$(find "$beads_dir/embeddeddolt" -newer "$marker" -print -quit 2>/dev/null)" ] && return 0
    fi
    return 1     # 書込なし
}

# remote 有無: bd-managed dolt remote が 1 つでもあれば 0。無ければ / 判定不能なら 1（silent no-op へ）。
# 読み取り専用（`bd dolt remote list`）＝funnel 対象外（write でない）。timeout で hang を有界化。
_sp_has_remote() {
    local root="$1" out rc
    command -v bd >/dev/null 2>&1 || return 1          # bd 不在 → 判定不能 → no-op（invariant⑦）
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout "$REMOTE_TIMEOUT" bd -C "$root" dolt remote list 2>/dev/null)"; rc=$?
    else
        out="$(bd -C "$root" dolt remote list 2>/dev/null)"; rc=$?
    fi
    [ "$rc" -eq 0 ] || return 1
    [ -n "$out" ] || return 1                          # 出力空 = remote 未設定 → silent no-op
    return 0
}

# throttle marker を atomic に stamp（tmp → rename。mtime が本体・scribe-heartbeat 同型・write-isolation 準拠）。
_sp_stamp_marker() {
    local marker="$1" ts tmp
    ts="$(date +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)"
    [ -n "$ts" ] || ts="unknown"
    tmp="$marker.tmp.$$"
    if printf '{"ts":"%s","layer":"2","event":"stop-sync-push"}\n' "$ts" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$marker" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# ============================ main ============================

ledger_root="${1:-}"
[ -n "$ledger_root" ] || exit 0
[ -d "$ledger_root/.beads" ] || exit 0                 # .beads 無し → graceful no-op（invariant⑦）

beads_dir="$ledger_root/.beads"
marker="$beads_dir/$MARKER_FILENAME"

# 1) throttle gate（stat のみ・subprocess 起動しない）
_sp_within_throttle "$marker" "$THROTTLE_MIN" && exit 0

# 2) write-signal gate（stat + 有界 find・subprocess 起動しない）
_sp_has_write_since "$marker" "$beads_dir" || exit 0

# --- ここから先が「実 push 経路」= bd/bdw subprocess を初めて払う（hot path 保護済）---

# 3) remote 有無（無ければ silent no-op・invariant⑦）。subprocess は throttle/write gate 通過後のみ。
_sp_has_remote "$ledger_root" || exit 0

# 4) bdw funnel 経由 push（bare bd dolt push を叩かない＝invariant③・唯一の enforcement）。
#    push は ledger_root を作業ディレクトリにして走らせ、bdw の DB 解決を anchor 台帳へ固定する
#    （Stop hook の cwd が admin 任意サブディレクトリでも取り違えない・heartbeat 前例）。
#    bdw path は本 script（scripts/）の sibling `scripts/bdw`。
_SP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
bdw="$_SP_DIR/bdw"
[ -x "$bdw" ] || exit 0                                # bdw 不在 → no-op（funnel を外して bare push はしない）

push_out=""; push_rc=0
if command -v timeout >/dev/null 2>&1; then
    push_out="$( cd "$ledger_root" 2>/dev/null && timeout "$PUSH_TIMEOUT" "$bdw" dolt push 2>&1 )"; push_rc=$?
else
    push_out="$( cd "$ledger_root" 2>/dev/null && "$bdw" dolt push 2>&1 )"; push_rc=$?
fi

if [ "$push_rc" -ne 0 ]; then
    # 失敗分類（transient / conflict とも exit 0・loud=stderr であって非0終了ではない）。
    # 出力に conflict 系の語があれば genuine conflict として loud、無ければ transient warn として記録。
    # marker は前進させない（次回 Stop が窓を跨いだ時点で再試行＝後続回収・write を落とさない）。
    if printf '%s' "$push_out" | grep -qiE 'conflict|merge|diverge|non-fast-forward|rejected' 2>/dev/null; then
        printf 'scribe-sync-push: push CONFLICT (loud・要確認, rc=%s): %s\n' "$push_rc" "$push_out" >&2
    else
        printf 'scribe-sync-push: push failed (transient・次窓で回収, rc=%s): %s\n' "$push_rc" "$push_out" >&2
    fi
    exit 0
fi

# 5) marker stamp（実 push 成功経路のみ・auto-export 復帰後＝marker.mtime >= issues.jsonl.mtime で自己 bump loop を塞ぐ）
_sp_stamp_marker "$marker"

exit 0

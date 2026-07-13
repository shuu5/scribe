#!/usr/bin/env bash
# session-boundary-heartbeat.sh — admin の cycle 境界 heartbeat（sc-b6w / orch-0yof ②・裁定-cycle-signal）
#
# 役割（裁定-cycle-signal verbatim）: 「admin の SessionStart/終了時 heartbeat（自台帳 mtime stamp・
#   last-sync 同型・write-isolation 準拠）＋推論配送（bead 作成時刻 < 宛先の cycle 境界＝配送済みと機械推論・
#   **per-bead ack write は作らない**）」。orchestrator の**配送観測**（orch-4js9: 各 admin の最終境界時刻・
#   up/down・未配送 `for:X` の滞留 age を可視化）が読む **1 個の stamp** を、admin 自身が自台帳へ焼く。
#
# 焼く面（最小設計）: `<ledger-root>/.beads/scribe-heartbeat`
#   - **mtime が stamp 本体**（`last-sync` 同型＝scriptorium `.beads/last-sync` と同じ規約。orchestrator は
#     stat の mtime だけで「最終 cycle 境界時刻」を得られる＝parse 不要）。
#   - 中身は **1 行 JSON**（人間と機械の両方が読める最小 detail）:
#       {"ts":"<ISO8601>","event":"session-start|session-end","source":"<startup|resume|clear|compact|
#        clear|logout|prompt_input_exit|other>","session_id":"<id>","ledger":"<dolt_database>","role":"admin"}
#     `event` で境界の種別、`source` で SessionStart の source / SessionEnd の reason を保つ（裁定-cycle-
#     unification: 普段は /clear・長寿命/plugin 変更後は respawn ＝どちらの経路で境界が来たかを orchestrator が
#     読めるようにする。auto-compact 発火＝`source=compact` は cycle 規律破れの signal ＝総点検追補3）。
#   - **write-isolation 準拠**: 書くのは **自台帳のみ**（foreign 台帳＝orch 台帳へは絶対に書かない）。
#     本 hook は `bd` を**一切呼ばない**（DB write なし・ファイル 1 個の atomic rename だけ）＝bd 並列 write の
#     直列化（bdw flock）とも無関係で、SessionStart/SessionEnd を遅らせない（**実測 ~90ms/境界**＝hook プロセスの
#     bash+jq 起動が支配的で、stamp 書込自体は rename 1 回。境界は session あたり 2 回ゆえ無視できる）。
#   - **per-bead ack write は作らない**（裁定で明示却下）。配送は「bead 作成時刻 < 境界時刻」の機械推論で足りる。
#
# 発火 role: **admin（anchor）のみ**。worker（worktree cell）/ consult（read-only 議論役）/ SCRIBE_ROLE=none は
#   no-op ——heartbeat は「この project の admin cycle がいつ境界を跨いだか」の signal であり、ephemeral な
#   worker/consult の起動終了で汚すと配送観測の意味が壊れる（role 判定は共有 lib `mbx_role`）。
#   自台帳 == orch 台帳（orchestrator 自身）も skip（配送観測の**観測側**であって被観測側ではない）。
#
# git 汚染について（load-bearing）: `.beads/scribe-heartbeat` は **runtime 生成物ゆえ commit しない**。
#   scribe repo は root `.gitignore` に `/.beads/scribe-heartbeat` を持つ（scriptorium が `.beads/last-sync` を
#   root .gitignore で除外しているのと同型）。**他 project（plugin global enable で本 hook が届く先）では
#   ignore 行が無いため untracked ファイルとして見える**——/scribe:setup（per-project reconciler）に
#   ignore 行の収束を足すのが恒久解（本 cell の scope 外＝admin への起票候補として bead notes に残す）。
#
# fail-safe: 全経路 **exit 0 degrade**（set -e は使わない）。lib 不在・台帳未解決・.beads が read-only
#   （worker sandbox 等）・stamp 書込失敗でもセッションを壊さない（SessionStart/SessionEnd の banner hook 系
#   ＝`[ -x ]` + `|| true` で wire）。

# --- 共有 lib（不在なら no-op degrade）---
_MBX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
# shellcheck source=lib/mailbox-common.sh
. "$_MBX_DIR/lib/mailbox-common.sh" 2>/dev/null || exit 0

# stamp ファイル名（env で上書き可＝テスト seam）
HB_FILENAME="${SCRIBE_HEARTBEAT_FILENAME:-scribe-heartbeat}"

# ============================ main ============================

mbx_read_stdin
hook_cwd="$(mbx_json_field cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
session_id="$(mbx_json_field session_id)"
hook_event="$(mbx_json_field hook_event_name)"

# 境界の種別: SessionStart は `source`・SessionEnd は `reason`（値は CC 版で増減しうるため**列挙に依存せず
# 受けた文字列をそのまま保存する**＝未知値でも壊れない）。どちらも取れなければ "unknown"。
# 既知の限界（sc-b6w self-review [nit]）: SessionEnd が発火しない終了（kill -9 / クラッシュ / ホスト停止）では
# 終了側 stamp は焼かれない——orchestrator は「最終境界時刻が古い」ことしか観測できず、down と沈黙は
# 区別できない（配送観測は last-boundary の age で読む設計ゆえ許容・裁定-cycle-signal の推論配送と整合）。
case "$hook_event" in
    SessionEnd) event="session-end";   src="$(mbx_json_field reason)" ;;
    SessionStart) event="session-start"; src="$(mbx_json_field source)" ;;
    *)          event="session-start"; src="$(mbx_json_field source)" ;;   # 保険（event 名不明時は start 扱い）
esac
[ -n "$src" ] || src="unknown"

# 発火は admin（anchor）のみ
[ "$(mbx_role "$hook_cwd")" = "admin" ] || exit 0

# 自台帳（.beads opt-in）。**walk-up は 1 回だけ**行い、root と dolt_database を同じ `.beads` から取る
# （sc-b6w self-review [nit] 修正: 独立に 2 回 walk-up すると、metadata.json を欠く `.beads` が途中に在るとき
#  root と db が別ディレクトリ由来になり、無関係な台帳へ stamp を焼きうる＝解決の非原子性）。
ledger_root="$(mbx_resolve_ledger_root "$hook_cwd")" || exit 0
[ -n "$ledger_root" ] || exit 0
self_db="$(mbx_read_dolt_db "$ledger_root/.beads/metadata.json")" || exit 0   # 同じ .beads から読む
[ -n "$self_db" ] || exit 0

# 自台帳 == orch 台帳（orchestrator 自身）→ skip（観測側であって被観測側でない）
orch_anchor="$(mbx_orch_anchor)" && {
    orch_db="$(mbx_read_dolt_db "$orch_anchor/.beads/metadata.json" 2>/dev/null || true)"
    [ -n "$orch_db" ] && [ "$orch_db" = "$self_db" ] && exit 0
}

# --- stamp を atomic に焼く（tmp → rename。mtime が本体）---
target="$ledger_root/.beads/$HB_FILENAME"
ts="$(date +%Y-%m-%dT%H:%M:%S%:z 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null)"
[ -n "$ts" ] || ts="unknown"

tmp="$target.tmp.$$"
if printf '{"ts":"%s","event":"%s","source":"%s","session_id":"%s","ledger":"%s","role":"admin"}\n' \
        "$ts" "$event" "$src" "$session_id" "$self_db" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null
fi

exit 0

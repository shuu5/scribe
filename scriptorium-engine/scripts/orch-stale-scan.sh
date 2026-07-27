#!/usr/bin/env bash
# orch-stale-scan.sh — 自台帳(orch-) open bead の created_at ベース停滞 scan（read-only・LLM 不使用・bd orch-gg9q Leg B）
#
# 由来（裁定 SSOT = orch-gg9q「[hygiene] label 体系昇格 + created_at 停滞 scan + re-ratify 定例」）─────────
#   admin/orchestrator の open backlog は「本当に手を付けるべき actionable」と「既存検知線（courier/handoff/
#   reconciliation/mailbox）が既に見張っている委譲物」「人間再裁定を待つ held/defer」が混在する。棚卸しの度に
#   全 open を目視分類するのは非効率かつ取りこぼす。本 script は open を **3 lifecycle クラスへ機械分類**し、
#   その上で **actionable クラスだけ** に created_at 年齢 gate（既定 14d）を適用して「停滞疑い」を surface する。
#   read-only surfacing のみ＝auto close / dispatch は一切しない（respawn 可否の clean-state-probe と同哲学＝
#   機械は事実を出すだけ・判断と行動は orchestrator/人間）。
#
# なぜ created_at か（bd stale=updated_at ベースとの相補・DEDUP SSOT）──────────────────────────────────
#   標準の `bd stale`（updated_at ベース・既定 30d）は本 fleet では **恒常 0 件** を返す（実測: orch-gg9q Leg A
#   2026-07-14 実行『No stale issues found』）。理由は embedded Dolt の export/hydrate（`bd repo sync` / v1.1.0
#   migration export）が **実作業と無関係に updated_at を bump** するため（実例: orch-mx0 = created 2026-06-21 /
#   updated 2026-07-07 ＝ 16 日後 bump・vs orch-awo = bump なし）。ゆえ updated_at ベースの停滞判定は premise 失効を
#   検知できず無効化される。本 script は bump 免疫のある **created_at**（起票時刻・不変）を年齢の基準にし、status が
#   open のまま（＝lifecycle 未遷移）長期滞留する actionable を拾う。**bd stale の置換ではなく相補**（bd stale が
#   updated_at で拾えなくなった premise 失効面を created_at で補完する）。
#
# 3 lifecycle クラス（open を漏れなく重複なく 1 クラスへ解決＝completeness gate）──────────────────────────
#   分類は **curated allowlist**（下記ラベル集合に固定・worker/orchestrator が発明しない・junk label 化防止）で、
#   優先順（first-match・両属を単一クラスへ確定）に評価する:
#     (1) held-defer      : `held` ラベル ∨ status==deferred  →  人間 re-ratify 対象（最優先＝明示 park が最強シグナル）
#     (2) tracker-delegated: `courier`/`coord`/`needs-grill`/`needs-orch`/`needs-orch-ack`/`federate-publish`/
#                           `reconcile-published`/`for:*`（mailbox §5.3）→ 既存検知線が既に見張る委譲物＝除外
#     (3) held-defer      : `follow-up` ∨ `seam` ラベル  →  deferred follow-up / 予約 seam ＝ re-ratify 対象
#                           （検知線を持たないため actionable でなく held/defer 側の残余へ寄せる）
#     (4) actionable      : 上記いずれでもない（default）＝ sweep 対象＝停滞 gate を適用する唯一のクラス
#   ★completeness: class は必ず 1 つへ解決する（default=actionable ゆえ 0 クラスは起きない）。両属は優先順で
#     単一化する（例 courier+follow-up は (2) tracker が follow-up より先＝tracker-delegated へ確定）。分類は
#     ラベル未認識でも actionable（default）へ落ちる＝class レベルの「分類不能」は生じない。
#
# 停滞判定（THRESHOLD・過検出防止）───────────────────────────────────────────────────────────────────
#   **順序を守る**: 先に classify → **actionable クラスの bead だけ** に created_at 年齢 > THRESHOLD_DAYS（既定 14d）
#   を適用する。tracker-delegated / held-defer は「停滞疑い:M」から **除外**（既存検知線・人間再裁定が別途見張る）。
#   started_at は bd に無いため「status 未遷移」は status==open へ collapse し created_at 年齢と AND を取る
#   （母集団は status==open,deferred＝in_progress/blocked/closed は対象外。deferred は held-defer へ分類され
#   停滞 gate 対象外ゆえ、年齢 gate が実際に効くのは status==open の actionable のみ）。
#   ★created_at 解析不能な actionable は「停滞」と「新鮮」のどちらへも force-fit せず、別枠 [STALE-UNKNOWN] で
#     loud surface する（parse 失敗と真の停滞を融合しない・silently-choose 禁止）。
#
# limitation（updated_at 意図的無視の代償・DEDUP SSOT）──────────────────────────────────────────────────
#   created_at ベースは **active に議論・更新され続けている長期 open を誤検出しうる**（例: 起票は古いが今も活発に
#   動いている actionable bead は「停滞疑い」に載る）。これは updated_at を意図的に無視した代償で、本 script は
#   「疑い」を surface するだけ＝停滞かどうかの最終判断は orchestrator/人間が行う（auto close しない）。held/defer/
#   tracker は除外されるため、active 議論中でも held ラベルを付ければ M から外れる（分類が誤検出の逃げ道になる）。
#
# 母集団は自台帳 orch- のみ（SCOPE・write-isolation §4）─────────────────────────────────────────────────
#   連結 substrate hydrate で自 DB の `bd list` は foreign copy（sc/ccs や連結先 project 由来の各種 prefix）も返すため、id が
#   `orch-` 始まりのものだけに filter する。foreign bead は分類も停滞判定もしない（read-only ゆえ書込みは元々皆無・
#   母集団混入だけを弾く）。--self-test で foreign 混入 fixture の非検出を assert する。
#
# 既存 hygiene 系との非二重配線（DEDUP）─────────────────────────────────────────────────────────────────
#   clean-state-probe（respawn 可否軸）とは軸が直交＝合成しない。degraded-watch（窓消失 cell）とも別軸。本 script は
#   停滞 backlog の surfacing 専任。/scriptorium:orch-rebrief の 1 行 tripwire への配線は orch-rebrief-fetch.sh の
#   env seam（ORCH_RESUME_STALE_SCAN）経由で本 script を **1 回だけ** invoke する形に限定し（scan LOGIC の
#   単一 SSOT を本 script が持ち fetch 側は compose のみ・二重呼びしない）、workinprogress hook へ勝手に足さない
#   （越境=二重 surface）。
#   ★provider 側 seam は 2 本: `--emit-tripwire`（[STALE-TRIPWIRE] 行 1 行＝fetch 側が [STALE] の M と [CLASSES] の
#     3 クラス内訳を **同一 invocation** から両取りできる・bd orch-myn0）と `--emit-count`（M のみ・後方互換で残置）。
#     どちらも 1 invocation ＝呼出増ゼロ。engine 同梱の orch-rebrief-fetch.sh は現時点で `--emit-count` を invoke
#     する（consumer 側の tripwire 移行は本 script の fence 外＝別便。provider seam の先行提供が本節の範囲）。
#
# 使い方─────────────────────────────────────────────────────────────────────────────────────────────
#   scripts/orch-stale-scan.sh              # 全 open を分類し停滞疑いを surface（人間可読レポート・常に exit 0）
#   scripts/orch-stale-scan.sh --emit-count # 停滞疑い M（actionable ∩ created_at>閾値）の整数のみを stdout へ（seam 用）
#   scripts/orch-stale-scan.sh --emit-tripwire # [STALE-TRIPWIRE] 行 1 行のみを stdout へ（3 クラス内訳 + M を同一 pass で
#                                           #   compose する seam＝orch-rebrief-fetch の [STALE]/[CLASSES] 両取り用・
#                                           #   report が既に計算済みの行を emit するだけ＝invocation 増ゼロ・_classify 無改修。
#                                           #   bd read/jq parse 失敗時は tripwire 行を出さず [STALE-TRIPWIRE-UNKNOWN] へ倒す
#                                           #   ＝「全クラス 0 件」と融合しない）
#   scripts/orch-stale-scan.sh --re-ratify  # 死角クラス（courier/coord/held/seam/follow-up∨deferred）の re-ratify sweep
#                                           #   ＝別軸・別閾値（既定 7d）・別表示（週次再裁定・stateless read-only・write ゼロ）
#   scripts/orch-stale-scan.sh --emit-reratify-count # re-ratify 候補の整数のみ（--emit-count と別 seam・fail-open で無出力）
#   scripts/orch-stale-scan.sh --dry-run    # 叩く read-only コマンドを列挙（実行しない）
#   scripts/orch-stale-scan.sh --self-test  # hermetic 自己検証（fail-closed・bats 非依存）
#   scripts/orch-stale-scan.sh --help
#
# self-scope gate（他 orch- script と同一機構・誤台帳起動を fail-closed で弾く）──────────────────────────
#   cwd から walk-up した最初の .beads/metadata.json の dolt_database が orch でなければ何もせず非 0 で抜ける
#   （ORCH_STALE_SKIP_SESSION_GATE=1 で skip＝hermetic self-test / bats 用）。
#
# env override（主に hermetic self-test / bats 用）──────────────────────────────────────────────────────
#   ORCH_STALE_SCRIPTORIUM       scriptorium anchor root（既定: 共有 lib _resolve_scriptorium〔ORCH_ANCHOR /
#                                ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き〕・解決不能は fail-loud）。bd read を anchor へ pin。
#   ORCH_STALE_BD                bd 実体（既定: PATH 上の bd）。read-only（list --json のみ）。
#   ORCH_STALE_NOW               「現在」を表す date 文字列（既定: now）。created_at 年齢の基準（hermetic 決定論用）。
#   ORCH_STALE_THRESHOLD_DAYS    停滞 gate の閾値日数（既定: 14）。actionable クラスのみに適用。
#   ORCH_STALE_RERATIFY_THRESHOLD_DAYS  re-ratify sweep の閾値日数（既定: 7）。死角クラスのみに適用（THRESHOLD_DAYS と別）。
#   ORCH_STALE_SKIP_SESSION_GATE=1  self-scope gate を skip（hermetic self-test / bats 用）。
#
# 検証: tests/scenarios/orch-stale-scan.bats（hermetic: bd を PATH/env スタブで差替・3 クラス分類 / foreign 非検出 /
#   defer 済み非計上 / compound 2-label / threshold 順序 / completeness / mutation 非空虚）＋ 本 script `--self-test`。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard / 他 orch- script と同一値を共有）。
SELF_PREFIX="orch"

# ── SCRIPTORIUM anchor 動的解決（共有 lib orch_anchor.sh・clean-state-probe / dispatch と同型・orch-49g）──
# _resolve_scriptorium（E2 anchor 検証付き）を提供する共有 lib を BASH_SOURCE 相対で source する（bats/--self-test が
# seam override しても実 lib を確実に見つける）。lib は内部で orch_session.sh を transitive source し、解決候補 anchor の
# dolt_database==orch を検証する（foreign repo anchor の誤採用を構造封鎖＝E2）。★SCRIPTORIUM 代入の**前**に source する。
_orch_stale_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_orch_stale_dir="$(cd "$(dirname "$_orch_stale_self")" 2>/dev/null && pwd || echo .)"
_ORCH_ANCHOR_LIB="$_orch_stale_dir/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
    # shellcheck source=lib/orch_anchor.sh
    . "$_ORCH_ANCHOR_LIB"
else
    echo "orch-stale-scan: 共有 anchor lib 不在: $_ORCH_ANCHOR_LIB（anchor 解決不能・fail-closed）" >&2
    exit 1
fi

# ── 共有 self-scope lib（_ledger_dolt_database）を source（clean-state-probe と同型・orch-vo2） ──
_ORCH_SESSION_LIB="$_orch_stale_dir/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-stale-scan: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# anchor 解決（SCRIPTORIUM）は scan/dry/report path 専用ゆえ **arg-parse + --self-test dispatch + self-scope gate
# の後** に遅延させる（下部参照）。hermetic な --self-test は自前 fixture で完結し anchor に触れないため、engine の
# fail-loud anchor が --self-test / --help を巻き添えにしてはならない（self-test は自 anchor fixture を子起動へ渡す）。
BD="${ORCH_STALE_BD:-bd}"
THRESHOLD_DAYS="${ORCH_STALE_THRESHOLD_DAYS:-14}"

# ─────────────────────────────────────────────────────────────────────────────
# 共通 read-only ヘルパ
# ─────────────────────────────────────────────────────────────────────────────

# 自台帳 orch- の open+deferred bead を "id|status|labels_csv|created_at|title" 行（| 区切り）で emit（read-only・jq 必須）。
#   母集団は `--status open,deferred`＝bd-native に defer された bead も held-defer クラスとして surface する（deferred
#   は held-defer へ分類され actionable にはならない＝停滞 gate 対象外ゆえ M は不変・re-ratify 起点にだけ載る）。
#   連結 substrate hydrate で foreign copy も返るため SELF_PREFIX で filter。labels:null は空 CSV へ潰す。
#   bd read は anchor へ cd してから叩く（worktree の `.beads/embeddeddolt` 不在で空/foreign を返す罠を回避・
#   orch-rebrief-fetch と同型の cwd 非依存原則）。
#   フィールド区切りは `|`（パイプ）＝**非空白**を使う（tab は空白ゆえ read の IFS 畳み込みで空 labels フィールドが
#   消え created_at が labels 列へ滑り込む off-by-one bug を招く）。id=orch-[a-z0-9]/status=語/label=[a-z:-]/
#   created_at=RFC3339 は `|` を含まないため衝突しない・labels 内の複数値は "," 連結ゆえ | と非干渉。
#   ★title は **最終列**に置く（title は人間文＝`|` を含みうるが、reader は `read -r ... created title` の trailing var
#     が残余を丸ごと吸収するため embedded `|` があっても created_at 列へ滑らない。title の embedded 改行のみ非対応＝
#     bd title は単一行ゆえ実害なし）。title 非使用の既存モード（report/count）は trailing var を捨てるだけで byte 不変。
#   ★bd 呼出（_stale_bd_json）と jq filter（_rows_from_json）を分離するのは、re-ratify モードが bd の rc を検知して
#     「bd 失敗＝判定不能」と「空台帳＝候補なし」を弁別するため（acceptance(7) が bd 失敗を明示列挙）。既存モード用
#     _open_rows は rc を無視する従来 pipe 形を保つ（byte 不変＝bd 失敗→空 rows→0/NONE は run_scan の既存挙動）。
_stale_bd_json() {
    # 自台帳 open+deferred の生 JSON（rc 保存＝subshell rc = bd/anchor 失敗を呼出側が検知可能）。
    ( cd "$SCRIPTORIUM" 2>/dev/null && "$BD" list --status open,deferred --json --no-pager --limit 0 2>/dev/null )
}
_rows_from_json() {
    # 生 JSON（stdin）→ "id|status|labels|created|title" 行（SELF_PREFIX filter・jq 必須）。
    jq -r --arg p "$SELF_PREFIX" '
        .[]? | select(.id | startswith($p + "-"))
        | [ .id, (.status // ""), ((.labels // []) | join(",")), (.created_at // ""), (.title // "") ]
        | join("|")' 2>/dev/null
}
_open_rows() {
    # 既存モード（run_scan）用の従来形＝bd rc を無視（byte 不変・bd 失敗→空 rows）。
    _stale_bd_json | _rows_from_json
}

# now を epoch 秒で（ORCH_STALE_NOW 既定 now・hermetic 決定論用）。解決不能は空。
_now_epoch() { date -d "${ORCH_STALE_NOW:-now}" +%s 2>/dev/null; }

# created_at 文字列（RFC3339）を epoch 秒へ。解析不能は空（呼出側で [STALE-UNKNOWN] へ）。
_epoch_of() { date -d "$1" +%s 2>/dev/null; }

# ─────────────────────────────────────────────────────────────────────────────
# classifier: labels_csv + status → "class<TAB>reason"（curated allowlist・first-match 優先順）
#   completeness: 必ず 1 クラスへ解決（default=actionable）。両属は優先順で単一化。
# ─────────────────────────────────────────────────────────────────────────────
_classify() {
    local labels_csv="$1" status="$2" lab
    local IFS=','
    local -a arr
    read -ra arr <<< "$labels_csv"
    IFS=$' \t\n'
    # (1) held-defer: held ラベル ∨ deferred status（最優先＝明示 park）。
    for lab in "${arr[@]}"; do
        [ "$lab" = "held" ] && { printf 'held-defer\theld ラベル'; return; }
    done
    [ "$status" = "deferred" ] && { printf 'held-defer\tdeferred status'; return; }
    # (2) tracker-delegated: 既存検知線が見張る委譲物。
    for lab in "${arr[@]}"; do
        case "$lab" in
            courier|coord|needs-grill|needs-orch|needs-orch-ack|federate-publish|reconcile-published)
                printf 'tracker-delegated\t%s ラベル' "$lab"; return ;;
            for:*)
                printf 'tracker-delegated\t%s（mailbox §5.3）' "$lab"; return ;;
        esac
    done
    # (3) held-defer: follow-up / seam（検知線を持たない deferred 残余）。
    for lab in "${arr[@]}"; do
        case "$lab" in
            follow-up|seam) printf 'held-defer\t%s ラベル' "$lab"; return ;;
        esac
    done
    # (4) actionable: default（sweep 対象・停滞 gate を適用する唯一のクラス）。
    if [ -n "$labels_csv" ]; then
        printf 'actionable\tdefault（未認識ラベル [%s]・sweep 対象）' "$labels_csv"
    else
        printf 'actionable\tdefault（label 無し・sweep 対象）'
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# re-ratify sweep 分類（bd orch-cqf4 Leg-A・_classify とは別軸＝死角クラスの再裁定 sweep）
#   由来（orch-6srt 裁定-backlog(2)(3)）: 日常は既存 event 駆動検知線に任せ、年齢 gate 死角クラス
#   （courier/coord/held/seam/follow-up ∨ deferred＝courier 22d silent 滞留の実測穴）だけを **別閾値・別表示** で
#   週次 re-ratify sweep する。actionable stale（_classify）とは対象集合が真逆（_classify では courier/coord は
#   tracker-delegated で actionable stale から除外されるが、本 sweep はそれら死角クラスこそ対象にする）。
#   ★_classify を一切変えない（既存 tripwire/emit-count は byte 不変）。本関数は curated allowlist・完全一致・
#     first-match で単一 key へ確定する（worker が母集団を発明/拡張しない）。
#   labels_csv + status → "target<TAB>key" | "excluded<TAB>reason"
#     除外優先（first-match）: needs-grill/needs-orch/needs-orch-ack/federate-publish/reconcile-published を
#       持てば対象外（bead 自体を毎 session surface する live 検知線あり＝二重 surface 禁止）。
#     死角クラス: {held, seam, follow-up, courier, coord} のいずれか ∨ status==deferred → target（key=matched）。
#     それ以外（actionable 域・for:* 単独含む）→ excluded。for:* は除外条件にしない（mandate-verify override ii：
#       courier∩for:* は courier で target 化＝配送後長期 open こそ courier 22d 穴の実体）。
# ─────────────────────────────────────────────────────────────────────────────
_reratify_target() {
    local labels_csv="$1" status="$2" lab
    local IFS=','
    local -a arr
    read -ra arr <<< "$labels_csv"
    IFS=$' \t\n'
    # 除外優先: live 検知線が既に毎 session surface する委譲物（二重 surface 禁止）。
    for lab in "${arr[@]}"; do
        case "$lab" in
            needs-grill|needs-orch|needs-orch-ack|federate-publish|reconcile-published)
                printf 'excluded\t%s（live 検知線あり）' "$lab"; return ;;
        esac
    done
    # 死角クラス（re-ratify 対象）: 完全一致・first-match で単一 key 化。
    for lab in "${arr[@]}"; do
        case "$lab" in
            held|seam|follow-up|courier|coord) printf 'target\t%s' "$lab"; return ;;
        esac
    done
    [ "$status" = "deferred" ] && { printf 'target\tdeferred'; return; }
    # それ以外（actionable 域・for:* 単独含む）は re-ratify 対象外。
    printf 'excluded\tactionable域（re-ratify 対象外・for:* 単独含む）'
}

# ─────────────────────────────────────────────────────────────────────────────
# scan 本体: 全 open を分類し、actionable のみに created_at 年齢 gate を適用して M を算出。
#   $1="report"（人間可読・stdout 全出力）| "count"（M の整数のみ）| "tripwire"（[STALE-TRIPWIRE] 行 1 行のみ）。副作用ゼロ。
#   戻り値経由で M を返せないため、report は stdout へ・count は M のみ・tripwire は tripwire 行のみ stdout へ。
#   ★tripwire mode は report が既に組み立てる同一文字列（$tw_line）を emit するだけ＝**同一 pass・invocation 増ゼロ**
#     （fetch 側が [STALE] の M と [CLASSES] の 3 クラス内訳を 1 回の呼出で両取りするための seam・bd orch-myn0）。
#     _classify も年齢 gate も一切触らない＝`--emit-count` / report 出力は **byte 不変**。
#   ★tripwire mode のみ rows 取得の rc を弁別する（bd read/jq parse 失敗→[STALE-TRIPWIRE-UNKNOWN]・下記 fail-closed
#     コメント参照）。count/report は rc を参照しない＝従来の「bd 失敗→空 rows→0/NONE」挙動を byte 不変で維持。
# ─────────────────────────────────────────────────────────────────────────────
run_scan() {
    local mode="$1"
    local rows now_epoch rows_rc
    # ★rc 捕捉（set -o pipefail 済＝bd 失敗も jq parse 失敗も拾える）。**tripwire mode だけ**が rc を参照する
    #   （count/report は従来どおり rc を無視＝A2 byte 不変・_open_rows の pipe 形も無改修）。
    rows="$(_open_rows)"; rows_rc=$?
    now_epoch="$(_now_epoch)"

    local total=0 n_action=0 n_held=0 n_tracker=0 stale=0 unknown=0
    local action_ids="" held_ids="" tracker_ids=""
    local -a class_lines=() stale_lines=() unknown_lines=()

    local id status labels created title cls reason
    while IFS='|' read -r id status labels created title; do
        [ -n "$id" ] || continue
        total=$((total + 1))
        IFS=$'\t' read -r cls reason < <(_classify "$labels" "$status")
        class_lines+=("[CLASS] $(printf '%-10s %-18s (%s)' "$id" "$cls" "$reason")")
        case "$cls" in
            actionable)
                n_action=$((n_action + 1)); action_ids="${action_ids:+$action_ids }$id"
                # 停滞 gate は actionable クラスにのみ適用（THRESHOLD 順序: classify 済み → 年齢）。
                local cepoch age_d
                cepoch="$(_epoch_of "$created")"
                if [ -z "$cepoch" ] || [ -z "$now_epoch" ]; then
                    unknown=$((unknown + 1))
                    unknown_lines+=("[STALE-UNKNOWN] $id created_at='$created' 解析不能＝停滞判定不能（force-fit せず surface）")
                    continue
                fi
                age_d=$(( (now_epoch - cepoch) / 86400 ))
                if [ "$age_d" -gt "$THRESHOLD_DAYS" ]; then
                    stale=$((stale + 1))
                    stale_lines+=("[STALE] $id created=${created%%T*} age=${age_d}d > ${THRESHOLD_DAYS}d  ⚠停滞疑い（actionable・長期 open）")
                fi
                ;;
            held-defer)
                n_held=$((n_held + 1)); held_ids="${held_ids:+$held_ids }$id" ;;
            tracker-delegated)
                n_tracker=$((n_tracker + 1)); tracker_ids="${tracker_ids:+$tracker_ids }$id" ;;
        esac
    done <<< "$rows"

    # tripwire 行は report / tripwire mode で同一文字列を使う（二重実装しない＝drift 源を作らない）。
    local tw_line
    tw_line="[STALE-TRIPWIRE] open:$total actionable:$n_action held-defer:$n_held tracker:$n_tracker 停滞疑い:$stale$([ "$unknown" -ne 0 ] && printf ' age不明:%s' "$unknown")"

    if [ "$mode" = "count" ]; then
        printf '%s\n' "$stale"
        return 0
    fi

    # tripwire seam（bd orch-myn0）: 1 行のみを stdout へ（report の他行は出さない＝parse 側の contract を単純化）。
    #   ★fail-closed（bd orch-myn0 self-review・major#1/#2）: bd read 失敗（anchor/bd 障害・dolt lock 競合）や
    #     jq parse 失敗（rows_rc≠0）を **「全クラス 0 件」へ融合しない**。tripwire 行を出さず
    #     `[STALE-TRIPWIRE-UNKNOWN]`（consumer の `^\[STALE-TRIPWIRE\] ` 正規形に**一致しない**別 marker）へ倒す。
    #     provider 側の契約は「正規形を名乗らない」ことだけで、consumer は正規形に一致しない出力を自分の
    #     skip 経路へ落とす（engine 同梱 orch-rebrief-fetch.sh は現時点で本 seam の consumer ではない＝別便）。
    #     俯瞰 consumer は tripwire の 3 クラス内訳を「残り」の唯一の出所として数え直しを禁じる設計ゆえ、ここで
    #     0 を返すと台帳障害が『残り 0 件・今すぐ着手 0』という偽 all-clear へ収束する（fail-open の方向が危険側）。
    #     run_reratify が既に持つ「bd 失敗 vs 空台帳」弁別（本 script 内の先例）と対称にする。
    #     ★空台帳（rc=0・rows 空）は従来どおり open:0 の tripwire 行を emit する＝弁別は空虚でない。
    if [ "$mode" = "tripwire" ]; then
        if [ "$rows_rc" -ne 0 ]; then
            printf '%s\n' "[STALE-TRIPWIRE-UNKNOWN] bd read/parse 失敗（rc=$rows_rc・anchor/bd/jq 障害）＝3 クラス内訳と停滞疑いは測定不能（0 件・空台帳と融合しない）"
            return 0
        fi
        printf '%s\n' "$tw_line"
        return 0
    fi

    echo "orch-stale-scan: created_at ベース停滞 scan（read-only・副作用ゼロ・bd orch-gg9q Leg B）"
    echo "  anchor=$SCRIPTORIUM threshold=${THRESHOLD_DAYS}d now=${ORCH_STALE_NOW:-now}"
    echo
    echo "── 分類テーブル（orch- open 全件・completeness gate＝各件ちょうど 1 クラス） ──"
    if [ "$total" -eq 0 ]; then
        echo "  （orch- open bead は 0 件）"
    else
        local l; for l in "${class_lines[@]}"; do echo "  $l"; done
    fi
    echo
    echo "── grouping（class/label 別束ね・read-only 一回性提案・常設 engine は新設しない） ──"
    echo "  held-defer ($n_held): ${held_ids:-（なし）}"
    echo "  tracker-delegated ($n_tracker): ${tracker_ids:-（なし）}"
    echo "  actionable ($n_action): ${action_ids:-（なし）}"
    echo
    echo "── 停滞判定（actionable クラスのみ created_at>${THRESHOLD_DAYS}d を適用・tracker/held-defer は除外） ──"
    if [ "$stale" -eq 0 ]; then
        echo "  [STALE-NONE] actionable クラスに停滞疑い（>${THRESHOLD_DAYS}d）なし"
    else
        local s; for s in "${stale_lines[@]}"; do echo "  $s"; done
    fi
    if [ "$unknown" -ne 0 ]; then
        local u; for u in "${unknown_lines[@]}"; do echo "  $u"; done
    fi
    echo
    # completeness assert（実行時の loud 表示・sum==total を人間が一次確認できる）。
    local classified=$((n_action + n_held + n_tracker))
    if [ "$classified" -ne "$total" ]; then
        echo "  [COMPLETENESS-RED] 分類合計 $classified ≠ open 総数 $total（分類漏れ＝要調査）"
    fi
    echo "$tw_line"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# re-ratify sweep 本体（bd orch-cqf4 Leg-A・stateless read-only・write ゼロ・fail-open）
#   死角クラス（_reratify_target=target）∩ created_at 年齢 > ORCH_STALE_RERATIFY_THRESHOLD_DAYS（既定 7）を
#   label 束ね・age 降順で surface。$1="report"（人間可読）| "count"（整数のみ・--emit-reratify-count seam）。
#   ★停滞（actionable/14d）とは別閾値・別表示・別 tripwire＝既存出力を一切 perturbate しない。
#   ★fail-open（acceptance(7)＝bd/jq/date 失敗でも exit 0）: bd read 失敗（_stale_bd_json rc≠0＝anchor/bd 障害）or
#     now 解決不能（date 失敗）→ report は「判定不能」note・count は無出力。jq 不在は上流の mode-aware gate で処理済み。
#     ★bd 失敗（rc≠0）と空台帳（rc=0・rows 空）を弁別する（bd outage を『再裁定すべき仕事なし』と silent に隠さない＝
#       re-ratify sweep の目的＝silent 滞留検出と自己矛盾させない・slate --surface の rc 伝播と対称）。
#   ★write ゼロ: timer/cron/marker/per-item stamp なし（「週次」は cadence でなく再 ratify 頻度の目安＝毎 session
#     無条件 print）。needs-user 併存 bead には呼び鈴対象マーク（push は一切しない＝surfacing 専任）。
# ─────────────────────────────────────────────────────────────────────────────
run_reratify() {
    local mode="$1"
    local json rc rows now_epoch threshold
    json="$(_stale_bd_json)"; rc=$?
    now_epoch="$(_now_epoch)"
    threshold="${ORCH_STALE_RERATIFY_THRESHOLD_DAYS:-7}"

    # fail-open: bd/anchor 失敗（rc≠0）or now 解決不能（date 障害）→「判定不能」で exit 0（count は無出力＝整数不能時契約）。
    #   ★bd 失敗を空台帳（rc=0・rows 空→後段で RERATIFY-NONE）と弁別＝bd outage を『候補なし』へ silent に畳まない。
    if [ "$rc" -ne 0 ] || [ -z "$now_epoch" ]; then
        [ "$mode" = "count" ] && return 0
        local why
        if [ "$rc" -ne 0 ]; then why="bd read 失敗（rc=$rc・anchor/bd 障害）"; else why="now 解決不能（date 失敗）"; fi
        echo "orch-stale-scan --re-ratify: 判定不能（$why）— read-only surfacing のみ（write ゼロ・exit 0）"
        return 0
    fi
    rows="$(printf '%s' "$json" | _rows_from_json)"

    local n_target=0 n_unknown=0
    local -a surfaced=() unknown_lines=()

    local id status labels created title decision key
    while IFS='|' read -r id status labels created title; do
        [ -n "$id" ] || continue
        IFS=$'\t' read -r decision key < <(_reratify_target "$labels" "$status")
        [ "$decision" = "target" ] || continue
        # 死角クラス ∩ created_at 年齢 > threshold。created_at 解析不能は force-fit せず別枠 surface。
        local cepoch age_d
        cepoch="$(_epoch_of "$created")"
        if [ -z "$cepoch" ]; then
            n_unknown=$((n_unknown + 1))
            unknown_lines+=("[RERATIFY-UNKNOWN] $id ($key) created_at='$created' 解析不能＝年齢判定不能（force-fit せず surface）")
            continue
        fi
        age_d=$(( (now_epoch - cepoch) / 86400 ))
        [ "$age_d" -gt "$threshold" ] || continue
        n_target=$((n_target + 1))
        # needs-user 併存 → 呼び鈴対象マーク（push はしない・§1.2 ③ Tier2 push=人間 go）。
        local bell=""
        case ",$labels," in *,needs-user,*) bell="  🔔呼び鈴対象(needs-user・push はしない)" ;; esac
        local titlehead="${title:0:60}"
        # 束ね/整列用に "age<TAB>key<TAB>表示行" で溜める（key 別 grouping・age 降順 sort に使う）。
        surfaced+=("$(printf '%d\t%s\t[RERATIFY] %-12s age=%dd (%s) %s%s' "$age_d" "$key" "$id" "$age_d" "$key" "$titlehead" "$bell")")
    done <<< "$rows"

    if [ "$mode" = "count" ]; then
        printf '%s\n' "$n_target"
        return 0
    fi

    echo "orch-stale-scan --re-ratify: re-ratify sweep（死角クラス）（read-only・write ゼロ・bd orch-cqf4 Leg-A）"
    echo "  anchor=$SCRIPTORIUM reratify-threshold=${threshold}d now=${ORCH_STALE_NOW:-now}"
    echo "  死角クラス={held,seam,follow-up,courier,coord}∨deferred status / 除外=needs-grill,needs-orch,needs-orch-ack,federate-publish,reconcile-published（live 検知線あり）・for:* 単独も対象外"
    echo
    echo "── re-ratify 候補（label 束ね・age 降順・created_at>${threshold}d・push なし） ──"
    if [ "$n_target" -eq 0 ] && [ "$n_unknown" -eq 0 ]; then
        echo "  [RERATIFY-NONE] 死角クラスに created_at>${threshold}d の re-ratify 候補なし"
    else
        if [ "$n_target" -gt 0 ]; then
            # canonical key 順（first-match と同順）で束ね、各 group を age 降順で print（silent cap 禁止＝全件）。
            local gkey group
            for gkey in held seam follow-up courier coord deferred; do
                group="$(printf '%s\n' "${surfaced[@]}" | awk -F'\t' -v k="$gkey" '$2==k')"
                [ -n "$group" ] || continue
                local gcnt
                gcnt="$(printf '%s\n' "$group" | grep -c .)"
                echo "  ── ${gkey} (${gcnt}) ──"
                printf '%s\n' "$group" | sort -t"$(printf '\t')" -k1,1nr | cut -f3- | while IFS= read -r l; do
                    [ -n "$l" ] && echo "    $l"
                done
            done
        fi
        if [ "$n_unknown" -ne 0 ]; then
            local u; for u in "${unknown_lines[@]}"; do echo "  $u"; done
        fi
    fi
    echo
    echo "[RERATIFY-TRIPWIRE] 死角クラス re-ratify 候補:$n_target$([ "$n_unknown" -ne 0 ] && printf ' age不明:%s' "$n_unknown")（threshold=${threshold}d・push なし・write ゼロ）"
    return 0
}

run_dry_run() {
    echo "[plan] orch-stale-scan 単発 read-only scan（mutate しない・close/dispatch/label もしない）:"
    echo "[plan]   母集団: ( cd $SCRIPTORIUM && $BD list --status open,deferred --json --limit 0 ) を jq で ${SELF_PREFIX}- filter"
    echo "[plan]   分類: curated allowlist（held/deferred → held-defer / courier,coord,for:*,needs-*,federate/reconcile → tracker / follow-up,seam → held-defer / else → actionable）"
    echo "[plan]   停滞: actionable クラスのみ created_at 年齢 > ${THRESHOLD_DAYS}d（now=${ORCH_STALE_NOW:-now}・date -d で epoch 差）"
    echo "[plan]   出力: 分類テーブル + grouping + [STALE-TRIPWIRE] 行（--emit-count は M の整数のみ）"
    return 0
}

usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# --self-test: bats 非依存の内蔵 hermetic 検証（fail-closed＝assert 1 つでも落ちたら非0）
#   一時 fixture（.beads/metadata.json dolt_database=orch・スタブ bd）を組み、3 クラス分類 / foreign 非検出 /
#   defer 済み非計上 / compound 2-label / threshold 順序 / completeness / mutation 非空虚 を検証する。
# ─────────────────────────────────────────────────────────────────────────────
run_self_test() {
    local tmp rc fails=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/orch-stale-selftest.XXXXXX")" || { echo "self-test: mktemp 失敗" >&2; return 1; }
    trap 'rm -rf "$tmp"' RETURN

    local self="$_orch_stale_dir/$(basename "${BASH_SOURCE[0]}")"
    local bindir="$tmp/bin"; mkdir -p "$bindir"
    local anchor="$tmp/anchor"; mkdir -p "$anchor/.beads"
    printf '{"dolt_database":"orch"}\n' > "$anchor/.beads/metadata.json"

    # bd スタブ: STUB_ROWS（1 行 = id|status|labels_csv|created_at）を bd list --json として emit。
    #   foreign 混入（pk-xxx 等）も STUB_ROWS に含め、非 orch- filter を exercise する。
    cat > "$bindir/bd" <<'STUB'
#!/usr/bin/env bash
# read-only bd スタブ（list --json のみ）。STUB_ROWS の各行を JSON object へ。labels_csv 空→[] / "null"→labels 欠落。
#   行形式は "id|status|labels_csv|created_at[|title]"（title は任意 5 列目＝re-ratify 表示用・省略時空）。
#   ★BD_FAIL=1 で非0 exit（bd/anchor outage を模す＝re-ratify の bd 失敗弁別を exercise）。
#   ★BD_BADJSON=1 は **exit 0 のまま** stdout を不正 JSON にする（dolt lock 警告の前置ノイズが混じる degraded 形）。
#     tripwire の fail-closed には発火 trigger が 2 本ある（bd rc≠0 と jq parse rc≠0）。BD_FAIL は前者しか
#     exercise しないため、jq 段の rc を捨てる変異が素通りする＝後者を叩く seam をここに置く。
#   ★BD_LOG（既定 /dev/null）へ 1 呼出 = 1 行を記録する。行数がそのまま bd 呼出回数＝「report と同一 pass・
#     invocation 増ゼロ」の直接 teeth（出力の byte 一致は決定論 fixture 下で二重 pass 実装を弁別できない）。
# --status <csv> を尊重して実 bd の相互排他 status 挙動を模す（指定 status の行のみ emit・未指定は全件）。
#   ★deferred 行は query が open,deferred を要求したときだけ返る＝deferred は deferred-scan 由来で返る（母集団が
#   --status open のみだと deferred は返らない＝deferred branch を vacuous に green にしない現実的 stub）。
printf '%s\n' "$*" >> "${BD_LOG:-/dev/null}"
[ -n "${BD_FAIL:-}" ] && exit 1
[ -n "${BD_BADJSON:-}" ] && { printf 'warning: dolt lock held by another process\n[]'; exit 0; }
_statuses=""; _prev=""
for _a in "$@"; do
    [ "$_prev" = "--status" ] && { _statuses="$_a"; break; }
    _prev="$_a"
done
_in_status() { # $1=行 status（未指定 --status は全 status 許可）
    [ -z "$_statuses" ] && return 0
    local _s IFS=','
    for _s in $_statuses; do [ "$_s" = "$1" ] && return 0; done
    return 1
}
printf '['
first=1
while IFS='|' read -r id status labels created title; do
    [ -n "$id" ] || continue
    _in_status "$status" || continue
    [ $first -eq 1 ] || printf ','
    first=0
    if [ "$labels" = "null" ]; then
        printf '{"id":"%s","status":"%s","labels":null,"created_at":"%s","title":"%s"}' "$id" "$status" "$created" "$title"
    else
        lj=""; IFS=',' read -ra la <<< "$labels"
        lfirst=1
        for x in "${la[@]}"; do [ -n "$x" ] || continue; [ $lfirst -eq 1 ] || lj="$lj,"; lj="$lj\"$x\""; lfirst=0; done
        printf '{"id":"%s","status":"%s","labels":[%s],"created_at":"%s","title":"%s"}' "$id" "$status" "$lj" "$created" "$title"
    fi
done <<< "$STUB_ROWS"
printf ']'
STUB
    chmod +x "$bindir/bd"

    _run() { # $1=mode(report/count/dry/reratify/reratify-count) 追加 env は呼出側 export。
        local m="$1"; shift
        local flag=""
        case "$m" in
            count)          flag="--emit-count" ;;
            tripwire)       flag="--emit-tripwire" ;;
            dry)            flag="--dry-run" ;;
            reratify)       flag="--re-ratify" ;;
            reratify-count) flag="--emit-reratify-count" ;;
        esac
        ORCH_STALE_SKIP_SESSION_GATE=1 \
        ORCH_STALE_SCRIPTORIUM="$anchor" \
        ORCH_STALE_BD="$bindir/bd" \
        bash "$self" $flag 2>/dev/null
    }
    _assert_eq() { # $1=期待 $2=実 $3=名前
        if [ "$1" = "$2" ]; then echo "  ok: $3 (=$2)"; else echo "  FAIL: $3 期待=$1 実=$2" >&2; fails=$((fails+1)); fi
    }
    _assert_grep() { # $1=出力 $2=正規表現 $3=名前（マッチで ok）
        if printf '%s' "$1" | grep -qE "$2"; then echo "  ok: $3"; else echo "  FAIL: $3（/$2/ 不一致）" >&2; fails=$((fails+1)); fi
    }
    _assert_ngrep() { # $1=出力 $2=正規表現 $3=名前（非マッチで ok）
        if printf '%s' "$1" | grep -qE "$2"; then echo "  FAIL: $3（/$2/ が出た＝非検出を期待）" >&2; fails=$((fails+1)); else echo "  ok: $3"; fi
    }

    # ── 代表 fixture: 3 クラス + foreign 混入 + compound + defer 済み ──
    # now=2026-07-20 を基準（ORCH_STALE_NOW）。閾値 14d。
    #   orch-act-old : 2026-07-01（19d>14）actionable  → 停滞 ✓
    #   orch-act-new : 2026-07-18（2d<14） actionable  → 非停滞
    #   orch-held    : 2026-06-01（held）              → held-defer・M 非計上
    #   orch-fu      : 2026-06-01（follow-up）         → held-defer・M 非計上（defer 済み非計上の核）
    #   orch-seam    : 2026-06-01（seam）              → held-defer
    #   orch-cour    : 2026-06-01（courier）           → tracker-delegated
    #   orch-for     : 2026-06-01（for:sc）            → tracker-delegated（for:* mailbox）
    #   orch-cmp     : 2026-06-01（courier,follow-up） → tracker-delegated（compound・優先順で tracker）
    #   orch-defst   : 2026-06-01（label 無し・deferred status）→ held-defer（status 経路）
    #   orch-foohd   : 2026-06-01（foo,held＝allowlist が非先頭） → held-defer（multi-label separator 衝突回帰）
    #   orch-multiact: 2026-07-01（foo,bar＝非 allowlist 2 個・19d） → actionable ∩ 停滞（created_at 破損回帰）
    #   pk-foreign   : 2026-06-01（foreign）           → 非検出（SELF_PREFIX filter）
    local rows="orch-act-old|open||2026-07-01T00:00:00Z
orch-act-new|open||2026-07-18T00:00:00Z
orch-held|open|held|2026-06-01T00:00:00Z
orch-fu|open|follow-up|2026-06-01T00:00:00Z
orch-seam|open|seam|2026-06-01T00:00:00Z
orch-cour|open|courier|2026-06-01T00:00:00Z
orch-for|open|for:sc|2026-06-01T00:00:00Z
orch-cmp|open|courier,follow-up|2026-06-01T00:00:00Z
orch-defst|deferred||2026-06-01T00:00:00Z
orch-foohd|open|foo,held|2026-06-01T00:00:00Z
orch-multiact|open|foo,bar|2026-07-01T00:00:00Z
pk-foreign|open||2026-06-01T00:00:00Z"

    local out
    out="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run report)"

    # (1) 3 クラス分類（代表各 1 件）
    _assert_grep "$out" '\[CLASS\] orch-held +held-defer +\(held' "held ラベル→held-defer"
    _assert_grep "$out" '\[CLASS\] orch-cour +tracker-delegated +\(courier' "courier→tracker-delegated"
    _assert_grep "$out" '\[CLASS\] orch-act-old +actionable +\(default' "label 無し→actionable(default)"
    _assert_grep "$out" '\[CLASS\] orch-for +tracker-delegated +\(for:sc' "for:*→tracker-delegated(mailbox)"
    _assert_grep "$out" '\[CLASS\] orch-seam +held-defer' "seam→held-defer"
    _assert_grep "$out" '\[CLASS\] orch-defst +held-defer +\(deferred status' "deferred status→held-defer"
    # (2) compound（courier,follow-up）は優先順で tracker（両属を単一化）
    _assert_grep "$out" '\[CLASS\] orch-cmp +tracker-delegated' "compound 2-label→tracker(優先順)"
    # (2b) multi-label separator 衝突回帰: allowlist label が非先頭でも取りこぼさない（foo,held→held-defer）
    _assert_grep "$out" '\[CLASS\] orch-foohd +held-defer +\(held' "multi-label 非先頭 held→held-defer(separator 衝突回帰)"
    _assert_ngrep "$out" '\[CLASS\] orch-foohd +actionable' "multi-label 非先頭 held→actionable へ誤分類しない"
    # (3) foreign 非検出（SCOPE）
    _assert_ngrep "$out" 'pk-foreign' "foreign 混入 pk- は非検出(SELF_PREFIX filter)"
    # (4) 停滞: actionable かつ >14d のみ
    _assert_grep "$out" '\[STALE\] orch-act-old .* ⚠停滞疑い' "actionable 19d→停滞疑い"
    _assert_ngrep "$out" '\[STALE\] orch-act-new' "actionable 2d→非停滞(閾値内)"
    # (4b) created_at 破損回帰: 非 allowlist 2 label の actionable は created_at が保全され正しく停滞判定
    _assert_grep "$out" '\[STALE\] orch-multiact .* ⚠停滞疑い' "multi-label actionable 19d→停滞疑い(created_at 破損回帰)"
    _assert_ngrep "$out" '\[STALE-UNKNOWN\] orch-multiact' "multi-label actionable→created_at 破損せず STALE-UNKNOWN へ落ちない"
    # (5) defer 済み（follow-up/held/seam）は M に非計上（THRESHOLD）
    _assert_ngrep "$out" '\[STALE\] orch-fu' "follow-up defer 済み→M 非計上"
    _assert_ngrep "$out" '\[STALE\] orch-held' "held→M 非計上"
    # (6) tripwire 集計: open:11(orch- のみ) actionable:3 held-defer:5 tracker:3 停滞疑い:2
    _assert_grep "$out" '\[STALE-TRIPWIRE\] open:11 actionable:3 held-defer:5 tracker:3 停滞疑い:2' "tripwire 集計"
    # (7) completeness: RED が出ていない（分類合計==total）
    _assert_ngrep "$out" 'COMPLETENESS-RED' "completeness green(分類漏れなし)"

    # ── --emit-count は M の整数のみ ──
    local cnt
    cnt="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run count)"
    _assert_eq "2" "$cnt" "--emit-count は M=2 の整数のみ"

    # ── --emit-tripwire seam（bd orch-myn0）: [STALE-TRIPWIRE] 行 1 行のみ・report の同一 pass 由来で byte 一致 ──
    local twout twlines
    twout="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run tripwire)"
    _assert_eq "[STALE-TRIPWIRE] open:11 actionable:3 held-defer:5 tracker:3 停滞疑い:2" "$twout" "--emit-tripwire は tripwire 行のみ"
    twlines="$(printf '%s\n' "$twout" | grep -c .)"
    _assert_eq "1" "$twlines" "--emit-tripwire は 1 行のみ（report の他行を出さない）"
    # report 内の同一行と byte 一致（同一 pass 由来＝二重実装でない証明）。
    local twinreport
    twinreport="$(printf '%s\n' "$out" | grep -F '[STALE-TRIPWIRE]')"
    _assert_eq "$twinreport" "$twout" "--emit-tripwire は report の tripwire 行と byte 一致"
    # age不明 付き（解析不能 actionable 混在）でも tripwire seam が同形で出る（consumer parser が許容すべき形）。
    local twbad
    twbad="$(STUB_ROWS="orch-bad|open||not-a-date
orch-act-old|open||2026-07-01T00:00:00Z" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run tripwire)"
    _assert_grep "$twbad" '^\[STALE-TRIPWIRE\] open:2 actionable:2 held-defer:0 tracker:0 停滞疑い:1 age不明:1$' "--emit-tripwire は age不明 付き形も emit"

    # ── fail-closed: bd read 失敗（BD_FAIL=1）は tripwire 行を出さない（「全クラス 0 件」と融合しない・self-review#1/#2） ──
    local tw_fail
    tw_fail="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_FAIL=1 _run tripwire)"
    _assert_ngrep "$tw_fail" '^\[STALE-TRIPWIRE\] ' "bd 失敗→正規 tripwire 行を出さない(偽 all-clear 封鎖)"
    _assert_ngrep "$tw_fail" 'open:0' "bd 失敗→open:0 を名乗らない"
    _assert_grep "$tw_fail" '^\[STALE-TRIPWIRE-UNKNOWN\] ' "bd 失敗→UNKNOWN marker（consumer の正規形に非一致）"
    # ── 弁別が空虚でない: 空台帳（rc=0・rows 空）は従来どおり open:0 の正規 tripwire 行を emit する ──
    local tw_empty
    tw_empty="$(STUB_ROWS="" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run tripwire)"
    _assert_eq "[STALE-TRIPWIRE] open:0 actionable:0 held-defer:0 tracker:0 停滞疑い:0" "$tw_empty" "空台帳(rc=0)→open:0 を emit（bd 失敗と弁別・非空虚）"
    # ── byte 不変の据置: count/report は rc を参照しない（bd 失敗→従来どおり 0 / STALE-NONE） ──
    local cnt_fail
    cnt_fail="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_FAIL=1 _run count)"
    _assert_eq "0" "$cnt_fail" "bd 失敗でも --emit-count は従来挙動 0（A2 byte 不変の据置）"
    # ── fail-closed の 2 本目の trigger: bd rc=0 でも jq parse 失敗（BD_BADJSON）は UNKNOWN へ倒す ──
    #   BD_FAIL は bd rc≠0 経路しか叩かないため、これが無いと jq 段の rc を捨てる変異（`_rows_from_json || true` /
    #   rc を bd 側だけで採る refactor）が in-band moat を素通りする（bats 非同伴 host では本 self-test が唯一の網）。
    local tw_badjson
    tw_badjson="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_BADJSON=1 _run tripwire)"
    _assert_ngrep "$tw_badjson" '^\[STALE-TRIPWIRE\] ' "jq parse 失敗→正規 tripwire 行を出さない(偽 all-clear 封鎖)"
    _assert_ngrep "$tw_badjson" 'open:0' "jq parse 失敗→open:0 を名乗らない"
    _assert_grep "$tw_badjson" '^\[STALE-TRIPWIRE-UNKNOWN\] ' "jq parse 失敗→UNKNOWN marker（bd rc=0 でも融合しない）"
    # ── 同一 pass・invocation 増ゼロ の直接 teeth: bd 呼出回数を数える（出力の byte 一致では二重 pass を弁別不能） ──
    local twlog replog n_tw_inv n_rep_inv
    twlog="$tmp/bd-inv-tripwire"; replog="$tmp/bd-inv-report"
    rm -f "$twlog" "$replog"
    STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_LOG="$twlog" _run tripwire >/dev/null
    STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_LOG="$replog" _run report >/dev/null
    n_tw_inv="$( [ -f "$twlog" ] && grep -c . "$twlog" || echo 0 )"
    n_rep_inv="$( [ -f "$replog" ] && grep -c . "$replog" || echo 0 )"
    _assert_eq "1" "$n_tw_inv" "--emit-tripwire の bd 呼出は 1 回（invocation 増ゼロ）"
    _assert_eq "$n_rep_inv" "$n_tw_inv" "tripwire の bd 呼出回数は report と同数（同一 pass）"

    # ── mutation 非空虚(a): 閾値を巨大化すると停滞 0（gate が効いている証明） ──
    local cnt_hi
    cnt_hi="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-07-20T00:00:00Z" ORCH_STALE_THRESHOLD_DAYS=9999 _run count)"
    _assert_eq "0" "$cnt_hi" "閾値9999→停滞0(gate 実効・非空虚)"

    # ── mutation 非空虚(b): now を未来へ飛ばすと act-new も停滞化（年齢計算が生きている） ──
    local cnt_future
    cnt_future="$(STUB_ROWS="$rows" ORCH_STALE_NOW="2026-09-01T00:00:00Z" _run count)"
    _assert_eq "3" "$cnt_future" "now=09-01→actionable 3件とも停滞(年齢計算 非空虚)"

    # ── age 解析不能な actionable は [STALE-UNKNOWN]（force-fit しない） ──
    local out_bad
    out_bad="$(STUB_ROWS="orch-bad|open||not-a-date" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run report)"
    _assert_grep "$out_bad" '\[STALE-UNKNOWN\] orch-bad' "解析不能 created_at→STALE-UNKNOWN(force-fit せず)"
    _assert_ngrep "$out_bad" '\[STALE\] orch-bad ' "解析不能→停滞にも非計上"

    # ── re-ratify sweep（死角クラス・別軸・別閾値 7d・orch-cqf4 Leg-A） ──
    # now=2026-07-20・reratify threshold=7d。死角クラス ∩ age>7d のみ surface。
    #   orch-rr-cour  : courier 2026-07-01(19d)                → target(courier)
    #   orch-rr-held  : held 2026-07-01                        → target(held)
    #   orch-rr-seam  : seam 2026-07-01                        → target(seam)
    #   orch-rr-fu    : follow-up 2026-07-01                   → target(follow-up)
    #   orch-rr-coord : coord 2026-07-01                       → target(coord)
    #   orch-rr-defst : deferred status 2026-07-01            → target(deferred)
    #   orch-rr-courfor: courier,for:sc 2026-07-01            → target(courier)【override ii: courier∩for:*】
    #   orch-rr-bell  : held,needs-user 2026-07-01            → target(held)+🔔呼び鈴対象
    #   orch-rr-ng    : needs-grill,held 2026-07-01           → excluded（live 検知線・除外優先）
    #   orch-rr-fed   : federate-publish,courier 2026-07-01   → excluded（live 検知線）
    #   orch-rr-act   : label 無し 2026-07-01                 → excluded（actionable 域）
    #   orch-rr-foronly: for:sc 単独 2026-07-01               → excluded（for:* 単独は対象外）
    #   orch-rr-fresh : courier 2026-07-18(2d)                → age gate で非 surface
    #   pk-rr         : courier 2026-07-01                    → foreign 非検出
    local rr="orch-rr-cour|open|courier|2026-07-01T00:00:00Z|配送後に長期 open な courier bead
orch-rr-held|open|held|2026-07-01T00:00:00Z
orch-rr-seam|open|seam|2026-07-01T00:00:00Z
orch-rr-fu|open|follow-up|2026-07-01T00:00:00Z
orch-rr-coord|open|coord|2026-07-01T00:00:00Z
orch-rr-defst|deferred||2026-07-01T00:00:00Z
orch-rr-courfor|open|courier,for:sc|2026-07-01T00:00:00Z
orch-rr-bell|open|held,needs-user|2026-07-01T00:00:00Z
orch-rr-ng|open|needs-grill,held|2026-07-01T00:00:00Z
orch-rr-fed|open|federate-publish,courier|2026-07-01T00:00:00Z
orch-rr-act|open||2026-07-01T00:00:00Z
orch-rr-foronly|open|for:sc|2026-07-01T00:00:00Z
orch-rr-fresh|open|courier|2026-07-18T00:00:00Z
pk-rr|open|courier|2026-07-01T00:00:00Z"

    local out_rr
    out_rr="$(STUB_ROWS="$rr" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run reratify)"
    _assert_grep "$out_rr" 're-ratify sweep（死角クラス）' "re-ratify header"
    _assert_grep "$out_rr" '\[RERATIFY\] orch-rr-cour +age=19d \(courier\)' "courier 死角→target"
    _assert_grep "$out_rr" '\[RERATIFY\] orch-rr-courfor +age=19d \(courier\)' "courier∩for:*→target(override ii)"
    _assert_grep "$out_rr" '\[RERATIFY\] orch-rr-defst +age=19d \(deferred\)' "deferred status→target"
    _assert_grep "$out_rr" '\[RERATIFY\] orch-rr-bell .*🔔呼び鈴対象' "needs-user 併存→呼び鈴対象マーク"
    _assert_grep "$out_rr" '配送後に長期 open な courier bead' "title 冒頭を表示"
    _assert_ngrep "$out_rr" 'orch-rr-ng' "needs-grill 併存→除外(live 検知線・二重 surface 禁止)"
    _assert_ngrep "$out_rr" 'orch-rr-fed' "federate-publish 併存→除外(live 検知線)"
    _assert_ngrep "$out_rr" 'orch-rr-act' "actionable 域→re-ratify 対象外"
    _assert_ngrep "$out_rr" 'orch-rr-foronly' "for:* 単独→re-ratify 対象外"
    _assert_ngrep "$out_rr" 'orch-rr-fresh' "死角クラスでも age<7d は非 surface(閾値内)"
    _assert_ngrep "$out_rr" 'pk-rr' "foreign 非検出(SELF_PREFIX filter)"
    _assert_grep "$out_rr" '\[RERATIFY-TRIPWIRE\] 死角クラス re-ratify 候補:8' "re-ratify tripwire=8"

    # --emit-reratify-count は整数のみ（--emit-count と別 seam）
    local rrc
    rrc="$(STUB_ROWS="$rr" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run reratify-count)"
    _assert_eq "8" "$rrc" "--emit-reratify-count は 8 の整数のみ"

    # 既存 --emit-count 意味論の byte 不変（re-ratify fixture でも actionable stale=1=orch-rr-act のみ・14d gate）
    local rrc_stale
    rrc_stale="$(STUB_ROWS="$rr" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run count)"
    _assert_eq "1" "$rrc_stale" "--emit-count は actionable stale=1(orch-rr-act・14d gate)＝re-ratify と別軸"

    # mutation 非空虚: reratify 閾値巨大化 → 候補 0（死角 gate が実効）
    local rrc_hi
    rrc_hi="$(STUB_ROWS="$rr" ORCH_STALE_NOW="2026-07-20T00:00:00Z" ORCH_STALE_RERATIFY_THRESHOLD_DAYS=9999 _run reratify-count)"
    _assert_eq "0" "$rrc_hi" "reratify 閾値9999→候補0(死角 gate 実効・非空虚)"

    # re-ratify created_at 解析不能な死角クラスは [RERATIFY-UNKNOWN]（force-fit しない）
    local out_rrbad
    out_rrbad="$(STUB_ROWS="orch-rrbad|open|courier|not-a-date" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run reratify)"
    _assert_grep "$out_rrbad" '\[RERATIFY-UNKNOWN\] orch-rrbad' "re-ratify 解析不能→RERATIFY-UNKNOWN"
    _assert_ngrep "$out_rrbad" '\[RERATIFY\] orch-rrbad ' "re-ratify 解析不能→候補にも非計上"

    # 空 graceful（死角クラス 0 件）→ RERATIFY-NONE・tripwire 候補:0
    local out_rrnone
    out_rrnone="$(STUB_ROWS="orch-rr-act|open||2026-07-01T00:00:00Z" ORCH_STALE_NOW="2026-07-20T00:00:00Z" _run reratify)"
    _assert_grep "$out_rrnone" '\[RERATIFY-NONE\]' "死角クラス 0→RERATIFY-NONE"
    _assert_grep "$out_rrnone" '\[RERATIFY-TRIPWIRE\] 死角クラス re-ratify 候補:0' "re-ratify tripwire=0(空 graceful)"

    # ── fail-open: bd 失敗（BD_FAIL）は空台帳（RERATIFY-NONE）と弁別して「判定不能」note（acceptance(7) の bd 明示） ──
    local out_rrbd
    out_rrbd="$(STUB_ROWS="$rr" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_FAIL=1 _run reratify)"
    _assert_grep "$out_rrbd" '判定不能（bd read 失敗' "bd 失敗→判定不能(空台帳と弁別)"
    _assert_ngrep "$out_rrbd" '\[RERATIFY-NONE\]' "bd 失敗→RERATIFY-NONE へ silent 畳み込みしない"
    local rrbd_cnt
    rrbd_cnt="$(STUB_ROWS="$rr" ORCH_STALE_NOW="2026-07-20T00:00:00Z" BD_FAIL=1 _run reratify-count)"
    _assert_eq "" "$rrbd_cnt" "bd 失敗の --emit-reratify-count は無出力(整数不能時契約)"

    # ── fail-open: now 解決不能の count も無出力（date 障害 × count 分岐・整数 seam 契約の残る一角） ──
    local rrnow_cnt
    rrnow_cnt="$(STUB_ROWS="$rr" ORCH_STALE_NOW="not-a-valid-date" _run reratify-count)"
    _assert_eq "" "$rrnow_cnt" "now 解決不能の --emit-reratify-count は無出力(date 障害 × count)"

    # ── self-scope reject（skip せず・cwd 台帳が orch でない）──
    local foreign="$tmp/foreign"; mkdir -p "$foreign/.beads"
    printf '{"dolt_database":"un"}\n' > "$foreign/.beads/metadata.json"
    ( cd "$foreign" && ORCH_STALE_SCRIPTORIUM="$anchor" ORCH_STALE_BD="$bindir/bd" bash "$self" >/dev/null 2>&1 )
    _assert_eq "1" "$?" "self-scope reject(foreign cwd)→exit1"

    # ── leak battery（F3・orch-cqf4 Leg-A public-safe hardening）────────────────────────
    # engine は PUBLIC 配布物ゆえ、本 diff で追加した re-ratify 関数群（declare -f で live 抽出＝hermetic・base 非依存）
    # に deploy 主体名 / 内部短名 codename / 絶対 deploy-path を混入していないことを 4 系統 fail-closed で assert する。
    # 実 leak は 0（admin 実測）＝battery は保険。緑=歯無しの取り違えを各系統 1 mutation（positive fixture 注入→RED）で塞ぐ。
    #   (2) 短名は bare codename のみ検出しハイフン付き ledger-ID（foreign fixture pk-xxx / un-xxx）は非該当
    #       （ハイフンを token 文字に含める＝short-name leak の本来意味・pre-existing foreign fixture を誤爆しない）。
    _leak_scan() {  # $1=text : leak 検出→系統名を echo し rc=1 / clean→rc=0
        local _t="$1"
        # ★自己参照回避（realname 系統）: 兄弟 literal も char class で分断し、公開 source へ verbatim 識別子を残さない
        #   （`black[0-9]`/deploy-path 分断と一貫。分断後も real leak（実 codename/実ホスト名/email 断片の実出現）は
        #   依然マッチ＝検出器の歯は不変・acceptance-6 の literal grep=0 を realname 兄弟にも及ぼす）。
        grep -qwE 'shu[u]5|black[0-9]|phit[o]|ipath[o]|doobido[o]|blackco[w]|gmai[l]' <<<"$_t" && { echo realname; return 1; }
        grep -qE '(^|[^-A-Za-z0-9_])(pk|scp|un|scm|cs)([^-A-Za-z0-9_]|$)' <<<"$_t" && { echo shortname; return 1; }
        # ★自己参照回避: 検出器パターン自身が acceptance-6 の deploy-path grep に自己ヒットしないよう、対象 literal を
        #   正規表現 character class で分断する（`scriptoriu[m]` は real leak を変わらず検出・grader の literal grep には非マッチ）。
        grep -qE 'local-projects/scriptoriu[m]|/home/[a-z]' <<<"$_t" && { echo deploypath; return 1; }
        return 0
    }
    # ★sample には run_scan も含める（sc-pik7 の --emit-tripwire seam は run_scan 内に入ったため、含めないと
    #   本 diff の追加行が恒久 moat の射程外に落ちる＝出荷後の port が leak 検査を素通りする）。
    local _lk_sample; _lk_sample="$(declare -f _stale_bd_json _rows_from_json _reratify_target run_reratify run_scan)"
    if _leak_scan "$_lk_sample" >/dev/null; then echo "ok: leak-battery: scan/re-ratify 関数群は realname/shortname/deploypath clean"
    else echo "FAIL: leak-battery: scan/re-ratify 関数群に leak（系統=$(_leak_scan "$_lk_sample")）" >&2; fails=$((fails+1)); fi
    _inj="shu""u5"; if _leak_scan "$_lk_sample"$'\nleaked by '"$_inj"$' here\n'    >/dev/null; then echo "FAIL: leak-battery realname 系統に歯が無い（${_inj} 見逃し）" >&2; fails=$((fails+1)); else echo "ok: leak-battery realname 系統に歯あり（${_inj} mutation を RED 化）"; fi
    if _leak_scan "$_lk_sample"$'\nthe un project note\n'     >/dev/null; then echo "FAIL: leak-battery shortname 系統に歯が無い（bare un 見逃し）" >&2; fails=$((fails+1)); else echo "ok: leak-battery shortname 系統に歯あり（bare un mutation を RED 化）"; fi
    if _leak_scan "$_lk_sample"$'\nfallback=/home/someone/x\n' >/dev/null; then echo "FAIL: leak-battery deploypath 系統に歯が無い（/home/ 見逃し）" >&2; fails=$((fails+1)); else echo "ok: leak-battery deploypath 系統に歯あり（/home/ mutation を RED 化）"; fi
    # 系統3 dangling-lib: 本 script が source する共有 lib（orch_anchor.sh / orch_session.sh）の実在検証 + 非実在 mutation。
    _leak_libcheck() { [ -r "$1" ]; }
    if _leak_libcheck "$_ORCH_ANCHOR_LIB" && _leak_libcheck "$_ORCH_SESSION_LIB"; then echo "ok: leak-battery dangling-lib: source 先 orch_anchor.sh / orch_session.sh は実在"
    else echo "FAIL: leak-battery dangling-lib: source 先 lib が dangling（$_ORCH_ANCHOR_LIB / $_ORCH_SESSION_LIB）" >&2; fails=$((fails+1)); fi
    if _leak_libcheck "$tmp/nonexistent-lib-$$.sh"; then echo "FAIL: leak-battery dangling-lib 系統に歯が無い（非実在 lib を実在判定）" >&2; fails=$((fails+1)); else echo "ok: leak-battery dangling-lib 系統に歯あり（非実在 lib mutation を RED 化）"; fi

    if [ "$fails" -eq 0 ]; then
        echo "orch-stale-scan --self-test: PASS（全シナリオ green）"
        return 0
    fi
    echo "orch-stale-scan --self-test: FAIL（$fails 件）" >&2
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
MODE="report"
while [ $# -gt 0 ]; do
    case "$1" in
        --emit-count)          MODE="count"; shift ;;
        --emit-tripwire)       MODE="tripwire"; shift ;;
        --re-ratify)           MODE="reratify"; shift ;;
        --emit-reratify-count) MODE="reratify-count"; shift ;;
        --dry-run)             MODE="dry"; shift ;;
        --self-test)           MODE="selftest"; shift ;;
        -h|--help)             usage 0 ;;
        --*)                   echo "orch-stale-scan: 不明なオプション: $1（--emit-count / --emit-tripwire / --re-ratify / --emit-reratify-count / --dry-run / --self-test / --help）" >&2; usage 1 ;;
        *)                     echo "orch-stale-scan: 位置引数は取りません: $1" >&2; usage 1 ;;
    esac
done

# self-test は self-scope gate の対象外（hermetic fixture 内で完結）。
if [ "$MODE" = "selftest" ]; then
    run_self_test; exit $?
fi

# self-scope gate（誤台帳起動を fail-closed で弾く・guard / clean-state-probe と一貫）。
if [ "${ORCH_STALE_SKIP_SESSION_GATE:-}" != "1" ]; then
    DB="$(_ledger_dolt_database "$PWD")"
    if [ "$DB" != "$SELF_PREFIX" ]; then
        echo "orch-stale-scan: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
        echo "  orchestrator session（cwd=orchestrator anchor）から実行せよ。self-scope の fail-closed。" >&2
        exit 1
    fi
fi

# jq は report/count/**tripwire**/dry では hard requirement（fail-closed・byte 不変・clean-state-probe と同型 F1）。
#   ★tripwire は `*)` の fail-closed（exit 1）へ落ちるのが正＝count/report と同じ hard requirement で、fail-open 側の
#     reratify 群へは混ぜない（bd orch-myn0 acceptance A3・分類不能を『内訳 0』と騙らない）。
#   re-ratify 新モードは fail-open（jq 失敗でも exit 0 +「判定不能」note・count は無出力＝orch-cqf4 acceptance(7)）。
if ! command -v jq >/dev/null 2>&1; then
    case "$MODE" in
        reratify)
            echo "orch-stale-scan --re-ratify: 判定不能（jq が PATH に無く bd JSON 解析不能・fail-open）— read-only surfacing のみ（exit 0）"
            exit 0 ;;
        reratify-count)
            exit 0 ;;  # 整数不能時 無出力（count seam 契約）
        *)
            echo "orch-stale-scan: jq が PATH に無い＝bd JSON を解析できず分類不能（fail-closed）" >&2
            exit 1 ;;
    esac
fi

# anchor 解決（engine 版・scan/dry/report path 専用）: env override > 共有 lib _resolve_scriptorium（ORCH_ANCHOR /
# ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き）。解決不能は fail-loud（deploy-layout 依存の hardcode fallback は
# engine では持たない）。--self-test / --help / self-scope reject を巻き添えにしないよう self-scope gate の後に置く。
SCRIPTORIUM="${ORCH_STALE_SCRIPTORIUM:-$(_resolve_scriptorium || true)}"
if [ -z "$SCRIPTORIUM" ]; then
    echo "orch-stale-scan: anchor 解決不能（fail-loud）: env ORCH_STALE_SCRIPTORIUM / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ（engine は hardcode fallback を持たない）。" >&2
    exit 1
fi

case "$MODE" in
    dry)            run_dry_run ;;
    count)          run_scan count ;;
    tripwire)       run_scan tripwire ;;
    report)         run_scan report ;;
    reratify)       run_reratify report ;;
    reratify-count) run_reratify count ;;
esac

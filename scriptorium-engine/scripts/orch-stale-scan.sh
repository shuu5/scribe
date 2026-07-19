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
#   env seam（ORCH_RESUME_STALE_SCAN）経由で本 script を `--emit-count` invoke する形に限定し（scan LOGIC の
#   単一 SSOT を本 script が持ち fetch 側は compose のみ）、workinprogress hook へ勝手に足さない（越境=二重 surface）。
#
# 使い方─────────────────────────────────────────────────────────────────────────────────────────────
#   scripts/orch-stale-scan.sh              # 全 open を分類し停滞疑いを surface（人間可読レポート・常に exit 0）
#   scripts/orch-stale-scan.sh --emit-count # 停滞疑い M（actionable ∩ created_at>閾値）の整数のみを stdout へ（seam 用）
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

# 自台帳 orch- の open+deferred bead を "id|status|labels_csv|created_at" 行（| 区切り）で emit（read-only・jq 必須）。
#   母集団は `--status open,deferred`＝bd-native に defer された bead も held-defer クラスとして surface する（deferred
#   は held-defer へ分類され actionable にはならない＝停滞 gate 対象外ゆえ M は不変・re-ratify 起点にだけ載る）。
#   連結 substrate hydrate で foreign copy も返るため SELF_PREFIX で filter。labels:null は空 CSV へ潰す。
#   bd read は anchor へ cd してから叩く（worktree の `.beads/embeddeddolt` 不在で空/foreign を返す罠を回避・
#   orch-rebrief-fetch と同型の cwd 非依存原則）。
#   フィールド区切りは `|`（パイプ）＝**非空白**を使う（tab は空白ゆえ read の IFS 畳み込みで空 labels フィールドが
#   消え created_at が labels 列へ滑り込む off-by-one bug を招く）。`|` は bd データ（id=orch-[a-z0-9]/status=語/
#   label=[a-z:-]/created_at=RFC3339）に出現しないため衝突しない・labels 内の複数値は "," 連結ゆえ | と非干渉。
_open_rows() {
    ( cd "$SCRIPTORIUM" 2>/dev/null && "$BD" list --status open,deferred --json --no-pager --limit 0 2>/dev/null ) \
        | jq -r --arg p "$SELF_PREFIX" '
            .[]? | select(.id | startswith($p + "-"))
            | [ .id, (.status // ""), ((.labels // []) | join(",")), (.created_at // "") ]
            | join("|")' 2>/dev/null
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
# scan 本体: 全 open を分類し、actionable のみに created_at 年齢 gate を適用して M を算出。
#   $1="report"（人間可読・stdout 全出力）| "count"（M の整数のみ）。副作用ゼロ。
#   戻り値経由で M を返せないため、report は stdout へ・count は M のみ stdout へ。
# ─────────────────────────────────────────────────────────────────────────────
run_scan() {
    local mode="$1"
    local rows now_epoch
    rows="$(_open_rows)"
    now_epoch="$(_now_epoch)"

    local total=0 n_action=0 n_held=0 n_tracker=0 stale=0 unknown=0
    local action_ids="" held_ids="" tracker_ids=""
    local -a class_lines=() stale_lines=() unknown_lines=()

    local id status labels created cls reason
    while IFS='|' read -r id status labels created; do
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

    if [ "$mode" = "count" ]; then
        printf '%s\n' "$stale"
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
    echo "[STALE-TRIPWIRE] open:$total actionable:$n_action held-defer:$n_held tracker:$n_tracker 停滞疑い:$stale$([ "$unknown" -ne 0 ] && printf ' age不明:%s' "$unknown")"
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
# --status <csv> を尊重して実 bd の相互排他 status 挙動を模す（指定 status の行のみ emit・未指定は全件）。
#   ★deferred 行は query が open,deferred を要求したときだけ返る＝deferred は deferred-scan 由来で返る（母集団が
#   --status open のみだと deferred は返らない＝deferred branch を vacuous に green にしない現実的 stub）。
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
while IFS='|' read -r id status labels created; do
    [ -n "$id" ] || continue
    _in_status "$status" || continue
    [ $first -eq 1 ] || printf ','
    first=0
    if [ "$labels" = "null" ]; then
        printf '{"id":"%s","status":"%s","labels":null,"created_at":"%s"}' "$id" "$status" "$created"
    else
        lj=""; IFS=',' read -ra la <<< "$labels"
        lfirst=1
        for x in "${la[@]}"; do [ -n "$x" ] || continue; [ $lfirst -eq 1 ] || lj="$lj,"; lj="$lj\"$x\""; lfirst=0; done
        printf '{"id":"%s","status":"%s","labels":[%s],"created_at":"%s"}' "$id" "$status" "$lj" "$created"
    fi
done <<< "$STUB_ROWS"
printf ']'
STUB
    chmod +x "$bindir/bd"

    _run() { # $1=mode(report/count/dry) 追加 env は呼出側 export。
        local m="$1"; shift
        local flag=""
        case "$m" in count) flag="--emit-count" ;; dry) flag="--dry-run" ;; esac
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

    # ── self-scope reject（skip せず・cwd 台帳が orch でない）──
    local foreign="$tmp/foreign"; mkdir -p "$foreign/.beads"
    printf '{"dolt_database":"un"}\n' > "$foreign/.beads/metadata.json"
    ( cd "$foreign" && ORCH_STALE_SCRIPTORIUM="$anchor" ORCH_STALE_BD="$bindir/bd" bash "$self" >/dev/null 2>&1 )
    _assert_eq "1" "$?" "self-scope reject(foreign cwd)→exit1"

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
        --emit-count) MODE="count"; shift ;;
        --dry-run)    MODE="dry"; shift ;;
        --self-test)  MODE="selftest"; shift ;;
        -h|--help)    usage 0 ;;
        --*)          echo "orch-stale-scan: 不明なオプション: $1（--emit-count / --dry-run / --self-test / --help）" >&2; usage 1 ;;
        *)            echo "orch-stale-scan: 位置引数は取りません: $1" >&2; usage 1 ;;
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

# jq は hard requirement（分類・filter に必須・clean-state-probe と同型 F1）。
if ! command -v jq >/dev/null 2>&1; then
    echo "orch-stale-scan: jq が PATH に無い＝bd JSON を解析できず分類不能（fail-closed）" >&2
    exit 1
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
    dry)    run_dry_run ;;
    count)  run_scan count ;;
    report) run_scan report ;;
esac

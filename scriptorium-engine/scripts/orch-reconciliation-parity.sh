#!/usr/bin/env bash
# orch-reconciliation-parity.sh — published-interface parity 検出（bd orch-b4b・実装1+実装2）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   federated reconciliation の §27「reconciliation = published-interface + reconciliation,
#   NOT deep-introspection」を 二層の第一層（常時安価な published-interface 照合）として
#   実体化する。orchestrator が各 project から ingest した記録（自台帳 orch- の構造化公開面）と、
#   各 project が federation 候補として公開した surface（foreign 台帳の公開ラベル）を foreign
#   read-only で突合し、parity gap（取り込み漏れ / 公開し戻し漏れ）と鮮度 drift を surface する。
#
#   本 script は orchestrator-owned reconciliation の detect 面に徹する（D6 notice 原則）:
#   検出 -> 人間向け notice まで。起票しない・foreign を mutate しない・AI 自律 dispatch しない。
#   live 送達（tmux inject）は既存 courier primitive（orch-discovery-nudge.sh・orch-s8c）の領分で
#   あり本 script では新規送達コードを作らない（--notice は人間向け print に徹し、live inject は
#   admin/courier が既存 primitive で wire する＝runbook 実装2「新規送達コードを作らない」）。
#
# parity モデル（foreign bead id をキーに二集合を突合）─────────────────────────────
#   公開面の定義は C1 の published-surface 定義に従う暫定として、当面は bd 専用ラベルを最小
#   公開面とする（folio inventory は将来 rollout=orch-32e で主へ昇格＝二系統・D1 段階移行）。
#
#   集合 P（orchestrator published ingest-ledger surface・自台帳 orch-）:
#     ラベル $ORCH_RECON_PUBLISH_LABEL（既定 reconcile-published・完全一致）を持つ非 closed
#     orch- bead。各 bead は cross-rig dep（depends_on_id が foreign prefix）で ingest 元 foreign
#     bead を指す。map: foreign_id -> { orch_id, updated_at }。
#
#   集合 F（各 project の federation 公開候補・foreign 台帳・read-only）:
#     ラベル $ORCH_RECON_FOREIGN_LABEL（既定 federate-publish・完全一致）を持つ非 closed
#     foreign bead。map: foreign_id -> { updated_at, project }。
#
#   parity 判定（foreign_id をキーに）:
#     - f in F かつ f not-in P                   -> GAP   : project が公開したが orchestrator 未取込
#                                                  （= 「未 ingest 候補」・取り込み漏れ）。
#     - f in F かつ f in P                        -> OK    : 取込済（= 「ingest 済」・non-gap）。
#     - f in P かつ P[f].updated < F[f].updated   -> DRIFT : 取込後に foreign が更新（公開面が stale）。
#     - f in P かつ f not-in F                    -> ORPHAN: 公開し戻したが foreign 候補が消失/非公開化
#                                                  （= 逆 leg drift・公開面が現実から乖離）。
#
# 公開面は exact-match label（regex 禁止・load-bearing）─────────────────────────────
#   seam(5) の主眼は peer-notes の ad-hoc 正規表現走査を構造化 published surface 照合へ移すこと
#   ゆえ、検出側も regex に退行してはならない。bd の --label 完全一致に委ねるだけでなく、本 script
#   は取得 bead の labels 配列に対象ラベルが 文字列完全一致で含まれるか を自前で再検査する
#   （bd が over-return しても部分一致 surface を誤検出しない＝二重の exact-match 防壁）。
#
# write-isolation（不可侵の核）──────────────────────────────────────────────────
#   foreign 台帳は `bd -C <path> list`（read-only）でのみ読む。foreign を `bd update` しない。
#   自台帳 orch- も本 script は read のみ（list）＝write しないので bdw 不要（read 素通し）。
#
# self-scope（誤台帳 scan の防止）────────────────────────────────────────────────
#   `bd list` は cwd の台帳に作用する。非 orch 台帳から走らせると誤集計するため、起動時に cwd から
#   walk-up した最初の .beads/metadata.json の dolt_database が orch か検査し、非該当なら何もせず
#   非 0 で抜ける（orch-hydrate / discovery-nudge / guard と同一 self-scope・同一 SELF_PREFIX）。
#
# 予約 seam（実装は派生 bead・本 script は受け口の一文だけ持つ・D2/D5）──────────────
#   (a) completeness gate seam: 「どの公開面にも載らない知識（bead 化されず永久不可視になる知識）」
#       の検出受け口。published-interface parity は『載った物同士』の照合ゆえ載せ忘れを原理的に
#       見られない。受け口は _completeness_seam()（下方・stub）。実装 = 派生 bead (i)。
#   (b) scribe enforce seam: 公開面鮮度を相手側 lint/skill で強制する受け口。本 script は
#       orchestrator 側 detect のみ＝相手側 enforce は cross-project 調整ゆえ courier 経由で別 bead。
#       受け口は本ヘッダ + runbook「予約 seam」節。実装 = 派生 bead (ii)。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）  parity レポート（人間向け text）を stdout に。gap/drift があれば非 0（fail-loud）。
#   --notice  gap/drift を人間向け notice 形式で print（discovery-nudge と同じ print-notice 様式・
#             live inject はしない＝新規送達コードを作らない）。
#   --json    機械可読 JSON（後続自動化・誤検出率実測=派生 bead iii 用）。常に exit 0（解析は呼出側）。
#   --dry-run 実 bd を呼ばず、解決した project list / ラベル / 実行予定 bd コマンドを print のみ。
#   --help    使い方（このヘッダブロック）。
#
# env override（主に self-test 用・他 orch-* script と同表現＝実体パス/設定差替）:
#   ORCH_RECON_BD            scan に使う bd 実体パス（既定: bd）。fake ledger を hermetic に食わせる。
#   ORCH_RECON_PROJECTS      foreign project list を全置換（空白区切り `name=path` 列・path に空白不可）。
#                            未指定なら private 配備層 registry overlay（scripts/lib/orch-projects.sh・
#                            配備層が配置した場合のみ・不在/空は fail-loud）。
#   ORCH_RECON_PUBLISH_LABEL orchestrator published surface ラベル（既定: reconcile-published）。
#   ORCH_RECON_FOREIGN_LABEL foreign federation 公開候補ラベル（既定: federate-publish）。
#
# 検証: tests/scenarios/orch-reconciliation-parity.bats（durable・hermetic＝bd を PATH/env スタブで
#   差替・実 dolt 不使用）と worktree-local selftest-orch-b4b.local.sh（untracked・fail-closed）。
#
# SSOT: docs/orch-b4b-reconciliation-runbook.md（実装手順）/ bd orch-b4b（設計決定 D1-D6）/ 親 orch-4r3。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard と同一値を共有）。
SELF_PREFIX="orch"

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・orch-vo2 で 5 script も統一） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。旧 inline _resolve_dolt_database は
# _json_is_valid gate を欠く drift（破損 orch-token metadata で誤 self-scope＝誤台帳起動しうる）だったため
# 撤去し、gate 済みの共有関数へ統一する（orch-vo2 acceptance・orch-degraded-watch と同型）。self-scope gate は
# fail-closed 方針ゆえ、gate 追加で破損 orch-token metadata は self とみなされず refuse 側へ倒れる（安全側）。
# ★実 script 位置（BASH_SOURCE 相対）で解決するので bats/--self-test が実 lib を確実に見つける。
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_ORCH_SESSION_LIB="$_SCRIPT_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-reconciliation-parity: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# 公開面ラベル（exact-match・env で差替可）。
PUBLISH_LABEL="${ORCH_RECON_PUBLISH_LABEL:-reconcile-published}"
FOREIGN_LABEL="${ORCH_RECON_FOREIGN_LABEL:-federate-publish}"

# bd 実体（env で差替可・self-test 用）。
BD="${ORCH_RECON_BD:-bd}"

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
MODE="report"   # report | notice | json
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --notice)  MODE="notice" ;;
        --json)    MODE="json" ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            # 先頭コメントブロック（shebang 直後〜最初の非コメント行手前）を help として出す
            # （行番号 pin せず最初の非コメント行で打ち切る＝ヘッダ伸縮に追従・orch-hydrate と同型）。
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "orch-reconciliation-parity: unknown arg: $arg（--notice / --json / --dry-run / --help）" >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# project list（共有 lib＝二重 SSOT 回避・orch-2ax。env override 優先）
# ─────────────────────────────────────────────────────────────────────────────
PROJECTS=()
if [ -n "${ORCH_RECON_PROJECTS:-}" ]; then
    read -ra PROJECTS <<< "$ORCH_RECON_PROJECTS"
else
    # private 配備層 registry overlay（engine は値の hardcode を持たない・不在/空は fail-loud）。
    _LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib"
    DEFAULT_PROJECTS=()
    if [ -f "$_LIB_DIR/orch-projects.sh" ]; then
        # shellcheck source=lib/orch-projects.sh
        # shellcheck disable=SC1091
        source "$_LIB_DIR/orch-projects.sh"
    fi
    if [ "${#DEFAULT_PROJECTS[@]}" -eq 0 ]; then
        echo "orch-reconciliation-parity: project list 未供給（fail-loud）: env ORCH_RECON_PROJECTS を設定するか、" >&2
        echo "  private 配備層 registry を $_LIB_DIR/orch-projects.sh へ配置すること（engine は値の hardcode を持たない）。" >&2
        exit 1
    fi
    PROJECTS=("${DEFAULT_PROJECTS[@]}")
fi

# ─────────────────────────────────────────────────────────────────────────────
# self-scope: cwd 台帳 dolt_database == orch でなければ何もしない（誤 scan 防止・fail-closed）
# ─────────────────────────────────────────────────────────────────────────────
# cwd/path の台帳 dolt_database の walk-up 解決（_ledger_dolt_database）は共有 lib scripts/hooks/lib/orch_session.sh
# が提供する（上で source 済み・orch-vo2）。旧 inline _resolve_dolt_database は _json_is_valid gate を欠く
# drift だったため撤去し、gate 済みの _ledger_dolt_database へ統一した（破損 orch-token metadata での誤
# self-scope を fail-closed で弾く・orch-degraded-watch と同型）。
DB="$(_ledger_dolt_database "$PWD")"
if [ "$DB" != "$SELF_PREFIX" ]; then
    echo "orch-reconciliation-parity: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
    echo "  orchestrator session（cwd=orchestrator）から実行せよ。foreign 台帳を誤 scan しない fail-closed。" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 予約 seam（実装は派生 bead・受け口のみ）
# ─────────────────────────────────────────────────────────────────────────────
# (a) completeness gate seam（派生 bead (i)）: published-interface parity は『公開面に載った物同士』
#     の照合ゆえ、そもそもどの公開面にも載らない知識（bead 化されず永久不可視）を原理的に検出でき
#     ない。その載せ忘れ検出は本 parity とは別述語（deep-introspection 寄り・二層の第二層=periodic
#     completeness 監査）であり、ここに受け口だけ残す。実装するな（admin 領分）。
_completeness_seam() {
    : # NOT IMPLEMENTED (orch-b4b スコープ外・派生 bead i)。published surface に載らない知識の検出。
}
# (b) scribe enforce seam（派生 bead (ii)）: 公開面の鮮度を相手側（各 project）の lint/skill で強制
#     する受け口。本 script は orchestrator 側 detect のみ。相手側 enforce は cross-project 合意が
#     要るため courier 経由で別 bead。ここでは仕様の一文として明記するに留める（実装するな）。

# ─────────────────────────────────────────────────────────────────────────────
# ヘルパ: jq で labels 配列に exact-match ラベルを持つ非 closed bead を抽出
#   出力 TSV: <id>\t<updated_at>\t<dep_foreign_csv>
#   dep_foreign_csv は dependencies[].depends_on_id のうち self prefix 以外（cross-rig dep target）を
#   カンマ連結（無ければ空）。jq 不在時は graceful degrade（labels/deps 解析不能->空集合＝fail-open）。
# ─────────────────────────────────────────────────────────────────────────────
_extract_labeled() {
    # $1 = exact label, stdin = bd list --json
    local label="$1"
    if ! command -v jq >/dev/null 2>&1; then
        echo "orch-reconciliation-parity: jq 不在のため labels/deps 解析不能（fail-open・空集合）" >&2
        return 0
    fi
    jq -r --arg L "$label" --arg SELF "$SELF_PREFIX" '
        (if type=="array" then . else (.issues // .items // []) end)
        | .[]?
        | select((.status // "") != "closed")
        | . as $b
        | (($b.labels // []) | map(select(. == $L)) | length) as $hit
        | select($hit > 0)
        | ( ($b.dependencies // [])
            | map(.depends_on_id // empty)
            | map(select(. != null and . != ""))
            | map(select((. | split("-")[0]) != $SELF))
            | join(",") ) as $foreign
        | [ ($b.id // ""), ($b.updated_at // $b.updated // ""), $foreign ] | @tsv
    ' 2>/dev/null
}

# 比較用に updated_at を秒 epoch へ（解析不能は 0＝drift 判定で安全側に倒さない＝stale 誤検出を避ける）。
_epoch() {
    local ts="$1"
    [ -z "$ts" ] && { echo 0; return; }
    date -d "$ts" +%s 2>/dev/null || echo 0
}

# ─────────────────────────────────────────────────────────────────────────────
# dry-run: 実 bd を呼ばず計画のみ
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    echo "== orch-reconciliation-parity (DRY-RUN) =="
    echo "  ledger DB       : $DB"
    echo "  bd              : $BD"
    echo "  publish label   : $PUBLISH_LABEL (exact-match)"
    echo "  foreign label   : $FOREIGN_LABEL (exact-match)"
    echo "  projects        : ${#PROJECTS[@]}"
    echo "  would run (P)    : $BD list --label $PUBLISH_LABEL --json --no-pager --limit 0   # 自台帳 orch-（read-only）"
    for entry in "${PROJECTS[@]}"; do
        name="${entry%%=*}"; path="${entry#*=}"
        echo "  would run (F:$name): $BD -C $path list --label $FOREIGN_LABEL --json --no-pager --limit 0   # foreign read-only"
    done
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 集合 P: orchestrator published surface（自台帳 orch-・read-only）
#   P_FOREIGN[foreign_id] = "orch_id|updated_epoch"
# ─────────────────────────────────────────────────────────────────────────────
declare -A P_FOREIGN=()
declare -A P_HAS_DEP=()   # orch_id -> 1（cross-rig dep を 1 本も持たない published bead の検出用）
P_SURFACE_COUNT=0

P_JSON="$("$BD" list --label "$PUBLISH_LABEL" --json --no-pager --limit 0 2>/dev/null)"
p_rc=$?
if [ "$p_rc" -ne 0 ]; then
    echo "orch-reconciliation-parity: published surface scan 失敗（$BD list --label $PUBLISH_LABEL・rc=$p_rc）" >&2
    exit 1
fi
while IFS=$'\t' read -r oid oupd ofdeps; do
    [ -z "$oid" ] && continue
    P_SURFACE_COUNT=$((P_SURFACE_COUNT + 1))
    oepoch="$(_epoch "$oupd")"
    ohad=0; [ -n "$oupd" ] && ohad=1   # timestamp 文字列が在ったか（parse 失敗=0 と 不在=0 を区別する m4）。
    if [ -z "$ofdeps" ]; then
        # published だが cross-rig dep を 1 本も持たない＝何を ingest したか不明（公開面の壊れ）。
        P_HAS_DEP["$oid"]=0
        continue
    fi
    P_HAS_DEP["$oid"]=1
    IFS=',' read -ra _fids <<< "$ofdeps"
    for fid in "${_fids[@]}"; do
        [ -z "$fid" ] && continue
        P_FOREIGN["$fid"]="$oid|$oepoch|$ohad"
    done
done <<< "$(printf '%s' "$P_JSON" | _extract_labeled "$PUBLISH_LABEL")"

# ─────────────────────────────────────────────────────────────────────────────
# 集合 F: 各 project の federation 公開候補（foreign 台帳・read-only）
#   F_CAND[foreign_id] = "project|updated_epoch"
# ─────────────────────────────────────────────────────────────────────────────
declare -A F_CAND=()
declare -A SCANNED_PREFIXES=()   # 成功スキャンした project の dolt_database prefix 集合（M1・ORPHAN 判定の
                                 # 「owning project を本当に読めたか」を foreign_id prefix で照合するため）。
F_CAND_COUNT=0
SCANNED_PROJECTS=0
SKIPPED_PROJECTS=0
ERRORED_PROJECTS=0   # .beads は在るが bd -C list が rc!=0（一過性障害等）の数。'clean' と区別して surface。

for entry in "${PROJECTS[@]}"; do
    name="${entry%%=*}"; path="${entry#*=}"
    if [ ! -d "$path/.beads" ]; then
        SKIPPED_PROJECTS=$((SKIPPED_PROJECTS + 1))
        continue   # .beads 不在＝hydrate 不能・fail-safe skip（「存在すれば」扱いの project）。
    fi
    SCANNED_PROJECTS=$((SCANNED_PROJECTS + 1))
    F_JSON="$("$BD" -C "$path" list --label "$FOREIGN_LABEL" --json --no-pager --limit 0 2>/dev/null)"
    f_rc=$?
    # foreign は read-only。**rc!=0 は silent swallow しない**（P スキャンが fail-loud なのに F だけ
    # 黙って空集合にすると『読めなかった』を『clean』に誤認させる false-negative＝orch-b4b review minor）。
    # errored として計上し stderr へ surface する（best-effort skip は維持＝nudge は止めない）。
    if [ "$f_rc" -ne 0 ]; then
        ERRORED_PROJECTS=$((ERRORED_PROJECTS + 1))
        echo "orch-reconciliation-parity: WARN: foreign scan 失敗 project=$name path=$path (rc=$f_rc) — 'clean' と区別不能ゆえ errored に計上" >&2
        continue   # errored project は SCANNED_PREFIXES に入れない＝その prefix の foreign_id は ORPHAN 確定できない（M1）。
    fi
    # 成功スキャン: この project の prefix を記録（owning project を本当に読めた印・M1）。
    # ★gate 済み _ledger_dolt_database は破損 metadata を空 db に畳む＝壊れた foreign metadata を prefix として
    #   信用せず SCANNED_PREFIXES に記録しない（保守的・ORPHAN 誤確定を避ける安全側・意味論不変の強化のみ）。
    _pfx="$(_ledger_dolt_database "$path")"
    [ -n "$_pfx" ] && SCANNED_PREFIXES["$_pfx"]=1
    while IFS=$'\t' read -r fid fupd _fdeps; do
        [ -z "$fid" ] && continue
        F_CAND_COUNT=$((F_CAND_COUNT + 1))
        fhad=0; [ -n "$fupd" ] && fhad=1
        F_CAND["$fid"]="$name|$(_epoch "$fupd")|$fhad"
    done <<< "$(printf '%s' "$F_JSON" | _extract_labeled "$FOREIGN_LABEL")"
done

# ─────────────────────────────────────────────────────────────────────────────
# parity 判定
# ─────────────────────────────────────────────────────────────────────────────
GAPS=()     # F にあり P に無い（未 ingest 候補）            : "fid\tproject"
OKS=()      # F にあり P にある（ingest 済）                 : "fid\tproject\torch_id"
DRIFTS=()   # P[f].updated < F[f].updated（公開面が stale）   : "fid\tproject\torch_id"
ORPHANS=()  # P にあり F に無い かつ owning project は読めた  : "fid\torch_id"
BROKEN=()   # published だが cross-rig dep 無し（公開面の壊れ）: "orch_id"
INDETERM=() # 評価不能（clean/orphan でない・fail-loud しない）: "fid\treason\tdetail"

# 収束テーマ「読めない/評価不能 ≠ clean/orphan」: 評価できなかったものは INDETERM へ別出しし、
# 真の parity 問題（gap/drift/orphan/broken）とも clean とも混ぜない（exit は degraded=3 で surface）。

# F 起点: GAP / OK / DRIFT / INDETERM(drift-unparseable・m4)
for fid in "${!F_CAND[@]}"; do
    fmeta="${F_CAND[$fid]}"
    IFS='|' read -r fproj fepoch fhad <<< "$fmeta"
    if [ -n "${P_FOREIGN[$fid]+x}" ]; then
        IFS='|' read -r poid pepoch ohad <<< "${P_FOREIGN[$fid]}"
        if [ "$pepoch" -gt 0 ] && [ "$fepoch" -gt 0 ]; then
            # 両 epoch 比較可能。
            if [ "$fepoch" -gt "$pepoch" ]; then
                DRIFTS+=("$fid"$'\t'"$fproj"$'\t'"$poid")
            else
                OKS+=("$fid"$'\t'"$fproj"$'\t'"$poid")
            fi
        elif { [ "$pepoch" -eq 0 ] && [ "${ohad:-0}" = "1" ]; } || { [ "$fepoch" -eq 0 ] && [ "${fhad:-0}" = "1" ]; }; then
            # timestamp は在るのに parse 不能（date 不能→0）＝鮮度を評価できない。OK に混ぜず INDETERM（m4）。
            INDETERM+=("$fid"$'\t'"drift-unparseable"$'\t'"$fproj <- $poid (timestamp parse 不能・実 drift を隠さない)")
        else
            # 双方 timestamp 不在＝鮮度データ無いが ingest 済は確定。OK（評価不能ではなく『鮮度情報なし』）。
            OKS+=("$fid"$'\t'"$fproj"$'\t'"$poid")
        fi
    else
        GAPS+=("$fid"$'\t'"$fproj")
    fi
done

# P 起点: ORPHAN か INDETERM(orphan-unreadable・M1)
#   F_CAND に無い foreign_id でも、owning project（=foreign_id prefix）が SKIPPED/ERRORED/未スキャンだと
#   『本当に消えた』のか『読めなかっただけ』か区別できない。owning project を成功スキャンした（prefix が
#   SCANNED_PREFIXES に在る）時のみ ORPHAN 確定。そうでなければ INDETERM（fail-loud しない・M1）。
for fid in "${!P_FOREIGN[@]}"; do
    if [ -z "${F_CAND[$fid]+x}" ]; then
        IFS='|' read -r poid _pe _oh <<< "${P_FOREIGN[$fid]}"
        prefix="${fid%%-*}"
        if [ -n "${SCANNED_PREFIXES[$prefix]+x}" ]; then
            ORPHANS+=("$fid"$'\t'"$poid")     # owning project を読めた上で不在＝真の orphan。
        else
            INDETERM+=("$fid"$'\t'"orphan-unreadable"$'\t'"$poid (owning project '$prefix' を読めず＝消失でなく評価不能)")
        fi
    fi
done

# published だが cross-rig dep 無し（公開面の壊れ）
for oid in "${!P_HAS_DEP[@]}"; do
    [ "${P_HAS_DEP[$oid]}" = "0" ] && BROKEN+=("$oid")
done

# jq 不在は全 labels/deps 解析を空にし issue=0=clean に誤認させる（M2）。degraded として surface。
JQ_DEGRADED=0; command -v jq >/dev/null 2>&1 || JQ_DEGRADED=1

n_gap=${#GAPS[@]}; n_ok=${#OKS[@]}; n_drift=${#DRIFTS[@]}; n_orphan=${#ORPHANS[@]}; n_broken=${#BROKEN[@]}
n_indeterm=${#INDETERM[@]}
n_issues=$((n_gap + n_drift + n_orphan + n_broken))        # 真の parity 問題（fail-loud=exit1 対象）。
# degraded=評価不能（errored project / jq 不在 / indeterminate）。clean とも parity 問題とも別軸（exit3）。
n_degraded=$((ERRORED_PROJECTS + JQ_DEGRADED + n_indeterm))

# ─────────────────────────────────────────────────────────────────────────────
# 出力
# ─────────────────────────────────────────────────────────────────────────────
_json_array() {
    # stdin: TSV 行群、$@ : 各列の key 名。jq で [{key:val,...}] へ。空入力は [] を返す。
    if ! command -v jq >/dev/null 2>&1; then echo '[]'; return; fi
    local keys_json
    keys_json="$(printf '%s\n' "$@" | jq -R . | jq -cs .)"
    jq -Rn --argjson keys "$keys_json" '
        [ inputs | select(length > 0) | (split("\t")) as $f
          | reduce range(0; ($keys|length)) as $i ({}; . + { ($keys[$i]): ($f[$i] // "") }) ]
    ' 2>/dev/null || echo '[]'
}

emit_json() {
    # 各カテゴリを TSV->JSON 配列へ。手書き JSON のクォート事故を避け jq で構築。
    if ! command -v jq >/dev/null 2>&1; then
        echo '{"error":"jq unavailable"}'; return
    fi
    local gap_j ok_j drift_j orphan_j broken_j indeterm_j
    gap_j="$(printf '%s\n' "${GAPS[@]:-}"       | _json_array foreign_id project)"
    ok_j="$(printf '%s\n' "${OKS[@]:-}"         | _json_array foreign_id project orch_id)"
    drift_j="$(printf '%s\n' "${DRIFTS[@]:-}"   | _json_array foreign_id project orch_id)"
    orphan_j="$(printf '%s\n' "${ORPHANS[@]:-}" | _json_array foreign_id orch_id)"
    broken_j="$(printf '%s\n' "${BROKEN[@]:-}"  | _json_array orch_id)"
    indeterm_j="$(printf '%s\n' "${INDETERM[@]:-}" | _json_array foreign_id reason detail)"
    jq -n \
        --argjson gap "$gap_j" --argjson ok "$ok_j" --argjson drift "$drift_j" \
        --argjson orphan "$orphan_j" --argjson broken "$broken_j" --argjson indeterminate "$indeterm_j" \
        --argjson counts "{\"gap\":$n_gap,\"ok\":$n_ok,\"drift\":$n_drift,\"orphan\":$n_orphan,\"broken\":$n_broken,\"indeterminate\":$n_indeterm,\"projects_scanned\":$SCANNED_PROJECTS,\"projects_skipped\":$SKIPPED_PROJECTS,\"projects_errored\":$ERRORED_PROJECTS,\"jq_unavailable\":$JQ_DEGRADED,\"degraded\":$n_degraded}" \
        '{counts:$counts, gap:$gap, ok:$ok, drift:$drift, orphan:$orphan, broken:$broken, indeterminate:$indeterminate}' \
        2>/dev/null || echo "{\"counts\":{\"gap\":$n_gap,\"ok\":$n_ok,\"drift\":$n_drift,\"orphan\":$n_orphan,\"broken\":$n_broken,\"indeterminate\":$n_indeterm,\"degraded\":$n_degraded}}"
}

emit_report() {
    echo "== orch-reconciliation-parity (report) =="
    echo "  ledger DB       : $DB"
    echo "  publish label   : $PUBLISH_LABEL (exact-match)   surface beads: $P_SURFACE_COUNT"
    echo "  foreign label   : $FOREIGN_LABEL (exact-match)   candidates  : $F_CAND_COUNT"
    echo "  projects        : scanned=$SCANNED_PROJECTS skipped=$SKIPPED_PROJECTS errored=$ERRORED_PROJECTS"
    [ "$ERRORED_PROJECTS" -gt 0 ] && echo "  WARN            : $ERRORED_PROJECTS project の foreign scan が失敗（rc!=0）— その分は 'clean' でなく '読めなかった'（stderr 参照）"
    [ "$JQ_DEGRADED" -eq 1 ] && echo "  WARN            : jq 不在＝labels/deps 解析不能で評価劣化（DEGRADED・'clean' と区別不能にしない・exit3）"
    echo "----------------------------------------------------------------------"
    if [ "$n_gap" -gt 0 ]; then
        echo "GAP（project 公開・orchestrator 未取込＝未 ingest 候補）: $n_gap"
        for r in "${GAPS[@]}"; do IFS=$'\t' read -r fid proj <<< "$r"; echo "  - $fid  [$proj]"; done
    fi
    if [ "$n_drift" -gt 0 ]; then
        echo "DRIFT（取込後に foreign 更新＝公開面 stale）: $n_drift"
        for r in "${DRIFTS[@]}"; do IFS=$'\t' read -r fid proj oid <<< "$r"; echo "  - $fid  [$proj] <- $oid (要 re-sync)"; done
    fi
    if [ "$n_orphan" -gt 0 ]; then
        echo "ORPHAN（公開し戻したが foreign 候補が消失/非公開化＝逆 leg drift）: $n_orphan"
        for r in "${ORPHANS[@]}"; do IFS=$'\t' read -r fid oid <<< "$r"; echo "  - $fid <- $oid"; done
    fi
    if [ "$n_broken" -gt 0 ]; then
        echo "BROKEN（published だが cross-rig dep 無し＝公開面の壊れ）: $n_broken"
        for r in "${BROKEN[@]}"; do echo "  - $r"; done
    fi
    if [ "$n_indeterm" -gt 0 ]; then
        echo "INDETERMINATE（評価不能＝clean でも orphan でもない・要再評価）: $n_indeterm"
        for r in "${INDETERM[@]}"; do IFS=$'\t' read -r fid reason detail <<< "$r"; echo "  - $fid [$reason] $detail"; done
    fi
    echo "----------------------------------------------------------------------"
    echo "summary: gap=$n_gap ok=$n_ok drift=$n_drift orphan=$n_orphan broken=$n_broken (issues=$n_issues) | degraded=$n_degraded (errored=$ERRORED_PROJECTS jq_unavailable=$JQ_DEGRADED indeterminate=$n_indeterm)"
}

emit_notice() {
    # discovery-nudge と同じ print-notice 様式（live inject はしない＝新規送達コードを作らない）。
    # 「評価不能 ≠ clean」: issue が無くても degraded があれば no-op と言わず degraded を surface する。
    if [ "$n_issues" -eq 0 ] && [ "$n_degraded" -eq 0 ]; then
        echo "no reconciliation parity issues — no-op"
        return
    fi
    echo "=== orchestrator courier / reconciliation parity notice ==="
    for r in "${GAPS[@]:-}"; do
        [ -z "$r" ] && continue
        IFS=$'\t' read -r fid proj <<< "$r"
        echo "NOTICE [gap]: $fid（$proj が federation 公開・orchestrator 未取込）— orch- へ ingest（cross-rig dep）して公開し戻せ"
    done
    for r in "${DRIFTS[@]:-}"; do
        [ -z "$r" ] && continue
        IFS=$'\t' read -r fid proj oid <<< "$r"
        echo "NOTICE [drift]: $fid（$proj）が $oid 取込後に更新 — bd repo sync で再 hydrate し公開面を更新せよ"
    done
    for r in "${ORPHANS[@]:-}"; do
        [ -z "$r" ] && continue
        IFS=$'\t' read -r fid oid <<< "$r"
        echo "NOTICE [orphan]: $oid の公開面が指す $fid が foreign に無い — 公開面の整合を確認せよ"
    done
    for r in "${BROKEN[@]:-}"; do
        [ -z "$r" ] && continue
        echo "NOTICE [broken]: $r は published だが cross-rig dep 無し — 何を ingest したか公開面が示せていない"
    done
    for r in "${INDETERM[@]:-}"; do
        [ -z "$r" ] && continue
        IFS=$'\t' read -r fid reason detail <<< "$r"
        echo "NOTICE [indeterminate]: $fid（$reason）評価不能 — $detail（clean/orphan と断定しない・再評価せよ）"
    done
    [ "$ERRORED_PROJECTS" -gt 0 ] && echo "NOTICE [degraded]: $ERRORED_PROJECTS project の foreign scan 失敗（rc!=0）— その分は評価不能（再実行/foreign 復旧後に再評価）"
    [ "$JQ_DEGRADED" -eq 1 ] && echo "NOTICE [degraded]: jq 不在で評価劣化 — 'clean' と区別不能にしない（jq 導入後に再評価）"
    echo "(notice のみ・自動 dispatch ではありません＝action は人間判断。live 送達は orch-discovery-nudge 系 primitive の領分)"
}

case "$MODE" in
    json)   emit_json; exit 0 ;;                 # 解析は呼出側＝常に exit 0（counts.degraded で判別）
    notice) emit_notice ;;
    *)      emit_report ;;
esac

# exit scheme（収束テーマ「評価不能 ≠ clean」を exit code でも区別する・report/notice モード）:
#   exit 1 = 確定 parity 問題あり（gap/drift/orphan/broken）＝fail-loud。
#   exit 3 = 評価不能（errored project / jq 不在 / indeterminate）あり・確定 parity 問題は無い＝DEGRADED。
#            cron/自動化が exit0 を 'clean' と消費しても degraded を健全と誤認しない。
#   exit 0 = 全件評価済かつ問題なし＝真の clean。
if [ "$n_issues" -gt 0 ]; then
    exit 1
elif [ "$n_degraded" -gt 0 ]; then
    exit 3
fi
exit 0

#!/usr/bin/env bash
# scribe-wf-cost.sh — WF 消費の bead 値札 emitter（sc-46kv・外側 (4)・scribe-gate-attest.sh 同型:
# probe = read-only 証跡生成 / record = bdw 経由の bd write）。
#
# 裁定（orch-zkkq M0-P1 外側 (4)）: 「検知線(e) が bead 単位の累計 WF 消費（run 数 / token）を焼き板に出す」。
# 集計・表示は scriptorium 検知線（E-D7 単一 collector）の所有＝scribe 側の責務は **bead へ機械可読な値札を
# emit する**こと（既存の ad-hoc 慣行〔自由文の run/token 記録〕に文法と欠測しない計上点を与える）。
#
# ■ 計上点の設計（facet 実測に基づく・欠測経路を loud に）
#   - 一次面 = run record（`<config-dir>/projects/<enc-cwd>/<session-uuid>/workflows/wf_<runId>.json`・
#     **完走時のみ生成**・locator は protocol §4 の (補) 参照）。完了 task-notification の `<usage>` と
#     run record の値は厳密一致（facet 実測）＝admin は notification でその場照合できる。
#   - **resume は同一 runId の run record を上書きし累計にならない**＝値札は **invocation ごとに record** する
#     （1 run 1 行でなく 1 invocation 1 行。累計は collector 側が行頭 marker を集計して出す）。
#   - **OOM 死 run は run record 自体が残らない**＝probe は rc=2（JOURNAL-NOT-FOUND）で loud に欠測を報告する
#     （「記録なし＝消費なし」と読ませない）。
#   - 値札行に**絶対パスを焼かない**（公開面規律: 台帳 bead に実名/ホスト名/絶対パスを書かない。runId が
#     あれば run record は再探索できる。probe は探索した path を stderr にだけ出す）。
#
# ■ 監視トリガー衛生（protocol §6）
#   header は独自の `[SCRIBE-WF-COST v1]`（`STATUS:` 行頭・`[DONE--`・`[SPAWNED--`・`gate-pending` と非衝突・
#   tests/wf-loop-control.bats が pin）。
#
# Usage:
#   scribe-wf-cost.sh probe  --run RUNID [--id ID] (--journal F | [--config-dir D])
#   scribe-wf-cost.sh record --run RUNID --id ID [--anchor A] (--journal F | [--config-dir D]) [--dry-run]
# 終了コード:
#   probe : 0=値札行を emit / 2=run record 不在（欠測 loud・OOM 死/未完走/別 account の可能性を stderr へ）
#           / 1=usage・die。
#   record: 0=append 成功 / 2=run record 不在（append しない） / 1=usage・die / bdw の非 0 はそのまま伝播。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scribe-wf-cost.sh probe  --run RUNID [--id ID] (--journal F | [--config-dir D])
  scribe-wf-cost.sh record --run RUNID --id ID [--anchor A] (--journal F | [--config-dir D]) [--dry-run]

probe  : run record から [SCRIBE-WF-COST v1] 値札行を emit（read-only・bd/git を書かない）。
record : その値札行を bdw 経由で当該 bead の notes へ append（admin の write 段）。
値札は invocation ごとに焼く（resume は run record を上書きし累計にならない＝叩き忘れが欠測になる）。
EOF
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
MODE="$1"; shift
case "$MODE" in
  probe|record) ;;
  -h|--help) usage 0 ;;
  *) scribe_die "未知のモード: '$MODE'（probe|record を指定）" ;;
esac

command -v jq >/dev/null 2>&1 || scribe_die "jq が見つかりません（run record の JSON 読取りに必須）"

RUNID=""; ID=""; JOURNAL=""; CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; ANCHOR="$(pwd)"; DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)        scribe_need_val "${2:-}" --run; RUNID="$2"; shift 2 ;;
    --id)         scribe_need_val "${2:-}" --id; ID="$2"; shift 2 ;;
    --journal)    scribe_need_val "${2:-}" --journal; JOURNAL="$2"; shift 2 ;;
    --config-dir) scribe_need_val "${2:-}" --config-dir; CONFIG_DIR="$2"; shift 2 ;;
    --anchor)     scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=1; shift ;;
    -h|--help)    usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  scribe_die "余分な引数: $1" ;;
  esac
done
[[ -n "$RUNID" ]] || scribe_die "--run（必須・wf_ 始まりの runId）がありません。"
[[ "$RUNID" == wf_* ]] || scribe_die "--run は 'wf_' 始まりの runId を指定してください: '$RUNID'"
if [[ "$MODE" == record ]]; then
  [[ -n "$ID" ]] || scribe_die "record には --id（値札を焼く bead）が必須です。"
fi
[[ -z "$ID" ]] || ID="$(scribe_normalize_bd_id "$ID")" || scribe_die "bd id の形式が不正です: '$ID'"

# --- run record の解決（--journal 直指定が最優先・無ければ config-dir 配下を探索）---
if [[ -z "$JOURNAL" ]]; then
  # projects/<enc-cwd>/<session-uuid>/workflows/wf_<runId>.json（locator = protocol §4 (補)）。
  # account（config dir）が違うと見つからない（sc-rvq 同型の落とし穴）＝--config-dir で切替可。
  # 探索は bash glob（locator 深度に正確）。find は本 fleet のサンドボックス環境で当該階層の走査が
  # 空を返す実測がある（sc-46kv 実装時・glob は同一階層で hit）＝find に依存しない。
  shopt -s nullglob
  HITS=( "$CONFIG_DIR"/projects/*/*/workflows/"${RUNID}.json" )
  shopt -u nullglob
  if [[ ${#HITS[@]} -eq 0 ]]; then
    echo "run record が見つかりません: ${RUNID}.json（config-dir=$CONFIG_DIR。可能性: 未完走 / OOM 死で record 自体が無い / 別 account の config-dir）" >&2
    printf '[SCRIBE-WF-COST v1] bd=%s run=%s status=JOURNAL-NOT-FOUND（欠測 loud・消費ゼロと読まないこと）\n' "${ID:--}" "$RUNID"
    exit 2
  fi
  JOURNAL="${HITS[0]}"
  if [[ ${#HITS[@]} -gt 1 ]]; then
    echo "warn: run record が複数見つかりました（先頭を採用）: ${#HITS[@]} 件" >&2
  fi
fi
if [[ ! -f "$JOURNAL" ]]; then
  echo "run record が読めません: $JOURNAL" >&2
  printf '[SCRIBE-WF-COST v1] bd=%s run=%s status=JOURNAL-NOT-FOUND（欠測 loud・消費ゼロと読まないこと）\n' "${ID:--}" "$RUNID"
  exit 2
fi
echo "run record: $JOURNAL" >&2   # path は stderr のみ（値札行＝bd notes へは絶対パスを焼かない）

# --- 抽出（journal は 1 invocation 分＝resume 上書き後は最新 invocation の値）---
LINE="$(jq -r --arg bd "${ID:--}" --arg run "$RUNID" '
  def n(x): if (x | type) == "number" then (x | tostring) else "?" end;
  (.args | if type == "string" then (fromjson? // {}) else (. // {}) end) as $a |
  (($a.taskTitle // $a.targetBead // "") | tostring) as $tt |
  "[SCRIBE-WF-COST v1] bd=" + (if $bd != "-" then $bd elif ($tt | length) > 0 then $tt else "-" end) +
  " run=" + $run +
  " name=" + (.workflowName // "?") +
  " status=" + (.status // "?") +
  " agents=" + n(.agentCount) +
  " tokens=" + n(.totalTokens) +
  " toolCalls=" + n(.totalToolCalls) +
  " durationMs=" + n(.durationMs) +
  " invocation=latest（resume は上書き＝invocation ごとに record）"
' "$JOURNAL" 2>/dev/null)" || scribe_die "run record の JSON parse に失敗しました: $JOURNAL"
[[ -n "$LINE" ]] || scribe_die "値札行の合成に失敗しました（内部異常）"
UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
LINE="$LINE utc=$UTC"

if [[ "$MODE" == probe ]]; then
  printf '%s\n' "$LINE"
  exit 0
fi

# ============================ record ============================
BDW="$SCRIPT_DIR/bdw"
if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'DRY-RUN record: (cd %q && %q update %q --append-notes <%d bytes>)\n' \
    "$ANCHOR" "$BDW" "$ID" "${#LINE}"
  printf '%s\n' "$LINE"
  exit 0
fi
[[ -x "$BDW" ]] || scribe_die "bdw が実行できません: $BDW"
( cd "$ANCHOR" && "$BDW" update "$ID" --append-notes "$LINE" )
printf '%s\n' "$LINE"
exit 0

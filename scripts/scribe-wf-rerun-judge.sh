#!/usr/bin/env bash
# scribe-wf-rerun-judge.sh — WF 外側ループの機械化 (1)(2)(3)（sc-46kv・M0 外側 4 裁定 = orch-zkkq M0-P1）
#
# 裁定（一次 SSOT = scriptorium orch-zkkq M0-P1。pre-bake facet = .claude-session/m0-prebake/
# m0-facet-outer-loop-protocol.json）: 原理 = **止まるときは必ず loud・続けるときは必ず値札と記録**
# （値札 = scribe-wf-cost.sh が対・protocol §4 は本 header 群への pointer 1 行のみ）。
#   (1) 再走可否の機械判定 = 「削られた findings に閾値以上が含まれる場合のみ再走可（minor のみなら受容）」
#       ＝ vibe 判断の排除。入力は cell-quality cap 契約 v2 の返り値（capExceeded / capReport / capDropped）。
#   (2) 再走は restart でなく resume（cache 再利用で削られた部分だけ払い直す）。手順は本 header が規約本文。
#   (3) 同一 bead への escalation（再走）自動は 1 回まで・2 回目以降は理由の bd notes 記帳必須。
#
# ■ (2) resume 再走の手順（規約本文）
#   `Workflow({scriptPath: <前回 tool result の Script file>, resumeFromRunId: "<runId>", args: <初回と同一>})`。
#   - **args は resume で復元されない＝初回と同一 args を明示再送する**（folio 実測 2026-08-04・doobidoo
#     ca761464。再送忘れは SCARGS fail-fast が 0 agent で即死させる＝安価に露見する）。
#   - **resume が効かない 3 条件**（該当時は「安く再走できる」前提が崩れる＝restart か errata 差し戻しを選び、
#     どちらへ倒したかを理由付きで bd notes へ記帳する）:
#     (i)   再走に prompt/opts を変える改修を伴う（top-K・rubric・effort 変更＝cache key (prompt,opts) が変わる）
#     (ii)  session を跨いだ（/clear・respawn 後。cache 実体は旧 session 配下＝引けるかは未保証）
#     (iii) 前回の失敗原因（rate limit・env 劣化）が未解消（cache 即返り + 再死で空 verdict を掴む既知例）
#   - **run record（journal）は resume で同一 runId を上書きし累計にならない**＝値札（scribe-wf-cost.sh record）
#     は invocation ごとに焼く（過少計上の構造防止）。
#
# ■ (3) escalation 計数の規約（count / marker subcommand）
#   自動再走は当該 bead の行頭 marker `[WF-RERUN--<id>]` が **0 件のとき（＝この再走が 1 回目）だけ**無条件可。
#   1 件以上（2 回目以降）は reason を添えた marker 行を bdw で記帳してから再走する。marker 行は本 script の
#   `marker` subcommand が print し、**write は admin が bdw 経由で行う**（道具は bd を書かない・read-only）。
#   marker 語彙は §6 監視トリガー語（`STATUS:` 行頭・`[DONE--`・`[SPAWNED--`・`gate-pending` ラベル）と非衝突
#   （tests/wf-loop-control.bats が pin）。
#
# ■ 閾値の SSOT（決め打ちしない・P1 実分布待ち = orch-zkkq.13）
#   blocking 級 severity 集合の既定 = critical,major,unknown（`workflows/cell-quality.workflow.js` の
#   `CAP_BLOCKING_DROP_SEVERITIES` の mirror。drift は tests/wf-loop-control.bats の pin が RED 化）。
#   上書きは --severities CSV / env `SCRIBE_WF_RERUN_SEVERITIES`（構造だけ land し集合/数値は args 側が SSOT）。
#
# Usage:
#   scribe-wf-rerun-judge.sh judge  (--result-file F | stdin) [--severities CSV]
#   scribe-wf-rerun-judge.sh count  --id ID (--notes-file F | [--anchor A])
#   scribe-wf-rerun-judge.sh marker --id ID --run RUNID --n N --reason TEXT [--verdict V]
# 終了コード:
#   judge : 0=ACCEPT（受容＝再走不要・minor/nit 尾切りのみ） / 1=RERUN-REQUIRED（blocking 級が削られた）
#           / 2=INCONCLUSIVE（JSON parse 不能・cap 契約 key 欠落）。**rc=2 を 0 に丸めない**——判定不能は
#           再走側へ倒す（fail-closed・「削った事実を隠さない」原理）のが呼出元の既定。
#   count : 0=読めた（auto=OK|REASON-REQUIRED を emit） / 2=notes を読めない（自動再走不可側へ倒す）。
#   marker: 0=行を print / 1=usage・die。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scribe-wf-rerun-judge.sh judge  (--result-file F | stdin) [--severities CSV]
  scribe-wf-rerun-judge.sh count  --id ID (--notes-file F | [--anchor A])
  scribe-wf-rerun-judge.sh marker --id ID --run RUNID --n N --reason TEXT [--verdict V]

judge : WF 返り値 JSON（cap 契約 v2）から再走可否を機械判定（rc 0=ACCEPT / 1=RERUN-REQUIRED / 2=INCONCLUSIVE）。
count : bead notes の [WF-RERUN--<id>] marker を数え、自動再走の可否（auto=OK|REASON-REQUIRED）を出す。
marker: 記帳用の marker 行を print する（write は admin が bdw 経由で行う＝道具は bd を書かない）。
EOF
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
MODE="$1"; shift
case "$MODE" in
  judge|count|marker) ;;
  -h|--help) usage 0 ;;
  *) scribe_die "未知のモード: '$MODE'（judge|count|marker を指定）" ;;
esac

command -v jq >/dev/null 2>&1 || scribe_die "jq が見つかりません（judge/count の JSON 読取りに必須）"

# 既定 severity 集合 = cell-quality.workflow.js CAP_BLOCKING_DROP_SEVERITIES の mirror（drift は bats pin）。
DEFAULT_SEVERITIES="critical,major,unknown"

# ============================ judge ============================
if [[ "$MODE" == judge ]]; then
  RESULT_FILE=""; SEVERITIES="${SCRIBE_WF_RERUN_SEVERITIES:-$DEFAULT_SEVERITIES}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result-file) scribe_need_val "${2:-}" --result-file; RESULT_FILE="$2"; shift 2 ;;
      --severities)  scribe_need_val "${2:-}" --severities; SEVERITIES="$2"; shift 2 ;;
      -h|--help)     usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "未知のオプション: $1" ;;
      *)  scribe_die "余分な引数: $1" ;;
    esac
  done
  if [[ -n "$RESULT_FILE" ]]; then
    [[ -f "$RESULT_FILE" ]] || scribe_die "--result-file が読めません: $RESULT_FILE"
    RAW="$(cat "$RESULT_FILE")"
  else
    RAW="$(cat)"
  fi
  [[ -n "$RAW" ]] || scribe_die "WF 返り値 JSON が空です（--result-file か stdin で渡してください）"

  # parse 検証（不能 = INCONCLUSIVE rc=2・rc=0 に丸めない）
  if ! printf '%s' "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf '[WF-RERUN-JUDGE v1] verdict=INCONCLUSIVE reason=PARSE_FAILED severities=%s\n' "$SEVERITIES"
    exit 2
  fi
  # cap 契約 v2 の key 実在（capExceeded が無い返り値は判定対象外 = INCONCLUSIVE）
  if ! printf '%s' "$RAW" | jq -e 'has("capExceeded")' >/dev/null 2>&1 || \
     [[ "$(printf '%s' "$RAW" | jq -r 'has("capExceeded")')" != "true" ]]; then
    printf '[WF-RERUN-JUDGE v1] verdict=INCONCLUSIVE reason=CONTRACT_MISSING（capExceeded 不在＝cap 契約 v2 の返り値でない） severities=%s\n' "$SEVERITIES"
    exit 2
  fi

  CAP_EXCEEDED="$(printf '%s' "$RAW" | jq -r '.capExceeded')"
  SEVS_JSON="$(printf '%s' "$SEVERITIES" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"
  # capDropped[] から blocking 級を独立に数える（capReport.droppedBlocking と突合し、大きい側を採る = fail-closed）
  DROPPED_TOTAL="$(printf '%s' "$RAW" | jq '[.capDropped[]?] | length')"
  DROPPED_BLOCKING_LIST="$(printf '%s' "$RAW" | jq --argjson sevs "$SEVS_JSON" \
    '[.capDropped[]? | select(.severity as $s | ($sevs | index($s)) != null)] | length')"
  DROPPED_BLOCKING_REPORT="$(printf '%s' "$RAW" | jq -r '.capReport.droppedBlocking // empty')"
  [[ "$DROPPED_BLOCKING_REPORT" =~ ^[0-9]+$ ]] || DROPPED_BLOCKING_REPORT=""

  if [[ "$CAP_EXCEEDED" == "false" ]]; then
    printf '[WF-RERUN-JUDGE v1] verdict=ACCEPT reason=no-drop（capExceeded=false＝削りなし） capExceeded=false droppedBlocking=0 droppedTotal=%s severities=%s\n' \
      "$DROPPED_TOTAL" "$SEVERITIES"
    exit 0
  fi

  # capExceeded=true: blocking 級の削りが 1 件でもあれば再走可（required）・minor/nit 尾切りのみなら受容
  BLOCKING="$DROPPED_BLOCKING_LIST"
  if [[ -n "$DROPPED_BLOCKING_REPORT" && "$DROPPED_BLOCKING_REPORT" -gt "$BLOCKING" ]]; then
    BLOCKING="$DROPPED_BLOCKING_REPORT"   # 2 表面が食い違ったら大きい側（fail-closed・隠さない）
  fi
  if [[ "$BLOCKING" -gt 0 ]]; then
    printf '[WF-RERUN-JUDGE v1] verdict=RERUN-REQUIRED reason=blocking-dropped（blocking 級 %s 件が削られた） capExceeded=true droppedBlocking=%s droppedTotal=%s severities=%s\n' \
      "$BLOCKING" "$BLOCKING" "$DROPPED_TOTAL" "$SEVERITIES"
    exit 1
  fi
  printf '[WF-RERUN-JUDGE v1] verdict=ACCEPT reason=tail-only（削りは minor/nit 尾切りのみ＝受容） capExceeded=true droppedBlocking=0 droppedTotal=%s severities=%s\n' \
    "$DROPPED_TOTAL" "$SEVERITIES"
  exit 0
fi

# ============================ count ============================
if [[ "$MODE" == count ]]; then
  ID=""; NOTES_FILE=""; ANCHOR="$(pwd)"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)         scribe_need_val "${2:-}" --id; ID="$2"; shift 2 ;;
      --notes-file) scribe_need_val "${2:-}" --notes-file; NOTES_FILE="$2"; shift 2 ;;
      --anchor)     scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
      -h|--help)    usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "未知のオプション: $1" ;;
      *)  scribe_die "余分な引数: $1" ;;
    esac
  done
  [[ -n "$ID" ]] || scribe_die "--id（必須）がありません。"
  ID="$(scribe_normalize_bd_id "$ID")" || scribe_die "bd id の形式が不正です。"
  if [[ -n "$NOTES_FILE" ]]; then
    if [[ ! -f "$NOTES_FILE" ]]; then
      printf '[WF-RERUN-COUNT v1] id=%s n=? auto=UNKNOWN reason=NOTES_UNREADABLE（自動再走不可側へ倒す）\n' "$ID"
      exit 2
    fi
    NOTES="$(cat "$NOTES_FILE")"
  else
    if ! NOTES="$( cd "$ANCHOR" && bd show "$ID" --json 2>/dev/null | jq -r '.[0].notes // ""' )"; then
      printf '[WF-RERUN-COUNT v1] id=%s n=? auto=UNKNOWN reason=BD_READ_FAILED（自動再走不可側へ倒す）\n' "$ID"
      exit 2
    fi
  fi
  # 行頭 marker の完全一致 prefix で数える（本文中の引用と区別するため行頭 anchor・herestring で SIGPIPE 回避）
  N="$(grep -c -- "^\[WF-RERUN--${ID}\]" <<< "$NOTES" || true)"
  [[ "$N" =~ ^[0-9]+$ ]] || N=0
  if [[ "$N" -eq 0 ]]; then
    printf '[WF-RERUN-COUNT v1] id=%s n=0 auto=OK（この再走が 1 回目＝自動可。marker を記帳してから再走する）\n' "$ID"
  else
    printf '[WF-RERUN-COUNT v1] id=%s n=%s auto=REASON-REQUIRED（2 回目以降＝reason 付き marker の記帳必須）\n' "$ID" "$N"
  fi
  exit 0
fi

# ============================ marker ============================
ID=""; RUNID=""; NNUM=""; REASON=""; VERDICT="-"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --id)      scribe_need_val "${2:-}" --id; ID="$2"; shift 2 ;;
    --run)     scribe_need_val "${2:-}" --run; RUNID="$2"; shift 2 ;;
    --n)       scribe_need_val "${2:-}" --n; NNUM="$2"; shift 2 ;;
    --reason)  scribe_need_val "${2:-}" --reason; REASON="$2"; shift 2 ;;
    --verdict) scribe_need_val "${2:-}" --verdict; VERDICT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  scribe_die "余分な引数: $1" ;;
  esac
done
[[ -n "$ID" ]]     || scribe_die "--id（必須）がありません。"
[[ -n "$RUNID" ]]  || scribe_die "--run（必須）がありません。"
[[ -n "$NNUM" ]]   || scribe_die "--n（必須・この記帳で何回目の再走か）がありません。"
[[ -n "$REASON" ]] || scribe_die "--reason（必須・2 回目以降の理由記帳が本 marker の存在理由）がありません。"
ID="$(scribe_normalize_bd_id "$ID")" || scribe_die "bd id の形式が不正です。"
[[ "$NNUM" =~ ^[0-9]+$ ]] || scribe_die "--n は数値で指定してください: '$NNUM'"
UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '[WF-RERUN--%s] n=%s run=%s verdict=%s utc=%s reason=%s\n' "$ID" "$NNUM" "$RUNID" "$VERDICT" "$UTC" "$REASON"
exit 0

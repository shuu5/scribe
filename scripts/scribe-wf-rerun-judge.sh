#!/usr/bin/env bash
# scribe-wf-rerun-judge.sh — WF 外側ループの機械化 (1)(2)(3)（sc-46kv・M0 外側 4 裁定 = orch-zkkq M0-P1）
#
# 裁定（一次 SSOT = scriptorium orch-zkkq M0-P1・経緯の durable 面 = bd sc-46kv notes〔pre-bake facet の
# 要旨と GATE 判定を含む〕）: 原理 = **止まるときは必ず loud・続けるときは必ず値札と記録**
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
#           / 2=INCONCLUSIVE（JSON parse 不能・cap 契約 key 欠落 / shape 不正 / 自己矛盾入力 / 内訳欠落）
#           / 4=BAD_USAGE（引数・入力経路の不備。**rc=1〔再走要〕と usage die の衝突を分離**する専用 rc）。
#           **rc=2 を 0 に丸めない**——判定不能は再走側へ倒す（fail-closed・「削った事実を隠さない」原理）
#           のが呼出元の既定。**判定は cap 面のみ**（scope=cap-only を出力に明示。timedOut / unverified /
#           machineryFailedLastRound / schemaHealth は判定外＝呼出元が §4 の machinery 健全性判定で別途監査）。
#   count : 0=読めた（auto=OK|REASON-REQUIRED を emit） / 2=notes を読めない・bead 不在・bd timeout
#           （**bead 不在も rc2**＝n=0 auto=OK へ倒さない fail-closed。自動再走不可側へ）。
#   marker: 0=行を print / 1=usage・die（reason 等は改行を空白へ正規化＝行頭 marker 注入を封じる）。
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
  # judge 専用 die = rc4（BAD_USAGE）。scribe_die の rc1 は本 mode では RERUN-REQUIRED と衝突するため使わない。
  jdie() { printf 'ERROR: %s\n' "$1" >&2; exit 4; }
  RESULT_FILE=""; SEVERITIES="${SCRIBE_WF_RERUN_SEVERITIES:-$DEFAULT_SEVERITIES}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --result-file) [[ -n "${2:-}" ]] || jdie "--result-file に値がありません"; RESULT_FILE="$2"; shift 2 ;;
      --severities)  [[ -n "${2:-}" ]] || jdie "--severities に値がありません"; SEVERITIES="$2"; shift 2 ;;
      -h|--help)     usage 0 ;;
      --) shift; break ;;
      *) jdie "未知のオプション/余分な引数: $1" ;;
    esac
  done
  if [[ -n "$RESULT_FILE" ]]; then
    [[ -f "$RESULT_FILE" ]] || jdie "--result-file が読めません: $RESULT_FILE"
    RAW="$(cat "$RESULT_FILE")"
  else
    [[ ! -t 0 ]] || jdie "stdin が tty です（--result-file を指定するか JSON を pipe してください）"
    RAW="$(cat)"
  fi
  [[ -n "$RAW" ]] || jdie "WF 返り値 JSON が空です（--result-file か stdin で渡してください）"

  emit_inconclusive() { # $1=reason
    printf '[WF-RERUN-JUDGE v1] verdict=INCONCLUSIVE reason=%s scope=cap-only severities=%s\n' "$1" "$SEVERITIES"
    exit 2
  }

  # parse 検証（不能 = INCONCLUSIVE rc=2・rc=0 に丸めない）
  if ! printf '%s' "$RAW" | jq -e 'type == "object"' >/dev/null 2>&1; then
    emit_inconclusive 'PARSE_FAILED'
  fi

  SEVS_JSON="$(printf '%s' "$SEVERITIES" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))')"

  # 入力 shape の検証と抽出を 1 pass に集約（gate r1 E1: 型検証を散らさない・jq die を宣言 rc 空間の外へ
  # 漏らさない）。severity 欠落/非文字列は 'unknown' 既定＝上流 cell-quality.workflow.js:614 の
  # `severity || 'unknown'`（blocking 集合へ倒す）と同じ意味論に揃える。
  JQ_PROG='
    def sevblock($sevs):
      if (.capDropped | type) == "array"
      then ([ .capDropped[]
              | (try (.severity? // "unknown") catch "unknown") as $s0
              | (if ($s0 | type) == "string" then $s0 else "unknown" end)
              | select(. as $s | ($sevs | index($s)) != null) ] | length)
      else -1 end;
    [ (.capExceeded | type),
      (if has("capDropped") then (.capDropped | type) else "absent" end),
      (if has("capReport") then (.capReport | type) else "absent" end),
      sevblock($sevs),
      (if (.capDropped | type) == "array" then (.capDropped | length) else -1 end),
      (if (.capReport | type) == "object" and ((.capReport.droppedBlocking? | type) == "number")
         then (.capReport.droppedBlocking | floor) else -1 end)
    ] | @tsv'
  ROW="$(printf '%s' "$RAW" | jq -r --argjson sevs "$SEVS_JSON" "$JQ_PROG" 2>/dev/null)" || ROW=""
  [[ -n "$ROW" ]] || emit_inconclusive 'SHAPE_INVALID（抽出不能）'
  IFS=$'\t' read -r EXT DTYPE RTYPE BLOCKL TOTAL RBLOCK <<< "$ROW"

  # shape 検証（capExceeded 非 boolean〔null / "false" 文字列 / 欠落〕・capDropped 非配列・capReport 非 object
  # はすべて INCONCLUSIVE rc=2 = 再走側。ACCEPT に丸めない）
  [[ "$EXT" == "boolean" ]] || emit_inconclusive "SHAPE_INVALID（capExceeded type=${EXT}・boolean 以外は判定不能）"
  case "$DTYPE" in array|absent|null) ;; *) emit_inconclusive "SHAPE_INVALID（capDropped type=${DTYPE}）" ;; esac
  case "$RTYPE" in object|absent|null) ;; *) emit_inconclusive "SHAPE_INVALID（capReport type=${RTYPE}）" ;; esac

  CAP_EXCEEDED="$(printf '%s' "$RAW" | jq -r '.capExceeded')"
  # blocking 実効値 = capDropped 列挙と capReport.droppedBlocking の大きい側（2 表面食い違いは fail-closed）
  BLOCKING=0; HAVE_SIGNAL=0
  if [[ "$BLOCKL" -ge 0 ]]; then BLOCKING="$BLOCKL"; HAVE_SIGNAL=1; fi
  if [[ "$RBLOCK" -ge 0 ]]; then HAVE_SIGNAL=1; [[ "$RBLOCK" -gt "$BLOCKING" ]] && BLOCKING="$RBLOCK"; fi
  DROPPED_TOTAL=0; [[ "$TOTAL" -ge 0 ]] && DROPPED_TOTAL="$TOTAL"

  if [[ "$CAP_EXCEEDED" == "false" ]]; then
    # 自己矛盾（capExceeded=false なのに drop の実体がある）は ACCEPT に丸めず INCONCLUSIVE（gate r1 E1）
    if [[ "$DROPPED_TOTAL" -gt 0 || "$BLOCKING" -gt 0 ]]; then
      emit_inconclusive "CONTRADICTION（capExceeded=false なのに droppedTotal=${DROPPED_TOTAL} droppedBlocking=${BLOCKING}）"
    fi
    printf '[WF-RERUN-JUDGE v1] verdict=ACCEPT reason=no-drop（capExceeded=false＝削りなし） capExceeded=false droppedBlocking=0 droppedTotal=0 scope=cap-only severities=%s\n' \
      "$SEVERITIES"
    exit 0
  fi

  # capExceeded=true: 内訳が両面とも読めなければ判定不能（severity で判定できない削りは再走側へ・D-sub-3）
  if [[ "$HAVE_SIGNAL" -eq 0 ]]; then
    emit_inconclusive 'DROP_DETAIL_MISSING（capExceeded=true だが capDropped/capReport の内訳が読めない）'
  fi
  if [[ "$BLOCKING" -gt 0 ]]; then
    printf '[WF-RERUN-JUDGE v1] verdict=RERUN-REQUIRED reason=blocking-dropped（blocking 級 %s 件が削られた） capExceeded=true droppedBlocking=%s droppedTotal=%s scope=cap-only severities=%s\n' \
      "$BLOCKING" "$BLOCKING" "$DROPPED_TOTAL" "$SEVERITIES"
    exit 1
  fi
  printf '[WF-RERUN-JUDGE v1] verdict=ACCEPT reason=tail-only（削りは minor/nit 尾切りのみ＝受容） capExceeded=true droppedBlocking=0 droppedTotal=%s scope=cap-only severities=%s\n' \
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
    # bd read は timeout で包む（dolt lock 競合の無期限 hang 防止・repo 慣行 = SCRIBE_REBRIEF_BD_TIMEOUT 同型。
    # gate r1 E4）。env seam = SCRIBE_WF_LOOP_BD_TIMEOUT（既定 20 秒）。
    if ! RAWJ="$( cd "$ANCHOR" && timeout "${SCRIBE_WF_LOOP_BD_TIMEOUT:-20}" bd show "$ID" --json 2>/dev/null )"; then
      printf '[WF-RERUN-COUNT v1] id=%s n=? auto=UNKNOWN reason=BD_READ_FAILED（自動再走不可側へ倒す）\n' "$ID"
      exit 2
    fi
    # bead 不在（bd show が [] / 非 object を返す）も rc2 側へ倒す（n=0 auto=OK に化けさせない・gate r1 E2。
    # scribe_bd_id_exists が上流で塞ぐ「不正 id の silent fallback」と同じ convention）。
    NOTES="$(jq -r 'if (type == "array" and length > 0 and (.[0] | type == "object")) then (.[0].notes // "") else "__SCRIBE_BEAD_MISSING__" end' <<< "$RAWJ" 2>/dev/null)" || NOTES="__SCRIBE_BEAD_MISSING__"
    if [[ "$NOTES" == "__SCRIBE_BEAD_MISSING__" ]]; then
      printf '[WF-RERUN-COUNT v1] id=%s n=? auto=UNKNOWN reason=BEAD_NOT_FOUND（bead 不在＝自動再走不可側へ倒す）\n' "$ID"
      exit 2
    fi
  fi
  # 行頭 marker の完全一致 prefix で数える（本文中の引用と区別するため行頭 anchor・herestring で SIGPIPE 回避。
  # id は regex escape する＝dotted id〔例 sc-xx.1〕の `.` を metachar にしない・gate r1 E6）
  ESC_ID="$(printf '%s' "$ID" | sed 's/[][\.*^$]/\\&/g')"
  N="$(grep -c -- "^\[WF-RERUN--${ESC_ID}\]" <<< "$NOTES" || true)"
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
# 自由文（reason/verdict）の改行を空白へ正規化する＝marker を必ず 1 物理行に保ち、改行経由で
# 行頭 monitor 語（[DONE-- 等）を注入される経路を封じる（gate r1 E6・§6 トリガー衛生）。
REASON="${REASON//$'\n'/ }"; REASON="${REASON//$'\r'/ }"
VERDICT="${VERDICT//$'\n'/ }"; VERDICT="${VERDICT//$'\r'/ }"
UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '[WF-RERUN--%s] n=%s run=%s verdict=%s utc=%s reason=%s\n' "$ID" "$NNUM" "$RUNID" "$VERDICT" "$UTC" "$REASON"
exit 0

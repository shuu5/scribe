#!/usr/bin/env bash
# scribe-wf-stall-scan.sh — 走行中 WF の呼出元側 stall 検知（bd sc-9yoc・c1df leg2-B2）
#
# なぜ在るか（層の説明・protocol §6 stall watchdog 節の WF 側 bullet が規約面）:
#   - worker cell の stall watchdog（§6）は pane / commit を見る。WF の agent は background で pane に
#     出ない＝別層の観測面が要る。
#   - 完走前は run record（workflows/wf_<runId>.json）が存在しない（完走時のみ生成・bd sc-lbjv）＝
#     走行中の唯一の live 観測面は transcriptDir 配下の per-agent jsonl
#     （<config-dir>/projects/<enc-cwd>/<session-uuid>/subagents/workflows/<runId>/agent-*.jsonl）。
#   - harness の agent stallMs は tool in-flight 中に watchdog 解除される（sc-foqe fence 実測）＝
#     本 scan は jsonl mtime（event append で前進する）を一次量としてその盲点を補完する。
#   - read-only: file / git / bd を一切変更しない（監視は読むだけ・write / 操舵は admin の判断層）。
#
# 探索は bash glob（scribe-wf-cost.sh と同型）: GNU find 既定 -P は開始点 <config-dir>/projects が
# symlink の環境で降りず 0 件 rc=0 を返す（doobidoo 7b13a5d7）＝find を使わない。
#
# Usage:
#   scribe-wf-stall-scan.sh --run RUNID [--config-dir D] [--threshold SEC]
#   scribe-wf-stall-scan.sh --dir TRANSCRIPT_DIR [--threshold SEC]
#
# 出力（行頭 marker・固定 arity 前置 + 自由文 label は末尾＝label 内の空白で parse が壊れない順）:
#   [WF-STALL-SCAN v1] run=<runId> agent=<id> ageSec=<n> verdict=STALL|ACTIVE|DONE label=<prompt 先頭 hint>
#   [WF-STALL-SCAN v1] run=<runId> total=<n> done=<k> stalled=<m> threshold=<sec> verdict=STALL|OK|EMPTY
# 完了 agent の除外（gate wf_bd633def-65b MF-1）: 完了 agent / resume 前 invocation の jsonl は追記が
# 止まる＝mtime 単独判定は健全 run の最終盤で誤 STALL を出す（実データ 1805 run 中 43% で再現）。
# 同 dir の journal.jsonl（{"type":"result","agentId":…}）を完了判定に使い、result 済み agent は
# verdict=DONE として stall 集計から除外する。journal 不在/読取不能は除外ゼロ＝過剰報告側（fail-closed）。
# 終了コード（宣言 rc 空間 {0,2,3,4,5} の外へ漏らさない）:
#   0=停滞なし / 3=停滞あり（未完了 agent が threshold 超過）/ 2=判定不能（agent file 0 件・dir 多重
#   hit・scan 中の stat 失敗）/ 4=BAD_USAGE / 5=run dir 不在（NOT-FOUND・loud）
# threshold 既定 900 秒: tool 1 呼出しが数分走る agent（bats 実走 lens 等）の in-flight を停滞と
# 誤検知しない側へ倒した値。露見した誤検知/見逃しは呼出し側が --threshold で較正する。
set -euo pipefail

usage() {
  sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

die4() { echo "scribe-wf-stall-scan: BAD_USAGE: $*" >&2; exit 4; }

RUNID=""; DIR=""; CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"; THRESHOLD=900
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)        [[ -n "${2:-}" ]] || die4 "--run に値がありません"; RUNID="$2"; shift 2 ;;
    --dir)        [[ -n "${2:-}" ]] || die4 "--dir に値がありません"; DIR="$2"; shift 2 ;;
    --config-dir) [[ -n "${2:-}" ]] || die4 "--config-dir に値がありません"; CONFIG_DIR="$2"; shift 2 ;;
    --threshold)  [[ -n "${2:-}" ]] || die4 "--threshold に値がありません"; THRESHOLD="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    *)            die4 "未知の引数: $1" ;;
  esac
done

[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || die4 "--threshold は非負整数秒で指定してください: '$THRESHOLD'"
if [[ -z "$DIR" && -z "$RUNID" ]]; then
  die4 "--run RUNID か --dir TRANSCRIPT_DIR のどちらかが必須です"
fi
if [[ -z "$DIR" ]]; then
  [[ "$RUNID" == wf_* ]] || die4 "--run は 'wf_' 始まりの runId を指定してください: '$RUNID'"
  # 走行中 WF の transcriptDir を glob で解決（run record と違い完走前から存在する）
  shopt -s nullglob
  HITS=( "$CONFIG_DIR"/projects/*/*/subagents/workflows/"$RUNID" )
  shopt -u nullglob
  if [[ ${#HITS[@]} -eq 0 ]]; then
    echo "scribe-wf-stall-scan: NOT-FOUND: transcriptDir が見つかりません: $CONFIG_DIR/projects/*/*/subagents/workflows/$RUNID（account 違いなら --config-dir で切替・未起動/別 host の可能性）" >&2
    exit 5
  fi
  if [[ ${#HITS[@]} -gt 1 ]]; then
    echo "scribe-wf-stall-scan: AMBIGUOUS: transcriptDir が ${#HITS[@]} 件 hit＝判定不能（--dir で明示指定してください）:" >&2
    printf '  %s\n' "${HITS[@]}" >&2
    exit 2
  fi
  DIR="${HITS[0]}"
fi
[[ -d "$DIR" ]] || { echo "scribe-wf-stall-scan: NOT-FOUND: dir がありません: $DIR" >&2; exit 5; }
RUN_LABEL="${RUNID:-$(basename "$DIR")}"

# label hint: agent jsonl 1 行目の prompt 先頭を best-effort で抽出（jq 不在/形不一致は '-'）。
# 走行中は run record（label の一次面）が無く journal.jsonl の started 行にも label が無い＝
# prompt 先頭が唯一の同定 hint（機械判定は agent id / ageSec 側で完結し label は人間向け補助）。
label_hint() { # $1 = agent jsonl path
  local h=""
  if command -v jq >/dev/null 2>&1; then
    h="$(head -n 1 "$1" 2>/dev/null \
      | jq -r '.message.content | if type=="array" then (.[0].text // .[0].content // empty) else . end' 2>/dev/null \
      | tr '\n\t' '  ' | cut -c1-60 || true)"
  fi
  printf '%s' "${h:--}"
}

shopt -s nullglob
AGENTS=( "$DIR"/agent-*.jsonl )
shopt -u nullglob

if [[ ${#AGENTS[@]} -eq 0 ]]; then
  printf '[WF-STALL-SCAN v1] run=%s total=0 done=0 stalled=0 threshold=%s verdict=EMPTY\n' "$RUN_LABEL" "$THRESHOLD"
  echo "scribe-wf-stall-scan: EMPTY: agent jsonl が 0 件＝判定不能（起動直後 or 観測面の layout 変化。停滞なしと読まないこと）" >&2
  exit 2
fi

# 完了 agent 集合（MF-1）: journal.jsonl の result 行から agentId を拾う。jsonl は 1 event 1 行ゆえ
# 同一行の "type":"result" と "agentId" の共起で判定できる（jq 非依存＝key 順にも依らない）。
declare -A DONE_SET=()
if [[ -f "$DIR/journal.jsonl" ]]; then
  while IFS= read -r _aid; do [[ -n "$_aid" ]] && DONE_SET["$_aid"]=1; done < <(
    grep -F '"type":"result"' "$DIR/journal.jsonl" 2>/dev/null \
      | grep -oE '"agentId":"[A-Za-z0-9]+"' | cut -d'"' -f4 || true)
fi

NOW="$(date +%s)"
STALLED=0; DONE=0
for f in "${AGENTS[@]}"; do
  # scan 中に file が消える TOCTOU は宣言空間内の rc2 へ落とす（rc1 漏れ = MF-3）
  mtime="$(stat -c %Y "$f" 2>/dev/null)" || {
    echo "scribe-wf-stall-scan: INDETERMINATE: stat 失敗（scan 中に file が消えた等）: $f" >&2
    exit 2
  }
  age=$(( NOW - mtime )); (( age < 0 )) && age=0
  aid="$(basename "$f")"; aid="${aid#agent-}"; aid="${aid%.jsonl}"
  if [[ -n "${DONE_SET[$aid]:-}" ]]; then
    verdict="DONE"; DONE=$(( DONE + 1 ))
  elif (( age > THRESHOLD )); then
    verdict="STALL"; STALLED=$(( STALLED + 1 ))
  else
    verdict="ACTIVE"
  fi
  printf '[WF-STALL-SCAN v1] run=%s agent=%s ageSec=%s verdict=%s label=%s\n' \
    "$RUN_LABEL" "$aid" "$age" "$verdict" "$(label_hint "$f")"
done

if (( STALLED > 0 )); then SUMMARY="STALL"; else SUMMARY="OK"; fi
printf '[WF-STALL-SCAN v1] run=%s total=%s done=%s stalled=%s threshold=%s verdict=%s\n' \
  "$RUN_LABEL" "${#AGENTS[@]}" "$DONE" "$STALLED" "$THRESHOLD" "$SUMMARY"
(( STALLED > 0 )) && exit 3
exit 0

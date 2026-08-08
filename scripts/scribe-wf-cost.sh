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
#   - **OOM 死 run は run record 自体が残らない**＝probe は rc=2（JOURNAL-NOT-FOUND）で loud に欠測を報告し、
#     **record モードでは NOT-FOUND 行そのものを bead へ durable append する**（「記録なし＝消費なし」と
#     読ませない・欠測の証跡を台帳に残す）。
#   - 値札行に**絶対パスを焼かない**（公開面規律: 台帳 bead に実名/ホスト名/絶対パスを書かない。runId が
#     あれば run record は再探索できる。probe は探索した path を stderr にだけ出す）。
#   - **per-agent 内訳（workflowProgress の label×phase×tokens）は意図して焼かない**（gate r1 E5 の省略申告）:
#     値札は 1 行原則（bd notes 肥大の抑制）で bead 会計は totalTokens で閉じる。内訳は runId から run record
#     を引けば取れる deep-dive 面＝collector（scriptorium 検知線）側の領分。
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

BDW="$SCRIPT_DIR/bdw"

# 欠測（run record 不在）の loud 経路: probe は行 emit + rc2、record は NOT-FOUND 行を bead へ durable
# append してから rc2（gate r1 E6・「記録なし＝消費なし」と読ませない doctrine の実装）。
emit_notfound() { # $1 = stderr 向け診断
  echo "$1" >&2
  local nfline
  nfline="$(printf '[SCRIBE-WF-COST v1] bd=%s run=%s status=JOURNAL-NOT-FOUND（欠測 loud・消費ゼロと読まないこと） utc=%s' \
    "${ID:--}" "$RUNID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  if [[ "$MODE" == record ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      printf 'DRY-RUN record: (cd %q && %q update %q --append-notes <%d bytes>)\n' "$ANCHOR" "$BDW" "$ID" "${#nfline}"
    else
      [[ -x "$BDW" ]] || scribe_die "bdw が実行できません: $BDW"
      ( cd "$ANCHOR" && "$BDW" update "$ID" --append-notes "$nfline" )
    fi
  fi
  printf '%s\n' "$nfline"
  exit 2
}

# --- run record の解決（--journal 直指定が最優先・無ければ config-dir 配下を探索）---
if [[ -z "$JOURNAL" ]]; then
  # projects/<enc-cwd>/<session-uuid>/workflows/wf_<runId>.json（locator = protocol §4 (補)）。
  # account（config dir）が違うと見つからない（sc-rvq 同型の落とし穴）＝--config-dir で切替可。
  # 探索は bash glob。GNU find 既定（-P）は開始点 `<config-dir>/projects` が symlink の環境で降りず
  # 空を返す（`find -L` なら hit・gate r1 で真因確定＝「sandbox が find を塞ぐ」は誤 lore）。glob は
  # symlink 越しでも展開されるためこちらを使う。
  shopt -s nullglob
  HITS=( "$CONFIG_DIR"/projects/*/*/workflows/"${RUNID}.json" )
  shopt -u nullglob
  # 複数 hit（同一 runId が複数 session/project 配下に見える）は mtime 最新を採る（resume 後の最新
  # invocation を代表させる・glob 辞書順の誤帰属を避ける・gate r1 E6）。
  if [[ ${#HITS[@]} -gt 1 ]]; then
    mapfile -t HITS < <(ls -1t -- "${HITS[@]}" 2>/dev/null)
  fi
  if [[ ${#HITS[@]} -eq 0 ]]; then
    emit_notfound "run record が見つかりません: ${RUNID}.json（config-dir=$CONFIG_DIR。可能性: 未完走 / OOM 死で record 自体が無い / 別 account の config-dir）"
  fi
  JOURNAL="${HITS[0]}"
  if [[ ${#HITS[@]} -gt 1 ]]; then
    echo "warn: run record が複数見つかりました（mtime 最新を採用）: ${#HITS[@]} 件" >&2
  fi
fi
if [[ ! -f "$JOURNAL" ]]; then
  emit_notfound "run record が読めません: $JOURNAL"
fi
echo "run record: $JOURNAL" >&2   # path は stderr のみ（値札行＝bd notes へは絶対パスを焼かない）

# --journal 直指定と --run の runId 突合（取り違えた journal で別 run の値札を焼く誤帰属を封じる・gate r1 E6）
RJ="$(jq -r '.runId // ""' "$JOURNAL" 2>/dev/null || true)"
if [[ -n "$RJ" && "$RJ" != "$RUNID" ]]; then
  scribe_die "journal の runId（$RJ）が --run（$RUNID）と一致しません（取り違え防止・fail-loud）"
fi

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

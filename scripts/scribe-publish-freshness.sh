#!/usr/bin/env bash
# scribe-publish-freshness.sh — federate-publish 面の publish 鮮度 advisory lint（sc-e93 / Plan A）。
#
# これがコード化する規約の SSOT は docs/protocol.md §5（gate funnel の advisory 鮮度 self-check ステップ）
# と §8（federate-publish / reconcile-published 公開面ラベル規約）。
#
# 目的（sc-e93 / orch-tya・orchestrator が Q1-Q4 合意）:
#   `federate-publish` ラベル bead の**内容が更新（updated_at 前進）されたのに再 publish されず
#   published surface が古いまま**になる drift を、admin が gate funnel（§5）/ dolt push 同期点で
#   **advisory に self-check** する（orch-reconciliation-parity.sh の human notice を待たない早期検知）。
#
# 合意事項（sc-e93 notes / 第3便 courier）:
#   Q1 鮮度信号 = updated_at（orch parity と同一信号・checksum 不採用＝parity の二重定義を避ける）。
#   Q2 publish provenance = bead notes（`federate-published-at: <ISO8601-UTC>` marker・一次）。
#   Q3 enforce 強度 = **advisory lint（warn・非block）**。§8「scribe は受容周知のみで enforce しない」
#      ゆえ block はしない。本道具は既定で findings があっても exit 0＝§8 と両立する advisory 上限線。
#   Q4 受け口 = 案A（本道具＝早期 self-check）。orch parity notice の代替でなく**補完で並走**する。
#
# **非block の実装**: `check` は既定で **常に exit 0**（drift/unpublished/unknown があっても止めない）。
#   機械 signal が要る caller（将来の CI 等・gate funnel は手動判断ゆえ非該当）向けに `--strict` を付けた
#   ときだけ findings 時 exit 3。infra 不調（bd 不在・bd list 失敗）は **findings ではない**ので --strict
#   でも exit 0（funnel を止めない）。壊れた呼び出し（不正 subcommand/option・不正 GRACE）だけ fail-loud。
#
# env seam（テストのスタブ差し替え点）:
#   SCRIBE_BD    bd バイナリ（既定 bd・check は READ のみ＝§3 で bdw 不要）
#   SCRIBE_BDW   bdw ラッパ（既定 <script_dir>/bdw・mark-published の WRITE を §3 で直列化する）
#   SCRIBE_ANCHOR  bd graph 所在（既定 cwd・--anchor で上書き可）
#   SCRIBE_PUBLISH_FRESHNESS_GRACE  drift 判定の猶予秒（既定 5）。marker を append する行為自体が bead の
#     updated_at を marker 時刻へ bump する（自己 bump）ため、publish 直後は updated_at≈marker となる。
#     この append 遅延を吸収する猶予で、advisory ゆえ実 drift（分〜日スケール）より十分小さくてよい。
#   SCRIBE_FEDERATE_PUBLISH_LABEL  公開候補ラベル（既定 federate-publish・§8 の平ラベルと一致）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

BD="${SCRIBE_BD:-bd}"
BDW="${SCRIBE_BDW:-$SCRIPT_DIR/bdw}"
ANCHOR="${SCRIBE_ANCHOR:-.}"
GRACE="${SCRIBE_PUBLISH_FRESHNESS_GRACE:-5}"
PUBLISH_LABEL="${SCRIBE_FEDERATE_PUBLISH_LABEL:-federate-publish}"
MARKER_KEY="federate-published-at"

usage() {
  cat <<'EOF'
Usage:
  scribe-publish-freshness.sh [check] [--strict] [--anchor PATH]
      federate-publish ラベル bead の publish 鮮度を advisory に self-check（warn・非block）。
      各 bead の updated_at(Q1) と notes の最新 `federate-published-at:` marker(Q2) を比較し、
      公開後に内容 drift（updated_at が marker より grace 秒超で新しい）していれば warn する。
      既定 exit 0（findings があっても止めない＝§8 advisory）。--strict で findings 時のみ exit 3。
  scribe-publish-freshness.sh mark-published <bd-id> [--anchor PATH]
      <bd-id> の notes へ `federate-published-at: <ISO8601-UTC>` marker を append（bdw 経由＝直列化）。
      = publish provenance（Q2）を記録する。以後 check はこの marker と updated_at を比較する。
  scribe-publish-freshness.sh -h | --help
EOF
  exit "${1:-0}"
}

SUBCMD=""
STRICT=0
MARK_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)  usage 0 ;;
    --strict)   STRICT=1; shift ;;
    --anchor)   scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
    check|mark-published)
      [[ -z "$SUBCMD" ]] || scribe_die "subcommand が重複しています: '$SUBCMD' と '$1'"
      SUBCMD="$1"; shift ;;
    -*)         scribe_die "不明なオプション: '$1'（--strict / --anchor / -h のみ）" ;;
    *)
      # 位置引数は mark-published の <bd-id> のみ許す（それ以外は誤用ゆえ fail-loud）。
      if [[ "$SUBCMD" == "mark-published" && -z "$MARK_ID" ]]; then
        MARK_ID="$1"; shift
      else
        scribe_die "余分な引数: '$1'"
      fi ;;
  esac
done
[[ -n "$SUBCMD" ]] || SUBCMD="check"

# GRACE は算術・比較に使うので非負整数を強制（不正値の silent 混入を防ぐ・fail-loud）。
[[ "$GRACE" =~ ^[0-9]+$ ]] \
  || scribe_die "SCRIBE_PUBLISH_FRESHNESS_GRACE は非負整数で指定してください: '$GRACE'"

# check — federate-publish 面の鮮度 advisory lint。JSON 解釈・日時演算・複数行 notes からの marker 抽出は
#   python3 に委譲する（gate-args と同じ委譲パターン）。bd 呼び出しは python の subprocess から行うが
#   バイナリは env の SCRIBE_BD ($BD) を使うためスタブ差し替えが効く（テストの hermetic 性を保つ）。
cmd_check() {
  local rc=0
  BD="$BD" ANCHOR="$ANCHOR" GRACE="$GRACE" PUBLISH_LABEL="$PUBLISH_LABEL" \
  MARKER_KEY="$MARKER_KEY" STRICT="$STRICT" python3 - <<'PY' || rc=$?
import json, os, re, subprocess, sys
from datetime import datetime, timezone

bd = os.environ["BD"]
anchor = os.environ["ANCHOR"]
grace = int(os.environ["GRACE"])
label = os.environ["PUBLISH_LABEL"]
mkey = os.environ["MARKER_KEY"]
strict = os.environ["STRICT"] == "1"

def run_bd(args):
    try:
        return subprocess.run([bd, *args], cwd=anchor, capture_output=True, text=True)
    except FileNotFoundError:
        # infra 不調（bd バイナリ不在）は findings ではない → warn して gate funnel を止めない。
        sys.stderr.write("scribe: warn: bd バイナリが見つかりません（鮮度 check を skip）: %s\n" % bd)
        sys.exit(0)

def parse_iso(ts):
    # bd の updated_at と mark-published の marker はいずれも YYYY-MM-DDTHH:MM:SSZ（固定幅 UTC）。
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None

# --anchor typo 等（存在しない graph 所在）は infra 不調（bd 不在）と別物ゆえ、正確な warn で区別する
# （非block・exit 0 は維持＝FileNotFoundError を『bd バイナリ不在』へ誤帰属しない）。
if not os.path.isdir(anchor):
    sys.stderr.write("scribe: warn: anchor ディレクトリが存在しません（--anchor を確認・鮮度 check を skip）: %s\n" % anchor)
    sys.exit(0)

# federate-publish 候補 id を取得（READ・§3 で bdw 不要）。--limit 0=無制限（bd list の既定 limit=50 による
# silent 打ち切りを防ぎ、非 closed の**全** federate-publish bead を走査する＝§5 step8 の exhaustive 契約。
# closed=公開済完了ゆえ drift 対象外＝既定の非 closed フィルタは意図どおり）。
r = run_bd(["list", "--label", label, "--json", "--limit", "0"])
if r.returncode != 0:
    sys.stderr.write("scribe: warn: `bd list --label %s --json` が失敗（鮮度 check を skip）: %s\n"
                     % (label, (r.stderr or "").strip()))
    sys.exit(0)   # infra 不調 → advisory ゆえ止めない
try:
    beads = json.loads(r.stdout or "[]")
except json.JSONDecodeError:
    sys.stderr.write("scribe: warn: bd list --json の JSON 解釈に失敗（鮮度 check を skip）\n")
    sys.exit(0)
ids = [b["id"] for b in beads if isinstance(b, dict) and b.get("id")]

print("scribe publish-freshness: federate-publish 面の鮮度 advisory lint（warn・非block・§5/§8・sc-e93）")
print("  信号=updated_at(Q1) / provenance=bead notes `%s:`(Q2) / grace=%ds" % (mkey, grace))

counts = {"fresh": 0, "drift": 0, "unpublished": 0, "unknown": 0}
marker_re = re.compile(re.escape(mkey) + r":\s*(\S+)")

for bid in ids:
    s = run_bd(["show", bid, "--json"])
    if s.returncode != 0:
        print("  [unknown]     %s  (bd show 失敗)" % bid); counts["unknown"] += 1; continue
    try:
        obj = json.loads(s.stdout)
        if isinstance(obj, list):
            obj = obj[0]
    except (json.JSONDecodeError, IndexError):
        print("  [unknown]     %s  (bd show --json 解釈不可)" % bid); counts["unknown"] += 1; continue
    updated = obj.get("updated_at") or ""
    notes = obj.get("notes") or ""
    markers = marker_re.findall(notes)
    if not markers:
        print("  [unpublished] %s  updated=%s  (%s marker 無し／未 publish 記録)" % (bid, updated, mkey))
        counts["unpublished"] += 1; continue
    pub = markers[-1]  # notes は append-only・時系列 → 末尾が最新の publish 記録。
    u_dt, p_dt = parse_iso(updated), parse_iso(pub)
    if u_dt is None or p_dt is None:
        print("  [unknown]     %s  published=%s updated=%s  (timestamp 解釈不可)" % (bid, pub, updated))
        counts["unknown"] += 1; continue
    delta = int((u_dt - p_dt).total_seconds())
    if delta > grace:
        print("  [DRIFT]       %s  published=%s  updated=%s  (+%ds: 公開後に内容 drift／再 publish 未)"
              % (bid, pub, updated, delta))
        counts["drift"] += 1
    else:
        print("  [fresh]       %s  published=%s  updated=%s" % (bid, pub, updated))
        counts["fresh"] += 1

print("---")
print("  %d beads · fresh=%d drift=%d unpublished=%d unknown=%d"
      % (len(ids), counts["fresh"], counts["drift"], counts["unpublished"], counts["unknown"]))
print("  advisory: drift/unpublished は merge/push を止めない（§8「scribe は enforce しない」）。"
      "再 publish 後は `scribe-publish-freshness.sh mark-published <id>` で provenance を更新する。")

findings = counts["drift"] + counts["unpublished"] + counts["unknown"]
sys.exit(3 if (strict and findings > 0) else 0)
PY
  exit "$rc"
}

# mark-published <bd-id> — publish provenance（Q2）を bead notes へ記録する。WRITE ゆえ bdw 経由（§3 直列化）。
cmd_mark_published() {
  local norm ts
  [[ -n "$MARK_ID" ]] || scribe_die "mark-published には <bd-id> が必要です。"
  norm="$(scribe_normalize_bd_id "$MARK_ID")" || scribe_die "不正な bd id: '$MARK_ID'"
  SCRIBE_ANCHOR="$ANCHOR" scribe_bd_id_exists "$norm" \
    || scribe_die "bd issue が存在しません: '$norm'"
  # soft warn: federate-publish ラベルの無い bead を mark するのは誤操作の可能性（advisory・block しない）。
  if ! grep -q "\"${PUBLISH_LABEL}\"" <<< "$( cd "$ANCHOR" 2>/dev/null && "$BD" show "$norm" --json 2>/dev/null )"; then
    printf 'scribe: warn: %s に %s ラベルがありません（publish 候補でない bead を mark している可能性）\n' \
      "$norm" "$PUBLISH_LABEL" >&2
  fi
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # WRITE も read（L186 実在検証 / L189 label check）と同じく **anchor スコープ**で行う（cwd でなく ANCHOR の
  # graph へ書く）。bd/bdw の graph 解決は cwd 依存ゆえ、cd せず書くと --anchor 修飾時に read=ANCHOR/write=cwd の
  # 非対称になり provenance を別 graph へ誤記録する。scribe-spawn.sh の `cd "$ANCHOR" && bdw update` 規約に一致させる。
  ( cd "$ANCHOR" && "$BDW" update "$norm" --append-notes "${MARKER_KEY}: ${ts}" ) >/dev/null \
    || scribe_die "bdw append-notes に失敗しました: $norm"
  printf 'scribe: %s に publish provenance を記録しました: %s: %s\n' "$norm" "$MARKER_KEY" "$ts"
}

case "$SUBCMD" in
  check)          cmd_check ;;
  mark-published) cmd_mark_published ;;
  *)              scribe_die "未対応の subcommand: '$SUBCMD'" ;;
esac

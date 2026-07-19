#!/usr/bin/env bash
# fleet-monitor.sh — 人間向け fleet タスクボード（read-only）
#
# 対象読者: 人間（ユーザー）専用。AI は bd/tmux を直叩きするので pane は読まない。
#   人間がちらっと見て「今 fleet で何が動いていて、次に何をすべきか」を把握できることに全振り。
#
# 表示（header 直下の 🔑 鍵失効警告 + 6 セクション・タスクボード）:
#   🔑 鍵失効警告 : tailnet 鍵の失効が近い時のみ header 直下に 1 行表示（tailnet-expiry-check.sh が
#                  書く状態ファイルを read するだけ・network 不要）。状態ファイル不在ホスト（timer 未配備）や
#                  平時(OK)は無表示＝全ホスト配布 canonical でも誤表示/noise ゼロ（旧ホスト固有 port→canonical port・orch-150）。
#   ● 稼働中     : bd in_progress + worker↔window 照合。worker 検出を ◆/✗ で示す。
#                  ◆=worker 窓検出（生存）/ ✗=窓消失した in_progress cell（可視警報＝age に関わらず残す・
#                  grill L2 sc-3pq/orch-nzd/orch-r22）。age は annotation のみ（時間 cap で無音良性化しない）。
#                  ◇（旧・admin epic 良性）は窓消失分岐から退役（time-cap silent 降格バグの是正）。
#                  degraded の構造判定（CLOSED不在×commit=0）は独立 watcher orch-degraded-watch.sh が担う。
#                  gate-pending は除外（★へ）。
#   ▶ 次にやるべき: bd ready 上位 5（in_progress 除外・priority 順・needs-user / gate-pending 除外）。
#   ★ 検品待ち   : gate-pending ラベルの非 closed issue（worker 実装完了・admin の gate 待ち＝D1）。
#                  ただし needs-user 併存時は ⚠要議論へ集約し除外（下記 disjoint 不変条件・needs-user 優先）。
#                  worker は自分で close せず gate-pending を付け DONE を出し、admin が gate+merge 後に close。
#                  各行末に **待ち時間（updated_at からの経過）** を表示（orch-edv T3・stall を人間がボードで一目）。
#   ⚠ 要議論     : needs-user ラベルの issue（admin が付与/剥奪を所有・worker は bd notes で提起）。
#                  各行末に **待ち時間（updated_at からの経過）** を表示（orch-edv T3・decision-point 停滞を一目）。
#   🔍 grill 待ち: needs-grill ラベルの非 closed issue（grill 進行中＝人間 grill 待ち）に対し、対応する
#                  consult-<id> 窓の有無を **完全一致照合** で可視化（orch-89pw・方式A・user ratify 2026-07-10）。
#                  窓あり=◆consult（対話中）/ 窓なし=consult窓なし（中断の可能性＝notice のみ・断定しない）。
#                  plain consult（consult-HHMMSS・id 非含有）は完全一致しないため対象外（誤点灯ゼロ）。
#   ─ 残         : open 総数 + P 別内訳 + anchor 状態 を 1 行に圧縮。
#
# セクション disjoint（不変条件）: gate-pending ラベル issue は ★検品待ちのみ・needs-user は ⚠要議論のみ。
#   gate-pending は free-form ラベル（事前作成不要・`bd label add gate-pending <id>` で初回自動生成。
#   needs-user と同機構）。worker cell 完了時に anchor で `bdw label add gate-pending <自 id>` を実行する。
#   両ラベル併存時（gate-pending かつ needs-user）は ⚠要議論へ集約し ★検品待ちから除外する（needs-user 優先）。
#     理由: needs-user=人間判断が未決着＝gate 不能。決着前に検品リストへ出すと「今 gate できる」と誤誘導する。
#     next-action は議論ゆえ ⚠要議論 に一本化し、二重表示（良性冗長）を解消する（orch-cuq）。
#
# worker↔issue 照合（誤検出ゼロ設計・un-jax 改善案 b 採用）:
#   spawn 命名規約を標準化し、**完全一致のみ**で点灯する:
#     - window 名 = wt-<完全bd id>（例 wt-un-chz）→ "wt-" を剥がした残りを候補 id に。
#       pane cwd が anchor へ逃げても window 名は不変なので確実に拾える（flaky cwd 耐性）。
#     - branch/worktree パス = spawn/<id>-HHMMSS（例 .worktrees/spawn/un-chz-161917）→
#       ANCHOR/.worktrees/ 配下の最終セグメント、および末尾 -<数字> を剥がした id を候補に。
#   候補 id と in_progress issue id を grep -qxF / awk $1==id の**完全一致**で照合するため、
#   wt-un-aa が un-aaa を誤点灯することはない（部分一致しない）。旧 cc-session 命名や
#   issue id 非含有の branch worktree は単に点灯しない（under-mark 許容＝誤検出より安全）。
#   consult 窓（orch-89pw）: window 名 = consult-<id>（scribe-spawn の grill consult session）も同じ完全一致
#   機構で live_workers が候補 emit し、🔍 grill 待ち節が needs-grill bead と id 完全一致で照合する（wt- と同型）。
#   plain consult（consult-HHMMSS・id 非含有）は剥いた残りが bead id と完全一致しないため構造的に非点灯。
#
# 点灯は spawn 時の bd id 解決可否依存（scribe-spawn / cc-session とも命名ロジックは規約追従済み）:
#   scribe plugin の scribe-spawn.sh 経由で起動した worker は window=wt-<完全bd id> /
#   worktree=spawn/<完全bd id>-<HHMMSS> を恒常生成するため ◆ が live 点灯する
#   （un-6br(8) で un-7hx/un-01h を実視認＝◆ … ◀ wt-un-7hx / wt-un-01h）。
#   /session:spawn --worktree スキル（cc-session 外部リポ＝本リポ管理外）も un-cbi（PR cc-session#25・
#   main マージ済み）で同じ bd id 連動命名へ追従済みで、bd id 解決時は spawn/<id>-<HHMMSS> / wt-<id> を
#   生成し ◆ 点灯する。
#   ◇（under-mark＝安全側）になるのは bd id 不明時の汎用 spawn フォールバックのみ:
#   id を捕捉できない spawn では BRANCH_NAME=spawn/<HHMMSS>-<pid>（id 非含有）・window 名も #123 検出時のみ
#   wt-123（un-xxx id 非捕捉時は wt-HHMMSS-$$）になり、この id 無しケースだけが規約名にならず ◇ のまま。
#   未追従なのは producer ではなく id-less な spawn ケース（残課題は bd id を確実に渡す/捕捉する運用のみ）。
#   詳細・追従条件は docs/session-orchestration-strategy.md §3.1 を参照。
#
# 設計: 状態を読むだけ。セッション/ファイル/サービスを一切作らない（CLAUDE.md「観測専用」）。
# 描画: in-place 無ちらつき。clear（全画面消去）は使わない。
#   左上 \033[H → 各行末 \033[K → 末尾 \033[J。描画中 \033[?25l でカーソル非表示、
#   EXIT/INT/TERM trap で必ず \033[?25h 復帰。
#
# 再現性（fleet）: ANCHOR / SESSION はハードコードせず動的解決。どのホストでもそのまま動く。
#   - ANCHOR : スクリプト実体（symlink 解決後）が属する repo の main worktree を
#              `git worktree list` 先頭から解決（= anchor）。FLEET_MONITOR_ANCHOR で上書き可。
#   - SESSION: 引数 / 環境変数 / 既定は現在の tmux セッション名。
#
# 使い方:
#   bash fleet-monitor.sh                 # ループ表示（既定 5 秒間隔・現在の tmux セッション）
#   bash fleet-monitor.sh --once          # 1 回描画して終了（capture/テスト用）
#   bash fleet-monitor.sh <session>       # 監視対象セッションを指定
#   bash fleet-monitor.sh --session <s>   # 同上（明示フラグ）
#   FLEET_MONITOR_SESSION=projalpha bash fleet-monitor.sh
#   FLEET_MONITOR_INTERVAL=10 bash fleet-monitor.sh
#   FLEET_MONITOR_ANCHOR=/path/to/repo bash fleet-monitor.sh
#   FLEET_MONITOR_STALL_MINS=120 bash fleet-monitor.sh   # stall 閾値（分・既定 360）
#   FLEET_MONITOR_NOW_EPOCH=...   bash fleet-monitor.sh   # age 算出の現在時刻を固定（test/デバッグ用）
#
# 非対応（YAGNI）: --json（機械可読モード）は作らない。AI は bd/tmux を直叩きするため不要。
# ---END-USAGE-DOC---  (usage() がこのマーカーまでを表示。doc 行追加時もズレない)
set -uo pipefail

ONCE=0
SESSION="${FLEET_MONITOR_SESSION:-}"
INTERVAL="${FLEET_MONITOR_INTERVAL:-5}"
# 時間 cap の閾値（分）。**grill L2（sc-3pq/orch-nzd/orch-r22）で主判定から降格**: 窓消失した
# in_progress cell は age に関わらず ✗（可視警報）。この閾値は annotation（age > cap で「cap超・死亡濃厚」
# を添える）にのみ使い、旧 D4 の「age 超過→◇ 無音良性化」は folio 同型 silent 降格バグゆえ撤回した。非数値は既定へ。
STALL_MINS="${FLEET_MONITOR_STALL_MINS:-360}"
case "$STALL_MINS" in *[!0-9]*|"") STALL_MINS=360 ;; esac

usage() {
  # 先頭 doc ブロック（2 行目〜終端マーカー直前）のみ表示。マーカー方式で行追加にも追従。
  sed -n '2,/^# ---END-USAGE-DOC---/p' "$0" | sed '$d'
  exit "${1:-0}"
}

# ── 引数パース ────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --once)            ONCE=1 ;;
    --session|-s)      shift; SESSION="${1:-}" ;;
    --help|-h)         usage 0 ;;
    --*)               echo "fleet-monitor: 不明なオプション: $1" >&2; usage 1 ;;
    *)                 SESSION="$1" ;;  # 位置引数 = セッション名
  esac
  shift
done

# ── ANCHOR 動的解決（共有 lib orch_anchor.sh・orch-49g で集約）───────────────
# スクリプト実体（~/.local/bin/fleet-monitor.sh は anchor の scripts/ への symlink）を辿り、その repo の main
# worktree（= anchor）を求める。`_resolve_scriptorium`（E2 anchor 検証付き・clean-probe / degraded-watch /
# dispatch と単一 SSOT）は共有 lib へ集約した（旧 resolve_anchor の byte 複製を解消・orch-49g）。lib は解決候補
# anchor の dolt_database==orch を検証し foreign repo anchor の誤採用を封鎖する（E2）。BASH_SOURCE 相対で実 lib を
# 解決するので symlink deploy でも実 lib（scripts/lib/）を見つける。
_self="${BASH_SOURCE[0]}"
_self_real=$(readlink -f "$_self" 2>/dev/null || printf '%s' "$_self")
_self_dir=$(cd "$(dirname "$_self_real")" 2>/dev/null && pwd || dirname "$_self_real")

_ORCH_ANCHOR_LIB="$_self_dir/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
  # shellcheck source=lib/orch_anchor.sh
  . "$_ORCH_ANCHOR_LIB"
else
  echo "fleet-monitor: 共有 anchor lib 不在: $_ORCH_ANCHOR_LIB（anchor 解決不能）。FLEET_MONITOR_ANCHOR で指定してください。" >&2
fi
# _resolve_scriptorium 未定義（lib 不在）でも ${VAR:-...} は command-not-found→非0→空へ倒れ、下の空 ANCHOR check が拾う。
ANCHOR="${FLEET_MONITOR_ANCHOR:-$(_resolve_scriptorium 2>/dev/null)}"
if [ -z "$ANCHOR" ]; then
  echo "fleet-monitor: ANCHOR を解決できません（git リポジトリ外）。FLEET_MONITOR_ANCHOR で指定してください。" >&2
  exit 1
fi

# ── SESSION 既定 = 現在の tmux セッション名 ───────────────
if [ -z "$SESSION" ]; then
  SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null) || true
fi

# ── bd の JSON を 1 回取得（list / ready）─────────────────
# timeout 3 で bd 応答遅延が描画を固めるのを防ぐ（timeout 不在環境はそのまま実行）。
# bd / python3 不在時は空出力（呼出側がフォールバック表示）。
_bd_json() {
  command -v bd >/dev/null 2>&1 || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local -a cmd
  case "$1" in
    ready) cmd=(bd ready --limit 0 --json) ;;
    list)  cmd=(bd list --status open,in_progress,blocked --limit 0 --json) ;;
    *)     return 0 ;;
  esac
  if command -v timeout >/dev/null 2>&1; then
    timeout 3 "${cmd[@]}" 2>/dev/null || return 0
  else
    "${cmd[@]}" 2>/dev/null || return 0
  fi
}

# ── タスクボード集計 python（stdin=bd JSON / argv[1]=mode）──
# heredoc は stdin を奪うため -c で渡す。mode ごとに TSV を 1 行ずつ emit:
#   inprogress : status==in_progress（gate-pending 除外）を priority,id 順 → "id<TAB>title<TAB>age_secs"
#                age_secs = now - updated_at（秒・int）。updated_at 不明/解析不可は空（→呼出側で ◇）。
#                now は FLEET_MONITOR_NOW_EPOCH があればそれ（test/デバッグ用）、無ければ実時刻。
#   gatepending: gate-pending ラベル(非 closed) を priority,id 順 →  "id<TAB>title<TAB>age_secs"
#                needs-user 併存行は除外（⚠要議論へ集約・節を disjoint に＝両ラベル二重表示の解消）。
#                age_secs = now - updated_at（秒・int）。updated_at 不明は空（→呼出側で待ち時間非表示）。orch-edv T3。
#   ready      : in_progress / needs-user / gate-pending を除外し priority,id 順・上位 5 → "id<TAB>P<TAB>title"
#   needsuser  : needs-user ラベル(非 closed) を priority,id 順 →  "id<TAB>status<TAB>title<TAB>age_secs"
#                age_secs = now - updated_at（秒・int）。updated_at 不明は空（→呼出側で待ち時間非表示）。orch-edv T3。
#   remaining  : status==open の総数と P 別内訳 →  "total<TAB>P0:a P1:b P2:c P3:d P4:e"
_BOARD_PY='
import json, sys, collections, os, time, datetime
mode = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    issues = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(issues, list):
    sys.exit(0)

def pr(it):
    p = it.get("priority")
    return p if isinstance(p, int) else 9

def title(it):
    return (it.get("title") or "").replace("\t", " ").replace("\n", " ")

def has_label(it, name):
    return any(isinstance(l, str) and l == name for l in (it.get("labels") or []))

def needs_user(it):
    return has_label(it, "needs-user")

def gate_pending(it):
    return has_label(it, "gate-pending")

def now_epoch():
    v = os.environ.get("FLEET_MONITOR_NOW_EPOCH")
    if v:
        try:
            return float(v)
        except Exception:
            pass
    return time.time()

def parse_epoch(s):
    # bd の updated_at は RFC3339（例 2026-06-19T05:44:37Z）。epoch 秒へ。解析不可は None。
    if not isinstance(s, str) or not s:
        return None
    t = s.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        pass
    try:
        dt = datetime.datetime.strptime(s.strip(), "%Y-%m-%dT%H:%M:%SZ")
        return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None

rows = [it for it in issues if isinstance(it, dict)]

if mode == "inprogress":
    # gate-pending は ★検品待ちへ振り分けるため除外（節を disjoint に保つ＝同一 id の二重表示防止）。
    sel = [it for it in rows if it.get("status") == "in_progress" and not gate_pending(it)]
    sel.sort(key=lambda x: (pr(x), x.get("id", "")))
    now = now_epoch()
    for it in sel:
        ep = parse_epoch(it.get("updated_at"))
        age = "" if ep is None else int(now - ep)
        print("%s\t%s\t%s" % (it.get("id", "?"), title(it), age))

elif mode == "gatepending":
    # needs-user 併存行は ⚠要議論へ集約するため除外（節を disjoint に・両ラベル二重表示の解消）。
    # 理由: needs-user=人間判断が未決着＝gate 不能。決着前に検品リストへ出すと誤誘導（next-action は議論）。
    sel = [it for it in rows
           if it.get("status") != "closed" and gate_pending(it) and not needs_user(it)]
    sel.sort(key=lambda x: (pr(x), x.get("id", "")))
    now = now_epoch()
    for it in sel:
        ep = parse_epoch(it.get("updated_at"))
        age = "" if ep is None else int(now - ep)   # 待ち時間（orch-edv T3・updated_at 不明は空）
        print("%s\t%s\t%s" % (it.get("id", "?"), title(it), age))

elif mode == "ready":
    # bd ready は in_progress を既に除外するが belt-and-suspenders で再除外。
    # needs-user は ⚠ 要議論節へ・gate-pending は ★検品待ち節へ振り分けるためここから除外（節を disjoint に保つ）。
    sel = [it for it in rows
           if it.get("status") != "in_progress" and not needs_user(it) and not gate_pending(it)]
    sel.sort(key=lambda x: (pr(x), x.get("id", "")))
    for it in sel[:5]:
        print("%s\t%s\t%s" % (it.get("id", "?"), pr(it), title(it)))

elif mode == "needsuser":
    # needs-user を持つ行はここに出す（gate-pending 併存でも＝両ラベルの一本化先・needs-user 優先）。
    sel = [it for it in rows if it.get("status") != "closed" and needs_user(it)]
    sel.sort(key=lambda x: (pr(x), x.get("id", "")))
    now = now_epoch()
    for it in sel:
        ep = parse_epoch(it.get("updated_at"))
        age = "" if ep is None else int(now - ep)   # 待ち時間（orch-edv T3・updated_at 不明は空）
        print("%s\t%s\t%s\t%s" % (it.get("id", "?"), it.get("status", "?"), title(it), age))

elif mode == "grillpending":
    # needs-grill 平ラベル完全一致の非 closed bead（grill 進行中＝人間 grill 待ち・orch-89pw）。
    # 対応 consult-<id> 窓の有無は呼出側が live_workers の consult- 候補と完全一致照合して可視化する（notice のみ）。
    sel = [it for it in rows if it.get("status") != "closed" and has_label(it, "needs-grill")]
    sel.sort(key=lambda x: (pr(x), x.get("id", "")))
    for it in sel:
        print("%s\t%s" % (it.get("id", "?"), title(it)))

elif mode == "remaining":
    opens = [it for it in rows if it.get("status") == "open"]
    c = collections.Counter(pr(it) for it in opens)
    parts = " ".join("P%d:%d" % (p, c.get(p, 0)) for p in range(5))
    print("%d\t%s" % (len(opens), parts))
'

# ── live worker 候補（id<TAB>label）─────────────────────────
# ★orch-riz1 topology 裁定記録（record-only・無改修）: session=project / 宛先正準形 `<project>:admin`（session:window）
#   への統一（top-spec §1.2・裁定 orch-thgx）に対し、本 fleet-monitor は **無改修**が裁定。理由: 下記 list-panes -a は
#   既に全 session 横断（cross-session 対応）で session=project 化に非依存。admin 窓の専用可視化は要否＝**不要**
#   （admin liveness は orch-dispatch --liveness ②/③ が session:window 正準形で担う・二重可視化を新設しない）。本ボードは
#   worker↔window 完全一致点灯に徹する。
# tmux 全 pane を走査し、誤検出ゼロの完全一致照合用に候補 id とラベルを emit。
#   - window 名 wt-<id> → "id<TAB>wt-<id>"（pane cwd 非依存＝flaky 耐性）
#   - ANCHOR/.worktrees/ 配下 pane の最終セグメント → "seg<TAB>seg"
#     さらに末尾 -<数字>（spawn/<id>-HHMMSS の HHMMSS）を剥がした id → "id<TAB>seg"
#   呼出側は awk $1==<issue id> の完全一致で照合（部分一致しない）。
live_workers() {
  tmux list-panes -a -F '#{window_name}|#{pane_current_path}' 2>/dev/null \
    | awk -F'|' -v a="$ANCHOR/.worktrees/" '
        {
          win = $1; path = $2
          # window 名由来: wt-<id>（"wt-" 接頭辞を厳密一致で剥がす）
          if (win ~ /^wt-./) {
            id = substr(win, 4)
            print id "\t" win
          }
          # window 名由来: consult-<id>（grill consult 窓・"consult-" 接頭辞を厳密一致で剥がす・orch-89pw）
          # scribe-spawn.sh:589 が consult-<正規化 bd id> を、:591 が consult-<HHMMSS>（id 非含有）を生成する。
          # 後者（plain consult）は剥いた残りが bead id と完全一致しないため grill 節で構造的に点灯しない（対象外）。
          if (win ~ /^consult-./) {
            id = substr(win, 9)               # "consult-" は 8 文字
            print id "\t" win
          }
          # path 由来: ANCHOR/.worktrees/ 配下（index()==1 で前方一致・メタ無効化）
          if (index(path, a) == 1) {
            rel = substr(path, length(a) + 1)
            sub(/\/+$/, "", rel)                 # 末尾 / 除去
            n = split(rel, seg, "/")
            base = (n >= 1) ? seg[n] : ""
            if (base != "") {
              print base "\t" base
              stripped = base
              sub(/-[0-9]+$/, "", stripped)      # 末尾 -<HHMMSS> を剥がす
              if (stripped != base && stripped != "") print stripped "\t" base
            }
          }
        }
      ' | sort -u
}

# 文字列を表示幅（東アジア全角=2）基準で省略し末尾に … を付与。
# bash の ${#s} は全角を 1 幅換算し日本語 title が溢れるため python3 で幅換算する。
# python3 不在時は素朴な文字数換算にフォールバック。
truncate_str() {
  local s="$1" n="$2"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$s" | python3 -c '
import sys, unicodedata
s = sys.stdin.read()
n = int(sys.argv[1])
def w(ch):
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
total = sum(w(c) for c in s)
if total <= n:
    sys.stdout.write(s); sys.exit(0)
# … (幅1) のぶんを残して切り詰め
acc = 0; out = []
for c in s:
    cw = w(c)
    if acc + cw > n - 1:
        break
    out.append(c); acc += cw
sys.stdout.write("".join(out) + "…")
' "$n"
  else
    if [ "${#s}" -gt "$n" ]; then
      printf '%s…' "${s:0:n-1}"
    else
      printf '%s' "$s"
    fi
  fi
}

# 待ち時間（updated_at からの経過秒）を『   (待ち Nm)』/『   (待ち NhMMm)』へ整形（orch-edv T3）。
# 空/非数値（updated_at 不明）は無表示。時計ズレ(負)は 0m にクランプ（stall 節と同型の防御）。
_fmt_wait() {
  local age="$1"
  case "$age" in
    ""|*[!0-9-]*) return 0 ;;    # 不明は無表示（updated_at 欠落）
  esac
  local a=$(( age < 0 ? 0 : age ))
  local m=$(( a / 60 ))
  if [ "$m" -ge 60 ]; then
    printf '   (待ち %dh%02dm)' $(( m / 60 )) $(( m % 60 ))
  else
    printf '   (待ち %dm)' "$m"
  fi
}

render() {
  local now; now=$(date '+%H:%M:%S')
  local out=""
  # 描画モード: plain（--once: カーソル制御・行末消去なしの clean capture）/ 既定（in-place）。
  # PLAIN=1 のとき各行末の \033[K を付けず、末尾の \033[H/\033[J も付けない。
  local EOL=$'\033[K'
  [ "${PLAIN:-0}" = "1" ] && EOL=""
  # 各行は \033[K（行末まで消去）で終端し、古い残骸を残さない（plain では無装飾）。
  _line() { out+="$1$EOL"$'\n'; }

  # bd JSON を 1 回ずつ取得（list は 3 節で再利用）
  local list_json ready_json workers
  list_json=$(_bd_json list)
  ready_json=$(_bd_json ready)
  workers=$(live_workers)

  _line "$(printf '┌─ fleet タスクボード [%s]  %ss更新  (Ctrl-C で停止) ───────' "$now" "$INTERVAL")"

  # ── 🔑 鍵失効警告（tailnet-expiry-check.sh が書く状態ファイルを read・network 不要）──
  # 状態ファイルは systemd user timer(tailnet-expiry-check.timer)が日次更新する 1 行 TSV
  #   <OK|WARN|CRIT>\t<要約>\t<epoch>。WARN/CRIT のときだけ 1 行表示（OK は無表示＝平時は不変）。
  # canonical（全ホスト配布）での安全性: データ源（状態ファイル）はホスト固有で、timer 未配備ホストでは
  #   ファイルが無く `[ -f ]` が false → 無表示。よって faithful port しても誤表示/noise は出ない（orch-150）。
  local _ke_state="${TAILNET_EXPIRY_STATE_FILE:-${XDG_RUNTIME_DIR:-/tmp}/tailnet-expiry.status}"
  if [ -f "$_ke_state" ]; then
    local _ke_level _ke_summary
    IFS=$'\t' read -r _ke_level _ke_summary _ < "$_ke_state" 2>/dev/null
    if [ "$_ke_level" = "WARN" ] || [ "$_ke_level" = "CRIT" ]; then
      local _ke_short; _ke_short=$(truncate_str "${_ke_summary:-鍵失効接近}" 48)
      _line "$(printf '🔑 鍵失効[%s] %s  → admin console で Disable key expiry' "$_ke_level" "$_ke_short")"
    fi
  fi

  # ── ● 稼働中（bd in_progress + worker↔window 照合）───────
  _line "$(printf '● 稼働中 ───────────────────────────────────────────────')"
  if [ -z "$list_json" ]; then
    _line "  (bd/python3 不在)"
  else
    local ip; ip=$(printf '%s' "$list_json" | python3 -c "$_BOARD_PY" inprogress 2>/dev/null)
    if [ -z "$ip" ]; then
      _line "  (in_progress なし)"
    else
      local stall_secs=$(( STALL_MINS * 60 ))
      # IFS=$'\t' read の受け取り変数は emit 列数(id<TAB>title<TAB>age)と厳密一致させる。
      # 変数が足りないと age が title へ食い込み裸行混入・描画崩れの再来になる（既存 bats が機械保証）。
      while IFS=$'\t' read -r id title age; do
        [ -z "$id" ] && continue
        # この issue id と完全一致する worker 候補のラベルを引く（誤検出ゼロ）
        local label=""
        [ -n "$workers" ] && label=$(printf '%s\n' "$workers" | awk -F'\t' -v k="$id" '
            $1==k {
              if ($2 ~ /^wt-/) { print $2; found=1; exit }  # window 名ラベル(wt-<id>)を最優先表示
              # consult- 候補は grill 節専用。稼働中の worker 窓ラベルには混ぜない（consult 窓＝worker 窓では
              # ないので、worker 窓不在なら consult 窓があっても稼働中は ✗ 窓消失に倒す・orch-89pw）。
              if (first=="" && $2 !~ /^consult-/) first=$2   # フォールバック: path 由来の worktree 名
            }
            # awk の exit は END へジャンプするため、found ガード無しだと first(path 由来)が
            # END で二重出力され label が 2 行値になる(裸行が _line に流れ in-place 描画が崩れる)。
            END { if (!found && first!="") print first }')
        local short; short=$(truncate_str "$title" 46)
        if [ -n "$label" ]; then
          _line "$(printf '  ◆ %-11s %s   ◀ %s' "$id" "$short" "$label")"
        else
          # window 不在: 窓消失した in_progress cell は **時間経過で無音良性化しない**（grill L2・
          # sc-3pq / orch-nzd / orch-r22）。旧 D4「age 超過なら ◇ のまま（admin 保有 epic とみなし
          # 警報しない）」は folio incident 同型の silent 降格バグ（6h 超 stall＝むしろ死亡濃厚の cell の
          # ✗ 警報を age だけで黙って消していた）ゆえ**撤回**する。時間 cap（STALL_MINS）は主判定から
          # 降格し annotation にのみ使い、窓消失は age に関わらず可視警報 ✗ を残す。CLOSED不在×commit=0 の
          # 構造判定（degraded の機械判定）は独立 watcher orch-degraded-watch.sh が主判定として担う（grill L1・
          # fleet-monitor に機械判定を詰め込まない）。旧 ◇（admin epic 良性）は本 window 不在分岐から退役
          # （fleet-monitor は window 不在 in_progress を良性/劣化に構造判別できず、grill L2 が可視警報側へ倒す）。
          local ann
          case "$age" in
            ""|*[!0-9-]*)
              ann="窓消失・時刻不明" ;;                      # age 不明でも無音化しない（可視 ✗）
            *)
              local mins=$(( (age<0?0:age) / 60 ))
              if [ "$age" -gt "$stall_secs" ]; then
                ann="窓消失 ${mins}m・cap超（長時間放置＝死亡濃厚）"   # 旧: ◇ で silent → grill L2 で可視 ✗
              else
                ann="窓消失 ${mins}m"
              fi ;;
          esac
          _line "$(printf '  ✗ %-11s %s   (stall: %s)' "$id" "$short" "$ann")"
        fi
      done <<< "$ip"
    fi
  fi

  # ── ▶ 次にやるべき（bd ready 上位 5）─────────────────────
  _line "$(printf '▶ 次にやるべき ─────────────────────────────────────────')"
  if [ -z "$ready_json" ]; then
    _line "  (bd/python3 不在)"
  else
    local rdy; rdy=$(printf '%s' "$ready_json" | python3 -c "$_BOARD_PY" ready 2>/dev/null)
    if [ -z "$rdy" ]; then
      _line "  (ready issue なし)"
    else
      while IFS=$'\t' read -r id p title; do
        [ -z "$id" ] && continue
        local short; short=$(truncate_str "$title" 44)
        _line "$(printf '  ○ %-11s %s  P%s' "$id" "$short" "$p")"
      done <<< "$rdy"
    fi
  fi

  # ── ★ 検品待ち（gate-pending ラベル＝worker 完了・admin の gate 待ち・D1）─
  _line "$(printf '★ 検品待ち ─────────────────────────────────────────────')"
  local gp=""
  [ -n "$list_json" ] && gp=$(printf '%s' "$list_json" | python3 -c "$_BOARD_PY" gatepending 2>/dev/null)
  if [ -z "$gp" ]; then
    _line "  (なし)"
  else
    while IFS=$'\t' read -r id title age; do
      [ -z "$id" ] && continue
      local short; short=$(truncate_str "$title" 46)
      local wait; wait=$(_fmt_wait "$age")
      _line "$(printf '  ★ %-11s %s%s' "$id" "$short" "$wait")"
    done <<< "$gp"
  fi

  # ── ⚠ 要議論（needs-user ラベル）─────────────────────────
  _line "$(printf '⚠ 要議論 ───────────────────────────────────────────────')"
  local nu=""
  [ -n "$list_json" ] && nu=$(printf '%s' "$list_json" | python3 -c "$_BOARD_PY" needsuser 2>/dev/null)
  if [ -z "$nu" ]; then
    _line "  (なし)"
  else
    while IFS=$'\t' read -r id st title age; do
      [ -z "$id" ] && continue
      local short; short=$(truncate_str "$title" 46)
      local wait; wait=$(_fmt_wait "$age")
      _line "$(printf '  ⚠ %-11s %s%s' "$id" "$short" "$wait")"
    done <<< "$nu"
  fi

  # ── 🔍 grill 待ち（needs-grill ラベル＋対応 consult-<id> 窓の有無・orch-89pw）───────
  # grill 進行中 bead（needs-grill 平ラベル完全一致・非 closed）に対し、対応する consult-<id> 窓の有無を
  # worker 候補との **完全一致照合**（live_workers の consult- 分岐）で示す。窓あり=◆consult（対話中）/
  # 窓なし=consult窓なし（中断の可能性＝notice のみ・断定や自律 action はしない・判断は人間＝orch-vs8 規律）。
  # plain consult（consult-HHMMSS・id 非含有）は bead id と完全一致しないため構造的に対象外（誤点灯ゼロ）。
  # 対応 bead は hydrated orch DB の read（foreign grill-issue も write-isolation 上 read は正当）。
  _line "$(printf '🔍 grill 待ち ──────────────────────────────────────────')"
  local grill=""
  [ -n "$list_json" ] && grill=$(printf '%s' "$list_json" | python3 -c "$_BOARD_PY" grillpending 2>/dev/null)
  if [ -z "$grill" ]; then
    _line "  (なし)"
  else
    while IFS=$'\t' read -r id title; do
      [ -z "$id" ] && continue
      # この grill bead id と完全一致する consult- 窓ラベルを引く（部分一致では点灯しない＝誤検出ゼロ）
      local clabel=""
      [ -n "$workers" ] && clabel=$(printf '%s\n' "$workers" | awk -F'\t' -v k="$id" '
          $1==k && $2 ~ /^consult-/ { print $2; exit }')
      local short; short=$(truncate_str "$title" 44)
      if [ -n "$clabel" ]; then
        _line "$(printf '  ◆consult %-11s %s   ◀ %s' "$id" "$short" "$clabel")"
      else
        _line "$(printf '  consult窓なし %-11s %s   (grill 窓なし＝中断の可能性)' "$id" "$short")"
      fi
    done <<< "$grill"
  fi

  # ── ─ 残（open 総数 + P 別内訳 + anchor 状態を 1 行に圧縮）─
  local total="0" pbreak="P0:0 P1:0 P2:0 P3:0 P4:0"
  if [ -n "$list_json" ]; then
    local remain; remain=$(printf '%s' "$list_json" | python3 -c "$_BOARD_PY" remaining 2>/dev/null)
    if [ -n "$remain" ]; then
      IFS=$'\t' read -r total pbreak <<< "$remain"
    fi
  fi
  # anchor 状態（dirty 数 + 同居 claude 数）
  local atracked anchstate aclaudes
  atracked=$(git -C "$ANCHOR" status --porcelain 2>/dev/null | grep -vc '^??')
  if [ "$atracked" -gt 0 ] 2>/dev/null; then
    anchstate=$(printf '⚠dirty=%s' "$atracked")
  else
    anchstate="clean"
  fi
  if [ -n "$SESSION" ] && tmux has-session -t "$SESSION" 2>/dev/null; then
    aclaudes=$(tmux list-panes -s -t "$SESSION" -F '#{pane_current_command}|#{pane_current_path}' 2>/dev/null \
               | awk -F'|' -v a="$ANCHOR" '$1=="claude" && $2==a' | wc -l)
  else
    aclaudes=0
  fi
  _line "$(printf '─ 残: open=%s  %s   anchor: %s 同居claude=%s' "$total" "$pbreak" "$anchstate" "$aclaudes")"

  out+=$(printf '└────────────────────────────────────────────────────────')"$EOL"

  if [ "${PLAIN:-0}" = "1" ]; then
    # plain: カーソル制御を一切付けない clean capture（--once 用）。
    printf '%s\n' "$out"
  else
    # in-place 描画: 左上へ移動 → 上書き → 以降を消去（clear なし＝無ちらつき）。
    # SIGWINCH 後は NEED_CLEAR=1 で一度だけ全画面消去し resize 残骸を除去（最小対応）。
    if [ "${NEED_CLEAR:-0}" = "1" ]; then
      printf '\033[2J'
      NEED_CLEAR=0
    fi
    printf '\033[H%s\033[J' "$out"
  fi
}

if [ "$ONCE" = "1" ]; then
  # --once は capture/テスト用。PLAIN=1 で \033[H/\033[J・行末 \033[K を一切付けず
  # clean capture にする（カーソル制御・trap 不要）。
  PLAIN=1 render
  exit 0
fi

# ── ループ描画: カーソル非表示 + 必ず復帰 ──────────────────
cleanup() { printf '\033[?25h'; }   # カーソル復帰（EXIT で必ず通る）
trap cleanup EXIT
# INT/TERM に加え HUP/QUIT も捕捉 — pane/window kill（常駐の主用途）で SIGHUP が飛び、
# 未捕捉だと \033[?25l（カーソル非表示）が残留して端末が壊れて見える。SIGKILL は捕捉不可。
trap 'exit 0' INT TERM HUP QUIT     # シグナル → exit → EXIT trap でカーソル復帰
# SIGWINCH（端末リサイズ）: 次の render で一度だけ全画面消去し残骸を除去（最小対応）。
NEED_CLEAR=0
trap 'NEED_CLEAR=1' WINCH
printf '\033[?25l'                  # カーソル非表示
printf '\033[2J'                    # 初回のみ全画面クリア（以降は in-place 上書き）
while true; do
  render
  sleep "$INTERVAL"
done

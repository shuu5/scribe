#!/usr/bin/env bash
# scribe-env-probe.sh — worker 実行環境の健全性 probe（sc-sau・fail-closed）。
#
# 背景（folio incident 0264028f / doobidoo 44f17714）: CC platform 層の Bash 非永続（呼出し間で
# filesystem 変更が消える・intermittent）で worker が commit/test できないのに self-verify を誤 PASS した。
# cell-quality の self-test fail-closed は test の「失敗」しか守らず、env 劣化による「誤 PASS」は塞げない。
# 本 probe は worker が done を申告する前に env 劣化を検出して fail-closed させる（sandbox は無関与＝
# 真因は CC infra ゆえ worker では直せない→検出して停止するのが唯一効く防御）。
#
# 検出する2つの劣化:
#   (1) cross-call filesystem 非永続: `plant` で sentinel を書き、**別の Bash 呼出し**での `verify` が
#       読み戻せるか。呼出し間で消えていたら劣化（folio の /tmp ファイル消失と同型）。
#       重要: shell 変数は Bash 呼出し間で消えるため、token は plant の stdout を **LLM が文脈で控えて**
#       verify に文字列で渡す（呼出し間で生きる唯一の確実な channel）。
#   (2) commit 非永続/未実装: done 主張なのに <base>..HEAD が 0 commit なら劣化（folio で 0 commit を実測）。
#
# fail-closed: 劣化検出時は `ENV_DEGRADED: <理由>` を stdout+stderr に出して非0 で抜ける。worker は
# done を申告せず `STATUS: blocked — env degraded …` を bdw で書いて停止する（scribe-spawn worker prompt）。
#
# sentinel パス（テスト seam = env 上書き可）:
#   SCRIBE_ENVPROBE_FILE  既定 <worktree>/.scribe-envprobe   （worktree FS の cross-call 永続を試す＝必須面。plant は
#                         この basename を worktree の共有 info/exclude へ冪等登録し verify 前の commit 混入を防ぐ＝sc-zin）
#   SCRIBE_ENVPROBE_TMP   既定 /tmp/.scribe-envprobe          （/tmp の cross-call 永続を試す＝folio の現場・--also-tmp 時のみ・worktree 外ゆえ git 無関与）
#   SCRIBE_ENVPROBE_TOKEN plant の token を固定（テスト用・既定は uuid/乱数生成）
#
# Usage:
#   scribe-env-probe.sh plant  --worktree W
#   scribe-env-probe.sh verify --token T --worktree W [--base B] [--also-tmp]
# 終了コード: 0=ENV_OK / 1=usage・die（scribe_die・fail-loud） / 3=cross-call 非永続 / 4=0 commit。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scribe-env-probe.sh plant  --worktree W
  scribe-env-probe.sh verify --token T --worktree W [--base B] [--also-tmp]
ENV_DEGRADED:<理由> + 非0 = 環境劣化（Bash 非永続 / 0 commit）。worker は done を申告せず
`STATUS: blocked — env degraded …` を bdw で書いて停止する。
EOF
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
MODE="$1"; shift
case "$MODE" in
  plant|verify) ;;
  -h|--help) usage 0 ;;
  *) scribe_die "未知のモード: '$MODE'（plant|verify を指定）" ;;
esac

WORKTREE=""; TOKEN=""; BASE=""; ALSO_TMP=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree) scribe_need_val "${2:-}" --worktree; WORKTREE="$2"; shift 2 ;;
    --token)    scribe_need_val "${2:-}" --token; TOKEN="$2"; shift 2 ;;
    --base)     scribe_need_val "${2:-}" --base; BASE="$2"; shift 2 ;;
    --also-tmp) ALSO_TMP=1; shift ;;
    -h|--help)  usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  scribe_die "余分な引数: $1" ;;
  esac
done

[[ -n "$WORKTREE" ]] || scribe_die "--worktree（必須）がありません。"
[[ -d "$WORKTREE" ]] || scribe_die "--worktree がディレクトリではありません: $WORKTREE"

SENT_FILE="${SCRIBE_ENVPROBE_FILE:-$WORKTREE/.scribe-envprobe}"
# /tmp sentinel は worktree から導く一意名（並列 worker が /tmp/.scribe-envprobe を奪い合って
# false ENV_DEGRADED を出すのを防ぐ・sc-sau）。plant/verify は同一 --worktree ゆえ同一パスに解決する。
_wt_hash="$(printf '%s' "$WORKTREE" | cksum | cut -d' ' -f1)"
SENT_TMP="${SCRIBE_ENVPROBE_TMP:-/tmp/.scribe-envprobe-$_wt_hash}"

# ---- plant: sentinel を書き token を stdout へ ----
if [[ "$MODE" == plant ]]; then
  tok="${SCRIBE_ENVPROBE_TOKEN:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "$$-${RANDOM}-${RANDOM}-${RANDOM}")}"
  # sentinel を撒く前に worktree の共有 info/exclude へ登録する（責任の局所化・sc-zin/un-ejfc）。worker prompt
  # (scribe-spawn §2) は plant(着手時)→実装→commit→verify(self-report 直前) の順で、commit が verify(sentinel を
  # 掃除する下の trap)より前に起きる。sentinel が worktree の .gitignore に無い他プロジェクトの worktree では
  # scribe-add / 素の `git add -A` が untracked sentinel を stage し commit へ混入させる(uns un-smnk 実事故
  # be8c199→amend 除外)。撒く主体(plant)が撒く前に info/exclude へ冪等登録して混入経路を構造的に塞ぐ。既定名は
  # .scribe-envprobe（SENT_FILE の basename＝sc-sau で anchor .gitignore にも登録済の名と一致）。best-effort＝
  # 登録不能でも plant 本務(sentinel 書込み)は殺さず、verify の trap 掃除で二重防御（/tmp sentinel は worktree 外で対象外）。
  scribe_write_exclude "$WORKTREE" "$(basename "$SENT_FILE")" || true
  # worktree 面は必須（書込み自体が失敗したら即 fail-loud＝env がもう壊れている）。
  printf '%s\n' "$tok" > "$SENT_FILE" || scribe_die "sentinel 書込み失敗(worktree 面): $SENT_FILE"
  # /tmp 面は best-effort（sandbox 等で /tmp が writable でない場合に plant を殺さない）。
  printf '%s\n' "$tok" > "$SENT_TMP" 2>/dev/null || echo "scribe-env-probe: warn: /tmp sentinel を書けず（verify は --also-tmp を外すこと）: $SENT_TMP" >&2
  printf '%s\n' "$tok"
  exit 0
fi

# ---- verify: 別 Bash 呼出しから sentinel を読み戻して永続を判定 ----
[[ -n "$TOKEN" ]] || scribe_die "--token（必須・plant が出力した token を文脈から渡す）がありません。"

# どの exit（ENV_OK / degraded 3,4 / die）でも sentinel を残さない。degraded 経路で worktree に残ると
# worker の git add に巻き込まれ・admin の引取り worktree を汚す（review#4/#7）。trap で全 exit を掃除。
trap 'rm -f "$SENT_FILE" "$SENT_TMP" 2>/dev/null || true' EXIT

degraded() { printf 'ENV_DEGRADED: %s\n' "$1"; printf 'ENV_DEGRADED: %s\n' "$1" >&2; exit "${2:-3}"; }

check_sentinel() { # <label> <path>
  local label="$1" path="$2" got
  [[ -f "$path" ]] || degraded "cross-call filesystem 非永続（sentinel 消失: $label=$path・plant→verify 間で消えた＝Bash 呼出し間で FS が永続していない）" 3
  got="$(cat "$path" 2>/dev/null || true)"
  [[ "$got" == "$TOKEN" ]] || degraded "cross-call filesystem 非永続/破損（sentinel 不一致: $label=$path・expected='$TOKEN' got='$got'）" 3
}

check_sentinel "worktree" "$SENT_FILE"
[[ "$ALSO_TMP" -eq 1 ]] && check_sentinel "tmp" "$SENT_TMP"

# commit 永続/実装有無（--base 指定時のみ）: base..HEAD が 0 commit なら劣化/未実装。
if [[ -n "$BASE" ]]; then
  if ! count="$(scribe_git -C "$WORKTREE" rev-list --count "$BASE..HEAD" 2>/dev/null)"; then
    scribe_die "commit-count を取得できません（base が解決不能?: '$BASE'・worktree=$WORKTREE）"
  fi
  [[ "$count" =~ ^[0-9]+$ ]] || scribe_die "commit-count が数値でありません（内部異常）: '$count'"
  [[ "$count" -gt 0 ]] || degraded "base..HEAD が 0 commit（worker の実装が永続していない/未コミット＝done を申告できない）: base=$BASE worktree=$WORKTREE" 4
fi

# 健全 → ENV_OK（sentinel 掃除は上の trap EXIT が全 exit 共通で行う）。
printf 'ENV_OK\n'
exit 0

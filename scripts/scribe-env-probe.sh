#!/usr/bin/env bash
# scribe-env-probe.sh — worker 実行環境の健全性 probe（sc-sau・fail-closed）。
#
# 背景（folio incident 0264028f / doobidoo 44f17714）: CC platform 層の Bash 非永続（呼出し間で
# filesystem 変更が消える・intermittent）で worker が commit/test できないのに self-verify を誤 PASS した。
# cell-quality の self-test fail-closed は test の「失敗」しか守らず、env 劣化による「誤 PASS」は塞げない。
# 本 probe は worker が done を申告する前に env 劣化を検出して fail-closed させる（sandbox は無関与＝
# 真因は CC infra ゆえ worker では直せない→検出して停止するのが唯一効く防御）。
#
# 検出する3つの劣化:
#   (1) cross-call filesystem 非永続: `plant` で sentinel を書き、**別の Bash 呼出し**での `verify` が
#       読み戻せるか。呼出し間で消えていたら劣化（folio の /tmp ファイル消失と同型）。
#       重要: shell 変数は Bash 呼出し間で消えるため、token は plant の stdout を **LLM が文脈で控えて**
#       verify に文字列で渡す（呼出し間で生きる唯一の確実な channel）。
#   (2) commit 非永続/未実装: done 主張なのに <base>..HEAD が 0 commit なら劣化（folio で 0 commit を実測）。
#   (3) .git 書込劣化（read-only 化）: verify の度に commit の**実書込先ディレクトリ**（per-worktree の GIT_DIR＝
#       index/HEAD 面 + 共有 GIT_COMMON_DIR/objects＝loose object 面）へ touch/rm ラウンドトリップし、書込不能を
#       検出する（sc-owj・folio-229 偽陰性）。既存 commit がある状態で .git が read-only mount 化すると (1)(2) は共に
#       PASS するが commit を新規 produce できない——「検証は全部走るのに成果を commit できない」空回りになる。この面は
#       (1)(2) の検出圏外だった。ルートでなく実書込 subdir を狙うため objects のみ RO の部分劣化も捕捉する。
#
# fail-closed: 劣化検出時は `ENV_DEGRADED: <理由>` を stdout+stderr に出して非0 で抜ける。worker は
# done を申告せず `STATUS: blocked — env degraded …` を bdw で書いて停止する（scribe-spawn worker prompt）。
#
# verify は再入可能（sc-0d2）: ENV_OK は sentinel を温存し、同じ token で何度でも verify できる。
# worker prompt は self-report を cell-quality 呼出しと gate-pending 付与の 2 時点で踏むため、単回使用
# （ENV_OK でも trap が sentinel を消費する旧設計）だと 2 回目の verify が偽 ENV_DEGRADED になる
# （folio-c5r.5 実測・doobidoo 79d41450）。sentinel 掃除は degraded/die 経路のみ（下の trap 注記）。
#
# sentinel パス（テスト seam = env 上書き可）:
#   SCRIBE_ENVPROBE_FILE  既定 <worktree>/.scribe-envprobe   （worktree FS の cross-call 永続を試す＝必須面。plant は
#                         この basename を worktree の共有 info/exclude へ冪等登録し verify 前の commit 混入を防ぐ＝sc-zin）
#   SCRIBE_ENVPROBE_TMP   既定 /tmp/.scribe-envprobe          （/tmp の cross-call 永続を試す＝folio の現場・--also-tmp 時のみ・worktree 外ゆえ git 無関与）
#   SCRIBE_ENVPROBE_TOKEN plant の token を固定（テスト用・既定は uuid/乱数生成）
#
# Usage:
#   scribe-env-probe.sh plant    --worktree W
#   scribe-env-probe.sh verify   --token T --worktree W [--base B] [--also-tmp]
#   scribe-env-probe.sh classify   # 失敗 Bash 呼出しの stderr を stdin から分類（症状 A=bwrap launch-race 判定・un-9c8d）
# 終了コード: 0=ENV_OK / 1=usage・die（scribe_die・fail-loud） / 3=cross-call 非永続 / 4=0 commit / 5=.git 書込劣化（sc-owj）。
#   （classify は分類 advisory ゆえ常に exit0＝劣化コードを持たない。TRANSIENT_LAUNCH_RACE/PASS_THROUGH を stdout に出す。）
# 意味論の単一 SSOT = docs/protocol.md §6「env 劣化 exit code catalog」（sc-sbb 案B で実体移設。
# 本ヘッダは実装注記＝drift したら §6 の表が勝つ）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scribe-env-probe.sh plant    --worktree W
  scribe-env-probe.sh verify   --token T --worktree W [--base B] [--also-tmp]
  scribe-env-probe.sh classify           # 失敗 Bash 呼出しの stderr を stdin から分類（症状 A=bwrap launch-race か否か）
ENV_DEGRADED:<理由> + 非0 = 環境劣化（Bash 非永続 / 0 commit / .git 書込不能）。worker は done を申告せず
`STATUS: blocked — env degraded …` を bdw で書いて停止する。
classify は TRANSIENT_LAUNCH_RACE（症状 A・再実行）/ PASS_THROUGH（本表の exit code 判定へ）を stdout に出す（un-9c8d）。
EOF
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
MODE="$1"; shift
case "$MODE" in
  plant|verify|classify) ;;
  -h|--help) usage 0 ;;
  *) scribe_die "未知のモード: '$MODE'（plant|verify|classify を指定）" ;;
esac

# ---- classify: 失敗した Bash 呼出しの stderr を分類する（症状 A=bwrap launch-race か否か・un-9c8d）----
# 症状 A（bwrap launch-race）: worker の Bash 呼出しが **launch 時**に
#   `bwrap: Can't get type of source …/.git/*.lock: No such file or directory` で exit1 する事象。
#   locus = **CC 組込み sandbox**（共有 `.git` を writable〔config/hooks は拒否〕にするため `.git` 直下を
#   per-entry bind 列挙する層）が、共有 common-dir への並行 git atomic config write（config.lock を
#   create→rename→unlink）と race し、bind source が bwrap の stat() 到達前に消えて起きる。scribe は `.git` を
#   一切 bind 列挙しない（`grep config.lock`=0 / gen-sandbox allowWrite は `.beads` runtime+lock 鍵のみ / 本
#   env-probe は自前 bwrap 非起動＝launch 失敗時は script 本体が走る前）ゆえ **repo からは launch を retry でき
#   ない**（race の恒久除去は CC 側 escalation）。再実行で必ず消える transient なので worker は同一コマンドを
#   1 回だけ再実行し、ENV_DEGRADED/STATUS: blocked と記録しない（症状 B＝env-probe が機械判定した真の劣化＝
#   exit 3/4/5 とは別物）。意味論 SSOT = docs/protocol.md §6「env 劣化 exit code catalog」症状 A 注記。
# 判定は署名一致のみ（stderr を stdin から読む・exit code に依存しない）。認識できない失敗は PASS_THROUGH＝
# 通常の exit code 判定へ委ねる（真の劣化を transient と誤って握りつぶさない＝**マスキング回帰の番人**）。
if [[ "$MODE" == classify ]]; then
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage 0 ;;
      --) shift; break ;;
      *) scribe_die "classify は引数を取りません（stderr は stdin から渡す）: $1" ;;
    esac
  done
  _cls_err="$(cat)"
  # bwrap の bind-source 消失（共有 `.git` 直下の transient lockfile が stat 前に消える）signature。
  # case/apostrophe に寛容（-i・`can.?t`）。`.git/*.lock` に限定して genuine な非 lock source 欠落を
  # 誤って transient と判定しない（config.lock/index.lock/packed-refs.lock 等 git atomic-write 鍵は共通機序）。
  if printf '%s' "$_cls_err" \
       | grep -Eiq "bwrap:.*can.?t get type of source .*/\.git/[^ ]*\.lock: no such file or directory"; then
    printf 'TRANSIENT_LAUNCH_RACE\n'
    exit 0
  fi
  printf 'PASS_THROUGH\n'
  exit 0
fi

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
  # 登録不能でも plant 本務(sentinel 書込み)は殺さず、verify が ENV_OK 経路で冪等再登録・degraded/die 経路で
  # trap 掃除して二重防御（/tmp sentinel は worktree 外で対象外・sc-0d2 で ENV_OK 掃除→温存に変更）。
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

# degraded(3,4,5)/die 経路では sentinel を残さない——残ると worker の git add に巻き込まれ・admin の
# 引取り worktree を汚す（review#4/#7）。ENV_OK 経路は末尾で trap を解除して sentinel を温存する
# （verify 再入可能化・sc-0d2。ignored な sentinel は git add にも `git worktree remove` にも掛からない＝
# 検証済み。/tmp 面は既定 sandbox では plant が書けず（read-only・--also-tmp も落ちる＝sc-3lj）残置は
# 非 sandbox 経路のみ。worktree パスは spawn ごと一意ゆえ次 plant の上書きは期待できず OS の /tmp 掃除に委ねる）。
trap 'rm -f "$SENT_FILE" "$SENT_TMP" 2>/dev/null || true' EXIT

degraded() { printf 'ENV_DEGRADED: %s\n' "$1"; printf 'ENV_DEGRADED: %s\n' "$1" >&2; exit "${2:-3}"; }

# .git 書込可否 probe（sc-owj・folio-229 偽陰性）: commit の**実書込先ディレクトリ**へ touch/rm ラウンド
# トリップして「今 commit の write ができるか」を試す。既存 commit がある状態で .git が read-only mount 化
# しても sentinel 永続(3)・0-commit(4) は共に PASS するため検出圏外だった面をここで塞ぐ。commit が実際に
# write する面を probe する（.git ルート直下だけ writable で subtree が RO の部分劣化＝objects の read-only
# 共有 bind-mount 等も捕捉するため、ルートでなく実書込 subdir を狙う・gate 指摘 sc-owj）:
#   - GIT_DIR 直下（index / HEAD の per-worktree 面。両者は git-dir 直下ゆえルート probe が同 dir を試す）
#   - GIT_COMMON_DIR/objects（commit が loose object を書く共有面。無ければ common-dir 直下へフォールバック）
# probe file は .git 内部ゆえ commit 混入せず・毎回 touch→rm の transient で sentinel 温存 semantics(sc-0d2)
# と無干渉。非 git worktree（テスト seam 等）は git-path が解決不能 → no-op で skip（probe 対象が無い＝この
# 面の劣化は起こりえない。実 worker は常に git worktree）。
git_write_probe() {
  local gd cd p probe
  local -a targets
  gd="$(scribe_git -C "$WORKTREE" rev-parse --absolute-git-dir 2>/dev/null)" || return 0
  cd="$(scribe_git -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)" || cd="$gd"
  # --git-common-dir は相対（"." 等）を返しうる → worktree 起点で絶対化してから probe する。
  case "$cd" in /*) : ;; *) cd="$WORKTREE/$cd" ;; esac
  targets=( "$gd" )                                    # index / HEAD 面（GIT_DIR 直下）
  if [[ -d "$cd/objects" ]]; then                      # loose object の実書込先（共有面）
    targets+=( "$cd/objects" )
  else
    targets+=( "$cd" )                                 # 想定外だが objects 不在なら common-dir 直下へフォールバック
  fi
  for p in "${targets[@]}"; do
    [[ -d "$p" ]] || continue
    probe="$p/.scribe-wprobe.$$"
    ( : > "$probe" ) 2>/dev/null \
      || degraded ".git 書込劣化（$p へ新規 write 不能＝read-only mount 等で commit を produce できない・既存 commit があっても done を申告できない・folio-229）" 5
    rm -f "$probe" 2>/dev/null || true
  done
  return 0
}

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
  [[ "$count" -gt 0 ]] || degraded "base..HEAD が 0 commit（worker の実装が永続していない/未コミット＝done を申告できない）: base=$BASE worktree=$WORKTREE ／ 実装をまだ commit していないならこれは正常であり env 劣化ではない（verify を commit より前に呼んだ『早すぎる呼出し』の可能性）——commit 後に verify --base を 1 回だけ再実行（ただし前段の exit4 で sentinel は掃除済みゆえ、再 verify の前に plant で sentinel を再設置し新 token を控え直すこと＝再 plant なしの再 verify は sentinel 不在で偽 exit3 になる）し、それでも 0 commit のときだけ劣化として扱え（sc-bp7）" 4
fi

# .git 書込可否（sc-owj）: 上の sentinel/0-commit を通過しても .git が read-only 化していれば commit を
# 新規 produce できない（folio-229 偽陰性）。ENV_OK を出す前に必ず probe する（--base の有無に依らず・
# 「今 write できるか」は commit 段の前提）。degraded 検出時は exit 5＝trap が sentinel を掃除する。
git_write_probe

# 健全 → ENV_OK。trap を解除して sentinel を温存する（verify 再入可能・sc-0d2）。plant の info/exclude
# 登録が失敗していた場合の第二防御として、ENV_OK の度に冪等再登録する（best-effort・非 git worktree は no-op）。
scribe_write_exclude "$WORKTREE" "$(basename "$SENT_FILE")" || true
trap - EXIT
printf 'ENV_OK\n'
exit 0

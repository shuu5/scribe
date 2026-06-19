#!/usr/bin/env bash
# scribe-origin-guard.sh — 共有 .git/config の origin URL 汚染を防ぐ道具（bd un-1n1）。
#
# worktree は anchor と `.git/config`（remotes）を **共有** する。worker が origin を mutate すると
# anchor+全 worktree の origin が壊れ admin の push が破綻する（2026-06-16 un-v5x funnel 実害）。
# 本道具は protocol.md §1 spawn（canonical origin を per-worktree marker へ捕捉）と §5 gate funnel
# （push 前に origin 健全性を verify・汚染なら fail-loud+復元）の規約をコード化する薄い CLI。
# 機構の実体は lib/scribe-lib.sh の scribe_{capture,verify,restore}_origin。
#
# marker は per-worktree の private git dir（`.git/worktrees/<name>/scribe-origin.marker`）に置く
# ＝共有 config と別物ゆえ worker の config 汚染を生き延び、worktree working tree 外ゆえ worker の
#   編集スコープ外（誤コミット不可）。
#
# Usage:
#   scribe-origin-guard.sh capture --worktree <path> [--repo <path>]
#   scribe-origin-guard.sh verify  --worktree <path> [--repo <path>] [--restore]
#   scribe-origin-guard.sh restore --worktree <path> [--repo <path>]
# Subcommands:
#   capture   spawn 時: <repo> の canonical origin URL を marker へ捕捉する（origin 無しは no-op）。
#   verify    gate 時: marker と現在 origin を照合。健全=exit 0 / 汚染=exit 非0（canonical URL を stdout）。
#             --restore 併用で、汚染検知時に marker から復元してから exit 非0（fail-loud は維持）。
#             既定では marker 不在=照合不能ゆえ skip=exit 0（**意図的 fail-open**: origin 無しの新規リポ/
#             dogfood は保護対象が無く marker も作られないため gate を素通りすべき）。これを厳格化したい
#             個別 gate は --require-marker を additive opt-in で付ける（sc-vuu facet2）。--require-marker 下の
#             marker 不在は origin 現存なら fail-loud（真の漏れ）・origin 無しなら exit0（正当 no-op）＝sc-cw6。
#             default を非0 へ反転する移行条件は docs/protocol.md §5（全 spawn marker 捕捉保証 + gate 自動配線）。
#   restore   marker の canonical URL で origin を復元する（汚染検知後の手動復元）。
# Options:
#   --worktree PATH  対象 worktree（必須・marker の所在）。
#   --repo PATH      origin remote を持つ git リポジトリ（既定: --worktree の所属 main worktree）。
#                    config 共有のため worktree/repo どちらでも origin は同一だが、admin の心象に合わせ既定は main。
#   --restore        verify が汚染を検知したとき marker から復元する（verify サブコマンド専用）。
#   --require-marker verify で marker 不在を厳格化する（verify 専用・既定挙動は不変）。marker 不在は origin 現存
#                    なら fail-loud（真の漏れ）・origin 無しなら exit0（正当 no-op を誤検知しない）・probe 失敗は
#                    fail-closed（sc-cw6）。
#   -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scribe-origin-guard.sh capture --worktree <path> [--repo <path>]
  scribe-origin-guard.sh verify  --worktree <path> [--repo <path>] [--restore] [--require-marker]
  scribe-origin-guard.sh restore --worktree <path> [--repo <path>]
Subcommands:
  capture   spawn 時: canonical origin URL を per-worktree marker へ捕捉（origin 無しは no-op）
  verify    gate 時: marker と現在 origin を照合（健全=0 / 汚染=非0・canonical URL を stdout）
            --restore 併用で汚染検知時に復元してから非0 終了（fail-loud 維持）
            既定は marker 不在=skip=exit0（意図的 fail-open）。--require-marker で厳格化（origin 現存のみ非0・sc-cw6）
  restore   marker の canonical URL で origin を復元
Options:
  --worktree PATH  対象 worktree（必須）
  --repo PATH      origin を持つリポジトリ（既定: --worktree の所属 main worktree）
  --restore        verify が汚染検知時に復元する（verify 専用）
  --require-marker verify の marker 不在を厳格化: origin 現存=fail-loud/origin 無し=exit0/probe 失敗=fail-closed（verify 専用・sc-cw6）
  -h | --help
EOF
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
SUBCMD=""
case "$1" in
  capture|verify|restore) SUBCMD="$1"; shift ;;
  -h|--help) usage 0 ;;
  -*) scribe_die "未知のオプション: $1（先頭にサブコマンド capture/verify/restore が必要）" ;;
  *) scribe_die "未知のサブコマンド: $1（capture/verify/restore のいずれか）" ;;
esac

WORKTREE=""
REPO=""
DO_RESTORE=0
REQUIRE_MARKER=0   # sc-vuu facet2: verify で marker 不在を fail-loud にする additive opt-in（既定 0=従来 skip）。

while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)       scribe_need_val "${2:-}" --worktree; WORKTREE="$2"; shift 2 ;;
    --repo)           scribe_need_val "${2:-}" --repo; REPO="$2"; shift 2 ;;
    --restore)        DO_RESTORE=1; shift ;;
    --require-marker) REQUIRE_MARKER=1; shift ;;
    -h|--help)        usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  scribe_die "余分な引数: $1（--worktree/--repo で指定してください）" ;;
  esac
done

[[ -n "$WORKTREE" ]] || scribe_die "--worktree（必須）がありません。Usage は --help。"
[[ "$DO_RESTORE" -eq 0 || "$SUBCMD" == "verify" ]] || scribe_die "--restore は verify サブコマンド専用です。"
[[ "$REQUIRE_MARKER" -eq 0 || "$SUBCMD" == "verify" ]] || scribe_die "--require-marker は verify サブコマンド専用です。"

# --repo 既定 = --worktree の所属 main worktree（config 共有ゆえ origin は同一だが admin の心象に合わせる）。
# 導出できなければ worktree 自身へ縮退（linked でない/単独リポでも動く）。
if [[ -z "$REPO" ]]; then
  REPO="$(scribe_owning_repo "$WORKTREE" 2>/dev/null)" || REPO=""
  [[ -n "$REPO" ]] || REPO="$WORKTREE"
fi

case "$SUBCMD" in
  capture)
    scribe_capture_origin "$REPO" "$WORKTREE" \
      || scribe_die "origin の捕捉に失敗しました（worktree=$WORKTREE が git worktree でない可能性）"
    marker="$(scribe_origin_marker_path "$WORKTREE")"
    if [[ -f "$marker" ]]; then
      echo "captured: origin=$(cat "$marker") marker=$marker"
    else
      echo "captured: origin 無し（保護対象なし・marker 未作成） worktree=$WORKTREE"
    fi
    ;;
  verify)
    # --require-marker（additive opt-in・sc-vuu facet2 / sc-cw6）: marker 不在を skip(fail-open) でなく厳格化する。
    # 既定（--require-marker なし）は scribe_verify_origin が marker 不在=skip=exit0（意図的 fail-open・
    # tests AC 不変）。lib 関数は「健全」と「marker 不在 skip」をどちらも return 0 に畳むため、ここで
    # marker の実在を先に検査して厳格化する（lib 非改変＝既定経路は byte 不変。default 反転条件は protocol.md §5）。
    if [[ "$REQUIRE_MARKER" -eq 1 ]]; then
      _marker="$(scribe_origin_marker_path "$WORKTREE" 2>/dev/null || true)"
      if [[ -z "${_marker:-}" || ! -f "$_marker" ]]; then
        # marker 不在。sc-cw6: 「origin 現存なのに marker 無い(=真の漏れ・spawn 時の捕捉漏れ)」と「origin が
        # そもそも無い(=正当 no-op・capture も origin 無しなら marker を作らない)」を区別し、前者だけ fail-loud に
        # 倒す。後者まで非0 にすると、守る対象が無いリポの push を誤って止める false-positive(footgun)になる。
        # origin 現存 probe は移植性の高い `git remote` 一覧で origin の有無を見る（get-url の exit2/exit128 依存より
        # git 版差に堅牢）。probe 自体が落ちる稀ケース（$REPO 異常で git remote 非0）は origin 現存を判定できない＝
        # --require-marker の strict 意図に従い fail-closed（非0）に倒す（sc-cw6 論点1）。
        if _remotes="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$REPO" remote 2>/dev/null)"; then
          if printf '%s\n' "$_remotes" | grep -qx origin; then
            scribe_die "--require-marker: origin が現存するのに marker が不在です（spawn 時の捕捉漏れ＝真の漏れ・origin 健全性を verify できない）: repo=$REPO worktree=$WORKTREE"
          fi
          echo "origin OK（保護対象なし: origin 未設定ゆえ marker 不要・strict でも素通す）: repo=$REPO"
          exit 0
        fi
        scribe_die "--require-marker: origin の現存を判定できませんでした（git remote 失敗＝repo=$REPO が異常な可能性・strict ゆえ fail-closed）: worktree=$WORKTREE"
      fi
    fi
    if canonical="$(scribe_verify_origin "$REPO" "$WORKTREE")"; then
      echo "origin OK（健全）: repo=$REPO"
      exit 0
    fi
    # 汚染検知（scribe_verify_origin が非0・stderr に差分・stdout に canonical URL）。
    if [[ "$DO_RESTORE" -eq 1 && -n "$canonical" ]]; then
      scribe_restore_origin "$REPO" "$WORKTREE" \
        && echo "restored: origin を marker から復元しました（repo=$REPO origin=$canonical）" >&2 \
        || scribe_die "origin の復元に失敗しました（repo=$REPO）"
    fi
    # canonical URL を stdout へ再出力（lib 関数と契約を揃える＝復元用に machine-readable）。
    [[ -n "$canonical" ]] && printf '%s\n' "$canonical"
    # fail-loud は維持する（汚染が起きた事実を非0 で上流へ伝える）。
    exit 1
    ;;
  restore)
    scribe_restore_origin "$REPO" "$WORKTREE" \
      || scribe_die "origin の復元に失敗しました（marker 不在/空 or repo=$REPO）"
    marker="$(scribe_origin_marker_path "$WORKTREE")"
    echo "restored: origin=$(cat "$marker") repo=$REPO"
    ;;
esac

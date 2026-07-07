#!/usr/bin/env bash
# scribe-gate-attest.sh — gate の ground-truth 証跡プロデューサ（sc-ex2・幻影 backstop の機械化）。
#
# 背景（十全性監査 wf_c2cd03d4 agent D・2026-07-07）: 幻影（confabulation）の実効 backstop は admin gate の
# 独立 env 検証（protocol.md §5「gate の 3 義務」(b) selfTestCmd 再実行）ただ一つだが、実行者の admin 自身が
# xhigh 長ターンの幻影発生源で、その再実行に**機械強制も証跡も無い**（塔の頂点に検証層が無い）。本道具は
# gate の ground-truth 三点を『**実際に叩いた**証跡』として機械記録し、read-only subagent（scribe:explore）へ
# 構造分離できる形にする。admin が anchor で叩く想定（worker sandbox 内では使わない）。
#
# 三点（protocol.md §5「gate の 3 義務」）:
#   (b) selfTestCmd 再実行     → worktree で自ら再実行し exit code + 出力 sha256 + cmd sha256 を記録。
#                                actor 報告の「self-test PASS」を信じず ground-truth を取る。
#   commit-count（Layer2）     → base..HEAD の commit 数（= **liveness**。completeness ではない）。
#                                加えて base...HEAD の changed-files を列挙し touch-check の基盤にする。
#   (a) acceptance 逐条        → 意味判定は admin 領分（機械化不能）。本道具は --acceptance-file を受けたとき
#                                だけ逐条 scaffold（未記入 checklist）を emit する。PASS/FAIL の裁定は admin/
#                                subagent が埋め、埋めたものを record する（道具は判定を捏造しない）。
#   (4) transcript-forensics   → worker .jsonl の tool_use / tool_result **件数**と marker **件数**を報告。
#                                先例 4 件（un-df2 / orch-wzq / orch-8dl / scm-5gp）が transcript-verified。
#
# 監視トリガー衛生（protocol.md §6・最重要の設計制約）: 本道具の**出力（= bd notes へ入る証跡）には検知
#   文字列を verbatim で焼かない**。transcript の marker raw grep も**件数のみ**を出し、一致した生行は出さない
#   （引用・説明でも monitor が実 signal と誤発火するため）。header は独自の `[SCRIBE-GATE-ATTEST v1]` を使い、
#   `STATUS:` 行頭・完了ラベル文字列とは衝突しない。marker regex は admin が --marker-regex で渡す（既定は
#   件数を出さない＝トリガー literal を道具に焼かない）。
#
# read-only 分離（項目2）: `probe` は bd も git も**書かない**（selfTestCmd の再実行と git read / transcript
#   read のみ）。ゆえ scribe:explore subagent（Bash は検証実行・read に限る）から叩けて、admin 本体の長ターン
#   から独立させられる。`record`（bdw 経由の bd write）だけが admin の write 段。
#
# Usage:
#   scribe-gate-attest.sh probe  --worktree W --base B --self-test CMD [--id ID] [--anchor A]
#                                [--transcript FILE] [--marker-regex RE]
#                                [--acceptance-file F] [--acceptance-path GLOB]... [--strict]
#   scribe-gate-attest.sh record --id ID [--anchor A] [--attestation-file F] [--dry-run]
# 終了コード:
#   probe : 0=証跡を emit（selfTestCmd の成否に依らず＝証跡は exit を**記録**する。gate は block を読む）。
#           --strict 時のみ selftest-exit!=0 または commit-count==0 で非 0（機械 caller 向け fail-closed）。
#           1=usage・die（引数不備・base 解決不能 等 fail-loud）。
#   record: 0=append 成功 / 1=usage・die / bdw の非 0 はそのまま伝播。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  scribe-gate-attest.sh probe  --worktree W --base B --self-test CMD [--id ID] [--anchor A]
                               [--transcript FILE] [--marker-regex RE]
                               [--acceptance-file F] [--acceptance-path GLOB]... [--strict]
  scribe-gate-attest.sh record --id ID [--anchor A] [--attestation-file F] [--dry-run]

probe  : gate ground-truth 三点を『実際に叩いた証跡』として stdout へ emit（read-only=bd/git を書かない）。
record : その証跡を bdw 経由で bd notes へ append（admin の write 段）。
出力に検知文字列は焼かない（protocol.md §6・monitor 誤発火防止）＝件数・ハッシュのみ。
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

# sha256 の可搬ラッパ（Linux=sha256sum / macOS=shasum -a 256）。無ければ die（fail-loud）。
scribe_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | cut -d' ' -f1
  else scribe_die "sha256 ツール（sha256sum / shasum）が見つかりません"; fi
}

# ============================ record ============================
# 証跡（--attestation-file or stdin）を bdw 経由で当該 issue の notes へ append する。
if [[ "$MODE" == record ]]; then
  ID=""; ANCHOR="$(pwd)"; ATT_FILE=""; DRY_RUN=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)               scribe_need_val "${2:-}" --id; ID="$2"; shift 2 ;;
      --anchor)           scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
      --attestation-file) scribe_need_val "${2:-}" --attestation-file; ATT_FILE="$2"; shift 2 ;;
      --dry-run)          DRY_RUN=1; shift ;;
      -h|--help)          usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "未知のオプション: $1" ;;
      *)  scribe_die "余分な引数: $1" ;;
    esac
  done
  [[ -n "$ID" ]] || scribe_die "--id（必須）がありません。"
  ID="$(scribe_normalize_bd_id "$ID")" || scribe_die "bd id の形式が不正です。"
  # 証跡本文を取得（file 指定→そこから / 無ければ stdin）。
  if [[ -n "$ATT_FILE" ]]; then
    [[ -f "$ATT_FILE" ]] || scribe_die "--attestation-file が読めません: $ATT_FILE"
    CONTENT="$(cat "$ATT_FILE")"
  else
    CONTENT="$(cat)"
  fi
  [[ -n "$CONTENT" ]] || scribe_die "証跡本文が空です（probe の出力を渡してください）。"
  BDW="$SCRIPT_DIR/bdw"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    # 実 write せず bdw invocation の形を可視化（テスト・監査用）。本文は焼かず要旨のみ。
    printf 'DRY-RUN record: (cd %q && %q update %q --append-notes <%d bytes>)\n' \
      "$ANCHOR" "$BDW" "$ID" "${#CONTENT}"
    exit 0
  fi
  [[ -x "$BDW" ]] || scribe_die "bdw が実行できません: $BDW"
  ( cd "$ANCHOR" && "$BDW" update "$ID" --append-notes "$CONTENT" )
  exit $?
fi

# ============================ probe ============================
WORKTREE=""; BASE=""; SELFTEST=""; ID=""; ANCHOR="$(pwd)"
TRANSCRIPT=""; MARKER_RE=""; ACC_FILE=""; STRICT=0
ACC_PATHS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --worktree)        scribe_need_val "${2:-}" --worktree; WORKTREE="$2"; shift 2 ;;
    --base)            scribe_need_val "${2:-}" --base; BASE="$2"; shift 2 ;;
    --self-test)       scribe_need_val "${2:-}" --self-test; SELFTEST="$2"; shift 2 ;;
    --id)              scribe_need_val "${2:-}" --id; ID="$2"; shift 2 ;;
    --anchor)          scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; shift 2 ;;
    --transcript)      scribe_need_val "${2:-}" --transcript; TRANSCRIPT="$2"; shift 2 ;;
    --marker-regex)    scribe_need_val "${2:-}" --marker-regex; MARKER_RE="$2"; shift 2 ;;
    --acceptance-file) scribe_need_val "${2:-}" --acceptance-file; ACC_FILE="$2"; shift 2 ;;
    --acceptance-path) scribe_need_val "${2:-}" --acceptance-path; ACC_PATHS+=("$2"); shift 2 ;;
    --strict)          STRICT=1; shift ;;
    -h|--help)         usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1" ;;
    *)  scribe_die "余分な引数: $1" ;;
  esac
done

[[ -n "$WORKTREE" ]] || scribe_die "--worktree（必須）がありません。"
[[ -d "$WORKTREE" ]] || scribe_die "--worktree がディレクトリではありません: $WORKTREE"
[[ -n "$BASE" ]]     || scribe_die "--base（必須）がありません。"
[[ -n "$SELFTEST" ]] || scribe_die "--self-test（必須・gate が自ら再実行する ground-truth コマンド）がありません。"
[[ -z "$ID" ]] || ID="$(scribe_normalize_bd_id "$ID")" || scribe_die "bd id の形式が不正です: '$ID'"

HOST="$(hostname 2>/dev/null || echo unknown)"
UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- commit-count（liveness・Layer2 と同じ base..HEAD 二点）+ head sha ---
if ! COUNT="$(scribe_git -C "$WORKTREE" rev-list --count "$BASE..HEAD" 2>/dev/null)"; then
  scribe_die "commit-count を取得できません（base が解決不能?: '$BASE'・worktree=$WORKTREE）"
fi
[[ "$COUNT" =~ ^[0-9]+$ ]] || scribe_die "commit-count が数値でありません（内部異常）: '$COUNT'"
HEAD_SHA="$(scribe_git -C "$WORKTREE" rev-parse --short HEAD 2>/dev/null || echo '?')"

# --- changed-files（completeness 基盤・snapshot と同じ base...HEAD 三点）---
CHANGED="$(scribe_git -C "$WORKTREE" diff --name-only "$BASE...HEAD" 2>/dev/null || true)"
CHANGED_N=0
[[ -n "$CHANGED" ]] && CHANGED_N="$(printf '%s\n' "$CHANGED" | grep -c . || true)"

# --- touch-check: acceptance 対応パスに diff が触れているか（機械基盤・意味判定は admin）---
# --acceptance-path GLOB を受けたときだけ、changed-files が glob に一致するかを数える。
# 一致 0/総数 は「commit-count>0 でも acceptance 対応面に触れていない」= liveness≠completeness の可視化。
TOUCH_SUMMARY=""
if [[ ${#ACC_PATHS[@]} -gt 0 ]]; then
  matched=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    for g in "${ACC_PATHS[@]}"; do
      # shellcheck disable=SC2053  # 右辺 glob マッチを意図（引用しない）。
      if [[ "$f" == $g ]]; then matched=$((matched+1)); break; fi
    done
  done <<< "$CHANGED"
  TOUCH_SUMMARY="acceptance-path 一致 ${matched}/${CHANGED_N}（0 なら commit はあるが acceptance 対応面に未 touch＝liveness≠completeness）"
else
  TOUCH_SUMMARY="manual（--acceptance-path 未指定・上の changed-files を admin が acceptance と逐条突合）"
fi

# --- selfTestCmd 再実行（worktree で・exit + 出力 sha256 + cmd sha256）---
# set -e を外して非 0 exit を捕捉（証跡は失敗も記録する）。出力（stdout+stderr）を sha256 で fingerprint。
set +e
ST_OUT="$( cd "$WORKTREE" && bash -c "$SELFTEST" 2>&1 )"
ST_EXIT=$?
set -e
ST_OUT_SHA="$(printf '%s' "$ST_OUT" | scribe_sha256)"
ST_CMD_SHA="$(printf '%s' "$SELFTEST" | scribe_sha256)"

# --- transcript-forensics（--transcript 指定時・件数のみ・生 marker 行は出さない）---
TS_LINE=""
if [[ -n "$TRANSCRIPT" ]]; then
  if [[ -f "$TRANSCRIPT" ]]; then
    tuse="$(grep -c '"type":"tool_use"' "$TRANSCRIPT" 2>/dev/null || true)"
    tres="$(grep -c '"type":"tool_result"' "$TRANSCRIPT" 2>/dev/null || true)"
    [[ "$tuse" =~ ^[0-9]+$ ]] || tuse=0
    [[ "$tres" =~ ^[0-9]+$ ]] || tres=0
    if [[ -n "$MARKER_RE" ]]; then
      mk="$(grep -cE "$MARKER_RE" "$TRANSCRIPT" 2>/dev/null || true)"
      [[ "$mk" =~ ^[0-9]+$ ]] || mk=0
      mk_field="$mk"
    else
      mk_field="n/a（--marker-regex 未指定・件数を焼かない）"
    fi
    TS_LINE="transcript: tool_use=${tuse} tool_result=${tres} marker-hits=${mk_field}"
  else
    TS_LINE="transcript: 指定ファイルが読めません（forensics 不能・要 admin 確認）: $(basename "$TRANSCRIPT")"
  fi
fi

# --- acceptance 逐条 scaffold（--acceptance-file 指定時のみ・未記入 checklist）---
# 道具は PASS/FAIL を捏造しない。admin/subagent が `[ ]`→`[PASS]`/`[FAIL]` を根拠付きで埋め、埋めたものを
# record する（項目 a の意味判定は admin 領分）。
ACC_BLOCK=""
if [[ -n "$ACC_FILE" ]]; then
  if [[ -f "$ACC_FILE" ]]; then
    ACC_BLOCK="acceptance-scaffold（admin が逐条 PASS/FAIL を根拠付きで埋める・道具は判定しない）:"$'\n'
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      ACC_BLOCK+="  [ ] ${line}"$'\n'
    done < "$ACC_FILE"
  else
    ACC_BLOCK="acceptance-scaffold: 指定ファイルが読めません: $(basename "$ACC_FILE")"$'\n'
  fi
fi

# --- 証跡 emit（検知文字列を焼かない・件数/ハッシュのみ）---
{
  printf '[SCRIBE-GATE-ATTEST v1] id=%s host=%s cwd=%s utc=%s\n' "${ID:-'(未指定)'}" "$HOST" "$WORKTREE" "$UTC"
  printf 'commit: base=%s head=%s count=%s（count=liveness・completeness ではない）\n' "$BASE" "$HEAD_SHA" "$COUNT"
  printf 'changed-files (%s):\n' "$CHANGED_N"
  if [[ "$CHANGED_N" -gt 0 ]]; then
    printf '%s\n' "$CHANGED" | sed 's/^/  /'
  else
    printf '  (なし)\n'
  fi
  printf 'touch-check: %s\n' "$TOUCH_SUMMARY"
  printf 'self-test: exit=%s out-sha256=%s cmd-sha256=%s\n' "$ST_EXIT" "$ST_OUT_SHA" "$ST_CMD_SHA"
  [[ -n "$TS_LINE" ]] && printf '%s\n' "$TS_LINE"
  [[ -n "$ACC_BLOCK" ]] && printf '%s' "$ACC_BLOCK"
}

# --strict（機械 caller 向け fail-closed）: selftest 失敗 or 0-commit で非 0。既定は 0（証跡を出すのが本務）。
if [[ "$STRICT" -eq 1 ]]; then
  if [[ "$ST_EXIT" -ne 0 ]]; then exit 6; fi
  if [[ "$COUNT" -eq 0 ]]; then exit 7; fi
fi
exit 0

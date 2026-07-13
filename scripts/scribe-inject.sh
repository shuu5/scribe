#!/usr/bin/env bash
# scribe-inject.sh — admin 操舵注入の「送達確認つき」pane inject ヘルパ（sc-6vj・fail-closed）。
#
# 背景（sc-3hg → sc-6vj・2026-07-08 に live 実証）: 現行 tmux 環境は全 pane pipe=0 /
# after-send-keys hook 未バインドで、pane 入力欄への send-keys が「送達したか」を事後確認する層が無い。
# 同日 admin 操舵注入の送達失敗が 2 度実発生した:
#   (A) errata 指示が bracketed paste として入力欄に滞留し未送信（ポーラ 40 分 timeout で発覚→Enter 追送で回復）。
#   (B) durable note 指示が `-l` 逐字送信でも未送信のまま滞留し、pane 目視でも『送信済み』と誤判定した。
# → 対策の核 = 「送信後に入力欄へテキストが残留していないことの機械検知・残留時 fail-loud」（sc-6vj acceptance）。
#
# 設計判断（issue の a/b/導入否・rationale は gate で admin が裁く）:
#   (a) global session-created hook で pipe-pane 自動起動 = 見送り。pipe-pane は pane *出力* 側の log で
#       「入力の出所」を辿れず、本 repo は tmux.conf を所有しない（env 設定=dotfiles・worker scope 外）。
#       加えて live server の global hook 変更は 2026-04-22 の session 消失事故の前例があり不可逆リスク。
#   (b) after-send-keys グローバル hook ロギング = 見送り。tmux 3.4 の hook は session/window/pane に属し
#       *トリガのみ* で、send-keys の *keys 本文* も *呼出し元 PID* も format へ露出しない（verified: man tmux
#       "Hooks are stored as array options … executed when the hook is triggered"）。ゆえに「どのキーを誰が
#       送ったか」を原理的に記録できず、出所不明入力の forensic 追跡という当初目的を満たせない。
#   → 採用: 出所ログ（低価値・out-of-scope）でなく、live evidence(A/B) を直接解く *送達確認* をこの
#      ヘルパで機械化する。live tmux server に触れず（capture-pane は read-only）、検知ロジックは pure な
#      文字列処理ゆえ fixture で fail-closed に自己テストできる（本 worker は OS sandbox 下で tmux server を
#      起動できない＝ロジックを tmux 非依存に切り出すのが唯一テスト可能な設計）。
#
# サブコマンド:
#   verify  … 純粋な残留検知（テスト可能な核）。capture-pane 出力（--capture-file か stdin）と、注入
#             payload の distinctive な marker（--marker）を受け、CC TUI の入力ボックス *内部* に marker が
#             残っているかを判定する。「送信済みで transcript に echo された自分のテキスト」と「入力欄に
#             滞留した未送信テキスト」を、判定対象を入力ボックス内部に限定することで弁別する（incident B の
#             誤『送信済み』を塞ぐ核）。
#   send    … 注入オーケストレーション。target pane へ payload を send-keys -l + Enter し、capture して
#             verify する。RESIDUAL なら Enter を追送して再検証（incident A の回復を機械化）。retry 尽きても
#             残留なら fail-loud。tmux バイナリは SCRIBE_TMUX で差し替え可（テスト seam）。
#   marker  … payload（stdin / --file / --text）から verify 用 marker を導出して stdout に出す（純粋関数）。
#             送信を伴わない検証（既に他者が inject 済みの pane を verify する）で marker 導出を再実装させない
#             ための口（sc-8g5: scribe-spawn の post-spawn submit 検証層が cld-spawn 経由で inject された
#             worker prompt の marker をここから得る＝導出規則の SSOT を 1 箇所に保つ）。
#
# 入力ボックス検知（sc-6vj gate errata で実 CC TUI と突合し改訂）: 検知は capture の *最下部に最も近い*
#   構造へ anchor する（scrollback 中の引用/描画由来の box を誤選択しない）。2 型に両対応:
#   - Type A（実 CC TUI・優先）: 入力欄は角丸枠でなく *水平罫線 ─ のペア*（末尾装飾「… ultracode ─」
#     許容）で描かれ、プロンプトは ❯（U+276F）。最下部の罫線行を下端・直上の罫線行を上端とし間を interior
#     とする（下端罫線より下の status bar 行は interior 外）。空入力欄は「❯ + NBSP(U+00A0)」で描かれる。
#   - Type B（fallback）: 角丸/角ボックス（╭ … │ > … ╰）。最下部の ╰/└ から直上の ╭/┌ まで。
#   プロンプトは ❯ / > 両対応。ボックス未検出なら INCONCLUSIVE（保守的 fail-loud＝確認できないのに
#   『送信済み』と主張しない・incident B 対策）。旧実装は角丸枠のみ前提で、実 TUI の水平罫線入力欄を拾えず
#   上方の corner box（bd テーブル等）を誤選択し、その interior が空だと残留を見落とす fail-open があった。
#
# 残留判定（interior に対して順に評価）:
#   1. marker が interior に含まれる            → RESIDUAL（自分の注入テキストが入力欄に居る＝未送信）
#   2. bracketed-paste placeholder が interior  → RESIDUAL（incident A: paste が [Pasted text …] で滞留）
#   3. --ignore-pattern 除去後の interior が空   → DELIVERED（入力欄クリア＝送信された）
#   4. それ以外（帰属不能な非空内容）           → INCONCLUSIVE（fail-loud・admin は --ignore-pattern で調整）
#
# Usage:
#   scribe-inject.sh verify [--marker M] [--capture-file F] [--ignore-pattern RE]...
#   scribe-inject.sh send --target PANE (--file F | --text T) [--marker M] [--retries N]
#                         [--no-enter] [--settle SEC] [--ignore-pattern RE]...
#   scribe-inject.sh marker [--file F | --text T]        # 既定は stdin から payload を読む
# 終了コード: 0=DELIVERED / 1=usage・die（scribe_die・fail-loud） / 3=RESIDUAL（未送達＝要 fail-loud） /
#             4=INCONCLUSIVE（入力欄を特定不能 or 帰属不能な残留＝保守的 fail-loud）。marker は 0=導出成功。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

# 終了コード SSOT（ヘッダと一致させる）。
readonly INJECT_DELIVERED=0
readonly INJECT_RESIDUAL=3
readonly INJECT_INCONCLUSIVE=4

# bracketed-paste placeholder（CC/端末が貼付を折り畳む表示）を残留として拾う。大小無視の ERE。
readonly PASTE_PLACEHOLDER_RE='\[[Pp]asted text|\[[0-9]+ (more )?lines?( pasted)?\]|[Pp]asted [0-9]+ lines?'

usage() {
  cat <<'EOF'
Usage:
  scribe-inject.sh verify [--marker M] [--capture-file F] [--ignore-pattern RE]...
  scribe-inject.sh send --target PANE (--file F | --text T) [--marker M] [--retries N]
                        [--no-enter] [--settle SEC] [--ignore-pattern RE]...
  scribe-inject.sh marker [--file F | --text T]   # payload（既定 stdin）から verify 用 marker を導出
終了コード: 0=DELIVERED / 1=usage・die / 3=RESIDUAL（未送達・fail-loud） / 4=INCONCLUSIVE（特定不能・fail-loud）。
EOF
  exit "${1:-0}"
}

# _is_input_rule <line> — 入力欄の「水平罫線行」か判定する（実 CC TUI の入力欄は角丸枠でなく
#   水平罫線 ─ のペアで描かれる・sc-6vj gate errata で実測）。条件: ─ を 10 連以上含み、かつ
#   縦線/コーナー/交差 glyph（│┌┐└┘├┤┬┴┼╭╮╰╯）を一切含まない。これで bd テーブル等の枠線
#   （必ず │ や交差を含む）を除外しつつ、末尾装飾（例「… ultracode ─」）付きの罫線も拾う。
_is_input_rule() {
  case "$1" in
    *"│"* | *"┌"* | *"┐"* | *"└"* | *"┘"* | *"├"* | *"┤"* | *"┬"* | *"┴"* | *"┼"* \
      | *"╭"* | *"╮"* | *"╰"* | *"╯"*) return 1 ;;
  esac
  case "$1" in
    *"──────────"*) return 0 ;;   # ─ × 10 連以上
    *) return 1 ;;
  esac
}

# _extract_input_box — stdin の capture から「入力欄 interior」を stdout に出す。ボックス未検出なら return 4。
#   最下部に最も近い構造へ anchor し、遠い（scrollback 中の）box を誤選択しない（sc-6vj gate errata）。
#   Type A（実 CC TUI・優先）= 水平罫線ペア: 最下部の罫線行を下端、その直上の罫線行を上端とし、
#     間を interior とする（下端罫線より下の status bar 行は interior 外）。プロンプトは ❯ / > 両対応。
#   Type B（fallback）= 角丸/角 box: 最下部の ╰/└ から直上の ╭/┌ まで。
_extract_input_box() {
  local -a lines=()
  mapfile -t lines
  local n=${#lines[@]} i start=-1 end=-1
  # --- Type A: 水平罫線ペア（最下部優先）---
  local r2=-1 r1=-1
  for ((i = n - 1; i >= 0; i--)); do
    if _is_input_rule "${lines[i]}"; then r2=$i; break; fi
  done
  if (( r2 >= 0 )); then
    for ((i = r2 - 1; i >= 0; i--)); do
      if _is_input_rule "${lines[i]}"; then r1=$i; break; fi
    done
    if (( r1 >= 0 )); then start=$((r1 + 1)); end=$((r2 - 1)); fi
  fi
  # --- Type B: corner box（最下部の ╰/└ → 直上の ╭/┌）---
  if (( start < 0 )); then
    local bot=-1 top=-1
    for ((i = n - 1; i >= 0; i--)); do
      case "${lines[i]}" in *"╰"* | *"└"*) bot=$i; break ;; esac
    done
    (( bot >= 0 )) || return 4
    for ((i = bot - 1; i >= 0; i--)); do
      case "${lines[i]}" in *"╭"* | *"┌"*) top=$i; break ;; esac
    done
    (( top >= 0 )) || return 4
    start=$((top + 1)); end=$((bot - 1))
  fi
  # --- interior emit（両 Type 共通）---
  local first=1 line
  for ((i = start; i <= end; i++)); do
    line="${lines[i]}"
    # 枠側面・box-drawing・交差 glyph を除去（内容だけ残す）。
    line="${line//│/}"; line="${line//─/}"
    line="${line//╭/}"; line="${line//╮/}"; line="${line//╰/}"; line="${line//╯/}"
    line="${line//┌/}"; line="${line//┐/}"; line="${line//└/}"; line="${line//┘/}"
    line="${line//├/}"; line="${line//┤/}"; line="${line//┬/}"; line="${line//┴/}"; line="${line//┼/}"
    if (( first )); then
      # 先頭 interior 行だけプロンプト（❯ か >）を 1 つ剥ぐ（前後空白ごと）。
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      line="${line#❯}"; line="${line#>}"
      first=0
    fi
    printf '%s\n' "$line"
  done
}

# _classify_interior <interior> <marker> <ignore_re_joined> — 残留判定して INJECT_* を return。
#   ignore_re_joined は '\n' 区切りの ERE 群（空可）。
_classify_interior() {
  local interior="$1" marker="$2" ignore="$3"
  # 1. marker（自分の注入テキスト）が入力欄に居る＝未送信。
  if [[ -n "$marker" ]] && printf '%s' "$interior" | grep -Fq -- "$marker"; then
    return "$INJECT_RESIDUAL"
  fi
  # 2. bracketed-paste placeholder が居る＝paste 未送信（incident A）。
  if printf '%s' "$interior" | grep -Eq -- "$PASTE_PLACEHOLDER_RE"; then
    return "$INJECT_RESIDUAL"
  fi
  # 3. ignore-pattern に一致する行を落としてから空判定。
  #    grep -Ev の exit: 0=一部除去 / 1=全除去（正当に空）/ 2=エラー（不正 ERE 等）。
  #    `|| true` で 1 と 2 を混同すると、不正 pattern で grep が空を返し残留が
  #    DELIVERED へ fail-open する。exit 2 は fail-loud（INCONCLUSIVE）で塞ぐ。
  local body="$interior" re out gs
  if [[ -n "$ignore" ]]; then
    while IFS= read -r re; do
      [[ -n "$re" ]] || continue
      out="$(printf '%s' "$body" | grep -Ev -- "$re")" && gs=0 || gs=$?
      if (( gs > 1 )); then
        # 不正な ERE 等で grep がエラー終了＝空判定に落とせない。保守的に fail-loud。
        return "$INJECT_INCONCLUSIVE"
      fi
      body="$out"
    done <<< "$ignore"
  fi
  # 空（空白と余剰プロンプト '>'/'❯' のみ）なら送信された。実 CC TUI の空入力欄は「❯ +
  # NBSP(U+00A0)」で、NBSP は [:space:] に含まれない（C locale の tr）ため明示除去する（sc-6vj gate errata）。
  local core
  core="$(printf '%s' "$body" | tr -d '[:space:]')"
  core="${core//$'\xc2\xa0'/}"   # NBSP（❯ 後の空白）
  core="${core//>/}"
  core="${core//❯/}"
  if [[ -z "$core" ]]; then
    return "$INJECT_DELIVERED"
  fi
  # 4. 帰属不能な非空内容＝保守的に確認不能扱い（誤『送信済み』を出さない）。
  return "$INJECT_INCONCLUSIVE"
}

# _verdict_name <code> — 数値コードを表示名に。
_verdict_name() {
  case "$1" in
    "$INJECT_DELIVERED") printf 'DELIVERED' ;;
    "$INJECT_RESIDUAL") printf 'RESIDUAL' ;;
    "$INJECT_INCONCLUSIVE") printf 'INCONCLUSIVE' ;;
    *) printf 'ERROR' ;;
  esac
}

# _emit_verdict <code> <detail> — env-probe 同様に stdout+stderr へ fail-loud 表示。
_emit_verdict() {
  local code="$1" detail="${2:-}" name
  name="$(_verdict_name "$code")"
  local line="INJECT_${name}${detail:+: $detail}"
  if (( code == INJECT_DELIVERED )); then
    printf '%s\n' "$line"
  else
    printf '%s\n' "$line" >&2
    printf '%s\n' "$line"
  fi
}

# do_verify — capture を読んで残留判定し verdict を出す（core・純粋文字列処理）。
do_verify() {
  local marker="" capture_file="" ignore=""
  while (( $# )); do
    case "$1" in
      --marker) scribe_need_val "${2:-}" --marker; marker="$2"; shift 2 ;;
      --capture-file) scribe_need_val "${2:-}" --capture-file; capture_file="$2"; shift 2 ;;
      --ignore-pattern) scribe_need_val "${2:-}" --ignore-pattern; ignore+="$2"$'\n'; shift 2 ;;
      -h | --help) usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "verify: 未知のオプション: $1" ;;
      *) scribe_die "verify: 余分な引数: $1" ;;
    esac
  done
  local capture
  if [[ -n "$capture_file" ]]; then
    [[ -r "$capture_file" ]] || scribe_die "verify: capture-file が読めません: $capture_file"
    capture="$(cat -- "$capture_file")"
  else
    capture="$(cat)"
  fi
  local interior rc=0
  interior="$(printf '%s\n' "$capture" | _extract_input_box)" || rc=$?
  if (( rc == 4 )); then
    _emit_verdict "$INJECT_INCONCLUSIVE" "入力ボックスを capture 内に特定できません（agent 実行中で入力欄が隠れている等）"
    return "$INJECT_INCONCLUSIVE"
  fi
  local vc=0
  _classify_interior "$interior" "$marker" "$ignore" || vc=$?
  case "$vc" in
    "$INJECT_RESIDUAL") _emit_verdict "$INJECT_RESIDUAL" "注入テキストが入力欄に残留（未送達）" ;;
    "$INJECT_INCONCLUSIVE") _emit_verdict "$INJECT_INCONCLUSIVE" "入力欄に帰属不能な内容あり（--ignore-pattern で調整可）" ;;
    *) _emit_verdict "$INJECT_DELIVERED" "入力欄クリア（送達）" ;;
  esac
  return "$vc"
}

# _derive_marker <payload> — payload の最終非空行の末尾（cursor が座る箇所）を marker に。
_derive_marker() {
  local payload="$1" last
  last="$(printf '%s' "$payload" | awk 'NF{l=$0} END{if(l!="")print l}')"
  # rtrim
  last="${last%"${last##*[![:space:]]}"}"
  local n=24
  (( ${#last} > n )) && last="${last: -n}"
  printf '%s' "$last"
}

# do_marker — payload（stdin / --file / --text）から verify 用 marker を導出して stdout に出す（sc-8g5）。
#   do_send は marker を内部導出するが、**送信を伴わない検証**（他者が inject 済みの pane を verify する）では
#   その導出規則だけが要る。呼出側（scribe-spawn の post-spawn submit 検証層）に _derive_marker を再実装させると
#   導出規則が 2 箇所に散り drift する（marker が食い違えば RESIDUAL を取りこぼし fail-open する）ため、pure core を
#   subcommand として露出する。改行は付けない（$(...) で受けた側が末尾改行に悩まされない）。
do_marker() {
  local file="" text="" has_text=0
  while (( $# )); do
    case "$1" in
      --file) scribe_need_val "${2:-}" --file; file="$2"; shift 2 ;;
      --text) [[ $# -ge 2 ]] || scribe_die "--text に値を指定してください"; text="$2"; has_text=1; shift 2 ;;
      -h | --help) usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "marker: 未知のオプション: $1" ;;
      *) scribe_die "marker: 余分な引数: $1" ;;
    esac
  done
  local payload
  if [[ -n "$file" ]]; then
    (( has_text )) && scribe_die "marker: --file と --text は排他です"
    [[ -r "$file" ]] || scribe_die "marker: --file が読めません: $file"
    payload="$(cat -- "$file")"
  elif (( has_text )); then
    payload="$text"
  else
    payload="$(cat)"
  fi
  [[ -n "$payload" ]] || scribe_die "marker: payload が空です"
  local m
  m="$(_derive_marker "$payload")"
  [[ -n "$m" ]] || scribe_die "marker: payload から marker を導出できません（全空白？）"
  printf '%s' "$m"
}

# do_send — target pane へ注入し送達確認する（RESIDUAL は Enter 追送で回復）。
do_send() {
  local target="" file="" text="" marker="" retries=2 settle="0.2" no_enter=0 ignore="" has_text=0
  local -a ignore_args=()
  while (( $# )); do
    case "$1" in
      --target) scribe_need_val "${2:-}" --target; target="$2"; shift 2 ;;
      --file) scribe_need_val "${2:-}" --file; file="$2"; shift 2 ;;
      --text) [[ $# -ge 2 ]] || scribe_die "--text に値を指定してください"; text="$2"; has_text=1; shift 2 ;;
      --marker) scribe_need_val "${2:-}" --marker; marker="$2"; shift 2 ;;
      --retries) scribe_need_val "${2:-}" --retries; retries="$2"; shift 2 ;;
      --settle) scribe_need_val "${2:-}" --settle; settle="$2"; shift 2 ;;
      --no-enter) no_enter=1; shift ;;
      --ignore-pattern) scribe_need_val "${2:-}" --ignore-pattern; ignore+="$2"$'\n'; ignore_args+=(--ignore-pattern "$2"); shift 2 ;;
      -h | --help) usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "send: 未知のオプション: $1" ;;
      *) scribe_die "send: 余分な引数: $1" ;;
    esac
  done
  [[ -n "$target" ]] || scribe_die "send: --target は必須です（tmux -t のターゲット pane）"
  [[ "$retries" =~ ^[0-9]+$ ]] || scribe_die "send: --retries は非負整数です: $retries"
  # --settle も --retries と同様 fail-loud 検証（非数値を silent に無視すると settle 無しで即回り
  # premature capture → 誤 verdict を招きうる）。sleep のフラクショナル秒に合わせ小数を許す。
  [[ "$settle" =~ ^[0-9]+([.][0-9]+)?$ ]] || scribe_die "send: --settle は非負の数値です: $settle"
  local payload
  if [[ -n "$file" ]]; then
    (( has_text )) && scribe_die "send: --file と --text は排他です"
    [[ -r "$file" ]] || scribe_die "send: --file が読めません: $file"
    payload="$(cat -- "$file")"
  elif (( has_text )); then
    payload="$text"
  else
    scribe_die "send: --file か --text のいずれかで payload を指定してください"
  fi
  [[ -n "$payload" ]] || scribe_die "send: payload が空です"
  if [[ -z "$marker" ]]; then
    marker="$(_derive_marker "$payload")"
    [[ -n "$marker" ]] || scribe_die "send: payload から marker を導出できません（全空白？）——--marker を明示してください"
  fi

  local TMUX_BIN="${SCRIBE_TMUX:-tmux}"
  # 注入: literal 本文 → Enter で submit。
  "$TMUX_BIN" send-keys -t "$target" -l -- "$payload"
  (( no_enter )) || "$TMUX_BIN" send-keys -t "$target" Enter

  local attempt=0 vc cap
  while :; do
    [[ "$settle" == "0" || "$settle" == "0.0" ]] || sleep "$settle" 2>/dev/null || true
    cap="$("$TMUX_BIN" capture-pane -p -t "$target")"
    vc=0
    printf '%s\n' "$cap" | do_verify --marker "$marker" "${ignore_args[@]}" >/dev/null 2>&1 || vc=$?
    if (( vc == INJECT_DELIVERED )); then
      _emit_verdict "$INJECT_DELIVERED" "送達確認（target=$target・attempt=$attempt）"
      return "$INJECT_DELIVERED"
    fi
    if (( attempt >= retries )); then
      local why="残留（未送達）"
      (( vc == INJECT_INCONCLUSIVE )) && why="入力欄を確認できず（帰属不能 or 特定不能）"
      _emit_verdict "$vc" "$why・retry 尽きた（target=$target・attempts=$((attempt + 1))）"
      return "$vc"
    fi
    # RESIDUAL は Enter 追送で回復を試みる（incident A）。INCONCLUSIVE は再 capture のみ。
    if (( vc == INJECT_RESIDUAL && no_enter == 0 )); then
      "$TMUX_BIN" send-keys -t "$target" Enter
    fi
    attempt=$((attempt + 1))
  done
}

[[ $# -gt 0 ]] || usage 1
mode="$1"; shift
case "$mode" in
  verify) do_verify "$@" ;;
  send) do_send "$@" ;;
  marker) do_marker "$@" ;;
  -h | --help) usage 0 ;;
  *) scribe_die "未知のサブコマンド: $mode（verify|send|marker）" ;;
esac

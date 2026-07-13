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
#   busy-check … **送信前** に target の入力欄が空か（＝push してよいか）だけを判定する（sc-6mtm・下記 gate の
#             pure core を単体で露出。send はこれを内部で必ず通る）。0=IDLE（push 可）/ 5=DEFERRED（push 不可）。
#
# 送信前 busy-check gate（sc-6mtm・orch-thgx 裁定-comm-protocol(a) の scribe leg・**co-submit 事故の構造対策**）:
#   send は send-keys の *前* に target を capture し、入力欄 interior が非空なら **一切送らずに** exit 5
#   （INJECT_DEFERRED）で defer する（＝mailbox 降格。admin は bead / mailbox 経由で伝える）。
#   - 何を防ぐか: 入力欄に human の打鍵途中テキストが居るとき send-keys -l は *その続き* に連結され、続く Enter で
#     「human の書きかけ + admin の注入」が **1 行に merge されたまま submit** される（入力 merge / co-submit 事故）。
#     この事故は事後検知できない——送信後の入力欄は空になるため、残留ベースの検証（verify / session-comm の
#     confirm-receipt）はどちらも DELIVERED を返す（下記「confirm-receipt の限界」）。ゆえに **事前に送らない**
#     ことだけが構造的な対策になる。
#   - 判定は verify と **同一の入力欄構造検知**（`_extract_input_box` → `_classify_interior`）を再利用する＝
#     pane 全文の grep はしない（pane 本文と主題が衝突して誤発火した先例 sc-11z を踏まない）。ghost text 等で
#     誤 BUSY になるなら `--ignore-pattern` で調整する（verify と同じ口）。
#   - **`--ignore-pattern` は gate を盲目化しうる**（sc-6mtm self-review）: ignore の適用は `grep -Ev` の *行削除*
#     ゆえ、human の打鍵行に部分一致する広い pattern は **その行ごと消して busy を idle に化けさせる**。ゆえに
#     gate は ignore を当てずに一次判定し、素で非空だが ignore 除去で空になった場合は silent に通さず
#     `⚠ INJECT_IDLE_VIA_IGNORE` を stderr に出す（exit 0 だが loud）。gate へ渡す pattern は ghost text に
#     厳密一致する狭いものだけにすること。
#   - 3 値: IDLE（入力欄を **積極証拠つきで** 特定でき interior が空）→ 送る / BUSY（特定でき非空）→ defer /
#     UNKNOWN（入力欄を capture 内に特定できない＝idle を *確認できない*）→ defer（**fail-closed**）。
#     UNKNOWN も defer するのは「確認できないのに push しない」＝本ツールの保守側倒し（INCONCLUSIVE 同型）。
#   - **IDLE は積極証拠でのみ宣言する**（scribe-spawn.sh ヘッダ【設計原理】と同型・sc-6mtm self-review）:
#     罫線ペアは transcript 中の描画（区切り線・引用された box）にも現れうるため、「最下部の罫線ペアが在る」だけ
#     では入力欄の証拠にならない。誤選択した box の interior はたいてい空に見え、そのまま IDLE を返すと gate が
#     **fail-open** する。ゆえに interior 先頭行から実際にプロンプト（`❯` / `>`）を剥げたときだけ「入力欄だと
#     確証できた」とみなし（`_extract_input_box --prompt-only`）、プロンプト不在なら IDLE ではなく **UNKNOWN**
#     （＝defer）へ落とす。「空に見えた」は idle の証拠ではない。
#   - **TOCTOU 残余は許容**（裁定に明記）: busy-check 後〜send-keys の間に human が打鍵し始める窓は残る。
#     完全封鎖を狙って複雑化せず、指示の原本は durable な bead に置く（pane 注入は補助チャネル）。
#
# no-push 原則（docs SSOT = docs/protocol.md §6「transport 構造封鎖」）:
#   **user が対話中の窓へは push しない**。busy-check gate はこの原則の機械強制であり、defer 時の回復手段は
#   「入力欄を掃除して押し込む」ことでは **ない**（それは human の未送信テキストを破壊する）。bead / mailbox へ回す。
#   - **入力欄 wipe（`C-u` 相当 / `--clear-first`）は禁止**: 本スクリプトに wipe 経路は存在せず（send-keys は
#     `-l --` の literal 本文と `Enter` のみ＝キー名を注入する経路が構造的に無い。payload 中の "C-u" も literal
#     文字列として送られキー入力にならない）、`--clear-first` 等が渡されたら **専用メッセージで die** する（sc-6mtm）。
#
# confirm-receipt / verify の限界（co-submit は検知できない・sc-6mtm(4)）:
#   session-comm の `inject-file --confirm-receipt`（sentinel-presence）も本スクリプトの verify（入力欄残留）も、
#   「**何が submit されたか**」は見ていない——前者は pane への *到着*、後者は入力欄が *空になったこと* しか見ない。
#   ゆえに human と同時送信（co-submit）が起きて merge された 1 行が submit されても、両者とも DELIVERED を返す
#   （**偽陽性**）。DELIVERED は「注入テキストが無傷で submit された」ことを含意しない。この限界は残留ベース検証の
#   原理的なものであり、事前 gate（busy-check）と durable な bead 原本でのみ埋める。
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
#   scribe-inject.sh busy-check (--target PANE | --capture-file F) [--ignore-pattern RE]...
# 終了コード: 0=DELIVERED（send/verify）・IDLE（busy-check） / 1=usage・die（scribe_die・fail-loud） /
#             3=RESIDUAL（未送達＝要 fail-loud） / 4=INCONCLUSIVE（入力欄を特定不能 or 帰属不能な残留＝保守的
#             fail-loud） / 5=DEFERRED（**送っていない**＝busy-check gate が push を止めた・sc-6mtm）。
#             marker は 0=導出成功。**3/4 は「送った後の確認結果」・5 は「送っていない」**（呼出側はこの差で
#             再送の可否を判断できる＝5 で再送してはならない・bead/mailbox へ回す）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

# 終了コード SSOT（ヘッダと一致させる）。
readonly INJECT_DELIVERED=0
readonly INJECT_RESIDUAL=3
readonly INJECT_INCONCLUSIVE=4
readonly INJECT_DEFERRED=5   # 送信前 busy-check gate が push を止めた（＝送っていない・sc-6mtm）

# bracketed-paste placeholder（CC/端末が貼付を折り畳む表示）を残留として拾う。大小無視の ERE。
readonly PASTE_PLACEHOLDER_RE='\[[Pp]asted text|\[[0-9]+ (more )?lines?( pasted)?\]|[Pp]asted [0-9]+ lines?'

usage() {
  cat <<'EOF'
Usage:
  scribe-inject.sh verify [--marker M] [--capture-file F] [--ignore-pattern RE]...
  scribe-inject.sh send --target PANE (--file F | --text T) [--marker M] [--retries N]
                        [--no-enter] [--settle SEC] [--ignore-pattern RE]...
  scribe-inject.sh marker [--file F | --text T]   # payload（既定 stdin）から verify 用 marker を導出
  scribe-inject.sh busy-check (--target PANE | --capture-file F) [--ignore-pattern RE]...
                                                  # 送信前 gate: 入力欄が空か（push 可か）だけを判定
終了コード: 0=DELIVERED/IDLE / 1=usage・die / 3=RESIDUAL（送った後・未送達・fail-loud） /
            4=INCONCLUSIVE（送った後・特定不能・fail-loud） / 5=DEFERRED（**送っていない**＝busy-check gate が
            push を止めた。入力欄が非空 or 特定不能。再送せず bead/mailbox 経由で伝えること）。
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

# _extract_input_box [--prompt-only] — stdin の capture から「入力欄 interior」を stdout に出す。ボックス未検出なら return 4。
#   最下部に最も近い構造へ anchor し、遠い（scrollback 中の）box を誤選択しない（sc-6vj gate errata）。
#   Type A（実 CC TUI・優先）= 水平罫線ペア: 最下部の罫線行を下端、その直上の罫線行を上端とし、
#     間を interior とする（下端罫線より下の status bar 行は interior 外）。プロンプトは ❯ / > 両対応。
#   Type B（fallback）= 角丸/角 box: 最下部の ╰/└ から直上の ╭/┌ まで。
#   --prompt-only: interior を **出さず**、選んだ box が入力欄だという *積極証拠*（interior 先頭行から実際に
#     プロンプト `❯`/`>` を剥げたか）だけを rc で返す（0=証拠あり / 4=box 未検出 or プロンプト不在）。
#     busy-check gate が「罫線ペアを誤選択して interior が空に見えた」ケースを IDLE と誤宣言しないための口
#     （sc-6mtm self-review・fail-open 封鎖）。verify は従来どおり既定モード（rc は box 検出のみを表す）。
_extract_input_box() {
  local prompt_only=0
  [[ "${1:-}" == "--prompt-only" ]] && prompt_only=1
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
  local first=1 line stripped has_prompt=0
  for ((i = start; i <= end; i++)); do
    line="${lines[i]}"
    # 枠側面・box-drawing・交差 glyph を除去（内容だけ残す）。
    line="${line//│/}"; line="${line//─/}"
    line="${line//╭/}"; line="${line//╮/}"; line="${line//╰/}"; line="${line//╯/}"
    line="${line//┌/}"; line="${line//┐/}"; line="${line//└/}"; line="${line//┘/}"
    line="${line//├/}"; line="${line//┤/}"; line="${line//┬/}"; line="${line//┴/}"; line="${line//┼/}"
    if (( first )); then
      # 先頭 interior 行だけプロンプト（❯ か >）を 1 つ剥ぐ（前後空白ごと）。
      # 実際に剥げたか（＝この box が入力欄だという積極証拠）を has_prompt に記録する（--prompt-only の答え）。
      line="${line#"${line%%[![:space:]]*}"}"   # ltrim
      stripped="${line#❯}"; if [[ "$stripped" != "$line" ]]; then has_prompt=1; fi; line="$stripped"
      stripped="${line#>}";  if [[ "$stripped" != "$line" ]]; then has_prompt=1; fi; line="$stripped"
      first=0
    fi
    (( prompt_only )) || printf '%s\n' "$line"
  done
  if (( prompt_only )); then
    # プロンプトを剥げなかった＝入力欄だと確証できない（罫線ペアの誤選択 / interior 皆無）→ 未検出と同値の 4。
    (( has_prompt )) || return 4
  fi
}

# _classify_interior <interior> <marker> <ignore_re_joined> [strict_prompt] — 残留判定して INJECT_* を return。
#   ignore_re_joined は '\n' 区切りの ERE 群（空可）。
#   strict_prompt=1（busy-check gate 専用・sc-6mtm self-review）: 空判定で余剰プロンプト glyph（'>' / '❯'）を
#     **剥がない**。gate では先頭プロンプトは既に _extract_input_box が剥いでおり、残った '>' は human が打鍵した
#     *内容*（例「>>>」）である——それを空扱いにすると busy を idle と誤宣言して fail-open する。verify（既定＝0）は
#     従来どおり剥ぐ（送信後の入力欄に残る描画上のプロンプトを残留と誤認しないための sc-6vj の措置）。
_classify_interior() {
  local interior="$1" marker="$2" ignore="$3" strict_prompt="${4:-0}"
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
  if (( strict_prompt == 0 )); then
    core="${core//>/}"
    core="${core//❯/}"
  fi
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

# _busy_state <capture> <ignore_re_joined> — **送信前** の入力欄状態を判定する pure core（sc-6mtm gate）。
#   stdout に理由トークンを出し、return は 0=IDLE（push 可） / INJECT_DEFERRED=push 不可。
#     idle    … 入力欄を **積極証拠つきで** 特定でき（interior 先頭からプロンプト ❯/> を実際に剥げた）、かつ
#               interior が空（human は打鍵していない）→ 0
#     busy    … 入力欄を特定でき interior が非空（human 打鍵中 / 前回注入の残留 / paste 滞留、および
#               --ignore-pattern が不正 ERE で空判定に落とせない場合＝いずれも「送ってはいけない」で同値）→ 5
#     unknown … 入力欄を capture 内に特定できない、**または** 罫線ペアは在るがプロンプトが無く「入力欄だと確証
#               できない」（＝transcript 由来の罫線を誤選択した疑い）＝idle を *確認できない* → 5（fail-closed）
#   判定は verify と同一の構造検知（_extract_input_box → _classify_interior）を再利用する（pane 全文 grep をしない
#   ＝誤発火の先例 sc-11z を踏まない）。marker は空で呼ぶ——送信前ゆえ自分の payload はまだ入力欄に無く、
#   「空か否か」だけが問い（marker 一致は verify の問い）。
#   **IDLE を積極証拠でのみ宣言する**（sc-6mtm self-review の fail-open 封鎖）: 「box を誤特定して空に見えた」は
#   idle の証拠にならない。プロンプト不在は空/非空によらず unknown（＝defer）へ落とす。
_busy_state() {
  local capture="$1" ignore="$2"
  local interior rc=0
  interior="$(printf '%s\n' "$capture" | _extract_input_box)" || rc=$?
  if (( rc == 4 )); then
    printf 'unknown'
    return "$INJECT_DEFERRED"
  fi
  # 入力欄の積極証拠（プロンプト glyph を実際に剥げたか）が無ければ idle を名乗らせない（fail-closed）。
  local prc=0
  printf '%s\n' "$capture" | _extract_input_box --prompt-only || prc=$?
  if (( prc != 0 )); then
    printf 'unknown'
    return "$INJECT_DEFERRED"
  fi
  # まず **ignore を当てずに** 空判定する（gate の一次判定）。素で空なら文句なく idle。
  local raw=0
  _classify_interior "$interior" "" "" 1 || raw=$?
  if (( raw == INJECT_DELIVERED )); then
    printf 'idle'
    return "$INJECT_DELIVERED"
  fi
  # 素では非空。ignore-pattern を当てて空になるなら「ghost text だった」＝idle だが、これは
  # **gate を盲目化しうる経路**（grep -Ev は *行削除* ゆえ、広い pattern は human の打鍵行ごと消して
  # busy を idle に化けさせる）。silent に通さず 'idle-via-ignore' として loud に告げる（sc-6mtm self-review）。
  if [[ -n "$ignore" ]]; then
    local cc=0
    _classify_interior "$interior" "" "$ignore" 1 || cc=$?
    if (( cc == INJECT_DELIVERED )); then
      printf 'idle-via-ignore'
      return "$INJECT_DELIVERED"
    fi
  fi
  printf 'busy'
  return "$INJECT_DEFERRED"
}

# _emit_busy_verdict <reason> <target> — busy-check / send gate の verdict 表示（fail-loud は stderr にも）。
#   defer 時のメッセージは **回復手段を bead/mailbox に固定**する（入力欄 wipe や押し込みを示唆しない＝no-push 原則）。
_emit_busy_verdict() {
  local reason="$1" target="${2:-}" line
  case "$reason" in
    idle-via-ignore)
      # 素の interior は非空で、--ignore-pattern の行削除で空になった＝gate が盲目化された可能性を loud に告げる
      # （human の打鍵行に部分一致する広い pattern は busy を idle へ化けさせる・sc-6mtm self-review）。
      line="INJECT_IDLE: 入力欄は --ignore-pattern 除去後に空（push 可${target:+・target=$target}）"
      printf '%s\n' "⚠ INJECT_IDLE_VIA_IGNORE: 素の入力欄は **非空** で、--ignore-pattern が行ごと除去した結果 idle と判定しました（ghost text 想定）。pattern が human の打鍵行に一致していると busy を idle と誤判定します＝gate の盲目化。広い pattern を渡していないか確認してください。" >&2
      printf '%s\n' "$line"
      return "$INJECT_DELIVERED" ;;
    idle)
      line="INJECT_IDLE: 入力欄が空（push 可${target:+・target=$target}）"
      printf '%s\n' "$line"
      return "$INJECT_DELIVERED" ;;
    busy)
      line="INJECT_DEFERRED: reason=busy — 入力欄に未送信テキストあり（human 打鍵中 or 前回注入の残留）＝**送信していません**${target:+・target=$target}。押し込まず bead/mailbox 経由で伝えてください（no-push 原則・protocol §6）。" ;;
    *)
      line="INJECT_DEFERRED: reason=unknown — 入力欄を capture 内に特定できず idle を確認できません（fail-closed）＝**送信していません**${target:+・target=$target}。bead/mailbox 経由で伝えてください（no-push 原則・protocol §6）。" ;;
  esac
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line"
  return "$INJECT_DEFERRED"
}

# do_busy_check — 送信前 gate を単体で回す（send は同じ core を内部で通る）。
#   --target で live pane を capture するか、--capture-file / stdin で capture を与える（テスト・事後監査用）。
do_busy_check() {
  local target="" capture_file="" ignore=""
  while (( $# )); do
    case "$1" in
      --target) scribe_need_val "${2:-}" --target; target="$2"; shift 2 ;;
      --capture-file) scribe_need_val "${2:-}" --capture-file; capture_file="$2"; shift 2 ;;
      --ignore-pattern) scribe_need_val "${2:-}" --ignore-pattern; ignore+="$2"$'\n'; shift 2 ;;
      -h | --help) usage 0 ;;
      --) shift; break ;;
      -*) scribe_die "busy-check: 未知のオプション: $1" ;;
      *) scribe_die "busy-check: 余分な引数: $1" ;;
    esac
  done
  [[ -n "$target" && -n "$capture_file" ]] && scribe_die "busy-check: --target と --capture-file は排他です"
  local capture
  if [[ -n "$target" ]]; then
    local TMUX_BIN="${SCRIBE_TMUX:-tmux}"
    capture="$("$TMUX_BIN" capture-pane -p -t "$target")" \
      || scribe_die "busy-check: capture-pane に失敗しました（target=$target・window/pane が解決できない？）"
  elif [[ -n "$capture_file" ]]; then
    [[ -r "$capture_file" ]] || scribe_die "busy-check: capture-file が読めません: $capture_file"
    capture="$(cat -- "$capture_file")"
  else
    capture="$(cat)"
  fi
  local reason rc=0
  reason="$(_busy_state "$capture" "$ignore")" || rc=$?
  _emit_busy_verdict "$reason" "$target"
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
      # 入力欄 wipe（C-u 相当）の禁止を **機械的に** 拒否する（sc-6mtm(3)・no-push 原則）。本スクリプトに wipe 経路は
      # 元より無い（send-keys は `-l --` の literal 本文と Enter のみ）が、"未知のオプション" という一般 die では
      # 「なぜ禁止か」が伝わらず、呼出側が自前の生 send-keys で C-u を撃つ回避に流れる。専用メッセージで塞ぐ。
      --clear-first | --clear | --wipe | --wipe-input)
        scribe_die "send: $1 は禁止です（入力欄 wipe = C-u 相当は human の未送信テキストを破壊する・sc-6mtm no-push 原則）。入力欄が非空なら **押し込まず** bead/mailbox 経由で伝えてください（busy-check gate が既に defer します）。" ;;
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

  # --- 送信前 busy-check gate（sc-6mtm・**送る前に一度だけ**）---------------------------------
  # 入力欄が非空（human 打鍵中の疑い）or 特定不能なら **send-keys を一切撃たずに** exit 5 で defer する。
  # 送ってしまってからでは co-submit（merge された 1 行の submit）は検知できない（ヘッダ「confirm-receipt の限界」）。
  local _gate_cap _gate_reason _gate_rc=0
  _gate_cap="$("$TMUX_BIN" capture-pane -p -t "$target")" \
    || scribe_die "send: 送信前 busy-check の capture-pane に失敗しました（target=$target・window/pane が解決できない？）"
  _gate_reason="$(_busy_state "$_gate_cap" "$ignore")" || _gate_rc=$?
  if (( _gate_rc != INJECT_DELIVERED )); then
    _emit_busy_verdict "$_gate_reason" "$target" || true
    return "$INJECT_DEFERRED"
  fi

  # 注入: literal 本文 → Enter で submit。
  # （キー名を撃つ経路はここに無い＝payload は常に `-l --` の literal。C-u 等の wipe は構造的に送れない・sc-6mtm）
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
  busy-check) do_busy_check "$@" ;;
  -h | --help) usage 0 ;;
  *) scribe_die "未知のサブコマンド: $mode（verify|send|marker|busy-check）" ;;
esac

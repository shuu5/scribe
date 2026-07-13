#!/usr/bin/env bats
# scribe-inject.sh — admin 操舵注入の送達確認ヘルパ（sc-6vj）+ 送信前 busy-check gate（sc-6mtm）の回帰テスト。
# **live tmux は起動しない**（worker sandbox では tmux server の socket 作成/接続が OS sandbox に拒否される
#   ＝`tmux -S <任意path>` でも "Operation not permitted"・verified。かつ検知ロジックは pure な文字列処理）。
#   - verify:     fixture capture で残留検知の弁別を確認（transcript echo と入力欄滞留を取り違えない核）。
#   - busy-check: **送信前** gate の 3 値（idle / busy / unknown）を実 CC TUI capture fixture で確認（sc-6mtm）。
#   - send:       SCRIBE_TMUX を stub へ差し替え、gate による defer（送らない）と、gate 通過後の Enter 追送に
#                 よる回復（incident A）・fail-loud を確認。
# 検知ロジックがコード化する契約の SSOT = scripts/scribe-inject.sh ヘッダ。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INJECT="$REPO_ROOT/scripts/scribe-inject.sh"
  CAP="$BATS_TEST_TMPDIR/cap.txt"
  # stub tmux。**実 pane の時間発展を模す**（sc-6mtm）: 送信前（SENDL 前）は入力欄が空＝idle、
  # 我々が payload を打った後（SENDL 後）だけ入力欄に payload が座り、Enter が閾値回数入ると空になる。
  # 旧 stub は「Enter 回数だけ」で描画を決めていたため、送信前 capture まで payload 残留を返してしまい
  # busy-check gate（送信前は idle のはず）を実挙動と乖離した状態でテストしてしまう。
  #   STUB_BUSY_BEFORE_SEND=1 … 送信前から入力欄に human の打鍵途中テキストが居る（gate BUSY 経路）
  #   STUB_NO_BOX=1           … 入力欄を常に特定できない（gate UNKNOWN 経路）
  #   STUB_NO_BOX_AFTER_SEND=1… 送信前は入力欄あり・送信後に消える（gate 通過後の INCONCLUSIVE 経路）
  STUB_DIR="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB_DIR"
  : > "$STUB_DIR/calls.log"; echo 0 > "$STUB_DIR/enters"; echo 0 > "$STUB_DIR/sendl"
  cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$(readlink -f "$0")")"
sub="$1"; shift
R='──────────────────────────────────'
emit_box() { printf '%s\n' "$R" "❯ $1" "$R" '  user@host  scribe  main'; }
case "$sub" in
  send-keys)
    if printf '%s\n' "$@" | grep -q -- '-l'; then
      echo "SENDL $*" >> "$S/calls.log"; m=$(cat "$S/sendl"); echo $((m+1)) > "$S/sendl"
    elif printf '%s\n' "$@" | grep -q -- 'Enter'; then
      echo "ENTER $*" >> "$S/calls.log"; n=$(cat "$S/enters"); echo $((n+1)) > "$S/enters"
    fi ;;
  capture-pane)
    sent=$(cat "$S/sendl")
    if [[ "${STUB_NO_BOX:-0}" == 1 ]]; then printf '%s\n' 'Thinking… (esc to interrupt)'; exit 0; fi
    if (( sent == 0 )); then
      # --- 送信前（gate が見る画面）---
      if [[ "${STUB_BUSY_BEFORE_SEND:-0}" == 1 ]]; then emit_box 'human が書きかけの指示テキスト'; exit 0; fi
      emit_box ''; exit 0
    fi
    # --- 送信後 ---
    if [[ "${STUB_NO_BOX_AFTER_SEND:-0}" == 1 ]]; then printf '%s\n' 'Thinking… (esc to interrupt)'; exit 0; fi
    n=$(cat "$S/enters"); thr="${STUB_CLEAR_AFTER:-2}"
    if (( n >= thr )); then emit_box ''; else emit_box 'payload-tail-marker'; fi ;;
esac
STUB
  chmod +x "$STUB_DIR/tmux"
}

# --- verify: 弁別の核 -------------------------------------------------------

@test "verify: 入力欄クリア（marker は transcript のみ）→ DELIVERED exit0" {
  cat > "$CAP" <<'EOF'
> errata: 指示を反映してください
  ⎿ 了解

╭──────────────────────────────╮
│ >                            │
╰──────────────────────────────╯
  ? for shortcuts
EOF
  run "$INJECT" verify --marker "指示を反映してください" --capture-file "$CAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_DELIVERED* ]]
}

@test "verify: 逐字残留（incident B）→ RESIDUAL exit3" {
  cat > "$CAP" <<'EOF'
  ⎿ 前の応答
╭──────────────────────────────╮
│ > errata: 指示を反映してください   │
╰──────────────────────────────╯
EOF
  run "$INJECT" verify --marker "指示を反映してください" --capture-file "$CAP"
  [ "$status" -eq 3 ]
  [[ "$output" == *INJECT_RESIDUAL* ]]
}

@test "verify: paste 残留（incident A）→ RESIDUAL exit3（marker 不一致でも placeholder で拾う）" {
  cat > "$CAP" <<'EOF'
╭──────────────────────────────╮
│ > [Pasted text +12 lines]    │
╰──────────────────────────────╯
EOF
  run "$INJECT" verify --marker "全く違う文字列" --capture-file "$CAP"
  [ "$status" -eq 3 ]
  [[ "$output" == *INJECT_RESIDUAL* ]]
}

@test "verify: 入力ボックス無し（agent 実行中）→ INCONCLUSIVE exit4（保守的 fail-loud）" {
  cat > "$CAP" <<'EOF'
✻ Thinking… (esc to interrupt)
  tokens: 1234
EOF
  run "$INJECT" verify --marker "指示" --capture-file "$CAP"
  [ "$status" -eq 4 ]
  [[ "$output" == *INJECT_INCONCLUSIVE* ]]
}

@test "verify: 帰属不能な非空内容 → INCONCLUSIVE exit4" {
  cat > "$CAP" <<'EOF'
╭──────────────────────────────╮
│ > some unrelated leftover     │
╰──────────────────────────────╯
EOF
  run "$INJECT" verify --marker "指示を反映してください" --capture-file "$CAP"
  [ "$status" -eq 4 ]
}

@test "verify: --ignore-pattern で既知の placeholder hint を空扱いにできる" {
  cat > "$CAP" <<'EOF'
╭──────────────────────────────╮
│ > Try "edit <file>"          │
╰──────────────────────────────╯
EOF
  run "$INJECT" verify --marker "指示" --ignore-pattern 'Try "' --capture-file "$CAP"
  [ "$status" -eq 0 ]
}

@test "verify: 不正な --ignore-pattern（regex エラー）で残留を DELIVERED にしない → INCONCLUSIVE exit4（fail-loud）" {
  cat > "$CAP" <<'EOF'
╭──────────────────────────────╮
│ > some unrelated leftover     │
╰──────────────────────────────╯
EOF
  # '[' は不正な ERE。grep が exit 2 で失敗するのを握り潰して空扱いにすると
  # 残留があるのに DELIVERED(exit0) へ fail-open する。保守的に INCONCLUSIVE で塞ぐ。
  run "$INJECT" verify --marker "指示" --ignore-pattern '[' --capture-file "$CAP"
  [ "$status" -eq 4 ]
  [[ "$output" == *INJECT_INCONCLUSIVE* ]]
}

@test "verify: capture を stdin からも読める" {
  run bash -c "printf '%s\n' '╭──╮' '│ >  │' '╰──╯' | '$INJECT' verify --marker x"
  [ "$status" -eq 0 ]
}

# --- 実 CC TUI capture（sc-6vj gate errata・水平罫線ペア + ❯ + status bar + 上方に bd テーブル corner box）---
# fixture = admin が本物の pane を capture-pane -p した生データ（email/username のみサニタイズ・構造保存）。
# 旧実装は上方 corner box を誤選択し、空入力欄なのに拾えず fail-open した。以下 3 assert で pin する。

@test "real capture: 空 ❯ 入力欄 + 不在 marker → DELIVERED exit0（誤選択 corner box を排除）" {
  run "$INJECT" verify --marker zzz-nonexistent --capture-file "$REPO_ROOT/tests/fixtures/real-cc-capture.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_DELIVERED* ]]
}

@test "real capture: ❯ 行へ marker 挿入 → RESIDUAL exit3（実入力欄の残留を検知）" {
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
# 空 ❯ 行（末尾から探す）へ marker を挿入。
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ STEER-MARKER-XYZ"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" verify --marker STEER-MARKER-XYZ --capture-file "$CAP"
  [ "$status" -eq 3 ]
  [[ "$output" == *INJECT_RESIDUAL* ]]
}

@test "real capture: ❯ 行へ paste placeholder 挿入 → RESIDUAL exit3" {
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ [Pasted text +7 lines]"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" verify --marker zzz-nonexistent --capture-file "$CAP"
  [ "$status" -eq 3 ]
  [[ "$output" == *INJECT_RESIDUAL* ]]
}

# --- send: オーケストレーション（stub tmux）---------------------------------

@test "send: 1st Enter 残留 → retry Enter で回復 → DELIVERED exit0" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_CLEAR_AFTER=2 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0 --retries 2
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_DELIVERED* ]]
  # SENDL 1 回 + ENTER 2 回（初回 + 回復 1）。
  run grep -c '^SENDL' "$STUB_DIR/calls.log"; [ "$output" -eq 1 ]
  run grep -c '^ENTER' "$STUB_DIR/calls.log"; [ "$output" -eq 2 ]
}

@test "send: 永久残留 → retry 尽きて RESIDUAL exit3（fail-loud）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_CLEAR_AFTER=99 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0 --retries 2
  [ "$status" -eq 3 ]
  [[ "$output" == *INJECT_RESIDUAL* ]]
  # 初回 Enter + retry 2 = 3。
  [ "$(cat "$STUB_DIR/enters")" -eq 3 ]
}

@test "send: 送信後に入力ボックスを特定できず → INCONCLUSIVE exit4（fail-loud・2 系統目の fail-loud）" {
  # gate は通る（送信前は入力欄あり・空）が、送信後の capture で box が消えるケース。
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_NO_BOX_AFTER_SEND=1 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0 --retries 1
  [ "$status" -eq 4 ]
  [[ "$output" == *INJECT_INCONCLUSIVE* ]]
  # INCONCLUSIVE は Enter 追送しない（RESIDUAL 限定）→ 初回 send の 1 回のみ。
  run grep -c '^ENTER' "$STUB_DIR/calls.log"; [ "$output" -eq 1 ]
}

@test "send: --file からの payload 正常系（読取り→marker 導出→送達）→ DELIVERED exit0" {
  printf '%s\n' 'line1' 'payload-tail-marker' > "$BATS_TEST_TMPDIR/payload.txt"
  echo 2 > "$STUB_DIR/enters"   # クリア済み状態を模す（--file 読取り経路の実行が主眼）
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_CLEAR_AFTER=2 \
    "$INJECT" send --target %1 --file "$BATS_TEST_TMPDIR/payload.txt" --settle 0
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_DELIVERED* ]]
  # --file の payload が send-keys -l で送られている。
  run grep -c '^SENDL' "$STUB_DIR/calls.log"; [ "$output" -eq 1 ]
}

@test "send: --no-enter は Enter を送らない（送達確認だけ・DELIVERED は成立しうる）" {
  echo 2 > "$STUB_DIR/enters"   # 既にクリア状態を模す
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_CLEAR_AFTER=2 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0 --no-enter
  [ "$status" -eq 0 ]
  run grep -c '^ENTER' "$STUB_DIR/calls.log"; [ "$output" -eq 0 ]
}

# --- busy-check: 送信前 gate の pure core（sc-6mtm）---------------------------
# 実 CC TUI capture（tests/fixtures/real-cc-capture.txt）を土台に、入力欄の状態だけを変えて 3 値を pin する。
# 判定は verify と同一の構造検知（水平罫線ペア + ❯）を通す＝pane 全文 grep をしない（誤発火の先例 sc-11z）。

@test "busy-check: 実 capture の空 ❯ 入力欄 → IDLE exit0（push 可・DELIVERED 経路の回帰なし）" {
  run "$INJECT" busy-check --capture-file "$REPO_ROOT/tests/fixtures/real-cc-capture.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_IDLE* ]]
}

@test "busy-check: 実 capture の ❯ 行に human 打鍵テキスト → DEFERRED exit5 reason=busy（mailbox 誘導）" {
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ admin へ返す質問を書きかけ"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" busy-check --capture-file "$CAP"
  [ "$status" -eq 5 ]
  [[ "$output" == *INJECT_DEFERRED* ]]
  [[ "$output" == *"reason=busy"* ]]
  [[ "$output" == *mailbox* ]]
}

@test "busy-check: paste placeholder が入力欄に滞留 → DEFERRED exit5（前回注入の残留にも押し込まない）" {
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ [Pasted text +7 lines]"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" busy-check --capture-file "$CAP"
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=busy"* ]]
}

@test "busy-check: 入力欄を特定できない → DEFERRED exit5 reason=unknown（fail-closed）" {
  printf '%s\n' '✻ Thinking… (esc to interrupt)' > "$CAP"
  run "$INJECT" busy-check --capture-file "$CAP"
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=unknown"* ]]
}

@test "busy-check: 罫線ペアはあるがプロンプト無し（transcript 由来の誤選択）→ DEFERRED exit5 reason=unknown" {
  # IDLE は「入力欄だと確証できた box が空」のときだけ宣言する（sc-6mtm self-review・fail-open 封鎖）。
  # 罫線ペアだけを見て「空 interior ⇒ idle」と宣言すると、transcript 中の区切り線を誤選択して push してしまう。
  R='──────────────────────────────────'
  printf '%s\n' 'agent output' "$R" '' "$R" '  user@host  scribe  main' > "$CAP"
  run "$INJECT" busy-check --capture-file "$CAP"
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=unknown"* ]]
}

@test "busy-check: 入力欄に '>>>' だけを打鍵中 → DEFERRED exit5 reason=busy（プロンプト glyph を内容と混同しない）" {
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ >>>"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" busy-check --capture-file "$CAP"
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=busy"* ]]
}

@test "busy-check: --ignore-pattern で ghost text を空扱いにできる（誤 BUSY の調整口）" {
  cat > "$CAP" <<'EOF'
╭──────────────────────────────╮
│ > Try "edit <file>"          │
╰──────────────────────────────╯
EOF
  run "$INJECT" busy-check --ignore-pattern 'Try "' --capture-file "$CAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_IDLE* ]]
}

@test "busy-check: --ignore-pattern が human 打鍵行を消して idle 化したら loud に警告する（gate 盲目化・sc-6mtm）" {
  # grep -Ev は行削除ゆえ、広い pattern は human の書きかけ行ごと消して busy を idle に化けさせる。
  # exit 0（idle）自体は ghost text 想定として許すが、**silent には通さない**。
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ Thinking about the plan — 書きかけ"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" busy-check --ignore-pattern 'Thinking' --capture-file "$CAP"
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_IDLE_VIA_IGNORE* ]]   # ← 盲目化の可能性を loud に告げている
}

@test "busy-check: ignore-pattern 無しなら同じ capture は素直に BUSY（上の警告が非 vacuous）" {
  python3 - "$REPO_ROOT/tests/fixtures/real-cc-capture.txt" > "$CAP" <<'PY'
import sys
L = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i in range(len(L)-1, -1, -1):
    if L[i].startswith("❯"):
        L[i] = "❯ Thinking about the plan — 書きかけ"; break
sys.stdout.write("\n".join(L))
PY
  run "$INJECT" busy-check --capture-file "$CAP"
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=busy"* ]]
}

@test "busy-check: --target は tmux capture-pane を読む（stub・live pane 経路）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" "$INJECT" busy-check --target %1
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_IDLE* ]]
  [[ "$output" == *"target=%1"* ]]
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_BUSY_BEFORE_SEND=1 "$INJECT" busy-check --target %1
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=busy"* ]]
}

@test "busy-check: --target と --capture-file の同時指定は die exit1" {
  echo x > "$CAP"
  run "$INJECT" busy-check --target %1 --capture-file "$CAP"
  [ "$status" -eq 1 ]
}

# --- send の busy-check gate（sc-6mtm・co-submit 事故の構造対策）--------------

@test "send: 入力欄が非空（human 打鍵中）→ DEFERRED exit5 で **1 キーも送らない**（co-submit 防止の核）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_BUSY_BEFORE_SEND=1 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0
  [ "$status" -eq 5 ]
  [[ "$output" == *INJECT_DEFERRED* ]]
  [[ "$output" == *"reason=busy"* ]]
  [[ "$output" == *mailbox* ]]
  # payload も Enter も一切送っていない（送ってからでは merge を検知できない）。
  [ "$(cat "$STUB_DIR/sendl")" -eq 0 ]
  [ "$(cat "$STUB_DIR/enters")" -eq 0 ]
  run grep -c '^SENDL\|^ENTER' "$STUB_DIR/calls.log"; [ "$output" -eq 0 ]
}

@test "send: 入力欄を特定できない → DEFERRED exit5（fail-closed・送らない。旧 fail-open を塞ぐ）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_NO_BOX=1 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0 --retries 1
  [ "$status" -eq 5 ]
  [[ "$output" == *"reason=unknown"* ]]
  [ "$(cat "$STUB_DIR/sendl")" -eq 0 ]
  [ "$(cat "$STUB_DIR/enters")" -eq 0 ]
}

@test "send: 入力欄が空（idle）→ gate を通り従来どおり送達 DELIVERED exit0（回帰なし）" {
  echo 2 > "$STUB_DIR/enters"   # 送信後すぐクリアされる pane を模す
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_CLEAR_AFTER=2 \
    "$INJECT" send --target %1 --text "payload-tail-marker" --settle 0
  [ "$status" -eq 0 ]
  [[ "$output" == *INJECT_DELIVERED* ]]
  [ "$(cat "$STUB_DIR/sendl")" -eq 1 ]
}

@test "send: --clear-first（入力欄 wipe = C-u 相当）は die exit1（no-push 原則・機械拒否）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" "$INJECT" send --target %1 --text hi --clear-first
  [ "$status" -eq 1 ]
  [[ "$output" == *"--clear-first"* ]]
  [[ "$output" == *禁止* ]]
  # 拒否は send-keys より前（1 キーも送らない）。
  [ "$(cat "$STUB_DIR/sendl")" -eq 0 ]
}

@test "send: --clear / --wipe / --wipe-input も同じく die exit1（別名で回避させない）" {
  for opt in --clear --wipe --wipe-input; do
    run env SCRIBE_TMUX="$STUB_DIR/tmux" "$INJECT" send --target %1 --text hi "$opt"
    [ "$status" -eq 1 ]
    [[ "$output" == *禁止* ]]
  done
}

# --- usage / fail-loud ------------------------------------------------------

@test "send: --target 欠落は die exit1" {
  run "$INJECT" send --text hi
  [ "$status" -eq 1 ]
}

@test "send: --file と --text の同時指定は die" {
  echo hi > "$CAP"
  run "$INJECT" send --target %1 --file "$CAP" --text hi
  [ "$status" -eq 1 ]
}

@test "send: 空 payload は die" {
  run "$INJECT" send --target %1 --text ""
  [ "$status" -eq 1 ]
}

@test "send: 非数値 --settle は fail-loud die exit1（--retries と対称）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" "$INJECT" send --target %1 --text hi --settle abc
  [ "$status" -eq 1 ]
  [[ "$output" == *"--settle"* ]]
}

@test "未知サブコマンドは die exit1" {
  run "$INJECT" bogus
  [ "$status" -eq 1 ]
}

@test "scribe-need-val: 値省略で次フラグ誤消費を fail-loud" {
  run "$INJECT" verify --marker --capture-file "$CAP"
  [ "$status" -eq 1 ]
}

#!/usr/bin/env bats
# scribe-inject.sh — admin 操舵注入の送達確認ヘルパ（sc-6vj）の回帰テスト。
# **live tmux は起動しない**（worker sandbox では tmux server 不可・かつ検知ロジックは pure な文字列処理）。
#   - verify: fixture capture で残留検知の弁別を確認（transcript echo と入力欄滞留を取り違えない核）。
#   - send:   SCRIBE_TMUX を stub へ差し替え、Enter 追送による回復（incident A）と fail-loud を確認。
# 検知ロジックがコード化する契約の SSOT = scripts/scribe-inject.sh ヘッダ。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  INJECT="$REPO_ROOT/scripts/scribe-inject.sh"
  CAP="$BATS_TEST_TMPDIR/cap.txt"
  # stub tmux（send-keys 記録 / capture-pane は Enter 回数で residual→clean 切替）。
  STUB_DIR="$BATS_TEST_TMPDIR/stub"; mkdir -p "$STUB_DIR"
  : > "$STUB_DIR/calls.log"; echo 0 > "$STUB_DIR/enters"
  cat > "$STUB_DIR/tmux" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$(readlink -f "$0")")"
sub="$1"; shift
case "$sub" in
  send-keys)
    if printf '%s\n' "$@" | grep -q -- '-l'; then echo "SENDL $*" >> "$S/calls.log"
    elif printf '%s\n' "$@" | grep -q -- 'Enter'; then
      echo "ENTER $*" >> "$S/calls.log"; n=$(cat "$S/enters"); echo $((n+1)) > "$S/enters"
    fi ;;
  capture-pane)
    # STUB_NO_BOX=1 なら入力ボックスを含まない capture（send の INCONCLUSIVE 経路検証用）。
    if [[ "${STUB_NO_BOX:-0}" == 1 ]]; then printf '%s\n' 'Thinking… (esc to interrupt)'; exit 0; fi
    n=$(cat "$S/enters"); thr="${STUB_CLEAR_AFTER:-2}"
    if (( n >= thr )); then printf '%s\n' '╭────────────╮' '│ >          │' '╰────────────╯'
    else printf '%s\n' '╭────────────╮' '│ > payload-tail-marker │' '╰────────────╯'; fi ;;
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

@test "send: 入力ボックスを最後まで特定できず → INCONCLUSIVE exit4（fail-loud・2 系統目の fail-loud）" {
  run env SCRIBE_TMUX="$STUB_DIR/tmux" STUB_NO_BOX=1 \
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

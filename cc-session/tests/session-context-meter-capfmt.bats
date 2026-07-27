#!/usr/bin/env bats
# session-context-meter-capfmt.bats — fleet-cap seam 適合 adapter のテスト
# canonical meter は SESSION_METER_BIN で stub（hermetic・実 tmux 不要）。
# consumer（orch-fleet-cap.sh _eval_cap）の parse を再現する round-trip も pin する。
#
# 注意（bats stub の構造盲点）: stub は実 meter の挙動を再現しない。
# adapter→実 meter の結線は「統合」テスト（tmux 関数 mock 経由）と
# ライブ smoke で確認する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CAPFMT="$SCRIPT_DIR/session-context-meter-capfmt.sh"

setup() {
    TMPD="$BATS_TEST_TMPDIR"
    STUB="$TMPD/meter-stub.sh"
    export SESSION_METER_BIN="$STUB"
    export STUB_ARGV_FILE="$TMPD/argv.txt"
    export STUB_OUT_FILE="$TMPD/stub-out.txt"

    # 既定 stub: pane 成功形
    make_stub 0 'used_pct=13 used_tokens=130000 window_tokens=1000000 source=pane sid=- target=ccs:2'
}

# make_stub <rc> <stdout>（stdout は '' で無出力）
make_stub() {
    export STUB_RC="$1"
    if [ -n "$2" ]; then
        printf '%s\n' "$2" > "$STUB_OUT_FILE"
    else
        : > "$STUB_OUT_FILE"
    fi
    cat > "$STUB" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGV_FILE"
[ -s "$STUB_OUT_FILE" ] && cat "$STUB_OUT_FILE"
exit "$STUB_RC"
EOF
    chmod +x "$STUB"
}

# =============================================================================
# 成功経路（cap 形式変換）
# =============================================================================

@test "capfmt: pane 成功形を '<pct> <abs>' 1 行へ変換し exit 0" {
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$output" = "13 130000" ]
}

@test "capfmt: 位置引数を --target として canonical meter に渡す" {
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_ARGV_FILE")" = "--target
ccs" ]
}

@test "capfmt: 空白入り target も 1 引数のまま透過する" {
    run "$CAPFMT" 'my session'
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_ARGV_FILE")" = "--target
my session" ]
}

@test "capfmt: 未知 key の混入は無視する（前方互換・列追加は末尾のみ契約）" {
    make_stub 0 'extra=1 used_pct=7 used_tokens=70000 window_tokens=1000000 source=pane sid=- target=x new_col=z'
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$output" = "7 70000" ]
}

@test "capfmt: 複数行 stub 出力でも 1 行目のみ parse（防御）" {
    make_stub 0 "$(printf 'used_pct=13 used_tokens=130000 window_tokens=1000000 source=pane sid=- target=ccs:2\ngarbage second line')"
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$output" = "13 130000" ]
}

# =============================================================================
# 欠測・失敗経路（捏造値を出さない・fail-open 契約）
# =============================================================================

@test "capfmt: jsonl fallback（used_pct='-'）は exit 4・stdout 無出力（0 埋めしない）" {
    make_stub 0 'used_pct=- used_tokens=130000 window_tokens=- source=jsonl sid=aaaa-bbbb target=ccs:2'
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$output" ]
}

@test "capfmt: used_tokens 欠測も exit 4・無出力" {
    make_stub 0 'used_pct=13 used_tokens=- window_tokens=1000000 source=pane sid=- target=ccs:2'
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$output" ]
}

@test "capfmt: 非整数値（used_pct=abc）は exit 4・無出力" {
    make_stub 0 'used_pct=abc used_tokens=130000 window_tokens=1000000 source=pane sid=- target=x'
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$output" ]
}

@test "capfmt: meter 出力が空（契約違反）は exit 4・無出力" {
    make_stub 0 ''
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$output" ]
}

@test "capfmt: meter exit 3（解決失敗）を伝播・無出力" {
    make_stub 3 ''
    run "$CAPFMT" nonexistent
    [ "$status" -eq 3 ]
    [ -z "$output" ]
}

@test "capfmt: meter exit 4（計測不能）を伝播・無出力" {
    make_stub 4 ''
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$output" ]
}

# =============================================================================
# usage error
# =============================================================================

@test "capfmt: 引数 0 個は exit 2（usage は stderr のみ・stdout 無出力）" {
    run "$CAPFMT"
    [ "$status" -eq 2 ]
    # bats の run は stderr を output へ混ぜるため、stdout 純度は直接検証する
    [ -z "$("$CAPFMT" 2>/dev/null || true)" ]
}

@test "capfmt: 引数 2 個は exit 2（seam は位置引数 1 個の契約）" {
    run "$CAPFMT" ccs extra
    [ "$status" -eq 2 ]
}

@test "capfmt: 空引数は exit 2" {
    run "$CAPFMT" ''
    [ "$status" -eq 2 ]
}

# =============================================================================
# consumer round-trip（orch-fleet-cap.sh _eval_cap の parse を再現）
# =============================================================================

@test "capfmt: _eval_cap 再現 round-trip（read -r pct abs _ で両整数が取れる）" {
    out="$("$CAPFMT" ccs)"
    read -r pct abs _ <<< "$out" || true
    [[ "$pct" =~ ^[0-9]+$ ]]
    [[ "$abs" =~ ^[0-9]+$ ]]
    [ "$pct" = "13" ]
    [ "$abs" = "130000" ]
}

# =============================================================================
# 統合（SESSION_METER_BIN 未設定 → 同 dir の実 meter を既定解決。
# tmux は exported 関数で mock = session-context-meter.bats と同型）
# =============================================================================

@test "capfmt: 統合 = 実 meter 経由で pane statusline を cap 形式へ変換" {
    unset SESSION_METER_BIN

    tmux() {
        local sub="$1"; shift || true
        case "$sub" in
            has-session) [ "${TMUX_MOCK_HAS_SESSION:-1}" = "1" ] ;;
            list-windows) printf '%s\n' "${TMUX_MOCK_LIST_WINDOWS:-sc:1 admin}" ;;
            list-panes)
                local fmt=""
                while [ $# -gt 0 ]; do
                    case "$1" in -F) fmt="$2"; shift 2 ;; *) shift ;; esac
                done
                if [ "$fmt" = '#{pane_pid}' ]; then
                    printf '%s\n' "${TMUX_MOCK_PANE_PID:-1}"
                elif [ "$fmt" = '#{pane_id} #{pane_current_command}' ]; then
                    # bare session 名の claude pane 特定（meter 本体の新契約）
                    printf '%b\n' "${TMUX_MOCK_SESSION_PANES:-%7 claude}"
                else
                    printf '%b\n' "${TMUX_MOCK_LIST_PANES:-claude\t0\t%7\t/home/test}"
                fi
                ;;
            capture-pane) cat "${TMUX_MOCK_CAPTURE_FILE:-/dev/null}" ;;
            display-message) printf '%s\n' "${TMUX_MOCK_PANE_ID:-%7}" ;;
            *) return 0 ;;
        esac
    }
    export -f tmux
    export TMUX_MOCK_CAPTURE_FILE="$TMPD/capture.txt"
    cat > "$TMPD/capture.txt" <<'EOF'
● 前の応答テキスト

❯

32% 320k/1M Opus 4.8 [xhigh] 5h:92%(1h23m) 7d:67%(2d5h)
EOF

    run "$CAPFMT" sc
    [ "$status" -eq 0 ]
    [ "$output" = "32 320000" ]
}

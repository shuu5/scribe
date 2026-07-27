#!/usr/bin/env bats
# session-context-meter-capfmt.bats — fleet-cap seam 適合 adapter のテスト
# canonical meter は SESSION_METER_BIN で stub（hermetic・実 tmux 不要）。
# consumer（orch-fleet-cap.sh _eval_cap）の parse を再現する round-trip も pin する。
#
# 注意: capfmt は成功時に監査痕跡 1 行を stderr へ出す（契約）。bats の run は
# stderr を $output へ混ぜるため、stdout の等値検証は command substitution
# （2>/dev/null）で行い、run は status 検証に使う。
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

    # hermetic 隔離: 統合テスト（実 meter）が実ホストの pane-map / transcript を
    # 読まないように必ず fixture 側へ向ける（R2 gate finding: 非 hermetic）
    export SESSION_METER_PANE_MAP="$TMPD/pane-map.tsv"
    export SESSION_METER_PROJECT_DIRS="$TMPD/projects"
    : > "$TMPD/pane-map.tsv"
    mkdir -p "$TMPD/projects"

    # 既定 stub: pane 成功形
    make_stub 0 'used_pct=13 used_tokens=130000 window_tokens=1000000 source=pane sid=- target=%3'
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
    [ "$("$CAPFMT" ccs 2>/dev/null)" = "13 130000" ]
}

@test "capfmt: <session>:admin を --source pane 固定で計測する（action 対象との一致）" {
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$(cat "$STUB_ARGV_FILE")" = "--target
ccs:admin
--source
pane" ]
}

@test "capfmt: SESSION_METER_WINDOW で window を上書きできる" {
    SESSION_METER_WINDOW=orchestrator run "$CAPFMT" scriptorium
    [ "$status" -eq 0 ]
    grep -qx 'scriptorium:orchestrator' "$STUB_ARGV_FILE"
}

@test "capfmt: 空白入り session 名も 1 引数のまま透過する" {
    run "$CAPFMT" 'my session'
    [ "$status" -eq 0 ]
    grep -qx 'my session:admin' "$STUB_ARGV_FILE"
}

@test "capfmt: 未知 key の混入は無視する（前方互換・列追加は末尾のみ契約）" {
    make_stub 0 'extra=1 used_pct=7 used_tokens=70000 window_tokens=1000000 source=pane sid=- target=%3 new_col=z'
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$("$CAPFMT" ccs 2>/dev/null)" = "7 70000" ]
}

@test "capfmt: 複数行 stub 出力でも 1 行目のみ parse（防御）" {
    make_stub 0 "$(printf 'used_pct=13 used_tokens=130000 window_tokens=1000000 source=pane sid=- target=%%3\ngarbage second line')"
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [ "$("$CAPFMT" ccs 2>/dev/null)" = "13 130000" ]
    # 監査痕跡も 1 行目のみ（2 行目が echo されないことで防御を識別可能にする）
    [ "$("$CAPFMT" ccs 2>&1 >/dev/null | wc -l)" -eq 1 ]
}

@test "capfmt: 監査痕跡（meter の key=value 行）を stderr へ出し stdout は 2 値のみ" {
    run "$CAPFMT" ccs
    [ "$status" -eq 0 ]
    [[ "$output" == *"capfmt: used_pct=13"* ]]
    [ "$("$CAPFMT" ccs 2>/dev/null)" = "13 130000" ]
}

# =============================================================================
# 欠測・失敗経路（捏造値を出さない・fail-open 契約）
# =============================================================================

@test "capfmt: used_pct 欠測（'-'）は exit 4・stdout 無出力（0 埋めしない）" {
    make_stub 0 'used_pct=- used_tokens=130000 window_tokens=- source=jsonl sid=aaaa-bbbb target=%3'
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$("$CAPFMT" ccs 2>/dev/null || true)" ]
}

@test "capfmt: used_tokens 欠測も exit 4・無出力" {
    make_stub 0 'used_pct=13 used_tokens=- window_tokens=1000000 source=pane sid=- target=%3'
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$("$CAPFMT" ccs 2>/dev/null || true)" ]
}

@test "capfmt: 非整数値（used_pct=abc）は exit 4・無出力" {
    make_stub 0 'used_pct=abc used_tokens=130000 window_tokens=1000000 source=pane sid=- target=%3'
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$("$CAPFMT" ccs 2>/dev/null || true)" ]
}

@test "capfmt: meter 出力が空（契約違反）は exit 4・無出力" {
    make_stub 0 ''
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$("$CAPFMT" ccs 2>/dev/null || true)" ]
}

@test "capfmt: meter exit 3（解決失敗）を伝播・無出力" {
    make_stub 3 ''
    run "$CAPFMT" nonexistent
    [ "$status" -eq 3 ]
    [ -z "$("$CAPFMT" nonexistent 2>/dev/null || true)" ]
}

@test "capfmt: meter exit 4（計測不能）を伝播・無出力" {
    make_stub 4 ''
    run "$CAPFMT" ccs
    [ "$status" -eq 4 ]
    [ -z "$("$CAPFMT" ccs 2>/dev/null || true)" ]
}

# =============================================================================
# usage error
# =============================================================================

@test "capfmt: 引数 0 個は exit 2（usage は stderr のみ・stdout 無出力）" {
    run "$CAPFMT"
    [ "$status" -eq 2 ]
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
    out="$("$CAPFMT" ccs 2>/dev/null)"
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

@test "capfmt: 統合 = 実 meter 経由で <session>:admin の statusline を cap 形式へ変換" {
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
                elif [ "$fmt" = '#{pane_id}' ]; then
                    printf '%b\n' "${TMUX_MOCK_SESSION_PANES:-%7}"
                else
                    printf '%b\n' "${TMUX_MOCK_LIST_PANES:-claude\t0\t%7\t/home/test}"
                fi
                ;;
            capture-pane) cat "${TMUX_MOCK_CAPTURE_FILE:-/dev/null}" ;;
            display-message)
                local fmt="" tgt=""
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -p) shift ;;
                        -t) tgt="$2"; shift 2 ;;
                        *) fmt="$1"; shift ;;
                    esac
                done
                if [[ "$fmt" == *pane_dead* ]]; then
                    printf '%s\n' "${TMUX_MOCK_PANE_STATE:-0 1 claude}"
                elif [[ "$fmt" == *session_name* ]]; then
                    printf '%s %s\n' "${TMUX_MOCK_PANE_ID:-%7}" "${TMUX_MOCK_ACTUAL_WIN:-sc:1}"
                else
                    printf '%s\n' "${TMUX_MOCK_PANE_ID:-%7}"
                fi
                ;;
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
    [ "$("$CAPFMT" sc 2>/dev/null)" = "32 320000" ]
}

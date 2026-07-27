#!/usr/bin/env bats
# session-context-meter.bats — session context meter primitive のテスト
# 全 tmux 呼び出しを exported 関数でモック（実 tmux 不要・hermetic）。
# transcript / pane-map は $BATS_TEST_TMPDIR の fixture。
#
# 注意（bats tmux stub の構造盲点・doobidoo ca78a472）: stub は実 tmux の
# 非 0 経路を再現しないため、実環境固有挙動（送達・描画）はライブ smoke で
# 別途確認する。本ファイルは parse / 経路分岐 / 契約（exit code・出力形式）を pin する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
METER="$SCRIPT_DIR/session-context-meter.sh"

setup() {
    TMPD="$BATS_TEST_TMPDIR"

    # --- tmux モック（環境変数駆動・export -f で子プロセスへ伝播） ---
    # TMUX_MOCK_CAPTURE_FILE : capture-pane が返す内容
    # TMUX_MOCK_HAS_SESSION  : has-session の exit を固定（1=成功 / 0=失敗・旧互換）
    # TMUX_MOCK_SESSIONS     : 実在 session 名の空白区切り（既定 'sc'。HAS_SESSION
    #                          未設定時に '=name'=exact / 裸 name=prefix で判定）
    # TMUX_MOCK_LIST_WINDOWS : list-windows -F '#{session_name}:#{window_index} #{window_name}'
    # TMUX_MOCK_LIST_PANES   : list-panes の 4 カラム行（session-state 系互換）
    # TMUX_MOCK_SESSION_PANES: list-panes -s -F '#{pane_id}'（bare session 列挙・%b 展開）
    # TMUX_MOCK_PANE_STATE   : display-message '#{pane_dead} #{pane_pid} #{pane_current_command}'
    #                          の既定値。pane 別上書きは TMUX_MOCK_PANE_STATE_<N>（%N の N）
    # TMUX_MOCK_PANE_ID      : display-message '#{pane_id}'
    # TMUX_MOCK_ARGV_LOG     : 全呼び出しの subcommand+argv を 1 行 1 要素で記録
    #                          （呼び出し境界 '--'）。「どの pane/scope を見たか」を
    #                          assert 可能にする（R2 gate finding: 引数を捨てる mock
    #                          は計測対象の同一性を構造的に検証できない）
    tmux() {
        local sub="$1"; shift || true
        { printf '%s\n' "$sub" "$@"; echo '--'; } >> "${TMUX_MOCK_ARGV_LOG:-/dev/null}"
        case "$sub" in
            has-session)
                # 実 tmux の解決意味論を再現する: '=name' は exact・裸 name は
                # prefix 一致（R3 gate finding: colon 経路の prefix false attribution
                # を検知するため）。TMUX_MOCK_HAS_SESSION 明示時はそれを優先（旧互換）。
                local hs_tgt=""
                while [ $# -gt 0 ]; do
                    case "$1" in -t) hs_tgt="$2"; shift 2 ;; *) shift ;; esac
                done
                if [ -n "${TMUX_MOCK_HAS_SESSION:-}" ]; then
                    [ "$TMUX_MOCK_HAS_SESSION" = "1" ]
                else
                    local hs_name="${hs_tgt#=}" hs_s
                    for hs_s in ${TMUX_MOCK_SESSIONS:-sc}; do
                        if [ "${hs_tgt:0:1}" = "=" ]; then
                            [ "$hs_s" = "$hs_name" ] && return 0
                        else
                            case "$hs_s" in "$hs_name"*) return 0 ;; esac
                        fi
                    done
                    return 1
                fi
                ;;
            list-windows)
                printf '%s\n' "${TMUX_MOCK_LIST_WINDOWS:-sc:1 admin}"
                ;;
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
            capture-pane)
                cat "${TMUX_MOCK_CAPTURE_FILE:-/dev/null}"
                ;;
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
                    local key="${tgt#%}"; key="${key//[^A-Za-z0-9]/_}"
                    local var="TMUX_MOCK_PANE_STATE_$key"
                    printf '%s\n' "${!var:-${TMUX_MOCK_PANE_STATE:-0 1 claude}}"
                else
                    printf '%s\n' "${TMUX_MOCK_PANE_ID:-%7}"
                fi
                ;;
            *)
                return 0
                ;;
        esac
    }
    export -f tmux
    export TMUX_MOCK_CAPTURE_FILE="$TMPD/capture.txt"
    export TMUX_MOCK_ARGV_LOG="$TMPD/tmux-argv.log"
    : > "$TMPD/tmux-argv.log"

    # 既定 fixture: statusline line2 を含む pane capture
    cat > "$TMPD/capture.txt" <<'EOF'
● 前の応答テキスト

❯

32% 320k/1M Opus 4.8 [xhigh] 5h:92%(1h23m) 7d:67%(2d5h)
EOF

    # 既定 fixture: pane-map + transcript
    # %70 行は prefix 衝突 fixture（%7 との取り違え＝前方一致退行を検知する。
    # 正キー %7 を先・衝突キー %70 を後に置く: 前方一致化すると %70 行も key %7 に
    # match して last-wins で誤 sid になり、transcript miss で RED 化する）
    export SESSION_METER_PANE_MAP="$TMPD/pane-map.tsv"
    printf '%%7\taaaa-bbbb-cccc\n%%70\tprefix-collision-sid\n' > "$TMPD/pane-map.tsv"

    mkdir -p "$TMPD/projects/-home-test-proj"
    export SESSION_METER_PROJECT_DIRS="$TMPD/projects"
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"user","message":{"content":"hi"}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":2548,"cache_read_input_tokens":118273,"output_tokens":1064}}}
EOF
}

# =============================================================================
# pane source（primary）
# =============================================================================

@test "pane: statusline line2 を parse して 3 値を返す（session:window target）" {
    run "$METER" --target sc:admin
    [ "$status" -eq 0 ]
    # target= は解決後の pane id（gate/capture/監査痕跡を単一 pane に固定 = R3）
    [ "$output" = "used_pct=32 used_tokens=320000 window_tokens=1000000 source=pane sid=- target=%7" ]
}

@test "契約: session 名の prefix 一致で別 session を測らない（colon 経路も exact）" {
    # 実在 session は 'paper' のみ。要求 'pap' は tmux の裸 -t なら prefix で
    # paper に解決されてしまう（R3 gate CONFIRMED の再現形）→ exact 検証で exit 3
    export TMUX_MOCK_SESSIONS='paper'
    export TMUX_MOCK_LIST_WINDOWS='paper:1 admin'
    run "$METER" --target pap:admin
    [ "$status" -eq 3 ]
    [ -z "$("$METER" --target pap:admin 2>/dev/null || true)" ]
}

@test "契約: --source pane は決して jsonl を出さない（解決不能 + --sid 併用でも exit 3）" {
    export TMUX_MOCK_LIST_WINDOWS='sc:1 other'
    run "$METER" --target sc:admin --sid aaaa-bbbb-cccc --source pane
    [ "$status" -eq 3 ]
    [[ "$output" != *"source=jsonl"* ]]
}

@test "pane: %N pane-id target は resolve を経由せず直接 capture する" {
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=pane"* ]]
    [[ "$output" == *"target=%7"* ]]
}

@test "pane: 200k 窓（k/k 表記）を正しく整数化する" {
    cat > "$TMPD/capture.txt" <<'EOF'
45% 90k/200k Haiku 4.5
EOF
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_pct=45 used_tokens=90000 window_tokens=200000"* ]]
}

@test "pane: used の生数値は受理・window は k/M 必須（SSOT 準拠形）" {
    cat > "$TMPD/capture.txt" <<'EOF'
0% 500/1M Haiku 4.5
EOF
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_pct=0 used_tokens=500 window_tokens=1000000"* ]]
}

@test "pane: window token に k/M が無い行は拒否する（fmt_tokens SSOT 上あり得ない形）" {
    cat > "$TMPD/capture.txt" <<'EOF'
12% 500/800
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
}

@test "pane: dialog 画面の prose 行（50% 3/4 done）を計測値にしない" {
    cat > "$TMPD/capture.txt" <<'EOF'
❯ 1. Yes
  2. No
 Enter to confirm · Esc to cancel
  50% 3/4 done
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
}

@test "pane: 健全性 bound 外（pct>100 / used>window）は拒否する" {
    cat > "$TMPD/capture.txt" <<'EOF'
999% 9999k/1M Opus 5
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
    cat > "$TMPD/capture.txt" <<'EOF'
5% 2M/1M Opus 5
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
}

@test "pane: 入力ボックスより上の本文 decoy 行は拾わない（❯ anchor）" {
    cat > "$TMPD/capture.txt" <<'EOF'
88% 880k/1M 本文へ貼られた他 session の statusline
❯
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
}

@test "pane: live 形（statusline の下に trailing UI 2 行 + 空行）を parse できる" {
    # R3 gate CONFIRMED: 旧 tail -3 は workflow 進捗行で margin 0 だった。
    # ❯ anchor により footer が増えても statusline を見失わないことを pin する。
    cat > "$TMPD/capture.txt" <<'EOF'
❯
  shuu5@host (user@example.com)  cc-session  main*
  44% 440k/1M Fable 5 [xhigh] 5h:24%(4h3m) 7d:70%(4d12h)
  ⏵⏵ bypass permissions on · 1 shell · ← 5 agents

  ◯ cell-quality  … 4/11 agents done · 19m 18s · ↓ 1.0m tokens
  ◯ p08-mv-gate  … 2/10 agents done · 3m 2s
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_pct=44 used_tokens=440000"* ]]
}

@test "pane: ❯ 不在画面は末尾 6 非空行 fallback（空行除去が効く形で pin）" {
    { echo '30% 300k/1M Opus 5'; printf '\n\n\n\n\n\n'; echo 'trailing note'; } > "$TMPD/capture.txt"
    run "$METER" --target %7 --source pane
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_pct=30"* ]]
}

@test "pane: 健全性 bound は各条件が独立に効く（pct>100 単独 / window<100k 単独）" {
    cat > "$TMPD/capture.txt" <<'EOF'
101% 10k/1M Opus 5
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
    cat > "$TMPD/capture.txt" <<'EOF'
50% 30k/50k done
EOF
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
}

@test "pane: 同形状の行が複数あるとき最終行（statusline 側）を採る" {
    cat > "$TMPD/capture.txt" <<'EOF'
10% 100k/1M これは本文に紛れた偽の行
99% 990k/1M
EOF
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_pct=99 used_tokens=990000"* ]]
}

@test "pane: 先頭空白付きの実 TUI render 形を parse できる（live 実測 2026-07-24）" {
    cat > "$TMPD/capture.txt" <<'EOF'
  shuu5@ipatho-server-2 (user@example.com)  cc-session  main*
  19% 190k/1M Fable 5 [xhigh] 5h:4%(4h37m) 7d:99%(3h7m)
  ⏵⏵ bypass permissions on (shift+tab to cycle)
EOF
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_pct=19 used_tokens=190000 window_tokens=1000000"* ]]
}

@test "pane: --source pane で statusline 不在なら exit 4（jsonl へ落ちない）" {
    printf '❯ \n' > "$TMPD/capture.txt"
    run "$METER" --target %7 --source pane
    [ "$status" -eq 4 ]
}

# =============================================================================
# stale-screen gate（claude 非稼働 pane の残渣を読まない）
# =============================================================================

@test "gate: claude 非稼働（idle）pane では statusline があっても jsonl へ fallback" {
    export TMUX_MOCK_PANE_STATE='0 1 bash'
    # pane_alive_claude の pgid 探索を決定論的に空へ（ps モック）
    ps() { :; }
    export -f ps
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=jsonl"* ]]
    [[ "$output" == *"used_tokens=120823"* ]]
}

@test "gate: dead pane（exited）も同様に jsonl へ fallback" {
    export TMUX_MOCK_PANE_STATE='1 1 claude'
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=jsonl"* ]]
}

@test "gate: cld-spawn 由来 pane（cmd=bash・pgid 内に claude）は pane source で計測できる" {
    export TMUX_MOCK_PANE_STATE='0 4242 bash'
    ps() {
        case "$*" in
            *pgid*) echo ' 4242' ;;
            *comm*) printf 'claude\n' ;;
        esac
    }
    pgrep() { echo 4242; }
    export -f ps pgrep
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=pane"* ]]
    [[ "$output" == *"used_pct=32"* ]]
}

@test "gate: pgid はあるが group 内に claude が居なければ pane を信頼しない" {
    export TMUX_MOCK_PANE_STATE='0 4242 bash'
    ps() { case "$*" in *pgid*) echo ' 4242' ;; esac; }
    pgrep() { return 1; }
    export -f ps pgrep
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=jsonl"* ]]
}

@test "gate: pgrep は pgid スコープ + 完全一致で問い合わせる（argv pin）" {
    export TMUX_MOCK_PANE_STATE='0 4242 bash'
    export PGREP_ARGV_LOG="$TMPD/pgrep-argv.log"
    : > "$PGREP_ARGV_LOG"
    ps() { case "$*" in *pgid*) echo ' 4242' ;; esac; }
    pgrep() { printf '%s\n' "$*" >> "$PGREP_ARGV_LOG"; return 0; }
    export -f ps pgrep
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=pane"* ]]
    grep -q -- '-g 4242' "$PGREP_ARGV_LOG"
    grep -q -- '-x claude' "$PGREP_ARGV_LOG"
}

# =============================================================================
# jsonl source（fallback / direct）
# =============================================================================

@test "jsonl fallback: pane 不成立時に pane-map 経由で sid 解決し usage 和を返す" {
    printf '❯ \n' > "$TMPD/capture.txt"
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [ "$output" = "used_pct=- used_tokens=120823 window_tokens=- source=jsonl sid=aaaa-bbbb-cccc target=%7" ]
}

@test "jsonl direct: --sid 指定で pane を経由しない" {
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [ "$output" = "used_pct=- used_tokens=120823 window_tokens=- source=jsonl sid=aaaa-bbbb-cccc target=-" ]
}

@test "jsonl: sidechain の assistant message は skip し非 sidechain の最新を採る" {
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":90,"output_tokens":5}}}
{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":999999,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}
EOF
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=100"* ]]
}

@test "jsonl: usage 欠落 assistant は skip・欠落フィールドは 0 扱い" {
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":7,"cache_read_input_tokens":13}}}
{"type":"assistant","isSidechain":false,"message":{"content":"no usage here"}}
EOF
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=20"* ]]
}

@test "jsonl: 末尾 chunk が行断片でも黙って捨てて成立する（fromjson? 耐性）" {
    # 大きな padding 行の後に有効行 → tail chunk が padding 行の途中から始まる
    {
        printf '{"type":"user","message":{"content":"%s"}}\n' "$(head -c 2000 /dev/zero | tr '\0' 'x')"
        printf '{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}\n'
    } > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl"
    SESSION_METER_TAIL_BYTES=300 run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=6"* ]]
}

@test "jsonl: tail chunk 内に対象が無ければ全量走査へ fallback する" {
    # chunk（末尾 10 bytes）は最終行の断片のみ → 全量走査で最初の有効 entry を拾う
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":5}}}
{"type":"user","message":{"content":"tail はこの行の断片だけを見る"}}
EOF
    SESSION_METER_TAIL_BYTES=10 run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=10"* ]]
}

@test "jsonl: 複数 transcript 候補は mtime 最新を採る" {
    mkdir -p "$TMPD/projects2/-other-proj"
    cat > "$TMPD/projects2/-other-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":777,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
    touch -d '2020-01-01' "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl"
    SESSION_METER_PROJECT_DIRS="$TMPD/projects:$TMPD/projects2" \
        run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=777"* ]]
}

# =============================================================================
# 解決失敗・契約（exit code）
# =============================================================================

@test "exit 3: tmux target 解決失敗（session 不在・sid 無し）" {
    export TMUX_MOCK_HAS_SESSION=0
    export TMUX_MOCK_LIST_WINDOWS=""
    run "$METER" --target nosuch:admin
    [ "$status" -eq 3 ]
}

@test "exit 3: pane-map miss（fallback sid 解決不能）" {
    printf '❯ \n' > "$TMPD/capture.txt"
    printf '%%99\tother-sid\n' > "$TMPD/pane-map.tsv"
    run "$METER" --target %7
    [ "$status" -eq 3 ]
}

@test "exit 3: transcript 不在" {
    rm "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl"
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 3 ]
}

@test "exit 4: transcript に有効な assistant usage が 1 件も無い" {
    printf '{"type":"user","message":{"content":"only user"}}\n' \
        > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl"
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 4 ]
}

@test "exit 2: 引数なし" {
    run "$METER"
    [ "$status" -eq 2 ]
}

@test "exit 2: 不正な sid（path traversal 文字）を拒否する" {
    run "$METER" --sid '../../etc/passwd'
    [ "$status" -eq 2 ]
}

@test "exit 2: 不明オプション" {
    run "$METER" --bogus
    [ "$status" -eq 2 ]
}

@test "exit 2: 不正な --source 値" {
    run "$METER" --target %7 --source magic
    [ "$status" -eq 2 ]
}

@test "exit 2: --source pane は --target 必須" {
    run "$METER" --sid aaaa-bbbb-cccc --source pane
    [ "$status" -eq 2 ]
}

# =============================================================================
# 契約の細部
# =============================================================================

@test "契約: 出力は常に 1 行・固定順 key=value" {
    run "$METER" --target %7
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]
    # フィールド型を厳密 pin（[0-9-]+ の緩形は '1-2' 等の破損値を通す = R2 gate nit）
    [[ "$output" =~ ^used_pct=(-|[0-9]+)\ used_tokens=(-|[0-9]+)\ window_tokens=(-|[0-9]+)\ source=(pane|jsonl)\ sid=[A-Za-z0-9-]+\ target=[^[:space:]]+$ ]]
}

@test "契約: --target と --sid 併用時は pane 成功なら pane・sid をそのまま出力" {
    run "$METER" --target %7 --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=pane"* ]]
    [[ "$output" == *"sid=aaaa-bbbb-cccc"* ]]
}

@test "契約: --target と --sid 併用時 pane 不成立なら指定 sid で jsonl（pane-map 不要）" {
    printf '❯ \n' > "$TMPD/capture.txt"
    rm "$TMPD/pane-map.tsv"
    run "$METER" --target %7 --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=jsonl"* ]]
    [[ "$output" == *"sid=aaaa-bbbb-cccc"* ]]
}

@test "契約: bare session 名 fallback は claude が走る唯一の pane を測る（active window 基準にしない）" {
    export TMUX_MOCK_LIST_WINDOWS="sc:1 other-window"
    export TMUX_MOCK_SESSION_PANES='%7\n%9'
    export TMUX_MOCK_PANE_STATE_9='0 1 bash'
    ps() { :; }
    export -f ps
    run "$METER" --target sc
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=pane"* ]]
    # 測定した pane を出力へ明示する（bare 入力の echo にしない＝事後監査可能）
    [[ "$output" == *"target=%7"* ]]
    # 計測対象の同一性を argv で pin する（R2/R3 gate finding: -s 除去 /
    # list-panes の exact-match 除去 / 別 pane capture の 3 変異を RED 化する。
    # '=sc' は呼び出し境界つきで list-panes 側に限定して見る＝has-session 側の
    # '=sc' で偽 green にならない）
    grep -qx -- '-s' "$TMPD/tmux-argv.log"
    awk '/^list-panes$/{f=1;next} f&&/^=sc$/{ok=1} /^--$/{f=0} END{exit !ok}' "$TMPD/tmux-argv.log"
    awk '/^capture-pane$/{f=1;next} f&&/^%7$/{found=1} /^--$/{f=0} END{exit !found}' "$TMPD/tmux-argv.log"
}

@test "契約: bare session の claude 判定は pgid 経路も拾う（cld-spawn の wrapper bash pane）" {
    export TMUX_MOCK_LIST_WINDOWS="sc:1 other-window"
    export TMUX_MOCK_SESSION_PANES='%7'
    export TMUX_MOCK_PANE_STATE_7='0 4242 bash'
    ps() {
        case "$*" in
            *pgid*) echo ' 4242' ;;
            *comm*) printf 'claude\n' ;;
        esac
    }
    pgrep() { echo 4242; }
    export -f ps pgrep
    run "$METER" --target sc
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=pane"* ]]
    [[ "$output" == *"target=%7"* ]]
}

@test "契約: bare session 名は claude pane 複数で exit 3（曖昧・どれを測るか推測しない）" {
    export TMUX_MOCK_LIST_WINDOWS="sc:1 other-window"
    export TMUX_MOCK_SESSION_PANES='%7\n%9'
    run "$METER" --target sc
    [ "$status" -eq 3 ]
}

@test "契約: bare session 名は claude pane 0 件で exit 3（stale 画面を掴まない）" {
    export TMUX_MOCK_LIST_WINDOWS="sc:1 other-window"
    export TMUX_MOCK_SESSION_PANES='%7'
    export TMUX_MOCK_PANE_STATE_7='0 1 bash'
    ps() { :; }
    export -f ps
    run "$METER" --target sc
    [ "$status" -eq 3 ]
}

@test "契約: bare session 曖昧（claude pane 複数）でも --sid 併用なら jsonl へ落ちる" {
    export TMUX_MOCK_LIST_WINDOWS="sc:1 other-window"
    export TMUX_MOCK_SESSION_PANES='%7\n%9'
    run "$METER" --target sc --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=jsonl"* ]]
    [[ "$output" == *"sid=aaaa-bbbb-cccc"* ]]
}

@test "jsonl: 末尾の usage 全 0 entry（synthetic API error）は skip し直近の非 0 を採る" {
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":2,"cache_creation_input_tokens":8,"cache_read_input_tokens":190000,"output_tokens":50}}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
EOF
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=190010"* ]]
}

@test "jsonl: 全 entry が usage 0 なら exit 4（捏造 0 を出さない）" {
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}}}
EOF
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 4 ]
}

@test "jsonl: 複数有効 entry は最後（最新）を採る — 末尾に sidechain/全 0 が居ても順序不変" {
    # 順序意味論の pin（R2 gate finding: tail→head 変異が全 green で生存した）。
    # 有効 entry 2 件（100 → 250000）+ 末尾に sidechain と全 0 の decoy。
    cat > "$TMPD/projects/-home-test-proj/aaaa-bbbb-cccc.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":100,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":50000,"cache_creation_input_tokens":0,"cache_read_input_tokens":200000}}}
{"type":"assistant","isSidechain":true,"message":{"usage":{"input_tokens":999999,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
    run "$METER" --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=250000"* ]]
}

@test "exit 3: pane-map の不正形 sid（path traversal）を拒否する" {
    printf '❯ \n' > "$TMPD/capture.txt"
    printf '%%7\t../../evil\n' > "$TMPD/pane-map.tsv"
    # traversal の脱出先に「読めてしまう」transcript を実在させる＝検証を外すと
    # exit 0 + 777777 を返してしまう構図にして、検証削除の退行を観測可能にする
    cat > "$TMPD/evil.jsonl" <<'EOF'
{"type":"assistant","isSidechain":false,"message":{"usage":{"input_tokens":777777,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
    run "$METER" --target %7
    [ "$status" -eq 3 ]
    [[ "$output" != *"777777"* ]]
}

@test "契約: --source jsonl は statusline があっても pane を測らない" {
    run "$METER" --target %7 --source jsonl
    [ "$status" -eq 0 ]
    [[ "$output" == *"source=jsonl"* ]]
    [[ "$output" == *"used_tokens=120823"* ]]
}

@test "契約: 空白入り target 文字列は emit で無害化される（偽 key=value 注入不能）" {
    printf '❯ \n' > "$TMPD/capture.txt"
    export TMUX_MOCK_HAS_SESSION=0
    run "$METER" --target 'nosuchwin used_pct=99 used_tokens=999999' --sid aaaa-bbbb-cccc
    [ "$status" -eq 0 ]
    [[ "$output" == *"used_tokens=120823"* ]]
    [[ "$output" != *"used_pct=99"* ]]
    [[ "$output" != *"used_tokens=999999"* ]]
}

@test "exit 2: --source に値が無い（set -e の shift 落ちで契約外 exit 1 にしない）" {
    run "$METER" --target %7 --source
    [ "$status" -eq 2 ]
}

@test "契約: usage/診断は stderr のみ・stdout は成功時 1 行専用" {
    # usage error 経路（exit 2）
    [ -z "$("$METER" 2>/dev/null || true)" ]
    [ -z "$("$METER" --target %7 --source 2>/dev/null || true)" ]
    [ -z "$("$METER" --bogus 2>/dev/null || true)" ]
    # 解決失敗（exit 3）・計測不能（exit 4）経路も stdout 純度を pin（R2 gate finding）
    [ -z "$("$METER" --target nosuch:x 2>/dev/null || true)" ]
    printf '❯ \n' > "$TMPD/capture.txt"
    [ -z "$("$METER" --target %7 --source pane 2>/dev/null || true)" ]
    # bare session ambiguous（claude pane 複数 → exit 3）経路も pin（R3 gate finding）
    export TMUX_MOCK_LIST_WINDOWS="sc:1 other-window"
    export TMUX_MOCK_SESSION_PANES='%7\n%9'
    [ -z "$("$METER" --target sc 2>/dev/null || true)" ]
}

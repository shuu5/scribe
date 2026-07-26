#!/usr/bin/env bats
# cld-memory-max.bats - cld の cgroup メモリ上限（MemoryMax）決定ロジックの unit tests
#
# 背景（bd sc-von0）: 固定既定 12G は host 非依存に破綻する（潤沢な host では低すぎて dynamic
# workflow が焼き切り cgroup OOM killer が CC ごと SIGKILL、小さな host では上限が実 RAM を超えて
# 防壁にならない）。既定を MemTotal 比例（pct・floor・ceil）へ変えたため、その導出を pin する。
#
# Scenarios covered:
#   - CLD_MEMORY_MAX 明示が最優先（後方互換）
#   - 未指定時は MemTotal x pct（既定 20%）から導出
#   - CLD_MEMORY_MAX_PCT で割合を上書きできる
#   - floor（小 host）/ ceil（巨大 host）でクランプされる
#   - MemTotal を読めないときは fallback 12G（launcher は止めない）
#   - 不正な pct は die でなく既定へ倒す（不変条件: 何であれ claude の起動を妨げない）
#   - 実効値の可視化（stderr 1 行 / --description）と CLD_MEMORY_QUIET による抑制
#   - systemd-run 不在時は上限なしで直接起動（回帰）＋その旨を可視化
#   - --description は feature-detect（古い systemd で落ちない）
#
# スタブ方針:
#   - claude stub が受け取った引数を出力する（既存 cld-plugin-exclude.bats と同流儀）
#   - systemd-run stub は自身の引数を 'SDRUN_ARG:<arg>' 行として吐いてから claude 以降を exec する
#     （既存 stub は -p の値を捨てるため、上限値を検証できるよう別 stub を使う）
#   - MemTotal は CLD_MEMINFO_FILE seam でテスト用ファイルへ差し替える（実 host に依存しない）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD="$SCRIPT_DIR/cld"

setup() {
    SANDBOX="$(mktemp -d)"
    FAKE_BIN="$SANDBOX/bin"
    mkdir -p "$FAKE_BIN"

    cat > "$FAKE_BIN/claude" <<'CLAUDE_STUB'
#!/bin/bash
printf 'CLAUDE_ARG:%s\n' "$@"
CLAUDE_STUB
    chmod +x "$FAKE_BIN/claude"

    # systemd-run stub: --help に --description を出す（feature-detect が true になる既定）。
    # 通常起動では自身の引数を 1 行 1 引数で吐き、最初の 'claude' 以降を exec する。
    cat > "$FAKE_BIN/systemd-run" <<'SDRUN_STUB'
#!/bin/bash
if [[ "${1:-}" == "--help" ]]; then
    echo "     --description=TEXT           Description for unit"
    exit 0
fi
printf 'SDRUN_ARG:%s\n' "$@"
while [[ $# -gt 0 && "$1" != claude ]]; do shift; done
exec "$@"
SDRUN_STUB
    chmod +x "$FAKE_BIN/systemd-run"

    # plugin 検出は本テストの関心外（空の plugins ディレクトリで無害化）
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/.claude/plugins"

    export PATH="$FAKE_BIN:$PATH"

    # MemTotal 差し替え seam の既定 = 125GiB 相当（実 host ipatho-server-2 と同オーダー）
    MEMINFO_125G="$SANDBOX/meminfo-125g"
    cat > "$MEMINFO_125G" <<'EOF'
MemTotal:       131707548 kB
MemFree:        14000000 kB
MemAvailable:  114100480 kB
EOF

    unset CLD_MEMORY_MAX CLD_MEMORY_MAX_PCT CLD_MEMORY_QUIET CLD_PLUGIN_EXCLUDE || true
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
}

# _mk_meminfo <MemTotal_kB>: 指定 MemTotal を持つ meminfo ファイルを作りパスを返す
_mk_meminfo() {
    local kb="$1" f="$SANDBOX/meminfo-$1"
    printf 'MemTotal:       %s kB\nMemFree:        1024 kB\n' "$kb" > "$f"
    printf '%s' "$f"
}

# _memmax: 直前の run 出力から systemd-run へ渡された MemoryMax 値を取り出す
_memmax() {
    sed -n 's/^SDRUN_ARG:MemoryMax=//p' <<< "$output"
}

@test "memmax: CLD_MEMORY_MAX 明示が最優先（後方互換）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=7G bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "7G" ]
    [[ "$output" == *"CLD_MEMORY_MAX 明示"* ]]
}

@test "memmax: 明示指定は pct 指定より優先される" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=3G CLD_MEMORY_MAX_PCT=50 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "3G" ]
}

@test "memmax: 未指定なら MemTotal x 既定 20%（125GiB → 25G）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
}

@test "memmax: CLD_MEMORY_MAX_PCT で割合を上書きできる（100GiB x 10% → 10G）" {
    local mi
    mi="$(_mk_meminfo 104857600)"
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX_PCT=10 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "10G" ]
}

@test "memmax: 小さな host では floor 4G でクランプされる（8GiB x 20% = 1.6G → 4G）" {
    local mi
    mi="$(_mk_meminfo 8388608)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "4G" ]
}

@test "memmax: 巨大 host では ceil 32G でクランプされる（500GiB x 20% = 100G → 32G）" {
    local mi
    mi="$(_mk_meminfo 524288000)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "32G" ]
}

@test "memmax: MemTotal を読めなければ fallback 12G（launcher は止めない）" {
    run env CLD_MEMINFO_FILE="$SANDBOX/does-not-exist" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
    [[ "$output" == *"fallback"* ]]
    [[ "$output" == *"CLAUDE_ARG:--dangerously-skip-permissions"* ]]
}

@test "memmax: MemTotal 行の無い meminfo でも fallback 12G へ倒れる" {
    local mi="$SANDBOX/meminfo-broken"
    printf 'MemFree:        1024 kB\n' > "$mi"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
}

@test "memmax: 非数値の pct は warn して既定 20% へ倒れる（die しない）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX_PCT=abc bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"CLD_MEMORY_MAX_PCT"* ]]
}

@test "memmax: 100 超の pct は warn して既定 20% へ倒れる" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX_PCT=400 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"CLD_MEMORY_MAX_PCT"* ]]
}

@test "memmax: pct=0 も warn して既定 20% へ倒れる（0 上限で即 OOM を防ぐ）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX_PCT=0 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
}

@test "memmax: pct=100 は受理される（境界・warn しない）" {
    local mi
    mi="$(_mk_meminfo 20971520)"   # 20GiB
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX_PCT=100 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "20G" ]
    [[ "$output" != *"CLD_MEMORY_MAX_PCT"* ]]
}

@test "memmax: meminfo が FIFO でも launcher が hang/abort しない（正規ファイル限定の pin）" {
    local mi="$SANDBOX/meminfo-fifo"
    mkfifo "$mi"
    run timeout 5 env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
}

@test "memmax: 実効値が stderr 1 行で可視化される" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cld: MemoryMax=25G"* ]]
}

@test "memmax: CLD_MEMORY_QUIET=1 で可視化行が抑制される（上限自体は変わらない）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_QUIET=1 bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" != *"cld: MemoryMax="* ]]
    [ "$(_memmax)" = "25G" ]
}

@test "memmax: --description に実効値と出所が焼かれる（起動後も systemctl show で読める）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SDRUN_ARG:--description=cld claude session (MemoryMax=25G src=auto-pct20)"* ]]
}

@test "memmax: --description を持たない systemd では付与しない（feature-detect）" {
    cat > "$FAKE_BIN/systemd-run" <<'SDRUN_OLD'
#!/bin/bash
if [[ "${1:-}" == "--help" ]]; then
    echo "  --user   Run as user unit"
    exit 0
fi
printf 'SDRUN_ARG:%s\n' "$@"
while [[ $# -gt 0 && "$1" != claude ]]; do shift; done
exec "$@"
SDRUN_OLD
    chmod +x "$FAKE_BIN/systemd-run"
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" != *"--description"* ]]
    [ "$(_memmax)" = "25G" ]
}

@test "memmax: systemd-run 不在なら上限なしで直接起動し、その旨を可視化する（回帰）" {
    # 実 host の /usr/bin/systemd-run を PATH から締め出すため、必要最小のコマンドだけを
    # symlink した専用 bin を組んで PATH をそれだけにする（stub 削除だけでは実物に解決される）。
    local nosd="$SANDBOX/nosd-bin" c p
    mkdir -p "$nosd"
    cp "$FAKE_BIN/claude" "$nosd/claude"
    for c in bash awk grep sed cat printf env; do
        p="$(command -v "$c" || true)"
        [[ -n "$p" ]] && ln -sf "$p" "$nosd/$c"
    done
    run env PATH="$nosd" CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" != *"SDRUN_ARG:"* ]]
    [[ "$output" == *"CLAUDE_ARG:--dangerously-skip-permissions"* ]]
    [[ "$output" == *"メモリ上限なし"* ]]
}

@test "memmax: 追加引数は従来どおり claude へ透過する（回帰）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD" --model opus --resume
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE_ARG:--model"* ]]
    [[ "$output" == *"CLAUDE_ARG:opus"* ]]
    [[ "$output" == *"CLAUDE_ARG:--resume"* ]]
}

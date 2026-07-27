#!/usr/bin/env bats
# cld-memory-max.bats - cld の cgroup メモリ上限（MemoryMax）決定ロジックの unit tests
#
# 背景（bd sc-von0）: 固定既定 12G は host 非依存に破綻する（潤沢な host では低すぎて dynamic
# workflow が焼き切り cgroup OOM killer が CC ごと SIGKILL、小さな host では上限が実 RAM を超えて
# 防壁にならない）。既定を MemTotal 比例（pct・floor・ceil）へ変えたため、その導出を pin する。
#
# Scenarios covered:
#   - CLD_MEMORY_MAX 明示が最優先（後方互換）／1GiB 未満・形式不明は warn して自動導出へ倒す
#   - 明示値の受理集合は systemd に揃える（小文字単位は大文字へ正規化・100% 超は自動導出へ倒す）
#     ＝素通しすると systemd-run が property parse error で落ち claude が一切起動しないため
#   - 未指定時は MemTotal x pct（既定 20%）から導出
#   - CLD_MEMORY_MAX_PCT で割合を上書きできる
#   - 下限 min(12G, MemTotal の 50%) と 上限 32G でクランプされる（中間帯 host の退行防止と
#     「上限が実 RAM に迫って防壁が bind しない」の同時回避）
#   - MemTotal を読めないときは fallback 12G（launcher は止めない）
#   - 不正な pct は die でなく既定へ倒す（不変条件: 何であれ claude の起動を妨げない）
#   - 実効値の可視化（stderr 1 行 / --description）と CLD_MEMORY_QUIET（真偽値解釈）による抑制
#   - 上限なし警告は QUIET でも抑制されない（保護不在の隠蔽を防ぐ）
#   - stderr が書込不可でも launcher は claude 起動を妨げない
#   - 既定 seam（/proc/meminfo）を踏む経路が壊れていない（seam 名 typo の silent fallback 検知）
#   - systemd-run 不在時は上限なしで直接起動（回帰）＋その旨を可視化
#   - --description は feature-detect（古い systemd で落ちない）＋ session 識別子を含む
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

@test "memmax: 上限は -p の直後に渡る（値だけ見る _memmax の盲点を塞ぐ）" {
    # _memmax は 'SDRUN_ARG:MemoryMax=' 行を拾うだけなので `-p` 脱落を検出できない。
    # systemd-run は `-p KEY=VALUE` の形でしか property を受けないため隣接まで pin する。
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *$'SDRUN_ARG:-p\nSDRUN_ARG:MemoryMax='* ]]
    [[ "$output" == *"SDRUN_ARG:--user"* ]]
    [[ "$output" == *"SDRUN_ARG:--scope"* ]]
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

@test "memmax: CLD_MEMORY_MAX_PCT で割合を上書きできる（100GiB x 30% → 30G）" {
    local mi
    mi="$(_mk_meminfo 104857600)"
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX_PCT=30 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "30G" ]
}

@test "memmax: pct を下げても下限は割らない（100GiB x 1% = 1G → 12G）" {
    local mi
    mi="$(_mk_meminfo 104857600)"
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX_PCT=1 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
}

@test "memmax: 中間帯 host は下限 12G で旧既定より弱くならない（32GiB x 20% = 6G → 12G）" {
    local mi
    mi="$(_mk_meminfo 33554432)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
}

@test "memmax: 60GiB は比例値と下限が一致する境界（20% = 12G）" {
    local mi
    mi="$(_mk_meminfo 62914560)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
}

@test "memmax: 下限は MemTotal の 50% を超えない（16GiB → 12G でなく 8G）" {
    local mi
    mi="$(_mk_meminfo 16777216)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    # 絶対 floor 12G は実 RAM の 75% で防壁として bind しないため 50% クランプが勝つ
    [ "$(_memmax)" = "8G" ]
}

@test "memmax: 小さな host では下限も MemTotal 連動（8GiB x 20% = 1.6G → 4G）" {
    local mi
    mi="$(_mk_meminfo 8388608)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "4G" ]
}

@test "memmax: 極小 host でも上限は実 RAM 未満に留まる（4GiB → 2G ＝ 防壁が bind する）" {
    local mi
    mi="$(_mk_meminfo 4194304)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "2G" ]
}

@test "memmax: 1GiB host でも 0G にはならない（MIN 1G）" {
    local mi
    mi="$(_mk_meminfo 1048576)"
    run env CLD_MEMINFO_FILE="$mi" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "1G" ]
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

@test "memmax: 単位なしの明示値（25＝25G の打ち間違い）は warn して自動導出へ倒れる" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=25 bash "$CLD"
    [ "$status" -eq 0 ]
    # 25 バイト上限で起動直後に OOM kill されるのを防ぐ
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"1GiB 未満"* ]]
}

@test "memmax: 1GiB 未満の単位付き明示値（512M）も自動導出へ倒れる" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=512M bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
}

@test "memmax: 解釈できない明示値は warn して自動導出へ倒れる（launcher は落ちない）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX="25 GB" bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"解釈できない形式"* ]]
}

@test "memmax: 割合形式の明示値（20%）はそのまま systemd へ渡る" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=20% bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "20%" ]
}

@test "memmax: 割合形式の境界 100% は受理される" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=100% bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "100%" ]
}

@test "memmax: 100% 超の明示割合（150%）は warn して自動導出へ倒れる" {
    # systemd は 100% 超を受理しない＝素通しすると systemd-run が落ちて claude が起動しない
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=150% bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"100% を超えます"* ]]
}

@test "memmax: 200%（20% の打ち間違い）も自動導出へ倒れる＝防壁が外れない" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=200% bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"100% を超えます"* ]]
}

@test "memmax: 小文字単位の明示値（8g）は systemd 受理形（8G）へ正規化される" {
    # systemd の接尾辞は大小文字を区別する。素通しすると property parse error で claude が起動しない
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=8g bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "8G" ]
}

@test "memmax: 小文字 t/m も正規化される（1t → 1T ／ 2048m → 2048M）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=1t bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "1T" ]
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=2048m bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "2048M" ]
}

@test "memmax: 小文字でも 1GiB 未満（512m）は従来どおり自動導出へ倒れる" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=512m bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"1GiB 未満"* ]]
}

@test "memmax: 実 RAM 以上の明示値は受理するが「防壁が bind しない」と警告する" {
    # 明示値は下限/上限クランプを迂回する＝自動導出側の 50% クランプが効かない。実 RAM 以上を
    # 指定すると「上限があるのに無いのと同じ」状態が silent に出来上がるので loud に警告する。
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=200G bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "200G" ]        # 受理する（escape hatch は殺さない）
    [[ "$output" == *"bind しません"* ]]
    [[ "$output" == *"MemTotal 125GiB"* ]]
}

@test "memmax: 境界 — 実 RAM ちょうどは警告し、1G 下は警告しない" {
    local mi
    mi="$(_mk_meminfo 8388608)"      # ちょうど 8GiB
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX=8G bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "8G" ]
    [[ "$output" == *"bind しません"* ]]
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX=7G bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "7G" ]
    [[ "$output" != *"bind しません"* ]]
}

@test "memmax: 100%（= MemTotal）も「bind しない」警告の対象（受理は据え置き）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=100% bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "100%" ]
    [[ "$output" == *"bind しません"* ]]
}

@test "memmax: 「bind しない」警告は CLD_MEMORY_QUIET でも抑制されない（保護不在を隠蔽しない）" {
    # QUIET は可視化行だけの抑制設定。上限なし警告と同じ扱いで、保護が効いていない事実は必ず出す。
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_QUIET=1 CLD_MEMORY_MAX=200G bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bind しません"* ]]
    [[ "$output" != *"cld: MemoryMax="* ]]   # 可視化行の方は抑制されている
}

@test "memmax: MemTotal を読めなければ bind 判定はせず明示値をそのまま通す（誤警告を出さない）" {
    run env CLD_MEMINFO_FILE="$SANDBOX/does-not-exist" CLD_MEMORY_MAX=200G bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "200G" ]
    [[ "$output" != *"bind しません"* ]]
}

@test "memmax: 64bit 桁溢れの明示値は warn して自動導出へ倒れる（wrap で検証を素通りさせない）" {
    # bash の算術は 64bit signed で黙って wrap するため、桁数と符号の 2 面で弾く必要がある
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=99999999999999999999G bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "25G" ]
    [[ "$output" == *"桁が大きすぎて"* ]]
}

@test "memmax: CLD_MEMORY_QUIET の真値は 1 以外（true/yes/on）も受理される" {
    local w
    for w in true yes on; do
        run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_QUIET="$w" bash "$CLD"
        [ "$status" -eq 0 ]
        [[ "$output" != *"cld: MemoryMax="* ]]
        [ "$(_memmax)" = "25G" ]
    done
}

@test "memmax: 32GiB host は pct=1 でも下限 12G（doc の pct 引き下げ指針は下限に飲まれる）" {
    # protocol.md の fleet 総量 bullet が「pct は下限より下へは下がらない」と書いている根拠の pin
    local mi
    mi="$(_mk_meminfo 33554432)"
    run env CLD_MEMINFO_FILE="$mi" CLD_MEMORY_MAX_PCT=1 bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "12G" ]
}

@test "memmax: infinity は受理するが防壁撤廃として loud に警告する" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_MAX=infinity bash "$CLD"
    [ "$status" -eq 0 ]
    [ "$(_memmax)" = "infinity" ]
    [[ "$output" == *"防壁の撤廃"* ]]
}

@test "memmax: 既定 seam（/proc/meminfo）を踏む経路が壊れていない（seam typo の silent fallback 検知）" {
    [[ -r /proc/meminfo ]] || skip "/proc/meminfo が読めない環境"
    run env -u CLD_MEMINFO_FILE bash "$CLD"
    [ "$status" -eq 0 ]
    # 値は host 依存なので「auto 導出であって fallback でない」ことだけを assert する
    [[ "$output" == *"auto: MemTotal"* ]]
    [[ "$output" != *"fallback"* ]]
    [[ "$output" != *"src=/"* ]]
}

@test "memmax: seam 使用時は可視化行に出所（src=<path>）が出る" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"src=$MEMINFO_125G"* ]]
}

@test "memmax: stderr が書込不可でも launcher は claude 起動を妨げない" {
    # `run ... 2>&-` では bats が run の内側で fd2 を張り直すため閉じた stderr を再現できない
    # （空虚なテストになる）。子プロセスの中で閉じてから exec することで実際に EBADF 経路を踏む。
    run bash -c 'exec 2>&-; exec env CLD_MEMINFO_FILE="$1" bash "$2"' _ "$MEMINFO_125G" "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE_ARG:--dangerously-skip-permissions"* ]]
}

@test "memmax: stderr が ENOSPC（/dev/full）でも launcher は claude 起動を妨げない" {
    # 書込が失敗する（閉じてはいない）経路。set -e 下で echo の失敗が abort を招かないことの pin
    run bash -c 'exec 2>/dev/full; exec env CLD_MEMINFO_FILE="$1" bash "$2"' _ "$MEMINFO_125G" "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE_ARG:--dangerously-skip-permissions"* ]]
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

@test "memmax: CLD_MEMORY_QUIET=0 は抑制しない（真偽値解釈・非空即沈黙の footgun 回避）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_QUIET=0 bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"cld: MemoryMax=25G"* ]]
}

@test "memmax: --description に実効値・出所・session 識別子が焼かれる（post-mortem 同定用）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"SDRUN_ARG:--description=cld claude "* ]]
    [[ "$output" == *"(MemoryMax=25G src=auto-pct20)"* ]]
}

@test "memmax: --description に tmux pane 識別子が混ざる（同時稼働 session の弁別）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" TMUX_PANE="%42" bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"%42 (MemoryMax=25G src=auto-pct20)"* ]]
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

@test "memmax: 上限なし警告は CLD_MEMORY_QUIET でも抑制されない（保護不在を隠蔽しない）" {
    local nosd="$SANDBOX/nosd-bin2" c p
    mkdir -p "$nosd"
    cp "$FAKE_BIN/claude" "$nosd/claude"
    for c in bash awk grep sed cat printf env; do
        p="$(command -v "$c" || true)"
        [[ -n "$p" ]] && ln -sf "$p" "$nosd/$c"
    done
    run env PATH="$nosd" CLD_MEMINFO_FILE="$MEMINFO_125G" CLD_MEMORY_QUIET=1 bash "$CLD"
    [ "$status" -eq 0 ]
    [[ "$output" == *"メモリ上限なし"* ]]
}

@test "memmax: 追加引数は従来どおり claude へ透過する（回帰）" {
    run env CLD_MEMINFO_FILE="$MEMINFO_125G" bash "$CLD" --model opus --resume
    [ "$status" -eq 0 ]
    [[ "$output" == *"CLAUDE_ARG:--model"* ]]
    [[ "$output" == *"CLAUDE_ARG:opus"* ]]
    [[ "$output" == *"CLAUDE_ARG:--resume"* ]]
}

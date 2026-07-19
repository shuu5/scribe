#!/usr/bin/env bats
# tests/scenarios/orch-delivery-observe.bats
#
# 配送観測ロジック本体（scripts/orch-delivery-observe.sh・bd orch-4js9・fence2）の hermetic bats。
# session-start-workinprogress.bats は第4節の **wire**（出る/fail-open/consult で消える）を sentinel stub で
# 見るだけ（推論・呼び鈴ロジックを sentinel echo に代替させない）。実ロジックの teeth は本 file が担う:
#   acceptance(2) 呼び鈴点灯 / acceptance(3) false-positive を **producer 本体**で陽性 assert し、
#   境界比較の反転・unknown→delivered default を **mutation 非空虚**（潰すと RED）で pin する（fence2/fence3）。
#
# 方式（hermetic・実 bd/tmux 非依存）:
#   - bd stub: `list --json` で固定 fixture を返す（引数記録＝--limit 0 截断禁止 teeth）。
#   - tmux stub: `list-panes -F <fmt>` で $TMUX_WINDOWS_FILE を format 尊重で返す（liveness lib と同契約）。
#   - now-epoch を env で固定して age/滞留判定を決定的にする。
#
# 検証する不変条件（SSOT = orch-4js9 fence1〜fence8 + acceptance(1)〜(3)）:
#   (A/B/C) 推論配送 3 値: 境界前→delivered / 境界後→undelivered(滞留) / 境界不能→unknown（fence3）。
#   (bell)  acceptance(2): 滞留超 ∧ 宛先窓 <X>:admin live 完全一致 → 呼び鈴提案が点灯（fence1）。
#   (degrade) fence1 縮退: フル名 session のみ live・prefix 不一致 → 呼び鈴出さず滞留 age は surface。
#   (fp)    acceptance(3) errata: undelivered/unknown を配送済みと表示しない（unknown≠delivered 不変条件）。
#   (mut1)  mutation: 境界比較 `<` を反転すると DLV/STL の分類が入れ替わる＝比較が load-bearing（潰すと RED）。
#   (mut2)  mutation: unknown 分岐を delivered へ潰すと UNK が delivered 化する＝unknown≠delivered が load-bearing。
#   (fence6) auto-compact marker read: 完全一致 label surface / 0 件は graceful。
#   (fence8) proposal-only: 呼び鈴点灯経路で push 実行系 sentinel 全不在 + runtime 本体の静的 grep clean。
#   (trunc) fence3: bd list に --limit 0（default-30 截断禁止）。
#   (scope) self-scope gate: foreign→refuse 非0 / orch→通過。
#   (self)  本体 --self-test green（durable coverage pin）。
#   (syntax) bash -n。
#
# 実行: bats tests/scenarios/orch-delivery-observe.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-delivery-observe.sh"
    TEST_TMPDIR="$(mktemp -d -t delivery-bats-XXXXXX)"
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"

    # NOW = 2026-07-13T12:00:00Z=1783944000（fixture age を決定的にする・STL=360m>閾値 / FRS=30m<閾値）。
    NOW="1783944000"

    # bd stub: list --json で 7 件 fixture を返す（引数記録付き）。
    #   sc-old   updated 2026-07-13T00:00:00Z … 宛先 sc の境界（max・foreign copy）
    #   orch-DLV for:sc created 2026-07-12T00:00:00Z … 境界前 → delivered
    #   orch-STL for:sc created 2026-07-13T06:00:00Z … 境界後・age 360m>閾値 → undelivered(滞留)・呼び鈴 point 到達
    #   orch-FRS for:sc created 2026-07-13T11:30:00Z … 境界後だが age 30m<閾値 → undelivered だが呼び鈴 point 未達（minor#3 teeth）
    #   orch-UNK for:zz created 2026-07-13T06:00:00Z … 宛先 zz は foreign copy 無し → unknown
    #   orch-CLZ for:sc status=closed … 配送済+処理済ゆえ滞留候補から除外（どの bucket にも計上しない・minor#1 teeth）
    #   orch-CMP label auto-compact-fired … marker read
    export BD_ARGS_LOG="$TEST_TMPDIR/bd-args.log"; : > "$BD_ARGS_LOG"
    cat > "$BIN/bd" <<'BDEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_LOG"
cat <<'JSON'
[
  {"id":"sc-old","title":"scribe foreign copy","labels":[],"status":"open","created_at":"2026-07-13T00:00:00Z","updated_at":"2026-07-13T00:00:00Z"},
  {"id":"orch-DLV","title":"delivered bin","labels":["for:sc"],"status":"open","created_at":"2026-07-12T00:00:00Z","updated_at":"2026-07-12T00:00:00Z"},
  {"id":"orch-STL","title":"stalled bin","labels":["for:sc"],"status":"open","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"},
  {"id":"orch-FRS","title":"fresh undelivered bin","labels":["for:sc"],"status":"open","created_at":"2026-07-13T11:30:00Z","updated_at":"2026-07-13T11:30:00Z"},
  {"id":"orch-UNK","title":"unknown-dest bin","labels":["for:zz"],"status":"open","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"},
  {"id":"orch-CLZ","title":"closed bin","labels":["for:sc"],"status":"closed","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"},
  {"id":"orch-CMP","title":"compact marker","labels":["auto-compact-fired"],"status":"open","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"}
]
JSON
BDEOF
    chmod +x "$BIN/bd"

    # tmux stub: list-panes -F <fmt> で $TMUX_WINDOWS_FILE を format 尊重で返す。
    export TMUX_WINDOWS_FILE="$TEST_TMPDIR/windows.txt"
    cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    fmt=""; prevf=""
    for a in "$@"; do [ "$prevf" = "-F" ] && fmt="$a"; prevf="$a"; done
    if [ -f "${TMUX_WINDOWS_FILE:-/nonexistent}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *:*) sess="${line%%:*}"; win="${line#*:}" ;; *) sess="orch"; win="$line" ;; esac
        case "$fmt" in *session_name*) printf '%s:%s\n' "$sess" "$win" ;; *) printf '%s\n' "$win" ;; esac
      done < "$TMUX_WINDOWS_FILE"
    fi
    exit 0 ;;
esac
exit 0
STUB
    chmod +x "$BIN/tmux"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# real script を env-stub 付きで起動する（self-scope は skip）。$1=窓 fixture 内容（改行区切り・末尾改行を付す）。
run_observe() {  # $1=windows-content
    printf '%s\n' "${1:-}" > "$TMUX_WINDOWS_FILE"
    run env ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$BIN/bd" ORCH_DELIVERY_TMUX="$BIN/tmux" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_STALE_MIN=60 bash "$SCRIPT"
}

# lib を symlink した sandbox に mutant copy を置いて起動する（mutation 非空虚用）。
#   $1=sed 式 $2=窓 fixture 内容 → run で mutant を実行。
run_mutant() {  # $1=sed-expr $2=windows-content
    local sb="$TEST_TMPDIR/mut-$RANDOM"; mkdir -p "$sb"
    ln -s "$REPO/scripts/lib"   "$sb/lib"
    ln -s "$REPO/scripts/hooks" "$sb/hooks"
    sed "$1" "$SCRIPT" > "$sb/orch-delivery-observe.sh"
    printf '%s\n' "${2:-}" > "$TMUX_WINDOWS_FILE"
    run env ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$BIN/bd" ORCH_DELIVERY_TMUX="$BIN/tmux" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_STALE_MIN=60 bash "$sb/orch-delivery-observe.sh"
}

# 単一 bead 行に scope した assert（bash [[ の * は改行を跨ぐため per-bead 判定は grep で 1 行に絞る）。
# bead_line <id> : $output のうち <id> を含む行を返す。
bead_line() { printf '%s\n' "$output" | grep -- "$1"; }

@test "(A/B/C) 推論配送 3 値: 境界前→delivered / 境界後→undelivered(滞留) / 境界不能→unknown（fence3）" {
    run_observe "scribe:admin"   # 窓は非一致（呼び鈴経路には入らない・3値だけ見る）
    [ "$status" -eq 0 ]
    bead_line orch-DLV | grep -q "配送済み(推論)"
    bead_line orch-STL | grep -q "滞留"
    bead_line orch-UNK | grep -q "未確認"
    # 集計: delivered=1(DLV) / undelivered=2(STL+FRS) / unknown=1(UNK)・closed(CLZ)はどの bucket にも入らない。
    [[ "$output" == *"delivered(推論)=1 undelivered(滞留)=2 unknown(未確認)=1"* ]]
}

@test "(bell) acceptance(2): 滞留超 ∧ 宛先窓 sc:admin live 完全一致 → 呼び鈴提案が点灯（fence1）" {
    run_observe "sc:admin"
    [ "$status" -eq 0 ]
    [[ "$output" == *"🔔 呼び鈴打ちますか"* ]]
    [[ "$output" == *"呼び鈴提案=1"* ]]
}

@test "(degrade) fence1 縮退: フル名 session(scribe:admin)のみ live・sc:admin 非一致 → 呼び鈴出さず滞留 age は surface" {
    run_observe "scribe:admin"
    [ "$status" -eq 0 ]
    [[ "$output" != *"🔔 呼び鈴打ちますか"* ]]           # prefix 不一致 → 呼び鈴出さない
    [[ "$output" == *"宛先窓 live 未確認"* ]]            # 縮退 note
    bead_line orch-STL | grep -q "滞留"                 # 滞留 age は抑止せず surface
    [[ "$output" == *"live未確認縮退=1"* ]]
}

@test "(fp) acceptance(3) errata: undelivered/unknown を配送済みと表示しない（unknown≠delivered 不変条件）" {
    run_observe "sc:admin"
    [ "$status" -eq 0 ]
    # STL(境界後)は滞留であって配送済みではない・UNK(境界不能)は未確認であって配送済みではない（per-bead 行 scope）。
    ! bead_line orch-STL | grep -q "配送済み"
    ! bead_line orch-UNK | grep -q "配送済み"
    # 唯一 delivered なのは境界前の DLV のみ（配送済み(推論) の陽性面）。
    bead_line orch-DLV | grep -q "配送済み(推論)"
}

@test "(mut1) mutation: 境界比較 '<' を反転すると DLV/STL の分類が入れ替わる（比較が load-bearing・潰すと RED）" {
    # 原本: DLV=delivered, STL=undelivered。`elif created < boundary:` を `>` に反転すると入れ替わる。
    grep -q 'elif created < boundary:' "$SCRIPT"        # 非vacuity: 対象行が原本に実在
    run_mutant 's/elif created < boundary:/elif created > boundary:/' "sc:admin"
    [ "$status" -eq 0 ]
    # 反転で DLV は delivered でなくなり（undelivered 化）、STL は delivered 化する＝原本と逆（per-bead 行 scope）。
    ! bead_line orch-DLV | grep -q "配送済み(推論)"
    bead_line orch-STL | grep -q "配送済み(推論)"
}

@test "(mut2) mutation: unknown 分岐を delivered へ潰すと UNK が delivered 化する（unknown≠delivered が load-bearing・潰すと RED）" {
    # python エンジンの unknown 状態を delivered へ潰す（両 unknown 分岐の代入を書換）。原本では UNK=unknown。
    grep -q 'state = "unknown"' "$SCRIPT"               # 非vacuity: 対象行が原本に実在
    run_mutant 's/state = "unknown"/state = "delivered"/g' "scribe:admin"
    [ "$status" -eq 0 ]
    # 原本では UNK は未確認だが、mutant では delivered 化する＝unknown≠delivered ガードが load-bearing（per-bead 行 scope）。
    bead_line orch-UNK | grep -q "配送済み(推論)"
}

@test "(minor1) closed 除外 + mutation: closed for:X 便は surface しない / 除外を潰すと closed が滞留計上され RED（cell-quality minor#1）" {
    # 原本: orch-CLZ(for:sc・status=closed)は滞留候補 forbeads から除外され一切 surface しない（配送済+処理済）。
    run_observe "sc:admin"
    [ "$status" -eq 0 ]
    ! printf '%s\n' "$output" | grep -q "orch-CLZ"        # closed 便は surface しない（over-surface しない）
    grep -q 'status != "closed"' "$SCRIPT"                # 非vacuity: 対象 filter が原本に実在
    # mutation: closed 除外を潰す（status!=closed → True）と CLZ が forbeads に入り滞留計上され surface される＝RED。
    run_mutant 's/status != "closed"/True/' "sc:admin"
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -q "orch-CLZ"          # mutant では closed 便が誤って surface（除外が load-bearing）
}

@test "(minor3) 呼び鈴 point 未達 + mutation: 閾値未満の undelivered は呼び鈴を出さない / 閾値 gate を潰すと誤点灯し RED（cell-quality minor#3）" {
    # 原本: FRS(undelivered ∧ age 30m<閾値 60)は sc:admin live でも呼び鈴を出さず『point 未達』surface。STL のみ点灯＝呼び鈴提案=1。
    run_observe "sc:admin"
    [ "$status" -eq 0 ]
    bead_line orch-FRS | grep -q "呼び鈴 point 未達"        # FRS は閾値未満で point 未達
    [[ "$output" == *"呼び鈴提案=1"* ]]                    # 点灯は STL のみ（FRS は加算しない）
    grep -q 'a > stale_min' "$SCRIPT"                     # 非vacuity: 閾値 gate が原本に実在
    # mutation: 閾値 gate を潰す（undelivered なら常時 stalled）と FRS も点灯し 呼び鈴提案=2 へ＝誤点灯 RED。
    run_mutant 's/state == "undelivered" and a > stale_min/state == "undelivered"/' "sc:admin"
    [ "$status" -eq 0 ]
    [[ "$output" == *"呼び鈴提案=2"* ]]                    # mutant では FRS も誤点灯（閾値 gate が load-bearing）
}

@test "(fence6) auto-compact marker read: 完全一致 label surface / 0 件は graceful" {
    run_observe "scribe:admin"
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto-compact 発火 marker: orch-CMP"* ]]
    # 別 label を指定すると 0 件 graceful。
    run env ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$BIN/bd" ORCH_DELIVERY_TMUX="$BIN/tmux" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_COMPACT_LABEL="no-such-zzz" bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"auto-compact marker: なし"* ]]
}

@test "(fence8) proposal-only: 呼び鈴点灯経路で push 実行系 sentinel 全不在 + runtime 本体の静的 grep clean" {
    # 静的: runtime run_observe 本体に push 実行系 call が無い（comment/self-test の言及と弁別・関数 scope）。
    body="$(awk '/^run_observe\(\) \{/,/^\}/' "$SCRIPT")"
    ! printf '%s' "$body" | grep -Eq 'send-keys|inject-existing|orch-relay|session-comm'
    # 挙動: 呼び鈴点灯経路で send-keys / orch-relay.sh / session-comm.sh を実際に呼ばない（sentinel 不在）。
    export SENDKEYS_SENTINEL="$TEST_TMPDIR/sk-fired"; export RELAY_SENTINEL="$TEST_TMPDIR/relay-fired"; export SESSCOMM_SENTINEL="$TEST_TMPDIR/sc-fired"
    rm -f "$SENDKEYS_SENTINEL" "$RELAY_SENTINEL" "$SESSCOMM_SENTINEL"
    cat > "$BIN/tmux-push-trap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  send-keys) : >> "$SENDKEYS_SENTINEL"; exit 0 ;;
  list-panes)
    fmt=""; prevf=""
    for a in "$@"; do [ "$prevf" = "-F" ] && fmt="$a"; prevf="$a"; done
    if [ -f "${TMUX_WINDOWS_FILE:-/nonexistent}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *:*) sess="${line%%:*}"; win="${line#*:}" ;; *) sess="orch"; win="$line" ;; esac
        case "$fmt" in *session_name*) printf '%s:%s\n' "$sess" "$win" ;; *) printf '%s\n' "$win" ;; esac
      done < "$TMUX_WINDOWS_FILE"
    fi
    exit 0 ;;
esac
exit 0
STUB
    chmod +x "$BIN/tmux-push-trap"
    printf '#!/usr/bin/env bash\n: >> "$RELAY_SENTINEL"\nexit 0\n'    > "$BIN/orch-relay.sh"
    printf '#!/usr/bin/env bash\n: >> "$SESSCOMM_SENTINEL"\nexit 0\n' > "$BIN/session-comm.sh"
    chmod +x "$BIN/orch-relay.sh" "$BIN/session-comm.sh"
    printf 'sc:admin\n' > "$TMUX_WINDOWS_FILE"
    run env PATH="$BIN:$PATH" ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$BIN/bd" \
        ORCH_DELIVERY_TMUX="$BIN/tmux-push-trap" ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_STALE_MIN=60 bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"🔔 呼び鈴打ちますか"* ]]          # 提案テキストは存在
    [ ! -e "$SENDKEYS_SENTINEL" ]                       # push 実行系は一切呼ばれていない
    [ ! -e "$RELAY_SENTINEL" ]
    [ ! -e "$SESSCOMM_SENTINEL" ]
}

@test "(trunc) fence3: bd list に --limit 0（default-30 截断禁止）" {
    run_observe "scribe:admin"
    [ "$status" -eq 0 ]
    grep -qF -- "--limit 0" "$BD_ARGS_LOG"
}

@test "(scope) self-scope gate: foreign→refuse 非0 / orch→通過" {
    mkdir -p "$TEST_TMPDIR/foreign/.beads"; printf '{"dolt_database":"un"}' > "$TEST_TMPDIR/foreign/.beads/metadata.json"
    printf 'sc:admin\n' > "$TMUX_WINDOWS_FILE"
    run bash -c "cd '$TEST_TMPDIR/foreign' && ORCH_DELIVERY_BD='$BIN/bd' ORCH_DELIVERY_TMUX='$BIN/tmux' bash '$SCRIPT'"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    # orch 台帳 cwd → gate 通過し observe が走る。
    mkdir -p "$TEST_TMPDIR/orch/.beads"; printf '{"dolt_database":"orch"}' > "$TEST_TMPDIR/orch/.beads/metadata.json"
    run bash -c "cd '$TEST_TMPDIR/orch' && ORCH_DELIVERY_BD='$BIN/bd' ORCH_DELIVERY_TMUX='$BIN/tmux' ORCH_DELIVERY_NOW_EPOCH='$NOW' bash '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"集計:"* ]]
    [[ "$output" != *"refusing to run"* ]]
}

@test "(fail-open) bd list 失敗 → 配送観測不能 note + exit0（surface は fail-open）" {
    printf '#!/usr/bin/env bash\nexit 7\n' > "$BIN/bd-fail"; chmod +x "$BIN/bd-fail"
    printf 'sc:admin\n' > "$TMUX_WINDOWS_FILE"
    run env ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$BIN/bd-fail" ORCH_DELIVERY_TMUX="$BIN/tmux" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" bash "$SCRIPT"
    [ "$status" -eq 0 ]                                 # fail-open（surface 機能）
    [[ "$output" == *"配送観測不能"* ]]
}

@test "(self) 本体 --self-test が green（durable coverage pin・fail-closed）" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(syntax) bash -n が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

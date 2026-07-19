#!/usr/bin/env bats
# tests/scenarios/orch-hydrate-universal-pull.bats
#
# orch-hydrate.sh の pre-sync universal pull（orch-ctzr・裁定 orch-rafl 論点3）の hermetic control-flow 回帰。
# remote-fed clone（cdr 等）の local dolt を人手なしで freshen する pre-sync 段を、sync の前に独立して回し、
# ( cd <repo> && bdw dolt pull )（subshell cd 形・load-bearing）で pull → bdw auto-export で mirror 追随 →
# 後段 bdw repo sync が fresh mirror を hydrate、の chain を制御フロー面で pin する。
#
# 方式（hermetic・実 dolt/bd/bdw/network を一切呼ばない）:
#   - self-scope 用 fake orch 台帳（dolt_database=orch）の cwd から**実 script**を EXEC/DRY-RUN で起動。
#   - bdw は ORCH_HYDRATE_BDW で **CWD 記録 stub**（$PWD<TAB>$* を BDW_LOG へ append）へ差し替える。stub は
#     `dolt pull` の rc/出力を CWD の .beads/PULL_MODE（ok|remoteless|transient|conflict）で切替＝pull 分類を
#     fixture で完全制御。`repo add|sync` は exit 0。**stub の $PWD 記録**が「bdw -C でなく subshell cd 形」の tooth。
#   - bd は ORCH_HYDRATE_BD で no-op stub（STALE-CHECK を有効 issue 0 件 fail-open へ倒し pull 検証に集中）。
#   - throttle 現在時刻は ORCH_HYDRATE_NOW で決定論注入・marker dir は ORCH_HYDRATE_PULL_MARKER_DIR で temp 化。
#
# 検証する契約不変条件（orch-ctzr acceptance / DISPATCH SCOPE-FENCE）:
#   (enumerate)    --dry-run が有効 .beads repo を全列挙し不在/非.beads を対象外にする（universal・no-flag）
#   (cd-form)      pull は ( cd <repo> && bdw dolt pull )＝stub 記録 CWD==repo ∧ bdw 引数に `-C` 非出現
#                  （bdw -C 形なら flock 鍵/auto-export root が orch に落ち silent false-green＝load-bearing tooth）
#   (order)        pull は add/sync の**前**（BDW_LOG で dolt pull 行が repo add/sync 行より先）
#   (remoteless)   remote-less（"Requires a Dolt remote"）→ benign-skip・非fatal・exit0・remote-less 計上
#   (transient)    network/transient 失敗 → pull_warn 計上・failures 非算入・exit0（次cycle回収・stamp せず）
#   (conflict)     genuine merge-conflict → loud 警告 + pull_warn・非fatal・exit0
#   (all-fail-exit0) 全 pull が失敗（transient）でも orch-hydrate は exit0（cell 全滅を false-RED と誤読しない）
#   (throttle-skip) marker age < THROTTLE → pull を skip（bdw dolt pull を呼ばない）・throttled 計上
#   (throttle-stale) marker age >= THROTTLE → pull を実行（bdw dolt pull を呼ぶ）
#   (stamp-success) 成功 pull は throttle marker を stamp（settled → 次 invocation で throttle 窓）
#   (no-stamp-transient) transient 失敗は marker を stamp しない（次 invocation で retry）
#   (mutation)     cd-form/remoteless 会計の不変条件を壊すと RED（非空虚 tooth を明示）
#   (readonly-selfledger) pull marker は自台帳 marker dir 配下のみに書く（foreign repo 配下へ書かない）
#   (syntax)       bash -n が通る
#
# 実行: bats tests/scenarios/orch-hydrate-universal-pull.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-hydrate.sh"

    TEST_TMPDIR="$(mktemp -d -t orch-hydrate-upull-XXXXXX)"

    # self-scope 用 fake orch 台帳（dolt_database=orch）。この cwd から script を走らせる。
    ORCH="$TEST_TMPDIR/orch"
    mkdir -p "$ORCH/.beads"
    printf '{"dolt_database":"orch"}\n' > "$ORCH/.beads/metadata.json"

    # 空 config（未登録→add 経路→registered_total>=1→sync 到達）。
    CONFIG="$TEST_TMPDIR/config.yaml"
    : > "$CONFIG"

    MARKER="$TEST_TMPDIR/last-sync"                 # sync 鮮度マーカー（temp）
    PULL_MARKER_DIR="$TEST_TMPDIR/pull-freshness"   # pull throttle marker dir（temp・自台帳外に隔離）
    BDW_LOG="$TEST_TMPDIR/bdw-invocations.log"       # bdw の (CWD, args) 記録

    # CWD 記録 bdw stub: $PWD<TAB>$* を BDW_LOG へ。dolt pull は CWD の .beads/PULL_MODE で rc/出力を切替。
    FAKE_BDW="$TEST_TMPDIR/bdw"
    cat > "$FAKE_BDW" <<'EOF'
#!/usr/bin/env bash
printf '%s\t%s\n' "$PWD" "$*" >> "$BDW_LOG"
if [ "${1:-}" = "dolt" ] && [ "${2:-}" = "pull" ]; then
    mode="ok"
    [ -f "$PWD/.beads/PULL_MODE" ] && mode="$(cat "$PWD/.beads/PULL_MODE" 2>/dev/null)"
    case "$mode" in
        ok)          echo "Everything up-to-date."; exit 0 ;;
        remoteless)  echo "Error: Requires a Dolt remote to pull from" >&2; exit 1 ;;
        transient)   echo "fatal: unable to access remote: Network is unreachable" >&2; exit 1 ;;
        conflict)    echo "Error: merge conflict detected while merging remote" >&2; exit 1 ;;
        *)           echo "Everything up-to-date."; exit 0 ;;
    esac
fi
# repo add / repo sync / その他 → no-op success
exit 0
EOF
    chmod +x "$FAKE_BDW"

    # bd no-op stub（STALE-CHECK の bd -C export を有効0件へ倒し fail-open skip・pull 検証に集中）。
    FAKE_BD="$TEST_TMPDIR/bd"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BD"
    chmod +x "$FAKE_BD"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# fixture repo（.beads 付き）を作り path を print。第2引数があれば .beads/PULL_MODE に書く。
_mkrepo() {
    local name="$1" mode="${2:-}"
    mkdir -p "$TEST_TMPDIR/$name/.beads"
    [ -n "$mode" ] && printf '%s' "$mode" > "$TEST_TMPDIR/$name/.beads/PULL_MODE"
    printf '%s' "$TEST_TMPDIR/$name"
}

# pre-sync pull throttle marker key（本体 _pull_marker_key と同一規則: sha256(path)[:16]）。
_marker_key() { printf '%s' "$1" | sha256sum | cut -c1-16; }

# 実 script を fake orch cwd で hermetic 実行（bd/bdw/config/marker/now を stub 化）。
# $1=projects文字列 残り=script 引数。ORCH_HYDRATE_NOW は呼出側が事前 export 可（既定 date +%s）。
run_hydrate() {
    local projects="$1"; shift
    run env \
        BDW_LOG="$BDW_LOG" \
        ORCH_HYDRATE_PROJECTS="$projects" \
        ORCH_HYDRATE_CONFIG="$CONFIG" \
        ORCH_HYDRATE_BDW="$FAKE_BDW" \
        ORCH_HYDRATE_BD="$FAKE_BD" \
        ORCH_HYDRATE_SYNC_MARKER="$MARKER" \
        ORCH_HYDRATE_PULL_MARKER_DIR="$PULL_MARKER_DIR" \
        ${ORCH_HYDRATE_NOW:+ORCH_HYDRATE_NOW="$ORCH_HYDRATE_NOW"} \
        ${ORCH_HYDRATE_PULL_THROTTLE_SEC:+ORCH_HYDRATE_PULL_THROTTLE_SEC="$ORCH_HYDRATE_PULL_THROTTLE_SEC"} \
        bash -c "cd '$ORCH' && bash '$SCRIPT' \"\$@\"" -- "$@"
}

# ==============================================================================
# (enumerate) --dry-run は有効 .beads repo を全列挙し不在/非.beads を対象外にする（universal）
# ==============================================================================
@test "(enumerate) dry-run が有効 repo を全列挙・不在/非.beads を対象外（universal・no-flag）" {
    local a b c
    a="$(_mkrepo ra)"; b="$(_mkrepo rb)"
    mkdir -p "$TEST_TMPDIR/rc-nobeads"          # .beads 無し
    c="$TEST_TMPDIR/rc-nobeads"

    run_hydrate "ra=$a rb=$b nc=$c gone=$TEST_TMPDIR/missing" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would execute: ( cd $a && "*"bdw dolt pull )"* ]]
    [[ "$output" == *"would execute: ( cd $b && "*"bdw dolt pull )"* ]]
    [[ "$output" != *"cd $c &&"* ]]             # 非.beads は pull 対象外
    [[ "$output" != *"cd $TEST_TMPDIR/missing"* ]]  # 不在は pull 対象外
    [ ! -f "$BDW_LOG" ]                          # dry-run は bdw を実呼びしない
}

# ==============================================================================
# (cd-form) pull は subshell cd 形＝stub 記録 CWD==repo ∧ bdw 引数に -C 非出現（load-bearing tooth）
# ==============================================================================
@test "(cd-form) pull は ( cd <repo> && bdw dolt pull )＝CWD==repo ∧ -C 非出現" {
    local p; p="$(_mkrepo cdrepo ok)"
    run_hydrate "cdrepo=$p"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PULL-OK: cdrepo"* ]]      # ← run grep が $output を上書きする前に検査する
    [ -f "$BDW_LOG" ]
    # dolt pull 行の CWD フィールド（TAB 前）が repo path と一致する（bdw -C なら orch cwd になり不一致）。
    run grep -P "^\Q$p\E\tdolt pull$" "$BDW_LOG"
    [ "$status" -eq 0 ]
    # bdw への引数列に -C は一度も現れない（bdw -C <repo> dolt pull 形の誤実装を弾く mutation tooth）。
    run grep -- '-C' "$BDW_LOG"
    [ "$status" -ne 0 ]
}

# ==============================================================================
# (order) pull は add/sync の前（BDW_LOG で dolt pull 行が repo add/sync 行より先）
# ==============================================================================
@test "(order) pre-sync pull は repo add/sync より前に走る" {
    local p; p="$(_mkrepo ordrepo ok)"
    run_hydrate "ordrepo=$p"
    [ "$status" -eq 0 ]
    local pull_ln add_ln sync_ln
    pull_ln="$(grep -n 'dolt pull' "$BDW_LOG" | head -1 | cut -d: -f1)"
    add_ln="$(grep -n 'repo add'  "$BDW_LOG" | head -1 | cut -d: -f1)"
    sync_ln="$(grep -n 'repo sync' "$BDW_LOG" | head -1 | cut -d: -f1)"
    [ -n "$pull_ln" ] && [ -n "$add_ln" ] && [ -n "$sync_ln" ]
    [ "$pull_ln" -lt "$add_ln" ]
    [ "$pull_ln" -lt "$sync_ln" ]
}

# ==============================================================================
# (remoteless) remote-less → benign-skip・非fatal・exit0・remote-less 計上
# ==============================================================================
@test "(remoteless) remote-less pull → benign-skip・exit0・remote-less 計上（非fatal）" {
    local p; p="$(_mkrepo rlrepo remoteless)"
    run_hydrate "rlrepo=$p"
    [ "$status" -eq 0 ]                          # 非fatal（remote 無しは benign）
    [[ "$output" == *"PULL-SKIP (remote-less・benign): rlrepo"* ]]
    [[ "$output" == *"remote-less=1"* ]]
    [[ "$output" != *"failures=1"* ]]           # fatal failures へ算入しない
}

# ==============================================================================
# (transient) network/transient 失敗 → pull_warn 計上・failures 非算入・exit0・stamp せず
# ==============================================================================
@test "(transient) transient pull 失敗 → pull_warn・failures 非算入・exit0" {
    local p; p="$(_mkrepo trrepo transient)"
    run_hydrate "trrepo=$p"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PULL-WARN (transient/network・degrade・次cycle回収): trrepo"* ]]
    [[ "$output" == *"warn=1"* ]]
    [[ "$output" == *"failures=0"* ]]           # 明示: fatal 会計に入らない
}

# ==============================================================================
# (conflict) genuine merge-conflict → loud 警告 + pull_warn・非fatal・exit0
# ==============================================================================
@test "(conflict) genuine merge-conflict → loud + pull_warn・exit0（非fatal）" {
    local p; p="$(_mkrepo cfrepo conflict)"
    run_hydrate "cfrepo=$p"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PULL-CONFLICT (genuine・loud・要人手): cfrepo"* ]]
    [[ "$output" == *"warn=1"* ]]
    [[ "$output" == *"failures=0"* ]]
}

# ==============================================================================
# (all-fail-exit0) 全 pull が transient 失敗でも orch-hydrate は exit0（cell 全滅を false-RED と誤読しない）
# ==============================================================================
@test "(all-fail-exit0) 全 pull が失敗しても exit0（sync 到達・cell 全滅を false-RED としない）" {
    local a b
    a="$(_mkrepo fa transient)"; b="$(_mkrepo fb transient)"
    run_hydrate "fa=$a fb=$b"
    [ "$status" -eq 0 ]
    [[ "$output" == *"warn=2"* ]]
    [[ "$output" == *"repo sync"* || "$output" == *"SYNC:"* ]]   # sync 到達（pull 全滅に妨げられない）
    [[ "$output" == *"failures=0"* ]]
}

# ==============================================================================
# (throttle-skip) marker age < THROTTLE → pull を skip（bdw dolt pull を呼ばない）
# ==============================================================================
@test "(throttle-skip) marker fresh（age < THROTTLE）→ pull skip・bdw dolt pull 非呼出" {
    local p; p="$(_mkrepo thr ok)"
    mkdir -p "$PULL_MARKER_DIR"
    local key; key="$(_marker_key "$p")"
    touch -d "@1000000000" "$PULL_MARKER_DIR/$key"    # marker mtime 固定

    ORCH_HYDRATE_NOW=1000000500 ORCH_HYDRATE_PULL_THROTTLE_SEC=1500 \
        run_hydrate "thr=$p"                          # age=500 < 1500 → skip
    [ "$status" -eq 0 ]
    [[ "$output" == *"PULL-SKIP (throttle age=500s < 1500s): thr"* ]]
    [[ "$output" == *"throttled=1"* ]]
    # bdw dolt pull はこの repo に対して呼ばれない（BDW_LOG に dolt pull 行が無い）。
    if [ -f "$BDW_LOG" ]; then
        run grep 'dolt pull' "$BDW_LOG"
        [ "$status" -ne 0 ]
    fi
}

# ==============================================================================
# (throttle-stale) marker age >= THROTTLE → pull を実行（bdw dolt pull を呼ぶ）
# ==============================================================================
@test "(throttle-stale) marker stale（age >= THROTTLE）→ pull 実行" {
    local p; p="$(_mkrepo thr2 ok)"
    mkdir -p "$PULL_MARKER_DIR"
    local key; key="$(_marker_key "$p")"
    touch -d "@1000000000" "$PULL_MARKER_DIR/$key"

    ORCH_HYDRATE_NOW=1000002000 ORCH_HYDRATE_PULL_THROTTLE_SEC=1500 \
        run_hydrate "thr2=$p"                         # age=2000 >= 1500 → pull
    [ "$status" -eq 0 ]
    [[ "$output" == *"PULL-OK: thr2"* ]]
    [ -f "$BDW_LOG" ]
    run grep 'dolt pull' "$BDW_LOG"
    [ "$status" -eq 0 ]
}

# ==============================================================================
# (stamp-success) 成功 pull は throttle marker を stamp（settled → 次 invocation で throttle 窓）
# ==============================================================================
@test "(stamp-success) 成功 pull が throttle marker を stamp する" {
    local p; p="$(_mkrepo stok ok)"
    local key; key="$(_marker_key "$p")"
    [ ! -f "$PULL_MARKER_DIR/$key" ]             # 事前は marker 不在
    run_hydrate "stok=$p"
    [ "$status" -eq 0 ]
    [ -f "$PULL_MARKER_DIR/$key" ]               # 成功後に marker が stamp される
}

# ==============================================================================
# (no-stamp-transient) transient 失敗は marker を stamp しない（次 invocation で retry）
# ==============================================================================
@test "(no-stamp-transient) transient 失敗は marker を stamp しない（retry を保つ）" {
    local p; p="$(_mkrepo ntr transient)"
    local key; key="$(_marker_key "$p")"
    run_hydrate "ntr=$p"
    [ "$status" -eq 0 ]
    [ ! -f "$PULL_MARKER_DIR/$key" ]             # transient は stamp しない → 次回 retry
}

# ==============================================================================
# (stamp-remoteless) remote-less は settled ゆえ throttle marker を stamp する（4 分類 stamp mapping の tooth）
#   remote は自発的に生えない＝settled outcome。stamp して attempt を bound しないと恒常 remote-less repo が
#   毎 invocation pull を再試行し throttle de-dup が失効する（cell-quality 確認 finding の回帰防止）。
# ==============================================================================
@test "(stamp-remoteless) remote-less pull は settled ゆえ throttle marker を stamp する" {
    local p; p="$(_mkrepo strl remoteless)"
    local key; key="$(_marker_key "$p")"
    [ ! -f "$PULL_MARKER_DIR/$key" ]             # 事前は marker 不在
    run_hydrate "strl=$p"
    [ "$status" -eq 0 ]
    [ -f "$PULL_MARKER_DIR/$key" ]               # remote-less→stamp（settled・attempt を bound）
}

# ==============================================================================
# (no-stamp-conflict) genuine merge-conflict は marker を stamp しない（safety・throttle 窓で沈黙させない）
#   conflict を誤って stamp すると要人手の merge-conflict loud 警告が throttle 窓（~25分）抑制される＝安全関連
#   の load-bearing 判定（cell-quality 確認 finding の回帰防止・conflict→no-stamp modality を pin）。
# ==============================================================================
@test "(no-stamp-conflict) genuine conflict は marker を stamp しない（loud を throttle 窓で沈黙させない）" {
    local p; p="$(_mkrepo ncf conflict)"
    local key; key="$(_marker_key "$p")"
    run_hydrate "ncf=$p"
    [ "$status" -eq 0 ]
    [ ! -f "$PULL_MARKER_DIR/$key" ]             # conflict→no-stamp（次 invocation で再 loud・throttle 窓で沈黙しない）
}

# ==============================================================================
# (readonly-selfledger) pull marker は自台帳 marker dir 配下のみ・foreign repo 配下へ書かない
# ==============================================================================
@test "(readonly-selfledger) throttle marker は自台帳 marker dir 配下のみに書く（foreign 非汚染）" {
    local p; p="$(_mkrepo ro ok)"
    run_hydrate "ro=$p"
    [ "$status" -eq 0 ]
    # marker は PULL_MARKER_DIR（自台帳側 temp）配下に生成される。
    local key; key="$(_marker_key "$p")"
    [ -f "$PULL_MARKER_DIR/$key" ]
    # foreign repo 配下に pull-freshness marker を書いていない（write-isolation）。
    [ ! -e "$p/.beads/pull-freshness" ]
    [ ! -e "$p/pull-freshness" ]
}

# ==============================================================================
# (mutation) cd-form/remoteless の不変条件を壊すと RED（非空虚 tooth の明示）
#   このテストは「stub と assert が実挙動に結合している」ことを二重に固める:
#   - CWD 記録が orch cwd（=誤 bdw -C 形の観測値）だったら cd-form assert は落ちる
#   - remoteless を fatal 会計にすると exit≠0 になり remoteless assert は落ちる
# ==============================================================================
@test "(mutation) cd-form CWD 記録と remoteless 非fatal は実挙動に結合（非空虚）" {
    local p; p="$(_mkrepo mut ok)"
    run_hydrate "mut=$p"
    [ "$status" -eq 0 ]
    # 記録 CWD が orch cwd（誤 bdw -C 形の指標）でないことを明示的に否定する。
    run grep -P "^\Q$ORCH\E\tdolt pull$" "$BDW_LOG"
    [ "$status" -ne 0 ]
    # 記録 CWD は必ず repo path 側。
    run grep -P "^\Q$p\E\tdolt pull$" "$BDW_LOG"
    [ "$status" -eq 0 ]
}

# ==============================================================================
# (syntax) bash -n（構文）が通る
# ==============================================================================
@test "(syntax) bash -n が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

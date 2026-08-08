#!/usr/bin/env bats
# tests/scenarios/session-start-workinprogress.bats
#
# SessionStart workinprogress hook（scripts/hooks/session-start-workinprogress.sh・bd orch-7py / orch-c8p F）の
# **e2e（stdin→stdout の実フック契約）** と **hooks.json wire 検査** の hermetic bats。
#
# 背景: fresh な orchestrator session の起動時に、gate-pending pull（orch-dispatch --gate-pending）と
#   degraded-watch（orch-degraded-watch.sh）を read-only で自動実行し「仕掛かり」を context へ自動表示する
#   （orch-c8p grill G3② 採択）。self-scope（orch session のみ）+ cwd 第2軸（anchor のみ・worktree は no-op）+
#   fail-open（script 不在でも session を止めない）を実フック経路で pin する。spec-inject-cwd-axis.bats /
#   guard-health-banner.bats と同型の hermetic E2E。
#
# 方式（hermetic・実 plugin/DB 非依存）:
#   - 台帳 fixture: temp に orch(dolt_database=orch) と foreign(dolt_database=un) の .beads/metadata.json。
#     anchor 配下に .worktrees/spawn/wt と .claude/worktrees/wt2（台帳 walk-up は anchor=orch へ届く）。
#   - 参照 script fixture: fixture plugin root の scripts/ に stub orch-dispatch.sh / orch-degraded-watch.sh
#     を置き、sentinel を echo させる。CLAUDE_PLUGIN_ROOT で hook の参照先を fixture へ向ける。
#   - hook を JSON payload を stdin に流して subprocess 実行し $status と $output を assert する。
#
# 検証する契約不変条件（SSOT=orch-7py / orch-jmu / orch-4js9 / orch-z4z7 acceptance / hook header / hooks.json comment）:
#   (i)   orch anchor cwd → 4 sentinel（gate-pending / degraded-watch / handoff / delivery）表示・exit0。
#   (ii)  orch worktree(.worktrees/ 配下) → no-op（台帳 self-scope は通過するが cwd 軸で弾く）・exit0。
#   (iii) orch worktree(.claude/worktrees/ = CC-native 配下) → no-op・exit0。
#   (iv)  foreign session(dolt_database≠orch) → no-op（self-scope が先に効く）・exit0。
#   (v)   fail-open: 参照 script 不在 → skip note + exit0・sentinel は出ない（非vacuous・acceptance 3・delivery 含む）。
#   (vi)  in-process `--self-test` が green（コミット済 coverage を durable に pin）。
#   (vii) 破損 JSON だが orch トークンを含む台帳 → no-op（guard-parity・sed 誤発火を _json_is_valid が防ぐ）。
#   (viii) jq 破損(exit1)でも valid orch 台帳は sed 経路で救済し発火（fail-open 回帰ガード・OR 合成 rescue）。
#   (ix)  本体が cd anchor してから 4 script を実行し degraded/delivery を無引数 / handoff を --no-freshness で呼ぶ契約を pin
#         （load-bearing・stub が起動時 $PWD + 受領 args を echo し、cd 除去/誤 scope・引数退行を RED 化）。
#   (x)   fail-open 混合: dispatch のみ不在 → degraded/handoff/delivery sentinel + dispatch skip note が同時（部分縮退せず継続）。
#   (xi)  fail-open 混合: degraded のみ不在 → dispatch/handoff/delivery sentinel + degraded skip note が同時。
#   (xii) fail-open 混合: handoff のみ不在 → dispatch/degraded/delivery sentinel + handoff skip note が同時（第3セクション・orch-jmu）。
#   (xiii) fail-open 混合: delivery のみ不在 → dispatch/degraded/handoff sentinel + delivery skip note が同時（第4セクション・orch-4js9）。
#   (xiv) consult 窓(consult-*) → 全4節 no-op（orch-z4z7/fence7・consult gate 削除 mutation で RED）。
#   (xv)  非 consult 窓(orchestrator) → 4 sentinel 表示（consult gate 誤爆しない・fence7 b-2）。
#   (xvi) foreign 台帳 + consult 窓 → no-op（self-scope 先勝ち・fence7 b-3）。
#   (wire) hooks.json が SessionStart へ workinprogress を spec-inject / guard-health と同形 fail-safe
#          （`|| true`）で wire し、参照 script が repo に存在し実行可能であること。
#   (syntax) bash -n が通る。
#
# 実行: bats tests/scenarios/session-start-workinprogress.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/hooks/session-start-workinprogress.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d -t wip-bats-XXXXXX)"

    # 台帳 fixture: orch(self) / foreign(un)。walk-up で .beads/metadata.json の dolt_database を解決。
    ANCHOR="$TEST_TMPDIR/anchor"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$ANCHOR/.beads";  printf '{"dolt_database":"orch"}' > "$ANCHOR/.beads/metadata.json"
    mkdir -p "$FOREIGN/.beads"; printf '{"dolt_database":"un"}'   > "$FOREIGN/.beads/metadata.json"
    mkdir -p "$ANCHOR/.worktrees/spawn/wt"        # 台帳 walk-up は anchor(orch)へ届く worktree
    mkdir -p "$ANCHOR/.claude/worktrees/wt2"      # CC-native worktree

    # 参照 script fixture: stub orch-dispatch.sh / orch-degraded-watch.sh / orch-handoff-scan.sh が sentinel を echo。
    # sentinel に **起動時 PWD**（本体の load-bearing な cd "$anchor_cwd" を pin）と **受領 args**
    # （dispatch は --gate-pending / degraded は無引数=scan mode / handoff は --no-freshness=鮮度を第1セクションへ
    #   委譲・orch-jmu p3 を pin）を含めて gate-full にする。
    PLUGIN="$TEST_TMPDIR/plugin"
    mkdir -p "$PLUGIN/scripts"
    printf '#!/usr/bin/env bash\necho "GATE-PENDING-SENTINEL pwd=$PWD args=[$*]"\n'   > "$PLUGIN/scripts/orch-dispatch.sh"
    printf '#!/usr/bin/env bash\necho "DEGRADED-WATCH-SENTINEL pwd=$PWD args=[$*]"\n' > "$PLUGIN/scripts/orch-degraded-watch.sh"
    printf '#!/usr/bin/env bash\necho "HANDOFF-SCAN-SENTINEL pwd=$PWD args=[$*]"\n'   > "$PLUGIN/scripts/orch-handoff-scan.sh"
    # 第4節 配送観測（orch-4js9）: 本 bats は wire（出る/fail-open/consult で消える）のみ sentinel stub で見る。
    #   推論・呼び鈴の実ロジックは orch-delivery-observe.bats が担う（sentinel echo に代替させない・fence2）。
    printf '#!/usr/bin/env bash\necho "DELIVERY-OBSERVE-SENTINEL pwd=$PWD args=[$*]"\n' > "$PLUGIN/scripts/orch-delivery-observe.sh"
    # 第5節 stub（orch-cqf4 Leg-A・PR#147 engine 反映）: re-ratify sweep（scripts/）と slate surface（scripts/lib/）が
    #   各々独立 sentinel（RERATIFY-SWEEP / SLATE-SURFACE）を起動時 PWD + 受領 args 付きで echo する（load-bearing pin）。
    mkdir -p "$PLUGIN/scripts/lib"
    printf '#!/usr/bin/env bash\necho "RERATIFY-SWEEP-SENTINEL pwd=$PWD args=[$*]"\n' > "$PLUGIN/scripts/orch-stale-scan.sh"
    printf '#!/usr/bin/env bash\necho "SLATE-SURFACE-SENTINEL pwd=$PWD args=[$*]"\n'  > "$PLUGIN/scripts/lib/orch_slate.sh"
    chmod +x "$PLUGIN/scripts/orch-dispatch.sh" "$PLUGIN/scripts/orch-degraded-watch.sh" \
             "$PLUGIN/scripts/orch-handoff-scan.sh" "$PLUGIN/scripts/orch-delivery-observe.sh" \
             "$PLUGIN/scripts/orch-stale-scan.sh" "$PLUGIN/scripts/lib/orch_slate.sh"

    # consult 経路（orch-z4z7 / fence7 b）用 hazard-faithful stub tmux（spec-inject M2 teeth と同型）。
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"
    cat > "$BIN/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
have_t=0; prev=""
for a in "$@"; do
    if [ "$prev" = "-t" ] && [ -n "$a" ]; then have_t=1; fi
    prev="$a"
done
if [ "$have_t" -eq 1 ]; then
    [ -n "${STUB_WNAME:-}" ] || exit 1
    printf '%s\n' "$STUB_WNAME"
else
    printf '%s\n' "orchestrator"
fi
TMUXEOF
    chmod +x "$BIN/tmux"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# hook payload の cwd を stdin で与え、fixture plugin root で script を起動する。
# NOTE: bats の `run` はパイプ下流に置くと $status/$output を親テストへ伝播しないため、
#   stdin はファイル経由で与え、`run` を最外（リダイレクト付き simple command）に置く。
run_hook() {  # $1=cwd
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    # env -u TMUX -u TMUX_PANE（fence7 a）: bats を実 tmux window 内で回したとき、新設 consult gate の
    #   _is_consult_window が実 tmux/実窓名に依存するのを遮断する（非 consult 経路の既存 modality を実窓名非依存に保つ）。
    run env -u TMUX -u TMUX_PANE bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

# ── 表示層 trim（bd sc-v0ao）用ヘルパ ──────────────────────────────────────────────────────────
# stdout **のみ** を返す（`run` は stderr を混ぜるため u16 計測には使わない・計測規律: stderr 混入禁止）。
hook_stdout_of() {  # $1=script $2..=args → stdout を echo
    local _s="$1"; shift
    printf '{"cwd":"%s"}' "$ANCHOR" > "$TEST_TMPDIR/payload.json"
    env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$PLUGIN" bash "$_s" "$@" < "$TEST_TMPDIR/payload.json" 2>/dev/null
}
hook_stdout() { hook_stdout_of "$SCRIPT" "$@"; }

# u16（UTF-16 code unit）計測: utf-8 decode → strip → utf-16-le byte 長 // 2（wc -c / wc -m は代用にしない）。
u16_of() {  # $1=text → u16 数
    printf '%s' "$1" | python3 -c 'import sys
_d = sys.stdin.buffer.read().decode("utf-8", "replace").strip()
sys.stdout.write(str(len(_d.encode("utf-16-le")) // 2))'
}

# 過負荷 stub: 1 節あたり 200 行・各行 ~120 文字（日本語混在）を吐く。$3=prio なら **末尾付近**に
# 滞留行 / 呼び鈴行（優先クラス）を足す（T3 用）。record 行には優先クラス語を一切含めない。
make_overload_stub() {  # $1=path $2=tag $3=mode(plain|prio)
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
pad='仕掛かり記録の詳細説明テキストであり表示予算を消費するための埋草である。'
i=1
while [ $i -le 200 ]; do
    printf '  %sREC%03d %s%s%s\n' "$tag" "$i" "$pad" "$pad" "$pad"
    i=$((i + 1))
done
STUBEOF
    sed -i "s/__TAG__/$2/" "$1"
    if [ "${3:-plain}" = "prio" ]; then
        cat >> "$1" <<'STUBEOF'
printf '  [滞留] %sSTUCK 便が滞留している宛先がある\n' "$tag"
printf '  🔔 呼び鈴: %sBELL needs-user 併存の提案（proposal-only）\n' "$tag"
STUBEOF
    fi
    chmod +x "$1"
}

# 全行が優先クラス（[滞留]）の過負荷 stub（T3 phase2 用）。実 producer の regime（配送観測の便 record は
# 全行が [滞留]）を模す＝優先行は N 枠を消費しないので trim では 1 行も減らず、終端 hard-cap だけが効く。
make_allprio_stub() {  # $1=path $2=tag $3=mode(無視)
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
pad='仕掛かり記録の詳細説明テキストであり表示予算を消費するための埋草である。'
i=1
while [ $i -le 200 ]; do
    printf '  便 %sREC%03d [滞留] %s%s\n' "$tag" "$i" "$pad" "$pad"
    i=$((i + 1))
done
printf '      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go）｜根拠: %s-BELL\n' "$tag"
printf '  ── 集計: undelivered(滞留)=200 呼び鈴提案=1（%s）\n' "$tag"
STUBEOF
    sed -i "s/__TAG__/$2/" "$1"
    chmod +x "$1"
}

# 少行 stub（T2 用・trim が誤発火しないことを見る）。
make_small_stub() {  # $1=path $2=tag
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
for i in 1 2 3; do printf '  %sREC%03d 少量の記録行\n' "$tag" "$i"; done
STUBEOF
    sed -i "s/__TAG__/$2/" "$1"
    chmod +x "$1"
}

# 6 block 全部（第1-4節 + 第5節の re-ratify / slate）を差し替える。tag は block 識別子。
make_all_stubs() {  # $1=maker(make_overload_stub|make_small_stub) $2=mode
    "$1" "$PLUGIN/scripts/orch-dispatch.sh"         S1 "${2:-plain}"
    "$1" "$PLUGIN/scripts/orch-degraded-watch.sh"   S2 "${2:-plain}"
    "$1" "$PLUGIN/scripts/orch-handoff-scan.sh"     S3 "${2:-plain}"
    "$1" "$PLUGIN/scripts/orch-delivery-observe.sh" S4 "${2:-plain}"
    "$1" "$PLUGIN/scripts/orch-stale-scan.sh"       S5 "${2:-plain}"
    "$1" "$PLUGIN/scripts/lib/orch_slate.sh"        S6 "${2:-plain}"
}

# ── 実行予算（bd sc-dmmz・per-child bound + 総予算 deadline）用 stub 群 ───────────────────────────
# ★予算の teeth は「速い/遅い」だけでは足りない。**孫が stdout を保持したまま子が即 exit する** 形（command
#   substitution が解放されない）と、**孫が生き残って副作用を残す** 形（timeout --foreground でプロセスグループを
#   作らない）を別 fixture として持つ＝実装形の拘束（子 stdout を file sink へ / --foreground 禁止）が load-bearing
#   であることを、存在 grep でなく実挙動で示すため。
# (1) 即時: 3 行出して即 exit（打ち切られない子）。
make_budget_fast_stub() {  # $1=path $2=tag $3=無視
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
for i in 1 2 3; do printf '  %sREC%03d 即時に返る子の記録行\n' "$tag" "$i"; done
STUBEOF
    sed -i "s/__TAG__/$2/" "$1"; chmod +x "$1"
}
# (2) 遅い: 部分出力を出してから長時間 hang（per-child bound / 総予算 deadline の打ち切り対象）。
make_budget_slow_stub() {  # $1=path $2=tag $3=hang 秒
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
for i in 1 2 3; do printf '  %sREC%03d 遅い子の部分出力行\n' "$tag" "$i"; done
sleep __HANG__
STUBEOF
    sed -i "s/__TAG__/$2/; s/__HANG__/${3:-30}/" "$1"; chmod +x "$1"
}
# (3) 孫が stdout を保持: 本体は即 exit するが孫が生き残る（`_raw="$(子)"` 形だと本体が孫の寿命ぶん待たされる）。
make_budget_gc_stub() {  # $1=path $2=tag $3=孫の寿命秒
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
( sleep __LIFE__ ) &
for i in 1 2 3; do printf '  %sREC%03d 孫を残して即 exit する子の記録行\n' "$tag" "$i"; done
STUBEOF
    sed -i "s/__TAG__/$2/; s/__LIFE__/${3:-8}/" "$1"; chmod +x "$1"
}
# (4) 孫が marker を残す: 本体は hang し孫が N 秒後に marker を作る（--foreground を付ける mutation の teeth）。
make_budget_marker_stub() {  # $1=path $2=tag $3=marker path $4=孫の待ち秒
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
( sleep __WAIT__; : > "__MARKER__" ) &
printf '  %sREC001 孫つきの子\n' "$tag"
sleep 30
STUBEOF
    sed -i "s/__TAG__/$2/; s|__MARKER__|$3|; s/__WAIT__/${4:-3}/" "$1"; chmod +x "$1"
}
# (5) 全行優先クラスの過負荷を出してから hang（打ち切り行が trim + hard-cap を通り抜けるかを見る regime）。
make_budget_allprio_slow_stub() {  # $1=path $2=tag $3=hang 秒
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
pad='仕掛かり記録の詳細説明テキストであり表示予算を消費するための埋草である。'
i=1
while [ $i -le 200 ]; do
    printf '  便 %sREC%03d [滞留] %s%s\n' "$tag" "$i" "$pad" "$pad"
    i=$((i + 1))
done
sleep __HANG__
STUBEOF
    sed -i "s/__TAG__/$2/; s/__HANG__/${3:-30}/" "$1"; chmod +x "$1"
}

# 予算 knob 付きで hook を起動し stdout のみを返す（$1=script $2=per-child 秒 $3=総予算 秒 $4..=args）。
# ★予算をハードコードしていたら hermetic test は実時間 60 秒級の sleep を強いられ、存在 grep の vacuous test へ
#   退避せざるを得なくなる。env knob（WIP_CHILD_TIMEOUT / WIP_TOTAL_BUDGET / WIP_KILL_GRACE）で 1 秒級にする。
hook_stdout_budget() {
    local _s="$1" _c="$2" _t="$3"; shift 3
    printf '{"cwd":"%s"}' "$ANCHOR" > "$TEST_TMPDIR/payload.json"
    env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$PLUGIN" \
        WIP_CHILD_TIMEOUT="$_c" WIP_TOTAL_BUDGET="$_t" WIP_KILL_GRACE=1 \
        bash "$_s" "$@" < "$TEST_TMPDIR/payload.json" 2>/dev/null
}

# sink（一時 file）不能を模す PATH shim: wip-child-* の要求だけ失敗し、他は実 mktemp へ委譲する（bats 自身や
# 子 stub の mktemp を巻き添えにしない）。TMPDIR が read-only / 容量枯渇 / sandbox 制限のときの現実経路。
make_fake_mktemp_fail() {
    MKBIN="$TEST_TMPDIR/mkbin"; mkdir -p "$MKBIN"
    local _real; _real="$(command -v mktemp)"
    cat > "$MKBIN/mktemp" <<'MKEOF'
#!/usr/bin/env bash
for a in "$@"; do case "$a" in wip-child-*) exit 1 ;; esac; done
exec "__REAL__" "$@"
MKEOF
    sed -i "s|__REAL__|$_real|" "$MKBIN/mktemp"; chmod +x "$MKBIN/mktemp"
}

# 予算 knob 付き + mktemp 不能 shim 付きで hook を起動する（$1=script $2=per-child 秒 $3=総予算 秒）。
# ここでは決定論 path の fallback（SINK-FALLBACK）が通る＝sink は確保できる（正規経路のまま degrade を出す）。
hook_stdout_budget_nosink() {
    local _s="$1" _c="$2" _t="$3"; shift 3
    printf '{"cwd":"%s"}' "$ANCHOR" > "$TEST_TMPDIR/payload.json"
    env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$PLUGIN" PATH="$MKBIN:$PATH" \
        WIP_CHILD_TIMEOUT="$_c" WIP_TOTAL_BUDGET="$_t" WIP_KILL_GRACE=1 \
        bash "$_s" "$@" < "$TEST_TMPDIR/payload.json" 2>/dev/null
}

# sink を **全滅** させて hook を起動する（mktemp shim ＋ TMPDIR を不在 dir へ向ける）＝mktemp も決定論 path も
# 作れない現実経路（TMPDIR が消えている / 権限が無い / sandbox 制限）。ここが「禁止形へ落ちない」ことを実測する
# 唯一の regime（sink が在る限り正規経路しか通らないため、他の helper では踏めない）。
hook_stdout_budget_nosink_hard() {
    local _s="$1" _c="$2" _t="$3"; shift 3
    printf '{"cwd":"%s"}' "$ANCHOR" > "$TEST_TMPDIR/payload.json"
    env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$PLUGIN" PATH="$MKBIN:$PATH" \
        TMPDIR="$TEST_TMPDIR/absent-sink-dir" \
        WIP_CHILD_TIMEOUT="$_c" WIP_TOTAL_BUDGET="$_t" WIP_KILL_GRACE=1 \
        bash "$_s" "$@" < "$TEST_TMPDIR/payload.json" 2>/dev/null
}

# timeout **だけ** を除いた PATH farm（`command -v timeout` を実際に失敗させる唯一の hermetic 手段。shim では
# 「在るが失敗する」しか作れず degrade 分岐へ入らない）。他の外部 bin（python3 / jq / sed / cat / rm / date …）は
# 実体への symlink で保つ＝hook と共有 lib の依存を壊さない。
make_no_timeout_path() {
    NOTOBIN="$TEST_TMPDIR/notobin"; mkdir -p "$NOTOBIN"
    local _d _f _b
    while IFS= read -r _d; do
        [ -d "$_d" ] || continue
        for _f in "$_d"/*; do
            _b="${_f##*/}"
            [ "$_b" = "timeout" ] && continue
            [ -e "$NOTOBIN/$_b" ] && continue
            [ -x "$_f" ] || continue
            ln -s "$_f" "$NOTOBIN/$_b" 2>/dev/null || true
        done
    done <<<"$(tr ':' '\n' <<<"$PATH")"
}

# timeout 不在 × sink 全滅（bare 経路）で hook を起動する。上界が本当に消える最悪の degrade で、それでも
# 出力が続き（fail-open）degrade が loud に出ることを実測するための唯一の regime。
hook_stdout_budget_bare() {  # $1=script $2=per-child 秒 $3=総予算 秒
    local _s="$1" _c="$2" _t="$3"; shift 3
    printf '{"cwd":"%s"}' "$ANCHOR" > "$TEST_TMPDIR/payload.json"
    env -u TMUX -u TMUX_PANE CLAUDE_PLUGIN_ROOT="$PLUGIN" PATH="$MKBIN:$NOTOBIN" \
        TMPDIR="$TEST_TMPDIR/absent-sink-dir" \
        WIP_CHILD_TIMEOUT="$_c" WIP_TOTAL_BUDGET="$_t" WIP_KILL_GRACE=1 \
        bash "$_s" "$@" < "$TEST_TMPDIR/payload.json" 2>/dev/null
}

# 部分出力を出してから非0で終わる子（「壊れた子」＝打ち切りではない fail-open 経路の fixture）。
make_budget_rc_stub() {  # $1=path $2=tag $3=exit code
    cat > "$1" <<'STUBEOF'
#!/usr/bin/env bash
tag="__TAG__"
for i in 1 2 3; do printf '  %sREC%03d 途中まで出して壊れる子の記録行\n' "$tag" "$i"; done
exit __RC__
STUBEOF
    sed -i "s/__TAG__/$2/; s/__RC__/${3:-3}/" "$1"; chmod +x "$1"
}

# mutant を作る（sed 式で本体を書き換えた copy）。lib も同梱して source を解決させる（_SCRIPT_DIR 相対）。
make_mutant() {  # $1=sed 式 → mutant script path を echo
    local _d="$TEST_TMPDIR/mut-$2"
    mkdir -p "$_d/lib"
    sed "$1" "$SCRIPT" > "$_d/session-start-workinprogress.sh"
    cp "$REPO/scripts/hooks/lib/orch_session.sh" "$_d/lib/orch_session.sh"
    chmod +x "$_d/session-start-workinprogress.sh"
    printf '%s' "$_d/session-start-workinprogress.sh"
}

# consult 経路（fence7 b）: TMUX + stub tmux 付きで起動（$2=窓名・空→tmux 取得失敗を模す）。
run_hook_consult() {  # $1=cwd $2=window-name
    printf '{"cwd":"%s"}' "$1" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    run env PATH="$BIN:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" \
        bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
}

@test "(i) orch anchor cwd → 4 sentinel(gate-pending / degraded-watch / handoff / delivery)表示・exit0" {
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]
    [[ "$output" == *"DEGRADED-WATCH-SENTINEL"* ]]
    [[ "$output" == *"HANDOFF-SCAN-SENTINEL"* ]]   # 第3セクション（needs-orch handoff・orch-jmu）
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL"* ]]   # 第4セクション（配送観測・orch-4js9）
    [[ "$output" == *"--gate-pending"* ]]     # dispatch に --gate-pending が渡っている
    [[ "$output" == *"--no-freshness"* ]]     # handoff に --no-freshness が渡っている（鮮度は第1へ委譲・p3）
}

@test "(ii) orch worktree(.worktrees/ 配下) → no-op(cwd 軸で弾く)・exit0" {
    run_hook "$ANCHOR/.worktrees/spawn/wt"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(iii) orch worktree(.claude/worktrees/ = CC-native 配下) → no-op・exit0" {
    run_hook "$ANCHOR/.claude/worktrees/wt2"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(iv) foreign session → no-op(self-scope 先行)・exit0" {
    run_hook "$FOREIGN"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(v) fail-open: 参照 script 不在 → skip note + exit0・sentinel 無(非vacuous・acceptance 3)" {
    rm -f "$PLUGIN/scripts/orch-dispatch.sh" "$PLUGIN/scripts/orch-degraded-watch.sh" \
          "$PLUGIN/scripts/orch-handoff-scan.sh" "$PLUGIN/scripts/orch-delivery-observe.sh"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"GATE-PENDING-SENTINEL"* ]]
    [[ "$output" != *"DEGRADED-WATCH-SENTINEL"* ]]
    [[ "$output" != *"HANDOFF-SCAN-SENTINEL"* ]]
    [[ "$output" != *"DELIVERY-OBSERVE-SENTINEL"* ]]
    [[ "$output" == *"fail-open"* ]]          # skip note を出して continue する
}

@test "(vi) 本体 --self-test が green(durable coverage pin・fail-closed)" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(vii) 破損 JSON だが orch トークンを含む台帳 → no-op(guard-parity・誤発火ゼロ)・exit0" {
    # header の安全機構: sed 抽出前に _json_is_valid を噛ませ、破損 JSON(orch トークン入り)で shell だけが
    # 誤発火するのを防ぐ。破損 metadata `{"dolt_database":"orch"`（未閉じ）は jq -r が空を返し
    # _json_is_valid が invalid と判定 → sed フォールバック不採用 → db 空 → no-op。bare sed guard だと
    # orch を抽出して誤発火するため、この分岐が load-bearing。
    BROKEN="$TEST_TMPDIR/broken"
    mkdir -p "$BROKEN/.beads"
    printf '{"dolt_database":"orch"'  > "$BROKEN/.beads/metadata.json"   # 未閉じ = 破損 JSON
    run_hook "$BROKEN"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$output" != *"GATE-PENDING-SENTINEL"* ]]   # 破損 orch トークンで誤発火しない
}

@test "(viii) jq 破損(exit1)でも valid orch 台帳は sed 経路で救済し発火(fail-open 回帰ガード)・exit0" {
    # _json_is_valid は jq/python3/node の OR 合成で、壊れた jq の偽陰性を python3/node が救う設計
    # （header「壊れた jq の veto を python3/node が救う」）。broken jq(常に exit1)を PATH 前置しても
    # valid JSON なら python3 が妥当を肯定 → sed で orch 抽出 → 発火する（jq 単独破損で anchor を取りこぼさない）。
    mkdir -p "$TEST_TMPDIR/fakebin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TEST_TMPDIR/fakebin/jq"
    chmod +x "$TEST_TMPDIR/fakebin/jq"
    printf '{"cwd":"%s"}' "$ANCHOR" > "$TEST_TMPDIR/payload.json"
    export CLAUDE_PLUGIN_ROOT="$PLUGIN"
    run env PATH="$TEST_TMPDIR/fakebin:$PATH" bash "$SCRIPT" < "$TEST_TMPDIR/payload.json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]     # jq 破損でも sed 経路で orch 判定 → 発火
    [[ "$output" == *"DEGRADED-WATCH-SENTINEL"* ]]
}

@test "(ix) 本体が cd anchor してから 3 script を実行し degraded 無引数 / handoff --no-freshness を pin(load-bearing)" {
    # session-start-workinprogress.sh:_emit_workinprogress の cd "$anchor_cwd"（bd/degraded の
    # self-scope を anchor 起点に一貫解決させる load-bearing な副作用）と、degraded の scan-mode
    # 無引数呼出を実 stdout で pin する。stub が起動時 $PWD と受領 args を echo するので、
    #   - cd を外す/誤 scope → stub の pwd が fixture anchor と不一致 → RED。
    #   - degraded に引数を付ける退行 → degraded の args が [] でなくなる → RED。
    EXPECTED_ANCHOR="$(cd "$ANCHOR" && pwd)"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    # dispatch: cd anchor 済み + --gate-pending で呼ばれる（pwd と args を同時に pin）。
    [[ "$output" == *"GATE-PENDING-SENTINEL pwd=$EXPECTED_ANCHOR args=[--gate-pending]"* ]]
    # degraded: cd anchor 済み + 無引数(scan mode)で呼ばれる（pwd と args=[] を同時に pin）。
    [[ "$output" == *"DEGRADED-WATCH-SENTINEL pwd=$EXPECTED_ANCHOR args=[]"* ]]
    # handoff: cd anchor 済み + --no-freshness(鮮度を第1セクションへ委譲・orch-jmu p3)で呼ばれる。
    [[ "$output" == *"HANDOFF-SCAN-SENTINEL pwd=$EXPECTED_ANCHOR args=[--no-freshness]"* ]]
    # delivery: cd anchor 済み + 無引数(observe mode)で呼ばれる（pwd と args=[] を同時に pin・orch-4js9）。
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL pwd=$EXPECTED_ANCHOR args=[]"* ]]
}

@test "(x) fail-open 混合: dispatch のみ不在 → degraded/handoff sentinel + dispatch skip note が同時・exit0" {
    rm -f "$PLUGIN/scripts/orch-dispatch.sh"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"GATE-PENDING-SENTINEL"* ]]        # dispatch 不在 → sentinel 出ない
    [[ "$output" == *"orch-dispatch.sh 不在"* ]]         # dispatch skip note（fail-open）
    [[ "$output" == *"DEGRADED-WATCH-SENTINEL"* ]]       # degraded は存在 → sentinel 出る（部分縮退せず継続）
    [[ "$output" == *"HANDOFF-SCAN-SENTINEL"* ]]         # 第3セクション handoff も継続発火（部分縮退せず継続）
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL"* ]]     # 第4セクション delivery も継続発火（部分縮退せず継続）
}

@test "(xi) fail-open 混合: degraded のみ不在 → dispatch/handoff sentinel + degraded skip note が同時・exit0" {
    rm -f "$PLUGIN/scripts/orch-degraded-watch.sh"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]         # dispatch は存在 → sentinel 出る
    [[ "$output" == *"orch-degraded-watch.sh 不在"* ]]   # degraded skip note（fail-open）
    [[ "$output" != *"DEGRADED-WATCH-SENTINEL"* ]]       # degraded 不在 → sentinel 出ない
    [[ "$output" == *"HANDOFF-SCAN-SENTINEL"* ]]         # 第3セクション handoff も継続発火（部分縮退せず継続）
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL"* ]]     # 第4セクション delivery も継続発火（部分縮退せず継続）
}

@test "(xii) fail-open 混合: handoff のみ不在 → dispatch/degraded sentinel + handoff skip note が同時・exit0" {
    rm -f "$PLUGIN/scripts/orch-handoff-scan.sh"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]         # dispatch は存在 → sentinel 出る
    [[ "$output" == *"DEGRADED-WATCH-SENTINEL"* ]]       # degraded は存在 → sentinel 出る
    [[ "$output" != *"HANDOFF-SCAN-SENTINEL"* ]]         # handoff 不在 → sentinel 出ない
    [[ "$output" == *"orch-handoff-scan.sh 不在"* ]]     # handoff skip note（fail-open・部分縮退せず継続）
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL"* ]]     # 第4セクション delivery も継続発火（部分縮退せず継続）
}

@test "(xiii) fail-open 混合: delivery のみ不在 → dispatch/degraded/handoff sentinel + delivery skip note が同時・exit0（orch-4js9）" {
    rm -f "$PLUGIN/scripts/orch-delivery-observe.sh"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]         # dispatch は存在 → sentinel 出る
    [[ "$output" == *"DEGRADED-WATCH-SENTINEL"* ]]       # degraded は存在 → sentinel 出る
    [[ "$output" == *"HANDOFF-SCAN-SENTINEL"* ]]         # handoff は存在 → sentinel 出る
    [[ "$output" != *"DELIVERY-OBSERVE-SENTINEL"* ]]     # delivery 不在 → sentinel 出ない
    [[ "$output" == *"orch-delivery-observe.sh 不在"* ]] # delivery skip note（fail-open・部分縮退せず継続）
}

@test "(xiv) consult 窓(consult-*) → 全4節 no-op・exit0（orch-z4z7 / fence7・gate 削除 mutation で RED）" {
    run_hook_consult "$ANCHOR" "consult-abc"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                     # consult 窓へは仕掛かり一覧を一切注入しない（全4節一括 gating）
}

@test "(xv) 非 consult 窓(orchestrator) → 4 sentinel 表示・exit0（consult gate 誤爆しない・fence7 b-2）" {
    run_hook_consult "$ANCHOR" "orchestrator"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL"* ]]     # consult でない anchor 窓では全4節 emit
}

@test "(xvi) foreign 台帳 + consult 窓 → no-op(self-scope 先勝ち)・exit0（fence7 b-3）" {
    run_hook_consult "$FOREIGN" "consult-abc"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(xvii) 第5節: orch anchor → RERATIFY-SWEEP / SLATE-SURFACE 両 sentinel 表示・exit0（orch-cqf4 Leg-A・cd anchor + --re-ratify/--surface を pin）" {
    # 第5節 wire（re-ratify sweep + open slate surface）の存在を独立に pin する。sections 1-4 の 4-sentinel assert
    # は 5th/6th 破損を検知しない（vacuous）ため、両 sentinel を pwd + 受領 args 付きで明示 assert する（F7 b）。
    EXPECTED_ANCHOR="$(cd "$ANCHOR" && pwd)"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    # re-ratify: cd anchor 済み + --re-ratify で呼ばれる（pwd と args を同時に pin）。
    [[ "$output" == *"RERATIFY-SWEEP-SENTINEL pwd=$EXPECTED_ANCHOR args=[--re-ratify]"* ]]
    # slate surface: cd anchor 済み + --surface で呼ばれる（pwd と args を同時に pin）。
    [[ "$output" == *"SLATE-SURFACE-SENTINEL pwd=$EXPECTED_ANCHOR args=[--surface]"* ]]
}

@test "(xviii) 第5節 fail-open mutation: re-ratify/slate stub 不在 → 両 sentinel 消失 + skip note + exit0（5th/6th 独立・既存 4-sentinel の流用不可・F7 c）" {
    # 第5節 stub 2 本だけを削除する（sections 1-4 stub は温存）。両 sentinel が消え skip note を出し、
    # 他 4 節は継続発火する（部分縮退せず fail-open）ことを見る＝5th/6th の teeth を独立に立証する。
    rm -f "$PLUGIN/scripts/orch-stale-scan.sh" "$PLUGIN/scripts/lib/orch_slate.sh"
    run_hook "$ANCHOR"
    [ "$status" -eq 0 ]
    [[ "$output" != *"RERATIFY-SWEEP-SENTINEL"* ]]         # re-ratify 不在 → sentinel 出ない
    [[ "$output" != *"SLATE-SURFACE-SENTINEL"* ]]          # slate surface 不在 → sentinel 出ない
    [[ "$output" == *"orch-stale-scan.sh 不在"* ]]          # re-ratify skip note（fail-open）
    [[ "$output" == *"orch_slate.sh 不在"* ]]               # slate surface skip note（fail-open）
    [[ "$output" == *"GATE-PENDING-SENTINEL"* ]]           # 第1-4節は温存 → 継続発火（部分縮退しない）
    [[ "$output" == *"DELIVERY-OBSERVE-SENTINEL"* ]]
}

# ══ 表示層 trim（bd sc-v0ao・inline 復帰「上位 N 行 + 全件 pointer」）の teeth: T1-T4 ══════════════
# ★既存 20 test は 1 行 stub ゆえ trim 経路を一切踏まない（20/20 green は新機能の証拠にならない）。
#   よって過負荷 stub（1 節 200 行 × ~120 字）で **同一 run の before(--full) / after** を対で測り、
#   「0 u16 / 縮退 / vacuous な小出力」を合格根拠にできないようにする。

@test "(T1) 過負荷 stub: before(--full)>=12000 u16 かつ after<=9800 u16・全節見出し実在・fail-open 0 hit・省略件数が実省略行数と一致" {
    make_all_stubs make_overload_stub plain
    local before after b a
    before="$(hook_stdout --full)"     # 同一 run の before（trim を外した全件経路）
    after="$(hook_stdout)"             # after（表示層 trim 後）
    b="$(u16_of "$before")"; a="$(u16_of "$after")"
    # (c) before が 12,000 u16 以上 = 計測が非vacuous（stub が実際に cliff 超えの負荷を出している）
    [ "$b" -ge 12000 ]
    # (d) after が 9,800 u16 以下（目標 8,000）
    [ "$a" -le 9800 ]
    # (a) 全節見出しが在る（trim で節が消えていない）
    [[ "$after" == *"(1) gate-pending"* ]]
    [[ "$after" == *"(2) degraded-watch"* ]]
    [[ "$after" == *"(3) needs-orch handoff"* ]]
    [[ "$after" == *"(4) 配送観測"* ]]
    [[ "$after" == *"(5) re-ratify sweep"* ]]
    # (b) 出力中の fail-open が 0 hit（縮退した小出力を合格根拠にしない）
    [[ "$after" != *"fail-open"* ]]
    # 各 block: 表示 record 行数が N 上限内 + 「省略行の <数> == 実省略行数」（= 200 - 表示行数）
    local tags=(S1 S2 S3 S4 S5 S6)
    local scripts=(orch-dispatch.sh orch-degraded-watch.sh orch-handoff-scan.sh orch-delivery-observe.sh orch-stale-scan.sh orch_slate.sh)
    local k shown line omit
    for k in 0 1 2 3 4 5; do
        shown="$(grep -c "${tags[$k]}REC" <<<"$after" || true)"
        line="$(grep -F '行を省略・全件: ' <<<"$after" | grep -F "${scripts[$k]}" || true)"
        omit="$(sed -n 's/.*残り \([0-9][0-9]*\) 行を省略.*/\1/p' <<<"$line")"
        [ -n "$omit" ]                       # 省略が起きた block には必ず省略行が出る
        [ "$shown" -ge 5 ]                   # floor: 5 行未満へは落ちない
        [ "$shown" -le 20 ]                  # 予算駆動 N の上限内（200 行中のごく一部）
        [ "$((shown + omit))" -eq 200 ]      # 省略件数が実省略行数と一致
    done
}

@test "(T2) 少行 stub(3 行) → 省略行 0 hit・全 record 行が残る（trim が誤発火しない）" {
    make_all_stubs make_small_stub
    local after n
    after="$(hook_stdout)"
    [[ "$after" != *"行を省略"* ]]                    # 省略 0 の block では省略行を出さない
    n="$(grep -c 'REC' <<<"$after" || true)"
    [ "$n" -eq 18 ]                                   # 3 行 × 6 block が全部残る
}

@test "(T3) 過負荷 stub の末尾付近に置いた滞留行 / 呼び鈴行が trim 後も全 block で残存（優先行は N 枠外）" {
    make_all_stubs make_overload_stub prio
    local after t
    after="$(hook_stdout)"
    for t in S1 S2 S3 S4 S5 S6; do
        [[ "$after" == *"${t}STUCK"* ]]               # [滞留] 行（末尾付近）が残る
        [[ "$after" == *"${t}BELL"* ]]                # 🔔 呼び鈴行（末尾付近）が残る
    done
    # 節生存（acceptance 3）: 優先行が混ざっても節見出しは 1 つも消えない（優先行の生存だけを見て
    # 「後半の節が見出しごと落ちた」を見逃さないための対の assert）。
    [[ "$after" == *"(1) gate-pending"* ]]
    [[ "$after" == *"(2) degraded-watch"* ]]
    [[ "$after" == *"(3) needs-orch handoff"* ]]
    [[ "$after" == *"(4) 配送観測"* ]]
    [[ "$after" == *"(5) re-ratify sweep"* ]]
    # 対で見る: 非優先 record 行は畳まれている（「trim が効いていない」ことを優先行の生存と取り違えない）
    [[ "$after" == *"行を省略・全件: "* ]]
    [ "$(u16_of "$after")" -le 9800 ]

    # phase2（優先行が予算を食い潰す最悪ケース・実 producer の regime）: 全 6 block が全行 [滞留]（＝優先行で
    # N 枠を消費しない）＋末尾に 🔔 / 集計:。trim では 1 行も減らず終端 hard-cap だけが効く経路を e2e で踏む。
    local ap
    make_all_stubs make_allprio_stub
    ap="$(hook_stdout)"
    # 節生存: hard-cap が発火しても全節見出しは 1 つも落ちない（末尾一律切りだと (2)-(5) が全滅する形）
    [[ "$ap" == *"(1) gate-pending"* ]]
    [[ "$ap" == *"(2) degraded-watch"* ]]
    [[ "$ap" == *"(3) needs-orch handoff"* ]]
    [[ "$ap" == *"(4) 配送観測"* ]]
    [[ "$ap" == *"(5) re-ratify sweep"* ]]
    # 予算警告は body より前（stdout 先頭 1 行目）
    [[ "$(head -n 1 <<<"$ap")" == *"⚠ 警告: 表示予算"* ]]
    [[ "$ap" == *"予算到達により以降 "* ]]
    # rank-A（🔔 / 集計:）は block 末尾に置いても全 6 block ぶん残る
    [ "$(grep -c '🔔' <<<"$ap")" -eq 6 ]
    [ "$(grep -c '── 集計:' <<<"$ap")" -eq 6 ]
    # 予算保証は **警告行を含む stdout 総量**で見る（body だけ見ると警告行ぶん超過して land する）
    [ "$(u16_of "$ap")" -le 8000 ]
}

@test "(T4) mutation: trim 除去 / 省略行 emit 除去 で T1 の assert が RED 化する（teeth の非vacuity）" {
    make_all_stubs make_overload_stub plain
    local after mut out
    # 健全形は green（対照）
    after="$(hook_stdout)"
    [ "$(u16_of "$after")" -le 9800 ]
    [[ "$after" == *"行を省略・全件: "* ]]
    # mutation A: 表示層 trim を外す（WIP_TRIM=1 → 0）→ after が 9,800 u16 を超える（T1 の (d) が RED 化）
    mut="$(make_mutant 's/^WIP_TRIM=1/WIP_TRIM=0/' A)"
    out="$(hook_stdout_of "$mut")"
    [ "$(u16_of "$out")" -gt 9800 ]
    # mutation B: 省略行 emit を止める（条件を到達不能化・構文は保つ）→ 省略行が 0 hit（T1 の件数一致が RED 化）
    mut="$(make_mutant 's/_omit" -gt 0 \]/_omit" -gt 999999 ]/' B)"
    out="$(hook_stdout_of "$mut")"
    [ -n "$out" ]                                     # mutant が死んでいない（構文破壊で空になる偽 RED を排除）
    [[ "$out" != *"行を省略・全件: "* ]]
}

# ══ 実行予算（bd sc-dmmz・per-child bound + 総予算 deadline）の teeth: B1-B7 ═══════════════════════
# ★既存 24 test は即時 stub ゆえ予算経路を一切踏まない（24/24 green は新機能の証拠にならない）。よって
#   「遅い子」「孫が stdout を保持する子」「孫が副作用を残す子」の 3 fixture を実走させ、上界・打ち切り表示・
#   実装形の拘束（file sink / --foreground 禁止 / deadline 方式）を各 1 mutation で RED 化する。

@test "(B1) 予算: 遅い子 1 本を per-child bound で打ち切り、専用 loud 行が出て他 5 節は完全（fail-open 文言 0 hit）" {
    make_all_stubs make_budget_fast_stub
    make_budget_slow_stub "$PLUGIN/scripts/orch-degraded-watch.sh" S2 30
    local t0 out el
    t0=$SECONDS; out="$(hook_stdout_budget "$SCRIPT" 2 60)"; el=$((SECONDS - t0))
    [ "$el" -le 8 ]                                   # 子の hang(30s)へ引きずられない＝per-child bound が効いた
    [[ "$out" == *"打ち切り"* ]]                       # 打ち切りは loud（専用行）
    [[ "$out" == *"orch-degraded-watch.sh"* ]]         # 全件 pointer が実行時変数から組まれている
    [[ "$out" != *"fail-open"* ]]                      # 既存の共通文言を再利用していない（「壊れた」と区別可能）
    [[ "$out" == *"S2REC001"* ]]                       # 打ち切っても部分出力は保持する
    # 打ち切られた節の外は完全（見出し + 本文）＝部分縮退しない
    [[ "$out" == *"(1) gate-pending"* ]]
    [[ "$out" == *"(2) degraded-watch"* ]]
    [[ "$out" == *"(3) needs-orch handoff"* ]]
    [[ "$out" == *"(4) 配送観測"* ]]
    [[ "$out" == *"(5) re-ratify sweep"* ]]
    local t
    for t in S1 S3 S4 S5 S6; do
        [[ "$out" == *"${t}REC001"* ]]
        [[ "$out" == *"${t}REC003"* ]]
    done
}

@test "(B2) 予算: 6 子とも hang でも総予算 deadline 内に完了し全節が生存 — deadline を外す mutation で RED" {
    make_all_stubs make_budget_slow_stub 30
    local t0 out el
    t0=$SECONDS; out="$(hook_stdout_budget "$SCRIPT" 2 2)"; el=$((SECONDS - t0))
    [ "$el" -le 8 ]                                   # 総予算 2 秒 + 組立の余裕（per-child のみなら 6×2=12s 級）
    [[ "$out" == *"(1) gate-pending"* ]]
    [[ "$out" == *"(2) degraded-watch"* ]]
    [[ "$out" == *"(3) needs-orch handoff"* ]]
    [[ "$out" == *"(4) 配送観測"* ]]
    [[ "$out" == *"(5) re-ratify sweep"* ]]
    [ "$(grep -c '打ち切り' <<<"$out")" -ge 2 ]        # per-child kill と 総予算枯渇 の両 mode が出る
    [[ "$out" == *"総予算"* ]]                         # 予算が尽きた残 block は **実行せず** 打ち切っている
    # mutation: cap を deadline 残時間から算出するのをやめる（per-child 上限のみ）→ 6 子直列で総予算を大幅超過。
    local mut out2 t1 el2
    mut="$(make_mutant 's|.*# DEADLINE-DERIVED.*|        _rem="$WIP_CHILD_TIMEOUT"|' D)"
    t1=$SECONDS; out2="$(hook_stdout_budget "$mut" 2 2)"; el2=$((SECONDS - t1))
    [ -n "$out2" ]                                    # mutant が死んでいない（構文破壊の偽 RED を排除）
    [ "$el2" -ge 9 ]                                  # 総予算方式が load-bearing（per-child だけでは 6T になる）
}

@test "(B3) 予算: timeout 呼出を外す mutation で打ち切りが消え上界が破れる（degrade 自体は fail-open で出力継続）" {
    make_all_stubs make_budget_fast_stub
    make_budget_slow_stub "$PLUGIN/scripts/orch-dispatch.sh" S1 8
    local t0 out el
    t0=$SECONDS; out="$(hook_stdout_budget "$SCRIPT" 2 60)"; el=$((SECONDS - t0))
    [ "$el" -le 6 ]
    [[ "$out" == *"打ち切り"* ]]
    local mut out2 t1 el2
    mut="$(make_mutant 's|.*# TIMEOUT-PROBE.*|    _use_to=0|' T)"
    t1=$SECONDS; out2="$(hook_stdout_budget "$mut" 2 60)"; el2=$((SECONDS - t1))
    [[ "$out2" != *"打ち切り"* ]]                      # 上界が無い＝打ち切りが起きない
    [ "$el2" -ge 7 ]                                  # 子の hang(8s)へ丸ごと引きずられる
    [[ "$out2" == *"S2REC001"* ]]                     # timeout 不在 degrade でも他節は出る（fail-open）
    # ★上界が実際に消える唯一の経路（timeout 不在 × sink 成功）が **silent にならない** ことを pin する。
    #   これが無いと「打ち切りが消えた」だけを見て degrade 行の不在を PASS 扱いする vacuity になり、運用者には
    #   『総予算到達により打ち切り』しか見えず per-child bound 無効化の因果が読めない（self-review major-1）。
    [[ "$out2" == *"劣化"* ]]                          # degrade 自体が loud（noto mode の 1 行が出る）
    [[ "$out2" == *"無効"* ]]                          # 「上限は無効」＝上界喪失を明示している
    [[ "$out2" != *"一時 file 不能"* ]]                # sink は成功しているので bare の原因文言を流用しない
}

@test "(B4) 予算: --foreground を付ける mutation で孫が完走する（プロセスグループごとの終端が load-bearing）" {
    local mk="$TEST_TMPDIR/gc-marker"
    make_all_stubs make_budget_fast_stub
    make_budget_marker_stub "$PLUGIN/scripts/orch-dispatch.sh" S1 "$mk" 3
    rm -f "$mk"
    hook_stdout_budget "$SCRIPT" 1 60 > /dev/null
    sleep 5
    [ ! -e "$mk" ]                                    # 健全形: 孫も終端され marker は作られない
    local mut
    mut="$(make_mutant 's|timeout -k|timeout --foreground -k|' F)"
    rm -f "$mk"
    hook_stdout_budget "$mut" 1 60 > /dev/null
    sleep 5
    [ -e "$mk" ]                                      # mutant: 孫が生き残り完走（■3(2) の禁止が load-bearing）
    rm -f "$mk"
}

@test "(B5) 予算: 孫が stdout を保持しても本体は待たない（file sink）— sink を外す mutation で子が実行されなくなる" {
    make_all_stubs make_budget_fast_stub
    make_budget_gc_stub "$PLUGIN/scripts/orch-dispatch.sh" S1 8
    local t0 out el
    t0=$SECONDS; out="$(hook_stdout_budget "$SCRIPT" 30 120)"; el=$((SECONDS - t0))
    [ "$el" -le 5 ]                                   # 孫(8s)へ引きずられない
    [[ "$out" == *"S1REC001"* ]]
    [[ "$out" != *"打ち切り"* ]]                       # 子は即 exit＝timeout は未発火（sink だけが効いている）
    [[ "$out" != *"劣化"* ]]                           # 正規経路（mktemp 成功）＝degrade を false-loud に出さない
    # mutation: sink 取得を丸ごと潰す → 子は「上界を保証できない」ため **実行されない**（禁止形へは落ちない）。
    #   ★旧実装はここで `_raw="$(timeout N 子)"` へ落ち、孫が stdout を保持する型で per-child bound と総予算
    #     deadline が同時に失効していた（＝上界喪失が silent）。その経路が消えたことを el2 で実測する。
    local mut out2 t1 el2
    mut="$(make_mutant 's|.*# TMPFILE-SINK.*|    _f=""|' S)"
    t1=$SECONDS; out2="$(hook_stdout_budget "$mut" 30 120)"; el2=$((SECONDS - t1))
    [ -n "$out2" ]                                    # mutant が死んでいない（sink 不能でも節は出る＝fail-open）
    [ "$el2" -le 5 ]                                  # 禁止形へ落ちない（孫の寿命ぶん解放されない形を採らない）
    [[ "$out2" == *"上界を保証できないため未実行"* ]]   # 未実行を loud に告げる
    [[ "$out2" != *"S1REC001"* ]]                     # sink 無しでは子を走らせない＝sink が load-bearing
}

@test "(B6) 予算: 打ち切り行は過負荷 + hard-cap 下でも残る — 専用文言 / rank-A marker を外す mutation で RED" {
    make_all_stubs make_allprio_stub
    make_budget_allprio_slow_stub "$PLUGIN/scripts/orch-degraded-watch.sh" S2 30
    local out
    out="$(hook_stdout_budget "$SCRIPT" 1 60)"
    [[ "$out" == *"打ち切り"* ]]                       # trim + hard-cap を通っても打ち切り行が残る
    [ "$(u16_of "$out")" -le 9800 ]                   # 予算保証は維持
    # mutation A: 専用文言を既存の共通文言へ戻す → 「打ち切った」と「壊れた」が区別できなくなる。
    local mut out2
    mut="$(make_mutant 's|秒で打ち切り＝表示は部分・全件|秒・skip＝fail-open・全件|' W)"
    out2="$(hook_stdout_budget "$mut" 1 60)"
    [ -n "$out2" ]
    [[ "$out2" != *"打ち切り"* ]]
    # mutation B: rank-A marker（⚠ 警告）を外す → 節予算の先取りから漏れ、過負荷下で打ち切り行が落ちる。
    mut="$(make_mutant 's|  ⚠ 警告: %s を %s 秒で打ち切り|  %s を %s 秒で打ち切り|' R)"
    out2="$(hook_stdout_budget "$mut" 1 60)"
    [ -n "$out2" ]
    [[ "$out2" != *"打ち切り"* ]]
}

@test "(B7) wire: workinprogress timeout が [120,600] の整数・他 entry 不変・総予算 × 係数 以上（値の SSOT は hook 定数行）" {
    # ★数値の二重持ちを作らない: 総予算の既定値と係数は hook script の定数行 1 箇所が SSOT で、本 test はそこを
    #   読んで **算術関係**（wire 秒値 >= 総予算 × 係数）を照合する。literal 一致 assert は置かない。
    cat > "$TEST_TMPDIR/wirechk.py" <<'PY'
import json, re, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                                  # valid JSON でなければ die
ss = [h for g in d.get("hooks", {}).get("SessionStart", []) for h in g.get("hooks", [])]
pre = [h for g in d.get("hooks", {}).get("PreToolUse", []) for h in g.get("hooks", [])]
wip = [h for h in ss if "session-start-workinprogress.sh" in h.get("command", "")]
if len(wip) != 1:
    print("FAIL: SessionStart の workinprogress wire が 1 本でない:", len(wip)); sys.exit(1)
t = wip[0].get("timeout")
if not isinstance(t, int) or isinstance(t, bool):
    print("FAIL: timeout が整数でない:", repr(t)); sys.exit(1)
if not (120 <= t <= 600):
    print("FAIL: timeout(秒) が [120,600] の外:", t); sys.exit(1)
others = [h.get("timeout") for h in ss + pre if h is not wip[0]]
if len(others) != 5 or any(x != 10000 for x in others):
    print("FAIL: workinprogress 以外の 5 entry の timeout が不変でない:", others); sys.exit(1)
src = open(hook_path, encoding="utf-8").read()
mb = re.search(r'^WIP_TOTAL_BUDGET="\$\{WIP_TOTAL_BUDGET:-(\d+)\}"', src, re.M)
mf = re.search(r'^WIP_WIRE_FACTOR=(\d+)', src, re.M)
if not mb or not mf:
    print("FAIL: hook script から 総予算既定 / 係数 を読めない（値の SSOT 行が消えた）"); sys.exit(1)
budget, factor = int(mb.group(1)), int(mf.group(1))
if t < budget * factor:
    print("FAIL: wire 秒値 %d < 総予算 %d × 係数 %d" % (t, budget, factor)); sys.exit(1)
print("OK: timeout=%ds ∈[120,600]・他 5 entry 不変・%d >= 総予算 %d × 係数 %d" % (t, t, budget, factor))
PY
    run python3 "$TEST_TMPDIR/wirechk.py" "$HOOKS_JSON" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
    # mutation: wire 秒値を総予算未満へ落とす → RED（算術 assert が vacuous でない）。
    python3 - "$HOOKS_JSON" "$TEST_TMPDIR/mut-hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d["hooks"]["SessionStart"]:
    for h in g["hooks"]:
        if "session-start-workinprogress.sh" in h.get("command", ""):
            h["timeout"] = 100
json.dump(d, open(sys.argv[2], "w"))
PY
    run python3 "$TEST_TMPDIR/wirechk.py" "$TEST_TMPDIR/mut-hooks.json" "$SCRIPT"
    [ "$status" -ne 0 ]
}

@test "(B8) 予算: mktemp 不能でも決定論 path の sink で上界を保ち degrade を loud に出す — fallback を外す mutation で RED" {
    # ★degrade 経路が「上界ごと捨てる」形だと、B1-B7 は全 green のまま per-child bound + 総予算 deadline が
    #   同時に無効化される（deadline は実行前の cap 判定しか効かず、実行中の hang を切れない）。しかも従来形は
    #   degrade したこと自体が出力に現れない＝silent。mktemp 不能は TMPDIR が read-only / 容量枯渇 / sandbox
    #   制限のとき現実に踏む経路なので、fake mktemp fixture で実挙動として踏む。sink を諦めずに決定論 path で
    #   再取得することで、この degrade クラスでも **正規経路（timeout + file sink）のまま** 上界を保つ。
    make_all_stubs make_budget_fast_stub
    make_budget_slow_stub "$PLUGIN/scripts/orch-degraded-watch.sh" S2 8
    make_fake_mktemp_fail
    local t0 out el
    t0=$SECONDS; out="$(hook_stdout_budget_nosink "$SCRIPT" 2 60)"; el=$((SECONDS - t0))
    [ "$el" -le 6 ]                                   # sink 不能でも per-child bound は生きている（8s hang へ引きずられない）
    [[ "$out" == *"打ち切り"* ]]                       # 上界が効いた証拠（degrade しても打ち切りは起きる）
    [[ "$out" == *"劣化"* ]]                           # degrade 自体が loud（silent に上界が落ちない）
    [[ "$out" == *"S2REC001"* ]]                       # 打ち切っても部分出力は保持
    [[ "$out" == *"S1REC001"* ]]                       # 他節は完全（fail-open）
    [[ "$out" == *"(2) degraded-watch"* ]]
    # mutation A: 決定論 path の fallback を潰す（mktemp 失敗だけで sink を諦める形）→ 上界を保証できず子は
    #   未実行になり、部分出力も打ち切り行も消える＝fallback が load-bearing（「動いているのに出力が出る」を
    #   保つのは fallback 側）。
    local mut out2 t1 el2
    mut="$(make_mutant 's|.*# SINK-FALLBACK.*|    while [ 0 -eq 1 ]; do|' K)"
    t1=$SECONDS; out2="$(hook_stdout_budget_nosink "$mut" 2 60)"; el2=$((SECONDS - t1))
    [ -n "$out2" ]                                    # mutant が死んでいない（構文破壊の偽 RED を排除）
    [ "$el2" -le 6 ]                                  # 禁止形へは落ちない（上界は破らない側へ倒れる）
    [[ "$out2" == *"上界を保証できないため未実行"* ]]
    [[ "$out2" != *"S2REC001"* ]]
    [[ "$out2" != *"打ち切り"* ]]
    # mutation B: 正規経路から timeout を外す → sink は在るが上界が消え、子の hang(8s)へ丸ごと引きずられる。
    local mut2 out3 t2 el3
    mut2="$(make_mutant 's|timeout -k "$WIP_KILL_GRACE" "$_cap" "$_script" "$@" >"$_f" 2>/dev/null|"$_script" "$@" >"$_f" 2>/dev/null|' K2)"
    t2=$SECONDS; out3="$(hook_stdout_budget_nosink "$mut2" 2 60)"; el3=$((SECONDS - t2))
    [ -n "$out3" ]
    [ "$el3" -ge 7 ]                                  # per-child bound が消えた（timeout が load-bearing）
    [[ "$out3" != *"打ち切り"* ]]
}

@test "(B9) 予算: sink 全滅でも禁止形へ落ちない — 孫が stdout を保持する子でも総予算内に完了（禁止形へ戻す mutation で RED）" {
    # ★本 case が要る理由（B8 では踏めない残余）: sink が作れないときに `_raw="$(timeout N 子)"` へ落ちると、
    #   「子は cap より前に exit するが孫が stdout を保持する」型で timeout はシグナルを一切送らず、bash は孫が
    #   持つ pipe の EOF を待ち続ける＝rc=0（_WIP_CUT=0・打ち切り行なし）で per-child bound と総予算 deadline が
    #   **同時に** 失効する。B8 の fixture（子自身が hang）ではこの型を踏めないため、gc stub × sink 全滅の組を
    #   独立 case として置く（fence A2 の第 3 種 fixture を予算 degrade 経路にも通す）。
    make_all_stubs make_budget_fast_stub
    make_budget_gc_stub "$PLUGIN/scripts/orch-dispatch.sh" S1 8
    make_fake_mktemp_fail
    local t0 out el
    t0=$SECONDS; out="$(hook_stdout_budget_nosink_hard "$SCRIPT" 2 6)"; el=$((SECONDS - t0))
    [ "$el" -le 5 ]                                   # 総予算 6 秒 + ε 内（孫 8s へ延伸しない）
    [[ "$out" == *"上界を保証できないため未実行"* ]]   # 上界を保証できない子は走らせず loud に告げる
    [[ "$out" != *"S1REC001"* ]]                      # 禁止形で走らせていない
    [[ "$out" == *"(1) gate-pending"* ]]              # 節は全て生存（fail-open は保つ）
    [[ "$out" == *"(2) degraded-watch"* ]]
    [[ "$out" == *"(3) needs-orch handoff"* ]]
    [[ "$out" == *"(4) 配送観測"* ]]
    [[ "$out" == *"(5) re-ratify sweep"* ]]
    # mutation: 未実行の判断を禁止形（command substitution + timeout）へ戻す → 孫が stdout を保持する型で
    #   総予算が破れ、打ち切り行も出ないまま hook が孫の寿命ぶんブロックする。
    local mut out2 t1 el2
    mut="$(make_mutant 's%.*# NOSINK-REFUSE.*%            _WIP_RAW="$(timeout -k "$WIP_KILL_GRACE" "$_cap" "$_script" "$@" 2>/dev/null)" || _WIP_RC=$?%' N)"
    t1=$SECONDS; out2="$(hook_stdout_budget_nosink_hard "$mut" 2 6)"; el2=$((SECONDS - t1))
    [ -n "$out2" ]                                    # mutant が死んでいない（構文破壊の偽 RED を排除）
    [ "$el2" -ge 7 ]                                  # 禁止形は孫の寿命ぶん解放されない＝総予算 6 秒を破る
}

@test "(B10) 予算: timeout 不在 × sink 全滅（bare）でも出力は続き degrade が loud — bare を潰す mutation で RED" {
    # ★上界が本当に消える唯一の経路（fence ■3(3) が degrade を許す条件）を behavior として pin する。ここが
    #   無いと `_WIP_DEGRADE=bare` を丸ごと潰しても全 test green のまま「静かに上界が落ちる」形へ退行できる
    #   （self-review minor: 実測で mutation が生存していた）。bare は noto（sink は在る）と原因が違うので、
    #   原因文言まで含めて pin する＝運用者に誤った原因を告げない。
    make_all_stubs make_budget_fast_stub
    make_fake_mktemp_fail
    make_no_timeout_path
    local out
    out="$(hook_stdout_budget_bare "$SCRIPT" 2 60)"
    [ -n "$out" ]                                     # 上界は無いが session は壊さない（fail-open）
    [[ "$out" == *"S1REC001"* ]]                      # 子は実行され出力も出る
    [[ "$out" == *"(5) re-ratify sweep"* ]]           # 全節が生存
    [[ "$out" == *"劣化"* ]]                           # degrade が loud
    [[ "$out" == *"一時 file 不能"* ]]                 # bare の原因文言（noto の「timeout 不在につき」と区別）
    [[ "$out" == *"無効"* ]]                           # 上限が無効化された事実を明示
    [[ "$out" != *"打ち切り"* ]]                       # 上界が無いので打ち切りは起きない（誤表示しない）
    # mutation: bare を立てない（= 上界喪失が silent になる）→ degrade 行が消える。
    local mut out2
    mut="$(make_mutant 's|^            _WIP_DEGRADE=bare|            :|' Q)"
    out2="$(hook_stdout_budget_bare "$mut" 2 60)"
    [ -n "$out2" ]                                    # mutant が死んでいない（構文破壊の偽 RED を排除）
    [[ "$out2" == *"S1REC001"* ]]                     # 出力は同じに出る＝差は degrade 行の有無だけ
    [[ "$out2" != *"劣化"* ]]
}

@test "(B11) 予算: 壊れた子（rc≠0・非打ち切り）は既存 fail-open 理由行で報告される — 当該分岐を潰す mutation で RED" {
    # ★「予算で打ち切った」と「子が壊れた」を区別する契約（fence ■6）は 2 方向で歯が要る。打ち切り側は
    #   B1/B6 が見ているが、非0終了側は分岐を丸ごと潰しても全 test green だった（self-review minor）。
    make_all_stubs make_budget_fast_stub
    make_budget_rc_stub "$PLUGIN/scripts/orch-handoff-scan.sh" S3 3
    local out
    out="$(hook_stdout_budget "$SCRIPT" 2 60)"
    [[ "$out" == *"S3REC001"* ]]                      # 部分出力は保持する
    [[ "$out" == *"が非0終了・skip＝fail-open"* ]]     # 壊れた子は既存の共通文言で報告
    [[ "$out" != *"打ち切り"* ]]                       # 予算で切ったわけではない（誤表示しない）
    [[ "$out" != *"劣化"* ]]                           # degrade でもない
    [[ "$out" == *"S1REC001"* ]]                      # 他節は継続（部分縮退しない）
    local mut out2
    mut="$(make_mutant 's|elif \[ "$_rc" -ne 0 \]; then|elif [ "$_rc" -ne 0 ] \&\& [ 0 -eq 1 ]; then|' V)"
    out2="$(hook_stdout_budget "$mut" 2 60)"
    [ -n "$out2" ]                                    # mutant が死んでいない
    [[ "$out2" == *"S3REC001"* ]]                     # 出力は同じ＝差は理由行の有無だけ
    [[ "$out2" != *"が非0終了・skip＝fail-open"* ]]
}

@test "(wire) hooks.json が workinprogress を spec-inject/guard-health と同形 fail-safe で SessionStart へ wire" {
    run python3 - "$HOOKS_JSON" "$SCRIPT" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                 # valid JSON でなければ die
ss = d.get("hooks", {}).get("SessionStart", [])
cmds = [h.get("command", "") for g in ss for h in g.get("hooks", [])]
wip = [c for c in cmds if "session-start-workinprogress.sh" in c]
if not wip:
    print("FAIL: SessionStart に workinprogress wire が無い"); sys.exit(1)
c = wip[0]
if "|| true" not in c:
    print("FAIL: workinprogress wire が spec-inject/guard-health と同形 fail-safe(|| true)でない"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: workinprogress wire は fail-safe・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "(syntax) bash -n(構文)が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

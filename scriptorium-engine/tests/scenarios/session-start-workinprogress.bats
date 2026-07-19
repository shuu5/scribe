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
    chmod +x "$PLUGIN/scripts/orch-dispatch.sh" "$PLUGIN/scripts/orch-degraded-watch.sh" \
             "$PLUGIN/scripts/orch-handoff-scan.sh" "$PLUGIN/scripts/orch-delivery-observe.sh"

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

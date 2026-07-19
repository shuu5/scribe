#!/usr/bin/env bats
# tests/scenarios/fleet-monitor-board.bats
#
# fleet-monitor.sh タスクボード再設計（un-chz / un-jax 吸収）の決定的テスト。
#
# 方式: bd / tmux / git を PATH スタブで差し替え、実スクリプトを `--once`(PLAIN) で
#   実行して clean capture を assert する E2E。bd 一時 DB は使えないため fixture 注入。
#   ANCHOR は FLEET_MONITOR_ANCHOR で固定（git worktree list を経由させない）。
#
# 検証する設計不変条件（bd un-chz description = ratify 済契約）:
#   (1) 5 セクション見出し（●稼働中 / ▶次にやるべき / ★検品待ち / ⚠要議論 / ─残）の存在
#   (1d) 5 セクション見出しが規定の描画順で並ぶ（存在だけでなく順序を機械 assert＝doc-order drift 検出・orch-cuq）
#   (1b) ★検品待ち: gate-pending ラベル issue が出る・●稼働中には出ない（disjoint・D1）
#   (1e) gate-pending+needs-user 併存 issue は ⚠要議論のみ（★検品待ちには出ない＝両ラベル二重表示の解消・orch-cuq）
#   (1c) 窓消失マーカー: in_progress + 窓不在 → age に関わらず ✗ 可視警報（grill L2 是正・sc-3pq/orch-nzd/
#        orch-r22）。旧 D4「古い/不明 → ◇ 無音良性化」は time-cap silent 降格バグゆえ撤回。age は annotation のみ。
#   (2) in_progress 行に worker↔window 照合マーク（◆=worker 検出 / ✗=窓消失 in_progress の可視警報）
#   (3) window 名 wt-<完全bd id> の完全一致照合のみ点灯＝誤検出ゼロ
#       - wt-un-aaa → un-aaa 点灯 / wt-un-aa は un-aaa を点灯させない（部分一致しない）
#       - pane cwd が anchor へ逃げても window 名で点灯（un-jax 改善案 b の核心）
#       - worker 不在の in_progress は ✗ 可視警報（grill L2・窓消失を無音良性化しない）
#   (4) needs-user ラベル issue が要議論節に出る（次にやるべき節には出ない＝節は disjoint）
#   (5) 残行に open 総数 + P 別内訳
#   (6) thread:* 論点ボードの完全廃止（"thread:" / "論点" を描画しない）
#   (8) 🔑 鍵失効警告（上流由来を canonical へ port・orch-150）: 状態ファイル WARN/CRIT のみ header 直下に 1 行表示。
#        OK/ファイル不在は無表示（timer 未配備の全ホストで noise ゼロ）・長要約は 48 幅 truncate（render-gate）。
#
# 実行: bats tests/scenarios/fleet-monitor-board.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/fleet-monitor.sh"
    TEST_TMPDIR=$(mktemp -d -t fleet-board-bats-XXXXXX)
    export FIX_DIR="$TEST_TMPDIR"
    export ANCHOR="$TEST_TMPDIR/anchor"
    mkdir -p "$ANCHOR/.worktrees"
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    # ── 🔑 鍵失効警告の状態ファイルを temp path に固定（orch-150）────
    #   既定 path（${XDG_RUNTIME_DIR:-/tmp}/tailnet-expiry.status）だと実環境の偶発ファイルに
    #   依存し非 hermetic。temp path へ向けて既定で不在にし、各 🔑 テストがここへ level を書く。
    export TAILNET_EXPIRY_STATE_FILE="$TEST_TMPDIR/tailnet-expiry.status"

    # ── stall 判定の時刻固定（age = NOW_EPOCH - updated_at）────────
    #   NOW_EPOCH を固定し、updated_at を「直近(stall)」「100日前(古い epic)」で生成して決定的に。
    #   既定閾値 FLEET_MONITOR_STALL_MINS=360（=21600 秒）は明示設定せず default 経路も検証する。
    export FLEET_MONITOR_NOW_EPOCH=1750000000
    local recent_iso old_iso
    recent_iso=$(date -u -d "@$((1750000000 - 300))" +%Y-%m-%dT%H:%M:%SZ)       # 5 分前 → ✗(stall)
    old_iso=$(date -u -d "@$((1750000000 - 8640000))" +%Y-%m-%dT%H:%M:%SZ)      # 100 日前 → ◇

    # ── fixture: bd list（open/in_progress/blocked）─────────────
    #   open=7（rdy1-6 + disc）/ in_progress=7（aaa,bbb,ccc,ddd,gate,stall,oldepic）
    #   稼働中に出るのは gate-pending を除いた 6（gate は ★検品待ちへ disjoint 振り分け）
    #   P 内訳(open): P0:1(rdy1) P1:0 P2:2(rdy2,rdy3) P3:3(rdy4,rdy5,disc) P4:1(rdy6)
    #   un-gate  : in_progress + gate-pending → ★検品待ちのみ・●稼働中には出ない（disjoint）
    #   un-stall : in_progress + 窓不在 + updated_at 直近 → ✗(窓消失 5m)
    #   un-oldepic: in_progress + 窓不在 + updated_at 100日前 → ✗(窓消失・cap超)（grill L2 是正・旧 ◇ 無音降格を撤回）
    #   un-bbb   : in_progress + 窓不在 + updated_at 無し → ✗(窓消失・時刻不明)（grill L2・age 不明でも無音化しない）
    cat > "$TEST_TMPDIR/list.json" <<JSON
[
 {"id":"un-aaa","status":"in_progress","priority":2,"labels":[],"title":"稼働中タスクA"},
 {"id":"un-bbb","status":"in_progress","priority":2,"labels":[],"title":"稼働中タスクB ワーカー無し"},
 {"id":"un-ccc","status":"in_progress","priority":1,"labels":[],"title":"稼働中タスクC cwd は anchor"},
 {"id":"un-ddd","status":"in_progress","priority":2,"labels":[],"title":"稼働中タスクD path のみ照合"},
 {"id":"un-gate","status":"in_progress","priority":2,"labels":["gate-pending"],"updated_at":"$recent_iso","title":"検品待ちタスク gate 待ち"},
 {"id":"un-stall","status":"in_progress","priority":2,"labels":[],"updated_at":"$recent_iso","title":"stall タスク 窓消失"},
 {"id":"un-oldepic","status":"in_progress","priority":3,"labels":[],"updated_at":"$old_iso","title":"admin epic 古い"},
 {"id":"un-rdy1","status":"open","priority":0,"labels":[],"title":"次やる1"},
 {"id":"un-rdy2","status":"open","priority":2,"labels":["thread:fleet"],"title":"次やる2 ラベル付き"},
 {"id":"un-rdy3","status":"open","priority":2,"labels":[],"title":"次やる3"},
 {"id":"un-rdy4","status":"open","priority":3,"labels":[],"title":"次やる4"},
 {"id":"un-rdy5","status":"open","priority":3,"labels":[],"title":"次やる5"},
 {"id":"un-rdy6","status":"open","priority":4,"labels":[],"title":"次やる6 cap で除外"},
 {"id":"un-disc","status":"open","priority":3,"labels":["needs-user"],"updated_at":"$recent_iso","title":"要議論タスク"}
]
JSON

    # ── fixture: bd ready（in_progress 除外済の ready 集合）──────
    #   needs-user(un-disc) は含むが python 側で要議論へ振り分け除外。
    #   非 needs-user の ready が 6 件＝top5 cap 検証（un-rdy6 が溢れる）。
    cat > "$TEST_TMPDIR/ready.json" <<'JSON'
[
 {"id":"un-rdy1","status":"open","priority":0,"labels":[],"title":"次やる1"},
 {"id":"un-rdy2","status":"open","priority":2,"labels":["thread:fleet"],"title":"次やる2 ラベル付き"},
 {"id":"un-rdy3","status":"open","priority":2,"labels":[],"title":"次やる3"},
 {"id":"un-rdy4","status":"open","priority":3,"labels":[],"title":"次やる4"},
 {"id":"un-rdy5","status":"open","priority":3,"labels":[],"title":"次やる5"},
 {"id":"un-rdy6","status":"open","priority":4,"labels":[],"title":"次やる6 cap で除外"},
 {"id":"un-disc","status":"open","priority":3,"labels":["needs-user"],"title":"要議論タスク"}
]
JSON

    # ── fixture: tmux パネル一覧（window_name|pane_current_path）──
    #   wt-un-aaa : window+path 両方で un-aaa を照合（ラベルは window 名優先）
    #   wt-un-ccc : pane cwd は anchor（path 信号なし）だが window 名で un-ccc 点灯
    #   bash      : window 名は wt- でない（窓信号なし）が path で un-ddd 点灯（path-only 照合）
    #   wt-un-aa  : 部分一致の罠（un-aaa を誤点灯させてはいけない）
    #   wt-foobar : 無関係 worktree（issue id 不一致）
    #   main      : wt- 接頭辞なし＝無視
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
wt-un-aaa|$ANCHOR/.worktrees/spawn/un-aaa-111111
wt-un-ccc|$ANCHOR
bash|$ANCHOR/.worktrees/spawn/un-ddd-333333
wt-un-aa|/elsewhere/dir
wt-foobar|$ANCHOR/.worktrees/spawn/foobar-222222
main|$ANCHOR
EOF

    # ── stub: bd ───────────────────────────────────────────────
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  ready) cat "$FIX_DIR/ready.json" ;;
  list)  cat "$FIX_DIR/list.json" ;;
esac
exit 0
STUB

    # ── stub: tmux ─────────────────────────────────────────────
    cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    all=0
    for a in "$@"; do [ "$a" = "-a" ] && all=1; done
    [ "$all" = 1 ] && cat "$FIX_DIR/panes.txt"
    ;;
  has-session)    exit 0 ;;
  display-message) echo "testsess" ;;
esac
exit 0
STUB

    # ── stub: git（anchor は常に clean）────────────────────────
    cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
# 'git -C <dir> status --porcelain' → 出力なし＝clean
exit 0
STUB

    chmod +x "$BIN/bd" "$BIN/tmux" "$BIN/git"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# fleet-monitor.sh を fixture 環境で --once 実行し output を返す
run_board() {
    PATH="$BIN:$PATH" FLEET_MONITOR_ANCHOR="$ANCHOR" \
        run bash "$SCRIPT" --once --session testsess
    [ "$status" -eq 0 ]
}

# ==============================================================================
# (1) 5 セクション見出しの存在
# ==============================================================================

@test "5 セクション見出し（稼働中/次にやるべき/検品待ち/要議論/残）が全て出る" {
    run_board
    [[ "$output" == *"稼働中"* ]]
    [[ "$output" == *"次にやるべき"* ]]
    [[ "$output" == *"検品待ち"* ]]
    [[ "$output" == *"要議論"* ]]
    [[ "$output" == *"残:"* ]]
}

# ------------------------------------------------------------------------------
# (1d) 5 セクション見出しが規定の描画順で並ぶ（存在だけでなく順序を機械 assert）
#   既存テストは見出しの『存在』だけを検査し『順序』を保証しない（cell-quality WF が
#   doc-order drift を指摘した経緯）。各見出しの記号+語の固有並びで行番号を取り厳密昇順を assert。
#   見出しは「記号+半角空白+語」で行頭に出るためタスク行（2字下げ+別記号）とは衝突しない:
#     '● 稼働中' / '▶ 次にやるべき' / '★ 検品待ち' / '⚠ 要議論' / '─ 残:'
#   （タスク title に『検品待ち』『要議論』が含まれても、見出し固有並びには一致しない）。
# ------------------------------------------------------------------------------

@test "(1d) 5 セクション見出しが規定の描画順（稼働中→次→検品待ち→要議論→残）で並ぶ" {
    run_board
    local n_head n_next n_gate n_disc n_rem
    n_head=$(printf '%s\n' "$output" | grep -nF '● 稼働中'      | head -1 | cut -d: -f1)
    n_next=$(printf '%s\n' "$output" | grep -nF '▶ 次にやるべき' | head -1 | cut -d: -f1)
    n_gate=$(printf '%s\n' "$output" | grep -nF '★ 検品待ち'    | head -1 | cut -d: -f1)
    n_disc=$(printf '%s\n' "$output" | grep -nF '⚠ 要議論'      | head -1 | cut -d: -f1)
    n_rem=$(printf  '%s\n' "$output" | grep -nF '─ 残:'         | head -1 | cut -d: -f1)
    # 全 5 見出しが検出される（非空＝存在保証）。各 assert は独立行にして bats の set -e で個別に
    # fail-close させる（'&&' 連鎖だと bash errexit が非末尾コマンドを免除し、見出し欠落を
    # この行で落とせず後続の数値比較頼みになる＝コメントと実装が乖離する。独立行なら空変数で即 fail）。
    [ -n "$n_head" ]
    [ -n "$n_next" ]
    [ -n "$n_gate" ]
    [ -n "$n_disc" ]
    [ -n "$n_rem" ]
    # 厳密昇順（描画順保証＝drift で 1 つでも入れ替わると落ちる）
    [ "$n_head" -lt "$n_next" ]
    [ "$n_next" -lt "$n_gate" ]
    [ "$n_gate" -lt "$n_disc" ]
    [ "$n_disc" -lt "$n_rem" ]
}

# ==============================================================================
# (2)(3) worker↔window 照合：完全一致のみ点灯＝誤検出ゼロ
# ==============================================================================

@test "稼働中: window 完全一致の in_progress は ◆ で点灯（un-aaa）" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-aaa')
    [[ "$line" == *"◆"* ]]
    # window+path 両信号一致時もラベルは window 名(wt-un-aaa)を優先表示する
    [[ "$line" == *"wt-un-aaa"* ]]
}

@test "稼働中: pane cwd が anchor でも window 名で点灯（un-ccc / un-jax 改善案 b）" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-ccc')
    [[ "$line" == *"◆"* ]]
    # window 名 wt-un-ccc がラベル表示される（path 信号なしの純 window 照合）
    [[ "$line" == *"wt-un-ccc"* ]]
}

@test "稼働中: worker 不在の in_progress は ✗ 可視警報（grill L2・窓消失を無音良性化しない）" {
    # grill L2（sc-3pq/orch-nzd/orch-r22）: 窓消失した in_progress cell は age に関わらず可視警報 ✗。
    # 旧契約「worker 不在→◇ 無警報」は time-cap silent 降格バグゆえ撤回（un-bbb は updated_at 無しでも ✗）。
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-bbb')
    [[ "$line" == *"✗"* ]]
    [[ "$line" != *"◆"* ]]
    [[ "$line" != *"◇"* ]]
    # age 不明でも無音化しない annotation（時刻不明）
    [[ "$line" == *"窓消失・時刻不明"* ]]
}

@test "誤検出ゼロ: wt-un-aa は un-aaa を点灯させない（部分一致しない）＝◆ は厳密に 3 個" {
    run_board
    # 点灯するのは un-aaa(window+path) / un-ccc(window) / un-ddd(path) の 3 件のみ。
    # wt-un-aa / wt-foobar / main は誤点灯しない。
    local marks; marks=$(printf '%s\n' "$output" | grep -o '◆' | wc -l)
    [ "$marks" -eq 3 ]
}

@test "path-only 照合: window 名不一致でも worktree パス一致で点灯（un-ddd・ラベルは worktree 名）" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-ddd')
    [[ "$line" == *"◆"* ]]
    # window 由来ラベルが無いので path 由来の worktree セグメント名を表示
    [[ "$line" == *"un-ddd-333333"* ]]
}

@test "回帰(Blocking1): 稼働中節の行数が表示 in_progress 件数(6)と厳密一致＝裸行混入なし" {
    run_board
    # ● 稼働中 と ▶ 次にやるべき の見出し間 = 稼働中に出る in_progress 行のみ。
    # in_progress は 7 件だが gate-pending(un-gate)は ★検品待ちへ disjoint 振り分けで除外 → 6 行。
    # label 2 行値バグ(awk exit→END 二重出力)や age 列の read 取りこぼし(裸行混入)があると行数が増える。
    local section
    section=$(printf '%s\n' "$output" | sed -n '/稼働中/,/次にやるべき/p' | sed '1d;$d')
    local n; n=$(printf '%s\n' "$section" | grep -c .)
    [ "$n" -eq 6 ]
    # window+path 両一致の un-aaa で裸の worktree 名(un-aaa-111111)が単独行になっていないこと
    printf '%s\n' "$output" | grep -qx 'un-aaa-111111' && return 1
    # age 列(数字のみ)が裸行として独立していないこと（read 受け取り変数の取りこぼし回帰）
    printf '%s\n' "$output" | grep -qxE '[0-9]+' && return 1
    return 0
}

# ==============================================================================
# (1b) ★検品待ち：gate-pending ラベル。●稼働中とは disjoint（D1）
# ==============================================================================

@test "検品待ち: gate-pending ラベルの un-gate が ★検品待ちに出る" {
    run_board
    [[ "$output" == *"検品待ち"* ]]
    local line; line=$(printf '%s\n' "$output" | grep 'un-gate')
    [[ "$line" == *"★"* ]]
}

@test "disjoint: gate-pending(un-gate) は ●稼働中に出ない（出現は全体で 1 回＝検品待ちのみ）" {
    run_board
    # in_progress だが gate-pending なので稼働中から除外され、検品待ちに 1 回だけ出る。
    local n; n=$(printf '%s\n' "$output" | grep -c 'un-gate')
    [ "$n" -eq 1 ]
    # 稼働中節（稼働中→次にやるべき間）に un-gate が無いこと
    local section
    section=$(printf '%s\n' "$output" | sed -n '/稼働中/,/次にやるべき/p')
    printf '%s\n' "$section" | grep -q 'un-gate' && return 1
    return 0
}

# ------------------------------------------------------------------------------
# (1e) 両ラベル併存（gate-pending かつ needs-user）の二重表示解消
#   per-label routing は正しいが、両ラベルを持つ issue は ★検品待ち と ⚠要議論 の両方に出る
#   良性冗長があった。needs-user 優先で ⚠要議論 に一本化する（needs-user=人間判断が未決着＝
#   gate 不能ゆえ next-action は議論）。主 fixture を汚さない（◆/✗/open 厳密数を保つ）よう
#   この test 内で両ラベル issue の最小 list を注入する（「stall(負 age)」テストと同じ作法）。
# ------------------------------------------------------------------------------

@test "(1e) 両ラベル disjoint: gate-pending+needs-user 併存は ⚠要議論のみ（★検品待ち/●稼働中に出ない）" {
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-both","status":"in_progress","priority":2,"labels":["gate-pending","needs-user"],"title":"両ラベル併存 issue"}
]
JSON
    run_board
    # 全体で 1 回だけ出現（二重表示の解消＝良性冗長なし）
    local n; n=$(printf '%s\n' "$output" | grep -c 'un-both')
    [ "$n" -eq 1 ]
    # ⚠要議論 節（要議論→残 間）に出る＝一本化先
    local disc_section
    disc_section=$(printf '%s\n' "$output" | sed -n '/⚠ 要議論/,/─ 残:/p')
    printf '%s\n' "$disc_section" | grep -q 'un-both'
    # ★検品待ち 節（検品待ち→要議論 間）には出ない（needs-user 優先で除外）
    local gate_section
    gate_section=$(printf '%s\n' "$output" | sed -n '/★ 検品待ち/,/⚠ 要議論/p')
    printf '%s\n' "$gate_section" | grep -q 'un-both' && return 1
    # ●稼働中 節（稼働中→次にやるべき 間）にも出ない（in_progress だが gate-pending で除外）
    local ip_section
    ip_section=$(printf '%s\n' "$output" | sed -n '/● 稼働中/,/▶ 次にやるべき/p')
    printf '%s\n' "$ip_section" | grep -q 'un-both' && return 1
    return 0
}

# ==============================================================================
# (1c) 窓消失マーカー：in_progress + 窓不在 → age に関わらず ✗ 可視警報（grill L2 是正）
#   旧契約（D4）= 窓不在 + updated_at 直近 → ✗ / age 超過・不明 → ◇（無音良性化）。
#   grill L2（sc-3pq/orch-nzd/orch-r22）で ★time-cap silent 降格は撤回★: 窓消失した in_progress cell は
#   age に関わらず ✗（可視警報）。age は annotation のみ（直近=分数 / cap超=「cap超・死亡濃厚」/ 不明=「時刻不明」）。
#   6h 超 stall（=むしろ死亡濃厚）を age だけで ◇ に黙って降格していた folio 同型バグを塞ぐ。
# ==============================================================================

@test "窓消失: 窓不在 + updated_at 直近(5分前)の un-stall は ✗ で点灯（◆/◇ ではない）" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-stall')
    [[ "$line" == *"✗"* ]]
    [[ "$line" != *"◆"* ]]
    [[ "$line" != *"◇"* ]]
    # age 注釈: NOW_EPOCH-300秒(=5分前)なので『窓消失 5m』と分換算(age/60)が出る。
    # 注釈テキスト・分換算が壊れても緑になる被覆抜けを塞ぐ（completeness-critic 指摘）。
    [[ "$line" == *"窓消失 5m"* ]]
}

@test "窓消失(grill L2 是正): 窓不在 + updated_at 100日前の un-oldepic も ✗ 可視警報（旧 ◇ 無音降格を撤回）" {
    # ★是正の核★: 旧契約は age > STALL_MINS(360分) で ✗→◇ に黙って降格し、6h 超 stall した cell の
    # 警報を silent に消していた（folio incident 同型）。grill L2 で age に関わらず ✗（可視警報）に統一。
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-oldepic')
    [[ "$line" == *"✗"* ]]
    [[ "$line" != *"◇"* ]]
    # cap 超過は annotation で明示（無音化せず「死亡濃厚」を可視化）
    [[ "$line" == *"cap超"* ]]
}

@test "窓消失(grill L2 是正): updated_at の無い窓不在 in_progress(un-bbb)も ✗ 可視警報（age 不明でも無音化しない）" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-bbb')
    [[ "$line" == *"✗"* ]]
    [[ "$line" != *"◇"* ]]
    [[ "$line" == *"窓消失・時刻不明"* ]]
}

@test "窓消失 ✗ は窓不在 in_progress 3 件全て（un-stall/un-oldepic/un-bbb・age に関わらず可視）" {
    # grill L2 是正で ✗ 件数 1→3: 窓不在 in_progress（un-bbb 不明 / un-stall 直近 / un-oldepic 古い）は
    # age に関わらず全て ✗。旧契約は直近の un-stall のみ ✗（他 2 件を age で ◇ に無音降格）だった。
    # 窓あり in_progress（un-aaa/un-ccc/un-ddd=◆）と gate-pending(un-gate=★) には ✗ が付かない。
    run_board
    local marks; marks=$(printf '%s\n' "$output" | grep -o '✗' | wc -l)
    [ "$marks" -eq 3 ]
    # ◇ は窓消失分岐から退役＝稼働中節で 1 つも出ない（silent 良性化の撤回を機械 pin）
    local diamonds; diamonds=$(printf '%s\n' "$output" | grep -o '◇' | wc -l)
    [ "$diamonds" -eq 0 ]
}

@test "stall(負 age): updated_at が未来(時計ズレ)でも ✗ 算術が壊れず 0m にクランプされる" {
    # 主 fixture を汚さない（◆/✗ 厳密数を保つ）よう、この test 内で未来 updated_at の最小 list を注入。
    # 負 age（now < updated_at）は ◇ 握り潰しでなく ✗(過剰警報＝安全側)に倒れ、分換算は (age<0?0:age)/60 で 0m にクランプ。
    local future_iso; future_iso=$(date -u -d "@$((1750000000 + 600))" +%Y-%m-%dT%H:%M:%SZ)
    cat > "$TEST_TMPDIR/list.json" <<JSON
[
 {"id":"un-future","status":"in_progress","priority":2,"labels":[],"updated_at":"$future_iso","title":"未来 updated_at 時計ズレ"}
]
JSON
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-future')
    [[ "$line" == *"✗"* ]]
    # 0m にクランプ（負分『-10m』等にならない・算術エラーで行が崩れない）
    [[ "$line" == *"窓消失 0m"* ]]
}

# ==============================================================================
# (4) 次にやるべき：bd ready 上位5（in_progress 除外・priority 順・needs-user 除外）
# ==============================================================================

@test "次にやるべき: ready 上位5 が出て 6 番目(un-rdy6)は cap で溢れる" {
    run_board
    [[ "$output" == *"un-rdy1"* ]]
    [[ "$output" == *"un-rdy5"* ]]
    # 6 件目は top5 cap で描画されない（どのセクションにも出ない＝残カウントのみ）
    [[ "$output" != *"un-rdy6"* ]]
}

@test "次にやるべき: 最高優先(P0)の un-rdy1 が priority 順で描画される" {
    run_board
    [[ "$output" == *"un-rdy1"* ]]
    # P0 表示を伴う
    local line; line=$(printf '%s\n' "$output" | grep 'un-rdy1')
    [[ "$line" == *"P0"* ]]
}

# ==============================================================================
# (5) 要議論：needs-user ラベル。次にやるべき節とは disjoint
# ==============================================================================

@test "要議論: needs-user ラベルの un-disc が出る（出現は全体で 1 回＝要議論のみ）" {
    run_board
    [[ "$output" == *"un-disc"* ]]
    # needs-user は次にやるべき節から除外されるため出現は要議論節の 1 回のみ
    local n; n=$(printf '%s\n' "$output" | grep -c 'un-disc')
    [ "$n" -eq 1 ]
}

# ==============================================================================
# (6) 残行：open 総数 + P 別内訳
# ==============================================================================

@test "残行: open 総数(7)と P 別内訳を含む" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep '残:')
    [[ "$line" == *"open=7"* ]]
    [[ "$line" == *"P0:1"* ]]
    [[ "$line" == *"P2:2"* ]]
    [[ "$line" == *"P3:3"* ]]
    [[ "$line" == *"P4:1"* ]]
}

# ==============================================================================
# (7) thread:* 論点ボードの完全廃止
# ==============================================================================

@test "thread:* 論点ボードが廃止されている（thread: ラベルも 論点 という語も描画しない）" {
    run_board
    [[ "$output" != *"thread:"* ]]
    [[ "$output" != *"論点"* ]]
}

@test "フォールバック: bd 不在でもクラッシュせず代替表示する（fail-open・hermetic）" {
    # hermetic bin: 必須コアのみ symlink + git/tmux スタブ。bd は一切置かない。
    # PATH をこの dir のみに限定するので、fleet ホストの /usr/bin に bd があっても実 bd に漏れない
    #（旧 PATH narrowing 版は /usr/bin を含み非 hermetic だった＝Minor1 修正）。
    local HBIN="$TEST_TMPDIR/hbin"; mkdir -p "$HBIN"
    local b p
    for b in bash readlink dirname date awk grep wc cat sed sort head python3 env; do
        p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$HBIN/$b"
    done
    cp "$BIN/tmux" "$BIN/git" "$HBIN/"   # スタブのみ流用（bd は流用しない）
    [ ! -e "$HBIN/bd" ]                  # hermetic 保証: bd は存在しない
    PATH="$HBIN" FLEET_MONITOR_ANCHOR="$ANCHOR" \
        run bash "$SCRIPT" --once --session testsess
    # 落ちずに exit 0、4 見出しは出し、bd 不在のフォールバック文言を表示
    [ "$status" -eq 0 ]
    [[ "$output" == *"稼働中"* ]]
    [[ "$output" == *"次にやるべき"* ]]
    [[ "$output" == *"検品待ち"* ]]
    [[ "$output" == *"要議論"* ]]
    [[ "$output" == *"残:"* ]]
    [[ "$output" == *"不在"* ]]
}

@test "PLAIN 出力にカーソル制御エスケープが混入しない（--once clean capture）" {
    run_board
    # \033[H / \033[J / \033[K が出ないこと（plain capture の不変条件）
    printf '%s' "$output" | grep -q $'\033' && return 1
    return 0
}

# ==============================================================================
# (8) 🔑 鍵失効警告（tailnet-expiry-check.sh 由来・上流由来を canonical へ port・orch-150）
#   header 直下の条件付き 1 行警告。状態ファイル(TAILNET_EXPIRY_STATE_FILE)を read するだけ:
#     WARN/CRIT → 1 行表示 / OK・ファイル不在 → 無表示（全ホスト配布 canonical でも noise ゼロ）。
#   setup で TAILNET_EXPIRY_STATE_FILE を temp path に固定済み（既定は不在＝実環境非依存 hermetic）。
# ==============================================================================

@test "(8) 🔑: 状態ファイル WARN で鍵失効警告が 1 行表示される（level+要約+誘導文）" {
    printf 'WARN\t残り3日で失効\t1750000000\n' > "$TAILNET_EXPIRY_STATE_FILE"
    run_board
    local line; line=$(printf '%s\n' "$output" | grep '🔑')
    [ -n "$line" ]
    [[ "$line" == *"WARN"* ]]
    [[ "$line" == *"残り3日で失効"* ]]
    [[ "$line" == *"Disable key expiry"* ]]
}

@test "(8) 🔑: 状態ファイル CRIT でも鍵失効警告が表示される" {
    printf 'CRIT\t明日失効\t1750000000\n' > "$TAILNET_EXPIRY_STATE_FILE"
    run_board
    local line; line=$(printf '%s\n' "$output" | grep '🔑')
    [ -n "$line" ]
    [[ "$line" == *"CRIT"* ]]
    [[ "$line" == *"明日失効"* ]]
}

@test "(8) 🔑: OK レベルは無表示（平時は不変＝noise を出さない）" {
    printf 'OK\t十分猶予あり\t1750000000\n' > "$TAILNET_EXPIRY_STATE_FILE"
    run_board
    [[ "$output" != *"🔑"* ]]
}

@test "(8) 🔑: 状態ファイル不在なら無表示（timer 未配備の全ホストで noise ゼロ＝canonical port の安全性）" {
    rm -f "$TAILNET_EXPIRY_STATE_FILE"
    [ ! -e "$TAILNET_EXPIRY_STATE_FILE" ]
    run_board
    [[ "$output" != *"🔑"* ]]
}

@test "(8) 🔑: header 直下（● 稼働中 より前）に描画される（配置順＝faithful port の位置）" {
    printf 'WARN\t残り3日\t1750000000\n' > "$TAILNET_EXPIRY_STATE_FILE"
    run_board
    local n_key n_head
    n_key=$(printf  '%s\n' "$output" | grep -nF '🔑'      | head -1 | cut -d: -f1)
    n_head=$(printf '%s\n' "$output" | grep -nF '● 稼働中' | head -1 | cut -d: -f1)
    [ -n "$n_key" ]
    [ -n "$n_head" ]
    [ "$n_key" -lt "$n_head" ]
}

@test "(8) 🔑: TAILNET_EXPIRY_STATE_FILE env override が効く（別 path を read）" {
    local alt="$TEST_TMPDIR/alt-tailnet.status"
    printf 'CRIT\t別pathの失効警告\t1750000000\n' > "$alt"
    rm -f "$TAILNET_EXPIRY_STATE_FILE"   # 既定 path は空にし override 先だけに警告を置く
    PATH="$BIN:$PATH" FLEET_MONITOR_ANCHOR="$ANCHOR" TAILNET_EXPIRY_STATE_FILE="$alt" \
        run bash "$SCRIPT" --once --session testsess
    [ "$status" -eq 0 ]
    [[ "$output" == *"別pathの失効警告"* ]]
}

@test "(8) 🔑: 長い要約でも 48 幅で truncate され原文全体は出ない（render-gate・幾何崩れ無し）" {
    # 全角100文字の要約。truncate_str で 48 幅 + … に切り詰められ、原文全体は行に出ない。
    local longsum; longsum=$(printf 'あ%.0s' {1..100})
    printf 'WARN\t%s\t1750000000\n' "$longsum" > "$TAILNET_EXPIRY_STATE_FILE"
    run_board
    local line; line=$(printf '%s\n' "$output" | grep '🔑')
    [ -n "$line" ]
    [[ "$line" == *"…"* ]]           # 切り詰め発生（省略記号）
    [[ "$line" != *"$longsum"* ]]    # 原文全体（100文字）はそのまま出ない
}

# ==============================================================================
# (9) ★検品待ち / ⚠要議論 の待ち時間表示（updated_at からの経過・orch-edv T3）
#   silent mutual-wait deadlock を人間がボードで一目で捉えられるよう、gate-pending / needs-user 行末に
#   待ち時間（now - updated_at）を表示する。fixture: un-gate（gate-pending）と un-disc（needs-user）はともに
#   updated_at=recent_iso（NOW_EPOCH-300秒＝5分前）ゆえ『待ち 5m』が出る。updated_at 不明は非表示（誤表示回避）。
# ==============================================================================

@test "(9) 待ち時間: ★検品待ち(gate-pending) の un-gate 行に updated_at からの経過『待ち 5m』が出る" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-gate')
    [[ "$line" == *"★"* ]]
    [[ "$line" == *"待ち 5m"* ]]     # NOW_EPOCH-300秒(=5分前)→ 300/60=5m
}

@test "(9) 待ち時間: ⚠要議論(needs-user) の un-disc 行に updated_at からの経過『待ち 5m』が出る" {
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-disc')
    [[ "$line" == *"⚠"* ]]
    [[ "$line" == *"待ち 5m"* ]]
}

@test "(9) 待ち時間: updated_at 不明の gate-pending 行は待ち時間を表示しない（誤表示回避）" {
    # 主 fixture を汚さず、この test 内で updated_at 無しの gate-pending 最小 list を注入（stall 系 test と同作法）。
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-noage","status":"in_progress","priority":2,"labels":["gate-pending"],"title":"updated_at 無し gate-pending"}
]
JSON
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-noage')
    [[ "$line" == *"★"* ]]
    [[ "$line" != *"待ち"* ]]        # updated_at 不明ゆえ待ち時間は出さない（"?" や負値を出さない）
}

@test "(9) 待ち時間: 長時間(2h5m)は時分表記『待ち 2h05m』で出る（大きな経過の可読性）" {
    local old_iso; old_iso=$(date -u -d "@$((1750000000 - 7500))" +%Y-%m-%dT%H:%M:%SZ)   # 125 分前 = 2h5m
    cat > "$TEST_TMPDIR/list.json" <<JSON
[
 {"id":"un-long","status":"in_progress","priority":2,"labels":["gate-pending"],"updated_at":"$old_iso","title":"長時間 gate 待ち"}
]
JSON
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-long')
    [[ "$line" == *"待ち 2h05m"* ]]
}

@test "(9) 待ち時間: 未来 updated_at(時計ズレ)でも待ち時間が壊れず 0m にクランプ（負値を出さない）" {
    local future_iso; future_iso=$(date -u -d "@$((1750000000 + 600))" +%Y-%m-%dT%H:%M:%SZ)
    cat > "$TEST_TMPDIR/list.json" <<JSON
[
 {"id":"un-fut","status":"in_progress","priority":2,"labels":["gate-pending"],"updated_at":"$future_iso","title":"未来 updated_at"}
]
JSON
    run_board
    local line; line=$(printf '%s\n' "$output" | grep 'un-fut')
    [[ "$line" == *"待ち 0m"* ]]     # 負 age は 0m にクランプ（"-10m" 等にならない）
}

@test "(9) 待ち時間（回帰・裸行なし）: age 列追加後も ★/⚠ 行が裸の数字行に割れない（read 変数の取りこぼし防止）" {
    # gatepending は id<TAB>title<TAB>age（3列）/ needsuser は id<TAB>status<TAB>title<TAB>age（4列）。
    # read 受け取り変数が emit 列数と一致していないと age が裸行として混入し in-place 描画が崩れる。
    run_board
    # ★検品待ち節（検品待ち→要議論 間）と ⚠要議論節（要議論→残 間）に裸の数字だけの行が無いこと。
    local gate_section disc_section
    gate_section=$(printf '%s\n' "$output" | sed -n '/★ 検品待ち/,/⚠ 要議論/p')
    disc_section=$(printf '%s\n' "$output" | sed -n '/⚠ 要議論/,/─ 残:/p')
    printf '%s\n' "$gate_section" | grep -qxE '[0-9]+' && return 1
    printf '%s\n' "$disc_section" | grep -qxE '[0-9]+' && return 1
    return 0
}

# ==============================================================================
# (10) 🔍 grill 待ち：needs-grill bead ＋ 対応 consult-<id> 窓の有無を完全一致照合で可視化（orch-89pw）
#   方式A（user ratify 2026-07-10）: consult-<grill-issue> 窓を対応 grill bead と id 完全一致で照合し点灯する
#   （wt- と同型機構）。grill 進行中 bead（needs-grill 平ラベル完全一致・非 closed）に対し:
#     - 対応 consult-<id> 窓あり → ◆consult（対話中）で点灯
#     - 窓なし               → consult窓なし（中断の可能性＝notice のみ・断定しない）
#   plain consult（consult-HHMMSS・id 非含有）は剥いた残りが bead id と完全一致しないため対象外（誤点灯ゼロ）。
#   sentinel 固定（orchestrator 裁定）: 点灯側=「◆consult」/ 窓なし側=「consult窓なし」を grep で mutation RED 実証。
#   主 fixture を汚さない（◆/✗/open 厳密数を保つ）よう各 test 内で needs-grill 最小 list + consult 窓 panes を注入。
#   grill 節（🔍 grill→─残 間）へ scope して稼働中/ready への同 id 副次出現と混同しない。
# ==============================================================================

@test "(10) consult 点灯: needs-grill bead + consult-<id> 窓 → ◆consult（完全一致・sentinel）" {
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-grl","status":"in_progress","priority":2,"labels":["needs-grill"],"title":"grill 対象タスク"}
]
JSON
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-un-grl|$ANCHOR
EOF
    run_board
    # 🔍 grill 節（🔍 grill→─残 間）へ scope（稼働中の ✗ 副次行と混同しない）
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    local line; line=$(printf '%s\n' "$gsec" | grep 'un-grl')
    [[ "$line" == *"◆consult"* ]]        # 点灯 sentinel（mutation RED）
    [[ "$line" == *"consult-un-grl"* ]]  # 完全一致した consult 窓ラベル
    [[ "$line" != *"consult窓なし"* ]]   # 窓ありなので窓なし側は出ない
}

@test "(10) 窓なし可視化: needs-grill bead + consult 窓なし → consult窓なし（notice・sentinel）" {
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-nowin","status":"in_progress","priority":2,"labels":["needs-grill"],"title":"grill 対象・窓なし"}
]
JSON
    # consult 窓を一切置かない panes（wt- も無し）
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
main|$ANCHOR
EOF
    run_board
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    local line; line=$(printf '%s\n' "$gsec" | grep 'un-nowin')
    [[ "$line" == *"consult窓なし"* ]]   # 窓なし sentinel（mutation RED）
    [[ "$line" != *"◆consult"* ]]        # 窓なしなので点灯 sentinel は出ない
    [[ "$line" == *"中断"* ]]            # 中断の可能性 notice を可視化（断定表現でない）
}

@test "(10) 完全一致規律: consult-un-grl 窓は un-grla（部分一致 bead）を点灯させない" {
    # bead id = un-grla、consult 窓 = consult-un-grl（un-grl 剥がれ）。部分一致で点灯してはいけない。
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-grla","status":"in_progress","priority":2,"labels":["needs-grill"],"title":"部分一致の罠 bead"}
]
JSON
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-un-grl|$ANCHOR
EOF
    run_board
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    local line; line=$(printf '%s\n' "$gsec" | grep 'un-grla')
    [[ "$line" == *"consult窓なし"* ]]   # 部分一致では点灯せず窓なし扱い（誤検出ゼロ）
    [[ "$line" != *"◆consult"* ]]
}

@test "(10) 完全一致規律(逆方向): consult-un-grla 窓は un-grl（bead id が window id の接頭辞）を点灯させない" {
    # gate errata（orchestrator relay）: grill 照合 $1==k を $1~k へ緩めても既存 suite が全 green で生き延びた実測。
    # 既存 test は『窓 id が bead id より長い』forward 方向のみ pin し、逆方向＝bead id が window id の接頭辞に
    # なるケースが未 pin だった。ここを塞ぐ: bead un-grl(needs-grill) に対し、別の長い bead 由来の
    # consult-un-grla 窓のみ生存 → un-grl は 窓なし にならねばならない（un-grla != un-grl の完全一致規律）。
    # $1~k 変異では『un-grla ~ /un-grl/』が substring 一致し un-grl を誤点灯するため、本 tooth が RED になる。
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-grl","status":"in_progress","priority":2,"labels":["needs-grill"],"title":"逆方向 完全一致 bead"}
]
JSON
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-un-grla|$ANCHOR
EOF
    run_board
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    local line; line=$(printf '%s\n' "$gsec" | grep 'un-grl')
    [[ "$line" == *"consult窓なし"* ]]   # 完全一致のみ点灯＝bead が window の接頭辞でも点灯しない
    [[ "$line" != *"◆consult"* ]]        # $1~k 変異ならここが ◆consult になり RED（逆方向 pin）
    [[ "$line" != *"consult-un-grla"* ]] # 別 bead の窓ラベルが漏れ込まない（誤照合ゼロ）
}

@test "(10) plain consult 対象外: consult-HHMMSS 窓は needs-grill bead を点灯させない（id 非含有）" {
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-grl","status":"in_progress","priority":2,"labels":["needs-grill"],"title":"grill 対象タスク"}
]
JSON
    # plain consult（HHMMSS・bd id 非含有）のみ。un-grl とは完全一致しない。
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-142339|$ANCHOR
EOF
    run_board
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    local line; line=$(printf '%s\n' "$gsec" | grep 'un-grl')
    [[ "$line" == *"consult窓なし"* ]]   # plain consult は照合対象外ゆえ窓なし
    [[ "$line" != *"◆consult"* ]]
    # plain consult 窓は grill 節に独自行を作らない（needs-grill bead のみ列挙・142339 行が出ない）
    printf '%s\n' "$gsec" | grep -q '142339' && return 1
    return 0
}

@test "(10) needs-grill 無し / closed は grill 節に出ない（(なし) 表示・非終端限定）" {
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-done","status":"closed","priority":2,"labels":["needs-grill"],"title":"grill 済 closed"},
 {"id":"un-plain","status":"in_progress","priority":2,"labels":[],"title":"needs-grill 無し"}
]
JSON
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-un-done|$ANCHOR
main|$ANCHOR
EOF
    run_board
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    # closed の needs-grill(un-done) は非終端限定ゆえ出ない・needs-grill 無し(un-plain)も出ない
    printf '%s\n' "$gsec" | grep -q 'un-done' && return 1
    printf '%s\n' "$gsec" | grep -q 'un-plain' && return 1
    # 対象 0 件ゆえ (なし) を表示
    [[ "$gsec" == *"(なし)"* ]]
    return 0
}

@test "(10) grill 節は ⚠要議論 と ─残 の間に描画される（配置順・(1d) 5 見出しは不変）" {
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-grl","status":"in_progress","priority":2,"labels":["needs-grill"],"title":"grill 対象タスク"}
]
JSON
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-un-grl|$ANCHOR
EOF
    run_board
    local n_disc n_grill n_rem
    n_disc=$(printf  '%s\n' "$output" | grep -nF '⚠ 要議論'  | head -1 | cut -d: -f1)
    n_grill=$(printf '%s\n' "$output" | grep -nF '🔍 grill'  | head -1 | cut -d: -f1)
    n_rem=$(printf   '%s\n' "$output" | grep -nF '─ 残:'     | head -1 | cut -d: -f1)
    [ -n "$n_disc" ]
    [ -n "$n_grill" ]
    [ -n "$n_rem" ]
    [ "$n_disc" -lt "$n_grill" ]
    [ "$n_grill" -lt "$n_rem" ]
}

@test "(10) 稼働中不変: consult 窓のみ(worker 窓なし)の in_progress は稼働中で ✗（consult ラベル非混入）" {
    # needs-grill in_progress bead が consult 窓のみ持つ場合、稼働中節では worker 窓不在ゆえ ✗ に倒す
    # （consult- 候補が稼働中の worker ラベルへ混入して誤 ◆ 点灯しないことの回帰）。
    cat > "$TEST_TMPDIR/list.json" <<'JSON'
[
 {"id":"un-grl","status":"in_progress","priority":2,"labels":["needs-grill"],"updated_at":"2026-06-19T05:40:00Z","title":"grill 対象・worker 窓なし"}
]
JSON
    cat > "$TEST_TMPDIR/panes.txt" <<EOF
consult-un-grl|$ANCHOR
EOF
    run_board
    # 稼働中節（稼働中→次にやるべき 間）で un-grl は ✗（consult- がラベルに混じって ◆ にならない）
    local ipsec; ipsec=$(printf '%s\n' "$output" | sed -n '/● 稼働中/,/▶ 次にやるべき/p')
    local ipline; ipline=$(printf '%s\n' "$ipsec" | grep 'un-grl')
    [[ "$ipline" == *"✗"* ]]
    [[ "$ipline" != *"◆"* ]]
    [[ "$ipline" != *"consult-un-grl"* ]]  # consult ラベルが稼働中の worker 窓ラベルへ混入しない
    # 一方 grill 節では ◆consult で点灯する（同 bead を二軸で正しく表示）
    local gsec; gsec=$(printf '%s\n' "$output" | sed -n '/🔍 grill/,/─ 残:/p')
    local gline; gline=$(printf '%s\n' "$gsec" | grep 'un-grl')
    [[ "$gline" == *"◆consult"* ]]
}

# ==============================================================================
# (ANCHOR) 共有 lib orch_anchor.sh 経由の動的 anchor 解決（orch-49g・env override 無し）
#   fleet-monitor は旧 inline resolve_anchor から共有 lib の _resolve_scriptorium（E2 anchor 検証付き）へ移行した。
#   全既存 test は FLEET_MONITOR_ANCHOR override ゆえ lib-source/動的解決経路が 1 本も exercise されていなかった穴を塞ぐ:
#   (resolve) git 解決した orch 台帳 anchor は E2 検証を通り採用され board が render する（真陽性を落とさない）。
#   (E2reject) foreign 台帳 anchor は E2 検証で reject → ANCHOR 空 → loud exit1（fleet-monitor は hardcode fallback を
#     持たない＝human-facing tool は foreign repo の board を silent 誤 render するより loud fail-closed が正しい）。
# ==============================================================================
_install_wtlist_git_stub() {  # $1 = worktree list 先頭に返す candidate path
    cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-C" ]; then shift 2; fi
if [ "\$1 \$2" = "worktree list" ]; then printf 'worktree %s\n' "$1"; exit 0; fi
exit 0
EOF
    chmod +x "$BIN/git"
}

@test "(ANCHOR-resolve) env override 無し: git 解決した orch 台帳 anchor を共有 lib が採用し board が render（orch-49g）" {
    local OANCHOR="$TEST_TMPDIR/resolved-orch-anchor"
    mkdir -p "$OANCHOR/.beads" "$OANCHOR/.worktrees"
    printf '{"dolt_database":"orch"}' > "$OANCHOR/.beads/metadata.json"
    _install_wtlist_git_stub "$OANCHOR"
    # FLEET_MONITOR_ANCHOR を渡さない＝_resolve_scriptorium（E2 検証）経由でのみ anchor を解決する。
    PATH="$BIN:$PATH" run bash "$SCRIPT" --once --session testsess
    [ "$status" -eq 0 ]
    [[ "$output" == *"稼働中"* ]]   # 解決成功＝board が render した（真陽性を落とさない）
}

@test "(ANCHOR-E2reject) env override 無し: foreign 台帳 anchor は E2 検証で reject → ANCHOR 空→loud exit1（orch-49g・非vacuity）" {
    local FANCHOR="$TEST_TMPDIR/resolved-foreign-anchor"
    mkdir -p "$FANCHOR/.beads" "$FANCHOR/.worktrees"
    printf '{"dolt_database":"un"}' > "$FANCHOR/.beads/metadata.json"
    _install_wtlist_git_stub "$FANCHOR"
    # E2 reject → ANCHOR 空 → 既存の空 ANCHOR check が loud fail-closed（非vacuity: 検証を外すと FANCHOR を採用し exit0 で render）。
    PATH="$BIN:$PATH" run bash "$SCRIPT" --once --session testsess
    [ "$status" -ne 0 ]
    [[ "$output" == *"ANCHOR を解決できません"* ]]
}

# ==============================================================================
# (ANCHOR-libabsent) orch_anchor.sh 不在は warn→空 ANCHOR check で fail-closed exit1（orch-49g errata E2）
#   fleet-monitor の lib source は fail-open（warn→continue）だが、_resolve_scriptorium 未定義→ANCHOR 空→
#   既存の空 ANCHOR check が loud exit1 に倒す（fall-through fail-closed を pin）。
# ==============================================================================
@test "(ANCHOR-libabsent) 共有 anchor lib 不在は warn→空 ANCHOR→fail-closed exit1（orch-49g errata E2）" {
    local SB="$TEST_TMPDIR/sb-nolib"; mkdir -p "$SB"
    cp "$SCRIPT" "$SB/fleet-monitor.sh"   # lib/orch_anchor.sh を置かない
    # FLEET_MONITOR_ANCHOR を渡さない → _resolve_scriptorium 未定義 → ANCHOR 空 → 空 ANCHOR check が exit1。
    PATH="$BIN:$PATH" run bash "$SB/fleet-monitor.sh" --once --session testsess
    [ "$status" -ne 0 ]
    [[ "$output" == *"共有 anchor lib 不在"* || "$output" == *"ANCHOR を解決できません"* ]]
}

#!/usr/bin/env bats
# tests/tmux-send-keys-guard.bats
#
# PreToolUse[Bash] hook（scripts/hooks/tmux-send-keys-guard.py・sc-164 transport 構造封鎖 B）の
# **e2e（stdin JSON → exit code / stderr の実フック契約）** と **hooks.json wire 検査** の hermetic bats。
#
# 契約: 管理窓（非 'wt-' window）への生 tmux transport を exit2 で block し scribe-inject 経由へ funnel する。
#   worker 窓（wt-*）への steering・capture-pane（監視 read）は封鎖対象外。foreign(orch) session は no-op。
# sc-2g3: 対象 transport を send-keys 以外へ拡張（paste-buffer / load-buffer / run-shell / pipe-pane -I ＋
#   payload に transport を包む exec carrier の再帰）。(k*) が sc-2g3 の e2e、(a)-(j) は sc-164 の非干渉 pin。
#
# 方式（hermetic・実 plugin/tmux server 非依存）:
#   - 台帳 fixture: temp に scribe(dolt_database=sc) と foreign(dolt_database=orch) の .beads/metadata.json。
#   - cmdtokens: 実トークナイザが要る（stub iter_commands=[] では send-keys を検出できない）ため、残置 local
#     lib（$REPO/scripts/hooks/lib）を CMDTOKENS_LIB で指す（guard の override 経路を実走）。
#   - tmux: SCRIBE_TMUX で stub へ差し替え。socket probe と `-t` の window 名解決を canned で返す。
#   - hook を JSON payload を stdin に流して subprocess 実行し $status と $output(stderr 併合)を assert する。
#
# 実行: bats tests/tmux-send-keys-guard.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$REPO/scripts/hooks/tmux-send-keys-guard.py"
    HOOKS_JSON="$REPO/hooks/hooks.json"
    CT_LIB="$REPO/scripts/hooks/lib"   # 実トークナイザ（残置 local cmdtokens.py）

    TEST_TMPDIR="$(mktemp -d -t scribe-tmux-guard-bats-XXXXXX)"

    # 台帳 fixture: scribe(self) / foreign(orch)。walk-up で dolt_database を解決。
    SCRIBE_LEDGER="$TEST_TMPDIR/scribe"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$SCRIBE_LEDGER/.beads" "$SCRIBE_LEDGER/sub" "$FOREIGN/.beads" "$FOREIGN/sub"
    printf '{"database":"dolt","dolt_database":"sc"}'   > "$SCRIBE_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$FOREIGN/.beads/metadata.json"
    SCRIBE_CWD="$SCRIBE_LEDGER/sub"
    FOREIGN_CWD="$FOREIGN/sub"

    # present-but-unreadable 台帳 fixture（`.beads/metadata.json` は在るが JSON parse 不能）。
    # guard 側 _is_scribe_guard_session の **fail-closed**（self とみなし発火）を pin するための唯一の
    # 自動 coverage（bd-write-guard 撤去=un-2uap Leg-R-sc により、この非対称を叩く他テストが消えた）。
    BROKEN="$TEST_TMPDIR/broken"
    mkdir -p "$BROKEN/.beads" "$BROKEN/sub"
    printf '{invalid' > "$BROKEN/.beads/metadata.json"
    BROKEN_CWD="$BROKEN/sub"

    # ②側（＝『parse 失敗ではない識別不能』）台帳 fixture 群。上の BROKEN(①)と**意図的に非対称**で、
    # いずれも False=fail-open（他 project を一切 brick しない・②不変厳守＝scribe_session.py:125 docstring）
    # を要求する。①(d2)の fail-closed を広げすぎて②まで True 化する過剰補正を捕捉する回帰 pin であり、
    # bd-write-guard 撤去(un-2uap Leg-R-sc)で消えた旧 scope_cases の ② 3 分岐を回復する。
    #   BARE    : walk-up 上に `.beads/metadata.json` が皆無（無関係 project / git 外）
    #   NONDICT : parse 成功だが非 dict
    #   NOKEY   : dict だが dolt_database キー欠落
    BARE="$TEST_TMPDIR/bare"
    mkdir -p "$BARE/sub"
    BARE_CWD="$BARE/sub"
    NONDICT="$TEST_TMPDIR/nondict"
    mkdir -p "$NONDICT/.beads" "$NONDICT/sub"
    printf '[1,2,3]' > "$NONDICT/.beads/metadata.json"
    NONDICT_CWD="$NONDICT/sub"
    NOKEY="$TEST_TMPDIR/nokey"
    mkdir -p "$NOKEY/.beads" "$NOKEY/sub"
    printf '{"database":"dolt"}' > "$NOKEY/.beads/metadata.json"
    NOKEY_CWD="$NOKEY/sub"

    # stub tmux（到達可）: @3/admin:0→'admin'(管理窓)・@7→'wt-sc-1'(worker 窓)・他→解決失敗(exit1)。
    #   guard が引く display-message の `-t`(target-pane) と `-c`(target-client・load-buffer 用) の両方を解決する。
    TMUX_OK="$TEST_TMPDIR/tmux-reachable"
    cat > "$TMUX_OK" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in *"#{socket_path}"*) echo /tmp/stub-sock; exit 0 ;; esac
tgt=""; prev=""
for a in "$@"; do case "$prev" in -t|-c) tgt="$a" ;; esac; prev="$a"; done
case "$tgt" in
  @3|admin*)  echo "admin";   exit 0 ;;
  @7)         echo "wt-sc-1"; exit 0 ;;
  /dev/pts/9) echo "admin";   exit 0 ;;   # client(管理窓を見ている)
  /dev/pts/7) echo "wt-sc-1"; exit 0 ;;   # client(worker 窓を見ている)
  *)          exit 1 ;;
esac
EOF
    chmod +x "$TMUX_OK"

    # stub tmux（到達不能）: socket probe も含め全て exit1。
    TMUX_UNREACH="$TEST_TMPDIR/tmux-unreachable"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMUX_UNREACH"
    chmod +x "$TMUX_UNREACH"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# hook を実フック経路（stdin JSON → exit/stderr）で起動。stderr を stdout に併合して $output で assert する。
run_guard() {
    local cwd="$1" cmd="$2" tmux="${3:-$TMUX_OK}"
    printf '{"tool_input":{"command":%s},"cwd":"%s"}' "$(_json "$cmd")" "$cwd" \
      | CMDTOKENS_LIB="$CT_LIB" SCRIBE_TMUX="$tmux" python3 "$HOOK" 2>&1
}
# 最小 JSON 文字列エンコード（" と \ のみ）。テスト cmd はそれ以外の特殊文字を含めない。
_json() { local s="${1//\\/\\\\}"; s="${s//\"/\\\"}"; printf '"%s"' "$s"; }

@test "(a) 管理窓 @3 への send-keys → block(exit2)・deny に scribe-inject/exit 3/exit 4 誘導" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t @3 hi Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    [[ "$output" == *"scribe-inject"* ]]
    [[ "$output" == *"exit 3"* ]]
    [[ "$output" == *"exit 4"* ]]
}

@test "(b) worker 窓 @7(→wt-sc-1) への send-keys → allow(exit0・無出力)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t @7 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(b2) literal 'wt-' 窓名は tmux read なしで allow(exit0)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t wt-sc-164 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(c) capture-pane(監視 read) → allow(exit0)・pane 監視は無傷" {
    run run_guard "$SCRIBE_CWD" "tmux capture-pane -p -t @3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(d) foreign(orch) session では管理窓 send-keys も no-op(exit0)・orchestrator を brick しない" {
    run run_guard "$FOREIGN_CWD" "tmux send-keys -t admin:0 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(d2) present-but-unreadable 台帳(壊れた metadata.json)では guard は fail-closed で発火(exit2)" {
    # scribe_session.py の D2 非対称（guard=_is_scribe_guard_session は fail-closed / banner=
    # _is_scribe_session は fail-open）の guard 側の端を pin する。(d)/(k6) の foreign no-op（fail-open
    # 方向）と対になり、両端が揃う。これが無いと `_is_scribe_guard_session` を fail-open 側へ倒す退行が
    # bats 全緑のまま通る（bd-write-guard 撤去でこの分岐の唯一の coverage が消えたため追加=un-2uap）。
    run run_guard "$BROKEN_CWD" "tmux send-keys -t admin:0 hi Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    # 弁別: 同じ壊れ台帳でも worker 窓(wt-*)は allow＝『壊れ台帳なら何でも deny』の vacuous pass ではない。
    run run_guard "$BROKEN_CWD" "tmux send-keys -t @7 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(d3) ②側台帳(bare/非dict/key欠落)では管理窓 send-keys も exit0 no-op＝他 project を brick しない(②不変)" {
    # (d2) の①(present-but-unreadable→fail-closed True)と**対**になる②側の pin。guard は plugin global
    # enable で全 project に到達するため、② が True へ反転すると `.beads` を持たない無関係 project 全部で
    # tmux transport が block され brick する（scribe_session.py:125 docstring の『plugin global enable 時も
    # 他 project を一切壊さない・②不変厳守』契約）。撤去された bd-write-guard の scope_cases は
    # bare/nondict/nokey の 3 分岐をこの意図で pin していた＝(d2) 追加後に起きやすい過剰補正
    # （fail-closed を広げすぎて②まで True 化）を捕捉する唯一の装置なのでここへ回復する（un-2uap Leg-R-sc）。
    local cwd
    for cwd in "$BARE_CWD" "$NONDICT_CWD" "$NOKEY_CWD"; do
        run run_guard "$cwd" "tmux send-keys -t admin:0 hi Enter"
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    # 弁別: 同一コマンドを sc 台帳 cwd で叩けば block(2)＝上の exit0 は session-gate による no-op であって
    # 『guard が壊れて全部 exit0』の vacuous pass ではない。
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t admin:0 hi Enter"
    [ "$status" -eq 2 ]
}

@test "(e) scribe-inject.sh 呼出行(basename!=tmux)は通す(exit0)" {
    run run_guard "$SCRIBE_CWD" "scripts/scribe-inject.sh send --target admin:0 --text hi"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f) compound / bash -c / send alias + semicolon 難読化でも管理窓は block(exit2)" {
    run run_guard "$SCRIBE_CWD" "echo x && tmux send-keys -t admin:0 hi Enter"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "bash -c 'tmux send-keys -t @3 hi Enter'"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "a; tmux send -t @3 hi"
    [ "$status" -eq 2 ]
}

@test "(f1) send-keys の曖昧さ無し略記/alias(send-key/send-ke/send-k)も管理窓は block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux send-key -t @3 hi Enter"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux send-ke -t admin:0 hi Enter"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux send-k -t @3 hi Enter"
    [ "$status" -eq 2 ]
}

@test "(f1b) send-prefix(send-p 略記系)は send-keys 非対象 → allow(exit0)" {
    run run_guard "$SCRIBE_CWD" "tmux send-prefix -t @3"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f2) tmux コマンド列(\\;)の後続 send-keys(管理窓)も block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux select-window -t @7 \\; send-keys -t admin:0 evil Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
}

@test "(f3) 複数 -t は tmux getopt last-wins。first が wt- でも実効 target が管理窓なら block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t wt-sc-1 -t @3 hi Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
}

@test "(f3b) 複数 -t が全て worker 窓なら allow(exit0)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t wt-sc-1 -t @7 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f4) getopt バンドル短縮形(-lt/-lRt/-ltVALUE)で管理窓 send-keys も block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -lt admin:0 hi Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    run run_guard "$SCRIBE_CWD" "tmux send-keys -lRt @3 evil Enter"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux send-keys -ltadmin:0 hi Enter"
    [ "$status" -eq 2 ]
}

@test "(f4b) バンドル -lt が worker 窓なら allow(exit0)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -lt wt-sc-164 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f5) 値取り global flag -T / bundled -2T 前置でも管理窓 send-keys は block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux -T 256 send-keys -t admin:0 evil Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    run run_guard "$SCRIBE_CWD" "tmux -2T 256 send-keys -t @3 evil Enter"
    [ "$status" -eq 2 ]
}

@test "(f6) self-review finding2: -X を含むバンドル短縮形(-Xt/-lXt)で管理窓 send-keys も block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -Xt admin:0 evil Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    run run_guard "$SCRIBE_CWD" "tmux send-keys -lXt admin:0 evil Enter"
    [ "$status" -eq 2 ]
}

@test "(f6b) -Xt が worker 窓なら allow(exit0)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -Xt wt-sc-164 hi Enter"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f7) self-review finding1: glued 値flag(末尾 f 衝突)-f/x/tmux.conf 前置でも管理窓 send-keys は block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux -f/x/tmux.conf send-keys -t admin:0 evil Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
}

@test "(g) echo クォート内の send-keys は誤検出しない(exit0)" {
    run run_guard "$SCRIBE_CWD" 'echo "tmux send-keys -t admin:0 hi"'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(h) tmux 到達不能なら管理窓 send-keys も素通し(exit0・send-keys 自体実行不能ゆえ実害なし)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t @3 hi Enter" "$TMUX_UNREACH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(i) tmux 到達可だが解決不能な target → deny(exit2・fail-closed)" {
    run run_guard "$SCRIBE_CWD" "tmux send-keys -t @99 hi Enter"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
}

@test "(k1/sc-2g3) 管理窓 paste-buffer(buffer 経由の間接送信)は alias/略記も block(exit2)" {
    run run_guard "$SCRIBE_CWD" "tmux paste-buffer -t @3"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    [[ "$output" == *"paste-buffer"* ]]
    run run_guard "$SCRIBE_CWD" "tmux pasteb -b evil -t admin:0"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux pa -t @3"
    [ "$status" -eq 2 ]
    # value-less 束(-dpr) + 値取り(-s)を貫通して実効 target を読む（naive scanner は target を落とす）。
    run run_guard "$SCRIBE_CWD" "tmux paste-buffer -dpr -s X -t admin:0"
    [ "$status" -eq 2 ]
}

@test "(k1b/sc-2g3) worker 窓への paste-buffer は allow(exit0)・-t 無しは fail-closed で block" {
    run run_guard "$SCRIBE_CWD" "tmux paste-buffer -t @7"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux paste-buffer -b x -t wt-sc-164"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux paste-buffer -b evil"   # -t 無し=現在窓(解決不能&到達可)
    [ "$status" -eq 2 ]
}

@test "(k2/sc-2g3) load-buffer: -t は target-client。管理窓 client は block・staging(-t 無し)は allow" {
    run run_guard "$SCRIBE_CWD" "tmux load-buffer -w -t /dev/pts/9 /tmp/f"   # client は管理窓を見ている
    [ "$status" -eq 2 ]
    [[ "$output" == *"load-buffer"* ]]
    run run_guard "$SCRIBE_CWD" "tmux load-buffer -w -t /dev/pts/7 /tmp/f"   # client は worker 窓を見ている
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux loadb -t @99 /tmp/f"                   # 解決不能&到達可 → fail-closed
    [ "$status" -eq 2 ]
    # -t 無し = pane 配送先を持たない staging → allow（delivery 側 paste-buffer が管理窓宛なら block される）。
    run run_guard "$SCRIBE_CWD" "tmux load-buffer -b x /tmp/f"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k2b/sc-2g3) 二段ベクタ(load→paste): 管理窓宛は delivery で block・worker 窓宛の合成は allow" {
    run run_guard "$SCRIBE_CWD" "tmux load-buffer -b x /tmp/f && tmux paste-buffer -b x -t admin:0"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux load-buffer -b x /tmp/f && tmux paste-buffer -b x -t wt-sc-1"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k3/sc-2g3) run-shell: 管理窓 target は block・worker 窓 target + 無害 payload は allow" {
    run run_guard "$SCRIBE_CWD" "tmux run-shell -t @3 'echo hi'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"run-shell"* ]]
    run run_guard "$SCRIBE_CWD" "tmux run-shell -t @7 'echo hi'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # bare run-shell（-t 無し）: 配送先を持たず pane へ何も注入しない → allow（no_target='allow'・sc-2g3 self-review）。
    # 現在窓=admin へ誤 deny する over-block 回帰を pin。admin/orchestrator の `tmux run-shell 'cmd'` 運用を壊さない。
    run run_guard "$SCRIBE_CWD" "tmux run-shell 'echo hi'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux run -c /tmp 'echo hi'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k3b/sc-2g3) run-shell の payload 再帰: worker 窓 target でも payload が管理窓 transport なら block" {
    # run-shell の -t は実効注入先を縛らない（payload が別窓へ送れる）→ target 判定だけでは素通りする穴。
    run run_guard "$SCRIBE_CWD" "tmux run-shell -t @7 'tmux send-keys -t admin:0 evil Enter'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    # -C（payload=tmux コマンド）解釈でも捕捉する。
    run run_guard "$SCRIBE_CWD" "tmux run -C -t wt-sc-1 'send-keys -t admin:0 evil Enter'"
    [ "$status" -eq 2 ]
    # payload 内の paste-buffer（transport 表 × 再帰の合成）。
    run run_guard "$SCRIBE_CWD" "tmux run-shell -t wt-sc-1 'tmux paste-buffer -t admin:0'"
    [ "$status" -eq 2 ]
    # bare run-shell（-t 無し）でも payload が管理窓 transport なら再帰で block（no_target='allow' は payload 検査に非干渉）。
    run run_guard "$SCRIBE_CWD" "tmux run-shell 'tmux send-keys -t admin:0 evil Enter'"
    [ "$status" -eq 2 ]
}

@test "(k4/sc-2g3) pipe-pane: -I(pane 入力へ書込=typed 相当)だけ transport・-o/-O(read piping)は allow" {
    run run_guard "$SCRIBE_CWD" "tmux pipe-pane -I -t @3 'cat /tmp/payload'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"pipe-pane"* ]]
    run run_guard "$SCRIBE_CWD" "tmux pipe-pane -o -t @3 'cat >> /tmp/log'"   # 監視 read → 壊さない
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux pipe-pane -I -t @7 'echo hi'"           # worker 窓
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k5/sc-2g3) exec carrier(if-shell/new-window/split-window)の payload に管理窓 transport → block" {
    run run_guard "$SCRIBE_CWD" "tmux if-shell -b true 'send-keys -t admin:0 evil Enter'"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux new-window 'tmux send-keys -t admin:0 evil Enter'"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux split-window -t wt-sc-1 'tmux pasteb -t @3'"
    [ "$status" -eq 2 ]
}

@test "(k5b/sc-2g3) exec carrier 自体は無条件 deny にしない(FP を増やさない): 無害 payload は allow(exit0)" {
    run run_guard "$SCRIBE_CWD" "tmux new-window -n wt-sc-9 htop"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux new-window -t admin -n tools 'less /tmp/log'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux if-shell 'test -f /tmp/x' 'display-message ok'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k5c/sc-2g3) exec carrier 再帰の FP 非増加: window/session 名が transport 略記と衝突しても allow(exit0)" {
    # `-n run`/`-s pa` 等の名前が `tmux <名>` と再解釈され `-t` 無し→現在窓(admin)→誤 deny する回帰を pin。
    run run_guard "$SCRIBE_CWD" "tmux new-window -n run htop"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$SCRIBE_CWD" "tmux new-window -n send"
    [ "$status" -eq 0 ]
    run run_guard "$SCRIBE_CWD" "tmux new-window -n pa htop"
    [ "$status" -eq 0 ]
    run run_guard "$SCRIBE_CWD" "tmux new-session -s run -d"
    [ "$status" -eq 0 ]
    run run_guard "$SCRIBE_CWD" "tmux new-session -s pa"
    [ "$status" -eq 0 ]
    # 実 vector（payload が明示 -t admin で管理窓を指す）は FP 修正後も変わらず block。
    run run_guard "$SCRIBE_CWD" "tmux new-window -n run 'tmux send-keys -t admin:0 evil'"
    [ "$status" -eq 2 ]
}

@test "(k5d/sc-2g3) tmux コマンド payload のセミコロン連鎖 fail-open(if-shell / -C)を block する" {
    # `tmux ` 前置を payload 全体に一度だけ足すと `;` 以降が tmux invocation と認識されず素通りしていた回帰。
    run run_guard "$SCRIBE_CWD" "tmux if-shell true 'x ; send-keys -t admin:0 evil'"
    [ "$status" -eq 2 ]
    [[ "$output" == *"DENIED(tmux)"* ]]
    run run_guard "$SCRIBE_CWD" "tmux run -C -t wt-sc-1 'display-message hi ; send-keys -t admin:0 evil'"
    [ "$status" -eq 2 ]
    run run_guard "$SCRIBE_CWD" "tmux if-shell true 'display-message a ; pasteb -t @3'"
    [ "$status" -eq 2 ]
    # 無害な `;` 連鎖（transport 無し）は allow（新たな deny を増やさない）。
    run run_guard "$SCRIBE_CWD" "tmux if-shell true 'display-message a ; display-message b'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k6/sc-2g3) foreign(orch) session では新 transport も no-op(exit0)・orchestrator を brick しない" {
    run run_guard "$FOREIGN_CWD" "tmux paste-buffer -t admin:0"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run run_guard "$FOREIGN_CWD" "tmux run-shell -t @3 'tmux send-keys -t admin:0 evil'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(k7/sc-2g3) tmux 到達不能なら新 transport も素通し(exit0・実行不能ゆえ実害なし)" {
    run run_guard "$SCRIBE_CWD" "tmux paste-buffer -t @3" "$TMUX_UNREACH"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(j) garbage stdin → fail-open(exit0・traceback 無し)" {
    run bash -c "printf 'not json {{' | CMDTOKENS_LIB='$CT_LIB' python3 '$HOOK' 2>&1"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Traceback"* ]]
}

@test "(v) in-process --self-test が green(durable coverage pin)" {
    run bash -c "CMDTOKENS_LIB='$CT_LIB' python3 '$HOOK' --self-test"
    [ "$status" -eq 0 ]
    [[ "$output" == *"ALL PASSED"* ]]
}

@test "(v-b) self-test fail-closed が非vacuous(判定を allow 固定に sabotage すると run_self_test が非0)" {
    run bash -c "CMDTOKENS_LIB='$CT_LIB' python3 - '$HOOK' <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('tguard', sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# sabotage: 全 transport の target 判定を allow 固定 → (4)/(5)/(5b)/(7) の block 期待が壊れる。
# 判定 funnel は _decide_targets（send-keys / paste-buffer / load-buffer / run-shell / pipe-pane 共通・sc-2g3）。
m._decide_targets = lambda targets, kind='pane', no_target='current': (False, '')
rc = m.run_self_test()
sys.exit(0 if rc != 0 else 1)   # 検出できれば test pass。
PY"
    [ "$status" -eq 0 ]
}

@test "(wire) hooks.json が tmux-send-keys-guard を既存 guard と同形(python3・no-or-true・dash-x 存在ガード)で PreToolUse[Bash] へ wire" {
    run python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                 # valid JSON でなければ die
pre = d.get("hooks", {}).get("PreToolUse", [])
cmds = [h.get("command", "") for g in pre if g.get("matcher") == "Bash" for h in g.get("hooks", [])]
tg = [c for c in cmds if "tmux-send-keys-guard.py" in c]
if not tg:
    print("FAIL: PreToolUse[Bash] に tmux-send-keys-guard wire が無い"); sys.exit(1)
c = tg[0]
if "python3" not in c:
    print("FAIL: guard wire が python3 で起動していない"); sys.exit(1)
if "|| true" in c:
    print("FAIL: guard wire に `|| true` がある（exit2=block を無効化＝禁止）"); sys.exit(1)
if "[ -x" not in c:
    print("FAIL: guard wire が `[ -x \"$SCRIPT\" ]` 存在ガードを欠く（既存 guard と同形でない）"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: tmux-send-keys-guard wire は既存 guard 同形・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

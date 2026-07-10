#!/usr/bin/env bats
# tests/tmux-send-keys-guard.bats
#
# PreToolUse[Bash] hook（scripts/hooks/tmux-send-keys-guard.py・sc-164 transport 構造封鎖 B）の
# **e2e（stdin JSON → exit code / stderr の実フック契約）** と **hooks.json wire 検査** の hermetic bats。
#
# 契約: 管理窓（非 'wt-' window）への生 tmux send-keys を exit2 で block し scribe-inject 経由へ funnel する。
#   worker 窓（wt-*）への steering・capture-pane（監視 read）は封鎖対象外。foreign(orch) session は no-op。
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

    # stub tmux（到達可）: @3/admin:0→'admin'(管理窓)・@7→'wt-sc-1'(worker 窓)・他→解決失敗(exit1)。
    TMUX_OK="$TEST_TMPDIR/tmux-reachable"
    cat > "$TMUX_OK" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in *"#{socket_path}"*) echo /tmp/stub-sock; exit 0 ;; esac
tgt=""; prev=""; for a in "$@"; do [ "$prev" = "-t" ] && tgt="$a"; prev="$a"; done
case "$tgt" in
  @3|admin*) echo "admin"; exit 0 ;;
  @7)        echo "wt-sc-1"; exit 0 ;;
  *)         exit 1 ;;
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
# sabotage: 全 target を allow 固定 → (4)/(5)/(7) の block 期待が壊れる。
m._decide_send_keys = lambda t: (False, '')
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

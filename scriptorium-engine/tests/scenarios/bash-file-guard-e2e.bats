#!/usr/bin/env bats
# tests/scenarios/bash-file-guard-e2e.bats
#
# L3 bash-file-write-guard.py（orch-2o6）の **e2e（stdin→exit code の実フック契約）** と
# **hooks.json wire 検査** の durable 化（orch-dk5）。
#
# 背景: guard 内蔵 `--self-test`（analyze() を in-process で 85+ checks・mutation seam 込み）は committed
#   だが、(1) 実フック経路（JSON on stdin → main() → exit code）の e2e と (2) hooks.json が guard を正しく
#   PreToolUse[Bash] へ wire しているかの検査は、orch-2o6 worker の untracked `selftest-orch-2o6.local.sh`
#   のみに在り main に durable に残らなかった（worktree 削除で消える）。本 bats はそれを fleet-monitor-board.bats
#   / orch-dispatch.bats と同型の hermetic E2E として tests/scenarios/ へ昇格する（orch-j55 と同類の durability 改善）。
#
# 方式（hermetic）:
#   - 台帳 fixture: temp に orch(dolt_database=orch) と foreign(dolt_database=un) の .beads/metadata.json を作る。
#   - guard を JSON payload を **stdin に流して subprocess 実行**し $status（exit code）と分離捕捉した stderr を
#     assert する＝guard 内蔵 --self-test（in-process analyze()）が触らない main()→stdin→exit の実契約を被覆。
#   - cmdtokens lib は installed plugin を優先・無ければ repo 同梱の residual copy(scripts/hooks/lib)へ fallback
#     （両者 API 互換＝iter_commands/parse_statements/shlex_safe/track_cd/peel）。これで production fidelity
#     （plugin がある host では guard が実際に使う lib と同一）と bare checkout の可搬性を両立する。
#
# 検証する契約不変条件（SSOT=orch-2o6 gate / guard header / hooks.json comment）:
#   (A) e2e deny/allow: foreign 台帳配下の Bash file 変異（redirect=Pass B / operand=Pass A）→ exit 2 deny
#       + DENIED(bash-file) を stderr。自台帳(orch)・台帳外(/dev/null)・foreign の read・非 orch session・
#       cd 追跡後の相対宛先 → 期待どおり allow(0) / deny(2)。
#   (B) e2e fail-open & under-block: malformed/空 stdin・cmdtokens lib 不在 → exit 0（全 Bash を brick しない）。
#       under-block（変数/置換宛先）→ exit 0 + loud log（silent 取りこぼしにしない＝検出器が非vacuous）。
#   (C) 回帰: committed in-process `--self-test` が durable runner 経由でも green（コミット済 coverage を pin）。
#   (D) hooks.json wire: PreToolUse[Bash] が bash-file-write-guard.py を（bd-write-guard.py と同一 matcher group で）
#       fail-open 形（`if [ -x "$SCRIPT" ]; then python3 "$SCRIPT"; else exit 0; fi`・`|| true` 無し）で wire し、
#       参照 script が repo に存在し実行可能であること。
#
# 実行: bats tests/scenarios/bash-file-guard-e2e.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    GUARD="$REPO/scripts/hooks/bash-file-write-guard.py"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    # cmdtokens lib 解決: installed plugin を優先（production fidelity）・無ければ repo 同梱 residual copy へ
    # fallback（bare checkout でも hermetic）。両 copy は API 互換ゆえ本 test の単純コマンドでは同一挙動。
    # guard preamble は CMDTOKENS_LIB が非絶対だと既定へ落とすため、必ず絶対パスを export する。
    if [ -f "$HOME/.claude/plugins/cmdtokens/lib/cmdtokens.py" ]; then
        export CMDTOKENS_LIB="$HOME/.claude/plugins/cmdtokens/lib"
    else
        export CMDTOKENS_LIB="$REPO/scripts/hooks/lib"
    fi

    TEST_TMPDIR=$(mktemp -d -t bash-file-guard-e2e-XXXXXX)
    STDERR_FILE="$TEST_TMPDIR/guard.stderr"

    # hermetic 台帳 fixture: orch(self) と foreign(un)。walk-up で .beads/metadata.json の dolt_database を解決。
    ORCH="$TEST_TMPDIR/orch"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$ORCH/.beads" "$ORCH/sub" "$FOREIGN/.beads" "$FOREIGN/sub"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"un"}'   > "$FOREIGN/.beads/metadata.json"
    : > "$FOREIGN/f.txt"; : > "$FOREIGN/src.txt"

    # hooks.json 構造検査 validator（durable・JSON を grep でなく機械パース）。
    WIRE_PY="$TEST_TMPDIR/wire_check.py"
    cat > "$WIRE_PY" <<'PY'
import json, os, re, sys
hooks_json, repo, check = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(open(hooks_json))                      # valid JSON でなければここで die
groups = d.get("hooks", {}).get("PreToolUse", [])
bash_groups = [g for g in groups if g.get("matcher") == "Bash"]
bash_cmds = [h.get("command", "") for g in bash_groups for h in g.get("hooks", [])]

def fail(m):
    print("FAIL:", m); sys.exit(1)

if check == "valid-json":
    pass  # json.load 成功で十分
elif check == "bash-matcher-exists":
    if not bash_groups:
        fail("PreToolUse に Bash matcher が無い")
elif check == "l3-wired":
    if not any("bash-file-write-guard.py" in c for c in bash_cmds):
        fail("Bash matcher に bash-file-write-guard.py(L3) の wire が無い")
elif check == "bd-co-located":
    if not any("bd-write-guard.py" in c for c in bash_cmds):
        fail("Bash matcher に bd-write-guard.py が無い（L3 は bd-guard と同 matcher 同居が契約）")
    ok = any(
        any("bash-file-write-guard.py" in h.get("command", "") for h in g.get("hooks", [])) and
        any("bd-write-guard.py" in h.get("command", "") for h in g.get("hooks", []))
        for g in bash_groups)
    if not ok:
        fail("bd-guard と bash-file-guard が同一 Bash matcher group に同居していない")
elif check == "l3-failopen-form":
    l3 = [c for c in bash_cmds if "bash-file-write-guard.py" in c]
    if not l3:
        fail("L3 wire 不在")
    c = l3[0]
    if "|| true" in c:
        fail("L3 wire に `|| true`（guard 無効化）が在る")
    if not re.search(r'if\s*\[\s*-x\s*"\$SCRIPT"\s*\]', c):
        fail('L3 wire が `[ -x "$SCRIPT" ]` fail-open 形でない')
    if "exit 0" not in c:
        fail("L3 wire に script 不在時 `exit 0`（fail-open）が無い")
    if "python3" not in c:
        fail("L3 wire が python3 で guard を起動していない")
elif check == "l3-script-exists":
    l3 = [c for c in bash_cmds if "bash-file-write-guard.py" in c][0]
    m = re.search(r'\$\{CLAUDE_PLUGIN_ROOT\}(/scripts/hooks/bash-file-write-guard\.py)', l3)
    if not m:
        fail("L3 wire の script path が ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/bash-file-write-guard.py でない")
    real = repo + m.group(1)
    if not os.path.isfile(real):
        fail("guard script 不在: " + real)
    if not os.access(real, os.X_OK):
        fail("guard script が実行可能でない: " + real)
else:
    fail("unknown check " + check)
print("OK:", check)
PY
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# ── helpers ───────────────────────────────────────────────────────────────────
# JSON payload を python で安全に組む（任意の path/コマンド文字列を確実に escape）。
mkpayload() {
    python3 -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1], "tool_input": {"command": sys.argv[2]}}))' "$1" "$2"
}

# guard を (cwd, command) の JSON payload を stdin に流して実行。$status=exit code・stderr は $STDERR_FILE に分離。
run_guard() {
    local payload; payload=$(mkpayload "$1" "$2")
    : > "$STDERR_FILE"
    run bash -c 'python3 "$1" 2>"$2"' _ "$GUARD" "$STDERR_FILE" <<<"$payload"
}

# 生 stdin（不正/空 JSON）を guard に流す。
run_guard_raw() {
    : > "$STDERR_FILE"
    run bash -c 'python3 "$1" 2>"$2"' _ "$GUARD" "$STDERR_FILE" <<<"$1"
}

# ==============================================================================
# (A) e2e deny/allow: 実 stdin→main()→exit code（in-process --self-test が触らない実フック契約）
# ==============================================================================

@test "e2e(Pass B): redirect で foreign 台帳へ書くと exit 2 deny（DENIED を stderr）" {
    run_guard "$ORCH" "echo x > $FOREIGN/f.txt"
    [ "$status" -eq 2 ]
    grep -q 'DENIED(bash-file)' "$STDERR_FILE"
}

@test "e2e(Pass B・非vacuous対): 同じ redirect でも自台帳(orch)宛は exit 0 allow（DENIED 無し）" {
    run_guard "$ORCH" "echo x > $ORCH/g.txt"
    [ "$status" -eq 0 ]
    ! grep -q 'DENIED' "$STDERR_FILE"
}

@test "e2e(Pass A): sed -i で foreign へ書くと exit 2 deny" {
    run_guard "$ORCH" "sed -i s/x/y/ $FOREIGN/f.txt"
    [ "$status" -eq 2 ]
    grep -q 'DENIED(bash-file)' "$STDERR_FILE"
}

@test "e2e(Pass A・非vacuous対): sed -i でも自台帳(orch)宛は exit 0 allow" {
    run_guard "$ORCH" "sed -i s/x/y/ $ORCH/g.txt"
    [ "$status" -eq 0 ]
    ! grep -q 'DENIED' "$STDERR_FILE"
}

@test "e2e(Pass A): cp の宛先が foreign なら exit 2 deny" {
    run_guard "$ORCH" "cp /etc/hostname $FOREIGN/copy.txt"
    [ "$status" -eq 2 ]
}

@test "e2e: foreign の read（cat / cp の src）は exit 0 allow（read は許可）" {
    run_guard "$ORCH" "cat $FOREIGN/f.txt"
    [ "$status" -eq 0 ]
    ! grep -q 'DENIED' "$STDERR_FILE"
    run_guard "$ORCH" "cp $FOREIGN/src.txt $ORCH/dst.txt"
    [ "$status" -eq 0 ]
    ! grep -q 'DENIED' "$STDERR_FILE"
}

@test "e2e: 台帳外（/dev/null）への書込は exit 0 allow" {
    run_guard "$ORCH" "echo x > /dev/null"
    [ "$status" -eq 0 ]
}

@test "e2e: 非 orchestrator session（cwd=foreign）は foreign 宛でも no-op exit 0" {
    run_guard "$FOREIGN" "echo x > $FOREIGN/f.txt"
    [ "$status" -eq 0 ]
    ! grep -q 'DENIED' "$STDERR_FILE"
}

@test "e2e(cd 追跡): cd で実効 cwd が foreign に移ると相対宛先 redirect も deny" {
    run_guard "$ORCH" "cd $FOREIGN && echo x > rel.txt"
    [ "$status" -eq 2 ]
}

# ==============================================================================
# (B) e2e fail-open & under-block（全 Bash を brick しない／silent 取りこぼしにしない）
# ==============================================================================

@test "fail-open: 不正 JSON stdin は exit 0（全 Bash を brick しない）" {
    run_guard_raw "this is not json {"
    [ "$status" -eq 0 ]
}

@test "fail-open: 空 stdin は exit 0" {
    run_guard_raw ""
    [ "$status" -eq 0 ]
}

@test "fail-open: cmdtokens lib 不在は exit 0 + loud log（preamble の fail-open）" {
    local payload; payload=$(mkpayload "$ORCH" "echo x > $FOREIGN/f.txt")
    : > "$STDERR_FILE"
    run bash -c 'CMDTOKENS_LIB=/nonexistent-cmdtokens-xyz python3 "$1" 2>"$2"' _ "$GUARD" "$STDERR_FILE" <<<"$payload"
    [ "$status" -eq 0 ]
    grep -q 'cannot load cmdtokens lib' "$STDERR_FILE"
}

@test "under-block: 静的解決不能な宛先（変数）は exit 0 + loud log（silent にしない＝非vacuous）" {
    run_guard "$ORCH" 'echo x > $OUT'
    [ "$status" -eq 0 ]
    grep -q '静的解決不能' "$STDERR_FILE"
}

# ==============================================================================
# (C) 回帰: committed in-process --self-test が durable runner 経由でも green
# ==============================================================================

@test "回帰: 内蔵 in-process --self-test が green（committed coverage を runner で pin）" {
    run python3 "$GUARD" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
    [[ "$output" != *"FAIL"* ]]
}

# ==============================================================================
# (D) hooks.json wire 検査（durable・構造化パース）
# ==============================================================================

@test "wire: hooks.json が valid JSON" {
    run python3 "$WIRE_PY" "$HOOKS_JSON" "$REPO" valid-json
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK"* ]]
}

@test "wire: PreToolUse に Bash matcher が存在する" {
    run python3 "$WIRE_PY" "$HOOKS_JSON" "$REPO" bash-matcher-exists
    [ "$status" -eq 0 ]
}

@test "wire: L3 bash-file-write-guard.py が PreToolUse[Bash] に wire されている" {
    run python3 "$WIRE_PY" "$HOOKS_JSON" "$REPO" l3-wired
    [ "$status" -eq 0 ]
}

@test "wire: bd-write-guard.py と同一 Bash matcher group に同居している" {
    run python3 "$WIRE_PY" "$HOOKS_JSON" "$REPO" bd-co-located
    [ "$status" -eq 0 ]
}

@test "wire: L3 wire は fail-open 形（[ -x ]→python3 / else exit 0）で || true を含まない" {
    run python3 "$WIRE_PY" "$HOOKS_JSON" "$REPO" l3-failopen-form
    [ "$status" -eq 0 ]
}

@test "wire: 参照される guard script が repo に存在し実行可能" {
    run python3 "$WIRE_PY" "$HOOKS_JSON" "$REPO" l3-script-exists
    [ "$status" -eq 0 ]
}

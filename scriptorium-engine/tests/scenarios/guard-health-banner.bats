#!/usr/bin/env bats
# tests/scenarios/guard-health-banner.bats
#
# SessionStart guard-health hook（scripts/hooks/session-start-guard-health.py・bd orch-hos）の
# **e2e（stdin→stdout の実フック契約）** と **hooks.json wire 検査** の hermetic bats（AC3）。
#
# 背景: cmdtokens plugin 不在ホストでは bd-write-guard / bash-file-write-guard が consume preamble の
#   fail-open(exit0)で silent に無効化される。本 hook はそれを SessionStart stdout の ⚠️ banner で loud
#   化する（設計確定 orch-hos NOTES・案A）。hook の self-scope（orch session のみ発火）・cmdtokens 解決
#   （consume preamble と同一）・banner 内容（影響 guard 名 + DISABLED + 解決 path + 復旧 hint）を実フック
#   経路で pin する。fleet-monitor-board.bats / bash-file-guard-e2e.bats と同型の hermetic E2E。
#
# 方式（hermetic・実 plugin/DB 非依存）:
#   - 台帳 fixture: temp に orch(dolt_database=orch) と foreign(dolt_database=un) の .beads/metadata.json。
#   - cmdtokens fixture: present = guard が import する 5 API を定義する stub cmdtokens.py を含む dir /
#     absent = 空 dir（import 失敗）。CMDTOKENS_LIB で hook の解決先を切り替える。
#   - hook を JSON payload を stdin に流して subprocess 実行し $status と $output を assert する。
#
# 検証する契約不変条件（SSOT=orch-hos AC1-AC3 / hook header / hooks.json comment）:
#   (i)   cmdtokens present + orch session → banner 無（silent）・exit0。
#   (ii)  cmdtokens absent  + orch session → banner 有（bd-write-guard / bash-file-write-guard / DISABLED /
#         解決 path / 復旧 hint を含む）・exit0。
#   (iii) cmdtokens absent  + foreign session(dolt_database≠orch) → no-op（banner 無・self-scope が先に効く）。
#   (iv)  in-process `--self-test` が green（コミット済 coverage を durable に pin）。
#   (iv-b) self-test fail-closed が非vacuous: banner 生成を sabotage すると run_self_test が非0を返す。
#   (wire) hooks.json が SessionStart へ guard-health を spec-inject と同形 fail-safe（`|| true`・python3）で
#          wire し、参照 script が repo に存在し実行可能であること。
#
# 実行: bats tests/scenarios/guard-health-banner.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    HOOK="$REPO/scripts/hooks/session-start-guard-health.py"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d -t guard-health-bats-XXXXXX)"

    # 台帳 fixture: orch(self) / foreign(un)。walk-up で .beads/metadata.json の dolt_database を解決。
    ORCH="$TEST_TMPDIR/orch"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$ORCH/.beads" "$ORCH/sub" "$FOREIGN/.beads" "$FOREIGN/sub"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"un"}'   > "$FOREIGN/.beads/metadata.json"
    ORCH_CWD="$ORCH/sub"
    FOREIGN_CWD="$FOREIGN/sub"

    # cmdtokens fixture: present(5 API stub) / absent(空 dir)。
    CT_PRESENT="$TEST_TMPDIR/ct-present"
    CT_ABSENT="$TEST_TMPDIR/ct-absent"
    mkdir -p "$CT_PRESENT" "$CT_ABSENT"
    cat > "$CT_PRESENT/cmdtokens.py" <<'PY'
def iter_commands(*a, **k):
    return []
def parse_statements(*a, **k):
    return []
def shlex_safe(*a, **k):
    return None
def track_cd(*a, **k):
    return None
def peel(*a, **k):
    return (None, None, False, None)
PY
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# hook を実フック経路（stdin JSON → stdout）で起動する helper。
run_hook() {
    local cwd="$1" ctlib="$2"
    printf '{"cwd":"%s"}' "$cwd" | CMDTOKENS_LIB="$ctlib" python3 "$HOOK"
}

@test "(i) cmdtokens present + orch session → banner 無(silent)・exit0" {
    run run_hook "$ORCH_CWD" "$CT_PRESENT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(ii) cmdtokens absent + orch session → banner 有(guard 名/DISABLED/path/復旧)・exit0" {
    run run_hook "$ORCH_CWD" "$CT_ABSENT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"GUARD HEALTH WARNING"* ]]
    [[ "$output" == *"bd-write-guard"* ]]
    [[ "$output" == *"bash-file-write-guard"* ]]
    [[ "$output" == *"DISABLED"* ]]
    [[ "$output" == *"$CT_ABSENT"* ]]        # 解決した lib path を含む
    [[ "$output" == *"ln -sfn"* ]]           # 復旧(symlink)hint を含む
}

@test "(iii) cmdtokens absent + foreign session → no-op(banner 無・self-scope 先行)" {
    run run_hook "$FOREIGN_CWD" "$CT_ABSENT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(iv) in-process --self-test が green(durable coverage pin)" {
    run python3 "$HOOK" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSED"* ]]
}

@test "(iv-b) self-test fail-closed が非vacuous(banner sabotage で run_self_test が非0)" {
    run python3 - "$HOOK" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ghealth", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# sabotage: banner を常に空にする → (ii) absent+orch の banner 期待が壊れる。
m._build_banner = lambda *a, **k: ""
rc = m.run_self_test()
# fail-closed なら sabotage で rc!=0。期待どおりなら exit0(test pass)、検出できなければ exit1(test fail)。
sys.exit(0 if rc != 0 else 1)
PY
    [ "$status" -eq 0 ]
}

@test "(iv-c) 閉じた stdin(fd0 closed) でも die しない(exit0・traceback 無し・orch-3z9)" {
    # SessionStart hook が fd0 閉鎖で起動されると CPython は sys.stdin=None で初期化し、未保護の
    # isatty() 呼び出しが AttributeError を送出して traceback+非0 で die しうる(本 hook の「常に exit0・
    # 決して die しない」契約違反)。修正前は RED(traceback)・修正後は GREEN。
    run bash -c 'python3 "$1" 0<&-' _ "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" != *"AttributeError"* ]]
}

@test "(iv-d) cwd 削除済み + garbage/空 stdin でも die しない(exit0・traceback 無し・orch-k33)" {
    # main() の except 経路の os.getcwd() は try 外にあり、cwd 削除済み + garbage/空 stdin の degenerate
    # edge で FileNotFoundError が伝播し traceback+exit1 で die しうる(「常に exit0・決して die しない」契約
    # 違反)。_safe_cwd() で "/" へ degrade することで防ぐ。修正前は RED(traceback)・修正後は GREEN。
    # 削除する cwd は subshell に閉じ込め、bats 本体の cwd を壊さない。
    # (a) garbage stdin: json.loads 失敗 → except → getcwd(try 外)で die しうる。
    run bash -c 'd=$(mktemp -d -t ghk33-XXXXXX); cd "$d" && rmdir "$d" && printf "not json {{{" | python3 "$1" 2>&1' _ "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" != *"FileNotFoundError"* ]]
    # (b) 空 stdin: data={} → `data.get("cwd") or getcwd()`(try 内)で die しうる。
    run bash -c 'd=$(mktemp -d -t ghk33-XXXXXX); cd "$d" && rmdir "$d" && printf "" | python3 "$1" 2>&1' _ "$HOOK"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Traceback"* ]]
    [[ "$output" != *"FileNotFoundError"* ]]
}

@test "(wire) hooks.json が guard-health を spec-inject と同形 fail-safe で SessionStart へ wire" {
    run python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                 # valid JSON でなければ die
ss = d.get("hooks", {}).get("SessionStart", [])
cmds = [h.get("command", "") for g in ss for h in g.get("hooks", [])]
gh = [c for c in cmds if "session-start-guard-health.py" in c]
if not gh:
    print("FAIL: SessionStart に guard-health wire が無い"); sys.exit(1)
c = gh[0]
if "python3" not in c:
    print("FAIL: guard-health wire が python3 で起動していない"); sys.exit(1)
if "|| true" not in c:
    print("FAIL: guard-health wire が spec-inject と同形 fail-safe(|| true)でない"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: guard-health wire は fail-safe・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

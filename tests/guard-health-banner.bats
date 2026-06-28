#!/usr/bin/env bats
# tests/guard-health-banner.bats
#
# SessionStart guard-health hook（scripts/hooks/session-start-guard-health.py・sc-ovq）の
# **e2e（stdin→stdout の実フック契約）** と **hooks.json wire 検査** の hermetic bats。
#
# 背景: scribe は canonical plugin（cmdtokens / beads-bdw）を consume するが、plugin 不在ホストでは
#   silent に劣化する: (A) cmdtokens 不在で git/rm destructive guard が consume preamble の fail-open(exit0)
#   で無効化＝破壊コマンド素通し / (B) beads-bdw 不在で scripts/bdw shim が fail-closed＝bd write 不可
#   （sandbox-off worker は zombie 化）。本 hook はそれを SessionStart stdout の ⚠️ banner で loud 化する。
#   port 元 = scriptorium scripts/hooks/session-start-guard-health.py（cmdtokens 版・bd orch-hos）。
#
# 方式（hermetic・実 plugin/DB 非依存）:
#   - 台帳 fixture: temp に scribe(dolt_database=sc) と foreign(dolt_database=orch) の .beads/metadata.json。
#   - cmdtokens fixture: present = 両 guard が import する和集合 API を定義する stub cmdtokens.py を含む dir /
#     absent = 空 dir（import 失敗）。CMDTOKENS_LIB で hook の解決先を切り替える。
#   - bdw fixture: present = `lock-dir` で exit0 する canonical bdw stub / absent = 不正パス（shim fail-closed）。
#     BEADS_BDW で scripts/bdw shim の canonical 解決先を切り替える（shim→canonical chain を実走＝sc-vae 同経路）。
#   - hook を JSON payload を stdin に流して subprocess 実行し $status と $output を assert する。
#
# 検証する契約不変条件:
#   (i)   cmdtokens present + bdw present + scribe session → banner 無（silent）・exit0。
#   (ii)  cmdtokens absent  + scribe session → banner 有（git-destructive-guard / rm-destructive-guard /
#         DISABLED / 解決 path / 復旧 hint）・exit0。
#   (iii) bdw absent        + scribe session → banner 有（beads-bdw / fail-closed / zombie / 復旧 hint）・exit0。
#   (iv)  cmdtokens absent  + foreign session(dolt_database=orch) → no-op（banner 無・self-scope 先行＝誤注入ゼロ）。
#   (v)   in-process `--self-test` が green（コミット済 coverage を durable に pin）。
#   (v-b) self-test fail-closed が非vacuous: banner 生成を sabotage すると run_self_test が非0を返す。
#   (wire) hooks.json が SessionStart へ guard-health を role-inject と同形 fail-safe（`|| true`・python3）で
#          wire し、参照 script が repo に存在し実行可能であること。
#
# 実行: bats tests/guard-health-banner.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$REPO/scripts/hooks/session-start-guard-health.py"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d -t scribe-guard-health-bats-XXXXXX)"

    # 台帳 fixture: scribe(self) / foreign(orch)。walk-up で .beads/metadata.json の dolt_database を解決。
    SCRIBE_LEDGER="$TEST_TMPDIR/scribe"
    FOREIGN="$TEST_TMPDIR/foreign"
    mkdir -p "$SCRIBE_LEDGER/.beads" "$SCRIBE_LEDGER/sub" "$FOREIGN/.beads" "$FOREIGN/sub"
    printf '{"database":"dolt","dolt_database":"sc"}'   > "$SCRIBE_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$FOREIGN/.beads/metadata.json"
    SCRIBE_CWD="$SCRIBE_LEDGER/sub"
    FOREIGN_CWD="$FOREIGN/sub"

    # cmdtokens fixture: present(両 guard の和集合 API stub) / absent(空 dir)。
    CT_PRESENT="$TEST_TMPDIR/ct-present"
    CT_ABSENT="$TEST_TMPDIR/ct-absent"
    mkdir -p "$CT_PRESENT" "$CT_ABSENT"
    cat > "$CT_PRESENT/cmdtokens.py" <<'PY'
def iter_commands(*a, **k):
    return []
def long_opt_abbrev(*a, **k):
    return None
def parse_statements(*a, **k):
    return []
def peel(*a, **k):
    return (None, None, False, None)
def shlex_safe(*a, **k):
    return None
def strip_redirections(*a, **k):
    return None
def track_cd(*a, **k):
    return None
SHELLS = ()
VAR_OR_SUBST = None
PY

    # bdw fixture: present(canonical bdw stub: lock-dir→exit0) / absent(不正パス→shim fail-closed)。
    BDW_PRESENT="$TEST_TMPDIR/bdw-canonical-present"
    printf '#!/usr/bin/env bash\n[ "$1" = lock-dir ] && { echo "%s/locks"; exit 0; }\nexit 0\n' "$TEST_TMPDIR" > "$BDW_PRESENT"
    chmod +x "$BDW_PRESENT"
    BDW_ABSENT="$TEST_TMPDIR/no-such-canonical-bdw"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# hook を実フック経路（stdin JSON → stdout）で起動する helper。cmdtokens/bdw の解決先を env で切り替える。
run_hook() {
    local cwd="$1" ctlib="$2" bdw="$3"
    printf '{"cwd":"%s"}' "$cwd" | CMDTOKENS_LIB="$ctlib" BEADS_BDW="$bdw" python3 "$HOOK"
}

@test "(i) cmdtokens present + bdw present + scribe session → banner 無(silent)・exit0" {
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(ii) cmdtokens absent + scribe session → banner 有(両 guard 名/DISABLED/path/復旧)・exit0" {
    run run_hook "$SCRIBE_CWD" "$CT_ABSENT" "$BDW_PRESENT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLUGIN HEALTH WARNING"* ]]
    [[ "$output" == *"git-destructive-guard"* ]]
    [[ "$output" == *"rm-destructive-guard"* ]]
    [[ "$output" == *"DISABLED"* ]]
    [[ "$output" == *"$CT_ABSENT"* ]]        # 解決した cmdtokens lib path を含む
    [[ "$output" == *"ln -sfn"* ]]           # 復旧(symlink)hint を含む
    [[ "$output" != *"beads-bdw"* ]]         # bdw present ゆえ bdw 節は出さない（probe の独立性）
}

@test "(iii) bdw absent + scribe session → banner 有(beads-bdw/fail-closed/zombie/復旧)・exit0" {
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_ABSENT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLUGIN HEALTH WARNING"* ]]
    [[ "$output" == *"beads-bdw"* ]]
    [[ "$output" == *"fail-closed"* ]]
    [[ "$output" == *"zombie"* ]]            # sandbox-off zombie 化を明示
    [[ "$output" == *"BEADS_BDW"* ]]         # bdw 復旧 hint を含む
    [[ "$output" != *"git-destructive-guard"* ]]  # cmdtokens present ゆえ guard 節は出さない
}

@test "(iv) cmdtokens absent + foreign session(dolt_database=orch) → no-op(banner 無・self-scope 先行=誤注入ゼロ)" {
    run run_hook "$FOREIGN_CWD" "$CT_ABSENT" "$BDW_ABSENT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(iv-b) closed stdin(0<&-) でも exit0・traceback 無し（決して die しない契約・sc-ovq orchestrator gate）" {
    # fd 0 を閉じて起動すると CPython は sys.stdin=None で初期化し、素の sys.stdin.isatty() が
    # AttributeError を送出して die しうる（「常に exit0・決して die しない」契約違反）。None ガードで
    # degrade することを pin する（修正前は RED=traceback+rc1 / 後は GREEN）。非 ledger cwd から走らせ
    # self-scope no-op で出力を決定論的に空へ（host の plugin 配備に依存させない）。
    run bash -c "cd '$TEST_TMPDIR' && python3 '$HOOK' 0<&-"
    [ "$status" -eq 0 ]
    [[ "$output" != *"Traceback"* ]]
    [ -z "$output" ]
}

@test "(v) in-process --self-test が green(durable coverage pin)" {
    run python3 "$HOOK" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASSED"* ]]
}

@test "(v-b) self-test fail-closed が非vacuous(banner sabotage で run_self_test が非0)" {
    run python3 - "$HOOK" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ghealth", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# sabotage: banner を常に空にする → (ii)/(iii) absent+scribe の banner 期待が壊れる。
m._build_banner = lambda *a, **k: ""
rc = m.run_self_test()
# fail-closed なら sabotage で rc!=0。検出できれば exit0(test pass)、できなければ exit1(test fail)。
sys.exit(0 if rc != 0 else 1)
PY
    [ "$status" -eq 0 ]
}

@test "(wire) hooks.json が guard-health を role-inject と同形 fail-safe で SessionStart へ wire" {
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
    print("FAIL: guard-health wire が role-inject と同形 fail-safe(|| true)でない"); sys.exit(1)
if "[ -x" not in c:
    # 安全形の中核: script 不在/CLAUDE_PLUGIN_ROOT 異常時に無条件実行しない存在ガード。role-inject wire
    # テスト(session-start-role-inject.bats)が同じく `[ -x` を assert するのと対称（sc-ovq gate finding）。
    print("FAIL: guard-health wire が `[ -x \"$SCRIPT\" ]` 存在ガードを欠く（role-inject と同形でない）"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: guard-health wire は fail-safe([ -x ]+|| true)・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

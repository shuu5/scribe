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
#   (iii-b/c/d/e/f/g) bd-write moat（PreToolUse[Bash] → canonical bd-write-guard）の実配線検査（probe B2・sc-8e7i）:
#         wire 皆無 → banner / 2 wire 経路それぞれ単独で silent / 宣言有 + canonical 不在 → banner /
#         plugin 明示 disable → banner / 非実行 canonical(0644) + plugin wire → banner（gate は X_OK）/
#         settings wire 宣言有 + shim 本体不在 → banner。可用性 gate は **wire 経路ごとに実配線と同極性**
#         （plugin=[ -x ]・settings=shim 本体の `test -f`）で判定する。probe B とは独立に報告されることも pin。
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

    # bd-write moat fixture（probe B2・sc-8e7i）: canonical bd-write-guard + PreToolUse[Bash] wire。
    #   hook は canonical(BD_WRITE_GUARD)から scripts/hooks/ を 2 段上って <root>/hooks/hooks.json を探すため
    #   fixture も plugin と同一 layout で作る。wired = plugin hooks.json 有 / unwired = canonical だけ在る。
    #   canonical の mode は実配線の gate と同じ意味を持つ（plugin hooks.json は `[ -x ]` で gate する）ため
    #   健全 fixture は chmod +x する。NOEXEC fixture は 0644＝「読めるが非実行」で plugin 経路が fail-open する構成。
    WIRED_ROOT="$TEST_TMPDIR/bdw-plugin-wired"
    UNWIRED_ROOT="$TEST_TMPDIR/bdw-plugin-unwired"
    NOEXEC_ROOT="$TEST_TMPDIR/bdw-plugin-noexec"
    mkdir -p "$WIRED_ROOT/scripts/hooks" "$WIRED_ROOT/hooks" "$UNWIRED_ROOT/scripts/hooks" \
             "$NOEXEC_ROOT/scripts/hooks" "$NOEXEC_ROOT/hooks"
    echo '# canonical bd-write-guard stub' > "$WIRED_ROOT/scripts/hooks/bd-write-guard.py"
    echo '# canonical bd-write-guard stub' > "$UNWIRED_ROOT/scripts/hooks/bd-write-guard.py"
    echo '# canonical bd-write-guard stub' > "$NOEXEC_ROOT/scripts/hooks/bd-write-guard.py"
    chmod 755 "$WIRED_ROOT/scripts/hooks/bd-write-guard.py" "$UNWIRED_ROOT/scripts/hooks/bd-write-guard.py"
    chmod 644 "$NOEXEC_ROOT/scripts/hooks/bd-write-guard.py"
    cat > "$WIRED_ROOT/hooks/hooks.json" <<'JSON'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[
  {"type":"command","command":"SCRIPT=\"${CLAUDE_PLUGIN_ROOT}/scripts/hooks/bd-write-guard.py\"; if [ -x \"$SCRIPT\" ]; then python3 \"$SCRIPT\"; else exit 0; fi"}
]}]}}
JSON
    cp "$WIRED_ROOT/hooks/hooks.json" "$NOEXEC_ROOT/hooks/hooks.json"
    GUARD_WIRED="$WIRED_ROOT/scripts/hooks/bd-write-guard.py"
    GUARD_UNWIRED="$UNWIRED_ROOT/scripts/hooks/bd-write-guard.py"
    GUARD_NOEXEC="$NOEXEC_ROOT/scripts/hooks/bd-write-guard.py"
    GUARD_ABSENT="$TEST_TMPDIR/no-such-bd-write-guard.py"

    # settings 経路の **起動対象**（shim 本体）fixture。実配線は `test -f <shim> && python3 <shim>` ゆえ shim の
    # 実在が live の必要条件。hermetic に保つため $HOME ではなく fixture 内絶対 path を wire する。
    SHIM_PRESENT="$TEST_TMPDIR/shim-bd-write-guard.py"
    echo '# shim stub' > "$SHIM_PRESENT"
    SHIM_MISSING="$TEST_TMPDIR/no-such-shim-bd-write-guard.py"

    # config dir fixture: 空(wire 宣言なし) / settings 経由 shim wire あり / shim 本体が消えた wire /
    #                     plugin を明示 disable。
    CFG_EMPTY="$TEST_TMPDIR/cfg-empty"
    CFG_WIRED="$TEST_TMPDIR/cfg-wired"
    CFG_SHIM_GONE="$TEST_TMPDIR/cfg-shim-gone"
    CFG_DISABLED="$TEST_TMPDIR/cfg-disabled"
    mkdir -p "$CFG_EMPTY" "$CFG_WIRED" "$CFG_SHIM_GONE" "$CFG_DISABLED"
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"test -f \\"%s\\" && python3 \\"%s\\""}]}]}}' \
        "$SHIM_PRESENT" "$SHIM_PRESENT" > "$CFG_WIRED/settings.json"
    printf '{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"test -f \\"%s\\" && python3 \\"%s\\""}]}]}}' \
        "$SHIM_MISSING" "$SHIM_MISSING" > "$CFG_SHIM_GONE/settings.json"
    cat > "$CFG_DISABLED/settings.json" <<'JSON'
{"enabledPlugins":{"bdw-plugin-wired@local":false}}
JSON

    # config dir 配下の plugin 実配置 fixture（BD_WRITE_GUARD 非 pin 時の plugin root 追従・sc-8e7i）。
    #   CC は $CLAUDE_CONFIG_DIR/plugins/<name> を load するため probe もそこを見なければならない。
    CFG_PLUGIN="$TEST_TMPDIR/cfg-plugin"
    mkdir -p "$CFG_PLUGIN/plugins/beads-bdw/scripts/hooks" "$CFG_PLUGIN/plugins/beads-bdw/hooks"
    echo '# canonical bd-write-guard stub' > "$CFG_PLUGIN/plugins/beads-bdw/scripts/hooks/bd-write-guard.py"
    chmod 755 "$CFG_PLUGIN/plugins/beads-bdw/scripts/hooks/bd-write-guard.py"
    cp "$WIRED_ROOT/hooks/hooks.json" "$CFG_PLUGIN/plugins/beads-bdw/hooks/hooks.json"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# hook を実フック経路（stdin JSON → stdout）で起動する helper。cmdtokens/bdw/moat の解決先を env で切り替える。
#   $4/$5（BD_WRITE_GUARD / CLAUDE_CONFIG_DIR）は省略時 **健全な moat 構成**へ pin する。probe B2 は既定で
#   host 実設定を読むため、pin しないと既存 test が host の plugin 配備に依存して非 hermetic になる。
run_hook() {
    local cwd="$1" ctlib="$2" bdw="$3" guard="${4:-$GUARD_WIRED}" cfg="${5:-$CFG_EMPTY}"
    printf '{"cwd":"%s"}' "$cwd" \
        | CMDTOKENS_LIB="$ctlib" BEADS_BDW="$bdw" BD_WRITE_GUARD="$guard" CLAUDE_CONFIG_DIR="$cfg" \
          python3 "$HOOK"
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

@test "(iii-b) bd-write moat の wire 皆無 + scribe session → banner 有(moat 消失を loud 化・sc-8e7i)" {
    # 検査意図: bd write の「実行系」(probe B = bdw lock-dir) が緑でも moat は独立に消えうる。
    #   canonical guard は在るが誰も起動しない（plugin hooks.json 無し + settings 宣言無し）構成を pin する。
    #   sc-q2kn の bespoke guard 撤去で moat が wire 1 本依存になった結果、新たに開いた無音面。
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_UNWIRED" "$CFG_EMPTY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PLUGIN HEALTH WARNING"* ]]
    [[ "$output" == *"bd-write moat"* ]]
    [[ "$output" == *"PreToolUse"* ]]
    [[ "$output" == *"(無し)"* ]]                 # 検出した wire = 無し
    [[ "$output" == *"BD_WRITE_GUARD"* ]]         # moat 復旧 hint を含む
    [[ "$output" != *"fail-closed"* ]]            # probe B present ゆえ bdw 節は出さない（probe の独立性）
    [[ "$output" != *"git-destructive-guard"* ]]  # cmdtokens present ゆえ guard 節も出さない
}

@test "(iii-c) 健全な moat 構成では silent 維持(plugin wire 単独 / settings wire 単独・誤検知ゼロ)" {
    # acceptance(2): 正常構成で無音。2 wire 経路それぞれ **単独** で moat 成立と読むことを両方向で pin する
    #   （片方しか見ない実装だと、もう一方だけの構成で偽 banner を出す＝この test が RED になる）。
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_WIRED" "$CFG_EMPTY"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                              # plugin hooks.json wire 単独 → silent
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_UNWIRED" "$CFG_WIRED"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                              # settings 経由 shim wire 単独 → silent
}

@test "(iii-d) wire 宣言有 + canonical 不在 → banner 有(shim fail-open を検出・宣言だけ見る実装では緑)" {
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_ABSENT" "$CFG_WIRED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd-write moat"* ]]
    [[ "$output" == *"$GUARD_ABSENT"* ]]          # 解決した canonical path を含む
}

@test "(iii-e) plugin 明示 disable + settings wire 無 → banner 有(失敗モード i・宣言の実在に騙されない)" {
    # enabledPlugins の明示 false は「CC が hooks を load しない」観測可能な signal。hooks.json が在っても
    # moat は消えている。逆に entry 不在は auto-discover 既定 enable ゆえ disable と読まない（(iii-c) が pin）。
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_WIRED" "$CFG_DISABLED"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd-write moat"* ]]
    [[ "$output" == *"DISABLED"* ]]
}

@test "(iii-f) 非実行 canonical(0644) + plugin wire 単独 → banner 有(経路別 gate = X_OK・sc-8e7i)" {
    # plugin hooks.json の実配線は `if [ -x "$SCRIPT" ]; then python3 …; else exit 0; fi`＝gate は **X_OK**。
    # canonical が読めても非実行なら hook は exit0 で fail-open＝moat 消失。R_OK だけを見る検査器はここを
    # silent に取りこぼす（検出器自身の false-negative）。実行権限だけが違う 2 構成で対偶も pin する。
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_NOEXEC" "$CFG_EMPTY"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd-write moat"* ]]
    [[ "$output" == *"NOEXEC"* ]]
    chmod +x "$GUARD_NOEXEC"                      # mode 以外は同一構成
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_NOEXEC" "$CFG_EMPTY"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                              # chmod +x で silent へ戻る = 判定は X_OK のみに依存
}

@test "(iii-g) settings wire 宣言有 + shim 本体不在 → banner 有(起動対象の実在まで見る・sc-8e7i)" {
    # settings 経路の実配線は `test -f <shim> && python3 <shim>` で **shim 本体**を起動する。shim が消えていれば
    # && が短絡し guard は一切起動しない＝moat 消失。canonical は実在する（canonical 側 gate では捕まらない面）。
    run run_hook "$SCRIBE_CWD" "$CT_PRESENT" "$BDW_PRESENT" "$GUARD_UNWIRED" "$CFG_SHIM_GONE"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd-write moat"* ]]
    [[ "$output" == *"SHIM-MISSING"* ]]
    [ -f "$GUARD_UNWIRED" ]                       # 前提: canonical は在る(non-vacuous)
    # 対偶は (iii-c) 後段（同じ settings 形で shim 本体が在れば silent）が pin する。
}

@test "(iii-h) plugin root は CLAUDE_CONFIG_DIR に追従する(config dir に plugin 不在 → banner・sc-8e7i)" {
    # BD_WRITE_GUARD を pin している限りこの軸は一度も踏めない（root が env 起点になる）ため env を外して回す。
    # CC の plugin enablement は config dir ごとに独立（本ホストは全 session が per-account config dir）。
    # ~/.claude 固定で読む実装は、その session が決して load しない hooks.json を根拠に silent になる
    #   ＝検出器自身の false-silent。ここでは config dir に plugin 不在 + settings wire 無 → banner を pin。
    run env -u BD_WRITE_GUARD CMDTOKENS_LIB="$CT_PRESENT" BEADS_BDW="$BDW_PRESENT" \
        CLAUDE_CONFIG_DIR="$CFG_EMPTY" bash -c "printf '{\"cwd\":\"$SCRIBE_CWD\"}' | python3 '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd-write moat"* ]]
    [[ "$output" == *"(無し)"* ]]                 # ~/.claude 側 plugin を live と数えない
    # 対偶: 同じ env 状態で config dir 配下に plugin を置けば silent = 判定は config dir だけに依存。
    run env -u BD_WRITE_GUARD CMDTOKENS_LIB="$CT_PRESENT" BEADS_BDW="$BDW_PRESENT" \
        CLAUDE_CONFIG_DIR="$CFG_PLUGIN" bash -c "printf '{\"cwd\":\"$SCRIBE_CWD\"}' | python3 '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$CFG_PLUGIN/plugins/beads-bdw/hooks/hooks.json" ]   # 前提(non-vacuous)
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

@test "(iv-c) cwd 削除済み + garbage/空 stdin でも die しない(exit0・traceback 無し・orch-k33)" {
    # main() の except 経路の os.getcwd() が try 外にあり、cwd 削除済みだと FileNotFoundError が伝播し
    # traceback+exit1 で die しうる（「常に exit0・決して die しない」契約違反）。_safe_cwd() で "/" へ
    # degrade することを pin する（修正前は RED=traceback+rc1 / 後は GREEN）。
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

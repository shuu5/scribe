#!/usr/bin/env bats
# tests/session-boundary-heartbeat.bats
#
# admin cycle 境界 heartbeat（scripts/hooks/session-boundary-heartbeat.sh・sc-b6w / orch-0yof ②・
# 裁定-cycle-signal）の **e2e（stdin JSON → 自台帳 stamp）** と **hooks.json wire 検査** の hermetic bats。
#
# 役割: admin の SessionStart / SessionEnd で自台帳へ mtime stamp（`<ledger>/.beads/scribe-heartbeat`・
#   `last-sync` 同型）を焼き、orchestrator の配送観測（orch-4js9＝各 admin の最終 cycle 境界時刻・up/down・
#   未配送 for:X の滞留 age）に読ませる。**per-bead ack write は作らない**（裁定で明示却下）。
#
# 検証する契約不変条件:
#   (a)  admin + SessionStart → stamp が作られる・1 行 JSON に ts/event=session-start/source=startup/
#        session_id/ledger/role=admin が入る。
#   (b)  admin + SessionEnd → event=session-end・source=SessionEnd の reason(clear 等)を保つ
#        （裁定-cycle-unification: 普段は /clear・長寿命は respawn ＝どちらの境界かを orchestrator が読める）。
#   (c)  境界を跨ぐたび **mtime が前進**する（＝stamp の本体は mtime・acceptance(2) の実測 pin）。
#   (d)  auto-compact 発火（SessionStart source=compact）が source として保存される（総点検追補3 の signal）。
#   (w-*) write-isolation: 書くのは **自台帳のみ**（orch 台帳へ書かない）・**bd を一切呼ばない**
#         （DB write ゼロ・per-bead ack write なし＝PATH 前置の mock bd への呼出記録が空であること）。
#   (r-*) role: worker（.worktrees / .claude/worktrees / SCRIBE_ROLE=worker）・consult・none → 焼かない。
#   (o)   自台帳 == orch 台帳（orchestrator 自身）→ skip（配送観測の観測側であって被観測側でない）。
#   (f-*) fail-safe: .beads 無し / .beads が write 不能 → exit0 degrade（セッションを壊さない）。
#   (wire) hooks.json が SessionStart と SessionEnd の両方へ fail-safe（`[ -x ]`+`|| true`）で wire。
#   (gi)  scribe repo の root .gitignore が stamp を除外している（runtime 生成物を commit しない）。
#
# 実行: bats tests/session-boundary-heartbeat.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$REPO/scripts/hooks/session-boundary-heartbeat.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d -t scribe-hb-bats-XXXXXX)"

    SELF_LEDGER="$TEST_TMPDIR/proj-sc"
    ORCH_LEDGER="$TEST_TMPDIR/scriptorium"
    ORCH_SELF="$TEST_TMPDIR/proj-orch"
    NOBEADS="$TEST_TMPDIR/proj-none"
    mkdir -p "$SELF_LEDGER/.beads" "$SELF_LEDGER/sub" \
             "$ORCH_LEDGER/.beads" "$ORCH_SELF/.beads" "$NOBEADS"
    printf '{"database":"dolt","dolt_database":"sc"}'   > "$SELF_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_SELF/.beads/metadata.json"
    SELF_CWD="$SELF_LEDGER/sub"
    STAMP="$SELF_LEDGER/.beads/scribe-heartbeat"

    WT_DIR="$SELF_LEDGER/.worktrees/spawn/x-1"
    CC_WT_DIR="$SELF_LEDGER/.claude/worktrees/x-1"
    mkdir -p "$WT_DIR" "$CC_WT_DIR"

    # mock bd: 呼ばれたら記録（heartbeat は bd を一切呼ばない＝呼出記録が空であることを assert する）
    BD_CALL_LOG="$TEST_TMPDIR/bd-calls.log"
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    cat > "$BIN/bd" <<MOCKBD
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BD_CALL_LOG"
echo '[]'
exit 0
MOCKBD
    chmod +x "$BIN/bd"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# SessionStart 経路（source= startup|resume|clear|compact）
run_start() { # $1=cwd $2=source  他=env
    local cwd="$1" src="$2"; shift 2
    printf '{"cwd":"%s","session_id":"sess-hb-1","hook_event_name":"SessionStart","source":"%s"}' "$cwd" "$src" \
        | env "$@" PATH="$BIN:$PATH" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" bash "$HOOK"
}

# SessionEnd 経路（reason= clear|logout|prompt_input_exit|other）
run_end() { # $1=cwd $2=reason  他=env
    local cwd="$1" reason="$2"; shift 2
    printf '{"cwd":"%s","session_id":"sess-hb-1","hook_event_name":"SessionEnd","reason":"%s"}' "$cwd" "$reason" \
        | env "$@" PATH="$BIN:$PATH" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" bash "$HOOK"
}

@test "static: hook が実行可能・bash 構文 OK" {
    [ -x "$HOOK" ]
    run bash -n "$HOOK"
    [ "$status" -eq 0 ]
}

@test "(a) admin + SessionStart → 自台帳へ stamp（1 行 JSON: ts/event/source/session_id/ledger/role）" {
    run run_start "$SELF_CWD" startup
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]
    run cat "$STAMP"
    [[ "$output" == *'"event":"session-start"'* ]]
    [[ "$output" == *'"source":"startup"'* ]]
    [[ "$output" == *'"session_id":"sess-hb-1"'* ]]
    [[ "$output" == *'"ledger":"sc"'* ]]
    [[ "$output" == *'"role":"admin"'* ]]
    [[ "$output" == *'"ts":"20'* ]]                       # ISO8601（last-sync 同型）
    # 1 行 JSON であること（orchestrator が parse する面）
    [ "$(wc -l < "$STAMP")" -eq 1 ]
    run python3 -c "import json,sys; d=json.load(open('$STAMP')); print(d['event'])"
    [ "$status" -eq 0 ]
    [[ "$output" == "session-start" ]]
}

@test "(b) admin + SessionEnd → event=session-end・reason を source として保つ" {
    run run_end "$SELF_CWD" clear
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]
    run cat "$STAMP"
    [[ "$output" == *'"event":"session-end"'* ]]
    [[ "$output" == *'"source":"clear"'* ]]
}

@test "(c) 境界を跨ぐたび mtime が前進する(stamp の本体は mtime・acceptance(2))" {
    run run_start "$SELF_CWD" startup
    [ "$status" -eq 0 ]
    m1="$(stat -c %Y "$STAMP")"
    # mtime 秒解像度ゆえ 1 秒待ってから 2 度目の境界（SessionEnd）を跨ぐ
    sleep 1
    run run_end "$SELF_CWD" logout
    [ "$status" -eq 0 ]
    m2="$(stat -c %Y "$STAMP")"
    [ "$m2" -gt "$m1" ]
    run cat "$STAMP"
    [[ "$output" == *'"event":"session-end"'* ]]          # 中身も最新境界で上書きされる（追記でない）
}

@test "(d) auto-compact 発火(source=compact)が signal として保存される(総点検追補3)" {
    run run_start "$SELF_CWD" compact
    [ "$status" -eq 0 ]
    run cat "$STAMP"
    [[ "$output" == *'"source":"compact"'* ]]
}

@test "(w-a) write-isolation: orch 台帳へは書かない(foreign へ stamp を作らない)" {
    run run_start "$SELF_CWD" startup
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]                                        # 自台帳には焼いた（非vacuous）
    [ ! -f "$ORCH_LEDGER/.beads/scribe-heartbeat" ]        # foreign 台帳は無傷
}

@test "(w-b) bd を一切呼ばない(DB write ゼロ・per-bead ack write は作らない＝裁定で明示却下)" {
    run run_start "$SELF_CWD" startup
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]
    [ ! -f "$BD_CALL_LOG" ]                                # mock bd への呼出がゼロ
}

@test "(w-c) tmp ファイルを残さない(atomic rename)" {
    run run_start "$SELF_CWD" startup
    [ "$status" -eq 0 ]
    run bash -c "ls '$SELF_LEDGER/.beads/' | grep -c 'scribe-heartbeat.tmp' || true"
    [[ "$output" == "0" ]]
}

@test "(r-a) worker: cwd .worktrees/ 配下 → 焼かない" {
    run run_start "$WT_DIR" startup
    [ "$status" -eq 0 ]
    [ ! -f "$STAMP" ]
}

@test "(r-b) worker: cwd .claude/worktrees/ 配下 → 焼かない" {
    run run_start "$CC_WT_DIR" startup
    [ "$status" -eq 0 ]
    [ ! -f "$STAMP" ]
}

@test "(r-c) worker: SCRIBE_ROLE=worker → 焼かない" {
    run run_start "$SELF_CWD" startup SCRIBE_ROLE=worker
    [ "$status" -eq 0 ]
    [ ! -f "$STAMP" ]
}

@test "(r-d) consult: SCRIBE_ROLE=consult → 焼かない(cycle 境界は admin の signal)" {
    run run_start "$SELF_CWD" startup SCRIBE_ROLE=consult
    [ "$status" -eq 0 ]
    [ ! -f "$STAMP" ]
}

@test "(r-e) SCRIBE_ROLE=none(opt-out) → 焼かない" {
    run run_start "$SELF_CWD" startup SCRIBE_ROLE=none
    [ "$status" -eq 0 ]
    [ ! -f "$STAMP" ]
}

@test "(o) 自台帳 == orch 台帳(orchestrator 自身) → skip(観測側は被観測側でない)" {
    run run_start "$ORCH_SELF" startup
    [ "$status" -eq 0 ]
    [ ! -f "$ORCH_SELF/.beads/scribe-heartbeat" ]
}

@test "(q) 成功経路は stdout 無出力(SessionStart の stdout は context に注入される＝heartbeat は語らない)" {
    run run_start "$SELF_CWD" startup
    [ "$status" -eq 0 ]
    [ -f "$STAMP" ]                                        # 焼いた（非vacuous）
    [ -z "$output" ]                                       # が、何も出力しない（context を汚さない）
    run run_end "$SELF_CWD" clear
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(u) walk-up は 1 回(metadata 欠落の .beads が途中に在っても別台帳へ焼かない・sc-b6w self-review [nit])" {
    # cwd と自台帳の間に「.beads はあるが metadata.json が無い」ディレクトリを挟む。
    # root と db を独立に walk-up すると root=中間dir / db=上位台帳 となり **無関係な .beads へ stamp** を焼く。
    MID="$SELF_LEDGER/mid"
    mkdir -p "$MID/.beads" "$MID/deep"
    run run_start "$MID/deep" startup
    [ "$status" -eq 0 ]
    [ ! -f "$MID/.beads/scribe-heartbeat" ]                # 中間の（識別不能な）台帳へは焼かない
    [ ! -f "$STAMP" ]                                      # 上位台帳へも焼かない（識別不能 → no-op degrade）
}

@test "(f-a) .beads 無し(scribe 管轄外) → no-op exit0" {
    run run_start "$NOBEADS" startup
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f-b) .beads が write 不能 → exit0 degrade(セッションを壊さない)" {
    chmod 500 "$SELF_LEDGER/.beads"
    run run_start "$SELF_CWD" startup
    chmod 700 "$SELF_LEDGER/.beads"
    [ "$status" -eq 0 ]                                    # die しない
    [ ! -f "$STAMP" ]                                      # 焼けてはいない（degrade）
}

@test "(f-c) SessionEnd で reason 欠落 → source=unknown で焼く(die しない)" {
    run bash -c "printf '{\"cwd\":\"%s\",\"session_id\":\"s\",\"hook_event_name\":\"SessionEnd\"}' '$SELF_CWD' \
        | env PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' bash '$HOOK'"
    [ "$status" -eq 0 ]
    run cat "$STAMP"
    [[ "$output" == *'"event":"session-end"'* ]]
    [[ "$output" == *'"source":"unknown"'* ]]
}

@test "(wire) hooks.json が heartbeat を SessionStart と SessionEnd の両方へ fail-safe で wire" {
    run python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                 # valid JSON でなければ die
for ev in ("SessionStart", "SessionEnd"):
    groups = d.get("hooks", {}).get(ev, [])
    cmds = [h.get("command", "") for g in groups for h in g.get("hooks", [])]
    hb = [c for c in cmds if "session-boundary-heartbeat.sh" in c]
    if not hb:
        print("FAIL: %s に heartbeat wire が無い" % ev); sys.exit(1)
    c = hb[0]
    if "|| true" not in c or "[ -x" not in c:
        print("FAIL: %s の heartbeat wire が fail-safe([ -x ]+|| true)でない" % ev); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: heartbeat は SessionStart/SessionEnd 両方へ fail-safe wire・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "(gi) root .gitignore が stamp を除外(runtime 生成物を commit しない・last-sync 同型)" {
    run grep -Fxq '/.beads/scribe-heartbeat' "$REPO/.gitignore"
    [ "$status" -eq 0 ]
    # cc-session subtree ledger 側の同型 marker も root .gitignore で除外する(sc-c4fr)
    run grep -Fxq '/cc-session/.beads/scribe-heartbeat' "$REPO/.gitignore"
    [ "$status" -eq 0 ]
}

@test "(gi) cc-session/.beads/.gitignore が bd 必須パターンを持つ(sc-c4fr)" {
    local gi="$REPO/cc-session/.beads/.gitignore"
    [ -f "$gi" ]
    for pat in 'last_pull' 'proxieddb/' 'proxied_server_client_info.json'; do
        run grep -Fxq "$pat" "$gi"
        [ "$status" -eq 0 ]
    done
}

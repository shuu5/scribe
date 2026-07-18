#!/usr/bin/env bats
# tests/session-stop-push.bats
#
# universal sync Layer2 — throttle 付き admin-only Stop hook 即 push（sc-fz5i / orch-ptaq relay /
# orch-klca 論点5）の **e2e（Stop stdin JSON → bdw funnel push）** と **hooks.json wire 検査** の hermetic bats。
#
# hook wrapper = scripts/hooks/session-stop-push.sh（policy: role gate / 自台帳解決。旧 orch skip は sc-i4xc で解除済）
# 実体 script  = scripts/scribe-sync-push.sh（throttle / write-signal / remote / bdw funnel push / marker stamp）
#
# 検証する契約不変条件（mandate 検証リスト①-⑤ + scope-fence）:
#   (①) 非 admin（worker/consult/none）→ no-push（role 規律不変・⑧ MACHINE 軸）
#   (②) throttle 窓内 → no-push
#   (③) 書き込み無し → no-push。**read で bump する .beads/last-touched を signal にしない**（非空虚 pin：
#        last-touched を newer にしても push しない＝last-touched を使う実装は RED）
#   (④) 条件成立 → **bdw funnel 経由**の push が呼ばれる（bare bd dolt push が出ない）＝invariant③ 唯一の enforcement
#   (⑤) throttle marker 名が .beads/last-sync / scribe-heartbeat / bd-native runtime と字面 disjoint（専用名）
#   (safety) Stop hook exit2=会話 block ゆえ **全経路 exit 0**：mock bdw を非0 exit させても hook status0 かつ
#            stdout 無出力（stderr のみ・loud=stderr であって非0終了ではない）
#   (hot)    skip 三経路（非admin/throttle/no-write）で mock bd と mock bdw の呼出ログが**共に空**
#            （stat だけで早期 return・bd/bdw subprocess は実 push 経路でのみ起動）
#   (stamp)  marker は実 push 成功経路でのみ前進（skip 三経路後は mtime 不変）／push 直後の再 Stop（書込無し）→ no-push
#   (fn)     write 検知の fail 方向：marker 不在＋write あり → push（永久 no-op 空虚緑を kill）
#   (emb)    副 signal：BDW_NO_AUTOEXPORT 相当（mirror 凍結）でも embeddeddolt の write 痕跡で push
#   (remote) remote 未設定 → silent no-op（warn なし＝stderr も空）
#   (wire)   hooks.json が Stop へ banner 系 fail-safe（`[ -x ]`+`|| true`）で wire
#   (gi)     root .gitignore が marker を除外（runtime 生成物を commit しない・scribe-heartbeat 同型）
#
# 実行: bats tests/session-stop-push.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$REPO/scripts/hooks/session-stop-push.sh"
    SYNC="$REPO/scripts/scribe-sync-push.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/scribe-stoppush-XXXXXX")"

    SELF_LEDGER="$TEST_TMPDIR/proj-sc"
    ORCH_LEDGER="$TEST_TMPDIR/scriptorium"
    ORCH_SELF="$TEST_TMPDIR/proj-orch"
    NOBEADS="$TEST_TMPDIR/proj-none"
    # embeddeddolt は既定では作らない（副 signal を意図せず発火させない）。
    # (emb) テストだけが自前で mkdir + touch して mirror 凍結時のフォールバックを検証する。
    mkdir -p "$SELF_LEDGER/.beads" "$SELF_LEDGER/sub" \
             "$ORCH_LEDGER/.beads" "$ORCH_SELF/.beads" "$NOBEADS/sub"
    printf '{"database":"dolt","dolt_database":"sc"}'   > "$SELF_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_SELF/.beads/metadata.json"

    SELF_CWD="$SELF_LEDGER/sub"
    MARKER="$SELF_LEDGER/.beads/scribe-push-throttle"
    ISSUES="$SELF_LEDGER/.beads/issues.jsonl"
    LASTTOUCHED="$SELF_LEDGER/.beads/last-touched"
    EMB="$SELF_LEDGER/.beads/embeddeddolt"

    WT_DIR="$SELF_LEDGER/.worktrees/spawn/x-1"
    CC_WT_DIR="$SELF_LEDGER/.claude/worktrees/x-1"
    mkdir -p "$WT_DIR" "$CC_WT_DIR"

    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    BD_CALL_LOG="$TEST_TMPDIR/bd-calls.log"
    BDW_CALL_LOG="$TEST_TMPDIR/bdw-calls.log"

    # mock bd（PATH 前置）: 呼出を記録。`dolt remote list` は remote を emit（_sp_has_remote 制御）。
    # 他 subcmd は空配列。**push は絶対に受け付けない**（hook が bare bd dolt push を叩けば log に現れる＝④ が検出）。
    cat > "$BIN/bd" <<MOCKBD
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BD_CALL_LOG"
case "\$*" in
  *"dolt remote list"*)
     [ -n "\${MOCK_BD_NO_REMOTE:-}" ] && exit 0
     printf 'origin\tgit+https://example/repo.git\n'
     exit 0 ;;
esac
echo '[]'
exit 0
MOCKBD
    chmod +x "$BIN/bd"

    # mock bdw（BEADS_BDW seam）: 実 scripts/bdw shim が exec する先。呼出を記録し MOCK_BDW_RC で exit。
    cat > "$BIN/mock-bdw" <<MOCKBDW
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BDW_CALL_LOG"
[ -n "\${MOCK_BDW_OUT:-}" ] && printf '%s\n' "\$MOCK_BDW_OUT" >&2
exit \${MOCK_BDW_RC:-0}
MOCKBDW
    chmod +x "$BIN/mock-bdw"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# mtime helpers（決定的・秒解像度）
mkold()  { touch -d '2 hours ago' "$1"; }   # 旧
mkmid()  { touch -d '1 hour ago'  "$1"; }   # 中
mknow()  { touch "$1"; }                     # 現在
mtime()  { stat -c %Y "$1" 2>/dev/null; }

# Stop 経路（stdin JSON → hook）。第1引数=cwd、以降=追加 env。
run_stop() { # $1=cwd  rest=env
    local cwd="$1"; shift
    printf '{"cwd":"%s","session_id":"sess-stop-1","hook_event_name":"Stop","stop_hook_active":false}' "$cwd" \
        | env "$@" PATH="$BIN:$PATH" BEADS_BDW="$BIN/mock-bdw" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" bash "$HOOK"
}

# ============================ static ============================

@test "static: hook / sync 実体が実行可能・bash 構文 OK" {
    [ -x "$HOOK" ]
    [ -x "$SYNC" ]
    run bash -n "$HOOK"; [ "$status" -eq 0 ]
    run bash -n "$SYNC"; [ "$status" -eq 0 ]
}

# ============================ ① role 規律 ============================

@test "(①-a) worker: cwd .worktrees/ → no-push（bd/bdw 未呼出）" {
    mkmid "$MARKER"; mknow "$ISSUES"     # push 条件は満たす（role が唯一の止め手＝非空虚）
    run run_stop "$WT_DIR" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(①-b) worker: cwd .claude/worktrees/ → no-push" {
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$CC_WT_DIR" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
}

@test "(①-c) worker: SCRIBE_ROLE=worker → no-push" {
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$SELF_CWD" SCRIBE_ROLE=worker SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
}

@test "(①-d) consult: SCRIBE_ROLE=consult → no-push" {
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$SELF_CWD" SCRIBE_ROLE=consult SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
}

@test "(①-e) none: SCRIBE_ROLE=none（opt-out）→ no-push" {
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$SELF_CWD" SCRIBE_ROLE=none SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
}

@test "(o) 自台帳 == orch 台帳（orchestrator 自身）→ 解除後は通常どおり push（旧 rollout gate 解除・sc-i4xc/orch-t4oo）" {
    # 旧 pin（skip）の反転: un-10h5 実層 Seq-2/5 GREEN 充足で orch-skip は解除された。
    # orch 台帳を他台帳と同扱いで push する（skip を復活させた実装は本テストが RED にする）。
    mknow "$ORCH_SELF/.beads/issues.jsonl"   # write 有（非空虚）
    run run_stop "$ORCH_SELF/.beads/.." SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ -f "$BDW_CALL_LOG" ]
    run grep -q 'dolt push' "$BDW_CALL_LOG"; [ "$status" -eq 0 ]
    [ -f "$ORCH_SELF/.beads/scribe-push-throttle" ]
}

# ============================ ② throttle ============================

@test "(②) throttle 窓内（marker が最近）→ no-push（bd/bdw 未呼出＝stat だけで早期 return）" {
    mknow "$MARKER"; mknow "$ISSUES"      # marker 直近 → 窓内。write 有でも throttle が止める（非空虚）
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=10
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
    [ ! -f "$BD_CALL_LOG" ]
}

# ============================ ③ write-signal ============================

@test "(③) 書き込み無し → no-push（issues.jsonl が marker より旧・bd/bdw 未呼出）" {
    mkold "$ISSUES"; mkmid "$MARKER"      # 前回 push 以降 write 無し
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0   # throttle 無効＝write gate が唯一の止め手
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(③-nonvacuous) read で bump した last-touched は signal にしない（last-touched newer でも no-push）" {
    mkold "$ISSUES"; mkmid "$MARKER"
    mknow "$LASTTOUCHED"                  # bd の READ が last-touched を bump（marker より newer）
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]              # last-touched を write-signal に使う実装は RED になる
}

# ============================ ④ funnel enforcement（唯一の砦）============================

@test "(④) 条件成立 → bdw funnel 経由 push（bare bd dolt push が出ない）" {
    mkmid "$MARKER"; mknow "$ISSUES"      # write 有・throttle 無効・remote 有
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    # (a) hook が scripts/bdw（funnel）へ `dolt push` を渡した
    [ -f "$BDW_CALL_LOG" ]
    run grep -q 'dolt push' "$BDW_CALL_LOG"; [ "$status" -eq 0 ]
    # (b) PATH 前置 mock bd の call-log に **bare dolt push が現れない**（remote list のみ）
    run grep -q 'dolt push' "$BD_CALL_LOG"; [ "$status" -ne 0 ]
    run grep -q 'dolt remote list' "$BD_CALL_LOG"; [ "$status" -eq 0 ]
}

@test "(④-mutation) push 呼出が唯一の funnel 実体：push 実行時のみ BDW_CALL_LOG が生じる" {
    # 反証: write が無ければ push は起きず funnel log も生じない（④ が push の存在に依存＝非空虚）
    mkold "$ISSUES"; mkmid "$MARKER"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]
}

# ============================ ⑤ marker namespace disjoint ============================

@test "(⑤) throttle marker 名が既存 stamp / bd-native runtime と字面 disjoint" {
    # 既定 marker 名（scribe-push-throttle）が禁則集合のいずれとも一致しないことを構造 pin。
    name="$(SCRIBE_PUSH_THROTTLE_FILENAME= bash -c 'echo "${SCRIBE_PUSH_THROTTLE_FILENAME:-scribe-push-throttle}"')"
    [ "$name" = "scribe-push-throttle" ]
    for forbidden in last-sync scribe-heartbeat last-touched push-state.json sync-state.json export-state.json .local_version issues.jsonl; do
        [ "$name" != "$forbidden" ]
    done
    # 実 push 後に生成される marker が実在ファイル名として上記と衝突しないことも実測
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ -f "$MARKER" ]
    [ "$(basename "$MARKER")" = "scribe-push-throttle" ]
}

# ============================ session-safety（全経路 exit 0）============================

@test "(safety) mock bdw が非0 exit → hook status0・push は試行・marker 前進せず（stdout 空は safety-stderr で pin）" {
    mkmid "$MARKER"; mknow "$ISSUES"
    m0="$(mtime "$MARKER")"
    # 注: bats の run は stdout+stderr を $output に併合するため、stdout-only の空検査は
    #     (safety-stderr) がファイル分離で担う。本テストは exit0 / push 試行 / marker 不前進を pin。
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0 MOCK_BDW_RC=1 MOCK_BDW_OUT=boom
    [ "$status" -eq 0 ]                   # exit2 を絶対に返さない（会話 block/brick 防止）
    [ -f "$BDW_CALL_LOG" ]                # push は試みた（非空虚）
    [ "$(mtime "$MARKER")" -eq "$m0" ]    # 失敗時 marker は前進しない（次窓で再試行＝後続回収）
}

@test "(safety-stderr) push 失敗は stderr へ loud 記録するが stdout は汚さない" {
    mkmid "$MARKER"; mknow "$ISSUES"
    # stdout / stderr を分離捕捉
    printf '{"cwd":"%s","session_id":"s","hook_event_name":"Stop"}' "$SELF_CWD" \
        | env SCRIBE_PUSH_THROTTLE_MIN=0 MOCK_BDW_RC=1 MOCK_BDW_OUT=network-fail \
              PATH="$BIN:$PATH" BEADS_BDW="$BIN/mock-bdw" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              bash "$HOOK" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err"
    rc=$?
    [ "$rc" -eq 0 ]
    [ ! -s "$TEST_TMPDIR/out" ]           # stdout 空
    [ -s "$TEST_TMPDIR/err" ]             # stderr に warn 有
    run cat "$TEST_TMPDIR/err"
    [[ "$output" == *"scribe-sync-push"* ]]
}

@test "(safety-conflict) genuine conflict 出力は loud だが exit0（block ではない）" {
    mkmid "$MARKER"; mknow "$ISSUES"
    printf '{"cwd":"%s","session_id":"s","hook_event_name":"Stop"}' "$SELF_CWD" \
        | env SCRIBE_PUSH_THROTTLE_MIN=0 MOCK_BDW_RC=1 MOCK_BDW_OUT="merge conflict detected" \
              PATH="$BIN:$PATH" BEADS_BDW="$BIN/mock-bdw" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              bash "$HOOK" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err"
    [ "$?" -eq 0 ]
    [ ! -s "$TEST_TMPDIR/out" ]
    run cat "$TEST_TMPDIR/err"
    [[ "$output" == *"CONFLICT"* ]]
}

@test "(q) 成功経路も stdout 無出力（Stop hook は語らない）" {
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ -f "$BDW_CALL_LOG" ]                # 焼いた（非空虚）
    [ -z "$output" ]
}

# ============================ hot path（skip 三経路は subprocess ゼロ）============================

@test "(hot) skip 三経路（非admin/throttle/no-write）で bd・bdw 呼出ログが共に空" {
    # 非 admin
    mkmid "$MARKER"; mknow "$ISSUES"
    run run_stop "$WT_DIR" SCRIBE_PUSH_THROTTLE_MIN=0
    [ ! -f "$BD_CALL_LOG" ]; [ ! -f "$BDW_CALL_LOG" ]
    # throttle 窓内
    mknow "$MARKER"; mknow "$ISSUES"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=10
    [ ! -f "$BD_CALL_LOG" ]; [ ! -f "$BDW_CALL_LOG" ]
    # 書込無し
    mkold "$ISSUES"; mkmid "$MARKER"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ ! -f "$BD_CALL_LOG" ]; [ ! -f "$BDW_CALL_LOG" ]
}

# ============================ marker stamp discipline ============================

@test "(stamp-a) skip 三経路後は marker mtime 不変（前進させない＝偽 landed を作らない）" {
    # throttle 窓内 skip: marker=now（10min 窓内）・write 有でも throttle が止める
    mknow "$ISSUES"; mknow "$MARKER"; m0="$(mtime "$MARKER")"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=10
    [ "$(mtime "$MARKER")" -eq "$m0" ]
    # no-write skip: throttle 無効・issues が marker より旧（write 無し）
    mkold "$ISSUES"; mkmid "$MARKER"; m0="$(mtime "$MARKER")"
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$(mtime "$MARKER")" -eq "$m0" ]
}

@test "(stamp-b) push 成功 → marker 前進、直後の再 Stop（書込無し）→ no-push（自己 bump loop を塞ぐ）" {
    mkmid "$MARKER"; mknow "$ISSUES"; m0="$(mtime "$MARKER")"
    # 1 回目: push 発火（mock bdw は auto-export しない＝issues.jsonl は現在時刻のまま）
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ -f "$BDW_CALL_LOG" ]
    [ "$(mtime "$MARKER")" -ge "$m0" ]                 # marker は前進（>= 元の中間時刻）
    n1="$(wc -l < "$BDW_CALL_LOG")"
    # 2 回目: 書込無し（issues.jsonl 不変）で再 Stop → marker.mtime >= issues.jsonl.mtime ゆえ no-push
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    n2="$(wc -l < "$BDW_CALL_LOG")"
    [ "$n2" -eq "$n1" ]                                # push 回数は増えない（恒常 no-op でなく loop でもない）
}

# ============================ write 検知 fail 方向 / 副 signal ============================

@test "(fn) marker 不在 ＋ write あり → push（永久 no-op 空虚緑を kill・fail は push 候補側へ）" {
    rm -f "$MARKER"                       # marker 不在（初回）
    mknow "$ISSUES"                       # write 有
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=10
    [ "$status" -eq 0 ]
    [ -f "$BDW_CALL_LOG" ]                # marker 不在は「窓外＋書込あり」へ倒す＝push
}

@test "(emb) 副 signal：mirror 凍結（issues.jsonl 旧）でも embeddeddolt の write 痕跡で push" {
    mkdir -p "$EMB/sc/.dolt"
    mkold "$ISSUES"; mkmid "$MARKER"      # mirror は marker より旧（BDW_NO_AUTOEXPORT 相当）
    mknow "$EMB/sc/.dolt/repo_state.json" # dolt 内部 write 痕跡が marker より新しい
    run run_stop "$SELF_CWD" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ -f "$BDW_CALL_LOG" ]                # embeddeddolt の新エントリを find -newer が検出 → push
}

# ============================ remote 未設定 = silent no-op ============================

@test "(remote) remote 未設定 → silent no-op（push せず・warn も出さない＝stderr 空）" {
    mkmid "$MARKER"; mknow "$ISSUES"      # write 有・throttle 無効（remote だけが止め手）
    printf '{"cwd":"%s","session_id":"s","hook_event_name":"Stop"}' "$SELF_CWD" \
        | env SCRIBE_PUSH_THROTTLE_MIN=0 MOCK_BD_NO_REMOTE=1 \
              PATH="$BIN:$PATH" BEADS_BDW="$BIN/mock-bdw" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              bash "$HOOK" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err"
    [ "$?" -eq 0 ]
    [ ! -f "$BDW_CALL_LOG" ]              # push しない
    [ ! -s "$TEST_TMPDIR/out" ]           # stdout 空
    [ ! -s "$TEST_TMPDIR/err" ]           # stderr 空（silent・warn を出さない＝invariant⑦）
}

# ============================ graceful no-op ============================

@test "(f-a) .beads 無し（scribe 管轄外）→ no-op exit0（無出力）" {
    run run_stop "$NOBEADS/sub" SCRIBE_PUSH_THROTTLE_MIN=0
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BDW_CALL_LOG" ]
}

@test "(f-b) bd 不在（PATH に bd 無し）→ silent no-op（push せず・warn なし・exit0＝invariant⑦ 第3枝）" {
    # invariant⑦ の silent no-op は「remote 未設定 /(remote)・.beads 無し /(f-a)・**bd 不在**」の 3 枝。
    # 本テストは 3 枝目（bd binary が PATH に無い）を非空虚に pin する（write 有・throttle 無効＝bd 不在だけが止め手）。
    # bd は ~/.local/bin にのみ存在するため PATH を /usr/bin:/bin へ絞り bd を不在化（coreutils は温存）。
    mkmid "$MARKER"; mknow "$ISSUES"
    printf '{"cwd":"%s","session_id":"s","hook_event_name":"Stop"}' "$SELF_CWD" \
        | env SCRIBE_PUSH_THROTTLE_MIN=0 BEADS_BDW="$BIN/mock-bdw" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              PATH="/usr/bin:/bin" \
              bash "$HOOK" >"$TEST_TMPDIR/out" 2>"$TEST_TMPDIR/err"
    rc=$?
    [ "$rc" -eq 0 ]                       # command -v bd = false → _sp_has_remote return1 → silent no-op
    [ ! -f "$BDW_CALL_LOG" ]              # push しない（bare bd も bdw も呼ばない）
    [ ! -s "$TEST_TMPDIR/out" ]           # stdout 空
    [ ! -s "$TEST_TMPDIR/err" ]           # stderr 空（silent・warn を出さない＝invariant⑦）
}

# ============================ wire / gitignore ============================

@test "(wire) hooks.json が Stop へ banner 系 fail-safe（[ -x ]+|| true）で wire・script 実行可能" {
    run python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                      # valid JSON でなければ die
groups = d.get("hooks", {}).get("Stop", [])
cmds = [h.get("command", "") for g in groups for h in g.get("hooks", [])]
sp = [c for c in cmds if "session-stop-push.sh" in c]
if not sp:
    print("FAIL: Stop に session-stop-push wire が無い"); sys.exit(1)
c = sp[0]
if "|| true" not in c or "[ -x" not in c:
    print("FAIL: Stop wire が banner 系 fail-safe([ -x ]+|| true)でない"); sys.exit(1)
# guard 系（if...then...else exit0）で wire していない＝exit2 伝播を作らない
if "if [ -x" in c:
    print("FAIL: Stop wire が guard 系(if/then/else)＝exit2 伝播しうる形"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: Stop は banner 系 fail-safe wire・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "(wire-untouched) 既存 SessionEnd heartbeat wire は不触で残置（push を足さない）" {
    run python3 - "$HOOKS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for ev in ("SessionStart", "SessionEnd"):
    cmds = [h.get("command","") for g in d.get("hooks",{}).get(ev,[]) for h in g.get("hooks",[])]
    if not any("session-boundary-heartbeat.sh" in c for c in cmds):
        print("FAIL: %s の heartbeat wire が消えた" % ev); sys.exit(1)
    if any("session-stop-push.sh" in c for c in cmds):
        print("FAIL: %s に stop-push が紛れ込んだ" % ev); sys.exit(1)
print("OK: heartbeat wire は不触・stop-push は Stop のみ")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "(gi) root .gitignore が marker を除外（runtime 生成物を commit しない・scribe-heartbeat 同型）" {
    run grep -Fq '/.beads/scribe-push-throttle' "$REPO/.gitignore"
    [ "$status" -eq 0 ]
}

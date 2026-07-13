#!/usr/bin/env bats
# tests/session-start-mailbox-scan.bats
#
# SessionStart 下り mailbox hook（scripts/hooks/session-start-mailbox-scan.sh・sc-p2o・top-spec §5.3）の
# **e2e（stdin JSON → stdout surface の実フック契約）** と **hooks.json wire 検査** の hermetic bats。
#
# 役割: SessionStart で scriptorium orch 台帳を direct read（`bd -C <orch-anchor> list --label for:<self>
#   --status open --readonly`）し、自 project 宛 open bead を surface する下り知識中継（pull 型）。
#   orchestrator 側 workinprogress hook（orch-7py）の対向形。正本 = scriptorium top-spec §5.3 会計②。
#
# 方式（hermetic・実 plugin/DB 非依存）:
#   - 台帳 fixture: temp に self(dolt_database=sc) と orch(dolt_database=orch) の .beads/metadata.json。
#   - mock bd: PATH 前置の stub。全呼出を BD_CALL_LOG に記録し、`repo`（hydrate = repo sync/add）が
#     来たら異常終了する。MOCK_BD_MODE(ok/empty/err) で固定応答を切替える。
#   - hook を JSON payload を stdin に流して subprocess 実行し $status と $output を assert する。
#   - orch anchor は SCRIBE_ORCH_ANCHOR env で fixture へ固定（per-machine 既定 path に依存させない）。
#
# 検証する契約不変条件（sc-p2o gate finding 1 の提案 (i)-(vii)+(wire)）:
#   (i)   orch fixture(dolt_database!=self)に for:<self> open bead → surface 出力 + exit0。
#   (i-limit)    direct read は --limit 0(全件) を渡す（bd 既定 --limit 50 の silent 打ち切り回避）。
#   (i-notimeout) timeout 不在 → else 分岐で直に bd を呼び surface（sed/jq とは別の modality 被覆）。
#   (i-nojq)     jq 不在・python3 存在 → sed(cwd/metadata)+python3(emit) フォールバックで surface。
#   (ii)  該当 bead 無し（空配列）→ 無出力 exit0。
#   (iii) worker 文脈（cwd .worktrees/ / .claude/worktrees/ / SCRIBE_ROLE=worker）→ no-op。
#   (iv)  SCRIBE_ROLE=none（opt-out）→ no-op。
#   (v)   self_db==orch_db（発信側自身）→ skip。
#   (vi)  orch anchor 不在 / bd 不在 / read 失敗（bd rc!=0）/ JSON parse 不能（rc0 だが壊れ出力）/
#         自台帳 present-but-unreadable（.beads 有だが dolt_database 欠落）→ exit0 degrade（fail-safe 非vacuous）。
#   (vii) 実行経路が `bd repo sync`/`repo add`（hydrate）を一切呼ばない（stub の呼出記録で assert）。
#   (wire) hooks.json が mailbox-scan を role-inject/guard-health と同形 fail-safe（`[ -x ]`+`|| true`）で
#          SessionStart へ wire し、参照 script が repo に存在し実行可能であること。
#
# 実行: bats tests/session-start-mailbox-scan.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$REPO/scripts/hooks/session-start-mailbox-scan.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d -t scribe-mailbox-bats-XXXXXX)"

    # 台帳 fixture: self(dolt_database=sc) / orch(dolt_database=orch)。walk-up で解決される。
    SELF_LEDGER="$TEST_TMPDIR/proj-sc"
    ORCH_LEDGER="$TEST_TMPDIR/scriptorium"
    ORCH_SELF="$TEST_TMPDIR/proj-orch"       # 自台帳==orch（発信側）の fixture
    NOBEADS="$TEST_TMPDIR/proj-none"
    mkdir -p "$SELF_LEDGER/.beads" "$SELF_LEDGER/sub" \
             "$ORCH_LEDGER/.beads" "$ORCH_SELF/.beads" "$NOBEADS"
    printf '{"database":"dolt","dolt_database":"sc"}'   > "$SELF_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_SELF/.beads/metadata.json"
    SELF_CWD="$SELF_LEDGER/sub"

    # present-but-unreadable fixture: .beads/ は在るが metadata.json に dolt_database が無い（{}）
    #   → _mbx_resolve_self_db が識別不能で 1 を返し no-op（self 未特定ゆえ bd に到達しない）。
    UNREADABLE="$TEST_TMPDIR/proj-unreadable"
    mkdir -p "$UNREADABLE/.beads"
    printf '{}' > "$UNREADABLE/.beads/metadata.json"

    # worker cwd fixture（.worktrees/ と CC-native .claude/worktrees/・いずれも .beads 有=redirect 相当）。
    WT_DIR="$SELF_LEDGER/.worktrees/spawn/x-1"
    CC_WT_DIR="$SELF_LEDGER/.claude/worktrees/x-1"
    mkdir -p "$WT_DIR" "$CC_WT_DIR"

    # mock bd: PATH 前置。全呼出を BD_CALL_LOG に記録し、repo(hydrate)は異常終了。
    BD_CALL_LOG="$TEST_TMPDIR/bd-calls.log"
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"
    cat > "$BIN/bd" <<MOCKBD
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$BD_CALL_LOG"
for a in "\$@"; do
  case "\$a" in
    repo) echo "MOCK-BD-ERROR: repo(hydrate) が呼ばれた" >&2; exit 99 ;;
  esac
done
case "\${MOCK_BD_MODE:-ok}" in
  ok)      echo '[{"id":"orch-abc","priority":1,"title":"scribe 宛 coord テスト"},{"id":"orch-xyz","priority":2,"title":"knowledge relay テスト"}]'; exit 0 ;;
  empty)   echo '[]'; exit 0 ;;
  err)     echo "MOCK-BD-ERROR" >&2; exit 1 ;;
  badjson) echo 'not-json {{{ 壊れ出力'; exit 0 ;;   # rc0 だが JSON parse 不能 → _mbx_emit が 1 を返す想定
esac
MOCKBD
    chmod +x "$BIN/bd"

    # bd 不在 PATH: 必要な実ツールだけ symlink して bd を欠かす（command -v bd を失敗させる）。
    NOBD_BIN="$TEST_TMPDIR/nobd-bin"
    mkdir -p "$NOBD_BIN"
    for t in bash cat sed head dirname jq python3 timeout env printf grep; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOBD_BIN/$t"
    done

    # jq 不在・python3 存在 PATH: mock bd + 必要ツールを揃え **jq だけ欠かす**（_mbx_emit の
    # python3 フォールバック分岐を実データで通す＝gate finding「python3 heredoc-stdin 衝突で dead path」
    # の回帰固定）。jq を含めないので hook は python3 分岐へ落ちる。
    NOJQ_BIN="$TEST_TMPDIR/nojq-bin"
    mkdir -p "$NOJQ_BIN"
    ln -sf "$BIN/bd" "$NOJQ_BIN/bd"
    for t in bash cat sed head dirname python3 timeout env printf grep; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOJQ_BIN/$t"
    done

    # timeout 不在 PATH: mock bd + 必要ツール（jq 含む）を揃え **timeout だけ欠かす**（direct read の
    # `command -v timeout` else 分岐＝timeout 無しで直に bd を呼ぶ経路を実データで通す・sc-p2o minor #1）。
    NOTIMEOUT_BIN="$TEST_TMPDIR/notimeout-bin"
    mkdir -p "$NOTIMEOUT_BIN"
    ln -sf "$BIN/bd" "$NOTIMEOUT_BIN/bd"
    for t in bash cat sed head dirname jq python3 env printf grep; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOTIMEOUT_BIN/$t"
    done

    # dedupe/TTL state は repo 外（XDG state）に置かれる（lib mailbox-common.sh）。実 $HOME を汚さないよう
    # fixture 内へ隔離する（sc-b6w: SessionStart は surface した id を seen へ seed し、UserPromptSubmit
    # 中間配送点がそれを既報として再通知しない＝両配送点の共有 state）。
    STATE_DIR="$TEST_TMPDIR/state"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# hook を実フック経路（stdin JSON → stdout）で起動。PATH に mock bd を前置し orch anchor を fixture へ固定。
run_hook() { # $1=cwd  他=env 前置(KEY=VAL...)
    local cwd="$1"; shift
    printf '{"cwd":"%s","session_id":"sess-bats-1"}' "$cwd" \
        | env "$@" PATH="$BIN:$PATH" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              SCRIBE_MAILBOX_STATE_DIR="$STATE_DIR" bash "$HOOK"
}

@test "static: hook が実行可能・bash 構文 OK" {
    [ -x "$HOOK" ]
    run bash -n "$HOOK"
    [ "$status" -eq 0 ]
}

@test "(i) orch に for:sc open bead → surface 出力 + exit0" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$output" == *"下り mailbox"* ]]
    [[ "$output" == *"orch-abc"* ]]
    [[ "$output" == *"orch-xyz"* ]]
    [[ "$output" == *"scribe 宛 coord テスト"* ]]
    [[ "$output" == *"for:sc"* ]]          # self ラベルで scan した表記
    [[ "$output" == *"hydrate"* ]]         # hydrate 禁止の注意書き footer
    # direct read は正しい label/--status open/--limit 0(全件)/--readonly で呼ばれる
    [[ "$(cat "$BD_CALL_LOG")" == *"-C $ORCH_LEDGER list --label for:sc --status open --limit 0 --readonly --json"* ]]
}

@test "(i-limit) direct read は --limit 0(全件) を渡す（bd 既定 --limit 50 の silent 打ち切り回避・sc-p2o minor）" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$(cat "$BD_CALL_LOG")" == *"--limit 0"* ]]     # 50 件超の mailbox が黙って切られない
}

@test "(i-notimeout) timeout 不在 → else 分岐で直に bd を呼び surface + exit0(sc-p2o minor #1)" {
    # `command -v timeout` else 分岐（timeout を被せない直接 read）を実データで通す回帰固定。
    run bash -c "printf '{\"cwd\":\"%s\"}' '$SELF_CWD' | env MOCK_BD_MODE=ok PATH='$NOTIMEOUT_BIN' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]
    [[ "$output" == *"下り mailbox"* ]]
    [[ "$(cat "$BD_CALL_LOG")" == *" list "* ]]        # bd に到達し read した
}

@test "(i-nojq) jq 不在・python3 存在 → python3 フォールバックで surface + exit0" {
    # gate finding 回帰固定: _mbx_emit の python3 分岐が heredoc-stdin 衝突で dead path 化していないこと。
    # jq を欠いた PATH（python3 は在る）で MOCK_BD_MODE=ok → 実データで surface されねばならない。
    run bash -c "printf '{\"cwd\":\"%s\"}' '$SELF_CWD' | env MOCK_BD_MODE=ok PATH='$NOJQ_BIN' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"下り mailbox"* ]]
    [[ "$output" == *"orch-abc"* ]]
    [[ "$output" == *"orch-xyz"* ]]
    [[ "$output" == *"scribe 宛 coord テスト"* ]]
}

@test "(ii) 該当 bead 無し(空配列) → 無出力 exit0" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=empty
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(iii-a) worker: cwd .worktrees/ 配下 → no-op(無出力 exit0)" {
    run run_hook "$WT_DIR" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]                 # bd に到達せず skip
}

@test "(iii-b) worker: cwd .claude/worktrees/ 配下(CC-native) → no-op" {
    run run_hook "$CC_WT_DIR" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(iii-c) worker: SCRIBE_ROLE=worker → no-op(受信点は admin/consult)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_ROLE=worker
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(iv) SCRIBE_ROLE=none(opt-out) → no-op" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_ROLE=none
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(v) self_db==orch_db(発信側自身) → skip(無出力 exit0・read しない)" {
    # 自台帳の dolt_database が orch と一致 → orchestrator 自身ゆえ受信 scan 無意味。
    run bash -c "printf '{\"cwd\":\"%s\"}' '$ORCH_SELF' | env MOCK_BD_MODE=ok PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]                 # self==orch skip は bd read の手前
}

@test "(vi-a) orch anchor 不在 → exit0 degrade(無出力)" {
    run bash -c "printf '{\"cwd\":\"%s\"}' '$SELF_CWD' | env MOCK_BD_MODE=ok PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$TEST_TMPDIR/does-not-exist' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(vi-b) bd 不在 → exit0 degrade(無出力)" {
    # bd を欠いた PATH で実行。command -v bd 失敗 → read せず exit0。
    run bash -c "printf '{\"cwd\":\"%s\"}' '$SELF_CWD' | env -i MOCK_BD_MODE=ok PATH='$NOBD_BIN' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(vi-c) bd read 失敗(rc!=0) → exit0 degrade(無出力・fail-safe 非vacuous)" {
    # MOCK_BD_MODE=err で bd が rc1。fail-safe が本当に働くことを pin（surface しない）。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=err
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(vi-d) .beads 無し(scribe 管轄外) → no-op" {
    run run_hook "$NOBEADS" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(vi-e) bd が rc0 だが JSON parse 不能(壊れ出力) → 無出力 exit0(fail-safe 非vacuous・sc-p2o minor #3)" {
    # read 成功(rc0)でも中身が非配列/壊れ JSON なら _mbx_emit が 1 を返し surface しない（garbage を出さない）。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=badjson
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$BD_CALL_LOG" ]                    # bd には到達している(非vacuous=parse 段で落ちた)
}

@test "(vi-f) 自台帳 present-but-unreadable(.beads 有だが dolt_database 欠落) → no-op(bd 未到達・sc-p2o minor #3)" {
    # metadata.json が {}（dolt_database 無し）→ self 識別不能 → self 未特定ゆえ read せず exit0。
    run run_hook "$UNREADABLE" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]                  # self 未解決で bd read の手前に抜ける
}

@test "(vii) hydrate 禁止: 実行経路が bd repo sync/add を一切呼ばない(呼出記録で assert)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -f "$BD_CALL_LOG" ]                                   # bd には到達している(非vacuous)
    run cat "$BD_CALL_LOG"
    [[ "$output" != *"repo sync"* ]]
    [[ "$output" != *"repo add"* ]]
    [[ "$output" != *" repo "* ]]                           # いかなる repo サブコマンドも無い
    [[ "$output" == *" list "* ]]                           # 発行したのは read(list)のみ
}

@test "(viii-seed) surface した bead id を seen state へ seed する(UserPromptSubmit 中間配送点の dedupe 種・sc-b6w)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]                       # surface はした（非vacuous）
    seen="$STATE_DIR/sess-bats-1__sc.seen"
    [ -f "$seen" ]                                         # session 単位の seen state が作られ…
    grep -Fxq "orch-abc" "$seen"                           # …surface した id が全て記録される
    grep -Fxq "orch-xyz" "$seen"
    [ -f "$STATE_DIR/sess-bats-1__sc.scan" ]               # TTL stamp も置かれる（毎 prompt hook の間引き用）
}

@test "(viii-seed-degrade) state 書込不能でも surface は行う(配送 > 静粛・fail-safe)" {
    # state dir を作れない状況（親が既存ファイル＝mkdir -p が必ず失敗）でも SessionStart は必ず surface する。
    # run_hook は SCRIBE_MAILBOX_STATE_DIR を末尾で固定するため、ここは env を直に組んで上書きする。
    printf 'not-a-dir' > "$TEST_TMPDIR/blocked-state"
    run bash -c "printf '{\"cwd\":\"%s\",\"session_id\":\"sess-bats-1\"}' '$SELF_CWD' \
        | env MOCK_BD_MODE=ok PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' \
              SCRIBE_MAILBOX_STATE_DIR='$TEST_TMPDIR/blocked-state/x' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]
}

@test "(ix-prune) 下り便ゼロ(空配列)でも state prune と TTL stamp は走る(sc-b6w self-review [minor])" {
    # 旧実装は prune / stamp を「surface できたとき」だけ実行しており、下り便ゼロが常態の project では
    # ①XDG state が永久に伸び ②直後の UserPromptSubmit が同じ read を撃ち直した。両方を pin する。
    mkdir -p "$STATE_DIR"
    : > "$STATE_DIR/old__sc.seen"
    touch -d "30 days ago" "$STATE_DIR/old__sc.seen" 2>/dev/null || touch -t 202001010000 "$STATE_DIR/old__sc.seen"
    run run_hook "$SELF_CWD" MOCK_BD_MODE=empty
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                       # surface は無い（下り便ゼロ）
    [ ! -f "$STATE_DIR/old__sc.seen" ]                     # …が prune は走った（7 日超の state を掃除）
    [ -f "$STATE_DIR/sess-bats-1__sc.scan" ]               # …TTL stamp も前進（中間配送点が直後に再 read しない）
}

@test "(wire) hooks.json が mailbox-scan を role-inject と同形 fail-safe で SessionStart へ wire" {
    run python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                 # valid JSON でなければ die
ss = d.get("hooks", {}).get("SessionStart", [])
cmds = [h.get("command", "") for g in ss for h in g.get("hooks", [])]
mbx = [c for c in cmds if "session-start-mailbox-scan.sh" in c]
if not mbx:
    print("FAIL: SessionStart に mailbox-scan wire が無い"); sys.exit(1)
c = mbx[0]
if "|| true" not in c:
    print("FAIL: mailbox-scan wire が role-inject と同形 fail-safe(|| true)でない"); sys.exit(1)
if "[ -x" not in c:
    print("FAIL: mailbox-scan wire が `[ -x \"$SCRIPT\" ]` 存在ガードを欠く(role-inject と同形でない)"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: mailbox-scan wire は fail-safe([ -x ]+|| true)・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

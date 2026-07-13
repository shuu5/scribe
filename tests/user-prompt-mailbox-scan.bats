#!/usr/bin/env bats
# tests/user-prompt-mailbox-scan.bats
#
# UserPromptSubmit 中間配送点（scripts/hooks/user-prompt-mailbox-scan.sh・sc-b6w / orch-0yof ①・
# 裁定-delivery-guarantee②）の **e2e（stdin JSON → stdout surface の実フック契約）** と
# **hooks.json wire 検査** の hermetic bats。
#
# 役割: 毎 user prompt で軽量に orch 台帳を direct read し、**新着 `for:<self>` open bead だけ**を surface
#   する滞留保険（SessionStart 配送点は bundle 境界でしか発火せず、長寿命 admin session で下り便が滞留する
#   ＝for:sc 4 本が 2 日滞留した実 incident の恒久対策）。
#
# 方式（hermetic・実 plugin/DB 非依存）: session-start-mailbox-scan.bats と同型。
#   - 台帳 fixture（self=sc / orch=orch）+ PATH 前置の mock bd（全呼出を BD_CALL_LOG に記録・repo=hydrate は異常終了）。
#   - dedupe/TTL state は SCRIBE_MAILBOX_STATE_DIR で fixture 内へ隔離（実 $HOME を汚さない）。
#   - TTL は既定 300s ゆえ、dedupe 単体を見るテストでは SCRIBE_MAILBOX_TTL_SEC=0 で gate を無効化する
#     （TTL gate 自体は (t-*) で別に pin する＝2 つの間引き機構を独立に検証する）。
#
# 検証する契約不変条件:
#   (a)  admin + 新着あり → surface + exit0・direct read は label 完全一致 / --status open / --limit 0 / --readonly。
#   (b)  dedupe: 同一 session の 2 回目は既報を再通知しない（無出力 exit0）。
#   (b2) SessionStart 既報との dedupe: SessionStart が seed した id は UserPromptSubmit で再通知されない
#        （＝acceptance(1) の実証。両 hook が同じ state を共有する）。
#   (b3) 差分のみ: 新 bead が増えたら **新着だけ** surface（既報は出さない）。
#   (t-1) TTL gate: TTL 内の 2 回目は **bd を呼ばない**（呼出記録が増えない＝軽量性の機械 pin）。
#   (t-2) TTL gate: 空配列でも scan stamp は前進する（新着ゼロでも次 prompt で再 read しない）。
#   (t-3) TTL gate の **期限切れ側**: TTL 経過後は再 scan し、**新着のみ** surface（滞留保険の本体。
#         この分岐が壊れると session 内で初回以降 永久に沈黙する＝2 日滞留 incident の再来）。
#   (t-4) TTL gate の **失敗経路**: bd rc!=0 でも scan stamp は焼かれ、TTL 内の再 prompt は bd を呼び直さない
#         （backoff。stamp を read 成功後にだけ焼くと bd degrade 中に毎 prompt が timeout 5s を再支払いする）。
#   (r-*) role: worker（cwd .worktrees / .claude/worktrees / SCRIBE_ROLE=worker）・consult・none → no-op（bd 未到達）。
#   (s)   session_id 不在 → no-op（dedupe/TTL 不能なら配送より静粛＝spam と 0.8s/prompt の二重事故回避）。
#   (f-*) fail-safe: orch anchor 不在 / bd 不在 / bd rc!=0 / 壊れ JSON / .beads 無し / self 未解決 / self==orch
#         → 無出力 exit0 degrade（UserPromptSubmit の非 0 は **user prompt 自体を block する**ため決して非 0 で終わらない）。
#   (h)   hydrate 禁止: 実行経路が `bd repo sync`/`repo add` を一切呼ばない。
#   (wire) hooks.json が UserPromptSubmit へ fail-safe（`[ -x ]`+`|| true`）で wire し script が実行可能。
#
# 実行: bats tests/user-prompt-mailbox-scan.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    HOOK="$REPO/scripts/hooks/user-prompt-mailbox-scan.sh"
    SS_HOOK="$REPO/scripts/hooks/session-start-mailbox-scan.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    TEST_TMPDIR="$(mktemp -d -t scribe-upmbx-bats-XXXXXX)"

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

    UNREADABLE="$TEST_TMPDIR/proj-unreadable"
    mkdir -p "$UNREADABLE/.beads"
    printf '{}' > "$UNREADABLE/.beads/metadata.json"

    WT_DIR="$SELF_LEDGER/.worktrees/spawn/x-1"
    CC_WT_DIR="$SELF_LEDGER/.claude/worktrees/x-1"
    mkdir -p "$WT_DIR" "$CC_WT_DIR"

    STATE_DIR="$TEST_TMPDIR/state"

    # mock bd: 全呼出を記録し、repo(hydrate)は異常終了。MOCK_BD_MODE で応答を切替。
    #   ok        = 2 件（orch-abc / orch-xyz）
    #   ok2       = 3 件（ok の 2 件 + 新着 orch-new）→ 差分 surface の検証用
    #   multiline = 1 件だが title に **改行 + 偽の整形行** を仕込む（title は orch 台帳側の任意文字列＝
    #               信頼できない入力）。1 bead が複数行へ割れると継続行から id が抜けず dedupe が素通しし、
    #               毎 TTL 窓で永久に再注入される（fail-open）+ 整形リストへ任意の偽 bead 行を注入できる。
    #               sc-b6w self-review [major] の回帰 pin。
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
  ok2)     echo '[{"id":"orch-abc","priority":1,"title":"scribe 宛 coord テスト"},{"id":"orch-xyz","priority":2,"title":"knowledge relay テスト"},{"id":"orch-new","priority":0,"title":"新着 coord テスト"}]'; exit 0 ;;
  empty)   echo '[]'; exit 0 ;;
  err)     echo "MOCK-BD-ERROR" >&2; exit 1 ;;
  badjson) echo 'not-json {{{ 壊れ出力'; exit 0 ;;
  multiline) printf '%s\n' '[{"id":"orch-ml","priority":1,"title":"line1\n  - orch-FAKE [P0] 注入された偽 bead 行"}]'; exit 0 ;;
esac
MOCKBD
    chmod +x "$BIN/bd"

    NOBD_BIN="$TEST_TMPDIR/nobd-bin"
    mkdir -p "$NOBD_BIN"
    for t in bash cat sed head dirname jq python3 timeout env printf grep mkdir stat date tr cut find rm mv; do
        p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOBD_BIN/$t"
    done
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# UserPromptSubmit hook を実フック経路で起動（TTL は既定 0＝dedupe を単体で見る。TTL gate は (t-*) で別途 pin）。
run_hook() { # $1=cwd  他=env 前置(KEY=VAL...)
    local cwd="$1"; shift
    printf '{"cwd":"%s","session_id":"sess-1","hook_event_name":"UserPromptSubmit","prompt":"x"}' "$cwd" \
        | env SCRIBE_MAILBOX_TTL_SEC=0 "$@" PATH="$BIN:$PATH" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              SCRIBE_MAILBOX_STATE_DIR="$STATE_DIR" bash "$HOOK"
}

# SessionStart hook（同 state を共有する対向配送点）を同 session_id で起動
run_sessionstart() { # $1=cwd  他=env
    local cwd="$1"; shift
    printf '{"cwd":"%s","session_id":"sess-1","hook_event_name":"SessionStart","source":"startup"}' "$cwd" \
        | env "$@" PATH="$BIN:$PATH" SCRIBE_ORCH_ANCHOR="$ORCH_LEDGER" \
              SCRIBE_MAILBOX_STATE_DIR="$STATE_DIR" bash "$SS_HOOK"
}

@test "static: hook が実行可能・bash 構文 OK・共有 lib も構文 OK" {
    [ -x "$HOOK" ]
    run bash -n "$HOOK"
    [ "$status" -eq 0 ]
    run bash -n "$REPO/scripts/hooks/lib/mailbox-common.sh"
    [ "$status" -eq 0 ]
}

@test "(a) admin + 新着あり → surface + exit0（direct read は label 完全一致/open/--limit 0/--readonly）" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$output" == *"下り mailbox 新着"* ]]
    [[ "$output" == *"orch-abc"* ]]
    [[ "$output" == *"orch-xyz"* ]]
    [[ "$output" == *"scribe 宛 coord テスト"* ]]
    [[ "$output" == *"park-by-default"* ]]          # triage 導線（protocol §8 受信優先順位）
    [[ "$(cat "$BD_CALL_LOG")" == *"-C $ORCH_LEDGER list --label for:sc --status open --limit 0 --readonly --json"* ]]
}

@test "(b) dedupe: 同一 session の 2 回目は既報を再通知しない(無出力 exit0)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]                 # 1 回目は surface（非vacuous）
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok        # 2 回目（TTL=0 ゆえ bd は再び呼ばれる）
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                # 既報のみ → 無出力
}

@test "(b2) SessionStart 既報は UserPromptSubmit で再通知されない(両配送点の state 共有・acceptance(1))" {
    run run_sessionstart "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]                 # SessionStart が surface 済み
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                # 中間配送点は既報を再通知しない
}

@test "(b3) 差分のみ surface: 新 bead が増えたら新着だけ出す(既報は出さない)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok2       # orch-new が追加された
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-new"* ]]                 # 新着は出る
    [[ "$output" == *"新着 coord テスト"* ]]
    [[ "$output" != *"orch-abc"* ]]                 # 既報は出ない
    [[ "$output" != *"orch-xyz"* ]]
}

@test "(b4) 改行入り title でも dedupe は破れない(2 回目は無出力・fail-open 回帰 pin・sc-b6w self-review [major])" {
    # title は orch 台帳側の任意文字列＝信頼できない入力。改行が入ると 1 bead が複数行へ割れ、継続行から
    # id が抜けないため mbx_filter_unseen が素通し → 毎 TTL 窓で永久に再注入される（fail-open）。
    # mbx_emit が CR/LF を潰して「1 bead = 1 行」を構造保証することで塞ぐ。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=multiline
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-ml"* ]]                  # 1 回目は surface（非vacuous）
    [ "$(printf '%s\n' "$output" | grep -c '^  - ')" -eq 1 ]   # ★1 bead = 1 行（継続行へ割れない）
    run run_hook "$SELF_CWD" MOCK_BD_MODE=multiline # 2 回目
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                # ★既報は再通知されない（毎 TTL 窓の永久再注入が消える）
    run run_hook "$SELF_CWD" MOCK_BD_MODE=multiline # 3 回目（永続性: 何度回しても沈黙）
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    grep -Fxq "orch-ml" "$STATE_DIR/sess-1__sc.seen"            # seen に実 id が記録されている
}

@test "(b5) 改行入り title は整形リストへ偽 bead 行を注入できない(行フォーマット偽装の封鎖)" {
    # title 内に `  - orch-FAKE [P0] ...` を仕込んでも、独立した list 行として立ち上がってはならない
    #（surface は毎 turn の context へ注入されるため、任意行注入は下流の読み手を騙す面になる）。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=multiline
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-ml"* ]]                              # 非vacuous
    run bash -c "printf '%s\n' \"\$1\" | grep -c '^  - orch-FAKE' || true" _ "$output"
    [[ "$output" == "0" ]]                                      # ★偽の list 行は立たない（同一行へ畳まれる）
}

@test "(t-1) TTL gate: TTL 内の 2 回目は bd を呼ばない(毎 prompt の重い direct read を間引く・軽量性 pin)" {
    # 実測 0.74-0.89s/read ゆえ毎 prompt 同期実行は不可。TTL=300s（既定）で 2 回目は stat 1 回で即 exit0。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_MAILBOX_TTL_SEC=300
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]                 # 1 回目は read して surface
    before="$(wc -l < "$BD_CALL_LOG")"
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok2 SCRIBE_MAILBOX_TTL_SEC=300   # 新着があっても TTL 内なら
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                # surface しない（TTL 内 skip）
    after="$(wc -l < "$BD_CALL_LOG")"
    [ "$before" -eq "$after" ]                      # ★bd を一度も呼んでいない（軽量性の機械 pin）
}

@test "(t-2) TTL gate: 新着ゼロ(空配列)でも scan stamp は前進する(次 prompt で再 read しない)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=empty SCRIBE_MAILBOX_TTL_SEC=300
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$STATE_DIR/sess-1__sc.scan" ]             # 「見た」ことは記録される
    before="$(wc -l < "$BD_CALL_LOG")"
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_MAILBOX_TTL_SEC=300
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    after="$(wc -l < "$BD_CALL_LOG")"
    [ "$before" -eq "$after" ]                      # TTL 内ゆえ bd 未呼出
}

@test "(t-3) TTL 経過 → 再 scan して新着のみ surface(滞留保険の本体・期限切れ側の分岐を pin)" {
    # (t-1)(t-2) は TTL gate の **skip 側** だけを見ており、(a)(b)(b2)(b3) は TTL=0（gate 短絡）。
    # 期限切れ側（mbx_within_ttl の `[ $((now-last)) -lt $ttl ]` が false）が壊れると hook は session 内で
    # 初回以降 永久に沈黙する（＝2 日滞留 incident の再来）ため、ここで TTL=1 + sleep 2 で実際に跨がせる。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_MAILBOX_TTL_SEC=1
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-abc"* ]]                 # 1 回目 surface（非vacuous）
    before="$(wc -l < "$BD_CALL_LOG")"
    sleep 2                                          # TTL(1s) を跨ぐ（mtime は秒解像度）
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok2 SCRIBE_MAILBOX_TTL_SEC=1
    [ "$status" -eq 0 ]
    after="$(wc -l < "$BD_CALL_LOG")"
    [ "$after" -gt "$before" ]                      # ★TTL 経過 → 再 read した（gate の期限切れ側）
    [[ "$output" == *"orch-new"* ]]                 # 新着だけ surface
    [[ "$output" != *"orch-abc"* ]]                 # 既報は再通知しない（dedupe と合成）
    [[ "$output" != *"orch-xyz"* ]]
}

@test "(t-4) 失敗経路も間引く: bd rc!=0 の直後の prompt は bd を呼び直さない(backoff・軽量性 fail-open 封鎖)" {
    # ★load-bearing（self-review [major]）: TTL stamp を **read 成功後にだけ** 焼くと、bd が degrade した間
    # （dolt lock 競合・DB busy・hang）は gate が永久に開き、毎 user prompt が `timeout 5` を再支払いする
    # ＝最も重い失敗モードでだけ間引きが無効化される。stamp は「scan を試みた」時点で焼く（rc 非依存）。
    run run_hook "$SELF_CWD" MOCK_BD_MODE=err SCRIBE_MAILBOX_TTL_SEC=300
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                # degrade（無出力 exit0）は維持
    [ -f "$BD_CALL_LOG" ]                           # 1 回目は bd に到達（非vacuous）
    [ -f "$STATE_DIR/sess-1__sc.scan" ]             # ★失敗でも scan stamp が焼かれる
    before="$(wc -l < "$BD_CALL_LOG")"
    run run_hook "$SELF_CWD" MOCK_BD_MODE=err SCRIBE_MAILBOX_TTL_SEC=300
    [ "$status" -eq 0 ]
    after="$(wc -l < "$BD_CALL_LOG")"
    [ "$before" -eq "$after" ]                      # ★TTL 内の再 prompt は bd を呼ばない（backoff 成立）
}

@test "(r-a) worker: cwd .worktrees/ 配下 → no-op(bd 未到達)" {
    run run_hook "$WT_DIR" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(r-b) worker: cwd .claude/worktrees/ 配下(CC-native) → no-op" {
    run run_hook "$CC_WT_DIR" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(r-c) worker: SCRIBE_ROLE=worker → no-op" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_ROLE=worker
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(r-d) consult: SCRIBE_ROLE=consult → no-op(毎 prompt 配送点は admin 専用・orch-0yof ①)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_ROLE=consult
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(r-e) SCRIBE_ROLE=none(opt-out) → no-op" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok SCRIBE_ROLE=none
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(s) session_id 不在 → no-op(dedupe/TTL 不能なら静粛・spam と 0.8s/prompt の二重事故回避)" {
    run bash -c "printf '{\"cwd\":\"%s\"}' '$SELF_CWD' \
        | env MOCK_BD_MODE=ok SCRIBE_MAILBOX_TTL_SEC=0 PATH='$BIN:$PATH' \
              SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]                         # bd に到達しない（重い read を撃たない）
}

@test "(f-a) orch anchor 不在 → 無出力 exit0 degrade" {
    run bash -c "printf '{\"cwd\":\"%s\",\"session_id\":\"sess-1\"}' '$SELF_CWD' \
        | env MOCK_BD_MODE=ok SCRIBE_MAILBOX_TTL_SEC=0 PATH='$BIN:$PATH' \
              SCRIBE_ORCH_ANCHOR='$TEST_TMPDIR/no-such-anchor' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f-b) bd 不在 → 無出力 exit0 degrade" {
    run bash -c "printf '{\"cwd\":\"%s\",\"session_id\":\"sess-1\"}' '$SELF_CWD' \
        | env -i SCRIBE_MAILBOX_TTL_SEC=0 HOME='$TEST_TMPDIR' PATH='$NOBD_BIN' \
              SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR' bash '$HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f-c) bd read 失敗(rc!=0) → 無出力 exit0 degrade(fail-safe 非vacuous)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=err
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -f "$BD_CALL_LOG" ]                           # bd には到達している
}

@test "(f-d) bd が rc0 だが JSON parse 不能 → 無出力 exit0 degrade" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=badjson
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "(f-e) .beads 無し(scribe 管轄外) → no-op" {
    run run_hook "$NOBEADS" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(f-f) 自台帳 present-but-unreadable(dolt_database 欠落) → no-op(bd 未到達)" {
    run run_hook "$UNREADABLE" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(f-g) self_db==orch_db(発信側自身) → skip(無出力 exit0・read しない)" {
    run run_hook "$ORCH_SELF" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ ! -f "$BD_CALL_LOG" ]
}

@test "(h) hydrate 禁止: 実行経路が bd repo sync/add を一切呼ばない(呼出記録で assert)" {
    run run_hook "$SELF_CWD" MOCK_BD_MODE=ok
    [ "$status" -eq 0 ]
    [ -f "$BD_CALL_LOG" ]                           # bd には到達している(非vacuous)
    run cat "$BD_CALL_LOG"
    [[ "$output" != *"repo sync"* ]]
    [[ "$output" != *"repo add"* ]]
    [[ "$output" != *" repo "* ]]
    [[ "$output" == *" list "* ]]                   # 発行したのは read(list)のみ
}

@test "(wire) hooks.json が UserPromptSubmit へ fail-safe([ -x ]+|| true)で wire・script は実行可能" {
    run python3 - "$HOOKS_JSON" "$HOOK" <<'PY'
import json, os, sys
hooks_json, hook_path = sys.argv[1], sys.argv[2]
d = json.load(open(hooks_json))                 # valid JSON でなければ die
ups = d.get("hooks", {}).get("UserPromptSubmit", [])
cmds = [h.get("command", "") for g in ups for h in g.get("hooks", [])]
mbx = [c for c in cmds if "user-prompt-mailbox-scan.sh" in c]
if not mbx:
    print("FAIL: UserPromptSubmit に mailbox-scan wire が無い"); sys.exit(1)
c = mbx[0]
if "|| true" not in c:
    print("FAIL: wire が非ブロック fail-safe(|| true)でない — UserPromptSubmit の非0は prompt を block する"); sys.exit(1)
if "[ -x" not in c:
    print("FAIL: wire が `[ -x \"$SCRIPT\" ]` 存在ガードを欠く"); sys.exit(1)
if not (os.path.isfile(hook_path) and os.access(hook_path, os.X_OK)):
    print("FAIL: hook script が存在しない/実行不可:", hook_path); sys.exit(1)
print("OK: UserPromptSubmit wire は fail-safe・script は実行可能")
PY
    [ "$status" -eq 0 ]
    [[ "$output" == *"OK:"* ]]
}

@test "(dry) 発見ロジックは共有 lib に単一実装(二重実装しない・orch-0yof ①)" {
    # 両配送点が lib を source し、direct read / walk-up を各自に再実装していないこと。
    run grep -q 'lib/mailbox-common.sh' "$HOOK"
    [ "$status" -eq 0 ]
    run grep -q 'lib/mailbox-common.sh' "$SS_HOOK"
    [ "$status" -eq 0 ]
    # direct read の実発行（`list --label ... --limit 0 --readonly`）は **lib にしか無い**
    #（hook 側に再実装があれば二重実装＝ドリフト源）。hook は mbx_direct_read を呼ぶだけ。
    run grep -q 'list --label' "$REPO/scripts/hooks/lib/mailbox-common.sh"
    [ "$status" -eq 0 ]
    run grep -q 'list --label' "$HOOK"
    [ "$status" -ne 0 ]
    run grep -q 'list --label' "$SS_HOOK"
    [ "$status" -ne 0 ]
    run grep -q 'mbx_direct_read' "$HOOK"
    [ "$status" -eq 0 ]
    run grep -q 'mbx_direct_read' "$SS_HOOK"
    [ "$status" -eq 0 ]
}

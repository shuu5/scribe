#!/usr/bin/env bats
# tests/scenarios/orch-relay.bats
#
# orch-relay.sh（orch-z7g H2 push relay primitive・orch-ce6）の決定的テスト。
#
# 方式: cld-spawn を env ORCH_RELAY_CLD でスタブへ差替（実 inject しない・argv を生で記録）、実 script を実行して
#   assert する hermetic E2E（$HOME 非依存・実 tmux window を触らない）。
#   - stub は argv を $CLD_ARGS_FILE に `ARG\t<val>` 行で記録し、最後の positional（= --inject-existing の PROMPT）を
#     $CLD_MSG_FILE へ生バイトで書く＝locale 非依存に envelope 内容を grep できる。BADRC=1 で非0 終了（失敗伝播 test）。
#
# 検証する契約不変条件（orch-z7g H2 / orch-ce6）:
#   - cld-spawn --inject-existing <window> -- <message> を組む（送達は cld-spawn へ委譲・新規発明しない）。
#   - 既定は [ORCH-RELAY] sentinel envelope で message を包む（受け手が push relay と認識・--raw で verbatim）。
#   - window / message 必須（fail-loud）。dry-run は cld-spawn を呼ばない（副作用ゼロ）。
#   - cld-spawn 失敗（read-back 未確認）の非0 を伝播する（偽 relay 成功を出さない）。
#
# 実行: bats tests/scenarios/orch-relay.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-relay.sh"
    TEST_TMPDIR=$(mktemp -d -t orch-relay-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    export CLD_ARGS_FILE="$TEST_TMPDIR/cld-args.txt"
    export CLD_MSG_FILE="$TEST_TMPDIR/cld-msg.txt"
    : > "$CLD_ARGS_FILE"; : > "$CLD_MSG_FILE"

    # ── stub: cld-spawn（argv 記録・最後の positional=message を生で記録）。BADRC=1 で非0 終了。──
    cat > "$BIN/cld-spawn-stub" <<'STUB'
#!/usr/bin/env bash
: > "$CLD_ARGS_FILE"
for a in "$@"; do printf 'ARG\t%s\n' "$a" >> "$CLD_ARGS_FILE"; done
printf '%s' "${!#}" > "$CLD_MSG_FILE"   # 最後の positional = message（改行含む生バイト）
[ -n "${BADRC:-}" ] && exit 7
echo "injected → ${*}"
exit 0
STUB
    chmod +x "$BIN/cld-spawn-stub"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

run_relay() {
    ORCH_RELAY_CLD="$BIN/cld-spawn-stub" \
    CLD_ARGS_FILE="$CLD_ARGS_FILE" \
    CLD_MSG_FILE="$CLD_MSG_FILE" \
        run bash "$SCRIPT" "$@"
}

# ==============================================================================
# cld-spawn --inject-existing の再利用（送達委譲）
# ==============================================================================

@test "relay（既定）: cld-spawn --inject-existing <window> -- <message> を組む" {
    run_relay admin-projalpha -- "merge を承認する"
    [ "$status" -eq 0 ]
    grep -q -- '--inject-existing' "$CLD_ARGS_FILE"
    grep -qF 'admin-projalpha' "$CLD_ARGS_FILE"
    grep -qF -- '--' "$CLD_ARGS_FILE"
}

@test "relay（既定 envelope）: message を [ORCH-RELAY] sentinel で包む（受け手が push relay と認識）" {
    run_relay admin-projalpha -- "merge を承認する（PR#42）"
    [ "$status" -eq 0 ]
    grep -q 'ORCH-RELAY' "$CLD_MSG_FILE"
    grep -q 'push relay' "$CLD_MSG_FILE"
    grep -q '再開せよ' "$CLD_MSG_FILE"
    grep -qF 'merge を承認する（PR#42）' "$CLD_MSG_FILE"   # 本文も含まれる
}

@test "relay（envelope 権威構造・orch-2vkx）: 承認済み/中継/承認記録は bead notes を焼き human 本人発 framing を出さない" {
    run_relay admin-projalpha -- "merge を承認する（PR#42）"
    [ "$status" -eq 0 ]
    grep -q '承認済み' "$CLD_MSG_FILE"                        # human 承認済み orchestrator 決定
    grep -q '中継' "$CLD_MSG_FILE"                             # 本人発でなく中継
    grep -qF '承認記録は bead notes' "$CLD_MSG_FILE"           # 承認 pointer 総称文（orch-2vkx (c) Option A）
    # 事故 framing（human 本人発の示唆）の回帰封鎖。実メッセージ出力に当てる＝非空虚（envelope 経路が生きている限り必ず評価される）。
    ! grep -qE 'human 決定|人間の決定|human が下した決定' "$CLD_MSG_FILE"
}

@test "relay（--raw）: envelope を付けず message を verbatim 注入する" {
    run_relay admin-projalpha --raw -- "go ahead verbatim"
    [ "$status" -eq 0 ]
    ! grep -q 'ORCH-RELAY' "$CLD_MSG_FILE"                 # sentinel なし
    [ "$(cat "$CLD_MSG_FILE")" = "go ahead verbatim" ]     # 完全一致（verbatim）
}

@test "relay（--window 形式）: 位置引数の代わりに --window で window を指定できる" {
    run_relay --window wt-orch-abc -- "決定を反映せよ"
    [ "$status" -eq 0 ]
    grep -qF 'wt-orch-abc' "$CLD_ARGS_FILE"
}

@test "relay（複数語 message）: '--' 以降の複数トークンが 1 message に連結される" {
    run_relay admin-projalpha --raw -- one two three
    [ "$status" -eq 0 ]
    [ "$(cat "$CLD_MSG_FILE")" = "one two three" ]
}

@test "relay（session:window 正準形・topology orch-riz1）: 宛先 '<project>:admin' を verbatim で cld-spawn へ forward する（window 解決コードを足さない）" {
    # orch-thgx topology: admin 宛先正準形は session:window の `<project>:admin`。orch-relay は $WINDOW を verbatim
    # passthrough し曖昧解決/fail-loud は cld-spawn に委譲する（本 script は window 解決コードを持たない）。
    run_relay projalpha:admin -- "merge を承認する"
    [ "$status" -eq 0 ]
    grep -q -- '--inject-existing' "$CLD_ARGS_FILE"
    # session:window を byte 変えず（rewrite せず）そのまま forward する＝正準形の透過。
    grep -qxF $'ARG\tprojalpha:admin' "$CLD_ARGS_FILE"
    # 素 admin / admin-<project> へ書き換える window 解決コードが混入していないこと（透過の非vacuity）。
    ! grep -qxF $'ARG\tadmin' "$CLD_ARGS_FILE"
    ! grep -qxF $'ARG\tadmin-projalpha' "$CLD_ARGS_FILE"
}

# ==============================================================================
# 入力検証（fail-loud）
# ==============================================================================

@test "relay: window 無しは die" {
    run_relay -- "msg only"
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_ARGS_FILE" ]                              # cld-spawn を呼ばない
}

@test "relay: message 無しは die（注入内容が空）" {
    run_relay admin-projalpha
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_ARGS_FILE" ]
}

@test "relay: 空 body（-- \"\"）は die（内容なし envelope の exit0 注入を塞ぐ・orch-ce6 errata 4b）" {
    run_relay admin-projalpha -- ""
    [ "$status" -ne 0 ]
    [[ "$output" == *"空/空白のみ"* ]]
    [ ! -s "$CLD_ARGS_FILE" ]                              # cld-spawn を呼ばない
}

@test "relay: 空白のみ body（-- \"   \"）は die（envelope/--raw の非対称を対称 fail-closed 化・orch-ce6 errata 4b）" {
    run_relay admin-projalpha -- "   "
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_ARGS_FILE" ]
}

@test "relay: 余分な位置引数は die（window は 1 つ・message は -- 以降）" {
    run_relay admin-projalpha extra -- "msg"
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_ARGS_FILE" ]
}

@test "relay: 未知オプションは die" {
    run_relay --bogus admin-projalpha -- "msg"
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_ARGS_FILE" ]
}

# ==============================================================================
# dry-run（副作用ゼロ）・失敗伝播
# ==============================================================================

@test "relay（dry-run）: cld-spawn を呼ばず実行予定コマンドを print する" {
    run_relay admin-projalpha --dry-run -- "merge を承認する"
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN"* ]]
    [[ "$output" == *"--inject-existing"* ]]
    [ ! -s "$CLD_ARGS_FILE" ]                              # cld-spawn stub は呼ばれない
    [ ! -s "$CLD_MSG_FILE" ]
}

@test "relay（失敗伝播）: cld-spawn が非0（read-back 未確認）なら relay も非0 を返す（偽成功を出さない）" {
    BADRC=1 run_relay admin-projalpha -- "msg"
    [ "$status" -ne 0 ]
    [ "$status" -eq 7 ]                                    # exec ゆえ cld-spawn の exit code をそのまま伝播
}

@test "relay: cld-spawn 実体が実行不可なら die（fail-loud）" {
    ORCH_RELAY_CLD="$TEST_TMPDIR/nonexistent-cld" run bash "$SCRIPT" admin-projalpha -- "msg"
    [ "$status" -ne 0 ]
    [[ "$output" == *"cld-spawn"* ]]
}

@test "relay: --help は exit 0 で usage を出す" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-relay"* ]]
    [[ "$output" == *"--inject-existing"* ]]
}

@test "bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "orch-relay.sh 自体に事故 framing drift が 0 件（M4 型 mutation の恒久防御・orch-2vkx errata）" {
    # 恒久 source-level assert。envelope teeth（CLD_MSG_FILE grep）は runtime envelope 行(:131)しか被覆せず、
    # header comment(:5/:6/:25/:38) への drift 再導入（gate errata M4＝human が下した決定 の再注入で bats 17/17 GREEN
    # のまま素通り・実測）を取りこぼす。gate 時のみ走る bead 検証行 file grep に依存せず、同一パターンを script file
    # 自体へ当てて merge 後の将来 refactor に対する恒久防御を bats へ内在化する（M4 型 mutation を bats 単独で RED 化）。
    # grep -c は 0 一致で exit 1（＝drift 無し＝望ましい状態）を返すため `|| true` で count 取得の exit を吸収する。
    # drift 再導入時は count>0 かつ grep exit 0 で n が正数となり `[ "$n" -eq 0 ]` が RED になる（M4 を捕捉）。
    local n
    n=$(grep -cE 'human 決定|人間の決定|human が下した決定' "$SCRIPT" || true)
    [ "$n" -eq 0 ]
}

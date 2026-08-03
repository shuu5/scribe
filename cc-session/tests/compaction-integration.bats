#!/usr/bin/env bats
# compaction-integration.bats — pre→post→session-start のフック連鎖統合テスト
# 単体テストでは捕捉できないフック間の状態受け渡し（命令の生存・フック順序非依存）を検証する。
# 既知 finding（SessionStart が PostCompact 前/後どちらで走っても矛盾ヒントを出さない）の回帰防止。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
HOOKS="$SCRIPT_DIR/hooks"

setup() {
    SANDBOX="$(mktemp -d)"
    export WORKING_MEMORY_DIR="$SANDBOX/.claude-session"
    # 派生変数は session-env.sh に解決させる（外部環境の汚染を排除）
    unset WORKING_MEMORY_FILE WORKING_MEMORY_CONSUMED_FILE COMPACTION_ENABLED_MARKER COMPACTION_LOG_FILE
    # ambient な実セッション id を排除し legacy 非 scoped パスで決定論化（session-scoped は
    # working-memory-session-scoped.bats が固定。これらは legacy 経路の回帰ガード）。
    unset CLAUDE_CODE_SESSION_ID WM_SESSION_ID WORKING_MEMORY_SESSION_ID
    WM_FILE="$WORKING_MEMORY_DIR/working-memory.md"
    CONSUMED="$WORKING_MEMORY_DIR/working-memory.consumed.md"
    MARKER="$WORKING_MEMORY_DIR/.compaction-enabled"
    mkdir -p "$WORKING_MEMORY_DIR"
    touch "$MARKER"
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    unset WORKING_MEMORY_DIR
}

@test "integration: pre→post→session-start でスキルの命令が生存し SessionStart が誤誘導を出さない" {
    # スキルが working を退避（命令を含む）
    printf '%s\n' "## 計画弧・次のステップ" "- step" "" "## この effort を貫く命令・制約" "- [confirm] CHAIN_DIRECTIVE" > "$WM_FILE"
    # PreCompact: 既存 working を尊重（上書きしない）
    run bash "$HOOKS/pre-compact.sh"
    [ "$status" -eq 0 ]
    grep -q "CHAIN_DIRECTIVE" "$WM_FILE"
    ! grep -q "auto_precompact" "$WM_FILE"
    # PostCompact: 内容を注入し consumed へ mv
    run bash "$HOOKS/post-compact.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CHAIN_DIRECTIVE"* ]]
    [ ! -f "$WM_FILE" ]
    [ -f "$CONSUMED" ]
    # SessionStart: consumed を見て carry-forward 案内のみ。誤誘導（退避された作業状態を Read せよ）は出さない
    run bash "$HOOKS/session-start-compact.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"carry-forward"* ]]
    [[ "$output" != *"退避された作業状態があります"* ]]
}

@test "integration: 2サイクル連鎖で命令が carry-forward され続ける（post→pre→post）" {
    # cycle1: 命令 ALPHA を退避 → consumed 化
    printf '%s\n' "## 計画弧・次のステップ" "- s1" "" "## この effort を貫く命令・制約" "- [auto] ALPHA" > "$WM_FILE"
    bash "$HOOKS/post-compact.sh" >/dev/null
    grep -q "ALPHA" "$CONSUMED"
    # cycle2: スキル未実行で PreCompact 安全網 → consumed の ALPHA を機械 carry-forward
    run bash "$HOOKS/pre-compact.sh"
    [ "$status" -eq 0 ]
    grep -q "ALPHA" "$WM_FILE"
    # 再び PostCompact で consumed 化、ALPHA 生存
    bash "$HOOKS/post-compact.sh" >/dev/null
    grep -q "ALPHA" "$CONSUMED"
}

@test "czero: emit_working_memory は consumed 不在で loud warn を出す（stdout は従来形のまま）" {
    local missing="$WORKING_MEMORY_DIR/nope.consumed.md"
    run bash -c "source '$SCRIPT_DIR/lib/working-memory.sh'; emit_working_memory 2026-01-01T00:00:00Z manual '$missing' 2>'$SANDBOX/err'"
    [ "$status" -eq 0 ]
    grep -qF 'carry-forward 供給 0 項目' "$SANDBOX/err"
    grep -qF "$missing" "$SANDBOX/err"
    grep -qF 'exists=no' "$SANDBOX/err"
    # 挙動変更は stderr のみ＝stdout は「consumed 引数なし」と byte 等価
    run bash -c "source '$SCRIPT_DIR/lib/working-memory.sh'; emit_working_memory 2026-01-01T00:00:00Z manual '$missing' 2>/dev/null"
    local with_arg="$output"
    run bash -c "source '$SCRIPT_DIR/lib/working-memory.sh'; emit_working_memory 2026-01-01T00:00:00Z manual 2>/dev/null"
    [ "$with_arg" = "$output" ]
}

@test "czero: 命令・制約節が空の consumed も 0 項目として warn する（exists=yes）" {
    printf '%s\n' "## 計画弧・次のステップ" "- s" "" "## この effort を貫く命令・制約" > "$CONSUMED"
    run bash -c "source '$SCRIPT_DIR/lib/working-memory.sh'; emit_working_memory 2026-01-01T00:00:00Z manual '$CONSUMED' 2>'$SANDBOX/err'"
    [ "$status" -eq 0 ]
    grep -qF 'carry-forward 供給 0 項目' "$SANDBOX/err"
    grep -qF 'exists=yes' "$SANDBOX/err"
}

@test "czero: 正常 carry（項目あり）では warn を出さない（negative）" {
    printf '%s\n' "## 計画弧・次のステップ" "- s" "" "## この effort を貫く命令・制約" "- [auto] CZERO_KEEP" > "$CONSUMED"
    run bash -c "source '$SCRIPT_DIR/lib/working-memory.sh'; emit_working_memory 2026-01-01T00:00:00Z manual '$CONSUMED' 2>'$SANDBOX/err'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CZERO_KEEP"* ]]
    [ ! -s "$SANDBOX/err" ]
}

@test "integration: SessionStart が PostCompact より先に走っても誤誘導を出さない（順序逆転）" {
    # working のみ存在（PostCompact 未走 = consumed なし）
    printf '%s\n' "## この effort を貫く命令・制約" "- [auto] PENDING" > "$WM_FILE"
    run bash "$HOOKS/session-start-compact.sh"
    [ "$status" -eq 0 ]
    # 断定的な「Read して復元せよ」ではなく条件付き案内
    [[ "$output" == *"まだ注入していなければ"* ]]
    [[ "$output" != *"未復元の作業状態が残っています"* ]]
    # その後 PostCompact が走れば正常に復元・consumed 化
    run bash "$HOOKS/post-compact.sh"
    [ "$status" -eq 0 ]
    [[ "$output" == *"PENDING"* ]]
    [ -f "$CONSUMED" ]
}

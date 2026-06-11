#!/usr/bin/env bats
# session-start-role-inject.bats — scribe v0-C2(bd un-ck2) role 別 SessionStart 注入の検証
#
# カバレッジ:
#   - 構文(bash -n)
#   - role 判定マトリクス: env SCRIBE_ROLE(admin/worker/consult) / cwd .worktrees(worker) /
#     既定(admin) / 優先順(env > cwd > 既定) / 未知 env の degrade
#   - role 別注入内容の必須キーワード存在(spec §2.1-2.3)
#   - fail-safe: doc 不在で exit 0 degrade(全 role)・stderr 警告・stdout 無注入
#   - cwd ソース: stdin JSON 優先 / 無ければ $PWD フォールバック
#   - hooks.json: valid JSON / script 参照 / 安全形の dynamic assertion(ガード支配)

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/hooks/session-start-role-inject.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"
    WT_JSON='{"cwd":"/home/u/proj/.worktrees/spawn/x-1"}'
    ANCHOR_JSON='{"cwd":"/home/u/proj"}'
    EMPTY_JSON='{}'
}

# inject <role|-> <plugin_root> <stdin_json>
#   role が "-" なら SCRIBE_ROLE を unset、それ以外は env で焼き込む。
inject() {
    local r="$1" root="$2" json="$3"
    if [ "$r" = "-" ]; then
        printf '%s' "$json" | env -u SCRIBE_ROLE CLAUDE_PLUGIN_ROOT="$root" "$SCRIPT"
    else
        printf '%s' "$json" | env SCRIBE_ROLE="$r" CLAUDE_PLUGIN_ROOT="$root" "$SCRIPT"
    fi
}

# ---- 構文 ----
@test "syntax: bash -n が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "script: 実行可能ビットが立っている" {
    [ -x "$SCRIPT" ]
}

# ---- role 判定マトリクス ----
@test "role: 既定(env 無し・cwd が非 worktree) → admin" {
    run --separate-stderr inject - "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"既定(anchor 無印)"* ]]
}

@test "role: cwd が .worktrees/ 配下(env 無し) → worker" {
    run --separate-stderr inject - "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"cwd .worktrees/"* ]]
}

@test "role: env SCRIBE_ROLE=consult → consult" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
    [[ "$output" == *"env SCRIBE_ROLE"* ]]
}

@test "role: env SCRIBE_ROLE=admin → admin" {
    run --separate-stderr inject admin "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
}

@test "role: env SCRIBE_ROLE=worker → worker" {
    run --separate-stderr inject worker "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

@test "優先順: env(consult) > cwd(.worktrees) — worktree cwd でも consult が勝つ" {
    run --separate-stderr inject consult "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
}

@test "優先順: cwd(.worktrees) > 既定 — env 無し worktree は worker(admin に落ちない)" {
    run --separate-stderr inject - "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

@test "degrade: 未知の SCRIBE_ROLE は無視され cwd 判定へ(worktree→worker)・stderr 警告" {
    run --separate-stderr inject bogus "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$stderr" == *"未知の SCRIBE_ROLE"* ]]
}

@test "degrade: 未知の SCRIBE_ROLE + 非 worktree → 既定 admin" {
    run --separate-stderr inject bogus "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
}

# ---- cwd ソース: stdin 無し → $PWD フォールバック ----
@test "cwd ソース: stdin JSON に cwd 無し → \$PWD フォールバック(worktree から実行→worker)" {
    # $PWD を worktree っぽいパスにして実行(cwd 抽出が空 → PWD フォールバック検証)
    local d="$BATS_TEST_TMPDIR/.worktrees/spawn/z-1"
    mkdir -p "$d"
    run --separate-stderr bash -c "cd '$d' && printf '%s' '$EMPTY_JSON' | env -u SCRIBE_ROLE CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

# ---- cwd 抽出: jq 不在環境で sed フォールバック分岐を強制(回帰ネット) ----
@test "cwd 抽出: jq 不在(restricted PATH)→ sed フォールバックで cwd 解決(worktree→worker)" {
    # jq を PATH から外し _scribe_extract_cwd の sed 分岐(else)を強制実行する。
    # script が sed 分岐でも cwd を正しく抽出し role=worker を出すことを assert(片系統の回帰検知)。
    local bindir="$BATS_TEST_TMPDIR/nojq-bin"
    mkdir -p "$bindir"
    local b
    for b in bash env dirname cat sed head awk; do
        ln -sf "$(command -v "$b")" "$bindir/$b"
    done
    # jq は意図的にリンクしない → script の `command -v jq` が失敗 → sed フォールバック
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE= CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$WT_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"cwd .worktrees/"* ]]
}

# ---- role 別注入内容の必須キーワード(spec §2.1-2.3) ----
@test "注入(admin): gate funnel / errata / dolt push 同期点 を含む" {
    run --separate-stderr inject admin "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate funnel"* ]]
    [[ "$output" == *"errata"* ]]
    [[ "$output" == *"dolt push 同期点"* ]]
}

@test "注入(worker): bd create/dep/dolt push 禁止 / bdw / notes 提案 を含む" {
    run --separate-stderr inject worker "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd create"* ]]
    [[ "$output" == *"bd dep"* ]]
    [[ "$output" == *"bd dolt push"* ]]
    [[ "$output" == *"bdw"* ]]
    [[ "$output" == *"notes で提案"* ]]
}

@test "注入(worker): protocol.md の §2/§3/§4 のみ(§1/§5/§6 は出さない)" {
    run --separate-stderr inject worker "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"## 2. worker prompt 規約"* ]]
    [[ "$output" == *"## 3. B/hybrid 役割境界"* ]]
    [[ "$output" == *"## 4. close → gate → errata 規約"* ]]
    [[ "$output" != *"## 1. spawn 規約"* ]]
    [[ "$output" != *"## 5. gate funnel 手順"* ]]
    [[ "$output" != *"## 6. 監視"* ]]
}

@test "注入(consult): read-only / 記憶系のみ / サマリ保存義務 / 暫定運用 を含む" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"read-only"* ]]
    [[ "$output" == *"記憶系のみ"* ]]
    [[ "$output" == *"サマリ保存義務"* ]]
    [[ "$output" == *"暫定運用"* ]]
}

@test "注入(consult): §2.3 のみ抽出(§2.1 admin / §2.2 worker 見出し本文は混入しない)" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"### 2.3 consult"* ]]
    [[ "$output" != *"### 2.1 admin"* ]]
    [[ "$output" != *"### 2.2 worker"* ]]
    [[ "$output" != *"## 3. C2"* ]]
}

# ---- fail-safe: doc 不在で exit 0 degrade ----
@test "fail-safe(admin): protocol.md 不在 → exit 0・stdout 無注入・stderr 警告" {
    run --separate-stderr inject - "$BATS_TEST_TMPDIR" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"protocol.md 不在"* ]]
}

@test "fail-safe(worker): protocol.md 不在 → exit 0・stdout 無注入・stderr 警告" {
    run --separate-stderr inject - "$BATS_TEST_TMPDIR" "$WT_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"protocol.md 不在"* ]]
}

@test "fail-safe(consult): role-context-spec.md 不在 → exit 0・stdout 無注入・stderr 警告" {
    run --separate-stderr inject consult "$BATS_TEST_TMPDIR" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"role-context-spec.md 不在"* ]]
}

# ---- hooks.json ----
@test "hooks.json: valid JSON" {
    run jq -e . "$HOOKS_JSON"
    [ "$status" -eq 0 ]
}

@test "hooks.json: SessionStart wire が inject script を参照する" {
    run jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"session-start-role-inject.sh"* ]]
    [[ "$output" == *"[ -x"* ]]
}

@test "hooks.json: 安全形 dynamic — script 不在(CLAUDE_PLUGIN_ROOT 異常)で exit 0・副作用ゼロ" {
    # spec §3 selftest 強化引き継ぎ: 見せかけガードの false-PASS を防ぐため、
    # 実コマンドを未存在 CLAUDE_PLUGIN_ROOT で実行し exit 0 + stdout/stderr 空をドライラン観測。
    local cmd
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")"
    run --separate-stderr env CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/nonexistent" bash -c "$cmd"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "hooks.json: wire が live script を起動する(end-to-end・admin 既定)" {
    local cmd
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")"
    run --separate-stderr env -u SCRIBE_ROLE CLAUDE_PLUGIN_ROOT="$REPO" bash -c "$cmd" <<< "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"gate funnel"* ]]
}

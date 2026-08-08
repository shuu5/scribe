#!/usr/bin/env bats
# session-state-input-waiting.bats - detect_state() input-waiting 判定テスト
# Issue #486: approval UI / AskUserQuestion パターンの input-waiting 検出
# tmux 依存なし（モックアプローチ）

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
SESSION_STATE_SCRIPT="$SCRIPT_DIR/session-state.sh"

setup() {
    TMPFILE="$(mktemp)"
}

teardown() {
    [[ -n "$TMPFILE" && -f "$TMPFILE" ]] && rm -f "$TMPFILE"
}

# ---------------------------------------------------------------------------
# ヘルパー: capture-pane 内容をモックして detect_state を実行
# ---------------------------------------------------------------------------
# tmux list-panes → claude プロセス模倣（has_claude=true パスを使用）
# tmux capture-pane → TMPFILE の内容を返す
run_detect_state_with_capture() {
    local capture_content="$1"
    printf '%s\n' "$capture_content" > "$TMPFILE"

    run bash <<EOF
tmux() {
    case "\$1" in
        list-panes)
            # pane_cmd=claude, pane_dead=0, pane_id=%0, pane_path=/home/test
            printf 'claude\t0\t%%0\t/home/test\n'
            ;;
        capture-pane)
            cat "$TMPFILE"
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux
source "$SESSION_STATE_SCRIPT"
detect_state 'test-session:0'
EOF
}

# ---------------------------------------------------------------------------
# Scenario: Claude Code 選択 UI (approval UI)
# Enter to select · ↑/↓ to navigate · Esc to cancel が末尾にある場合
# ---------------------------------------------------------------------------
@test "detect_state: Claude Code 選択 UI (Enter to select) → input-waiting" {
    run_detect_state_with_capture \
"❯ 1. 承認して実行
     Phase 1 を開始。3 Worker を並列起動し orchestrator に委譲
  2. キャンセル

Enter to select · ↑/↓ to navigate · Esc to cancel"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: approval UI の選択肢行 (❯) が tail-5 の中間にある → input-waiting" {
    run_detect_state_with_capture \
"❯ 1. 承認して実行
  2. キャンセル
Enter to select · ↑/↓ to navigate"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: 日本語 AskUserQuestion
# ---------------------------------------------------------------------------
@test "detect_state: 日本語 承認しますか prompt → input-waiting" {
    run_detect_state_with_capture \
"この操作を実行します。
承認しますか？ [y/N]"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: 日本語 確認しますか prompt → input-waiting" {
    run_detect_state_with_capture \
"変更を適用します。
確認しますか？"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: 英語 y/N / Do you want to
# ---------------------------------------------------------------------------
@test "detect_state: [y/N] prompt → input-waiting" {
    run_detect_state_with_capture \
"Do you want to proceed?
[y/N]"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: Do you want to prompt → input-waiting" {
    run_detect_state_with_capture \
"Do you want to apply these changes?"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: Waiting for user input → input-waiting" {
    run_detect_state_with_capture \
"Waiting for user input..."
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: 従来の ❯ 末尾パターン（既存挙動の維持）
# ---------------------------------------------------------------------------
@test "detect_state: 従来の ❯ 末尾プロンプト → input-waiting (後方互換)" {
    run_detect_state_with_capture \
"Completed previous task.
❯ "
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Scenario: processing 中（誤検知なし）
# ---------------------------------------------------------------------------
@test "detect_state: Thinking... のみ → processing (誤検知なし)" {
    run_detect_state_with_capture \
"Thinking...
⠋ Processing request"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: Working... のみ → processing" {
    run_detect_state_with_capture \
"Working on the task...
  Analyzing code"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: 空の出力 → processing" {
    run_detect_state_with_capture ""
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# ---------------------------------------------------------------------------
# Scenario: [Y/n] バリアント
# ---------------------------------------------------------------------------
@test "detect_state: [Y/n] prompt → input-waiting" {
    run_detect_state_with_capture \
"Install the package? [Y/n]"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Issue #708: "esc to interrupt" / "bypass permissions" の誤検知・検出テスト
# ---------------------------------------------------------------------------
@test "detect_state: esc to interrupt のみ表示 → processing (false positive 再現)" {
    run_detect_state_with_capture \
"esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: bypass permissions のみ表示 → input-waiting" {
    run_detect_state_with_capture \
"bypass permissions"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: esc to interrupt + Thinking 表示 → processing" {
    run_detect_state_with_capture \
"Thinking...
esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# ccs-pwr で expectation を反転: 旧テストは「bypass 優先 → input-waiting」を pin していたが、
# 'bypass permissions' は --dangerously-skip-permissions の**常時表示ステータスバー**であり
# ダイアログ識別子ではない（session-comm.sh の modality ガード注記で既に是正済みの誤解）。
# 'esc to interrupt' は turn 実行中にのみ表示される積極証拠のため、両方可視なら processing が正しい。
# 旧 expectation のままだと turn 走行中の bypass セッションを input-waiting と誤報し、
# read-back 偽陰性→再送重複（orch-8rn8 実測 2026-07-15）の一因になる。
@test "detect_state: bypass permissions + esc to interrupt 同時表示 → processing (ccs-pwr 是正: esc は turn 証拠・bypass は常時表示)" {
    run_detect_state_with_capture \
"bypass permissions · esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: ダイアログ (Do you want to) + esc to interrupt 同時 → input-waiting (ダイアログ優先は維持)" {
    run_detect_state_with_capture \
"Do you want to proceed?
esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# ---------------------------------------------------------------------------
# Issue #708 拡張: thinking 進行形が ❯ / bypass と共存しても processing
# Opus 4.7 は thinking 中に「動名詞インジケータ + ❯ 入力欄 + bypass ステータスバー」を
# 同時表示する。進行形インジケータは入力ボックスの上に出るため tail -8 で捕捉する。
# (実セッションの fork 検証で観測した false positive の回帰テスト)
# ---------------------------------------------------------------------------
@test "detect_state: thinking 進行形 (Incubating…) + ❯ + bypass 同時 → processing (#708 誤検出回帰)" {
    run_detect_state_with_capture \
"✶ Incubating… (6m 12s · ↓ 25.5k tokens · almost done thinking with max effort)
──────────────────────────────
❯
──────────────────────────────
  shuu5@host 10% 100k/1M Opus 4.7 [max]
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: completion 表示 (Baked for 8m) + ❯ → input-waiting (過去形は thinking 扱いしない)" {
    run_detect_state_with_capture \
"✻ Baked for 8m 25s
──────────────────────────────
❯
──────────────────────────────
  shuu5@host 0% 0/1M Opus 4.7 [max]
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: compaction 中 (Compacting) + ❯ → processing" {
    run_detect_state_with_capture \
"✽ Compacting conversation… (51s)
──────────────────────────────
❯
──────────────────────────────
  shuu5@host 0% 0/1M Opus 4.7 [max]
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# ---------------------------------------------------------------------------
# ccs-pwr: 現行 TUI (2026-07 系) の turn 走行中誤分類の根治
# 実測標本 (2026-07-15・orch-8rn8 偽陰性の機序): 現行 TUI は 'esc to interrupt' を
# 表示せず、スピナー行が Tip 行の折返し等で tail -8 の外へ押し出されると、
# ❯/bypass 判定が「turn 走行中なのに input-waiting」を返していた。
# ---------------------------------------------------------------------------
@test "detect_state: 現行 TUI スピナーが tail -8 の外（Tip 折返し）でも → processing (ccs-pwr 実測回帰)" {
    run_detect_state_with_capture \
"✽ Boondoggling… (6m 16s · ↓ 23.2k tokens)
  ⎿ · Tip: Use /btw to ask a quick side question without interrupting
     Claude's current work
──────────────────────────────
❯
──────────────────────────────
  shuu5@ipatho-server-2 (user@example.com)  cc-session  main*
  17% 170k/1M Fable 5 [xhigh] 5h:6%(3h18m) 7d:22%(1d6h)
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: 現行 TUI スピナー行のみ（esc to interrupt 不在）→ processing (TUI ドリフト追随)" {
    run_detect_state_with_capture \
"✢ Simmering… (8m 0s · ↓ 24.9k tokens)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# agent 一覧行はインデントされ（行頭 glyph アンカー不成立）タイマーも '(' に包まれない
# ＝スピナーと誤認しない（orchestrator pane の live 標本 2026-07-15 で検証した誤爆封鎖）
@test "detect_state: agent 一覧行（◯ name … Ns · ↓ tokens）はスピナー扱いしない → input-waiting" {
    run_detect_state_with_capture \
"  ● main
  ◯ claude-code-guide  Claude Code 予測機能の無…  1m 54s · ↓ 63.8k tokens
──────────────────────────────
❯
──────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# 過去形完了表示は現行 TUI 形式でも input-waiting のまま（タイマー '(' 無し・ellipsis 無し）
@test "detect_state: 現行 TUI 完了表示 (● Boondoggled for 8m) + 入力欄 → input-waiting" {
    run_detect_state_with_capture \
"● Boondoggled for 8m 25s
──────────────────────────────
❯
──────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

# 評価順是正の pin: ❯（trailing space 付き＝PROMPT_PATTERN 一致形）より esc が先に評価される
@test "detect_state: esc to interrupt + ❯（空入力欄）→ processing (評価順: turn 証拠 > ❯・ccs-pwr)" {
    run_detect_state_with_capture \
"──────────────────────────────
❯ 
──────────────────────────────
esc to interrupt"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# ===========================================================================
# sc-8bhc: 可視画面外（scrollback）に残ったスピナー残骸だけを根拠にした偽 processing
# ---------------------------------------------------------------------------
# 機序: 現行 TUI では終了済み turn のスピナー行が再描画後も可視画面の外（scrollback）に残存しうる。
# スピナー判定を capture 全域（-S -20）へ掛けていると、可視画面が入力欄でも「スピナー残骸だけを
# 根拠に processing」を返し続ける（= 入力待ちの窓へ何も届かない偽陽性）。修正は「1 回の -S -20
# capture の末尾 pane_height 行（= 可視 frame）だけをスピナー走査対象にする」。
#
# 実 tmux の意味論（下の arg-aware mock が再現する契約）:
#   capture-pane -S -20         → scrollback 20 行 + 可視 pane 全高（実測: 20 + pane_height 行）
#   capture-pane -S 0 / 引数なし → 可視 pane のみ（= -S -20 出力の末尾 pane_height 行と一致）
#
# 上の既存ヘルパー run_detect_state_with_capture の stub は capture-pane の引数を見ずに全文を返すため、
# 「可視画面の外にだけ存在する行」を表現できない＝走査範囲を変えても結果が 1 件も変わらない
# （false-green）。そこで -S の有無で返す内容が変わる arg-aware な mock を新設する。
# 既存 25 件の挙動を 1 byte も変えないため、既存ヘルパーには手を入れず本ヘルパーを併設している。
# ===========================================================================

# 実 pane の入力欄行は ❯ + U+00A0（bytes: E2 9D AF C2 A0）。ASCII space 形ではない。
SS_NBSP=$'\u00a0'
SS_PROMPT_LINE="❯${SS_NBSP}"

# arg-aware tmux stub（-S 有無で返す内容が変わる / list-panes は pane_height を 4 列目で返す）
_ss_write_arg_aware_tmux_stub() {
    cat > "$1" <<'STUB_EOF'
tmux() {
    case "${1:-}" in
        list-panes)
            local _h
            _h=$(wc -l < "$SS_MOCK_VISIBLE")
            # pane_cmd=claude, pane_dead=0, pane_id=%0, pane_height=<可視部の行数>, pane_path=/home/test
            printf 'claude\t0\t%%0\t%s\t/home/test\n' "$_h"
            ;;
        capture-pane)
            local _a _has_s=false
            for _a in "$@"; do
                [[ "$_a" == "-S" ]] && _has_s=true
            done
            if $_has_s; then
                cat "$SS_MOCK_SCROLLBACK" "$SS_MOCK_VISIBLE"
            else
                cat "$SS_MOCK_VISIBLE"
            fi
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux
STUB_EOF
}

# scrollback 部 / 可視 frame 部を分けて与えて detect_state を実行する
run_detect_state_with_frames() {
    export SS_MOCK_SCROLLBACK="$BATS_TEST_TMPDIR/ss-scrollback.txt"
    export SS_MOCK_VISIBLE="$BATS_TEST_TMPDIR/ss-visible.txt"
    local stub="$BATS_TEST_TMPDIR/ss-tmux-stub.sh"
    printf '%s\n' "$1" > "$SS_MOCK_SCROLLBACK"
    printf '%s\n' "$2" > "$SS_MOCK_VISIBLE"
    _ss_write_arg_aware_tmux_stub "$stub"
    run bash -c "source '$stub'; source '$SESSION_STATE_SCRIPT'; detect_state 'test-session:0'"
}

# detect_state の出力不変（rc=0 かつ 5 語のいずれか 1 語のみ）を検査する
_ss_assert_state_word() {
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ ^(idle|input-waiting|processing|error|exited)$ ]]
}

@test "arg-aware mock 自己 pin: capture-pane は -S の有無で返す内容が変わる（A4・sc-8bhc）" {
    export SS_MOCK_SCROLLBACK="$BATS_TEST_TMPDIR/ss-scrollback.txt"
    export SS_MOCK_VISIBLE="$BATS_TEST_TMPDIR/ss-visible.txt"
    local stub="$BATS_TEST_TMPDIR/ss-tmux-stub.sh"
    printf '%s\n' "SCROLLBACK-ONLY-MARKER" > "$SS_MOCK_SCROLLBACK"
    printf '%s\n' "VISIBLE-LINE-1
VISIBLE-LINE-2" > "$SS_MOCK_VISIBLE"
    _ss_write_arg_aware_tmux_stub "$stub"

    # -S あり = scrollback + 可視
    run bash -c "source '$stub'; tmux capture-pane -p -t x -S -20"
    [[ "$status" -eq 0 ]]
    grep -q 'SCROLLBACK-ONLY-MARKER' <<< "$output"
    grep -q 'VISIBLE-LINE-2' <<< "$output"

    # -S なし = 可視のみ（この差が出ないと本 bug は test で表現できない）
    run bash -c "source '$stub'; tmux capture-pane -p -t x"
    [[ "$status" -eq 0 ]]
    ! grep -q 'SCROLLBACK-ONLY-MARKER' <<< "$output"
    grep -q 'VISIBLE-LINE-2' <<< "$output"

    # list-panes の 4 列目 = pane_height（可視部の行数）
    run bash -c "source '$stub'; tmux list-panes -t x -F ignored"
    [[ "$status" -eq 0 ]]
    [[ "$(cut -f4 <<< "$output")" == "2" ]]
}

@test "fixture 自己検証: 入力欄行は ❯ + U+00A0（E2 9D AF C2 A0）で PROMPT_PATTERN は 0 hit（sc-8bhc）" {
    local hex
    hex=$(printf '%s' "$SS_PROMPT_LINE" | od -An -tx1 | tr -d ' \n')
    [[ "$hex" == "e29dafc2a0" ]]
    # 実 pane 形の入力欄には PROMPT_PATTERN が当たらない（当たると下の input-waiting の根拠が
    # ❯ 分岐か bypass 分岐か判別できなくなる＝false-green の芽）。この欠陥自体は本 bead の scope 外。
    run bash -c "source '$SESSION_STATE_SCRIPT'; printf '%s\n' \"\$1\" | grep -qP \"\$PROMPT_PATTERN\"" _ "$SS_PROMPT_LINE"
    [[ "$status" -ne 0 ]]
}

# --- 本 test の限界（false-green 封鎖のための明示・sc-8bhc）-------------------------------------
# 本 test の VISIBLE は非空 6 行（'●' 行 / 区切り線 2 本 / 入力欄 / メーター行 / bypass 行）で、
# acceptance A1 の字義（VISIBLE = ❯ + U+00A0 と bypass のみ）より広い。字義どおりの VISIBLE を
# 与えると本 test は input-waiting ではなく processing になる（実測）。理由はスピナー分岐より前に
# 評価される thinking 判定（capture 全域を空行除去して tail -8）で、scrollback の残骸行
# 『✽ Simmering… (3m 42s · ↓ 14.7k tokens)』は TURN_SPINNER_PATTERN だけでなく
# THINKING_PROGRESS_PATTERN にも一致するため（S+immer+ing+… が [\p{Lu}][\p{Ll}]+ing… に合致）。
# つまり「残骸だけを根拠にした偽 processing」には 2 経路あり、本 diff（スピナー走査の可視限定）が
# 塞いだのはスピナー経路のみ。thinking 経路は可視 frame の非空行が 8 行未満のとき再現する
# （余裕は 1 行: 上の VISIBLE を非空 5 行に減らすと scrollback + VISIBLE = 計 9 行となり、
# tail -8 が残骸行を拾って processing に戻る）。
# この第 2 経路（thinking 判定の走査範囲を可視 frame へ揃える件）は本 bead の scope 外であり、
# 実装側の当該行は禁触。よって本 test の green を「A1 を字義どおり達成した」根拠にしてはならない。
# ------------------------------------------------------------------------------------------------
# 適用範囲の注記: 本修正が塞ぐのは「スピナー走査（可視 frame 限定にした分岐）が残骸を拾う」経路のみ。
# thinking 進行形の走査は capture 全域の tail -8（非空行）を見る別分岐で、そちらは本 bead の scope 外
# （SSOT を共有する別判定のため意味論変更は独立レビューが要る）。したがって「残骸が可視 frame の
# 直上にあり、かつ可視 frame の非空行が 8 行未満」という frame では、進行形分岐が先に一致して
# processing のままになる。下の fixture は残骸が tail -8 窓の外に居る形（= 報告された残存形）。
@test "detect_state: スピナー残骸が scrollback だけに在り可視は入力欄 → input-waiting（A1 本丸・idle 不可・sc-8bhc）" {
    run_detect_state_with_frames \
"  ⎿  Read 120 lines (ctrl+o to expand)
✽ Simmering… (3m 42s · ↓ 14.7k tokens)
  ⎿ · Tip: Use /btw to ask a quick side question without interrupting
     Claude's current work" \
"● 直前の turn は完了している
──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  0% 0/1M Opus 5 [high]
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: 可視 frame 内のスピナーが tail -8 の外（Tip 折返し）でも → processing（A2・可視限定で偽陰性を作らない・sc-8bhc）" {
    run_detect_state_with_frames \
"  ⎿  Read 42 lines (ctrl+o to expand)
● 前の turn の出力" \
"✽ Boondoggling… (6m 16s · ↓ 23.2k tokens)
  ⎿ · Tip: Use /btw to ask a quick side question without interrupting
     Claude's current work
──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  cc-session  main*
  17% 170k/1M Opus 5 [high]
  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

# 以下 2 本は「スピナーが可視 frame に見えている間は processing のまま」という意味論の pin。
# 現行 TUI のスピナー語は gerund + … ゆえ thinking 進行形分岐にも一致する＝これらの fixture では
# 2 つの turn 証拠分岐が同時に成立する（どちらが先に返しても期待は processing）。スピナー分岐だけを
# 単独で殺しても RED になる teeth は、上の「tail -8 の外」fixture が担う（進行形分岐の窓の外に置いた
# 形＝スピナー分岐でしか processing になれない）。
@test "detect_state: 可視 frame のスピナー行のみ（scrollback に残骸なし）→ processing（A2・sc-8bhc）" {
    run_detect_state_with_frames \
"● 前の turn の出力" \
"✢ Simmering… (8m 0s · ↓ 24.9k tokens)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: 現 frame のスピナーが入力欄 ❯ の直上でも → processing（A3・スピナーが ❯ より上＝過去 frame ではない・sc-8bhc）" {
    run_detect_state_with_frames \
"  ⎿  Read 8 lines (ctrl+o to expand)" \
"✽ Boondoggling… (1m 12s · ↓ 3.4k tokens)
──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: pane_height が取れない mock では capture 全域へ倒す（fail-safe は processing 側・sc-8bhc）" {
    # 旧来の 4 列 list-panes（pane_height 欄なし）を模した stub。可視 frame を切り出せないため
    # 走査は capture 全域に戻る＝偽陽性（processing）側へ倒れる。偽陰性（走行中を入力待ちと誤報）は
    # 走行中セッションの kill 抑止を外す不可逆な誤りのため、不明時はこちら側が正しい。
    export SS_MOCK_SCROLLBACK="$BATS_TEST_TMPDIR/ss-scrollback.txt"
    export SS_MOCK_VISIBLE="$BATS_TEST_TMPDIR/ss-visible.txt"
    local stub="$BATS_TEST_TMPDIR/ss-legacy-stub.sh"
    printf '%s\n' "✽ Simmering… (3m 42s · ↓ 14.7k tokens)" > "$SS_MOCK_SCROLLBACK"
    printf '%s\n' "──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)" > "$SS_MOCK_VISIBLE"
    cat > "$stub" <<'LEGACY_EOF'
tmux() {
    case "${1:-}" in
        list-panes)
            # pane_height 欄を持たない旧形式（4 列）
            printf 'claude\t0\t%%0\t/home/test\n'
            ;;
        capture-pane)
            cat "$SS_MOCK_SCROLLBACK" "$SS_MOCK_VISIBLE"
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux
LEGACY_EOF
    run bash -c "source '$stub'; source '$SESSION_STATE_SCRIPT'; detect_state 'test-session:0'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: 空 capture でも rc=0 かつ 5 語のいずれか（A6・sc-8bhc）" {
    run_detect_state_with_frames "" ""
    _ss_assert_state_word
}

@test "detect_state: ❯ が 1 つも無い capture でも rc=0 かつ 5 語のいずれか（A6・sc-8bhc）" {
    run_detect_state_with_frames \
"  ⎿  Read 42 lines (ctrl+o to expand)" \
"  tool output line 1
  tool output line 2"
    _ss_assert_state_word
}

@test "detect_state: ❯ が多数ある capture でも rc=0 かつ 5 語のいずれか（A6・sc-8bhc）" {
    run_detect_state_with_frames \
"${SS_PROMPT_LINE}
${SS_PROMPT_LINE}
${SS_PROMPT_LINE}" \
"❯ 1. 承認して実行
❯ 2. キャンセル
──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)"
    _ss_assert_state_word
}

@test "detect_state: 巨大 capture（数千行）でも rc=0 かつ 5 語のいずれか（A6・sc-8bhc）" {
    local big="" i
    for ((i = 1; i <= 3000; i++)); do
        big+="  line ${i}: tool output"$'\n'
    done
    run_detect_state_with_frames "$big" "$big"
    _ss_assert_state_word
}

# ===========================================================================
# sc-8bhc(follow-up): 可視 frame の下端に空行が在る実 frame
# ---------------------------------------------------------------------------
# 機序: `captured=$(tmux capture-pane ...)` は command substitution ゆえ末尾の改行を全て剥ぐ。
# 実 pane の可視 frame は下端に空行を持つのが普通なので、剥ぎ取り後の capture は
# 「scrollback 20 行 + pane_height 行」より k 行（= 下端空行数）短くなる。この値へ
# `tail -n pane_height` を掛けると可視 frame の直上 k 行——すなわち直前に画面外へ流れた
# scrollback 行——まで巻き込む。TUI ではスピナー行は入力ボックスの直上に描かれる＝新出力で
# 最初に画面外へ押し出される行なので、その k 行はまさに残骸スピナーが居やすい位置になる。
# 結果、下端空行のある frame では「残骸 spinner だけを根拠に processing」が丸ごと再現する。
# 対策は capture 時に番兵を付けて下端空行を保持すること（session-state.sh の capture 部）。
#
# 上の arg-aware mock は pane_height を `wc -l < $SS_MOCK_VISIBLE` で返すため、この frame 形
# （pane_height が下端空行を含む値）を構造的に表現できない。よって pane_height を明示指定
# できる stub を併設する。既存 stub / helper は 1 byte も変更していない（追記のみ）。
# ===========================================================================

_ss_write_arg_aware_tmux_stub_ph() {
    cat > "$1" <<'STUB_EOF'
tmux() {
    case "${1:-}" in
        list-panes)
            printf 'claude\t0\t%%0\t%s\t/home/test\n' "$SS_MOCK_PANE_HEIGHT"
            ;;
        capture-pane)
            local _a _has_s=false
            for _a in "$@"; do
                [[ "$_a" == "-S" ]] && _has_s=true
            done
            if $_has_s; then
                cat "$SS_MOCK_SCROLLBACK" "$SS_MOCK_VISIBLE"
            else
                cat "$SS_MOCK_VISIBLE"
            fi
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux
STUB_EOF
}

# $1=scrollback 本文 / $2=可視 frame（末尾の空行まで含めた生バイト列） / $3=pane_height
run_detect_state_with_frames_ph() {
    export SS_MOCK_SCROLLBACK="$BATS_TEST_TMPDIR/ss-scrollback-ph.txt"
    export SS_MOCK_VISIBLE="$BATS_TEST_TMPDIR/ss-visible-ph.txt"
    export SS_MOCK_PANE_HEIGHT="$3"
    local stub="$BATS_TEST_TMPDIR/ss-tmux-stub-ph.sh"
    printf '%s\n' "$1" > "$SS_MOCK_SCROLLBACK"
    printf '%s' "$2" > "$SS_MOCK_VISIBLE"
    _ss_write_arg_aware_tmux_stub_ph "$stub"
    run bash -c "source '$stub'; source '$SESSION_STATE_SCRIPT'; detect_state 'test-session:0'"
}

# scrollback 末尾にスピナー残骸を置く（tail -8 の thinking 判定には届かない位置＝
# spinner 分岐だけを単独で検査するため、可視側に非空行を 9 行置いて押し出している）
SS_PH_SCROLLBACK="  ⎿  Read 120 lines (ctrl+o to expand)
✽ Simmering… (3m 42s · ↓ 14.7k tokens)"

# 可視 frame の非空行 9 行（下端空行は各 test が付け足す）
SS_PH_VISIBLE_BODY="● 直前の turn は完了している
  ⎿  Read 42 lines (ctrl+o to expand)
  ⎿  Read 43 lines (ctrl+o to expand)
  ⎿  Read 44 lines (ctrl+o to expand)
──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  cc-session  main*
  ⏵⏵ bypass permissions on (shift+tab to cycle)
"

@test "detect_state: 可視 frame の下端に空行 3 行があっても scrollback の残骸を拾わない → input-waiting（sc-8bhc follow-up 本丸）" {
    # pane_height=12 は下端空行 3 行を含む実 pane の値。capture の末尾空行を保持しないと
    # tail -12 が scrollback のスピナー行まで巻き込み processing を返す（本 test の teeth）。
    run_detect_state_with_frames_ph \
        "$SS_PH_SCROLLBACK" \
        "${SS_PH_VISIBLE_BODY}"$'\n\n\n' \
        12
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: 同型で下端空行 0 の対照 frame も input-waiting（下端空行の有無で結果が動かない・sc-8bhc follow-up）" {
    run_detect_state_with_frames_ph \
        "$SS_PH_SCROLLBACK" \
        "${SS_PH_VISIBLE_BODY}" \
        9
    [[ "$status" -eq 0 ]]
    [[ "$output" == "input-waiting" ]]
}

@test "detect_state: 可視 frame 下端が空行でも frame 内スピナーは processing のまま（偽陰性を作らない・sc-8bhc follow-up）" {
    run_detect_state_with_frames_ph \
        "  ⎿  Read 8 lines (ctrl+o to expand)" \
        "✽ Boondoggling… (6m 16s · ↓ 23.2k tokens)
  ⎿ · Tip: Use /btw to ask a quick side question without interrupting
     Claude's current work
──────────────────────────────
${SS_PROMPT_LINE}
──────────────────────────────
  ⏵⏵ bypass permissions on (shift+tab to cycle)
"$'\n\n' \
        9
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

@test "detect_state: capture-pane 失敗時は processing へ倒れる（fallback 分岐の pin・sc-8bhc follow-up）" {
    # 下端空行を保持する番兵 X は必ず `&&` で繋ぐこと。`;` にすると substitution の status が
    # printf の 0 になり、この fallback 分岐が構造的に死ぬ。
    # 注記（本 test の限界・過大主張を避ける）: `;` 形でも capture 失敗時の captured は空になり
    # 全判定を素通りして末尾の既定 processing に落ちるため、本 test 単体では `&&` と `;` を
    # 判別できない。本 test が pin するのは「capture 不能な pane で processing を返す」という
    # 観測可能な契約（fallback を input-waiting 側へ書き換える退行の検出）であり、`&&` の
    # 必要性そのものは実装側の構造要件として担保する。
    local stub="$BATS_TEST_TMPDIR/ss-tmux-stub-capfail.sh"
    cat > "$stub" <<'CAPFAIL_EOF'
tmux() {
    case "${1:-}" in
        list-panes)
            printf 'claude\t0\t%%0\t20\t/home/test\n'
            ;;
        capture-pane)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}
export -f tmux
CAPFAIL_EOF
    run bash -c "source '$stub'; source '$SESSION_STATE_SCRIPT'; detect_state 'test-session:0'"
    [[ "$status" -eq 0 ]]
    [[ "$output" == "processing" ]]
}

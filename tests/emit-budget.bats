#!/usr/bin/env bats
# tests/emit-budget.bats — emit-budget 共有 lib（scripts/hooks/lib/emit_budget.sh・sc-mzhi / orch-db47 leg(4)）の teeth
#
# 対象契約（bead sc-mzhi notes ■7 / ■8 / ■11）:
#   ■11-3 measure-then-emit の単一入口 API（body を丸ごと受け u16 を内部実測し、超過時だけ warn を
#         **先頭**へ前置して一括出力）。閾値は env 上書き seam を持つ（この seam が無いと健全な実 hook は
#         閾値を超えないため warn を bats から実証できない）。
#   ■11-4 python3 不在は計測を諦め本文だけ出して exit 0（fail-open・本文注入を絶対に止めない）。
#   ■11-5 teeth 5 本: (1)閾値+1 で warn 発火かつ stdout 1 行目 / (2)閾値-1 で無発火 / (3)cliff 超過でも
#         exit 0 / (4)無出力経路では warn も出ない / (5)mutation で lib の計測行を潰すと warn teeth が RED へ flip。
#   ■11-1 共用先 3 hook（session-start-role-inject.sh / session-start-mailbox-scan.sh /
#         user-prompt-mailbox-scan.sh）すべてから warn 経路が通ることを pin。
#   ■11-6 mailbox 2 本は **hermetic stub 経路のみ**で検証する（実 orch 台帳を叩く admin 実走は禁止＝
#         foreign 台帳 read）。ここでは fixture 台帳 + PATH 前置の mock bd で閉じる。
#   ■8-1  u16 = UTF-16 code unit。codepoint 数（bash `${#var}` / `wc -m`）や byte 数（`wc -c`）ではない
#         ことを非 BMP 文字で pin する（代用実装への退行検知）。
#   ■7    無出力経路（degrade / opt-out）では warn も出さない＝既存 suite の `[ -z "$output" ]` 群を守る。
#
# 実行: bats tests/emit-budget.bats

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    LIB="$REPO/scripts/hooks/lib/emit_budget.sh"
    ROLE_HOOK="$REPO/scripts/hooks/session-start-role-inject.sh"
    SS_MBX_HOOK="$REPO/scripts/hooks/session-start-mailbox-scan.sh"
    UP_MBX_HOOK="$REPO/scripts/hooks/user-prompt-mailbox-scan.sh"

    TEST_TMPDIR="$(mktemp -d -t scribe-emitbudget-bats-XXXXXX)"

    # --- role-inject 用 fixture（.beads opt-in を通す anchor 相当 cwd）---
    ANCHOR_DIR="$TEST_TMPDIR/proj"
    WT_DIR="$TEST_TMPDIR/proj/.worktrees/spawn/x-1"
    mkdir -p "$ANCHOR_DIR/.beads" "$WT_DIR/.beads"
    ANCHOR_JSON="{\"cwd\":\"$ANCHOR_DIR\"}"
    WT_JSON="{\"cwd\":\"$WT_DIR\"}"

    # --- mailbox hook 用 hermetic fixture（■11-6: 実 orch 台帳へ到達させない）---
    SELF_LEDGER="$TEST_TMPDIR/proj-sc"
    ORCH_LEDGER="$TEST_TMPDIR/scriptorium"
    mkdir -p "$SELF_LEDGER/.beads" "$SELF_LEDGER/sub" "$ORCH_LEDGER/.beads"
    printf '{"database":"dolt","dolt_database":"sc"}'   > "$SELF_LEDGER/.beads/metadata.json"
    printf '{"database":"dolt","dolt_database":"orch"}' > "$ORCH_LEDGER/.beads/metadata.json"
    SELF_CWD="$SELF_LEDGER/sub"
    STATE_DIR="$TEST_TMPDIR/state"

    # mock bd（PATH 前置）: hydrate（repo sync/add）が来たら異常終了する既存 stub と同型。
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
echo '[{"id":"orch-abc","priority":1,"title":"scribe 宛 coord テスト"},{"id":"orch-xyz","priority":2,"title":"knowledge relay テスト"}]'
exit 0
MOCKBD
    chmod +x "$BIN/bd"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# --- helpers -------------------------------------------------------------

# repeat_char <char> <n> → <char> を n 回並べた文字列
repeat_char() {
    local c="$1" n="$2" out=""
    local i=0
    while [ "$i" -lt "$n" ]; do out="$out$c"; i=$((i + 1)); done
    printf '%s' "$out"
}

# emit_via <lib> <warn> <cliff> <body> — lib を source して単一入口 API を呼ぶ
emit_via() {
    local lib="$1" warn="$2" cliff="$3" body="$4"
    env SCRIBE_EMIT_BUDGET_WARN_U16="$warn" SCRIBE_EMIT_BUDGET_CLIFF_U16="$cliff" \
        bash -c '. "$1"; scribe_emit_with_budget "$2" "TEST"' _ "$lib" "$body"
}

WARN_MARK='⚠️ [scribe/emit-budget]'

# ---- 静的 ----
@test "static: lib が存在し bash 構文 OK（source 専用ゆえ実行ビットは不問）" {
    [ -f "$LIB" ]
    run bash -n "$LIB"
    [ "$status" -eq 0 ]
}

@test "static: 共用先 3 hook が emit_budget.sh を source し単一入口 API を呼ぶ（■11-1）" {
    local h
    for h in "$ROLE_HOOK" "$SS_MBX_HOOK" "$UP_MBX_HOOK"; do
        run grep -Fq -- 'lib/emit_budget.sh' "$h"
        [ "$status" -eq 0 ]
        run grep -Fq -- 'scribe_emit_with_budget' "$h"
        [ "$status" -eq 0 ]
    done
}

@test "static: 対象外 3 本（guard-health.py / heartbeat / stop-push）は emit_budget を source しない（■11-2）" {
    # guard-health は Python ゆえ bash lib を source 不可、heartbeat/stop-push は stdout 無出力が
    # session-safety 要件（warn を出す余地が無い）。誤 wire の回帰ネット。
    local h
    for h in "$REPO/scripts/hooks/session-start-guard-health.py" \
             "$REPO/scripts/hooks/session-boundary-heartbeat.sh" \
             "$REPO/scripts/hooks/session-stop-push.sh"; do
        run grep -Fq -- 'emit_budget' "$h"
        [ "$status" -ne 0 ]
    done
}

# ---- teeth (1): 閾値+1 u16 で warn が発火し stdout の 1 行目に出る ----
@test "teeth1: 閾値+1 u16 → warn が発火し stdout の 1 行目に出る（本文はその後に無傷で続く）" {
    local body
    body="$(repeat_char a 101)"
    run --separate-stderr emit_via "$LIB" 100 10000 "$body"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "$WARN_MARK"* ]]           # ★先頭行であること（measure-then-emit の核心）
    [[ "${lines[0]}" == *"101 u16"* ]]             # 実測値が出る
    [[ "${lines[0]}" == *"100 u16"* ]]             # 閾値が出る
    [ "${lines[1]}" = "$body" ]                    # 本文は truncate も改変もされない
    [ "${#lines[@]}" -eq 2 ]                       # cliff 未満なので warn は 1 行だけ
}

# ---- teeth (2): 閾値-1 u16 で無発火 ----
@test "teeth2: 閾値-1 u16 → warn は 1 行も出ず本文だけが出る" {
    local body
    body="$(repeat_char a 99)"
    run --separate-stderr emit_via "$LIB" 100 10000 "$body"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$WARN_MARK"* ]]
    [ "$output" = "$body" ]
}

@test "teeth2b: ちょうど閾値 u16 → 無発火（境界は『超過』でのみ発火する）" {
    local body
    body="$(repeat_char a 100)"
    run --separate-stderr emit_via "$LIB" 100 10000 "$body"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$WARN_MARK"* ]]
    [ "$output" = "$body" ]
}

# ---- teeth (3): cliff 超過でも exit 0（fail-open・truncate しない） ----
@test "teeth3: cliff 超過 → warn 2 行に増えるが exit 0・本文は 1 byte も削られない" {
    local body
    body="$(repeat_char a 50)"
    run --separate-stderr emit_via "$LIB" 10 20 "$body"
    [ "$status" -eq 0 ]                            # ★超過は非 0 終了にしない（fail-open）
    [[ "${lines[0]}" == "$WARN_MARK"* ]]
    [[ "${lines[1]}" == "$WARN_MARK"* ]]
    [[ "${lines[1]}" == *"cliff"* ]]
    [ "${lines[2]}" = "$body" ]                    # 本文は無傷（truncate 禁止）
    [ "${#lines[@]}" -eq 3 ]
}

# ---- teeth (4): 無出力経路では warn も出ない ----
@test "teeth4: body 空 → 無出力・exit 0（warn も出さない・■7）" {
    run --separate-stderr emit_via "$LIB" 1 1 ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "teeth4b: role-inject の opt-out 経路（SCRIBE_ROLE=none）は warn 閾値 1 でも無出力（■7）" {
    # 「出力ゼロ」を assert する既存 test 群（19 本）を warn の無条件出力が壊さないことの e2e pin。
    run --separate-stderr bash -c "printf '%s' '$ANCHOR_JSON' | env -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        SCRIBE_ROLE=none SCRIBE_EMIT_BUDGET_WARN_U16=1 CLAUDE_PLUGIN_ROOT='$REPO' '$ROLE_HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "teeth4c: role-inject の degrade 経路（doc 不在）も warn 閾値 1 で無出力（■7）" {
    # ★CLAUDE_PLUGIN_ROOT は **実在するが docs を持たない** dir にする——不在 dir を渡すと script が
    #   「script 位置から導出」へフォールバックし実 repo の docs を拾って degrade 経路に入らない。
    local emptyroot="$TEST_TMPDIR/emptyroot"
    mkdir -p "$emptyroot"
    run --separate-stderr bash -c "printf '%s' '$ANCHOR_JSON' | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        SCRIBE_EMIT_BUDGET_WARN_U16=1 CLAUDE_PLUGIN_ROOT='$emptyroot' '$ROLE_HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"protocol.md 不在"* ]]
}

# ---- teeth (5): mutation — lib の計測行を潰すと warn teeth が RED へ flip ----
@test "teeth5(mutation): 計測行を潰した lib では teeth1 の warn assert が RED へ flip する（本文は出続ける）" {
    local mut="$TEST_TMPDIR/emit_budget.mutant.sh"
    # ★標的は「u16 を数える式」そのもの（fail-open 分岐ではない）。常に 0 を返すよう潰す。
    sed 's|^sys\.stdout\.write(str(len(data\.encode("utf-16-le")) // 2))$|sys.stdout.write("0")|' \
        "$LIB" > "$mut"
    # mutation が実際に効いたことを先に確認する（sed 空振り＝vacuous な mutation test を防ぐ）
    ! cmp -s "$LIB" "$mut"
    run bash -n "$mut"
    [ "$status" -eq 0 ]

    local body
    body="$(repeat_char a 101)"

    # baseline: 素の lib では teeth1 の assert が GREEN（warn が 1 行目）
    run --separate-stderr emit_via "$LIB" 100 10000 "$body"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "$WARN_MARK"* ]]

    # mutant: 同じ assert が RED へ flip（warn が 1 行も出ない）
    run --separate-stderr emit_via "$mut" 100 10000 "$body"
    [ "$status" -eq 0 ]                            # fail-open は保つ（潰れても本文注入は止めない）
    [[ "${lines[0]}" != "$WARN_MARK"* ]]           # ← teeth1 の assert がここで RED になる
    [[ "$output" != *"$WARN_MARK"* ]]
    [ "$output" = "$body" ]                        # 本文は無傷で出続ける
}

# ---- fail-open（■11-4）: python3 不在でも本文だけ出して exit 0 ----
@test "fail-open: python3 不在 → 計測を諦め本文だけ出して exit 0（warn 無し・truncate 無し）" {
    local bindir="$TEST_TMPDIR/nopy-bin" b
    mkdir -p "$bindir"
    for b in bash env printf cat sed grep; do
        ln -sf "$(command -v "$b")" "$bindir/$b"
    done
    # python3 は意図的にリンクしない → command -v python3 が失敗
    local body
    body="$(repeat_char a 500)"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_EMIT_BUDGET_WARN_U16=10 SCRIBE_EMIT_BUDGET_CLIFF_U16=20 \
        bash -c '. "$1"; scribe_emit_with_budget "$2" "TEST"' _ "$LIB" "$body"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$WARN_MARK"* ]]
    [ "$output" = "$body" ]
}

@test "fail-open: 閾値が非数値でも die せず既定へ倒れる（本文は必ず出る）" {
    local body
    body="$(repeat_char a 50)"
    run --separate-stderr env SCRIBE_EMIT_BUDGET_WARN_U16="abc" SCRIBE_EMIT_BUDGET_CLIFF_U16="" \
        bash -c '. "$1"; scribe_emit_with_budget "$2" "TEST"' _ "$LIB" "$body"
    [ "$status" -eq 0 ]
    [ "$output" = "$body" ]                        # 既定 8000 へ倒れる＝50 u16 は無発火
}

# ---- ■8-1: 単位が u16（UTF-16 code unit）であること = codepoint 数でも byte 数でもない ----
@test "unit(■8-1): 非 BMP 文字は 1 文字 2 u16 と数える（codepoint 数・byte 数の代用実装を弾く）" {
    # 𝄞 (U+1D11E) は codepoint 1 / UTF-8 4 byte / UTF-16 2 code unit。50 文字 = 100 u16。
    local body
    body="$(repeat_char '𝄞' 50)"
    # 閾値 99 → 100 u16 は超過（codepoint 数 50 で数える実装なら発火しない＝RED になる）
    run --separate-stderr emit_via "$LIB" 99 10000 "$body"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "$WARN_MARK"* ]]
    [[ "${lines[0]}" == *"100 u16"* ]]
    # 閾値 100 → 同数は無発火（byte 数 200 で数える実装なら発火してしまう＝RED になる）
    run --separate-stderr emit_via "$LIB" 100 10000 "$body"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$WARN_MARK"* ]]
}

# ---- ■11-1: 共用先 3 hook すべてから warn 経路が通る（e2e） ----
@test "3hook(1/3): session-start-role-inject.sh から warn が stdout 1 行目に出る" {
    run --separate-stderr bash -c "printf '%s' '$ANCHOR_JSON' | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        SCRIBE_EMIT_BUDGET_WARN_U16=10 SCRIBE_EMIT_BUDGET_CLIFF_U16=20 CLAUDE_PLUGIN_ROOT='$REPO' '$ROLE_HOOK'"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "$WARN_MARK"* ]]
    [[ "${lines[0]}" == *"role=admin"* ]]                        # label が発信元を示す
    # ■7 (2): warn の直後は role header 1 行
    [[ "${lines[2]}" == "=== [scribe/SessionStart] role=admin"* ]]
    # 本文は従来どおり注入される（warn は追加であって置換ではない）
    [[ "$output" == *"gate funnel"* ]]
}

@test "3hook(2/3): session-start-mailbox-scan.sh から warn が stdout 1 行目に出る（hermetic stub・■11-6）" {
    run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' \
        | env -u SCRIBE_ROLE PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR' \
              SCRIBE_EMIT_BUDGET_WARN_U16=10 SCRIBE_EMIT_BUDGET_CLIFF_U16=20 bash '$SS_MBX_HOOK'"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "$WARN_MARK"* ]]
    [[ "${lines[0]}" == *"SessionStart mailbox"* ]]
    [[ "${lines[2]}" == "=== [scribe/SessionStart] 📬 下り mailbox"* ]]
    [[ "$output" == *"orch-abc"* ]]                              # surface 本文は無傷
    # hydrate 禁止の回帰も兼ねる（stub は repo サブコマンドで異常終了する）
    run grep -c 'repo' "$BD_CALL_LOG"
    [ "$output" = "0" ]
}

@test "3hook(3/3): user-prompt-mailbox-scan.sh から warn が stdout 1 行目に出る（hermetic stub・■11-6）" {
    run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb2\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"x\"}' \
        | env -u SCRIBE_ROLE PATH='$BIN:$PATH' SCRIBE_MAILBOX_TTL_SEC=0 SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' \
              SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR' \
              SCRIBE_EMIT_BUDGET_WARN_U16=10 SCRIBE_EMIT_BUDGET_CLIFF_U16=20 bash '$UP_MBX_HOOK'"
    [ "$status" -eq 0 ]
    [[ "${lines[0]}" == "$WARN_MARK"* ]]
    [[ "${lines[0]}" == *"UserPromptSubmit mailbox"* ]]
    [[ "${lines[2]}" == "=== [scribe/UserPromptSubmit] 📬 下り mailbox 新着"* ]]
    [[ "$output" == *"orch-abc"* ]]
}

@test "3hook: 無出力経路（mailbox 新着ゼロ相当 = worker role）は warn 閾値 1 でも完全無出力" {
    local wt="$SELF_LEDGER/.worktrees/spawn/x-1"
    mkdir -p "$wt"
    run --separate-stderr bash -c "printf '{\"cwd\":\"$wt\",\"session_id\":\"sess-eb3\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' \
        | env -u SCRIBE_ROLE PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR' \
              SCRIBE_EMIT_BUDGET_WARN_U16=1 bash '$SS_MBX_HOOK'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- ■7: role-inject の 5 段順序（機械防御 warn が本文の後ろへ移った） ----
@test "order(■7): worker の機械防御 split-brain warning は本文（§2-4）の**後ろ**に出る" {
    run --separate-stderr bash -c "printf '%s' '$WT_JSON' | env -u SCRIBE_ROLE -u SCRIBE_WORKER -u SCRIBE_WORKTREE \
        -u TMUX -u TMUX_PANE -u SCRIBE_TMUX CLAUDE_PLUGIN_ROOT='$REPO' '$ROLE_HOOK'"
    [ "$status" -eq 0 ]
    # 本文（§2 見出し）と warning ブロック固有 signature の**行番号**を取り、順序を assert する
    local body_ln warn_ln
    body_ln="$(printf '%s\n' "$output" | grep -n -F '## 2. worker prompt 規約' | head -n1 | cut -d: -f1)"
    warn_ln="$(printf '%s\n' "$output" | grep -n -F 'このセッションは scribe-spawn 経由ではありません' | head -n1 | cut -d: -f1)"
    [ -n "$body_ln" ]
    [ -n "$warn_ln" ]
    [ "$warn_ln" -gt "$body_ln" ]                                # ★本文の後ろ（旧: 本文の前）
    # 本文は 1 byte も削らない: warning 本文の各行が従来どおり全て残る
    [[ "$output" == *"edit-write-guard.py"* ]]
    [[ "$output" == *"起動し直す"* ]]
    [[ "$output" == *"機械防御が全て無効"* ]]
}

@test "order(■7): warn 無し時は header が 1 行目 — header → 自衛文 intro → 本文 の順（warn は超過時のみ前置）" {
    # 実 worker 注入は現状 8,000 u16 を超える（core trim は分割 A の領分）ため、既定閾値のままだと
    # 1 行目が warn になる。ここは「warn が出ないときの 5 段順序」を見るので warn=0（opt-out）で無効化する。
    run --separate-stderr bash -c "printf '%s' '$WT_JSON' | env -u SCRIBE_ROLE -u SCRIBE_WORKER -u SCRIBE_WORKTREE \
        -u TMUX -u TMUX_PANE -u SCRIBE_TMUX SCRIBE_EMIT_BUDGET_WARN_U16=0 CLAUDE_PLUGIN_ROOT='$REPO' '$ROLE_HOOK'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"$WARN_MARK"* ]]                                 # warn=0 は opt-out（警告を出さない）
    # ★bats の `lines` は IFS=改行 の read -a で分割されるため **空行が畳まれる**（非空行の並びになる）。
    #   ゆえに header の次の非空行が intro であることを見る（生の空行込み順序は上の grep -n テストが担保）。
    [[ "${lines[0]}" == "=== [scribe/SessionStart] role=worker"* ]]   # (2) header が 1 行目
    [[ "${lines[1]}" == "あなたは scribe worker"* ]]                   # (3) 自衛文枠 intro
}

# ---- teeth (6): fail-open guard が「API の存在」で発火する（silent total loss の封鎖・sc-mzhi self-review major） ----
@test "teeth6: API を欠いた valid な lib を掴んでも 3 hook は本文を出し続ける（source rc だけを見る guard の穴）" {
    # 穴の再現条件: lib が「構文的には valid だが scribe_emit_with_budget を含まない」状態
    # （部分書込 / rsync・cp 中断 / plugin 版ズレ / 将来の関数リネーム）。`.` は rc=0 を返すため
    # 『source 失敗』だけを見る fallback は定義されず、呼出が command not found（stderr のみ）に
    # なって script 末尾の exit 0 へ到達する＝rc=0 / stdout 0 byte の **silent total loss**。
    # とくに session-start-mailbox-scan では dedupe seed が emit の前に焼かれているため、
    # 「seen 済みなのに一度も surface されない」配送保証の恒久破壊になる。
    local fake="$TEST_TMPDIR/fakeplugin/scripts/hooks"
    mkdir -p "$fake/lib"
    cp "$ROLE_HOOK" "$SS_MBX_HOOK" "$UP_MBX_HOOK" "$fake/"
    cp "$REPO/scripts/hooks/lib/mailbox-common.sh" "$fake/lib/"
    cat > "$fake/lib/emit_budget.sh" <<'PARTIAL'
# 部分書込を模した lib: helper だけ在って単一入口 API が無い（bash 構文は valid）
SCRIBE_EMIT_BUDGET_WARN_U16_DEFAULT=8000
SCRIBE_EMIT_BUDGET_CLIFF_U16_DEFAULT=10000
_scribe_emit_budget_num() { printf '%s' "$1"; }
PARTIAL

    # 前提の非 vacuity: この lib は **source に成功し**、かつ API を定義しない（＝穴の発火条件そのもの）
    run bash -c '. "$1" && ! command -v scribe_emit_with_budget >/dev/null 2>&1' _ "$fake/lib/emit_budget.sh"
    [ "$status" -eq 0 ]

    # (1/3) role-inject: admin 役割規約の注入が消えない
    run --separate-stderr bash -c "printf '%s' '$ANCHOR_JSON' | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        SCRIBE_EMIT_BUDGET_WARN_U16=0 CLAUDE_PLUGIN_ROOT='$REPO' bash '$fake/session-start-role-inject.sh'"
    [ "$status" -eq 0 ]
    [ -n "$output" ]                                             # ★ここが穴では 0 byte になる
    [[ "${lines[0]}" == "=== [scribe/SessionStart] role=admin"* ]]
    [[ "$output" == *"gate funnel"* ]]

    # (2/3) session-start-mailbox-scan: surface 本文が消えない（seed 済みの恒久消失を防ぐ）
    run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb6a\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' \
        | env -u SCRIBE_ROLE PATH='$BIN:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR/a' \
              SCRIBE_EMIT_BUDGET_WARN_U16=0 bash '$fake/session-start-mailbox-scan.sh'"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"orch-abc"* ]]

    # (3/3) user-prompt-mailbox-scan: 新着中継が消えない
    run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb6b\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"x\"}' \
        | env -u SCRIBE_ROLE PATH='$BIN:$PATH' SCRIBE_MAILBOX_TTL_SEC=0 SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' \
              SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR/b' SCRIBE_EMIT_BUDGET_WARN_U16=0 bash '$fake/user-prompt-mailbox-scan.sh'"
    [ "$status" -eq 0 ]
    [ -n "$output" ]
    [[ "$output" == *"orch-abc"* ]]
}

# ---- teeth (7): degrade 型 fail-open — 「遅い / 固まる python3」でも本文が消えない（sc-mzhi self-review major） ----
@test "teeth7: python3 が hang する host でも 3 hook は wire timeout 前に本文を出す（計測は bound される）" {
    # 穴の構造: measure-then-emit ゆえ本文の printf は **必ず計測の後**に来る。計測が python3 を無制限に
    # 待つと、hang / 極端に遅い環境（pyenv・conda 等の shim、stale NFS 上の home、ロック待ちの wrapper）で
    # hook 自体が wire の timeout（hooks/hooks.json は SessionStart / UserPromptSubmit とも 10,000ms）で
    # kill され、**stdout が 1 byte も出ない**:
    #   - role-inject → admin 役割規約の注入が丸ごと消失（wire は `|| true` ゆえ誰にも見えない silent total loss）
    #   - mailbox     → dedupe seed（mbx_seed_seen）は emit の **前** に焼かれているため「seen 済みなのに
    #                   一度も surface されない」＝UserPromptSubmit 中継も unseen フィルタで抑止され、
    #                   その session では配送が恒久的に失われる（本 hook 自身が『配送保証の恒久破壊』と呼ぶ型）。
    # 既存 teeth の「python3 **不在**」は `command -v` で即 return 1 する別経路であり、この degrade 型
    # （在るが返ってこない）は無防備だった。ここでそれを pin する。
    command -v timeout >/dev/null 2>&1 || skip "timeout(coreutils) 不在ホストでは計測の bound 自体が成立しない"

    local slowbin="$TEST_TMPDIR/slowpy-bin"
    mkdir -p "$slowbin"
    cat > "$slowbin/python3" <<'SLOWPY'
#!/usr/bin/env bash
sleep 20
SLOWPY
    chmod +x "$slowbin/python3"
    cp "$BIN/bd" "$slowbin/bd"                       # mailbox 用 mock bd（hydrate 検出つき）も同じ dir へ

    # (1a/3) role-inject: hang python3 単独。計測 bound が存在することの pin。
    run --separate-stderr bash -c "printf '%s' '$ANCHOR_JSON' | timeout 10 env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        PATH='$slowbin:$PATH' CLAUDE_PLUGIN_ROOT='$REPO' bash '$ROLE_HOOK'"
    [ "$status" -eq 0 ]                              # ★124(=時間切れ)にならない
    [ -n "$output" ]
    [[ "${lines[0]}" == "=== [scribe/SessionStart] role=admin"* ]]   # 計測は諦めるが本文は先頭から無傷
    [[ "$output" != *"$WARN_MARK"* ]]                # 計測不能なので warn は出さない（fail-open）
    [[ "$output" == *"gate funnel"* ]]

    # --- role-inject の合成条件 fixture ---------------------------------------------------
    # ★事実: role-inject は emit の前に **timeout で包まれていない待ち**を持つ。
    #   `_scribe_has_beads` は cwd 直下に .beads が無いと `git rev-parse --show-toplevel` を呼ぶ
    #   （repo のサブディレクトリから起動したセッションでは必ずこの経路）。もう 1 つは
    #   `_scribe_is_consult_window` の `tmux display-message`。どちらも所要時間に上限が無い。
    #   ゆえに (1a) の「hang python3 単独」では **bound の値**が wire 予算に収まるかを pin できない
    #   （bound を何秒に伸ばしても単独なら wire 内に収まってしまう）。ここで unbounded な待ちを
    #   実体として噛ませ、bound の値まで含めて pin する。
    local realgit gitrepo slowgit GITSUB_JSON
    realgit="$(command -v git)"
    gitrepo="$TEST_TMPDIR/gitsub"
    mkdir -p "$gitrepo/.beads" "$gitrepo/sub"        # .beads は toplevel だけ（cwd=sub には無い）
    git -C "$gitrepo" init -q
    GITSUB_JSON="{\"cwd\":\"$gitrepo/sub\"}"
    slowgit="$TEST_TMPDIR/slowgit-bin"
    mkdir -p "$slowgit"
    cp "$slowbin/python3" "$slowgit/python3"
    cat > "$slowgit/git" <<GITSTUB
#!/usr/bin/env bash
sleep "\${MOCK_GIT_SLEEP:-7}"
exec "$realgit" "\$@"
GITSTUB
    chmod +x "$slowgit/git"

    # (1b/3) role-inject 合成条件: unbounded な git 7s + hang python3 + wire 予算 10s。
    run --separate-stderr bash -c "printf '%s' '$GITSUB_JSON' | timeout 10 env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        PATH='$slowgit:$PATH' CLAUDE_PLUGIN_ROOT='$REPO' bash '$ROLE_HOOK'"
    [ "$status" -eq 0 ]                              # ★124(=wire kill)にならない
    [ -n "$output" ]                                 # ★boot path の規約注入が silent に全損しない
    [[ "${lines[0]}" == "=== [scribe/SessionStart] role=admin"* ]]
    [[ "$output" == *"gate funnel"* ]]

    # (1c/3) 非 vacuity（role-inject・bound の**値**を標的にする mutation）: 計測 bound を大きい値へ
    #   sed すると同じ合成条件で wire timeout に達し stdout 0 byte になる＝(1b) が RED へ flip する。
    #   ※ role-inject は lib 既定をそのまま使う（呼び手側の上書きを持たない）ので、標的は lib の既定値 1 行。
    #   分解能（本 fixture = git 7s + hang python3 + wire 10s での実測）:
    #     bound=1 → rc 0 / 202,213 byte（生存）/ bound=3 → rc 124 / 0 byte / bound=4 → rc 124 / bound=6 → rc 124
    #   ＝既定を 1 から 3 以上へ bump した時点で本 teeth が RED になる（bump の検知漏れが無い）。
    local rfake="$TEST_TMPDIR/roleboundplugin/scripts/hooks"
    mkdir -p "$rfake/lib"
    cp "$ROLE_HOOK" "$rfake/"
    sed 's|^SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC_DEFAULT=1$|SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC_DEFAULT=6|' \
        "$LIB" > "$rfake/lib/emit_budget.sh"
    ! cmp -s "$LIB" "$rfake/lib/emit_budget.sh"      # sed 空振り（vacuous mutation）を弾く
    run bash -n "$rfake/lib/emit_budget.sh"
    [ "$status" -eq 0 ]
    run --separate-stderr bash -c "printf '%s' '$GITSUB_JSON' | timeout 10 env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        PATH='$slowgit:$PATH' CLAUDE_PLUGIN_ROOT='$REPO' bash '$rfake/session-start-role-inject.sh'"
    [ "$status" -ne 0 ]                              # 124 = wire が kill する状況の再現
    [ -z "$output" ]                                 # ★(1b) の assert がここで RED へ flip する

    # (2/3)(3/3) mailbox 2 本（hermetic stub・■11-6）。
    # ★ここは **合成条件**で測る（sc-mzhi self-review 2 巡目 major）: mailbox は emit の前に
    #   mbx_direct_read の bound（SessionStart=8s / UserPromptSubmit=5s）を既に払っている。即答 bd stub
    #   では「計測 bound + 他の bound の和 < wire timeout(10,000ms)」が pin されない（旧 teeth はここが
    #   vacuous で、実際 8s bd + 3s 計測 = 10.06s の wire 超過を見逃した）。ゆえに **遅い bd**（dolt 埋込
    #   backend の lock 待ちで数秒かかるのは既知の実態）と **hang する python3** を重ねて壁時計を assert する。
    # ※ mbx_emit は jq → python3 の順で整形するため、jq 不在ホストでは **本 lib とは別の**（本 diff 以前
    #   から在る）**unbounded な** python3 依存に先に当たる。その bound 化は lib/mailbox-common.sh の
    #   変更を要し本 leg の allowlist 外＝既知限界。ゆえに emit_budget 側の合成 bound は jq 在ホストで
    #   測り、jq 不在ホストでは **silent skip せず** 既知 gap の実在を構造で assert する（下の else）。
    if command -v jq >/dev/null 2>&1; then
        local slowbd="$TEST_TMPDIR/slowbd-bin" t0 t1 elapsed
        mkdir -p "$slowbd"
        cp "$slowbin/python3" "$slowbd/python3"
        # 遅い bd: 7s 待ってから成功で JSON を返す（mbx_direct_read の 8s bound 内＝read は成功する）
        cat > "$slowbd/bd" <<'SLOWBD'
#!/usr/bin/env bash
sleep "${MOCK_BD_SLEEP:-7}"
echo '[{"id":"orch-abc","priority":1,"title":"scribe 宛 coord テスト"}]'
exit 0
SLOWBD
        chmod +x "$slowbd/bd"

        # SessionStart: 7s(bd) + 1s(計測) = 8s 台 < 10s。seed は emit の前に焼かれているため、
        # ここで kill されると「seen 済みなのに一度も surface されない」恒久破壊になる。
        t0="$(date +%s)"
        run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb7a\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' \
            | timeout 10 env -u SCRIBE_ROLE PATH='$slowbd:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' \
                  SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR/h1' bash '$SS_MBX_HOOK'"
        t1="$(date +%s)"
        elapsed=$((t1 - t0))
        [ "$status" -eq 0 ]                          # ★124(=wire kill)にならない
        [ "$elapsed" -lt 10 ]                        # ★壁時計が wire timeout(10,000ms)未満
        [[ "$output" == *"orch-abc"* ]]              # seed 済みの bead が一度も surface されない、を防ぐ

        # UserPromptSubmit: bd bound は 5s ゆえ 4s の bd で成功させる。4s + 1s = 5s 台 < 10s。
        t0="$(date +%s)"
        run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb7b\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"x\"}' \
            | timeout 10 env -u SCRIBE_ROLE PATH='$slowbd:$PATH' MOCK_BD_SLEEP=4 SCRIBE_MAILBOX_TTL_SEC=0 \
                  SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR/h2' bash '$UP_MBX_HOOK'"
        t1="$(date +%s)"
        elapsed=$((t1 - t0))
        [ "$status" -eq 0 ]
        [ "$elapsed" -lt 10 ]
        [[ "$output" == *"orch-abc"* ]]

        # --- 非 vacuity（合成の側）: 計測 bound を「呼び手の残り予算に合わない値」へ戻すと、同条件で
        #     wire timeout に達して stdout 0 byte になる＝この assert 群が RED へ flip する。
        #     標的は本 hook の合成 pin そのもの（`:-1}` → `:-6}`）。7s(bd) + 6s(計測) = 13s > 10s。
        local mfake="$TEST_TMPDIR/mbxbudget/scripts/hooks"
        mkdir -p "$mfake/lib"
        cp "$REPO/scripts/hooks/lib/mailbox-common.sh" "$LIB" "$mfake/lib/"
        sed 's|SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC="\${SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC:-1}"|SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC="${SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC:-6}"|' \
            "$SS_MBX_HOOK" > "$mfake/session-start-mailbox-scan.sh"
        ! cmp -s "$SS_MBX_HOOK" "$mfake/session-start-mailbox-scan.sh"   # sed 空振り（vacuous）を弾く
        run bash -n "$mfake/session-start-mailbox-scan.sh"
        [ "$status" -eq 0 ]

        run --separate-stderr bash -c "printf '{\"cwd\":\"$SELF_CWD\",\"session_id\":\"sess-eb7c\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}' \
            | timeout 10 env -u SCRIBE_ROLE PATH='$slowbd:$PATH' SCRIBE_ORCH_ANCHOR='$ORCH_LEDGER' \
                  SCRIBE_MAILBOX_STATE_DIR='$STATE_DIR/h3' bash '$mfake/session-start-mailbox-scan.sh'"
        [ "$status" -ne 0 ]                          # 124 = wire が kill する状況の再現
        [ -z "$output" ]                             # ★surface が丸ごと消える（seed だけが焼かれる）
    else
        # jq 不在ホスト: 合成 bound を単独では測れない（mbx_emit が先に unbounded な python3 へ落ちる）。
        # silent skip にせず、その gap が実在することを構造で assert して記録に残す。
        # mbx_emit の python3 fallback が存在し、かつ timeout で包まれていないこと＝gap の定義そのもの。
        run grep -Fq -- 'elif command -v python3' "$REPO/scripts/hooks/lib/mailbox-common.sh"
        [ "$status" -eq 0 ]
        # tripwire: mbx_emit 側が bound 化されたらここが RED になり、上のコメント（既知限界）の
        # 更新と本分岐の撤去を促す。bound 化は本 leg の allowlist 外＝別 issue の領分。
        run grep -Eq 'timeout[^|]*python3 -c' "$REPO/scripts/hooks/lib/mailbox-common.sh"
        [ "$status" -ne 0 ]
    fi

    # --- 非 vacuity: bound を剥がした lib では同条件で stdout 0 byte になる（この teeth が RED へ flip する）---
    local fake="$TEST_TMPDIR/hangplugin/scripts/hooks"
    mkdir -p "$fake/lib"
    cp "$ROLE_HOOK" "$fake/"
    sed 's|^\( *\)timeout "[^"]*" python3 |\1python3 |' "$LIB" > "$fake/lib/emit_budget.sh"
    ! cmp -s "$LIB" "$fake/lib/emit_budget.sh"       # sed 空振り（vacuous mutation）を弾く
    run bash -n "$fake/lib/emit_budget.sh"
    [ "$status" -eq 0 ]

    run --separate-stderr bash -c "printf '%s' '$ANCHOR_JSON' | timeout 6 env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX \
        PATH='$slowbin:$PATH' CLAUDE_PLUGIN_ROOT='$REPO' bash '$fake/session-start-role-inject.sh'"
    [ "$status" -ne 0 ]                              # 124 = wire が kill する状況の再現
    [ -z "$output" ]                                 # ★注入が丸ごと消える＝現行 guard が塞いでいる穴
}

#!/usr/bin/env bats
# cld-spawn-tmux-guard.bats - TMUX guard の server 生存 probe 化 + session 誤配防止（sc-9nc7）
#
# 何を守るか:
#   [probe:] 旧 guard `[[ -z "${TMUX:-}" ]]`（＝「$TMUX が非空か」）を tmux server の生存 probe へ
#     置き換えた。$TMUX 非空は liveness の証拠でも「今この pane が tmux 内にある」証拠でもなく、
#     双方向に誤る（世代交代で TMUX が unset の端末から spawn 全滅／stale だが非空の TMUX は素通り）。
#     probe は `list-windows -a`（read-only・server を生成しない）で、非 0 なら exit 非 0 + stderr。
#     ただし **--help は probe より前**（scribe-spawn.sh が毎 spawn で `cld-spawn --help` を叩いて
#     --effort 透過を feature-detect するため。probe を前に置くと effort が silent 降格する）。
#
#   [pane:] session 解決から bare display-message（-t 無し）を廃した。bare は client 指定が無いと
#     tmux が「直近 activity のある session」を選び、**rc=0 のまま現在窓と無関係な session を返す**
#     （実測 4 回で毎回別 session＝非決定）。TMUX_PANE を -t に与え pane_id のエコーが一致した
#     ときだけ session_name を採り、確定できなければ --session 必須で fail-loud する。
#     --session 必須化は **この場合だけ**（既存呼出は --session を 1 つも渡しておらず、--session は
#     --inject-existing と併用禁止＝無条件必須化は既存経路を全滅させる）。
#
# スタブ方針は cld-spawn-session.bats と同型（tmux/mktemp/flock/session-name.sh/session-comm.sh）。
# tmux stub は「-t <pane> のときだけ pane_id を第 1 フィールドへエコーする」実 tmux の
# '#{pane_id} #{session_name}' format を再現し、PANE_ECHO_STUB でエコー値を差し替えて
# **不一致（negative）経路**を非空虚に踏む。probe の rc は PROBE_RC で制御する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_SPAWN="$SCRIPT_DIR/cld-spawn"

setup() {
    SANDBOX="$(mktemp -d)"
    export LAUNCHER_PATH="$SANDBOX/launcher.sh"
    export FAKE_BIN="$SANDBOX/bin"
    export TMUX_LOG="$SANDBOX/tmux.log"
    : > "$TMUX_LOG"
    mkdir -p "$FAKE_BIN"

    # --- tmux stub ---
    #   list-windows -a -F '#{window_id}' … server 生存 probe（PROBE_RC で rc を制御）
    #   list-windows（それ以外）        … window 名の列挙
    #   display-message                 … -t <pane> のときだけ "<pane_id> <session>" をエコー
    #   has-session                     … EXISTING_SESSIONS との完全一致
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
echo "tmux $*" >> "$TMUX_LOG"
case "${1:-}" in
    list-windows)
        # probe 形（-a かつ -F '#{window_id}'）だけを PROBE_RC で落とす。window 名の列挙に
        # 使われる list-windows は従来どおり成功させる（probe だけを非 0 にする分離）。
        if [[ "$*" == *"-a"* && "$*" == *"#{window_id}"* ]]; then
            exit "${PROBE_RC:-0}"
        fi
        echo "${WINDOW_NAME_STUB:-cld-spawn-test}"
        ;;
    display-message)
        _tgt=""; _prev=""
        for _a in "$@"; do [[ "$_prev" == "-t" ]] && _tgt="$_a"; _prev="$_a"; done
        # -t 無し（bare）では **何も返さない**: 実装が bare 解決を廃したことを非空虚に pin する
        # （bare を残した実装はここで空を掴み、旧コードなら「解決できませんでした」で落ちる）。
        # ':-' でなく '-' 既定にするのは、CURRENT_SESSION_STUB="" で「区切りだけの非空出力」
        # （実測: 不在 pane への複数フィールド display-message が返す形）を作れるようにするため。
        [[ -n "$_tgt" ]] && echo "${PANE_ECHO_STUB-$_tgt} ${CURRENT_SESSION_STUB-cursess}"
        ;;
    has-session)
        tgt=""; prev=""
        for a in "$@"; do
            [[ "$prev" == "-t" ]] && tgt="${a#=}"
            prev="$a"
        done
        for s in ${EXISTING_SESSIONS:-}; do
            [[ "$s" == "$tgt" ]] && exit 0
        done
        exit 1
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub: LAUNCHER パスを固定 / prompt ファイルは SANDBOX へ（worker cell の /tmp は read-only）---
    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-spawn-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"
    echo "${LAUNCHER_PATH}"
elif [[ "\$*" == *"cld-spawn-prompt-XXXXXX.txt"* ]]; then
    /usr/bin/mktemp "${SANDBOX}/cld-spawn-prompt-XXXXXX.txt"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    # --- flock stub ---
    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/flock"
    chmod +x "$FAKE_BIN/flock"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS/lib"

    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-spawn-test"; }
find_existing_window()  { echo "FEW:$*" >> "$TMUX_LOG"; echo "${FEW_RESULT:-}"; }
SESSION_STUB

    touch "$STUB_SCRIPTS/window-manifest.sh"
    cp "$SCRIPT_DIR/lib/session-env.sh" "$STUB_SCRIPTS/lib/session-env.sh"

    cat > "$STUB_SCRIPTS/session-comm.sh" <<'COMM_STUB'
#!/bin/bash
echo "COMM:$*" >> "$TMUX_LOG"
exit 0
COMM_STUB
    chmod +x "$STUB_SCRIPTS/session-comm.sh"

    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/cld-stub"
    chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    cp "$CLD_SPAWN" "$STUB_SCRIPTS/cld-spawn"
    chmod +x "$STUB_SCRIPTS/cld-spawn"

    export HOME="$SANDBOX/home"
    mkdir -p "$HOME/.local/state/claude-session"
    export PATH="$FAKE_BIN:$PATH"

    # 既定は「TMUX は unset（層1 後の世界）・pane は実在」= server 生存 probe が通り、pane エコーで
    # session が確定する状態。旧 guard ならこの既定で全 spawn が死ぬ。
    unset TMUX PANE_ECHO_STUB PROBE_RC FEW_RESULT CURRENT_SESSION_STUB 2>/dev/null || true
    export TMUX_PANE="%42"
    export EXISTING_SESSIONS="cursess"
    export FEW_RESULT=""
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    return 0
}

_run_spawn() {
    run bash "$STUB_SCRIPTS/cld-spawn" "$@"
}

# ---------- probe: server 生存 probe ----------

@test "probe: server 不在（probe が非 0）なら exit 非 0 + stderr で die する" {
    export PROBE_RC=1
    _run_spawn
    [ "$status" -ne 0 ]
    [[ "$output" == *"tmux server に接続できません"* ]]
    # 死ぬのは probe の直後＝window を 1 つも作らない（誤 spawn ゼロ）。
    ! grep -q "tmux new-window" "$TMUX_LOG"
    ! grep -q "tmux new-session" "$TMUX_LOG"
}

@test "probe: server 不在でも --help は exit 0 で usage を出す（--effort feature-detect を殺さない）" {
    # scripts/scribe-spawn.sh は毎 spawn で `cld-spawn --help` を grep して --effort 透過を
    # feature-detect する。probe を help 判定より前に置くと effort が silent に降格する。
    export PROBE_RC=1
    run bash "$STUB_SCRIPTS/cld-spawn" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--effort"* ]]
    [[ "$output" == *"Usage:"* ]]
}

@test "probe: TMUX unset でも server が生きていれば spawn は通る（旧 \$TMUX 非空 guard の撤廃）" {
    # setup は TMUX を unset にしてある（層1＝daemon 世代交代後の世界の再現）。
    [ -z "${TMUX:-}" ]
    _run_spawn
    [ "$status" -eq 0 ]
    [[ "$output" == *"spawned → tmux window 'cld-spawn-test' (session: cursess)"* ]]
    # 旧 guard の文言は二度と出てはならない（実装からも 0 hit）。
    [[ "$output" != *"tmux内で実行してください"* ]]
    ! grep -q 'tmux内で実行してください' "$STUB_SCRIPTS/cld-spawn"
}

@test "probe: probe は server を生成しない（start-server / new-session を発行しない read-only 判定）" {
    # start-server / new-session を probe に使うと「probe が probe 対象を作る」構造的 fail-open に
    # なる。server 不在で die するまでに tmux へ出したのは read-only 判定だけであることを pin する。
    export PROBE_RC=1
    _run_spawn
    [ "$status" -ne 0 ]
    ! grep -q "tmux start-server" "$TMUX_LOG"
    ! grep -q "tmux new-session" "$TMUX_LOG"
    grep -q "tmux list-windows -a -F #{window_id}" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

# ---------- pane: session 誤配防止（pane_id エコー一致） ----------

@test "pane: TMUX_PANE が実在（エコー一致）なら -t \"\$TMUX_PANE\" で session を解決する" {
    export CURRENT_SESSION_STUB="realsess"
    export EXISTING_SESSIONS="realsess"
    _run_spawn
    [ "$status" -eq 0 ]
    grep -q "tmux display-message -p -t %42 #{pane_id} #{session_name}" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
    [[ "$output" == *"(session: realsess)"* ]]
    grep -q "FEW:cld-spawn-test realsess" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

@test "pane: session 解決に bare display-message（-t 無し）を使わない" {
    # bare は rc=0 のまま無関係 session を返す（非決定）。実装が bare を 1 度でも撃っていれば
    # log に -t を持たない display-message 行が残る。
    _run_spawn
    [ "$status" -eq 0 ]
    run grep '^tmux display-message' "$TMUX_LOG"
    [ "$status" -eq 0 ]                                  # display-message は撃っている（空虚でない）
    ! grep '^tmux display-message' "$TMUX_LOG" | grep -qv -- '-t '
}

@test "pane: TMUX_PANE 未設定なら --session 無し spawn は fail-loud（適当な session へ縮退しない）" {
    unset TMUX_PANE
    _run_spawn
    [ "$status" -ne 0 ]
    [[ "$output" == *"積極証拠で解決できませんでした"* ]]
    [[ "$output" == *"--session"* ]]
    ! grep -q "tmux new-window" "$TMUX_LOG"
    ! grep -q "tmux new-session" "$TMUX_LOG"
}

@test "pane: TMUX_PANE がエコー不一致（stale な pane）なら --session 無し spawn は fail-loud" {
    # 実測: 不在 pane への display-message は rc=0 + 空、複数フィールド format なら rc=0 + 区切りのみ。
    # ゆえに rc でも出力の非空でも判定できず、pane_id のエコー一致だけが積極証拠になる。
    export PANE_ECHO_STUB="%99"
    _run_spawn
    [ "$status" -ne 0 ]
    [[ "$output" == *"積極証拠で解決できませんでした"* ]]
    [[ "$output" == *"%42"* ]]                           # 診断に実値を出す（silent に落ちない）
    ! grep -q "tmux new-window" "$TMUX_LOG"
}

@test "pane: エコーが区切りのみ（session フィールドが空）でも fail-loud する" {
    export CURRENT_SESSION_STUB=""
    _run_spawn
    [ "$status" -ne 0 ]
    [[ "$output" == *"積極証拠で解決できませんでした"* ]]
}

@test "pane: 確定不能でも --session 明示なら通る（--session 必須化は積極証拠不能時のみ）" {
    unset TMUX_PANE
    export EXISTING_SESSIONS="proj"
    _run_spawn --session proj
    [ "$status" -eq 0 ]
    [[ "$output" == *"(session: proj)"* ]]
    grep -q "tmux new-window -t =proj: -n cld-spawn-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

# ---------- pane: --inject-existing の回帰 pin（無条件 --session 必須化の封鎖） ----------
# --inject-existing は session 解決へ到達せず exit し、かつ --session と併用禁止。ゆえに
# 「確定不能なら --session 必須」を前方（TMUX guard 直後や inject 分岐より前）へ移すと、
# inject 経路は復旧手段ゼロで全滅する。以下 2 本がその移動を機械的に禁止する。

@test "pane: TMUX_PANE 未設定でも --inject-existing は従来どおり成功する（引数変更なし）" {
    unset TMUX_PANE
    export WINDOW_NAME_STUB="target-win"
    _run_spawn --inject-existing target-win -- "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompt injected → 'target-win' (existing)"* ]]
    grep -q "COMM:inject-file target-win" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

@test "pane: TMUX_PANE がエコー不一致でも --inject-existing は従来どおり成功する（引数変更なし）" {
    export PANE_ECHO_STUB="%99"
    export WINDOW_NAME_STUB="target-win"
    _run_spawn --inject-existing target-win -- "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"prompt injected → 'target-win' (existing)"* ]]
}

#!/usr/bin/env bats
# cld-fork-guard.bats - cld-fork の TMUX guard を server 生存 probe 化（sc-4aj7 / leg(a)=sc-9nc7 の同型）
#
# 何を守るか:
#   cld-fork 冒頭にあった旧 guard `[[ -z "${TMUX:-}" ]]`（＝「$TMUX が非空か」）を、cld-spawn と
#   同判定の server 生存 probe（`tmux list-windows -a -F '#{window_id}'` の rc）へ置き換えた。
#   片方（cld-spawn）だけを直すと、$TMUX が unset で渡る世界（層1＝daemon 世代交代後）で
#   spawn は通るのに fork だけが死ぬ。ここはその非対称を機械的に禁止する。
#   判定 semantics の rationale SSOT は cld-spawn の `_tmux_server_alive` comment（cld-fork 側は
#   pointer のみ＝長文の二重化を禁じる drift pin を下の "drift:" ケースが持つ）。
#
# スタブ方針は cld-spawn-tmux-guard.bats と同型（tmux/mktemp/session-name.sh）。probe の rc は
# PROBE_RC で制御し、window 名を列挙する側の list-windows（＝生成確認）は常に成功させて
# **probe だけを分離して落とす**。/tmp は worker cell で read-only なため mktemp も stub する。

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"
CLD_FORK="$SCRIPT_DIR/cld-fork"
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
    #   list-windows（それ以外）          … 作成後の window 名の列挙（生成確認）
    cat > "$FAKE_BIN/tmux" <<'TMUX_STUB'
#!/bin/bash
echo "tmux $*" >> "$TMUX_LOG"
case "${1:-}" in
    list-windows)
        if [[ "$*" == *"-a"* && "$*" == *"#{window_id}"* ]]; then
            exit "${PROBE_RC:-0}"
        fi
        echo "${WINDOW_NAME_STUB:-cld-fork-test}"
        ;;
esac
exit 0
TMUX_STUB
    chmod +x "$FAKE_BIN/tmux"

    # --- mktemp stub: LAUNCHER を SANDBOX へ固定（worker cell の /tmp は read-only）---
    cat > "$FAKE_BIN/mktemp" <<MKTEMP_STUB
#!/bin/bash
if [[ "\$*" == *"cld-fork-XXXXXX.sh"* ]]; then
    touch "${LAUNCHER_PATH}"
    echo "${LAUNCHER_PATH}"
else
    /usr/bin/mktemp "\$@"
fi
MKTEMP_STUB
    chmod +x "$FAKE_BIN/mktemp"

    export STUB_SCRIPTS="$SANDBOX/scripts"
    mkdir -p "$STUB_SCRIPTS"

    cat > "$STUB_SCRIPTS/session-name.sh" <<'SESSION_STUB'
generate_window_name() { echo "cld-fork-test"; }
SESSION_STUB

    # window-manifest.sh は空 stub＝manifest_append_entry 未定義で manifest ブロックは skip
    touch "$STUB_SCRIPTS/window-manifest.sh"

    printf '#!/bin/bash\nexit 0\n' > "$FAKE_BIN/cld-stub"
    chmod +x "$FAKE_BIN/cld-stub"
    export CLD_PATH="$FAKE_BIN/cld-stub"

    cp "$CLD_FORK" "$STUB_SCRIPTS/cld-fork"
    chmod +x "$STUB_SCRIPTS/cld-fork"

    export HOME="$SANDBOX/home"
    mkdir -p "$HOME"
    export PATH="$FAKE_BIN:$PATH"

    # 既定は「TMUX は unset（層1 後の世界）・server は生存」。旧 guard ならこの既定で fork が死ぬ。
    unset TMUX PROBE_RC WINDOW_NAME_STUB 2>/dev/null || true
}

teardown() {
    [[ -n "$SANDBOX" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
    return 0
}

_run_fork() {
    run bash "$STUB_SCRIPTS/cld-fork" "$@"
}

# _refute_fixed <pattern> <file>
#   「無いこと」の assert を **関数の非 0 return** で表す。`! grep …` と書いてはならない:
#   bash の set -e は「`!` で戻り値を反転したコマンド」を明示的に除外するため、bats の test 本体で
#   非最終行に置いた `! grep` は **落ちても test を落とさない**（本 cell で bats 1.13.0 実測: 非最終の
#   `! true` は ok / 非最終の `false` は not ok）。空虚な negative assert を構造的に防ぐ。
_refute_fixed() {
    if grep -Fq -e "$1" -- "$2"; then
        echo "unexpected hit: [$1] in $2" >&2
        if [[ "$2" == "${TMUX_LOG:-}" ]]; then echo "log: $(cat "$TMUX_LOG")" >&2; fi
        return 1
    fi
    return 0
}

_refute_in_log() {
    _refute_fixed "$1" "$TMUX_LOG"
}

# ---------- (a) server 不達なら非 0 exit + server 不達文言 ----------

@test "guard: server 不達（probe が非 0）なら exit 非 0 + server 不達の文言で die する" {
    export PROBE_RC=1
    _run_fork
    [ "$status" -ne 0 ]
    [[ "$output" == *"tmux server に接続できません"* ]]
    # 旧文言（「tmux内で実行してください」）は新判定と意味論が不一致＝出てはならない。
    [[ "$output" != *"tmux内で実行してください"* ]]
    # 死ぬのは probe の直後＝window を 1 つも作らない。
    _refute_in_log "tmux new-window"
    _refute_in_log "tmux new-session"
}

@test "guard: probe は server を生成しない（start-server / new-session を発行しない read-only 判定）" {
    # start-server / new-session を probe に使うと「probe が probe 対象を作る」構造的 fail-open。
    export PROBE_RC=1
    _run_fork
    [ "$status" -ne 0 ]
    _refute_in_log "tmux start-server"
    _refute_in_log "tmux new-session"
    grep -q "tmux list-windows -a -F #{window_id}" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

# ---------- (b) TMUX unset かつ server 生存なら guard を通過（旧 guard の偽陰性解消） ----------

@test "guard: TMUX unset でも server が生きていれば fork は通る（旧 \$TMUX 非空 guard の撤廃）" {
    [ -z "${TMUX:-}" ]
    _run_fork
    [ "$status" -eq 0 ]
    [[ "$output" == *"forked → tmux window 'cld-fork-test'"* ]]
    grep -q "tmux new-window -n cld-fork-test" "$TMUX_LOG" \
        || { echo "log: $(cat "$TMUX_LOG")"; false; }
}

@test "guard: TMUX unset + server 生存では probe を撃ってから window を作る（順序 pin）" {
    _run_fork
    [ "$status" -eq 0 ]
    _probe_line="$(grep -n "tmux list-windows -a -F #{window_id}" "$TMUX_LOG" | head -1 | cut -d: -f1)"
    _new_line="$(grep -n "tmux new-window" "$TMUX_LOG" | head -1 | cut -d: -f1)"
    [ -n "$_probe_line" ]
    [ -n "$_new_line" ]
    [ "$_probe_line" -lt "$_new_line" ]
}

# ---------- (c) 旧 guard 形の残存 0 / 実装共有形（同一 literal）の pin ----------

@test "guard: 旧 guard 形と旧文言が実装に 0 hit（cld-fork / cld-spawn の双方）" {
    # cld-fork は「$TMUX 非空」の literal を **comment を含め 1 hit も持たない**（bead の検証行が
    # ファイル全体の grep で判定するため。rationale は SSOT 側の cld-spawn comment にだけ在る）。
    _refute_fixed '-z "${TMUX:-}"' "$CLD_FORK"
    _refute_fixed 'tmux内で実行してください' "$CLD_FORK"
    # 片方だけ直した状態（＝本 issue が塞ぐ非対称）を禁止する。cld-spawn は rationale comment 中で
    # 旧形を引用するため、**実行される guard 行**だけを refute する（comment の引用は許す）。
    _refute_fixed 'if [[ -z "${TMUX:-}" ]]; then' "$CLD_SPAWN"
    _refute_fixed 'if [[ -z "${TMUX:-}" ]]; then' "$CLD_FORK"
    _refute_fixed 'tmux内で実行してください' "$CLD_SPAWN"
}

@test "drift: probe 本体は cld-spawn と同一 literal で、長文 rationale は cld-spawn 側にだけ在る" {
    # 実装共有形は (a) 関数複製を採った（理由は bead sc-4aj7 notes）。複製ゆえ本体 literal の
    # 一致と「rationale は SSOT 側にだけ置く」ことを機械で pin する。
    _probe_literal="    tmux list-windows -a -F '#{window_id}' >/dev/null 2>&1"
    grep -Fqx -e "$_probe_literal" -- "$CLD_FORK"
    grep -Fqx -e "$_probe_literal" -- "$CLD_SPAWN"
    # rationale SSOT は cld-spawn 側の comment。cld-fork は pointer に留める（二重化＝drift 源）。
    grep -Fq -e 'probe に list-windows を選んだ理由' -- "$CLD_SPAWN"
    _refute_fixed 'probe に list-windows を選んだ理由' "$CLD_FORK"
    # pointer が実在すること（rationale の在処を失わない）。
    grep -Fq -e 'cld-spawn' -- "$CLD_FORK"
}

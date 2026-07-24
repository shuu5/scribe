#!/usr/bin/env bats
# tests/scenarios/orch-dispatch.bats
#
# orch-dispatch.sh（orch-69w / orch-0w7 実装3）の決定的テスト。
#
# 方式: scribe-spawn / bd を env/PATH スタブで差し替え、実 script を実行して assert する hermetic E2E。
#   - scribe-spawn: env ORCH_DISPATCH_SPAWN でスタブへ差替（argv を `SPAWN-ARGS:` 行で echo・実 spawn しない）。
#   - bd: PATH スタブで差替（argv を $BD_ARGS_FILE に記録 + `list` で $BD_LIST_JSON を出力）。
#   - 既定 anchor/repo は env ORCH_DISPATCH_SCRIPTORIUM で固定（$HOME 非依存・決定的）。
#
# 検証する契約不変条件（bd orch-69w description = ratify 済契約）:
#   (1) spawn: orchestrator 既定（--anchor/--repo=scriptorium・--base HEAD・--model opus）で scribe-spawn を呼ぶ。
#   (1b) spawn: --dry-run を scribe-spawn へ forward（実 spawn しない）。非 dry-run は --dry-run を付けない。
#   (1c) spawn: --model/--repo/--anchor/--base の override が forward される。fable は die。
#   (1f) spawn 入口 fail-closed gate（orch-vji・orch-c8p B / grill G1+G2+G7 入口）:
#        契約 bead を `bd -C <anchor> show` で read（実在検証も兼ねる・read 不能=fail-closed 中止）。
#        (G1)acceptance 欠落 / (G7)verification 欄欠落（`verification:`/`検証:` の非空 value or `機械 probe 不能` 明示宣言）
#        を非0+loud で拒否し scribe-spawn を呼ばない。(G2)acceptance snapshot（sentinel + JSON-decoded acceptance の
#        UTF-8 sha256 + verbatim）を bdw 経由で自台帳 notes へ append（foreign は skip=write-isolation・dry-run は write skip）。
#        snapshot/bdw 失敗も fail-closed。正常 bead は snapshot 記録 AND 従来どおり scribe-spawn へ forward（回帰なし）。
#   (2) gate-pending: `bd list --label gate-pending --status open` を組む（★単数 --label・--labels を使わない）。
#       結果を id+title で整形、空なら「なし」。bd 台帳へ write しない（list の read のみ）。
#   (3) watch worker（既定・後方互換）: 指定 bead が gate-pending 出現で exit 0 / timeout で非 0（exit 3）。
#   (3b) watch admin（orch-5pn）: foreign bead status 到達 ① OR pane idle ② で完了（success mode）。
#        window 消失は非致命（foreign status 継続）。--resync は injectable コマンドへ委譲。
#   (3c) watch generic（orch-5pn）: pane idle のみで完了。window 消失=exit 4（actor 終了・surface）。
#   (4) モード排他・未知オプション・未知 --actor・--help・dry-run の no-side-effect。
#
# 追加スタブ（orch-5pn）:
#   - bd show <id> --json: $BD_SHOW_JSON を返す（admin の foreign status read 用）。
#   - tmux（ORCH_DISPATCH_TMUX）: capture-pane -p -t <win> で $TMUX_PANE_FILE/<win> の内容を出力（read-only）。
#     ファイル不在＝window 消失（非0 終了）。idle は同一内容を返し続けることで再現。
#   - resync（ORCH_DISPATCH_RESYNC_CMD）: 呼ばれたら $RESYNC_MARKER を touch するだけ（委譲先の発火を観測）。
#   - bdw（ORCH_DISPATCH_BDW・orch-vji）: spawn 入口 gate の G2 snapshot write の委譲先。argv + cwd を $BDW_ARGS_FILE へ
#     記録するだけ（BDW_FAIL=1 で非0＝記録失敗注入）。BD_SHOW_JSON 未指定 test は既定 VALID_BEAD_JSON（正常 bead）で回帰不変。
#
# 実行: bats tests/scenarios/orch-dispatch.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-dispatch.sh"
    TEST_TMPDIR=$(mktemp -d -t orch-dispatch-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    # 既定 anchor/repo（$HOME 非依存の決定的値）。
    export TANCHOR="$TEST_TMPDIR/scriptorium"
    export TREPO_OTHER="$TEST_TMPDIR/other-project"
    # orch-vji: spawn 入口 gate の snapshot write は cwd=ANCHOR の subshell で bdw を叩く（bd 台帳解決を anchor に固定）。
    #   anchor dir が無いと cd が失敗し snapshot が空 commit 誤検出に化けるため、両 anchor を実在させる（hermetic）。
    mkdir -p "$TANCHOR" "$TREPO_OTHER"

    # bd の argv 記録先。
    export BD_ARGS_FILE="$TEST_TMPDIR/bd-args.txt"
    : > "$BD_ARGS_FILE"

    # orch-vji: spawn 入口 gate（G1/G7/G2）の契約 bead フィクスチャ。既定は「正常 bead」（acceptance あり +
    #   verification 欄あり）＝既存 spawn 回帰 test が新 gate を無改変で通る（BD_SHOW_JSON を明示 export した test は上書き）。
    #   G1/G7 の欠落・G2 snapshot 照合は個別 test が BD_SHOW_JSON を上書きして検証する。
    export VALID_BEAD_JSON='[{"id":"orch-test","acceptance_criteria":"(1) foo が動く (2) bar が動く","description":"検証方針。\nverification: bash selftest-orch-vji.local.sh"}]'
    # bdw stub（orch-vji・G2 snapshot write の委譲先）: argv + cwd を記録するだけ（BDW_FAIL=1 で非0＝記録失敗注入）。
    export BDW_ARGS_FILE="$TEST_TMPDIR/bdw-args.txt"
    : > "$BDW_ARGS_FILE"
    cat > "$BIN/bdw-stub" <<'STUB'
#!/usr/bin/env bash
{ printf 'BDW-ARGS: %s\n' "$*"; printf 'BDW-CWD: %s\n' "$PWD"; } >> "$BDW_ARGS_FILE"
[ -n "${BDW_FAIL:-}" ] && exit 1
exit 0
STUB

    # orch-edv T2: bd show 呼び出し回数カウンタ（baseline 遷移サポート・test ごとに fresh dir ゆえ初回は不在=0）。
    export BD_SHOW_COUNT_FILE="$TEST_TMPDIR/bd-show-count"
    # orch-y9z: bd list 呼び出し回数カウンタ（worker baseline の new-arrival 遷移サポート・BD_SHOW_COUNT_FILE と同型）。
    export BD_LIST_COUNT_FILE="$TEST_TMPDIR/bd-list-count"

    # foreign 鮮度ソース（orch-6rb）。主指標 = sync 専用マーカー .beads/last-sync。既定は fresh（now）な
    # マーカーを用意し、既存テストが鮮度 unknown/stale で⚠ ノイズを混ぜないようにする。補助表示用に
    # export-state.json も fresh で置く。鮮度テストは個別に mtime/不在を作って上書きする。
    export SYNC_MARKER_DEFAULT="$TEST_TMPDIR/last-sync"
    printf '%s\n' '2026-06-26T00:00:00+09:00' > "$SYNC_MARKER_DEFAULT"
    touch "$SYNC_MARKER_DEFAULT"   # mtime=now ⇒ fresh
    export EXPORT_STATE_DEFAULT="$TEST_TMPDIR/export-state.json"
    printf '%s' '{"last_dolt_commit":"abc","timestamp":"2026-06-26T00:00:00+09:00","issues":1}' > "$EXPORT_STATE_DEFAULT"
    touch "$EXPORT_STATE_DEFAULT"   # mtime=now ⇒ fresh（補助表示用）

    # ── stub: scribe-spawn（argv を echo するだけ・実 spawn しない）──
    cat > "$BIN/scribe-spawn-stub" <<'STUB'
#!/usr/bin/env bash
echo "SPAWN-ARGS: $*"
exit 0
STUB

    # ── stub: bd（argv 記録 + list で $BD_LIST_JSON を出力）。BD_FAIL=1 で非 0 終了＝障害注入。
    #    BD_RAW=1 で BD_LIST_JSON を素通し（非 JSON 注入＝fail-silent test 用）。
    #    それ以外は実 bd の `--status <val>`（カンマ区切り）フィルタを模倣＝指定 status の issue のみ返す
    #    （status 無指定 fixture は open 扱い＝既存 fixture 互換）。これにより orch-dispatch が誤った
    #    --status（例 open のみ）を渡すと in_progress を取りこぼすことを behavioral test が捕捉できる。
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_FILE"
[ -n "${BD_FAIL:-}" ] && exit 1
[ -n "${BD_RAW:-}" ] && { printf '%s' "${BD_LIST_JSON:-[]}"; exit 0; }
# orch-ail 直読 poll: `bd -C <dir> show ...` のグローバル -C/--directory を剥がして subcommand へ dispatch。
# 元の argv（-C 込み）は上で $BD_ARGS_FILE に記録済み＝test は -C/<path> の通過を assert できる。
# orch-edv T3（liveness）: -C 有無（=foreign query か）を _foreign に控える（foreign list を self と出し分ける）。
_foreign=0
while [ "${1:-}" = "-C" ] || [ "${1:-}" = "--directory" ]; do _foreign=1; shift 2; done
_status=""; _prev=""
for _a in "$@"; do [ "$_prev" = "--status" ] && _status="$_a"; _prev="$_a"; done
case "$1" in
  list)
    # orch-edv T3: foreign query（bd -C ...）は BD_LIST_JSON_FOREIGN（set 時）を返す＝self/foreign を出し分けて
    #   liveness の [foreign] タグ surface を hermetic に検証できる。未 set なら self と同じ BD_LIST_JSON。
    _src="${BD_LIST_JSON:-[]}"
    [ "$_foreign" = 1 ] && [ -n "${BD_LIST_JSON_FOREIGN:-}" ] && _src="${BD_LIST_JSON_FOREIGN}"
    # orch-y9z（worker baseline new-arrival 遷移サポート）: BD_LIST_JSON_BASELINE が set なら **初回 list 呼び出し**
    #   はそれを返し、2 回目以降は BD_LIST_JSON を返す（poll1=武装時=未 gate-pending / poll2 以降=gate-pending 出現）。
    #   呼び出し回数は BD_LIST_COUNT_FILE で数える。未 set なら常に BD_LIST_JSON（既存 test は不変）。BD_SHOW_JSON_BASELINE と同型。
    if [ -n "${BD_LIST_JSON_BASELINE:-}" ] && [ -n "${BD_LIST_COUNT_FILE:-}" ]; then
      _ln=$(cat "$BD_LIST_COUNT_FILE" 2>/dev/null || echo 0)
      _ln=$((_ln + 1)); printf '%s' "$_ln" > "$BD_LIST_COUNT_FILE"
      [ "$_ln" -eq 1 ] && _src="${BD_LIST_JSON_BASELINE}"
    fi
    if [ -n "$_status" ]; then
      ORCH_STUB_STATUS="$_status" python3 - "$_src" <<'PY'
import json, os, sys
allowed = set(os.environ.get("ORCH_STUB_STATUS", "").split(","))
try:
    data = json.loads(sys.argv[1])
except Exception:
    print("[]"); sys.exit(0)
if not isinstance(data, list):
    print("[]"); sys.exit(0)
out = [it for it in data if (not isinstance(it, dict)) or it.get("status", "open") in allowed]
print(json.dumps(out))
PY
    else
      printf '%s' "$_src"
    fi
    ;;
  show)
    # orch-edv T3（liveness section ③・per-id）: BD_SHOW_DIR set 時、show <id> は $BD_SHOW_DIR/<id> を返す
    #   （ファイル不在=rc1=not-found＝宣言 bead 不在の再現）。複数 wt-<id> window を別 status で検証できる。
    if [ -n "${BD_SHOW_DIR:-}" ]; then
      _sid="${2:-}"
      # orch-qof gap-A teeth: BD_SHOW_FAIL_ON_COUNT set 時、show <id> 呼出を数え該当回で rc1 を注入する。
      #   liveness ③ は cell 毎に show を 2 回叩く（call1=_liveness_self_status の status read / call2=
      #   _spawned_marker_present の marker read）。=2 を渡すと『2 回目 bd read のみ失敗』＝marker read だけが
      #   落ち _spawned_marker_present rc=2「判定不能」枝を pin できる。既定 unset＝既存 test は byte 不変。
      if [ -n "${BD_SHOW_FAIL_ON_COUNT:-}" ] && [ -n "${BD_SHOW_COUNT_FILE:-}" ]; then
        _fc=$(cat "$BD_SHOW_COUNT_FILE" 2>/dev/null || echo 0); _fc=$((_fc + 1)); printf '%s' "$_fc" > "$BD_SHOW_COUNT_FILE"
        [ "$_fc" = "$BD_SHOW_FAIL_ON_COUNT" ] && exit 1
      fi
      # orch-qof gap-A' teeth: BD_SHOW_BADJSON_ON_COUNT set 時、該当回の show は壊れ JSON を exit 0 で返す。
      #   bd show は成功（rc=0）だが _NOTES_PY が parse 失敗→sys.exit(2) へ落ち、_spawned_marker_present の
      #   rc=2「判定不能」の第2 modality（bd-read 成功 × notes parse 失敗）を pin する。=2 で marker read だけを壊す。
      if [ -n "${BD_SHOW_BADJSON_ON_COUNT:-}" ] && [ -n "${BD_SHOW_COUNT_FILE:-}" ]; then
        _bc=$(cat "$BD_SHOW_COUNT_FILE" 2>/dev/null || echo 0); _bc=$((_bc + 1)); printf '%s' "$_bc" > "$BD_SHOW_COUNT_FILE"
        [ "$_bc" = "$BD_SHOW_BADJSON_ON_COUNT" ] && { printf '%s' '{壊れ JSON: not parseable'; exit 0; }
      fi
      _sf="$BD_SHOW_DIR/$_sid"
      [ -f "$_sf" ] || exit 1
      cat "$_sf"; exit 0
    fi
    # orch-5pn: admin watch の foreign status read。BD_SHOW_RAW=1 で非 JSON 注入（parse 失敗 test 用）。
    # 既定は空オブジェクト。${VAR:-{}} はブレース対応で末尾 } が漏れるため一旦変数へ束縛してから出す。
    # orch-edv T2（baseline 遷移サポート）: BD_SHOW_JSON_BASELINE が set なら **初回 show 呼び出し** はそれを返し、
    #   2 回目以降は BD_SHOW_JSON を返す（poll1=baseline / poll2 以降=遷移後）。呼び出し回数は BD_SHOW_COUNT_FILE で数える。
    #   未 set なら常に BD_SHOW_JSON（既存 test は不変）。これで「baseline から done-set へ変化」を hermetic に再現する。
    _n=0
    if [ -n "${BD_SHOW_COUNT_FILE:-}" ]; then
      _n=$(cat "$BD_SHOW_COUNT_FILE" 2>/dev/null || echo 0)
      _n=$((_n + 1)); printf '%s' "$_n" > "$BD_SHOW_COUNT_FILE"
    fi
    _show="${BD_SHOW_JSON:-}"
    if [ "$_n" -eq 1 ] && [ -n "${BD_SHOW_JSON_BASELINE:-}" ]; then _show="${BD_SHOW_JSON_BASELINE}"; fi
    [ -z "$_show" ] && _show='{}'
    [ -n "${BD_SHOW_RAW:-}" ] && { printf '%s' "$_show"; exit 0; }
    printf '%s' "$_show"
    ;;
esac
exit 0
STUB

    # ── stub: tmux（orch-5pn・read-only capture-pane）。`capture-pane -p -t <win>` で
    #    $TMUX_PANE_DIR/<win> の内容を stdout へ。ファイル不在＝window 消失（非0 終了）。
    #    同一ファイル内容を返し続けることで pane idle（連続無変化）を hermetic に再現。
    export TMUX_PANE_DIR="$TEST_TMPDIR/panes"
    mkdir -p "$TMUX_PANE_DIR"
    # orch-edv T3（liveness）: window 列挙用フィクスチャ（1 行 1 window_name）。既定は不在＝window なし。
    export TMUX_WINDOWS_FILE="$TEST_TMPDIR/tmux-windows.txt"
    cat > "$BIN/tmux-stub" <<'STUB'
#!/usr/bin/env bash
# 期待形: tmux capture-pane -p -t <win>  /  tmux list-panes -a -F '#{window_name}'（liveness）
case "$1" in
  list-panes)
    # -a 列挙: $TMUX_WINDOWS_FILE の各行を **format 尊重**で返す（orch-riz1 topology）。実 script は
    #   `-F '#{session_name}:#{window_name}'` で叩く。session_name を含む format なら session:window 形、
    #   そうでなければ window_name のみ（＝format を `#{window_name}` へ戻す mutation で session 修飾が失われ
    #   素 admin 窓が曖昧化し teeth が RED になる非vacuity）。フィクスチャ行は session:window 形（colon 無しは
    #   bare window として TMUX_DEFAULT_SESSION〔既定 orch〕を合成＝既存 bare フィクスチャの後方互換）。
    fmt=""; prevf=""
    for a in "$@"; do [ "$prevf" = "-F" ] && fmt="$a"; prevf="$a"; done
    if [ -f "${TMUX_WINDOWS_FILE:-/nonexistent}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
          *:*) sess="${line%%:*}"; win="${line#*:}" ;;
          *)   sess="${TMUX_DEFAULT_SESSION:-orch}"; win="$line" ;;
        esac
        case "$fmt" in
          *session_name*) printf '%s:%s\n' "$sess" "$win" ;;
          *)              printf '%s\n' "$win" ;;
        esac
      done < "$TMUX_WINDOWS_FILE"
    fi
    exit 0
    ;;
  capture-pane)
    win=""; prev=""
    for a in "$@"; do [ "$prev" = "-t" ] && win="$a"; prev="$a"; done
    f="$TMUX_PANE_DIR/$win"
    [ -f "$f" ] || exit 1     # window 不在＝消失
    cat "$f"
    exit 0
    ;;
esac
exit 0
STUB

    # ── stub: resync コマンド（orch-5pn）。呼ばれたら $RESYNC_MARKER を touch するだけ（委譲発火を観測）。
    export RESYNC_MARKER="$TEST_TMPDIR/resync-ran"
    cat > "$BIN/resync-stub" <<'STUB'
#!/usr/bin/env bash
: >> "$RESYNC_MARKER"
exit 0
STUB

    # ── stub: pgrep / ps / find（orch-ayj・liveness 第3軸 host-progress probe・read-only）──
    #   pgrep -f <pat>: HOSTPROG_PIDS（改行区切り PID・既定 unset＝マッチなし=rc1）を返す。
    #   ps -o pid=,etimes= -p <csv>: HOSTPROG_PS_FILE（"pid etimes" 行）を返す（不在=空＝年齢判定不能）。
    #   find <path> -newermt <ref> -type f -print -quit: HOSTPROG_RECENT_WRITE set 時のみ疑似ファイル名を出す
    #     （＝recent write あり＝正常 build）。argv は HOSTPROG_FIND_ARGS へ記録（read-only 検証の teeth 用）。
    export HOSTPROG_PS_FILE="$TEST_TMPDIR/hostprog-ps.txt"
    export HOSTPROG_FIND_ARGS="$TEST_TMPDIR/hostprog-find-args.txt"; : > "$HOSTPROG_FIND_ARGS"
    # host-progress の監視パスを hermetic な実在 dir に固定（既定の containers/storage 等は実 host に存在しうる＝
    #   非決定的ゆえ）。実在すれば find stub が確実に呼ばれ、HOSTPROG_RECENT_WRITE で結果を制御できる。
    export HOSTPROG_WATCH_DIR="$TEST_TMPDIR/hostprog-watch"; mkdir -p "$HOSTPROG_WATCH_DIR"
    cat > "$BIN/pgrep-stub" <<'STUB'
#!/usr/bin/env bash
# HOSTPROG_PGREP_RC set 時はその rc で異常終了を注入（rc=2 で ERE 構文エラーを再現・stdout は空）。
[ -n "${HOSTPROG_PGREP_RC:-}" ] && exit "$HOSTPROG_PGREP_RC"
[ -n "${HOSTPROG_PIDS:-}" ] || exit 1
printf '%s\n' "${HOSTPROG_PIDS}"
exit 0
STUB
    cat > "$BIN/ps-stub" <<'STUB'
#!/usr/bin/env bash
# 期待形: ps -o pid=,etimes= -p <csv>
[ -f "${HOSTPROG_PS_FILE:-/nonexistent}" ] && cat "$HOSTPROG_PS_FILE"
exit 0
STUB
    cat > "$BIN/find-stub" <<'STUB'
#!/usr/bin/env bash
# 期待形: find <path> -newermt <ref> -type f -print -quit（read-only）
printf '%s\n' "$*" >> "${HOSTPROG_FIND_ARGS:-/dev/null}"
[ -n "${HOSTPROG_RECENT_WRITE:-}" ] && printf '%s\n' "$1/recent-file"
exit 0
STUB

    chmod +x "$BIN/scribe-spawn-stub" "$BIN/bd" "$BIN/tmux-stub" "$BIN/resync-stub" "$BIN/bdw-stub" \
             "$BIN/pgrep-stub" "$BIN/ps-stub" "$BIN/find-stub"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# orch-dispatch.sh をスタブ環境で実行（PATH に BIN を前置・scribe-spawn は env seam）。
#   orch-vji: spawn 入口 gate が `bd show` を read するため、BD_SHOW_JSON 未指定 test は既定「正常 bead」
#     （VALID_BEAD_JSON）を与え既存 spawn 回帰を無改変で通す。bdw は stub（ORCH_DISPATCH_BDW）で snapshot write を観測。
#   orch-vswk: slate interlock（run_spawn のみ）を既定 bypass（ORCH_DISPATCH_SKIP_SLATE_GATE=1）＝既存 spawn 回帰を
#     無改変で通す（gate-active な present→pass / absent→fail は orch-slate.bats が実 script で pin）。gate を実 exercise
#     したい test は `ORCH_DISPATCH_SKIP_SLATE_GATE=0 run_dispatch ...` で prepend override する（:- 既定 1 を上書き）。
run_dispatch() {
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
    ORCH_DISPATCH_SCRIPTORIUM="$TANCHOR" \
    ORCH_DISPATCH_SKIP_SLATE_GATE="${ORCH_DISPATCH_SKIP_SLATE_GATE:-1}" \
    ORCH_DISPATCH_BDW="${ORCH_DISPATCH_BDW:-$BIN/bdw-stub}" \
    ORCH_DISPATCH_POLL_INTERVAL=0 \
    ORCH_DISPATCH_SYNC_MARKER="${ORCH_DISPATCH_SYNC_MARKER:-$SYNC_MARKER_DEFAULT}" \
    ORCH_DISPATCH_EXPORT_STATE="${ORCH_DISPATCH_EXPORT_STATE:-$EXPORT_STATE_DEFAULT}" \
    ORCH_DISPATCH_TMUX="${ORCH_DISPATCH_TMUX:-$BIN/tmux-stub}" \
    ORCH_DISPATCH_RESYNC_CMD="${ORCH_DISPATCH_RESYNC_CMD:-$BIN/resync-stub}" \
    ORCH_DISPATCH_EXTERNAL_REGISTRY="${ORCH_DISPATCH_EXTERNAL_REGISTRY:-$TEST_TMPDIR/external-registry}" \
    ORCH_DISPATCH_PGREP="${ORCH_DISPATCH_PGREP:-$BIN/pgrep-stub}" \
    ORCH_DISPATCH_PS="${ORCH_DISPATCH_PS:-$BIN/ps-stub}" \
    ORCH_DISPATCH_FIND="${ORCH_DISPATCH_FIND:-$BIN/find-stub}" \
    ORCH_DISPATCH_HOSTPROG_PATHS="${ORCH_DISPATCH_HOSTPROG_PATHS:-$HOSTPROG_WATCH_DIR}" \
    BD_ARGS_FILE="$BD_ARGS_FILE" \
    BDW_ARGS_FILE="$BDW_ARGS_FILE" \
    BD_LIST_JSON="${BD_LIST_JSON:-[]}" \
    BD_SHOW_JSON="${BD_SHOW_JSON:-$VALID_BEAD_JSON}" \
        run bash "$SCRIPT" "$@"
}

# ==============================================================================
# (1) spawn: orchestrator 既定で scribe-spawn を呼ぶ
# ==============================================================================

@test "spawn: 既定で scribe-spawn を --anchor/--repo=scriptorium --base HEAD --model opus で呼ぶ" {
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]
    [[ "$output" == *"--anchor $TANCHOR"* ]]
    [[ "$output" == *"--repo $TANCHOR"* ]]
    [[ "$output" == *"--base HEAD"* ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" == *"orch-test"* ]]
}

@test "spawn: bd-id 引数が scribe-spawn へ末尾で渡る" {
    run_dispatch orch-abc
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$line" == *"orch-abc"* ]]
}

# ==============================================================================
# (1b) spawn: --dry-run forward / 非 dry-run では付けない
# ==============================================================================

@test "spawn --dry-run: scribe-spawn へ --dry-run を forward（実 spawn しない）" {
    run_dispatch --dry-run orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$line" == *"--dry-run"* ]]
    [[ "$line" == *"orch-test"* ]]
}

@test "spawn（非 dry-run）: scribe-spawn 引数に --dry-run を付けない" {
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$line" != *"--dry-run"* ]]
}

# ==============================================================================
# (1c) spawn: override の forward / fable 拒否
# ==============================================================================

@test "spawn: --model override が forward される" {
    run_dispatch --model sonnet orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"--model sonnet"* ]]
}

@test "spawn: --repo override（foreign worktree host）が forward される（anchor は既定 scriptorium のまま）" {
    run_dispatch --repo "$TREPO_OTHER" orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"--repo $TREPO_OTHER"* ]]
    [[ "$output" == *"--anchor $TANCHOR"* ]]
}

@test "spawn: --anchor / --base override が forward される" {
    run_dispatch --anchor "$TREPO_OTHER" --base origin/main orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"--anchor $TREPO_OTHER"* ]]
    [[ "$output" == *"--base origin/main"* ]]
}

@test "spawn: --model fable 系は die（worker は opus 必須＝コスト事故回避）" {
    run_dispatch --model fable orch-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"fable"* ]]
    # fable die 時は scribe-spawn を呼ばない
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "spawn: bd-id 無しは die" {
    run_dispatch
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

# ==============================================================================
# (1c-account) spawn: account 既定 --account auto / mirror 明示 forward / label 透過（orch-vzmf・orch-r8w9 で mirror 反転）
#   ★teeth: forwarded SPAWN-ARGS 行を grep してから assert（plan >&2 行では assert しない＝空虚 green 防止）。
#     (a) 既定=--account auto 存在 ∧ SPAWN-ARGS 到達 ∧ status 0 ／ (b) mirror=--account mirror 存在 ∧ SPAWN-ARGS 到達 ∧
#     status 0（(a) と必ず対＝単独は vacuous・die を flag 無しと誤認しない・orch-r8w9 で「不付与」から反転）／
#     (c) label=--account <label> 存在 ／ (empty) orch-6eao=空文字列→--account auto（:- 退行 guard）。
# ==============================================================================

@test "spawn account (a): ORCH_DISPATCH_ACCOUNT 未設定で SPAWN-ARGS に --account auto が現れる" {
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')   # forwarded argv のみを見る（plan >&2 行を排除）
    [[ -n "$line" ]]                                                     # SPAWN-ARGS 到達（spawn 実行＝die でない）
    [[ "$line" == *"--account auto"* ]]
}

@test "spawn account (b): ORCH_DISPATCH_ACCOUNT=mirror で SPAWN-ARGS に --account mirror が明示 forward される（orch-r8w9）" {
    ORCH_DISPATCH_ACCOUNT=mirror run_dispatch orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ -n "$line" ]]                                                     # SPAWN-ARGS 到達（(a) と対＝die を flag 無しと誤認しない）
    [[ "$line" == *"--account mirror"* ]]                                # orch-r8w9 反転＝旧「flag 不付与」から明示 forward へ
}

@test "spawn account (empty・orch-6eao): ORCH_DISPATCH_ACCOUNT='' 空文字列で SPAWN-ARGS に --account auto が現れる（:- 退行 guard）" {
    # rider orch-6eao: ${ORCH_DISPATCH_ACCOUNT:-auto} の :-（空も default 化）が保持されている teeth。
    # mutation :-→-（空を default 化しない）にすると本 case は --account '' へ落ちて赤反転する。
    ORCH_DISPATCH_ACCOUNT='' run_dispatch orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ -n "$line" ]]
    [[ "$line" == *"--account auto"* ]]
}

@test "spawn account (c): ORCH_DISPATCH_ACCOUNT=<label> で --account <label> が透過 forward される" {
    ORCH_DISPATCH_ACCOUNT=black3 run_dispatch orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ -n "$line" ]]
    [[ "$line" == *"--account black3"* ]]
}

@test "spawn account plan (acceptance 5): dry-run 情報ブロックの account 行が forward 値を忠実表示する" {
    # 既定（auto）: plan は auto を表示 ∧ 実 argv も --account auto
    run_dispatch --dry-run orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"account : auto"* ]]                               # plan 行（>&2）
    local aline; aline=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$aline" == *"--account auto"* ]]                                # plan と実 argv が乖離しない
    # mirror: plan は「--account mirror を forward」を明示 ∧ 実 argv に --account mirror present（orch-r8w9 反転）
    ORCH_DISPATCH_ACCOUNT=mirror run_dispatch --dry-run orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"account : mirror"* ]]
    [[ "$output" == *"--account mirror を forward"* ]]
    local mline; mline=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$mline" == *"--account mirror"* ]]
}

# ==============================================================================
# (1d) spawn: worker 対話 tool 封鎖は scribe-spawn hardcode が担う＝orch-dispatch は forward しない（orch-ce6 errata）
# ==============================================================================

@test "spawn 封鎖（orch-ce6 errata）: orch-dispatch は --disallowed-tools を scribe-spawn へ forward しない" {
    # worker cell の対話 tool 封鎖は scribe-spawn が hardcode（WORKER_DISALLOWED_TOOLS・orch-4dm 着地形）で
    # cld-spawn 起動行へ無条件付与する。orch-dispatch が --disallowed-tools を渡すと scribe-spawn は未知オプションで
    # die し spawn を壊すため、渡してはならない（初期実装の capability-probe+条件付き forward は dead code だった＝撤去）。
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$line" != *"--disallowed-tools"* ]]                                # forward しない（scribe-spawn hardcode が担う）
    [[ "$output" != *"未対応"* ]]                                          # 虚偽の『orch-4dm 未着地』warn を出さない
    [[ "$output" == *"scribe-spawn hardcode"* ]]                           # block 行は実態（scribe-spawn 担当）を述べる
}

@test "spawn 封鎖（orch-ce6 errata）: --disallowed-tools は orch-dispatch では未知オプションで die（worker に無効ゆえ撤去済）" {
    run_dispatch orch-test --disallowed-tools AskUserQuestion
    [ "$status" -ne 0 ]
    [[ "$output" == *"未知のオプション"* ]]
}

# ==============================================================================
# (1e) spawn 直後 watch 常駐ヒント（orch-ce6・H3-ii）
# ==============================================================================

@test "watch 常駐ヒント（orch-ce6）: self-dev worker は bd-id 既知ゆえ [ORCH-WATCH-RESIDENT] と完全形 watch コマンドを emit" {
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"ORCH-WATCH-RESIDENT"* ]]
    [[ "$output" == *"--watch orch-test"* ]]                               # bd-id 埋め込み済みの完全形
    [[ "$output" == *"run_in_background"* ]]                               # 孤児 fork しない運用注記
}

@test "watch 常駐ヒント（orch-ce6・抑止）: --no-watch-hint で emit しない" {
    run_dispatch --no-watch-hint orch-test
    [ "$status" -eq 0 ]
    [[ "$output" != *"ORCH-WATCH-RESIDENT"* ]]
}

# ==============================================================================
# (1f) spawn 入口 fail-closed gate（orch-vji・orch-c8p B / grill G1+G2+G7 入口・doobidoo f4888921）
#   契約 bead を anchor 台帳から read し (G1)acceptance 欠落 / (G7)verification 欄欠落を fail-closed 拒否、
#   (G2)acceptance snapshot を自台帳 notes へ bdw 経由で機械記録する。read-only check は foreign にも掛け、
#   snapshot write は自台帳（orch-）のみ（write-isolation）。既存の正常 bead dispatch は無影響（回帰なし）。
# ==============================================================================

@test "spawn 入口（read 経路）: 契約 bead を bd -C <anchor> show で read する（実在検証も兼ねる）" {
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    # contract read が anchor 台帳を -C で指す（self/foreign 双方この経路）。
    grep -q -- "-C $TANCHOR show orch-test --json" "$BD_ARGS_FILE"
}

@test "spawn G1（fail-closed）: acceptance 欠落 bead は非0 + loud で拒否・scribe-spawn を呼ばない" {
    export BD_SHOW_JSON='[{"id":"orch-noacc","description":"verification: bash foo"}]'
    run_dispatch orch-noacc
    [ "$status" -ne 0 ]
    [[ "$output" == *"acceptance"* ]]
    [[ "$output" == *"G1"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]                         # dispatch しない
    ! grep -q "ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT" "$BDW_ARGS_FILE"   # snapshot も書かない
}

@test "spawn G1（空白 acceptance）: acceptance_criteria が空白のみでも欠落扱いで拒否" {
    export BD_SHOW_JSON='[{"id":"orch-ws","acceptance_criteria":"   ","description":"verification: x"}]'
    run_dispatch orch-ws
    [ "$status" -ne 0 ]
    [[ "$output" == *"acceptance"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "spawn G7（fail-closed）: verification 欄欠落 bead は非0 で拒否・scribe-spawn を呼ばない" {
    export BD_SHOW_JSON='[{"id":"orch-nover","acceptance_criteria":"(1) foo が動く"}]'
    run_dispatch orch-nover
    [ "$status" -ne 0 ]
    [[ "$output" == *"verification"* ]]
    [[ "$output" == *"G7"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "spawn G7（空 value）: verification: の value が空なら欠落扱いで拒否" {
    export BD_SHOW_JSON='[{"id":"orch-ev","acceptance_criteria":"(1) foo","description":"verification: "}]'
    run_dispatch orch-ev
    [ "$status" -ne 0 ]
    [[ "$output" == *"verification"* ]]
}

@test "spawn G7（機械 probe 不能）: 明示宣言は verification 欄として受理し dispatch する" {
    export BD_SHOW_JSON='[{"id":"orch-pr","acceptance_criteria":"(1) 文書が正しい","description":"これは機械 probe 不能な文書タスク"}]'
    run_dispatch orch-pr
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]                         # 受理して dispatch する
}

@test "spawn G7（日本語ラベル 検証:）: 半角コロンの 検証: 宣言も verification 欄として受理する" {
    # 契約明記の受理形（verification:/検証:/全角コロン/機械 probe 不能）の 検証: ブランチを網羅（completeness）。
    export BD_SHOW_JSON='[{"id":"orch-jp","acceptance_criteria":"(1) foo","description":"検証: bash selftest-orch-vji.local.sh"}]'
    run_dispatch orch-jp
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]
}

@test "spawn G7（全角コロン 検証：）: 全角コロン（U+FF1A）の 検証： 宣言も verification 欄として受理する" {
    # 全角コロン `：` は半角 `:` と別 code point。日本語 first の codebase で自然な入力ゆえ受理形として網羅する。
    export BD_SHOW_JSON='[{"id":"orch-fw","acceptance_criteria":"(1) foo","description":"検証：bash selftest-orch-vji.local.sh"}]'
    run_dispatch orch-fw
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]
}

@test "spawn 入口（read 不能）: 契約 bead が read できない（bd 失敗）ら fail-closed で拒否" {
    export BD_FAIL=1
    run_dispatch orch-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"read できません"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "spawn 入口（parse 失敗）: bd show が非 JSON を返したら fail-closed で拒否" {
    export BD_SHOW_JSON='this is not json'
    run_dispatch orch-test
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

@test "spawn G2（snapshot 記録）: dispatch 時に acceptance の sha256+全文が bdw 経由で notes へ append される" {
    run_dispatch orch-snap
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]                         # dispatch も進む
    # snapshot が bdw（自台帳 write 直列化の正路）で append される。
    grep -q "update orch-snap --append-notes" "$BDW_ARGS_FILE"
    grep -q "ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1" "$BDW_ARGS_FILE"
    grep -q "bd=orch-snap" "$BDW_ARGS_FILE"
    grep -qF "(1) foo が動く (2) bar が動く" "$BDW_ARGS_FILE"  # verbatim acceptance
    grep -q "BDW-CWD: $TANCHOR" "$BDW_ARGS_FILE"               # cwd=anchor で台帳解決を固定
    # canonical hash 定義（gate 側 orch-tdj が同一手順で再計算し照合）: JSON-decoded acceptance の UTF-8 sha256。
    local expected; expected=$(printf '%s' '(1) foo が動く (2) bar が動く' | sha256sum | cut -d' ' -f1)
    grep -q "sha256=$expected" "$BDW_ARGS_FILE"
}

@test "spawn G2（foreign skip）: foreign 台帳 bead（非 orch-）は snapshot を書かない（write-isolation）" {
    # 既定の正常 bead（acceptance + verification）を foreign id で dispatch。check は通るが snapshot は自台帳のみ。
    run_dispatch un-foreign
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]                         # dispatch は進む
    ! grep -q "ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT" "$BDW_ARGS_FILE"   # snapshot write なし（foreign admin の責務）
}

@test "spawn G2（bdw 失敗）: snapshot 記録に失敗したら fail-closed で dispatch 中止" {
    export BDW_FAIL=1
    run_dispatch orch-snapfail
    [ "$status" -ne 0 ]
    [[ "$output" == *"snapshot"* ]]
    [[ "$output" != *"SPAWN-ARGS:"* ]]                         # tamper-evidence 欠落ゆえ dispatch しない
}

@test "spawn 入口（回帰・AC4）: 正常 bead は snapshot 記録 AND scribe-spawn 呼出の両方が起きる（forward 不変）" {
    run_dispatch orch-reg
    [ "$status" -eq 0 ]
    # forward は従来どおり（既定 anchor/repo/base/model）。
    [[ "$output" == *"--anchor $TANCHOR"* ]]
    [[ "$output" == *"--model opus"* ]]
    [[ "$output" == *"orch-reg"* ]]
    # snapshot も記録される（G2）。
    grep -q "update orch-reg --append-notes" "$BDW_ARGS_FILE"
}

@test "spawn --dry-run（G2 skip）: dry-run は snapshot を書かない（副作用ゼロ）が check は通す" {
    run_dispatch --dry-run orch-dry
    [ "$status" -eq 0 ]
    local line; line=$(printf '%s\n' "$output" | grep 'SPAWN-ARGS:')
    [[ "$line" == *"--dry-run"* ]]
    ! grep -q "ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT" "$BDW_ARGS_FILE"   # write なし
}

@test "spawn --dry-run（G1）: dry-run でも acceptance 欠落は拒否（read-only check は dry-run でも効く）" {
    export BD_SHOW_JSON='[{"id":"orch-dryno","description":"verification: x"}]'
    run_dispatch --dry-run orch-dryno
    [ "$status" -ne 0 ]
    [[ "$output" != *"SPAWN-ARGS:"* ]]
}

# ==============================================================================
# (2) gate-pending: `bd list --label gate-pending --status open,in_progress,blocked`（★単数 --label・非 closed）
# ==============================================================================

@test "gate-pending: bd list を --label gate-pending --status open,in_progress,blocked で組む（--labels を使わない）" {
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    # bd へ渡った argv を検査（単数 --label・非 closed status・--labels 不在）。
    # 完全な status 文字列を assert（`--status open` だけだと open,in_progress,blocked にも部分一致で false-pass）。
    grep -q -- '--label gate-pending' "$BD_ARGS_FILE"
    grep -q -- '--status open,in_progress,blocked' "$BD_ARGS_FILE"
    ! grep -qE -- '--status open( |$)' "$BD_ARGS_FILE"
    grep -q -- 'gate-pending' "$BD_ARGS_FILE"
    # --limit 0（unlimited）を固定＝bd list 既定 50 件 truncate を回避（誰かが落とすと黙って打ち切られる）
    grep -q -- '--limit 0' "$BD_ARGS_FILE"
    # 無効フラグ --labels（複数形）を使っていないこと（admin が踏んだ罠）
    ! grep -q -- '--labels' "$BD_ARGS_FILE"
}

@test "gate-pending: 位置サブコマンド形 'gate-pending' も等価に動く" {
    export BD_LIST_JSON='[]'
    run_dispatch gate-pending
    [ "$status" -eq 0 ]
    grep -q -- '--label gate-pending' "$BD_ARGS_FILE"
    ! grep -q -- '--labels' "$BD_ARGS_FILE"
}

@test "gate-pending: 結果を id + title で整形する" {
    export BD_LIST_JSON='[{"id":"orch-aaa","title":"検品待ちタスクA"},{"id":"orch-bbb","title":"検品待ちタスクB"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-aaa"* ]]
    [[ "$output" == *"検品待ちタスクA"* ]]
    [[ "$output" == *"orch-bbb"* ]]
    [[ "$output" == *"検品待ちタスクB"* ]]
}

@test "gate-pending: 空結果は「なし」を出す（false-clean でなく明示）" {
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"なし"* ]]
}

@test "gate-pending（behavioral・回帰）: in_progress + gate-pending の cell も列挙する（--status open のみだと取りこぼす）" {
    # D1 標準運用: worker は自 bead を claim（→in_progress）してから gate-pending を付ける。
    # stub は --status を honor するため、orch-dispatch が open のみを渡すとこの fixture は消え本 test が落ちる。
    export BD_LIST_JSON='[{"id":"orch-ip","title":"進行中の検品待ち","status":"in_progress"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-ip"* ]]
    [[ "$output" != *"なし"* ]]
}

@test "gate-pending（fail-silent 回避）: bd が非 JSON を返したら「なし」と誤報せず非 0 で surface する" {
    export BD_RAW=1
    export BD_LIST_JSON='this is not json'
    run_dispatch --gate-pending
    [ "$status" -ne 0 ]
    [[ "$output" != *"なし"* ]]
}

# (orch-9l1) un-merged spawn worktree を bead status / gate-pending ラベル非依存で surface する。
#   実 git の一時 repo で検証（bats は git をスタブしないため real git が走る）。
@test "gate-pending（orch-9l1）: un-merged spawn worktree を bead status/ラベル非依存で surface する" {
    # spawn worktree に未 merge commit を持たせ、bd stub は空（gate-pending ラベル付き cell 無し）＝
    # 旧実装なら「なし」と誤報した状況。worker が自己 close/ラベル無しでも検知されることを実証。
    local R="$TEST_TMPDIR/wtrepo-surface"
    git init -q -b main "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-zzz-999 "$R/.worktrees/spawn/orch-zzz-999" main
    echo b > "$R/.worktrees/spawn/orch-zzz-999/b"
    git -C "$R/.worktrees/spawn/orch-zzz-999" add b
    git -C "$R/.worktrees/spawn/orch-zzz-999" -c commit.gpgsign=false commit -qm work
    export BD_LIST_JSON='[]'
    # ORCH_DISPATCH_EXPORT_STATE を fresh な既定へ向け、setup 宣言どおり鮮度⚠ ノイズを混ぜない（orch-6rb）。
    PATH="$BIN:$PATH" ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
      ORCH_DISPATCH_SCRIPTORIUM="$R" ORCH_DISPATCH_POLL_INTERVAL=0 \
      ORCH_DISPATCH_SYNC_MARKER="$SYNC_MARKER_DEFAULT" \
      ORCH_DISPATCH_EXPORT_STATE="$EXPORT_STATE_DEFAULT" \
      run bash "$SCRIPT" --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-zzz"* ]]      # 自己 close/ラベル無しでも検知される
    [[ "$output" == *"main+1"* ]]
    [[ "$output" != *"なし"* ]]          # 旧実装ならここで「なし」と誤報していた
    [[ "$output" != *"⚠"* ]]            # fresh ゆえ鮮度警告は混ざらない（worktree 検知と鮮度の直交を pin）
}

# (orch-9l1・非vacuous/誤検出回避) 先行 commit 0（merge 済 or 未着手相当）の worktree は surface しない。
@test "gate-pending（orch-9l1・誤検出回避）: 先行 0 commit の worktree は surface せず「なし」になる" {
    local R="$TEST_TMPDIR/wtrepo-clean"
    git init -q -b main "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    # worktree を main と同一 HEAD で作る（先行 commit 0）。
    git -C "$R" worktree add -q -b spawn/orch-yyy-888 "$R/.worktrees/spawn/orch-yyy-888" main
    export BD_LIST_JSON='[]'
    # ORCH_DISPATCH_EXPORT_STATE を fresh な既定へ向け、setup 宣言どおり鮮度⚠ ノイズを混ぜない（orch-6rb）。
    PATH="$BIN:$PATH" ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
      ORCH_DISPATCH_SCRIPTORIUM="$R" ORCH_DISPATCH_POLL_INTERVAL=0 \
      ORCH_DISPATCH_SYNC_MARKER="$SYNC_MARKER_DEFAULT" \
      ORCH_DISPATCH_EXPORT_STATE="$EXPORT_STATE_DEFAULT" \
      run bash "$SCRIPT" --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" != *"orch-yyy"* ]]      # 先行 0 は gate 待ちでない＝出さない
    [[ "$output" == *"なし"* ]]
    [[ "$output" != *"⚠"* ]]            # fresh ゆえ鮮度警告は混ざらない（誤検出回避と鮮度の直交を pin）
}

# ==============================================================================
# (2-ext) external repo cell の監視射程 + 宣言 write 盲点への loud 対処（orch-b10）
#   incident orch-7ti: `--repo <外部 project>` cell は <外部>/.worktrees/spawn 配下に住み、SCRIPTORIUM
#   ルートだけ見る gate-pending scan の射程から漏れる（終端宣言 write も worker sandbox で断たれ二重盲点）。
#   → dispatch が外部 repo root を registry に記録 + loud 警告（acceptance 2）、gate-pending が registry を
#     読み <root>/.worktrees/spawn も surface（acceptance 1）。
# ==============================================================================

@test "spawn（external repo・orch-b10）: --repo が anchor≠repo なら registry へ記録し loud 警告を出す（fail-open で spawn は進む）" {
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg"
    run_dispatch --repo "$TREPO_OTHER" orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]                       # spawn は進む（監視で担保・fail-open）
    [[ "$output" == *"[ORCH-EXTERNAL-REPO]"* ]]              # loud 警告（acceptance 2「silent でなく loud」）
    [[ "$output" == *"anchor≠repo"* ]]                       # 宣言 write が sandbox で断たれる盲点を述べる
    [ -f "$TEST_TMPDIR/ext-reg" ]                            # registry へ記録
    grep -qxF "$(readlink -f "$TREPO_OTHER")" "$TEST_TMPDIR/ext-reg"   # repo root（realpath 正規化）が 1 行入る
}

@test "spawn（self repo・orch-b10）: 既定 --repo=SCRIPTORIUM は external 扱いにせず registry も警告も出さない（回帰）" {
    run_dispatch orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]
    [[ "$output" != *"[ORCH-EXTERNAL-REPO]"* ]]              # 自己開発 cell は無警告
    [ ! -f "$TEST_TMPDIR/external-registry" ]                # registry は書かれない（副作用ゼロ）
}

@test "spawn --dry-run（external repo・orch-b10）: loud 警告は出すが registry は書かない（副作用ゼロ）" {
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-dry"
    run_dispatch --dry-run --repo "$TREPO_OTHER" orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"[ORCH-EXTERNAL-REPO]"* ]]              # dry-run でも loud（再発の可視化）
    [[ "$output" == *"registry: skip"* ]]                    # 記録は skip（dry-run＝副作用ゼロ）と示す
    [ ! -f "$TEST_TMPDIR/ext-reg-dry" ]                      # registry は未 write
}

@test "spawn（external repo・冪等・orch-b10）: 同一 repo を 2 回 dispatch しても registry は 1 行（冪等 append）" {
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-idem"
    run_dispatch --repo "$TREPO_OTHER" orch-test
    [ "$status" -eq 0 ]
    run_dispatch --repo "$TREPO_OTHER" orch-test2           # 2 回目・同 repo（別 bead）
    [ "$status" -eq 0 ]
    local n; n=$(grep -cxF "$(readlink -f "$TREPO_OTHER")" "$TEST_TMPDIR/ext-reg-idem")
    [ "$n" -eq 1 ]                                           # 冪等: 重複行を作らない
}

@test "gate-pending（external repo・orch-b10）: registry の外部 repo cell の未 merge worktree を surface する（宣言 label 非依存）" {
    # 外部 repo を real git で組み、未 merge worktree を持たせ、registry に repo root を記録。
    # bd list は空（gate-pending ラベル cell 無し＝宣言 write が断たれた状況）でも worktree scan で拾う。
    local R="$TEST_TMPDIR/ext-gp-repo"
    git init -q -b main "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extgp-777 "$R/.worktrees/spawn/orch-extgp-777" main
    echo b > "$R/.worktrees/spawn/orch-extgp-777/b"
    git -C "$R/.worktrees/spawn/orch-extgp-777" add b
    git -C "$R/.worktrees/spawn/orch-extgp-777" -c commit.gpgsign=false commit -qm work
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-gp"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-gp"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-extgp"* ]]                        # 外部 repo cell が surface（射程に入る・acceptance 1）
    [[ "$output" == *"external repo cell:"* ]]               # 外部 repo cell と注記
    [[ "$output" == *"$(readlink -f "$R")"* ]]               # repo root が surface
    [[ "$output" != *"なし"* ]]                              # 旧実装なら「なし」と誤報していた
}

@test "gate-pending（external・誤検出回避・orch-b10）: registry があっても先行 0 commit の外部 worktree は surface しない" {
    local R="$TEST_TMPDIR/ext-gp-clean"
    git init -q -b main "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extcl-666 "$R/.worktrees/spawn/orch-extcl-666" main   # 先行 0
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-cl"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-cl"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" != *"orch-extcl"* ]]                        # 先行 0 は gate 待ちでない＝出さない（external でも同基準）
    [[ "$output" == *"なし"* ]]
}

@test "gate-pending（external・base≠main・orch-665 Option B）: local main を持たない外部 repo cell を per-repo default branch 解決で実 commit 数 surface（判定不能でない）" {
    # orch-665（Option B・orch-b10 follow-up）: 外部 repo が master/develop 既定で local `main` を持たないと、
    #   global base=main の `git rev-list --count main..HEAD` が非0終了する。Option A（orch-b10）は「判定不能」で
    #   fail-loud surface していた（安全な over-flag だが lossy＝正確な commit 数が出ない）。Option B は external
    #   repo の default branch（main worktree の symbolic-ref HEAD）を _resolve_repo_base で per-repo 解決し、
    #   `<base>..HEAD` で正確な commit 数を surface する（acceptance 1・RED→GREEN）。
    #   ★mutation RED 実証（acceptance 3）: per-repo 解決（_awaiting_gate_worktrees の _resolve_repo_base）を
    #     外して global base=main へ戻すと master..HEAD が数えられず「判定不能」に落ち、下の `!= 判定不能` /
    #     `== master+1` が RED になる＝per-repo 解決が load-bearing であることの teeth。
    local R="$TEST_TMPDIR/ext-gp-nomain"
    git init -q -b master "$R"                                # ← default branch = master（local `main` 不在）
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extnm-888 "$R/.worktrees/spawn/orch-extnm-888" master
    echo b > "$R/.worktrees/spawn/orch-extnm-888/b"
    git -C "$R/.worktrees/spawn/orch-extnm-888" add b
    git -C "$R/.worktrees/spawn/orch-extnm-888" -c commit.gpgsign=false commit -qm work   # master より 1 先行
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-nm"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-nm"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-extnm"* ]]                        # 射程に入る（acceptance 1）
    [[ "$output" == *"master+1"* ]]                          # per-repo 解決した実 base（master）に対する実 commit 数（Option B・acceptance 1）
    [[ "$output" != *"判定不能"* ]]                          # 判定不能でない（Option A から格上げ・mutation 外すと RED＝acceptance 3）
    [[ "$output" == *"external repo cell:"* ]]               # 外部 repo cell と注記
    [[ "$output" != *"なし"* ]]                              # silent drop しない
}

@test "gate-pending（external・base 解決不能 fallback・orch-665）: main worktree が detached HEAD なら per-repo 解決に失敗し「判定不能」へ fail-loud fallback" {
    # orch-665 fallback 経路の teeth: per-repo 解決（_resolve_repo_base）が失敗する（detached HEAD で symbolic-ref
    #   失敗・非 git dir/git 障害で worktree list 空）と global base=main へ fallback し、main 不在なら従来どおり
    #   「判定不能」で fail-loud surface する（silent drop でなく＝degraded-watch と対称）。Option B は「解決できるとき
    #   正確化」であって、解決不能時の安全な over-flag は温存する（judgment: 判定不能の code path が dead にならない）。
    local R="$TEST_TMPDIR/ext-gp-detached"
    git init -q -b master "$R"                                # local `main` 不在
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extdh-111 "$R/.worktrees/spawn/orch-extdh-111" master
    echo b > "$R/.worktrees/spawn/orch-extdh-111/b"
    git -C "$R/.worktrees/spawn/orch-extdh-111" add b
    git -C "$R/.worktrees/spawn/orch-extdh-111" -c commit.gpgsign=false commit -qm work
    git -C "$R" checkout -q --detach                          # ← main worktree を detached HEAD 化＝symbolic-ref 失敗
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-dh"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-dh"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-extdh"* ]]                        # 射程に入る（silent drop しない）
    [[ "$output" == *"判定不能"* ]]                          # 解決不能 → global base fallback → main 不在 → 判定不能（fail-loud）
    [[ "$output" == *"external repo cell:"* ]]
    [[ "$output" != *"なし"* ]]
}

@test "gate-pending（external・harm(b)・orch-665）: master 既定の 0-ahead(merge 済) external cell は per-repo 解決で false-positive 化せず drop（判定不能も出さない・契約中核 harm の直接 teeth）" {
    # 契約中核 harm (b): 「merge 済 non-main worktree が cleanup 前に一時 false-positive 化しうる」(orch_anchor.sh 契約記述)。
    #   Option A では master 既定 external cell の `rev-list main..HEAD` が非0終了→「判定不能」(要人間確認 false-positive) を出した。
    #   Option B は per-repo で master を解決し master..HEAD=0(merge 済) → `-gt 0` の drop で surface しない＝false-positive 解消。
    #   ★harm (a)[判定不能→実数] の test44/M7 は 1-ahead だが、harm (b) は 0-ahead(merged) modality＝契約が名指しした
    #     シナリオそのものを直接 pin する(narrative completeness)。per-repo 解決を revert(external base=main)すると
    #     main..HEAD が数えられず「判定不能」が復活し、下の `!= 判定不能`/`== なし` が RED になる＝harm(b) teeth。
    local R="$TEST_TMPDIR/ext-gp-merged"
    git init -q -b master "$R"                                # default=master（local main 不在）
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    # cell を master と同一 HEAD で作る＝0-ahead（既に merge 済 / 未着手相当）。
    git -C "$R" worktree add -q -b spawn/orch-extmg-222 "$R/.worktrees/spawn/orch-extmg-222" master
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-mg"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-mg"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" != *"orch-extmg"* ]]                        # 0-ahead(merge 済) は gate 待ちでない＝surface しない（false-positive 解消・harm b）
    [[ "$output" != *"判定不能"* ]]                          # Option A の 判定不能 false-positive を出さない（per-repo 解決 revert で復活し RED）
    [[ "$output" == *"なし"* ]]                              # 他に gate 待ち無し（誤検出ゼロ）
}

@test "gate-pending（external・harm(b) 中核 a=0∧b>0・orch-igl）: merge 済 cell の背後で default が前進しても contained→drop（naive ancestor gate / b-first なら diverged 誤検出で RED）" {
    # 契約 item(1) が名指しした harm(b) の中核 modality: 0-ahead(merge 済) cell の背後で default(master) が cell 先へ
    #   前進し base が cell の非祖先化する（a=rev-list master..HEAD=0 ∧ b=rev-list HEAD..master>0）。既存 harm(b)
    #   :795 は cell==master（a=0 ∧ b=0＝base 非前進）で、b>0 の真の harm(b) を exercise しない盲点だった
    #   （cell-quality gate blocking major・wf_75eda7ee）。a-first 短絡は正しく contained→drop に倒し surface しない。
    #   ★mutation RED: a==0 短絡を外し b を先に評価する / naive `merge-base --is-ancestor` gate へ差し替えると、この
    #     cell が「diverged→乖離」で false-positive surface され、下の `!= orch-extma` / `== なし` が RED になる。
    local R="$TEST_TMPDIR/ext-gp-advanced"
    git init -q -b master "$R"                                # default=master（local main 不在）
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extma-444 "$R/.worktrees/spawn/orch-extma-444" master   # cell=master（0-ahead）
    echo z > "$R/z"; git -C "$R" add z; git -C "$R" -c commit.gpgsign=false commit -qm advance         # master を 1 先行（cell 据置＝a=0 ∧ b=1）
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-ma"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-ma"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" != *"orch-extma"* ]]                        # a=0（統合済）→ contained→drop（b>0 でも surface しない・harm(b) 中核）
    [[ "$output" != *"乖離"* ]]                              # b-first / naive ancestor gate なら乖離 false-positive で RED
    [[ "$output" != *"判定不能"* ]]
    [[ "$output" == *"なし"* ]]                              # 他に gate 待ち無し（誤検出ゼロ）
}

@test "gate-pending（external・非 default checkout 乖離・orch-igl）: main worktree が非 default branch（cell 系列外）を checkout 中なら silent-drop / 誤 count せず「乖離」で fail-loud（containment gate teeth）" {
    # orch-igl item(1): `_resolve_repo_base` は「main worktree の checkout branch」で default を近似する。foreign
    #   main worktree が非 default branch（cell 系列から乖離）を checkout 中だと base が cell 系列外を指し、
    #   `rev-list base..HEAD` の commit 数が不正確になる（従来: 誤 count を surface / 別 config では silent-drop）。
    #   containment gate（_repo_base_relation）は base⊀HEAD ∧ HEAD⊄base（a>0 ∧ b>0）を乖離として検出し「乖離」で
    #   fail-loud surface する。
    #   ★mutation RED（acceptance 1/3）: containment gate（diverged 分岐）を外し従来の数値 surface へ戻すと
    #     「feature+1 commits」で誤 surface され、下の `== 乖離`/`!= feature+1 commits` が RED になる＝gate が load-bearing。
    local R="$TEST_TMPDIR/ext-gp-diverged"
    git init -q -b master "$R"                                # default branch = master
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init   # master: M
    # main worktree を非 default branch feature（master+1・cell とは別系列）へ移す。
    git -C "$R" checkout -q -b feature
    echo fx > "$R/fx"; git -C "$R" add fx; git -C "$R" -c commit.gpgsign=false commit -qm featwork   # feature: M+Fx
    # cell は master 起点で 1 先行（cell = M+C）＝feature とは乖離（互いに相手に無い commit を持つ）。
    git -C "$R" worktree add -q -b spawn/orch-extdv-333 "$R/.worktrees/spawn/orch-extdv-333" master
    echo c > "$R/.worktrees/spawn/orch-extdv-333/c"
    git -C "$R/.worktrees/spawn/orch-extdv-333" add c
    git -C "$R/.worktrees/spawn/orch-extdv-333" -c commit.gpgsign=false commit -qm cellwork   # cell: M+C
    printf '%s\n' "$R" > "$TEST_TMPDIR/ext-reg-dv"
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/ext-reg-dv"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-extdv"* ]]                        # 射程に入る（silent-drop しない・acceptance 1）
    [[ "$output" == *"乖離"* ]]                              # containment gate が乖離を検出→fail-loud（gate 外すと RED）
    [[ "$output" != *"feature+1 commits"* ]]                # 非 default base(feature) の誤 count を surface しない（gate 外すと RED）
    [[ "$output" == *"external repo cell:"* ]]              # 外部 repo cell と注記
    [[ "$output" != *"なし"* ]]                              # silent drop しない
}

@test "spawn（external repo・registry write 失敗・orch-b10）: 記録失敗でも spawn は継続（fail-open）し⚠ で loud surface" {
    # acceptance 2 隣接: registry write は監視の補助ゆえ失敗しても dispatch を止めない（fail-open）が失敗を loud 化する。
    #   親 dir 不在の registry path を向け _register_external_repo を return 1（`[ -d "$dir" ]` false）へ落とす。
    #   spawn 継続（status=0 + SPAWN-ARGS）かつ⚠「記録失敗」を surface することを pin（else 分岐の未カバー解消）。
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/no-such-dir/registry"   # 親 dir 不在＝write 不可
    run_dispatch --repo "$TREPO_OTHER" orch-test
    [ "$status" -eq 0 ]                                      # fail-open: spawn を止めない
    [[ "$output" == *"SPAWN-ARGS:"* ]]                       # spawn は進む
    [[ "$output" == *"[ORCH-EXTERNAL-REPO]"* ]]              # loud 警告は出る
    [[ "$output" == *"記録失敗"* ]]                          # registry write 失敗を surface（silent でない）
    [ ! -f "$TEST_TMPDIR/no-such-dir/registry" ]            # 実際に書かれていない（親 dir 不在ゆえ）
}

@test "(E2) external 発火判定の realpath 正規化: self を symlink/末尾スラッシュ綴りで --repo 指定しても警告なし・registry 無書込" {
    # orch-b10 gate errata E2: 発火判定 [ "$REPO" != "$SCRIPTORIUM" ] が生文字列比較だと read 側（readlink -f 正規化）
    #   と非対称で、self を別綴り（symlink・末尾スラッシュ）で --repo 指定すると false [ORCH-EXTERNAL-REPO] 警告 +
    #   registry へ self 誤登録が起きる。canon 比較へ直した回帰防御（生比較へ戻す mutation で警告が出て RED）。
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/e2-reg"
    ln -s "$TANCHOR" "$TEST_TMPDIR/self-link"                # self(SCRIPTORIUM=TANCHOR)への symlink 綴り
    run_dispatch --repo "$TEST_TMPDIR/self-link" orch-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN-ARGS:"* ]]                       # spawn は進む
    [[ "$output" != *"[ORCH-EXTERNAL-REPO]"* ]]              # self 別綴りを external 誤判定しない（生比較なら RED）
    [ ! -f "$TEST_TMPDIR/e2-reg" ]                           # registry へ self 誤登録しない
    # 末尾スラッシュ綴りも同様（canon 一致で吸収）。
    run_dispatch --repo "$TANCHOR/" orch-test
    [ "$status" -eq 0 ]
    [[ "$output" != *"[ORCH-EXTERNAL-REPO]"* ]]
    [ ! -f "$TEST_TMPDIR/e2-reg" ]
}

@test "(E3) gate-pending: registry 重複行でも external cell を二重 surface しない（read 側 dedupe teeth）" {
    # orch-b10 gate errata E3: _register_external_repo の grep→append は非アトミック（並列 dispatch で重複行残留）。
    #   read 側 dedupe（_external_scan_roots で emit 済み root skip）で二重 surface を防ぐ（dedupe を外すと 2 で RED）。
    local R="$TEST_TMPDIR/ext-gp-dup"
    git init -q -b main "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extdup-555 "$R/.worktrees/spawn/orch-extdup-555" main
    echo b > "$R/.worktrees/spawn/orch-extdup-555/b"
    git -C "$R/.worktrees/spawn/orch-extdup-555" add b
    git -C "$R/.worktrees/spawn/orch-extdup-555" -c commit.gpgsign=false commit -qm work
    printf '%s\n%s\n' "$R" "$R" > "$TEST_TMPDIR/e3-reg"      # 同一 root を 2 行（TOCTOU 重複を模す）
    export BD_LIST_JSON='[]'
    export ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/e3-reg"
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    local n; n=$(printf '%s\n' "$output" | grep -c 'orch-extdup')
    [ "$n" -eq 1 ]                                           # 重複行でも 1 回だけ surface（dedupe を外すと 2 で RED）
}

@test "(E5) gate-pending self root fail-open: base 解決不能(master 既定)の self worktree は『判定不能』を出さず fail-open skip" {
    # orch-b10 gate errata E5: self root（scriptorium 相当）は base=main 常時解決可の前提で、rev-list 解決不能時に
    #   fail-open（silent skip）を維持する（external の 判定不能 fail-loud とは非対称＝一過性 git 障害の誤検出回避）。
    #   _scan_awaiting_root の `[ -n "$annot" ]` guard を外す mutation（self も 判定不能 化）を入れると『判定不能』が
    #   出て RED。external 側 test 44 のみだった fail-open 側の teeth 欠落を埋める。
    local R="$TEST_TMPDIR/self-master"
    git init -q -b master "$R"                               # ← self repo だが default=master（local main 不在）
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-selfm-333 "$R/.worktrees/spawn/orch-selfm-333" master
    echo b > "$R/.worktrees/spawn/orch-selfm-333/b"
    git -C "$R/.worktrees/spawn/orch-selfm-333" add b
    git -C "$R/.worktrees/spawn/orch-selfm-333" -c commit.gpgsign=false commit -qm work
    export BD_LIST_JSON='[]'
    PATH="$BIN:$PATH" ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
      ORCH_DISPATCH_SCRIPTORIUM="$R" ORCH_DISPATCH_POLL_INTERVAL=0 \
      ORCH_DISPATCH_SYNC_MARKER="$SYNC_MARKER_DEFAULT" \
      ORCH_DISPATCH_EXPORT_STATE="$EXPORT_STATE_DEFAULT" \
      ORCH_DISPATCH_EXTERNAL_REGISTRY="$TEST_TMPDIR/e5-reg-absent" \
      run bash "$SCRIPT" --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" != *"判定不能"* ]]                          # self root は fail-loud 化しない（annot 空 guard を外すと RED）
    [[ "$output" != *"orch-selfm"* ]]                        # self worktree は fail-open で surface しない
    [[ "$output" == *"なし"* ]]
}

# ==============================================================================
# (2-z) 非 canonical anchor path の scan root 動的解決（orch-pso・orch-7py gate follow-up）
#   deploy-layout hardcode（canonical anchor 絶対 path）を撤去し、`git worktree list` 先頭
#   （= anchor main worktree）から SCRIPTORIUM を解決する。anchor を非 canonical path へ checkout/改名しても
#   SCRIPTORIUM を根に持つ既定（_awaiting_gate_worktrees の scan root=$SCRIPTORIUM/.worktrees/spawn 等）が
#   誤 path を silent に指さない（latent 結合の解消・acceptance (1)(2)）。orch-dispatch は lib を source しない
#   自己完結ゆえ、script を非 canonical real git repo の scripts/ へ 1 file コピーし real git で解決させる
#   （env ORCH_DISPATCH_SCRIPTORIUM を渡さない＝git 解決だけで導く。旧 hardcode 実装なら $R 配下 cell を
#   hardcode path に無いため surface せず RED になる teeth）。
# ==============================================================================
@test "非 canonical anchor（orch-pso）: SCRIPTORIUM を git worktree list から動的解決し worktree scan root を導く（env override なし）" {
    local R="$TEST_TMPDIR/renamed-orchestrator-xyz"
    git init -q -b main "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-ncp-777 "$R/.worktrees/spawn/orch-ncp-777" main
    echo b > "$R/.worktrees/spawn/orch-ncp-777/b"
    git -C "$R/.worktrees/spawn/orch-ncp-777" add b
    git -C "$R/.worktrees/spawn/orch-ncp-777" -c commit.gpgsign=false commit -qm work
    # script + 共有 lib を非 canonical anchor の scripts/ へコピー（orch-49g: orch-dispatch は共有 lib
    #   orch_anchor.sh を source するようになったため、relocate 形態を再現するには lib も同梱する＝real repo は
    #   lib ごと存在する）。_self_dir=$R/scripts → real `git worktree list` 先頭 = $R（非 canonical anchor）へ解決。
    local SRCDIR; SRCDIR="$(dirname "$SCRIPT")"
    mkdir -p "$R/scripts/lib" "$R/scripts/hooks/lib"
    cp "$SCRIPT" "$R/scripts/orch-dispatch.sh"
    cp "$SRCDIR/lib/orch_anchor.sh" "$R/scripts/lib/orch_anchor.sh"
    cp "$SRCDIR/lib/orch_liveness.sh" "$R/scripts/lib/orch_liveness.sh"   # orch-4js9 fence1: 共有 liveness lib も同梱（source 必須ゆえ）
    cp "$SRCDIR/lib/orch_slate.sh" "$R/scripts/lib/orch_slate.sh"         # orch-vswk: 共有 slate lib も top-level source ゆえ同梱
    cp "$SRCDIR/hooks/lib/orch_session.sh" "$R/scripts/hooks/lib/orch_session.sh"
    # 鮮度⚠ ノイズを避けるため last-sync を $R 配下（=解決後 SCRIPTORIUM の既定 marker path）に fresh で置く。
    #   orch-49g: E2 anchor 検証（dolt_database==orch）を通すため $R に orch 台帳 metadata を置く（real orchestrator
    #   anchor は orch 台帳を持つ＝faithful 化・非 canonical でも dolt_database==orch なら採用される）。
    mkdir -p "$R/.beads"; printf '%s\n' 'x' > "$R/.beads/last-sync"; touch "$R/.beads/last-sync"
    printf '{"dolt_database":"orch"}' > "$R/.beads/metadata.json"
    export BD_LIST_JSON='[]'
    # ★ORCH_DISPATCH_SCRIPTORIUM を敢えて渡さない＝git worktree list からの解決だけで scan root を導く。
    PATH="$BIN:$PATH" ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" ORCH_DISPATCH_POLL_INTERVAL=0 \
      run bash "$R/scripts/orch-dispatch.sh" --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-ncp"* ]]      # 非 canonical anchor 配下の未 merge worktree が surface＝scan root が git 解決された
    [[ "$output" == *"main+1"* ]]
    [[ "$output" != *"⚠"* ]]            # $R 配下 last-sync が fresh ゆえ鮮度警告は混ざらない
}

# ==============================================================================
# (2-x) cross-ledger（§5.2 外部 track・orch-3d4）: 連結 substrate（§3 `bd repo sync` pull hydrate）で
#       自 DB に混在する foreign 台帳の gate-pending bead が surface し、self-dev（orch-）と外部 repo cell
#       （foreign）の 2 バケットへ分かれる。bd stub は prefix を問わず BD_LIST_JSON を返す＝`bd repo sync`
#       後に foreign copy が自 DB へ hydrate された状態を hermetic に再現する。gate 意味論の差（§1.1 案C:
#       self-dev=直 gate / foreign=admin gate 信頼・admin 不在は人間 go-gate）を出力で surface することを pin。
# ==============================================================================

@test "gate-pending（cross-ledger）: foreign 台帳の gate-pending bead が hydrate 後 surface し『外部 repo cell』バケットに入る" {
    # 外部 cell が自台帳 foreign に書いた gate-pending を、courier `bd repo sync` 後に orchestrator が拾う想定。
    export BD_LIST_JSON='[{"id":"un-ext1","title":"projalpha 外部 cell の検品待ち"},{"id":"sc-ext2","title":"scribe 外部 cell"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"un-ext1"* ]]                 # foreign が surface する（cross-ledger 核心 acceptance）
    [[ "$output" == *"sc-ext2"* ]]
    [[ "$output" == *"外部 repo cell"* ]]          # 外部 track の gate routing 見出しが出る（§5.2）
    [[ "$output" != *"なし"* ]]                     # 旧 local-only 前提なら foreign を落とし「なし」になりうる
    [[ "$output" != *"self-dev cell"* ]]           # foreign のみ＝self-dev 見出しは出ない（誤バケット回避）
}

@test "gate-pending（cross-ledger）: self-dev（orch-）は self-dev バケット・foreign とは別見出しに入る" {
    export BD_LIST_JSON='[{"id":"orch-self1","title":"自己開発の検品待ち"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-self1"* ]]
    [[ "$output" == *"self-dev cell"* ]]           # self-dev 見出しが出る
    [[ "$output" != *"外部 repo cell"* ]]          # self のみ＝外部見出しは出ない（orch- を foreign と誤判定しない）
}

@test "gate-pending（cross-ledger）: self-dev と foreign の混在を 2 バケットに分けて両方 surface する" {
    export BD_LIST_JSON='[{"id":"orch-self1","title":"自己開発"},{"id":"un-ext1","title":"外部 projalpha"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-self1"* ]]
    [[ "$output" == *"un-ext1"* ]]
    [[ "$output" == *"self-dev cell"* ]]
    [[ "$output" == *"外部 repo cell"* ]]
}

# ==============================================================================
# (2-y) foreign 鮮度警告（orch-6rb・§5.2 fail-open 補強）: gate-pending の外部 repo cell バケットは事前
#       courier `bd repo sync` 成功に構造依存する。sync 未実行/失敗/古だと foreign gate-pending を silent
#       取りこぼす。本 wrapper は read-only（sync を呼ばない）ゆえ、sync 専用マーカー .beads/last-sync
#       （orch-hydrate.sh が sync 成功直後に stamp）の mtime を read し、stale(>閾値)/unknown(不在) なら⚠
#       警告を添えて「一覧が full とは限らない」を surface する。foreign が「なし」でも警告（silent 取りこぼし
#       の fail-loud 化）。fresh は foreign surface 時のみ控えめ注記。両側（出る/出ない）を pin し非vacuous を証明。
#       ★admin gate errata（freshness-soundness）: export-state.json は any-write proxy ゆえ active orchestrator
#       が sync 忘れでも fresh のまま＝取りこぼす。主指標は last-sync（sync 特化）で「active-but-sync-stale」を捕捉。
#       鮮度ソースは ORCH_DISPATCH_SYNC_MARKER（主）/ ORCH_DISPATCH_EXPORT_STATE（補助）で hermetic に差替。
# ==============================================================================

@test "鮮度（stale + foreign）: 最後の sync が閾値超過なら foreign バケットに⚠ 警告を出す" {
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"   # last-sync age 120 > 既定 60 ⇒ stale
    export BD_LIST_JSON='[{"id":"un-ext1","title":"外部 projalpha の検品待ち"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"un-ext1"* ]]              # foreign は surface される
    [[ "$output" == *"foreign 鮮度警告"* ]]      # ⚠ 警告本文
    [[ "$output" == *"⚠"* ]]
    [[ "$output" == *"orch-hydrate.sh"* ]]      # 是正導線（再 sync）を案内
}

@test "鮮度（errata 核心・active-but-sync-stale）: last-sync stale だが export-state fresh（active orchestrator が sync 忘れ）でも⚠" {
    # admin gate errata の再現: orchestrator がローカル write を継続し export-state は fresh のまま、
    # しかし courier `bd repo sync` を長時間回していない（last-sync stale）局面。any-write proxy を主指標に
    # していた旧実装はここで fresh と誤判定し⚠ を出さず silent 取りこぼしを残した。last-sync 主指標で捕捉する。
    touch "$EXPORT_STATE_DEFAULT"                       # export-state は fresh（active なローカル write を模す）
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"   # だが sync は 120 分前（sync 忘れ）
    export BD_LIST_JSON='[]'                            # foreign は bd list に未出（sync 未反映）
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"なし"* ]]
    [[ "$output" == *"⚠"* ]]                            # export fresh に騙されず stale を検出（errata 修正の核心）
    [[ "$output" == *"foreign 鮮度警告"* ]]
}

@test "鮮度（fresh + foreign・誤検出回避）: 新鮮なら⚠ を出さず控えめ注記のみ" {
    # setup 既定 = last-sync fresh（now）。
    export BD_LIST_JSON='[{"id":"un-ext1","title":"外部 projalpha の検品待ち"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"un-ext1"* ]]
    [[ "$output" != *"⚠"* ]]                    # fresh は⚠ を出さない（誤検出回避＝非vacuous の片側）
    [[ "$output" != *"foreign 鮮度警告"* ]]
    [[ "$output" == *"（注:"* ]]                 # 控えめ注記（sync 依存である事実）は出す
}

@test "鮮度（unknown・last-sync 不在）: export-state が fresh でも sync 専用証跡が無ければ⚠（over-claim 回避）" {
    rm -f "$SYNC_MARKER_DEFAULT"                 # last-sync 不在 ⇒ unknown（export-state は fresh のまま残す）
    export BD_LIST_JSON='[{"id":"un-ext1","title":"外部 projalpha"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"un-ext1"* ]]
    [[ "$output" == *"foreign 鮮度警告"* ]]
    [[ "$output" == *"一度も成功していない可能性"* ]]   # unknown 固有の文言（export fresh でも unknown を維持）
}

@test "鮮度（なし + stale・核心）: foreign が「なし」でも stale なら⚠（silent 取りこぼしの fail-loud 化）" {
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"なし"* ]]                  # gate-pending は空
    [[ "$output" == *"⚠"* ]]                    # だが鮮度が悪いので「なし」は信頼できない旨を出す
    [[ "$output" == *"foreign 鮮度警告"* ]]
}

@test "鮮度（なし + fresh・誤検出回避）: foreign が「なし」かつ新鮮なら⚠ を出さない" {
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"なし"* ]]
    [[ "$output" != *"⚠"* ]]                    # fresh は誤警告しない（非vacuous の片側）
    [[ "$output" != *"foreign 鮮度警告"* ]]
}

@test "鮮度（self のみ + stale）: self-dev だけでも foreign 取りこぼし可能性を⚠ で surface" {
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"
    export BD_LIST_JSON='[{"id":"orch-self1","title":"自己開発の検品待ち"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-self1"* ]]
    [[ "$output" == *"self-dev cell"* ]]
    [[ "$output" == *"⚠"* ]]                    # foreign は空でも sync 鮮度劣化を警告
}

@test "鮮度（self のみ + fresh・誤検出回避）: foreign 空かつ新鮮なら注記も⚠ も出さない" {
    export BD_LIST_JSON='[{"id":"orch-self1","title":"自己開発"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-self1"* ]]
    [[ "$output" != *"⚠"* ]]
    [[ "$output" != *"外部 repo cell"* ]]        # foreign 空ゆえ注記も出ない（noise 削減）
}

@test "鮮度（read-only 不変条件）: 鮮度計算は鮮度ソース（last-sync）を mutate しない（mtime 不変）" {
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"
    local before; before="$(stat -c %Y "$SYNC_MARKER_DEFAULT")"
    export BD_LIST_JSON='[{"id":"un-ext1","title":"外部"}]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]
    local after; after="$(stat -c %Y "$SYNC_MARKER_DEFAULT")"
    [ "$before" = "$after" ]                     # read-only: 鮮度ソースを書き換えない
}

@test "鮮度（非整数閾値の fallback）: ORCH_DISPATCH_SYNC_STALE_MIN 非整数は warn して既定 60 で動作継続" {
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"
    export ORCH_DISPATCH_SYNC_STALE_MIN="notanum"
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending
    [ "$status" -eq 0 ]                          # die せず継続（鮮度は補助機能ゆえ fail-open 寄り）
    [[ "$output" == *"非整数"* ]]                # warn を出す
    [[ "$output" == *"⚠"* ]]                    # 既定 60 で age 120 > 60 ⇒ stale 判定が効く
}

@test "鮮度（dry-run）: bd も鮮度ソースも触らず plan に鮮度行を出す（副作用ゼロ）" {
    : > "$BD_ARGS_FILE"
    touch -d "120 minutes ago" "$SYNC_MARKER_DEFAULT"
    local before; before="$(stat -c %Y "$SYNC_MARKER_DEFAULT")"
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [[ "$output" == *"鮮度"* ]]                  # plan に鮮度行が出る
    [[ "$output" != *"⚠"* ]]                    # dry-run は鮮度を評価しない（plan の説明のみ・実警告は出ない）
    [[ "$output" != *"foreign 鮮度警告"* ]]      # stale な状態でも実警告本文を出さない＝評価スキップの非vacuous 証明
    [ ! -s "$BD_ARGS_FILE" ]                     # bd は呼ばれない
    local after; after="$(stat -c %Y "$SYNC_MARKER_DEFAULT")"
    [ "$before" = "$after" ]                     # 鮮度ソースも触らない
}

@test "gate-pending: 余分な bd-id を渡すと die（ambiguity の fail-loud）" {
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending orch-stray
    [ "$status" -ne 0 ]
}

@test "gate-pending --dry-run: bd を実際に叩かない（[plan] のみ・read-only も発火しない）" {
    : > "$BD_ARGS_FILE"
    export BD_LIST_JSON='[]'
    run_dispatch --gate-pending --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    # bd は一度も呼ばれない
    [ ! -s "$BD_ARGS_FILE" ]
}

# ==============================================================================
# (3) watch: gate-pending 出現で 0 / timeout で 3
# ==============================================================================

@test "watch: 対象 bead が gate-pending に出現したら exit 0（新規到達・後方互換）" {
    # orch-y9z baseline 化後の後方互換: 武装時は未 gate-pending（poll1=空）、その後 gate-pending 出現（poll2）で発火。
    #   baseline_gp=0 ゆえ updated_at に依らず新規到達で発火する（通常の dispatch 直後フロー）。
    export BD_LIST_JSON_BASELINE='[]'
    export BD_LIST_JSON='[{"id":"orch-watch","title":"watch 対象"}]'
    run_dispatch --watch --timeout 5 orch-watch
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-watch"* ]]
    [[ "$output" == *"gate-pending"* ]]
    [[ "$output" == *"新規到達"* ]]
}

@test "watch（behavioral・回帰）: in_progress の gate-pending cell を検出して exit 0（--status open のみだと false timeout）" {
    # D1 標準運用（claim→in_progress→gate-pending）の正準ケース。open のみだと永久に検出されず exit 3 になる。
    # orch-y9z baseline 化後: 武装時未 gate-pending→出現の新規到達で発火（in_progress の status フィルタ通過を維持）。
    export BD_LIST_JSON_BASELINE='[]'
    export BD_LIST_JSON='[{"id":"orch-ipw","title":"進行中","status":"in_progress"}]'
    run_dispatch --watch --timeout 5 orch-ipw
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-ipw"* ]]
}

@test "watch: timeout で非 0（exit 3）— 出現しないまま期限切れ" {
    export BD_LIST_JSON='[]'
    run_dispatch --watch --timeout 0 orch-never
    [ "$status" -eq 3 ]
}

@test "watch: 別 bead だけが gate-pending でも対象は timeout（完全一致のみ）" {
    export BD_LIST_JSON='[{"id":"orch-other","title":"別タスク"}]'
    run_dispatch --watch --timeout 0 orch-target
    [ "$status" -eq 3 ]
}

@test "watch: bd-id 無しは die" {
    run_dispatch --watch
    [ "$status" -ne 0 ]
}

@test "watch: 非数値 --timeout は die（数値前提入力の input-validation・fail-loud）" {
    run_dispatch --watch --timeout abc orch-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"整数"* ]]
}

@test "watch（算術注入 regression）: --timeout に array-subscript ペイロードを渡してもコマンドが実行されない" {
    # bash 算術 $((SECONDS + TIMEOUT)) は a[expr] の expr でコマンド置換を評価する。
    # 数値検証が無いと TIMEOUT='SECONDS[$(touch marker)]' で marker が生成されてしまう（PWN）。
    # 検証導入後は使用前に die し、marker は生成されないことを機械保証する。
    local marker="$TEST_TMPDIR/PWNED"
    [ ! -e "$marker" ]
    run_dispatch --watch --timeout "SECONDS[\$(touch $marker)]" orch-x
    [ "$status" -ne 0 ]
    # コマンド置換が実行されていない＝marker が無い（算術注入面が塞がれている）
    [ ! -e "$marker" ]
}

@test "watch: 非数値 ORCH_DISPATCH_POLL_INTERVAL は die（sleep へ流れる前に弾く）" {
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
    ORCH_DISPATCH_SCRIPTORIUM="$TANCHOR" \
    ORCH_DISPATCH_POLL_INTERVAL="notanum" \
    BD_ARGS_FILE="$BD_ARGS_FILE" \
    BD_LIST_JSON='[]' \
        run bash "$SCRIPT" --watch --timeout 5 orch-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"整数"* ]]
}

@test "watch（fail-silent 回避）: bd list 失敗時は警告を surface しつつ timeout する（障害を『まだ』と誤報しない）" {
    export BD_FAIL=1
    export BD_LIST_JSON='[]'
    PATH="$BIN:$PATH" \
    ORCH_DISPATCH_SPAWN="$BIN/scribe-spawn-stub" \
    ORCH_DISPATCH_SCRIPTORIUM="$TANCHOR" \
    ORCH_DISPATCH_POLL_INTERVAL=0 \
    BD_ARGS_FILE="$BD_ARGS_FILE" \
    BD_FAIL=1 BD_LIST_JSON='[]' \
        run bash "$SCRIPT" --watch --timeout 0 orch-target
    # bd 障害（rc!=0）は無言で握り潰さず警告を出す。timeout 終端（exit 3）は維持。
    [ "$status" -eq 3 ]
    [[ "$output" == *"bd list が失敗"* ]]
}

# ==============================================================================
# (3-worker-baseline) watch worker baseline 方式（orch-y9z）: gate-pending ラベルにも baseline を適用する。
#   admin baseline（orch-edv T2）は status にのみ効き label には非適用だった。gate-pending は reversible な
#   ラベルで、errata 差し戻し中に label が残ったまま --watch を再武装すると武装した瞬間に即偽発火する
#   （orch-b10 運用実測）。watch 開始時に (gate-pending 有無, updated_at) を baseline 記録し:
#     - 武装時 未 gate-pending → gate-pending 出現で発火（新規到達・後方互換／上の 2 test が被覆）。
#     - 武装時 既 gate-pending → updated_at 前進（errata 宣言の notes append）まで suppress。
#     - errata 宣言で updated_at 前進 → re-arm 後の再宣言として発火。
#   list 遷移は BD_LIST_JSON_BASELINE（初回 list）+ BD_LIST_JSON（2 回目以降）で、updated_at 遷移は
#   BD_SHOW_JSON_BASELINE（初回 show）+ BD_SHOW_JSON（2 回目以降）で hermetic に再現する。
# ==============================================================================

@test "watch worker baseline（orch-y9z・即時偽発火解消）: 武装時 既 gate-pending で bead 無更新なら発火せず timeout(exit 3)" {
    # 契約 acceptance(1): gate-pending 既付与状態で --watch 武装→bead 無更新なら発火しない。
    # 旧実装（gate-pending 存在で即発火）はここで即時偽発火し admin が worker を「完了」と誤認した（orch-b10 実測）。
    export BD_LIST_JSON='[{"id":"orch-sup","title":"既 gate-pending"}]'   # 武装時から gate-pending 存在（constant）
    # BD_SHOW_JSON は list 形 [{...}]（実 bd show --json=v1.1.0 実測の list 形に忠実・orch-rqp／_STATUS_PY は isinstance(data,list) unwrap で list/object 両対応）。
    export BD_SHOW_JSON='[{"id":"orch-sup","status":"in_progress","updated_at":"2026-07-04T00:00:00Z"}]'  # updated_at 不変
    run_dispatch --watch --timeout 0 orch-sup
    [ "$status" -eq 3 ]
    [[ "$output" != *"gate-pending になりました"* ]]   # 即時偽発火が解消されている（誤発火解消の核心）
}

@test "watch worker baseline（orch-y9z・errata 再宣言で発火）: 既 gate-pending のまま updated_at 前進で発火(exit 0)" {
    # 契約 acceptance(2): errata 宣言（notes append=updated_at 前進）で発火する。
    # gate-pending ラベルは不変（constant present）だが baseline から updated_at が前進するため発火する。
    export BD_LIST_JSON='[{"id":"orch-err","title":"errata 再宣言"}]'   # gate-pending は残ったまま（constant）
    # BD_SHOW_JSON{,_BASELINE} 共に list 形 [{...}]（実 bd show --json 忠実・orch-rqp／F2＝baseline も list 化）。
    export BD_SHOW_JSON_BASELINE='[{"id":"orch-err","status":"in_progress","updated_at":"2026-07-04T00:00:00Z"}]'
    export BD_SHOW_JSON='[{"id":"orch-err","status":"in_progress","updated_at":"2026-07-04T01:00:00Z"}]'  # updated_at 前進
    run_dispatch --watch --timeout 5 orch-err
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate-pending になりました"* ]]
    [[ "$output" == *"再宣言"* ]]        # 発火理由が re-arm 後の再宣言（updated_at 前進）と derive される
}

@test "watch worker baseline（orch-y9z・mutation RED）: baseline capture を潰した mutant は武装時 既 gate-pending で即発火(exit 0)" {
    # 契約 acceptance(3): 新 teeth の mutation RED 実証。baseline_gp の capture を 0 固定に潰すと baseline 抑止が
    #   無効化され、上の suppress teeth（既 gate-pending・無更新→exit 3）が exit 0 に反転する＝抑止ロジックが
    #   load-bearing（非vacuous）であることを機械保証する。
    # mutant は共有 anchor lib（scripts/lib）を BASH_SOURCE 相対で解決するため、sandbox に lib を実 scripts/lib へ
    #   symlink して置く（readlink -f が mutant→$sb を解決し $sb/lib symlink 経由で実 lib を掴む。orch_anchor.sh の
    #   `../hooks/lib` は kernel が symlink 追跡後に `..` を辿り実 scripts/hooks/lib へ解決＝両 lib 成立）。
    local sb="$TEST_TMPDIR/mut-sandbox"; mkdir -p "$sb"
    ln -s "$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)" "$sb/lib"
    local mutant="$sb/orch-dispatch.sh"
    sed 's/baseline_gp="\$cur_gp"/baseline_gp=0/' "$SCRIPT" > "$mutant"
    # 変異が実際に適用された（原本には capture があり mutant からは消えている）＝非vacuity。
    grep -q 'baseline_gp="\$cur_gp"' "$SCRIPT"
    ! grep -q 'baseline_gp="\$cur_gp"' "$mutant"
    export BD_LIST_JSON='[{"id":"orch-mut","title":"既 gate-pending"}]'
    # BD_SHOW_JSON は list 形 [{...}]（実 bd show --json 忠実・orch-rqp）。
    export BD_SHOW_JSON='[{"id":"orch-mut","status":"in_progress","updated_at":"2026-07-04T00:00:00Z"}]'
    # run_dispatch は $SCRIPT を bash 実行する。env-prefix は関数内の変数参照へ伝播しないため明示再代入する
    #   （@test は独立プロセスゆえ他 test へ leak しない）。
    SCRIPT="$mutant"
    run_dispatch --watch --timeout 0 orch-mut
    [ "$status" -eq 0 ]                                     # mutant は baseline 抑止を失い即発火（旧バグ再現）
    [[ "$output" == *"gate-pending になりました"* ]]
}

# ==============================================================================
# (3-worker-showfail) watch worker status_warned 経路（orch-rqp・orch-y9z gate follow-up）:
#   bd list=gate-pending 存在だが bd show=parse 不能（baseline=updated_at 確立不能）のとき、show 失敗を
#   『完了』と取り違えず warn + exit 3（偽 timeout・fail-safe）で終端する挙動を pin する。run_watch_worker の
#   status_warned 分岐は worker mode の teeth が 1 本も無く未 pin だった＝admin 版の「fail-silent 回避」test
#   （`watch admin（fail-silent 回避）`）の worker 対応版を補う。
#   ★BD_FAIL=1 は使わない: bd list も落ちて bd_warned 経路（別 warn）へ逸れ status_warned を exercise しない。
#   show だけを parse 不能にするため BD_SHOW_JSON='this is not json'（_STATUS_PY exit2 → _bead_status rc2 → srrc≠0）。
# ==============================================================================

@test "watch worker（fail-silent 回避・orch-rqp）: gate-pending 存在 × bd show=parse 不能なら発火せず警告して timeout(exit 3)" {
    # 契約 acceptance(1): worker mode で bd list=gate-pending 存在（cur_gp=1）だが bd show=parse 不能で
    #   baseline(updated_at) 確立不能のとき、show 失敗を『完了』と取り違えず warn + exit 3（偽 timeout・fail-safe）。
    export BD_LIST_JSON='[{"id":"orch-shf","title":"gate-pending 存在"}]'   # cur_gp=1（発火条件の gate-pending 側は満たす）
    export BD_SHOW_JSON='this is not json'                                    # _STATUS_PY parse 失敗 → _bead_status rc=2（baseline 確立不能）
    run_dispatch --watch --timeout 0 orch-shf
    [ "$status" -eq 3 ]                                     # 偽 timeout（fail-safe・show 不明を完了と取り違えない）
    [[ "$output" == *"bd show が失敗"* ]]                   # status_warned 経路の warn を surface（warn echo の安定部分文字列）
    [[ "$output" != *"gate-pending になりました"* ]]        # baseline 未確立ゆえ発火しない（誤完了しない）
}

@test "watch worker status_warned（orch-rqp・mutation RED）: warn guard を潰した mutant は bd show 失敗を silent 化する(warn 消失)" {
    # 契約 acceptance(1) の mutation RED: status_warned の warn guard（`[ "$status_warned" -eq 0 ]`）を
    #   never-true へ潰すと warn が抑止され、上の behavioral tooth の warn 断言（`bd show が失敗` を surface）が RED に
    #   反転する＝warn が load-bearing（fail-silent 回避が非vacuous）であることを機械保証する。exit 3 自体は不変ゆえ
    #   warn を消すと「静かに timeout するだけ」＝env 劣化を上位が silent に見逃す旧 fail-silent クラスに退行する。
    # mutant は共有 anchor lib（scripts/lib）を BASH_SOURCE 相対で解決するため、既存 mutation tooth と同型で sandbox に
    #   lib を実 scripts/lib へ symlink する（怠ると偽 mutation＝lib 不在で別経路 die）。
    local sb="$TEST_TMPDIR/mut-showfail-sandbox"; mkdir -p "$sb"
    ln -s "$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)" "$sb/lib"
    local mutant="$sb/orch-dispatch.sh"
    sed 's/"\$status_warned" -eq 0/"$status_warned" -eq 99/' "$SCRIPT" > "$mutant"
    # 変異が実際に適用された（原本には warn guard があり mutant からは消えている）＝非vacuity。
    grep -q '"\$status_warned" -eq 0' "$SCRIPT"
    ! grep -q '"\$status_warned" -eq 0' "$mutant"
    export BD_LIST_JSON='[{"id":"orch-shm","title":"gate-pending 存在"}]'
    export BD_SHOW_JSON='this is not json'
    SCRIPT="$mutant"
    run_dispatch --watch --timeout 0 orch-shm
    [ "$status" -eq 3 ]                                     # exit 3（fail-safe 自体は生きる）
    [[ "$output" != *"bd show が失敗"* ]]                   # warn が抑止され silent 化＝behavioral tooth の warn 断言が RED
}

# ==============================================================================
# (3b) watch admin（orch-5pn）: foreign status 到達 ① OR pane idle ② で完了（success mode）
# ==============================================================================

@test "watch admin（success mode ①）: foreign bead が done-status(closed) に到達したら exit 0" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"closed"}'
    run_dispatch --watch --actor admin --timeout 5 sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"sc-oa9"* ]]
    [[ "$output" == *"foreign 完了"* ]]
}

@test "watch admin（baseline 区別）: 完了は status==done-set のみ・in_progress では timeout（exit 3）" {
    # 「status 変化検出」を「どんな変化でも完了」と取り違えない＝done-set 到達のみが success。
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"in_progress"}'
    run_dispatch --watch --actor admin --timeout 0 sc-oa9
    [ "$status" -eq 3 ]
}

@test "watch admin（success mode ②・pane idle）: status 未到達でも pane が連続無変化なら exit 0" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"in_progress"}'
    printf 'admin idle output\n' > "$TMUX_PANE_DIR/admin-scribe"   # 静的＝毎回同一＝idle
    run_dispatch --watch --actor admin --window admin-scribe --idle-polls 2 --timeout 5 sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"pane idle"* ]]
}

@test "watch admin（done-status 優先）: status が closed なら pane idle 検出前でも foreign 完了で exit 0" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"closed"}'
    printf 'still talking\n' > "$TMUX_PANE_DIR/admin-scribe"
    run_dispatch --watch --actor admin --window admin-scribe --idle-polls 9 --timeout 5 sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
}

@test "watch admin（--resync 委譲）: --resync 指定時に re-sync コマンドが bdw 委譲経路で発火する" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"closed"}'
    [ ! -e "$RESYNC_MARKER" ]
    run_dispatch --watch --actor admin --resync --timeout 5 sc-oa9
    [ "$status" -eq 0 ]
    # 委譲先（ORCH_DISPATCH_RESYNC_CMD=resync-stub）が少なくとも 1 回呼ばれた＝marker 生成。
    [ -e "$RESYNC_MARKER" ]
}

@test "watch admin（resync 無指定は read-only）: --resync 無しなら re-sync コマンドを呼ばない" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"closed"}'
    [ ! -e "$RESYNC_MARKER" ]
    run_dispatch --watch --actor admin --timeout 5 sc-oa9
    [ "$status" -eq 0 ]
    [ ! -e "$RESYNC_MARKER" ]
}

@test "watch admin（window 消失は非致命①）: window が無くても foreign status で完了検出し exit 0（status が authoritative）" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"closed"}'
    # admin-scribe の pane ファイルを作らない＝capture-pane 非0＝window 消失。status closed が先に短絡し完了。
    run_dispatch --watch --actor admin --window admin-scribe --timeout 5 sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
}

@test "watch admin（window 消失は非致命②）: 未完了 + window 消失なら警告して pane 検査を無効化し status poll を継続（timeout 3）" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"in_progress"}'   # done 未到達＝status では完了しない
    # admin-scribe の pane ファイルを作らない＝window 消失。window-gone を warn しつつ foreign status poll は継続→timeout。
    run_dispatch --watch --actor admin --window admin-scribe --timeout 0 sc-oa9
    [ "$status" -eq 3 ]
    [[ "$output" == *"pane idle 検査を無効化"* ]]
}

@test "watch admin: bd-id 無しは die" {
    run_dispatch --watch --actor admin
    [ "$status" -ne 0 ]
}

@test "watch admin（fail-silent 回避）: bd show 失敗を『完了』と誤らず警告して timeout（exit 3）" {
    export BD_FAIL=1
    run_dispatch --watch --actor admin --timeout 0 sc-oa9
    [ "$status" -eq 3 ]
    [[ "$output" == *"bd show が失敗"* ]]
}

@test "watch admin（dry-run）: bd も tmux も叩かず [plan] のみ（副作用ゼロ）" {
    : > "$BD_ARGS_FILE"
    run_dispatch --watch --actor admin --window admin-scribe --dry-run sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [[ "$output" == *"watch(admin)"* ]]
    [ ! -s "$BD_ARGS_FILE" ]
}

@test "watch admin（dry-run・resync 文言の出し分け）: --resync 無しなら read-only と案内し『軽量 hydrate』を出さない" {
    # RESYNC 既定は文字列 "0"（非null）。${RESYNC:+...} だと --resync 未指定でも常に hydrate 文言が出る誤情報を防ぐ。
    run_dispatch --watch --actor admin --dry-run sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"read-only"* ]]
    [[ "$output" != *"軽量 hydrate"* ]]
}

@test "watch admin（dry-run・resync 文言の出し分け）: --resync 有りなら『軽量 hydrate（bdw 委譲）』を案内する" {
    run_dispatch --watch --actor admin --resync --dry-run sc-oa9
    [ "$status" -eq 0 ]
    [[ "$output" == *"軽量 hydrate（bdw 委譲）"* ]]
}

# ==============================================================================
# (3b-baseline) watch admin baseline 方式（orch-edv T2）: watch 開始時に (status,needs-user,updated_at) を
#   baseline 記録し「baseline からの変化」で発火する。silent mutual-wait deadlock の恒久 fix:
#     - 誤発火解消: 既 blocked+needs-user bead を watch 開始しても baseline 不変なら発火しない（旧実装は即時誤発火）。
#     - re-pause 検知: status/label が不変でも updated_at 前進（notes append）で発火する（無変化 transition の取りこぼしを断つ）。
#     - 新規到達: baseline=open/in_progress から done-set への遷移は従来どおり発火（後方互換）。
#     - irreversible 終端（closed）: baseline 不変でも発火（再 pause 不能ゆえ pre-existing でも完了で正しい・pure baseline の regression 回避）。
#   baseline 遷移は bd stub の BD_SHOW_JSON_BASELINE（初回 show）+ BD_SHOW_JSON（2 回目以降）で hermetic に再現。
# ==============================================================================

@test "watch admin baseline（orch-edv T2・誤発火解消）: 既 blocked+needs-user bead は baseline 不変なら発火せず timeout(exit 3)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # baseline も現在も同一（blocked+needs-user・updated_at 不変）＝admin が re-engage していない re-watch 局面。
    # 旧実装（done-set 到達で即発火）はここで即時誤発火し orchestrator が admin を「完了」と誤認→相互デッドロック。
    export BD_SHOW_JSON='{"id":"un-rp","status":"blocked","labels":["needs-user"],"updated_at":"2026-07-02T00:00:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 0 un-rp
    [ "$status" -eq 3 ]
    [[ "$output" == *"INCONCLUSIVE"* ]]
    [[ "$output" != *"foreign 完了"* ]]   # 既 blocked の即時誤発火が解消されている（誤発火解消の核心＝deadlock fix）
}

@test "watch admin baseline（orch-edv T2・re-pause 検知）: blocked+needs-user のまま updated_at 前進で re-pause 発火(exit 0)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # baseline: updated_at=T0 / 以降: 同 status/label だが updated_at=T1（admin が notes append で updated_at 前進＝re-pause）。
    # status/label は不変（無変化 transition）だが baseline sig が変わるため発火する（root cause #1 の取りこぼしを断つ）。
    export BD_SHOW_JSON_BASELINE='{"id":"un-rp2","status":"blocked","labels":["needs-user"],"updated_at":"2026-07-02T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"un-rp2","status":"blocked","labels":["needs-user"],"updated_at":"2026-07-02T00:05:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-rp2
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"re-pause"* ]]        # 発火理由が re-pause（updated_at 前進）と derive される
    [[ "$output" == *"NEEDS-USER"* ]]      # blocked+needs-user は NEEDS-USER で surface
}

@test "watch admin baseline（orch-edv T2・新規到達）: baseline=in_progress から closed へ遷移で新規到達発火(exit 0)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    export BD_SHOW_JSON_BASELINE='{"id":"un-na","status":"in_progress","updated_at":"2026-07-02T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"un-na","status":"closed","updated_at":"2026-07-02T00:05:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-na
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"新規到達"* ]]
    [[ "$output" == *"DONE"* ]]
}

@test "watch admin baseline（orch-edv T2・closed は baseline 不変でも発火）: irreversible 終端は即発火(後方互換・regression 回避)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # closed は再 pause 不能ゆえ pre-existing でも「完了」で正しい（admin 完了検出の後方互換＝pure baseline の regression 回避）。
    export BD_SHOW_JSON='{"id":"un-cl","status":"closed","updated_at":"2026-07-02T00:00:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-cl
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"DONE"* ]]
    [[ "$output" == *"irreversible"* ]]
}

# ==============================================================================
# (3b-m3r) watch admin 発火軸B（orch-m3r）: status=open の NEEDS-USER park 検知漏れを塞ぐ。
#   実測 incident（2026-07-05 の第2バンドル・scp-bou）: foreign admin が NEEDS-USER park を
#   needs-user ラベル+notes append で宣言したが status を open のまま残したため、旧 admin watch
#   （success=status∈{closed,blocked}＝軸A のみ）が 30 分 timeout まで無発火＝park 検知漏れ。
#   defense-in-depth として、status が done-set 外でも needs-user ラベル park が baseline から変化
#   （ラベル遷移 or ラベル保持中の updated_at 前進）したら発火する軸B を追加。軸B も baseline 方式ゆえ
#   既 needs-user な bead の re-watch では誤発火しない（baseline 方式維持＝acceptance 2）。
#   baseline 遷移は bd stub の BD_SHOW_JSON_BASELINE（初回 show）+ BD_SHOW_JSON（2 回目以降）で hermetic に再現。
# ==============================================================================

@test "watch admin 軸B（orch-m3r・acceptance 1）: status=open+needs-user ラベル+notes append の park を発火する(exit 0)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # baseline=open(未 park・needs-user なし) → open+needs-user+updated_at 前進(park 宣言) の遷移を再現。
    # status は open のまま（done-set 外）＝旧軸A は無発火だった穴を軸B が status 非依存で拾う。
    export BD_SHOW_JSON_BASELINE='{"id":"scp-op","status":"open","updated_at":"2026-07-05T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"scp-op","status":"open","labels":["gate-pending","needs-user"],"updated_at":"2026-07-05T00:05:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 scp-op
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"NEEDS-USER"* ]]      # status=open でも needs-user park は NEEDS-USER で surface 区別
    [[ "$output" == *"軸B"* ]]             # status 非依存の park 検知（orch-m3r）と derive
    [[ "$output" != *"=BLOCKED"* ]]        # plain BLOCKED と取り違えない
}

@test "watch admin 軸B（orch-m3r・acceptance 2・誤発火なし）: status=open+needs-user が baseline 不変なら発火せず timeout(exit 3)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # 武装時に既に open+needs-user（baseline 不変）＝admin が re-engage していない re-watch 局面。
    # 軸B も baseline 方式ゆえ即時誤発火しない（baseline 方式維持＝acceptance 2 の核心）。
    export BD_SHOW_JSON='{"id":"scp-op2","status":"open","labels":["needs-user"],"updated_at":"2026-07-05T00:00:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 0 scp-op2
    [ "$status" -eq 3 ]
    [[ "$output" == *"INCONCLUSIVE"* ]]
    [[ "$output" != *"foreign 完了"* ]]    # 既 needs-user baseline の即時誤発火が解消されている（acceptance 2）
}

@test "watch admin 軸B（orch-m3r・re-pause）: status=open+needs-user のまま updated_at 前進で park 再宣言発火(exit 0)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # baseline=open+needs-user T0 → 同 status/label だが updated_at=T1（notes append で re-pause）。status 非依存で軸B が拾う。
    export BD_SHOW_JSON_BASELINE='{"id":"scp-op3","status":"open","labels":["needs-user"],"updated_at":"2026-07-05T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"scp-op3","status":"open","labels":["needs-user"],"updated_at":"2026-07-05T00:05:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 scp-op3
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"再宣言"* ]]          # 発火理由が re-pause（updated_at 前進）と derive される
    [[ "$output" == *"NEEDS-USER"* ]]
}

@test "watch admin 軸B（orch-m3r・非vacuity）: needs-user ラベル無き open の updated_at 前進は発火しない(INCONCLUSIVE・timeout 3)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # 軸B は needs-user ラベル park のみ拾う（status=open の単なる進捗＝宣言なき間は INCONCLUSIVE のまま・orch-mot 不変）。
    # これを落とすと軸B が「open が動いたら何でも完了」に退化する（宣言なき終了を DONE にしない原則を破る）＝過検出 guard。
    # baseline=open(nu0) → in_progress(nu0)+updated_at 前進 を 2 poll で評価しても軸B（nu==1 gate）は発火しない。
    export BD_SHOW_JSON_BASELINE='{"id":"scp-op4","status":"open","updated_at":"2026-07-05T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"scp-op4","status":"in_progress","updated_at":"2026-07-05T00:05:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 2 scp-op4
    [ "$status" -eq 3 ]
    [[ "$output" == *"INCONCLUSIVE"* ]]
    [[ "$output" != *"foreign 完了"* ]]
}

@test "watch admin 軸B（orch-m3r・dry-run 案内）: plan に status=open needs-user park の発火軸B を案内する" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    run_dispatch --watch --actor admin --foreign-repo "$FR" --dry-run scp-op5
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [[ "$output" == *"発火軸B"* ]]
    [[ "$output" == *"status=open"* ]]      # status=open park の検知漏れを塞ぐ旨を plan で明示
}

# ==============================================================================
# (3c') watch admin 軸C（orch-o0b・gate-pending park 終端形）: foreign admin の human-ratify フローは
#       自己 close 禁止ゆえ終端形が『gate-pending ラベル + status=in_progress のまま』になる。軸A(done-set)・
#       軸B(needs-user park) は拾えず 30 分 timeout していた（incident 2026-07-06 scp-bou.6 / cm-3qb）。
#       軸C = gate-pending ラベルの baseline 変化（(i) 0→1 遷移〔updated_at 不変でも〕 or (ii) 保持中の
#       updated_at 前進〔errata 再宣言〕）で発火（軸B と同型・baseline 方式維持ゆえ既 gate-pending の
#       再武装で誤発火しない）。★needs-user 混入禁止＝軸B 経由で現行コードでも緑=偽 DONE になるため
#       （PROBE 実測: gate-pending のみ→現行 exit 3 / needs-user 混入→現行 exit 0）。以下の acceptance teeth は
#       すべて labels=gate-pending のみ（precedence teeth のみ意図的に混在させ decl 順位を固定する）。
# ==============================================================================

@test "watch admin 軸C（orch-o0b・acceptance 1-i）: status=in_progress + gate-pending 0→1 遷移（needs-user 無し・updated_at 不変）を発火する(exit 0)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # baseline=in_progress（未 gate-pending）→ in_progress + gate-pending ラベル付与。status は done-set 外のまま。
    # updated_at は不変（T0=T0）＝ラベル 0→1 遷移そのもので発火することの teeth（baseline_gp==0 disjunct）。
    export BD_SHOW_JSON_BASELINE='{"id":"scp-gp1","status":"in_progress","updated_at":"2026-07-06T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"scp-gp1","status":"in_progress","labels":["gate-pending"],"updated_at":"2026-07-06T00:00:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 scp-gp1
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"GATE-PENDING"* ]]     # gate-pending 専用 surface
    [[ "$output" == *"軸C"* ]]              # gate-pending park 検知（orch-o0b）と derive
    [[ "$output" != *"TERMINAL"* ]]         # done-set 外を TERMINAL と誤表示しない（核心・acceptance 1）
    [[ "$output" != *"軸B"* ]]              # needs-user park（軸B）と取り違えない
    [[ "$output" != *"NEEDS-USER"* ]]
}

@test "watch admin 軸C（orch-o0b・acceptance 1-ii）: 既 gate-pending 保持中の updated_at 前進（errata 再宣言）で発火する(exit 0)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # baseline=in_progress + gate-pending T0 → 同 status/label だが updated_at=T1（errata の notes append で前進）。
    export BD_SHOW_JSON_BASELINE='{"id":"scp-gp2","status":"in_progress","labels":["gate-pending"],"updated_at":"2026-07-06T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"scp-gp2","status":"in_progress","labels":["gate-pending"],"updated_at":"2026-07-06T01:00:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 scp-gp2
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"GATE-PENDING"* ]]
    [[ "$output" == *"再宣言"* ]]           # updated_at 前進＝errata 再宣言と derive
    [[ "$output" == *"軸C"* ]]
    [[ "$output" != *"TERMINAL"* ]]
    [[ "$output" != *"軸B"* ]]
}

@test "watch admin 軸C（orch-o0b・acceptance 2・誤発火なし）: 既 gate-pending が baseline 不変なら発火せず timeout(exit 3)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # 武装時に既に in_progress + gate-pending（baseline 不変）＝再武装局面。baseline 方式ゆえ即時誤発火しない。
    export BD_SHOW_JSON='{"id":"scp-gp3","status":"in_progress","labels":["gate-pending"],"updated_at":"2026-07-06T00:00:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 0 scp-gp3
    [ "$status" -eq 3 ]
    [[ "$output" == *"INCONCLUSIVE"* ]]
    [[ "$output" != *"foreign 完了"* ]]     # 既 gate-pending baseline の即時誤発火が解消されている（acceptance 2）
}

@test "watch admin 軸C（orch-o0b・mutation RED）: baseline_gp capture を潰した mutant は武装時 既 gate-pending で即発火(exit 0)" {
    # 契約 acceptance(3): baseline_gp の capture を 0 固定に潰すと baseline 抑止が無効化され、上の suppress teeth
    #   （既 gate-pending・無更新→exit 3）が exit 0 に反転する＝抑止ロジックが load-bearing（非vacuous）と機械保証。
    #   orch-y9z worker mutation（本 bats の対応 test）と同型。共有 lib は sandbox に symlink して BASH_SOURCE 相対解決を成立させる。
    #   sed パターンは admin 固有 `baseline_gp="$gp"`（worker は `baseline_gp="$cur_gp"` ＝別文字列ゆえ非対象）。
    local sb="$TEST_TMPDIR/mut-sandbox-c"; mkdir -p "$sb"
    ln -s "$(cd "$BATS_TEST_DIRNAME/../../scripts/lib" && pwd)" "$sb/lib"
    local mutant="$sb/orch-dispatch.sh"
    sed 's/baseline_gp="\$gp"/baseline_gp=0/' "$SCRIPT" > "$mutant"
    grep -q 'baseline_gp="\$gp"' "$SCRIPT"          # 原本に admin baseline_gp capture がある
    ! grep -q 'baseline_gp="\$gp"' "$mutant"        # mutant からは消えている（非vacuity）
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    export BD_SHOW_JSON='{"id":"scp-gpm","status":"in_progress","labels":["gate-pending"],"updated_at":"2026-07-06T00:00:00Z"}'
    SCRIPT="$mutant"
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 0 scp-gpm
    [ "$status" -eq 0 ]                              # mutant は baseline 抑止を失い即発火（誤発火）
    [[ "$output" == *"GATE-PENDING"* ]]
}

@test "watch admin 軸C（orch-o0b・precedence）: needs-user + gate-pending 同居は NEEDS-USER（軸B）が優先し GATE-PENDING と誤表示しない" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # human-ratify 終端形が needs-user も帯びるケース: 人間判断待ち（NEEDS-USER）は gate-pending park より強い
    # signal ゆえ decl/fire_reason で優先する（decl 順位 NEEDS-USER > GATE-PENDING > TERMINAL を固定）。
    export BD_SHOW_JSON_BASELINE='{"id":"scp-gp4","status":"open","updated_at":"2026-07-06T00:00:00Z"}'
    export BD_SHOW_JSON='{"id":"scp-gp4","status":"open","labels":["gate-pending","needs-user"],"updated_at":"2026-07-06T00:05:00Z"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 scp-gp4
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEEDS-USER"* ]]       # needs-user park が優先
    [[ "$output" == *"軸B"* ]]
    [[ "$output" != *"GATE-PENDING"* ]]     # gate-pending は subordinate（decl は NEEDS-USER）
}

@test "watch admin 軸C（orch-o0b・dry-run 案内）: plan に gate-pending park の発火軸C を案内する" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    run_dispatch --watch --actor admin --foreign-repo "$FR" --dry-run scp-gp6
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [[ "$output" == *"発火軸C"* ]]
    [[ "$output" == *"gate-pending"* ]]
}

# ==============================================================================
# (3d) watch admin 直読 poll（orch-ail / orch-mot channel α）: --foreign-repo で同一マシンの foreign 台帳を
#      `bd -C <path> show <id> --json` で hydrate 無しに直接 read する。truth は actor 自身の終端宣言
#      （DONE=closed / BLOCKED=blocked）のみ。宣言なき間（open/in_progress・宣言 bead 未作成）は未完
#      (INCONCLUSIVE)＝決して DONE にしない。bd stub は先頭 `-C <dir>` を剥がし subcommand へ dispatch し、
#      元 argv（-C 込み）を $BD_ARGS_FILE に記録＝直読の証跡を assert できる。
#   契約不変条件（bd orch-ail (3) = ratify 済契約）:
#     (a) 直読 poll が foreign bead の DONE/BLOCKED を正しく拾う。
#     (b) hydrate（bdw repo sync）せず直読する＝race-free（resync stub 不発火 + bd -C 通過）。
#     (c) 宣言なき間は INCONCLUSIVE を返し DONE と誤らない（in_progress / status 不明 → timeout exit 3）。
# ==============================================================================

@test "watch admin 直読（orch-ail・a・DONE）: --foreign-repo で bd -C 直読し status=closed を DONE 完了で拾う" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    export BD_SHOW_JSON='{"id":"un-term1","status":"closed"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-term1
    [ "$status" -eq 0 ]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" == *"DONE"* ]]
    # 直読の証跡: bd が -C <foreign> 付きで・対象 id の show で呼ばれた（hydrated copy でなく foreign を直読）
    grep -q -- "-C $FR" "$BD_ARGS_FILE"
    grep -q -- "show un-term1" "$BD_ARGS_FILE"
}

@test "watch admin 直読（orch-ail・a・BLOCKED）: status=blocked を BLOCKED 終端宣言として拾う（既定 done-set に blocked 含む）" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # orch-edv T2: reversible park（blocked）は baseline からの変化で発火。baseline=in_progress→blocked の遷移を再現。
    export BD_SHOW_JSON_BASELINE='{"id":"un-term2","status":"in_progress"}'
    export BD_SHOW_JSON='{"id":"un-term2","status":"blocked"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-term2
    [ "$status" -eq 0 ]
    [[ "$output" == *"BLOCKED"* ]]
    [[ "$output" == *"foreign 完了"* ]]
    [[ "$output" != *"NEEDS-USER"* ]]   # orch-r5x: needs-user ラベル無き blocked は plain BLOCKED（NEEDS-USER と取り違えない）
}

# orch-r5x: blocked の surface 区別（三値 triad の surface 完全化）。actor が NEEDS-USER を
#   blocked+needs-user ラベルで宣言したら、watch 直読 surface も plain BLOCKED でなく NEEDS-USER と出す。
#   _STATUS_PY が labels を read し 2 列目（needs-user flag）を返す＝両方向（label 有→NEEDS-USER / 無→BLOCKED）を pin。
@test "watch admin 直読（orch-r5x・NEEDS-USER）: status=blocked + needs-user ラベルを NEEDS-USER 終端宣言として surface 区別する" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    # orch-edv T2: reversible park（needs-user）は baseline からの変化で発火。baseline=in_progress→blocked+needs-user の遷移を再現。
    export BD_SHOW_JSON_BASELINE='{"id":"un-nu1","status":"in_progress"}'
    export BD_SHOW_JSON='{"id":"un-nu1","status":"blocked","labels":["needs-user","thread:x"]}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-nu1
    [ "$status" -eq 0 ]
    [[ "$output" == *"NEEDS-USER"* ]]    # blocked+needs-user は plain BLOCKED でなく NEEDS-USER で surface
    [[ "$output" != *"=BLOCKED"* ]]      # decl=BLOCKED と取り違えない（区別の核心）
    [[ "$output" == *"foreign 完了"* ]]  # 完了シグナル自体は出る（blocked は done-set ゆえ）
}

@test "watch admin 直読（orch-ail・b・race-free）: --foreign-repo は hydrate(bdw repo sync)を呼ばず直読する" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    [ ! -e "$RESYNC_MARKER" ]
    export BD_SHOW_JSON='{"id":"un-term3","status":"closed"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 5 un-term3
    [ "$status" -eq 0 ]
    # hydrate 経路（resync 委譲）は一切発火しない＝直読は sync を介さない（同一マシン race-free の構造保証）
    [ ! -e "$RESYNC_MARKER" ]
    grep -q -- "-C $FR" "$BD_ARGS_FILE"
}

@test "watch admin 直読（orch-ail・b・排他）: --foreign-repo と --resync は同時指定で die（直読は sync 不要）" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    [ ! -e "$RESYNC_MARKER" ]
    run_dispatch --watch --actor admin --foreign-repo "$FR" --resync --timeout 5 un-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"同時指定できません"* ]]
    [ ! -e "$RESYNC_MARKER" ]      # die 先行＝resync は発火しない
}

@test "watch admin 直読（orch-ail・c・INCONCLUSIVE）: 宣言なき間(in_progress)は DONE にせず未完で timeout(exit 3)" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    export BD_SHOW_JSON='{"id":"un-term4","status":"in_progress"}'
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 0 un-term4
    [ "$status" -eq 3 ]
    [[ "$output" == *"INCONCLUSIVE"* ]]
    [[ "$output" != *"foreign 完了"* ]]   # 終端宣言なき間を DONE と誤らない（contract (c) 核心）
}

@test "watch admin 直読（orch-ail・c・宣言 bead 未作成も INCONCLUSIVE）: status 不明(宣言なし)を DONE にせず timeout" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    export BD_SHOW_JSON='{}'   # status フィールド無し＝終端宣言なし（actor が宣言 bead を未作成相当）
    run_dispatch --watch --actor admin --foreign-repo "$FR" --timeout 0 un-term5
    [ "$status" -eq 3 ]
    [[ "$output" == *"INCONCLUSIVE"* ]]
    [[ "$output" != *"foreign 完了"* ]]
}

@test "watch 直読（orch-ail・admin 専用）: --foreign-repo を worker に渡すと die（worker は自台帳 gate-pending ラベル）" {
    run_dispatch --watch --actor worker --foreign-repo "$TEST_TMPDIR/x" --timeout 5 orch-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"admin 専用"* ]]
}

@test "watch admin 直読（orch-ail・path fail-closed）: --foreign-repo のパス不在は die（誤 path を無言 poll しない）" {
    run_dispatch --watch --actor admin --foreign-repo "$TEST_TMPDIR/nonexistent" --timeout 5 un-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"存在しません"* ]]
}

@test "watch admin 直読（orch-ail・dry-run）: --foreign-repo の plan に直読(race-free)を案内し副作用ゼロ" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    : > "$BD_ARGS_FILE"
    run_dispatch --watch --actor admin --foreign-repo "$FR" --dry-run un-term6
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [[ "$output" == *"直読"* ]]
    [[ "$output" == *"race-free"* ]]
    [[ "$output" == *"INCONCLUSIVE"* ]]   # 宣言なき間/timeout を DONE にしない方針を plan で明示
    [ ! -s "$BD_ARGS_FILE" ]              # bd 不発火（read-only な plan）
}

# ==============================================================================
# (3c) watch generic（orch-5pn）: pane idle のみで完了・window 消失=exit 4
# ==============================================================================

@test "watch generic（success mode）: pane が連続無変化なら exit 0" {
    printf 'generic done\n' > "$TMUX_PANE_DIR/win-x"
    run_dispatch --watch --actor generic --window win-x --idle-polls 2 --timeout 5
    [ "$status" -eq 0 ]
    [[ "$output" == *"pane idle"* ]]
}

@test "watch generic（window 消失）: window が消えたら exit 4（actor 終了・完了不定で surface・success と混同しない）" {
    # win-gone の pane ファイルを作らない＝capture-pane 非0。
    run_dispatch --watch --actor generic --window win-gone --idle-polls 2 --timeout 5
    [ "$status" -eq 4 ]
    [[ "$output" == *"消失"* ]]
}

@test "watch generic（timeout）: pane が変化し続け idle 未達なら exit 3" {
    # idle-polls を大きくして timeout 0 で即終端＝静的 pane でも idle 未達のまま期限切れ。
    printf 'x\n' > "$TMUX_PANE_DIR/win-busy"
    run_dispatch --watch --actor generic --window win-busy --idle-polls 99 --timeout 0
    [ "$status" -eq 3 ]
}

@test "watch generic: --window 無しは die（pane idle が唯一の完了シグナル）" {
    run_dispatch --watch --actor generic --timeout 5
    [ "$status" -ne 0 ]
}

@test "watch: 未知の --actor は die（worker|admin|generic 以外）" {
    run_dispatch --watch --actor bogus --timeout 5 orch-x
    [ "$status" -ne 0 ]
    [[ "$output" == *"actor"* ]]
}

@test "watch admin（算術注入 regression）: --timeout 注入ペイロードでもコマンドが実行されない" {
    local marker="$TEST_TMPDIR/PWNED_ADMIN"
    [ ! -e "$marker" ]
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"in_progress"}'
    run_dispatch --watch --actor admin --timeout "SECONDS[\$(touch $marker)]" sc-oa9
    [ "$status" -ne 0 ]
    [ ! -e "$marker" ]
}

@test "watch admin: 非正の --idle-polls は die（pane idle が即発火する誤判定を防ぐ）" {
    export BD_SHOW_JSON='{"id":"sc-oa9","status":"in_progress"}'
    run_dispatch --watch --actor admin --window admin-scribe --idle-polls 0 --timeout 5 sc-oa9
    [ "$status" -ne 0 ]
}

# ==============================================================================
# (5) liveness sweep（orch-edv T3・silent mutual-wait deadlock backstop）: read-only 単発 sweep で
#     spawn window（wt-*/admin-*）× 対応 bead（自台帳 + --foreign-repo）を突合し 2 停滞シグナルを surface する:
#       ① decision-point 停滞（needs-user/gate-pending が N 分以上 park）
#       ② window 生存 × bead 無更新/不在（N 分以上）
#     mutate しない（起票/dispatch/label しない＝read のみ）。tmux は list-panes（read-only）で window を列挙、
#     bd は list/show（read-only）のみ。age は ORCH_DISPATCH_NOW_EPOCH で固定して決定的に検証する。
# ==============================================================================

@test "liveness（dry-run）: bd も tmux も叩かず [plan] のみ（副作用ゼロ・read-only 明示）" {
    : > "$BD_ARGS_FILE"
    run_dispatch --liveness --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    [[ "$output" == *"liveness sweep"* ]]
    [[ "$output" == *"read-only"* ]]
    [ ! -s "$BD_ARGS_FILE" ]
}

@test "liveness（window 列挙）: wt-*/admin-* spawn window を『生存』一覧に出し、非 spawn window(main)は出さない" {
    printf 'wt-orch-abc\nadmin-projalpha\nmain\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"   # wt-orch-abc は不在=宣言 bead 未作成扱い
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"spawn window（生存）"* ]]
    [[ "$output" == *"wt-orch-abc"* ]]
    [[ "$output" == *"admin-projalpha"* ]]
    # 非 spawn window(main)は生存一覧に出さない（wt-/admin- 接頭辞のみ）
    local win_section; win_section=$(printf '%s\n' "$output" | sed -n '/spawn window（生存）/,/decision-point/p')
    printf '%s\n' "$win_section" | grep -qx '  orch:main' && return 1
    printf '%s\n' "$win_section" | grep -qx '  main' && return 1
    return 0
}

@test "liveness（topology orch-riz1・teeth a）: 素 admin 窓（window 名=admin）が session:window 正準形 <project>:admin で生存一覧に現れる" {
    # 裁定 orch-thgx: admin 宛先正準形 `<project>:admin`。素 admin 窓が session 修飾付きで surface することを pin する。
    #   bare-name 退行 mutation（`_liveness_windows` を `#{window_name}` + `^(wt-|admin-)` へ戻す）では、format 依存の
    #   tmux stub が window_name のみ（`admin`）を emit し `^admin-` に非合致→素 admin 窓が消え本 assert が RED になる。
    printf 'projalpha:admin\nwt-orch-liveA\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    local win_section; win_section=$(printf '%s\n' "$output" | sed -n '/spawn window（生存）/,/decision-point/p')
    printf '%s\n' "$win_section" | grep -qF 'projalpha:admin'    # 素 admin 窓が :admin 正準形で surface（teeth a）
}

@test "liveness（topology orch-riz1・teeth b）: <session>:wt-<id> から session prefix を剥がして正しく id を抽出し self bead を突合する" {
    # 単一 format 化で wt-<id> も session 修飾される。下流 ③ の id 抽出は `${w##*:}` で window_name を取り出す。
    #   downstream を `id=${w#wt-}` + `case "$w" in wt-*)` へ戻す mutation は、session 修飾付き `myproj:wt-orch-stallB`
    #   が `wt-*` に非合致→continue で cell を取りこぼし『silent stall 疑い』が消える→RED（非vacuity）。
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'myproj:wt-orch-stallB\n' > "$TMUX_WINDOWS_FILE"   # 本物の session 修飾（default 合成でない）
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-stallB","status":"in_progress","updated_at":"%s"}' "$stale_iso" > "$BD_SHOW_DIR/orch-stallB"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"myproj:wt-orch-stallB"* ]]     # session 修飾付きで surface
    [[ "$output" == *"silent stall 疑い"* ]]          # id=orch-stallB が正しく抽出され self bead 突合が成立
    [[ "$output" == *"無更新 60m"* ]]
}

@test "liveness（decision-point 停滞・self）: needs-user が N 分以上 park なら age 付きで surface（fresh は出さない）" {
    local stale_iso fresh_iso
    stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)   # 60 分前 → stale(>30)
    fresh_iso=$(date -u -d "@$((1751000000 - 300))"  +%Y-%m-%dT%H:%M:%SZ)   # 5 分前 → fresh(<30)
    : > "$TMUX_WINDOWS_FILE"   # window なし＝③は該当なし（②に集中）
    export BD_LIST_JSON="[{\"id\":\"orch-park1\",\"status\":\"blocked\",\"labels\":[\"needs-user\"],\"updated_at\":\"$stale_iso\"},{\"id\":\"orch-fresh1\",\"status\":\"blocked\",\"labels\":[\"needs-user\"],\"updated_at\":\"$fresh_iso\"}]"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-park1"* ]]         # stale は surface
    [[ "$output" == *"停滞 60m"* ]]           # age 換算
    [[ "$output" != *"orch-fresh1"* ]]        # fresh(<閾値)は出さない（誤検出回避）
}

@test "liveness（decision-point 停滞・gate-pending も対象）: gate-pending park も停滞として surface する" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON="[{\"id\":\"orch-gp1\",\"status\":\"in_progress\",\"labels\":[\"gate-pending\"],\"updated_at\":\"$stale_iso\"}]"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-gp1"* ]]
    [[ "$output" == *"gate-pending"* ]]
    [[ "$output" == *"停滞 60m"* ]]
}

@test "liveness（decision-point 停滞・foreign）: --foreign-repo の park bead は [foreign] タグ付きで surface" {
    local FR="$TEST_TMPDIR/foreign-ledger"; mkdir -p "$FR/.beads"
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'   # self は park なし
    export BD_LIST_JSON_FOREIGN="[{\"id\":\"un-smnk\",\"status\":\"blocked\",\"labels\":[\"needs-user\"],\"updated_at\":\"$stale_iso\"}]"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness --foreign-repo "$FR"
    [ "$status" -eq 0 ]
    [[ "$output" == *"un-smnk"* ]]            # foreign の park bead が surface（cross-ledger read）
    [[ "$output" == *"[foreign]"* ]]          # foreign タグで self と区別
    # foreign を直読した証跡（bd -C <FR> list が呼ばれた）
    grep -q -- "-C $FR" "$BD_ARGS_FILE"
}

@test "liveness（window×bead・silent stall）: wt-<id> window 生存 + self bead 無更新 N 分で silent stall を surface" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-stall\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-stall","status":"in_progress","updated_at":"%s"}' "$stale_iso" > "$BD_SHOW_DIR/orch-stall"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-stall"* ]]
    [[ "$output" == *"silent stall 疑い"* ]]
    [[ "$output" == *"無更新 60m"* ]]
}

@test "liveness（window×bead・宣言 bead 不在）: wt-<id> window 生存だが self bead が見つからないと不在で surface" {
    printf 'wt-orch-nobead\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"   # orch-nobead のファイルを置かない＝not-found
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-nobead"* ]]
    [[ "$output" == *"bead orch-nobead 不在"* ]]
    [[ "$output" == *"宣言 bead 未作成"* ]]
}

@test "liveness（window×bead・fresh は誤検出しない）: wt-<id> 生存 + self bead が新鮮なら window 停滞に出さない" {
    local fresh_iso; fresh_iso=$(date -u -d "@$((1751000000 - 300))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-live\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-live","status":"in_progress","updated_at":"%s"}' "$fresh_iso" > "$BD_SHOW_DIR/orch-live"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    # window 停滞節は該当なし（fresh ゆえ silent stall にしない・誤検出回避）
    local wb_section; wb_section=$(printf '%s\n' "$output" | sed -n '/window 生存 × bead/,$p')
    printf '%s\n' "$wb_section" | grep -q '該当なし'
    [[ "$output" != *"silent stall 疑い"* ]]
}

@test "liveness（terminal bead は window 停滞にしない）: wt-<id> 生存 + self bead が closed/blocked は silent stall 扱いしない" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-done\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-done","status":"closed","updated_at":"%s"}' "$stale_iso" > "$BD_SHOW_DIR/orch-done"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    # closed は gate/cleanup 待ちの別軸ゆえ silent stall にしない（該当なし）
    local wb_section; wb_section=$(printf '%s\n' "$output" | sed -n '/window 生存 × bead/,$p')
    printf '%s\n' "$wb_section" | grep -q '該当なし'
}

# ── SPAWNED marker smoke（orch-gv9・C案 検知側・liveness ②）───────────────────────────────
#   marker 契約: worker が起動直後に自 bead notes へ行頭 `[SPAWNED--<id>]` を書く。stale cell の marker 不在で
#   宣言 write 断絶（external repo cell の sandbox sever）を機械検知する。既定 on（ORCH_DISPATCH_SPAWN_SMOKE=0 で off・
#   書込側 sc-0df land 済みゆえ orch-qof 裁定 B 2026-07-10 で既定 flip。off 時の出力は従来 byte 同一を維持）。

@test "liveness smoke（既定 on）: SPAWN_SMOKE 未指定でも stale cell に marker 弁別注記を付ける（orch-qof 裁定 B の既定 flip を pin）" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-dflt\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # env 未指定（既定）で marker 無し stale cell → 断絶疑い注記が出る＝既定 on。既定を 0 へ戻す退行で RED になる。
    printf '{"id":"orch-dflt","status":"in_progress","updated_at":"%s","notes":"進捗ログ（marker 無し）"}' "$stale_iso" > "$BD_SHOW_DIR/orch-dflt"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-dflt"* ]]
    [[ "$output" == *"SPAWNED marker 不在"* ]]
    [[ "$output" == *"宣言 write 断絶疑い"* ]]
}

@test "liveness smoke（明示 off・回帰）: SPAWN_SMOKE=0 なら stale cell に marker 注記を一切付けない（従来 byte 同一）" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-nomk\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # notes に marker が無い stale cell だが、smoke off ゆえ marker 弁別注記は出ない（従来どおり silent stall のみ）。
    printf '{"id":"orch-nomk","status":"in_progress","updated_at":"%s","notes":"進捗ログ"}' "$stale_iso" > "$BD_SHOW_DIR/orch-nomk"
    ORCH_DISPATCH_SPAWN_SMOKE=0 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"silent stall 疑い"* ]]
    [[ "$output" == *"無更新 60m"* ]]
    [[ "$output" != *"SPAWNED marker"* ]]
    [[ "$output" != *"宣言 write 断絶"* ]]
}

@test "liveness smoke（on・marker 不在）: SPAWN_SMOKE=1 + stale + marker 無しは『宣言 write 断絶疑い』を surface" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-sever\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-sever","status":"in_progress","updated_at":"%s","notes":"進捗ログ（marker 無し）"}' "$stale_iso" > "$BD_SHOW_DIR/orch-sever"
    ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-sever"* ]]
    [[ "$output" == *"SPAWNED marker 不在"* ]]
    [[ "$output" == *"宣言 write 断絶疑い"* ]]
    # advisory ＝read-only・write 系は一切発行しない（spawn abort しない・design(2)）
    ! grep -qE '(^| )(update|close|create|dep)( |$)' "$BD_ARGS_FILE"
}

@test "liveness smoke（on・marker 有）: SPAWN_SMOKE=1 + stale + marker 有は『write 経路生存の別要因 stall』と弁別する" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-live2\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # notes 先頭に行頭 marker（worker が起動直後に書いた体）。stale だが write 経路は生存＝別要因の stall。
    printf '{"id":"orch-live2","status":"in_progress","updated_at":"%s","notes":"[SPAWNED--orch-live2]\\n以降の進捗ログ"}' "$stale_iso" > "$BD_SHOW_DIR/orch-live2"
    ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWNED marker 有"* ]]
    [[ "$output" != *"宣言 write 断絶疑い"* ]]
    [[ "$output" == *"silent stall 疑い"* ]]
}

@test "liveness smoke（on・fresh は marker check しない）: SPAWN_SMOKE=1 でも新鮮 cell は marker 不在でも surface しない（誤検出回避・design(2)）" {
    local fresh_iso; fresh_iso=$(date -u -d "@$((1751000000 - 300))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-fresh2\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-fresh2","status":"in_progress","updated_at":"%s","notes":"まだ marker 未書込"}' "$fresh_iso" > "$BD_SHOW_DIR/orch-fresh2"
    ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    # fresh（age<閾値）は stale 枝に入らず marker check を掛けない＝該当なし（起動途中の false sever を出さない）
    [[ "$output" != *"宣言 write 断絶疑い"* ]]
    local wb_section; wb_section=$(printf '%s\n' "$output" | sed -n '/window 生存 × bead/,$p')
    printf '%s\n' "$wb_section" | grep -q '該当なし'
}

@test "liveness smoke（on・marker prefix 衝突回避）: 行中の SPAWNED-- 様文字列は marker と誤認しない（行頭アンカー・orch-8hp）" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-anchor\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # 行の途中に "[SPAWNED--" 様の文字列があっても行頭アンカーゆえ marker とみなさない＝不在扱い（断絶疑い）。
    printf '{"id":"orch-anchor","status":"in_progress","updated_at":"%s","notes":"本文中に foo [SPAWNED--x] を引用しただけ"}' "$stale_iso" > "$BD_SHOW_DIR/orch-anchor"
    ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWNED marker 不在"* ]]
}

@test "liveness smoke（on・dry-run plan）: SPAWN_SMOKE=1 の dry-run は ③+ smoke 軸を plan に案内し bd を叩かない" {
    ORCH_DISPATCH_SPAWN_SMOKE=1 run_dispatch --liveness --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"SPAWN_SMOKE=1"* ]]
    [[ "$output" == *"宣言 write 断絶疑い"* ]]
    # dry-run は read-only plan のみ＝bd を一切叩かない（副作用ゼロ）
    [ ! -s "$BD_ARGS_FILE" ] || ! grep -qE '(show|list)' "$BD_ARGS_FILE"
}

# ── orch-qof teeth 補強（on 化前・gate 指摘 wf_0f371b36）──────────────────────────────
#   gap-A=rc2 fail-safe 分岐 pin（2 回目 bd read のみ失敗）/ gap-B=実 bd 配列形[{...}] で _NOTES_PY unwrap 分岐 pin
#   （MUT5 素通り封鎖）/ gap-C=marker 有/無混在 2+ cell の 1 run 弁別。self-dev cell の write 断絶診断も含む broaden 後。

@test "liveness smoke（on・gap-A rc2 判定不能）: 2 回目 bd read（marker read）のみ失敗で『判定不能（sever 断定せず）』注記を付す" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-a2\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # notes には marker 有り（read が両方成功していれば「有」になる）。だが 2 回目 show（marker read）だけを落として
    #   _spawned_marker_present rc=2「判定不能」枝を狙い撃つ（＝marker 有無でなく bd read 障害由来の分岐を pin）。
    printf '{"id":"orch-a2","status":"in_progress","updated_at":"%s","notes":"[SPAWNED--orch-a2]\\n進捗"}' "$stale_iso" > "$BD_SHOW_DIR/orch-a2"
    BD_SHOW_FAIL_ON_COUNT=2 ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-a2"* ]]
    # status read（call1）は成功＝stale 枝へ入る。marker read（call2）が落ちて rc=2 → 判定不能。
    [[ "$output" == *"SPAWNED marker 判定不能"* ]]
    # sever 断定しない（fail-safe）＝断絶疑いにも marker 有にも倒さない。
    [[ "$output" != *"宣言 write 断絶疑い"* ]]
    [[ "$output" != *"SPAWNED marker 有"* ]]
    # advisory ＝write 系を一切発行しない（read-only）
    ! grep -qE '(^| )(update|close|create|dep)( |$)' "$BD_ARGS_FILE"
}

@test "liveness smoke（on・gap-A' parse-fail rc2）: marker read が壊れ JSON（bd 成功 × parse 失敗）でも『判定不能（sever 断定せず）』へ落とす" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-a3\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # rc=2「判定不能」の第2 modality: bd show は成功（rc=0）だが notes が非 JSON で _NOTES_PY が sys.exit(2)。
    #   gap-A（bd-read 失敗＝rc≠0）が触れない parse-fail 枝を pin する。核安全性=読めない notes で sever を断定しない。
    printf '{"id":"orch-a3","status":"in_progress","updated_at":"%s","notes":"[SPAWNED--orch-a3]\\n進捗"}' "$stale_iso" > "$BD_SHOW_DIR/orch-a3"
    BD_SHOW_BADJSON_ON_COUNT=2 ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-a3"* ]]
    # marker read の parse 失敗→rc=2→判定不能（bd-read 失敗と同じ fail-safe 注記）。
    [[ "$output" == *"SPAWNED marker 判定不能"* ]]
    # sever を断定しない＝断絶疑いにも marker 有にも倒さない（false positive で生存 cell を殺さない核安全性）。
    [[ "$output" != *"宣言 write 断絶疑い"* ]]
    [[ "$output" != *"SPAWNED marker 有"* ]]
    ! grep -qE '(^| )(update|close|create|dep)( |$)' "$BD_ARGS_FILE"
}

@test "liveness smoke（on・gap-B array unwrap）: 実 bd 配列形[{...}] の notes でも _NOTES_PY unwrap で marker 有を検知（MUT5 封鎖）" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-b2\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # 実 bd show --json は object でなく 1 要素配列 [{...}] を返す。stub をその実形へ寄せ、_NOTES_PY / _STATUS_PY の
    #   list-unwrap（data=data[0]）分岐を実際に通す。unwrap が壊れると list のまま dict 化されず判定不能へ落ち「有」を失う。
    printf '[{"id":"orch-b2","status":"in_progress","updated_at":"%s","notes":"[SPAWNED--orch-b2]\\n以降の進捗"}]' "$stale_iso" > "$BD_SHOW_DIR/orch-b2"
    ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-b2"* ]]
    [[ "$output" == *"SPAWNED marker 有"* ]]
    [[ "$output" != *"宣言 write 断絶疑い"* ]]
    [[ "$output" != *"判定不能"* ]]
}

@test "liveness smoke（on・gap-C 混在弁別）: 1 run で marker 有 cell と marker 不在 cell を per-cell に弁別する" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-c1\nwt-orch-c2\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    # c1=marker 有（write 経路生存）/ c2=marker 不在（断絶疑い）。同一 run で 2 cell を独立判定でき、
    #   注記が per-cell に取り違わらないことを pin（global flag へ潰れていない）。
    printf '{"id":"orch-c1","status":"in_progress","updated_at":"%s","notes":"[SPAWNED--orch-c1]\\n進捗"}' "$stale_iso" > "$BD_SHOW_DIR/orch-c1"
    printf '{"id":"orch-c2","status":"in_progress","updated_at":"%s","notes":"marker 未書込の進捗ログ"}' "$stale_iso" > "$BD_SHOW_DIR/orch-c2"
    ORCH_DISPATCH_SPAWN_SMOKE=1 ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    local c1_line c2_line
    c1_line=$(printf '%s\n' "$output" | grep 'wt-orch-c1')
    c2_line=$(printf '%s\n' "$output" | grep 'wt-orch-c2')
    # c1 行は「有」で断絶疑いを付けない。c2 行は「不在」で断絶疑いを付ける。行単位で交差しない。
    [[ "$c1_line" == *"SPAWNED marker 有"* ]]
    [[ "$c1_line" != *"宣言 write 断絶疑い"* ]]
    [[ "$c2_line" == *"SPAWNED marker 不在"* ]]
    [[ "$c2_line" == *"宣言 write 断絶疑い"* ]]
}

@test "liveness（read-only 不変条件）: bd は list/show のみ・write 系サブコマンドを一切発行しない" {
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    printf 'wt-orch-x\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON="[{\"id\":\"orch-park9\",\"status\":\"blocked\",\"labels\":[\"needs-user\"],\"updated_at\":\"$stale_iso\"}]"
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    # write 系（update/close/create/label add/dolt push/dep）は一度も呼ばれない（surface のみ＝mutate しない）
    ! grep -qE '(^| )(update|close|create|dep|import|batch|sql)( |$)' "$BD_ARGS_FILE"
    ! grep -q 'label add' "$BD_ARGS_FILE"
    ! grep -q 'dolt push' "$BD_ARGS_FILE"
    # list は read として呼ばれている（sweep が動いた非vacuous 証明）
    grep -q '^list ' "$BD_ARGS_FILE" || grep -q ' list ' "$BD_ARGS_FILE"
}

@test "liveness（foreign-repo path fail-closed）: --foreign-repo のパス不在は die（誤 path を無言 sweep しない）" {
    run_dispatch --liveness --foreign-repo "$TEST_TMPDIR/nonexistent-fr"
    [ "$status" -ne 0 ]
    [[ "$output" == *"存在しません"* ]]
}

@test "liveness（bd-id は取らない）: 余分な bd-id を渡すと die" {
    run_dispatch --liveness orch-stray
    [ "$status" -ne 0 ]
}

@test "liveness（非整数 --stale-min は die）: 数値前提入力の fail-loud" {
    run_dispatch --liveness --stale-min notanum
    [ "$status" -ne 0 ]
    [[ "$output" == *"整数"* ]]
}

@test "liveness（window なし + park なし）: 何も無ければ各節に『なし/該当なし』を明示（false-clean でなく)" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"spawn window なし"* ]]
    [[ "$output" == *"停滞なし"* ]]
    [[ "$output" == *"該当なし"* ]]
}

# ── cell-quality minor fixes（orch-edv T3 の自己 review 指摘・全 read-only advisory の polish）──────────

@test "liveness（fix#1・bd list 失敗は fail-loud）: decision-point の bd list 失敗を warn し『停滞なし』を偽 clean にしない" {
    # liveness は silent mutual-wait deadlock の fail-loud backstop。bd 障害を握りつぶし『停滞なし』と偽 clean を
    # 出すと人間を誤って安心させる（run_watch_worker / run_gate_pending と同型に fail-silent を回避する）。
    : > "$TMUX_WINDOWS_FILE"
    export BD_FAIL=1
    export BD_LIST_JSON='[]'
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]                        # read-only surface ゆえ die はしない
    [[ "$output" == *"bd list"* ]]             # 失敗を surface（stderr warn）
    [[ "$output" == *"信用するな"* ]]           # 偽 clean を戒める（fail-loud）
}

@test "liveness（fix#3・hydrated foreign copy 除外）: 自台帳読みは SELF_PREFIX(orch-) で filter＝hydrate された foreign copy(un-)を self バケットに出さない" {
    # 連結 substrate hydrate で自 DB の bd list は foreign copy(un-/sc-…)も prefix 非依存で返す。filter しないと
    # foreign copy が [foreign] タグ無しで self-dev の如く surface される。foreign は --foreign-repo 経路へ一本化する。
    local stale_iso; stale_iso=$(date -u -d "@$((1751000000 - 3600))" +%Y-%m-%dT%H:%M:%SZ)
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON="[{\"id\":\"orch-self\",\"status\":\"blocked\",\"labels\":[\"needs-user\"],\"updated_at\":\"$stale_iso\"},{\"id\":\"un-hyd\",\"status\":\"blocked\",\"labels\":[\"needs-user\"],\"updated_at\":\"$stale_iso\"}]"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-self"* ]]           # self-dev(orch-)は surface
    [[ "$output" != *"un-hyd"* ]]              # hydrate された foreign copy は self バケットに出さない（誤タグ surface 防止）
}

@test "liveness（fix#2・age不明②）: updated_at 欠落の park bead は『停滞 age不明』で safe surface（silent miss しない）" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[{"id":"orch-noage","status":"blocked","labels":["needs-user"]}]'   # updated_at 無し
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-noage"* ]]
    [[ "$output" == *"age不明"* ]]             # 停滞判定不能でも safe 側で surface（silent-miss backstop）
}

@test "liveness（fix#2・age不明③）: wt-<id> 生存 + self bead に updated_at 欠落は『更新時刻不明』で surface（stall 判定不能=要確認）" {
    printf 'wt-orch-noup\n' > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export BD_SHOW_DIR="$TEST_TMPDIR/showdir"; mkdir -p "$BD_SHOW_DIR"
    printf '{"id":"orch-noup","status":"in_progress"}' > "$BD_SHOW_DIR/orch-noup"   # updated_at 無し
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"wt-orch-noup"* ]]
    [[ "$output" == *"更新時刻不明"* ]]
}

# ── host-progress probe（liveness 第3軸・orch-ayj）: 長 running build 生存 × fs 書込停止＝silent hang ──────
#   3 分岐: (a) stall（生存×書込ゼロ→surface）/ (b) 正常 build（書込継続→surface しない）/ (c) プロセス不在
#   （probe 対象外）。加えて 短命プロセス除外・read-only・dry-run plan・probe 不能 fail-loud を検証。
#   pgrep/ps/find は PATH/env スタブ、監視 fs は hermetic dir（HOSTPROG_WATCH_DIR）に固定して決定的にする。

@test "liveness（host-progress・stall/分岐a）: 長 running build プロセス生存 + fs 書込 N 分ゼロ＝silent hang を surface" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PIDS='12345'
    printf '12345 5400\n' > "$HOSTPROG_PS_FILE"   # etimes=5400s(90m) ≥ 30m → 長 running
    # HOSTPROG_RECENT_WRITE 未設定＝find は何も返さない＝書込ゼロ（stall 側）
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"host-progress"* ]]
    [[ "$output" == *"silent hang 疑い"* ]]
    [[ "$output" == *"pid 12345"* ]]
}

@test "liveness（host-progress・正常 build/分岐b）: 書込継続なら false positive しない（silent hang にしない）" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PIDS='12345'
    printf '12345 5400\n' > "$HOSTPROG_PS_FILE"
    export HOSTPROG_RECENT_WRITE=1               # find が書込を検出＝正常 build（acceptance 2）
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"正常 build"* ]]
    [[ "$output" != *"silent hang 疑い"* ]]
}

@test "liveness（host-progress・プロセス不在/分岐c）: build プロセスが無ければ probe 対象外（stall と誤らない）" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    # HOSTPROG_PIDS 未設定＝pgrep マッチなし（rc1）
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"host-progress"* ]]
    [[ "$output" == *"build プロセスなし"* ]]
    [[ "$output" != *"silent hang 疑い"* ]]
}

@test "liveness（host-progress・短命プロセス除外）: N 分未満のプロセスは書込ゼロでも長 running なしで stall にしない" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PIDS='999'
    printf '999 60\n' > "$HOSTPROG_PS_FILE"    # etimes=60s < 30m → 長 running でない
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"長 running なし"* ]]
    [[ "$output" != *"silent hang 疑い"* ]]
}

@test "liveness（host-progress・ps 判定不能は fail-loud 側）: etimes 取得不能でも書込ゼロなら silent hang を surface（取りこぼさない）" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PIDS='777'
    : > "$HOSTPROG_PS_FILE"                     # ps 出力空＝年齢判定不能→全 PID を長 running 扱い（安全側）
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"silent hang 疑い"* ]]
    [[ "$output" == *"pid 777"* ]]
}

@test "liveness（host-progress・read-only）: find は -print -quit のみ・-delete/-exec を発行しない（mutate しない）" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PIDS='12345'
    printf '12345 5400\n' > "$HOSTPROG_PS_FILE"
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [ -s "$HOSTPROG_FIND_ARGS" ]                    # find が呼ばれた（非vacuous＝probe が実際に走った証跡）
    grep -q -- '-print' "$HOSTPROG_FIND_ARGS"       # read-only な走査
    grep -q -- '-quit' "$HOSTPROG_FIND_ARGS"        # 1 件で打ち切り
    ! grep -qE -- '-delete|-exec' "$HOSTPROG_FIND_ARGS"
    # bd の write 系サブコマンドも一切呼ばれない（host-progress 軸が mutate しない・acceptance 3）
    ! grep -qE '(^| )(update|close|create|dep|import|batch|sql)( |$)' "$BD_ARGS_FILE"
}

@test "liveness（host-progress・build 不在は find を叩かない）: プロセス不在時は find コストを払わない（probe skip）" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    # HOSTPROG_PIDS 未設定＝build 不在
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [ ! -s "$HOSTPROG_FIND_ARGS" ]                  # find は 1 度も呼ばれていない（build 中のみ走る安価性）
}

@test "liveness（host-progress・dry-run plan）: dry-run は ④ host-progress 軸を plan に案内し pgrep/find を叩かない" {
    export HOSTPROG_PIDS='12345'                    # 設定しても dry-run は probe を実行しない
    run_dispatch --liveness --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]   ④"* ]]
    [[ "$output" == *"silent hang"* ]]
    [ ! -s "$HOSTPROG_FIND_ARGS" ]                  # dry-run は副作用ゼロ（find を叩かない）
}

@test "liveness（host-progress・probe 不能 fail-loud）: pgrep/find 不在なら『問題なし』と偽 clean にせず warn する" {
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    # pgrep を存在しないパスへ向ける＝probe 実行不能（find も無効化）
    ORCH_DISPATCH_PGREP="$TEST_TMPDIR/no-such-pgrep" \
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]                             # read-only surface ゆえ die はしない
    [[ "$output" == *"probe 実行不能"* ]]
    [[ "$output" == *"信用するな"* ]]               # 偽 clean を戒める（fail-loud・②の bd 失敗と同型）
}

@test "liveness（host-progress・pgrep 異常終了 fail-loud）: rc≥2（ERE 構文エラー等）を『マッチなし』と同一視せず warn する" {
    # cell-quality confirmed minor（robustness-security）: pgrep rc は 0=マッチ/1=なし/2=構文エラー/3=致命。
    # rc≥2 を rc==1 と混同して『build プロセスなし』へ倒すと不正 pattern override で silent hang 検知が黙って無効化。
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PGREP_RC=2                      # pgrep rc=2（ERE 構文エラー・stdout 空）
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]                             # read-only surface ゆえ die はしない
    [[ "$output" == *"probe 実行不能"* ]]
    [[ "$output" == *"pgrep が異常終了"* ]]
    [[ "$output" == *"信用するな"* ]]               # fail-loud（binary 不在 guard と同型）
    [[ "$output" != *"build プロセスなし"* ]]        # rc≥2 を『マッチなし』と誤らない
}

@test "liveness（host-progress・rc==1 は通常の probe 対象外）: pgrep マッチなし（rc1）は fail-loud でなく静かに対象外" {
    # rc==1（正当な『build なし』）は fail-loud にせず従来どおり『build プロセスなし』へ倒す（rc≥2 との出し分け teeth）。
    : > "$TMUX_WINDOWS_FILE"
    export BD_LIST_JSON='[]'
    export HOSTPROG_PGREP_RC=1                      # pgrep rc=1（マッチなし）
    ORCH_DISPATCH_NOW_EPOCH=1751000000 run_dispatch --liveness
    [ "$status" -eq 0 ]
    [[ "$output" == *"build プロセスなし"* ]]
    [[ "$output" != *"probe 実行不能"* ]]
    [[ "$output" != *"pgrep が異常終了"* ]]
}

@test "liveness（host-progress・既定 pattern の idle-daemon 除外）: shipped ERE は build/pull/push/buildah/skopeo に match し podman daemon を除外" {
    # cell-quality confirmed minor（completeness-critic）: pgrep-stub は pattern を無視するため、既定 pattern の
    # false-positive 回避 claim（idle podman daemon を除外）が未検証だった。source から shipped default を抽出し
    # grep -E で包含/除外を直接 assert する（pattern を緩めると 10 test を pass したまま FP を再導入できる gap を塞ぐ）。
    local pat
    pat="$(grep -oE 'ORCH_DISPATCH_HOSTPROG_PATTERN:-[^}]+' "$SCRIPT" | sed 's/^ORCH_DISPATCH_HOSTPROG_PATTERN:-//')"
    [ -n "$pat" ]
    # 包含: build/pull/push 操作 + buildah + skopeo（生存＝作業中）
    printf '/usr/bin/podman build -t x .\n' | grep -qE "$pat"
    printf 'podman pull docker.io/library/alpine\n' | grep -qE "$pat"
    printf 'podman push localhost/x:latest\n' | grep -qE "$pat"
    printf 'buildah bud -f Dockerfile .\n' | grep -qE "$pat"
    printf 'skopeo copy dir:a docker://b\n' | grep -qE "$pat"
    # 除外: idle podman daemon（socket-activated service）を silent hang と誤検知しない（この pattern が唯一の guard）
    printf 'podman system service --time=0 unix:///run/podman.sock\n' | grep -qvE "$pat"
}

# ==============================================================================
# (4) モード排他・未知オプション・help・健全性
# ==============================================================================

@test "モード排他: --gate-pending と --watch の同時指定は die" {
    run_dispatch --gate-pending --watch orch-x
    [ "$status" -ne 0 ]
}

@test "未知オプションは die" {
    run_dispatch --bogus orch-test
    [ "$status" -ne 0 ]
}

@test "--help は exit 0 で usage を出す（4 モードを案内）" {
    run_dispatch --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"spawn"* ]]
    [[ "$output" == *"gate-pending"* ]]
    [[ "$output" == *"watch"* ]]
    [[ "$output" == *"liveness"* ]]
}

@test "bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

# ==============================================================================
# (E1/E2) 共有 lib orch_anchor.sh の解決経路（orch-49g errata）
#   E1: symlink 経由起動でも readlink -f で script 実体を解決し実 repo の lib を source できる（symlink 退行の回帰防御）。
#   E2: lib 不在なら fail-closed exit1 + loud message（確立規約 orch-hydrate.bats / orch-architecture-hydrate.bats 同型）。
# ==============================================================================
@test "(E1) symlink 経由起動でも共有 lib を解決し --help exit0（readlink-safe・orch-49g errata E1）" {
    # 実 dispatch への symlink を lib の無い dir に置いて起動。readlink -f が実体を解決すれば実 repo の lib を
    #   source でき --help が exit0。非 readlink（退行）なら $LN/lib/orch_anchor.sh を見て lib 不在 die（非vacuity）。
    local LN="$TEST_TMPDIR/linkdir"; mkdir -p "$LN"
    ln -s "$SCRIPT" "$LN/orch-dispatch.sh"
    PATH="$BIN:$PATH" run bash "$LN/orch-dispatch.sh" --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"共有 anchor lib 不在"* ]]
}

@test "(E2-libabsent) 共有 anchor lib 不在なら fail-closed exit1 + loud message（orch-49g errata E2）" {
    local SB="$TEST_TMPDIR/sb-nolib"; mkdir -p "$SB"
    cp "$SCRIPT" "$SB/orch-dispatch.sh"   # lib/orch_anchor.sh を意図的に置かない
    PATH="$BIN:$PATH" run bash "$SB/orch-dispatch.sh" --help
    [ "$status" -ne 0 ]
    [[ "$output" == *"共有 anchor lib 不在"* ]]
}

# ==============================================================================
# (E3) engine anchor fail-loud teeth（--help 短絡の対）
#   engine は deploy-layout hardcode fallback を撤去済み。anchor seam（env / config / 動的導出）が全て未供給かつ
#   起動が非 help mode のとき、silent に誤 anchor を指さず loud に die する。--help のみ anchor 非依存で応答する
#   （E1 が pin）＝この 2 本で「help は短絡・非 help は fail-loud」の両側を非vacuous に固定する。
# ==============================================================================
@test "(E3-anchor) anchor 未供給 + 非 help mode は fail-loud die（hardcode fallback を持たない）" {
    # env anchor 3 seam を全て unset し、非 git dir から起動して動的導出も失効させる（hermetic）。
    #   非 help（--gate-pending）ゆえ anchor 解決を要求 → 解決不能 → loud die。read 経路も anchor 派生既定
    #   （BDW/RESYNC/鮮度マーカー）に依るため anchor 未解決は fail-loud が正（silent no-op しない）。
    local NG="$TEST_TMPDIR/nongit"; mkdir -p "$NG"
    run bash -c 'cd "$3" || exit 99; unset ORCH_DISPATCH_SCRIPTORIUM ORCH_ANCHOR ORCH_ANCHOR_CONFIG
                 PATH="$1:$PATH" exec bash "$2" --gate-pending' _ "$BIN" "$SCRIPT" "$NG"
    [ "$status" -ne 0 ]
    [ "$status" -ne 99 ]                                   # cd 失敗ではなく anchor die であることを保証
    [[ "$output" == *"anchor 解決不能"* ]]
}

@test "(E3-spawn) SPAWN 未供給で spawn 実行経路に入ると fail-loud die（engine は既定 path を持たない）" {
    # engine は ORCH_DISPATCH_SPAWN の既定 path を撤去（private 配備層が env seam で供給）。未供給のまま spawn
    #   （実行経路）に入ったら scribe-spawn 実体不在を loud に die し silent no-op しない。anchor は供給し、SPAWN
    #   のみ unset＝-x check（run_spawn 冒頭・契約 gate/bd read より前）で die することを pin する。
    run env -u ORCH_DISPATCH_SPAWN \
        PATH="$BIN:$PATH" \
        ORCH_DISPATCH_SCRIPTORIUM="$TANCHOR" \
        ORCH_DISPATCH_SKIP_SLATE_GATE=1 \
        bash "$SCRIPT" orch-test
    [ "$status" -ne 0 ]
    [[ "$output" == *"scribe-spawn"* ]]                    # 実体不在を名指しで loud に述べる
    [[ "$output" == *"ORCH_DISPATCH_SPAWN"* ]]             # 是正導線（env seam 供給）を案内
    [[ "$output" != *"SPAWN-ARGS:"* ]]                     # spawn を呼ばない（silent no-op しない）
}

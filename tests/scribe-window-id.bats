#!/usr/bin/env bats
# scribe-window-id.bats - scribe_window_id / scribe_current_session の session-scope 契約（sc-9nc7）
#
# 何を守るか（scripts/lib/scribe-lib.sh が SSOT）:
#   window 名 → window_id(@N) の解決は **単一 session の中**に閉じる（`list-windows -t "=<session>"`）。
#   旧実装は `list-windows`（-t 無し）で、tmux は「現在 session」を暗黙 target にするが、その「現在」は
#   client 依存＝bare display-message と同じ非決定を持ち込む。かといって -a（全 session 横断）へ広げるのは
#   **拡大**であり誤りの向きが悪い: 呼び手は scribe-spawn.sh の `send-keys -t "$WID" Enter` と
#   scribe-cleanup.sh の `kill-window -t "$WID"` で、-a は「他 session の同名 wt- 窓へ Enter を撃つ /
#   他 session の窓を kill する」新規の誤配経路を作る。
#   よって: session を積極証拠（pane_id エコー一致）で確定できなければ **空を返す**（-a へ fallback しない）。
#   同一 session 内で複数一致した場合も silent 先頭採用はせず stderr 1 行 + 空を返す。
#
# 実 tmux は起動しない（SCRIBE_TMUX seam の stub のみ）。

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LIB="$REPO_ROOT/scripts/lib/scribe-lib.sh"
  S="$BATS_TEST_TMPDIR/stub"; mkdir -p "$S/windows"
  : > "$S/calls.log"

  # tmux stub:
  #   display-message … -t <pane> のときだけ "<pane_id> <session>" をエコー（実 tmux の
  #                     '#{pane_id} #{session_name}' format 再現。PANE_ECHO で不一致を作れる）
  #   list-windows    … -t "=<session>" の session に属する窓だけを返す（session-scope の再現）。
  #                     -a（全 session 横断）で呼ばれたら **明示的に落とす**＝-a への退行を検出する。
  TMUX_STUB="$S/tmux"
  cat > "$TMUX_STUB" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$(readlink -f "$0")")"
sub="$1"; shift
echo "$sub $*" >> "$S/calls.log"
case "$sub" in
  display-message)
    _tgt=""; _prev=""
    for _a in "$@"; do [[ "$_prev" == "-t" ]] && _tgt="$_a"; _prev="$_a"; done
    [[ -n "$_tgt" ]] || exit 0
    echo "${PANE_ECHO-$_tgt} ${SESS_STUB-cursess}" ;;
  list-windows)
    _tgt=""; _prev=""
    for _a in "$@"; do [[ "$_prev" == "-t" ]] && _tgt="$_a"; _prev="$_a"; done
    if [[ "$*" == *"-a"* ]]; then
      echo "tmux-stub: list-windows -a は session-scope 契約違反" >&2
      exit 1
    fi
    [[ "$_tgt" == =* ]] || { echo "tmux-stub: -t \"=<session>\" が無い" >&2; exit 1; }
    cat "$S/windows/${_tgt#=}" 2>/dev/null || true ;;
esac
exit 0
STUB
  chmod +x "$TMUX_STUB"
  export SCRIBE_TMUX="$TMUX_STUB"
  export TMUX_PANE="%42"
  unset PANE_ECHO SESS_STUB 2>/dev/null || true
}

# scribe_window_id を lib から呼ぶ薄いドライバ（stdout=WID / stderr も run で拾う）。
_wid() {
  run bash -c 'set -uo pipefail; source "$1"; scribe_window_id "${2:-}" "${3-}"' _ "$LIB" "$@"
}

_cursess_windows() { printf '%s\n' "$@" > "$S/windows/cursess"; }
_other_windows()   { printf '%s\n' "$@" > "$S/windows/other"; }

# ---------- (a) 同 session 内一致 ----------

@test "window-id(sc-9nc7): 自 session 内に一致する窓があれば window_id(@N) を返す" {
  _cursess_windows "@9 wt-un-4nm" "@3 admin"
  _wid wt-un-4nm
  [ "$status" -eq 0 ]
  [ "$output" = "@9" ]
  # -t "=<session>" の exact match で引いている（-a でも -t 無しでもない）
  grep -q 'list-windows -t =cursess -F #{window_id} #{window_name}' "$S/calls.log" \
    || { echo "log: $(cat "$S/calls.log")"; false; }
}

# ---------- (b) 他 session のみに同名窓 ----------

@test "window-id(sc-9nc7): 同名窓が他 session にしか無ければ空を返す（-a で横断解決しない）" {
  _cursess_windows "@3 admin"
  _other_windows   "@9 wt-un-4nm"
  _wid wt-un-4nm
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  # 空を返すのが正解: 呼び手（send-keys / kill-window）が他 session の窓を掴まない。
  ! grep -q '\-a' "$S/calls.log"
}

# ---------- (c) 同 session 内で複数一致 ----------

@test "window-id(sc-9nc7): 同 session 内で複数一致したら silent 先頭採用せず stderr + 空" {
  _cursess_windows "@9 wt-un-4nm" "@11 wt-un-4nm"
  _wid wt-un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 件一致"* ]]                # stderr の warn（run は stderr も output へ集める）
  [[ "$output" != *"@9"* ]]                      # 先頭を黙って採らない
  [[ "$output" != *"@11"* ]]
}

# ---------- session 解決の積極証拠 ----------

@test "window-id(sc-9nc7): pane エコー不一致なら session を確定せず空（list-windows すら叩かない）" {
  _cursess_windows "@9 wt-un-4nm"
  export PANE_ECHO="%99"
  _wid wt-un-4nm
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q '^list-windows' "$S/calls.log"
}

@test "window-id(sc-9nc7): TMUX_PANE 未設定なら空（bare display-message へ縮退しない）" {
  _cursess_windows "@9 wt-un-4nm"
  unset TMUX_PANE
  _wid wt-un-4nm
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q '^display-message' "$S/calls.log"    # -t 無しの bare 解決を試みない
  ! grep -q '^list-windows' "$S/calls.log"
}

@test "window-id(sc-9nc7): session を第 2 引数で明示すれば pane 解決へ行かずその session を scope にする" {
  _other_windows "@7 wt-un-4nm"
  unset TMUX_PANE                                # pane 解決は不能な状況
  _wid wt-un-4nm other
  [ "$status" -eq 0 ]
  [ "$output" = "@7" ]
  ! grep -q '^display-message' "$S/calls.log"
}

@test "window-id(sc-9nc7): window 名が空なら tmux を 1 度も叩かず空を返す" {
  _wid ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$S/calls.log" ]
}

# ---------- scribe_current_session（積極証拠の pure 判定）----------

@test "current-session(sc-9nc7): pane_id エコー一致なら session 名を返す" {
  export SESS_STUB="realsess"
  run bash -c 'set -uo pipefail; source "$1"; scribe_current_session' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "realsess" ]
  grep -q 'display-message -p -t %42 #{pane_id} #{session_name}' "$S/calls.log" \
    || { echo "log: $(cat "$S/calls.log")"; false; }
}

@test "current-session(sc-9nc7): 区切りだけの非空エコー（session フィールド空）は非 0 で拒否する" {
  # 実測: 不在 pane への複数フィールド display-message は rc=0 + 非空（区切りのみ）を返す。
  # ゆえに rc でも出力の非空でも判定できず、pane_id のエコー一致だけが積極証拠になる。
  export SESS_STUB=""
  run bash -c 'set -uo pipefail; source "$1"; scribe_current_session' _ "$LIB"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

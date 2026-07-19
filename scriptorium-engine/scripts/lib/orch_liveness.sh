#!/usr/bin/env bash
# orch_liveness.sh — spawn/admin window の **session:window 正準形** 列挙の共有 shell lib（bd orch-4js9・fence1）
#
# 役割 ─────────────────────────────────────────────────────────────────────────
#   orch-dispatch.sh の landed liveness（`_liveness_windows`・orch-riz1 topology）を **単一 SSOT** 化し、
#   orch-dispatch.sh と orch-delivery-observe.sh が共に consume する（byte 複製ゼロ）。宛先窓 live 判定を
#   複数 consumer が持つと riz1 の `:(wt-|admin-|admin$)` canonical form が drift する（`^admin-` / 前方一致
#   の再導入で誤検出／取りこぼし）ため、canonical form を 1 箇所に固定する（orch-4js9 fence1「素朴再実装しない」）。
#
# _liveness_windows <tmux_bin> ─────────────────────────────────────────────────
#   spawn window（wt-* / 素 admin / admin-*）を **session:window 正準形**（`#{session_name}:#{window_name}`）で
#   列挙する（read-only・tmux server を mutate しない）。第1引数に tmux 実体を取る（consumer が自前の env-seam
#   〔ORCH_DISPATCH_TMUX / ORCH_DELIVERY_TMUX〕で解決した bin を渡す＝lib は env 名に依存しない）。未指定は `tmux`。
#     裁定-topology（orch-thgx・orch-riz1）: admin window の宛先正準形は `<project>:admin`（window 名は素 'admin'
#     維持・session 名=project 名が識別を担う）。ゆえに format を `#{session_name}:#{window_name}` に統一し、素
#     admin 窓（window 名=admin）も admin-<project>（移行期出力）も session 修飾付きで一意に surface する。
#     grep: window_name が wt- / admin- で始まる or 末尾がちょうど admin＝`:(wt-|admin-|admin$)`（末尾 $ で
#     administrator 等の過検出を防ぐ）。list-panes は tmux server を mutate しない。pane 単位で重複するため sort -u。
#
# 検証: 本 file の `--self-test`（直接実行時のみ・hermetic・fail-closed）+ consumer の bats
#   （orch-dispatch.bats の liveness section / orch-delivery-observe.bats の窓 live section）。
#   **plugin 反映には新規 cld session 必須**。

# spawn/admin window を session:window 正準形で列挙（read-only・orch-riz1 topology・単一 SSOT）。
_liveness_windows() {
    local tmux_bin="${1:-tmux}"
    "$tmux_bin" list-panes -a -F '#{session_name}:#{window_name}' 2>/dev/null \
        | grep -E ':(wt-|admin-|admin$)' | sort -u
}

# === --self-test: 直接実行時のみの hermetic 自己完結テスト（fail-closed・orch-4js9） ===
# source 時（BASH_SOURCE[0] != $0）はこのブロックを skip する（consumer の $1 継承で誤発火しない）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" != "--self-test" ]; then
        echo "orch_liveness.sh は source して使う共有 lib です（--self-test で自己検証）。" >&2
        exit 0
    fi

    st_fail=0
    st_tmp="$(mktemp -d -t orch-liveness-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    # hazard-faithful stub tmux: `list-panes -F <fmt>` で $TMUX_WINDOWS_FILE の各行を format 尊重で返す
    #   （session:window 形 or bare window）。canonical form の pass-through と grep フィルタを exercise する。
    mkdir -p "$st_tmp/bin"
    cat > "$st_tmp/bin/tmux" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-panes)
    fmt=""; prevf=""
    for a in "$@"; do [ "$prevf" = "-F" ] && fmt="$a"; prevf="$a"; done
    if [ -f "${TMUX_WINDOWS_FILE:-/nonexistent}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
          *:*) sess="${line%%:*}"; win="${line#*:}" ;;
          *)   sess="orch"; win="$line" ;;
        esac
        case "$fmt" in
          *session_name*) printf '%s:%s\n' "$sess" "$win" ;;
          *)              printf '%s\n' "$win" ;;
        esac
      done < "$TMUX_WINDOWS_FILE"
    fi
    exit 0 ;;
esac
exit 0
STUB
    chmod +x "$st_tmp/bin/tmux"

    export TMUX_WINDOWS_FILE="$st_tmp/windows.txt"
    # fixture: admin 窓 2（素 admin + admin-pk 移行形）/ wt 窓 1 / 非対象窓 2（orchestrator / administrator=過検出罠）。
    cat > "$TMUX_WINDOWS_FILE" <<'WINS'
scribe:admin
pk:admin-pk
un:wt-un-xxx
orch:orchestrator
foo:administrator
WINS

    out="$(_liveness_windows "$st_tmp/bin/tmux")"
    # (1) canonical form pass-through: session 修飾付きで返る（session_name 含む format を尊重）。
    if printf '%s\n' "$out" | grep -qxF "scribe:admin" \
       && printf '%s\n' "$out" | grep -qxF "pk:admin-pk" \
       && printf '%s\n' "$out" | grep -qxF "un:wt-un-xxx"; then
        _ok "canonical form: 素 admin / admin-<proj> / wt-* が session:window 形で列挙"
    else
        _fail "canonical form: admin/wt 窓の session:window 列挙を期待したが不一致: [$out]"
    fi
    # (2) 非対象窓の除外（非vacuity）: orchestrator（admin/wt でない）と administrator（末尾 $ で過検出しない）は落ちる。
    if ! printf '%s\n' "$out" | grep -q "orchestrator" \
       && ! printf '%s\n' "$out" | grep -q "administrator"; then
        _ok "フィルタ非vacuity: 非 admin/wt 窓(orchestrator)と administrator(末尾\$ 過検出罠)を除外"
    else
        _fail "フィルタ: orchestrator/administrator は除外を期待したが混入: [$out]"
    fi
    # (3) 空窓ファイル → 空出力（graceful）。
    : > "$TMUX_WINDOWS_FILE"
    out_empty="$(_liveness_windows "$st_tmp/bin/tmux")"
    if [ -z "$out_empty" ]; then
        _ok "空: window 無し → 空出力（graceful）"
    else
        _fail "空: window 無しで空出力を期待したが不一致: [$out_empty]"
    fi

    if [ "$st_fail" -eq 0 ]; then echo "orch_liveness.sh --self-test: PASS"; exit 0
    else echo "orch_liveness.sh --self-test: FAIL" >&2; exit 1; fi
fi

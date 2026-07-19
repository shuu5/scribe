#!/usr/bin/env bash
# orch-handoff-scan.sh — orchestrator-facing needs-orch 検知線（foreign→orchestrator self-surface・bd orch-jmu）
#
# 役割（orch-am1 grill 論点6 確定）─────────────────────────────────────────────────
#   hydrated orch DB（自 orch- bead + `bd repo sync` で hydrate された foreign copy）を `needs-orch`
#   平ラベルで **完全一致** scan し、orchestrator 自身が引き取るべき foreign bead を surface する検知線。
#   方向: **foreign→orchestrator**（自己 surface）。discovery-nudge の project-admin down-route
#   （orchestrator→admin window）とは逆向き・reconciliation-parity の公開面 parity とも別述語ゆえ
#   それらの機構を転用しない（新述語＝needs-orch ラベル scan）。read-only ゆえ bdw 不要。
#
# 検知（scan・acceptance 1 / orch-jmu notes p1,p2）──────────────────────────────────
#   `bd list -l needs-orch --json --no-pager --limit 0`（既存 idiom = orch-discovery-nudge.sh /
#   orch-reconciliation-parity.sh と同形）で非 closed bead を拾う。
#     - `--limit 0`（p1）: bd list は既定 ~30 件で **silent 截断**する＝needs-orch の恒久 burial を直接
#       招くため `--limit 0`（全件）を厳守する（default-limit 截断禁止）。
#     - 単数 `-l/--label`（p2）: `--labels`（複数形）は無効フラグで無言 0 件になる既知罠ゆえ使わない。
#   labels 配列も read し、各 bead が `needs-grill` を併存するかを per-bead 判定する（下記 triage 保留）。
#
# triage 保留（acceptance 2 / orch-am1 論点3・orch-jmu notes p5）───────────────────
#   優先規則「needs-grill が残る限り orchestrator は triage しない」を **per-bead** で表現する。各 bead の
#   labels に `needs-grill` を含むなら「triage 保留」として区別表示する（DB 全体を保留にするのではなく、
#   保留は当該 bead 単位＝orch-dispatch.sh の 'gate-pending in labels' per-bead 判定と同型）。needs-grill を
#   含まない needs-orch bead は「triage 可能（actionable）」として surface する。
#
# 鮮度警告（acceptance e / orch-jmu notes p3）──────────────────────────────────────
#   foreign copy は courier `bd repo sync`（hydrate）に構造依存する。sync が古い/未実行だと hydrate された
#   foreign needs-orch を silent 取りこぼす。よって **standalone 実行時のみ**、orch 台帳の sync 専用マーカー
#   `.beads/last-sync`（orch-hydrate.sh が `bd repo sync` 成功直後に stamp・orch-dispatch の主鮮度ソースと
#   同一 marker）の mtime を read し、stale(>閾値分)/unknown なら警告を添える（read-only＝sync は呼ばない）。
#   鮮度計算は orch-dispatch.sh の `_compute_sync_freshness` と同義（mtime 主指標・clock skew は fresh 側へ
#   丸め・marker 不在は unknown へ最安全側に倒す）。**hook 統合時（--no-freshness）は第1セクション
#   （gate-pending pull）の鮮度警告に委譲**し、同一 hook 出力での二重表示を避ける（p3）。
#
# self-scope gate（誤台帳 scan の防止・他 orch- script と同一機構）────────────────────
#   `bd list` は cwd の台帳に作用する。非 orch 台帳（scribe 'sc' / cc-session 'ccs' …）から走らせると foreign DB を
#   scan して誤 surface する。cwd から walk-up した最初の .beads/metadata.json の dolt_database が orch で
#   なければ何もせず非 0 で抜ける（共有 lib _ledger_dolt_database・fail-closed）。ORCH_HANDOFF_SKIP_SESSION_GATE=1
#   で skip（hermetic self-test 用）。
#
# 共有 lib consume（orch-jmu notes d・自前 walk-up を書かない）─────────────────────
#   hooks/lib/orch_session.sh（_ledger_dolt_database＝self-scope walk-up・_json_is_valid gate 済み）と
#   lib/orch_anchor.sh（_resolve_scriptorium＝鮮度 marker の SCRIPTORIUM anchor 動的解決・E2 検証付き）を
#   BASH_SOURCE 相対で source する（orch-t9z / orch-49g の dedup 方針維持）。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）scan     : needs-orch bead を surface（鮮度警告付き・standalone）。
#   --no-freshness   : 鮮度警告を出さない（hook 統合が第1セクションへ委譲するとき用・p3）。
#   --self-test      : hermetic 自己完結テスト（fail-closed・下記）。
#   --help
#
# env override（主に hermetic self-test / hook 用）─────────────────────────────────
#   ORCH_HANDOFF_BD            scan に使う bd 実体（既定: PATH 上の bd）。read-only（list のみ）。
#   ORCH_HANDOFF_SCRIPTORIUM   鮮度 marker 解決の scriptorium root（既定: _resolve_scriptorium）。
#   ORCH_HANDOFF_SYNC_MARKER   sync 専用マーカーパス（既定: <SCRIPTORIUM>/.beads/last-sync）。
#   ORCH_HANDOFF_STALE_MIN     鮮度 stale 閾値（分・既定 60＝orch-dispatch と同値）。
#   ORCH_HANDOFF_SKIP_SESSION_GATE=1  self-scope gate を skip（hermetic self-test 用）。
#
# 検証（tracked・durable）: tests/scenarios/orch-handoff-scan.bats（hermetic: bd を PATH stub で real bd の -l
#   exact-match フィルタごと差替・正/負例・triage 保留 per-bead・截断禁止・scan 失敗 fail-closed・self-scope
#   両側・鮮度 stale/fresh/unknown）+ 本 file の `--self-test`（hermetic・fail-closed）。**plugin 反映には
#   新規 cld session 必須**（hook 統合分）。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard と同一値を共有）。
SELF_PREFIX="orch"
SCAN_LABEL="needs-orch"    # 検知する平ラベル（完全一致・orch-am1 §論点6）。
GRILL_LABEL="needs-grill"  # triage 保留の gate ラベル（併存 per-bead 判定・論点3）。

# --- 共有 self-scope lib を source（bd orch-t9z・SSOT = scripts/hooks/lib/orch_session.sh） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。★実 script 位置（BASH_SOURCE 相対）で
# 解決するので bats / --self-test が実 lib を確実に見つける。symlink 起動でも実体を解決（readlink -f）。
_orch_hs_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(cd "$(dirname "$_orch_hs_self")" 2>/dev/null && pwd)"
_ORCH_SESSION_LIB="$_SCRIPT_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-handoff-scan: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# --- 共有 anchor lib を source（bd orch-49g・鮮度 marker の SCRIPTORIUM 解決に _resolve_scriptorium を再利用） ---
# lib は内部で orch_session.sh を transitive source し E2 anchor 検証（dolt_database==orch のみ採用）を掛ける。
_ORCH_ANCHOR_LIB="$_SCRIPT_DIR/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
    # shellcheck source=lib/orch_anchor.sh
    . "$_ORCH_ANCHOR_LIB"
else
    echo "orch-handoff-scan: 共有 anchor lib 不在: $_ORCH_ANCHOR_LIB（anchor 解決不能・fail-closed）" >&2
    exit 1
fi

# 外部ツール / 設定（env で差替可・self-test 用）。
BD="${ORCH_HANDOFF_BD:-bd}"
STALE_MIN="${ORCH_HANDOFF_STALE_MIN:-60}"
[[ "$STALE_MIN" =~ ^[0-9]+$ ]] || STALE_MIN=60   # 非整数は既定 60 へ（orch-dispatch と同型の防御）。

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
EMIT_FRESHNESS=1
for arg in "$@"; do
    case "$arg" in
        --no-freshness) EMIT_FRESHNESS=0 ;;
        --self-test)    ;;   # 下方の --self-test ブロックで処理（ここでは無視）
        -h|--help)
            # 先頭コメントブロック（shebang 直後〜最初の非コメント行の手前）を help として出す。
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "orch-handoff-scan: unknown arg: $arg（--no-freshness / --self-test / --help のみ）" >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# ヘルパ
# ─────────────────────────────────────────────────────────────────────────────

# scan JSON（$1）→ "<id>\t<title>\t<grill-flag>" 行。jq 主・python3 フォールバック（両者 labels を正しく解釈）。
#   grill-flag: labels 配列に needs-grill を含めば "1"・無ければ "0"（per-bead 保留判定に使う・p5）。
#   title/notes 中の TAB/改行は列区切りを壊すため空白へ潰す（防御的）。どの parser も使えない/失敗は非 0。
_parse_scan() {
    local json="$1" out rc
    if command -v jq >/dev/null 2>&1; then
        out="$(printf '%s' "$json" | jq -r '
            .[]? | [
              .id,
              ((.title // "") | gsub("[\t\n]"; " ")),
              (if ((.labels // []) | index("'"$GRILL_LABEL"'")) != null then "1" else "0" end)
            ] | @tsv' 2>/dev/null)"
        rc=$?
        if [ "$rc" -eq 0 ]; then printf '%s' "$out"; return 0; fi
    fi
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | GRILL_LABEL="$GRILL_LABEL" python3 -c '
import sys, json, os
grill = os.environ.get("GRILL_LABEL", "needs-grill")
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if not isinstance(data, list):
    sys.exit(2)
for it in data:
    if isinstance(it, dict):
        labels = it.get("labels")
        g = "1" if isinstance(labels, list) and grill in labels else "0"
        title = (it.get("title", "") or "").replace("\t", " ").replace("\n", " ")
        print("%s\t%s\t%s" % (it.get("id", ""), title, g))
'
        return $?
    fi
    return 1
}

# 鮮度計算（orch-dispatch _compute_sync_freshness と同義・mtime 主指標・standalone のみ emit）。
#   marker mtime から経過分を計算し stale(>STALE_MIN)/unknown を判定して警告を stdout へ。
#   SCRIPTORIUM は遅延解決（--no-freshness 経路で不要な git 呼出しを避ける）。read-only。
_emit_freshness() {
    local scriptorium marker mtime now age_sec age_min ts
    # anchor 解決（engine 版）: 解決不能なら空のまま → marker 不在扱いで下の unknown 警告へ自然縮退
    # （advisory 経路ゆえ die しない・deploy-layout 依存の hardcode fallback は engine では持たない）。
    scriptorium="${ORCH_HANDOFF_SCRIPTORIUM:-$(_resolve_scriptorium 2>/dev/null || true)}"
    marker="${ORCH_HANDOFF_SYNC_MARKER:-$scriptorium/.beads/last-sync}"
    if [ -f "$marker" ]; then
        mtime="$(stat -c %Y "$marker" 2>/dev/null)"
        if [ -n "$mtime" ] && [[ "$mtime" =~ ^[0-9]+$ ]]; then
            now="$(date +%s 2>/dev/null)"
            if [ -n "$now" ] && [[ "$now" =~ ^[0-9]+$ ]]; then
                age_sec=$(( now - mtime ))
                [ "$age_sec" -lt 0 ] && age_sec=0   # clock skew（未来 mtime）→ fresh 側へ丸める。
                age_min=$(( age_sec / 60 ))
                ts="$(head -n1 "$marker" 2>/dev/null | tr -d '\000-\037')"   # 制御文字除去（端末注入回避）。
                if [ "$age_min" -gt "$STALE_MIN" ]; then
                    echo "  ⚠ foreign 鮮度警告: 最後の sync（.beads/last-sync）が約 ${age_min} 分前（stale 閾値 ${STALE_MIN} 分 超過${ts:+・最終 sync=$ts}）。"
                    echo "    hydrate された foreign needs-orch を silent 取りこぼしている可能性（上の一覧が full とは限らない）。\`scripts/orch-hydrate.sh\` で再 sync 後に再確認せよ（read-only＝sync は呼ばない）。"
                fi
                return 0
            fi
        fi
        # stat/date 失敗 → unknown へ縮退（下の unknown 警告へ）。
    fi
    echo "  ⚠ foreign 鮮度警告: sync 専用マーカー（.beads/last-sync）が無い/読取不可＝\`bd repo sync\`（orch-hydrate.sh）が一度も成功していない可能性。"
    echo "    foreign needs-orch を silent 取りこぼしている可能性（上の一覧が full とは限らない）。\`scripts/orch-hydrate.sh\` で sync 後に再確認せよ（read-only＝sync は呼ばない）。"
}

# ─────────────────────────────────────────────────────────────────────────────
# scan 本体（run_scan）: needs-orch bead を surface（read-only・observe のみ）
# ─────────────────────────────────────────────────────────────────────────────
run_scan() {
    echo "== orch-handoff-scan（needs-orch 検知線・foreign→orchestrator・read-only） =="

    local json rc
    json="$("$BD" list -l "$SCAN_LABEL" --json --no-pager --limit 0 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ⚠ scan 失敗（$BD list -l $SCAN_LABEL --json・rc=$rc）＝needs-orch 検知不能。bd 台帳/PATH を確認せよ。" >&2
        return 1
    fi

    local tsv
    tsv="$(_parse_scan "$json")" || {
        echo "  ⚠ scan JSON の parse に失敗（jq/python3 いずれも不可）＝needs-orch 検知不能。" >&2
        return 1
    }

    # needs-orch 無 → no-op（正常）。
    if [ -z "${tsv//[$' \t\n']/}" ]; then
        echo "  needs-orch: なし（orchestrator が引き取るべき foreign bead はありません）"
        [ "$EMIT_FRESHNESS" -eq 1 ] && _emit_freshness
        echo "  ── 集計: scanned=0 actionable=0 triage-hold=0"
        return 0
    fi

    local scanned=0 actionable=0 hold=0 id title grill
    while IFS=$'\t' read -r id title grill; do
        [ -n "$id" ] || continue
        scanned=$((scanned + 1))
        if [ "$grill" = "1" ]; then
            # needs-grill 併存 → triage 保留（per-bead・論点3）。orchestrator は grill 完了まで triage しない。
            hold=$((hold + 1))
            printf '  [TRIAGE 保留] %-14s %s  （needs-grill 併存＝grill 完了まで orchestrator は triage しない）\n' "$id" "$title"
        else
            actionable=$((actionable + 1))
            printf '  [needs-orch]  %-14s %s\n' "$id" "$title"
        fi
    done <<< "$tsv"

    [ "$EMIT_FRESHNESS" -eq 1 ] && _emit_freshness
    echo "  ── 集計: scanned=$scanned actionable=$actionable triage-hold=$hold"
    return 0
}

# === --self-test: hermetic 自己完結テスト（fail-closed・orch-jmu） ===
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t handoff-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    # fake bd: `list -l needs-orch ...` 引数を記録し、固定 JSON を返す（needs-orch 正例2 + 併存 needs-grill 1 +
    #   needs-orch 無しの負例1）。self-scope gate は SKIP env で無効化（cwd 非依存の hermetic）。
    mkdir -p "$st_tmp/bin"
    cat > "$st_tmp/bin/bd" <<'BDEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_LOG"
# needs-orch 3 件（うち1件 needs-grill 併存）+ needs-orch を持たない bead は返さない（bd の -l フィルタ相当）。
cat <<'JSON'
[
  {"id":"un-aaa","title":"foreign A needs orch","labels":["needs-orch"]},
  {"id":"sc-bbb","title":"foreign B needs orch and grill","labels":["needs-orch","needs-grill"]},
  {"id":"pk-ccc","title":"foreign C needs orch","labels":["needs-orch"]}
]
JSON
BDEOF
    chmod +x "$st_tmp/bin/bd"

    # 台帳 fixture（self-scope gate 用・skip する経路と gate する経路の両方を試す）。
    mkdir -p "$st_tmp/foreign/.beads"; printf '{"dolt_database":"un"}' > "$st_tmp/foreign/.beads/metadata.json"

    export BD_ARGS_LOG="$st_tmp/bd-args.log"
    : > "$BD_ARGS_LOG"

    # (1) scan（gate skip）: needs-orch 3 件・うち needs-grill 併存 1 件は TRIAGE 保留・他 2 件 actionable。
    out="$(ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$st_tmp/bin/bd" ORCH_HANDOFF_SYNC_MARKER="$st_tmp/nomarker" \
           bash "$_orch_hs_self" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] \
       && printf '%s' "$out" | grep -qF "[needs-orch]" \
       && printf '%s' "$out" | grep -q "un-aaa" \
       && printf '%s' "$out" | grep -q "pk-ccc" \
       && printf '%s' "$out" | grep -qF "[TRIAGE 保留]" \
       && printf '%s' "$out" | grep -q "sc-bbb" \
       && printf '%s' "$out" | grep -qF "scanned=3 actionable=2 triage-hold=1"; then
        _ok "scan: needs-orch 3 件・needs-grill 併存 1 件は per-bead で TRIAGE 保留・集計一致"
    else
        _fail "scan: 3件(actionable=2,hold=1)を期待したが不一致（rc=$rc）: [$out]"
    fi

    # (2) 截断禁止（p1）: 記録された bd 引数に `--limit 0` と `-l needs-orch` が含まれる。
    if grep -qF -- "-l needs-orch" "$BD_ARGS_LOG" && grep -qF -- "--limit 0" "$BD_ARGS_LOG"; then
        _ok "截断禁止: bd 呼出しに -l needs-orch と --limit 0（default-limit 截断禁止・p1/p2）"
    else
        _fail "截断禁止: bd 引数に -l needs-orch --limit 0 を期待したが不在: [$(cat "$BD_ARGS_LOG")]"
    fi

    # (3) per-bead 保留の teeth（sc-bbb だけが保留・un-aaa/pk-ccc は保留にしない）。
    if printf '%s' "$out" | grep -q "sc-bbb.*needs-grill 併存" \
       && ! printf '%s' "$out" | grep -q "un-aaa.*保留" \
       && ! printf '%s' "$out" | grep -q "pk-ccc.*保留"; then
        _ok "per-bead 保留: 併存 bead のみ保留・非併存 bead は actionable（DB 全体保留ではない）"
    else
        _fail "per-bead 保留: sc-bbb のみ保留を期待したが不一致: [$out]"
    fi

    # (4) 鮮度: stale marker（古い mtime）→ standalone で ⚠ 警告。--no-freshness では出さない。
    marker="$st_tmp/last-sync"; printf 'old\n' > "$marker"; touch -d '3 hours ago' "$marker" 2>/dev/null || touch "$marker"
    out_fresh="$(ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$st_tmp/bin/bd" ORCH_HANDOFF_SYNC_MARKER="$marker" ORCH_HANDOFF_STALE_MIN=60 \
                 bash "$_orch_hs_self" 2>&1)"
    out_nofresh="$(ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$st_tmp/bin/bd" ORCH_HANDOFF_SYNC_MARKER="$marker" ORCH_HANDOFF_STALE_MIN=60 \
                   bash "$_orch_hs_self" --no-freshness 2>&1)"
    if printf '%s' "$out_fresh" | grep -qF "鮮度警告" && ! printf '%s' "$out_nofresh" | grep -qF "鮮度警告"; then
        _ok "鮮度: stale marker で standalone は⚠警告・--no-freshness は委譲で無警告（p3）"
    else
        _fail "鮮度: standalone=警告 / --no-freshness=無警告 を期待したが不一致"
    fi

    # (4b) 鮮度: fresh marker（現在時刻 mtime）→ standalone でも無警告（always-warn 型偽陽性回帰を捕捉・cell-quality finding）。
    fresh_marker="$st_tmp/last-sync-fresh"; printf 'now\n' > "$fresh_marker"   # touch=現在時刻ゆえ age≈0（fresh）。
    out_freshok="$(ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$st_tmp/bin/bd" ORCH_HANDOFF_SYNC_MARKER="$fresh_marker" ORCH_HANDOFF_STALE_MIN=60 \
                   bash "$_orch_hs_self" 2>&1)"
    if ! printf '%s' "$out_freshok" | grep -qF "鮮度警告"; then
        _ok "鮮度: fresh marker（recent mtime）→ standalone でも無警告（fresh 分岐を pin・always-warn 偽陽性回帰を捕捉）"
    else
        _fail "鮮度: fresh marker で無警告を期待したが⚠警告が出た: [$out_freshok]"
    fi

    # (5) self-scope gate（gate 有効・foreign cwd）→ refuse・非0（誤台帳 scan を fail-closed で弾く）。
    out_gate="$(cd "$st_tmp/foreign" && ORCH_HANDOFF_BD="$st_tmp/bin/bd" bash "$_orch_hs_self" 2>&1)"; rc_gate=$?
    if [ "$rc_gate" -ne 0 ] && printf '%s' "$out_gate" | grep -qF "refusing to run"; then
        _ok "self-scope: foreign 台帳 cwd → refuse・非0（fail-closed）"
    else
        _fail "self-scope: foreign → refuse 非0 を期待したが不一致（rc=$rc_gate）: [$out_gate]"
    fi

    # (5b) self-scope 肯定側: orch 台帳 cwd（SKIP なし）→ gate 通過し scan が走る（always-refuse 回帰を捕捉・cell-quality finding）。
    mkdir -p "$st_tmp/orch/.beads"; printf '{"dolt_database":"orch"}' > "$st_tmp/orch/.beads/metadata.json"
    out_pos="$(cd "$st_tmp/orch" && ORCH_HANDOFF_BD="$st_tmp/bin/bd" ORCH_HANDOFF_SYNC_MARKER="$st_tmp/nomarker" bash "$_orch_hs_self" --no-freshness 2>&1)"; rc_pos=$?
    if [ "$rc_pos" -eq 0 ] && ! printf '%s' "$out_pos" | grep -qF "refusing to run" && printf '%s' "$out_pos" | grep -qF "scanned=3"; then
        _ok "self-scope 肯定側: orch 台帳 cwd → gate 通過し scan 実行（scanned=3・always-refuse 回帰を捕捉）"
    else
        _fail "self-scope 肯定側: orch cwd → gate 通過 scan を期待したが不一致（rc=$rc_pos）: [$out_pos]"
    fi

    if [ "$st_fail" -eq 0 ]; then echo "orch-handoff-scan --self-test: PASS"; exit 0
    else echo "orch-handoff-scan --self-test: FAIL" >&2; exit 1; fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# self-scope gate: orchestrator session（cwd の台帳 dolt_database == orch）でなければ何もしない
# ─────────────────────────────────────────────────────────────────────────────
if [ "${ORCH_HANDOFF_SKIP_SESSION_GATE:-}" != "1" ]; then
    DB="$(_ledger_dolt_database "$PWD")"
    if [ "$DB" != "$SELF_PREFIX" ]; then
        echo "orch-handoff-scan: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
        echo "  orchestrator session（cwd=orchestrator）から実行せよ。foreign 台帳を誤 scan しない fail-closed。" >&2
        exit 1
    fi
fi

run_scan

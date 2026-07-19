#!/usr/bin/env bash
# orch-delivery-observe.sh — 配送観測（delivery observation）の独立 read-only composable script（bd orch-4js9）
#
# 役割（裁定-cycle-signal + delivery-guarantee①・top-spec §1.1:85 / §5.4:246）──────────────────────
#   各 admin（宛先 project X）への `for:X` 便が「届いたか・滞留しているか」を **proxy 近似**で surface する。
#   session-start-workinprogress.sh の第4節「配送観測」の実ロジック本体（hook は本 script を read-only 実行するだけ）。
#   3 つを read-only で観測する:
#     (1) cycle 境界 proxy   : 各宛先 X の hydrated foreign copy の max(updated_at)＝admin X の最終 cycle 境界の近似。
#     (2) 推論配送 3 値       : 各 for:X 便を delivered / undelivered(滞留) / unknown(未確認) に分類（per-bead ack write なし）。
#     (3) 呼び鈴 proposal    : 滞留閾値超 ∧ 宛先窓 live なら「呼び鈴打ちますか」を **提案のみ** 出す（push は人間 go）。
#   加えて auto-compact 発火 marker channel の **読み側**（完全一致 label scan・producer 未 land ゆえ live 空 graceful）。
#
# proxy scope hard fence（fence5・本 script の責務境界）─────────────────────────────────────────────
#   本 script は **PROXY のみ**を実装する（heartbeat stamp READ 依存を持たない・forward-compatible）:
#     - cycle 境界近似 = hydrated foreign copy の max(updated_at)（admin heartbeat stamp が land すれば精度向上・別便 orch-0yof）。
#     - 滞留 age      = 自台帳 orch- の for:X bead の created_at → now。
#   admin heartbeat stamp（foreign 台帳への mtime stamp WRITE）は本便対象外。断定 up/down は出さず、境界は必ず
#   「proxy 近似（foreign 更新鮮度・heartbeat 未 land）」とラベルする。
#
# データ源（fence4・hydrated orch DB・read-only・自台帳 write なし）─────────────────────────────────
#   既 hydrate 済み orch DB（自 orch- bead + `bd repo sync` で hydrate された foreign copy）を `bd list --json` で
#   read-only に読む。hook 内で `bd repo sync`/hydrate はしない（鮮度は別便 orch-7ute の 30 分 timer へ委譲）。
#   `bd -C`/`--foreign-repo` 直読は使わない（worktree の embeddeddolt は gitignore で空＝false-BLOCKED を招く）。
#   stale hydrate は境界が古く見え over-surface（滞留の過検出＝配送 monitor として安全側・H-5 追認 2026-07-13）。
#   「自台帳 read のみ」= write-isolation（foreign 台帳へ書かない）の意（3 guards 準拠）。
#
# ★fence3 errata（bd の label prefix 非対応）: 契約 fence3 は `bd list -l for: --json` を指すが、bd の `-l` は
#   **完全一致**で prefix match しない（`bd list -l for:` は 0 件・`-l for:sc` のみ 5 件＝実測 2026-07-13）。ゆえに
#   全 bead を `bd list --json --no-pager --limit 0`（default-30 截断禁止・fence3 の趣意「全 for:X 便を取りこぼさない」を
#   満たす）で取得し、parser 側で label が `for:<X>` に一致する bead を抽出する（宛先 X→session 名 mapping を発明しない
#   ＝X は data 由来の label 値そのもの）。この置換は silently-choose でなく本 header に理由を残す（fence2/fence3）。
#
# 推論配送 3 値（fence3・unknown≠delivered 不変条件）──────────────────────────────────────────────
#   各 for:X 便（非 closed）を次の 3 値に分類する。**唯一の delivered 経路は created_at < 境界**:
#     - delivered  (配送済み・推論): created_at < 境界（両辺とも妥当 RFC3339 Z）。admin が created 後に cycle 済み。
#     - undelivered(滞留)          : created_at ≥ 境界。admin がまだ cycle していない＝未配送で滞留。
#     - unknown    (未確認)        : 境界取得不能（foreign copy なし/max 不能） **または** created_at 取得不能。
#   時刻比較は両辺 **RFC3339 Z 固定幅（20 char）の文字列比較**で統一する（epoch/local 変換を挟まない＝lexical==chrono）。
#   不変条件: **unknown・undelivered を配送済みと表示しない**（acceptance(3) の字義「境界前 bead を配送済みと誤らない」を
#   この不変条件へ言い換える errata＝境界『前』(created_at<境界)こそ delivered ゆえ、誤りは『境界後/取得不能を delivered と
#   する』方向。teeth は比較反転・unknown→delivered default を各 mutation で RED 化）。滞留 age は表示専用（epoch 換算・
#   判定には使わない）。
#
# 宛先窓 live 判定 + 呼び鈴（fence1/fence8・proposal-only）──────────────────────────────────────────
#   窓 live は共有 lib `lib/orch_liveness.sh` の `_liveness_windows`（session:window 正準形）を REUSE する
#   （canonical form を素朴再実装しない・riz1 drift 再導入禁止）。宛先 X の live 判定は `<X>:admin` の **完全一致**
#   （discovery-nudge 同型 fail-safe）。for:X の X（台帳 dolt_database 値 sc/ccs）→ session 名（scribe/cc-session）の
#   mapping を発明しない＝現状 live 窓はフル名 session（`scribe:admin`）で `sc:admin` に一致しないため、非一致時は
#   **呼び鈴を出さず**「滞留 age は surface + 宛先窓 live 未確認（topology write 側 orch-8rn8=for:ccs land 待ち・
#   transitional gap）」へ縮退する（滞留 surface は抑止しない）。呼び鈴は **提案のみ**＝push 実行系（orch-relay/
#   session-comm/tmux send-keys/inject-existing）を一切呼ばない（Tier2 push=人間 go・§1.2 ③）。
#
# self-scope gate（誤台帳 scan の防止・他 orch- script と同一機構）──────────────────────────────────
#   `bd list` は cwd の台帳に作用する。非 orch 台帳から走らせると foreign DB を scan して誤 surface する。cwd から
#   walk-up した最初の .beads/metadata.json の dolt_database が orch でなければ何もせず非 0 で抜ける（共有 lib
#   _ledger_dolt_database・fail-closed）。ORCH_DELIVERY_SKIP_SESSION_GATE=1 で skip（hermetic self-test 用）。
#
# fail-open（配送観測は cosmetic surface・hook は || true で包む）───────────────────────────────────
#   bd read 失敗 / python3 不在 / parse 不能は「配送観測不能」note を出して return 0（surface 機能ゆえ fail-open）。
#   self-scope gate だけは fail-closed（誤台帳 scan を弾く）。sandbox で実 live を叩けないことは BLOCKED 理由に
#   ならない（fence10・設計上不能）＝検証は hermetic bats + --self-test に限定。
#
# モード ────────────────────────────────────────────────────────────────────────────────────────────
#   （既定）observe : 配送観測を stdout へ（read-only・observe のみ）。
#   --self-test     : hermetic 自己完結テスト（fail-closed）。
#   --help
#
# env override（主に hermetic self-test / hook 用）───────────────────────────────────────────────────
#   ORCH_DELIVERY_BD            scan に使う bd 実体（既定: PATH 上の bd）。read-only（list のみ）。
#   ORCH_DELIVERY_TMUX          窓 live に使う tmux 実体（既定: PATH 上の tmux）。read-only（list-panes のみ）。
#   ORCH_DELIVERY_NOW_EPOCH     滞留 age 算出の現在時刻（epoch 秒・test 固定用）。未設定/非整数なら実時刻。
#   ORCH_DELIVERY_STALE_MIN     呼び鈴 point の滞留閾値（分・既定 60）。
#   ORCH_DELIVERY_COMPACT_LABEL auto-compact 発火 marker の完全一致 label（既定 auto-compact-fired・producer 未 land）。
#   ORCH_DELIVERY_SKIP_SESSION_GATE=1  self-scope gate を skip（hermetic self-test 用）。
#
# 検証: tests/scenarios/orch-delivery-observe.bats（hermetic: bd/tmux を env-stub・now 固定・3 値 + 呼び鈴点灯/
#   縮退 + auto-compact marker read + mutation 非空虚）+ 本 file の `--self-test`（fail-closed）。
#   **plugin 反映には新規 cld session 必須**（hook 統合分）。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard と同一値を共有）。
SELF_PREFIX="orch"

# --- 共有 self-scope lib を source（bd orch-t9z・SSOT = scripts/hooks/lib/orch_session.sh） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。★実 script 位置（BASH_SOURCE 相対）で
# 解決するので bats / --self-test が実 lib を確実に見つける。symlink 起動でも実体を解決（readlink -f）。
_orch_do_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(cd "$(dirname "$_orch_do_self")" 2>/dev/null && pwd)"
_ORCH_SESSION_LIB="$_SCRIPT_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-delivery-observe: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# --- 共有 liveness lib を source（bd orch-4js9 fence1・_liveness_windows を orch-dispatch と単一 SSOT で共有） ---
_ORCH_LIVENESS_LIB="$_SCRIPT_DIR/lib/orch_liveness.sh"
if [ -r "$_ORCH_LIVENESS_LIB" ]; then
    # shellcheck source=lib/orch_liveness.sh
    . "$_ORCH_LIVENESS_LIB"
else
    echo "orch-delivery-observe: 共有 liveness lib 不在: $_ORCH_LIVENESS_LIB（窓 live 判定不能・fail-closed）" >&2
    exit 1
fi

# 外部ツール / 設定（env で差替可・self-test 用）。
BD="${ORCH_DELIVERY_BD:-bd}"
TMUX_BIN="${ORCH_DELIVERY_TMUX:-tmux}"
STALE_MIN="${ORCH_DELIVERY_STALE_MIN:-60}"
[[ "$STALE_MIN" =~ ^[0-9]+$ ]] || STALE_MIN=60   # 非整数は既定 60 へ（他 orch script と同型の防御）。
COMPACT_LABEL="${ORCH_DELIVERY_COMPACT_LABEL:-auto-compact-fired}"

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --self-test) ;;   # 下方の --self-test ブロックで処理（ここでは無視）
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "orch-delivery-observe: unknown arg: $arg（--self-test / --help のみ）" >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# 配送計算エンジン（python3・fence3/fence4/fence6 の中核ロジック）
#   stdin=bd list JSON / env NOW_EPOCH,STALE_MIN,SELF_PREFIX,COMPACT_LABEL → TSV tagged 行を stdout へ:
#     BOUNDARY\t<X>\t<boundary_or_empty>
#     BEAD\t<X>\t<id>\t<state>\t<age_min>\t<stalled(0/1)>
#     COMPACT\t<id>
#   state ∈ {delivered, undelivered, unknown}。stalled=1 は state==undelivered ∧ age>STALE_MIN。
#   時刻比較は RFC3339 Z 固定幅の文字列比較（fence3）。age は epoch 換算（表示専用）。
# ─────────────────────────────────────────────────────────────────────────────
_DELIVERY_PY='
import sys, json, os, re
RFC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")   # RFC3339 Z 固定幅（20 char）
self_prefix = os.environ.get("SELF_PREFIX", "orch")
compact_label = os.environ.get("COMPACT_LABEL", "auto-compact-fired")
try:
    stale_min = int(os.environ.get("STALE_MIN", "60"))
except Exception:
    stale_min = 60
now_env = os.environ.get("NOW_EPOCH", "")
import time, calendar
if now_env.isdigit():
    now = int(now_env)
else:
    now = int(time.time())

def valid(ts):
    return isinstance(ts, str) and bool(RFC.match(ts))

def to_epoch(ts):
    # RFC3339 Z（UTC）→ epoch（表示 age 専用・判定には使わない）。妥当性は valid() で別途 gate。
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        return None

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if not isinstance(data, list):
    sys.exit(3)

# 宛先 X 集合（自 orch- bead の for:<X> label から抽出＝X→session mapping を発明しない・data 由来）。
# 境界 boundary(X) = id prefix==X の hydrated foreign copy の max(妥当 updated_at)。
forbeads = []      # (X, id, created_at, status)
prefix_max = {}    # X -> max updated_at (妥当のみ)
compact_ids = []
for it in data:
    if not isinstance(it, dict):
        continue
    bid = it.get("id", "") or ""
    labels = it.get("labels") or []
    if not isinstance(labels, list):
        labels = []
    # auto-compact marker（完全一致・fence6・read only）。
    if compact_label in labels:
        compact_ids.append(bid)
    # 宛先 max(updated_at)（foreign copy = id prefix==X）。prefix は id の最初の "-" までの segment。
    pfx = bid.split("-", 1)[0] if "-" in bid else bid
    upd = it.get("updated_at", "")
    if valid(upd):
        cur = prefix_max.get(pfx)
        if cur is None or upd > cur:
            prefix_max[pfx] = upd
    # for:<X> label を持つ非 closed bead（滞留候補）。closed は配送済み+処理済ゆえ除外。
    status = (it.get("status", "") or "")
    for lab in labels:
        if isinstance(lab, str) and lab.startswith("for:"):
            x = lab[4:]
            if x and status != "closed":
                forbeads.append((x, bid, it.get("created_at", ""), status))

# 宛先集合（for:X label 由来）を sort し境界を emit。
dests = sorted(set(x for (x, _b, _c, _s) in forbeads))
for x in dests:
    b = prefix_max.get(x)
    sys.stdout.write("BOUNDARY\t%s\t%s\n" % (x, b if b is not None else ""))

# 各 for:X 便を 3 値分類（唯一の delivered = created_at < 境界・両辺妥当 RFC3339 Z の文字列比較）。
for (x, bid, created, status) in sorted(forbeads):
    boundary = prefix_max.get(x)
    if not valid(created):
        state = "unknown"          # created_at 取得不能 → 未確認（配送済みと表示しない）
    elif boundary is None or not valid(boundary):
        state = "unknown"          # 境界取得不能 → 未確認（fence3 (B)）
    elif created < boundary:
        state = "delivered"        # 唯一の delivered 経路（fence3・境界前）
    else:
        state = "undelivered"      # created_at ≥ 境界 → 滞留（fence3 (A)）
    # age（表示専用・epoch 換算・fail-safe "?"）。
    ce = to_epoch(created) if valid(created) else None
    if ce is None:
        age = "?"
        stalled = 0
    else:
        a = (now - ce) // 60
        if a < 0:
            a = 0                  # clock skew（未来 created）→ fresh 側へ丸め
        age = str(a)
        stalled = 1 if (state == "undelivered" and a > stale_min) else 0
    sys.stdout.write("BEAD\t%s\t%s\t%s\t%s\t%d\n" % (x, bid, state, age, stalled))

for cid in compact_ids:
    sys.stdout.write("COMPACT\t%s\n" % cid)
'

# ─────────────────────────────────────────────────────────────────────────────
# observe 本体（run_observe）: 配送観測を surface（read-only・observe のみ・fail-open）
# ─────────────────────────────────────────────────────────────────────────────
run_observe() {
    echo "== orch-delivery-observe（配送観測・proxy 近似・read-only・呼び鈴は提案のみ） =="

    if ! command -v python3 >/dev/null 2>&1; then
        echo "  ⚠ 配送観測不能: python3 不在（配送計算エンジンが動かせない・fail-open skip）"
        return 0
    fi

    local json rc
    json="$("$BD" list --json --no-pager --limit 0 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ⚠ 配送観測不能: bd list 失敗（$BD・rc=$rc）。bd 台帳/PATH を確認せよ（fail-open skip）。"
        return 0
    fi

    local tsv
    tsv="$(printf '%s' "$json" | NOW_EPOCH="${ORCH_DELIVERY_NOW_EPOCH:-}" STALE_MIN="$STALE_MIN" \
            SELF_PREFIX="$SELF_PREFIX" COMPACT_LABEL="$COMPACT_LABEL" python3 -c "$_DELIVERY_PY" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "  ⚠ 配送観測不能: 配送計算エンジンが JSON parse に失敗（rc=$rc・fail-open skip）。"
        return 0
    fi

    # 窓 live 一覧を 1 回だけ取得（共有 lib・session:window 正準形）。
    local live_windows; live_windows="$(_liveness_windows "$TMUX_BIN")"

    # tsv を種別ごとに仕分けて surface する。
    local -A boundary_of=()
    local bead_lines="" compact_lines="" tag rest
    while IFS=$'\t' read -r tag rest; do
        [ -n "$tag" ] || continue
        case "$tag" in
            BOUNDARY)
                local bx bb
                IFS=$'\t' read -r bx bb <<< "$rest"
                boundary_of["$bx"]="$bb"
                ;;
            BEAD)    bead_lines+="$rest"$'\n' ;;
            COMPACT) compact_lines+="$rest"$'\n' ;;
        esac
    done <<< "$tsv"

    # 宛先ごとの cycle 境界 proxy（断定 up/down は出さない・fence5）。
    if [ "${#boundary_of[@]}" -eq 0 ]; then
        echo "  宛先: なし（for:X 便が自台帳に無い＝配送観測対象なし）"
    else
        local x
        for x in $(printf '%s\n' "${!boundary_of[@]}" | sort); do
            local b="${boundary_of[$x]}"
            if [ -n "$b" ]; then
                echo "  宛先 $x: cycle 境界 proxy=$b（foreign 更新鮮度近似・heartbeat 未 land ゆえ proxy）"
            else
                echo "  宛先 $x: cycle 境界 proxy=取得不能（$x-* foreign copy が hydrated DB に無い＝未確認）"
            fi
        done
    fi

    # 各 for:X 便の推論配送 3 値 + 呼び鈴（proposal-only）。
    local delivered=0 undelivered=0 unknown=0 bells=0 degraded=0
    local bx bid state age stalled
    while IFS=$'\t' read -r bx bid state age stalled; do
        [ -n "$bid" ] || continue
        case "$state" in
            delivered)
                delivered=$((delivered + 1))
                printf '    便 %-14s 宛先 %-6s [配送済み(推論)] created<境界・age %s 分\n' "$bid" "$bx" "$age"
                ;;
            undelivered)
                undelivered=$((undelivered + 1))
                if [ "$stalled" = "1" ]; then
                    # 滞留閾値超。宛先窓 <X>:admin が live か完全一致で判定（fence1）。
                    if printf '%s\n' "$live_windows" | grep -qxF "$bx:admin"; then
                        bells=$((bells + 1))
                        printf '    便 %-14s 宛先 %-6s [滞留] age %s 分(>閾値 %s)・宛先窓 %s:admin live\n' "$bid" "$bx" "$age" "$STALE_MIN" "$bx"
                        printf '      🔔 呼び鈴打ちますか？（提案のみ・push は人間 go＝§1.2 ③）｜根拠: 滞留 %s 分 > 閾値 %s 分 ∧ 宛先窓 %s:admin live\n' "$age" "$STALE_MIN" "$bx"
                    else
                        degraded=$((degraded + 1))
                        printf '    便 %-14s 宛先 %-6s [滞留] age %s 分(>閾値 %s)・宛先窓 live 未確認（%s:admin 非一致＝topology write 側 orch-8rn8 land 待ち・transitional gap）\n' "$bid" "$bx" "$age" "$STALE_MIN" "$bx"
                    fi
                else
                    printf '    便 %-14s 宛先 %-6s [滞留] age %s 分（閾値 %s 分 未満＝呼び鈴 point 未達）\n' "$bid" "$bx" "$age" "$STALE_MIN"
                fi
                ;;
            unknown)
                unknown=$((unknown + 1))
                printf '    便 %-14s 宛先 %-6s [未確認] 境界 or created_at 取得不能（配送済みと表示しない・unknown≠delivered）\n' "$bid" "$bx"
                ;;
        esac
    done <<< "$bead_lines"

    # auto-compact marker read（fence6・producer 未 land ゆえ live 空 graceful）。
    local compact_count=0 cid
    while IFS= read -r cid; do
        [ -n "$cid" ] || continue
        compact_count=$((compact_count + 1))
        printf '  ⚑ auto-compact 発火 marker: %s（cycle 規律破れ incident・強制回復モードで bd を一次 truth に再ブリーフ・top-spec §1.1:85）\n' "$cid"
    done <<< "$compact_lines"
    if [ "$compact_count" -eq 0 ]; then
        echo "  auto-compact marker: なし（label '$COMPACT_LABEL' 完全一致 0 件・producer=admin 焼き未 land ゆえ graceful）"
    fi

    echo "  ── 集計: delivered(推論)=$delivered undelivered(滞留)=$undelivered unknown(未確認)=$unknown 呼び鈴提案=$bells live未確認縮退=$degraded auto-compact=$compact_count"
    return 0
}

# === --self-test: hermetic 自己完結テスト（fail-closed・orch-4js9 fence2/3/6/8） ===
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t delivery-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    mkdir -p "$st_tmp/bin"
    # fake bd: list --json で固定 fixture を返す（引数記録も残す＝截断禁止 teeth）。
    #   NOW_EPOCH は 2026-07-13T12:00:00Z=1783944000 相当で固定して age を決定的にする（STL=360m>閾値 / FRS=30m<閾値）。
    #   fixture:
    #     - sc-old   updated 2026-07-13T00:00:00Z（宛先 sc の境界＝max）
    #     - orch-DLV  for:sc created 2026-07-12T00:00:00Z（境界前 → delivered）
    #     - orch-STL  for:sc created 2026-07-13T06:00:00Z（境界後・age 6h>閾値 → undelivered 滞留・呼び鈴 point 到達）
    #     - orch-FRS  for:sc created 2026-07-13T11:30:00Z（境界後だが age 30m<閾値 → undelivered だが呼び鈴 point 未達・minor#3 teeth）
    #     - orch-UNK  for:zz（宛先 zz は foreign copy 無し → 境界取得不能 → unknown）
    #     - orch-CLZ  for:sc status=closed（配送済+処理済ゆえ滞留候補から除外・どの bucket にも計上しない・minor#1 teeth）
    #     - orch-CMP  label auto-compact-fired（marker read）
    cat > "$st_tmp/bin/bd" <<'BDEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_LOG"
cat <<'JSON'
[
  {"id":"sc-old","title":"scribe foreign copy","labels":[],"status":"open","created_at":"2026-07-13T00:00:00Z","updated_at":"2026-07-13T00:00:00Z"},
  {"id":"orch-DLV","title":"delivered bin","labels":["for:sc"],"status":"open","created_at":"2026-07-12T00:00:00Z","updated_at":"2026-07-12T00:00:00Z"},
  {"id":"orch-STL","title":"stalled bin","labels":["for:sc"],"status":"open","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"},
  {"id":"orch-FRS","title":"fresh undelivered bin","labels":["for:sc"],"status":"open","created_at":"2026-07-13T11:30:00Z","updated_at":"2026-07-13T11:30:00Z"},
  {"id":"orch-UNK","title":"unknown-dest bin","labels":["for:zz"],"status":"open","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"},
  {"id":"orch-CLZ","title":"closed bin","labels":["for:sc"],"status":"closed","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"},
  {"id":"orch-CMP","title":"compact marker","labels":["auto-compact-fired"],"status":"open","created_at":"2026-07-13T06:00:00Z","updated_at":"2026-07-13T06:00:00Z"}
]
JSON
BDEOF
    chmod +x "$st_tmp/bin/bd"
    export BD_ARGS_LOG="$st_tmp/bd-args.log"; : > "$BD_ARGS_LOG"

    # stub tmux（窓 fixture）: $TMUX_WINDOWS_FILE の行を session:window 形で返す（liveness lib と同契約）。
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
    NOW="1783944000"   # 2026-07-13T12:00:00Z（fixture の age を決定的にする・STL=360m>閾値 / FRS=30m<閾値）

    _run() {  # $* extra env assignments 済み前提で observe を起動し stdout+stderr を返す
        ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$st_tmp/bin/bd" ORCH_DELIVERY_TMUX="$st_tmp/bin/tmux" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_STALE_MIN=60 bash "$_orch_do_self" 2>&1
    }

    # (A) 境界後→滞留 / (C) 境界前→delivered / (B) 境界不能→unknown（fence3 3 値の陽性 assert）。
    # まず窓 live 未一致（scribe:admin のみ）＝縮退経路: 滞留は出るが呼び鈴は出ない（fence1 縮退 modality）。
    printf 'scribe:admin\n' > "$TMUX_WINDOWS_FILE"
    out="$(_run)"
    if printf '%s' "$out" | grep -q "orch-DLV.*配送済み(推論)" \
       && printf '%s' "$out" | grep -q "orch-STL.*滞留" \
       && printf '%s' "$out" | grep -q "orch-UNK.*未確認"; then
        _ok "3値: 境界前→delivered(DLV) / 境界後→undelivered滞留(STL) / 境界不能→unknown(UNK) を陽性 assert（fence3 A/B/C）"
    else
        _fail "3値: delivered/undelivered/unknown の陽性を期待したが不一致: [$out]"
    fi
    # 縮退 modality（fence1）: 窓が sc:admin に非一致（scribe:admin のみ）→ 呼び鈴出さず滞留 age は surface。
    if printf '%s' "$out" | grep -q "宛先窓 live 未確認" \
       && ! printf '%s' "$out" | grep -q "🔔 呼び鈴打ちますか"; then
        _ok "縮退: フル名 session(scribe:admin)のみ live・sc:admin 非一致 → 呼び鈴出さず滞留 age は surface（fence1 transitional gap）"
    else
        _fail "縮退: sc:admin 非一致で呼び鈴抑止 + 滞留 surface を期待したが不一致: [$out]"
    fi

    # (2) 呼び鈴点灯（acceptance(2)）: 宛先窓を sc:admin 完全一致にすると滞留超 STL で呼び鈴提案が点灯する。
    printf 'sc:admin\n' > "$TMUX_WINDOWS_FILE"
    out_bell="$(_run)"
    if printf '%s' "$out_bell" | grep -q "🔔 呼び鈴打ちますか" \
       && printf '%s' "$out_bell" | grep -q "呼び鈴提案=1"; then
        _ok "呼び鈴点灯(acceptance(2)): 滞留超(STL) ∧ 宛先窓 sc:admin live → 呼び鈴提案が点灯"
    else
        _fail "呼び鈴点灯: sc:admin live で呼び鈴提案を期待したが不一致: [$out_bell]"
    fi

    # (minor#3) 呼び鈴 point 未達（滞留閾値 gate a>stale_min の負側）: FRS は undelivered だが age 30m<60 ゆえ
    #   sc:admin live でも呼び鈴を出さず「閾値 未満＝呼び鈴 point 未達」に留まる（呼び鈴提案=1＝STL のみ・FRS は加算しない）。
    _frs="$(printf '%s\n' "$out_bell" | grep 'orch-FRS')"
    if printf '%s' "$_frs" | grep -q "呼び鈴 point 未達" \
       && ! printf '%s' "$_frs" | grep -q "🔔"; then
        _ok "呼び鈴 point 未達(minor#3): FRS(undelivered ∧ age<閾値) は sc:admin live でも呼び鈴を出さず『point 未達』surface"
    else
        _fail "呼び鈴 point 未達: FRS が『point 未達』で呼び鈴を出さないことを期待したが不一致: [$_frs]"
    fi

    # (minor#1) closed 除外（滞留候補フィルタ status!=closed の teeth）: orch-CLZ(for:sc・status=closed)は forbeads から
    #   除外され、どの bucket にも計上されず一切 surface しない（呼び鈴 point の芽にならない・over-surface しない）。
    if ! printf '%s' "$out_bell" | grep -q "orch-CLZ"; then
        _ok "closed 除外(minor#1): closed for:X 便(orch-CLZ)は滞留候補から除外され surface しない（配送済+処理済）"
    else
        _fail "closed 除外: orch-CLZ が surface されない（除外）ことを期待したが混入: [$out_bell]"
    fi

    # (2-neg-static) proposal-only 静的 grep（fence8）: **runtime 経路** run_observe の本体に push 実行系
    #   （send-keys / inject-existing / orch-relay / session-comm）が一切現れない（comment/自己テストの言及と弁別する
    #   ため関数本体に scope＝素朴な全文 grep は本 header の説明文や本 assertion 自身に誤 match するゆえ scope する）。
    _run_observe_body="$(awk '/^run_observe\(\) \{/,/^\}/' "$_orch_do_self")"
    if ! printf '%s' "$_run_observe_body" | grep -Eq 'send-keys|inject-existing|orch-relay|session-comm'; then
        _ok "proposal-only 静的(fence8): runtime run_observe 本体に push 実行系(send-keys/inject-existing/orch-relay/session-comm)の call が無い"
    else
        _fail "proposal-only 静的: run_observe 本体に push 実行系の call が混入（Tier2 push=人間 go 違反）: [$_run_observe_body]"
    fi

    # (2-neg-behavioral) proposal-only 挙動（fence8）: 呼び鈴点灯経路で push 実行系を実際に呼ばないことを sentinel で pin。
    #   stub tmux は send-keys で $SENDKEYS_SENTINEL を、PATH stub orch-relay.sh/session-comm.sh は各 sentinel を touch する。
    #   呼び鈴点灯（sc:admin live）後にどの sentinel も不在＝push を一切発火していない証明（提案テキストは存在する）。
    printf 'sc:admin\n' > "$TMUX_WINDOWS_FILE"
    export SENDKEYS_SENTINEL="$st_tmp/sendkeys-fired"; rm -f "$SENDKEYS_SENTINEL"
    cat > "$st_tmp/bin/tmux-push-trap" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  send-keys) : >> "$SENDKEYS_SENTINEL"; exit 0 ;;
  list-panes)
    fmt=""; prevf=""
    for a in "$@"; do [ "$prevf" = "-F" ] && fmt="$a"; prevf="$a"; done
    if [ -f "${TMUX_WINDOWS_FILE:-/nonexistent}" ]; then
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in *:*) sess="${line%%:*}"; win="${line#*:}" ;; *) sess="orch"; win="$line" ;; esac
        case "$fmt" in *session_name*) printf '%s:%s\n' "$sess" "$win" ;; *) printf '%s\n' "$win" ;; esac
      done < "$TMUX_WINDOWS_FILE"
    fi
    exit 0 ;;
esac
exit 0
STUB
    chmod +x "$st_tmp/bin/tmux-push-trap"
    export RELAY_SENTINEL="$st_tmp/relay-fired"; export SESSCOMM_SENTINEL="$st_tmp/sesscomm-fired"; rm -f "$RELAY_SENTINEL" "$SESSCOMM_SENTINEL"
    printf '#!/usr/bin/env bash\n: >> "$RELAY_SENTINEL"\nexit 0\n'    > "$st_tmp/bin/orch-relay.sh"
    printf '#!/usr/bin/env bash\n: >> "$SESSCOMM_SENTINEL"\nexit 0\n' > "$st_tmp/bin/session-comm.sh"
    chmod +x "$st_tmp/bin/orch-relay.sh" "$st_tmp/bin/session-comm.sh"
    out_nopush="$(cd "$st_tmp/orch-behav" 2>/dev/null || { mkdir -p "$st_tmp/orch-behav/.beads"; printf '{"dolt_database":"orch"}' > "$st_tmp/orch-behav/.beads/metadata.json"; cd "$st_tmp/orch-behav"; }
        PATH="$st_tmp/bin:$PATH" ORCH_DELIVERY_BD="$st_tmp/bin/bd" ORCH_DELIVERY_TMUX="$st_tmp/bin/tmux-push-trap" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_STALE_MIN=60 bash "$_orch_do_self" 2>&1)"
    if printf '%s' "$out_nopush" | grep -q "🔔 呼び鈴打ちますか" \
       && [ ! -e "$SENDKEYS_SENTINEL" ] && [ ! -e "$RELAY_SENTINEL" ] && [ ! -e "$SESSCOMM_SENTINEL" ]; then
        _ok "proposal-only 挙動(fence8): 呼び鈴点灯後も send-keys/orch-relay/session-comm sentinel 全不在＝提案のみ・push 未発火"
    else
        _fail "proposal-only 挙動: 呼び鈴提案存在 ∧ push sentinel 全不在を期待したが不一致（sk=$([ -e "$SENDKEYS_SENTINEL" ]&&echo fired)  relay=$([ -e "$RELAY_SENTINEL" ]&&echo fired)  sc=$([ -e "$SESSCOMM_SENTINEL" ]&&echo fired)）: [$out_nopush]"
    fi

    # (6) auto-compact marker read（fence6）: label auto-compact-fired の bead を surface する。
    if printf '%s' "$out_bell" | grep -q "auto-compact 発火 marker: orch-CMP"; then
        _ok "auto-compact marker read(fence6): 完全一致 label の bead を surface（producer 未 land でも read 経路は動く）"
    else
        _fail "auto-compact marker: orch-CMP の surface を期待したが不一致: [$out_bell]"
    fi

    # (6-graceful) marker 無し fixture では graceful（live 空を実装漏れと誤診しない）。
    out_nomark="$(ORCH_DELIVERY_SKIP_SESSION_GATE=1 ORCH_DELIVERY_BD="$st_tmp/bin/bd" ORCH_DELIVERY_TMUX="$st_tmp/bin/tmux" \
        ORCH_DELIVERY_NOW_EPOCH="$NOW" ORCH_DELIVERY_COMPACT_LABEL="no-such-label-zzz" bash "$_orch_do_self" 2>&1)"
    if printf '%s' "$out_nomark" | grep -q "auto-compact marker: なし"; then
        _ok "auto-compact graceful(fence6): 完全一致 0 件 → 『なし（producer 未 land）』で graceful（fail-open）"
    else
        _fail "auto-compact graceful: 0 件で graceful note を期待したが不一致: [$out_nomark]"
    fi

    # 截断禁止（fence3）: bd 呼出しに --limit 0（default-30 截断禁止）。
    if grep -qF -- "--limit 0" "$BD_ARGS_LOG"; then
        _ok "截断禁止(fence3): bd list に --limit 0（default-30 截断禁止）"
    else
        _fail "截断禁止: bd 引数に --limit 0 を期待したが不在: [$(cat "$BD_ARGS_LOG")]"
    fi

    # self-scope gate（gate 有効・foreign cwd）→ refuse・非0（誤台帳 scan を fail-closed で弾く）。
    mkdir -p "$st_tmp/foreign/.beads"; printf '{"dolt_database":"un"}' > "$st_tmp/foreign/.beads/metadata.json"
    out_gate="$(cd "$st_tmp/foreign" && ORCH_DELIVERY_BD="$st_tmp/bin/bd" ORCH_DELIVERY_TMUX="$st_tmp/bin/tmux" bash "$_orch_do_self" 2>&1)"; rc_gate=$?
    if [ "$rc_gate" -ne 0 ] && printf '%s' "$out_gate" | grep -qF "refusing to run"; then
        _ok "self-scope: foreign 台帳 cwd → refuse・非0（fail-closed）"
    else
        _fail "self-scope: foreign → refuse 非0 を期待したが不一致（rc=$rc_gate）: [$out_gate]"
    fi

    # self-scope 肯定側: orch 台帳 cwd（SKIP なし）→ gate 通過し observe が走る（always-refuse 回帰を捕捉）。
    mkdir -p "$st_tmp/orch/.beads"; printf '{"dolt_database":"orch"}' > "$st_tmp/orch/.beads/metadata.json"
    printf 'sc:admin\n' > "$TMUX_WINDOWS_FILE"
    out_pos="$(cd "$st_tmp/orch" && ORCH_DELIVERY_BD="$st_tmp/bin/bd" ORCH_DELIVERY_TMUX="$st_tmp/bin/tmux" ORCH_DELIVERY_NOW_EPOCH="$NOW" bash "$_orch_do_self" 2>&1)"; rc_pos=$?
    if [ "$rc_pos" -eq 0 ] && ! printf '%s' "$out_pos" | grep -qF "refusing to run" && printf '%s' "$out_pos" | grep -q "集計:"; then
        _ok "self-scope 肯定側: orch 台帳 cwd → gate 通過し observe 実行（always-refuse 回帰を捕捉）"
    else
        _fail "self-scope 肯定側: orch cwd → gate 通過 observe を期待したが不一致（rc=$rc_pos）: [$out_pos]"
    fi

    if [ "$st_fail" -eq 0 ]; then echo "orch-delivery-observe --self-test: PASS"; exit 0
    else echo "orch-delivery-observe --self-test: FAIL" >&2; exit 1; fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# self-scope gate: orchestrator session（cwd の台帳 dolt_database == orch）でなければ何もしない
# ─────────────────────────────────────────────────────────────────────────────
if [ "${ORCH_DELIVERY_SKIP_SESSION_GATE:-}" != "1" ]; then
    DB="$(_ledger_dolt_database "$PWD")"
    if [ "$DB" != "$SELF_PREFIX" ]; then
        echo "orch-delivery-observe: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
        echo "  orchestrator session（cwd=orchestrator）から実行せよ。foreign 台帳を誤 scan しない fail-closed。" >&2
        exit 1
    fi
fi

run_observe

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
# 重複便 hold（bd orch-ygbz A 群・重複 ack 生成器の閉塞）─────────────────────────────
#   needs-orch は **foreign 台帳の bead に付くラベル**であり、orchestrator は write-isolation により外せない。
#   ゆえに ack 便を出しても当該 foreign bead は毎 session actionable として surface し続け、各 session が
#   新しい ack 便を作る（実測: foreign bead 1 件に対し ack 便 5 本）。これは race ではなく恒常状態＝構造的な重複
#   生成器。よって「自台帳に当該 foreign bead 宛の open な courier 便が既に在る」ものを **重複便 hold** として
#   actionable から落とす（既存の needs-grill 由来 triage 保留とは別クラス＝集計の内訳で弁別する）。
#
#   hold 述語（orch-ygbz notes fence ■4 の 6 条件・**全て**満たすときに限る。silently-choose 禁止）:
#     (1) 根拠便の id prefix が orch-（hydrate された foreign copy を根拠にしない）。
#     (2) 根拠便の status != closed（open / in_progress / deferred / blocked を含む「非 closed」）。
#     (3) 根拠便の labels に `for:<X>` があり X が対象 foreign id の prefix と **完全一致**（宛先は labels のみを
#         truth にする＝title の [for:X] は実 label と食い違う実データがある）。
#     (4) 根拠便の labels に `courier` を持つ（self-dev / 調査 bead を抑制器にしない）。
#     (5) 対象 foreign id が根拠便の title / description / notes のいずれかに **語境界一致**で出現
#         （dotted child id が実在するため素の substring 一致は禁止）。
#     (6) 根拠便の created_at が対象 foreign bead の created_at より後（対象より古い言及を根拠にしない）。
#
#   fail 方向（不可逆性の非対称・fence ■4）: false-hold（intake 埋葬）は不可逆・false-actionable（重複 ack）は
#   可逆ゆえ、判定に迷う枝は必ず **surface 側**へ倒す。自台帳の全文走査（`bd list --all`）が失敗・parse 不能・
#   python3 不在なら hold にも actionable にも断定せず **判定不能**（語彙 SSOT = lib/orch_observe_vocab.sh）
#   として従来どおり surface 側に残し、集計に `dup=判定不能` と出す（黙って落とさない・fence ■5）。
#   hold 行は件数だけでなく `foreign-id ← 根拠便 id 群` を 1 行ずつ列挙する（件数のみは埋葬と等価）。
#   ★取りこぼし（label 衛生の破れで for: 値が不一致な便など）は actionable のまま残るのが正しい fail 方向。
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
#   lib/orch_anchor.sh（_resolve_scriptorium＝鮮度 marker の SCRIPTORIUM anchor 動的解決・E2 検証付き）と
#   lib/orch_observe_vocab.sh（ORCH_OBSERVE_UNDECIDABLE＝「判定不能」の語彙 SSOT・orch-ygbz C1）を
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
COURIER_LABEL="courier"    # 重複便 hold の根拠便に要求するラベル（fence ■4 条件(4)・orch-ygbz）。

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

# --- 共有 observe 語彙 lib を source（bd orch-ygbz C1・「判定不能」を 2 script 単一 SSOT で共有） ---
# ORCH_OBSERVE_UNDECIDABLE を提供する。orch-delivery-observe.sh と同一定数を consume することで、observe 層の
# 「観測していない」表示語が 2 script 間で drift するのを防ぐ（drift teeth = orch-delivery-observe.bats (vocab-drift)）。
_ORCH_VOCAB_LIB="$_SCRIPT_DIR/lib/orch_observe_vocab.sh"
if [ -r "$_ORCH_VOCAB_LIB" ]; then
    # shellcheck source=lib/orch_observe_vocab.sh
    . "$_ORCH_VOCAB_LIB"
else
    echo "orch-handoff-scan: 共有 observe 語彙 lib 不在: $_ORCH_VOCAB_LIB（状態語の SSOT 不明・fail-closed）" >&2
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

# scan JSON（$1）→ "<id>\t<title>\t<grill-flag>\t<created_at>" 行。jq 主・python3 フォールバック（両者 labels を正しく解釈）。
#   grill-flag: labels 配列に needs-grill を含めば "1"・無ければ "0"（per-bead 保留判定に使う・p5）。
#   created_at: 重複便 hold の条件(6)〔根拠便が対象より後〕に使う（欠落/不正は空欄＝hold しない側へ倒す・orch-ygbz）。
#   title/notes 中の TAB/改行は列区切りを壊すため空白へ潰す（防御的）。どの parser も使えない/失敗は非 0。
_parse_scan() {
    local json="$1" out rc
    if command -v jq >/dev/null 2>&1; then
        out="$(printf '%s' "$json" | jq -r '
            .[]? | [
              .id,
              ((.title // "") | gsub("[\t\n]"; " ")),
              (if ((.labels // []) | index("'"$GRILL_LABEL"'")) != null then "1" else "0" end),
              (.created_at // "")
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
        print("%s\t%s\t%s\t%s" % (it.get("id", ""), title, g, it.get("created_at", "") or ""))
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

# 重複便 hold の判定エンジン（orch-ygbz A 群・fence ■4 の 6 条件）。
#   stdin  = 自台帳全文 JSON（bd list --all）。env TARGETS = "<foreign-id>\t<created_at>" 行。
#   stdout = "<foreign-id>\t<根拠便 id 群（空白区切り・sort 済）>" 行（hold 対象のみ）。
#   ★語境界一致（条件5）: dotted child id（orch-22jj.2 等）が実在するため素の substring 一致は禁止
#     ＝前後が [0-9A-Za-z._-] でないことを lookaround で要求する（親 id が child id の部分文字列になる罠を封鎖）。
#   ★fail 方向: 判定材料（created_at）が不正な側は hold しない＝surface 側へ倒す（false-hold は不可逆）。
_DUP_PY='
import sys, json, os, re
self_prefix = os.environ.get("SELF_PREFIX", "orch")
courier_label = os.environ.get("COURIER_LABEL", "courier")
RFC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")   # RFC3339 Z 固定幅（lexical==chrono）

def valid(ts):
    return isinstance(ts, str) and bool(RFC.match(ts))

targets = []
for line in os.environ.get("TARGETS", "").split("\n"):
    if not line.strip():
        continue
    cols = line.split("\t")
    if len(cols) < 2:
        continue
    targets.append((cols[0], cols[1]))

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(3)
if not isinstance(data, list):
    sys.exit(3)

holders = []   # (id, {for 値}, created_at, 全文)
for it in data:
    if not isinstance(it, dict):
        continue
    bid = it.get("id") or ""
    if not bid.startswith(self_prefix + "-"):          # (1) 自台帳 bead のみ（foreign copy を根拠にしない）
        continue
    if (it.get("status") or "") == "closed":           # (2) 非 closed（open/in_progress/deferred/blocked）
        continue
    labels = it.get("labels")
    if not isinstance(labels, list) or courier_label not in labels:   # (4) courier 便のみ
        continue
    fors = set(l[4:] for l in labels if isinstance(l, str) and l.startswith("for:") and len(l) > 4)
    if not fors:                                       # (3) の材料（宛先は labels のみを truth にする）
        continue
    created = it.get("created_at") or ""
    if not valid(created):                             # (6) の材料（不明なら hold しない＝surface 側）
        continue
    text = "\n".join([str(it.get(k) or "") for k in ("title", "description", "notes")])
    holders.append((bid, fors, created, text))

for (tid, tcreated) in targets:
    if not valid(tcreated):                            # (6) 対象側が不明なら hold しない
        continue
    pfx = tid.split("-", 1)[0] if "-" in tid else tid
    pat = re.compile(r"(?<![0-9A-Za-z._-])" + re.escape(tid) + r"(?![0-9A-Za-z._-])")
    hits = sorted(b for (b, fors, c, text) in holders
                  if pfx in fors and c > tcreated and pat.search(text))   # (3)(6)(5)
    if hits:
        sys.stdout.write("%s\t%s\n" % (tid, " ".join(hits)))
'

# 重複便 hold を引く（$1 = needs-orch TSV）。stdout は _DUP_PY と同形。
#   rc=0 判定成功（0 件 hold なら空 stdout）/ rc=1 判定不能（python3 不在・bd 失敗・parse 不能）。
#   ★rc=1 は「hold 0 件」ではない: 呼び元は判定不能として全件を surface 側へ残す（fence ■5）。
_dup_holds() {
    local tsv="$1" targets json rc out
    command -v python3 >/dev/null 2>&1 || return 1
    # 対象は "<id>\t<created_at>"（_parse_scan の 1,4 列目）。空 id 行は落とす。
    targets="$(awk -F'\t' 'NF>=4 && $1!="" { print $1 "\t" $4 }' <<< "$tsv")"
    [ -n "$targets" ] || return 1
    # 自台帳の全文走査（title/description/notes を読むため --all の全件が要る・截断禁止 --limit 0）。
    json="$("$BD" list --all --json --no-pager --limit 0 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    # ★producer は printf の command-substitution 経由（herestring は /tmp が RO の sandbox で落ちうる）。
    #   python3 は stdin を全読するため SIGPIPE 早期 exit は起きない（_parse_scan と同型）。
    out="$(printf '%s' "$json" | TARGETS="$targets" SELF_PREFIX="$SELF_PREFIX" COURIER_LABEL="$COURIER_LABEL" \
           python3 -c "$_DUP_PY")"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    printf '%s' "$out"
    return 0
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

    # needs-orch 無 → no-op（正常）。重複便 hold の走査も不要（対象 0 件＝bd 追加呼出しをしない）。
    if [ -z "${tsv//[$' \t\n']/}" ]; then
        echo "  needs-orch: なし（orchestrator が引き取るべき foreign bead はありません）"
        [ "$EMIT_FRESHNESS" -eq 1 ] && _emit_freshness
        echo "  ── 集計: scanned=0 actionable=0 triage-hold=0（grill=0 dup=0）"
        return 0
    fi

    # 重複便 hold（orch-ygbz A 群）: 自台帳に当該 foreign bead 宛の open な courier 便が既に在るかを引く。
    #   dup_ok=0（判定不能）のときは hold を一切立てず、全件を従来どおり surface 側へ残す（fence ■5・fail-safe）。
    local dup_tsv dup_ok=1
    dup_tsv="$(_dup_holds "$tsv")" || dup_ok=0
    local -A dup_of=()
    if [ "$dup_ok" -eq 1 ] && [ -n "$dup_tsv" ]; then
        local dtid dhits
        while IFS=$'\t' read -r dtid dhits; do
            [ -n "$dtid" ] || continue
            dup_of["$dtid"]="$dhits"
        done <<< "$dup_tsv"
    fi

    local scanned=0 actionable=0 hold=0 grill_hold=0 dup_hold=0 id title grill created
    while IFS=$'\t' read -r id title grill created; do
        [ -n "$id" ] || continue
        scanned=$((scanned + 1))
        if [ "$grill" = "1" ]; then
            # needs-grill 併存 → triage 保留（per-bead・論点3）。orchestrator は grill 完了まで triage しない。
            hold=$((hold + 1)); grill_hold=$((grill_hold + 1))
            printf '  [TRIAGE 保留] %-14s %s  （needs-grill 併存＝grill 完了まで orchestrator は triage しない）\n' "$id" "$title"
        elif [ -n "${dup_of[$id]:-}" ]; then
            # 自台帳に既存の open な courier 便あり → 重複便 hold（重複 ack 生成器の閉塞・orch-ygbz）。
            # ★根拠便 id 群を必ず列挙する（件数のみは埋葬と等価・fence ■5）。行頭 【 は boot 表示の rank-B token。
            hold=$((hold + 1)); dup_hold=$((dup_hold + 1))
            printf '  【重複便 hold】%-14s ← %s  （自台帳に当該 foreign bead 宛の open な courier 便が既存＝新規 ack を起票しない）\n' "$id" "${dup_of[$id]}"
        else
            actionable=$((actionable + 1))
            printf '  [needs-orch]  %-14s %s\n' "$id" "$title"
        fi
    done <<< "$tsv"

    # 判定不能（自台帳の全文走査が失敗・parse 不能・python3 不在）: hold にも actionable にも断定せず surface 側に残す。
    local dup_field="$dup_hold"
    if [ "$dup_ok" -ne 1 ]; then
        dup_field="$ORCH_OBSERVE_UNDECIDABLE"
        printf '  【重複便 %s】自台帳の全文走査（%s list --all）が失敗/parse 不能/python3 不在＝既存 ack 便の有無を断定できない。上の一覧は重複便を含みうる（hold せず全件 surface・false-hold は不可逆ゆえ surface 側へ倒す）。\n' \
               "$ORCH_OBSERVE_UNDECIDABLE" "$BD"
    fi

    [ "$EMIT_FRESHNESS" -eq 1 ] && _emit_freshness
    echo "  ── 集計: scanned=$scanned actionable=$actionable triage-hold=$hold（grill=$grill_hold dup=$dup_field）"
    return 0
}

# === --self-test: hermetic 自己完結テスト（fail-closed・orch-jmu） ===
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t handoff-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    # fake bd: 引数を記録し **argv 分岐**で JSON を返す（実 bd の 2 経路を faithful に模写・orch-ygbz）:
    #   `--all` あり  → 自台帳全文走査（重複便 hold の根拠便 fixture・$ALL_JSON_FILE の中身）
    #   `--all` なし  → `-l needs-orch` の結果（needs-orch 正例2 + 併存 needs-grill 1）
    #   ※argv 非分岐だと 2 本目の query を足した瞬間に hold 経路が空虚 PASS する（fence ■16(1)）。
    # self-scope gate は SKIP env で無効化（cwd 非依存の hermetic）。
    mkdir -p "$st_tmp/bin"
    cat > "$st_tmp/bin/bd" <<'BDEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_LOG"
case "$*" in
  *--all*)
    cat "${ALL_JSON_FILE:-/dev/null}"
    ;;
  *)
    cat <<'JSON'
[
  {"id":"un-aaa","title":"foreign A needs orch","labels":["needs-orch"],"created_at":"2026-07-01T00:00:00Z"},
  {"id":"sc-bbb","title":"foreign B needs orch and grill","labels":["needs-orch","needs-grill"],"created_at":"2026-07-01T00:00:00Z"},
  {"id":"pk-ccc","title":"foreign C needs orch","labels":["needs-orch"],"created_at":"2026-07-01T00:00:00Z"}
]
JSON
    ;;
esac
BDEOF
    chmod +x "$st_tmp/bin/bd"

    # 自台帳全文走査の既定 fixture = 空（＝重複便 hold 0 件。既存 assert を hold 経路から独立させる）。
    export ALL_JSON_FILE="$st_tmp/all-empty.json"; printf '[]' > "$ALL_JSON_FILE"

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

    # (6) 重複便 hold（orch-ygbz A 群・fence ■4 の 6 条件）: un-aaa 宛の open な courier 便が 2 本あると
    #     un-aaa は actionable から落ち、根拠便 2 本を列挙した hold 行になる。pk-ccc（根拠便なし）は actionable のまま。
    dup_json="$st_tmp/all-dup.json"
    cat > "$dup_json" <<'JSON'
[
  {"id":"orch-h1","title":"[for:un] ack 便 1","description":"un-aaa の受け","notes":"","labels":["courier","for:un"],"status":"open","created_at":"2026-07-02T00:00:00Z"},
  {"id":"orch-h2","title":"[for:un] ack 便 2","description":"","notes":"根拠: un-aaa を引き取る","labels":["courier","for:un"],"status":"in_progress","created_at":"2026-07-03T00:00:00Z"},
  {"id":"orch-x1","title":"self-dev 調査（for: なし）","description":"pk-ccc に言及するが courier 便ではない","notes":"","labels":["self-dev"],"status":"open","created_at":"2026-07-05T00:00:00Z"}
]
JSON
    out_dup="$(ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$st_tmp/bin/bd" ALL_JSON_FILE="$dup_json" \
               bash "$_orch_hs_self" --no-freshness 2>&1)"; rc_dup=$?
    _dupline="$(printf '%s\n' "$out_dup" | grep -F 'un-aaa')"
    if [ "$rc_dup" -eq 0 ] \
       && grep -qF "【重複便 hold】" <<< "$_dupline" \
       && grep -qF "orch-h1 orch-h2" <<< "$_dupline" \
       && grep -qF "[needs-orch]" <<< "$(printf '%s\n' "$out_dup" | grep -F 'pk-ccc')" \
       && grep -qF "scanned=3 actionable=1 triage-hold=2（grill=1 dup=1）" <<< "$out_dup"; then
        _ok "重複便 hold: 既存 open courier 便 2 本を根拠に un-aaa を hold・根拠便を列挙・pk-ccc は actionable のまま（dup=1）"
    else
        _fail "重複便 hold: un-aaa の hold（根拠 2 本列挙）と dup=1 を期待したが不一致（rc=$rc_dup）: [$out_dup]"
    fi

    # (6b) negative control（self-dev 便は抑制器にしない）: orch-x1 は for:* / courier を持たないので
    #      pk-ccc を hold しない（本 bead 自身のような調査 bead が needs-orch を恒久 burial させる罠の封鎖）。
    if ! grep -qF "orch-x1" <<< "$out_dup"; then
        _ok "negative control: for:*/courier を持たない self-dev 便は根拠にならない（pk-ccc は surface 側）"
    else
        _fail "negative control: orch-x1 が根拠として現れてはならない: [$out_dup]"
    fi

    # (7) 判定不能（fence ■5 の fail 経路）: 自台帳全文走査（--all）が rc≠0 のとき hold を立てず全件を
    #     surface 側に残し、集計に dup=判定不能 を出す（false-hold は不可逆ゆえ surface 側へ倒す）。
    cat > "$st_tmp/bin/bd-allfail" <<'BDEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_ARGS_LOG"
case "$*" in
  *--all*) exit 4 ;;
  *)
    cat <<'JSON'
[
  {"id":"un-aaa","title":"foreign A needs orch","labels":["needs-orch"],"created_at":"2026-07-01T00:00:00Z"},
  {"id":"pk-ccc","title":"foreign C needs orch","labels":["needs-orch"],"created_at":"2026-07-01T00:00:00Z"}
]
JSON
    ;;
esac
BDEOF
    chmod +x "$st_tmp/bin/bd-allfail"
    out_und="$(ORCH_HANDOFF_SKIP_SESSION_GATE=1 ORCH_HANDOFF_BD="$st_tmp/bin/bd-allfail" \
               bash "$_orch_hs_self" --no-freshness 2>&1)"; rc_und=$?
    if [ "$rc_und" -eq 0 ] \
       && grep -qF "【重複便 判定不能】" <<< "$out_und" \
       && grep -qF "dup=判定不能" <<< "$out_und" \
       && grep -qF "scanned=2 actionable=2" <<< "$out_und" \
       && grep -qF "[needs-orch]" <<< "$(printf '%s\n' "$out_und" | grep -F 'un-aaa')"; then
        _ok "判定不能(fence ■5): 全文走査 rc≠0 → hold せず全件 surface・dup=判定不能（黙って落とさない）"
    else
        _fail "判定不能: dup=判定不能 と全件 surface を期待したが不一致（rc=$rc_und）: [$out_und]"
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

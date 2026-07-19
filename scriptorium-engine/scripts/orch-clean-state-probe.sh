#!/usr/bin/env bash
# orch-clean-state-probe.sh — admin/orchestrator の「bundle 境界 clean state」機械検証 probe（read-only・LLM 不使用）
#
# 由来（grill SSOT = orch-c8p grill G4 採択・doobidoo f4888921 / bd orch-i8b・親 orch-c8p E=orch-9dv）───────
#   admin/orchestrator 寿命規律（bundle 境界で計画 respawn 既定・compaction は fallback）を規約化する前提として、
#   「admin は今 clean state か（respawn してよいか）」を **自己申告でなく機械で** 検証する read-only probe。
#   『私はクリーン』という自己申告こそ orch-wzq で捏造された当のもの＝機械 probe が必須（grill G4）。
#
# 検証する 4 核（bundle 境界 = admin clean state の定義・全て read-only）─────────────────────────────
#   (a) in_progress 反映 : in_progress な自台帳(orch-)bead が全て「実状態を反映」している
#                          ＝ live window `wt-<id>` か spawn worktree のどちらかの作業実体を持つ。
#                          ★幽霊判定は「local cell が orch-dispatch で spawn された機械証跡」＝notes に
#                            [ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1] を持つ in_progress に限定する（M3）。
#                            snapshot 無し in_progress（courier 委任 / orchestrator inline）は local cell を
#                            持たない正当な進行中ゆえ (a) の幽霊対象外＝info 行で列挙のみ（新規 label は導入しない）。
#                          snapshot 付き in_progress で実体なきもの（誰も作業していないのに進行中表示）が RED。
#   (b) push 済          : 未 push 差分がない（同期点 `bd dolt push` を踏んだ）。
#                          bd v1.0.4 に read-only な push 先行/遅れ判定は無い（`bd dolt status` は engine
#                          lifecycle しか出さず ahead/behind を報告せず・push 先 remote は network 依存）。
#                          ゆえ判定は env override（ORCH_CLEAN_PUSH_CHECK_CMD）へ委譲可能にし、委譲が無い既定は
#                          fail-closed に倒す（M2）: `.beads/last-touched`（台帳変更記録）が在れば「push 判定不能
#                          =RED＋委譲を促す理由」、無ければ「変更記録なし=GREEN」。旧 last-sync proxy は hydrate
#                          （sync-in）マーカーで push 記録でなく false-clean を生むため既定から排除した。false-clean
#                          だけは絶対に出さない。正確な push 判定が要る運用は ORCH_CLEAN_PUSH_CHECK_CMD で差し込む
#                          （rc 0=同期済 / 非0=未 push・stdout=理由）。
#                          ★既定の RED は push を踏んでも恒久継続する（last-touched は常在＝判定不能のまま・F7）。
#                            恒常 GREEN 化には委譲が必要（例: ORCH_CLEAN_PUSH_CHECK_CMD='<anchor>/scripts/bdw dolt push'
#                            ＝push 成功 rc0 をもって同期済とみなす）。
#   (c) degraded clean   : orch-degraded-watch.sh（既存部品）を合成呼び出しし、salvage/suspect cell が
#                          無い、または全て `gate-pending` ラベル付きで台帳可視（gate 待ちとして admin 認識済）。
#                          未認識の degraded-death 疑い cell が残っていれば RED。
#   (d) 未宣言仕掛かり    : spawn worktree（.worktrees/spawn/*）で base..HEAD 先行 commit>0 を持つのに、
#                          その cell の bead が terminal（closed/blocked or notes STATUS 終端）でも
#                          `gate-pending` でもない ＝ 台帳に宣言なき仕掛かり（取りこぼしリスク）が RED。
#                          ※degraded-watch は「窓消失」cell に特化するが、(d) は窓生存 cell の先行 commit も
#                            対象にする（生きた worker の未 gate 成果物も respawn 前は宣言済であるべき）。
#
# bd read liveness 事前検査（fail-closed の核・finding orch-i8b / grill G4）───────────────────────────
#   4 核を評価する前に bd read（list --json）疎通を検査する。bd が rc≠0/非 JSON（不在・未 hydrate・誤設定・
#   全断）なら台帳を一切読めておらず、(a)/(c)/(d) は『取得 0 件→GREEN』と実状態未確認のまま clean を偽りうる
#   （＝自己申告 clean の捏造＝orch-wzq で捏造された当のもの＝probe の存在理由に反する false-clean）。
#   読めない以上 clean と断じず全体 RED（respawn を止める）。核(a) の空判定を「取得失敗」と取り違えない要。
#   ★jq は hard requirement（F1）: データ抽出 helper 群（_in_progress_ids / _gate_pending_ids /
#     _bead_has_dispatch_snapshot / _status_field / extract_status）は jq 必須。jq 不在で liveness だけ
#     python3/node fallback により GREEN を出すと「全 helper が空読み→幽霊不可視の全体 GREEN」という
#     false-clean を生む（実再現済の退行）。ゆえ jq 不在は fail-closed RED（理由は「jq 不在＝判定不能」と
#     正確に帰属し bd 障害と混同しない）。python3/node は「jq 在るが bd 出力が非 JSON」の検証補助にとどまる。
#
# 判定と exit（respawn ゲート）─────────────────────────────────────────────────────────────────────
#   全核 GREEN → exit 0（clean・respawn 可）。1 つでも RED → exit 1（respawn 不可・片付けよ）。
#   各核は GREEN/RED と理由を stdout に出し、RED は「何を片付けるべきか」を actionable に併記する（acceptance 4）。
#   probe 自体は observe のみ＝bd/foreign 台帳を一切 mutate せず、worktree にも書き戻さない（副作用ゼロ・
#   3 guards / write-isolation 準拠）。bd は read（list/show --json）・git は read（rev-list/branch）・
#   tmux は read（list-panes）だけを叩く。
#
# 使い方（acceptance 2: respawn 規約 E から参照可能な単発コマンド）──────────────────────────────────
#   scripts/orch-clean-state-probe.sh            # 4 核を検査し green/red を出力（exit 0=clean / 1=dirty）
#   scripts/orch-clean-state-probe.sh --dry-run  # 叩く read-only コマンドを列挙（実行しない）
#   scripts/orch-clean-state-probe.sh --self-test # hermetic 自己検証（fail-closed・bats 非依存）
#   scripts/orch-clean-state-probe.sh --help
#
# self-scope gate（他 orch- script と同一機構・誤台帳起動を fail-closed で弾く）──────────────────────
#   cwd から walk-up した最初の .beads/metadata.json の dolt_database が orch でなければ何もせず非 0 で抜ける
#   （ORCH_CLEAN_SKIP_SESSION_GATE=1 で skip＝hermetic self-test / bats 用）。
#
# env override（主に hermetic self-test / bats 用）──────────────────────────────────────────────────
#   ORCH_CLEAN_SCRIPTORIUM        scriptorium repo root（既定: 共有 lib _resolve_scriptorium〔ORCH_ANCHOR /
#                                 ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き〕・解決不能は fail-loud・orch-axg）。
#   ORCH_CLEAN_WORKTREE_ROOT      spawn cell の探索 root（既定: <SCRIPTORIUM>/.worktrees/spawn）。
#   ORCH_CLEAN_GATE_BASE          先行 commit 照合の base ref（既定: main）。
#   ORCH_CLEAN_DONE_STATUS        終端とみなす bead status 集合（CSV・既定: closed,blocked）。
#   ORCH_CLEAN_BD                 bd 実体（既定: PATH 上の bd）。read-only（list/show --json のみ）。
#   ORCH_CLEAN_TMUX              tmux 実体（既定: PATH 上の tmux）。read-only（list-panes のみ）。
#   ORCH_CLEAN_DEGRADED_WATCH    orch-degraded-watch.sh の path（既定: 本 script と同ディレクトリ）。
#   ORCH_CLEAN_BEADS_DIR         (b) が読む .beads dir（既定: <SCRIPTORIUM>/.beads）。last-touched の有無を見る。
#   ORCH_CLEAN_PUSH_CHECK_CMD    (b) の push 判定を委譲する外部コマンド（rc 0=同期済 / 非0=未 push・stdout=理由）。
#                                未設定かつ last-touched 在＝push 判定不能で RED（fail-closed・委譲を促す）。
#   ORCH_CLEAN_JSON_VERIFIERS    bd read liveness の JSON 配列検証器の試行順（既定: "jq python3 node"）。
#                                ★jq 不在は verifiers 設定に関わらず fail-closed RED（F1・データ抽出 helper 群が
#                                jq 必須のため）。python3/node は「jq 在るが出力が非 JSON」検証の補助にとどまる。
#   ORCH_CLEAN_SKIP_SESSION_GATE=1  self-scope gate を skip（hermetic self-test / bats 用）。
#
# 検証: tests/scenarios/orch-clean-state-probe.bats（hermetic: bd/tmux/git/degraded-watch を PATH スタブで差替・
#   4 核の green/red ＋ self-scope ＋ 全 green exit0 / 任意 red exit1 ＋ actionable 出力を網羅）
#   ＋ 本 script `--self-test`（bats 非依存の内蔵 hermetic 検証・fail-closed）。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard / orch-degraded-watch と同一値を共有）。
SELF_PREFIX="orch"

# ── SCRIPTORIUM anchor 動的解決（共有 lib orch_anchor.sh・orch-49g で集約）──────────────────────────
# `_resolve_scriptorium`（E2 anchor 検証付き・degraded-watch / dispatch / fleet-monitor と単一 SSOT）は共有 lib へ
# 集約した（旧 byte 複製 4 を解消・orch-49g）。lib は内部で orch_session.sh を source し `_ledger_dolt_database` で
# 解決候補 anchor の dolt_database==orch を検証する（foreign repo anchor の誤採用を構造封鎖＝E2）。旧 hardcode
# （$HOME/...）は orch identity と非対称で、非 canonical anchor で SCRIPTORIUM/WORKTREE_ROOT が canonical(空) を指し、
# check_c で degraded-watch へ forward すると (c) 核が空 scan→GREEN 誤報（composed bypass）を招いた。env override
# （ORCH_CLEAN_SCRIPTORIUM）を最優先で維持し、解決不能は fail-loud（engine は hardcode fallback を持たない）。
# ★lib は SCRIPTORIUM 代入の**前**に source すること（E2 検証に _ledger_dolt_database が要るため）。BASH_SOURCE 相対
# で実 lib を解決（bats/--self-test 無改変で green）。★非空 env 設定時は下記 ${VAR:-...} の既定が展開されず
# _resolve_scriptorium は呼ばれない＝git を一切叩かない（既存 bats/self-test は SCRIPTORIUM override ゆえ副作用ゼロ）。
# ★symlink-safe（orch-49g errata E1）: readlink -f で script 実体を解決した dir を _ORCH_ANCHOR_LIB / SELF_DIR /
#   orch_session source が共有する（旧 inline _resolve_scriptorium は readlink 耐性を持っていた＝退行を戻す）。
_orch_clean_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_orch_clean_dir="$(cd "$(dirname "$_orch_clean_self")" 2>/dev/null && pwd || echo .)"
_ORCH_ANCHOR_LIB="$_orch_clean_dir/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
    # shellcheck source=lib/orch_anchor.sh
    . "$_ORCH_ANCHOR_LIB"
else
    echo "orch-clean-state-probe: 共有 anchor lib 不在: $_ORCH_ANCHOR_LIB（anchor 解決不能・fail-closed）" >&2
    exit 1
fi
# ★anchor 解決（SCRIPTORIUM とその派生既定 WORKTREE_ROOT / BEADS_DIR）は arg-parse + --self-test dispatch +
#   self-scope gate の**後**へ遅延する（最下部「anchor 解決（遅延・engine 版）」ブロック参照）。fail-loud な
#   anchor 解決が --help / --self-test（hermetic）/ self-scope reject の anchor 非依存経路を巻き添えにしない
#   ため（degraded-watch / stale-scan と同型・sc-vcjv gate finding 反映）。
GATE_BASE="${ORCH_CLEAN_GATE_BASE:-main}"
BD="${ORCH_CLEAN_BD:-bd}"
TMUX_BIN="${ORCH_CLEAN_TMUX:-tmux}"
SELF_DIR="$_orch_clean_dir"   # ★symlink-safe（readlink 解決済み・上で導出・errata E1）
DEGRADED_WATCH="${ORCH_CLEAN_DEGRADED_WATCH:-$SELF_DIR/orch-degraded-watch.sh}"

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・orch-vo2 で 5 script も統一） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。旧 inline _resolve_dolt_database は
# _json_is_valid gate を欠く drift（破損 orch-token metadata で誤 self-scope＝誤台帳起動しうる）だったため
# 撤去し、gate 済みの共有関数へ統一する（orch-vo2 acceptance・orch-degraded-watch と同型）。respawn 可否の
# fail-closed gate ゆえ誤 self-scope の影響が大きく、gate 追加で破損 orch-token metadata は self とみなされず
# refuse 側へ倒れる（安全側）。★実 script 位置（BASH_SOURCE 相対）で解決するので bats/--self-test が実 lib を確実に見つける。
_ORCH_SESSION_LIB="$SELF_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-clean-state-probe: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# 終端とみなす status 集合（CSV → 配列）。既定 closed,blocked＝終端宣言 DONE(closed)/BLOCKED(blocked)。
DONE_SET=()
IFS=',' read -ra DONE_SET <<< "${ORCH_CLEAN_DONE_STATUS:-closed,blocked}"

# ─────────────────────────────────────────────────────────────────────────────
# ported: extract_status / is_terminal / _status_field（orch-degraded-watch.sh・grill-status-watch.sh 由来）
#   read-only な STATUS 抽出＝notes 最終 STATUS 行の terminal 判定に使う。foreign code を live 参照せず自 repo に
#   port（自己完結）。頑健化（bd error-object / 非配列 / notes 非文字列 / 壊れ JSON は no-notes へ潰し jq を
#   非0終了させない）も原典どおり移植する。
# ─────────────────────────────────────────────────────────────────────────────
extract_status() {
    jq -r 'if (type=="array" and (.[0]|type)=="object" and (.[0].notes|type)=="string")
           then (.[0].notes | split("\n") | map(select(startswith("STATUS:"))) | last // "no-status")
           else "no-notes" end' 2>/dev/null || echo "no-notes"
}

is_terminal() {
    local kw="${1#STATUS:}"
    kw="${kw#"${kw%%[![:space:]]*}"}"   # 先頭空白を除去
    case "$kw" in
        done*|blocked*) return 0 ;;
        *) return 1 ;;
    esac
}

_status_field() {
    jq -r 'if (type=="array" and (.[0]|type)=="object") then (.[0].status // "") else "" end' 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# self-scope: cwd の bd 台帳 dolt_database の walk-up 解決（_ledger_dolt_database）は共有 lib
# scripts/hooks/lib/orch_session.sh が提供する（上で source 済み・orch-vo2・orch-degraded-watch と同型）。
# 旧 inline _resolve_dolt_database は _json_is_valid gate を欠く drift だったため撤去し、gate 済みの
# _ledger_dolt_database へ統一した（破損 orch-token metadata での誤 self-scope を fail-closed で弾く）。
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# 共通 read-only ヘルパ
# ─────────────────────────────────────────────────────────────────────────────

# live window 名一覧（tmux list-panes・read-only）。取得不能（tmux 不在/サーバ無）は空。
_live_window_names() {
    "$TMUX_BIN" list-panes -a -F '#{window_name}' 2>/dev/null | sort -u
}

# 文字列が JSON 配列か検証（jq→python3→node の順）。
#   最初に見つかった検証器が判定する。echo: "yes"=配列 / "no"=非配列 / "noverifier"=検証器皆無。
#   試行順は ORCH_CLEAN_JSON_VERIFIERS で上書き可（検証器分岐の hermetic テスト用）。
#   ★F1: jq 不在を GREEN に通す経路は全廃済＝呼び出し元 _bd_read_ok が jq 存在を先に gate する
#     （データ抽出 helper 群が jq 必須のため）。python3/node は「jq 在るが bd 出力が非 JSON」の検証補助。
_json_is_array() {
    local s="$1" v
    for v in ${ORCH_CLEAN_JSON_VERIFIERS:-jq python3 node}; do
        command -v "$v" >/dev/null 2>&1 || continue
        case "$v" in
            jq)
                printf '%s' "$s" | jq -e 'type=="array"' >/dev/null 2>&1 && { echo yes; return 0; }
                echo no; return 0 ;;
            python3)
                printf '%s' "$s" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if isinstance(d,list) else 1)' >/dev/null 2>&1 && { echo yes; return 0; }
                echo no; return 0 ;;
            node)
                printf '%s' "$s" | node -e 'let b="";process.stdin.on("data",d=>b+=d).on("end",()=>{try{process.exit(Array.isArray(JSON.parse(b))?0:1)}catch(e){process.exit(1)}})' >/dev/null 2>&1 && { echo yes; return 0; }
                echo no; return 0 ;;
        esac
    done
    echo noverifier
}

# bd read 疎通の事前検査（read-only・fail-closed の核・finding orch-i8b / grill G4）。
#   返り値: 0=生きている（bd rc0 + JSON 配列確認）/ 1=bd 障害（rc≠0/非 JSON＝不在・未 hydrate・誤設定・全断）
#          / 2=検証器不在（JSON 配列を確認できない・bd 障害と誤帰属しない）/ 3=jq 不在（F1・下記）。
#   ★F1（jq hard requirement）: データ抽出 helper 群（_in_progress_ids/_gate_pending_ids/
#     _bead_has_dispatch_snapshot/_status_field/extract_status）は jq 必須。jq 不在のまま liveness を
#     python3/node fallback で GREEN に通すと、全 helper が空読みになり「幽霊不可視の全体 GREEN」という
#     false-clean を生む（実再現済の退行）。ゆえ jq 不在は検証以前に 3＝fail-closed RED
#     （理由は「jq 不在＝判定不能・bd 障害ではない」と正確に帰属する＝m2 の趣旨は文言で満たす）。
#   これが無いと bd 障害時に (a)/(c)/(d) が『取得 0 件＝GREEN』と実状態未確認のまま clean を偽る
#   （＝自己申告 clean の捏造＝probe の存在理由に反する false-clean）。
#   ※liveness probe には check_a と同じ `list --status=in_progress` を使う（自 DB の最小 read）。
_bd_read_ok() {
    local out rc verdict
    command -v jq >/dev/null 2>&1 || return 3
    out="$("$BD" list --status=in_progress --limit 0 --json 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    verdict="$(_json_is_array "$out")"
    case "$verdict" in
        yes)        return 0 ;;
        noverifier) return 2 ;;
        *)          return 1 ;;
    esac
}

# bead が dispatch snapshot（[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1]・local cell が orch-dispatch で spawn
#   された機械証跡）を notes に持つなら 0。無ければ 1（bd 失敗/not-found は notes 空に潰れ「snapshot 無し」側）。
#   read-only（bd show --long --json のみ）。M3: (a) の幽霊判定を snapshot 付き in_progress に限定する鍵。
_bead_has_dispatch_snapshot() {
    local id="$1" json notes
    json="$("$BD" show "$id" --long --json 2>/dev/null || true)"
    [ -n "$json" ] || return 1
    notes="$(printf '%s' "$json" | jq -r 'if (type=="array" and (.[0]|type)=="object" and (.[0].notes|type)=="string") then .[0].notes else "" end' 2>/dev/null || echo "")"
    printf '%s' "$notes" | grep -qF '[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1]'
}

# 自台帳 orch- の in_progress bead id 一覧（bd list --status --json・read-only）。
#   連結 substrate hydrate で自 DB の bd list は foreign copy も返すため SELF_PREFIX で filter（degraded/liveness と同型）。
_in_progress_ids() {
    "$BD" list --status=in_progress --limit 0 --json 2>/dev/null \
        | jq -r '.[]?.id // empty' 2>/dev/null \
        | grep -E "^${SELF_PREFIX}-" || true
}

# gate-pending ラベル付き（非 closed）bead id セット（bd list --label --json・read-only）。SELF_PREFIX filter。
_gate_pending_ids() {
    "$BD" list --label gate-pending --status open,in_progress,blocked --limit 0 --json 2>/dev/null \
        | jq -r '.[]?.id // empty' 2>/dev/null \
        | grep -E "^${SELF_PREFIX}-" || true
}

# id が改行区切りリストに含まれるか（完全一致）。$1=id / $2=リスト。
_id_in_list() {
    printf '%s\n' "$2" | grep -qxF "$1"
}

# bead が終端宣言済なら 0（terminal）・未終端なら 1。status ∈ done-set OR notes 最終 STATUS が terminal。
#   bd 失敗/not-found（error-object 含む）は status 空・notes no-notes に潰れ「未終端」側（保守的）。
_bead_terminal() {
    local id="$1" json stat st d
    json="$("$BD" show "$id" --long --json 2>/dev/null || true)"
    [ -n "$json" ] || return 1
    stat="$(printf '%s' "$json" | _status_field)"
    for d in "${DONE_SET[@]}"; do
        [ -n "$d" ] && [ "$stat" = "$d" ] && return 0
    done
    st="$(printf '%s' "$json" | extract_status)"
    is_terminal "$st" && return 0
    return 1
}

# worktree の base..HEAD 先行コミット数を echo（数値・解決不能は空）。read-only。
_commit_count() {
    local wt="$1" n
    n="$(git -C "$wt" rev-list --count "$GATE_BASE..HEAD" 2>/dev/null)" || return 0
    printf '%s' "$n"
}

# spawn worktree branch から cell id を復元（orch-dispatch / degraded-watch と同一規約: spawn/<id>-<ts>）。
_cell_id_of() {
    local wt="$1" branch
    branch="$(git -C "$wt" branch --show-current 2>/dev/null)" || return 1
    [ -n "$branch" ] || return 1
    printf '%s' "$branch" | sed -E 's#^spawn/##; s/-[0-9]+$//'
}

# ─────────────────────────────────────────────────────────────────────────────
# 核 (a): in_progress 反映
# ─────────────────────────────────────────────────────────────────────────────
check_a() {
    local ids wins id ghosts=0 n_cell=0 ghost_ids="" noncell_ids=""
    ids="$(_in_progress_ids)"
    wins="$(_live_window_names)"
    if [ -z "$ids" ]; then
        echo "[GREEN] (a) in_progress 反映: 自台帳(${SELF_PREFIX}-)の in_progress bead は 0 件（進行中の取りこぼしなし）"
        return 0
    fi
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        # M3: 幽霊判定対象は「local cell が orch-dispatch で spawn された機械証跡」＝notes に
        #     [ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1] を持つ in_progress のみ。snapshot 無し（courier 委任 /
        #     orchestrator inline）は local cell を持たない正当な進行中ゆえ (a) 対象外で info 列挙のみ。
        if ! _bead_has_dispatch_snapshot "$id"; then
            noncell_ids="${noncell_ids:+$noncell_ids }$id"
            continue
        fi
        n_cell=$((n_cell + 1))
        # 実体判定: live window wt-<id> か spawn worktree（.worktrees/spawn/<id>-*）のどちらかがあれば「反映」。
        if printf '%s\n' "$wins" | grep -qxF "wt-$id"; then
            continue
        fi
        local found_wt=0 d bid
        if [ -d "$WORKTREE_ROOT" ]; then
            for d in "$WORKTREE_ROOT"/*/; do
                [ -d "$d" ] || continue
                bid="$(_cell_id_of "$d")" || continue
                [ "$bid" = "$id" ] && { found_wt=1; break; }
            done
        fi
        [ "$found_wt" -eq 1 ] && continue
        ghosts=$((ghosts + 1))
        ghost_ids="${ghost_ids:+$ghost_ids }$id"
    done <<< "$ids"

    if [ "$ghosts" -ne 0 ]; then
        echo "[RED]   (a) in_progress 反映: snapshot 付き（local cell）in_progress で実体なき幽霊 ${ghosts} 件: ${ghost_ids}"
        echo "        → 片付け: 各 bead を実状態へ整合させよ（作業完了なら close/gate-pending、放棄なら理由付きで再 open/close）。"
        echo "          確認: cd \"$SCRIPTORIUM\" && bd show <id>  /  進行中なら worker cell を再 dispatch。"
        [ -n "$noncell_ids" ] && echo "        info: local cell 非対象の in_progress（snapshot 無し・courier 委任/inline・幽霊判定対象外）: ${noncell_ids}"
        return 1
    fi
    if [ "$n_cell" -eq 0 ]; then
        echo "[GREEN] (a) in_progress 反映: snapshot 付き（local cell）in_progress は 0 件（幽霊判定対象なし）"
    else
        echo "[GREEN] (a) in_progress 反映: snapshot 付き（local cell）in_progress ${n_cell} 件は全て live window/worktree に対応（実状態を反映）"
    fi
    [ -n "$noncell_ids" ] && echo "        info: local cell 非対象の in_progress（snapshot 無し・courier 委任/inline・幽霊判定対象外）: ${noncell_ids}"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 核 (b): push 済（未 push 差分なし）
#   ORCH_CLEAN_PUSH_CHECK_CMD があれば委譲（rc 0=同期済 / 非0=未 push・stdout=理由）。
#   無ければ既定は fail-closed（M2）: bd v1.0.4 に read-only な push 先行判定が無い（`bd dolt status`＝
#   engine lifecycle のみで ahead/behind を出さず・push 先 remote は network 依存）ため best-effort に clean
#   を騙らない。旧 last-sync proxy は hydrate（sync-in）マーカーで push 記録でなく false-clean を生むため
#   既定から排除した。
#     - last-touched 不在 → 台帳変更記録なし → 未 push 差分なし → GREEN。
#     - last-touched 在（委譲なし）→ 変更はあるが read-only に push 済を確認する確実手段が無い → 判定不能=RED
#       （fail-closed・ORCH_CLEAN_PUSH_CHECK_CMD で正確判定を委譲せよ）。false-clean だけは絶対に出さない。
#   ★F7: 既定の RED は push しても解けない（last-touched は常在＝判定不能のまま恒久継続）。恒常 GREEN 化には
#     委譲が必要（例: ORCH_CLEAN_PUSH_CHECK_CMD='<anchor>/scripts/bdw dolt push'＝push 成功 rc0=同期済とみなす）。
# ─────────────────────────────────────────────────────────────────────────────
check_b() {
    if [ -n "${ORCH_CLEAN_PUSH_CHECK_CMD:-}" ]; then
        local out rc
        out="$(eval "$ORCH_CLEAN_PUSH_CHECK_CMD" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ]; then
            echo "[GREEN] (b) push 済: 委譲コマンド green${out:+（$out）}"
            return 0
        fi
        echo "[RED]   (b) push 済: 委譲コマンド red (rc=$rc)${out:+: $out}"
        echo "        → 片付け: cd \"$SCRIPTORIUM\" && \"$SELF_DIR/bdw\" dolt push で同期してから respawn せよ。"
        return 1
    fi

    local touched="$BEADS_DIR/last-touched"
    if [ ! -f "$touched" ]; then
        echo "[GREEN] (b) push 済: 台帳変更記録（last-touched）なし＝未 push 差分なし"
        return 0
    fi
    echo "[RED]   (b) push 済: 台帳変更記録（last-touched）は在るが read-only な push 済判定手段が bd v1.0.4 に無い＝判定不能（fail-closed・false-clean を出さない）"
    echo "        → 片付け: 既定ではこの RED は push しても恒久継続する（last-touched は常在＝判定不能のまま）。"
    echo "          GREEN 化には ORCH_CLEAN_PUSH_CHECK_CMD への委譲が必要"
    echo "          （例: ORCH_CLEAN_PUSH_CHECK_CMD='$SCRIPTORIUM/scripts/bdw dolt push'＝push 成功 rc0 をもって同期済とみなす）。"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 核 (c): degraded clean（or 全て gate-pending 可視）
#   orch-degraded-watch.sh（既存部品）を合成呼び出し。[SALVAGE]/[SUSPECT] 行の cell id を抽出し、
#   全て gate-pending ラベル付き（台帳可視）なら GREEN、1 つでも未 gate なら RED。
# ─────────────────────────────────────────────────────────────────────────────
check_c() {
    if [ ! -x "$DEGRADED_WATCH" ]; then
        echo "[RED]   (c) degraded clean: orch-degraded-watch.sh が実行できない（$DEGRADED_WATCH）＝判定不能（fail-closed）"
        echo "        → 片付け: degraded-watch を復旧するか ORCH_CLEAN_DEGRADED_WATCH で正しい path を指定せよ。"
        return 1
    fi
    local out rc flagged gate_ids id unvisible=0 unvis_ids="" terminal_ids=""
    # degraded-watch も self-scope gate を持つ＝probe は既に gate 済ゆえ skip し env を forward（read-only 合成）。
    # m1: ORCH_CLEAN_DONE_STATUS を ORCH_DEGRADED_DONE_STATUS として forward（terminal 判定の done-set を一致させる）。
    # orch-axg: SCRIPTORIUM/WORKTREE_ROOT は _resolve_scriptorium で動的解決した anchor（非 canonical でも正しい）を
    #   ORCH_DEGRADED_SCRIPTORIUM/_WORKTREE_ROOT として forward する＝degraded-watch は forward された動的解決結果を
    #   env 最優先で使い、canonical(空) を scan する composed bypass（false GREEN）を起こさない。
    out="$(ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
           ORCH_DEGRADED_SCRIPTORIUM="$SCRIPTORIUM" \
           ORCH_DEGRADED_WORKTREE_ROOT="$WORKTREE_ROOT" \
           ORCH_DEGRADED_GATE_BASE="$GATE_BASE" \
           ORCH_DEGRADED_BD="$BD" \
           ORCH_DEGRADED_TMUX="$TMUX_BIN" \
           ORCH_DEGRADED_DONE_STATUS="${ORCH_CLEAN_DONE_STATUS:-closed,blocked}" \
           "$DEGRADED_WATCH" 2>/dev/null)"; rc=$?
    # M4: degraded-watch は (a)(d) が拾えない窓消失 degraded の単独検出点ゆえ、実行できても rc≠0（クラッシュ・
    #     空 stdout）を silent GREEN にすると致命。missing-executable と同じ RED（fail-closed）に倒す。
    if [ "$rc" -ne 0 ]; then
        echo "[RED]   (c) degraded clean: orch-degraded-watch.sh が rc=$rc で異常終了＝degraded 判定不能（fail-closed）"
        echo "        → 片付け: cd \"$SCRIPTORIUM\" && \"$SELF_DIR/orch-degraded-watch.sh\" を直接叩き失敗原因を除いてから respawn せよ。"
        return 1
    fi
    flagged="$(printf '%s\n' "$out" | awk '/\[SALVAGE\]|\[SUSPECT\]/{print $2}' | sort -u)"
    if [ -z "$flagged" ]; then
        echo "[GREEN] (c) degraded clean: degraded-watch に salvage/suspect cell なし（窓消失 degraded なし）"
        return 0
    fi
    gate_ids="$(_gate_pending_ids)"
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        # M1: check_d と同じ terminal escape。flagged でも bead が terminal（closed/blocked）なら「未認識
        #     degraded」と数えない（post-merge/cleanup 待ちの closed cell を誤 RED しない）。
        if _bead_terminal "$id"; then
            terminal_ids="${terminal_ids:+$terminal_ids }$id"
            continue
        fi
        if ! _id_in_list "$id" "$gate_ids"; then
            unvisible=$((unvisible + 1))
            unvis_ids="${unvis_ids:+$unvis_ids }$id"
        fi
    done <<< "$flagged"

    if [ "$unvisible" -ne 0 ]; then
        echo "[RED]   (c) degraded clean: 未認識の degraded 疑い cell ${unvisible} 件（terminal でも gate-pending でもない）: ${unvis_ids}"
        echo "        → 片付け: cd \"$SCRIPTORIUM\" && \"$SELF_DIR/orch-degraded-watch.sh\" で詳細確認し、"
        echo "          各 cell を salvage（成果物回収）or gate-pending 宣言して台帳可視にせよ。"
        return 1
    fi
    echo "[GREEN] (c) degraded clean: degraded-watch 検出 cell は全て terminal 宣言済 or gate-pending として台帳可視（未認識 degraded なし）"
    # M1: terminal（closed/blocked）だが worktree 残存＝無言 GREEN にせず cleanup を促す（respawn は妨げない）。
    [ -n "$terminal_ids" ] && echo "        → 片付け: terminal(closed/blocked)宣言済だが worktree 残存 cell: ${terminal_ids} — worktree cleanup せよ（respawn は妨げない）。"
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 核 (d): 未宣言仕掛かり（worktree 先行 commit>0 かつ terminal でも gate-pending でもない）
#   窓生存/消失を問わず全 spawn worktree を walk（degraded-watch の窓消失特化とは別軸の defense-in-depth）。
# ─────────────────────────────────────────────────────────────────────────────
check_d() {
    if [ ! -d "$WORKTREE_ROOT" ]; then
        echo "[GREEN] (d) 未宣言仕掛かり: spawn worktree root なし（$WORKTREE_ROOT）＝仕掛かり cell なし"
        return 0
    fi
    local gate_ids d id cnt undeclared=0 undecl_desc=""
    gate_ids="$(_gate_pending_ids)"
    for d in "$WORKTREE_ROOT"/*/; do
        [ -d "$d" ] || continue
        id="$(_cell_id_of "$d")" || continue
        [ -n "$id" ] || continue
        cnt="$(_commit_count "$d")"
        # m6: git rev-list 解決不能（cnt 空）を skip（fail-open）すると「取りこぼさない」fail-closed 契約と
        #     矛盾する。判定材料を得られない以上「判定不能=RED」に倒す（cell id を明示）。
        if [ -z "$cnt" ]; then
            undeclared=$((undeclared + 1))
            undecl_desc="${undecl_desc:+$undecl_desc; }${id}(commit=rev-list解決不能)"
            continue
        fi
        # 先行 commit 0 は「仕掛かり成果物なし」＝対象外。
        [ "$cnt" -gt 0 ] 2>/dev/null || continue
        # terminal 宣言済 or gate-pending 可視なら「宣言済の仕掛かり」＝clean（対象外）。
        if _bead_terminal "$id"; then continue; fi
        if _id_in_list "$id" "$gate_ids"; then continue; fi
        undeclared=$((undeclared + 1))
        undecl_desc="${undecl_desc:+$undecl_desc; }${id}(commit=${cnt})"
    done

    if [ "$undeclared" -eq 0 ]; then
        echo "[GREEN] (d) 未宣言仕掛かり: 先行 commit を持つ worktree は全て terminal/gate-pending 宣言済（取りこぼしなし）"
        return 0
    fi
    echo "[RED]   (d) 未宣言仕掛かり: 宣言なき先行 commit を持つ cell ${undeclared} 件: ${undecl_desc}"
    echo "        → 片付け: 各 cell の成果物を gate（gate-pending 宣言）or salvage/破棄せよ。"
    echo "          確認: git -C \"$WORKTREE_ROOT/<id>-<ts>\" log ${GATE_BASE}..HEAD --oneline"
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
run_probe() {
    echo "orch-clean-state-probe: admin clean-state 機械検証（read-only・副作用ゼロ・grill orch-c8p G4）"
    echo "  anchor=$SCRIPTORIUM base=$GATE_BASE worktree_root=$WORKTREE_ROOT"
    echo
    # ★bd read liveness 事前検査（fail-closed の核・finding orch-i8b / grill G4）: bd を読めないと
    #   (a)/(c)/(d) が『取得 0 件→GREEN』と実状態未確認のまま clean を偽る（自己申告 clean の捏造＝
    #   probe が防ぐ当のもの）。判定材料（台帳）を読めない以上、clean と断じず RED（respawn を止める）。
    local live_rc
    _bd_read_ok; live_rc=$?
    if [ "$live_rc" -ne 0 ]; then
        if [ "$live_rc" -eq 3 ]; then
            # F1: jq 不在＝データ抽出 helper 群が全滅（空読み→幽霊不可視の false-clean）ゆえ fail-closed。
            #     理由は「jq 不在」と正確に帰属し bd 障害と混同しない（m2 の誤帰属修正は文言で満たす）。
            echo "[RED]   (0) bd 疎通: jq が PATH に無い＝台帳 JSON を解析できず clean 判定不能（fail-closed・bd 障害ではない）"
            echo "        → 片付け: jq を導入してから respawn せよ（データ抽出 helper 群は jq 必須・python3/node では代替不能）。"
        elif [ "$live_rc" -eq 2 ]; then
            # m2: JSON 配列検証器が確認できない＝bd 障害と誤帰属せず「検証器不在で判定不能」を明示。
            echo "[RED]   (0) bd 疎通: JSON 配列検証器が無く bd read の妥当性を確認できない＝判定不能（fail-closed・bd 障害とは限らない）"
            echo "        → 片付け: ORCH_CLEAN_JSON_VERIFIERS の指定を見直してから respawn せよ。"
        else
            echo "[RED]   (0) bd 疎通: bd read（$BD list --json）が rc≠0/非 JSON＝自台帳を読めない＝clean 判定不能（fail-closed）"
            echo "        → 片付け: cd \"$SCRIPTORIUM\" && $BD list --status=in_progress --json で bd を復旧し、"
            echo "          台帳が読める状態にしてから respawn せよ（読めないまま『clean』と偽らない）。"
        fi
        echo
        echo "── 判定: RED（respawn 不可・bd 判定不能で clean を検証できず）  green=0 red=1"
        return 1
    fi
    local reds=0 greens=0
    for chk in check_a check_b check_c check_d; do
        if "$chk"; then greens=$((greens + 1)); else reds=$((reds + 1)); fi
    done
    echo
    if [ "$reds" -eq 0 ]; then
        echo "── 判定: GREEN（clean・respawn 可）  green=$greens red=0"
        return 0
    fi
    echo "── 判定: RED（respawn 不可・上記 [RED] を片付けよ）  green=$greens red=$reds"
    return 1
}

run_dry_run() {
    echo "[plan] orch-clean-state-probe 単発 read-only sweep（mutate しない・起票/dispatch/label もしない）:"
    echo "[plan]   (a) $BD list --status=in_progress --json（${SELF_PREFIX}- filter）× $BD show <id>（dispatch snapshot 有無・M3）× tmux list-panes（wt-<id> 突合）× worktree 走査"
    if [ -n "${ORCH_CLEAN_PUSH_CHECK_CMD:-}" ]; then
        echo "[plan]   (b) 委譲: $ORCH_CLEAN_PUSH_CHECK_CMD（rc 0=同期済 / 非0=未 push）"
    else
        echo "[plan]   (b) 既定 fail-closed: $BEADS_DIR/last-touched の有無（在れば push 判定不能=RED・委譲を促す / 無ければ変更記録なし=GREEN。read-only な確実 push 信号が bd v1.0.4 に無い・M2）"
    fi
    echo "[plan]   (c) $DEGRADED_WATCH（合成・read-only・rc 捕捉）× $BD list --label gate-pending --json で可視性突合"
    echo "[plan]   (d) $WORKTREE_ROOT/* を走査し git rev-list --count $GATE_BASE..HEAD × bead terminal/gate-pending 突合"
    return 0
}

usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# --self-test: bats 非依存の内蔵 hermetic 検証（fail-closed＝assert 1 つでも落ちたら非0）
#   一時 fixture（.beads/metadata.json dolt_database=orch・スタブ bd/tmux/degraded-watch）を組み、
#   all-green（exit0）/ (a)(b)(c)(d) 各 red（exit1）/ self-scope reject / bd read 不通→RED（fail-closed）
#   を検証する。
# ─────────────────────────────────────────────────────────────────────────────
run_self_test() {
    local tmp rc fails=0
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/orch-clean-selftest.XXXXXX")" || { echo "self-test: mktemp 失敗" >&2; return 1; }
    trap 'rm -rf "$tmp"' RETURN

    # ★absolute 解決必須: シナリオ6 は cd "$foreign" 後に bash "$self" を叩くため、相対パスだと
    #   cd 後に解決できず bash が rc=127（not-found）を返し self-scope gate を一度も実行しない（vacuous）。
    #   SELF_DIR（L73 で既に絶対解決済）を再利用して cwd 非依存の絶対パスにする。
    local self="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
    local bindir="$tmp/bin"; mkdir -p "$bindir"
    local anchor="$tmp/anchor"; mkdir -p "$anchor/.beads" "$anchor/.worktrees/spawn"
    printf '{"dolt_database":"orch"}\n' > "$anchor/.beads/metadata.json"

    # ── スタブ生成ヘルパ ─────────────────────────────────────────────
    # bd スタブ: 環境変数 STUB_IP_IDS / STUB_GATE_IDS / STUB_TERMINAL_IDS で挙動を制御。
    cat > "$bindir/bd" <<'STUB'
#!/usr/bin/env bash
# read-only bd スタブ（list/show --json のみ）。
args="$*"
# STUB_BD_FAIL: bd 全断（read 疎通失敗）をシミュレート＝全呼び出しを rc 1 で落とす。
[ -n "${STUB_BD_FAIL:-}" ] && exit 1
emit_ids() { # $1=CSV → JSON array of {id}
  local csv="$1" first=1; printf '['
  IFS=',' read -ra a <<< "$csv"
  for x in "${a[@]}"; do [ -n "$x" ] || continue; [ $first -eq 1 ] || printf ','; printf '{"id":"%s"}' "$x"; first=0; done
  printf ']'
}
case "$args" in
  *"list"*"--status=in_progress"*) emit_ids "${STUB_IP_IDS:-}"; exit 0 ;;
  *"list"*"--label gate-pending"*) emit_ids "${STUB_GATE_IDS:-}"; exit 0 ;;
  *"show"*"--json"*)
    # show <id> ...: 引数から id を拾い、STUB_TERMINAL_IDS に含まれれば status=closed。
    #   STUB_SNAPSHOT_IDS に含まれれば notes に dispatch snapshot marker を載せる（M3・check_a の証跡判定）。
    id=""; for a in "$@"; do case "$a" in show) : ;; --*) : ;; *) [ -z "$id" ] && id="$a" ;; esac; done
    st="open"
    case ",${STUB_TERMINAL_IDS:-}," in *",$id,"*) st="closed" ;; esac
    notes=""
    case ",${STUB_SNAPSHOT_IDS:-}," in *",$id,"*) notes="[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1] bd=$id" ;; esac
    printf '[{"id":"%s","status":"%s","notes":"%s"}]' "$id" "$st" "$notes"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
    chmod +x "$bindir/bd"

    # tmux スタブ: STUB_WINDOWS（改行区切り）を list-panes として返す。
    cat > "$bindir/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "${STUB_WINDOWS:-}"
exit 0
STUB
    chmod +x "$bindir/tmux"

    # degraded-watch スタブ: STUB_DEGRADED_FLAGGED（CSV）を [SALVAGE] 行として emit。
    #   STUB_DW_RC で終了コードを制御（M4: 実行可能だが rc≠0＝クラッシュ を再現）。
    cat > "$bindir/degraded-watch" <<'STUB'
#!/usr/bin/env bash
IFS=',' read -ra a <<< "${STUB_DEGRADED_FLAGGED:-}"
for x in "${a[@]}"; do [ -n "$x" ] && printf '  [SALVAGE] %s 窓消失 branch=spawn/%s-1 quiet=x\n' "$x" "$x"; done
exit "${STUB_DW_RC:-0}"
STUB
    chmod +x "$bindir/degraded-watch"

    # fake spawn worktree（先行 commit>0 の git repo）を作るヘルパ。
    _mk_wt() { # $1=id
        local wt="$anchor/.worktrees/spawn/$1-1"
        mkdir -p "$wt"
        ( cd "$wt" && git init -q -b main . && git config user.email t@t && git config user.name t \
          && git commit -q --allow-empty -m base && git checkout -q -b "spawn/$1-1" \
          && git commit -q --allow-empty -m work ) >/dev/null 2>&1
    }

    _run() { # 共通 env で probe を実行し rc を返す。追加 env は呼び出し側で export。
        PATH="$bindir:$PATH" \
        ORCH_CLEAN_SKIP_SESSION_GATE=1 \
        ORCH_CLEAN_SCRIPTORIUM="$anchor" \
        ORCH_CLEAN_BD="$bindir/bd" \
        ORCH_CLEAN_TMUX="$bindir/tmux" \
        ORCH_CLEAN_DEGRADED_WATCH="$bindir/degraded-watch" \
        ORCH_CLEAN_BEADS_DIR="$anchor/.beads" \
        bash "$self" >/dev/null 2>&1
    }
    _assert() { # $1=期待rc $2=実rc $3=名前
        if [ "$1" -eq "$2" ]; then echo "  ok: $3 (rc=$2)"; else echo "  FAIL: $3 期待rc=$1 実rc=$2" >&2; fails=$((fails+1)); fi
    }

    # push proxy を GREEN 側に固定（last-touched なし＝変更記録なし）するため BEADS_DIR は空。
    # シナリオ1: all-green（in_progress なし・gate なし・degraded なし・worktree なし）。
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" _run ); _assert 0 $? "all-green→exit0"

    # シナリオ2: (a) red（snapshot 付き in_progress orch-x に window/worktree なし＝幽霊）。
    ( STUB_IP_IDS="orch-ghost" STUB_SNAPSHOT_IDS="orch-ghost" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" _run ); _assert 1 $? "(a)snapshot付き幽霊 in_progress→exit1"

    # シナリオ2b: (a) green（snapshot 付き in_progress だが live window あり＝実体反映）。
    ( STUB_IP_IDS="orch-live" STUB_SNAPSHOT_IDS="orch-live" STUB_WINDOWS="wt-orch-live" STUB_DEGRADED_FLAGGED="" _run ); _assert 0 $? "(a)window対応 in_progress→exit0"

    # シナリオ2c: (a) green（M3: snapshot 無し in_progress＝courier/inline は幽霊対象外＝info 列挙のみ）。
    ( STUB_IP_IDS="orch-inline" STUB_SNAPSHOT_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" _run ); _assert 0 $? "(a)snapshot無し in_progress→exit0(info)"

    # シナリオ3: (c) red（degraded flagged だが gate-pending 未付与）。
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="orch-dead" STUB_GATE_IDS="" _run ); _assert 1 $? "(c)未認識degraded→exit1"

    # シナリオ3b: (c) green（degraded flagged だが gate-pending 可視）。
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="orch-dead" STUB_GATE_IDS="orch-dead" _run ); _assert 0 $? "(c)gate可視degraded→exit0"

    # シナリオ3c: (c) green（M1: degraded flagged だが terminal 宣言済＝未認識 degraded と数えず GREEN + cleanup 案内）。
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="orch-dead" STUB_TERMINAL_IDS="orch-dead" STUB_GATE_IDS="" _run ); _assert 0 $? "(c)terminal flagged degraded→exit0"

    # シナリオ3d: (c) red（M4: degraded-watch は実行可能だが rc≠0 で異常終了＝空 stdout の silent GREEN を許さない）。
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" STUB_DW_RC=1 _run ); _assert 1 $? "(c)degraded-watch rc≠0→exit1(fail-closed)"

    # シナリオ4: (d) red（worktree 先行 commit>0 だが terminal でも gate でもない）。
    _mk_wt "orch-wip"
    ( STUB_IP_IDS="" STUB_WINDOWS="wt-orch-wip" STUB_DEGRADED_FLAGGED="" STUB_GATE_IDS="" STUB_TERMINAL_IDS="" _run ); _assert 1 $? "(d)未宣言先行commit→exit1"

    # シナリオ4b: (d) green（同 worktree だが terminal 宣言済）。
    ( STUB_IP_IDS="" STUB_WINDOWS="wt-orch-wip" STUB_DEGRADED_FLAGGED="" STUB_GATE_IDS="" STUB_TERMINAL_IDS="orch-wip" _run ); _assert 0 $? "(d)terminal宣言済先行commit→exit0"

    # シナリオ4c: (d) green（同 worktree だが gate-pending 可視）。
    ( STUB_IP_IDS="" STUB_WINDOWS="wt-orch-wip" STUB_DEGRADED_FLAGGED="" STUB_GATE_IDS="orch-wip" STUB_TERMINAL_IDS="" _run ); _assert 0 $? "(d)gate可視先行commit→exit0"

    # シナリオ4 の worktree を撤去（以降のシナリオで (d) が red に混ざる vacuity を防ぎ (b) を単独で見る）。
    rm -rf "$anchor/.worktrees/spawn/orch-wip-1"

    # シナリオ5: (b) red（M2: last-touched 在＋委譲未設定＝push 判定不能・fail-closed。last-sync 非依存）。
    printf 'orch-x\n' > "$anchor/.beads/last-touched"
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" _run ); _assert 1 $? "(b)last-touched在+委譲なし→exit1(判定不能)"

    # シナリオ5b: (b) green（同構成でも ORCH_CLEAN_PUSH_CHECK_CMD 委譲 rc0＝同期済）。
    ( STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" ORCH_CLEAN_PUSH_CHECK_CMD="exit 0" _run ); _assert 0 $? "(b)委譲rc0→exit0"
    rm -f "$anchor/.beads/last-touched"

    # シナリオ6: self-scope reject（skip gate せず・cwd 台帳が orch でない）。
    local foreign="$tmp/foreign"; mkdir -p "$foreign/.beads"
    printf '{"dolt_database":"un"}\n' > "$foreign/.beads/metadata.json"
    ( cd "$foreign" && PATH="$bindir:$PATH" ORCH_CLEAN_SCRIPTORIUM="$anchor" ORCH_CLEAN_BD="$bindir/bd" \
        ORCH_CLEAN_TMUX="$bindir/tmux" ORCH_CLEAN_DEGRADED_WATCH="$bindir/degraded-watch" \
        ORCH_CLEAN_BEADS_DIR="$anchor/.beads" bash "$self" >/dev/null 2>&1 )
    _assert 1 $? "self-scope reject(foreign cwd)→exit1"

    # シナリオ7: bd read 不通（bd 全断）→ 判定材料欠落で全体 RED（fail-closed・finding orch-i8b / grill G4）。
    #   ★非 vacuous: この env（全 benign）は liveness gate が無ければ (a)(b)(c)(d) 全 GREEN で exit0＝
    #     『空 fleet + bd 全断で台帳未読のまま respawn 可』の false-clean。gate 導入で exit1 に倒れる。
    ( STUB_BD_FAIL=1 STUB_IP_IDS="" STUB_WINDOWS="" STUB_DEGRADED_FLAGGED="" _run ); _assert 1 $? "bd read 不通→exit1(fail-closed)"

    # non-vacuity: fixture が本当に区別しているか（all-green が exit0 を出せることは上で確認済）。
    if [ "$fails" -eq 0 ]; then
        echo "orch-clean-state-probe --self-test: PASS（全シナリオ green）"
        return 0
    fi
    echo "orch-clean-state-probe --self-test: FAIL（$fails 件）" >&2
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
MODE="probe"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   MODE="dry"; shift ;;
        --self-test) MODE="selftest"; shift ;;
        -h|--help)   usage 0 ;;
        --*)         echo "orch-clean-state-probe: 不明なオプション: $1（--dry-run / --self-test / --help）" >&2; usage 1 ;;
        *)           echo "orch-clean-state-probe: 位置引数は取りません: $1" >&2; usage 1 ;;
    esac
done

# self-test は self-scope gate の対象外（hermetic fixture 内で完結）。
if [ "$MODE" = "selftest" ]; then
    run_self_test; exit $?
fi

# self-scope gate（誤台帳起動を fail-closed で弾く・guard / orch-degraded-watch と一貫）。
if [ "${ORCH_CLEAN_SKIP_SESSION_GATE:-}" != "1" ]; then
    DB="$(_ledger_dolt_database "$PWD")"
    if [ "$DB" != "$SELF_PREFIX" ]; then
        echo "orch-clean-state-probe: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
        echo "  orchestrator session（cwd=orchestrator）から実行せよ。self-scope の fail-closed。" >&2
        exit 1
    fi
fi

# ── anchor 解決（遅延・engine 版）: env override > 共有 lib _resolve_scriptorium（ORCH_ANCHOR /
# ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き）。解決不能は fail-loud（deploy-layout 依存の hardcode fallback は
# engine では持たない）。arg-parse・--self-test dispatch・self-scope gate の**後**に置き、anchor 非依存経路
# （--help / hermetic --self-test / self-scope reject）を巻き添えにしない（degraded-watch / stale-scan と同型）。
SCRIPTORIUM="${ORCH_CLEAN_SCRIPTORIUM:-$(_resolve_scriptorium || true)}"
if [ -z "$SCRIPTORIUM" ]; then
    echo "orch-clean-state-probe: anchor 解決不能（fail-loud）: env ORCH_CLEAN_SCRIPTORIUM / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ（engine は hardcode fallback を持たない）。" >&2
    exit 1
fi
WORKTREE_ROOT="${ORCH_CLEAN_WORKTREE_ROOT:-$SCRIPTORIUM/.worktrees/spawn}"
BEADS_DIR="${ORCH_CLEAN_BEADS_DIR:-$SCRIPTORIUM/.beads}"

case "$MODE" in
    dry)   run_dry_run ;;
    probe) run_probe ;;
esac

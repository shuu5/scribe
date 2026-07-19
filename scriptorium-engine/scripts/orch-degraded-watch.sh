#!/usr/bin/env bash
# orch-degraded-watch.sh — spawn worker cell（.worktrees/spawn）の独立 machine 判定 watcher（read-only・LLM 不使用）
#   consult-window 中断検知（consult-<grill-issue> 窓消失 × grill-issue bead 未終端 = A∧B・非 commit 経路）は
#   本 3核 watcher の射程外＝orch-nzd で follow-up（consult は worktree/commit を持たず commit 核 C が無い）。
#
# 役割（grill SSOT = scribe sc-3pq / bd orch-nzd / orch-r22・grill 2026-06-24 4 論点確定）─────────────
#   fleet-monitor.sh は「人間向けボード」のまま維持し（grill L1）、degraded の**機械判定は本 watcher が
#   独立ツールとして担う**（fleet-monitor に機械判定を詰め込まない）。folio incident 0264028f 同型の
#   「窓が消えた cell の停止見落とし」を、bd CLOSED に依存せず**構造シグナル**で検出する。
#
# 判定核 = 構造3核（grill L2・時間 cap は主判定にしない）──────────────────────────────────────────
#   spawn cell（.worktrees/spawn/<id>-<ts> = worktree 隔離 cell の durable artifact・window 消失でも残る）
#   ごとに、以下 3 つの「delivery なしで死んだ兆候」を評価する:
#     A. 窓消失   : その cell の tmux window（wt-<id>）が live pane に無い（＝対話 session が消えた）。
#                   ※窓が有る cell は「生きている」とみなし degraded-death の候補にしない。★これは grill L2
#                     由来の「WF 実行中の見かけ idle を誤検出しない」目的を果たす **代替設計判断（substitute）**:
#                     grill L2 の false-idle 除外機構は「進捗ボックス N/M agents done + spinner 併読」だが machine
#                     watcher は UI を読めない→その substitute として「窓存在=alive proxy」を採る（目的は grill L2・
#                     機構は substitute）。★既知限界（scope 外）: 窓は生きているが内部が死んだ cell（cld crash 後に
#                     launcher が dead shell を保持）は本 anchor では検出しない＝scribe env-probe / 人間 triage へ
#                     委譲する構造上の blind-spot（意図的 scope 境界・fixture でも pin）。
#     B. CLOSED不在: その cell の bead が終端宣言していない（status が done-set〔既定 closed,blocked〕でなく、
#                   かつ notes 最終 STATUS 行も terminal〔done/blocked〕でない）。orch-mot の終端宣言
#                   （DONE/BLOCKED/NEEDS-USER）が届いていない＝degraded worker から構造的に届かない側。
#     C. commit=0 : その cell の worktree branch が base（既定 main）より先行コミット 0（何も produce せず死んだ）。
#                   ※caveat: main..HEAD=0 は「未 produce」だけでなく ff/merge-commit で local main に取込済の
#                     merged cell も 0 に見える（squash/rebase 取込は >0）。cleanup 未実施の terminal cell が
#                     過渡的に A×C SUSPECT を出す＝黄旗の **意図的 over-flag 範囲**（誤 salvage ではない・B が
#                     terminal なので salvage は阻止される）。
#                   ※fail-open 方向: git rev-list 解決不能時は nocommit=0（＝非 degraded 側・核 A/B とは逆方向）へ
#                     倒す＝git 一過性障害での誤 SALVAGE を回避する（過剰 salvage より取りこぼし側が安全）。
#   ★時間 idle（quiet since）は**補助注釈のみ**で 3核の AND/OR には一切入れない（grill L2 一丁目一番地：
#     時間 cap で stalled cell を黙って良性化した folio 教訓を判定核に持ち込まない）。env/STATUS notes は
#     補助（届けば強証拠）＝B の terminal 判定に extract_status（grill-status-watch.sh から port）を織り込む。
#
# suspect → salvage の 2 層（grill L4 二層分離 carrier・grill L2 緩OR / 強AND）──────────────────────────
#   窓消失（A）を候補 anchor とし、残る劣化核（B/C）の充足度で 2 段に分ける:
#     - suspect（黄旗・緩）: A かつ（B または C）＝劣化核が 1 つでも立てば「見にこさせる」。
#         例) A×B（窓消失・未終端だが commit 有り）=「delivery したが gate/close 忘れ」＝要確認。
#             A×C（窓消失・終端宣言済だが commit 0）=「done と言ったが何も produce せず」＝要確認。
#     - salvage（強・誤殺防止）: A かつ B かつ C＝構造3核が全て立つ＝**degraded-death 濃厚**（要 salvage 介入）。
#   誤殺防止（強AND）で正常 cell を殺さない一方、suspect（緩OR）で silent な取りこぼしを黄旗化する。
#
# read-only 徹底（監視は observe のみ）─────────────────────────────────────────────────────────────
#   bd は `show --long --json`（read）・git は `rev-list/branch/log`（read）・tmux は `list-panes`（read）だけ。
#   bd/foreign 台帳を一切 mutate しない・worktree に書き戻さない（3 guards 準拠・write-isolation を侵さない）。
#   本 watcher は「独立ツール」ゆえ既定は 1 回スキャンして所見を stdout に出し exit 0（Monitor/`/loop` で
#   包めば periodic 監視になる＝orch-dispatch gate-pending / fleet-monitor --once と同じ composable 設計）。
#
# self-scope gate（他 orch- script と同一機構）──────────────────────────────────────────────────────
#   cwd から walk-up した最初の .beads/metadata.json の dolt_database が orch でなければ何もせず非 0 で抜ける
#   （誤台帳起動を fail-closed で弾く・ORCH_DEGRADED_SKIP_SESSION_GATE=1 で skip＝hermetic self-test 用）。
#
# モード ────────────────────────────────────────────────────────────────────────────────────────────
#   （既定）scan   : spawn cell 群を走査し suspect/salvage を stdout へ（read-only・observe）。
#   --extract      : stdin の `bd show --long --json` から最終 STATUS 行を抽出（grill-status-watch.sh port・test/compose）。
#   --classify <s> : STATUS 文字列が終端（done/blocked 前方一致）かを terminal/ongoing で表示（port・test/compose）。
#   --help
#
# env override（主に hermetic self-test 用）────────────────────────────────────────────────────────
#   ORCH_DEGRADED_SCRIPTORIUM     scriptorium repo root（既定: 共有 lib _resolve_scriptorium〔ORCH_ANCHOR /
#                                 ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き〕・解決不能は fail-loud・orch-pso）。
#   ORCH_DEGRADED_WORKTREE_ROOT   spawn cell の探索 root（既定: <SCRIPTORIUM>/.worktrees/spawn）。
#   ORCH_DEGRADED_GATE_BASE       commit 照合の base ref（既定: main）。
#   ORCH_DEGRADED_DONE_STATUS     終端とみなす bead status 集合（CSV・既定: closed,blocked）。
#   ORCH_DEGRADED_BD              bd 実体（既定: PATH 上の bd）。read-only（show --long --json のみ）。
#   ORCH_DEGRADED_TMUX            tmux 実体（既定: PATH 上の tmux）。read-only（list-panes のみ）。
#   ORCH_DEGRADED_SKIP_SESSION_GATE=1  self-scope gate を skip（hermetic self-test 用）。
#
# 検証: tests/scenarios/fleet-degraded-watch.bats（hermetic: bd/tmux/git を PATH スタブで差替・3核 suspect/salvage
#   ＋ extract_status port ＋ self-scope ＋ fail-open を網羅）。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard / orch-dispatch と同一値を共有）。
SELF_PREFIX="orch"

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・SSOT = scripts/hooks/lib/orch_session.sh） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。旧 _resolve_dolt_database は
# _json_is_valid gate を欠く drift（破損 orch-token metadata で誤 self-scope＝誤台帳起動しうる）だったが、
# gate 済みの共有関数を consume して drift を解消する（orch-t9z acceptance 3）。self-scope gate は fail-closed
# 方針ゆえ、gate 追加で破損 orch-token metadata は self とみなされず refuse 側へ倒れる（安全側）。
# ★実 script 位置（BASH_SOURCE 相対）で解決するので bats（実 SCRIPT path 起動）で実 lib を確実に見つける。
#   自 script は scripts/ 直下ゆえ lib は hooks/lib/ 配下。lib 不在は self-scope 判定不能ゆえ fail-closed で die。
# ★symlink-safe（orch-49g errata E1）: readlink -f で script 実体を解決してから lib dir を導く（symlink 起動でも
#   実 repo の orch_session.sh / orch_anchor.sh を source できる・fleet-monitor / dispatch と同型）。
_orch_dw_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_SCRIPT_DIR="$(cd "$(dirname "$_orch_dw_self")" 2>/dev/null && pwd)"
_ORCH_SESSION_LIB="$_SCRIPT_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-degraded-watch: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# ── SCRIPTORIUM anchor 動的解決 + external repo cell scan roots（共有 lib orch_anchor.sh・orch-49g で集約）──
# `_resolve_scriptorium`（E2 anchor 検証付き・fleet-monitor / clean-probe / dispatch と単一 SSOT）と
# `_external_scan_roots`（dispatch と単一 SSOT）は共有 lib へ集約した（旧 byte 複製 4+2 を解消・orch-49g）。lib は
# 内部で orch_session.sh を source し `_ledger_dolt_database` で解決候補 anchor の dolt_database==orch を検証する
# （foreign repo anchor の誤採用を構造封鎖＝E2）。env override（ORCH_DEGRADED_SCRIPTORIUM）を最優先で維持し、
# 解決不能は fail-loud する（engine は deploy-layout 依存の hardcode fallback を持たない）。★lib は
# SCRIPTORIUM 代入の**前**に source すること（E2 検証に _ledger_dolt_database が要るため）。BASH_SOURCE 相対で
# 実 lib を解決（bats/--self-test 無改変で green）。
_ORCH_ANCHOR_LIB="$_SCRIPT_DIR/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
    # shellcheck source=lib/orch_anchor.sh
    . "$_ORCH_ANCHOR_LIB"
else
    echo "orch-degraded-watch: 共有 anchor lib 不在: $_ORCH_ANCHOR_LIB（anchor 解決不能・fail-closed）" >&2
    exit 1
fi
# anchor 解決（SCRIPTORIUM / WORKTREE_ROOT / EXTERNAL_REGISTRY）は scan path 専用ゆえ **arg-parse + pure-mode
# dispatch（--extract/--classify/--help）+ self-scope gate の後** に遅延させる（下部参照）。純関数モードと --help、
# および foreign cwd の self-scope reject は台帳/anchor に触れないため anchor 解決不能でも動く必要がある（engine の
# fail-loud anchor が pure/help/gate を巻き添えにしない）。lib source は上で済ませ、解決は scan 直前に行う。
GATE_BASE="${ORCH_DEGRADED_GATE_BASE:-main}"
BD="${ORCH_DEGRADED_BD:-bd}"
TMUX_BIN="${ORCH_DEGRADED_TMUX:-tmux}"

# 終端とみなす status 集合（CSV → 配列）。既定 closed,blocked＝終端宣言 DONE(closed)/BLOCKED(blocked)。
DONE_SET=()
IFS=',' read -ra DONE_SET <<< "${ORCH_DEGRADED_DONE_STATUS:-closed,blocked}"

# ─────────────────────────────────────────────────────────────────────────────
# ported: extract_status / is_terminal（scribe grill-status-watch.sh・sc-bka）
#   read-only な STATUS 抽出＝env/STATUS notes 補助（grill L2「届けば強証拠」）。foreign code を live 参照
#   せず自 repo に port（自己完結）。頑健化（bd error-object / 非配列 / notes 非文字列 / 壊れ JSON は
#   no-notes に潰し jq を非0終了させない）も原典の契約どおり移植する。
# ─────────────────────────────────────────────────────────────────────────────
extract_status() {
    jq -r 'if (type=="array" and (.[0]|type)=="object" and (.[0].notes|type)=="string")
           then (.[0].notes | split("\n") | map(select(startswith("STATUS:"))) | last // "no-status")
           else "no-notes" end' 2>/dev/null || echo "no-notes"
}

# STATUS 文字列が終端（canonical の done/blocked）なら 0。`STATUS:` を剥がした先頭トークンだけを
# done/blocked と前方一致（原典 sc-bka: grilling 行の自由文末尾 "… done" を terminal 誤判定しない）。
is_terminal() {
    local kw="${1#STATUS:}"
    kw="${kw#"${kw%%[![:space:]]*}"}"   # 先頭空白を除去
    case "$kw" in
        done*|blocked*) return 0 ;;
        *) return 1 ;;
    esac
}

# stdin: `bd show <id> --long --json`（配列）。stdout: status 文字列（非配列/欠如は空）。
_status_field() {
    jq -r 'if (type=="array" and (.[0]|type)=="object") then (.[0].status // "") else "" end' 2>/dev/null || echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# self-scope 判定の walk-up（_ledger_dolt_database）は共有 lib scripts/hooks/lib/orch_session.sh が提供する
# （上で source 済み・bd orch-t9z）。旧 _resolve_dolt_database は _json_is_valid gate を欠く drift だったため
# 撤去し、gate 済みの _ledger_dolt_database へ統一した（破損 orch-token metadata での誤 self-scope を弾く）。
# ─────────────────────────────────────────────────────────────────────────────

# ─────────────────────────────────────────────────────────────────────────────
# 構造3核ヘルパ（全て read-only）
# ─────────────────────────────────────────────────────────────────────────────

# live window 名一覧（tmux list-panes・read-only）。取得不能（tmux 不在/サーバ無）は空＝全 cell 窓消失側
# （fail-open で over-mark＝degraded を silent に取りこぼすより安全側）。
_live_window_names() {
    "$TMUX_BIN" list-panes -a -F '#{window_name}' 2>/dev/null | sort -u
}

# 核A（窓消失）: cell id の window wt-<id> が live pane に無ければ 0（窓消失）。有れば 1（生存＝候補外）。
_window_gone() {
    local id="$1" wins="$2"
    printf '%s\n' "$wins" | grep -qxF "wt-$id" && return 1
    return 0
}

# 核B（CLOSED不在）: bead が終端宣言済なら 0（terminal）・未終端なら 1（CLOSED不在）。
#   terminal = status ∈ done-set（closed/blocked）OR notes 最終 STATUS が terminal（done/blocked・extract_status 補助）。
#   bd 失敗/not-found（error-object 含む）は status 空・notes no-notes に潰れ「未終端」側＝CLOSED不在（保守的・
#   suspect 寄り）。※窓消失 AND commit=0 も同時成立して初めて salvage ゆえ bd 一過性障害だけで誤 salvage しない。
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

# 核C（commit=0）: worktree の base..HEAD 先行コミット数を echo（数値・解決不能は空）。read-only。
#   base は $2（未指定は global $GATE_BASE）。external root では呼び元が per-repo 解決した default branch を
#   渡す（orch-665・Option B）＝外部 repo が local main を持たなくても実 commit 数を数える（空→「判定不能」化を減らす）。
_commit_count() {
    local wt="$1" base="${2:-$GATE_BASE}" n
    n="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null)" || return 0
    printf '%s' "$n"
}

# 補助注釈（判定核でない・grill L2）: worktree HEAD の相対更新時刻（quiet since）。read-only。
_quiet_since() {
    local wt="$1" rel
    rel="$(git -C "$wt" log -1 --format=%cr 2>/dev/null)" || rel=""
    [ -n "$rel" ] && printf '%s' "$rel" || printf '不明'
}

# ── external repo cell registry（orch-b10・read-only）─────────────────────────────
# `_external_scan_roots`（registry を読み <root>/.worktrees/spawn を emit・self-skip / dedup / 非存在 skip）は
#   共有 lib orch_anchor.sh へ集約した（旧 dispatch との byte 複製を解消・orch-49g）。$EXTERNAL_REGISTRY /
#   $SCRIPTORIUM は caller-global として lib 関数が参照する（上で source 済み）。file read のみ＝SEC1 read-only
#   verb discipline（bd/tmux/git）を侵さない。

# ─────────────────────────────────────────────────────────────────────────────
# scan: spawn cell を走査し suspect/salvage を stdout へ（read-only・observe のみ）
# ─────────────────────────────────────────────────────────────────────────────
# 1 root（<...>/.worktrees/spawn）配下の spawn cell を構造3核で走査し suspect/salvage を stdout へ。
#   caller（run_scan）の local カウンタ found_salvage/found_suspect を dynamic scope で加算する（bash の local は
#   呼び出し先関数から可視＝別途 global を作らない）。external root は surface 行に repo root を注記する。
#   kind: self | external（external のとき root_label=repo root を surface に付与）。全 verb は read-only。
_scan_root_cells() {
    local root="$1" wins="$2" kind="$3" root_label="$4" base="${5:-$GATE_BASE}"
    [ -d "$root" ] || return 0
    local d branch id wgone terminal cnt nocommit quiet suffix why
    suffix=""
    [ "$kind" = external ] && suffix="  (external repo cell・root=$root_label・orch-b10)"
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        branch="$(git -C "$d" branch --show-current 2>/dev/null)" || continue
        [ -n "$branch" ] || continue
        # spawn/<id>-<HHMMSS> から cell id を復元（orch-dispatch の抽出と同一規約）。
        id="$(printf '%s' "$branch" | sed -E 's#^spawn/##; s/-[0-9]+$//')"
        [ -n "$id" ] || continue

        # 核A: 窓消失?
        if _window_gone "$id" "$wins"; then wgone=1; else wgone=0; fi
        # 窓が有る＝生存 cell は degraded-death 候補にしない（grill L2・見かけ idle も窓有りで除外）。
        [ "$wgone" -eq 1 ] || continue

        # 核B: CLOSED不在?
        if _bead_terminal "$id"; then terminal=1; else terminal=0; fi
        # 核C: commit=0?（base は呼び元が root 種別ごとに渡す＝external は per-repo 解決した default branch・orch-665）
        #   external root（orch-igl containment gate）: `_resolve_repo_base` は「main worktree の checkout branch」で
        #   default を近似するため、foreign main worktree が非 default branch（cell 系列から乖離）を checkout 中だと
        #   base が cell 系列外を指し commit 数が不正確になる（salvage/suspect 誤分類）。包含関係で弁別する:
        #     ・contained（HEAD⊂base・a=0）→ cnt=0（統合済/未着手＝nocommit=1・従来と同）。
        #     ・ahead n（base⊂HEAD）→ cnt=n（正確な先行数）。
        #     ・diverged（a>0 ∧ b>0）→ cnt="乖離"（不正確な数を出さず fail-loud＝commit=乖離 で surface・nocommit=0）。
        #     ・解決不能（rc≠0）→ cnt 空（従来どおり commit=判定不能・nocommit=0）。
        #   self root（kind=self）は base=main 常時解決可＝従来の _commit_count を byte 不変で維持する（dispatch (E5) と対称）。
        if [ "$kind" = external ]; then
            local rel; rel="$(_repo_base_relation "$d" "$base")"
            case "$rel" in
                contained)   cnt=0 ;;
                ahead\ *)    cnt="${rel#ahead }" ;;
                diverged\ *) cnt="乖離" ;;
                *)           cnt="" ;;   # 解決不能/未知 → 判定不能扱い（fail-loud）
            esac
        else
            cnt="$(_commit_count "$d" "$base")"
        fi
        if [ -n "$cnt" ] && [ "$cnt" -eq 0 ] 2>/dev/null; then nocommit=1; else nocommit=0; fi

        quiet="$(_quiet_since "$d")"

        # 分類: salvage = A×B×C（強AND）/ suspect = A×(B∨C)（緩OR）。窓有りは上で continue 済＝A は常に真。
        if [ "$terminal" -eq 0 ] && [ "$nocommit" -eq 1 ]; then
            found_salvage=$((found_salvage + 1))
            printf '  [SALVAGE] %-12s 窓消失 × CLOSED不在 × commit=0（degraded 濃厚・要 salvage 介入）  branch=%s quiet=%s%s\n' \
                "$id" "$branch" "$quiet" "$suffix"
        elif [ "$terminal" -eq 0 ] || [ "$nocommit" -eq 1 ]; then
            if [ "$terminal" -eq 0 ]; then
                # commit 判定を surface（cnt 空＝git rev-list 解決不能なら「判定不能」を明示・silent drop 解消）。
                # cnt 空時は上で nocommit=0（fail-open・非 degraded 側）ゆえこの A×B suspect 経路に落ちる。
                why="窓消失 × CLOSED不在（commit=${cnt:-判定不能}・delivery したが未終端の疑い）"
            else
                why="窓消失 × commit=0（終端宣言済だが produce ゼロの疑い）"
            fi
            found_suspect=$((found_suspect + 1))
            printf '  [SUSPECT] %-12s %s  branch=%s quiet=%s%s\n' "$id" "$why" "$branch" "$quiet" "$suffix"
        fi
    done
}

run_scan() {
    echo "orch-degraded-watch: scan root=$WORKTREE_ROOT base=$GATE_BASE（構造3核・時間 cap 非核・grill sc-3pq/orch-nzd）"
    # external repo cell roots（orch-b10）: registry-discovered。存在すれば header に列挙する（read-only）。
    local ext_roots; ext_roots="$(_external_scan_roots)"
    # orch-b10 E4: ext_roots は改行区切り。unquoted 展開は pathname expansion（glob）を被るため quoted な
    #   改行→空白置換で列挙する（root path に glob メタ文字が含まれても展開しない）。
    [ -n "$ext_roots" ] && echo "  + external repo cell roots（orch-b10・registry $EXTERNAL_REGISTRY）: ${ext_roots//$'\n'/ }"

    local wins; wins="$(_live_window_names)"
    local found_salvage=0 found_suspect=0

    # self（scriptorium）root: base=global $GATE_BASE（main 常時解決可＝per-repo 解決は掛けない・dispatch (E5) と対称）。
    if [ -d "$WORKTREE_ROOT" ]; then
        _scan_root_cells "$WORKTREE_ROOT" "$wins" self "" "$GATE_BASE"
    else
        echo "  (spawn worktree root なし: $WORKTREE_ROOT) — 監視対象 cell はありません"
    fi

    # external repo cell roots（orch-b10）: 各外部 repo の .worktrees/spawn も同 3 核で走査。
    #   orch-665（Option B）: external repo は local `main` を持たない（master/develop/trunk 既定）ことがあり、
    #   global $GATE_BASE=main のままだと rev-list が非0終了し cnt 空→「commit=判定不能」に落ちて lossy だった。
    #   repo ごとに default branch（main worktree の symbolic-ref HEAD）を _resolve_repo_base で解決し正確な commit
    #   数を数える。解決不能（detached HEAD 等）なら global base へ fallback＝従来の cnt 空→判定不能 経路へ倒れる。
    local extroot extrepo extbase
    while IFS= read -r extroot; do
        [ -n "$extroot" ] || continue
        extrepo="${extroot%/.worktrees/spawn}"
        extbase="$(_resolve_repo_base "$extrepo" || printf '%s' "$GATE_BASE")"
        _scan_root_cells "$extroot" "$wins" external "$extrepo" "$extbase"
    done <<< "$ext_roots"

    if [ "$found_salvage" -eq 0 ] && [ "$found_suspect" -eq 0 ]; then
        echo "  degraded/suspect: なし（構造3核に該当する窓消失 cell はありません）"
    else
        echo "  ── 集計: salvage=$found_salvage suspect=$found_suspect（salvage=強AND 誤殺防止 / suspect=緩OR 要確認）"
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

MODE="scan"
CLASSIFY_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --extract)  MODE="extract"; shift ;;
        --classify) MODE="classify"; CLASSIFY_ARG="${2:-}"; shift 2 ;;
        -h|--help)  usage 0 ;;
        --*)        echo "orch-degraded-watch: 不明なオプション: $1（--extract / --classify / --help）" >&2; usage 1 ;;
        *)          echo "orch-degraded-watch: 位置引数は取りません: $1" >&2; usage 1 ;;
    esac
done

# extract/classify は self-scope gate の対象外（純関数・stdin/引数のみで台帳に触れない）。
case "$MODE" in
    extract)  extract_status; exit 0 ;;
    classify) if is_terminal "$CLASSIFY_ARG"; then echo terminal; else echo ongoing; fi; exit 0 ;;
esac

# scan は self-scope gate（誤台帳起動を fail-closed で弾く・guard / orch-architecture-hydrate と一貫）。
if [ "${ORCH_DEGRADED_SKIP_SESSION_GATE:-}" != "1" ]; then
    DB="$(_ledger_dolt_database "$PWD")"
    if [ "$DB" != "$SELF_PREFIX" ]; then
        echo "orch-degraded-watch: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
        echo "  orchestrator session（cwd=orchestrator）から実行せよ。self-scope の fail-closed。" >&2
        exit 1
    fi
fi

# anchor 解決（engine 版・scan path 専用）: env override > 共有 lib _resolve_scriptorium（ORCH_ANCHOR /
# ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き）。解決不能は fail-loud（deploy-layout 依存の hardcode fallback は
# engine では持たない）。pure-mode/--help/self-scope reject を巻き添えにしないよう self-scope gate の後に置く。
SCRIPTORIUM="${ORCH_DEGRADED_SCRIPTORIUM:-$(_resolve_scriptorium || true)}"
if [ -z "$SCRIPTORIUM" ]; then
    echo "orch-degraded-watch: anchor 解決不能（fail-loud）: env ORCH_DEGRADED_SCRIPTORIUM / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ（engine は hardcode fallback を持たない）。" >&2
    exit 1
fi
WORKTREE_ROOT="${ORCH_DEGRADED_WORKTREE_ROOT:-$SCRIPTORIUM/.worktrees/spawn}"
# external repo cell registry（orch-b10）: orch-dispatch が `--repo` 外部 repo cell の repo root を記録する runtime
#   マーカー（orch-dispatch.sh と同一ファイル・既定 <SCRIPTORIUM>/.beads/external-repo-cells）。degraded scan は
#   これを読み <root>/.worktrees/spawn も走査＝外部 repo cell の窓消失/未 merge を構造3核の監視射程へ入れる
#   （終端宣言 write が worker sandbox で断たれても拾う・incident orch-7ti）。read-only（file read のみ）。
EXTERNAL_REGISTRY="${ORCH_DEGRADED_EXTERNAL_REGISTRY:-$SCRIPTORIUM/.beads/external-repo-cells}"

run_scan

#!/usr/bin/env bash
# session-start-role-inject.sh — scribe SessionStart role 別文脈注入（bd un-ck2 / v0-C2）
#
# 役割: SessionStart で role(admin/worker/consult)を実行時 guard で判定し、role 別の
#       規約文脈を stdout へ注入する。SessionStart hook は stdout を session の context へ
#       注入する仕様（Claude Code）に従うため、ここでは plain stdout に出力する。
#
# opt-in ガード（docs/role-context-spec.md §1.0・bd un-7hx）:
#   本 script はグローバル hook として**ホストの全 SessionStart で発火**する。scribe を
#   使わないプロジェクト（paper 等）へ規約を注入しないよう、cwd（または git toplevel）に
#   `.beads/` が存在するときだけ注入する。`.beads` = scribe opt-in の代理マーカー（beads は
#   scribe の前提 substrate ゆえ「.beads あり ⇔ scribe 管轄」が一致する）。無ければ role
#   判定すら行わず無出力で exit 0（現行 fail-safe を維持）。
#
# role 判定（docs/role-context-spec.md §1 と整合・優先順は上から最初に当たったもの）:
#   1. env SCRIBE_ROLE が認識可能な role(admin|worker|consult) → それを採用
#      （一次は consult の明示焼き込み=C3 ヘルパーが --env-file で行う。worker の
#        admin/consult 上書きが必要なら env で明示できる設計でよい・spec §1 注記）
#   2. cwd が .worktrees/ または .claude/worktrees/（CC-native worktree）配下 → worker
#      （worktree = worker の構造的マーカー。scribe-spawn は .worktrees/ 配下に作るが、
#        CC-native worktree〔EnterWorktree 等〕は .claude/worktrees/ 配下ゆえ両方拾う）
#   3. 既定（上記いずれにも当たらない・anchor 無印） → admin
#   ※ SCRIBE_ROLE=none は既知の opt-out: role 注入を抑止し無出力 exit 0（degrade せず warning も出さない）。
#     別レイヤ(自前 .beads の orchestrator 等)が scribe role 注入を受けないための明示シグナル（spec §1.1）
#   ※ window 名は判定に使わない（表示規約のみ・spec §1）
#
# 注入内容の SSOT（本文を script に二重化しない・spec §3。script は「どの file/どの sentinel 区間を
#                  出すか」だけを持ち、本文は doc から抽出する）:
#   admin   = docs/protocol.md の boot core 区間 `scribe-core-admin`（progressive disclosure・sc-x93w）
#   worker  = docs/protocol.md の boot core 区間 `scribe-core-worker`（同上）
#   consult = docs/role-context-spec.md §2.3（read-only・記憶系のみ write・サマリ保存義務・暫定運用）
#             ※ consult の規約 SSOT は protocol.md ではなく role-context-spec.md §2.3 にインライン
#               移設済み（un-tao テンプレ移設版）。
#
# ★progressive disclosure（sc-x93w / orch-db47 leg(1)）: SessionStart 注入は UTF-16 code unit 10,000 で
#   truncate される（実測）。旧実装は admin へ protocol.md 全文（121,513 u16）を cat しており実配達は
#   1.79%＝worker の §3/§4 配達率は 0% だった。ゆえに **doc 側に置いた boot core（不変条件の 1 行版）
#   だけを注入し、on-demand 全文へは「絶対 path + trigger 表」で到達させる** 2 段構えへ変えた。
#   本文は doc が SSOT のままで（script はヒアドキュメントへ規約本文を書かない）、script が持つのは
#   「どの sentinel 区間を出すか」だけ、という spec §3 の規律は不変。
#
# fail-safe: 判定不能・doc 不在・sentinel 区間の欠落でもセッションを壊さない。set -e は使わず
#            常に exit 0(degrade)、警告は stderr。これは「全セッション破壊の防止」の核心。
#            抽出器は begin/end が各ちょうど 1 個であることを検査し、欠落・重複・逆順では
#            **空を返さず非 0**（fail-loud）＝header だけのサイレント部分注入で pin を空虚化させない。
#            本文抽出は sed のみに依存する（awk / grep / python3 を規約本文の carrier 経路の必須依存に
#            しない＝restricted PATH でも 3 role とも規約本文が届く）。

# --- plugin root / doc パス解決（CLAUDE_PLUGIN_ROOT 優先・無ければ script 位置から導出） ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    # scripts/hooks/ の 2 つ上 = plugin root
    PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
PROTOCOL_DOC="$PLUGIN_ROOT/docs/protocol.md"
SPEC_DOC="$PLUGIN_ROOT/docs/role-context-spec.md"

# --- emit-budget 共有 lib（measure-then-emit の単一入口・sc-mzhi / orch-db47 leg(4) ■11）---
# 本 script の stdout は SessionStart で context へ注入される＝予算（既定 warn 8,000 u16）を持つ。
# lib が本文を u16 で実測し、超過時のみ警告を **stdout 先頭** へ前置する（truncate はしない）。
# fail-open: lib 不在・壊れでも本文注入を止めない——source 失敗時は「本文をそのまま出すだけ」の
# no-op fallback を同じ API 形で定義し、以降の呼び出し側を分岐させない。
# ★fallback の発火条件は「source の rc」ではなく **API の存在**（sc-mzhi self-review major）:
#   構文的には valid だが scribe_emit_with_budget を含まない lib（部分書込・rsync/cp 中断・plugin 版
#   ズレ・将来の関数リネーム）を掴むと `.` は rc=0 を返し、fallback が定義されないまま呼出が
#   `command not found`（stderr のみ）となり、stdout 0 byte / exit 0 の **silent total loss** になる。
#   `command -v` は shell 関数も解決する（verified）ので、これで唯一の単一障害点を塞ぐ。
# shellcheck source=lib/emit_budget.sh
if ! . "$_SCRIPT_DIR/lib/emit_budget.sh" 2>/dev/null \
   || ! command -v scribe_emit_with_budget >/dev/null 2>&1; then
    scribe_emit_with_budget() { [ -n "${1:-}" ] || return 0; printf '%s\n' "$1"; return 0; }
fi
# 計測 bound は **lib 既定（1s）のまま上書きしない**（wire 予算は hooks/hooks.json で 10,000ms）。
# 事実: 本 hook は emit の前に **timeout で包まれていない待ちを 2 つ**持つ——
#   (1) `_scribe_has_beads` の `git rev-parse --show-toplevel`（cwd 直下に .beads が無い経路＝repo の
#       サブディレクトリから起動したセッションでは必ず発火する）
#   (2) `_scribe_is_consult_window` の `tmux display-message`
# どちらも所要時間の上限を持たないため、「計測 bound + 既知 bound の和 < wire 予算」という形の算術は
# そもそも立たない。よって計測側は最小へ倒す（lib 既定 1s）。実 admin body の u16 計測は実測 0.017s
# ゆえ bound を伸ばして買えるものは無く、伸ばした分だけ上記 (1)(2) が遅い環境で wire kill の窓が開く
# （kill されると stdout は 1 byte も出ず、wire の `|| true` ゆえ silent に規約注入が全損する）。
# lib が置いた非対称性の原則どおり: 計測を諦めて失うのは warn だけで、本文は fail-open で必ず出る。

# --- stdin の hook JSON から cwd / source を抽出（jq → sed フォールバック）。tty なら読まない(block 回避) ---
# 全 hook の stdin JSON 共通フィールドに cwd が含まれ（session_id/transcript_path/cwd/...）、
# SessionStart は加えて source（startup|resume|clear|compact）を持つ（公式 hooks 仕様）。
# stdin は一度しか読めないため起動時に 1 回だけ読んで保持し、フィールドは汎用抽出器で個別に取り出す
# （sc-o7fz: cwd 専用 _scribe_extract_cwd を置換・jq→sed fallback の二系統は不変）。
# 抽出不能なら無出力 → 呼び出し側でフォールバック（cwd は $PWD へ・source は空=未知扱い）。
_SCRIBE_HOOK_STDIN=""
if [ ! -t 0 ]; then
    _SCRIBE_HOOK_STDIN="$(cat 2>/dev/null)"
fi

_scribe_extract_json_string() {
    # $1 = top-level キー名（英数字のみ想定・sed パターンへ連結するため regex メタは渡さない）
    local key="$1" val
    [ -z "$_SCRIBE_HOOK_STDIN" ] && return 0
    if command -v jq >/dev/null 2>&1; then
        val="$(printf '%s' "$_SCRIBE_HOOK_STDIN" | jq -r --arg k "$key" '.[$k] // empty' 2>/dev/null)"
    else
        val="$(printf '%s' "$_SCRIBE_HOOK_STDIN" \
            | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
            | head -n1)"
    fi
    [ -n "$val" ] && printf '%s' "$val"
    return 0
}

# --- boot core の sentinel 区間を抽出（sed のみ・fail-loud・sc-x93w / ■5-4 / ■6-1） ---
# $1=file / $2=sentinel 名（例 `scribe-core-admin`）。区間は HTML コメント
#   `<!-- <名>:begin -->` … `<!-- <名>:end -->`（各ちょうど 1 個・begin が end より前）で挟む。
# ★fail-loud（rc=9）にするのが load-bearing: 欠落・重複・逆順で「空でない部分抽出」を黙って返すと、
#   core 固有 literal を pin している teeth が header/intro だけで green になり pin が空虚化する。
#   呼び手（hook 本体）は rc!=0 を受けたら **何も注入せず** stderr へ warn して exit 0（fail-open）。
# ★sed 以外に依存しない: 出現行番号を `sed -n '/pat/='` で取り、件数・順序の判定と行範囲の切り出しは
#   bash 内で完結させる（grep / awk / wc を規約本文の carrier 経路へ持ち込まない＝restricted PATH 耐性）。
#   sentinel 名には正規表現メタ文字（`.` `*` `[` `\` `/`）を使わない（sed の BRE へそのまま埋めるため）。
_scribe_emit_sentinel_section() {
    local file="$1" name="$2"
    local b="<!-- ${name}:begin -->" e="<!-- ${name}:end -->"
    local blines elines bline eline

    blines="$(sed -n "/$b/=" "$file" 2>/dev/null)"
    elines="$(sed -n "/$e/=" "$file" 2>/dev/null)"

    # 単語分割で件数と先頭要素を得る（空文字列なら $# = 0）
    set -- $blines
    [ "$#" -eq 1 ] || return 9
    bline="$1"
    set -- $elines
    [ "$#" -eq 1 ] || return 9
    eline="$1"

    [ "$bline" -lt "$eline" ] || return 9

    # 区間が空（begin の直後が end）なら何も出さずに正常終了する。
    # ※ここを sed の範囲アドレスへ丸投げすると addr2 < addr1 で「addr1 の 1 行だけ」を出す挙動に
    #   落ち、end sentinel 行そのものを本文として吐く（区間を空にする反 false-green 検証が偽 green
    #   になる）。数値で先に弾く。
    [ "$((bline + 1))" -le "$((eline - 1))" ] || return 0

    sed -n "$((bline + 1)),$((eline - 1))p" "$file"
}

# --- role-context-spec.md の §2.3 サブセクションを抽出（### 2.3 〜 次の --- 直前・sed のみ） ---
# 旧実装は awk（`inseg` フラグ）だったが、規約本文の carrier 経路から awk 依存を外すため sed 化した
# （■6-1）。範囲アドレスで `### 2.3` 〜 直後の水平線までを取り、終端の `---` 行だけを落とす＝旧 awk と
# 同一の出力（`### 2.3` 行を含み `---` 行を含まない）になる。
_scribe_emit_consult_section() {
    local file="$1"
    sed -n '/^### 2\.3/,/^---[[:space:]]*$/{ /^---[[:space:]]*$/d; p; }' "$file"
}

# --- .beads opt-in マーカー検出（cwd 直下 → git toplevel フォールバック・bd un-7hx） ---
# scribe は beads を前提 substrate とするため、.beads/ の存在を「この cwd は scribe 管轄」
# の opt-in 代理判定に使う。cwd 直下に無くても、cwd が repo のサブディレクトリなら
# git toplevel に .beads/ がありうるためフォールバック確認する（git 不在/非 repo は無害に
# 失敗し false を返す＝fail-safe）。実体は anchor/worktree とも .beads ディレクトリ。
# 堅牢化（gate self-check・bd un-7hx）: 本 script はホスト全 SessionStart で発火するため、
# 親プロセスが GIT_DIR/GIT_WORK_TREE を export していると `rev-parse --show-toplevel` が
# 継承 env に従って無関係 repo の toplevel を解決し**過剰注入**しうる（実測再現・過剰注入は
# 本ガードの設計目的に反する UNSAFE 方向）。toplevel 解決を継承 git env から隔離する。
_scribe_has_beads() {
    local dir="$1"
    [ -n "$dir" ] || return 1
    [ -d "$dir/.beads" ] && return 0
    local top
    top="$(cd "$dir" 2>/dev/null && env -u GIT_DIR -u GIT_WORK_TREE git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$top" ] && [ -d "$top/.beads" ] && return 0
    return 1
}

# --- consult 窓判定（tmux window 名 prefix `consult-` で弁別・sc-cji / orch-qcqz leg-a） ---
# 動機: scriptorium anchor（settings.json に SCRIBE_ROLE=none を wire）で consult を spawn すると、
# CC が settings project 層 env を hook 子プロセスへ優先適用し、env-file の SCRIBE_ROLE=consult を
# none で上書きする（orchestrator が /proc environ 直読で verified）。結果 consult 窓が下記 `none)`
# 枝の opt-out に落ち consult 規約が注入されない。env は none に潰されるが tmux window 名は残るため、
# scribe-spawn が consult 窓へ必ず付与する prefix `consult-`（命名規約: grill-consult=consult-<issue>
# / plain=consult-HHMMSS）を env-clobber を生き延びる弁別軸に使う。
# fail-safe: tmux 不在 / TMUX 未設定 / 取得失敗・空出力は「consult でない」(return 1) ＝ 既存 anchor
# 挙動へ委ねる（「不能→no-op」でなく「不能→従来判定」。consult は tmux 同居ゆえ実害なし・operative
# 契約は spawn prompt が担保）。取得は必ず `-t "$TMUX_PANE"` 明示（背景 spawn 中に human が別窓 focus
# すると bare `display-message` は誤窓名を返す・verified hazard）。tmux 呼出は `"${SCRIBE_TMUX:-tmux}"`
# 経由で bats から stub 可能にする（scribe-spawn.sh:718 と同一 seam 名）。
# ★orca タブ由来 stale pane の skip（sc-0dx9 / ot 依頼 leg(b)）:
#   orca（GUI ターミナル）タブから起動したセッションは TMUX / TMUX_PANE を**非空のまま**継承するが、
#   その TMUX_PANE が指す pane は既に消滅していることがある（実測: TMUX=/tmp/tmux-1001/default,1601,16 /
#   TMUX_PANE=%88 で **server 自体は生存**し pane %88 だけが消滅）。不在 pane への display-message は
#   rc=0 + 空（複数フィールド format なら区切りだけの非空）を返すため、**rc でも出力の非空でも**実在を
#   判定できない。ゆえに pane 実在は `#{pane_id}` の**エコー一致**（積極証拠）で判定する。
#   ★skip は **論理積**（ORCA_TERMINAL_HANDLE が非空 ∧ エコー不一致）に限る——handle 単独条件にすると、
#   tmux server が orca タブ起点で再起動されて server env に handle が入り全 pane がこれを継承した場合、
#   sc-cji の consult 復帰が **silent に全滅**する。handle 不所持でのエコー不一致は従来どおり扱う
#   （skip せず取得した窓名でそのまま prefix 判定＝空なら非 consult）。
#   ★将来（要反転）: consult を **orca タブ化**（出典: ot-ody 論点3 / orca-migration-recon Q5 案 B）すると、
#     **本 skip が正当な consult を殺す向きに反転**する。その時点で本条件を外すか反転させること。
#   限定（過大主張しない）: pane 実在検証が塞ぐのは**不在 pane のみ**。stale だが生存中の pane を指す型は
#   本 leg では塞がらない（pane id は同一 server 内で再利用されないため、その型は server 世代交代後にのみ成立）。
#   照合は TMUX_PANE が `%N` 形であることを前提とする。`%N` 以外の target 形が入ると正当 pane でも不一致に
#   なりうるが、帰結は既存 fail-safe と同じ非 consult であり新たな害は無い。
#   fail-loud は stderr 1 行のみ（skip 経路だけ・silent 失効の可視化）。fail-safe の向き・exit 0 は不変。
_scribe_is_consult_window() {
    command -v "${SCRIBE_TMUX:-tmux}" >/dev/null 2>&1 || return 1
    [ -n "${TMUX:-}" ] || return 1
    # TMUX_PANE 空も gate（gate review finding・独立 2 lens 収束）: 空だと -t "" が bare 形と同じ
    # active-pane 解決へ縮退し「取得は必ず -t 明示」の防護が黙って無効化される（tmux 3.4 実測=
    # -t "" は現在 focus 窓名を exit 0 で返す）。pane 識別子なし=防護が効かない→fail-safe(非 consult)。
    [ -n "${TMUX_PANE:-}" ] || return 1
    local _out _pid _w
    # tmux 呼出は **1 回のまま**（pane_id と #W を 1 回で同時取得する・この hook は timeout 非包の待ちを
    # 2 つ持ち、呼出を増やすと wire 予算超過＝stdout 0 byte の silent 全損の窓が広がる）。
    _out="$("${SCRIBE_TMUX:-tmux}" display-message -p -t "${TMUX_PANE:-}" '#{pane_id} #W' 2>/dev/null)" || return 1
    # parse は空白 1 個区切り（非貪欲）: 窓名に空白が入っても窓名側を丸ごと復元できる。cut/awk/python3 に
    # 依存しない（restricted PATH 耐性）。参照実装 scripts/lib/scribe-lib.sh の scribe_current_session と同型。
    _pid="${_out%% *}"
    _w="${_out#* }"
    if [ "$_pid" != "${TMUX_PANE:-}" ]; then
        # 論理積の handle 条件（空文字は set でないと扱う: 空 set を skip 側に数えると skip が広がり、
        # 本 leg が最も恐れる「正当な consult を殺す」向きへ倒れる）。
        if [ -n "${ORCA_TERMINAL_HANDLE:-}" ]; then
            echo "[scribe/SessionStart] warning: ORCA_TERMINAL_HANDLE あり + pane_id エコー不一致 → orca タブ由来の stale TMUX_PANE とみなし consult 窓判定を skip(非 consult・sc-0dx9) TMUX_PANE=${TMUX_PANE:-}" >&2
            return 1
        fi
    fi
    # 退化ガード: 区切りが無い出力（1 フィールドのみ）は _w == _pid になる＝判定不能ゆえ非 consult へ倒す。
    [ "$_w" != "$_pid" ] || return 1
    case "$_w" in
        consult-*) return 0 ;;
        *)         return 1 ;;
    esac
}

# === role 判定 ===
hook_cwd="$(_scribe_extract_json_string cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
# SessionStart source（startup|resume|clear|compact）。ultracode リマインダの分岐（admin 注入）にのみ
# 使い、role 判定には使わない。抽出不能は空＝未知として fail-safe 側（リマインダを出す）へ倒す。
hook_source="$(_scribe_extract_json_string source)"

# === .beads opt-in guard（scribe 管轄外セッションには何も注入しない・bd un-7hx） ===
# cwd（または git toplevel）に .beads/ が無ければ scribe を使っていないプロジェクトと
# みなし、role 判定すら行わず無出力で exit 0 する。これがグローバル hook の規約注入を
# scribe opt-in したプロジェクトに限定し、無関係セッション（paper 等）への漏洩を塞ぐ。
# 注入漏れ防止が目的ゆえ stderr 警告も出さない（無関係セッションを汚さない）。
if ! _scribe_has_beads "$hook_cwd"; then
    exit 0
fi

role=""
detect_basis=""
case "${SCRIBE_ROLE:-}" in
    admin|worker|consult)
        role="$SCRIBE_ROLE"; detect_basis="env SCRIBE_ROLE" ;;
    "")
        : ;;  # 未設定 → cwd/既定判定へ
    none)
        # 既知の opt-out 値: 別レイヤ(自前 .beads を持つ orchestrator 等)が「どの scribe role 注入も
        # 受けない」を機械保証するための明示シグナル。未知値(*)と異なり degrade(cwd/既定 admin 注入)
        # せず、warning も出さず無出力で exit 0 する(意図的 opt-out ゆえ正常終了)。.beads opt-in ガードを
        # 通過済でも role 注入を抑止する(bfe0ce39 / decision 115521de: advisory な隔離・実隔離は別途 guard)。
        # 例外(sc-cji): scriptorium anchor の consult 窓は settings.json project 層 env が SCRIBE_ROLE を
        # none に潰すため(orch-qcqz verified)、正当な opt-out と env-clobber された consult を env だけでは
        # 区別できない。tmux window 名 prefix consult- で consult 窓を弁別できたときのみ consult へ復帰し、
        # それ以外の none は従来どおり opt-out(exit 0)＝orchestrator anchor 等の意図的 opt-out を壊さない。
        if _scribe_is_consult_window; then
            role="consult"; detect_basis="window consult-*(env SCRIBE_ROLE=none override・sc-cji)"
        else
            exit 0
        fi ;;
    *)
        echo "[scribe/SessionStart] warning: 未知の SCRIBE_ROLE='${SCRIBE_ROLE}' を無視し cwd/既定判定へ degrade" >&2 ;;
esac

if [ -z "$role" ]; then
    case "$hook_cwd" in
        */.worktrees/*)        role="worker"; detect_basis="cwd .worktrees/" ;;
        */.claude/worktrees/*) role="worker"; detect_basis="cwd .claude/worktrees/" ;;
        *)                     role="admin";  detect_basis="既定(anchor 無印)" ;;
    esac
fi

# === role 別 注入 ===
_scribe_header() {
    echo "=== [scribe/SessionStart] role=$role (判定: $detect_basis) ==="
    echo ""
}

# --- 機械防御 carrier self-check（split-brain 検出・sc-99c） ---
# worker の機械防御——`edit-write-guard.py`（Edit/Write を自 worktree 境界へ縛る PreToolUse guard・
# protocol.md §3）と env-probe / zombie sentinel / 実効 effort 統制——は scribe-spawn が焼く
# env signal（`SCRIBE_WORKER=1` / `SCRIBE_WORKTREE`）と spawn prompt の operative コマンドが唯一の
# carrier。しかし本 script の role 判定は cwd（`.worktrees/` / `.claude/worktrees/`）で worker を
# 分類するため、scribe-spawn を経ない CC-native worktree（EnterWorktree 等・`.claude/worktrees/`
# 配下）は worker 分類されても env signal を伴わず**機械防御がゼロになる**（split-brain）。この空白を
# worker が黙って踏まないよう、SCRIBE_WORKER/SCRIBE_WORKTREE 不在を検査し loud warning を stdout
# （＝context 注入）へ出す。carrier モデルの本文 SSOT は docs/protocol.md §2（本注入と spawn prompt の
# 両 carrier がここを引く＝drift 停止）。※注入内容に protocol.md の top-level 見出し（`## N.`）文字列を
# 混ぜない——worker 注入は boot core 区間だけという既存不変条件（`## 1.` / `## 5.` / `## 6.` の非注入を
# 測るテスト pin）を壊さないため（sc-x93w 以降は「§2-4 のみ」ではなく「core 区間のみ」）。
_scribe_worker_defense_warn() {
    local wt="${SCRIBE_WORKTREE:-}"
    if [ "${SCRIBE_WORKER:-}" != "1" ]; then
        cat <<'DEFWARN'
⚠️ **機械防御が無効（このセッションは scribe-spawn 経由ではありません・sc-99c）** ⚠️
- このセッションは cwd（worktree 配下）で **worker 分類**されましたが、環境変数 `SCRIBE_WORKER=1` / `SCRIBE_WORKTREE` が**不在**です＝**scribe-spawn を経ていない**（例: `EnterWorktree` 等の CC-native worktree）。
- そのため scribe-spawn が据える**機械防御が全て無効**です:
  - **`edit-write-guard.py`（Edit/Write/NotebookEdit を自 worktree 境界へ縛る PreToolUse guard・B/hybrid 境界）は `SCRIBE_WORKER=1` のときだけ発火**するため、今は発火せず——**worktree 外への書込を機械的に止められません**。
  - **env-probe / zombie pane sentinel（spawn prompt の operative コマンド carrier）と 実効 effort 統制（env-file の `CLAUDE_CODE_EFFORT_LEVEL`＝env signal carrier）——いずれも scribe-spawn だけが据える carrier**ゆえ**未注入**です——env 劣化の fail-closed 検出・全ツール死（zombie）検知・effort 実効化が効きません。
- 対処: **自律実装セルとして走らせるなら、この窓を捨てて `scribe-spawn`（`.worktrees/` 配下に spawn）で起動し直す**（機械防御が要るため）。手動で続けるなら、**自 worktree 境界の遵守と env 健全性は自己責任**で、人間監督下で行うこと（この窓では B/hybrid 境界を機械が守りません）。

DEFWARN
    elif [ -z "$wt" ] || [ ! -d "$wt" ]; then
        cat <<DEFWARN2
⚠️ **worktree 境界を確立できません（SCRIBE_WORKER=1 だが SCRIBE_WORKTREE 不正・sc-99c）** ⚠️
- \`SCRIBE_WORKER=1\` ですが \`SCRIBE_WORKTREE\`（='${wt}'）が未設定／実在ディレクトリではありません。
- **\`edit-write-guard.py\` は境界不確立で fail-closed＝全 Edit/Write/NotebookEdit を block** し、env-probe も境界を解決できません。scribe-spawn は SCRIBE_WORKTREE を自 worktree の絶対パスへ焼きます——手動起動なら SCRIBE_WORKTREE を自 worktree の絶対パスへ設定し直してください。

DEFWARN2
    fi
}

# === 注入本文の組み立て（measure-then-emit・■7 の 5 段順序）===
# stdout の順序を次に固定する:
#   (1) emit-budget warn（u16 が warn 閾値を超えたときだけ・lib が前置する）
#   (2) role header 1 行
#   (3) 自衛文枠 = role 別 intro（+ admin のみ ultracode リマインダ）
#   (4) core 本体（doc からの供給）
#   (5) 機械防御 split-brain warning（sc-99c）は **本文の後ろ**（本文は 1 byte も削らない。loud 性は
#       「出ること」で担保され、先頭の希少枠を占有する必要はない）
# 本文は必ず変数へ全量受けてから 1 回で出す——`cat` の直流しや逐次 echo では (1) の「先頭 warn」が
# 構造的に成立しない（本文を出し始めた後では前置できない）。degrade / opt-out 経路は body を作らず
# その場で exit 0 する（無出力＝warn も出さない・■7）。
#
# ★(3) 自衛文枠は「これは要約である旨 + 自 role の規約 SSOT doc の**絶対 path**（実行時展開）+ Read 指示」
#   を先頭 1,000 u16 以内に置く（■7(3) / acceptance(2)）。path は必ず $PROTOCOL_DOC / $SPEC_DOC から
#   展開する——tracked file へホーム配下の絶対 path を literal で焼くと、ephemeral な worktree path が
#   公開 repo に残るため（■13-3）。trigger 表は doc 側の core 冒頭が持つ（script は規約本文を持たない・■4-6）。
body=""
case "$role" in
    admin)
        if [ ! -r "$PROTOCOL_DOC" ]; then
            echo "[scribe/SessionStart] warning: protocol.md 不在($PROTOCOL_DOC)・admin 文脈注入を skip(degrade)" >&2
            exit 0
        fi
        core="$(_scribe_emit_sentinel_section "$PROTOCOL_DOC" scribe-core-admin)" || {
            echo "[scribe/SessionStart] warning: boot core 区間(scribe-core-admin)を $PROTOCOL_DOC から抽出できません(begin/end が各 1 個で begin が先、を満たさない)・admin 文脈注入を skip(degrade)" >&2
            exit 0
        }
        body="$(
        _scribe_header
        echo "あなたは scribe admin(anchor)です。graph の所有者・gate funnel の実行者・唯一の bd dolt push 同期点です。"
        echo "⚠️ **以下は規約の要約(boot core)であって全文ではありません**。規約 SSOT の全文 = \`$PROTOCOL_DOC\` ——判断が要約の外へ出たら、下の trigger 表で節を選んで**この絶対 path を Read** すること(全文注入は cap で truncate されるため注入しない)。"
        echo ""
        # ultracode 打鍵リマインダ(sc-icb・source 分岐=sc-o7fz/orch-cn7s): ultracode は CC 仕様上
        # session-only(settings/env/flag で永続化不可・公式 docs verified=sc-ex2 裁定)で hook からも
        # /effort を起動できないため、人間の打鍵を促す行を admin にだけ出す(worker/consult は
        # effort 統制=sc-dc9 の管轄)。ただし「session-only」の実測境界は protocol §9 が単一 SSOT＝
        # 『/clear は ultracode を保持・respawn でのみ失われる』。source 無条件の打鍵誘導は /clear 後に
        # §9 と矛盾する誤誘導 noise になる(orch-cn7s)ため、SessionStart source で分岐する:
        #   startup        = 新規 process＝確実に off → 打鍵リマインダを出す
        #   clear          = 保持実測済(§9) → 再打鍵誘導を焼かず「保持＝再打鍵不要」の 1 行に差し替え
        #   compact        = 未実測だが同一 process 継続(clear と同型)＝保持が濃厚(deduced) → suppress
        #                    (on/off の authoritative は毎ターンの system-reminder＝§9。状態を主張しない)
        #   resume/空/未知 = resume は新規 process かつ transcript に ultracode 値が無い(§9)＝喪失濃厚
        #                    (deduced)。source 抽出不能(旧 CC・jq/sed 不発)・未知値も含め fail-safe は
        #                    「出す」側(出し損ね＝意図した ultracode の silent 喪失 > 余分な 1 行 noise)
        case "$hook_source" in
            clear)
                echo "(リマインダ) /clear は ultracode を保持します(respawn でのみ失われる・protocol §9)＝/clear を理由とする再打鍵は不要です。現在の on/off は毎ターンの system-reminder が authoritative です。"
                echo ""
                ;;
            compact)
                : ;;
            *)
                echo "(リマインダ) ultracode 運用を意図する session では、人間が「/effort ultracode」を打鍵してください(session-only 設定のため自動化・永続化は不可)。"
                echo ""
                ;;
        esac
        printf '%s\n' "$core"
        )"
        ;;
    worker)
        if [ ! -r "$PROTOCOL_DOC" ]; then
            echo "[scribe/SessionStart] warning: protocol.md 不在($PROTOCOL_DOC)・worker 文脈注入を skip(degrade)" >&2
            exit 0
        fi
        core="$(_scribe_emit_sentinel_section "$PROTOCOL_DOC" scribe-core-worker)" || {
            echo "[scribe/SessionStart] warning: boot core 区間(scribe-core-worker)を $PROTOCOL_DOC から抽出できません(begin/end が各 1 個で begin が先、を満たさない)・worker 文脈注入を skip(degrade)" >&2
            exit 0
        }
        body="$(
        _scribe_header
        echo "あなたは scribe worker(worktree セッション)です。自 issue の write だけを行い graph は触りません(B/hybrid)。bd create / bd dep / bd dolt push は禁止、follow-up は notes で提案します。"
        echo "⚠️ **以下は規約の要約(boot core)であって全文ではありません**。規約 SSOT の全文 = \`$PROTOCOL_DOC\` ——要約の外の判断が要るときは、下の trigger 表で節を選んで**この絶対 path を Read** すること。operative な手順は spawn prompt が運ぶ。"
        echo ""
        printf '%s\n' "$core"
        # 機械防御 carrier self-check（split-brain 検出・sc-99c）: scribe-spawn を経ない worker
        # （env signal 不在）には「機械防御が無効」の loud warning を注入する。SSOT=protocol.md §2。
        # ■7 (5): 本文の**後ろ**へ置く（本文は 1 byte も削らない。warning 本文自体も無改変で位置だけを
        # 移す）。**区切りの空行 1 行は warning を出すときだけ前置する**のが load-bearing——旧 §2-4 抽出は
        # 節末の空行を本文の一部として持っていたが、sentinel 区間は `$( )` が末尾改行を落とすため区切りが
        # 消える（core 末尾行に warning が直結し、実測不変条件「条件A−条件B=873 u16」も 872 へずれる）。
        # 逆に無条件に足すと、warning を出さない spawn worker 側でも body 末尾が動きうるため条件付きにする
        # （出力の有無は変数で判定＝空なら 1 行も出さない）。
        _defwarn="$(_scribe_worker_defense_warn)"
        if [ -n "$_defwarn" ]; then printf '\n%s\n' "$_defwarn"; fi
        )"
        ;;
    consult)
        if [ ! -r "$SPEC_DOC" ]; then
            echo "[scribe/SessionStart] warning: role-context-spec.md 不在($SPEC_DOC)・consult 文脈注入を skip(degrade)" >&2
            exit 0
        fi
        body="$(
        _scribe_header
        echo "あなたは scribe consult(設計議論・grill 専用の read-only セッション)です。オーケストレーション・gate 代行・実装はしません。write してよいのは記憶系(doobidoo / auto-memory)のみで、終了前のサマリ保存が義務です。以下が役割規約(role-context-spec.md §2.3)です。"
        echo "⚠️ 以下は §2.3 の全文だが規約の全体ではない。規約 SSOT = \`$SPEC_DOC\` を Read（trigger: 役割境界→§2.3 / grill 手順→protocol.md §7 / 承認の 3 クラス→protocol.md §5.4）。"
        echo ""
        _scribe_emit_consult_section "$SPEC_DOC"
        )"
        ;;
    *)
        # 到達不能（role は必ず上で確定する）。万一の保険として degrade。
        echo "[scribe/SessionStart] warning: role 判定不能・文脈注入を skip(degrade)" >&2
        exit 0
        ;;
esac

# === emit（measure-then-emit の単一出口）===
# body が空（本文抽出が空を返した等）なら無出力＝warn も出さない（■7・既存の「出力ゼロ」assert 群を守る）。
scribe_emit_with_budget "$body" "SessionStart role=$role"

exit 0

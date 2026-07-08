#!/usr/bin/env bash
# scribe-spawn.sh — worker を spawn（1 issue = 1 worktree = 1 window）、または consult セッションを起動する道具。
#
# admin の手作業（docs/protocol.md §1 spawn 規約 / §2 worker prompt 規約）を 1 コマンド化する。
# **道具は規約をコード化するだけ**。命名・起動・禁止事項の SSOT は docs/protocol.md。
#
# === worker モード（既定）流れ（protocol.md §1）===
#   1. bd id 必須 → `bd show <id>` で実在を事前検証（fail-loud = un-cbi 引き継ぎ。
#      cld-spawn は非空で不正な --bd-id を警告なく旧命名へ silent fallback するため上流で塞ぐ）
#   2. git worktree add（spawn/<id>-HHMMSS・<repo>/.worktrees/ 配下）
#   3. task prompt 生成（契約 = bd description 参照 / cell-quality WF 起動 / bdw 規律 / 禁止事項）
#   4. cld-spawn --bd-id <id> --model opus（window 名は cld-spawn が wt-<id> を採用）
#   5. monitor 生成 + 起動（tmux 参照は window ID @N = dotted bd id の -t 構文衝突回避）
#
# === consult モード（--consult）流れ（docs/role-context-spec.md §2.3 / §2.1 §2.3・design §14 line348）===
#   consult は **anchor 同居・read-only セッション**（設計議論・grill 専用）。worker とは別系統で、
#   worktree 仕事・実装・bd write をしない（design §14 は consult に対し worktree spawn を禁止）。
#   よって consult モードでは:
#     - **worktree を作らない / worker prompt を出さない / --bd-id を渡さない**（role 契約遵守）。
#       `--cd` は anchor（cwd）を指す＝worktree ではない（consult は anchor 同居）。
#     - anchor（cwd）で `cld-spawn --model <fable 既定・不可時 opus> --env-file <SCRIBE_ROLE=consult> "<consult テンプレ本文>"`。
#       consult テンプレは read-only 規律・記憶系のみ write・サマリ保存義務のみ（bdw/selftest/cell-quality を含まない）。
#     - SCRIBE_ROLE=consult を --env-file で注入（C2 の role 判定が最優先で読む side）。env-file は
#       **anchor working tree の外**（/tmp）に作り spawn 後に rm する＝anchor リポを汚さない（read-only 起動器の自浄）。
#     - model は既定 fable・利用不可時のみ opus へ loud fallback（sc-9q6・role-context-spec §2.3。--model 明示が優先・worker は fable 厳禁）。
#   bd id は consult では **任意の議題参照**（read-only な `bd show` のみ・worktree/branch には焼かない）。
#
# 既知バグ防御（un-ivb・別セル）: 現行 cld-spawn は未知オプションを PROMPT に落とす。
#   → 本ヘルパーは **正しい引数のみ** を cld-spawn に渡す設計で防御する。
#
# Usage:
#   scribe-spawn.sh [options] <bd-id>          # worker モード
#   scribe-spawn.sh --consult [options] [<bd-id>]   # consult モード（worktree/worker prompt なし）
# Options:
#   --repo PATH     worktree を作る git リポジトリ（worker のみ・既定: cwd）
#   --base REF      新 branch の base（worker のみ・既定: HEAD）
#   --anchor PATH   bd graph の所在（bd show 用・既定: cwd）。consult はここで起動する
#   --account LABEL worker/consult を起動する Claude アカウント（config dir 追随・sc-rvq）。LABEL → <accounts-base>/<label>
#                   の規約導出（accounts-base 既定=$HOME/.claude-accounts・un-h289）。省略時は admin の CLAUDE_CONFIG_DIR を
#                   mirror（未設定なら ~/.claude 既定）。解決優先順位: --account > SCRIBE_WORKER_CONFIG_DIR env > admin env mirror。
#   --consult       consult role セッションを anchor で起動（worktree/worker prompt なし・SCRIBE_ROLE=consult を --env-file 注入）
#   --context FILE  consult 専用。admin 集約 brief（FILE 内容）を grill 材料として焼き込み grill-consult モードへ。
#                   §7 needs-user regime: grill-issue id 必須。grill-consult は brief を出発点にユーザーと対話 grill し、
#                   決定を own grill-issue の bd notes へ書く（bdw 経由 --claim/--append-notes のみ・read-only 限定緩和）。
#                   （pre-bake 自体は admin が回す dynamic Workflow = workflows/needs-user-prebake.workflow.js へ移管。）
#   --model MODEL   cld-spawn のモデル（既定: worker=opus / consult=fable）。worker は fable 厳禁＝コスト爆発。
#                   consult は既定 fable・利用不可時のみ opus へ loud fallback（sc-9q6・role-context-spec §2.3）
#   --effort LEVEL  worker の実効 effort（既定 high・env SCRIBE_WORKER_EFFORT で既定上書き・allowlist low|medium|high|xhigh|max）。
#                   settings.json の "effortLevel":"xhigh" 無差別波及を止め、CC 正規名 CLAUDE_CODE_EFFORT_LEVEL を
#                   worker env-file へ後勝ち注入する（CLAUDE_EFFORT は CC 非正規名＝silent no-op ゆえ使わない・sc-dc9）。
#                   consult は effort 管轄外（role-context-spec §2.3・main-loop 系統）ゆえ worker のみに効く。
#   --dry-run       実行するはずのコマンド列を arg-echo するだけ（実 spawn しない）
#   -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

# cld-spawn の所在（テスト時は SCRIBE_CLD_SPAWN でスタブ差し替え）。
CLD_SPAWN="${SCRIBE_CLD_SPAWN:-$HOME/.claude/plugins/session/scripts/cld-spawn}"
# sandbox settings 生成器の所在（テスト時は SCRIBE_SANDBOX_GEN でスタブ差し替え＝gen 失敗注入用。
# 既定は本番ヘルパ＝sandbox 時の挙動 byte 不変。CLD_SPAWN と同型の testability seam）。
SANDBOX_GEN="${SCRIBE_SANDBOX_GEN:-$SCRIPT_DIR/sandbox-spike/gen-sandbox-settings.sh}"
# sandbox dep-preflight 道具の所在（テスト時は SCRIBE_SANDBOX_PREFLIGHT でスタブ差し替え＝deps 欠如注入用。
# 既定は本番ヘルパ。CLD_SPAWN / SANDBOX_GEN と同型の testability seam。sc-u53 default-on の安全弁＝
# deps 欠如 host で worker を sandbox 化できないとき fail-loud / fallback を決める検査の入口）。
SANDBOX_PREFLIGHT="${SCRIBE_SANDBOX_PREFLIGHT:-$SCRIPT_DIR/scribe-sandbox-preflight.sh}"
# grill-me SKILL.md の所在（grill-consult が grill 方法論を verbatim 注入する元・テスト時は SCRIBE_GRILL_SKILL で差し替え）。
# sc-swc: grill-consult は grill-me を paraphrase せず本スキル本文をそのまま焼き込む（mechanism b＝drift しない・劣化再実装を撤去）。
GRILL_SKILL="${SCRIBE_GRILL_SKILL:-$HOME/.claude/skills/grill-me/SKILL.md}"
# worker cell へ物理封鎖する対話 tool（orch-4dm / H5・user ratified 機構チェーン orch-z7g ④）。worker cell は
# 無人 window（human is not attending）ゆえ、admin 監視下で対話 UI を出しても誰も答えられず window が固まり
# bead-truth poll から不可視になる。worker prompt の prose ban（build_prompt「人間の確認を待って停止するな」）に
# 加え、claude 起動フラグとして物理封鎖する（H5・prose 層と二重化）。cld-spawn 側 passthrough は cc-session
# PR#32 で land 済（DISALLOWED_TOOLS+=("$2") ＝分割せず 1 要素蓄積）。**この値は 1 argv verbatim で cld-spawn へ
# 渡す**（cc-session gate round-1 で分割 fail-open が CONFIRMED＝claude は括弧認識で自分で split するので、
# こちら側で空白/カンマ split すると内部空白 spec が壊れ silent fail-open する）。consult は有人 grill が本務ゆえ
# 対象外（worker cell 起動行のみに付与）。
WORKER_DISALLOWED_TOOLS="AskUserQuestion,ExitPlanMode"

usage() {
  cat <<'EOF'
Usage:
  scribe-spawn.sh [options] <bd-id>              # worker モード
  scribe-spawn.sh --consult [options] [<bd-id>]  # consult モード（worktree/worker prompt なし）
  scribe-spawn.sh --consult --context FILE <bd-id>  # grill-consult モード（§7 needs-user regime・brief を grill）
Options:
  --repo PATH     worktree を作る git リポジトリ（worker のみ・既定: cwd）
  --base REF      新 branch の base（worker のみ・既定: HEAD）
  --anchor PATH   bd graph の所在（bd show 用・既定: cwd）。consult はここで起動する
  --account LABEL worker/consult を起動する Claude アカウント（config dir 追随・sc-rvq）。LABEL → <accounts-base>/<label>
                  の規約導出（既定 accounts-base=$HOME/.claude-accounts）。省略時は admin の CLAUDE_CONFIG_DIR を mirror
                  （未設定=~/.claude 既定）。優先順位: --account > SCRIBE_WORKER_CONFIG_DIR env > admin env mirror
  --account auto  claude-usage 残量ベース maximin で最も空いているアカウントを自動選択（sc-1rq・opt-in）。
                  適格=usage(ok∧非stale)+preflight(login/onboarding/plugin) の lazy 交差。API故障=主アカ fallback・
                  適格0件=fail-loud。default が選ばれたら ~/.claude(unset)へ写像。--bd-id ある spawn は選定 snapshot を
                  issue notes へ自動追記（接頭辞 account-select:）。dry-run で選定予定ランキングを可視化。
  --consult       consult role セッションを anchor で起動（worktree/worker prompt なし）
  --context FILE  consult 専用。admin 集約 brief（FILE）を grill 材料として焼き込み grill-consult モードへ（§7・grill-issue id 必須）。
                  grill-consult は brief を grill し決定を own grill-issue の bd notes へ書く（bdw 経由・read-only 限定緩和）
  --model MODEL   cld-spawn のモデル（既定: worker=opus / consult=fable）。worker は fable 厳禁＝コスト爆発。
                  consult は既定 fable・利用不可時のみ opus へ loud fallback（sc-9q6・role-context-spec §2.3）
  --effort LEVEL  worker の実効 effort（既定 high・env SCRIBE_WORKER_EFFORT で既定上書き・allowlist low|medium|high|xhigh|max・worker のみ）
  --dry-run       実行するはずのコマンド列を arg-echo するだけ（実 spawn しない）
  -h | --help
EOF
  exit "${1:-0}"
}

REPO="$(pwd)"
BASE="HEAD"
ANCHOR="$(pwd)"
CONSULT=0
MODEL="opus"       # worker 既定。consult は --model 未指定なら fable 既定へ解決する（sc-9q6・consult 分岐冒頭）
MODEL_EXPLICIT=0   # --model 明示の有無（明示は consult の fable 既定より常に優先）
# worker 実効 effort（sc-dc9）。既定 high（settings.json の xhigh 無差別波及を止める＝この issue の核）。
# env SCRIBE_WORKER_EFFORT が既定を上書きし、--effort フラグがさらに上書きする（flag > env > 既定 high）。
# allowlist 検証は worker 分岐入口（effort を実際に使う経路）で fail-loud。consult は effort を使わない。
EFFORT="${SCRIBE_WORKER_EFFORT:-high}"
EFFORT_EXPLICIT=0  # --effort 明示の有無（監査・dry-run 表示用）
# --account: worker/consult を起動する Claude アカウントのラベル（config dir 追随・sc-rvq）。空=未指定。
# label → <accounts-base>/<label> の規約導出（un-h289・uns が安定 interface として保証）。CLAUDE_CONFIG_DIR
# mirror の既定動作より優先（解決順位は下記 config-dir 解決ブロック参照）。
ACCOUNT=""
DRY_RUN=0
BD_ID=""
# --context: admin 集約 brief をファイルから consult prompt へ焼き込み grill-consult モードへ切替える
# （§7 needs-user regime・sc-cuw 再編）。consult 専用・空なら従来の素 consult。
# 意味の変化: 旧「焼いて死ぬ pre-bake」→ 新「brief を grill 材料に受け取りユーザーと対話 grill する grill-consult」
# （pre-bake 自体は admin が回す dynamic Workflow = workflows/needs-user-prebake.workflow.js へ移管）。
CONTEXT_FILE=""
# REPO/ANCHOR が「既定（cwd）」か「明示指定」かを独立に追う（un-ag7・AC3/AC4）。
# 明示時は linked-worktree ガードを不発火にし、cross-repo cell の意図的 override を壊さない。
REPO_EXPLICIT=0
ANCHOR_EXPLICIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    scribe_need_val "${2:-}" --repo; REPO="$2"; REPO_EXPLICIT=1; shift 2 ;;
    --base)    scribe_need_val "${2:-}" --base; BASE="$2"; shift 2 ;;
    --anchor)  scribe_need_val "${2:-}" --anchor; ANCHOR="$2"; ANCHOR_EXPLICIT=1; shift 2 ;;
    --account) scribe_need_val "${2:-}" --account; ACCOUNT="$2"; shift 2 ;;
    --consult) CONSULT=1; shift ;;
    --context) scribe_need_val "${2:-}" --context; CONTEXT_FILE="$2"; shift 2 ;;
    --model)   scribe_need_val "${2:-}" --model; MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
    --effort)  scribe_need_val "${2:-}" --effort; EFFORT="$2"; EFFORT_EXPLICIT=1; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) scribe_die "未知のオプション: $1（cld-spawn の PROMPT 落下バグを避けるため拒否する）" ;;
    *)  [[ -z "$BD_ID" ]] || scribe_die "bd id は 1 つだけ指定してください（既指定: $BD_ID, 追加: $1）"; BD_ID="$1"; shift ;;
  esac
done
# `--` で break した残り（あれば bd id として採用）
if [[ -z "$BD_ID" && $# -gt 0 ]]; then BD_ID="$1"; fi

# --- ANCHOR を絶対パスへ正規化（un-gjr）---
# anchor（bd graph 所在）は worker/consult 双方の経路で使う: worker は build_prompt が
# \`cd "$ANCHOR" && bd show / bdw\` として **prompt に焼き込み**、consult は cld-spawn を
# \`--cd "$ANCHOR"\`（cwd=anchor 同居起動）に渡す。worker の cwd は **worktree** であり
# spawn 起動時の相対パスは worker から解決できないため、両経路で使う前に絶対パスへ正規化する。
# 存在しなければ fail-loud で bd graph 所在の typo を上流で塞ぐ（誤った anchor は下流の
# scribe_bd_id_exists で cd 失敗→短絡し「issue 不在」という誤診断に化けるため、ここで先に
# 明確なエラーへ倒す）。
ANCHOR="$(cd "$ANCHOR" 2>/dev/null && pwd)" \
  || scribe_die "--anchor のパスが存在しません（bd graph 所在を絶対パスで解決できない）"

# --- AC1: 既定 anchor が linked（副）worktree のとき fail-loud（un-ag7）---
# `--anchor` 未指定（= cwd 既定）で cwd が副 worktree のとき、bd graph は main worktree 側にあり、
# 副 worktree を anchor にすると `bd show`/`bdw` の解決が破綻する（誤診断「issue 不在」に化ける）。
# worktree 作成・worker prompt・consult 起動・--dry-run の plan いずれの前にもここで停止する（AC5）。
# consult/worker 双方の経路へ効くよう **両分岐の手前**（ANCHOR 正規化直後）に置く（AC1）。
# 明示 `--anchor` 時は cross-repo cell の意図的 override を壊さないため不発火（AC3）。
# 検出は git plumbing（main worktree と show-toplevel の差分）— naming 規約に依存しない（AC4）。
if [[ "$ANCHOR_EXPLICIT" -eq 0 ]] && _anchor_main="$(scribe_linked_worktree_main "$ANCHOR")"; then
  scribe_die "既定 anchor が linked worktree です: $ANCHOR
  bd graph は main worktree 側にあり、副 worktree を anchor にすると bd 参照解決に失敗します。
  真の anchor（main worktree）: $_anchor_main
  → そこへ cd するか、--anchor '$_anchor_main' を明示してください。"
fi

# --- --context は consult 専用（grill-consult は consult role 機構・worker は grill-consult しない）---
# worker 分岐は consult 分岐の後に来るため、ここで先に弾かないと worker 経路へ --context が漏れる。
if [[ -n "$CONTEXT_FILE" && "$CONSULT" -eq 0 ]]; then
  scribe_die "--context は consult モード(--consult)専用です（grill-consult は consult role 機構・§7 / role-context-spec §2.3）"
fi

# ===========================================================================
# CLAUDE_CONFIG_DIR 追随（sc-rvq・マルチアカウント）: worker/consult を admin と同一アカウントで起こす。
# ===========================================================================
# tmux new-window は env を剥がすため、admin が CLAUDE_CONFIG_DIR set で走っていても spawn 子は既定 ~/.claude へ
# 落ち別アカウント化する（切替直後の spawn worker が初回オンボーディング〔theme→sign-in〕で停止する実事故・
# doobidoo 82e2fc50）。ゆえに admin process env（=この script の env）の CLAUDE_CONFIG_DIR を worker/consult の
# env-file へ mirror 注入する。cc-session/cld は systemd-run --user --scope の env 継承で無改修成立するが、env-file は
# tmux env 剥ぎ後に launcher が source する唯一の確実な伝播口ゆえ、ここで明示注入する（worker/consult 共通）。
#
# 解決優先順位（NOTES 2026-07-07）: --account 明示 > SCRIBE_WORKER_CONFIG_DIR env > admin env の mirror > 既定 unset。
#   - --account <label> → <accounts-base>/<label> の規約導出（uns が安定 interface として保証・un-h289。台帳
#     claude-accounts.txt の読取りは不要）。accounts-base 既定=$HOME/.claude-accounts（テスト seam=SCRIBE_ACCOUNTS_BASE）。
#   - SCRIBE_WORKER_CONFIG_DIR env（override 口・検証=dir 実在は下記 preflight が担う）。
#   - どれも無ければ admin env の CLAUDE_CONFIG_DIR を mirror（cla default の「unset=~/.claude」意味論を保つ）。
#   - 全て無し = CLAUDE_CONFIG_DIR 非設定（=env-file に `unset` を注入）。unset は worker が chain-source する
#     ~/.cld-env からの CLAUDE_CONFIG_DIR 混入に対する fail-closed 防御（後勝ちで打ち消す）。
ACCOUNTS_BASE="${SCRIBE_ACCOUNTS_BASE:-$HOME/.claude-accounts}"
WCFG_DIR=""       # 注入予定 config dir（空=unset を注入＝既定 ~/.claude）
WCFG_SOURCE=""    # 解決元（account|env|mirror|unset|auto:<label>|auto-fallback|auto-fallback-mirror）— dry-run 表示・監査用
# --account auto（sc-1rq・facet①=明示 opt-in）: claude-usage 残量ベース maximin で config dir を自動選択する。
# 特別ラベル "auto" は <accounts-base>/auto という実在しない dir へ導出してはならないため、通常ラベル分岐より
# 前に intercept する。実解決（selector 実行 + preflight lazy walk）は probe_config_dir/SCRIPT_DIR が要るため
# 関数定義後の resolve_account_auto() へ委ねる（ここでは AUTO=1 のマークのみ）。
AUTO=0
if [[ "$ACCOUNT" == "auto" ]]; then
  AUTO=1
  WCFG_SOURCE="auto"   # 実解決は下記 resolve_account_auto() で確定（selector + lazy walk）
elif [[ -n "$ACCOUNT" ]]; then
  # label は path 導出に使うため sanitize（path traversal を上流で拒否・bd id 検証と同姿勢）。
  case "$ACCOUNT" in
    *[!A-Za-z0-9._-]*) scribe_die "--account のラベルに使えない文字が含まれます: '$ACCOUNT'（許可: 英数 . _ -）" ;;
    .|..)              scribe_die "--account のラベルが不正です: '$ACCOUNT'（path traversal を拒否）" ;;
  esac
  WCFG_DIR="$ACCOUNTS_BASE/$ACCOUNT"
  WCFG_SOURCE="account"
elif [[ -n "${SCRIBE_WORKER_CONFIG_DIR:-}" ]]; then
  WCFG_DIR="$SCRIBE_WORKER_CONFIG_DIR"
  WCFG_SOURCE="env"
elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  WCFG_DIR="$CLAUDE_CONFIG_DIR"
  WCFG_SOURCE="mirror"
else
  WCFG_SOURCE="unset"
fi

# worker/consult env-file へ焼く CLAUDE_CONFIG_DIR 行を 1 箇所で組む（両経路で drift させない）。
#   set   → export（%q で source-safe・chain-source の後に置き後勝ち）。export 必須（bare 代入は launcher の子へ非継承）。
#   unset → `unset CLAUDE_CONFIG_DIR`（chain-source 混入への fail-closed・cla default の unset 意味論と一致）。
emit_config_dir_envline() {
  if [[ -n "$WCFG_DIR" ]]; then
    printf 'export CLAUDE_CONFIG_DIR=%q\n' "$WCFG_DIR"
  else
    printf 'unset CLAUDE_CONFIG_DIR\n'
  fi
}

# dry-run 用: 注入する CLAUDE_CONFIG_DIR 行の人間可読サマリ（worker/consult 共有・監査可視化）。
config_dir_plan_line() {
  if [[ -n "$WCFG_DIR" ]]; then
    echo "[plan] config-dir 追随（sc-rvq・源=$WCFG_SOURCE）: env-file に export CLAUDE_CONFIG_DIR=$WCFG_DIR を後勝ち注入（実起動時に preflight: credentials/onboarding/plugin enable を fail-loud 検査）"
  else
    echo "[plan] config-dir 追随（sc-rvq）: admin env に CLAUDE_CONFIG_DIR 無し → env-file に unset CLAUDE_CONFIG_DIR を注入（既定 ~/.claude・~/.cld-env 混入への fail-closed）"
  fi
}

# spawn preflight（fail-loud・sc-rvq 実装3）: 注入予定 config dir が set のとき、その dir が worker/consult を
# 安全に起こせるかを検査する。欠落を黙って既定 ~/.claude へ fallback させない（AC3）。**実起動時のみ**呼ぶ
# （dry-run は side-effect ゼロ＝fable preflight / sandbox dep-preflight と同じ real-path-only 規律）。unset（既定
# ~/.claude）は挙動不変ゆえ検査しない（AC1）。理由（c）= hooks は ${CLAUDE_PLUGIN_ROOT}（=アクティブ config dir
# 配下 plugin）から発火するため、plugin 欠落 dir で worker を起こすと edit-write-guard（SBX-ESC-1 境界）/
# bd-write-guard / git-destructive-guard / session-start-role-inject が全て黙って無効化される（無防備 worker を
# 黙って起こさない）。
# 単一の config dir が worker/consult を安全に起こせるかを検査する **非致命** probe（sc-1rq で抽出）。
# 引数 $1=dir $2=source。合格なら 0 を返す（無出力）。不合格なら理由を stdout へ echo し 1 を返す
# （die しない）。この probe を 2 者が共有する: (1) preflight_config_dir（globals 上で die 版・既存挙動）と
# (2) --account auto の lazy walk（候補を非致命に試す・sc-1rq facet②）。検査本体を 1 箇所へ集約し drift を防ぐ。
# 検査は fs 読取りのみ（-d/-f/jq read/grep）＝side-effect ゼロ（dry-run でも安全）。
probe_config_dir() {
  local _d="$1" _src="$2"
  [[ -n "$_d" ]] || return 0
  [[ -d "$_d" ]] \
    || { echo "spawn preflight: 注入予定 config dir が存在しません（源=$_src）: $_d（黙って既定 ~/.claude へ fallback しない・sc-rvq）"; return 1; }
  # (a) credentials: 未 login dir は claude 起動が sign-in オンボーディングで停止する（doobidoo 82e2fc50）。
  [[ -f "$_d/.credentials.json" ]] \
    || { echo "spawn preflight: $_d/.credentials.json が無い＝未 login config dir（claude 起動が sign-in で停止・sc-rvq）。当該アカウントで一度 login してください。"; return 1; }
  # (b) onboarding 完了: hasCompletedOnboarding=true（theme 選択ハング=doobidoo 82e2fc50）。jq があれば厳密判定、
  #     無ければ grep フォールバック（この経路は sandbox gen 前で jq 保証が無いため defensive に両対応）。
  local _cj="$_d/.claude.json"
  [[ -f "$_cj" ]] \
    || { echo "spawn preflight: $_cj が無い＝オンボーディング未完了 config dir（claude 起動が停止・sc-rvq）。"; return 1; }
  if command -v jq >/dev/null 2>&1; then
    jq -e '.hasCompletedOnboarding == true' "$_cj" >/dev/null 2>&1 \
      || { echo "spawn preflight: $_cj の hasCompletedOnboarding が true でない＝オンボーディング未完了（theme 選択→sign-in で停止・doobidoo 82e2fc50・sc-rvq）。"; return 1; }
  else
    grep -Eq '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$_cj" \
      || { echo "spawn preflight: $_cj の hasCompletedOnboarding が true でない（jq 不在の grep 判定・sc-rvq）。"; return 1; }
  fi
  # (c) scribe(+beads-bdw+cmdtokens) plugin が当該 config dir で enable（=<dir>/plugins/<name> 実在。local dev
  #     plugin は symlink 存在が enable シグナル・settings.json の enabledPlugins には載らない＝実測）。dangling
  #     symlink は -e が偽になる＝真に不在扱い（意図どおり）。
  local _p
  for _p in scribe beads-bdw cmdtokens; do
    [[ -e "$_d/plugins/$_p" ]] \
      || { echo "spawn preflight: plugin '$_p' が config dir で enable されていません（$_d/plugins/$_p 不在・源=$_src）。plugin 欠落 dir で worker を起こすと edit-write-guard/bd-write-guard/git-destructive-guard/session-start-role-inject が黙って無効化されます（無防備 worker を黙って起こさない・sc-rvq）。"; return 1; }
  done
  return 0
}

preflight_config_dir() {
  [[ -n "$WCFG_DIR" ]] || return 0
  local _r
  _r="$(probe_config_dir "$WCFG_DIR" "$WCFG_SOURCE")" || scribe_die "$_r"
}

# ===========================================================================
# --account auto の実解決（sc-1rq・facet①〜⑥⑧ の統合点）。IMPLEMENTATION CONTRACT 2026-07-08 準拠。
# ===========================================================================
# selector（scripts/scribe-account-select・純粋計算・fs 非接触）を実行して claude-usage 残量 maximin の
# ランキング TSV を得、適格候補を残量降順に preflight lazy walk して最初に通った候補を採用する
# （facet② の usage∧preflight を lazy 交差で実現・preflight 実装は 1 箇所のまま）。
#   ・API 故障（selector exit 3）→ loud-warn + 主アカ(default=~/.claude・unset)へ fallback（spawn は成立・facet⑤①）。
#   ・usage 側で適格 0 件（selector が eligible 0 行）→ fail-loud（不適格と分かって主アカで起こさない・facet⑤②）。
#   ・適格はあるが preflight 全滅 → fail-loud（login/onboarding/plugin 欠落・facet⑤②）。
#   ・default が選ばれたら ~/.claude（unset 意味論）へ写像（facet④）。preflight は ~/.claude に対しても一様に実施。
#   ・dry-run は fs preflight walk を行わず top-by-usage を表示用に採用（実起動時のみ preflight・side-effect 規律）。
AUTO_TSV=""       # selector の生 TSV（監査 note / dry-run plan 用）
AUTO_CHOSEN=""    # 採用 label（監査用）
AUTO_FALLBACK=0   # API 故障 fallback を踏んだか（監査用）
resolve_account_auto() {
  # selector の exit code（特に API 故障=3）を set -e に殺されず捕捉する。plain 代入 `x=$(cmd)` は
  # cmd 失敗で set -e が発火し `; _rc=$?` に到達しないため、`|| _rc=$?` で左辺化して抑止する（sc-1rq）。
  local _tsv _rc=0
  _tsv="$("$SCRIPT_DIR/scribe-account-select")" || _rc=$?
  AUTO_TSV="$_tsv"
  if [[ "$_rc" -eq 3 ]]; then
    # facet⑤①: API 故障 → 主アカウント（=admin 自身の稼働アカウント）へ fallback。plain 経路（--account 未指定時の
    # mirror-then-unset・227-231）と同一規約で解決する（sc-1rq finding1）: admin が CLAUDE_CONFIG_DIR を持てば
    # それを mirror（WCFG_DIR 非空）、無ければ unset（~/.claude）。~/.claude ハードコードは admin が ~/.claude 稼働の
    # ときだけ正しく、black4 等の非 ~/.claude admin では preflight_config_dir が空を無検査 skip するため guard 欠落 dir
    # （login/onboarding/scribe・beads-bdw・cmdtokens 欠落＝各 guard 無効化）に無防備 worker を起こす fail-open だった。
    # mirror で WCFG_DIR を非空にすれば呼出元の preflight_config_dir が採用 dir の実在を一様検査する（guard 欠落なら
    # loud-fail・sc-rvq の不変条件を fallback でも保つ）。
    AUTO_FALLBACK=1
    if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
      WCFG_DIR="$CLAUDE_CONFIG_DIR"; WCFG_SOURCE="auto-fallback-mirror"
      echo "scribe: ⚠ --account auto: claude-usage が読めません（API 故障）→ 主アカウント（admin 稼働 config dir を mirror=$WCFG_DIR）へ fallback します（この spawn は成立・採用 dir を preflight で一様検査・facet⑤①・sc-1rq）。" >&2
    else
      WCFG_DIR=""; WCFG_SOURCE="auto-fallback"
      echo "scribe: ⚠ --account auto: claude-usage が読めません（API 故障）→ 主アカウント（~/.claude・unset 経路）へ fallback します（この spawn は成立・facet⑤①・sc-1rq）。" >&2
    fi
    return 0
  fi
  [[ "$_rc" -eq 0 ]] || scribe_die "--account auto: selector が想定外 exit（$_rc）で失敗しました（sc-1rq）"
  local _labels
  _labels="$(awk -F'\t' '$2=="1"{print $1}' <<<"$_tsv")"
  if [[ -z "$_labels" ]]; then
    if [[ "$DRY_RUN" -eq 1 ]]; then
      WCFG_DIR=""; WCFG_SOURCE="auto(適格0件・実起動時 fail-loud)"; return 0
    fi
    scribe_die "--account auto: claude-usage 上で適格アカウントが 0 件でした（ok∧非stale を満たすアカウント無し・facet⑤②・sc-1rq）。全アカウントが認証切れ/劣化しています。"
  fi
  local _label _probe_dir _inject_dir _reason
  while IFS= read -r _label; do
    [[ -n "$_label" ]] || continue
    # facet④: default は ~/.claude（unset 意味論）へ写像。preflight は ~/.claude へ一様に実施し、採用時の注入は
    # unset（WCFG_DIR=""）にする。他ラベルは <accounts-base>/<label>。
    if [[ "$_label" == "default" ]]; then
      _probe_dir="$HOME/.claude"; _inject_dir=""
    else
      _probe_dir="$ACCOUNTS_BASE/$_label"; _inject_dir="$_probe_dir"
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
      # dry-run は fs preflight walk を行わない（実起動時のみ）。top-by-usage を表示用に採用する。
      WCFG_DIR="$_inject_dir"; WCFG_SOURCE="auto(dry-run:top-by-usage=$_label・実起動時に preflight walk)"
      AUTO_CHOSEN="$_label"; return 0
    fi
    if _reason="$(probe_config_dir "$_probe_dir" "auto:$_label")"; then
      WCFG_DIR="$_inject_dir"; WCFG_SOURCE="auto:$_label"; AUTO_CHOSEN="$_label"
      echo "scribe: --account auto: '$_label' を採用（残量 maximin 上位で preflight 通過・源=$WCFG_SOURCE・sc-1rq）" >&2
      return 0
    fi
    echo "scribe: --account auto: 候補 '$_label'（残量上位）は preflight 不通過で skip: ${_reason%%$'\n'*}" >&2
  done <<<"$_labels"
  scribe_die "--account auto: 残量上位の適格候補が preflight を全て不通過でした（usage は適格だが login/onboarding/plugin が欠落・facet⑤②・sc-1rq）。候補: $(tr '\n' ' ' <<<"$_labels")"
}

# facet⑥ 監査: --account auto の選定 snapshot を安定接頭辞 account-select: の機械可読ブロックへ整形する
# （後で横断 grep 集計し maximin 見直し材料に）。候補全員（適格+除外）を tab→'|'・空→'-' で列挙する。
format_account_select_snapshot() {
  local _chosen="${AUTO_CHOSEN:-none}"
  local _fb="no"
  if [[ "$AUTO_FALLBACK" -eq 1 ]]; then
    _fb="yes"
    # fallback 採用 dir を監査に正確に映す（sc-1rq finding1）: mirror なら admin 稼働 dir、unset なら ~/.claude。
    if [[ "$WCFG_SOURCE" == "auto-fallback-mirror" ]]; then
      _chosen="FALLBACK:mirror($WCFG_DIR)"
    else
      _chosen="FALLBACK:default(~/.claude)"
    fi
  fi
  printf 'account-select: chosen=%s fallback=%s method=maximin(残量%%=100-pct・積極解釈) source=%s\n' \
    "$_chosen" "$_fb" "$WCFG_SOURCE"
  printf 'account-select: cols=label|eligible|score|h5|h7|pct5|pct7|resets5|resets7|reason\n'
  if [[ -n "$AUTO_TSV" ]]; then
    awk -F'\t' '{ for(i=1;i<=10;i++){ f=$i; if(f=="") f="-"; printf "%s%s", (i>1?"|":"account-select:   "), f } print "" }' <<<"$AUTO_TSV"
  else
    printf 'account-select:   (selector 出力なし＝API故障 fallback)\n'
  fi
}

# facet⑥ 監査（実起動時）: --bd-id ある spawn のみ該当 issue notes へ snapshot を自動追記（bdw 経由・best-effort）。
# --bd-id 無い spawn（素 consult 等）は notes 書き先が無いため stderr 表示のみ。
emit_account_select_note() {
  local _snap; _snap="$(format_account_select_snapshot)"
  local _nid; _nid="$(scribe_normalize_bd_id "$BD_ID" 2>/dev/null || true)"
  if [[ -z "$_nid" ]]; then
    { echo "scribe: account-select 監査（--bd-id 無し→ notes 書き先なし・表示のみ）:"; echo "$_snap"; } >&2
    return 0
  fi
  ( cd "$ANCHOR" && "$SCRIPT_DIR/bdw" update "$_nid" --append-notes "$_snap" ) >/dev/null 2>&1 \
    || echo "scribe: warn: account-select 監査 note の追記に失敗（bdw・best-effort・spawn は継続）: $_nid" >&2
}

# facet⑥ 監査（dry-run）: 選定予定を plan 行で可視化する（候補ランキング + 選定結果）。
account_select_plan() {
  echo "[plan] --account auto（sc-1rq・facet①=opt-in）: claude-usage 残量 maximin 自動選択（残量%=100-pct・積極解釈・resets_at null/過去=満残量）"
  if [[ "$AUTO_FALLBACK" -eq 1 ]]; then
    if [[ "$WCFG_SOURCE" == "auto-fallback-mirror" ]]; then
      echo "[plan]   selector=API故障 → 主アカ（admin 稼働 config dir を mirror=$WCFG_DIR）へ fallback（採用 dir を preflight で一様検査・facet⑤①）"
    else
      echo "[plan]   selector=API故障 → 主アカ(~/.claude・unset)へ fallback（実起動でも fallback・facet⑤①）"
    fi
  elif [[ -n "$AUTO_TSV" ]]; then
    echo "[plan]   selector ランキング（上位=残量最大・el=適格1/0・min=maximin score）:"
    awk -F'\t' '{printf "[plan]     %s\tel=%s\tmin=%s\th5=%s\th7=%s\t%s\n",$1,$2,($3==""?"-":$3),($4==""?"-":$4),($5==""?"-":$5),$10}' <<<"$AUTO_TSV"
    echo "[plan]   選定予定（top-by-usage）=${AUTO_CHOSEN:-none}（実起動時に上位から preflight lazy walk・facet②）"
  else
    echo "[plan]   selector=適格0件 → 実起動時に fail-loud（facet⑤②）"
  fi
}

# --account auto の解決を関数定義後・分岐前に実行する（worker/consult 両経路が resolved WCFG を共有）。
# dry-run でも selector を回してランキングを plan へ出す（read-only usage 読取り）。実起動時は preflight lazy
# walk + 監査 note まで行う。
if [[ "$AUTO" -eq 1 ]]; then
  resolve_account_auto
  [[ "$DRY_RUN" -eq 0 ]] && emit_account_select_note
fi

# fable の許否は role で非対称（道具は規約を変えない）:
#   - worker: fable 厳禁（protocol.md §1: worker は opus 必須＝コスト爆発防止）。worker 分岐内で die する。
#   - consult: fable は **既定**（sc-9q6: 既定 fable・利用不可時のみ opus へ loud fallback・--model 明示は常に優先。
#     consult は admin と同じ main-loop 系統ゆえ fable 起動が許される唯一の役割＝role-context-spec §2.3）。
# ＝この一括 die をここに置くと consult の例外パスを塞いで規約を変えてしまうため、
#   worker 分岐の入口へ移動する（下記）。

# ===========================================================================
# consult モード（--consult）: role-context-spec §2.3 / design §14 の契約どおりに分岐。
#   worktree 作成・worker prompt 生成・--bd-id を **一切しない**（consult に spawn worktree は禁止）。
#   anchor で `cld-spawn --cd <anchor> --model <fable 既定・不可時 opus> --env-file <SCRIBE_ROLE=consult> "<consult テンプレ>"` を出す
#   （--cd は anchor=cwd を指す＝worktree ではない）。
#   bd id は consult では任意の議題参照（read-only な実在検証のみ・worktree/branch には焼かない）。
# ===========================================================================
if [[ "$CONSULT" -eq 1 ]]; then
  # --- consult 既定 model = fable（sc-9q6・2026-07-03 ユーザー確定）---
  # --model 明示は常に優先（MODEL_EXPLICIT）。未指定なら fable を既定にし、fable が利用できない
  # （API/アクセス障害）ときだけ opus へ **loud** fallback する（silent 降格しない）。
  # preflight は実起動時のみ（dry-run は API を叩かない＝dry-run の副作用ゼロを維持）。
  # SCRIBE_FABLE_PREFLIGHT=1/0 で可否を強制注入できる（テスト・緊急時の seam。未設定=実測）。
  CONSULT_FABLE_MODEL="claude-fable-5"
  fable_available() {
    case "${SCRIBE_FABLE_PREFLIGHT:-}" in
      1) return 0 ;;
      0) return 1 ;;
    esac
    # 実測（sc-9q6・2026-07-03）: fable は最小 -p 呼び出しでも応答に 60s+ かかる（重 reasoning 系の固有コスト）
    # 一方、利用不可（モデル不存在・アクセス不能・limit 到達）は ~5s で fast fail する（rc=1 等）。
    # ゆえに判定は「fast fail だけが不可」: timeout(rc=124) は **受理された＝利用可** とみなす
    # （完了を待つ判定だと正常 fable が常に偽不可＝恒常 opus 降格になる）。timeout 15s は fast fail(~5s) の
    # 3 倍マージン。--strict-mcp-config + 空 mcp-config で MCP ロードを抑止し preflight を軽く保つ。
    local rc=0
    timeout 15 "${SCRIBE_CLAUDE_BIN:-claude}" --model "$CONSULT_FABLE_MODEL" -p "ok" \
      --strict-mcp-config --mcp-config '{"mcpServers":{}}' >/dev/null 2>&1 || rc=$?
    [[ "$rc" -eq 0 || "$rc" -eq 124 ]]
  }
  if [[ "$MODEL_EXPLICIT" -eq 0 ]]; then
    MODEL="$CONSULT_FABLE_MODEL"
  fi

  TOPIC=""
  if [[ -n "$BD_ID" ]]; then
    TOPIC="$(scribe_normalize_bd_id "$BD_ID")" \
      || scribe_die "bd id の形式が不正です: '$BD_ID'（path traversal 等を拒否）"
    # consult の議題参照は READ のみ。実在しなければ fail-loud（typo を上流で塞ぐ）。
    SCRIBE_ANCHOR="$ANCHOR" scribe_bd_id_exists "$TOPIC" \
      || scribe_die "bd issue が存在しません: '$TOPIC'（consult 議題参照の typo を上流で阻止）"
  fi

  # --- grill-consult モード（--context 指定時）の前提検証（§7・sc-cuw 再編）---
  if [[ -n "$CONTEXT_FILE" ]]; then
    # (a) grill-issue id 必須: grill-consult は admin が起票した grill-issue を 1 件担当し、その bd notes へ
    #     決定を handoff する（§7）。grill-issue が無いと claim/append-notes/admin 監視の対象が定まらない。
    [[ -n "$TOPIC" ]] \
      || scribe_die "--context（grill-consult）は grill-issue id が必須です（決定 handoff 先の bd notes を定めるため・§7）"
    # (b) context は読める通常ファイルであること（admin が焼き込む集約 brief。typo を上流で fail-loud）。
    #     -r 単体だとディレクトリも真を返し、後段 build_consult_prompt 内の `cat "$CONTEXT_FILE"` が
    #     'Is a directory' で失敗しても直後の heredoc 成功で関数 exit が上書きされ「空 brief のまま
    #     consult 起動」する fail-safe ギャップになる（review wf_a92a624f confirmed）。-f を足して
    #     ディレクトリ/特殊ファイルを上流で fail-loud にする。
    [[ -f "$CONTEXT_FILE" && -r "$CONTEXT_FILE" ]] \
      || scribe_die "--context は読める通常ファイルを指定してください: '$CONTEXT_FILE'（不在/ディレクトリ/特殊ファイルは不可）"
    # (c) grill 方法論 = grill-me SKILL.md を verbatim 注入する（sc-swc・mechanism b）。不在/不読は fail-loud
    #     （grill-me 本文無しの grill-consult を spawn しない＝paraphrase ドリフトの再発を構造的に防ぐ）。
    [[ -f "$GRILL_SKILL" && -r "$GRILL_SKILL" ]] \
      || scribe_die "grill-me SKILL.md が読めません: '$GRILL_SKILL'（grill-consult は grill-me 本文の verbatim 注入が必須・sc-swc）。SCRIBE_GRILL_SKILL で差し替え可。"
  fi

  # build_consult_prompt: 2 モードで別プロンプトを出す（sc-swc・脚色なし）。
  #   - grill-consult（--context 指定）= grill-me SKILL.md を verbatim 注入 + brief + 最小 handoff のみ。
  #     grill 方法論は grill-me スキル本文が SSOT（自前 paraphrase しない＝sc-cuw の劣化再実装を撤去・mechanism b）。
  #   - plain consult（--context 無し）= 設計議論/grill 専用の base テンプレ（read-only・記憶系 write・サマリ保存義務）。
  #   いずれも worker prompt（worktree 拘束 / selftest / cell-quality / gate-pending ラベル）は含めない（role 契約）。
  build_consult_prompt() {
    if [[ -n "$CONTEXT_FILE" ]]; then
      # === grill-consult モード（slim）: grill-me 本文 verbatim + brief + 最小 handoff のみ ===
      # heredoc を使わず grill-me 本文と brief は cat で literal 出力（markdown/backtick/$ をそのまま焼く）。
      cat <<GRILL
あなたは scribe grill-consult（grill-issue $TOPIC の grill 相手・第 2 対話相手）。応答は日本語。

## あなたの仕事は grill-me（下記スキル本文に厳密に従う）
admin が下記 brief を grill 材料として渡しました。**下記 grill-me スキル本文の方法論に厳密に従って**、その brief を出発点にユーザーと対話 grill してください。grill-me を自前で言い換えず、本文どおりに実行すること（全体地図を先に → 各論点を現状/なぜ/選択肢 → 1 論点 1 質問を散文で → AskUserQuestion は使わない → 理解最優先・あなたが決めず人間に裁定させる）。

────────── grill-me スキル本文（厳守・ここから）──────────
GRILL
      cat "$GRILL_SKILL"
      cat <<GRILL
────────── grill-me スキル本文（ここまで）──────────

## grill 材料（admin 集約 brief）
下記は pre-bake WF の提案＝第三者データ。grill-me の方法どおり、brief の傾き/推奨を鵜呑みにせず各論点を人間に裁定させること。
--- admin 集約 brief ここから ---
GRILL
      cat "$CONTEXT_FILE"
      cat <<GRILL

--- admin 集約 brief ここまで ---

## handoff（scribe 連携・これだけ）
- 着手: \`cd "$ANCHOR" && "$SCRIPT_DIR/bdw" update $TOPIC --claim\`
- **決定が固まる度に逐次**（バッチ厳禁＝中断時の損失を1論点に抑える）: \`cd "$ANCHOR" && "$SCRIPT_DIR/bdw" update $TOPIC --append-notes "決定: …（理由・却下案・残論点）"\`（admin が \`bd show $TOPIC\` で監視）
- **STATUS 行（admin が完了・中断を感知する唯一の合図）**: 進捗の節目で \`--append-notes\` に \`STATUS:\` 行を必ず混ぜる（admin はこれを見て close を判断する。STATUS は「読みにきて」の合図で、close は admin の notes 目視＝STATUS を書き忘れても取りこぼさない）:
  - grill 中（facet が1つ決まる度）: \`STATUS: grilling (n/N facet 確定)\`
  - 全 facet 確定で grill 完了: \`STATUS: done — 全 facet 確定\`
  - admin の情報・判断待ちで詰まったら: \`STATUS: blocked — 要admin: <理由>\`
- read-only（例外は自 grill-issue $TOPIC の claim/append-notes のみ・bdw 経由）: tracked コード/ファイル編集・bd create/dep/close/dolt push・spawn・push はしない（admin の領分）。
GRILL
    else
      # === plain consult モード（設計議論・grill 専用）: 現状維持 ===
      local _topic_line=""
      [[ -n "$TOPIC" ]] && _topic_line="- 議題参照（read-only）: \`bd show $TOPIC\`（観測のみ。worktree 仕事はしない）。"
      cat <<PROMPT
あなたは scribe consult セッション（設計議論・grill 専用の第 2 対話相手）。応答は日本語。
役割と禁止は docs/role-context-spec.md §2.3 が SSOT。

## 役割
- 用途は **設計議論・grill のみ**。オーケストレーション・gate 代行・実装はしない。
${_topic_line}

## read-only 規律（厳守）
- リポの tracked ファイル・コードを編集しない。bd の write（create/update/close/dolt push）・spawn・deploy は **禁止**。
- 観測は可（read）。タスク化が要っても自分で bd 起票せず、相談サマリに「admin への起票候補」として書き出すに留める（起票は admin）。

## write してよいのは記憶系のみ
- doobidoo（\`mcp__doobidoo__memory_store\`）と auto-memory（\`MEMORY.md\`）への保存だけ許可。

## サマリ保存義務（必須）
- 終了・中断の前に、議論の結論・未解決の論点・admin への起票候補を相談サマリにまとめ doobidoo へ保存する（会話履歴に依存させない）。
PROMPT
    fi
  }

  # env-file は **anchor working tree の外**（/tmp 配下）に作る。anchor は admin の cwd で
  # あり、そこに artifact を残すと anchor リポを汚し誤コミット経路になる（道具自身が read-only 契約の
  # 起動器なのに anchor を汚す非対称を避ける）。cld-spawn は env-file を launcher へ source 済みなので
  # spawn 後に rm して消える＝anchor に何も残さない。dry-run は実ファイルを作らずパスだけ案内する。
  ENV_LINE="export SCRIBE_ROLE=consult"
  # consult は --bd-id を渡さない設計のため、放置すると cld-spawn の window 名が汎用命名（git 状態由来の
  # wt-<repo>-<branch>-…）へ落ち、fleet-monitor/人間が consult を判別できない（admin C5 live finding・un-01h）。
  # window 名の規約（prefix `consult-` で識別・fleet-monitor 照合 / sc-3pq L3=A案・grill 確定 2026-06-24）:
  #   - grill-consult（--context 指定で grill-issue=$TOPIC が在る）→ consult-<grill-issue>。wt-<id> と同型の
  #     id 完全一致命名にし、fleet-monitor / degraded watcher が「どの grill-issue の consult が沈黙したか」を
  #     一意に紐付けられるようにする。grill-issue は in_progress（grill-consult が bd notes へ決定を書く）ゆえ
  #     board に正しく点灯する。
  #   - plain consult（grill-issue 無し）→ consult-HHMMSS（id が無いので時刻で一意化）。read-only の議題参照
  #     issue は in_progress とは限らず board を誤点灯しうるため id 紐付けしない。
  # いずれも固定 `consult`（定数）は避ける: cld-spawn の find_existing_window が完全一致で既存 window を reuse →
  #   exit 0（偽成功・env-file 非 source で SCRIBE_ROLE=consult 未注入）する fail-open を招く（gate wf_d3777d26
  #   CONFIRMED）。reuse の構造封鎖は下記 --force-new が担う（window 名の毎回一意性に依存しない＝同一 grill-issue の
  #   中断リカバリ再 spawn〔§7〕でも --force-new が新規セッションを保証する）。
  if [[ -n "$CONTEXT_FILE" && -n "$TOPIC" ]]; then
    CONSULT_WINDOW="consult-$TOPIC"            # grill-consult: id 紐付け（fleet-monitor 照合・sc-3pq A案）
  else
    CONSULT_WINDOW="consult-$(date +%H%M%S)"   # plain consult: id 無し→時刻フォールバック
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$CONTEXT_FILE" ]]; then
      echo "[plan] scribe-spawn(consult): anchor=$ANCHOR grill-issue=$TOPIC（grill-consult モード）"
      echo "[plan] grill-consult モード（§7）: brief=$CONTEXT_FILE を grill 材料として焼き込み・grill-issue=$TOPIC"
      echo "[plan]   handoff 規約 → 決定は grill-issue $TOPIC の bd notes（bdw 経由 --claim/--append-notes のみ・read-only 限定緩和）。admin は bd show $TOPIC で監視"
    else
      echo "[plan] scribe-spawn(consult): anchor=$ANCHOR${TOPIC:+ 議題参照=$TOPIC（read-only）}"
    fi
    config_dir_plan_line
    [[ "$AUTO" -eq 1 ]] && account_select_plan
    echo "[plan] env-file（anchor 外＝anchor リポを汚さない・spawn 後 rm）:"
    echo "         ENV_FILE=\$(mktemp /tmp/scribe-consult-XXXXXX.env)"
    echo "         printf '%s\\n' '$ENV_LINE' > \"\$ENV_FILE\""
    echo "         $(emit_config_dir_envline) >> \"\$ENV_FILE\"   # sc-rvq config-dir 追随（源=$WCFG_SOURCE）"
    if [[ "$MODEL_EXPLICIT" -eq 0 ]]; then
      echo "[plan] model: 既定 fable（$CONSULT_FABLE_MODEL・sc-9q6）。本起動時に preflight し、利用不可なら opus へ loud fallback（dry-run は API を叩かない）"
    fi
    echo "[plan] $CLD_SPAWN --cd $ANCHOR --model $MODEL --window-name $CONSULT_WINDOW --force-new --env-file \"\$ENV_FILE\" \"<consult テンプレ本文>\""
    echo "[plan] rm -f \"\$ENV_FILE\"   # source 済みなので spawn 後に消す（anchor に残さない）"
    echo "[plan] (consult は worktree を作らない / --bd-id を渡さない / worker prompt を出さない＝role 契約)"
    echo "[plan] window 名 = --window-name $CONSULT_WINDOW（grill-issue 在りは consult-<grill-issue> で id 紐付け・無しは consult-HHMMSS・prefix consult- で識別・sc-3pq A案）+ --force-new（reuse 経路封鎖=偽成功/SCRIBE_ROLE 未注入防止・un-01h gate）"
    echo "[plan] --- consult テンプレ（role-context-spec §2.3）---"
    build_consult_prompt | sed 's/^/         | /'
    exit 0
  fi

  # ===== consult 実行（real）=====
  # fable preflight（sc-9q6）: fable 既定で解決されたときだけ実測し、利用不可なら opus へ loud fallback。
  if [[ "$MODEL_EXPLICIT" -eq 0 ]] && ! fable_available; then
    echo "[scribe-spawn] WARN: fable preflight 失敗 → consult を opus で起動します（既定 fable の fallback 経路・sc-9q6）" >&2
    MODEL="opus"
  fi
  # config-dir preflight（sc-rvq・item2/3）: consult も worktree add せず anchor 同居で cld-spawn するが、
  # tmux env 剥ぎで既定 ~/.claude へ落ちる非対称は worker と同じ（consult は chain-source 無しゆえ余計に落ちる）。
  # 注入予定 config dir が set なら preflight で欠落を fail-loud にしてから起動する。
  preflight_config_dir
  ENV_FILE="$(mktemp /tmp/scribe-consult-XXXXXX.env)" || scribe_die "env-file の作成に失敗しました（mktemp）"
  trap 'rm -f "$ENV_FILE"' EXIT   # 異常終了でも /tmp に残さない
  printf '%s\n' "$ENV_LINE" > "$ENV_FILE"
  # sc-rvq: consult 分岐の env-file にも同じ config-dir 追随を注入（item2）。SCRIBE_ROLE 行の後に置く。
  emit_config_dir_envline >> "$ENV_FILE"
  CONSULT_PROMPT="$(build_consult_prompt)"
  "$CLD_SPAWN" --cd "$ANCHOR" --model "$MODEL" --window-name "$CONSULT_WINDOW" --force-new --env-file "$ENV_FILE" "$CONSULT_PROMPT"
  if [[ -n "$CONTEXT_FILE" ]]; then
    echo "spawned(consult): anchor=$ANCHOR model=$MODEL window=$CONSULT_WINDOW grill-consult=$TOPIC（決定 handoff=grill-issue bd notes）"
  else
    echo "spawned(consult): anchor=$ANCHOR model=$MODEL window=$CONSULT_WINDOW${TOPIC:+ 議題参照=$TOPIC}"
  fi
  exit 0
fi

# ===========================================================================
# worker モード（既定）: 1 issue = 1 worktree = 1 window。
# ===========================================================================
# worker は fable 厳禁（protocol.md §1: opus 必須＝コスト爆発防止）。consult は上で既に分岐済みなので
# ここに来るのは worker のみ＝この die は consult の fable 例外（role-context-spec §2.3）を塞がない。
# ${MODEL,,} で小文字化＝FABLE/Fable 等の大文字混在も取りこぼさない（case-insensitive）。
case "${MODEL,,}" in
  *fable*) scribe_die "--model に fable 系は使えません（worker は opus 必須・protocol.md §1）" ;;
esac

# --- effort allowlist 検証（sc-dc9・worker 分岐でのみ・flag/env/既定 の全由来を検証）---
# EFFORT は --effort フラグ・SCRIBE_WORKER_EFFORT env・既定 high のいずれか。CC が受理する effort 語彙
# （low|medium|high|xhigh|max）は scribe-lib の単一 SSOT SCRIBE_EFFORT_ALLOWLIST（sc-ax4）へ集約済み。
# それ以外は CC 側の silent 無視や誤挙動を招くため上流で fail-loud する（consult 分岐は既に exit 済＝
# ここは worker 経路のみ）。許可語彙メッセージも SSOT 由来（scribe_effort_allowlist_join）にして drift を断つ。
scribe_effort_is_valid "$EFFORT" \
  || scribe_die "--effort/SCRIBE_WORKER_EFFORT が不正: '$EFFORT'（許可: $(scribe_effort_allowlist_join '|')）"

# --- AC2: 既定 repo が linked（副）worktree のとき fail-loud（un-ag7）---
# `--repo` 未指定（= cwd 既定）で cwd が副 worktree のとき、`git worktree add` が
# <linked-wt>/.worktrees/spawn/... へネストし、base=HEAD も origin/main でなく副 branch HEAD になる
# （2026-06-12 実害）。worktree add（および --dry-run の emit_plan）の前にここで停止する（AC2/AC5）。
# REPO と ANCHOR は独立判定（AC4）: --anchor 明示でここまで来ても --repo 既定が副 worktree なら止める。
# 明示 `--repo` 時は不発火（AC3）。検出は git plumbing（naming 規約に依存しない・AC4）。
if [[ "$REPO_EXPLICIT" -eq 0 ]] && _repo_main="$(scribe_linked_worktree_main "$REPO")"; then
  scribe_die "既定 repo が linked worktree です: $REPO
  ここで git worktree add すると .worktrees がネストし base も誤り（HEAD=副 branch）になります。
  真の main worktree: $_repo_main
  → そこへ cd するか、--repo '$_repo_main' を明示してください。"
fi

[[ -n "$BD_ID" ]] || scribe_die "bd id（worker モードの必須引数）がありません。Usage は --help。"

# --- 1. bd id 事前検証（fail-loud・この前に spawn コマンド列は一切出さない）---
ID="$(scribe_normalize_bd_id "$BD_ID")" \
  || scribe_die "bd id の形式が不正です: '$BD_ID'（path traversal 等を拒否）"
SCRIBE_ANCHOR="$ANCHOR" scribe_bd_id_exists "$ID" \
  || scribe_die "bd issue が存在しません: '$ID'（cld-spawn の silent fallback を上流で阻止）"

# --- 命名（protocol.md §1）---
BRANCH="$(scribe_branch_name "$ID")"            # spawn/<id>-HHMMSS
WINDOW="$(scribe_window_name "$ID")"            # wt-<id>
WORKTREE="$REPO/.worktrees/$BRANCH"             # <repo>/.worktrees/spawn/<id>-HHMMSS

# --- sandbox は既定 on（opt-out 化・sc-u53）---
# 旧仕様（default off・SCRIBE_SANDBOX=1 で opt-in）から反転。worker を OS sandbox に**既定で**封じる。
# 明示 opt-out は SCRIBE_SANDBOX=0 のみ（"0" のときだけ off・未指定/その他は on）。SANDBOX_ON を一度だけ計算し、
# build_prompt（--also-tmp / scribe-add 規律）・emit_plan・実 materialization が全てこの 1 変数を読む（DRY＝
# 4 箇所のインライン判定が drift しない）。dep-preflight（下記・実 spawn 経路）が deps 欠如時に SANDBOX_ON を
# 0 へ降格しうる（fallback）ため、build_prompt はその降格後の値を見る（呼出は materialization より後）。
# SANDBOX_OPTOUT（sc-7oj/FO-1）は「明示 opt-out で off になった」ことだけを記録する別変数（fallback 降格と区別）。
# 明示 opt-out は env 継承で sticky 化し無警告で fleet 全体を非 sandbox 化しうる（silent degrade の本命）ため、
# emit_plan（dry-run 可視化・FO-4）と実経路（stderr loud warn・FO-1）の両方でこのフラグを見て縮退を surface する。
# fallback 降格（deps 欠如＋FALLBACK=1）は別途その場で警告済みゆえ二重警告しないよう opt-out だけを立てる。
SANDBOX_ON=1
SANDBOX_OPTOUT=0
[[ "${SCRIBE_SANDBOX:-}" == "0" ]] && { SANDBOX_ON=0; SANDBOX_OPTOUT=1; }

# --- 3. task prompt 生成（protocol.md §2）---
build_prompt() {
  # この spawn prompt は worker 機械防御（env-probe/sentinel/effort/autonomous 規律）の operative
  # instantiation（worktree/anchor/ID を焼いた具体コマンド）である。その carrier モデルと規律本文の
  # SSOT は docs/protocol.md §2（「機械防御の carrier は scribe-spawn」項 + autonomous 規律項）——本
  # prompt と SessionStart role-inject の両 carrier が §2 を引く（drift 停止・sc-99c/sc-3p9）。非 spawn
  # worker（env signal 不在）への split-brain warning は role-inject が §2 を SSOT に注入する。
  # env-probe の base は spawn 時点の commit を SHA へ凍結して焼く。既定 BASE="HEAD" をリテラルで
  # 焼くと verify 時の `HEAD..HEAD`=常に 0 commit になり健全 worker を誤 blocked にする（un-k02 同型・
  # review#1 critical）。scribe_git で GIT_DIR/GIT_WORK_TREE 継承を隔離して解決（sc-e1w）。
  local _probe_base
  _probe_base="$(scribe_git -C "$REPO" rev-parse "$BASE" 2>/dev/null || printf '%s' "$BASE")"
  # env-probe verify の /tmp sentinel チェック（--also-tmp）は sandbox 下で外す（sc-3lj）。CC sandbox は /tmp を
  # read-only にするため plant の /tmp sentinel は best-effort で書けず（scribe-env-probe が warn して継続）、
  # verify --also-tmp がその不在を誤って ENV_DEGRADED と判定する。worktree sentinel チェック（常時・主シグナル）で
  # 十分なので sandbox 時は --also-tmp を落とす。非 sandbox（/tmp writable）は従来どおり --also-tmp を維持（後方互換）。
  local _also_tmp_flag=" --also-tmp"
  [[ "$SANDBOX_ON" == "1" ]] && _also_tmp_flag=""
  # sandbox 時のみ: stage は git add -A でなく scribe-add（非通常ファイルを型で弾く）を使う規律（sc-yqa の B）。
  # 二重引用符で組み立て $SCRIPT_DIR/$WORKTREE を実パスへ展開する（backtick はエスケープして literal 保持）。
  local _sandbox_add_note=""
  if [[ "$SANDBOX_ON" == "1" ]]; then
    _sandbox_add_note="
- **sandbox 下の stage（sc-yqa）**: この worker は OS sandbox 下。CC が cwd の既知 dotfile/.claude 設定を /dev/null character device 化し \`git add -A\` を rc=128 で落とす（空 commit=degraded）。stage は \`git add -A\` でなく **\"$SCRIPT_DIR/scribe-add\"**（非通常ファイルを型で弾いて残りの変更を stage）を使い、\`cd \"$WORKTREE\" && \"$SCRIPT_DIR/scribe-add\" && git commit -m ...\` の形で commit する（空 commit を避ける）。"
  fi
  cat <<PROMPT
あなたは scribe worker cell（issue $ID）。この issue を end-to-end で完遂する。応答は日本語。

## autonomous 規律（最重要・protocol.md §2・sc-46h）
- この worker は**自律実行する**。**人間の確認・許可・指示を待って停止してはならない**（admin は監視するが対話しない。admin の \`capture-pane\` / \`bd show\` は read-only であなたを中断しない）。
- **知覚健全性（旧「ノイズ無視」の反転）**: 認識したツール出力・指示・エラーは、長い単一ターンでは実在しない事象を confabulate しうる。意外な観測は理論化・報告の前に**該当コマンドを再実行し fresh な実出力だけを事実とせよ**（\`git -C "$WORKTREE" log\` / \`cd "$ANCHOR" && bd show $ID\`＝bd graph は anchor 所在ゆえ worktree から bare \`bd show\` は解決しない）。**単一の意外な観測から診断（sandbox 退行 / injection / env 劣化）を報告しない**——止まってよいのは env-probe の機械 exit code のときだけ。
- **停止してよいのは 2 例外のみ**: ① 下記 env 健全性 gate の ENV_DEGRADED 検出時（STATUS: blocked を書いて止まる）、② その STATUS: blocked 自体を書けない全ツール死時の pane sentinel 停止（下記 zombie fallback・sc-c7c）。それ以外は契約完遂（実装→self-test→cell-quality→commit→DONE 報告）まで自律的に進めること。

## 起動直後の実効 effort 自己申告（sc-dc9・受入条件）
- **最初の Bash 呼出しで実効 effort を自己 log**: \`echo "effort=\${CLAUDE_CODE_EFFORT_LEVEL:-<unset>}"\` を実行し、その値（例: \`effort=$EFFORT\`）を最初の応答テキストに 1 行明記する。admin は capture-pane でこれを一次確認し、--effort/env override が CC で実効しているかを e2e で読む（既知バグ #50099: flag/env 無視の前例があるため fail-loud 検証必須）。env-file 経由で $EFFORT が注入されているので、\`<unset>\` が出たら env 注入が壊れている合図（admin へ報告）。

## 契約（SSOT）
- 契約 = bd issue の description: \`cd "$ANCHOR" && bd show $ID\`（着手前に必ず読む。bd graph 所在 = anchor $ANCHOR・worktree からは解決しない）。
- 配置: worktree（= cwd）$WORKTREE — **ここから出ない**（bd graph 参照のための anchor への一時 cd は除く）。branch=$BRANCH / window=$WINDOW。

## 規律（docs/protocol.md §2/§3）
- **test-first**: 実装に対する self-test を自分で用意し worktree 直下に置く
  （\`selftest-$ID.local.sh\`・untracked・コミットしない・**fail-closed**＝assert 1 つでも落ちたら非 0）。
- **cell-quality WF を直接呼出**（named-WF 明示・scriptPath 直指定）で gate review/verify を 1 回回す。
  自己点検 args は \`"$SCRIPT_DIR/scribe-selftest-args.sh" --worktree "$WORKTREE" --anchor "$ANCHOR" --self-test <selfTestCmd> $ID\` で 1 コマンド化済み
  （\`doImplement\`/\`doPlan\`=false・\`autoFix\`=true・\`selfTestCmd\` 必須を固定。手作業で args を組まない。**\`--anchor\` は必須**＝bd graph 所在は worktree cwd では解決しないため省くと die）。
- **報告に WF 返り値 JSON + \`receivedArgs\` を必須**で含める（args 解決の成否を admin が一次監査できるように）。
- **env 健全性 gate（fail-closed・CC infra の Bash 非永続を検出／folio 0264028f）**: self-report（cell-quality 呼出し・gate-pending 付与）の前に env 劣化を検出する（self-test fail-closed は「失敗」しか守らず env 劣化の「誤 PASS」を塞げない）。exit code の意味論（exit 3/4/5・sc-owj）は \`scribe-env-probe.sh\` ヘッダが SSOT、incident 経緯・zombie 検知網・TUI 描画理屈は protocol §6 が catalog SSOT——ここでは operative コマンドのみ焼く:
  - 着手の最初に**別 Bash 呼出し**で \`"$SCRIPT_DIR/scribe-env-probe.sh" plant --worktree "$WORKTREE"\` を実行し、**出力 token を文字列で控える**（shell 変数は Bash 呼出し間で消える）。
  - **self-report の直前**に**別 Bash 呼出し**で \`"$SCRIPT_DIR/scribe-env-probe.sh" verify --token <控えた token> --worktree "$WORKTREE" --base $_probe_base$_also_tmp_flag\` を実行する。
  - **verify は再入可能**（ENV_OK は sentinel を温存・sc-0d2）: 途中確認は **\`--base\` を外して**同じ token で随時 verify（\`--base\` 付きは 0 commit で偽 \`ENV_DEGRADED\` を出すため gate-pending 直前のみ）。
  - \`ENV_DEGRADED\` の扱いは **exit code で分岐する**（exit 3=Bash 非永続 / exit 4=0 commit / exit 5=.git 書込劣化・意味論 SSOT は \`scribe-env-probe.sh\` ヘッダ）。共通の停止手順は **done を申告せず** \`cd "$ANCHOR" && "$SCRIPT_DIR/bdw" update $ID --append-notes "STATUS: blocked — env degraded（CC infra の Bash 非永続 or .git 書込劣化・要admin）: <ENV_DEGRADED の理由>"\` を書いて停止する（回避策を打たない＝worker では直せない・admin が引き取る）:
    - **exit 3 / exit 5 は無条件停止**（真の劣化＝即 blocked）。
    - **exit 4（0 commit）は条件付き**: **実装をまだ commit していないなら劣化ではない**（verify を commit より前に呼んだ『早すぎる呼出し』＝正常）。この時は blocked を書かず、まず実装を commit し、**前段の exit 4 で sentinel は掃除済み**ゆえ \`"$SCRIPT_DIR/scribe-env-probe.sh" plant --worktree "$WORKTREE"\` で sentinel を再設置して**新 token を控え直してから**、その新 token で \`verify --base\` を **1 回だけ**再実行せよ（再 plant なしの再 verify は sentinel 不在で偽 exit 3 になる）。**自ら commit 済みを確認した後もなお exit 4** のときだけ真の劣化として上記 blocked を書いて停止する（commit 前の exit 4 で blocked を書くのは誤停止・sc-bp7）。
  - **zombie fallback（STATUS: blocked を書けない時・sc-c7c）**: bdw 書込が繰り返し失敗する／ツール実行が全て空応答（Bash/Read 再実行でも無返答＝ツール層の全死）なら、回避策を打たず**応答テキストの単独行**として行頭から \`SCRIBE-ENV-DEGRADED: $ID <一行理由>\` を出力して停止する（turn text は pane に残る＝最後の信号。admin は \`capture-pane | tail -n N | grep -E '^[[:space:]]*SCRIBE-ENV-DEGRADED:'\` で拾う・TUI インデントゆえ行頭空白許容）。出力後は再試行せず入力待ちで止まる。
- bd write は必ず \`bdw\` 経由で直列化: \`cd "$ANCHOR" && "$SCRIPT_DIR/bdw" <subcmd>\`（自 issue の進捗のみ）。$_sandbox_add_note
- **完了は gate-pending ラベル + DONE 報告（自己 close しない・§4 反転）**: 実装 + self-test pass + PR/commit + 上記 env-probe verify が揃ったら、\`cd "$ANCHOR" && "$SCRIPT_DIR/bdw" update $ID --add-label gate-pending\` で自 issue に **gate-pending ラベル**を付与し、PR 番号 / commit / WF 返り値を添えて DONE を報告する。**自分で \`bd close\` しない**——close は admin が gate+merge を済ませた後に行う（worker の自己 close は admin の gate 待ち検知をすり抜ける＝orch-ol0 反転）。

## 禁止（protocol.md §2/§3）
- \`bd create\` / \`bd dep\` / assignment / \`bd dolt push\` / **\`bd close\`（自 issue の close も admin 専有＝gate+merge 後）**（graph・同期点は admin の所有物）。
- GitHub への push（admin が gate 後）/ admin window への tmux inject / 編集可スコープ外の編集。
- **共有 \`.git/config\`（remotes / hooks / config 等）を mutate しない**: worktree は anchor と \`.git/config\` を **共有** するため、worker が origin/remote を書き換えると anchor+全 worktree の origin が壊れ admin の push が破綻する（un-1n1 実害）。remote 検証が要るなら **throwaway bare repo / 別 clone** を使う（\`remote.*\` は git が共有 config からのみ読むため \`git config --worktree\` でも隔離できない＝検証済み・物理隔離は →un-6nf）。
- **follow-up の bd create**: 起票が要っても自分で起票せず自 issue の notes に「admin への起票候補」として書く。
PROMPT
}

# --- monitor 起動コマンド（protocol.md §1/§6・window ID @N 参照）---
# WINDOW(wt-<id>) → window_id(@N) を解決してから -t に渡す（dotted id の window.pane 区切り衝突回避）。
# 監視は capture-pane + busy 判定 regex（protocol.md §6）で手動観測する（v0 = 背景 supervisor なし）。
# sc-w5e（sc-c7c 昇格の運用側配線）: tail 窓は 3→12 行。CC TUI は入力 prompt box + statusline で pane
# 最下部を最大 ~10 行占有するため、worker 停止時の zombie sentinel 行は 3 行窓の外へ押し出される
#（sc-c7c dogfood 実測。busy spinner 行も同様に 3 行窓の外だった）。12 は同 dogfood の admin 監視が
# idle 判定に使った実測値で、これ以上広げると scrollback 残渣が誤検知源になる（同 dogfood で広窓が
# 過去表示の残渣から SESSION-LIMIT を偽検知した実害）。
# 1 回の capture を C に取り、目視（echo）と sentinel 機械検知（grep・§6 補助信号）を 1 行に併記する。
# 検知 regex は sc-c7c dogfood 確定形（行頭空白許容・protocol §6 と同一契約）。sentinel は
# self-authenticating ではない（§6・token が worker の正当 content に現れるケースを regex では弁別不能）
# ため、検知時の文言は即 salvage でなく 0-commit × 持続 idle の cross-read へ誘導する。
# grep 形は fleet-monitor 拡張（sc-3pq）が将来 consume する前提で protocol §6 と揃える。
# 両 emit 箇所（emit_plan の MONITOR_CMD / spawn 末尾の monitor: 行）は本 builder を共有し、片方だけの
# 契約ドリフトを構造的に防ぐ。
MONITOR_TAIL=12
MONITOR_SENTINEL_RE='^[[:space:]]*SCRIBE-ENV-DEGRADED:'
monitor_cmd_for() {  # $1 = tmux -t ターゲット（dry-run は literal $WID のまま emit＝MONITOR_RESOLVE 後に admin shell が展開）
  printf '%s' "C=\$(tmux capture-pane -p -t \"$1\" | tail -n $MONITOR_TAIL); echo \"\$C\"; grep -E '$MONITOR_SENTINEL_RE' <<<\"\$C\" && echo '>>> zombie sentinel 検知（補助信号・protocol §6: 即 salvage せず 0-commit × 持続 idle を cross-read）'   # busy regex: '… \\(|esc to interrupt|agents [0-9/ ]*(done|running)|tokens'"
}
MONITOR_RESOLVE="WID=\$(tmux list-windows -F '#{window_id} #{window_name}' | awk -v n='$WINDOW' '\$2==n{print \$1; exit}')   # → @N"
MONITOR_CMD="$(monitor_cmd_for '$WID')"

# --- cld-spawn --effort passthrough は feature-detect（sc-dc9・実装3・un-ivb 防御）---
# cld-spawn の --effort は cc-session 側 PR で land 予定だが未 merge の可能性がある。現行 cld-spawn は未知
# オプションを PROMPT へ落とす（un-ivb）ため **無条件 passthrough は厳禁**。--help に --effort が実在するときだけ
# spawn 行の argv へ `--effort <EFFORT>` を追加する。env-file 経路（CLAUDE_CODE_EFFORT_LEVEL の後勝ち注入・下記）は
# flag 有無に関わらず常に敷く（CC 正規 precedence = --effort フラグ > CLAUDE_CODE_EFFORT_LEVEL env ゆえ flag>env で共存無害）。
# 検出結果は emit_plan（dry-run 可視化）と実 spawn 行の両方が参照する（片方だけの契約ドリフトを防ぐため一度だけ計算）。
CLD_EFFORT_ARG=()
CLD_EFFORT_DETECTED=0
if "$CLD_SPAWN" --help 2>/dev/null | grep -q -- '--effort'; then
  CLD_EFFORT_ARG=(--effort "$EFFORT")
  CLD_EFFORT_DETECTED=1
fi
# dry-run の spawn 行と実 spawn 行の表示で共有する effort 断片（未検出時は空＝env-file 経路のみ）。
_effort_show=""
[[ "$CLD_EFFORT_DETECTED" == "1" ]] && _effort_show=" --effort $EFFORT"

emit_plan() {
  echo "[plan] scribe-spawn: issue=$ID（実在検証 OK）"
  echo "[plan] git -C $REPO worktree add -b $BRANCH $WORKTREE $BASE"
  [[ "$SANDBOX_ON" == "1" ]] && echo "[plan] sandbox: $WORKTREE/.claude/settings.local.json を生成（SCRIBE_SANDBOX 既定 on・opt-out は SCRIBE_SANDBOX=0。bwrap 外壁。CLD_PATH/launcher は不変＝spawn 行 byte 同一）。実 spawn 時に dep-preflight（deps 欠如→SCRIBE_SANDBOX_FALLBACK=1 で警告付き非 sandbox / 無ければ fail-loud・sc-u53）"
  # FO-4(sc-7oj): 縮退経路（明示 opt-out）を dry-run でも可視化する。旧 emit_plan は opt-out 時に sandbox 行を
  # 一切出さず「無防備で走る」ことが --dry-run 監査で不可視だった（監査ギャップ）。opt-out は env 継承で sticky
  # 化する点まで明示する。sandbox 設定は生成しない旨は書くが literal 'settings.local.json' は出さない（opt-out で
  # sandbox 節を出さない不変条件を pin する既存テストを壊さないため・そちらは別行で on 経路のみ照合している）。
  [[ "$SANDBOX_OPTOUT" == "1" ]] && echo "[plan] sandbox: OPT-OUT（SCRIBE_SANDBOX=0）→ この worker は OS sandbox の**外**で走ります（sandbox 設定を生成せず旧 byte 経路・Bash subprocess の書込みが worktree 外へ到達しうる）。⚠ SCRIBE_SANDBOX=0 は env 継承で sticky 化し、意図せず以降の全 spawn を無防備化しうる（1 回限りの opt-out でなければ環境から unset すること）。"
  echo "[plan] scribe_capture_origin $REPO $WORKTREE   # canonical origin を per-worktree marker へ捕捉（un-1n1・gate §5 verify 用）"
  echo "[plan] worker env-file（/tmp・全 worker 無条件・worktree add より前に mktemp・spawn 後 rm。edit-write-guard の activation+境界 signal・sc-649）:"
  echo "         WORKER_ENV_FILE=\$(mktemp /tmp/scribe-worker-XXXXXX.env)"
  echo "         { source '${CLD_ENV_FILE:-\$HOME/.cld-env}' ...（ホスト既定 env を chain-source＝認証/秘密を保つ・gate round4）; export SCRIBE_WORKER=1; export SCRIBE_WORKTREE=%q（$WORKTREE・%q=source-safe）; export CLAUDE_CODE_EFFORT_LEVEL=%q（$EFFORT・CC 正規名・後勝ち・sc-dc9）; $(emit_config_dir_envline)（sc-rvq config-dir 追随・chain-source 後勝ち・源=$WCFG_SOURCE） } > \"\$WORKER_ENV_FILE\""
  # sc-dc9: worker の実効 effort は CC 正規名 CLAUDE_CODE_EFFORT_LEVEL を env-file へ後勝ち注入する（settings.json の
  # xhigh 無差別波及を止める）。cld-spawn への --effort flag passthrough は feature-detect（--help に実在時のみ・un-ivb 防御）。
  if [[ "$CLD_EFFORT_DETECTED" == "1" ]]; then
    echo "[plan] effort: $EFFORT（cld-spawn --help に --effort 検出→ spawn 行に --effort $EFFORT を追加 + env-file に CLAUDE_CODE_EFFORT_LEVEL=$EFFORT）"
  else
    echo "[plan] effort: $EFFORT（cld-spawn --help に --effort 未検出→ env-file の CLAUDE_CODE_EFFORT_LEVEL=$EFFORT のみ・flag は付けない=un-ivb 防御）"
  fi
  config_dir_plan_line
  [[ "$AUTO" -eq 1 ]] && account_select_plan
  # 値は引用して表示する（実 invocation 行 §下記と同じく 1 argv であることを dry-run 監査でも視覚化する。
  # 将来 WORKER_DISALLOWED_TOOLS が内部空白を持つ spec〔例 Bash(git push:*)〕を含む場合に「2 引数」と誤読
  # させない・gate finding orch-4dm-review [nit]）。--env-file は全 worker（sandbox on/off 問わず）無条件ゆえ
  # opt-out と既定で spawn 行は等しく byte 不変（sc-649）。
  echo "[plan] $CLD_SPAWN --cd $WORKTREE --bd-id $ID --model $MODEL$_effort_show --disallowed-tools \"$WORKER_DISALLOWED_TOOLS\" --env-file \"\$WORKER_ENV_FILE\" \"<task prompt>\""
  echo "[plan] monitor（window ID @N 参照・dotted id の tmux -t 衝突回避）:"
  echo "         $MONITOR_RESOLVE"
  echo "         $MONITOR_CMD"
  echo "[plan] --- task prompt（protocol.md §2）---"
  build_prompt | sed 's/^/         | /'
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  emit_plan
  exit 0
fi

# ===== 実行（real）=====

# --- config-dir preflight（sc-rvq・実装3）: 注入予定 config dir が set なら worker を安全に起こせるか fail-loud 検査 ---
# worktree add の **前**に置く（欠落 config dir で orphan worktree を作らない・sandbox dep-preflight と同姿勢）。
# unset（既定 ~/.claude）は no-op ゆえ挙動不変（AC1）。欠落系は黙って ~/.claude へ fallback せず die（AC3）。
preflight_config_dir

# --- FO-1(sc-7oj): 明示 opt-out を loud に警告する（silent fleet degrade の本命）---
# SCRIBE_SANDBOX=0 は env 継承で sticky 化しうる（1 回の opt-out を export したまま同一 shell から spawn を
# 繰り返すと、以降の全 worker が無警告で非 sandbox 化される）。旧コードはこの経路を一切警告せず、settings も
# 生成しないため実 spawn でも --dry-run でも「無防備で走る」ことが不可視だった（security-audit FO-1 high→medium）。
# ここで stderr に loud warn を出し、意図しない sticky opt-out を運用者が即座に気付けるようにする。fallback 降格
# （deps 欠如＋FALLBACK=1）は下の dep-preflight ブロックが別途警告するため、ここは明示 opt-out だけを対象にする。
if [[ "$SANDBOX_OPTOUT" == "1" ]]; then
  echo "scribe: ⚠ sandbox OPT-OUT: SCRIBE_SANDBOX=0 が設定されています → この worker（issue $ID）は OS sandbox の**外**で走ります（Bash subprocess の書込みが worktree 外へ到達しうる）。1 回限りの opt-out でなければ環境から SCRIBE_SANDBOX を unset してください（env 継承で sticky 化し、以降の全 spawn が無警告で無防備になります）。" >&2
fi

# --- canonical bdw 無条件 preflight（sc-ovq・sandbox-off zombie worker 防止）---
# bdw（scripts/bdw shim→canonical beads-bdw plugin）は **sandbox の有無に依らず worker が必ず使う**一般依存
# （worker の自 issue 進捗 write は全て bdw 経由・protocol.md §3）。canonical 不在なら shim は fail-closed で
# 停止し、worker の全 bd write が台帳に残らない＝**zombie worker**（commit はするが進捗が graph に一切反映されない）。
# 旧コードは bdw 到達性を sandbox-ON 限定の dep-preflight 内でだけ検査していたため、SCRIBE_SANDBOX=0（opt-out）
# 経路はそこを通らず、plugin 不在 host で sandbox-off worker が黙って zombie 化していた（sc-ovq）。
# よって worktree add の **前**に、ON/OFF どちらの経路でも無条件に bdw 到達性を検査し、不能なら worker 起動前に
# fail-loud で止める（orphan worktree も zombie worker も作らない）。検査は scribe-lib の共有関数
# scribe_canonical_bdw_ok（gen / sandbox preflight と同一の `scripts/bdw lock-dir` 経路＝drift しない）。
# テスト時は BEADS_BDW=不正パスで shim を fail-closed に倒して非vacuous に注入できる（seam 不要＝実 shim を実走）。
if ! _bdw_reason="$(scribe_canonical_bdw_ok)"; then
  scribe_die "canonical bdw に到達できず worker を起動できません（sandbox の有無に依らず worker は bdw を使う・sc-ovq）: ${_bdw_reason}
  対処のいずれか:
    (1) beads-bdw plugin を配備する: ln -sfn ~/projects/local-projects/beads-bdw ~/.claude/plugins/beads-bdw
    (2) canonical bin/bdw を環境変数で指定する: export BEADS_BDW=/abs/path/to/beads-bdw/bin/bdw
  （未配備のまま spawn すると worker の全 bd write が shim fail-closed で台帳に残らない zombie worker になります）"
fi

# --- sandbox dep-preflight（sc-u53・default-on の安全弁）---
# default-on では deps 欠如 host で settings.local.json の failIfUnavailable により worker が起動拒否される。
# worktree を作る **前** に deps を preflight する（fail-loud で orphan worktree を残さない）。欠如時:
#   - SCRIBE_SANDBOX_FALLBACK=1 を置いた host → 警告して非 sandbox で続行（SANDBOX_ON=0 へ降格・build_prompt も追従）。
#   - それ以外 → fail-loud で停止（黙って無防備に走らせない＝scribe の fail-closed 規律・sc-u53 ユーザー確定）。
# 明示 SCRIBE_SANDBOX=0（opt-out）は SANDBOX_ON=0 ゆえこのブロックを通らない＝旧 byte 経路へ素通り。
# preflight は seam（SANDBOX_PREFLIGHT）経由＝テストで deps 欠如を注入できる。欠落理由は stdout で受ける。
if [[ "$SANDBOX_ON" == "1" ]]; then
  if ! _preflight_reason="$("$SANDBOX_PREFLIGHT" 2>/dev/null)"; then
    if [[ "${SCRIBE_SANDBOX_FALLBACK:-0}" == "1" ]]; then
      echo "scribe: warn: sandbox deps 欠如（${_preflight_reason}）だが SCRIBE_SANDBOX_FALLBACK=1 → 非 sandbox で続行します（この worker は OS sandbox の外で走ります）。" >&2
      SANDBOX_ON=0
    else
      scribe_die "sandbox deps 欠如で worker を sandbox 化できません（default-on・sc-u53）: ${_preflight_reason}
  対処のいずれか:
    (1) deps を入れる（bubblewrap / socat / userns 緩和。手順は $SCRIPT_DIR/sandbox-spike/README.md）。
    (2) この host で非 sandbox 実行を意図するなら SCRIBE_SANDBOX=0 を明示する（1 回限りの opt-out）。
    (3) この host で恒久的に『deps 欠如時は警告付き非 sandbox』にするなら SCRIBE_SANDBOX_FALLBACK=1 を置く。"
    fi
  fi
fi

# --- worker-immutable な signal を CC プロセス env へ注入（sc-649・全 worker 無条件） ---
# edit-write-guard.py（PreToolUse[Edit|Write|NotebookEdit|MultiEdit]）は SCRIBE_WORKER=1 のときだけ発火し、
# 書込み先を SCRIBE_WORKTREE（= この worktree 絶対パス）の外なら exit2 で block する（bwrap は Bash のみ封じ
# built-in ファイル編集は素通し＝security-audit SBX-ESC-1）。両 env は worker が改変できない（Bash の export は
# hook が継承する CC プロセス env に効かない）＝**活性化も境界も worker-immutable**（git 構造を信用すると worker が
# `<worktree>/.git` を非再帰 rm して境界を anchor へ広げられる＝gate round2 の boundary escalation を排除）。
# **sandbox on/off に依らず全 worker へ無条件注入**（opt-out でも Edit/Write は worktree に縛る＝host 依存ゼロの
# path guard・かつ opt-out と既定の spawn 行は等しく --env-file を持ち byte 不変）。env-file は anchor/worktree を
# 汚さない /tmp に作り spawn 後 rm（cld-spawn が wait-ready 後に返る＝launcher が source 済みゆえ安全・consult と
# 同式）。**`git worktree add` より前**に mktemp する＝mktemp 失敗で orphan worktree を作らない（gate round2 minor）。
WORKER_ENV_FILE="$(mktemp /tmp/scribe-worker-XXXXXX.env)" || scribe_die "worker env-file の作成に失敗しました（mktemp）"
trap 'rm -f "$WORKER_ENV_FILE"' EXIT   # 異常終了でも /tmp に残さない
# cld-spawn は env-file を **shell source** する（dotenv parse でない）ため、パス値は %q で source-safe に
# エスケープする（空白/メタ文字入り worktree パスでの語分割による境界破壊・$()/backtick の source-time
# インジェクションを防ぐ・gate round3）。%q は source 時に原値へ復元される。
# **ホスト既定 env-file を chain-source する**（gate round4）: cld-spawn の env-file 解決は排他（--env-file を
# 渡すと `${CLD_ENV_FILE:-$HOME/.cld-env}` の既定 source を置換する）。worker は隔離対象ではなく、従来
# --env-file 無しで既定 env（認証/秘密＝session plugin CLAUDE.md 規約）を source していた。その挙動を保つため
# 既定 env-file を先に chain-source してから SCRIBE signal を export する（source 対象は host 所有の信頼ファイル）。
_worker_def_env="${CLD_ENV_FILE:-$HOME/.cld-env}"
# 先頭チルダを $HOME へ展開する（cld-spawn:278 の既定 env 解決と parity）。%q は `~` をエスケープするため、
# CLD_ENV_FILE がリテラル `~`（例: quoted export・systemd/docker env 定義）を含むと展開されず既定 env を
# 無音で取りこぼす（認証/秘密喪失の狭域再導入・gate round5）。source する前にここで展開しておく。
_worker_def_env="${_worker_def_env/#\~/$HOME}"
{
  [[ -n "$_worker_def_env" ]] && printf 'source %q 2>/dev/null || true\n' "$_worker_def_env"
  printf 'export SCRIBE_WORKER=1\nexport SCRIBE_WORKTREE=%q\n' "$WORKTREE"
  # sc-dc9: worker の実効 effort を CC **正規名** CLAUDE_CODE_EFFORT_LEVEL で後勝ち注入する。chain-source した
  # ホスト既定 env に同名があっても後に置く＝上書きする（settings.json の "effortLevel":"xhigh" 無差別波及を止める
  # のがこの issue の核）。**CLAUDE_EFFORT は CC が読まない非正規名で silent no-op**（CC 正規 precedence = --effort
  # フラグ > CLAUDE_CODE_EFFORT_LEVEL env > settings.effortLevel > model 既定）ゆえ絶対に使わない。値は allowlist
  # 検証済み（low|medium|high|xhigh|max）だが、SCRIBE_WORKTREE と対称に %q で source-safe に焼く。
  printf 'export CLAUDE_CODE_EFFORT_LEVEL=%q\n' "$EFFORT"
  # sc-rvq: worker を admin と同一アカウントで起こす。chain-source した ~/.cld-env の後に置き後勝ちにする
  #（set→export CLAUDE_CONFIG_DIR / unset→`unset`＝~/.cld-env 混入への fail-closed）。emit で worker/consult 共通化。
  emit_config_dir_envline
} > "$WORKER_ENV_FILE"

git -C "$REPO" worktree add -b "$BRANCH" "$WORKTREE" "$BASE"

# --- origin 健全性ガード: canonical origin を per-worktree marker へ捕捉（un-1n1・protocol.md §1/§5）---
# worker が共有 .git/config の origin を mutate しても、admin が gate 時（§5）にこの marker と照合して
# 汚染を検知・復元できるようにする。捕捉失敗（origin 無し等）は spawn を止めない（best-effort・warn のみ）。
if scribe_capture_origin "$REPO" "$WORKTREE"; then
  _origin_marker="$(scribe_origin_marker_path "$WORKTREE" 2>/dev/null || true)"
  if [[ -n "${_origin_marker:-}" && -f "$_origin_marker" ]]; then
    echo "origin captured: $(cat "$_origin_marker")（marker=$_origin_marker・gate §5 verify 用）"
  fi
else
  echo "scribe: warn: origin の捕捉に失敗（gate §5 の origin 健全性 verify が skip される）: worktree=$WORKTREE" >&2
fi

# --- sandbox materialization（既定 on・opt-out=SCRIBE_SANDBOX=0・sc-1gu/sc-u53）: worker を OS レベル bwrap sandbox に封じる ---
# git worktree add 済みの worktree に .claude/settings.local.json を生成し、worker(cwd=worktree)の
# Bash subprocess を「自 worktree + 共有 .git + anchor の .beads + bdw 鍵($HOME/.cache/bdw-locks)」へ限定する。
# CLD_PATH/cld-spawn/launcher は一切触らない＝spawn 行は sandbox 有無で byte 不変。前提=bubblewrap +
# socat + userns（apparmor profile / sysctl いずれか）。**deps 欠如はこのブロックの前の dep-preflight が
# 既に処理済み**（fail-loud で停止 or SCRIBE_SANDBOX_FALLBACK=1 で SANDBOX_ON=0 へ降格）＝ここに来る時点で
# SANDBOX_ON=1 なら deps は充足している。
if [[ "$SANDBOX_ON" == "1" ]]; then
  # "1" の文字列比較（[[ -eq ]] の算術評価は非数値で die・算術インジェクションを許すため避ける）。
  mkdir -p "$WORKTREE/.claude" || scribe_die "sandbox: .claude ディレクトリ作成に失敗（sandbox 既定 on・opt-out=SCRIBE_SANDBOX=0）: $WORKTREE"
  # 一時ファイルへ生成し成功時のみ atomic mv（gen が途中失敗しても半端な settings を残さない）。
  # 真の "$ANCHOR"（--anchor で正規化済み絶対パス）を gen へ**明示**渡す（sc-lkg）。cross-repo cell
  # （--repo X --anchor Y・X≠Y）では worktree は repo X 側ゆえ gen の逆算 anchor=X になり allowWrite が
  # 誤った .beads を grant してしまう（真の bd graph=Y へ書けず worker の bdw が read-only で失敗）。
  _sb_tmp="$(mktemp "$WORKTREE/.claude/.settings.XXXXXX")" || scribe_die "sandbox: 一時ファイル作成に失敗: $WORKTREE/.claude"
  if "$SANDBOX_GEN" "$WORKTREE" "$ANCHOR" > "$_sb_tmp"; then
    mv -f "$_sb_tmp" "$WORKTREE/.claude/settings.local.json"
  else
    # gen 失敗時は worktree add 済み＝orphan が残る。cld-spawn 失敗路（下記）と対称に、真因ヒントと cleanup を案内して
    # fail-loud する（defense-in-depth: 最頻 trigger〔plugin/jq 不在〕は preflight が worktree add 前に止めるが、ここに
    # 来た場合も orphan path・真因・復旧コマンドを surface して no-force 保守姿勢と整合させる）。
    rm -f "$_sb_tmp"
    {
      echo "scribe: error: sandbox settings.local.json の生成に失敗（gen-sandbox-settings.sh・sandbox 既定 on・opt-out=SCRIBE_SANDBOX=0）。"
      echo "scribe: 真因の候補: jq 不在 / canonical bdw（beads-bdw plugin）未配備で 'scripts/bdw lock-file' 失敗（sc-vae/sc-mcx cutover で gen の spawn-time 依存＝OG-4 で lock-dir から lock-file consume へ）。通常は preflight が両者を worktree add 前に検出する。"
      echo "scribe: worktree が orphan として残っています（自動削除はしません＝force 禁止・確認必須ポリシー）: $WORKTREE"
      echo "scribe: 掃除するには（force 系を使わない確認プロンプト付き cleanup）:"
      echo "         $SCRIPT_DIR/scribe-cleanup.sh --repo \"$REPO\" --worktree \"$WORKTREE\" --branch \"$BRANCH\" --window \"$WINDOW\" $ID"
    } >&2
    exit 1
  fi
  # --- FO-2(sc-7oj): 生成した settings が実際に sandbox を強制するキーを持つか実行時アテステーション ---
  # gen が（SCRIBE_SANDBOX_GEN stub 差替え / 手編集 drift で）valid JSON だが強制キーを欠く settings を吐いても、
  # materialize して worker を「sandbox 済み」と信じたまま起動すれば silent fail-open になる（安全性が CC の
  # settings honor 任せである以上、少なくとも我々が置いたファイルの enforcing 不変条件は launch 前に自分で確かめる）。
  # enabled=true / failIfUnavailable=true / allowUnsandboxedCommands=false を assert し、破れたら fail-loud で
  # 停止する（黙って非 sandbox worker を起動しない）。CC 本体が settings を honor するか自体（version/precedence
  # drift）はここでは検証不能＝実 e2e verify(sc-7n1) と脅威モデルの正直な文書化(sc-451)の領分。jq はこの経路へ
  # 到達する時点で必ず在る（gen が jq 依存で先に die）が、防御的に存在を確認してから使う。
  if command -v jq >/dev/null 2>&1; then
    if ! jq -e '.sandbox.enabled == true and .sandbox.failIfUnavailable == true and .sandbox.allowUnsandboxedCommands == false' \
         "$WORKTREE/.claude/settings.local.json" >/dev/null 2>&1; then
      scribe_die "sandbox 実行時アテステーション失敗: 生成した settings.local.json が sandbox 強制キー（enabled=true / failIfUnavailable=true / allowUnsandboxedCommands=false）を満たしません（gen 破損 / stub drift?）。黙って非 sandbox worker を起動しないため停止します。
  worktree が orphan として残っています（自動削除はしません＝force 禁止・確認必須ポリシー）: $WORKTREE
  掃除するには: $SCRIPT_DIR/scribe-cleanup.sh --repo \"$REPO\" --worktree \"$WORKTREE\" --branch \"$BRANCH\" --window \"$WINDOW\" $ID
  settings: $WORKTREE/.claude/settings.local.json"
    fi
  fi
  # 生成した settings.local.json を ephemeral に保つ（worker の stage に巻き込まない・sc-1gu）。info/exclude は
  # 共有 common-dir へ冪等追記する（scribe-lib の単一実装＝本番と test で drift しない）。CC sandbox が cwd の
  # 既知 dotfile/.claude 設定を /dev/null device 化する件（sc-yqa）は info/exclude でなく scribe-add（型で弾く
  # stage ラッパ）が担う＝CC のリスト churn に無関係・共有 exclude の広い漏れを避ける（E→B 切替・sc-yqa grill）。
  scribe_sandbox_write_exclude "$WORKTREE"
  # bwrap が allowWrite path を bind 前に存在要求しうる（deduced・sc-da0）。gen が grant した書込み許可 path を
  # worker 起動前に事前生成する。allowWrite は 2 種を含み、pre-create の作法が異なる:
  #  (1) bdw の flock 鍵 = **file**（OG-4・sc-mcx で lock dir 丸ごとから file 単位へ狭化）。canonical bdw の
  #      `exec 9>"$lock_file"`(O_TRUNC)は不在 file には parent dir write を要すが、file 単位 grant では親 dir を
  #      grant しないため、ここで parent(lock dir)を mkdir し file を **touch** で先在させる（`mkdir -p` では file
  #      を dir 化してしまい flock が Is-a-directory で壊れる＝専用 touch が要る）。repo_id 導出は複製せず gen と
  #      同一の `bdw lock-file` を consume する（subshell `(cd "$ANCHOR" && bdw lock-file)` で worker の bd write
  #      と同一 invocation にする＝repo_id は cwd 依存で BDW_REPO_DIR override は効かない・verified。cross-repo cell
  #      でも worker が使う鍵と byte 一致・gen と drift しない）。
  #  (2) .beads runtime サブパス = file と dir の混在（gen-sandbox-settings.sh が present な .beads/* を grant する＝
  #      interactions.jsonl 等の **file** と embeddeddolt/ 等の **dir**）。gen は present エントリのみ列挙する契約ゆえ
  #      established anchor では全て既在＝**存在すれば file/dir 問わず bwrap bind-safe** なので触れない。旧実装は
  #      これらに一律 `mkdir -p` していたが、それは (a) 不在 file 位置に **dir を作り .beads を破損**しうる（例:
  #      interactions.jsonl の場所に dir・sc-0nb (a)）・(b) 既存 file には "File exists" warn を **毎 spawn** 吐く
  #      （sc-0nb (b)）という二重の害があった。よって「既存なら skip・不在なら自動生成せず fail-loud warn」に改める
  #      （種別不明の leaf を作らない＝破損を構造的に排除）。lock file は (1) で touch 済みゆえ **除外**する。
  _sb_lock_file="$(cd "$ANCHOR" && "$SCRIPT_DIR/bdw" lock-file 2>/dev/null)" || _sb_lock_file=""
  if [[ -n "$_sb_lock_file" ]]; then
    if ! { mkdir -p "$(dirname "$_sb_lock_file")" 2>/dev/null && touch "$_sb_lock_file" 2>/dev/null; }; then
      echo "scribe: warn: sandbox lock 鍵 file の pre-create（parent mkdir + touch）に失敗（worker 起動が failIfUnavailable で止まりうる）: $_sb_lock_file" >&2
    fi
  fi
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r _sb_aw; do
      [[ -n "$_sb_aw" && "$_sb_aw" != "$_sb_lock_file" ]] || continue
      # 既存パス（file/dir どちらでも）は bwrap bind-safe ゆえ何もしない。gen が present な .beads/* のみを grant
      # する契約下では established anchor で常にここへ入り、旧 `mkdir -p <file>` が毎 spawn 吐いていた "File exists"
      # スケア警告を構造的に消す（sc-0nb (b)）。
      [[ -e "$_sb_aw" ]] && continue
      # 不在は gen 契約（present のみ grant）下では通常起きない異常。file/dir 種別が不明ゆえ `mkdir` で dir を作ると
      # 本来 file の runtime パス（interactions.jsonl 等）を dir 化して .beads を破損しうる（sc-0nb (a)）。安全側で
      # leaf は自動生成せず fail-loud に warn する（bwrap bind 失敗＝worker が failIfUnavailable で気付く ＞ 黙って破損）。
      echo "scribe: warn: sandbox allowWrite path が不在です（gen は present のみ grant するはず・種別不明ゆえ自動生成せず。worker 起動が failIfUnavailable で止まりうる）: $_sb_aw" >&2
    done < <(jq -r '.sandbox.filesystem.allowWrite[]?' "$WORKTREE/.claude/settings.local.json" 2>/dev/null || true)
  fi
  echo "sandbox: worker を bwrap sandbox に封じます（既定 on・opt-out=SCRIBE_SANDBOX=0・settings=$WORKTREE/.claude/settings.local.json）"
fi

PROMPT_TEXT="$(build_prompt)"

# cld-spawn 失敗時の扱い（sc-vuu facet3）: worktree は既に `git worktree add` 済み（上記）。
# **自動 rollback はしない**——破壊操作ポリシー（force 禁止・確認必須）の例外を作らないため
# （自動削除 trap / ハイブリッドは却下）。代わりに orphan worktree を残し、orphan path と
# scribe-cleanup.sh 復旧コマンドを stderr に明示して cld-spawn の exit code で fail-loud する
# （掃除は admin が scribe-cleanup.sh で確認の上 = no-force 保守姿勢と整合）。
# `|| _rc=$?` で実 exit code を捕捉（set -e 下でも中断させず、案内を出してから伝播）。成功時は
# 下記案内を出さず従来の "spawned:" 経路へ抜ける＝happy-path 出力は byte 不変。
_cld_rc=0
# --disallowed-tools は 1 argv verbatim（"$WORKER_DISALLOWED_TOOLS" を分割せず）で透過する（orch-4dm / H5・
# 上記定数コメント参照＝分割 fail-open は cc-session gate round-1 で CONFIRMED）。cld-spawn は末尾 PROMPT の
# 直前でこれを消費する（cld-spawn は --disallowed-tools を claude の末尾可変長 <tools...> として自身の起動行
# 末尾へ再配置するため、scribe 側の引数順は PROMPT 前であれば可）。
"$CLD_SPAWN" --cd "$WORKTREE" --bd-id "$ID" --model "$MODEL" "${CLD_EFFORT_ARG[@]}" --disallowed-tools "$WORKER_DISALLOWED_TOOLS" --env-file "$WORKER_ENV_FILE" "$PROMPT_TEXT" || _cld_rc=$?
if [[ "$_cld_rc" -ne 0 ]]; then
  {
    echo "scribe: error: cld-spawn が失敗しました（exit=$_cld_rc）。worker は起動していません。"
    echo "scribe: worktree が orphan として残っています（自動削除はしません＝force 禁止・確認必須ポリシー）: $WORKTREE"
    echo "scribe: 掃除するには（force 系を使わない確認プロンプト付き cleanup）:"
    echo "         $SCRIPT_DIR/scribe-cleanup.sh --repo \"$REPO\" --worktree \"$WORKTREE\" --branch \"$BRANCH\" --window \"$WINDOW\" $ID"
  } >&2
  exit "$_cld_rc"
fi

# monitor: window 名 → window_id(@N) を解決し、以後の -t は ID で行う（protocol.md §1）。
# cld-spawn 成功後の monitor 案内用。tmux 不在/失敗でも spawn は済んでいるので set -e で落とさず
# 空 WID へ degrade させる（|| true）。空なら下の ${WID:-$WINDOW} が window 名へフォールバック。
WID="$(scribe_window_id "$WINDOW")"
echo "spawned: issue=$ID window=$WINDOW window_id=${WID:-?} worktree=$WORKTREE"
# sc-w5e: dry-run 側 MONITOR_CMD と同一 builder（monitor_cmd_for）で emit する（sentinel 配線 + 12 行窓の
# 契約を 2 箇所で個別に持たない）。こちらは WID 解決済みゆえ実値（@N or 名前フォールバック）を埋め込む。
echo "monitor: $(monitor_cmd_for "${WID:-$WINDOW}")"

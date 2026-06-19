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
#     - anchor（cwd）で `cld-spawn --model opus --env-file <SCRIBE_ROLE=consult> "<consult テンプレ本文>"`。
#       consult テンプレは read-only 規律・記憶系のみ write・サマリ保存義務のみ（bdw/selftest/cell-quality を含まない）。
#     - SCRIBE_ROLE=consult を --env-file で注入（C2 の role 判定が最優先で読む side）。env-file は
#       **anchor working tree の外**（/tmp）に作り spawn 後に rm する＝anchor リポを汚さない（read-only 起動器の自浄）。
#     - model は基本 opus・ユーザー指定時のみ fable 可（role-context-spec §2.3 の唯一の fable 例外。worker は fable 厳禁）。
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
#   --consult       consult role セッションを anchor で起動（worktree/worker prompt なし・SCRIBE_ROLE=consult を --env-file 注入）
#   --context FILE  consult 専用。admin 集約 brief（FILE 内容）を grill 材料として焼き込み grill-consult モードへ。
#                   §7 needs-user regime: grill-issue id 必須。grill-consult は brief を出発点にユーザーと対話 grill し、
#                   決定を own grill-issue の bd notes へ書く（bdw 経由 --claim/--append-notes のみ・read-only 限定緩和）。
#                   （pre-bake 自体は admin が回す dynamic Workflow = workflows/needs-user-prebake.workflow.js へ移管。）
#   --model MODEL   cld-spawn のモデル（既定: opus）。worker は fable 厳禁＝コスト爆発。
#                   consult は基本 opus・ユーザー指定時のみ fable 可（role-context-spec §2.3 の例外）
#   --dry-run       実行するはずのコマンド列を arg-echo するだけ（実 spawn しない）
#   -h | --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
# shellcheck source=./lib/scribe-lib.sh
source "$SCRIPT_DIR/lib/scribe-lib.sh"

# cld-spawn の所在（テスト時は SCRIBE_CLD_SPAWN でスタブ差し替え）。
CLD_SPAWN="${SCRIBE_CLD_SPAWN:-$HOME/.claude/plugins/session/scripts/cld-spawn}"

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
  --consult       consult role セッションを anchor で起動（worktree/worker prompt なし）
  --context FILE  consult 専用。admin 集約 brief（FILE）を grill 材料として焼き込み grill-consult モードへ（§7・grill-issue id 必須）。
                  grill-consult は brief を grill し決定を own grill-issue の bd notes へ書く（bdw 経由・read-only 限定緩和）
  --model MODEL   cld-spawn のモデル（既定: opus）。worker は fable 厳禁＝コスト爆発。
                  consult は基本 opus・ユーザー指定時のみ fable 可（role-context-spec §2.3 の例外）
  --dry-run       実行するはずのコマンド列を arg-echo するだけ（実 spawn しない）
  -h | --help
EOF
  exit "${1:-0}"
}

REPO="$(pwd)"
BASE="HEAD"
ANCHOR="$(pwd)"
CONSULT=0
MODEL="opus"
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
    --consult) CONSULT=1; shift ;;
    --context) scribe_need_val "${2:-}" --context; CONTEXT_FILE="$2"; shift 2 ;;
    --model)   scribe_need_val "${2:-}" --model; MODEL="$2"; shift 2 ;;
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

# fable の許否は role で非対称（道具は規約を変えない）:
#   - worker: fable 厳禁（protocol.md §1: worker は opus 必須＝コスト爆発防止）。worker 分岐内で die する。
#   - consult: fable は **許容**（role-context-spec §2.3: 基本 opus・ユーザー指定時のみ fable。
#     consult は admin と同じ main-loop 系統ゆえ fable 起動が許される唯一の例外）。
# ＝この一括 die をここに置くと consult の例外パスを塞いで規約を変えてしまうため、
#   worker 分岐の入口へ移動する（下記）。

# ===========================================================================
# consult モード（--consult）: role-context-spec §2.3 / design §14 の契約どおりに分岐。
#   worktree 作成・worker prompt 生成・--bd-id を **一切しない**（consult に spawn worktree は禁止）。
#   anchor で `cld-spawn --cd <anchor> --model opus --env-file <SCRIBE_ROLE=consult> "<consult テンプレ>"` を出す
#   （--cd は anchor=cwd を指す＝worktree ではない）。
#   bd id は consult では任意の議題参照（read-only な実在検証のみ・worktree/branch には焼かない）。
# ===========================================================================
if [[ "$CONSULT" -eq 1 ]]; then
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
  fi

  # consult テンプレ本文（role-context-spec §2.3）= 設計議論/grill 専用・read-only 規律・記憶系のみ write・サマリ保存義務。
  # **worker prompt（worktree 拘束 / bdw / selftest / cell-quality / bd close）は一切含めない**（role 契約）。
  # --context 指定時は末尾に grill-consult 任務（admin 集約 brief 焼き込み + bd notes handoff 規約）を追記する（§7）。
  build_consult_prompt() {
    # 役割節の bd id 行は mode で意味が変わる: grill-consult（--context 指定）では $TOPIC は
    # 担当 grill-issue（下記 grill-consult 任務で claim し決定 notes を書く＝read-only 観測ではない）、
    # 素 consult では read-only な議題参照。heredoc 内で分岐できないため事前に文字列を組む。
    local _topic_line=""
    if [[ -n "$TOPIC" ]]; then
      if [[ -n "$CONTEXT_FILE" ]]; then
        _topic_line="- 担当 grill-issue: \`bd show $TOPIC\`（下記 grill-consult 任務で claim し決定 notes を書く＝read-only 観測ではない）。"
      else
        _topic_line="- 議題参照（read-only）: \`bd show $TOPIC\`（観測のみ。worktree 仕事はしない）。"
      fi
    fi
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
    # --- grill-consult 任務の追記（--context 指定時のみ・§7 needs-user regime・sc-cuw 再編）---
    # --context は「焼いて死ぬ pre-bake」から「grill 材料を受け取る grill-consult」へ意味が変わった
    # （pre-bake 自体は admin が回す dynamic Workflow へ移管・consult から撤去）。grill-consult は brief を
    # 出発点にユーザーと **対話 grill** し、確定した決定を own grill-issue の bd notes へ書く（bdw 経由）。
    if [[ -n "$CONTEXT_FILE" ]]; then
      cat <<GRILL

## 【grill-consult 任務】§7 needs-user regime（admin から grill-issue を割り当てられた第 2 対話相手）
admin が下記 brief（pre-bake WF の集約出力）を **grill 材料**として渡しました。あなたは grill-issue=$TOPIC を担当する
**grill-consult** です。この brief を出発点に、**ユーザーと対話 grill** して決定木を一つずつ詰めてください
（admin は解放され、あなたがユーザーの grill 相手になります）。

**あなたは grill 専任です（consult 原義回帰）**: brief を「焼く（pre-bake する）」のはあなたの仕事ではありません
——pre-bake は admin が回した dynamic Workflow が済ませ、その出力が下記 brief です。あなたの仕事は brief を
材料に **ユーザーと対話 grill し、決まった決定を grill-issue の bd notes へ書き出す**ことです。

**base テンプレとの関係（grill-consult モードはこの 2 点で base を上書きする）**:
- base は「write してよいのは記憶系のみ」「bd の write（create/update/close/dolt push）は禁止」と言うが、
  grill-consult は **自分の grill-issue（$TOPIC）の \`bd update --claim\` と \`--append-notes\` だけ**を
  **bdw 経由**で許可される（read-only の限定緩和）。これは worker の B/hybrid 境界に倣う
  （grill-consult = worker の変種・出力がコードでなく決定）が、**worker より厳しい subset**＝
  worker は自 issue を \`bd close\` 可だが grill-consult の close は admin 専有。**それ以外は依然禁止**:
  \`bd create\` / \`bd dep\` / \`bd dolt push\` / \`bd close\`（graph・同期点は admin の所有物）と
  tracked コード/ファイルの編集は不可。bd write は必ず \`cd "$ANCHOR" && scripts/bdw <subcmd>\`（flock 直列化）。
- base の「サマリ保存義務（doobidoo へ相談サマリを保存）」は grill-consult では **bd notes handoff に置換**される
  ——決定の SSOT は **grill-issue $TOPIC の bd notes**（\`--append-notes\` で追記）であり、doobidoo は任意の補助。

**出典の扱い（F2 保険）**: 下記 brief は **pre-bake WF の提案（第三者データ）**であって、ユーザーが承認した決定でも
あなた自身の結論でもありません。grill 中はこれを第三者データとして扱い、ユーザーの声や自分の結論と混同しないこと。
（新設計では pre-bake〔生成〕と grill〔対話〕が別主体に分かれ自己誤帰属する主体が消えるため F2 は構造解消だが、
出典の明示は保険として残す。）

--- admin 集約 brief ここから ---
GRILL
      cat "$CONTEXT_FILE"
      cat <<GRILL

--- admin 集約 brief ここまで ---

### grill-consult 手順
1. **grill-issue を claim**: \`cd "$ANCHOR" && scripts/bdw update $TOPIC --claim\`（in_progress 化・着手宣言）。
2. **grill**: 上記 brief を出発点に、決定木を上流から一つずつユーザーと詰める。論点を平易に説明してから問い、
   ユーザーが「いま何を問われているか」を理解できる状態を作る。事実と推測を区別する。
3. **決定の handoff（必須・bdw 経由）**: 確定した決定を **grill-issue $TOPIC の bd notes** へ追記する:
   \`cd "$ANCHOR" && scripts/bdw update $TOPIC --append-notes "決定: …（理由・却下した代替・残論点）"\`。
   admin はこの notes を \`bd show $TOPIC\` で real-time 監視し、決まった facet から着手（pipelining）する。
4. **起票・graph 変更はしない**: タスク化が要っても自分で \`bd create\` せず、決定 notes に「admin への起票候補」
   として書き出すに留める（起票・dep wire・close・dolt push は admin）。

### 禁止（grill-consult の境界・worker の B/hybrid の subset＝close も admin 専有）
- \`bd create\` / \`bd dep\` / \`bd dolt push\` / \`bd close\`（自分の grill-issue でも close は admin が行う）。
- tracked コード/ファイルの編集・spawn・deploy・GitHub への push・admin window への tmux inject。
- 共有 \`.git/config\`（remotes/hooks/config）の mutate（anchor 同居ゆえ汚すと admin の push が壊れる）。
GRILL
    fi
  }

  # env-file は **anchor working tree の外**（/tmp 配下）に作る。anchor は admin orchestrator の cwd で
  # あり、そこに artifact を残すと anchor リポを汚し誤コミット経路になる（道具自身が read-only 契約の
  # 起動器なのに anchor を汚す非対称を避ける）。cld-spawn は env-file を launcher へ source 済みなので
  # spawn 後に rm して消える＝anchor に何も残さない。dry-run は実ファイルを作らずパスだけ案内する。
  ENV_LINE="export SCRIBE_ROLE=consult"
  # consult は --bd-id を渡さない設計のため、放置すると cld-spawn の window 名が汎用命名（git 状態由来の
  # wt-<repo>-<branch>-…）へ落ち、fleet-monitor/人間が consult を判別できない（admin C5 live finding・un-01h）。
  # window 名は consult-HHMMSS（毎回新規）にし prefix `consult-` で識別する。固定 `consult` は cld-spawn の
  # find_existing_window が完全一致で既存 window を reuse → exit 0（偽成功・env-file 非 source で
  # SCRIBE_ROLE=consult 未注入）する fail-open を招く（gate wf_d3777d26 CONFIRMED）。あわせて --force-new で
  # reuse 経路を構造的に封鎖し、能動起動の入口が必ず新セッションを立てることを保証する。
  CONSULT_WINDOW="consult-$(date +%H%M%S)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    if [[ -n "$CONTEXT_FILE" ]]; then
      echo "[plan] scribe-spawn(consult): anchor=$ANCHOR grill-issue=$TOPIC（grill-consult モード）"
      echo "[plan] grill-consult モード（§7）: brief=$CONTEXT_FILE を grill 材料として焼き込み・grill-issue=$TOPIC"
      echo "[plan]   handoff 規約 → 決定は grill-issue $TOPIC の bd notes（bdw 経由 --claim/--append-notes のみ・read-only 限定緩和）。admin は bd show $TOPIC で監視"
    else
      echo "[plan] scribe-spawn(consult): anchor=$ANCHOR${TOPIC:+ 議題参照=$TOPIC（read-only）}"
    fi
    echo "[plan] env-file（anchor 外＝anchor リポを汚さない・spawn 後 rm）:"
    echo "         ENV_FILE=\$(mktemp /tmp/scribe-consult-XXXXXX.env)"
    echo "         printf '%s\\n' '$ENV_LINE' > \"\$ENV_FILE\""
    echo "[plan] $CLD_SPAWN --cd $ANCHOR --model $MODEL --window-name $CONSULT_WINDOW --force-new --env-file \"\$ENV_FILE\" \"<consult テンプレ本文>\""
    echo "[plan] rm -f \"\$ENV_FILE\"   # source 済みなので spawn 後に消す（anchor に残さない）"
    echo "[plan] (consult は worktree を作らない / --bd-id を渡さない / worker prompt を出さない＝role 契約)"
    echo "[plan] window 名 = --window-name $CONSULT_WINDOW（毎回新規・prefix consult- で識別）+ --force-new（reuse 経路封鎖=偽成功/SCRIBE_ROLE 未注入防止・un-01h gate）"
    echo "[plan] --- consult テンプレ（role-context-spec §2.3）---"
    build_consult_prompt | sed 's/^/         | /'
    exit 0
  fi

  # ===== consult 実行（real）=====
  ENV_FILE="$(mktemp /tmp/scribe-consult-XXXXXX.env)" || scribe_die "env-file の作成に失敗しました（mktemp）"
  trap 'rm -f "$ENV_FILE"' EXIT   # 異常終了でも /tmp に残さない
  printf '%s\n' "$ENV_LINE" > "$ENV_FILE"
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

# --- 3. task prompt 生成（protocol.md §2）---
build_prompt() {
  cat <<PROMPT
あなたは scribe worker cell（issue $ID）。この issue を end-to-end で完遂する。応答は日本語。

## 契約（SSOT）
- 契約 = bd issue の description: \`cd "$ANCHOR" && bd show $ID\`（着手前に必ず読む。bd graph 所在 = anchor $ANCHOR・worktree からは解決しない）。
- 配置: worktree（= cwd）$WORKTREE — **ここから出ない**（bd graph 参照のための anchor への一時 cd は除く）。branch=$BRANCH / window=$WINDOW。

## 規律（docs/protocol.md §2/§3）
- **test-first**: 実装に対する self-test を自分で用意し worktree 直下に置く
  （\`selftest-$ID.local.sh\`・untracked・コミットしない・**fail-closed**＝assert 1 つでも落ちたら非 0）。
- **cell-quality WF を直接呼出**（named-WF 明示・scriptPath 直指定）で gate review/verify を 1 回回す。
  自己点検 args は \`scripts/scribe-selftest-args.sh --worktree "$WORKTREE" --anchor "$ANCHOR" --self-test <selfTestCmd> $ID\` で 1 コマンド化済み
  （\`doImplement\`/\`doPlan\`=false・\`autoFix\`=true・\`selfTestCmd\` 必須を固定。手作業で args を組まない。**\`--anchor\` は必須**＝bd graph 所在は worktree cwd では解決しないため省くと die）。
- **報告に WF 返り値 JSON + \`receivedArgs\` を必須**で含める（args 解決の成否を admin が一次監査できるように）。
- bd write は必ず \`bdw\` 経由で直列化: \`cd "$ANCHOR" && scripts/bdw <subcmd>\`（自 issue の進捗のみ）。

## 禁止（protocol.md §2/§3）
- \`bd create\` / \`bd dep\` / assignment / \`bd dolt push\`（graph・同期点は admin の所有物）。
- GitHub への push（admin が gate 後）/ admin window への tmux inject / 編集可スコープ外の編集。
- **共有 \`.git/config\`（remotes / hooks / config 等）を mutate しない**: worktree は anchor と \`.git/config\` を **共有** するため、worker が origin/remote を書き換えると anchor+全 worktree の origin が壊れ admin の push が破綻する（un-1n1 実害）。remote 検証が要るなら **throwaway bare repo / 別 clone** を使う（\`remote.*\` は git が共有 config からのみ読むため \`git config --worktree\` でも隔離できない＝検証済み・物理隔離は →un-6nf）。
- **follow-up の bd create**: 起票が要っても自分で起票せず自 issue の notes に「admin への起票候補」として書く。
PROMPT
}

# --- monitor 起動コマンド（protocol.md §1/§6・window ID @N 参照）---
# WINDOW(wt-<id>) → window_id(@N) を解決してから -t に渡す（dotted id の window.pane 区切り衝突回避）。
# 監視は capture-pane + busy 判定 regex（protocol.md §6）で手動観測する（v0 = 背景 supervisor なし）。
MONITOR_RESOLVE="WID=\$(tmux list-windows -F '#{window_id} #{window_name}' | awk -v n='$WINDOW' '\$2==n{print \$1; exit}')   # → @N"
MONITOR_CMD="tmux capture-pane -p -t \"\$WID\" | tail -n 3   # busy regex: '… \\(|esc to interrupt|agents [0-9/ ]*(done|running)|tokens'"

emit_plan() {
  echo "[plan] scribe-spawn: issue=$ID（実在検証 OK）"
  echo "[plan] git -C $REPO worktree add -b $BRANCH $WORKTREE $BASE"
  [[ "${SCRIBE_SANDBOX:-0}" == "1" ]] && echo "[plan] sandbox: $WORKTREE/.claude/settings.local.json を生成（SCRIBE_SANDBOX=1・bwrap 外壁。CLD_PATH/launcher は不変＝本番経路 byte 同一）"
  echo "[plan] scribe_capture_origin $REPO $WORKTREE   # canonical origin を per-worktree marker へ捕捉（un-1n1・gate §5 verify 用）"
  echo "[plan] $CLD_SPAWN --cd $WORKTREE --bd-id $ID --model $MODEL \"<task prompt>\""
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

# --- sandbox opt-in（SCRIBE_SANDBOX=1・sc-1gu）: worker を OS レベル bwrap sandbox に封じる ---
# git worktree add 済みの worktree に .claude/settings.local.json を生成し、worker(cwd=worktree)の
# Bash subprocess を「自 worktree + 共有 .git + anchor の .beads + bdw 鍵($XDG_RUNTIME_DIR)」へ限定する。
# CLD_PATH/cld-spawn/launcher は一切触らない＝opt-in 未指定時は本番経路 byte 不変。前提=bubblewrap +
# socat + apparmor_restrict_unprivileged_userns=0。依存欠如時は failIfUnavailable で worker が起動拒否。
if [[ "${SCRIBE_SANDBOX:-0}" == "1" ]]; then
  # == "1" の文字列比較（[[ -eq ]] の算術評価は非数値で die・算術インジェクションを許すため避ける）。
  mkdir -p "$WORKTREE/.claude" || scribe_die "sandbox: .claude ディレクトリ作成に失敗（SCRIBE_SANDBOX=1）: $WORKTREE"
  # 一時ファイルへ生成し成功時のみ atomic mv（gen が途中失敗しても半端な settings を残さない）。
  _sb_tmp="$(mktemp "$WORKTREE/.claude/.settings.XXXXXX")" || scribe_die "sandbox: 一時ファイル作成に失敗: $WORKTREE/.claude"
  if "$SCRIPT_DIR/sandbox-spike/gen-sandbox-settings.sh" "$WORKTREE" > "$_sb_tmp"; then
    mv -f "$_sb_tmp" "$WORKTREE/.claude/settings.local.json"
  else
    rm -f "$_sb_tmp"; scribe_die "sandbox settings.local.json の生成に失敗（SCRIBE_SANDBOX=1）: $WORKTREE"
  fi
  # 生成した settings.local.json を ephemeral に保つ（worker の git add -A で巻き込まない）。repo の
  # tracked .gitignore でなく worktree の git exclude へ冪等追記する＝全マシン/全ユーザー（CI・他ホスト・
  # machine-local ~/.config/git/ignore を持たない環境）でも効かせる。info/exclude は共有 common-dir。
  _sb_excl="$(git -C "$WORKTREE" rev-parse --git-path info/exclude 2>/dev/null || true)"
  if [[ -n "$_sb_excl" ]]; then
    mkdir -p "$(dirname "$_sb_excl")" 2>/dev/null || true
    grep -qxF '**/.claude/settings.local.json' "$_sb_excl" 2>/dev/null \
      || printf '%s\n' '**/.claude/settings.local.json' >> "$_sb_excl"
  fi
  echo "sandbox: worker を bwrap sandbox に封じます（SCRIBE_SANDBOX=1・settings=$WORKTREE/.claude/settings.local.json）"
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
"$CLD_SPAWN" --cd "$WORKTREE" --bd-id "$ID" --model "$MODEL" "$PROMPT_TEXT" || _cld_rc=$?
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
WID="$(tmux list-windows -F '#{window_id} #{window_name}' 2>/dev/null | awk -v n="$WINDOW" '$2==n{print $1; exit}' || true)"
echo "spawned: issue=$ID window=$WINDOW window_id=${WID:-?} worktree=$WORKTREE"
echo "monitor: tmux capture-pane -p -t \"${WID:-$WINDOW}\" | tail -n 3"

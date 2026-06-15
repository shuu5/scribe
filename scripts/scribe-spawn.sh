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
Options:
  --repo PATH     worktree を作る git リポジトリ（worker のみ・既定: cwd）
  --base REF      新 branch の base（worker のみ・既定: HEAD）
  --anchor PATH   bd graph の所在（bd show 用・既定: cwd）。consult はここで起動する
  --consult       consult role セッションを anchor で起動（worktree/worker prompt なし）
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
# REPO/ANCHOR が「既定（cwd）」か「明示指定」かを独立に追う（un-ag7・AC3/AC4）。
# 明示時は linked-worktree ガードを不発火にし、cross-repo cell の意図的 override を壊さない。
REPO_EXPLICIT=0
ANCHOR_EXPLICIT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    [[ -n "${2:-}" ]] || scribe_die "--repo にパスを指定してください"; REPO="$2"; REPO_EXPLICIT=1; shift 2 ;;
    --base)    [[ -n "${2:-}" ]] || scribe_die "--base に ref を指定してください"; BASE="$2"; shift 2 ;;
    --anchor)  [[ -n "${2:-}" ]] || scribe_die "--anchor にパスを指定してください"; ANCHOR="$2"; ANCHOR_EXPLICIT=1; shift 2 ;;
    --consult) CONSULT=1; shift ;;
    --model)   [[ -n "${2:-}" ]] || scribe_die "--model にモデル名を指定してください"; MODEL="$2"; shift 2 ;;
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

  # consult テンプレ本文（role-context-spec §2.3）= 設計議論/grill 専用・read-only 規律・記憶系のみ write・サマリ保存義務。
  # **worker prompt（worktree 拘束 / bdw / selftest / cell-quality / bd close）は一切含めない**（role 契約）。
  build_consult_prompt() {
    cat <<PROMPT
あなたは scribe consult セッション（設計議論・grill 専用の第 2 対話相手）。応答は日本語。
役割と禁止は docs/role-context-spec.md §2.3 が SSOT。

## 役割
- 用途は **設計議論・grill のみ**。オーケストレーション・gate 代行・実装はしない。
${TOPIC:+- 議題参照（read-only）: \`bd show $TOPIC\`（観測のみ。worktree 仕事はしない）。}

## read-only 規律（厳守）
- リポの tracked ファイル・コードを編集しない。bd の write（create/update/close/dolt push）・spawn・deploy は **禁止**。
- 観測は可（read）。タスク化が要っても自分で bd 起票せず、相談サマリに「admin への起票候補」として書き出すに留める（起票は admin）。

## write してよいのは記憶系のみ
- doobidoo（\`mcp__doobidoo__memory_store\`）と auto-memory（\`MEMORY.md\`）への保存だけ許可。

## サマリ保存義務（必須）
- 終了・中断の前に、議論の結論・未解決の論点・admin への起票候補を相談サマリにまとめ doobidoo へ保存する（会話履歴に依存させない）。
PROMPT
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
    echo "[plan] scribe-spawn(consult): anchor=$ANCHOR${TOPIC:+ 議題参照=$TOPIC（read-only）}"
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
  echo "spawned(consult): anchor=$ANCHOR model=$MODEL window=$CONSULT_WINDOW${TOPIC:+ 議題参照=$TOPIC}"
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
- **報告に WF 返り値 JSON + \`receivedArgs\` を必須**で含める（args 解決の成否を admin が一次監査できるように）。
- bd write は必ず \`bdw\` 経由で直列化: \`cd "$ANCHOR" && scripts/bdw <subcmd>\`（自 issue の進捗のみ）。

## 禁止（protocol.md §2/§3）
- \`bd create\` / \`bd dep\` / assignment / \`bd dolt push\`（graph・同期点は admin の所有物）。
- GitHub への push（admin が gate 後）/ admin window への tmux inject / 編集可スコープ外の編集。
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

PROMPT_TEXT="$(build_prompt)"

"$CLD_SPAWN" --cd "$WORKTREE" --bd-id "$ID" --model "$MODEL" "$PROMPT_TEXT"

# monitor: window 名 → window_id(@N) を解決し、以後の -t は ID で行う（protocol.md §1）。
# cld-spawn 成功後の monitor 案内用。tmux 不在/失敗でも spawn は済んでいるので set -e で落とさず
# 空 WID へ degrade させる（|| true）。空なら下の ${WID:-$WINDOW} が window 名へフォールバック。
WID="$(tmux list-windows -F '#{window_id} #{window_name}' 2>/dev/null | awk -v n="$WINDOW" '$2==n{print $1; exit}' || true)"
echo "spawned: issue=$ID window=$WINDOW window_id=${WID:-?} worktree=$WORKTREE"
echo "monitor: tmux capture-pane -p -t \"${WID:-$WINDOW}\" | tail -n 3"

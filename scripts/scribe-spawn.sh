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
#   --consult       consult role セッションを anchor で起動（worktree/worker prompt なし・SCRIBE_ROLE=consult を --env-file 注入）
#   --context FILE  consult 専用。admin 集約 brief（FILE 内容）を grill 材料として焼き込み grill-consult モードへ。
#                   §7 needs-user regime: grill-issue id 必須。grill-consult は brief を出発点にユーザーと対話 grill し、
#                   決定を own grill-issue の bd notes へ書く（bdw 経由 --claim/--append-notes のみ・read-only 限定緩和）。
#                   （pre-bake 自体は admin が回す dynamic Workflow = workflows/needs-user-prebake.workflow.js へ移管。）
#   --model MODEL   cld-spawn のモデル（既定: worker=opus / consult=fable）。worker は fable 厳禁＝コスト爆発。
#                   consult は既定 fable・利用不可時のみ opus へ loud fallback（sc-9q6・role-context-spec §2.3）
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
  --consult       consult role セッションを anchor で起動（worktree/worker prompt なし）
  --context FILE  consult 専用。admin 集約 brief（FILE）を grill 材料として焼き込み grill-consult モードへ（§7・grill-issue id 必須）。
                  grill-consult は brief を grill し決定を own grill-issue の bd notes へ書く（bdw 経由・read-only 限定緩和）
  --model MODEL   cld-spawn のモデル（既定: worker=opus / consult=fable）。worker は fable 厳禁＝コスト爆発。
                  consult は既定 fable・利用不可時のみ opus へ loud fallback（sc-9q6・role-context-spec §2.3）
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
    --model)   scribe_need_val "${2:-}" --model; MODEL="$2"; MODEL_EXPLICIT=1; shift 2 ;;
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
    echo "[plan] env-file（anchor 外＝anchor リポを汚さない・spawn 後 rm）:"
    echo "         ENV_FILE=\$(mktemp /tmp/scribe-consult-XXXXXX.env)"
    echo "         printf '%s\\n' '$ENV_LINE' > \"\$ENV_FILE\""
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

# --- sandbox は既定 on（opt-out 化・sc-u53）---
# 旧仕様（default off・SCRIBE_SANDBOX=1 で opt-in）から反転。worker を OS sandbox に**既定で**封じる。
# 明示 opt-out は SCRIBE_SANDBOX=0 のみ（"0" のときだけ off・未指定/その他は on）。SANDBOX_ON を一度だけ計算し、
# build_prompt（--also-tmp / scribe-add 規律）・emit_plan・実 materialization が全てこの 1 変数を読む（DRY＝
# 4 箇所のインライン判定が drift しない）。dep-preflight（下記・実 spawn 経路）が deps 欠如時に SANDBOX_ON を
# 0 へ降格しうる（fallback）ため、build_prompt はその降格後の値を見る（呼出は materialization より後）。
SANDBOX_ON=1
[[ "${SCRIBE_SANDBOX:-}" == "0" ]] && SANDBOX_ON=0

# --- 3. task prompt 生成（protocol.md §2）---
build_prompt() {
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
- 出力に「中断された」「割り込み」等のノイズが見えても作業を止めるな。shell 変数は Bash 呼出し間で消える・出力フィルタがノイズを混ぜることがある——**疑わしければ同じコマンドを再実行し、git/bd の実体（\`git -C "$WORKTREE" log\` / \`cd "$ANCHOR" && bd show $ID\`＝bd graph は anchor 所在ゆえ worktree から bare \`bd show\` は解決しない）で事実を確認**してから進む（推測や前回出力の記憶で判断しない）。
- **停止してよいのは下記 env 健全性 gate の ENV_DEGRADED 検出時のみ**（その時だけ STATUS: blocked を書いて止まる）。それ以外は契約完遂（実装→self-test→cell-quality→commit→DONE 報告）まで自律的に進めること。

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
- **env 健全性 gate（fail-closed・CC infra の Bash 非永続を検出／folio 0264028f）**: self-report（cell-quality 呼出し・gate-pending ラベル付与）の前に env 劣化を検出する。cell-quality の self-test fail-closed は test の「失敗」しか守らず、env 劣化による「誤 PASS」は塞げないため。
  - 着手の最初に**別 Bash 呼出し**で \`"$SCRIPT_DIR/scribe-env-probe.sh" plant --worktree "$WORKTREE"\` を実行し、**出力 token を文脈に控える**（shell 変数は Bash 呼出し間で消えるので文字列として控える）。
  - **self-report の直前**に**別 Bash 呼出し**で \`"$SCRIPT_DIR/scribe-env-probe.sh" verify --token <控えた token> --worktree "$WORKTREE" --base $_probe_base$_also_tmp_flag\` を実行する。
  - \`ENV_DEGRADED\`（呼出し間で sentinel 消失／base..HEAD が 0 commit）なら **done を申告せず** \`cd "$ANCHOR" && "$SCRIPT_DIR/bdw" update $ID --append-notes "STATUS: blocked — env degraded（CC infra の Bash 非永続・要admin）: <ENV_DEGRADED の理由>"\` を書いて停止する（回避策を打たない＝worker では直せない・admin が reliable env で引き取る）。
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
MONITOR_RESOLVE="WID=\$(tmux list-windows -F '#{window_id} #{window_name}' | awk -v n='$WINDOW' '\$2==n{print \$1; exit}')   # → @N"
MONITOR_CMD="tmux capture-pane -p -t \"\$WID\" | tail -n 3   # busy regex: '… \\(|esc to interrupt|agents [0-9/ ]*(done|running)|tokens'"

emit_plan() {
  echo "[plan] scribe-spawn: issue=$ID（実在検証 OK）"
  echo "[plan] git -C $REPO worktree add -b $BRANCH $WORKTREE $BASE"
  [[ "$SANDBOX_ON" == "1" ]] && echo "[plan] sandbox: $WORKTREE/.claude/settings.local.json を生成（SCRIBE_SANDBOX 既定 on・opt-out は SCRIBE_SANDBOX=0。bwrap 外壁。CLD_PATH/launcher は不変＝spawn 行 byte 同一）。実 spawn 時に dep-preflight（deps 欠如→SCRIBE_SANDBOX_FALLBACK=1 で警告付き非 sandbox / 無ければ fail-loud・sc-u53）"
  echo "[plan] scribe_capture_origin $REPO $WORKTREE   # canonical origin を per-worktree marker へ捕捉（un-1n1・gate §5 verify 用）"
  echo "[plan] worker env-file（/tmp・全 worker 無条件・worktree add より前に mktemp・spawn 後 rm。edit-write-guard の activation+境界 signal・sc-649）:"
  echo "         WORKER_ENV_FILE=\$(mktemp /tmp/scribe-worker-XXXXXX.env)"
  echo "         { source '${CLD_ENV_FILE:-\$HOME/.cld-env}' ...（ホスト既定 env を chain-source＝認証/秘密を保つ・gate round4）; export SCRIBE_WORKER=1; export SCRIBE_WORKTREE=%q（$WORKTREE・%q=source-safe） } > \"\$WORKER_ENV_FILE\""
  # 値は引用して表示する（実 invocation 行 §下記と同じく 1 argv であることを dry-run 監査でも視覚化する。
  # 将来 WORKER_DISALLOWED_TOOLS が内部空白を持つ spec〔例 Bash(git push:*)〕を含む場合に「2 引数」と誤読
  # させない・gate finding orch-4dm-review [nit]）。--env-file は全 worker（sandbox on/off 問わず）無条件ゆえ
  # opt-out と既定で spawn 行は等しく byte 不変（sc-649）。
  echo "[plan] $CLD_SPAWN --cd $WORKTREE --bd-id $ID --model $MODEL --disallowed-tools \"$WORKER_DISALLOWED_TOOLS\" --env-file \"\$WORKER_ENV_FILE\" \"<task prompt>\""
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
      echo "scribe: 真因の候補: jq 不在 / canonical bdw（beads-bdw plugin）未配備で 'scripts/bdw lock-dir' 失敗（sc-vae cutover で gen の spawn-time 依存）。通常は preflight が両者を worktree add 前に検出する。"
      echo "scribe: worktree が orphan として残っています（自動削除はしません＝force 禁止・確認必須ポリシー）: $WORKTREE"
      echo "scribe: 掃除するには（force 系を使わない確認プロンプト付き cleanup）:"
      echo "         $SCRIPT_DIR/scribe-cleanup.sh --repo \"$REPO\" --worktree \"$WORKTREE\" --branch \"$BRANCH\" --window \"$WINDOW\" $ID"
    } >&2
    exit 1
  fi
  # 生成した settings.local.json を ephemeral に保つ（worker の stage に巻き込まない・sc-1gu）。info/exclude は
  # 共有 common-dir へ冪等追記する（scribe-lib の単一実装＝本番と test で drift しない）。CC sandbox が cwd の
  # 既知 dotfile/.claude 設定を /dev/null device 化する件（sc-yqa）は info/exclude でなく scribe-add（型で弾く
  # stage ラッパ）が担う＝CC のリスト churn に無関係・共有 exclude の広い漏れを避ける（E→B 切替・sc-yqa grill）。
  scribe_sandbox_write_exclude "$WORKTREE"
  # bwrap が allowWrite path を bind 前に存在要求しうる（deduced・sc-da0）。gen が grant した書込み
  # 許可 path（専用 lock dir = 既定 $HOME/.cache/bdw-locks・sc-xs2 で orch/uns bdw と収束）を worker
  # 起動前に事前生成する。formula を再実装せず生成済み settings の allowWrite から読む＝gen と drift
  # しない（.beads は既存ゆえ no-op）。
  if command -v jq >/dev/null 2>&1; then
    while IFS= read -r _sb_aw; do
      if [[ -n "$_sb_aw" ]]; then
        mkdir -p "$_sb_aw" || echo "scribe: warn: sandbox allowWrite path の mkdir に失敗（worker 起動が failIfUnavailable で止まりうる）: $_sb_aw" >&2
      fi
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
"$CLD_SPAWN" --cd "$WORKTREE" --bd-id "$ID" --model "$MODEL" --disallowed-tools "$WORKER_DISALLOWED_TOOLS" --env-file "$WORKER_ENV_FILE" "$PROMPT_TEXT" || _cld_rc=$?
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
echo "monitor: tmux capture-pane -p -t \"${WID:-$WINDOW}\" | tail -n 3"

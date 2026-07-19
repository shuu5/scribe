#!/usr/bin/env bash
# orch-spawn-admin.sh — 任意 project の admin window を 1 コマンドで on-demand spawn（bd orch-b7f）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   orchestrator の設計役割「各 project の admin を on-demand spawn する」の実体化。人間が
#   毎回 tmux + cd + cld を手で起動する手間をなくし、任意 project の「正しい cwd の admin 権限
#   window」を 1 コマンドで建てる（コンテキスト連続は不要＝fresh session でよい）。本体は
#   cld-spawn（指定 cwd に新規 tmux window で cld を起動する primitive）への薄いラッパ。
#
# admin window であって worker cell でない（load-bearing） ────────────────────────
#   admin は worktree を作らない＝cld-spawn 直叩き（worktree 付き worker 専用の scribe-spawn は
#   使わない）。spawn された cld session が「その project の admin」になるのは scribe の SessionStart
#   role-inject の作用: .beads を持つ project では `.beads` opt-in → 既定 admin role + bd prime が
#   注入され自動で admin session になる。.beads を持たない project では台帳が無く
#   role 注入も無い＝素の cld session になる（台帳が無いので admin role を載せないのが正しい）。
#   どちらも cld-spawn コマンド自体は同一で、role の有無は SessionStart hook が決める。本スクリプトは
#   beads 有無を判定して人間に情報提示するだけ（コマンドは分岐しない）。
#
# 設計境界 ──────────────────────────────────────────────────────────────────────
#   admin spawn は orchestrator の正当な設計役割で write-isolation 違反ではない: spawn された admin は
#   その project の台帳へ write してよい（正当）。orchestrator 自身は foreign 台帳を read-only のまま
#   （hydrate して読むだけ）保つ。ツールは人間の依頼時に叩く＝自律 dispatch はしない（notice/nudge
#   までが orchestrator の役割で action は人間判断）。
#
# window 命名規約 ────────────────────────────────────────────────────────────────
#   window 名は現状 admin-<project>（下記 WINDOW_NAME 代入行）。cld-spawn は同名の既存 window があれば再利用する（--force-new で強制新規）。
#   ★orch-riz1 topology 裁定（orch-thgx・命名/addressing）: admin の宛先**正準形は `<project>:admin`（session:window）**
#     ＝window 名は本来「素 'admin'」で、session 名（=project 名）が識別を担う。だが window 名を素 admin へ改名する write 側
#     の切替は cld-spawn の session ターゲティング land（orch-8rn8=for:ccs）と**同時**でないと、current session 内で
#     cross-project 衝突 + find_existing_window の誤 reuse を招く（退行）ため、**本便では下記 WINDOW_NAME 代入行を admin-<project> のまま維持**する。
#     read 側 consumer（orch-dispatch --liveness / orch-discovery-nudge / orch-relay）は既に正準形 `<project>:admin` を
#     構築・透過する（orch-riz1）。素 admin への改名 + 実 live-admin end-to-end は cld-spawn leg land 後の follow-up。
#   ★ただし --disallowed-tools 既定 ON（orch-ce6）では既存 window 再利用は cld-spawn 側で **fail-closed（exit 1）**
#     になる（既に起動済みの window に封鎖を後付けできない＝黙って未封鎖 window を再利用しない）。よって既定経路
#     での「二度叩いて既存へ select」は成立せず、再選択したいなら --no-disallowed-tools（封鎖不要時）または
#     --force-new（封鎖付きで建て直し）を使う（詳細は下記「window 再利用 × --disallowed-tools」節・使い方セクション）。
#     封鎖なし（--no-disallowed-tools）なら従来どおり二度叩いても窓が増えず既存へ select される。
#
# model / effort（admin spawn 既定改訂・orch-k660・user 裁定 2026-07-14） ────────────
#   ★admin session の spawn 既定 = **fable かつ effort xhigh**（~/.claude/CLAUDE.md「Workflow モデル階層
#     ルーティング」が SSOT）。fable は admin main-loop 系統で許される規約内既定（WF agent への fable 投入とは
#     無関係）。従来は既定 opus 明示だったが、admin main-loop は fable で運用する user 裁定に合わせて改訂した
#     （worker spawn=`--model opus` 必ず明示 は不変＝改訂は admin spawn の既定だけ）。
#   ★fable 利用不可（API/アクセス障害）の preflight fallback = **Opus 1M で xhigh**。model 文字列は実 binary
#     照合で受理形を確定した（orch-k660 worker・実機 claude binary で `--model opus[1m]` /
#     `claude-opus-4-8[1m]` 両形が rc=0 応答・不受理 model は "There's an issue with the selected model" を返し
#     区別可＝stub fidelity 教訓の実 binary verify）。version-robust な alias 形 `opus[1m]`（＝latest opus + 1M
#     context）を採用する（fable も alias 既定・opus 4.8 の版 bump で pin が腐らない）。fable preflight は scribe
#     consult の sc-9q6（fast fail のみ不可扱い・timeout=利用可）を REUSE する（下記 fable_available）。preflight
#     は **実起動時のみ**（dry-run は API を叩かない＝副作用ゼロ）。seam ORCH_SPAWN_ADMIN_FABLE_PREFLIGHT=1/0。
#   ★effort xhigh は ambient 既定に依存しない（実測: 素の session は high であって xhigh 保証なし）ゆえ cld-spawn
#     の --effort passthrough で **明示注入して保証**する（--effort で override 可・下記 EFFORT）。
#   --model 明示は常に既定 fable/preflight より優先（MODEL_EXPLICIT）。
#
# /effort ultracode 注入（spawn 後・kickoff 前・orch-k660 leg2） ─────────────────────
#   admin を ultracode で起動したい（standing multi-agent orchestration）。ultracode は env で載せられず、CLI の
#   --effort も low|medium|high|xhigh|max のみ受理し ultracode 非対応（`claude --help` 実測）ゆえ、**TUI スラッシュ
#   コマンド `/effort ultracode` を spawn 後に別 submission として直接注入**する（scribe 運用 memory の「/effort
#   ultracode 打鍵」実績＝feasible）。kickoff より前に注入し、effort が kickoff の turn に効くようにする。
#   送達確認は cld-spawn --inject-existing の read-back（inject-file + 受理確認）を REUSE する。不受理/送達失敗は
#   **fail-open**（admin は fable+xhigh のまま稼働継続）+ ⚠ loud、opt-out は --no-effort-inject。
#   ★[xhigh]（effort level）と ultracode（session mode）は footer に共存する（acceptance(f) の実 spawn footer
#     「Fable 5 [xhigh] + ultracode」で orchestrator が gate 後に実測確認する＝worker sandbox は実 spawn 不能）。
#
# spawn 後の kickoff turn-start 実照合（併修 orch-sm6p・boot-race defense-in-depth） ──
#   起動レースで cld-spawn の read-back（受理確認）が偽陽性を返し、初回注入が boot 中の TUI 再描画に飲まれても
#   'prompt injected' を報告する実測 bug（orch-sm6p・pane splash+空入力欄のまま turn 未起動）。orch-spawn-admin 側
#   の自己完結 defense-in-depth（orch-sm6p 案(b)）: kickoff 注入後に **turn が実際に開始したか**を cc-session の
#   session-state.sh（processing 状態）で positive-proof 照合する（入力欄が空=受理 という短絡は使わない＝orch-sm6p
#   の根因訂正・positive-proof-only 原理）。turn 未起動なら **再送 → なお未起動なら fail-loud**（消失を偽 injected
#   にしない）。cld-spawn read-back 自体の根本修正は cc-session admin へ courier（本 bead notes に切り分け記録）。
#   seam ORCH_SPAWN_ADMIN_SESSION_STATE（既定 ~/.claude/plugins/session/scripts/session-state.sh）。
#
# project レジストリ（name → 絶対パス・設定可能） ─────────────────────────────────
#   レジストリは env `ORCH_ADMIN_PROJECTS` または private 配備層 registry overlay（scripts/lib/orch-projects.sh・
#   連結対象 foreign project の SSOT・orch-hydrate.sh / orch-architecture-hydrate.sh と同一解決）から受ける＋
#   self-entry scriptorium のみ本 script ローカルで append する（orch-70i・下記「project レジストリ」節の設計理由を
#   参照＝二重 SSOT 回避と self-entry 分離）。env `ORCH_ADMIN_PROJECTS`（空白区切りの `name=path` トークン列・
#   **path に空白を含めない**＝空白区切り read -ra で分割するため）で全置換できる（env 分岐は registry より優先）。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）  実行: cld-spawn を exec して admin window を建てる。
#   --dry-run cld-spawn を一切呼ばず、project→cwd 解決・cwd 実在検査・beads 判定・実行予定コマンド
#             print のみ行う（実 tmux window を建てない＝self-test が hermetic・実 session を起動しない）。
#   --help    使い方（このヘッダブロック）。
#
# account 選択（マルチアカウント・orch-dgo / sc-1rq 同型） ─────────────────────────
#   admin spawn は既定 account（=~/.claude・CLAUDE_CONFIG_DIR unset）を継承する。default account が weekly 枯渇
#   のまま admin を起こすと 35 分 churn 後に凍結する実事故があった（un-gakv 便・orch-dgo）。worker 経路
#   （scribe-spawn --account auto・sc-1rq）は残量ベース account 自動選択で被覆済みだが、admin 経路（cld-spawn 直）
#   は gap だった。本 script は --account <label|auto> を足し、cld-spawn native --env-file 経由で CLAUDE_CONFIG_DIR
#   を注入して account を切り替える（F1）。残量 maximin ロジックは複製せず scribe の selector（scribe-account-select・
#   read-only・fs 非接触）を実行して消費する（F2＝SSOT は scribe・foreign script の read-only 実行は write-isolation 非侵害）。
#     --account auto   残量 maximin 上位 account を自動選定（selector 不在/API 故障/適格0件は fail-loud die＝
#                      silent に default 継承へ落ちない・本 bug の再発防止）。
#     --account <label> <accounts-base>/<label> を注入（label 検証は英数 . _ - のみ・path traversal 拒否・F12）。
#                      selector があれば当該 account の weekly 枯渇を loud 警告するが spawn は継続（代替を殺さない・F7）。
#     未指定           従来挙動＝unset CLAUDE_CONFIG_DIR を注入（既定 ~/.claude・F5）。selector があれば default
#                      account の残量を probe し weekly 枯渇なら loud 警告（silent 凍結の再発防止・acceptance(3)）。
#   注入する config-dir（auto 採用/explicit label 両経路）は sibling worker（scribe probe_config_dir・sc-rvq）
#   と同水準で fail-loud 検査する: (a)dir 実在 (b)credentials(login) (c)onboarding 完了 (d)guard plugin enable。
#   下流 cld-spawn/cld には CLAUDE_CONFIG_DIR 検証 preflight が **無い**＝verified ゆえ不健全 dir 注入は login TUI
#   で無人 window を hang させるか（(a)〜(c)）guard plugin 欠落のまま無防備 admin を起こす（(d)）＝silent 凍結の
#   別変種 + write-isolation を破る fail-open になる（admin は worker より特権的ゆえ検査を省く非対称は退行・orch-dgo
#   self-review major）。probe_config_dir は scribe-spawn.sh 内の埋込関数で standalone 実行 entry が無く SSOT
#   read-only 消費が不能ゆえ、label 検証（un-h289 安定 interface）と同姿勢で安定 interface を複製して被覆する。
#   env-file は既定 ~/.cld-env（ホスト既定 env=認証/秘密）を chain-source してから config-dir 行を後勝ちで置く
#   （cld-spawn の --env-file は既定 source を排他置換するため・scribe worker sc-rvq gate round4 と同型）。
#   監査 snapshot は stderr にのみ出す（foreign 台帳へ bd write しない＝write-isolation・F3）。
#
# 使い方:
#   orch-spawn-admin <project> [--account L|auto] [--force-new] [--dry-run] [--model MODEL] [--effort LEVEL]
#                    [--no-effort-inject] [--disallowed-tools CSV | --no-disallowed-tools] [--no-watch-hint]
#                    [-- <kickoff prompt>]
#     <project>          レジストリ上の project 名（既知 project 集合は共有 lib scripts/lib/orch-projects.sh
#                        ＋self-entry scriptorium。未知 project 指定時のエラーが known projects を列挙する）。必須。
#     --account L|auto   spawn する admin の CLAUDE_CONFIG_DIR account（label or auto=残量 maximin 自動選定）。
#                        未指定は従来挙動（既定 ~/.claude・unset 注入・下記「account 選択」節）。
#     --force-new        既存 admin window を再利用せず必ず新規作成（cld-spawn へ pass-through）。
#     --dry-run          実行予定の cld-spawn コマンドを print するのみ（何も起動しない）。
#     --model MODEL      cld の model（既定 fable・不可時 opus[1m] へ preflight fallback・明示は既定より優先）。
#     --effort LEVEL     cld の effort（既定 xhigh・明示注入で保証）。cld-spawn --effort passthrough へ透過。
#     --no-effort-inject spawn 後の `/effort ultracode` 注入を無効化（ultracode 起動を見送る＝fable+xhigh のまま）。
#     --disallowed-tools CSV  cld→claude へ物理封鎖する対話 tool（既定 'AskUserQuestion,ExitPlanMode'・orch-ce6）。
#                        cld-spawn の --disallowed-tools passthrough（orch-6sd）へ verbatim 1-argv 透過する。
#     --no-disallowed-tools   対話 tool 封鎖を無効化（人間直付き admin を明示 spawn する等の例外用）。
#     --no-watch-hint    spawn 直後 watch 常駐ヒント（[ORCH-WATCH-RESIDENT]・orch-ce6）を stderr へ emit しない。
#     -- <prompt...>     `--` 以降を kickoff prompt として cld-spawn へ渡す（起動後 inject）。
#                        ★終端宣言作法ブリーフ（orch-mot / orch-306）は **prompt の有無に依らず恒久注入**される
#                        （後述）。user prompt があればブリーフの後に置く。prompt が無くてもブリーフのみ inject される。
#
# ★window 再利用 × --disallowed-tools の相互作用（fail-closed・cld-spawn の設計）: window 名は安定規約
#   admin-<project> で、既存 window があれば cld-spawn は再利用する。だが --disallowed-tools 付きで再利用が
#   起きると cld-spawn は fail-closed で拒否する（既に起動済みの window には封鎖を後付けできない＝黙って
#   未封鎖 window を再利用し偽成功にしない・gate round-1 CONFIRMED #3）。よって封鎖付きで建て直すには
#   --force-new で置換するか、対象 window を閉じるか、封鎖不要なら --no-disallowed-tools で再選択する。
#
# 終端宣言作法 + 無人 window 作法の恒久注入（orch-mot / orch-306 / orch-ail (2) / orch-z7g / orch-355 / orch-edv） ──
#   spawn される actor の監視は pane の見た目でなく actor 自身の durable 終端宣言を truth とする
#   （grill 2026-06-30 確定）。よって spawn 時に下記規律のブリーフ（先頭 ASCII sentinel [ORCH-WATCH-CONTRACT]）を
#   kickoff prompt へ**恒久注入**する: ①自台帳に終端宣言 bead を作り ID を即報告 ②DONE/BLOCKED/NEEDS-USER を
#   明示宣言 ③背景 pending 中は宣言しない ④orchestrator は --foreign-repo 直読 poll で監視 ⑤pane は truth でない。
#   加えて無人 window 作法（orch-z7g grill・user ratified 2026-07-01・文面即効の layer ①）: ⑥対話プロンプト
#   （AskUserQuestion / ExitPlanMode / permission 待ち）を使うな＝この window に人間は付いていない（無人）ゆえ
#   誰も答えられず固まる ⑦human 決定（固い merge 確認を含む）は NEEDS-USER を宣言して turn を終えよ（gate-pending は
#   worker→自 admin 用ゆえ foreign admin は human 決定に使わない）⑧orchestrator が bead 直読 poll で検知し window
#   メッセージ（push relay）で再開指示する＝それを待て。
#   さらに bead-append 規律（orch-edv grill T1・user ratified 2026-07-02・silent mutual-wait deadlock 恒久 fix）:
#   ⑨orchestrator への新質問/報告/再 pause は**該当 bead の notes に append し updated_at を必ず動かせ**（pane-only 禁止）。
#   **既に needs-user の bead への再 pause も同様**（status/label 不変でも notes append で updated_at を前進させる）。
#   ＝orchestrator の baseline watch（updated_at 前進で発火・orch-2hx T2）が re-pause を検知でき、pane に決定情報を
#   滞留させない（re-pause が「無変化 transition」で取りこぼされ相互デッドロックに陥る root cause #1/#3 を断つ）。
#   .beads を持たない project は終端宣言 bead を作れない＝pane 縮退ゆえ「最終出力で明示」変種を注入する
#   （⑥⑧は no-beads でも同旨・⑦は最終出力での park に読み替える・⑨は「新質問/報告/再 pause を最終出力で毎回明示」に読み替える）。
#   ※文面（本ブリーフ）は layer ① で焼いた（orch-355）。**layer ③（orch-ce6・本 script）で機構強制も着地**した:
#   spawn 時に --disallowed-tools（既定 AskUserQuestion,ExitPlanMode）を cld-spawn へ渡し対話 channel を
#   物理封鎖する（文面＋機構の二重化＝H1=(c)）。cc-session cld-spawn の passthrough（orch-6sd）着地が前提。
#
# env override（主に self-test 用）:
#   ORCH_ADMIN_PROJECTS   project レジストリを全置換（空白区切り `name=path` 列・path に空白不可）。
#   ORCH_SPAWN_CLD        cld-spawn 実体パス（既定: ~/.claude/plugins/session/scripts/cld-spawn）。
#   ORCH_ACCOUNT_SELECT   残量 maximin selector パス（既定: ~/.claude/plugins/scribe/scripts/scribe-account-select）。
#                         SSOT は scribe（複製禁止）＝read-only 実行で消費する（F2）。selector 側 seam
#                         （SCRIBE_USAGE_JSON / SCRIBE_USAGE_CMD / SCRIBE_USAGE_NOW）は env でそのまま透過する。
#   ORCH_ACCOUNTS_BASE    account label→dir の基底（既定: ~/.claude-accounts・F12）。<base>/<label> を注入。
#   CLD_ENV_FILE          env-file が chain-source するホスト既定 env（既定: ~/.cld-env）。
#   ORCH_SPAWN_ADMIN_FABLE_PREFLIGHT  1=fable 利用可を強制 / 0=不可を強制（未設定=実測。fable 既定の fallback
#                         判定用 seam・sc-9q6 の SCRIBE_FABLE_PREFLIGHT と同型・bats/緊急時の注入口）。
#   ORCH_SPAWN_CLAUDE_BIN fable preflight が叩く claude 実体（既定: claude）。
#   ORCH_SPAWN_ADMIN_SESSION_STATE  kickoff turn-start 照合の session-state.sh 実体（既定: ~/.claude/plugins/
#                         session/scripts/session-state.sh）。`state <window>` が processing/input-waiting 等を返す。
#   ORCH_SPAWN_ADMIN_VERIFY_ATTEMPTS / _VERIFY_SETTLE  turn-start poll の試行回数（既定 6）/ 間隔秒（既定 2）。
#   ORCH_SPAWN_ADMIN_RESEND_MAX       kickoff 未起動時の再送上限（既定 1・二重 submit 母集団を有界化）。
#   ORCH_SPAWN_ADMIN_INJECT_TIMEOUT   cld-spawn --inject-existing の read-back 待機秒（既定 60）。
#   ORCH_SPAWN_ADMIN_BD   slate interlock（bd orch-vswk）が叩く bd 実体（read-only・既定 PATH 上の bd）。gate-2 裁定の
#                         新 seam＝bats を hermetic 化する（open slate の members を read するだけ・foreign 台帳へ write しない）。
#   ORCH_SPAWN_ADMIN_SCRIPTORIUM  slate 台帳 anchor（自台帳 orch=scriptorium）の override（既定: _resolve_scriptorium 動的解決）。
#   ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE  slate interlock を bypass する hermetic seam（=1 で skip・既定 0=gate 有効）。既存 bats
#                         回帰維持用＝production 既定は gate 有効（後方互換を口実にした warn-only 化でない・fail-closed）。
#
# 検証: selftest-orch-b7f.local.sh（worktree 直下・untracked・fail-closed・dry-run のみ＝実 session を
#   起動しない。bash -n + project 解決 / 未知 project エラー / beads 判定 / cwd 不在 / dry-run 非起動）。

set -uo pipefail

# --- project レジストリは env seam / private 配備層 registry から受ける（二重 SSOT 回避・orch-2ax→orch-70i） ---
# engine tree は project registry（実名 list）を同梱しない。解決順:
#   (1) env `ORCH_ADMIN_PROJECTS` が set なら後段（引数解析後）でそれを全採用（従来どおり）。
#   (2) 同 dir の private registry overlay（scripts/lib/orch-projects.sh・配備層が配置した場合のみ）を source。
#   (3) どちらも無ければ fail-loud（値の hardcode fallback は持たない）。
# 旧実装は本 script が独自 hardcode の DEFAULT_PROJECTS を持ち registry と二重 SSOT 化していた＝registry に
# 足した新規 project が未反映で unknown project として die した（orch-70i 実測 drift）。registry を配備層
# 1 箇所に置き engine は読むだけ、で drift を断つ（orch-hydrate.sh と同型・BASH_SOURCE[0] 相対解決）。
#
# ★self-entry scriptorium は共有 lib へは入れず spawn-admin ローカルで append する（orch-70i 設計確定・
#   両方向 silently-choose 禁止）: lib/orch-projects.sh は『連結対象 foreign project』の SSOT で、scriptorium
#   （dolt_database=orch＝自台帳）を lib に足すと orch-hydrate / architecture-hydrate が自台帳を bd repo add する
#   二次汚染を起こす（per-project self-skip 無し）＝lib への scriptorium 追加は禁止。逆に scriptorium を落とすのも
#   禁止（『unknown project』より明快な footgun エラーを出す意図が退行する）。正解＝source の**直後**に
#   DEFAULT_PROJECTS へ scriptorium を append（self-entry を foreign-project SSOT から意図的に分離＝二重 SSOT では
#   ない）。scriptorium エントリは下記 self-ledger footgun ガード（orch-1r7・dolt_database==orch なら die）で守られる。
#   trailing slash は付けない（cld-spawn は realpath 正規化するが判定の一貫性のため）。
_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib"
DEFAULT_PROJECTS=()
if [ -f "$_ORCH_LIB_DIR/orch-projects.sh" ]; then
    # shellcheck source=lib/orch-projects.sh
    # shellcheck disable=SC1091
    source "$_ORCH_LIB_DIR/orch-projects.sh"
fi
# 未供給（env も registry も無い/空）は fail-closed で die: hardcode fallback で degraded spawn しない
# （orch-70i acceptance 3）。scriptorium append の**前**に判定する（append が空 registry を 1 件で覆い隠して
# degraded 継続するのを防ぐ）。★事前の `DEFAULT_PROJECTS=()` 初期化により「registry が source 成功するが
# DEFAULT_PROJECTS を定義しない（変数改名等の破損）」ケースも空配列＝未供給として同列に fail-closed 判定される
# （set -u 下の unset 配列 quirk〔orch-70i acceptance 3 の核〕を初期化で構造的に潰した engine 形）。
# --help / -h は registry 非依存で表示する（下の fail-loud gate より前に先読み・引数解析の -h|--help と同一出力・
# sc-vcjv gate finding 反映）。`--` 以降は kickoff prompt 引数ゆえ flag として解釈しない。
for _arg in "$@"; do
    case "$_arg" in
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0 ;;
        --) break ;;
    esac
done

if [ -z "${ORCH_ADMIN_PROJECTS:-}" ] && [ "${#DEFAULT_PROJECTS[@]}" -eq 0 ]; then
    echo "orch-spawn-admin: project レジストリ未供給（fail-loud）: env ORCH_ADMIN_PROJECTS（空白区切り name=path）を設定するか、" >&2
    echo "  private 配備層 registry を $_ORCH_LIB_DIR/orch-projects.sh へ配置すること（engine は値の hardcode を持たない）。" >&2
    exit 1
fi
# self-entry scriptorium を registry 解決の直後に append（foreign-project SSOT から意図的に分離・orch-70i）。
# engine 版: 自 anchor path を deploy-layout hardcode で持たず、seam（ORCH_ANCHOR）供給時のみ append する。
# 未供給なら self-entry 無し＝'scriptorium' 指定は unknown project として fail-loud（private 配備層が
# ORCH_ANCHOR を供給する運用が正）。footgun ガード（orch-1r7・dolt_database==orch なら die）は不変。
if [ -n "${ORCH_ANCHOR:-}" ]; then
    DEFAULT_PROJECTS+=("scriptorium=$ORCH_ANCHOR")
fi

# ★slate interlock の共有 lib（orch_anchor.sh / orch_slate.sh）は **gate ブロック内で遅延 source** する
#   （下記 slate interlock 節・_load_slate_libs）。load 時に top-level source しない理由: (1) footgun/unknown で
#   spawn へ到達しない経路（mutant sandbox 含む）に lib 依存を波及させない (2) bypass seam=1 のとき lib 不要。
#   ＝新依存は「実際に slate 照合が走るときだけ」現れる（fail は必要時のみ・既存 mutant sandbox を無改変で維持）。

# cld-spawn 実体パス（env で差し替え可・self-test 用）。
CLD_SPAWN="${ORCH_SPAWN_CLD:-$HOME/.claude/plugins/session/scripts/cld-spawn}"

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析: 第1 non-option = project / `--` 以降 = kickoff prompt
# ─────────────────────────────────────────────────────────────────────────────
PROJECT=""
DRY_RUN=false
FORCE_NEW=false
# admin spawn 既定改訂（orch-k660・user 裁定 2026-07-14）: 既定 model=fable（従来 opus）・不可時 opus[1m] へ
#   preflight fallback（下記 fable_available）。--model 明示は MODEL_EXPLICIT で既定/fallback より常に優先。
MODEL="fable"
MODEL_EXPLICIT=false
FABLE_FALLBACK_MODEL="opus[1m]"   # fable 利用不可時の fallback（Opus 1M・alias 形＝version-robust・実 binary 受理確認済み）
# effort xhigh は ambient 既定に依存せず --effort 明示注入で保証する（orch-k660 leg1）。--effort で override 可。
EFFORT="xhigh"
# spawn 後の `/effort ultracode` 注入（orch-k660 leg2）。--no-effort-inject で見送り（fable+xhigh のまま）。
INJECT_EFFORT_ULTRACODE=true
ACCOUNT=""        # spawn する admin の CLAUDE_CONFIG_DIR account（""=未指定=従来挙動・"auto"=maximin・その他=label）。
PROMPT_ARGS=()

# 対話 tool の物理封鎖（機構強制・orch-z7g layer ③ / orch-ce6）─────────────────────
#   無人 window（admin は人間非同席）で AskUserQuestion / ExitPlanMode 等の対話 tool を使うと誰も答えられず
#   window が固まる（out-of-band ゆえ bead-truth poll からも不可視）。ORCH-WATCH-CONTRACT ブリーフ（文面）は
#   これを禁じるが、文面だけだと CC 既定挙動へ再発する（orch-z7g H1）。よって cld-spawn の --disallowed-tools
#   passthrough（cld→claude へ verbatim 1-argv 透過・orch-6sd 着地）で対話 channel を **物理封鎖** し、文面と
#   機構で二重化する（H1=(c)）。既定は AskUserQuestion,ExitPlanMode（cld-spawn が値を分割せず claude が
#   括弧認識で split する＝カンマ区切り 1 値で渡す）。--no-disallowed-tools で無効化（人間直付き admin を
#   明示 spawn する等の例外用＝その場合 AskUserQuestion は正しい挙動）。
DISALLOWED_TOOLS_DEFAULT="AskUserQuestion,ExitPlanMode"
DISALLOWED_TOOLS="$DISALLOWED_TOOLS_DEFAULT"
# spawn 直後 watch 常駐ヒント（orch-z7g H3-ii / orch-ce6）を stderr に emit するか（--no-watch-hint で抑止）。
WATCH_HINT=true

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --force-new) FORCE_NEW=true; shift ;;
        --disallowed-tools)
            # 値は cld-spawn へ verbatim 1-argv 透過（分割しない・claude が括弧認識で split）。
            if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
                echo "orch-spawn-admin: --disallowed-tools に値を指定してください（例: 'AskUserQuestion,ExitPlanMode'）" >&2
                exit 2
            fi
            DISALLOWED_TOOLS="$2"; shift 2 ;;
        --no-disallowed-tools) DISALLOWED_TOOLS=""; shift ;;
        --no-watch-hint) WATCH_HINT=false; shift ;;
        --account)
            # account label（or 特別値 auto）。値必須（欠落 or 次が option 形なら fail-loud）。
            if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
                echo "orch-spawn-admin: --account に値を指定してください（例: --account auto / --account <label>）" >&2
                exit 2
            fi
            ACCOUNT="$2"; shift 2 ;;
        --model)
            if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
                echo "orch-spawn-admin: --model に値を指定してください" >&2
                exit 2
            fi
            MODEL="$2"; MODEL_EXPLICIT=true; shift 2 ;;
        --effort)
            if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
                echo "orch-spawn-admin: --effort に値を指定してください（low|medium|high|xhigh|max）" >&2
                exit 2
            fi
            EFFORT="$2"; shift 2 ;;
        --no-effort-inject) INJECT_EFFORT_ULTRACODE=false; shift ;;
        -h|--help)
            # 先頭コメントブロック（shebang 直後〜最初の非コメント行の手前）を help として出す。
            # 行番号を固定せず最初の非コメント行で打ち切るのでヘッダ伸縮に追従する（orch-hydrate と同型）。
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        --)
            shift
            PROMPT_ARGS=("$@")
            break
            ;;
        -*)
            echo "orch-spawn-admin: unknown option: $1" >&2
            echo "  usage: orch-spawn-admin <project> [--force-new] [--dry-run] [--model M] [-- <prompt>]" >&2
            exit 2
            ;;
        *)
            if [ -z "$PROJECT" ]; then
                PROJECT="$1"; shift
            else
                # project は 1 つ・kickoff prompt は `--` 以降で渡す（曖昧回避の fail-loud）。
                echo "orch-spawn-admin: 余分な引数: '$1'（project は 1 つ・prompt は '--' 以降で渡す）" >&2
                echo "  usage: orch-spawn-admin <project> [--force-new] [--dry-run] [--model M] [-- <prompt>]" >&2
                exit 2
            fi
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# project 必須・レジストリ解決
# ─────────────────────────────────────────────────────────────────────────────
if [ -z "$PROJECT" ]; then
    echo "orch-spawn-admin: project を指定してください" >&2
    echo "  usage: orch-spawn-admin <project> [--force-new] [--dry-run] [--model M] [-- <prompt>]" >&2
    exit 2
fi

# project レジストリ解決（env override 優先・空白区切り name=path）。
PROJECTS=()
if [ -n "${ORCH_ADMIN_PROJECTS:-}" ]; then
    read -ra PROJECTS <<< "$ORCH_ADMIN_PROJECTS"
else
    PROJECTS=("${DEFAULT_PROJECTS[@]}")
fi

CWD=""
for entry in "${PROJECTS[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    if [ "$name" = "$PROJECT" ] && [ "$name" != "$entry" ] && [ -n "$path" ]; then
        CWD="$path"
        break
    fi
done

if [ -z "$CWD" ]; then
    echo "orch-spawn-admin: unknown project: '$PROJECT'" >&2
    printf '  known projects:' >&2
    for entry in "${PROJECTS[@]}"; do printf ' %s' "${entry%%=*}" >&2; done
    printf '\n' >&2
    exit 2
fi

# ─────────────────────────────────────────────────────────────────────────────
# cwd 実在検査（fail-closed: 不在なら起動しない）
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -d "$CWD" ]; then
    echo "orch-spawn-admin: project '$PROJECT' の cwd が存在しません: $CWD" >&2
    echo "  spawn できないため中止（fail-closed）。レジストリ path を確認せよ。" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# self-ledger footgun ガード（runtime・orch-1r7）: 解決した project の台帳が自台帳（dolt_database=orch）
#   なら die する。orch-spawn-admin は「他 project の admin を on-demand spawn」する道具（federated 3-tier）
#   であり、自 repo（scriptorium＝dolt_database=orch）に 2 人目 admin を建てるのは footgun: 同一 embedded
#   Dolt（single-writer）へ authority が二重化し衝突する（orch-3c1「自 repo には admin を建てない＝
#   orchestrator session 自身が orch admin」/ orch-0w7 案A）。DEFAULT_PROJECTS に scriptorium を残すのは
#   「unknown project」より明快なエラーを出すため。判定は dir 名でなく dolt_database==orch（CLAUDE.md /
#   orch_session.py SELF_PREFIX と同一 SSOT・改名/alias でも維持）。**metadata 欠落/読取不能は die しない**
#   ＝orch と肯定確認できたときだけ fail-loud（既存 self-test の .beads-only fixture を壊さない fail-open 側）。
_SELF_LEDGER_META="$CWD/.beads/metadata.json"
_SELF_LEDGER_DB=""
if [ -f "$_SELF_LEDGER_META" ]; then
    if command -v jq >/dev/null 2>&1; then
        _SELF_LEDGER_DB="$(jq -r '.dolt_database // empty' "$_SELF_LEDGER_META" 2>/dev/null)"
    fi
    if [ -z "$_SELF_LEDGER_DB" ] && command -v python3 >/dev/null 2>&1; then
        _SELF_LEDGER_DB="$(python3 -c 'import json,sys
try:
    d=json.load(open(sys.argv[1], encoding="utf-8"))
    print(d.get("dolt_database","") if isinstance(d, dict) else "")
except Exception:
    print("")' "$_SELF_LEDGER_META" 2>/dev/null)"
    fi
fi
if [ "$_SELF_LEDGER_DB" = "orch" ]; then
    echo "orch-spawn-admin: '$PROJECT' は orchestrator 自台帳（dolt_database=orch）です — spawn を拒否（fail-closed）。" >&2
    echo "  自 repo には 2 人目 admin を建てない（同一 single-writer embedded Dolt への authority 衝突・orch-3c1 / orch-0w7 案A）。" >&2
    echo "  orchestrator session 自身が orch admin ＝自己開発の worker cell は orch-dispatch <bd-id> で dispatch する。" >&2
    exit 1
fi

# ── slate interlock（bd orch-vswk・orch-6srt 裁定-safeguards(3)・gate-1/gate-2 裁定・fail-closed）─────────────
#   spawn する target project が open な計画 slate（自台帳 orch の members 和集合）に列挙されていなければ spawn を
#   拒否する。照合キー = **spawn する target project**（slate の対象={bead-id ∪ target-project} union キー）。
#   ★配置: footgun ガードの後・spawn 実行（env-file 作成/cld-spawn 起動）の前＝副作用ゼロで弾く（read-only 参照のみ）。
#   ★dry-run も read-only 照合を掛ける（「dry-run では slate skip」の逆解釈は封じる・dispatch と対称）。
#   ★interlock 発火 scope は全 spawn（foreign-only exempt は作らない・gate-1）。bypass seam は hermetic 用（既定 gate 有効）。
#   ★共有 lib（orch_anchor.sh の _resolve_scriptorium・orch_slate.sh の _orch_slate_*）を **ここで遅延 source** する
#     （load 時 top-level で source しない＝footgun/unknown 経路や mutant sandbox に lib 依存を波及させない）。
_load_slate_libs() {
    if [ -r "$_ORCH_LIB_DIR/orch_anchor.sh" ]; then
        # shellcheck source=lib/orch_anchor.sh
        # shellcheck disable=SC1091
        source "$_ORCH_LIB_DIR/orch_anchor.sh"
    else
        echo "orch-spawn-admin: 共有 anchor lib 不在: $_ORCH_LIB_DIR/orch_anchor.sh（slate anchor 解決不能・fail-closed）" >&2
        return 1
    fi
    if [ -r "$_ORCH_LIB_DIR/orch_slate.sh" ]; then
        # shellcheck source=lib/orch_slate.sh
        # shellcheck disable=SC1091
        source "$_ORCH_LIB_DIR/orch_slate.sh"
    else
        echo "orch-spawn-admin: 共有 slate lib 不在: $_ORCH_LIB_DIR/orch_slate.sh（slate interlock 不能・fail-closed）" >&2
        return 1
    fi
    return 0
}
if [ "${ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE:-0}" != 1 ]; then
    _load_slate_libs || exit 1
    # slate 台帳 anchor（自台帳 orch=scriptorium）。env override（ORCH_SPAWN_ADMIN_SCRIPTORIUM）を最優先で維持し、
    # 未設定時のみ _resolve_scriptorium で動的解決（ORCH_ANCHOR / ORCH_ANCHOR_CONFIG seam 込み・解決不能は
    # fail-loud＝deploy-layout 依存の hardcode fallback は engine では持たない・dispatch と同型）。
    SLATE_ANCHOR="${ORCH_SPAWN_ADMIN_SCRIPTORIUM:-$(_resolve_scriptorium 2>/dev/null || true)}"
    if [ -z "$SLATE_ANCHOR" ]; then
        echo "orch-spawn-admin: slate anchor 解決不能（fail-loud）: env ORCH_SPAWN_ADMIN_SCRIPTORIUM / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ（engine は hardcode fallback を持たない）。" >&2
        exit 1
    fi
    # slate interlock が叩く bd 実体（read-only・bats hermetic 化用の新 seam・gate-2 裁定）。既定 PATH 上の bd。
    SLATE_BD="${ORCH_SPAWN_ADMIN_BD:-bd}"
    _slate_members="$(_orch_slate_open_members "$SLATE_BD" "$SLATE_ANCHOR")"; _slate_rc=$?
    if [ "$_slate_rc" -ne 0 ]; then
        echo "orch-spawn-admin: 計画 slate を read できません（bd list/show 失敗・rc=$_slate_rc・anchor=$SLATE_ANCHOR）＝slate 検証不能で spawn 中止（fail-closed・orch-vswk）。" >&2
        exit 1
    fi
    if [ -z "$_slate_members" ]; then
        echo "orch-spawn-admin: open な計画 slate（label '$ORCH_SLATE_LABEL' + 行頭 sentinel '$ORCH_SLATE_SENTINEL'）が無い/members 未列挙＝計画外 spawn を拒否（fail-closed・orch-vswk）。" >&2
        echo "  bundle 頭で slate を記録し target project '$PROJECT' を members に列挙してから再 spawn せよ。" >&2
        exit 1
    fi
    if ! printf '%s\n' "$_slate_members" | grep -qxF -- "$PROJECT"; then
        echo "orch-spawn-admin: target project '$PROJECT' が open slate の members 集合に属さない＝計画外 spawn を拒否（fail-closed・orch-vswk・空虚 interlock でなく集合照合）。" >&2
        echo "  slate の members に '$PROJECT' を列挙してから再 spawn せよ。" >&2
        exit 1
    fi
fi

# beads 有無判定（情報提示のみ・コマンドは分岐しない）。
if [ -d "$CWD/.beads" ]; then
    BEADS_NOTE="beads detected → scribe SessionStart で admin role が注入される"
    BEADS_KIND="beads"
else
    BEADS_NOTE="no .beads → 素の cld session（admin role 注入なし＝台帳が無いので正しい）"
    BEADS_KIND="no-beads"
fi

WINDOW_NAME="admin-$PROJECT"

# ─────────────────────────────────────────────────────────────────────────────
# 終端宣言作法 + 無人 window 作法ブリーフ（恒久注入・orch-mot / orch-306 / orch-ail (2) / orch-z7g / orch-355）
#   spawn される actor の監視は「pane の見た目」でなく「actor 自身の durable 終端宣言」を truth とする
#   （orch-mot grill 2026-06-30 確定）。よって spawn brief に下記規律を**恒久注入**する:
#     - 自台帳に終端宣言 bead を作り ID を即報告 / DONE・BLOCKED・NEEDS-USER を明示宣言
#     - 背景 pending（workflow/subagent/bg コマンド）実行中は宣言しない＝turn 境界 idle を完了と誤認させない
#     - orchestrator は orch-dispatch --watch --foreign-repo で bead を直読 poll 監視する
#     - pane は truth でなく INCONCLUSIVE 補助でしかない（一致しても DONE にしない）
#   加えて無人 window 作法（orch-z7g grill・user ratified 2026-07-01・文面 layer ①＝orch-355／機構強制 layer ③＝orch-ce6 で本 script の cld-spawn 起動に --disallowed-tools として着地）:
#     - 対話プロンプト（AskUserQuestion / ExitPlanMode / permission 待ち）を使うな＝この window に人間は付いて
#       いない（無人）ゆえ対話 UI を出しても誰も答えられず固まる（out-of-band で bead-truth poll から不可視）
#     - human 決定（固い merge 確認を含む）が要るときは NEEDS-USER を宣言して turn を終えよ（gate-pending は
#       worker→自 admin 用ゆえ foreign admin は human 決定に使わない）
#     - 宣言後は待て: orchestrator が bead 直読 poll で NEEDS-USER を検知し、この window へメッセージ（push relay）で
#       再開指示する＝自分で対話 prompt を出して先へ進もうとしない
#   さらに bead-append 規律（orch-edv grill T1・user ratified 2026-07-02・silent mutual-wait deadlock 恒久 fix）:
#     - orchestrator への新質問/報告/再 pause は必ず該当 bead の notes に append し updated_at を前進させよ
#       （pane-only 禁止）。既に needs-user の bead へ再 pause する場合も同様（status/label 不変でも notes append で
#       updated_at を動かす）＝orchestrator の baseline watch（updated_at 前進で発火・orch-2hx T2）が re-pause を
#       検知でき、決定情報を pane に滞留させない（re-pause が「無変化 transition」で取りこぼされる root cause を断つ）。
#   先頭に ASCII sentinel [ORCH-WATCH-CONTRACT] を置き、注入の検証（locale 非依存 grep）を可能にする。
#   beads / no-beads で文面を出し分ける（no-beads は終端宣言 bead を作れない＝pane 縮退ゆえ最終出力で明示・
#   対話禁止/push relay は no-beads でも同旨、NEEDS-USER は最終出力での park に読み替える・bead-append 規律は
#   「新質問/報告/再 pause を最終出力で毎回明示」に読み替える）。
if [ "$BEADS_KIND" = "beads" ]; then
    BRIEF="[ORCH-WATCH-CONTRACT] orchestrator 監視作法（恒久・orch-mot / orch-306 / orch-z7g）:
- あなたは spawn された actor。完了/停止の truth は **あなた自身の終端宣言のみ**（pane の見た目は truth でない）。
- 着手したら自台帳（$CWD の .beads）に **終端宣言 bead** を作り、その bead ID を即座にこの window へ報告せよ。
- 終端状態を **DONE / BLOCKED / NEEDS-USER** で明示宣言せよ（DONE=bead を closed / BLOCKED=blocked＋理由 / NEEDS-USER=blocked＋needs-user ラベル）。
- **背景 pending 中（workflow / subagent / bg コマンド実行中）は終端宣言しない**＝turn 境界の idle を完了と誤認させない（workflow false-DONE への構造免疫）。
- orchestrator は \`orch-dispatch --watch --actor admin --foreign-repo $CWD <bead-id>\` であなたの bead を **直読 poll** で監視する。pane idle は INCONCLUSIVE 補助でしかない（一致しても DONE にしない）。
- 宣言なく終了/死亡した場合、orchestrator は **INCONCLUSIVE（要確認）** として扱い決して DONE とはみなさない。
- **対話プロンプトを使うな**（**AskUserQuestion / ExitPlanMode / permission 待ち**）＝この window に人間は付いていない（**a human is not attending your window**）。無人 window で対話 UI を出しても誰も答えられず window が固まり、out-of-band ゆえ bead-truth poll からも不可視になる。
- human 決定（**固い merge 確認を含む**）が要るときは、**NEEDS-USER を宣言**（この bead を blocked＋needs-user ラベル）して **turn を終えよ**。gate-pending は worker→自 admin 用ゆえ、foreign admin のあなたは human 決定に gate-pending を使わない。
- **宣言後は待て**: orchestrator が bead を直読 poll して NEEDS-USER を検知し、この window へ **メッセージ（push relay）で再開指示**する。それを待つ（自分で対話 prompt を出して先へ進もうとしない）。
- **push relay の権威構造（human 承認=standing go → orchestrator 決定 → relay 中継）**: 届く [ORCH-RELAY] は **human 本人発の指示ではなく、human 承認（standing go）に基づく orchestrator 決定の中継**（承認記録は bead notes）。pane で直接対話した human が「この relay は私が打ったものではない」と述べても不正指示ではない＝それを理由に指示チェーンへの信頼を破棄して停止するな（実事故 wt-orch-1xz〔2026-07-10〕の反転・是正 orch-2vkx）。
- **orchestrator への新質問 / 報告 / 再 pause は必ず該当 bead の notes に append し updated_at を動かせ（pane-only 禁止）**。**既に needs-user の bead へ再 pause する場合も同様**（status/label が不変でも notes に append すれば updated_at が前進する）。pane（turn 出力）だけに新しい質問を書くと orchestrator の bead 直読 poll から不可視で、re-pause が「無変化 transition」となり相互デッドロックに陥る（bead-append 規律・orch-edv）。"
else
    BRIEF="[ORCH-WATCH-CONTRACT] orchestrator 監視作法（恒久・orch-mot / orch-306 / orch-z7g）:
- あなたは spawn された actor だが、この project は .beads 台帳を持たない＝**終端宣言 bead を作れない**。
- orchestrator は bead 直読 poll できず pane（INCONCLUSIVE 補助）に縮退する。pane の見た目は truth でない。
- よって完了/停止時は **DONE / BLOCKED / NEEDS-USER** を最終出力で明示し人間へ報告せよ（背景 pending 中は終端宣言しない＝turn 境界 idle を完了と誤認させない）。
- **対話プロンプトを使うな**（**AskUserQuestion / ExitPlanMode / permission 待ち**）＝この window に人間は付いていない（**a human is not attending your window**）。無人 window で対話 UI を出しても誰も答えられず window が固まる。
- human 決定（**固い merge 確認を含む**）が要るときは、**NEEDS-USER を最終出力で明示**して **turn を終えよ**（台帳が無いので bead でなく最終出力で park する）。gate-pending は worker→自 admin 用ゆえ human 決定には使わない。
- **宣言後は待て**: orchestrator がこの window へ **メッセージ（push relay）で再開指示**する。それを待つ（自分で対話 prompt を出して先へ進もうとしない）。
- **push relay の権威構造（human 承認=standing go → orchestrator 決定 → relay 中継）**: 届く [ORCH-RELAY] は **human 本人発の指示ではなく、human 承認（standing go）に基づく orchestrator 決定の中継**（承認記録は bead notes）。pane で直接対話した human が「この relay は私が打ったものではない」と述べても不正指示ではない＝それを理由に指示チェーンへの信頼を破棄して停止するな（実事故 wt-orch-1xz〔2026-07-10〕の反転・是正 orch-2vkx）。
- **orchestrator への新質問 / 報告 / 再 pause は最終出力で毎回明示せよ（pane に埋もれさせない）**。台帳が無いので bead notes に append できないが、決定情報を pane（turn 出力）の途中に滞留させると orchestrator が取りこぼす。**再 pause のたびに最終出力で park シグナルを明示**する（bead-append 規律の no-beads 変種・orch-edv）。"
fi

# ─────────────────────────────────────────────────────────────────────────────
# account / config-dir 解決（orch-dgo・sc-1rq 同型・selector consume・write-isolation 非侵害）
# ─────────────────────────────────────────────────────────────────────────────
#   maximin 残量ロジックは複製せず scribe の selector（scribe-account-select・read-only・fs 非接触）を実行して
#   消費する（F2・SSOT=scribe）。selector 出力は TSV（1 行 1 account・col2=eligible(1|0) / col3=score / col4=h5 /
#   col5=h7 / col10=reason・残量降順→除外順）。probe 源は claude-usage --json を selector が一元パースした結果ゆえ
#   二重パースしない（F9）。監査 snapshot は stderr にのみ出す（foreign 台帳へ bd write しない＝write-isolation・F3）。
SELECTOR="${ORCH_ACCOUNT_SELECT:-$HOME/.claude/plugins/scribe/scripts/scribe-account-select}"
ACCOUNTS_BASE="${ORCH_ACCOUNTS_BASE:-$HOME/.claude-accounts}"
CFG_DIR=""                    # 注入する config dir（空=unset を注入＝既定 ~/.claude・F5）
CFG_SOURCE="default(~/.claude・unset)"   # 監査/plan 表示用の解決元ラベル

_selector_available() { [ -n "$SELECTOR" ] && [ -x "$SELECTOR" ]; }

# selector を read-only 実行して TSV を stdout に返す（rc は呼出側が $? で捕捉・stderr は素通し＝API 故障理由を見せる）。
_run_selector_tsv() { "$SELECTOR"; }

# F3: 選定候補ランキングの監査 snapshot を **stderr のみ**へ整形出力する（bdw write は移植禁止＝spawn 対象は
#   foreign 台帳ゆえ write-isolation 違反になる・sc-1rq facet⑥の note-write を意図的に除外）。
_account_snapshot_stderr() {
    local _tsv="$1" _chosen="$2"
    {
        echo "account-select（orch-dgo・監査は stderr のみ＝foreign 台帳へ bd write しない・F3）: chosen=$_chosen method=maximin(残量%=100-pct)"
        echo "account-select:   cols=label|eligible|score|h5|h7|pct5|pct7|resets5|resets7|reason"
        if [ -n "$_tsv" ]; then
            awk -F'\t' '{for(i=1;i<=10;i++){f=$i;if(f=="")f="-";printf "%s%s",(i>1?"|":"account-select:   "),f} print ""}' <<<"$_tsv"
        fi
    } >&2
}

if [ "$ACCOUNT" = "auto" ]; then
    # --account auto（F2/F7/F9）: 残量 maximin 上位 account を選定。selector 不在 / API 故障(exit 3) / 適格0件は
    #   fail-loud die する（silent に default 継承へ落ちない＝本 bug=silent 凍結 の再発防止。die は loud ゆえ
    #   silent 凍結を再導入しない・F7 の「spawn 継続」は明示 label / 未指定 default 限定で auto には及ばない）。
    if ! _selector_available; then
        echo "orch-spawn-admin: --account auto には selector が必要です（不在/実行不可: $SELECTOR）。" >&2
        echo "  残量 maximin 選定不能ゆえ fail-loud（default 継承へ silent 落ちしない・orch-dgo/F2）。--account <label> か 未指定 default で再実行せよ。" >&2
        echo "  selector パスは env ORCH_ACCOUNT_SELECT で差し替え可（SSOT=scribe・複製禁止）。" >&2
        exit 1
    fi
    _tsv=""; _rc=0
    _tsv="$(_run_selector_tsv)" || _rc=$?
    if [ "$_rc" -eq 3 ]; then
        echo "orch-spawn-admin: --account auto: claude-usage が読めません（selector API 故障 exit 3）。" >&2
        echo "  残量 maximin 選定不能ゆえ fail-loud（default 継承へ silent 落ちしない・orch-dgo/F7）。--account <label> か 未指定 default で再実行せよ。" >&2
        exit 1
    fi
    if [ "$_rc" -ne 0 ]; then
        echo "orch-spawn-admin: --account auto: selector が想定外 exit（$_rc）で失敗しました（orch-dgo）。" >&2
        exit 1
    fi
    _eligible="$(awk -F'\t' '$2=="1"{print $1}' <<<"$_tsv")"
    if [ -z "$_eligible" ]; then
        echo "orch-spawn-admin: --account auto: 適格アカウントが 0 件です（全 account が weekly 枯渇/認証切れ・orch-dgo/F7）。" >&2
        echo "  不適格と分かって default で admin を起こさない（fail-loud）。account の残量回復か再 login を確認せよ。" >&2
        _account_snapshot_stderr "$_tsv" "NONE(eligible=0)"
        exit 1
    fi
    _top="$(printf '%s\n' "$_eligible" | head -1)"
    # facet④: label "default" は ~/.claude（unset 意味論）へ写像・他 label は <base>/<label>。ゆえに top-by-usage を採用する。
    #   注: 採用 dir の健全性は下記「config-dir preflight」ブロックで CFG_DIR 決定後に一括検査する（cld-spawn/cld には
    #   CLAUDE_CONFIG_DIR を検証する preflight が無い＝verified・grep 該当ゼロゆえ下流に安全網は無い。orch-dgo self-review
    #   major）。検査は (a)dir 実在 (b)credentials (c)onboarding (d)guard plugin enable の 4 段（sibling worker と同水準）。
    #   auto は F8 境界を保つ＝採用 1 dir のみ検査し不健全でも次候補へ walk せず fail-loud die する（fail-open で
    #   無防備 admin を起こすより loud die が正・selector eligible=1 でも (d) plugin enable は認証独立ゆえ起こりうる）。
    if [ "$_top" = "default" ]; then
        CFG_DIR=""; CFG_SOURCE="auto:default(~/.claude・unset)"
    else
        CFG_DIR="$ACCOUNTS_BASE/$_top"; CFG_SOURCE="auto:$_top"
    fi
    _account_snapshot_stderr "$_tsv" "$_top"
    echo "orch-spawn-admin: --account auto → '$_top' を採用（残量 maximin 上位・源=$CFG_SOURCE・orch-dgo）。" >&2
elif [ -n "$ACCOUNT" ]; then
    # 明示 --account <label>（F12）: label 検証（scribe-spawn.sh:218-222 同型＝un-h289 保証の安定 interface ゆえ複製可）→
    #   <base>/<label> を注入。selector があれば当該 account の枯渇を loud 警告するが spawn は継続（明示ゆえ代替を殺さない・F7）。
    case "$ACCOUNT" in
        *[!A-Za-z0-9._-]*) echo "orch-spawn-admin: --account のラベルに使えない文字が含まれます: '$ACCOUNT'（許可: 英数 . _ -）" >&2; exit 2 ;;
        .|..)              echo "orch-spawn-admin: --account のラベルが不正です: '$ACCOUNT'（path traversal を拒否）" >&2; exit 2 ;;
    esac
    CFG_DIR="$ACCOUNTS_BASE/$ACCOUNT"; CFG_SOURCE="account:$ACCOUNT"
    if _selector_available; then
        _tsv=""; _rc=0
        _tsv="$(_run_selector_tsv)" || _rc=$?
        if [ "$_rc" -eq 3 ]; then
            echo "orch-spawn-admin: ⚠ --account $ACCOUNT: claude-usage が読めず残量 probe できません（selector API 故障）。spawn は継続（orch-dgo/F7）。" >&2
        elif [ "$_rc" -eq 0 ]; then
            _row="$(awk -F'\t' -v L="$ACCOUNT" '$1==L{print;exit}' <<<"$_tsv")"
            if [ -z "$_row" ]; then
                echo "orch-spawn-admin: ⚠ --account $ACCOUNT: claude-usage に当該 label の残量情報が無く probe 不能。spawn は継続（orch-dgo/F7）。" >&2
            elif [ "$(printf '%s' "$_row" | cut -f2)" = "0" ]; then
                echo "orch-spawn-admin: ⚠ --account $ACCOUNT は weekly 枯渇/認証劣化です（selector eligible=0: $(printf '%s' "$_row" | cut -f10)）。それでも spawn は継続します（明示指定ゆえ代替を殺さない・orch-dgo/F7）。silent 凍結に注意。" >&2
            fi
            _account_snapshot_stderr "$_tsv" "$ACCOUNT"
        fi
    fi
else
    # 未指定 default（F5）: unset CLAUDE_CONFIG_DIR を注入（従来挙動＝既定 ~/.claude）。加えて selector があれば
    #   default account の残量を probe し weekly 枯渇なら loud 警告（silent 凍結の再発防止・acceptance(3)/F7・spawn は継続）。
    CFG_DIR=""; CFG_SOURCE="default(~/.claude・unset)"
    if _selector_available; then
        _tsv=""; _rc=0
        _tsv="$(_run_selector_tsv)" || _rc=$?
        if [ "$_rc" -eq 3 ]; then
            echo "orch-spawn-admin: ⚠ 未指定 default: claude-usage が読めず残量 probe できません（selector API 故障）。spawn は継続（orch-dgo/F7）。" >&2
        elif [ "$_rc" -eq 0 ]; then
            _row="$(awk -F'\t' '$1=="default"{print;exit}' <<<"$_tsv")"
            if [ -n "$_row" ] && [ "$(printf '%s' "$_row" | cut -f2)" = "0" ]; then
                echo "orch-spawn-admin: ⚠ 未指定 default（~/.claude）は weekly 枯渇/認証劣化です（selector eligible=0: $(printf '%s' "$_row" | cut -f10)）。それでも spawn は継続します（default は代替を殺さない）。⚠ silent 凍結の再発リスク — --account auto か --account <label> を検討せよ（orch-dgo/F7・un-gakv incident）。" >&2
            fi
            _account_snapshot_stderr "$_tsv" "default"
        fi
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# config-dir preflight（orch-dgo self-review・major finding）: 注入する CFG_DIR の深い健全性検査
# ─────────────────────────────────────────────────────────────────────────────
#   下流（cld-spawn / cld）には CLAUDE_CONFIG_DIR を検証する preflight が **存在しない**（verified・grep 該当ゼロ）。
#   ゆえに不健全 dir を注入すると claude が login/onboarding TUI を出し無人 tmux window で hang するか、guard plugin
#   欠落のまま **無防備 admin** が黙って起動する（--disallowed-tools は AskUserQuestion を封じるが login TUI は封じない）
#   ＝本 script が撲滅対象とする「silent 凍結する admin」の別変種 + write-isolation を破りうる fail-open。
#   admin は worker（foreign 台帳の gate・bd write・git 破壊操作を担う）より特権的ゆえ、sibling worker が
#   probe_config_dir（scribe-spawn.sh・sc-rvq）で行う (a)dir 実在 (b)credentials(login) (c)onboarding
#   (d)guard plugin enable の 4 段検査を **同水準**で行う（admin だけ省く非対称は robustness-security 退行）。
#   SSOT 委譲（read-only 実行で消費）を第一に検討したが probe_config_dir は scribe-spawn.sh 内の埋込 shell 関数で
#   **standalone entry-point が無く**（verified・grep 該当ゼロ）、read-only 実行が構造的に不能ゆえ、label 検証
#   （scribe-spawn.sh:218-222・un-h289 保証の安定 interface）と同姿勢で**安定 interface の複製**で被覆する。
#   auto は F8 境界（fs preflight lazy-walk はしない）を保つ＝採用 1 dir のみ検査し不健全なら次候補へ walk せず
#   fail-loud die する（fail-open で無防備 admin を起こすより loud die が正・selector eligible=1〔認証〕でも
#   plugin enable〔認証独立〕は保証されないため auto でも (d) は起こりうる）。CFG_DIR 空=既定 ~/.claude は claude
#   起動側が持つゆえ対象外（挙動不変・F5）。dry-run でも走らせる（fs read-only の -d/-f/jq/-e ゆえ side-effect ゼロ）。
_preflight_config_dir() {
    local _d="$1" _src="$2"
    [ -n "$_d" ] || return 0
    # (a) dir 実在: 空/不在 dir 注入は login/onboarding TUI で無人 window が hang する（silent 凍結の別変種）。
    if [ ! -d "$_d" ]; then
        echo "orch-spawn-admin: 注入予定の config-dir が存在しません: $_d（源=$_src）。" >&2
        echo "  空/不在 config-dir で admin を起こすと login/onboarding TUI で無人 window が hang する（silent 凍結の別変種・orch-dgo）。" >&2
        echo "  --account のラベル typo か account 未セットアップを疑え（cld-spawn/cld には config-dir 検証 preflight は無い＝verified）。" >&2
        return 1
    fi
    # (b) credentials(login): 未 login dir は claude 起動が sign-in で停止する（doobidoo 82e2fc50・scribe sc-rvq 同型）。
    if [ ! -f "$_d/.credentials.json" ]; then
        echo "orch-spawn-admin: $_d/.credentials.json が無い＝未 login config-dir（claude 起動が sign-in TUI で hang・源=$_src）。" >&2
        echo "  当該 account で一度 login せよ（logged-out dir 注入は silent 凍結の別変種・explicit 指定でも認証劣化 dir は起こさない・orch-dgo/F7 は usage 枯渇限定で認証健全性には及ばない）。" >&2
        return 1
    fi
    # (c) onboarding 完了: hasCompletedOnboarding!=true は theme 選択 TUI でハングする（jq 優先・不在時 grep fallback）。
    local _cj="$_d/.claude.json"
    if [ ! -f "$_cj" ]; then
        echo "orch-spawn-admin: $_cj が無い＝オンボーディング未完了 config-dir（claude 起動が停止・源=$_src・orch-dgo）。" >&2
        return 1
    fi
    if command -v jq >/dev/null 2>&1; then
        if ! jq -e '.hasCompletedOnboarding == true' "$_cj" >/dev/null 2>&1; then
            echo "orch-spawn-admin: $_cj の hasCompletedOnboarding が true でない＝オンボーディング未完了（theme 選択→sign-in で hang・doobidoo 82e2fc50・orch-dgo）。" >&2
            return 1
        fi
    else
        if ! grep -Eq '"hasCompletedOnboarding"[[:space:]]*:[[:space:]]*true' "$_cj"; then
            echo "orch-spawn-admin: $_cj の hasCompletedOnboarding が true でない（jq 不在の grep 判定・orch-dgo）。" >&2
            return 1
        fi
    fi
    # (d) guard plugin enable: <dir>/plugins/<name> 実在（local dev plugin は symlink 存在が enable シグナル・dangling
    #     symlink は -e が偽＝真に不在扱い）。欠落で admin を起こすと bd-write-guard/file-write-guard/git-destructive-guard/
    #     session-start-role-inject が黙って無効化＝無防備 admin（write-isolation を破りうる fail-open・scribe sc-rvq 同型）。
    local _p
    for _p in scribe beads-bdw cmdtokens; do
        if [ ! -e "$_d/plugins/$_p" ]; then
            echo "orch-spawn-admin: plugin '$_p' が config-dir で enable されていません（$_d/plugins/$_p 不在・源=$_src）。" >&2
            echo "  plugin 欠落 dir で admin を起こすと bd-write-guard/file-write-guard/git-destructive-guard/session-start-role-inject が黙って無効化されます（無防備 admin を黙って起こさない＝write-isolation 保全・orch-dgo）。" >&2
            return 1
        fi
    done
    return 0
}
_preflight_config_dir "$CFG_DIR" "$CFG_SOURCE" || exit 1

# ─────────────────────────────────────────────────────────────────────────────
# env-file 内容の組み立て（config-dir 追随・F1/F5）
# ─────────────────────────────────────────────────────────────────────────────
#   cld-spawn native --env-file 経由で CLAUDE_CONFIG_DIR を注入する（sc-1rq=scribe-spawn.sh:234-243 と同型・
#   CLD_PATH wrapper は sc-1rq と別機構ゆえ不採用・F1）。cld-spawn の --env-file は既定 source（${CLD_ENV_FILE:-
#   ~/.cld-env}）を **排他置換** する（chain しない）ため、ホスト既定 env（認証/秘密＝session plugin 規約）を
#   保つべく既定 env-file を **先に chain-source** してから config-dir 行を **後勝ち** で置く（scribe worker
#   gate round4 と同型）。set→export（%q で source-safe）/ 空=unset（空文字 export でなく `unset`＝~/.cld-env
#   混入への fail-closed・scribe と同一 unset 意味論・F5）。
_DEF_ENV="${CLD_ENV_FILE:-$HOME/.cld-env}"
_DEF_ENV="${_DEF_ENV/#\~/$HOME}"   # 先頭 ~ を $HOME へ展開（%q が ~ をエスケープする前に・cld-spawn 既定解決と parity）
if [ -n "$CFG_DIR" ]; then
    _CONFIG_LINE="$(printf 'export CLAUDE_CONFIG_DIR=%q' "$CFG_DIR")"
else
    _CONFIG_LINE="unset CLAUDE_CONFIG_DIR"
fi
ENV_FILE_CONTENT=""
[ -n "$_DEF_ENV" ] && ENV_FILE_CONTENT+="$(printf 'source %q 2>/dev/null || true' "$_DEF_ENV")"$'\n'
ENV_FILE_CONTENT+="$_CONFIG_LINE"$'\n'

# env-file を作る（exec のみ mktemp＝side-effect・dry-run は作らず内容を plan 表示）。exec 後に cld-spawn は
#   env-file を launcher へ source 済みで返る（wait-ready・scribe consult/worker と同式）ため、trap EXIT で消せる。
#   ★exec でなく subprocess 実行に変えた（下記）: exec だと trap が発火せず env-file が leak するため。
#   mktemp は /tmp を hardcode せず $TMPDIR（sandbox 下では writable・self-test も同経路）を尊重する。
if [ "$DRY_RUN" = true ]; then
    ENV_FILE="<実起動時に mktemp: 上記 env-file 内容を書く>"
else
    ENV_FILE="$(mktemp "${TMPDIR:-/tmp}/orch-admin-env.XXXXXX")" \
        || { echo "orch-spawn-admin: env-file の作成に失敗しました（mktemp）" >&2; exit 1; }
    trap 'rm -f "$ENV_FILE"' EXIT   # 異常終了/正常終了とも temp を残さない
    printf '%s' "$ENV_FILE_CONTENT" > "$ENV_FILE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# fable preflight → Opus 1M fallback（orch-k660 leg1・sc-9q6 REUSE・実起動時のみ）
# ─────────────────────────────────────────────────────────────────────────────
#   admin spawn 既定 model=fable（user 裁定）。fable が利用不可（API/アクセス障害）のときだけ Opus 1M
#   （$FABLE_FALLBACK_MODEL=opus[1m]・xhigh は EFFORT で別途保証）へ **loud** fallback する（silent 降格しない）。
#   判定は scribe consult の sc-9q6 を REUSE: fable は最小 -p でも応答に 60s+ かかる一方、利用不可は ~5s で
#   fast fail する（rc≠0/124以外）。ゆえに rc=0（応答）or rc=124（timeout=受理され処理中）を **利用可**、
#   fast fail のみ **不可** とみなす（完了待ちだと正常 fable が常に偽不可＝恒常 opus 降格になる）。
#   --model 明示（MODEL_EXPLICIT）は fallback 対象外（常に優先）。preflight は実起動時のみ（dry-run は API を
#   叩かない＝副作用ゼロ）。seam ORCH_SPAWN_ADMIN_FABLE_PREFLIGHT=1/0 で可否を強制注入（bats/緊急時）。
fable_available() {
    case "${ORCH_SPAWN_ADMIN_FABLE_PREFLIGHT:-}" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    local rc=0
    timeout 15 "${ORCH_SPAWN_CLAUDE_BIN:-claude}" --model "$MODEL" -p "ok" \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]
}
# 実起動時のみ preflight（dry-run は fable のまま plan 表示し「実起動時に fallback」と注記する）。
if [ "$DRY_RUN" = false ] && [ "$MODEL_EXPLICIT" = false ] && [ "$MODEL" = "fable" ]; then
    if ! fable_available; then
        echo "orch-spawn-admin: ⚠ fable preflight 失敗 → admin を $FABLE_FALLBACK_MODEL（Opus 1M）で起動します（既定 fable の loud fallback・orch-k660/sc-9q6）。effort は $EFFORT を維持。" >&2
        MODEL="$FABLE_FALLBACK_MODEL"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# cld-spawn コマンド構築（spawn 専用＝payload なし・kickoff/effort は spawn 後に別 submission で注入）
# ─────────────────────────────────────────────────────────────────────────────
#   ★orch-k660: 従来は `-- "$KICKOFF"` を spawn 呼出に束ねて cld-spawn に注入させたが、`/effort ultracode` を
#     kickoff より前に別 submission として注入する必要があるため、spawn 呼出は **payload を持たない**（window を
#     建てるだけ）へ変更した。effort ultracode → kickoff の 2 submission は下記 _run_post_spawn_injections が
#     cld-spawn --inject-existing（read-back 再利用）で順に送る。
CMD=("$CLD_SPAWN" --cd "$CWD" --window-name "$WINDOW_NAME" --model "$MODEL" --effort "$EFFORT")
[ "$FORCE_NEW" = true ] && CMD+=(--force-new)
# 機構強制（orch-z7g layer ③ / orch-ce6）: 対話 tool を cld-spawn 経由で物理封鎖する（既定 AskUserQuestion,
# ExitPlanMode・--no-disallowed-tools で空にすると封鎖なし）。値は verbatim 1-argv で cld→claude へ透過し、
# 分割は claude が行う（括弧認識・space/comma）。**必ず `--`（kickoff）より前**に置く（cld-spawn は post-`--`
# を PROMPT へ落とすため）。空なら渡さない（=封鎖なし＝人間直付き admin 用の例外）。
[ -n "$DISALLOWED_TOOLS" ] && CMD+=(--disallowed-tools "$DISALLOWED_TOOLS")
# config-dir 追随（orch-dgo・F1）: env-file を cld-spawn へ渡す（既定 source を置換し config-dir を後勝ち注入）。
# **必ず `--`（kickoff）より前**に置く（--disallowed-tools と同じ理由＝cld-spawn は post-`--` を PROMPT へ落とす）。
# config-dir 追随の env-file を最後に付す（spawn 専用 opt はここまで＝payload は付けない）。
CMD+=(--env-file "$ENV_FILE")
# 終端宣言作法ブリーフを kickoff prompt へ**恒久注入**する（user kickoff の有無に依らず常に注入）。
# user kickoff があればブリーフの後に置く（discipline がタスクを frame する）。ブリーフ + user prompt を
# 改行で分節した単一 prompt に束ね、spawn 後に _run_post_spawn_injections が cld-spawn --inject-existing で
# 送る（cld-spawn へ payload として渡さない＝/effort ultracode を先に別 submission するため・orch-k660）。
KICKOFF="$BRIEF"
if [ "${#PROMPT_ARGS[@]}" -gt 0 ]; then
    KICKOFF="${KICKOFF}"$'\n\n--- 以下は人間/admin からの kickoff 指示 ---\n'"${PROMPT_ARGS[*]}"
fi

mode_label="$([ "$DRY_RUN" = true ] && echo 'DRY-RUN' || echo 'EXEC')"
echo "== orch-spawn-admin ($mode_label) =="
echo "  project : $PROJECT"
echo "  cwd     : $CWD"
echo "  window  : $WINDOW_NAME"
# model 行は MODEL_EXPLICIT でも分岐する（cell-quality gate minor#1）: --model 明示時は preflight/fallback を
#   実行しない（:684 のガード `[ "$MODEL_EXPLICIT" = false ]`）ため、dry-run でも preflight/fallback を予告しない。
if [ "$MODEL_EXPLICIT" = true ]; then
    echo "  model   : $MODEL（--model 明示ゆえ既定 fable / preflight / opus[1m] fallback は適用しない・orch-k660）"
elif [ "$DRY_RUN" = false ]; then
    echo "  model   : $MODEL（既定 fable・不可時 $FABLE_FALLBACK_MODEL へ preflight 済・orch-k660）"
else
    echo "  model   : $MODEL（既定 fable・実起動時に preflight し不可なら $FABLE_FALLBACK_MODEL へ loud fallback・orch-k660）"
fi
echo "  effort  : $EFFORT（--effort 明示注入で保証・cld-spawn --effort passthrough・orch-k660）"
if [ "$INJECT_EFFORT_ULTRACODE" = true ]; then
    echo "  ultra   : spawn 後に /effort ultracode を kickoff 前へ注入（送達確認つき・不受理は fail-open+loud・orch-k660 leg2）"
else
    echo "  ultra   : /effort ultracode 注入は見送り（--no-effort-inject＝fable+xhigh のまま）"
fi
echo "  account : $CFG_SOURCE"
echo "  cfgdir  : ${CFG_DIR:-<unset＝既定 ~/.claude>}（cld-spawn --env-file 経由で config-dir 追随・F1/F5）"
echo "  beads   : $BEADS_KIND ($BEADS_NOTE)"
if [ -n "$DISALLOWED_TOOLS" ]; then
    echo "  block   : 対話 tool 物理封鎖（機構強制・orch-ce6）= --disallowed-tools '$DISALLOWED_TOOLS'（cld→claude 透過）"
else
    echo "  block   : 対話 tool 封鎖なし（--no-disallowed-tools）＝人間直付き admin を想定（AskUserQuestion 温存）"
fi
echo "  brief   : 終端宣言作法を kickoff へ恒久注入（DONE/BLOCKED/NEEDS-USER・直読 poll 監視・pane は truth でない・対話禁止＋NEEDS-USER park＋push relay 待ち・新質問/再 pause は bead notes append で updated_at を動かす）"
echo "----------------------------------------------------------------------"

# ─────────────────────────────────────────────────────────────────────────────
# spawn 直後 watch 常駐ヒント（orch-z7g H3-ii / orch-ce6）
#   spawn した admin は poll-on-demand だと「固まって見える」ため、spawn 直後に監視 watch を **background 常駐**
#   させるのが運用。ただし foreign admin の終端宣言 bead ID は spawn 後に admin が作って報告する（本 script は
#   spawn 時点で知らない）ため、ここでは bead-id を <bead-id> プレースホルダにした **ちょうど実行すべき watch
#   コマンド** を stderr に emit する（orchestrator が admin の bead-id 報告を受けたら埋めて background 常駐する）。
#   ★background 常駐は orchestrator が **自分の harness（run_in_background）で** 行う＝harness 追跡下に置く。
#   本 script（spawn 起動器）から nohup/setsid で fork しない: 追跡外の孤児 watch は orch-mot（pane は truth で
#   ない・turn 境界 idle ≠ 完了）の監視規律と衝突する。ゆえに「実装」= 実行すべきコマンドの emit、「運用」=
#   orchestrator が run_in_background で常駐、で分離する（sentinel [ORCH-WATCH-RESIDENT] で grep 可能）。
_emit_watch_hint() {
    [ "$WATCH_HINT" = true ] || return 0
    local disp; disp="$(cd "$(dirname "$0")" && pwd)/orch-dispatch.sh"
    {
        echo "[ORCH-WATCH-RESIDENT] spawn 直後 watch 常駐（orch-ce6・admin の終端宣言 bead-id 報告後に background 常駐せよ）:"
        echo "  $disp --watch --actor admin --foreign-repo $CWD <bead-id>"
        echo "  ↑ orchestrator が自分の run_in_background（harness 追跡）で常駐する。孤児 fork しない（orch-mot 監視規律）。"
    } >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# spawn 後の submission 注入（orch-k660 leg2 + 併修 orch-sm6p）
# ─────────────────────────────────────────────────────────────────────────────
#   spawn 呼出は payload を持たない（window を建てるだけ）。effort ultracode → kickoff の 2 submission を
#   cld-spawn --inject-existing（inject-file + read-back 受理確認を REUSE）で順に送る。
INJECT_TIMEOUT="${ORCH_SPAWN_ADMIN_INJECT_TIMEOUT:-60}"
SESSION_STATE="${ORCH_SPAWN_ADMIN_SESSION_STATE:-$HOME/.claude/plugins/session/scripts/session-state.sh}"
VERIFY_ATTEMPTS="${ORCH_SPAWN_ADMIN_VERIFY_ATTEMPTS:-6}"
VERIFY_SETTLE="${ORCH_SPAWN_ADMIN_VERIFY_SETTLE:-2}"
RESEND_MAX="${ORCH_SPAWN_ADMIN_RESEND_MAX:-1}"

# _deliver <text> — cld-spawn --inject-existing で 1 submission を送り read-back 受理確認する（0=送達/非0=未達）。
#   spawn 専用 opt は付けない（cld-spawn が併用を fail-loud で弾く）。window 名は spawn した $WINDOW_NAME。
_deliver() {
    "$CLD_SPAWN" --inject-existing "$WINDOW_NAME" --timeout "$INJECT_TIMEOUT" -- "$1"
}

# _verify_turn_started — kickoff 注入後に turn が実際に開始したか（session-state=processing）を positive-proof
#   照合する（併修 orch-sm6p・boot-race defense-in-depth）。「入力欄が空=受理」という短絡は使わない（orch-sm6p
#   の根因訂正）。processing を一度でも観測 → 0（起動確認）。VERIFY_ATTEMPTS 回ずっと input-waiting/未確認のまま
#   （splash 滞留＝注入が飲まれた）→ 非0（未起動）。session-state 不在/不能は判定不能ゆえ非0（保守的＝偽 injected
#   を返さない）。seam ORCH_SPAWN_ADMIN_SESSION_STATE / _VERIFY_ATTEMPTS / _VERIFY_SETTLE。
_verify_turn_started() {
    local i st
    for ((i = 1; i <= VERIFY_ATTEMPTS; i++)); do
        st="$("$SESSION_STATE" state "$WINDOW_NAME" 2>/dev/null || echo unknown)"
        [ "$st" = "processing" ] && return 0    # positive proof: turn が起動した
        [ "$i" -lt "$VERIFY_ATTEMPTS" ] && sleep "$VERIFY_SETTLE"
    done
    return 1   # 一度も processing を観測できず＝turn 未起動（boot-race で注入が消失した疑い）
}

# _inject_kickoff — kickoff を送達確認つきで注入し、turn 起動を照合する（未起動なら再送→なお未起動なら非0）。
#   併修 orch-sm6p: cld-spawn read-back が偽陽性でも本層が turn 未起動を捕捉し、消失を偽 injected にしない。
_inject_kickoff() {
    local text="$1" resend=0
    while :; do
        if _deliver "$text"; then
            if _verify_turn_started; then
                return 0   # 送達 ∧ turn 起動を確認
            fi
            echo "orch-spawn-admin: ⚠ kickoff 注入後に turn 起動を確認できません（session-state≠processing・boot-race 疑い・orch-sm6p）。" >&2
        else
            echo "orch-spawn-admin: ⚠ kickoff の送達確認に失敗（cld-spawn read-back 未確認）。" >&2
        fi
        if [ "$resend" -lt "$RESEND_MAX" ]; then
            resend=$((resend + 1))
            echo "orch-spawn-admin: kickoff を再送します（$resend/$RESEND_MAX・orch-sm6p 消失対策）。" >&2
            continue
        fi
        return 1   # 再送しても turn 未起動＝fail-loud（呼出側が扱う）
    done
}

# _run_post_spawn_injections — spawn 後の submission 列（effort ultracode → kickoff）を実行する。
#   effort ultracode: 送達確認のみ（スラッシュコマンドは turn を起こさない可能性ゆえ turn 照合しない）・不受理は
#     fail-open+loud（admin は fable+xhigh のまま稼働継続）。kickoff: 送達確認＋turn 起動照合（fail-loud）。
_run_post_spawn_injections() {
    if [ "$INJECT_EFFORT_ULTRACODE" = true ]; then
        if _deliver "/effort ultracode"; then
            echo "orch-spawn-admin: /effort ultracode を注入しました（送達確認済み・orch-k660 leg2）。" >&2
        else
            echo "orch-spawn-admin: ⚠ /effort ultracode の注入に失敗しました（不受理/送達失敗）。admin は fable+xhigh のまま稼働継続します（fail-open・--no-effort-inject で本注入を見送れる・orch-k660 leg2）。" >&2
        fi
    fi
    # kickoff（終端宣言ブリーフ + user prompt）は turn 起動照合つきで注入（fail-loud）。
    if ! _inject_kickoff "$KICKOFF"; then
        echo "orch-spawn-admin: ✗ kickoff の注入が確認できませんでした（送達失敗 or turn 未起動・再送も不発・orch-sm6p）。admin window は起動済みだが kickoff が届いていない可能性＝要 admin 確認（scribe-inject 再送 or window 実照合）。" >&2
        return 1
    fi
    return 0
}

if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: would spawn (payload なし＝window 起動のみ):'
    printf ' %q' "${CMD[@]}"
    printf '\n'
    # env-file は dry-run では作らない（side-effect ゼロ）。注入予定内容を plan 表示する（config-dir 追随の可視化）。
    echo "DRY-RUN: env-file 内容（実起動時に mktemp して cld-spawn が source＝既定 env を chain-source→config-dir 後勝ち・F1）:"
    while IFS= read -r _l; do echo "DRY-RUN:   $_l"; done <<<"$ENV_FILE_CONTENT"
    # spawn 後の submission 列を plan 表示（effort ultracode → kickoff）。KICKOFF は生 echo ゆえ ASCII sentinel
    #   [ORCH-WATCH-CONTRACT] がそのまま載る（dry-run の sentinel 検証はこの経路で成立する）。
    echo "DRY-RUN: spawn 後の submission 列（cld-spawn --inject-existing $WINDOW_NAME・orch-k660）:"
    if [ "$INJECT_EFFORT_ULTRACODE" = true ]; then
        echo "DRY-RUN:   [1] /effort ultracode（送達確認のみ・不受理は fail-open+loud・leg2）"
        echo "DRY-RUN:   [2] kickoff（終端宣言作法を kickoff へ恒久注入・送達確認＋turn 起動照合・fail-loud・orch-sm6p）"
    else
        echo "DRY-RUN:   [1] kickoff（終端宣言作法を kickoff へ恒久注入・送達確認＋turn 起動照合・fail-loud・--no-effort-inject で ultracode 見送り）"
    fi
    echo "DRY-RUN: --- kickoff 本文（ブリーフ + user prompt）---"
    while IFS= read -r _l; do echo "DRY-RUN:   | $_l"; done <<<"$KICKOFF"
    _emit_watch_hint
    exit 0
fi

# 実行モード: cld-spawn 実体が要る。
if [ ! -x "$CLD_SPAWN" ]; then
    echo "orch-spawn-admin: cld-spawn not found/executable: $CLD_SPAWN" >&2
    echo "  ORCH_SPAWN_CLD で実体パスを差し替え可。" >&2
    exit 1
fi

# spawn 直後 watch 常駐ヒントを cld-spawn 実行前に emit。
_emit_watch_hint

# ★subprocess 実行（exec しない・orch-dgo）: env-file を trap EXIT で確実に rm するため exec を廃した。cld-spawn は
#   wait-ready 後に返る（launcher が env-file を source 済み）ため、返った後に env-file を消して問題ない。
# 1) spawn（payload なし＝window 起動のみ）。失敗（非0）なら注入へ進まず透過 exit。
"${CMD[@]}"
_spawn_rc=$?
if [ "$_spawn_rc" -ne 0 ]; then
    echo "orch-spawn-admin: cld-spawn の spawn が失敗しました（rc=$_spawn_rc）＝注入へ進みません。" >&2
    exit "$_spawn_rc"
fi

# 2) spawn 後の submission 列（effort ultracode → kickoff）。kickoff 未達は fail-loud（非0）。
_run_post_spawn_injections
exit $?

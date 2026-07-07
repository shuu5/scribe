# scribe 手動 administrator プロトコル（規約 SSOT）

> **このファイルの位置づけ**
> 2026-06-10 の Wave1+2（10 PR 分）で **実証済み**の admin 手動プロトコルを成文化したもの。scribe-design.md §14 の v0 第 1 本柱「手動 admin プロトコルの成文化」に対応する。
> **規約 SSOT** はこのファイル。project CLAUDE.md は本文の重複を持たず、ここへのポインタに縮小済み（本リポ CLAUDE.md は現にポインタのみ・経緯 = 別 cell C4 / bd un-0c6）。道具（`scripts/`・C3）はここの手順をコード化し、role 別 SessionStart 注入（C2）は role ごとに必要な節をここから引く。
>
> **成文化の規律**: 本書は実証済み運用と一言一句レベルで整合させ、創作・推測で規約を盛らない。各節末に一次出典を明記する。**本書は orchestration の how（admin が実際に踏む手順）に focus する** — 設計の why は `docs/scribe-design.md`、**ワークフローの方法論（ultracode 強度の選び方・quality patterns・戦術層 D1-D7 の運用）は `docs/methodology.md`** が SSOT（本書はそれらを転記せず、必要箇所でポインタを置くに留める）。
>
> **信頼度の凡例**: `verified`（実機で確認済）/ `deduced`（実証ログ・notes から導出）。推測（inferred）は本書に載せない。

---

## 0. 全体像 — administrator の 1 issue ライフサイクル

```
[起票・依存 wire(admin)] → spawn(§1) → worker 実装(§2 prompt 規約に従う)
   → worker self-report + gate-pending ラベル(§4・close しない) → gate funnel(§5: 報告監査 → cell-quality gate review
   → findings 直読 → merge gate(§5.4 二段判定・merge 自体は非トリガー) → squash/auto-merge → go-live → admin が close → cleanup) → dolt push 同期点(§3)
監視(§6) は spawn 〜 close まで全域で走る。
```

- **admin = anchor**。graph の所有者であり、唯一の `bd dolt push` 同期点。
- **worker = worktree セッション**。自 issue の進捗だけを書き、graph は触らない（§3 B/hybrid）。
- 役割の env 判定仕様は `docs/role-context-spec.md`（`SCRIBE_ROLE` > cwd `.worktrees/` 判定 > anchor 既定）。
- **needs-user タスク**（worker 着手不可・人間判断依存）は通常フローに乗らず §7 の解決フロー（WF pre-bake → grill-consult → admin 起票/着手）へ分岐する。

---

## 1. spawn 規約

worker を 1 issue = 1 worktree = 1 window で起動するときの命名・起動の規約。

> **道具ポインタ（bd un-7hx）**: 本節の spawn 手順（実在検証 → `git worktree add` → **origin 健全性 marker の捕捉**（un-1n1・下記）→ task prompt 生成 → `cld-spawn` → monitor）は **`scripts/scribe-spawn.sh` で 1 コマンド化済み**（worker モード既定・`--consult` で consult 起動・`--dry-run` で実 spawn せず arg-echo）。注入を受けた admin が道具の存在に気づかず手作業で再現しないよう、まず `scribe-spawn.sh --help` を確認すること（道具は本節の規約をコード化するだけで規約は変えない）。

> **origin 健全性 marker の捕捉（bd un-1n1）**: `scribe-spawn.sh` は `git worktree add` 直後に canonical origin URL を **per-worktree marker**（`.git/worktrees/<name>/scribe-origin.marker`）へ捕捉する（`scribe-origin-guard.sh capture` 相当）。worktree は anchor と `.git/config`（remotes）を共有し、worker が origin を mutate すると anchor+全 worktree の origin が壊れるため（un-v5x 実害）、admin が gate funnel（§5）の push 前に現在 origin と marker を照合（`verify`）して汚染を検知・復元できるようにする。marker は共有 config と別物（per-worktree git dir）ゆえ worker の config 汚染を生き延び、working tree 外ゆえ worker の編集スコープ外。

> **既定 anchor/repo の linked-worktree ガード（bd un-ag7）**: `--anchor`/`--repo` を **明示せず**（cwd 既定）に実行した cwd が linked（副）worktree のとき、scribe-spawn は worktree 作成・consult 起動・spawn の前に **fail-loud** する（副 worktree を anchor にすると bd 参照が解決できず、副 worktree を repo にすると `.worktrees` のネスト・誤 base=副 branch HEAD になる・2026-06-12 実害）。検出は git plumbing（main worktree と `git rev-parse --show-toplevel` の差分・naming 規約には依存しない）。明示 `--anchor`/`--repo` 時は cross-repo cell の意図的 override を壊さないため不発火（REPO/ANCHOR は各々が既定か否かで独立判定）。エラーは検出した副 worktree と推定される真の main worktree を示し、そこへ cd するか明示指定するよう案内する。

### 命名規約（consumer 照合が依存する硬い契約）

- **window 名** = `wt-<完全bd id>`（例: `wt-un-led`）。
- **branch / worktree 名** = `spawn/<完全bd id>-HHMMSS`（例: `spawn/un-led-073745`）。`-HHMMSS` サフィックスは並列 spawn の衝突回避のため維持する。
- **「完全 bd id」を使う**こと（短縮・別名にしない）。fleet-monitor の worker↔window 照合（`◆`）が `wt-` 剥がし → 末尾 `-<数字>` 剥がし → `awk $1==id` 完全一致に依存するため、命名を崩すと稼働中 worker が検出されなくなる（under-mark = 安全側だが主機能が死ぬ）。
- **consult window 名**（sc-3pq L3・grill 確定 2026-06-24）= **grill-consult**（admin が `--context` で brief を渡すモード・§7）は `consult-<grill-issue>`（例: `consult-sc-3pq`）。`wt-<id>` と同型の id 完全一致命名で、fleet-monitor / degraded watcher が「どの grill-issue の consult が沈黙したか」を一意に紐付けられる（grill-issue は grill-consult が bd notes へ決定を書くため in_progress＝board に正しく点灯する）。**plain consult**（grill-issue 無し）は `consult-HHMMSS`（id 無し→時刻で一意化。read-only の議題参照 issue は in_progress とは限らず board を誤点灯しうるため id 紐付けしない）。reuse 偽成功の構造封鎖は `--force-new` が担う（window 名の毎回一意性に非依存＝中断リカバリの再 spawn〔§7〕でも新規保証）。**consult- の degraded 自動検知（watcher 拡張）は scriptorium 所有・cross-project**（impl は scriptorium/uns・scribe は命名＋STATUS 語彙の contract leg＝sc-3pq notes が決定 SSOT）。

### 起動コマンド

- `cld-spawn --bd-id <完全bd id> --model opus "<worker prompt>"`。
  - **`--model opus` は必ず明示**。新規セッション既定が `claude-fable-5` のため、明示しないと worker が fable を継承しコスト爆発する。
  - `--bd-id` は window 名フォールバック（`--window-name` 未指定時 `wt-<id>` 採用）に使う。**非空で不正な `--bd-id` は警告なしで旧命名へ silent fallback する**文書化済み契約 → spawn ヘルパー（C3）側で `bd show <id>` による実在確認を行い fail-loud にする（un-it7 設計引き継ぎ）。
- spawn-latency は cld-spawn の confirm-receipt 込みで **2-3 秒/cell**（実測・pilot N=3）。

### tmux 参照は window ID（`@N`）で行う（dotted id 衝突の回避）

- bd 子 issue の id はドットを含む（例 `un-3sh.3.5`）ため、**window 名 `wt-un-3sh.3.5` を `tmux -t` に渡すと window.pane 区切り構文と衝突**し、名前指定の `capture-pane`/`send-keys` が解決不能になる（admin の wave3 monitor が「window 消失」誤判定した live finding・実証済）。
  - 影響するのは「名前を `-t` に渡す」操作のみ。`new-window -n`（作成）と `#{window_name}`（一覧）は無傷 → fleet-monitor の名前文字列照合は影響なし。
- **対処（命名規約は変えない）**: window 作成時に window ID（`@N`）を捕捉し、以後の `-t` 参照は ID で行う。または `list-windows` で name→ID 解決してから `-t` に渡す。名前のドット sanitize は consumer（完全一致照合）との跨リポ同時変更が要るため**しない**。
  - cc-session の `session-comm.sh` / `session-state.sh` は `resolve_target()` で名前→`session:index` を先に解決してから `-t` を使うため既に dot-safe。

> 一次出典: bd un-cbi notes（命名規約 producer 追従 PR・dotted id の tmux -t 衝突 live finding／いずれも `verified`）/ bd un-it7 notes（spawn ヘルパー設計引き継ぎ 3 点）/ scribe-design.md §14 道具節。

### sandbox（既定 on・opt-out=`SCRIBE_SANDBOX=0`・worker を OS レベル隔離）[sc-u53]

worker は **既定で** Claude Code 組込み bwrap sandbox に封じられる（**default-on・sc-u53**。旧 default-off + `SCRIBE_SANDBOX=1` opt-in から反転）。非 sandbox で走らせたい worker/host は `SCRIBE_SANDBOX=0` を明示して opt-out する（**opt-out 時は本番 spawn 経路 byte 不変**＝cld-spawn 起動行が sandbox 有無で 1 byte も変わらない・`"0"` のときだけ off・未指定/その他は on）。`scribe-spawn.sh` が `git worktree add` 後に worktree の `.claude/settings.local.json` を生成し、worker の Bash subprocess を「自 worktree + 共有 `.git` + anchor の `.beads` + bdw 鍵の置き場（lock_dir の SSOT は **canonical bdw〔beads-bdw plugin〕** ＝ `gen-sandbox-settings.sh` は `scripts/bdw lock-dir` で問い合わせて consume する・sc-vae cutover で 3 copy drift〔uns/scriptorium/scribe〕を撲滅。既定 `$HOME/.cache/bdw-locks` ＝ scribe 以外の bd writer（orch/uns bdw）と byte 一致する収束点・sc-xs2。parent を丸ごとでなく専用 lock dir のみ grant＝最小化）」へ限定する。それ以外への **Bash subprocess の**書込みは OS 外壁（bwrap）が拒否する（`bypassPermissions` と直交）。**ただし bwrap が封じるのは Bash 経路のみ**で、built-in の `Edit`/`Write`/`NotebookEdit` は permission 層（`bypassPermissions` 下で素通し）で動き bwrap では縛れないため、worker の Edit/Write を worktree 境界へ縛るのは別レイヤの PreToolUse guard（`scripts/hooks/edit-write-guard.py`・sc-649）が担う（SBX-ESC-1）。生成 settings は worktree の `info/exclude` で ephemeral 化され worker の `git add` から保護される。

- **守る/守らないの正直な境界（sc-451）**: sandbox が封じるのは **worker Bash subprocess の write のみ**（built-in Edit/Write は tool 層 guard・sc-649 が別レイヤで縛る）＝**完全隔離ではない**。**read は host 全体・network egress は非封鎖**（読めた秘密は持ち出せる）ため、敵対的 prompt を掴んだ worker の秘密読出し・持出しは sandbox では防げない。また admin/consult は**非 sandbox のまま** worker 生成物（bd notes・commit・diff）を ingest する非対称があり、現状は信頼前提＝gate funnel（§5）の ground-truth verify が運用上の補償。全体像・到達限界一覧の SSOT = `scripts/sandbox-spike/README.md`「脅威モデル」節。
- **ホスト前提**: `bubblewrap` + **`socat`**（CC sandbox の network proxy・両方必須）+ userns が使えること（`kernel.apparmor_restrict_unprivileged_userns=0` の sysctl 緩和、または bwrap への **targeted apparmor profile** のいずれか＝ホスト全体 userns を緩めない方式も可）。
- **dep-preflight（default-on の安全弁・sc-u53）**: default-on ゆえ deps 欠如 host では `failIfUnavailable` で worker が起動拒否される。これを spawn が **worktree を作る前**に `scripts/scribe-sandbox-preflight.sh`（実体 = `scribe-lib.sh` の `scribe_sandbox_preflight`。bwrap/socat/jq + **userns 実プローブ** `bwrap --ro-bind / / --unshare-user true`。jq は settings 生成器 `gen-sandbox-settings.sh` の hard 依存ゆえ sandbox 機構固有の前提として検査する〔jq 不在を見落とすと worktree add 後に gen が落ち orphan を残す・round3 gate〕。global sysctl は**読まず**「実際に userns を作れるか」だけ見る＝targeted apparmor profile 方式でも信頼できる唯一の signal）で先回り検査する。欠如時の方針（**sc-u53 ユーザー確定 = fail-loud + opt-in fallback**）:
  - 既定 = **fail-loud で停止**（黙って無防備に走らせない＝fail-closed 規律。orphan worktree も残さない）。actionable に「deps を入れる / `SCRIBE_SANDBOX=0` で opt-out / `SCRIBE_SANDBOX_FALLBACK=1` で恒久 fallback」を案内する。
  - `SCRIBE_SANDBOX_FALLBACK=1` を置いた host **だけ**、deps 欠如時に**警告して非 sandbox で続行**する（明示 opt-in した host のエスケープ）。
- 設計・検証・rollback の詳細 SSOT = `scripts/sandbox-spike/README.md`（dogfood = bd `sc-1gu`）。

> 一次出典: bd `sc-1gu`（spike a/b 5/5 実証 + 本番 direct-gen 実装 + live e2e 起動実証）/ CC docs `code.claude.com/docs/en/sandboxing.md`（`verified`）。

---

## 2. worker prompt 規約

admin が worker に渡す起動 prompt（spawn の最初の inject）が満たすべき規約。

- **autonomous 規律（最重要・bd sc-46h）**: worker は**自律実行**し、**人間の確認・許可・指示を待って停止してはならない**（admin は監視するが対話しない＝admin の `capture-pane` / `bd show` は read-only で worker を中断しない）。出力に「中断された」「割り込み」等のノイズが見えても止まらず、疑わしければ同じコマンドを再実行し **git/bd の実体**（`git -C <worktree> log` / `cd <anchor> && bd show <id>`）で事実を確認してから進む（推測や前回出力の記憶で判断しない）。**停止してよいのは 2 例外のみ**: ① env 健全性 gate の `ENV_DEGRADED` 検出時（その時だけ `STATUS: blocked` を書いて止まる）、② その `STATUS: blocked` 自体を bdw で書けない zombie 変種（下記 §6 degraded-zombie）では pane sentinel（`SCRIBE-ENV-DEGRADED: <id> <理由>` を応答テキスト行頭に出力）を残して止まる（sc-c7c・dogfood 実証済）。背景: sc-498 litmus で worker1 が早期に確認待ちで idle 化し fleet を詰まらせた（admin nudge で回復）。根本原因の出力汚染（cmdtokens 系・cross-project）は本規律では緩和に留まり、hallucinated 完了は Layer2（admin の commit-count 独立照合・§5 step1）と sc-16i（自己 close→gate-pending）が backstop として捕捉する。
- **編集可スコープの明示**: worker が触ってよいパス境界を prompt で明示する（例: 「編集可は新規リポ配下のみ・コピー元は読むだけ」）。スコープ外の編集を求める後続要求は worker が自分で拒否できるようにする。
- **anchor 絶対パスを焼き込む**: worker の cwd は **worktree** であり、そこからは anchor の bd graph（`.beads`）が解決しない。よって契約参照（`bd show`）と bdw 規律行（§3）に **anchor（bd graph 所在）の絶対パスを埋め**、worker が `cd` 先を自力発見せずに済むようにする。spawn ヘルパー（`scripts/scribe-spawn.sh`）は `--anchor`（既定 cwd）を絶対パスへ正規化して保持済みの `$ANCHOR` を `build_prompt` に焼き込む。
- **tests 同梱（test-first）**: worker は実装に対する self-test を**自分で用意**し、リポ直下に置く。pilot では `selftest-<id>.local.sh`（untracked・コミットしない・fail-closed）の形で運用した。
- **selfTest は fail-closed**: assert が 1 つでも落ちたら非 0 で終了し、「未検証なのに DONE」を構造的に防ぐ。cell-quality WF の `selfTestCmd` に渡し、gated autoFix の self-test 段に fail-closed で効かせる。
- **cell-quality WF を worker が直接呼び出す**: gate review/verify を worker タスク内で 1 回回す（直接呼出・named-WF 明示・`scriptPath` 直指定）。これは admin の gate funnel（§5）とは別物で、worker 自身の自己点検。WF の強度（fan-out 本数・verify 票数）と dimensions の組み方は `docs/methodology.md`（§1 強度キャリブレーション・§3 D1-D7 運用）に従う。
  - **道具ポインタ（bd un-3yc）**: この自己点検用 cell-quality args(JSON) の組み立ては **`scripts/scribe-selftest-args.sh --worktree <path> --self-test <cmd> <bd-id>` で 1 コマンド化済み**（`doImplement`/`doPlan` を `false`・`autoFix` を `true` にハードコード固定 + `selfTestCmd` を必須化＝必須観点の欠落・autoFix の fail-closed ゲート抜けを上流で塞ぐ）。§5 の admin gate（`scribe-gate-args.sh`）と対称の道具で、**責務だけ非対称**（gate=read-only / 自己点検=worker 実装済み前提の gated autoFix）。手作業で args を組まず道具を使うこと。
- **報告に WF 返り値 JSON + `receivedArgs` を必須**で含める: Workflow tool の args は呼び出し側 serialization 依存で **script に JSON 文字列のまま届くことがある**（非決定的）。args 前提の WF が全デフォルト実行に落ちると single モードで空 diff を 0 findings で false-clean に返す経路がある（bd un-2yy）。よって worker は「WF が実際に受け取った args（`receivedArgs` / `parseFailed`）」を報告に含め、admin が args 解決の成否を一次監査できるようにする。
- **新規リポ / main 直 work cell では `baseRef` を prompt 段階で明示供給する**（bd un-k02）: 自己点検 WF の diff は `baseRef...HEAD`（既定 `origin/main`）で取る。新規リポや main へ直 commit する cell では `origin/main` が無い／HEAD と同一で diff が空になり、WF が「空 diff」を escalate する。これを避けるため、そうした cell では worker prompt に `baseRef`（自己点検 args の `--base`）を明示供給する。
- **共有 `.git/config`（remotes / hooks / config 等）を mutate しない**（bd un-1n1）: worktree は anchor と `.git/config` を **共有**するため、worker が origin/remote を書き換えると anchor+全 worktree の origin が壊れ、admin の push が破綻する（2026-06-16 un-v5x funnel 実害＝worker が push-gate 試験で dummy origin を設定し anchor push が 134s タイムアウト）。remote 検証が要るなら **throwaway bare repo / 別 clone** を使う（`remote.*` は git が共有 config からのみ読むため `git config --worktree` でも隔離できない＝git 2.43 で検証済み・物理隔離は →un-6nf）。これを prompt の「禁止」節に列挙する。
- **sandbox（既定 on・opt-out=`SCRIBE_SANDBOX=0`・sc-u53）下の stage/commit**（bd sc-yqa）: CC 組込み sandbox は worker cwd の既知 dotfile（`.bashrc`/`.gitconfig`/`.mcp.json` 等 11 個）と `.claude/` 設定（`agents`/`commands`/`skills`/`workflows` 等 9 個）を `/dev/null` character device として null-mount し無害化する（CC のセキュリティ機構・**設定で外せない**＝verified・GH#17258）。git は device の add を拒否するため `git add -A`/`git add .` が rc=128 で落ち**空 commit**（degraded worker）を生む。対策は worker が `git add -A` でなく **`scripts/scribe-add`**（char/block device 等の非通常ファイルを**ファイル型**で弾き、通常ファイルと symlink を stage する薄ラッパ＝device に `git add` を一切かけない。`[ -h ] || [ -f ]` で symlink を deref せず保つ）で stage し commit する（`cd <worktree> && scribe-add && git commit -m ...`）。型ベースゆえ CC が null-mount リストを増減しても壊れない（名前リストに結合しない）し、共有 `info/exclude` を汚さない（非 sandbox worktree への漏れゼロ＝論点3 を完全解消）。worker prompt には SCRIBE_SANDBOX 時のみこの規律を注入する。worker が手癖で `git add -A` に戻れば loud に rc=128 で失敗し §5 step1 / §6 の 0-commit 検出網が salvage に回す（サイレント漏れより安全）。drift（CC の挙動変化）は `verify-sandbox-e2e.sh` が scribe-add 実走で番人検知（sc-yqa 4b）。
  - **E 案（info/exclude に dotfile 列挙）を棄却した経緯**: 当初は worktree の `info/exclude` に null-mount dotfile を入れ `git add -A` を機械スキップさせる案だったが、(1) CC は `.claude/*`（普通にコミットされる設定）も null-mount すると e2e で判明し共有 `info/exclude` の漏れが広い、(2) per-worktree exclude は git が読まず真の scope 化には `extensions.worktreeConfig`＝共有 `.git/config` mutate（un-1n1 違反）が要る、(3) 名前リストは CC のリスト churn に脆い——の 3 点で B（scribe-add 型ベース）へ切替えた（sc-yqa grill）。
  - **cell-quality WF の gated autoFix も scribe-add 化する**（bd sc-u4u）: 上の規律は worker **自身**の commit を守るが、worker 自己点検（§2 上）で回す cell-quality WF の **gated autoFix**（Fix/implement agent が confirmed 修正後に `git commit --amend` で取り込む）の stage 経路は別物で、ここにも scribe-add 規律が要る。**default-on（sc-u53）で全 worker がこの autoFix 経路を踏む**ため、Fix agent が手癖で `git add -A` を打てば同じ rc=128 死で amend 失敗→degraded になる（sc-yqa の gate round1 で発見・当時は opt-in 下ゆえ refuted だったが default-on で prerequisite に昇格）。対処は **`scribe-selftest-args.sh` が `scribeAddPath`（= `<scribe>/scripts/scribe-add` の絶対パス）を常に args へ載せ**、WF が受けると Fix/implement の stage を `git add -A` でなく scribe-add に固定する。**SCRIBE_SANDBOX 検出に依らず常時供給**するのは、scribe-add が `git add -A` の安全上位互換（通常ファイルでは等価・device のみ型で弾く）ゆえ非 sandbox でも無害で、どの hop でも sandbox 判定が要らず決定論的だから（litmus は Fix agent が LLM 非決定で穴を隠しうるので deterministic に潰す）。sandbox 内からの scribe-add 実行は CC の `--ro-bind / /`（読み/実行は全 FS 許可・書込みのみ allowWrite 制限）で成立（sc-yqa e2e PASS=4 で実証）。なお scribeAddPath は WF 側で path 安全文字のみ許可し、稀に install path がそれを外れる exotic ケース（空白/非ASCII を含むディレクトリ等）では scribe-add 固定が外れるが、その際 WF は **loud に warn** して旧経路への後退を可視化する（silent な degraded にしない＝決定論主張をこの可視化で担保・sc-u4u gate）。WF autoFix 経路の実 sandbox 実証は sc-498（litmus）が担う。
- **完了は gate-pending ラベル + DONE（自己 close しない・§4 反転）**: worker は実装 + self-test pass + PR/commit が揃ったら、自 issue に `gate-pending` ラベルを付与（`bdw update <id> --add-label gate-pending`）して DONE を報告する。**自分で `bd close` しない**——close は admin が gate+merge 後に行う（worker の自己 close が scriptorium の gate 待ち検知をすり抜けた構造原因＝orch-ol0 反転）。
- **禁止事項を定型で明示**: `bd create` / `bd dep` / `bd dolt push` / `bd close`（自 issue の close も admin 専有＝gate+merge 後・§4） / GitHub への push / admin window への tmux inject / スコープ外編集 / follow-up の bd create / **共有 `.git/config`（remotes/hooks/config）の mutate**（§3 B/hybrid 境界・un-1n1）を prompt の「禁止」節に列挙する。

> 一次出典: doobidoo `3b838167`(Wave2)・un-8q5 pilot 横断 GOTCHA（WF args の JSON 文字列化・false-clean／`verified`）/ bd un-2yy（args defensive parse）/ bd un-cbi notes（worker の receivedArgs 報告実例・全 12 キー受領／`verified`）/ bd un-1n1（共有 .git/config mutate 禁止 = un-v5x funnel 実害の対策①）/ bd un-k02（新規リポ/main 直 cell の baseRef 明示供給）/ bd sc-yqa（sandbox null-mount〔dotfile 11 + .claude 設定 9〕の `git add -A` rc=128 回避 = `scribe-add` 型ベース stage〔B〕・doobidoo `48ddb387`/`9300b72f`）。

---

## 3. B/hybrid 役割境界（worker↔beads）

worker↔beads = **B/hybrid で確定**（scribe-design.md §8）。台帳は anchor の単一 embeddeddolt を全 worktree が redirect 共有する（siloed ではない）。

### worker の権限（自 issue の進捗のみ・bdw 経由）

- 自分が claim した issue の status/進捗を **auto-share DB に直接書く**: `bd update --claim` / `--append-notes` / `gate-pending` ラベル付与（`--add-label gate-pending`）。**自 issue の close はしない**（admin が gate+merge 後に close・§4 反転）。
- **write は必ず `bdw` 経由で直列化する**: `cd <anchor リポ> && scripts/bdw <subcmd>`。`.beads/embeddeddolt` は embedded Dolt = single-writer で、N 並列 worker が同一 issue へ read-modify-write 系 write を並行すると last-writer-wins で lost-update が起きる（実測 un-gmq: 15 並列 append-notes → 10 しか残らず 5 件消失。bdw 直列化で 15/15）。pilot N=3 では bdw により bd write 事故ゼロを実証。
  - bdw は fail-closed: READ と確証できるサブコマンドだけ lock なしで素通しし、未知/全 write は flock 取得後に実行する。

### worker が**してはいけない**こと（graph は admin の所有物）

- `bd create` / `bd dep`（依存 wire）/ assignment / `bd dolt push` / **`bd close`（自 issue の close も admin 専有＝gate+merge 後・§4）** は**明示禁止**。worker は graph を操作しない。
  - **構造的背景**: `bd prime` の SessionStart 注入が全セッション（worker 含む）へ無条件に「非自明な作業は着手前に `bd create`」を入れており、これが worker の `bd create` 逸脱の**構造原因**（2026-06-10 に 1 件の逸脱を prompt 明記で解消した実績＝注入の問題と確認・`verified`）。対処は role 別注入（`docs/role-context-spec.md`）で worker への一律 `bd create` 注入を止めること。
- **follow-up は notes で提案する**: タスク化が必要になっても worker は自分で起票せず、自 issue の `--append-notes` に「admin への起票候補」として書き出すに留める。**起票は admin が行う**。

### admin の所有

- issue 作成・依存グラフ・assignment・最終判断・**`bd dolt push` / remote 同期点**を所有する（§5 末で push）。

> 一次出典: scribe-design.md §8（B/hybrid 確定）/ anchor リポの `scripts/bdw`（scribe 出荷物ではない substrate・flock 直列化の WHY・un-gmq 実測）/ doobidoo `13447a54`（role 別 PRIME 分割 = worker bd create 逸脱の構造原因の発見／`verified`）/ bd un-cbi notes（worker が follow-up を bd create せず notes 提案した実例）。

---

## 4. gate-pending → gate → close → errata 規約

worker の完了申告から gate・merge・close・追補までの規約。**順序が肝**（worker は gate-pending を出すだけ・close は admin が merge 後）。

> **規約反転（sc-16i / orch-ol0・2026-06-26）**: 旧規約は「worker が PR-up 時に自己 close（close=作業を出した・merge 済みではない）」だった。これを反転し、**worker は自 issue を close せず `gate-pending` ラベルを付与して DONE を出す。close は admin が gate+merge を済ませた後に行う**。理由 = (1) scriptorium の gate 待ち検知が `gate-pending` ラベル依存で、scribe worker の自己 close が CLOSED を先に出すと検知に乗らず**検知漏れが 2 度発生**（orch-2ax / orch-2o6・user 指摘で発覚。検知側の defense-in-depth = orch-9l1 で別途 fix 済、本規約は**根本予防**＝worker が gate-pending を明示する側）、(2) CLOSED の意味が「merge 済み・完了」に**一意化**する（旧「closed だが未 merge」の曖昧状態を解消）、(3) 依存 cell の ready 化が **merge 後**に正される（自己 close は未 merge work で dependents を早期 ready 化していた）、(4) degraded worker の「commit 0 のまま CLOSED」罠（§6）が**構造消滅**する（worker が close しないので false-CLOSED を出せない）。§7 の grill-issue が既に admin 専有 close なのと**一貫**する。

- **gate-pending = PR-up 時の自己申告（close しない）**: worker は実装 + self-test pass + PR/ローカル commit が揃った時点で、自 issue に `gate-pending` ラベルを付与（`cd <anchor> && scripts/bdw update <id> --add-label gate-pending`・bdw 経由）し DONE を報告する（report に PR 番号 / commit / WF 返り値を含める）。**worker は自分で close しない**（close は「merge 済み」を意味し、merge は admin の gate 後）。
- **gate は gate-pending の後**: admin の gate funnel（§5）は worker が gate-pending を出した**後**に走る。gate-pending → gate → merge → close の順序を保つ。
- **close = admin が gate+merge 後に行う**: gate 通過 → merge（§5.6）後、admin が当該 issue を `bd close`（理由に PR 番号 / squash commit）。**close できるのは admin だけ**（§5 funnel step6 に組込み）。
- **errata = open(gate-pending) のまま同一 branch へ追補**: gate で見つかった findings の修正は、issue を **open（`gate-pending` ラベルのまま）**で同一 branch に追補コミットして対応する（PR を新規に開き直さない）。merge 前なので reopen は不要。
- **gate findings は notes-append 必須**: gate で出た findings は当該 issue の `--append-notes` に追記して永続化する（review trail を残す。`bd update --notes` の上書きで消さない）。
- **reopen は merge 後の substantive 再実装のみ**: admin が close（merge 済み）した後に設計レベルの作り直しが要るときだけ reopen する。merge 前の findings は上記 errata（open のまま追補）で処理し reopen しない。

> 一次出典: doobidoo `3b838167`(Wave2)・un-8q5 pilot（errata 規約 = findings は notes-append・同一 branch 追補・substantive のみ reopen を gate 2 件で初運用し機能／`verified`）/ doobidoo `ac9022d8`(Wave1)/ **orchestrator orch-ol0（gate-pending 恒久化 = worker 自己 close を反転し admin merge 後 close へ・scriptorium 検知漏れ orch-2ax/orch-2o6 の根本予防・検知側 defense-in-depth = orch-9l1）**。

---

## 5. gate funnel 手順

worker の close 後に admin が踏む funnel。**判断は admin の手動**（v0 では自動化しない・scribe-design.md §14「v0 で作らないもの」）。

### gate の 3 義務（orch-tdj・acceptance ground-truth 検証）

gate funnel は worker/actor の**完遂報告を額面で信じない**。step1 の commit-count 独立照合（Layer2・§5 step1）と同じ「self-report を信用せず admin が reliable env で裏取りする」規律を、契約 acceptance の検証まで拡張した 3 義務を課す。背景 = 完遂総括の**丸ごと捏造**を ground-truth 検証が捕捉した実証（`orch-wzq`＝actor が虚偽の完遂サマリを出したが、gate の独立再実行が実体との乖離を捕捉した事例）。

- **(a) acceptance の逐条判定義務**: gate は契約 bead の acceptance を**項目ごとに PASS/FAIL を明示**して逐条判定する（総括的な「概ね OK」で通さない）。各項目の判定根拠（どの成果物・どの検証で PASS/FAIL としたか）を当該 issue の `--append-notes` に残す（§4 の findings notes-append と同じ review trail を永続化する）。
- **(b) selfTestCmd を gate が自ら再実行する義務**: gate は actor の「self-test PASS」報告を信じず、契約 bead の verification 欄（`検証:`）の **selfTestCmd を自ら再実行**して ground-truth を取る。actor 報告の丸ごと捏造（`orch-wzq`）は self-report の机上監査では捕捉できず、gate の独立再実行のみが捕捉する。selfTestCmd は bead notes の **verification 欄の value から取得**する（欄の位置規則は下記 snapshot 節と共通）。再実行が FAIL した／実行できない場合は merge せず errata（§4）or salvage（§6）へ回す。
- **(c) acceptance snapshot mismatch = auto-merge 資格剥奪 → 人間 ratify 昇格**: dispatch 入口で bead notes に焼いた acceptance snapshot（下記形式）と、gate 時点の現 acceptance が **mismatch**（契約が dispatch 後に書き換わった）していたら、その cell は §5.4 の auto-merge 資格を**剥奪**し、機械判定に関係なく**人間 ratify へ昇格**する（fail-closed）。契約すり替えを merge が素通しするのを防ぐ（§5.4 (c) と対応）。
- **(d) transcript-forensics 義務（先例 4 件で verified）**: gate は worker transcript（`.jsonl`）の tool_use / tool_result **件数**と marker 出現**件数**を機械列挙し、worker の完遂報告の裏取りに使う（幻影＝ツール結果の confabulation は「叩いたと主張するが transcript に対応する tool_use/tool_result が無い」形で露見する）。先例 = un-df2（`ff754603`）/ orch-wzq（`3c3bf2b2`）/ orch-8dl / scm-5gp（`9a08fe2b`）が transcript-verified。**件数のみを記録し、一致した生 marker 行は notes へ焼かない**（§6 監視トリガー衛生・引用/説明でも monitor が実 signal と誤発火するため）。

> **幻影 backstop の機械化と read-only 分離（sc-ex2・十全性監査 wf_c2cd03d4 agent D・2026-07-07）**: 幻影（confabulation）に対し **worker の自己検証は構造的に無力**——worker 側 Layer1（env-probe）は env 劣化の検出であって幻影の検出ではなく、worker 自身の self-test 実行（Layer4 相当）は幻影発生源が自分自身ゆえ自分を検証できない。唯一の**意味的** backstop は **admin が reliable env で selfTestCmd を独立再実行する** (b) だが、その実行者 admin 自身も xhigh 長ターンの幻影発生源で、(b) の再実行に**機械強制も証跡も無かった**（塔の頂点に検証層が無い＝orch-8is で routine merge が人間非トリガー化した帰結）。対策:
>  - **ground-truth の機械証跡化（(b)/(d)/commit-count を『実際に叩いた証跡』に）**: (b) selfTestCmd 再実行の exit code + 出力 sha256 + cmd sha256、commit-count、changed-files（touch-check）、(d) transcript-forensics 件数を bd notes へ機械記録する。**道具ポインタ = `scripts/scribe-gate-attest.sh probe --worktree <path> --base <sha> --self-test <cmd>`**（証跡を stdout へ emit）→ **`scripts/scribe-gate-attest.sh record --id <id> --anchor <path>`**（bdw 経由で当該 issue notes へ append）。手作業で証跡文字列を組まず道具を使うこと。**証跡は検知文字列を verbatim で焼かない設計**（件数・ハッシュのみ・§6）。
>  - **read-only subagent 分離（項目2）**: selfTestCmd 再実行は admin 本体の長ターンでなく **read-only subagent（`scribe:explore`）**に `probe` を叩かせて独立させる（`probe` は bd も git も**書かない**＝read-only を構造強制。selfTestCmd 実行と git read / transcript read のみ）。admin 本体の幻影が再実行結果を汚さない。write 段（`record`）だけが admin に残る。
>  - **liveness≠completeness（commit-count の限界）**: Layer2 の commit-count は **liveness**（作業が commit として永続したか）であって **completeness**（acceptance を満たしたか）**ではない**。`probe` は commit-count に加え **changed-files** を列挙し、`--acceptance-path <glob>` 指定時は acceptance 対応面への **touch-check**（diff が対応ファイルに触れているか）まで機械基盤を出す——commit があっても対応面 0-touch なら completeness は未達と可視化する。逐条 PASS/FAIL の**意味判定**は (a) のとおり admin 領分（道具は判定を捏造せず未記入 scaffold を emit するのみ・admin/subagent が根拠付きで埋め、埋めたものを `record` する）。
>  一次出典: bd sc-ex2（十全性監査 wf_c2cd03d4 agent D の最高 severity＝幻影 backstop の機械化 + read-only 分離・実装 `scripts/scribe-gate-attest.sh` + `tests/gate-attest.bats`）。

#### acceptance snapshot の形式・照合手順（orch-dispatch 入口 gate と byte 整合・orch-vji land 済）

orch 側 `orch-dispatch` 入口 gate が焼く acceptance snapshot と、その照合手順を以下に写す（scribe gate はこの形式を前提に (c) を判定する。両所の byte 整合が SSOT）:

- **snapshot 形式**: bead notes への `[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1] bd=<id> sha256=<hex>` という **header 行** + 表示専用の **verbatim 本文**（人間可読の acceptance 全文）。
- **照合**: 最新 header の `sha256=` と、**現 acceptance の再計算**（`sha256(JSON-decoded 生文字列 UTF-8・zero-normalization)`）の**比較のみ**で行う。**verbatim 本文は再 hash しない**（表示専用ゆえ末尾改行が入り preimage と非同一になるため）。snapshot が複数あれば **append 順の最後**を採る。
- **verification 欄の位置規則**: `verification:` / `検証:`（半角/全角コロン・大小無視）は**行頭マッチ**。「機械 probe 不能」の宣言は**全文どこでも**マッチ。selfTestCmd は verification 欄の value から取得し、(b) で gate が自ら再実行する。

1. **worker 報告の監査**: worker の self-report（commit hash / WF 返り値 JSON / `receivedArgs` / self-test 結果 / 成文化・実装した内容）を読み、args 解決の成否（`parseFailed`/`receivedArgs`）と self-test の pass を一次確認する。
   - **commit-count 独立照合（sc-sau Layer2・bd sc-ydg）**: worker の self-report を額面で信じず、admin が **reliable env**（自分の anchor）で `git -C <worktree> rev-list --count <base>..HEAD` を独立に叩き、**0 commit でないこと**を裏取りする。base は spawn 時に `scribe-spawn.sh` が SHA へ凍結し、worker の env-probe（Layer1）の `verify --base` に焼いたのと**同一 SHA**（admin Layer2 と worker Layer1 が同じ base を見る）。既定 `HEAD` をリテラルで焼くと `HEAD..HEAD`＝常に 0-commit となり健全 worker を誤 blocked にする回帰（un-k02 同型）を避けるため、spawn 時点の commit を凍結する。worker 側 env-probe（sc-sau **Layer1**・§6 salvage）は env 劣化時に worker 自身を `STATUS: blocked` で止めるが、劣化が probe をすり抜ける／worker が誤って done を申告する残余に備え、admin gate でも commit 実在を確認する（degraded worker は **commit 0 のまま gate-pending DONE を出しうる**＝**gate-pending/DONE 単独を信用しない**・§6。worker は close しないので CLOSED は出ない・§4）。0 commit を検知したら merge せず §6 salvage へ回す。
2. **cell-quality gate review（read-only・worktree 指定）**: admin が cell-quality WF を **read-only** で起動し、worktree を指定して gate review をかける（admin gate は dimensions 必須 4 観点固定＝`docs/methodology.md` §3 D3・強度の選び方は同 §1）。**snapshot 合成（PR#346）により worktree 指定で WF が `base...HEAD` diff を自動取得する**ため、diff の静的供給は不要（argshim も退役・defensive parse が tool レベルの string 化を吸収）。← だからこそ本リポは先頭に空の initial commit を置き、`base...HEAD` の合成が機能するようにしてある。
   - **道具ポインタ（bd un-7hx）**: この gate review 用 cell-quality args(JSON) の組み立ては **`scripts/scribe-gate-args.sh --worktree <path> <bd-id>` で 1 コマンド化済み**（`doPlan`/`doImplement`/`autoFix` を read-only にハードコード固定＝一次監査が実装/autoFix に化けない）。手作業で args を組まず道具を使うこと。
3. **findings 直読（refuted も鵜呑みにしない）**: WF の返り値 findings を admin が直読検証する。WF 内の adversarial verify が `refuted` と判定した finding も鵜呑みにせず、admin が一次監査する（gate は薄い一次監査・WF 返り値の机上承認ではない）。スコープ外（他リポ・他 cell の領分）を求める finding は却下し、却下理由を記録する。
4. **merge gate（二段判定・merge 自体は非トリガー）**（orchestrator grill orch-8is・2026-06-26 ユーザー ratify）: **merge という行為そのものは人間確認の必須トリガーから外す**。ユーザーは自分でコードを読まないため「全 merge を最後に確認する」のは情報量ゼロで意味がなく、実質の安全弁は下記の **AI gate（findings 直読＝step3）と不可逆カテゴリの機械判定**に置く。確認を取るのは以下 **(a)/(b)（orch-8is 二段判定の 2 分類）および (c)（orch-tdj で scribe 側に追加した独立 fail-closed トリガ・orch ①-④ 番号を持たない）**に該当する変更**だけ**で、それ以外は admin が確認なしで auto-merge する（step6）。以下「二段判定」は orch-8is の (a)/(b) 中核を指す語で、(c) はそこに追加された第 3 の fail-closed トリガとして step6 の auto-merge 条件に**同格で**効く:
   - **本 §5.4 が merge-gate 分類の規約正本（canonical SSOT）**（`orch-an2` で本節へ改訂・`orch-d6b` G6 で byte 整合）: orchestrator 面の top-spec §1.1 と orchestrator `CLAUDE.md` は本節を指す（top-spec 末尾「規約正本は scribe `protocol.md` §5.4」）。両所の番号（①-④）は本節の (a)/(b) と次のとおり対応する（＝同一分類の別番号・byte 整合の実体）— orchestrator **①（事前合意からの逸脱）＝本節 (b)**（AI gate が「明確な合意違反」と高確信した時のみ確認＝**機械 fail-closed ではない**。逸脱は diff パスで機械判定できないため本節では (b) 側に置く方が構造的に正しい）、orchestrator **②③④（規約ファイル／全ホスト配布物／新規 outward）＝本節 (a) の ①②③**（diff touch の機械 fail-closed）。両所が terse に記す「規約ファイル（`CLAUDE.md`・`docs/*.md`）」は本節 (a)① の**精密列挙**（enforced rule／役割契約 の**規範文書のみ**）へ **defer** し、how-to（`docs/methodology.md`）／ rationale（`docs/scribe-design.md`）は非該当＝(b) 側。＝「`docs/*.md`」の字面で how-to／rationale まで固い側へ巻き込む over-trigger（runbook 非対称）は起こさない（分類の実体は本節・各リポは自 docs を同原則で列挙する）。
   - **(a) 不可逆カテゴリ（機械判定・無条件 fail-closed）**: diff が次のいずれかに touch したら、**AI の主観的判断に関係なく必ずユーザー確認を取る**（diff のパスで機械的に判定し、グレーでも止める＝fail-closed）:
     - ① **規約ファイル** = **enforced rule / 役割契約**を定める文書: `CLAUDE.md` / `docs/protocol.md`（本書）/ `docs/role-context-spec.md` / `.beads/PRIME.md` など（how-to の `docs/methodology.md` と設計 rationale の `docs/scribe-design.md` は enforced rule でないため非該当＝実装ズレと同じ (b) 側・orch-8is で確定）。
     - ② **全ホスト配布物**（`hooks/` / グローバル設定（`~/.claude/` 配下）/ plugin 出荷物（`scripts/` ・`workflows/` ・`skills/`）など全ホスト・全セッションへ波及するもの）
     - ③ **新規 outward**（外部公開・新規 repo 作成など不可逆で外向きの操作）
   - **(b) 設計ソフトズレ（AI gate を信頼・fail-open 寄り）**: (a) に触れない実装レベルのズレは、AI gate（step3 の findings 直読）が「**事前合意（grill / 明示指示）からの明確な逸脱**」と**高確信**したときだけ確認を取る。逸脱と言い切れないグレー（設計判断の許容幅）は確認せず通す（fail-open）。merge が情報量ゼロというユーザー裁定の裏返しで、safety を「AI gate が事前合意との乖離を能動検知する」側へ寄せる設計。
   - **(c) acceptance snapshot mismatch（機械 fail-closed・§5「gate の 3 義務」(c)）**: dispatch 入口で焼いた acceptance snapshot（§5「acceptance snapshot の形式・照合手順」）と gate 時点の現 acceptance が **mismatch** した cell は、(a)/(b) の判定に関係なく **auto-merge 資格を剥奪し人間 ratify へ昇格**する（契約が dispatch 後にすり替わった＝合意基盤が動いたため fail-closed）。照合は最新 header の `sha256=` と現 acceptance の再計算（zero-normalization）の比較のみで行う（§5 snapshot 節）。
   - **適用範囲**: 本二段判定は self-dev に限定せず、**foreign（他 project の cell）を含めて広く**適用する（cross-ledger の push 経路も §5 origin verify と同じ gate chain を通る・§8）。
   - **事後証跡（auto-merge 時の必須記録）**: (a)/(b)/(c) のいずれにも該当せず admin が確認なしで auto-merge した場合は、対象 issue の `--append-notes` に **`auto-merged: <gate 判定要約> + <PR/commit>`** を必ず残す（無確認 merge を後から追跡可能にする＝§4 の gate findings notes-append と同じく review trail を永続化する）。
5. **push 前に origin URL 健全性を verify（汚染なら fail-loud + 復元）**（bd un-1n1）: squash merge / GitHub push の **前に** リポの `origin` URL が spawn 時 canonical のままかを照合する。worktree は anchor と `.git/config`（remotes）を共有するため、worker が origin を mutate すると anchor+全 worktree の origin が壊れ push が破綻する（2026-06-16 un-v5x 実害＝134s タイムアウト+gh が known host 無しと誤認）。汚染を検知したら **fail-loud し、canonical へ復元してから** push する（汚染したまま push しない）。
   - **道具ポインタ（bd un-1n1）**: spawn 時の canonical origin 捕捉と gate 時の照合・復元は **`scripts/scribe-origin-guard.sh {capture,verify,restore} --worktree <path>` で 1 コマンド化済み**。spawn は `scribe-spawn.sh` が `git worktree add` 直後に `capture`（canonical origin を per-worktree marker `.git/worktrees/<name>/scribe-origin.marker` へ捕捉）を自動実行する。gate では `scribe-origin-guard.sh verify --worktree <path>`（健全=exit 0 / 汚染=exit 非0・canonical URL を stdout）を push 前に走らせ、汚染時は `--restore` 併用 or `restore` サブコマンドで復元する。marker は per-worktree の private git dir に置く＝共有 config と別物ゆえ worker の config 汚染を生き延び、working tree 外ゆえ worker の編集スコープ外。
   - **marker 不在 verify が「意図的 fail-open（skip=exit 0）」である理由と将来の反転条件**（bd sc-vuu facet2）: `verify` は spawn 時 marker が無いと「照合不能」として **skip=exit 0**（warn のみ）に倒す。これは意図的な fail-open であり、(a) origin 無しのリポ（dogfood・新規リポ）は保護対象が無く `capture` も no-op で marker を作らないため、その verify が gate を素通りすべき、(b) marker 捕捉導入前に作られた既存 worktree との後方互換、の二点で正当化される（＝「未検証だから止める」ではなく「保護対象が無いから素通す」）。この default を **fail-loud（marker 不在=非0）へ反転**してよいのは、次の移行条件が**両方**揃ったとき: ① 全 spawn 経路が marker 捕捉を保証する（origin 付きリポで marker 不在＝「捕捉漏れ」と確実に言える状態）、かつ ② gate funnel が `verify` を自動配線で必ず通す（手動 skip の温存が不要になる）。それまでの間、marker 不在を厳格化したい個別 gate は additive opt-in の **`scribe-origin-guard.sh verify --require-marker`**（marker 不在は origin 現存なら fail-loud・origin 無しなら exit0・既定挙動は不変）を使う。「`capture` 失敗で marker が無い（=origin 現存・真の漏れ）」と「origin 無しで marker が無い（=正当 no-op）」を verify が区別する強化は `--require-marker` 下で実装済み（origin 現存=fail-loud / origin 無し=exit0 / origin 現存 probe 失敗=fail-closed＝sc-cw6）。
6. **squash merge → go-live → close（条件付き auto-merge）**: step4 の merge gate 判定で **(a)/(b)/(c) のいずれにも該当しなければ admin が確認なしで auto-merge**（squash merge）し、go-live（配布・反映）する（(c) acceptance snapshot mismatch も (a)/(b) と同格の fail-closed トリガ＝該当すれば auto-merge せず人間 ratify）。**auto-merge した場合は step4 の事後証跡（`auto-merged: <判定要約> + <PR/commit>` を対象 issue notes へ append）を必ず残す**。確認対象に該当した場合は**ユーザー確認が取れてから** squash merge する。**merge 後、admin が当該 issue を `bd close`**（理由に PR / squash commit）——worker は自己 close しない（§4 反転）ので close は admin の funnel に属する。
7. **cleanup**: worktree / branch / window を掃除する（`@N` 参照で window を kill・§1）。
   - **道具ポインタ（bd un-7hx）**: この cleanup（worktree remove / branch 安全削除 / window kill / `bd dolt push` リマインド）は **`scripts/scribe-cleanup.sh <bd-id>` で 1 コマンド化済み**（破壊操作は確認プロンプト付き・`--yes` で一括承認・**force 系は使わない**・`bd dolt push` は admin 専用ゆえ自動実行せずリマインドのみ）。手作業で掃除を再現せず道具を使うこと。
8. **dolt push 同期点**: 一連の funnel が片付いた区切りで admin が `bd dolt push` して台帳をマシン間同期する（§3・worker は push しない）。
   - **publish 鮮度 advisory lint（sc-e93 / orch-tya・案A）**: dolt push 同期点で admin は `scripts/scribe-publish-freshness.sh check` を走らせ、`federate-publish` ラベル bead（§8 の公開候補）が**公開後に内容 drift**（**updated_at** が最終 publish より grace 秒超で新しい＝内容更新後に再 publish されず published surface が古いまま）になっていないかを advisory に self-check する。これは funnel 全体でなく**公開面のグローバル check**（全 `federate-publish` bead を走査）ゆえ per-issue の step1-7 でなく本同期点に置く（cross-machine/cross-project 同期の直前に公開面の鮮度を一望する）。
     - **信号 = updated_at**（Q1・orch parity と**同一信号**＝parity の二重定義と checksum の照合ズレを避ける）。**provenance = bead notes の `federate-published-at:` marker**（Q2・admin が再 publish 時に `scribe-publish-freshness.sh mark-published <id>` で記録する。marker append 自身の updated_at 自己 bump は grace〔既定 5s〕が吸収する）。
     - **warn・非block**（既定 exit 0・drift/unpublished は merge/push を止めない・`--strict` は将来の機械 caller 向け opt-in で手動 funnel では使わない）＝§8「scribe は受容周知のみで enforce しない」と両立する **advisory 上限線**（Q3。強 block=hook は §8 と正面衝突ゆえ不採用）。drift を見つけた admin は再 publish（内容整合を取り `mark-published` で provenance 更新）or notes 追補で解消する。
     - orch の `orch-reconciliation-parity.sh`（read-only・human notice）を**待たない早期 self-check**で、その代替でなく**補完で並走**する（Q4=案A）。orch 側の突合（完全一致ラベル `federate-publish`/`reconcile-published` + updated_at）は**現行のまま**（`orch-reconciliation-parity.sh` は変更不要）。
     - **道具ポインタ**: `scripts/scribe-publish-freshness.sh {check,mark-published}`（READ の check は bdw 不要／WRITE の mark-published は bdw 経由で直列化・§3）。env seam・grace 調整は同スクリプト冒頭ヘッダ参照。

- **N（並列 worker 数）の上限 = admin funnel 律速**: gate 逐次 + errata 往復 + ユーザー確認が直列なので、funnel がボトルネック。pilot 実測で **N=3 が快適**、N=4-5 はタスク所要が異質な編成なら成立。
- adversarial gate の検出力（実証）: dead import の fail-open 結合 / env 検証の octal fail-open（`SESSION_COMM_SUBMIT_ENTER_MAX=008` が bash 算術で不正 octal → 修正自体が無音失効）/ base-staleness アーティファクトの正確な診断などを、いずれも merge 前に捕捉した。

> 一次出典: doobidoo `3b838167`(Wave2)・`ac9022d8`(Wave1)・un-8q5 pilot（funnel 純 review 10-13min/PR・N 上限 = funnel 律速・snapshot 合成で diff 静的供給不要・adversarial gate 検出力／`verified`）/ bd un-1n1（origin URL 健全性 verify = un-v5x funnel 実害の対策③・push 前 verify+復元を規約化）/ **orchestrator grill `orch-8is`（2026-06-26 ユーザー ratify: step4 を二段判定へ改訂＝merge 自体を非トリガー化・(a)不可逆カテゴリ〔規約/全ホスト/新規 outward〕の機械 fail-closed + (b)設計ソフトズレの AI gate fail-open・auto-merge 時の bd notes 証跡。決定 SSOT = orch-8is notes / scribe 側追跡 = bd sc-97f / orchestrator 側追跡 = orch-an2）** / **sc-e93 / orch-tya（step8 の publish 鮮度 advisory lint = 案A・Q1-Q4 orchestrator 合意: Q1 信号=updated_at〔orch parity と同一信号〕 / Q2 provenance=bead notes `federate-published-at:` marker / Q3=warn非block〔§8 と両立する advisory 上限線〕 / Q4=案A〔orch parity notice を待たない早期 self-check・代替でなく補完で並走〕。実装 = `scripts/scribe-publish-freshness.sh` + `tests/publish-freshness.bats`）** / **orch-tdj / orch-vji / orch-wzq（「gate の 3 義務」= gate は acceptance を逐条 PASS/FAIL 判定し・actor 報告を信じず selfTestCmd を自ら再実行し・acceptance snapshot mismatch は auto-merge 資格剥奪→人間 ratify 昇格。ground-truth 検証が完遂総括の丸ごと捏造を捕捉した実証 orch-wzq が動機・snapshot 形式/照合は orch-dispatch 入口 gate〔orch-vji land 済〕と byte 整合。scribe 側追跡 = 第5便 RiderA）**。

---

## 6. 監視

spawn 〜 close まで worker pane を観測する。**v0 は (a) 最小 = admin が手動監視**（背景 supervisor は v1+・scribe-design.md §10/§14）。

### 監視の規律（folio incident 0264028f の教訓）

admin が worker 群の稼働を見るときの 3 規律。folio admin の停止見落とし（**自前の bash poll** が 160 分 silent cap で失効・完了判定を **bd CLOSED 依存**にし・degraded worker を構造的に検出不能で、停止をユーザー指摘まで気づけなかった）を構造原因として規約化したもの:

- **自前の監視 poll を作らない**: 監視は本節の primitives（busy 判定 regex・worker↔window 照合）で行う。fleet 全体のボードが要るなら scriptorium の `fleet-monitor.sh`（**人間向け** read-only タスクボード・所有は scriptorium〔orch-7hc で uns→scriptorium 移管〕）を**人間が**ちらっと見る——`◆`=worker 窓検出 / `✗`=**stall**（窓消失だが直近 active＝生きていた cell が窓を失った）/ `◇`=窓不在かつ古い（admin epic とみなし非警報）。AI admin が独自に時間 cap 付き poll を書くと、cap の silent 失効・誤った healthy 判定で停止を見逃す（folio 実害）。
- **完了 signal を額面で信用しない（worker は close しない・§4 反転）**: 新モデルでは worker は自己 close せず、完了申告は **gate-pending ラベル + DONE 報告**（close は admin が merge 後）。degraded worker（env 劣化で self-verify が嘘になる cell）は健全な完了に到達できない／誤って DONE を申告しうる。「gate-pending が無い＝まだ健全に稼働中」とも「gate-pending が付いた＝完了」とも額面で読まず、窓の生死（fleet-monitor の `✗` stall）と commit 実在（§5 step1 の Layer2 照合）を併読する。**commit 0 × 窓消失**を salvage トリガとして扱う。**窓が生存していても、pane の idle-at-prompt 持続（busy regex 不一致が数分継続）× commit 0 は zombie 変種の signature**（下記 salvage 第 3 変種・folio-nufl）として同じく salvage トリガに扱う——窓の生死だけを見ると zombie を取りこぼす。
- **長時間 worker は proactive に確認する（admin 自省）**: 想定所要を大きく超えた worker は monitor 任せにせず、admin が能動的に pane / commit を覗いて生死を確かめる。v0 の検知は受動（admin が気づく）ゆえ、自省が最後の砦。

> `consult-`（grill-consult）window の沈黙を fleet-monitor が**自動検知**する拡張は **v1・sc-3pq**（fleet-monitor の degraded 検出拡張・所有は scriptorium）。本節の規律はその自動検知に依存せず v0 手動監視で成立する。fleet-monitor の「使用義務」を厳密文言化するのは sc-3pq の確定 contract と整合させてから（salvage 手順〔下記〕は incident+memory で実体確定済ゆえ先行・bd sc-ydg 注）。

### bd ラベル/notes ベース完了検知の作法（監視トリガー衛生）

上の「監視の規律」は『**自前の監視 poll を作らない**』と定めるが、それでも admin が bd の**ラベル/notes を完了 signal として読む**場面は残る（`gate-pending` ラベルの有無・`STATUS:` で始まる定型行の一致）。本作法はその読み取りが **false positive（誤検知）** を起こさないための隙間埋めの追補である。2026-07-06 の sc-7bv/sc-xyw 運用で admin 自作 monitor の誤検知が**同日 2 回実発生**したことを構造原因として規約化する（doobidoo `75e6c821`・信頼度 `verified`）:

- **ラベル判定は labels 配列の完全一致で行う（bead 全文 grep 禁止）**: 完了ラベル（`gate-pending` 等）の有無は `bd show --json` の `labels` 配列に対する**完全一致**（`grep -qx` ／ jq の配列 membership）で判定する。bead 全文を対象にした部分文字列 grep はしない——description/notes 本文に同じ語が現れて誤一致する（記憶 [monitor trigger-string hygiene] と整合）。
- **定型行トリガー語を自分の notes に verbatim で書かない（引用・説明文中でも）**: 完了検知に定型行（`STATUS:` 始まりの行 等）の文字列一致を使うなら、admin は**自分の notes append にそのトリガー文字列を verbatim で書かない**——たとえ引用符で括っても、「この文字列は書かない」と説明する文の中でも書かない（間接参照・言い換えにする）。grep は引用符を区別しないため、引用・注意書きのつもりの一致でも monitor は実 signal と誤認する（2026-07-06 の **2 回目**の誤発火がまさにこの形＝『この文字列は書かない』と説明する文中の引用に一致した）。
- **可能なら独立信号の複合条件（AND）で判定する**: 単一の文字列一致に賭けず、**独立した 2 信号の AND** で複合判定する——marker の厳密形式（`grep -qx` の完全一致 or 行頭アンカー付き厳密 regex）**∧** commit の実在（§5 step1 の Layer2 commit-count 照合）。片方が偽陽性でも他方が抑える（2026-07-06 の **1 回目**の誤発火＝admin 進捗メモ中のトリガー語への一致は、commit 実在との AND を課していれば抑止できた）。

> 自己言及の注意: 上の 2 点目は『admin が bd **notes** にトリガー語を verbatim で書くな』であって、**docs（本 protocol.md 等）に監視語彙・トリガー例を書くことは違反でない**——監視 monitor が読むのは bd の notes/labels であって docs ではないからだ。規約の自己ホスト上、追補文自体に監視語彙が現れるのは不可避（§6 sentinel 節と同じ論点）。

### busy 判定の regex

worker が稼働中（busy = 入力受付不可）かを pane 下部行で判定する regex:

```
… \(|esc to interrupt|agents [0-9/ ]*(done|running)|tokens
```

- `… \(` … スピナー行 / `esc to interrupt` … 実行中 / `agents [0-9/ ]*(done|running)` … Workflow 進捗ボックス / `tokens` … トークン計上行。いずれかにマッチすれば busy。

### Workflow background 中の idle 見え（重要な落とし穴）

- **`session-state.sh` は Workflow tool 実行中の worker に `input-waiting` を返す**: WF はバックグラウンドで走り main loop の入力欄が空くため、**state ベース監視は WF 実行中に false-DONE する**。
- robust な監視は、pane 下部の **WF 進捗ボックス（`N/M agents done`）と spinner 行を併読**して判定する（state だけに頼らない・bd un-jax 引き継ぎ）。

### 停止時の復旧 = session-comm inject（env が健全な idle worker 向け）

- worker が idle に落ちた（prompt で停止した・queue exhausted）場合で **env が健全**なら、cc-session の `session-comm` で操舵注入して復旧する: `wait-ready`（input-waiting を待つ）→ `inject-file`（flock で確実配送）。
- inject は worker の pane で起き、**admin の context には載らない**（PUSH チャネル・scribe-design.md §9）。`-t` 参照は window ID（`@N`）か `session:index` で行う（§1 の dotted id 衝突回避）。
- **env が劣化している worker には inject は効かない**（注入した操舵も非永続環境で消える）→ 下記 salvage へ。

### degraded worker の salvage（env 劣化で self-report が信用できない）

上の session-comm inject は **env が健全な idle worker** を蘇生する手段。**env が劣化した worker**（CC infra の Bash 非永続で commit/bd/dolt が呼出し間で消え、self-verify が嘘になる・folio incident 0264028f）は inject では直らない。env 劣化を検知したら、**worker を蘇生せず admin が引き取る**。劣化には作業の durable 性で 2 系統（扱いが違う）と、検知性で別枠の第 3 変種（zombie）がある:

- **degraded-but-committed**（memory `5ee99c7`・週次 token 上限で window が外因消失した等）: env 自体は健全で、作業は **commit + self-test + bead に durable に残っている**。→ session を蘇生せず admin が **gate を引き取る**: worktree の commit / self-test を確認 → admin が reliable env で **独立に再走** → diff を精読 → PR → squash → close → `bd dolt push` → worktree remove。**作業は捨てない**（durable な成果を破棄して再実装しない）。
- **degraded-uncommitted**（本 incident・Bash 非永続）: Write tool 製 artifact のみ存在し **commit は 0**・self-verify は不可信。→ admin は worker の self-report を**信じず**、残った artifact から作業を再構成するか **独立に再走**する。**commit 0 のまま gate-pending DONE が出ていても完了とみなさない**（§5 step1 Layer2 照合が裏取り＝gate-pending/DONE 単独を信用しない。worker は close しないので CLOSED は出ない・§4）。
- **degraded-zombie（全ツール死・blocked 書込不能）**（folio-nufl incident 2026-07-04・doobidoo `45d7ccb4`）: CC infra のツール実行層が session 途中で**全死**する変種（Bash/Read/ToolSearch 等が空応答・token 消費ゼロで固定・folio 実測では着手直後の Bash 数回と env-probe plant 成功後に全滅）。worker の LLM ループと窓は生存し入力 prompt で idle に見えるが、**Bash ごと死ぬため Layer1 の `STATUS: blocked` を書けず**、窓も消えないため、admin 検知網の 3 信号（gate-pending ラベル / `STATUS:` notes / 窓消失）が**全て沈黙**する——bd 上は健全稼働中と区別不能（0264028f 系〔Bash 非永続〕より深い変種）。durable 性は uncommitted 系（folio 実測は commit 0 / dirty 0）。→ 検知は 2 系統: **(主網) admin 側の zombie signature = pane idle-at-prompt 持続（busy regex 不一致が数分継続）× 0-commit の併読**（folio 実測では thinking 完了表示 + 入力 prompt の持続を admin monitor の IDLE 検知が先行捕捉・verified）。**(補助信号) pane sentinel（sc-c7c）**: worker prompt は「blocked を bdw で書けない時は応答テキスト行頭に `SCRIBE-ENV-DEGRADED: <id> <一行理由>` を出力して停止」する規律を焼いており、**ツール実行層が死んでも LLM ループの turn text 出力は pane に残る**ため（folio-nufl 実測）、admin は `tmux capture-pane -p -t <win> | tail -n N | grep -E '^[[:space:]]*SCRIBE-ENV-DEGRADED:'` で機械的に拾える（CC TUI が assistant text を先頭スペースインデントで描画するため検知側は行頭空白を許容する・厳格 `^` は偽陰性＝sc-c7c dogfood 実測 verified。tail 窓は prompt echo を除外し、relaxed prefix は TUI インデントを許容する）。ただし token が worker の正当な content に出るケース（scribe 自己ホスト＝この protocol.md / scribe-spawn.sh を編集する worker の pane には token が読み込み・diff・引用として現れる）は regex では弁別できない——**sentinel は self-authenticating な trigger ではなく**、admin が 0-commit × 数分の持続 idle × pane 回収を cross-read してから salvage する（下記）。**sentinel は追加信号であって主網の代替ではない**——sentinel 出力前に LLM ループごと死ぬケースはあり得るため、idle-at-prompt × 0-commit 併読が fail-closed の主網のまま。salvage: worker の引き継ぎは pane にのみ残りうる（bd に書けない）ため、**admin が pane（sentinel 行 or 残留サマリ）から回収して bd へ代筆記録**してから `tmux kill-window` → `git worktree remove --force` → **同一契約（bd notes 焼込のまま）で fresh respawn**（folio 実測で回復・verified）。sibling worker が同一 spawn 経路・同一 sandbox 設定で正常稼働していれば、spawn/sandbox 機構でなく CC infra 単発と切り分けてよい（deduced）。

検知の足場（2 層）: **worker 側 = sc-sau env-probe**（cross-call sentinel + `base..HEAD` 0-commit で fail-closed＝env 劣化時に worker 自身が `STATUS: blocked` を書き done を申告しない・Layer1）。**admin 側 = §5 step1 の commit-count 独立照合**（Layer2）+ 本節の窓生死（fleet-monitor `✗`）+ **pane idle-at-prompt 持続の併読（zombie 変種向け）**。**zombie 変種では Layer1 が構造的に沈黙する**（Bash ごと死ぬため blocked を書けない）ため、**fail-closed の主網は Layer2 の idle-at-prompt × 0-commit 併読**であり、pane sentinel（sc-c7c・上記 degraded-zombie 変種の bullet）はそれを補う追加信号にとどまる（sentinel 出力前に LLM ループごと死にうるため主網の代替にはしない）。**§7 の grill-consult 中断リカバリ（3段）は、この一般 salvage の consult 版**（出力がコードでなく決定・session-comm inject → 残 facet 再 spawn → admin 引き取り）。

> 一次出典: doobidoo `6d11f667`(un-8q5 pilot 横断 GOTCHA: session-state が WF 実行中に input-waiting を返す false-DONE／`verified`)・bd un-jax 引き継ぎ / scribe-design.md §9 通信モデル（PUSH=操舵注入）/ ubuntu-note-system `docs/session-orchestration-strategy.md` §3.2（外部・本リポ未同梱・session-comm wait-ready→inject）／ doobidoo `0264028f`（folio incident: 自前 poll silent cap 失効・CLOSED 依存・degraded 検出不能で停止見落とし＝本節監視規律の構造原因・真因は CC infra Bash 非永続〔`44f17714` で訂正〕）・`5ee99c7`（degraded-but-committed salvage = 週次上限 window 消失でも work は durable・admin gate 引取り）／ doobidoo `45d7ccb4`・folio bd `folio-nufl` notes【admin incident 記録 2026-07-04】（zombie 変種: 全ツール死で blocked 書込不能・3 信号全沈黙・idle-at-prompt × 0-commit 検知・pane 引き継ぎの admin 代筆・同一契約 respawn で回復）／ bd sc-ydg（salvage 2 系統 + 監視規律の成文化）・sc-sau（worker env-probe Layer1・§5 step1 が Layer2）・sc-48w（zombie 第 3 変種の成文化・folio admin cross-ledger handoff 起点）／ doobidoo `75e6c821`（sc-7bv/sc-xyw monitoring lesson 2026-07-06: admin 自作 monitor の false positive が同日 2 回実発生・labels 配列完全一致 ∧ トリガー語 verbatim 禁止〔引用/説明文中でも〕∧ 独立信号 AND 複合判定＝監視トリガー衛生・`verified`）・bd sc-7ie（§6「bd ラベル/notes ベース完了検知の作法」小節の成文化）。

---

## 7. needs-user タスクの扱い（WF pre-bake → grill-consult）

> **regime 再編（sc-cuw・2026-06-19）**: 本節は旧 F1=B regime（consult が pre-bake 専任で死に・grill は admin の場＝sc-osn/sc-in9 で codify）を改訂したもの。**pre-bake は consult から撤去し、admin が回す dynamic Workflow（`workflows/needs-user-prebake.workflow.js`）へ移管**した。consult は **grill 専任（原義回帰）** に戻り、admin が集約 brief を `--context` で渡して spawn する **grill-consult** が、**ユーザーと対話 grill する第 2 対話相手**になる（admin は grill から解放される）。旧 regime の経緯・dogfood 一次記録 = doobidoo `9c73606d`（設計合意）/ `b7c99f2f`（sc-in9 dogfood F1-F3）/ `8e98c34a`。
>
> **grill 方法論の実装（sc-swc・2026-06-19）**: grill-consult の grill 挙動は **grill-me スキル本文を SSOT** とし、build_consult_prompt が spawn 時に `$SCRIBE_GRILL_SKILL`（既定 `~/.claude/skills/grill-me/SKILL.md`）を **verbatim 注入**する（不在は fail-loud）。旧 build_consult_prompt は grill-me を自前 paraphrase し load-bearing ルール（AskUserQuestion 禁止・1論点1問）を落としていた（sc-vuu の grill dogfood で露呈）ため撤去。plain consult（`--context` 無し）の base テンプレは grill-me を名乗らないため不変。

- **対象**: needs-user タスク = worker 着手不可の理由が人間判断に依存する状態（概念定義 = `scribe-design.md` §1）。needs-user は駐車ラベル、本節の WF pre-bake + grill-consult が解決機構（別物）。
- **発火条件**: 人間判断を要する **相互独立な決定軸（facet）が複数（≥2）**あるとき、admin が pre-bake WF で各 facet を並列 read-only 分析する。1 facet なら admin インラインで足り、WF fan-out 不要（そのまま grill-consult を立てるか admin が直接 grill するかは admin 判断）。
- **入口（2系統・sc-bs0 2026-07-03 grill 確定）**: 本フローの入口は2つ。**入口A（graph 駆動・従来）** = needs-user ラベルのタスクを admin が graph 処理するとき（上記発火条件で判定）。**入口B（ユーザー駆動）** = ユーザーが consult 起動を依頼したとき（`/scribe:consult`）。入口Bでは AI が spawn **前**に議題を **2段判定**する:
  1. **目的判定**: その相談は「**決定を確定し記録したい**」形か、「**思考の壁打ち・第2視点**」か。壁打ちなら**黙って素 consult の従来フローへ**（毎回選択肢を提示しない＝確認疲れで本当に必要なときの推奨が流し読みされるのを防ぐ）。
  2. **facet 数判定（決定側のみ）**: 上記発火条件と同じ（facet ≥2 → pre-bake WF / 1 facet → WF 不要・admin インライン下ごしらえ or 直接 grill-consult）。
  判定が「決定を確定・記録したい」形のときだけ、AI は「**pre-bake 推奨ですが実行しますか？ それとも plain consult をすぐ起動しますか？**」と**ユーザーに裁定を求める**（推奨提示時は grill-issue が 1 件起票されること・WF のコストを一行で開示する）。**ユーザーが「pre-bake なしで」等を明示済みなら判定・質問を挟まず素 consult を即起動**する。pre-bake 選択時は本フロー（下記 1.〜6.）にそのまま乗せる — grill-issue の起票も本フロー内（step 2＝brief 集約後）でその場で行う（`--context` は grill-issue 必須＝決定 handoff 先の bd notes を定める技術制約であり、この issue は「決定の記録先」そのもの。起票は admin 専有＝§3）。skill 側の手順は `skills/consult/SKILL.md` step 0（本節が規約 SSOT・skill は本文を転記しない）。決定経緯 = bd sc-bs0 notes（旧 regime sc-osn→sc-in9→sc-cuw では入口Bのルーティングが未検討で、pre-bake WF がユーザー駆動経路で構造的にバイパスされていた gap の解消）。
- **facet の単位**: 通常は 1 needs-user issue = 1 grill-issue。1 issue 内に相互独立な複数決定があれば、各決定を 1 facet 扱いして pre-bake WF の `facets[]` に並べる（例: sandbox spike の「bwrap install 是非」と「書込み許可注入の設計」）。**濫用防止**: 相互独立でない・人間判断を要さない些末な選択肢は facet に分割しない。
- **フロー**:
  1. **pre-bake（admin が WF を回す・read-only）**: admin が `Workflow({name:'needs-user-prebake', args:{taskRef, taskTitle, anchor, facets:[{key,question,context}]}})` を起動する。各 facet を **並列 read-only agent** が分析（現状調査〔read-only〕→ 決定木 → 選択肢 + トレードオフ → admin 起票候補）し、opus が **単一の構造化 brief へ統合して WF 返り値（`briefMarkdown`/`facets`/`receivedArgs`）で admin に返す**。WF は **grill しない・graph を触らない・doobidoo 保存もしない**（データを admin に返すだけ）。admin は返り値を一次監査する（薄 gate＝worker 報告と同型）。
  2. **grill-issue 起票（admin）**: admin が brief を集約し、その needs-user 決定群を 1 件の **grill-issue** として起票する（`bd create`・依存 wire は admin）。
  3. **grill-consult spawn（admin）**: admin が brief を file へ書き、`scribe-spawn --consult --context <brief-file> <grill-issue>` で **grill-consult** を起動する（anchor 同居・SCRIBE_ROLE=consult）。brief は grill の **材料（第三者データ）** として焼き込まれる。
  4. **grill（ユーザー × grill-consult）**: **ユーザーが grill-consult と対話 grill** する。grill 方法論は **grill-me スキル本文を SSOT** とし、`scribe-spawn` build_consult_prompt が spawn 時に `$SCRIBE_GRILL_SKILL`（既定 `~/.claude/skills/grill-me/SKILL.md`）を **verbatim 注入**する（自前 paraphrase しない・不在は fail-loud＝sc-swc）。grill-consult はその本文どおり（全体地図→現状/なぜ/選択肢→1論点1問・ポップアップ禁止・理解最優先）に brief を出発点に決定木を一つずつ詰める（**admin は grill から解放される**）。
  5. **決定の handoff（grill-consult → bd notes）**: grill-consult は確定した決定を **own grill-issue の bd notes** に書く（`scripts/bdw update <grill-issue> --claim` / `--append-notes`・**bdw 経由のみ**）。決定は**1論点決まる度に逐次** append し（バッチ厳禁＝中断時の損失を1論点に抑える）、節目で `STATUS:` 行（`grilling (n/N)` / `done — 全 facet 確定` / `blocked — 要admin: …`）を必ず混ぜる。admin はこの notes と STATUS を `bd show <grill-issue>` で **real-time 監視**し、決まった facet から実装 cell を spawn する（**pipelining**＝全 facet の確定を待たない）。同一マシン anchor 同居ゆえ `bd dolt push` 無しで admin が即視認できる。
  6. **完了確認 gate → 反映・cleanup（admin）**: admin は **close 前に人間 gate を踏む**——grill-consult window の静止 / `STATUS: done` / ユーザー完了告知を契機に `bd show <grill-issue>` を開き、**全 facet が決定として記録されていることを目視確認**してから（STATUS は「見にくる」合図であって機械的 close トリガーではない＝grill-consult が STATUS を書き忘れても admin の目視で取りこぼさない fail-closed）、決定を graph へ反映（実装 cell 起票・dep wire）し、grill-issue を `bd close`、grill-consult window を cleanup（`kill-window`）する。downstream 実装 cell は grill-issue への `blocks` 依存＋`bd close` で ready 化する（既存 dep+close で足り、bd gate は使わない）。
- **admin 責務（明文化）**: ① pre-bake WF 起動 → ② brief 集約 → ③ grill-issue 起票 → ④ grill-consult spawn（context=brief）→ ⑤ bd notes / STATUS 監視・決定反映 → ⑥ **完了確認 gate（全 facet 目視）→ grill-issue close** → ⑦ consult window cleanup（kill-window）。途中で grill-consult が静止・中断したら ⑤' **中断リカバリ**（下記）を踏む。graph 変更・起票・`bd dolt push` は **すべて admin**（grill-consult は不可）。
- **中断リカバリ（grill-consult が静止・idle 落ち・中断したとき）**: これは **§6 degraded worker salvage の consult 版**（worker-cell death の一般 recovery の特殊形＝出力がコードでなく決定）。admin は bd notes の**部分決定（書かれた facet）と最後の STATUS** を `bd show <grill-issue>` で読み、**3段で復旧**する——① **§6 の session-comm inject** で grill-consult を蘇生（`wait-ready` → `inject-file`・worker idle 復旧と同型・env 健全時のみ有効）、蘇生不能なら ② **残 facet だけの brief** で grill-consult を再 spawn（決定済み facet は捨てない＝§6 の「durable な部分成果を捨てない」と同型）、それでも無理なら ③ admin が grill を引き取る。v0 の中断検知は**受動**（admin が window 静止を見て気づく）。STATUS の半自動 poll 通知は `scripts/grill-status-watch.sh`（下記 §7.1）で利用でき、`consult-` window の自動検知（fleet-monitor 拡張）は v1（背景 supervisor・`scribe-design.md` §14）。
- **grill-consult の read-only 限定緩和（§3 worker B/hybrid の subset）**: grill-consult は **自分の grill-issue の `bd update --claim` と `--append-notes` だけ** を **bdw 経由**で書ける。`bd create` / `bd dep` / `bd dolt push` / `bd close` と tracked コード/ファイルの編集は **read-only 維持**（不可）。grill-consult = worker の変種（出力がコードでなく決定）で worker 境界に倣う。**§4 反転（worker も自己 close せず admin が merge 後 close）後は worker と grill-consult はいずれも close を admin 専有とする点で対称**で、両者の差は完了 handoff の形式のみ（worker = `gate-pending` ラベル / grill-consult = `STATUS:` notes で admin に合図）。義務詳細 = `role-context-spec.md` §2.3。
- **F2 の構造解消**: 旧 regime の F2（consult が自分の pre-bake 出力をユーザー入力と誤認する事故）は、新設計で **pre-bake〔生成〕= WF agent / grill〔対話〕= grill-consult** と別主体に分かれ、**自己 pre-bake を誤帰属する主体が消える**ため構造的に解消する。grill-consult は brief を **外部 context（第三者データ）** として受け取るだけで自分では pre-bake しない。出典ヘッダ（「brief は WF の提案であって決定でない」）は **保険として** consult prompt に残す（`scribe-spawn` build_consult_prompt）。
- **旧 doobidoo handoff regime の撤去**: brief は **WF 返り値**（in-memory で admin に返る）であり、決定 handoff は **bd notes**（ローカル・flock 直列化）ゆえ、旧 regime の doobidoo 集約機構（共有 tag `scribe-brief-{id}` / `conversation_id` / un-sl9 の MEMORY.md 衝突回避 / F3 の doobidoo リトライ規律）は **本フローでは不要になり撤去**した（pre-bake が doobidoo を経由しないため）。grill-consult が任意で議論メモを doobidoo へ残すのは妨げないが、決定の SSOT は grill-issue の bd notes。
- パターン選択（いつ WF fan-out するか）= `methodology.md` §2。

### 7.1 grill-consult STATUS 監視（sc-bka・任意の即時感知）

admin の受動監視（§7 ⑤）を即時化する read-only watcher。`scripts/grill-status-watch.sh` が grill-issue の bd notes の最後の `STATUS:` 行を poll し、**変化したときだけ** `[<id>] STATUS changed: <new>` を stdout に出す。`STATUS: done` / `blocked` を観測したら exit 0 で自己終了する。

- **使い方**: 自己ループ版 `scripts/grill-status-watch.sh <grill-issue> [interval秒=15]` を **Monitor の command** に渡す（スクリプト自身が poll し続け、done/blocked で exit 0 する）。`/loop` で回すなら**単発の** `--fetch <grill-issue>`（自己ループせず現在 STATUS を 1 回返す）を使う——自己ループ版を `/loop` に渡すと二重ループになる。
- **READ-only**: `bd show --long --json` だけを叩く（bdw lock 不要）。**close も bd write もしない**——STATUS は「見にくる合図」であって機械的 close トリガーではなく、最終 close は admin の全 facet 目視 gate（§7 ⑥・sc-qos D3 の fail-closed）。watcher は admin を「見にこさせる」だけで gate を迂回しない。
- **位置づけ**: 背景 supervisor（v1・`scribe-design.md` §14）の軽量 poll だが、LLM 不使用ゆえ admin が任意で使える v0 手動監視の補助としても成立する。`consult-` window の自動検知（grill-consult の沈黙検出）は別軸で v1（fleet-monitor 拡張・sc-3pq）。
- STATUS の canonical 形式（`grilling (n/N)` / `done — …` / `blocked — 要admin: …`）の SSOT は grill-consult prompt（`scripts/scribe-spawn.sh`）と本 §7。

---

## 8. cross-ledger 境界（自 `sc-` 台帳 ↔ 他 project 台帳・federated）

scribe admin が複数 project の台帳が併存する環境（orchestrator 配下・cross-rig handoff）で動くときの境界。**admin が write・所有するのは自 project の台帳（`sc-`）だけ**で、他 project の台帳（`un-` / `cc-` 等）は read に留める。worker/consult はそもそも foreign 台帳に触れないため、**本節は admin 専用**（worker 注入 §2/§3/§4 には含めない＝admin は全文 cat で受領）。

- **writer 規律（自台帳のみ write）**: 他 project の台帳を `bd -C <other>/.beads` / `--db` で **write しない**（create/update/close/dep/dolt push のいずれも）。foreign issue への依存が要るときは自台帳側に `bd dep add <自 issue> <foreign-id>` で **foreign bead を depends-on に置く形のみ**可（foreign 台帳は書き換えない）。cross-project の起票・修正依頼は handoff（doobidoo / 相手 admin への連絡）で渡し、相手 project の admin が自台帳へ起票する。
- **read 方向の情報分離**: foreign 台帳を read して自 `sc-` bead / worker prompt / doobidoo へ**転記する際は、出所・audience・確度・要確認フラグを保持する**（どの project の誰の主張かを落とさない＝混線・誤帰属の防止）。**他 project の機密本文（運営数値・資金・特許・COI 等）は `-C` 直読みに留め durable copy を作らない**（自台帳 notes・doobidoo へ機密本文を保存しない＝漏洩面を増やさない）。
- **origin verify は §5 が SSOT**: cross-repo の worker が push する経路の origin URL 健全性 verify/restore（`scribe-origin-guard.sh {capture,verify,restore}`）は **§5（push 前 verify）** に既出。cross-ledger でも同じ gate chain を push 前に必ず通す（本節は再掲せずポインタに留める）。
- **doobidoo（知識系）を SPOF にしない**: cross-ledger handoff の durable leg は **doobidoo より per-project bead（自台帳 notes）を一次**にする。`memory_search` 失敗で着手を止めない・`memory_quality` 評価は skip 可（best-effort）。doobidoo は知識の二次 carrier であって、タスクの真実源（= bd）ではない。
- **公開面ラベル規約（federation・orchestrator SSOT を受容・`orch-7my`(b) courier）**: federation 公開面の候補検知は notes の ad-hoc 正規表現走査でなく**ラベルの完全一致**で行う（規約 SSOT は orchestrator = top-spec §5.1・`orch-b4b`。scribe は本規約を**受容・周知するだけで enforce しない**＝機械強制は持たない）。scribe が federation へ公開候補として出す `sc-` bead には平ラベル **`federate-publish`** を付ける（orchestrator が `bd list --label federate-publish` の exact-match で拾う）。**`reconcile-published`** は orchestrator が `orch-` 側に付ける逆 leg ラベル（foreign 公開候補を ingest し公開面へ出し戻し cross-rig dep を張った印）ゆえ **scribe は付けない**。両ラベルは orchestrator の `orch-reconciliation-parity.sh`（read-only・detect のみ）が exact-match で照合する published surface の最小定義で、env `ORCH_RECON_PUBLISH_LABEL` / `ORCH_RECON_FOREIGN_LABEL` で orchestrator 側が上書き可。**cross-project 合意前提ゆえ本受容の確定は orchestrator gate を経る**（scribe 単独確定はしない）。公開後の内容 drift（`federate-publish` bead の updated_at が最終 publish より新しい＝再 publish 漏れ）の scribe 側 **early self-check** は §5 step8 の `scribe-publish-freshness.sh`（**warn・非block**・sc-e93 / orch-tya 合意）＝これは enforce（block）でなく advisory ゆえ本節の「scribe は enforce しない」と両立する（信号=updated_at で orch parity と同一・orch の `orch-reconciliation-parity.sh` human notice の補完で並走）。
- **bead-append 規律（上位への報告は notes-append で `updated_at` を動かす・pane-only 禁止・orch-edv T1(b)）**: admin が orchestrator の **bead 直読 poll** 下で動くとき（**ORCH-WATCH-CONTRACT** = orchestrator が spawn した actor の bead を直読 poll して DONE/BLOCKED/NEEDS-USER を判定する監視契約。出所は orchestrator 側の spawn 契約＝scribe 外部で、本節はその admin 側の従い方を規約化する）、**上位（orchestrator）への新質問・報告・再 pause は、該当 bead の notes へ `bd update --append-notes`（自台帳ゆえ bdw 経由・§3）で追記して `updated_at` を必ず前進させる**（**pane＝turn 出力だけに書くのは禁止**）。理由（load-bearing）= orchestrator は bead を直読 poll するため、pane-only の新質問／再 pause は poll から不可視で、status/label が動かなければ『無変化 transition』となり相互デッドロックに陥る（orch-edv 実証）。**既に needs-user / blocked の bead へ再 pause する場合も同様**に notes へ append する（status/label が不変でも append すれば `updated_at` が前進し、poll 側が変化を検知して再開指示を出せる）。worker→admin の対称形（admin が worker / grill-consult の進捗を bead で監視する側）は **§7（`STATUS:` notes への逐次 append ＝ lower→upper の poll signal）** が最も近く、§4 も『**durable な notes-append で永続化する**（gate findings は append 必須・`bd update --notes` の上書きで消さない）』原則を体現する。本規律はこの durable-notes-append（ephemeral な pane に頼らず updated_at を動かす）原則を、**admin→orchestrator の watch 経路へ一般化**したもの。

> 一次出典: doobidoo `9be93364`（uns admin → scribe cross-ledger handoff: un-ao2 split・un-jcn A/B）・`cfd599dc`（federated 設計）・`115521de`（実隔離＝各層自身の bd-write-guard が機械強制し、scribe role 注入は cosmetic/advisory。本 §8 の writer 規律は admin が従う protocol 規約であって機械強制ではない）/ **orchestrator `orch-edv` T1(b)（bead-append 規律 = 上位への新質問・報告・再 pause は notes-append で `updated_at` を動かす・pane-only 禁止・needs-user/blocked への再 pause も同様。pane-only re-pause が bead-truth poll から不可視で相互デッドロックに陥る事故の構造予防）**。

---

## 一次出典（まとめ）

| 出典 | 内容 |
|---|---|
| doobidoo `13447a54` | scribe v0 grill 確定（段階着手・v0 スコープ・role 別 PRIME 分割 = worker bd create 逸脱の構造原因） |
| doobidoo `e2addec8` | ミニ grill 2 点確定（PRIME 重複 = 案 A 責務分割 / consult 識別 = `SCRIBE_ROLE` env 一次・anchor 無印 = admin 既定） |
| doobidoo `ac9022d8` | Wave1 手動プロトコル実測 |
| doobidoo `3b838167` | Wave2 完了（gate funnel 実証値・errata 規約初運用・consult 規約・snapshot 合成で diff 供給不要・argshim 退役） |
| doobidoo `6d11f667`（un-8q5 pilot N=3） | spawn-latency 2-3s・bdw lost-update ゼロ・errata 規約・WF args false-clean・session-state false-DONE・N=funnel 律速 |
| bd un-3v9 notes | grill 議事（7 論点全確定） |
| bd un-it7 notes | v0 実装 epic（5 cell 分解・spawn ヘルパー設計引き継ぎ） |
| bd un-cbi notes | spawn 命名規約 producer 追従・dotted id の tmux -t 衝突 live finding・worker receivedArgs 報告実例 |
| doobidoo `9be93364` / `cfd599dc` | cross-ledger handoff（uns admin → scribe）: federated 規律（§8）= 自台帳のみ write・read 方向の provenance/機密分離・doobidoo SPOF 回避 |
| orchestrator `orch-edv` T1(b) | bead-append 規律（§8）: 上位（orchestrator/admin）への新質問・報告・再 pause は該当 bead notes へ append し `updated_at` を動かす（pane-only 禁止）。needs-user/blocked への再 pause も同様＝pane-only re-pause の bead-truth poll 不可視デッドロックの構造予防 |
| orch top-spec §5.1 / `orch-b4b` / courier `orch-7my`(b) | 公開面ラベル規約（federation・§8）: `federate-publish`（scribe 公開候補）/ `reconcile-published`（orchestrator 逆 leg）・exact-match・scribe は受容周知のみで enforce せず・確定は orchestrator gate |
| bd sc-e93 / orch-tya（courier 第3便・orchestrator Q1-Q4 合意） | publish 鮮度 advisory lint（§5 step8・案A）: `federate-publish` bead の公開後 drift（updated_at vs `federate-published-at:` marker）を warn・非block で self-check。信号=updated_at / provenance=bead notes / §8「enforce しない」と両立する advisory 上限線 / orch parity notice の補完で並走。実装 `scripts/scribe-publish-freshness.sh`・`tests/publish-freshness.bats` |
| scribe-design.md | 設計の why（§8 B/hybrid・§9 通信・§10 監視・§14 v0 スコープ） |

> 設計の細部に疑義が出たら、本書ではなく上記 doobidoo の原典を recall して確認すること（本書は実証ログ・notes を成文化した how 文書）。

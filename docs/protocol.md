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
   → worker self-report + close(§4) → gate funnel(§5: 報告監査 → cell-quality gate review
   → findings 直読 → merge 前ユーザー確認 → squash merge → go-live → cleanup) → dolt push 同期点(§3)
監視(§6) は spawn 〜 close まで全域で走る。
```

- **admin = anchor（orchestrator セッション）**。graph の所有者であり、唯一の `bd dolt push` 同期点。
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

### sandbox opt-in（`SCRIBE_SANDBOX=1`・worker を OS レベル隔離）

worker を Claude Code 組込み bwrap sandbox に封じたいときは `SCRIBE_SANDBOX=1` を付けて spawn する（既定 off・**opt-in 未指定時は本番 spawn 経路 byte 不変**）。`scribe-spawn.sh` が `git worktree add` 後に worktree の `.claude/settings.local.json` を生成し、worker の Bash subprocess を「自 worktree + 共有 `.git` + anchor の `.beads` + bdw 鍵の置き場（`scribe-lib.sh` の `scribe_bdw_lock_dir()` ＝ `scripts/bdw` と `gen-sandbox-settings.sh` が共有する SSOT。既定 `$HOME/.cache/bdw-locks` ＝ scribe 以外の bd writer（orch/uns bdw）と byte 一致する収束点・sc-xs2。parent を丸ごとでなく専用 lock dir のみ grant＝最小化・sc-imu で関数集約）」へ限定する。それ以外への書込みは OS 外壁が拒否する（`bypassPermissions` と直交）。生成 settings は worktree の `info/exclude` で ephemeral 化され worker の `git add` から保護される。

- **ホスト前提**（欠けると `failIfUnavailable` で worker が起動拒否）: `bubblewrap` + **`socat`**（両方必須）+ `kernel.apparmor_restrict_unprivileged_userns=0`（Ubuntu 24.04。ホスト全体の userns ハードニング緩和ゆえ**マルチユーザーホストでは security トレードオフを承知で**）。
- 設計・検証・rollback の詳細 SSOT = `scripts/sandbox-spike/README.md`（dogfood = bd `sc-1gu`）。

> 一次出典: bd `sc-1gu`（spike a/b 5/5 実証 + 本番 direct-gen 実装 + live e2e 起動実証）/ CC docs `code.claude.com/docs/en/sandboxing.md`（`verified`）。

---

## 2. worker prompt 規約

admin が worker に渡す起動 prompt（spawn の最初の inject）が満たすべき規約。

- **編集可スコープの明示**: worker が触ってよいパス境界を prompt で明示する（例: 「編集可は新規リポ配下のみ・コピー元は読むだけ」）。スコープ外の編集を求める後続要求は worker が自分で拒否できるようにする。
- **anchor 絶対パスを焼き込む**: worker の cwd は **worktree** であり、そこからは anchor の bd graph（`.beads`）が解決しない。よって契約参照（`bd show`）と bdw 規律行（§3）に **anchor（bd graph 所在）の絶対パスを埋め**、worker が `cd` 先を自力発見せずに済むようにする。spawn ヘルパー（`scripts/scribe-spawn.sh`）は `--anchor`（既定 cwd）を絶対パスへ正規化して保持済みの `$ANCHOR` を `build_prompt` に焼き込む。
- **tests 同梱（test-first）**: worker は実装に対する self-test を**自分で用意**し、リポ直下に置く。pilot では `selftest-<id>.local.sh`（untracked・コミットしない・fail-closed）の形で運用した。
- **selfTest は fail-closed**: assert が 1 つでも落ちたら非 0 で終了し、「未検証なのに DONE」を構造的に防ぐ。cell-quality WF の `selfTestCmd` に渡し、gated autoFix の self-test 段に fail-closed で効かせる。
- **cell-quality WF を worker が直接呼び出す**: gate review/verify を worker タスク内で 1 回回す（直接呼出・named-WF 明示・`scriptPath` 直指定）。これは admin の gate funnel（§5）とは別物で、worker 自身の自己点検。WF の強度（fan-out 本数・verify 票数）と dimensions の組み方は `docs/methodology.md`（§1 強度キャリブレーション・§3 D1-D7 運用）に従う。
  - **道具ポインタ（bd un-3yc）**: この自己点検用 cell-quality args(JSON) の組み立ては **`scripts/scribe-selftest-args.sh --worktree <path> --self-test <cmd> <bd-id>` で 1 コマンド化済み**（`doImplement`/`doPlan` を `false`・`autoFix` を `true` にハードコード固定 + `selfTestCmd` を必須化＝必須観点の欠落・autoFix の fail-closed ゲート抜けを上流で塞ぐ）。§5 の admin gate（`scribe-gate-args.sh`）と対称の道具で、**責務だけ非対称**（gate=read-only / 自己点検=worker 実装済み前提の gated autoFix）。手作業で args を組まず道具を使うこと。
- **報告に WF 返り値 JSON + `receivedArgs` を必須**で含める: Workflow tool の args は呼び出し側 serialization 依存で **script に JSON 文字列のまま届くことがある**（非決定的）。args 前提の WF が全デフォルト実行に落ちると single モードで空 diff を 0 findings で false-clean に返す経路がある（bd un-2yy）。よって worker は「WF が実際に受け取った args（`receivedArgs` / `parseFailed`）」を報告に含め、admin が args 解決の成否を一次監査できるようにする。
- **新規リポ / main 直 work cell では `baseRef` を prompt 段階で明示供給する**（bd un-k02）: 自己点検 WF の diff は `baseRef...HEAD`（既定 `origin/main`）で取る。新規リポや main へ直 commit する cell では `origin/main` が無い／HEAD と同一で diff が空になり、WF が「空 diff」を escalate する。これを避けるため、そうした cell では worker prompt に `baseRef`（自己点検 args の `--base`）を明示供給する。
- **共有 `.git/config`（remotes / hooks / config 等）を mutate しない**（bd un-1n1）: worktree は anchor と `.git/config` を **共有**するため、worker が origin/remote を書き換えると anchor+全 worktree の origin が壊れ、admin の push が破綻する（2026-06-16 un-v5x funnel 実害＝worker が push-gate 試験で dummy origin を設定し anchor push が 134s タイムアウト）。remote 検証が要るなら **throwaway bare repo / 別 clone** を使う（`remote.*` は git が共有 config からのみ読むため `git config --worktree` でも隔離できない＝git 2.43 で検証済み・物理隔離は →un-6nf）。これを prompt の「禁止」節に列挙する。
- **禁止事項を定型で明示**: `bd create` / `bd dep` / `bd dolt push` / GitHub への push / admin window への tmux inject / スコープ外編集 / follow-up の bd create / **共有 `.git/config`（remotes/hooks/config）の mutate**（§3 B/hybrid 境界・un-1n1）を prompt の「禁止」節に列挙する。

> 一次出典: doobidoo `3b838167`(Wave2)・un-8q5 pilot 横断 GOTCHA（WF args の JSON 文字列化・false-clean／`verified`）/ bd un-2yy（args defensive parse）/ bd un-cbi notes（worker の receivedArgs 報告実例・全 12 キー受領／`verified`）/ bd un-1n1（共有 .git/config mutate 禁止 = un-v5x funnel 実害の対策①）/ bd un-k02（新規リポ/main 直 cell の baseRef 明示供給）。

---

## 3. B/hybrid 役割境界（worker↔beads）

worker↔beads = **B/hybrid で確定**（scribe-design.md §8）。台帳は anchor の単一 embeddeddolt を全 worktree が redirect 共有する（siloed ではない）。

### worker の権限（自 issue の進捗のみ・bdw 経由）

- 自分が claim した issue の status/進捗を **auto-share DB に直接書く**: `bd update --claim` / `--append-notes` / `bd close`。
- **write は必ず `bdw` 経由で直列化する**: `cd <anchor リポ> && scripts/bdw <subcmd>`。`.beads/embeddeddolt` は embedded Dolt = single-writer で、N 並列 worker が同一 issue へ read-modify-write 系 write を並行すると last-writer-wins で lost-update が起きる（実測 un-gmq: 15 並列 append-notes → 10 しか残らず 5 件消失。bdw 直列化で 15/15）。pilot N=3 では bdw により bd write 事故ゼロを実証。
  - bdw は fail-closed: READ と確証できるサブコマンドだけ lock なしで素通しし、未知/全 write は flock 取得後に実行する。

### worker が**してはいけない**こと（graph は admin の所有物）

- `bd create` / `bd dep`（依存 wire）/ assignment / `bd dolt push` は**明示禁止**。worker は graph を操作しない。
  - **構造的背景**: `bd prime` の SessionStart 注入が全セッション（worker 含む）へ無条件に「非自明な作業は着手前に `bd create`」を入れており、これが worker の `bd create` 逸脱の**構造原因**（2026-06-10 に 1 件の逸脱を prompt 明記で解消した実績＝注入の問題と確認・`verified`）。対処は role 別注入（`docs/role-context-spec.md`）で worker への一律 `bd create` 注入を止めること。
- **follow-up は notes で提案する**: タスク化が必要になっても worker は自分で起票せず、自 issue の `--append-notes` に「admin への起票候補」として書き出すに留める。**起票は admin が行う**。

### admin の所有

- issue 作成・依存グラフ・assignment・最終判断・**`bd dolt push` / remote 同期点**を所有する（§5 末で push）。

> 一次出典: scribe-design.md §8（B/hybrid 確定）/ anchor リポの `scripts/bdw`（scribe 出荷物ではない substrate・flock 直列化の WHY・un-gmq 実測）/ doobidoo `13447a54`（role 別 PRIME 分割 = worker bd create 逸脱の構造原因の発見／`verified`）/ bd un-cbi notes（worker が follow-up を bd create せず notes 提案した実例）。

---

## 4. close → gate → errata 規約

worker の完了申告から gate、その後の追補までの規約。**順序が肝**（close が先・gate が後）。

- **close = PR-up 時の自己申告**: worker は実装 + self-test pass + PR/ローカル commit が揃った時点で自分の issue を `bd close`（理由に PR 番号 / commit / gate 待ちである旨を書く）。close は「作業を出した」の宣言であって「merge 済み」ではない。
- **gate は close の後**: admin の gate funnel（§5）は worker が close した**後**に走る。close → gate の順序を保つ（gate を待ってから close、ではない）。
- **errata = closed のまま同一 branch へ追補**: gate で見つかった findings の修正は、issue を**閉じたまま**同一 branch に追補コミットして対応する（PR を新規に開き直さない）。
- **gate findings は notes-append 必須**: gate で出た findings は当該 issue の `--append-notes` に追記して永続化する（review trail を残す。`bd update --notes` の上書きで消さない）。
- **reopen は substantive 再実装のみ**: 軽微な errata では reopen しない。設計レベルの作り直しが要るときだけ reopen する。

> 一次出典: doobidoo `3b838167`(Wave2)・un-8q5 pilot（errata 規約 = close 後 findings は notes-append・closed のまま追補コミット・substantive のみ reopen を gate 2 件で初運用し機能／`verified`）/ doobidoo `ac9022d8`(Wave1)。

---

## 5. gate funnel 手順

worker の close 後に admin が踏む funnel。**判断は admin の手動**（v0 では自動化しない・scribe-design.md §14「v0 で作らないもの」）。

1. **worker 報告の監査**: worker の self-report（commit hash / WF 返り値 JSON / `receivedArgs` / self-test 結果 / 成文化・実装した内容）を読み、args 解決の成否（`parseFailed`/`receivedArgs`）と self-test の pass を一次確認する。
   - **commit-count 独立照合（sc-sau Layer2・bd sc-ydg）**: worker の self-report を額面で信じず、admin が **reliable env**（自分の anchor）で `git -C <worktree> rev-list --count <base>..HEAD` を独立に叩き、**0 commit でないこと**を裏取りする。base は spawn 時に `scribe-spawn.sh` が SHA へ凍結し、worker の env-probe（Layer1）の `verify --base` に焼いたのと**同一 SHA**（admin Layer2 と worker Layer1 が同じ base を見る）。既定 `HEAD` をリテラルで焼くと `HEAD..HEAD`＝常に 0-commit となり健全 worker を誤 blocked にする回帰（un-k02 同型）を避けるため、spawn 時点の commit を凍結する。worker 側 env-probe（sc-sau **Layer1**・§6 salvage）は env 劣化時に worker 自身を `STATUS: blocked` で止めるが、劣化が probe をすり抜ける／worker が誤って done を申告する残余に備え、admin gate でも commit 実在を確認する（degraded-uncommitted worker は **commit 0 のまま `bd close` を出しうる**＝**CLOSED 単独を信用しない**・§6）。0 commit を検知したら merge せず §6 salvage へ回す。
2. **cell-quality gate review（read-only・worktree 指定）**: admin が cell-quality WF を **read-only** で起動し、worktree を指定して gate review をかける（admin gate は dimensions 必須 4 観点固定＝`docs/methodology.md` §3 D3・強度の選び方は同 §1）。**snapshot 合成（PR#346）により worktree 指定で WF が `base...HEAD` diff を自動取得する**ため、diff の静的供給は不要（argshim も退役・defensive parse が tool レベルの string 化を吸収）。← だからこそ本リポは先頭に空の initial commit を置き、`base...HEAD` の合成が機能するようにしてある。
   - **道具ポインタ（bd un-7hx）**: この gate review 用 cell-quality args(JSON) の組み立ては **`scripts/scribe-gate-args.sh --worktree <path> <bd-id>` で 1 コマンド化済み**（`doPlan`/`doImplement`/`autoFix` を read-only にハードコード固定＝一次監査が実装/autoFix に化けない）。手作業で args を組まず道具を使うこと。
3. **findings 直読（refuted も鵜呑みにしない）**: WF の返り値 findings を admin が直読検証する。WF 内の adversarial verify が `refuted` と判定した finding も鵜呑みにせず、admin が一次監査する（gate は薄い一次監査・WF 返り値の机上承認ではない）。スコープ外（他リポ・他 cell の領分）を求める finding は却下し、却下理由を記録する。
4. **merge 前ユーザー確認**: 以下に該当する変更は merge 前に**ユーザー確認を取る**:
   - 規約・運用方針に関わる変更
   - 全ホストに影響する変更（配布物・グローバル hook・命名規約など）
   - outward（外部公開・不可逆）な操作
5. **push 前に origin URL 健全性を verify（汚染なら fail-loud + 復元）**（bd un-1n1）: squash merge / GitHub push の **前に** リポの `origin` URL が spawn 時 canonical のままかを照合する。worktree は anchor と `.git/config`（remotes）を共有するため、worker が origin を mutate すると anchor+全 worktree の origin が壊れ push が破綻する（2026-06-16 un-v5x 実害＝134s タイムアウト+gh が known host 無しと誤認）。汚染を検知したら **fail-loud し、canonical へ復元してから** push する（汚染したまま push しない）。
   - **道具ポインタ（bd un-1n1）**: spawn 時の canonical origin 捕捉と gate 時の照合・復元は **`scripts/scribe-origin-guard.sh {capture,verify,restore} --worktree <path>` で 1 コマンド化済み**。spawn は `scribe-spawn.sh` が `git worktree add` 直後に `capture`（canonical origin を per-worktree marker `.git/worktrees/<name>/scribe-origin.marker` へ捕捉）を自動実行する。gate では `scribe-origin-guard.sh verify --worktree <path>`（健全=exit 0 / 汚染=exit 非0・canonical URL を stdout）を push 前に走らせ、汚染時は `--restore` 併用 or `restore` サブコマンドで復元する。marker は per-worktree の private git dir に置く＝共有 config と別物ゆえ worker の config 汚染を生き延び、working tree 外ゆえ worker の編集スコープ外。
   - **marker 不在 verify が「意図的 fail-open（skip=exit 0）」である理由と将来の反転条件**（bd sc-vuu facet2）: `verify` は spawn 時 marker が無いと「照合不能」として **skip=exit 0**（warn のみ）に倒す。これは意図的な fail-open であり、(a) origin 無しのリポ（dogfood・新規リポ）は保護対象が無く `capture` も no-op で marker を作らないため、その verify が gate を素通りすべき、(b) marker 捕捉導入前に作られた既存 worktree との後方互換、の二点で正当化される（＝「未検証だから止める」ではなく「保護対象が無いから素通す」）。この default を **fail-loud（marker 不在=非0）へ反転**してよいのは、次の移行条件が**両方**揃ったとき: ① 全 spawn 経路が marker 捕捉を保証する（origin 付きリポで marker 不在＝「捕捉漏れ」と確実に言える状態）、かつ ② gate funnel が `verify` を自動配線で必ず通す（手動 skip の温存が不要になる）。それまでの間、marker 不在を厳格化したい個別 gate は additive opt-in の **`scribe-origin-guard.sh verify --require-marker`**（marker 不在は origin 現存なら fail-loud・origin 無しなら exit0・既定挙動は不変）を使う。「`capture` 失敗で marker が無い（=origin 現存・真の漏れ）」と「origin 無しで marker が無い（=正当 no-op）」を verify が区別する強化は `--require-marker` 下で実装済み（origin 現存=fail-loud / origin 無し=exit0 / origin 現存 probe 失敗=fail-closed＝sc-cw6）。
6. **squash merge → go-live**: 確認が取れたら squash merge し、go-live（配布・反映）する。
7. **cleanup**: worktree / branch / window を掃除する（`@N` 参照で window を kill・§1）。
   - **道具ポインタ（bd un-7hx）**: この cleanup（worktree remove / branch 安全削除 / window kill / `bd dolt push` リマインド）は **`scripts/scribe-cleanup.sh <bd-id>` で 1 コマンド化済み**（破壊操作は確認プロンプト付き・`--yes` で一括承認・**force 系は使わない**・`bd dolt push` は admin 専用ゆえ自動実行せずリマインドのみ）。手作業で掃除を再現せず道具を使うこと。
8. **dolt push 同期点**: 一連の funnel が片付いた区切りで admin が `bd dolt push` して台帳をマシン間同期する（§3・worker は push しない）。

- **N（並列 worker 数）の上限 = admin funnel 律速**: gate 逐次 + errata 往復 + ユーザー確認が直列なので、funnel がボトルネック。pilot 実測で **N=3 が快適**、N=4-5 はタスク所要が異質な編成なら成立。
- adversarial gate の検出力（実証）: dead import の fail-open 結合 / env 検証の octal fail-open（`SESSION_COMM_SUBMIT_ENTER_MAX=008` が bash 算術で不正 octal → 修正自体が無音失効）/ base-staleness アーティファクトの正確な診断などを、いずれも merge 前に捕捉した。

> 一次出典: doobidoo `3b838167`(Wave2)・`ac9022d8`(Wave1)・un-8q5 pilot（funnel 純 review 10-13min/PR・N 上限 = funnel 律速・snapshot 合成で diff 静的供給不要・adversarial gate 検出力／`verified`）/ bd un-1n1（origin URL 健全性 verify = un-v5x funnel 実害の対策③・push 前 verify+復元を規約化）。

---

## 6. 監視

spawn 〜 close まで worker pane を観測する。**v0 は (a) 最小 = admin が手動監視**（背景 supervisor は v1+・scribe-design.md §10/§14）。

### 監視の規律（folio incident 0264028f の教訓）

admin が worker 群の稼働を見るときの 3 規律。folio admin の停止見落とし（**自前の bash poll** が 160 分 silent cap で失効・完了判定を **bd CLOSED 依存**にし・degraded worker を構造的に検出不能で、停止をユーザー指摘まで気づけなかった）を構造原因として規約化したもの:

- **自前の監視 poll を作らない**: 監視は本節の primitives（busy 判定 regex・worker↔window 照合）で行う。fleet 全体のボードが要るなら scriptorium の `fleet-monitor.sh`（**人間向け** read-only タスクボード・所有は scriptorium〔orch-7hc で uns→scriptorium 移管〕）を**人間が**ちらっと見る——`◆`=worker 窓検出 / `✗`=**stall**（窓消失だが直近 active＝生きていた cell が窓を失った）/ `◇`=窓不在かつ古い（admin epic とみなし非警報）。AI admin が独自に時間 cap 付き poll を書くと、cap の silent 失効・誤った healthy 判定で停止を見逃す（folio 実害）。
- **完了 signal を bd CLOSED 単独に依存しない**: degraded worker（env 劣化で self-verify が嘘になる cell）は **CLOSED を出さない**。「まだ CLOSED が無い＝まだ健全に稼働中」と読んではならない。窓の生死（fleet-monitor の `✗` stall）と commit 実在（§5 step1 の Layer2 照合）を併せて見て、**CLOSED 不在 × 窓消失**を salvage トリガとして扱う。
- **長時間 worker は proactive に確認する（admin 自省）**: 想定所要を大きく超えた worker は monitor 任せにせず、admin が能動的に pane / commit を覗いて生死を確かめる。v0 の検知は受動（admin が気づく）ゆえ、自省が最後の砦。

> `consult-`（grill-consult）window の沈黙を fleet-monitor が**自動検知**する拡張は **v1・sc-3pq**（fleet-monitor の degraded 検出拡張・所有は scriptorium）。本節の規律はその自動検知に依存せず v0 手動監視で成立する。fleet-monitor の「使用義務」を厳密文言化するのは sc-3pq の確定 contract と整合させてから（salvage 手順〔下記〕は incident+memory で実体確定済ゆえ先行・bd sc-ydg 注）。

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

上の session-comm inject は **env が健全な idle worker** を蘇生する手段。**env が劣化した worker**（CC infra の Bash 非永続で commit/bd/dolt が呼出し間で消え、self-verify が嘘になる・folio incident 0264028f）は inject では直らない。env 劣化を検知したら、**worker を蘇生せず admin が引き取る**。劣化には作業の durable 性で 2 系統あり扱いが違う:

- **degraded-but-committed**（memory `5ee99c7`・週次 token 上限で window が外因消失した等）: env 自体は健全で、作業は **commit + self-test + bead に durable に残っている**。→ session を蘇生せず admin が **gate を引き取る**: worktree の commit / self-test を確認 → admin が reliable env で **独立に再走** → diff を精読 → PR → squash → close → `bd dolt push` → worktree remove。**作業は捨てない**（durable な成果を破棄して再実装しない）。
- **degraded-uncommitted**（本 incident・Bash 非永続）: Write tool 製 artifact のみ存在し **commit は 0**・self-verify は不可信。→ admin は worker の self-report を**信じず**、残った artifact から作業を再構成するか **独立に再走**する。**commit 0 のまま `bd close` が出ていても完了とみなさない**（§5 step1 Layer2 照合が裏取り＝CLOSED 単独を信用しない）。

検知の足場（2 層）: **worker 側 = sc-sau env-probe**（cross-call sentinel + `base..HEAD` 0-commit で fail-closed＝env 劣化時に worker 自身が `STATUS: blocked` を書き done を申告しない・Layer1）。**admin 側 = §5 step1 の commit-count 独立照合**（Layer2）+ 本節の窓生死（fleet-monitor `✗`）。**§7 の grill-consult 中断リカバリ（3段）は、この一般 salvage の consult 版**（出力がコードでなく決定・session-comm inject → 残 facet 再 spawn → admin 引き取り）。

> 一次出典: doobidoo `6d11f667`(un-8q5 pilot 横断 GOTCHA: session-state が WF 実行中に input-waiting を返す false-DONE／`verified`)・bd un-jax 引き継ぎ / scribe-design.md §9 通信モデル（PUSH=操舵注入）/ ubuntu-note-system `docs/session-orchestration-strategy.md` §3.2（外部・本リポ未同梱・session-comm wait-ready→inject）／ doobidoo `0264028f`（folio incident: 自前 poll silent cap 失効・CLOSED 依存・degraded 検出不能で停止見落とし＝本節監視規律の構造原因・真因は CC infra Bash 非永続〔`44f17714` で訂正〕）・`5ee99c7`（degraded-but-committed salvage = 週次上限 window 消失でも work は durable・admin gate 引取り）／ bd sc-ydg（salvage 2 系統 + 監視規律の成文化）・sc-sau（worker env-probe Layer1・§5 step1 が Layer2）。

---

## 7. needs-user タスクの扱い（WF pre-bake → grill-consult）

> **regime 再編（sc-cuw・2026-06-19）**: 本節は旧 F1=B regime（consult が pre-bake 専任で死に・grill は admin の場＝sc-osn/sc-in9 で codify）を改訂したもの。**pre-bake は consult から撤去し、admin が回す dynamic Workflow（`workflows/needs-user-prebake.workflow.js`）へ移管**した。consult は **grill 専任（原義回帰）** に戻り、admin が集約 brief を `--context` で渡して spawn する **grill-consult** が、**ユーザーと対話 grill する第 2 対話相手**になる（admin は grill から解放される）。旧 regime の経緯・dogfood 一次記録 = doobidoo `9c73606d`（設計合意）/ `b7c99f2f`（sc-in9 dogfood F1-F3）/ `8e98c34a`。
>
> **grill 方法論の実装（sc-swc・2026-06-19）**: grill-consult の grill 挙動は **grill-me スキル本文を SSOT** とし、build_consult_prompt が spawn 時に `$SCRIBE_GRILL_SKILL`（既定 `~/.claude/skills/grill-me/SKILL.md`）を **verbatim 注入**する（不在は fail-loud）。旧 build_consult_prompt は grill-me を自前 paraphrase し load-bearing ルール（AskUserQuestion 禁止・1論点1問）を落としていた（sc-vuu の grill dogfood で露呈）ため撤去。plain consult（`--context` 無し）の base テンプレは grill-me を名乗らないため不変。

- **対象**: needs-user タスク = worker 着手不可の理由が人間判断に依存する状態（概念定義 = `scribe-design.md` §1）。needs-user は駐車ラベル、本節の WF pre-bake + grill-consult が解決機構（別物）。
- **発火条件**: 人間判断を要する **相互独立な決定軸（facet）が複数（≥2）**あるとき、admin が pre-bake WF で各 facet を並列 read-only 分析する。1 facet なら admin インラインで足り、WF fan-out 不要（そのまま grill-consult を立てるか admin が直接 grill するかは admin 判断）。
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
- **grill-consult の read-only 限定緩和（§3 worker B/hybrid の subset・close を除く）**: grill-consult は **自分の grill-issue の `bd update --claim` と `--append-notes` だけ** を **bdw 経由**で書ける。`bd create` / `bd dep` / `bd dolt push` / `bd close` と tracked コード/ファイルの編集は **read-only 維持**（不可）。grill-consult = worker の変種（出力がコードでなく決定）で worker 境界に倣うが、**worker は自 issue を `bd close` できる（§4）のに対し grill-consult の close は admin 専有**ゆえ worker より厳しい subset。義務詳細 = `role-context-spec.md` §2.3。
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

> 一次出典: doobidoo `9be93364`（uns admin → scribe cross-ledger handoff: un-ao2 split・un-jcn A/B）・`cfd599dc`（federated 設計）・`115521de`（実隔離＝各層自身の bd-write-guard が機械強制し、scribe role 注入は cosmetic/advisory。本 §8 の writer 規律は admin が従う protocol 規約であって機械強制ではない）。

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
| scribe-design.md | 設計の why（§8 B/hybrid・§9 通信・§10 監視・§14 v0 スコープ） |

> 設計の細部に疑義が出たら、本書ではなく上記 doobidoo の原典を recall して確認すること（本書は実証ログ・notes を成文化した how 文書）。

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

worker を Claude Code 組込み bwrap sandbox に封じたいときは `SCRIBE_SANDBOX=1` を付けて spawn する（既定 off・**opt-in 未指定時は本番 spawn 経路 byte 不変**）。`scribe-spawn.sh` が `git worktree add` 後に worktree の `.claude/settings.local.json` を生成し、worker の Bash subprocess を「自 worktree + 共有 `.git` + anchor の `.beads` + bdw 鍵の置き場（`${BDW_LOCK_DIR:-${XDG_RUNTIME_DIR:-/tmp}}` ＝ `scripts/bdw` の lock_dir と同式。生式でなくこの参照式が主）」へ限定する。それ以外への書込みは OS 外壁が拒否する（`bypassPermissions` と直交）。生成 settings は worktree の `info/exclude` で ephemeral 化され worker の `git add` から保護される。

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
2. **cell-quality gate review（read-only・worktree 指定）**: admin が cell-quality WF を **read-only** で起動し、worktree を指定して gate review をかける（admin gate は dimensions 必須 4 観点固定＝`docs/methodology.md` §3 D3・強度の選び方は同 §1）。**snapshot 合成（PR#346）により worktree 指定で WF が `base...HEAD` diff を自動取得する**ため、diff の静的供給は不要（argshim も退役・defensive parse が tool レベルの string 化を吸収）。← だからこそ本リポは先頭に空の initial commit を置き、`base...HEAD` の合成が機能するようにしてある。
   - **道具ポインタ（bd un-7hx）**: この gate review 用 cell-quality args(JSON) の組み立ては **`scripts/scribe-gate-args.sh --worktree <path> <bd-id>` で 1 コマンド化済み**（`doPlan`/`doImplement`/`autoFix` を read-only にハードコード固定＝一次監査が実装/autoFix に化けない）。手作業で args を組まず道具を使うこと。
3. **findings 直読（refuted も鵜呑みにしない）**: WF の返り値 findings を admin が直読検証する。WF 内の adversarial verify が `refuted` と判定した finding も鵜呑みにせず、admin が一次監査する（gate は薄い一次監査・WF 返り値の机上承認ではない）。スコープ外（他リポ・他 cell の領分）を求める finding は却下し、却下理由を記録する。
4. **merge 前ユーザー確認**: 以下に該当する変更は merge 前に**ユーザー確認を取る**:
   - 規約・運用方針に関わる変更
   - 全ホストに影響する変更（配布物・グローバル hook・命名規約など）
   - outward（外部公開・不可逆）な操作
5. **push 前に origin URL 健全性を verify（汚染なら fail-loud + 復元）**（bd un-1n1）: squash merge / GitHub push の **前に** リポの `origin` URL が spawn 時 canonical のままかを照合する。worktree は anchor と `.git/config`（remotes）を共有するため、worker が origin を mutate すると anchor+全 worktree の origin が壊れ push が破綻する（2026-06-16 un-v5x 実害＝134s タイムアウト+gh が known host 無しと誤認）。汚染を検知したら **fail-loud し、canonical へ復元してから** push する（汚染したまま push しない）。
   - **道具ポインタ（bd un-1n1）**: spawn 時の canonical origin 捕捉と gate 時の照合・復元は **`scripts/scribe-origin-guard.sh {capture,verify,restore} --worktree <path>` で 1 コマンド化済み**。spawn は `scribe-spawn.sh` が `git worktree add` 直後に `capture`（canonical origin を per-worktree marker `.git/worktrees/<name>/scribe-origin.marker` へ捕捉）を自動実行する。gate では `scribe-origin-guard.sh verify --worktree <path>`（健全=exit 0 / 汚染=exit 非0・canonical URL を stdout）を push 前に走らせ、汚染時は `--restore` 併用 or `restore` サブコマンドで復元する。marker は per-worktree の private git dir に置く＝共有 config と別物ゆえ worker の config 汚染を生き延び、working tree 外ゆえ worker の編集スコープ外。
   - **marker 不在 verify が「意図的 fail-open（skip=exit 0）」である理由と将来の反転条件**（bd sc-vuu facet2）: `verify` は spawn 時 marker が無いと「照合不能」として **skip=exit 0**（warn のみ）に倒す。これは意図的な fail-open であり、(a) origin 無しのリポ（dogfood・新規リポ）は保護対象が無く `capture` も no-op で marker を作らないため、その verify が gate を素通りすべき、(b) marker 捕捉導入前に作られた既存 worktree との後方互換、の二点で正当化される（＝「未検証だから止める」ではなく「保護対象が無いから素通す」）。この default を **fail-loud（marker 不在=非0）へ反転**してよいのは、次の移行条件が**両方**揃ったとき: ① 全 spawn 経路が marker 捕捉を保証する（origin 付きリポで marker 不在＝「捕捉漏れ」と確実に言える状態）、かつ ② gate funnel が `verify` を自動配線で必ず通す（手動 skip の温存が不要になる）。それまでの間、marker 不在を厳格化したい個別 gate は additive opt-in の **`scribe-origin-guard.sh verify --require-marker`**（marker 不在=fail-loud・既定挙動は不変）を使う。なお「`capture` 失敗で marker が無い」と「origin 無しで marker が無い」を verify が区別する強化は別 issue 候補（現状は両者とも marker 不在として同じく扱う）。
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

### busy 判定の regex

worker が稼働中（busy = 入力受付不可）かを pane 下部行で判定する regex:

```
… \(|esc to interrupt|agents [0-9/ ]*(done|running)|tokens
```

- `… \(` … スピナー行 / `esc to interrupt` … 実行中 / `agents [0-9/ ]*(done|running)` … Workflow 進捗ボックス / `tokens` … トークン計上行。いずれかにマッチすれば busy。

### Workflow background 中の idle 見え（重要な落とし穴）

- **`session-state.sh` は Workflow tool 実行中の worker に `input-waiting` を返す**: WF はバックグラウンドで走り main loop の入力欄が空くため、**state ベース監視は WF 実行中に false-DONE する**。
- robust な監視は、pane 下部の **WF 進捗ボックス（`N/M agents done`）と spinner 行を併読**して判定する（state だけに頼らない・bd un-jax 引き継ぎ）。

### 停止時の復旧 = session-comm inject

- worker が idle に落ちた（prompt で停止した・queue exhausted）場合、cc-session の `session-comm` で操舵注入して復旧する: `wait-ready`（input-waiting を待つ）→ `inject-file`（flock で確実配送）。
- inject は worker の pane で起き、**admin の context には載らない**（PUSH チャネル・scribe-design.md §9）。`-t` 参照は window ID（`@N`）か `session:index` で行う（§1 の dotted id 衝突回避）。

> 一次出典: doobidoo `6d11f667`(un-8q5 pilot 横断 GOTCHA: session-state が WF 実行中に input-waiting を返す false-DONE／`verified`)・bd un-jax 引き継ぎ / scribe-design.md §9 通信モデル（PUSH=操舵注入）/ ubuntu-note-system `docs/session-orchestration-strategy.md` §3.2（外部・本リポ未同梱・session-comm wait-ready→inject）。

---

## 7. needs-user タスクの扱い（WF pre-bake → grill-consult）

> **regime 再編（sc-cuw・2026-06-19）**: 本節は旧 F1=B regime（consult が pre-bake 専任で死に・grill は admin の場＝sc-osn/sc-in9 で codify）を改訂したもの。**pre-bake は consult から撤去し、admin が回す dynamic Workflow（`workflows/needs-user-prebake.workflow.js`）へ移管**した。consult は **grill 専任（原義回帰）** に戻り、admin が集約 brief を `--context` で渡して spawn する **grill-consult** が、**ユーザーと対話 grill する第 2 対話相手**になる（admin は grill から解放される）。旧 regime の経緯・dogfood 一次記録 = doobidoo `9c73606d`（設計合意）/ `b7c99f2f`（sc-in9 dogfood F1-F3）/ `8e98c34a`。

- **対象**: needs-user タスク = worker 着手不可の理由が人間判断に依存する状態（概念定義 = `scribe-design.md` §1）。needs-user は駐車ラベル、本節の WF pre-bake + grill-consult が解決機構（別物）。
- **発火条件**: 人間判断を要する **相互独立な決定軸（facet）が複数（≥2）**あるとき、admin が pre-bake WF で各 facet を並列 read-only 分析する。1 facet なら admin インラインで足り、WF fan-out 不要（そのまま grill-consult を立てるか admin が直接 grill するかは admin 判断）。
- **facet の単位**: 通常は 1 needs-user issue = 1 grill-issue。1 issue 内に相互独立な複数決定があれば、各決定を 1 facet 扱いして pre-bake WF の `facets[]` に並べる（例: sandbox spike の「bwrap install 是非」と「書込み許可注入の設計」）。**濫用防止**: 相互独立でない・人間判断を要さない些末な選択肢は facet に分割しない。
- **フロー**:
  1. **pre-bake（admin が WF を回す・read-only）**: admin が `Workflow({name:'needs-user-prebake', args:{taskRef, taskTitle, anchor, facets:[{key,question,context}]}})` を起動する。各 facet を **並列 read-only agent** が分析（現状調査〔read-only〕→ 決定木 → 選択肢 + トレードオフ → admin 起票候補）し、opus が **単一の構造化 brief へ統合して WF 返り値（`briefMarkdown`/`facets`/`receivedArgs`）で admin に返す**。WF は **grill しない・graph を触らない・doobidoo 保存もしない**（データを admin に返すだけ）。admin は返り値を一次監査する（薄 gate＝worker 報告と同型）。
  2. **grill-issue 起票（admin）**: admin が brief を集約し、その needs-user 決定群を 1 件の **grill-issue** として起票する（`bd create`・依存 wire は admin）。
  3. **grill-consult spawn（admin）**: admin が brief を file へ書き、`scribe-spawn --consult --context <brief-file> <grill-issue>` で **grill-consult** を起動する（anchor 同居・SCRIBE_ROLE=consult）。brief は grill の **材料（第三者データ）** として焼き込まれる。
  4. **grill（ユーザー × grill-consult）**: **ユーザーが grill-consult と対話 grill** する。grill-consult は brief を出発点に決定木を一つずつ詰める（**admin は grill から解放される**）。
  5. **決定の handoff（grill-consult → bd notes）**: grill-consult は確定した決定を **own grill-issue の bd notes** に書く（`scripts/bdw update <grill-issue> --claim` / `--append-notes`・**bdw 経由のみ**）。admin はこの notes を `bd show <grill-issue>` で **real-time 監視**し、決まった facet から実装 cell を spawn する（**pipelining**＝全 facet の確定を待たない）。同一マシン anchor 同居ゆえ `bd dolt push` 無しで admin が即視認できる。
  6. **反映・cleanup（admin）**: admin が決定を graph へ反映（実装 cell 起票・dep wire）し、grill 完了後に grill-issue を `bd close`、grill-consult window を cleanup（`kill-window`）する。
- **admin 責務（明文化）**: ① pre-bake WF 起動 → ② brief 集約 → ③ grill-issue 起票 → ④ grill-consult spawn（context=brief）→ ⑤ bd notes 監視・決定反映 → ⑥ grill-issue close → ⑦ consult window cleanup（kill-window）。graph 変更・起票・`bd dolt push` は **すべて admin**（grill-consult は不可）。
- **grill-consult の read-only 限定緩和（§3 worker B/hybrid の subset・close を除く）**: grill-consult は **自分の grill-issue の `bd update --claim` と `--append-notes` だけ** を **bdw 経由**で書ける。`bd create` / `bd dep` / `bd dolt push` / `bd close` と tracked コード/ファイルの編集は **read-only 維持**（不可）。grill-consult = worker の変種（出力がコードでなく決定）で worker 境界に倣うが、**worker は自 issue を `bd close` できる（§4）のに対し grill-consult の close は admin 専有**ゆえ worker より厳しい subset。義務詳細 = `role-context-spec.md` §2.3。
- **F2 の構造解消**: 旧 regime の F2（consult が自分の pre-bake 出力をユーザー入力と誤認する事故）は、新設計で **pre-bake〔生成〕= WF agent / grill〔対話〕= grill-consult** と別主体に分かれ、**自己 pre-bake を誤帰属する主体が消える**ため構造的に解消する。grill-consult は brief を **外部 context（第三者データ）** として受け取るだけで自分では pre-bake しない。出典ヘッダ（「brief は WF の提案であって決定でない」）は **保険として** consult prompt に残す（`scribe-spawn` build_consult_prompt）。
- **旧 doobidoo handoff regime の撤去**: brief は **WF 返り値**（in-memory で admin に返る）であり、決定 handoff は **bd notes**（ローカル・flock 直列化）ゆえ、旧 regime の doobidoo 集約機構（共有 tag `scribe-brief-{id}` / `conversation_id` / un-sl9 の MEMORY.md 衝突回避 / F3 の doobidoo リトライ規律）は **本フローでは不要になり撤去**した（pre-bake が doobidoo を経由しないため）。grill-consult が任意で議論メモを doobidoo へ残すのは妨げないが、決定の SSOT は grill-issue の bd notes。
- パターン選択（いつ WF fan-out するか）= `methodology.md` §2。

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
| scribe-design.md | 設計の why（§8 B/hybrid・§9 通信・§10 監視・§14 v0 スコープ） |

> 設計の細部に疑義が出たら、本書ではなく上記 doobidoo の原典を recall して確認すること（本書は実証ログ・notes を成文化した how 文書）。

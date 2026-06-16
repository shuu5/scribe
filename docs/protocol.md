# scribe 手動 administrator プロトコル（規約 SSOT）

> **このファイルの位置づけ**
> 2026-06-10 の Wave1+2（10 PR 分）で **実証済み**の admin 手動プロトコルを成文化したもの。scribe-design.md §14 の v0 第 1 本柱「手動 admin プロトコルの成文化」に対応する。
> **将来の規約 SSOT** はこのファイル。project CLAUDE.md は本文の重複を持たず、ここへのポインタへ縮小する（縮小自体は別 cell = bd un-0c6 / C4）。道具（`scripts/`・C3）はここの手順をコード化し、role 別 SessionStart 注入（C2）は role ごとに必要な節をここから引く。
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

---

## 1. spawn 規約

worker を 1 issue = 1 worktree = 1 window で起動するときの命名・起動の規約。

> **道具ポインタ（bd un-7hx）**: 本節の spawn 手順（実在検証 → `git worktree add` → task prompt 生成 → `cld-spawn` → monitor）は **`scripts/scribe-spawn.sh` で 1 コマンド化済み**（worker モード既定・`--consult` で consult 起動・`--dry-run` で実 spawn せず arg-echo）。注入を受けた admin が道具の存在に気づかず手作業で再現しないよう、まず `scribe-spawn.sh --help` を確認すること（道具は本節の規約をコード化するだけで規約は変えない）。

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
- **禁止事項を定型で明示**: `bd create` / `bd dep` / `bd dolt push` / GitHub への push / admin window への tmux inject / スコープ外編集 / follow-up の bd create（§3 B/hybrid 境界）を prompt の「禁止」節に列挙する。

> 一次出典: doobidoo `3b838167`(Wave2)・un-8q5 pilot 横断 GOTCHA（WF args の JSON 文字列化・false-clean／`verified`）/ bd un-2yy（args defensive parse）/ bd un-cbi notes（worker の receivedArgs 報告実例・全 12 キー受領／`verified`）。

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
5. **squash merge → go-live**: 確認が取れたら squash merge し、go-live（配布・反映）する。
6. **cleanup**: worktree / branch / window を掃除する（`@N` 参照で window を kill・§1）。
   - **道具ポインタ（bd un-7hx）**: この cleanup（worktree remove / branch 安全削除 / window kill / `bd dolt push` リマインド）は **`scripts/scribe-cleanup.sh <bd-id>` で 1 コマンド化済み**（破壊操作は確認プロンプト付き・`--yes` で一括承認・**force 系は使わない**・`bd dolt push` は admin 専用ゆえ自動実行せずリマインドのみ）。手作業で掃除を再現せず道具を使うこと。
7. **dolt push 同期点**: 一連の funnel が片付いた区切りで admin が `bd dolt push` して台帳をマシン間同期する（§3・worker は push しない）。

- **N（並列 worker 数）の上限 = admin funnel 律速**: gate 逐次 + errata 往復 + ユーザー確認が直列なので、funnel がボトルネック。pilot 実測で **N=3 が快適**、N=4-5 はタスク所要が異質な編成なら成立。
- adversarial gate の検出力（実証）: dead import の fail-open 結合 / env 検証の octal fail-open（`SESSION_COMM_SUBMIT_ENTER_MAX=008` が bash 算術で不正 octal → 修正自体が無音失効）/ base-staleness アーティファクトの正確な診断などを、いずれも merge 前に捕捉した。

> 一次出典: doobidoo `3b838167`(Wave2)・`ac9022d8`(Wave1)・un-8q5 pilot（funnel 純 review 10-13min/PR・N 上限 = funnel 律速・snapshot 合成で diff 静的供給不要・adversarial gate 検出力／`verified`）。

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

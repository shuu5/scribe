# sandbox-spike (sc-1gu) — sandbox 本番ヘルパー（既定 on・opt-out=`SCRIBE_SANDBOX=0`・sc-u53）+ 実証 spike 記録

> ディレクトリ名は `sandbox-spike` のまま据え置く（sc-2m0 facet3・案C軽量）が、`gen-sandbox-settings.sh`
> は実証 spike を経て **本番反映済みの本番ヘルパー（既定 on・opt-out=`SCRIBE_SANDBOX=0`・sc-u53）**（下記「本番反映」節）。本ファイルは
> その本番ヘルパーの仕様 + 実証 spike（2026-06-18 検証済み）の記録を兼ねる。

scribe worker を **OS レベル sandbox**(Claude Code 組込み bubblewrap)で封じ込められるか、
かつ正当な cross-dir 作業(anchor の bd 台帳書込み)を壊さないかを、使い捨て worktree で実証する spike。

## 脅威モデル — sandbox が守るもの / 守らないもの（sc-451・正直な境界）

**本節が scribe sandbox の脅威モデル SSOT**（`docs/protocol.md` §1 / `docs/scribe-design.md` §6 はここへの
ポインタ）。security-audit（TB-1 high / TB-2 medium）で確定した正直な境界: scribe docs が worker を sandbox に
「封じる」と言うとき、その正確な意味は **worker の Bash subprocess の write を許可 path へ限定する**こと
（だけ）である。**完全隔離ではない**。

### 守るもの（実装済みの各レイヤ）

| 境界 | レイヤ | 実装 |
|---|---|---|
| Bash subprocess の write → worktree + 許可 path のみ | OS 外壁（bwrap・層2） | `gen-sandbox-settings.sh`（allowWrite は `.beads` runtime サブパス + 自リポの bdw flock 鍵 **file** へ最小化・OG-1/sc-nd6 + OG-4/sc-mcx） |
| built-in `Edit`/`Write`/`NotebookEdit`/`MultiEdit` → worktree 境界 | tool 層（PreToolUse hook） | `edit-write-guard.py`（SBX-ESC-1/sc-649。bwrap は Bash しか縛れないための別レイヤ） |
| 縮退の可視化・fail-loud | spawn 経路 | dep-preflight（sc-u53）+ opt-out loud warn / dry-run 可視化 / 生成 settings 強制キーの実行時アテステーション（FO-1/2/4・sc-7oj） |

### 守らないもの（非対象・到達限界の明示）

- **read は host 全体**（TB-1 high）: CC sandbox は write 封じ込めのみで、host filesystem を広く read 可能な
  まま走らせる。`bypassPermissions` worker は host の秘密（`~/.ssh`・`~/.cld-env`・認証 token 等）を**読める**。
- **network egress は非封鎖**（TB-1）: egress は CC sandbox の proxy 構成任せで scribe は追加封鎖しない。
  読めた秘密は**持ち出せる**。⇒ read+egress が非対象である以上、**敵対的 prompt（injection）を掴んだ worker
  による秘密の読出し・持出しは sandbox では防げない**。防御は worker に与える入力（issue 本文・参照させる
  ファイル）の信頼に依存する。
- **admin/consult の ingest 非対称**（TB-2 medium）: admin/consult は**非 sandbox + `bypassPermissions`** の
  まま worker 生成物（bd notes・commit・diff・self-report）を取り込む＝**最も封じ込めの弱い principal が最も
  敵対的になりうる入力を処理する**。現状は信頼前提の運用（脅威モデル A=うっかり対応・`docs/scribe-design.md`
  §6。B=意図的偽装への壁は provenance 署名 lane・v1+）。gate funnel（protocol §5）の「worker の報告を信じず
  ground truth を verify する」規律が、この非対称に対する現行の運用上の補償である。
- **dolt DB の raw 書換**（OG-1 到達限界・sc-nd6）: `embeddeddolt/` を dir で grant する以上、worker は dolt DB
  を raw 書換でき**他 issue の改竄は OS 層では防げない**（tool 層の universal beads-bdw guard が別レイヤの補償
  ＝scribe bespoke の bd-write-guard は撤去され堀は beads-bdw plugin へ移管済・un-2uap Leg-R-sc）。
- **CC が settings を honor すること自体**（FO-2 残存・sc-7oj）: spawn 時の実行時アテステーションは「我々が
  置いたファイルの強制キー」までしか検証できない。CC 本体の version/precedence drift による fail-open は
  spawn 時に検証不能＝opt-in e2e lane（`SCRIBE_SANDBOX_E2E=1`・sc-7n1・下記「sandbox 内の実操作 e2e」節の
  block-side control）が実 CC で外壁の実効を検証する唯一の手段。

## 前提(ホスト)

CC 組込み sandbox は次の3つを要求する(spike で実測):

1. `bubblewrap`(`apt install bubblewrap`)
2. **`socat`**(`apt install socat`) — network proxy 用。**欠けると `failIfUnavailable` で CC が起動拒否**し
   コマンドが一切走らない(spike 初回はこれで全 assert が無効化された)。
3. **userns が使えること** — 次のどちらかの方式（判定は方式に依らず実プローブで行う・下記）:
   - `kernel.apparmor_restrict_unprivileged_userns=0`(Ubuntu 24.04)。`/etc/sysctl.d/` に置いて
     `sudo sysctl --system`。**ホスト全体の userns ハードニングを外す**ため、マルチユーザーホストでは
     security トレードオフを承知の上で。ロールバック = その conf を rm して再 `sysctl --system`。
   - **bwrap への targeted apparmor profile**（ホスト全体の sysctl を緩めず bwrap だけに userns を許可）。
     **マルチユーザーホストはこちらが推奨**（global sysctl=1 のまま sandbox が成立し、他ユーザーの攻撃面を
     広げない）。CC 公式 docs（`code.claude.com/docs/en/sandboxing`）の profile を verbatim で置く:
     ```bash
     # /etc/apparmor.d/bwrap に配置（要 sudo）
     sudo tee /etc/apparmor.d/bwrap >/dev/null <<'EOF'
     abi <abi/4.0>,
     include <tunables/global>

     profile bwrap /usr/bin/bwrap flags=(unconfined) {
       userns,
       include if exists <local/bwrap>
     }
     EOF
     sudo systemctl reload apparmor
     # 検証: bwrap --ro-bind / / --unshare-user echo ok  → "ok"
     # ロールバック: sudo apparmor_parser -R /etc/apparmor.d/bwrap && sudo rm /etc/apparmor.d/bwrap
     #   （`systemctl reload` は削除済み profile を kernel から unload しない＝reload だけでは posture が
     #    復元されない。先に apparmor_parser -R で in-kernel profile を revoke してから rm する。）
     ```
     （bwrap のパスが `/usr/bin/bwrap` でない場合は `profile bwrap <path> flags=(unconfined)` 行の
     `<path>` を実パスに合わせる。）
   判定は方式に依らず **実プローブ** `bwrap --ro-bind / / --unshare-user true` で行う＝global sysctl 値は
   読まない（profile 方式で false-negative になるため）。実体 = `scribe_sandbox_preflight`（scribe-lib.sh）。

### 既定 on（opt-out）+ dep-preflight（sc-u53）

worker は **既定で** sandbox 化される（`SCRIBE_SANDBOX=0` で opt-out・本番 spawn 行は byte 不変）。default-on
ゆえ deps 欠如 host では spawn が **worktree を作る前**に `scribe-sandbox-preflight.sh` で先回り検査し（bwrap/socat/userns
〔実プローブ〕に加え **jq**＝settings 生成器 `gen-sandbox-settings.sh` の hard 依存も検査する。jq 不在を見落とすと
worktree add 後に gen が落ち orphan を残す・round3 gate）、欠如時は
**fail-loud で停止**する（黙って無防備に走らせない＝fail-closed・sc-u53 ユーザー確定）。`SCRIBE_SANDBOX_FALLBACK=1`
を置いた host **だけ**警告付きで非 sandbox 続行する（明示エスケープ）。手動 fleet チェック =
`scripts/scribe-sandbox-preflight.sh`（充足 exit 0 / 欠如 exit 1 + 欠落理由を stdout）。

## スクリプト

- `gen-sandbox-settings.sh <worktree> [<anchor>]` — worker 用 `.claude/settings.local.json` を stdout 出力。
  `sandbox.filesystem.allowWrite` に `<ANCHOR>/.beads`(台帳・runtime サブパスのみ) と自リポの bdw flock 鍵
  **file**(`${lock_dir}/bd-write-<repo_id>.lock`・`bdw lock-file` に問い合わせて byte 一致・OG-4/sc-mcx。
  lock dir 丸ごとを開けず同 dir 内の他リポ鍵に触れない) を絶対パスで入れる。cwd(worktree) と linked worktree の共有 `.git` は sandbox 既定で
  writable(列挙不要)。
  **anchor は第2引数で明示するのが正**(sc-lkg): 省略時のみ worktree から逆算する。cross-repo cell
  (`scribe-spawn --repo X --anchor Y`・X≠Y)では worktree は repo X 側に在り逆算 anchor=X になるが真の
  bd graph は Y ゆえ allowWrite が誤った `.beads` を grant する。scribe-spawn は真の `--anchor` を渡す。

> spike ハーネス `run-spike.sh` は spike 目的達成後 deadcode として削除した(commit 71bf862 で凍結・sc-18q)。
> 本番反映は下記「本番反映」節のとおり `gen-sandbox-settings.sh` の direct-gen が担う。

## 検証済み(2026-06-18)

spike ハーネス(commit 71bf862)で 5/5 PASS(全て ran=yes ＝ genuine):

| assert | 期待 | 結果 |
|---|---|---|
| a1 cwd 書込み | allow | PASS |
| a2 `<ANCHOR>/.beads` 書込み | allow | PASS(明示 allowWrite が効く) |
| a3 `$XDG_RUNTIME_DIR` 書込み | allow | PASS |
| b1 anchor 直下(worktree の親) | block | PASS(層2 外壁) |
| b2 `$HOME`(リポ外) | block | PASS(層2 外壁) |

⟹ CC sandbox は worktree-local `settings.local.json` の allowWrite 境界を OS レベルで強制する。
正当な cross-dir 書込み(cwd/.beads runtime/自リポ lock 鍵 file)は通り、外への書込みは封じる。

> **sc-da0 → sc-xs2（grant 最小化 + lock_dir 収束・上表 a3 の更新）**: spike 当時(2026-06-18)は
> `$XDG_RUNTIME_DIR` を丸ごと allowWrite に入れていたが、bdw が要るのは flock 鍵 1 ファイルのみ。
> sc-da0 で専用サブdir のみへ最小化し、**sc-xs2(2026-06-21)で lock_dir を `$HOME/.cache/bdw-locks`
> （scribe 以外の bd writer = orch/uns bdw と byte 一致）へ収束**させた（旧 `$XDG_RUNTIME_DIR/scribe-bdw`
> は base 違い + subdir 付与で構造分岐し lost-update を生んでいた）。sc-vae cutover で lock SSOT は
> canonical bdw〔beads-bdw plugin〕へ一本化され、**OG-4/sc-mcx(2026-07-04) で grant を dir 丸ごとから
> 自リポの flock 鍵 file 単位へ狭化**（gen-sandbox は `scripts/bdw lock-file` で問い合わせて worker の
> bd write と byte 一致・同 dir 内の他リポ鍵に触れない＝残存 DoS を解消）。bwrap の bind-before-exist
> のため `scribe-spawn.sh` が worker 起動前に parent lock dir を mkdir し鍵 file を touch で先在させる。

## 本番反映(実装済み: direct-gen)

> **sc-u53 更新**: 本番は default-on（opt-out=`SCRIBE_SANDBOX=0`）へ反転済み。現行の opt-out/preflight セマンティクスの
> SSOT は本ファイル冒頭「### 既定 on（opt-out）+ dep-preflight（sc-u53）」節。以下は sc-1gu 当時（opt-in）の direct-gen 反映記録。

worker spawn 時（既定 on・`SCRIBE_SANDBOX=0` で opt-out・sc-u53）、`scripts/scribe-spawn.sh` が `git worktree add` 後に
`gen-sandbox-settings.sh` で worktree の `.claude/settings.local.json` を**直接生成**する
(`CLD_PATH`/cld-spawn/launcher は触らない＝opt-out 時は本番経路 byte 不変)。生成した
settings は worktree の git exclude(`info/exclude`)へ冪等追記して ephemeral に保つ
(worker の `git add -A` で巻き込まない・全マシン/全ユーザーで効かせる)。

> decision② の元案「CLD_PATH wrapper」は撤回: worker 経路は ENV_FILE を使わず tmux new-window が
> server 環境で走るため wrapper へ本物の cld パスを渡せず複雑化する。direct-gen の方が単純で
> ratified 本質(opt-in / byte 不変 / failIfUnavailable / D1 穴)を保つ。

検証: bats(SCRIBE_SANDBOX gating + spawn 行 full-line byte 同一)。

**旧「残」項目は完了済み（sc-jqd で source of record と突合）**:
- ✅ live opt-in の end-to-end spawn 実証(D7 c/d): `sc-1gu` で「live e2e で worker が sandboxed に boot」を実証済（commit 71bf862 / 4d16943 / 5bbd57a）。
- ✅ docs(protocol.md)へ socat 前提反映済: `docs/protocol.md` の「sandbox（既定 on・opt-out=SCRIBE_SANDBOX=0）」節（sc-u53 で旧「sandbox opt-in」から改名）が `bubblewrap`+`socat`+userns 必須・dep-preflight・fallback を明記。

この spike-record に未完項目は残っていない（本番反映は上記「本番反映(実装済み: direct-gen)」節＝production・後続の最小化は sc-da0）。

## sandbox 内の実操作 e2e (sc-7n1)

spike の境界 assert(上表 a1/a2/b1/b2)は**生ファイル書込み**までだった。`verify-sandbox-e2e.sh` は
その先 — sandboxed worker の**実操作**が allowWrite 境界を通って*永続*するか — を埋める:

- **git commit → 共有 .git に永続**（linked worktree の `.git` は `$ANCHOR/.git`＝cwd の外だが、CC
  sandbox 既定で writable。allowWrite への列挙不要を**実証**＝gen-sandbox の前提が正しいことを裏取り）。
- **bd close → `<ANCHOR>/.beads` に永続**（明示 allowWrite（.beads runtime + 自リポ lock 鍵 file）grant が効く）。
- **block-side control → allowWrite 外（anchor 直下）への書込みが外壁に拒否される**（spike の b1 を 1 点継承）。
  これが無いと sandbox を無効化しても上 2 つは PASS し『境界を*通って*永続』を実証できない（boundary-vacuous）。
  3 つ揃って初めて「外壁が genuine に効いた状態で実操作が永続する」を意味する。

方式は spike 同様 **実 Claude Code(`claude -p`)を worktree で起動**し CC 自身の bwrap を適用させる
（自前 bwrap を組まない＝CC 実体との乖離なし）。完全 hermetic（`mktemp -d` の使い捨て temp anchor +
独立 bd 台帳。実 scribe の repo/.beads は触らない）。前提が欠ければ rc=77 で skip。

```
bash scripts/sandbox-spike/verify-sandbox-e2e.sh          # 単発（deps 要・PASS=4 FAIL=0 が green）
SCRIBE_SANDBOX_E2E=1 bats tests/scribe-tools.bats         # 回帰の opt-in lane で実走
```

既定の `bats tests/scribe-tools.bats` は CC を起動せずハーネスの契約のみ host 非依存に lock する。

### sandbox 下の stage は `scribe-add` で（sc-yqa・B 方式）

CC sandbox は worker cwd の既知 dotfile（`.bash_profile` `.bashrc` `.gitconfig` `.gitmodules` `.profile`
`.zprofile` `.zshrc` `.mcp.json` `.idea` `.vscode` `.ripgreprc`＝11）と `.claude/` 設定（`agents` `commands`
`hooks` `skills` `workflows` `routines` `launch.json` `scheduled_tasks.json` `settings.json`＝9）を
**`/dev/null` character device** として null-mount し無害化する（CC のセキュリティ機構・**設定で外せない**＝
verified・GH#17258/#17087）。git は device の add を拒否するため、素の `git add -A` / `git add .` は rc=128 で
失敗し空 commit を生む。

**対策（B）**: worker は `git add -A` でなく **`scripts/scribe-add`** で stage する。scribe-add は未追跡の
**通常ファイルと symlink** を型で選んで stage し（`[ -h ] || [ -f ]` で char/block device 等の非通常ファイルにだけ
`git add` をかけない。`[ -f ]` 単独だと dangling/→dir symlink を deref して黙って落とすため `[ -h ]` を OR する）、
追跡変更は `git add -u --ignore-errors` で拾う。型ベースゆえ **CC が null-mount リストを 20→N 個に増やしても
壊れない**（名前リストに結合しない）。共有 `info/exclude` を汚さないので **非 sandbox worktree への漏れもゼロ**
（論点3 を完全に解消）。worker prompt には SCRIBE_SANDBOX 時のみ scribe-add 規律を注入する。
（限界: 未追跡のネスト git repo は stage しない＝worker はネスト repo を作らない前提。）

本ハーネスは commit 経路に **scribe-add を実走**し、sandbox 下で device を弾いて commit が共有 .git に永続する
ことを実証する。加えて **negative control** として素の `git add -A` も 1 度走らせ、それが実 sandbox の char-device で
rc=128 失敗することを assert する（scribe-add の必要性＝退行は loud fail を counterfactual で実証・gate blocking#1）。
CC が null-mount を増やしても scribe-add は型ベースで壊れない（sc-yqa 4b の番人）。

> 旧 E 案（info/exclude に dotfile を列挙）は、CC が `.claude/*`（普通にコミットされる設定）も null-mount する
> ことが e2e で判明し、共有 exclude の漏れが広いうえ CC のリスト churn に脆く、真の per-worktree 化は共有
> `.git/config` mutate（un-1n1 違反）を要するため B 案へ切替えた（sc-yqa grill）。

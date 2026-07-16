---
name: setup
description: |
  scribe を使い始めるプロジェクトの beads(bd) セットアップを「我々の正しい構成」へ冪等に収束させ、
  scribe role 別 SessionStart 注入を opt-in 成立させる reconciler（旧 ubuntu-note-system beads-init を移管）。
  正しく入っていれば何もせず、間違って入っていれば（bd 既定の汚染・二重発火・旧役割入り PRIME）修正し、未導入なら正しく入れる。
  bd 既定の init は CLAUDE.md/AGENTS.md を方針と正反対のポリシー（bd remember 推奨・git push 必須）で汚染し、
  project-local settings.json を生成してグローバル hook と二重発火する。本スキルはそれを検出・是正する。
  新規導入時は scriptorium DEFAULT_PROJECTS（orchestrator の federation-read 集合）への編入判断を一問挟む
  （intent 路・自動 add はしない・編入の実 write は orchestrator 側 PR）。

  Use when user wants to: このプロジェクトで scribe を使い始める / beads を入れる・直す / bd を初期化 / issue 追跡を始める,
  says 「scribe をこのリポに入れる」「beads入れて」「bd init して」「beads のセットアップを直して」「このリポで scribe/bd 使いたい」。
---

# scribe:setup Skill（冪等 reconciler — beads 導入 + scribe opt-in）

scribe を使い始めるプロジェクトの beads セットアップを**我々の正しい構成へ収束**させ、**scribe role 別
SessionStart 注入が opt-in で発火する状態**にする。各次元を独立に「検出 → 正しければ skip / 違えば修正 /
無ければ追加」する。**何度実行しても安全（冪等）**。

> **scribe opt-in の意味**: scribe は per-project の opt-in plugin。プロジェクトに `.beads/`（永続タスク台帳）が
> でき、PRIME が role 中立版になると、scribe の role 別 SessionStart 注入（admin / worker / consult）が矛盾なく
> 機能する。旧・役割入り PRIME（「着手前に bd create」「終了に bd dolt push」を全セッションへ一律注入）は scribe
> 注入と二重・矛盾するため、本 skill は PRIME を role 中立版へ同期する。

## 正しい構成（収束ゴール）
1. `bd` が **導入済み**（バージョンは pin しない・upgrade 前検証は人間ポリシー＝PRIME §バージョン管理。reconciler は特定バージョンを強制/ダウングレードしない）
2. `.beads/` が存在（embedded Dolt）
3. `bd config` の `backup.git-push = false`
4. Dolt remote `origin = git+https://...`（マルチPC同期）
5. `.beads/PRIME.md` が**我々の役割中立版**（役割分担・bd remember 禁止・役割規約は scribe role 注入へ委譲）
6. CLAUDE.md/AGENTS.md に **bd 既定の汚染ブロックが無い**（`bd remember` 推奨/`git push` MANDATORY 等）
7. project-local `.claude/settings.json` に **bd の `bd prime` hook が無い**（グローバル hook と二重発火しない）
8. `.gitignore` が `issues.jsonl`/`interactions.jsonl`/`embeddeddolt/` と scribe runtime marker 2 種（`/.beads/scribe-heartbeat`・`/.beads/scribe-push-throttle`）を除外（Dolt が SSOT・marker は hook 生成物）
9. プロジェクト CLAUDE.md に**矯正済みポインタ節**（bd マーカー無し・役割規約は scribe role 注入が SSOT）
10. **scribe role 注入が opt-in 成立**: `.beads/` が在り（= scribe で管理する意思表示）、PRIME が role 中立版で
    scribe role 別 SessionStart 注入（admin/worker/consult）と矛盾しない。scribe plugin 登録済みなら、これで
    worktree=worker / `SCRIBE_ROLE=consult`=consult / anchor=admin の注入が矛盾なく発火する状態になる。

## Step 0: 状態検出（read-only。まず現状を一覧化して報告）

git root で以下を実行し、各次元の状態を把握する:
```bash
root=$(git rev-parse --show-toplevel) && cd "$root"
bd --version 2>/dev/null                                   # → 導入済みか（バージョンは pin しない）
test -d .beads && echo "BEADS:yes" || echo "BEADS:no"
bd config get backup.git-push 2>/dev/null                  # → false か
bd dolt remote list 2>/dev/null | grep -q '://' && echo "REMOTE:yes" || echo "REMOTE:no"
# PRIME.md が我々の版か（sentinel: 役割分担 + bd remember 禁止）
if test -f .beads/PRIME.md && { grep -q 'beads-init-template v:' .beads/PRIME.md || { grep -q '役割分担（最重要）' .beads/PRIME.md && grep -q 'memories` は使わない' .beads/PRIME.md; }; }; then echo "PRIME:ours"; else echo "PRIME:missing/wrong"; fi   # marker か役割分担 sentinel で判定（既存の marker 無し正版も救済＝移行安全）
# PRIME が role 中立版か（marker バージョン番号で判定＝本文フレーズに依存しない。将来 PRIME を再編集して
# 偶然「セッション終了プロトコル」等を含めても marker が残る限り誤上書きしない）。我々版でも marker が旧/無しだと
# scribe opt-in 未成立。役割中立版の最小 marker バージョン（v:1）未満 or marker 無しは旧世代＝要同期。ただし
# marker 無し/旧版でも明示的 role 中立 sentinel「本 PRIME は role 中立」があれば救済（移行安全・上の ours 救済と整合）。
MIN_ROLE_NEUTRAL_VERSION=1
prime_ver=$(grep -oE 'beads-init-template v:[0-9]+' .beads/PRIME.md 2>/dev/null | head -1 | grep -oE '[0-9]+$')
# marker があれば v:N が唯一の権威で判定（v:0 等の旧版は本文に何が書かれても要同期＝sentinel で救済しない）。
# marker が無いときだけ role 中立 sentinel で移行救済（pre-marker な hand-derived 正版を過剰同期しない）。
# こうすると marker 権威が一貫し、旧版が本文中で偶然 sentinel 句に言及しても誤って role-neutral に倒れない。
if test -f .beads/PRIME.md && { if [ -n "$prime_ver" ]; then [ "$prime_ver" -ge "$MIN_ROLE_NEUTRAL_VERSION" ]; else grep -q '本 PRIME は role 中立' .beads/PRIME.md; fi; }; then echo "PRIME:role-neutral"; else echo "PRIME:role-laden(marker 旧/無し・要同期)"; fi
# CLAUDE.md/AGENTS.md の bd 既定汚染（英語既定の特徴句）
for f in CLAUDE.md AGENTS.md; do grep -qE 'Use `bd remember`|do NOT use MEMORY\.md|PUSH TO REMOTE' "$f" 2>/dev/null && echo "POLLUTED:$f" || true; done
# project-local settings.json の bd prime hook（二重発火）。bd が書く正規 command はラッパ形
# `command -v bd >/dev/null 2>&1 && bd prime || true`（引用符で囲まれない）なので、リテラル `"bd prime"` を
# 探すと NO MATCH で fail-open する。引用符を外した部分一致 `bd prime` で検出する。
test -f .claude/settings.json && grep -q 'bd prime' .claude/settings.json && echo "DOUBLEFIRE:yes" || echo "DOUBLEFIRE:no"
# gitignore は必要行の全充足で yes（issues.jsonl のみの粗判定だと runtime marker 未収束でも yes になり #8 が skip される）
{ grep -q 'issues.jsonl' .gitignore && grep -q 'scribe-heartbeat' .gitignore && grep -q 'scribe-push-throttle' .gitignore; } 2>/dev/null && echo "GITIGNORE:yes" || echo "GITIGNORE:no"
```
結果を「✅正しい / ⚠️要修正 / ➕要追加」で表にして報告してから収束に進む。**変更が一切不要なら「既に正しい構成」と報告して終了**。

## Step 1〜: 各次元を収束（必要な次元だけ実行）

### bd 導入（#1）
未導入なら案内: `npm install -g @beads/bd`。**バージョンは pin しない**（旧ポリシーの v1.0.4 ピンは撤廃）。**特定バージョンの強制・ダウングレードは促さない**。upgrade する場合は upgrade 先の migration がマルチPC同期を壊さないか検証してから上げる＝人間判断（reconciler は代行しない）。参考: v1.0.5+ の migration 0043 が過去に #4259 で同期破壊。remote-backed DB の schema 移行は単一指定移行者のみ（PRIME §バージョン管理）。

### .beads（#2）— 無いときだけ init
```bash
bd init --prefix <PREFIX> --non-interactive --skip-agents --skip-hooks
```
`--skip-agents`(CLAUDE.md/AGENTS.md/settings 生成抑止) と `--skip-hooks` は**必須**。
**既に `.beads/` が有れば re-init しない**（`bd init --force/--reinit-local/--destroy-token` は PreToolUse guard がブロック＝データ消失防止）。prefix はプロジェクト名から導出しユーザー確認。

### backup.git-push（#3）/ Dolt remote（#4）
```bash
bd config get backup.git-push 2>/dev/null | grep -qx false || bd config set backup.git-push false
bd dolt remote list 2>/dev/null | grep -q '://' || {
  url=$(git remote get-url origin); case "$url" in git@github.com:*) url="https://github.com/${url#git@github.com:}";; /*) url="file://$url";; esac  # ssh→https / ローカル絶対パス→file://（git+ は URL scheme 必須。scheme 無しは bd が拒否）
  bd dolt remote add origin "git+${url%.git}.git"; }
```
origin remote が無い場合もスキップし「後で `bd dolt remote add origin git+<url>` を」と案内（安全・再 init はしない）。

### PRIME.md（#5）— missing/wrong または旧版（marker 旧/無し・role-laden）のときだけ配置
テンプレ（**この skill に同梱** `${CLAUDE_PLUGIN_ROOT}/skills/setup/PRIME.template.md`）を置換コピー:
```bash
proj=$(basename "$(git rev-parse --show-toplevel)")
sed "s|{{PROJECT}}|${proj}|g" "${CLAUDE_PLUGIN_ROOT}/skills/setup/PRIME.template.md" > .beads/PRIME.md
```
`|` 区切りで `/` を含むパスに耐える。proj 名に `|`/`&`/`\` を含む稀なケースは sed が壊れ得るので、その時は Read+Write で手動置換する。
「我々の版か」判定は marker `beads-init-template v:` か役割分担 sentinel（#5）で行う。「role 中立か」判定は **marker バージョン番号**で行う（PRIME 本文の自然言語フレーズには依存しない＝将来 PRIME を再編集して偶然「セッション終了プロトコル」「着手前に bd create」等を含めても marker が残る限り誤上書きしない）。**marker `beads-init-template v:N` の N が役割中立版の最小バージョン（`v:1`）未満、または marker が無く role 中立 sentinel「本 PRIME は role 中立」も無い旧世代を検出したら、scribe 注入と矛盾するので役割中立版へ同期する**（marker があれば `v:N` が唯一の権威＝旧バージョンなら本文に何があっても上書き対象。marker が無いときだけ role 中立 sentinel で移行救済し同期しない）。既存 PRIME.md が「our でなく独自カスタム」の場合は**上書きせずユーザーに確認**（意図的カスタムを尊重）。

### 汚染除去（#6）— POLLUTED:<file> のときだけ
CLAUDE.md/AGENTS.md を Read し、`<!-- BEGIN BEADS INTEGRATION -->` 〜 `<!-- END BEADS INTEGRATION -->` の **bd 既定汚染ブロックを丸ごと削除**（Edit）。bd 既定の特徴句（`Use bd remember`/`do NOT use MEMORY.md`/`PUSH TO REMOTE ... MANDATORY`）を含む版のみが対象。我々の矯正済み内容なら触らない。

### 二重発火除去（#7）— DOUBLEFIRE:yes のときだけ
project-local `.claude/settings.json` から `bd prime` を含む hook **だけ**を削除（他の project-local hook は保持）。`del(.hooks.SessionStart)` のような event 丸ごと削除は正規 hook を巻き込むため**禁止**。
**構造に注意**: settings.json の hooks は `event名 → [{matcher, hooks:[{command,type}]}]` の**ネスト**（各 group が `hooks` 配列を持つ）。下の jq の内側 `.hooks` はこの **group の hooks 配列**を指し正しい（`event → [{command}]` のフラットと誤読して `.command` を group 直下で探さないこと）。
**完全一致比較は禁止**: bd が書く正規 command はラッパ形 `command -v bd >/dev/null 2>&1 && bd prime || true` であり、リテラル `"bd prime"` とは等しくない。完全一致 `!= "bd prime"` だと bd 既定の hook が除去されず fail-open する。`contains("bd prime")` の**部分一致**で判定し、ラッパ形も確実に剥がす。以下の jq は `bd prime` を含むコマンドのみ除去し、空になった hook group / event を刈り込む:
```bash
jq '.hooks |= (to_entries | map(.value |= (map(.hooks |= map(select(((.command // "") | contains("bd prime")) | not))) | map(select(.hooks|length>0)))) | map(select(.value|length>0)) | from_entries)' .claude/settings.json > .claude/settings.json.tmp && mv .claude/settings.json.tmp .claude/settings.json
jq empty .claude/settings.json   # JSON 妥当性確認
```
グローバル `~/.claude/settings.json` の hook が SSOT。

### gitignore（#8）
`.gitignore` に冪等追記（無い行だけ）: `.beads/issues.jsonl` / `.beads/interactions.jsonl` / `embeddeddolt/` に加え、
scribe hook が焼く **runtime marker 2 種**を root-anchored で除外する: `/.beads/scribe-heartbeat`（SessionStart/End
heartbeat）・`/.beads/scribe-push-throttle`（Stop hook 即 push の throttle）。いずれも mtime が本体の hook 生成物で
commit しない（scribe plugin が有効な project では anchor session が自動生成するため、除外しないと untracked 表示・
`git add -A` 誤 commit の芽になる）。bd init は `interactions.jsonl` を git 追跡するため**必ず** untrack する。ただし `issues.jsonl` は init 直後は未生成のことが多く、pathspec 不一致で `git rm` が **atomic 失敗**（present 側の `interactions.jsonl` も untrack されない）するため **`--ignore-unmatch` 必須**（marker 2 種も誤 commit 済みの可能性に備え同列で untrack）:
```bash
git rm --cached --ignore-unmatch .beads/issues.jsonl .beads/interactions.jsonl .beads/scribe-heartbeat .beads/scribe-push-throttle
```

### CLAUDE.md ポインタ（#9）— 無いときだけ追加（bd マーカー無し）

> **この注入テンプレは「縮退時の最小フォールバック」として意図的に PRIME と一部 overlap する**（bd 運用ルールの SSOT は `.beads/PRIME.md`・SessionStart hook が毎セッション注入。本ポインタは bd 未導入で PRIME がまだ注入されない過渡期だけの最小安全網）。ゆえに**逐語の理由文・版番号は持たせない**（持たせると PRIME 変更時に stale 化するドリフト源になる＝本テンプレが防ごうとしている重複そのもの）。詳細・理由は PRIME が SSOT で、食い違ったら PRIME が優先。テンプレ更新時はこの最小性を保つこと。

```markdown
## Beads Issue Tracker (bd) + scribe

タスク追跡は **bd (beads)**。SessionStart hook が `bd prime` で bd 基礎の文脈を毎セッション注入する（**運用ルールと詳細の SSOT = `.beads/PRIME.md`**）。本節は PRIME が注入されない bd 未導入時だけの最小フォールバック。

- **タスク = beads / 知識 = doobidoo**: 永続・横断の作業は bd issue で追跡。知見は doobidoo に保存し、**`bd remember/recall/memories` は使わない**（理由・詳細は PRIME）。
- **役割を帯びた規約（誰が create/dep/close/dolt push するか・終了プロトコル）の SSOT は scribe plugin の role 別 SessionStart 注入**（admin / worker / consult）。PRIME は role 中立な基礎のみを持つ。
```

### scriptorium DEFAULT_PROJECTS 編入判断（intake 一問・新規導入時のみ）

> **出自と対の設計**: orch-rafl grill 裁定[論点6(3)]（user 裁定 2026-07-16）の **intent 路**。orchestrator 側には
> disk-scan reconciliation（disk 上の `.beads/metadata.json` 走査 vs DEFAULT_PROJECTS の差分 loud surface・自動 add
> しない）が **backstop** として別途在る＝本 step を飛ばしても最終的には backstop が拾う（fail-safe）。

**発火条件**: この run で `.beads/` を**新規に作成した**とき（Step 0 が BEADS:no → #2 で init した新規導入）だけ
一問挟む。既導入 project への冪等再実行では**発火しない**（既存 stock の編入判断は orch 側 backstop の担当＝
再実行のたびに聞き直すノイズを出さない）。ユーザーが明示的に編入判断を求めたときはこの限りでない。

**問い（一問）**: 「この project を scriptorium orchestrator の **DEFAULT_PROJECTS**（= orchestrator が横断 read する
federation-read 対象の project 集合。sweep の SSOT ではない）へ編入しますか?」
判断材料を添えて人間に問う: 継続的に作業が走る active な project か（dormant な project は編入しない先例）、
orchestrator の観測・cross-project 調整の対象にする意思があるか。**無人実行では勝手に決めず「保留」**として
Step 末の報告に残す（backstop が後日 surface する）。

**yes → needs-orch 上り intake を起票**（**自動 add はしない**。DEFAULT_PROJECTS への実 write = scriptorium
`scripts/lib/orch-projects.sh` の編集は **orchestrator 側 PR**。本 skill が scriptorium repo に触れることは無い）:
```bash
proj=$(basename "$(git rev-parse --show-toplevel)")
# 冪等ガード: 既に同旨の依頼 bead が在れば再作成しない（SKIP が出たら以降の notes/label も行わない）
bd search "DEFAULT_PROJECTS" 2>/dev/null | grep -q "編入依頼" \
  && echo "SKIP: 既存の編入依頼 bead あり（冪等・再作成しない）" \
  || bd create --title="scriptorium DEFAULT_PROJECTS へ ${proj} を編入依頼" --type=task --priority=2 \
       --description="scribe:setup の編入判断 step（intent 路）発の上り依頼。人間 yes 裁定済み。"
# ↑の出力 id で notes（必須 3 節 front-load）→ label の順に付ける（label だけ先行させない）
bd update <id> --append-notes "## 依頼
scriptorium DEFAULT_PROJECTS へ entry「${proj}=$(git rev-parse --show-toplevel)」を追加する orchestrator 側 PR を依頼（entry 形式は name=絶対パス・trailing slash 無し）。
## scope
編入 entry の追加のみ（実 write は orchestrator 側。関連 channel の override 要否も orchestrator 判断）。
## acceptance
DEFAULT_PROJECTS に本 project の entry が入り、orchestrator の federation-read が本台帳へ届く。
## provenance
scribe:setup 新規導入 run・編入判断 step（orch-rafl 裁定 論点6(3) intent 路）・人間 yes 裁定。"
bd update <id> --add-label needs-orch
```
冪等ガード（ブロック先頭の `bd search`）が SKIP を出したら notes/label へ進まない。orchestrator は `needs-orch`
ラベル（完全一致）を pull で拾う——新規台帳はまだ federation-read の対象外だが、backstop の disk-scan が台帳自体を
surface するため取りこぼさない（intent 路と backstop の対）。並列 worker が稼働する環境では bd write を bdw 経由に
する（PRIME §並列 spawn）——新規導入直後は通常 solo ゆえ素の bd で可。

**no → 起票しない**。判断根拠（dormant・個人実験・観測不要等）を Step 末の要約報告へ 1 行残す（orch 側 backstop が
差分を surface した際の一次資料になる）。恒久除外の管理は orchestrator 側の「確認済み除外 list」が担う＝本 skill は
書かない。

## Step 末: 同期＋検証＋コミット
```bash
bd dolt push          # remote 設定済みなら
bd ready              # 動作確認
grep -L 'BEGIN BEADS INTEGRATION' CLAUDE.md AGENTS.md   # 汚染が消えたか
# 二重発火是正の確認（#7）: project-local settings.json に bd prime hook が残っていないか fail-loud 再 grep
# （検出・除去が部分一致 `bd prime` ゆえ、bd ラッパ形 `... && bd prime || true` も剥がれているはず）
test -f .claude/settings.json && grep -q 'bd prime' .claude/settings.json && echo "⚠ #7 未是正（settings.json に bd prime hook 残存）" || echo "二重発火なし（#7）✅"
# scribe opt-in 成立の確認（#10）: PRIME が role 中立版（marker v:N≥1 か role 中立 sentinel。本文フレーズに依存しない）
_pv=$(grep -oE 'beads-init-template v:[0-9]+' .beads/PRIME.md 2>/dev/null | head -1 | grep -oE '[0-9]+$')
test -d .beads && test -f .beads/PRIME.md && { if [ -n "$_pv" ]; then [ "$_pv" -ge 1 ]; else grep -q '本 PRIME は role 中立' .beads/PRIME.md; fi; } && echo "scribe opt-in: role 中立 PRIME ✅" || echo "⚠ PRIME 未同期（marker 旧/無し）"
git status --short
```
変更を**標準 git ワークフロー**でコミット（`main` 直 push 禁止のプロジェクトは feature branch → PR）。最後に「何を skip し何を修正/追加したか」を要約報告。新規導入 run では **DEFAULT_PROJECTS 編入判断の結果**（依頼起票 `<id>` / 見送り+根拠 / 保留）も 1 行含める。

## 禁止事項（MUST NOT）
- `--skip-agents` 省略の `bd init`（汚染・二重発火）。
- 既存 `.beads/` への `bd init --force`/`--reinit-local`/`--destroy-token`（guard がブロック、データ消失）。
- 既存の「正しい」次元への不要な再書き込み（冪等性を壊す）。
- `bd remember`/`bd recall`/`bd memories` の使用、v1.0.5+ の導入。

## 注意
- グローバル hook（SessionStart `bd prime` / SessionEnd 自動 push / 破壊的 bd guard）は machine 全体で有効。本スキルは**プロジェクト側**のみ収束させる。
- **役割を帯びた規約本文の SSOT は scribe plugin**（`docs/protocol.md` / `docs/role-context-spec.md`）。本 skill は bd 基礎の収束と PRIME の role 中立同期までを担い、role 別の振る舞いは scribe の SessionStart 注入に委ねる。
- **sandbox host 依存は本 skill の対象外**（リポ状態でなく host 状態ゆえ）: worker spawn は既定で OS sandbox 化される（default-on・opt-out=`SCRIBE_SANDBOX=0`・sc-u53）ため、その host には `bubblewrap`/`socat`/`jq` と userns 許可（multi-user は bwrap への標的 apparmor profile が安全・単一ユーザーは sysctl 緩和）が要る。未充足だと最初の worker spawn が worktree 作成前に fail-loud で止まる。`scripts/scribe-sandbox-preflight.sh`（充足 exit 0）で事前確認し、導入手順は `scripts/sandbox-spike/README.md`。

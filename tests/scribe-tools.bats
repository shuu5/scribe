#!/usr/bin/env bats
# scribe 道具（spawn ヘルパー / gate 支援 / cleanup）の dry-run arg-echo を検証する。
# **実 spawn・実 tmux・実 claude 起動はしない**（dry-run + bd スタブのみ・コスト大ゆえ）。
# 道具がコード化する規約の SSOT = docs/protocol.md。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  GATE="$SCRIPTS/scribe-gate-args.sh"
  SELFTEST="$SCRIPTS/scribe-selftest-args.sh"
  CLEANUP="$SCRIPTS/scribe-cleanup.sh"
  GUARD="$SCRIPTS/scribe-origin-guard.sh"
  LIB="$SCRIPTS/lib/scribe-lib.sh"
  BDW="$SCRIPTS/bdw"
  HOOKS="$SCRIPTS/hooks"
  HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
  # bd を実在検証スタブへ差し替え（実 graph 不要）。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm un-consult un-3sh.3.5"
  # cld-spawn は dry-run では実行されない。echo を決定論化するため固定値を入れる。
  export SCRIBE_CLD_SPAWN="cld-spawn"
  # grill-consult は grill-me SKILL.md を verbatim 注入する（sc-swc・mechanism b）。テストは hermetic に
  # するためホストの実 skill でなく fixture stub を読ませる（注入の機構＝sentinel が焼かれるかを検証）。
  export SCRIBE_GRILL_SKILL="$FIXTURES/grill-me-stub.md"
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true
  # 既定 REPO/ANCHOR は cwd。テストの cwd が linked worktree（このリポ自身の .worktrees/ 配下で
  # 走らせた場合など）だと un-ag7 ガードが発火して既定パスのテストを汚す。cwd を安定した
  # main worktree（temp git repo）に固定し、テスト実行場所（main/linked のいずれか）に依存させない。
  SCRIBE_TEST_CWD="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$SCRIBE_TEST_CWD" -c init.defaultBranch=main init -q
  git -C "$SCRIBE_TEST_CWD" config user.email t@e; git -C "$SCRIBE_TEST_CWD" config user.name t
  git -C "$SCRIBE_TEST_CWD" commit -q --allow-empty -m init
  cd "$SCRIBE_TEST_CWD"
}

teardown() {
  [[ -n "${SCRIBE_TEST_CWD:-}" ]] && rm -rf "$SCRIBE_TEST_CWD"
  return 0
}

# テスト用に main worktree（temp git repo）+ linked worktree を 1 組作る。
# stdout に "<main>\t<linked>" を返す（呼び出し側で cut して使う）。
_mk_main_and_linked() {
  local main linked
  main="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$main" -c init.defaultBranch=main init -q
  git -C "$main" config user.email t@e; git -C "$main" config user.name t
  git -C "$main" commit -q --allow-empty -m init
  linked="$main/.worktrees/spawn/un-4nm-101010"
  git -C "$main" worktree add -q -b spawn/un-4nm-101010 "$linked" >/dev/null
  printf '%s\t%s\n' "$main" "$linked"
}

# ---------- bash -n（全 script 構文）----------
@test "bash -n: 全 script が構文 OK" {
  for f in "$SPAWN" "$GATE" "$SELFTEST" "$CLEANUP" "$GUARD" "$BDW" "$SCRIPTS/lib/scribe-lib.sh"; do
    run bash -n "$f"
    [ "$status" -eq 0 ]
  done
}

# ---------- spawn: fail-loud ----------
@test "spawn: 実在しない bd id で fail-loud（exit 非 0・spawn コマンド列を出さない）" {
  run "$SPAWN" --dry-run un-nope
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  [[ "$output" != *"--bd-id"* ]]
}

@test "spawn: 形式不正な bd id（path traversal）で fail-loud" {
  run "$SPAWN" --dry-run "../evil"
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  [[ "$output" != *"--bd-id"* ]]
}

@test "spawn: bd id 引数なしで fail-loud" {
  run "$SPAWN" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" != *"--bd-id"* ]]
}

# ---------- spawn: 正常系 dry-run ----------
@test "spawn: dry-run の arg-echo に --bd-id / --model opus / spawn/<id>- / window ID @N が含まれる" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"--bd-id un-4nm"* ]]
  [[ "$output" == *"--model opus"* ]]
  [[ "$output" == *"spawn/un-4nm-"* ]]
  [[ "$output" == *"@N"* ]]
  [[ "$output" == *"window_id"* ]]
}

@test "spawn: window 名は wt-<id>・worktree は .worktrees/ 配下" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt-un-4nm"* ]]
  [[ "$output" == *"/.worktrees/spawn/un-4nm-"* ]]
}

@test "spawn: dotted 階層 id（un-3sh.3.5）も命名規約どおり通る" {
  run "$SPAWN" --dry-run un-3sh.3.5
  [ "$status" -eq 0 ]
  [[ "$output" == *"--bd-id un-3sh.3.5"* ]]
  [[ "$output" == *"spawn/un-3sh.3.5-"* ]]
}

# ---------- spawn: sandbox opt-in（SCRIBE_SANDBOX=1・sc-1gu）----------
@test "spawn(sandbox): gen-sandbox-settings.sh は failIfUnavailable + .beads先頭 allowWrite の valid JSON を出す" {
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$SCRIBE_TEST_CWD"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sandbox.enabled==true and .sandbox.failIfUnavailable==true and .sandbox.allowUnsandboxedCommands==false' >/dev/null
  echo "$output" | jq -e '(.sandbox.filesystem.allowWrite|length)==2 and (.sandbox.filesystem.allowWrite[0]|endswith("/.beads"))' >/dev/null
}

@test "spawn(sandbox): SCRIBE_SANDBOX=1 の worker dry-run は settings.local.json 生成を plan に出す（spawn 行は不変）" {
  SCRIBE_SANDBOX=1 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.local.json"* ]]
  [[ "$output" == *"SCRIBE_SANDBOX"* ]]
  [[ "$output" == *"--bd-id un-4nm"* ]]      # 本番 spawn 行は SCRIBE_SANDBOX で変わらない
  [[ "$output" == *"--model opus"* ]]
}

@test "spawn(sandbox): SCRIBE_SANDBOX 未指定なら sandbox 節を一切出さない（opt-in gating・本番 byte 不変の核）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"settings.local.json"* ]]
  [[ "$output" == *"--bd-id un-4nm"* ]]
  [[ "$output" == *"--model opus"* ]]
}

@test "spawn(sandbox): SCRIBE_SANDBOX 有無で cld-spawn の spawn 行は byte 同一（substring でなく full-line で pin）" {
  # worktree タイムスタンプ(spawn/un-4nm-HHMMSS)だけ正規化し、spawn 行の完全一致を直接 assert する。
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  plain="$(printf '%s\n' "$output" | grep -F 'cld-spawn --cd' | sed -E 's#un-4nm-[0-9]+#un-4nm-TS#')"
  SCRIBE_SANDBOX=1 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  sb="$(printf '%s\n' "$output" | grep -F 'cld-spawn --cd' | sed -E 's#un-4nm-[0-9]+#un-4nm-TS#')"
  [ -n "$plain" ]
  [ "$plain" == "$sb" ]   # SCRIBE_SANDBOX で spawn 行は 1 byte も変わらない
}

# ---------- sandbox-spike 'spike' 文言の本番ヘルパー手当て（sc-2m0 facet3・案C軽量）----------
# 実害: 'spike' 語が **本番ヘルパー** gen-sandbox-settings.sh（scribe-spawn.sh の SCRIBE_SANDBOX=1
# opt-in が起動）を experimental と誤認させる可読性問題。ディレクトリ scripts/sandbox-spike/ は
# 据え置き（path 追従なし）。本番ヘルパーの自己記述（gen ヘッダ）と README 見出しが「本番」と読める
# ことを pin（旧 'sandbox spike:' 框組が消えたことも）。weak のままだと RED / 手当て後に GREEN。
@test "sandbox(facet3): 本番ヘルパー gen-sandbox-settings.sh のヘッダが experimental 'spike' でなく本番と読める" {
  run head -3 "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"本番"* ]]
  [[ "$output" != *"sandbox spike:"* ]]
}

@test "sandbox(facet3): README 見出しが本番ヘルパーを含意する（experimental spike 単独框組でない）" {
  run head -1 "$SCRIPTS/sandbox-spike/README.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"本番"* ]]
}

# ---------- spawn: consult モード ----------
@test "spawn: consult モードで SCRIBE_ROLE=consult が env-file に焼き込まれる" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_ROLE=consult"* ]]
  [[ "$output" == *"--env-file"* ]]
}

@test "spawn: consult の env-file は anchor working tree 外（/tmp・mktemp）で anchor リポを汚さない" {
  # 実在する anchor（repo root）を明示し、その配下に .scribe-consult.env を作る計画が出ないことを assert。
  run "$SPAWN" --dry-run --consult --anchor "$REPO_ROOT" un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"mktemp /tmp/scribe-consult-"* ]]
  # anchor 直下の .scribe-consult.env を生成する計画は出してはならない（anchor リポ汚染防御）。
  [[ "$output" != *"$REPO_ROOT/.scribe-consult.env"* ]]
  [[ "$output" != *".scribe-consult.env"* ]]
  # spawn 後に rm して anchor/外部にも残さない計画が出る。
  [[ "$output" == *"rm -f"* ]]
}

@test "spawn: consult は worktree も worker prompt も出さない（role-context-spec §2.3 契約）" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  # consult は anchor 同居・read-only。worktree spawn は design §14 で禁止。
  [[ "$output" != *"worktree add"* ]]
  # cld-spawn 起動行に --bd-id を渡さない（説明文中の言及や anchor パスは無視し、起動行だけを検査）。
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  [[ "$cld_line" != *"--bd-id"* ]]
  # worker prompt（実装/bdw/cell-quality/selftest）は consult に同居させない。
  [[ "$output" != *"end-to-end で完遂"* ]]
  [[ "$output" != *"bdw"* ]]
  [[ "$output" != *"cell-quality"* ]]
  [[ "$output" != *"selftest-"* ]]
  # consult テンプレの肝（read-only 規律・記憶系のみ write）は出る。
  [[ "$output" == *"設計議論"* ]]
  [[ "$output" == *"read-only"* ]]
}

@test "spawn: consult は bd id 省略でも起動できる（議題参照は任意）" {
  run "$SPAWN" --dry-run --consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_ROLE=consult"* ]]
  # cld-spawn 起動行に --bd-id を渡さない。
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  [[ "$cld_line" != *"--bd-id"* ]]
}

@test "spawn: consult で存在しない議題 id は fail-loud" {
  run "$SPAWN" --dry-run --consult un-nope
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn: consult は cld-spawn に --window-name consult-HHMMSS と --force-new を渡す（reuse 偽成功防止・un-01h gate）" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  # window 名は consult-<6 桁時刻>（固定 `consult` は cld-spawn の完全一致 reuse で偽成功 fail-open する）。
  re='--window-name consult-[0-9]{6}'
  [[ "$cld_line" =~ $re ]]
  # reuse 経路を構造的に封鎖（必ず新セッションを立てる）。
  [[ "$cld_line" == *"--force-new"* ]]
  # window 名を持ち込んでも --bd-id は依然渡さない（consult 設計）。
  [[ "$cld_line" != *"--bd-id"* ]]
}

@test "spawn: consult は bd id 省略でも --window-name consult-HHMMSS と --force-new を渡す" {
  run "$SPAWN" --dry-run --consult
  [ "$status" -eq 0 ]
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  re='--window-name consult-[0-9]{6}'
  [[ "$cld_line" =~ $re ]]
  [[ "$cld_line" == *"--force-new"* ]]
}

@test "spawn: worker（非 consult）は consult window 名も --force-new も持ち込まない（wt-<id> 命名規約を保つ）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"--window-name consult"* ]]
  [[ "$output" != *"--force-new"* ]]
}

@test "spawn: 非 consult では env-file を注入しない" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCRIBE_ROLE=consult"* ]]
  [[ "$output" != *"--env-file"* ]]
}

# ---------- spawn: 防御 ----------
@test "spawn: 未知オプションを拒否する（cld-spawn の PROMPT 落下バグ防御・un-ivb）" {
  run "$SPAWN" --dry-run --bogus-opt un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn: worker は --model fable 系を拒否する（worker は opus 必須・protocol.md §1）" {
  run "$SPAWN" --dry-run --model claude-fable-5 un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  # case-insensitive: 大文字混在（CLAUDE-FABLE-5 等）も取りこぼさず die する。
  run "$SPAWN" --dry-run --model CLAUDE-FABLE-5 un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn: consult は --model fable を許容する（role-context-spec §2.3 の例外・worker との非対称）" {
  # consult は admin と同じ main-loop 系統ゆえ fable 起動が許される唯一の例外。
  # 同じ fable 指定でも worker（上テスト）は die・consult は通る＝道具が規約を変えない証拠。
  run "$SPAWN" --dry-run --consult --model claude-fable-5 un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_ROLE=consult"* ]]
  [[ "$output" == *"--model claude-fable-5"* ]]
}

@test "spawn: prompt テンプレに cell-quality WF / receivedArgs / bdw / 禁止が含まれる" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"cell-quality"* ]]
  [[ "$output" == *"receivedArgs"* ]]
  [[ "$output" == *"bdw"* ]]
  [[ "$output" == *"bd create"* ]]
}

# ---------- spawn: grill-consult モード（--context・§7 needs-user regime・sc-cuw 再編）----------
# --context は「焼いて死ぬ pre-bake」から「admin 集約 brief を grill 材料に受け取りユーザーと対話 grill する
# grill-consult」へ意味が変わった。pre-bake 自体は admin が回す dynamic Workflow へ移管(consult から撤去)。
@test "spawn(grill-consult): --context + grill-issue で brief 焼き込み + bd notes handoff(bdw 経由)が prompt に注入される" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'ADMIN_BRIEF_SENTINEL\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # admin 集約 brief が grill 材料として焼き込まれる。
  [[ "$output" == *"ADMIN_BRIEF_SENTINEL"* ]]
  # grill-consult はユーザーと対話 grill する第 2 対話相手(原義回帰)。
  [[ "$output" == *"grill-consult"* ]]
  [[ "$output" == *"対話 grill"* ]]
  [[ "$output" == *"grill-issue=un-consult"* ]]
  # 決定 handoff = own grill-issue の bd notes(bdw 経由 --claim/--append-notes のみ)。
  [[ "$output" == *"bdw"* ]]
  [[ "$output" == *"--claim"* ]]
  [[ "$output" == *"--append-notes"* ]]
  [[ "$output" == *"bd show un-consult"* ]]   # admin が real-time 監視
  [[ "$output" == *"限定緩和"* ]]
  # 旧 doobidoo handoff regime(tag/conversation_id)は撤去された(brief は WF 返り値・handoff は bd notes)。
  [[ "$output" != *"scribe-brief-"* ]]
  [[ "$output" != *"conversation_id"* ]]
}

@test "spawn(grill-consult): read-only 限定緩和は厳密 — 自 grill-issue notes のみ可・graph 構造と tracked コードは不可" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # 緩和されるのは自 grill-issue の --claim / --append-notes だけ(bdw 経由・read-only 限定緩和)。
  [[ "$output" == *"--append-notes"* ]]
  [[ "$output" == *"限定緩和"* ]]
  # graph 構造(create/dep/close/dolt push)は依然禁止(slim prompt の handoff 禁止節で明示)。
  [[ "$output" == *"bd create/dep/close/dolt push"* ]]
  # tracked コード編集も不可(read-only=admin の領分)。
  [[ "$output" == *"tracked コード"* ]]
}

# sc-swc: grill-consult は grill-me を自前 paraphrase せず SKILL.md を verbatim 注入する(mechanism b)。
# 旧 grill-consult は grill-me を言い換え load-bearing ルール(ポップアップ禁止・1論点1問)を落としていた
# (dogfood で露呈)。注入の機構を fixture stub の sentinel で hermetic に検証する。
@test "spawn(grill-consult): grill-me SKILL.md を verbatim 注入する(paraphrase でなく本文・sc-swc)" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # fixture stub の sentinel が prompt に現れる = $SCRIBE_GRILL_SKILL を verbatim 焼いている。
  [[ "$output" == *"GRILL_ME_VERBATIM_SENTINEL"* ]]
  # grill-me の load-bearing ルール(paraphrase では落ちていた)が本文として入る。
  [[ "$output" == *"AskUserQuestion"* ]]
  [[ "$output" == *"1 論点 1 質問"* ]]
  [[ "$output" == *"全体地図"* ]]
  # 自前 paraphrase に委ねず「スキル本文に厳密に従う」と指示する。
  [[ "$output" == *"grill-me スキル本文"* ]]
}

@test "spawn(grill-consult): grill-me SKILL.md 不在は fail-loud(grill-me 本文無しで grill-consult を spawn しない・sc-swc)" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  export SCRIBE_GRILL_SKILL=/tmp/scribe-no-such-grill-skill.md
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SKILL.md"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): F2 は構造解消 — 第三者データ出典は保険として残り旧 pre-bake 専任文言は消える" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # F2 保険: brief は WF の提案=第三者データ。
  [[ "$output" == *"第三者データ"* ]]
  # 新設計では consult が grill 相手(原義回帰)。旧 regime の「pre-bake 専任」「対話 grill に入らない」は消える。
  [[ "$output" != *"pre-bake 専任"* ]]
  [[ "$output" != *"対話 grill に入らない"* ]]
  # 旧 doobidoo F3 リトライ規律(保存成功を終了条件)は撤去(handoff は bd notes ゆえ doobidoo 保存しない)。
  [[ "$output" != *"保存成功を終了条件"* ]]
}

@test "spawn(grill-consult): --context は worker モードでは consult 専用 die(worker は grill-consult しない)" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --context "$ctx" un-4nm
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"consult"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): --context は grill-issue id 必須で fail-loud(handoff 先の bd notes を定められない)" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx"
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"grill-issue"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): --context のファイルが不在だと fail-loud(typo を上流で塞ぐ)" {
  run "$SPAWN" --dry-run --consult --context /tmp/scribe-no-such-ctx-file.md un-consult
  [ "$status" -ne 0 ]
  [[ "$output" == *"通常ファイル"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): --context にディレクトリを渡すと fail-loud(空 brief のまま起動する fail-safe ギャップ防御・review wf_a92a624f)" {
  dir="$(mktemp -d /tmp/scribe-ctx-dir-XXXXXX)"
  run "$SPAWN" --dry-run --consult --context "$dir" un-consult
  rmdir "$dir"
  # -r 単体ならディレクトリは truthy で通過してしまう。-f で弾けていることを確認。
  [ "$status" -ne 0 ]
  [[ "$output" == *"通常ファイル"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): --context 無しの素 consult は grill-consult 節を一切出さない(回帰防御)" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  # 素 consult(設計議論・grill の read-only)は grill-consult 任務・bd notes handoff を持たない。
  [[ "$output" != *"grill-consult"* ]]
  [[ "$output" != *"--append-notes"* ]]
  [[ "$output" != *"第三者データ"* ]]
  [[ "$output" != *"bdw"* ]]
  [[ "$output" != *"scribe-brief-"* ]]
}

# ---------- spawn: 共有 .git/config mutate 禁止（un-1n1 ①）----------
@test "spawn(un-1n1): worker prompt の禁止節に共有 .git/config mutate 禁止 + 正しい代替(throwaway)が入る" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  # 禁止本文（共有 .git/config の mutate 禁止）。
  [[ "$output" == *".git/config"* ]]
  [[ "$output" == *"mutate しない"* ]]
  # 正しい代替手段は throwaway bare repo / 別 clone（remote 検証用）。
  [[ "$output" == *"throwaway"* ]]
  [[ "$output" == *"un-6nf"* ]]
  # git config --worktree は remote.* には効かないことを明記（誤誘導を避ける・un-1n1 gate finding）。
  [[ "$output" == *"git config --worktree"* && "$output" == *"隔離できない"* ]]
}

# ---------- spawn: origin 健全性 marker 捕捉の plan 行（un-1n1 ③）----------
@test "spawn(un-1n1): dry-run plan に origin 捕捉ステップ（scribe_capture_origin）が worktree add の後に出る" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"scribe_capture_origin"* ]]
  # worktree add → capture の順序（capture は worktree 生成後でないと marker を置けない）。
  add_ln="$(echo "$output" | grep -n 'worktree add' | head -1 | cut -d: -f1)"
  cap_ln="$(echo "$output" | grep -n 'scribe_capture_origin' | head -1 | cut -d: -f1)"
  [ -n "$add_ln" ] && [ -n "$cap_ln" ] && [ "$cap_ln" -gt "$add_ln" ]
}

# ---------- spawn: cld-spawn 失敗時の orphan worktree 案内（sc-vuu facet3・failure injection 初導入）----------
# 実モード spawn（dry-run でない）で cld-spawn を失敗 stub に差し替える初の failure-injection。
# 自動 rollback はしない（破壊操作ポリシー: force 禁止・確認必須＝自動削除の例外を作らない）。
# orphan worktree を残し、stderr に orphan path + scribe-cleanup.sh 復旧コマンドを明示して非0 終了する。
@test "spawn(facet3): cld-spawn 失敗時は worktree を自動削除せず orphan を残し stderr 掃除案内+非0" {
  local repo wt fail_stub
  repo="$SCRIBE_TEST_CWD"   # setup() の temp git repo（init コミット済み）
  fail_stub="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 7\n' > "$fail_stub"; chmod +x "$fail_stub"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env SCRIBE_CLD_SPAWN="$fail_stub" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$fail_stub"
  # cld-spawn の exit code（7）を上流へ伝える（fail-loud）。
  [ "$status" -eq 7 ]
  # worktree は自動削除されず orphan として残る（自動 rollback しない）。
  [ -d "$wt" ]
  # stderr に orphan path + scribe-cleanup.sh 復旧コマンドが出る（path + 復旧コマンド付き明示）。
  [[ "$output" == *"orphan"* ]]
  [[ "$output" == *"$wt"* ]]
  [[ "$output" == *"scribe-cleanup.sh"* ]]
  # happy-path 由来の "spawned:" 行は出ない（失敗経路）。
  [[ "$output" != *"spawned: issue=un-4nm"* ]]
  # 後片付け（テスト自身は force 可・本番ポリシーとは別物）。
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------- spawn(sandbox materialization): SCRIBE_SANDBOX=1 実経路の物理生成（sc-s68）----------
# 上の sandbox テスト(108-165)は dry-run plan と gen 単体 JSON を pin するが、実(非dry-run)経路の
# *物理 materialization*（settings.local.json の atomic 生成・temp 後始末・worker 巻添え防止の
# exclude 追記・gen 失敗時の die+temp 掃除）は未検証だった。mv→cp 退化や exclude 破損で
# settings.local.json が worker commit に漏れても検出できない（README が ephemeral 維持を不変条件と明記）。
# facet3(上記) と同じく cld-spawn を no-op stub に差し替えて実 spawn を駆動し、生成物を assert する。
@test "spawn(sandbox/sc-s68): SCRIBE_SANDBOX=1 実経路で settings.local.json を atomic 生成・temp 残無・worker 巻添え防止" {
  local repo wt noop
  repo="$SCRIBE_TEST_CWD"   # setup() の temp git repo（init コミット済み）
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$noop"
  [ "$status" -eq 0 ]
  # 物理生成された settings.local.json は valid JSON で sandbox contract（failIfUnavailable + .beads 先頭）を持つ。
  [ -f "$wt/.claude/settings.local.json" ]
  run jq -e '.sandbox.enabled == true and .sandbox.failIfUnavailable == true and (.sandbox.filesystem.allowWrite[0] | endswith("/.beads"))' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  # atomic mv 後に temp ファイル(.settings.XXXXXX)が残っていない（mv→cp 退化を捕捉）。
  run bash -c "ls \"$wt/.claude/\".settings.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  # worktree の git exclude 追記で worker の git add -A が settings.local.json を巻き込まない（ephemeral 維持・load-bearing）。
  run git -C "$wt" check-ignore -q .claude/settings.local.json
  [ "$status" -eq 0 ]
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

@test "spawn(sandbox/sc-s68): gen 失敗時は die（非0）し settings.local.json を残さず temp も後始末する" {
  local repo wt noop genfail
  repo="$SCRIBE_TEST_CWD"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  # SCRIBE_SANDBOX_GEN(=CLD_SPAWN と同型 seam)で gen を失敗 stub に差し替え、spawn の die+temp掃除枝を駆動。
  genfail="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 5\n' > "$genfail"; chmod +x "$genfail"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_SANDBOX_GEN="$genfail" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$noop" "$genfail"
  # gen 失敗 → scribe_die で非0 終了（cld-spawn 到達前）・理由を stderr に明示。
  [ "$status" -ne 0 ]
  [[ "$output" == *"settings.local.json の生成に失敗"* ]]
  # 半端な settings.local.json を残さない・temp も掃除済み（gen 失敗で worker commit へ漏らさない）。
  [ ! -f "$wt/.claude/settings.local.json" ]
  run bash -c "ls \"$wt/.claude/\".settings.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------- spawn: worker prompt に anchor 絶対パスを焼き込む（un-gjr）----------
# anchor は worker 実行コマンド（cd "$ANCHOR" && bd show / bdw）へ補間されるため、空白を含む
# パスでも 1 引数に収まるよう **ダブルクォート付き**で焼き込む（quote 漏れは空白 anchor で cd 破綻）。
@test "spawn: worker prompt の契約参照行に anchor 絶対パス付き bd show が焼き込まれる（un-gjr）" {
  run "$SPAWN" --dry-run --anchor "$REPO_ROOT" un-4nm
  [ "$status" -eq 0 ]
  # 契約参照: anchor へ cd してから bd show（worktree からは bd graph が解決しないため）。クォート付き。
  [[ "$output" == *"cd \"$REPO_ROOT\" && bd show un-4nm"* ]]
  # 旧プレースホルダ（裸の `bd show <id>`・cd なし）に退行していない。
  [[ "$output" != *"description: \`bd show un-4nm\`"* ]]
}

@test "spawn: worker prompt の bdw 規律行が <anchor> プレースホルダでなく絶対パスになる（un-gjr）" {
  run "$SPAWN" --dry-run --anchor "$REPO_ROOT" un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd \"$REPO_ROOT\" && scripts/bdw"* ]]
  # 旧プレースホルダ `cd <anchor>` が残っていない（リグレッション防止）。
  [[ "$output" != *"cd <anchor>"* ]]
}

@test "spawn: 相対 --anchor も絶対パスへ正規化して焼き込む（worker の cwd は worktree・un-gjr）" {
  # REPO_ROOT を親ディレクトリからの相対パスで渡す → prompt には絶対パスが出る。
  parent="$(dirname "$REPO_ROOT")"
  rel="$(basename "$REPO_ROOT")"
  run bash -c "cd '$parent' && '$SPAWN' --dry-run --anchor '$rel' un-4nm"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cd \"$REPO_ROOT\" && bd show un-4nm"* ]]
  [[ "$output" == *"cd \"$REPO_ROOT\" && scripts/bdw"* ]]
  # 相対パスのまま焼き込んでいない（worker から解決できない）。
  [[ "$output" != *"cd \"$rel\" && bd show"* ]]
}

@test "spawn: 空白を含む --anchor でも cd が 1 引数に収まる（クォート焼き込み・un-gjr gate finding）" {
  spacedir="$(mktemp -d)/sp ace"
  mkdir -p "$spacedir"
  run "$SPAWN" --dry-run --anchor "$spacedir" un-4nm
  rm -rf "$(dirname "$spacedir")"
  [ "$status" -eq 0 ]
  # 空白入り anchor がダブルクォートされ、worker の cd が単一引数を受け取る。
  [[ "$output" == *"cd \"$spacedir\" && bd show un-4nm"* ]]
  [[ "$output" == *"cd \"$spacedir\" && scripts/bdw"* ]]
  # 未クォート（cd /…/sp ace && …）に退行していない＝空白で cd が 2 引数化しない。
  [[ "$output" != *"cd $spacedir && bd show"* ]]
}

@test "spawn: 存在しない --anchor は fail-loud（絶対パス解決不能を上流で塞ぐ・un-gjr）" {
  run "$SPAWN" --dry-run --anchor /no/such/anchor/dir un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
}

# ---------- spawn: anchor/repo 誤認ガード（un-ag7）----------
# 既定 REPO/ANCHOR（= cwd）が linked（副）worktree のとき fail-loud。検出は git plumbing
# （scribe_owning_repo の porcelain 先頭=main と show-toplevel の差分）— naming 規約には依存しない。

@test "spawn(un-ag7): scribe_linked_worktree_main は linked で main を返し main/非worktree で空+非0" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  # linked worktree → 所属 main を返す（exit 0）
  run bash -c 'source "$1"; scribe_linked_worktree_main "$2"' _ "$LIB" "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == "$main" ]]
  # main worktree 自身 → 空 + 非0（show-toplevel == main）
  run bash -c 'source "$1"; scribe_linked_worktree_main "$2"' _ "$LIB" "$main"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # 非 git/非 worktree → 空 + 非0
  nongit="$(mktemp -d)"
  run bash -c 'source "$1"; scribe_linked_worktree_main "$2"' _ "$LIB" "$nongit"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  rm -rf "$nongit"
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

# 検出が naming でなく git plumbing である証拠: 継承 GIT_DIR/GIT_WORK_TREE を別リポへ leak させても
# 当該 worktree の所属 main を返す（env -u 隔離が効く）。session-start-role-inject と同系の leak modality。
@test "spawn(un-ag7): scribe_linked_worktree_main は継承 GIT_DIR/GIT_WORK_TREE から隔離する（AC4）" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  poison="$(mktemp -d)"
  git -C "$poison" -c init.defaultBranch=main init -q
  git -C "$poison" config user.email t@e; git -C "$poison" config user.name t
  git -C "$poison" commit -q --allow-empty -m init
  run bash -c '
    source "$1"
    export GIT_DIR="$2/.git" GIT_WORK_TREE="$2"
    scribe_linked_worktree_main "$3"
  ' _ "$LIB" "$poison" "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == "$main" ]]
  [[ "$output" != *"$poison"* ]]
  rm -rf "$poison"
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "spawn(un-ag7): 既定 REPO/ANCHOR を linked worktree から実行→非0+真の anchor 案内（AC1/AC5）" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  run bash -c 'cd "$1" && "$2" --dry-run un-4nm' _ "$linked" "$SPAWN"
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]            # plan を出す前に止まる（AC5）
  [[ "$output" == *"linked worktree"* ]]   # 検出を明示
  [[ "$output" == *"$main"* ]]             # 真の main worktree を案内
  # AC6: ガード発火で worktree add(=ネスト・誤 base 経路)に到達しない＝副 worktree 配下に
  # .worktrees/spawn/... が物理的に作られないことを直接確認（2026-06-12 実害の transitive 阻止）。
  [ ! -e "$linked/.worktrees" ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "spawn(un-ag7): consult も既定 anchor が linked worktree なら fail-loud（AC1 両モード）" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  run bash -c 'cd "$1" && "$2" --dry-run --consult un-consult' _ "$linked" "$SPAWN"
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  [[ "$output" == *"linked worktree"* ]]
  [[ "$output" == *"$main"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "spawn(un-ag7): --repo/--anchor 明示なら linked worktree から実行してもガード不発火（AC3）" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  # 明示 main を anchor/repo に指定（cross-repo / 意図的 override の許可）。
  run bash -c 'cd "$1" && "$2" --dry-run --repo "$3" --anchor "$3" un-4nm' _ "$linked" "$SPAWN" "$main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[plan]"* ]]            # plan まで到達する
  [[ "$output" != *"linked worktree"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "spawn(un-ag7): --anchor 明示でも --repo 既定が linked worktree なら REPO ガード発火（AC4 独立判定）" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  # anchor は明示 main（ANCHOR ガード不発火）だが、repo は既定 cwd=linked → REPO ガードが止める。
  run bash -c 'cd "$1" && "$2" --dry-run --anchor "$3" un-4nm' _ "$linked" "$SPAWN" "$main"
  [ "$status" -ne 0 ]
  [[ "$output" != *"[plan]"* ]]
  [[ "$output" == *"linked worktree"* ]]
  [[ "$output" == *"$main"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "spawn(un-ag7): 通常 main worktree から既定実行→ガード不発火（偽陽性なし）" {
  IFS=$'\t' read -r main linked < <(_mk_main_and_linked)
  # linked worktree が存在しても、main から既定実行する限り発火しない。
  run bash -c 'cd "$1" && "$2" --dry-run un-4nm' _ "$main" "$SPAWN"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[plan]"* ]]
  [[ "$output" != *"linked worktree"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

# ---------- gate 支援 ----------
@test "gate-args: 出力 JSON が valid で doImplement:false / autoFix:false / doPlan:false 固定" {
  run "$GATE" --dry-run --worktree /tmp/wt un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doImplement"])')" = "False" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["autoFix"])')" = "False" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doPlan"])')" = "False" ]
}

@test "gate-args: worktree / baseRef / taskTitle / model が JSON に入る" {
  run "$GATE" --dry-run --worktree /tmp/wt --base origin/main un-4nm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree"])')" = "/tmp/wt" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["baseRef"])')" = "origin/main" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')" = "opus" ]
  [[ "$output" == *"un-4nm"* ]]
}

@test "gate-args: --worktree 未指定で fail-loud" {
  run "$GATE" --dry-run un-4nm
  [ "$status" -ne 0 ]
}

@test "gate-args: --model fable 系を拒否する（大文字混在も case-insensitive で die・3兄弟対称・sc-vuu facet4）" {
  run "$GATE" --dry-run --worktree /tmp/wt --model claude-fable-5 un-4nm
  [ "$status" -ne 0 ]
  # case-insensitive: 大文字混在（CLAUDE-FABLE-5 / Fable）も取りこぼさず die する。
  # 旧 case-sensitive `*fable*`（gate-args:65）は Fable/FABLE を見逃す fail-open だった（sc-2m0 派生・sc-vuu facet4）。
  # spawn:325 の `${MODEL,,}` 流へ統一（selftest:111 と 3 兄弟対称化）。
  run "$GATE" --dry-run --worktree /tmp/wt --model CLAUDE-FABLE-5 un-4nm
  [ "$status" -ne 0 ]
  run "$GATE" --dry-run --worktree /tmp/wt --model Fable un-4nm
  [ "$status" -ne 0 ]
}

# ---------- worker 自己点検 支援 (un-3yc / un-aq5) ----------
# gate-args(read-only) と対称の道具だが**責務だけ非対称**: 自己点検は worker 実装済み前提の gated autoFix。
# 非対称点を assert: autoFix=true / doImplement=doPlan=false / --self-test 必須 / --model fable 拒否 /
# --max-concurrency 既定4 / dimensions 既定なし(WF が必須4補完)。dry-run + bd スタブのみ（実 spawn しない）。
@test "selftest-args: 出力 JSON が valid で autoFix:true / doImplement:false / doPlan:false 固定（gate と非対称）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["autoFix"])')" = "True" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doImplement"])')" = "False" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["doPlan"])')" = "False" ]
}

@test "selftest-args: worktree / baseRef / selfTestCmd / model / maxConcurrency が JSON に入る（既定 model=opus・maxConcurrency=4）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --base origin/main --self-test 'bats tests/foo.bats' un-4nm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["worktree"])')" = "/tmp/wt" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["baseRef"])')" = "origin/main" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["selfTestCmd"])')" = "bats tests/foo.bats" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["model"])')" = "opus" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["maxConcurrency"])')" = "4" ]
  [[ "$output" == *"un-4nm"* ]]
}

@test "selftest-args: --max-concurrency で上書きでき、非正整数(0/非数)は fail-loud" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --max-concurrency 8 un-4nm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["maxConcurrency"])')" = "8" ]
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --max-concurrency 0 un-4nm
  [ "$status" -ne 0 ]
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --max-concurrency abc un-4nm
  [ "$status" -ne 0 ]
}

@test "selftest-args: dimensions は既定で載らない（WF が必須4補完）／--add-dimension で追加観点が載る" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' un-4nm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print("dimensions" in json.load(sys.stdin))')" = "False" ]
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --add-dimension perf:hotpath un-4nm
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["dimensions"][0]["key"])')" = "perf" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["dimensions"][0]["focus"])')" = "hotpath" ]
}

@test "selftest-args: --add-dimension に必須4観点 key（correctness 等）を渡すと fail-loud" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --add-dimension correctness:foo un-4nm
  [ "$status" -ne 0 ]
}

@test "selftest-args: --worktree 未指定で fail-loud" {
  run "$SELFTEST" --dry-run --self-test 'x' un-4nm
  [ "$status" -ne 0 ]
}

@test "selftest-args: --self-test 未指定で fail-loud（autoFix の fail-closed ゲート必須）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt un-4nm
  [ "$status" -ne 0 ]
}

@test "selftest-args: --self-test の値を省くと次フラグを誤消費せず fail-loud" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test --task-type chore un-4nm
  [ "$status" -ne 0 ]
}

# ---------- 値省略→次フラグ誤消費せず fail-loud（scribe_need_val strict 統一・sc-2m0 facet1）----------
# weak ガード([[ -n "${2:-}" ]])は値を省いて次フラグを書くと次フラグを silent に消費し bogus 値で
# 進む（gate-args 実機再現: `--worktree --base un-4nm` → worktree=--base の bogus JSON を exit 0 で吐く）。
# scribe_need_val は「非空 かつ -始まりでない」を要求し各道具の parse loop を fail-loud に統一する。
# 各テストは weak のままだと RED（exit 0 もしくは別 die で "誤消費" 文言が出ない）/ strict で GREEN。
# selftest-args の鏡像（上記）を gate-args/cleanup/spawn/origin-guard へ 1 本ずつ展開（D4 回帰網）。
@test "gate-args: --worktree の値を省くと次フラグを誤消費せず fail-loud（scribe_need_val）" {
  run "$GATE" --dry-run --worktree --base un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" == *"誤消費"* ]]
}

@test "cleanup: --worktree の値を省くと次フラグを誤消費せず fail-loud（scribe_need_val）" {
  run "$CLEANUP" --dry-run --worktree --branch un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" == *"誤消費"* ]]
}

@test "spawn: --repo の値を省くと次フラグを誤消費せず fail-loud（scribe_need_val）" {
  run "$SPAWN" --dry-run --repo --base un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" == *"誤消費"* ]]
}

@test "origin-guard: --worktree の値を省くと次フラグを誤消費せず fail-loud（scribe_need_val）" {
  run "$GUARD" verify --worktree --repo /tmp/r
  [ "$status" -ne 0 ]
  [[ "$output" == *"誤消費"* ]]
}

@test "selftest-args: --model fable 系を拒否する（worker は opus・protocol.md §1・大文字も die・sc-vuu facet4）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --model claude-fable-5 un-4nm
  [ "$status" -ne 0 ]
  # 3 兄弟対称化（sc-vuu facet4）: 旧 glob `*[Ff][Aa]...` を `${MODEL,,}` 流へ統一しても大文字を取りこぼさない。
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --model CLAUDE-FABLE-5 un-4nm
  [ "$status" -ne 0 ]
}

# ---------- WF 層 fable 降格の回帰（cell-quality.workflow.js・sc-tl3）----------
# ツール層 3 兄弟（spawn/gate-args/selftest-args）の `*fable*` は上で test 済み。WF 層 demoteFable の
# isFable も同じ部分一致 `/fable/i` であること・旧 exact-match 集合 FABLE_ALIASES へ退化していないことを
# source assertion で固定する（exact-match だと claude-fable-5-preview 等を WF 直叩き経路で取りこぼし、
# demoteFable も ≤2 cap も外れる二重 fail-open=sc-tl3）。挙動 unit は repo に node test 機構が無いため
# source-level で層間一致を pin する（~/.claude/workflows は repo workflows/ への symlink=単一実体）。
@test "cell-quality WF: isFable は部分一致 /fable/i で層間一致（exact-match 集合へ退化しない・sc-tl3）" {
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  [ -f "$WF" ]
  # 部分一致判定が在る（ツール層 *fable* / 兄弟 prebake /fable/i と意味一致）。
  grep -Eq 'isFable.*/fable/i' "$WF"
  # 旧 exact-match 集合へ退化していない（派生 fable 名の取りこぼし=二重 fail-open を再発させない）。
  ! grep -q 'FABLE_ALIASES' "$WF"
}

# ---------- DESC 合成の lib 抽出（scribe_synthesize_issue_desc・sc-2m0 facet2）----------
# gate-args / selftest-args で byte 同一だった「issue→taskTitle/description 合成」を lib へ集約（D1）。
# 非 dry-run 経路は従来 bats coverage ゼロ（D0）だったため、本体（lib unit）+ 両 caller 結線 smoke +
# 移植前後の byte 不変 pin を test-first で敷く。NUL 区切り 2 値返却（DESC が最後・D2）・dry-run
# title-suffix・sentinel・scribe_die 早期失敗を関数内に閉じ込めた忠実移植（D4）を各枝で検証する。
@test "lib synth(facet2): 正常取得（TITLE=id・DESC=bd show 本文）" {
  run bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    { IFS= read -r -d "" t && IFS= read -r -d "" d; } < <(scribe_synthesize_issue_desc un-4nm 0 "'"$PWD"'")
    printf "TITLE=[%s]\n" "$t"
    printf "BODY=%s\n" "$([[ "$d" == *"stub description for un-4nm"* ]] && echo yes || echo no)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"TITLE=[un-4nm]"* ]]
  [[ "$output" == *"BODY=yes"* ]]
}

@test "lib synth(facet2): 複数行 DESC が NUL read で改行ごと保たれる" {
  run bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    { IFS= read -r -d "" t && IFS= read -r -d "" d; } < <(scribe_synthesize_issue_desc un-4nm 0 "'"$PWD"'")
    printf "HEAD=[%s]\n" "$(printf "%s" "$d" | sed -n 1p)"
    printf "MULTILINE=%s\n" "$([[ "$d" == *$'"'"'\n'"'"'* ]] && echo yes || echo no)"
    printf "TAIL=%s\n" "$([[ "$d" == *"stub description for un-4nm" ]] && echo yes || echo no)"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"HEAD=[○ un-4nm · stub issue]"* ]]
  [[ "$output" == *"MULTILINE=yes"* ]]
  [[ "$output" == *"TAIL=yes"* ]]
}

@test "lib synth(facet2): 取得不可（exists OK だが本文空）は sentinel へ fallback" {
  run bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    export BD_STUB_EMPTY_IDS="un-4nm"
    { IFS= read -r -d "" t && IFS= read -r -d "" d; } < <(scribe_synthesize_issue_desc un-4nm 0 "'"$PWD"'")
    printf "TITLE=[%s]\nDESC=[%s]\n" "$t" "$d"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"TITLE=[un-4nm]"* ]]
  [[ "$output" == *"DESC=[(bd show 取得不可)]"* ]]
}

@test "lib synth(facet2): dry-run は bd show を踏まず title-suffix + placeholder" {
  run bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    { IFS= read -r -d "" t && IFS= read -r -d "" d; } < <(scribe_synthesize_issue_desc un-4nm 1 "'"$PWD"'")
    printf "TITLE=[%s]\nDESC=[%s]\n" "$t" "$d"
  '
  [ "$status" -eq 0 ]
  [[ "$output" == *"TITLE=[un-4nm (dry-run)]"* ]]
  [[ "$output" == *"DESC=[(dry-run: bd show 省略)]"* ]]
}

@test "lib synth(facet2): 非 dry-run で実在しない id は関数内 scribe_die で早期失敗（fail-loud）" {
  run bash -c '
    set -euo pipefail
    source "'"$LIB"'"
    scribe_synthesize_issue_desc un-nope 0 "'"$PWD"'" >/dev/null
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *"bd issue が存在しません"* ]]
}

@test "gate-args(facet2): 非 dry-run 合成の byte 不変 pin（taskTitle suffix 無し・DESC 末尾 byte 忠実）" {
  run "$GATE" --worktree /tmp/wt --base origin/main --anchor "$PWD" un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["taskTitle"])')" = "un-4nm" ]
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["context"].endswith("○ un-4nm · stub issue\n\nDESCRIPTION\nstub description for un-4nm"))')" = "True" ]
  [[ "$output" != *"bd show 取得不可"* ]]
  [[ "$output" != *"dry-run"* ]]
}

@test "selftest-args(facet2): 非 dry-run の結線 smoke（DESC が context に入る・lib 合成経由）" {
  run "$SELFTEST" --worktree /tmp/wt --self-test 'x' --anchor "$PWD" un-4nm
  [ "$status" -eq 0 ]
  echo "$output" | python3 -m json.tool >/dev/null
  [ "$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["taskTitle"])')" = "un-4nm" ]
  [[ "$output" == *"stub description for un-4nm"* ]]
}

# ---------- cleanup ----------
@test "cleanup: dry-run に禁止操作（branch -D / reset --hard / kill-server）が含まれない" {
  run "$CLEANUP" --dry-run --repo /tmp/repo --worktree /tmp/wt --branch spawn/un-4nm-101010 un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"branch -D"* ]]
  [[ "$output" != *"reset --hard"* ]]
  [[ "$output" != *"kill-server"* ]]
}

@test "cleanup: dry-run は安全操作のみ（branch -d / kill-window / worktree remove）+ window ID @N 参照" {
  run "$CLEANUP" --dry-run --repo /tmp/repo --worktree /tmp/wt --branch spawn/un-4nm-101010 un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"branch -d"* ]]
  [[ "$output" == *"kill-window"* ]]
  [[ "$output" == *"worktree remove"* ]]
  [[ "$output" == *"@N"* ]]
  [[ "$output" == *"window_id"* ]]
}

@test "cleanup: dolt push は自動実行せずリマインドのみ（[plan] 実行行に出さない）" {
  run "$CLEANUP" --dry-run --repo /tmp/repo un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"dolt push"* ]]
  # dolt push を含む行が実行 plan（^[plan]）であってはならない＝checklist リマインドのみ
  ! echo "$output" | grep -E '^\[plan\].*dolt push'
}

@test "cleanup: window 既定は wt-<id>" {
  run "$CLEANUP" --dry-run --repo /tmp/repo un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"wt-un-4nm"* ]]
}

# real モードでの「安全失敗→チェックリスト継続→終了コード非 0」を検証する。
# 非 git ディレクトリを --repo に渡すと step1(worktree remove)/step2(branch -d) が安全失敗する。
# window は存在しない名前を渡して kill を確実に skip させる（実 window を kill しない）。
@test "cleanup: step1 が安全失敗しても後続 step を出力し終了コード非 0（set -e で中断しない）" {
  tmpdir="$(mktemp -d)"   # 非 git ディレクトリ
  run "$CLEANUP" --yes --repo "$tmpdir" --worktree "$tmpdir/nope" \
      --branch "spawn/no-such-$$" --window "wt-no-such-window-$$" un-4nm
  rm -rf "$tmpdir"
  # step1 が失敗しても、後続の window checklist / dolt push リマインドまで歩き切る
  [[ "$output" == *"warn:"* ]]
  [[ "$output" == *"dolt push"* ]]
  # 失敗があったので終了コードは非 0（fail-closed）
  [ "$status" -ne 0 ]
  # force 系は依然 dry-run/real とも出さない
  [[ "$output" != *"branch -D"* ]]
  [[ "$output" != *"kill-server"* ]]
}

# ---------- cleanup: 確認 read EOF を user-N と区別（sc-vuu facet1）----------
# confirm() の read が EOF（非対話/パイプ切れ）に当たったとき、従来は user-N（拒否）と同じ「skip」へ
# 落ち exit 0 で「未確認なのに成功扱い」する fail-open だった。三値化（0=承認/1=拒否/2=EOF）で
# EOF を FAILED 計上→exit 非0 へ倒す（lib の EOF=fail-loud イディオムとの非対称を解消）。
# --yes/--dry-run は先行 return で read 不到達ゆえ不変（tests:824/679 不変）。
@test "cleanup(facet1): 確認入力が EOF（</dev/null・非対話）なら user-N と区別し FAILED 計上+exit 非0" {
  local tmpdir; tmpdir="$(mktemp -d)"   # 非 git でも確認段（read）で EOF に当たるので git コマンドは不到達
  # --yes/--dry-run を付けず stdin を閉じて（</dev/null）confirm の read を EOF に当てる。
  run bash -c '"$1" --repo "$2" --worktree "$2/nope" --branch "spawn/no-such-$$" \
      --window "wt-no-such-window-$$" un-4nm </dev/null' _ "$CLEANUP" "$tmpdir"
  rm -rf "$tmpdir"
  # EOF 専用識別メッセージが出る（user-N の "skip" とは別経路）。
  [[ "$output" == *"EOF"* ]]
  # 確認が EOF＝未確認なので step は実行されない（"→ worktree remove" は出ない）。
  [[ "$output" != *"→ worktree remove"* ]]
  # FAILED 計上で終了コードは非 0（fail-closed・user-N の skip+exit0 とは非対称）。
  [ "$status" -ne 0 ]
}

@test "cleanup(facet1): user-N（printf 'N'）は EOF と区別され skip+exit0（三値化の非対称を pin）" {
  local tmpdir; tmpdir="$(mktemp -d)"
  # 全 step に 'N' を与える（改行なしでも ans 非空なら通常拒否＝EOF(2) と区別）。
  run bash -c 'printf "N\nN\nN\n" | "$1" --repo "$2" --worktree "$2/nope" \
      --branch "spawn/no-such-$$" --window "wt-no-such-window-$$" un-4nm' _ "$CLEANUP" "$tmpdir"
  rm -rf "$tmpdir"
  # ユーザー拒否は skip 経路（EOF 専用メッセージは出ない）。
  [[ "$output" == *"skip: worktree remove"* ]]
  [[ "$output" != *"EOF"* ]]
  # 全 step skip で失敗ゼロ → exit 0（user-N は fail-loud しない）。
  [ "$status" -eq 0 ]
}

# confirm() の `[[ -z "$ans" ]]` ガード（read rc=1 でも ans 非空なら通常回答）を pin（sc-vuu facet1・gate finding）。
# 末尾改行なしの 'y' は read を rc=1 で返すが ans='y' ゆえ EOF(2) でなく承認(0)へ落ちる——この分岐は
# EOF(</dev/null=ans 空) と user-N(改行付き=rc0) のテストでは未踏ゆえ、ここで明示的に pin する
# （将来 confirm を「read 非0=即 EOF(2)」へ単純化すると改行なし入力が黙って壊れるのを捕捉する）。
@test "cleanup(facet1): 末尾改行なしの 'y'（printf 'y'）は EOF(2) でなく承認(0)＝[[ -z ans ]] ガードを pin" {
  local tmpdir; tmpdir="$(mktemp -d)"
  # stdin が 'y' だけで閉じる（末尾改行なし）→ read rc=1 だが ans='y' → 承認（"→ worktree remove" が出る）。
  run bash -c 'printf "y" | "$1" --repo "$2" --worktree "$2/nope" --branch "spawn/no-such-$$" \
      --window "wt-no-such-$$" un-4nm' _ "$CLEANUP" "$tmpdir"
  rm -rf "$tmpdir"
  # step1(worktree remove) は承認され実行へ進む＝EOF skip でも user-N skip でもない。
  [[ "$output" == *"→ worktree remove"* ]]
}

# ---------- cleanup: cross-repo（bd un-c4s）----------
# --repo 未指定で別リポの worktree を別 cwd から掃除しても、--worktree の所属リポを導出して
# git -C <owning-repo> で実行する（cwd 誤標的で 'branch not found' 安全失敗しない）。
@test "cleanup(un-c4s): --repo 無し+別 cwd でも --worktree の所属リポを導出して掃除する" {
  # owner は git 正準パスへ正準化する（scribe_owning_repo は porcelain の正準絶対パスを返すため、
  # symlink された TMPDIR/-/tmp 環境=macOS/一部 CI で生 mktemp パスと差異が出て偽陽性 fail するのを防ぐ）。
  owner="$(cd "$(mktemp -d)" && pwd -P)"   # 掃除対象 worktree の所属リポ
  other="$(mktemp -d)"   # 実行時 cwd（旧コードはここを誤標的にした別リポ）
  git -C "$owner" -c init.defaultBranch=main init -q
  git -C "$owner" config user.email t@e; git -C "$owner" config user.name t
  git -C "$owner" commit -q --allow-empty -m init
  git -C "$other" -c init.defaultBranch=main init -q
  git -C "$other" config user.email t@e; git -C "$other" config user.name t
  git -C "$other" commit -q --allow-empty -m init
  br="spawn/un-4nm-101010"; wt="$owner/.worktrees/spawn/un-4nm-101010"
  git -C "$owner" worktree add -q -b "$br" "$wt" >/dev/null

  run bash -c 'cd "$1" && "$2" --yes --worktree "$3" --branch "$4" --window "wt-no-such-$$" un-4nm' \
      _ "$other" "$CLEANUP" "$wt" "$br"

  # 所属リポを導出した旨を出し、git -C は owner を標的にしている
  [[ "$output" == *"所属リポを導出"* ]]
  [[ "$output" == *"git -C $owner"* ]]
  [[ "$output" != *"git -C $other"* ]]
  # worktree は実際に消え、branch も安全削除され、終了コードは 0
  [ ! -e "$wt" ]
  ! git -C "$owner" rev-parse --verify -q "refs/heads/$br" >/dev/null 2>&1
  [ "$status" -eq 0 ]
  rm -rf "$owner" "$other"
}

# 明示 --repo は導出より優先される（least-surprise）。明示した非 git ディレクトリを標的に
# 安全失敗することで「導出に上書きされていない」ことを検証する。
@test "cleanup(un-c4s): 明示 --repo は --worktree 導出より優先される" {
  owner="$(mktemp -d)"; explicit="$(mktemp -d)"   # explicit=非 git ディレクトリ
  git -C "$owner" -c init.defaultBranch=main init -q
  git -C "$owner" config user.email t@e; git -C "$owner" config user.name t
  git -C "$owner" commit -q --allow-empty -m init
  br="spawn/un-4nm-202020"; wt="$owner/.worktrees/spawn/un-4nm-202020"
  git -C "$owner" worktree add -q -b "$br" "$wt" >/dev/null

  run "$CLEANUP" --yes --repo "$explicit" --worktree "$wt" --branch "$br" \
      --window "wt-no-such-$$" un-4nm

  # 明示 --repo(explicit)を標的にしているので worktree remove が安全失敗（warn）し WT は残る
  [[ "$output" == *"git -C $explicit"* ]]
  [[ "$output" != *"所属リポを導出"* ]]
  [[ "$output" == *"warn:"* ]]
  [ -e "$wt" ]
  [ "$status" -ne 0 ]
  git -C "$owner" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$owner" "$explicit"
}

# 受入基準(2)の核心: scribe_owning_repo は **継承 GIT_DIR/GIT_WORK_TREE から隔離して**
# main worktree を導出する。別リポの .git を GIT_DIR/GIT_WORK_TREE へ export した状態で
# linked worktree を問い合わせ、汚染リポではなく当該 worktree の所属 main repo を返すことを assert。
# env -u が外れると `git worktree list --porcelain` がリーク先 repo を返し誤導出する（実証済）。
# session-start-role-inject.bats:186 と同系の leak modality を新ヘルパーへ移植した fail-closed ゲート。
@test "cleanup(un-c4s): scribe_owning_repo は継承 GIT_DIR/GIT_WORK_TREE から隔離して導出する" {
  owner="$(mktemp -d)"   # 掃除対象 worktree の所属リポ（正しい導出先）
  poison="$(mktemp -d)"  # GIT_DIR/GIT_WORK_TREE をここへ leak させる汚染リポ
  git -C "$owner" -c init.defaultBranch=main init -q
  git -C "$owner" config user.email t@e; git -C "$owner" config user.name t
  git -C "$owner" commit -q --allow-empty -m init
  git -C "$poison" -c init.defaultBranch=main init -q
  git -C "$poison" config user.email t@e; git -C "$poison" config user.name t
  git -C "$poison" commit -q --allow-empty -m init
  br="spawn/un-4nm-303030"; wt="$owner/.worktrees/spawn/un-4nm-303030"
  git -C "$owner" worktree add -q -b "$br" "$wt" >/dev/null

  want="$(cd "$owner" && pwd -P)"
  # poison の GIT_DIR/GIT_WORK_TREE を export した状態で wt の所属リポを問う。
  run bash -c '
    source "$1"
    export GIT_DIR="$2/.git" GIT_WORK_TREE="$2"
    got="$(scribe_owning_repo "$3")" || exit 9
    cd "$got" && pwd -P
  ' _ "$REPO_ROOT/scripts/lib/scribe-lib.sh" "$poison" "$wt"

  [ "$status" -eq 0 ]
  # 汚染リポではなく当該 worktree の所属 main repo を返す（env -u 隔離が効いている）。
  [[ "$output" == "$want" ]]
  [[ "$output" != *"$poison"* ]]
  rm -rf "$owner" "$poison"
}

# 受入基準(2)後半: worktree でない/git 不在のパスでは空 + 非0 を返す（呼び出し側のフォールバック契約）。
@test "cleanup(un-c4s): scribe_owning_repo は非 git/非 worktree パスで空 + 非0 を返す" {
  nongit="$(mktemp -d)"   # git リポでないただのディレクトリ（/tmp 配下は git 管理外）
  run bash -c 'source "$1"; scribe_owning_repo "$2"' _ "$REPO_ROOT/scripts/lib/scribe-lib.sh" "$nongit"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  # 引数欠落（空文字列）も非0 + 空で弾く。
  run bash -c 'source "$1"; scribe_owning_repo ""' _ "$REPO_ROOT/scripts/lib/scribe-lib.sh"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  rm -rf "$nongit"
}

# 導出失敗時（--worktree が非 git 等で所属リポ不明）は cwd へ安全縮退し warn を surface する。
# fail-open ではなく「破壊操作は cwd で安全失敗 + 手動 --repo を促す」記録経路を fail-closed に固定する。
@test "cleanup(un-c4s): --worktree 導出失敗時は cwd フォールバック + warn を出す" {
  cwd="$(cd "$(mktemp -d)" && pwd -P)"   # 実行 cwd（非 git＝導出も remove も安全失敗する）
  nongit="$(mktemp -d)"                   # 非 git の --worktree（所属リポ導出不能）
  run bash -c 'cd "$1" && "$2" --yes --worktree "$3" --branch "spawn/no-such-$$" --window "wt-no-such-$$" un-4nm' \
      _ "$cwd" "$CLEANUP" "$nongit"
  # 導出できず cwd を使用する warn が surface され、git -C は cwd を標的にする
  [[ "$output" == *"所属リポを導出できず cwd を使用"* ]]
  [[ "$output" == *"git -C $cwd"* ]]
  # 破壊操作は cwd(非 git)で安全失敗し終了コード非0（fail-closed・force 系は依然出さない）
  [ "$status" -ne 0 ]
  [[ "$output" != *"branch -D"* ]]
  [[ "$output" != *"kill-server"* ]]
  rm -rf "$cwd" "$nongit"
}

# ---------- origin 健全性ガード（bd un-1n1）----------
# worktree は anchor と .git/config（remotes）を共有するため worker の origin mutate が anchor+全 worktree を
# 壊す（un-v5x 実害）。spawn で canonical origin を per-worktree marker へ捕捉し、gate で照合・復元する。
# 実 git で main+linked worktree（origin 付き）を作り、共有 config の origin 汚染→検知→復元を検証する。

# main+linked worktree（origin remote 付き）を 1 組作る。stdout に "<main>\t<linked>" を返す。
_mk_repo_with_origin() {
  local main linked
  main="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$main" -c init.defaultBranch=main init -q
  git -C "$main" config user.email t@e; git -C "$main" config user.name t
  git -C "$main" commit -q --allow-empty -m init
  git -C "$main" remote add origin https://github.com/shuu5/scribe.git
  linked="$main/.worktrees/spawn/un-4nm-101010"
  git -C "$main" worktree add -q -b spawn/un-4nm-101010 "$linked" >/dev/null
  printf '%s\t%s\n' "$main" "$linked"
}

@test "origin-guard(un-1n1): marker path は per-worktree git dir 配下（共有 config と別物）・非 git は空+非0" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  run bash -c 'source "$1"; scribe_origin_marker_path "$2"' _ "$LIB" "$linked"
  [ "$status" -eq 0 ]
  # per-worktree の private git dir（.git/worktrees/<name>/）配下に置く＝共有 .git/config とは別物。
  [[ "$output" == "$main/.git/worktrees/un-4nm-101010/scribe-origin.marker" ]]
  # 非 git / 引数欠落は空 + 非0。
  nongit="$(mktemp -d)"
  run bash -c 'source "$1"; scribe_origin_marker_path "$2"' _ "$LIB" "$nongit"
  [ "$status" -ne 0 ]; [ -z "$output" ]
  run bash -c 'source "$1"; scribe_origin_marker_path ""' _ "$LIB"
  [ "$status" -ne 0 ]; [ -z "$output" ]
  rm -rf "$nongit"
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): capture が canonical origin を marker へ捕捉する（spawn 相当）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  run "$GUARD" capture --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *"captured: origin=https://github.com/shuu5/scribe.git"* ]]
  [[ "$(cat "$main/.git/worktrees/un-4nm-101010/scribe-origin.marker")" == "https://github.com/shuu5/scribe.git" ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): verify は健全なら exit 0（汚染なし）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null
  run "$GUARD" verify --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): 汚染 origin を検知して exit 非0 + canonical URL を stdout（核心 AC）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null
  # worker が共有 .git/config の origin を dummy へ書換（un-v5x の汚染を再現）。
  git -C "$linked" remote set-url origin https://10.255.255.1/repo.git
  # main 側も同じ汚染を見る（config 共有の証拠）。
  [[ "$(git -C "$main" remote get-url origin)" == "https://10.255.255.1/repo.git" ]]
  # 汚染検知 → exit 非0・canonical URL を stdout・差分を stderr。
  run "$GUARD" verify --worktree "$linked"
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://github.com/shuu5/scribe.git"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): verify --restore は汚染検知時に origin を復元してなお exit 非0（fail-loud 維持）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null
  git -C "$linked" remote set-url origin https://10.255.255.1/repo.git
  run "$GUARD" verify --worktree "$linked" --restore
  # 復元しても「汚染が起きた事実」は非0 で上流へ伝える（fail-loud）。
  [ "$status" -ne 0 ]
  # origin は canonical へ復元されている（main 側で確認）。
  [[ "$(git -C "$main" remote get-url origin)" == "https://github.com/shuu5/scribe.git" ]]
  # 復元後は verify が健全（exit 0）。
  run "$GUARD" verify --worktree "$linked"
  [ "$status" -eq 0 ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): restore サブコマンドで marker から origin を復元する" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null
  git -C "$linked" remote set-url origin https://10.255.255.1/repo.git
  run "$GUARD" restore --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$(git -C "$main" remote get-url origin)" == "https://github.com/shuu5/scribe.git" ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

# worker が `git remote remove origin` で origin ごと削除したケースも復元できる（set-url は存在しない
# remote を作れず No such remote で失敗するため add へ分岐する・un-1n1 gate finding）。
@test "origin-guard(un-1n1): origin を remove で削除しても verify は汚染検知 + restore が add で再作成する" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null
  git -C "$linked" remote remove origin   # worker が origin ごと削除（書換でなく削除）
  ! git -C "$main" remote get-url origin >/dev/null 2>&1   # origin 不在を確認
  # verify は origin 消失も汚染として検知（fail-loud・false-clean ではない）。
  run "$GUARD" verify --worktree "$linked"
  [ "$status" -ne 0 ]
  [[ "$output" == *"https://github.com/shuu5/scribe.git"* ]]
  # restore は remote add で再作成して復元する。
  run "$GUARD" restore --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$(git -C "$main" remote get-url origin)" == "https://github.com/shuu5/scribe.git" ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): origin 無しの repo では capture は no-op（marker 未作成・exit 0）" {
  main="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$main" -c init.defaultBranch=main init -q
  git -C "$main" config user.email t@e; git -C "$main" config user.name t
  git -C "$main" commit -q --allow-empty -m init
  linked="$main/.worktrees/spawn/un-4nm-202020"
  git -C "$main" worktree add -q -b spawn/un-4nm-202020 "$linked" >/dev/null
  run "$GUARD" capture --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin 無し"* ]]
  [ ! -f "$main/.git/worktrees/un-4nm-202020/scribe-origin.marker" ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): marker 不在（baseline なし）の verify は skip して exit 0 + warn を出す" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  # capture せずに verify（marker が無い）→ 照合不能ゆえ skip（exit 0）だが warn を surface。
  run "$GUARD" verify --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *"marker が無く照合できません"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

# marker 不在=skip=exit0 は意図的 fail-open（dogfood: origin 無し新規リポは gate を素通りすべき）。
# それを個別 gate で厳格化したい場合の additive opt-in が --require-marker（既定挙動は不変・sc-vuu facet2）。
# sc-cw6: --require-marker 下の marker 不在は「origin 現存=真の漏れ=非0」と「origin 無し=正当 no-op=exit0」を
# 区別する（capture-failure と origin-無し の区別）。下 2 test で両枝を pin する。
@test "origin-guard(facet2/sc-cw6): --require-marker は origin 現存 ＆ marker 不在を fail-loud（真の漏れ=非0）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)   # repo は origin 付き
  # capture せず（marker 不在）に --require-marker で verify → origin 現存ゆえ真の漏れ＝fail-loud。
  run "$GUARD" verify --worktree "$linked" --require-marker
  [ "$status" -ne 0 ]
  [[ "$output" == *"marker が不在"* ]]
  [[ "$output" == *"origin が現存"* ]]
  # 同条件で --require-marker 無しなら従来どおり skip=exit0（既定挙動が additive opt-in で壊れていない）。
  run "$GUARD" verify --worktree "$linked"
  [ "$status" -eq 0 ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(sc-cw6): --require-marker でも origin 無し ＆ marker 不在は exit 0（正当 no-op を誤検知しない）" {
  # origin を持たない repo + linked worktree（capture は no-op で marker 未作成）。
  main="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$main" -c init.defaultBranch=main init -q
  git -C "$main" config user.email t@e; git -C "$main" config user.name t
  git -C "$main" commit -q --allow-empty -m init
  linked="$main/.worktrees/spawn/un-4nm-303030"
  git -C "$main" worktree add -q -b spawn/un-4nm-303030 "$linked" >/dev/null
  # origin が無いので marker 不在は「保護対象なし」＝strict でも素通す（false-positive を出さない）。
  run "$GUARD" verify --worktree "$linked" --require-marker
  [ "$status" -eq 0 ]
  [[ "$output" == *"保護対象なし"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(sc-cw6): --require-marker で origin 現存 probe が失敗（--repo が非 git）なら fail-closed（非0・論点1）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  notgit="$(mktemp -d)"   # git repo でないディレクトリ＝git remote が失敗し origin 現存を判定できない
  # marker 不在 + origin 現存判定不能（--repo が非 git で git remote が落ちる）→ strict 意図ゆえ fail-closed。
  run "$GUARD" verify --worktree "$linked" --repo "$notgit" --require-marker
  [ "$status" -ne 0 ]
  [[ "$output" == *"判定できませんでした"* ]]
  rm -rf "$notgit"
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(facet2): --require-marker 下でも marker があれば健全 verify は exit 0（厳格化は不在時のみ）" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null   # marker を作る
  run "$GUARD" verify --worktree "$linked" --require-marker
  [ "$status" -eq 0 ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): verify は継承 GIT_DIR/GIT_WORK_TREE から隔離して marker/origin を解決する" {
  IFS=$'\t' read -r main linked < <(_mk_repo_with_origin)
  "$GUARD" capture --worktree "$linked" >/dev/null
  poison="$(mktemp -d)"
  git -C "$poison" -c init.defaultBranch=main init -q
  git -C "$poison" config user.email t@e; git -C "$poison" config user.name t
  git -C "$poison" commit -q --allow-empty -m init
  git -C "$poison" remote add origin https://example.invalid/poison.git
  # poison の GIT_DIR/GIT_WORK_TREE を export しても、当該 worktree の共有 config origin を読む。
  run bash -c 'export GIT_DIR="$1/.git" GIT_WORK_TREE="$1"; "$2" verify --worktree "$3"' \
      _ "$poison" "$GUARD" "$linked"
  [ "$status" -eq 0 ]   # 健全（poison の origin に引きずられない）
  [[ "$output" != *"poison"* ]]
  rm -rf "$poison"
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main"
}

@test "origin-guard(un-1n1): 引数なし/未知サブコマンド/--worktree 欠落/--restore 誤用で fail-loud" {
  run "$GUARD"; [ "$status" -ne 0 ]
  run "$GUARD" bogus --worktree /tmp/wt; [ "$status" -ne 0 ]
  run "$GUARD" verify; [ "$status" -ne 0 ]
  # --restore は verify 専用（capture/restore に付けると fail-loud）。
  run "$GUARD" capture --worktree /tmp/wt --restore; [ "$status" -ne 0 ]
  # --require-marker も verify 専用（capture/restore に付けると fail-loud・sc-vuu facet2）。
  run "$GUARD" capture --worktree /tmp/wt --require-marker; [ "$status" -ne 0 ]
}

# ---------- live security guard の self-test を回帰網へ配線（sc-i9b member 1）----------
# rm/git/cmdtokens guard はそれぞれ hermetic な `--self-test`（実破壊なし・/tmp に fixture を作って
# 判定だけ検証）を内蔵し、pass で exit 0 を返す。これを bats から呼ぶことで 200+ の security
# assertion が「bats 緑のまま壊れうる」状態を脱し回帰網へ入る。python3 は本ファイルで json.tool
# 既使用ゆえ前提不変。rm guard の scratch は /tmp 等 HOME 外固定（TMPDIR 非依存・un-x3o）。
# case 数下限 pin（sc-16n）: self-test の print は cases 配列 length 駆動ゆえ、cases を空にすると
# 0/0+exit0 を出して上の status0+substring を全て満たす。117+/81+/7 の security assertion を消す
# mutation が緑のまま通る second-order な test-on-test 穴を、総数(分母)の下限 assert で塞ぐ
# （現数 rm=123/git=106/cmdtokens=7。最終 case 数確定後＝sc-x4h/sc-i13/sc-oem 完了後に pin）。
@test "guard self-test: rm-destructive-guard --self-test が exit 0 + case 数下限（hermetic）" {
  run python3 "$HOOKS/rm-destructive-guard.py" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELF-TEST PASSED"* ]]
  [[ "$output" =~ ([0-9]+)/([0-9]+)" cases" ]]
  [ "${BASH_REMATCH[2]}" -ge 100 ]   # cases 空(0/0)・大量削除を捕捉
}

@test "guard self-test: git-destructive-guard --self-test が exit 0 + case 数下限（hermetic）" {
  run python3 "$HOOKS/git-destructive-guard.py" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" =~ ([0-9]+)/([0-9]+)" OK" ]]
  [ "${BASH_REMATCH[2]}" -ge 80 ]
}

@test "guard self-test: cmdtokens --self-test が exit 0 + case 数下限（軽量サニティ）" {
  run python3 "$HOOKS/lib/cmdtokens.py" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
  [[ "$output" =~ ([0-9]+)/([0-9]+)" OK" ]]
  [ "${BASH_REMATCH[2]}" -ge 5 ]
}

# ---------- PreToolUse guard WIRE の e2e 回帰（sc-4ix）----------
# 上の self-test は guard 単体の判定を pin するが、hooks.json の *配線*（command 文字列・matcher・
# 起動行・guard の存在）は別物。fail-open suffix(`|| true`)混入・matcher typo・起動行破損・guard 削除が
# 起きると 3 guard の self-test が緑のまま本番で破壊コマンドが素通りしうる（exit2→exit0 化は実機再現済）。
# そこで hooks.json から *実際の command 文字列を抽出して起動* し end-to-end で block/fail-open を pin する
# （session-start-role-inject.bats の SessionStart wire テストと対称）。guard 名で select するので配列順や
# 一方の guard 削除にも耐える（jq が空を返し [ -n ] で fail-loud）。
_pre_cmd() {  # <guard-script-basename> → 該当 PreToolUse[Bash] hook の command 文字列
  jq -r --arg s "$1" '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[].command | select(contains($s))' "$HOOKS_JSON"
}

@test "PreToolUse wire(sc-4ix): hooks.json の command 経由で破壊 git/rm を exit2 block（end-to-end）" {
  local gcmd rcmd
  gcmd="$(_pre_cmd git-destructive-guard.py)"
  rcmd="$(_pre_cmd rm-destructive-guard.py)"
  [ -n "$gcmd" ]   # git-guard が PreToolUse[Bash] 下に配線されている（削除/matcher typo を捕捉）
  [ -n "$rcmd" ]   # rm-guard が配線されている
  # 実 command を起動（${CLAUDE_PLUGIN_ROOT}→repo root に解決）。fail-open suffix 混入なら exit0 化し fail。
  run env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "$gcmd" <<< '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"cwd":"/tmp"}'
  [ "$status" -eq 2 ]
  run env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "$rcmd" <<< '{"tool_name":"Bash","tool_input":{"command":"rm -rf /etc"},"cwd":"/tmp"}'
  [ "$status" -eq 2 ]
}

@test "PreToolUse wire(sc-4ix): script 不在（CLAUDE_PLUGIN_ROOT 異常）で exit0・副作用ゼロ（fail-open）" {
  local cmd
  for cmd in "$(_pre_cmd git-destructive-guard.py)" "$(_pre_cmd rm-destructive-guard.py)"; do
    run --separate-stderr env CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/nonexistent" bash -c "$cmd" <<< '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"cwd":"/tmp"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
}

# ---------- bdw: flock-serialized B/hybrid の中核ロジックを pin（sc-i9b member 2）----------
# bd 実体を echo に差し替え（BDW_BD_BIN=echo）て実 Dolt write を起こさず、READ/WRITE 経路の
# 分岐だけを検証する。判定の観測点 = BDW_LOCK_DIR に `bd-write-*.lock` が作られたか。
#   - READ allowlist  → exec が lock 作成より前（L66）に走るため lock 0 個（無ロック素通し）
#   - WRITE / 未知    → flock 取得後 exec のため lock 1 個（直列化路）
# 各 @test は使い捨ての空 lock dir を作って観測する。cwd は setup() の temp git repo。
_bdw_locks() { ls "$1"/bd-write-*.lock 2>/dev/null | wc -l | tr -d ' '; }

@test "bdw: READ allowlist（show）は無ロックで素通し（lock 0 個・args 透過）" {
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" show un-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"show un-x"* ]]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: WRITE（update --claim）は flock 取得路（lock 1 個・args 透過）" {
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" update un-x --claim
  [ "$status" -eq 0 ]
  [[ "$output" == *"update un-x --claim"* ]]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: WRITE（close）は flock 取得路（lock 1 個）" {
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" close un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: 未知サブコマンドは fail-closed で flock 取得路（lock 1 個・allowlist 漏れ=直列化）" {
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" frobnicate x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: WRITE は flock 取得失敗で fail-closed（実排他を観測・lock file 在＝取得済 を証明しない）" {
  # 上の WRITE @test 群は「lock file が在る」しか見ない。だが bdw L89 `exec 9>lock_file` は
  # flock 取得の成否に依らず lock file を無条件生成するので、L90 `flock -w` が回帰で消えても
  # それらは緑のまま通る（lock file 在 ≠ 排他が効いている）。本 @test は実際の相互排他を観測する:
  # 別プロセスに同一 lock を保持させたまま bdw WRITE を BDW_LOCK_TIMEOUT=1 で起動し、取得失敗で
  # 非 0 終了し bd を実行しない（fail-closed）ことを assert する。flock が外れれば bdw は素通しで
  # 緑になり本 @test が落ちる＝『flock が実際に直列化している』を pin する。
  local ld; ld="$(mktemp -d)"
  # 1) WRITE を 1 回走らせて bdw が計算する実 lock file パスを得る（repo_id は cwd 依存）。
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" close un-x
  [ "$status" -eq 0 ]
  local lock_file; lock_file="$(ls "$ld"/bd-write-*.lock)"
  # 2) 別プロセスに排他ロックを保持させる。marker でロック保持を待ち、release で解放する
  #    （固定 sleep に依らない決定論同期）。
  local marker="$ld/held" release="$ld/release"
  ( flock -x 9; touch "$marker"; while [ ! -e "$release" ]; do sleep 0.05; done ) 9>"$lock_file" &
  local holder=$!
  local i; for ((i=0; i<200; i++)); do [ -e "$marker" ] && break; sleep 0.05; done
  [ -e "$marker" ]   # holder が確かにロックを保持していること
  # 3) ロック保持中に bdw WRITE → 取得失敗で fail-closed（非 0・bd 不実行・診断 stderr）。
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" BDW_LOCK_TIMEOUT=1 "$BDW" close un-y
  touch "$release"; wait "$holder" 2>/dev/null || true
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not acquire"* ]]
  [[ "$output" != *"close un-y"* ]]   # bd（echo スタブ）は実行されていない
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（--actor）の値を subcommand と誤認しない（--actor close show → READ・lock 0）" {
  # --actor の値が write subcmd 名（close）でも次トークンとして読み飛ばし、真の subcmd=show を採る。
  # skip_next が壊れると subcmd=close と誤認 → WRITE lock になる。lock 0 でそれを pin。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" --actor close show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（--db）の値を subcommand と誤認しない（--db close show → READ・lock 0）" {
  # 契約 member(2) が名指しで pin を要求する 3 つ目の value-taking flag。--db の値が write subcmd 名
  # （close）でも次トークンとして読み飛ばし、真の subcmd=show を採る。bdw L55 の case 一覧から --db が
  # 回帰で落ちると subcmd=close と誤認 → WRITE lock になる。lock 0 でそれを pin（--actor と対称）。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" --db close show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（--directory）の値を subcommand と誤認しない（--directory close show → READ・lock 0）" {
  # 同 skip_next case 分岐（L55）の網羅を完成させる。--directory の値（close）を読み飛ばし真の subcmd=show
  # を採る。case 一覧から --directory が落ちれば subcmd=close 誤認 → WRITE lock。lock 0 でそれを pin。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" --directory close show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（-C）は値を飛ばし真の subcommand を採る（-C path update → WRITE・lock 1）" {
  # -C の値（/tmp/x）を飛ばした上で update を subcmd と認識する＝flag-skip が真の subcmd を食わない。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" -C /tmp/x update un-y --claim
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: boolean flag（-f）を値取りと誤読しない（-f show → READ・lock 0）" {
  # -f は boolean。次トークン show を値として食わない（食えば subcmd=un-x→未知→WRITE lock）。lock 0 で pin。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" -f show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: bd 不在は exit 127 で fail-loud（write を実行しない）" {
  run -127 env BDW_BD_BIN=/nonexistent-bd-xyz "$BDW" show un-x
  [ "$status" -eq 127 ]
  [[ "$output" == *"not found"* ]]
}

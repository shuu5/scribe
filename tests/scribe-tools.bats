#!/usr/bin/env bats
# scribe 道具（spawn ヘルパー / gate 支援 / cleanup）の dry-run arg-echo を検証する。
# **実 spawn・実 tmux・実 claude 起動はしない**（dry-run + bd スタブのみ・コスト大ゆえ）。
# 道具がコード化する規約の SSOT = docs/protocol.md。

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
  # bd を実在検証スタブへ差し替え（実 graph 不要）。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm un-consult un-3sh.3.5"
  # cld-spawn は dry-run では実行されない。echo を決定論化するため固定値を入れる。
  export SCRIBE_CLD_SPAWN="cld-spawn"
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
  for f in "$SPAWN" "$GATE" "$SELFTEST" "$CLEANUP" "$GUARD" "$SCRIPTS/lib/scribe-lib.sh"; do
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

# ---------- spawn: consult pre-bake モード（--context・§7 needs-user regime / 合意スペック 9c73606d）----------
@test "spawn(pre-bake): --context + bd id で handoff 規約（conversation_id/tag）と焼き込み context が prompt に注入される" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'ADMIN_PREBAKED_CONTEXT_SENTINEL\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # admin 事前 context が焼き込まれる（同一出発点）。
  [[ "$output" == *"ADMIN_PREBAKED_CONTEXT_SENTINEL"* ]]
  # handoff 規約: 集約は共有グループ tag。conversation_id は dedup 回避ヒントとして併用。
  # tag=consult-<HHMMSS> は window 名と一致（capture-pane 突合の個別識別）。
  [[ "$output" == *"scribe-brief-un-consult"* ]]                 # 共有グループ tag = task_ref keyed
  [[ "$output" == *"conversation_id"* ]]                          # dedup 回避ヒントとして残す
  re='tag=consult-[0-9]{6}'
  [[ "$output" =~ $re ]]
  # 集約 key は tag（conversation_id は memory_search フィルタに採れない＝§7 verified errata）。
  [[ "$output" == *"集約"* ]]
  [[ "$output" == *"memory_search"* ]]
  # pre-bake 手順 + doobidoo 専用（un-sl9 回避）の brief 保存規約。
  [[ "$output" == *"pre-bake"* ]]
  [[ "$output" == *"task_ref: un-consult"* ]]
  [[ "$output" == *"un-sl9"* ]]
  # 並列 consult の brief 衝突回避ゆえ MEMORY.md は使わない指示が出る。
  [[ "$output" == *"MEMORY.md は使わない"* ]]
}

@test "spawn(pre-bake): F1/F2/F3 regime 知見が consult prompt へ注入される（dogfood sc-in9）" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # F1: consult は pre-bake 専任で対話 grill に入らない（grill トポロジ = 案 B）。
  [[ "$output" == *"pre-bake 専任"* ]]
  [[ "$output" == *"対話 grill に入らない"* ]]
  # F2: brief にメタ直後の出典ヘッダ（提案＝第三者データ・決定でない）を置く＝admin の attribution 予防。
  [[ "$output" == *"第三者データ"* ]]
  # F3: 単発失敗で down 断定せずリトライ + 保存成功を終了条件にする（黙って brief を捨てない）。
  [[ "$output" == *"単発失敗"* ]]
  [[ "$output" == *"保存成功を終了条件"* ]]
}

@test "spawn(pre-bake): --context は worker モードでは consult 専用 die（worker は pre-bake しない）" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --context "$ctx" un-4nm
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"consult"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(pre-bake): --context は bd id（task_ref）必須で fail-loud（conversation_id を構成できない）" {
  ctx="$(mktemp /tmp/scribe-ctx-XXXXXX.md)"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx"
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"task_ref"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(pre-bake): --context のファイルが不在だと fail-loud（typo を上流で塞ぐ）" {
  run "$SPAWN" --dry-run --consult --context /tmp/scribe-no-such-ctx-file.md un-consult
  [ "$status" -ne 0 ]
  [[ "$output" == *"通常ファイル"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(pre-bake): --context にディレクトリを渡すと fail-loud（空 context のまま起動する fail-safe ギャップ防御・review wf_a92a624f）" {
  dir="$(mktemp -d /tmp/scribe-ctx-dir-XXXXXX)"
  run "$SPAWN" --dry-run --consult --context "$dir" un-consult
  rmdir "$dir"
  # -r 単体ならディレクトリは truthy で通過してしまう。-f で弾けていることを確認。
  [ "$status" -ne 0 ]
  [[ "$output" == *"通常ファイル"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(pre-bake): --context 無しの素 consult は pre-bake 節を一切出さない（回帰防御）" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" != *"pre-bake"* ]]
  [[ "$output" != *"scribe-brief-"* ]]
  [[ "$output" != *"conversation_id"* ]]
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

@test "gate-args: --model fable 系を拒否する" {
  run "$GATE" --dry-run --worktree /tmp/wt --model claude-fable-5 un-4nm
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

@test "selftest-args: --model fable 系を拒否する（worker は opus・protocol.md §1）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'x' --model claude-fable-5 un-4nm
  [ "$status" -ne 0 ]
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
}

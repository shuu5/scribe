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
  CLEANUP="$SCRIPTS/scribe-cleanup.sh"
  # bd を実在検証スタブへ差し替え（実 graph 不要）。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm un-consult un-3sh.3.5"
  # cld-spawn は dry-run では実行されない。echo を決定論化するため固定値を入れる。
  export SCRIBE_CLD_SPAWN="cld-spawn"
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true
}

# ---------- bash -n（全 script 構文）----------
@test "bash -n: 全 script が構文 OK" {
  for f in "$SPAWN" "$GATE" "$CLEANUP" "$SCRIPTS/lib/scribe-lib.sh"; do
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

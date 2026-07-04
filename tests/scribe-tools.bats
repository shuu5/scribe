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
  WATCH="$SCRIPTS/grill-status-watch.sh"
  PROBE="$SCRIPTS/scribe-env-probe.sh"
  E2E="$SCRIPTS/sandbox-spike/verify-sandbox-e2e.sh"
  HOOKS="$SCRIPTS/hooks"
  HOOKS_JSON="$REPO_ROOT/hooks/hooks.json"
  # bd を実在検証スタブへ差し替え（実 graph 不要）。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm un-consult un-3sh.3.5"
  # cld-spawn は dry-run では実行されない。echo を決定論化するため固定値を入れる。
  export SCRIBE_CLD_SPAWN="cld-spawn"
  # sc-ovq: spawn は real-exec 冒頭で **無条件に**（ON/OFF 両経路で）canonical bdw 到達性を検査する
  # （zombie worker 防止）。bdw 非依存の spawn テスト（preflight/fallback/orphan/gen 失敗枝）が host の
  # plugin 配備に左右されないよう、`lock-dir` で exit0 する present スタブを 1 つ用意する（テストは
  # BEADS_BDW="$BDW_PRESENT_STUB" でこれを使う＝host 非依存維持）。bdw 不在を注入するテストは BEADS_BDW を
  # 明示上書きする（_need_canonical_bdw で実 canonical を要するテストには使わない＝そちらは skip 規律のまま）。
  BDW_PRESENT_STUB="$BATS_TEST_TMPDIR/bdw-present-stub"
  printf '#!/usr/bin/env bash\n[ "$1" = lock-dir ] && { echo "%s/locks"; exit 0; }\n[ "$1" = lock-file ] && { echo "%s/locks/bd-write-stub.lock"; exit 0; }\nexit 0\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BDW_PRESENT_STUB"
  chmod +x "$BDW_PRESENT_STUB"
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
  for f in "$SPAWN" "$GATE" "$SELFTEST" "$CLEANUP" "$GUARD" "$BDW" "$PROBE" "$SCRIPTS/lib/scribe-lib.sh"; do
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

# ---------- lib: scribe_branch_name 直接ユニット（sc-b8j・関数を source して叩く）----------
# 上の spawn dry-run 群は spawn ヘルパー経由で命名を観るが、ここは scribe_branch_name を
# 直接 source して叩き、HHMMSS 決定論注入の precedence（第2引数 > SCRIBE_HHMMSS > date +%H%M%S）
# の 3 枝を単体で pin する（protocol.md §1 の spawn/<id>-HHMMSS 命名規約）。
@test "lib(sc-b8j): scribe_branch_name は SCRIBE_HHMMSS env 注入で spawn/<id>-HHMMSS を決定論生成" {
  run env SCRIBE_HHMMSS=101010 bash -c 'source "$1"; scribe_branch_name "$2"' _ "$LIB" un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == "spawn/un-4nm-101010" ]]
}

@test "lib(sc-b8j): scribe_branch_name は第2引数 hhmmss を使い env より優先する" {
  # 第2引数注入: env 注入と同結果（spawn/<id>-101010）。ambient SCRIBE_HHMMSS を env -u で隔離し
  # 第2引数の単独効力を ambient 状態から独立に表明する（tests 1/3 と同じ hermetic 方針・setup L29-30）。
  run env -u SCRIBE_HHMMSS bash -c 'source "$1"; scribe_branch_name "$2" "$3"' _ "$LIB" un-4nm 101010
  [ "$status" -eq 0 ]
  [[ "$output" == "spawn/un-4nm-101010" ]]
  # 第2引数は SCRIBE_HHMMSS env を上書きする（${2:-${SCRIBE_HHMMSS:-}} の precedence を pin）。
  run env SCRIBE_HHMMSS=999999 bash -c 'source "$1"; scribe_branch_name "$2" "$3"' _ "$LIB" un-4nm 101010
  [ "$status" -eq 0 ]
  [[ "$output" == "spawn/un-4nm-101010" ]]
}

@test "lib(sc-b8j): scribe_branch_name は注入なしで spawn/<id>-+6桁の date フォールバック" {
  run env -u SCRIBE_HHMMSS bash -c 'source "$1"; scribe_branch_name "$2"' _ "$LIB" un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^spawn/un-4nm-[0-9]{6}$ ]]
}

# sc-te9（sc-498 litmus payload・admin salvage）: scribe_normalize_bd_id（spawn/gate-args/selftest-args/
# cleanup 全道具が呼ぶ id 正規化の核）を直接 source して各枝を pin（先頭#剥がし/前後空白trim/dotted id通過/
# .. traversal・スラッシュ拒否）。実装は scripts/lib/scribe-lib.sh（無変更）。worker1 が degraded で未達→admin 引取（§6）。
@test "lib(sc-te9): scribe_normalize_bd_id は先頭 # を剥がし前後空白を trim する" {
  run bash -c 'source "$1"; scribe_normalize_bd_id "$2"' _ "$LIB" '#un-4nm'
  [ "$status" -eq 0 ]
  [ "$output" = "un-4nm" ]
  run bash -c 'source "$1"; scribe_normalize_bd_id "$2"' _ "$LIB" '  un-4nm  '
  [ "$status" -eq 0 ]
  [ "$output" = "un-4nm" ]
}

@test "lib(sc-te9): scribe_normalize_bd_id は dotted id（un-3sh.3.5）を通す" {
  run bash -c 'source "$1"; scribe_normalize_bd_id "$2"' _ "$LIB" 'un-3sh.3.5'
  [ "$status" -eq 0 ]
  [ "$output" = "un-3sh.3.5" ]
}

@test "lib(sc-te9): scribe_normalize_bd_id は .. traversal / スラッシュ を非0 で弾く" {
  run bash -c 'source "$1"; scribe_normalize_bd_id "$2"' _ "$LIB" '../evil'
  [ "$status" -ne 0 ]
  run bash -c 'source "$1"; scribe_normalize_bd_id "$2"' _ "$LIB" 'un..evil'
  [ "$status" -ne 0 ]
}

# ---------- spawn: sandbox opt-in（SCRIBE_SANDBOX=1・sc-1gu）----------
# realistic .beads fixture（sc-nd6）: tracked 統治ファイル + dolt/bd runtime を両方置く。gen は governance を
# 除いた present 直下エントリだけを grant するため、両種を置いて「runtime は grant・統治は除外」を検証できる。
# 旧 gen は .beads の存在を見ず path 文字列を無条件 grant していたが、新 gen は実在 runtime を列挙するため
# gen を叩くテストは realistic .beads を要する（＝より正しいテスト化）。
_mk_beads() {
  local d="$1/.beads"
  mkdir -p "$d/embeddeddolt/x/.dolt/noms" "$d/backup"
  : > "$d/PRIME.md"; : > "$d/metadata.json"; : > "$d/config.yaml"; : > "$d/README.md"; : > "$d/.gitignore"
  : > "$d/issues.jsonl"; : > "$d/interactions.jsonl"; : > "$d/last-touched"; : > "$d/.local_version"
}

@test "spawn(sandbox): gen-sandbox-settings.sh は failIfUnavailable + .beads runtime サブパス allowWrite の valid JSON を出す（sc-nd6: 統治ファイルを除外）" {
  _mk_beads "$SCRIBE_TEST_CWD"
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$SCRIBE_TEST_CWD"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.sandbox.enabled==true and .sandbox.failIfUnavailable==true and .sandbox.allowUnsandboxedCommands==false' >/dev/null
  # sc-nd6/sc-mcx: allowWrite は .beads を丸ごとでなく runtime サブパス + lock **鍵 file**。embeddeddolt は grant・wholesale .beads は非 grant。
  local b="$SCRIBE_TEST_CWD/.beads"
  echo "$output" | jq -e --arg b "$b" '.sandbox.filesystem.allowWrite | (index($b+"/embeddeddolt")!=null) and (index($b)==null)' >/dev/null
}

@test "gen-sandbox(sc-nd6・OG-1): tracked 統治ファイル(PRIME.md/metadata.json/config.yaml/README.md/.gitignore)は allowWrite に入らない＝worker Bash から read-only" {
  _mk_beads "$SCRIBE_TEST_CWD"
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$SCRIBE_TEST_CWD" "$SCRIBE_TEST_CWD"
  [ "$status" -eq 0 ]
  local b="$SCRIBE_TEST_CWD/.beads"
  # 統治ファイル5種がどれも allowWrite に無い（差集合=5＝全除外）＝OG-1 の核心 assertion。
  echo "$output" | jq -e --arg b "$b" '([$b+"/PRIME.md",$b+"/metadata.json",$b+"/config.yaml",$b+"/README.md",$b+"/.gitignore"] - .sandbox.filesystem.allowWrite | length)==5' >/dev/null
  # runtime(embeddeddolt)は grant＝worker の bd write は機能する（過剰狭化でない）。
  echo "$output" | jq -e --arg b "$b" '.sandbox.filesystem.allowWrite | index($b+"/embeddeddolt")!=null' >/dev/null
  # wholesale .beads を grant しない（旧 over-grant の回帰ガード）。
  echo "$output" | jq -e --arg b "$b" '.sandbox.filesystem.allowWrite | index($b)==null' >/dev/null
}

@test "gen-sandbox(sc-nd6): 空/統治のみの .beads は fail-closed（exit 2・空 allowWrite を黙って出さない）" {
  local A; A="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$A" -c init.defaultBranch=main init -q; git -C "$A" config user.email t@e; git -C "$A" config user.name t; git -C "$A" commit -q --allow-empty -m init
  mkdir -p "$A/.beads"; : > "$A/.beads/PRIME.md"; : > "$A/.beads/metadata.json"   # 統治のみ・runtime 無し
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$A" "$A"
  [ "$status" -eq 2 ]
  [[ "$output" == *"grant 可能な runtime エントリがありません"* ]]
  rm -rf "$A"
}

@test "spawn(sandbox/sc-lkg): cross-repo で gen は明示 anchor(第2引数)の .beads を grant する（逆算は repo 側を誤 grant＝negative control）" {
  # cross-repo cell（scribe-spawn --repo X --anchor Y・X≠Y）の再現: worktree は repo X 側に在り、
  # 真の bd graph は別リポ anchor Y に在る。gen の第2引数（明示 anchor）が無いと逆算で X を誤 grant する。
  local repoX anchorY wt
  repoX="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$repoX" -c init.defaultBranch=main init -q
  git -C "$repoX" config user.email t@e; git -C "$repoX" config user.name t
  git -C "$repoX" commit -q --allow-empty -m init
  _mk_beads "$repoX"                                # 逆算で誤 grant される側にも realistic .beads（sc-nd6）
  anchorY="$(cd "$(mktemp -d)" && pwd -P)"          # 真の bd graph 所在（repo X とは別リポ）
  _mk_beads "$anchorY"
  wt="$repoX/.worktrees/cell"
  git -C "$repoX" worktree add -q -b cell-branch "$wt" >/dev/null

  # (a) negative control: anchor 未指定＝逆算 → repo X の .beads runtime を誤 grant（sc-lkg バグ再現＝修正の counterfactual）
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$wt"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg x "$repoX/.beads" '.sandbox.filesystem.allowWrite | index($x+"/embeddeddolt")!=null' >/dev/null

  # (b) fix: 真の anchor Y を第2引数で明示 → Y の .beads runtime を grant・X 側は一切 grant しない（sc-nd6 で shape 更新）
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$wt" "$anchorY"
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg y "$anchorY/.beads" '.sandbox.filesystem.allowWrite | index($y+"/embeddeddolt")!=null' >/dev/null
  echo "$output" | jq -e --arg x "$repoX/.beads" '.sandbox.filesystem.allowWrite | (map(startswith($x+"/")) | any | not)' >/dev/null

  rm -rf "$repoX" "$anchorY"
}

@test "gen-sandbox(sc-mcx/cross-repo): lock-file grant は worktree(X)でなく anchor(Y)の repo_id 鍵（実 bdw・stub でない・OG-4 誤 grant 回帰）" {
  # sc-mcx cell-quality blocking: 既存 cross-repo テスト(sc-lkg)は BDW_PRESENT_STUB(定数 lock 名)で repo_id 導出を
  # 再現せず lock file を assert しない。ここは **実 canonical bdw** で 2 実リポ(X≠Y)を構成し、gen の lock-file grant
  # が anchor(Y)の repo_id 鍵であって worktree(X)の鍵でないことを動的に pin する（repo_id は cwd 依存＝gen の subshell
  # `cd "$anchor"` 落とし回帰を捕捉。worker は `cd Y && bdw` で書くため Y 鍵でなければ flock がずれ bd write が壊れる）。
  _need_canonical_bdw
  local X Y XLD gen_lf key_x key_y
  X="$(cd "$(mktemp -d)" && pwd -P)"; Y="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$X" -c init.defaultBranch=main init -q; git -C "$Y" -c init.defaultBranch=main init -q
  _mk_beads "$Y"                                    # anchor(Y)側に realistic .beads（gen が grant する側）
  XLD="$BATS_TEST_TMPDIR/xrlocks"; mkdir -p "$XLD"
  run env BDW_LOCK_DIR="$XLD" "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$X" "$Y"
  [ "$status" -eq 0 ]
  gen_lf="$(echo "$output" | jq -r '.sandbox.filesystem.allowWrite[] | select(endswith(".lock"))')"
  key_y="$( (cd "$Y" && BDW_LOCK_DIR="$XLD" "$SCRIPTS/bdw" lock-file) )"   # worker/spawn 経路（cd "$ANCHOR"=Y）
  key_x="$( (cd "$X" && BDW_LOCK_DIR="$XLD" "$SCRIPTS/bdw" lock-file) )"   # worktree 側リポ(X)の鍵
  [ -n "$key_y" ] && [ "$key_y" != "$key_x" ]      # 非 vacuity: 2 リポの repo_id 鍵が異なる
  [ "$gen_lf" = "$key_y" ]                          # gen は anchor(Y)の鍵を grant
  [ "$gen_lf" != "$key_x" ]                         # worktree(X)の鍵を誤 grant しない
  rm -rf "$X" "$Y"
}

@test "spawn(sandbox/sc-lkg): gen は存在しない --anchor(第2引数)を fail-loud で弾く（誤ったパスを黙って grant しない）" {
  run "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh" "$SCRIBE_TEST_CWD" "/nonexistent/anchor/path"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ディレクトリではありません"* ]]
}

@test "spawn(sandbox): SCRIBE_SANDBOX=1 の worker dry-run は settings.local.json 生成を plan に出す（spawn 行は不変）" {
  SCRIBE_SANDBOX=1 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.local.json"* ]]
  [[ "$output" == *"SCRIBE_SANDBOX"* ]]
  [[ "$output" == *"--bd-id un-4nm"* ]]      # 本番 spawn 行は SCRIBE_SANDBOX で変わらない
  [[ "$output" == *"--model opus"* ]]
}

@test "spawn(sandbox/sc-u53): 既定（SCRIBE_SANDBOX 未指定）で sandbox 節を出す（default-on・opt-out 化）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"settings.local.json"* ]]   # 既定で sandbox materialization を plan に出す（旧 default-off から反転・sc-u53）
  [[ "$output" == *"--bd-id un-4nm"* ]]
  [[ "$output" == *"--model opus"* ]]
}

@test "spawn(sandbox/sc-u53): SCRIBE_SANDBOX=0 で sandbox 節を出さない（明示 opt-out で旧 byte 経路へ戻る）" {
  SCRIBE_SANDBOX=0 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"settings.local.json"* ]]
  [[ "$output" == *"--bd-id un-4nm"* ]]
  [[ "$output" == *"--model opus"* ]]
}

@test "spawn(sandbox/sc-u53): SCRIBE_SANDBOX=0(opt-out) と既定(on) で cld-spawn の spawn 行は byte 同一（full-line で pin）" {
  # worktree タイムスタンプ(spawn/un-4nm-HHMMSS)だけ正規化し、spawn 行の完全一致を直接 assert する。
  # sandbox の有無で settings.local.json の生成は変わるが、cld-spawn 起動行（CLD_PATH/launcher）は不変＝
  # 「opt-out で本番 byte 旧経路へ戻る」不変条件を default-on 前提で pin（旧『SCRIBE_SANDBOX 有無』を再定義・sc-u53）。
  SCRIBE_SANDBOX=0 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  optout="$(printf '%s\n' "$output" | grep -F 'cld-spawn --cd' | sed -E 's#un-4nm-[0-9]+#un-4nm-TS#')"
  run "$SPAWN" --dry-run un-4nm   # 既定 = sandbox on
  [ "$status" -eq 0 ]
  defon="$(printf '%s\n' "$output" | grep -F 'cld-spawn --cd' | sed -E 's#un-4nm-[0-9]+#un-4nm-TS#')"
  [ -n "$optout" ]
  [ "$optout" == "$defon" ]   # sandbox 有無で spawn 行は 1 byte も変わらない
}

# ---------- fail-open 硬化（sc-7oj: FO-1 opt-out loud 化 / FO-4 dry-run 可視化 / FO-2 アテステーション）----------
@test "spawn(sc-7oj/FO-4): SCRIBE_SANDBOX=0 の dry-run は opt-out 縮退を可視化する（無防備で走る旨 + sticky 警告）" {
  # 旧 emit_plan は opt-out 時に sandbox 行を一切出さず、--dry-run 監査で「非 sandbox で走る」ことが不可視だった
  # （FO-4 監査ギャップ）。opt-out 縮退行が出ること・env 継承 sticky の注意喚起が入ることを pin する。mutation
  # （emit_plan の opt-out 行を消す）で本テストは RED 化する。既存の「opt-out で sandbox 節を出さない」不変条件
  # （下の byte-identity / settings.local.json 非出力テスト）とは両立する＝opt-out 行は literal settings.local.json を含まない。
  SCRIBE_SANDBOX=0 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"OPT-OUT"* ]]                       # 縮退経路が可視
  [[ "$output" == *"OS sandbox の**外**"* ]]           # 無防備で走る旨を明示
  [[ "$output" == *"sticky"* ]]                        # env 継承で sticky 化する注意喚起
  [[ "$output" != *"settings.local.json"* ]]           # opt-out 行は sandbox 設定生成を含意しない（旧 byte 経路の不変条件を保つ）
}

@test "spawn(sc-7oj/FO-1): SCRIBE_SANDBOX=0 の実経路は stderr に loud opt-out 警告を出す（silent fleet degrade 防止）" {
  # FO-1 本命: 明示 opt-out は env 継承で sticky 化し無警告で fleet 全体を非 sandbox 化しうる。実 spawn（cld-spawn
  # は noop stub）で opt-out 警告が出ること・spawn 自体は成功することを pin する。mutation（FO-1 警告ブロック削除）で
  # 警告 assert が RED 化する。worktree は実生成されるため後始末する（test 388/fallback と同型の実経路テスト）。
  local repo noop wt
  repo="$SCRIBE_TEST_CWD"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$noop" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$noop"
  [ "$status" -eq 0 ]                                   # opt-out は縮退であって失敗ではない（spawn は成功する）
  [[ "$output" == *"OPT-OUT"* ]]                        # loud 警告
  [[ "$output" == *"OS sandbox の**外**"* ]]            # 非 sandbox である旨
  [[ "$output" == *"sticky"* ]]                         # env 継承 sticky の注意喚起
  [ ! -f "$wt/.claude/settings.local.json" ]            # opt-out＝settings.local.json を生成しない（旧 byte 経路）
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------- sandbox dep-preflight（default-on の安全弁・sc-u53）----------
@test "lib(sc-u53): scribe_sandbox_preflight は deps 欠如で非0 + 欠落理由を stdout に返す（PATH 隠蔽で host 非依存）" {
  # PATH を空にして bwrap/socat を不可視化→ command -v が外れ「不在」理由を返す（実 bwrap を host から消さずに検査）。
  run env PATH=/nonexistent /bin/bash -c "source '$LIB'; scribe_sandbox_preflight"
  [ "$status" -ne 0 ]
  [[ "$output" == *"が不在"* ]]
}

@test "preflight(sc-u53): scribe-sandbox-preflight.sh は deps 充足 host で exit 0（欠如 host は skip）" {
  command -v bwrap >/dev/null 2>&1 && command -v socat >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
    && bwrap --ro-bind / / --unshare-user true 2>/dev/null || skip "sandbox deps 未満（この host は対象外）"
  run "$SCRIPTS/scribe-sandbox-preflight.sh"
  [ "$status" -eq 0 ]
}

@test "lib(sc-u53): scribe_sandbox_preflight は jq 不在を sandbox 固有依存として検出する（bwrap/socat 可視のまま jq だけ隠す・round3）" {
  # jq は gen-sandbox-settings.sh の hard 依存＝sandbox 機構固有。bwrap/socat が揃っても jq 不在なら preflight が
  # 非0 を返し materialization で gen が落ち orphan を残す前に止めることを pin（round3 gate confirmed の回帰防止）。
  # bwrap/socat はダミー実行体で command -v を満たすだけ（loop が jq の手前を通過するため・userns 実プローブには
  # 到達しない＝host 非依存）。
  local fakebin="$BATS_TEST_TMPDIR/fakebin"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/bwrap"; chmod +x "$fakebin/bwrap"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/socat"; chmod +x "$fakebin/socat"
  # jq は意図的に置かない。
  run env PATH="$fakebin" /bin/bash -c "source '$LIB'; scribe_sandbox_preflight"
  [ "$status" -ne 0 ]
  [[ "$output" == *"jq が不在"* ]]
}

@test "lib(sc-vae): scribe_sandbox_preflight は canonical bdw 不在を検出する（gen の spawn-time 依存・worktree add 前に止める・REQUIRED-1）" {
  # cutover で gen-sandbox が lock_dir を `scripts/bdw lock-dir`(shim→canonical)で解決する spawn-time hard 依存に
  # なった。bwrap/socat/jq は揃うが canonical bdw 不在(BEADS_BDW=不正パス)の host で preflight が非0+理由を返し、
  # worktree add 後に gen が fail-closed→orphan を残す前に止めることを pin（jq round3 と構造同型の不変条件再違反を塞ぐ）。
  # bwrap/socat/jq はダミーで command -v を満たす（canonical probe は bin loop の後ゆえ到達）。canonical probe は bin
  # loop と userns 実プローブの間に置くため userns には到達しない（host 非依存）。bash/env 解決のため実 PATH を温存する。
  local fakebin="$BATS_TEST_TMPDIR/fakebin-canon"
  mkdir -p "$fakebin"
  local b; for b in bwrap socat jq; do printf '#!/usr/bin/env bash\nexit 0\n' > "$fakebin/$b"; chmod +x "$fakebin/$b"; done
  run env PATH="$fakebin:$PATH" BEADS_BDW=/nonexistent-canonical-xyz /bin/bash -c "source '$LIB'; scribe_sandbox_preflight"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical bdw"* ]]
}

# ---------- canonical bdw 無条件 preflight（sandbox-off zombie worker 防止・sc-ovq）----------
@test "lib(sc-ovq): scribe_canonical_bdw_ok は present で exit0(無出力)・absent で非0+理由（probe の SSOT 抽出）" {
  # 共有関数（spawn の無条件検査 と sandbox preflight が共有する probe の SSOT）。BEADS_BDW で canonical を
  # 切り替え、shim→canonical→lock-dir の chain 全体を実走する（gen と同一経路＝drift しない）。
  # present: lock-dir で exit0 する stub。absent: 不正パス→shim fail-closed(非0)。
  run env BEADS_BDW="$BDW_PRESENT_STUB" /bin/bash -c "source '$LIB'; scribe_canonical_bdw_ok"
  [ "$status" -eq 0 ]
  [ -z "$output" ]                                     # present は無出力（preflight の他項目と同じ出力契約）
  run env BEADS_BDW=/nonexistent-canonical-xyz /bin/bash -c "source '$LIB'; scribe_canonical_bdw_ok"
  [ "$status" -ne 0 ]
  [[ "$output" == *"canonical bdw"* ]]                 # 欠落理由を stdout に machine-readable で返す
}

@test "spawn(sc-ovq): sandbox-off(SCRIBE_SANDBOX=0) でも canonical bdw 不在を spawn 前に検出し fail-loud（worktree を作らない=zombie 防止）" {
  # 非vacuous（mutation）: SCRIBE_SANDBOX=0 は sandbox dep-preflight を **skip** する経路ゆえ、旧コードは
  # この経路で canonical bdw 不在を一切検出せず、plugin 不在 host で sandbox-off worker が起動し全 bd write が
  # shim fail-closed で台帳に残らない zombie worker を生んでいた。本テストは BEADS_BDW=不正パスで bdw を不在に
  # し、SCRIBE_SANDBOX=0 でも spawn が **worktree add の前**に fail-loud で die することを pin する。無条件
  # bdw 検査を spawn から外すと(mutation) このテストは worktree が作られ status!=0 が崩れて RED 化する。
  local repo noop wt
  repo="$SCRIBE_TEST_CWD"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env BEADS_BDW=/nonexistent-canonical-xyz SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$noop" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$noop"
  [ "$status" -ne 0 ]                                  # fail-loud（黙って zombie を起動しない）
  [[ "$output" == *"canonical bdw"* ]]                 # 真因
  [[ "$output" == *"zombie"* ]]                        # zombie worker 化を明示
  [[ "$output" == *"BEADS_BDW"* ]]                     # 復旧 hint
  [ ! -d "$wt" ]                                       # worktree add より前に die＝orphan/zombie を作らない
  [[ "$output" != *"spawned: issue=un-4nm"* ]]         # happy-path 行は出ない
}

@test "spawn(preflight/sc-u53): default-on で deps 欠如かつ FALLBACK 無し → fail-loud で die（worktree を作らない）" {
  local repo failstub noop
  repo="$SCRIBE_TEST_CWD"
  failstub="$(mktemp)"; printf '#!/usr/bin/env bash\nprintf "TESTDEP が不在"; exit 1\n' > "$failstub"; chmod +x "$failstub"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX_PREFLIGHT="$failstub" SCRIBE_CLD_SPAWN="$noop" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$failstub" "$noop"
  [ "$status" -ne 0 ]                                  # fail-loud（黙って無防備に走らせない）
  [[ "$output" == *"sandbox deps 欠如"* ]]             # 理由
  [[ "$output" == *"TESTDEP が不在"* ]]                # preflight の stdout を die メッセージへ織り込む
  [[ "$output" == *"SCRIBE_SANDBOX=0"* ]]              # opt-out 案内
  [[ "$output" == *"SCRIBE_SANDBOX_FALLBACK=1"* ]]     # fallback 案内
  [ ! -d "$repo/.worktrees/spawn/un-4nm-101010" ]      # worktree add より前に die＝orphan を作らない
}

@test "spawn(preflight/sc-u53): deps 欠如 + SCRIBE_SANDBOX_FALLBACK=1 → 警告して非 sandbox で続行（settings 生成せず）" {
  local repo failstub noop wt
  repo="$SCRIBE_TEST_CWD"
  failstub="$(mktemp)"; printf '#!/usr/bin/env bash\nprintf "TESTDEP が不在"; exit 1\n' > "$failstub"; chmod +x "$failstub"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX_PREFLIGHT="$failstub" SCRIBE_SANDBOX_FALLBACK=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$failstub" "$noop"
  [ "$status" -eq 0 ]                                  # 続行（spawn は成功する）
  [[ "$output" == *"SCRIBE_SANDBOX_FALLBACK=1"* ]]     # 警告に明示
  [[ "$output" == *"OS sandbox の外"* ]]               # 非 sandbox である旨を loud に警告
  [ ! -f "$wt/.claude/settings.local.json" ]           # 非 sandbox＝settings.local.json を生成しない
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------- sandbox /tmp read-only 互換（sc-3lj・sc-498 G1）----------
# sandbox 下では CC が /tmp を read-only にする。(A) grill-consult の context 一時ファイルが /tmp 直書きだと
# worker の bats 自己点検（sandbox 内）で mktemp が die し RED 化する→$BATS_TEST_TMPDIR(bats 保証の書込可)へ寄せた。
# (B) env-probe verify の --also-tmp が /tmp sentinel を要求し read-only で誤 ENV_DEGRADED→sandbox 時は落とす。
@test "tests(sc-3lj): bats に sandbox で die する /tmp 直書き(mktemp の /tmp テンプレート)が残っていない" {
  # CC sandbox は \$TMPDIR を session temp へ向け cwd+session-temp 外の書込みを拒否する。明示 /tmp への mktemp は
  # worker の sandbox bats 自己点検で die し false-RED を生む(sc-498 worker2 実証)。実 file を grep し本ガード自身の
  # 行は GUARD-SELF-SENTINEL で除外する(自己マッチ防止)。`! grep` でなく run+空文字 assert で errexit 免除の罠も避ける。
  run bash -c 'grep -nE "[$][(]mktemp [^)]*/tmp/" "$1" | grep -v GUARD-SELF-SENTINEL' _ "$BATS_TEST_DIRNAME/scribe-tools.bats"  # GUARD-SELF-SENTINEL
  [ "$output" = "" ]
  # grill-consult の context 一時が $BATS_TEST_TMPDIR ベースに置換されていることの正の確認（置換が実際に入った証跡）。
  grep -q 'BATS_TEST_TMPDIR/scribe-ctx' "$BATS_TEST_DIRNAME/scribe-tools.bats"
}

@test "spawn(sc-3lj): SCRIBE_SANDBOX=1 の worker prompt は env-probe verify から --also-tmp を落とす（read-only /tmp 誤 ENV_DEGRADED 回避）" {
  SCRIBE_SANDBOX=1 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *'scribe-env-probe.sh" verify'* ]]   # env-probe verify 行は在る
  [[ "$output" != *"--also-tmp"* ]]                     # sandbox では --also-tmp 無し（worktree sentinel で十分）
}

@test "spawn(sc-3lj/sc-u53): 非 sandbox（SCRIBE_SANDBOX=0 opt-out）の worker prompt は env-probe verify に --also-tmp を保つ（後方互換）" {
  SCRIBE_SANDBOX=0 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"--also-tmp"* ]]
}

# ---------- zombie fallback の pane 可視 sentinel（sc-c7c・folio-nufl・dogfood 済）----------
# 全ツール死（Bash/Read が空応答＝bdw で STATUS: blocked を書けない zombie 変種・protocol §6 第 3 変種）では
# admin 検知網 3 信号（gate-pending / STATUS notes / 窓消失）が全て沈黙する。folio-nufl 実測で turn の
# text 出力だけは pane に残った → worker prompt に「blocked を書けない時は行頭定型 SCRIBE-ENV-DEGRADED: を
# 出力して停止」を焼き、admin が capture-pane + regex で機械的に拾えるようにする（Layer1 の pane fallback）。
# dogfood（sc-adr drill・lock 鍵 chmod 000 で bd write 封鎖）で確定: CC TUI は assistant text を先頭スペース
# インデントで描画するため実 sentinel は '  SCRIBE-ENV-DEGRADED: …' となり厳格 ^ は偽陰性 → 検知 regex は
# 行頭空白許容形 ^[[:space:]]*SCRIBE-ENV-DEGRADED: が正（prompt にこの正しい契約が焼かれることを pin）。
@test "spawn(sc-c7c): worker prompt に zombie fallback（SCRIBE-ENV-DEGRADED: <実ID> 行頭定型 + dogfood 確定検知 regex 契約）が焼かれる" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *'SCRIBE-ENV-DEGRADED: un-4nm'* ]]                 # 定型に実 issue-id が展開される（$ID のまま残らない）
  [[ "$output" == *'^[[:space:]]*SCRIBE-ENV-DEGRADED:'* ]]          # dogfood 確定の空白許容検知 regex が契約として明記される
  [[ "$output" == *'tail -n'* ]]                                     # prompt echo 除外の tail 窓検知が契約に含まれる
}

@test "spawn(sc-c7c): 停止許可の規律行が pane sentinel 停止を第 2 例外として明記する（旧「ENV_DEGRADED 検出時のみ」へ巻き戻すと RED）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *'pane sentinel 停止'* ]]
  [[ "$output" != *'ENV_DEGRADED 検出時のみ'* ]]
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

# ---------- 脅威モデルの正直な文書化（sc-451: TB-1 read+egress 非対象 / TB-2 admin ingest 非対称）----------
@test "sandbox(sc-451): 脅威モデル SSOT（sandbox README）が『守る/守らない』を正直に持ち、protocol/design がポインタで整合する" {
  # security-audit TB-1/TB-2: docs が『封じる』と言うとき read/egress が非対象である旨・admin ingest 非対称が
  # 不明確だった。SSOT（sandbox README「脅威モデル」節）の存在と核心文言、protocol.md / scribe-design.md の
  # ポインタ整合を pin する。mutation（節削除・over-claim への巻き戻し・ポインタ喪失）で RED 化する。
  local readme="$SCRIPTS/sandbox-spike/README.md" proto="$REPO_ROOT/docs/protocol.md" design="$REPO_ROOT/docs/scribe-design.md"
  # SSOT: 節見出し + TB-1（read host 全体・egress 非封鎖）+ TB-2（ingest 非対称）+ 完全隔離でない旨。
  grep -q "^## 脅威モデル" "$readme"
  grep -q "read は host 全体" "$readme"
  grep -q "network egress は非封鎖" "$readme"
  grep -q "ingest 非対称" "$readme"
  grep -q "完全隔離ではない" "$readme"
  # protocol.md: 正直な境界 bullet + SSOT ポインタ（本文の重複でなく要約 + 参照）。
  grep -q "完全隔離ではない" "$proto"
  grep -q "read は host 全体" "$proto"
  grep -q 'sandbox-spike/README.md.*脅威モデル' "$proto"
  # scribe-design.md: §6 脅威モデル（A/B）へ sandbox 境界が接続され SSOT を指す。
  grep -q "Bash write 境界" "$design"
  grep -q 'sandbox-spike/README.md.*脅威モデル' "$design"
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
  [[ "$output" != *"scribe-env-probe"* ]]
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

# ---------- spawn: 対話 tool 物理封鎖（orch-4dm / H5・無人 worker cell）----------
@test "spawn: worker cell は cld-spawn へ --disallowed-tools \"AskUserQuestion,ExitPlanMode\" を渡す（H5・無人 window の対話 tool 物理封鎖）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  # カンマ連結の **単一トークン**（空白 split しない＝1 argv verbatim）を引用付きで表示。cc-session gate round-1 で
  # 分割 fail-open が CONFIRMED ゆえ、value を分割せず 1 要素で透過することが load-bearing。
  # 注: これは dry-run(emit_plan) の [plan] 表示検査。実 invocation 行の quoting は下の source-guard test が守る
  #     （dry-run 文字列では実 argv 境界を証明できないため・gate finding orch-4dm-review [low]）。
  [[ "$output" == *'--disallowed-tools "AskUserQuestion,ExitPlanMode"'* ]]
  # PROMPT より前に置く（cld-spawn が claude 末尾 <tools...> へ再配置する契約・起動行内順序は PROMPT 前で可）。
  cld_line="$(printf '%s\n' "$output" | grep -F 'cld-spawn --cd')"
  [[ "$cld_line" == *'--disallowed-tools "AskUserQuestion,ExitPlanMode"'*'<task prompt>'* ]]
}

@test "spawn: 実 cld-spawn invocation 行は --disallowed-tools 値を二重引用する（1 argv 保証・unquote 退行を静的に禁止・gate finding orch-4dm-review [low]）" {
  # dry-run は emit_plan（別関数）を叩くため実 invocation 行(scribe-spawn.sh の \"\$CLD_SPAWN\" … 行)の quoting を
  # 証明できない。実 invocation 行は worktree add / sandbox / tmux 依存で hermetic に駆動できない（本ファイルは
  # 実 spawn をしない設計）。そこで source を静的 assert し「値が unquote されると内部空白 spec が split して
  # silent fail-open」する退行を guard する（cc-session gate round-1 CONFIRMED の fail-open 再来を封じる）。
  run grep -F -- '--disallowed-tools "$WORKER_DISALLOWED_TOOLS"' "$SPAWN"
  [ "$status" -eq 0 ]
  # 実起動行（"$CLD_SPAWN" で始まる行）にその引用形が在ることまで固定（dry-run echo の \" 形と別物であることを担保）。
  run bash -c 'grep -E "^\"\\\$CLD_SPAWN\".*--disallowed-tools \"\\\$WORKER_DISALLOWED_TOOLS\"" "$1"' _ "$SPAWN"
  [ "$status" -eq 0 ]
}

@test "spawn: consult は cld-spawn launch 行に --disallowed-tools を渡さない（plain + grill-consult 両方・worker との非対称・H5 は worker cell 限定）" {
  # sibling consult test(404/422/435)と同じく launch 行(cld-spawn --cd)に grep を絞る（output 全体でなく起動行を検査）。
  # plain consult
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  cld_line="$(printf '%s\n' "$output" | grep -E 'cld-spawn --cd')"
  [[ -n "$cld_line" ]]
  [[ "$cld_line" != *"--disallowed-tools"* ]]
  # grill-consult(--context brief)も同一 launch 行を共有＝封鎖されないことを明示カバー（gate finding orch-4dm-review [nit]）。
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
  printf 'BRIEF\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  cld_line="$(printf '%s\n' "$output" | grep -E 'cld-spawn --cd')"
  [[ -n "$cld_line" ]]
  [[ "$cld_line" != *"--disallowed-tools"* ]]
}

@test "spawn: worker は consult env（SCRIBE_ROLE=consult）を注入しない（worker 用 env-file は SCRIBE_WORKER=1・sc-649）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"SCRIBE_ROLE=consult"* ]]   # worker は consult role env を持たない
  [[ "$output" == *"SCRIBE_WORKER=1"* ]]        # worker 用 env-file は SCRIBE_WORKER=1（sc-649・consult とは別物）
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

# ---------- spawn: consult 既定 model = fable（sc-9q6・利用不可時 opus fallback） ----------
@test "spawn: consult 既定 model は fable（--model 未指定・dry-run は preflight しない・sc-9q6）" {
  run "$SPAWN" --dry-run --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"--model claude-fable-5"* ]]
  # dry-run は API を叩かず、本起動時 preflight の予告行だけ出す（副作用ゼロ維持）。
  [[ "$output" == *"preflight"* ]]
}

@test "spawn: consult --model 明示は fable 既定より優先される（sc-9q6）" {
  run "$SPAWN" --dry-run --consult --model opus un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"--model opus"* ]]
  [[ "$output" != *"--model claude-fable-5"* ]]
  # 明示時は preflight 予告も出ない（既定解決の経路に入らない）。
  [[ "$output" != *"preflight"* ]]
}

@test "spawn: consult 実起動で fable preflight 失敗 → opus へ loud fallback（SCRIBE_FABLE_PREFLIGHT=0 注入・sc-9q6）" {
  noop="$BATS_TEST_TMPDIR/noop-cld-spawn"
  printf '#!/bin/bash\necho "cld-spawn-args: $*"\n' > "$noop"; chmod +x "$noop"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_FABLE_PREFLIGHT=0 "$SPAWN" --consult un-consult
  [ "$status" -eq 0 ]
  # spawn 行と結果行の両方が opus（fallback 済み）になり、WARN が loud に出る（silent 降格禁止）。
  [[ "$output" == *"--model opus"* ]]
  [[ "$output" == *"model=opus"* ]]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" != *"claude-fable-5"* ]]
}

@test "spawn: consult 実起動で fable preflight 成功 → fable のまま起動（SCRIBE_FABLE_PREFLIGHT=1 注入・sc-9q6）" {
  noop="$BATS_TEST_TMPDIR/noop-cld-spawn"
  printf '#!/bin/bash\necho "cld-spawn-args: $*"\n' > "$noop"; chmod +x "$noop"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_FABLE_PREFLIGHT=1 "$SPAWN" --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"--model claude-fable-5"* ]]
  [[ "$output" == *"model=claude-fable-5"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "spawn: consult --model 明示時は preflight を実行しない（SCRIBE_FABLE_PREFLIGHT=0 でも fallback しない・sc-9q6）" {
  # 明示 --model claude-fable-5 はユーザーの確定指定＝preflight 対象外（fallback で上書きしない）。
  noop="$BATS_TEST_TMPDIR/noop-cld-spawn"
  printf '#!/bin/bash\necho "cld-spawn-args: $*"\n' > "$noop"; chmod +x "$noop"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_FABLE_PREFLIGHT=0 "$SPAWN" --consult --model claude-fable-5 un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"--model claude-fable-5"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "spawn: worker の既定 model は opus のまま（consult の fable 既定が worker へ漏れない・sc-9q6）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"--model opus"* ]]
  [[ "$output" != *"claude-fable-5"* ]]
}

# ---------- spawn: fable_available 実路（SCRIBE_CLAUDE_BIN stub 注入・rc 述語の境界を実証・sc-9q6 gate 指摘） ----------
# SCRIBE_FABLE_PREFLIGHT を渡さず実路（timeout + rc 述語 [[ rc==0 || rc==124 ]]）を駆動する。
# stub claude が exit code を返す＝timeout(1) は子の exit code を透過するため、受理/棄却境界を決定的に再現できる。
_make_claude_stub() { # $1=exit code
  local stub="$BATS_TEST_TMPDIR/claude-stub-$1"
  printf '#!/bin/bash\nexit %s\n' "$1" > "$stub"; chmod +x "$stub"; echo "$stub"
}
_make_noop_cld_spawn() {
  local noop="$BATS_TEST_TMPDIR/noop-cld-spawn"
  printf '#!/bin/bash\necho "cld-spawn-args: $*"\n' > "$noop"; chmod +x "$noop"; echo "$noop"
}

@test "spawn: fable_available 実路 rc=0（即成功）→ fable 維持（sc-9q6）" {
  noop="$(_make_noop_cld_spawn)"; stub="$(_make_claude_stub 0)"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_CLAUDE_BIN="$stub" "$SPAWN" --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=claude-fable-5"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "spawn: fable_available 実路 rc=124（timeout=受理）→ fable 維持（正常 fable は 60s+ ゆえ timeout を利用可とみなす・sc-9q6）" {
  # rc=124 を不可扱いに退行させると正常 fable が恒常 opus 降格になる＝この境界が本 feature の核心。
  noop="$(_make_noop_cld_spawn)"; stub="$(_make_claude_stub 124)"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_CLAUDE_BIN="$stub" "$SPAWN" --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=claude-fable-5"* ]]
  [[ "$output" != *"WARN"* ]]
}

@test "spawn: fable_available 実路 rc=1（fast fail=利用不可）→ opus へ loud fallback（sc-9q6）" {
  noop="$(_make_noop_cld_spawn)"; stub="$(_make_claude_stub 1)"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_CLAUDE_BIN="$stub" "$SPAWN" --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=opus"* ]]
  [[ "$output" == *"WARN"* ]]
  [[ "$output" != *"model=claude-fable-5"* ]]
}

@test "spawn: fable_available 実路 rc=127（bin 不在相当）→ opus へ loud fallback（sc-9q6）" {
  noop="$(_make_noop_cld_spawn)"; stub="$(_make_claude_stub 127)"
  run env SCRIBE_CLD_SPAWN="$noop" SCRIBE_CLAUDE_BIN="$stub" "$SPAWN" --consult un-consult
  [ "$status" -eq 0 ]
  [[ "$output" == *"model=opus"* ]]
  [[ "$output" == *"WARN"* ]]
}

@test "spawn: prompt テンプレに cell-quality WF / receivedArgs / bdw / 禁止が含まれる" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"cell-quality"* ]]
  [[ "$output" == *"receivedArgs"* ]]
  [[ "$output" == *"bdw"* ]]
  [[ "$output" == *"bd create"* ]]
}

# sc-46h: worker は autonomous に動く＝確認待ちで停止しない。sc-498 litmus で worker1 が「どうしますか?」と
# 確認待ち idle 化し fleet を詰まらせた穴を prompt 規律で塞ぐ。停止は ENV_DEGRADED 時のみ・監視ノイズで止まらない。
@test "spawn(sc-46h): worker prompt に autonomous 規律(確認待ち停止禁止・停止は ENV_DEGRADED と pane sentinel の 2 例外のみ)が焼ける" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"autonomous 規律"* ]]
  [[ "$output" == *"確認・許可・指示を待って停止してはならない"* ]]
  # 停止条件は ENV_DEGRADED 検出＋pane sentinel（sc-c7c で「のみ」→2 例外へ拡張。autonomy が env 健全性
  # gate / zombie fallback の停止と矛盾しないことの pin）。独立文で
  # 各 [[ ]] を errexit に効かせる（`&&` 連結は errexit 免除で fail-open になりうる＝sc-3lj gate の教訓）。
  [[ "$output" == *"停止してよいのは"* ]]
  [[ "$output" == *"ENV_DEGRADED 検出時"* ]]
  # 実体確認の bd は anchor cd 付き（worktree から bare bd show は bd graph を解決しない・sc-46h gate blocking）。
  # $ANCHOR は heredoc で展開されるため、修正で入れた安定 prose で pin する。
  [[ "$output" == *"bd graph は anchor 所在ゆえ worktree から bare"* ]]
}

# sc-46h: autonomous 規律の本文 SSOT は docs/protocol.md §2（ツール側だけに最重要規律の正本を持たない＝
# リポの SSOT 契約。scribe-spawn ヘッダ「道具は規約をコード化するだけ」を守る）。docs からの脱落を pin する。
@test "docs(sc-46h): protocol.md §2 に autonomous 規律が SSOT 化されている" {
  grep -q 'autonomous 規律' "$REPO_ROOT/docs/protocol.md"
  grep -q '確認・許可・指示を待って停止してはならない' "$REPO_ROOT/docs/protocol.md"
  # 停止条件(load-bearing)も docs 側で pin する（spawn 側 assert と対称・docs だけ停止規範が drift しても捕捉）。
  grep -q '停止してよいのは' "$REPO_ROOT/docs/protocol.md"
  grep -q 'ENV_DEGRADED' "$REPO_ROOT/docs/protocol.md"
}

# sc-c7c: dogfood 通過後の §6 昇格を pin する。zombie 変種の pane sentinel（定型・確定検知 regex・
# tail 窓検知コマンド）が protocol §6 の regulatory SSOT に成文化され、§2 停止規律が 2 例外化された
# ことを docs 側で pin（成文化の規律＝dogfood 済みのみ protocol に載る。昇格を巻き戻すと RED）。
@test "docs(sc-c7c): protocol §6 に zombie pane sentinel が成文化され §2 停止規律が 2 例外化されている" {
  local proto="$REPO_ROOT/docs/protocol.md"
  # §6: sentinel 定型 + dogfood 確定の空白許容検知 regex + prompt echo 除外の tail 窓検知。
  grep -q 'SCRIBE-ENV-DEGRADED' "$proto"
  grep -q '\^\[\[:space:\]\]\*SCRIBE-ENV-DEGRADED:' "$proto"   # 厳格 ^ でなく空白許容形（偽陰性回避・dogfood verified）
  grep -q 'capture-pane' "$proto"
  # sentinel は主網の代替でなく追加信号である旨（fail-closed 主網 = idle-at-prompt × 0-commit）。
  grep -q '追加信号であって主網の代替ではない' "$proto"
  # §2: 停止許可が「のみ」1 条件から pane sentinel を含む 2 例外へ更新された（巻き戻し検出）。
  grep -q '停止してよいのは 2 例外のみ' "$proto"
}

# 上の positive テストは cell-quality/receivedArgs/bdw のみ assert し、build_prompt が焼く
# selftest-args 呼出（cell-quality の自己点検 args 1 コマンド化）を pin しない＝行の脱落/改変が
# 緑通過する純 test-gap（sc-e22）。dry-run prompt 出力に selftest-args の核要素が焼けることを pin する。
@test "spawn(sc-e22): worker prompt に selftest-args 注入（helper/anchor/self-test/selfTestCmd/autoFix/doImplement）が焼ける" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"scribe-selftest-args.sh"* ]]   # 自己点検 args を 1 コマンド化する helper
  [[ "$output" == *"--anchor"* ]]                   # bd graph 所在＝worktree cwd で解決せず必須（省くと die）
  [[ "$output" == *"--self-test"* ]]                # selfTestCmd を渡すフラグ
  [[ "$output" == *"selfTestCmd"* ]]                # selfTestCmd 必須の明示
  [[ "$output" == *"autoFix"* ]]                    # autoFix=true 固定（review→自動 fix を回す）
  [[ "$output" == *"doImplement"* ]]                # doImplement/doPlan=false 固定（gate review のみ・実装/計画しない）
}

# sc-sau: worker prompt に env 健全性 gate（scribe-env-probe.sh の plant/verify + STATUS:blocked 配線）が焼ける。
# folio 0264028f の「env 劣化で self-verify 誤 PASS」を worker 自身が done 前に検出する fail-closed gate。
@test "spawn(sc-sau): worker prompt に env-probe gate（plant/verify/--also-tmp/STATUS:blocked）が焼ける" {
  # --also-tmp は非 sandbox 面ゆえ opt-out 経路で確認（default-on では sandbox 化で --also-tmp が落ちる・sc-u53）。
  SCRIBE_SANDBOX=0 run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"scribe-env-probe.sh"* ]]        # env 健全性 probe helper
  [[ "$output" == *"plant"* ]]                       # sentinel を植える
  [[ "$output" == *"verify"* ]]                      # 別 Bash 呼出しで読み戻す（cross-call 永続）
  [[ "$output" == *"--also-tmp"* ]]                  # /tmp 面（folio の現場）も検査
  [[ "$output" == *"ENV_DEGRADED"* ]]                # 劣化判定で分岐
  [[ "$output" == *"STATUS: blocked"* ]]             # 劣化時は done を申告せず blocked を bdw で書く
  # review#1 critical 回帰: --base はリテラル HEAD でなく spawn 時点の解決済み SHA を焼く
  # （HEAD..HEAD=常に 0 commit で健全 worker を誤 blocked にしない・un-k02 同型）。
  [[ "$output" != *"--base HEAD"* ]]
  [[ "$output" =~ --base[[:space:]][0-9a-f]{40} ]]
}

# sc-5wu: build_prompt が焼く scribe plugin script 参照（selftest-args/bdw）が相対パスだと、worker cwd=
# worktree・consult cwd=anchor が downstream repo の場合に解決しない（plugin は ${CLAUDE_PLUGIN_ROOT}/scripts
# にあり PATH 未配置）。scribe 自己 dev では anchor/worktree が scribe repo ゆえ偶然 scripts/ が在り緑通過する
# test-gap。$SCRIPT_DIR（spawn 自身の dir＝plugin scripts dir）補間で絶対パスを emit することを pin する。
@test "spawn(sc-5wu): worker prompt の scribe script 参照は絶対パス（\$SCRIPT_DIR 補間）で worker cwd 非依存" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  # selftest-args helper / bdw が先頭 / 付き絶対パスで焼かれる（相対 scripts/… でない）。
  [[ "$output" == *"/scripts/scribe-selftest-args.sh"* ]]
  [[ "$output" == *"/scripts/bdw"* ]]
  # 退行検出: 相対参照（backtick 直後・&& 直後の bare scripts/…）へ戻していないこと。
  [[ "$output" != *'`scripts/scribe-selftest-args.sh'* ]]
  [[ "$output" != *"&& scripts/bdw"* ]]
  # 絶対パスは spawn 自身の plugin scripts dir に解決される（setup の $SELFTEST/$BDW と一致）。
  [[ "$output" == *"$SELFTEST"* ]]
  [[ "$output" == *"$BDW"* ]]
  # 空白安全: emit は $ANCHOR と同様クォート補間する（SCRIPT_DIR にスペースがあっても語分割しない・gate finding）。
  [[ "$output" == *"\"$SELFTEST\""* ]]
  [[ "$output" == *"\"$BDW\""* ]]
}

# ---------- spawn: grill-consult モード（--context・§7 needs-user regime・sc-cuw 再編）----------
# --context は「焼いて死ぬ pre-bake」から「admin 集約 brief を grill 材料に受け取りユーザーと対話 grill する
# grill-consult」へ意味が変わった。pre-bake 自体は admin が回す dynamic Workflow へ移管(consult から撤去)。
@test "spawn(grill-consult): --context + grill-issue で brief 焼き込み + bd notes handoff(bdw 経由)が prompt に注入される" {
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
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
  # sc-5wu: consult の bdw 参照も絶対パス($SCRIPT_DIR 補間)で anchor=downstream でも解決する。
  [[ "$output" == *"$BDW"* ]]
  [[ "$output" == *"\"$BDW\""* ]]   # 空白安全クォート(gate finding)
  [[ "$output" != *"&& scripts/bdw"* ]]
  [[ "$output" == *"--claim"* ]]
  [[ "$output" == *"--append-notes"* ]]
  [[ "$output" == *"bd show un-consult"* ]]   # admin が real-time 監視
  [[ "$output" == *"限定緩和"* ]]
  # 旧 doobidoo handoff regime(tag/conversation_id)は撤去された(brief は WF 返り値・handoff は bd notes)。
  [[ "$output" != *"scribe-brief-"* ]]
  [[ "$output" != *"conversation_id"* ]]
}

# sc-3pq L3=A案(grill 確定 2026-06-24): grill-consult window は consult-<grill-issue> で id 紐付けし、
# fleet-monitor / degraded watcher が「どの grill-issue の consult が沈黙したか」を完全一致で拾えるようにする。
# plain consult(--context 無し)は consult-HHMMSS のまま(test 223/236 が保証)＝この id 命名は grill-consult 限定。
@test "spawn(grill-consult): window 名は consult-<grill-issue> で id 紐付けする(sc-3pq A案・fleet-monitor 照合)" {
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  cld_line="$(echo "$output" | grep -E 'cld-spawn --cd')"
  # grill-consult は consult-<grill-issue>(=consult-un-consult)＝wt-<id> と同型の id 完全一致命名。
  [[ "$cld_line" == *"--window-name consult-un-consult"* ]]
  # HHMMSS フォールバックには落ちない(grill-issue があるので id 命名する)。
  re='--window-name consult-[0-9]{6}'
  [[ ! "$cld_line" =~ $re ]]
  # reuse 偽成功の構造封鎖は --force-new(window 名の毎回一意性に非依存・中断リカバリ再 spawn でも新規保証)。
  [[ "$cld_line" == *"--force-new"* ]]
  # consult 設計どおり --bd-id は渡さない(window 名に id を焼くだけ)。
  [[ "$cld_line" != *"--bd-id"* ]]
}

# sc-qos: 復路の完了シグナル形式化。grill-consult が STATUS 行(grilling/done/blocked)で
# admin に完了・中断を感知させ、決定は逐次 append する(バッチ厳禁)。
@test "spawn(grill-consult): STATUS 行規約(grilling/done/blocked)と逐次 append が prompt に注入される(sc-qos)" {
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -eq 0 ]
  # admin が完了・中断を感知する STATUS 行規約(D2)。
  [[ "$output" == *"STATUS: grilling"* ]]
  [[ "$output" == *"STATUS: done"* ]]
  [[ "$output" == *"STATUS: blocked"* ]]
  # 逐次 append(バッチ厳禁)の明示補強(D4 床)。
  [[ "$output" == *"逐次"* ]]
}

@test "spawn(grill-consult): read-only 限定緩和は厳密 — 自 grill-issue notes のみ可・graph 構造と tracked コードは不可" {
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
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
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
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
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
  printf 'x\n' > "$ctx"
  export SCRIBE_GRILL_SKILL=/tmp/scribe-no-such-grill-skill.md
  run "$SPAWN" --dry-run --consult --context "$ctx" un-consult
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SKILL.md"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): F2 は構造解消 — 第三者データ出典は保険として残り旧 pre-bake 専任文言は消える" {
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
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
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
  printf 'x\n' > "$ctx"
  run "$SPAWN" --dry-run --context "$ctx" un-4nm
  rm -f "$ctx"
  [ "$status" -ne 0 ]
  [[ "$output" == *"consult"* ]]
  [[ "$output" != *"[plan]"* ]]
}

@test "spawn(grill-consult): --context は grill-issue id 必須で fail-loud(handoff 先の bd notes を定められない)" {
  ctx="$(mktemp "$BATS_TEST_TMPDIR/scribe-ctx-XXXXXX.md")"
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
  dir="$(mktemp -d "$BATS_TEST_TMPDIR/scribe-ctx-dir-XXXXXX")"
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
  # sc-u53: cld-spawn 失敗→orphan は sandbox と直交ゆえ SCRIBE_SANDBOX=0(opt-out)で非 sandbox 経路に固定する
  #（default-on の preflight/materialization を通さない＝host 非依存 + 実 $HOME/.cache/bdw-locks 汚染なし）。
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$fail_stub" SCRIBE_HHMMSS=101010 \
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
  _need_canonical_bdw  # sc-vae/sc-mcx: 実 gen が bdw lock-file(shim→canonical・OG-4)を呼ぶゆえ plugin 不在 host は skip(SHOULD a・host 非依存維持)
  local repo wt noop
  repo="$SCRIBE_TEST_CWD"   # setup() の temp git repo（init コミット済み）
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  _mk_beads "$repo"   # sc-nd6: gen が runtime サブパスを列挙するため anchor に realistic .beads が要る
  # sc-u53: default-on の dep-preflight を passing stub(noop=exit0)で stub し host 非依存にする
  #（materialization 経路の検証が host の bwrap/socat/userns 有無に依存しないように）。
  run env SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_SANDBOX_PREFLIGHT="$noop" BDW_LOCK_DIR="$BATS_TEST_TMPDIR/rt" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$noop"
  [ "$status" -eq 0 ]
  # 物理生成された settings.local.json は valid JSON で sandbox contract（failIfUnavailable + .beads runtime サブパス・sc-nd6）を持つ。
  [ -f "$wt/.claude/settings.local.json" ]
  run jq -e --arg b "$repo/.beads" '.sandbox.enabled == true and .sandbox.failIfUnavailable == true and (.sandbox.filesystem.allowWrite | index($b+"/embeddeddolt")!=null) and (.sandbox.filesystem.allowWrite | index($b)==null)' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  # atomic mv 後に temp ファイル(.settings.XXXXXX)が残っていない（mv→cp 退化を捕捉）。
  run bash -c "ls \"$wt/.claude/\".settings.* 2>/dev/null | wc -l | tr -d ' '"
  [ "$output" = "0" ]
  # worktree の git exclude 追記で worker の git add -A が settings.local.json を巻き込まない（ephemeral 維持・load-bearing）。
  run git -C "$wt" check-ignore -q .claude/settings.local.json
  [ "$status" -eq 0 ]
  # sc-mcx(OG-4): runtime grant は lock **dir** 丸ごとでなく自リポの flock 鍵 `<lock_dir>/bd-write-<repo_id>.lock`
  # (file 単位)へ狭化されている。BDW_LOCK_DIR=$BATS_TEST_TMPDIR/rt を base に repo_id は不定ゆえ前方一致 + .lock 末尾で検査。
  run jq -e --arg ld "$BATS_TEST_TMPDIR/rt" '.sandbox.filesystem.allowWrite | map(startswith($ld+"/bd-write-") and endswith(".lock")) | any' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  # lock **dir** 自体は allowWrite に入らない（同 dir 内の他リポ鍵に触れない＝OG-4 の核心・wholesale grant 回帰ガード）。
  run jq -e --arg ld "$BATS_TEST_TMPDIR/rt" '.sandbox.filesystem.allowWrite | index($ld) == null' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  # sc-da0/sc-mcx: bwrap の bind-before-exist 対策で spawn が lock **鍵 file** を pre-create(touch)する（grant 済 path が実在）。
  run bash -c "ls '$BATS_TEST_TMPDIR/rt'/bd-write-*.lock"
  [ "$status" -eq 0 ]
  # dir 化でなく通常ファイルとして先在する（flock の `exec 9>file` が Is-a-directory で壊れない回帰ガード）。
  _lf="$(ls "$BATS_TEST_TMPDIR/rt"/bd-write-*.lock | head -1)"; [ -f "$_lf" ]
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

@test "spawn(sandbox/sc-lkg): cross-repo 実経路で settings.local.json の allowWrite が真の --anchor の .beads を指す（scribe-spawn の forwarding regress を integration 層で捕捉）" {
  # sc-lkg の欠陥本体は scribe-spawn が真の --anchor を gen へ渡さないこと。gen 単体テスト(上)は
  # gen の挙動を pin するが、scribe-spawn:555 が旧 `"$SANDBOX_GEN" "$WORKTREE"` へ regress しても
  # gen 単体テストは緑のまま＝silent 再発しうる。ここは **実 gen を scribe-spawn 経由で実走**し、
  # repo≠anchor（cross-repo cell）で allowWrite[0] が真の anchorY/.beads になることを assert する。
  local repoX anchorY wt noop
  repoX="$SCRIBE_TEST_CWD"                          # worktree を作るリポ（= --repo X）
  anchorY="$(cd "$(mktemp -d)" && pwd -P)"          # 真の bd graph（= --anchor Y・repo X とは別）
  git -C "$anchorY" -c init.defaultBranch=main init -q
  git -C "$anchorY" config user.email t@e; git -C "$anchorY" config user.name t
  git -C "$anchorY" commit -q --allow-empty -m init
  _mk_beads "$anchorY"   # sc-nd6: gen が runtime サブパスを列挙するため真 anchor に realistic .beads が要る
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repoX/.worktrees/spawn/un-4nm-101010"
  # 実 gen を走らせる（gen は stub しない）。preflight/cld-spawn のみ noop・bdw は present stub で host 非依存。
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_SANDBOX_PREFLIGHT="$noop" \
      BDW_LOCK_DIR="$BATS_TEST_TMPDIR/rt" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repoX" --anchor "$anchorY" un-4nm
  rm -f "$noop"
  [ "$status" -eq 0 ]
  [ -f "$wt/.claude/settings.local.json" ]
  # 核心 assert: 真の anchorY/.beads runtime を grant（repoX/.beads を一切 grant しない＝forwarding が効いている・sc-nd6 で shape 更新）。
  run jq -e --arg y "$anchorY/.beads" '.sandbox.filesystem.allowWrite | index($y+"/embeddeddolt")!=null' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  run jq -e --arg x "$repoX/.beads" '.sandbox.filesystem.allowWrite | (map(startswith($x+"/")) | any | not)' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  git -C "$repoX" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$anchorY"
}

@test "spawn(sandbox/sc-mcx・OG-4): cross-repo 実 bdw で lock 鍵 file が anchor の repo_id で {gen grant / spawn pre-create / worker 経路} 3者 byte 一致（spawn 側 cd \$ANCHOR 落とし回帰を捕捉）" {
  # 受入(OG-4)の中核 modality =『repo_id を subshell `cd anchor` で consume し cross-repo(X≠Y)で worker の bd write と
  # byte 一致』。これを genuine な X≠Y(2 実リポ + 実 canonical bdw)で動的に叩く。上の sc-lkg 実経路テストは
  # BDW_PRESENT_STUB(定数 `bd-write-stub.lock`・cwd/BDW_LOCK_DIR 無視)ゆえ repo_id 導出を再現できず lock 鍵に何も
  # assert しない。ここは **実 canonical bdw**(shim→canonical)を使い repo_id を genuine に導出させる(present stub
  # 不使用ゆえ _need_canonical_bdw で plugin 不在 host は skip=host 非依存維持)。
  _need_canonical_bdw
  local repoX anchorY wt noop ld gen_lf worker_lf repoX_lf
  repoX="$SCRIBE_TEST_CWD"                          # worktree を作るリポ（= --repo X）
  anchorY="$(cd "$(mktemp -d)" && pwd -P)"          # 真の bd graph（= --anchor Y・X とは別 git common-dir ゆえ repo_id が異なる）
  git -C "$anchorY" -c init.defaultBranch=main init -q
  git -C "$anchorY" config user.email t@e; git -C "$anchorY" config user.name t
  git -C "$anchorY" commit -q --allow-empty -m init
  _mk_beads "$anchorY"   # sc-nd6: gen が runtime サブパスを列挙するため真 anchor に realistic .beads が要る
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  wt="$repoX/.worktrees/spawn/un-4nm-101010"
  ld="$BATS_TEST_TMPDIR/rt"
  # 実 gen + 実 bdw を scribe-spawn 経由で走らせる（BEADS_BDW を **設定しない**＝shim→canonical・repo_id を実導出。
  # preflight/cld-spawn のみ noop）。
  run env SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_SANDBOX_PREFLIGHT="$noop" \
      BDW_LOCK_DIR="$ld" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repoX" --anchor "$anchorY" un-4nm
  rm -f "$noop"
  [ "$status" -eq 0 ]
  [ -f "$wt/.claude/settings.local.json" ]
  # (i) gen が grant した lock 鍵 = BDW_LOCK_DIR(ld)配下・.lock 末尾の唯一の要素。
  gen_lf="$(jq -r '.sandbox.filesystem.allowWrite[] | select(endswith(".lock"))' "$wt/.claude/settings.local.json")"
  [ -n "$gen_lf" ]
  [[ "$gen_lf" == "$ld/bd-write-"*.lock ]]
  # (iii) worker 経路（`cd anchorY && bdw lock-file`・実 shim→canonical）の鍵と byte 一致＝gen が anchor(Y)の repo_id で grant。
  worker_lf="$( (cd "$anchorY" && BDW_LOCK_DIR="$ld" "$BDW" lock-file) )"
  [ "$gen_lf" = "$worker_lf" ]
  # X≠Y の genuine 対照: repoX の cwd で導く repo_id 鍵は gen 鍵と異なる（同一なら cross-repo が vacuous＝テスト無効）。
  repoX_lf="$( (cd "$repoX" && BDW_LOCK_DIR="$ld" "$BDW" lock-file) )"
  [ "$gen_lf" != "$repoX_lf" ]
  # (ii) scribe-spawn が pre-create した実ファイルが gen 鍵(=worker 鍵)で、**通常ファイル**として先在し dir 化していない。
  #      spawn が line 663 の `cd "$ANCHOR"` を落とすと cwd(=repoX)の repo_id 鍵(repoX_lf)を pre-create+除外し、gen が
  #      grant した anchorY 鍵(gen_lf)は除外されず汎用 mkdir ループで **dir 化**する→ [ -f gen_lf ] が落ちて回帰を捕捉。
  [ -f "$gen_lf" ]
  [ ! -d "$gen_lf" ]
  # 誤鍵(repoX 側)は pre-create されていない（cd \$ANCHOR 落とし回帰の直接検出＝spawn が正しく anchor cwd で導いた証跡）。
  [ ! -e "$repoX_lf" ]
  git -C "$repoX" worktree remove --force "$wt" 2>/dev/null || true
  rm -rf "$anchorY"
}

@test "spawn(sandbox/sc-s68): gen 失敗時は die（非0）し settings.local.json を残さず temp も後始末する" {
  local repo wt noop genfail
  repo="$SCRIBE_TEST_CWD"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  # SCRIBE_SANDBOX_GEN(=CLD_SPAWN と同型 seam)で gen を失敗 stub に差し替え、spawn の die+temp掃除枝を駆動。
  genfail="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 5\n' > "$genfail"; chmod +x "$genfail"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  # sc-u53: preflight は passing stub(noop)で通し、materialization の gen 失敗枝だけを駆動する（host 非依存）。
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_SANDBOX_PREFLIGHT="$noop" SCRIBE_SANDBOX_GEN="$genfail" SCRIBE_HHMMSS=101010 \
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

@test "spawn(sc-7oj/FO-2): gen が強制キーを欠く valid JSON を吐いたら実行時アテステーションで die（silent fail-open 防止）" {
  # FO-2: gen が（stub 差替え / 手編集 drift で）valid JSON だが sandbox 強制キー（enabled=true 等）を欠く settings を
  # 吐くと、旧コードは materialize してそのまま worker を「sandbox 済み」と信じて起動＝silent fail-open だった。
  # gen stub を enabled=false の valid JSON で exit0（gen 失敗テストと違い mv は成功する）にし、materialize 後の
  # アテステーションが die させることを pin する。mutation（アテステーション削除）で status!=0 が崩れ RED 化する。
  local repo wt noop genbad
  repo="$SCRIBE_TEST_CWD"
  noop="$(mktemp)"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  # valid JSON だが enabled=false（強制キー不成立）。gen は exit0 ゆえ mv は成功し、アテステーションが捕える。
  genbad="$(mktemp)"
  cat > "$genbad" <<'STUB'
#!/usr/bin/env bash
echo '{"sandbox":{"enabled":false,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"filesystem":{"allowWrite":["/tmp"]}}}'
exit 0
STUB
  chmod +x "$genbad"
  wt="$repo/.worktrees/spawn/un-4nm-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=1 SCRIBE_CLD_SPAWN="$noop" SCRIBE_SANDBOX_PREFLIGHT="$noop" SCRIBE_SANDBOX_GEN="$genbad" SCRIBE_HHMMSS=101010 \
      "$SPAWN" --repo "$repo" --anchor "$repo" un-4nm
  rm -f "$noop" "$genbad"
  [ "$status" -ne 0 ]                                   # 黙って非 sandbox worker を起動せず fail-loud
  [[ "$output" == *"アテステーション失敗"* ]]          # 真因
  [[ "$output" == *"強制キー"* ]]                       # どの不変条件が破れたか
  [[ "$output" != *"spawned: issue=un-4nm"* ]]          # cld-spawn（happy-path）へは到達しない
  git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true
}

# ---------- sandbox e2e: sandboxed worker の git commit + bd close 永続（sc-7n1）----------
# 上の sandbox テスト(108-165, 572-624)は dry-run plan / gen JSON / 実 materialization までを pin するが、
# sandboxed worker の *実操作*（git commit が共有 .git に / bd close が .beads に永続するか）は未 assert
# だった（spike の run-spike.sh は deadcode 削除済・commit 71bf862）。verify-sandbox-e2e.sh が実 CC
# (`claude -p`)を起動してこれを埋める(sc-7n1)。本 bats は **CC を起動せず**ハーネスの契約を host 非依存に
# lock する（実 e2e は重い＋auth/deps 依存ゆえ既定 suite に入れない。deps と SCRIBE_SANDBOX_E2E=1 が
# 揃った時のみ末尾の opt-in lane が実走する）。実害: 片側 assert 退行・vacuous guard 欠落・dotfile
# null-mount 回避(sc-yqa)の退行を検出できないと「sandbox で動くつもりの worker」が空 commit を出す。
# ハーネスパス $E2E は setup() で定義（$SCRIPTS は setup() 後にしか確定しないため top-level 不可）。

@test "sandbox-e2e(sc-7n1): ハーネスが存在し実行可能・構文健全" {
  [ -x "$E2E" ]
  run bash -n "$E2E"
  [ "$status" -eq 0 ]
}

@test "sandbox-e2e(sc-7n1): git commit と bd close の両 verdict と実 claude -p 呼出を持つ（片側退行・自前 bwrap 化を捕捉）" {
  # 同じ文字列がコメントにも在るため **非コメント行限定** で verdict と実 claude -p 呼出を pin する。
  # 緩い substring 照合だと実コードを消してもコメント残置で GREEN になる（gate sc-7n1 blocking#2）。
  run grep -cE '^[^#]*verdict (PASS|FAIL) "git commit:' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  run grep -cE '^[^#]*verdict (PASS|FAIL) "bd close:' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  run grep -cE '^[^#]*claude -p' "$E2E"        # 実呼出行（真の e2e・自前 bwrap モデルでない）
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
}

@test "sandbox-e2e(sc-7n1): block-side control を実ファイル artifact で assert（narration 耐性・順序非依存・gate round2/3）" {
  # allow-side(commit/bd close)だけだと sandbox を無効化しても PASS する。外壁が genuine に効くことを 1 点 assert する。
  run grep -cE '^[^#]*verdict (PASS|FAIL) "block-side control:' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  # WORKER_CMD は allowWrite 外(OUTSIDE)へ書込みを試み、worker 自身が成否を判定して cwd 内の実ファイル INBOUND に blocked/wrote を残す。
  run grep -n 'WORKER_CMD=' "$E2E"
  [[ "$output" == *"\$OUTSIDE"* ]]
  [[ "$output" == *"printf wrote > '\$INBOUND'"* ]]
  [[ "$output" == *"printf blocked > '\$INBOUND'"* ]]
  # printf(失敗が期待値)の後は `&&` でなく `;` で必ず自己判定へ繋ぐ（AND ゲートすると INBOUND が永久に書かれず 全 PASS 不能・gate round2#2）。
  [[ "$output" == *"2>/dev/null; ["* ]]
  [[ "$output" != *"2>/dev/null && ["* ]]
  # OUTSIDE は anchor 直下(allowWrite 外)・INBOUND は cwd($WT)内(sandbox writable=real artifact を残せる)。
  run grep -n 'OUTSIDE=' "$E2E"; [[ "$output" == *"ANCHOR"* ]]
  run grep -n 'INBOUND=' "$E2E"; [[ "$output" == *"WT"* ]]
  # narration 耐性(gate round3#1): block_result は stdout grep でなく **INBOUND 実ファイルの cat** から得る(command-echo に汚染されない)。
  run grep -cE 'block_result="\$\(cat "\$INBOUND"' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  # PASS は『INBOUND==blocked かつ OUTSIDE 不在』の連言のみ=分岐順非依存(gate round3#2)。INBOUND 空(未実行)→FAIL で vacuous 閉塞。
  run grep -cE 'block_result" == blocked && ! -e "\$OUTSIDE"' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  run grep -c '実行証跡(INBOUND)なし' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
}

@test "sandbox-e2e(sc-7n1): deps 不在は rc=77 skip し bwrap/socat/claude を gate する（host 非依存の回帰を保つ）" {
  run cat "$E2E"
  [ "$status" -eq 0 ]
  [[ "$output" == *"exit 77"* ]]
  [[ "$output" == *"command -v claude"* ]]
  [[ "$output" == *"command -v bwrap"* ]]
  [[ "$output" == *"command -v socat"* ]]   # socat 欠如で CC 起動拒否=全 assert 無効化（spike で判明）
}

@test "sandbox-e2e(sc-7n1): vacuous-PASS guard（token の echo+grep 配線まで）を持つ" {
  run cat "$E2E"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOK_GIT="* ]]
  [[ "$output" == *"TOK_BD="* ]]
  [[ "$output" == *"vacuous"* ]]
  # 代入だけでなくガード配線（WORKER_CMD で echo・CC 出力を grep・token 欠落で FAIL 分岐）も pin（gate sc-7n1 minor#3）。
  run grep -n 'WORKER_CMD=' "$E2E"
  [[ "$output" == *"echo \$TOK_GIT"* ]]
  [[ "$output" == *"echo \$TOK_BD"* ]]
  run grep -cE 'grep -q "\$TOK_(GIT|BD)"' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 2 ]
  run grep -cE '\$(git|bd)_ran" != yes' "$E2E"   # token 欠落→FAIL 分岐（偽 PASS を確実に倒す）
  [ "$status" -eq 0 ]; [ "$output" -ge 2 ]
}

@test "sandbox-e2e(sc-7n1): hermetic（mktemp + cleanup trap + 自前 bd init・実台帳を mutate しない）" {
  run cat "$E2E"
  [ "$status" -eq 0 ]
  [[ "$output" == *"mktemp -d"* ]]
  [[ "$output" == *"trap cleanup EXIT"* ]]
  [[ "$output" == *"bd init"* ]]       # temp anchor を自前で初期化（実 scribe .beads を触らない）
}

@test "sandbox-e2e(sc-yqa/4b): commit 経路は scribe-add・negative control(素の git add -A)で B の必要性を実証" {
  # commit 経路は scribe-add(SADD)→git commit。素の git add -A で stage→commit する退行を禁止。
  # さらに negative control: scribe-add の前に素の git add -A を 1 度走らせ rc を NEGCTL に記録し、それが実 sandbox の
  # char-device で *失敗* することを assert する(counterfactual=B の必要性/退行は loud fail を実証・gate blocking#1)。
  run grep -n 'WORKER_CMD=' "$E2E"
  [ "$status" -eq 0 ]
  [[ "$output" == *"'\$SADD' && git commit"* ]]      # positive: scribe-add→commit
  [[ "$output" != *"git add -A && git commit"* ]]    # 退行(git add -A で stage→commit)していない
  [[ "$output" != *"git add '\$MARKER'"* ]]          # 旧 sidestep にも退行していない
  [[ "$output" == *"\$NEGCTL"* ]]                     # negative control が NEGCTL に rc を記録
  # SADD は scribe-add の実体(本番と同じ)を指す。
  run grep -cE '^[^#]*SADD="\$HERE/\.\./scribe-add"' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
  # negative control の verdict を持つ(素の git add -A の失敗で B の必要性を実証)。
  run grep -cE '^[^#]*verdict (PASS|FAIL) "negative control:' "$E2E"
  [ "$status" -eq 0 ]; [ "$output" -ge 1 ]
}

# ---------- sc-yqa: scribe-add（sandbox 下の git add -A 代替・型で device を弾く）----------
# CC sandbox は worker cwd の既知 dotfile(11) + .claude 設定(agents/commands/skills 等 9)を /dev/null char-device
# 化し `git add -A` を rc=128 で落とす(空 commit=degraded)。設定で外せず(verified)リストは CC バージョン依存。
# scribe-add は **device(非通常ファイル)に git add を一切かけない**(型で除外)ため、null-mount 集合が増減しても壊れない・
# 共有 info/exclude を汚さない(漏れゼロ)。型ガードの実弁別対象は **symlink**(git ls-files -o は fifo/socket を元々列挙
# しないため fifo は型ガードに届かない=minor#1)。単体テストは symlink で型ガードを駆動し、char-device 特有の rc=128
# 回避は root を要し単体不可ゆえ e2e(実 sandbox)が唯一の番人。
@test "sc-yqa(scribe-add): 存在し実行可能・構文健全" {
  [ -x "$SCRIPTS/scribe-add" ]
  run bash -n "$SCRIPTS/scribe-add"
  [ "$status" -eq 0 ]
}

@test "sc-yqa(scribe-add): 通常ファイルと symlink を stage し非通常ファイルは弾く・fail しない" {
  local r; r="$SCRIBE_TEST_CWD"
  ( cd "$r" && : > real.txt && ln -s /nonexistent/tgt dlink && mkdir realdir && ln -s realdir dirlink && mkfifo fifo.dev )
  # 型ガードの実弁別対象は symlink(git ls-files -o は fifo を列挙しないため fifo は届かない)。`[ -h ]||[ -f ]` が
  # dangling/->dir symlink を deref せず stage することを固定する(gate blocking#2 の回帰防止)。char-device 特有の
  # rc=128 回避は root 不可ゆえ e2e(実 sandbox)が唯一の番人。
  run bash -c "cd '$r' && '$SCRIPTS/scribe-add'"
  [ "$status" -eq 0 ]
  run git -C "$r" diff --cached --name-only
  [[ "$output" == *"real.txt"* ]]   # 通常ファイル
  [[ "$output" == *"dlink"* ]]      # dangling symlink を取りこぼさない(git は mode 120000 で commit 可)
  [[ "$output" == *"dirlink"* ]]    # dir を指す symlink も stage
  [[ "$output" != *"fifo.dev"* ]]   # 非通常ファイルは stage しない
  ( cd "$r" && rm -f fifo.dev dlink dirlink && rm -rf realdir )
}

@test "sc-yqa(scribe-add): 追跡ファイルの変更も stage する（git add -u 相当）" {
  local r; r="$SCRIBE_TEST_CWD"
  ( cd "$r" && : > t.txt && git add t.txt && git commit -q -m seed && printf x > t.txt )  # 追跡ファイルを変更
  run bash -c "cd '$r' && '$SCRIPTS/scribe-add'"
  [ "$status" -eq 0 ]
  run git -C "$r" diff --cached --name-only
  [[ "$output" == *"t.txt"* ]]                     # 追跡変更が stage される
}

@test "sc-yqa(scribe-add): 追跡ファイルが device 化しても --ignore-errors で他の追跡変更を stage し exit 0" {
  # gate minor#4: tracked path が null-mount で device 化した分岐(git add -u --ignore-errors)を固定する。
  local r; r="$SCRIBE_TEST_CWD"
  ( cd "$r" && : > good.txt && : > bad.txt && git add good.txt bad.txt && git commit -q -m seed \
       && printf x > good.txt && rm bad.txt && mkfifo bad.txt )   # good=変更 / bad=tracked path を device 化
  run bash -c "cd '$r' && '$SCRIPTS/scribe-add'"
  [ "$status" -eq 0 ]                              # device 化した追跡 path が在っても exit 0(--ignore-errors 分岐)
  run git -C "$r" diff --cached --name-only
  [[ "$output" == *"good.txt"* ]]                  # 他の追跡変更は stage される
  ( cd "$r" && rm -f bad.txt )
}

@test "sc-yqa(scribe-add): git リポジトリでなければ fail-loud(非0)" {
  local d; d="$(mktemp -d)"
  run bash -c "cd '$d' && '$SCRIPTS/scribe-add'"
  [ "$status" -ne 0 ]
  rm -rf "$d"
}

@test "sc-yqa(scribe-add): settings.local.json は除外があれば stage しない(info/exclude 尊重)" {
  local r; r="$SCRIBE_TEST_CWD"
  bash -c "source '$LIB' && scribe_sandbox_write_exclude '$r'"   # **/.claude/settings.local.json を除外
  ( cd "$r" && mkdir -p .claude && : > .claude/settings.local.json && : > keep.txt )
  run bash -c "cd '$r' && '$SCRIPTS/scribe-add'"
  [ "$status" -eq 0 ]
  run git -C "$r" diff --cached --name-only
  [[ "$output" == *"keep.txt"* ]]
  [[ "$output" != *"settings.local.json"* ]]       # 除外尊重(--exclude-standard)で ephemeral 維持
}

@test "sc-yqa(B 規律/sc-u53): worker prompt の scribe-add 規律は sandbox 時に注入される（既定 on・SCRIBE_SANDBOX=0 で外れる）" {
  # 非 sandbox（明示 opt-out）: 注入されない(通常 worker は素の git で良い)。
  run env SCRIBE_SANDBOX=0 "$SPAWN" --dry-run --anchor "$REPO_ROOT" un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" != *"sandbox 下の stage（sc-yqa）"* ]]
  # 既定（default-on）: scribe-add を使えと注入される(絶対パス付き)。
  run "$SPAWN" --dry-run --anchor "$REPO_ROOT" un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"sandbox 下の stage（sc-yqa）"* ]]
  [[ "$output" == *"$SCRIPTS/scribe-add"* ]]
}

@test "sandbox-e2e(sc-7n1/opt-in live): deps+SCRIBE_SANDBOX_E2E=1 のとき実 e2e が PASS する" {
  [ "${SCRIBE_SANDBOX_E2E:-0}" = "1" ] || skip "実 e2e は SCRIBE_SANDBOX_E2E=1 のときのみ（実 CC 起動・重い・auth 要）"
  run timeout 320 bash "$E2E"
  # ハーネスは deps(claude/bwrap/socat/bd/jq/userns)不足を rc=77 で skip する。bats もそれを skip 扱いにして
  # 「deps 揃わぬ host で偽 RED」を防ぐ（gate sc-7n1 minor#1: 旧版は claude/bwrap/socat/userns しか pre-gate せず
  # bd/jq 欠落で rc=77→FAIL になった。dep set を二重化せず rc=77 を一次の skip 源にする）。
  [ "$status" -eq 77 ] && skip "ハーネスが前提未満で skip(rc=77)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS=4 FAIL=0"* ]]   # allow-side 2 + block-side 1 + negative control 1
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
  [[ "$output" == *"cd \"$REPO_ROOT\" && \"$BDW\""* ]]   # bdw 絶対パス+空白安全クォート（sc-5wu）・anchor は絶対+クォート（un-gjr）
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
  [[ "$output" == *"cd \"$REPO_ROOT\" && \"$BDW\""* ]]   # bdw 絶対パス+空白安全クォート（sc-5wu）・anchor は絶対+クォート（un-gjr）
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
  [[ "$output" == *"cd \"$spacedir\" && \"$BDW\""* ]]   # bdw 絶対パス+空白安全クォート（sc-5wu）・空白 anchor は単一引数（un-gjr）
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

# sc-u4u: WF の gated autoFix(Fix/implement agent)が commit 前に stage する経路を sandbox-safe 化する。
# selftest-args は scribeAddPath を **常に**（SCRIBE_SANDBOX 検出に依らず）出力し、WF へ scribe-add の絶対パス
# を渡す。scribe-add は `git add -A` の安全上位互換ゆえ非 sandbox でも等価＝常時供給が決定論的（default-on 移行を
# フラグから decouple）。これが脱落すると default-on で全 worker の autoFix 経路が sandbox の null-mount device で
# rc=128 死し degraded（取りこぼし）になる回帰なので pin する。
@test "selftest-args(sc-u4u): scribeAddPath が常に絶対パスで scribe-add を指す（WF autoFix を sandbox-safe 化）" {
  run "$SELFTEST" --dry-run --worktree /tmp/wt --self-test 'bats tests/foo.bats' un-4nm
  [ "$status" -eq 0 ]
  sap="$(echo "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["scribeAddPath"])')"
  [[ "$sap" == /*/scribe-add ]]   # 絶対パスで scribe-add を指す（相対だと worker cwd で解決せず die）
  [ -x "$sap" ]                    # 実在し実行可能（型ベース stage ラッパ＝scribe-add 自体の +x も同時に守る）
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

# ---------- WF autoFix の sandbox-safe stage（cell-quality.workflow.js・sc-u4u）----------
# WF の gated autoFix は confirmed 修正後 Fix agent が `git commit --amend` で取り込むが、その stage 経路に
# scribe-add 規律が無いと、sandbox(default-on の全 worker)で agent が `git add -A` を打ち null-mount device で
# rc=128 死→amend 失敗→degraded になる（sc-yqa の refuted finding が default-on で prerequisite に昇格）。
# 対処: scribeAddPath を受けたら Fix/implement の stage を scribe-add に固定する。挙動 unit は repo に node test
# 機構が無い（top-level await/return ゆえ node --check も不可）ため source-level で構造を pin する。
@test "cell-quality WF(sc-u4u): scribeAddPath を path 検証して受け、Fix/implement の stage を scribe-add に固定する分岐を持つ" {
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  [ -f "$WF" ]
  # args から受け、baseRef と同じ path-安全文字 hardening で検証する（不正値→空 fallback）。
  grep -q 'A\.scribeAddPath' "$WF"
  grep -q '_rawScribeAdd' "$WF"
  grep -q 'const scribeAddPath' "$WF"
  # Fix(stageStep) / implement(commitNote) の双方が scribeAddPath で stage を分岐する。
  grep -q 'stageStep' "$WF"
  grep -q 'commitNote' "$WF"
  # 供給時の分岐が `git add -A` を明示的に避ける（prohibition が在る＝穴を塞ぐ意図を pin）。
  grep -Fq 'git add -A' "$WF"
  # 供給されたが path 検証を外れた(非空 reject)場合は loud に warn する＝silent な旧経路後退を可視化する
  # （sc-u4u gate の有用提案を採用。空 fallback が「未供給=legacy」と「reject」を縮退させる穴を loud 化）。
  grep -q '_rawScribeAdd && !scribeAddPath' "$WF"
  grep -q '警告: scribeAddPath' "$WF"
}

# sc-u4u gate round2 採用: WF 側 scribeAddPath 検証は上のテストで *存在* を grep pin するだけで *挙動* を実行検証
# していなかった（selftest-args 側 1071-1078 は python3 で実値 assert する非対称）。WF ソースから検証 regex
# リテラルを抽出して node -e で実走させ、valid な install path を通し exotic(空白/非ASCII)を弾くことを behavioral
# に pin する（regex を再実装せず *実体* を叩く＝condition 反転/regex 破損の回帰を grep が見逃しても赤くする）。
@test "cell-quality WF(sc-u4u): scribeAddPath 検証 regex が valid を通し exotic(空白/非ASCII)を弾く（behavioral・実体 regex を実行）" {
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  [ -f "$WF" ]
  # `const scribeAddPath = /…/.test(…)` 行から regex リテラル `/…/` を抽出（再実装でなく実体）。
  re="$(grep -E 'const scribeAddPath = /' "$WF" | sed -E 's#^.*= (/.*/)\.test.*#\1#')"
  [ -n "$re" ]
  [[ "$re" == /*/ ]]   # 抽出が regex リテラル形である（抽出失敗で空/別物を node へ渡さない）
  # 実体 regex で valid(ASCII-clean な install path)→true・exotic(空白/非ASCII/相対は別議論)→false を実行検証。
  run node -e "const re=$re; const ok=re.test('/home/u/.claude/plugins/scribe/scripts/scribe-add'); const bad1=re.test('/home/My User/scribe-add'); const bad2=re.test('/home/josé/scribe-add'); process.exit((ok && !bad1 && !bad2) ? 0 : 1)"
  [ "$status" -eq 0 ]
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

# bd-write-guard(sc-wdr)は 3 兄弟中最大の self-test（token 判定 / session self-scope(D1) / preamble の
# 3 battery）を持つが、他 guard（rm/git/cmdtokens）と違い回帰網へ未配線だった＝core rule と D1 no-op
# 安全性が『self-test 緑のまま壊れうる』状態だった。他 guard と同形に bats から --self-test を呼び、
# status0 + 各 battery の "OK" + case 数下限を pin する。下限は cases[] を空にして 0/0+exit0 を出す
# mutation（(a)(b)(c)/J1-J7/dep/link/repo/HIGH_DANGER_WRITE の token 判定・D1 no-op 安全 session cases
# の消去）を捕捉する（現数 token=111 / session=20 / preamble=3）。
@test "guard self-test: bd-write-guard --self-test が exit 0 + 3 battery 全 OK + case 数下限（sc-wdr）" {
  run python3 "$HOOKS/bd-write-guard.py" --self-test
  [ "$status" -eq 0 ]
  # (1) token 判定 battery: guard 中核ルール（(a)(b)(c)/J1-J7/dep/link/repo/HIGH_DANGER_WRITE 分類）。
  [[ "$output" =~ "bd-guard self-test: "([0-9]+)/([0-9]+)" OK" ]]
  [ "${BASH_REMATCH[2]}" -ge 100 ]
  # (2) session self-scope battery: D1 の『非 sc session→exit0 no-op』安全保証（integ_cases i/i'/iv）。
  [[ "$output" =~ "session self-test: "([0-9]+)/([0-9]+)" OK" ]]
  [ "${BASH_REMATCH[2]}" -ge 15 ]
  # (3) preamble battery: cmdtokens consume cutover の (a)/(override)/(c)。
  [[ "$output" =~ "preamble self-test: "([0-9]+)/([0-9]+)" OK" ]]
  [ "${BASH_REMATCH[2]}" -ge 3 ]
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

# bd-write-guard(sc-wdr)は git/rm guard と違い session-gate 付き（cwd の .beads/metadata.json の
# dolt_database=='sc' の session でのみ発火する＝D1）。wire/preamble の e2e 検証で「sc 台帳 session」を
# hermetic に与えるため、dolt_database=sc の .beads/metadata.json を持つ temp 台帳 dir を作り path を echo
# する（JSON payload の cwd に据えて session-gate を通す）。$BATS_TEST_TMPDIR 配下ゆえ bats が per-test で
# 自動掃除する（.beads を含むため明示 rm はしない＝beads-destructive-guard に触れない）。
_mk_sc_ledger() {
  local d; d="$(mktemp -d "$BATS_TEST_TMPDIR/scled.XXXXXX")"
  mkdir -p "$d/.beads"
  printf '{"database":"dolt","dolt_database":"sc"}\n' > "$d/.beads/metadata.json"
  printf '%s\n' "$d"
}

@test "PreToolUse wire(sc-4ix): hooks.json の command 経由で破壊 git/rm/bd を exit2 block（end-to-end）" {
  local gcmd rcmd bcmd
  gcmd="$(_pre_cmd git-destructive-guard.py)"
  rcmd="$(_pre_cmd rm-destructive-guard.py)"
  bcmd="$(_pre_cmd bd-write-guard.py)"
  [ -n "$gcmd" ]   # git-guard が PreToolUse[Bash] 下に配線されている（削除/matcher typo を捕捉）
  [ -n "$rcmd" ]   # rm-guard が配線されている
  [ -n "$bcmd" ]   # bd-write-guard(sc-wdr)が3本目として配線されている（削除/matcher typo/|| true 混入を捕捉）
  # 実 command を起動（${CLAUDE_PLUGIN_ROOT}→repo root に解決）。fail-open suffix 混入なら exit0 化し fail。
  run env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "$gcmd" <<< '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"cwd":"/tmp"}'
  [ "$status" -eq 2 ]
  run env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "$rcmd" <<< '{"tool_name":"Bash","tool_input":{"command":"rm -rf /etc"},"cwd":"/tmp"}'
  [ "$status" -eq 2 ]
  # bd-write-guard は session-gate 付きゆえ wire 経路に固有の失敗面を持つ: sc cwd でも foreign write の
  # exit2 が hooks.json command 経由で伝播するか（criterion 5＝`|| true` 無し=block 伝播）を pin する。
  # temp sc .beads/metadata.json(dolt_database=sc)を JSON payload の cwd に据え、foreign write(bd update un-1)を block。
  local scled bpayload; scled="$(_mk_sc_ledger)"
  bpayload="$(printf '{"tool_name":"Bash","tool_input":{"command":"bd update un-1"},"cwd":"%s"}' "$scled")"
  run env CLAUDE_PLUGIN_ROOT="$REPO_ROOT" bash -c "$bcmd" <<< "$bpayload"
  [ "$status" -eq 2 ]
}

@test "PreToolUse wire(sc-wdr / D1 allow 方向): healthy guard + foreign 台帳(un/orch) session の foreign write は exit0 no-op" {
  # 既存 e2e/preamble は全て sc 台帳 cwd の block(exit2)方向のみ叩く。D1 の核心＝『非 sc session では guard が
  # 一切判定せず exit0 no-op する』allow 方向を実 subprocess で automate する（_is_scribe_guard_session を常時
  # True へ反転させ globally-enable された guard が無関係 project の bd write を brick する回帰は、この allow
  # 方向テストが無いと bats 全緑のまま通る）。foreign 台帳=un/orch を両方叩く（.beads を含む temp dir は
  # $BATS_TEST_TMPDIR 配下で bats が per-test 自動掃除する＝明示 rm しない=beads-destructive-guard に触れない）。
  local fled payload db
  for db in un orch; do
    fled="$(mktemp -d "$BATS_TEST_TMPDIR/fled.XXXXXX")"
    mkdir -p "$fled/.beads"
    printf '{"database":"dolt","dolt_database":"%s"}\n' "$db" > "$fled/.beads/metadata.json"
    # sc 台帳なら kind b で deny(2) になる foreign write を foreign session cwd では no-op(0) にする。
    payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"bd update un-1 --notes x"},"cwd":"%s"}' "$fled")"
    run --separate-stderr python3 "$HOOKS/bd-write-guard.py" <<< "$payload"
    [ "$status" -eq 0 ]     # 非 sc session → guard 無判定 no-op（D1）
    [ -z "$stderr" ]        # no-op ゆえ DENIED 案内も loud 警告も出ない
  done
  # 弁別力の pin: 同一 foreign write を sc 台帳 cwd で叩くと deny(2)＝上の exit0 は session-gate による
  # no-op であって『guard が壊れて全部 exit0』の vacuous pass ではない（cmdtokens fail-open 等と弁別）。
  local scled; scled="$(_mk_sc_ledger)"
  payload="$(printf '{"tool_name":"Bash","tool_input":{"command":"bd update un-1 --notes x"},"cwd":"%s"}' "$scled")"
  run python3 "$HOOKS/bd-write-guard.py" <<< "$payload"
  [ "$status" -eq 2 ]
}

@test "PreToolUse wire(sc-4ix): script 不在（CLAUDE_PLUGIN_ROOT 異常）で exit0・副作用ゼロ（fail-open）" {
  local cmd
  # bd-write-guard も同形 if/else wire ゆえ script 不在で exit0 fail-open（起動行は 3 guard 共通・sc-wdr）。
  for cmd in "$(_pre_cmd git-destructive-guard.py)" "$(_pre_cmd rm-destructive-guard.py)" "$(_pre_cmd bd-write-guard.py)"; do
    run --separate-stderr env CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/nonexistent" bash -c "$cmd" <<< '{"tool_name":"Bash","tool_input":{"command":"git push --force"},"cwd":"/tmp"}'
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
  done
}

@test "guard: 非UTF-8 stdin で fail-open exit0（sc-a7t: UnicodeDecodeError を exit1 化させない）" {
  # 非UTF-8 raw バイトの stdin.read() を try 外に置くと未捕捉 UnicodeDecodeError で exit1 化し、
  # 整形 fail-open(exit0)経路と不整合になる。両 guard が exit0(=non-blocking fail-open)へ倒すことを pin。
  for g in git-destructive-guard.py rm-destructive-guard.py bd-write-guard.py; do
    run bash -c "printf '\\xff\\xfe\\xff' | python3 '$HOOKS/$g'"
    [ "$status" -eq 0 ]
  done
}

# ---------- cmdtokens consume preamble の解決分岐を回帰網へ pin（sc-ehv / orch-j55・由来 orch-iqz/orch-a9y/orch-2nz）----------
# 2 guard の lib import は「CMDTOKENS_LIB env override → expanduser → os.path.isabs ガードで非絶対値を
# 既定 plugin lib へ落とす → import」のテンプレ方式に載せ替えられた。この preamble は import 時に 1 度だけ
# 走り、guard 内蔵 --self-test は module ロード後のロジックしか叩かない＝preamble の解決分岐は self-test/上の
# wire テストでは一切実行されない。結果、本変更の核心セキュリティ性質（isabs ガードによる cwd 相対 poison
# import 回避＝orch-a9y/bd-write-guard gate で検出した欠陥の修正）が『緑のまま退行しうる』状態だった。
# ここで preamble を新規プロセスごとに走らせ、3 分岐（相対/poison→既定 fallback、絶対 override、不在 abs→
# fail-open）を回帰網へ入れる。各ケースは hook と同形の JSON を stdin で渡し exit code/stderr を pin する。
_PREAMBLE_FAILOPEN_MSG="cannot load cmdtokens lib, failing open"
_run_guard_env() {  # <guard-basename> <cmd> <json_cwd> <envassign|""> <proc_cwd|"">  → status=$?,output(stderr) を返す
  local guard="$HOOKS/$1" cmd="$2" json_cwd="$3" envassign="$4" proc_cwd="$5"
  local jf; jf="$(mktemp)"
  python3 -c 'import json,sys; open(sys.argv[3],"w").write(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$json_cwd" "$jf"
  if [ -n "$proc_cwd" ]; then
    run --separate-stderr bash -c "cd '$proc_cwd' && env $envassign python3 '$guard' < '$jf'"
  else
    run --separate-stderr bash -c "env $envassign python3 '$guard' < '$jf'"
  fi
  rm -f "$jf"
}

@test "preamble(sc-ehv): CMDTOKENS_LIB=相対値 → isabs ガードで既定へ落ち block（poison/fail-open しない）" {
  for spec in "git-destructive-guard.py|git push -f" "rm-destructive-guard.py|rm -rf /"; do
    local g="${spec%%|*}" c="${spec#*|}"
    _run_guard_env "$g" "$c" /tmp "CMDTOKENS_LIB=some/rel/path" ""
    [ "$status" -eq 2 ]
    [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  done
  # bd-write-guard は自 preamble copy を持つ（drift 独立）+ session-gate ゆえ sc cwd + foreign write で同分岐を pin。
  local scled; scled="$(_mk_sc_ledger)"
  _run_guard_env "bd-write-guard.py" "bd update un-1" "$scled" "CMDTOKENS_LIB=some/rel/path" ""
  [ "$status" -eq 2 ]
  [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
}

@test "preamble(sc-ehv / orch-a9y 修正の核心): CMDTOKENS_LIB='.' を poison cmdtokens.py 入り cwd で叩いても poison を import せず block" {
  local poison; poison="$(mktemp -d "$BATS_TEST_TMPDIR/scehv-poison.XXXXXX")"
  printf 'raise RuntimeError("POISONED cmdtokens loaded")\n' > "$poison/cmdtokens.py"
  for spec in "git-destructive-guard.py|git push -f" "rm-destructive-guard.py|rm -rf /"; do
    local g="${spec%%|*}" c="${spec#*|}"
    _run_guard_env "$g" "$c" /tmp "CMDTOKENS_LIB=." "$poison"
    [ "$status" -eq 2 ]
    [[ "$stderr" != *"POISONED"* ]]
    [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  done
  # bd-write-guard も poison cwd から自 preamble を通す（JSON cwd=sc 台帳で session-gate 通過・proc cwd=poison）。
  local scled; scled="$(_mk_sc_ledger)"
  _run_guard_env "bd-write-guard.py" "bd update un-1" "$scled" "CMDTOKENS_LIB=." "$poison"
  [ "$status" -eq 2 ]
  [[ "$stderr" != *"POISONED"* ]]
  [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  rm -rf "$poison"
}

@test "preamble(sc-ehv): CMDTOKENS_LIB='' → or 既定 fallback で block（空文字でも既定解決）" {
  for spec in "git-destructive-guard.py|git push -f" "rm-destructive-guard.py|rm -rf /"; do
    local g="${spec%%|*}" c="${spec#*|}"
    _run_guard_env "$g" "$c" /tmp "CMDTOKENS_LIB=" ""
    [ "$status" -eq 2 ]
    [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  done
  local scled; scled="$(_mk_sc_ledger)"
  _run_guard_env "bd-write-guard.py" "bd update un-1" "$scled" "CMDTOKENS_LIB=" ""
  [ "$status" -eq 2 ]
  [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
}

@test "preamble(sc-ehv): CMDTOKENS_LIB=<repo lib 絶対パス> override が効き block（isabs=真 分岐）" {
  local repo_lib_dir="$HOOKS/lib"
  for spec in "git-destructive-guard.py|git push -f" "rm-destructive-guard.py|rm -rf /"; do
    local g="${spec%%|*}" c="${spec#*|}"
    _run_guard_env "$g" "$c" /tmp "CMDTOKENS_LIB=$repo_lib_dir" ""
    [ "$status" -eq 2 ]
    [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  done
  local scled; scled="$(_mk_sc_ledger)"
  _run_guard_env "bd-write-guard.py" "bd update un-1" "$scled" "CMDTOKENS_LIB=$repo_lib_dir" ""
  [ "$status" -eq 2 ]
  [[ "$stderr" != *"$_PREAMBLE_FAILOPEN_MSG"* ]]
}

@test "preamble(sc-ehv): CMDTOKENS_LIB=<cmdtokens.py 不在の絶対 dir> → fail-open exit0 + [git-guard]/[rm-guard]/[bd-guard] loud stderr" {
  local badabs="$BATS_TEST_TMPDIR/nonexistent-cmdtokens-scehv"
  _run_guard_env "git-destructive-guard.py" "git push -f" /tmp "CMDTOKENS_LIB=$badabs" ""
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[git-guard]"* ]]
  [[ "$stderr" == *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  _run_guard_env "rm-destructive-guard.py" "rm -rf /" /tmp "CMDTOKENS_LIB=$badabs" ""
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[rm-guard]"* ]]
  [[ "$stderr" == *"$_PREAMBLE_FAILOPEN_MSG"* ]]
  # bd-write-guard は cmdtokens load 失敗時 session-gate 前に fail-open exit0（[bd-guard] loud）。cwd は
  # 任意で可（session 判定へ到達しない）。preamble copy の fail-open 分岐 + [bd-guard] タグを pin する。
  _run_guard_env "bd-write-guard.py" "bd update un-1" /tmp "CMDTOKENS_LIB=$badabs" ""
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"[bd-guard]"* ]]
  [[ "$stderr" == *"$_PREAMBLE_FAILOPEN_MSG"* ]]
}

@test "bdw cutover(sc-vae/sc-mcx): bdw=logic-free shim / gen+e2e は bdw lock-file を consume / scribe-lib に lock_dir 関数なし" {
  # cutover の構造不変条件（旧 'lock_dir formula を scribe_bdw_lock_dir に集約' を置換）。lock_dir の SSOT は
  # canonical bdw（beads-bdw plugin）へ一本化され、scribe 側は shim→canonical を consume するだけ＝3 copy
  # drift（uns/scriptorium/scribe）を撲滅した。判定は bare token でなく「直列化ロジックの実体」で行う
  # （header コメントが歴史 provenance として 'flock' 等の語を含みうるため・scriptorium shim 先例と同様）。
  # (a) scripts/bdw = logic ゼロの shim: canonical 解決(_CANON)と exec を含み、直列化ロジック（flock 取得・
  #     fd9 lock open）・lib source 文・旧ローカル lock 関数参照を一切含まない。
  grep -q '_CANON' "$BDW"
  grep -qE 'exec "\$_CANON" "\$@"' "$BDW"
  run grep -qE 'flock -w' "$BDW";              [ "$status" -ne 0 ]
  run grep -q 'exec 9>' "$BDW";                [ "$status" -ne 0 ]
  run grep -qE '^[[:space:]]*source ' "$BDW";  [ "$status" -ne 0 ]
  run grep -q 'scribe_bdw_lock_dir' "$BDW";    [ "$status" -ne 0 ]
  # (b) gen-sandbox / verify-sandbox-e2e は `bdw lock-file`（shim→canonical・OG-4 で lock-dir から狭化）を consume し、旧ローカル関数を呼ばない。
  grep -qE '/bdw" lock-file' "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh"
  run grep -q 'scribe_bdw_lock_dir' "$SCRIPTS/sandbox-spike/gen-sandbox-settings.sh"; [ "$status" -ne 0 ]
  grep -qE '/bdw" lock-file' "$E2E"
  run grep -q 'scribe_bdw_lock_dir' "$E2E"; [ "$status" -ne 0 ]
  # (c) scribe-lib.sh は lock_dir 解決関数を定義しない（dead code 削除＝単一SSOT化の本旨）。
  run grep -q 'scribe_bdw_lock_dir' "$LIB"; [ "$status" -ne 0 ]
}

@test "bdw(shim): canonical 不在は fail-closed（exit 1・bd 不実行・診断 stderr）" {
  # shim の核心: canonical が解決できなければ bd write を素通しさせず loud に止める（直列化を外して実行は
  # しない＝静かな lost-update 復活を防ぐ）。BEADS_BDW を非存在パスへ向け、bd（echo スタブ）が実行されない
  # こと・exit 1・stderr に診断が出ることを pin する。素通し回帰が起きれば bd が走り output に 'show un-x'
  # が混じる＝本 @test が落ちる。
  run env BEADS_BDW=/nonexistent-canonical-xyz BDW_BD_BIN=echo "$BDW" show un-x
  [ "$status" -eq 1 ]
  [[ "$output" == *"canonical bdw not found"* ]]
  [[ "$output" == *"fail-closed"* ]]
  [[ "$output" != *"show un-x"* ]]   # bd（echo スタブ）は実行されていない
}

@test "bdw(shim/drift): 実行ロジックが canonical templates/bdw-shim と byte 一致（template drift を捕捉・不在時 skip・SHOULD b）" {
  # cutover の主旨＝3 copy drift（uns/scriptorium/scribe）撲滅。shim の実行ロジック（set -uo pipefail 以降）は plugin の
  # templates/bdw-shim と byte 一致に保つ契約（ヘッダ comment は repo 固有可・scriptorium 先例と同様）。将来 template が
  # 変わって scribe shim が追従し損ねる drift を本テストで捕捉する（構造 test の grep subset は別パス/別 fail-closed 文言の
  # drift を見逃すため byte 比較で補う）。template 不在の host/CI では skip（e2e の deps skip と同型）。
  local tmpl="${BEADS_BDW_TEMPLATE:-$HOME/.claude/plugins/beads-bdw/templates/bdw-shim}"
  [ -f "$tmpl" ] || skip "canonical templates/bdw-shim not found ($tmpl)"
  run diff <(sed -n '/^set -uo pipefail/,$p' "$BDW") <(sed -n '/^set -uo pipefail/,$p' "$tmpl")
  [ "$status" -eq 0 ]
}

# ---------- bdw: flock-serialized B/hybrid の中核ロジックを pin（sc-i9b member 2）----------
# sc-vae cutover 後は scripts/bdw が canonical bdw（beads-bdw plugin）へ exec する shim になったため、
# 以下は shim→canonical を貫く **integration test** として残す（READ/WRITE 分岐ロジックの実装は canonical 側）。
# bd 実体を echo に差し替え（BDW_BD_BIN=echo・shim が exec で canonical へ継承）て実 Dolt write を起こさず、
# READ/WRITE 経路の分岐だけを検証する。判定の観測点 = BDW_LOCK_DIR 直下に `bd-write-*.lock`（sc-xs2: override は
# subdir を足さず直接使う＝orch/uns bdw と収束）が作られたか。
#   - READ allowlist  → exec が lock 作成より前に走るため lock 0 個（無ロック素通し）
#   - WRITE / 未知    → flock 取得後 exec のため lock 1 個（直列化路）
# 各 @test は使い捨ての空 lock dir を作って観測する。cwd は setup() の temp git repo。
_bdw_locks() { ls "$1"/bd-write-*.lock 2>/dev/null | wc -l | tr -d ' '; }
# sc-vae cutover で scripts/bdw は canonical(beads-bdw plugin)へ exec する shim になった。以下の integration
# test は shim→canonical を貫くため canonical が無い host/CI では実行不能 → red 退行でなく clean skip する
# （test 移植性回復・e2e の deps skip と同型・SHOULD(a)）。各 integration @test 冒頭で呼ぶ。
_need_canonical_bdw() { [ -x "${BEADS_BDW:-$HOME/.claude/plugins/beads-bdw/bin/bdw}" ] || skip "canonical beads-bdw plugin not installed (BEADS_BDW)"; }

@test "bdw: READ allowlist（show）は無ロックで素通し（lock 0 個・args 透過）" {
  _need_canonical_bdw
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" show un-x
  [ "$status" -eq 0 ]
  [[ "$output" == *"show un-x"* ]]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: WRITE（update --claim）は flock 取得路（lock 1 個・args 透過）" {
  _need_canonical_bdw
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" update un-x --claim
  [ "$status" -eq 0 ]
  [[ "$output" == *"update un-x --claim"* ]]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: WRITE（close）は flock 取得路（lock 1 個）" {
  _need_canonical_bdw
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" close un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: 未知サブコマンドは fail-closed で flock 取得路（lock 1 個・allowlist 漏れ=直列化）" {
  _need_canonical_bdw
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" frobnicate x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: WRITE は flock 取得失敗で fail-closed（実排他を観測・lock file 在＝取得済 を証明しない）" {
  _need_canonical_bdw
  # 上の WRITE @test 群は「lock file が在る」しか見ない。だが canonical bdw（via shim）の `exec 9>lock_file` は
  # flock 取得の成否に依らず lock file を無条件生成するので、`flock -w` が回帰で消えても
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
  _need_canonical_bdw
  # --actor の値が write subcmd 名（close）でも次トークンとして読み飛ばし、真の subcmd=show を採る。
  # skip_next が壊れると subcmd=close と誤認 → WRITE lock になる。lock 0 でそれを pin。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" --actor close show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（--db）の値を subcommand と誤認しない（--db close show → READ・lock 0）" {
  _need_canonical_bdw
  # 契約 member(2) が名指しで pin を要求する 3 つ目の value-taking flag。--db の値が write subcmd 名
  # （close）でも次トークンとして読み飛ばし、真の subcmd=show を採る。canonical bdw（via shim）の flag case 一覧から --db が
  # 回帰で落ちると subcmd=close と誤認 → WRITE lock になる。lock 0 でそれを pin（--actor と対称）。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" --db close show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（--directory）の値を subcommand と誤認しない（--directory close show → READ・lock 0）" {
  _need_canonical_bdw
  # 同 skip_next case 分岐（canonical bdw via shim）の網羅を完成させる。--directory の値（close）を読み飛ばし真の subcmd=show
  # を採る。case 一覧から --directory が落ちれば subcmd=close 誤認 → WRITE lock。lock 0 でそれを pin。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" --directory close show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: 値取り global flag（-C）は値を飛ばし真の subcommand を採る（-C path update → WRITE・lock 1）" {
  _need_canonical_bdw
  # -C の値（/tmp/x）を飛ばした上で update を subcmd と認識する＝flag-skip が真の subcmd を食わない。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" -C /tmp/x update un-y --claim
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 1 ]
  rm -rf "$ld"
}

@test "bdw: boolean flag（-f）を値取りと誤読しない（-f show → READ・lock 0）" {
  _need_canonical_bdw
  # -f は boolean。次トークン show を値として食わない（食えば subcmd=un-x→未知→WRITE lock）。lock 0 で pin。
  local ld; ld="$(mktemp -d)"
  run env BDW_BD_BIN=echo BDW_LOCK_DIR="$ld" "$BDW" -f show un-x
  [ "$status" -eq 0 ]
  [ "$(_bdw_locks "$ld")" -eq 0 ]
  rm -rf "$ld"
}

@test "bdw: bd 不在は exit 127 で fail-loud（write を実行しない）" {
  _need_canonical_bdw
  run -127 env BDW_BD_BIN=/nonexistent-bd-xyz "$BDW" show un-x
  [ "$status" -eq 127 ]
  [[ "$output" == *"not found"* ]]
}

# ---------- grill-status-watch.sh（sc-bka: STATUS poll 通知・read-only watcher）----------
# 無限監視ループ（loop + sleep）は叩かず、load-bearing な抽出/判定の seam（--extract / --classify / --fetch）を
# 合成 JSON で決定論的に検証する（実 bd を叩かない＝既存スタブ流儀に倣う）。STATUS の SSOT は sc-qos 成果物。

@test "grill-status-watch(--extract): notes 最後の STATUS 行を抽出（複数 STATUS は last を採る）" {
  run bash "$WATCH" --extract <<<'[{"notes":"決定: A\nSTATUS: grilling (1/3)\n決定: B\nSTATUS: grilling (2/3)"}]'
  [ "$status" -eq 0 ]
  [[ "$output" == "STATUS: grilling (2/3)" ]]
}

@test "grill-status-watch(--extract): notes が null なら no-notes（落ちない）" {
  run bash "$WATCH" --extract <<<'[{"notes":null}]'
  [ "$status" -eq 0 ]
  [[ "$output" == "no-notes" ]]
}

@test "grill-status-watch(--extract): notes フィールド欠如でも no-notes（bd の空 notes 省略・verified）" {
  run bash "$WATCH" --extract <<<'[{"id":"sc-x","title":"t"}]'
  [ "$status" -eq 0 ]
  [[ "$output" == "no-notes" ]]
}

@test "grill-status-watch(--extract): notes はあるが STATUS 行が無ければ no-status" {
  run bash "$WATCH" --extract <<<'[{"notes":"決定: A のみ（STATUS 未記入）"}]'
  [ "$status" -eq 0 ]
  [[ "$output" == "no-status" ]]
}

@test "grill-status-watch(--classify): done / blocked は terminal・grilling は ongoing" {
  run bash "$WATCH" --classify "STATUS: done — 全 facet 確定"
  [[ "$output" == "terminal" ]]
  run bash "$WATCH" --classify "STATUS: blocked — 要admin: X"
  [[ "$output" == "terminal" ]]
  run bash "$WATCH" --classify "STATUS: grilling (1/3)"
  [[ "$output" == "ongoing" ]]
}

# 回帰（sc-bka F1/F3）: 終端判定は canonical の STATUS 値（`STATUS:` 直後のキーワード）に前方アンカーする。
# grilling 行の自由文末尾に done/blocked の語が混ざっても terminal 誤判定してはならない
# （部分一致 *done*|*blocked* だと早期 exit 0 して watcher が黙って死ぬ）。
@test "grill-status-watch(--classify): grilling 行 prose の done/blocked を terminal 誤判定しない（回帰）" {
  run bash "$WATCH" --classify "STATUS: grilling — facet done で確認待ち"
  [[ "$output" == "ongoing" ]]
  run bash "$WATCH" --classify "STATUS: grilling (2/3) — A は done だが残り 1"
  [[ "$output" == "ongoing" ]]
  run bash "$WATCH" --classify "STATUS: grilling — blocked な検討事項を整理"
  [[ "$output" == "ongoing" ]]
  # 逆: blocked 理由文に done が混ざっても、先頭キーワードが blocked なら terminal を維持する。
  run bash "$WATCH" --classify "STATUS: blocked — 要admin: done の facet 残り"
  [[ "$output" == "terminal" ]]
}

# 回帰（sc-bka F2/F5/F6）: bd が配列でない error-object / notes 非文字列 / 壊れた JSON を stdout に
# 返しても extract_status は jq を非ゼロ終了させず no-notes に潰す（set -e 下で loop を殺さない＝acceptance(4)）。
@test "grill-status-watch(--extract): bd error-object（非配列）は no-notes・jq を落とさない（回帰）" {
  run bash "$WATCH" --extract <<<'{"error":"no issues found matching the provided IDs","schema_version":1}'
  [ "$status" -eq 0 ]
  [[ "$output" == "no-notes" ]]
}

@test "grill-status-watch(--extract): notes が非文字列（数値）でも no-notes・落ちない（回帰）" {
  run bash "$WATCH" --extract <<<'[{"notes":123}]'
  [ "$status" -eq 0 ]
  [[ "$output" == "no-notes" ]]
}

@test "grill-status-watch(--extract): 壊れた JSON（parse error）でも no-notes・落ちない（回帰）" {
  run bash "$WATCH" --extract <<<'garbage not json'
  [ "$status" -eq 0 ]
  [[ "$output" == "no-notes" ]]
}

# 回帰（sc-bka F4）: watch_loop の通知・自己終了（受入1・3 の core）を 1 周で決定論的に検証する。
# GRILL_WATCH_JSON_FILE フックで固定 JSON を返し、interval=0 で 1 周だけ回す（timeout 併用で安全網）。
@test "grill-status-watch(loop): terminal STATUS を 1 周で検知し通知して exit 0 自己終了（受入3）" {
  f="$(mktemp)"
  printf '%s' '[{"notes":"STATUS: blocked — 要admin: 設計確認"}]' > "$f"
  run timeout 5 env GRILL_WATCH_JSON_FILE="$f" bash "$WATCH" sc-x 0
  rm -f "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[sc-x] STATUS changed: STATUS: blocked — 要admin: 設計確認"* ]]
}

@test "grill-status-watch(--fetch): GRILL_WATCH_JSON_FILE フックで bd を叩かず STATUS を取る（fetch seam）" {
  f="$(mktemp)"
  printf '%s' '[{"notes":"STATUS: blocked — 要admin: 設計確認"}]' > "$f"
  run env GRILL_WATCH_JSON_FILE="$f" bash "$WATCH" --fetch sc-x
  rm -f "$f"
  [ "$status" -eq 0 ]
  [[ "$output" == "STATUS: blocked — 要admin: 設計確認" ]]
}

@test "grill-status-watch: 引数なしは usage を出す（exit 0・READ-only 強調）" {
  run bash "$WATCH"
  [ "$status" -eq 0 ]
  [[ "$output" == *"READ-only"* ]]
  [[ "$output" == *"grill-status-watch.sh"* ]]
}

# GRILL_WATCH_JSON_CMD seam: poll の度に「次の行の JSON」を返すスクリプトを生成する。
# 状態ファイルにカウンタを持たせ、呼ばれる度に NL 区切りの k 行目を stdout へ出す（k++）。
# これで grilling→grilling(n+1)→done のような非終端遷移・dedup を 1 プロセス内で再現する（sc-bka F1/F4/F2）。
_make_step_cmd() {
  local sf="$1"; shift            # 状態ファイル（カウンタ保持）
  local lines="$1"                # NL 区切りの JSON シーケンス（ヒアドキュメント等で渡す）
  local lf; lf="$(mktemp)"
  # 末尾改行を必ず付ける（wc -l は改行数を数えるため、改行無し末尾行が欠落するのを防ぐ）。
  printf '%s\n' "$lines" > "$lf"
  printf '0' > "$sf"
  # 末尾行を超えたら最終行を返し続ける（loop が最後の STATUS で安定する）。
  printf 'i=$(cat %q); n=$(wc -l < %q); [ "$i" -lt "$n" ] || i=$((n-1)); sed -n "$((i+1))p" %q; echo $((i+1)) > %q' \
    "$sf" "$lf" "$lf" "$sf"
}

# 回帰（sc-bka F1/F4）: 非終端 STATUS の変化を通知しつつ loop を継続し、終端で初めて exit 0 する。
# grilling(1/3)→grilling(2/3)→done の 3 遷移を JSON_CMD で順送りし、3 通知＋最後に自己終了を固定する。
@test "grill-status-watch(loop): 非終端変化を逐次通知し継続、終端 done で exit 0（F1/F4 変化検知）" {
  sf="$(mktemp)"
  cmd="$(_make_step_cmd "$sf" \
'[{"notes":"STATUS: grilling (1/3)"}]
[{"notes":"STATUS: grilling (2/3)"}]
[{"notes":"STATUS: done — 全 facet 確定"}]')"
  run timeout 5 env GRILL_WATCH_JSON_CMD="$cmd" bash "$WATCH" sc-x 0
  rm -f "$sf"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[sc-x] STATUS changed: STATUS: grilling (1/3)"* ]]
  [[ "$output" == *"[sc-x] STATUS changed: STATUS: grilling (2/3)"* ]]
  [[ "$output" == *"[sc-x] STATUS changed: STATUS: done — 全 facet 確定"* ]]
  # 通知は 3 行ちょうど（grilling の dedup 漏れや余計な再通知が無い）。
  [ "$(printf '%s\n' "$output" | grep -c 'STATUS changed:')" -eq 3 ]
}

# 回帰（sc-bka F1/F4 dedup）: 同一 STATUS が連続したら 2 度目以降は通知しない。
# grilling(1/3)×2 → done と順送りし、grilling は 1 回しか通知されないことを固定する。
@test "grill-status-watch(loop): 同一 STATUS 連続は再通知しない dedup（F1/F4）" {
  sf="$(mktemp)"
  cmd="$(_make_step_cmd "$sf" \
'[{"notes":"STATUS: grilling (1/3)"}]
[{"notes":"STATUS: grilling (1/3)"}]
[{"notes":"STATUS: done — 確定"}]')"
  run timeout 5 env GRILL_WATCH_JSON_CMD="$cmd" bash "$WATCH" sc-x 0
  rm -f "$sf"
  [ "$status" -eq 0 ]
  # grilling は 1 回・done は 1 回（連続同値の grilling を 2 度通知しない）。
  [ "$(printf '%s\n' "$output" | grep -c 'STATUS changed: STATUS: grilling (1/3)')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'STATUS changed: STATUS: done')" -eq 1 ]
}

# 回帰（sc-bka F2）: bd の一過性失敗で no-notes に潰れても、復帰時に同一 STATUS を spurious re-notify しない。
# grilling → no-notes(bd 失敗) → 同 grilling → done と順送りし、grilling 通知は 1 回だけであることを固定する。
@test "grill-status-watch(loop): bd 一過性失敗→復帰で変化していない STATUS を再通知しない（F2）" {
  sf="$(mktemp)"
  cmd="$(_make_step_cmd "$sf" \
'[{"notes":"STATUS: grilling (1/3)"}]
{"error":"transient bd failure"}
[{"notes":"STATUS: grilling (1/3)"}]
[{"notes":"STATUS: done — 確定"}]')"
  run timeout 5 env GRILL_WATCH_JSON_CMD="$cmd" bash "$WATCH" sc-x 0
  rm -f "$sf"
  [ "$status" -eq 0 ]
  # bd 失敗をまたいでも grilling は 1 回しか通知されない（no-notes を遷移として扱わない）。
  [ "$(printf '%s\n' "$output" | grep -c 'STATUS changed: STATUS: grilling (1/3)')" -eq 1 ]
  [ "$(printf '%s\n' "$output" | grep -c 'STATUS changed: STATUS: done')" -eq 1 ]
}

# 回帰（sc-bka F3）: 非数値 interval は loop 突入前に弾く（return 2）。sleep で set -e クラッシュしない。
@test "grill-status-watch(loop): 非数値 interval を弾き死なない（F3・acceptance4 拡張）" {
  f="$(mktemp)"
  printf '%s' '[{"notes":"STATUS: grilling (1/3)"}]' > "$f"
  run timeout 5 env GRILL_WATCH_JSON_FILE="$f" bash "$WATCH" sc-x abc
  rm -f "$f"
  [ "$status" -eq 2 ]
  [[ "$output" == *"interval must be a non-negative integer: abc"* ]]
}

# 回帰（sc-bka 確認ラウンド）: 単一ダッシュの未知オプション（-x / -fetch typo 等）を unknown option として
# 弾く。`--*)` だけだと単一ダッシュが id 扱いで watch_loop に落ち、実 bd を叩いて無音で無限ブロックする。
@test "grill-status-watch: 単一ダッシュの未知オプション(-x)を弾く（typo で無限ループに落ちない）" {
  run timeout 5 bash "$WATCH" -x
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option: -x"* ]]
}

# ============================================================
# scribe-env-probe.sh（sc-sau・worker env 健全性 fail-closed probe）
# folio incident 0264028f: CC infra の Bash 非永続で self-verify が誤 PASS した。本 probe は
# plant→（別 Bash 呼出しの）verify で cross-call 永続を検出し、--base で 0-commit を検出する。
# ============================================================

# probe 用の hermetic な worktree+tmp-sentinel 環境。stdout に "<worktree>\t<tmp-sentinel>"。
_mk_probe_env() {
  local wt tmp
  wt="$(cd "$(mktemp -d)" && pwd -P)"
  tmp="$(mktemp -u)"   # 未作成パス（plant が作る）
  printf '%s\t%s\n' "$wt" "$tmp"
}

@test "env-probe: 未知モードを fail-loud（plant|verify 以外）" {
  run "$PROBE" frob --worktree /tmp
  [ "$status" -ne 0 ]
  [[ "$output" == *"未知のモード"* ]]
}

@test "env-probe: 引数なしで usage（非0）" {
  run "$PROBE"
  [ "$status" -ne 0 ]
}

@test "env-probe(plant): --worktree 必須" {
  run "$PROBE" plant
  [ "$status" -ne 0 ]
  [[ "$output" == *"--worktree"* ]]
}

@test "env-probe(plant): token を stdout に出し sentinel を書く" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  run env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"TOK123"* ]]
  [ "$(cat "$wt/.scribe-envprobe")" = "TOK123" ]
  [ "$(cat "$tmp")" = "TOK123" ]
  rm -rf "$wt" "$tmp"
}

@test "env-probe(plant・sc-zin): git リポで sentinel を info/exclude へ冪等登録し git 追跡から外す（verify 前の commit 混入を防ぐ）" {
  wt="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$wt" -c init.defaultBranch=main init -q
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK "$PROBE" plant --worktree "$wt" >/dev/null
  # 撒かれた sentinel は git の untracked 一覧に出てこない（info/exclude が効く＝scribe-add/素の git add -A 両経路で除外）
  run git -C "$wt" status --porcelain --untracked-files=all
  [[ "$output" != *".scribe-envprobe"* ]]
  [ "$(grep -cxF '.scribe-envprobe' "$wt/.git/info/exclude")" -eq 1 ]
  # 冪等: 二度目の plant でも info/exclude は 1 行のまま
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK2 "$PROBE" plant --worktree "$wt" >/dev/null
  [ "$(grep -cxF '.scribe-envprobe' "$wt/.git/info/exclude")" -eq 1 ]
  rm -rf "$wt" "$tmp"
}

@test "env-probe(plant・sc-zin): 非 git worktree では info/exclude 登録を no-op で飛ばし plant 本務は成功する（best-effort）" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"   # _mk_probe_env は非 git tmpdir
  run env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK "$PROBE" plant --worktree "$wt"
  [ "$status" -eq 0 ]                      # git 解決不能でも plant 本務は死なない
  [ "$(cat "$wt/.scribe-envprobe")" = "TOK" ]
  rm -rf "$wt" "$tmp"
}

@test "scribe_write_exclude(sc-zin): 任意 pattern を info/exclude へ冪等追記・非 git は no-op（return 0）" {
  r="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$r" -c init.defaultBranch=main init -q
  run bash -c 'source "$1"; scribe_write_exclude "$2" ".scribe-envprobe"' _ "$LIB" "$r"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '.scribe-envprobe' "$r/.git/info/exclude")" -eq 1 ]
  bash -c 'source "$1"; scribe_write_exclude "$2" ".scribe-envprobe"' _ "$LIB" "$r"   # 二度目=冪等
  [ "$(grep -cxF '.scribe-envprobe' "$r/.git/info/exclude")" -eq 1 ]
  n="$(cd "$(mktemp -d)" && pwd -P)"
  run bash -c 'source "$1"; scribe_write_exclude "$2" "X"' _ "$LIB" "$n"
  [ "$status" -eq 0 ]                      # 非 git は die せず no-op（fail-open で呼び出し元を殺さない）
  rm -rf "$r" "$n"
}

@test "scribe_sandbox_write_exclude(sc-zin): ラッパ化後も settings.local.json を info/exclude へ追記（後方互換）" {
  r="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$r" -c init.defaultBranch=main init -q
  bash -c 'source "$1"; scribe_sandbox_write_exclude "$2"' _ "$LIB" "$r"
  grep -qxF '**/.claude/settings.local.json' "$r/.git/info/exclude"
  rm -rf "$r"
}

@test "env-probe(verify): 健全（sentinel 残存・token 一致）→ ENV_OK exit 0 + sentinel 温存（再入可能・sc-0d2）" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK123 --worktree "$wt" --also-tmp
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV_OK"* ]]
  [ "$(cat "$wt/.scribe-envprobe")" = "TOK123" ]   # ENV_OK は sentinel を温存する（旧: 掃除→sc-0d2 で反転）
  rm -rf "$wt" "$tmp"
}

# sc-0d2 回帰: worker prompt は self-report を 2 時点（cell-quality 呼出し・gate-pending 付与）で踏むため
# verify が 2 回呼ばれうる。旧・単回使用（ENV_OK でも trap が sentinel を消費）では 2 回目が偽 ENV_DEGRADED
# になった（folio-c5r.5 実測・doobidoo 79d41450）。
@test "env-probe(verify・sc-0d2): 連続 2 回の verify がどちらも ENV_OK（double-verify 偽陽性の回帰）" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK123 --worktree "$wt" --also-tmp
  [ "$status" -eq 0 ]
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK123 --worktree "$wt" --also-tmp
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV_OK"* ]]
  rm -rf "$wt" "$tmp"
}

@test "env-probe(verify・sc-0d2): ENV_OK 時に info/exclude を冪等再登録する（plant 登録失敗時の第二防御）" {
  r="$(cd "$(mktemp -d)" && pwd -P)"; git -C "$r" -c init.defaultBranch=main init -q
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK "$PROBE" plant --worktree "$r" >/dev/null
  : > "$r/.git/info/exclude"   # plant の登録が失われた状況を模す
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK --worktree "$r"
  [ "$status" -eq 0 ]
  [ "$(grep -cxF '.scribe-envprobe' "$r/.git/info/exclude")" -eq 1 ]
  # 再登録も冪等（もう一度 verify しても重複登録しない）
  env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK --worktree "$r" >/dev/null
  [ "$(grep -cxF '.scribe-envprobe' "$r/.git/info/exclude")" -eq 1 ]
  # 温存された sentinel は exclude 済で git add / status に掛からない（温存判断の安全不変条件・sc-0d2）
  [ -f "$r/.scribe-envprobe" ]
  [ -z "$(git -C "$r" status --porcelain --untracked-files=all)" ]
  rm -rf "$r" "$tmp"
}

@test "env-probe(verify): worktree sentinel 消失（cross-call 非永続）→ ENV_DEGRADED exit 3" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt" >/dev/null
  rm -f "$wt/.scribe-envprobe"   # 呼出し間で消えた状況を模す
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK123 --worktree "$wt"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ENV_DEGRADED"* ]]
  [[ "$output" == *"非永続"* ]]
  rm -rf "$wt" "$tmp"
}

@test "env-probe(verify): token 不一致 → ENV_DEGRADED exit 3" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token WRONG --worktree "$wt"
  [ "$status" -eq 3 ]
  [[ "$output" == *"ENV_DEGRADED"* ]]
  rm -rf "$wt" "$tmp"
}

@test "env-probe(verify): --also-tmp で tmp sentinel 消失 → ENV_DEGRADED exit 3（folio の現場面）" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt" >/dev/null
  rm -f "$tmp"   # /tmp 面だけ消えた
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token TOK123 --worktree "$wt" --also-tmp
  [ "$status" -eq 3 ]
  [[ "$output" == *"tmp"* ]]
  rm -rf "$wt"
}

@test "env-probe(verify): --token 必須" {
  wt="$(cd "$(mktemp -d)" && pwd -P)"
  run "$PROBE" verify --worktree "$wt"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--token"* ]]
  rm -rf "$wt"
}

@test "env-probe(verify --base): base..HEAD が 0 commit → ENV_DEGRADED exit 4" {
  read -r main linked < <(_mk_main_and_linked)
  base="$(git -C "$main" rev-parse HEAD)"   # linked は init commit のみ＝base と同一 → 0 commit
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=T "$PROBE" plant --worktree "$linked" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token T --worktree "$linked" --base "$base"
  [ "$status" -eq 4 ]
  [[ "$output" == *"0 commit"* ]]
  [ ! -f "$linked/.scribe-envprobe" ]   # degraded(exit 4) でも trap が sentinel を掃除する（sc-0d2: 温存は ENV_OK のみ）
  [ ! -f "$tmp" ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main" "$tmp"
}

@test "env-probe(verify --base): commit あり → ENV_OK exit 0" {
  read -r main linked < <(_mk_main_and_linked)
  base="$(git -C "$linked" rev-parse HEAD)"
  git -C "$linked" commit -q --allow-empty -m work   # base..HEAD に 1 commit
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=T "$PROBE" plant --worktree "$linked" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token T --worktree "$linked" --base "$base"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV_OK"* ]]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main" "$tmp"
}

# review#4/#7 回帰: degraded（exit 3）でも trap で sentinel を残さない（worktree/tmp を汚さない）。
@test "env-probe(verify): degraded でも trap で sentinel を残さない（git add 巻き込み防止）" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=TOK123 "$PROBE" plant --worktree "$wt" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token WRONG --worktree "$wt" --also-tmp
  [ "$status" -eq 3 ]
  [ ! -f "$wt/.scribe-envprobe" ]   # degraded 経路でも trap EXIT が掃除する
  [ ! -f "$tmp" ]
  rm -rf "$wt"
}

# ---------- .git 書込劣化 probe（sc-owj・folio-229 偽陰性）----------
# folio-229 実測: worker worktree の .git が read-only mount 化し commit 不能だった間、verify は ENV_OK を
# 返し続けた（sentinel 永続(3)・0-commit(4) は .git 書込可否を probe しないため既存 commit 状態の書込劣化は
# 検出圏外）。verify に .git commit 実書込面（per-worktree GIT_DIR + 共有 GIT_COMMON_DIR）への touch/rm
# ラウンドトリップを足し ENV_DEGRADED exit 5 で fail-closed に倒す。
@test "env-probe(verify・sc-owj): per-worktree GIT_DIR が read-only → ENV_DEGRADED exit 5（既存 commit 状態でも捕捉）" {
  read -r main linked < <(_mk_main_and_linked)
  git -C "$linked" commit -q --allow-empty -m work   # 既存 commit あり（0-commit 検査は PASS する状態）
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=T "$PROBE" plant --worktree "$linked" >/dev/null
  local gd; gd="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$linked" rev-parse --absolute-git-dir)"
  chmod a-w "$gd"                                     # per-worktree の index/HEAD 面を書込不能化
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token T --worktree "$linked"
  chmod u+w "$gd"                                     # cleanup が worktree remove できるよう先に回復
  [ "$status" -eq 5 ]
  [[ "$output" == *"ENV_DEGRADED"* ]]
  [[ "$output" == *".git 書込劣化"* ]]
  [ ! -f "$linked/.scribe-envprobe" ]                # exit 5 も trap が sentinel を掃除する（温存は ENV_OK のみ）
  [ ! -f "$tmp" ]
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main" "$tmp"
}

@test "env-probe(verify・sc-owj): 共有 GIT_COMMON_DIR/objects が read-only → ENV_DEGRADED exit 5（loose object 実書込面・部分 RO も捕捉）" {
  read -r main linked < <(_mk_main_and_linked)
  git -C "$linked" commit -q --allow-empty -m work
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=T "$PROBE" plant --worktree "$linked" >/dev/null
  local cd; cd="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$linked" rev-parse --git-common-dir)"
  # commit の loose object 実書込先 objects/ のみを RO 化（.git ルートは writable のまま＝部分 RO）。
  # ルート probe では取りこぼす部分劣化を、実書込 subdir probe が捕捉することを pin する。
  chmod a-w "$cd/objects"
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token T --worktree "$linked"
  chmod u+w "$cd/objects"
  [ "$status" -eq 5 ]
  [[ "$output" == *".git 書込劣化"* ]]
  [[ "$output" == *"objects"* ]]                     # 実書込先（objects 面）を probe した証跡
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main" "$tmp"
}

# 健全な .git では probe が透過し ENV_OK を保つ + probe file の残骸を残さない（touch→rm ラウンドトリップの完結）。
@test "env-probe(verify・sc-owj): 健全 .git は probe を透過し ENV_OK・probe file 残骸なし" {
  read -r main linked < <(_mk_main_and_linked)
  git -C "$linked" commit -q --allow-empty -m work
  tmp="$(mktemp -u)"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=T "$PROBE" plant --worktree "$linked" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token T --worktree "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV_OK"* ]]
  local gd cd; gd="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$linked" rev-parse --absolute-git-dir)"
  cd="$(env -u GIT_DIR -u GIT_WORK_TREE git -C "$linked" rev-parse --git-common-dir)"
  run bash -c 'find "$1" "$2" -name ".scribe-wprobe.*" 2>/dev/null' _ "$gd" "$cd"
  [ -z "$output" ]                                    # probe file は毎回 rm される（残骸ゼロ）
  git -C "$main" worktree remove --force "$linked" 2>/dev/null || true
  rm -rf "$main" "$tmp"
}

# 非 git worktree（テスト seam・実 worker は常に git worktree）では git-path 解決不能 → probe を no-op skip し
# ENV_OK を保つ（この面の劣化は起こりえない＝probe 対象が無い）。既存 _mk_probe_env 系の ENV_OK が退行しない保証。
@test "env-probe(verify・sc-owj): 非 git worktree は .git 書込 probe を skip し ENV_OK（非退行）" {
  pe="$(_mk_probe_env)"; wt="${pe%%$'\t'*}"; tmp="${pe#*$'\t'}"
  env SCRIBE_ENVPROBE_TMP="$tmp" SCRIBE_ENVPROBE_TOKEN=T "$PROBE" plant --worktree "$wt" >/dev/null
  run env SCRIBE_ENVPROBE_TMP="$tmp" "$PROBE" verify --token T --worktree "$wt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV_OK"* ]]
  rm -rf "$wt" "$tmp"
}

# review#4 回帰: env-probe sentinel が .gitignore で ignore され worker の git add に巻き込まれない。
@test "gitignore: .scribe-envprobe を ignore する（worker の git add 巻き込み防止）" {
  run git -C "$REPO_ROOT" check-ignore .scribe-envprobe
  [ "$status" -eq 0 ]
}

# ---------- PreToolUse[Edit|Write|NotebookEdit|MultiEdit] guard（sc-649・SBX-ESC-1 封じ込め穴埋め）----------
# scribe worker の built-in ファイル編集を worktree 境界へ縛る（bwrap は Bash のみ封じるため）。活性化は
# spawn 注入の worker-immutable env `SCRIBE_WORKER=1` のみ（filesystem content を読まない=self-disable 不能）。
# $SCRIPTS は setup() 後に確定するためヘルパで解決。
_ewguard() { printf '%s' "$SCRIPTS/hooks/edit-write-guard.py"; }

# anchor + linked worker worktree の fixture（git 構造のみ。活性化は env ゆえ .beads は不要）。
# stdout に "<anchor>\t<worktree>"。in-tree .beads を仕込みたいテストは wt に自前で作る。
_mk_wt() {
  local anchor wt
  anchor="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$anchor" -c init.defaultBranch=main init -q
  git -C "$anchor" config user.email t@e; git -C "$anchor" config user.name t
  git -C "$anchor" commit -q --allow-empty -m init
  wt="$anchor/.worktrees/wtx"
  git -C "$anchor" worktree add -q -b wtx-branch "$wt" >/dev/null
  printf '%s\t%s' "$anchor" "$wt"
}

@test "edit-write-guard(sc-649): --self-test が緑（decide の境界・prefix・traversal・symlink・in-tree metadata を hermetic に pin）" {
  run python3 "$(_ewguard)" --self-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"SELF-TEST OK"* ]]
}

@test "edit-write-guard(sc-649): 実行可能である" {
  [ -x "$(_ewguard)" ]
}

@test "edit-write-guard(sc-649): worker(SCRIBE_WORKER=1) の worktree 内 Write は allow（exit 0）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$wt/foo.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 0 ]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): worker の worktree 外（anchor 直下）Write は deny（exit 2・SBX-ESC-1 経路）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$anchor/RELEASE.md\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]
  [[ "$output" == *"BLOCKED"* ]]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): worker の worktree 外（リポ完全外 /tmp）Edit は deny（exit 2）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Edit\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"/tmp/ewguard-evil-$$.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): worker の NotebookEdit(notebook_path) worktree 外は deny（exit 2）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"NotebookEdit\",\"cwd\":\"$wt\",\"tool_input\":{\"notebook_path\":\"$anchor/x.ipynb\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): worker の MultiEdit(file_path) worktree 外は deny（exit 2・matcher に MultiEdit を含む）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"MultiEdit\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$anchor/m.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): self-disable 回帰 — worktree 内に汚染 .beads/metadata.json があっても guard は依然発火する（活性化に台帳を読まない）" {
  # gate round1 critical の回帰。旧設計は _is_scribe_guard_session が worktree ローカルの tracked
  # metadata.json を読み、worker がそれを非 sc へ書換えて guard を自己無効化できた。新設計は活性化を
  # env `SCRIBE_WORKER=1` のみに依存し filesystem content を読まないため、metadata を汚染しても発火し続ける。
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  mkdir -p "$wt/.beads"; printf '{"dolt_database":"orch"}\n' > "$wt/.beads/metadata.json"   # worker が書換えた想定
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$anchor/escape.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]   # 汚染 metadata に関係なく worktree 外は依然 deny＝self-disable 不能
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): 境界 escalation 回帰 — worker が worktree の .git を rm しても SCRIBE_WORKTREE env が境界を保つ（anchor へ広がらない）" {
  # gate round2 major の回帰。旧設計は境界を git toplevel(cwd) から導出＝worker が <worktree>/.git（単一
  # ファイル gitfile）を非再帰 rm すると git が anchor へ walk-up し境界が anchor 全体へ広がった。新設計は
  # 境界を spawn 注入の SCRIBE_WORKTREE env から取るため .git を消しても境界は worktree のまま。
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  rm "$wt/.git"   # linked worktree の gitfile は単一ファイル＝非再帰 rm で消せる（rm-guard は再帰のみ block）
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$anchor/escape.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]   # SCRIBE_WORKTREE env が境界＝.git 破壊に関係なく anchor 外は deny
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): 境界は SCRIBE_WORKTREE env を最優先（内=allow・外=deny）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$wt/in.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 0 ]
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$anchor/out.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): SCRIBE_WORKER=1 だが SCRIBE_WORKTREE 未設定 → fail-closed deny（git fallback へ落とさない・gate round3）" {
  # round3: git_toplevel fallback を撤去し、worker 文脈で境界を確立できなければ deny（git 構造を信用しない）。
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$wt/in.txt\"}}' | env -u SCRIBE_WORKTREE SCRIBE_WORKER=1 python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]   # 境界未確立 → fail-closed（worktree 内書込みすら通さない＝安全側）
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): SCRIBE_WORKTREE が非存在ディレクトリ → fail-closed deny（境界破損を fail-open にしない）" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"$wt/in.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE=/nonexistent/broken-wt python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "spawn(sc-649): worker env-file は SCRIBE_WORKTREE を %q で source-safe に焼く（空白/メタ文字パスの語分割・source インジェクションを防ぐ・gate round3）" {
  # scribe-spawn の生成方式（printf %q）と同型で空白入りパスの env-file を作り、cld-spawn 相当の source で
  # 原値が復元されることを pin する（%s だと語分割で SCRIBE_WORKTREE が切り詰められる回帰を counterfactual で封じる）。
  local ef wtpath got
  ef="$(mktemp)"; wtpath='/home/a b/.worktrees/sc x'
  printf 'export SCRIBE_WORKER=1\nexport SCRIBE_WORKTREE=%q\n' "$wtpath" > "$ef"
  got="$(bash -c "source '$ef' 2>/dev/null; printf '%s' \"\$SCRIBE_WORKTREE\"")"
  [ "$got" = "$wtpath" ]     # source 後に原値（空白込み）が復元される
  rm -f "$ef"
  # scribe-spawn 本体が %q（%s でない）で焼くことを source で pin（現ホストに空白が無くても回帰を守る）。
  run grep -F "SCRIBE_WORKTREE=%q" "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -F "SCRIBE_WORKTREE=%s" "$SPAWN"
  [ "$status" -ne 0 ]        # 無引用 %s が残っていない
}

@test "spawn(sc-649): worker env-file はホスト既定 env（CLD_ENV_FILE/~/.cld-env）を chain-source する（--env-file 排他置換による認証/秘密喪失を防ぐ・gate round4）" {
  # cld-spawn の env-file 解決は排他（--env-file が ~/.cld-env 既定 source を置換）。worker は隔離対象でない
  # ため、生成 env-file が既定 env-file を先に source してから SCRIBE signal を足すこと（順序込み・両立）を pin する。
  # (a) 生成器が既定 env を chain-source する行を持つ（実 spawn 経路・dry-run mirror でなく source で pin）。
  run grep -F "source %q 2>/dev/null || true" "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -F 'CLD_ENV_FILE:-$HOME/.cld-env' "$SPAWN"
  [ "$status" -eq 0 ]
  # (b) 実機: 既定 env（サンプル値）を先に source → SCRIBE signal を後に export すると両方が並立する
  #     （chain-source が既定を潰さず、順序も正しい＝gate round4 の boot-path 回帰 counterfactual）。
  local defenv ef got
  defenv="$(mktemp)"; printf 'export SAMPLE_HOST_SECRET=xyz\n' > "$defenv"
  ef="$(mktemp)"
  { printf 'source %q 2>/dev/null || true\n' "$defenv"; printf 'export SCRIBE_WORKER=1\nexport SCRIBE_WORKTREE=%q\n' '/tmp/wt'; } > "$ef"
  got="$(bash -c "source '$ef' 2>/dev/null; printf '%s|%s' \"\$SAMPLE_HOST_SECRET\" \"\$SCRIBE_WORKER\"")"
  [ "$got" = "xyz|1" ]       # 既定 env の値と SCRIBE signal が両立（chain-source が既定を潰さない）
  rm -f "$defenv" "$ef"
  # (c) scribe-spawn が %q 前に先頭チルダを $HOME へ展開すること（cld-spawn:278 parity・literal ~ 設定での
  #     既定 env 取りこぼしを防ぐ・gate round5）を source で pin。
  run grep -F 'HOME}' "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -E '_worker_def_env=.*/#.~/.HOME' "$SPAWN"
  [ "$status" -eq 0 ]
}

@test "spawn(sc-649): chain-source は literal-tilde の CLD_ENV_FILE でも既定 env を source する（%q 前に ~ 展開・gate round5）" {
  # 現状の生成ロジックと同型で literal ~ を展開してから焼き、source で原ファイルに解決されることを実機確認。
  local d ef got def
  d="$(mktemp -d)"; printf 'export TILDE_SECRET=ok\n' > "$d/.cld-env"
  def='~/.cld-env'
  def="${def/#\~/$d}"                 # scribe-spawn と同式で先頭 ~ を展開（テストでは $d を HOME 代用）
  ef="$(mktemp)"
  { printf 'source %q 2>/dev/null || true\n' "$def"; printf 'export SCRIBE_WORKER=1\n'; } > "$ef"
  got="$(bash -c "source '$ef' 2>/dev/null; printf '%s' \"\$TILDE_SECRET\"")"
  [ "$got" = "ok" ]                    # 展開後は literal ~ でも既定 env が source される（auth-loss 回避）
  rm -rf "$d" "$ef"
}

@test "edit-write-guard(sc-649): 非 worker（SCRIBE_WORKER 未設定・admin/foreign）は発火せず worktree 外書込みも allow" {
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  # SCRIBE_WORKER を明示的に空にして起動（admin/foreign セッションを模す）。worktree cwd + 外部パスでも非発火。
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"cwd\":\"$wt\",\"tool_input\":{\"file_path\":\"/tmp/ewg-nonworker-$$.txt\"}}' | env -u SCRIBE_WORKER python3 '$(_ewguard)'"
  [ "$status" -eq 0 ]   # env signal 無し＝発火せず（admin の全リポ編集/foreign project を壊さない）
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): cwd 欠落 + 境界外の絶対パスは deny（境界は SCRIBE_WORKTREE ゆえ cwd 不要・fail-closed へ統一・gate round3）" {
  # round3 finding4: SCRIBE_WORKTREE が権威になった今、cwd 欠落でも絶対パスは境界判定でき、境界外は deny。
  local p anchor wt; p="$(_mk_wt)"; anchor="${p%%$'\t'*}"; wt="${p#*$'\t'}"
  run bash -c "printf '%s' '{\"tool_name\":\"Write\",\"tool_input\":{\"file_path\":\"$anchor/out.txt\"}}' | SCRIBE_WORKER=1 SCRIBE_WORKTREE='$wt' python3 '$(_ewguard)'"
  [ "$status" -eq 2 ]   # cwd 欠落でも SCRIBE_WORKTREE 境界外の絶対パスは deny（fail-open にしない）
  git -C "$anchor" worktree remove --force "$wt" 2>/dev/null || true; rm -rf "$anchor"
}

@test "edit-write-guard(sc-649): 壊れた JSON 入力は fail-open（exit 0・guard バグで worker を brick しない）" {
  run bash -c "printf '%s' '{bad json' | SCRIBE_WORKER=1 SCRIBE_WORKTREE=/tmp python3 '$(_ewguard)'"
  [ "$status" -eq 0 ]
}

@test "hooks(sc-649): PreToolUse に matcher='Edit|Write|NotebookEdit|MultiEdit' の block があり edit-write-guard.py を指す（|| true を付けない）" {
  run python3 -c "import json; h=json.load(open('$HOOKS_JSON')); pre=h['hooks']['PreToolUse']; \
m=[b for b in pre if b.get('matcher')=='Edit|Write|NotebookEdit|MultiEdit']; assert len(m)==1, 'matcher 欠落/不一致'; \
cmd=m[0]['hooks'][0]['command']; assert 'edit-write-guard.py' in cmd, 'guard 未配線'; assert '|| true' not in cmd, 'guard に || true 禁止（exit2 を伝播）'; print('OK')"
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "spawn(sc-649): worker 起動は SCRIBE_WORKER=1 + SCRIBE_WORKTREE の env-file を注入する（activation+境界 signal）" {
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"SCRIBE_WORKER=1"* ]]      # activation signal
  [[ "$output" == *"SCRIBE_WORKTREE="* ]]     # 境界 signal（worker-immutable な worktree 絶対パス）
  [[ "$output" == *"--env-file"* ]]           # worker cld-spawn は env-file を持つ
  [[ "$output" != *"SCRIBE_ROLE=consult"* ]]  # worker は consult env を持たない
}

@test "spawn(sc-649): 実 worker cld-spawn 起動行が --env-file \"\$WORKER_ENV_FILE\" を持つ（dry-run mirror でなく実行路を source で pin）" {
  # minor round2: dry-run plan だけでなく実 invocation 行（cld-spawn 実行）が env-file を渡すことを source で確認。
  run grep -E '\$CLD_SPAWN" --cd "\$WORKTREE".*--env-file "\$WORKER_ENV_FILE"' "$SPAWN"
  [ "$status" -eq 0 ]
  # env-file の mktemp が worktree add より前にあること（mktemp 失敗で orphan を作らない・gate round2 minor）。
  run bash -c "grep -n 'WORKER_ENV_FILE=\"\$(mktemp' '$SPAWN' | cut -d: -f1"
  local mktemp_ln="$output"
  run bash -c "grep -n 'worktree add -b \"\$BRANCH\"' '$SPAWN' | cut -d: -f1"
  local add_ln="$output"
  [ "$mktemp_ln" -lt "$add_ln" ]
}

#!/usr/bin/env bats
# skills/setup/check-ledger-separation.sh（bd 台帳とコード repo の分離を検査する機械条件 2 本）と、
# それを 3 箇所へ配線した skills/setup/SKILL.md を検証する（bd sc-zkof / orchestrator 裁定 orch-jot0）。
#
# 規約の SSOT = bd sc-zkof の acceptance と SCOPE FENCE。本 bats が守る核心は次の 3 点:
#   1. 判定は「散文 + 散文を grep する bats」でなく **実行可能 checker** が持つ（doc-pin 禁止）。
#   2. 条件 1 は **3 値**（OK / VIOLATION / UNKNOWN）。判定不能を OK に畳まない（fail-open 封鎖）。
#   3. 条件 2 は **正規化後の完全一致**で 3 経路（col0 平坦 / nested / dolt レジストリの実 push 先）を OR 判定。
#      本リポ自身が `scribe` と `scribe-beads` という接頭辞衝突の実例なので、部分一致実装は分離済みの正を
#      違反と誤報する。2c を欠く実装は 2026-07-27 incident そのものの状態（config は private・実 push 先は
#      コード repo）を green と報告するため受け入れない。
#
# **network に出ない**: 条件 1 は `git init --bare` した local fixture、URL 形の同一視は stub git、
# 実 push 先は stub bd で hermetic に再現する。実 origin へ push しない。実 anchor の .beads は read もしない
# （本 bats が触る実ファイルは worktree の tracked な config.yaml と SKILL.md の **read だけ**）。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  CHECKER="$REPO_ROOT/skills/setup/check-ledger-separation.sh"
  SKILL="$REPO_ROOT/skills/setup/SKILL.md"

  # --- stub bd（常に PATH 前置）: `bd dolt remote list` のみ再現する。
  #     cwd の .bd-stub-remote（1 行 1 URL・空ファイル = remote 未設定）を返す。
  #     BD_STUB_RC≠0 で「bd 実行不能＝実 push 先を確認できない」を再現する。
  BDSTUB="$BATS_TEST_TMPDIR/bdstub"
  mkdir -p "$BDSTUB"
  #     `bd where` も再現する（checker は 2c を台帳へ pin するため解決先を実測する）。実 bd の出力形に
  #     忠実化して **path 行 + `database:` 行**を出す（実測: 構成により `prefix:` 行は出ないことがあるので
  #     行番号ではなくキーで拾われる前提）。既定の解決先は cwd の .beads / その配下 embeddeddolt。
  #     `.bd-stub-where` を置くと **path は cwd の .beads だが database: だけ祖先台帳**という
  #     ambient 解決状態（実 bd で実測された masking の型）を再現できる。
  cat > "$BDSTUB/bd" <<'STUB'
#!/usr/bin/env bash
rc="${BD_STUB_RC:-0}"
if [ "$rc" -ne 0 ]; then echo "bd-stub: forced failure" >&2; exit "$rc"; fi
case "${1:-}" in
  where)
    if [ -f ./.bd-stub-where ]; then
      cat ./.bd-stub-where
    else
      printf '%s\n  prefix: stub\n  database: %s\n' "$PWD/.beads" "$PWD/.beads/embeddeddolt"
    fi
    exit 0 ;;
esac
if [ -f ./.bd-stub-remote ]; then
  while IFS= read -r u; do [ -n "$u" ] && printf 'origin               %s\n' "$u"; done < ./.bd-stub-remote
fi
exit 0
STUB
  chmod +x "$BDSTUB/bd"

  # --- stub git（必要なテストだけが PATH へ前置する）: checker の外向き git 呼出しのみ再現。
  #     `--repo` を渡す前提なので rev-parse は使わない。network には出ない。
  GITSTUB="$BATS_TEST_TMPDIR/gitstub"
  mkdir -p "$GITSTUB"
  cat > "$GITSTUB/git" <<'STUB'
#!/usr/bin/env bash
args=(); while [ $# -gt 0 ]; do case "$1" in -C) shift 2 ;; *) args+=("$1"); shift ;; esac; done
case "${args[0]:-}" in
  # `git remote`（引数なし）は **remote 名の列挙**、`git remote get-url <name>` は URL。
  # 両者を同じ出力にすると checker が「URL という名前の remote」を見て origin 不在と誤認する。
  remote)
    case "${args[1]:-}" in
      get-url) printf '%s\n' "${GIT_STUB_ORIGIN:-}" ;;
      "")      printf '%s\n' "${GIT_STUB_REMOTES:-origin}" ;;
    esac ;;
  rev-parse) exit "${GIT_STUB_REVPARSE_RC:-0}" ;;
  ls-remote) [ -n "${GIT_STUB_LSREMOTE:-}" ] && printf '%s\n' "$GIT_STUB_LSREMOTE"
             exit "${GIT_STUB_LSREMOTE_RC:-0}" ;;
  # check-ignore の rc は「0=ignored / 1=ignored でない」。既定は 1（ignored でない）——
  # 既定 0 にすると checker が全台帳を ephemeral 扱いで skip し、違反 fixture が緑になる。
  check-ignore) exit "${GIT_STUB_CHECKIGNORE_RC:-1}" ;;
esac
exit 0
STUB
  chmod +x "$GITSTUB/git"

  export PATH="$BDSTUB:$PATH"
}

# --- fixture helpers --------------------------------------------------------

# mk_work <name> — bare な「コード repo」<name>.git と、それを origin に持つ作業 repo を作る。
#   標準出力に作業 repo の絶対パス。network に出ない（local path remote）。
mk_work() {
  local name="$1"
  local code="$BATS_TEST_TMPDIR/$name.git"
  local work="$BATS_TEST_TMPDIR/$name-work"
  git init -q --bare "$code"
  git -c init.defaultBranch=main init -q "$work"
  git -C "$work" config user.email t@e
  git -C "$work" config user.name t
  git -C "$work" commit -q --allow-empty -m init
  git -C "$work" remote add origin "$code"
  printf '%s' "$work"
}

# push_dolt_ref <work> — コード repo へ refs/dolt/data を作る（条件 1 の違反状態）。
push_dolt_ref() {
  git -C "$1" push -q origin HEAD:refs/dolt/data
}

# put_ledger <work> <relpath|.> <mode: flat|nested|both|none> <url>
#   live な台帳を模すため embeddeddolt も作る（checker は `database:` が当該 .beads 配下に **実在**する
#   ことを 2c の前提にする＝DB 不在は live な台帳ではないので 2c: UNKNOWN）。
put_ledger() {
  local work="$1" rel="$2" mode="$3" url="${4:-}"
  local d
  if [ "$rel" = "." ]; then d="$work/.beads"; else d="$work/$rel/.beads"; fi
  mkdir -p "$d/embeddeddolt"
  : > "$d/config.yaml"
  case "$mode" in
    flat)   printf 'sync.remote: "%s"\n' "$url" >> "$d/config.yaml" ;;
    nested) printf 'sync:\n    remote: "%s"\n' "$url" >> "$d/config.yaml" ;;
    both)   printf 'sync:\n    remote: "%s"\nsync.remote: "%s"\n' "$url" "$url" >> "$d/config.yaml" ;;
    none)   printf '# remote は書かない\n' >> "$d/config.yaml" ;;
  esac
}

# put_dolt_remote <ledger の親ディレクトリ> [url] — stub bd が返す「実 push 先」を置く。
put_dolt_remote() {
  local parent="$1" url="${2:-}"
  mkdir -p "$parent"
  if [ -n "$url" ]; then printf '%s\n' "$url" > "$parent/.bd-stub-remote"; else : > "$parent/.bd-stub-remote"; fi
}

# ---------------------------------------------------------------------------
# 0. 形式
# ---------------------------------------------------------------------------

@test "checker: bash -n 構文 OK かつ実行可能" {
  run bash -n "$CHECKER"
  [ "$status" -eq 0 ]
  [ -x "$CHECKER" ]
}

@test "checker: scripts/ でなく skills/setup/ 配下に在る（fence: scripts/ は fence 外）" {
  [ -f "$REPO_ROOT/skills/setup/check-ledger-separation.sh" ]
  run test -e "$REPO_ROOT/scripts/check-ledger-separation.sh"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 1. 機械条件 1 の 3 値判定（rc=0&0行→OK / rc=0&1行以上→違反 / rc≠0→UNKNOWN）
# ---------------------------------------------------------------------------

@test "条件1: コード repo に refs/dolt/* が 0 件 → COND1: OK / RESULT: CLEAN(rc=0)" {
  w="$(mk_work sep-a)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-a-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-a-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND1: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "条件1: コード repo に refs/dolt/data が実在 → COND1: VIOLATION / rc=1" {
  w="$(mk_work sep-b)"
  push_dolt_ref "$w"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-b-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-b-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND1: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
  # 条件 2 は清浄なので、赤は条件 1 由来であることを明示 pin する。
  [[ "$output" == *"COND2: OK"* ]]
}

@test "条件1: origin が到達不能 → COND1: UNKNOWN / rc=2（決して OK に畳まない）" {
  w="$BATS_TEST_TMPDIR/sep-c-work"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  git -C "$w" remote add origin "$BATS_TEST_TMPDIR/does-not-exist.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND1: UNKNOWN"* ]]
  [[ "$output" == *"RESULT: UNKNOWN"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

# ---------------------------------------------------------------------------
# 2. 機械条件 2 — 正規化後の完全一致（部分一致禁止）
# ---------------------------------------------------------------------------

@test "条件2 正例: 接頭辞衝突 scribe vs scribe-beads は PASS（部分一致実装なら偽 RED になる）" {
  # 本リポ自身の実配置（コード repo = .../scribe / 台帳 = .../scribe-beads）を local fixture で再現する。
  local code="$BATS_TEST_TMPDIR/scribe.git"
  local work="$BATS_TEST_TMPDIR/scribe-work"
  git init -q --bare "$code"
  git init -q --bare "$BATS_TEST_TMPDIR/scribe-beads.git"
  git -c init.defaultBranch=main init -q "$work"
  git -C "$work" config user.email t@e; git -C "$work" config user.name t
  git -C "$work" commit -q --allow-empty -m init
  git -C "$work" remote add origin "$code"
  put_ledger "$work" . both "git+file://$BATS_TEST_TMPDIR/scribe-beads.git"
  put_dolt_remote "$work" "git+file://$BATS_TEST_TMPDIR/scribe-beads.git"
  run "$CHECKER" --repo "$work"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "条件2 (2a col0 平坦のみ): sync.remote がコード repo → VIOLATION / rc=1" {
  w="$(mk_work sep-d)"
  put_ledger "$w" . flat "git+file://$BATS_TEST_TMPDIR/sep-d.git"     # ← コード repo 自身
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-d-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
  [[ "$output" == *"COND2 .beads 2b: ABSENT"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "条件2 (2b nested のみ): sync: ブロックの remote: がコード repo → VIOLATION / rc=1" {
  w="$(mk_work sep-e)"
  put_ledger "$w" . nested "git+file://$BATS_TEST_TMPDIR/sep-e.git"   # ← コード repo 自身
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-e-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2b: VIOLATION"* ]]
  [[ "$output" == *"COND2 .beads 2a: ABSENT"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "条件2 (両形 both): 2 形態が同時に実在し双方 private → 2a/2b とも OK（同値重複は正常）" {
  w="$(mk_work sep-f)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-f-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-f-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2 .beads 2a: OK"* ]]
  [[ "$output" == *"COND2 .beads 2b: OK"* ]]
  [[ "$output" == *"COND2 .beads 2c: OK"* ]]
}

@test "条件2 (2c が真の決定点): config は private でも dolt レジストリがコード repo なら VIOLATION" {
  # 2026-07-27 incident そのものの状態。config だけを見る実装はこれを green と報告する。
  w="$(mk_work sep-g)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-g-beads.git"
  put_dolt_remote "$w" "file://$BATS_TEST_TMPDIR/sep-g.git"           # ← 実 push 先はコード repo
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: OK"* ]]
  [[ "$output" == *"COND2 .beads 2b: OK"* ]]
  [[ "$output" == *"COND2 .beads 2c: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "条件2 (2c 判定不能): bd が実行不能なら COND2: UNKNOWN / rc=2（OK に畳まない）" {
  w="$(mk_work sep-h)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-h-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-h-beads.git"
  BD_STUB_RC=1 run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
  [[ "$output" == *"COND2: UNKNOWN"* ]]
  [[ "$output" == *"RESULT: UNKNOWN"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "条件2 (2c 未設定): remote 未設定の local-only 台帳は ABSENT 扱いで CLEAN" {
  w="$(mk_work sep-i)"
  put_ledger "$w" . none
  put_dolt_remote "$w" ""
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2 .beads 2c: ABSENT"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

# ---------------------------------------------------------------------------
# 3. URL 正規化（ssh / https 混在形の同一視・末尾 .git・git+ 前置・大小文字）
# ---------------------------------------------------------------------------

@test "正規化: origin=https 形 / config=ssh 形 の同一 repo を同一視して VIOLATION" {
  w="$BATS_TEST_TMPDIR/norm-a"
  put_ledger "$w" . flat "git+git@github.com:shuu5/scribe.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe"
  export GIT_STUB_LSREMOTE_RC=0
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "正規化: origin=ssh 形 / config=https 形 の同一 repo を同一視して VIOLATION" {
  w="$BATS_TEST_TMPDIR/norm-b"
  put_ledger "$w" . nested "git+https://GitHub.com/shuu5/scribe.git/"
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="git@github.com:shuu5/scribe.git"
  export GIT_STUB_LSREMOTE_RC=0
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2b: VIOLATION"* ]]
}

@test "正規化: 接頭辞衝突 scribe vs scribe-beads は ssh/https 混在でも PASS" {
  w="$BATS_TEST_TMPDIR/norm-c"
  put_ledger "$w" . both "git+git@github.com:shuu5/scribe-beads.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe.git"
  export GIT_STUB_LSREMOTE_RC=0
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "優先順位: 違反(条件2) と 判定不能(条件1) が同時なら rc=1（違反が勝つ）" {
  w="$BATS_TEST_TMPDIR/norm-d"
  put_ledger "$w" . flat "git+https://github.com/shuu5/scribe.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe"
  export GIT_STUB_LSREMOTE_RC=128
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND1: UNKNOWN"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

# ---------------------------------------------------------------------------
# 4. 適用単位 = repo 内に実在する全 .beads（git root の 1 つだけではない）
# ---------------------------------------------------------------------------

@test "全 .beads 適用: 従属ディレクトリの 2 台帳目が違反なら repo 全体が RED" {
  w="$(mk_work sep-j)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-j-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-j-beads.git"
  put_ledger "$w" sub flat "git+file://$BATS_TEST_TMPDIR/sep-j.git"   # ← 従属台帳がコード repo を指す
  put_dolt_remote "$w/sub" "git+file://$BATS_TEST_TMPDIR/sep-j-sub-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: OK"* ]]
  [[ "$output" == *"COND2 sub/.beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "全 .beads 適用: 2 台帳とも別々の private 先なら CLEAN（両方が検査されている）" {
  w="$(mk_work sep-k)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-k-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-k-beads.git"
  put_ledger "$w" sub flat "git+file://$BATS_TEST_TMPDIR/sep-k-sub-beads.git"
  put_dolt_remote "$w/sub" "git+file://$BATS_TEST_TMPDIR/sep-k-sub-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2 .beads 2c: OK"* ]]
  [[ "$output" == *"COND2 sub/.beads 2c: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "走査範囲: .worktrees 配下の **非 live** stale checkout は台帳として数えない（anchor の偽 RED 回帰 pin）" {
  # 本リポ anchor は .worktrees/spawn/<cell>/ に他 cell の checkout を持つ（.gitignore 済み・ephemeral）。
  # 分離前 commit の config が残っているだけで anchor 全体が RESULT: VIOLATION になると、
  # SKILL.md の規定により /scribe:setup が構造的に停止する（恒常 false RED → gate 無視の誘発）。
  # ★除外の根拠は「ディレクトリ名が .worktrees だから」ではなく「git-ignored かつ DB 実体なし」。
  #   live な台帳は .worktrees 配下でも評価される（→ C1 の tooth が対）ので、fixture は DB 実体なしにする。
  w="$(mk_work sep-wt)"
  printf '/.worktrees/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-wt-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-wt-beads.git"
  # ephemeral な worktree checkout に「分離前」の違反 config を置く（DB 実体は持たない＝実測どおり）。
  put_ledger "$w" .worktrees/spawn/other-cell flat "git+file://$BATS_TEST_TMPDIR/sep-wt.git"
  put_dolt_remote "$w/.worktrees/spawn/other-cell" "git+file://$BATS_TEST_TMPDIR/sep-wt.git"
  rm -rf "$w/.worktrees/spawn/other-cell/.beads/embeddeddolt"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: CLEAN"* ]]
  [[ "$output" != *".worktrees/spawn/other-cell/.beads 2a: VIOLATION"* ]]
  # 実在台帳のほうは依然として検査されている（走査ごと落としたのではない）。
  [[ "$output" == *"COND2 .beads 2c: OK"* ]]
}

@test "走査範囲: git-ignored **かつ DB 実体なし**のコピーは数えない（tracked な違反は依然 RED）" {
  # 除外述語は「git-ignored かつ live でない」。ignored であることだけを理由に落とすと、そこが
  # 公開面を指していても CLEAN になる（→ 下の「ignored でも live なら RED」tooth が対）。
  w="$(mk_work sep-ign)"
  printf 'vendor-cache/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-ign-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-ign-beads.git"
  put_ledger "$w" vendor-cache/x flat "git+file://$BATS_TEST_TMPDIR/sep-ign.git"   # ignored な違反
  put_dolt_remote "$w/vendor-cache/x" "git+file://$BATS_TEST_TMPDIR/sep-ign.git"
  rm -rf "$w/vendor-cache/x/.beads/embeddeddolt"                                   # ← DB 実体なし＝ephemeral
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: CLEAN"* ]]
  [[ "$output" == *"skip — git-ignored かつ DB 実体なし"* ]]

  # 対照: ignored でない（untracked でも可）従属台帳の違反は今までどおり RED のまま。
  put_ledger "$w" sub flat "git+file://$BATS_TEST_TMPDIR/sep-ign.git"
  put_dolt_remote "$w/sub" "git+file://$BATS_TEST_TMPDIR/sep-ign-sub-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 sub/.beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "2c pin: bd の解決先が別台帳なら OK に畳まず UNKNOWN（ambient 解決による masking の封鎖）" {
  # DB を持たない .beads では bd が祖先の台帳へ解決する（環境変数 BEADS_DIR も cwd より優先される）。
  # pin しない実装は「別台帳の清浄な remote」をこの台帳の 2c: OK として報告してしまう。
  w="$(mk_work sep-pin)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-pin-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-pin-beads.git"
  # 解決先を別台帳（祖先）に見せかける。
  printf '%s\n' "$BATS_TEST_TMPDIR/some-other-anchor/.beads" > "$w/.bd-stub-where"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
  [[ "$output" == *"COND2: UNKNOWN"* ]]
  [[ "$output" != *"COND2 .beads 2c: OK"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "条件1 補助: refs/dolt/* の外に居る dolt 由来 ref を surface する（rc は変えない）" {
  # dolt の git-remote 実装は refs/heads/__dolt_remote_info__ も push する。glob refs/dolt/* は
  # これを拾わないため、条件1 が OK でも台帳由来 ref が公開面に残りうる（実測: 本リポのコード repo に残存）。
  w="$(mk_work sep-extra)"
  git -C "$w" push -q origin HEAD:refs/heads/__dolt_remote_info__
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-extra-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-extra-beads.git"
  run "$CHECKER" --repo "$w"
  # 検出は fail-loud に出る。
  [[ "$output" == *"COND1-EXTRA: DOLT-REF-OUTSIDE-GLOB refs/heads/__dolt_remote_info__"* ]]
  # rc の意味は変えない（既存 ref の削除は破壊操作＝人間承認事案ゆえ、報告に留めて reconciler は止めない）。
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND1: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "条件1 補助: 該当 ref が無ければ COND1-EXTRA 行は出ない（安売りしない）" {
  w="$(mk_work sep-noextra)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-noextra-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-noextra-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" != *"COND1-EXTRA:"* ]]
}

# ---------------------------------------------------------------------------
# 4b. errata R1 — 除外規則・pin・identity・引数処理の fail-open / dead-end 封鎖
# ---------------------------------------------------------------------------

@test "E1 2c pin: path は一致しても database: が祖先台帳なら 2c: UNKNOWN（実 bd で実測された masking の型）" {
  # 実 bd の実測: DB(embeddeddolt) を持たない .beads では `bd where` の path 行に cwd の .beads を返しつつ
  # database: 行だけが祖先台帳を指す。path 行だけを比べる pin はこれを通し、祖先台帳の remote を
  # 当該台帳の 2c: OK として報告する（fail-open）。
  w="$(mk_work sep-dbpin)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-dbpin-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-dbpin-beads.git"
  # path は一致・database: だけ祖先台帳。**祖先の DB は実在させる**（実 bd での状況を忠実に再現する）。
  # 実在させないと「DB 不在」検査だけで UNKNOWN になり、包含判定そのものが pin されない（変異で無反応になる）。
  mkdir -p "$BATS_TEST_TMPDIR/ancestor/.beads/embeddeddolt"
  printf '%s\n  database: %s\n' "$w/.beads" "$BATS_TEST_TMPDIR/ancestor/.beads/embeddeddolt" \
    > "$w/.bd-stub-where"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
  [[ "$output" != *"COND2 .beads 2c: OK"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "E1 2c pin: database: が実在しない（live な台帳でない）なら 2c: UNKNOWN" {
  w="$(mk_work sep-nodb)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-nodb-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-nodb-beads.git"
  rmdir "$w/.beads/embeddeddolt"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
}

@test "E1 2c pin: bd where が database: を出さない出力形なら 2c: UNKNOWN（行番号に依存しない）" {
  w="$(mk_work sep-nodbkey)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-nodbkey-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-nodbkey-beads.git"
  printf '%s\n  prefix: stub\n' "$w/.beads" > "$w/.bd-stub-where"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
}

@test "E2 除外の安全弁1: .gitignore が .beads/ を含む repo でも root 台帳は評価する（違反は RED）" {
  # root 台帳ごと check-ignore で落とすと候補 0＝「未導入」＝COND2: OK＝CLEAN rc=0 に化け、
  # 違反 config を持つ repo を清浄と報告してしまう（--quiet では skip 行も見えず rc=0 だけが残る）。
  w="$(mk_work sep-igroot)"
  printf '.beads/\n' > "$w/.gitignore"
  put_ledger "$w" . flat "git+file://$BATS_TEST_TMPDIR/sep-igroot.git"   # ← コード repo 自身＝違反
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-igroot-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
  # --quiet でも rc は 1（詳細行が消えても判定は変わらない）。
  run "$CHECKER" --repo "$w" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "E2 除外の安全弁1: root 台帳が清浄なら .gitignore に .beads/ が在っても CLEAN（過剰赤化しない）" {
  w="$(mk_work sep-igroot2)"
  printf '.beads/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-igroot2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-igroot2-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "E2 除外の安全弁2: 候補 1 件以上で評価対象 0 件は COND2: UNKNOWN（OK に畳まない）" {
  # root 台帳を持たず、従属台帳だけが ignored な構成。候補は在るのに全て落ちる＝除外規則が
  # 判定を空洞化している状態。OK に畳むと「除外規則そのもの」が fail-open になる。
  w="$(mk_work sep-allskip)"
  printf 'vendor-cache/\n' > "$w/.gitignore"
  put_ledger "$w" vendor-cache/x flat "git+file://$BATS_TEST_TMPDIR/sep-allskip.git"
  put_dolt_remote "$w/vendor-cache/x" "git+file://$BATS_TEST_TMPDIR/sep-allskip.git"
  rm -rf "$w/vendor-cache/x/.beads/embeddeddolt"   # DB 実体なし＝除外対象（live なら評価される）
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2: UNKNOWN"* ]]
  [[ "$output" != *"COND2: OK"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "E2 除外の安全弁2: 候補 0 かつ除外 0（真の未導入）は COND2: OK のまま" {
  w="$(mk_work sep-none)"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "E2 symlink: --repo に symlink を渡しても台帳を見つける（候補 0＝CLEAN に化けない）" {
  w="$(mk_work sep-link)"
  put_ledger "$w" . flat "git+file://$BATS_TEST_TMPDIR/sep-link.git"     # ← 違反
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-link-beads.git"
  ln -sfn "$w" "$BATS_TEST_TMPDIR/sep-link-alias"
  run "$CHECKER" --repo "$BATS_TEST_TMPDIR/sep-link-alias"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
}

@test "E3 wire ゲート: --assert-not-code-repo はコード repo URL を rc=1 で拒否し台帳 URL を rc=0 で通す" {
  w="$(mk_work sep-assert)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-assert-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-assert-beads.git"

  # コード repo 自身（正規化前の別表記でも同一視される）
  run "$CHECKER" --repo "$w" --assert-not-code-repo "git+file://$BATS_TEST_TMPDIR/sep-assert.git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: VIOLATION"* ]]

  # 台帳専用 repo（接頭辞衝突する名前でも完全一致で弁別される）
  run "$CHECKER" --repo "$w" --assert-not-code-repo "git+file://$BATS_TEST_TMPDIR/sep-assert-beads.git"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: OK"* ]]
}

@test "E3 wire ゲート: 値欠落・空 URL は rc=2（判定不能を OK に畳まない）" {
  w="$(mk_work sep-assert2)"
  run "$CHECKER" --repo "$w" --assert-not-code-repo ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: UNKNOWN"* ]]
  run "$CHECKER" --repo "$w" --assert-not-code-repo
  [ "$status" -eq 2 ]
}

@test "E3 SKILL.md: bd dolt remote add より前に --assert-not-code-repo を呼ぶ（wire-then-check でない）" {
  sec="$(awk '/^### backup.git-push/,/^### PRIME.md/' "$SKILL")"
  [[ "$sec" == *"--assert-not-code-repo"* ]]
  # 出現順: assert → add（同一 step 内）。
  a_line="$(grep -n -- '--assert-not-code-repo' "$SKILL" | head -1 | cut -d: -f1)"
  w_line="$(grep -n 'bd dolt remote add origin "git+' "$SKILL" | head -1 | cut -d: -f1)"
  [ -n "$a_line" ]
  [ -n "$w_line" ]
  [ "$a_line" -lt "$w_line" ]
  # rc を捕捉して分岐し、非 0 では add しない形になっている。
  [[ "$sec" == *"assert_rc=\$?"* ]]
  [[ "$sec" == *'if [ "$assert_rc" -ne 0 ]; then'* ]]
  # wire 後に rc=1 だった場合の巻き戻し手順が明記されている。
  run grep -q 'bd dolt remote remove origin' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "E4 identity: remote 0 本なら条件1 は N/A OK・条件2 は repo 自パスで判定継続（違反は RED）" {
  w="$BATS_TEST_TMPDIR/sep-noremote"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  put_ledger "$w" . flat "file://$w"      # ← 自リポを指す＝違反
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-noremote-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND1: OK"* ]]
  [[ "$output" == *"COND1-NOTE: NO-GIT-REMOTE"* ]]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
}

@test "E4 identity: remote 0 本で台帳が別先なら CLEAN rc=0（dead-end にしない）" {
  w="$BATS_TEST_TMPDIR/sep-noremote2"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-noremote2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-noremote2-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND1: OK"* ]]
  [[ "$output" == *"COND1-NOTE: NO-GIT-REMOTE"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "E4 identity: remote あり origin 無しは条件1 UNKNOWN・条件2 は全 remote と比較（実違反は rc=1）" {
  # origin 以外の名前（upstream）でコード repo を持ち、sync.remote が同じ URL を指す実違反。
  # 「origin 不在→N/A→CLEAN」の素朴形はこれを清浄と誤報する。
  w="$BATS_TEST_TMPDIR/sep-upstream"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-upstream-code.git"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  git -C "$w" remote add upstream "$BATS_TEST_TMPDIR/sep-upstream-code.git"
  put_ledger "$w" . flat "git+file://$BATS_TEST_TMPDIR/sep-upstream-code.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-upstream-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND1: UNKNOWN"* ]]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "E4 identity: 非 git ディレクトリは UNKNOWN（origin 未設定と git 実行不能を弁別）" {
  d="$BATS_TEST_TMPDIR/not-a-repo"
  mkdir -p "$d"
  run "$CHECKER" --repo "$d"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND1: UNKNOWN"* ]]
  [[ "$output" == *"COND2: UNKNOWN"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "E5 引数: --repo の値欠落は rc=2 で即 fail-loud（busy loop しない）" {
  run timeout 10 "$CHECKER" --repo
  [ "$status" -eq 2 ]      # 124 なら busy loop（timeout）＝退行
  [[ "$output" == *"RESULT: UNKNOWN"* ]]
}

@test "E5 引数: 未知 arg も rc=2（既存契約と整合）" {
  run timeout 10 "$CHECKER" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"RESULT: UNKNOWN"* ]]
}

@test "E6 ラベル: --repo 末尾スラッシュでも rel ラベルが潰れない（判定は不変）" {
  w="$(mk_work sep-slash)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-slash-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-slash-beads.git"
  put_ledger "$w" sub flat "git+file://$BATS_TEST_TMPDIR/sep-slash-sub-beads.git"
  put_dolt_remote "$w/sub" "git+file://$BATS_TEST_TMPDIR/sep-slash-sub-beads.git"
  run "$CHECKER" --repo "$w/"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2 .beads 2a: OK"* ]]
  [[ "$output" == *"COND2 sub/.beads 2a: OK"* ]]
}

# ---------------------------------------------------------------------------
# 4c. errata R2 — 除外述語 / code-identity / symlink / wire 実走 / 引数・出力の穴
# ---------------------------------------------------------------------------

@test "B1 除外述語: git-ignored でも live（DB 実体あり）な台帳がコード面を指せば RED" {
  # ignored を理由に live 台帳を落とすと、そこが実 push 先としてコード面を指していても CLEEN になる。
  # 「ignored かつ DB 実体なし」だけを ephemeral として除外する。
  w="$(mk_work sep-ignlive)"
  printf '/vendored/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-ignlive-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-ignlive-beads.git"
  # ignored だが live（put_ledger が embeddeddolt を作る）で、実 push 先がコード repo
  put_ledger "$w" vendored/sub flat "git+file://$BATS_TEST_TMPDIR/sep-ignlive.git"
  put_dolt_remote "$w/vendored/sub" "git+file://$BATS_TEST_TMPDIR/sep-ignlive.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 vendored/sub/.beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
  [[ "$output" == *"git-ignored だが live"* ]]
}

@test "B1 除外述語: .worktrees の stale checkout は live でないので依然 skip（F1 の偽 RED を再発させない）" {
  w="$(mk_work sep-wtlive)"
  printf '/.worktrees/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-wtlive-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-wtlive-beads.git"
  put_ledger "$w" .worktrees/spawn/other flat "git+file://$BATS_TEST_TMPDIR/sep-wtlive.git"
  rm -rf "$w/.worktrees/spawn/other/.beads/embeddeddolt"    # worktree checkout は DB を持たない（実測）
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

@test "B2 code-identity: origin あり + upstream がコード面 + 台帳がそこを指す → rc=1（remote 名付き）" {
  w="$(mk_work sep-b2)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-b2-up.git"
  git -C "$w" remote add upstream "$BATS_TEST_TMPDIR/sep-b2-up.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-b2-up.git"     # ← 非 origin のコード面を指す
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-b2-up.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION remote=upstream"* ]]
  [[ "$output" == *"COND2 .beads 2c: VIOLATION remote=upstream"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "B2 code-identity: 同 URL の --assert-not-code-repo も rc=1（wire 前に止まる）" {
  w="$(mk_work sep-b2a)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-b2a-up.git"
  git -C "$w" remote add upstream "$BATS_TEST_TMPDIR/sep-b2a-up.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-b2a-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-b2a-beads.git"
  run "$CHECKER" --repo "$w" --assert-not-code-repo "git+file://$BATS_TEST_TMPDIR/sep-b2a-up.git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: VIOLATION remote=upstream"* ]]
}

@test "B2 条件1: 非 origin remote 上の refs/dolt/* も per-remote で検出する（remote 名を出す）" {
  w="$(mk_work sep-b2c)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-b2c-mirror.git"
  git -C "$w" remote add mirror "$BATS_TEST_TMPDIR/sep-b2c-mirror.git"
  git -C "$w" push -q mirror HEAD:refs/dolt/data
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-b2c-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-b2c-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND1 origin: OK"* ]]
  [[ "$output" == *"COND1 mirror: VIOLATION"* ]]
  [[ "$output" == *"COND1: VIOLATION"* ]]
}

@test "B3 symlink 台帳: 違反する symlink .beads は RED（候補 0＝未導入に化けない）" {
  w="$(mk_work sep-b3)"
  mkdir -p "$BATS_TEST_TMPDIR/sep-b3-store/embeddeddolt"
  printf 'sync.remote: "git+file://%s/sep-b3.git"\n' "$BATS_TEST_TMPDIR" \
    > "$BATS_TEST_TMPDIR/sep-b3-store/config.yaml"
  ln -sfn "$BATS_TEST_TMPDIR/sep-b3-store" "$w/.beads"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-b3-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "B3 symlink 台帳: 清浄な symlink .beads は CLEAN（過剰赤化しない・2c も判定できる）" {
  w="$(mk_work sep-b3b)"
  mkdir -p "$BATS_TEST_TMPDIR/sep-b3b-store/embeddeddolt"
  printf 'sync.remote: "git+file://%s/sep-b3b-beads.git"\n' "$BATS_TEST_TMPDIR" \
    > "$BATS_TEST_TMPDIR/sep-b3b-store/config.yaml"
  ln -sfn "$BATS_TEST_TMPDIR/sep-b3b-store" "$w/.beads"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-b3b-beads.git"
  # symlink 台帳では bd が実体パスを返す構成もある。そのときも 2c を判定できること。
  printf '%s\n  database: %s\n' "$BATS_TEST_TMPDIR/sep-b3b-store" \
    "$BATS_TEST_TMPDIR/sep-b3b-store/embeddeddolt" > "$w/.bd-stub-where"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2 .beads 2c: OK"* ]]
  [[ "$output" == *"RESULT: CLEAN"* ]]
}

# --- B4: wire ブロックの実走 tooth（doc-pin ではなく挙動で pin する） -------------
#     SKILL.md #4 収束 step の bash ブロックを別プロセスで実行し、stub bd の呼出記録で
#     「assert が VIOLATION のとき dolt remote add が起きない / OK なら起きる / URL 未提供なら起きない」
#     を assert する。字面 pin だけでは「add を assert の前へ移す」変異体を検出できない。
run_wire_block() {   # $1 = assert が返す rc（0=許可 / 1=拒否）, $2 = LEDGER_REMOTE_URL（空なら未提供）
  local assert_rc="$1" ledger_url="${2:-}"
  local d="$BATS_TEST_TMPDIR/wire"
  rm -rf "$d"; mkdir -p "$d/plugin/skills/setup" "$d/bin" "$d/cwd"

  awk '/^### backup.git-push/,/^### PRIME.md/' "$SKILL" > "$d/section.md"
  awk -v out="$d" '/^```bash$/{inb=1;n++;next} /^```$/{inb=0;next} inb{print > (out "/block" n ".sh")}' \
    "$d/section.md"

  # stub checker: assert mode のときだけ指定 rc を返す（既定 mode は 0）
  cat > "$d/plugin/skills/setup/check-ledger-separation.sh" <<STUBEOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--assert-not-code-repo" ] && exit $assert_rc; done
exit 0
STUBEOF
  chmod +x "$d/plugin/skills/setup/check-ledger-separation.sh"

  cat > "$d/bin/bd" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_CALL_LOG"
exit 0
STUBEOF
  chmod +x "$d/bin/bd"

  export CLAUDE_PLUGIN_ROOT="$d/plugin"
  export BD_CALL_LOG="$d/bd-calls.log"; : > "$BD_CALL_LOG"
  if [ -n "$ledger_url" ]; then export LEDGER_REMOTE_URL="$ledger_url"; else unset LEDGER_REMOTE_URL; fi
  local b
  for b in "$d"/block*.sh; do
    [ -s "$b" ] || continue
    ( cd "$d/cwd" && PATH="$d/bin:$PATH" bash "$b" ) >>"$d/out" 2>&1 || true
  done
  WIRE_DIR="$d"
}

@test "B4 wire 実走: assert が VIOLATION なら bd dolt remote add が起きない" {
  run_wire_block 1 "https://github.com/shuu5/scribe.git"
  run grep -q 'dolt remote add' "$WIRE_DIR/bd-calls.log"
  [ "$status" -ne 0 ]
}

@test "B4 wire 実走: assert が OK なら bd dolt remote add が起きる（ゲートが通せることも pin）" {
  run_wire_block 0 "https://github.com/shuu5/scribe-beads.git"
  run grep -q 'dolt remote add' "$WIRE_DIR/bd-calls.log"
  [ "$status" -eq 0 ]
}

@test "B4 wire 実走: LEDGER_REMOTE_URL 未提供なら add も assert も起きない（fail-loud 停止）" {
  run_wire_block 0 ""
  run grep -q 'dolt remote add' "$WIRE_DIR/bd-calls.log"
  [ "$status" -ne 0 ]
  run grep -q '台帳専用 private repo の URL が未提供' "$WIRE_DIR/out"
  [ "$status" -eq 0 ]
}

@test "B4 順序: #4 収束 step の section 内で assert が add より前にある（section 相対で判定）" {
  # ファイル全体の行番号で比べると、別 section の出現順に引きずられて順序判定が空洞化する。
  sec="$BATS_TEST_TMPDIR/sec4.md"
  awk '/^### backup.git-push/,/^### PRIME.md/' "$SKILL" > "$sec"
  a="$(grep -n -- '--assert-not-code-repo' "$sec" | head -1 | cut -d: -f1)"
  w="$(grep -n 'bd dolt remote add origin' "$sec" | head -1 | cut -d: -f1)"
  [ -n "$a" ]
  [ -n "$w" ]
  [ "$a" -lt "$w" ]
}

@test "m1 --repo 正規化: repo 内サブディレクトリを渡しても toplevel へ正規化して判定する" {
  w="$(mk_work sep-m1)"
  put_ledger "$w" . flat "git+file://$BATS_TEST_TMPDIR/sep-m1.git"     # ← 違反
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-m1-beads.git"
  mkdir -p "$w/deep/dir"
  run "$CHECKER" --repo "$w/deep/dir"
  [ "$status" -eq 1 ]
  [[ "$output" == *"REPO-NOTE: NORMALIZED-TO-TOPLEVEL"* ]]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
}

@test "m2 走査不完全: find がエラーを出したら SCAN-INCOMPLETE + UNKNOWN（部分結果を CLEAN と言わない）" {
  w="$(mk_work sep-m2)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-m2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-m2-beads.git"
  mkdir -p "$w/unreadable/inner"
  chmod 000 "$w/unreadable"
  run "$CHECKER" --repo "$w"
  chmod 755 "$w/unreadable"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2-NOTE: SCAN-INCOMPLETE"* ]]
  [[ "$output" == *"COND2: UNKNOWN"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "m3 path-only 注記: remote 0 本のときは COND2 と assert の両方で CODE-IDENTITY-PATH-ONLY を出す" {
  w="$BATS_TEST_TMPDIR/sep-m3"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  put_ledger "$w" . both "git+https://github.com/shuu5/sep-m3-beads.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/sep-m3-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2-NOTE: CODE-IDENTITY-PATH-ONLY"* ]]
  run "$CHECKER" --repo "$w" --assert-not-code-repo "git+https://github.com/shuu5/sep-m3-beads.git"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2-NOTE: CODE-IDENTITY-PATH-ONLY"* ]]
}

@test "m4 正規化: 大小文字を区別しない既知ホストでは path の大小文字差を同一視する" {
  w="$BATS_TEST_TMPDIR/sep-m4"
  put_ledger "$w" . flat "git+https://github.com/Shuu5/Scribe.git"     # ← 大小文字だけ違うコード repo
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe.git"
  export GIT_STUB_LSREMOTE_RC=0
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
}

@test "m4 正規化: 大小文字を区別するホスト（file://）では path の大小文字差を同一視しない" {
  w="$(mk_work sep-m4b)"
  put_ledger "$w" . flat "git+file://$BATS_TEST_TMPDIR/SEP-M4B.git"    # 別 path（大小文字差）
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-m4b-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND2 .beads 2a: OK"* ]]
}

@test "m5 2c parse: remote 行が在るのに URL 形の値を取れなければ 2c: UNKNOWN（列の取り違えを OK にしない）" {
  w="$(mk_work sep-m5)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-m5-beads.git"
  # 2 列目が URL でない出力（想定外の出力形）
  printf 'not-a-url\n' > "$w/.bd-stub-remote"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
  [[ "$output" != *"COND2 .beads 2c: OK"* ]]
}

@test "m6 timeout: ls-remote が固まっても rc=124 を UNKNOWN として返す（判定が返らない状態を作らない）" {
  w="$BATS_TEST_TMPDIR/sep-m6"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-m6-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-m6-beads.git"
  HANG="$BATS_TEST_TMPDIR/hangbin"; mkdir -p "$HANG"
  cat > "$HANG/git" <<'STUB'
#!/usr/bin/env bash
args=(); while [ $# -gt 0 ]; do case "$1" in -C) shift 2 ;; *) args+=("$1"); shift ;; esac; done
case "${args[0]:-}" in
  remote)    case "${args[1]:-}" in get-url) echo "https://example.invalid/code.git" ;; "") echo origin ;; esac ;;
  rev-parse) case "${args[1]:-}" in --show-toplevel) printf '%s\n' "$GIT_STUB_TOP" ;; esac; exit 0 ;;
  ls-remote) sleep 30 ;;
  check-ignore) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$HANG/git"
  export GIT_STUB_TOP="$w"
  # timeout を 1s に縮めて実測（既定 20s では bats が待ちすぎる）
  PATH="$HANG:$PATH" LEDGER_SEP_LSREMOTE_TIMEOUT=1 run timeout 20 "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]                       # 124 でも 0 でもなく、UNKNOWN の 2
  [[ "$output" == *"COND1 origin: UNKNOWN"* ]]
  [[ "$output" == *"COND1: UNKNOWN"* ]]
}

@test "m7 SKILL.md: 既存レジストリがコード面を指す場合の unwire 手順が rc=1 節に在る" {
  run grep -q 'bd dolt remote remove origin' "$SKILL"
  [ "$status" -eq 0 ]
  # rc=1 の節（違反時）に unwire と「push しない」が併記されている
  sec="$(awk '/rc が 0 以外のときに止めるのは/,/^## Step 1/' "$SKILL")"
  [[ "$sec" == *"bd dolt remote remove origin"* ]]
  [[ "$sec" == *"push"* ]]
  [[ "$sec" == *"既存"* ]]
}

@test "m8 --help: ヘッダ全体を出す（固定行数で切らない）" {
  # ヘッダ（先頭の連続コメント行）の実行数と --help の出力行数が一致する。
  n_hdr="$(awk 'NR>1 && /^#/ { n++ } NR>1 && !/^#/ { exit } END { print n+0 }' "$CHECKER")"
  run "$CHECKER" --help
  [ "$status" -eq 0 ]
  n_out=0; while IFS= read -r _; do n_out=$((n_out+1)); done <<< "$output"
  [ "$n_out" -eq "$n_hdr" ]
  # usage 節（ヘッダ末尾付近）まで到達している＝切れていない
  [[ "$output" == *"--assert-not-code-repo"* ]]
  [[ "$output" == *"LEDGER_SEP_LSREMOTE_TIMEOUT"* ]]
}

# ---------------------------------------------------------------------------
# 4d. errata R3 — prune / URL 正規化 / pushurl / URL 解決不能 / bd timeout の穴
# ---------------------------------------------------------------------------

@test "C1 prune 撤去: ディレクトリ名で事前 prune せず、.worktrees 配下の live 台帳もコード面を指せば RED" {
  # 名前 prune は live 安全弁より前段で効くため、prune 対象配下の live 台帳が存在ごと不可視になる。
  # 除外は「git-ignored かつ live でない」の単一述語に一本化する。
  w="$(mk_work sep-c1)"
  printf '/.worktrees/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c1-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c1-beads.git"
  put_ledger "$w" .worktrees/spawn/x flat "git+file://$BATS_TEST_TMPDIR/sep-c1.git"   # live + 違反
  put_dolt_remote "$w/.worktrees/spawn/x" "git+file://$BATS_TEST_TMPDIR/sep-c1.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .worktrees/spawn/x/.beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "C1 prune 撤去: node_modules 配下の live 台帳もコード面を指せば RED（名前で免除しない）" {
  w="$(mk_work sep-c1n)"
  printf '/node_modules/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c1n-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c1n-beads.git"
  put_ledger "$w" node_modules/pkg flat "git+file://$BATS_TEST_TMPDIR/sep-c1n.git"
  put_dolt_remote "$w/node_modules/pkg" "git+file://$BATS_TEST_TMPDIR/sep-c1n.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 node_modules/pkg/.beads 2a: VIOLATION"* ]]
}

@test "C2 正規化: http / git / 連続スラッシュ / 既定ポート が同一コード面として assert rc=1" {
  w="$BATS_TEST_TMPDIR/sep-c2"
  put_ledger "$w" . both "git+https://github.com/shuu5/scribe-beads.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe.git"
  export GIT_STUB_LSREMOTE_RC=0
  for v in "http://github.com/shuu5/scribe.git" \
           "git://github.com/shuu5/scribe.git" \
           "https://github.com/shuu5//scribe.git" \
           "https://github.com:443/shuu5/scribe.git" \
           "ssh://git@github.com:22/shuu5/scribe.git"; do
    run "$CHECKER" --repo "$w" --assert-not-code-repo "$v"
    [ "$status" -eq 1 ]
    [[ "$output" == *"ASSERT-NOT-CODE-REPO: VIOLATION"* ]]
  done
  # 対照: 別 repo は通す（何でも赤にしているのではない）
  run "$CHECKER" --repo "$w" --assert-not-code-repo "https://github.com/shuu5/scribe-beads.git"
  [ "$status" -eq 0 ]
}

@test "C2 正規化: file 形の . / .. / 連続スラッシュ を解決して同一視する（assert rc=1）" {
  w="$(mk_work sep-c2f)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c2f-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c2f-beads.git"
  for v in "file://$BATS_TEST_TMPDIR/./sep-c2f.git" \
           "file://$BATS_TEST_TMPDIR/sub/../sep-c2f.git" \
           "file://$BATS_TEST_TMPDIR//sep-c2f.git" \
           "$BATS_TEST_TMPDIR/./sep-c2f.git"; do
    run "$CHECKER" --repo "$w" --assert-not-code-repo "$v"
    [ "$status" -eq 1 ]
  done
}

@test "C2 正規化: COND2 側でも別表記のコード面を VIOLATION にする" {
  w="$BATS_TEST_TMPDIR/sep-c2c"
  put_ledger "$w" . flat "git+http://github.com/shuu5//scribe.git"   # http + 連続スラッシュ
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe.git"
  export GIT_STUB_LSREMOTE_RC=0
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
}

@test "C3 pushurl: pushurl がコード面で台帳がそこを指せば rc=1（remote 名指定では取り逃がす経路）" {
  w="$(mk_work sep-c3)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-c3-push.git"
  git -C "$w" config remote.origin.pushurl "$BATS_TEST_TMPDIR/sep-c3-push.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c3-push.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c3-push.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION remote=origin#push"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "C3 pushurl: 同 URL の assert も rc=1（wire 前に止まる）" {
  w="$(mk_work sep-c3a)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-c3a-push.git"
  git -C "$w" config remote.origin.pushurl "$BATS_TEST_TMPDIR/sep-c3a-push.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c3a-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c3a-beads.git"
  run "$CHECKER" --repo "$w" --assert-not-code-repo "git+file://$BATS_TEST_TMPDIR/sep-c3a-push.git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: VIOLATION remote=origin#push"* ]]
}

@test "C3 pushurl: pushurl 上の refs/dolt/* も条件1 で検出する（URL 直指定の走査）" {
  w="$(mk_work sep-c3b)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-c3b-push.git"
  git -C "$w" config remote.origin.pushurl "$BATS_TEST_TMPDIR/sep-c3b-push.git"
  git -C "$w" push -q "$BATS_TEST_TMPDIR/sep-c3b-push.git" HEAD:refs/dolt/data
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c3b-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c3b-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND1 origin: OK"* ]]
  [[ "$output" == *"COND1 origin#push: VIOLATION"* ]]
}

@test "C4 silent drop: URL 解決不能な remote は drop せず UNKNOWN として記録する" {
  # ★単一 remote fixture にすると「CODE_IDS が空」の旧 fail-closed 分岐で rc=2 になり空虚な tooth になる。
  #   origin は解決可・第 2 remote だけ解決不可、という構成でなければ silent drop を捕まえられない。
  w="$(mk_work sep-c4)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-c4-other.git"
  git -C "$w" remote add other "$BATS_TEST_TMPDIR/sep-c4-other.git"
  git -C "$w" config remote.other.url ""
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c4-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c4-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND1 other: UNKNOWN"* ]]
  [[ "$output" == *"COND1: UNKNOWN"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "C4 silent drop: 解決不能 remote があるときは assert も UNKNOWN（比較集合に穴がある）" {
  w="$(mk_work sep-c4a)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-c4a-other.git"
  git -C "$w" remote add other "$BATS_TEST_TMPDIR/sep-c4a-other.git"
  git -C "$w" config remote.other.url ""
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c4a-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-c4a-beads.git"
  run "$CHECKER" --repo "$w" --assert-not-code-repo "git+file://$BATS_TEST_TMPDIR/sep-c4a-beads.git"
  [ "$status" -eq 2 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: UNKNOWN"* ]]
}

@test "C5 bd timeout: bd が hang しても有界時間で 2c: UNKNOWN を返す（ゲートが返らない状態を作らない）" {
  w="$(mk_work sep-c5)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-c5-beads.git"
  HANG="$BATS_TEST_TMPDIR/hangbd"; mkdir -p "$HANG"
  printf '#!/usr/bin/env bash\nsleep 30\n' > "$HANG/bd"
  chmod +x "$HANG/bd"
  PATH="$HANG:$PATH" LEDGER_SEP_BD_TIMEOUT=1 run timeout 20 "$CHECKER" --repo "$w"
  [ "$status" -eq 2 ]                       # 124（呼出側 timeout）ではなく checker 自身の UNKNOWN
  [[ "$output" == *"COND2 .beads 2c: UNKNOWN"* ]]
  [[ "$output" == *"RESULT: UNKNOWN"* ]]
}

@test "C-extra listing 語彙: 条件1 の OK は ref listing の不在であって object の不在ではないと明示する" {
  # ref を削除しても object は remote に残り匿名 fetch で取れる場合がある（実測）。`COND1: OK` を
  # 「露出が消えた」証明として読ませないため、走査した run では必ず注記を出す。
  w="$(mk_work sep-listing)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-listing-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-listing-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND1: OK"* ]]
  [[ "$output" == *"COND1-NOTE: REF-LISTING-ONLY"* ]]
  [[ "$output" == *"ref listing に無い"* ]]
}

@test "C-extra listing 語彙: remote 0 本（走査していない）run では REF-LISTING-ONLY を出さない（安売りしない）" {
  w="$BATS_TEST_TMPDIR/sep-listing2"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  put_ledger "$w" . both "git+https://github.com/shuu5/sep-listing2-beads.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/sep-listing2-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" != *"COND1-NOTE: REF-LISTING-ONLY"* ]]
  [[ "$output" == *"COND1-NOTE: NO-GIT-REMOTE"* ]]
}

@test "q1 自リポ: remote が在る repo でも台帳が repo 自パスを指せば RED / assert も rc=1" {
  w="$(mk_work sep-q1)"
  put_ledger "$w" . flat "file://$w"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-q1-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION remote=<repo 自身のパス>"* ]]
  run "$CHECKER" --repo "$w" --assert-not-code-repo "file://$w"
  [ "$status" -eq 1 ]
}

@test "q2 config 不読: config.yaml が在るのに読めなければ 2a/2b を ABSENT にせず UNKNOWN" {
  w="$(mk_work sep-q2)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-q2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-q2-beads.git"
  chmod 000 "$w/.beads/config.yaml"
  run "$CHECKER" --repo "$w"
  chmod 644 "$w/.beads/config.yaml"
  [ "$status" -eq 2 ]
  [[ "$output" == *"COND2-NOTE: CONFIG-UNREADABLE"* ]]
  [[ "$output" == *"COND2 .beads 2a: UNKNOWN"* ]]
  [[ "$output" != *"COND2 .beads 2a: ABSENT"* ]]
  [[ "$output" != *"RESULT: CLEAN"* ]]
}

@test "q3 補助検出: COND1-EXTRA が origin 限定でなく走査対象の面ごとに出る" {
  w="$(mk_work sep-q3)"
  git init -q --bare "$BATS_TEST_TMPDIR/sep-q3-push.git"
  git -C "$w" config remote.origin.pushurl "$BATS_TEST_TMPDIR/sep-q3-push.git"
  git -C "$w" push -q "$BATS_TEST_TMPDIR/sep-q3-push.git" HEAD:refs/heads/__dolt_remote_info__
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-q3-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-q3-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"COND1-EXTRA: DOLT-REF-OUTSIDE-GLOB refs/heads/__dolt_remote_info__"* ]]
}

@test "q5 正規化: 既定ポート（https:443 / ssh:22）は畳むが非既定ポートは畳まない" {
  w="$BATS_TEST_TMPDIR/sep-q5"
  put_ledger "$w" . both "git+https://github.com/shuu5/scribe-beads.git"
  put_dolt_remote "$w" "git+https://github.com/shuu5/scribe-beads.git"
  export PATH="$GITSTUB:$PATH"
  export GIT_STUB_ORIGIN="https://github.com/shuu5/scribe.git"
  export GIT_STUB_LSREMOTE_RC=0
  run "$CHECKER" --repo "$w" --assert-not-code-repo "https://github.com:443/shuu5/scribe.git"
  [ "$status" -eq 1 ]
  # 非既定ポートは別ホストとして扱う（畳みすぎない）
  run "$CHECKER" --repo "$w" --assert-not-code-repo "https://github.com:8443/shuu5/scribe.git"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 4e. errata R4 — URL-alias class の残余（percent-encode / file://localhost / 相対 path）と境界宣言
# ---------------------------------------------------------------------------

@test "FIX-E(a) percent-encode: unreserved の %XX 形は同一コード面として assert rc=1（実到達する真の alias）" {
  # %73 → 's'。git はこの URL で実 repo に到達できる（gate 実測 REACHABLE）ので、
  # 文字列比較で弾けないと wire ゲートを素通りする。
  d="$BATS_TEST_TMPDIR/pe"; mkdir -p "$d"
  git init -q --bare "$d/scribe.git"
  w="$BATS_TEST_TMPDIR/pe-w"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  git -C "$w" remote add origin "$d/scribe.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/pe-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/pe-beads.git"

  # 前提: この percent 形が実際に同じ repo へ到達する（alias である）ことを先に確かめる
  run git ls-remote "file://$d/%73cribe.git"
  [ "$status" -eq 0 ]

  run "$CHECKER" --repo "$w" --assert-not-code-repo "file://$d/%73cribe.git"
  [ "$status" -eq 1 ]
  [[ "$output" == *"ASSERT-NOT-CODE-REPO: VIOLATION"* ]]
}

@test "FIX-E(a) percent-encode: 予約文字（%2F）は復号しない（path 構造を変えて別 repo を同一視しない）" {
  w="$(mk_work sep-pct2)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-pct2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-pct2-beads.git"
  # `%2F` を `/` へ復号してしまうと別 path が origin と一致してしまう形
  run "$CHECKER" --repo "$w" --assert-not-code-repo "file://$BATS_TEST_TMPDIR/sep-pct2.git%2Fx"
  [ "$status" -eq 0 ]
}

@test "FIX-E(b) file://localhost: localhost 形と空 host 形を同一視して COND2 を RED にする" {
  w="$(mk_work sep-lh)"
  put_ledger "$w" . flat "file://localhost$BATS_TEST_TMPDIR/sep-lh.git"   # ← コード repo（localhost 形）
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-lh-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
  [[ "$output" == *"RESULT: VIOLATION"* ]]
}

@test "FIX-E(b) file://localhost: assert も rc=1（wire 前に止まる）" {
  w="$(mk_work sep-lh2)"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-lh2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-lh2-beads.git"
  run "$CHECKER" --repo "$w" --assert-not-code-repo "file://localhost$BATS_TEST_TMPDIR/sep-lh2.git"
  [ "$status" -eq 1 ]
  # 対照: 別 repo の localhost 形は通す（何でも赤にしているのではない）
  run "$CHECKER" --repo "$w" --assert-not-code-repo "file://localhost$BATS_TEST_TMPDIR/sep-lh2-beads.git"
  [ "$status" -eq 0 ]
}

@test "s1 相対 remote: origin=../code.git を repo 基準で解決し COND2 を RED にする" {
  git init -q --bare "$BATS_TEST_TMPDIR/rel-code.git"
  w="$BATS_TEST_TMPDIR/relbase/w"
  mkdir -p "$BATS_TEST_TMPDIR/relbase"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  git -C "$w" remote add origin "../../rel-code.git"      # ← 相対形
  put_ledger "$w" . flat "file://$BATS_TEST_TMPDIR/rel-code.git"   # 同一 repo を絶対形で指す＝違反
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/rel-beads.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 1 ]
  [[ "$output" == *"COND2 .beads 2a: VIOLATION"* ]]
}

@test "s1 相対 remote: 同 URL の assert も rc=1（wire 前に止まる）" {
  git init -q --bare "$BATS_TEST_TMPDIR/rel2-code.git"
  w="$BATS_TEST_TMPDIR/relbase2/w"
  mkdir -p "$BATS_TEST_TMPDIR/relbase2"
  git -c init.defaultBranch=main init -q "$w"
  git -C "$w" config user.email t@e; git -C "$w" config user.name t
  git -C "$w" commit -q --allow-empty -m init
  git -C "$w" remote add origin "../../rel2-code.git"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/rel2-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/rel2-beads.git"
  run "$CHECKER" --repo "$w" --assert-not-code-repo "file://$BATS_TEST_TMPDIR/rel2-code.git"
  [ "$status" -eq 1 ]
}

@test "R4 境界宣言: checker header と SKILL.md の両方に「rc=0 はコード repo でない証明ではない」が在る" {
  # 同値類を列挙して塞ぐ設計である以上、未列挙の変種は残る。その境界を doc 化しておかないと
  # rc=0 が「安全の証明」として読まれる。
  hdr="$(awk 'NR==1 && /^#!/ { next } /^#/ { print; next } { exit }' "$CHECKER")"
  [[ "$hdr" == *"証明ではない"* ]]
  [[ "$hdr" == *"exposure gate v2"* ]]
  [[ "$hdr" == *"IDN homograph"* ]]
  run grep -q '証明ではない' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -q 'exposure gate v2' "$SKILL"
  [ "$status" -eq 0 ]
  # 吸収する同値類が doc に列挙されている（何を保証するかも書く）
  [[ "$hdr" == *"percent-encode"* ]]
  [[ "$hdr" == *"localhost"* ]]
}

# --- s3: Step 0 の配線を実走で pin する（文字列存在だけでは rc 破棄形への退化を素通しする） ------
run_step0_block() {   # $1 = stub checker が返す rc
  local chk_rc="$1"
  local d="$BATS_TEST_TMPDIR/step0"
  rm -rf "$d"; mkdir -p "$d/plugin/skills/setup" "$d/bin" "$d/cwd"

  awk '/^## Step 0:/,/^## Step 1/' "$SKILL" > "$d/section.md"
  awk -v out="$d" '/^```bash$/{inb=1;n++;next} /^```$/{inb=0;next} inb{print > (out "/block" n ".sh")}' \
    "$d/section.md"
  [ -s "$d/block1.sh" ]

  printf '#!/usr/bin/env bash\nexit %s\n' "$chk_rc" > "$d/plugin/skills/setup/check-ledger-separation.sh"
  chmod +x "$d/plugin/skills/setup/check-ledger-separation.sh"
  # Step 0 は bd / git / jq 等を叩くので、失敗しても続行できるよう最小 stub を置く
  for c in bd; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/$c"; chmod +x "$d/bin/$c"; done

  export CLAUDE_PLUGIN_ROOT="$d/plugin"
  ( cd "$d/cwd" && git -c init.defaultBranch=main init -q . && PATH="$d/bin:$PATH" bash "$d/block1.sh" ) \
    > "$d/out" 2>&1 || true
  STEP0_DIR="$d"
}

@test "s3 Step 0 実走: checker の rc が LEDGER-SEP:rc= に反映される（rc=1）" {
  run_step0_block 1
  run grep -q 'LEDGER-SEP:rc=1' "$STEP0_DIR/out"
  [ "$status" -eq 0 ]
}

@test "s3 Step 0 実走: checker の rc が LEDGER-SEP:rc= に反映される（rc=2 を 0 に畳まない）" {
  run_step0_block 2
  run grep -q 'LEDGER-SEP:rc=2' "$STEP0_DIR/out"
  [ "$status" -eq 0 ]
  run grep -q 'LEDGER-SEP:rc=0' "$STEP0_DIR/out"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 5. acceptance 1a — 本リポ worktree の .beads/config.yaml を回帰 pin（read のみ）
# ---------------------------------------------------------------------------

@test "本リポ config: nested sync:/remote: と col0 平坦 sync.remote: の 2 形態が同時に実在する" {
  cfg="$REPO_ROOT/.beads/config.yaml"
  [ -f "$cfg" ]
  # col0 平坦形（beads-bdw guard の has_remote はこの形しか読まない＝orch-0d37）
  run grep -qE '^sync\.remote:[[:space:]]*"' "$cfg"
  [ "$status" -eq 0 ]
  # nested 形（bd dolt remote add が書く正準形＝実効値）
  run grep -qE '^sync:[[:space:]]*$' "$cfg"
  [ "$status" -eq 0 ]
  run grep -qE '^[[:space:]]+remote:[[:space:]]*"' "$cfg"
  [ "$status" -eq 0 ]
}

@test "本リポ config: 2 形態とも台帳専用 private URL を指し、コード repo URL を一切持たない" {
  cfg="$REPO_ROOT/.beads/config.yaml"
  urls="$(grep -oE 'git\+[a-z+]*://[^"]+' "$cfg")"
  [ -n "$urls" ]
  # 2 形態ぶん（col0 + nested）が在る。
  n=0; while IFS= read -r u; do [ -n "$u" ] && n=$((n+1)); done <<< "$urls"
  [ "$n" -ge 2 ]
  # すべて台帳専用 private repo（scribe-beads）を指す＝コード repo（.../scribe）を指す行が 1 本も無い。
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    [[ "$u" == *"/scribe-beads"* ]]
    [[ "$u" != "git+https://github.com/shuu5/scribe.git" ]]
  done <<< "$urls"
}

@test "本リポ config: 「実効 push 先は dolt レジストリであり config ではない」落とし穴コメントが残存する" {
  cfg="$REPO_ROOT/.beads/config.yaml"
  # 編集しても push 先は切り替わらない旨
  run grep -q 'このファイルを編集しても push 先は切り替わらない' "$cfg"
  [ "$status" -eq 0 ]
  # 切替には dolt 側のレジストリ操作が要る旨
  run grep -q 'bd dolt remote remove/add' "$cfg"
  [ "$status" -eq 0 ]
  # push 前に実測する規律（実測と push を別の実行単位に分ける）
  run grep -q 'bd dolt remote list' "$cfg"
  [ "$status" -eq 0 ]
  # 不変条件 2 本が config へ焼かれている
  run grep -q "git ls-remote" "$cfg"
  [ "$status" -eq 0 ]
}

@test "本リポ cc-session 台帳も台帳専用 private URL を指す（2 台帳目の回帰 pin）" {
  cfg="$REPO_ROOT/cc-session/.beads/config.yaml"
  [ -f "$cfg" ]
  urls="$(grep -oE 'git\+[a-z+]*://[^"]+' "$cfg")"
  [ -n "$urls" ]
  while IFS= read -r u; do
    [ -z "$u" ] && continue
    [[ "$u" == *"-beads"* ]]
  done <<< "$urls"
}

# ---------------------------------------------------------------------------
# 6. acceptance 2 — SKILL.md 側（違反を作る機構の除去 + checker を 3 箇所へ配線）
# ---------------------------------------------------------------------------

@test "SKILL.md: 収束ゴール #4 が「台帳専用 private repo」形で、機械条件 2 本が #11/#12 として在る" {
  run grep -qE '^4\. Dolt remote .*台帳専用 private repo' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -qE '^11\. \*\*機械条件 1' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -qE '^12\. \*\*機械条件 2' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -q "git ls-remote <このコード repo> 'refs/dolt/\*'" "$SKILL"
  [ "$status" -eq 0 ]
}

@test "SKILL.md: auto-wiring（git remote get-url origin 由来の bd dolt remote add）が撤去されている" {
  # 撤去対象は「origin の URL を組み立てて wire する」旧ブロック。同一行・近傍行の共起で判定する。
  hits="$(grep -n 'git remote get-url origin' "$SKILL" || true)"
  # 残存していても、それが bd dolt remote add の材料になっていないこと（旧ブロックの特徴行が消えている）。
  run grep -q 'url=$(git remote get-url origin)' "$SKILL"
  [ "$status" -ne 0 ]
  run grep -q 'bd dolt remote add origin "git+${url%.git}.git"; }' "$SKILL"
  [ "$status" -ne 0 ]
  # 代わりに「URL 未提供なら wire せず止める」fail-loud 分岐が在る。
  run grep -q 'LEDGER_REMOTE_URL' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -q 'コード repo へは wire しない' "$SKILL"
  [ "$status" -eq 0 ]
  # private repo の自動作成をしない旨が明記されている。
  run grep -q '自動作成' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -q 'gh repo create' "$SKILL"
  [ "$status" -eq 0 ]
}

@test "SKILL.md: checker が Step 0 / 収束 step / Step 末 の 3 箇所すべてから呼ばれる" {
  calls="$(grep -n 'check-ledger-separation.sh' "$SKILL")"
  n=0; while IFS= read -r l; do [ -n "$l" ] && n=$((n+1)); done <<< "$calls"
  # 導入の説明 1 箇所 + 実行 3 箇所。実行箇所が 3 未満なら配線漏れ。
  [ "$n" -ge 4 ]

  # Step 0（状態検出）ブロック内に呼出が在る。
  s0="$(awk '/^## Step 0:/,/^## Step 1/' "$SKILL")"
  [[ "$s0" == *"check-ledger-separation.sh"* ]]
  # Dolt remote 収束 step 内に呼出が在る。
  sr="$(awk '/^### backup.git-push/,/^### PRIME.md/' "$SKILL")"
  [[ "$sr" == *"check-ledger-separation.sh"* ]]
  # Step 末に呼出が在る。
  se="$(awk '/^## Step 末:/,/^## 禁止事項/' "$SKILL")"
  [[ "$se" == *"check-ledger-separation.sh"* ]]
}

@test "SKILL.md: Step 末は bd dolt remote list で実測してから、rc=0 のときだけ push する" {
  se="$(awk '/^## Step 末:/,/^## 禁止事項/' "$SKILL")"
  # 実測（一次観測）
  [[ "$se" == *"bd dolt remote list"* ]]
  # 実測結果で分岐してから push（実測と push が同一実行単位に無い）
  [[ "$se" == *"bd dolt push"* ]]
  # 未確認時は push しない旨が明記されている
  [[ "$se" == *"bd dolt push を実行しない"* ]]
  # rc は実行単位を跨ぐ: ゲートは file へ落とし、push 側はそれを読み直す（シェル変数に依存しない）。
  [[ "$se" == *'echo $? > "${TMPDIR:-/tmp}/ledger-sep.rc"'* ]]
  [[ "$se" == *'gate_rc="$(cat "${TMPDIR:-/tmp}/ledger-sep.rc" 2>/dev/null || echo 2)"'* ]]
  # push 側は checker を再実測し、ゲート rc と再実測 rc の両方 0 のときだけ push する。
  [[ "$se" == *'if [ "${gate_rc:-2}" -eq 0 ] && [ "${now_rc:-2}" -eq 0 ]; then'* ]]
  # 前段の**シェル変数**を跨いで読む形（実行単位を跨げず常に既定値へ畳まれる）は
  # **実行されるコードから**消えている（散文での言及は説明ゆえ対象外＝コードブロックだけを見る）。
  se_code="$(awk '/^## Step 末:/{s=1} /^## 禁止事項/{s=0} s' "$SKILL" \
            | awk '/^```bash$/{inb=1;next} /^```$/{inb=0;next} inb')"
  [ -n "$se_code" ]
  [[ "$se_code" != *'sep_rc=$?'* ]]
  [[ "$se_code" != *'"${sep_rc:-2}" -eq 0'* ]]
}

# --- doc-pin ではなく実走で pin する: Step 末の 2 ブロックを別プロセス（= 別の実行単位）で実行し、
#     分離が緑なら push へ到達し、赤なら到達しないことを実証する。
#     字面 pin だけでは「rc がシェル変数で渡らず green 経路が到達不能」という壊れ方を検出できない。
run_step_end_blocks() {   # $1 = checker が返す rc
  local chk_rc="$1"
  local d="$BATS_TEST_TMPDIR/stepend"
  rm -rf "$d"; mkdir -p "$d/plugin/skills/setup" "$d/bin" "$d/tmp" "$d/cwd"

  # SKILL.md の Step 末セクションから ```bash ブロックを順に切り出す。
  awk '/^## Step 末:/{s=1} /^## 禁止事項/{s=0} s' "$SKILL" > "$d/section.md"
  awk -v out="$d" '
    /^```bash$/ { inb=1; n++; next }
    /^```$/     { inb=0; next }
    inb         { print > (out "/block" n ".sh") }
  ' "$d/section.md"
  [ -s "$d/block1.sh" ]
  [ -s "$d/block2.sh" ]

  # stub checker（指定 rc を返す）と stub bd（呼ばれたサブコマンドを記録する）。
  printf '#!/usr/bin/env bash\nexit %s\n' "$chk_rc" > "$d/plugin/skills/setup/check-ledger-separation.sh"
  chmod +x "$d/plugin/skills/setup/check-ledger-separation.sh"
  cat > "$d/bin/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_CALL_LOG"
exit 0
STUB
  chmod +x "$d/bin/bd"

  export CLAUDE_PLUGIN_ROOT="$d/plugin"
  export BD_CALL_LOG="$d/bd-calls.log"; : > "$BD_CALL_LOG"
  export TMPDIR="$d/tmp"
  # 別プロセスで順に実行する（シェル状態は跨がない＝実運用の Bash 呼出しと同じ条件）。
  # ブロック末尾の `git status` 等は fixture では失敗しうるので rc は捨てる（判定は成果物で行う）。
  ( cd "$d/cwd" && PATH="$d/bin:$PATH" bash "$d/block1.sh" ) >"$d/out1" 2>&1 || true
  ( cd "$d/cwd" && PATH="$d/bin:$PATH" bash "$d/block2.sh" ) >"$d/out2" 2>&1 || true
  STEP_END_DIR="$d"
}

@test "SKILL.md Step 末（実走）: 分離が緑(rc=0)なら別プロセスでも bd dolt push へ到達する" {
  run_step_end_blocks 0
  run grep -qx 'dolt push' "$STEP_END_DIR/bd-calls.log"
  [ "$status" -eq 0 ]
  run grep -q '台帳分離が未確認' "$STEP_END_DIR/out2"
  [ "$status" -ne 0 ]
}

@test "SKILL.md Step 末（実走）: 分離が赤(rc=1)なら bd dolt push へ到達しない" {
  run_step_end_blocks 1
  run grep -qx 'dolt push' "$STEP_END_DIR/bd-calls.log"
  [ "$status" -ne 0 ]
  run grep -q '台帳分離が未確認' "$STEP_END_DIR/out2"
  [ "$status" -eq 0 ]
}

@test "SKILL.md: rc 2（判定不能）を OK に畳まないことが明記され、禁止事項にも入っている" {
  run grep -q '判定不能' "$SKILL"
  [ "$status" -eq 0 ]
  run grep -q '畳まない' "$SKILL"
  [ "$status" -eq 0 ]
  ban="$(awk '/^## 禁止事項/,/^## 注意/' "$SKILL")"
  [[ "$ban" == *"check-ledger-separation.sh"* ]]
  [[ "$ban" == *"コード repo への"* ]]
}

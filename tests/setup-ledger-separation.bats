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

@test "走査範囲: .worktrees 配下の stale checkout は台帳として数えない（本リポ anchor の偽 RED 回帰 pin）" {
  # 本リポ anchor は .worktrees/spawn/<cell>/ に他 cell の checkout を持つ（.gitignore 済み・ephemeral）。
  # 分離前 commit の config が残っているだけで anchor 全体が RESULT: VIOLATION になると、
  # SKILL.md の規定により /scribe:setup が構造的に停止する（恒常 false RED → gate 無視の誘発）。
  w="$(mk_work sep-wt)"
  printf '/.worktrees/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-wt-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-wt-beads.git"
  # ephemeral な worktree checkout に「分離前」の違反 config を置く。
  put_ledger "$w" .worktrees/spawn/other-cell flat "git+file://$BATS_TEST_TMPDIR/sep-wt.git"
  put_dolt_remote "$w/.worktrees/spawn/other-cell" "git+file://$BATS_TEST_TMPDIR/sep-wt.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: CLEAN"* ]]
  [[ "$output" != *".worktrees/spawn/other-cell/.beads 2a: VIOLATION"* ]]
  # 実在台帳のほうは依然として検査されている（走査ごと落としたのではない）。
  [[ "$output" == *"COND2 .beads 2c: OK"* ]]
}

@test "走査範囲: .gitignore された生成物配下の .beads も数えない（tracked な違反は依然 RED）" {
  w="$(mk_work sep-ign)"
  printf 'vendor-cache/\n' > "$w/.gitignore"
  put_ledger "$w" . both "git+file://$BATS_TEST_TMPDIR/sep-ign-beads.git"
  put_dolt_remote "$w" "git+file://$BATS_TEST_TMPDIR/sep-ign-beads.git"
  put_ledger "$w" vendor-cache/x flat "git+file://$BATS_TEST_TMPDIR/sep-ign.git"   # ignored な違反
  put_dolt_remote "$w/vendor-cache/x" "git+file://$BATS_TEST_TMPDIR/sep-ign.git"
  run "$CHECKER" --repo "$w"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: CLEAN"* ]]

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
  # path は一致・database: だけ祖先台帳。
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

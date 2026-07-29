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
  cat > "$BDSTUB/bd" <<'STUB'
#!/usr/bin/env bash
rc="${BD_STUB_RC:-0}"
if [ "$rc" -ne 0 ]; then echo "bd-stub: forced failure" >&2; exit "$rc"; fi
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
  remote)   printf '%s\n' "${GIT_STUB_ORIGIN:-}" ;;
  ls-remote) [ -n "${GIT_STUB_LSREMOTE:-}" ] && printf '%s\n' "$GIT_STUB_LSREMOTE"
             exit "${GIT_STUB_LSREMOTE_RC:-0}" ;;
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
put_ledger() {
  local work="$1" rel="$2" mode="$3" url="${4:-}"
  local d
  if [ "$rel" = "." ]; then d="$work/.beads"; else d="$work/$rel/.beads"; fi
  mkdir -p "$d"
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
  [[ "$se" == *"sep_rc"* ]]
  [[ "$se" == *'if [ "${sep_rc:-2}" -eq 0 ]; then'* ]]
  [[ "$se" == *"bd dolt push"* ]]
  # 未確認時は push しない旨が明記されている
  [[ "$se" == *"bd dolt push を実行しない"* ]]
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

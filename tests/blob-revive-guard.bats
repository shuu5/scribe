#!/usr/bin/env bats
# scripts/scribe-blob-revive-scan.sh（leg A）と scripts/scribe-base-freshness.sh（leg B / leg B-2）を
# 検証する（bd sc-efoa）。stale-base clobber の**再発検知線**そのものの teeth。
#
# 規律:
#   - 変異 fixture は `mktemp -d`（$TMPDIR 追随・`/tmp` を literal で書かない）配下の使い捨て git repo
#     にのみ作る。**本リポの worktree で branch / tag / checkout / commit / reset を実行しない**
#     （worktree は anchor と objects・refs・logs を共有するため anchor に残渣が出る）。
#   - fixture の origin/main は `git fetch` でなく `git update-ref refs/remotes/origin/main <sha>` で作る。
#   - rc の主張は貼付ログでなく**厳密一致 assert**（-eq 0 / -eq 1 / -eq 2）で encode する（-ne 0 は使わない）。
#   - 実リポ commit を使う assert は当該 commit 不在時 skip（clone 差で赤くしない）。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCAN="$REPO_ROOT/scripts/scribe-blob-revive-scan.sh"
  FRESH="$REPO_ROOT/scripts/scribe-base-freshness.sh"

  FX="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$FX" -c init.defaultBranch=main init -q
  git -C "$FX" config user.email t@e
  git -C "$FX" config user.name t

  # main の合成履歴:
  #   C1: a.txt=v1 / b.txt=keep
  #   C2: a.txt=v2               （正常な前進）
  #   C3: a.txt=v1               ← **過去 blob への巻き戻し**（変異注入・leg A が捕える対象）
  #   C4: c.txt 追加             （正常な前進）
  printf 'v1\n' > "$FX/a.txt"; printf 'keep\n' > "$FX/b.txt"
  git -C "$FX" add -A; git -C "$FX" commit -q -m c1
  C1="$(git -C "$FX" rev-parse HEAD)"
  printf 'v2\n' > "$FX/a.txt"
  git -C "$FX" add -A; git -C "$FX" commit -q -m c2
  C2="$(git -C "$FX" rev-parse HEAD)"
  printf 'v1\n' > "$FX/a.txt"
  git -C "$FX" add -A; git -C "$FX" commit -q -m c3
  C3="$(git -C "$FX" rev-parse HEAD)"
  printf 'c\n' > "$FX/c.txt"
  git -C "$FX" add -A; git -C "$FX" commit -q -m c4
  C4="$(git -C "$FX" rev-parse HEAD)"

  BLOB_V1="$(git -C "$FX" rev-parse "$C1:a.txt")"   # 巻き戻し先 blob
  BLOB_V2="$(git -C "$FX" rev-parse "$C2:a.txt")"

  # origin/main を fetch せずに作る（remote-tracking ref は update-ref で植える）。
  git -C "$FX" update-ref refs/remotes/origin/main "$C4"

  # branch 群（いずれも main を checkout し直さず `branch <name> <sha>` + worktree 非依存で作る）
  git -C "$FX" branch feat-stale "$C1"      # base より遅れている（leg B が捕える）
  git -C "$FX" branch feat-fresh "$C4"      # 遅れていない
  git -C "$FX" branch feat-clean "$C4"
  git -C "$FX" branch feat-clobber "$C4"
}

teardown() {
  [[ -n "${FX:-}" ]] && rm -rf "$FX"
  return 0
}

# fixture repo に「worktree を汚さず」commit を積むヘルパ（plumbing のみ・checkout しない）。
# <branch> <親sha> <path> <内容> [<path2> <内容2>...]
fx_commit_on() {
  local br="$1" parent="$2"; shift 2
  local tmpidx="$FX/.idx-$br"
  rm -f "$tmpidx"
  GIT_INDEX_FILE="$tmpidx" git -C "$FX" read-tree "$parent"
  while [[ $# -gt 0 ]]; do
    local p="$1" body="$2"; shift 2
    local blob
    blob="$(printf '%s' "$body" | git -C "$FX" hash-object -w --stdin)"
    GIT_INDEX_FILE="$tmpidx" git -C "$FX" update-index --add --cacheinfo "100644,$blob,$p"
  done
  local tree new
  tree="$(GIT_INDEX_FILE="$tmpidx" git -C "$FX" write-tree)"
  new="$(git -C "$FX" commit-tree "$tree" -p "$parent" -m "on-$br")"
  git -C "$FX" update-ref "refs/heads/$br" "$new"
  rm -f "$tmpidx"
  printf '%s' "$new"
}

# --- 特殊な履歴が要る teeth 用の使い捨て repo ヘルパ（setup の合成履歴を歪めないため別 repo に作る） ---

# 使い捨て repo を作って path を返す（mktemp -d 配下・$TMPDIR 追随）。
new_repo() {
  local d
  d="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$d" -c init.defaultBranch=main init -q
  git -C "$d" config user.email t@e
  git -C "$d" config user.name t
  printf '%s' "$d"
}

# 任意の使い捨て repo へ worktree 非依存で commit を積む（plumbing のみ・checkout しない）。
#   xcommit <repo> <ref> <parent|""> ["+<path>=<内容>" | "-<path>"]...
xcommit() {
  local repo="$1" ref="$2" parent="$3"; shift 3
  local ix="$repo/.ix" spec p body blob tree new
  rm -f "$ix"
  [[ -z "$parent" ]] || GIT_INDEX_FILE="$ix" git -C "$repo" read-tree "$parent"
  for spec in "$@"; do
    case "$spec" in
      +*) spec="${spec#+}"; p="${spec%%=*}"; body="${spec#*=}"
          blob="$(printf '%s' "$body" | git -C "$repo" hash-object -w --stdin)"
          GIT_INDEX_FILE="$ix" git -C "$repo" update-index --add --cacheinfo 100644 "$blob" "$p" ;;
      -*) p="${spec#-}"
          GIT_INDEX_FILE="$ix" git -C "$repo" update-index --force-remove "$p" ;;
    esac
  done
  tree="$(GIT_INDEX_FILE="$ix" git -C "$repo" write-tree)"
  if [[ -n "$parent" ]]; then
    new="$(git -C "$repo" commit-tree "$tree" -p "$parent" -m x)"
  else
    new="$(git -C "$repo" commit-tree "$tree" -m x)"
  fi
  git -C "$repo" update-ref "$ref" "$new"
  rm -f "$ix"
  printf '%s' "$new"
}

# path に `=` を含む fixture 用（xcommit の +<path>=<内容> 形式では表現できないため位置引数で受ける）。
#   px_commit <repo> <ref> <parent|""> <path> <内容> [<path2> <内容2>...]
px_commit() {
  local repo="$1" ref="$2" parent="$3"; shift 3
  local ix="$repo/.ixp" pth body blob tree new
  rm -f "$ix"
  [[ -z "$parent" ]] || GIT_INDEX_FILE="$ix" git -C "$repo" read-tree "$parent"
  while [[ $# -gt 0 ]]; do
    pth="$1" body="$2"; shift 2
    blob="$(printf '%s' "$body" | git -C "$repo" hash-object -w --stdin)"
    GIT_INDEX_FILE="$ix" git -C "$repo" update-index --add --cacheinfo 100644 "$blob" "$pth"
  done
  tree="$(GIT_INDEX_FILE="$ix" git -C "$repo" write-tree)"
  if [[ -n "$parent" ]]; then
    new="$(git -C "$repo" commit-tree "$tree" -p "$parent" -m x)"
  else
    new="$(git -C "$repo" commit-tree "$tree" -m x)"
  fi
  git -C "$repo" update-ref "$ref" "$new"
  rm -f "$ix"
  printf '%s' "$new"
}

# ---------- 構文 ----------

@test "blob-revive: 両 script の bash -n 構文 OK" {
  run bash -n "$SCAN"
  [ "$status" -eq 0 ]
  run bash -n "$FRESH"
  [ "$status" -eq 0 ]
}

@test "blob-revive: 両 script が実行可能ビット付き" {
  [ -x "$SCAN" ]
  [ -x "$FRESH" ]
}

# ---------- leg A: 変異注入で非空虚（過去 blob へ戻す合成 commit を検知） ----------

@test "legA: 過去 blob へ戻す合成 commit を検知し rc=1（変異注入・非空虚）" {
  run "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
  grep -q 'revived=1' <<< "$output"
  grep -q "clobber-suspect: path=a.txt" <<< "$output"
  grep -q "revived-blob=${BLOB_V1:0:7}" <<< "$output"
}

@test "legA: 巻き戻しを跨ぐ広い range でも検知する（range base より前の履歴を照合している）" {
  # C1..C4 の range で C3 の巻き戻しを検知できる＝prior-occurrence 照合が効いている。
  run "$SCAN" --repo "$FX" --range "$C1..$C4"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
}

@test "legA: 正常な合成履歴では rc=0 かつ『走査済み・0 件』と判る集計行を出す" {
  run "$SCAN" --repo "$FX" --range "$C1..$C2"
  [ "$status" -eq 0 ]
  grep -q 'revived=0' <<< "$output"
  grep -q 'clobber-suspect=0' <<< "$output"
  grep -q 'scanned-commits=1' <<< "$output"      # 沈黙でなく「走査した上で 0 件」
  grep -q 'touched-paths=1' <<< "$output"
}

@test "legA: 集計行は 0 件でも必ず stdout に出る（沈黙を green と読ませない）" {
  run "$SCAN" --repo "$FX" --range "$C1..$C2"
  [ "$status" -eq 0 ]
  grep -q '^blob-revive-scan: mode=post-merge' <<< "$output"
}

# ---------- leg A: 意図的復元の 3 分類（宣言が load-bearing であること） ----------

@test "legA: --expect-restore の宣言で declared-restore になり rc=0（宣言が load-bearing）" {
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --expect-restore "a.txt=${BLOB_V1:0:7}"
  [ "$status" -eq 0 ]
  grep -q 'clobber-suspect=0' <<< "$output"
  grep -q 'declared-restore=1' <<< "$output"
  grep -q '^declared-restore: path=a.txt' <<< "$output"
}

@test "legA: 宣言の blob が違えば declared にならず clobber-suspect のまま rc=1" {
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --expect-restore "a.txt=${BLOB_V2:0:7}"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
  grep -q 'declared-restore=0' <<< "$output"
}

@test "legA: 宣言の path が違えば declared にならず rc=1" {
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --expect-restore "b.txt=${BLOB_V1:0:7}"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
}

@test "legA: --allowlist file 経由の宣言でも declared-restore になり rc=0" {
  printf '# 意図的な再 land\na.txt %s PR#999 で意図的に戻した\n' "${BLOB_V1:0:7}" > "$FX/allow.txt"
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --allowlist "$FX/allow.txt"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
}

@test "legA: --allowlist の根拠列が無い行は harness-fail(2)（宣言に説明責任を持たせる）" {
  printf 'a.txt %s\n' "${BLOB_V1:0:7}" > "$FX/allow-bad.txt"
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --allowlist "$FX/allow-bad.txt"
  [ "$status" -eq 2 ]
}

# ---------- leg A: harness-fail teeth（緑にも検知にも倒さない） ----------

@test "legA: 不在 ref は harness-fail(2)（検知にも clean にも倒さない）" {
  # 下の 40 桁 hex は **どの object も指さない合成値**（意図的に解決不能な ref を作るための literal）。
  run "$SCAN" --repo "$FX" --range "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef..$C4"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "legA: 非 git dir は harness-fail(2)" {
  NOGIT="$(cd "$(mktemp -d)" && pwd -P)"
  run "$SCAN" --repo "$NOGIT" --range "$C1..$C4"
  rm -rf "$NOGIT"
  [ "$status" -eq 2 ]
}

@test "legA: --range 欠落は harness-fail(2)（usage error を検知に倒さない）" {
  run "$SCAN" --repo "$FX"
  [ "$status" -eq 2 ]
}

@test "legA: --range の値欠落（次フラグの誤消費）は harness-fail(2)" {
  run "$SCAN" --range --repo "$FX"
  [ "$status" -eq 2 ]
}

@test "legA: '...' 形式の range は harness-fail(2)（対称差は本検査の意味論と合わない）" {
  run "$SCAN" --repo "$FX" --range "$C1...$C4"
  [ "$status" -eq 2 ]
}

@test "legA: 空 range（走査対象 commit 0）は harness-fail(2)" {
  run "$SCAN" --repo "$FX" --range "$C4..$C4"
  [ "$status" -eq 2 ]
}

@test "legA: 走査対象 file 0 件（空 commit のみの range）は harness-fail(2)" {
  local e1 e2
  e1="$(git -C "$FX" commit-tree "$C4^{tree}" -p "$C4" -m empty1)"
  e2="$(git -C "$FX" commit-tree "$C4^{tree}" -p "$e1" -m empty2)"
  run "$SCAN" --repo "$FX" --range "$C4..$e2"
  [ "$status" -eq 2 ]
}

@test "legA: 未知オプションは harness-fail(2)" {
  run "$SCAN" --repo "$FX" --range "$C1..$C4" --bogus
  [ "$status" -eq 2 ]
}

# ---------- leg A: merge の無音 skip をしない ----------

@test "legA: merge commit を無音 skip せず件数を集計行へ出す" {
  # side branch を作って main へ merge commit を積む（worktree 非依存の plumbing）。
  local side merged
  side="$(fx_commit_on feat-clean "$C4" side.txt 'side')"
  merged="$(git -C "$FX" commit-tree "$C4^{tree}" -p "$C4" -p "$side" -m merge-commit)"
  run "$SCAN" --repo "$FX" --range "$C4..$merged"
  # merge の first-parent diff は空（tree=C4）なので走査対象 file 0＝harness-fail(2) が正しい挙動。
  # この run を assert 無しで捨てない（死実行にすると「何を確かめた run か」が消える）。
  [ "$status" -eq 2 ]
  # 重要なのは「merge を数えている」ことなので、file を伴う merge で確かめ直す。
  local merged2
  merged2="$(git -C "$FX" commit-tree "$(git -C "$FX" rev-parse "$side^{tree}")" -p "$C4" -p "$side" -m merge-commit2)"
  run "$SCAN" --repo "$FX" --range "$C4..$merged2"
  [ "$status" -eq 0 ]
  grep -q 'merges=1' <<< "$output"
  grep -q 'skipped-merges=0' <<< "$output"
}

# ---------- leg A: read-only 規律（worktree と HEAD を変更しない） ----------

@test "legA: 実行前後で HEAD と working tree の状態が不変（git の read しかしない）" {
  local head_before head_after st_before st_after
  head_before="$(git -C "$FX" rev-parse HEAD)"
  st_before="$(git -C "$FX" status --porcelain)"
  run "$SCAN" --repo "$FX" --range "$C1..$C4"
  [ "$status" -eq 1 ]
  head_after="$(git -C "$FX" rev-parse HEAD)"
  st_after="$(git -C "$FX" status --porcelain)"
  [ "$head_before" = "$head_after" ]
  [ "$st_before" = "$st_after" ]
}

@test "legA: 監視トリガー literal を出力へ焼かない（行頭 STATUS: / gate-pending / ENV_DEGRADED）" {
  run "$SCAN" --repo "$FX" --range "$C1..$C4"
  [ "$status" -eq 1 ]
  run ! grep -qE '^[[:space:]]*STATUS:|gate-pending|ENV_DEGRADED' <<< "$output"
}

# ---------- leg B: base 鮮度（is-ancestor） ----------

@test "legB: stale base の branch を --rc-leg b で検知し rc=1" {
  local br
  br="$(fx_commit_on feat-stale "$C1" d.txt 'd')"
  run "$FRESH" --repo "$FX" --branch feat-stale --base-ref origin/main --rc-leg b
  [ "$status" -eq 1 ]
  grep -q 'is-ancestor=stale' <<< "$output"
}

@test "legB: fresh base の branch は --rc-leg b で rc=0" {
  local br
  br="$(fx_commit_on feat-fresh "$C4" e.txt 'e')"
  run "$FRESH" --repo "$FX" --branch feat-fresh --base-ref origin/main --rc-leg b
  [ "$status" -eq 0 ]
  grep -q 'is-ancestor=fresh' <<< "$output"
}

@test "legB: 使った base-ref 名と解決 sha を出力へ刻む（local main と origin/main は同値でない）" {
  local br
  br="$(fx_commit_on feat-fresh "$C4" e.txt 'e')"
  run "$FRESH" --repo "$FX" --branch feat-fresh --base-ref origin/main --rc-leg b
  [ "$status" -eq 0 ]
  grep -q "base-ref=origin/main@${C4:0:7}" <<< "$output"
  grep -q "branch=feat-fresh@${br:0:7}" <<< "$output"
}

@test "legB: comm 交差（branch が触った file ∩ base が触った file）を advisory として出す" {
  # feat-stale は C1 から c.txt を触る。merge-base(C1)..origin/main(C4) でも main が c.txt を追加して
  # いるので交差 1 件＝squash 適用時に片方の変更が消える形（実際に踏んだ事故の形）。
  # ※ a.txt は C3 で v1 へ戻っているため C1 と C4 で blob 同一＝base 側 diff に出ない（交差にならない）。
  local br
  br="$(fx_commit_on feat-stale "$C1" c.txt 'branch-side-c')"
  run "$FRESH" --repo "$FX" --branch feat-stale --base-ref origin/main --rc-leg b
  [ "$status" -eq 1 ]
  grep -q 'overlap-files=1' <<< "$output"
  grep -q '^overlap: path=c.txt' <<< "$output"
}

@test "legB: 交差が無ければ overlap-files=0（弱い条件が green だと分かる）" {
  local br
  br="$(fx_commit_on feat-stale "$C1" newfile.txt 'x')"
  run "$FRESH" --repo "$FX" --branch feat-stale --base-ref origin/main --rc-leg b
  [ "$status" -eq 1 ]
  grep -q 'overlap-files=0' <<< "$output"
}

# ---------- leg B-2: content 条件（rc を決める 1 本） ----------

@test "legB-2: base の過去 blob へ巻き戻す branch を既定 rc-leg で検知し rc=1" {
  # C4 時点の a.txt は v1。branch が a.txt を v2（C2 の過去 blob）へ書き戻す＝clobber。
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  grep -q 'rc-leg=b2' <<< "$output"
  grep -q 'clobber-suspect=1' <<< "$output"
  grep -q '^clobber-suspect: path=a.txt' <<< "$output"
  grep -q "br-blob=${BLOB_V2:0:7}" <<< "$output"
  grep -q "base-cur-blob=${BLOB_V1:0:7}" <<< "$output"
}

@test "legB-2: is-ancestor が fresh でも content 条件で RED になる（leg B では捕まらない class）" {
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  grep -q 'is-ancestor=fresh' <<< "$output"   # advisory は green
  grep -q 'overlap-files=0' <<< "$output"     # 弱い条件も green
  grep -q 'clobber-suspect=1' <<< "$output"   # rc を決めるのは B-2 だけ
}

@test "legB-2: 正常な branch（新規 file 追加のみ）は rc=0" {
  local br
  br="$(fx_commit_on feat-clean "$C4" newfile.txt 'fresh content')"
  run "$FRESH" --repo "$FX" --branch feat-clean --base-ref origin/main
  [ "$status" -eq 0 ]
  grep -q 'clobber-suspect=0' <<< "$output"
}

@test "legB-2: branch が base より新しい内容へ進めた場合は rc=0（過去 blob でなければ RED にしない）" {
  local br
  br="$(fx_commit_on feat-clean "$C4" a.txt 'v3-new
')"
  run "$FRESH" --repo "$FX" --branch feat-clean --base-ref origin/main
  [ "$status" -eq 0 ]
  grep -q 'clobber-suspect=0' <<< "$output"
}

@test "legB-2: --expect-restore で declared-restore になり rc=0（宣言が load-bearing）" {
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main \
        --expect-restore "a.txt=${BLOB_V2:0:7}"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  grep -q 'clobber-suspect=0' <<< "$output"
}

@test "legB-2: stale base でも rc を決めるのは content 条件だけ（rc を多重化しない）" {
  # stale（is-ancestor=stale）だが content 巻き戻しは無い → 既定 rc-leg=b2 では rc=0。
  local br
  br="$(fx_commit_on feat-stale "$C1" newfile.txt 'x')"
  run "$FRESH" --repo "$FX" --branch feat-stale --base-ref origin/main
  [ "$status" -eq 0 ]
  grep -q 'is-ancestor=stale' <<< "$output"
  grep -q 'clobber-suspect=0' <<< "$output"
}

# ---------- leg B: harness-fail teeth ----------

@test "legB: 不在 base-ref は harness-fail(2)（fetch せず落とす）" {
  local br
  br="$(fx_commit_on feat-fresh "$C4" e.txt 'e')"
  run "$FRESH" --repo "$FX" --branch feat-fresh --base-ref refs/remotes/origin/nonexistent
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "legB: 不在 branch は harness-fail(2)" {
  run "$FRESH" --repo "$FX" --branch no-such-branch --base-ref origin/main
  [ "$status" -eq 2 ]
}

@test "legB: 非 git dir は harness-fail(2)" {
  NOGIT="$(cd "$(mktemp -d)" && pwd -P)"
  run "$FRESH" --repo "$NOGIT" --branch main
  rm -rf "$NOGIT"
  [ "$status" -eq 2 ]
}

@test "legB: --branch 欠落は harness-fail(2)（引数欠落の usage error を検知に倒さない）" {
  run "$FRESH" --repo "$FX"
  [ "$status" -eq 2 ]
}

@test "legB: --branch の値欠落（次フラグの誤消費）は harness-fail(2)" {
  run "$FRESH" --branch --repo "$FX"
  [ "$status" -eq 2 ]
}

@test "legB: 不正な --rc-leg は harness-fail(2)" {
  run "$FRESH" --repo "$FX" --branch feat-fresh --base-ref origin/main --rc-leg bogus
  [ "$status" -eq 2 ]
}

@test "legB: 走査対象 file 0 件（branch が merge-base から何も変えていない）は harness-fail(2)" {
  local e1
  e1="$(git -C "$FX" commit-tree "$C4^{tree}" -p "$C4" -m empty)"
  git -C "$FX" update-ref refs/heads/feat-clean "$e1"
  run "$FRESH" --repo "$FX" --branch feat-clean --base-ref origin/main
  [ "$status" -eq 2 ]
}

@test "legB: 既定 base-ref は origin/main（未指定でも origin/main を解決して刻む）" {
  local br
  br="$(fx_commit_on feat-fresh "$C4" e.txt 'e')"
  run "$FRESH" --repo "$FX" --branch feat-fresh --rc-leg b
  [ "$status" -eq 0 ]
  grep -q "base-ref=origin/main@${C4:0:7}" <<< "$output"
}

@test "legB: 実行前後で HEAD と working tree の状態が不変（git の read しかしない）" {
  local br head_before head_after st_before st_after
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  head_before="$(git -C "$FX" rev-parse HEAD)"
  st_before="$(git -C "$FX" status --porcelain)"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  head_after="$(git -C "$FX" rev-parse HEAD)"
  st_after="$(git -C "$FX" status --porcelain)"
  [ "$head_before" = "$head_after" ]
  [ "$st_before" = "$st_after" ]
}

# ---------- pre-merge モード（A2 = leg B-2 と同一実装への委譲） ----------

@test "legA --mode pre-merge: leg B-2 へ委譲し同一 rc を返す（判定を二重実装しない）" {
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$SCAN" --repo "$FX" --mode pre-merge --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  grep -q '^base-freshness: ' <<< "$output"
  grep -q 'clobber-suspect=1' <<< "$output"
}

@test "legA --mode pre-merge: 宣言フラグも委譲先へ渡る（rc=0）" {
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$SCAN" --repo "$FX" --mode pre-merge --branch feat-clobber --base-ref origin/main \
        --expect-restore "a.txt=${BLOB_V2:0:7}"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
}

@test "legA --mode pre-merge: --branch 欠落は harness-fail(2)" {
  run "$SCAN" --repo "$FX" --mode pre-merge
  [ "$status" -eq 2 ]
}

@test "legA: 不明な --mode は harness-fail(2)" {
  run "$SCAN" --repo "$FX" --mode bogus --range "$C1..$C4"
  [ "$status" -eq 2 ]
}

# ---------- 実リポの実 commit（当該 commit 不在なら skip・clone 差で赤くしない） ----------

real_commit_or_skip() { # <rev>...
  local r
  # shallow clone では両 script が設計どおり harness-fail(2) を返すため、実データ teeth は
  # 「commit が在るのに rc が期待と違う」形で RED になる。file 冒頭の「clone 差で赤くしない」
  # 規律に合わせ、commit 不在と同様に skip する（clone の形の差で赤くしない）。
  [[ "$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)" == "false" ]] \
    || skip "本 clone が shallow（両 script は設計どおり harness-fail する＝実データ teeth の対象外）"
  for r in "$@"; do
    git -C "$REPO_ROOT" rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1 \
      || skip "実 commit $r が本 clone に無い"
  done
}

@test "実データ legA: range=75cfb24..7e5449d で当該 2 file の復活を検知し rc=1" {
  real_commit_or_skip 75cfb24 7e5449d
  run "$SCAN" --repo "$REPO_ROOT" --range 75cfb24..7e5449d
  [ "$status" -eq 1 ]
  grep -q 'revived=2' <<< "$output"
  grep -q 'clobber-suspect=2' <<< "$output"
  grep -q 'path=scriptorium-engine/scripts/orch-stale-scan.sh' <<< "$output"
  grep -q 'path=scriptorium-engine/tests/scenarios/orch-stale-scan.bats' <<< "$output"
}

@test "実データ legB: BR=cf3bc2e / BASE_REF=75cfb24 は is-ancestor green（この class は捕まえない）" {
  real_commit_or_skip cf3bc2e 75cfb24
  run "$FRESH" --repo "$REPO_ROOT" --branch cf3bc2e --base-ref 75cfb24 --rc-leg b
  [ "$status" -eq 0 ]
  grep -q 'is-ancestor=fresh' <<< "$output"
  grep -q 'overlap-files=0' <<< "$output"
}

@test "実データ legB-2: 同 commit を既定 rc-leg で検知し rc=1（捕捉責任は B-2 にある）" {
  real_commit_or_skip cf3bc2e 75cfb24
  run "$FRESH" --repo "$REPO_ROOT" --branch cf3bc2e --base-ref 75cfb24
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=2' <<< "$output"
  grep -q 'path=scriptorium-engine/scripts/orch-stale-scan.sh' <<< "$output"
}

@test "実データ legA: first-parent 60 commit（0c7ce5c..9a319ac）で revival 4 件" {
  real_commit_or_skip 0c7ce5c 9a319ac
  run "$SCAN" --repo "$REPO_ROOT" --range 0c7ce5c..9a319ac
  [ "$status" -eq 1 ]
  grep -q 'scanned-commits=60' <<< "$output"
  grep -q 'revived=4' <<< "$output"
  grep -q 'clobber-suspect=4' <<< "$output"
  grep -q 'merges=1' <<< "$output"
  grep -q 'skipped-merges=0' <<< "$output"
  # 走査母数も厳密一致で pin する（件数が黙って動いたら赤くする）。
  # 内訳: blob を持つ変更のあった path 193 + 削除しか無かった path 4 = 197（＝admin 実測の touch file 数）。
  grep -q 'touched-paths=193' <<< "$output"
  grep -q 'deleted-only-paths=4' <<< "$output"
}

@test "実データ legA: 宣言を与えた 2 件だけ declared-restore に落ちる（3 分類が実データで効く）" {
  real_commit_or_skip 0c7ce5c 9a319ac
  run "$SCAN" --repo "$REPO_ROOT" --range 0c7ce5c..9a319ac \
        --expect-restore 'scriptorium-engine/scripts/orch-stale-scan.sh=edfa4e7' \
        --expect-restore 'scriptorium-engine/tests/scenarios/orch-stale-scan.bats=2aa9398'
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=2' <<< "$output"
  grep -q 'declared-restore=2' <<< "$output"
  grep -q 'declared-restore: path=scriptorium-engine/scripts/orch-stale-scan.sh commit=2e5a45e' <<< "$output"
  grep -q 'clobber-suspect: path=scriptorium-engine/scripts/orch-stale-scan.sh commit=7e5449d' <<< "$output"
}

# ---------- ERRATA-1 FIX-1: 空 prev field（delete → 同一 blob 再追加）で壊れない ----------

@test "FIX-1 legA: delete 後に同一 blob を再追加する range を rc=1 で検知し、集計行と path を出す" {
  # prev（直前 blob）が空になる唯一の形。field 区切りが畳まれると path が空になり配列 subscript で
  # abort し、**stdout 完全空 + rc=1** という「検知に見えるが何も出ていない」状態になる（実測）。
  local r c1 c2 c3 blob
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+dead.txt=v1' '+a.txt=x')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '-dead.txt'    '+a.txt=y')"
  c3="$(xcommit "$r" refs/heads/main "$c2" '+dead.txt=v1')"
  blob="$(git -C "$r" rev-parse "$c1:dead.txt")"
  run "$SCAN" --repo "$r" --range "$c1..$c3"
  rm -rf "$r"
  [ "$status" -eq 1 ]
  grep -q '^blob-revive-scan: mode=post-merge' <<< "$output"
  grep -q 'revived=1' <<< "$output"
  grep -q 'clobber-suspect=1' <<< "$output"
  grep -q '^clobber-suspect: path=dead.txt' <<< "$output"
  grep -q "revived-blob=${blob:0:7}" <<< "$output"
  grep -q 'prev-blob=none' <<< "$output"      # 空 prev は none として表示する（field は落とさない）
  # ※ `run !` は $output を上書きするので、この形の assert は必ず最後に置く。
  run ! grep -q 'bad array subscript' <<< "$output"
}

@test "FIX-1 legA: 同じ形へ --expect-restore を与えると declared-restore になり rc=0" {
  local r c1 c2 c3 blob
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+dead.txt=v1' '+a.txt=x')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '-dead.txt'    '+a.txt=y')"
  c3="$(xcommit "$r" refs/heads/main "$c2" '+dead.txt=v1')"
  blob="$(git -C "$r" rev-parse "$c1:dead.txt")"
  run "$SCAN" --repo "$r" --range "$c1..$c3" --expect-restore "dead.txt=${blob:0:7}"
  rm -rf "$r"
  [ "$status" -eq 0 ]
  grep -q 'clobber-suspect=0' <<< "$output"
  grep -q 'declared-restore=1' <<< "$output"
  grep -q '^declared-restore: path=dead.txt' <<< "$output"
}

# ---------- ERRATA-1 FIX-2: base が削除した path の復活を素通ししない ----------

@test "FIX-2 legB-2: base が削除した path を branch が過去 blob で復活させたら rc=1" {
  # base に現行 blob が無い＝「新規追加だから安全」ではない。base 側の削除が squash で消える形。
  local r c1 c2 blob
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+dead.txt=v1' '+a.txt=x')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '-dead.txt')"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  blob="$(git -C "$r" rev-parse "$c1:dead.txt")"
  xcommit "$r" refs/heads/feat "$c2" '+dead.txt=v1' > /dev/null
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main
  rm -rf "$r"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
  grep -q '^clobber-suspect: path=dead.txt' <<< "$output"
  grep -q "br-blob=${blob:0:7}" <<< "$output"
  grep -q 'base-cur-blob=absent' <<< "$output"   # 現行不在は sentinel で明示（沈黙で落とさない）
}

@test "FIX-2 legB-2: base 削除 path の復活も宣言すれば declared-restore で rc=0" {
  local r c1 c2 blob
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+dead.txt=v1' '+a.txt=x')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '-dead.txt')"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  blob="$(git -C "$r" rev-parse "$c1:dead.txt")"
  xcommit "$r" refs/heads/feat "$c2" '+dead.txt=v1' > /dev/null
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main --expect-restore "dead.txt=${blob:0:7}"
  rm -rf "$r"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  grep -q 'clobber-suspect=0' <<< "$output"
}

# ---------- ERRATA-1 FIX-3: 継承した git 環境変数で別 repo を走査しない ----------

@test "FIX-3 legA: GIT_DIR 汚染下でも --repo が非 git dir なら harness-fail(2)" {
  # GIT_DIR/GIT_WORK_TREE が export されていると `git -C <非 git dir>` が環境側の repo を解決し、
  # **走査していない repo の結果を --repo の名前で** rc=1 として報告する（実測）。
  local nogit
  nogit="$(cd "$(mktemp -d)" && pwd -P)"
  run env GIT_DIR="$FX/.git" GIT_WORK_TREE="$FX" "$SCAN" --repo "$nogit" --range "$C1..$C4"
  rm -rf "$nogit"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "FIX-3 legB: GIT_DIR 汚染下でも --repo が非 git dir なら harness-fail(2)" {
  local nogit
  nogit="$(cd "$(mktemp -d)" && pwd -P)"
  run env GIT_DIR="$FX/.git" GIT_WORK_TREE="$FX" "$FRESH" --repo "$nogit" --branch main --base-ref "$C2"
  rm -rf "$nogit"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "FIX-3: GIT_DIR 汚染下でも正規の --repo なら従来どおり検知する（過剰に殺していない）" {
  run env GIT_DIR="$FX/.git" GIT_WORK_TREE="$FX" "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
}

# ---------- ERRATA-1 FIX-4: shallow clone を clean と名乗らない ----------

@test "FIX-4 legA: shallow clone（--depth）は harness-fail(2)（履歴照合が成立しない）" {
  # full clone が rc=1 で検知する同一 clobber を、shallow では 0 件 clean と報告していた（実測）。
  local par sh
  par="$(cd "$(mktemp -d)" && pwd -P)"   # 親ごと消す（clone 先だけ消すと親が毎回残る）
  sh="$par/sh"
  git clone -q --depth 2 "file://$FX" "$sh"
  [ "$(git -C "$sh" rev-parse --is-shallow-repository)" = "true" ]
  run "$SCAN" --repo "$sh" --range "$C3..$C4"
  rm -rf "$par"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "FIX-4 legB: shallow clone（--depth）は harness-fail(2)" {
  # base-ref を C3 に取ると、guard を外した場合に「走査は成立するが履歴が足りず clobber-suspect=0」
  # ＝**clean を名乗る** 経路へ入る（実測 rc=0）。この引数でないと別理由の rc=2 で空虚な teeth になる。
  local par sh
  par="$(cd "$(mktemp -d)" && pwd -P)"
  sh="$par/sh"
  git clone -q --depth 2 "file://$FX" "$sh"
  [ "$(git -C "$sh" rev-parse --is-shallow-repository)" = "true" ]
  run "$FRESH" --repo "$sh" --branch main --base-ref "$C3"
  rm -rf "$par"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "FIX-4 legA: full clone は shallow guard に掛からず従来どおり検知する（過剰に殺していない）" {
  local par full
  par="$(cd "$(mktemp -d)" && pwd -P)"
  full="$par/full"
  git clone -q "file://$FX" "$full"
  [ "$(git -C "$full" rev-parse --is-shallow-repository)" = "false" ]
  run "$SCAN" --repo "$full" --range "$C2..$C3"
  rm -rf "$par"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
}

# ---------- ERRATA-1 minor: 削除のみ range / skipped-merges 実カウント / C-quote path ----------

@test "MINOR-m1 legA: 削除しか無い range は harness-fail でなく rc=0 + deleted-only-paths を出す" {
  # 以前は「走査対象 file が 0 件」で rc=2 になり、理由文（走査していない）が事実と食い違っていた。
  local r c1 c2
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+a.txt=x' '+gone.txt=g')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '-gone.txt')"
  run "$SCAN" --repo "$r" --range "$c1..$c2"
  rm -rf "$r"
  [ "$status" -eq 0 ]
  grep -q 'touched-paths=0' <<< "$output"
  grep -q 'deleted-only-paths=1' <<< "$output"
  grep -q 'revived=0' <<< "$output"
}

@test "MINOR-m1 legA: 変更も削除も無い range は従来どおり harness-fail(2)（緩めすぎていない）" {
  local r c1 e1
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main "" '+a.txt=x')"
  e1="$(git -C "$r" commit-tree "$c1^{tree}" -p "$c1" -m empty)"
  run "$SCAN" --repo "$r" --range "$c1..$e1"
  rm -rf "$r"
  [ "$status" -eq 2 ]
}

@test "MINOR-m2 legA: skipped-merges は実カウント（走査できなかった merge を 1 と数える）" {
  # first-parent diff が空の merge は raw 行を 1 本も生まない＝その merge については何も見ていない。
  # literal '0' を焼いていると、この fixture でも 0 が出て assert が空虚になる。
  local side merge_empty after
  side="$(fx_commit_on feat-clean "$C4" side.txt 'side')"
  merge_empty="$(git -C "$FX" commit-tree "$C4^{tree}" -p "$C4" -p "$side" -m merge-empty)"
  git -C "$FX" update-ref refs/heads/tmp-m "$merge_empty"
  after="$(fx_commit_on tmp-m "$merge_empty" after.txt 'after')"
  run "$SCAN" --repo "$FX" --range "$C4..$after"
  [ "$status" -eq 0 ]
  grep -q 'scanned-commits=2' <<< "$output"
  grep -q 'merges=1' <<< "$output"
  grep -q 'skipped-merges=1' <<< "$output"
  grep -q 'touched-paths=1' <<< "$output"
}

@test "MINOR-m3 legB-2: C-quote が要る path（TAB 入り）の clobber を無言で落とさない" {
  # 生 path だけだと履歴側の表現（"q\tb.txt"）と一致せず、行表現だけだと rev-parse が解決できない。
  # どちらか一方しか持たない実装では **rc=0 で素通り**する（実測）。
  local r c1 c2 tp
  tp=$'q\tb.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  xcommit "$r" refs/heads/feat "$c2" "+$tp=v1" > /dev/null
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main
  rm -rf "$r"
  [ "$status" -eq 1 ]
  grep -q 'quoted-paths=1' <<< "$output"
  grep -q 'clobber-suspect=1' <<< "$output"
}

@test "MINOR-m3 legB-2: 通常 path のみなら quoted-paths=0（件数が常時 1 になっていない）" {
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  grep -q 'quoted-paths=0' <<< "$output"
}

# ---------- ERRATA-2 FIX-5: 中間表現の区切りを含む path を無言 clean にしない（leg B-2 の fail-open） ----------

@test "FIX-5 legB-2: path が US(0x1f) を含む clobber は harness-fail(2)（無言 clean にしない）" {
  # cand.txt の第 2 field は `-z` 由来の生 path。git は control char を -z 出力では quote しないため、
  # path が US を含むと field が右シフトし want[qpath] に blob でなく path の断片が入る
  # → hit が出ず **clobber-suspect=0 / rc=0** で素通りしていた（実測）。
  local r c1 c2 tp
  tp=$'u\037s.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  xcommit "$r" refs/heads/feat "$c2" "+$tp=v1" > /dev/null
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main
  rm -rf "$r"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
  grep -q 'US(0x1f)' <<< "$output"
  # 「clobber は無い」と名乗っていないこと（fail-open の再発検知）。
  run ! grep -q 'clobber-suspect=0' <<< "$output"
}

@test "FIX-5 legB-2: path が LF を含む clobber も harness-fail(2)（record 区切りの同一 bug class）" {
  local r c1 c2 tp
  tp=$'u\ns.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  xcommit "$r" refs/heads/feat "$c2" "+$tp=v1" > /dev/null
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main
  rm -rf "$r"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
}

@test "FIX-5 legA: 同じ US 入り path の clobber を leg A は従来どおり rc=1 で検知する（guard は leg B-2 側だけで足りる）" {
  # leg A の path は `log --raw`（quotePath=false でも control char は C-quote される）由来なので
  # 生の US が EVENT 行へ載らない＝同一 bug class を持たない。過剰に殺していないことも同時に示す。
  local r c1 c2 feat tp
  tp=$'u\037s.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  feat="$(xcommit "$r" refs/heads/feat "$c2" "+$tp=v1")"
  run "$SCAN" --repo "$r" --range "$c1..$feat"
  rm -rf "$r"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
}

# ---------- ERRATA-2 minor: 宣言表記の非対称を明文化・branch 削除の痕跡・leg B の allowlist ----------

@test "MINOR legB: --allowlist file 経由の宣言でも declared-restore になり rc=0（leg B 側の宣言 teeth）" {
  # acceptance 4 の「宣言 2 経路」は leg A だけでなく leg B-2 でも実証が要る（従来 0 本だった）。
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  printf '# 意図的な再 land\na.txt %s PR#999 で意図的に戻した\n' "${BLOB_V2:0:7}" > "$FX/allow-b.txt"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main --allowlist "$FX/allow-b.txt"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  grep -q 'clobber-suspect=0' <<< "$output"
}

@test "MINOR legB: --allowlist の根拠列が無い行は harness-fail(2)（leg B 側も説明責任を持たせる）" {
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  printf 'a.txt %s\n' "${BLOB_V2:0:7}" > "$FX/allow-b-bad.txt"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main --allowlist "$FX/allow-b-bad.txt"
  [ "$status" -eq 2 ]
}

@test "MINOR: 宣言 path の表記が 2 leg で異なることを teeth で pin する（無言の非対称にしない）" {
  # leg A は C-quote 形・leg B-2 は生 path。方向は fail-closed（表記違いは declared にならず rc=1）。
  # usage / ヘッダにその旨を明記してあることも同時に確かめる。
  local r c1 c2 feat tp blob
  tp=$'q\tb.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  feat="$(xcommit "$r" refs/heads/feat "$c2" "+$tp=v1")"
  blob="$(git -C "$r" rev-parse "$c1:$tp")"

  # leg A: C-quote 形の宣言だけが効く
  run "$SCAN" --repo "$r" --range "$c1..$feat" --expect-restore "\"q\\tb.txt\"=${blob:0:7}"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  run "$SCAN" --repo "$r" --range "$c1..$feat" --expect-restore "$tp=${blob:0:7}"
  [ "$status" -eq 1 ]                       # 生 path では効かない（fail-closed）

  # leg B-2: 生 path の宣言だけが効く
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main --expect-restore "$tp=${blob:0:7}"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main --expect-restore "\"q\\tb.txt\"=${blob:0:7}"
  rm -rf "$r"
  [ "$status" -eq 1 ]                       # C-quote 形では効かない（fail-closed）

  # 非対称が **--help の実出力** に出ていること（script 全文 grep だとヘッダ comment に当たるため、
  # usage の記載を削っても green になり pin として空虚になる）。
  run "$SCAN" --help
  [ "$status" -eq 0 ]
  grep -q 'C-quote 形' <<< "$output"
  run "$FRESH" --help
  [ "$status" -eq 0 ]
  grep -q '生 path' <<< "$output"
}

@test "MINOR legB: branch が削除した path は集計行へ br-deleted-paths として痕跡を残す" {
  # branch 側の削除による clobber は本検査の射程外。射程外であることを沈黙させない（rc は変えない）。
  local r c1 c2
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+a.txt=x' '+doomed.txt=d')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '+a.txt=y')"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  xcommit "$r" refs/heads/feat "$c2" '-doomed.txt' '+new.txt=n' > /dev/null
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main
  rm -rf "$r"
  [ "$status" -eq 0 ]
  grep -q 'br-deleted-paths=1' <<< "$output"
  grep -q 'clobber-suspect=0' <<< "$output"
}

@test "MINOR legB: 通常の branch では br-deleted-paths=0（件数が常時 1 になっていない）" {
  local br
  br="$(fx_commit_on feat-clean "$C4" newfile.txt 'fresh content')"
  run "$FRESH" --repo "$FX" --branch feat-clean --base-ref origin/main
  [ "$status" -eq 0 ]
  grep -q 'br-deleted-paths=0' <<< "$output"
}

@test "MINOR legB: 外部コマンド失敗は rc=1（検知）でなく harness-fail(2) へ写像する" {
  # `set -e` 下で comm / sort / tr を素で実行すると harness 失敗が rc=1 に化け、集計行も出ない
  # silent RED になる。comm を必ず失敗する shim に差し替えた「壊れた harness」で rc=2 を要求する。
  # ★branch に**実際の clobber を積んでから**回すこと。積まないと「走査対象 file が 0 件」という
  #   別理由で rc=2 になり teeth が空虚になる（rc 写像を撤回しても green のまま＝実測）。
  local br shim
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  shim="$(cd "$(mktemp -d)" && pwd -P)"
  printf '#!/bin/sh\nexit 3\n' > "$shim/comm"
  chmod +x "$shim/comm"
  run env PATH="$shim:$PATH" "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  rm -rf "$shim"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
  # rc=1（検知）へ化けていないこと＝この branch は本来 rc=1 になる clobber を持っている。
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
}

# ---------- ERRATA-3 FIX-A: wc の rc を契約 {0,1,2} の外へ漏らさない ----------

@test "FIX-A legA: wc が失敗しても rc=2（契約外の rc をそのまま漏らさない）" {
  # 実測（修正前）: wc を exit 3 の shim にすると legA も legB-2 も **rc=3 かつ stdout 0 byte**。
  # rc 契約 {0,1,2} 違反と「沈黙を green と読ませない」不変量の同時破れ。
  local shim
  shim="$(cd "$(mktemp -d)" && pwd -P)"
  printf '#!/bin/sh\nexit 3\n' > "$shim/wc"
  chmod +x "$shim/wc"
  run env PATH="$shim:$PATH" "$SCAN" --repo "$FX" --range "$C2..$C3"
  rm -rf "$shim"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
  # guard あり時は本来 rc=1 になる range であることを同時に示す（別理由の 2 で空虚にしない）。
  run "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 1 ]
}

@test "FIX-A legB: wc が失敗しても rc=2（契約外の rc をそのまま漏らさない）" {
  local br shim
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  shim="$(cd "$(mktemp -d)" && pwd -P)"
  printf '#!/bin/sh\nexit 3\n' > "$shim/wc"
  chmod +x "$shim/wc"
  run env PATH="$shim:$PATH" "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  rm -rf "$shim"
  [ "$status" -eq 2 ]
  grep -q 'harness-fail' <<< "$output"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
}

@test "FIX-A: 依存 probe が実使用コマンド（wc）の不在を rc=2 で捕まえる（rc=127 を漏らさない）" {
  # PATH を「bash と git 等はあるが wc が無い」状態にして、127 でなく 2 で落ちることを要求する。
  local stub c p
  stub="$(cd "$(mktemp -d)" && pwd -P)"
  for c in bash sh git awk comm sort mktemp tr sed head cat env printf readlink dirname chmod rm; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$stub/$c"
  done
  run env PATH="$stub" "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 2 ]
  grep -q '外部コマンドが見つかりません: wc' <<< "$output"
  run env PATH="$stub" "$FRESH" --repo "$FX" --branch feat-fresh --base-ref origin/main
  rm -rf "$stub"
  [ "$status" -eq 2 ]
  grep -q '外部コマンドが見つかりません: wc' <<< "$output"
}

# ---------- ERRATA-3 minor n1 / n2: 宣言の表現能力 ----------

@test "MINOR-n1: path に等号を含む file も宣言できる（最後の = で分割する）" {
  # 最短前方一致（%%=*）だと path が 'k' に切れて宣言が黙って効かなかった。
  local r c1 c2 feat blob tp
  tp='k=v.txt'
  r="$(new_repo)"
  # ※ xcommit の spec 形式（+<path>=<内容>）は最短前方一致で分割するため `=` 入り path を作れない。
  #    この fixture だけ直 plumbing で組む（ヘルパを変えると既存 20 数箇所の呼出しに影響するため）。
  c1="$(px_commit "$r" refs/heads/main ""    "$tp" v1 plain.txt p)"
  c2="$(px_commit "$r" refs/heads/main "$c1" "$tp" v2)"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  feat="$(px_commit "$r" refs/heads/feat "$c2" "$tp" v1)"
  blob="$(git -C "$r" rev-parse "$c1:$tp")"
  # leg A
  run "$SCAN" --repo "$r" --range "$c1..$feat" --expect-restore "$tp=${blob:0:7}"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  # leg B-2
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main --expect-restore "$tp=${blob:0:7}"
  rm -rf "$r"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
}

@test "MINOR-n2: --allowlist は空白と # を含む path を表現できる（TAB 区切り・行頭のみコメント）" {
  local r c1 c2 feat blob tp
  tp='a b#c.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  feat="$(xcommit "$r" refs/heads/feat "$c2" "+$tp=v1")"
  blob="$(git -C "$r" rev-parse "$c1:$tp")"
  printf '# 行頭コメントは落とす\n%s\t%s\tPR#999 で意図的に戻した\n' "$tp" "${blob:0:7}" > "$r/allow.txt"
  run "$FRESH" --repo "$r" --branch feat --base-ref origin/main --allowlist "$r/allow.txt"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  run "$SCAN" --repo "$r" --range "$c1..$feat" --allowlist "$r/allow.txt"
  rm -rf "$r"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
}

@test "MINOR-n2: 従来の空白区切り allowlist も引き続き効く（後方互換）" {
  printf 'a.txt %s PR#999 で意図的に戻した\n' "${BLOB_V1:0:7}" > "$FX/allow-sp.txt"
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --allowlist "$FX/allow-sp.txt"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
}

# ---------- ERRATA-3 minor n3 / n6 / n7: 実装済み guard に teeth を付ける ----------

@test "MINOR-n3: pre-merge の委譲先解決に必要な外部コマンド不在は rc=2（cwd へ無言 degrade しない）" {
  # readlink / dirname が無いと $(...) が空になり `cd "" && pwd` が cwd を返す＝cwd 相対の同名
  # script を掴みうる。fail-closed で落ちることを要求する。
  local stub c p
  stub="$(cd "$(mktemp -d)" && pwd -P)"
  for c in bash sh git awk comm sort mktemp tr sed head cat env printf wc chmod rm; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$stub/$c"
  done
  run env PATH="$stub" "$SCAN" --repo "$FX" --mode pre-merge --branch feat-clobber --base-ref origin/main
  rm -rf "$stub"
  [ "$status" -eq 2 ]
  grep -q '委譲先の解決に必要な外部コマンドがありません' <<< "$output"
}

@test "MINOR-n6: replace ref が在る repo は両 leg とも harness-fail(2)" {
  # 実装済み guard に teeth が 0 本だった面。replace ref は object graph を差し替えるため走査結果が
  # 黙って変わる（本リポの実測は 0 件）。
  local r c1 c2
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    '+a.txt=v1')"
  c2="$(xcommit "$r" refs/heads/main "$c1" '+a.txt=v2')"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  git -C "$r" replace -f "$c2" "$c1"
  run "$SCAN" --repo "$r" --range "$c1..$c2"
  [ "$status" -eq 2 ]
  grep -q 'replace ref' <<< "$output"
  run "$FRESH" --repo "$r" --branch main --base-ref "$c1"
  rm -rf "$r"
  [ "$status" -eq 2 ]
  grep -q 'replace ref' <<< "$output"
}

@test "MINOR-n6: 不正な --expect-restore（blob が hex でない / = 無し）は両 leg とも rc=2" {
  # ★leg B 側は **本来 rc=1 になる branch**（clobber 済み）を渡す。0 file の branch を渡すと
  #   「走査対象 file が 0 件」の別理由で rc=2 になり teeth が空虚になる（宣言 guard は BR_N 検査の後）。
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --expect-restore 'a.txt=notahexvalue!'
  [ "$status" -eq 2 ]
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --expect-restore 'a.txt-no-equals'
  [ "$status" -eq 2 ]
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main --expect-restore 'a.txt=zz'
  [ "$status" -eq 2 ]
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main --expect-restore 'a.txt-no-equals'
  [ "$status" -eq 2 ]
  # guard あり時に本来 rc=1 になる引数であること（別理由の 2 で空虚にしない）
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
}

@test "MINOR-n6: 不在の --allowlist file は両 leg とも rc=2（空 allowlist として素通ししない）" {
  # ★leg B 側は本来 rc=1 になる branch を渡す（上と同じ理由）。
  local br
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  run "$SCAN" --repo "$FX" --range "$C2..$C3" --allowlist "$FX/no-such-allowlist.txt"
  [ "$status" -eq 2 ]
  grep -q 'allowlist' <<< "$output"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main --allowlist "$FX/no-such-allowlist.txt"
  [ "$status" -eq 2 ]
  grep -q 'allowlist' <<< "$output"
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
}

@test "MINOR-n6: unset 対象の git 環境変数すべてが結果を汚さない（GIT_DIR 以外も含む）" {
  # FIX-3 teeth は GIT_DIR / GIT_WORK_TREE だけを見ていた。残りの 5 個も同時に汚して、
  # 正規の --repo に対する結果が不変であることを要求する。
  local other
  other="$(new_repo)"
  xcommit "$other" refs/heads/main "" '+zzz.txt=z' > /dev/null
  run env GIT_DIR="$other/.git" GIT_WORK_TREE="$other" GIT_INDEX_FILE="$other/.idxpollute" \
      GIT_OBJECT_DIRECTORY="$other/.git/objects" \
      GIT_ALTERNATE_OBJECT_DIRECTORIES="$other/.git/objects" \
      GIT_COMMON_DIR="$other/.git" GIT_NAMESPACE=pollute \
      "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
  grep -q "clobber-suspect: path=a.txt" <<< "$output"
  fx_commit_on feat-fresh "$C4" e.txt 'e' > /dev/null   # 0 file だと別理由の rc=2 になる
  run env GIT_DIR="$other/.git" GIT_WORK_TREE="$other" GIT_NAMESPACE=pollute \
      "$FRESH" --repo "$FX" --branch feat-fresh --base-ref origin/main --rc-leg b
  rm -rf "$other"
  [ "$status" -eq 0 ]
  grep -q 'is-ancestor=fresh' <<< "$output"
}

@test "MINOR-n7: --mode pre-merge の宣言は生 path 側の規約（usage の記載と一致する）" {
  # 同じ script・同じフラグでもモードで宣言表記が変わる（pre-merge は base-freshness へ exec 委譲）。
  local r c1 c2 tp blob
  tp=$'q\tb.txt'
  r="$(new_repo)"
  c1="$(xcommit "$r" refs/heads/main ""    "+$tp=v1" '+plain.txt=p')"
  c2="$(xcommit "$r" refs/heads/main "$c1" "+$tp=v2")"
  git -C "$r" update-ref refs/remotes/origin/main "$c2"
  xcommit "$r" refs/heads/feat "$c2" "+$tp=v1" > /dev/null
  # pre-merge は生 path で効く
  run "$SCAN" --repo "$r" --mode pre-merge --branch feat --base-ref origin/main \
        --expect-restore "$tp=$(git -C "$r" rev-parse "$c1:$tp" | cut -c1-7)"
  [ "$status" -eq 0 ]
  grep -q 'declared-restore=1' <<< "$output"
  # C-quote 形では効かない（post-merge 側の規約）
  run "$SCAN" --repo "$r" --mode pre-merge --branch feat --base-ref origin/main \
        --expect-restore "\"q\\tb.txt\"=$(git -C "$r" rev-parse "$c1:$tp" | cut -c1-7)"
  rm -rf "$r"
  [ "$status" -eq 1 ]
  # usage（--help の実出力）にモード別の表記規約が書かれていること
  run "$SCAN" --help
  [ "$status" -eq 0 ]
  grep -q 'mode post-merge（既定） … \*\*C-quote 形\*\*' <<< "$output"
  grep -q 'mode pre-merge          … \*\*生 path\*\*' <<< "$output"
}

# ---------- ERRATA-4 FIX-B: EXIT trap の cleanup が判定 rc を上書きしない ----------

@test "FIX-B legA: rm が失敗しても clean は rc=0 / 検知は rc=1 / harness-fail は rc=2 のまま" {
  # 機構: `set -e` 下では EXIT trap の最終コマンドの非 0 で **判定 rc が上書きされる**。
  # 実測（修正前）: rm を exit 1 shim にすると clean(0) も harness-fail(2) も rc=1（偽検知）。
  local shim
  shim="$(cd "$(mktemp -d)" && pwd -P)"
  printf '#!/bin/sh\nexit 1\n' > "$shim/rm"
  chmod +x "$shim/rm"
  # まず guard あり（正規 PATH）での本来 rc を pin する（別理由で一致して空虚になるのを防ぐ）。
  run "$SCAN" --repo "$FX" --range "$C1..$C2"
  [ "$status" -eq 0 ]
  run "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 1 ]
  run "$SCAN" --repo "$FX" --range "$C4..$C4"
  [ "$status" -eq 2 ]
  # rm を壊しても 3 つの rc が変わらないこと
  run env PATH="$shim:$PATH" "$SCAN" --repo "$FX" --range "$C1..$C2"
  [ "$status" -eq 0 ]
  run env PATH="$shim:$PATH" "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 1 ]
  run env PATH="$shim:$PATH" "$SCAN" --repo "$FX" --range "$C4..$C4"
  rm -rf "$shim"
  [ "$status" -eq 2 ]
}

@test "FIX-B legA: rm が exit 3 でも判定 rc が 3 へ漏れない" {
  local shim
  shim="$(cd "$(mktemp -d)" && pwd -P)"
  printf '#!/bin/sh\nexit 3\n' > "$shim/rm"
  chmod +x "$shim/rm"
  run env PATH="$shim:$PATH" "$SCAN" --repo "$FX" --range "$C2..$C3"
  rm -rf "$shim"
  [ "$status" -eq 1 ]
  grep -q 'clobber-suspect=1' <<< "$output"
}

@test "FIX-B legB: rm が失敗しても clean は rc=0 / 検知は rc=1 / harness-fail は rc=2 のまま" {
  local br shim
  br="$(fx_commit_on feat-clobber "$C4" a.txt 'v2
')"
  fx_commit_on feat-clean "$C4" newfile.txt 'fresh content' > /dev/null
  shim="$(cd "$(mktemp -d)" && pwd -P)"
  printf '#!/bin/sh\nexit 1\n' > "$shim/rm"
  chmod +x "$shim/rm"
  run "$FRESH" --repo "$FX" --branch feat-clean --base-ref origin/main
  [ "$status" -eq 0 ]
  run "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  run "$FRESH" --repo "$FX" --branch no-such-branch --base-ref origin/main
  [ "$status" -eq 2 ]
  run env PATH="$shim:$PATH" "$FRESH" --repo "$FX" --branch feat-clean --base-ref origin/main
  [ "$status" -eq 0 ]
  run env PATH="$shim:$PATH" "$FRESH" --repo "$FX" --branch feat-clobber --base-ref origin/main
  [ "$status" -eq 1 ]
  run env PATH="$shim:$PATH" "$FRESH" --repo "$FX" --branch no-such-branch --base-ref origin/main
  rm -rf "$shim"
  [ "$status" -eq 2 ]
}

@test "FIX-B: rm 抜き stub PATH は両 leg とも rc=2（rc=127 を漏らさない）" {
  local stub c p
  stub="$(cd "$(mktemp -d)" && pwd -P)"
  for c in bash sh git awk comm sort mktemp tr sed head cat env printf readlink dirname wc; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$stub/$c"
  done
  run env PATH="$stub" "$SCAN" --repo "$FX" --range "$C2..$C3"
  [ "$status" -eq 2 ]
  grep -q '外部コマンドが見つかりません: rm' <<< "$output"
  run env PATH="$stub" "$FRESH" --repo "$FX" --branch feat-fresh --base-ref origin/main
  rm -rf "$stub"
  [ "$status" -eq 2 ]
  grep -q '外部コマンドが見つかりません: rm' <<< "$output"
}

@test "FIX-B: --help は外部 cat 不在でも rc=0 で usage 本文を出す" {
  # 実測（修正前）: cat 抜き PATH で -h が rc=127・usage 本文が出なかった（usage は引数解析中に
  # 走るため依存 probe より前＝probe へ cat を足しても救えない）。builtin 出力へ変えて解消する。
  local stub c p
  stub="$(cd "$(mktemp -d)" && pwd -P)"
  for c in bash sh git awk comm sort mktemp tr sed head env printf readlink dirname wc rm; do
    p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$stub/$c"
  done
  run env PATH="$stub" "$SCAN" --help
  [ "$status" -eq 0 ]
  grep -q '^Usage:' <<< "$output"
  grep -q 'Exit: 0=clean' <<< "$output"
  run env PATH="$stub" "$FRESH" --help
  rm -rf "$stub"
  [ "$status" -eq 0 ]
  grep -q '^Usage:' <<< "$output"
}

@test "実データ legA: 本リポ走査でも HEAD と working tree を変更しない" {
  real_commit_or_skip 0c7ce5c 9a319ac
  local head_before head_after st_before st_after
  head_before="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  st_before="$(git -C "$REPO_ROOT" status --porcelain)"
  run "$SCAN" --repo "$REPO_ROOT" --range 0c7ce5c..9a319ac
  [ "$status" -eq 1 ]
  head_after="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  st_after="$(git -C "$REPO_ROOT" status --porcelain)"
  [ "$head_before" = "$head_after" ]
  [ "$st_before" = "$st_after" ]
}

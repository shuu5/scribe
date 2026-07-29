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

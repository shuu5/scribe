#!/usr/bin/env bash
# scribe-base-freshness.sh — merge 前の base 鮮度 / content clobber の機械確認（bd sc-efoa leg B / B-2）。
#
# 実運用点: **anchor の merge 直前**（gate funnel で PR を main へ merge する直前）に、対象 branch を
# 引数に取って回す。branch を切ってから base が進んだ結果、squash 適用で base 側の変更が消える形
# （＝実際に踏んだ事故の形）を merge 前に止めるための検査。
#
# 3 つの情報を出す。**rc を決めるのは leg B-2 の 1 本だけ**（判断材料は全部出すが rc は多重化しない）:
#
#   leg B   （advisory）: `git merge-base --is-ancestor <base-ref> <branch>`
#                         base-ref が branch の祖先か＝「そもそも遅れていない」ことを示す強い条件。
#   comm 交差（advisory）: 「branch が触った file」と「branch を切ってから base が触った file」の交差。
#                         交差が無ければ「遅れているが重なりが無いので安全」を示す弱い条件。
#   leg B-2 （rc を決める）: **content 条件**。branch の各 file の blob が、その path について base の
#                         **過去** blob と一致し、かつ base の**現行** blob と不一致なら RED。
#                         ＝branch が base の現行内容を過去の内容へ巻き戻している（clobber）。
#                         base に現行 blob が無い path（＝base が削除した path）も対象に含める。
#                         base 側の削除を branch が過去 blob で打ち消す形も同じ clobber であり、
#                         「現行が無い＝新規追加だから安全」とは言えない。
#
# 実測（本検査の射程を誤読させないため）: 「branch を base へ reset してから stale な working tree を
# 再 commit した」形の事故では、merge 時点の tip に対して leg B（is-ancestor）も comm 交差も **green**
# になる。捕捉責任は leg B-2 側にある。leg B は「真に遅れた base」という別 class を塞ぐ安価な検査。
#
# 3 分類（区分は leg A と同じ。意図的復元は rc に載せない）:
#   clobber-suspect / declared-restore / clean。宣言経路は `--expect-restore <path>=<blob>`（主）と
#   `--allowlist <file>`（補）の 2 つのみ。
#   **宣言 path の表記は 2 leg で異なる**（対称ではない — 誤読すると宣言が黙って効かない）:
#     本 script（leg B / B-2）… **生 path**（シェルがそのまま渡す形。例 $'q\tb.txt'）
#     leg A（blob-revive-scan）… `git log --raw` 由来の **C-quote 形**（例 "q\tb.txt"）
#   通常 path（control char・`"`・`\` を含まない）では両者は一致するので実運用の差は出ない。
#   quote が要る path を宣言するときは、その leg の出力行に出ている path 表記をそのまま写すこと。
#
# rc 契約（standalone。scribe-gate-attest.sh probe の exit には載せない）:
#   0 = clean / 1 = 検知 / 2 = harness-fail（引数不備 / 非 git dir / ref・範囲の解決不能 /
#   走査対象 0 file / 外部コマンド不在）。
#   `git merge-base --is-ancestor` は 0 / 1 のほか 128・129 を返す（実測: 不正 ref で 128・引数欠落で
#   129）。**1 以外の非 0 は必ず 2 へ写像**し、1 だけを検知にする（usage error を「検知」に倒さない）。
#   0 件でも集計行を必ず stdout へ出す（沈黙を green と読ませない）。
#
# --rc-leg: rc を決める leg を選ぶ（既定 b2）。b2 = content 条件 / b = is-ancestor。
#   どちらの場合も他方は advisory として出力へ併記する（OR で多重化はしない）。
#
# 規律:
#   - git の read のみ。worktree と HEAD を変更しない。
#   - `git fetch` / `git remote update` / `git pull` を実行しない（共有 remote-tracking ref を書き換えると
#     anchor と他 cell の base 判定が動く）。基準 ref が古いままかどうかは呼び出し側の責任。
#   - 基準 ref は `--base-ref`（既定 origin/main）で受け、**使った ref 名と解決 sha を出力へ必ず刻む**
#     （local main と origin/main は同値でない — 実測で 4 commit 差がありうる）。
#   - 鮮度が判定できない場合は clean(0) でなく harness-fail(2) へ倒す。
#
# テスト: tests/blob-revive-guard.bats
set -euo pipefail

# 継承した git 環境変数を落とす（**引数解析より前**）。これらが export されていると `git -C <PATH>` が
# PATH でなく環境変数側の repo を解決し、走査していない repo の結果を --repo の名前で報告しうる。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_COMMON_DIR GIT_NAMESPACE

PROG="base-freshness"
# 中間表現（cand / hit）の field 区切り。path は TAB を含みうるので TAB を区切りに使わない。
US=$'\037'

die2() { printf '%s: harness-fail: %s\n' "$PROG" "$*" >&2; exit 2; }
need_val() { [[ -n "${1:-}" && "$1" != -* ]] || die2 "$2 に値を指定してください（値の欠落・次フラグの誤消費を防止）"; }

usage() {
  cat <<'EOF'
Usage:
  scribe-base-freshness.sh --branch <BR> [--base-ref <REF>] [--repo PATH] [--rc-leg b2|b] [宣言オプション]
      merge 直前に回す。<REF> の既定は origin/main（fetch はしない＝呼び出し側の責任）。
  宣言オプション:
      --expect-restore <path>=<blob>   意図的復元の宣言（主・複数指定可・blob は 4 桁以上の前方一致）
      --allowlist <file>               意図的復元の allowlist（補・1 行 `<path> <blob> <根拠>`・# コメント可）
      ※ path は **生 path**（本 script の出力行に出る表記）。leg A（blob-revive-scan）は C-quote 形を
         使うため、quote が要る path では 2 leg で表記が異なる。出力の path 表記をそのまま写すこと。
  scribe-base-freshness.sh -h | --help

Exit: 0=clean / 1=検知 / 2=harness-fail
EOF
  exit "${1:-0}"
}

REPO="."
BRANCH=""
BASE_REF="origin/main"
RC_LEG="b2"
ALLOWLIST=""
DECL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        usage 0 ;;
    --repo)           need_val "${2:-}" --repo; REPO="$2"; shift 2 ;;
    --branch)         need_val "${2:-}" --branch; BRANCH="$2"; shift 2 ;;
    --base-ref)       need_val "${2:-}" --base-ref; BASE_REF="$2"; shift 2 ;;
    --rc-leg)         need_val "${2:-}" --rc-leg; RC_LEG="$2"; shift 2 ;;
    --allowlist)      need_val "${2:-}" --allowlist; ALLOWLIST="$2"; shift 2 ;;
    --expect-restore) need_val "${2:-}" --expect-restore; DECL_ARGS+=("$2"); shift 2 ;;
    -*)               die2 "不明なオプション: '$1'（--help を参照）" ;;
    *)                die2 "余分な引数: '$1'（対象は --branch / --base-ref で指定する）" ;;
  esac
done

for c in git awk comm sort mktemp; do
  command -v "$c" >/dev/null 2>&1 || die2 "外部コマンドが見つかりません: $c"
done

[[ -n "$BRANCH" ]] || die2 "--branch <BR> が必要です"
case "$RC_LEG" in b2|b) ;; *) die2 "不明な --rc-leg: '$RC_LEG'（b2 / b）" ;; esac
[[ -d "$REPO" ]] || die2 "--repo が存在しません: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die2 "git リポジトリではありません: $REPO"

# 履歴が完全でない repo では「base の過去 blob か」を原理的に答えられない。判定できないので
# clean(0) でなく harness-fail(2) へ倒す。
SHALLOW="$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || true)"
[[ "$SHALLOW" == "false" ]] \
  || die2 "履歴が完全ではありません（is-shallow-repository=${SHALLOW:-unknown}）: $REPO"
# replace ref は object graph を差し替えるため、照合結果が黙って変わる。
REPLACE_N="$({ git -C "$REPO" replace -l 2>/dev/null || true; } | wc -l)"; REPLACE_N=${REPLACE_N// /}
[[ "$REPLACE_N" -eq 0 ]] \
  || die2 "replace ref が $REPLACE_N 件あります（object graph が差し替わり照合結果が変わる）: $REPO"

resolve_commit() { # <rev> <label>
  local out
  out="$(git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null)" || true
  [[ -n "$out" ]] || die2 "$2 を解決できません: '$1'（fetch はしない — 呼び出し側で用意すること）"
  printf '%s' "$out"
}
BR_SHA="$(resolve_commit "$BRANCH" "--branch")"
BASE_SHA="$(resolve_commit "$BASE_REF" "--base-ref")"

# merge-base は変数に取り、非空かつ rev-parse --verify を通ることを検査してから使う
# （空 ref のまま git diff へ渡すと HEAD 解釈で 0 file・rc=0 の偽 green になる。実測）。
MB_RAW="$(git -C "$REPO" merge-base "$BASE_SHA" "$BR_SHA" 2>/dev/null)" || MB_RAW=""
[[ -n "$MB_RAW" ]] || die2 "merge-base を解決できません（無関係な履歴？）: $BASE_REF vs $BRANCH"
MB="$(resolve_commit "$MB_RAW" "merge-base")"

# --- leg B（advisory）: base-ref が branch の祖先か ---
# rc 0=fresh / 1=stale / それ以外（128・129 等）は harness-fail(2) へ写像する。
IS_ANC_RC=0
git -C "$REPO" merge-base --is-ancestor "$BASE_SHA" "$BR_SHA" || IS_ANC_RC=$?
case "$IS_ANC_RC" in
  0) IS_ANC="fresh" ;;
  1) IS_ANC="stale" ;;
  *) die2 "merge-base --is-ancestor が想定外の rc=$IS_ANC_RC を返しました（1 以外の非 0 は検知に倒さない）" ;;
esac

TMPD="$(mktemp -d)" || die2 "mktemp -d に失敗しました"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

# --- branch が触った file / base が触った file ---
# path を 2 形式で取る（**同一コマンドの同一順序**なので位置で対応が取れる）:
#   br.z … `-z` の生 path。`rev-parse <sha>:<path>` と出力・宣言照合に使う。
#   br.q … 行表現（C-quote 込み）。`git log --raw` 側の path 表現と同じなので履歴照合の key に使う。
# 生 path だけだと C-quote が要る path（TAB・"・改行等）が履歴側の表現と一致せず無言で落ち、
# 行表現だけだと `rev-parse <sha>:"q\tb.txt"` が解決できず無言で落ちる（実測）。両方持って解消する。
git -C "$REPO" diff --name-only -z --no-renames "$MB" "$BR_SHA" > "$TMPD/br.z" \
  || die2 "branch 側の diff（-z）に失敗しました"
git -C "$REPO" -c core.quotePath=false diff --name-only --no-renames "$MB" "$BR_SHA" > "$TMPD/br.q" \
  || die2 "branch 側の diff（行表現）に失敗しました"
git -C "$REPO" -c core.quotePath=false diff --name-only --no-renames "$MB" "$BASE_SHA" \
  | sort > "$TMPD/base.txt" || die2 "base 側の diff に失敗しました"

# 実 path 数 = NUL の個数。2 形式の件数が食い違えば位置対応が崩れている＝判定できないので落とす。
# ここから下の外部コマンドは **rc を捕まえて 2 へ写像する**。素の実行だと `set -e` が script を
# rc=1 で殺し、harness 失敗が「検知」へ化ける（集計行も出ない silent RED になる）。
if ! BR_N="$(tr -dc '\0' < "$TMPD/br.z" | wc -c)"; then
  die2 "branch 側 path 一覧（-z）の計数に失敗しました"
fi
BR_N=${BR_N// /}
if ! BR_Q_N="$(wc -l < "$TMPD/br.q")"; then
  die2 "branch 側 path 一覧（行表現）の計数に失敗しました"
fi
BR_Q_N=${BR_Q_N// /}
[[ "$BR_N" -eq "$BR_Q_N" ]] \
  || die2 "path 一覧の 2 形式で件数が一致しません（-z=$BR_N / 行表現=$BR_Q_N）＝位置対応が取れません"
[[ "$BR_N" -gt 0 ]] || die2 "走査対象 file が 0 件です（branch が merge-base から何も変更していない）: $BRANCH"

sort "$TMPD/br.q" > "$TMPD/br.txt" || die2 "branch 側 path 一覧の sort に失敗しました"

# --- comm 交差（advisory）: comm の rc を判定には使わない（交差の有無は行数で見る）が、
# comm 自体の失敗は harness 失敗ゆえ 2 へ写像する（rc=1 の「検知」に化けさせない） ---
comm -12 "$TMPD/br.txt" "$TMPD/base.txt" > "$TMPD/overlap.txt" \
  || die2 "comm による交差算出に失敗しました"
if ! OVERLAP_N="$(wc -l < "$TMPD/overlap.txt")"; then
  die2 "交差 file の計数に失敗しました"
fi
OVERLAP_N=${OVERLAP_N// /}

# --- leg B-2（rc を決める content 条件） ---
# base 側の履歴 raw を 1 回の log で取る（pathspec は使わない — path 列を単語分割で渡すと空白入り path で
# 壊れ、file 数が増えると引数長にも当たる。照合は awk 側で path 完全一致で行う）。
# `-m --first-parent` で merge も first-parent diff を raw 行として出す（無音 skip 0）。
git -C "$REPO" -c core.quotePath=false log --first-parent -m --raw --no-renames --root --no-abbrev \
  --format='__C__ %H' "$BASE_SHA" > "$TMPD/hist.txt" 2>"$TMPD/err.txt" \
  || die2 "base 側履歴の走査に失敗しました: $(head -1 "$TMPD/err.txt")"

# 宣言（declared-restore）
declare -A DECL=()
add_decl() { # <path>=<blob> <出所>
  local spec="$1" src="$2" p b
  [[ "$spec" == *=* ]] || die2 "$src の形式が不正です（<path>=<blob> が必要）: '$spec'"
  p="${spec%%=*}"; b="${spec#*=}"
  [[ -n "$p" ]] || die2 "$src の path が空です: '$spec'"
  [[ "$b" =~ ^[0-9a-fA-F]{4,40}$ ]] || die2 "$src の blob が不正です（16 進 4-40 桁）: '$spec'"
  DECL["$p"]="${DECL[$p]:-} ${b,,}"
}
for d in ${DECL_ARGS[@]+"${DECL_ARGS[@]}"}; do add_decl "$d" "--expect-restore"; done
if [[ -n "$ALLOWLIST" ]]; then
  [[ -f "$ALLOWLIST" ]] || die2 "--allowlist の file が読めません: $ALLOWLIST"
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%%#*}"
    [[ -n "${line// /}" ]] || continue
    read -r a_path a_blob a_rest <<< "$line"
    [[ -n "$a_path" && -n "$a_blob" && -n "$a_rest" ]] \
      || die2 "--allowlist の $lineno 行目が不正です（'<path> <blob> <根拠>' が必要）: $ALLOWLIST"
    add_decl "$a_path=$a_blob" "--allowlist の $lineno 行目"
  done < "$ALLOWLIST"
fi
is_declared() { # <path> <blob-full>
  local p="$1" blob="${2,,}" b
  # 空 path は連想配列の subscript にできず abort する。field 破損を緑にも検知にも倒さない。
  [[ -n "$p" ]] || die2 "内部エラー: 空の path で宣言照合が呼ばれました（中間表現の field 破損）"
  [[ -n "${DECL[$p]:-}" ]] || return 1
  for b in ${DECL[$p]}; do
    [[ "$blob" == "$b"* ]] && return 0
  done
  return 1
}

short() { printf '%s' "${1:0:7}"; }

SUSPECT=0; DECLARED=0
SUSPECT_LINES=(); DECLARED_LINES=()

# 候補（branch が触った file のうち base の現行 blob と異なるもの）を先に確定させる。
mapfile -t QPATHS < "$TMPD/br.q"
QUOTED_N=0
BR_DELETED_N=0
qi=0
: > "$TMPD/cand.txt"
while IFS= read -r -d '' path; do
  qpath="${QPATHS[$qi]:-}"
  qi=$((qi + 1))
  [[ -n "$path" && -n "$qpath" ]] || die2 "path の 2 形式が対応しません（$qi 件目）: '$path' / '$qpath'"
  # cand.txt の第 2 field には `-z` 由来の**生 path** を載せる。git は control char を -z 出力では
  # quote しないため、path 自身が cand.txt の field 区切り（US）や record 区切り（LF）を含むと
  # 行・field が右シフトし、awk 側の want[qpath] に blob でなく path の断片が入る → hit が出ず
  # **無言で clobber-suspect=0 / rc=0** になる（実測: leg A は同じ clobber を rc=1 で検知するのに
  # leg B-2 だけ fail-open）。中間表現の field 対応が取れない以上「巻き戻しが無い」とは言えないので、
  # 緑にも検知にも倒さず harness-fail(2) で落とす（FIX-1 の空 path ガードと同じ fail-closed 方針）。
  case "$path" in
    *"$US"*)  die2 "path が中間表現の field 区切り US(0x1f) を含むため field 対応が取れません: $qpath" ;;
    *$'\n'*)  die2 "path が中間表現の record 区切り LF を含むため field 対応が取れません: $qpath" ;;
  esac
  [[ "$qpath" == "$path" ]] || QUOTED_N=$((QUOTED_N + 1))
  # branch 側 blob。branch が削除した path は本検査（content 巻き戻し）の対象外だが、**件数を集計行へ
  # 出す**（branch が base の file を消す形の clobber は射程外＝痕跡を残さないと「見た上で 0 件」と
  # 「そもそも見ていない」が区別できない。rc は多重化しないので advisory 件数のみ）。
  br_blob="$(git -C "$REPO" rev-parse --verify --quiet "$BR_SHA:$path" 2>/dev/null)" || br_blob=""
  if [[ -z "$br_blob" ]]; then
    BR_DELETED_N=$((BR_DELETED_N + 1))
    continue
  fi
  # base 側の現行 blob。**base に path が無い場合も候補に載せる**（base が削除した path を branch が
  # 過去 blob で復活させる形＝base 側の削除が消える clobber。現行 blob が無いことは「新規追加だから
  # 安全」を意味しない）。照合は base 履歴中の過去 blob（want[p]）のみで行う。
  base_cur="$(git -C "$REPO" rev-parse --verify --quiet "$BASE_SHA:$path" 2>/dev/null)" || base_cur=""
  # 現行と一致していれば巻き戻しではない（base_cur 空なら一致しようがない）
  [[ -z "$base_cur" || "$br_blob" != "$base_cur" ]] || continue
  printf '%s%s%s%s%s%s%s\n' "$qpath" "$US" "$path" "$US" "$br_blob" "$US" "${base_cur:-absent}" \
    >> "$TMPD/cand.txt"
done < "$TMPD/br.z"

# base の**過去** blob に br_blob が居るかを 1 回の awk で照合する（path ごとに log/awk を回さない）。
: > "$TMPD/hit.txt"
if [[ -s "$TMPD/cand.txt" ]]; then
  # cand の field: 1=履歴照合 key（行表現）/ 2=生 path（表示・宣言照合）/ 3=branch blob / 4=base 現行 blob
  awk -v FS="$US" -v US="$US" '
    FNR==NR { want[$1]=$3; cur[$1]=$4; raw[$1]=$2; next }
    /^__C__ / { split($0, a, " "); csha = a[2]; next }
    /^:/ {
      t = index($0, "\t"); if (t == 0) next
      meta = substr($0, 1, t-1); p = substr($0, t+1)
      if (!(p in want) || (p in hit)) next
      split(meta, m, " ")
      # m[4]=dst blob。base 履歴のどこかで当該 path がこの blob を持っていた＝過去 blob への巻き戻し。
      # 照合は want[p] のみで行う（base の現行 blob が無い＝base が削除した path も候補に含まれる）。
      if (m[4] == want[p]) hit[p] = csha
    }
    END { for (p in hit) print raw[p] US want[p] US cur[p] US hit[p] }
  ' "$TMPD/cand.txt" "$TMPD/hist.txt" | sort > "$TMPD/hit.txt" || die2 "base 履歴の照合（awk）に失敗しました"
fi

while IFS="$US" read -r path br_blob base_cur prior_commit; do
  [[ -n "$path" ]] || continue
  if is_declared "$path" "$br_blob"; then
    DECLARED=$((DECLARED + 1))
    DECLARED_LINES+=("declared-restore: path=$path br-blob=$(short "$br_blob") base-cur-blob=$(short "$base_cur") prior-commit=$(short "$prior_commit")")
  else
    SUSPECT=$((SUSPECT + 1))
    SUSPECT_LINES+=("clobber-suspect: path=$path br-blob=$(short "$br_blob") base-cur-blob=$(short "$base_cur") prior-commit=$(short "$prior_commit")")
  fi
done < "$TMPD/hit.txt"

printf '%s: repo=%s branch=%s@%s base-ref=%s@%s merge-base=%s is-ancestor=%s overlap-files=%s br-touched-files=%s quoted-paths=%s br-deleted-paths=%s clobber-suspect=%s declared-restore=%s rc-leg=%s\n' \
  "$PROG" "$REPO" "$BRANCH" "$(short "$BR_SHA")" "$BASE_REF" "$(short "$BASE_SHA")" "$(short "$MB")" \
  "$IS_ANC" "$OVERLAP_N" "$BR_N" "$QUOTED_N" "$BR_DELETED_N" "$SUSPECT" "$DECLARED" "$RC_LEG"

while IFS= read -r p; do [[ -z "$p" ]] || printf 'overlap: path=%s\n' "$p"; done < "$TMPD/overlap.txt"
[[ ${#SUSPECT_LINES[@]}  -eq 0 ]] || printf '%s\n' "${SUSPECT_LINES[@]}"
[[ ${#DECLARED_LINES[@]} -eq 0 ]] || printf '%s\n' "${DECLARED_LINES[@]}"

# rc は 1 本の leg だけが決める（OR で多重化しない）。他方は上の集計行に advisory として出ている。
if [[ "$RC_LEG" == "b" ]]; then
  if [[ "$IS_ANC" == "stale" ]]; then exit 1; fi
  exit 0
fi
if [[ "$SUSPECT" -gt 0 ]]; then exit 1; fi
exit 0

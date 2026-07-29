#!/usr/bin/env bash
# scribe-blob-revive-scan.sh — 過去 blob 復活（stale-base clobber）の機械検知（bd sc-efoa leg A）。
#
# 塞ぐ穴（実測済みインシデント）:
#   branch を base へ reset した後に stale な working tree を丸ごと再 commit すると、branch が
#   能動的に編集していない file が **過去の blob へ byte 同一で巻き戻る**。teeth ごと消えるため
#   silent に成立し、diff レビューでも「その file は触っていない」ようにしか見えない。
#
# 判定核（range 内の blob 系列を見るのは空虚 — squash merge は 1 commit ゆえ range 内に revert
# 系列が存在しない。実測）:
#   **range で導入された各 blob が、その path について「その commit より前の first-parent 履歴」に
#   既出であり、かつ直前値と異なる** ものを復活 event とする（prior-occurrence 照合）。
#   走査は range 外（base 側）の履歴まで遡って seen 集合を構築するので、range だけを見る実装と違い
#   「range base より前に land した blob への巻き戻し」を捕捉できる。
#
# 3 分類（意図的復元と事故を弁別する — 実測: 意図的な再 land でも復活は hit する）:
#   clobber-suspect  復活かつ復元宣言なし  → **rc=1 を決めるのはこれだけ**
#   declared-restore 復活だが宣言あり      → 件数のみ報告（rc に載せない）
#   clean            復活なし
#   宣言経路は 2 つのみ: (c) 呼出しフラグ `--expect-restore <path>=<blob>`（主）/
#   (b) allowlist データ file `--allowlist <file>`（補・`<path> <blob> <根拠1行>`）。
#   commit message / PR 本文のトレーラ宣言方式は**採らない**（本リポは squash merge 運用で message を
#   書くのは merge 時の admin であり、新しい運用規約の成文化を要するため）。
#
# rc 契約（本 script の standalone 契約。scribe-gate-attest.sh probe の exit には載せない）:
#   0 = clean（走査した上で clobber-suspect 0 件）
#   1 = 検知（clobber-suspect ≥ 1 件）
#   2 = harness-fail（引数不備 / 非 git dir / ref・範囲の解決不能 / 走査対象 0 / 外部コマンド不在）
#   harness-fail を緑にも検知にも倒さない。0 件でも集計行を必ず stdout へ出す（沈黙を green と読ませない）。
#
# 2 モード:
#   --mode post-merge（既定） main 等の first-parent 履歴を **sha で pin した range** で走査（結果側の検知）。
#   --mode pre-merge          merge 前の予測。判定は leg B-2（content 条件）と同一のため、実装は
#                             同ディレクトリの scribe-base-freshness.sh へ委譲する（二重実装しない）。
#
# 規律:
#   - git の **read のみ**。worktree と HEAD を変更しない（branch / tag / checkout / commit / reset をしない）。
#   - `git fetch` / `git remote update` / `git pull` を実行しない（共有 remote-tracking ref を書き換えると
#     anchor と他 cell の base 判定が動く）。
#   - 走査対象 repo と range は**引数で受ける**（自 repo 決め打ちにしない＝使い捨て repo で変異注入できる）。
#   - 出力は件数 + file 名を基本とし、内訳説明に要る短縮 sha（7 桁）のみ添える（全 blob の総覧は出さない）。
#   - merge commit は無音 skip しない（`--first-parent -m` で first-parent diff を走査し、range 内の
#     merge 件数と skip 件数を集計行へ必ず出す）。
#
# テスト: tests/blob-revive-guard.bats
set -euo pipefail

# 継承した git 環境変数を落とす（**引数解析より前**）。これらが export されていると `git -C <PATH>` が
# PATH でなく環境変数側の repo を解決し、走査していない repo の結果を --repo の名前で報告しうる。
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_COMMON_DIR GIT_NAMESPACE

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROG="blob-revive-scan"
# EVENT / STATS 行の field 区切り。TAB は IFS-whitespace ゆえ連続区切りが 1 個に畳まれ、空 field
# （prev 無し＝delete 後の再追加）で field が左シフトする。US(0x1f) は非 whitespace なので畳まれない。
US=$'\037'

# harness-fail 専用経路（lib の scribe_die は exit 1 固定ゆえ使わない — 1 は「検知」に予約されている）。
die2() { printf '%s: harness-fail: %s\n' "$PROG" "$*" >&2; exit 2; }
need_val() { [[ -n "${1:-}" && "$1" != -* ]] || die2 "$2 に値を指定してください（値の欠落・次フラグの誤消費を防止）"; }

usage() {
  cat <<'EOF'
Usage:
  scribe-blob-revive-scan.sh --range <base>..<tip> [--repo PATH] [宣言オプション]
      post-merge 検知（既定）。range は **sha で pin** すること（HEAD 相対は cell ごとに再現しない）。
  scribe-blob-revive-scan.sh --mode pre-merge --branch <BR> [--base-ref <REF>] [--repo PATH] [宣言オプション]
      pre-merge 予測。scribe-base-freshness.sh（leg B-2）へ委譲する。
  宣言オプション:
      --expect-restore <path>=<blob>   意図的復元の宣言（主・複数指定可・blob は 4 桁以上の前方一致）
      --allowlist <file>               意図的復元の allowlist（補・1 行 `<path> <blob> <根拠>`・# コメント可）
  scribe-blob-revive-scan.sh -h | --help

Exit: 0=clean / 1=clobber-suspect 検知 / 2=harness-fail
EOF
  exit "${1:-0}"
}

REPO="."
RANGE=""
MODE="post-merge"
BRANCH=""
BASE_REF=""
ALLOWLIST=""
DECL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)        usage 0 ;;
    --repo)           need_val "${2:-}" --repo; REPO="$2"; shift 2 ;;
    --range)          need_val "${2:-}" --range; RANGE="$2"; shift 2 ;;
    --mode)           need_val "${2:-}" --mode; MODE="$2"; shift 2 ;;
    --branch)         need_val "${2:-}" --branch; BRANCH="$2"; shift 2 ;;
    --base-ref)       need_val "${2:-}" --base-ref; BASE_REF="$2"; shift 2 ;;
    --allowlist)      need_val "${2:-}" --allowlist; ALLOWLIST="$2"; shift 2 ;;
    --expect-restore) need_val "${2:-}" --expect-restore; DECL_ARGS+=("$2"); shift 2 ;;
    -*)               die2 "不明なオプション: '$1'（--help を参照）" ;;
    *)                die2 "余分な引数: '$1'（走査対象は --repo / --range で指定する）" ;;
  esac
done

for c in git awk mktemp; do
  command -v "$c" >/dev/null 2>&1 || die2 "外部コマンドが見つかりません: $c"
done

case "$MODE" in
  post-merge) ;;
  pre-merge)
    # A2 = leg B-2 と同一実装。委譲して rc を透過する（判定ロジックを二重実装しない）。
    BF="$SCRIPT_DIR/scribe-base-freshness.sh"
    [[ -x "$BF" ]] || die2 "pre-merge モードの委譲先が実行できません: $BF"
    [[ -n "$BRANCH" ]] || die2 "--mode pre-merge には --branch が必要です"
    [[ -z "$RANGE" ]] || die2 "--mode pre-merge に --range は使えません（--branch / --base-ref を使う）"
    args=(--repo "$REPO" --branch "$BRANCH")
    [[ -z "$BASE_REF" ]] || args+=(--base-ref "$BASE_REF")
    [[ -z "$ALLOWLIST" ]] || args+=(--allowlist "$ALLOWLIST")
    for d in ${DECL_ARGS[@]+"${DECL_ARGS[@]}"}; do args+=(--expect-restore "$d"); done
    exec "$BF" "${args[@]}"
    ;;
  *) die2 "不明な --mode: '$MODE'（post-merge / pre-merge）" ;;
esac

[[ -n "$RANGE" ]] || die2 "--range <base>..<tip> が必要です（sha で pin すること）"
[[ -z "$BRANCH" ]] || die2 "--branch は --mode pre-merge 専用です"
[[ -d "$REPO" ]] || die2 "--repo が存在しません: $REPO"
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die2 "git リポジトリではありません: $REPO"

# 履歴が完全でない repo では prior-occurrence 照合が成立しない。判定できないので clean(0) でなく
# harness-fail(2) へ倒す（shallow clone は「過去に既出か」を原理的に答えられない）。
SHALLOW="$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || true)"
[[ "$SHALLOW" == "false" ]] \
  || die2 "履歴が完全ではありません（is-shallow-repository=${SHALLOW:-unknown}）: $REPO"
# replace ref は object graph を差し替えるため、走査結果が黙って変わる。
REPLACE_N="$({ git -C "$REPO" replace -l 2>/dev/null || true; } | wc -l)"; REPLACE_N=${REPLACE_N// /}
[[ "$REPLACE_N" -eq 0 ]] \
  || die2 "replace ref が $REPLACE_N 件あります（object graph が差し替わり走査結果が変わる）: $REPO"

# --- range を解決（'..' 形式のみ受ける。'...' は対称差ゆえ本検査の意味論と合わない） ---
case "$RANGE" in
  *...*) die2 "--range は <base>..<tip> 形式のみ受け付けます（'...' は不可）: $RANGE" ;;
  *..*)  ;;
  *)     die2 "--range は <base>..<tip> 形式で指定してください: $RANGE" ;;
esac
RANGE_BASE_IN="${RANGE%%..*}"
RANGE_TIP_IN="${RANGE#*..}"
[[ -n "$RANGE_BASE_IN" && -n "$RANGE_TIP_IN" ]] || die2 "--range の base / tip が空です: $RANGE"

resolve_commit() { # <rev> <label>
  local out
  out="$(git -C "$REPO" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null)" || true
  [[ -n "$out" ]] || die2 "$2 を解決できません: '$1'"
  printf '%s' "$out"
}
RANGE_BASE="$(resolve_commit "$RANGE_BASE_IN" "--range の base")"
RANGE_TIP="$(resolve_commit "$RANGE_TIP_IN" "--range の tip")"

TMPD="$(mktemp -d)" || die2 "mktemp -d に失敗しました"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

# --- 走査対象 commit（range 内・first-parent） ---
if ! git -C "$REPO" rev-list --first-parent "$RANGE_BASE".."$RANGE_TIP" > "$TMPD/range.txt" 2>"$TMPD/err.txt"; then
  die2 "range の解決に失敗しました: $RANGE（$(head -1 "$TMPD/err.txt")）"
fi
RANGE_N=$(wc -l < "$TMPD/range.txt")
RANGE_N=${RANGE_N// /}
[[ "$RANGE_N" -gt 0 ]] || die2 "走査対象 commit が 0 件です（range が空 = 指定ミス）: $RANGE"

# range 内の merge 件数（無音 skip をしないことを機械で示すため必ず集計する）。
# skipped-merges は **実カウント**（literal を焼くと bats の assert が空虚になる）。走査で raw 行を
# 1 本も得られなかった range 内 merge ＝その merge については何も見ていない、を skipped と定義する。
if ! git -C "$REPO" rev-list --first-parent --merges "$RANGE_BASE".."$RANGE_TIP" > "$TMPD/merges.txt"; then
  die2 "range 内 merge の列挙に失敗しました: $RANGE"
fi
MERGE_N=$(wc -l < "$TMPD/merges.txt")
MERGE_N=${MERGE_N// /}

# --- 全 first-parent 履歴の raw 走査（tip から root まで 1 回） ---
# `-m --first-parent` で merge も first-parent との diff を raw 行として出す（既定の「merge の diff を
# 出さない」を回避＝無音 skip 0）。`--root` で root commit の追加も拾う。`--no-abbrev` で blob を full sha に。
if ! git -C "$REPO" -c core.quotePath=false log --first-parent -m --raw --no-renames --root --no-abbrev \
      --format='__C__ %H' "$RANGE_TIP" > "$TMPD/log.txt" 2>"$TMPD/err.txt"; then
  die2 "履歴の走査に失敗しました（tip=$RANGE_TIP）: $(head -1 "$TMPD/err.txt")"
fi

awk -v US="$US" -v rangef="$TMPD/range.txt" -v mergef="$TMPD/merges.txt" '
  FILENAME==rangef { inrange[$0]=1; next }
  FILENAME==mergef { ismerge[$0]=1; next }
  /^__C__ / { ci++; csha[ci]=$2; nn[ci]=0; next }
  /^:/ { if (ci>0) { nn[ci]++; raw[ci SUBSEP nn[ci]]=$0 } next }
  END {
    scanned=0; touched=0; revived=0; delonly=0; skipped=0
    # git log は新→古なので逆順に走査して「古い順」にする（prior-occurrence の意味論はこの順序に依存）。
    for (i=ci; i>=1; i--) {
      sha = csha[i]
      inr = (sha in inrange)
      if (inr) scanned++
      # raw 行が 1 本も無い range 内 merge ＝この merge については何も走査していない。
      if (inr && (sha in ismerge) && nn[i] == 0) skipped++
      for (j=1; j<=nn[i]; j++) {
        line = raw[i SUBSEP j]
        t = index(line, "\t")
        if (t == 0) continue
        meta = substr(line, 1, t-1)
        path = substr(line, t+1)
        split(meta, m, " ")
        dst = m[4]; st = m[5]
        # 削除は blob を持たないので prior-occurrence 照合の対象外（= touched-paths には数えない）。
        # 「削除しか無い path」は別枠で数えて集計行に出す（集計単位を沈黙で落とさない）。
        if (st == "D" || dst ~ /^0+$/) { last[path] = ""; if (inr) dseen[path]=1; continue }
        prev = (path in last) ? last[path] : ""
        if (inr && !(path in tseen)) { tseen[path]=1; touched++ }
        key = path SUBSEP dst
        if (dst != prev && (key in seen) && inr) {
          revived++
          # 区切りは US。prev は空になりうる（delete 後の再追加）ので、畳まれる TAB は使わない。
          print "EVENT" US sha US dst US prev US path
        }
        seen[key] = 1
        last[path] = dst
      }
    }
    for (p in dseen) if (!(p in tseen)) delonly++
    print "STATS" US scanned US touched US revived US delonly US skipped
  }
' "$TMPD/range.txt" "$TMPD/merges.txt" "$TMPD/log.txt" > "$TMPD/out.txt" || die2 "走査（awk）に失敗しました"

# --- 宣言（declared-restore）の読み込み ---
# DECL[path] に空白区切りの blob prefix 列を積む。blob は 4 桁以上の前方一致で照合する。
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
    # `<path> <blob> <根拠1行>`。根拠は照合に使わないが省略は不可（宣言に説明責任を持たせる）。
    read -r a_path a_blob a_rest <<< "$line"
    [[ -n "$a_path" && -n "$a_blob" && -n "$a_rest" ]] \
      || die2 "--allowlist の $lineno 行目が不正です（'<path> <blob> <根拠>' が必要）: $ALLOWLIST"
    add_decl "$a_path=$a_blob" "--allowlist の $lineno 行目"
  done < "$ALLOWLIST"
fi

is_declared() { # <path> <blob-full>
  local p="$1" blob="${2,,}" b
  # 空 path は連想配列の subscript にできず abort する。呼び出し側の field 破損を緑にも検知にも
  # 倒さず harness-fail(2) で落とす。
  [[ -n "$p" ]] || die2 "内部エラー: 空の path で宣言照合が呼ばれました（EVENT 行の field 破損）"
  [[ -n "${DECL[$p]:-}" ]] || return 1
  # DECL[path] は空白区切りの blob prefix 列（宣言側が hex に検証済みゆえ単語分割で安全）。
  for b in ${DECL[$p]}; do
    [[ "$blob" == "$b"* ]] && return 0
  done
  return 1
}

# --- 集計と出力 ---
SCANNED=0; TOUCHED=0; REVIVED=0; DELONLY=0; SKIPPED_MERGES=0
SUSPECT=0; DECLARED=0
SUSPECT_LINES=()
DECLARED_LINES=()
short() { printf '%s' "${1:0:7}"; }

while IFS="$US" read -r tag f2 f3 f4 f5 f6; do
  case "$tag" in
    STATS) SCANNED="$f2"; TOUCHED="$f3"; REVIVED="$f4"; DELONLY="$f5"; SKIPPED_MERGES="$f6" ;;
    EVENT)
      # f2=commit / f3=復活した blob / f4=直前 blob / f5=path
      if is_declared "$f5" "$f3"; then
        DECLARED=$((DECLARED + 1))
        DECLARED_LINES+=("declared-restore: path=$f5 commit=$(short "$f2") revived-blob=$(short "$f3") prev-blob=$(short "${f4:-none}")")
      else
        SUSPECT=$((SUSPECT + 1))
        SUSPECT_LINES+=("clobber-suspect: path=$f5 commit=$(short "$f2") revived-blob=$(short "$f3") prev-blob=$(short "${f4:-none}")")
      fi
      ;;
  esac
done < "$TMPD/out.txt"

# 削除しか無い range は「走査対象 0」ではない（正常に走査した結果、blob を持つ変更が無かった）。
# deleted-only-paths を集計行へ出した上で通常の走査扱いにする（理由文と事実を食い違わせない）。
[[ "$TOUCHED" -gt 0 || "$DELONLY" -gt 0 ]] \
  || die2 "走査対象 file が 0 件です（range 内に file の変更も削除も無い）: $RANGE"

# range 内 commit のうち tip の first-parent chain に載っていないものがあると prior-occurrence の
# 意味論（「その commit より前の first-parent 履歴」）が保証できない。鮮度が判定できない場合は
# clean(0) へ倒さず harness-fail(2) にする。
[[ "$SCANNED" -eq "$RANGE_N" ]] || die2 \
  "range 内 commit が tip の first-parent chain に載っていません（range=$RANGE_N 件 / chain 上 $SCANNED 件）: $RANGE"

# touched-paths は「blob を持つ変更があった path」（削除だけの path は deleted-only-paths へ分ける）。
# 集計単位を沈黙で落とさないため両方出す（他実装の raw 集計と桁が合わない時の突合点になる）。
printf '%s: mode=post-merge repo=%s range=%s..%s range-in=%s scanned-commits=%s merges=%s skipped-merges=%s touched-paths=%s deleted-only-paths=%s revived=%s clobber-suspect=%s declared-restore=%s\n' \
  "$PROG" "$REPO" "$(short "$RANGE_BASE")" "$(short "$RANGE_TIP")" "$RANGE" \
  "$SCANNED" "$MERGE_N" "$SKIPPED_MERGES" "$TOUCHED" "$DELONLY" "$REVIVED" "$SUSPECT" "$DECLARED"

[[ ${#SUSPECT_LINES[@]}  -eq 0 ]] || printf '%s\n' "${SUSPECT_LINES[@]}"
[[ ${#DECLARED_LINES[@]} -eq 0 ]] || printf '%s\n' "${DECLARED_LINES[@]}"

if [[ "$SUSPECT" -gt 0 ]]; then
  exit 1
fi
exit 0

#!/usr/bin/env bash
# check-ledger-separation.sh — bd 台帳（refs/dolt/*）がコード repo から分離されているかの機械検査。
#
# 出所: orchestrator 裁定 orch-jot0 / bd sc-zkof。fleet 標準として「bd 台帳の sync 先はコード repo と
# 分離する（PUBLIC repo だけでなく全 repo 既定）」を、scribe:setup reconciler が機械で検査するための実体。
# SKILL.md の散文だけでは「散文を grep する bats」で満たしたことにできてしまうため、判定は本 checker が持ち
# SKILL.md は Step 0 / 収束 step / Step 末の 3 箇所からこれを呼ぶ（doc-pin 禁止）。
#
# 機械条件（2 本）:
#   条件 1: `git ls-remote <コード repo> 'refs/dolt/*'` が 0 件であること。
#   条件 2: sync.remote が当該コード repo を指さないこと。
#
# 終了コード（3 値・UNKNOWN を OK に畳まない＝fail-open 封鎖）:
#   0 = CLEAN     （両条件とも違反なしと確認できた）
#   1 = VIOLATION （どちらかで実際の違反を検出した）
#   2 = UNKNOWN   （到達不能・認証不能・timeout・bd 実行不能・引数不正等で判定できなかった）
# 違反と判定不能が同時に出た場合は 1（違反）を優先する（より強い信号を返す）。
#
# --- コード repo の同定（identity） ------------------------------------------
# `origin` を正準のコード repo とする。origin が無い repo でも「台帳分離と無関係な次元まで恒久停止」に
# ならないよう、remote の実在で 3 通りに分岐する:
#   (c) origin あり            → コード repo = origin。条件 1 / 2 とも origin を基準に判定する。
#   (b) remote ≥1・origin 無し → 正準コード repo を特定できないので条件 1 は UNKNOWN。ただし条件 2 は
#       **全 remote の URL** を比較対象に広げて判定を続ける（origin だけを見る実装は、コード repo を
#       upstream 等の別名で持つ repo の実違反を素通しする）。
#   (a) remote 0 本            → 公開面が無いので条件 1 は N/A（`COND1: OK` + `COND1-NOTE:` 注記）。条件 2 は
#       **repo 自身の物理パスの file:// 正規化**を code-identity の fallback に用いて判定を続ける
#       （local-only repo で sync.remote が自リポを指す形も違反として検出できる）。
#   いずれでもなく git 自体が使えない（非 git ディレクトリ・git 実行不能）ときは全体 UNKNOWN。
#   ＝「origin の rc≠0」を『origin 未設定』と『git 実行不能』に弁別する。
#
# 条件 1 の 3 値判定:
#   rc=0 かつ 0 行            → OK
#   rc=0 かつ 1 行以上        → VIOLATION（台帳が公開面に出ている）
#   rc≠0                      → UNKNOWN（fail-loud。決して OK に畳まない）
#   ※ `git ls-remote ... | grep -q` のようにパイプで rc を捨てる形は使わない（out/rc を必ず捕捉する）。
#   ※ 補助検出: dolt の git-remote 実装は `refs/heads/__dolt_remote_info__` も push するため、
#     glob の外に居る台帳由来 ref を `COND1-EXTRA: DOLT-REF-OUTSIDE-GLOB <ref>` で fail-loud に surface する
#     （rc は変えない。既存 ref の削除は破壊操作＝人間承認事案で reconciler の裁量外ゆえ報告に留める）。
#
# 条件 2 の判定（部分一致禁止・3 経路 OR）:
#   比較は「正規化後の完全一致」。1 経路でもコード repo を指したら VIOLATION（OR で赤・AND で緑にしない）。
#     (2a) col0 平坦の `sync.remote:` 行
#     (2b) nested `sync:` ブロックの `remote:`
#     (2c) `bd dolt remote list` の実 push 先 ← **これが真の決定点**
#   2c を欠く実装は受け入れない: dolt エンジンは config.yaml とは別の自前 remote レジストリを持つため、
#   config だけを見る検査は 2026-07-27 incident そのものの状態（config は private・実 push 先はコード repo）を
#   green と報告してしまう。
#   2c は検査対象の台帳へ **pin** する。bd の台帳解決は ambient（BEADS_DIR が cwd より優先され、DB を持たない
#   .beads では祖先の台帳へ解決される）ため、pin しないと別台帳の remote を当該台帳の 2c として報告してしまう。
#   pin は `bd where` の **2 情報**で行う——(i) active な .beads path が当該 .beads と一致 **かつ**
#   (ii) `database:` 行が当該 .beads 配下の実在パスを指す。**path だけの比較では不十分**（path は cwd の
#   .beads を返しつつ database だけが祖先台帳を指す状態が実在する＝実測）。不一致・取得不能・DB 不在は
#   いずれも 2c: UNKNOWN。
#
#   適用単位は git root の .beads ではなく **repo 内に実在する全 .beads**。ただし git-ignored な ephemeral
#   コピー（worker worktree の checkout 等）は台帳ではないので走査から外す。**除外には 2 つの安全弁**を置く:
#     - `$REPO/.beads`（root 台帳）は除外対象にしない。root 台帳が ephemeral コピーであることは無く、
#       `.gitignore` に `.beads/` を書く repo で root 台帳ごと落ちると「候補 0＝未導入＝OK」に化ける。
#     - 「フィルタ前候補が 1 件以上あるのに評価対象が 0 件」は **COND2: UNKNOWN**（`OK` に畳まない）。
#       `OK` を返すのは「候補 0 かつ除外 0」＝本当に台帳が無いときだけ。
#
# 正規化仕様（sc-vbre の beads-bdw plugin 側 guard と同一契約。lib 共有は別便）:
#   先頭 `git+` 除去 / ssh 形 `git@host:owner/repo` を `https://host/owner/repo` へ写像 /
#   `ssh://` scheme を `https` へ写像しユーザ情報を除去 / 素の絶対パスを `file://` へ写像 /
#   scheme・host を小文字化 / 末尾 `/` と末尾 `.git` を除去。path の大小文字は保存する。
#
# usage:
#   check-ledger-separation.sh [--repo <path>] [--quiet]
#       機械条件 2 本を判定する（既定 mode）。
#   check-ledger-separation.sh --assert-not-code-repo <url> [--repo <path>] [--quiet]
#       「この URL はコード repo ではない」ことだけを判定する（rc 0=コード repo でない / 1=コード repo と
#       一致 / 2=判定不能）。`bd dolt remote add` の **前** に呼ぶ wire ゲート用。wire してから検査すると
#       レジストリに残留し、以後の自動 push で公開面へ出てしまう（不可逆）ため、判定は wire より前に置く。

set -uo pipefail

REPO=""
QUIET=0
MODE="check"
ASSERT_URL=""

die_unknown() { printf '%s\n' "check-ledger-separation: $1" >&2; printf 'RESULT: UNKNOWN\n'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      # 値の存在を検査してから shift する。値欠落で `shift 2` が失敗すると $1 が消費されないまま
      # ループが回り続け、無出力の busy loop になる（rc も返らない）。引数不正は既存の未知 arg と
      # 同じ rc=2 で fail-loud にする。
      [ $# -ge 2 ] || die_unknown "--repo に値が必要（引数不正）"
      REPO="$2"; shift 2 ;;
    --assert-not-code-repo)
      [ $# -ge 2 ] || die_unknown "--assert-not-code-repo に値が必要（引数不正）"
      MODE="assert"; ASSERT_URL="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '1,72p' "$0"; exit 0 ;;
    *) die_unknown "unknown arg: $1" ;;
  esac
done

say() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

if [ -z "$REPO" ]; then
  REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || REPO=""
fi
if [ -z "$REPO" ] || [ ! -d "$REPO" ]; then
  say "check-ledger-separation: git root を解決できない（--repo で指定する）"
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi
# 物理パスへ正規化する。symlink 経由で渡されると find が台帳を 1 件も見つけられず「未導入」に化け、
# 末尾スラッシュ付きだと候補の相対ラベルが全て `.beads` へ潰れる。両方をここで潰しておく。
REPO="$(cd "$REPO" 2>/dev/null && pwd -P)" || REPO=""
if [ -z "$REPO" ]; then
  say "check-ledger-separation: --repo を物理パスへ解決できない"
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi

# --- URL 正規化 -------------------------------------------------------------
normalize_url() {
  local u="${1:-}"
  [ -z "$u" ] && { printf ''; return 0; }
  # 前後の空白・引用符を剥がす
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  u="${u#\"}"; u="${u%\"}"; u="${u#\'}"; u="${u%\'}"
  # 先頭 git+ を除去（bd の sync.remote は git+<url> 形）
  u="${u#git+}"
  # scp 形 ssh（user@host:owner/repo）を https へ写像
  if [[ "$u" != *"://"* && "$u" =~ ^[^/@]+@([^:/]+):(.+)$ ]]; then
    u="https://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  # 素の絶対パスを file:// へ写像（`git remote get-url` は素のパスを返す一方、bd の sync.remote は
  # scheme 必須ゆえ file:// 形で書かれる。両者を同一視しないと local remote 構成で違反を見落とす）
  if [[ "$u" != *"://"* && "$u" == /* ]]; then
    u="file://$u"
  fi
  # scheme://host/path を分解し scheme・host を小文字化。ssh は https へ写像し userinfo を落とす
  if [[ "$u" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(.*)$ ]]; then
    local sch="${BASH_REMATCH[1]}" host="${BASH_REMATCH[2]}" rest="${BASH_REMATCH[3]}"
    sch="$(printf '%s' "$sch" | tr '[:upper:]' '[:lower:]')"
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    host="${host##*@}"
    [ "$sch" = "ssh" ] && sch="https"
    u="${sch}://${host}${rest}"
  fi
  # 末尾 / と 末尾 .git を除去
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  u="${u%.git}"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  printf '%s' "$u"
}

# --- git が使えるかの弁別（「origin 未設定」と「git 実行不能」を混ぜない） --------
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  say "check-ledger-separation: $REPO を git repo として読めない（非 git or git 実行不能）→ 判定不能"
  printf 'COND1: UNKNOWN\n'
  printf 'COND2: UNKNOWN\n'
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi

remotes_out="$(git -C "$REPO" remote 2>/dev/null)"; remotes_rc=$?
if [ "$remotes_rc" -ne 0 ]; then
  say "check-ledger-separation: git remote の列挙に失敗（rc=$remotes_rc）→ 判定不能"
  printf 'COND1: UNKNOWN\n'
  printf 'COND2: UNKNOWN\n'
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi

REMOTE_NAMES=()
while IFS= read -r r; do [ -n "$r" ] && REMOTE_NAMES+=("$r"); done <<< "$remotes_out"

HAS_ORIGIN=0
for r in ${REMOTE_NAMES[@]+"${REMOTE_NAMES[@]}"}; do
  [ "$r" = "origin" ] && HAS_ORIGIN=1
done

CODE_IDS=()        # 正規化済みの code-identity 集合（条件 2 の比較対象）
CODE_MODE=""       # origin | all-remotes | no-remote
say "[check-ledger-separation] repo=$REPO"
if [ "$HAS_ORIGIN" -eq 1 ]; then
  CODE_MODE="origin"
  code_raw="$(git -C "$REPO" remote get-url origin 2>/dev/null)"; code_rc=$?
  if [ "$code_rc" -ne 0 ] || [ -z "$code_raw" ]; then
    say "  origin は在るが URL を取得できない（rc=$code_rc）→ 判定不能"
    printf 'COND1: UNKNOWN\n'
    printf 'COND2: UNKNOWN\n'
    printf 'RESULT: UNKNOWN\n'
    exit 2
  fi
  CODE_IDS=("$(normalize_url "$code_raw")")
  say "  code-repo: $code_raw  (正規化: ${CODE_IDS[0]})"
elif [ "${#REMOTE_NAMES[@]}" -gt 0 ]; then
  CODE_MODE="all-remotes"
  say "  origin が無い（remote: ${REMOTE_NAMES[*]}）→ 正準コード repo を特定できないので条件 1 は UNKNOWN。"
  say "  条件 2 は全 remote の URL を比較対象へ広げて判定を続ける。"
  for r in "${REMOTE_NAMES[@]}"; do
    raw="$(git -C "$REPO" remote get-url "$r" 2>/dev/null)"
    [ -n "$raw" ] || continue
    CODE_IDS+=("$(normalize_url "$raw")")
    say "    remote $r: $raw"
  done
  if [ "${#CODE_IDS[@]}" -eq 0 ]; then
    say "  remote の URL を 1 本も取得できない → 判定不能"
    printf 'COND1: UNKNOWN\n'
    printf 'COND2: UNKNOWN\n'
    printf 'RESULT: UNKNOWN\n'
    exit 2
  fi
else
  CODE_MODE="no-remote"
  CODE_IDS=("$(normalize_url "$REPO")")
  say "  git remote が 0 本＝台帳が出て行く公開面が無い。条件 1 は N/A、条件 2 は repo 自身のパスを"
  say "  code-identity の fallback にして判定を続ける（正規化: ${CODE_IDS[0]}）。"
fi

is_code_repo() {   # $1 = 正規化済み URL
  local n="${1:-}" c
  [ -z "$n" ] && return 1
  for c in ${CODE_IDS[@]+"${CODE_IDS[@]}"}; do
    [ -n "$c" ] && [ "$n" = "$c" ] && return 0
  done
  return 1
}

# --- assert mode: wire 前ゲート ------------------------------------------------
if [ "$MODE" = "assert" ]; then
  a_norm="$(normalize_url "$ASSERT_URL")"
  if [ -z "$a_norm" ]; then
    say "  assert: URL を正規化できない（空）→ 判定不能"
    printf 'ASSERT-NOT-CODE-REPO: UNKNOWN\n'
    exit 2
  fi
  if is_code_repo "$a_norm"; then
    say "  assert: 与えられた URL はこの repo のコード repo と一致する（正規化: $a_norm）"
    say "    → 台帳をコード repo へ wire してはならない。wire せず停止すること。"
    printf 'ASSERT-NOT-CODE-REPO: VIOLATION\n'
    exit 1
  fi
  say "  assert: 与えられた URL はコード repo ではない（正規化: $a_norm）→ wire 可"
  printf 'ASSERT-NOT-CODE-REPO: OK\n'
  exit 0
fi

violation=0
unknown=0

# --- 条件 1: コード repo に refs/dolt/* が 0 件か ------------------------------
# rc を必ず捕捉する（grep -q へパイプして rc を捨てる形は使わない＝fail-open の芽）。
case "$CODE_MODE" in
  origin)
    ls_out="$(git -C "$REPO" ls-remote origin 'refs/dolt/*' 2>/dev/null)"; ls_rc=$?
    if [ "$ls_rc" -ne 0 ]; then
      say "  条件1: UNKNOWN — git ls-remote が rc=$ls_rc（到達不能・認証不能・timeout 等）"
      printf 'COND1: UNKNOWN\n'
      unknown=1
    else
      n_refs=0
      if [ -n "$ls_out" ]; then
        n_refs="$(printf '%s\n' "$ls_out" | grep -c '[^[:space:]]')"
      fi
      if [ "$n_refs" -eq 0 ]; then
        say "  条件1: OK — コード repo に refs/dolt/* は 0 件"
        printf 'COND1: OK\n'
      else
        say "  条件1: VIOLATION — コード repo に refs/dolt/* が ${n_refs} 件（台帳が公開面に出ている）"
        say "$(printf '%s\n' "$ls_out" | sed 's/^/    /')"
        printf 'COND1: VIOLATION\n'
        violation=1
      fi
    fi

    # 補助検出: dolt の git-remote 実装は台帳 push 時に `refs/heads/__dolt_remote_info__` も作るため、
    # glob `refs/dolt/*` では拾えない。条件 1 が OK でも台帳由来 ref が公開面に残りうるので surface する。
    # ただし rc の意味は変えない: 既存 ref の削除は破壊操作（人間承認事案）で reconciler の裁量外ゆえ、
    # ここで RED にすると分離済みの repo が恒久停止する。判定は報告に留め、処置は人間が決める。
    extra_out="$(git -C "$REPO" ls-remote origin '*__dolt*' 2>/dev/null)"; extra_rc=$?
    if [ "$extra_rc" -ne 0 ]; then
      printf 'COND1-EXTRA: UNKNOWN\n'
      say "  条件1 補助: UNKNOWN — git ls-remote が rc=$extra_rc（dolt 由来 ref の残存を確認できない）"
    elif [ -n "$extra_out" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        ref="${line##*$'\t'}"
        case "$ref" in refs/dolt/*) continue ;; esac
        printf 'COND1-EXTRA: DOLT-REF-OUTSIDE-GLOB %s\n' "$ref"
        say "  条件1 補助: 台帳由来 ref が refs/dolt/* の外に残存 — $ref"
        say "    （削除は破壊操作＝人間承認事案。rc は変えない＝報告のみ）"
      done <<< "$extra_out"
    fi
    ;;
  all-remotes)
    say "  条件1: UNKNOWN — origin が無く正準のコード repo を特定できない（remote: ${REMOTE_NAMES[*]}）"
    say "    origin を設定するか、どの remote がコード repo かを決めてから再検査すること。"
    printf 'COND1: UNKNOWN\n'
    unknown=1
    ;;
  no-remote)
    say "  条件1: OK（N/A）— git remote が 0 本＝台帳が出て行く公開面が無い"
    printf 'COND1: OK\n'
    printf 'COND1-NOTE: NO-GIT-REMOTE\n'
    ;;
esac

# --- config.yaml のパース ----------------------------------------------------
# (2a) col0 平坦の `sync.remote:` 行
parse_flat_remote() {
  awk '
    /^[[:space:]]*#/ { next }
    /^sync\.remote:[[:space:]]*/ {
      v = $0; sub(/^sync\.remote:[[:space:]]*/, "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      if (v != "") { print v }
    }
  ' "$1" 2>/dev/null
}

# (2b) nested `sync:` ブロックの `remote:`（col0 の別キーが来たらブロック終了）
parse_nested_remote() {
  awk '
    /^[[:space:]]*#/ { next }
    /^sync:[[:space:]]*(#.*)?$/ { insync = 1; next }
    /^[^[:space:]#]/ { insync = 0 }
    insync && /^[[:space:]]+remote:[[:space:]]*/ {
      v = $0; sub(/^[[:space:]]+remote:[[:space:]]*/, "", v)
      sub(/[[:space:]]*(#.*)?$/, "", v)
      if (v != "") { print v }
    }
  ' "$1" 2>/dev/null
}

# --- 条件 2: 全 .beads について 3 経路を OR 判定 --------------------------------
# 走査は **repo 自身の working tree に実在する台帳** に限る。git-ignored な ephemeral コピー
# （worker worktree の checkout・vendor ディレクトリ）まで台帳として数えると、`.worktrees/` を持つ
# anchor で他 cell の古い config が偽 VIOLATION を作り、reconciler が恒久停止する。恒常的な false RED は
# 「rc を読み飛ばす」運用を誘発し、次の本物の違反を素通しさせる＝本 checker が防ごうとしている失敗様式そのもの。
# 除外は 2 段: (1) 明示 prune（worktree 規約・vendor ディレクトリ）(2) `git check-ignore`。
# ただし除外そのものが fail-open にならないよう、下記 2 つの安全弁（root 台帳の免除・評価対象 0 件の UNKNOWN）
# を必ず併置する。
mapfile -t BEADS_CANDIDATES < <(
  find "$REPO" \
    \( -name .git -o -name node_modules -o -name .worktrees -o -path '*/.claude/worktrees' \) -prune -o \
    \( -name .beads -type d \) -print 2>/dev/null | LC_ALL=C sort
)

n_cand="${#BEADS_CANDIDATES[@]}"
n_skipped=0
BEADS_DIRS=()
for cand in ${BEADS_CANDIDATES[@]+"${BEADS_CANDIDATES[@]}"}; do
  # 安全弁 1: root 台帳は除外対象にしない。`.gitignore` に `.beads/` を書く repo で root 台帳ごと
  # 落とすと「候補 0＝未導入＝OK」に化け、違反 config を持つ repo を CLEAN と報告してしまう。
  if [ "$cand" = "$REPO/.beads" ]; then
    BEADS_DIRS+=("$cand")
    continue
  fi
  if git -C "$REPO" check-ignore -q -- "$cand" 2>/dev/null; then
    n_skipped=$((n_skipped + 1))
    say "  条件2: skip — git-ignored な ephemeral コピー（台帳ではない）: ${cand#"$REPO"/}"
    continue
  fi
  BEADS_DIRS+=("$cand")
done

if [ "$n_cand" -eq 0 ]; then
  say "  条件2: 判定対象の .beads が無い（未導入）"
  printf 'COND2: OK\n'
elif [ "${#BEADS_DIRS[@]}" -eq 0 ]; then
  # 安全弁 2: 候補は在ったのに全て除外された。OK に畳むと「除外規則そのもの」が fail-open になる。
  say "  条件2: UNKNOWN — 候補 $n_cand 件すべてが除外され（skip $n_skipped 件）評価対象が 0 件"
  say "    除外規則が広すぎるか、台帳が ephemeral な場所にしか無い。OK には畳まない。"
  printf 'COND2: UNKNOWN\n'
  unknown=1
else
  cond2_violation=0
  cond2_unknown=0
  strip_prefix="$REPO/"; [ "$REPO" = "/" ] && strip_prefix="/"
  for bdir in "${BEADS_DIRS[@]}"; do
    rel="${bdir#"$strip_prefix"}"
    cfg="$bdir/config.yaml"
    parent="$(dirname "$bdir")"

    # (2a)
    if [ -f "$cfg" ]; then
      flat="$(parse_flat_remote "$cfg")"
    else
      flat=""
    fi
    if [ -z "$flat" ]; then
      printf 'COND2 %s 2a: ABSENT\n' "$rel"
      say "    $rel 2a col0 sync.remote: (無し)"
    else
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        nu="$(normalize_url "$u")"
        if is_code_repo "$nu"; then
          printf 'COND2 %s 2a: VIOLATION\n' "$rel"
          say "    $rel 2a col0 sync.remote: $u → VIOLATION（コード repo を指している）"
          cond2_violation=1
        else
          printf 'COND2 %s 2a: OK\n' "$rel"
          say "    $rel 2a col0 sync.remote: $u → OK"
        fi
      done <<< "$flat"
    fi

    # (2b)
    if [ -f "$cfg" ]; then
      nested="$(parse_nested_remote "$cfg")"
    else
      nested=""
    fi
    if [ -z "$nested" ]; then
      printf 'COND2 %s 2b: ABSENT\n' "$rel"
      say "    $rel 2b nested sync:.remote: (無し)"
    else
      while IFS= read -r u; do
        [ -z "$u" ] && continue
        nu="$(normalize_url "$u")"
        if is_code_repo "$nu"; then
          printf 'COND2 %s 2b: VIOLATION\n' "$rel"
          say "    $rel 2b nested sync:.remote: $u → VIOLATION（コード repo を指している）"
          cond2_violation=1
        else
          printf 'COND2 %s 2b: OK\n' "$rel"
          say "    $rel 2b nested sync:.remote: $u → OK"
        fi
      done <<< "$nested"
    fi

    # (2c) 真の決定点: dolt の remote レジストリ。**検査対象の台帳へ pin する**。
    #   `bd where` は「active な .beads の path」と「database:（実 DB の場所）」を出す。path だけを見る
    #   pin は不十分——DB を持たない .beads では path に cwd の .beads を返しつつ database: だけが祖先台帳を
    #   指すため、`bd dolt remote list` は祖先の remote を返しながら pin は通ってしまう（masking＝fail-open）。
    #   ゆえに path 一致 **かつ** database: が当該 .beads 配下の実在パスであることを要求する。
    #   出力行数は bd の版・構成で変わる（prefix: 行が出ない構成が実在する）ので行番号ではなくキーで拾う。
    # `| head -1` は使わない（pipefail 下で bd が SIGPIPE を踏むと rc が化ける）。全文を捕捉して解析する。
    where_out="$(cd "$parent" 2>/dev/null && env -u BEADS_DIR bd where 2>/dev/null)"; where_rc=$?
    if [ "$where_rc" -ne 0 ] || [ -z "$where_out" ]; then
      printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
      say "    $rel 2c bd where: rc=$where_rc → UNKNOWN（bd の解決先を確認できない＝台帳を pin できない）"
      cond2_unknown=1
      continue
    fi
    # active な .beads path（行頭が絶対パスの最初の行。警告行等は無視する）
    resolved="$(awk '/^\// { print; exit }' <<< "$where_out")"
    resolved="${resolved%"${resolved##*[![:space:]]}"}"; resolved="${resolved%/}"
    # database: 行（キーで拾う）
    dbpath="$(awk '/^[[:space:]]*database:[[:space:]]*/ {
                     sub(/^[[:space:]]*database:[[:space:]]*/, ""); print; exit }' <<< "$where_out")"
    dbpath="${dbpath%"${dbpath##*[![:space:]]}"}"; dbpath="${dbpath%/}"

    if [ -z "$resolved" ]; then
      printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
      say "    $rel 2c bd where の出力から active な台帳 path を読めない → UNKNOWN"
      cond2_unknown=1
      continue
    fi
    if [ "$resolved" != "${bdir%/}" ]; then
      printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
      say "    $rel 2c bd の解決先が別台帳（$resolved）→ UNKNOWN（この台帳の実 push 先は未確認）"
      cond2_unknown=1
      continue
    fi
    if [ -z "$dbpath" ]; then
      printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
      say "    $rel 2c bd where が database: を出さない → UNKNOWN（どの DB の remote かを特定できない）"
      cond2_unknown=1
      continue
    fi
    case "$dbpath" in
      "${bdir%/}"|"${bdir%/}"/*) ;;
      *)
        printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
        say "    $rel 2c database: が別台帳配下（$dbpath）→ UNKNOWN"
        say "      （path は一致していても実 DB は祖先台帳＝remote も別台帳のもの。OK に畳まない）"
        cond2_unknown=1
        continue ;;
    esac
    if [ ! -e "$dbpath" ]; then
      printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
      say "    $rel 2c database: が実在しない（$dbpath）→ UNKNOWN（live な台帳ではない）"
      cond2_unknown=1
      continue
    fi

    dolt_out="$(cd "$parent" 2>/dev/null && env -u BEADS_DIR bd dolt remote list 2>/dev/null)"; dolt_rc=$?
    if [ "$dolt_rc" -ne 0 ]; then
      printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
      say "    $rel 2c bd dolt remote list: rc=$dolt_rc → UNKNOWN（実 push 先を確認できない）"
      cond2_unknown=1
    else
      urls="$(printf '%s\n' "$dolt_out" | awk 'NF>=2 { print $2 }')"
      if [ -z "$urls" ]; then
        printf 'COND2 %s 2c: ABSENT\n' "$rel"
        say "    $rel 2c bd dolt remote list: (remote 未設定＝local-only)"
      else
        while IFS= read -r u; do
          [ -z "$u" ] && continue
          nu="$(normalize_url "$u")"
          if is_code_repo "$nu"; then
            printf 'COND2 %s 2c: VIOLATION\n' "$rel"
            say "    $rel 2c bd dolt remote list: $u → VIOLATION（実 push 先がコード repo）"
            cond2_violation=1
          else
            printf 'COND2 %s 2c: OK\n' "$rel"
            say "    $rel 2c bd dolt remote list: $u → OK"
          fi
        done <<< "$urls"
      fi
    fi
  done

  if [ "$cond2_violation" -eq 1 ]; then
    printf 'COND2: VIOLATION\n'
    violation=1
  elif [ "$cond2_unknown" -eq 1 ]; then
    printf 'COND2: UNKNOWN\n'
    unknown=1
  else
    printf 'COND2: OK\n'
  fi
fi

# --- 総合判定（VIOLATION > UNKNOWN > CLEAN） ----------------------------------
if [ "$violation" -eq 1 ]; then
  say "  → 台帳がコード repo と分離されていない。bd dolt push しないこと。"
  printf 'RESULT: VIOLATION\n'
  exit 1
fi
if [ "$unknown" -eq 1 ]; then
  say "  → 判定不能。OK に畳まず、原因を解消してから再検査すること。"
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi
printf 'RESULT: CLEAN\n'
exit 0

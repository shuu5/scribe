#!/usr/bin/env bash
# check-ledger-separation.sh — bd 台帳（refs/dolt/*）がコード面から分離されているかの機械検査。
#
# 出所: orchestrator 裁定 orch-jot0 / bd sc-zkof。fleet 標準として「bd 台帳の sync 先はコード repo と
# 分離する（PUBLIC repo だけでなく全 repo 既定）」を、scribe:setup reconciler が機械で検査するための実体。
# SKILL.md の散文だけでは「散文を grep する bats」で満たしたことにできてしまうため、判定は本 checker が持ち
# SKILL.md は Step 0 / 収束 step / Step 末の 3 箇所からこれを呼ぶ（doc-pin 禁止）。
#
# 機械条件（2 本）:
#   条件 1: コード面に `refs/dolt/*` が 0 件であること。
#   条件 2: sync.remote がコード面を指さないこと。
#
# 終了コード（3 値・UNKNOWN を OK に畳まない＝fail-open 封鎖）:
#   0 = CLEAN     （両条件とも違反なしと確認できた）
#   1 = VIOLATION （どちらかで実際の違反を検出した）
#   2 = UNKNOWN   （到達不能・認証不能・timeout・bd 実行不能・引数不正・走査不完全等で判定できなかった）
# 違反と判定不能が同時に出た場合は 1（違反）を優先する（より強い信号を返す）。
#
# --- コード面の同定（code identity） -----------------------------------------
# 台帳が出て行きうる面は origin の第 1 fetch URL だけではない。次の**全部**を code-identity 集合に入れる:
#   - 各 remote の `git remote get-url --all <名前>`（fetch URL 全部・複数 url 設定に対応）
#   - 各 remote の `git remote get-url --push --all <名前>`（**pushurl**。push はこちらへ行く）
#   - repo 自身の物理パス（台帳を自リポへ向ける形も違反として検出する）
# 正規化後に去重し、条件 2 と `--assert-not-code-repo` はこの集合との完全一致で判定する。
# **URL を 1 本も解決できない remote は黙って落とさない**（silent drop は fail-open）——
# `COND1 <名前>: UNKNOWN` として記録し全体を UNKNOWN 側へ倒す。
# remote の実在で 3 通りに分岐する:
#   (c) origin あり            → 条件 1 は全 URL を per-URL で走査。
#   (b) remote ≥1・origin 無し → per-URL 走査に加え、正準面を特定できない旨で最終 UNKNOWN。
#   (a) remote 0 本            → 公開面が無いので条件 1 は N/A（`COND1: OK` + `COND1-NOTE: NO-GIT-REMOTE`）。
#       条件 2 は repo 自身のパスだけを code-identity に用いるため
#       `COND2-NOTE: CODE-IDENTITY-PATH-ONLY` を出す（URL 形の台帳先は機械照合できない＝人間が確認）。
#   git 自体が使えない（非 git ディレクトリ・git 実行不能）ときは全体 UNKNOWN
#   ＝「origin 未設定」と「git 実行不能」を弁別する。
# **VIOLATION 行には面のラベル（remote 名 / `#push` / `<repo 自身のパス>`）を出す**。台帳専用 private repo を
# git remote に登録している構成では「台帳が台帳 repo を指す」ことが VIOLATION として出うるため、
# どの面と一致したかを人間が弁別できるようにする。
#
# 条件 1 の 3 値判定（per-URL → 合成）:
#   rc=0 かつ 0 行            → OK
#   rc=0 かつ 1 行以上        → VIOLATION（台帳がその面に出ている）
#   rc≠0（timeout 含む）      → UNKNOWN（fail-loud。決して OK に畳まない）
#   合成は VIOLATION > UNKNOWN > OK。`| grep -q` でパイプして rc を捨てる形は使わない。
#   走査は **remote 名ではなく URL を直接指定**する（remote 名指定の ls-remote は fetch URL しか見ないので
#   pushurl 上の露出を取り逃がす）。
#
#   ★**条件 1 が測っているのは「ref listing の不在」であって「object の不在」ではない**（orch-g0xs 実測）。
#     ref を削除しても object 自体は remote に残り、匿名 fetch で取得できる場合がある（public repo で
#     台帳本体 32MB が ref 削除後も匿名到達可能であることが実測されている）。ゆえに条件 1 の OK は
#     「一覧に出ない」ことの確認であり、**露出が消えたことの証明ではない**。この区別を出力語彙でも保つ:
#     走査を行った run では `COND1-NOTE: REF-LISTING-ONLY` を必ず出し、per-URL の OK 行も
#     「listing に無い」と書く。露出の完全な解消には remote 側の GC / repo 再作成等が要る（本 checker の
#     裁量外＝人間の判断事項）。
#   ※ 補助検出: dolt の git-remote 実装は `refs/heads/__dolt_remote_info__` も push するため、
#     glob の外に居る台帳由来 ref を `COND1-EXTRA: DOLT-REF-OUTSIDE-GLOB <ref>` で per-URL に surface する
#     （rc は変えない。既存 ref の削除は破壊操作＝人間承認事案で reconciler の裁量外ゆえ報告に留める）。
#
# 条件 2 の判定（部分一致禁止・3 経路 OR）:
#   比較は「正規化後の完全一致」。1 経路でもコード面を指したら VIOLATION（OR で赤・AND で緑にしない）。
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
#   いずれも 2c: UNKNOWN。remote 行が在るのに URL 形の値を 1 本も取れないときも 2c: UNKNOWN。
#   config.yaml が在るのに読めない場合は 2a/2b を ABSENT（緑）にせず
#   `COND2-NOTE: CONFIG-UNREADABLE` + UNKNOWN にする。
#
#   適用単位は git root の .beads ではなく **repo 内に実在する全 .beads**（symlink 形も拾う）。
#   ephemeral コピー（worker worktree の checkout 等）だけを走査から外すが、除外は
#   **「git-ignored かつ live でない（DB 実体なし）」の単一述語**に一本化する。ディレクトリ名による
#   事前 prune（`.worktrees` 等）は使わない——prune は live 安全弁より前段で効くため、prune 対象配下の
#   live 台帳がコード面を指していても存在ごと不可視になり CLEAN に化ける。prune するのは `.git` だけ。
#   さらに 2 つの安全弁を併置する:
#     - `$REPO/.beads`（root 台帳）は除外対象にしない（`.gitignore` に `.beads/` を書く repo で
#       root 台帳ごと落ちると「候補 0＝未導入＝OK」に化ける）。
#     - 「フィルタ前候補が 1 件以上あるのに評価対象が 0 件」は **COND2: UNKNOWN**。`OK` を返すのは
#       「候補 0 かつ除外 0」＝本当に台帳が無いときだけ。走査自体が不完全なら
#       `COND2-NOTE: SCAN-INCOMPLETE` + UNKNOWN（部分走査の結果を CLEAN と言わない）。
#
# 正規化仕様（sc-vbre の beads-bdw plugin 側 guard と同一契約。lib 共有は別便）:
#   先頭 `git+` 除去 / ssh 形 `git@host:owner/repo` を `https://host/owner/repo` へ写像 /
#   素の絶対パスを `file://` へ写像 / scheme・host を小文字化しユーザ情報を除去 /
#   既定ポート除去（https:443 / http:80 / ssh:22 / git:9418）/
#   **network scheme（http / https / git / ssh）を https へ畳む**（同一 repo の別 transport 表記を同一視）/
#   path の連続スラッシュ圧縮と `.` / `..` の字句解決 /
#   末尾 `/` と末尾 `.git` を除去。
#   path の大小文字は既定で保存するが、**大小文字を区別しない既知ホスト**（github.com 等の白名リスト）
#   では比較時のみ path も小文字化する。表示は元表記。
#
# usage:
#   check-ledger-separation.sh [--repo <path>] [--quiet]
#       機械条件 2 本を判定する（既定 mode）。
#   check-ledger-separation.sh --assert-not-code-repo <url> [--repo <path>] [--quiet]
#       「この URL はコード面ではない」ことだけを判定する（rc 0=コード面でない / 1=コード面と一致 /
#       2=判定不能）。`bd dolt remote add` の **前** に呼ぶ wire ゲート用。wire してから検査すると
#       レジストリに残留し、以後の自動 push で公開面へ出てしまう（不可逆）ため、判定は wire より前に置く。
#
# env:
#   LEDGER_SEP_LSREMOTE_TIMEOUT  git ls-remote の timeout 秒（既定 20）。
#   LEDGER_SEP_BD_TIMEOUT        bd 呼出（where / dolt remote list）の timeout 秒（既定 20）。

set -uo pipefail

REPO=""
QUIET=0
MODE="check"
ASSERT_URL=""
LS_TIMEOUT="${LEDGER_SEP_LSREMOTE_TIMEOUT:-20}"
BD_TIMEOUT="${LEDGER_SEP_BD_TIMEOUT:-20}"

# 大小文字を区別しない既知ホスト（比較時のみ path を小文字化する）
CI_HOSTS="github.com www.github.com gitlab.com www.gitlab.com bitbucket.org codeberg.org dev.azure.com ssh.dev.azure.com"

TMPFILES=()
cleanup() { [ "${#TMPFILES[@]}" -gt 0 ] && rm -f -- "${TMPFILES[@]}" 2>/dev/null; return 0; }
trap cleanup EXIT

die_unknown() { printf '%s\n' "check-ledger-separation: $1" >&2; printf 'RESULT: UNKNOWN\n'; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)
      # 値の存在を検査してから shift する。値欠落で `shift 2` が失敗すると $1 が消費されないまま
      # ループが回り続け、無出力の busy loop になる（rc も返らない）。引数不正は未知 arg と同じ rc=2。
      [ $# -ge 2 ] || die_unknown "--repo に値が必要（引数不正）"
      REPO="$2"; shift 2 ;;
    --assert-not-code-repo)
      [ $# -ge 2 ] || die_unknown "--assert-not-code-repo に値が必要（引数不正）"
      MODE="assert"; ASSERT_URL="$2"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help)
      # ヘッダ（先頭の連続コメント行）を全部出す。固定行数の sed だと加筆でヘッダが切れる。
      awk 'NR==1 && /^#!/ { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
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
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# path の連続スラッシュ圧縮 + `.` / `..` の字句解決（存在しないパスでも解決できる＝realpath -m 相当）
norm_path() {
  local p="${1:-}" seg out=""
  local -a segs=() stack=()
  IFS='/' read -ra segs <<< "$p"
  for seg in ${segs[@]+"${segs[@]}"}; do
    case "$seg" in
      ''|.) ;;
      ..) [ "${#stack[@]}" -gt 0 ] && stack=("${stack[@]:0:${#stack[@]}-1}") ;;
      *) stack+=("$seg") ;;
    esac
  done
  for seg in ${stack[@]+"${stack[@]}"}; do out="$out/$seg"; done
  [ -z "$out" ] && out="/"
  printf '%s' "$out"
}

normalize_url() {
  local u="${1:-}"
  [ -z "$u" ] && { printf ''; return 0; }
  # 前後の空白・引用符を剥がす
  u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
  u="${u#\"}"; u="${u%\"}"; u="${u#\'}"; u="${u%\'}"
  # 先頭 git+ を除去（bd の sync.remote は git+<url> 形）
  u="${u#git+}"
  # scp 形 ssh（user@host:owner/repo）を ssh:// 形へ写像（scheme 正規化は下でまとめて行う）
  if [[ "$u" != *"://"* && "$u" =~ ^[^/@]+@([^:/]+):(.+)$ ]]; then
    u="ssh://${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  fi
  # 素の絶対パスを file:// へ写像（`git remote get-url` は素のパスを返す一方、bd の sync.remote は
  # scheme 必須ゆえ file:// 形で書かれる。両者を同一視しないと local remote 構成で違反を見落とす）
  if [[ "$u" != *"://"* && "$u" == /* ]]; then
    u="file://$u"
  fi
  if [[ "$u" =~ ^([A-Za-z][A-Za-z0-9+.-]*)://([^/]*)(.*)$ ]]; then
    local sch host rest port=""
    sch="$(lc "${BASH_REMATCH[1]}")"
    host="$(lc "${BASH_REMATCH[2]}")"
    rest="${BASH_REMATCH[3]}"
    host="${host##*@}"                      # userinfo を落とす
    # 既定ポートを畳む（元 scheme に対応する既定値だけを除去する）
    case "$host" in
      *:*) port="${host##*:}"; host="${host%:*}" ;;
    esac
    if [ -n "$port" ]; then
      case "$sch:$port" in
        https:443|http:80|ssh:22|git:9418) port="" ;;
      esac
    fi
    # network scheme を https へ畳む（同一 repo の別 transport 表記を同一視する）
    case "$sch" in
      http|https|git|ssh) sch="https" ;;
    esac
    # path の連続スラッシュ圧縮と . / .. の解決
    rest="$(norm_path "$rest")"
    # 大小文字を区別しない既知ホストでは比較用に path も小文字化
    local h
    for h in $CI_HOSTS; do
      if [ "$host" = "$h" ]; then rest="$(lc "$rest")"; break; fi
    done
    [ -n "$port" ] && host="${host}:${port}"
    u="${sch}://${host}${rest}"
  fi
  # 末尾 / と 末尾 .git を除去
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  u="${u%.git}"
  while [ "${u%/}" != "$u" ]; do u="${u%/}"; done
  printf '%s' "$u"
}

url_like() {   # $1 = 生の値。URL/パス形に見えるか（`bd dolt remote list` の列取り違えを弾く）
  case "${1:-}" in
    git+*://*|*://*) return 0 ;;
    /*)              return 0 ;;
    *@*:*)           return 0 ;;
    *)               return 1 ;;
  esac
}

ls_remote_url() {  # $1 = URL（remote 名ではなく URL を直接渡す）, $2 = ref パターン
  if command -v timeout >/dev/null 2>&1; then
    GIT_TERMINAL_PROMPT=0 timeout "$LS_TIMEOUT" git -C "$REPO" ls-remote "$1" "$2" 2>/dev/null
  else
    GIT_TERMINAL_PROMPT=0 git -C "$REPO" ls-remote "$1" "$2" 2>/dev/null
  fi
}

bd_run() {   # bd を有界化して呼ぶ（hang すると Step 0 / Step 末ゲートが返らない）
  if command -v timeout >/dev/null 2>&1; then
    env -u BEADS_DIR timeout "$BD_TIMEOUT" bd "$@" 2>/dev/null
  else
    env -u BEADS_DIR bd "$@" 2>/dev/null
  fi
}

ledger_is_live() {   # $1 = .beads dir。DB 実体を持つ＝この機械で稼働している台帳
  [ -d "$1/embeddeddolt" ] && return 0
  local f
  for f in "$1"/*.db; do [ -e "$f" ] && return 0; done
  return 1
}

# --- git が使えるかの弁別（「origin 未設定」と「git 実行不能」を混ぜない） --------
if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
  say "check-ledger-separation: $REPO を git repo として読めない（非 git or git 実行不能）→ 判定不能"
  printf 'COND1: UNKNOWN\n'
  printf 'COND2: UNKNOWN\n'
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi

# --repo が git toplevel でない（repo 内のサブディレクトリ等）と走査範囲が欠けて「未導入」に化ける。
_top="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || _top=""
if [ -n "$_top" ]; then
  _top="$(cd "$_top" 2>/dev/null && pwd -P)" || _top=""
fi
if [ -n "$_top" ] && [ "$_top" != "$REPO" ]; then
  printf 'REPO-NOTE: NORMALIZED-TO-TOPLEVEL\n'
  say "check-ledger-separation: --repo が git toplevel でないので toplevel へ正規化した"
  say "  指定: $REPO → toplevel: $_top"
  REPO="$_top"
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

CODE_IDS=()        # 正規化済みの code-identity 集合（条件 2 / assert の比較対象）
CODE_LABELS=()     # 同じ添字で「どの面か」のラベル（VIOLATION 行に出す）
SCAN_LABELS=()     # 条件 1 で走査する面のラベル
SCAN_URLS=()       # 条件 1 で走査する生 URL（remote 名ではなく URL を直接渡す）
CODE_MODE=""       # origin | all-remotes | no-remote
PATH_ONLY=0        # code-identity が repo 自パスのみ
UNRESOLVED=()      # URL を 1 本も解決できなかった remote 名

# $1 = 生 URL, $2 = ラベル, $3 = scan に載せるか（1/0）
add_code_id() {
  local raw="$1" label="$2" scan="${3:-1}" n i
  n="$(normalize_url "$raw")"
  [ -z "$n" ] && return 1
  for i in "${!CODE_IDS[@]}"; do
    [ "${CODE_IDS[$i]}" = "$n" ] && return 0     # 正規化後に同一＝去重
  done
  CODE_IDS+=("$n"); CODE_LABELS+=("$label")
  if [ "$scan" = "1" ]; then SCAN_LABELS+=("$label"); SCAN_URLS+=("$raw"); fi
  return 0
}

say "[check-ledger-separation] repo=$REPO"
if [ "${#REMOTE_NAMES[@]}" -gt 0 ]; then
  if [ "$HAS_ORIGIN" -eq 1 ]; then CODE_MODE="origin"; else CODE_MODE="all-remotes"; fi
  for r in "${REMOTE_NAMES[@]}"; do
    n_for_remote=0
    idx=0
    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      n_for_remote=$((n_for_remote + 1))
      lbl="$r"; [ "$idx" -gt 0 ] && lbl="$r#$idx"
      add_code_id "$raw" "$lbl" 1
      say "  code 面 $lbl (fetch): $raw  (正規化: $(normalize_url "$raw"))"
      idx=$((idx + 1))
    done <<< "$(git -C "$REPO" remote get-url --all "$r" 2>/dev/null)"
    idx=0
    while IFS= read -r raw; do
      [ -n "$raw" ] || continue
      n_for_remote=$((n_for_remote + 1))
      lbl="$r#push"; [ "$idx" -gt 0 ] && lbl="$r#push$idx"
      if add_code_id "$raw" "$lbl" 1; then
        say "  code 面 $lbl: $raw  (正規化: $(normalize_url "$raw"))"
      fi
      idx=$((idx + 1))
    done <<< "$(git -C "$REPO" remote get-url --push --all "$r" 2>/dev/null)"
    if [ "$n_for_remote" -eq 0 ]; then
      # URL を 1 本も解決できない remote を黙って落とすと、その面を指す台帳を検出できない（fail-open）。
      UNRESOLVED+=("$r")
      say "  code 面 $r: URL を解決できない → 判定不能として記録する（drop しない）"
    fi
  done
  if [ "${#CODE_IDS[@]}" -eq 0 ] && [ "${#UNRESOLVED[@]}" -eq 0 ]; then
    say "  remote の URL を 1 本も取得できない → 判定不能"
    printf 'COND1: UNKNOWN\n'
    printf 'COND2: UNKNOWN\n'
    printf 'RESULT: UNKNOWN\n'
    exit 2
  fi
  # repo 自身のパスも code-identity に入れる（台帳を自リポへ向ける形も違反として検出する）。
  # 走査対象には載せない（自リポの ref 走査は条件 1 の趣旨＝外部公開面の検査から外れる）。
  add_code_id "$REPO" "<repo 自身のパス>" 0
  if [ "$CODE_MODE" = "all-remotes" ]; then
    say "  origin が無い（remote: ${REMOTE_NAMES[*]}）→ 正準面を特定できないので条件 1 は最終 UNKNOWN。"
    say "  条件 2 は全 remote の URL を比較対象にして判定を続ける。"
  fi
else
  CODE_MODE="no-remote"
  PATH_ONLY=1
  add_code_id "$REPO" "<repo 自身のパス>" 0
  say "  git remote が 0 本＝台帳が出て行く公開面が無い。条件 1 は N/A、条件 2 は repo 自身のパスを"
  say "  code-identity の fallback にして判定を続ける（正規化: ${CODE_IDS[0]}）。"
  say "  ※ URL 形（https://… 等）の台帳先はこの repo と機械照合できない＝人間が確認すること。"
fi

MATCHED_LABEL=""
is_code_repo() {   # $1 = 正規化済み URL。一致したら MATCHED_LABEL に面のラベルを入れて 0 を返す
  local n="${1:-}" i
  MATCHED_LABEL=""
  [ -z "$n" ] && return 1
  for i in "${!CODE_IDS[@]}"; do
    if [ -n "${CODE_IDS[$i]}" ] && [ "$n" = "${CODE_IDS[$i]}" ]; then
      MATCHED_LABEL="${CODE_LABELS[$i]}"
      return 0
    fi
  done
  return 1
}

# --- assert mode: wire 前ゲート ------------------------------------------------
if [ "$MODE" = "assert" ]; then
  [ "$PATH_ONLY" -eq 1 ] && printf 'COND2-NOTE: CODE-IDENTITY-PATH-ONLY\n'
  a_norm="$(normalize_url "$ASSERT_URL")"
  if [ -z "$a_norm" ]; then
    say "  assert: URL を正規化できない（空）→ 判定不能"
    printf 'ASSERT-NOT-CODE-REPO: UNKNOWN\n'
    exit 2
  fi
  if is_code_repo "$a_norm"; then
    say "  assert: 与えられた URL はこの repo のコード面と一致する（面=$MATCHED_LABEL / 正規化: $a_norm）"
    say "    → 台帳をコード面へ wire してはならない。wire せず停止すること。"
    printf 'ASSERT-NOT-CODE-REPO: VIOLATION remote=%s\n' "$MATCHED_LABEL"
    exit 1
  fi
  if [ "${#UNRESOLVED[@]}" -gt 0 ]; then
    # 比較集合に穴があるので「コード面でない」と断定できない。
    say "  assert: URL を解決できない remote がある（${UNRESOLVED[*]}）→ 判定不能"
    printf 'ASSERT-NOT-CODE-REPO: UNKNOWN\n'
    exit 2
  fi
  say "  assert: 与えられた URL はコード面ではない（正規化: $a_norm）→ wire 可"
  printf 'ASSERT-NOT-CODE-REPO: OK\n'
  exit 0
fi

violation=0
unknown=0

# --- 条件 1: コード面に refs/dolt/* が 0 件か（per-URL → 合成） ------------------
if [ "$CODE_MODE" = "no-remote" ]; then
  say "  条件1: OK（N/A）— git remote が 0 本＝台帳が出て行く公開面が無い"
  printf 'COND1: OK\n'
  printf 'COND1-NOTE: NO-GIT-REMOTE\n'
else
  c1_viol=0
  c1_unk=0
  for r in ${UNRESOLVED[@]+"${UNRESOLVED[@]}"}; do
    printf 'COND1 %s: UNKNOWN\n' "$r"
    say "    面 $r: UNKNOWN — remote の URL を解決できない（走査も比較もできない）"
    c1_unk=1
  done
  for i in ${SCAN_URLS[@]+"${!SCAN_URLS[@]}"}; do
    lbl="${SCAN_LABELS[$i]}"; u="${SCAN_URLS[$i]}"
    ls_out="$(ls_remote_url "$u" 'refs/dolt/*')"; ls_rc=$?
    if [ "$ls_rc" -ne 0 ]; then
      printf 'COND1 %s: UNKNOWN\n' "$lbl"
      say "    面 $lbl: UNKNOWN — git ls-remote が rc=$ls_rc（到達不能・認証不能・timeout 等）"
      c1_unk=1
      continue
    fi
    n_refs=0
    if [ -n "$ls_out" ]; then
      n_refs="$(printf '%s\n' "$ls_out" | grep -c '[^[:space:]]')"
    fi
    if [ "$n_refs" -eq 0 ]; then
      printf 'COND1 %s: OK\n' "$lbl"
      say "    面 $lbl: OK — refs/dolt/* が **ref listing に無い**（object の到達可能性は別問題）"
    else
      printf 'COND1 %s: VIOLATION refs=%s\n' "$lbl" "$n_refs"
      say "    面 $lbl: VIOLATION — refs/dolt/* が ${n_refs} 件（台帳がこの面に出ている）"
      say "$(printf '%s\n' "$ls_out" | sed 's/^/      /')"
      c1_viol=1
    fi

    # 補助検出: dolt の git-remote 実装は台帳 push 時に `refs/heads/__dolt_remote_info__` も作るため
    # glob `refs/dolt/*` では拾えない。条件 1 が OK でも台帳由来 ref が残りうるので per-URL で surface する。
    # rc の意味は変えない（既存 ref の削除は破壊操作＝人間承認事案で reconciler の裁量外）。
    extra_out="$(ls_remote_url "$u" '*__dolt*')"; extra_rc=$?
    if [ "$extra_rc" -ne 0 ]; then
      printf 'COND1-EXTRA %s: UNKNOWN\n' "$lbl"
    elif [ -n "$extra_out" ]; then
      while IFS= read -r line; do
        [ -z "$line" ] && continue
        ref="${line##*$'\t'}"
        case "$ref" in refs/dolt/*) continue ;; esac
        printf 'COND1-EXTRA: DOLT-REF-OUTSIDE-GLOB %s\n' "$ref"
        say "  条件1 補助（面 $lbl）: 台帳由来 ref が refs/dolt/* の外に残存 — $ref"
        say "    （削除は破壊操作＝人間承認事案。rc は変えない＝報告のみ）"
      done <<< "$extra_out"
    fi
  done

  if [ "$c1_viol" -eq 1 ]; then
    say "  条件1: VIOLATION（上の面ラベルを見て、コード面か台帳 repo 登録かを弁別すること）"
    printf 'COND1: VIOLATION\n'
    violation=1
  elif [ "$c1_unk" -eq 1 ]; then
    say "  条件1: UNKNOWN — 1 つ以上の面を確認できなかった"
    printf 'COND1: UNKNOWN\n'
    unknown=1
  elif [ "$CODE_MODE" = "all-remotes" ]; then
    say "  条件1: UNKNOWN — 各面に refs/dolt/* は無いが、origin が無く正準面を特定できない"
    printf 'COND1: UNKNOWN\n'
    unknown=1
  else
    say "  条件1: OK — 全ての面で refs/dolt/* が ref listing に無い"
    printf 'COND1: OK\n'
  fi

  # 走査を行った run では、条件 1 が測ったのが「listing の不在」であって「object の不在」ではないことを
  # 機械可読に明示する（ref を消しても object は remote に残り匿名 fetch で取れる場合がある＝実測）。
  # この注記は rc を変えない。露出の完全解消（remote 側 GC / repo 再作成）は人間の判断事項。
  if [ "${#SCAN_URLS[@]}" -gt 0 ]; then
    printf 'COND1-NOTE: REF-LISTING-ONLY\n'
    say "  ※ 条件1 は ref listing の不在のみを測る。ref を削除しても object は remote に残りうる"
    say "    （匿名 fetch で到達可能な実測あり）。listing が空でも「露出が消えた」証明にはならない。"
  fi
fi

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
# 除外は「git-ignored かつ live でない」の単一述語に一本化する（ディレクトリ名の事前 prune は
# live 安全弁より前段で効いてしまい、prune 対象配下の live 台帳を不可視にする＝fail-open）。
scan_out="$(mktemp 2>/dev/null)" || scan_out=""
scan_err="$(mktemp 2>/dev/null)" || scan_err=""
[ -n "$scan_out" ] && TMPFILES+=("$scan_out")
[ -n "$scan_err" ] && TMPFILES+=("$scan_err")

if [ -z "$scan_out" ] || [ -z "$scan_err" ]; then
  say "  条件2: 一時ファイルを作れず走査結果を検証できない → 判定不能"
  printf 'COND2-NOTE: SCAN-INCOMPLETE\n'
  printf 'COND2: UNKNOWN\n'
  unknown=1
else
  # prune は `.git` のみ（内部構造を走査しないため）。`.beads` は symlink であることもある。
  find "$REPO" -name .git -prune -o \( -name .beads \( -type d -o -type l \) \) -print \
    > "$scan_out" 2> "$scan_err"
  find_rc=$?

  scan_incomplete=0
  if [ "$find_rc" -ne 0 ] || [ -s "$scan_err" ]; then
    scan_incomplete=1
  fi

  BEADS_CANDIDATES=()
  while IFS= read -r c; do [ -n "$c" ] && BEADS_CANDIDATES+=("$c"); done < <(LC_ALL=C sort "$scan_out")

  n_cand=0
  n_skipped=0
  BEADS_DIRS=()
  for cand in ${BEADS_CANDIDATES[@]+"${BEADS_CANDIDATES[@]}"}; do
    [ -d "$cand" ] || continue          # symlink 先が dir でないものは台帳ではない
    n_cand=$((n_cand + 1))
    # 安全弁 1: root 台帳は除外対象にしない
    if [ "$cand" = "$REPO/.beads" ]; then
      BEADS_DIRS+=("$cand")
      continue
    fi
    # 安全弁 2: git-ignored でも **live**（DB 実体を持つ）台帳は評価する。
    # ephemeral な worktree checkout は DB を持たないので、除外の目的（他 cell の stale config を
    # 数えない）は保たれる。live を落とすと、その台帳が公開面を指していても CLEAN になる。
    if git -C "$REPO" check-ignore -q -- "$cand" 2>/dev/null; then
      if ledger_is_live "$cand"; then
        say "  条件2: git-ignored だが live（DB 実体あり）なので評価する: ${cand#"$REPO"/}"
      else
        n_skipped=$((n_skipped + 1))
        say "  条件2: skip — git-ignored かつ DB 実体なし（ephemeral コピー）: ${cand#"$REPO"/}"
        continue
      fi
    fi
    BEADS_DIRS+=("$cand")
  done

  if [ "$scan_incomplete" -eq 1 ]; then
    say "  条件2: 走査が不完全（find rc=$find_rc / stderr あり）→ 部分結果を CLEAN と言わない"
    [ -s "$scan_err" ] && say "$(sed 's/^/    /' "$scan_err")"
    printf 'COND2-NOTE: SCAN-INCOMPLETE\n'
    printf 'COND2: UNKNOWN\n'
    unknown=1
  elif [ "$n_cand" -eq 0 ]; then
    say "  条件2: 判定対象の .beads が無い（未導入）"
    printf 'COND2: OK\n'
  elif [ "${#BEADS_DIRS[@]}" -eq 0 ]; then
    # 安全弁 3: 候補は在ったのに全て除外された。OK に畳むと「除外規則そのもの」が fail-open になる。
    say "  条件2: UNKNOWN — 候補 $n_cand 件すべてが除外され（skip $n_skipped 件）評価対象が 0 件"
    say "    除外規則が広すぎるか、台帳が ephemeral な場所にしか無い。OK には畳まない。"
    printf 'COND2: UNKNOWN\n'
    unknown=1
  else
    [ "$PATH_ONLY" -eq 1 ] && printf 'COND2-NOTE: CODE-IDENTITY-PATH-ONLY\n'
    cond2_violation=0
    cond2_unknown=0
    strip_prefix="$REPO/"; [ "$REPO" = "/" ] && strip_prefix="/"
    for bdir in "${BEADS_DIRS[@]}"; do
      rel="${bdir#"$strip_prefix"}"
      cfg="$bdir/config.yaml"
      parent="$(dirname "$bdir")"

      # config.yaml が在るのに読めないときは ABSENT（緑）にせず UNKNOWN（fail-open 封鎖）
      cfg_unreadable=0
      if [ -e "$cfg" ] && [ ! -r "$cfg" ]; then
        cfg_unreadable=1
        printf 'COND2-NOTE: CONFIG-UNREADABLE\n'
        say "    $rel config.yaml が在るが読めない → 2a/2b は UNKNOWN（ABSENT に畳まない）"
      fi

      # (2a)
      if [ "$cfg_unreadable" -eq 1 ]; then
        printf 'COND2 %s 2a: UNKNOWN\n' "$rel"
        cond2_unknown=1
      else
        if [ -f "$cfg" ]; then flat="$(parse_flat_remote "$cfg")"; else flat=""; fi
        if [ -z "$flat" ]; then
          printf 'COND2 %s 2a: ABSENT\n' "$rel"
          say "    $rel 2a col0 sync.remote: (無し)"
        else
          while IFS= read -r u; do
            [ -z "$u" ] && continue
            nu="$(normalize_url "$u")"
            if is_code_repo "$nu"; then
              printf 'COND2 %s 2a: VIOLATION remote=%s\n' "$rel" "$MATCHED_LABEL"
              say "    $rel 2a col0 sync.remote: $u → VIOLATION（コード面 $MATCHED_LABEL を指している）"
              cond2_violation=1
            else
              printf 'COND2 %s 2a: OK\n' "$rel"
              say "    $rel 2a col0 sync.remote: $u → OK"
            fi
          done <<< "$flat"
        fi
      fi

      # (2b)
      if [ "$cfg_unreadable" -eq 1 ]; then
        printf 'COND2 %s 2b: UNKNOWN\n' "$rel"
        cond2_unknown=1
      else
        if [ -f "$cfg" ]; then nested="$(parse_nested_remote "$cfg")"; else nested=""; fi
        if [ -z "$nested" ]; then
          printf 'COND2 %s 2b: ABSENT\n' "$rel"
          say "    $rel 2b nested sync:.remote: (無し)"
        else
          while IFS= read -r u; do
            [ -z "$u" ] && continue
            nu="$(normalize_url "$u")"
            if is_code_repo "$nu"; then
              printf 'COND2 %s 2b: VIOLATION remote=%s\n' "$rel" "$MATCHED_LABEL"
              say "    $rel 2b nested sync:.remote: $u → VIOLATION（コード面 $MATCHED_LABEL を指している）"
              cond2_violation=1
            else
              printf 'COND2 %s 2b: OK\n' "$rel"
              say "    $rel 2b nested sync:.remote: $u → OK"
            fi
          done <<< "$nested"
        fi
      fi

      # (2c) 真の決定点: dolt の remote レジストリ。**検査対象の台帳へ pin する**。
      #   `bd where` の path 行と database: 行の 2 情報で pin する（path だけでは、DB を持たない .beads で
      #   path に cwd を返しつつ database だけ祖先台帳を指す状態を通してしまう＝masking）。
      #   出力行数は bd の版・構成で変わるので行番号ではなくキーで拾う。
      # `| head -1` は使わない（pipefail 下で bd が SIGPIPE を踏むと rc が化ける）。全文を捕捉して解析する。
      where_out="$(cd "$parent" 2>/dev/null && bd_run where)"; where_rc=$?
      if [ "$where_rc" -ne 0 ] || [ -z "$where_out" ]; then
        printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
        say "    $rel 2c bd where: rc=$where_rc → UNKNOWN（bd の解決先を確認できない＝台帳を pin できない）"
        cond2_unknown=1
        continue
      fi
      resolved="$(awk '/^\// { print; exit }' <<< "$where_out")"
      resolved="${resolved%"${resolved##*[![:space:]]}"}"; resolved="${resolved%/}"
      dbpath="$(awk '/^[[:space:]]*database:[[:space:]]*/ {
                       sub(/^[[:space:]]*database:[[:space:]]*/, ""); print; exit }' <<< "$where_out")"
      dbpath="${dbpath%"${dbpath##*[![:space:]]}"}"; dbpath="${dbpath%/}"

      if [ -z "$resolved" ]; then
        printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
        say "    $rel 2c bd where の出力から active な台帳 path を読めない → UNKNOWN"
        cond2_unknown=1
        continue
      fi
      # symlink 台帳では bd が実体パスを返しうるので、physical でも比較する
      bdir_phys="$(cd "$bdir" 2>/dev/null && pwd -P)" || bdir_phys="$bdir"
      if [ "$resolved" != "${bdir%/}" ] && [ "$resolved" != "$bdir_phys" ]; then
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
        "${bdir%/}"|"${bdir%/}"/*|"$bdir_phys"|"$bdir_phys"/*) ;;
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

      dolt_out="$(cd "$parent" 2>/dev/null && bd_run dolt remote list)"; dolt_rc=$?
      if [ "$dolt_rc" -ne 0 ]; then
        printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
        say "    $rel 2c bd dolt remote list: rc=$dolt_rc → UNKNOWN（実 push 先を確認できない）"
        cond2_unknown=1
        continue
      fi
      # remote 行の有無と「URL 形の値を取れたか」を分けて数える（列を取り違えて非 URL を URL 扱いしない）
      n_lines=0; n_urls=0
      while IFS= read -r line; do
        [ -z "${line//[[:space:]]/}" ] && continue
        n_lines=$((n_lines + 1))
        u="$(awk '{ print $2 }' <<< "$line")"
        url_like "$u" || continue
        n_urls=$((n_urls + 1))
        nu="$(normalize_url "$u")"
        if is_code_repo "$nu"; then
          printf 'COND2 %s 2c: VIOLATION remote=%s\n' "$rel" "$MATCHED_LABEL"
          say "    $rel 2c bd dolt remote list: $u → VIOLATION（実 push 先がコード面 $MATCHED_LABEL）"
          cond2_violation=1
        else
          printf 'COND2 %s 2c: OK\n' "$rel"
          say "    $rel 2c bd dolt remote list: $u → OK"
        fi
      done <<< "$dolt_out"
      if [ "$n_lines" -eq 0 ]; then
        printf 'COND2 %s 2c: ABSENT\n' "$rel"
        say "    $rel 2c bd dolt remote list: (remote 未設定＝local-only)"
      elif [ "$n_urls" -eq 0 ]; then
        printf 'COND2 %s 2c: UNKNOWN\n' "$rel"
        say "    $rel 2c remote 行は在るが URL 形の値を取れない（出力形が想定外）→ UNKNOWN"
        cond2_unknown=1
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
fi

# --- 総合判定（VIOLATION > UNKNOWN > CLEAN） ----------------------------------
if [ "$violation" -eq 1 ]; then
  say "  → 台帳がコード面と分離されていない。bd dolt push しないこと。"
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

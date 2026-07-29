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
#   2 = UNKNOWN   （到達不能・認証不能・timeout・bd 実行不能等で判定できなかった）
# 違反と判定不能が同時に出た場合は 1（違反）を優先する（より強い信号を返す）。
#
# 条件 1 の 3 値判定:
#   rc=0 かつ 0 行            → OK
#   rc=0 かつ 1 行以上        → VIOLATION（台帳が公開面に出ている）
#   rc≠0                      → UNKNOWN（fail-loud。決して OK に畳まない）
#   ※ `git ls-remote ... | grep -q` のようにパイプで rc を捨てる形は使わない（out/rc を必ず捕捉する）。
#
# 条件 2 の判定（部分一致禁止・3 経路 OR）:
#   比較は「正規化後の完全一致」。1 経路でもコード repo を指したら VIOLATION（OR で赤・AND で緑にしない）。
#     (2a) col0 平坦の `sync.remote:` 行
#     (2b) nested `sync:` ブロックの `remote:`
#     (2c) `bd dolt remote list` の実 push 先 ← **これが真の決定点**
#   2c を欠く実装は受け入れない: dolt エンジンは config.yaml とは別の自前 remote レジストリを持つため、
#   config だけを見る検査は 2026-07-27 incident そのものの状態（config は private・実 push 先はコード repo）を
#   green と報告してしまう。
#   適用単位は git root の .beads ではなく **repo 内に実在する全 .beads**（本 repo は root と cc-session/ の 2 台帳）。
#
# 正規化仕様（sc-vbre の beads-bdw plugin 側 guard と同一契約。lib 共有は別便）:
#   先頭 `git+` 除去 / ssh 形 `git@host:owner/repo` を `https://host/owner/repo` へ写像 /
#   `ssh://` scheme を `https` へ写像しユーザ情報を除去 / scheme・host を小文字化 /
#   末尾 `/` と末尾 `.git` を除去。path の大小文字は保存する。
#
# usage: check-ledger-separation.sh [--repo <path>] [--quiet]
#   --repo   検査対象の git repo（既定: cwd の git root）
#   --quiet  詳細行を抑止し RESULT 行のみ出す

set -uo pipefail

REPO=""
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)  REPO="${2:-}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    -h|--help) sed -n '1,50p' "$0"; exit 0 ;;
    *) printf 'check-ledger-separation: unknown arg: %s\n' "$1" >&2; exit 2 ;;
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

# --- コード repo の URL ------------------------------------------------------
CODE_URL_RAW="$(git -C "$REPO" remote get-url origin 2>/dev/null)"; code_rc=$?
if [ "$code_rc" -ne 0 ] || [ -z "$CODE_URL_RAW" ]; then
  say "check-ledger-separation: コード repo の origin remote を解決できない（判定不能）"
  printf 'COND1: UNKNOWN\n'
  printf 'COND2: UNKNOWN\n'
  printf 'RESULT: UNKNOWN\n'
  exit 2
fi
CODE_URL="$(normalize_url "$CODE_URL_RAW")"

say "[check-ledger-separation] repo=$REPO"
say "  code-repo: $CODE_URL_RAW  (正規化: $CODE_URL)"

violation=0
unknown=0

# --- 条件 1: コード repo に refs/dolt/* が 0 件か ------------------------------
# rc を必ず捕捉する（grep -q へパイプして rc を捨てる形は使わない＝fail-open の芽）。
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
mapfile -t BEADS_DIRS < <(find "$REPO" -name .beads -type d -not -path '*/.git/*' 2>/dev/null | LC_ALL=C sort)

if [ "${#BEADS_DIRS[@]}" -eq 0 ]; then
  say "  条件2: 判定対象の .beads が無い（未導入）"
  printf 'COND2: OK\n'
else
  cond2_violation=0
  cond2_unknown=0
  for bdir in "${BEADS_DIRS[@]}"; do
    rel="${bdir#"$REPO"/}"; [ "$rel" = "$bdir" ] && rel=".beads"
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
        if [ "$nu" = "$CODE_URL" ]; then
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
        if [ "$nu" = "$CODE_URL" ]; then
          printf 'COND2 %s 2b: VIOLATION\n' "$rel"
          say "    $rel 2b nested sync:.remote: $u → VIOLATION（コード repo を指している）"
          cond2_violation=1
        else
          printf 'COND2 %s 2b: OK\n' "$rel"
          say "    $rel 2b nested sync:.remote: $u → OK"
        fi
      done <<< "$nested"
    fi

    # (2c) 真の決定点: dolt の remote レジストリ
    dolt_out="$(cd "$parent" 2>/dev/null && bd dolt remote list 2>/dev/null)"; dolt_rc=$?
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
          if [ "$nu" = "$CODE_URL" ]; then
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

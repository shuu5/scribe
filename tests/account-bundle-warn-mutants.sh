#!/usr/bin/env bash
# tests/account-bundle-warn-mutants.sh — sc-zwzs（orch-c1df leg3）多重束ね warn の **変異対照**。
#
# なぜ要るか: 「非発火 fixture で 0 行」だけを見る teeth は、機能を丸ごと殺しても常に green のまま通る
# （負条件 grep 単独・非発火のみは vacuous）。本 harness は **temp 複製に warn 出力を潰す変異**を入れ、
# 発火側 assert が RED へ flip することを一次出力で示す（= teeth が実際に機能へ接続されている証明）。
#
# 変異は必ず temp 複製へ入れる（原本は 1 byte も触らない。末尾で sha256 と git status の同値を機械照合する）。
# 変異版が「単に壊れて何も出せない」だけでないことを **生存対照**で示す（bash -n 通過 + UNKNOWN 経路は
# 依然 1 行出る = script は起動し判定も回っている。潰したのは WARN 出力だけ）。
#
# fail-closed: 期待に 1 つでも反したら非 0 で終了する。
set -uo pipefail

R="$(git rev-parse --show-toplevel)" || { echo "FATAL: repo root を解決できません（fail-closed）"; exit 2; }
HELPER_SRC="$R/scripts/scribe-account-bundle-warn"
[[ -f "$HELPER_SRC" ]] || { echo "FATAL: $HELPER_SRC がありません"; exit 2; }

SHA_BEFORE="$(sha256sum "$HELPER_SRC" | awk '{print $1}')"
ST_BEFORE="$(git -C "$R" status --porcelain -- scripts tests | sort)"

TMP="$(mktemp -d)" || { echo "FATAL: mktemp 失敗"; exit 2; }
cleanup() {
  # worktree を作る実起動を回すので、後始末は anchor ごと消す前に worktree 登録を解除する。
  if [[ -d "$TMP/anchor" ]]; then
    git -C "$TMP/anchor" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}' \
      | while read -r w; do [[ "$w" == "$TMP/anchor" ]] || git -C "$TMP/anchor" worktree remove --force "$w" >/dev/null 2>&1; done
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

FAIL=0
note() { printf '%s\n' "$*"; }
expect_eq() {  # $1=実測 $2=期待 $3=説明
  if [[ "$1" == "$2" ]]; then note "  PASS  $3（実測=$1）"
  else note "  FAIL  $3（実測=$1 / 期待=$2）"; FAIL=1; fi
}

# ---------------------------------------------------------------------------
# 発火 fixture（bats T-FIRE と同型: 採用=black4 に live 2 本）
# ---------------------------------------------------------------------------
NOW="2026-07-08T12:00:00+00:00"
ANCHOR="$TMP/anchor"; mkdir -p "$ANCHOR"
git -C "$ANCHOR" -c init.defaultBranch=main init -q
git -C "$ANCHOR" config user.email t@e; git -C "$ANCHOR" config user.name t
git -C "$ANCHOR" commit -q --allow-empty -m init

ABASE="$TMP/acctbase"
mkdir -p "$ABASE/black4/plugins/scribe" "$ABASE/black4/plugins/beads-bdw" "$ABASE/black4/plugins/cmdtokens"
printf '{}' > "$ABASE/black4/.credentials.json"
printf '{"hasCompletedOnboarding":true}' > "$ABASE/black4/.claude.json"

cat > "$TMP/golden.json" <<JSON
{ "as_of": "$NOW", "accounts": [
  {"label":"black2","ok":true,"stale":false,"five_hour_pct":43,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":97,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black4","ok":true,"stale":false,"five_hour_pct":18,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":96,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}
] }
JSON

printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/noop.sh"; chmod +x "$TMP/noop.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/bd.sh";   chmod +x "$TMP/bd.sh"

LIVE="$(printf '101\t%s\n102\t%s\n103\t%s' "$ABASE/black4" "$ABASE/black4" "$ABASE/black2")"

# <scripts-dir> <bd-id> → stderr に出た行頭 `account-bundle: ` の物理行数を stdout へ
fire_count() {
  local sdir="$1" id="$2" err="$TMP/err.$2.txt"
  # ★env の -u は NAME=VALUE より前に置く（GNU env はオプションを先に読む。後置すると `-u` が
  #   コマンド名と解釈され、spawn が 1 度も起動しないまま「0 行」＝偽の flip 成立になる）。
  env -u CLAUDE_CONFIG_DIR -u SCRIBE_ACCOUNT_BUNDLE_DISABLE -u SCRIBE_LIVE_ACTORS_CMD \
      SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$TMP/golden.json")" \
      SCRIBE_ACCOUNTS_BASE="$ABASE" SCRIBE_BD="$TMP/bd.sh" BEADS_BDW="$TMP/noop.sh" \
      SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$TMP/noop.sh" SCRIBE_LIVE_ACTORS="$LIVE" \
      "$sdir/scribe-spawn.sh" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto "$id" \
      >/dev/null 2>"$err"
  grep -c '^account-bundle: ' "$err" || true
}

# <scripts-dir> <bd-id> → stderr に出た `account-bundle-unknown: reason=probe-blind` の物理行数を stdout へ。
# 母集団 0 行（probe が「エラーではなく 0 件」を返す形＝PID namespace 下の実行文脈と同型）× claude セッション内。
blind_count() {
  local sdir="$1" id="$2" err="$TMP/errb.$2.txt"
  env -u CLAUDE_CONFIG_DIR -u SCRIBE_ACCOUNT_BUNDLE_DISABLE -u SCRIBE_LIVE_ACTORS \
      SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$TMP/golden.json")" \
      SCRIBE_ACCOUNTS_BASE="$ABASE" SCRIBE_BD="$TMP/bd.sh" BEADS_BDW="$TMP/noop.sh" \
      SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$TMP/noop.sh" SCRIBE_LIVE_ACTORS_CMD=true CLAUDECODE=1 \
      "$sdir/scribe-spawn.sh" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto "$id" \
      >/dev/null 2>"$err"
  grep -c '^account-bundle-unknown: reason=probe-blind ' "$err" || true
}

# ---------------------------------------------------------------------------
# 0) 原本（GREEN 対照）: 発火側 assert が実際に立っていること
# ---------------------------------------------------------------------------
note "[0] 原本（未変異）で発火側 assert が green であること"
expect_eq "$(fire_count "$R/scripts" mut-orig)" "1" "原本: 行頭 account-bundle: が 1 物理行"
expect_eq "$(blind_count "$R/scripts" mut-orig-b)" "1" "原本: 盲目の弁別が probe-blind を 1 物理行"

# ---------------------------------------------------------------------------
# 変異版の生成（temp 複製）
# ---------------------------------------------------------------------------
mk_mutant() {  # $1=名前 $2=sed 式
  local name="$1" expr="$2" dir="$TMP/m-$1"
  rm -rf "$dir"; cp -a "$R/scripts" "$dir" || return 1
  sed -i "$expr" "$dir/scribe-account-bundle-warn" || return 1
  # 変異が実際に byte を動かしたこと（no-op 変異＝偽の生存を作らない）。
  if cmp -s "$dir/scribe-account-bundle-warn" "$HELPER_SRC"; then
    note "  FAIL  変異 '$name' が原本と同一（sed 式が当たっていない）"; FAIL=1; return 1
  fi
  printf '%s\n' "$dir"
}

# 生存対照: 変異版が「起動失敗で何も出せない」だけではないこと。
#   (a) bash -n を通る  (b) UNKNOWN 経路（seam parse 不能）は依然 1 行出る＝判定は回っている。
alive_check() {
  local dir="$1" name="$2" out rc n
  if ! bash -n "$dir/scribe-account-bundle-warn" 2>/dev/null; then
    note "  FAIL  変異 '$name' が構文エラー（起動失敗＝flip の根拠にならない）"; FAIL=1; return 1
  fi
  out="$(env SCRIBE_LIVE_ACTORS='garbage-without-tab' SCRIBE_ACCOUNTS_BASE="$ABASE" \
         "$dir/scribe-account-bundle-warn" --chosen-label black4 --chosen-dir "$ABASE/black4" 2>/dev/null)"
  rc=$?
  n="$(grep -c '^account-bundle-unknown: ' <<<"$out" || true)"
  expect_eq "$rc" "0" "変異 '$name' の生存対照: exit 0（fail-open）"
  expect_eq "$n"  "1" "変異 '$name' の生存対照: UNKNOWN 経路は依然 1 行（script は起動し判定も回る）"
}

# ---------------------------------------------------------------------------
# M1: WARN 出力の呼出そのものを潰す
# ---------------------------------------------------------------------------
note "[M1] emit_warn の呼出を潰す（warn 出力行の除去）"
if D1="$(mk_mutant m1 's|^  emit_warn "\$TARGET_LABEL".*$|  :|')"; then
  alive_check "$D1" m1
  expect_eq "$(fire_count "$D1" mut-m1)" "0" "M1: 発火側 assert が RED へ flip（1 → 0 行）"
else
  FAIL=1
fi

# ---------------------------------------------------------------------------
# M2: WARN の発火条件（live >= 1）を到達不能にする
# ---------------------------------------------------------------------------
note "[M2] WARN 条件 live >= 1 を到達不能へ書き換える"
if D2="$(mk_mutant m2 's|^if \[\[ "\$LIVE" -ge 1 \]\]; then|if [[ "$LIVE" -ge 999999 ]]; then|')"; then
  alive_check "$D2" m2
  expect_eq "$(fire_count "$D2" mut-m2)" "0" "M2: 発火側 assert が RED へ flip（1 → 0 行）"
else
  FAIL=1
fi

# ---------------------------------------------------------------------------
# M3: marker 接頭辞を壊す（行頭マッチの契約が teeth に効いていること）
# ---------------------------------------------------------------------------
note "[M3] marker 接頭辞 'account-bundle: ' を別語へ差し替える"
if D3="$(mk_mutant m3 "s|^  printf 'account-bundle: chosen=|  printf 'acct-bundle-x: chosen=|")"; then
  alive_check "$D3" m3
  expect_eq "$(fire_count "$D3" mut-m3)" "0" "M3: 行頭 marker 契約が崩れると RED へ flip（1 → 0 行）"
else
  FAIL=1
fi

# ---------------------------------------------------------------------------
# M4: 盲目の弁別（probe-blind）を潰す — 「見えていない 0」が SILENT へ畳まれて戻ることを示す
# ---------------------------------------------------------------------------
note "[M4] 盲目の弁別（emit_unknown \"probe-blind\"）を潰す"
if D4="$(mk_mutant m4 's|^  emit_unknown "probe-blind".*$|  :|')"; then
  alive_check "$D4" m4
  # 潰すと母集団 0 行は live=0 として SILENT へ落ちる＝警告機能が無言で死ぬ側へ戻る。
  expect_eq "$(blind_count "$D4" mut-m4)" "0" "M4: 盲目側 assert が RED へ flip（1 → 0 行）"
  # 対照: WARN 経路は M4 で壊れていない（変異が盲目判定だけに効いていることの弁別）。
  expect_eq "$(fire_count "$D4" mut-m4f)" "1" "M4 の限局性: WARN 経路は依然 1 行（盲目判定だけを潰した）"
else
  FAIL=1
fi

# ---------------------------------------------------------------------------
# 原本無改変の機械照合
# ---------------------------------------------------------------------------
note "[X] 原本無改変（変異は temp 複製にのみ入れた）"
SHA_AFTER="$(sha256sum "$HELPER_SRC" | awk '{print $1}')"
ST_AFTER="$(git -C "$R" status --porcelain -- scripts tests | sort)"
expect_eq "$SHA_AFTER" "$SHA_BEFORE" "原本 helper の sha256 が実行前後で同値"
if [[ "$ST_AFTER" == "$ST_BEFORE" ]]; then note "  PASS  git status（scripts/ tests/）が実行前後で同値"
else note "  FAIL  git status が変化した:"; diff <(printf '%s\n' "$ST_BEFORE") <(printf '%s\n' "$ST_AFTER") || true; FAIL=1; fi
note "  git diff --stat（原本側の一次出力）:"
git -C "$R" diff --stat -- scripts/scribe-account-bundle-warn scripts/scribe-spawn.sh | sed 's/^/    /'

if [[ "$FAIL" -eq 0 ]]; then
  note "MUTANTS: PASS（原本 green / 4 変異とも該当 assert が RED へ flip / 生存対照つき / 原本無改変）"
  exit 0
fi
note "MUTANTS: FAIL"
exit 1

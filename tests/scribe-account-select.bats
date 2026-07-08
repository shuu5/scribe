#!/usr/bin/env bats
# tests/scribe-account-select.bats — sc-1rq「--account auto（claude-usage 残量 maximin 自動選択）」の
# 出荷物 self-test（IMPLEMENTATION CONTRACT 2026-07-08 のテスト要件を committed bats として固定する）。
#
# なぜ committed か: 契約は self-test を **plugin 出荷物**（= scribe-spawn.sh + 新 scribe-account-select と
# 並ぶ deliverable）として必須化する。worker の untracked `selftest-<id>.local.sh` は gate 用の使い捨てで
# あり、100−pct の逆選択回帰ピン（取り違え=バグと契約が警告）や GOLDEN acceptance を将来にわたって
# 固定する resident な回帰網は committed でなければ果たせない。本 file が その資産（tests/scribe-tools.bats と
# 同姿勢：dry-run + スタブのみ・実 spawn/実 tmux/実 claude/実 bd は起こさない）。
#
# 決定性の seam（live 非依存）:
#   ・selector 入力 = env SCRIBE_USAGE_JSON / `--stdin`（claude-usage を exec しない）。
#   ・比較基準時刻 = env SCRIBE_USAGE_NOW（resets_at 比較を固定・過去/未来を決定化）。
#   ・spawn の bd 実在検証 = SCRIBE_BD スタブ（実 graph 非依存）。cld-spawn/sandbox/bdw も全てスタブ。
#
# ★VERIFIED セマンティクス（回帰ピンの核心）: five_hour_pct/seven_day_pct = utilization(使用率)。
#   残量% = 100 − pct。pct を残量と読むと maximin が枯渇寸前アカを選ぶ逆選択バグ（S12/S1b が pin）。

bats_require_minimum_version 1.5.0

NOW="2026-07-08T12:00:00+00:00"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  SEL="$SCRIPTS/scribe-account-select"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  # host 側の usage/config-dir env が漏れてテストを汚さないよう毎回落とす（hermetic）。
  unset SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD SCRIBE_USAGE_NOW \
        CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE 2>/dev/null || true

  # bd 実在検証スタブ（実 graph 不要）。dry-run 統合テストは実在 id が要るので sc-auto-test を ok に。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="sc-auto-test"
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true

  # anchor/repo = 使い捨て git repo（host パス・実 scribe repo に非依存）。
  ANCHOR="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/anchor.XXXXXX")" && pwd -P)"
  git -C "$ANCHOR" -c init.defaultBranch=main init -q
  git -C "$ANCHOR" config user.email t@e; git -C "$ANCHOR" config user.name t
  git -C "$ANCHOR" commit -q --allow-empty -m init

  ABASE="$BATS_TEST_TMPDIR/acctbase"
  NOTE_LOG="$BATS_TEST_TMPDIR/note.log"
  # bdw スタブ（監査 note を記録＝実 bd を触らない）。scribe-spawn は scripts/bdw 経由で BEADS_BDW を exec する。
  BDW_STUB="$BATS_TEST_TMPDIR/bdw_stub.sh"
  cat > "$BDW_STUB" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTE_LOG"
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--append-notes" ]] && printf 'NOTE:%s\n' "\$a" >> "$NOTE_LOG"
  prev="\$a"
done
exit 0
STUB
  chmod +x "$BDW_STUB"
  NOOP="$BATS_TEST_TMPDIR/noop.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"

  _write_fixtures
}

# ---- 現ロスター golden + 契約列挙ケースの fixture 群（$BATS_TEST_TMPDIR へ） ----
_write_fixtures() {
  GOLDEN="$BATS_TEST_TMPDIR/golden.json"
  cat > "$GOLDEN" <<JSON
{ "as_of": "$NOW", "accounts": [
  {"label":"default","email":null,"ok":true,"stale":false,"error":null,
   "five_hour_pct":0,"five_hour_resets_at":null,"five_hour_remaining":"",
   "seven_day_pct":100,"seven_day_resets_at":"2026-07-14T00:00:00+00:00","seven_day_remaining":"5d"},
  {"label":"black2","email":null,"ok":true,"stale":false,"error":null,
   "five_hour_pct":43,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":97,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black3","email":null,"ok":false,"stale":true,"error":"認証切れ(/login 要)",
   "five_hour_pct":10,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":20,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black4","email":null,"ok":true,"stale":false,"error":null,
   "five_hour_pct":18,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":96,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"phito","email":null,"ok":false,"stale":true,"error":"認証切れ(/login 要)"}
] }
JSON

  ZERO="$BATS_TEST_TMPDIR/zero.json"
  cat > "$ZERO" <<JSON
{ "accounts": [
  {"label":"a","ok":false,"stale":true},
  {"label":"b","ok":false,"stale":false,"error":"接続不可"}
] }
JSON

  KEYMISS="$BATS_TEST_TMPDIR/keymiss.json"
  cat > "$KEYMISS" <<JSON
{ "accounts": [
  {"label":"good","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"bad","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null}
] }
JSON

  TIE="$BATS_TEST_TMPDIR/tie.json"
  cat > "$TIE" <<JSON
{ "accounts": [
  {"label":"zeta","ok":true,"stale":false,"five_hour_pct":50,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":50,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"},
  {"label":"alpha","ok":true,"stale":false,"five_hour_pct":50,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":50,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"}
] }
JSON

  NULLR="$BATS_TEST_TMPDIR/nullreset.json"
  cat > "$NULLR" <<JSON
{ "accounts": [
  {"label":"x","ok":true,"stale":false,"five_hour_pct":90,"five_hour_resets_at":null,"seven_day_pct":90,"seven_day_resets_at":null}
] }
JSON

  PASTR="$BATS_TEST_TMPDIR/pastreset.json"
  cat > "$PASTR" <<JSON
{ "accounts": [
  {"label":"x","ok":true,"stale":false,"five_hour_pct":95,"five_hour_resets_at":"2026-07-08T09:00:00+00:00","seven_day_pct":95,"seven_day_resets_at":"2026-07-08T09:00:00+00:00"}
] }
JSON

  PCTPIN="$BATS_TEST_TMPDIR/pctpin.json"
  cat > "$PCTPIN" <<JSON
{ "accounts": [
  {"label":"busy","ok":true,"stale":false,"five_hour_pct":90,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":90,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"},
  {"label":"idle","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":10,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"}
] }
JSON

  AMBIG="$BATS_TEST_TMPDIR/ambig.json"
  cat > "$AMBIG" <<JSON
{ "accounts": [
  {"label":"amb","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,"five_hour_remaining":"","seven_day_pct":5,"seven_day_resets_at":"2026-07-14T00:00:00+00:00","seven_day_remaining":""}
] }
JSON

  ONLYDEF="$BATS_TEST_TMPDIR/onlydefault.json"
  cat > "$ONLYDEF" <<JSON
{ "accounts": [
  {"label":"default","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,"seven_day_pct":0,"seven_day_resets_at":null},
  {"label":"other","ok":false,"stale":true}
] }
JSON

  # usage 側は適格だが preflight 全滅を作る fixture（非 default のみ＝~/.claude へ写像されない）。
  # config dir を一切作らなければ全候補 preflight 不通過 → resolve 末尾 fail-loud を引く（facet⑤②(b)）。
  PFAIL="$BATS_TEST_TMPDIR/pfail.json"
  cat > "$PFAIL" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"acctB","ok":true,"stale":false,"five_hour_pct":20,"five_hour_resets_at":null,"seven_day_pct":20,"seven_day_resets_at":null}
] }
JSON
}

# selector を SCRIBE_USAGE_JSON seam で回す（$1=fixture file・残りは argv）。
sel() { SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$1")" python3 "$SEL" "${@:2}"; }
# 適格ラベルを上位順に返す（呼出元 lazy walk と同じ awk）。
walk() { sel "$1" | awk -F'\t' '$2=="1"{print $1}'; }
# golden 実行から label 行 1 本を取り出す。
row_of() { sel "$GOLDEN" | awk -F'\t' -v l="$1" '$1==l{print; exit}'; }

# 有効 config dir を作る（$1=dir・env NO_PLUGIN=<name> で当該 plugin を欠落注入）。
mk_cfg() {
  local d="$1"; mkdir -p "$d"
  printf '{}' > "$d/.credentials.json"
  printf '{"hasCompletedOnboarding":true}' > "$d/.claude.json"
  local p
  for p in scribe beads-bdw cmdtokens; do
    [[ "${NO_PLUGIN:-}" == "$p" ]] && continue
    mkdir -p "$d/plugins/$p"
  done
}

# ============================================================================
# selector 単体（純粋計算・fs 非接触）
# ============================================================================

@test "sc-1rq selector: GOLDEN ランキング=black4>black2>default・black3/phito(stale)除外" {
  local got; got="$(walk "$GOLDEN" | paste -sd, -)"
  [ "$got" = "black4,black2,default" ]
  # 除外アカは walk に載らない
  [[ "$(walk "$GOLDEN")" != *black3* ]]
  [[ "$(walk "$GOLDEN")" != *phito* ]]
}

@test "sc-1rq selector: 100−pct 変換の値ピン（black4 score=4/h5=82/h7=4・default score=0/h5=100）" {
  local r; r="$(row_of black4)"
  local _l _e _score _h5 _h7 _rest
  IFS=$'\t' read -r _l _e _score _h5 _h7 _rest <<<"$r"
  [ "$_score" = "4" ]      # min(82,4)
  [ "$_h5" = "82" ]        # 100-18
  [ "$_h7" = "4" ]         # 100-96
  r="$(row_of default)"
  IFS=$'\t' read -r _l _e _score _h5 _h7 _rest <<<"$r"
  [ "$_score" = "0" ]      # min(100, 100-100)=0
  [ "$_h5" = "100" ]       # resets_at null → 満残量
}

@test "sc-1rq selector: 除外理由に stale が入る（black3）" {
  [[ "$(row_of black3)" == *stale* ]]
}

@test "sc-1rq selector[a]: API故障=JSON不正 → exit3・stdout空（理由は stderr）" {
  # stdout/stderr を分離（--separate-stderr）: 契約は「stdout 空 + stderr に理由」。
  run --separate-stderr env SCRIBE_USAGE_JSON='{bad json' python3 "$SEL"
  [ "$status" -eq 3 ]
  [ -z "$output" ]           # $output=stdout（空）
  [[ "$stderr" == *"API 故障"* ]]
}

@test "sc-1rq selector[a]: API故障=claude-usage 不在 → exit3" {
  run env -u SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[a]: API故障=claude-usage 非0 exit → exit3" {
  local stub="$BATS_TEST_TMPDIR/usage_nz.sh"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$stub"; chmod +x "$stub"
  run env -u SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD="$stub" python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[a]: API故障=accounts キー不在 → exit3" {
  run env SCRIBE_USAGE_JSON='{"as_of":"x"}' python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[a]: API故障=accounts 空 → exit3" {
  run env SCRIBE_USAGE_JSON='{"accounts":[]}' python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[b]: 適格0件（全 stale/not-ok）→ exit0・eligible 0 行" {
  run sel "$ZERO"
  [ "$status" -eq 0 ]
  [ -z "$(walk "$ZERO")" ]
}

@test "sc-1rq selector[c]: 個別アカ キー欠落 → 当該除外し続行（good は残る・bad は malformed）" {
  [ "$(walk "$KEYMISS")" = "good" ]
  [[ "$(sel "$KEYMISS" | awk -F'\t' '$1=="bad"')" == *malformed* ]]
}

@test "sc-1rq selector[d]: 同点 → label 辞書順（alpha,zeta）" {
  [ "$(walk "$TIE" | paste -sd, -)" = "alpha,zeta" ]
}

@test "sc-1rq selector[e]: resets_at null → 満残量（pct90 でも h5=100）" {
  local r _l _e _sc _h5 _rest
  r="$(sel "$NULLR" | awk -F'\t' '$1=="x"')"
  IFS=$'\t' read -r _l _e _sc _h5 _rest <<<"$r"
  [ "$_h5" = "100" ]
}

@test "sc-1rq selector[f]: resets_at 過去 → 満残量（pct95 でも h5=100）" {
  local r _l _e _sc _h5 _rest
  r="$(sel "$PASTR" | awk -F'\t' '$1=="x"')"
  IFS=$'\t' read -r _l _e _sc _h5 _rest <<<"$r"
  [ "$_h5" = "100" ]
}

@test "sc-1rq selector[g]: pct誤読回帰ピン — idle(残量90)>busy(残量10)・busy h5=100−90=10" {
  # pct を残量と誤読すれば busy(pct90) が上位に来てこの assert が落ちる。
  [ "$(walk "$PCTPIN" | paste -sd, -)" = "idle,busy" ]
  local r _l _e _sc _h5 _rest
  r="$(sel "$PCTPIN" | awk -F'\t' '$1=="busy"')"
  IFS=$'\t' read -r _l _e _sc _h5 _rest <<<"$r"
  [ "$_h5" = "10" ]
}

@test "sc-1rq selector: 曖昧ケース fixture(pct=0,remaining='',resets_at=null) → crash なし・h5=100/h7=95" {
  run sel "$AMBIG"
  [ "$status" -eq 0 ]
  local r _l _e _sc _h5 _h7 _rest
  r="$(sel "$AMBIG" | awk -F'\t' '$1=="amb"')"
  IFS=$'\t' read -r _l _e _sc _h5 _h7 _rest <<<"$r"
  [ "$_h5" = "100" ]      # null reset
  [ "$_h7" = "95" ]       # 100-5
}

@test "sc-1rq selector: stdin seam（--stdin < fixture）でも同一ランキング" {
  local got
  got="$(SCRIBE_USAGE_NOW="$NOW" python3 "$SEL" --stdin < "$GOLDEN" | awk -F'\t' '$2=="1"{print $1}' | paste -sd, -)"
  [ "$got" = "black4,black2,default" ]
}

# ============================================================================
# scribe-spawn.sh --account auto 統合（dry-run + スタブのみ・実 spawn しない）
# ============================================================================

@test "sc-1rq spawn: dry-run auto plan — ランキング可視化 + top-by-usage=black4 + 注入=base/black4" {
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *black4* ]]
  [[ "$output" == *"top-by-usage）=black4"* ]]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=$ABASE/black4"* ]]
  [[ "$output" == *"--account auto（sc-1rq"* ]]
}

@test "sc-1rq spawn: 適格0件 → fail-loud（実起動・resolve 内で die）" {
  # fake id（BD_STUB_OK_IDS 外）だが resolve→die が bd 実在検査より前に走るので到達前に停止する。
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$ZERO")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-none
  [ "$status" -ne 0 ]
  [[ "$output" == *"適格アカウントが 0 件"* ]]
}

@test "sc-1rq spawn: 適格あり but preflight 全滅 → fail-loud（実起動・resolve 末尾 die・facet⑤②(b)）" {
  # sc-1rq finding2: usage 適格0件（上のテスト）とは別 modality＝usage は適格だが全候補の
  # login/onboarding/plugin が欠落。config dir を一切作らないので acctA/acctB 双方 preflight 不通過→末尾 die。
  # リファクタで末尾 die が return 0（主アカ fallback）へ化けたら status=0 になりこの assert が捕える（fail-open 回帰網）。
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$PFAIL")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-pfail
  [ "$status" -ne 0 ]
  [[ "$output" == *"preflight を全て不通過"* ]]
}

@test "sc-1rq spawn: API故障 fallback（admin config dir 保持）→ mirror（preflight 対象化・finding1）" {
  # sc-1rq finding1: 旧実装は ~/.claude(unset)をハードコードし preflight を skip → 非 ~/.claude admin で
  # guard 欠落 dir に無防備 worker を起こす fail-open。mirror なら WCFG_DIR 非空で preflight_config_dir が採用 dir を検査する。
  : > "$NOTE_LOG"
  mk_cfg "$ABASE/adminacct"
  run env -u SCRIBE_USAGE_JSON CLAUDE_CONFIG_DIR="$ABASE/adminacct" \
    SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-fbmirror
  [[ "$output" == *"mirror=$ABASE/adminacct"* ]]
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"fallback=yes"* ]]
  [[ "$notes" == *"FALLBACK:mirror"* ]]
}

@test "sc-1rq spawn: 既存 --account LABEL 経路は不変（auto をラベルと誤解しない）" {
  run env SCRIBE_ACCOUNTS_BASE=/acct/base CLAUDE_CONFIG_DIR=/admin/dir \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account alice sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=/acct/base/alice"* ]]
  [[ "$output" == *"源=account"* ]]
  [[ "$output" != *"--account auto（sc-1rq"* ]]
}

@test "sc-1rq spawn: 素経路（--account 未指定）は unset 注入で不変・auto plan 混入なし" {
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"unset CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" != *maximin* ]]
}

@test "sc-1rq spawn: lazy walk — 上位 black4(plugin欠落)を skip し black2 を採用（実起動）" {
  mk_cfg "$ABASE/black2"
  NO_PLUGIN=scribe mk_cfg "$ABASE/black4"
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-walk
  [[ "$output" == *"候補 'black4'"* ]]
  [[ "$output" == *"'black2' を採用"* ]]
}

@test "sc-1rq spawn: default→unset 写像（dry-run・default だけ適格→export しない）" {
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$ONLYDEF")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"top-by-usage=default"* ]]
  [[ "$output" == *"unset CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" != *"export CLAUDE_CONFIG_DIR=$ABASE/default"* ]]
}

@test "sc-1rq spawn: API故障 → 主アカ fallback + 監査 note(接頭辞 account-select:・fallback=yes)" {
  : > "$NOTE_LOG"
  run env -u SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz \
    SCRIBE_ACCOUNTS_BASE="$ABASE" BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-fb
  [[ "$output" == *"主アカウント（~/.claude・unset 経路）へ fallback"* ]]
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"account-select:"* ]]
  [[ "$notes" == *"fallback=yes"* ]]
}

@test "sc-1rq spawn: 正常採用時 監査 note — 接頭辞 + chosen=black4 + 候補全員(default/除外black3)snapshot" {
  : > "$NOTE_LOG"
  mk_cfg "$ABASE/black4"; mk_cfg "$ABASE/black2"
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-note
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"chosen=black4"* ]]
  [[ "$notes" == *default* ]]     # snapshot は候補全員（適格）
  [[ "$notes" == *black3* ]]      # snapshot は除外アカも含む
}

@test "sc-1rq: 出荷物 bash/python 構文（両 deliverable）" {
  run bash -n "$SPAWN"
  [ "$status" -eq 0 ]
  run python3 -c "import ast; ast.parse(open('$SEL').read())"
  [ "$status" -eq 0 ]
}

#!/usr/bin/env bats
# tests/account-bundle-warn.bats — sc-zwzs（orch-c1df leg3）「--account auto の多重束ね抑止（Phase1 warn-only）」の
# 出荷物 self-test。判定本体 = scripts/scribe-account-bundle-warn / 発火点 = scripts/scribe-spawn.sh の採用確定枝。
#
# 決定性の seam（live 非依存）:
#   ・live actor 一覧 = env SCRIBE_LIVE_ACTORS（生データ最優先）/ SCRIBE_LIVE_ACTORS_CMD（既定=本番の実 probe）。
#   ・selector 入力 = env SCRIBE_USAGE_JSON、比較基準時刻 = SCRIBE_USAGE_NOW。
#   ・spawn の bd 実在検証 = SCRIBE_BD スタブ。cld-spawn / sandbox / bdw も全てスタブ（実 spawn は起こさない）。
#
# ★観測面の規律（bd sc-zwzs ■F4）: 発火の照合は **stub 実起動（非 dry-run）の stderr** で行う。--dry-run の
#   stdout を根拠にしてはならない（dry-run は preflight walk を行わず実起動と採用 label が食い違う）。
# ★F2: 本 leg の acceptance は live 観測の結果では判定しない。判定面は「注入 fixture に対する warn の有無」。
#   T-PROBE だけは実 probe の**選択述語**を pin するが、母集団は **本テストが自分で起こした fixture プロセス**に
#   限定して pid 単位で assert する（host の live session 数には一切依存しない）。
# ★実測件数（host の live session 数など）の literal は 1 つも焼かない（時点依存で揺れるため）。

bats_require_minimum_version 1.5.0

NOW="2026-07-08T12:00:00+00:00"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  HELPER="$SCRIPTS/scribe-account-bundle-warn"

  # host 側 env の漏れを落とす（hermetic）。
  unset SCRIBE_USAGE_JSON SCRIBE_USAGE_NOW CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR \
        SCRIBE_ACCOUNTS_BASE SCRIBE_LIVE_ACTORS SCRIBE_LIVE_ACTORS_CMD \
        SCRIBE_ACCOUNT_BUNDLE_DISABLE SCRIBE_ACCOUNT_BUNDLE_TIMEOUT 2>/dev/null || true
  export SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/scribe-no-usage-cmd"

  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  # 実起動（非 dry-run）で bd 実在検証を通すため、本 suite が使う id を全て ok にする。
  export BD_STUB_OK_IDS="sc-auto-test zz-fire zz-quiet zz-self zz-unk zz-tmo zz-oddmirror zz-fbwarn zz-koff zz-kon zz-inv zz-attr"
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true

  ANCHOR="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/anchor.XXXXXX")" && pwd -P)"
  git -C "$ANCHOR" -c init.defaultBranch=main init -q
  git -C "$ANCHOR" config user.email t@e; git -C "$ANCHOR" config user.name t
  git -C "$ANCHOR" commit -q --allow-empty -m init

  ABASE="$BATS_TEST_TMPDIR/acctbase"
  NOTE_LOG="$BATS_TEST_TMPDIR/note.log"
  CAPT_LOG="$BATS_TEST_TMPDIR/capt.log"
  export CAPT_LOG
  : > "$NOTE_LOG"; : > "$CAPT_LOG"

  BDW_STUB="$BATS_TEST_TMPDIR/bdw_stub.sh"
  cat > "$BDW_STUB" <<STUB
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--append-notes" ]] && printf '%s\n' "\$a" >> "$NOTE_LOG"
  prev="\$a"
done
exit 0
STUB
  chmod +x "$BDW_STUB"

  # cld-spawn スタブ: 注入 config dir の一次観測面（env-file 本体を capture する）。
  CAPT_STUB="$BATS_TEST_TMPDIR/capt_stub.sh"
  cat > "$CAPT_STUB" <<'STUB'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  if [[ "$prev" == "--env-file" ]]; then grep -E '^(export|unset) CLAUDE_CONFIG_DIR' "$a" >> "$CAPT_LOG" 2>/dev/null; fi
  prev="$a"
done
exit 0
STUB
  chmod +x "$CAPT_STUB"

  _write_fixtures
}

_write_fixtures() {
  # F15: 実 account label は既出（black2/black3/black4/default/phito）の範囲に留める。
  GOLDEN="$BATS_TEST_TMPDIR/golden.json"
  cat > "$GOLDEN" <<JSON
{ "as_of": "$NOW", "accounts": [
  {"label":"default","ok":true,"stale":false,"error":null,
   "five_hour_pct":0,"five_hour_resets_at":null,
   "seven_day_pct":100,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black2","ok":true,"stale":false,"error":null,
   "five_hour_pct":43,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":97,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black4","ok":true,"stale":false,"error":null,
   "five_hour_pct":18,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":96,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}
] }
JSON
  # 適格 0 件（dry-run × AUTO_CHOSEN 空の枝＝null 安全の観測面）。
  ZERO="$BATS_TEST_TMPDIR/zero.json"
  cat > "$ZERO" <<'JSON'
{ "accounts": [
  {"label":"a","ok":false,"stale":true},
  {"label":"b","ok":false,"stale":false,"error":"接続不可"}
] }
JSON
}

mk_cfg() {
  local d="$1"; mkdir -p "$d"
  printf '{}' > "$d/.credentials.json"
  printf '{"hasCompletedOnboarding":true}' > "$d/.claude.json"
  local p
  for p in scribe beads-bdw cmdtokens; do mkdir -p "$d/plugins/$p"; done
}

# 採用される account（GOLDEN の maximin 上位）= black4。その dir へ live が居る fixture（発火）と、
# 居ない fixture（非発火）。TAB 区切り・1 行 1 プロセス。
_live_fire() { printf '101\t%s\n102\t%s\n103\t%s' "$ABASE/black4" "$ABASE/black4" "$ABASE/black2"; }
_live_quiet() { printf '103\t%s\n104\t-\n105\t/nowhere/odd-dir' "$ABASE/black2"; }

# stub 実起動（非 dry-run）。$1=bd id、以降は追加 env（KEY=VAL）。
_run_spawn() {
  local id="$1"; shift
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" \
    SCRIBE_ACCOUNTS_BASE="$ABASE" BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$CAPT_STUB" \
    "$@" "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto "$id"
}

_count_warn()    { grep -c '^account-bundle: ' <<<"${1-}" || true; }
_count_unknown() { grep -c '^account-bundle-unknown: ' <<<"${1-}" || true; }

# 未追跡ファイルのうち「実際に commit され得る成果物」だけを scope 判定へ載せる。
#  ・型フィルタ（通常ファイル / symlink のみ）: CC sandbox は cwd の既知 dotfile を /dev/null の char device へ
#    null-mount する（sc-yqa・実測 crw-rw-rw- 1,3）。これは cell の env 由来であって本 cell の編集ではない。
#    判定述語は scripts/scribe-add（stage 時に型で弾く薄ラッパ）と同一＝名前リストではなく型で弾く。
#  ・hidden path（`.` で始まる path 成分を含む）を除く: 上記 sandbox 残渣と self-test の一時 log がここに来る。
#    **tracked な hidden file の変更は下の git diff 3 本が捕捉する**ので、この除外は「未追跡の env 残渣」に限る。
_untracked_deliverables() {
  local f
  while IFS= read -r -d '' f; do
    case "$f" in .*|*/.*) continue ;; esac
    if [ -h "$REPO_ROOT/$f" ]; then printf '%s\n' "$f"; continue; fi
    [ -f "$REPO_ROOT/$f" ] || continue
    printf '%s\n' "$f"
  done < <(git -C "$REPO_ROOT" ls-files -o --exclude-standard -z)
}

# ============================================================================
# 発火 / 非発火（観測面 = stub 実起動の stderr）
# ============================================================================

@test "sc-zwzs T-FIRE: 採用 account に live 1 本以上 → 行頭 account-bundle: がちょうど 1 物理行（stderr）" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-fire SCRIBE_LIVE_ACTORS="$(_live_fire)"
  [ "$status" -eq 0 ]
  [ "$(_count_warn "$stderr")" -eq 1 ]
  # 5 key が契約どおりの順序・内訳（live は fixture の 2 本・self は呼出元 env 由来で 0）。
  [[ "$stderr" == *"account-bundle: chosen=black4 live=2 self=0 unknown=0 resets5=2026-07-08T15:00:00+00:00"* ]]
  # 採用は black4 のまま（warn は採用を変えない）。
  [[ "$stderr" == *"'black4' を採用"* ]]
  # UNKNOWN 側の marker は出ない（極性の弁別）。
  [ "$(_count_unknown "$stderr")" -eq 0 ]
}

@test "sc-zwzs T-SILENT: 採用 account に live 0 本（他 account / 帰属不能のみ）→ account-bundle 行 0 行" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-quiet SCRIBE_LIVE_ACTORS="$(_live_quiet)"
  [ "$status" -eq 0 ]
  [ "$(_count_warn "$stderr")" -eq 0 ]
  [ "$(_count_unknown "$stderr")" -eq 0 ]
  [[ "$stderr" == *"'black4' を採用"* ]]
}

@test "sc-zwzs T-SELF: 呼出元自身が同一 account のとき self=1 で内訳が出る（admin を母数から外さない・F1）" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-self SCRIBE_LIVE_ACTORS="$(_live_fire)" CLAUDE_CONFIG_DIR="$ABASE/black4"
  [ "$(_count_warn "$stderr")" -eq 1 ]
  [[ "$stderr" == *" self=1 "* ]]
}

# ============================================================================
# UNKNOWN（判定不能を silent に畳まない・fail-open）
# ============================================================================

@test "sc-zwzs T-UNKNOWN-LOUD: seam 出力が parse 不能 → account-bundle-unknown: を 1 行・spawn は止めない" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-unk SCRIBE_LIVE_ACTORS="garbage-without-tab"
  [ "$status" -eq 0 ]                                   # fail-open（spawn を殺さない）
  [ "$(_count_unknown "$stderr")" -eq 1 ]
  [ "$(_count_warn "$stderr")" -eq 0 ]                  # WARN と別 marker（極性の弁別）
  [[ "$stderr" == *"account-bundle-unknown: reason=seam-parse chosen=black4"* ]]
  [[ "$stderr" == *"'black4' を採用"* ]]                # 採用 label は不変
}

@test "sc-zwzs T-UNKNOWN-TIMEOUT: probe が上限時間を超える → UNKNOWN 1 行・spawn 成立（上限 env が効く）" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-tmo SCRIBE_LIVE_ACTORS_CMD="sleep 30" SCRIBE_ACCOUNT_BUNDLE_TIMEOUT=1
  [ "$status" -eq 0 ]
  [ "$(_count_unknown "$stderr")" -eq 1 ]
  [[ "$stderr" == *"reason=probe-timeout"* ]]
}

@test "sc-zwzs T-UNKNOWN-CHOSEN: 採用 dir が label へ写像できない（API 故障 mirror 先）→ UNKNOWN 1 行" {
  # API 故障 fallback（selector exit 3）× admin の config dir が <base> 配下でも ~/.claude でもない場合。
  local odd="$BATS_TEST_TMPDIR/odd-admin-dir"; mk_cfg "$odd"
  run --separate-stderr env -u SCRIBE_USAGE_JSON CLAUDE_CONFIG_DIR="$odd" \
    SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/nonexistent-usage-cmd" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$CAPT_STUB" \
    SCRIBE_LIVE_ACTORS="$(_live_fire)" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-oddmirror
  [ "$(_count_unknown "$stderr")" -eq 1 ]
  [[ "$stderr" == *"reason=chosen-unmapped"* ]]
  [[ "$stderr" == *"mirror=$odd"* ]]                    # fallback 自体は従来どおり成立
}

@test "sc-zwzs T-FALLBACK: API 故障 fallback（mirror 先が既知 label）でも採用確定枝として warn する" {
  mk_cfg "$ABASE/black2"
  run --separate-stderr env -u SCRIBE_USAGE_JSON CLAUDE_CONFIG_DIR="$ABASE/black2" \
    SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/nonexistent-usage-cmd" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$CAPT_STUB" \
    SCRIBE_LIVE_ACTORS="$(printf '201\t%s' "$ABASE/black2")" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-fbwarn
  [ "$(_count_warn "$stderr")" -eq 1 ]
  [[ "$stderr" == *"account-bundle: chosen=black2 live=1 self=1 unknown=0 resets5=-"* ]]
}

# ============================================================================
# kill-switch（on / off の両条件）
# ============================================================================

@test "sc-zwzs T-KILL-ON: SCRIBE_ACCOUNT_BUNDLE_DISABLE=1 は完全 no-op（発火 fixture でも 0 行）" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-koff SCRIBE_LIVE_ACTORS="$(_live_fire)" SCRIBE_ACCOUNT_BUNDLE_DISABLE=1
  [ "$status" -eq 0 ]
  [ "$(_count_warn "$stderr")" -eq 0 ]
  [ "$(_count_unknown "$stderr")" -eq 0 ]
}

@test "sc-zwzs T-KILL-OFF: kill-switch 未設定なら同一 fixture で発火する（off 側の対照＝vacuity 防止）" {
  mk_cfg "$ABASE/black4"
  _run_spawn zz-kon SCRIBE_LIVE_ACTORS="$(_live_fire)"
  [ "$(_count_warn "$stderr")" -eq 1 ]
}

# ============================================================================
# warn-only 不変条件（同一入力 2 実行で差分 0）
# ============================================================================

@test "sc-zwzs T-INVARIANT: warn 有 / probe 失敗 / kill-switch 有 の 3 実行で exit code・採用 label・注入 config dir・snapshot 行数列数が同値" {
  mk_cfg "$ABASE/black4"

  : > "$NOTE_LOG"; : > "$CAPT_LOG"
  _run_spawn zz-inv SCRIBE_LIVE_ACTORS="$(_live_fire)"
  local st_warn="$status"
  local err_warn="$stderr"
  local notes_warn; notes_warn="$(cat "$NOTE_LOG")"
  local cfg_warn;   cfg_warn="$(cat "$CAPT_LOG")"
  [ "$(_count_warn "$err_warn")" -eq 1 ]                # 対照が vacuous でないこと

  sleep 1                                               # worktree/branch 名の HHMMSS 衝突回避
  : > "$NOTE_LOG"; : > "$CAPT_LOG"
  _run_spawn zz-inv SCRIBE_LIVE_ACTORS="$(_live_fire)" SCRIBE_ACCOUNT_BUNDLE_DISABLE=1
  local st_off="$status"
  local err_off="$stderr"
  local notes_off; notes_off="$(cat "$NOTE_LOG")"
  local cfg_off;   cfg_off="$(cat "$CAPT_LOG")"
  [ "$(_count_warn "$err_off")" -eq 0 ]

  # 3 実行目 = probe 失敗（UNKNOWN）。acceptance(4) は「warn 発火時 **/ probe 失敗時とも**」同値を要求する。
  # UNKNOWN は emit_warn ではなく emit_unknown（別 code path・RESETS5 固定・DRC 分岐）を通るため、warn 経路の
  # 同値では代替できない＝この 3 実行目が不変条件のもう片翼。
  sleep 1                                               # worktree/branch 名の HHMMSS 衝突回避
  : > "$NOTE_LOG"; : > "$CAPT_LOG"
  _run_spawn zz-inv SCRIBE_LIVE_ACTORS_CMD=false        # probe が非 0 終了 → reason=probe-failed
  local st_unk="$status"
  local err_unk="$stderr"
  local notes_unk; notes_unk="$(cat "$NOTE_LOG")"
  local cfg_unk;   cfg_unk="$(cat "$CAPT_LOG")"
  [ "$(_count_unknown "$err_unk")" -eq 1 ]              # 対照が vacuous でないこと（UNKNOWN 経路を実際に通った）
  [[ "$err_unk" == *"reason=probe-failed"* ]]
  [ "$(_count_warn "$err_unk")" -eq 0 ]

  # (a) exit code
  [ "$st_warn" -eq "$st_off" ]
  [ "$st_unk" -eq "$st_off" ]
  # (b) 注入 config dir（cld-spawn へ渡った env-file 本体）
  [ -n "$cfg_warn" ]
  [ "$cfg_warn" = "$cfg_off" ]
  [ "$cfg_unk" = "$cfg_off" ]
  [[ "$cfg_warn" == *"export CLAUDE_CONFIG_DIR=$ABASE/black4"* ]]
  # (c) account-select: snapshot の行数と列数
  local nl_w nl_o nl_u cols_w cols_o cols_u
  nl_w="$(grep -c '^account-select:' <<<"$notes_warn" || true)"
  nl_o="$(grep -c '^account-select:' <<<"$notes_off" || true)"
  nl_u="$(grep -c '^account-select:' <<<"$notes_unk" || true)"
  [ "$nl_w" -eq "$nl_o" ]
  [ "$nl_u" -eq "$nl_o" ]
  [ "$nl_w" -gt 0 ]
  cols_w="$(awk -F'|' '/^account-select:   /{print NF}' <<<"$notes_warn" | sort -u | tr '\n' ',')"
  cols_o="$(awk -F'|' '/^account-select:   /{print NF}' <<<"$notes_off" | sort -u | tr '\n' ',')"
  cols_u="$(awk -F'|' '/^account-select:   /{print NF}' <<<"$notes_unk" | sort -u | tr '\n' ',')"
  [ "$cols_w" = "$cols_o" ]
  [ "$cols_u" = "$cols_o" ]
  [ "$cols_w" = "10," ]
  # (d) 採用 label と、account-bundle 行（WARN / UNKNOWN の両 marker）を除いた stderr 全体
  #     （timestamp 正規化後）が完全一致
  local n_w n_o n_u
  n_w="$(grep -v '^account-bundle' <<<"$err_warn" | sed -E 's/-[0-9]{6}([^0-9]|$)/-TS\1/g')"
  n_o="$(grep -v '^account-bundle' <<<"$err_off"  | sed -E 's/-[0-9]{6}([^0-9]|$)/-TS\1/g')"
  n_u="$(grep -v '^account-bundle' <<<"$err_unk"  | sed -E 's/-[0-9]{6}([^0-9]|$)/-TS\1/g')"
  [ "$n_w" = "$n_o" ]
  [ "$n_u" = "$n_o" ]
}

# ============================================================================
# null 安全 / dry-run 否定対照
# ============================================================================

@test "sc-zwzs T-NULLSAFE: dry-run × 適格 0 件枝（AUTO_CHOSEN 空）は helper を呼ばない＝account-bundle 行 0 行" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$ZERO")" \
    SCRIBE_ACCOUNTS_BASE="$ABASE" SCRIBE_LIVE_ACTORS="$(_live_fire)" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [ "$(_count_warn "$output$stderr")" -eq 0 ]
  [ "$(_count_unknown "$output$stderr")" -eq 0 ]
  [[ "$output" == *"適格0件"* ]]
  # helper を採用情報ゼロで直叩きしたときは silent に畳まず UNKNOWN を出す（fail-open・exit 0）。
  run env SCRIBE_LIVE_ACTORS="$(_live_fire)" "$HELPER"
  [ "$status" -eq 0 ]
  [ "$(_count_unknown "$output")" -eq 1 ]
  [[ "$output" == *"reason=chosen-undetermined"* ]]
}

@test "sc-zwzs T-DRYRUN: 発火 fixture でも --dry-run では warn 本体を出さない（plan 1 行のみ）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" \
    SCRIBE_ACCOUNTS_BASE="$ABASE" SCRIBE_LIVE_ACTORS="$(_live_fire)" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [ "$(_count_warn "$output$stderr")" -eq 0 ]
  [ "$(_count_unknown "$output$stderr")" -eq 0 ]
  [ "$(grep -c '多重束ね判定（sc-zwzs' <<<"$output" || true)" -eq 1 ]
}

# ============================================================================
# 帰属（母集団・3 値・列名引き）
# ============================================================================

@test "sc-zwzs T-ATTRIB: 別 project の同一 account は計上・他 account は非計上・environ 不読と写像外は unknown" {
  # 母集団は「host 全プロセス × CLAUDE_CONFIG_DIR」であって project/cwd ではない。生データに cwd 列が
  # 無いこと自体がその構造的証拠で、同一 account の 2 本（別 project で走っていても）はともに計上される。
  mk_cfg "$ABASE/black4"
  local live
  live="$(printf '301\t%s\n302\t%s\n303\t%s\n304\t-\n305\t/not/mapped/anywhere' \
      "$ABASE/black4" "$ABASE/black4" "$ABASE/black2")"
  _run_spawn zz-attr SCRIBE_LIVE_ACTORS="$live"
  [ "$(_count_warn "$stderr")" -eq 1 ]
  # 同一 account 2 本を計上 / black2 は非計上 / environ 不読 + 写像外の 2 本を unknown（DEFAULT へ足さない）。
  [[ "$stderr" == *"chosen=black4 live=2 self=0 unknown=2 "* ]]
}

@test "sc-zwzs T-COLNAME: resets5 は snapshot の列名で引く（列を additive 挿入しても位置ずれしない）" {
  # sc-8zuu が TSV の additive 拡張を予約しているため、列位置の hardcode は将来の列追加で静かに壊れる。
  local snap_new
  snap_new="$(printf 'account-select: cols=label|eligible|newcol|score|h5|h7|pct5|pct7|resets5|resets7|reason\naccount-select:   black4|1|X|4|82|4|18|96|2026-07-08T15:00:00+00:00|2026-07-14T00:00:00+00:00|-\n')"
  run env SCRIBE_LIVE_ACTORS="$(printf '401\t%s' "$ABASE/black4")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    bash -c 'printf "%s" "$1" | "$2" --chosen-label black4 --chosen-dir "$3" --snapshot -' \
    _ "$snap_new" "$HELPER" "$ABASE/black4"
  [ "$status" -eq 0 ]
  [[ "$output" == *"resets5=2026-07-08T15:00:00+00:00"* ]]
}

# ============================================================================
# 実 probe（選択述語）— 本テストが起こした fixture プロセスだけを pid 単位で assert する
# ============================================================================

@test "sc-zwzs T-PROBE: 実 probe は pgrep -x claude で選び noise 5 型を拾わない・別 cwd の同一 account は列挙する" {
  command -v pgrep >/dev/null 2>&1
  local bin="$BATS_TEST_TMPDIR/fakebin"; mkdir -p "$bin"
  local sl; sl="$(command -v sleep)"
  local n
  for n in claude socat bwrap claude-dashboard-serve claude-science apply-seccomp; do cp "$sl" "$bin/$n"; done
  local other="$BATS_TEST_TMPDIR/other-project"; mkdir -p "$other"

  # 別 project cwd で走る同一 account の session（cwd は母集団条件ではない）。
  ( cd "$other" && exec env CLAUDE_CONFIG_DIR="$ABASE/black4" "$bin/claude" 20 ) & local pc=$!
  # ノイズ 5 型（pgrep -f なら誤 match しうる実行ファイル名）。
  local pn=() p
  for n in socat bwrap claude-dashboard-serve claude-science apply-seccomp; do
    "$bin/$n" 20 & pn+=($!)
  done
  sleep 0.5

  run "$HELPER" --probe
  local rc="$status" out="$output"
  kill "$pc" "${pn[@]}" 2>/dev/null || true

  [ "$rc" -eq 0 ]
  # 同一 account の session は別 cwd でも列挙される（config dir 付きで）。
  [[ "$out" == *"$pc"$'\t'"$ABASE/black4"* ]]
  # ノイズ 5 型は 1 本も列挙されない。
  for p in "${pn[@]}"; do
    [ "$(grep -c "^$p"$'\t' <<<"$out" || true)" -eq 0 ]
  done
}

# ============================================================================
# 静的 source assert（seam の既定が本番の実 probe であることを pin）
# ============================================================================

@test "sc-zwzs T-SOURCE: seam の既定は実 probe・帰属は pgrep -x claude + environ（pgrep -f 系を使わない）" {
  [ -x "$HELPER" ]
  # 既定が実 probe（test-only 経路を既定にすると本番が silent no-op になる）。
  run grep -F -- 'LIVE_ACTORS_CMD_DEFAULT=("$SELF" --probe)' "$HELPER"
  [ "$status" -eq 0 ]
  run grep -F -- 'pgrep -x claude' "$HELPER"
  [ "$status" -eq 0 ]
  run grep -F -- '/environ' "$HELPER"
  [ "$status" -eq 0 ]
  # pgrep -f 系は禁止（dashboard / science / socat / bwrap / apply-seccomp ラッパを誤 match する）。
  # コメント行を落としてから見る（ヘッダの「pgrep -f 系は使わない」という**説明文**で偽 RED にしない）。
  run bash -c 'sed "s/#.*//" "$1" | grep -nE "pgrep[[:space:]]+-[^[:space:]]*f"' _ "$HELPER"
  [ "$status" -ne 0 ]
  # 呼出は採用確定枝の 2 箇所のみ・helper 呼出は 1 箇所へ集約（判定の二重実装を作らない）。
  [ "$(grep -c 'warn_account_bundle ' "$SPAWN" || true)" -eq 3 ]   # 定義 1 + 呼出 2（fallback 2 枝は排他）
  [ "$(grep -cF '"$SCRIPT_DIR/scribe-account-bundle-warn"' "$SPAWN" || true)" -eq 1 ]
  # 出荷物の bash 構文。
  run bash -n "$HELPER"
  [ "$status" -eq 0 ]
}

# ============================================================================
# scope（隣接 open bead の面を 1 byte も動かさない）
# ============================================================================

@test "sc-zwzs T-SCOPE: selector と配備層に触れていない（fs 非接触契約 / 配備層 0 touch）" {
  local base; base="$(git -C "$REPO_ROOT" merge-base HEAD origin/main 2>/dev/null || true)"
  [ -n "$base" ]                                        # BASE 解決失敗は fail-closed
  local d
  d="$(git -C "$REPO_ROOT" diff --name-only "$base"...HEAD -- scriptorium-engine scripts/scribe-account-select || true)"
  [ -z "$d" ]
  d="$(git -C "$REPO_ROOT" diff --name-only -- scriptorium-engine scripts/scribe-account-select || true)"
  [ -z "$d" ]
  # selector の 10 列 hardcode と cols ヘッダは不変（sc-8zuu が同箇所の改修を予約済み）。
  run grep -F -- 'account-select: cols=label|eligible|score|h5|h7|pct5|pct7|resets5|resets7|reason' "$SPAWN"
  [ "$status" -eq 0 ]
  # permanent state（lease / counter / 状態ファイル）を新規作成しない・claude-usage の burn/pace/eta を読まない。
  run grep -nE 'burn_|pace_|eta_' "$HELPER"
  [ "$status" -ne 0 ]
  run grep -nE '>[[:space:]]*"?\$\{?(HOME|XDG_STATE_HOME|XDG_CACHE_HOME)' "$HELPER"
  [ "$status" -ne 0 ]

  # 変更 file 集合が notes ■F13 の allowlist の **部分集合**であること（base...HEAD ∪ working tree）。
  # 禁止 2 path の 0 touch だけでは「allowlist に無い第 3 の file を触った」を検出できないため、包含側も見る。
  # allowlist = F13 編集可リスト + tests/scribe-account-select.bats。後者は F13 の列挙には無いが ■F3 が
  # 「既存 bats の hermetic setup へ新 seam を必ず追加する」と明示的に義務づける面（追加しないと host の
  # live session 数に依存して既存 suite が非決定化する）。**この例外は admin ratify 済み**（bd sc-zwzs の
  # salvage note＝より具体的な ■F3 が一般的な ■F13 に優先する lex specialis。契約側の列挙漏れであって
  # 逸脱ではない）。ratify の条件は「追記のみ・削除 0 行・assert の削除 / 緩和 / catch-all 化はゼロ」ゆえ、
  # 下でその条件のうち機械照合できる面（削除行 0）を assert する（条件を散文の申し送りに留めない）。
  local allow changed out
  allow='^(scripts/scribe-account-bundle-warn|scripts/scribe-spawn\.sh|scripts/README\.md'
  allow="$allow"'|tests/account-bundle-warn\.bats|tests/account-bundle-warn-mutants\.sh'
  allow="$allow"'|tests/fixtures/[^/]+|tests/scribe-account-select\.bats)$'
  changed="$( { git -C "$REPO_ROOT" diff --name-only "$base"...HEAD
                git -C "$REPO_ROOT" diff --name-only
                git -C "$REPO_ROOT" diff --name-only --cached
                _untracked_deliverables; } | sort -u | grep -v '^$' || true )"
  [ -n "$changed" ]                                     # vacuity 防止（本 cell の変更集合は必ず非空）
  out="$(grep -vE "$allow" <<<"$changed" || true)"
  [ -z "$out" ]

  # ratify 条件の機械照合: allowlist 例外（tests/scribe-account-select.bats）への変更は **追記のみ**
  # ＝削除行 0 であること。numstat の第 2 列が削除行数で、base...HEAD と working tree の両方を見る。
  # 空（= 当該 file に変更なし）は合格。数値として読めない値（binary の '-' 等）は fail-closed で RED。
  local del
  for del in "$(git -C "$REPO_ROOT" diff --numstat "$base"...HEAD -- tests/scribe-account-select.bats | awk '{print $2}')" \
             "$(git -C "$REPO_ROOT" diff --numstat -- tests/scribe-account-select.bats | awk '{print $2}')"; do
    [ -z "$del" ] || { [[ "$del" =~ ^[0-9]+$ ]] && [ "$del" -eq 0 ]; }
  done
}

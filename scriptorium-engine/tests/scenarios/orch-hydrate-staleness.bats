#!/usr/bin/env bats
# tests/scenarios/orch-hydrate-staleness.bats
#
# orch-hydrate.sh の post-sync mirror 鮮度 cross-check（orch-rur / orch-89v ③）の hermetic 回帰。
# bd v1.1.0 の auto-export 退行で foreign mirror（.beads/issues.jsonl）が dolt DB より古いまま凍結されると
# `bd repo sync` が stale data を hydrate する（silent false-negative）。post-sync 検査は各 registered repo の
# mirror（on-disk jsonl）と live DB（`bd -C export`＝dolt 直読）の (件数, 最大 updated_at) を比較し、
# DB が新しい／件数乖離なら loud 警告する（repo 名 + 復旧コマンド）。検査失敗は全て fail-open（注記のみ）。
#
# 方式（hermetic・実 dolt/bd/bdw を一切呼ばない）:
#   - self-scope 用 fake orch 台帳（dolt_database=orch）の cwd から**実 script**を EXEC モードで起動。
#   - bdw は ORCH_HYDRATE_BDW で no-op stub（repo add|sync は exit 0）へ差し替え、実 write を封じる。
#   - bd は ORCH_HYDRATE_BD で stub（`-C <path> export` で fixture の .beads/DB_EXPORT を stdout へ返す・
#     DB_EXPORT 不在なら bd の実挙動を模し error を吐く）へ差し替える＝live DB 側を fixture で完全制御。
#   - project は ORCH_HYDRATE_PROJECTS で fixture repo に全置換・config は空 temp（＝未登録→add 経路→registered_total≥1）。
#
# 検証する契約不変条件（orch-rur acceptance 1..5）:
#   (stale-updated) DB の max_updated > mirror → ⚠️ STALE MIRROR ＋ repo 名 ＋ 復旧コマンド・exit0（acc1）
#   (stale-count)   DB の件数 ≠ mirror の件数（max 同一）→ STALE 検出（count 乖離枝・acc1）
#   (fresh)         mirror == DB → STALE 警告なし・"fresh" OK 行・exit0（acc2）
#   (skip-truthful) fresh ∧ fail-open skip 混在 → 「全…fresh」を出さず checked/skipped 分離報告
#                   （gate errata E1・検査不能を fresh 検証済みに融合しない false reassurance 防止）
#   (failopen-bd)   bd -C export が有効 issue 0 件（bd read 失敗 or 空 DB）→ 注記のみ・警告なし・exit0（acc3）
#   (failopen-nojsonl) issues.jsonl 不在（mirror 未生成）→ 注記のみ・警告なし・exit0（acc3）
#   (parse-skip)    issues.jsonl に json.loads 不能な破損行混入 → _mirror_stats が有効行のみ計数し
#                   fail-open で継続（STALE 誤検出なし・破損行を issue に数えない・exit0）（acc1/acc3）
#   (failopen-nopython) PATH から python3 除去 → 「python3 不在のため … skip（fail-open）」注記・
#                   検査自体を走らせず（STALE 出さず）exit0（acc3・契約明示の 4 modality を完全 lock）
#   (exit-unchanged) stale 検出は exit code を変えない（stale ∧ fresh 混在でも exit0・acc1/acc4）
#   (dryrun-plan)   --dry-run は bd を呼ばず「would cross-check mirror staleness」plan のみ（acc4 無退行）
#   (readonly)      検査で bd に export 以外（write verb）を渡さない＝read-only 規律（bd stub がログ）
#   (syntax)        bash -n が通る
#
# 実行: bats tests/scenarios/orch-hydrate-staleness.bats

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    SCRIPT="$REPO/scripts/orch-hydrate.sh"

    TEST_TMPDIR="$(mktemp -d -t orch-hydrate-stale-XXXXXX)"

    # self-scope 用 fake orch 台帳（dolt_database=orch）。この cwd から script を走らせる。
    ORCH="$TEST_TMPDIR/orch"
    mkdir -p "$ORCH/.beads"
    printf '{"dolt_database":"orch"}\n' > "$ORCH/.beads/metadata.json"

    # 空 config（登録済み判定を確実に「未登録」にする＝add 経路→registered_total≥1）。
    CONFIG="$TEST_TMPDIR/config.yaml"
    : > "$CONFIG"

    # sync 鮮度マーカーは temp へ（自台帳 .beads を汚さない）。
    MARKER="$TEST_TMPDIR/last-sync"

    # bd に渡された verb を記録するログ（read-only 規律の検証用）。
    BD_LOG="$TEST_TMPDIR/bd-invocations.log"

    # no-op bdw stub（repo add|sync を exit 0・実 write なし）。
    FAKE_BDW="$TEST_TMPDIR/bdw"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_BDW"
    chmod +x "$FAKE_BDW"

    # bd stub: `bd -C <path> export` のみ実装。fixture の .beads/DB_EXPORT を live DB 表現として返す。
    FAKE_BD="$TEST_TMPDIR/bd"
    cat > "$FAKE_BD" <<EOF
#!/usr/bin/env bash
# fake bd for orch-hydrate staleness bats. Supports only: bd -C <path> export
echo "\$*" >> "$BD_LOG"
dir=""; prev=""; want_export=0
for a in "\$@"; do
  case "\$prev" in
    -C|--directory) dir="\$a" ;;
  esac
  [ "\$a" = "export" ] && want_export=1
  prev="\$a"
done
if [ "\$want_export" -eq 1 ]; then
  if [ -n "\$dir" ] && [ -f "\$dir/.beads/DB_EXPORT" ]; then
    cat "\$dir/.beads/DB_EXPORT"; exit 0
  fi
  # DB を開けない実挙動を模す（v1.0.4 実測: error を出しつつ exit 0）＝有効 issue 0 件で fail-open へ倒す
  echo "Error: failed to open database: embeddeddolt"; exit 0
fi
exit 0
EOF
    chmod +x "$FAKE_BD"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# 1 行 1 issue の jsonl レコード（bd export 形式）を print。
_issue() { printf '{"_type":"issue","id":"%s","title":"t","updated_at":"%s"}\n' "$1" "$2"; }

# fixture repo を作る: <name>。以後 <TEST_TMPDIR>/<name> に .beads/ を持つ。
_mkrepo() {
    local name="$1"
    mkdir -p "$TEST_TMPDIR/$name/.beads"
    printf '%s' "$TEST_TMPDIR/$name"
}

# python3 を含まない PATH shim dir を作り、その絶対 path を print する（failopen-nopython 用）。
# 現 PATH の全 dir から実行可能物を symlink し、python3 / python 系のみ除外する＝script が要する他コマンド
# （env/bash/dirname/date/jq/sed/head/cat…）は保つが `command -v python3` だけを確実に失敗させる。
_nopython_bin() {
    local bin="$TEST_TMPDIR/nopy-bin"
    mkdir -p "$bin"
    local d cmd base
    local dirs; IFS=: read -ra dirs <<< "$PATH"
    for d in "${dirs[@]}"; do
        [ -d "$d" ] || continue
        for cmd in "$d"/*; do
            [ -f "$cmd" ] || continue          # dir/socket は除外（実ファイル/symlink のみ）
            base="$(basename "$cmd")"
            case "$base" in python3*|python|python2*) continue ;; esac   # python 系のみ除外
            [ -e "$bin/$base" ] || ln -s "$cmd" "$bin/$base" 2>/dev/null || true
        done
    done
    printf '%s' "$bin"
}

# fake orch 台帳の cwd で実 script を EXEC モードで hermetic 実行（bd/bdw/config/marker を stub 化）。
run_hydrate() {
    local projects="$1"; shift
    run bash -c "cd '$ORCH' && \
        ORCH_HYDRATE_PROJECTS='$projects' \
        ORCH_HYDRATE_CONFIG='$CONFIG' \
        ORCH_HYDRATE_BDW='$FAKE_BDW' \
        ORCH_HYDRATE_BD='$FAKE_BD' \
        ORCH_HYDRATE_SYNC_MARKER='$MARKER' \
        bash '$SCRIPT' \"\$@\"" -- "$@"
}

# ==============================================================================
# (stale-updated) DB の max_updated > mirror → STALE MIRROR 警告（repo 名 + 復旧コマンド）・exit0
# ==============================================================================
@test "(stale-updated) DB が mirror より新しい → STALE MIRROR 警告 + repo名 + 復旧コマンド・exit0" {
    local p; p="$(_mkrepo scribe)"
    _issue s-1 "2026-07-06T10:00:00Z" > "$p/.beads/issues.jsonl"       # mirror（凍結・古い）
    _issue s-1 "2026-07-08T10:00:00Z" > "$p/.beads/DB_EXPORT"          # live DB（新しい）

    run_hydrate "scribe=$p"
    [ "$status" -eq 0 ]                                   # 警告は WARNING であって error でない
    [[ "$output" == *"STALE MIRROR: scribe"* ]]          # repo 名を含む loud 警告
    [[ "$output" == *"bdw export -o .beads/issues.jsonl"* ]]  # 復旧コマンド
    [[ "$output" == *"max_updated=2026-07-06T10:00:00Z"* ]]   # mirror 側の実値
    [[ "$output" == *"max_updated=2026-07-08T10:00:00Z"* ]]   # DB 側の実値
}

# ==============================================================================
# (stale-count) 件数乖離（max 同一・DB に余分な issue）→ STALE 検出（count 乖離枝）
# ==============================================================================
@test "(stale-count) 件数乖離（max 同一・DB に余分な issue）→ STALE 検出・exit0" {
    local p; p="$(_mkrepo cc-session)"
    { _issue c-1 "2026-07-06T10:00:00Z"; _issue c-2 "2026-07-06T10:00:00Z"; } > "$p/.beads/issues.jsonl"      # n=2
    { _issue c-1 "2026-07-06T10:00:00Z"; _issue c-2 "2026-07-06T10:00:00Z"; _issue c-3 "2026-07-06T10:00:00Z"; } > "$p/.beads/DB_EXPORT"  # n=3・max 同一

    run_hydrate "cc-session=$p"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE MIRROR: cc-session"* ]]
    [[ "$output" == *"n=2"* ]]
    [[ "$output" == *"n=3"* ]]
    # gate errata E2: 件数乖離は双方向発火ゆえ headline は方向中立（「古い」と断定しない・「乖離」で述べる）。
    [[ "$output" == *"内容が乖離"* ]]                     # 方向中立の文言
    [[ "$output" != *"dolt DB より古い"* ]]              # 件数乖離枝で片方向の「古い」を言わない
}

# ==============================================================================
# (fresh) mirror == DB → STALE 警告なし・"fresh" OK 行・exit0
# ==============================================================================
@test "(fresh) mirror == DB → STALE 警告なし・OK(fresh) 行・exit0" {
    local p; p="$(_mkrepo projalpha)"
    _issue u-1 "2026-07-07T12:00:00Z" > "$p/.beads/issues.jsonl"
    _issue u-1 "2026-07-07T12:00:00Z" > "$p/.beads/DB_EXPORT"

    run_hydrate "projalpha=$p"
    [ "$status" -eq 0 ]
    [[ "$output" != *"STALE MIRROR"* ]]                  # 誤検出しない（stale-updated の非vacuity 対）
    [[ "$output" == *"mirror は fresh"* ]]               # fresh の OK 行
}

# ==============================================================================
# (skip-truthful) fail-open skip 混在時は「全 registered repo の mirror は fresh」と言わず
#   checked(fresh)/skipped(検査不能) を分離報告する（gate errata E1・false reassurance 防止）。
#   本機能が殺すべき「検査不能を fresh 検証済みに融合する」事象の再導入を防ぐ集計行 truthfulness の tooth。
# ==============================================================================
@test "(skip-truthful) fresh ∧ fail-open skip 混在 → 『全…fresh』を出さず checked/skipped 分離報告（E1）" {
    local pf ps
    pf="$(_mkrepo fresh-ok)"; ps="$(_mkrepo skip-repo)"
    _issue f-1 "2026-07-07T00:00:00Z" > "$pf/.beads/issues.jsonl"      # fresh（mirror==DB）
    _issue f-1 "2026-07-07T00:00:00Z" > "$pf/.beads/DB_EXPORT"
    _issue s-1 "2026-07-05T00:00:00Z" > "$ps/.beads/issues.jsonl"      # skip-repo は DB_EXPORT なし
    # → skip-repo は bd -C export が有効0件で fail-open skip（検査不能）

    run_hydrate "fresh-ok=$pf skip-repo=$ps"
    [ "$status" -eq 0 ]
    # 核: skip が混じるとき「全 registered repo の mirror は fresh」という false reassurance を出さない
    [[ "$output" != *"全 registered repo の mirror は fresh"* ]]
    # 分離報告: 検査不能を skipped として、fresh を checked として別々に真実申告する
    [[ "$output" == *"skipped=1"* ]]
    [[ "$output" == *"checked=1"* ]]
    [[ "$output" == *"検査不能"* ]]
    # fail-open note 自体は依然出る（skip-repo は bd read 不能）
    [[ "$output" == *"bd -C export が有効 issue 0 件"* ]]
}

# ==============================================================================
# (failopen-bd) bd -C export が有効 issue 0 件（bd read 失敗 or 空 DB）→ 注記のみ・警告なし・exit0
# ==============================================================================
@test "(failopen-bd) bd -C export が有効0件（DB read 失敗）→ 注記のみ・警告なし・exit0（fail-open）" {
    local p; p="$(_mkrepo projbeta)"
    _issue k-1 "2026-07-05T00:00:00Z" > "$p/.beads/issues.jsonl"       # mirror は存在
    # DB_EXPORT を置かない → fake bd は error を吐き有効 issue 0 件 → 比較不能 → 注記のみ

    run_hydrate "projbeta=$p"
    [ "$status" -eq 0 ]                                   # fail-open: hydrate を止めない
    [[ "$output" != *"STALE MIRROR"* ]]                  # 誤陽性を出さない（bd 一時失敗を stale と誤断しない）
    [[ "$output" == *"bd -C export が有効 issue 0 件"* ]] # fail-open 注記
}

# ==============================================================================
# (failopen-nojsonl) issues.jsonl 不在（mirror 未生成）→ 注記のみ・警告なし・exit0
# ==============================================================================
@test "(failopen-nojsonl) issues.jsonl 不在（mirror 未生成）→ 注記のみ・警告なし・exit0（fail-open）" {
    local p; p="$(_mkrepo projgamma)"
    # .beads/ はあるが issues.jsonl を置かない（＝有効 bd repo だが mirror 未生成）
    _issue x-1 "2026-07-08T00:00:00Z" > "$p/.beads/DB_EXPORT"

    run_hydrate "projgamma=$p"
    [ "$status" -eq 0 ]
    [[ "$output" != *"STALE MIRROR"* ]]
    [[ "$output" == *"issues.jsonl 不在（mirror 未生成）"* ]]
}

# ==============================================================================
# (exit-unchanged) stale 検出は exit code を変えない（stale ∧ fresh 混在でも exit0）
# ==============================================================================
@test "(exit-unchanged) stale ∧ fresh 混在でも exit0（stale 検出は error でない）" {
    local ps pf
    ps="$(_mkrepo stale-repo)"; pf="$(_mkrepo fresh-repo)"
    _issue a-1 "2026-07-01T00:00:00Z" > "$ps/.beads/issues.jsonl"
    _issue a-1 "2026-07-09T00:00:00Z" > "$ps/.beads/DB_EXPORT"          # stale
    _issue b-1 "2026-07-02T00:00:00Z" > "$pf/.beads/issues.jsonl"
    _issue b-1 "2026-07-02T00:00:00Z" > "$pf/.beads/DB_EXPORT"          # fresh

    run_hydrate "stale-repo=$ps fresh-repo=$pf"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STALE MIRROR: stale-repo"* ]]
    [[ "$output" == *"1 repo で stale mirror を検出"* ]]  # 集計行
}

# ==============================================================================
# (dryrun-plan) --dry-run は bd を呼ばず plan のみ print（実 export しない・acc4 無退行）
# ==============================================================================
@test "(dryrun-plan) --dry-run は bd を呼ばず 'would cross-check mirror staleness' plan のみ" {
    local p; p="$(_mkrepo dryrun-repo)"
    _issue d-1 "2026-07-06T10:00:00Z" > "$p/.beads/issues.jsonl"
    _issue d-1 "2026-07-08T10:00:00Z" > "$p/.beads/DB_EXPORT"          # stale だが dry-run では検査しない

    run_hydrate "dryrun-repo=$p" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would cross-check mirror staleness"* ]]
    [[ "$output" != *"STALE MIRROR"* ]]                  # 実検査は走らない
    [ ! -f "$BD_LOG" ]                                    # bd stub は 1 度も呼ばれない（実 export なし）
}

# ==============================================================================
# (readonly) 検査は bd に export 以外の verb を渡さない（read-only 規律）
# ==============================================================================
@test "(readonly) bd に渡す verb は export のみ（write verb を渡さない・read-only 規律）" {
    local p; p="$(_mkrepo ro-repo)"
    _issue r-1 "2026-07-06T10:00:00Z" > "$p/.beads/issues.jsonl"
    _issue r-1 "2026-07-06T10:00:00Z" > "$p/.beads/DB_EXPORT"

    run_hydrate "ro-repo=$p"
    [ "$status" -eq 0 ]
    [ -f "$BD_LOG" ]                                      # bd は呼ばれた
    # bd に渡った各行に export が含まれ、write verb（update/create/close/import/sync/repo）は無い
    run grep -Ev 'export' "$BD_LOG"
    [ -z "$output" ]                                      # export を含まない bd 呼出しは 0 行
    run grep -E '(^| )(update|create|close|import|sync|repo|add|remove|dep|dolt)( |$)' "$BD_LOG"
    [ "$status" -ne 0 ]                                  # write/mutation verb は 1 度も渡っていない
}

# ==============================================================================
# (parse-skip) 破損行混入の issues.jsonl → _mirror_stats が有効行のみ計数し fail-open で継続
#   （破損行を issue に数えない＝数えれば n 乖離で STALE 誤検出。数えず fresh 成立で非vacuity）
# ==============================================================================
@test "(parse-skip) 破損行混入 → 有効行のみ計数し STALE 誤検出なし・exit0（fail-open）" {
    local p; p="$(_mkrepo parse-repo)"
    # mirror: 1 有効 issue ＋ json.loads 不能な破損行（＋空行）。
    { _issue pz-1 "2026-07-06T10:00:00Z"; printf 'THIS IS NOT JSON {{{\n'; printf '\n'; } > "$p/.beads/issues.jsonl"
    # live DB: 同一の有効 issue のみ。破損行が skip されれば mirror n=1 == DB n=1 → fresh（誤検出なし）。
    _issue pz-1 "2026-07-06T10:00:00Z" > "$p/.beads/DB_EXPORT"

    run_hydrate "parse-repo=$p"
    [ "$status" -eq 0 ]                          # 破損行で止まらない（fail-open）
    [[ "$output" != *"STALE MIRROR"* ]]          # 破損行を issue に数えない（数えれば n 乖離→STALE 誤検出）
    [[ "$output" == *"mirror は fresh"* ]]        # 有効行のみ計数し比較成立（parse 不能行に強い）
}

# ==============================================================================
# (failopen-nopython) PATH から python3 除去 → 「python3 不在のため … skip（fail-open）」注記・exit0
#   （契約が明示する fail-open 4 modality の残り 1 つ＝python3 不在の STALE-CHECK guard 枝を lock）
# ==============================================================================
@test "(failopen-nopython) python3 不在 → cross-check skip 注記のみ・警告なし・exit0（fail-open）" {
    local p; p="$(_mkrepo nopy-repo)"
    _issue np-1 "2026-07-06T10:00:00Z" > "$p/.beads/issues.jsonl"      # mirror（古い）
    _issue np-1 "2026-07-08T10:00:00Z" > "$p/.beads/DB_EXPORT"         # DB（新しい・本来なら STALE）

    local nopath; nopath="$(_nopython_bin)"
    # sanity（非vacuity）: shim PATH 下で python3 が実際に見つからないことを確認。
    PATH="$nopath" command -v python3 && return 1 || true

    run bash -c "cd '$ORCH' && PATH='$nopath' \
        ORCH_HYDRATE_PROJECTS='nopy-repo=$p' \
        ORCH_HYDRATE_CONFIG='$CONFIG' \
        ORCH_HYDRATE_BDW='$FAKE_BDW' \
        ORCH_HYDRATE_BD='$FAKE_BD' \
        ORCH_HYDRATE_SYNC_MARKER='$MARKER' \
        bash '$SCRIPT'"
    [ "$status" -eq 0 ]                                          # fail-open: hydrate を止めない
    [[ "$output" == *"python3 不在のため mirror 鮮度 cross-check を skip"* ]]  # fail-open 注記
    [[ "$output" != *"STALE MIRROR"* ]]                          # 検査自体が走らないので STALE も出ない
    [ ! -f "$BD_LOG" ]                                           # bd も呼ばれない（検査に入る前に skip）
}

# ==============================================================================
# (syntax) bash -n（構文）が通る
# ==============================================================================
@test "(syntax) bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

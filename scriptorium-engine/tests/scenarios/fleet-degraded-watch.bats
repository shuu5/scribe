#!/usr/bin/env bats
# tests/scenarios/fleet-degraded-watch.bats
#
# orch-degraded-watch.sh（degraded cell 独立 watcher・bd orch-r22・grill SSOT sc-3pq / orch-nzd）の
# 決定的 hermetic テスト。fleet-monitor-board.bats / guard-health-banner.bats と同型で bd / tmux / git を
# PATH スタブに差し替え、実スクリプトを走らせて構造3核判定を assert する E2E。
#
# 検証する契約不変条件（grill 2026-06-24 4 論点確定）:
#   (A) salvage = 構造3核の強AND（窓消失 × CLOSED不在 × commit=0）。orch-aaa（3核全立）が [SALVAGE]。
#   (B) 窓ありは候補外（生存 cell を殺さない）: orch-ccc（wt-orch-ccc live）は SALVAGE/SUSPECT どちらにも出ない。
#   (C) commit core の teeth: orch-bbb（窓消失・未終端だが commit>0）は [SUSPECT] であって [SALVAGE] でない。
#   (D) extract_status 補助（env STATUS）の teeth: orch-eee（窓消失・commit=0 だが notes 最終 STATUS=done）は
#       terminal とみなされ [SUSPECT] であって [SALVAGE] でない（＝env STATUS 補助が誤 salvage を防ぐ）。
#   (E) 終端 + 成果ありは無印: orch-ddd（窓消失・closed・commit>0）は SALVAGE/SUSPECT どちらにも出ない。
#   (F) salvage 件数の厳密性: [SALVAGE] はちょうど 1 件（orch-aaa のみ）。
#   (G) ported --extract / --classify が grill-status-watch 原典の契約どおり（最終 STATUS 抽出・done/blocked 前方一致）。
#   (H) self-scope gate: foreign cwd（dolt_database≠orch）は scan を拒否（fail-closed）・orch cwd は走る。
#   (I) fail-open: bd/tmux 不在でも die しない + 窓消失=全true で orch-aaa が [SALVAGE] 側（over-mark=安全側・silent 取りこぼしでない）。
#   (J) worktree root 不在は graceful（「監視対象 cell はありません」・exit 0）。
#   (SEC1) read-only verb discipline（safety core・無人周期実行で guard が効かない＝test が唯一のモート）:
#         bd は show のみ / tmux は list-panes のみ / git は **subcommand 粒度**で rev-list --count|log -1|
#         branch --show-current|worktree list のみ（他 subcommand・破壊 subverb〔branch -D 等〕が出たら RED）。
#   (SEC1-teeth) SEC1 の allowlist が subcommand 粒度で破壊 subverb/flag（branch -D / worktree remove / push 等）を
#         RED 化することを合成 log で実証（mutation 非vacuity・orch-7l4＝旧 verb 粒度なら branch -D 素通しだった穴）。
#   (SEC2) write-isolation: scan は worktree fixture 配下に新規 file を一切生まない（file-set 不変）。
#   (K) crash-shell blind-spot pin: orch-fff（窓在×未終端×commit=0＝dead shell 保持）は SALVAGE/SUSPECT
#         どちらにも出ない（窓消失 anchor の意図的 scope 境界・env-probe/人間 triage 委譲を機械 pin）。
#
# 実行: bats tests/scenarios/fleet-degraded-watch.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-degraded-watch.sh"
    TEST_TMPDIR=$(mktemp -d -t degraded-watch-bats-XXXXXX)
    export FIX_DIR="$TEST_TMPDIR"
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    export WROOT="$TEST_TMPDIR/worktrees/spawn"
    mkdir -p "$WROOT"

    # 合成 anchor（engine seam: anchor 解決は per-consumer env ORCH_DEGRADED_SCRIPTORIUM を最優先で verbatim
    #   採用＝env 供給時は _resolve_scriptorium/git を経ない。engine は hardcode fallback を持たず未供給は
    #   fail-loud die ゆえ scan path の test は明示 anchor を供給する〔orch-stale-scan.bats と同型〕）。
    export ANCHOR="$TEST_TMPDIR/anchor"
    mkdir -p "$ANCHOR/.beads"
    printf '{"dolt_database":"orch"}\n' > "$ANCHOR/.beads/metadata.json"

    # ── spawn cell fixtures（各 worktree dir に .branch/.count/.quiet を置き git スタブが読む）──
    #   aaa : 窓消失 × in_progress(未終端) × commit 0 → SALVAGE（構造3核全立）
    #   bbb : 窓消失 × in_progress(未終端) × commit 3 → SUSPECT（commit core で salvage 阻止）
    #   ccc : 窓あり(wt-orch-ccc) × in_progress × commit 0 → 無印（生存 cell は候補外）
    #   ddd : 窓消失 × closed(終端) × commit 5 → 無印（終端 + 成果あり）
    #   eee : 窓消失 × in_progress だが notes STATUS=done × commit 0 → SUSPECT（extract_status 補助で salvage 阻止）
    _mkcell() { # name branch count quiet
        local d="$WROOT/$1"; mkdir -p "$d"
        printf '%s' "$2" > "$d/.branch"
        printf '%s' "$3" > "$d/.count"
        printf '%s' "$4" > "$d/.quiet"
    }
    #   fff : 窓在(wt-orch-fff) × in_progress × commit 0 → 無印（crash-shell blind-spot の意図的 scope 境界 pin）
    _mkcell orch-aaa-111111 "spawn/orch-aaa-111111" "0" "8 hours ago"
    _mkcell orch-bbb-222222 "spawn/orch-bbb-222222" "3" "20 minutes ago"
    _mkcell orch-ccc-333333 "spawn/orch-ccc-333333" "0" "2 minutes ago"
    _mkcell orch-ddd-444444 "spawn/orch-ddd-444444" "5" "1 hour ago"
    _mkcell orch-eee-555555 "spawn/orch-eee-555555" "0" "3 hours ago"
    _mkcell orch-fff-666666 "spawn/orch-fff-666666" "0" "9 hours ago"

    # ── bead fixtures（bd show <id> --long --json が返す配列）──
    printf '%s' '[{"id":"orch-aaa","status":"in_progress","notes":"作業中"}]'                         > "$FIX_DIR/bead-orch-aaa.json"
    printf '%s' '[{"id":"orch-bbb","status":"in_progress","notes":"作業中"}]'                         > "$FIX_DIR/bead-orch-bbb.json"
    printf '%s' '[{"id":"orch-ccc","status":"in_progress","notes":"作業中"}]'                         > "$FIX_DIR/bead-orch-ccc.json"
    printf '%s' '[{"id":"orch-ddd","status":"closed","notes":"完了"}]'                                > "$FIX_DIR/bead-orch-ddd.json"
    printf '%s' '[{"id":"orch-eee","status":"in_progress","notes":"work\nSTATUS: done — delivered"}]' > "$FIX_DIR/bead-orch-eee.json"
    printf '%s' '[{"id":"orch-fff","status":"in_progress","notes":"crash 後 dead shell 保持中"}]'      > "$FIX_DIR/bead-orch-fff.json"

    # ── live window 名（tmux list-panes -a -F '#{window_name}'）: orch-ccc / orch-fff が生存 ──
    #   orch-fff は「窓は生きているが内部は死んだ（cld crash 後の dead shell）」を模す＝窓消失 anchor では
    #   拾えない構造上の blind-spot（意図的 scope 境界・scribe env-probe / 人間 triage 委譲）。
    printf '%s\n' 'wt-orch-ccc' 'wt-orch-fff' 'main' 'admin' > "$FIX_DIR/windows.txt"

    # ── stub: bd（show <id> --long --json → bead fixture / 不在は error-object + exit 1）──
    #   ★全 argv を bd-invocations.log に記録（read-only 性の回帰防御＝SEC1 が show 以外の verb を RED 化）。
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/bd-invocations.log"
# bd show <id> --long --json
if [ "$1" = "show" ]; then
  f="$FIX_DIR/bead-$2.json"
  if [ -f "$f" ]; then cat "$f"; exit 0; fi
  echo '{"error":"not found"}'; exit 1
fi
exit 0
STUB

    # ── stub: tmux（list-panes -a -F ... → windows.txt）──
    #   ★全 argv を tmux-invocations.log に記録（SEC1 が list-panes 以外の verb を RED 化）。
    cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/tmux-invocations.log"
case "$1" in
  list-panes) cat "$FIX_DIR/windows.txt" ;;
esac
exit 0
STUB

    # ── stub: git（-C <dir> の per-worktree fixture を読む）──
    #   ★全 argv を git-invocations.log に記録（SEC1 が rev-list/log/branch 以外の verb を RED 化）。
    cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/git-invocations.log"
dir=""
if [ "$1" = "-C" ]; then dir="$2"; shift 2; fi
case "$1 $2" in
  "branch --show-current") cat "$dir/.branch" 2>/dev/null ;;
  "rev-list --count")      cat "$dir/.count"  2>/dev/null ;;   # base..HEAD 引数は無視
  "log -1")                cat "$dir/.quiet"  2>/dev/null ;;
  # anchor 動的解決（orch-pso）: NCANCHOR set 時のみ worktree list 先頭に NCANCHOR を返す（未 set の既存 test は
  # 無出力＝resolution が hardcode fallback へ倒れる＝WORKTREE_ROOT override 下では副作用ゼロ）。porcelain 先頭 = main worktree。
  "worktree list")         [ -n "${NCANCHOR:-}" ] && printf 'worktree %s\n' "$NCANCHOR" ;;
esac
exit 0
STUB

    chmod +x "$BIN/bd" "$BIN/tmux" "$BIN/git"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# scan を fixture 環境で実行（self-scope gate は skip・PATH スタブ差替）。
#   orch-b10: EXTERNAL_REGISTRY を既定で不在パスへ固定＝実 repo の registry に依存しない hermetic 化
#   （external test は事前に export ORCH_DEGRADED_EXTERNAL_REGISTRY=<fixture> で上書きする）。
run_scan() {
    PATH="$BIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$ANCHOR" \
      ORCH_DEGRADED_WORKTREE_ROOT="$WROOT" \
      ORCH_DEGRADED_GATE_BASE="main" \
      ORCH_DEGRADED_EXTERNAL_REGISTRY="${ORCH_DEGRADED_EXTERNAL_REGISTRY:-$TEST_TMPDIR/no-registry}" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
}

# 指定 cell id の分類行（[SALVAGE]/[SUSPECT]）を抽出（無ければ空・grep 不一致でも exit 0）。
_cell_line() { printf '%s\n' "$output" | grep -E "\[(SALVAGE|SUSPECT)\][[:space:]]+$1\b" || true; }

# git-invocations.log の各 argv から先頭 "-C <dir>" を剥がした **先頭2トークン（subcommand + 次トークン）** を取り、
# read-only 実使用形の完全一致 allowlist 外を抽出する（空＝規律 OK・非空＝違反 verb 列）。**verb 粒度でなく
# subcommand/flag 粒度**なので `branch -D`（破壊）は `branch --show-current`（read）と別物として弾く（orch-7l4・
# 旧 verb 粒度では `branch` が丸ごと許可され `branch -D` が素通しした穴を塞ぐ）。SEC1 / (SEC1-teeth) / (L) が共有し
# フィルタ論理のドリフトを防ぐ単一 SSOT。allowlist は degraded-watch の実使用形: rev-list --count（commit 数）/
# log -1（quiet 補助）/ branch --show-current（branch 名）/ worktree list（_resolve_scriptorium の anchor 解決 +
# _resolve_repo_base の main worktree 解決）/ symbolic-ref --short（_resolve_repo_base の default branch 解決・
# orch-665・read-only＝HEAD の指す ref を読むだけ）。★symbolic-ref --short は external root 経路（_resolve_repo_base）
# 専用で、既定 run_scan（external registry 無し）では未到達ゆえ本 SEC1 の stub log には現れないが、M7/M8 は実 git を
# argv-logging wrapper 越しに叩く（orch-igl item(3)）ため external 経路の worktree list / symbolic-ref --short が
# git-invocations.log に載り M7/M8 の verb 検査で pin される。破壊 subverb〔symbolic-ref --delete / 2 引数 write 形〕は
# subcommand+flag 粒度ゆえ別物として RED 化されることを (SEC1-teeth) が合成 log で直接実証する（orch-igl item(2)＝旧 over-claim を teeth 化）。
_git_offending_verbs() { # $1=logfile
    sed -E 's/^-C [^ ]+ //' "$1" \
      | awk '{print $1" "$2}' \
      | sort -u \
      | grep -vE '^(rev-list --count|log -1|branch --show-current|worktree list|symbolic-ref --short)$' || true
}

# ==============================================================================
# (A) salvage = 構造3核の強AND
# ==============================================================================
@test "(A) salvage: 窓消失×CLOSED不在×commit=0 の orch-aaa が [SALVAGE]" {
    run_scan
    local line; line=$(_cell_line "orch-aaa")
    [[ "$line" == *"[SALVAGE]"* ]]
    [[ "$line" == *"orch-aaa"* ]]
}

# ==============================================================================
# (B) 窓あり cell は候補外（生存 cell を殺さない）
# ==============================================================================
@test "(B) 窓あり(wt-orch-ccc live)の orch-ccc は SALVAGE/SUSPECT どちらにも出ない" {
    run_scan
    local line; line=$(_cell_line "orch-ccc")
    [ -z "$line" ]
}

# ==============================================================================
# (C) commit core の teeth: commit>0 は salvage を阻止
# ==============================================================================
@test "(C) commit core: 窓消失×未終端だが commit>0 の orch-bbb は [SUSPECT]（[SALVAGE] ではない）" {
    run_scan
    local line; line=$(_cell_line "orch-bbb")
    [[ "$line" == *"[SUSPECT]"* ]]
    [[ "$line" != *"[SALVAGE]"* ]]
}

# ==============================================================================
# (D) extract_status 補助（env STATUS）の teeth: notes STATUS=done は salvage を阻止
# ==============================================================================
@test "(D) env STATUS 補助: 窓消失×commit=0 だが notes 最終 STATUS=done の orch-eee は [SUSPECT]（[SALVAGE] ではない）" {
    run_scan
    local line; line=$(_cell_line "orch-eee")
    [[ "$line" == *"[SUSPECT]"* ]]
    [[ "$line" != *"[SALVAGE]"* ]]
}

# ==============================================================================
# (E) 終端 + 成果ありは無印
# ==============================================================================
@test "(E) 終端+成果あり: 窓消失×closed×commit>0 の orch-ddd は SALVAGE/SUSPECT どちらにも出ない" {
    run_scan
    local line; line=$(_cell_line "orch-ddd")
    [ -z "$line" ]
}

# ==============================================================================
# (F) salvage 件数の厳密性
# ==============================================================================
@test "(F) [SALVAGE] はちょうど 1 件（orch-aaa のみ・強AND で誤殺しない）" {
    run_scan
    local n; n=$(printf '%s\n' "$output" | grep -c '\[SALVAGE\]')
    [ "$n" -eq 1 ]
}

# ==============================================================================
# (G) ported --extract / --classify（grill-status-watch 原典契約）
# ==============================================================================
@test "(G1) --extract: 配列 notes から最終 STATUS 行を抽出（複数 STATUS の last）" {
    run bash -c 'printf "%s" '\''[{"notes":"a\nSTATUS: grilling (1/3)\nb\nSTATUS: done — 完了"}]'\'' | ORCH_DEGRADED_SKIP_SESSION_GATE=1 bash "$1" --extract' _ "$SCRIPT"
    [ "$status" -eq 0 ]
    [ "$output" = "STATUS: done — 完了" ]
}

@test "(G2) --extract: notes 欠如は no-notes・error-object も no-notes（loop を殺さない）" {
    run bash -c 'printf "%s" '\''[{"status":"open"}]'\'' | bash "$1" --extract' _ "$SCRIPT"
    [ "$output" = "no-notes" ]
    run bash -c 'printf "%s" '\''{"error":"nope"}'\'' | bash "$1" --extract' _ "$SCRIPT"
    [ "$output" = "no-notes" ]
}

@test "(G3) --classify: done/blocked は terminal・grilling は ongoing（前方一致・prose 誤検出しない）" {
    run bash "$SCRIPT" --classify "STATUS: done — x"; [ "$output" = "terminal" ]
    run bash "$SCRIPT" --classify "STATUS: blocked — 要admin"; [ "$output" = "terminal" ]
    run bash "$SCRIPT" --classify "STATUS: grilling (2/5)"; [ "$output" = "ongoing" ]
    # 自由文末尾に done を含む grilling 行を terminal 誤判定しない（原典 sc-bka 前方アンカー）
    run bash "$SCRIPT" --classify "STATUS: grilling — facet done で確認待ち"; [ "$output" = "ongoing" ]
}

# ==============================================================================
# (H) self-scope gate（fail-closed）
# ==============================================================================
@test "(H1) foreign cwd（dolt_database≠orch）は scan を拒否（fail-closed・exit 非0・scan しない）" {
    local FOREIGN="$TEST_TMPDIR/foreign"; mkdir -p "$FOREIGN/.beads"
    printf '{"dolt_database":"un"}' > "$FOREIGN/.beads/metadata.json"
    PATH="$BIN:$PATH" ORCH_DEGRADED_WORKTREE_ROOT="$WROOT" \
      run bash -c 'cd "$1" && bash "$2"' _ "$FOREIGN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"[SALVAGE]"* ]]
}

@test "(H2) orch cwd（dolt_database=orch）は scan する" {
    local ORCH="$TEST_TMPDIR/orchcwd"; mkdir -p "$ORCH/.beads"
    printf '{"dolt_database":"orch"}' > "$ORCH/.beads/metadata.json"
    PATH="$BIN:$PATH" ORCH_DEGRADED_SCRIPTORIUM="$ANCHOR" ORCH_DEGRADED_WORKTREE_ROOT="$WROOT" ORCH_DEGRADED_GATE_BASE="main" \
      run bash -c 'cd "$1" && bash "$2"' _ "$ORCH" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SALVAGE]"* ]]
    [[ "$output" == *"orch-aaa"* ]]
}

@test "(H3) drift fix(orch-t9z): 破損 orch-token metadata は scan を拒否(fail-closed・_json_is_valid gate)" {
    # 旧 _resolve_dolt_database は _json_is_valid gate を欠き、破損 JSON でも sed が orch トークンを抽出して
    # 誤 self-scope（scan 実行）した（live drift）。共有 lib の _ledger_dolt_database は _json_is_valid gate 済みゆえ、
    # 破損 orch-token metadata は妥当性を肯定できず db 空 → DB≠orch → refuse（fail-closed・誤台帳起動を弾く）。
    # この test は旧コード（gate なし）では scan して RED になる teeth＝drift 解消の回帰防御（acceptance 3）。
    local BROKEN="$TEST_TMPDIR/brokenorch"; mkdir -p "$BROKEN/.beads"
    printf '{"dolt_database":"orch"' > "$BROKEN/.beads/metadata.json"   # 未閉じ = 破損 JSON（orch トークン入り）
    PATH="$BIN:$PATH" ORCH_DEGRADED_WORKTREE_ROOT="$WROOT" \
      run bash -c 'cd "$1" && bash "$2"' _ "$BROKEN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"[SALVAGE]"* ]]
}

# ==============================================================================
# (I) fail-open: bd/tmux 不在でも die しない + over-mark=安全側（silent 取りこぼしでない）
# ==============================================================================
@test "(I) bd/tmux 不在でも die しない＋窓消失=全true で orch-aaa が [SALVAGE]（over-mark=安全側・silent 取りこぼしでない）" {
    local HBIN="$TEST_TMPDIR/hbin"; mkdir -p "$HBIN"
    local b p
    for b in bash jq sed grep sort head awk cat printf dirname env; do
        p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$HBIN/$b"
    done
    cp "$BIN/git" "$HBIN/"   # git スタブのみ流用（bd/tmux は置かない＝不在）
    [ ! -e "$HBIN/bd" ]; [ ! -e "$HBIN/tmux" ]
    PATH="$HBIN" ORCH_DEGRADED_SKIP_SESSION_GATE=1 ORCH_DEGRADED_SCRIPTORIUM="$ANCHOR" \
      ORCH_DEGRADED_WORKTREE_ROOT="$WROOT" \
      ORCH_DEGRADED_GATE_BASE="main" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"scan"* ]]
    # tmux 不在→窓消失=全 cell true・bd 不在→bead 未終端化。orch-aaa（commit 0）は SALVAGE 側に現れる
    # ＝degraded を silent に取りこぼさず over-mark（安全側）に倒す（現状 "scan" substring は die しないしか見ない）。
    [[ "$output" == *"[SALVAGE]"* ]]
    local line; line=$(_cell_line "orch-aaa")
    [[ "$line" == *"[SALVAGE]"* ]]
}

# ==============================================================================
# (SEC1) read-only verb discipline（safety core・無人周期実行で PreToolUse guard が効かない）
#   watcher は Monitor/loop で無人周期実行され guard の射程外＝この test が read-only 性の唯一のモート。
#   correctness core(A〜F) と対称に safety core にも回帰防御を張る。
# ==============================================================================
@test "(SEC1) read-only verb: bd=show のみ / tmux=list-panes のみ / git=subcommand 粒度で rev-list --count|log -1|branch --show-current|worktree list のみ" {
    run_scan
    # 非 vacuous: 実際に 3 ツールを叩いている（log が空なら判定が空振りになる）。
    [ -s "$FIX_DIR/bd-invocations.log" ]
    [ -s "$FIX_DIR/tmux-invocations.log" ]
    [ -s "$FIX_DIR/git-invocations.log" ]
    # bd: show 以外の verb（update|create|close|assign|tag|sql|import|batch 等）が 1 つでも出たら RED。
    run bash -c 'awk "{print \$1}" "$1" | sort -u | grep -vxF show || true' _ "$FIX_DIR/bd-invocations.log"
    [ -z "$output" ]
    # tmux: list-panes 以外が出たら RED。
    run bash -c 'awk "{print \$1}" "$1" | sort -u | grep -vxF list-panes || true' _ "$FIX_DIR/tmux-invocations.log"
    [ -z "$output" ]
    # git: 先頭 "-C <dir>" を剥がした **先頭2トークン**（subcommand + 次トークン）が read-only 実使用形の完全一致
    #      allowlist（rev-list --count|log -1|branch --show-current|worktree list）以外なら RED。**subcommand/flag 粒度**
    #      ゆえ `branch -D`（破壊）は `branch --show-current`（read）と別物として弾く（orch-7l4＝旧 verb 粒度では
    #      `branch` が丸ごと許可され `branch -D` が素通しした穴を塞ぐ。worktree は従来から 2 トークン照合＝orch-pso errata）。
    #      破壊 subverb（branch -D / worktree remove / push / commit 等）の RED 化は (SEC1-teeth) が合成 log で実証する。
    run _git_offending_verbs "$FIX_DIR/git-invocations.log"
    [ -z "$output" ]
}

# ==============================================================================
# (SEC1-teeth) SEC1 allowlist の subcommand 粒度 teeth（mutation 非vacuity 実証・orch-7l4）
#   SEC1 が読む allowlist フィルタ（_git_offending_verbs）が、実使用 read-only 形は通し、破壊 subverb/flag は
#   RED 化することを合成 git-invocations.log で直接実証する。旧 verb 粒度なら `branch -D` は `branch` として
#   allowlist を素通しした＝この test は allowlist を verb 粒度へ戻す退行を殺す恒久 teeth（acceptance 1/3）。
# ==============================================================================
@test "(SEC1-teeth) git allowlist は subcommand 粒度で破壊 subverb/flag を RED 化する（実使用 read-only 形は通す）" {
    local L="$TEST_TMPDIR/git-teeth.log"
    # (通す) 実使用 read-only 形は allowlist 内＝offending 空（read-only 形を false-positive で弾かない）。
    printf '%s\n' \
      '-C /wt rev-list --count main..HEAD' \
      '-C /wt log -1 --format=%cr' \
      '-C /wt branch --show-current' \
      '-C /wt worktree list --porcelain' \
      '-C /wt symbolic-ref --short HEAD' > "$L"
    run _git_offending_verbs "$L"
    [ -z "$output" ]
    # (RED) 旧 verb 粒度なら `branch -D` が素通しした破壊 subverb/flag を subcommand 粒度で弾く＝mutation 非vacuity。
    #   orch-igl item(2): symbolic-ref の write 形（2 引数 `symbolic-ref HEAD <ref>` / `--delete`）も RED 化されることを
    #   直接実証する（allowlist は read 形 `symbolic-ref --short` のみ＝:150 の over-claim コメントを teeth 化）。
    printf '%s\n' \
      '-C /wt branch -D spawn/orch-aaa-1' \
      '-C /wt worktree remove /wt' \
      '-C /wt push origin main' \
      '-C /wt commit -m x' \
      '-C /wt checkout -b spawn/x' \
      '-C /wt symbolic-ref HEAD refs/heads/x' \
      '-C /wt symbolic-ref --delete refs/heads/x' > "$L"
    run _git_offending_verbs "$L"
    [ -n "$output" ]
    [[ "$output" == *"branch -D"* ]]              # ★核: verb 粒度では素通しした破壊 subverb を弾く
    [[ "$output" == *"worktree remove"* ]]
    [[ "$output" == *"push origin"* ]]
    [[ "$output" == *"commit -m"* ]]
    [[ "$output" == *"checkout -b"* ]]
    [[ "$output" == *"symbolic-ref HEAD"* ]]      # ★orch-igl item(2): symbolic-ref の 2 引数 write 形を RED 化（read 形 --short は上で通す）
    [[ "$output" == *"symbolic-ref --delete"* ]] # symbolic-ref --delete も subcommand+flag 粒度で別物として弾く
}

# ==============================================================================
# (SEC2) write-isolation: scan は worktree fixture 配下に新規 file を生まない
# ==============================================================================
@test "(SEC2) scan は worktree fixture 配下に新規 file を一切生まない（file-set 不変・timing 非依存で -newer を包摂）" {
    local before after
    before=$(find "$WROOT" -type f | sort)
    run_scan
    after=$(find "$WROOT" -type f | sort)
    [ "$before" = "$after" ]
}

# ==============================================================================
# (K) crash-shell blind-spot pin（意図的 scope 境界）
# ==============================================================================
@test "(K) 窓在×未終端×commit=0 の orch-fff（dead shell 保持）は SALVAGE/SUSPECT に出ない（窓消失 anchor の意図的 scope 境界）" {
    run_scan
    local line; line=$(_cell_line "orch-fff")
    [ -z "$line" ]
}

# ==============================================================================
# (J) worktree root 不在は graceful
# ==============================================================================
@test "(J) spawn worktree root 不在は graceful（監視対象なし・exit 0）" {
    PATH="$BIN:$PATH" ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$ANCHOR" \
      ORCH_DEGRADED_WORKTREE_ROOT="$TEST_TMPDIR/does-not-exist" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"監視対象 cell はありません"* ]]
}

# ==============================================================================
# (ANCHOR-FAILLOUD) engine seam: anchor 未供給（per-consumer env / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG なし ×
#   動的導出も詰み）は scan path で fail-loud die する（engine は deploy-layout hardcode fallback を持たない）。
#   pure-mode（--extract/--classify/--help）と self-scope reject は上流で anchor 非依存化済みゆえ、この die は
#   scan path 固有＝SKIP_SESSION_GATE で self-scope を抜けた後の anchor 解決で発火する。stub git（NCANCHOR 未 set）
#   で動的導出を空にし、anchor env を一切渡さないことで解決不能を作る。未供給 fail-loud の pin（seam 契約の teeth）。
# ==============================================================================
@test "(ANCHOR-FAILLOUD) anchor 未供給（env/config なし・動的導出も空）は scan path で fail-loud die（engine に hardcode fallback なし）" {
    PATH="$BIN:$PATH" ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_WORKTREE_ROOT="$WROOT" ORCH_DEGRADED_GATE_BASE="main" \
      run env -u ORCH_ANCHOR -u ORCH_ANCHOR_CONFIG -u ORCH_DEGRADED_SCRIPTORIUM bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"anchor 解決不能（fail-loud）"* ]]
    [[ "$output" != *"[SALVAGE]"* ]]
}

# ==============================================================================
# (L) 非 canonical anchor path の scan root 動的解決（orch-pso・orch-7py gate follow-up）
#   旧 canonical hardcode anchor path を撤去し、`git worktree list` 先頭
#   （= anchor main worktree）から SCRIPTORIUM/WORKTREE_ROOT を解決する。anchor を非 canonical path へ
#   checkout/改名しても scan root が空を silent 報告しない（latent 結合の解消・acceptance (1)(2)）。
#   env override（ORCH_DEGRADED_SCRIPTORIUM / ORCH_DEGRADED_WORKTREE_ROOT）を一切渡さず、git stub が
#   worktree list で返す非 canonical anchor だけで scan root を導けることを検証する（旧 hardcode 実装では
#   NCANCHOR 配下 cell が hardcode path に無いため「監視対象なし」と誤報して RED になる teeth）。
# ==============================================================================
@test "(L) 非 canonical anchor: SCRIPTORIUM/WORKTREE_ROOT を git worktree list から動的解決し cell 検出（env override なし）" {
    local NCANCHOR="$TEST_TMPDIR/renamed-orchestrator-xyz"
    mkdir -p "$NCANCHOR/.worktrees/spawn" "$NCANCHOR/.beads"
    # orch-49g: E2 anchor 検証（dolt_database==orch）を通すため非 canonical anchor にも orch 台帳 metadata を置く
    #   （relocate された real orchestrator anchor は当然 orch 台帳を持つ＝faithful 化・foreign は (E2reject) で pin）。
    printf '{"dolt_database":"orch"}' > "$NCANCHOR/.beads/metadata.json"
    # 非 canonical anchor 配下にのみ cell を置く（従来 hardcode path には無い＝hardcode だと空を silent 報告）。
    local d="$NCANCHOR/.worktrees/spawn/orch-ncp-777777"; mkdir -p "$d"
    printf '%s' "spawn/orch-ncp-777777" > "$d/.branch"
    printf '%s' "0"           > "$d/.count"    # commit=0
    printf '%s' "5 hours ago" > "$d/.quiet"
    printf '%s' '[{"id":"orch-ncp","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-ncp.json"
    # env override（SCRIPTORIUM / WORKTREE_ROOT）を敢えて渡さない。git stub は NCANCHOR set 時のみ
    #   worktree list で NCANCHOR を返す＝script 実体からの動的解決だけで scan root を導く。
    NCANCHOR="$NCANCHOR" PATH="$BIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 ORCH_DEGRADED_GATE_BASE="main" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # scan root が非 canonical anchor 配下に解決される（hardcode でも env でもなく git 由来）＝acceptance (1)。
    [[ "$output" == *"scan root=$NCANCHOR/.worktrees/spawn"* ]]
    # 非 canonical anchor 配下の cell が検出される（窓消失×未終端×commit=0 → SALVAGE）＝acceptance (2)。
    local line; line=$(_cell_line "orch-ncp")
    [[ "$line" == *"[SALVAGE]"* ]]
    [[ "$line" == *"orch-ncp"* ]]
    # ── SEC1 no-override 経路（実解決 anchor）の verb 検査（orch-7l4 (b)・axg WF 指摘）──────────────
    #   fleet では _resolve_scriptorium を短絡する gate 変数は ORCH_DEGRADED_SCRIPTORIUM（orch-degraded-watch.sh:114
    #   の `${ORCH_DEGRADED_SCRIPTORIUM:-$(_resolve_scriptorium ...)}`）であり、WORKTREE_ROOT ではない。run_scan は
    #   WORKTREE_ROOT のみ override し SCRIPTORIUM を渡さないため SEC1 でも _resolve_scriptorium は実走し
    #   `git worktree list` を既に叩く（ただし NCANCHOR 未設定で stub 無出力→hardcode fallback＝解決結果を駆動しない
    #   空振りの呼出）。本 (L) case は NCANCHOR を返す stub 下で no-override 解決が**非 canonical anchor を実際に採用し
    #   scan root を駆動する**経路（_resolve_scriptorium の E2 accept 分岐）を exercise する＝SEC1 が通す空振り
    #   worktree list より広い実解決経路の全 git subcommand が read-only 実使用形の allowlist 内であることを SEC1 と
    #   同じフィルタ（_git_offending_verbs）で pin する。（probe 側は run_probe が ORCH_CLEAN_SCRIPTORIUM も渡すため
    #   probe SEC1 では真に inert＝(NONCANON) が exercise する。fixture 差に注意＝axg (b) の「inert 前提」は probe 用。）
    run _git_offending_verbs "$FIX_DIR/git-invocations.log"
    [ -z "$output" ]
    # 非 vacuity: worktree list が実際に呼ばれた（no-override 解決経路を通り _resolve_scriptorium が実走した直接証明）。
    run bash -c 'sed -E "s/^-C [^ ]+ //" "$1" | awk "{print \$1\" \"\$2}" | grep -Fxq "worktree list"' _ "$FIX_DIR/git-invocations.log"
    [ "$status" -eq 0 ]
}

@test "(L2) env override 最優先（orch-pso gate errata）: ORCH_DEGRADED_SCRIPTORIUM 設定時は git 解決を経ず verbatim 使用" {
    # acceptance (1)「env override 維持」の回帰防御。既存 case は WORKTREE_ROOT override で SCRIPTORIUM 解決を
    # 丸ごとバイパスしており、SCRIPTORIUM 変数自体の env 最優先（git worktree list を叩かない）は未 pin だった。
    local ENVANCHOR="$TEST_TMPDIR/env-anchor"
    mkdir -p "$ENVANCHOR/.worktrees/spawn"
    local NCANCHOR="$TEST_TMPDIR/renamed-orchestrator-git"
    mkdir -p "$NCANCHOR/.worktrees/spawn"
    # git stub は NCANCHOR を返しうる状態にするが、env 最優先なら worktree list 自体が呼ばれない。
    NCANCHOR="$NCANCHOR" PATH="$BIN:$PATH" \
      ORCH_DEGRADED_SCRIPTORIUM="$ENVANCHOR" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 ORCH_DEGRADED_GATE_BASE="main" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # scan root は env の値 verbatim（git 由来の NCANCHOR ではない）。
    [[ "$output" == *"scan root=$ENVANCHOR/.worktrees/spawn"* ]]
    [[ "$output" != *"scan root=$NCANCHOR"* ]]
    # git worktree list が一度も呼ばれていない（${VAR:-...} の既定非展開＝関数不呼出の直接証明）。
    if [ -s "$FIX_DIR/git-invocations.log" ]; then
        run bash -c 'sed -E "s/^-C [^ ]+ //" "$1" | awk "{print \$1}" | grep -cx worktree || true' _ "$FIX_DIR/git-invocations.log"
        [ "$output" = "0" ]
    fi
}

# ==============================================================================
# (E2) foreign anchor 誤解決の構造封鎖（orch-49g・共有 lib orch_anchor.sh の E2 検証）
#   deploy 形態（script 実体が repo 外）で self_dir/$PWD leg の git 解決が**別 project の git repo** anchor を
#   返すと、旧実装（無検証）は foreign anchor を silent 採用して orchestrator の scan root にしてしまう（foreign
#   repo の worktree が orch 監視へ漏れ、逆に自 cell を取りこぼす）。共有 lib は解決候補の dolt_database==orch を
#   検証し、foreign（≠orch）候補を reject する。★engine seam: engine は hardcode canonical fallback を持たない
#   ため、E2 reject 後は解決不能で **fail-loud die（exit≠0）** に倒す（旧配備層版の graceful fallback→exit 0 とは
#   異なる・engine 契約）。いずれにせよ foreign anchor は scan root に採られず、その配下 cell が surface しない
#   ことを pin する（旧無検証実装なら FANCHOR を採用して scan 実行し foreign cell が surface＝mutation 非vacuity）。
# ==============================================================================
@test "(E2) foreign anchor（dolt_database≠orch）は git 動的解決で拾っても reject し foreign cell を surface しない（E2 封鎖・orch-49g）" {
    local FANCHOR="$TEST_TMPDIR/foreign-project-anchor"
    mkdir -p "$FANCHOR/.beads" "$FANCHOR/.worktrees/spawn/orch-foreigncell-111111"
    printf '{"dolt_database":"un"}' > "$FANCHOR/.beads/metadata.json"   # foreign 台帳（≠orch）
    printf '%s' 'spawn/orch-foreigncell-111111' > "$FANCHOR/.worktrees/spawn/orch-foreigncell-111111/.branch"
    printf '%s' '0'           > "$FANCHOR/.worktrees/spawn/orch-foreigncell-111111/.count"   # commit=0（旧実装なら SALVAGE 候補）
    printf '%s' '3 hours ago' > "$FANCHOR/.worktrees/spawn/orch-foreigncell-111111/.quiet"
    printf '%s' '[{"id":"orch-foreigncell","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-foreigncell.json"
    # env override を渡さない＝_resolve_scriptorium が git stub（NCANCHOR=FANCHOR）を解決 → E2 検証で reject。
    # engine は fallback を持たず解決不能で die するため anchor die メッセージを pin する。
    NCANCHOR="$FANCHOR" PATH="$BIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 ORCH_DEGRADED_GATE_BASE="main" \
      run bash "$SCRIPT"
    # engine 契約: E2 reject 後は解決不能 → fail-loud die（graceful fallback は撤去済み）。
    [ "$status" -ne 0 ]
    [[ "$output" == *"anchor 解決不能（fail-loud）"* ]]
    # E2 封鎖: foreign anchor を scan root に採らない（非vacuity: 検証を外すと FANCHOR を採用して下 2 行が落ちる）。
    [[ "$output" != *"scan root=$FANCHOR/.worktrees/spawn"* ]]
    [[ "$output" != *"orch-foreigncell"* ]]
}

# ==============================================================================
# (M) external repo cell の監視射程（orch-b10）
#   incident orch-7ti: `--repo <外部 project>` cell は <外部>/.worktrees/spawn 配下に住み、SCRIPTORIUM
#   ルートだけ見る degraded scan の射程から漏れる（終端宣言 write も worker sandbox で断たれ二重盲点＝
#   宣言もできず未 merge 検出にも掛からず hands-free ループが silent 停止）。dispatch が registry に外部 repo
#   root を記録 → degraded がそれを読み <root>/.worktrees/spawn も同 3 核で走査する。ここでは registry fixture
#   を pin し、外部 repo cell が SALVAGE/SUSPECT に surface することを実証する（acceptance 1「監視が拾う」・3）。
# ==============================================================================

# 外部 repo fixture を組む: <extroot>/.worktrees/spawn/<name> に .branch/.count/.quiet + bead fixture。
_mk_ext_cell() { # extroot name branch count quiet status notes
    local d="$1/.worktrees/spawn/$2"; mkdir -p "$d"
    printf '%s' "$3" > "$d/.branch"
    printf '%s' "$4" > "$d/.count"
    printf '%s' "$5" > "$d/.quiet"
    local id; id="$(printf '%s' "$3" | sed -E 's#^spawn/##; s/-[0-9]+$//')"
    printf '[{"id":"%s","status":"%s","notes":"%s"}]' "$id" "$6" "$7" > "$FIX_DIR/bead-$id.json"
}

@test "(M1) external repo cell: 窓消失×未終端×commit=0 が external root から [SALVAGE]（監視射程に入る・acceptance 1）" {
    local EXTDIR="$TEST_TMPDIR/ext-repo-A"
    _mk_ext_cell "$EXTDIR" "orch-ext1-111111" "spawn/orch-ext1-111111" "0" "6 hours ago" "in_progress" "作業中"
    printf '%s\n' "$EXTDIR" > "$TEST_TMPDIR/registry"
    export ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/registry"
    run_scan
    local line; line=$(_cell_line "orch-ext1")
    [[ "$line" == *"[SALVAGE]"* ]]
    [[ "$line" == *"orch-ext1"* ]]
    [[ "$line" == *"external repo cell"* ]]      # 外部 repo cell と注記される
    [[ "$line" == *"$EXTDIR"* ]]                 # root が surface される
    [[ "$output" == *"external repo cell roots"* ]]   # header にも external roots 行が出る
}

@test "(M2) external repo cell: 窓消失×commit>0 は [SUSPECT]（commit core で salvage 阻止・external でも同 3 核）" {
    local EXTDIR="$TEST_TMPDIR/ext-repo-B"
    _mk_ext_cell "$EXTDIR" "orch-ext2-222222" "spawn/orch-ext2-222222" "4" "10 minutes ago" "in_progress" "作業中"
    printf '%s\n' "$EXTDIR" > "$TEST_TMPDIR/registry"
    export ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/registry"
    run_scan
    local line; line=$(_cell_line "orch-ext2")
    [[ "$line" == *"[SUSPECT]"* ]]
    [[ "$line" != *"[SALVAGE]"* ]]
    [[ "$line" == *"external repo cell"* ]]
}

@test "(M3) registry の非存在 root は graceful skip（cell 撤去/repo 削除後も die せず・header にも出さない）" {
    printf '%s\n' "$TEST_TMPDIR/does-not-exist-repo" > "$TEST_TMPDIR/registry"
    export ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/registry"
    run_scan
    [[ "$output" != *"external repo cell roots"* ]]   # 非存在 root は存在チェックで落ち header に出ない
    [[ "$output" == *"[SALVAGE]"* ]]                   # self の orch-aaa は不変（回帰なし）
}

@test "(M4) registry 不在（既定）は external scan せず従来挙動（非 external 環境で副作用ゼロ・回帰防御）" {
    run_scan   # helper 既定 = 不在 registry（$TEST_TMPDIR/no-registry）
    [[ "$output" != *"external repo cell roots"* ]]
    [[ "$output" != *"external repo cell・root"* ]]
    local line; line=$(_cell_line "orch-aaa")
    [[ "$line" == *"[SALVAGE]"* ]]
}

@test "(M5・SEC2 external) external root scan は external worktree 配下に新規 file を生まない（write-isolation）" {
    local EXTDIR="$TEST_TMPDIR/ext-repo-C"
    _mk_ext_cell "$EXTDIR" "orch-ext3-333333" "spawn/orch-ext3-333333" "0" "5 hours ago" "in_progress" "作業中"
    printf '%s\n' "$EXTDIR" > "$TEST_TMPDIR/registry"
    export ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/registry"
    local before after
    before=$(find "$EXTDIR/.worktrees" -type f | sort)
    run_scan
    after=$(find "$EXTDIR/.worktrees" -type f | sort)
    [ "$before" = "$after" ]
}

@test "(M6) self repo を registry に誤登録しても二重 scan しない（skip-self teeth・orch-b10）" {
    # self repo（SCRIPTORIUM/WORKTREE_ROOT が指す repo）を registry にも入れた場合、_external_scan_roots が
    # self_canon 一致で skip し self root cell を二重計上しない（pure-defense の teeth＝skip-self を外すと n=2 で RED）。
    local SELFREPO="$TEST_TMPDIR/self-repo"
    local d="$SELFREPO/.worktrees/spawn/orch-self1-999999"; mkdir -p "$d"
    printf '%s' "spawn/orch-self1-999999" > "$d/.branch"
    printf '%s' "0"           > "$d/.count"    # commit=0（未終端 × commit0 → SALVAGE）
    printf '%s' "7 hours ago" > "$d/.quiet"
    printf '%s' '[{"id":"orch-self1","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-self1.json"
    printf '%s\n' "$SELFREPO" > "$TEST_TMPDIR/registry"   # self repo を registry に誤登録（skip-self を発火させる）
    PATH="$BIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$SELFREPO" \
      ORCH_DEGRADED_WORKTREE_ROOT="$SELFREPO/.worktrees/spawn" \
      ORCH_DEGRADED_GATE_BASE="main" \
      ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/registry" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    # orch-self1 は self root scan で 1 回だけ出る（registry の self entry は skip-self で二重 scan しない）。
    local n; n=$(printf '%s\n' "$output" | grep -c '\[SALVAGE\][[:space:]]\+orch-self1\b' || true)
    [ "$n" -eq 1 ]
    # 唯一の registry entry が self ゆえ external roots header は出ない（skip されて空）。
    [[ "$output" != *"external repo cell roots"* ]]
}

# ==============================================================================
# (M7/M8) external repo cell の per-repo base 解決（orch-665・Option B・orch-b10 follow-up）
#   外部 repo が local `main` を持たない（master/develop/trunk 既定）と、global base=main の
#   `git rev-list --count main..HEAD` が非0終了し cnt 空→「commit=判定不能」に落ちた（Option A・lossy）。
#   Option B は external repo の default branch（main worktree の symbolic-ref HEAD）を _resolve_repo_base で
#   per-repo 解決して正確な commit 数を数える。★実 git を使う（symbolic-ref/worktree list を faithfully 叩く＝
#   stub で fake しない・contract「degraded は bats stub に symbolic-ref 対応追加が必要」を実 git で faithful に満たす）:
#   実 git（PATH 先頭に symlink）+ stub bd/tmux（bead 未終端・window-gone）で構造3核を走らせる。SCRIPTORIUM/
#   WORKTREE_ROOT は hermetic な空 self へ向け、external repo のみ registry で走査する。
#   M7=解決成功で実数 surface（判定不能でない・mutation teeth）/ M8=detached HEAD で fallback→判定不能（fail-loud 温存）。
#   ★mutation RED（acceptance 3）: per-repo 解決（run_scan の _resolve_repo_base）を外し global base=main へ戻すと
#     M7 の cnt が空→「commit=判定不能」になり M7 の `commit=1`/`!= 判定不能` が RED（＝解決が load-bearing）。
#     M7（commit=1）と M8（判定不能）は fixture が default branch 状態だけ違い、対比が per-repo 解決の効果を実証する。
# ==============================================================================

# 実 git + stub bd/tmux の bin を組んで external repo を real git で走査する（$1=bin dir path）。
#   orch-igl item(3): git は「実 git を呼びつつ argv を git-invocations.log へ記録する wrapper」にする＝external 経路
#   （_resolve_repo_base）の worktree list / symbolic-ref --short を faithfully 叩き（=実 git 意味論）、かつ SEC1 と同じ
#   verb 検査（_git_offending_verbs）に載せる（旧 symlink は実 git だが argv 非 log ＝新 external verb が invocation-log
#   verb 検査を通らない盲点だった）。wrapper は絶対 path で実 git を exec ＝自己再帰しない。
_mk_realgit_bin() {
    local rbin="$1"; mkdir -p "$rbin"
    local realgit; realgit="$(command -v git)"   # RBIN を PATH に載せる前ゆえ実 git（wrapper 自身ではない）
    cat > "$rbin/git" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIX_DIR/git-invocations.log"
exec "$realgit" "\$@"
STUB
    chmod +x "$rbin/git"
    cp "$BIN/bd" "$rbin/bd"                    # stub bd（$FIX_DIR/bead-*.json 参照）
    cp "$BIN/tmux" "$rbin/tmux"               # stub tmux（$FIX_DIR/windows.txt 参照＝wt-orch-extX は不在→窓消失）
}

@test "(M7) external base≠main: per-repo default branch 解決で実 commit 数を surface（判定不能でない・acceptance 1/3）" {
    local RBIN="$TEST_TMPDIR/rbin-m7"; _mk_realgit_bin "$RBIN"
    local R="$TEST_TMPDIR/ext-master-m7"
    git init -q -b master "$R"                                # ← default branch = master（local main 不在）
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extm-999 "$R/.worktrees/spawn/orch-extm-999" master
    echo b > "$R/.worktrees/spawn/orch-extm-999/b"
    git -C "$R/.worktrees/spawn/orch-extm-999" add b
    git -C "$R/.worktrees/spawn/orch-extm-999" -c commit.gpgsign=false commit -qm work   # master より 1 先行
    # bead 未終端（in_progress）＝核B CLOSED不在。窓消失は windows.txt に wt-orch-extm が無いことで成立。
    printf '%s' '[{"id":"orch-extm","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-extm.json"
    printf '%s\n' "$R" > "$TEST_TMPDIR/reg-m7"
    local SELFEMPTY="$TEST_TMPDIR/selfempty-m7"   # 空 self（real git と self stub fixture の混在回避）
    PATH="$RBIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$SELFEMPTY" \
      ORCH_DEGRADED_WORKTREE_ROOT="$SELFEMPTY/.worktrees/spawn" \
      ORCH_DEGRADED_GATE_BASE="main" \
      ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/reg-m7" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local line; line=$(_cell_line "orch-extm")
    [[ "$line" == *"[SUSPECT]"* ]]               # 窓消失×未終端×commit>0 → SUSPECT（core C で salvage 阻止）
    [[ "$line" == *"commit=1"* ]]                # per-repo 解決した master に対する実 commit 数（Option B・判定不能でない）
    [[ "$line" != *"判定不能"* ]]                # Option A から格上げ（per-repo 解決を外すと判定不能で RED＝mutation teeth）
    [[ "$line" == *"external repo cell"* ]]      # 外部 repo cell と注記
    # orch-igl item(3): external 経路（_resolve_repo_base）の新 verb（worktree list / symbolic-ref --short）が
    #   argv-logging wrapper で git-invocations.log に載り、SEC1 と同じ read-only allowlist 検査を通ることを pin する
    #   （旧 symlink では実 git が argv を log せず、これらの新 verb が invocation-log verb 検査の盲点だった）。
    [ -s "$FIX_DIR/git-invocations.log" ]                                                       # 非 vacuous（実際に叩いている）
    run bash -c 'sed -E "s/^-C [^ ]+ //" "$1" | awk "{print \$1\" \"\$2}" | grep -Fxq "symbolic-ref --short"' _ "$FIX_DIR/git-invocations.log"
    [ "$status" -eq 0 ]                                                                          # symbolic-ref --short を実際に exercise（新 verb 非 vacuity）
    run _git_offending_verbs "$FIX_DIR/git-invocations.log"
    [ -z "$output" ]                                                                             # external 経路の全 git verb が read-only allowlist 内（新 verb 込み）
}

@test "(M8) external base 解決不能 fallback: main worktree が detached HEAD なら per-repo 解決失敗→judgment fallback→commit=判定不能（fail-loud 温存）" {
    local RBIN="$TEST_TMPDIR/rbin-m8"; _mk_realgit_bin "$RBIN"
    local R="$TEST_TMPDIR/ext-detached-m8"
    git init -q -b master "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-extd-888 "$R/.worktrees/spawn/orch-extd-888" master
    echo b > "$R/.worktrees/spawn/orch-extd-888/b"
    git -C "$R/.worktrees/spawn/orch-extd-888" add b
    git -C "$R/.worktrees/spawn/orch-extd-888" -c commit.gpgsign=false commit -qm work
    git -C "$R" checkout -q --detach             # ← main worktree detached HEAD＝symbolic-ref 失敗→解決不能
    printf '%s' '[{"id":"orch-extd","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-extd.json"
    printf '%s\n' "$R" > "$TEST_TMPDIR/reg-m8"
    local SELFEMPTY="$TEST_TMPDIR/selfempty-m8"
    PATH="$RBIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$SELFEMPTY" \
      ORCH_DEGRADED_WORKTREE_ROOT="$SELFEMPTY/.worktrees/spawn" \
      ORCH_DEGRADED_GATE_BASE="main" \
      ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/reg-m8" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local line; line=$(_cell_line "orch-extd")
    [[ "$line" == *"[SUSPECT]"* ]]               # 窓消失×未終端×（cnt 空→nocommit=0）→ A×B SUSPECT
    [[ "$line" == *"commit=判定不能"* ]]         # 解決不能→global base fallback→main 不在→判定不能（fail-loud 温存）
    [[ "$line" == *"external repo cell"* ]]
    # orch-igl item(3): detached HEAD 経路でも _resolve_repo_base は worktree list / symbolic-ref --short（失敗）を
    #   叩く＝これらの新 verb が argv-logging wrapper で記録され read-only allowlist 内であることを pin（fail 経路でも read-only）。
    run _git_offending_verbs "$FIX_DIR/git-invocations.log"
    [ -z "$output" ]
}

@test "(M9) external 非 default checkout 乖離: main worktree が cell 系列外 branch を checkout 中なら誤 count せず commit=乖離 で fail-loud（containment gate teeth・orch-igl item1・dispatch と対称）" {
    # orch-igl item(1)（addendum C: dispatch/degraded を対称に直す）: `_resolve_repo_base` は「main worktree の
    #   checkout branch」で default を近似するため、foreign main worktree が非 default branch（cell 系列から乖離）を
    #   checkout 中だと base が cell 系列外を指し commit 数が不正確化する（従来: 誤 count→salvage/suspect 誤分類）。
    #   containment gate（_repo_base_relation）が乖離（a>0 ∧ b>0）を検出し cnt="乖離"（commit=乖離）で fail-loud する。
    #   ★mutation RED（acceptance 1/3）: gate（diverged 分岐）を外し従来の _commit_count へ戻すと cnt=1（feature に対する
    #     誤 count）で「commit=1」になり、下の `commit=乖離` が RED になる＝gate が load-bearing。
    local RBIN="$TEST_TMPDIR/rbin-m9"; _mk_realgit_bin "$RBIN"
    local R="$TEST_TMPDIR/ext-diverged-m9"
    git init -q -b master "$R"                                # default branch = master
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init   # master: M
    git -C "$R" checkout -q -b feature                        # ← main worktree を非 default branch feature へ
    echo fx > "$R/fx"; git -C "$R" add fx; git -C "$R" -c commit.gpgsign=false commit -qm featwork   # feature: M+Fx
    git -C "$R" worktree add -q -b spawn/orch-extdv9-777 "$R/.worktrees/spawn/orch-extdv9-777" master   # cell 起点=master
    echo c > "$R/.worktrees/spawn/orch-extdv9-777/c"
    git -C "$R/.worktrees/spawn/orch-extdv9-777" add c
    git -C "$R/.worktrees/spawn/orch-extdv9-777" -c commit.gpgsign=false commit -qm cellwork   # cell: M+C（feature と乖離）
    printf '%s' '[{"id":"orch-extdv9","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-extdv9.json"
    printf '%s\n' "$R" > "$TEST_TMPDIR/reg-m9"
    local SELFEMPTY="$TEST_TMPDIR/selfempty-m9"
    PATH="$RBIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$SELFEMPTY" \
      ORCH_DEGRADED_WORKTREE_ROOT="$SELFEMPTY/.worktrees/spawn" \
      ORCH_DEGRADED_GATE_BASE="main" \
      ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/reg-m9" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local line; line=$(_cell_line "orch-extdv9")
    [[ "$line" == *"[SUSPECT]"* ]]               # 窓消失×未終端×（乖離→nocommit=0）→ A×B SUSPECT
    [[ "$line" == *"commit=乖離"* ]]             # containment gate: 乖離を検出し誤 count でなく fail-loud（gate 外すと commit=1 で RED）
    [[ "$line" != *"[SALVAGE]"* ]]               # 乖離は commit=0 ではない＝誤 salvage 化しない
}

@test "(M10) external 真の harm(b)（0-ahead merge 済 cell で base が前進・a=0 ∧ b>0）: containment gate が a-first 短絡で contained→commit=0→[SALVAGE]（誤 diverged/suspect 化しない・orch-igl item1）" {
    # orch-igl item(1) 核（M9〔diverged〕/M1〔a=0 ∧ b=0〕が抜いていた真の harm(b) modality）: merge 済 cell で
    #   default(base=master) が cell 先へ前進し base が cell HEAD の祖先でなくなる契約＝a=rev-list base..HEAD=0 ∧
    #   b=rev-list HEAD..base>0。_repo_base_relation は a==0 を先に判定し短絡＝contained→cnt=0→（窓消失×未終端×
    #   commit=0）で [SALVAGE]（harm(b) を守り drop/誤 suspect 化しない）。
    #   ★mutation RED（acceptance 1/3）: a==0 短絡を外し b を先に評価する / naive `merge-base --is-ancestor` gate へ
    #     差し替えると、この構成（base⊄HEAD ∧ b>0）で diverged 誤分類→cnt="乖離"→nocommit=0→[SUSPECT] になり
    #     下の `commit=0`/`[SALVAGE]` が RED になる＝a-first 分岐順序が load-bearing。
    local RBIN="$TEST_TMPDIR/rbin-m10"; _mk_realgit_bin "$RBIN"
    local R="$TEST_TMPDIR/ext-behind-m10"
    git init -q -b master "$R"                                # default branch = master
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init   # master: M
    git -C "$R" worktree add -q -b spawn/orch-extcb10-888 "$R/.worktrees/spawn/orch-extcb10-888" master   # cell 起点=master(0-ahead)
    echo m2 > "$R/m2"; git -C "$R" add m2; git -C "$R" -c commit.gpgsign=false commit -qm advance   # base(master) を 1 前進＝cell より先行(b>0)
    printf '%s' '[{"id":"orch-extcb10","status":"in_progress","notes":"作業中"}]' > "$FIX_DIR/bead-orch-extcb10.json"
    printf '%s\n' "$R" > "$TEST_TMPDIR/reg-m10"
    local SELFEMPTY="$TEST_TMPDIR/selfempty-m10"
    PATH="$RBIN:$PATH" \
      ORCH_DEGRADED_SKIP_SESSION_GATE=1 \
      ORCH_DEGRADED_SCRIPTORIUM="$SELFEMPTY" \
      ORCH_DEGRADED_WORKTREE_ROOT="$SELFEMPTY/.worktrees/spawn" \
      ORCH_DEGRADED_GATE_BASE="main" \
      ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/reg-m10" \
      run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    local line; line=$(_cell_line "orch-extcb10")
    [[ "$line" == *"[SALVAGE]"* ]]               # a=0 短絡→contained→cnt=0→（窓消失×未終端×commit=0）SALVAGE（gate 外すと SUSPECT で RED）
    [[ "$line" == *"commit=0"* ]]                # contained は commit=0（harm(b) を守る・誤 count しない）
    [[ "$line" != *"commit=乖離"* ]]             # a-first 短絡で b>0 を見ず＝diverged 誤分類しない（gate 外すと 乖離 で RED）
}

# ==============================================================================
# (E1) 集計 false-clean 不変条件（orch-b10 gate errata・major・teeth 欠落 pin）
#   _scan_root_cells が run_scan の local found_salvage/found_suspect を dynamic scope で加算する契約を pin する。
#   既存 test は [SALVAGE]/[SUSPECT] 行（_scan_root_cells が直接 printf）は見るが集計行を見ないため、
#   `_scan_root_cells` 冒頭に `local found_salvage=0 found_suspect=0` を挿す mutation（＝呼び先で shadow され
#   run_scan の counter が 0 のまま残る）が 25/25 green で生き残った（gate 実証済）。SALVAGE/SUSPECT が出る
#   fixture で (a)「degraded/suspect: なし」が出ない (b)「集計: salvage=N suspect=M」の実数、を assert する。
# ==============================================================================
@test "(E1) 集計 false-clean 不変条件: SALVAGE/SUSPECT が出るとき『なし』でなく実数の集計行を出す（dynamic-scope counter teeth）" {
    run_scan   # 既定 fixture: aaa=SALVAGE / bbb,eee=SUSPECT（salvage=1 suspect=2）
    # (a) SALVAGE/SUSPECT が実在するのに false-clean「degraded/suspect: なし」を出さない。
    [[ "$output" != *"degraded/suspect: なし"* ]]
    # (b) 集計行が実数（salvage=1 suspect=2）で出る＝counter が run_scan へ伝播している（shadow mutation なら 0 0 で RED）。
    [[ "$output" == *"集計: salvage=1 suspect=2"* ]]
}

# ==============================================================================
# (E3) registry 重複行の read 側 dedupe（orch-b10 gate errata・minor・TOCTOU 緩和 teeth）
#   _register_external_repo の grep→append は非アトミック（並列 dispatch で同一 root が重複行残留しうる）。
#   read 側（_external_scan_roots）で emit 済み root を skip し scan の二重 emit を防ぐ。registry に同一 root を
#   2 行入れて external cell の SALVAGE が 1 回だけ出ることを pin（dedupe を外すと 2 回で RED）。
# ==============================================================================
@test "(E3) registry 重複行でも external cell を二重 emit しない（read 側 dedupe teeth）" {
    local EXTDIR="$TEST_TMPDIR/ext-dup"
    _mk_ext_cell "$EXTDIR" "orch-extd-444444" "spawn/orch-extd-444444" "0" "6 hours ago" "in_progress" "作業中"
    printf '%s\n%s\n' "$EXTDIR" "$EXTDIR" > "$TEST_TMPDIR/registry"   # 同一 root を 2 行（TOCTOU 重複を模す）
    export ORCH_DEGRADED_EXTERNAL_REGISTRY="$TEST_TMPDIR/registry"
    run_scan
    # 重複行があっても external cell の SALVAGE は 1 回だけ（dedupe を外すと 2 回で RED＝集計水増し防止）。
    local n; n=$(printf '%s\n' "$output" | grep -c '\[SALVAGE\][[:space:]]\+orch-extd\b' || true)
    [ "$n" -eq 1 ]
    # header の external roots 列挙も 1 回（重複しない）。
    local h; h=$(printf '%s\n' "$output" | grep -oF "$EXTDIR/.worktrees/spawn" | wc -l)
    [ "$h" -eq 1 ]
}

# ==============================================================================
# (E2-libabsent) 共有 anchor lib 不在なら fail-closed exit1（orch-49g errata E2・orch-hydrate.bats:142 同型）
#   orch_session.sh は先に source されるため置く（present）→ 後続の orch_anchor.sh source が fail-closed で die。
# ==============================================================================
@test "(E2-libabsent) 共有 anchor lib 不在なら fail-closed exit1 + loud message（orch-49g errata E2）" {
    local SB="$TEST_TMPDIR/sb-nolib"; mkdir -p "$SB/hooks/lib"
    cp "$SCRIPT" "$SB/orch-degraded-watch.sh"
    cp "$BATS_TEST_DIRNAME/../../scripts/hooks/lib/orch_session.sh" "$SB/hooks/lib/orch_session.sh"
    PATH="$BIN:$PATH" ORCH_DEGRADED_SKIP_SESSION_GATE=1 run bash "$SB/orch-degraded-watch.sh"
    [ "$status" -ne 0 ]
    [[ "$output" == *"共有 anchor lib 不在"* ]]
}

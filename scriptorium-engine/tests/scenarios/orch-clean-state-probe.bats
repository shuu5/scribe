#!/usr/bin/env bats
# tests/scenarios/orch-clean-state-probe.bats
#
# orch-clean-state-probe.sh（admin「bundle 境界 clean state」機械検証 probe・bd orch-i8b・grill SSOT orch-c8p G4）の
# 決定的 hermetic テスト。fleet-degraded-watch.bats / guard-health-banner.bats と同型で bd / tmux / git /
# orch-degraded-watch を PATH スタブに差し替え、実スクリプトを走らせて 4 核判定を assert する E2E。
#
# 検証する契約不変条件（acceptance (1)-(4)）:
#   (GREEN)  4 核すべて benign → exit 0・"GREEN（clean・respawn 可）"（respawn ゲートの pass 側）。
#   (a1)     幽霊 in_progress（snapshot 付き・window も worktree も無い）→ [RED] (a)・exit 1・id 明示。
#   (a2)     snapshot 付き in_progress だが live window wt-<id> 有り → [GREEN] (a)（実状態反映）。
#   (a3)     snapshot 付き in_progress だが spawn worktree 有り（window 無し）→ [GREEN] (a)。
#   (a4)     SELF_PREFIX filter: foreign(un-) in_progress は幽霊に数えない（自台帳 orch- のみ判定）。
#   (a5)     M3: snapshot 無し in_progress（courier 委任/inline）→ [GREEN] (a) + info 列挙（幽霊にしない）。
#   (b1)     M2: last-touched 在（委譲なし）→ [RED] (b) 判定不能（last-sync proxy 排除・fail-closed）。
#   (b1b)    F2 regression: last-sync mtime が last-touched より新しい（旧 proxy なら GREEN）＋委譲未設定
#            → それでも [RED]（旧 last-sync proxy への回帰＝false-clean を殺す pin）。
#   (b2)     push 既定: last-touched 不在 → [GREEN] (b)（変更記録なし）。
#   (b3)     push override: ORCH_CLEAN_PUSH_CHECK_CMD rc≠0 → [RED] (b)（委譲 red）/ rc0 → [GREEN]。
#   (c1)     degraded flagged だが gate-pending 未付与 → [RED] (c)・id 明示。
#   (c2)     degraded flagged だが gate-pending 可視 → [GREEN] (c)（admin 認識済）。
#   (c3)     degraded clean（flagged 無し）→ [GREEN] (c)。
#   (c4)     degraded-watch 実行不能 → [RED] (c)（fail-closed・判定不能を clean と偽らない）。
#   (c5)     M1: degraded flagged だが terminal 宣言済 → [GREEN] (c) + worktree cleanup 案内（respawn 妨げない）。
#   (c6)     M4: degraded-watch 実行可能だが rc≠0（空 stdout クラッシュ）→ [RED] (c)・rc 明記（fail-closed）。
#   (c7)     F5/m1 pin: ORCH_CLEAN_DONE_STATUS のカスタム値が ORCH_DEGRADED_DONE_STATUS として
#            degraded-watch 合成呼出へ伝播する（stub が受領 env を log し assert）。
#   (cINTEG) ★anti-vacuity keystone: 実 orch-degraded-watch.sh を leaf stub 越しに合成し、本物の [SALVAGE]
#            emit フォーマットが check_c の $2 抽出を通ることを pin（stub 任せの format 乖離 vacuity を殺す）。
#   (NONCANON)  orch-axg: env override 無しでも probe:91 が git 動的解決で非 canonical anchor を採り、
#            check_c の ORCH_DEGRADED_SCRIPTORIUM/_WORKTREE_ROOT forward が動的解決結果を渡す（acceptance 1/2・
#            probe header anchor= と leaf stub 受領 env を assert・旧 hardcode なら canonical で不一致→落ちる）。
#   (NONCANON2) orch-axg: 非 canonical anchor の degraded cell を実 degraded-watch 合成で検出して (c) RED
#            （composed bypass の false-GREEN を殺す anti-vacuity・acceptance 3）。
#   (d1)     worktree 先行 commit>0・非 terminal・非 gate-pending → [RED] (d)・id+commit 明示。
#   (d2)     worktree 先行 commit>0 だが terminal 宣言済 → [GREEN] (d)。
#   (d3)     worktree 先行 commit>0 だが gate-pending 可視 → [GREEN] (d)。
#   (d4)     worktree 先行 commit=0 → [GREEN] (d)（成果物なし＝対象外）。
#   (d5)     m6: git rev-list 失敗 cell を skip せず [RED] (d) 判定不能・id 明示（fail-closed 契約整合）。
#   (d6)     m5: bead status 非 terminal だが notes 最終 STATUS が terminal → [GREEN] (d)（notes-STATUS 分岐）。
#   (COMPOSE) 任意の 1 核 red で全体 exit 1・"RED（respawn 不可"。
#   (ACT)    acceptance (4): 各 RED 核は "→ 片付け:" actionable 行を伴う。
#   (LIVE)   bd read liveness（finding orch-i8b / grill G4）: bd rc≠0/非 JSON → 全体 RED・exit 1
#            （判定材料欠落を clean と偽らない fail-closed・全 benign env でも false-clean へ落ちない）。
#   (LIVE2)  m7: bd rc0 だが非 JSON stdout → 全体 RED・exit 1（liveness fail-closed）。
#   (LIVE3)  ★F1 regression pin: PATH から jq を実除去（python3 在・snapshot 付き幽霊在）→ 全体 RED
#            （jq 不在の理由文）。fallback GREEN 退行なら「helper 空読み→幽霊不可視の全体 GREEN」に落ちる
#            ところを exit1 で殺す（PATH 再構成 fixture・env 渡しだけでは不十分ゆえ実除去）。
#   (LIVE4)  F1: jq 不在（全核 benign）→ RED 理由文が「jq 不在・bd 障害ではない」と正確に帰属する。
#   (LIVE5)  m7: JSON 配列検証器を確認できない（jq 在・verifiers 空振り）→ 検証器不在で判定不能 RED
#            （bd 障害と誤帰属しない）。
#   (DRY2)   F6/m4 pin: ORCH_CLEAN_PUSH_CHECK_CMD 設定時の --dry-run で (b) plan 行が委譲コマンドを
#            1 回だけ表示する（${VAR:+}${VAR:-} 二重表示への回帰を殺す）。
#   (EXEC)   distribution 契約: SCRIPT に実行ビットがある（bare path 単発起動＝acceptance 2・respawn 規約 E）。
#   (HGATE)  self-scope gate: foreign cwd（dolt_database≠orch）は refuse・exit 1・check を出さない。
#   (SEC1)   read-only verb discipline（safety core・無人実行で guard 射程外＝test が唯一のモート）:
#            bd=list|show のみ / tmux=list-panes のみ / git=**subcommand 粒度**で rev-list --count|branch --show-current|
#            worktree list のみ（他 subcommand・破壊 subverb〔branch -D 等〕が出たら RED）。
#   (SEC1-teeth) SEC1 の allowlist が subcommand 粒度で破壊 subverb/flag（branch -D / worktree remove / push 等）を
#            RED 化することを合成 log で実証（mutation 非vacuity・orch-7l4＝旧 verb 粒度なら branch -D 素通しだった穴）。
#   (SEC2)   write-isolation: probe は worktree/anchor 配下に新規 file を一切生まない（file-set 不変）。
#   (DRY)    --dry-run は exit 0・mutate ゼロ・[plan] を列挙（check を実行しない）。
#
# 実行: bats tests/scenarios/orch-clean-state-probe.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-clean-state-probe.sh"
    TEST_TMPDIR=$(mktemp -d -t clean-probe-bats-XXXXXX)
    export FIX_DIR="$TEST_TMPDIR"
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"

    # anchor 配下に .beads（push proxy 用）と .worktrees/spawn（cell 走査 root）を実配置に合わせて置く。
    ANCHOR="$TEST_TMPDIR/anchor"
    BEADS="$ANCHOR/.beads"
    WROOT="$ANCHOR/.worktrees/spawn"
    mkdir -p "$BEADS" "$WROOT"

    # ── stub: bd（list --status=in_progress / list --label gate-pending / show <id> --long --json）──
    #   ★全 argv を bd-invocations.log に記録（SEC1 が list|show 以外の verb を RED 化）。
    #   挙動制御 env: STUB_IP_IDS / STUB_GATE_IDS / STUB_TERMINAL_IDS（CSV）。
    cat > "$BIN/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/bd-invocations.log"
# STUB_BD_FAIL: bd 全断（read 疎通失敗）をシミュレート＝呼び出しを rc 1 で落とす（呼び出しは log 済）。
[ -n "${STUB_BD_FAIL:-}" ] && exit 1
# STUB_BD_NONJSON: rc0 だが非 JSON stdout（liveness の JSON 配列検証を落とす・m7）。
[ -n "${STUB_BD_NONJSON:-}" ] && { printf 'GARBAGE-NON-JSON'; exit 0; }
emit_ids() { # $1=CSV → JSON array of {id}
  local csv="$1" first=1; printf '['
  IFS=',' read -ra a <<< "$csv"
  for x in "${a[@]}"; do [ -n "$x" ] || continue; [ $first -eq 1 ] || printf ','; printf '{"id":"%s"}' "$x"; first=0; done
  printf ']'
}
case "$*" in
  *"list"*"--status=in_progress"*) emit_ids "${STUB_IP_IDS:-}"; exit 0 ;;
  *"list"*"--label gate-pending"*) emit_ids "${STUB_GATE_IDS:-}"; exit 0 ;;
  *"show"*"--long"*"--json"*)
    id=""; for a in "$@"; do case "$a" in show|--*) : ;; *) [ -z "$id" ] && id="$a" ;; esac; done
    st="open"; case ",${STUB_TERMINAL_IDS:-}," in *",$id,"*) st="closed" ;; esac
    # STUB_SNAPSHOT_IDS: notes に dispatch snapshot marker を載せる（M3・check_a の local cell 証跡）。
    # STUB_NOTES_STATUS_IDS: notes 最終 STATUS 行を terminal（status 非 terminal でも）にする（m5・_bead_terminal notes 分岐）。
    notes=""
    case ",${STUB_SNAPSHOT_IDS:-}," in *",$id,"*) notes="[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1] bd=$id" ;; esac
    case ",${STUB_NOTES_STATUS_IDS:-}," in *",$id,"*) notes="${notes:+$notes\\n}STATUS: done — test-terminal" ;; esac
    printf '[{"id":"%s","status":"%s","notes":"%s"}]' "$id" "$st" "$notes"; exit 0 ;;
  *) exit 0 ;;
esac
STUB

    # ── stub: tmux（list-panes -a -F '#{window_name}' → STUB_WINDOWS 改行区切り）──
    cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/tmux-invocations.log"
case "$1" in
  list-panes) printf '%s\n' "${STUB_WINDOWS:-}" ;;
esac
exit 0
STUB

    # ── stub: git（-C <dir> の per-worktree fixture .branch/.count/.quiet を読む）──
    cat > "$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/git-invocations.log"
dir=""; if [ "$1" = "-C" ]; then dir="$2"; shift 2; fi
case "$1 $2" in
  "branch --show-current") cat "$dir/.branch" 2>/dev/null ;;
  "rev-list --count")                                            # base..HEAD 引数は無視
      c="$(cat "$dir/.count" 2>/dev/null)"
      [ "$c" = "REVLIST_FAIL" ] && exit 1                        # m6: rev-list 解決不能を rc≠0 で再現
      printf '%s' "$c" ;;
  "log -1")                cat "$dir/.quiet"  2>/dev/null ;;   # 実 degraded-watch の quiet 補助用
  # orch-axg: _resolve_scriptorium の `git worktree list --porcelain` を stub 化。STUB_WORKTREE_TOP 設定時のみ
  #   porcelain 先頭 `worktree <path>` を emit（＝anchor 動的解決を非 canonical fixture へ向ける）。未設定時は
  #   何も出さず _resolve_scriptorium を fallback（hardcode）へ落とす＝env override する既存 case には無影響。
  "worktree list") [ -n "${STUB_WORKTREE_TOP:-}" ] && printf 'worktree %s\n' "$STUB_WORKTREE_TOP" ;;
esac
exit 0
STUB

    # ── stub: degraded-watch（STUB_DEGRADED_FLAGGED CSV を実物と同一 emit フォーマット `  [SALVAGE] %-12s ...` で出す）──
    #   実物 orch-degraded-watch.sh の L226/238 の printf 形式に一致させる（$2=id を check_c awk が抽出）。
    cat > "$BIN/degraded-watch" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIX_DIR/dw-invocations.log"
# F5/m1 pin: 受領した ORCH_DEGRADED_DONE_STATUS を log（probe の env forward を assert 可能にする）。
printf 'DONE_STATUS=%s\n' "${ORCH_DEGRADED_DONE_STATUS:-unset}" >> "$FIX_DIR/dw-invocations.log"
# orch-axg pin: 受領した SCRIPTORIUM/WORKTREE_ROOT を log（動的解決結果の forward を assert 可能にする）。
printf 'SCRIPTORIUM=%s\n' "${ORCH_DEGRADED_SCRIPTORIUM:-unset}" >> "$FIX_DIR/dw-invocations.log"
printf 'WORKTREE_ROOT=%s\n' "${ORCH_DEGRADED_WORKTREE_ROOT:-unset}" >> "$FIX_DIR/dw-invocations.log"
IFS=',' read -ra a <<< "${STUB_DEGRADED_FLAGGED:-}"
for x in "${a[@]}"; do
  [ -n "$x" ] && printf '  [SALVAGE] %-12s 窓消失 × CLOSED不在 × commit=0  branch=spawn/%s-1 quiet=x\n' "$x" "$x"
done
exit "${STUB_DW_RC:-0}"   # M4: STUB_DW_RC で実行可能だが rc≠0（クラッシュ）を再現
STUB

    chmod +x "$BIN/bd" "$BIN/tmux" "$BIN/git" "$BIN/degraded-watch"
}

teardown() {
    [ -n "$TEST_TMPDIR" ] && rm -rf "$TEST_TMPDIR"
}

# spawn worktree fixture を作る（branch=spawn/<id>-1・.count=先行 commit 数）。
_mkwt() { # id count
    local d="$WROOT/$1-1"; mkdir -p "$d"
    printf 'spawn/%s-1' "$1" > "$d/.branch"
    printf '%s' "$2" > "$d/.count"
}

# 共通 env で probe を実行（self-scope skip・PATH スタブ差替・全 override を stub 系へ向ける）。
run_probe() {
    PATH="$BIN:$PATH" \
      ORCH_CLEAN_SKIP_SESSION_GATE=1 \
      ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" \
      ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" \
      ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" \
      ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash "$SCRIPT"
}

# 核 a/b/c/d の出力行を抽出（"(a)".."(d)" を含む行・grep 不一致でも exit 0）。
_core() { printf '%s\n' "$output" | grep -F "($1)" || true; }

# git-invocations.log の各 argv から先頭 "-C <dir>" を剥がした **先頭2トークン（subcommand + 次トークン）** を取り、
# read-only 実使用形の完全一致 allowlist 外を抽出する（空＝規律 OK・非空＝違反 verb 列）。**verb 粒度でなく
# subcommand/flag 粒度**なので `branch -D`（破壊）は `branch --show-current`（read）と別物として弾く（orch-7l4・
# 旧 verb 粒度では `branch` が丸ごと許可され `branch -D` が素通しした穴を塞ぐ）。SEC1 / (SEC1-teeth) / (NONCANON) が
# 共有しフィルタ論理のドリフトを防ぐ単一 SSOT。allowlist は probe scan の実使用形: rev-list --count（先行 commit 数）/
# branch --show-current（branch 名）/ worktree list（_resolve_scriptorium の anchor 解決）。probe は git log を scan
# 経路で叩かないため log は allowlist に含めない（fail-closed＝将来 log 追加時は RED で気付く）。
_git_offending_verbs() { # $1=logfile
    sed -E 's/^-C [^ ]+ //' "$1" \
      | awk '{print $1" "$2}' \
      | sort -u \
      | grep -vE '^(rev-list --count|branch --show-current|worktree list)$' || true
}

# ==============================================================================
# (GREEN) 4 核 benign → clean・exit 0
# ==============================================================================
@test "(GREEN) 全核 benign（in_progress/gate/degraded/worktree/last-touched なし）→ exit0・clean" {
    run_probe
    [ "$status" -eq 0 ]
    [[ "$output" == *"GREEN（clean・respawn 可）"* ]]
}

# ==============================================================================
# 核 (a): in_progress 反映
# ==============================================================================
@test "(a1) 幽霊 in_progress（snapshot 付き・window/worktree 無し）→ [RED] (a)・exit1・id 明示" {
    export STUB_IP_IDS="orch-ghost"
    export STUB_SNAPSHOT_IDS="orch-ghost"   # M3: local cell 証跡あり＝幽霊判定対象
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core a)
    [[ "$line" == *"[RED]"* ]]
    [[ "$output" == *"orch-ghost"* ]]
}

@test "(a2) snapshot 付き in_progress だが live window wt-<id> 有り → [GREEN] (a)" {
    export STUB_IP_IDS="orch-live"
    export STUB_SNAPSHOT_IDS="orch-live"
    export STUB_WINDOWS="wt-orch-live"
    run_probe
    local line; line=$(_core a)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(a3) snapshot 付き in_progress だが spawn worktree 有り（window 無し）→ [GREEN] (a)" {
    export STUB_IP_IDS="orch-wt"
    export STUB_SNAPSHOT_IDS="orch-wt"
    _mkwt orch-wt 0
    run_probe
    local line; line=$(_core a)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(a4) SELF_PREFIX filter: foreign(un-) in_progress は幽霊に数えない（orch- のみ判定）" {
    export STUB_IP_IDS="un-foreign,orch-ghost"
    export STUB_SNAPSHOT_IDS="orch-ghost"
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core a)
    [[ "$line" == *"[RED]"* ]]
    [[ "$output" == *"orch-ghost"* ]]
    # un-foreign は幽霊集計に含めない（自台帳 write-isolation の read filter と対称）。
    [[ "$output" != *"un-foreign"* ]]
}

@test "(a5) M3: snapshot 無し in_progress（courier 委任/inline）→ [GREEN] (a) + info 列挙（幽霊にしない）" {
    export STUB_IP_IDS="orch-inline"
    # STUB_SNAPSHOT_IDS 未設定＝local cell 証跡なし＝(a) 幽霊対象外。
    run_probe
    [ "$status" -eq 0 ]
    local line; line=$(_core a)
    [[ "$line" == *"[GREEN]"* ]]
    [[ "$output" == *"local cell 非対象"* ]]
    [[ "$output" == *"orch-inline"* ]]
}

# ==============================================================================
# 核 (b): push 済（proxy / override）
# ==============================================================================
@test "(b1) M2: last-touched 在（委譲なし）→ [RED] (b) 判定不能（fail-closed・last-sync proxy 排除）" {
    printf 'orch-x' > "$BEADS/last-touched"   # last-sync は見ない（M2 で排除）
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core b)
    [[ "$line" == *"[RED]"* ]]
    [[ "$line" == *"判定不能"* ]]
    # 委譲を促す actionable（ORCH_CLEAN_PUSH_CHECK_CMD）が出る。
    [[ "$output" == *"ORCH_CLEAN_PUSH_CHECK_CMD"* ]]
}

@test "(b1b) F2 regression: last-sync mtime > last-touched mtime（旧 proxy なら GREEN）＋委譲未設定 → それでも [RED]" {
    # ★M2 の核を pin: 旧 last-sync proxy（touched ≤ sync → GREEN）なら false-clean になる構成を作る。
    #   定常 hydrate（sync-in）直後＝last-sync が最新、の実測退行シナリオそのもの。回帰したらこの test が落ちる。
    printf 'y' > "$BEADS/last-touched"; sleep 1; printf 'x' > "$BEADS/last-sync"
    # 前提確認（非 vacuity）: last-sync が本当に新しい（旧 proxy の GREEN 条件が成立している）。
    [ "$BEADS/last-sync" -nt "$BEADS/last-touched" ]
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core b)
    [[ "$line" == *"[RED]"* ]]
    [[ "$line" == *"判定不能"* ]]
}

@test "(b2) push 既定: last-touched 不在 → [GREEN] (b)（変更記録なし）" {
    # setup の BEADS は空（last-touched 無し）＝この核だけ見れば GREEN。
    run_probe
    local line; line=$(_core b)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(b3) push override: ORCH_CLEAN_PUSH_CHECK_CMD rc≠0 → [RED] (b) / rc0 → [GREEN]" {
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      ORCH_CLEAN_PUSH_CHECK_CMD="exit 3" run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$(printf '%s\n' "$output" | grep -F '(b)')" == *"[RED]"* ]]

    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      ORCH_CLEAN_PUSH_CHECK_CMD="exit 0" run bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | grep -F '(b)')" == *"[GREEN]"* ]]
}

# ==============================================================================
# 核 (c): degraded clean（or 全 gate-pending 可視）
# ==============================================================================
@test "(c1) degraded flagged だが gate-pending 未付与 → [RED] (c)・id 明示" {
    export STUB_DEGRADED_FLAGGED="orch-dead"
    export STUB_GATE_IDS=""
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core c)
    [[ "$line" == *"[RED]"* ]]
    [[ "$output" == *"orch-dead"* ]]
}

@test "(c2) degraded flagged だが gate-pending 可視 → [GREEN] (c)" {
    export STUB_DEGRADED_FLAGGED="orch-dead"
    export STUB_GATE_IDS="orch-dead"
    run_probe
    local line; line=$(_core c)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(c3) degraded clean（flagged 無し）→ [GREEN] (c)" {
    run_probe
    local line; line=$(_core c)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(c4) degraded-watch 実行不能 → [RED] (c)（fail-closed・判定不能を clean と偽らない）" {
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$TEST_TMPDIR/no-such-degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$(printf '%s\n' "$output" | grep -F '(c)')" == *"[RED]"* ]]
}

@test "(c5) M1: degraded flagged だが terminal 宣言済 → [GREEN] (c) + cleanup 案内・全体 exit0（respawn 妨げない）" {
    export STUB_DEGRADED_FLAGGED="orch-dead"
    export STUB_TERMINAL_IDS="orch-dead"   # closed＝post-merge/cleanup 待ち＝未認識 degraded と数えない
    export STUB_GATE_IDS=""
    run_probe
    [ "$status" -eq 0 ]
    local line; line=$(_core c)
    [[ "$line" == *"[GREEN]"* ]]
    # 無言 GREEN でなく worktree cleanup を促す remediation 行が出る（M1）。
    [[ "$output" == *"worktree cleanup"* ]]
    [[ "$output" == *"orch-dead"* ]]
}

@test "(c6) M4: degraded-watch 実行可能だが rc≠0（空 stdout クラッシュ）→ [RED] (c)・rc 明記・exit1（fail-closed）" {
    export STUB_DW_RC=1
    export STUB_DEGRADED_FLAGGED=""   # 空 stdout でも rc≠0 を silent GREEN にしない
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core c)
    [[ "$line" == *"[RED]"* ]]
    [[ "$line" == *"rc=1"* ]]
}

@test "(c7) F5/m1 pin: ORCH_CLEAN_DONE_STATUS が ORCH_DEGRADED_DONE_STATUS として degraded-watch へ伝播する" {
    export ORCH_CLEAN_DONE_STATUS="closed,blocked,parked"
    run_probe
    # stub degraded-watch が受領 env を log に残す＝forward の実在を pin（m1 の未 pin を解消）。
    grep -qxF 'DONE_STATUS=closed,blocked,parked' "$FIX_DIR/dw-invocations.log"
}

@test "(cINTEG) 実 degraded-watch を leaf stub 越しに合成し emit フォーマット契約ごと check_c を通す（anti-vacuity keystone）" {
    local REAL="$BATS_TEST_DIRNAME/../../scripts/orch-degraded-watch.sh"
    [ -x "$REAL" ]
    _mkwt orch-dead 0                 # commit=0（核C）
    export STUB_WINDOWS=""            # 窓消失（核A・全 cell）
    export STUB_TERMINAL_IDS=""       # bead open＝未終端（核B）
    export STUB_GATE_IDS=""           # gate-pending 未付与
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$REAL" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    local line; line=$(printf '%s\n' "$output" | grep -F "(c)")
    [[ "$line" == *"[RED]"* ]]
    [[ "$line" == *"orch-dead"* ]]
}

# ==============================================================================
# (NONCANON) 非 canonical anchor 動的解決（orch-axg・pso composed bypass 解消）
#   probe:91 の SCRIPTORIUM が env 最優先 + git 動的解決 + hardcode fallback（PR#53 同型）になり、
#   env override 無しでも `git worktree list` 先頭から非 canonical anchor へ解決し、check_c の
#   ORCH_DEGRADED_SCRIPTORIUM/_WORKTREE_ROOT forward が動的解決結果を渡すことを pin する。
# ==============================================================================
@test "(NONCANON) 非 canonical anchor: env override 無しで git 動的解決 → SCRIPTORIUM/WORKTREE_ROOT を非 canonical anchor へ解決し degraded-watch へ forward（acceptance 1/2・orch-axg）" {
    # 非 canonical anchor（hardcode canonical と別 path）。env override（SCRIPTORIUM/WORKTREE_ROOT/BEADS_DIR）は
    # 敢えて渡さず、git stub の `worktree list` が返す非 canonical anchor を _resolve_scriptorium 経由で採らせる。
    local NC="$TEST_TMPDIR/noncanon"; mkdir -p "$NC/.beads" "$NC/.worktrees/spawn"
    # orch-49g: E2 anchor 検証（dolt_database==orch）を通すため非 canonical anchor にも orch 台帳 metadata を置く
    #   （relocate された real scriptorium anchor は当然 orch 台帳を持つ＝faithful 化。foreign 台帳なら reject される
    #   のは (E2reject) test で pin）。
    printf '{"dolt_database":"orch"}' > "$NC/.beads/metadata.json"
    export STUB_WORKTREE_TOP="$NC"
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" \
      run bash "$SCRIPT"
    # acceptance(1): probe header の anchor/worktree_root が動的解決した非 canonical anchor（旧 hardcode なら canonical で不一致→落ちる）。
    [[ "$output" == *"anchor=$NC"* ]]
    [[ "$output" == *"worktree_root=$NC/.worktrees/spawn"* ]]
    # acceptance(2): degraded-watch への forward が動的解決結果を渡す（leaf stub が受領 env を log）。
    grep -qxF "SCRIPTORIUM=$NC" "$FIX_DIR/dw-invocations.log"
    grep -qxF "WORKTREE_ROOT=$NC/.worktrees/spawn" "$FIX_DIR/dw-invocations.log"
    # ── SEC1 no-override 経路の verb 検査（orch-7l4 (b)・axg WF 指摘）──────────────────────────────
    #   SEC1 fixture（run_probe）は SCRIPTORIUM/WORKTREE_ROOT override で解決を短絡するため `git worktree list` を
    #   叩かず、worktree list allowlist entry が inert（許可されるが exercise されない）。本 case は env override を
    #   渡さず _resolve_scriptorium が実走し `git worktree list --porcelain` を実際に叩く＝no-override 経路を
    #   end-to-end で通す。この経路で叩かれる全 git subcommand が read-only 実使用形の allowlist 内であることを
    #   SEC1 と同じフィルタ（_git_offending_verbs）で pin する。
    run _git_offending_verbs "$FIX_DIR/git-invocations.log"
    [ -z "$output" ]
    # 非 vacuity: worktree list が実際に呼ばれた（no-override 経路を通り _resolve_scriptorium が実走した直接証明・
    #   これが無いと「inert entry を exercise した」主張が空振りになる）。
    run bash -c 'sed -E "s/^-C [^ ]+ //" "$1" | awk "{print \$1\" \"\$2}" | grep -Fxq "worktree list"' _ "$FIX_DIR/git-invocations.log"
    [ "$status" -eq 0 ]
}

@test "(NONCANON2) 非 canonical anchor の degraded cell を実 degraded-watch 合成で捕捉（composed bypass の false-GREEN を殺す anti-vacuity・acceptance 3・orch-axg）" {
    local REAL="$BATS_TEST_DIRNAME/../../scripts/orch-degraded-watch.sh"
    [ -x "$REAL" ]
    # 非 canonical anchor に degraded cell（窓消失 × 未終端 × commit=0 = salvage）を置く。
    local NC="$TEST_TMPDIR/noncanon2"; mkdir -p "$NC/.beads"
    printf '{"dolt_database":"orch"}' > "$NC/.beads/metadata.json"   # orch-49g: E2 検証を通す orch 台帳（faithful 化）
    local NCWROOT="$NC/.worktrees/spawn"; mkdir -p "$NCWROOT/orch-ncdead-1"
    printf 'spawn/orch-ncdead-1' > "$NCWROOT/orch-ncdead-1/.branch"
    printf '0' > "$NCWROOT/orch-ncdead-1/.count"       # commit=0（核C）
    export STUB_WORKTREE_TOP="$NC"      # 動的解決 → 非 canonical anchor
    export STUB_WINDOWS=""              # 窓消失（核A・全 cell）
    export STUB_TERMINAL_IDS=""         # 未終端（核B）
    export STUB_GATE_IDS=""             # gate-pending 未付与
    # env override（SCRIPTORIUM/WORKTREE_ROOT/BEADS_DIR）を渡さない＝動的解決結果のみが degraded-watch へ届く。
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$REAL" \
      run bash "$SCRIPT"
    # 旧 hardcode なら canonical(空) を scan して (c) GREEN（false-clean）に落ちるところを、
    # 非 canonical anchor の degraded cell を検出して (c) RED・exit1 で殺す。
    [ "$status" -ne 0 ]
    local line; line=$(printf '%s\n' "$output" | grep -F "(c)")
    [[ "$line" == *"[RED]"* ]]
    [[ "$output" == *"orch-ncdead"* ]]
}

# ==============================================================================
# 核 (d): 未宣言仕掛かり
# ==============================================================================
@test "(d1) worktree 先行 commit>0・非 terminal・非 gate → [RED] (d)・id+commit 明示" {
    _mkwt orch-wip 2
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core d)
    [[ "$line" == *"[RED]"* ]]
    [[ "$output" == *"orch-wip"* ]]
    [[ "$output" == *"commit=2"* ]]
}

@test "(d2) worktree 先行 commit>0 だが terminal 宣言済 → [GREEN] (d)" {
    _mkwt orch-wip 2
    export STUB_TERMINAL_IDS="orch-wip"
    run_probe
    local line; line=$(_core d)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(d3) worktree 先行 commit>0 だが gate-pending 可視 → [GREEN] (d)" {
    _mkwt orch-wip 2
    export STUB_GATE_IDS="orch-wip"
    run_probe
    local line; line=$(_core d)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(d4) worktree 先行 commit=0 → [GREEN] (d)（成果物なし＝対象外）" {
    _mkwt orch-wip 0
    run_probe
    local line; line=$(_core d)
    [[ "$line" == *"[GREEN]"* ]]
}

@test "(d5) m6: git rev-list 失敗 cell を skip せず [RED] (d) 判定不能・id 明示（fail-closed 契約整合）" {
    _mkwt orch-broken REVLIST_FAIL   # .count=REVLIST_FAIL → git stub が rev-list を rc≠0 で落とす
    run_probe
    [ "$status" -ne 0 ]
    local line; line=$(_core d)
    [[ "$line" == *"[RED]"* ]]
    [[ "$output" == *"orch-broken"* ]]
    [[ "$output" == *"解決不能"* ]]
}

@test "(d6) m5: bead status 非 terminal だが notes 最終 STATUS が terminal → [GREEN] (d)（notes-STATUS 分岐を通す）" {
    _mkwt orch-wip 2
    export STUB_NOTES_STATUS_IDS="orch-wip"   # status=open だが notes に "STATUS: done"＝_bead_terminal 真
    run_probe
    local line; line=$(_core d)
    [[ "$line" == *"[GREEN]"* ]]
}

# ==============================================================================
# (COMPOSE) 任意の 1 核 red で全体 exit 1
# ==============================================================================
@test "(COMPOSE) 1 核（d）だけ red でも全体 exit1・RED 判定" {
    _mkwt orch-wip 2
    run_probe
    [ "$status" -ne 0 ]
    [[ "$output" == *"RED（respawn 不可"* ]]
}

# ==============================================================================
# (ACT) acceptance (4): 各 RED 核は actionable な "→ 片付け:" を伴う
# ==============================================================================
@test "(ACT) 4 核すべて red のとき「→ 片付け:」actionable 行が 4 本以上出る（acceptance 4）" {
    export STUB_IP_IDS="orch-ghost"                # (a) red
    export STUB_SNAPSHOT_IDS="orch-ghost"          # M3: local cell 証跡＝幽霊判定対象
    export STUB_DEGRADED_FLAGGED="orch-dead"       # (c) red
    export STUB_GATE_IDS=""
    _mkwt orch-wip 2                               # (d) red
    printf 'y' > "$BEADS/last-touched"             # (b) red（M2: last-touched 在＝判定不能）
    run_probe
    [ "$status" -ne 0 ]
    local n; n=$(printf '%s\n' "$output" | grep -c '→ 片付け:')
    [ "$n" -ge 4 ]
}

# ==============================================================================
# (HGATE) self-scope gate（fail-closed）
# ==============================================================================
@test "(HGATE) foreign cwd（dolt_database≠orch）は refuse・exit1・check を出さない" {
    local FOREIGN="$TEST_TMPDIR/foreign"; mkdir -p "$FOREIGN/.beads"
    printf '{"dolt_database":"un"}' > "$FOREIGN/.beads/metadata.json"
    PATH="$BIN:$PATH" ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" ORCH_CLEAN_BD="$BIN/bd" \
      ORCH_CLEAN_TMUX="$BIN/tmux" ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" \
      ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash -c 'cd "$1" && bash "$2"' _ "$FOREIGN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"(a) in_progress"* ]]
}

@test "(HGATE2) 破損 orch-token metadata（orch トークン在るが JSON 破損）→ refuse・exit1（_json_is_valid gate が誤 self-scope を防ぐ・t9z H3 同型・orch-vo2）" {
    # drift teeth（orch-vo2 acceptance 3）: 旧 inline _resolve_dolt_database（gate なし sed 直抽出）は
    # 破損 JSON でも orch トークンを抽出して誤 self-scope（gate 通過）した。共有 lib の gate 済み
    # _ledger_dolt_database は _json_is_valid で破損を検出し空 db に畳む＝refuse 側（fail-closed）へ倒す。
    # この case は旧実装なら「refuse しない」で落ちる回帰 teeth（jq/python3/node いずれの検証器でも、
    # また全て不在でも破損 JSON は不採用→空 db→refuse ゆえ安全側で一貫する）。
    local BROKEN="$TEST_TMPDIR/broken"; mkdir -p "$BROKEN/.beads"
    printf '{"dolt_database":"orch"' > "$BROKEN/.beads/metadata.json"   # 未閉じ = 破損 JSON（orch トークン在）
    PATH="$BIN:$PATH" ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" ORCH_CLEAN_BD="$BIN/bd" \
      ORCH_CLEAN_TMUX="$BIN/tmux" ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" \
      ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash -c 'cd "$1" && bash "$2"' _ "$BROKEN" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"(a) in_progress"* ]]
}

# ==============================================================================
# (SEC1) read-only verb discipline（safety core）
# ==============================================================================
@test "(SEC1) read-only verb: bd=list|show のみ / tmux=list-panes のみ / git=subcommand 粒度で rev-list --count|branch --show-current|worktree list のみ" {
    export STUB_IP_IDS="orch-a"
    export STUB_DEGRADED_FLAGGED="orch-a"
    _mkwt orch-a 2
    run_probe
    # 非 vacuous: 実際に 3 ツールを叩いている（log 空なら判定が空振り）。
    [ -s "$FIX_DIR/bd-invocations.log" ]
    [ -s "$FIX_DIR/tmux-invocations.log" ]
    [ -s "$FIX_DIR/git-invocations.log" ]
    # bd: list|show 以外の verb（update|create|close|assign|tag|sql|import|batch 等）が出たら RED。
    run bash -c 'awk "{print \$1}" "$1" | sort -u | grep -vE "^(list|show)$" || true' _ "$FIX_DIR/bd-invocations.log"
    [ -z "$output" ]
    # tmux: list-panes 以外が出たら RED。
    run bash -c 'awk "{print \$1}" "$1" | sort -u | grep -vxF list-panes || true' _ "$FIX_DIR/tmux-invocations.log"
    [ -z "$output" ]
    # git: 先頭 "-C <dir>" を剥がした **先頭2トークン**（subcommand + 次トークン）が read-only 実使用形の完全一致
    #      allowlist（rev-list --count|branch --show-current|worktree list）以外なら RED。**subcommand/flag 粒度**ゆえ
    #      `branch -D`（破壊）は `branch --show-current`（read）と別物として弾く（orch-7l4＝旧 verb 粒度では `branch`
    #      が丸ごと許可され `branch -D` が素通しした穴を塞ぐ。worktree は従来から 2 トークン照合＝orch-axg errata）。
    #      SEC1 fixture（run_probe）は env override で解決を短絡し `worktree list` を叩かないため worktree list entry は
    #      ここでは inert だが、(NONCANON) が no-override 経路で end-to-end に exercise する（axg 指摘 (b)）。破壊 subverb の
    #      RED 化は (SEC1-teeth) が合成 log で実証する。
    run _git_offending_verbs "$FIX_DIR/git-invocations.log"
    [ -z "$output" ]
}

# ==============================================================================
# (SEC1-teeth) SEC1 allowlist の subcommand 粒度 teeth（mutation 非vacuity 実証・orch-7l4）
#   SEC1 が読む allowlist フィルタ（_git_offending_verbs）が、実使用 read-only 形は通し、破壊 subverb/flag は
#   RED 化することを合成 git-invocations.log で直接実証する。旧 verb 粒度なら `branch -D` は `branch` として
#   allowlist を素通しした＝この test は allowlist を verb 粒度へ戻す退行を殺す恒久 teeth（acceptance 1/3・
#   fleet-degraded-watch.bats (SEC1-teeth) と同型）。
# ==============================================================================
@test "(SEC1-teeth) git allowlist は subcommand 粒度で破壊 subverb/flag を RED 化する（実使用 read-only 形は通す）" {
    local L="$TEST_TMPDIR/git-teeth.log"
    # (通す) probe scan の実使用 read-only 形は allowlist 内＝offending 空（read-only 形を false-positive で弾かない）。
    printf '%s\n' \
      '-C /wt rev-list --count main..HEAD' \
      '-C /wt branch --show-current' \
      '-C /wt worktree list --porcelain' > "$L"
    run _git_offending_verbs "$L"
    [ -z "$output" ]
    # (RED) 旧 verb 粒度なら `branch -D` が素通しした破壊 subverb/flag を subcommand 粒度で弾く＝mutation 非vacuity。
    printf '%s\n' \
      '-C /wt branch -D spawn/orch-a-1' \
      '-C /wt worktree remove /wt' \
      '-C /wt push origin main' \
      '-C /wt commit -m x' \
      '-C /wt checkout -b spawn/x' > "$L"
    run _git_offending_verbs "$L"
    [ -n "$output" ]
    [[ "$output" == *"branch -D"* ]]              # ★核: verb 粒度では素通しした破壊 subverb を弾く
    [[ "$output" == *"worktree remove"* ]]
    [[ "$output" == *"push origin"* ]]
    [[ "$output" == *"commit -m"* ]]
    [[ "$output" == *"checkout -b"* ]]
}

# ==============================================================================
# (SEC2) write-isolation: probe は worktree/anchor 配下に新規 file を生まない
# ==============================================================================
@test "(SEC2) probe は worktree/anchor 配下に新規 file を一切生まない（file-set 不変）" {
    export STUB_IP_IDS="orch-a"
    export STUB_DEGRADED_FLAGGED="orch-a"
    _mkwt orch-a 2
    local before after
    before=$(find "$ANCHOR" -type f | sort)
    run_probe
    after=$(find "$ANCHOR" -type f | sort)
    [ "$before" = "$after" ]
}

# ==============================================================================
# (DRY) --dry-run は plan 列挙・mutate ゼロ・check を実行しない
# ==============================================================================
@test "(DRY) --dry-run は exit0・[plan] を列挙し check（[RED]/[GREEN]）を実行しない" {
    export STUB_IP_IDS="orch-ghost"   # 通常実行なら (a) red になる材料
    local before after
    before=$(find "$ANCHOR" -type f | sort)
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"[plan]"* ]]
    # check を実行しない＝RED/GREEN 判定行を出さない。
    [[ "$output" != *"[RED]"* ]]
    [[ "$output" != *"[GREEN]"* ]]
    after=$(find "$ANCHOR" -type f | sort)
    [ "$before" = "$after" ]
}

@test "(DRY2) F6/m4 pin: 委譲設定時の --dry-run は (b) plan 行が委譲コマンドを 1 回だけ表示（二重表示回帰を殺す）" {
    local CMD="my-push-probe --check"
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      ORCH_CLEAN_PUSH_CHECK_CMD="$CMD" run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    # (b) plan 行は「委譲:」形で委譲コマンドを示す。
    local line; line=$(printf '%s\n' "$output" | grep -F '(b)')
    [[ "$line" == *"委譲: $CMD"* ]]
    # 委譲コマンドは出力全体でちょうど 1 回（旧 ${VAR:+...}${VAR:-...} は 2 回表示だった＝m4 の回帰 pin）。
    local n; n=$(printf '%s\n' "$output" | grep -oF "$CMD" | wc -l)
    [ "$n" -eq 1 ]
}

# ==============================================================================
# (LIVE) bd read liveness 事前検査（fail-closed の核・finding orch-i8b / grill G4）
#   bd が rc≠0（不在/未 hydrate/全断）だと (a)/(c)/(d) は『取得 0 件→GREEN』と実状態未確認のまま
#   clean を偽る＝自己申告 clean の捏造。gate が無ければ全 benign env で exit0（false-clean）になるので、
#   この test は STUB_BD_FAIL=1 かつ他核 benign（旧実装なら GREEN）で exit1・RED を pin する非 vacuous 検証。
# ==============================================================================
@test "(LIVE) bd read 不通（rc≠0）→ 全体 RED・exit1（判定材料欠落を clean と偽らない・fail-closed）" {
    export STUB_BD_FAIL=1
    # 他核は全て benign（in_progress/gate/degraded/worktree/last-touched なし）＝gate 無しなら誤って GREEN。
    run_probe
    [ "$status" -ne 0 ]
    [[ "$output" == *"bd 疎通"* ]]
    [[ "$output" == *"判定不能"* ]]
    [[ "$output" == *"RED（respawn 不可"* ]]
    # 非 vacuity: liveness は実際に bd を叩いている（log 空なら空振り）。
    [ -s "$FIX_DIR/bd-invocations.log" ]
}

@test "(LIVE2) m7: bd rc0 だが非 JSON stdout → 全体 RED・exit1（liveness fail-closed）" {
    export STUB_BD_NONJSON=1
    # 他核 benign。rc0 でも非 JSON 配列なら『取得 0 件 GREEN』へ落とさず RED。
    run_probe
    [ "$status" -ne 0 ]
    [[ "$output" == *"bd 疎通"* ]]
    [[ "$output" == *"判定不能"* ]]
    [ -s "$FIX_DIR/bd-invocations.log" ]
}

# jq 抜き PATH を実構成する（F1 regression 用 fixture）。probe と leaf stub が必要とする実 binary だけを
# symlink し、jq は置かない（PATH 再構成＝実除去。ORCH_CLEAN_JSON_VERIFIERS 渡しだけでは helper 群の
# bare jq には効かず退行を再現できないため）。echo した dir を PATH に BIN と並べて使う。
_mk_nojq_path() {
    local NOJQ="$TEST_TMPDIR/nojq-bin" t p
    mkdir -p "$NOJQ"
    for t in bash sh sed grep sort awk head cat dirname basename stat mktemp find python3 node; do
        p="$(command -v "$t" 2>/dev/null)" && ln -s "$p" "$NOJQ/$t"
    done
    printf '%s' "$NOJQ"
}

@test "(LIVE3) F1 regression pin: PATH から jq を実除去（python3 在）＋ snapshot 付き幽霊在 → 全体 RED（jq 理由文・幽霊不可視 GREEN を出さない）" {
    local NOJQ; NOJQ="$(_mk_nojq_path)"
    # 前提確認（非 vacuity）: python3 は在り jq は無い＝F1 退行（fallback GREEN→helper 空読み）の再現条件。
    [ -x "$NOJQ/python3" ]
    [ ! -e "$NOJQ/jq" ]
    # snapshot 付き幽霊: jq が在れば (a) RED になる材料。F1 退行実装なら liveness が python3 で GREEN を
    # 通し、helper 群（bare jq）が空読み → 幽霊不可視の全体 GREEN（false-clean）に落ちる。
    export STUB_IP_IDS="orch-ghost"
    export STUB_SNAPSHOT_IDS="orch-ghost"
    PATH="$BIN:$NOJQ" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" != *"GREEN（clean・respawn 可）"* ]]
    # 理由は「jq 不在」と正確に帰属（bd 障害の理由文へ混同しない）。
    [[ "$output" == *"jq"* ]]
    [[ "$output" == *"判定不能"* ]]
}

@test "(LIVE4) F1: jq 不在（全核 benign）→ RED 理由文が「jq 不在・bd 障害ではない」と正確に帰属する" {
    local NOJQ; NOJQ="$(_mk_nojq_path)"
    [ ! -e "$NOJQ/jq" ]
    # 全核 benign でも jq 不在なら fail-closed RED（幽霊有無に依存しない gate）。
    PATH="$BIN:$NOJQ" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"jq が PATH に無い"* ]]
    [[ "$output" == *"bd 障害ではない"* ]]
    [[ "$output" == *"RED（respawn 不可"* ]]
}

@test "(LIVE5) m7: JSON 配列検証器を確認できない（jq 在・verifiers 空振り）→ 検証器不在で判定不能 RED（bd 障害と誤帰属しない）" {
    # jq は PATH に在る（F1 gate は通過）が、検証器リストが空振り＝rc2 分岐（誤帰属しない理由文）を pin。
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 ORCH_CLEAN_SCRIPTORIUM="$ANCHOR" \
      ORCH_CLEAN_WORKTREE_ROOT="$WROOT" ORCH_CLEAN_GATE_BASE="main" \
      ORCH_CLEAN_BD="$BIN/bd" ORCH_CLEAN_TMUX="$BIN/tmux" \
      ORCH_CLEAN_DEGRADED_WATCH="$BIN/degraded-watch" ORCH_CLEAN_BEADS_DIR="$BEADS" \
      ORCH_CLEAN_JSON_VERIFIERS="no-such-verifier-xyz" run bash "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"検証器"* ]]
    [[ "$output" == *"判定不能"* ]]
}

# ==============================================================================
# (EXEC) distribution 契約: SCRIPT に実行ビットがある（bare path 単発起動・acceptance 2）
#   header/usage が `scripts/orch-clean-state-probe.sh`（bare）起動を文書化し、respawn 規約 E から
#   単発コマンドとして参照される。非実行(100644)だと全ホストで Permission denied になる。
#   self-test/bats は `bash "$SCRIPT"` 経由ゆえ exec-bit 欠落を検知しない＝この assert が唯一のゲート。
# ==============================================================================
@test "(EXEC) SCRIPT に実行ビットがある（bare path 単発起動が動く・distribution 契約）" {
    [ -x "$SCRIPT" ]
}

# ==============================================================================
# (E2-libabsent) 共有 anchor lib 不在なら fail-closed exit1（orch-49g errata E2・orch-hydrate.bats:142 同型）
# ==============================================================================
@test "(E2-libabsent) 共有 anchor lib 不在なら fail-closed exit1 + loud message（orch-49g errata E2）" {
    local SB="$TEST_TMPDIR/sb-nolib"; mkdir -p "$SB"
    cp "$SCRIPT" "$SB/orch-clean-state-probe.sh"   # lib/orch_anchor.sh を意図的に置かない（最初の source で die）
    PATH="$BIN:$PATH" ORCH_CLEAN_SKIP_SESSION_GATE=1 run bash "$SB/orch-clean-state-probe.sh" --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"共有 anchor lib 不在"* ]]
}

# ==============================================================================
# (NOANCHOR*) engine seam: anchor 解決は arg-parse + --self-test dispatch + self-scope gate の**後**（遅延）で、
#   解決不能は fail-loud die（hardcode fallback 撤去の teeth・sc-vcjv gate finding 反映）。
#   engine copy は deploy-layout 依存の hardcode fallback を持たない。per-consumer env
#   （ORCH_CLEAN_SCRIPTORIUM）/ ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれも未供給かつ動的導出も
#   E2（dolt_database==orch）で reject されると、共有 lib _resolve_scriptorium が解決不能 → fail-loud die
#   （exit 非0・「解決不能」）。ただし anchor 非依存経路（--help / hermetic --self-test / self-scope reject）
#   は巻き添えにしない（degraded-watch / stale-scan と同型の遅延構造）。
#   ★非 vacuity: 旧 hardcode fallback が生きていれば anchor が「解決できてしまい」die せず GREEN 側経路へ
#     落ちる。この teeth は fallback 復活（＝engine 公開境界の後退）を exit1 で殺す。
# ==============================================================================
@test "(NOANCHOR) anchor 未供給（env 全欠・orch fixture cwd）→ self-scope 通過後の anchor 解決段で fail-loud die・exit1・「解決不能」" {
    local NOA="$TEST_TMPDIR/noanchor"; mkdir -p "$NOA/.beads"
    printf '{"dolt_database":"orch"}' > "$NOA/.beads/metadata.json"   # self-scope は通過させ anchor die を単離
    # env -u で 3 seam を全て剥がす（ambient に注入されていても確実に空にする）。cwd は非 git の orch fixture。
    run env -u ORCH_ANCHOR -u ORCH_ANCHOR_CONFIG -u ORCH_CLEAN_SCRIPTORIUM \
        bash -c 'cd "$1" && exec bash "$2" --dry-run' _ "$NOA" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"解決不能"* ]]
    # anchor die 経路であって self-scope refuse ではない（self-scope は orch fixture で通過済み）。
    [[ "$output" != *"refusing to run"* ]]
}

@test "(NOANCHOR-help) anchor 未供給でも --help は usage を exit0 表示（anchor 非依存経路の非巻き添え teeth）" {
    local NOA="$TEST_TMPDIR/noanchor-help"; mkdir -p "$NOA"   # .beads すら無し（最も裸の環境）
    run env -u ORCH_ANCHOR -u ORCH_ANCHOR_CONFIG -u ORCH_CLEAN_SCRIPTORIUM \
        bash -c 'cd "$1" && exec bash "$2" --help' _ "$NOA" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-clean-state-probe"* ]]
    # die メッセージ全文形で負 assert（usage 文書中の一般語「解決不能」とは弁別する）。
    [[ "$output" != *"anchor 解決不能（fail-loud）"* ]]
}

@test "(NOANCHOR-selftest) anchor 未供給でも --self-test は hermetic に PASS（standalone 実行可能性 teeth）" {
    local NOA="$TEST_TMPDIR/noanchor-st"; mkdir -p "$NOA"
    run env -u ORCH_ANCHOR -u ORCH_ANCHOR_CONFIG -u ORCH_CLEAN_SCRIPTORIUM \
        bash -c 'cd "$1" && exec bash "$2" --self-test' _ "$NOA" "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" != *"anchor 解決不能（fail-loud）"* ]]
}

@test "(NOANCHOR-selfscope) anchor 未供給 + foreign cwd → self-scope refuse が先（anchor die でなく refusing to run）" {
    local NOA="$TEST_TMPDIR/noanchor-foreign"; mkdir -p "$NOA/.beads"
    printf '{"dolt_database":"un"}' > "$NOA/.beads/metadata.json"   # foreign 台帳 fixture
    run env -u ORCH_ANCHOR -u ORCH_ANCHOR_CONFIG -u ORCH_CLEAN_SCRIPTORIUM \
        bash -c 'cd "$1" && exec bash "$2" --dry-run' _ "$NOA" "$SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"refusing to run"* ]]
    [[ "$output" != *"anchor 解決不能（fail-loud）"* ]]
}

#!/usr/bin/env bats
# scribe-spawn.sh の --transport（tmux|bg|auto）分岐と bg native background agent launcher（sc-5rl）を検証する。
# 3 層構成:
#   (A) dry-run / plan       — hermetic・/tmp 非依存・worker sandbox でも走る（AC1/AC8）。
#   (B) real-path die-before  — bg/plugin-dir preflight は worktree add / env-file mktemp より前に die する
#                               （AC2/AC5）。/tmp 書込前に死ぬため worker sandbox でも走る。
#   (C) real-path carrier/launch — settings 合成・attestation・bg launch は env-file mktemp(/tmp) を要する（AC3/AC4/AC6）。
#                               worker OS sandbox は /tmp を read-only 化するため、そこでは `_need_tmp` で skip し
#                               admin host（/tmp 書込可）で緑にする。**実 claude --bg は起動しない**（SCRIBE_CLAUDE_BIN
#                               stub で差替＝worker 安全制約・protocol）。
# また静的 source assert（AC6/DJ2 の起動構成）で /tmp 非依存に不変条件を pin する。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  SMOKE="$SCRIPTS/scribe-spawn-smoke.sh"
  # bd 実在検証スタブ（sc-bg を OK にする）。
  BD_STUB="$BATS_TEST_TMPDIR/bd-stub"
  printf '#!/usr/bin/env bash\n[[ "$1" == show ]] && { [[ "$2" == sc-bg ]] && exit 0 || exit 1; }\nexit 0\n' > "$BD_STUB"
  chmod +x "$BD_STUB"
  export SCRIBE_BD="$BD_STUB"
  export SCRIBE_HHMMSS=101010
  export SCRIBE_CLD_SPAWN="cld-spawn"     # dry-run では起動されない
  # hermetic 化: ホスト env の漏れを落とす。
  unset CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE SCRIBE_TRANSPORT SCRIBE_BG_PREFLIGHT SCRIBE_CLAUDE_BIN SCRIBE_PLUGIN_DIR 2>/dev/null || true
  # canonical bdw present スタブ（spawn の無条件 bdw preflight を host 非依存で通す）。
  BDW_PRESENT_STUB="$BATS_TEST_TMPDIR/bdw-present-stub"
  printf '#!/usr/bin/env bash\n[ "$1" = lock-dir ] && { echo "%s/locks"; exit 0; }\n[ "$1" = lock-file ] && { echo "%s/locks/x.lock"; exit 0; }\nexit 0\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BDW_PRESENT_STUB"
  chmod +x "$BDW_PRESENT_STUB"
  # 安定 main worktree（temp git repo）を cwd 兼 repo/anchor に。
  REPO="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email t@e; git -C "$REPO" config user.name t
  git -C "$REPO" commit -q --allow-empty -m init
  cd "$REPO"
}

teardown() {
  # real-path テストが作った worktree を掃除（skip テストでは無害）。
  [[ -n "${REPO:-}" ]] && git -C "$REPO" worktree remove --force "$REPO/.worktrees/spawn/sc-bg-101010" 2>/dev/null || true
  [[ -n "${REPO:-}" ]] && rm -rf "$REPO"
  return 0
}

# /tmp が書込可（=admin host 相当）でなければ skip する（worker OS sandbox は /tmp read-only・env-file mktemp が落ちる）。
_need_tmp() {
  local p="/tmp/.scribe-tp-$$"
  if : > "$p" 2>/dev/null; then rm -f "$p"; else skip "/tmp が read-only（worker OS sandbox）＝env-file mktemp 不可・admin host で検証"; fi
}

# 実 claude を起こさない bg stub（--help に --bg/--effort を出し、--bg 起動で fake short-id を echo）。$1 rc で launch 成否注入。
# 注: 実 claude --bg は起動しない（SCRIBE_CLAUDE_BIN でこの stub を差替＝worker 安全制約・protocol）。
_mk_claude_stub() {  # $1 = bg launch（--bg 起動）の exit code（既定 0）
  local rc="${1:-0}"
  local f="$BATS_TEST_TMPDIR/claude-stub-$rc"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo "if [[ \"\$1\" == \"--bg\" ]]; then echo \"bgagent-abcd1234\"; exit $rc; fi"
    echo 'exit 0'
  } > "$f"
  chmod +x "$f"; echo "$f"
}

# ===========================================================================
# (A) dry-run / plan（/tmp 非依存）
# ===========================================================================

@test "transport(AC1): 不正な --transport 値は fail-loud（dry-run でも先に die）" {
  run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport nope --dry-run sc-bg
  [ "$status" -ne 0 ]
  [[ "$output" == *"--transport/SCRIBE_TRANSPORT が不正"* ]]
  [[ "$output" == *"tmux|bg|auto"* ]]
}

@test "transport(AC1): 既定（--transport 省略）の dry-run plan は --transport tmux と byte 等価（AC7/AC10）" {
  run "$SPAWN" --repo "$REPO" --anchor "$REPO" --dry-run sc-bg
  [ "$status" -eq 0 ]
  local def="$output"
  run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport tmux --dry-run sc-bg
  [ "$status" -eq 0 ]
  [ "$def" = "$output" ]
}

@test "transport(AC1): --transport tmux の dry-run plan は transport 固有行を足さない（既定と同一＝byte 不変）" {
  run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport tmux --dry-run sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" != *"transport=bg"* ]]
  [[ "$output" != *"transport=auto"* ]]
  [[ "$output" == *'--disallowed-tools "AskUserQuestion,ExitPlanMode"'* ]]
}

@test "transport(AC1/AC8): --transport bg の dry-run plan に bg 固有構成（--bg/--plugin-dir/env carrier/bg monitor）が出る" {
  run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg --dry-run sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"transport=bg"* ]]
  [[ "$output" == *"--bg "* ]]
  [[ "$output" == *"--plugin-dir"* ]]
  [[ "$output" == *"--dangerously-skip-permissions"* ]]
  [[ "$output" == *"env block"* ]]
  [[ "$output" == *"commit sentinel"* ]]
}

@test "transport(AC1): --transport auto の dry-run plan は bg 候補 / tmux fallback を注記（具体経路は断定しない）" {
  run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport auto --dry-run sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"transport=auto"* ]]
  [[ "$output" == *"tmux"* ]]
  [[ "$output" == *"bg 候補"* ]]
}

@test "transport(AC1): SCRIBE_TRANSPORT env が既定を上書きし源=SCRIBE_TRANSPORT + sticky 注記が dry-run plan に出る" {
  SCRIBE_TRANSPORT=bg run "$SPAWN" --repo "$REPO" --anchor "$REPO" --dry-run sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"源=SCRIBE_TRANSPORT"* ]]
  [[ "$output" == *"sticky"* ]]
}

@test "transport(AC1): --transport flag は SCRIBE_TRANSPORT env より優先（flag 勝ち）" {
  SCRIBE_TRANSPORT=bg run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport tmux --dry-run sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" != *"transport=bg"* ]]   # flag=tmux が勝つ＝bg 固有行は出ない
}

@test "transport(AC1): --transport は consult モードでは fail-loud（worker 専用 guard）" {
  run "$SPAWN" --consult --transport bg --dry-run sc-bg
  [ "$status" -ne 0 ]
  [[ "$output" == *"--transport は worker モード専用"* ]]
}

@test "transport(AC2/AC11): --transport bg の dry-run は claude を一切叩かない（side-effect ゼロ）" {
  # claude stub が呼ばれたら marker を作る。dry-run bg で marker が出来ないことを assert（bg preflight/effort 未起動）。
  local marker="$BATS_TEST_TMPDIR/claude-called"
  local stub="$BATS_TEST_TMPDIR/claude-noisy"
  printf '#!/usr/bin/env bash\ntouch %q\nexit 0\n' "$marker" > "$stub"; chmod +x "$stub"
  SCRIBE_CLAUDE_BIN="$stub" run "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg --dry-run sc-bg
  [ "$status" -eq 0 ]
  [ ! -f "$marker" ]
}

# ===========================================================================
# (B) real-path die-before-worktree（/tmp 非依存＝worker sandbox でも走る）
# ===========================================================================

@test "transport(AC2): --transport bg + bg preflight 不可 → worktree add 前に fail-loud（bg 明示は tmux へ黙って落とさない）" {
  local unavail="$BATS_TEST_TMPDIR/bg-unavail"
  printf '#!/usr/bin/env bash\necho "no --bg flag"; exit 1\n' > "$unavail"; chmod +x "$unavail"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$unavail" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -ne 0 ]
  [[ "$output" == *"bg preflight が不可"* ]]
  [ ! -d "$REPO/.worktrees/spawn/sc-bg-101010" ]   # worktree add 前に die＝orphan なし
}

@test "transport(AC5): --transport bg + bg preflight 可 + plugin-dir 欠落 → worktree add 前に fail-loud（無防備 worker 防止）" {
  local avail="$BATS_TEST_TMPDIR/bg-avail"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$avail" SCRIBE_PLUGIN_DIR="$BATS_TEST_TMPDIR/nonexistent-plugin-dir" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -ne 0 ]
  [[ "$output" == *"plugin-dir"* ]]
  [ ! -d "$REPO/.worktrees/spawn/sc-bg-101010" ]
}

@test "transport(AC5): plugin-dir に hooks/edit-write-guard.py 欠落 → fail-loud（guard 実体欠落を検出）" {
  local avail="$BATS_TEST_TMPDIR/bg-avail2"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  # hooks.json は在るが guard 実体を欠く plugin-dir を用意（部分配備の検出）。
  local pd="$BATS_TEST_TMPDIR/partial-plugin"
  mkdir -p "$pd/hooks" "$pd/scripts/hooks"
  printf '{}' > "$pd/hooks/hooks.json"
  # edit-write-guard.py は置かない。
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$avail" SCRIBE_PLUGIN_DIR="$pd" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -ne 0 ]
  [[ "$output" == *"edit-write-guard.py"* ]]
  [ ! -d "$REPO/.worktrees/spawn/sc-bg-101010" ]
}

# ===========================================================================
# (C) real-path carrier / launch（/tmp 依存＝admin host で緑・worker sandbox は skip）
# ===========================================================================

@test "transport(AC4): bg × SANDBOX_ON=0 は env-only settings.local.json（env carrier 3キー）を生成し worker stage から除外" {
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude wt
  avail="$BATS_TEST_TMPDIR/bg-avail3"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 0)"
  wt="$REPO/.worktrees/spawn/sc-bg-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -eq 0 ]
  [ -f "$wt/.claude/settings.local.json" ]
  run jq -e --arg wt "$wt" '.env.SCRIBE_WORKER == "1" and .env.SCRIBE_WORKTREE == $wt and (.env.CLAUDE_CODE_EFFORT_LEVEL|length>0)' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
  # sandbox off ゆえ sandbox キーは持たない（env-only）。
  run jq -e 'has("sandbox")' "$wt/.claude/settings.local.json"
  [ "$status" -ne 0 ]
  # worker stage から除外（scribe_sandbox_write_exclude が共有 common-dir info/exclude へ
  # `**/.claude/settings.local.json` を冪等追記する）。除外先は linked worktree でも common-dir
  # （$REPO/.git/info/exclude）に確定する（scribe_write_exclude が --git-path info/exclude を解く＝共有）。
  # 必須 assert に格上げ（旧版は末尾 `|| true` で exclude 未実施でも常時 green の false-green だった）。
  run grep -qF -- '**/.claude/settings.local.json' "$REPO/.git/info/exclude"
  [ "$status" -eq 0 ]
}

@test "transport(AC4): bg × SANDBOX_ON=1 は gen 出力へ env block を合成し複合 attestation（sandbox3+env3）を通す" {
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude gen wt
  avail="$BATS_TEST_TMPDIR/bg-avail4"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 0)"
  # gen stub: sandbox 強制3キーを持つ最小 valid JSON を出す（allowWrite は空でよい）。
  gen="$BATS_TEST_TMPDIR/gen-stub"
  printf '#!/usr/bin/env bash\njq -n "{sandbox:{enabled:true,failIfUnavailable:true,allowUnsandboxedCommands:false,filesystem:{allowWrite:[]}}}"\n' > "$gen"; chmod +x "$gen"
  wt="$REPO/.worktrees/spawn/sc-bg-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$avail" SCRIBE_SANDBOX_GEN="$gen" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -eq 0 ]
  [ -f "$wt/.claude/settings.local.json" ]
  run jq -e --arg wt "$wt" '.sandbox.enabled==true and .sandbox.failIfUnavailable==true and .sandbox.allowUnsandboxedCommands==false and .env.SCRIBE_WORKER=="1" and .env.SCRIBE_WORKTREE==$wt' "$wt/.claude/settings.local.json"
  [ "$status" -eq 0 ]
}

@test "transport(AC7): tmux × SANDBOX_ON=1 は settings に env block を注入しない（現行形状の byte 不変）" {
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local noop gen wt
  noop="$BATS_TEST_TMPDIR/noop-cld"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  gen="$BATS_TEST_TMPDIR/gen-stub2"
  printf '#!/usr/bin/env bash\njq -n "{sandbox:{enabled:true,failIfUnavailable:true,allowUnsandboxedCommands:false,filesystem:{allowWrite:[]}}}"\n' > "$gen"; chmod +x "$gen"
  wt="$REPO/.worktrees/spawn/sc-bg-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX_GEN="$gen" SCRIBE_CLD_SPAWN="$noop" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport tmux sc-bg
  [ "$status" -eq 0 ]
  [ -f "$wt/.claude/settings.local.json" ]
  run jq -e 'has("env")' "$wt/.claude/settings.local.json"
  [ "$status" -ne 0 ]   # tmux 経路は env block を持たない（AC7）
}

@test "transport(AC6/AC8): bg launch 成功 → spawned(bg) + agent_id + bg monitor（commit sentinel）を emit" {
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude
  avail="$BATS_TEST_TMPDIR/bg-avail5"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 0)"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]
  [[ "$output" == *"bgagent-abcd1234"* ]]
  [[ "$output" == *"commit sentinel"* ]]
}

@test "transport(AC6/AC10): bg launch は claude --help に --effort 実在時 --effort <EFFORT> を実 --bg 起動 argv へ渡す（feature-detect 検出枝・positive assert）" {
  # finding#1(a/b): 検出枝で --effort が実際に claude --bg 起動行へ届くことの positive assert。既存 stub は
  # short-id を stdout に出すだけで argv を捕捉しないため、この経路（effort が bg launch へ届く）は未検証だった。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude marker
  avail="$BATS_TEST_TMPDIR/bg-avail-eff1"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  marker="$BATS_TEST_TMPDIR/claude-argv-eff1"
  # claude stub: --help に --effort を出す（BG_EFFORT_DETECTED=1 枝）。--bg 起動で受けた argv 全体を marker へ
  # `<%s>` 区切りで記録し short-id を stdout に返す（stdout は spawn 側が short-id として捕捉するため argv は
  # 別ファイルへ side-channel する）。`<%s>` 区切りは prompt 引数が内部に "--effort" 文字列を持っても argv 要素
  # としての `<--effort>` とは弁別されるので誤 match しない（隣接性 + 値まで固定できる）。
  claude="$BATS_TEST_TMPDIR/claude-eff1"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo "if [[ \"\$1\" == \"--bg\" ]]; then printf '<%s>' \"\$@\" > '$marker'; echo bgagent-abcd1234; exit 0; fi"
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg --effort xhigh sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]
  # positive assert: 実 --bg 起動 argv に `--effort xhigh` が隣接して届いている（feature-detect 検出→付与）。
  [ -f "$marker" ]
  run grep -qF -- '<--effort><xhigh>' "$marker"
  [ "$status" -eq 0 ]
}

@test "transport(AC6/AC11): bg launch は claude --help に --effort 非在時 loud warn かつ --effort を付けない（feature-detect 非検出枝）" {
  # finding#1(a): 非検出→loud warn 枝（effort を付けない・warn を出す新規 fail-mode）は完全に未検証だった。
  # 既存 transport bats の claude stub は --help に必ず --effort を出す（_mk_claude_stub）ため検出枝しか通らない。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude marker
  avail="$BATS_TEST_TMPDIR/bg-avail-eff2"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  marker="$BATS_TEST_TMPDIR/claude-argv-eff2"
  # claude stub: --help に --effort を **出さない**（BG_EFFORT_DETECTED=0 枝）。--bg 起動 argv を marker へ記録。
  claude="$BATS_TEST_TMPDIR/claude-eff2"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--plugin-dir D] ..."; exit 0; fi'
    echo "if [[ \"\$1\" == \"--bg\" ]]; then printf '<%s>' \"\$@\" > '$marker'; echo bgagent-abcd1234; exit 0; fi"
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg --effort xhigh sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]
  # loud warn（effort 指定不能）が出る（silent 降格ゼロ・AC11）。ユーザーが --effort xhigh を要求しても non-対応
  # claude では effort を渡せないことを loud に告げる。
  [[ "$output" == *"--effort フラグが見当たりません"* ]]
  # かつ 実 --bg 起動 argv に `--effort` が **付かない**（未知フラグ落下防御・un-ivb）。
  [ -f "$marker" ]
  run grep -qF -- '<--effort>' "$marker"
  [ "$status" -ne 0 ]
}

@test "transport(finding#1): bg launch は claude --help に --model 実在時 --model <MODEL> を実 --bg 起動 argv へ渡す（worker=opus 不変条件を bg parity で運ぶ・positive assert）" {
  # finding#1[major]: bg launch は tmux 経路（cld-spawn へ --model "$MODEL" を必ず渡す）と非対称に --model を落とし、
  # bg worker が起動セッション/アカウント既定モデル（admin main-loop=fable）を継承しコスト爆発しうる回帰。--model が
  # claude --bg 起動行へ届くことの positive assert（effort の positive assert と同型）。worker 既定 MODEL=opus。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude marker
  avail="$BATS_TEST_TMPDIR/bg-avail-mdl1"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  marker="$BATS_TEST_TMPDIR/claude-argv-mdl1"
  # claude stub: --help に --model を出す（BG_MODEL_DETECTED=1 枝）。--bg 起動 argv 全体を marker へ `<%s>` 区切りで記録。
  claude="$BATS_TEST_TMPDIR/claude-mdl1"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--model M] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo "if [[ \"\$1\" == \"--bg\" ]]; then printf '<%s>' \"\$@\" > '$marker'; echo bgagent-abcd1234; exit 0; fi"
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]
  # positive assert: 実 --bg 起動 argv に `--model opus` が隣接して届いている（tmux parity・worker=opus 不変条件）。
  [ -f "$marker" ]
  run grep -qF -- '<--model><opus>' "$marker"
  [ "$status" -eq 0 ]
}

@test "transport(finding#1): bg launch は claude --help に --model 非在時 loud warn かつ --model を付けない（feature-detect 非検出枝・un-ivb 防御）" {
  # finding#1: --model 非対応バイナリでは model を固定できない旨を loud warn（silent 無視を禁ずる）。effort 非検出枝と対称。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude marker
  avail="$BATS_TEST_TMPDIR/bg-avail-mdl2"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  marker="$BATS_TEST_TMPDIR/claude-argv-mdl2"
  # claude stub: --help に --model を **出さない**（BG_MODEL_DETECTED=0 枝）。--effort は出す（effort 検出枝の混線を避ける）。
  claude="$BATS_TEST_TMPDIR/claude-mdl2"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo "if [[ \"\$1\" == \"--bg\" ]]; then printf '<%s>' \"\$@\" > '$marker'; echo bgagent-abcd1234; exit 0; fi"
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]
  # loud warn（model 固定不能）が出る（silent 無視ゼロ）。
  [[ "$output" == *"--model フラグが見当たりません"* ]]
  # かつ 実 --bg 起動 argv に `--model` が **付かない**（未知フラグ落下防御・un-ivb）。
  [ -f "$marker" ]
  run grep -qF -- '<--model>' "$marker"
  [ "$status" -ne 0 ]
}

@test "transport(AC3): bg 明示 + launch 失敗 → loud fail + cleanup 案内 + orphan worktree（自動削除しない）" {
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude wt
  avail="$BATS_TEST_TMPDIR/bg-avail6"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 7)"   # --bg が exit 7
  wt="$REPO/.worktrees/spawn/sc-bg-101010"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -ne 0 ]
  [[ "$output" == *"bg launch"* ]]
  [[ "$output" == *"scribe-cleanup.sh"* ]]
  [ -d "$wt" ]   # orphan を残す（自動削除しない）
}

@test "transport(AC3): auto + bg launch 失敗 → tmux へ post-launch fallback（loud warn・二重起動しない）" {
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude noop
  avail="$BATS_TEST_TMPDIR/bg-avail7"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 5)"    # --bg が exit 5
  noop="$BATS_TEST_TMPDIR/noop-cld2"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" SCRIBE_CLD_SPAWN="$noop" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport auto sc-bg
  [ "$status" -eq 0 ]                                  # tmux fallback で成立
  [[ "$output" == *"post-launch fallback"* ]]
  [[ "$output" == *"spawned: issue=sc-bg"* ]]          # tmux 経路の spawned 行（bg でなく）
}

@test "transport(AC1/AC3): auto + bg preflight 不可 → tmux へ pre-launch loud fallback（silent 降格ゼロ・二重起動しない）" {
  # auto の存在理由そのもの: bg preflight が **不可** のとき pre-launch で tmux へ loud fallback する経路。
  # post-launch fallback（preflight 可 + launch 失敗）とは別経路で、bg は一切 launch されず preflight 段で tmux に倒れる。
  _need_tmp
  local unavail claude noop
  unavail="$BATS_TEST_TMPDIR/bg-unavail-auto"; printf '#!/usr/bin/env bash\necho "no --bg flag"; exit 1\n' > "$unavail"; chmod +x "$unavail"
  claude="$(_mk_claude_stub 0)"   # bg は起動されない（preflight 不可）＝effort feature-detect の host claude 依存を断つ stub
  noop="$BATS_TEST_TMPDIR/noop-cld3"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$unavail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_CLD_SPAWN="$noop" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport auto sc-bg
  [ "$status" -eq 0 ]                              # bg 不可 → tmux で成立（loud fallback）
  [[ "$output" == *"bg preflight が不可"* ]]        # pre-launch loud fallback warn（silent 降格ゼロ・AC1/AC3/AC11）
  [[ "$output" == *"spawned: issue=sc-bg"* ]]      # tmux 経路の spawned 行（bg でなく＝preflight 段で tmux に帰着）
}

# ---------------------------------------------------------------------------
# sc-vgl follow-up: auto→tmux fallback の spurious warn 抑止 / auto 成功 modality /
#                   empty short-id degrade / --account auto×bg warn の回帰 pin
# ---------------------------------------------------------------------------

@test "transport(sc-vgl finding(a)): auto + bg preflight 不可 → tmux fallback 時に bg 段の effort/model 非対応 loud warn を出さない（spurious warn 抑止）" {
  # finding(a): BG_EFFORT_ARG/BG_MODEL_ARG の feature-detect（loud warn 含む）を EFFECTIVE_TRANSPORT==bg 確定後へ
  # restructure した回帰 pin。旧実装は TRANSPORT==bg||auto 段（preflight より前）で probe していたため、auto→tmux
  # fallback（bg preflight 不可）で claude バイナリが --effort/--model を欠くと「指定できません/見当たりません」warn が
  # spurious に出た（tmux 経路は cld-spawn 経由で effort/model を正しく渡すのに誤 UX）。tmux 帰着時は出ないことを pin。
  _need_tmp
  local unavail claude noop
  unavail="$BATS_TEST_TMPDIR/bg-unavail-vgla"; printf '#!/usr/bin/env bash\necho "no --bg flag"; exit 1\n' > "$unavail"; chmod +x "$unavail"
  # claude stub: --help に --effort も --model も **出さない**（旧実装なら両 warn が spurious に出る条件）。--bg 起動は
  # されない（preflight 不可で tmux へ倒れる）が、feature-detect が誤って走れば warn が漏れる——それを負 assert で塞ぐ。
  claude="$BATS_TEST_TMPDIR/claude-vgla"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--plugin-dir D] ..."; exit 0; fi'
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  noop="$BATS_TEST_TMPDIR/noop-cld-vgla"; printf '#!/usr/bin/env bash\nexit 0\n' > "$noop"; chmod +x "$noop"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$unavail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_CLD_SPAWN="$noop" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport auto sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"bg preflight が不可"* ]]        # tmux へ loud fallback（正常経路）
  [[ "$output" == *"spawned: issue=sc-bg"* ]]      # tmux 帰着
  # spurious warn 抑止（finding(a) の核）: tmux 帰着では bg 段の effort/model 非対応 warn を一切出さない。
  [[ "$output" != *"--effort フラグが見当たりません"* ]]
  [[ "$output" != *"--model フラグが見当たりません"* ]]
  [[ "$output" != *"実効 effort を指定できません"* ]]
}

@test "transport(sc-vgl finding(b)): auto + bg preflight 可 + launch 成功 → bg へ帰着（spawned(bg)・auto 成功 modality）" {
  # finding(b): auto の成功 modality（bg preflight 可 + launch 成功 → bg 帰着）は既存 bats に無かった（auto は preflight
  # 不可→tmux / launch 失敗→tmux fallback の 2 経路しか pin されていなかった）。auto が実際に bg へ解決することを pin。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude
  avail="$BATS_TEST_TMPDIR/bg-avail-vglb"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 0)"   # bg launch 成功・short-id を echo
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport auto sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]              # bg へ帰着（tmux でなく）
  [[ "$output" == *"bgagent-abcd1234"* ]]
  [[ "$output" == *"commit sentinel"* ]]
  # auto→bg 成功ゆえ tmux fallback 経路の signal は出ない（bg へ確定したことの negative pin）。
  [[ "$output" != *"post-launch fallback"* ]]
  [[ "$output" != *"bg preflight が不可"* ]]
  [[ "$output" != *"spawned: issue=sc-bg"* ]]      # tmux 経路の spawned 行は出ない
}

@test "transport(sc-vgl finding(c)): bg launch 成功だが short-id 空 → loud degrade warn + spawned(bg) agent_id=?（monitor は worktree 参照へ degrade）" {
  # finding(c): short-id 捕捉不能（claude --bg が返却値を出さない）時に loud degrade する経路の回帰 pin。既存 bats は
  # short-id を必ず echo する stub しか使わず、捕捉不能 degrade（AC6/DJ4）が未 pin だった。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude
  avail="$BATS_TEST_TMPDIR/bg-avail-vglc"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  # claude stub: --bg は成功（exit 0）だが **short-id を返さない**（stdout 空）。--help に --effort/--model を出す。
  claude="$BATS_TEST_TMPDIR/claude-vglc"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--model M] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo 'if [[ "$1" == "--bg" ]]; then exit 0; fi'   # stdout 空＝short-id 捕捉不能
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg sc-bg
  [ "$status" -eq 0 ]                              # launch 成功ゆえ spawn 成立（short-id 空は degrade で継続）
  [[ "$output" == *"short-id を返却値から捕捉できませんでした"* ]]   # loud degrade warn（silent 降格ゼロ）
  [[ "$output" == *"spawned(bg): issue=sc-bg agent_id=? "* ]]      # agent_id=? へ degrade
}

@test "transport(sc-vgl finding(c)): --account auto × transport=bg 併用 → cross-account 未検証の loud warn（AUTO=1 × bg pin）" {
  # finding(c): --account auto × bg 併用時の cross-account 未検証 loud warn（AC6/SHOULD）の回帰 pin。AUTO=1 が bg 分岐へ
  # 到達したときだけ warn する不変条件を real-path で pin する。AUTO=1 は API 故障 fallback 経路で決定論的に立てる
  #（SCRIBE_USAGE_CMD を不在にして selector を exit 3＝API 故障へ倒す。fallback で WCFG_DIR="" ゆえ config-dir preflight は
  # no-op で通り、AUTO は 1 のまま bg 分岐へ届く）。selector 自身の「API 故障」warn とは別文字列を assert する。
  _need_tmp
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude
  avail="$BATS_TEST_TMPDIR/bg-avail-vgld"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$(_mk_claude_stub 0)"
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_SANDBOX=0 SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/nonexistent-usage-cmd" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg --account auto sc-bg
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]                                   # bg へ帰着
  [[ "$output" == *"--account auto × transport=bg 併用"* ]]              # cross-account 未検証 loud warn（AC6/SHOULD）
  [[ "$output" == *"cross-account routing は 2-account 環境で live 未検証"* ]]
}

# ===========================================================================
# 静的 source assert（/tmp 非依存で AC6/DJ2 起動構成を pin）
# ===========================================================================

@test "transport(AC6/DJ2): bg launch 行は claude --bg + --plugin-dir + --dangerously-skip-permissions + 1 argv disallowed-tools を持つ（source 静的）" {
  run grep -F -- '"$CLAUDE_BIN" --bg "$PROMPT_TEXT" --plugin-dir "$SCRIBE_PLUGIN_DIR" --dangerously-skip-permissions' "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -F -- '--disallowed-tools "$WORKER_DISALLOWED_TOOLS"' "$SPAWN"
  [ "$status" -eq 0 ]
  # --permission-mode bypassPermissions は使わない（DJ2）。
  run grep -F -- 'bypassPermissions' "$SPAWN"
  [ "$status" -ne 0 ]
}

@test "smoke(AC9): scribe-spawn-smoke.sh は dry-run smoke（既定）で PASS する" {
  [ -x "$SMOKE" ]
  run "$SMOKE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS（dry-run smoke"* ]]
  [[ "$output" == *"honest 境界"* ]]
}

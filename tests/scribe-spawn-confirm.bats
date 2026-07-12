#!/usr/bin/env bats
# scribe-spawn.sh の post-spawn submit 検証層（sc-8g5）の回帰テスト。
#
# 何を守るか（契約 SSOT = scripts/scribe-spawn.sh の spawn_confirm ブロック・v3 acceptance）:
#   cld-spawn(tmux) の "prompt injected" は pane への **到着** の証拠であって **submit** の証拠ではない
#   （sentinel-presence が input-waiting 救済 Enter 分岐より前に短絡評価される・session-comm.sh:730）。
#   ゆえに OK は **turn 開始の積極証拠（[SPAWNED--<id>] marker の新規出現）でのみ**宣言し、証拠の不在
#   （入力欄クリア=DELIVERED / box 特定不能=INCONCLUSIVE）で OK を宣言しない（positive-proof-only）。
#   回復は **RESIDUAL のときだけ** Enter 冪等再送（DJ-a/DJ-b）。
#
# **実 tmux / 実 claude / 実 bd は起動しない**: capture（SCRIBE_SPAWN_CAPTURE）/ tmux（SCRIBE_TMUX）/
#   bd（SCRIBE_BD）/ cld-spawn（SCRIBE_CLD_SPAWN）を全て stub seam へ差し替えて決定論化する。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  INJECT="$SCRIPTS/scribe-inject.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"

  # 実 graph 非依存: bd 実在検証（`bd show <id>`）は下の bd stub が担う。
  export BD_STUB_OK_IDS="un-4nm"
  export SCRIBE_SANDBOX=0            # sandbox 生成は本層と無関係（deps 依存を持ち込まない）
  export SCRIBE_HHMMSS=101010        # branch/worktree 名を決定論化
  unset CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE 2>/dev/null || true

  # canonical bdw 到達性 preflight（sc-ovq・無条件）を host 非依存にする present スタブ。
  BDW_PRESENT_STUB="$BATS_TEST_TMPDIR/bdw-present-stub"
  printf '#!/usr/bin/env bash\n[ "$1" = lock-dir ] && { echo "%s/locks"; exit 0; }\n[ "$1" = lock-file ] && { echo "%s/locks/bd.lock"; exit 0; }\nexit 0\n' \
    "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > "$BDW_PRESENT_STUB"
  chmod +x "$BDW_PRESENT_STUB"

  # cld-spawn は noop（success を返すだけ＝「injected と言い張るが submit されたとは限らない」現実を模す）。
  NOOP_CLD="$BATS_TEST_TMPDIR/noop-cld"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP_CLD"; chmod +x "$NOOP_CLD"

  # stub 群の状態置き場（capture mode / bd mode / Enter 回数 / 呼出しログ）。
  S="$BATS_TEST_TMPDIR/stub"; mkdir -p "$S"
  : > "$S/calls.log"; echo 0 > "$S/enters"; echo 0 > "$S/bdcalls"; echo 0 > "$S/caps"
  echo delivered > "$S/mode"; echo never > "$S/bdmode"; : > "$S/marker"

  # --- pane capture stub（SCRIBE_SPAWN_CAPTURE・$1=window-id）---
  # 実 CC TUI（Type A: 水平罫線ペア + ❯ + status bar）を模す。Enter が撃たれたら入力欄がクリアされる
  # ＝「Enter 冪等再送で submit が成立する」現実を模す。
  CAPTURE_STUB="$S/capture"
  cat > "$CAPTURE_STUB" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$(readlink -f "$0")")"
echo "CAPTURE ${1:-<empty>}" >> "$S/calls.log"
mode="$(cat "$S/mode")"
n="$(cat "$S/enters")"
c="$(cat "$S/caps")"; echo $((c + 1)) > "$S/caps"   # capture 呼出し回数（0 始まり＝c は今回の index）
R='──────────────────────────────────'
case "$mode" in
  residual)     # worker prompt の marker が入力欄に残留（swallowed Enter）→ Enter 後にクリア
    if (( n >= 1 )); then printf '%s\n' "$R" '❯ ' "$R" '  status bar'
    else printf '%s\n' "$R" "❯ $(cat "$S/marker")" "$R" '  status bar'; fi ;;
  fail-once)    # transient capture 失敗: 初回だけ失敗し、以降は residual（回復可能）。検証層が初回失敗で
                # 丸ごと放棄する（＝marker polling を捨てる）実装だとここで RESIDUAL を取りこぼす。
    if (( c == 0 )); then exit 1; fi
    if (( n >= 1 )); then printf '%s\n' "$R" '❯ ' "$R" '  status bar'
    else printf '%s\n' "$R" "❯ $(cat "$S/marker")" "$R" '  status bar'; fi ;;
  residual-sticky)  # 持続 RESIDUAL: Enter を撃っても入力欄がクリアされない（swallowed Enter が回復しない /
                    # box 抽出の誤取りで false-RESIDUAL に張り付く modality）。回復不能でも Enter を無制限に
                    # 撃ち続けず、marker が出れば OK・出なければ loud-fail することを検証するための fixture。
    printf '%s\n' "$R" "❯ $(cat "$S/marker")" "$R" '  status bar' ;;
  paste)        # 大 prompt が bracketed-paste placeholder に折畳まれた pane（marker 衝突 fixture）
    if (( n >= 1 )); then printf '%s\n' "$R" '❯ ' "$R" '  status bar'
    else printf '%s\n' "$R" '❯ [Pasted text +214 lines]' "$R" '  status bar'; fi ;;
  delivered)    printf '%s\n' "$R" '❯ ' "$R" '  status bar' ;;
  inconclusive) printf '%s\n' 'Thinking… (esc to interrupt)' ;;   # 入力ボックス特定不能
  fail)         exit 1 ;;                                          # capture 不能（tmux 不在等）
esac
STUB
  chmod +x "$CAPTURE_STUB"

  # --- tmux stub（SCRIBE_TMUX）: send-keys Enter を記録し capture stub の状態を進める ---
  TMUX_STUB="$S/tmux"
  cat > "$TMUX_STUB" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$(readlink -f "$0")")"
sub="$1"; shift
case "$sub" in
  send-keys)
    if printf '%s\n' "$@" | grep -qx -- 'Enter'; then
      echo "ENTER $*" >> "$S/calls.log"
      n="$(cat "$S/enters")"; echo $((n + 1)) > "$S/enters"
    fi ;;
  *) echo "TMUX $sub $*" >> "$S/calls.log" ;;
esac
exit 0
STUB
  chmod +x "$TMUX_STUB"

  # --- bd stub（SCRIBE_BD）: `show <id>`（実在検証・text）と `show <id> --json`（notes 走査）を実装 ---
  # bdmode: never=marker が出ない / after-enter=Enter 後に出る / immediate=baseline の次の read から出る /
  #         always=baseline 時点で既に在る（再 spawn の stale marker を模す＝差分ゼロで OK にしない検証）。
  BD_STUB="$S/bd"
  cat > "$BD_STUB" <<'STUB'
#!/usr/bin/env bash
S="$(dirname "$(readlink -f "$0")")"
sub="${1:-}"; id="${2:-}"
[[ "$sub" == show ]] || { echo "bd-stub: unsupported: $sub" >&2; exit 2; }
json=0
for a in "$@"; do [[ "$a" == "--json" ]] && json=1; done
if (( json == 0 )); then printf '○ %s · stub issue\n' "$id"; exit 0; fi   # 実在検証（scribe_bd_id_exists）
c="$(cat "$S/bdcalls")"; echo $((c + 1)) > "$S/bdcalls"                    # --json read だけを数える
mode="$(cat "$S/bdmode")"; n="$(cat "$S/enters")"
notes='pre-existing note'
case "$mode" in
  always)      notes="[SPAWNED--$id]" ;;                                   # baseline 時点で既在（stale）
  after-enter) (( n >= 1 )) && notes="[SPAWNED--$id]" ;;
  immediate)   (( c >= 1 )) && notes="[SPAWNED--$id]" ;;                   # c=0 が baseline read
  never)       : ;;
esac
printf '[{"id":"%s","notes":"%s"}]\n' "$id" "$notes"
STUB
  chmod +x "$BD_STUB"
  export SCRIBE_BD="$BD_STUB"

  # --- mktemp shim: worker env-file は /tmp 固定テンプレ（本番規約＝anchor/worktree を汚さない）だが、
  # worker sandbox 下では /tmp が read-only で実経路テストが走らない（既存 bats は _need_tmp で skip する）。
  # PATH 先頭に置く shim が /tmp/ テンプレを $BATS_TEST_TMPDIR へ書き換え、sandbox でも host でも同じ経路を
  # 非 vacuous に検証できるようにする（挙動は同一・書き先だけ移す）。
  SHIM_BIN="$S/bin"; mkdir -p "$SHIM_BIN"
  # 書き換えるのは本番が使う /tmp/scribe-*.env テンプレのみ（$BATS_TEST_TMPDIR 自身が /tmp 配下でも
  # worktree 内 settings の mktemp を巻き込まないよう、prefix を厳密に絞る）。
  cat > "$SHIM_BIN/mktemp" <<STUB
#!/usr/bin/env bash
args=()
for a in "\$@"; do
  case "\$a" in /tmp/scribe-*) a="$BATS_TEST_TMPDIR/\${a#/tmp/}" ;; esac
  args+=("\$a")
done
exec /usr/bin/mktemp "\${args[@]}"
STUB
  chmod +x "$SHIM_BIN/mktemp"
  SHIM_PATH="$SHIM_BIN:$PATH"

  # 検証層のタイミングを決定論化（budget 1s / poll・settle 0s）。
  export SCRIBE_SPAWN_CONFIRM_BUDGET=1
  export SCRIBE_SPAWN_CONFIRM_POLL=1
  export SCRIBE_SPAWN_CONFIRM_SETTLE=0

  # 安定した main worktree（temp git repo）を cwd に（linked-worktree ガードの誤発火回避）。
  REPO="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email t@e; git -C "$REPO" config user.name t
  git -C "$REPO" commit -q --allow-empty -m init
  cd "$REPO"
  WT="$REPO/.worktrees/spawn/un-4nm-101010"
}

teardown() {
  [[ -n "${REPO:-}" ]] && git -C "$REPO" worktree remove --force "$WT" 2>/dev/null
  [[ -n "${REPO:-}" ]] && rm -rf "$REPO"
  return 0
}

# 実 spawn（tmux 経路・cld-spawn は noop stub）を走らせる共通ドライバ。
_spawn() {
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$NOOP_CLD" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
}

_enters() { cat "$S/enters"; }

# worker prompt から導出される marker（capture stub が入力欄に描く残留テキスト）を実際の dry-run 出力から取る
# ＝テスト側で導出規則を再実装しない（実装が marker 導出を変えたら本 fixture も追随する）。
_set_prompt_marker() {
  local prompt m
  prompt="$(env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN=cld-spawn \
              "$SPAWN" --repo "$REPO" --anchor "$REPO" --dry-run un-4nm | sed -n 's/^         | //p')"
  m="$(printf '%s' "$prompt" | "$INJECT" marker)"
  [[ -n "$m" ]] || return 1
  printf '%s' "$m" > "$S/marker"
}

# ---------- marker subcommand（導出規則の SSOT 露出・DJ-g）----------

@test "inject(sc-8g5): marker subcommand は payload 最終非空行の末尾24字を導出する（do_send と同一 pure core）" {
  run "$INJECT" marker --text $'first line\nlast meaningful line 0123456789abcdef\n\n'
  [ "$status" -eq 0 ]
  [ "${#output}" -eq 24 ]
  [[ "$output" == "e 0123456789abcdef" ]] || [[ "$output" == *"0123456789abcdef" ]]
}

@test "inject(sc-8g5): marker subcommand は stdin からも読む（空 payload は fail-loud）" {
  run bash -c "printf '%s' 'tail-of-the-worker-prompt' | '$INJECT' marker"
  [ "$status" -eq 0 ]
  [[ "$output" == *"worker-prompt" ]]
  run bash -c "printf '' | '$INJECT' marker"
  [ "$status" -ne 0 ]
}

# ---------- AC1/AC2: RESIDUAL 冪等回復 → SPAWNED 出現で OK ----------

@test "spawn(sc-8g5/AC2): 入力欄に prompt が残留（RESIDUAL）→ Enter 冪等再送 → SPAWNED 出現で OK" {
  _set_prompt_marker
  echo residual > "$S/mode"; echo after-enter > "$S/bdmode"
  _spawn
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESIDUAL＝未 submit"* ]]            # 未 submit を積極検知した（swallowed Enter）
  [[ "$output" == *"Enter を冪等再送"* ]]               # DJ-a: 回復は Enter のみ（prompt 再 inject しない）
  [[ "$output" == *"post-spawn 検証 OK"* ]]             # OK は SPAWNED 新規出現でのみ
  [[ "$output" == *"spawned: issue=un-4nm"* ]]          # happy-path の stdout は従来どおり
  [ "$(_enters)" -ge 1 ]
}

@test "spawn(sc-8g5/AC6): 大 prompt が [Pasted text …] に折畳まれた pane も RESIDUAL 扱い（false-DELIVERED しない）" {
  # marker 衝突 fixture: 折畳み表示では marker 文字列が pane に現れないが、placeholder 自体が未送信の証拠。
  _set_prompt_marker
  echo paste > "$S/mode"; echo after-enter > "$S/bdmode"
  _spawn
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESIDUAL＝未 submit"* ]]
  [[ "$output" == *"post-spawn 検証 OK"* ]]
  [ "$(_enters)" -ge 1 ]
}

# ---------- 持続 RESIDUAL（Enter で回復しない pane）modality ----------

@test "spawn(sc-8g5/AC2): 持続 RESIDUAL でも SPAWNED が出れば OK（RESIDUAL 分岐でも marker を評価する）" {
  # pane は Enter を撃ってもクリアされない（false-RESIDUAL に張り付く）が、worker は実際に turn を始めて
  # marker を書いている。RESIDUAL 分岐が marker を一度も見ずに continue する実装はここで偽 loud-fail する。
  _set_prompt_marker
  echo residual-sticky > "$S/mode"; echo after-enter > "$S/bdmode"
  _spawn
  [ "$status" -eq 0 ]
  [[ "$output" == *"post-spawn 検証 OK"* ]]
  [[ "$output" == *"spawned: issue=un-4nm"* ]]
  [ "$(_enters)" -ge 1 ]
  [ "$(_enters)" -le 5 ]                                # Enter 再送は上限内（無制限に撃たない）
}

@test "spawn(sc-8g5/AC3): 持続 RESIDUAL + SPAWNED 永久不着 → Enter は上限で打ち切り loud-fail（exit 7）" {
  # 決定論化（AC6）: Enter 上限の到達を **壁時計に依存させない**。上限メッセージは `_enter` が上限へ達した周回でしか
  # 出ないため、既定 5 のままだと「budget 1s の間に 5 周回入るか」がマシン負荷依存になり確率的に落ちる（flaky）。
  # MAX_ENTER=1 を注入して **初周回で必ず上限へ到達**させ、上限後は Enter を撃たず marker 待ちへ移行することを
  # 回数境界（上限 1 + 最終回復 1 = 2 回ちょうど）で検証する（上限そのものは env 可変＝既定値に依存しない不変条件）。
  export SCRIBE_SPAWN_CONFIRM_MAX_ENTER=1
  _set_prompt_marker
  echo residual-sticky > "$S/mode"; echo never > "$S/bdmode"
  _spawn
  [ "$status" -eq 7 ]
  [[ "$output" == *"Enter を冪等再送"* ]]
  [[ "$output" == *"上限（1 回）に到達"* ]]              # 上限後は marker 待ちへ移行（live pane を叩き続けない）
  [[ "$output" == *"budget 到達時も RESIDUAL"* ]]        # AC3: 最後の回復機会として Enter 1 回
  [[ "$output" == *"post-spawn submit 検証に失敗"* ]]
  [[ "$output" == *"RESIDUAL"* ]]
  [[ "$output" != *"spawned: issue=un-4nm"* ]]
  [ "$(_enters)" -ge 2 ]
  [ "$(_enters)" -le 2 ]                                # 上限 1 + 最終 1 回ちょうど（無制限に撃たない）
  [ -d "$WT" ]                                          # 自動 teardown しない
}

# ---------- AC4: 冪等性（submit 済みの窓へ Enter を撃たない）----------

@test "spawn(sc-8g5/AC4): 初回 DELIVERED + SPAWNED 即出現 → Enter 0 回で OK（二重 submit ゼロ）" {
  echo delivered > "$S/mode"; echo immediate > "$S/bdmode"
  _spawn
  [ "$status" -eq 0 ]
  [[ "$output" == *"post-spawn 検証 OK"* ]]
  [[ "$output" == *"Enter 再送=0 回"* ]]
  [ "$(_enters)" -eq 0 ]
  ! grep -q '^ENTER' "$S/calls.log"
}

# ---------- AC3: loud-fail（positive proof が取れない）----------

@test "spawn(sc-8g5/AC3): SPAWNED が budget 内に出なければ loud-fail（非 0 exit・自動 teardown しない）" {
  echo delivered > "$S/mode"; echo never > "$S/bdmode"
  _spawn
  [ "$status" -eq 7 ]                                   # 専用 exit code（cld-spawn の rc と弁別可能）
  [[ "$output" == *"post-spawn submit 検証に失敗"* ]]
  [[ "$output" == *"到着"* ]]                            # 「injected は到着の証拠であって submit の証拠でない」
  [[ "$output" == *"scribe-cleanup.sh"* ]]              # 復旧案内（--window 明示）
  [[ "$output" == *"--window \"wt-un-4nm\""* ]]
  [[ "$output" != *"spawned: issue=un-4nm"* ]]          # 起動済みと宣言しない（silent-proceed ゼロ）
  [ -d "$WT" ]                                          # 自動 teardown しない（orphan は admin が判断）
}

@test "spawn(sc-8g5/AC6): INCONCLUSIVE + SPAWNED 不着 → loud-fail（v2 の INCONCLUSIVE→OK 写像 BLOCKER 固定）" {
  # 旧設計は「入力欄を確認できない」を OK へ写像して fail-open した。証拠の不在で OK を宣言しない原理の回帰。
  echo inconclusive > "$S/mode"; echo never > "$S/bdmode"
  _spawn
  [ "$status" -eq 7 ]
  [[ "$output" == *"post-spawn submit 検証に失敗"* ]]
  [[ "$output" == *"INCONCLUSIVE"* ]]                   # 直近 pane 判定を診断に出す
  [ "$(_enters)" -eq 0 ]                                # DJ-b: INCONCLUSIVE では Enter を撃たない（ダイアログ安全）
}

@test "spawn(sc-8g5): 再 spawn で残る stale な SPAWNED marker を新規出現と誤読しない（baseline 差分・fail-open 封鎖）" {
  # bd notes に既に [SPAWNED--un-4nm] が在る（前回 spawn の marker）状態で、今回の worker は起動しない。
  # baseline を取らない実装は即 OK を宣言してしまう（silent に broken worker を「起動済み」と誤宣言）。
  echo delivered > "$S/mode"; echo always > "$S/bdmode"
  _spawn
  [ "$status" -eq 7 ]
  [[ "$output" == *"post-spawn submit 検証に失敗"* ]]
}

# ---------- 検証不能時の挙動（構造的不能のみ loud skip・capture 失敗では放棄しない）----------

@test "spawn(sc-8g5): capture 対象が構造的に不在（tmux 不在＝WID 未解決 かつ capture seam 未設定）なら検証を loud に skip" {
  # 実 tmux に window が無い（WID 空）＋ capture seam 未設定＝capture の宛先そのものが無い唯一の skip 条件。
  # OK を宣言せず「未検証」と明示する（silent 降格ゼロ）。既存 bats（実 tmux 無し）が無改修 green の根拠でもある。
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$NOOP_CLD" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
  [ "$status" -eq 0 ]                                   # spawn 自体は成立
  [[ "$output" == *"post-spawn submit 検証を実行できません"* ]]
  [[ "$output" == *"未検証"* ]]
  [[ "$output" == *"spawned: issue=un-4nm"* ]]
  ! grep -q '^CAPTURE' "$S/calls.log"                   # WID 空で既定 capture を叩かない（admin pane の誤 capture 防止）
}

@test "spawn(sc-8g5/AC7): capture が失敗し続けても検証層を放棄しない（SPAWNED 不着 → exit 7・fail-open ゼロ）" {
  # review finding#2 の回帰: capture 1 回の失敗で検証層ごと skip すると、silent unsubmitted worker が
  # 「spawned:」で通過する（OK の oracle は bd notes の marker であって capture ではない）。
  echo fail > "$S/mode"; echo never > "$S/bdmode"
  _spawn
  [ "$status" -eq 7 ]
  [[ "$output" == *"pane capture に失敗/空"* ]]         # loud に degrade を surface（marker のみで判定継続）
  [[ "$output" == *"post-spawn submit 検証に失敗"* ]]
  [[ "$output" == *"再 spawn しないでください"* ]]
  [[ "$output" == *"scribe-cleanup.sh"* ]]
  [[ "$output" != *"spawned: issue=un-4nm"* ]]
  [ "$(_enters)" -eq 0 ]                                # capture 不能＝INCONCLUSIVE 相当 → Enter は撃たない（DJ-b）
}

@test "spawn(sc-8g5/AC2): capture が初回だけ失敗しても以降の RESIDUAL を回復し SPAWNED で OK" {
  # transient な capture 失敗（WID は解決済み・window は在る）で検証層を捨てない＝marker polling を継続する。
  export SCRIBE_SPAWN_CONFIRM_BUDGET=10
  export SCRIBE_SPAWN_CONFIRM_POLL=0
  _set_prompt_marker
  echo fail-once > "$S/mode"; echo after-enter > "$S/bdmode"
  _spawn
  [ "$status" -eq 0 ]
  [[ "$output" == *"pane capture に失敗/空"* ]]         # 初回失敗は loud
  [[ "$output" == *"RESIDUAL＝未 submit"* ]]            # 2 周目で RESIDUAL を検知して回復
  [[ "$output" == *"post-spawn 検証 OK"* ]]
  [[ "$output" == *"spawned: issue=un-4nm"* ]]
  [ "$(_enters)" -ge 1 ]
}

@test "spawn(sc-8g5): 検証層 env のタイポは **launch 前** に fail-loud（worker を孤児化しない・finding#1）" {
  # SCRIBE_SPAWN_CONFIRM_BUDGET=90s（単位付きタイポ）。旧実装は cld-spawn success 後に die し、生きた worker を
  # 抱えたまま exit 7 の「再 spawn するな / cleanup」案内を出さずに落ちていた（二重 worker の温床）。
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$NOOP_CLD" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" SCRIBE_SPAWN_CONFIRM_BUDGET=90s \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
  [ "$status" -ne 0 ]
  [[ "$output" == *"SCRIBE_SPAWN_CONFIRM_BUDGET"* ]]
  [ ! -d "$WT" ]                                        # worktree すら作られない＝launch 前に停止（孤児ゼロ）
  [ ! -s "$S/calls.log" ]                               # capture も tmux も触らない（cld-spawn 前に死ぬ）
}

# ---------- scope: bg は原理免疫（検証層を発火させない）----------

@test "spawn(sc-8g5): transport=bg では検証層を発火させない（positional prompt ゆえ swallowed-Enter race が不成立）" {
  command -v jq >/dev/null 2>&1 || skip "jq が不在"
  local avail claude
  avail="$BATS_TEST_TMPDIR/bg-avail"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$BATS_TEST_TMPDIR/claude-stub"
  printf '#!/usr/bin/env bash\ncase "$1" in --help) echo " --bg  --model  --effort";; --bg) echo bg-short-id;; *) :;; esac\nexit 0\n' > "$claude"
  chmod +x "$claude"
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$avail" SCRIBE_CLAUDE_BIN="$claude" \
      SCRIBE_PLUGIN_DIR="$REPO_ROOT" SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg):"* ]]
  [[ "$output" != *"post-spawn"* ]]                     # 検証層は tmux 経路のみ
  ! grep -q '^CAPTURE' "$S/calls.log"                   # capture すらしない（side-effect ゼロ）
}

# ---------- dry-run は side-effect ゼロ（検証層を呼ばない）----------

@test "spawn(sc-8g5): --dry-run は検証層を一切呼ばない（capture / bd --json / tmux に触れない）" {
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN=cld-spawn \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [ ! -s "$S/calls.log" ]
  [ "$(cat "$S/bdcalls")" -eq 0 ]
}

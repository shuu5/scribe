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
  # sc-9954: worker 既定が auto へ反転し、素の worker spawn も selector（scribe-account-select）を通る。実 claude-usage を
  # 叩かせず決定論化する: SCRIBE_USAGE_CMD を不在パスに固定 → selector exit 3（API 故障）→ 主アカ fallback（＝sc-9954 前の
  # 既定挙動 mirror/unset と同一解決）。本層は account 選択でなく submit 検証が主題ゆえ fallback で十分。
  export SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/scribe-no-usage-cmd"

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
  list-windows)
    # sc-9nc7: scribe_window_id は session-scope（list-windows -t "=<session>"）で window_id を引く。
    # SCRIBE_WINDOWS_STUB（"@N <window-name>" 行）が非空のときだけ返す。既定は空＝WID 未解決
    # （＝tmux 不在 / window 未解決）の再現で、これが「構造的に不能」テストの前提を保つ。
    echo "TMUX $sub $*" >> "$S/calls.log"
    [[ -n "${SCRIBE_WINDOWS_STUB:-}" ]] && printf '%s\n' "$SCRIBE_WINDOWS_STUB" ;;
  display-message)
    # sc-9nc7: -t <pane> 指定時のみ pane_id を第 1 フィールドへエコーする（実 tmux の
    # '#{pane_id} #{session_name}' format 再現）。PANE_ECHO_STUB でエコー不一致を作れる。
    echo "TMUX $sub $*" >> "$S/calls.log"
    _tgt=""; _prev=""
    for _a in "$@"; do [[ "$_prev" == "-t" ]] && _tgt="$_a"; _prev="$_a"; done
    [[ -n "$_tgt" ]] && echo "${PANE_ECHO_STUB-$_tgt} ${SCRIBE_SESSION_STUB-sess-stub}" ;;
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
#   sc-9nc7: spawn_confirm の loud-skip 条件が「WID 空 かつ capture seam 未設定」の論理積から
#   **WID 単独**へ変わった（空 WID のまま send-keys すると tmux が -t '' を現在 pane と解釈し、
#   他 session の live admin pane へ Enter を撃つため）。ゆえに検証層を発火させるドライバは
#   **WID が解決する現実**を stub で作る必要がある: 自 pane（TMUX_PANE）が実在して session が
#   確定し、その session 内に対象 window がある、という状態。
_spawn() {
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$NOOP_CLD" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      TMUX_PANE="%42" SCRIBE_WINDOWS_STUB="@9 wt-un-4nm" \
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

# ---------- sc-9nc7: WID 非空 assert（空 WID で 1 キーも送らない・誤配防止）----------
# tmux は `-t ''` を「現在 pane」と解釈するため、空 WID のまま capture-pane / send-keys を叩くと
# **他 session の live admin pane** を掴み、そこへ Enter を撃つ（実測 scriptorium:orchestrator.%35 /
# scm:admin.%9）。旧 skip 条件は「WID 空 **かつ** capture seam 未設定」の論理積で、seam を設定した
# 呼出では空 WID のまま送信側（$SPAWN_TMUX send-keys -t "$_wid"）へ進めた（seam は capture だけを
# 差し替え、send-keys は素通しのため）。条件を WID 単独へ変えたことを、この 3 本が非空虚に pin する。

@test "spawn(sc-9nc7): WID 空なら capture seam が設定されていても capture も send-keys も 1 回も発行しない" {
  # SCRIBE_WINDOWS_STUB を渡さない＝window が引けず WID 空。旧論理積の実装はここで capture 経路へ
  # 進み（seam があるため）、空 WID の send-keys まで到達する。
  echo residual > "$S/mode"; echo after-enter > "$S/bdmode"
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$NOOP_CLD" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" TMUX_PANE="%42" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
  [ "$status" -eq 0 ]                                   # loud warn + return 0（非 0 化しない現行契約を維持）
  [[ "$output" == *"post-spawn submit 検証を実行できません"* ]]
  [[ "$output" == *"未検証"* ]]
  [[ "$output" == *"spawned: issue=un-4nm"* ]]
  ! grep -q '^CAPTURE' "$S/calls.log"                   # capture-pane を 1 回も発行しない
  ! grep -q '^ENTER' "$S/calls.log"                     # send-keys Enter を 1 キーも送らない
  [ "$(_enters)" -eq 0 ]
}

@test "spawn(sc-9nc7): session を積極証拠で確定できない（pane エコー不一致）なら WID を解決せず loud skip" {
  # window は在る（SCRIBE_WINDOWS_STUB 非空）が、TMUX_PANE のエコーが一致しない＝自 pane の
  # session を確定できない。scribe_window_id は -a による全 session 横断へ fallback せず空を返す。
  echo residual > "$S/mode"; echo after-enter > "$S/bdmode"
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$NOOP_CLD" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" TMUX_PANE="%42" \
      PANE_ECHO_STUB="%99" SCRIBE_WINDOWS_STUB="@9 wt-un-4nm" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"post-spawn submit 検証を実行できません"* ]]
  ! grep -q '^CAPTURE' "$S/calls.log"
  ! grep -q '^ENTER' "$S/calls.log"
}

@test "spawn(sc-9nc7): WID が解決できれば検証層は従来どおり発火する（上 2 本が空虚でないことの対照）" {
  # 上の 2 本が「常に skip する実装」でも緑になるのを防ぐ positive control。
  echo residual > "$S/mode"; echo after-enter > "$S/bdmode"
  _set_prompt_marker
  _spawn
  [ "$status" -eq 0 ]
  [[ "$output" != *"post-spawn submit 検証を実行できません"* ]]
  [[ "$output" == *"post-spawn 検証 OK"* ]]
  grep -q '^CAPTURE @9' "$S/calls.log"                  # 解決済み WID(@N) を宛先に capture している
  grep -q '^ENTER .*-t @9' "$S/calls.log"               # send-keys も @N 宛（名前でも空でもない）
  [ "$(_enters)" -ge 1 ]
}

@test "spawn(sc-9nc7): cld-spawn 起動 2 系統（consult / worker）に --session を足していない（無条件必須化の封鎖）" {
  # cld-spawn 側の「積極証拠で解決できないときだけ --session 必須」を **無条件必須**へ広げると、
  # 呼び手側に --session の供給が要るようになる。それは本 leg の scope 外であり、かつ --session は
  # --inject-existing と併用禁止ゆえ inject 経路を巻き添えにする。呼び手が引数変更なしのままである
  # ことを機械照合で pin する（scribe repo 内の 2 系統に限定＝scriptorium-engine 側は対象外）。
  run grep -n '"\$CLD_SPAWN" --cd' "$SPAWN"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '"\$CLD_SPAWN" --cd')" -eq 2 ]   # consult / worker の 2 系統
  ! printf '%s\n' "$output" | grep -q -- '--session'
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

# ---------- sc-r43f: launch rc≠0 の断定撤去 + cleanup 提示の条件化（両経路・orch-2z5r ②）----------
# 何を守るか: cld-spawn / bg launch の rc≠0 は **送達確認（read-back）の失敗**しか意味しないのに、旧文言は
#   「worker は起動していません」と断定していた（→ admin が再 spawn して二重 worker）うえ、cleanup コマンドを
#   **無条件**に提示していた（→ live worker の破壊＝「消す」クラス事故。scm-hpti が 3 例目で実行一歩手前）。
#   ゆえに (1) error: 行を非断定文言へ是正し (2) 積極証拠の確認手順（bd show の SPAWNED marker + status /
#   tmux 経路は capture-pane 併記）を **cleanup コマンドより先に** 印字して cleanup 行を「不在が確定した
#   場合のみ」へ従属させる。oracle は file の grep ではなく **実行 stderr の内容と印字順序**（vacuous 封鎖）。
#   exit code は不変（本 leg は文言と提示構造のみ・成功扱いへの反転や裏取り実装は sc-gvvr ①）。

@test "rbff: cld-spawn rc≠0 は断定せず確認手順（bd marker + capture-pane）を cleanup より先に出す" {
  local fail42 p_ln t_ln c_ln cl_ln
  fail42="$BATS_TEST_TMPDIR/rbff-cld-42"; printf '#!/usr/bin/env bash\nexit 42\n' > "$fail42"; chmod +x "$fail42"
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$fail42" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      TMUX_PANE="%42" SCRIBE_WINDOWS_STUB="@9 wt-un-4nm" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
  [ "$status" -eq 42 ]                                     # exit code は素通し（不変・1/7 と弁別可能な値）
  [[ "$output" != *"worker は起動していません"* ]]          # 旧断定文言の撤去
  [[ "$output" != *"起動していません"* ]]                   # 言い換えによる復活も封鎖
  [[ "$output" != *"起動失敗"* ]]
  [[ "$output" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$output" == *"[SPAWNED--un-4nm]"* ]]                 # 積極証拠の確認手順（bd show の marker）
  [[ "$output" == *"in_progress"* ]]                       # status も併記（marker + status の AND）
  [[ "$output" == *"tmux capture-pane"* ]]                 # tmux 経路は pane 一次観測も併記
  [[ "$output" == *"不在が確定した場合のみ"* ]]             # cleanup は条件へ従属
  [[ "$output" == *"scribe-cleanup.sh"* ]]                 # cleanup 行自体は残す（削除ではなく従属化）
  # 印字順序（acceptance(2) の本体は literal ではなく順序）: 確認手順・条件文言が cleanup コマンドより前。
  p_ln="$(grep -n -m1 -F 'SPAWNED--un-4nm' <<< "$output" | cut -d: -f1)"
  t_ln="$(grep -n -m1 -F 'tmux capture-pane' <<< "$output" | cut -d: -f1)"
  c_ln="$(grep -n -m1 -F '不在が確定した場合のみ' <<< "$output" | cut -d: -f1)"
  cl_ln="$(grep -n -m1 -F 'scribe-cleanup.sh --repo' <<< "$output" | cut -d: -f1)"
  [ -n "$p_ln" ] && [ -n "$t_ln" ] && [ -n "$c_ln" ] && [ -n "$cl_ln" ]
  [ "$p_ln" -lt "$cl_ln" ]
  [ "$t_ln" -lt "$cl_ln" ]
  [ "$c_ln" -lt "$cl_ln" ]
  [ -d "$WT" ]                                             # orphan は残す（自動削除しない＝既存契約）
}

@test "rbff: bg launch 失敗も断定せず確認手順（bd marker）を cleanup より先に出す" {
  # --transport bg を **明示** する: auto は bg launch 失敗時に tmux へ post-launch fallback して当該 block へ
  # 入らない（＝assert が vacuous になる）。jq は bg × SCRIBE_SANDBOX=0 の env carrier 合成に必須（skip しない）。
  local avail claude p_ln c_ln cl_ln
  avail="$BATS_TEST_TMPDIR/rbff-bg-avail"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$BATS_TEST_TMPDIR/rbff-claude-9"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--model M] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo 'if [[ "$1" == "--bg" ]]; then echo "bgagent-abcd1234"; exit 9; fi'
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg un-4nm
  [ "$status" -eq 9 ]                                      # bg stub の exit code を素通し（不変）
  [[ "$output" == *"bg launch（claude --bg）が失敗しました"* ]]   # 事実（launch コマンドの失敗）は残す
  [[ "$output" != *"worker は起動していません"* ]]
  [[ "$output" != *"起動していません"* ]]
  [[ "$output" != *"起動失敗"* ]]
  [[ "$output" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$output" == *"[SPAWNED--un-4nm]"* ]]
  [[ "$output" == *"in_progress"* ]]
  [[ "$output" == *"不在が確定した場合のみ"* ]]
  [[ "$output" == *"scribe-cleanup.sh"* ]]
  [[ "$output" != *"capture-pane"* ]]                      # bg は tmux window が無い（pane 観測を誤案内しない）
  p_ln="$(grep -n -m1 -F 'SPAWNED--un-4nm' <<< "$output" | cut -d: -f1)"
  c_ln="$(grep -n -m1 -F '不在が確定した場合のみ' <<< "$output" | cut -d: -f1)"
  cl_ln="$(grep -n -m1 -F 'scribe-cleanup.sh --repo' <<< "$output" | cut -d: -f1)"
  [ -n "$p_ln" ] && [ -n "$c_ln" ] && [ -n "$cl_ln" ]
  [ "$p_ln" -lt "$cl_ln" ]
  [ "$c_ln" -lt "$cl_ln" ]
  [ -d "$WT" ]
}

@test "rbff: 案内は stderr のみへ出る（stdout 純度＝group redirect 破壊の唯一の検出網）" {
  # `{ … } >&2` を printf/heredoc へ書き換えたり group redirect を落とすと、案内が stdout へ漏れて
  # 「spawned 行だけを読む」consumer を汚す。stdout/stderr を分離して両側から pin する。
  local fail42
  fail42="$BATS_TEST_TMPDIR/rbff-cld-42b"; printf '#!/usr/bin/env bash\nexit 42\n' > "$fail42"; chmod +x "$fail42"
  run --separate-stderr env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$fail42" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      TMUX_PANE="%42" SCRIBE_WINDOWS_STUB="@9 wt-un-4nm" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
  [ "$status" -eq 42 ]
  [[ "$stderr" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$stderr" == *"[SPAWNED--un-4nm]"* ]]
  [[ "$stderr" == *"不在が確定した場合のみ"* ]]
  [[ "$stderr" == *"scribe-cleanup.sh"* ]]
  [[ "$output" != *"送達確認が取れませんでした"* ]]          # stdout（$output）へは 1 文字も漏らさない
  [[ "$output" != *"scribe-cleanup.sh"* ]]
  [[ "$output" != *"SPAWNED--un-4nm"* ]]
}

# ---------- sc-gvvr ①: launch rc≠0 を marker 増分の積極証拠で成功扱いへ倒す（両経路・orch-2z5r ①）----------
# 何を守るか: cld-spawn / bg launch の rc≠0 は **read-back（送達確認）の失敗**しか意味せず、worker は既に turn を
#   始めていることがある（実測 3 例）。②（sc-r43f）は文言と提示構造だけを直したので、rc≠0 は依然として非 0 exit で
#   終わり monitor 案内まで飛ぶ（2 次被害＝admin が monitor を手で立て直す）。ここでは
#   (1) 倒す唯一の oracle を spawn_confirm_spawned_new（[SPAWNED--<id>] の **baseline 比 新規出現**）に固定し
#       （rc の意味論では倒さない・生の marker 件数 > 0 でも倒さない＝stale marker の fail-open 封鎖）、
#   (2) 陽性なら exit 0・掃除提示ゼロ・spawned:/monitor: を emit し（成功扱い）、
#   (3) 陰性 / 判定不能では rc を **素通し**して ② の文言・印字順序を退行させないこと、
#   (4) cld の成功扱いでは post-spawn 検証層を skip する（capture / send-keys を 1 回も発行しない）こと
#   を、file の grep ではなく **実行の exit code と stdout/stderr** で pin する（vacuous 封鎖）。

# cld-spawn を任意 rc で失敗させる driver（bdmode は呼び手が事前に設定する）。
_spawn_cld_fail() {   # $1 = cld-spawn の exit code
  local f="$BATS_TEST_TMPDIR/rbff2-cld-$1"
  printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$f"; chmod +x "$f"
  run --separate-stderr env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN="$f" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      TMUX_PANE="%42" SCRIBE_WINDOWS_STUB="@9 wt-un-4nm" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" un-4nm
}

# bg launch を任意 rc で失敗させる driver（--transport bg 明示＝auto の post-launch fallback を避ける。jq は
# rbff:（bg）と同じく必須前提で skip しない＝rbff2 群を非空虚に保つ）。--bg の stdout は file 経由で与えるので
# 未 trim（前後空白・改行）の生返却値もそのまま再現できる。
_spawn_bg_fail() {   # $1 = claude --bg の exit code / $2 = --bg の stdout（既定 bgagent-abcd1234）
  local rc="$1" avail claude outf
  outf="$BATS_TEST_TMPDIR/rbff2-bgout"; printf '%s' "${2-bgagent-abcd1234}" > "$outf"
  avail="$BATS_TEST_TMPDIR/rbff2-bg-avail"; printf '#!/usr/bin/env bash\nexit 0\n' > "$avail"; chmod +x "$avail"
  claude="$BATS_TEST_TMPDIR/rbff2-claude"
  {
    echo '#!/usr/bin/env bash'
    echo 'if [[ "$1" == "--help" ]]; then echo "usage: claude [--bg] [--model M] [--effort L] [--plugin-dir D] ..."; exit 0; fi'
    echo "if [[ \"\$1\" == \"--bg\" ]]; then cat '$outf'; exit $rc; fi"
    echo 'exit 0'
  } > "$claude"; chmod +x "$claude"
  run --separate-stderr env PATH="$SHIM_PATH" BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_BG_PREFLIGHT="$avail" \
      SCRIBE_CLAUDE_BIN="$claude" SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg un-4nm
}

@test "rbff2: cld rc≠0 + SPAWNED 新規出現 → exit 0 で成功扱い（loud warn・掃除提示ゼロ・spawned:/monitor: を emit）" {
  echo delivered > "$S/mode"; echo immediate > "$S/bdmode"   # c=0 が baseline read → 以降 marker 出現＝増分あり
  _spawn_cld_fail 42
  [ "$status" -eq 0 ]                                                     # rc を 42 のまま落とさず成功扱いへ倒す
  [[ "$output" == *"spawned: issue=un-4nm"* ]]                            # stdout に spawned:
  [[ "$output" == *"monitor: "* ]]                                        # stdout に monitor:（2 次被害＝monitor skip の回復）
  [[ "$stderr" == *"積極証拠で起動を確認しました（成功扱いで続行します）"* ]]   # canonical loud warn（逐語）
  [[ "$stderr" == *"exit=42"* ]]                                          # 元の rc 値を surface（silent 昇格ゼロ）
  [[ "$stderr" == *"重複注入された可能性"* ]]                              # retry による prompt 重複の注意
  [[ "$stderr" == *"tmux list-windows"* ]]                                # 二重 worker の一次観測手順
  [[ "$output$stderr" != *"scribe-cleanup.sh"* ]]                         # 出力全体に掃除コマンドを 1 文字も出さない
  [[ "$output$stderr" != *"起動していません"* ]]
  [[ "$output" != *"積極証拠で起動を確認しました"* ]]                       # 新 warn は stdout を汚さない（stderr のみ）
  [ -d "$WT" ]
}

@test "rbff2: cld rc≠0 + SPAWNED 不着 → rc を素通し（exit 42）し ② の非断定文言と印字順序を退行させない" {
  local p_ln t_ln c_ln cl_ln
  echo delivered > "$S/mode"; echo never > "$S/bdmode"
  _spawn_cld_fail 42
  [ "$status" -eq 42 ]                                                    # 陰性は rc 素通し（7 等へ丸めない）
  [[ "$stderr" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$stderr" != *"起動していません"* ]]
  [[ "$stderr" != *"積極証拠で起動を確認しました"* ]]                       # 陰性で成功扱い warn を出さない
  [[ "$stderr" == *"不在が確定した場合のみ"* ]]
  [[ "$output" != *"spawned: issue=un-4nm"* ]]
  p_ln="$(grep -n -m1 -F 'SPAWNED--un-4nm' <<< "$stderr" | cut -d: -f1)"
  t_ln="$(grep -n -m1 -F 'tmux capture-pane' <<< "$stderr" | cut -d: -f1)"
  c_ln="$(grep -n -m1 -F '不在が確定した場合のみ' <<< "$stderr" | cut -d: -f1)"
  cl_ln="$(grep -n -m1 -F 'scribe-cleanup.sh --repo' <<< "$stderr" | cut -d: -f1)"
  [ -n "$p_ln" ] && [ -n "$t_ln" ] && [ -n "$c_ln" ] && [ -n "$cl_ln" ]
  [ "$p_ln" -lt "$cl_ln" ]
  [ "$t_ln" -lt "$cl_ln" ]
  [ "$c_ln" -lt "$cl_ln" ]
}

@test "rbff2: cld rc≠0 + stale marker（baseline 時点で既在）→ 成功扱いへ倒さない（exit 42・fail-open 封鎖）" {
  # 再 spawn の残骸 marker を「新規出現」と誤読すると、起動していない worker を成功扱いにしてしまう。
  # 判定は **生の件数 > 0** ではなく baseline 差分でなければならない、の回帰 pin。
  echo delivered > "$S/mode"; echo always > "$S/bdmode"
  _spawn_cld_fail 42
  [ "$status" -eq 42 ]
  [[ "$stderr" != *"積極証拠で起動を確認しました"* ]]
  [[ "$stderr" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$output" != *"spawned: issue=un-4nm"* ]]
}

@test "rbff2: cld の成功扱いでは post-spawn 検証層を再実行しない（capture 0 件・send-keys 0 件）" {
  # ■F5: 成功扱い後に検証層へ fall-through させると、marker 導出失敗経路 / budget 経路が
  # spawn_confirm_orphan_guidance を呼び「掃除提示なし」が確率的に破れる。層ごと skip することを side-effect で pin。
  echo residual > "$S/mode"; echo immediate > "$S/bdmode"   # capture すれば RESIDUAL→Enter を撃つ mode
  _spawn_cld_fail 42
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned: issue=un-4nm"* ]]
  ! grep -q '^CAPTURE' "$S/calls.log"                       # capture-pane を 1 回も発行しない
  ! grep -q '^ENTER' "$S/calls.log"                         # send-keys Enter を 1 キーも送らない
  [ "$(_enters)" -eq 0 ]
  [[ "$stderr" != *"post-spawn 検証 OK"* ]]                  # 検証層そのものを通っていない
  [[ "$stderr" != *"post-spawn submit 検証に失敗"* ]]
}

@test "rbff2: bg rc≠0 + SPAWNED 新規出現 → exit 0 で成功扱い（spawned(bg): の agent_id は単一トークン・掃除提示ゼロ）" {
  local aid
  echo immediate > "$S/bdmode"                              # baseline（launch 直前の自前取得）→ 以降 marker 出現
  _spawn_bg_fail 9 $'  bgagent-abcd1234  \n'                # 未 trim の生 stdout（空白・改行込み）
  [ "$status" -eq 0 ]
  [[ "$output" == *"spawned(bg): issue=un-4nm"* ]]
  [[ "$output" == *"monitor: "* ]]
  [[ "$stderr" == *"積極証拠で起動を確認しました（成功扱いで続行します）"* ]]
  [[ "$stderr" == *"exit=9"* ]]
  [[ "$stderr" == *"重複注入された可能性"* ]]
  [[ "$stderr" == *"tmux list-windows"* ]]
  [[ "$output$stderr" != *"scribe-cleanup.sh"* ]]
  [[ "$output$stderr" != *"起動していません"* ]]
  # ■F8: short-id は成功枝と同一の trim を通る（未 trim の生 stdout を流さない＝空白を含まない単一トークン）。
  aid="$(sed -n 's/.*spawned(bg): issue=un-4nm agent_id=\([^ ]*\) .*/\1/p' <<< "$output")"
  [ "$aid" = "bgagent-abcd1234" ]
}

@test "rbff2: bg rc≠0 + SPAWNED 不着 → rc を素通し（exit 9）し ② の非断定文言と印字順序を退行させない" {
  local p_ln c_ln cl_ln
  echo never > "$S/bdmode"
  _spawn_bg_fail 9
  [ "$status" -eq 9 ]
  [[ "$stderr" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$stderr" != *"起動していません"* ]]
  [[ "$stderr" != *"積極証拠で起動を確認しました"* ]]
  [[ "$stderr" == *"不在が確定した場合のみ"* ]]
  [[ "$output" != *"spawned(bg):"* ]]
  p_ln="$(grep -n -m1 -F 'SPAWNED--un-4nm' <<< "$stderr" | cut -d: -f1)"
  c_ln="$(grep -n -m1 -F '不在が確定した場合のみ' <<< "$stderr" | cut -d: -f1)"
  cl_ln="$(grep -n -m1 -F 'scribe-cleanup.sh --repo' <<< "$stderr" | cut -d: -f1)"
  [ -n "$p_ln" ] && [ -n "$c_ln" ] && [ -n "$cl_ln" ]
  [ "$p_ln" -lt "$cl_ln" ]
  [ "$c_ln" -lt "$cl_ln" ]
}

@test "rbff2: bg rc≠0 + stale marker（baseline 時点で既在）→ 成功扱いへ倒さない（exit 9・fail-open 封鎖）" {
  echo always > "$S/bdmode"
  _spawn_bg_fail 9
  [ "$status" -eq 9 ]
  [[ "$stderr" != *"積極証拠で起動を確認しました"* ]]
  [[ "$stderr" == *"送達確認が取れませんでした（worker が起動しているかは未確定）"* ]]
  [[ "$output" != *"spawned(bg):"* ]]
}

@test "rbff2: bg の baseline は transport 分岐の内側で取る（--dry-run は bd --json を 1 回も叩かない）" {
  # ■F11/confirm.bats:470 と同じ side-effect 規律を bg baseline 追加後も保つ（dry-run で bd を叩き始めたら
  # 「dry-run は side-effect ゼロ」契約が壊れる）。--transport bg 明示で dry-run しても bdcalls は 0。
  run env BEADS_BDW="$BDW_PRESENT_STUB" SCRIBE_CLD_SPAWN=cld-spawn \
      SCRIBE_BG_PREFLIGHT=/bin/true SCRIBE_CLAUDE_BIN=/bin/true SCRIBE_PLUGIN_DIR="$REPO_ROOT" \
      SCRIBE_SPAWN_CAPTURE="$CAPTURE_STUB" SCRIBE_TMUX="$TMUX_STUB" \
      "$SPAWN" --repo "$REPO" --anchor "$REPO" --transport bg --dry-run un-4nm
  [ "$status" -eq 0 ]
  [ "$(cat "$S/bdcalls")" -eq 0 ]
  [ ! -s "$S/calls.log" ]
}

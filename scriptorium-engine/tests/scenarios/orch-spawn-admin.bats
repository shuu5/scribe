#!/usr/bin/env bats
# tests/scenarios/orch-spawn-admin.bats
#
# orch-spawn-admin.sh の終端宣言作法ブリーフ恒久注入（orch-ail (2) / orch-mot / orch-306）の決定的テスト。
#
# 方式: cld-spawn を env ORCH_SPAWN_CLD でスタブへ差替（実 spawn しない・受け取った prompt を生で記録）、
#   project レジストリを env ORCH_ADMIN_PROJECTS で hermetic な temp dir へ全置換し、実 script を実行して
#   assert する hermetic E2E（$HOME 非依存・実 tmux window を建てない）。
#   - dry-run: cld-spawn を呼ばず実行予定コマンド（%q 整形）を print。ブリーフは %q 化されるため ASCII
#     sentinel [ORCH-WATCH-CONTRACT] と直 echo の announce 行で検証する（%q の Japanese は locale 依存ゆえ）。
#   - exec（stub）: cld-spawn stub が **最後の引数（= kickoff prompt）を生で** $CLD_PROMPT_FILE へ書く。
#     %q を介さない生バイトゆえ locale 非依存にブリーフ内容を grep できる（注入の実体を検査する主経路）。
#
# 検証する契約不変条件（bd orch-ail (2) = ratify 済契約）:
#   恒久注入: spawn brief に「①自台帳に終端宣言 bead を作り ID を即報告 ②DONE/BLOCKED/NEEDS-USER を宣言
#     ③背景 pending 中は宣言しない ④orchestrator は直読 poll で監視 ⑤pane は truth でない」を恒久注入する。
#   - prompt の有無に依らず常に注入される（user kickoff 無しでもブリーフのみ inject）。
#   - user kickoff があればブリーフの後に置かれる（discipline がタスクを frame する）。
#   - .beads 無し project は「終端宣言 bead を作れない＝最終出力で明示」変種を注入する。
#
# private 配備層の docs/systemd drift teeth（$REPO_ROOT/CLAUDE.md・docs/・systemd/ 実ファイルを grep する @test）は
#   配備層側 residual bats が担う（engine copy は mechanism teeth のみ）。
#
# 実行: bats tests/scenarios/orch-spawn-admin.bats

# config-dir preflight（orch-dgo self-review major）の健全 fixture 生成ヘルパ。$1=config-dir path。
#   sibling worker（scribe probe_config_dir）と同水準の 4 段検査 (a)dir 実在 (b).credentials.json
#   (c).claude.json の hasCompletedOnboarding=true (d)plugins/{scribe,beads-bdw,cmdtokens} enable を
#   すべて満たす hermetic な config-dir を作る（preflight を通す健全 fixture）。各 unhealthy modality の
#   teeth は「作った後に該当ファイル/dir を rm する」ことで局所的に構成できる（drift を避ける単一 SSOT）。
make_healthy_cfgdir() {
    local d="$1"
    mkdir -p "$d/plugins"
    printf '{}\n' > "$d/.credentials.json"
    printf '{"hasCompletedOnboarding": true}\n' > "$d/.claude.json"
    local p
    for p in scribe beads-bdw cmdtokens; do mkdir -p "$d/plugins/$p"; done
}

# fail-closed 否定 grep（gate WF wf_a106a4e2 errata・orch-k660）:
#   ★中間位置の `! grep …` は **無牙**（bats/set -e は `!` 反転コマンドの失敗で test を fail させない仕様＝
#     bash errexit の `!` 免除。統制実験で bats 1.13.0 実証: 中間位置 `! true`(exit1) は test を pass させる／
#     `[ ]`(exit1) と last 位置 `!` は fail させる）。ゆえに CMD へ payload 再付与等の回帰が中間 `! grep` を
#     すり抜ける（gate が 16/16 green を実 mutation 実証）。refute_grep は plain command として非0 を返し、
#     中間位置でも errexit teeth を持つ（`run` を使わず $output/$status を温存＝先行 run_spawn_admin の観測を壊さない）。
#   使い方: `! grep <args>` を機械的に `refute_grep <args>` へ置換する（引数は grep へ透過）。
refute_grep() { if grep "$@" >/dev/null 2>&1; then return 1; fi; return 0; }

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-spawn-admin.sh"
    TEST_TMPDIR=$(mktemp -d -t orch-spawn-admin-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"
    mkdir -p "$BIN"

    # hermeticity 硬化（orch-70i）: 下記「共有 lib SSOT」ブロックの新 SSOT テストは env 未設定経路
    #   （DEFAULT_PROJECTS 実路）を oracle にするが、run_real / 直 run 呼出は ORCH_ADMIN_PROJECTS を自前 set しない。
    #   開発者シェルが本 feature デバッグ中に ORCH_ADMIN_PROJECTS を export したまま bats を回すと、実 script は
    #   env override 分岐へ入り DEFAULT_PROJECTS 実路を通らず env-unset oracle（合成 registry 掲載等）が
    #   ambient 依存で誤 RED 化する。ここで ambient から明示 unset して env-unset 経路を確実に隔離する
    #   （run_spawn_admin は inline env-prefix で ORCH_ADMIN_PROJECTS を再 set するため既存 22 テストは無影響）。
    unset ORCH_ADMIN_PROJECTS

    # hermeticity 硬化（orch-dgo）: account/config-dir 解決は selector（ORCH_ACCOUNT_SELECT・既定 ~/.claude/plugins/
    #   scribe/scripts/scribe-account-select）を実行する。既定 selector が実在すると account 非指定の既存テストでも
    #   default-account probe が実 claude-usage を叩き非 hermetic 化する。既存テストは account 非対象ゆえ、ここで
    #   selector を存在しない path へ向け「selector 不在＝probe skip＝従来挙動」を確定させる（ORCH_ADMIN_PROJECTS
    #   の unset と同型のハーネス隔離）。account テストは各自 ORCH_ACCOUNT_SELECT を stub へ上書きする。
    export ORCH_ACCOUNT_SELECT="$TEST_TMPDIR/no-such-selector"
    export ORCH_ACCOUNTS_BASE="$TEST_TMPDIR/claude-accounts"
    # config-dir preflight（orch-dgo self-review major）: 注入する CFG_DIR は sibling worker（scribe probe_config_dir）
    #   と同水準の 4 段検査 (a)dir 実在 (b)credentials (c)onboarding (d)guard plugin enable で fail-loud する。既存の
    #   account テストが注入する acct-a の config-dir を **健全な** fixture として実在させ preflight を通す（実 account
    #   非依存・実 ~/.claude を触らない）。各 modality の teeth（credentials 不在 / onboarding 未完 / plugin 欠落 →die）は
    #   ACC-preflight-* 群が別途 pin する。健全 config-dir 生成は make_healthy_cfgdir ヘルパへ集約（drift 防止）。
    make_healthy_cfgdir "$ORCH_ACCOUNTS_BASE/acct-a"
    # env-file が chain-source する既定 env も hermetic に固定（実 ~/.cld-env を触らない・存在しなくても source は
    #   `|| true` で無害）。
    export CLD_ENV_FILE="$TEST_TMPDIR/cld-env"

    # hermetic project レジストリ（実在 dir・$HOME 非依存）。tb=beads 有 / tn=beads 無。
    export BEADS_DIR="$TEST_TMPDIR/proj-beads"
    export NOBEADS_DIR="$TEST_TMPDIR/proj-nobeads"
    export SELF_DIR="$TEST_TMPDIR/proj-self-orch"
    mkdir -p "$BEADS_DIR/.beads"     # .beads 有り・metadata 無し＝admin role 注入対象（orch と確証できない）
    mkdir -p "$NOBEADS_DIR"          # .beads 無し＝素の cld session
    mkdir -p "$SELF_DIR/.beads"      # 自台帳 fixture（dolt_database=orch）＝self-ledger footgun ガード対象
    printf '{"dolt_database":"orch"}\n' > "$SELF_DIR/.beads/metadata.json"

    # cld-spawn stub の記録先。
    export CLD_ARGS_FILE="$TEST_TMPDIR/cld-args.txt"
    export CLD_PROMPT_FILE="$TEST_TMPDIR/cld-prompt.txt"
    export CLD_ENVFILE_FILE="$TEST_TMPDIR/cld-envfile.txt"   # orch-dgo/F8: 渡された --env-file の内容を capture
    export CLD_ENVFILE_PATH="$TEST_TMPDIR/cld-envfile-path.txt"   # 渡された --env-file の path
    : > "$CLD_ARGS_FILE"; : > "$CLD_PROMPT_FILE"; : > "$CLD_ENVFILE_FILE"; : > "$CLD_ENVFILE_PATH"

    # ── stub: cld-spawn（実 spawn しない・spawn 呼出 と --inject-existing 呼出 を分岐して記録）──
    #    orch-k660 以降 orch-spawn-admin は 2 種類の cld-spawn 呼出をする:
    #      (1) spawn 呼出（payload なし・CMD=(... --model M --effort xhigh --disallowed-tools ... --env-file <f>)）
    #      (2) --inject-existing 呼出（spawn 後の submission・`... --inject-existing <win> --timeout N -- "<text>"`）
    #    stub は --inject-existing の有無で分岐する:
    #      spawn 呼出 → CLD_ARGS_FILE を truncate して全 argv を記録 + --env-file の path/内容を capture（F8）。
    #        CLD_PROMPT_FILE は書かない（payload なし＝post-`--` の kickoff は spawn 呼出には無い・orch-k660）。
    #      inject 呼出 → 最後の positional（= 注入 text）を CLD_PROMPT_FILE へ **append**（effort → kickoff の順で
    #        2 回呼ばれる＝順序と全 text を検査できる）。%q を介さない生バイトゆえ locale 非依存に grep できる。
    cat > "$BIN/cld-spawn-stub" <<'STUB'
#!/usr/bin/env bash
_is_inject=0
for a in "$@"; do [ "$a" = "--inject-existing" ] && _is_inject=1; done
if [ "$_is_inject" -eq 1 ]; then
    # 注入 text（最後の positional = post-`--` の 1 引数）を append（改行含む生バイト・複数回で順序保持）。
    printf '%s\n' "${!#}" >> "$CLD_PROMPT_FILE"
    exit 0
fi
# spawn 呼出: 全 argv を記録 + env-file capture。
: > "$CLD_ARGS_FILE"
for a in "$@"; do printf 'ARG\t%s\n' "$a" >> "$CLD_ARGS_FILE"; done
_prev=""
for a in "$@"; do
    if [ "$_prev" = "--env-file" ]; then
        printf '%s' "$a" > "$CLD_ENVFILE_PATH"
        [ -f "$a" ] && cat "$a" > "$CLD_ENVFILE_FILE"
        break
    fi
    _prev="$a"
done
exit 0
STUB
    chmod +x "$BIN/cld-spawn-stub"

    # ── stub: session-state（kickoff turn-start 照合の oracle・orch-k660/orch-sm6p）──
    #    orch-spawn-admin は kickoff 注入後に `session-state.sh state <win>` を poll し processing を positive-proof
    #    とする。既定 stub は processing（turn 起動）を返す＝happy path の exec テストが turn 照合を通る。boot-race
    #    テストは各自 input-waiting を返す stub へ差し替える（splash 滞留＝注入消失を再現）。
    export SESSION_STATE_STUB="$BIN/session-state-stub"
    cat > "$SESSION_STATE_STUB" <<'STUB'
#!/usr/bin/env bash
echo processing
STUB
    chmod +x "$SESSION_STATE_STUB"

    # ── selector stub 生成ヘルパ（account テスト用・TSV を吐いて指定 rc で exit）──
    #    write_selector <rc> <TSV 行...>（各行は $'label\t...\t...' でタブ区切り）。
    export SELECTOR_STUB="$BIN/scribe-account-select-stub"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# orch-spawn-admin.sh をスタブ環境で実行（cld-spawn は env seam・レジストリは ORCH_ADMIN_PROJECTS）。
#   ORCH_ACCOUNT_SELECT / ORCH_ACCOUNTS_BASE / CLD_ENV_FILE は setup で export 済（inherit される）。
#   account テストは呼出前に `ORCH_ACCOUNT_SELECT="$SELECTOR_STUB"` を prepend して selector を差し替える。
run_spawn_admin() {
    #   orch-k660 seam 硬化 → orch-i7ft で縮約: 旧 exec 経路は (1) fable preflight で実 claude を叩き (2) kickoff
    #   turn-start 照合で実 session-state を叩いた。(1) は既定 model が opus[1m] へ切り替わり preflight 機構ごと
    #   撤去された（orch-i7ft・user 裁定 2026-07-25）ため seam 注入も不要になった＝残る hermetic 固定は (2) のみ:
    #   SESSION_STATE=processing stub（turn 起動確認＝happy path が通る・boot-race テストは各自 input-waiting stub
    #   へ上書き）/ VERIFY_SETTLE=0（sleep しない＝bats を高速に保つ）。
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" \
    ORCH_ADMIN_PROJECTS="tb=$BEADS_DIR tn=$NOBEADS_DIR self=$SELF_DIR" \
    ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE="${ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE:-1}" \
    ORCH_SPAWN_ADMIN_SESSION_STATE="${ORCH_SPAWN_ADMIN_SESSION_STATE:-$SESSION_STATE_STUB}" \
    ORCH_SPAWN_ADMIN_VERIFY_SETTLE=0 \
    CLD_ARGS_FILE="$CLD_ARGS_FILE" \
    CLD_PROMPT_FILE="$CLD_PROMPT_FILE" \
        run bash "$SCRIPT" "$@"
}

# selector stub を書く（account テスト用）。$1=exit code、以降=TSV 行（$'label\teligible\t...' でタブ区切り）。
#   TSV 列: 1 label 2 eligible(1|0) 3 score 4 h5 5 h7 6 pct5 7 pct7 8 resets5 9 resets7 10 reason。
write_selector() {
    local rc="$1"; shift
    local tsv="$TEST_TMPDIR/sel.tsv"
    : > "$tsv"
    local line
    for line in "$@"; do printf '%s\n' "$line" >> "$tsv"; done
    cat > "$SELECTOR_STUB" <<STUB
#!/usr/bin/env bash
cat "$tsv"
exit $rc
STUB
    chmod +x "$SELECTOR_STUB"
}

# ==============================================================================
# 恒久注入: dry-run の観測面（sentinel + announce 行）
# ==============================================================================

@test "brief 恒久注入（dry-run・sentinel）: dry-run の %q 出力に ASCII sentinel と announce 行が載る" {
    run_spawn_admin tb --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"ORCH-WATCH-CONTRACT"* ]]                 # %q でも生き残る ASCII sentinel（ブリーフが prompt に在る証跡）
    [[ "$output" == *"終端宣言作法を kickoff へ恒久注入"* ]]   # 直 echo の announce 行（%q を介さない）
    # dry-run は cld-spawn を呼ばない（実 spawn しない）
    [ ! -s "$CLD_PROMPT_FILE" ]
}

# ==============================================================================
# 恒久注入: exec 経路で実際に prompt へ入る全要素（beads 変種）
# ==============================================================================

@test "brief 恒久注入（exec・内容）: kickoff prompt に終端宣言作法の 5 要素が入る（beads）" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    # cld-spawn stub が記録した生 prompt（%q 非経由＝locale 非依存）を検査。
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    grep -q '終端宣言 bead' "$CLD_PROMPT_FILE"               # ①自台帳に終端宣言 bead を作り ID 報告
    grep -q 'DONE / BLOCKED / NEEDS-USER' "$CLD_PROMPT_FILE"  # ②DONE/BLOCKED/NEEDS-USER を宣言
    grep -q '背景 pending' "$CLD_PROMPT_FILE"                # ③背景 pending 中は宣言しない
    grep -q -- '--foreign-repo' "$CLD_PROMPT_FILE"           # ④orchestrator は直読 poll で監視
    grep -q '直読 poll' "$CLD_PROMPT_FILE"
    grep -q 'pane' "$CLD_PROMPT_FILE"                        # ⑤pane は truth でない
    grep -q 'truth でない' "$CLD_PROMPT_FILE"
    grep -q 'INCONCLUSIVE' "$CLD_PROMPT_FILE"
}

@test "brief 恒久注入（exec・無人 window 作法 3 点／beads・orch-z7g/orch-355）: 対話禁止＋NEEDS-USER park＋push relay 待ちが入る" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    # ① 対話プロンプト禁止（無人 window）＝a human is not attending your window（3 modality を対称に pin）
    grep -q '対話プロンプトを使うな' "$CLD_PROMPT_FILE"
    grep -q 'AskUserQuestion' "$CLD_PROMPT_FILE"
    grep -q 'ExitPlanMode' "$CLD_PROMPT_FILE"
    grep -q 'permission 待ち' "$CLD_PROMPT_FILE"
    grep -q 'a human is not attending your window' "$CLD_PROMPT_FILE"
    # ② human 決定は NEEDS-USER park（gate-pending は foreign admin の human 決定に使わない＝H3-i）
    grep -q 'NEEDS-USER を宣言' "$CLD_PROMPT_FILE"
    grep -q 'turn を終えよ' "$CLD_PROMPT_FILE"
    grep -q 'gate-pending' "$CLD_PROMPT_FILE"
    # ③ orchestrator が bead 直読 poll で検知し push relay で再開指示＝それを待て（H2/H3-ii）
    grep -q 'push relay' "$CLD_PROMPT_FILE"
    grep -q '再開指示' "$CLD_PROMPT_FILE"
    grep -q '宣言後は待て' "$CLD_PROMPT_FILE"
}

@test "brief 恒久注入（無人 window 作法 3 点／no-beads・orch-z7g/orch-355）: no-beads 変種にも対話禁止＋NEEDS-USER park＋push relay 待ちが入る" {
    run_spawn_admin tn
    [ "$status" -eq 0 ]
    # ① 3 modality を beads 版と対称に pin（permission prompt は無人 window で最も詰まりやすい）
    grep -q '対話プロンプトを使うな' "$CLD_PROMPT_FILE"
    grep -q 'AskUserQuestion' "$CLD_PROMPT_FILE"
    grep -q 'ExitPlanMode' "$CLD_PROMPT_FILE"
    grep -q 'permission 待ち' "$CLD_PROMPT_FILE"
    grep -q 'a human is not attending your window' "$CLD_PROMPT_FILE"
    # ② no-beads は bead でなく最終出力で park（gate-pending は human 決定に使わない＝H3-i も同旨で焼く）
    grep -q 'NEEDS-USER を最終出力で明示' "$CLD_PROMPT_FILE"
    grep -q 'turn を終えよ' "$CLD_PROMPT_FILE"
    grep -q 'gate-pending' "$CLD_PROMPT_FILE"
    # ③ push relay 再開指示を待て（点③を no-beads 変種でも対称に pin）
    grep -q 'push relay' "$CLD_PROMPT_FILE"
    grep -q '再開指示' "$CLD_PROMPT_FILE"
    grep -q '宣言後は待て' "$CLD_PROMPT_FILE"
}

@test "brief 恒久注入（relay 権威構造・rider orch-zct6・beads/no-beads 両分岐）: 両 brief に push relay 権威構造 sentinel（human 承認=standing go → orchestrator 決定 → relay 中継・human 本人発でない）が入る" {
    # orch-2vkx（PR#88）が両 brief に足した権威構造行を bats へ pin する。orch-spawn-admin.bats は 2vkx cell の
    #   editable scope 外だったため未 pin だった＝将来 refactor で片分岐から権威構造行が落ちても bats が検知できない穴を
    #   塞ぐ（rider orch-zct6・非vacuity）。sentinel の 3 契機（human 承認 ∧ 中継 ∧ human 本人発でない）を個別 assert し、
    #   どちらの分岐からその行を削る mutation でも該当 grep が落ちて RED になる。
    # ── beads 分岐（orch-spawn-admin.sh:373）──
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    grep -q 'push relay の権威構造' "$CLD_PROMPT_FILE"        # 権威構造の見出し
    grep -q 'human 承認' "$CLD_PROMPT_FILE"                    # human 承認=standing go（承認の存在）
    grep -q '中継' "$CLD_PROMPT_FILE"                          # relay は本人発でなく中継
    grep -q 'human 本人発の指示ではなく' "$CLD_PROMPT_FILE"    # 本人発でない（誤停止封鎖の核）
    grep -q '承認記録は bead notes' "$CLD_PROMPT_FILE"         # 承認 pointer
    # ── no-beads 分岐（orch-spawn-admin.sh:383）── 片分岐削除 mutation で RED になる非vacuity
    run_spawn_admin tn
    [ "$status" -eq 0 ]
    grep -q 'push relay の権威構造' "$CLD_PROMPT_FILE"
    grep -q 'human 承認' "$CLD_PROMPT_FILE"
    grep -q '中継' "$CLD_PROMPT_FILE"
    grep -q 'human 本人発の指示ではなく' "$CLD_PROMPT_FILE"
    grep -q '承認記録は bead notes' "$CLD_PROMPT_FILE"
}

@test "brief 恒久注入（exec・bead-append 規律／beads・orch-edv T1）: 新質問/報告/再 pause を bead notes に append し updated_at を動かす（pane-only 禁止）が入る" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    # ⑨ bead-append 規律（silent mutual-wait deadlock 恒久 fix・root cause #1/#3）を beads 変種に pin。
    grep -q 'append' "$CLD_PROMPT_FILE"                       # bead notes に append
    grep -q 'updated_at' "$CLD_PROMPT_FILE"                   # updated_at を動かす（baseline watch 発火の load-bearing）
    grep -q 'pane-only 禁止' "$CLD_PROMPT_FILE"               # pane-only 禁止（決定情報を pane に滞留させない）
    grep -q '既に needs-user の bead へ再 pause' "$CLD_PROMPT_FILE"   # 既 needs-user への再 pause も同様（無変化 transition の核心）
    grep -q '無変化 transition' "$CLD_PROMPT_FILE"            # re-pause を取りこぼす root cause の言及
}

@test "brief 恒久注入（bead-append 規律／no-beads・orch-edv T1）: no-beads 変種は『最終出力で毎回明示』へ読み替えられる" {
    run_spawn_admin tn
    [ "$status" -eq 0 ]
    # no-beads は bead notes へ append できない＝pane 縮退ゆえ「最終出力で毎回明示」変種を pin。
    grep -q '最終出力で毎回明示' "$CLD_PROMPT_FILE"           # 新質問/報告/再 pause を最終出力で明示
    grep -q '再 pause のたびに最終出力で park' "$CLD_PROMPT_FILE"   # 再 pause のたびに park シグナル
    grep -q 'bead-append 規律の no-beads 変種' "$CLD_PROMPT_FILE"   # 出し分けの由来を pin
    # beads 専用の「bead の notes に append」は no-beads 変種の当該行には出ない（append 単語は no-beads では
    # 「append できない」文脈でのみ現れる＝beads 版の命令文と混同させない出し分けを弱く pin）。
    refute_grep -q '該当 bead の notes に append し updated_at を動かせ' "$CLD_PROMPT_FILE"
}

# ==============================================================================
# 機構強制（layer ③・orch-ce6）: 対話 tool 物理封鎖を cld-spawn へ渡す（layer ① scope guard を反転）
# ==============================================================================

@test "機構強制（layer ③・orch-ce6・既定）: 対話 tool 封鎖 --disallowed-tools AskUserQuestion,ExitPlanMode を cld-spawn 実行引数へ渡す" {
    # layer ①（orch-355）は文面のみだった。layer ③（本セル）で機構強制も着地: cld-spawn の起動引数に
    # --disallowed-tools と既定値が入る（cld→claude へ verbatim 1-argv 透過で対話 channel を物理封鎖）。
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    grep -q -- '--disallowed-tools' "$CLD_ARGS_FILE"                 # 起動引数にフラグ
    grep -qF 'AskUserQuestion,ExitPlanMode' "$CLD_ARGS_FILE"         # 既定値が verbatim 1-argv（カンマ結合＝claude が split）
    # フラグ自体は kickoff prompt に混ぜない（prompt は本文＝ブリーフのみ・フラグは cld-spawn の argv）。
    refute_grep -q -- '--disallowed-tools' "$CLD_PROMPT_FILE"
}

@test "機構強制（layer ③・no-beads 変種も封鎖）: .beads 無し admin も対話 tool を封鎖する（H5=全 unattended spawn）" {
    run_spawn_admin tn
    [ "$status" -eq 0 ]
    grep -q -- '--disallowed-tools' "$CLD_ARGS_FILE"
    grep -qF 'AskUserQuestion,ExitPlanMode' "$CLD_ARGS_FILE"
}

@test "機構強制（layer ③・override）: --disallowed-tools で封鎖 tool を上書きできる" {
    run_spawn_admin tb --disallowed-tools 'AskUserQuestion,ExitPlanMode,Bash'
    [ "$status" -eq 0 ]
    grep -qF 'AskUserQuestion,ExitPlanMode,Bash' "$CLD_ARGS_FILE"
}

@test "機構強制（layer ③・escape hatch）: --no-disallowed-tools で封鎖を無効化（人間直付き admin 用）" {
    run_spawn_admin tb --no-disallowed-tools
    [ "$status" -eq 0 ]
    refute_grep -q -- '--disallowed-tools' "$CLD_ARGS_FILE"                # フラグを渡さない＝AskUserQuestion 温存
}

@test "機構強制（layer ③・値検証）: --disallowed-tools に値なしは die（fail-loud）" {
    run_spawn_admin tb --disallowed-tools
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_PROMPT_FILE" ]                                       # 判定は cld-spawn 呼出以前
}

@test "機構強制（layer ③・dry-run 観測面）: dry-run の %q 出力に --disallowed-tools と block 行が載る" {
    run_spawn_admin tb --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"--disallowed-tools"* ]]
    [[ "$output" == *"物理封鎖"* ]]
}

# ==============================================================================
# spawn 直後 watch 常駐ヒント（orch-ce6・H3-ii）
# ==============================================================================

@test "watch 常駐ヒント（orch-ce6）: [ORCH-WATCH-RESIDENT] と admin 用 watch コマンド雛形を stderr へ emit する" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    [[ "$output" == *"ORCH-WATCH-RESIDENT"* ]]
    [[ "$output" == *"--watch --actor admin --foreign-repo"* ]]
    [[ "$output" == *"<bead-id>"* ]]                                  # bead-id は spawn 後に admin が作る＝雛形
    [[ "$output" == *"run_in_background"* ]]                          # 孤児 fork せず harness 追跡下に置く運用注記
}

@test "watch 常駐ヒント（orch-ce6・抑止）: --no-watch-hint で emit しない" {
    run_spawn_admin tb --no-watch-hint
    [ "$status" -eq 0 ]
    [[ "$output" != *"ORCH-WATCH-RESIDENT"* ]]
}

@test "brief 恒久注入（exec・user prompt 無しでも注入）: kickoff が無くてもブリーフのみ inject される（恒久）" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    [ -s "$CLD_PROMPT_FILE" ]                                 # prompt 非空＝恒久注入（旧実装は no-prompt で空だった）
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    refute_grep -q '人間/admin からの kickoff 指示' "$CLD_PROMPT_FILE"   # user 指示の見出しは無い（ブリーフのみ）
}

@test "brief 恒久注入（exec・user prompt 併置）: user kickoff はブリーフの後に置かれる（discipline が frame）" {
    run_spawn_admin tb -- "orch-xyz の gate をやってくれ"
    [ "$status" -eq 0 ]
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    grep -q '人間/admin からの kickoff 指示' "$CLD_PROMPT_FILE"
    grep -q 'orch-xyz の gate をやってくれ' "$CLD_PROMPT_FILE"
    # 順序: ブリーフ（sentinel）が user 指示より前にある（ブリーフ → user の併置）
    local sent_line user_line
    sent_line=$(grep -n 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE" | head -1 | cut -d: -f1)
    user_line=$(grep -n 'orch-xyz の gate' "$CLD_PROMPT_FILE" | head -1 | cut -d: -f1)
    [ "$sent_line" -lt "$user_line" ]
}

# ==============================================================================
# no-beads 変種: 終端宣言 bead を作れない project は「最終出力で明示」変種を注入する
# ==============================================================================

@test "brief 恒久注入（no-beads 変種）: .beads 無し project は『台帳を持たない/最終出力で明示』変種を注入する" {
    run_spawn_admin tn
    [ "$status" -eq 0 ]
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    grep -q '台帳を持たない' "$CLD_PROMPT_FILE"
    grep -q '最終出力で明示' "$CLD_PROMPT_FILE"
    # beads 専用の「着手したら自台帳…終端宣言 bead を作り」は no-beads 変種には出ない（出し分けを pin）
    refute_grep -q '着手したら自台帳' "$CLD_PROMPT_FILE"
}

@test "brief 恒久注入（no-beads・dry-run の beads 判定）: no-beads と判定され announce も出る" {
    run_spawn_admin tn --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"no-beads"* ]]
    [[ "$output" == *"ORCH-WATCH-CONTRACT"* ]]
}

# ==============================================================================
# 健全性
# ==============================================================================

@test "未知 project は die（注入以前に fail-loud）" {
    run_spawn_admin nonexistent-proj
    [ "$status" -ne 0 ]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "self-ledger footgun（orch-1r7）: dolt_database=orch の project は spawn 拒否で die（自 repo に 2人目 admin を建てない）" {
    run_spawn_admin self --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"dolt_database=orch"* ]] || [[ "$output" == *"自台帳"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]   # 判定は spawn/dry-run 出力以前＝cld-spawn を呼ばない
}

@test "self-ledger footgun（orch-1r7）: metadata に dolt_database 欠落は die しない（orch 肯定確認時のみ fail-loud）" {
    # tb は .beads あるが metadata.json 無し＝orch と確証できない → 既存どおり dry-run 成功（fail-open 側）。
    run_spawn_admin tb --dry-run
    [ "$status" -eq 0 ]
}

@test "bash -n（構文）が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

# ==============================================================================
# project 解決 seam（orch-70i / engine seam）: env 未設定経路（ORCH_ADMIN_PROJECTS 無し）の hermetic 検証
#   上記 22 テストは ORCH_ADMIN_PROJECTS override（run_spawn_admin）で走り registry overlay 実路を
#   一切 exercise しない＝本契約（private registry overlay を存在時のみ source + self-entry scriptorium は
#   ORCH_ANCHOR set 時のみ append + 未供給は fail-closed）に対し vacuous。engine tree は実名 registry を
#   同梱しないため、以下はテスト自身が **合成 registry fixture**（lib/orch-projects.sh に DEFAULT_PROJECTS=
#   ("projalpha=..." "projbeta=...") を定義）を sandbox へ生成し、その合成 entry が known list に載る＝registry
#   overlay を source した証跡とする（旧 実名 registry oracle の hermetic 置換）。self-entry scriptorium は
#   ORCH_ANCHOR=<fixture path> 供給時のみ append される新契約として pin し、空/未定義/未供給の fail-closed と
#   mutation（overlay source 行を殺す / scriptorium append を落とす）の RED flip も実証する（orch-70i acceptance 1〜4）。
# ==============================================================================

# 合成 registry fixture を書く（engine tree は実名 registry lib を同梱しない＝テストが自前で生成する）。
#   $1 = lib/orch-projects.sh を置く lib dir。DEFAULT_PROJECTS に projalpha/projbeta の 2 合成 entry を定義し、
#   その dir は fixture temp（実在＝name→cwd 解決 smoke が通る）。合成 entry の known list 掲載を registry
#   overlay を source した証跡（旧 hardcode drift で欠落したエントリ）の hermetic 代替 oracle として使う。
_write_registry_fixture() {
    local libdir="$1"
    mkdir -p "$libdir" "$TEST_TMPDIR/reg-projalpha" "$TEST_TMPDIR/reg-projbeta"
    cat > "$libdir/orch-projects.sh" <<EOF
DEFAULT_PROJECTS=("projalpha=$TEST_TMPDIR/reg-projalpha" "projbeta=$TEST_TMPDIR/reg-projbeta")
EOF
}

# registry sandbox: 実 script を隣（$sb）へ複製し、合成 registry fixture を $sb/lib へ生成して BASH_SOURCE
#   相対解決（overlay を存在時のみ source）を成立させる。$1 = sandbox dir。script パスを SB_SCRIPT に置く。
_build_registry_sandbox() {
    local sb="$1"
    mkdir -p "$sb/lib"
    cp "$SCRIPT" "$sb/orch-spawn-admin.sh"
    _write_registry_fixture "$sb/lib"
    SB_SCRIPT="$sb/orch-spawn-admin.sh"
}

# mutant sandbox: 実 script を sed 変異させ、合成 registry fixture を隣（$sb/lib）へ生成して BASH_SOURCE 相対解決を
#   成立させる（旧: 実 lib を cp していたが engine tree は実名 registry を同梱しない＝合成 fixture を生成する）。
#   $1 = sed 変異式 / $2 = sandbox dir。変異後 script パスをグローバル MUT_SCRIPT に置く。
_build_mutant() {
    local sedexpr="$1" sb="$2"
    mkdir -p "$sb/lib"
    sed "$sedexpr" "$SCRIPT" > "$sb/orch-spawn-admin.sh"
    _write_registry_fixture "$sb/lib"
    MUT_SCRIPT="$sb/orch-spawn-admin.sh"
}

@test "(SSOT-i) env 未設定経路: unknown-project の known list に 合成 registry entry（projalpha=overlay source 証跡）と scriptorium（ORCH_ANCHOR append）が載る（dir 非依存）" {
    # unknown-project エラーは cwd 実在検査より前＝実 dir 非依存 oracle。projalpha は合成 registry overlay のみに
    # 在るエントリ＝これが known list に載るのは overlay を source した証跡（旧 実名 registry oracle の hermetic 代替）。
    # scriptorium は ORCH_ANCHOR set 時のみ append される新契約ゆえ ORCH_ANCHOR=<fixture path> を供給して append を pin。
    local sb="$TEST_TMPDIR/reg-ssoti"
    _build_registry_sandbox "$sb"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" ORCH_ANCHOR="$TEST_TMPDIR/anchor-ssoti" \
        run bash "$SB_SCRIPT" bogus-xyz-orch70i --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown project"* ]]
    [[ "$output" == *"projalpha"* ]]          # ★overlay source の証跡（合成 registry のみに在る entry）
    [[ "$output" == *"scriptorium"* ]]        # ★self-entry append の証跡（ORCH_ANCHOR set 時のみ）
    [ ! -s "$CLD_PROMPT_FILE" ]               # 判定は cld-spawn 呼出以前
}

@test "(SSOT-i-smoke) env 未設定経路: 合成 registry の実在 project は overlay 解決し dry-run が cld-spawn コマンドを print（hermetic・dir-exists）" {
    # 旧: $HOME 実 dir 依存 smoke。engine tree では実名 registry を持たないため、合成 registry fixture の実在 dir
    # （fixture temp）を name→cwd 解決し footgun 通過して dry-run print へ到達する経路を hermetic に pin する。
    local sb="$TEST_TMPDIR/reg-smoke"
    _build_registry_sandbox "$sb"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE=1 \
        run bash "$SB_SCRIPT" projalpha --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"DRY-RUN: would spawn"* ]]   # orch-k660: spawn は payload なし＝メッセージ文言
    [[ "$output" == *"projalpha"* ]]
}

@test "(SSOT-ii) env 未設定経路: scriptorium 指定は self-ledger footgun die（unknown project でなく dolt_database=orch）" {
    # ORCH_ANCHOR set 時のみ scriptorium=$ORCH_ANCHOR が append される新契約。ORCH_ANCHOR を自台帳 fixture へ向け、
    # scriptorium が known（append 温存）でありかつ dolt_database=orch で footgun die することを同時に pin
    # （『unknown project』でないことが append の証跡）。footgun die は slate gate より前ゆえ lib 追加不要。
    local anchor="$TEST_TMPDIR/anchor-self"
    mkdir -p "$anchor/.beads"
    printf '{"dolt_database":"orch"}\n' > "$anchor/.beads/metadata.json"
    local sb="$TEST_TMPDIR/reg-ssotii"
    _build_registry_sandbox "$sb"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" ORCH_ANCHOR="$anchor" \
    CLD_ARGS_FILE="$CLD_ARGS_FILE" CLD_PROMPT_FILE="$CLD_PROMPT_FILE" \
        run bash "$SB_SCRIPT" scriptorium --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"dolt_database=orch"* ]] || [[ "$output" == *"自台帳"* ]]   # footgun 文言（unknown でない）
    [[ "$output" != *"unknown project"* ]]    # ★scriptorium は known＝append 温存の証跡
    [ ! -s "$CLD_PROMPT_FILE" ]               # footgun は cld-spawn 呼出以前
}

@test "(SSOT-mutA) mutation 非vacuity: overlay source 行を殺すと DEFAULT_PROJECTS 未定義→fail-closed die（projalpha 非列挙・degraded しない）" {
    local sb="$TEST_TMPDIR/mut-a"
    # source 行は `if [ -f ... ]; then` ブロック内で 4-space インデント＝delete すると空 if-body で syntax error に
    #   なるため no-op（`:`）へ置換して mutate する（インデント温存・block 非空維持）。
    _build_mutant 's|^\( *\)source "\$_ORCH_LIB_DIR/orch-projects\.sh"$|\1: # mutated overlay source removed|' "$sb"
    # 非vacuity: 元 script に source 行が在り、mutant からは消えている。
    grep -q 'source "\$_ORCH_LIB_DIR/orch-projects.sh"' "$SCRIPT"
    refute_grep -q 'source "\$_ORCH_LIB_DIR/orch-projects.sh"' "$MUT_SCRIPT"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" run bash "$MUT_SCRIPT" bogus-xyz-orch70i --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"未供給"* ]]                   # fail-closed die（source を殺すと overlay 由来が消え未定義になる）
    [[ "$output" != *"projalpha"* ]]                # ★RED flip: (SSOT-i) の oracle（overlay source 証跡）が消える
    [[ "$output" != *"DRY-RUN: would spawn"* ]]     # ★degraded spawn へ落ちない
}

@test "(SSOT-mutB) mutation 非vacuity: scriptorium append を落とすと footgun sentinel が消え scriptorium が unknown project になる" {
    local sb="$TEST_TMPDIR/mut-b"
    # 新 append 行は if [ -n "${ORCH_ANCHOR:-}" ] ブロック内で 4-space インデント＝delete すると空 if-body で syntax
    #   error になるため no-op（`:`）へ置換して mutate する（インデント温存・block 非空維持・行頭 anchor は外す）。
    _build_mutant 's|^\( *\)DEFAULT_PROJECTS+=("scriptorium=.*|\1: # mutated scriptorium append removed|' "$sb"
    # 非vacuity: 元 script に append 行が在り、mutant からは消えている。
    grep -q 'DEFAULT_PROJECTS+=("scriptorium=' "$SCRIPT"
    refute_grep -q 'DEFAULT_PROJECTS+=("scriptorium=' "$MUT_SCRIPT"
    # ORCH_ANCHOR を自台帳 fixture へ向けても、append 欠落で scriptorium は known でなくなる（合成 registry の
    # projalpha/projbeta は残るゆえ fail-closed には落ちず『unknown project』へ flip する）。
    local anchor="$TEST_TMPDIR/anchor-mutb"
    mkdir -p "$anchor/.beads"
    printf '{"dolt_database":"orch"}\n' > "$anchor/.beads/metadata.json"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" ORCH_ANCHOR="$anchor" \
        run bash "$MUT_SCRIPT" scriptorium --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"unknown project"* ]]          # ★RED flip: (SSOT-ii) の footgun でなく unknown（append sentinel 消失）
    [[ "$output" != *"dolt_database=orch"* ]]       # footgun die へ到達しない
}

@test "(SSOT-libabsent) 共有 lib 不在かつ env 未供給は fail-closed die（hardcode fallback で degraded spawn しない）" {
    # lib/ を置かず env（ORCH_ADMIN_PROJECTS）も与えない sandbox＝registry 未供給。overlay は存在時のみ source する
    # 契約ゆえ「lib not found」die はもう出ず、env も overlay も無い未供給として fail-closed die する（新契約 pin）。
    local sb="$TEST_TMPDIR/nolib"
    mkdir -p "$sb"
    cp "$SCRIPT" "$sb/orch-spawn-admin.sh"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" run bash "$sb/orch-spawn-admin.sh" projalpha --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"未供給"* ]]
}

@test "(SSOT-emptylib) lib は present だが DEFAULT_PROJECTS 空/未定義は fail-closed die（acceptance 3）" {
    # lib は在るが空配列を定義＝source 成功でも空リスト。scriptorium append の前に fail-closed die し degraded 継続しない。
    local sb="$TEST_TMPDIR/emptylib"
    mkdir -p "$sb/lib"
    cp "$SCRIPT" "$sb/orch-spawn-admin.sh"
    printf 'DEFAULT_PROJECTS=()\n' > "$sb/lib/orch-projects.sh"
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" run bash "$sb/orch-spawn-admin.sh" projalpha --dry-run
    [ "$status" -ne 0 ]
    [[ "$output" == *"未供給"* ]]
}

# ==============================================================================
# account / config-dir 選択（orch-dgo・F1〜F13）
#   cld-spawn stub が capture した --env-file 内容（$CLD_ENVFILE_FILE）で config-dir 追随を検証（F8）。
#   selector は $SELECTOR_STUB へ差し替え（SCRIBE_USAGE_JSON でなく TSV 直吐き stub＝決定的・F8）。
# ==============================================================================

@test "(ACC-auto-pick) --account auto: 残量 maximin 上位 account の config dir を env-file へ export（F1/F2/F9）" {
    # 上位=acct-a(適格)・default(適格) の順。top-by-usage=acct-a を採用し <base>/acct-a を注入する。
    write_selector 0 \
        $'acct-a\t1\t80\t80\t85\t20\t15\t-\t-\teligible' \
        $'default\t1\t60\t60\t70\t40\t30\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto
    [ "$status" -eq 0 ]
    grep -qF "export CLAUDE_CONFIG_DIR=$ORCH_ACCOUNTS_BASE/acct-a" "$CLD_ENVFILE_FILE"   # ★top-by-usage を注入
    grep -q -- '--env-file' "$CLD_ARGS_FILE"                                              # cld-spawn argv に --env-file
    [[ "$output" == *"auto → 'acct-a' を採用"* ]]                                         # 採用ログ（stderr）
}

@test "(ACC-auto-default-top) --account auto: top が default なら unset を注入（~/.claude・facet④）" {
    # default が maximin 上位＝~/.claude（unset 意味論）へ写像。export CLAUDE_CONFIG_DIR は出ない。
    write_selector 0 \
        $'default\t1\t90\t90\t95\t10\t5\t-\t-\teligible' \
        $'acct-a\t1\t60\t60\t70\t40\t30\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto
    [ "$status" -eq 0 ]
    grep -qF 'unset CLAUDE_CONFIG_DIR' "$CLD_ENVFILE_FILE"
    refute_grep -q 'export CLAUDE_CONFIG_DIR=' "$CLD_ENVFILE_FILE"
}

@test "(ACC-auto-eligible0) --account auto: 適格0件は fail-loud die（default 継承へ silent 落ちしない・F7）" {
    # 全 account eligible=0（weekly 枯渇）→ die。cld-spawn を呼ばない（env-file capture も空）。
    write_selector 0 \
        $'acct-a\t0\t\t\t\t100\t100\t-\t-\tweekly-exhausted' \
        $'default\t0\t\t\t\t100\t100\t-\t-\tweekly-exhausted'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"適格アカウントが 0 件"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]                # cld-spawn 未呼出
    [ ! -s "$CLD_ENVFILE_FILE" ]
}

@test "(ACC-auto-absent) --account auto: selector 不在は fail-loud die（F2）" {
    # ORCH_ACCOUNT_SELECT を存在しない path へ（setup 既定の no-such-selector をそのまま使う）。
    run_spawn_admin tb --account auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"selector が必要"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-auto-apifail) --account auto: selector API 故障(exit 3) は fail-loud die（F7）" {
    write_selector 3        # stdout 空・exit 3（API 故障）
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"claude-usage が読めません"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-explicit) --account <label>: <base>/<label> を env-file へ export（F12）" {
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 0 ]
    grep -qF "export CLAUDE_CONFIG_DIR=$ORCH_ACCOUNTS_BASE/acct-a" "$CLD_ENVFILE_FILE"
    [[ "$output" == *"account:acct-a"* ]]     # announce 行
}

@test "(ACC-explicit-badlabel) --account の不正 label（path traversal 系）は exit 2（F12）" {
    run_spawn_admin tb --account 'a/b'
    [ "$status" -eq 2 ]
    [ ! -s "$CLD_PROMPT_FILE" ]
    run_spawn_admin tb --account '..'
    [ "$status" -eq 2 ]
}

@test "(ACC-explicit-depleted-warn) 明示 --account が weekly 枯渇でも spawn 継続 + loud 警告（F7 teeth）" {
    # acct-a が eligible=0（枯渇）。明示指定ゆえ die せず警告して継続する（代替を殺さない）。
    write_selector 0 \
        $'acct-a\t0\t\t\t\t100\t100\t-\t-\tweekly-exhausted' \
        $'default\t1\t90\t90\t95\t10\t5\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account acct-a
    [ "$status" -eq 0 ]                                                         # spawn 継続
    [[ "$output" == *"weekly 枯渇"* ]]                                          # loud 警告（stderr）
    grep -qF "export CLAUDE_CONFIG_DIR=$ORCH_ACCOUNTS_BASE/acct-a" "$CLD_ENVFILE_FILE"   # 指定 account を注入
}

@test "(ACC-default-depleted-warn) 未指定 default が weekly 枯渇なら loud 警告 + spawn 継続（acceptance(3)/F7）" {
    # default account が eligible=0＝silent 凍結の再発リスクを loud 警告するが spawn は継続（unset 注入）。
    write_selector 0 \
        $'default\t0\t\t\t\t100\t100\t-\t-\tweekly-exhausted' \
        $'acct-a\t1\t90\t90\t95\t10\t5\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb
    [ "$status" -eq 0 ]
    [[ "$output" == *"silent 凍結の再発リスク"* ]]
    grep -qF 'unset CLAUDE_CONFIG_DIR' "$CLD_ENVFILE_FILE"   # 従来挙動（unset）は保つ
}

@test "(ACC-default-unset) 未指定 default + selector 不在: 従来挙動＝unset を注入し probe skip（F5）" {
    # setup 既定の no-such-selector ゆえ probe skip。unset を注入して spawn 継続。
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    grep -qF 'unset CLAUDE_CONFIG_DIR' "$CLD_ENVFILE_FILE"
    refute_grep -q 'export CLAUDE_CONFIG_DIR=' "$CLD_ENVFILE_FILE"
}

@test "(ACC-envfile-chain) env-file は既定 env（CLD_ENV_FILE）を chain-source してから config-dir を後勝ち注入（F1）" {
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 0 ]
    # 1 行目=source（chain・|| true）→ 2 行目=config-dir（後勝ち）。source が config より前にある。
    grep -qF "source $CLD_ENV_FILE" "$CLD_ENVFILE_FILE"
    local src_line cfg_line
    src_line=$(grep -n "source $CLD_ENV_FILE" "$CLD_ENVFILE_FILE" | head -1 | cut -d: -f1)
    cfg_line=$(grep -n 'CLAUDE_CONFIG_DIR' "$CLD_ENVFILE_FILE" | head -1 | cut -d: -f1)
    [ "$src_line" -lt "$cfg_line" ]
}

@test "(ACC-F8-argv-path) --env-file の path が cld-spawn argv に届き実在ファイルを指す（F8）" {
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 0 ]
    grep -q -- '--env-file' "$CLD_ARGS_FILE"
    [ -s "$CLD_ENVFILE_PATH" ]                       # stub が path を capture した
    # env-file の path が prompt に混ざらない（フラグ/path は argv・prompt は本文）
    refute_grep -q -- '--env-file' "$CLD_PROMPT_FILE"
}

@test "(ACC-F10-regress-disallowed) --account 指定でも --disallowed-tools 既定が cld-spawn argv に届く（F10）" {
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 0 ]
    grep -q -- '--disallowed-tools' "$CLD_ARGS_FILE"
    grep -qF 'AskUserQuestion,ExitPlanMode' "$CLD_ARGS_FILE"
}

@test "(ACC-F10-regress-model) --account 指定でも --model が cld-spawn argv に届く（F10）" {
    run_spawn_admin tb --account acct-a --model sonnet
    [ "$status" -eq 0 ]
    grep -q -- '--model' "$CLD_ARGS_FILE"
    grep -qxF 'ARG	sonnet' "$CLD_ARGS_FILE" || grep -qF 'sonnet' "$CLD_ARGS_FILE"
}

@test "(ACC-F10-regress-footgun) self-ledger footgun は --account auto を付けても発火する（F10）" {
    # self（dolt_database=orch）は account option の有無に依らず footgun die（account 解決より前に弾く）。
    write_selector 0 $'acct-a\t1\t80\t80\t85\t20\t15\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin self --account auto
    [ "$status" -ne 0 ]
    [[ "$output" == *"dolt_database=orch"* ]] || [[ "$output" == *"自台帳"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-F3-no-bd-write) --account auto spawn は foreign 台帳へ bd write しない（read は許可・orch-vswk narrow）" {
    # gate-2 裁定（user ratify 2026-07-16）: slate interlock（orch-vswk）は open slate を bd で **read** する
    #   （read-only）ため、旧「bd/bdw を一切呼ばない」を「bd/bdw の **write** ゼロ（自台帳 orch の read-only は許可）」へ
    #   narrow する。元契約の意図（spawn-admin が台帳を書き換えない保証）は write-verb ゼロ assert で保持し、foreign
    #   write 禁止 moat は不変。★slate gate を実 exercise（bypass=0）し、bd stub が read verb（list/show）だけで
    #   呼ばれ write verb がゼロであることを pin する（narrow の意味を positive/negative 双方で確定）。
    local marker="$TEST_TMPDIR/bd-called.txt"; : > "$marker"
    for t in bd bdw; do
        cat > "$BIN/$t" <<STUB
#!/usr/bin/env bash
printf 'CALLED %s %s\n' "$t" "\$*" >> "$marker"
# slate interlock の read を hermetic に満たす: list→open slate 1件 / show→tb を members に持つ slate。
case " \$* " in
  *" list "*) printf '%s' '[{"id":"orch-slate1"}]' ;;
  *" show "*) printf '%s' '[{"id":"orch-slate1","notes":"[ORCH-SLATE v1] members: tb, tn"}]' ;;
esac
exit 0
STUB
        chmod +x "$BIN/$t"
    done
    # foreign .beads 内容の before スナップショット（write されないことを二重に pin）。
    local before after
    before=$(ls -a "$BEADS_DIR/.beads" 2>/dev/null | sort)
    write_selector 0 $'acct-a\t1\t80\t80\t85\t20\t15\t-\t-\teligible'
    PATH="$BIN:$PATH" ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" \
      ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE=0 \
      ORCH_SPAWN_ADMIN_SCRIPTORIUM="$TEST_TMPDIR/slate-anchor" \
      ORCH_SPAWN_ADMIN_BD="$BIN/bd" \
      run_spawn_admin tb --account auto
    [ "$status" -eq 0 ]
    # ★read-verb allowlist（denylist 反転・orch-vswk self-review）: すべての CALLED bd|bdw 行が read-only verb
    #   （list/show）のみであることを assert する。旧 denylist（既知 write verb を列挙）は reopen/delete/assign/
    #   ready/block/sql/import/comment 等の未知/将来 write verb を取りこぼし false-green するため（write-isolation
    #   の不可侵の核の回帰検知が fail-open）、『read 以外ゼロ』を allowlist で airtight に pin する。
    local total_calls read_calls
    total_calls=$(grep -cE '^CALLED (bd|bdw) ' "$marker" || true)
    read_calls=$(grep -cE '^CALLED (bd|bdw) .*[[:space:]](list|show)([[:space:]]|$)' "$marker" || true)
    [ "$total_calls" -ge 1 ]                                 # slate read が実際に走った（vacuous でない・read は許可）
    [ "$total_calls" -eq "$read_calls" ]                     # 全 call が read-only verb（list/show）のみ＝write（既知/未知）ゼロ
    after=$(ls -a "$BEADS_DIR/.beads" 2>/dev/null | sort)
    [ "$before" = "$after" ]                                 # foreign .beads 不変
}

@test "(ACC-dryrun) --account auto --dry-run: 採用 account の env-file 内容を plan 表示（side-effect なし）" {
    write_selector 0 \
        $'acct-a\t1\t80\t80\t85\t20\t15\t-\t-\teligible' \
        $'default\t1\t60\t60\t70\t40\t30\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"--env-file"* ]]
    [[ "$output" == *"export CLAUDE_CONFIG_DIR=$ORCH_ACCOUNTS_BASE/acct-a"* ]]   # plan に採用 config dir
    [ ! -s "$CLD_PROMPT_FILE" ]                                                  # dry-run は cld-spawn 未呼出
}

@test "(ACC-value-missing) --account に値なしは exit 2（fail-loud・cld-spawn 呼出以前）" {
    run_spawn_admin tb --account
    [ "$status" -eq 2 ]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-value-optionlike) --account の直後が option 形は値欠落として exit 2" {
    run_spawn_admin tb --account --dry-run
    [ "$status" -eq 2 ]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-preflight-missing-dir) 明示 --account の config-dir が不在なら fail-loud die（silent 凍結の別変種を封じる・self-review major）" {
    # acct-typo(typo) の config-dir は存在しない（setup は acct-a のみ mkdir）→ 実在検査で exit 1・cld-spawn 未呼出。
    run_spawn_admin tb --account acct-typo
    [ "$status" -eq 1 ]
    [[ "$output" == *"config-dir が存在しません"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]                # cld-spawn を起動しない（無人 window の login TUI hang を未然に断つ）
    [ ! -s "$CLD_ENVFILE_FILE" ]
}

@test "(ACC-preflight-auto-missing-dir) auto 採用 dir が不在でも fail-loud die（採用後の実在検査・self-review major）" {
    # selector が eligible=1 で挙げた ghost account の config-dir が実在しない → 採用後の preflight で exit 1。
    write_selector 0 $'ghost\t1\t80\t80\t85\t20\t15\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto
    [ "$status" -eq 1 ]
    [[ "$output" == *"config-dir が存在しません"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-preflight-dryrun-catches) --dry-run でも不在 config-dir を早期 surface（read-only 検査・side-effect ゼロ）" {
    # dry-run でも実在検査を走らせ typo を plan 前に fail-loud する（cld-spawn 未呼出・env-file 未作成）。
    run_spawn_admin tb --account acct-typo --dry-run
    [ "$status" -eq 1 ]
    [[ "$output" == *"config-dir が存在しません"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-preflight-no-credentials) dir 実在でも .credentials.json 不在なら fail-loud die（未 login→sign-in hang・self-review major）" {
    # acct-a は setup で健全化済み。credentials だけ剥がすと (b) で die＝login TUI hang（silent 凍結の別変種）を封じる。
    rm -f "$ORCH_ACCOUNTS_BASE/acct-a/.credentials.json"
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 1 ]
    [[ "$output" == *".credentials.json が無い"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]                # 無防備/hang admin を起動しない
    [ ! -s "$CLD_ENVFILE_FILE" ]
}

@test "(ACC-preflight-not-onboarded) hasCompletedOnboarding!=true なら fail-loud die（theme 選択 TUI hang・self-review major）" {
    # onboarding 未完了 dir 注入は claude 起動が theme/sign-in で hang する（doobidoo 82e2fc50）。
    printf '{"hasCompletedOnboarding": false}\n' > "$ORCH_ACCOUNTS_BASE/acct-a/.claude.json"
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 1 ]
    [[ "$output" == *"hasCompletedOnboarding"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

@test "(ACC-preflight-plugin-missing) guard plugin 未 enable なら fail-loud die（無防備 admin=write-isolation fail-open を封じる・self-review major）" {
    # beads-bdw plugin を剥がすと (d) で die＝bd-write-guard 等が黙って無効化された無防備 admin を起こさない。
    rm -rf "$ORCH_ACCOUNTS_BASE/acct-a/plugins/beads-bdw"
    run_spawn_admin tb --account acct-a
    [ "$status" -eq 1 ]
    [[ "$output" == *"plugin 'beads-bdw' が config-dir で enable されていません"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]                # 無防備 admin を起動しない（write-isolation 保全）
    [ ! -s "$CLD_ENVFILE_FILE" ]
}

@test "(ACC-preflight-auto-plugin-missing) auto 採用 dir が plugin 欠落なら fail-loud die（eligible=1 でも (d) は独立・self-review major）" {
    # selector eligible=1（認証健全）でも plugin enable は認証独立ゆえ欠落しうる。auto でも無防備 admin を封じる。
    make_healthy_cfgdir "$ORCH_ACCOUNTS_BASE/acct2"
    rm -rf "$ORCH_ACCOUNTS_BASE/acct2/plugins/cmdtokens"
    write_selector 0 $'acct2\t1\t80\t80\t85\t20\t15\t-\t-\teligible'
    ORCH_ACCOUNT_SELECT="$SELECTOR_STUB" run_spawn_admin tb --account auto
    [ "$status" -eq 1 ]
    [[ "$output" == *"plugin 'cmdtokens' が config-dir で enable されていません"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]
}

# ==============================================================================
# orch-k660 → orch-i7ft: admin spawn 既定（model=opus[1m]+xhigh / /effort ultracode / boot-race 照合）
#   検証方式: (a) 既定 model/effort を spawn 呼出 argv（CLD_ARGS_FILE）で pin / (b) 既定の非空虚（mutation）と
#   --model 明示（優先 / fable 締め出しなし）と preflight 機構の不在（durable negative teeth）/ (c)(d)
#   session-state stub で turn-start 照合の boot-race 両枝 + inject 順序。exec 経路の hermeticity は
#   run_spawn_admin の seam（SESSION_STATE=processing stub / VERIFY_SETTLE=0）が担保する。
#   ★orch-i7ft（user 裁定 2026-07-25）: 既定 model が fable → opus[1m] へ切り替わり、fable preflight fallback
#     機構が死にコードとして撤去された。これに伴い (b) の旧 3 本（K660-b-fallback / K660-b-available /
#     K660-b-mut＝preflight 両枝と fallback 代入の mutation）を撤去し、新既定の teeth へ差し替えた（teeth 純減を
#     作らない）: I7FT-b-fable-explicit（裁定 1 の締め出さない fence）/ I7FT-b-mut-default（既定 argv pin の
#     mutation 非空虚）/ I7FT-b-no-preflight-symbols（撤去 4 識別子の durable negative teeth）+ 追加 1 本
#     I7FT-plan-no-fable（--no-effort-inject 枝の dry-run 出力に残存文言が出ない）。
#   ★人間可視 prose の残存文言 teeth は **4 modality** を被覆する（旧既定文言を実際に抱えていた surface の数）:
#     1/4 既定 dry-run の model 行（K660-dryrun-plan）/ 2/4 --no-effort-inject の ultra 行（I7FT-plan-no-fable）
#     3/4 fail-open stderr（K660-c-effort-failopen）/ 4/4 MODEL_EXPLICIT 枝の model 行（I7FT-b-fable-explicit）。
#   ★docs drift teeth（K660-e-docs 相当）は engine copy には移植しない（本 file header と末尾の (K660-e-docs)
#     削除注記のとおり private 配備層 residual bats の担当＝engine tree に CLAUDE.md / docs/ は無い）。
# ==============================================================================

# 指定した state を echo する session-state stub を作り path を返す（boot-race 等の差替用）。
_make_state_stub() {
    local st="$1" p="$BIN/session-state-$st"
    cat > "$p" <<STUB
#!/usr/bin/env bash
echo $st
STUB
    chmod +x "$p"
    printf '%s' "$p"
}

@test "(I7FT-a-model-default) 既定 spawn（--model 無指定）が opus[1m] を cld へ verbatim で渡す（acceptance 既定 argv pin・orch-i7ft）" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    # spawn 呼出 argv に --model opus[1m] が verbatim で載る（既定 fable→opus[1m] の改訂・user 裁定 2026-07-25）。
    grep -Fq $'ARG\t--model' "$CLD_ARGS_FILE"
    # ★行完全一致（-Fx）が load-bearing: -F のみだと $'ARG\topus' が "ARG<TAB>opus[1m]" 行にも部分一致して
    #   「素の opus へ退行した」場合と弁別できない（実測）。値 assert は必ず -Fx で行う。
    grep -Fxq $'ARG\topus[1m]' "$CLD_ARGS_FILE"
    refute_grep -Fxq $'ARG\tfable' "$CLD_ARGS_FILE"   # 旧既定 fable はもう出ない
    refute_grep -Fxq $'ARG\topus' "$CLD_ARGS_FILE"    # 素の opus（1M でない）へ落ちてもいない
}

@test "(K660-a-effort-xhigh) 既定 spawn が --effort xhigh を cld へ明示注入する（acceptance a・leg1・ambient 非依存）" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    grep -Fq $'ARG\t--effort' "$CLD_ARGS_FILE"
    grep -Fq $'ARG\txhigh' "$CLD_ARGS_FILE"
}

@test "(K660-a-effort-override) --effort で effort を上書きできる（xhigh 既定の override）" {
    run_spawn_admin tb --effort max
    [ "$status" -eq 0 ]
    grep -Fq $'ARG\tmax' "$CLD_ARGS_FILE"
    refute_grep -Fxq $'ARG\txhigh' "$CLD_ARGS_FILE"
}

@test "(I7FT-b-fable-explicit) --model fable 明示は die せず argv へ verbatim 透過する（裁定 1: 既定から外すだけ＝締め出さない）" {
    # 裁定 1（user 2026-07-25）の durable fence: 既定は opus[1m] へ移すが fable 明示経路は残す（die させない）。
    # ★honest 注記: 現時点の実装には --model 値を検査/拒否する分岐が無く、この assert を **壊す実装が存在しない**
    #   ＝構造的に準空虚な fence である。「fable 受理機構を検証した」とは主張しない。将来 --model allowlist や
    #   「fable は既定から外したので拒否」の実装が入ったとき RED になる回帰線としてのみ意味を持つ。
    run_spawn_admin tb --model fable
    [ "$status" -eq 0 ]                                   # die しない
    grep -Fxq $'ARG\tfable' "$CLD_ARGS_FILE"              # verbatim 透過（行完全一致）
    refute_grep -Fxq $'ARG\topus[1m]' "$CLD_ARGS_FILE"    # 既定へ差し戻されていない（明示が優先）
    # ★modality 4/4（MODEL_EXPLICIT 枝の plan 行）: この行も旧既定文言「既定 fable / preflight / opus[1m]
    #   fallback は適用しない」を抱えていた人間可視 surface で、argv assert だけでは stale 文言の復活を捕捉
    #   できない（cell-quality gate round2 completeness-critic finding）。plan 行は dry-run/exec 共通で stdout
    #   へ出るため exec 経路のまま検査できる（--dry-run を足すと argv assert が壊れる＝cld-spawn を呼ばない）。
    local plan_model
    plan_model=$(printf '%s\n' "$output" | grep -E '^  model   :' || true)
    [ -n "$plan_model" ]                                  # 当該行を確かに拾えている（空虚でない）
    [[ "$plan_model" == *"--model 明示ゆえ既定より優先"* ]]
    [[ "$plan_model" != *"preflight"* ]]
    [[ "$plan_model" != *"fallback"* ]]
}

@test "(I7FT-b-no-preflight-symbols) fable preflight 機構の 4 識別子が script から消えている（durable negative teeth・acceptance grep 0 hit）" {
    # acceptance の判定式（記号レベル 0 hit・対象は scripts/orch-spawn-admin.sh のみ）を bats へ内在化する。
    #   撤去は「今回消した」だけでなく「再導入しない」ことが契約ゆえ、外部 grep でなく suite 内に pin する。
    #   否定 assert は必ず refute_grep（中間位置の `!` は無牙・本 suite header 参照）。
    #   ★vacuity 封じ: path を再構築せず setup 済みの $SCRIPT を使い、冒頭で実在と positive control を確かめる
    #     （refute_grep はファイル不在の grep rc=2 を「不在＝OK」に化けさせる＝実測 false-green の穴）。
    #   ★語としての 'fable' の 0 hit は要求しない（裁定 1 の説明・改訂履歴の帰属記述が残るのが正）。
    [ -f "$SCRIPT" ]                                               # 対象ファイルが実在する
    grep -Fq 'MODEL=' "$SCRIPT"                                    # positive control（grep が実際に中身を見ている）
    refute_grep -Fq 'fable_available' "$SCRIPT"                    # preflight 判定関数
    refute_grep -Fq 'FABLE_FALLBACK_MODEL' "$SCRIPT"               # fallback model 変数
    refute_grep -Fq 'ORCH_SPAWN_ADMIN_FABLE_PREFLIGHT' "$SCRIPT"   # 可否強制注入 seam
    refute_grep -Fq 'ORCH_SPAWN_CLAUDE_BIN' "$SCRIPT"              # preflight 専用 claude 実体 seam（道連れ撤去）
}

@test "(K660-b-explicit-precedence) --model 明示は既定より優先する（MODEL_EXPLICIT・不変の回帰 teeth）" {
    # ★orch-i7ft 注記: preflight 撤去により本 test は準 vacuous になった。旧形は「preflight=0（fable 不可）でも
    #   指定 model のまま」＝fallback 分岐を迂回することの証明だったが、いま迂回すべき分岐自体が存在しない。
    #   残す理由は MODEL_EXPLICIT が将来 model を上書きする分岐（新 fallback 等）が入ったときの回帰線として。
    run_spawn_admin tb --model sonnet
    [ "$status" -eq 0 ]
    grep -Fxq $'ARG\tsonnet' "$CLD_ARGS_FILE"
    refute_grep -Fxq $'ARG\topus[1m]' "$CLD_ARGS_FILE"    # 既定で上書きされていない
}

@test "(I7FT-b-mut-default) mutation 非vacuity: 既定 MODEL を fable へ変異させると既定 argv pin が RED flip する" {
    # SSOT-mut* / _build_mutant と同型: 実 script を sed 変異させ合成 registry fixture を隣へ生成（BASH_SOURCE
    #   相対解決を成立）。MODEL="opus[1m]" の代入を旧既定 MODEL="fable" へ戻す → I7FT-a-model-default の positive
    #   assert が消え negative assert が点灯する＝既定 argv pin が実装に依存している（空虚でない）ことの証明。
    # ★変異前後の存在 assert を必ず添える（sed が pattern 不一致で silent no-op 化する穴を塞ぐ・K660-b-mut 欠落分）。
    # ★-Fx（行完全一致）が load-bearing: -F のみだと trailing comment 付き行にも一致し、sed の ^...$ が
    #   no-op 化する穴を単独では塞げない（契約 TEETH 節の「変異前に対象 literal が -Fx で実在」）。
    grep -Fxq 'MODEL="opus[1m]"' "$SCRIPT"                         # 元 script に列 0 の bare 行として実在する
    _build_mutant 's/^MODEL="opus\[1m\]"$/MODEL="fable"/' "$BIN/mut-default-model"
    refute_grep -Fq 'MODEL="opus[1m]"' "$MUT_SCRIPT"               # mutant では消えている（sed が効いた）
    grep -Fq 'MODEL="fable"' "$MUT_SCRIPT"                         # 旧既定へ変異している
    ORCH_SPAWN_CLD="$BIN/cld-spawn-stub" \
    ORCH_ADMIN_PROJECTS="tb=$BEADS_DIR tn=$NOBEADS_DIR self=$SELF_DIR" \
    ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE=1 \
    ORCH_SPAWN_ADMIN_SESSION_STATE="$SESSION_STATE_STUB" \
    ORCH_SPAWN_ADMIN_VERIFY_SETTLE=0 \
    CLD_ARGS_FILE="$CLD_ARGS_FILE" CLD_PROMPT_FILE="$CLD_PROMPT_FILE" \
        run bash "$MUT_SCRIPT" tb
    [ "$status" -eq 0 ]
    grep -Fxq $'ARG\tfable' "$CLD_ARGS_FILE"                       # ★RED flip: 旧既定へ退行
    refute_grep -Fxq $'ARG\topus[1m]' "$CLD_ARGS_FILE"             # 新既定が消える＝pin が非空虚
}

@test "(K660-leg2-payloadless-spawn) spawn 呼出 argv に kickoff payload（-- / ブリーフ本文）が無い（leg2 中核不変条件の直接 pin・cell-quality gate minor#2）" {
    # leg2 の核: spawn 呼出は payload なし（window 起動のみ）・kickoff は spawn 後に --inject-existing で注入。
    #   回帰で `-- "$KICKOFF"` が spawn CMD へ再付与されても（inject と二重注入になっても）、他の K660 テストは
    #   CLD_PROMPT_FILE（inject 由来）を grep するだけで捕捉しない。spawn 呼出 argv（CLD_ARGS_FILE）に payload が
    #   現れないことを直接 assert する（payload-less spawn の非vacuity pin）。
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    refute_grep -q 'ORCH-WATCH-CONTRACT' "$CLD_ARGS_FILE"      # ブリーフ本文が spawn argv に無い（inject 経路のみ）
    refute_grep -Fxq $'ARG\t--' "$CLD_ARGS_FILE"               # post-`--` payload 区切りが spawn argv に無い
    refute_grep -q '/effort ultracode' "$CLD_ARGS_FILE"        # effort も inject 経路（spawn argv には無い）
    # 対の positive: kickoff/effort は inject 由来 CLD_PROMPT_FILE に在る（二重注入でなく単一 inject 経路の証跡）。
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    grep -Fq '/effort ultracode' "$CLD_PROMPT_FILE"
}

@test "(K660-c-effort-inject-order) /effort ultracode が kickoff の前に注入される（acceptance c・leg2・送達確認つき）" {
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    # CLD_PROMPT_FILE は inject 呼出の text を順に append する＝1 行目に /effort ultracode、後にブリーフ。
    grep -Fq '/effort ultracode' "$CLD_PROMPT_FILE"
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    local eff_line kick_line
    eff_line=$(grep -nF '/effort ultracode' "$CLD_PROMPT_FILE" | head -1 | cut -d: -f1)
    kick_line=$(grep -n 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE" | head -1 | cut -d: -f1)
    [ "$eff_line" -lt "$kick_line" ]                 # effort は kickoff より前
    [[ "$output" == *"/effort ultracode を注入しました（送達確認済み"* ]]
}

@test "(K660-c-no-effort-inject) --no-effort-inject は /effort ultracode を注入せず kickoff のみ（opt-out）" {
    run_spawn_admin tb --no-effort-inject
    [ "$status" -eq 0 ]
    refute_grep -Fq '/effort ultracode' "$CLD_PROMPT_FILE"   # effort 注入なし
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"     # kickoff は注入される
}

@test "(K660-c-effort-failopen) /effort ultracode の送達失敗は fail-open（admin 継続・exit 0）+ loud + kickoff 継続" {
    # cld-spawn stub を「/effort inject だけ失敗」変種へ差替（hazard-faithful）。spawn/kickoff は成功。
    local failstub="$BIN/cld-spawn-effortfail"
    cat > "$failstub" <<'STUB'
#!/usr/bin/env bash
_is_inject=0
for a in "$@"; do [ "$a" = "--inject-existing" ] && _is_inject=1; done
if [ "$_is_inject" -eq 1 ]; then
    case "${!#}" in
        */effort*) exit 1 ;;                                 # effort 注入は不受理
        *) printf '%s\n' "${!#}" >> "$CLD_PROMPT_FILE"; exit 0 ;;
    esac
fi
exit 0
STUB
    chmod +x "$failstub"
    ORCH_SPAWN_CLD="$failstub" \
    ORCH_ADMIN_PROJECTS="tb=$BEADS_DIR tn=$NOBEADS_DIR self=$SELF_DIR" \
    ORCH_SPAWN_ADMIN_SKIP_SLATE_GATE=1 \
    ORCH_SPAWN_ADMIN_SESSION_STATE="$SESSION_STATE_STUB" \
    ORCH_SPAWN_ADMIN_VERIFY_SETTLE=0 \
    CLD_ARGS_FILE="$CLD_ARGS_FILE" CLD_PROMPT_FILE="$CLD_PROMPT_FILE" \
        run bash "$SCRIPT" tb
    [ "$status" -eq 0 ]                                       # fail-open＝admin 稼働継続
    [[ "$output" == *"fail-open"* ]]                          # loud
    # orch-i7ft modality 3/4: fail-open stderr の文言も新既定へ改訂済み（旧「admin は fable+xhigh のまま稼働継続」
    #   を放置すると人間可視の実出力が新既定下で嘘を吐く）。当該枝を通った上で 'fable' 0 hit を pin する。
    [[ "$output" != *"fable"* ]]
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"          # kickoff は注入される
    refute_grep -Fq '/effort ultracode' "$CLD_PROMPT_FILE"         # effort は届かなかった（記録されない）
}

@test "(K660-d-bootrace) boot-race stub（session-state=input-waiting・splash 滞留）で偽 injected を返さず再送→fail-loud（acceptance d・orch-sm6p pin）" {
    # kickoff 注入後に turn が起動しない（input-waiting のまま）＝注入が boot 中に飲まれた状況を再現。
    local ss; ss=$(_make_state_stub input-waiting)
    ORCH_SPAWN_ADMIN_SESSION_STATE="$ss" \
    ORCH_SPAWN_ADMIN_VERIFY_ATTEMPTS=2 ORCH_SPAWN_ADMIN_RESEND_MAX=1 \
        run_spawn_admin tb
    [ "$status" -ne 0 ]                                       # 偽 injected を返さない（fail-loud）
    [[ "$output" == *"turn 起動を確認できません"* ]]          # boot-race 検知
    [[ "$output" == *"再送します"* ]]                         # 消失対策の再送
    [[ "$output" == *"kickoff の注入が確認できませんでした"* ]] # 最終 fail-loud
}

@test "(K660-d-turnstart-ok) turn 起動（session-state=processing）を positive-proof で確認して成功（両枝の起動枝）" {
    # 既定 stub（processing）で turn 起動を確認＝exit 0・fail-loud にならない。
    local ss; ss=$(_make_state_stub processing)
    ORCH_SPAWN_ADMIN_SESSION_STATE="$ss" run_spawn_admin tb
    [ "$status" -eq 0 ]
    grep -q 'ORCH-WATCH-CONTRACT' "$CLD_PROMPT_FILE"
    [[ "$output" != *"turn 起動を確認できません"* ]]
}

@test "(K660-d-state-unresolvable) session-state が判定不能（unknown）でも偽 injected を返さない（保守的 fail-loud）" {
    # session-state 不在/不能は入力欄空≠受理の短絡に落ちず未起動扱い（保守的）＝boot-race と同じく fail-loud。
    local ss; ss=$(_make_state_stub unknown)
    ORCH_SPAWN_ADMIN_SESSION_STATE="$ss" \
    ORCH_SPAWN_ADMIN_VERIFY_ATTEMPTS=1 ORCH_SPAWN_ADMIN_RESEND_MAX=0 \
        run_spawn_admin tb
    [ "$status" -ne 0 ]
    [[ "$output" == *"turn 起動を確認できません"* ]]
}

@test "(K660-dryrun-plan) dry-run が model=opus[1m] / effort=xhigh / ultracode 注入 / injection plan を表示（side-effect ゼロ）" {
    run_spawn_admin tb --dry-run
    [ "$status" -eq 0 ]
    # ★orch-i7ft FOOTGUN-BRACKET: grep -q 'opus[1m]' は bracket expression と解釈され literal に一致しない（実測）。
    #   [[ ]] の RHS は quote すれば literal 比較になるのでここでは *"opus[1m]"* を使う（grep する場合は -F）。
    [[ "$output" == *"model   : opus[1m]"* ]]
    [[ "$output" == *"effort  : xhigh"* ]]
    [[ "$output" == *"/effort ultracode"* ]]
    [[ "$output" == *"turn 起動照合"* ]]                     # orch-sm6p の照合を plan に明示
    # 旧既定の残存文言が plan に出ない（modality 1/4・既定 plan 経路）。旧 assert の *"opus[1m]"*（「fallback 先を
    #   plan に明示」）は model 行で自己充足するため vacuous duplicate として削除した。
    #   engine の dry-run 出力には model fallback 以外の 'fallback' 語を出す機構が無い（local copy が持つ session 名
    #   fail-open fallback 警告＝topology(1) は engine 未取込み）ため、出力全体で 0 hit を要求できる（実測確認済み）。
    [[ "$output" != *"fable"* ]]
    [[ "$output" != *"preflight"* ]]
    [[ "$output" != *"fallback"* ]]
    [ ! -s "$CLD_PROMPT_FILE" ]                              # dry-run は cld-spawn を呼ばない
    [ ! -s "$CLD_ARGS_FILE" ]
}

@test "(I7FT-plan-no-fable) --dry-run --no-effort-inject の plan にも旧既定文言（fable）が出ない（modality 2/4・ultra 見送り枝の直接被覆）" {
    # --no-effort-inject 枝の ultra 行は人間可視の実出力で、旧文言「fable+xhigh のまま」を放置すると新既定下で
    #   嘘を吐く（既定 plan 経路の teeth では被覆されない別枝）。ここで直接 pin する。
    run_spawn_admin tb --dry-run --no-effort-inject
    [ "$status" -eq 0 ]
    [[ "$output" == *"注入は見送り"* ]]                      # 当該枝を確かに通っている（空虚でない）
    [[ "$output" != *"fable"* ]]
}

# (K660-e-docs) は削除: private 配備層の docs/systemd drift teeth（$REPO_ROOT/CLAUDE.md 等を grep する @test）は
#   配備層側 residual bats が担う（engine copy は mechanism teeth のみ）。

# ==============================================================================
# (HELP-noreg) --help は registry 非依存（fail-loud gate より前の先読み・sc-vcjv gate finding 反映）
#   registry（env ORCH_ADMIN_PROJECTS / lib overlay）が全く無い環境でも、文書化済みの --help は
#   header usage を exit0 で表示する（fail-loud gate は --help を巻き添えにしない）。
#   ★`--` 以降は kickoff prompt 引数ゆえ、prompt 内の "--help" 文字列では help へ落ちない（境界 teeth）。
# ==============================================================================
@test "(HELP-noreg) registry 未供給でも --help は usage を exit0 表示（fail-loud gate の非巻き添え）" {
    run env -u ORCH_ADMIN_PROJECTS -u ORCH_ANCHOR bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch-spawn-admin"* ]]
    [[ "$output" != *"未供給"* ]]
}

@test "(HELP-noreg-boundary) -- 以降の '--help' は prompt 引数として扱われ help へ落ちない（registry gate が先に効く）" {
    run env -u ORCH_ADMIN_PROJECTS -u ORCH_ANCHOR bash "$SCRIPT" -- "--help"
    [ "$status" -ne 0 ]
    [[ "$output" == *"未供給"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (VHIU) 承認規約 3 クラス改訂の teeth（orch-vhiu R1・engine copy への surgical port）
#
#   なぜ要るか（load-bearing）: 本 script の BRIEF は spawn される **全 foreign project admin** の kickoff
#   prompt へ恒久注入される。「human 決定（固い merge 確認を含む）は NEEDS-USER」が焼かれている限り、規約 doc を
#   全部直しても新規 admin は生まれた瞬間に旧規約を持つ。port 元 repo 側の ENGINE-KEEPSET-PARITY は本 script を
#   型1（drift inventory）/型2（コメント carrier の hit 数 pin）とも被覆するが、それは **foreign repo 側にしか
#   存在しない突合線**で engine repo 単独では RED にできない（かつ engine を持たない host では loud skip する）。
#   ゆえに本 teeth 群が engine repo 内で自己完結する唯一の防壁。
#   以下は「書いてあるか」でなく「旧文言なら落ちるか」を機械照合する: positive pin（新意味論の load-bearing
#   要素）と negative pin（旧文言・極性反転形の不在）を対で置き、4 carrier（header ⑦ / BRIEF 生成箇所の inline
#   comment / beads BRIEF / no-beads BRIEF）の同期を出現回数で pin する。
#   ★旧文言を逐語引用しないこと（引用すると negative pin が素通りして空虚化する）。
#   ★prompt file は inject stub が append し truncate は setup() の 1 回のみ＝両分岐を回す test は周回頭で
#     truncate する（しないと 2 周目が和集合になり no-beads 側 positive assert が空虚化する・(VHIU-harness) が pin）。
# ─────────────────────────────────────────────────────────────────────────────

@test "(VHIU-3class) 両 brief に「取り消せない」3 クラスが canonical 括弧注記込みで入る（(c) の閾値=追加課金の有無＝観測可能）" {
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避（下記 (VHIU-harness) 参照）
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        grep -q '取り消せない' "$CLD_PROMPT_FILE"
        grep -q '(a) 消す' "$CLD_PROMPT_FILE"
        grep -q '(b) 出す' "$CLD_PROMPT_FILE"
        grep -q '(c) 使う' "$CLD_PROMPT_FILE"
        # canonical block が verbatim 搬送を要求した括弧注記 2 点
        grep -q '第一防衛線は機械 guard 層' "$CLD_PROMPT_FILE"
        grep -q '核② private 保証はこの型' "$CLD_PROMPT_FILE"
        # (c) の閾値（user 裁定 2026-07-26）＝観測できない程度表現でなく二値で判定させる
        grep -q '追加課金が発生する操作' "$CLD_PROMPT_FILE"
        grep -q '定額プラン内は対象外' "$CLD_PROMPT_FILE"
    done
}

@test "(VHIU-info-unit) 両 brief で (b) の判定単位が repo でなく「情報」＝機械 2 条件で判定し照合不能なら (b) 側へ倒す" {
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        grep -q 'public 面の情報集合を増やす' "$CLD_PROMPT_FILE"
        grep -q '配備層 file を touch しない' "$CLD_PROMPT_FILE"     # 機械 2 条件 ①
        grep -q 'DATA literal' "$CLD_PROMPT_FILE"                     # 機械 2 条件 ②
        grep -q '0 hit' "$CLD_PROMPT_FILE"
        grep -q 'repo 単位の断定は禁止' "$CLD_PROMPT_FILE"           # over-permit の再発防止句
        grep -q 'fail-safe' "$CLD_PROMPT_FILE"                        # 照合不能なら (b) 側へ倒す
        # ★per-brief positive pin（(VHIU-4carrier-sync) の count は「分布」を見ないため、1 carrier を希釈して
        #   別 carrier へ複製し総数 4 を保つ改訂を素通しする。連言条件そのものを各 brief で直接 pin して塞ぐ）。
        grep -q '両方 green なら非該当' "$CLD_PROMPT_FILE"           # 機械 2 条件は連言（選言へ倒すと核② leak 面が開く）
        grep -q '人間確認が要るのは' "$CLD_PROMPT_FILE"              # 発火条件の主語
        grep -q '人間確認へ倒' "$CLD_PROMPT_FILE"                    # 照合不能時の倒し先
    done
}

@test "(VHIU-old-permit-negative) 旧 mandate（human 決定＝merge 確認で park）と旧未定義閾値が両 brief から消えている" {
    # ★このテストが本 port の意味変更を機械証明する中核: port 前の engine 文言で回すと落ちる（＝非空虚）。
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        # port 前 engine の旧 mandate（3 クラス化そのものが未 land だった形）
        refute_grep -q '固い merge 確認を含む' "$CLD_PROMPT_FILE"
        # 観測できない程度表現（死文化する閾値）
        refute_grep -q '大きな金銭コスト' "$CLD_PROMPT_FILE"
        # over-permit（核② の最大 leak 面を自判断側へ落とす断定）
        refute_grep -q '既に public な repo への通常 merge は非該当' "$CLD_PROMPT_FILE"
        refute_grep -q '既 public repo への通常 merge は非該当' "$CLD_PROMPT_FILE"
    done
    # ★file 全体スコープの negative pin: 上の refute は生成された prompt（BRIEF 2 carrier）にしか当たらず、
    #   header ⑦ / inline comment carrier へ旧 mandate を **共存的に再注入** する編集を素通しする
    #   （(VHIU-4carrier-sync) は count の減少しか見ないため増加は検知できない）。source 全体で 0 hit を pin する。
    [ -f "$SCRIPT" ]                                        # vacuity 封じ（不在なら RED）
    grep -Fq '人間確認が要るのは' "$SCRIPT"                 # positive control（新 mandate が実在する証跡）
    refute_grep -Fq '固い merge 確認を含む' "$SCRIPT"
    refute_grep -Fq '大きな金銭コスト' "$SCRIPT"
}

@test "(VHIU-gate-fail-exit) 両 brief で gate 側 fail-closed の出口が 2 分岐する（self-test/acceptance FAIL=再 gate ／ snapshot mismatch=人間 ratify 昇格）" {
    # ★carve-out が load-bearing な理由: snapshot-mismatch は「dispatch 後に acceptance がすり替わった」ことの
    #   **機械 tamper 検知**で、3 クラスのいずれにも属さない独立トリガ（受け側 repo の規約正本 docs/protocol.md
    #   §5.4 / §5「gate の義務」(c) と、engine 自身の orch-dispatch.sh G2 が「auto-merge 資格剥奪 → 人間 ratify
    #   昇格」で据置と明記）。ここを「契約を直して再 gate」だけに倒すと **すり替えた当人が acceptance を書き換えて
    #   mismatch を消し、独立の人間確認なしに merge へ抜ける**＝検知線を検知された本人が自己解除できる fail-open。
    #   よって positive（昇格する）と negative（再 gate 一本槍の旧形が復活していない）を対で pin する。
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        # 分岐 ①: self-test / acceptance 検証の FAIL は人間へ上げず gate を通る形へ直す
        grep -q 'fail-closed トリガ' "$CLD_PROMPT_FILE"
        grep -q '契約を直して再 gate' "$CLD_PROMPT_FILE"
        # 分岐 ②（carve-out）: snapshot mismatch だけは人間 ratify へ昇格＝★極性語込み完全形で pin
        grep -q 'acceptance snapshot mismatch は例外' "$CLD_PROMPT_FILE"
        grep -q 'NEEDS-USER（人間 ratify）へ昇格' "$CLD_PROMPT_FILE"
        # precedence の射程外であること（①〜④ 番号を持たない独立トリガゆえ「旧 ①〜④ 廃止」に呑まれない）
        grep -q 'snapshot-mismatch トリガは本条の対象外' "$CLD_PROMPT_FILE"
        # ★negative pin: 旧 fail-open 形（snapshot mismatch を「出口は人間確認ではない」側の例示に置く）の復活封鎖。
        #   この形が戻ると carve-out が空文になるため、positive だけでは検知できない。
        refute_grep -q 'acceptance snapshot mismatch 等' "$CLD_PROMPT_FILE"
    done
}

@test "(VHIU-3misread) 両 brief に誤読防止 3 句（gate は外さない / worker 自己 merge ではない / バナーは scope 縮小）が入る" {
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        grep -q 'gate 分離' "$CLD_PROMPT_FILE"                    # ② gate 分離は不変
        grep -q '「worker が自己 merge してよい」ではない' "$CLD_PROMPT_FILE"   # ② ★極性込み完全形（被否定句だけを pin すると反転で逆に一致する）
        grep -q '廃止でなく scope 縮小' "$CLD_PROMPT_FILE"        # ③ front-load/バナーは scope 縮小
        grep -q '実効安全弁' "$CLD_PROMPT_FILE"                   # ① gate は外さない（強化側）
    done
}

@test "(VHIU-precedence) 両 brief に precedence（本 mandate が旧 merge-ratify ①〜④ に優先・primer に旧規約が残っていても勝つ）が入る" {
    # 無いと kickoff（新規約）と SessionStart primer（旧規約・正本改訂は courier 係属中）の矛盾が
    #   非決定論的に解決される＝admin ごとに挙動が割れる。
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        grep -q 'precedence' "$CLD_PROMPT_FILE"
        grep -q '旧 merge-ratify' "$CLD_PROMPT_FILE"
    done
}

@test "(VHIU-4carrier-sync) 4 carrier（header ⑦ / inline / beads BRIEF / no-beads BRIEF）が同一 anchor 句で同期している" {
    # 3 層 drift（header ⑦ と inline comment が BRIEF より permissive になる非対称）の封鎖。
    #   各 anchor 句がちょうど 4 箇所に出ることで同期を機械照合する＝1 箇所だけ直す片手落ち改訂が RED になる。
    #   数 4 の由来: header ⑦ / BRIEF 生成箇所の inline comment / beads BRIEF / no-beads BRIEF。
    #   （将来 BRIEF を関数化して carrier 数が変わる refactor では、この期待値も同時に更新すること）
    #   ★anchor には **極性語を含む完全形** を使う（語彙の存在だけを pin すると「両方 green なら非該当」→
    #     「どちらか green なら非該当」の 1 行置換が全 green のまま通り、連言が選言へ反転して核② leak 面が
    #     自判断側へ開く）。極性語を anchor に含めれば反転で count が落ちて RED。
    #   ★carve-out（snapshot-mismatch）は **operative predicate ごと** anchor に入れる: 'acceptance snapshot
    #     mismatch は例外' / 'NEEDS-USER（人間 ratify）へ昇格' / 'snapshot-mismatch トリガは本条の対象外' は
    #     いずれも述語（剥奪する / 昇格せよ）を含まない部分一致形ゆえ、「3 クラス非該当**なら** auto-merge 資格を
    #     **維持**し」への 1 句反転が 3 句とも hit したまま素通りする（実測: mutation を当てても bats 全数 green）。
    #     よって述語込みの '3 クラス非該当でも auto-merge 資格を剥奪し' を 4-count anchor に加え、反転側は
    #     (VHIU-polarity-negative) の bad 語群（'auto-merge 資格を維持' / '昇格しなくてよい' 等）で対に塞ぐ。
    for phrase in "追加課金が発生する操作" "契約を直して再 gate" "precedence" "第一防衛線は機械 guard 層" \
                  "核② private 保証はこの型" "廃止でなく scope 縮小" "定額プラン内は対象外" \
                  "人間確認が要るのは" "人間確認へ倒" "両方 green なら非該当" "repo 単位の断定は禁止" \
                  "本 mandate は旧 merge-ratify ①〜④ に優先する" "出口は人間確認ではない" "実効安全弁" \
                  "「worker が自己 merge してよい」ではない" \
                  "acceptance snapshot mismatch は例外" "NEEDS-USER（人間 ratify）へ昇格" \
                  "3 クラス非該当でも auto-merge 資格を剥奪し" \
                  "snapshot-mismatch トリガは本条の対象外"; do
        n=$(grep -c "$phrase" "$SCRIPT")
        if [ "$n" -ne 4 ]; then
            echo "carrier drift: '$phrase' は 4 carrier すべてに在るべきだが $n 箇所しか無い" >&2
            return 1
        fi
    done
}

@test "(VHIU-header-help) header ⑦ は --help 可視で新意味論を含み旧文言を含まない" {
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"取り消せない"* ]]
    [[ "$output" == *"追加課金が発生する操作"* ]]
    [[ "$output" == *"public 面の情報集合を増やす"* ]]
    [[ "$output" == *"契約を直して再 gate"* ]]
    [[ "$output" == *"precedence"* ]]
    # snapshot-mismatch carve-out も header ⑦ に在り --help で人間可読であること（BRIEF より permissive にしない）
    [[ "$output" == *"acceptance snapshot mismatch は例外"* ]]
    [[ "$output" == *"NEEDS-USER（人間 ratify）へ昇格"* ]]
    [[ "$output" == *"snapshot-mismatch トリガは本条の対象外"* ]]
    # 旧文言 negative（port 前の header で回すと RED＝非空虚）
    [[ "$output" != *"固い merge 確認を含む"* ]]
    [[ "$output" != *"大きな金銭コスト"* ]]
    # fail-open 形 negative: snapshot mismatch を「出口は人間確認ではない」側の例示に戻していない
    [[ "$output" != *"acceptance snapshot mismatch 等"* ]]
}

@test "(VHIU-autonomy-superseded) 設計境界の旧 autonomy 文言（受動運用）が supersede 記述へ置換されている（--help 可視）" {
    # 同 file 内の同便 carrier。orch-rvbz / orch-6srt で③通知付き自律へ改訂済み（承認体制の自律化と同一主題）。
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" != *"自律 dispatch はしない"* ]]
    [[ "$output" == *"通知付き自律"* ]]
    [[ "$output" == *"supersede 済み"* ]]
}

@test "(VHIU-polarity-negative) 極性を反転した形が 1 つも出現しない（部分一致 pin が反転を素通しする罠の封鎖）" {
    # teeth の穴: 語彙の存在のみを pin し **述語の向き** を pin しないと、意味を反転させる 1 行置換が全緑のまま通る。
    #   positive 側は (VHIU-4carrier-sync) が極性語込み anchor の出現数 4 で pin する。本 test はその対で、
    #   反転形が 1 つでも現れたら RED にする。
    #   ここに挙げる語は「反転したときにだけ現れる形」であること（正文に含まれる語を入れると誤爆する）。
    #   ★carve-out の述語反転（'資格を剥奪し'→'資格を維持し' / '昇格せよ'→'昇格しなくてよい'）は本 cell で最も
    #     stake が高い（検知線を検知された本人が自己解除できる fail-open の復活）ため、反転側 4 形をここで pin
    #     する（4 形とも現行 source で 0 hit＝誤爆しないことを実測済み。positive 側は (VHIU-4carrier-sync) の
    #     '3 クラス非該当でも auto-merge 資格を剥奪し' が count=4 で受け持つ）。
    for bad in "どちらか green なら非該当" "いずれか green なら非該当" "片方が green なら非該当" \
               "出口は人間確認である" "出口は人間確認でなく" \
               "旧 merge-ratify ①〜④ が優先" "旧 merge-ratify ①〜④ に劣後" \
               "repo 単位で判定" "既に public な repo への通常 merge は非該当" \
               "acceptance snapshot mismatch 等" "snapshot mismatch は例外ではない" \
               "snapshot-mismatch トリガも本条の対象" \
               "auto-merge 資格を維持" "昇格しなくてよい" "昇格は不要" "昇格しない"; do
        if grep -q "$bad" "$SCRIPT"; then
            echo "polarity 反転形が出現している: '$bad'" >&2
            return 1
        fi
    done
    # ★逐語 list だけでは足りない理由（実測）: 正文は markdown 強調込みで '**…へ昇格**せよ' の形ゆえ、
    #   義務語だけを裏返す編集は '…へ昇格**しなくてよい' のように **強調記号を跨いだ** 文字列になり、
    #   contiguous な逐語 pin（'昇格しなくてよい'）を素通りする。強調記号・空白を許容する ERE で対に塞ぐ。
    if grep -qE 'へ昇格[*_[:space:]]*(しなくてよい|しなくても|せずとも|は不要|しない|する必要はない)' "$SCRIPT"; then
        echo "polarity 反転形: carve-out の義務語（人間 ratify へ昇格せよ）が反転している" >&2
        return 1
    fi
    if grep -qE 'auto-merge 資格を[*_[:space:]]*(維持|据置|保持|剥奪しない|剥奪せず)' "$SCRIPT"; then
        echo "polarity 反転形: auto-merge 資格の剥奪が維持側へ反転している" >&2
        return 1
    fi
}

@test "(VHIU-carrier-distribution) 各 anchor が 4 carrier に 1 hit ずつ **分布** する（count 一致だけでは片寄せ改訂を素通しするため）" {
    # (VHIU-4carrier-sync) は grep -c（行数カウント）で総数 4 を見るだけなので、1 carrier から落として別 carrier へ
    #   複製し総数を保つ「片寄せ」改訂を素通しする（gate が mutation で実証）。本 test は carrier ごとの実在を見る。
    #   ★carrier の切り出しは行番号 pin を使わず observable な経路で行う:
    #     header ⑦        = --help 出力（実測: --help は header の連続コメントのみを出し、BRIEF 生成箇所の
    #                        inline comment は出さない＝'同一意味論の再掲' が --help に 0 hit であることで確認）
    #     beads BRIEF     = tb（.beads 有り）で生成した prompt
    #     no-beads BRIEF  = tn（.beads 無し）で生成した prompt
    #     inline comment  = source 総数 4 から上記 3 carrier 分を引いた残余として導出（＝1 でなければ RED）
    run bash "$SCRIPT" --help
    [ "$status" -eq 0 ]
    local help_out="$output"

    : > "$CLD_PROMPT_FILE"; run_spawn_admin tb; [ "$status" -eq 0 ]
    local beads_prompt; beads_prompt="$(cat "$CLD_PROMPT_FILE")"
    : > "$CLD_PROMPT_FILE"; run_spawn_admin tn; [ "$status" -eq 0 ]
    local nobeads_prompt; nobeads_prompt="$(cat "$CLD_PROMPT_FILE")"

    # harness の非空虚性（切り出しが実際に別物を掴んでいること）: beads 専用句が no-beads 側に無い
    grep -q '着手したら自台帳' <<< "$beads_prompt"
    refute_grep -q '着手したら自台帳' <<< "$nobeads_prompt"
    grep -q '同一意味論の再掲' "$SCRIPT"            # inline carrier 固有句が source に在る（残余導出の前提）
    refute_grep -q '同一意味論の再掲' <<< "$help_out"  # かつ --help には出ない＝header と inline を弁別できる

    local p n_total n_help n_b n_n n_inline
    for p in "人間確認が要るのは" "追加課金が発生する操作" "契約を直して再 gate" "出口は人間確認ではない" \
             "両方 green なら非該当" "人間確認へ倒" "repo 単位の断定は禁止" "実効安全弁" \
             "acceptance snapshot mismatch は例外" "3 クラス非該当でも auto-merge 資格を剥奪し" \
             "snapshot-mismatch トリガは本条の対象外" "廃止でなく scope 縮小"; do
        n_total=$(grep -c "$p" "$SCRIPT")
        n_help=$(grep -c "$p" <<< "$help_out")
        n_b=$(grep -c "$p" <<< "$beads_prompt")
        n_n=$(grep -c "$p" <<< "$nobeads_prompt")
        n_inline=$(( n_total - n_help - n_b - n_n ))
        if [ "$n_total" -ne 4 ] || [ "$n_help" -lt 1 ] || [ "$n_b" -lt 1 ] || [ "$n_n" -lt 1 ] || [ "$n_inline" -ne 1 ]; then
            echo "carrier 分布 drift: '$p' total=$n_total header(--help)=$n_help beads=$n_b no-beads=$n_n inline(残余)=$n_inline" >&2
            return 1
        fi
    done
}

@test "(VHIU-ask-escalate) canonical block の【聞かないこと】【上げること】が両 brief に入る（自律側の唯一の未 pin 節を塞ぐ）" {
    # canonical block v2 の構成要素のうち、この 2 句だけが他の VHIU teeth のどれにも pin されていなかった
    #   （承認体制の自律化＝「聞かない」側の実体で、黙って落ちると admin が旧来どおり是認を求めて止まる）。
    #   ★出現数は 4 でなく 2: この節は BRIEF 2 carrier のみに在る（header ⑦ / inline comment は持たない＝
    #     local as-landed と同型）。ゆえに (VHIU-4carrier-sync) の 4-anchor 群には入れず本 test で別枠 pin する。
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        grep -q '推奨を出して決めて進め' "$CLD_PROMPT_FILE"   # 【聞かないこと】＝是認だけを求める問いは出さない
        grep -q 'grill 提案' "$CLD_PROMPT_FILE"               # 【上げること】＝承認要求でなく grill 提案として上げる
        grep -q '事実で決まるなら止めない' "$CLD_PROMPT_FILE" # 上げる境界（事実で決まる論点は止めない）
    done
    # 2 carrier 分布の pin（片方だけに在る状態＝出し分け漏れを RED にする）
    n=$(grep -c 'grill 提案' "$SCRIPT")
    [ "$n" -eq 2 ]
}

@test "(VHIU-harness) prompt file の truncate 無しでは no-beads 側 assert が空虚化する（harness 汚染の回帰 pin）" {
    # harness の構造: CLD_PROMPT_FILE は inject stub が **append** し（本 file 冒頭 stub 定義）、truncate は
    #   setup() の 1 回のみ。ゆえに truncate せずに tb→tn と 2 周回すと 2 周目の grep は tb+tn の **和集合** を
    #   見ることになり、no-beads 側の positive assert が全て空虚になる。本 test はその append 挙動自体を pin
    #   する（挙動が変われば VHIU 群の truncate 前提も見直しが要る）。
    #   ※ 弁別句の選び方: '終端宣言 bead' は no-beads 側にも「終端宣言 bead を作れない」の形で出るため使えない。
    #     beads 分岐だけが持つのは「着手したら自台帳」。
    run_spawn_admin tb
    [ "$status" -eq 0 ]
    grep -q '着手したら自台帳' "$CLD_PROMPT_FILE"       # beads 分岐だけが持つ句
    run_spawn_admin tn                                   # truncate せずに 2 周目を回すと…
    [ "$status" -eq 0 ]
    grep -q '着手したら自台帳' "$CLD_PROMPT_FILE"       # …前周の内容が残っている＝append である証拠
    grep -q '台帳を持たない' "$CLD_PROMPT_FILE"         # かつ今周の内容も在る＝和集合
    # truncate すれば分離される（VHIU 群が採る方式）
    : > "$CLD_PROMPT_FILE"
    run_spawn_admin tn
    [ "$status" -eq 0 ]
    refute_grep -q '着手したら自台帳' "$CLD_PROMPT_FILE"  # 前周の beads 専用句は消えている
    grep -q '台帳を持たない' "$CLD_PROMPT_FILE"
}

@test "(VHIU-relay-header) orch-relay.sh の役割コメントも 3 クラス規約へ同期している（同便 carrier・旧文言の孤立残置を防ぐ）" {
    # relay は「NEEDS-USER で park した window を再開させる」primitive ＝ park の発火条件を旧文言で説明したまま
    #   残すと、spawn-admin だけ直しても fleet の説明が割れる（同便で同期する理由）。
    local relay="$BATS_TEST_DIRNAME/../../scripts/orch-relay.sh"
    [ -f "$relay" ]                                  # vacuity 封じ: 不在なら RED（grep の rc=2 を OK に化けさせない）
    grep -q 'NEEDS-USER で park' "$relay"            # positive control（当該コメント block が実在する証跡）
    grep -q '取り消せない 3 クラス' "$relay"
    refute_grep -q '（固い merge 確認等）' "$relay"  # 旧文言 negative（port 前で回すと RED＝非空虚）
}

@test "(VHIU-unattended-visibility) 可視性要件は在席分岐込みで注入する（無人 brief へ「AskUserQuestion 最優先」を焼かない）" {
    # ★本 test は **engine-only の意図的分岐** を pin する（port 元 as-landed は当該句を保持。分岐の実測根拠と
    #   上流への申告は bd sc-r2ix の notes を参照＝根拠の詳細は台帳に留め公開 doc へ敷衍しない・protocol §5.4）。
    #   engine 側は下記 assert のとおり 0 hit＋無人 actor 分岐で着地する。
    # ★load-bearing: 同じ BRIEF の layer ①（orch-z7g・本 file 上部の「対話プロンプトを使うな」）は対話 tool を
    #   **絶対形**で禁じている（この window に人間は付いていない）。そこへ user 裁定 2026-07-17 の可視性要件を
    #   **在席修飾子ごと落として**転記すると「AskUserQuestion 最優先」が無人 window の runtime prompt に焼かれ、
    #   同一 brief 内で正面衝突する（admin は非決定論的にどちらかへ倒れる）。
    #   機構層（DISALLOWED_TOOLS_DEFAULT の --disallowed-tools 既定 ON）は二重化だが **opt-out 可**で、しかも
    #   --no-disallowed-tools は「既存 window を再選択したい」等 **在席とは無関係な用途**でも正規手順として案内される。
    #   その経路では文面 layer ① が唯一の防壁ゆえ（文面だけだと CC 既定挙動へ再発する＝orch-z7g H1 の裏返し）、
    #   文面が逆向きの指示を持つと無人 window の out-of-band freeze（bead-truth poll から不可視＝相互デッドロック）が
    #   再現する。規約正本も在席分岐を明示: 受け側 repo docs/protocol.md §7.2 可視性要件 (a)「対話文脈（human が
    #   window に居る）では AskUserQuestion を最優先（**無人 window へは出さない**）」／同節 整合注記「orchestrator
    #   監視下で human が window に居ない admin session は無人 actor 側に倒す」。
    #   ★過剰補正（可視性要件ごと削る）も RED にする＝縮小されたのは**発火条件**で様式ではない。
    #   ※出現数は 4 でなく 2: 可視性要件の列挙は BRIEF 2 carrier のみが持つ（header ⑦ / inline comment は持たない）
    #     ＝(VHIU-4carrier-sync) の 4-anchor 群には入れず本 test で別枠 pin する（(VHIU-ask-escalate) と同型）。
    for proj in tb tn; do
        : > "$CLD_PROMPT_FILE"   # ★harness 汚染回避
        run_spawn_admin "$proj"
        [ "$status" -eq 0 ]
        # negative: 在席修飾子を落とした転記形（layer ① との正面衝突）の封鎖
        refute_grep -q 'AskUserQuestion 最優先' "$CLD_PROMPT_FILE"
        # positive: 無人 actor 分岐が明示されている
        grep -q 'window は無人ゆえ AskUserQuestion は使わない' "$CLD_PROMPT_FILE"
        grep -q '無人 window へは出さない' "$CLD_PROMPT_FILE"
        # positive: 様式自体は存続（過剰補正で可視性要件ごと落とすのも RED）
        grep -q '可視性要件' "$CLD_PROMPT_FILE"
        grep -q '🔴 バナー一行' "$CLD_PROMPT_FILE"
        # positive control: layer ① 本体が同居している（分岐注記が孤立していない＝衝突相手が実在する）
        grep -q '対話プロンプトを使うな' "$CLD_PROMPT_FILE"
    done
    # file 全体 negative: 生成 prompt に当たらない header ⑦ / inline comment carrier への再注入も封鎖
    [ -f "$SCRIPT" ]                                                  # vacuity 封じ
    refute_grep -Fq 'AskUserQuestion 最優先' "$SCRIPT"
    # 2 carrier 分布の pin（片方だけ直す片手落ちを RED にする）
    n=$(grep -c 'window は無人ゆえ AskUserQuestion は使わない' "$SCRIPT")
    [ "$n" -eq 2 ]
}

#!/usr/bin/env bats
# session-start-role-inject.bats — scribe v0-C2(bd un-ck2) role 別 SessionStart 注入の検証
#
# カバレッジ:
#   - 構文(bash -n)
#   - .beads opt-in guard(bd un-7hx): .beads 有/無 × admin/worker/consult / git toplevel
#     フォールバック / ガードは role 明示より外側(.beads 無しなら明示 role でも注入ゼロ)
#   - role 判定マトリクス: env SCRIBE_ROLE(admin/worker/consult) / cwd .worktrees(worker) /
#     既定(admin) / 優先順(env > cwd > 既定) / 未知 env の degrade
#   - role 別注入内容の必須キーワード存在(spec §2.1-2.3)
#   - fail-safe: doc 不在で exit 0 degrade(全 role)・stderr 警告・stdout 無注入
#   - cwd ソース: stdin JSON 優先 / 無ければ $PWD フォールバック
#   - ultracode リマインダ source 分岐(sc-o7fz): startup/resume/欠落/未知=打鍵案内・clear=保持 1 行・
#     compact=suppress・sed フォールバック片系統・worker/consult 非混入
#   - hooks.json: valid JSON / script 参照 / 安全形の dynamic assertion(ガード支配)

bats_require_minimum_version 1.5.0

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/hooks/session-start-role-inject.sh"
    HOOKS_JSON="$REPO/hooks/hooks.json"

    # --- .beads opt-in guard(bd un-7hx)を通すため、実在する cwd を temp に用意する ---
    # 既定 cwd(anchor 相当・.beads あり・非 worktree)と worker cwd(.worktrees/ 配下・.beads
    # あり=redirect 相当)。本物の anchor/worktree とも .beads は実ディレクトリ。
    ANCHOR_DIR="$BATS_TEST_TMPDIR/proj"
    WT_DIR="$BATS_TEST_TMPDIR/proj/.worktrees/spawn/x-1"
    mkdir -p "$ANCHOR_DIR/.beads" "$WT_DIR/.beads"
    WT_JSON="{\"cwd\":\"$WT_DIR\"}"
    ANCHOR_JSON="{\"cwd\":\"$ANCHOR_DIR\"}"
    EMPTY_JSON='{}'

    # --- CC-native worktree cwd(.claude/worktrees/ 配下・sc-vwm)。先頭ドット無しゆえ
    #     旧 glob `*/.worktrees/*` に一致せず独立 arm `*/.claude/worktrees/*` で worker 判定する。 ---
    CC_WT_DIR="$BATS_TEST_TMPDIR/proj/.claude/worktrees/x-1"
    mkdir -p "$CC_WT_DIR/.beads"
    CC_WT_JSON="{\"cwd\":\"$CC_WT_DIR\"}"

    # --- .beads 無し cwd(注入ゼロ検証用・scribe 管轄外プロジェクト相当) ---
    NOBEADS_DIR="$BATS_TEST_TMPDIR/nobeads"
    NOBEADS_WT="$BATS_TEST_TMPDIR/nobeads/.worktrees/spawn/y-1"
    mkdir -p "$NOBEADS_WT"
    NOBEADS_ANCHOR_JSON="{\"cwd\":\"$NOBEADS_DIR\"}"
    NOBEADS_WT_JSON="{\"cwd\":\"$NOBEADS_WT\"}"

    # --- consult 窓判定(sc-cji)の hermetic 化用 tmux stub ---
    # hook は tmux を "${SCRIBE_TMUX:-tmux}" 経由で呼ぶ(gate の command -v も同 seam)。
    # 実 tmux server に依存せず window 名を注入できるよう偽 tmux を用意する。
    # 挙動は env で制御: STUB_TMUX_WINDOW=返す #W / STUB_TMUX_FAIL=1 で display-message が非0 exit。
    STUB_TMUX="$BATS_TEST_TMPDIR/fake-tmux"
    cat > "$STUB_TMUX" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "display-message" ] || exit 0
[ "${STUB_TMUX_FAIL:-0}" = "1" ] && exit 1
printf '%s\n' "${STUB_TMUX_WINDOW:-}"
STUB
    chmod +x "$STUB_TMUX"
}

# inject <role|-> <plugin_root> <stdin_json>
#   role が "-" なら SCRIBE_ROLE を unset、それ以外は env で焼き込む。
inject() {
    local r="$1" root="$2" json="$3"
    # tmux 系 env(TMUX/TMUX_PANE/SCRIBE_TMUX)を明示 unset して hermetic 化(sc-cji): これらを stub しない
    # テストは consult 窓判定の gate が必ず偽になり fail-safe(既存 opt-out/判定)経路を取る。tmux セッション内で
    # bats を走らせても none 枝が実 tmux を叩かない(継承 TMUX による非決定を排除)。consult 窓検出は inject_tmux で試す。
    if [ "$r" = "-" ]; then
        printf '%s' "$json" | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX CLAUDE_PLUGIN_ROOT="$root" "$SCRIPT"
    else
        printf '%s' "$json" | env -u TMUX -u TMUX_PANE -u SCRIBE_TMUX SCRIBE_ROLE="$r" CLAUDE_PLUGIN_ROOT="$root" "$SCRIPT"
    fi
}

# inject_tmux <role|-> <plugin_root> <stdin_json> <window|""> [fail:0|1]
#   consult 窓判定(sc-cji)用に tmux を stub して呼ぶ。TMUX/TMUX_PANE を設定し SCRIBE_TMUX で偽 tmux を差す。
#   window="" は display-message が空出力を返す状況(取得不能相当)、fail=1 は非0 exit(取得失敗)を再現する。
inject_tmux() {
    local r="$1" root="$2" json="$3" win="$4" fail="${5:-0}"
    local base=(CLAUDE_PLUGIN_ROOT="$root" SCRIBE_TMUX="$STUB_TMUX" TMUX="fake-tmux" TMUX_PANE="%0"
                STUB_TMUX_WINDOW="$win" STUB_TMUX_FAIL="$fail")
    if [ "$r" = "-" ]; then
        printf '%s' "$json" | env -u SCRIBE_ROLE "${base[@]}" "$SCRIPT"
    else
        printf '%s' "$json" | env SCRIBE_ROLE="$r" "${base[@]}" "$SCRIPT"
    fi
}

# ---- 構文 ----
@test "syntax: bash -n が通る" {
    run bash -n "$SCRIPT"
    [ "$status" -eq 0 ]
}

@test "script: 実行可能ビットが立っている" {
    [ -x "$SCRIPT" ]
}

# ---- role 判定マトリクス ----
@test "role: 既定(env 無し・cwd が非 worktree) → admin" {
    run --separate-stderr inject - "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"既定(anchor 無印)"* ]]
}

@test "role: cwd が .worktrees/ 配下(env 無し) → worker" {
    run --separate-stderr inject - "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"cwd .worktrees/"* ]]
}

@test "role: env SCRIBE_ROLE=consult → consult" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
    [[ "$output" == *"env SCRIBE_ROLE"* ]]
}

@test "role: env SCRIBE_ROLE=admin → admin" {
    run --separate-stderr inject admin "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
}

@test "role: env SCRIBE_ROLE=worker → worker" {
    run --separate-stderr inject worker "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

# ---- ultracode 打鍵リマインダ(sc-icb): admin にだけ出る ----
@test "ultracode リマインダ: admin 注入に /effort ultracode の打鍵案内が含まれる" {
    run --separate-stderr inject admin "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/effort ultracode"* ]]
}

@test "ultracode リマインダ: worker/consult 注入には出ない" {
    run --separate-stderr inject worker "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/effort ultracode"* ]]
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/effort ultracode"* ]]
}

# ---- ultracode リマインダ source 分岐(sc-o7fz/orch-cn7s): §9『/clear は保持・respawn でのみ喪失』 ----
# startup=打鍵案内 / clear=保持 1 行へ差し替え(再打鍵誘導を焼かない) / compact=suppress /
# resume・source 欠落・未知値=打鍵案内(fail-safe: 出し損ね=silent 喪失 > 余分な 1 行 noise)。
@test "ultracode source 分岐: startup → 打鍵案内を出す(新規 process=確実に off)" {
    run --separate-stderr inject admin "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"startup\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/effort ultracode"* ]]
}

@test "ultracode source 分岐: clear → 打鍵案内を出さず『/clear は保持』1 行に差し替え(§9 整合)" {
    run --separate-stderr inject admin "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"clear\"}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/effort ultracode"* ]]
    [[ "$output" != *"打鍵してください"* ]]
    [[ "$output" == *"/clear は ultracode を保持"* ]]
    [[ "$output" == *"protocol §9"* ]]
}

@test "ultracode source 分岐: compact → リマインダ・保持行とも出さない(suppress・本文注入は不変)" {
    run --separate-stderr inject admin "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"compact\"}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/effort ultracode"* ]]
    [[ "$output" != *"ultracode を保持"* ]]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"あなたは scribe admin"* ]]
}

@test "ultracode source 分岐: resume → 打鍵案内を出す(新規 process=喪失濃厚側の fail-safe)" {
    run --separate-stderr inject admin "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"resume\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/effort ultracode"* ]]
}

@test "ultracode source 分岐: source 欠落/未知値 → 打鍵案内を出す(抽出不能の fail-safe)" {
    # ANCHOR_JSON は source キー無し(source を持たない旧 CC 相当)
    run --separate-stderr inject admin "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/effort ultracode"* ]]
    # 未知の将来値も同じ側(出す)へ倒す
    run --separate-stderr inject admin "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"future-mode\"}"
    [ "$status" -eq 0 ]
    [[ "$output" == *"/effort ultracode"* ]]
}

@test "ultracode source 分岐: clear の保持行は worker/consult に混入しない" {
    run --separate-stderr inject worker "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"clear\"}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ultracode を保持"* ]]
    run --separate-stderr inject consult "$REPO" "{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"clear\"}"
    [ "$status" -eq 0 ]
    [[ "$output" != *"ultracode を保持"* ]]
}

@test "ultracode source 分岐: jq 不在(sed フォールバック)でも source=clear を認識する" {
    # cwd と同じ汎用抽出器(_scribe_extract_json_string)の sed 分岐が source でも機能する片系統回帰検知。
    local bindir="$BATS_TEST_TMPDIR/nojq-bin-src"
    mkdir -p "$bindir"
    local b
    for b in bash env dirname cat sed head awk; do
        ln -sf "$(command -v "$b")" "$bindir/$b"
    done
    local j="{\"cwd\":\"$ANCHOR_DIR\",\"source\":\"clear\"}"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE= CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$j' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" != *"/effort ultracode"* ]]
    [[ "$output" == *"/clear は ultracode を保持"* ]]
}

@test "優先順: env(consult) > cwd(.worktrees) — worktree cwd でも consult が勝つ" {
    run --separate-stderr inject consult "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
}

@test "優先順: cwd(.worktrees) > 既定 — env 無し worktree は worker(admin に落ちない)" {
    run --separate-stderr inject - "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

# ---- CC-native worktree(.claude/worktrees/)の worker 判定(sc-vwm・orch-d6b G6) ----
# `.claude/worktrees/` は先頭ドット無しゆえ `*/.worktrees/*` に一致しない(独立 arm が必要)。
# detect_basis="cwd .claude/worktrees/" の assertion が第2 arm の発火を証明する(第1 arm との disjoint)。
@test "role: cwd が .claude/worktrees/ 配下(CC-native・env 無し) → worker (sc-vwm)" {
    run --separate-stderr inject - "$REPO" "$CC_WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"cwd .claude/worktrees/"* ]]
}

@test "優先順: env(consult) > cwd(.claude/worktrees) — CC worktree cwd でも consult が勝つ (sc-vwm)" {
    run --separate-stderr inject consult "$REPO" "$CC_WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
}

@test "guard(.beads 有・CC-native worktree): worker は従来どおり注入する(§2/§3/§4) (sc-vwm)" {
    run --separate-stderr inject - "$REPO" "$CC_WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"## 2. worker prompt 規約"* ]]
}

@test "degrade: 未知の SCRIBE_ROLE は無視され cwd 判定へ(worktree→worker)・stderr 警告" {
    run --separate-stderr inject bogus "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$stderr" == *"未知の SCRIBE_ROLE"* ]]
}

@test "degrade: 未知の SCRIBE_ROLE + 非 worktree → 既定 admin" {
    run --separate-stderr inject bogus "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
}

# sc-pfm: SCRIBE_ROLE=none は既知の opt-out — role 注入を抑止し無出力 exit 0（未知値の degrade と異なり
# warning も出さない）。別レイヤ（自前 .beads の orchestrator 等）が .beads opt-in を通過しても scribe
# role 注入を受けないための明示シグナル（bfe0ce39 / decision 115521de）。
@test "opt-out: SCRIBE_ROLE=none + 非 worktree(.beads 有) → 注入ゼロ・exit 0・warning なし(既定 admin に落ちない)" {
    run --separate-stderr inject none "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                            # role 注入を出さない（既定 admin にも degrade しない）
    [[ "$output" != *"role="* ]]
    [[ "$stderr" != *"未知の SCRIBE_ROLE"* ]]   # 未知値(*)の degrade 経路と区別（warning を出さない）
}

@test "opt-out: SCRIBE_ROLE=none + worktree → 注入ゼロ・exit 0(cwd worker 判定も抑止)" {
    run --separate-stderr inject none "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$output" != *"role=worker"* ]]
}

# ---- consult 窓判定(sc-cji / orch-qcqz leg-a): env が settings.json project 層で none に潰される ----
# scriptorium anchor の consult 窓を tmux window 名 prefix consult- で救済する。正当な none opt-out
# (orchestrator anchor 等・非 consult 窓)は不変で壊さない。tmux は inject_tmux で stub。
@test "consult 窓(sc-cji): SCRIBE_ROLE=none + window=consult-* + 非 worktree → consult へ復帰(注入あり)" {
    run --separate-stderr inject_tmux none "$REPO" "$ANCHOR_JSON" "consult-sc-xyz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
    [[ "$output" == *"window consult-*"* ]]                      # detect_basis に override 根拠が出る
    [[ "$output" == *"env SCRIBE_ROLE=none override"* ]]
}

@test "consult 窓(sc-cji): SCRIBE_ROLE=none + window=consult-* + worktree cwd でも window が勝つ(none 枝が cwd 判定より先)" {
    run --separate-stderr inject_tmux none "$REPO" "$WT_JSON" "consult-1234"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]                         # worker に落ちない(consult 窓が authoritative)
}

@test "consult 窓(sc-cji): SCRIBE_ROLE=none + window=非consult(wt-*) → 従来どおり opt-out(注入ゼロ・回帰ガード)" {
    run --separate-stderr inject_tmux none "$REPO" "$ANCHOR_JSON" "wt-sc-abc"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                            # orchestrator anchor 等の正当な opt-out を壊さない
    [[ "$output" != *"role="* ]]
}

@test "consult 窓(sc-cji) fail-safe: SCRIBE_ROLE=none + display-message が非0 exit → opt-out(不能→従来挙動)" {
    run --separate-stderr inject_tmux none "$REPO" "$ANCHOR_JSON" "consult-sc-xyz" 1
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                            # 取得失敗は consult と誤認せず opt-out(fail-safe)
}

@test "consult 窓(sc-cji) fail-safe: SCRIBE_ROLE=none + window 名が空出力 → opt-out" {
    run --separate-stderr inject_tmux none "$REPO" "$ANCHOR_JSON" ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                            # 空 #W は consult prefix 不一致 → opt-out
}

@test "consult 窓(sc-cji) fail-safe: SCRIBE_ROLE=none + TMUX 有 + TMUX_PANE 空 → opt-out(-t '' の active-pane 縮退を gate)" {
    # TMUX_PANE 空だと -t "" が bare 形と同じ active-pane 解決へ縮退し「-t 明示」防護が無効化される
    # (gate review finding・tmux 3.4 実測)。stub は window=consult-* を返す設定だが、pane gate が先に
    # 偽になるため display-message へ到達せず opt-out になることを固定する。
    run --separate-stderr bash -c '
        printf "%s" "$1" | env SCRIBE_ROLE=none CLAUDE_PLUGIN_ROOT="$2" \
            SCRIBE_TMUX="$3" TMUX="fake-tmux" TMUX_PANE="" STUB_TMUX_WINDOW="consult-sc-xyz" "$4"
    ' _ "$ANCHOR_JSON" "$REPO" "$STUB_TMUX" "$SCRIPT"
    [ "$status" -eq 0 ]
    [ -z "$output" ]                                            # consult へ復帰しない(pane 識別なし=防護不能→fail-safe)
}

@test "consult 窓判定は none 枝限定(sc-cji): SCRIBE_ROLE=admin + window=consult-* でも admin(env が勝ち window は無視)" {
    run --separate-stderr inject_tmux admin "$REPO" "$ANCHOR_JSON" "consult-sc-xyz"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]                          # window 判定は none 枝だけ・global override ではない
    [[ "$output" == *"env SCRIBE_ROLE"* ]]
}

# ---- .beads opt-in guard(bd un-7hx): .beads 有/無 × role ----
# .beads 無し = scribe 管轄外 → 無出力で exit 0(注入ゼロ)。.beads 有り = 従来どおり注入。
@test "guard(.beads 無・非 worktree): admin 注入を漏らさず無出力 exit 0" {
    run --separate-stderr inject - "$REPO" "$NOBEADS_ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard(.beads 無・worktree): worker 注入を漏らさず無出力 exit 0" {
    run --separate-stderr inject - "$REPO" "$NOBEADS_WT_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard(.beads 無): env SCRIBE_ROLE=consult 明示でも注入ゼロ(ガードは role 明示より外側)" {
    run --separate-stderr inject consult "$REPO" "$NOBEADS_ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard(.beads 無): env SCRIBE_ROLE=admin 明示でも注入ゼロ" {
    run --separate-stderr inject admin "$REPO" "$NOBEADS_ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard(.beads 有・非 worktree): admin は従来どおり注入する" {
    run --separate-stderr inject - "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"gate funnel"* ]]
}

@test "guard(.beads 有・worktree): worker は従来どおり注入する" {
    run --separate-stderr inject - "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

@test "guard(.beads 有): consult は従来どおり注入する" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
}

@test "guard(git toplevel フォールバック): cwd 直下に .beads 無くても toplevel にあれば注入" {
    # repo を git init し toplevel に .beads を置く。cwd は subdir(直下 .beads 無し)。
    local repo="$BATS_TEST_TMPDIR/gitrepo"
    mkdir -p "$repo/sub" "$repo/.beads"
    git -C "$repo" init -q
    local sub_json="{\"cwd\":\"$repo/sub\"}"
    run --separate-stderr inject - "$REPO" "$sub_json"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
}

@test "guard(git repo だが .beads 無): toplevel にも .beads 無ければ無出力 exit 0" {
    local repo="$BATS_TEST_TMPDIR/gitrepo-nobeads"
    mkdir -p "$repo/sub"
    git -C "$repo" init -q
    local sub_json="{\"cwd\":\"$repo/sub\"}"
    run --separate-stderr inject - "$REPO" "$sub_json"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "guard(git env 隔離): GIT_DIR/GIT_WORK_TREE leak でも無関係 cwd は過剰注入しない(gate self-check)" {
    # .beads を持つ別 repo の GIT_DIR/GIT_WORK_TREE を export した状態で、.beads 無しの
    # 無関係 cwd から実行。env 隔離が無いと toplevel がリーク先 repo に解決し過剰注入する
    # → 隔離済み(_scribe_has_beads の env -u)なら無出力 exit 0(bd un-7hx・#1 堅牢化の回帰ネット)。
    local leak="$BATS_TEST_TMPDIR/leakrepo"
    mkdir -p "$leak/.beads"
    git -C "$leak" init -q
    local unrel="$BATS_TEST_TMPDIR/unrelated"
    mkdir -p "$unrel"
    run --separate-stderr bash -c "cd '$unrel' && printf '%s' '{\"cwd\":\"$unrel\"}' | env -u SCRIBE_ROLE GIT_DIR='$leak/.git' GIT_WORK_TREE='$leak' CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- cwd ソース: stdin 無し → $PWD フォールバック ----
@test "cwd ソース: stdin JSON に cwd 無し → \$PWD フォールバック(worktree から実行→worker)" {
    # $PWD を worktree っぽいパスにして実行(cwd 抽出が空 → PWD フォールバック検証)。
    # .beads opt-in guard を通すため .beads も置く(bd un-7hx)。
    local d="$BATS_TEST_TMPDIR/.worktrees/spawn/z-1"
    mkdir -p "$d/.beads"
    run --separate-stderr bash -c "cd '$d' && printf '%s' '$EMPTY_JSON' | env -u SCRIBE_ROLE CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
}

@test "guard(\$PWD フォールバック × .beads 無し): 注入ゼロ(acceptance #2 を両 cwd ソースで実証・gate self-check)" {
    # 実 paper-leak 経路 = JSON に cwd が無く $PWD へ倒れるケース。$PWD が .beads を
    # 持たない非 worktree なら無出力 exit 0(test 21 の negative 対・bd un-7hx)。
    local d="$BATS_TEST_TMPDIR/pwd-nobeads"
    mkdir -p "$d"
    run --separate-stderr bash -c "cd '$d' && printf '%s' '$EMPTY_JSON' | env -u SCRIBE_ROLE CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ---- cwd 抽出: jq 不在環境で sed フォールバック分岐を強制(回帰ネット) ----
@test "cwd 抽出: jq 不在(restricted PATH)→ sed フォールバックで cwd 解決(worktree→worker)" {
    # jq を PATH から外し _scribe_extract_json_string の sed 分岐(else)を強制実行する。
    # script が sed 分岐でも cwd を正しく抽出し role=worker を出すことを assert(片系統の回帰検知)。
    local bindir="$BATS_TEST_TMPDIR/nojq-bin"
    mkdir -p "$bindir"
    local b
    for b in bash env dirname cat sed head awk; do
        ln -sf "$(command -v "$b")" "$bindir/$b"
    done
    # jq は意図的にリンクしない → script の `command -v jq` が失敗 → sed フォールバック
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE= CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$WT_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"cwd .worktrees/"* ]]
}

# ---- 本文抽出器(awk)不在: worker/consult は明示 warning で degrade・admin は無傷 ----
# awk を PATH から外し本文抽出(_scribe_emit_*)を不能にする。worker/consult が「header のみの
# サイレント部分注入」に陥らず、exit 0 を維持しつつ stderr へ明示 warning を出して degrade する
# ことを assert(規約本文の silent drop 防止・errata wf_f51949b7)。
_link_bin_without_awk() {
    local bindir="$1" b
    mkdir -p "$bindir"
    for b in bash env dirname cat sed head jq; do
        ln -sf "$(command -v "$b")" "$bindir/$b"
    done
    # awk は意図的にリンクしない → command -v awk が失敗
}

@test "awk 不在(restricted PATH): worker は exit 0 維持で degrade・stderr に明示 warning" {
    local bindir="$BATS_TEST_TMPDIR/noawk-worker"
    _link_bin_without_awk "$bindir"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE= CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$WT_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"awk not found"* ]]
    [[ "$stderr" == *"worker"* ]]
}

@test "awk 不在(restricted PATH): consult は exit 0 維持で degrade・stderr に明示 warning" {
    local bindir="$BATS_TEST_TMPDIR/noawk-consult"
    _link_bin_without_awk "$bindir"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE=consult CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$ANCHOR_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"awk not found"* ]]
    [[ "$stderr" == *"consult"* ]]
}

@test "awk 不在(restricted PATH): admin は cat 経路で無傷(本文を注入する)" {
    local bindir="$BATS_TEST_TMPDIR/noawk-admin"
    _link_bin_without_awk "$bindir"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE=admin CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$ANCHOR_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate funnel"* ]]
    [[ "$output" == *"dolt push 同期点"* ]]
}

# ---- role 別注入内容の必須キーワード(spec §2.1-2.3) ----
@test "注入(admin): gate funnel / errata / dolt push 同期点 を含む" {
    run --separate-stderr inject admin "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate funnel"* ]]
    [[ "$output" == *"errata"* ]]
    [[ "$output" == *"dolt push 同期点"* ]]
}

@test "注入(worker): bd create/dep/dolt push 禁止 / bdw / notes 提案 を含む" {
    run --separate-stderr inject worker "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"bd create"* ]]
    [[ "$output" == *"bd dep"* ]]
    [[ "$output" == *"bd dolt push"* ]]
    [[ "$output" == *"bdw"* ]]
    [[ "$output" == *"notes で提案"* ]]
}

@test "注入(worker): protocol.md の §2/§3/§4 のみ(§1/§5/§6 は出さない)" {
    run --separate-stderr inject worker "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"## 2. worker prompt 規約"* ]]
    [[ "$output" == *"## 3. B/hybrid 役割境界"* ]]
    [[ "$output" == *"## 4. gate-pending → gate → close → errata 規約"* ]]
    [[ "$output" != *"## 1. spawn 規約"* ]]
    [[ "$output" != *"## 5. gate funnel 手順"* ]]
    [[ "$output" != *"## 6. 監視"* ]]
}

@test "注入(consult): read-only / 記憶系のみ / サマリ保存義務 / 暫定運用 を含む" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"read-only"* ]]
    [[ "$output" == *"記憶系のみ"* ]]
    [[ "$output" == *"サマリ保存義務"* ]]
    # TODO(un-sl9 / sc-gfm): 「暫定運用」条項は un-sl9 検証完了で role-context-spec.md:98 ごと撤去される。
    # これは brittle な偶発 fail でなく**意図的 tripwire**＝撤去時にこの assertion も削除すべきことを loud に
    # 知らせる（同リポの doc 編集で即 fail するため撤去漏れを検知できる）。un-sl9 完了時はこの 1 行を削除する。
    [[ "$output" == *"暫定運用"* ]]
}

@test "注入(consult): §2.3 のみ抽出(§2.1 admin / §2.2 worker 見出し本文は混入しない)" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"### 2.3 consult"* ]]
    [[ "$output" != *"### 2.1 admin"* ]]
    [[ "$output" != *"### 2.2 worker"* ]]
    [[ "$output" != *"## 3. C2"* ]]
}

@test "注入(consult): grill 専任 / read-only 限定緩和(自 grill-issue notes) / grill-consult を含む(sc-cuw 再編)" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    # consult は grill 専任(原義回帰)・grill-consult は admin が brief を渡して立てる第 2 対話相手。
    [[ "$output" == *"grill 専任"* ]]
    [[ "$output" == *"grill-consult"* ]]
    # read-only 限定緩和: 自 grill-issue の --claim(着手時 1 回限り・orch-3ej3)/--append-notes だけ bdw 経由で可(worker B/hybrid と一致)。
    [[ "$output" == *"限定緩和"* ]]
    [[ "$output" == *"--append-notes"* ]]
    [[ "$output" == *"bdw"* ]]
    # pre-bake は WF へ移管(consult の仕事ではない)。
    [[ "$output" == *"needs-user-prebake.workflow.js"* ]]
}

# ---- fail-safe: doc 不在で exit 0 degrade ----
@test "fail-safe(admin): protocol.md 不在 → exit 0・stdout 無注入・stderr 警告" {
    run --separate-stderr inject - "$BATS_TEST_TMPDIR" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"protocol.md 不在"* ]]
}

@test "fail-safe(worker): protocol.md 不在 → exit 0・stdout 無注入・stderr 警告" {
    run --separate-stderr inject - "$BATS_TEST_TMPDIR" "$WT_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"protocol.md 不在"* ]]
}

@test "fail-safe(consult): role-context-spec.md 不在 → exit 0・stdout 無注入・stderr 警告" {
    run --separate-stderr inject consult "$BATS_TEST_TMPDIR" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"role-context-spec.md 不在"* ]]
}

# ---- hooks.json ----
@test "hooks.json: valid JSON" {
    run jq -e . "$HOOKS_JSON"
    [ "$status" -eq 0 ]
}

@test "hooks.json: SessionStart wire が inject script を参照する" {
    run jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"session-start-role-inject.sh"* ]]
    [[ "$output" == *"[ -x"* ]]
}

@test "hooks.json: 安全形 dynamic — script 不在(CLAUDE_PLUGIN_ROOT 異常)で exit 0・副作用ゼロ" {
    # spec §3 selftest 強化引き継ぎ: 見せかけガードの false-PASS を防ぐため、
    # 実コマンドを未存在 CLAUDE_PLUGIN_ROOT で実行し exit 0 + stdout/stderr 空をドライラン観測。
    local cmd
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")"
    run --separate-stderr env CLAUDE_PLUGIN_ROOT="$BATS_TEST_TMPDIR/nonexistent" bash -c "$cmd"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
}

@test "hooks.json: wire が live script を起動する(end-to-end・admin 既定)" {
    local cmd
    cmd="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON")"
    run --separate-stderr env -u SCRIBE_ROLE CLAUDE_PLUGIN_ROOT="$REPO" bash -c "$cmd" <<< "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"gate funnel"* ]]
}

# ---- 機械防御 carrier self-check（split-brain 検出・sc-99c） ----
# worker 分類は cwd で行われるが、機械防御（edit-write-guard / env-probe / sentinel / effort）は
# scribe-spawn の env signal（SCRIBE_WORKER=1 / SCRIBE_WORKTREE）と spawn prompt が唯一の carrier。
# scribe-spawn を経ない CC-native worktree（.claude/worktrees/）は worker 分類されても防御ゼロになる
# （split-brain）。role-inject は SCRIBE_WORKER/SCRIBE_WORKTREE 不在を検査し loud warning を注入する。
# 注: SCRIBE_WORKER/SCRIBE_WORKTREE は ambient env から継承されうる（本 test は scribe worker window で
#     走りうる）ため、各ケースで env -u / 明示代入して決定論化する。

@test "機械防御(sc-99c): 非 spawn worker(SCRIBE_WORKER 不在・CC-native worktree) → 機械防御無効の loud warning を注入" {
    run --separate-stderr bash -c "printf '%s' '$CC_WT_JSON' | env -u SCRIBE_ROLE -u SCRIBE_WORKER -u SCRIBE_WORKTREE CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    # loud warning ブロック固有の signature（§2 本文の carrier モデル散文にも「機械防御が無効」の
    # 語は現れるため、warning ブロックだけが持つ文言で discriminate する＝docs prose への誤一致回避）
    [[ "$output" == *"このセッションは scribe-spawn 経由ではありません"* ]]
    [[ "$output" == *"edit-write-guard.py"* ]]
    [[ "$output" == *"起動し直す"* ]]
    # §2-4 本文は従来どおり注入される（warning は追加であって置換ではない）
    [[ "$output" == *"## 2. worker prompt 規約"* ]]
    # §2-4-only 不変条件を warning が壊さない（禁止見出しを混ぜない）
    [[ "$output" != *"## 1. spawn 規約"* ]]
    [[ "$output" != *"## 5. gate funnel 手順"* ]]
    [[ "$output" != *"## 6. 監視"* ]]
    # ultracode リマインダ（admin 専用）が混入しない回帰も兼ねる
    [[ "$output" != *"/effort ultracode"* ]]
}

@test "機械防御(sc-99c): spawn worker(SCRIBE_WORKER=1 + 実在 SCRIBE_WORKTREE) → warning を出さない" {
    run --separate-stderr bash -c "printf '%s' '$WT_JSON' | env -u SCRIBE_ROLE SCRIBE_WORKER=1 SCRIBE_WORKTREE='$WT_DIR' CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    # 機械防御が active なので split-brain warning ブロックは出さない（誤警報ゼロ）。§2 本文の
    # carrier モデル散文（「機械防御が無効」の語を含む）は出るため、warning ブロック固有の signature で判定。
    [[ "$output" != *"このセッションは scribe-spawn 経由ではありません"* ]]
    [[ "$output" != *"境界を確立できません"* ]]
    # 従来どおり §2 本文は注入される
    [[ "$output" == *"## 2. worker prompt 規約"* ]]
}

@test "機械防御(sc-99c): SCRIBE_WORKER=1 だが SCRIBE_WORKTREE 不正 → 境界確立不能 warning を注入" {
    run --separate-stderr bash -c "printf '%s' '$WT_JSON' | env -u SCRIBE_ROLE -u SCRIBE_WORKTREE SCRIBE_WORKER=1 CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    # SCRIBE_WORKTREE 不在 = edit-write-guard は fail-closed（全 Edit block）ゆえ別文言で警告する
    [[ "$output" == *"境界を確立できません"* ]]
    [[ "$output" == *"edit-write-guard.py"* ]]
    # §2 本文は従来どおり注入される
    [[ "$output" == *"## 2. worker prompt 規約"* ]]
}

# ---- docs SSOT pin（carrier モデルが protocol.md §2 に成文化されている・sc-99c drift 停止） ----
@test "docs(sc-99c): protocol.md §2 に機械防御 carrier モデル（split-brain・SCRIBE_WORKER）が SSOT 化されている" {
    local proto="$REPO/docs/protocol.md"
    grep -q '機械防御の carrier は scribe-spawn' "$proto"
    grep -q 'split-brain' "$proto"
    grep -q 'SCRIBE_WORKER' "$proto"
    grep -q 'SCRIBE_WORKTREE' "$proto"
    # role-inject の warning 本文 SSOT がここである旨（両 carrier がこれを引く＝drift 停止）
    grep -q 'session-start-role-inject.sh' "$proto"
}

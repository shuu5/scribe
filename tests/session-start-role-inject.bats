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
    PROTOCOL="$REPO/docs/protocol.md"

    # --- boot core（progressive disclosure・sc-x93w / orch-db47 leg(1)）の pin 材料 ---------------
    # 注入は protocol.md 全文 cat / §2-4 awk 抽出から **doc 側 sentinel 区間の boot core** へ変わった。
    # ★再武装の設計（■10-3）: pin は必ず **core 固有 literal**（script の header / intro が供給しない語）
    #   から採る。header・intro だけで green になる pin は、core 区間を空にしても緑のままで空虚になる
    #   （反 false-green 確認 = 下の "反 false-green" test が実際に flip を測る）。
    CORE_ADMIN_SENTINEL="scribe-core-admin"
    CORE_WORKER_SENTINEL="scribe-core-worker"
    CORE_ADMIN_TRIGGER='**trigger 表（admin・'
    CORE_ADMIN_INVARIANT='**完了 truth = bd**'
    CORE_ADMIN_APPROVAL='**承認は 3 クラス + snapshot-mismatch だけ**'
    CORE_WORKER_TRIGGER='**trigger 表（worker・'
    CORE_WORKER_DONE2='**順序を逆にしない**'
    CORE_WORKER_AUTONOMY='**停止してよいのは 2 例外だけ**'

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
    # ★再武装（sc-x93w ■10-3）: 上 3 本は header/intro だけで green になり「本文注入は不変」を測れない
    #   （core 区間を空にしても緑）。core 固有 literal を足して suppress が本文を巻き添えにしないことを pin。
    [[ "$output" == *"$CORE_ADMIN_TRIGGER"* ]]
    [[ "$output" == *"$CORE_ADMIN_INVARIANT"* ]]
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

@test "guard(.beads 有・CC-native worktree): worker は従来どおり注入する(boot core) (sc-vwm)" {
    # sc-x93w retarget: 旧 pin は `## 2. worker prompt 規約`（§2-4 全文注入時代の見出し）だったが、
    # 注入は doc 側 sentinel 区間の boot core へ変わった。core 固有 literal（header/intro が供給しない）
    # へ移し、注入が実際に届いていることの検知力を等価以上に保つ。
    run --separate-stderr inject - "$REPO" "$CC_WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_DONE2"* ]]
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
    # ★再武装（sc-x93w ■10-3）: `gate funnel` は intro が供給するため core が空でも green だった。
    [[ "$output" == *"$CORE_ADMIN_TRIGGER"* ]]
    [[ "$output" == *"$CORE_ADMIN_APPROVAL"* ]]
}

@test "guard(.beads 有・worktree): worker は従来どおり注入する" {
    run --separate-stderr inject - "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    # ★再武装（sc-x93w ■10-3）: role 行は header が供給するため本文ゼロでも green だった。
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_AUTONOMY"* ]]
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

# ---- 本文抽出器の依存を awk から sed へ移した（sc-x93w・■6）: awk 不在でも 3 role とも本文が届く ----
# 旧実装は worker/consult の本文抽出が awk 単一依存で、awk 不在ホストでは「明示 warning を出して
# 何も注入しない」degrade に落ちていた（admin だけが cat 経路で無傷）。sc-x93w で抽出を **sed のみ**へ
# 移したため degrade 自体が不要になり、この 2 本は **強化側の RED** になった（■6-2）。assert を削除せず
# 「awk 不在でも 3 role とも規約本文が届く」へ retarget する（degrade 検知 → 無 degrade 検知の等価以上）。
# admin を awk 非依存に保つ要件（■6-3）は 3 本目がそのまま担い続ける。
# restricted PATH が張るのは bash env dirname cat sed head jq のみ＝python3 も timeout も無い環境で、
# emit-budget lib は fail-open（計測を諦め本文だけ出す）に落ちる。本文が出続けることが本 test の核。
_link_bin_without_awk() {
    local bindir="$1" b
    mkdir -p "$bindir"
    for b in bash env dirname cat sed head jq; do
        ln -sf "$(command -v "$b")" "$bindir/$b"
    done
    # awk は意図的にリンクしない → 抽出経路が awk を要求するなら本文がゼロになる
}

@test "awk 不在(restricted PATH): worker へ規約本文(boot core)が届く(sed 抽出＝awk 非依存)" {
    local bindir="$BATS_TEST_TMPDIR/noawk-worker"
    _link_bin_without_awk "$bindir"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE= CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$WT_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_DONE2"* ]]
    [[ "$stderr" != *"awk not found"* ]]        # awk 依存の degrade 経路は消滅している
}

@test "awk 不在(restricted PATH): consult へ規約本文(§2.3)が届く(sed 抽出＝awk 非依存)" {
    local bindir="$BATS_TEST_TMPDIR/noawk-consult"
    _link_bin_without_awk "$bindir"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE=consult CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$ANCHOR_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=consult"* ]]
    [[ "$output" == *"### 2.3 consult"* ]]
    [[ "$output" == *"サマリ保存"* ]]
    [[ "$stderr" != *"awk not found"* ]]
}

@test "awk 不在(restricted PATH): admin へ規約本文(boot core)が届く(■6-3・admin を awk 依存にしない)" {
    local bindir="$BATS_TEST_TMPDIR/noawk-admin"
    _link_bin_without_awk "$bindir"
    run --separate-stderr env -i PATH="$bindir" SCRIBE_ROLE=admin CLAUDE_PLUGIN_ROOT="$REPO" \
        bash -c "printf '%s' '$ANCHOR_JSON' | '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"gate funnel"* ]]                 # intro 由来（従来 pin を維持）
    [[ "$output" == *"dolt push 同期点"* ]]            # intro 由来（従来 pin を維持）
    [[ "$output" == *"$CORE_ADMIN_TRIGGER"* ]]         # ★再武装: core 固有 literal（■10-3）
    [[ "$output" == *"$CORE_ADMIN_APPROVAL"* ]]
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

@test "注入(worker): boot core 区間のみ(§1/§5/§6 の本文は出さない・admin core も混入しない)" {
    # sc-x93w retarget: positive 3 本（§2/§3/§4 の見出し literal）は core 化で構造的に出なくなったため、
    # **同じ 3 節をカバーする core 固有 literal**（§3=禁止 / §4=完了 2 段 / §2=自律規律）へ置換する。
    # negative 3 本（§1/§5/§6 の非注入）は**そのまま維持**し、さらに admin core の非混入を追加して
    # 「区間を跨いだ過剰注入」まで pin する（検知力は等価以上・assert 削除 0）。
    run --separate-stderr inject worker "$REPO" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"**follow-up は自分で起票しない**"* ]]      # §3 相当（旧 `## 3.` pin の代替）
    [[ "$output" == *"$CORE_WORKER_DONE2"* ]]                     # §4 相当（旧 `## 4.` pin の代替）
    [[ "$output" == *"$CORE_WORKER_AUTONOMY"* ]]                  # §2 相当（旧 `## 2.` pin の代替）
    [[ "$output" != *"## 1. spawn 規約"* ]]
    [[ "$output" != *"## 5. gate funnel 手順"* ]]
    [[ "$output" != *"## 6. 監視"* ]]
    # 区間跨ぎの過剰注入（admin core が worker へ漏れる）を塞ぐ
    [[ "$output" != *"$CORE_ADMIN_TRIGGER"* ]]
    [[ "$output" != *"$CORE_ADMIN_APPROVAL"* ]]
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

# ---- sc-pegi: §2.3 モデル規約の docs teeth（新既定 opus[1m]・裁定履歴の保存） ----
# 背景: 改訂前は docs の model 記述を pin する assert が repo 内に 1 本も無く、docs の
# acceptance は構造的に空虚だった（sc-pegi・admin 実測）。以下 2 本がその teeth。
# literal 検索は必ず固定文字列モード（grep -F / bash の二重引用部分一致）で行う——`opus[1m]` を
# 未 escape の正規表現で探すと bracket expression 化して常に不一致になり false-green になる。
@test "注入(consult/sc-pegi): §2.3 の新既定 opus[1m] が注入本文に届く(§2.3 抽出 awk を通過している)" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    # positive: 新既定が注入本文に出る＝doc 改訂が consult セッションまで到達している。
    # （§2.3 節内に水平線を入れると以降が silent に注入から脱落するため、この assert は
    #   FENCE-SECTION-2.3 の tripwire も兼ねる: モデル規約は 2.3 節の後半にある。）
    [[ "$output" == *"opus[1m]"* ]]
    # negative: 旧既定文言（sc-9q6 の「既定 **fable**」）が現役規約として残っていない。
    [[ "$output" != *"既定 **fable**"* ]]
}

@test "docs(sc-pegi): role-context-spec §2.3 は新既定 opus[1m] を持ち裁定履歴(sc-9q6 / sc-pegi)を消さない" {
    local f="$REPO/docs/role-context-spec.md"
    run grep -Fq -- 'opus[1m]' "$f"
    [ "$status" -eq 0 ]
    # 裁定の履歴を消さない契約の teeth: 上書きされた旧裁定 id と、上書きした本裁定 id の両方が残る。
    run grep -Fq -- 'sc-9q6' "$f"
    [ "$status" -eq 0 ]
    run grep -Fq -- 'sc-pegi' "$f"
    [ "$status" -eq 0 ]
    # negative: 旧「既定 **fable**」は現役規約として不在（履歴として言及する文とは literal が異なる）。
    run grep -Fq -- '既定 **fable**' "$f"
    [ "$status" -ne 0 ]
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
    # ★再武装（sc-x93w ■10-3）: wire 経由でも **doc 側 core 本文**まで届くことを end-to-end で pin する
    #   （`gate funnel` は intro 由来ゆえ core 空でも green だった）。
    [[ "$output" == *"$CORE_ADMIN_TRIGGER"* ]]
    [[ "$output" == *"$CORE_ADMIN_INVARIANT"* ]]
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
    # boot core 本文は従来どおり注入される（warning は追加であって置換ではない・sc-x93w retarget）
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_AUTONOMY"* ]]
    # core-only 不変条件を warning が壊さない（禁止見出しを混ぜない）
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
    # 従来どおり boot core 本文は注入される（sc-x93w retarget: `## 2.` 見出し → core 固有 literal）
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_DONE2"* ]]
}

@test "機械防御(sc-99c): SCRIBE_WORKER=1 だが SCRIBE_WORKTREE 不正 → 境界確立不能 warning を注入" {
    run --separate-stderr bash -c "printf '%s' '$WT_JSON' | env -u SCRIBE_ROLE -u SCRIBE_WORKTREE SCRIBE_WORKER=1 CLAUDE_PLUGIN_ROOT='$REPO' '$SCRIPT'"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]
    # SCRIBE_WORKTREE 不在 = edit-write-guard は fail-closed（全 Edit block）ゆえ別文言で警告する
    [[ "$output" == *"境界を確立できません"* ]]
    [[ "$output" == *"edit-write-guard.py"* ]]
    # boot core 本文は従来どおり注入される（sc-x93w retarget: `## 2.` 見出し → core 固有 literal）
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_DONE2"* ]]
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

# ---- boot core sentinel（progressive disclosure・sc-x93w / orch-db47 leg(1)）の新設 teeth ----
#
# 設計の核（■5-4 / ■10-6）: 抽出器は begin/end が **各ちょうど 1 個で begin が先** を検査し、満たさない
# ときは「空でない部分抽出」を黙って返さず **rc 非 0（fail-loud）** にする。hook 本体は fail-open を保ち
# （stderr へ warn・exit 0・無出力）セッションを壊さない。sentinel 区間を**空にすると**上流の core 固有
# pin が RED へ flip する——これが「pin が非空虚である」ことの実測（推論でなく mutation で示す）。
#
# 変異は $BATS_TEST_TMPDIR 上の mutant plugin root（docs だけ差し替えたコピー）に対して行い、
# 本物の docs/protocol.md と git 履歴を汚さない。

# _mutant_root <dst> — $REPO の docs/ と scripts/ を symlink ではなく実体コピーで持つ最小 plugin root
_mutant_root() {
    local dst="$1"
    mkdir -p "$dst/docs" "$dst/scripts/hooks/lib"
    cp "$REPO/docs/protocol.md" "$dst/docs/protocol.md"
    cp "$REPO/docs/role-context-spec.md" "$dst/docs/role-context-spec.md"
    cp "$REPO/scripts/hooks/session-start-role-inject.sh" "$dst/scripts/hooks/"
    cp "$REPO/scripts/hooks/lib/emit_budget.sh" "$dst/scripts/hooks/lib/"
}

@test "sentinel: protocol.md に boot core 区間が admin/worker とも begin/end 各 1 個で実在する" {
    local n
    for name in "$CORE_ADMIN_SENTINEL" "$CORE_WORKER_SENTINEL"; do
        n="$(grep -cF -- "<!-- ${name}:begin -->" "$PROTOCOL")"
        [ "$n" -eq 1 ]
        n="$(grep -cF -- "<!-- ${name}:end -->" "$PROTOCOL")"
        [ "$n" -eq 1 ]
    done
    # sentinel 名は canonical-3class-block-v2 と別名（■5-3・同名は将来 carrier 追加時に occurrence pin を崩す）
    [ "$CORE_ADMIN_SENTINEL" != "canonical-3class-block-v2" ]
    [ "$CORE_WORKER_SENTINEL" != "canonical-3class-block-v2" ]
}

@test "sentinel: 区間が空でも end sentinel 行を本文として吐かない（範囲アドレス縮退の封鎖）" {
    # sed の `addr1,addr2` は addr2 < addr1 のとき **addr1 の 1 行だけ**を出す。抽出器がこれを
    # 数値で先に弾かないと、空区間で end sentinel の HTML コメントを規約本文として注入してしまう。
    local root="$BATS_TEST_TMPDIR/mut-empty"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_WORKER_SENTINEL" <<'PY'
import re, sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
b, e = f"<!-- {name}:begin -->", f"<!-- {name}:end -->"
i, j = s.index(b), s.index(e)
open(p, "w", encoding="utf-8").write(s[:i] + b + "\n" + s[j:])
PY
    run --separate-stderr inject worker "$root" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" != *"<!--"* ]]                       # sentinel 行そのものを本文として出さない
    [[ "$output" != *"$CORE_WORKER_TRIGGER"* ]]       # 区間が空なので core は 1 行も出ない
}

@test "反 false-green(■10-6): worker core 区間を空にすると core 固有 pin が RED へ flip する" {
    local root="$BATS_TEST_TMPDIR/mut-hollow-worker"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_WORKER_SENTINEL" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
b, e = f"<!-- {name}:begin -->", f"<!-- {name}:end -->"
i, j = s.index(b), s.index(e)
open(p, "w", encoding="utf-8").write(s[:i] + b + "\n" + s[j:])
PY
    # clean 側は green（pin が実際に本文を掴んでいる）
    run --separate-stderr inject worker "$REPO" "$WT_JSON"
    [[ "$output" == *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" == *"$CORE_WORKER_DONE2"* ]]
    [[ "$output" == *"$CORE_WORKER_AUTONOMY"* ]]
    [[ "$output" == *"bdw"* ]]
    # 変異側は同じ pin がすべて落ちる＝pin は非空虚（header/intro だけでは充足されない）
    run --separate-stderr inject worker "$root" "$WT_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=worker"* ]]                # header/intro は出続ける（＝pin の充足源ではない）
    [[ "$output" != *"$CORE_WORKER_TRIGGER"* ]]
    [[ "$output" != *"$CORE_WORKER_DONE2"* ]]
    [[ "$output" != *"$CORE_WORKER_AUTONOMY"* ]]
    [[ "$output" != *"bdw"* ]]
    # ★実測メモ（■10-4 の「落ちるか実行して確かめる」）: `bd create` / `bd dep` / `bd dolt push` /
    #   `notes で提案` は **worker intro が同じ字面を供給する**ため core を空にしても green のままになる
    #   ＝出力 grep だけでは ■9-4 の 6 要素保持を測れない。だから下の doc-level teeth で core 区間自体を pin する。
    [[ "$output" == *"bd create"* ]]
    [[ "$output" == *"notes で提案"* ]]
}

@test "core 内容(■9-4): worker core 区間が 6 要素（bd create/dep/dolt push・bdw・notes で提案・自 worktree 境界）を保持する" {
    # 出力 grep は intro が同じ字面を供給するため空虚になりうる（上の実測メモ）。ゆえに **doc 側 core 区間を
    # 直接抽出**して 6 要素を pin する＝trim で core から要素が落ちた瞬間に RED になる。
    local core
    core="$(sed -n "/<!-- ${CORE_WORKER_SENTINEL}:begin -->/,/<!-- ${CORE_WORKER_SENTINEL}:end -->/p" "$PROTOCOL")"
    [ -n "$core" ]
    [[ "$core" == *'`bd create`'* ]]
    [[ "$core" == *'`bd dep`'* ]]
    [[ "$core" == *'`bd dolt push`'* ]]
    [[ "$core" == *'`bdw`'* ]]
    [[ "$core" == *"notes で提案"* ]]
    [[ "$core" == *"自 worktree の中だけ"* ]]
    # 自己 close / 自己 merge 禁止（■2 の §4 分割）も core に残る
    [[ "$core" == *'`bd close`'* ]]
    [[ "$core" == *"自己 merge しない"* ]]
}

@test "core 内容(■9-2/■9-5): admin core が禁止・境界・承認・trigger 表 3 行以上を保持する" {
    local core n
    core="$(sed -n "/<!-- ${CORE_ADMIN_SENTINEL}:begin -->/,/<!-- ${CORE_ADMIN_SENTINEL}:end -->/p" "$PROTOCOL")"
    [ -n "$core" ]
    # trigger 表は 3 行以上（spawn 前→§1 / gate 前→§5 / 承認迷い→§5.4）
    # count は herestring で取る（pipefail 下の `producer | grep -c` は SIGPIPE 偽 RED の原因・protocol §2）
    n="$(grep -c '^- \*\*.*→ §' <<< "$core" || true)"
    [ "$n" -ge 3 ]
    # ★1 行 1 assert（`[[ A ]] && [[ B ]]` と書かない）: AND-OR リストの非最終要素は bash の
    #   errexit 免除規則で失敗しても落ちない＝前 2 本が vacuous になる（tests/scribe-account-select.bats
    #   :835 で明文化済みの既知 footgun・本 leg の cell-quality gate が実測で再確認）。
    [[ "$core" == *"§1"* ]]
    [[ "$core" == *"§5"* ]]
    [[ "$core" == *"§5.4"* ]]
    # 禁止・不可逆・fail-closed・境界（■9-2 で落としてはならない側）
    [[ "$core" == *"fail-closed"* ]]
    [[ "$core" == *"read に留め write しない"* ]]      # 台帳 write 境界
    [[ "$core" == *"消す / 出す / 使う"* ]]            # 承認 3 クラス
    [[ "$core" == *"自己 close も自己 merge もしない"* ]]  # gate 分離
    [[ "$core" == *"完了 truth = bd"* ]]
    # transport の**禁止**側（no-push）は ■2 の「core に 2 行」＝構造封鎖だけでは半分。co-submit は事後検知が
    # 原理的に不可能（§6）で、§6 全文は boot で届かない＝この 1 行を落とすと boot 時点でどこからも届かない。
    [[ "$core" == *"no-push"* ]]
    [[ "$core" == *"INJECT_DEFERRED"* ]]
    [[ "$core" == *"握りつぶして再送しない"* ]]
    # ■4-5: core 本文へ既存の negative / occurrence pin に当たる literal を書かない
    [[ "$core" != *"## 1. spawn 規約"* ]]
    [[ "$core" != *"## 5. gate funnel 手順"* ]]
    [[ "$core" != *"## 6. 監視"* ]]
    [[ "$core" != *"## 8. cross-ledger 境界"* ]]
    [[ "$core" != *"【人間確認が要るのは"* ]]
    [[ "$core" != *"① 配備層 file を touch しない"* ]]
}

@test "反 false-green(■10-6): admin core 区間を空にすると core 固有 pin が RED へ flip する" {
    local root="$BATS_TEST_TMPDIR/mut-hollow-admin"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_ADMIN_SENTINEL" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
b, e = f"<!-- {name}:begin -->", f"<!-- {name}:end -->"
i, j = s.index(b), s.index(e)
open(p, "w", encoding="utf-8").write(s[:i] + b + "\n" + s[j:])
PY
    run --separate-stderr inject admin "$REPO" "$ANCHOR_JSON"
    [[ "$output" == *"$CORE_ADMIN_TRIGGER"* ]]
    [[ "$output" == *"$CORE_ADMIN_INVARIANT"* ]]
    [[ "$output" == *"errata"* ]]
    run --separate-stderr inject admin "$root" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"role=admin"* ]]
    [[ "$output" == *"gate funnel"* ]]                # intro は生きている＝旧 pin が空虚だった証拠
    [[ "$output" != *"$CORE_ADMIN_TRIGGER"* ]]
    [[ "$output" != *"$CORE_ADMIN_INVARIANT"* ]]
    [[ "$output" != *"errata"* ]]
}

@test "fail-loud(■5-4): begin sentinel を削ると抽出器は空を返さず degrade（無注入・exit 0・stderr warn）" {
    local root="$BATS_TEST_TMPDIR/mut-nobegin"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_WORKER_SENTINEL" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace(f"<!-- {name}:begin -->\n", "", 1))
PY
    run --separate-stderr inject worker "$root" "$WT_JSON"
    [ "$status" -eq 0 ]                                # hook 本体は fail-open（session を壊さない）
    [ -z "$output" ]                                   # 部分注入を黙って出さない（fail-loud の効果）
    [[ "$stderr" == *"boot core 区間"* ]]
    [[ "$stderr" == *"$CORE_WORKER_SENTINEL"* ]]
}

@test "fail-loud(■5-4): begin sentinel が 2 個あると degrade（無注入・exit 0・stderr warn）" {
    local root="$BATS_TEST_TMPDIR/mut-dupbegin"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_ADMIN_SENTINEL" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
b = f"<!-- {name}:begin -->"
open(p, "w", encoding="utf-8").write(s.replace(b, b + "\n" + b, 1))
PY
    run --separate-stderr inject admin "$root" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"boot core 区間"* ]]
}

@test "fail-loud(■5-4): begin/end が逆順でも degrade（範囲が EOF まで暴走しない）" {
    local root="$BATS_TEST_TMPDIR/mut-swapped"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_WORKER_SENTINEL" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
b, e = f"<!-- {name}:begin -->", f"<!-- {name}:end -->"
i, j = s.index(b), s.index(e)
# begin と end を入れ替える（end が先・begin が後）
s = s[:i] + e + s[i + len(b):j] + b + s[j + len(e):]
open(p, "w", encoding="utf-8").write(s)
PY
    run --separate-stderr inject worker "$root" "$WT_JSON"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [[ "$stderr" == *"boot core 区間"* ]]
}

# _head_contract <role> <plugin_root>  — stdin = 注入出力。先頭 1,000 u16 が acceptance(1) の 4 要素
#   (i) 「これは要約」自衛文 (ii) 自 role の規約 SSOT doc の**絶対** path (iii) Read 指示 (iv) trigger 表
#   を満たすかを検査し、**assert でなく rc** を返す（rc=0 合格 / 非 0 不合格）。rc 形にするのが load-bearing:
#   clean で green・mutant で RED を**同じ判定器**で両側 pin でき、反 false-green を実測できる。
# ★pin の採り方（gate finding 由来の retarget）: 旧実装は `"Read"` / `".md" and "/"` / `"trigger"` の 3 本で、
#   いずれも **script の intro 行が単独で供給する**ため core を空にしても green だった（＝4 要素中 3 要素が
#   実質未検証）。ゆえに (i) は自衛文の逐語 literal、(ii) は「行から path を切り出して先頭が `/`」+ 実行時
#   展開値との一致、(iv) は **doc 側 core の表行**（intro 散文の "trigger" では代替できない語）で測る。
_head_contract() {
    local role="$1" root="$2" guard doc coreline
    case "$role" in
        admin)   guard='以下は規約の要約';   doc="$root/docs/protocol.md";          coreline="$CORE_ADMIN_TRIGGER" ;;
        worker)  guard='以下は規約の要約';   doc="$root/docs/protocol.md";          coreline="$CORE_WORKER_TRIGGER" ;;
        consult) guard='規約の全体ではない'; doc="$root/docs/role-context-spec.md"; coreline='### 2.3 consult' ;;
        *)       echo "unknown role: $role" >&2; return 2 ;;
    esac
    python3 -c '
import re, sys
guard, doc, coreline = sys.argv[1], sys.argv[2], sys.argv[3]
h = sys.stdin.buffer.read().decode("utf-8", "replace").strip().encode("utf-16-le")[:2000].decode("utf-16-le", "ignore")
bad = []
if guard not in h:
    bad.append("(i) 自衛文が先頭 1,000 u16 に無い: " + guard)
if "Read" not in h:
    bad.append("(iii) Read 指示が先頭 1,000 u16 に無い")
m = re.search(r"規約 SSOT[^`]*`([^`]+)`", h)
if m is None:
    bad.append("(ii) 規約 SSOT 行から doc path を切り出せない")
else:
    p = m.group(1)
    if not p.startswith("/"):
        bad.append("(ii) SSOT doc の path が絶対でない: " + p)
    elif p != doc:
        bad.append("(ii) SSOT doc の path が実行時展開値と一致しない: " + p + " != " + doc)
if coreline not in h:
    bad.append("(iv) doc 側 core の trigger 行が先頭 1,000 u16 に無い: " + coreline)
if bad:
    sys.stderr.write("head contract 違反:\n  " + "\n  ".join(bad) + "\n")
    sys.exit(1)
' "$guard" "$doc" "$coreline"
}

@test "予算(■8): 3 role とも 1,000 <= u16 <= 9,800（land 目標 8,000 以下）で先頭が acceptance(1) の 4 要素を満たす" {
    # 非 vacuity floor 1,000（0 u16 は合格でなく計測不能＝未達）と失格線 9,800 の AND 条件。
    # worker は条件 A（split-brain warning 込みの最悪ケース）で測る＝env -u で spawn signal を落とす。
    local r out u
    for r in admin worker consult; do
        out="$(printf '%s' "$ANCHOR_JSON" | env -u SCRIBE_WORKER -u SCRIBE_WORKTREE -u TMUX -u TMUX_PANE \
            -u SCRIBE_TMUX SCRIBE_ROLE="$r" CLAUDE_PLUGIN_ROOT="$REPO" "$SCRIPT" 2>/dev/null)"
        [ -n "$out" ]
        u="$(printf '%s' "$out" | python3 -c 'import sys;d=sys.stdin.buffer.read().decode("utf-8","replace").strip();print(len(d.encode("utf-16-le"))//2)')"
        [ "$u" -ge 1000 ]
        [ "$u" -le 8000 ]
        # 先頭 1,000 u16 に「これは要約」自衛文 + 自 role の SSOT doc **絶対** path + Read 指示 + trigger 表
        printf '%s' "$out" | _head_contract "$r" "$REPO"
    done
}

@test "反 false-green(acceptance(1)): head 契約は 自衛文削除 / 相対 path 化 / hollow core のいずれでも RED へ flip する" {
    # 旧 head-check は script の intro だけで 3 要素とも green になり、hollow core でも通っていた
    # （gate finding）。retarget 後の判定器が **実際に落ちる**ことを 3 変異で実測する（推論でなく mutation）。
    local out root

    # --- clean: 3 role とも green（判定器が本文を掴んでいる） ---
    for r in admin worker consult; do
        out="$(printf '%s' "$ANCHOR_JSON" | env -u SCRIBE_WORKER -u SCRIBE_WORKTREE -u TMUX -u TMUX_PANE \
            -u SCRIBE_TMUX SCRIBE_ROLE="$r" CLAUDE_PLUGIN_ROOT="$REPO" "$SCRIPT" 2>/dev/null)"
        run _head_contract "$r" "$REPO" <<< "$out"
        [ "$status" -eq 0 ]
    done

    # --- (i) 自衛文を script の intro から削る → RED（旧 check には assert が無く green のままだった） ---
    root="$BATS_TEST_TMPDIR/mut-head-noguard"
    _mutant_root "$root"
    python3 - "$root/scripts/hooks/session-start-role-inject.sh" <<'PY'
import sys
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
keep = [L for L in lines if "以下は規約の要約(boot core)" not in L]
assert len(keep) < len(lines), "自衛文行が見つからない（変異が空振り）"
open(p, "w", encoding="utf-8").write("\n".join(keep))
PY
    out="$(printf '%s' "$ANCHOR_JSON" | env -u SCRIBE_WORKER -u SCRIBE_WORKTREE -u TMUX -u TMUX_PANE \
        -u SCRIBE_TMUX SCRIBE_ROLE=admin CLAUDE_PLUGIN_ROOT="$root" "$root/scripts/hooks/session-start-role-inject.sh" 2>/dev/null)"
    [ -n "$out" ]                                      # 出力自体は出る＝落ちるのは head 契約だけ
    run _head_contract admin "$root" <<< "$out"
    [ "$status" -ne 0 ]

    # --- (ii) intro の path を相対にする → RED（旧 `.md` and `/` 判定は相対でも green だった） ---
    root="$BATS_TEST_TMPDIR/mut-head-relpath"
    _mutant_root "$root"
    python3 - "$root/scripts/hooks/session-start-role-inject.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
lines = s.split("\n")
n = 0
for i, L in enumerate(lines):
    if "規約 SSOT の全文" in L and "$PROTOCOL_DOC" in L:
        lines[i] = L.replace("$PROTOCOL_DOC", "docs/protocol.md")
        n += 1
assert n > 0, "intro の path 展開が見つからない（変異が空振り）"
open(p, "w", encoding="utf-8").write("\n".join(lines))
PY
    out="$(printf '%s' "$ANCHOR_JSON" | env -u SCRIBE_WORKER -u SCRIBE_WORKTREE -u TMUX -u TMUX_PANE \
        -u SCRIBE_TMUX SCRIBE_ROLE=admin CLAUDE_PLUGIN_ROOT="$root" "$root/scripts/hooks/session-start-role-inject.sh" 2>/dev/null)"
    [ -n "$out" ]
    [[ "$out" == *"docs/protocol.md"* ]]               # 変異は効いている（相対 path が出ている）
    run _head_contract admin "$root" <<< "$out"
    [ "$status" -ne 0 ]

    # --- (iv) doc 側 core を空にする → RED（旧 `"trigger"` は intro 散文が供給し green だった） ---
    root="$BATS_TEST_TMPDIR/mut-head-hollow"
    _mutant_root "$root"
    python3 - "$root/docs/protocol.md" "$CORE_ADMIN_SENTINEL" <<'PY'
import sys
p, name = sys.argv[1], sys.argv[2]
s = open(p, encoding="utf-8").read()
b, e = f"<!-- {name}:begin -->", f"<!-- {name}:end -->"
i, j = s.index(b), s.index(e)
open(p, "w", encoding="utf-8").write(s[:i] + b + "\n" + s[j:])
PY
    out="$(printf '%s' "$ANCHOR_JSON" | env -u SCRIBE_WORKER -u SCRIBE_WORKTREE -u TMUX -u TMUX_PANE \
        -u SCRIBE_TMUX SCRIBE_ROLE=admin CLAUDE_PLUGIN_ROOT="$root" "$root/scripts/hooks/session-start-role-inject.sh" 2>/dev/null)"
    [ -n "$out" ]
    run _head_contract admin "$root" <<< "$out"
    [ "$status" -ne 0 ]
}

@test "予算(■13-1): consult は §2.1/§2.2 の混入なく inline 回帰も無い（script に規約本文を書かない）" {
    run --separate-stderr inject consult "$REPO" "$ANCHOR_JSON"
    [ "$status" -eq 0 ]
    [[ "$output" == *"### 2.3 consult"* ]]
    [[ "$output" != *"### 2.1 admin"* ]]
    [[ "$output" != *"### 2.2 worker"* ]]
    # inline 回帰の機械定義: script 側に §2.3 本文（doc 固有の長句）をベタ書きしていない
    run grep -cF -- 'サマリ保存義務' "$SCRIPT"
    [ "$output" -le 1 ]                                # intro の 1 語まで（本文の転記は 0）
}

@test "script: 規約本文の抽出経路が awk / grep / python3 に依存しない（■6-1・sed と cat のみ）" {
    # 抽出器 2 本（_scribe_emit_sentinel_section / _scribe_emit_consult_section）の本体に
    # awk / grep / python3 / wc が現れないことを構造で pin する（restricted PATH 耐性の回帰ネット）。
    local fn
    fn="$(sed -n '/^_scribe_emit_sentinel_section()/,/^}/p;/^_scribe_emit_consult_section()/,/^}/p' "$SCRIPT")"
    [ -n "$fn" ]
    [[ "$fn" != *"awk "* ]]
    [[ "$fn" != *"grep "* ]]
    [[ "$fn" != *"python3"* ]]
    [[ "$fn" != *"wc "* ]]
    [[ "$fn" == *"sed -n"* ]]
}

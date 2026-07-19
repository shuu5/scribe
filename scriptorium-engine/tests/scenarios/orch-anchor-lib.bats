#!/usr/bin/env bats
# tests/scenarios/orch-anchor-lib.bats
#
# scripts/lib/orch_anchor.sh（scriptorium anchor 動的解決 + external repo cell scan roots の共有 shell lib・
# bd orch-49g）の決定的テスト。orch_session.sh の bats と同型に、lib を `source` して helper を直接叩く unit E2E +
# 本体 `--self-test`（hermetic・fail-closed）の green を pin する。
#
# 検証する契約不変条件（acceptance (1)-(3)）:
#   (SELFTEST) 本体 `--self-test` が PASS（内蔵 hermetic 検証・fail-closed）。
#   (E2a) _anchor_is_orch: orch 台帳（dolt_database==orch）→ accept（0）。
#   (E2b) _anchor_is_orch: foreign 台帳（≠orch）→ reject（非0）＝E2 封鎖の核。
#   (E2c) _anchor_is_orch: 破損 orch-token 台帳 → reject（_json_is_valid gate・orch-t9z drift fix と対称）。
#   (E2d) _anchor_is_orch: metadata 無し → reject。
#   (RESOLVE-accept) _resolve_scriptorium: git=orch anchor → その path を採用。
#   (RESOLVE-reject) _resolve_scriptorium: git=foreign anchor → 全 leg reject・return 1（採用しない）。
#   (MUT) mutation 非vacuity: E2 検証行を無効化した lib コピーは foreign anchor を採用する（=検証が load-bearing）。
#   (EXT) _external_scan_roots: registry read / self-skip / dedup / 非存在 skip。
#   (NODEF-fail-closed) orch_session.sh 不在で _ledger_dolt_database 未定義 → _anchor_is_orch は安全側 reject。
#   (SYNTAX) bash -n が通る。
#
# 実行: bats tests/scenarios/orch-anchor-lib.bats

setup() {
    LIB="$BATS_TEST_DIRNAME/../../scripts/lib/orch_anchor.sh"
    TEST_TMPDIR=$(mktemp -d -t orch-anchor-lib-bats-XXXXXX)
    BIN="$TEST_TMPDIR/bin"; mkdir -p "$BIN"

    # 台帳 fixture。
    mkdir -p "$TEST_TMPDIR/orch/.beads";    printf '{"dolt_database":"orch"}' > "$TEST_TMPDIR/orch/.beads/metadata.json"
    mkdir -p "$TEST_TMPDIR/foreign/.beads"; printf '{"dolt_database":"un"}'   > "$TEST_TMPDIR/foreign/.beads/metadata.json"
    mkdir -p "$TEST_TMPDIR/broken/.beads";  printf '{"dolt_database":"orch"'  > "$TEST_TMPDIR/broken/.beads/metadata.json"  # 未閉じ=破損
    mkdir -p "$TEST_TMPDIR/nometa/.beads"   # metadata.json 無し
}

teardown() { rm -rf "$TEST_TMPDIR"; }

# git を PATH stub 化して worktree list 先頭に固定 anchor を返させる（$1 = anchor path）。
_install_git_stub() {
    cat > "$BIN/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "-C" ]; then shift 2; fi
if [ "\$1 \$2" = "worktree list" ]; then printf 'worktree %s\n' "$1"; exit 0; fi
exit 0
EOF
    chmod +x "$BIN/git"
}

@test "(SELFTEST) 本体 --self-test が PASS（hermetic・fail-closed）" {
    run bash "$LIB" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"orch_anchor.sh --self-test: PASS"* ]]
}

@test "(SYNTAX) bash -n が通る" {
    run bash -n "$LIB"
    [ "$status" -eq 0 ]
}

@test "(E2a) _anchor_is_orch: orch 台帳 → accept" {
    run bash -c 'SELF_PREFIX=orch; . "$1"; _anchor_is_orch "$2"' _ "$LIB" "$TEST_TMPDIR/orch"
    [ "$status" -eq 0 ]
}

@test "(E2b) _anchor_is_orch: foreign 台帳（≠orch）→ reject（E2 封鎖）" {
    run bash -c 'SELF_PREFIX=orch; . "$1"; _anchor_is_orch "$2"' _ "$LIB" "$TEST_TMPDIR/foreign"
    [ "$status" -ne 0 ]
}

@test "(E2c) _anchor_is_orch: 破損 orch-token 台帳 → reject（_json_is_valid gate）" {
    run bash -c 'SELF_PREFIX=orch; . "$1"; _anchor_is_orch "$2"' _ "$LIB" "$TEST_TMPDIR/broken"
    [ "$status" -ne 0 ]
}

@test "(E2d) _anchor_is_orch: metadata 無し → reject" {
    run bash -c 'SELF_PREFIX=orch; . "$1"; _anchor_is_orch "$2"' _ "$LIB" "$TEST_TMPDIR/nometa"
    [ "$status" -ne 0 ]
}

@test "(E2e) _anchor_is_orch: orch 祖先配下の .beads 無し候補 → reject（walk-up 祖先継承 false-accept を封じる）" {
    # 候補 root 自身は .beads を持たず、orch 台帳を持つ祖先の配下にある（foreign repo が nest した想定）。
    #   _ledger_dolt_database の walk-up が祖先へ上昇して orch を継承 accept する穴を、候補自身の台帳要求で封じる。
    local ANC="$TEST_TMPDIR/anc"; mkdir -p "$ANC/.beads" "$ANC/nested_no_beads"
    printf '{"dolt_database":"orch"}' > "$ANC/.beads/metadata.json"
    run bash -c 'SELF_PREFIX=orch; . "$1"; _anchor_is_orch "$2"' _ "$LIB" "$ANC/nested_no_beads"
    [ "$status" -ne 0 ]
}

@test "(RESOLVE-accept) _resolve_scriptorium: git=orch anchor → その path を採用" {
    _install_git_stub "$TEST_TMPDIR/orch"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; _resolve_scriptorium' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/orch" ]
}

@test "(RESOLVE-reject) _resolve_scriptorium: git=foreign anchor → reject・return 1（採用しない）" {
    _install_git_stub "$TEST_TMPDIR/foreign"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; _resolve_scriptorium' _ "$LIB"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "(MUT) mutation 非vacuity: E2 検証を無効化した lib は foreign anchor を採用する（検証が load-bearing）" {
    # lib の _anchor_is_orch 本体を `return 0`（常に accept＝E2 検証無効化）へ書き換えた copy を作る
    #   ＝旧 byte 複製の無検証挙動を再現。
    local MUT="$TEST_TMPDIR/orch_anchor.mut.sh"
    awk '
      /^_anchor_is_orch\(\) \{/ { print; print "    return 0  # MUTATED: E2 検証無効化"; skip=1; next }
      skip && /^\}/ { print; skip=0; next }
      skip { next }
      { print }
    ' "$LIB" > "$MUT"
    _install_git_stub "$TEST_TMPDIR/foreign"
    # 2>/dev/null: mutated copy は sibling orch_session.sh を持たず source warning を stderr に出す（run は stderr を
    #   $output へ混ぜるため抑制）。mutation の核は _anchor_is_orch=return 0 で foreign を採用する点。
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1" 2>/dev/null; _resolve_scriptorium' _ "$MUT"
    # 検証無効化なら foreign anchor を採用してしまう＝(RESOLVE-reject) が real 検証に依存する証明（非vacuity）。
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/foreign" ]
}

# ==============================================================================
# (ANCHOR) 明示 config seam（anchor 設定明示化・bd orch-w9we.1 DONE 到達域 1）
#   engine-relocated topology を「git stub が foreign anchor を返す」で faithful 再現し、ORCH_ANCHOR / ORCH_ANCHOR_CONFIG
#   の明示 seam が動的導出失効下でも解決すること + mutation 非空虚（seam を strip すると解決不能 RED）を pin する。
# ==============================================================================
@test "(ANCHOR-env) ORCH_ANCHOR 明示供給 → 動的導出失効（git=foreign）下でも orch anchor を解決" {
    _install_git_stub "$TEST_TMPDIR/foreign"   # 動的導出は foreign しか返せない＝engine-relocated 等価
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; ORCH_ANCHOR="$2" _resolve_scriptorium' _ "$LIB" "$TEST_TMPDIR/orch"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/orch" ]
}

@test "(ANCHOR-unset) 明示 seam unset + 動的導出失効（git=foreign）→ return 1（env 未供給時 fail-loud）" {
    _install_git_stub "$TEST_TMPDIR/foreign"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; _resolve_scriptorium' _ "$LIB"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "(ANCHOR-cfgfile) ORCH_ANCHOR_CONFIG file → 先頭の非コメント/非空行の orch anchor を解決" {
    _install_git_stub "$TEST_TMPDIR/foreign"
    local CFG="$TEST_TMPDIR/anchor.conf"
    printf '%s\n' "# comment" "" "$TEST_TMPDIR/orch" > "$CFG"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; ORCH_ANCHOR_CONFIG="$2" _resolve_scriptorium' _ "$LIB" "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/orch" ]
}

@test "(ANCHOR-invalid) ORCH_ANCHOR=foreign（set-but-invalid）→ fail-loud return 1（動的/hardcode へ倒さない）" {
    _install_git_stub "$TEST_TMPDIR/orch"   # 動的導出は orch を返せる状況でも、明示 foreign 値を優先し fail-loud する
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; ORCH_ANCHOR="$2" _resolve_scriptorium 2>/dev/null' _ "$LIB" "$TEST_TMPDIR/foreign"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "(ANCHOR-precedence) 明示 foreign 値は動的導出(orch)より優先されて弾く（seam precedence の teeth）" {
    # ★(ANCHOR-invalid) の非空虚証明: 動的導出は orch を返せる（git stub=orch）のに、明示 seam が foreign ゆえ
    #   fail-loud return 1 になる＝tier-0 が確かに動的導出より前で効いている（precedence が load-bearing）。
    _install_git_stub "$TEST_TMPDIR/orch"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; _resolve_scriptorium' _ "$LIB"   # 明示 unset なら orch を採用
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/orch" ]
}

@test "(ANCHOR-seam-precedence) 両 seam 同時 set → ORCH_ANCHOR が ORCH_ANCHOR_CONFIG より優先（doc の precedence を pin）" {
    # doc precedence: per-consumer env > ORCH_ANCHOR > ORCH_ANCHOR_CONFIG > 動的導出。両 seam を同時 set し
    #   ORCH_ANCHOR=orch / ORCH_ANCHOR_CONFIG=foreign のとき orch が勝つ（if/elif の順序＝ORCH_ANCHOR 優先の teeth）。
    #   ★if/elif を逆順に書けば config(foreign) が拾われ fail-loud return 1 になり本 assertion が RED＝precedence 非空虚。
    _install_git_stub "$TEST_TMPDIR/foreign"
    local CFG="$TEST_TMPDIR/anchor-foreign.conf"
    printf '%s\n' "$TEST_TMPDIR/foreign" > "$CFG"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; ORCH_ANCHOR="$2" ORCH_ANCHOR_CONFIG="$3" _resolve_scriptorium 2>/dev/null' _ "$LIB" "$TEST_TMPDIR/orch" "$CFG"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/orch" ]
}

@test "(ANCHOR-cfg-unreadable) ORCH_ANCHOR_CONFIG が unreadable → unset 扱いで動的導出へ倒れる（additive・fail-open でない）" {
    # refuted finding の doc 明確化 teeth: config が -r 失敗（存在しない）のときは「供給されていない」として動的導出へ
    #   倒す（ORCH_ANCHOR="" / unset と同一の additive 挙動）。動的導出も _anchor_is_orch を必ず通すため foreign 採用の
    #   fail-open は無い（git stub=orch なら orch を解決）。
    _install_git_stub "$TEST_TMPDIR/orch"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1"; ORCH_ANCHOR_CONFIG="$2" _resolve_scriptorium' _ "$LIB" "$TEST_TMPDIR/no-such.conf"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/orch" ]
}

@test "(ANCHOR-MUT) 明示 config seam を strip した lib は engine-relocated 下で ORCH_ANCHOR を無視し return 1（seam が load-bearing）" {
    # tier-0（(0) ブロック）を削った copy＝明示 seam 無効化。engine-relocated（git=foreign）で ORCH_ANCHOR を供給しても
    #   動的導出しか効かず foreign reject → return 1。seam があれば解決するはずなので、strip すると解決不能＝seam 非空虚。
    local MUT="$TEST_TMPDIR/orch_anchor.mut.sh"
    # (0) ブロックの本体（cfg_anchor 判定〜fail-loud return）を削除: `local cfg_anchor=""` から
    #   `# ── (1) 動的導出` の直前までを drop する。
    awk '
      /local cfg_anchor=""/ { skip=1; next }
      skip && /── \(1\) 動的導出/ { skip=0 }
      skip { next }
      { print }
    ' "$LIB" > "$MUT"
    _install_git_stub "$TEST_TMPDIR/foreign"
    run bash -c 'SELF_PREFIX=orch; PATH="'"$BIN"':$PATH"; . "$1" 2>/dev/null; ORCH_ANCHOR="$2" _resolve_scriptorium' _ "$MUT" "$TEST_TMPDIR/orch"
    # seam を strip したので ORCH_ANCHOR は無視され、動的導出（foreign）が reject → return 1（seam が無いと解決不能）。
    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "(EXT) _external_scan_roots: registry read / self-skip / dedup / 非存在 skip" {
    local SELF="$TEST_TMPDIR/self"; mkdir -p "$SELF/.worktrees/spawn"
    mkdir -p "$TEST_TMPDIR/ext1/.worktrees/spawn" "$TEST_TMPDIR/ext2/.worktrees/spawn"
    local REG="$TEST_TMPDIR/registry"
    printf '%s\n' "$SELF" "$TEST_TMPDIR/ext1" "$TEST_TMPDIR/ext2" "$TEST_TMPDIR/ext1" "$TEST_TMPDIR/ext3-nonexistent" "# comment" > "$REG"
    run bash -c 'SCRIPTORIUM="$2"; EXTERNAL_REGISTRY="$3"; . "$1"; _external_scan_roots' _ "$LIB" "$SELF" "$REG"
    [ "$status" -eq 0 ]
    # ext1/ext2 のみ・self skip・重複 ext1 は 1 回・非存在 ext3 は skip = 計 2 行。
    local n; n=$(printf '%s\n' "$output" | grep -c .)
    [ "$n" -eq 2 ]
    [[ "$output" == *"$TEST_TMPDIR/ext1/.worktrees/spawn"* ]]
    [[ "$output" == *"$TEST_TMPDIR/ext2/.worktrees/spawn"* ]]
    [[ "$output" != *"$SELF/.worktrees/spawn"* ]]
}

# ==============================================================================
# (RB) _resolve_repo_base（per-repo default branch 解決・orch-665・Option B）
#   実 git で外部 repo の default branch（main worktree の symbolic-ref HEAD）を解決する。stub で fake せず
#   symbolic-ref/worktree list を faithfully 叩く。gate-pending/degraded-watch が external root の base を
#   main 固定でなく repo ごとに解決して「判定不能」を実 commit 数へ格上げする核。
# ==============================================================================
@test "(RB-accept) _resolve_repo_base: default=master（local main 不在）を per-repo 解決する" {
    local R="$TEST_TMPDIR/rb-master"
    git init -q -b master "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    run bash -c '. "$1"; _resolve_repo_base "$2"' _ "$LIB" "$R"
    [ "$status" -eq 0 ]
    [ "$output" = "master" ]           # local main を持たなくても実 default branch を返す（Option B の核）
}

@test "(RB-cell) _resolve_repo_base: cell worktree 起点でも main worktree の base を返す（cell branch を取り違えない）" {
    local R="$TEST_TMPDIR/rb-cell"
    git init -q -b develop "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-rbc-1 "$R/.worktrees/spawn/orch-rbc-1" develop
    # cell worktree（HEAD=spawn/orch-rbc-1）を起点に呼んでも default branch=develop を返す（spawn/... でない）。
    run bash -c '. "$1"; _resolve_repo_base "$2"' _ "$LIB" "$R/.worktrees/spawn/orch-rbc-1"
    [ "$status" -eq 0 ]
    [ "$output" = "develop" ]
}

@test "(RB-detached) _resolve_repo_base: main worktree が detached HEAD → return 1（consumer は global base fallback）" {
    local R="$TEST_TMPDIR/rb-detached"
    git init -q -b master "$R"
    git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" checkout -q --detach
    run bash -c '. "$1"; _resolve_repo_base "$2"' _ "$LIB" "$R"
    [ "$status" -ne 0 ]                # symbolic-ref 失敗 → return 1（空 stdout）＝Option A の「判定不能」経路へ倒れる
    [ -z "$output" ]
}

@test "(RB-empty) _resolve_repo_base: 空引数 / 非 git dir → return 1" {
    run bash -c '. "$1"; _resolve_repo_base ""' _ "$LIB"
    [ "$status" -ne 0 ]
    local NG="$TEST_TMPDIR/not-a-git-repo"; mkdir -p "$NG"
    run bash -c '. "$1"; _resolve_repo_base "$2"' _ "$LIB" "$NG"
    [ "$status" -ne 0 ]               # worktree list が非 git dir で失敗 → main_wt 空 → return 1
    [ -z "$output" ]
}

# ==============================================================================
# (RREL) _repo_base_relation（containment gate・orch-igl / orch-665 follow-up）
#   base↔cell HEAD の包含関係を弁別し、consumer（gate-pending / degraded-watch）が silent-drop / 誤 count せず
#   harm(b)（0-ahead merge 済 cell の drop）を守りつつ乖離（非 default checkout）を fail-loud にする核。実 git で叩く。
# ==============================================================================
@test "(RREL-contained) _repo_base_relation: 0-ahead cell（HEAD⊂base）→ contained（統合済/未着手・drop 維持で harm(b)）" {
    local R="$TEST_TMPDIR/rrel-c"
    git init -q -b master "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-rc-1 "$R/.worktrees/spawn/orch-rc-1" master   # cell=master と同一 HEAD
    run bash -c '. "$1"; _repo_base_relation "$2" master' _ "$LIB" "$R/.worktrees/spawn/orch-rc-1"
    [ "$status" -eq 0 ]
    [ "$output" = "contained" ]
}

@test "(RREL-contained-behind) _repo_base_relation: 0-ahead cell で base が前進（a=0 ∧ b>0＝真の harm(b)）→ contained（a-first 短絡で b を見ず drop 維持）" {
    # ★item(1) 核（RREL-contained〔a=0 ∧ b=0〕が抜いていた modality）: merge 済 cell で default(base) が cell 先へ
    #   前進し base が cell HEAD の祖先でなくなる契約＝a=rev-list base..HEAD=0（cell は base に無い commit を持たない）
    #   ∧ b=rev-list HEAD..base>0（base が cell より先行）。この場面こそ `_repo_base_relation` が a==0 を**先に**判定
    #   して短絡し（b を見ずに）contained を返す a-first 分岐順序の唯一の存在理由。
    #   ★mutation teeth: a==0 短絡を外し b を先に評価する / naive `merge-base --is-ancestor base HEAD` gate（base が
    #     HEAD の祖先でない→非 contained と誤判定）へ差し替えると、この構成（base⊄HEAD ∧ b>0）で "diverged 0"（誤分類）
    #     や非 contained になり本 assertion（output=contained）が RED になる＝分岐順序が load-bearing（harm(b) を守る）。
    local R="$TEST_TMPDIR/rrel-cb"
    git init -q -b master "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-rcb-1 "$R/.worktrees/spawn/orch-rcb-1" master   # cell=master 起点(0-ahead)
    echo m2 > "$R/m2"; git -C "$R" add m2; git -C "$R" -c commit.gpgsign=false commit -qm advance   # base(master) を 1 前進＝cell より先行(b>0)
    run bash -c '. "$1"; _repo_base_relation "$2" master' _ "$LIB" "$R/.worktrees/spawn/orch-rcb-1"
    [ "$status" -eq 0 ]
    [ "$output" = "contained" ]                 # a=0 短絡で b>0 を見ず contained（真の harm(b)・drop 維持）
}

@test "(RREL-ahead) _repo_base_relation: 1-ahead cell（base⊂HEAD）→ ahead 1（正確 surface）" {
    local R="$TEST_TMPDIR/rrel-a"
    git init -q -b master "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" worktree add -q -b spawn/orch-ra-1 "$R/.worktrees/spawn/orch-ra-1" master
    echo b > "$R/.worktrees/spawn/orch-ra-1/b"; git -C "$R/.worktrees/spawn/orch-ra-1" add b
    git -C "$R/.worktrees/spawn/orch-ra-1" -c commit.gpgsign=false commit -qm work
    run bash -c '. "$1"; _repo_base_relation "$2" master' _ "$LIB" "$R/.worktrees/spawn/orch-ra-1"
    [ "$status" -eq 0 ]
    [ "$output" = "ahead 1" ]
}

@test "(RREL-diverged) _repo_base_relation: base が cell 系列外（a>0 ∧ b>0）→ diverged（非 default checkout の fail-loud trigger・item1 核）" {
    local R="$TEST_TMPDIR/rrel-d"
    git init -q -b master "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    git -C "$R" checkout -q -b feature; echo fx > "$R/fx"; git -C "$R" add fx
    git -C "$R" -c commit.gpgsign=false commit -qm featwork                                  # feature=master+Fx
    git -C "$R" worktree add -q -b spawn/orch-rd-1 "$R/.worktrees/spawn/orch-rd-1" master
    echo c > "$R/.worktrees/spawn/orch-rd-1/c"; git -C "$R/.worktrees/spawn/orch-rd-1" add c
    git -C "$R/.worktrees/spawn/orch-rd-1" -c commit.gpgsign=false commit -qm cellwork       # cell=master+C（feature と乖離）
    run bash -c '. "$1"; _repo_base_relation "$2" feature' _ "$LIB" "$R/.worktrees/spawn/orch-rd-1"
    [ "$status" -eq 0 ]
    [[ "$output" == diverged\ * ]]              # a>0 ∧ b>0（互いに相手に無い commit）→ diverged
}

@test "(RREL-unresolvable) _repo_base_relation: 存在しない base / 空引数 → return 1（consumer は判定不能/skip へ）" {
    local R="$TEST_TMPDIR/rrel-u"
    git init -q -b master "$R"; git -C "$R" config user.email t@t.t; git -C "$R" config user.name t
    echo a > "$R/a"; git -C "$R" add a; git -C "$R" -c commit.gpgsign=false commit -qm init
    run bash -c '. "$1"; _repo_base_relation "$2" no-such-branch' _ "$LIB" "$R"
    [ "$status" -ne 0 ]; [ -z "$output" ]
    run bash -c '. "$1"; _repo_base_relation "" master' _ "$LIB"
    [ "$status" -ne 0 ]
}

@test "(NODEF-fail-closed) orch_session.sh 不在で _ledger_dolt_database 未定義 → _anchor_is_orch は安全側 reject" {
    # lib 単体を hooks/lib/orch_session.sh の無い場所へコピー＝transitive source が失敗し _ledger_dolt_database 未定義。
    local ISO="$TEST_TMPDIR/isolated"; mkdir -p "$ISO"
    cp "$LIB" "$ISO/orch_anchor.sh"
    run bash -c 'SELF_PREFIX=orch; . "$1" 2>/dev/null; _anchor_is_orch "$2"' _ "$ISO/orch_anchor.sh" "$TEST_TMPDIR/orch"
    # _ledger_dolt_database 未定義 → 検証不能 → reject（foreign 誤採用を避ける fail-closed・orch でも安全側 reject）。
    [ "$status" -ne 0 ]
}

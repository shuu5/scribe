#!/usr/bin/env bats
# tests/scenarios/orch-branch-sweep.bats
#
# orch-branch-sweep.sh（spawn branch backlog の機械掃除ツール・read-only 既定・bd orch-caz）の
# 決定的 hermetic テスト。fleet-degraded-watch.bats 等と同型で gh / bd / git を stub 実体に差し替え
# （ORCH_BRANCH_SWEEP_GH / _BD / _GIT）、実スクリプトを走らせて 3 段判定と安全不変条件を assert する E2E。
#
# 検証する契約不変条件（bd orch-caz PINS v2 の bats 必須ケース）:
#   (A) happy path: closed ∩ tip 一致 の spawn branch が「削除候補」になる。
#   (B) open bead → 候補外で sweep 継続（abort しない）＝台帳に closed で無い id は skip。
#   (C) 台帳不在 id（closed 集合にも無い open でもない）→ candidate skip・非 abort。
#   (D) tip SHA 不一致（merge 後 re-push 疑い）→ 候補外（loud 警告）。
#   (E) 抽出不能 branch 名（admin 手動 branch）→ 候補外（fail-closed under-sweep）。
#   (F) dry-run は remote/local を一切変更しない（push 未実行・git は ls-remote のみ＝read-only 規律）。
#   (G) --execute は候補のみ git push --delete（per-branch・候補外 branch は push しない）。
#   (H) local -D 委譲コマンド列を print（候補 branch のみ・自動実行しない）。
#   (I) bd 到達不能 → 非 0 終了（closed 集合を解決できない＝判定不能を skip に吸収しない）。
#   (J) gh 到達不能 → 非 0 終了（liveness fail-closed）。
#   (K) truncate guard: 取得件数 == PR_LIMIT で abort（非 0・silent 截断を候補ゼロと誤らない）。
#   (L) **default-30 截断回帰防御**: merged 35 本・gh stub が --limit を honor しても、script が --limit 1000 を
#       明示するので 31 本目以降（orch-p35）が欠落しない（もし --limit 30 実装なら stub 截断で orch-p35 が消え RED）。
#   (M) blanket-green 禁止: push が 1 本でも失敗したら非 0 で終わる（per-branch rc 捕捉の teeth）。
#   (N) self-scope gate: foreign cwd（dolt_database≠orch）は fail-closed で非 0（exit 2）・orch cwd は走る。
#   (O) 本体 --self-test が green（内蔵 hermetic テストの回帰防御）。
#   (P) **bd default-50 截断回帰防御**（finding orch-caz #1）: closed 55 本・bd stub が --limit を honor しても、
#       script が closed set を --limit 0（unlimited）で取るので 51 本目以降（orch-p55）が closed 認識され候補に残る
#       （もし無指定/有限 limit なら stub が 50 本に截断し orch-p55 が closed 集合から消え skip されて RED）。
#   (Q) bd closed truncate guard（gh 軸と同型・finding orch-caz #1）: 有限 BD_LIMIT を課し取得数==limit で abort（非 0）。
#   (R) **local orphan 網羅**（finding orch-caz #2）: remote 既削除（tip 空=n_skip_gone）の merged∩closed branch は
#       remote 削除候補にならないが local -D 委譲コマンドには出る（tip gate から独立＝local>remote 差分を取りこぼさない）。
#
# 実行: bats tests/scenarios/orch-branch-sweep.bats

setup() {
    SCRIPT="$BATS_TEST_DIRNAME/../../scripts/orch-branch-sweep.sh"
    T="$(mktemp -d -t branch-sweep-bats-XXXXXX)"
    BIN="$T/bin"; mkdir -p "$BIN"

    export GH_FIXTURE="$T/merged.json"
    export BD_FIXTURE="$T/closed.json"
    export TIP_FIXTURE="$T/tips.tsv"
    export PUSH_LOG="$T/push.log"
    export GIT_LOG="$T/git.log"
    : >"$PUSH_LOG"; : >"$GIT_LOG"

    # ── stub gh: liveness(--limit 1・非 merged)→[] / merged 一覧は --limit を honor して slice ──
    #   （実 gh の截断挙動を模す＝script が渡す --limit N より多い fixture は N 件に切られる。
    #     これで「script が --limit 1000 を明示するか」が (L) で teeth を持つ。）
    cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
lim=0; a=("$@")
for ((i=0;i<${#a[@]};i++)); do [[ "${a[i]}" == "--limit" ]] && lim="${a[i+1]}"; done
if [[ "$*" == *"--state merged"* ]]; then
    jq ".[0:${lim}]" "$GH_FIXTURE"; exit 0
fi
echo "[]"; exit 0        # liveness probe（pr list --limit 1）
STUB

    # ── stub bd: list --status closed --json → fixture（--limit を honor して slice）──
    #   実 bd の --limit 挙動を模す: default 50 / 0=unlimited / N>0 は先頭 N 件に slice。
    #   これで「script が closed set を --limit 0 で全件取るか」が finding#1 回帰（closed>50）で teeth を持つ
    #   （script が無指定/有限 limit なら stub が截断し 51 本目が closed 集合から消えて RED になる）。
    cat >"$BIN/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"list --status closed --json"* ]]; then
    lim=50; a=("$@")
    for ((i=0;i<${#a[@]};i++)); do [[ "${a[i]}" == "--limit" ]] && lim="${a[i+1]}"; done
    if [[ "$lim" == "0" ]]; then jq '.' "$BD_FIXTURE"; else jq ".[0:${lim}]" "$BD_FIXTURE"; fi
    exit 0
fi
echo "[]"; exit 0
STUB

    # ── stub git: ls-remote は TIP_FIXTURE を引く / push --delete は PUSH_LOG に記録（FAIL_BRANCH は失敗）──
    #   全 argv を GIT_LOG に記録＝read-only 規律（dry-run で push が出ないこと）の回帰防御。
    cat >"$BIN/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GIT_LOG"
if [[ "$1" == "ls-remote" ]]; then
    ref="${@: -1}"; branch="${ref#refs/heads/}"
    awk -v b="$branch" '$1==b{print $2"\trefs/heads/"$1}' "$TIP_FIXTURE"
    exit 0
fi
if [[ "$1" == "push" ]]; then
    br="${@: -1}"
    if [[ -n "${GIT_PUSH_FAIL_BRANCH:-}" && "$br" == "$GIT_PUSH_FAIL_BRANCH" ]]; then exit 1; fi
    echo "$*" >>"$PUSH_LOG"; exit 0
fi
exit 0
STUB
    chmod +x "$BIN/gh" "$BIN/bd" "$BIN/git"

    # ── 既定 fixture: 4 branch ──
    #  A: spawn/orch-aaa-111111  closed  tip一致    → 削除候補
    #  B: spawn/orch-bbb-222222  open(closed 集合に有るが closed でない=集合に無い) → skip
    #  C: spawn/orch-ccc-333333  closed  tip不一致  → skip (tip)
    #  D: feat/manual-thing      （命名外）        → skip (命名外)
    cat >"$GH_FIXTURE" <<'JSON'
[
  {"headRefName":"spawn/orch-aaa-111111","headRefOid":"aaaa1111","number":1},
  {"headRefName":"spawn/orch-bbb-222222","headRefOid":"bbbb2222","number":2},
  {"headRefName":"spawn/orch-ccc-333333","headRefOid":"cccc3333","number":3},
  {"headRefName":"feat/manual-thing","headRefOid":"dddd4444","number":4}
]
JSON
    # closed 集合には orch-aaa / orch-ccc のみ（orch-bbb は無い=open/不在扱い）。
    cat >"$BD_FIXTURE" <<'JSON'
[ {"id":"orch-aaa"}, {"id":"orch-ccc"}, {"id":"sc-zzz"} ]
JSON
    printf 'spawn/orch-aaa-111111\taaaa1111\n'  >"$TIP_FIXTURE"
    printf 'spawn/orch-ccc-333333\tcccc9999\n' >>"$TIP_FIXTURE"   # C は remote tip≠PR oid
}

teardown() {
    [ -n "${T:-}" ] && rm -rf "$T"
}

# stub 環境で sweep を走らせる（self-scope gate は skip）。
#   追加 env は "$@" で渡す・スクリプト引数は SWEEP_ARGS 配列で渡す（空配列は 0 引数に展開＝空文字を渡さない）。
run_sweep() {
    run env \
        ORCH_BRANCH_SWEEP_GH="$BIN/gh" \
        ORCH_BRANCH_SWEEP_BD="$BIN/bd" \
        ORCH_BRANCH_SWEEP_GIT="$BIN/git" \
        ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 \
        "$@" \
        bash "$SCRIPT" "${SWEEP_ARGS[@]}"
}

# ══════════════════════════════════════════════════════════════════════════════════
@test "(A) happy: closed ∩ tip 一致 の orch-aaa が削除候補" {
    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"削除候補: spawn/orch-aaa-111111"* ]]
}

@test "(B/C) open/台帳不在の orch-bbb は候補外・sweep 継続（A は候補のまま）" {
    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" != *"削除候補: spawn/orch-bbb-222222"* ]]
    [[ "$output" == *"skip (open/台帳不在): spawn/orch-bbb-222222"* ]]
    [[ "$output" == *"削除候補: spawn/orch-aaa-111111"* ]]   # 継続の証拠
}

@test "(D) tip SHA 不一致の orch-ccc は候補外" {
    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" != *"削除候補: spawn/orch-ccc-333333"* ]]
    [[ "$output" == *"tip 不一致"* ]]
}

@test "(E) 命名外 branch（feat/manual-thing）は候補外（抽出不能=scope 外・出力に一切現れない）" {
    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" != *"manual-thing"* ]]   # 命名外は静かに skip（per-line echo せず候補にもしない）
}

@test "(F) dry-run は push を実行しない・git は ls-remote のみ（read-only 規律）" {
    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [ ! -s "$PUSH_LOG" ]                                    # push ゼロ
    run grep -vE '^ls-remote ' "$GIT_LOG"                   # ls-remote 以外の git 呼出があれば行が残る
    [ -z "$output" ]                                        # 空＝ls-remote のみ
}

@test "(G) --execute は候補(orch-aaa)のみ push --delete・候補外は push しない" {
    SWEEP_ARGS=(--execute); run_sweep
    [ "$status" -eq 0 ]
    grep -q "push origin --delete spawn/orch-aaa-111111" "$PUSH_LOG"
    ! grep -Eq "orch-bbb|orch-ccc|manual-thing" "$PUSH_LOG"
}

@test "(H) local -D 委譲コマンド列を print（候補 branch のみ）" {
    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"git branch -D spawn/orch-aaa-111111"* ]]
    [[ "$output" != *"git branch -D spawn/orch-bbb-222222"* ]]
}

@test "(I) bd 到達不能 → 非 0 終了（closed 集合を解決できない）" {
    cat >"$BIN/bd" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$BIN/bd"
    SWEEP_ARGS=(); run_sweep
    [ "$status" -ne 0 ]
}

@test "(J) gh 到達不能 → 非 0 終了（liveness fail-closed）" {
    cat >"$BIN/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$BIN/gh"
    SWEEP_ARGS=(); run_sweep
    [ "$status" -ne 0 ]
}

@test "(K) truncate guard: 取得件数==PR_LIMIT で abort（非 0）" {
    SWEEP_ARGS=(); run_sweep ORCH_BRANCH_SWEEP_PR_LIMIT=4   # fixture が 4 本 → slice[0:4]=4 >= 4 で abort
    [ "$status" -ne 0 ]
}

@test "(L) default-30 截断回帰: merged 35 本でも orch-p35 が欠落しない（--limit 1000 明示の teeth）" {
    # 35 本の closed ∩ tip 一致 spawn branch を生成。
    local i br id oid pr closed tips
    pr="["; closed="["; tips=""
    for i in $(seq 1 35); do
        id="$(printf 'orch-p%02d' "$i")"
        br="spawn/${id}-$(printf '0000%02d' "$i")"        # 6 桁 suffix（000001..000035）
        oid="$(printf 'oid%03d' "$i")"
        [ "$i" -gt 1 ] && { pr+=","; closed+=","; }
        pr+="{\"headRefName\":\"$br\",\"headRefOid\":\"$oid\",\"number\":$i}"
        closed+="{\"id\":\"$id\"}"
        tips+="$br"$'\t'"$oid"$'\n'   # command substitution を通さず改行を保持（1 行 1 branch）
    done
    pr+="]"; closed+="]"
    printf '%s' "$pr"     >"$GH_FIXTURE"
    printf '%s' "$closed" >"$BD_FIXTURE"
    printf '%s' "$tips"   >"$TIP_FIXTURE"

    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"削除候補: spawn/orch-p35-000035"* ]]   # 35 本目が生き残る
    [[ "$output" == *"削除候補: spawn/orch-p31-000031"* ]]   # 31 本目（default-30 なら消える）
}

@test "(M) blanket-green 禁止: push が 1 本でも失敗したら非 0 終了" {
    SWEEP_ARGS=(--execute); run_sweep GIT_PUSH_FAIL_BRANCH=spawn/orch-aaa-111111
    [ "$status" -ne 0 ]
    [[ "$output" == *"失敗"* ]]
}

@test "(N) self-scope gate: foreign cwd は fail-closed 非0(exit2)・orch cwd は走る" {
    # foreign 台帳 cwd → exit 2（skip env は付けない）。cd してから run（bats test は独立プロセス）。
    local fdir="$T/foreign"; mkdir -p "$fdir/.beads"
    printf '{"dolt_database":"scribe"}' >"$fdir/.beads/metadata.json"
    cd "$fdir"
    run env \
        ORCH_BRANCH_SWEEP_GH="$BIN/gh" ORCH_BRANCH_SWEEP_BD="$BIN/bd" ORCH_BRANCH_SWEEP_GIT="$BIN/git" \
        bash "$SCRIPT"
    [ "$status" -eq 2 ]

    # orch 台帳 cwd → gate 通過して dry-run 完走（exit 0）。
    local odir="$T/orch"; mkdir -p "$odir/.beads"
    printf '{"dolt_database":"orch"}' >"$odir/.beads/metadata.json"
    cd "$odir"
    run env \
        ORCH_BRANCH_SWEEP_GH="$BIN/gh" ORCH_BRANCH_SWEEP_BD="$BIN/bd" ORCH_BRANCH_SWEEP_GIT="$BIN/git" \
        bash "$SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"削除候補: spawn/orch-aaa-111111"* ]]
}

@test "(O) 本体 --self-test が green" {
    run bash "$SCRIPT" --self-test
    [ "$status" -eq 0 ]
    [[ "$output" == *"PASS"* ]]
}

@test "(P) bd default-50 截断回帰: closed 55 本でも orch-p55 が closed 認識され候補に残る（--limit 0 の teeth）" {
    # 55 本の merged∩closed∩tip 一致 spawn branch を生成（closed 集合が bd default 50 を超える）。
    # bd stub は --limit を honor するので、script が --limit 0 を渡さないと 51 本目以降が closed 集合から消える。
    local i br id oid pr closed tips
    pr="["; closed="["; tips=""
    for i in $(seq 1 55); do
        id="$(printf 'orch-p%02d' "$i")"
        br="spawn/${id}-$(printf '0000%02d' "$i")"
        oid="$(printf 'oid%03d' "$i")"
        [ "$i" -gt 1 ] && { pr+=","; closed+=","; }
        pr+="{\"headRefName\":\"$br\",\"headRefOid\":\"$oid\",\"number\":$i}"
        closed+="{\"id\":\"$id\"}"
        tips+="$br"$'\t'"$oid"$'\n'
    done
    pr+="]"; closed+="]"
    printf '%s' "$pr"     >"$GH_FIXTURE"
    printf '%s' "$closed" >"$BD_FIXTURE"
    printf '%s' "$tips"   >"$TIP_FIXTURE"

    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"削除候補: spawn/orch-p55-000055"* ]]   # 51 本目以降が生き残る（bd 無防備なら消える）
    [[ "$output" == *"削除候補: spawn/orch-p51-000051"* ]]   # 51 本目（bd default-50 なら closed 集合外→skip）
    [[ "$output" != *"skip (open/台帳不在): spawn/orch-p51"* ]]   # 截断で open 誤認されていないこと
}

@test "(Q) bd closed truncate guard: 取得件数==BD_LIMIT で abort（非 0・gh 軸と同型）" {
    SWEEP_ARGS=(); run_sweep ORCH_BRANCH_SWEEP_BD_LIMIT=2   # 既定 closed fixture 3 本 → slice[0:2]=2 >= 2 で abort
    [ "$status" -ne 0 ]
}

@test "(R) local orphan: remote 既削除の merged∩closed branch は remote 候補外だが local -D 委譲には出る" {
    # orch-aaa の remote tip を消す（ls-remote が空を返す）＝remote は既に削除済みの local orphan を模す。
    # TIP_FIXTURE に aaa の行を書かない＝ls-remote が aaa に空を返す（ccc だけ残す）。
    printf 'spawn/orch-ccc-333333\tcccc9999\n' >"$TIP_FIXTURE"

    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    # aaa は remote gone → remote 削除候補にならない（push 委譲行に出ない）が…
    [[ "$output" != *"git push origin --delete spawn/orch-aaa-111111"* ]]
    [[ "$output" == *"skip remote (既に削除済み"*"spawn/orch-aaa-111111"* ]]
    # …local -D 委譲コマンドには出る（tip gate と独立＝local orphan を取りこぼさない）。
    [[ "$output" == *"git branch -D spawn/orch-aaa-111111"* ]]
}

@test "(S) anchor 境界: 7桁 suffix と 先頭余剰 prefix は候補外（SPAWN_BRANCH_RE の ^/$ anchor の mutation teeth）" {
    # SPAWN_BRANCH_RE='^spawn/(orch-[0-9a-z]+)-[0-9]{6}$' の anchor（^ と $）を exercise する fixture。
    # 既定 fixture の 'feat/manual-thing' は 'spawn/' リテラルで弾かれ anchor 境界を通らない（gate errata の穴）ため、
    # anchor が消えて初めて誤 match する 2 形を追加し、その候補化を assert で RED 化する牙にする（orchestrator gate finding）。
    #   - spawn/orch-ok-111111   : 正常（6桁・^spawn 始まり）→ 候補（制御＝harness が候補を出せる非vacuity 証拠）。
    #   - spawn/orch-aaa-1234567 : 7桁 suffix → 正規表現の $ が『6桁ちょうどで終端』を要求ゆえ候補外。
    #                              （$ を除去する変異なら先頭6桁で部分 match し候補化＝この行が RED 化する牙）。
    #   - zzspawn/orch-aaa-111111: 先頭余剰 prefix → ^ が『spawn/ で始まる』を要求ゆえ候補外。
    #                              （^ を除去する変異なら部分一致で候補化＝この行が RED 化する牙）。
    cat >"$GH_FIXTURE" <<'JSON'
[
  {"headRefName":"spawn/orch-ok-111111","headRefOid":"oidok","number":1},
  {"headRefName":"spawn/orch-aaa-1234567","headRefOid":"oid7","number":2},
  {"headRefName":"zzspawn/orch-aaa-111111","headRefOid":"oidz","number":3}
]
JSON
    cat >"$BD_FIXTURE" <<'JSON'
[ {"id":"orch-ok"}, {"id":"orch-aaa"} ]
JSON
    {
      printf 'spawn/orch-ok-111111\toidok\n'
      printf 'spawn/orch-aaa-1234567\toid7\n'
      printf 'zzspawn/orch-aaa-111111\toidz\n'
    } >"$TIP_FIXTURE"

    SWEEP_ARGS=(); run_sweep
    [ "$status" -eq 0 ]
    [[ "$output" == *"削除候補: spawn/orch-ok-111111"* ]]        # 制御: 正常 branch は候補（非vacuity＝harness が空でない）
    [[ "$output" != *"削除候補: spawn/orch-aaa-1234567"* ]]      # $ anchor の牙（7桁 suffix 拒否・$ 除去変異で RED）
    [[ "$output" != *"削除候補: zzspawn/orch-aaa-111111"* ]]     # ^ anchor の牙（先頭余剰 prefix 拒否・^ 除去変異で RED）
}

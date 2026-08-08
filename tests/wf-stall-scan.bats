#!/usr/bin/env bats
# wf-stall-scan.bats — 呼出元側 WF stall 検知 scan の teeth（bd sc-9yoc・c1df leg2-B2）
#
# 対象: scripts/scribe-wf-stall-scan.sh（read-only・走行中 WF の agent-*.jsonl mtime scan）
# 書式規約は protocol-pins.bats と同一: grep -qF -- 形・パイプ終端 head -1 禁止・fixture は
# $BATS_TEST_TMPDIR に生成（repo を汚さない・hermetic＝実 config-dir に触れない）。
#
# assertion inventory（fsev P7・invariant / polarity / mutant_fingerprint）:
#   T1: invariant=script が実在し bash -n が通り実行可 / polarity=positive /
#       mutant_fingerprint=構文破壊で bash -n RED
#   T2: invariant=全 agent fresh → 全行 ACTIVE・summary verdict=OK・rc0 / polarity=negative(誤検知なし) /
#       mutant_fingerprint=閾値比較の反転（age > T → age <= T）で STALL 化し RED
#   T3: invariant=stale agent → STALL・summary verdict=STALL・rc3 / polarity=positive(検知) /
#       mutant_fingerprint=閾値比較の反転 or exit 3 の削除で RED（T2 と相互対照）
#   T4: invariant=混在で停滞 agent だけを STALL（限局性・stalled=1）/ polarity=positive+negative /
#       mutant_fingerprint=全件同一 verdict 化で RED
#   T5: invariant=agent file 0 件 → verdict=EMPTY・rc2（rc0 に丸めない＝停滞なしと読ませない）/
#       polarity=negative / mutant_fingerprint=EMPTY 分岐削除で rc0 化し RED
#   T6: invariant=run dir 不在 → rc5 NOT-FOUND（loud）/ polarity=negative /
#       mutant_fingerprint=glob 0 件 guard 削除で rc≠5 化し RED
#   T7: invariant=BAD_USAGE 3 型（引数なし / 非 wf_ runId / 非整数 threshold）→ rc4 /
#       polarity=negative / mutant_fingerprint=検証削除で rc4 が別 rc へ漏れ RED
#   T8: invariant=per-agent 行が行頭 marker + 固定 arity（run/agent/ageSec/verdict）+ label 末尾 /
#       polarity=positive / mutant_fingerprint=出力形式変更で regex 不一致 RED
#   T9: invariant=--run 解決の glob が symlink の projects dir を降りる（find -P 退行の pin）/
#       polarity=positive / mutant_fingerprint=glob を find 化すると symlink 開始点で 0 件 rc5 化し RED
#   T10: invariant=journal result 済み agent は mtime が古くても DONE・rc0（完了残留の誤検知抑止 =
#        gate wf_bd633def-65b MF-1）/ polarity=negative(誤検知なし) /
#        mutant_fingerprint=journal 除外 block の削除で STALL 化し RED
#   T11: invariant=result 済み old は DONE・result 無し old は STALL（抑止が過剰でない＝検知面保持）/
#        polarity=positive+negative / mutant_fingerprint=全 agent DONE 化（journal 無条件除外）で RED
#   T12: invariant=scan 中の stat 失敗は rc2（宣言空間 {0,2,3,4,5} へ倒す・rc1 に漏らさない = MF-3）/
#        polarity=negative / mutant_fingerprint=stat guard 削除で rc1 化し RED

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO/scripts/scribe-wf-stall-scan.sh"
    CFG="$BATS_TEST_TMPDIR/cfg"
    WFDIR="$CFG/projects/enc-cwd/sid-0001/subagents/workflows/wf_test01"
    mkdir -p "$WFDIR"
}

mk_agent() { # $1 = id, $2 = touch 引数（mtime。省略なら now）
    local f="$WFDIR/agent-$1.jsonl"
    printf '{"message":{"content":"lens fixture-%s の検証 prompt"},"agentId":"%s"}\n' "$1" "$1" > "$f"
    if [ -n "${2:-}" ]; then touch -d "$2" "$f"; fi
}

mk_journal_result() { # $1 = agentId（journal.jsonl へ result 行を append・実 harness と同形の 1 行 JSON）
    printf '{"type":"result","key":"v2:fixture","agentId":"%s","result":"ok"}\n' "$1" >> "$WFDIR/journal.jsonl"
}

@test "T1: script が実在し bash -n が通り実行可" {
    [ -f "$SCRIPT" ]
    [ -x "$SCRIPT" ]
    bash -n "$SCRIPT"
}

@test "T2: 全 agent fresh → 全行 ACTIVE・verdict=OK・rc0（誤検知なし）" {
    mk_agent aaa; mk_agent bbb
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 0 ]
    [ "$(grep -cF -- 'verdict=ACTIVE' <<< "$output")" -eq 2 ]
    grep -qF -- 'total=2 done=0 stalled=0 threshold=900 verdict=OK' <<< "$output"
}

@test "T3: stale agent → STALL・verdict=STALL・rc3（検知）" {
    mk_agent old '2 hours ago'
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 3 ]
    grep -qF -- 'agent=old' <<< "$output"
    grep -qF -- 'verdict=STALL' <<< "$output"
    grep -qF -- 'total=1 done=0 stalled=1 threshold=900 verdict=STALL' <<< "$output"
}

@test "T4: 混在で停滞 agent のみ STALL（限局性）" {
    mk_agent fresh1; mk_agent old1 '2 hours ago'
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 3 ]
    # per-agent STALL 1 + summary STALL 1 = 2 / ACTIVE 1
    [ "$(grep -cF -- 'verdict=STALL' <<< "$output")" -eq 2 ]
    [ "$(grep -cF -- 'verdict=ACTIVE' <<< "$output")" -eq 1 ]
    grep -qF -- 'total=2 done=0 stalled=1' <<< "$output"
    # 停滞の帰属が正しい（fresh 側に STALL が付かない）
    ! grep -qE -- 'agent=fresh1 .*verdict=STALL' <<< "$output"
}

@test "T5: agent file 0 件 → verdict=EMPTY・rc2（rc0 に丸めない）" {
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 2 ]
    grep -qF -- 'verdict=EMPTY' <<< "$output"
}

@test "T6: run dir 不在 → rc5 NOT-FOUND（loud）" {
    run "$SCRIPT" --run wf_nope --config-dir "$CFG"
    [ "$status" -eq 5 ]
    grep -qF -- 'NOT-FOUND' <<< "$output"
}

@test "T7: BAD_USAGE 3 型 → rc4（引数なし / 非 wf_ runId / 非整数 threshold）" {
    run "$SCRIPT"
    [ "$status" -eq 4 ]
    run "$SCRIPT" --run notawf --config-dir "$CFG"
    [ "$status" -eq 4 ]
    run "$SCRIPT" --dir "$WFDIR" --threshold abc
    [ "$status" -eq 4 ]
}

@test "T8: per-agent 行の marker + 固定 arity + label 末尾" {
    mk_agent fmt1
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 0 ]
    grep -qE -- '^\[WF-STALL-SCAN v1\] run=[^ ]+ agent=fmt1 ageSec=[0-9]+ verdict=(STALL|ACTIVE) label=' <<< "$output"
}

@test "T9: --run 解決の glob は symlink の projects dir を降りる（find -P 退行 pin）" {
    mk_agent viaLink
    local CFG2="$BATS_TEST_TMPDIR/cfg2"
    mkdir -p "$CFG2"
    ln -s "$CFG/projects" "$CFG2/projects"
    run "$SCRIPT" --run wf_test01 --config-dir "$CFG2" --threshold 900
    [ "$status" -eq 0 ]
    grep -qF -- 'agent=viaLink' <<< "$output"
}

@test "T10: journal result 済み agent は mtime が古くても DONE・rc0（完了残留の誤検知抑止 = MF-1）" {
    mk_agent finished '2 hours ago'
    mk_agent working
    mk_journal_result finished
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 0 ]
    grep -qE -- 'agent=finished ageSec=[0-9]+ verdict=DONE' <<< "$output"
    grep -qF -- 'total=2 done=1 stalled=0 threshold=900 verdict=OK' <<< "$output"
}

@test "T11: result 済み old は DONE・result 無し old は STALL（抑止が過剰でない＝検知面保持）" {
    mk_agent finished2 '2 hours ago'
    mk_agent stuck '2 hours ago'
    mk_journal_result finished2
    run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 3 ]
    grep -qE -- 'agent=finished2 ageSec=[0-9]+ verdict=DONE' <<< "$output"
    grep -qE -- 'agent=stuck ageSec=[0-9]+ verdict=STALL' <<< "$output"
    grep -qF -- 'total=2 done=1 stalled=1 threshold=900 verdict=STALL' <<< "$output"
}

@test "T12: scan 中の stat 失敗は rc2（宣言空間へ倒す・rc1 に漏らさない = MF-3）" {
    mk_agent statfail
    local SHIM="$BATS_TEST_TMPDIR/shim"
    mkdir -p "$SHIM"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$SHIM/stat"
    chmod +x "$SHIM/stat"
    PATH="$SHIM:$PATH" run "$SCRIPT" --dir "$WFDIR" --threshold 900
    [ "$status" -eq 2 ]
    grep -qF -- 'INDETERMINATE' <<< "$output"
}

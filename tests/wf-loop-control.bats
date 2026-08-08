#!/usr/bin/env bats
# wf-loop-control.bats — WF 外側ループ 4 点の機械化の teeth（bd sc-46kv・M0 外側 4 裁定 = orch-zkkq M0-P1）
#
# 対象:
#   scripts/scribe-wf-rerun-judge.sh（judge=(1) 再走可否機械判定 / count・marker=(3) escalation 計数）
#   scripts/scribe-wf-cost.sh（probe/record=(4) 値札 emitter・gate-attest 同型）
#   docs/protocol.md の pointer 1 行（(2) resume 手順は judge script の usage header が規約本文）
#
# 書式規約は protocol-pins.bats と同一: grep -qF -- 形・パイプ終端 head -1 禁止・count は herestring /
# file-arg。fixture は $BATS_TEST_TMPDIR に生成（repo を汚さない）。
#
# assertion inventory（fsev P7・invariant / polarity / mutant_fingerprint）:
#   T1: invariant=両 script が実在し bash -n が通り実行可 / polarity=positive /
#       mutant_fingerprint=構文破壊で bash -n RED
#   T2: invariant=judge が capExceeded=false → ACCEPT rc0 / polarity=positive /
#       mutant_fingerprint=fixture の capExceeded を true にすると verdict が変わる（T3/T4 が対照）
#   T3: invariant=blocking 級（critical/unknown）drop → RERUN-REQUIRED rc1・capReport との
#       食い違いは大きい側（fail-closed） / polarity=positive / mutant_fingerprint=severity を minor に
#       すると rc0 へ flip（T4 が対照）
#   T4: invariant=minor/nit 尾切りのみ → ACCEPT rc0（受容） / polarity=positive /
#       mutant_fingerprint=T3 と相互対照
#   T5: invariant=parse 不能・cap 契約 key 欠落 → INCONCLUSIVE rc2（rc0 に丸めない） / polarity=negative /
#       mutant_fingerprint=丸め込み改変で rc0 になれば RED
#   T5b: invariant=shape 不正 4 型（矛盾入力/severity 欠落/非 boolean capExceeded/非配列・非 object）が
#        rc2 or rc1 へ倒れ宣言 rc 空間 {0,1,2,4} の外へ漏れない（gate r1 E1） / polarity=negative /
#        mutant_fingerprint=shape 検証の削除で (iv) が rc5 化し RED
#   T5c: invariant=BAD_USAGE は rc4（rc1 と衝突しない） / polarity=negative /
#        mutant_fingerprint=jdie を scribe_die へ戻すと rc1 化し RED
#   T5d: invariant=(2) resume 規約本文が judge usage header に実在（gate r1 E3） / polarity=positive /
#        mutant_fingerprint=header の resumeFromRunId 行削除 copy で pin RED（test 内で実測）
#   T7b: invariant=count の bead 不在は rc2 BEAD_NOT_FOUND（n=0 auto=OK へ倒さない・gate r1 E2）+
#        bd read の timeout seam 実在（E4） / polarity=negative /
#        mutant_fingerprint=不在 guard 削除で auto=OK 化し RED（bd shim で hermetic 実測）
#   T6: invariant=judge 既定 severity 集合が cell-quality の CAP_BLOCKING_DROP_SEVERITIES の
#       mirror（3 要素一致・第 4 要素なし） / polarity=positive(anti-drift pin) /
#       mutant_fingerprint=どちらか一方の集合変更で RED
#   T7: invariant=count が marker 0 件 → auto=OK / 1 件以上 → REASON-REQUIRED / 読めない → rc2 /
#       polarity=positive+negative / mutant_fingerprint=marker 行削除で分岐が flip
#   T8: invariant=marker 出力が行頭 [WF-RERUN--<id>] 形で count が往復検出できる / polarity=positive /
#       mutant_fingerprint=header 改変で count 0 に落ち RED
#   T9: invariant=cost probe が run record から全 field を値札行へ抽出・不在は rc2 で JOURNAL-NOT-FOUND を
#       loud emit・値札行に絶対パスを含まない / polarity=positive+negative /
#       mutant_fingerprint=journal 削除で rc2 側へ flip
#   T10: invariant=record --dry-run は bd を書かない（DRY-RUN 行のみ） / polarity=negative /
#        mutant_fingerprint=dry-run 分岐削除で bdw 実呼出し＝RED（bdw 不在環境で die）
#   T11: invariant=新語彙（判定行・marker・値札行）が §6 監視トリガー語と非衝突 / polarity=negative /
#        mutant_fingerprint=header に [DONE-- 等を含めると RED
#   T12: invariant=protocol §4 に pointer 1 行が実在し削除で RED / polarity=positive+mutation /
#        mutant_fingerprint=M（下記）が行削除 flip を実測

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    JUDGE="$REPO/scripts/scribe-wf-rerun-judge.sh"
    COST="$REPO/scripts/scribe-wf-cost.sh"
    WF="$REPO/workflows/cell-quality.workflow.js"
    PROTOCOL="$REPO/docs/protocol.md"
    # hermetic: 環境の上書き変数が T2-T5 の既定集合前提を汚さないように剥がす（gate r1 E6）
    unset SCRIBE_WF_RERUN_SEVERITIES
}

@test "T1: 両 script が実在し bash -n が通る" {
    [ -x "$JUDGE" ]
    [ -x "$COST" ]
    bash -n "$JUDGE"
    bash -n "$COST"
}

@test "T2: judge — capExceeded=false は ACCEPT rc0（no-drop）" {
    local fx="$BATS_TEST_TMPDIR/nodrop.json"
    printf '%s' '{"capExceeded":false,"capReport":{"droppedBlocking":0},"capDropped":[]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 0 ]
    grep -qF -- 'verdict=ACCEPT' <<< "$output"
    grep -qF -- 'reason=no-drop' <<< "$output"
}

@test "T3: judge — blocking 級 drop は RERUN-REQUIRED rc1（critical / unknown / capReport 大きい側）" {
    local fx="$BATS_TEST_TMPDIR/crit.json"
    printf '%s' '{"capExceeded":true,"capReport":{"droppedBlocking":1},"capDropped":[{"stage":"verify","severity":"critical","reason":"totalBudget"}]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 1 ]
    grep -qF -- 'verdict=RERUN-REQUIRED' <<< "$output"
    # lens 丸ごと drop（severity=unknown）も blocking 側
    printf '%s' '{"capExceeded":true,"capReport":{"droppedBlocking":0},"capDropped":[{"stage":"review","severity":"unknown","reason":"round-drop"}]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 1 ]
    # 2 表面（capReport vs capDropped 列挙）が食い違ったら大きい側 = fail-closed
    printf '%s' '{"capExceeded":true,"capReport":{"droppedBlocking":2},"capDropped":[{"stage":"verify","severity":"minor","reason":"perRoundVerifyTopK"}]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 1 ]
    grep -qF -- 'droppedBlocking=2' <<< "$output"
}

@test "T4: judge — minor/nit 尾切りのみは ACCEPT rc0（受容・vibe 排除の受容側）" {
    local fx="$BATS_TEST_TMPDIR/tail.json"
    printf '%s' '{"capExceeded":true,"capReport":{"droppedBlocking":0},"capDropped":[{"stage":"verify","severity":"minor","reason":"perRoundVerifyTopK"},{"stage":"verify","severity":"nit","reason":"perRoundVerifyTopK"}]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 0 ]
    grep -qF -- 'reason=tail-only' <<< "$output"
}

@test "T5: judge — parse 不能 / cap 契約 key 欠落は INCONCLUSIVE rc2（rc0 に丸めない）" {
    local fx="$BATS_TEST_TMPDIR/broken.json"
    printf '%s' 'not-json' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    grep -qF -- 'reason=PARSE_FAILED' <<< "$output"
    printf '%s' '{"blocking":[],"converged":true}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    grep -qF -- 'SHAPE_INVALID' <<< "$output"
}

@test "T5b: judge — shape 不正 4 型は rc2 へ倒れ・宣言 rc 空間 {0,1,2,4} の外へ漏れない（gate r1 E1）" {
    local fx="$BATS_TEST_TMPDIR/shape.json"
    # (i) 自己矛盾: capExceeded=false なのに blocking 級 capDropped 非空 → CONTRADICTION rc2（ACCEPT に丸めない）
    printf '%s' '{"capExceeded":false,"capReport":{"droppedBlocking":0},"capDropped":[{"severity":"critical"},{"severity":"critical"}]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    grep -qF -- 'CONTRADICTION' <<< "$output"
    # (ii) severity 欠落 entry は unknown 既定＝blocking 側（上流 severity||unknown と同じ意味論）
    printf '%s' '{"capExceeded":true,"capReport":{},"capDropped":[{"stage":"verify"}]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 1 ]
    grep -qF -- 'verdict=RERUN-REQUIRED' <<< "$output"
    # (iii) capExceeded が null / "false" 文字列 → SHAPE_INVALID rc2（rc0 に丸めない）
    printf '%s' '{"capExceeded":null,"capReport":{},"capDropped":[]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    printf '%s' '{"capExceeded":"false","capReport":{},"capDropped":[]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    # (iv) capReport が string / capDropped が object → rc2（jq die の rc=5 を宣言空間外へ漏らさない）
    printf '%s' '{"capExceeded":true,"capReport":"broken","capDropped":[]}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    printf '%s' '{"capExceeded":true,"capReport":{},"capDropped":{"a":1}}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    # (v) capExceeded=true で内訳が両面とも読めない → DROP_DETAIL_MISSING rc2（受容へ倒さない）
    printf '%s' '{"capExceeded":true}' > "$fx"
    run "$JUDGE" judge --result-file "$fx"
    [ "$status" -eq 2 ]
    grep -qF -- 'DROP_DETAIL_MISSING' <<< "$output"
}

@test "T5c: judge — BAD_USAGE は rc4（rc1〔再走要〕と衝突しない専用 rc）" {
    run "$JUDGE" judge --result-file "$BATS_TEST_TMPDIR/no-such.json"
    [ "$status" -eq 4 ]
    run "$JUDGE" judge --unknown-flag
    [ "$status" -eq 4 ]
}

@test "T5d: judge 規約本文（resume 手順）が usage header に実在する（gate r1 E3 の teeth）" {
    grep -qF -- 'resumeFromRunId' "$JUDGE"
    grep -qF -- 'resume が効かない 3 条件' "$JUDGE"
    grep -qF -- '(i)' "$JUDGE"
    grep -qF -- '(iii)' "$JUDGE"
    grep -qF -- '初回と同一 args を明示再送' "$JUDGE"
    # mutation: header から resumeFromRunId 行を削った copy では本 pin が RED（非空虚）
    local mut="$BATS_TEST_TMPDIR/judge-mut.sh"
    grep -vF -- 'resumeFromRunId' "$JUDGE" > "$mut"
    run grep -qF -- 'resumeFromRunId' "$mut"
    [ "$status" -ne 0 ]
}

@test "T6: 既定 severity 集合は CAP_BLOCKING_DROP_SEVERITIES の mirror（anti-drift pin）" {
    # judge 側の既定
    grep -qF -- 'DEFAULT_SEVERITIES="critical,major,unknown"' "$JUDGE"
    # workflow 側の集合（同 3 要素・第 4 要素なし。quote 内は任意文字を許す regex＝'sev-1' 等の
    # hyphen/digit/大文字の追加メンバーも数え漏らさない・gate r1 E6）
    local wfline
    wfline="$(grep -F -- 'const CAP_BLOCKING_DROP_SEVERITIES = new Set(' "$WF")"
    grep -qF -- "'critical'" <<< "$wfline"
    grep -qF -- "'major'" <<< "$wfline"
    grep -qF -- "'unknown'" <<< "$wfline"
    local n
    n="$(grep -o -- "'[^']*'" <<< "$wfline" | grep -c . || true)"
    [ "$n" -eq 3 ]
}

@test "T7b: count — bead 不在（bd show が []）は rc2 BEAD_NOT_FOUND へ倒れる（fail-open 封鎖・gate r1 E2）" {
    # 偽 bd shim を PATH 先頭へ置き、実 bd に依存せず [] 応答を再現する（hermetic）
    local shim="$BATS_TEST_TMPDIR/shim"
    mkdir -p "$shim"
    printf '%s\n' '#!/usr/bin/env bash' 'echo "[]"' > "$shim/bd"
    chmod +x "$shim/bd"
    PATH="$shim:$PATH" run "$JUDGE" count --id sc-nope1 --anchor "$BATS_TEST_TMPDIR"
    [ "$status" -eq 2 ]
    grep -qF -- 'reason=BEAD_NOT_FOUND' <<< "$output"
    # bd 自体の失敗（非 0 exit）も rc2 BD_READ_FAILED
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$shim/bd"
    PATH="$shim:$PATH" run "$JUDGE" count --id sc-nope1 --anchor "$BATS_TEST_TMPDIR"
    [ "$status" -eq 2 ]
    grep -qF -- 'reason=BD_READ_FAILED' <<< "$output"
    # timeout ラップの実在（env seam 名ごと pin・実測は shim 経路が担う）
    grep -qF -- 'SCRIBE_WF_LOOP_BD_TIMEOUT' "$JUDGE"
}

@test "T7: count — 0 件は auto=OK / 1 件以上は REASON-REQUIRED / 読めないは rc2" {
    local notes="$BATS_TEST_TMPDIR/notes.txt"
    printf '%s\n' '通常の note 行（marker なし）' > "$notes"
    run "$JUDGE" count --id sc-test1 --notes-file "$notes"
    [ "$status" -eq 0 ]
    grep -qF -- 'n=0 auto=OK' <<< "$output"
    printf '%s\n' '[WF-RERUN--sc-test1] n=1 run=wf_x verdict=RERUN-REQUIRED utc=t reason=r' >> "$notes"
    run "$JUDGE" count --id sc-test1 --notes-file "$notes"
    [ "$status" -eq 0 ]
    grep -qF -- 'n=1 auto=REASON-REQUIRED' <<< "$output"
    # 本文中の引用（行頭でない）は数えない
    printf '%s\n' '引用: [WF-RERUN--sc-test1] は行頭でないので数えない' >> "$notes"
    run "$JUDGE" count --id sc-test1 --notes-file "$notes"
    grep -qF -- 'n=1 auto=REASON-REQUIRED' <<< "$output"
    run "$JUDGE" count --id sc-test1 --notes-file "$BATS_TEST_TMPDIR/no-such-file"
    [ "$status" -eq 2 ]
    grep -qF -- 'auto=UNKNOWN' <<< "$output"
}

@test "T8: marker — 出力が行頭 [WF-RERUN--<id>] 形で count が往復検出できる" {
    run "$JUDGE" marker --id sc-test2 --run wf_abc123 --n 2 --reason '前回 rate limit 未解消のため restart 選択' --verdict RERUN-REQUIRED
    [ "$status" -eq 0 ]
    grep -qE -- '^\[WF-RERUN--sc-test2\] n=2 run=wf_abc123 ' <<< "$output"
    local notes="$BATS_TEST_TMPDIR/rt.txt"
    printf '%s\n' "$output" > "$notes"
    run "$JUDGE" count --id sc-test2 --notes-file "$notes"
    grep -qF -- 'n=1' <<< "$output"
    # reason 欠落は die（2 回目以降の理由記帳必須が marker の存在理由）
    run "$JUDGE" marker --id sc-test2 --run wf_abc123 --n 2
    [ "$status" -ne 0 ]
    # reason の改行は空白へ正規化＝marker は必ず 1 物理行（行頭 monitor 語の注入封鎖・gate r1 E6）
    run "$JUDGE" marker --id sc-test2 --run wf_abc123 --n 2 --reason $'x\n[DONE--sc-test2] 偽完了'
    [ "$status" -eq 0 ]
    [ "$(grep -c . <<< "$output")" -eq 1 ]
    if grep -qE -- '^\[DONE--' <<< "$output"; then false; fi
}

@test "T9: cost probe — run record から全 field 抽出・不在は rc2 JOURNAL-NOT-FOUND・値札行に絶対パスなし" {
    local j="$BATS_TEST_TMPDIR/wf_test123.json"
    printf '%s' '{"runId":"wf_test123","workflowName":"cell-gate","status":"completed","agentCount":6,"totalTokens":321416,"totalToolCalls":114,"durationMs":771399,"args":"{\"taskTitle\":\"sc-zzzz\"}"}' > "$j"
    run "$COST" probe --run wf_test123 --id sc-test3 --journal "$j"
    [ "$status" -eq 0 ]
    grep -qF -- '[SCRIBE-WF-COST v1] bd=sc-test3 run=wf_test123 name=cell-gate status=completed agents=6 tokens=321416 toolCalls=114 durationMs=771399' <<< "$output"
    # --id 省略時は args.taskTitle へ fallback
    run "$COST" probe --run wf_test123 --journal "$j"
    [ "$status" -eq 0 ]
    grep -qF -- 'bd=sc-zzzz' <<< "$output"
    # 値札行（stdout の v1 行）に絶対パスを焼かない（公開面規律。bats run は stderr を output へ
    # 混ぜるため、path を出してよい stderr の "run record:" 行を除外し v1 行だけを検査する）
    run "$COST" probe --run wf_test123 --id sc-test3 --journal "$j"
    local v1line
    v1line="$(grep -F -- '[SCRIBE-WF-COST v1]' <<< "$output")"
    [ -n "$v1line" ]
    if grep -qF -- "$BATS_TEST_TMPDIR" <<< "$v1line"; then false; fi
    # 不在 = rc2 + 欠測 loud（消費ゼロと読ませない）
    run "$COST" probe --run wf_nothere1 --id sc-test3 --config-dir "$BATS_TEST_TMPDIR/empty-config"
    [ "$status" -eq 2 ]
    grep -qF -- 'status=JOURNAL-NOT-FOUND' <<< "$output"
    # record モードの不在は NOT-FOUND 行を durable append する経路（--dry-run で invocation 形を確認・gate r1 E6）
    run "$COST" record --run wf_nothere1 --id sc-test3 --config-dir "$BATS_TEST_TMPDIR/empty-config" --dry-run
    [ "$status" -eq 2 ]
    grep -qF -- 'DRY-RUN record:' <<< "$output"
    grep -qF -- 'status=JOURNAL-NOT-FOUND' <<< "$output"
    # --journal と --run の runId 不一致は fail-loud（誤帰属封鎖・gate r1 E6）
    run "$COST" probe --run wf_wrongrun --id sc-test3 --journal "$j"
    [ "$status" -ne 0 ]
    if grep -qF -- '[SCRIBE-WF-COST v1] bd=sc-test3 run=wf_wrongrun name=' <<< "$output"; then false; fi
}

@test "T10: cost record --dry-run は bd を書かない（DRY-RUN 行 + 値札行のみ・実 write 痕跡なし）" {
    local j="$BATS_TEST_TMPDIR/wf_test456.json"
    printf '%s' '{"runId":"wf_test456","workflowName":"cell-quality","status":"completed","agentCount":10,"totalTokens":1000,"totalToolCalls":9,"durationMs":5,"args":{}}' > "$j"
    run "$COST" record --run wf_test456 --id sc-test4 --journal "$j" --dry-run
    [ "$status" -eq 0 ]
    grep -qF -- 'DRY-RUN record:' <<< "$output"
    grep -qF -- '[SCRIBE-WF-COST v1] bd=sc-test4 run=wf_test456' <<< "$output"
    # bd 実 write の痕跡（bdw の成功出力）が無いことを積極表明（gate r1 E6・実 write なら bdw が
    # 「Updated issue」を出すか sc-test4 不在で非 0 になる＝どちらでも本 assert 群が落ちる）
    if grep -qF -- 'Updated issue' <<< "$output"; then false; fi
}

@test "T11: 新語彙が §6 監視トリガー語と非衝突（STATUS: 行頭 / [DONE-- / [SPAWNED-- / gate-pending）" {
    local lines
    lines="$("$JUDGE" marker --id sc-test5 --run wf_x --n 1 --reason r)"
    lines+=$'\n'"$(printf '%s' '{"capExceeded":false,"capReport":{},"capDropped":[]}' | "$JUDGE" judge)"
    local notes="$BATS_TEST_TMPDIR/hyg.txt"; : > "$notes"
    lines+=$'\n'"$("$JUDGE" count --id sc-test5 --notes-file "$notes")"
    local j="$BATS_TEST_TMPDIR/wf_hyg1.json"
    printf '%s' '{"runId":"wf_hyg1","workflowName":"x","status":"completed","agentCount":1,"totalTokens":1,"totalToolCalls":1,"durationMs":1,"args":{}}' > "$j"
    lines+=$'\n'"$("$COST" probe --run wf_hyg1 --id sc-test5 --journal "$j" 2>/dev/null)"
    # vacuous 防止: 出力が空のまま「衝突なし」を green にしない（gate r1 E6）
    [ "$(grep -c '\[' <<< "$lines")" -ge 3 ]
    if grep -qE -- '^STATUS:' <<< "$lines"; then false; fi
    if grep -qF -- '[DONE--' <<< "$lines"; then false; fi
    if grep -qF -- '[SPAWNED--' <<< "$lines"; then false; fi
    if grep -qF -- 'gate-pending' <<< "$lines"; then false; fi
}

@test "T12: protocol §4 区間内に pointer 1 行が実在する（機械実装が SSOT・両 script 名・節 scope）" {
    # §4 区間抽出（別節への移設は RED・protocol-pins.bats の節 scope と同経路・gate r1 E6）
    local sec
    sec="$(sed -n '/^## 4\./,/^## 5\./p' "$PROTOCOL")"
    grep -qF -- 'WF 外側ループ 4 点' <<< "$sec"
    grep -qF -- 'scripts/scribe-wf-rerun-judge.sh' <<< "$sec"
    grep -qF -- 'scripts/scribe-wf-cost.sh' <<< "$sec"
    grep -qF -- 'usage header が規約本文' <<< "$sec"
}

@test "M: mutation — pointer 行を削ると T12 pin が RED へ flip する（ちょうど 1 行・削除実効確認）" {
    local mut="$BATS_TEST_TMPDIR/mut-protocol.md"
    grep -qF -- 'WF 外側ループ 4 点' "$PROTOCOL"
    grep -vF -- 'WF 外側ループ 4 点' "$PROTOCOL" > "$mut"
    [ "$(( $(wc -l < "$PROTOCOL") - $(wc -l < "$mut") ))" -eq 1 ]
    run grep -qF -- 'scripts/scribe-wf-rerun-judge.sh' "$mut"
    [ "$status" -ne 0 ]
}

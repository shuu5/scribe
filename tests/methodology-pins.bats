#!/usr/bin/env bats
# methodology-pins.bats — docs/methodology.md の codify 保護 pin（bd sc-irkr ← courier orch-hoyj）
#
# 守るもの（literal pin・grep -F 形）:
#   §2「ad-hoc WF の args 必須プリアンブル」——3 要素 (a)(b)(c) / snippet SSOT・機械 gate の指す先
#   （path 実在込み）/ 呼出元規律（narrator 行での args 解決確認・undefined 即停止・resume args 再送・
#   優先順位 3 段）。protocol.md の pin は protocol-pins.bats の責務（本 file へ足さない）。
#
# 書式規約は protocol-pins.bats と同一: pin は grep -qF -- 形（固定文字列・ugrep ラッパー環境差の回避）・
# パイプ終端 head -1 禁止・count は herestring / file-arg。変異対照は $BATS_TEST_TMPDIR 上の mutant copy
# に対して行い、本物の docs と git 履歴を汚さない。pin literal は採用前に base 0 hit / HEAD 1 hit を実測済み
# （sc-aprn gate F2 の cross-satisfy 回避規律・bd sc-irkr DONE note に実測ログ）。
#
# assertion inventory（fsev P7・invariant / polarity / mutant_fingerprint）:
#   T1: invariant=対象 doc と参照先実体が実在 / polarity=positive / mutant_fingerprint=path 削除で RED
#   T2: invariant=3 要素 (a)(b)(c) と throw 中核句が全て実在 / polarity=positive /
#       mutant_fingerprint=M1（(b) 行削除で T2 RED flip を実測）
#   T3: invariant=snippet SSOT / 機械 gate の指す先が §2 に明示され path が repo に実在 / polarity=positive /
#       mutant_fingerprint=M1 ループが該当 literal 行削除で RED flip を実測
#   T4: invariant=呼出元規律（args 解決確認・resume args 再送・優先順位 3 段）が実在 / polarity=positive /
#       mutant_fingerprint=M1 ループが該当 literal 行削除で RED flip を実測
#   M1: invariant=全 pin が非空虚（対応行の削除で必ず RED へ flip する） / polarity=negative(mutation) /
#       mutant_fingerprint=自身が変異対照（各 literal につき削除行数 ≥1 を確認してから flip を読む）

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    DOC="$REPO/docs/methodology.md"
}

# 全 pin literal の単一 SSOT（T2-T4 と M1 変異対照が同じ集合を読む＝pin 追加時はここへ足す）
PINS=(
    'ad-hoc WF の args 必須プリアンブル'
    '(a) 防御的 args parse'
    '(b) 必須 args の fail-fast'
    '(c) receivedArgs（受領 args の要約）を返り値へ'
    'agent を 1 体も起動せず即 throw'
    'canonical snippet SSOT = `workflows/lib/args-preamble.snippet.js`'
    '機械 gate = `scripts/scribe-wf-args-lint.sh`'
    'args 解決を確認'
    'resume（`resumeFromRunId`）は args を復元しない'
    '(1) 凍結骨格の再利用 → (2) args を渡さない'
)

@test "T1: docs/methodology.md と参照先実体（snippet / lint / teeth）が実在する" {
    [ -f "$DOC" ]
    [ -f "$REPO/workflows/lib/args-preamble.snippet.js" ]
    [ -f "$REPO/scripts/scribe-wf-args-lint.sh" ]
    [ -f "$REPO/tests/wf-args-lint.bats" ]
}

@test "T2: 3 要素 (a)(b)(c) と throw 中核句が実在する" {
    grep -qF -- 'ad-hoc WF の args 必須プリアンブル' "$DOC"
    grep -qF -- '(a) 防御的 args parse' "$DOC"
    grep -qF -- '(b) 必須 args の fail-fast' "$DOC"
    grep -qF -- '(c) receivedArgs（受領 args の要約）を返り値へ' "$DOC"
    grep -qF -- 'agent を 1 体も起動せず即 throw' "$DOC"
}

@test "T3: snippet SSOT / 機械 gate の指す先が §2 に明示されている" {
    grep -qF -- 'canonical snippet SSOT = `workflows/lib/args-preamble.snippet.js`' "$DOC"
    grep -qF -- '機械 gate = `scripts/scribe-wf-args-lint.sh`' "$DOC"
}

@test "T4: 呼出元規律（args 解決確認・resume 再送・優先順位 3 段）が実在する" {
    grep -qF -- 'args 解決を確認' "$DOC"
    grep -qF -- 'resume（`resumeFromRunId`）は args を復元しない' "$DOC"
    grep -qF -- '(1) 凍結骨格の再利用 → (2) args を渡さない' "$DOC"
}

# ---------- 変異対照（pin の非空虚性を mutation で実測する） ----------

@test "M1: 各 pin literal の行を削ると当該 pin が RED へ flip する（全 pin・削除実効を確認してから読む）" {
    local lit mut n_doc n_mut
    n_doc="$(wc -l < "$DOC")"
    for lit in "${PINS[@]}"; do
        mut="$BATS_TEST_TMPDIR/mut.md"
        grep -vF -- "$lit" "$DOC" > "$mut"
        n_mut="$(wc -l < "$mut")"
        # 変異が当たったこと（≥1 行削除）を先に確認する（空振り mutation を green と誤読しない）
        [ "$n_mut" -lt "$n_doc" ]
        # 削除後は pin が RED（grep 不一致）へ flip する
        run grep -qF -- "$lit" "$mut"
        [ "$status" -ne 0 ]
    done
}

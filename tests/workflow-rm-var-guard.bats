#!/usr/bin/env bats
# workflow-rm-var-guard.bats — cell-gate / cell-quality 骨格の rm 変数 path 規約の literal 到達 pin（bd sc-ezn1・orch-ypk9 受け）
#
# assertion inventory:
#   invariant: 両骨格の agent prompt 文面に ${VAR:?} 形 rm 規約（dangerous-rm 検知の picker 停止回避 + 空展開 guard）が
#              実在し、素の変数連結 rm（rm -rf "$S/$name" / $VAR/* 形）の例示・指示が両骨格に存在しない
#   polarity:  規約行の削除（sed '/{VAR:?}/d'）で T5/T6 の対照 pin が RED / 素の変数連結 rm -rf の追加で T3 が RED
#   mutant_fingerprint: sed '/{VAR:?}/d'（規約行の行削除）・'rm -rf "$S/$name"' 形 literal の挿入
#
# 書式規約: pin は grep -qF -- 形（固定文字列・ugrep ラッパー環境差の回避）・パイプ終端 head -1 禁止。
# 変異対照は $BATS_TEST_TMPDIR 上の mutant copy に対して行い、本物の workflows/ を汚さない（protocol-pins.bats と同形）。

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CG="$REPO/workflows/cell-gate.workflow.js"
    CQ="$REPO/workflows/cell-quality.workflow.js"
}

@test "前提: 両骨格 file が実在する" {
    [ -f "$CG" ]
    [ -f "$CQ" ]
}

@test "T1 rm-var-guard: cell-gate の common preamble に \${VAR:?} 規約 literal が実在する" {
    grep -qF -- 'Bash 規律(rm・厳守)' "$CG"
    grep -qF -- '{VAR:?}' "$CG"
    grep -qF -- 'dangerous-rm' "$CG"
}

@test "T2 rm-var-guard: cell-quality の RM_VAR_GUARD が実在し ctxBlock へ配線されている" {
    grep -qF -- 'Bash 規律(rm・厳守)' "$CQ"
    grep -qF -- '{VAR:?}' "$CQ"
    grep -qF -- 'dangerous-rm' "$CQ"
    # 定義だけで未配線（prompt へ届かない）を塞ぐ: ctxBlock の配列要素としての参照を pin
    grep -qF -- 'RM_VAR_GUARD,' "$CQ"
}

@test "T3 rm-var-guard: 素の変数連結 rm 例示が両骨格に存在しない（負・T1/T2 の正 pin と対）" {
    run grep -nE 'rm -r?f +"?\$[A-Za-z_]' "$CG" "$CQ"
    [ "$status" -eq 1 ]
}

@test "T4 rm-var-guard: 焼込後も両骨格が JS として健全（AsyncFunction compile）" {
    # 骨格は Workflow tool 専用モジュール（top-level return を含む async 関数体）＝素の node --check は適用不能。
    # cell-quality-selftest.driver.mjs と同形: `export ` を剥がし new AsyncFunction で compile（syntax 不正なら throw）。
    for wf in "$CG" "$CQ"; do
        node -e '
            const { readFileSync } = require("node:fs");
            const src = readFileSync(process.argv[1], "utf8").replace(/^export const meta/m, "const meta");
            const AF = Object.getPrototypeOf(async function () {}).constructor;
            new AF("agent", "parallel", "pipeline", "phase", "log", "args", "budget", "workflow", src);
        ' "$wf"
    done
}

@test "T5 rm-var-guard 変異対照: cell-gate の規約行削除で pin が RED になる（非空虚性）" {
    mut="$BATS_TEST_TMPDIR/cell-gate.mut.js"
    sed '/{VAR:?}/d' "$CG" > "$mut"
    # 変異が実際に加わったこと（copy 同一で空転していないこと・bare '! cmd' は Bats 1.13 空虚化ゆえ run 形）
    run cmp -s "$CG" "$mut"
    [ "$status" -ne 0 ]
    run grep -qF -- '{VAR:?}' "$mut"
    [ "$status" -eq 1 ]
}

@test "T6 rm-var-guard 変異対照: cell-quality の規約行削除で pin が RED になる（非空虚性）" {
    mut="$BATS_TEST_TMPDIR/cell-quality.mut.js"
    sed '/{VAR:?}/d' "$CQ" > "$mut"
    run cmp -s "$CQ" "$mut"
    [ "$status" -ne 0 ]
    run grep -qF -- '{VAR:?}' "$mut"
    [ "$status" -eq 1 ]
}

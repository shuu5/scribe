#!/usr/bin/env bats
# workflow-rm-var-guard.bats — cell-gate / cell-quality 骨格の rm 変数 path 規約の literal 到達 pin（bd sc-ezn1・orch-ypk9 受け）
#
# assertion inventory:
#   invariant: 両骨格の agent prompt 文面に ${VAR:?} 形 rm 規約（dangerous-rm 検知の picker 停止回避 + 空展開 guard +
#              glob 掃除の非救済明記 = find -delete 代替）が実在し、素の変数連結 rm（flag 有無・rmdir・-- 区切り・
#              brace 無 guard 形を含む）の例示・指示が両骨格に存在しない。cell-gate は common が lens prompt へ
#              補間される配線（${common}）、cell-quality は ctxBlock 配列要素（RM_VAR_GUARD,）も pin する
#   polarity:  live 規約行の削除（grep -vF 'Bash 規律(rm・厳守)'）で T5/T6 が RED / 素の変数連結 rm の追加で T3 が RED
#   mutant_fingerprint: grep -vF -- 'Bash 規律(rm・厳守)'（live 行のみ削除・解説コメントは残る）・素の変数連結 rm literal の挿入
#
# 書式規約: pin は grep -qF -- 形（固定文字列・ugrep ラッパー環境差の回避）・パイプ終端 head -1 禁止。
# 変異対照は $BATS_TEST_TMPDIR 上の mutant copy に対して行い、本物の workflows/ を汚さない（protocol-pins.bats と同形）。
# T3 の拡張 regex は fixture 10 行（hit 6 = flag 有無/rmdir/-fr/-- 区切り/brace 無 guard・miss 4 = ${S:?} 形/find 形/
# 語中 rm/散文）で実測検証済み（sc-ezn1 gate finding N3 の additive 拡張）。

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CG="$REPO/workflows/cell-gate.workflow.js"
    CQ="$REPO/workflows/cell-quality.workflow.js"
    # N3: 素の変数連結 rm の拡張検知。bare $VAR 形と brace 無 guard 形（${S} 直後に } = :? 無し）を検知し、
    # ${VAR:?} 形（$ の直後が { かつ } の前に :? が入る）は構造的に不一致。
    BARE_RM_RE='(^|[^[:alnum:]_])rm(dir)?( -[A-Za-z-]+| --)* +"?(\$[A-Za-z_]|\$\{[A-Za-z_0-9]+\})'
}

@test "前提: 両骨格 file が実在する" {
    [ -f "$CG" ]
    [ -f "$CQ" ]
}

@test "T1 rm-var-guard: cell-gate の common preamble に \${VAR:?} 規約 + glob 条項 + lens 配線が実在する" {
    grep -qF -- 'Bash 規律(rm・厳守)' "$CG"
    grep -qF -- '{VAR:?}' "$CG"
    grep -qF -- 'dangerous-rm' "$CG"
    grep -qF -- '-mindepth 1 -delete' "$CG"
    # N5: common が lens prompt へ補間される配線の pin（外れると guard が 0 agent へ届かないまま他 pin が green の退行）
    grep -qF -- '${common}' "$CG"
}

@test "T2 rm-var-guard: cell-quality の RM_VAR_GUARD が実在し ctxBlock へ配線されている" {
    grep -qF -- 'Bash 規律(rm・厳守)' "$CQ"
    grep -qF -- '{VAR:?}' "$CQ"
    grep -qF -- 'dangerous-rm' "$CQ"
    grep -qF -- '-mindepth 1 -delete' "$CQ"
    # 定義だけで未配線（prompt へ届かない）を塞ぐ: ctxBlock の配列要素としての参照を pin
    grep -qF -- 'RM_VAR_GUARD,' "$CQ"
}

@test "T3 rm-var-guard: 素の変数連結 rm 例示が両骨格に存在しない（負・拡張 regex・T1/T2 の正 pin と対）" {
    run grep -nE "$BARE_RM_RE" "$CG" "$CQ"
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

@test "T5 rm-var-guard 変異対照: cell-gate の live 規約行のみ削除で一次 pin が RED（非空虚性）" {
    mut="$BATS_TEST_TMPDIR/cell-gate.mut.js"
    grep -vF -- 'Bash 規律(rm・厳守)' "$CG" > "$mut"
    # 変異が実際に加わったこと（bare '! cmd' は Bats 1.13 空虚化ゆえ run 形）
    run cmp -s "$CG" "$mut"
    [ "$status" -ne 0 ]
    # live 行だけ消した mutant では一次 pin（規約 phrase）が RED になる
    run grep -qF -- 'Bash 規律(rm・厳守)' "$mut"
    [ "$status" -eq 1 ]
    # 一方 補助 literal は解説コメントに残る＝この削除は phrase pin が無いと素通りする（phrase pin の必要性の証明）
    grep -qF -- '{VAR:?}' "$mut"
}

@test "T6 rm-var-guard 変異対照: cell-quality の live 規約行のみ削除で一次 pin が RED（非空虚性）" {
    mut="$BATS_TEST_TMPDIR/cell-quality.mut.js"
    grep -vF -- 'Bash 規律(rm・厳守)' "$CQ" > "$mut"
    run cmp -s "$CQ" "$mut"
    [ "$status" -ne 0 ]
    run grep -qF -- 'Bash 規律(rm・厳守)' "$mut"
    [ "$status" -eq 1 ]
    grep -qF -- '{VAR:?}' "$mut"
}

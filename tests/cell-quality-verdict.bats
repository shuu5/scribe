#!/usr/bin/env bats
# 承認体制の自律化（3 クラス基準）を実行時 carrier へ焼いたことの teeth（bd sc-tx8s / 裁定 SSOT = bd orch-vhiu）。
#
# 何を守るか（R2 = 自己再生産の遮断）:
#   cell-quality WF の CONVERGED verdict 文字列は gate を 1 回回すたびに bead notes へ転記され、
#   その notes が次の cell の先例テンプレになる。ゆえに旧カテゴリ（人間 ratify の発火条件を
#   「outward/risk」で書く形）が verdict 文字列に残る限り、doc を全部直しても儀式は再生産される。
#   本 file はその 1 行を 3 段（source pin / behavioral pin / mutation probe）で pin する。
#
# 併せて「緩めてはならない不変」も pin する（acceptance 4 の機械判定分）:
#   gate 分離（worker は自己 merge しない / push は admin が gate 後）/ ESCALATE の silent ship 禁止 /
#   薄 gate・再 review しない / 3 Note（unvNote・machNote・schemaNote）の発火条件式と 3 分岐連結 /
#   worker mandate の autonomous 規律 bullet の逐語。
#
# 規約（本 repo の bats 規約）:
#   負論理は `!` 前置を使わず `run` + 明示 assert 形で書く（`!` 前置は bats の errexit から免除され
#   pin が no-op 化する。SSOT = tests/mandate-verify-wf.bats 冒頭）。一時ファイルは $BATS_TEST_TMPDIR。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  WF="$REPO_ROOT/workflows/cell-quality.workflow.js"
  PREBAKE="$REPO_ROOT/workflows/needs-user-prebake.workflow.js"
  DRIVER="$REPO_ROOT/tests/cell-quality-selftest.driver.mjs"
  SPAWN="$REPO_ROOT/scripts/scribe-spawn.sh"
  FIXTURES="$REPO_ROOT/tests/fixtures"
  SKILL_CONSULT="$REPO_ROOT/skills/consult/SKILL.md"
  SKILL_SETUP="$REPO_ROOT/skills/setup/SKILL.md"
  SKILL_REBRIEF="$REPO_ROOT/skills/rebrief/SKILL.md"
  # 収束（CONVERGED）へ倒れる最小充足 args（review findings 既定 = 空 = clean）。
  ARGS_WORKER='{"taskTitle":"cell","worktree":"/tmp/wt","goal":"do x","selfTestCmd":"bats tests/x.bats","autoFix":true,"taskType":"testable"}'
  # 禁止トークン（旧カテゴリの実体）。「人間 ratify」単独は禁止トークンにしない
  # ＝新文面「人間 ratify が要るのは 3 クラス該当時のみ」と衝突するため。
  BANNED_A='outward/risk'
  BANNED_B='boot-path/全ホスト/破壊的'
}

# ─────────────────────────────────────────────────────────────────────────────
# (2-a) source pin: 旧カテゴリ 2 トークンの不在 + 3 クラス必須トークン + 不変トークンの存在
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-tx8s (2-a): cell-quality WF から旧カテゴリの禁止トークン 2 つが消えている" {
  [ -f "$WF" ]
  run grep -F -q -- "$BANNED_A" "$WF"
  [ "$status" -ne 0 ]
  run grep -F -q -- "$BANNED_B" "$WF"
  [ "$status" -ne 0 ]
}

@test "sc-tx8s (2-a): cell-quality WF に 3 クラス必須トークン（3 クラス/消す/出す/使う/収束証跡）が載る" {
  # 単字トークン（消す/出す/使う）は WF 内の無関係箇所にもヒットしうる＝単独では pin として空虚。
  # ゆえに「3 クラスの列挙として並んでいる」複合形を先に必須化し、単字 pin はその補助に留める。
  run grep -F -q -- '3 クラス(消す/出す/使う)' "$WF"
  [ "$status" -eq 0 ]
  # canonical block 側の 3 クラス定義行（消す/出す/使う が各 1 行として実在すること）。
  run grep -F -q -- '消す — データ / repo / 履歴 / live 成果物の破壊' "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- '出す — public 化・外部公開・外部サービスへの送信' "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- '使う — 大きな金銭コスト' "$WF"
  [ "$status" -eq 0 ]
  for tok in '3 クラス' '収束証跡'; do
    run grep -F -q -- "$tok" "$WF"
    [ "$status" -eq 0 ]
  done
}

@test "sc-tx8s (2-a): carve-out が指す docs/protocol.md の節参照が drift していない（fail-loud な cross-file 依存）" {
  # runtime carrier（CONVERGED 文字列）は sibling leg A1(sc-o2nm) の書換対象である docs/protocol.md の
  # 節番号「§5.4」と、その (c) トリガ本文へ依存する。節番号だけが振り直されると carrier は
  # 存在しない節を指したまま silent に腐る。本 pin は「参照先の節番号」と「load-bearing な本文」の
  # 双方の実在を要求し、drift を merge 時に RED として loud 化する（本 test は docs を編集しない）。
  PROTO="$REPO_ROOT/docs/protocol.md"
  [ -f "$PROTO" ]
  # (i) 本文アンカー: (c) の独立 fail-closed トリガ自体が protocol に現存する。
  run grep -F -q -- 'acceptance snapshot mismatch' "$PROTO"
  [ "$status" -eq 0 ]
  # (ii) 節番号アンカー: carrier が名指しする §5.4 が protocol に現存する。
  run grep -F -q -- '§5.4' "$PROTO"
  [ "$status" -eq 0 ]
  # (iii) carrier 側が (i)(ii) と同じ組を名指ししている（片側だけ書き換わる drift を捕える）。
  run grep -F -q -- 'acceptance snapshot mismatch は protocol §5.4(c) の独立 fail-closed' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s (2-a): CONVERGED の排他(「のみ」)に §5.4(c) carve-out が併記され独立 fail-closed を打ち消さない" {
  # 3 クラスの排他は「3 クラス軸内の排他」であって、protocol §5.4(c)（acceptance snapshot mismatch =
  # auto-merge 資格剥奪 → 人間 ratify 昇格）という直交・独立の機械 fail-closed トリガを消さない。
  # carve-out を落とした排他文言だけの巻き戻しは、契約すり替え cell の auto-merge（fail-open）を招く。
  run grep -F -q -- '3 クラス(消す/出す/使う)該当時のみ(＋ acceptance snapshot mismatch は protocol §5.4(c) の独立 fail-closed としてそのまま人間 ratify 昇格)' "$WF"
  [ "$status" -eq 0 ]
  # 設計コメント側にも「縮小は 3 クラス軸に限る」根拠が残る（carrier だけ直して理由が消えるのを防ぐ）。
  run grep -F -q -- '3 クラス分類と直交する独立の機械 fail-closed トリガ' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s (2-a): 設計の核(4) が薄 gate/再 review しない を保ち列挙が 3 項（merge 権限 + 収束証跡確認 + 3 クラス該当判定）" {
  run grep -F -q -- 'admin は薄 gate(merge 権限 + 収束証跡確認 + 3 クラス該当判定)のみ、再 review しない。' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s (2-a): canonical 3-クラス block が設計コメントへ verbatim 転記されている（誤読防止句 3 つ込み）" {
  for tok in \
    '【人間確認が要るのは「取り消せない」3 クラスのみ】' \
    'AI 敵対 gate 通過をもって AI 判断で merge する。' \
    '【聞かないこと】' \
    '【上げること】' \
    '【本裁定で緩めないもの（fence）】' \
    '人間承認を外しても **gate は外さない**' \
    '「worker が自己 merge してよい」ではない' \
    '廃止でなく scope 縮小'; do
    run grep -F -q -- "$tok" "$WF"
    [ "$status" -eq 0 ]
  done
}

@test "sc-tx8s (2-a): gate 文字列 3 種が半角 prefix（CONVERGED:/ESCALATE:/OPEN:）で始まる＝機械契約を壊さない" {
  run grep -F -q -- "? 'CONVERGED: " "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- "? 'ESCALATE: " "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- ": 'OPEN: " "$WF"
  [ "$status" -eq 0 ]
}

# ── 不変（削っていないこと）の pin ──────────────────────────────────────────

@test "sc-tx8s 不変: ESCALATE 分岐の「silent ship 禁止 — 人間が判断すること」が残る" {
  run grep -F -q -- 'ESCALATE: 未収束/self-test 失敗/machinery 失敗。silent ship 禁止 — 人間が判断すること。' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s 不変: 3 Note の発火条件式が保たれ、gate 3 分岐すべてへ連結される" {
  # 発火条件式（緩めない・空文字化しない）。
  run grep -F -q -- 'const unvNote = allUnverified.length ?' "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- 'lastH.reviewFailed || lastH.snapshotFailed' "$WF"
  [ "$status" -eq 0 ]
  run grep -F -q -- 'schemaHealth.nullDeaths.length || schemaHealth.degenerate.length' "$WF"
  [ "$status" -eq 0 ]
  # 3 分岐すべてに `+ unvNote + machNote + schemaNote` が連結されている（ちょうど 3 箇所）。
  n="$(grep -F -c -- '+ unvNote + machNote + schemaNote' "$WF")"
  [ "$n" -eq 3 ]
  # 「鵜呑み禁止」の語が unvNote に残る。
  run grep -F -q -- 'verdict 鵜呑み禁止' "$WF"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s 不変: args fail-fast の ESCALATE（agent を一切起動せず即 return）が残る" {
  run grep -F -q -- 'agent を一切起動せず' "$WF"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# (2-b) behavioral pin: driver で実走し、返り値 gate 本文まで機械照合する
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-tx8s (2-b): 実走 gate が K gatePrefix CONVERGED を出し、本文に 3 クラスが載り禁止トークンが現れない" {
  run env CQ_ARGS="$ARGS_WORKER" node "$DRIVER" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K gatePrefix CONVERGED"* ]]
  # gate 本文（RESULT の JSON 全文）に 3 クラスの語が載る。
  [[ "$output" == *"3 クラス(消す/出す/使う)"* ]]
  # 実走 gate 本文にも §5.4(c) carve-out が載る（bd notes へ転記される実 carrier が独立 fail-closed を残す）。
  [[ "$output" == *"acceptance snapshot mismatch は protocol §5.4(c) の独立 fail-closed"* ]]
  # gate 分離は不変（worker は自己 merge しない）を落としていない。
  [[ "$output" == *"gate 分離は不変(worker は自己 merge しない)"* ]]
  # 禁止トークン 2 つが実走出力に一切現れない。
  [[ "$output" != *"$BANNED_A"* ]]
  [[ "$output" != *"$BANNED_B"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# (2-c) mutation probe: 旧文面へ巻き戻したコピーで上記 assert が RED へ flip することを実測する
#       （sed no-op の空虚 probe 防止に、変異が実際に入ったことを grep + cmp で確認する）
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-tx8s (2-c): 旧文面へ巻き戻すと source pin / behavioral pin が RED へ flip する（mutation probe）" {
  mut="$BATS_TEST_TMPDIR/mut"
  mkdir -p "$mut/tests" "$mut/workflows"
  cp "$DRIVER" "$mut/tests/driver.mjs"          # driver は自ファイル位置基準で WF を解決する
  cp "$WF" "$mut/workflows/cell-quality.workflow.js"
  mutwf="$mut/workflows/cell-quality.workflow.js"

  # 変異 1: CONVERGED の runtime 文字列を旧文面へ戻す。
  sed -i "s|^    ? 'CONVERGED: .*|    ? 'CONVERGED: 収束。${BANNED_A}(${BANNED_B})があれば merge 前に人間 ratify。' + unvNote + machNote + schemaNote|" "$mutwf"
  # 変異 2: 設計の核(4) の列挙を旧文面へ戻す。
  sed -i "s|admin は薄 gate(merge 権限 + 収束証跡確認 + 3 クラス該当判定)のみ|admin は薄 gate(merge 権限 + ${BANNED_A} 人間確認 + 収束証跡確認)のみ|" "$mutwf"

  # 変異が実際に入ったこと（no-op sed でないこと）を 2 経路で確認する。
  run cmp -s "$WF" "$mutwf"
  [ "$status" -ne 0 ]
  run grep -F -q -- "$BANNED_A" "$mutwf"
  [ "$status" -eq 0 ]
  run grep -F -q -- "$BANNED_B" "$mutwf"
  [ "$status" -eq 0 ]

  # (2-a) の source pin が RED へ flip する（禁止トークン不在 assert が成立しなくなる）。
  run grep -F -q -- 'admin は薄 gate(merge 権限 + 収束証跡確認 + 3 クラス該当判定)のみ、再 review しない。' "$mutwf"
  [ "$status" -ne 0 ]

  # (2-b) の behavioral pin が RED へ flip する（実走 gate 本文に旧文字列が出て 3 クラスが消える）。
  run env CQ_ARGS="$ARGS_WORKER" node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K gatePrefix CONVERGED"* ]]   # prefix（機械契約）は変異後も不変＝差分は本文だけ
  [[ "$output" == *"$BANNED_A"* ]]
  [[ "$output" != *"3 クラス(消す/出す/使う)該当時のみ"* ]]
}

@test "sc-tx8s (2-c): carve-out だけを剥がす巻き戻し（排他文言のみ残る）も source/behavioral pin が RED へ flip する" {
  # 変異 1/2 と違い禁止トークンを持ち込まない「排他文言だけの巻き戻し」= 3 クラス語も CONVERGED prefix も
  # 残るため既存 pin は全て素通りする。§5.4(c) carve-out の pin だけがこの fail-open を捕捉することを実測する。
  mut="$BATS_TEST_TMPDIR/mut-carveout"
  mkdir -p "$mut/tests" "$mut/workflows"
  cp "$DRIVER" "$mut/tests/driver.mjs"
  cp "$WF" "$mut/workflows/cell-quality.workflow.js"
  mutwf="$mut/workflows/cell-quality.workflow.js"

  carve='(＋ acceptance snapshot mismatch は protocol §5.4(c) の独立 fail-closed としてそのまま人間 ratify 昇格)'
  sed -i "s|${carve}||" "$mutwf"

  # 変異が実際に入った（no-op sed でない）ことを 2 経路で確認する。
  run cmp -s "$WF" "$mutwf"
  [ "$status" -ne 0 ]
  run grep -F -q -- "$carve" "$mutwf"
  [ "$status" -ne 0 ]
  # 巻き戻し後は「排他だけ」の文面へ正確に戻っている（sed が別所を削っていない）。
  run grep -F -q -- '3 クラス(消す/出す/使う)該当時のみ、非該当は AI 敵対 gate 通過をもって AI 判断で merge。' "$mutwf"
  [ "$status" -eq 0 ]

  # 既存 pin は素通りする（この変異は禁止トークンを持ち込まない）＝ carve-out pin が唯一の teeth である証明。
  run grep -F -q -- "$BANNED_A" "$mutwf"
  [ "$status" -ne 0 ]
  run grep -F -q -- "$BANNED_B" "$mutwf"
  [ "$status" -ne 0 ]

  # behavioral pin が RED へ flip する（実走 gate 本文から carve-out が消える）。
  run env CQ_ARGS="$ARGS_WORKER" node "$mut/tests/driver.mjs" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"K gatePrefix CONVERGED"* ]]
  [[ "$output" == *"3 クラス(消す/出す/使う)"* ]]
  [[ "$output" != *"acceptance snapshot mismatch は protocol §5.4(c) の独立 fail-closed"* ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# 配布 WF（prebake）と skills 3 件の期待形
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-tx8s: needs-user-prebake の whenToUse が 3 クラス/grill 提案の型へ置換され、1 行構造（roAgentType 末尾）が保たれる" {
  run grep -F -q -- '3 クラス(消す/出す/使う)該当、または複数の妥当な設計が併存し選択が人間の目的・価値観に依存する論点' "$PREBAKE"
  [ "$status" -eq 0 ]
  run grep -F -q -- '承認要求ではなく grill 提案として上げる型' "$PREBAKE"
  [ "$status" -eq 0 ]
  # 既存 teeth（cell-quality-fallback.bats）と同じ形で 1 行維持を確認する（改行分割で RED になる配線の先回り）。
  out="$(grep -A2 'whenToUse:' "$PREBAKE")"
  run grep -F -q -- 'roAgentType' <<< "$out"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s: skills/consult から起動前ユーザー確認が消え、3 クラス非該当ゆえ AI 判断で起動（理由 1 行開示）へ置換" {
  run grep -F -q -- '起動前にユーザーへ確認' "$SKILL_CONSULT"
  [ "$status" -ne 0 ]
  run grep -F -q -- '3 クラス（消す/出す/使う）**非該当**' "$SKILL_CONSULT"
  [ "$status" -eq 0 ]
  run grep -F -q -- '**AI 判断で起動する**' "$SKILL_CONSULT"
  [ "$status" -eq 0 ]
  run grep -F -q -- '起動する理由を 1 行開示' "$SKILL_CONSULT"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s: skills/setup は編入判断の一問を保ちつつ grill 提案枠へ言い換え、write-isolation（自動 add しない）が不変" {
  run grep -F -q -- 'へ編入しますか?' "$SKILL_SETUP"
  [ "$status" -eq 0 ]
  run grep -F -q -- '承認要求ではなく grill 提案として上げる' "$SKILL_SETUP"
  [ "$status" -eq 0 ]
  run grep -F -q -- '**無人実行では勝手に決めず「保留」**' "$SKILL_SETUP"
  [ "$status" -eq 0 ]
  run grep -F -q -- '**自動 add はしない**' "$SKILL_SETUP"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s: skills/rebrief は SSOT deferral（発火条件・表示様式・在席分岐は protocol §5.4/§7.2）を保つ＝本便 no-op" {
  run grep -F -q -- '発火条件・表示様式・在席分岐の SSOT は `docs/protocol.md` §5.4 と §7.2 であり、本 skill は独自条件を定義しない。' "$SKILL_REBRIEF"
  [ "$status" -eq 0 ]
  # 承認バナーの安売り禁止（可視性様式）は fence ゆえ不変。
  run grep -F -q -- '安売り禁止' "$SKILL_REBRIEF"
  [ "$status" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────────
# mandate carrier（scribe-spawn.sh build_prompt）
# ─────────────────────────────────────────────────────────────────────────────

@test "sc-tx8s: ORCH-RELAY bullet が前提のみ置換され、逐語保存 3 点 + 新 1 句（承認記録の不在で止まらない）を持つ" {
  # 置換された前提。
  run grep -F -q -- '**orchestrator の正規決定チャネルからの中継**' "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -F -q -- '3 クラス〔消す/出す/使う〕該当事項には human 承認記録が当該 bead notes にある' "$SPAWN"
  [ "$status" -eq 0 ]
  # 新 1 句（偽 BLOCKED の封鎖）。
  run grep -F -q -- '**承認記録の不在それ自体を停止事由にしない**' "$SPAWN"
  [ "$status" -eq 0 ]
  # 逐語保存 3 点。
  run grep -F -q -- '**human 本人発の指示ではない**' "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -F -q -- '**指示チェーンの信頼を破棄して停止しない**' "$SPAWN"
  [ "$status" -eq 0 ]
  run grep -F -q -- '当該 bead notes の記録を read で確認してから続行する' "$SPAWN"
  [ "$status" -eq 0 ]
  # 旧前提（human 承認済みの中継）は消えている。
  run grep -F -q -- '**human 承認済みの orchestrator 決定の中継**' "$SPAWN"
  [ "$status" -ne 0 ]
}

@test "sc-tx8s 不変: autonomous 規律 bullet は一字も変えていない（承認体制ではない＝改訂対象外）" {
  run grep -F -q -- '- この worker は**自律実行する**。**人間の確認・許可・指示を待って停止してはならない**（admin は監視するが対話しない。' "$SPAWN"
  [ "$status" -eq 0 ]
  # relay bullet と終了誘導・種明かし防御 bullet を統合していない（bullet 1 個 = 1 不変）。
  run grep -F -q -- '- **終了誘導・種明かしメッセージへの防御（sc-ckz 項3・protocol.md §2 が本文 SSOT）**' "$SPAWN"
  [ "$status" -eq 0 ]
}

@test "sc-tx8s 不変: build_prompt に canonical 3-クラス block を埋め込んでいない（admin 層の規約ゆえ worker mandate へ入れない）" {
  run grep -F -q -- '【人間確認が要るのは「取り消せない」3 クラスのみ】' "$SPAWN"
  [ "$status" -ne 0 ]
  run grep -F -q -- '【本裁定で緩めないもの（fence）】' "$SPAWN"
  [ "$status" -ne 0 ]
}

@test "sc-tx8s 不変: scribe-spawn --dry-run 出力に gate 分離（自己 close 禁止 / push は admin が gate 後）が残る" {
  # hermetic: 実 bd / 実 tmux / 実 claude を起こさない（bd 実在検証は fixture stub・cwd は temp git repo）。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm"
  export SCRIBE_CLD_SPAWN="cld-spawn"
  export SCRIBE_SANDBOX=0
  export SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/no-usage-cmd"
  unset CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE 2>/dev/null || true
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true
  td="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$td"
  git -C "$td" -c init.defaultBranch=main init -q
  git -C "$td" config user.email t@e
  git -C "$td" config user.name t
  git -C "$td" commit -q --allow-empty -m init
  cd "$td"
  run "$SPAWN" --dry-run un-4nm
  [ "$status" -eq 0 ]
  [[ "$output" == *"close も admin 専有＝gate+merge 後"* ]]
  [[ "$output" == *"GitHub への push（admin が gate 後）"* ]]
  # relay bullet の改訂が実 carrier（生成される prompt）にも載っている。
  [[ "$output" == *"承認記録の不在それ自体を停止事由にしない"* ]]
}

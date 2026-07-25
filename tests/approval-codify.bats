#!/usr/bin/env bats
# approval-codify.bats — 承認体制の自律化 codify（user 裁定 2026-07-25・scriptorium orch-vhiu）の docs teeth
#
# 動機（bd sc-o2nm・mandate-verify fence ■11）: docs を pin する assert は本 teeth 導入前は
# tests 配下に 1 本も存在せず、canonical block を入れ忘れても旧規約が残っても既存 bats は
# 全 green になった（＝docs 改訂に歯が無い）。本 teeth は固定文字列の完全一致で次を pin する:
#   (1) canonical 3-クラス block が protocol.md §5.4 に verbatim（sha256 完全一致）で実在
#   (2) 誤読防止句 3 行の実在 / (3) 旧トリガー固有 literal の不在（negative）
#   (4) 本裁定で緩めない fence literal の残存 / (5) 構造 teeth（worker 注入の過剰注入・打切り検知）
#   (6) html の構造不変（要素総数・タグ balance・旧カテゴリ文字列 0・強調記号増 0）
#
# negative assert の設計注意: 素の「規約ファイル」「全ホスト配布物」で検索してはならない
# （canonical block 本文と §8 の cross-repo 判定語に**正当に**残るため false-RED になる）。
# ゆえに negative は「旧トリガー固有の長い literal」だけを狙う。

bats_require_minimum_version 1.5.0

# --- negative assert のヘルパー（load-bearing）---------------------------------
# bash の `set -e` は **`!` で反転された command の失敗を無視する**（POSIX 仕様: 戻り値が
# `!` で反転される command は errexit の対象外）。ゆえに bats テスト本文に `! grep -q ...`
# を並べると、**最終行以外の否定 assert はすべて no-op**（fail-open）になる。実測で確認済み
# （旧トリガー literal を注入しても test が green のままだった）。否定 assert は必ず本ヘルパー
# 経由の**単純コマンド**として書き、失敗を errexit に拾わせる。
assert_absent() {
    local literal="$1" file="$2"
    # fail-closed: grep はファイル不在・読取不能でも非 0 で返るため、そのままでは
    # 「読めない＝不在」と誤って PASS する（negative assert の fail-open）。先に可読性を要求する。
    if [ ! -r "$file" ]; then
        printf 'FAIL: negative assert の対象ファイルが読めない: %s\n' "$file" >&2
        return 1
    fi
    if grep -qF -- "$literal" "$file"; then
        printf 'FAIL: 不在であるべき literal が %s に存在する: %s\n' "$file" "$literal" >&2
        return 1
    fi
    return 0
}

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROTOCOL="$REPO/docs/protocol.md"
    SPEC="$REPO/docs/role-context-spec.md"
    METHOD="$REPO/docs/methodology.md"
    DESIGN="$REPO/docs/scribe-design.md"
    GUIDE="$REPO/docs/dynamic-workflow-guide.html"
    INJECT="$REPO/scripts/hooks/session-start-role-inject.sh"

    # canonical block の verbatim 基準（bd sc-o2nm description の実測値）
    CANON_SHA256="e92aa851963606510422b6d5e81693f8c05cc3679f529fb68631415da74d960d"
    CANON_LINES=23
    # html のベースライン（本 codify 時点の実測・意図的変更時のみ更新する）
    GUIDE_ELEMENTS=706
}

# §5.4 に埋め込んだ canonical block（3 スペース継続インデント + text フェンス）を
# de-indent して取り出す。verbatim 判定は「行頭空白を除いた行内容・行順・行数」で行う。
extract_canonical() {
    awk '/^   ```text$/ { f=1; next } f && /^   ```$/ { f=0; next } f { sub(/^   /, ""); print }' "$PROTOCOL"
}

@test "docs が全て実在する（teeth の前提）" {
    for f in "$PROTOCOL" "$SPEC" "$METHOD" "$DESIGN" "$GUIDE"; do
        [ -f "$f" ]
    done
}

# ---------- (1) canonical block の verbatim ----------

@test "canonical block の text フェンスが §5.4 に 1 箇所だけ存在する（verbatim コピーは 1 箇所限定）" {
    run grep -c -F -- '   ```text' "$PROTOCOL"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "canonical block が 23 行・sha256 完全一致で verbatim 埋込されている" {
    local body n sum
    body="$(extract_canonical)"
    n="$(printf '%s\n' "$body" | wc -l)"
    [ "$n" -eq "$CANON_LINES" ]
    sum="$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)"
    [ "$sum" = "$CANON_SHA256" ]
}

@test "canonical block の 4 見出しが protocol.md に実在する" {
    grep -qF -- '【人間確認が要るのは「取り消せない」3 クラスのみ】' "$PROTOCOL"
    grep -qF -- '【聞かないこと】' "$PROTOCOL"
    grep -qF -- '【上げること】' "$PROTOCOL"
    grep -qF -- '【本裁定で緩めないもの（fence）】' "$PROTOCOL"
}

@test "3 クラス（消す / 出す / 使う）の行が実在する" {
    grep -qF -- '(a) 消す — データ / repo / 履歴 / live 成果物の破壊（第一防衛線は機械 guard 層）' "$PROTOCOL"
    grep -qF -- '(b) 出す — public 化・外部公開・外部サービスへの送信' "$PROTOCOL"
    grep -qF -- '(c) 使う — 大きな金銭コスト（承認でなく予算上限で制御）' "$PROTOCOL"
}

@test "canonical block が §5 step4（§5.4）の内側にある（別節へ移設したら RED）" {
    local fence step4 step5
    fence="$(grep -n -F -- '   ```text' "$PROTOCOL" | head -1 | cut -d: -f1)"
    step4="$(grep -n -F -- '4. **merge gate（3 クラス判定・merge 自体は非トリガー）**' "$PROTOCOL" | head -1 | cut -d: -f1)"
    step5="$(grep -n -F -- '5. **push 前に origin URL 健全性を verify' "$PROTOCOL" | head -1 | cut -d: -f1)"
    [ -n "$fence" ] && [ -n "$step4" ] && [ -n "$step5" ]
    [ "$step4" -lt "$fence" ]
    [ "$fence" -lt "$step5" ]
}

# ---------- (2) 誤読防止句 3 行 ----------

@test "誤読防止句 3 行が実在する" {
    grep -qF -- '1. 人間承認を外しても **gate は外さない**（gate が実効安全弁になったので強化側）。' "$PROTOCOL"
    grep -qF -- '2. 「worker が自己 merge してよい」ではない（gate 分離＝独立レビューは不変）。' "$PROTOCOL"
    grep -qF -- '3. front-load / バナーは **廃止でなく scope 縮小**（user 裁定 2026-07-17 の可視性要件を壊さない）。' "$PROTOCOL"
}

# ---------- (3) 旧トリガー固有 literal の不在（negative） ----------

@test "negative: 旧トリガー固有の長い literal が §5.4 の承認トリガー文脈に不在" {
    assert_absent '不可逆カテゴリ（機械判定・無条件 fail-closed）' "$PROTOCOL"
    assert_absent '**(b) 設計ソフトズレ（AI gate を信頼・fail-open 寄り）**' "$PROTOCOL"
    assert_absent '① **規約ファイル** = **enforced rule / 役割契約**を定める文書' "$PROTOCOL"
    assert_absent '② **全ホスト配布物**' "$PROTOCOL"
    assert_absent '③ **新規 outward**' "$PROTOCOL"
}

# canonical block の**外側**に旧規約を**新規で書き足す**変異への歯（admin gate 差し戻し 2026-07-26）。
# 上の negative 群は「本 diff で消した旧トリガー固有の literal」だけを狙う設計ゆえ（header :12 参照）、
# 「規約ファイル / 全ホスト配布物 を touch する PR は human ratify 必須」のような**新しく書かれた
# 旧カテゴリ規則**は素通りする（admin が複製上の変異注入で not_ok=0 を実測）。本 P0 の主眼が
# 「儀式の再生産を止める」ことである以上ここを塞ぐ。
# exact literal `human ratify 必須` を選ぶ理由（false-RED しないことの実測）: 現 5 doc で 0 hit。
# 正当に残る「旧②③（規約ファイル / 全ホスト配布物）の human ratify は廃止」は『必須』を含まず、
# canonical block 本文にも誤読防止句にも出現しないため、素の「規約ファイル」等で狙う場合と違い
# 正当な残存を巻き込まない。
@test "negative: 旧カテゴリの human ratify を必須化する規則が新規に書き足されていない" {
    for f in "$PROTOCOL" "$SPEC" "$METHOD" "$DESIGN" "$GUIDE"; do
        assert_absent 'human ratify 必須' "$f"
    done
}

@test "negative: 旧呼称「二段判定」が in-scope docs から消えている" {
    assert_absent '二段判定' "$PROTOCOL"
    assert_absent '二段判定' "$SPEC"
    assert_absent '二段判定' "$METHOD"
}

@test "negative: role-context-spec §2.1 から旧カテゴリの human ratify 記述が消えている" {
    assert_absent '(a) 不可逆カテゴリ（規約ファイル / 全ホスト配布物 / 新規 outward への diff touch）' "$SPEC"
}

# ---------- 旧②③廃止と gate 必須化が「対で」明文化されている（acceptance (1)） ----------

@test "旧②③の human ratify 廃止と AI 敵対 gate 必須化が対で明文化されている" {
    grep -qF -- '**旧②③（規約ファイル / 全ホスト配布物）の human ratify は廃止**' "$PROTOCOL"
    grep -qF -- 'AI 敵対 gate（step2 の cell-quality review + step3 の findings 直読）を必ず通す gate 必須化へ置き換える' "$PROTOCOL"
    grep -qF -- '**人間承認を外しても gate は外さない**' "$PROTOCOL"
}

# ---------- 3 クラス該当時の fail-closed 強制文（本 codify の核・単一箇所ゆえ pin 必須） ----------
#
# canonical block（fence 内）は**分類の定義**であって強制の articulation を持たない。
# 「3 クラスに該当したら AI の主観に関係なく必ず止める」という規範文は §5.4 のこの 1 文だけが
# 担っており、ここが fail-open 語彙（旧 (b) 設計ソフトズレの「グレーは通す」）へ書き換わっても
# block の sha256 も 3 クラス行も誤読防止句も無傷なままになる（実測: この 1 文の書換えだけでは
# 他の全 assert が green）。ゆえに強制文それ自体を positive に pin し、旧 fail-open 語彙の
# 再流入を negative で塞ぐ。
@test "3 クラス該当時の fail-closed 強制文が実在する（グレーでも止める）" {
    grep -qF -- '**AI の主観的判断に関係なく必ずユーザー確認を取る**（グレーでも止める＝fail-closed）' "$PROTOCOL"
}

@test "negative: 旧 (b) の fail-open 語彙（グレーは確認せず通す）が再流入していない" {
    assert_absent 'グレー（設計判断の許容幅）は確認せず通す' "$PROTOCOL"
}

# ---------- 埋込注記の carve-out / carve-back を「対で」pin（クラス (b) の唯一の安全弁） ----------
#
# §5.4 の埋込注記は「public な doc への追記は『出す』に該当しない」という permissive な
# carve-out を admin 判定で新設し、その fail-open を「ただし当該追記が未公開データ…を新たに
# 公開面へ載せる場合は『出す』に該当し人間確認を取る」という carve-back **だけ**で塞いでいる
# （doc 自身が「内容ベースの本例外を欠くと permissive 側へ倒れる＝クラス (b) の fail-open」と
# 明言する）。実測: carve-back の 1 文だけを削除しても他の全 assert は green だった。
# ＝ scribe が独自に narrowing した唯一のクラスの安全弁が無防備だったため、**対で** pin して
# 片方だけが残る編集を RED にする。
@test "埋込注記の carve-out（public doc 編集は「出す」非該当）が実在する" {
    grep -qF -- '**public な doc への追記は 3 クラスの「出す」（＝新規の公開面拡大: private→public 化・新規 repo 公開・未公開データの外部送信）に該当しない**' "$PROTOCOL"
}

@test "埋込注記の carve-back（未公開データを公開面へ載せるなら「出す」）が実在する" {
    grep -qF -- '**ただし当該追記が未公開データ〔user 発言の生引用・private / foreign 台帳の内容・ホスト名 / メール / 資格情報・未公開の内部情報〕を新たに公開面へ載せる場合は「出す」に該当し人間確認を取る**' "$PROTOCOL"
    # carve-out の射程限定（行為ベースであって内容ベースではない）も対で保持する
    grep -qF -- '**既に public な doc を編集する行為そのもの**' "$PROTOCOL"
    grep -qF -- '**載せる内容の公開性ではない**' "$PROTOCOL"
}

# ---------- (4) fence（本裁定で緩めないもの）の保持 ----------

@test "fence 保持: 完了 2 段固定・gate 分離・write-isolation・GATE-SUMMARY・🔴 バナー" {
    # 完了 2 段固定（DONE note → gate-pending ラベル・worker は自己 close しない）
    grep -qF -- '完了は DONE note → gate-pending ラベルの 2 段固定' "$PROTOCOL"
    grep -qF -- '[DONE--<id>]' "$PROTOCOL"
    # gate 分離（worker は自己 merge しない）
    grep -qF -- '**worker は自己 merge も自己 close もしない**' "$PROTOCOL"
    # write-isolation（foreign 台帳 write 禁止）
    grep -qF -- '**admin が write・所有するのは自 project の台帳（`sc-`）だけ**' "$PROTOCOL"
    # park の機械可視化
    grep -qF -- 'GATE-SUMMARY(...)' "$PROTOCOL"
    grep -qF -- '`needs-user` ラベルを付与' "$PROTOCOL"
    # 可視性様式（🔴 バナー・AskUserQuestion 最優先）
    grep -qF -- '🔴 人間承認待ち: N 件' "$PROTOCOL"
    grep -qF -- 'AskUserQuestion を最優先' "$PROTOCOL"
    # 破壊操作の機械 guard（cleanup）
    grep -qF -- '**force 系は使わない**' "$PROTOCOL"
}

@test "fence 保持: park の機械可視化はトリガー定義に依存しないと明記されている" {
    grep -qF -- '**本様式はトリガーの定義に依存しない**' "$PROTOCOL"
}

@test "fence 保持: snapshot-mismatch トリガは据置（人間 ratify 昇格の文言が残る）" {
    grep -qF -- 'auto-merge 資格を剥奪し人間 ratify へ昇格' "$PROTOCOL"
}

# §7.2 の発火条件縮小注記は「3 クラス該当**のみ**」と排他形で書いてはならない。
# §5.4（227 / 263 / 268 行）と role-context-spec §2.1 は承認トリガーを 2 系統
# （3 クラス該当 ＋ snapshot-mismatch トリガ）と定義しており、§7.2 だけ 1 系統にすると
# snapshot-mismatch park の ratify 要求が front-load 6 項の対象外になり、2026-07-14 裁定が
# 塞いだ「承認要求の turn 末尾後置」を 1 トリガー分だけ再び開く（fence ■7 の据置とも矛盾する）。
@test "§7.2 の発火条件縮小注記が snapshot-mismatch トリガを含む 2 系統になっている" {
    grep -qF -- '**3 クラス該当と snapshot-mismatch トリガ該当のみ**を指す' "$PROTOCOL"
    # 3 site（§5.4 / §7.2 / role-context-spec §2.1）が同じ 2 系統で揃っていること
    grep -qF -- '**3 クラス該当**または **snapshot-mismatch トリガ該当**' "$PROTOCOL"
    grep -qF -- '3 クラス（消す / 出す / 使う）該当と snapshot-mismatch トリガのみ' "$SPEC"
}

@test "fence 保持: §7.2 の user verbatim 引用 6 項が 1 byte も改変されていない" {
    grep -qF -- '> 1. **タスク順序を承認の有無で歪めない**＝最適順序で human-gated タスクが先頭なら、承認要求が turn の最初のアクション。' "$PROTOCOL"
    grep -qF -- '> 3. **受動 offer 禁止**＝「go をもらえれば」「必要なら言ってください」等、user の再発話待ち形で human-gated タスクを turn 末尾に置かない。' "$PROTOCOL"
    grep -qF -- '> 6. **過剰補正の禁止**＝承認不要な自律域まで質問化しない（なんでも聞きに行くのは本原則の誤用）。' "$PROTOCOL"
}

# 露出の手口・経路を public doc へ敷衍しない（契約 notes ■8 の敷衍禁止・LEDGER-IS-PUBLIC 訂正）。
# WF autoFix が根拠として一度書き込んだ「公開 remote から bead 本文が平文復元できる」旨の
# 具体経路を worker が撤去した経緯があり、再流入を negative で塞ぐ（露出監査自体は admin 所管）。
# 注（negative 設計・■11 と同型）: 素の `refs/dolt/data` で検索してはならない——同期機構の
# 正当な設計記述として scribe-design.md に**既存**（本 diff 非関与）ゆえ false-RED になる。
# 狙うのは「公開面から private 台帳本文を復元する**手口**」に固有の語だけ。
@test "negative: 露出の手口（公開面から private 台帳本文を復元する経路）が公開 doc へ敷衍されていない" {
    for f in "$PROTOCOL" "$SPEC" "$METHOD" "$DESIGN" "$GUIDE"; do
        assert_absent '平文復元' "$f"
        assert_absent 'メール前綴' "$f"
        assert_absent 'から bead 本文が' "$f"
    done
}

@test "auto-merge 事後証跡義務と step6 の 3 分割（可変 / 縮小 / 不変）が実在する" {
    grep -qF -- '**`auto-merged: <gate 判定要約> + <PR/commit>`** を必ず残す' "$PROTOCOL"
    grep -qF -- '**(1) auto-merge 条件（可変）**' "$PROTOCOL"
    grep -qF -- '**(2) 3 クラス該当時の確認（縮小）**' "$PROTOCOL"
    grep -qF -- '**(3) merge 後の close は admin 専有（不変）**' "$PROTOCOL"
}

@test "role-context-spec §2.1 / scribe-design.md §14 が 3 クラス基準へ改訂されている（巻き戻し検知）" {
    grep -qF -- '3 クラス（消す / 出す / 使う）該当と snapshot-mismatch トリガのみ' "$SPEC"
    grep -qF -- '**旧・固いカテゴリ③**' "$DESIGN"
    grep -qF -- '**admin の手動判断**であって human ratify ではない' "$DESIGN"
    assert_absent '二段判定' "$DESIGN"
}

# ---------- 構造: 見出しと §5 の連番 ----------

@test "protocol.md のトップレベル見出しが 0-9 + 一次出典 のままで新設が無い（awk 節抽出の事故面を開かない）" {
    local got want
    got="$(grep -n '^## ' "$PROTOCOL" | sed 's/^[0-9]*://')"
    want='## 0. 全体像 — administrator の 1 issue ライフサイクル
## 1. spawn 規約
## 2. worker prompt 規約
## 3. B/hybrid 役割境界（worker↔beads）
## 4. gate-pending → gate → close → errata 規約
## 5. gate funnel 手順
## 6. 監視
## 7. needs-user タスクの扱い（WF pre-bake → grill-consult）
## 8. cross-ledger 境界（自 `sc-` 台帳 ↔ 他 project 台帳・federated）
## 9. セッション寿命規律（意図的 cycle・fleet 共通核）
## 一次出典（まとめ）'
    [ "$got" = "$want" ]
}

@test "§5 の順序付きリストが 1 から 8 の連番のまま（step 番号は道具から参照される硬い契約）" {
    local got
    got="$(awk '/^## 5\./ { s=1; next } /^## 6\./ { s=0 } s && /^[0-9]+\./ { n=$0; sub(/\..*/, "", n); print n }' "$PROTOCOL" | tr '\n' ' ')"
    [ "$got" = "1 2 3 4 5 6 7 8 " ]
}

# ---------- (5) 構造 teeth: worker / consult 注入の過剰注入・打切り検知 ----------
#
# hermetic 化（load-bearing・既存 tests/session-start-role-inject.bats L69/71/80/211 と同じ隔離形）:
# **teeth は必ず被検査 worktree の docs を読まねばならない**。hook は plugin root を
# `CLAUDE_PLUGIN_ROOT` 優先で解決し（script 位置からの導出は fallback）、role は env `SCRIBE_ROLE` を
# cwd より優先する。ゆえに素の `bash "$INJECT"` は ambient env 次第で
#   (1) anchor 等 **別ツリーの stale docs** を assert して green（negative assert は canonical block が
#       存在しない旧 docs に対し自明に通る＝fail-open）、
#   (2) `SCRIBE_ROLE=none`（scriptorium anchor の実配線・sc-cji）や `SCRIBE_ROLE=admin` で false-RED、
# のいずれにも倒れる。全 invocation で env を明示隔離し、被検査ツリー（$REPO）を焼き込むこと。

@test "worker 注入抽出が §2 末尾行と §4 末尾行を含む（打切り検知）" {
    local wt out
    wt="$BATS_TEST_TMPDIR/proj/.worktrees/spawn/x-1"
    mkdir -p "$wt/.beads"
    out="$BATS_TEST_TMPDIR/worker-inject.txt"
    printf '%s' "{\"cwd\":\"$wt\"}" \
        | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX -u SCRIBE_WORKER -u SCRIBE_WORKTREE \
              CLAUDE_PLUGIN_ROOT="$REPO" bash "$INJECT" > "$out" 2>/dev/null || true
    [ -s "$out" ]
    # §2 の末尾行（一次出典）
    grep -qF -- 'scriptorium orch-3bop（un-xnks 中継・本 bullet 成文化 leg = bd sc-c1ur）。' "$out"
    # §4 の末尾行（一次出典）
    grep -qF -- '見直しトリガー medium 5 本。基準本文 SSOT = `docs/methodology.md` §1.1）**。' "$out"
    # §3 の本文（中間節が落ちていない）
    grep -qF -- '## 3. B/hybrid 役割境界（worker↔beads）' "$out"
}

@test "worker 注入抽出に §5 本文と canonical block が混入しない（過剰注入検知・§9 到達範囲の閉包）" {
    local wt out
    wt="$BATS_TEST_TMPDIR/proj/.worktrees/spawn/x-2"
    mkdir -p "$wt/.beads"
    out="$BATS_TEST_TMPDIR/worker-inject2.txt"
    printf '%s' "{\"cwd\":\"$wt\"}" \
        | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX -u SCRIBE_WORKER -u SCRIBE_WORKTREE \
              CLAUDE_PLUGIN_ROOT="$REPO" bash "$INJECT" > "$out" 2>/dev/null || true
    [ -s "$out" ]
    assert_absent '## 5. gate funnel 手順' "$out"
    assert_absent '【人間確認が要るのは「取り消せない」3 クラスのみ】' "$out"
    assert_absent '## 8. cross-ledger 境界' "$out"
}

@test "consult 注入抽出（role-context-spec §2.3）が非空のまま（§2.3 は本 leg で触っていない）" {
    local anchor out
    anchor="$BATS_TEST_TMPDIR/anchor"
    mkdir -p "$anchor/.beads"
    out="$BATS_TEST_TMPDIR/consult-inject.txt"
    # consult は env 側で明示代入する（cwd=anchor は既定 admin 判定ゆえ role を env で焼く）
    printf '%s' "{\"cwd\":\"$anchor\"}" \
        | env -u TMUX -u TMUX_PANE -u SCRIBE_TMUX -u SCRIBE_WORKER -u SCRIBE_WORKTREE \
              SCRIBE_ROLE=consult CLAUDE_PLUGIN_ROOT="$REPO" bash "$INJECT" > "$out" 2>/dev/null || true
    [ -s "$out" ]
    # §2.3 の先頭見出しと末尾行（一次出典）— 水平線の新設等で silent に落ちていないこと
    grep -qF -- '### 2.3 consult（anchor 同居可・read-only セッション）' "$out"
    grep -qF -- '手順 SSOT = `protocol.md` §7）。' "$out"
    assert_absent '【人間確認が要るのは「取り消せない」3 クラスのみ】' "$out"
}

# ---------- 仕様 doc は pointer 型（verbatim コピーは §5.4 の 1 箇所のみ） ----------

@test "仕様 doc 4 件は canonical block 本文を転記せず §5.4 を指す pointer 型に留まる" {
    for f in "$SPEC" "$METHOD" "$DESIGN" "$GUIDE"; do
        assert_absent '【人間確認が要るのは「取り消せない」3 クラスのみ】' "$f"
        assert_absent '【本裁定で緩めないもの（fence）】' "$f"
    done
    grep -qF -- '`docs/protocol.md` §5.4' "$SPEC"
    grep -qF -- '`protocol.md` §5.4' "$METHOD"
    grep -qF -- '`docs/protocol.md` §5.4' "$DESIGN"
}

@test "methodology.md の risk 因子（規約変更・全ホスト配布・外部公開・不可逆性・波及範囲）が削除されていない" {
    grep -qF -- 'blast radius・不可逆性・outward 性（規約変更・全ホスト配布・外部公開）' "$METHOD"
    grep -qF -- '**AI gate 強度**' "$METHOD"
}

# ---------- (6) html teeth ----------

@test "html: 要素総数が不変・タグ balance が取れている" {
    run python3 - "$GUIDE" <<'PY'
import sys
from html.parser import HTMLParser
VOID = {'br', 'img', 'meta', 'link', 'hr', 'input', 'source', 'area', 'base', 'col'}
class P(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []; self.n = 0; self.bad = 0
    def handle_starttag(self, tag, attrs):
        self.n += 1
        if tag not in VOID:
            self.stack.append(tag)
    def handle_endtag(self, tag):
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()
        else:
            self.bad += 1
p = P()
with open(sys.argv[1], encoding='utf-8') as fh:
    p.feed(fh.read())
print(f"{p.n} {len(p.stack)} {p.bad}")
PY
    [ "$status" -eq 0 ]
    [ "$output" = "$GUIDE_ELEMENTS 0 0" ]
}

@test "html: 旧カテゴリ文字列 0 件・強調記号（**）の増加 0・risk 因子は保持" {
    assert_absent '人間確認の閾値' "$GUIDE"
    assert_absent 'merge と不可逆操作の人間確認のみ担う' "$GUIDE"
    assert_absent '二段判定' "$GUIDE"
    assert_absent '**' "$GUIDE"
    grep -qF -- '不可逆性・外部公開・波及範囲' "$GUIDE"
    grep -qF -- '人間確認は3クラス（消す/出す/使う）該当時のみ' "$GUIDE"
}

@test "html: <title> が保持されている（tailnet 提示面の識別）" {
    grep -qF -- '<title>Dynamic Workflow 完全図解 — scribe での使われ方まで</title>' "$GUIDE"
}

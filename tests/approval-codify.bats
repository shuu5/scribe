#!/usr/bin/env bats
# approval-codify.bats — 承認体制の自律化 codify（user 裁定 2026-07-25・scriptorium orch-vhiu）の docs teeth
#
# 動機（bd sc-o2nm・mandate-verify fence ■11）: docs を pin する assert は本 teeth 導入前は
# tests 配下に 1 本も存在せず、canonical block を入れ忘れても旧規約が残っても既存 bats は
# 全 green になった（＝docs 改訂に歯が無い）。本 teeth は固定文字列の完全一致で次を pin する:
#   (1) canonical 3-クラス block **v2** が protocol.md §5.4 に verbatim（18 行 / 1359 字 / sha256 完全一致）で実在
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
    VERDICT="$REPO/tests/cell-quality-verdict.bats"

    # canonical block **v2** の verbatim 基準（一次 SSOT = scriptorium orch-vhiu notes・
    # in-repo carrier = skills/setup/PRIME.template.md の canonical-3class-block-v2 sentinel 区間）。
    # 期待値は literal で焼く（自ファイル・被検査ファイルから再計算した値を期待値にする自己参照 pin は
    # 不可＝reflow 済みや typo 混入の「自称 v2」でも green になるため）。
    CANON_SHA256="9f21616439b00259d99cdac1103b6b83fc1923672ad7752753bbf2f914e21c7d"
    CANON_LINES=18
    CANON_CHARS=1359
    # 埋込 carrier の形（§5 step4 の 3 スペース継続インデント + text フェンス）。
    EMBED_PREFIX="   "
    FENCE_BEGIN='   ```text'
    FENCE_END='   ```'
    # canonical block の見出し行（occurrence 一意性 pin の錨）。
    CANON_HEAD='【人間確認が要るのは「取り消せない」3 クラスのみ】'
    # 正本 (b) / (c) 行の逐語。負論理 pin が「許す唯一の出現」を完全一致で狭めるために使う。
    CANON_B_LINE='(b) 出す — public 化・外部公開・外部サービスへの送信（scriptorium 核② private 保証はこの型）。判定単位は repo でなく「情報」＝public 面の情報集合を増やすかで判定する。private 配備層から public engine への同期のような境界事案は機械 2 条件〔① 配備層 file を touch しない ② private 実名 DATA literal が 0 hit〕が両方 green なら非該当（AI 判断で merge）・どちらかが赤 or 機械照合できないなら (b) として人間確認へ倒す fail-safe。「既に public な repo だから非該当」という repo 単位の断定は禁止（public repo の中に private 由来の同期先が在りうる＝実例 scribe 内 scriptorium-engine）。〔裁定 R-A・2026-07-26〕'
    CANON_C_LINE='(c) 使う — 追加課金が発生する操作（従量課金 API 呼出 / 有料サービスの新規契約 / クラウド資源の課金発生）。定額プラン内は対象外＝token 消費それ自体は非該当（Workflow を何 M token 回しても (c) に当たらない）。旧文言「大きな金銭コスト（承認でなく予算上限で制御）」は観測できず死文化するため廃止した。〔裁定 R-B・2026-07-26〕'
    # html のベースライン（本 codify 時点の実測・意図的変更時のみ更新する）
    GUIDE_ELEMENTS=706
}

# §5 step4 に埋め込んだ canonical block を sentinel 区間（text フェンス）で抽出し、3 スペースの
# 埋込接頭辞を厳密に剥がして stdout へ出す（tests/cell-quality-verdict.bats:58-79 の移植）。
#   $1=file / $2=begin sentinel（固定文字列）/ $3=end sentinel（固定文字列）/ $4=埋込接頭辞
# markdown フェンス内の空行は trailing space を作らない形で書くため、空行は長さ 0 で受ける。
# 接頭辞に一致しない非空行・sentinel 欠落は stderr へ吐いて rc=9（silent な部分抽出で pin を空虚化させない）。
# 旧実装（`sub(/^   /,"")` の素通し）は接頭辞 drift を無言で吸収したため、fail-loud 形へ置き換えた。
extract_canonical_block() {
    awk -v b="$2" -v e="$3" -v p="$4" '
      !s && index($0, b) { s = 1; next }
      s && index($0, e)  { found = 1; exit }
      s {
        pl = length(p)
        if (substr($0, 1, pl) == p) { print substr($0, pl + 1) }
        else if ($0 == "")          { print "" }
        else { printf("PREFIX-MISMATCH: %s\n", $0) > "/dev/stderr"; bad = 1; exit }
      }
      END {
        if (bad)    exit 9
        if (!s)     { print "BEGIN-SENTINEL-NOT-FOUND" > "/dev/stderr"; exit 9 }
        if (!found) { print "END-SENTINEL-NOT-FOUND"   > "/dev/stderr"; exit 9 }
      }
    ' "$1"
}

# 被検査ファイル（protocol.md 本体 / $BATS_TEST_TMPDIR 上の mutant コピー）に対する薄い wrapper。
extract_canonical() { extract_canonical_block "$1" "$FENCE_BEGIN" "$FENCE_END" "$EMBED_PREFIX"; }

# 抽出結果の sha256 / 文字数（正本は末尾改行を含まない 18 行ゆえ最終 1 byte を落として測る）。
canon_sha256() { extract_canonical "$1" | head -c -1 | sha256sum | cut -d' ' -f1; }
canon_chars() {
    extract_canonical "$1" | head -c -1 \
        | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8")))'
}

# 指定 literal を含む行のうち「許された正本行（埋込接頭辞込みの完全一致）」以外だけを stdout へ出す
# （tests/cell-quality-verdict.bats:84-90 と同型）。$1=literal / $2=file / $3.. =許す行（完全一致）。
# 行単位の `grep -v <語>` 除外は fail-open（v1 復活行が同一行に 1 語添えるだけで素通りする）ゆえ、
# 除外は正本行との完全一致だけに狭める。
leftover_lines() {
    local literal="$1" f="$2"; shift 2
    local line allowed ok
    while IFS= read -r line; do
        ok=0
        for allowed in "$@"; do
            [ "$line" = "$allowed" ] && { ok=1; break; }
        done
        [ "$ok" -eq 1 ] || printf '%s\n' "$line"
    done < <(grep -F -- "$literal" "$f" || true)
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

@test "canonical block v2 が 18 行 / 1359 字 / sha256 完全一致で verbatim 埋込されている（版 pin）" {
    local n
    # 抽出そのものが成功する（sentinel 欠落・埋込接頭辞 drift は rc=9 で fail-loud）。
    run extract_canonical "$PROTOCOL"
    [ "$status" -eq 0 ]
    # 行数 drift（折り返し・行結合・欠落）を byte pin から独立に捕える。
    n="$(extract_canonical "$PROTOCOL" | wc -l)"
    [ "$n" -eq "$CANON_LINES" ]
    [ "$(canon_chars "$PROTOCOL")" -eq "$CANON_CHARS" ]
    # byte 同一性の本体。
    [ "$(canon_sha256 "$PROTOCOL")" = "$CANON_SHA256" ]
    # occurrence 一意性: 規範を反転させた第 2 block が同居すると抽出器（最初の区間で exit）を
    # 素通りするため、見出し行が 1 個であることを版 pin の一部として要求する。
    [ "$(grep -Fc -- "$CANON_HEAD" "$PROTOCOL")" -eq 1 ]
}

@test "版 pin: CANON_SHA256 が tests/cell-quality-verdict.bats の同定数と一致する（片側 drift を RED 化）" {
    # 同一の正本を docs 側と runtime carrier 側で別々に pin しているため、片側だけ版が上がると
    # 「両方 green なのに実体が食い違う」状態を作れてしまう。定数の同値性そのものを歯にする。
    local other
    other="$(sed -n "s/^  CANON_SHA256='\([0-9a-f]\{64\}\)'\$/\1/p" "$VERDICT")"
    [ -n "$other" ]
    [ "$other" = "$CANON_SHA256" ]
}

@test "canonical block の 4 見出しが protocol.md に実在する" {
    grep -qF -- '【人間確認が要るのは「取り消せない」3 クラスのみ】' "$PROTOCOL"
    grep -qF -- '【聞かないこと】' "$PROTOCOL"
    grep -qF -- '【上げること】' "$PROTOCOL"
    grep -qF -- '【本裁定で緩めないもの（fence）】' "$PROTOCOL"
}

@test "3 クラス（消す / 出す / 使う）の行が v2 の逐語で実在する" {
    # sha256 版 pin と重複するが、RED になったとき「どの行が落ちたか」を人間が読める形にする補助 pin。
    # (b)(c) は v2 で全面改訂された行ゆえ、先頭の一致ではなく行全体の逐語で焼く。
    grep -qF -- '(a) 消す — データ / repo / 履歴 / live 成果物の破壊（第一防衛線は機械 guard 層）' "$PROTOCOL"
    grep -qF -- "$CANON_B_LINE" "$PROTOCOL"
    grep -qF -- "$CANON_C_LINE" "$PROTOCOL"
}

@test "v2 の必須語（追加課金 / 機械 2 条件 / 判定単位は repo でなく「情報」/ 裁定 R-A・R-B）が実在する" {
    for tok in \
        '(c) 使う — 追加課金が発生する操作' \
        '定額プラン内は対象外＝token 消費それ自体は非該当' \
        '判定単位は repo でなく「情報」' \
        '機械 2 条件〔① 配備層 file を touch しない ② private 実名 DATA literal が 0 hit〕' \
        '〔裁定 R-A・2026-07-26〕' \
        '〔裁定 R-B・2026-07-26〕'; do
        grep -qF -- "$tok" "$PROTOCOL"
    done
    # v2 で新設された語が実在する（現行 protocol.md では 0 hit だったため非自明な pin）。
    grep -qF -- '追加課金' "$PROTOCOL"
}

# v1 の廃止済み文言は「v2 の (c) 行が旧語を引用して廃止を宣言する」構造ゆえ literal 0 hit を要求できない。
# ただし除外を「同一行に『廃止した』を含む」に置くと、v1 を復活させる行が 1 語添えるだけで素通りする
# （負論理 pin の fail-open）。ゆえに許すのは**正本 (c) 行との完全一致 1 行だけ**に狭める。
@test "negative(版 pin): v1 の廃止文言が正本 (c) 行以外の形で protocol.md に残っていない" {
    [ -z "$(leftover_lines '大きな金銭コスト' "$PROTOCOL" "${EMBED_PREFIX}${CANON_C_LINE}")" ]
    [ -z "$(leftover_lines '予算上限で制御'   "$PROTOCOL" "${EMBED_PREFIX}${CANON_C_LINE}")" ]
}

# クラス (b) の repo 単位断定（v1 系の緩い判定）は v2 で明示的に禁止された。禁止文それ自体は
# 正本 (b) 行に**正当に**含まれるため、素の literal 0 hit は false-RED になる（除外が要る）。
@test "negative(版 pin): repo 単位断定の反転形が正本 (b) 行以外に無く、旧 carve-out が撤去されている" {
    [ -z "$(leftover_lines '既に public な repo だから非該当' "$PROTOCOL" "${EMBED_PREFIX}${CANON_B_LINE}")" ]
    # 旧・行為ベースの一括免除（repo 単位の断定）は撤去済み＝再流入を negative で塞ぐ。
    assert_absent '本リポは既に public な GitHub repo であり' "$PROTOCOL"
    assert_absent '**public な doc への追記は 3 クラスの「出す」（＝新規の公開面拡大: private→public 化・新規 repo 公開・未公開データの外部送信）に該当しない**' "$PROTOCOL"
    # 旧免除の**射程限定句**（行為ベース: 編集する行為そのものは非該当 / 内容の公開性では判定しない）も
    # 断片単位で塞ぐ。full 文の pin だけでは、この 2 句だけを書き戻す断片経路が開いたままになる
    # （R-A は行為ベースの一括免除そのものを撤回し、判定を機械 2 条件へ置き換えた）。
    # literal は素の語形（強調記号なし）で焼く＝bold の有無に依らず捕捉する上位互換。
    assert_absent '既に public な doc を編集する行為そのもの' "$PROTOCOL"
    assert_absent '載せる内容の公開性ではない' "$PROTOCOL"
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
    # v2 では誤読防止句の ** 強調が正本本文から外れている（v1 の埋込側で付いていた記号は正本に無い）。
    # 記号の付加は v2 の搬送規律が禁じ sha256 も外れるため、pin 側から記号を外して retarget する
    # （block へ記号を足して green にするのは搬送規律違反。同型の解決先例 = cell-quality-verdict.bats:156-172）。
    grep -qF -- '1. 人間承認を外しても gate は外さない（gate が実効安全弁になったので強化側）。' "$PROTOCOL"
    grep -qF -- '2. 「worker が自己 merge してよい」ではない（gate 分離＝独立レビューは不変）。' "$PROTOCOL"
    grep -qF -- '3. front-load / バナーは廃止でなく scope 縮小（user 裁定 2026-07-17 の可視性要件を壊さない）。' "$PROTOCOL"
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

# ---------- 埋込注記の機械 2 条件を「対で」pin（クラス (b) の唯一の安全弁） ----------
#
# 旧・埋込注記は「public な doc への追記は『出す』に該当しない」という repo 単位の permissive な
# carve-out を持ち、その fail-open を carve-back **1 文だけ**で塞いでいた（実測: carve-back を
# 削っても他の全 assert が green）。v2（裁定 R-A）はこれを **機械 2 条件**へ置き換え、carve-back の
# 趣旨を条件②へ吸収した。①（配備層 touch）だけが残り②③が欠ける改訂は fail-open ゆえ、
# 「非該当側（両方 green）」と「該当側（どちらかが赤 → 人間確認へ倒す）」を **対で** pin して
# 片方だけが残る編集を RED にする。
#
# ★pin literal は **note 固有形**（強調記号・括弧付き）で焼く: 素の語（`① 配備層 file を touch しない`
# 等）は canonical block の (b) 行にも同じ字面で現れる（実測 2 hit）ため、note からその句を削っても
# block 側の 1 hit で grep が充足され pin が空虚になる（実測: ① を削って全 suite green）。
# 下記 4 literal はいずれも protocol.md 内 1 hit で、block 非該当（＝note だけが充足源）。
# 非空虚性は推論でなく mutation probe（:「note の ① 句だけを削ると RED」）で実測して示す。
@test "埋込注記の非該当条件（機械 2 条件が両方 green）が実在する" {
    grep -qF -- '**判定単位は repo でなく情報**' "$PROTOCOL"
    grep -qF -- '**① 配備層 file を touch しない**（`scriptorium-engine/` 配下）' "$PROTOCOL"
    grep -qF -- '**② private 実名 DATA literal が 0 hit**（user 発言の生引用' "$PROTOCOL"
    grep -qF -- '**両方 green なら非該当**（AI 判断で merge）' "$PROTOCOL"
}

@test "埋込注記の該当条件（赤 or 機械照合不能なら (b) へ倒す）と carve-back の趣旨が実在する" {
    # block 側 (b) 行にも同字面で現れる句ゆえ、note 固有形（強調記号 +（fail-safe））で焼く。
    grep -qF -- '**どちらかが赤 or 機械照合できないなら (b) として人間確認へ倒す**（fail-safe）' "$PROTOCOL"
    # carve-back の趣旨（未公開データ・foreign 台帳の内容を新たに公開面へ載せるなら「出す」）は
    # 条件②へ吸収した形で必ず維持する（①だけを残す改訂は fail-open）。
    grep -qF -- '**未公開データや foreign 台帳の内容を新たに公開面へ載せる場合は「出す」に該当し人間確認を取る**' "$PROTOCOL"
    # ② が指す private 実名 DATA の外延（列挙）も対で保持する。
    grep -qF -- 'user 発言の生引用・private / foreign 台帳の内容・ホスト名 / メール / 資格情報・未公開の内部情報' "$PROTOCOL"
    # 行為ベースの一括免除へ戻さない旨（v1 への巻き戻し禁止）が明文で残る。
    grep -qF -- '行為ベースの一括免除' "$PROTOCOL"
}

# ---------- mutation probe: 版 pin / 負論理 pin が非空虚であること ----------
#
# 「RED になるはず」という推論では teeth の非空虚性を示せない（実際に v1 を lock していた前歴がある）。
# 変異は $BATS_TEST_TMPDIR 上の mutant コピーに対して行い、protocol.md 本体と git 履歴を汚さない。
# 各 probe はまず「変異が実際に入った（no-op でない）」ことを 2 経路で確認してから RED を読む。

@test "mutation: block 内の 1 語（追加課金）を書き換えると sha256 版 pin が RED へ flip する" {
    local mut n
    mut="$BATS_TEST_TMPDIR/word-protocol.md"
    cp "$PROTOCOL" "$mut"
    sed -i 's|追加課金が発生する操作|多額の課金が発生する操作|' "$mut"

    run cmp -s "$PROTOCOL" "$mut"
    [ "$status" -ne 0 ]
    grep -qF -- '多額の課金が発生する操作' "$mut"

    # 行数は 18 のまま＝行数 pin では捕まらず、byte pin だけが捕える。
    n="$(extract_canonical "$mut" | wc -l)"
    [ "$n" -eq "$CANON_LINES" ]
    [ "$(canon_sha256 "$mut")" != "$CANON_SHA256" ]
}

@test "mutation: block 内の 2 行を結合（reflow 再現）すると行数 pin と sha256 版 pin が RED へ flip する" {
    local mut n
    mut="$BATS_TEST_TMPDIR/reflow-protocol.md"
    python3 - "$PROTOCOL" "$mut" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read().split("\n")
i = next(k for k, l in enumerate(src) if l.startswith("   【聞かないこと】"))
src[i:i + 2] = [src[i] + src[i + 1].lstrip()]
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(src))
PY
    run cmp -s "$PROTOCOL" "$mut"
    [ "$status" -ne 0 ]

    # 語の grep は全て素通りする（結合後も部分文字列としてヒットする）＝reflow は byte/行数 pin でしか捕まらない。
    grep -qF -- '【聞かないこと】' "$mut"
    grep -qF -- '【上げること】' "$mut"

    n="$(extract_canonical "$mut" | wc -l)"
    [ "$n" -ne "$CANON_LINES" ]
    [ "$(canon_sha256 "$mut")" != "$CANON_SHA256" ]
}

@test "mutation: block 外へ v1 語 / repo 単位断定を 1 行復活させると負論理 pin が RED へ flip する" {
    local mut
    mut="$BATS_TEST_TMPDIR/v1-protocol.md"
    cp "$PROTOCOL" "$mut"
    # 「同一行に『廃止した』を添えれば素通り」型の fail-open も同時に排除できていることを示す。
    printf '%s\n' '- (c) 使う — 大きな金銭コスト（承認でなく予算上限で制御）。旧規定は廃止した。' >> "$mut"
    printf '%s\n' '- 「既に public な repo だから非該当」と判定してよい。' >> "$mut"

    run cmp -s "$PROTOCOL" "$mut"
    [ "$status" -ne 0 ]

    # 負論理 pin: clean 側は空 / 変異側は非空（＝pin は非空虚）。
    [ -z "$(leftover_lines '大きな金銭コスト' "$PROTOCOL" "${EMBED_PREFIX}${CANON_C_LINE}")" ]
    [ -n "$(leftover_lines '大きな金銭コスト' "$mut" "${EMBED_PREFIX}${CANON_C_LINE}")" ]
    [ -z "$(leftover_lines '既に public な repo だから非該当' "$PROTOCOL" "${EMBED_PREFIX}${CANON_B_LINE}")" ]
    [ -n "$(leftover_lines '既に public な repo だから非該当' "$mut" "${EMBED_PREFIX}${CANON_B_LINE}")" ]

    # sha256 版 pin は block 内しか見ない＝block 外の領域を守るのは負論理 pin だけであることを示す。
    [ "$(canon_sha256 "$mut")" = "$CANON_SHA256" ]
}

@test "mutation: 埋込注記の ① 句だけを削ると note 固有 pin が RED へ flip する（素の語 pin は空虚）" {
    local mut
    mut="$BATS_TEST_TMPDIR/note-cond1-protocol.md"
    # note の「機械 2 条件〔① … / ② …〕」から ① 句だけを外し「機械条件〔② …〕」へ退化させる
    # （＝配備層 touch 条件＝`scriptorium-engine/` を守る側だけが落ちる fail-open 型の改訂）。
    python3 - "$PROTOCOL" "$mut" <<'PY'
import sys
src = open(sys.argv[1], encoding="utf-8").read()
old = "**機械 2 条件**〔**① 配備層 file を touch しない**（`scriptorium-engine/` 配下）/ **② private 実名 DATA literal が 0 hit**"
new = "**機械条件**〔**② private 実名 DATA literal が 0 hit**"
if src.count(old) != 1:
    sys.exit("MUT-ANCHOR-NOT-UNIQUE: %d" % src.count(old))
open(sys.argv[2], "w", encoding="utf-8").write(src.replace(old, new))
PY

    # 変異が実際に入った（no-op でない）ことを 2 経路で確認してから RED を読む。
    run cmp -s "$PROTOCOL" "$mut"
    [ "$status" -ne 0 ]
    grep -qF -- '**機械条件**〔**② private 実名 DATA literal が 0 hit**' "$mut"

    # 素の語（block の (b) 行と同字面）は block 側 1 hit で充足され素通りする＝旧 pin が空虚だった実測。
    [ "$(grep -Fc -- '① 配備層 file を touch しない' "$PROTOCOL")" -eq 2 ]
    [ "$(grep -Fc -- '① 配備層 file を touch しない' "$mut")" -eq 1 ]
    grep -qF -- '① 配備層 file を touch しない' "$mut"

    # note 固有 pin は clean 側 green / 変異側 RED（＝pin は非空虚）。
    grep -qF -- '**① 配備層 file を touch しない**（`scriptorium-engine/` 配下）' "$PROTOCOL"
    run grep -qF -- '**① 配備層 file を touch しない**（`scriptorium-engine/` 配下）' "$mut"
    [ "$status" -ne 0 ]

    # sha256 版 pin は block 内しか見ない＝note を守るのは本 pin だけであることを示す。
    [ "$(canon_sha256 "$mut")" = "$CANON_SHA256" ]
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

# sc-x93w 等価移設: 旧 pin は「§2-4 全文抽出の**先頭側と末尾側**が両方届く＝途中で打ち切られていない」を
# 節末の一次出典行で測っていた。注入が doc 側 sentinel 区間の boot core へ変わったため、同じ意図
# （区間の先頭と末尾が両方届く＝打切りが無い）を **core 区間の begin 直後行と end 直前行の逐語 pin** へ
# 移す（■10-1 の「打切り検知の意図を core 区間の begin 行と end 行の逐語 pin へ移して等価維持」）。
# 期待値は doc から**計算せず** literal で焼く（被検査ファイルから再計算する自己参照 pin は空虚・header :49 と同じ理由）。
@test "worker 注入抽出が core 区間の先頭行と末尾行を両方含む（打切り検知・sc-x93w 移設）" {
    local wt out
    wt="$BATS_TEST_TMPDIR/proj/.worktrees/spawn/x-1"
    mkdir -p "$wt/.beads"
    out="$BATS_TEST_TMPDIR/worker-inject.txt"
    printf '%s' "{\"cwd\":\"$wt\"}" \
        | env -u SCRIBE_ROLE -u TMUX -u TMUX_PANE -u SCRIBE_TMUX -u SCRIBE_WORKER -u SCRIBE_WORKTREE \
              CLAUDE_PLUGIN_ROOT="$REPO" bash "$INJECT" > "$out" 2>/dev/null || true
    [ -s "$out" ]
    # core 区間の**先頭行**（begin sentinel の直後）
    grep -qF -- '**trigger 表（worker・「いつどの節を Read するか」の索引。全文は本 file を上記の絶対 path で Read する）**' "$out"
    # core 区間の**末尾行**（end sentinel の直前・空行を除く最後の実体行）
    grep -qF -- '**機械防御の carrier は scribe-spawn**（`SCRIBE_WORKER` / `SCRIBE_WORKTREE` env signal + spawn prompt）' "$out"
    # 中間（§3 相当 / §4 相当）が落ちていない
    grep -qF -- '**follow-up は自分で起票しない**' "$out"
    grep -qF -- '**順序を逆にしない**' "$out"
    # sentinel 行そのものは本文として出さない（HTML コメントの漏出禁止）
    assert_absent 'scribe-core-worker:begin' "$out"
    assert_absent 'scribe-core-worker:end' "$out"
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

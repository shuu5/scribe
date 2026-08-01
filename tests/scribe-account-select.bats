#!/usr/bin/env bats
# tests/scribe-account-select.bats — sc-1rq「--account auto（claude-usage 残量 maximin 自動選択）」の
# 出荷物 self-test（IMPLEMENTATION CONTRACT 2026-07-08 のテスト要件を committed bats として固定する）。
#
# なぜ committed か: 契約は self-test を **plugin 出荷物**（= scribe-spawn.sh + 新 scribe-account-select と
# 並ぶ deliverable）として必須化する。worker の untracked `selftest-<id>.local.sh` は gate 用の使い捨てで
# あり、100−pct の逆選択回帰ピン（取り違え=バグと契約が警告）や GOLDEN acceptance を将来にわたって
# 固定する resident な回帰網は committed でなければ果たせない。本 file が その資産（tests/scribe-tools.bats と
# 同姿勢：dry-run + スタブのみ・実 spawn/実 tmux/実 claude/実 bd は起こさない）。
#
# 決定性の seam（live 非依存）:
#   ・selector 入力 = env SCRIBE_USAGE_JSON / `--stdin`（claude-usage を exec しない）。
#   ・比較基準時刻 = env SCRIBE_USAGE_NOW（resets_at 比較を固定・過去/未来を決定化）。
#   ・spawn の bd 実在検証 = SCRIBE_BD スタブ（実 graph 非依存）。cld-spawn/sandbox/bdw も全てスタブ。
#
# ★VERIFIED セマンティクス（回帰ピンの核心）: five_hour_pct/seven_day_pct = utilization(使用率)。
#   残量% = 100 − pct。pct を残量と読むと maximin が枯渇寸前アカを選ぶ逆選択バグ（S12/S1b が pin）。

bats_require_minimum_version 1.5.0

NOW="2026-07-08T12:00:00+00:00"

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  SEL="$SCRIPTS/scribe-account-select"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  # host 側の usage/config-dir env が漏れてテストを汚さないよう毎回落とす（hermetic）。
  unset SCRIBE_USAGE_JSON SCRIBE_USAGE_NOW \
        CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE 2>/dev/null || true
  # sc-9954: worker 既定 auto 反転で、素の worker spawn（--account 省略）も selector を通る。実 claude-usage を叩かせず
  # 決定論化する: SCRIBE_USAGE_CMD を不在パスに固定 → selector exit 3（API 故障）→ 主アカ fallback。usage を検証する
  # テストは SCRIBE_USAGE_JSON（seam 優先）を per-test で与えるため本既定に勝つ。API 故障を明示注入するテストは同 var を
  # 別の不在パスへ上書きするが効果は同一。
  export SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/scribe-no-usage-cmd"

  # bd 実在検証スタブ（実 graph 不要）。dry-run 統合テストは実在 id が要るので sc-auto-test を ok に。
  export SCRIBE_BD="$FIXTURES/bd-stub.sh"
  export BD_STUB_OK_IDS="sc-auto-test"
  chmod +x "$FIXTURES/bd-stub.sh" 2>/dev/null || true

  # anchor/repo = 使い捨て git repo（host パス・実 scribe repo に非依存）。
  ANCHOR="$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/anchor.XXXXXX")" && pwd -P)"
  git -C "$ANCHOR" -c init.defaultBranch=main init -q
  git -C "$ANCHOR" config user.email t@e; git -C "$ANCHOR" config user.name t
  git -C "$ANCHOR" commit -q --allow-empty -m init

  ABASE="$BATS_TEST_TMPDIR/acctbase"
  NOTE_LOG="$BATS_TEST_TMPDIR/note.log"
  # bdw スタブ（監査 note を記録＝実 bd を触らない）。scribe-spawn は scripts/bdw 経由で BEADS_BDW を exec する。
  BDW_STUB="$BATS_TEST_TMPDIR/bdw_stub.sh"
  cat > "$BDW_STUB" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTE_LOG"
prev=""
for a in "\$@"; do
  [[ "\$prev" == "--append-notes" ]] && printf 'NOTE:%s\n' "\$a" >> "$NOTE_LOG"
  prev="\$a"
done
exit 0
STUB
  chmod +x "$BDW_STUB"
  NOOP="$BATS_TEST_TMPDIR/noop.sh"; printf '#!/usr/bin/env bash\nexit 0\n' > "$NOOP"; chmod +x "$NOOP"

  _write_fixtures
}

# ---- 現ロスター golden + 契約列挙ケースの fixture 群（$BATS_TEST_TMPDIR へ） ----
_write_fixtures() {
  GOLDEN="$BATS_TEST_TMPDIR/golden.json"
  cat > "$GOLDEN" <<JSON
{ "as_of": "$NOW", "accounts": [
  {"label":"default","email":null,"ok":true,"stale":false,"error":null,
   "five_hour_pct":0,"five_hour_resets_at":null,"five_hour_remaining":"",
   "seven_day_pct":100,"seven_day_resets_at":"2026-07-14T00:00:00+00:00","seven_day_remaining":"5d"},
  {"label":"black2","email":null,"ok":true,"stale":false,"error":null,
   "five_hour_pct":43,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":97,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black3","email":null,"ok":false,"stale":true,"error":"HTTP 429","error_code":"429",
   "attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":20,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"black4","email":null,"ok":true,"stale":false,"error":null,
   "five_hour_pct":18,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":96,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"phito","email":null,"ok":false,"stale":true,"error":"認証切れ(/login 要)"}
] }
JSON
  # sc-7czu: black3 を「一過性 429 で degrade（snapshot cache の実データ有り）」＝**復帰クラス**へ更新した。
  #   ラベルは現状維持（PUBLIC repo へ露出を増やさない）。これで GOLDEN が「healthy 3 件 + 復帰クラス
  #   1 件 + データ無し stale 1 件（phito）」の三分類を全部含む否定対照になり、tier 順序を pin できる。
  #   black3 の score は 80（h5=90 / h7=80）で healthy 最上位 black4 の 4 を大きく上回る＝score 減点では
  #   追い越しを止められないことの実データ。phito は error_code を持たないので従来どおり除外される。

  ZERO="$BATS_TEST_TMPDIR/zero.json"
  cat > "$ZERO" <<JSON
{ "accounts": [
  {"label":"a","ok":false,"stale":true},
  {"label":"b","ok":false,"stale":false,"error":"接続不可"}
] }
JSON

  KEYMISS="$BATS_TEST_TMPDIR/keymiss.json"
  cat > "$KEYMISS" <<JSON
{ "accounts": [
  {"label":"good","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"bad","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null}
] }
JSON

  TIE="$BATS_TEST_TMPDIR/tie.json"
  cat > "$TIE" <<JSON
{ "accounts": [
  {"label":"zeta","ok":true,"stale":false,"five_hour_pct":50,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":50,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"},
  {"label":"alpha","ok":true,"stale":false,"five_hour_pct":50,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":50,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"}
] }
JSON

  NULLR="$BATS_TEST_TMPDIR/nullreset.json"
  cat > "$NULLR" <<JSON
{ "accounts": [
  {"label":"x","ok":true,"stale":false,"five_hour_pct":90,"five_hour_resets_at":null,"seven_day_pct":90,"seven_day_resets_at":null}
] }
JSON

  PASTR="$BATS_TEST_TMPDIR/pastreset.json"
  cat > "$PASTR" <<JSON
{ "accounts": [
  {"label":"x","ok":true,"stale":false,"five_hour_pct":95,"five_hour_resets_at":"2026-07-08T09:00:00+00:00","seven_day_pct":95,"seven_day_resets_at":"2026-07-08T09:00:00+00:00"}
] }
JSON

  PCTPIN="$BATS_TEST_TMPDIR/pctpin.json"
  cat > "$PCTPIN" <<JSON
{ "accounts": [
  {"label":"busy","ok":true,"stale":false,"five_hour_pct":90,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":90,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"},
  {"label":"idle","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":"2026-07-09T00:00:00+00:00","seven_day_pct":10,"seven_day_resets_at":"2026-07-09T00:00:00+00:00"}
] }
JSON

  AMBIG="$BATS_TEST_TMPDIR/ambig.json"
  cat > "$AMBIG" <<JSON
{ "accounts": [
  {"label":"amb","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,"five_hour_remaining":"","seven_day_pct":5,"seven_day_resets_at":"2026-07-14T00:00:00+00:00","seven_day_remaining":""}
] }
JSON

  ONLYDEF="$BATS_TEST_TMPDIR/onlydefault.json"
  cat > "$ONLYDEF" <<JSON
{ "accounts": [
  {"label":"default","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,"seven_day_pct":0,"seven_day_resets_at":null},
  {"label":"other","ok":false,"stale":true}
] }
JSON

  # --- sc-j8zv fixtures（実アカウント名・実残量は書かない＝本 repo は PUBLIC）-------------------
  # (A) 上流劣化の実例＝「usage 側に健全 account が 1 件も無い」形。
  # ★sc-7czu で入力を差し替えた: 旧版は全件 429 だったが、429 は本 fix で**復帰クラス**（候補に残す）に
  #   なったため「全 stale」はもう (A) の実例ではない（適格が残ってしまい (A) の pin が空虚化する）。
  #   ∴ 全件 dead（nologin＝再 login が要る回復しないクラス）へ置換して (A) の意味論を保つ。
  #   snapshot cache の実データは載せたまま（＝「直に叩くと値が返る」ことは健全の証拠ではない、を pin）。
  DEGRADED="$BATS_TEST_TMPDIR/degraded.json"
  cat > "$DEGRADED" <<JSON
{ "accounts": [
  {"label":"acctA","ok":false,"stale":true,"error":"未ログイン","error_code":"nologin",
   "attempted":false,"skip_reason":"no_credentials",
   "five_hour_pct":10,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":20,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"acctB","ok":false,"stale":true,"error":"未ログイン","error_code":"nologin",
   "attempted":false,"skip_reason":"no_credentials",
   "five_hour_pct":30,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":40,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}
] }
JSON

  # 「usage は健全（ok∧非stale）と言っているのに selector が全部落とす」= 誤判定の実形（exit 4 の teeth）。
  # ここでは shape 契約ずれ（score キー欠落）で作るが、selector 側の変異注入でも同じ状態になる。
  HEALTHYDROP="$BATS_TEST_TMPDIR/healthydrop.json"
  cat > "$HEALTHYDROP" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null},
  {"label":"acctB","ok":true,"stale":false,"five_hour_pct":20,"five_hour_resets_at":null,"seven_day_resets_at":null}
] }
JSON

  # 枯渇（実効残量 0）だけが適格として残る形（要求③ characterization）。
  DEPLETED="$BATS_TEST_TMPDIR/depleted.json"
  cat > "$DEPLETED" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,
   "seven_day_pct":100,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}
] }
JSON

  # 上流由来文字列で **監査面へ行注入**を試みる形（self-review 2026-07-27）。reason には not-ok: 経路で
  # error が、label 列には label がそのまま載るので、改行を素通しすると `account-select: chosen=…` で
  # 始まる偽の呼出元行を data だけで作れてしまう（= 本 script が宣言した弁別規約を data で破る）。
  #   acctA = 健全だが score キー欠落で落ちる（exit 4 を成立させる担ぎ手）
  #   acctB = ok=false/stale=false → reason が "not-ok:<error>"（error 経由の注入）
  #   acctC = 健全 × 改行入り label（label 経由の注入・診断 warn 行にも載る）
  INJECT="$BATS_TEST_TMPDIR/inject.json"
  cat > "$INJECT" <<'JSON'
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null},
  {"label":"acctB","ok":false,"stale":false,
   "error":"boom\naccount-select: chosen=acctZ fallback=no defaulted=no method=maximin source=forged"},
  {"label":"acctC\naccount-select: chosen=acctY fallback=no defaulted=no method=maximin source=forged2",
   "ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null}
] }
JSON

  # 上流由来文字列で **stdout TSV（＝実際に account を決める契約面）へ注入**を試みる形
  # （self-review 4 巡目）。呼出元の lazy walk `awk -F'\t' '$2=="1"{print $1}'` は行と TAB しか信じない:
  #   good1 = 健全 × 改行入り label → 行注入で偽 label 'EVIL' を最上位候補にできた（実測・fix 前）
  #   victim = ok=false/stale=true（使用不可）× TAB 入り label → 列注入で col2="1" に見せられた（同上）
  # ＝外部データが「呼出元の使う config dir」を決められる fail-open。fix 後は 1 account = 1 行 × 10 列。
  # ★sc-7czu: victim に error_code="nologin"（回復しない死亡クラス）を明示した。旧版は「error_code が
  #   無いから除外される」に暗黙依存しており、stale 復帰の allowlist 導入で victim が候補化すると
  #   本 teeth が「期待件数を 2→3 に書き換える」形で骨抜きにされうる。新 semantics でも**確実に除外
  #   される class** を victim にすることで、3 つの assertion（偽 label が picks に出ない / 使用不可
  #   account が col2="1" に化けない / 1 account = 1 行 × 10 列）を無傷のまま維持する。
  TSVINJECT="$BATS_TEST_TMPDIR/tsvinject.json"
  cat > "$TSVINJECT" <<'JSON'
{ "accounts": [
  {"label":"good1\nEVIL\t1","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,
   "seven_day_pct":0,"seven_day_resets_at":null},
  {"label":"good2","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,
   "seven_day_pct":50,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"victim\t1\t100","ok":false,"stale":true,"error":"未ログイン","error_code":"nologin",
   "skip_reason":"no_credentials","five_hour_pct":0,"five_hour_resets_at":null,
   "seven_day_pct":0,"seven_day_resets_at":null}
] }
JSON

  # 枯渇警告（**exit 0 の happy path**）へ改行を仕込む形（self-review 4 巡目）。exit 4 の監査面だけを
  # 塞いでも、floor 無し semantics では枯渇 account が最上位になるのが平常運転なので、この経路が
  # 素通しだと `account-select: chosen=…` の偽行を平常時に data だけで作れる。
  DEPINJECT="$BATS_TEST_TMPDIR/depinject.json"
  cat > "$DEPINJECT" <<'JSON'
{ "accounts": [
  {"label":"acctX\naccount-select: chosen=FORGED fallback=no defaulted=no method=maximin source=evil",
   "ok":true,"stale":false,"five_hour_pct":100,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":100,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}
] }
JSON

  # 健全（ok∧非stale）なのに **窓あり × utilization(pct)=null** で残量判定不能になる形（(B')）。
  # 上流 claude-usage の norm_pct は utilization 欠落/非数値で null を返す＝健全申告のまま起こりうる。
  # selector は fail-closed 除外するが、これは selector の欠陥ではない（誤帰属させない teeth）。
  INDET="$BATS_TEST_TMPDIR/indeterminate.json"
  cat > "$INDET" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":null,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":20,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}
] }
JSON

  # 上と同型の (B') が **適格 account と併存**する形（適格が残る場合の warn 文言を pin する）。
  INDETMIX="$BATS_TEST_TMPDIR/indetmix.json"
  cat > "$INDETMIX" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":null,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":20,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"acctB","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,
   "seven_day_pct":20,"seven_day_resets_at":null}
] }
JSON

  # ok/stale 自身の型ドリフト（健全判定器も無力になる盲点）→ 上流劣化と断じず shape 疑いを併記する。
  SHAPEDRIFT="$BATS_TEST_TMPDIR/shapedrift.json"
  cat > "$SHAPEDRIFT" <<JSON
{ "accounts": [
  {"label":"acctA","ok":"true","stale":"false","five_hour_pct":10,"five_hour_resets_at":null,
   "seven_day_pct":10,"seven_day_resets_at":null}
] }
JSON

  # usage 側は適格だが preflight 全滅を作る fixture（非 default のみ＝~/.claude へ写像されない）。
  # config dir を一切作らなければ全候補 preflight 不通過 → resolve 末尾 fail-loud を引く（facet⑤②(b)）。
  # --- sc-7czu fixtures（匿名ラベル・合成値のみ＝実 label / 実 pct / 実 token 期限は書かない）--------
  # 三分類の全クラスを 1 入力に含む形。上流 shape は claude-usage の出力契約から写した（live 実行はしない）。
  #   healthy = ok∧非stale（tier=0・**score は最下位の 1**）
  #   revExp  = 失効 token の pre-flight skip（skip_reason=token_expired / error_code=expired・score 99）
  #   rev429  = 一過性 HTTP 429（error_code=429 / attempted=true・score 98）
  #   dead    = credential 不在（skip_reason=no_token / error_code=notoken・回復しない）
  # score が healthy << 復帰クラス なのは意図（tier が無ければ復帰クラスが 1-2 位を占める＝pool 半減の
  # 是正が「順位の乗っ取り」に化ける形。tier 化の否定対照）。
  CLASSES="$BATS_TEST_TMPDIR/classes.json"
  cat > "$CLASSES" <<JSON
{ "accounts": [
  {"label":"healthy","ok":true,"stale":false,"error":null,"error_code":null,"attempted":true,
   "skip_reason":null,"token_expires_at":null,
   "five_hour_pct":99,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":99,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"revExp","ok":false,"stale":true,"error":"token 期限切れ(skip)","error_code":"expired",
   "attempted":false,"skip_reason":"token_expired","token_expires_at":"2026-07-08T09:00:00+00:00",
   "five_hour_pct":1,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":1,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"rev429","ok":false,"stale":true,"error":"HTTP 429","error_code":"429",
   "attempted":true,"skip_reason":null,"token_expires_at":null,
   "five_hour_pct":2,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":2,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"revCodeOnly","ok":false,"stale":true,"error":"token 期限切れ","error_code":"expired",
   "attempted":false,"token_expires_at":"2026-07-08T09:00:00+00:00",
   "five_hour_pct":3,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":3,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"revSkipOnly","ok":false,"stale":true,"error":"token 期限切れ(skip)",
   "attempted":false,"skip_reason":"token_expired","token_expires_at":"2026-07-08T09:00:00+00:00",
   "five_hour_pct":4,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
   "seven_day_pct":4,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"},
  {"label":"dead","ok":false,"stale":true,"error":"token 不在","error_code":"notoken",
   "attempted":false,"skip_reason":"no_token","token_expires_at":null,
   "five_hour_pct":0,"five_hour_resets_at":null,"seven_day_pct":0,"seven_day_resets_at":null}
] }
JSON

  # allowlist の境界（HTTP status 系）: 5xx=復帰 / 401・403・その他の非 5xx=除外。全て「stale=true」で
  # 来る＝stale フラグでは層別できないことを同時に pin する。
  # ★sc-7czu WF 指摘: s600 は**上限側**（`500 <= st <= 599` の `<= 599`）の否定対照。これが無いと
  #   `500 <= st` へ緩める（＝3 桁の 600-999 を全部復帰扱いにする）変異が全 tooth green で生存する
  #   ＝実測。s404 を下限/非 5xx 側の必須行と論じた同じ論法を上限側にも適用して網の非対称を消す。
  # ★sc-7czu self-review: s404 は「401/403 以外の非 5xx」の代表。これが無いと allowlist の否定側が
  #   401/403 の 2 値にしか掛からず、HTTP 判定を `st not in (401,403)`（＝全 status を復帰扱い）へ
  #   緩める fail-open 変異が全 tooth green のまま生存する（実測で生存を確認した）。allowlist 型
  #   （「429/5xx **のみ**」）を閉じ側から pin するために必須の行。
  HTTPCLASS="$BATS_TEST_TMPDIR/httpclass.json"
  cat > "$HTTPCLASS" <<JSON
{ "accounts": [
  {"label":"s503","ok":false,"stale":true,"error":"HTTP 503","error_code":"503","attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"s401","ok":false,"stale":true,"error":"HTTP 401","error_code":"401","attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"s403","ok":false,"stale":true,"error":"HTTP 403","error_code":"403","attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"s404","ok":false,"stale":true,"error":"HTTP 404","error_code":"404","attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"s600","ok":false,"stale":true,"error":"HTTP 600","error_code":"600","attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"sUnk","ok":false,"stale":true,"error":"???","error_code":"zzz","attempted":true,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null}
] }
JSON

  # 復帰クラスだが **採点不能**（snapshot が無く pct キー自体が無い＝claude-usage の to_json は data が
  # ある行にだけ pct を載せる、が上流の正常形）。除外はするが `malformed:` へ落としてはならない
  # （malformed: は shape 契約変更の疑いを数える予約語彙＝通常運転で踏む形を流すと偽警報が常時点灯する）。
  REVNODATA="$BATS_TEST_TMPDIR/revnodata.json"
  cat > "$REVNODATA" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,
   "seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"acctNoData","ok":false,"stale":false,"error":"token 期限切れ(skip)","error_code":"expired",
   "attempted":false,"skip_reason":"token_expired"}
] }
JSON

  # T1（sc-7czu §4）: healthy が全滅（score キー欠落）しつつ **採点可能な復帰クラスが eligible** に残る形。
  # 旧 exit 4 条件「eligible == 0」だと rc=4 が rc=0 へ落ちて teeth が死ぬ（この fixture がその disarm 検知）。
  T1DROP="$BATS_TEST_TMPDIR/t1drop.json"
  cat > "$T1DROP" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null},
  {"label":"acctB","ok":true,"stale":false,"five_hour_pct":20,"five_hour_resets_at":null,"seven_day_resets_at":null},
  {"label":"acctR","ok":false,"stale":true,"error":"HTTP 429","error_code":"429","attempted":true,
   "five_hour_pct":30,"five_hour_resets_at":null,"seven_day_pct":30,"seven_day_resets_at":null}
] }
JSON

  # T1B（sc-7czu self-review）: T1 と同型だが healthy 行と復帰行が **同一 label**。label は上流の一意性
  # 保証が無い（claude-usage の discover_accounts は auth 台帳の逆引きで label を決め dedup しないため、
  # 同一 account を 2 経路で発見すると同名行が 2 つ出る）ので、「healthy 由来の適格」を label 一致で
  # 数えると rc=4 が rc=0 へ落ちる（exit 4 の teeth を label 衝突だけで disarm できてしまう）。
  T1SAME="$BATS_TEST_TMPDIR/t1same.json"
  cat > "$T1SAME" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_resets_at":null},
  {"label":"acctA","ok":false,"stale":true,"error":"HTTP 429","error_code":"429","attempted":true,
   "five_hour_pct":30,"five_hour_resets_at":null,"seven_day_pct":30,"seven_day_resets_at":null}
] }
JSON

  # T2（sc-7czu §4）: healthy が **0 件** かつ復帰クラスが eligible。exit 0 のまま (A) の error_code
  # 内訳診断が出続けることを pin する（適格が出た途端に (A) が黙ると、健全 0 件という事実が消える）。
  T2ONLY="$BATS_TEST_TMPDIR/t2only.json"
  cat > "$T2ONLY" <<JSON
{ "accounts": [
  {"label":"acctR","ok":false,"stale":true,"error":"HTTP 429","error_code":"429","attempted":true,
   "five_hour_pct":30,"five_hour_resets_at":null,"seven_day_pct":30,"seven_day_resets_at":null},
  {"label":"acctD","ok":false,"stale":true,"error":"未ログイン","error_code":"nologin",
   "attempted":false,"skip_reason":"no_credentials",
   "five_hour_pct":40,"five_hour_resets_at":null,"seven_day_pct":40,"seven_day_resets_at":null}
] }
JSON

  # 新 field（error_code / attempted / skip_reason / token_expires_at）を **1 つも持たない** 旧版
  # claude-usage の出力形。optional 扱いが崩れて必須キー化すると全 account が malformed 除外され
  # pool 0 + 偽 shape-drift 警報 + spawn 全停止になるため、従来と同一出力であることを pin する。
  LEGACY="$BATS_TEST_TMPDIR/legacy.json"
  cat > "$LEGACY" <<JSON
{ "accounts": [
  {"label":"good","ok":true,"stale":false,"error":null,
   "five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":20,"seven_day_resets_at":null},
  {"label":"old","ok":false,"stale":true,"error":"取得不能",
   "five_hour_pct":5,"five_hour_resets_at":null,"seven_day_pct":5,"seven_day_resets_at":null}
] }
JSON

  PFAIL="$BATS_TEST_TMPDIR/pfail.json"
  cat > "$PFAIL" <<JSON
{ "accounts": [
  {"label":"acctA","ok":true,"stale":false,"five_hour_pct":10,"five_hour_resets_at":null,"seven_day_pct":10,"seven_day_resets_at":null},
  {"label":"acctB","ok":true,"stale":false,"five_hour_pct":20,"five_hour_resets_at":null,"seven_day_pct":20,"seven_day_resets_at":null}
] }
JSON
}

# selector を SCRIBE_USAGE_JSON seam で回す（$1=fixture file・残りは argv）。
sel() { SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$1")" python3 "$SEL" "${@:2}"; }
# 適格ラベルを上位順に返す（呼出元 lazy walk と同じ awk）。
walk() { sel "$1" | awk -F'\t' '$2=="1"{print $1}'; }
# golden 実行から label 行 1 本を取り出す。
row_of() { sel "$GOLDEN" | awk -F'\t' -v l="$1" '$1==l{print; exit}'; }

# 有効 config dir を作る（$1=dir・env NO_PLUGIN=<name> で当該 plugin を欠落注入）。
mk_cfg() {
  local d="$1"; mkdir -p "$d"
  printf '{}' > "$d/.credentials.json"
  printf '{"hasCompletedOnboarding":true}' > "$d/.claude.json"
  local p
  for p in scribe beads-bdw cmdtokens; do
    [[ "${NO_PLUGIN:-}" == "$p" ]] && continue
    mkdir -p "$d/plugins/$p"
  done
}

# ============================================================================
# selector 単体（純粋計算・fs 非接触）
# ============================================================================

@test "sc-1rq selector: GOLDEN ランキング=black4>black2>default>black3(復帰クラス)・phito(データ無し)除外" {
  # ★sc-7czu で期待値が動いた: black3 は一過性 429 の**復帰クラス**ゆえ候補に残る（tier=1 で末尾）。
  local got; got="$(walk "$GOLDEN" | paste -sd, -)"
  [ "$got" = "black4,black2,default,black3" ]
  # 除外アカは walk に載らない（phito は error_code を持たない＝判定不能ゆえ fail-closed 除外）
  [[ "$(walk "$GOLDEN")" != *phito* ]]
}

@test "sc-1rq selector: 100−pct 変換の値ピン（black4 score=4/h5=82/h7=4・default score=0/h5=100）" {
  local r; r="$(row_of black4)"
  local _l _e _score _h5 _h7 _rest
  IFS=$'\t' read -r _l _e _score _h5 _h7 _rest <<<"$r"
  [ "$_score" = "4" ]      # min(82,4)
  [ "$_h5" = "82" ]        # 100-18
  [ "$_h7" = "4" ]         # 100-96
  r="$(row_of default)"
  IFS=$'\t' read -r _l _e _score _h5 _h7 _rest <<<"$r"
  [ "$_score" = "0" ]      # min(100, 100-100)=0
  [ "$_h5" = "100" ]       # resets_at null → 満残量
}

# ── sc-7czu N1 ───────────────────────────────────────────────────────────────
# inventory: invariant=復帰クラス(429)は col2=1 で候補に残り col10 に demoted:stale(429) を持つ／
#            データ無し stale(phito) は col2=0 のまま除外され reason は malformed: でない
#          | polarity=positive(black3) + negative(phito)
#          | mutant_fingerprint=`_revival_of` の 429 分岐を削除 → black3 の col2 が 0 になり本 tooth が RED
@test "sc-7czu: black3(429)=eligible+demoted マーカー / phito(データ無し)=除外かつ malformed 誤分類しない" {
  # ★旧 tooth「除外理由に stale が入る（black3）」を置換した（sc-7czu §7 vacuous 是正）。旧形は
  #   `row_of black3` の**行全体**部分一致で "stale" を探しており、eligible フラグを見ていないため
  #   col2 が反転しても緑のままだった（＝vacuous）。列を指定して pin し直す。
  local r; r="$(row_of black3)"
  [ "$(awk -F'\t' '{print $2}' <<<"$r")" = "1" ]                    # 復帰クラスは候補に残る
  [[ "$(awk -F'\t' '{print $10}' <<<"$r")" == "demoted:stale(429)" ]]
  # 降格は順位に影響するので advisory:（=影響しないと自己宣言した接頭辞）へは載せない。
  [[ "$(awk -F'\t' '{print $10}' <<<"$r")" != *advisory:* ]]
  local p; p="$(sel "$GOLDEN" | awk -F'\t' '$1=="phito"')"
  [ "$(awk -F'\t' '{print $2}' <<<"$p")" = "0" ]                    # error_code 欠落 → fail-closed 除外
  [[ "$(awk -F'\t' '{print $10}' <<<"$p")" != malformed:* ]]        # shape ドリフト警報の予約語彙を汚さない
  [[ "$(awk -F'\t' '{print $10}' <<<"$p")" == unknown:* ]]
}

@test "sc-1rq selector[a]: API故障=JSON不正 → exit3・stdout空（理由は stderr）" {
  # stdout/stderr を分離（--separate-stderr）: 契約は「stdout 空 + stderr に理由」。
  run --separate-stderr env SCRIBE_USAGE_JSON='{bad json' python3 "$SEL"
  [ "$status" -eq 3 ]
  [ -z "$output" ]           # $output=stdout（空）
  [[ "$stderr" == *"API 故障"* ]]
}

@test "sc-1rq selector[a]: API故障=claude-usage 不在 → exit3" {
  run env -u SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[a]: API故障=claude-usage 非0 exit → exit3" {
  local stub="$BATS_TEST_TMPDIR/usage_nz.sh"
  printf '#!/usr/bin/env bash\nexit 7\n' > "$stub"; chmod +x "$stub"
  run env -u SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD="$stub" python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[a]: API故障=accounts キー不在 → exit3" {
  run env SCRIBE_USAGE_JSON='{"as_of":"x"}' python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[a]: API故障=accounts 空 → exit3" {
  run env SCRIBE_USAGE_JSON='{"accounts":[]}' python3 "$SEL"
  [ "$status" -eq 3 ]
}

@test "sc-1rq selector[b]: 適格0件（全 stale/not-ok）→ exit0・eligible 0 行" {
  run sel "$ZERO"
  [ "$status" -eq 0 ]
  [ -z "$(walk "$ZERO")" ]
}

@test "sc-1rq selector[c]: 個別アカ キー欠落 → 当該除外し続行（good は残る・bad は malformed）" {
  [ "$(walk "$KEYMISS")" = "good" ]
  [[ "$(sel "$KEYMISS" | awk -F'\t' '$1=="bad"')" == *malformed* ]]
}

@test "sc-1rq selector[d]: 同点 → label 辞書順（alpha,zeta）" {
  [ "$(walk "$TIE" | paste -sd, -)" = "alpha,zeta" ]
}

@test "sc-1rq selector[e]: resets_at null → 満残量（pct90 でも h5=100）" {
  local r _l _e _sc _h5 _rest
  r="$(sel "$NULLR" | awk -F'\t' '$1=="x"')"
  IFS=$'\t' read -r _l _e _sc _h5 _rest <<<"$r"
  [ "$_h5" = "100" ]
}

@test "sc-1rq selector[f]: resets_at 過去 → 満残量（pct95 でも h5=100）" {
  local r _l _e _sc _h5 _rest
  r="$(sel "$PASTR" | awk -F'\t' '$1=="x"')"
  IFS=$'\t' read -r _l _e _sc _h5 _rest <<<"$r"
  [ "$_h5" = "100" ]
}

@test "sc-1rq selector[g]: pct誤読回帰ピン — idle(残量90)>busy(残量10)・busy h5=100−90=10" {
  # pct を残量と誤読すれば busy(pct90) が上位に来てこの assert が落ちる。
  [ "$(walk "$PCTPIN" | paste -sd, -)" = "idle,busy" ]
  local r _l _e _sc _h5 _rest
  r="$(sel "$PCTPIN" | awk -F'\t' '$1=="busy"')"
  IFS=$'\t' read -r _l _e _sc _h5 _rest <<<"$r"
  [ "$_h5" = "10" ]
}

@test "sc-1rq selector: 曖昧ケース fixture(pct=0,remaining='',resets_at=null) → crash なし・h5=100/h7=95" {
  run sel "$AMBIG"
  [ "$status" -eq 0 ]
  local r _l _e _sc _h5 _h7 _rest
  r="$(sel "$AMBIG" | awk -F'\t' '$1=="amb"')"
  IFS=$'\t' read -r _l _e _sc _h5 _h7 _rest <<<"$r"
  [ "$_h5" = "100" ]      # null reset
  [ "$_h7" = "95" ]       # 100-5
}

@test "sc-1rq selector: stdin seam（--stdin < fixture）でも同一ランキング" {
  local got
  got="$(SCRIBE_USAGE_NOW="$NOW" python3 "$SEL" --stdin < "$GOLDEN" | awk -F'\t' '$2=="1"{print $1}' | paste -sd, -)"
  [ "$got" = "black4,black2,default,black3" ]   # sc-7czu: black3(429)=復帰クラスが末尾に加わった
}

# ============================================================================
# scribe-spawn.sh --account auto 統合（dry-run + スタブのみ・実 spawn しない）
# ============================================================================

@test "sc-1rq spawn: dry-run auto plan — ランキング可視化 + top-by-usage=black4 + 注入=base/black4" {
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *black4* ]]
  [[ "$output" == *"top-by-usage）=black4"* ]]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=$ABASE/black4"* ]]
  [[ "$output" == *"--account auto（sc-1rq"* ]]
}

@test "sc-1rq spawn: 適格0件 → fail-loud（実起動・resolve 内で die）" {
  # fake id（BD_STUB_OK_IDS 外）だが resolve→die が bd 実在検査より前に走るので到達前に停止する。
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$ZERO")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-none
  [ "$status" -ne 0 ]
  [[ "$output" == *"適格アカウントが 0 件"* ]]
}

@test "sc-1rq spawn: 適格あり but preflight 全滅 → fail-loud（実起動・resolve 末尾 die・facet⑤②(b)）" {
  # sc-1rq finding2: usage 適格0件（上のテスト）とは別 modality＝usage は適格だが全候補の
  # login/onboarding/plugin が欠落。config dir を一切作らないので acctA/acctB 双方 preflight 不通過→末尾 die。
  # リファクタで末尾 die が return 0（主アカ fallback）へ化けたら status=0 になりこの assert が捕える（fail-open 回帰網）。
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$PFAIL")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-pfail
  [ "$status" -ne 0 ]
  [[ "$output" == *"preflight を全て不通過"* ]]
}

@test "sc-1rq spawn: API故障 fallback（admin config dir 保持）→ mirror（preflight 対象化・finding1）" {
  # sc-1rq finding1: 旧実装は ~/.claude(unset)をハードコードし preflight を skip → 非 ~/.claude admin で
  # guard 欠落 dir に無防備 worker を起こす fail-open。mirror なら WCFG_DIR 非空で preflight_config_dir が採用 dir を検査する。
  : > "$NOTE_LOG"
  mk_cfg "$ABASE/adminacct"
  run env -u SCRIBE_USAGE_JSON CLAUDE_CONFIG_DIR="$ABASE/adminacct" \
    SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-fbmirror
  [[ "$output" == *"mirror=$ABASE/adminacct"* ]]
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"fallback=yes"* ]]
  [[ "$notes" == *"FALLBACK:mirror"* ]]
}

@test "sc-1rq spawn: 既存 --account LABEL 経路は不変（auto をラベルと誤解しない）" {
  run env SCRIBE_ACCOUNTS_BASE=/acct/base CLAUDE_CONFIG_DIR=/admin/dir \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account alice sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=/acct/base/alice"* ]]
  [[ "$output" == *"源=account"* ]]
  [[ "$output" != *"--account auto（sc-1rq"* ]]
}

# ============================================================================
# sc-9954: worker 既定を auto へ反転（consult は mirror 据え置き）。chain 不変・失敗意味論不変・監査弁別。
# ============================================================================

@test "sc-9954 spawn: worker 既定（--account 省略）は auto 経路へ入る（defaulted 表示・top-by-usage=black4・opt-in 文言でない）" {
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *maximin* ]]                                    # auto 経路に入った
  [[ "$output" == *"account 既定=auto（sc-9954"* ]]              # 既定反転の defaulted 表示（D-d）
  [[ "$output" == *"top-by-usage）=black4"* ]]                    # selector 実測で最も空いているアカを選定
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=$ABASE/black4"* ]]
  [[ "$output" != *"--account auto（sc-1rq"* ]]                   # 明示 opt-in 文言ではない（D-d 弁別）
}

@test "sc-9954 spawn: 明示 --account auto は opt-in 文言（既定 auto と弁別・defaulted=no 側）" {
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"--account auto（sc-1rq"* ]]                   # 明示 opt-in 文言
  [[ "$output" != *"account 既定=auto（sc-9954"* ]]              # 既定反転の defaulted 表示ではない
}

@test "sc-9954 spawn: consult 既定は mirror 据え置き（auto にしない・admin env を mirror）" {
  run env CLAUDE_CONFIG_DIR=/consult/dir \
    "$SPAWN" --dry-run --consult --anchor "$ANCHOR" sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=/consult/dir"* ]]
  [[ "$output" == *"源=mirror"* ]]
  [[ "$output" != *maximin* ]]                                    # consult は auto へ反転しない
}

@test "sc-9954 spawn: consult 既定（admin env 無し）は unset 据え置き（auto にしない）" {
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    "$SPAWN" --dry-run --consult --anchor "$ANCHOR" sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"unset CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" != *maximin* ]]
}

@test "sc-9954 spawn: --account mirror = admin env mirror 明示（accounts-base/mirror へ導出しない・auto 化しない）" {
  run env CLAUDE_CONFIG_DIR=/admin/dir SCRIBE_ACCOUNTS_BASE=/acct/base \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account mirror sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=/admin/dir"* ]]      # admin env を mirror
  [[ "$output" == *"源=mirror"* ]]
  [[ "$output" != *"/acct/base/mirror"* ]]                        # <accounts-base>/mirror へは導出しない（D-c）
  [[ "$output" != *maximin* ]]                                    # opt-out ゆえ auto 化しない
}

@test "sc-9954 spawn: --account mirror（admin env 無し）は unset・accounts-base/mirror 不在でも die しない" {
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account mirror sc-auto-test
  [ "$status" -eq 0 ]                                             # 不在 dir 導出しない＝die しない
  [[ "$output" == *"unset CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" != *maximin* ]]
}

@test "sc-9954 spawn: chain 不変 — SCRIBE_WORKER_CONFIG_DIR env は既定 auto に優先（源=env・auto 化しない）" {
  run env -u CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR=/override/dir \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"export CLAUDE_CONFIG_DIR=/override/dir"* ]]
  [[ "$output" == *"源=env"* ]]
  [[ "$output" != *maximin* ]]                                    # env が既定 auto に勝つ（chain 不変）
}

@test "sc-9954 spawn: 既定 auto の失敗意味論不変（API 故障→loud fallback）＋監査に defaulted=yes" {
  # D-b: resolve_account_auto の失敗意味論は明示 auto と同一（API 故障=loud fallback）。D-d: 既定反転由来は
  # 監査 snapshot で defaulted=yes と弁別できる。zz-default は BD_STUB_OK_IDS 外＝resolve/note 後に bd-check で
  # 死ぬ（worktree を作らない）が、status は問わず fallback 挙動と note のみを検証する（既存 API故障テストと同姿勢）。
  : > "$NOTE_LOG"
  run env -u SCRIBE_USAGE_JSON -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" zz-default
  [[ "$output" == *"主アカウント（~/.claude・unset 経路）へ fallback"* ]]   # 明示 auto と同一の loud fallback
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"fallback=yes"* ]]
  [[ "$notes" == *"defaulted=yes"* ]]                             # 既定反転由来の弁別（D-d）
}

@test "sc-9954 spawn: 既定 auto の正常採用 note に defaulted=yes（明示 auto は defaulted=no）" {
  : > "$NOTE_LOG"
  mk_cfg "$ABASE/black4"; mk_cfg "$ABASE/black2"
  # 既定（--account 省略）: defaulted=yes
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" zz-def-note
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"chosen=black4"* ]]
  [[ "$notes" == *"defaulted=yes"* ]]
  # 明示 --account auto: defaulted=no
  : > "$NOTE_LOG"
  run env -u CLAUDE_CONFIG_DIR -u SCRIBE_WORKER_CONFIG_DIR \
    SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-exp-note
  notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"chosen=black4"* ]]
  [[ "$notes" == *"defaulted=no"* ]]
}

@test "sc-1rq spawn: lazy walk — 上位 black4(plugin欠落)を skip し black2 を採用（実起動）" {
  mk_cfg "$ABASE/black2"
  NO_PLUGIN=scribe mk_cfg "$ABASE/black4"
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-walk
  [[ "$output" == *"候補 'black4'"* ]]
  [[ "$output" == *"'black2' を採用"* ]]
}

@test "sc-1rq spawn: default→unset 写像（dry-run・default だけ適格→export しない）" {
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$ONLYDEF")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    "$SPAWN" --dry-run --repo "$ANCHOR" --anchor "$ANCHOR" --account auto sc-auto-test
  [ "$status" -eq 0 ]
  [[ "$output" == *"top-by-usage=default"* ]]
  [[ "$output" == *"unset CLAUDE_CONFIG_DIR"* ]]
  [[ "$output" != *"export CLAUDE_CONFIG_DIR=$ABASE/default"* ]]
}

@test "sc-1rq spawn: API故障 → 主アカ fallback + 監査 note(接頭辞 account-select:・fallback=yes)" {
  : > "$NOTE_LOG"
  run env -u SCRIBE_USAGE_JSON SCRIBE_USAGE_CMD=/nonexistent-claude-usage-xyz \
    SCRIBE_ACCOUNTS_BASE="$ABASE" BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-fb
  [[ "$output" == *"主アカウント（~/.claude・unset 経路）へ fallback"* ]]
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"account-select:"* ]]
  [[ "$notes" == *"fallback=yes"* ]]
}

# ★sc-7czu で title も改訂: 本 tooth の body は「black3=復帰クラスで col2=1」「除外側の pin は phito」へ
#   動いており、旧 title の「除外black3」は逆の不変条件を述べていた（bats の失敗レポートは title で読まれる）。
@test "sc-1rq spawn: 正常採用時 監査 note — 接頭辞 + chosen=black4 + 候補全員(default/black3=復帰クラス)・除外 phito snapshot" {
  : > "$NOTE_LOG"
  mk_cfg "$ABASE/black4"; mk_cfg "$ABASE/black2"
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-note
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"chosen=black4"* ]]
  # ★sc-7czu §7 vacuous 是正: 旧形は `*default*` / `*black3*` の**素の部分一致**で、eligible 列が
  #   反転しても（さらに label が診断文へ出るだけでも）緑になった。呼出元 snapshot は
  #   `label|eligible|score|…` 形式なので col2 まで含めて pin する。
  [[ "$notes" == *"default|1|"* ]]   # snapshot は候補全員（適格）
  [[ "$notes" == *"black3|1|"* ]]    # 復帰クラスも候補として載る（sc-7czu で 0→1 へ動いた）
  [[ "$notes" == *"phito|0|"* ]]     # snapshot は除外アカも含む
}

# ============================================================================
# sc-j8zv: 「適格 0 件」の 2 種を機械弁別する teeth
#   (A) 上流劣化（usage 側に健全 account が無い）= selector は正しい → exit 0（従来不変）
#   (B) selector 誤判定（usage は健全と報告したのに全部落とした）→ exit 4 で fail-loud
# 現行は (A)(B) が同じ「exit 0・eligible 0 行」に潰れ、呼出元は一律「全アカウント認証切れ」と誤帰属した。
# ★変異注入で RED 化する teeth = 「usage 正常 → exit 0 かつ eligible≥1」の 2 本
#   （selector が健全 account を落とす変異を入れると exit 4 になり RED・実測は selftest-sc-j8zv.local.sh）。
# ============================================================================

@test "sc-j8zv teeth(B): usage 健全なのに適格0件 → exit 4（誤判定として fail-loud・上流劣化と別コード）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$HEALTHYDROP")" python3 "$SEL"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"selector 誤判定"* ]]
  # ★1 行 1 assert（`[[ A ]] && [[ B ]]` と書かない）: 中間行の AND-OR リストは左辺が false でも
  #   set -e が発火せず bats が pass する＝assert が沈黙する（実測 2026-07-27・self-review）。
  [[ "$stderr" == *acctA* ]]                                 # 犯人ラベルを名指しする
  [[ "$stderr" == *acctB* ]]
  [[ "$stderr" == *"malformed:欠落"* ]]                       # 落とした理由も出す
  # 監査を殺さない: exit 4 でも TSV は stdout に出る（呼出元 snapshot が空にならない）。
  [ -n "$output" ]
  [ "$(awk -F'\t' '$2=="0"' <<<"$output" | wc -l)" -eq 2 ]
}

@test "sc-j8zv teeth(A): 上流劣化(全 dead・実データ有り rc=0) → exit 0 のまま + error_code 内訳診断" {
  # incident 署名そのもの: usage を直に叩けば値が返る（degrade は cache 実データを載せる）が健全 0 件。
  # ★sc-7czu で実例入力を「全 429」→「全 nologin」へ置換した（429 は復帰クラスになり (A) の実例では
  #   なくなったため）。pin する不変条件は変えない: exit 0 / error_code 内訳 / 健全の証拠ではない注記。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$DEGRADED")" python3 "$SEL"
  [ "$status" -eq 0 ]                                  # (B) と別コード＝機械弁別できる
  [ -z "$(awk -F'\t' '$2=="1"' <<<"$output")" ]        # 適格 0 件は従来どおり
  [[ "$stderr" == *"上流劣化"* ]]
  [[ "$stderr" == *"nologin=2"* ]]                      # error_code 内訳（要 re-login と読める）
  [[ "$stderr" == *"健全の証拠ではない"* ]]             # rc=0/値あり を健全と誤読させない注記
  [[ "$stderr" != *"selector 誤判定"* ]]                # (B) の文言を誤って出さない
}

@test "sc-j8zv teeth: usage 正常（GOLDEN）→ exit 0 かつ eligible≥1（変異注入で exit 4 化=RED になる本体）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$2=="1"' <<<"$output" | wc -l)" -ge 1 ]
  [[ "$stderr" != *"selector 誤判定"* ]]
}

@test "sc-j8zv teeth: usage 正常（stdin seam）→ exit 0 かつ eligible≥1（seam 別経路でも同じ不変条件）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" python3 "$SEL" --stdin < "$PCTPIN"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$2=="1"' <<<"$output" | wc -l)" -eq 2 ]
}

@test "sc-j8zv: 部分ドリフト（健全だが 1 件だけ除外・適格は残る）→ exit 0 + warn（早期兆候）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$KEYMISS")" python3 "$SEL"
  [ "$status" -eq 0 ]                                   # 適格が残るので fail-loud しない
  [[ "$stderr" == *"warn: usage は健全と報告したのに selector が除外"* ]]
  [[ "$stderr" == *"bad="* ]]
}

@test "sc-j8zv: ok/stale の型ドリフト → 上流劣化と断じず shape 契約変更の疑いを併記（判定器の盲点を告知）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$SHAPEDRIFT")" python3 "$SEL"
  [ "$status" -eq 0 ]                                   # 健全申告が 1 件も無い＝(B) ではない
  [[ "$stderr" == *"shape 契約変更"* ]]
  [[ "$stderr" == *"malformed 除外が 1 件"* ]]
}

@test "sc-j8zv 要求③ characterization: 枯渇(残量0)でも eligible=1 のまま（floor 無し）+ advisory + 枯渇 warn" {
  # ★現行 semantics「枯渇（実効残量 0）でも eligible=1・**floor 無し**」を明示的に pin する。floor を
  #   入れる/入れないは admin 裁定事項ゆえ本 cell では選定を変えない。将来 floor を入れるなら本テストを
  #   意図的に書き換えること
  #   （旧コメントは「stale のみ除外・枯渇は減点」だったが sc-7czu で事実に反する記述になったため改訂:
  #    stale は除外されず復帰クラスは tier=1 の候補になり、「減点」も禁止＝tier 化で順位を付ける。
  #    selector 側の同語句は本 fix で 2 箇所とも中立表現へ書き換え済みで、ここだけが取り残されていた）
  #   （黙って挙動が反転したらここが RED になる＝gap が機械可視のまま残る）。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$DEPLETED")" python3 "$SEL"
  [ "$status" -eq 0 ]
  local _l _e _sc _rest
  IFS=$'\t' read -r _l _e _sc _rest <<<"$output"
  [ "$_e" = "1" ]                                       # 枯渇でも適格（＝floor が無い）
  [ "$_sc" = "0" ]                                      # maximin score=0（実効残量ゼロ）
  [[ "$output" == *"advisory:depleted(headroom=0)"* ]]  # 監査 snapshot へ durable に残る印
  [[ "$stderr" == *"枯渇警告"* ]]                        # 最上位が枯渇なら loud に警告
  [[ "$stderr" == *"floor が無い"* ]]
}

@test "sc-j8zv: 枯渇 advisory は col10 のみ（eligible/順位/exit を変えない＝選定 semantics 不変）" {
  # GOLDEN の default は 7d pct=100（枯渇）だが従来どおり 3 位の適格のまま。
  # ★sc-7czu で期待値が動いた（black3=復帰クラスが末尾に加わった）。枯渇 advisory 側の 3 本
  #   （col2=1 / score=0 / advisory:depleted）の検知力は落とさない。
  [ "$(walk "$GOLDEN" | paste -sd, -)" = "black4,black2,default,black3" ]
  local r; r="$(row_of default)"
  [[ "$r" == *"advisory:depleted"* ]]
  [ "$(awk -F'\t' '{print $2}' <<<"$r")" = "1" ]
  # 上位が枯渇でないので枯渇 warn は出ない（happy path を騒がせない）。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" python3 "$SEL"
  [[ "$stderr" != *"枯渇警告"* ]]
}

@test "sc-j8zv spawn: selector 誤判定(exit 4) は呼出元でも fail-loud（『適格0件』と別メッセージ）" {
  # 呼出元 scribe-spawn.sh は未知 exit を一律 fail-loud する（既存規約）。ゆえに本 cell が selector 側だけ
  # を変えても spawn は silent 続行しない。かつ (A) 用の「適格アカウントが 0 件」誤帰属を出さない。
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$HEALTHYDROP")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-misjudge
  [ "$status" -ne 0 ]
  [[ "$output" == *"想定外 exit（4）"* ]]
  [[ "$output" == *"selector 誤判定"* ]]                 # selector の stderr が呼出元へ素通しされる
  [[ "$output" != *"適格アカウントが 0 件"* ]]           # (A) の誤帰属メッセージへ落ちない
}

@test "sc-j8zv spawn: 上流劣化(全 dead)は従来どおり『適格0件』fail-loud（(A) の意味論を変えない）" {
  # ★sc-7czu: fixture を全 429→全 nologin へ置換したが、呼出元から見た意味論（適格0件で fail-loud）は不変。
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$DEGRADED")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-degraded
  [ "$status" -ne 0 ]
  [[ "$output" == *"適格アカウントが 0 件"* ]]
  [[ "$output" == *"上流劣化"* ]]                        # selector 診断が pane に出る
  [[ "$output" != *"想定外 exit"* ]]
}

@test "sc-j8zv teeth: exit 4 では selector 自身が rc 非依存の監査ブロックを stderr へ出す（呼出元の else 欠落を迂回）" {
  # 実測 2026-07-27: 呼出元の `account-select:` snapshot は rc=4 では 1 行も出ない（probe 分岐は else 欠落 /
  # auto 経路は die が emit より前）。異常時にこそ監査が消える形ゆえ、selector 自身を最後の砦にする。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$HEALTHYDROP")" python3 "$SEL"
  [ "$status" -eq 4 ]
  [[ "$stderr" == *"account-select: origin=selector rc=4"* ]]           # 呼出元由来と機械弁別できる印
  [[ "$stderr" == *"account-select: cols=label|eligible|score"* ]]
  # stdout の TSV 全行が '|' 区切りで stderr にも載る（監査の等価性＝stdout を捨てる呼出元でも再構成できる）
  [ "$(awk '/^account-select:   /' <<<"$stderr" | wc -l)" -eq "$(grep -c . <<<"$output")" ]
  [[ "$stderr" == *"acctA|0|-|-|-"* ]]                                  # 空欄は '-'（呼出元 snapshot と同形式）
}

@test "sc-j8zv teeth: 正常時(exit 0)は selector 監査ブロックを出さない（呼出元 snapshot と二重記録しない）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$GOLDEN")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"account-select: origin=selector"* ]]
  # (A) 上流劣化（適格 0 件だが exit 0）でも出さない＝出すのは exit 4 のときだけ、が不変条件。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$DEGRADED")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [[ "$stderr" != *"account-select: origin=selector"* ]]
}

@test "sc-j8zv teeth: 監査ブロックは 1 account = 1 行（上流由来の改行で行注入できない＝弁別規約を data で破らせない）" {
  # ★self-review 2026-07-27 の実測 blocking: `origin=selector` / `chosen=` による呼出元弁別は、セルへ
  #   claude-usage 由来の改行が素通しできると **data だけで偽造できた**（呼出元が選んでもいない account を
  #   「呼出元が選んだ」と読める監査行を注入でき、横断 grep 集計と incident 再構成が汚染される）。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$INJECT")" python3 "$SEL"
  [ "$status" -eq 4 ]
  # 不変条件: 監査行は accounts 件数ちょうど（見出し 2 行は prefix が違うので別枠）。
  [ "$(awk '/^account-select:   /' <<<"$stderr" | wc -l)" -eq 3 ]
  [ "$(grep -c '^account-select: [^ ]' <<<"$stderr")" -eq 2 ]   # 見出しは 2 行のみ（origin / cols）
  # 不変条件: selector は `account-select: chosen=` で始まる行を決して出さない（呼出元行の偽造不能）。
  [ "$(grep -c '^account-select: chosen=' <<<"$stderr" || true)" -eq 0 ]
  [ "$(grep -c 'source=forged' <<<"$stderr" || true)" -eq 3 ]   # 情報は消さず同じ行へ畳む（3 hit）
  # 無害化は可逆表記（\n）＝監査価値を落とさない。error 経路・label 経路の両方を塞ぐ。
  [[ "$stderr" == *'not-ok:boom\naccount-select: chosen=acctZ'* ]]
  [[ "$stderr" == *'acctC\naccount-select: chosen=acctY'* ]]
  # 診断 warn 行（label 経由）も 1 行に畳む＝stderr のどの面からも偽造できない。
  [ "$(awk '/^scribe-account-select:/' <<<"$stderr" | wc -l)" -eq 3 ]
}

@test "sc-j8zv teeth: stdout TSV も行注入/列注入を塞ぐ（呼出元 lazy walk が偽 label・使用不可 account を選ばない）" {
  # ★self-review 4 巡目の実測 blocking: 前巡は stderr（監査面）だけを塞いだが、**config dir を実際に
  #   決めるのは stdout**。素通しだと (i) 改行で偽の行を挿し込み存在しない label を最上位候補にでき、
  #   (ii) TAB で ok=false/stale=true の除外行を col2="1" に見せて使用不可 account を適格にできた。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$TSVINJECT")" python3 "$SEL"
  [ "$status" -eq 0 ]
  # 不変条件: 1 account = 1 行 × 10 列（行注入・列注入のどちらでも形が崩れない）。
  [ "$(grep -c . <<<"$output")" -eq 3 ]
  [ "$(awk -F'\t' '{print NF}' <<<"$output" | sort -u | paste -sd, -)" = "10" ]
  # 呼出元 lazy walk（scribe-spawn.sh:517 / orch-spawn-admin.sh:635 と同型）の候補集合を直接 pin する。
  local picks; picks="$(awk -F'\t' '$2=="1"{print $1}' <<<"$output")"
  [ "$(grep -c . <<<"$picks")" -eq 2 ]
  [ "$(grep -cx 'EVIL' <<<"$picks" || true)" -eq 0 ]      # (i) 行注入: 偽 label が候補に現れない
  [ "$(grep -c 'victim' <<<"$picks" || true)" -eq 0 ]     # (ii) 列注入: 使用不可 account が適格化しない
  [ "$(head -1 <<<"$picks")" = 'good1\nEVIL\t1' ]         # 最上位は実在 account のまま（分断もされない）
  # 無害化は可逆表記＝監査価値を落とさない（label の中身は消さず 1 セルへ畳むだけ）。
  [[ "$output" == *'victim\t1\t100'* ]]
}

@test "sc-j8zv teeth: exit 4 の注入入力でも stdout は 1 account = 1 行 × 10 列（stderr だけの片側防御にしない）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$INJECT")" python3 "$SEL"
  [ "$status" -eq 4 ]
  [ "$(grep -c . <<<"$output")" -eq 3 ]
  [ "$(awk -F'\t' '{print NF}' <<<"$output" | sort -u | paste -sd, -)" = "10" ]
  # 全件除外の入力なので、呼出元の候補集合は空でなければならない（data で適格を捏造できない）。
  [ -z "$(awk -F'\t' '$2=="1"' <<<"$output")" ]
}

@test "sc-j8zv teeth: 枯渇 warn(exit 0) も label を畳む＝selector は chosen= 行を『正常経路でも』決して出さない" {
  # ★self-review 4 巡目の実測 blocking: 前巡の行注入 fix は片面（exit 4 の監査面）だけで、floor 無し
  #   semantics では**平常運転**で踏む枯渇 warn が label を生のまま出していた。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$DEPINJECT")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"枯渇警告"* ]]
  # 不変条件: selector は `account-select:` で始まる行を exit 0 では 1 行も出さない（偽の呼出元行の否定）。
  [ "$(grep -c '^account-select:' <<<"$stderr" || true)" -eq 0 ]
  [ "$(grep -c '^account-select: chosen=' <<<"$stderr" || true)" -eq 0 ]
  # 枯渇 warn は 2 行ちょうど（改行注入で行が増えない）＝stderr のどの面からも偽造できない。
  [ "$(grep -c '^scribe-account-select:' <<<"$stderr" || true)" -eq 2 ]
  [ "$(grep -c . <<<"$stderr")" -eq 2 ]
  [[ "$stderr" == *'acctX\naccount-select: chosen=FORGED'* ]]   # 可逆表記（情報は落とさない）
  [ "$(grep -c . <<<"$output")" -eq 1 ]                          # stdout も 1 account = 1 行
}

@test "sc-j8zv teeth(B'): 健全 × 上流 utilization 欠落 は exit 4 でも『selector 誤判定』と誤帰属しない" {
  # ★self-review 2026-07-27 の実測 blocking: 窓あり × pct=null は上流 norm_pct が null を返す形＝
  #   健全申告のまま起こりうる。旧実装は (B) と一括りにして「本 selector 側の欠陥」と断じていた。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$INDET")" python3 "$SEL"
  [ "$status" -eq 4 ]                                   # 選定不能なので fail-loud 自体は維持
  [[ "$stderr" == *"上流 utilization 欠落"* ]]
  [[ "$stderr" == *"selector の欠陥ではありません"* ]]
  [[ "$stderr" != *"selector 誤判定"* ]]                # 犯人を取り違えない（誤帰属の teeth）
  [[ "$stderr" == *"acctA=indeterminate:残量判定不能"* ]]
  # 監査 trail は exit 4 の不変条件どおり出るが、reason は層別結果を載せる（trail に誤帰属を焼かない）。
  [[ "$stderr" == *"account-select: origin=selector rc=4 reason=upstream-utilization-missing"* ]]
}

@test "sc-j8zv 層別: (B') は適格が残る場合『shape ドリフトの早期兆候』warn に数えない（loud チャネルを摩耗させない）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$INDETMIX")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$2=="1"' <<<"$output" | wc -l)" -eq 1 ]
  [[ "$stderr" != *"shape 契約ドリフトの早期兆候"* ]]   # malformed でないものを欠陥の兆候と数えない
  [[ "$stderr" == *"utilization を返しておらず"* ]]     # 事実としては可視化する（黙らせない）
  [[ "$stderr" != *"selector 誤判定"* ]]
}

@test "sc-j8zv characterization: exit 4 の spawn は bd notes へ snapshot を書かない（die が emit より前）— pane には selector 監査が残る" {
  # ★呼出元契約 (b)「監査 snapshot を rc に関わらず出力」の **未達を現状 pin** する（別 bead の対象）。
  #   auto 経路は fail-loud はする（(a) 充足）が emit_account_select_note へ到達しないため notes が空になる。
  #   別 bead で emit 順序が直ったらここが RED になり、gap が閉じたことが機械可視になる（黙って直らない）。
  : > "$NOTE_LOG"
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$HEALTHYDROP")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-misjudge-note
  [ "$status" -ne 0 ]
  [[ "$output" == *"想定外 exit（4）"* ]]                # account 解決の段で die したことを確定させる
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" != *"account-select: chosen="* ]]          # 呼出元 snapshot は notes に無い（現状）
  [[ "$output" == *"account-select: origin=selector rc=4"* ]]  # selector 側の監査は pane へ素通しで残る
}

# ============================================================================
# sc-7czu: stale を候補に残し tier で降格・死亡のみ除外（実効 pool 半減の解消）
#   欠陥: 適格条件が `ok∧非stale` だけだったため、1 回の認証付き呼出や時間経過で回復する account まで
#         恒常的に候補外へ落ち、実効 pool が半減していた（stale は「live fetch 失敗→snapshot degrade」の
#         印であって認証切れとは限らない）。
#   是正: 三分類（healthy / 復帰クラス / 除外）+ 並べ替えキー (tier, -score, label)。
#   ★各 tooth に assertion inventory row（invariant / polarity / mutant_fingerprint）を併記する
#     （書式 SSOT = tests/wf-args-lint.bats）。
# ============================================================================

# ── sc-7czu T-CLASS ──────────────────────────────────────────────────────────
# inventory: invariant=クラス判定 — skip_reason=token_expired と error_code=429 は eligible=1／
#            skip_reason=no_token は eligible=0／healthy は復帰クラスの全部より上位／
#            demoted マーカーの code は**由来ごとに異なる値**が載る（429 固定ではない）
#          | polarity=positive(revExp,rev429,revCodeOnly,revSkipOnly) + negative(dead)
#          | mutant_fingerprint=`_REVIVAL_SKIP_REASONS` へ "no_token" を追加 → dead が eligible=1 になり RED /
#            `_revival_of` の OR を片半へ縮める（`if code in _REVIVAL_CODES:` だけ／`if skip in
#            _REVIVAL_SKIP_REASONS:` だけ）→ revSkipOnly／revCodeOnly がそれぞれ RED /
#            `tier, dcode = 1, (code or "?")` を `1, "429"` へ固定 → demoted の code assert が RED
#            （★revExp は error_code と skip_reason を**両方**持つため、この行だけでは OR の片半を
#              消す変異が全 tooth green で生存する＝実測。片方しか持たない 2 行が必須。sc-7czu WF 指摘）
@test "sc-7czu T-CLASS: 復帰=token_expired/429 は eligible=1・死亡=no_token は 0・healthy が全部より上位" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$CLASSES")" python3 "$SEL"
  [ "$status" -eq 0 ]
  local el; el() { awk -F'\t' -v l="$1" '$1==l{print $2}' <<<"$output"; }
  [ "$(el healthy)" = "1" ]
  [ "$(el revExp)" = "1" ]   # (i) 失効 token の pre-flight skip = CC 側 refresh で回復する生存クラス
  [ "$(el rev429)" = "1" ]   # (ii) 一過性 HTTP 429 = sc-j8zv incident の実体
  [ "$(el dead)" = "0" ]     # (iii) credential 不在 = 回復しない＝従来どおり除外
  # allowlist の 2 経路を**独立に** pin する（片方しか持たない行でないと OR の片半を消す変異が生存する）。
  [ "$(el revCodeOnly)" = "1" ]   # error_code=expired だけ（skip_reason 無し）でも復帰
  [ "$(el revSkipOnly)" = "1" ]   # skip_reason=token_expired だけ（error_code 無し）でも復帰
  # (iv) 順位保証: healthy は score 1 と最下位なのに、score 99〜96 の復帰クラスより上に来る（tier 化）。
  #      ★「1 位でない」ではなく walk 順の**完全一致**で pin する（2 位を許すと lazy walk / 先頭 1 件
  #        採用で即採用され、保証にならない）。
  [ "$(awk -F'\t' '$2=="1"{print $1}' <<<"$output" | paste -sd, -)" \
    = "healthy,revExp,rev429,revCodeOnly,revSkipOnly" ]
  # demoted マーカーの code は**由来ごとに違う値**が載る（監査面で後から層別するための情報）。
  #   ここを 429 固定へ潰す退行は、429 行だけを見る assert では検知できない（sc-7czu WF 指摘・実測）。
  local c10; c10() { awk -F'\t' -v l="$1" '$1==l{print $10}' <<<"$output"; }
  [ "$(c10 rev429)" = "demoted:stale(429)" ]
  [ "$(c10 revCodeOnly)" = "demoted:stale(expired)" ]
  [ "$(c10 revSkipOnly)" = "demoted:stale(token_expired)" ]   # code 欠落時は skip_reason が由来として載る
}

# ── sc-7czu T-TIER ───────────────────────────────────────────────────────────
# inventory: invariant=healthy な eligible が 1 件でもあれば eligible な stale は「その全部より下」
#          | polarity=negative-control(GOLDEN の stale は score 80・healthy 最上位は score 4)
#          | mutant_fingerprint=`eligible.sort` の key を (-e[1], e[2]) へ戻す → black3 が 1 位になり RED
@test "sc-7czu T-TIER: GOLDEN で eligible な stale は全 healthy より下（score 減点では成立しない否定対照）" {
  # black3 は score 80、healthy 最上位 black4 は score 4。**いかなる固定減点でも**追い越しは残る
  # （headroom はクランプせず 100-pct は非有界・resets_at が過去なら 100 に張り付く）＝tier 化の根拠。
  local picks; picks="$(walk "$GOLDEN")"
  [ "$(paste -sd, - <<<"$picks")" = "black4,black2,default,black3" ]
  # score 値そのものは 1 文字も変えない（減点していないことを col3 で直接 pin する）。
  local r; r="$(row_of black3)"
  [ "$(awk -F'\t' '{print $3}' <<<"$r")" = "80" ]   # min(h5=90, h7=80)
  [ "$(awk -F'\t' '{print $4}' <<<"$r")" = "90" ]   # 100-10
  [ "$(awk -F'\t' '{print $5}' <<<"$r")" = "80" ]   # 100-20
  # healthy 最上位の score は black3 より小さいのに上位＝tier が第一キーである証拠。
  [ "$(awk -F'\t' '{print $3}' <<<"$(row_of black4)")" = "4" ]
}

# ── sc-7czu T-HTTP ───────────────────────────────────────────────────────────
# inventory: invariant=HTTP status の allowlist 境界（429/5xx **のみ**復帰 / 401・403・その他の非 5xx・
#            未知語彙は除外）
#          | polarity=positive(503) + negative(401,403,404,zzz)
#          | mutant_fingerprint=`_revival_of` の HTTP 判定を `st >= 400` へ緩める → s401/s403 が RED /
#            同判定を `st is not None and st not in (401, 403)` へ緩める（＝401/403 以外の全 status を
#            復帰扱い＝allowlist を否定側から破壊する fail-open 変異）→ s404 が RED
#            （★s404 行が無いと後者の変異は全 tooth green のまま生存する＝実測。sc-7czu self-review）
@test "sc-7czu T-HTTP: 429/5xx のみ復帰・401/403/404 と未知語彙は除外（全て stale=true＝フラグで層別しない）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$HTTPCLASS")" python3 "$SEL"
  local el; el() { awk -F'\t' -v l="$1" '$1==l{print $2}' <<<"$output"; }
  [ "$(el s503)" = "1" ]
  [ "$(el s401)" = "0" ]
  [ "$(el s403)" = "0" ]
  [ "$(el s404)" = "0" ]     # 401/403 以外の非 5xx も復帰しない＝allowlist は「429/5xx のみ」で閉じる
  [ "$(el s600)" = "0" ]     # 上限側も閉じる（5xx は 599 まで。`500 <= st` へ緩める変異の否定対照）
  [ "$(el sUnk)" = "0" ]     # 未知語彙は fail-closed（「知らないコード＝たぶん生きてる」に倒さない）
  # demoted の code は由来ごとに異なる値（429 固定への潰しを 5xx 側からも検知する）。
  [ "$(awk -F'\t' '$1=="s503"{print $10}' <<<"$output")" = "demoted:stale(503)" ]
  # 除外理由は由来が分かる形（dead: / unknown:）で、shape ドリフト警報の予約語彙 malformed: を使わない。
  [[ "$(awk -F'\t' '$1=="s401"{print $10}' <<<"$output")" == dead:401* ]]
  [[ "$(awk -F'\t' '$1=="s404"{print $10}' <<<"$output")" == dead:404* ]]
  [[ "$(awk -F'\t' '$1=="s600"{print $10}' <<<"$output")" == dead:600* ]]
  [[ "$(awk -F'\t' '$1=="sUnk"{print $10}' <<<"$output")" == unknown:zzz* ]]
  [ "$(grep -c 'malformed:' <<<"$output" || true)" -eq 0 ]
}

# ── sc-7czu T-NODATA ─────────────────────────────────────────────────────────
# inventory: invariant=復帰クラスだが採点不能なら除外し、reason は stale-nodata:（malformed: 禁止）／
#            _SCORE_KEYS 欠落検査は緩めない（緩めると headroom(None,None)=100 で 1 位に化ける）
#          | polarity=negative
#          | mutant_fingerprint=`missing` 検査を tier==1 で skip → acctNoData が score 100 の 1 位になり RED
@test "sc-7czu T-NODATA: 復帰クラス×データ無しは除外・reason は stale-nodata:（malformed: へ落とさない）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$REVNODATA")" python3 "$SEL"
  [ "$status" -eq 0 ]
  local row; row="$(awk -F'\t' '$1=="acctNoData"' <<<"$output")"
  [ "$(awk -F'\t' '{print $2}' <<<"$row")" = "0" ]
  [[ "$(awk -F'\t' '{print $10}' <<<"$row")" == stale-nodata:* ]]
  [[ "$(awk -F'\t' '{print $10}' <<<"$row")" != malformed:* ]]
  # 予約語彙を汚していない＝「shape 契約変更の疑い」偽警報が出ない（通常運転で必ず踏む形）。
  [[ "$stderr" != *"shape 契約変更"* ]]
  # healthy 側は無傷（1 位のまま）。
  [ "$(awk -F'\t' '$2=="1"{print $1}' <<<"$output")" = "acctA" ]
}

# ── sc-7czu T-MALFORM-PIN ────────────────────────────────────────────────────
# inventory: invariant=データ無し stale（GOLDEN phito / ZERO a / ONLYDEF other）が malformed: に落ちない
#          | polarity=negative
#          | mutant_fingerprint=`_dead_reason` の返り値を "malformed:dead" にする → 3 入力とも RED
@test "sc-7czu T-MALFORM-PIN: データ無し stale は malformed: へ落ちない（偽 shape-drift 警報を出さない）" {
  local out
  out="$(sel "$GOLDEN")"
  [[ "$(awk -F'\t' '$1=="phito"{print $10}' <<<"$out")" != malformed:* ]]
  out="$(sel "$ZERO")"
  [[ "$(awk -F'\t' '$1=="a"{print $10}' <<<"$out")" != malformed:* ]]
  out="$(sel "$ONLYDEF")"
  [[ "$(awk -F'\t' '$1=="other"{print $10}' <<<"$out")" != malformed:* ]]
}

# ── sc-7czu T1 ───────────────────────────────────────────────────────────────
# inventory: invariant=healthy が全滅していれば、採点可能な stale が eligible に残っていても exit 4 + 犯人ラベル
#          | polarity=positive(exit 4 が維持される)
#          | mutant_fingerprint=`_diagnose` の条件を `if not eligible:` へ戻す → status が 0 になり RED
@test "sc-7czu T1: healthy 全滅 × 採点可能な stale が eligible → 依然 exit 4（旧条件だと rc=0 へ落ちる）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$T1DROP")" python3 "$SEL"
  [ "$status" -eq 4 ]
  [ "$(awk -F'\t' '$2=="1"{print $1}' <<<"$output")" = "acctR" ]   # stale 復帰クラスは適格として残る
  [[ "$stderr" == *"selector 誤判定"* ]]
  [[ "$stderr" == *acctA* ]]                                       # 犯人ラベルを名指しする
  [[ "$stderr" == *acctB* ]]
  [[ "$stderr" == *"malformed:欠落"* ]]
  [[ "$stderr" == *"account-select: origin=selector rc=4 reason=misjudge"* ]]
}

# ── sc-7czu T1B ──────────────────────────────────────────────────────────────
# inventory: invariant=healthy 由来の適格は accounts の位置 index で数える＝healthy 行と復帰行が同一
#            label でも exit 4 + reason=misjudge が生き残る（label 衝突で teeth を disarm できない）
#          | polarity=positive(exit 4 が維持される)
#          | mutant_fingerprint=`healthy_elig` を label 集合の所属判定
#            （`[lab for lab in healthy_labels if lab in elig_set]`）へ戻す → status が 0 になり RED
@test "sc-7czu T1B: healthy 全滅 × 同一 label の stale が eligible → 依然 exit 4（label 一致では数えない）" {
  # label は上流の一意性保証が無い（同一 account が 2 経路で発見されると同名行が 2 つ出る）。label 代理で
  # 「healthy 由来の適格」を数えると、healthy 行が全滅していても同名の tier=1 行だけで rc=4 が rc=0 へ落ちる。
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$T1SAME")" python3 "$SEL"
  [ "$status" -eq 4 ]
  [ "$(awk -F'\t' '$2=="1"{print $10}' <<<"$output")" = "demoted:stale(429)" ]  # 復帰行は適格のまま
  [ "$(awk -F'\t' '$2=="0"{print $1}' <<<"$output")" = "acctA" ]                # healthy 行は全滅
  [[ "$stderr" == *"selector 誤判定"* ]]
  [[ "$stderr" == *"malformed:欠落"* ]]                                         # 犯人の除外理由を名指しする
  [[ "$stderr" == *"account-select: origin=selector rc=4 reason=misjudge"* ]]
}

# ── sc-7czu T2 ───────────────────────────────────────────────────────────────
# inventory: invariant=healthy 0 件なら、stale が eligible でも (A) の error_code 内訳診断が exit 0 で出続け、
#            かつ**新 boot-path 固有の補償 warn**（適格 N 件はいずれも復帰クラス＝健全な候補は 0 件）が出る
#          | polarity=positive((A) 診断が黙らない)
#          | mutant_fingerprint=`if not healthy_labels:` ブロックを `if not eligible:` 配下へ戻す → 診断が消え RED /
#            selector :552-556 の `if elig_labels:` warn ブロックを丸ごと削除 → 「健全な候補は 0 件」が消え RED
@test "sc-7czu T2: healthy 0 件 × stale が eligible → exit 0 のまま (A) error_code 内訳診断が出続ける" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$T2ONLY")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$2=="1"{print $1}' <<<"$output")" = "acctR" ]
  [[ "$stderr" == *"上流劣化"* ]]
  [[ "$stderr" == *"429=1"* ]]
  [[ "$stderr" == *"nologin=1"* ]]
  [[ "$stderr" == *"健全の証拠ではない"* ]]
  # ★sc-7czu self-review: 本 diff は healthy=0 のとき呼出元の挙動を「loud die」から「degraded account で
  #   続行」へ変える。その唯一の補償が本 warn なので、**件数込み**で pin する（従来の (A) 行だけを見る
  #   assertion では warn を丸ごと削除しても緑のままだった＝生存 mutant を実測）。
  [[ "$stderr" == *"適格 1 件はいずれも stale 復帰クラス"* ]]
  [[ "$stderr" == *"健全な候補は 0 件"* ]]
  [[ "$stderr" != *"selector 誤判定"* ]]     # 健全 0 件は (B) ではない
  [[ "$stderr" != *"origin=selector"* ]]     # exit 0 では監査ブロックを出さない（二重記録しない）
}

# ── sc-7czu T2-SPAWN ─────────────────────────────────────────────────────────
# inventory: invariant=healthy 0 件 × 復帰クラスのみの pool でも呼出元は die せず tier=1 を採用し、
#            その degraded 由来（demoted:stale(429)）と補償 warn（健全な候補は 0 件）が pane / 監査 note に残る
#          | polarity=positive(新 boot-path が silent にならない)
#          | mutant_fingerprint=selector :552-556 の `if elig_labels:` warn ブロック削除 → 「健全な候補は 0 件」
#            が消え RED / col10 の demoted: マーカー生成を落とす → 監査 note の assertion が RED
@test "sc-7czu T2-SPAWN: healthy 0 件 × 復帰クラスのみ → 呼出元は die せず採用し degraded 由来が監査に残る" {
  # ★sc-7czu self-review: 本 diff は呼出元の die 条件（eligible 行の有無）を素通しで変える＝復帰クラスが
  #   eligible=1 化した瞬間、admin/worker は snapshot cache 由来の古い残量で採点された stale account 上で
  #   起動する。selector 単体 tooth（T2）だけでは「呼出元がこの新経路をどう扱うか」が 1 本も pin されない
  #   ので、spawn 段でも留める（degraded-only pool 上の silent 起動を機械で検知できる状態にする）。
  : > "$NOTE_LOG"
  mk_cfg "$ABASE/acctR"
  run env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$T2ONLY")" SCRIBE_ACCOUNTS_BASE="$ABASE" \
    BEADS_BDW="$BDW_STUB" SCRIBE_SANDBOX=0 SCRIBE_CLD_SPAWN="$NOOP" \
    "$SPAWN" --repo "$ANCHOR" --anchor "$ANCHOR" --account auto zz-degraded-only
  [[ "$output" != *"適格アカウントが 0 件"* ]]          # (A) の die へ落ちない（＝新経路で続行する）
  [[ "$output" == *"健全な候補は 0 件"* ]]              # 補償 warn が pane まで届く（loud channel の実効性）
  local notes; notes="$(cat "$NOTE_LOG" 2>/dev/null || true)"
  [[ "$notes" == *"chosen=acctR"* ]]                    # 復帰クラスが実際に採用される
  [[ "$notes" == *"acctR|1|"* ]]
  [[ "$notes" == *"demoted:stale(429)"* ]]              # degraded 由来である旨が durable な監査に残る
  [[ "$notes" == *"acctD|0|"* ]]                        # 死亡アカは除外のまま snapshot に載る
}

# ── sc-7czu T-OPTIONAL ───────────────────────────────────────────────────────
# inventory: invariant=新 field(error_code/attempted/skip_reason/token_expires_at)を 1 つも持たない
#            旧版 claude-usage 出力でも従来と同一の出力（optional 扱いが崩れて必須キー化しない）
#          | polarity=negative(回帰網)
#          | mutant_fingerprint=`_SCORE_KEYS` へ "error_code" を追加 → good が malformed 除外され RED
#            （★`_UNIVERSAL_KEYS` への追加は**生存 mutant**＝当該定数は宣言のみで未参照。selector 側に
#              その旨の注記を入れた。実際に検査を増やす経路は _SCORE_KEYS だけなのでそちらを fingerprint
#              に採る）
@test "sc-7czu T-OPTIONAL: 新 field を 1 つも持たない入力でも従来と同一出力（必須キー化していない）" {
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$(cat "$LEGACY")" python3 "$SEL"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$2=="1"{print $1}' <<<"$output")" = "good" ]     # healthy は従来どおり適格
  [ "$(awk -F'\t' '$1=="old"{print $2}' <<<"$output")" = "0" ]      # 判定不能は従来どおり除外
  [ "$(grep -c 'malformed:' <<<"$output" || true)" -eq 0 ]          # pool 0 + 偽 shape-drift 警報にしない
  [[ "$stderr" != *"shape 契約変更"* ]]
}

# ── sc-7czu T-COL10 ──────────────────────────────────────────────────────────
# inventory: invariant=demoted と advisory が同時成立しても col10 は 1 セル（半角空白区切り・11 列目を作らない）
#          | polarity=positive
#          | mutant_fingerprint=区切りを "\t" にする → 列数が 11 になり本 tooth が RED
@test "sc-7czu T-COL10: demoted と枯渇 advisory の同時成立でも 10 列・半角空白区切り" {
  local both='{"accounts":[
    {"label":"h","ok":true,"stale":false,"five_hour_pct":0,"five_hour_resets_at":null,
     "seven_day_pct":0,"seven_day_resets_at":null},
    {"label":"sd","ok":false,"stale":true,"error":"HTTP 429","error_code":"429","attempted":true,
     "five_hour_pct":100,"five_hour_resets_at":"2026-07-08T15:00:00+00:00",
     "seven_day_pct":100,"seven_day_resets_at":"2026-07-14T00:00:00+00:00"}]}'
  run --separate-stderr env SCRIBE_USAGE_NOW="$NOW" SCRIBE_USAGE_JSON="$both" python3 "$SEL"
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '{print NF}' <<<"$output" | sort -u | paste -sd, -)" = "10" ]
  [ "$(awk -F'\t' '$1=="sd"{print $10}' <<<"$output")" = "demoted:stale(429) advisory:depleted(headroom=0)" ]
  # 既存の部分一致 assertion（advisory:depleted(headroom=0) / advisory:depleted）を壊さない順序。
  [[ "$output" == *"advisory:depleted(headroom=0)"* ]]
}

@test "sc-1rq: 出荷物 bash/python 構文（両 deliverable）" {
  run bash -n "$SPAWN"
  [ "$status" -eq 0 ]
  run python3 -c "import ast; ast.parse(open('$SEL').read())"
  [ "$status" -eq 0 ]
}

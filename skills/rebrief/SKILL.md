---
name: rebrief
description: |
  respawn / compaction 後の第一手として、rebrief DATA（WM主張↔bd現在値の乖離 / orphan WM / auto-compact 強制回復 mode /
  consumed 化対象）を機械層 fetch から取り込み、全体像（ゴール / 現在地 / 残りの塊 / user 手番）+
  判定根拠・推奨・次アクション・hygiene tripwire を定型 brief で提示し、
  current session の Working Memory を consumed 化する。
  機械層（fetch）= scripts/scribe-rebrief-fetch.sh が read-only で DATA を出し、判断（brief）と consume（mv）は本 skill が担う。
  cc-session(session plugin) の user-scope enable が前提（Working Memory の退避側＝/session:ready-compaction の対）。

  Use when user wants to: respawn 直後に作業状態を復元したい / compaction 後に何をしていたか思い出したい /
  Working Memory と bd の食い違いを洗いたい / 別 session の未 consumed WM を掃除したい,
  says 「rebrief」「復元して」「続きから」「respawn した」「compaction 後の再開」「作業状態を戻して」。
---

# scribe:rebrief Skill（respawn / compaction 後の復元 brief）

admin session を respawn した直後・compaction 後の再開時の**第一手**。退避した Working Memory（WM）と bd 台帳の
**現在値**を突合し、「何をしていたか」「WM の主張は今も正しいか」「取りこぼした session は無いか」を brief にして
提示する。全 scribe project（`.beads/` を持つ repo）で同じ形で使える。

> **対になる skill**: 退避側は cc-session の `/session:ready-compaction`（compaction 前に WM を外部化する）。
> 本 skill はその**復元側**。cc-session は project 同居ではなく **user-scope で enable** する plugin ゆえ、
> 本 skill を使う前に enable されている必要がある（WM の path 解決・2 節 schema の SSOT が cc-session の lib）。

## 機械 / LLM の分担（この skill が守る境界）

- **機械層 = `scripts/scribe-rebrief-fetch.sh`**（read-only・一切 write しない）: DATA を行頭 marker 付きで emit する。
  台帳 prefix は `.beads/metadata.json` の `dolt_database` を walk-up で**動的解決**するので、project 固有の設定は要らない。
- **LLM 層 = 本 skill**: DATA を突合して brief を組み、`consume`（`.md` → `.consumed.md` の **mv**）を実行する。
  **fetch は consume しない**——consume は「brief を人間に提示し終えた」ことを表す状態遷移ゆえ本 skill の責務。

## 手順

### 1. fetch を回す（read-only）

```
"${CLAUDE_PLUGIN_ROOT}/scripts/scribe-rebrief-fetch.sh"
```

cwd の repo（`.beads/` を持つ root へ walk-up）を anchor とし、その台帳・その `.claude-session/` を読む。
別 repo を対象にするなら `SCRIBE_REBRIEF_ANCHOR=<repo root>` を付ける。session id が env から解決できない場合は
`SCRIBE_REBRIEF_SID=<sid>` を渡す（未解決だと legacy 非 scoped WM を見に行き、current の WM を取り違える）。

> **respawn / `/clear` では 1 回目が `[WM] missing` になるのが正常**（WM は sid で scope されるのに、
> respawn は新プロセス・`/clear` は session_id 自体が変わるため、前 session の退避物と exact 一致しない）。
> **これを「退避物が無い」と読んではならない**——手順は下記 §2 の `[WM-CANDIDATE]` を参照。

**FATAL で落ちたら回避策を打たない**（fail-loud は仕様）。死に方と意味:

| stderr | 意味 | 対処 |
|---|---|---|
| 台帳 resolver 不在 | scribe の共有 lib が読めない（壊れた deploy） | plugin の配置を直す |
| anchor を解決できない | cwd が `.beads/` を持つ repo の外 | 対象 repo で実行するか `SCRIBE_REBRIEF_ANCHOR` を渡す |
| dolt_database を確定できない | anchor 直下の `.beads/metadata.json` が不在/壊れ | 台帳の metadata を直す（`/scribe:setup`） |
| cc-session lib 不在 | session plugin が user-scope で enable されていない | cc-session を enable する |
| cc-session lib の API（`extract_effort_directives`）不在 | lib は在るが版ずれ（**公開 API** が rename/移設） | cc-session を更新して再 enable する |
| bd read 失敗 | bd 不在 / dolt lock 競合 / 台帳破損 / JSON parse 不能 | bd と台帳の健全性を直す（**再実行前に**） |
| JSON parser 不在 | `jq` も `python3` も PATH に無い | どちらかを入れる（粗い近似 parse には落とさない＝捏造 DRIFT を出さないため） |
| WM / WM dir が読めない | `.claude-session/` や WM の所有権・権限ずれ（例: container root が書いた） | 権限/所有者を直す（`[ORPHAN-NONE]` が嘘になるため skip しない） |

> **非 FATAL degrade（意図的な非対称）**: 上表の「API 不在＝FATAL」は cc-session の **公開 API**
> （`extract_effort_directives`）に限る。計画弧（現在地）の抽出に使う `_wm_extract_section` は cc-session の
> **private 記号**ゆえ記号 gate に含めない——正当な内部 rename で fleet 全 admin の rebrief が boot path で
> brick するのを避けるため。不在時は `[WM-PLAN-UNAVAILABLE]` を出して **rc 0 で継続**（FATAL ではなく brief は出す）。
> この場合「現在地」は**判定不能扱い**とし `[BD-INPROGRESS]` / `[BD-COUNT]` で代替する。

いずれも「読めなかった／識別できなかった」を「**異常なし（乖離なし・BD-COUNT=0）**」に化けさせないための
死に方＝黙って skip しない。**FATAL のときは brief を出さない**——DATA が無いのに「やり残しなし」と要約するのが
この skill の最悪の失敗（respawn 直後の第一手ゆえ、偽の全クリアはそのまま作業放棄になる）。
FATAL の内容をそのまま報告し、原因を直してから再実行する。

### 2. DATA を読んで brief を組む（下記 俯瞰 + 4 節・この形を崩さない）

fetch の marker と、brief に落とす先の対応:

- `[REBRIEF-MODE] normal | force-recovery` … `force-recovery` は auto-compact marker 検出＝**WM の退避が間に合わなかった疑い**。
  この時は **WM の主張より bd の現在値を一次 truth** として brief を組む（WM は古い可能性が高い）。
- `[DIFF-DRIFT] / [DIFF-OK] / [DIFF-MENTION] / [DIFF-NONE] / [DIFF-COUNT]` … WM が主張する bead status と bd 現在値の突合。
  **DRIFT は「WM が古い」か「bd が未更新」のどちらか**であって、どちらが正かは fetch には判らない＝**ここが judgment**。
- `[DIFF-UNKNOWN]` … **突合していない**（current sid の WM が無い＝比べる主張が無い）。`[DIFF-NONE]` とは別物で、
  **「乖離なし」と読み替えてはならない**。respawn / `/clear` 直後はこれが既定の出力。
- `[WM-CANDIDATE] / [WM-CANDIDATE-NONE]` … current sid の WM が無いときに出る**復元候補**（未 consumed WM の
  mtime 降順＝先頭が最新）。**respawn / `/clear` の復元はここから始まる**（下記手順）。fetch には
  「sid が変わった自 session の退避物」か「別 session の残置」か **区別できない**ので、判断は自分（skill）が持つ。
- `[ORPHAN-WM] / [ORPHAN-NONE] / [ORPHAN-COUNT]` … 別 session（sid≠current）の未 consumed WM。
  **`.consumed.md` が併存していても orphan として出る**（consume は mv ゆえ plain `.md` の存在自体が未 consume の証拠。
  過去に 1 度 consume した痕跡は、その後の**再**外部化を打ち消さない）。
- `[WM] found|missing` / `[CONSUME-TARGET] / [CONSUME-NONE]` … current session の WM＝consume 対象。
- `[WM-PLAN] / [WM-PLAN-EMPTY] / [WM-PLAN-NONE] / [WM-PLAN-UNAVAILABLE] / [WM-PLAN-TRUNCATED]` …
  WM の「計画弧・次のステップ」節＝**「現在地」の一次データ**（4 値排他・1 回の実行で状態は 1 つだけ出る）。
  落とす先は §3 俯瞰の **現在地**（および「残りの塊」の補強）。
  - `[WM-PLAN] <本文 1 行>` … 本文は **1 行ごとに marker を前置**して出る（行頭に生の WM 本文を出さない＝
    実 WM には marker literal が実在するため、生 emit は消費側の行頭 marker 判定を汚染する）。
  - `[WM-PLAN-EMPTY] reason=section-absent-or-empty` … WM は在るが当該節が不在/空（テンプレ生成直後 /
    旧 3 節スキーマ）→ 現在地は **判定不能**（「やることなし」ではない）。
  - `[WM-PLAN-NONE]` … current sid の WM file 自体が不在 → §2-b の復元手順へ（候補 sid で再 fetch すれば実データになる）。
  - `[WM-PLAN-UNAVAILABLE]` … cc-session lib の抽出記号/定数が無い（版ずれ）。**FATAL ではない**（rc 0 で brief は出す）
    ＝現在地は判定不能扱いとし `[BD-INPROGRESS]` / `[BD-COUNT]` で代替する（§1 の非対称注記）。
  - `[WM-PLAN-TRUNCATED] shown=N total=M` … 20 行で切った合図（黙って切らない）。全文が要るなら WM を直接 Read する。
- `[BD-INPROGRESS] <id> updated=<ts> <title>` / `[BD-INPROGRESS-NONE]` / `[BD-INPROGRESS-SKIP] reason=<...>` …
  bd の in_progress の **id + 更新時刻 + title**（固定 arity 前置 + 自由文末尾＝title 内の空白で parse が壊れない順）。
  落とす先は §3 俯瞰の **現在地**（force-recovery では一次）と §3「次のアクション」（in_progress を優先する判断の実データ）。
  `-NONE` は**確認した上で 0 件**。`-SKIP` は「read は成功したが enrich できない」＝**`-NONE` と融合させず
  判定不能として扱う**（bd read の失敗自体は §1 の FATAL 側＝brief を出さない）。reason 値は 2 種:
  `reason=field-missing`（bd 版差で title / updated_at キーが無い）/ `reason=count-mismatch`（`[BD-COUNT]` の
  in_progress 件数と enrich 行数が合わない＝2 read 間の status 変化等。**多い側も信用しない**＝差分は判定不能）。

#### 2-b. `[WM] missing` + `[WM-CANDIDATE]` のとき（respawn / `/clear` の既定経路・**ここを飛ばさない**）

「WM が無い」ではなく「**current sid の名前では見つからない**」だけ。次の順で復元する:

1. 先頭（最新）の `[WM-CANDIDATE]` を **Read** する。内容（「計画弧」「命令・制約」節）が自分の直前の作業と
   整合するなら、それが respawn 前の自分の退避物。無関係なら次の候補を見る（並走 session の残置の可能性）。
2. 採用した候補の sid で **再 fetch** して bd と突合する（これで `[DIFF-*]` が実データになる）:

   ```
   SCRIBE_REBRIEF_SID=<候補の sid> "${CLAUDE_PLUGIN_ROOT}/scripts/scribe-rebrief-fetch.sh"
   ```

   `<候補の sid>` は `working-memory.<sid>.md` の `<sid>` 部分。再 fetch の `[DIFF-DRIFT]` を §3 の brief に載せる。
   **候補 sid で再 fetch すると `[WM-PLAN]` が実データになる＝§3 俯瞰「現在地」の一次ソースはここで得る**
   （1 回目は `[WM-PLAN-NONE]`＝まだ取得していない状態。ここを踏まずに「現在地: 判定不能」と書くのは禁止＝下記 §3 の手順ゲート）。
3. `[DIFF-UNKNOWN]` のまま brief を書かない。**`[DIFF-UNKNOWN]` を「乖離: なし」と要約するのは禁止**
   （§1 の「最悪の失敗」＝偽の全クリア）。候補を読んでも突合できなかったなら、その旨を brief に明記する。

`[WM-CANDIDATE-NONE]`（候補が 1 件も無い）なら、退避物自体が存在しない＝真に新規 session。この場合のみ
「復元すべき WM は無い」と要約してよい（ただし bd の in_progress は残るので §3 の「次のアクション」は出す）。

### 3. brief を出す（定型・俯瞰 + 4 節）

**本テンプレは fetch が rc 0 で DATA を出したときのみ適用**する（§1 の FATAL 時は brief を出さない＝DATA が無いのに
定型を埋めて「やり残しなし」を捏造しない）。

**俯瞰 4 slot の規律**（フェンス内テンプレ先頭の `## 全体像`・順序固定。規律はここ＝フェンス外に置く）:

- **4 slot の定義と順序**: ① **ゴール** = 今の effort が達成しようとしている状態（個別 bead ではなく effort 単位）
  → ② **現在地** = どこまで進んでいるか → ③ **残りの塊** = これから残っている作業の塊 → ④ **user 手番** =
  user の承認・裁定・入力を待っている項目。**この順序を入れ替えない**（「今どこにいるか」を掴む順序そのものが規約）。
- **現在地の MODE 別優先順位**: `normal` は `[WM-PLAN]` を**一次**とし `[BD-INPROGRESS]` / `[BD-COUNT]` で裏取りする。
  `force-recovery` は `[BD-INPROGRESS]` / `[BD-COUNT]` を**一次**とし、`[WM-PLAN]` は「**古い可能性のある参考**」
  としてのみ引用する（§2 の `[REBRIEF-MODE]` 規律と同一＝`docs/protocol.md` §9「強制回復モード」）。
- **3 値則（判定不能を 0 / なしと書かない）**: 各 slot は〔実データ〕〔`判定不能(理由)`〕〔`なし`〕の 3 値で書き分ける。
  DATA から決められないものを `0 件` / `なし` と書くのは §1 の「最悪の失敗」（偽の全クリア）と同型。
  `判定不能` を書いてよい条件は **DATA の状態で 2 分岐する**（どちらでも「理由」は必須）:
  - (i) **WM が取れていない**経路（`[WM-PLAN-NONE]` / `[DIFF-UNKNOWN]`）: **§2-b の復元手順（先頭候補の Read →
    採用候補の sid で再 fetch）を踏んだ後だけ**書いてよい。踏まずに `判定不能` で埋めるのは禁止
    （踏めば `[WM-PLAN]` が実データになる＝現在地の一次ソースはそこで得る）。
  - (ii) **WM は取れたが決められない**経路（`[WM-PLAN-EMPTY]` / `[WM-PLAN-UNAVAILABLE]`＝`[WM] found` ゆえ
    §2-b は適用不能）: その marker 自体が「取得した上で決められない」の一次証拠ゆえ手順は不要。
    **理由に marker 名を書く**（例: `判定不能(WM-PLAN-EMPTY: 計画弧節が空)`）。この経路で `なし` / `0 件` と
    書くのが禁止事項であって、`判定不能` は正しい答え。
  `[DIFF-UNKNOWN]` 固有の規律は §2 / §2-b が SSOT（本文をここへ複製しない）。
- **`user 手番` が 0 件のときは空欄にせず「なし」と明示する**（＝確認した上で 0 件。判定不能と弁別する）。
  判定条件を自前定義せず §4 の RULE-1（正規ケース＝自動 consume / 正規外＝人間へ確認）と §1 の FATAL 表を参照する。
  **バナー / 承認待ちは提示層の表示であり、§4 の consume 手順（正規ケースの自動 mv）を停止させない**。
- **承認バナー**: 「user 手番」に挙げた項目のうち **user の承認・裁定を実際に要するものが 1 件以上あるとき**に
  バナー / AskUserQuestion を立て、**承認不要の報告では立てない**（安売り禁止＝バナー出現が承認要求を含意する不変量）。
  発火条件・表示様式・在席分岐の SSOT は `docs/protocol.md` §5.4 と §7.2 であり、本 skill は独自条件を定義しない。
- **「残りの塊」は conditional-required**: 3 クラス分類等の**分類器 marker は canonical fetch が持たない**（層の fence＝
  orchestrator overlay の領分）ので、**既定は常に未分類経路**＝`[BD-COUNT]` の内訳をそのまま写した 1 行で可
  （**合算値を単独で書かない**）。`[BD-COUNT]` は open / in_progress / blocked の 3 値のみで bd の `deferred` を
  計上しないため、「残り総数」を名乗らず「**bd 現在値の内訳（deferred 等は未計上）**」と限定する。分類器 marker が
  DATA に在る層（overlay）で回す場合はその分類を写す。
- **長さ cap の適用範囲**: cap（俯瞰の各 slot 1 行）は **俯瞰 4 slot の表示にのみ**掛かる。`[DIFF-DRIFT]` 各件・
  `[ORPHAN-WM]` 各件の列挙義務には掛からず、cap を理由に省略・要約丸めしてはならない。
  **cap は提示層の書式規約であって思考量への cap ではない**。
- **平易さ**: 提示の平易さは各 host の user CLAUDE.md「言語・伝え方」節に従う（規約本文をここへ複製しない）。

```
## 全体像
- ゴール: <この effort が達成しようとしている状態／判定不能(理由)>
- 現在地: <どこまで進んでいるか（MODE 別の一次ソースは上記規律）／判定不能(理由)>
- 残りの塊: <残作業の塊。分類器が無ければ「bd 現在値の内訳（open=N in_progress=N blocked=N・deferred 等は未計上）」を写す>
- user 手番: <user の承認・裁定・入力を待つ項目／なし>

## 判定根拠
- MODE: <normal|force-recovery>（force-recovery なら「bd 一次 truth」と明記）
- WM: <found|missing→候補 sid=X を採用（respawn/clear）|missing かつ候補なし>（採用した WM の「命令・制約」節の要旨）
- bd 現在値: open=N in_progress=N blocked=N
- 乖離: <DIFF-DRIFT の各件を「WM=X / bd=Y」で列挙・**突合できた上で** 0 件なら「なし」。
  [DIFF-UNKNOWN] のままなら「なし」ではなく「**未突合**（理由）」と書く>

## 推奨
- 各 DRIFT について「WM が古い（bd に合わせる）」か「bd が未更新（bd を直す）」かの**判断と理由**。
- force-recovery のときは WM 主張を採用しない理由を 1 行で明示する。

## 次のアクション
- 直近で再開すべき作業を 1〜3 個（bd id 付き）。in_progress の bead を優先する（id / title / 更新時刻は [BD-INPROGRESS] を写す）。

## hygiene tripwire
- orphan WM が在れば列挙し「別 session が退避したまま復元されていない」ことを警告する（放置＝作業文脈の喪失）。
- 乖離が 3 件以上なら「WM と bd がドリフトしている＝退避か更新の運用が崩れている」と警告する。
```

### 4. consume する（brief 提示の**後**・この skill の唯一の write）

`[CONSUME-TARGET]` が出ていたら、提示し終えた後に mv する:

```
mv "<CONSUME-TARGET の左辺>" "<右辺（.consumed.md）>"
```

- **brief より前に consume しない**（提示前に mv すると、brief 生成が失敗したとき WM が宙に浮く）。
- **削除しない**（mv であることが仕様。次サイクルの `/session:ready-compaction` が consumed から
  「命令・制約」節を carry-forward するので、消すと effort を貫く命令が落ちる）。
- **orphan は自動で consume しない**——orphan は別 session の文脈ゆえ、内容を読んで引き継ぐか捨てるかは人間の判断。
  brief で surface するに留め、指示があったときだけ触る。
- **`[WM-CANDIDATE]` の Read は「触る」に当たらない**（read-only ゆえ §2-b は常に実行してよい）。
  候補の **consume（mv）は「正規ケースは確認せず自動 consume・正規外のみ人間へ確認」**（user 裁定 2026-07-19・RULE-1）:
  - **正規ケース（＝確認せず自動 consume）**: `[WM-CANDIDATE]` が**単一** ∧ その内容（「計画弧」「命令・制約」節）が
    自 session の直前作業と整合する（＝§2-b で読んで採用し brief に反映し終えた、自分の respawn / `/clear` 前の退避物）／
    または current-sid の WM そのもの（`[CONSUME-TARGET]`）。この 2 つは **reversible な mv**（消えても次サイクルの
    `/session:ready-compaction` が consumed から carry-forward で拾う）ゆえ routine な確認往復を省く。
  - **採用候補（sid≠current）の consume 先は current-sid 名義**（設計裁定 A・2026-08-03・bd sc-209c）:
    mv 先を `working-memory.<current-sid>.consumed.md` とし、**直後に frontmatter へ `consumed-from: <元 sid>` を
    1 行追記**する（provenance を落とさない）。次サイクルの `/session:ready-compaction` は **current-sid の
    consumed** を carry-forward の供給源に取るため、元 sid 名義のまま置くと上の「reversible」が成立せず
    命令・制約が無言で 0 項目化する。**裁定理由**: 供給側を mtime 降順で fallback 探索する案は、並走 session の
    consumed を掴む cross-contamination があるため劣後（退避側でなく consume 側の名義を正すのが本筋）。
    `[CONSUME-TARGET]`（current-sid の WM そのもの）経路と、下記 orphan の非自動 consume の安全弁は**不変**。
  - **正規外（＝surface して人間へ確認・ask 維持）**: 候補内容が直前作業と**不一致** / 曖昧な候補が**複数** /
    所有 session **不明** / 別 session の orphan が**混在** / `[DIFF-UNKNOWN]` のまま**未突合**。この時は consume せず
    brief に loud surface し、人間へ mv 先を提示して指示を仰ぐ。
  - **不変の安全弁**: `[ORPHAN-WM]`（別 session の残置・sid≠current）は**自動 consume しない**（上記 orphan バレットを維持）。
    候補は `[ORPHAN-WM]` にも同じ file が出るが fetch は両者を区別できない（役割が違うだけで矛盾ではない）
    ＝正規ケースの自動 consume は「自 session の退避物と確認できた単一候補」に限る。

## この skill がしないこと（層の fence）

- **auto-compact marker の write / hook 新設**はしない（fetch は marker の有無を**判定するだけ**）。
- **orchestrator overlay**（配送観測・STALE 停滞 scan・clean-state-probe の GREEN gate・gate-pending 列挙）は
  持たない。それらは上位層が自分で compose する（本 skill は generic core の 4 要素に限定）。
- **bd を write しない**（status を直すのは判断した人間 / admin の仕事＝brief は推奨するに留める）。

→ 機械層の env seam・marker 仕様・orphan 規則の SSOT は `scripts/scribe-rebrief-fetch.sh` の header。

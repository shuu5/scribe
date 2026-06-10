# scribe

**scribe = per-project・Claude Code ネイティブの「実装 administrator（ユーザー代理 AI）」プラグイン。**

人間は「要望を出す」だけ。それ以外の段取り・分割・セッション制御・跨ぎメタ認知（spawn / 監視 / gate / errata / マージ判断 / 跨セッション・跨 compaction の記憶保持）を administrator が代理する。

> ⚠️ `thesis-scribe`（論文プロジェクト）とは**無関係の別物**。旧「scribe = 論文執筆層」の定義は破棄済み（設計 SSOT 冒頭参照）。

---

## 3 層スタックでの位置 — scribe は orchestration 層

scribe は自前で重い機構を持たず、既存の standalone な substrate を **compose する側**である（scribe-design.md §3「A 案で確定」）。

```
┌─ implementation（溶ける層）── worker = cc-session セッション + persona prompt + (v1+)folio in-loop gate
│
├─ orchestration（★ scribe = 作る対象）──────────────────────────────────────────
│    substrate を compose し worker を spawn / observe / comm、beads でタスク、
│    doobidoo で知識、(v1+)folio spec を anchor。
│    = session-orchestration-strategy.md の "Supervisor パターン" の製品化。
│
└─ substrate（既存・standalone・compose される側）────────────────────────────────
     • cc-session : spawn / fork / session-comm(操舵注入) / session-state / window-manifest
                    + ready-compaction + enforce。「常駐監視・マルチウィンドウ統括は範囲外」
                    と README で明記 → administrator はこの上に乗る別物。
     • beads      : per-project タスク台帳（live なタスク共有ボード）。tasks=bd / knowledge=doobidoo。
     • doobidoo   : 知識ストア。
     • folio      : (v1+) Layer0 spec 著作 + in-loop spec-gate hooks。v0 では未使用。
```

**「作る」プラグインは scribe 1 枚だけ。** 実装層（旧 phaser/worker）は first-class plugin にせず、persona prompt + dynamic-workflow テンプレ + (v1+)folio gate に「溶ける」。cc-session / beads / doobidoo / folio は compose する substrate。

---

## v0 スコープ — 堀なし軽量モード

v0 は最終形（scribe-design.md §1〜§13: 堀 ON・folio backend・自動判断層・背景 supervisor）のうち、§14 が定義する薄い切り出しだけを作る。**堀（in-loop hook 強制の spec 順守）は v0 では意識的に OFF**（§5 graceful degradation の軽量モード = scribe 内蔵 backend・docs 一枚・provenance/署名なし）。intent drift のリスクは着手速度のために意識的に受容し、Gate β 相当の準拠検証は手動レビュー（adversarial review + cell-quality gate）で回す。

### v0 で作る 3 本柱（scribe-design.md §14）

1. **手動 admin プロトコルの成文化** → `docs/protocol.md`（本セルで作成）。
   2026-06-10 Wave1+2 の 10 PR で実証済みの手順（spawn 規約 / worker prompt 規約 / B/hybrid 役割境界 / close→gate→errata / gate funnel / 監視）を plugin docs に同梱して **規約 SSOT** 化。project CLAUDE.md は本文重複を持たずポインタへ縮小（縮小自体は別 cell = C4）。
2. **道具（`scripts/`）** → spawn ヘルパー / gate 起動ヘルパー / cleanup。**C3(bd un-4nm)で実装**。
3. **role 判定つき SessionStart 文脈注入（3 role）** → admin / worker / consult。**C2(bd un-ck2)で実装**。内容仕様は `docs/role-context-spec.md`（本セルで作成）。

### v0 で作らないもの（v1+ へ後回し）

- 判断層の自動化（findings 直読・merge 確認等の gate 判断は admin の手動のまま）
- 背景 supervisor（§10(b)。v0 は admin が手動監視）
- 堀（in-loop hook 強制の folio-spec 順守。§2）
- folio backend（§5。v0 は scribe 内蔵 backend のみ）

---

## ディレクトリ構成

| パス | 役割 | v0 の状態 |
|---|---|---|
| `.claude-plugin/plugin.json` | plugin マニフェスト（name=scribe / version 0.1.0） | ✅ 本セル |
| `hooks/hooks.json` | SessionStart wire 雛形（安全形・no-op until C2） | ✅ 本セル（中身は C2） |
| `skills/` | administrator / consult skill | placeholder（後続 cell） |
| `scripts/` | 道具（spawn/gate/cleanup）+ hook script | placeholder（C2/C3） |
| `docs/scribe-design.md` | 設計 SSOT（ubuntu-note-system からコピー・出所注記付き） | ✅ 本セル |
| `docs/protocol.md` | **手動プロトコルの成文化 = 規約 SSOT** | ✅ 本セル |
| `docs/role-context-spec.md` | 3 role 注入の内容仕様（C2 への引き渡し） | ✅ 本セル |

---

## 配布

本リポは将来 `claude/plugins/scribe` symlink で全ホストへ配布される（**C4 = bd un-0c6**・session/folio と同型）。GitHub remote は admin が gate 後に作成する（本 bootstrap セルはローカル commit まで）。

## 出所（一次 SSOT）

- 設計: `docs/scribe-design.md` §17（doobidoo `13447a54` ほか）/ bd un-3v9・un-5ez・un-it7（v0 実装 epic）
- 手動プロトコルの実証: doobidoo `ac9022d8`(Wave1) / `3b838167`(Wave2) / un-8q5 pilot・bd un-3v9 notes → `docs/protocol.md` 参照

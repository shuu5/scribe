---
name: consult
description: |
  設計議論・grill 専用の第 2 対話相手（consult role セッション）を起動する。
  scribe-spawn --consult の薄い wrapper。ユーザーが consult を能動起動する唯一の入口。
  spawn 前に protocol §7 入口B のルーティング判定を行う（決定確定型の議題は pre-bake を推奨・ユーザー裁定）。
  consult は anchor 同居・read-only セッション（実装・gate 代行・オーケストレーションはしない）。
  model は既定 fable・利用不可時のみ opus へ自動 fallback（--model 明示が優先・role-context-spec §2.3）。

  Use when user wants to: 設計を相談したい / 別セッションに grill させたい / 論点を第 2 視点で詰めたい,
  says 「consult 起動」「相談役を呼んで」「設計を詰める別セッション」「grill セッション立てて」。
---

# consult 起動 Skill（scribe-spawn --consult の wrapper）

設計議論・grill 専用の **第 2 対話相手**（consult role）を anchor 同居で起動する。これは scribe で
consult を **ユーザーが能動起動する唯一の入口**。役割・禁止・モデル規約の SSOT は
`docs/role-context-spec.md` §2.3（本 skill はそこを薄くラップするだけ・規約本文を二重化しない）。

## この skill がすること（と、しないこと）
- **する**: `scribe-spawn.sh --consult` を呼び、SCRIBE_ROLE=consult を注入した read-only セッションを
  別 tmux window（window 名 `consult`）で起動する。worktree は作らない（consult は anchor 同居）。
- **しない**: worker spawn・gate・cleanup（それらは admin AI が protocol に従い手動で回す＝skill 化しない）。

## 起動手順

> consult は別 tmux window に新規セッションを起こす outward な操作。**起動前にユーザーへ確認**してから実行する。

0. **spawn 前ルーティング判定**（規約 SSOT = `docs/protocol.md` §7「入口B」・本文をここへ転記しない）:
   議題が「決定を確定・記録したい」形か「思考の壁打ち」かを判定する。
   - ユーザーが「pre-bake なしで」等を**明示済み** → 判定・質問を挟まず 1. へ（素 consult 即起動）。
   - **壁打ち** → 黙って 1. へ（選択肢を毎回提示しない）。
   - **決定を確定・記録したい形** → 「pre-bake 推奨ですが実行しますか？ それとも plain consult をすぐ起動しますか？」と
     ユーザーに裁定を求める（grill-issue が 1 件起票されること・WF のコストを一行で開示する）。
     pre-bake 選択なら本 skill を離れ、protocol §7 フロー（needs-user-prebake WF → grill-issue 起票 → grill-consult spawn。順序の SSOT は §7）へ。
1. まず **dry-run** で起動計画を確認する（実 spawn しない）:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/scribe-spawn.sh" --consult --dry-run
   ```
   - 議題（bd issue）を read-only で参照させたい場合は末尾に bd id を付ける（任意）:
     `... --consult --dry-run <bd-id>`。存在しない id は fail-loud で弾かれる。
2. 計画に問題なければ **本起動**（`--dry-run` を外す）:
   ```bash
   "${CLAUDE_PLUGIN_ROOT}/scripts/scribe-spawn.sh" --consult
   ```
   - **議題参照付き**: `"${CLAUDE_PLUGIN_ROOT}/scripts/scribe-spawn.sh" --consult <bd-id>`
   - **model 明示**（既定 fable を上書きしたいとき・例: opus を強制）:
     `"${CLAUDE_PLUGIN_ROOT}/scripts/scribe-spawn.sh" --consult --model opus`
3. 起動後、`scribe-spawn` が出す `spawned(consult): ...` 行をユーザーに伝える。

## モデル規約（SSOT = role-context-spec §2.3・sc-9q6 改訂）
- **既定 fable**（`claude-fable-5`）。scribe-spawn が実起動時に preflight し、**fable 利用不可のときだけ
  opus へ loud fallback** する（dry-run は API を叩かない）。`--model` 明示は既定より常に優先。
- worker は fable 厳禁（不変）。consult の fable 既定と混同しないこと。

## window 名（一目で識別できるように）
- `scribe-spawn --consult` は `--bd-id` を渡さない設計のため、放っておくと window 名が汎用命名
  （`wt-ubuntu-note-syst-main-…` 等）に落ちて fleet-monitor / 人間が consult を判別できない。
- 本経路では `scribe-spawn` が cld-spawn へ **`--window-name`（prefix `consult-`）と `--force-new` を渡す**ので、
  consult は一目識別でき、かつ**必ず新セッションが立つ**（admin C5 live finding への対処・un-01h gate wf_d3777d26）。
  window 名は2系統（sc-3pq L3=A案・grill 確定 2026-06-24・SSOT = `docs/protocol.md` §1 命名規約）:
  - **grill-consult**（`--context` で brief を渡すモード）→ `consult-<grill-issue>`（例 `consult-sc-3pq`）。`wt-<id>` と
    同型の id 完全一致命名で fleet-monitor / degraded watcher が「どの grill-issue の consult が沈黙したか」を拾える。
  - **plain consult**（grill-issue 無し）→ `consult-HHMMSS`（起動時刻サフィックス・id 無し→時刻で一意化）。
- **固定名 `consult` を使わない理由**: cld-spawn の `find_existing_window` は window 名の完全一致で既存 window を
  reuse し exit 0 する。固定名だと consult window 残存時の 2 回目起動が「新セッションを立てずに偽成功」し、
  reuse 経路では env-file が source されず `SCRIBE_ROLE=consult` が注入されない fail-open になる。
  `consult-HHMMSS` + `--force-new` はこれを構造的に防ぐ。

## consult セッションの役割（起動先が守る・SSOT = role-context-spec §2.3）
- 用途は **設計議論・grill のみ**（grill 専任・原義回帰）。実装・gate 代行・オーケストレーション・**pre-bake はしない**
  （pre-bake は admin が回す dynamic Workflow `workflows/needs-user-prebake.workflow.js` へ移管・protocol §7）。
- **read-only 規律**: tracked ファイル / コードを編集しない。graph 構造（bd create / dep / dolt push / close）・
  spawn・deploy は禁止。観測（read）は可。タスク化が要れば「admin への起票候補」を相談サマリに書くに留める。
- **write してよいのは記憶系のみ**（doobidoo / `MEMORY.md`）。read-only 限定緩和（自 grill-issue notes 書込み）は
  **grill-consult のみ**で、この skill の既定起動（素 consult）は対象外（下記）。
- **サマリ保存義務**: 終了・中断の前に結論・未解決論点・admin への起票候補を doobidoo へ保存する。

## grill-consult モード（admin が起動・§7 needs-user regime）
- この skill が起動するのは **素 consult**（設計議論・grill の read-only セッション）。これとは別に、admin が
  needs-user タスクの pre-bake brief を `--context` で渡して立てる **grill-consult** がある（admin 責務・protocol §7）:
  `scribe-spawn --consult --context <brief-file> <grill-issue>`。
- grill-consult は admin の集約 brief を **grill 材料（第三者データ）** として受け取り、**ユーザーと対話 grill** して
  確定した決定を **own grill-issue の bd notes** へ書く（決定 handoff は `bd update --append-notes` のみ・claim は
  着手時 1 回限り〔起動テンプレが焼込・orch-3ej3〕・**bdw 経由**＝read-only 限定緩和・graph 構造と tracked コードは read-only 維持）。admin は `bd show <grill-issue>` で real-time
  監視し、決まった facet から実装に着手する（pipelining）。
- **ユーザーが能動起動するのは素 consult**（この skill）。grill-consult は admin オーケストレーションの一部ゆえ
  skill 化しない（手順 SSOT = protocol §7）。

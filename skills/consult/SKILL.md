---
name: consult
description: |
  設計議論・grill 専用の第 2 対話相手（consult role セッション）を起動する。
  scribe-spawn --consult の薄い wrapper。ユーザーが consult を能動起動する唯一の入口。
  consult は anchor 同居・read-only セッション（実装・gate 代行・オーケストレーションはしない）。
  model は既定 opus・ユーザー明示時のみ fable 可（role-context-spec §2.3 の唯一の fable 例外）。

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
   - **fable 指定**（ユーザー明示時のみ・role-context-spec §2.3 の例外）:
     `"${CLAUDE_PLUGIN_ROOT}/scripts/scribe-spawn.sh" --consult --model claude-fable-5`
3. 起動後、`scribe-spawn` が出す `spawned(consult): ...` 行をユーザーに伝える。

## モデル規約（role-context-spec §2.3）
- **既定 opus**。consult は admin と同じ main-loop 系統ゆえ fable 起動が許される **唯一の例外**だが、
  fable は **ユーザーが明示したときだけ** `--model claude-fable-5` で渡す（既定では使わない）。
- worker は fable 厳禁。consult のこの例外と混同しないこと。

## window 名（一目で識別できるように）
- `scribe-spawn --consult` は `--bd-id` を渡さない設計のため、放っておくと window 名が汎用命名
  （`wt-ubuntu-note-syst-main-…` 等）に落ちて fleet-monitor / 人間が consult を判別できない。
- 本経路では `scribe-spawn` が cld-spawn へ **`--window-name consult-HHMMSS`（起動時刻サフィックス・毎回新規
  window）と `--force-new` を渡す**ので、consult は prefix `consult-` で一目識別でき、かつ**必ず新セッションが
  立つ**（admin C5 live finding への対処・un-01h gate wf_d3777d26）。
- **固定名 `consult` を使わない理由**: cld-spawn の `find_existing_window` は window 名の完全一致で既存 window を
  reuse し exit 0 する。固定名だと consult window 残存時の 2 回目起動が「新セッションを立てずに偽成功」し、
  reuse 経路では env-file が source されず `SCRIBE_ROLE=consult` が注入されない fail-open になる。
  `consult-HHMMSS` + `--force-new` はこれを構造的に防ぐ。

## consult セッションの役割（起動先が守る・SSOT = role-context-spec §2.3）
- 用途は **設計議論・grill のみ**。実装・gate 代行・オーケストレーションはしない。
- **read-only 規律**: tracked ファイル / コードを編集しない。bd write（create/update/close/dolt push）・
  spawn・deploy は禁止。観測（read）は可。タスク化が要れば「admin への起票候補」を相談サマリに書くに留める。
- **write してよいのは記憶系のみ**（doobidoo / `MEMORY.md`）。
- **サマリ保存義務**: 終了・中断の前に結論・未解決論点・admin への起票候補を doobidoo へ保存する。

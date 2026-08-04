#!/usr/bin/env bats
# background fan-out 禁止条項（sc-f6sw / folio-f060 incident の恒久化）の teeth。
#
# 何を pin するか:
#   (1) scripts/scribe-spawn.sh の build_prompt が生成する worker prompt に、禁止面 literal が
#       **無条件に**（SCRIBE_SANDBOX 既定 on / SCRIBE_SANDBOX=0 の両モードで）1 物理行として載る。
#   (2) 同一条項が carve-out 面（Workflow tool への委譲＝正規経路）を含む＝過広化していない。
#   (3) docs/protocol.md §2 の codify literal が在る。
#   (4) 変異対照: 条項行を削った複製で (1) が RED へ flip する（負条件 grep 単独では条項ゼロの
#       状態でも green になるため、正条件 + 変異対照の 2 本組で teeth の効きを実証する）。
#
# 観測面は **--dry-run の stdout**（生成 prompt の実出力）であってソース file の grep ではない
# （source grep は条件節・コメント内の literal でも hit するため false-green を許す）。
# dry-run 出力は各行に `         | ` が前置されるため、^ アンカーの正規表現・複数行 literal は
# 使わず grep -F の部分一致で照合する。条項 literal はハイフン始まりゆえ grep には必ず -e を付ける。
# 出力は必ず変数へ確定してから herestring で照合する（`producer | grep -q` は pipefail 下の
# SIGPIPE で rc=141 の偽 RED を生む・dry-run 出力は 15KB 級）。
#
# 実 spawn は起こさない（--dry-run は emit_plan 後に exit 0 する＝worktree 作成・env-file・
# bd notes write を一切行わない）。bd は fixtures/bd-stub.sh、usage コマンドは不在パスで殺す。

bats_require_minimum_version 1.5.0

# 条項 literal（admin が byte 確定・bd sc-f6sw notes ■F2）。1 byte も変えない。
BAN_LIT='- **background fan-out 禁止（folio-f060 incident の恒久化・sc-f6sw）**: 検証 suite 等を background shell（Bash tool の run_in_background / & / nohup / disown）で多数並走させる fan-out を禁止する。'
CARVEOUT_LIT='WF 骨格（Workflow tool）へ委譲'
BLOCKING_LIT='長時間処理の完了待ちは**単一の blocking 実行**に限る。'
DOC_LIT='- **background fan-out 禁止（sc-f6sw）**: worker prompt は「検証 suite 等を background shell で多数並走させる fan-out の禁止 / 完了待ちは単一の blocking 実行 / 並列は WF 骨格（Workflow tool）へ委譲＝正規経路（cell-quality WF の直接呼出は対象外）」を 1 条項として焼く。carrier は scripts/scribe-spawn.sh の build_prompt。'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS="$REPO_ROOT/scripts"
  SPAWN="$SCRIPTS/scribe-spawn.sh"
  # hermetic 化: ホスト env の漏れを落とす（account 解決・transport・plugin-dir が host 依存にならないように）。
  unset CLAUDE_CONFIG_DIR SCRIBE_WORKER_CONFIG_DIR SCRIBE_ACCOUNTS_BASE SCRIBE_TRANSPORT \
        SCRIBE_BG_PREFLIGHT SCRIBE_CLAUDE_BIN SCRIBE_PLUGIN_DIR SCRIBE_SANDBOX 2>/dev/null || true
  export SCRIBE_BD="$REPO_ROOT/tests/fixtures/bd-stub.sh"
  export BD_STUB_OK_IDS="un-4nm"
  export SCRIBE_HHMMSS=101010
  export SCRIBE_CLD_SPAWN="cld-spawn"          # dry-run では起動されない
  # 既定 account=auto が live claude-usage を叩くのを殺す（不在パス → API 故障 → 主アカ fallback）。
  export SCRIBE_USAGE_CMD="$BATS_TEST_TMPDIR/no-usage-cmd"
  # 安定 main worktree（temp git repo）を --repo/--anchor に渡す（linked worktree からの die を避ける・cwd 非依存）。
  REPO="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$REPO" -c init.defaultBranch=main init -q
  git -C "$REPO" config user.email t@e; git -C "$REPO" config user.name t
  git -C "$REPO" commit -q --allow-empty -m init
}

teardown() {
  [[ -n "${REPO:-}" ]] && rm -rf "$REPO"
  return 0
}

# dry-run 出力を stdout だけ確定して返す（stderr の account fallback 警告は落とす）。
_dry_run_prompt() {  # $@ = 追加 env 代入（例: SCRIBE_SANDBOX=0）
  env "$@" bash "$SPAWN" --repo "$REPO" --anchor "$REPO" --dry-run un-4nm 2>/dev/null
}

@test "fanout(1): dry-run prompt に禁止面 literal が載る（SCRIBE_SANDBOX 既定 on）" {
  local out
  out="$(_dry_run_prompt)"
  [ -n "$out" ]
  grep -qF -e "$BAN_LIT" <<<"$out"
  grep -qF -e "$BLOCKING_LIT" <<<"$out"
}

@test "fanout(2): SCRIBE_SANDBOX=0 でも同一 literal が載る（条件節 emit の構造的排除）" {
  local out
  out="$(_dry_run_prompt SCRIBE_SANDBOX=0)"
  [ -n "$out" ]
  grep -qF -e "$BAN_LIT" <<<"$out"
  grep -qF -e "$BLOCKING_LIT" <<<"$out"
}

@test "fanout(3): carve-out literal（WF 骨格への委譲＝正規経路）が両モードで載り、cell-quality WF 必須呼出 bullet が非破壊" {
  local on off
  on="$(_dry_run_prompt)"
  off="$(_dry_run_prompt SCRIBE_SANDBOX=0)"
  grep -qF -e "$CARVEOUT_LIT" <<<"$on"
  grep -qF -e "$CARVEOUT_LIT" <<<"$off"
  # 過広化封鎖: cell-quality WF の直接呼出が対象外である旨が同一条項内にある。
  grep -qF -e 'cell-quality WF の直接呼出はこの禁止に当たらない' <<<"$on"
  # 既存の cell-quality WF 必須呼出 bullet を割っていない（条項追加が自己矛盾を生んでいないことの pin）。
  grep -qF -e '**cell-quality WF を直接呼出**' <<<"$on"
}

@test "fanout(4): docs/protocol.md §2 に codify literal が在る（carrier ポインタ付き）" {
  grep -qF -e "$DOC_LIT" -- "$REPO_ROOT/docs/protocol.md"
  # boot core 区間の外＝§2 本体に置かれている（core へ書き足すと全 worker session の u16 予算を割る）。
  local core_end doc_line
  core_end="$(grep -nF -e 'scribe-core-worker:end' -- "$REPO_ROOT/docs/protocol.md" | head -n1 | cut -d: -f1)"
  doc_line="$(grep -nF -e "$DOC_LIT" -- "$REPO_ROOT/docs/protocol.md" | head -n1 | cut -d: -f1)"
  [ -n "$core_end" ] && [ -n "$doc_line" ]
  [ "$doc_line" -gt "$core_end" ]
}

@test "fanout(5): 変異対照 — 条項行を削った複製では (1) の assert が RED へ flip する（起動失敗による偽 RED でない）" {
  # scripts/ を丸ごと複製（lib/ 同梱＝SCRIPT_DIR 依存を満たす）。単一 file だけ cp すると lib 不在で
  # die し「0 hit が起動失敗のため」になって証拠力がゼロになる。原本と git 履歴は汚さない。
  local mut="$BATS_TEST_TMPDIR/mutant"
  mkdir -p "$mut"
  cp -a "$SCRIPTS" "$mut/scripts"
  local mut_spawn="$mut/scripts/scribe-spawn.sh"
  # 条項行（1 物理行）だけを削除する。
  grep -vF -e 'background fan-out 禁止（folio-f060 incident の恒久化・sc-f6sw）' -- "$mut_spawn" > "$mut_spawn.tmp"
  mv "$mut_spawn.tmp" "$mut_spawn"
  chmod +x "$mut_spawn"

  # (i) 変異版 dry-run は rc=0 で prompt 本文を復元できる（＝起動は成功している）。
  local mout rc
  mout="$(env SCRIBE_BD="$SCRIBE_BD" BD_STUB_OK_IDS="$BD_STUB_OK_IDS" SCRIBE_HHMMSS=101010 \
    SCRIBE_CLD_SPAWN=cld-spawn SCRIBE_USAGE_CMD="$SCRIBE_USAGE_CMD" \
    bash "$mut_spawn" --repo "$REPO" --anchor "$REPO" --dry-run un-4nm 2>/dev/null)" && rc=0 || rc=$?
  [ "$rc" -eq 0 ]
  [ -n "$mout" ]
  # 起動成功の positive control: 条項以外の prompt 本文（既存 pin 済み bullet）は復元できている。
  grep -qF -e '**cell-quality WF を直接呼出**' <<<"$mout"

  # (ii) その本文で当該 literal が 0 hit（＝(1) の assert が RED へ flip する）。
  run grep -qF -e "$BAN_LIT" <<<"$mout"
  [ "$status" -ne 0 ]
  run grep -qF -e "$CARVEOUT_LIT" <<<"$mout"
  [ "$status" -ne 0 ]
}

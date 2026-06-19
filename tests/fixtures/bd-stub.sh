#!/usr/bin/env bash
# bd-stub.sh — テスト用 bd スタブ。実 bd/実 graph を使わず bd id の実在検証を再現する。
#   `bd show <id>` のみ実装: $BD_STUB_OK_IDS（空白区切り）に含まれる id は exit 0 + 偽 description、
#   それ以外は exit 1（issue not found）。SCRIBE_BD でこのスタブを差し込んでテストする。
#   $BD_STUB_EMPTY_IDS（空白区切り）に含まれる id は **exit 0 だが本文が空**（実在検証は通すが
#   `bd show` 捕捉が空＝取得不可 fallback を踏ませる・sc-2m0 facet2 の sentinel 枝テスト用）。
set -euo pipefail
sub="${1:-}"
id="${2:-}"
ok="${BD_STUB_OK_IDS:-un-good un-4nm un-consult un-3sh.3.5}"
empty="${BD_STUB_EMPTY_IDS:-}"
case "$sub" in
  show)
    for k in $empty; do
      # 実在検証（exit 0）は通すが本文は空に保つ＝合成側の「DESC 空→sentinel」fallback を踏ませる。
      [[ "$id" == "$k" ]] && exit 0
    done
    for k in $ok; do
      if [[ "$id" == "$k" ]]; then
        printf '○ %s · stub issue\n\nDESCRIPTION\nstub description for %s\n' "$id" "$id"
        exit 0
      fi
    done
    echo "Error: issue not found: $id" >&2
    exit 1
    ;;
  *)
    echo "bd-stub: unsupported subcommand: $sub" >&2
    exit 2
    ;;
esac

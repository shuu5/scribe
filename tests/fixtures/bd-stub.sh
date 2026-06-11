#!/usr/bin/env bash
# bd-stub.sh — テスト用 bd スタブ。実 bd/実 graph を使わず bd id の実在検証を再現する。
#   `bd show <id>` のみ実装: $BD_STUB_OK_IDS（空白区切り）に含まれる id は exit 0 + 偽 description、
#   それ以外は exit 1（issue not found）。SCRIBE_BD でこのスタブを差し込んでテストする。
set -euo pipefail
sub="${1:-}"
id="${2:-}"
ok="${BD_STUB_OK_IDS:-un-good un-4nm un-consult un-3sh.3.5}"
case "$sub" in
  show)
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

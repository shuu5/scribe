#!/usr/bin/env bats
# scribe-publish-freshness.sh（sc-e93 / Plan A）の advisory 鮮度 lint を検証する。
# **実 bd/実 bdw は使わない**（inline スタブのみ）。道具の規約 SSOT = docs/protocol.md §5/§8。

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FRESH="$REPO_ROOT/scripts/scribe-publish-freshness.sh"
  STUB_DIR="$BATS_TEST_TMPDIR"
}

# bd スタブを生成する: list --label ... --json は $1_json（引数で渡す全 bead JSON）を返し、
# show <id> --json は $STUB_DIR/show-<id>.json を返す。show <id>（--json 無し・実在検証）は
# ファイルが在れば exit 0 / 無ければ exit 1。
_make_bd_stub() {
  local list_json="$1"
  local stub="$STUB_DIR/bd-stub.sh"
  cat > "$stub" <<STUB
#!/usr/bin/env bash
sub="\$1"
case "\$sub" in
  list) printf '%s' '$list_json' ;;
  show)
    id="\$2"; json_flag="\${3:-}"
    f="$STUB_DIR/show-\$id.json"
    [[ -f "\$f" ]] || exit 1
    [[ "\$json_flag" == "--json" ]] && cat "\$f"
    exit 0 ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$stub"
  printf '%s' "$stub"
}

_set_bead() {  # <id> <updated_at> <notes> <labels-json>
  cat > "$STUB_DIR/show-$1.json" <<JSON
[{"id":"$1","updated_at":"$2","notes":"$3","labels":$4}]
JSON
}

@test "publish-freshness: --help は Usage を出して exit 0" {
  run "$FRESH" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"mark-published"* ]]
  [[ "$output" == *"advisory"* ]]
}

@test "publish-freshness: federate-publish bead が 0 件なら 0 beads で exit 0" {
  local bd; bd="$(_make_bd_stub '[]')"
  run env SCRIBE_BD="$bd" "$FRESH" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 beads"* ]]
}

@test "publish-freshness: fresh / DRIFT / unpublished を正しく分類する" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-f"},{"id":"sc-d"},{"id":"sc-u"}]')"
  _set_bead sc-f "2026-07-02T10:00:03Z" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  _set_bead sc-d "2026-07-02T12:00:00Z" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  _set_bead sc-u "2026-07-02T09:00:00Z" "labeled but never marked" '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" check
  [ "$status" -eq 0 ]           # 既定は findings があっても exit 0（非block）
  [[ "$output" == *"[fresh]"*"sc-f"* ]]
  [[ "$output" == *"[DRIFT]"*"sc-d"* ]]
  [[ "$output" == *"[unpublished]"*"sc-u"* ]]
  [[ "$output" == *"fresh=1 drift=1 unpublished=1"* ]]
}

@test "publish-freshness: 既定は drift があっても exit 0（advisory・非block）" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-d"}]')"
  _set_bead sc-d "2026-07-02T12:00:00Z" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRIFT]"* ]]
}

@test "publish-freshness: --strict は findings があると exit 3" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-d"}]')"
  _set_bead sc-d "2026-07-02T12:00:00Z" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" --strict check
  [ "$status" -eq 3 ]
}

@test "publish-freshness: --strict でも findings 0 なら exit 0" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-f"}]')"
  _set_bead sc-f "2026-07-02T10:00:01Z" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" --strict
  [ "$status" -eq 0 ]
}

@test "publish-freshness: GRACE で drift 境界が動く（marker 自己 bump を吸収）" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-b"}]')"
  # delta=30s。既定 grace5 では DRIFT だが grace60 では fresh。
  _set_bead sc-b "2026-07-02T10:00:30Z" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" check
  [[ "$output" == *"[DRIFT]"* ]]
  run env SCRIBE_BD="$bd" SCRIBE_PUBLISH_FRESHNESS_GRACE=60 "$FRESH" check
  [[ "$output" == *"[fresh]"* ]]
}

@test "publish-freshness: marker 複数なら末尾（最新の再 publish）が勝つ" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-re"}]')"
  _set_bead sc-re "2026-07-02T10:00:02Z" \
    "federate-published-at: 2026-07-02T08:00:00Z\nedited\nfederate-published-at: 2026-07-02T10:00:00Z" \
    '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" check
  [[ "$output" == *"[fresh]"*"sc-re"* ]]
  [[ "$output" == *"published=2026-07-02T10:00:00Z"* ]]
}

@test "publish-freshness: timestamp 解釈不可は unknown 扱い（fail-loud しない）" {
  local bd; bd="$(_make_bd_stub '[{"id":"sc-x"}]')"
  _set_bead sc-x "not-a-timestamp" "federate-published-at: 2026-07-02T10:00:00Z" '["federate-publish"]'
  run env SCRIBE_BD="$bd" "$FRESH" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"[unknown]"*"sc-x"* ]]
}

@test "publish-freshness: 不明オプションは fail-loud（exit 1）" {
  run "$FRESH" --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"不明なオプション"* ]]
}

@test "publish-freshness: 不正 GRACE は fail-loud（exit 1）" {
  run env SCRIBE_PUBLISH_FRESHNESS_GRACE=abc "$FRESH" check
  [ "$status" -eq 1 ]
  [[ "$output" == *"非負整数"* ]]
}

@test "publish-freshness: bd list 失敗は warn+exit 0（infra は非block・--strict でも止めない）" {
  local stub="$STUB_DIR/bd-fail.sh"
  printf '#!/usr/bin/env bash\n[ "$1" = list ] && exit 7\nexit 1\n' > "$stub"; chmod +x "$stub"
  run env SCRIBE_BD="$stub" "$FRESH" --strict check
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
}

@test "publish-freshness: bd バイナリ不在は warn+exit 0（infra 非block）" {
  run env SCRIBE_BD="$STUB_DIR/no-such-bd" "$FRESH" check
  [ "$status" -eq 0 ]
  [[ "$output" == *"見つかりません"* || "$output" == *"skip"* ]]
}

@test "publish-freshness: mark-published は bdw で federate-published-at marker を append する" {
  local bd; bd="$(_make_bd_stub '[]')"
  _set_bead sc-m "2026-07-02T10:00:00Z" "x" '["federate-publish"]'
  local bdw="$STUB_DIR/bdw-cap.sh" cap="$STUB_DIR/bdw-args.txt"
  cat > "$bdw" <<BDW
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$cap"
exit 0
BDW
  chmod +x "$bdw"
  run env SCRIBE_BD="$bd" SCRIBE_BDW="$bdw" "$FRESH" mark-published sc-m
  [ "$status" -eq 0 ]
  [[ "$output" == *"provenance を記録"* ]]
  run cat "$cap"
  [[ "$output" == *"update sc-m --append-notes"* ]]
  [[ "$output" == *"federate-published-at:"* ]]
}

@test "publish-freshness: mark-published は存在しない id で fail-loud" {
  local bd; bd="$(_make_bd_stub '[]')"   # show-<id>.json を作らない → 実在検証 exit 1
  run env SCRIBE_BD="$bd" "$FRESH" mark-published sc-nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"存在しません"* ]]
}

@test "publish-freshness: mark-published は id 無しで fail-loud" {
  run "$FRESH" mark-published
  [ "$status" -eq 1 ]
  [[ "$output" == *"必要"* ]]
}

@test "publish-freshness: mark-published は label 不在でも warn しつつ記録する（advisory）" {
  local bd; bd="$(_make_bd_stub '[]')"
  _set_bead sc-nl "2026-07-02T10:00:00Z" "x" '["other-label"]'
  local bdw="$STUB_DIR/bdw2.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$bdw"; chmod +x "$bdw"
  run env SCRIBE_BD="$bd" SCRIBE_BDW="$bdw" "$FRESH" mark-published sc-nl
  [ "$status" -eq 0 ]
  [[ "$output" == *"ラベルがありません"* ]]
  [[ "$output" == *"provenance を記録"* ]]
}

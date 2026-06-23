#!/usr/bin/env bash
# grill-status-watch.sh — grill-consult の bd notes STATUS 行を poll して「変化」だけ通知する read-only watcher。
#
# 用途（sc-bka）: admin が Monitor / `/loop` の command として使い、grill-consult（§7 needs-user）の
#   完了（`STATUS: done`）/ 詰まり（`STATUS: blocked`）を「受動監視」から「即時感知」へ格上げする。
#   v1（背景 supervisor・scribe-design §14）の軽量 poll だが、LLM 不使用・jq のみで動くため
#   admin が任意で使える v0 手動監視の補助ツールとしても成立する。
#
# 設計の核:
#   - READ-only。`bd show <id> --long --json` だけを叩く（bdw lock 不要＝bdw は WRITE 直列化専用）。
#   - STATUS の SSOT は sc-qos 成果物（scripts/scribe-spawn.sh の grill-consult prompt + docs/protocol.md §7）。
#     canonical: `STATUS: grilling (n/N)` / `STATUS: done — …` / `STATUS: blocked — 要admin: …`。
#   - STATUS は「見にくる合図」であって機械的 close トリガーではない（fail-closed・sc-qos D3）。
#     本 watcher は close も bd write もしない・通知するだけ。最終 close は admin の全 facet 目視 gate（§7）。
#
# 実機 gotcha（verified）:
#   - bd は permissions warning 等を stderr に出すため bd 呼び出しは必ず `2>/dev/null`。ただし stderr 抑止
#     **だけでは不十分**——bd は存在しない/closed/deleted id に対し JSON error-object（`{"error":...}`）を
#     **stdout** に出して exit 1 する。これは 2>/dev/null を生き残り非空ゆえ guard を通過し、`.[0]` で
#     jq が落ちる。よって extract_status は型ガード＋`2>/dev/null || echo no-notes`、fetch_status は
#     キャプチャ＋フォールバックで「bd 失敗でも loop が死なない」を担保する（acceptance(4)）。
#   - `bd show --long --json` は notes 未記録の issue では notes フィールド自体を省略する（has(notes)==false）。
#     抽出 jq の型ガードが null / フィールド欠如の両方を no-notes に吸収する。
#   - 出力は通常は配列（`.[0]`）。配列でない error-object / 壊れた JSON も no-notes に潰す。
set -euo pipefail

readonly INTERVAL_DEFAULT=15

usage() {
  cat <<'USAGE'
grill-status-watch.sh — grill-consult の STATUS 行を poll して変化のみ通知する（read-only）。

USAGE:
  grill-status-watch.sh <grill-issue-id> [interval_sec]   # 監視ループ（既定 15 秒間隔）
  grill-status-watch.sh --fetch <grill-issue-id>           # 現在の STATUS を一回だけ取得（単発）
  grill-status-watch.sh --extract                          # stdin の bd json から STATUS 抽出（テスト/単発）
  grill-status-watch.sh --classify <status-string>         # STATUS が終端（done/blocked）かを判定
  grill-status-watch.sh -h | --help

挙動:
  - notes の最後の `STATUS:` 行を抽出し、直近の実 STATUS と差分があるときだけ
    `[<id>] STATUS changed: <new>` を stdout に出す（Monitor の command として使える）。
    bd の一過性失敗（no-notes/no-status）は遷移として扱わず基準を据え置く＝復帰時に同一 STATUS を再通知しない。
  - STATUS が done / blocked を含めば exit 0 で自己終了（Monitor の終了トリガー）。
  - interval は非負整数のみ（非数値はループ突入前に return 2 で弾く＝sleep クラッシュで黙って死なせない）。
  - READ-only。close も bd write もしない（最終 close は admin の目視 gate = protocol §7）。
USAGE
}

# stdin: `bd show <id> --long --json` の出力（通常は配列）。stdout: 最後の STATUS 行 / "no-status" / "no-notes"。
# notes フィールドが null でも欠如でも "no-notes" に吸収する（実機 verified）。
# 頑健化（acceptance(4)・sc-bka findings）: bd が error-object（`{"error":...}`）や非配列・
# notes 非文字列・壊れた JSON を stdout に返しても jq を非ゼロ終了させない——型ガードで no-notes に潰し、
# jq の parse error（壊れた JSON）も `|| echo no-notes` で吸収して loop を絶対に殺さない。
extract_status() {
  jq -r 'if (type=="array" and (.[0]|type)=="object" and (.[0].notes|type)=="string")
         then (.[0].notes | split("\n") | map(select(startswith("STATUS:"))) | last // "no-status")
         else "no-notes" end' 2>/dev/null || echo "no-notes"
}

# STATUS 文字列が終端（canonical の done/blocked）なら 0、そうでなければ 1。
# 前方アンカー（sc-bka findings）: canonical 形式では done/blocked は必ず `STATUS:` 直後のキーワード。
# 行全体の部分一致（*done*|*blocked*）だと grilling 行の自由文末尾（例
# `STATUS: grilling — facet done で確認待ち`）を terminal と誤判定して watcher が早期 exit 0 する。
# `STATUS:` を剥がした先頭トークンだけを done/blocked と前方一致させ、prose の混入を誤検出しない。
is_terminal() {
  local kw="${1#STATUS:}"
  kw="${kw#"${kw%%[![:space:]]*}"}"   # 先頭空白を除去（"STATUS: done …" の space を吸収）
  case "$kw" in
    done*|blocked*) return 0 ;;
    *) return 1 ;;
  esac
}

# <id> の現在 STATUS を一回取得。bd 失敗・空応答でも落ちず "no-notes" を返す（loop を止めない）。
# テスト用フック（poll ごとの遷移を表現する seam・sc-bka findings 1/4）:
#   - GRILL_WATCH_JSON_CMD: poll の度に実行し stdout を JSON ソースにする（呼ばれる度に違う値を返せる
#     ＝grilling→grilling(n+1)→done のような非終端遷移・dedup を 1 プロセス内で再現できる）。
#   - GRILL_WATCH_JSON_FILE: 固定 JSON ファイルを JSON ソースにする（単発・終端の決定論検証）。
#   CMD が優先（両方あれば CMD）。どちらも無ければ実 bd を叩く。
fetch_status() {
  local id="$1" json out
  if [[ -n "${GRILL_WATCH_JSON_CMD:-}" ]]; then
    json="$(eval "$GRILL_WATCH_JSON_CMD" 2>/dev/null || true)"
    out="$(printf '%s' "$json" | extract_status)" || out="no-notes"
    printf '%s\n' "${out:-no-notes}"
    return 0
  fi
  if [[ -n "${GRILL_WATCH_JSON_FILE:-}" ]]; then
    out="$(extract_status < "$GRILL_WATCH_JSON_FILE")" || out="no-notes"
    printf '%s\n' "${out:-no-notes}"
    return 0
  fi
  json="$(bd show "$id" --long --json 2>/dev/null || true)"
  [[ -n "$json" ]] || { echo "no-notes"; return 0; }
  # extract をキャプチャしてフォールバックする＝bd が error-object / 壊れた JSON を stdout に
  # 返しても fetch_status は no-notes を返して 0 終了し、watch_loop を絶対に殺さない（acceptance(4)）。
  out="$(printf '%s' "$json" | extract_status)" || out="no-notes"
  printf '%s\n' "${out:-no-notes}"
}

# 監視ループ: 変化した実 STATUS 行だけ通知し、終端で自己終了する。
# interval は CLI から直接渡る externally-controlled な値（Monitor/loop の引数）。非数値だと sleep が
# 失敗し set -e 下で loop が黙って死ぬ（fail-open＝監視停止）ので、ループ突入前に検証して弾く（sc-bka F3）。
#
# 変化検知の基準は「直近に観測した実 STATUS 行」(last_status) であり、毎周の cur ではない（sc-bka F2）。
# bd の一過性失敗は acceptance(4) が想定する常態で、その周回の cur は no-notes/no-status に潰れる。
# もし prev を毎周 cur で無条件更新すると、real STATUS 通知済み → bd 一瞬失敗(no-notes) → bd 復帰(同 real)
# で「変化していない STATUS」を spurious re-notify してしまう。last_status を実 STATUS 行でのみ更新し、
# no-notes/no-status の周回は基準を据え置く（＝遷移として扱わない）ことで偽シグナルを出さない。
watch_loop() {
  local id="$1" interval="${2:-$INTERVAL_DEFAULT}" last_status="" cur
  [[ "$interval" =~ ^[0-9]+$ ]] \
    || { echo "interval must be a non-negative integer: $interval" >&2; return 2; }
  while true; do
    # command-sub 失敗を吸って poll を継続する（fetch_status は既に 0 終了するが二重防御）。
    cur="$(fetch_status "$id")" || cur="no-notes"
    # 実 STATUS 行（"STATUS:" 始まり）かつ直近の実 STATUS と差分のときだけ通知する。
    # "no-notes" / "no-status"（grill 未着手・STATUS 未記録・bd 一過性失敗）は基準を据え置き静かに続ける。
    if [[ "$cur" == STATUS:* && "$cur" != "$last_status" ]]; then
      printf '[%s] STATUS changed: %s\n' "$id" "$cur"
      last_status="$cur"
      is_terminal "$cur" && exit 0
    fi
    sleep "$interval"
  done
}

main() {
  case "${1:-}" in
    -h|--help|'') usage ;;
    --fetch)      fetch_status "${2:?--fetch は <grill-issue-id> が必要}" ;;
    --extract)    extract_status ;;
    --classify)   if is_terminal "${2:-}"; then echo terminal; else echo ongoing; fi ;;
    -?*)          printf 'unknown option: %s\n' "$1" >&2; usage; return 2 ;;  # 単一/二重ダッシュ両方を弾く（typo→無限ループ防止・sc-bka 確認ラウンド）
    *)            watch_loop "$1" "${2:-}" ;;
  esac
}

main "$@"

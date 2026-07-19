#!/usr/bin/env bash
# orch-hydrate.sh — orchestrator 連結 substrate の冪等 bootstrap（bd un-aoa・un-df2 split）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   orchestrator session（cwd=orchestrator・dolt_database=orch）の初回/再実行で、既知 project の
#   bd 台帳を「連結 substrate」へ取り込む（top-spec §3）。各 project を
#     bd repo add <path>   # 既登録なら skip（連結対象として登録）
#     bd repo sync         # pull 型 hydrate（foreign issue を自 DB へ read 取り込み）
#   する。これにより cross-rig dep（`bdw dep add orch-<id> <foreign-bead>`）が解決可能になる。
#   courier の durable leg（定期 re-sync）の初回投入も本スクリプトが担う。
#
# 冪等・再実行安全（load-bearing） ───────────────────────────────────────────────
#   bd 自身は `repo add` の重複に非寛容: 同一 path を二度 add すると
#     "Error: failed to add repository: repository already configured: <path>"（非 0）で失敗する
#   （un-aoa で throwaway ledger 実測）。よって再実行安全のために**既登録 path は add せず skip** する
#   必要がある（bd 任せにできない）。登録状態の SSOT は bd 自身が編集する `.beads/config.yaml` の
#   `repos.additional`（`bd repo add` が `    - "<path>"` を quote 付き verbatim で追記＝実測）。本
#   スクリプトはこの config を read して既登録判定し、未登録のみ add する。`repo sync` は pull hydrate
#   ゆえ何度走っても安全＝毎回実行する（courier）。
#
# bdw 経由（write 直列化・guard 正路） ───────────────────────────────────────────
#   `repo add`/`repo sync` は orch 台帳（embedded Dolt = single-writer）を mutate する write。
#   bd-write-guard.py は `repo add|remove|sync` を kind 'c'（bdw 直列化）に分類し、`repo list` のみ
#   read allow とする（CLAUDE.md 連結 substrate 正路）。並行 hydrate の lost-update を防ぐため、本
#   スクリプトは bd を直接呼ばず**同梱 bdw 経由**で実行する（bdw は basename != "bd" ゆえ guard 対象外・
#   内部 bd 呼び出しは subprocess で PreToolUse hook 非再発火）。
#
# orchestrator session 前提（誤台帳 mutate の防止） ──────────────────────────────
#   `bd repo` は cwd の台帳に作用する。非 orch 台帳（scribe 'sc' / cc-session 'ccs' 等）
#   から実行すると foreign 台帳を汚す。よって起動時に「cwd から walk-up した最初の
#   .beads/metadata.json の dolt_database が orch か」を検査し、非該当なら何もせず非 0 で抜ける
#   （bd-write-guard / spec-inject の session self-scope と同一機構・同一 SELF_PREFIX を共有）。
#
# 設定可能 project list ─────────────────────────────────────────────────────────
#   project list は env `ORCH_HYDRATE_PROJECTS`（空白区切りの `name=path` トークン列・**path に空白を
#   含めない**＝空白区切り read -ra で分割するため）または private 配備層 registry（下記解決順）から
#   受ける（self-test / 将来の project 追加用）。存在しない path は
#   fail-safe で skip（「存在すれば」扱いの project を自然に表現）。.beads を持たない path も
#   hydrate 不能ゆえ skip する。
#
# pre-sync universal pull（orch-ctzr・裁定 orch-rafl 論点3） ────────────────────────
#   add/sync の**前**の独立 pre-sync 段で、remote を持つ全 foreign 登録候補 repo を
#     ( cd <repo> && bdw dolt pull )   # subshell cd 形（load-bearing）
#   で freshen する。remote-fed clone（書き手が他マシンの read mirror）の local dolt が他マシンの
#   新規 write を人手なしで拾えるようにし、bdw の auto-export 込みで dolt 前進と mirror(issues.jsonl) 追随を
#   同一起動内で保証する（後段 sync が fresh mirror を hydrate し STALE-CHECK が恒常警告を出さない）。
#   選別基準なし（universal・no-flag 原則整合＝per-repo フラグ/registry カテゴリ/構造検出/remote-fed マーク
#   全て不採用）で全 repo へ attempt し、remote-less error を benign-skip に分類する。
#     実装 form（load-bearing・silent false-green 回避）: 必ず subshell cd 形。bdw -C は flock 鍵/auto-export
#       root が CWD 由来で -C 不関与ゆえ orch に落ち silent に破れる（本体 pull phase コメント参照）。
#     失敗意味論（best-effort・非 fatal）: pull の非0 は fatal failures へ算入せず pull_warn へ。remote-less=
#       benign-skip / genuine conflict のみ loud / network・transient=warn+degrade+次cycle回収。全 pull が
#       失敗しても sync 到達・last-sync stamp・exit 0 を妨げない（cell 全滅を false-RED と誤読しない）。
#     throttle（条件1）: per-repo marker（自台帳 .beads/pull-freshness/・path-hash）の age < THROTTLE で skip
#       ＝GATE-DURATION-TRIPWIRE（gate が総 wall-clock を計時）への 60s 接近を防ぐ。SYNC_MARKER と別 namespace。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）  実行: pre-sync universal pull → 未登録 project を `bdw repo add` → `bdw repo sync` → STALE-CHECK。
#   --dry-run 実 bd/bdw を一切呼ばず、pull 対象列挙（would execute ( cd .. && bdw dolt pull )）・project list
#             解決・既登録 skip 判定・存在/`.beads` skip・実行予定コマンド print のみ（実 orch- 台帳/dolt を
#             汚さない＝self-test が hermetic）。
#   --help    使い方。
#
# post-sync mirror 鮮度 cross-check（orch-rur / orch-89v ③） ───────────────────────
#   bd v1.1.0 の auto-export 退行（orch-89v）で、各 project の .beads/issues.jsonl（＝`bd repo sync` が
#   読む foreign mirror）が dolt DB より古いまま凍結されると、sync は成功を装い stale data を hydrate する
#   （silent false-negative・2026-07-08 実測=丸1日）。sync 後、各 registered repo につき
#     mirror（on-disk .beads/issues.jsonl）の (件数, 最大 updated_at) と
#     live DB（`bd -C <repo> export`＝dolt 直読・stdout）の (件数, 最大 updated_at) を比較し、
#   DB が新しい／件数が乖離するなら「mirror が stale」と loud 警告する（repo 名 + 復旧コマンド
#   『(その repo の) bdw export -o .beads/issues.jsonl』）。foreign へは read のみ（`bd -C export` は stdout・
#   write しない＝write-isolation 不変）。検査自体の失敗（bd 不能・issues.jsonl 不在・python3 不在・parse 不能）
#   は hydrate を止めず注記のみ＝fail-open。警告は exit code を変えない（stale 検出は WARNING であり error でない）。
#
# env override（主に self-test 用）:
#   ORCH_HYDRATE_PROJECTS   project list を全置換（空白区切り `name=path` 列・path に空白不可）。
#   ORCH_HYDRATE_CONFIG     既登録判定に使う config.yaml パスを差し替え（既定: 解決した orch 台帳の
#                           .beads/config.yaml）。temp config で既登録 skip を hermetic にテストする。
#   ORCH_HYDRATE_BDW        bdw 実体パス（既定: 本スクリプトと同 dir の bdw）。
#   ORCH_HYDRATE_BD         bd 実体パス（既定: PATH の bd）。post-sync mirror 鮮度 cross-check の
#                           foreign 直読（`bd -C <repo> export`＝stdout・read-only）に使う。self-test で stub 差替。
#   ORCH_HYDRATE_SYNC_MARKER sync 専用鮮度マーカーの stamp 先（既定: 解決した orch 台帳の .beads/last-sync）。
#                           `bd repo sync` 成功直後に mtime/内容を更新し、orch-dispatch --gate-pending が
#                           foreign 鮮度判定の主指標に使う（export-state.json の any-write proxy 問題を解消・orch-6rb）。
#   ORCH_HYDRATE_PULL_MARKER_DIR pre-sync pull の per-repo throttle marker dir（既定: 解決した orch 台帳の
#                           .beads/pull-freshness）。SYNC_MARKER と別 namespace。self-test で temp 差替。
#   ORCH_HYDRATE_PULL_THROTTLE_SEC pre-sync pull の throttle 閾値秒（既定 1500=25分・gate PERIOD 30分 に対し
#                           timer cadence では毎 cycle pull で鮮度維持しつつ頻回 invocation を de-dup する結合）。
#   ORCH_HYDRATE_NOW        pre-sync pull throttle の現在時刻 epoch（既定 `date +%s`）。self-test で決定論注入。
#
# 検証: selftest-un-aoa.local.sh（worktree 直下・untracked・fail-closed・dolt 不使用＝bash -n +
#   --dry-run の冪等ロジック検査のみ。hermetic dolt は使わない＝契約 NOTES (3) 軽量方針）。

set -uo pipefail

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard と同一値を共有）。
SELF_PREFIX="orch"

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・orch-vo2 で 5 script も統一） ---
# _ledger_dolt_database（_json_is_valid gate 済み walk-up）を提供する。旧 inline _resolve_dolt_database は
# _json_is_valid gate を欠く drift（破損 orch-token metadata で誤 self-scope＝誤台帳起動しうる）だったため
# 撤去し、gate 済みの共有関数へ統一する（orch-vo2 acceptance・orch-degraded-watch と同型）。self-scope gate は
# fail-closed 方針ゆえ、gate 追加で破損 orch-token metadata は self とみなされず refuse 側へ倒れる（安全側）。
# ★実 script 位置（BASH_SOURCE 相対）で解決するので bats/--self-test が実 lib を確実に見つける。
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_ORCH_SESSION_LIB="$_SCRIPT_DIR/hooks/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=hooks/lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "orch-hydrate: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# --- project list は env seam / private 配備層 registry から受ける（engine=mechanism / value=private の分離） ---
# engine tree は project registry（実名 list）を同梱しない。解決順:
#   (1) env `ORCH_HYDRATE_PROJECTS`（空白区切り `name=path` 列）が set なら後段でそれを全採用（従来どおり）。
#   (2) 同 dir の private registry overlay（scripts/lib/orch-projects.sh・配備層が配置した場合のみ）を source。
#   (3) どちらも無ければ fail-loud（値の hardcode fallback は持たない＝degraded 続行しない）。
# 二重 SSOT 回避（orch-2ax）は「registry を配備層 1 箇所に置き engine は読むだけ」で維持する
# （folio inventory channel = orch-architecture-hydrate.sh と同一解決）。存在しない path の fail-safe skip
# （「存在すれば」扱いの project の自然表現）は不変。trailing slash は付けない（bd は別 path 扱い）。
_ORCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib"
DEFAULT_PROJECTS=()
if [ -f "$_ORCH_LIB_DIR/orch-projects.sh" ]; then
    # shellcheck source=lib/orch-projects.sh
    # shellcheck disable=SC1091
    source "$_ORCH_LIB_DIR/orch-projects.sh"
fi
if [ -z "${ORCH_HYDRATE_PROJECTS:-}" ] && [ "${#DEFAULT_PROJECTS[@]}" -eq 0 ]; then
    echo "orch-hydrate: project list 未供給（fail-loud）: env ORCH_HYDRATE_PROJECTS（空白区切り name=path）を設定するか、" >&2
    echo "  private 配備層 registry を $_ORCH_LIB_DIR/orch-projects.sh へ配置すること（engine は値の hardcode を持たない）。" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            # 先頭コメントブロック（shebang 直後〜最初の非コメント行の手前）を help として出す。
            # 行番号を固定せず最初の非コメント行で打ち切るのでヘッダ伸縮に追従する（cell-quality
            # 自己点検 finding 反映: 旧 `sed -n '2,60p'` は header 末尾を超えて set/代入行を混入させた）。
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "orch-hydrate: unknown arg: $arg（--dry-run / --help のみ）" >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# ヘルパ
# ─────────────────────────────────────────────────────────────────────────────

# trailing slash を剥がす（root '/' は保持）。bd は trailing slash 有無を別 path 扱いするため、
# 既登録判定の正規化に使う。
_strip_trailing_slash() {
    local p="$1"
    while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    printf '%s' "$p"
}

# cwd の台帳 dolt_database の walk-up 解決（_ledger_dolt_database）は共有 lib scripts/hooks/lib/orch_session.sh
# が提供する（上で source 済み・orch-vo2）。旧 inline _resolve_dolt_database は _json_is_valid gate を欠く
# drift だったため撤去し、gate 済みの _ledger_dolt_database へ統一した（破損 orch-token metadata での誤
# self-scope を fail-closed で弾く・orch-degraded-watch と同型）。

# config.yaml の repos.additional に列挙された登録済み repo path を 1 行ずつ echo
# （quote 剥がし + trailing slash 正規化済み）。`additional:` ブロック内の `- "<path>"` のみ採る
# （他セクションの list 行や comment 行は拾わない）。bd が書く形式（4-space indent・double quote・
# verbatim path）を un-aoa で実測済み。
_config_registered_paths() {
    local cfg="$1" in_add=0 line trimmed val
    [ -f "$cfg" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        # ltrim
        trimmed="${line#"${line%%[![:space:]]*}"}"
        case "$trimmed" in
            ''|'#'*) continue ;;                 # blank / 全行コメント
        esac
        case "$trimmed" in
            'additional:'*) in_add=1; continue ;; # additional ブロック開始
        esac
        if [ "$in_add" -eq 1 ]; then
            case "$trimmed" in
                '-'*)
                    val="${trimmed#-}"                       # '-' を剥がす
                    val="${val#"${val%%[![:space:]]*}"}"     # 後続の ltrim
                    val="${val%"${val##*[![:space:]]}"}"     # 末尾 ws rtrim
                    case "$val" in                           # 囲み quote 剥がし
                        '"'*'"') val="${val#\"}"; val="${val%\"}" ;;
                        "'"*"'") val="${val#\'}"; val="${val%\'}" ;;
                    esac
                    _strip_trailing_slash "$val"; printf '\n'
                    ;;
                *) in_add=0 ;;                               # 同/浅 indent の別 key → ブロック終了
            esac
        fi
    done < "$cfg"
}

# path が config に登録済みか（trailing slash 正規化して厳密一致）。
_is_registered() {
    local target cfg p
    target="$(_strip_trailing_slash "$1")"
    cfg="$2"
    while IFS= read -r p; do
        [ "$p" = "$target" ] && return 0
    done < <(_config_registered_paths "$cfg")
    return 1
}

# post-sync mirror 鮮度 cross-check 用（orch-rur）: stdin の jsonl（bd export 形式・1 行 1 issue）を読み
# 「<件数> <最大 updated_at>」を print する。issue レコードのみ対象（_type 既定 'issue'・infra/memory 行は除外）。
# updated_at は RFC3339 Z 固定幅（例 2026-07-06T10:43:44Z）ゆえ文字列 max = 時刻 max（呼出側は文字列比較）。
# 不正行は skip（parse 不能行に強い）。python3 不在なら非 0 で戻る（呼出側が fail-open で吸収）。
_mirror_stats() {
    command -v python3 >/dev/null 2>&1 || return 3
    python3 -c '
import sys, json
mx = ""; n = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        o = json.loads(line)
    except Exception:
        continue
    if not isinstance(o, dict):
        continue
    if o.get("_type", "issue") != "issue":
        continue
    n += 1
    u = o.get("updated_at") or ""
    if u > mx:
        mx = u
print(n, mx)
'
}

# pre-sync universal pull（orch-ctzr）の throttle marker key を返す。物理 path と 1 対 1 の path-hash
# （canonical bdw の repo_id 哲学＝sha256(path)[:16]・sanitized name の衝突を避ける）。sha256sum 不能時は
# sanitized name へ fallback（key 空で marker が dir path 化するのを防ぐ・fail-open）。
_pull_marker_key() {
    local k
    k="$(printf '%s' "$1" | sha256sum 2>/dev/null | cut -c1-16)"
    [ -n "$k" ] || k="$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"
    printf '%s' "$k"
}

# pull throttle marker を stamp（自台帳 .beads/pull-freshness/ 配下＝write-isolation 不破・foreign を書かない）。
# mtime が鮮度の要点・内容（時刻 + name + path）は人間可読の補助。dir 作成/write 失敗は fail-open（throttle が
# 効かず次回も pull する＝安全側・hydrate は止めない）。
_stamp_pull_marker() {
    local mk="$1" nm="$2" pth="$3" dir
    dir="$(dirname "$mk")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "  WARN: pull throttle marker dir を作れず（throttle 無効・次回も pull＝安全側）: $dir" >&2
        return 0
    fi
    printf '%s\t%s\t%s\n' "$(date -Iseconds 2>/dev/null || date)" "$nm" "$pth" > "$mk" 2>/dev/null || \
        echo "  WARN: pull throttle marker stamp 失敗（throttle 無効・次回も pull＝安全側）: $mk" >&2
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# 前提検査: orchestrator session（cwd の台帳 dolt_database == orch）でなければ何もしない
# ─────────────────────────────────────────────────────────────────────────────
DB="$(_ledger_dolt_database "$PWD")"
if [ "$DB" != "$SELF_PREFIX" ]; then
    echo "orch-hydrate: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
    echo "  orchestrator session（cwd=orchestrator）から実行せよ。foreign 台帳を汚さないための fail-closed。" >&2
    exit 1
fi

# bdw 実体パス（同梱 bdw を既定・env で差し替え可）。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
BDW="${ORCH_HYDRATE_BDW:-$SCRIPT_DIR/bdw}"

# bd 実体パス（post-sync mirror 鮮度 cross-check の foreign 直読 `bd -C <repo> export` に使う・read-only）。
# 既定は PATH の bd。self-test/bats で stub（canned export）へ差し替える（ORCH_HYDRATE_BD）。
BD="${ORCH_HYDRATE_BD:-bd}"

# 既登録判定に使う config.yaml（既定: 解決した orch 台帳の .beads/config.yaml）。
LEDGER_ROOT="$PWD"
_dir="$(cd "$PWD" 2>/dev/null && pwd)" || _dir="$PWD"
while [ -n "$_dir" ]; do
    if [ -f "$_dir/.beads/metadata.json" ]; then LEDGER_ROOT="$_dir"; break; fi
    [ "$_dir" = "/" ] && break
    _dir="$(dirname "$_dir")"
done
CONFIG_YAML="${ORCH_HYDRATE_CONFIG:-$LEDGER_ROOT/.beads/config.yaml}"

# sync 専用鮮度マーカー（orch-6rb）。`bd repo sync`（foreign hydrate）成功直後に stamp し、
# orch-dispatch --gate-pending が foreign 鮮度判定の主指標に使う。export-state.json は any-write proxy
# （ローカル bdw write でも更新され sync 特化でない）ゆえ「active orchestrator が sync 忘れ/失敗」を
# 取りこぼす（admin gate errata・freshness-soundness）。本マーカーは「最後に foreign hydrate が成功した
# 時刻」だけを表す sync 特化指標。自台帳 .beads/ 配下ゆえ write-isolation 不破（foreign を書かない）。
# stamp 先 root は「実 DB（embeddeddolt）が在る台帳」に固定する: git worktree は .beads/metadata.json
# （tracked）を持つが embeddeddolt（gitignore）は anchor のみゆえ、LEDGER_ROOT（metadata.json walk-up）だと
# worktree 誤実行で worktree を指し orch-dispatch（SCRIPTORIUM=anchor 基準）の read 先と食い違う。embeddeddolt
# を walk-up して anchor に揃える（見つからなければ LEDGER_ROOT にフォールバック・env override が最優先）。
_dolt_root=""
_d="$(cd "$PWD" 2>/dev/null && pwd)" || _d="$PWD"
while [ -n "$_d" ]; do
    if [ -e "$_d/.beads/embeddeddolt" ]; then _dolt_root="$_d"; break; fi
    [ "$_d" = "/" ] && break
    _d="$(dirname "$_d")"
done
SYNC_MARKER="${ORCH_HYDRATE_SYNC_MARKER:-${_dolt_root:-$LEDGER_ROOT}/.beads/last-sync}"

# 実行モードでは bdw が無いと write 不能。dry-run は bdw を呼ばないので不要。
if [ "$DRY_RUN" = false ] && [ ! -x "$BDW" ]; then
    echo "orch-hydrate: bdw not found/executable: $BDW（実行には bdw が必要・ORCH_HYDRATE_BDW で差替可）" >&2
    exit 1
fi

# project list 解決（env override 優先・空白区切り name=path）。
PROJECTS=()
if [ -n "${ORCH_HYDRATE_PROJECTS:-}" ]; then
    read -ra PROJECTS <<< "$ORCH_HYDRATE_PROJECTS"
else
    PROJECTS=("${DEFAULT_PROJECTS[@]}")
fi

# ─────────────────────────────────────────────────────────────────────────────
# メイン: 各 project を add（既登録/不在/.beads 無は skip）→ 最後に sync
# ─────────────────────────────────────────────────────────────────────────────
mode_label="$([ "$DRY_RUN" = true ] && echo 'DRY-RUN' || echo 'EXEC')"
echo "== orch-hydrate ($mode_label) =="
echo "  ledger        : $LEDGER_ROOT (dolt_database=$DB)"
echo "  config(SSOT)  : $CONFIG_YAML"
echo "  bdw           : $BDW"
echo "  projects      : ${#PROJECTS[@]}"
echo "----------------------------------------------------------------------"

# ─────────────────────────────────────────────────────────────────────────────
# pre-sync universal pull（orch-ctzr・裁定 orch-rafl 論点3・sync の前の独立 pre-sync 段）
#   remote を持つ全 foreign 登録候補 repo を ( cd <repo> && bdw dolt pull ) で freshen する。remote-fed
#   clone（書き手が他マシンの read mirror）の local dolt が他マシンの新規 write を人手なしで拾えるようにし、bdw の
#   auto-export 込みで dolt 前進と mirror(issues.jsonl) 追随を同一起動内で保証する（後段 bdw repo sync が
#   fresh mirror を hydrate し STALE-CHECK が green・条件5 無改修を保つ）。un-10h5 世界では単一 writer ホストの
#   台帳も他マシン write 分は read-side stale になりうるゆえ universal pull は一般 reader 鮮度も同時に閉じる
#   （cdr はその一特例）。orch primary は含めない（PROJECTS=foreign のみ・orch は bdw Layer1 self-pull 済）。
#
#   実装 form（load-bearing・silent false-green 回避）: 必ず subshell cd 形 ( cd <repo> && "$BDW" dolt pull )。
#     canonical bdw の flock 鍵(resolve_repo_id)・auto-export root(resolve_export_root) は共に CWD の
#     git-common-dir 由来で -C は不関与ゆえ、bdw -C <repo> dolt pull は (1) flock 鍵が orch に落ち per-ledger
#     直列化が効かず (2) auto-export が orch mirror を再生成し foreign mirror を凍結放置し STALE-CHECK が
#     pull rc=0 のまま解消しない（本 phase の目的が cell 内不可視で silent に破れる）。bare cd+bd dolt pull は
#     guard allow だが flock 無で lost-update ゆえ禁止＝bdw 経由の subshell cd 形のみが正路。
#
#   失敗意味論（条件3・best-effort・非 fatal）: pull の非0 exit を fatal failures カウンタ（下段 add/sync が
#     使い exit code を決める）へ算入せず pull_warn へ振る。分類: remote-less（"Requires a Dolt remote" 系）=
#     benign-skip / genuine merge-conflict のみ = loud / network・transient = warn+degrade+次cycle回収。いずれも
#     bdw repo sync 到達と last-sync stamp を妨げない（全 pull が network 断で失敗しても orch-hydrate は exit 0）。
#
#   throttle（条件1・GATE-DURATION-TRIPWIRE 防止）: per-repo marker（自台帳 .beads/pull-freshness/・path-hash
#     キー）の age < THROTTLE_SEC なら pull を skip。settled outcome（success/remote-less）でのみ stamp する
#     （transient/conflict は stamp せず次 invocation で retry）。無 throttle だと invocation 毎に全 repo へ
#     network pull し 60s tripwire に接近しうる（gate PERIOD=30分 に対し既定 THROTTLE=25分＝timer cadence では
#     毎 cycle pull で鮮度維持しつつ、間の頻回 invocation を de-dup する結合）。SYNC_MARKER とは別 namespace。
# ─────────────────────────────────────────────────────────────────────────────
NOW="${ORCH_HYDRATE_NOW:-$(date +%s 2>/dev/null || echo 0)}"
PULL_MARKER_DIR="${ORCH_HYDRATE_PULL_MARKER_DIR:-${_dolt_root:-$LEDGER_ROOT}/.beads/pull-freshness}"
PULL_THROTTLE_SEC="${ORCH_HYDRATE_PULL_THROTTLE_SEC:-1500}"

pulled=0; pull_remoteless=0; pull_throttled=0; pull_warn=0
echo "PRE-SYNC PULL: universal freshen（throttle=${PULL_THROTTLE_SEC}s・marker=$PULL_MARKER_DIR）"
for entry in "${PROJECTS[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    # malformed / 不在 / 非 bd repo は pull 対象外（後段 add/sync 側が SKIP を人間向けに報告する）。
    if [ -z "$name" ] || [ -z "$path" ] || [ "$name" = "$entry" ]; then continue; fi
    path="$(_strip_trailing_slash "$path")"
    [ -d "$path" ] || continue
    [ -d "$path/.beads" ] || continue

    if [ "$DRY_RUN" = true ]; then
        echo "  DRY-RUN: would execute: ( cd $path && $BDW dolt pull )   # ($name・universal pull 対象)"
        continue
    fi

    key="$(_pull_marker_key "$path")"
    marker="$PULL_MARKER_DIR/$key"

    # throttle: marker age < threshold なら pull を skip（毎 invocation の network pull を bound）。
    if [ -f "$marker" ]; then
        m_mtime="$(stat -c %Y "$marker" 2>/dev/null || echo 0)"
        age=$(( NOW - m_mtime ))
        if [ "$age" -ge 0 ] && [ "$age" -lt "$PULL_THROTTLE_SEC" ]; then
            echo "  PULL-SKIP (throttle age=${age}s < ${PULL_THROTTLE_SEC}s): $name"
            pull_throttled=$((pull_throttled + 1))
            continue
        fi
    fi

    # 実装 form（load-bearing）: subshell cd 形のみ。bdw -C は flock 鍵/auto-export root が CWD 由来ゆえ禁止。
    pull_out="$( ( cd "$path" && "$BDW" dolt pull ) 2>&1 )"; pull_rc=$?

    if [ "$pull_rc" -eq 0 ]; then
        # 成功（pull or already up-to-date）。bdw auto-export が同一起動内で mirror(issues.jsonl) を再生成する。
        echo "  PULL-OK: $name（dolt 前進 + auto-export で mirror 追随）"
        pulled=$((pulled + 1))
        _stamp_pull_marker "$marker" "$name" "$path"   # settled → throttle 窓を開く
    elif printf '%s' "$pull_out" | grep -qiE 'requires a dolt remote|no dolt remote|remote[^\n]*not (found|configured)|no remote configured'; then
        # remote-less（bd dolt pull の "Requires a Dolt remote" 系）＝benign-skip（no-flag 原則・事前選別しない）。
        # 実 bd v1.1.0 バイナリの remote-less 文言は「Requires a Dolt remote to be configured in the database
        # directory.」で、第1 alternation `requires a dolt remote`（-i）に substring 一致する（cell-quality verify
        # が実 binary strings 走査で確認済み・"No Dolt remote configured" 等の変種も同 regex に一致）。実 https
        # 経路の網羅照合は Leg-2（post-land smoke）に属す＝本 regex は防御的に広く取る（誤 transient 分類は
        # fail-safe＝benign-skip の代わりに warn+retry になるだけで correctness/exit code 不変）。
        echo "  PULL-SKIP (remote-less・benign): $name"
        pull_remoteless=$((pull_remoteless + 1))
        _stamp_pull_marker "$marker" "$name" "$path"   # remote は自発的に生えない＝settled・attempt を bound
    elif printf '%s' "$pull_out" | grep -qiE 'conflict'; then
        # genuine merge-conflict のみ loud（要人手・stamp せず次 invocation で loud 継続）。
        echo "  ⚠️  PULL-CONFLICT (genuine・loud・要人手): $name — bd dolt pull が merge conflict（rc=$pull_rc）" >&2
        printf '%s\n' "$pull_out" | sed 's/^/       /' >&2
        pull_warn=$((pull_warn + 1))
    else
        # network・transient（warn+degrade・stamp せず次cycle回収）。cell 内の network 断もここ＝非 fatal。
        echo "  ⚠️  PULL-WARN (transient/network・degrade・次cycle回収): $name（rc=$pull_rc）" >&2
        printf '%s\n' "$pull_out" | sed 's/^/       /' >&2
        pull_warn=$((pull_warn + 1))
    fi
done
echo "  pull summary: ok=$pulled remote-less=$pull_remoteless throttled=$pull_throttled warn=$pull_warn（best-effort・非fatal＝exit code 不関与）"
echo "----------------------------------------------------------------------"

added=0; skipped=0; registered_total=0; failures=0
# 存在し .beads を持つ有効 repo（＝sync 対象・後段の post-sync mirror 鮮度 cross-check 対象）を収集。
CHECKED_REPOS=()

for entry in "${PROJECTS[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    if [ -z "$name" ] || [ -z "$path" ] || [ "$name" = "$entry" ]; then
        echo "SKIP (malformed entry, expected name=path): '$entry'"
        skipped=$((skipped + 1))
        continue
    fi
    path="$(_strip_trailing_slash "$path")"

    if [ ! -d "$path" ]; then
        echo "SKIP (path missing): $name = $path"
        skipped=$((skipped + 1))
        continue
    fi
    if [ ! -d "$path/.beads" ]; then
        echo "SKIP (no .beads, not a bd repo): $name = $path"
        skipped=$((skipped + 1))
        continue
    fi
    # 存在 + .beads を持つ有効 bd repo → sync 対象ゆえ post-sync 鮮度 cross-check 対象に収集
    # （新規 add / 既登録 skip の双方を含む＝sync が実際に読む foreign 集合に対応）。
    CHECKED_REPOS+=("$name=$path")
    if _is_registered "$path" "$CONFIG_YAML"; then
        echo "SKIP (already registered): $name = $path"
        skipped=$((skipped + 1))
        registered_total=$((registered_total + 1))
        continue
    fi

    # 未登録 → add 対象
    if [ "$DRY_RUN" = true ]; then
        echo "DRY-RUN: would execute: $BDW repo add $path   # ($name)"
        added=$((added + 1))
        registered_total=$((registered_total + 1))
    else
        echo "ADD: $name = $path"
        if "$BDW" repo add "$path"; then
            added=$((added + 1))
            registered_total=$((registered_total + 1))
        else
            echo "  FAIL: bdw repo add で失敗: $name = $path" >&2
            failures=$((failures + 1))
        fi
    fi
done

echo "----------------------------------------------------------------------"
# sync は登録 repo が 1 つ以上あるときのみ（連結対象ゼロでの no-op sync を避ける）。
if [ "$registered_total" -ge 1 ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "DRY-RUN: would execute: $BDW repo sync   # pull hydrate（registered=$registered_total）"
        echo "DRY-RUN: would stamp:   $SYNC_MARKER   # sync 成功直後に sync 専用鮮度マーカーを更新（orch-6rb）"
    else
        echo "SYNC: bdw repo sync（pull hydrate・registered=$registered_total）"
        if "$BDW" repo sync; then
            # sync 成功直後にのみ sync 専用鮮度マーカーを stamp（orch-6rb）。失敗時は stamp しない＝マーカーが
            # 古いまま残り orch-dispatch が stale を検出する（＝「sync 失敗時に警告が出る」を満たす fail-loud）。
            # 自台帳 .beads/ 配下への write ゆえ write-isolation 不破。mtime が鮮度の要点・内容は人間可読の補助。
            if printf '%s\n' "$(date -Iseconds 2>/dev/null || date)" > "$SYNC_MARKER" 2>/dev/null; then
                echo "STAMP: sync 鮮度マーカー更新: $SYNC_MARKER"
            else
                echo "  WARN: sync 鮮度マーカーの stamp に失敗: $SYNC_MARKER（orch-dispatch 側で unknown に縮退＝fail-safe）" >&2
            fi
        else
            echo "  FAIL: bdw repo sync で失敗" >&2
            failures=$((failures + 1))
            # sync 失敗時は stamp しない（意図的）。マーカーが古い/不在のまま → orch-dispatch が stale/unknown で警告。
        fi
    fi
else
    echo "SYNC skip: 登録 repo が無いため sync しない"
fi

# ─────────────────────────────────────────────────────────────────────────────
# post-sync mirror 鮮度 cross-check（orch-rur / orch-89v ③）
#   各 registered repo につき mirror（on-disk issues.jsonl）と live DB（bd -C export・dolt 直読）の
#   (件数, 最大 updated_at) を比較し、DB が新しい／件数乖離なら stale mirror を loud 警告する。
#   全て read-only（bd -C export は stdout・foreign を書かない）。検査失敗は全て fail-open（注記のみ・
#   hydrate を止めない・exit code を変えない）。stale 検出も WARNING であって error ではない。
# ─────────────────────────────────────────────────────────────────────────────
echo "----------------------------------------------------------------------"
if [ "$registered_total" -ge 1 ] && [ "${#CHECKED_REPOS[@]}" -ge 1 ]; then
    if [ "$DRY_RUN" = true ]; then
        echo "DRY-RUN: would cross-check mirror staleness for ${#CHECKED_REPOS[@]} repo(s)（bd -C <repo> export vs .beads/issues.jsonl）"
    elif ! command -v python3 >/dev/null 2>&1; then
        echo "  NOTE: python3 不在のため mirror 鮮度 cross-check を skip（fail-open）" >&2
    else
        echo "STALE-CHECK: mirror 鮮度 cross-check（${#CHECKED_REPOS[@]} repo・read-only）"
        stale_found=0
        skipped_check=0   # fail-open で検査 skip した repo 数（集計行の truthfulness に使う・gate errata E1）
        for entry in "${CHECKED_REPOS[@]}"; do
            name="${entry%%=*}"
            path="${entry#*=}"
            jsonl="$path/.beads/issues.jsonl"
            if [ ! -f "$jsonl" ]; then
                echo "  NOTE: $name: issues.jsonl 不在（mirror 未生成）— 検査 skip（fail-open）"
                skipped_check=$((skipped_check + 1))
                continue
            fi
            # mirror 側（on-disk jsonl）の (件数, 最大 updated_at)
            j_n=""; j_max=""
            read -r j_n j_max < <(_mirror_stats < "$jsonl" 2>/dev/null)
            j_n="${j_n:-0}"
            # live DB 側（bd -C export = dolt 直読・stdout・read-only）の (件数, 最大 updated_at)
            db_out="$("$BD" -C "$path" export 2>/dev/null)"
            d_n=""; d_max=""
            read -r d_n d_max < <(printf '%s\n' "$db_out" | _mirror_stats 2>/dev/null)
            d_n="${d_n:-0}"
            if [ "$d_n" -eq 0 ]; then
                # bd -C export が有効 issue 0 件＝bd read 失敗（error 出力）or 空 DB。信頼できる比較不能ゆえ
                # 警告を出さず注記のみ（fail-open）。誤陽性（bd 一時失敗を stale と誤断）を避ける安全側。
                echo "  NOTE: $name: bd -C export が有効 issue 0 件（bd read 失敗 or 空 DB）— 検査 skip（fail-open）"
                skipped_check=$((skipped_check + 1))
                continue
            fi
            if [[ "$d_max" > "$j_max" ]] || [ "$d_n" != "$j_n" ]; then
                # 発火理由で headline を分ける（gate errata E2）: max_updated 後退は「jsonl が古い」＝方向あり、
                # 件数乖離は双方向発火（mirror>DB の稀ケースも含む）ゆえ方向中立の「乖離」で誤誘導を避ける。
                # 復旧コマンド（DB→mirror 再生成）は bd モデル上 DB=truth ゆえ両者で不変（E2 指示どおり）。
                if [[ "$d_max" > "$j_max" ]]; then
                    stale_reason=".beads/issues.jsonl が dolt DB より古い（max_updated が後退・bd repo sync が stale data を hydrate する silent false-negative リスク）"
                else
                    stale_reason="mirror(.beads/issues.jsonl) と dolt DB の内容が乖離（件数不一致・bd repo sync が実 DB と異なる集合を hydrate するリスク）"
                fi
                echo "  ⚠️  STALE MIRROR: $name — $stale_reason" >&2
                echo "       jsonl(mirror): n=$j_n  max_updated=$j_max" >&2
                echo "       dolt (live)  : n=$d_n  max_updated=$d_max" >&2
                echo "       復旧: cd \"$path\" && bdw export -o .beads/issues.jsonl   # (その repo の bdw で mirror を再生成)" >&2
                stale_found=$((stale_found + 1))
            fi
        done
        # 集計行の truthfulness（gate errata E1）: fail-open で skip した repo を「fresh 検証済み」に融合しない。
        # 「全 registered repo の mirror は fresh」は skip も stale も 0 のときだけ言う（＝全数が実検査を通り fresh）。
        # skip or stale が在るときは checked(fresh)/skipped(検査不能)/stale を分離報告し false reassurance を防ぐ。
        checked_fresh=$(( ${#CHECKED_REPOS[@]} - skipped_check - stale_found ))
        if [ "$stale_found" -gt 0 ]; then
            echo "  ⚠️  $stale_found repo で stale mirror を検出（上記復旧コマンドで各 repo の mirror を再生成せよ）" >&2
        fi
        if [ "$skipped_check" -eq 0 ] && [ "$stale_found" -eq 0 ]; then
            echo "  OK: 全 registered repo の mirror は fresh（stale 警告なし・checked=$checked_fresh）"
        else
            echo "  STALE-CHECK summary: checked=$checked_fresh fresh / skipped=$skipped_check（検査不能・fail-open）/ stale=$stale_found（total=${#CHECKED_REPOS[@]}）"
        fi
    fi
fi

echo "----------------------------------------------------------------------"
echo "summary: added=$added skipped=$skipped registered_total=$registered_total failures=$failures pull(ok=$pulled remote-less=$pull_remoteless throttled=$pull_throttled warn=$pull_warn) (mode=$mode_label)"

# exit code は fatal failures（add/sync）のみが決める。pre-sync pull は best-effort ゆえ pull_warn は
# 一切 exit code に算入しない（全 pull が network 断で失敗しても hydrate は exit 0＝cell 全滅を false-RED
# と誤読させない・条件3）。
[ "$failures" -eq 0 ] || exit 1
exit 0

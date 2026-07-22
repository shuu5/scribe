#!/usr/bin/env bash
# orch-discovery-nudge.sh — needs-grill 検知 → notice 配送の単発 primitive（bd orch-s8c）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   orchestrator の courier 面（§5）の「nudge」を実体化する single-shot primitive。orch bd DB
#   （自 orch- bead + `bd repo sync` で hydrate された foreign copy）を `needs-grill` 平ラベルで
#   scan し、grill 待ちの bead を**気づかせる notice** へ落とす。courier の定期 `bd repo sync`
#   （pull hydrate・§3）の**後に**走る前提（同期は本 script の責務外）。
#
#   notice のみ・dispatch しない（load-bearing）: orchestrator は AI 自律で cross-project の
#   action（admin への作業指示・window 起動）を起こさない（§1 人間ドリブン / §5 notice 原則）。
#   本 primitive は「人間 or admin に気づかせる」までに徹し、window を**自動で建てない**（決定論点7）。
#
# 検知（scan）─────────────────────────────────────────────────────────────────────
#   `bd list -l needs-grill --json`（完全一致・`needs-grill` 平ラベル規約＝orch-74l §5.1）で
#   非 closed bead を拾う。走査述語は本 cell = **ラベル scan**（横断起票 seam = peer notes scan は
#   別述語・同期土台のみ courier 共通＝top-spec §5.1「検知の分割」）。read-only ゆえ bdw 不要。
#
# 配送（route・決定論点7）─────────────────────────────────────────────────────────
#   ★二役分離（addressing=台帳短名(prefix) / notice=registry(map 値)・orch-b52a）: 宛先解決（役①）と
#     人間 notice の project 表記（役②）は**別の値**を使う。役① addressing は bead の id prefix（= 台帳
#     短名 dolt_database = session 短名。fleet 全 project で実測一致する invariant）を直接使い、役②
#     notice は下記 prefix map の値（registry 名）を使う。旧実装は map 値を両役に兼用しており、
#     topology(1) land 後（session 名=台帳短名・orch-ajku）に addressing が乖離していた（例: `scribe:admin`
#     を組むが実 session は `sc`＝呼び鈴が live 窓へ点かない）。
#
#   各 needs-grill bead の id prefix から admin window の宛先正準形 `<prefix>:admin`（session:window・
#   orch-riz1 topology 裁定 orch-thgx＝window 名は素 'admin'・session 名=台帳短名が識別を担う）を組み、
#   その live 有無で分岐する —
#     (a) live admin window が在る → `session-comm.sh inject-file <window> <notice> \
#           --wait <s> --confirm-receipt <s>` で気づかせる（配送安全 flag は必須＝G申し送り）。
#     (b) 無い（orchestrator-owned・window 不在 等）→ 人間向け notice を print:
#           「needs-grill: <bead> — orch-spawn-admin <registry 名> で admin を建てて grill せよ」。
#           registry 名が map に無いときは**捏造せず**「registry 未登録・project 特定要」へ倒す。
#     (c) AI は自動で window を建てない / 作業 dispatch もしない（人間判断＝§5）。
#   ★addressing は map membership から decouple する（orch-b52a 設計裁定）: map 未収録の prefix でも
#     live な `<prefix>:admin` が在れば inject する（map coverage の穴で呼び鈴が死ぬのを避ける＝live 点灯が
#     本 primitive の趣意）。map 値は役②専用ゆえ、map 欠落は notice の registry 名が不明になるだけ。
#   例外: 自 prefix `orch` は addressing 対象にしない（自台帳に 2 人目 admin を建てる footgun 誘導を
#     増やさない＝orch-3c1・既存どおり人間 notice へ倒す）。
#   window 有無を確認できない（tmux 不在）ときは**安全側 = 人間 notice**へ倒す。
#
# orchestrator session 前提（誤台帳 scan の防止） ──────────────────────────────────
#   `bd list` は cwd の台帳に作用する。非 orch 台帳（scribe 'sc' / cc-session 'ccs' …）から走らせると
#   foreign DB を scan して誤 notice を撒く。よって起動時に「cwd から walk-up した最初の
#   .beads/metadata.json の dolt_database が orch か」を検査し非該当なら何もせず非 0 で抜ける
#   （orch-hydrate / spec-inject / guard と同一の session self-scope・同一 SELF_PREFIX）。
#
# prefix → project レジストリ（検証済 dolt_database 値・設定可能） ──────────────────
#   既定は下記 DEFAULT_PREFIX_MAP（`prefix=registry`）。値は **registry 名**（orch-spawn-admin /
#   orch-hydrate の registry name と整合）で、**人間 notice 専用＝役②**（`orch-spawn-admin <project>`
#   引数と notice 本文の project 表記）に使う。**addressing には使わない**（役①は id prefix＝台帳短名。
#   orch-spawn-admin は registry 名で照合するため map 値の短名化は unknown project で die する＝二役分離）。
#   env `ORCH_NUDGE_PREFIX_MAP`（空白区切り `prefix=registry` 列・値に空白不可）で全置換できる
#   （self-test / 将来の project 追加用）。
#   未知 prefix でも addressing は成立する（live 窓が在れば inject）。窓不在なら registry 名不明の
#   fallback notice（registry 名を捏造しない）。
#
# モード ────────────────────────────────────────────────────────────────────────
#   （既定）  実行: scan → live window へ inject / 無ければ人間 notice print。
#   --dry-run scan + 配送予定コマンド print のみ・**実 inject しない**（session-comm を呼ばない＝
#             self-test が hermetic）。timer/常駐 poll は本 primitive の scope 外（別 cell・held）。
#   --help    使い方（このヘッダブロック）。
#
# 使い方:
#   orch-discovery-nudge [--dry-run] [--help]
#
# env override（主に self-test 用・orch-spawn-admin の ORCH_SPAWN_CLD と同表現＝実体パス差替）:
#   ORCH_NUDGE_BD            scan に使う bd 実体パス（既定: bd）。fake ledger を hermetic に食わせる。
#   ORCH_NUDGE_TMUX          window 検出に使う tmux 実体パス（既定: tmux）。
#   ORCH_NUDGE_SESSION_COMM  session-comm.sh 実体パス（既定: ~/.claude/plugins/session/scripts/session-comm.sh）。
#   ORCH_NUDGE_PREFIX_MAP    prefix→registry 名 map を全置換（空白区切り `prefix=registry` 列・値に空白
#                            不可）。**人間 notice 専用**（addressing は id prefix ＝ map 非依存・orch-b52a）。
#   ORCH_NUDGE_WAIT_SECONDS     inject-file --wait 秒（既定: 60）。
#   ORCH_NUDGE_CONFIRM_SECONDS  inject-file --confirm-receipt 秒（既定: 30）。
#
# 検証: tests/scenarios/orch-discovery-nudge.bats（durable 回帰・hermetic＝bash -n + fake ledger(.beads
#   orch)/fake bd/tmux/session-comm で 実 dolt/tmux/inject を一切使わない・orch-3d4 で新設）を主とし、
#   worktree-local の selftest-orch-s8c.local.sh（untracked・fail-closed）を補助とする。

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
    echo "orch-discovery-nudge: 共有 self-scope lib 不在: $_ORCH_SESSION_LIB（self-scope 判定不能・fail-closed）" >&2
    exit 1
fi

# --- 既定 prefix → registry 名 map（人間 notice 専用＝役②・設定可能） -----------------------------
# 値は registry 名（orch-spawn-admin の引数形）。**addressing には使わない**（役①=id prefix＝台帳短名）。
# orch=orchestrator は orchestrator-owned（admin window 常駐せず＝人間が orch-spawn-admin で一時建て）。
# engine 既定は suite 内 registry 名（allowlist）のみ。private 配備層の連結先 prefix は env
# `ORCH_NUDGE_PREFIX_MAP`（空白区切り `prefix=registry 名` 列・全置換）で配備層が full 供給する
# （mechanism=public / value=private の分離＝engine に連結先実名を焼かない・map 値は notice 専用）。
DEFAULT_PREFIX_MAP=(
    "orch=orchestrator"
    "sc=scribe"
    "ccs=cc-session"
)

# 外部ツール（env で差替可・self-test 用）。
BD="${ORCH_NUDGE_BD:-bd}"
TMUX_BIN="${ORCH_NUDGE_TMUX:-tmux}"
SESSION_COMM="${ORCH_NUDGE_SESSION_COMM:-$HOME/.claude/plugins/session/scripts/session-comm.sh}"

# inject-file の配送安全 flag 秒（必須 flag・env で差替可）。
WAIT_SECONDS="${ORCH_NUDGE_WAIT_SECONDS:-60}"
CONFIRM_SECONDS="${ORCH_NUDGE_CONFIRM_SECONDS:-30}"

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            # 先頭コメントブロック（shebang 直後〜最初の非コメント行の手前）を help として出す。
            # 行番号を固定せず最初の非コメント行で打ち切るのでヘッダ伸縮に追従する（orch-hydrate と同型）。
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        *)
            echo "orch-discovery-nudge: unknown arg: $arg（--dry-run / --help のみ）" >&2
            exit 2
            ;;
    esac
done

# ─────────────────────────────────────────────────────────────────────────────
# ヘルパ
# ─────────────────────────────────────────────────────────────────────────────

# cwd の台帳 dolt_database の walk-up 解決（_ledger_dolt_database）は共有 lib scripts/hooks/lib/orch_session.sh
# が提供する（上で source 済み・orch-vo2）。旧 inline _resolve_dolt_database は _json_is_valid gate を欠く
# drift だったため撤去し、gate 済みの _ledger_dolt_database へ統一した（破損 orch-token metadata での誤
# self-scope を fail-closed で弾く・orch-degraded-watch と同型）。

# prefix → registry 名を echo（map に無ければ非 0・何も出さない）。役②（人間 notice）専用で、
# 宛先解決（役①）はこの関数を経由しない（orch-b52a 二役分離＝addressing は map membership から decouple）。
_map_prefix() {
    local want="$1" entry name val
    for entry in "${PREFIX_MAP[@]}"; do
        name="${entry%%=*}"; val="${entry#*=}"
        if [ "$name" = "$want" ] && [ "$name" != "$entry" ] && [ -n "$val" ]; then
            printf '%s' "$val"; return 0
        fi
    done
    return 1
}

# tmux に window <target>（session:window 正準形 `<台帳短名>:admin`）が存在するか（全 session 横断・完全一致）。
#   orch-riz1 topology（裁定 orch-thgx）: window 名は素 'admin' 維持・宛先は `<session>:<window>` で一意化する。
#   ゆえに列挙 format を `#{session_name}:#{window_name}` に統一し target と完全一致で照合する（session 名=台帳短名
#   が識別を担うため、複数 session が同名の素 admin 窓を持っても `<短名>:admin` で一意に到達できる＝曖昧一致しない）。
#   tmux 不在/サーバ無は「在らず」扱い＝安全側（window 確認不能なら人間 notice へ倒す）。
_window_exists() {
    local target="$1"
    "$TMUX_BIN" list-windows -a -F '#{session_name}:#{window_name}' 2>/dev/null | grep -qxF "$target"
}

# scan JSON（stdin）を "<id>\t<title>" 行へ。jq → grep フォールバック（fallback は title 空）。
# 注: top-level "id" のみ採る（dependencies の "issue_id"/"depends_on_id" は `"id"` に一致しない）。
_parse_scan() {
    if command -v jq >/dev/null 2>&1; then
        jq -r '.[]? | [.id, (.title // "")] | @tsv' 2>/dev/null
    else
        grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed -E 's/.*"id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1\t/'
    fi
}

# 該当 bead の notice 本文を file へ書く（inject-file は file を取る）。
#   二役分離（orch-b52a）: 宛先表記は prefix（台帳短名＝実 session 名）、project 表記は registry 名（役②）。
#   registry 名が map に無い（$project 空）ときは捏造せず「registry 未登録」と明示し短名で呼ぶ。
_write_notice() {
    local f="$1" id="$2" title="$3" project="$4" prefix="$5"
    local who="${project:-$prefix}"
    {
        printf '[orchestrator courier / discovery-nudge] needs-grill 検知\n'
        printf 'bead    : %s\n' "$id"
        [ -n "$title" ] && printf 'title   : %s\n' "$title"
        if [ -n "$project" ]; then
            printf 'project : %s (%s:admin)\n' "$project" "$prefix"
        else
            printf 'project : %s（registry 未登録・registry 名不明） (%s:admin)\n' "$prefix" "$prefix"
        fi
        printf '\n'
        printf 'この %s admin セッションで grill 待ちの bead があります。\n' "$who"
        printf '`bd show %s` で確認し、人間と grill して論点を詰めてください。\n' "$id"
        printf '(notice のみ・自動 dispatch ではありません＝action は人間判断)\n'
    } > "$f"
}

# ─────────────────────────────────────────────────────────────────────────────
# 前提検査: orchestrator session（cwd の台帳 dolt_database == orch）でなければ何もしない
# ─────────────────────────────────────────────────────────────────────────────
DB="$(_ledger_dolt_database "$PWD")"
if [ "$DB" != "$SELF_PREFIX" ]; then
    echo "orch-discovery-nudge: refusing to run — cwd の bd 台帳 dolt_database='$DB'（期待 '$SELF_PREFIX'）。" >&2
    echo "  orchestrator session（cwd=orchestrator）から実行せよ。foreign 台帳を誤 scan しない fail-closed。" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 配送安全 flag の fail-closed 検証（§5.2 横断 (a)(b)・twill 教訓「fallback が真実を隠す」・orch-3d4）
#   inject-file の --wait / --confirm-receipt は **必須**（送達 read-back を無効化させない）。秒値が
#   正整数（^[1-9][0-9]*$）でなければ起動時に die する＝orchestrator 側で先に弾き、(i) 0/空 で
#   confirm-receipt を黙って無効化する fail-open と (ii) session-comm 任せの mid-delivery 失敗（scan 後の
#   exit 1）の両方を構造的に塞ぐ。下流（配送ループの inject cmd）は session-comm の exit 4（＝未確認・
#   fallback 的な「投げっぱなし成功」を session-comm が返さず fail-loud にする契約）を成功扱いせず
#   failure として数える（同 (b)・本 script 下方の配送ループ inject 判定 `if "${cmd[@]}"` 分岐）。
#   session-comm.sh 本体は cc-session foreign ゆえ触らない（別 leg = orch-xyr / courier の領分）—
#   横断対策は呼び出し元（本 script）側で焼く。
# ─────────────────────────────────────────────────────────────────────────────
if ! [[ "$WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "orch-discovery-nudge: ORCH_NUDGE_WAIT_SECONDS は正整数（秒）必須（受領: '$WAIT_SECONDS'）。inject-file --wait を無効化させない。" >&2
    exit 2
fi
if ! [[ "$CONFIRM_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    echo "orch-discovery-nudge: ORCH_NUDGE_CONFIRM_SECONDS は正整数（秒）必須（受領: '$CONFIRM_SECONDS'）。--confirm-receipt は必須＝送達 read-back を無効化させない（twill 教訓「fallback が真実を隠す」）。" >&2
    exit 2
fi

# prefix map 解決（env override 優先・空白区切り prefix=project）。
PREFIX_MAP=()
if [ -n "${ORCH_NUDGE_PREFIX_MAP:-}" ]; then
    read -ra PREFIX_MAP <<< "$ORCH_NUDGE_PREFIX_MAP"
else
    PREFIX_MAP=("${DEFAULT_PREFIX_MAP[@]}")
fi

# 実行モードでは session-comm が要る（inject 実体）。dry-run は呼ばないので不要。
if [ "$DRY_RUN" = false ] && [ ! -x "$SESSION_COMM" ]; then
    echo "orch-discovery-nudge: session-comm not found/executable: $SESSION_COMM" >&2
    echo "  ORCH_NUDGE_SESSION_COMM で実体パスを差し替え可。" >&2
    exit 1
fi

# notice file 用の作業 dir（自動掃除）。
TMPDIR_WORK="$(mktemp -d "${TMPDIR:-/tmp}/orch-nudge.XXXXXX")" || {
    echo "orch-discovery-nudge: mktemp -d に失敗" >&2; exit 1
}
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# scan: needs-grill 平ラベルで非 closed bead を拾う（完全一致・read-only）
# ─────────────────────────────────────────────────────────────────────────────
mode_label="$([ "$DRY_RUN" = true ] && echo 'DRY-RUN' || echo 'EXEC')"
echo "== orch-discovery-nudge ($mode_label) =="
echo "  ledger DB     : $DB"
echo "  bd            : $BD"
echo "  session-comm  : $SESSION_COMM"
echo "  prefix map    : ${#PREFIX_MAP[@]} entries"
echo "----------------------------------------------------------------------"

SCAN_JSON="$("$BD" list -l needs-grill --json --no-pager --limit 0 2>/dev/null)"
scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
    echo "orch-discovery-nudge: scan 失敗（$BD list -l needs-grill --json・rc=$scan_rc）" >&2
    exit 1
fi

SCAN_TSV="$(printf '%s' "$SCAN_JSON" | _parse_scan)"

# needs-grill 無 → no-op（fail-safe・正常終了）。
if [ -z "${SCAN_TSV//[$' \t\n']/}" ]; then
    echo "no needs-grill beads — no-op"
    echo "----------------------------------------------------------------------"
    echo "summary: scanned=0 injected=0 noticed=0 failures=0 (mode=$mode_label)"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 配送: 各 bead を window 有無で route
# ─────────────────────────────────────────────────────────────────────────────
scanned=0; injected=0; noticed=0; failures=0

while IFS=$'\t' read -r id title; do
    [ -z "$id" ] && continue
    scanned=$((scanned + 1))

    prefix="${id%%-*}"

    # 役②（人間 notice の registry 名）: map 欠落は空のまま進む＝registry 名を捏造しない。
    project="$(_map_prefix "$prefix")" || project=""

    # 役①（addressing）: 宛先正準形 `<prefix>:admin`（session:window・orch-riz1 topology）。prefix は bead id の
    #   台帳短名（dolt_database）＝ orch-ajku land 後の実 session 名で、fleet 全 project で一致する invariant。
    #   ★map membership から decouple（orch-b52a 設計裁定）: map 未収録 prefix でも live 窓が在れば inject する
    #     （map coverage の穴で呼び鈴が死ぬのを避ける）。map 値（registry 名）は役②のみで使う。
    #   ★例外: 自 prefix orch は addressing しない（自台帳に 2 人目 admin を建てる footgun 誘導を増やさない
    #     ＝orch-3c1・従来どおり人間 notice へ倒す）。
    window="$prefix:admin"
    if [ "$prefix" != "$SELF_PREFIX" ] && _window_exists "$window"; then
        notice_file="$TMPDIR_WORK/notice-$prefix-$scanned.txt"
        _write_notice "$notice_file" "$id" "$title" "$project" "$prefix"
        cmd=("$SESSION_COMM" inject-file "$window" "$notice_file" \
             --wait "$WAIT_SECONDS" --confirm-receipt "$CONFIRM_SECONDS")
        if [ "$DRY_RUN" = true ]; then
            printf 'DRY-RUN inject [%s → %s]: would execute:' "$id" "$window"
            printf ' %q' "${cmd[@]}"; printf '\n'
            injected=$((injected + 1))
        else
            printf 'INJECT [%s → %s]:' "$id" "$window"
            printf ' %q' "${cmd[@]}"; printf '\n'
            # twill 教訓 (§5.2 横断 (b)): session-comm の exit code を**そのまま**真偽に使う。
            #   --confirm-receipt 経路は受理未確認で exit 4（fallback 的な「投げっぱなし成功」を返さない
            #   fail-loud 契約）を返すため、非 0 は injected に数えず failure として積む（silent success に
            #   しない）。failures>0 は末尾で exit 1 に集約され、未配送を黙って隠さない。
            if "${cmd[@]}"; then
                injected=$((injected + 1))
            else
                echo "  FAIL: inject failed/unconfirmed for $id → $window (session-comm rc=$?・exit4=未確認)" >&2
                failures=$((failures + 1))
            fi
        fi
    else
        # live window 無（or 自 prefix orch）→ 人間向け notice（AI は window を建てない）。
        #   registry 名（役②）が map に在れば orch-spawn-admin の引数として提示し、無ければ捏造せず
        #   「registry 未登録・project 特定要」へ倒す（短名を registry 名として渡させない）。
        if [ -n "$project" ]; then
            echo "NOTICE [$id]: needs-grill: $id — orch-spawn-admin $project で admin を建てて grill せよ"
        else
            echo "NOTICE [$id]: needs-grill: $id — 未知の prefix '$prefix'（registry 未登録・registry 名不明）。project を特定して orch-spawn-admin <project> で建てて grill せよ"
        fi
        noticed=$((noticed + 1))
    fi
done <<< "$SCAN_TSV"

echo "----------------------------------------------------------------------"
echo "summary: scanned=$scanned injected=$injected noticed=$noticed failures=$failures (mode=$mode_label)"

[ "$failures" -eq 0 ] || exit 1
exit 0

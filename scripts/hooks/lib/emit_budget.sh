# shellcheck shell=bash
# emit_budget.sh — hook stdout（＝context 注入）の予算を測って警告する共有 lib（source 専用・sc-mzhi）
#
# 役割: hook が注入する本文の大きさを **UTF-16 code unit（u16）** で実測し、warn 閾値を超えたときだけ
#       警告行を **stdout の先頭** へ前置してから本文を出す。予算超過を loud にするのが唯一の仕事で、
#       本文の内容には一切関与しない（truncate しない・並べ替えない・1 byte も削らない）。
#
# ★measure-then-emit（単一入口 API・orch-db47 leg(4) ■11-3）:
#   `scribe_emit_with_budget "<body>"` に本文を**丸ごと**渡す。lib が内部で u16 を実測し、超過なら warn を
#   先頭へ前置して **1 回で**出力する。`cat` の直流しや逐次 echo では「先頭に warn」が構造的に成立しない
#   （本文を出し始めた後では前置できない）ため、呼び手は本文を変数へ全量受けてから本 API へ渡すこと。
#
# ★u16 で測る理由（■8-1）: CC の context 予算は UTF-16 code unit で数える。bash の `${#var}` は u16 では
#   ない（UTF-8 locale では codepoint 数＝非 BMP を過小に、`LC_ALL=C` では byte 数＝日本語を過大に数える）。
#   `wc -c` / `wc -m` の代用も同じ理由で禁止。計測は python3 で utf-8 decode → strip → utf-16-le の byte 長
#   を 2 で割る、の一本に固定する。
#
# ★fail-open（■11-4・絶対条件）: python3 不在・計測失敗・閾値が非数値——どの degrade でも
#   **本文だけを出して exit 0**。本文注入を止めない・非 0 で終わらない・本文を truncate しない。
#   予算は「core の内容設計」で達成するものであって、この lib が切り詰めて達成するものではない（■8-4）。
#
# ★無出力経路では warn も出さない（■7）: body が空なら何も出さない。無条件出力にすると
#   「出力ゼロ」を assert する既存 test 群（`[ -z "$output" ]` 系）を一斉に壊す。
#
# 閾値（既定 warn 8,000 u16 / cliff 10,000 u16・■8-3/■8-8）:
#   - warn 8,000  … land 目標線。超えたまま land すると全セッションで warn が先頭に出続ける。
#   - cliff 10,000 … 失格線。超過時は warn を 2 行目まで増やして更に loud にする（それでも exit 0）。
#   どちらも env で上書きできる（`SCRIBE_EMIT_BUDGET_WARN_U16` / `SCRIBE_EMIT_BUDGET_CLIFF_U16`）。
#   この seam が無いと bats から warn を発火させられない（健全な実 hook は閾値を超えないため・■11-3）。
#   warn=0（または非数値・未設定扱い）は「警告を出さない」opt-out として扱う。
#
# 共用先 3 本（■11-1）: scripts/hooks/session-start-role-inject.sh /
#   scripts/hooks/session-start-mailbox-scan.sh / scripts/hooks/user-prompt-mailbox-scan.sh
# 対象外（■11-2）: session-start-guard-health.py（Python ゆえ bash lib を source 不可）/
#   session-boundary-heartbeat.sh / session-stop-push.sh（stdout 無出力が session-safety 要件）

SCRIBE_EMIT_BUDGET_WARN_U16_DEFAULT=8000
SCRIBE_EMIT_BUDGET_CLIFF_U16_DEFAULT=10000

# 数値正規化: 非数値・空は既定へ倒す（fail-open。閾値の壊れで本文注入を止めない）
_scribe_emit_budget_num() {
    case "${1:-}" in
        ''|*[!0-9]*) printf '%s' "$2" ;;
        *)           printf '%s' "$1" ;;
    esac
}

# stdin の本文を u16 で数えて stdout へ出す。計測不能なら非 0（呼び手は fail-open で本文だけ出す）。
# ※ 下の python3 一行が **計測の実体**（mutation teeth の標的・■11-5 の 5 本目）。
#
# ★計測は必ず時間で bound する（sc-mzhi self-review major）: measure-then-emit ゆえ本文の printf は
#   **必ず計測の後**に来る。python3 を無制限に待つと、hang / 極端に遅い環境（pyenv・conda 等の shim、
#   stale NFS 上の home、ロック待ちの wrapper）で hook 自体が wire の timeout（hooks/hooks.json は
#   SessionStart / UserPromptSubmit とも 10,000ms）で kill され、**stdout が 1 byte も出ない**。
#   実測された壊れ方: role-inject → admin 役割規約の注入が丸ごと消失（wire は `|| true` ゆえ silent）、
#   mailbox → dedupe seed だけ焼けて一度も surface されない＝配送保証の恒久破壊。
#   ゆえに fail-open の fence は「python3 *不在*」だけでなく「**遅い / 固まる python3**」も塞ぐ必要がある。
#   bound の書き方は既存慣行（lib/mailbox-common.sh の mbx_direct_read）と同型＝`command -v timeout`
#   guard 付き。timeout 不在ホストでは従来どおり素で呼ぶ（bound できない環境で機能を落とさない）。
#   timeout の rc!=0（124=時間切れ / 125=timeout 自体の失敗）と空出力は、呼び手 scribe_emit_with_budget
#   の既存 fail-open 分岐がそのまま拾う＝本文は必ず出る。
#
# ★bound は「hook の wire 予算」と**合成**して決める（sc-mzhi self-review 2 巡目 major）: 本 bound は
#   hook 内で唯一の待ちとは限らない。呼び手が既に別の bound を払っていると **和** が wire timeout
#   （hooks/hooks.json: SessionStart / UserPromptSubmit とも 10,000ms）を超え、本 lib が塞いだはずの
#   total-loss を別経路で作り直す。実測: session-start-mailbox-scan は emit の前に mbx_direct_read の
#   8s bound を払うため、旧既定 3s との和は 8+3 で 10.06s＝wire 超過（しかも dedupe seed は emit の
#   **前**に焼き終えている＝「seen 済みなのに一度も surface されない」配送保証の恒久破壊）。
#   ゆえに既定を **1s** とし、「どの呼び手の残り予算にも収まる」側へ倒す（計測を諦めても失うのは warn
#   だけ＝本文は fail-open で必ず出る。非対称な損害の小さい方を既定にする）。
#   残り予算に余裕がある呼び手は source 後に SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC で上書きしてよい
#   （例: role-inject は emit 前に別 bound を持たないので 3s）。上書き時は「他の bound の和 + 本 bound
#   < 10s」を呼び手のコメントに算術で書き残すこと。
SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC_DEFAULT=1
scribe_emit_budget_measure_u16() {
    command -v python3 >/dev/null 2>&1 || return 1
    local _py='import sys
data = sys.stdin.buffer.read().decode("utf-8", "replace").strip()
sys.stdout.write(str(len(data.encode("utf-16-le")) // 2))
'
    local _t
    # 呼び手が env / 変数で上書きできる seam（非数値・空は既定へ倒す＝fail-open）
    _t="$(_scribe_emit_budget_num "${SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC:-}" "$SCRIBE_EMIT_BUDGET_MEASURE_TIMEOUT_SEC_DEFAULT")"
    if command -v timeout >/dev/null 2>&1; then
        timeout "$_t" python3 -c "$_py" 2>/dev/null
    else
        python3 -c "$_py" 2>/dev/null
    fi
}

# scribe_emit_with_budget <body> [label]
#   本文を丸ごと受け、u16 を実測し、warn 超過時のみ警告を **先頭** へ前置して一括出力する。
#   常に 0 を返す（fail-open）。body が空なら無出力（warn も出さない）。
scribe_emit_with_budget() {
    local body="${1:-}" label="${2:-scribe}" n warn cliff

    [ -n "$body" ] || return 0            # 無出力経路（degrade / opt-out）では warn も出さない（■7）

    warn="$(_scribe_emit_budget_num "${SCRIBE_EMIT_BUDGET_WARN_U16:-}" "$SCRIBE_EMIT_BUDGET_WARN_U16_DEFAULT")"
    cliff="$(_scribe_emit_budget_num "${SCRIBE_EMIT_BUDGET_CLIFF_U16:-}" "$SCRIBE_EMIT_BUDGET_CLIFF_U16_DEFAULT")"

    # 計測（失敗＝空 → 警告を諦めて本文だけ出す＝fail-open・■11-4）
    n="$(printf '%s' "$body" | scribe_emit_budget_measure_u16 2>/dev/null)" || n=""
    case "$n" in ''|*[!0-9]*) n="" ;; esac

    if [ -n "$n" ] && [ "$warn" -gt 0 ] 2>/dev/null && [ "$n" -gt "$warn" ] 2>/dev/null; then
        printf '%s\n' "⚠️ [scribe/emit-budget] ${label}: 注入本文 ${n} u16 が warn 閾値 ${warn} u16 を超過しています（cliff ${cliff} u16）。本文は truncate していません（fail-open）——予算は本文の内容設計で回復してください。"
        if [ "$n" -gt "$cliff" ] 2>/dev/null; then
            printf '%s\n' "⚠️ [scribe/emit-budget] ${label}: cliff ${cliff} u16 も超過（${n} u16）＝失格線です。最重要ペイロードが毎セッション圧迫されています。"
        fi
    fi

    printf '%s\n' "$body"
    return 0
}

#!/usr/bin/env bash
# orch_slate.sh — 計画 slate（何を・どの project で・なぜ）の記録 + 参照 interlock の共有 shell lib
#                 （bd orch-vswk・orch-6srt 裁定-safeguards(3)）
#
# 役割 ─────────────────────────────────────────────────────────────────────────
#   spawn/dispatch 前の「計画 slate」を自台帳 orch- bead へ機械記録し、orch-dispatch / orch-spawn-admin の
#   spawn 実行経路が slate 参照を **必須の機械 interlock**（slate 無し→fail-closed 拒否）とするための単一 SSOT。
#   slate は通知 carrier だけでなく merge-ratify ① baseline（事前合意逸脱検知の基準線）を兼ねる（orch-6srt）
#   ＝auto-merge が最も効く self-dev track こそ baseline 必須。ゆえに interlock 発火 scope は self-dev を含む
#   全 spawn 経路（foreign-only exempt 分岐は作らない・gate-1 裁定 orchestrator 2026-07-16）。
#   記録ロジックと参照 interlock を 1 本化し dispatch/spawn-admin は source consume する（byte 複製禁止＝
#   orch_anchor.sh / orch_session.sh と同型）。**入口は read-only 参照のみで auto-record しない**（記録は別
#   helper `_orch_slate_record`・別 turn＝orchestrator が bundle 頭で 1 回叩く。auto-create-per-dispatch は
#   1 slate=1 bundle 違反ゆえ非採用）。slate read/write は自台帳 orch の read-only / bdw 直列化 write。
#
# 参照機構スキーマ（silently-choose 禁止・本 file が SSOT）─────────────────────────
#   - 識別: 自台帳 orch- bead を **平ラベル `slate`（完全一致）** + notes 行頭 sentinel **`[ORCH-SLATE v1]`** で識別。
#           label だけ / sentinel だけの bead は valid slate と看做さない（両方必須＝誤検知防止・fail-closed 寄り）。
#   - 対象列挙（**canonical machine form を本 file で確定**）: notes の **単一 `members:` 行**に
#           `members: orch-a, orch-b, project-x` の形（**comma または whitespace 区切り**）で列挙する。
#           対象は **{bead-id ∪ target-project} の union キー**（dispatch は bead-id を、spawn-admin は
#           target-project を同一 members 集合へ照合する）。`_orch_slate_record` はこの form を書き、
#           reader（`_orch_slate_open_members`）は `members:` 行を comma/whitespace split で読む＝record と read が
#           同一 form を共有する（「1 行 1 id」等の別 form は本実装では採らない＝ambiguity を silently-choose しない）。
#   - 予約 label/sentinel は一切踏まない: 予約 label（gate-pending / for:* / needs-orch / needs-orch-ack /
#           needs-grill / held / courier / coord / follow-up / seam / auto-compact-fired）と予約 sentinel
#           （行頭 `[SPAWNED--` / `[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT`）とは非衝突（`slate` / `[ORCH-SLATE v1]`）。
#
# interlock は集合メンバーシップ照合（空虚 interlock 禁止）────────────────────────
#   dispatch 側は「dispatch する bd-id が open slate の members 集合に属す」、spawn-admin 側は「spawn する
#   project が open slate の targets に列挙される」を機械照合し、非属は fail-closed。単なる「slate が 1 件でも
#   存在すれば pass」は禁止（false-green）。照合は open slate 群の members 和集合に対して行う。
#
# lifecycle = bundle 完了で close ───────────────────────────────────────────────
#   slate bead は **活動中（列挙 4 status）=活動 bundle** / bundle 完了（gate→close+cleanup）で close する
#   （orchestrator 責務）。dispatch した slate bead が worker cell の `--claim` で in_progress 化しても
#   slate は生きる（bd orch-1dcd＝status で bundle の生死を決めるのは close だけ）。open 放置は
#   orch-stale-scan の母集団を汚染するため既定は close 運用（top-spec slate 節に明記）。
#
# 既知限界（status 集合を広げた代償・bd orch-1dcd）───────────────────────────────
#   - **列挙 4 値は「全非 closed」ではない（実 bd 照会 verified 2026-07-25・bd v1.1.0）**: `bd statuses` の
#     built-in は **7 値**（open / in_progress / blocked / deferred / closed に加え **pinned**〔frozen・
#     "Persistent, stays open indefinitely"〕と **hooked**〔wip・"Attached to an agent's hook"〕）で、両者は
#     filter token として実在する（pinned / hooked とも list filter に渡すと rc=0・不存在 token は rc=1）。
#     一方 `bd list --help` の `--status` 説明は 5 値しか挙げず bd 自身の doc が不整合。本 file が列挙するのは
#     **help の 5 値のうち非 closed の 4 値**であって全非 closed ではない＝**pinned / hooked へ遷移した slate は
#     列挙外に落ち、本 filter が解消した bundle 自殺（自分の slate を自分で殺し以降の dispatch/spawn が全て
#     fail-closed 拒否）が同型で再発する**。とくに hooked は「agent の hook に attach」＝worker `--claim`→
#     in_progress と同じ agent 起因遷移クラスで、この filter 拡張の根拠がそのまま当てはまる modality。
#     採用時点の実測分布は pinned・hooked とも 0 件ゆえ **latent**（live 破壊ではない）。filter 集合の 4 値は
#     bd orch-1dcd 契約で確定（再議しない）ゆえ **pinned / hooked の採否は follow-up**。
#   - bundle 完了後に close し忘れた slate は members を permit し続ける（歯止めは bundle-close 規律のみ）。
#   - orch-stale-scan の母集団は open,deferred ゆえ in_progress の slate は age 検知線から構造的に外れる。
#     clean-state-probe 核(a) も snapshot 付き in_progress のみ RED（snapshot 無しは info 止まり）＝
#     close 忘れ slate を機械検知する線は現状ない。検知線の新設（surface への status 表示 / tripwire 内訳 /
#     stale-scan 母集団拡張）は follow-up。
#   - **2 コピー同期義務（本 file は engine copy＝boot path 側・bd sc-xy9n）**: 同一機構は private 配備層の
#     local copy（配備層 repo の scripts/lib/orch_slate.sh）にも在り、SessionStart 第5節の slate surface は
#     **engine copy 単独**が担う（engine hook scripts/hooks/session-start-workinprogress.sh が
#     `$PLUGIN_ROOT/scripts/lib/orch_slate.sh --surface` を実行＝workinprogress は engine 一本化）。片方だけ
#     直すと「interlock は通るが人間には見えない／逆」の非対称が deployment に残る（実発生: bd orch-1dcd が
#     local のみ status-aware 化し boot path が status-blind のまま残り、活動中 bundle でも毎起動
#     `[SLATE-NONE]` を表示し続けた＝bd sc-xy9n が本 file を同期）。status 意味論を変えるときは **両 copy を
#     同一便で動かす**。この drift を RED にする機械検知線は現状無い（keep-set parity の対象 script に
#     orch_slate.sh は含まれない）＝運用義務。**本 bullet が主張するのは status 意味論の同期（bd sc-xy9n）だけ**
#     であり両 copy の parity 達成ではない＝**直下の項を必ず併読**すること。
#   - **status filter 以外の未同期 drift が本 file に残存する（bd orch-3d07・over-permit＝fail-open）**:
#     members 抽出の **行頭 sentinel アンカー / co-location 要件**（private 配備層の local copy には land 済み）は
#     本 file へ **未同期**で、下の `_orch_slate_members_of` は sentinel を **行中 search** で拾う。ゆえに散文が
#     sentinel を **行内引用** した行の `members:` まで harvest し、**計画外の bead-id / project が interlock を
#     通る**（over-permit＝interlock が計画適合性 gate として空虚化する。engine は PUBLIC 配布物ゆえ、他 adopter に
#     とっては本 file が唯一の copy）。hermetic 実測（2026-07-26・本便 worktree）: notes が canonical 行
#     `[ORCH-SLATE v1] members: orch-aaa` と散文行 `note: previously [ORCH-SLATE v1] members: orch-evil was burned`
#     の 2 行のとき、本 file は和集合へ引用行の token を混入させ `_orch_slate_has_member orch-evil` が rc=0（pass）
#     ／行頭アンカー済みの local copy は同 fixture で `orch-aaa` のみ返し reject する。**本項は「片方の drift
#     （status filter）を直しただけでは parity ではない」ことの SSOT** で、上の 2 コピー同期義務を parity 達成と
#     読んではならない。本 file への port は follow-up（配備層側 keep-set parity teeth へ本 file を編入する leg =
#     bd orch-da33。その再開 trigger が bd orch-3d07 の land＝land 済みゆえ実行可能）＝本便（bd sc-xy9n）の契約
#     scope 外（本便の契約は status filter 同期のみ）。
#
# 検証: 本 file の `--self-test`（直接実行時のみ・hermetic・fail-closed）+ consumer の bats
#   （tests/scenarios/orch-slate.bats・orch-dispatch.bats・orch-spawn-admin.bats）。
#   **plugin 反映には新規 cld session 必須**。

# 識別子（SSOT）。consumer は自前に文字列を持たず本 file の値を参照する。
ORCH_SLATE_LABEL="slate"
ORCH_SLATE_SENTINEL="[ORCH-SLATE v1]"
# 自台帳 prefix（bd-write-guard / orch_session の SELF_PREFIX と同値・foreign copy を弾く filter に使う）。
# caller が別値を必要とするなら export で上書き可（既定 orch）。
: "${ORCH_SLATE_SELF_PREFIX:=orch}"

# 活動中 slate bead の id を列挙（read-only）。$1=bd 実体, $2=anchor（bd graph 所在）。
#   `bd -C <anchor> list --label slate --status <活動中 4 値> --limit 0 --json` を読み、id が自台帳
#   prefix（orch-）で始まる bead のみ返す（連結 substrate hydrate で混在する foreign copy を排除）。
#   bd read 失敗は rc=1（fail-closed）。
#   ★status 集合＝**`bd list --help` が列挙する 5 値のうち非 closed の 4 値**を明示列挙
#     （open / in_progress / blocked / deferred・bd orch-1dcd）。**全非 closed ではない**（`bd statuses` の
#     built-in は pinned / hooked を含む 7 値＝上の 既知限界 を必ず併読すること）:
#     slate bead は dispatch 後に worker cell の `--claim` で in_progress 化するため、open 固定だと自分の
#     bundle の slate を自分で殺し、以降の dispatch/spawn が全て fail-closed 拒否される（実運用停止を実測）。
#     blocked（human ratify 待ち）/ deferred へ落ちた slate も同型 brick ゆえ同時に列挙する。**bd が status を
#     増やしたら（あるいは pinned / hooked を採用したら）この 1 行を更新する**（closed のみ除外＝bd 既定 filter
#     に依存する形は採らない＝明示列挙。運用義務に機械検知線は無い＝既知限界）。
#     禁止形: 同じ status flag を 2 回渡す形（bd は repeat を silently overwrite し先の値が消える）／
#     全件取得（`--all`）+ reader 側で closed を落とす形（bd 既定 limit 50 の截断が filter より前に起き
#     活動中 slate が silent に落ちる＝この filter が直している brick の再発）。
#     status リテラルは**コード中 1 箇所（直下の query 行）のみ**に置く＝surface path と interlock path が
#     同一 filter を共有する（片方だけ効く「見えるが通らない/通るが見えない」非対称を構造的に作らない）。
#     ★この「同一 filter 共有」が成り立つのは**本 file を source する経路の中だけ**である（engine copy 内では
#       boot path〔hook の --surface〕と interlock path〔dispatch / spawn-admin〕の双方が本 file を source
#       するため両者は常に同一 filter）。**copy 境界を越える parity は機械保証されない**＝上の 既知限界
#       （2 コピー同期義務）を必ず併読すること。
#   名前の注記: helper 名の `open` は歴史的名称（rename しない・consumer 契約）。意味は「活動中 slate」。
_orch_slate_open_ids() {
    local bd="$1" anchor="$2" json
    json="$("$bd" -C "$anchor" list --label "$ORCH_SLATE_LABEL" --status open,in_progress,blocked,deferred --limit 0 --json 2>/dev/null)" || return 1
    [ -n "$json" ] || return 0
    printf '%s' "$json" | python3 -c '
import json,sys
pref=sys.argv[1]+"-"
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(2)
rows=d if isinstance(d,list) else ([d] if isinstance(d,dict) else [])
for o in rows:
    if not isinstance(o,dict): continue
    i=o.get("id","") or ""
    if isinstance(i,str) and i.startswith(pref):
        print(i)
' "$ORCH_SLATE_SELF_PREFIX" 2>/dev/null || return 1
}

# 指定 slate bead の notes から members を抽出（read-only）。$1=bd, $2=anchor, $3=slate bead-id。
#   `bd show <id> --json` の notes に行頭 sentinel [ORCH-SLATE v1] が在る場合のみ、`members:` 行を
#   comma/whitespace split して 1 行 1 member で出力（sentinel 不在 slate は空＝valid 対象を持たない）。
#   bd read / parse 失敗は rc=1（fail-closed）。
_orch_slate_members_of() {
    local bd="$1" anchor="$2" sid="$3" json
    json="$("$bd" -C "$anchor" show "$sid" --json 2>/dev/null)" || return 1
    [ -n "$json" ] || return 0
    printf '%s' "$json" | python3 -c '
import json,sys,re
sent=sys.argv[1]
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(2)
o=d[0] if isinstance(d,list) and d else (d if isinstance(d,dict) else None)
if not isinstance(o,dict):
    sys.exit(0)
notes=o.get("notes","") or ""
# 行頭 sentinel（先頭空白のみ許容）が無ければ valid slate でない＝members ゼロ。
if not any(re.match(r"\s*"+re.escape(sent), ln) for ln in notes.splitlines()):
    sys.exit(0)
# canonical form は sentinel と members: が同一行（[ORCH-SLATE v1] members: a, b）ゆえ行中 search で拾う。
# ★members 抽出を sentinel 行へ束縛する（writer は sentinel と members を co-located canonical form で焼く）。
#   sentinel を含まない行の prose `members:`（既存 bead の前歴 notes 由来）を拾うと interlock を false-green 化
#   しうる（over-permit＝計画外 dispatch/spawn を pass させる）ため、sentinel を含む行のみ対象にする。
# ★既知限界（本 file 未同期・bd orch-3d07）: この束縛は **行中 search** ゆえ「散文が sentinel を **行内引用** した
#   行」も sentinel 行と看做し、その行の members: を harvest する（over-permit＝fail-open・hermetic 実測で確認）。
#   private 配備層の local copy は行頭アンカー（re.match）済み＝本 file への port は follow-up（file 冒頭の
#   既知限界 節を参照）。
# \b で "remembers:" 等の誤ヒットを防ぐ（word boundary）。
for ln in notes.splitlines():
    if not re.search(re.escape(sent), ln): continue   # sentinel 行のみ（stray prose members: を排除）
    m=re.search(r"\bmembers\s*:\s*(.*)$", ln, re.IGNORECASE)
    if not m: continue
    for tok in re.split(r"[,\s]+", m.group(1).strip()):
        if tok:
            print(tok)
' "$ORCH_SLATE_SENTINEL" 2>/dev/null || return 1
}

# 全 open slate の members 和集合を出力（read-only・dedupe）。$1=bd, $2=anchor。
#   bd read / parse 失敗（open_ids or members_of の rc=1）は rc=1 で伝播（fail-closed）。空出力は
#   「open slate 無し or members 未列挙」＝どちらも interlock 側で fail-closed 拒否対象（呼び元判断）。
_orch_slate_open_members() {
    local bd="$1" anchor="$2" ids id
    ids="$(_orch_slate_open_ids "$bd" "$anchor")" || return 1
    [ -n "$ids" ] || return 0
    local all=""
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        local m
        m="$(_orch_slate_members_of "$bd" "$anchor" "$id")" || return 1
        [ -n "$m" ] && all+="$m"$'\n'
    done <<< "$ids"
    [ -n "$all" ] && printf '%s' "$all" | grep -v '^[[:space:]]*$' | sort -u
    return 0
}

# interlock 本体: <member> が open slate の members 和集合に属すか（read-only・完全一致行照合）。
#   $1=member, $2=bd, $3=anchor。rc=0=属す（pass）/ rc=1=非属 or slate 無し（fail-closed 拒否）/
#   rc=2=bd read/parse 失敗（fail-closed 拒否・read 不能）。呼び元は rc≠0 を die 材料にする。
#   ★「slate が存在すれば pass」でなく members 集合照合＝空虚 interlock を構造的に禁止する。
_orch_slate_has_member() {
    local member="$1" bd="$2" anchor="$3" members rc
    members="$(_orch_slate_open_members "$bd" "$anchor")"; rc=$?
    [ "$rc" -eq 0 ] || return 2
    [ -n "$members" ] || return 1
    printf '%s\n' "$members" | grep -qxF -- "$member" && return 0
    return 1
}

# slate 記録 helper（別 turn・orchestrator が bundle 頭で 1 回叩く・auto-record しない）。
#   $1=bdw 実体, $2=anchor, $3=stamp 対象 orch- bead-id, $4..=member（bead-id / project 名の混在可）。
#   既存 orch- bead を slate として stamp する: 平ラベル slate 付与 + notes へ sentinel+members 行を append。
#   write は bdw 経由（自台帳 write 直列化の正路・un-8p7）＝呼び元は orchestrator context（worker でない）。
#   members は canonical form（`[ORCH-SLATE v1] members: a, b, c`）で 1 行に焼く。bdw の rc をそのまま返す。
_orch_slate_record() {
    local bdw="$1" anchor="$2" sid="$3"; shift 3
    [ -n "$sid" ] || return 2
    [ "$#" -ge 1 ] || return 2
    local csv=""
    local m
    for m in "$@"; do
        [ -n "$m" ] || continue
        if [ -z "$csv" ]; then csv="$m"; else csv="$csv, $m"; fi
    done
    [ -n "$csv" ] || return 2
    ( cd "$anchor" 2>/dev/null || exit 1
      "$bdw" update "$sid" --add-label "$ORCH_SLATE_LABEL" \
          --append-notes "$ORCH_SLATE_SENTINEL members: $csv" )
}

# open 計画 slate の read-only surface（bd orch-cqf4 Leg-A・薄い合成）。
#   既存 helper（_orch_slate_open_ids / _orch_slate_members_of / _orch_slate_open_members）を合成するだけで
#   slate schema 知識（label / sentinel / members form）は本 lib SSOT に留める（stale-scan にも hook にも複製しない）。
#   出力: 各 open slate bead id + members 行 + [SLATE-TRIPWIRE] 集計行。read-only surfacing 専任（write ゼロ）。
#   fail-open: bd read 失敗（open_ids rc≠0）は [SLATE-UNKNOWN] note で exit 0（brick しない）。
#   bd 実体は $1 or ORCH_SLATE_BD（既定 bd）・anchor は $2 or ORCH_SLATE_ANCHOR（既定 orch_anchor.sh の
#   _resolve_scriptorium〔E2 検証付き〕→ 非解決時は [SLATE-UNKNOWN] fail-loud で return 0＝engine は
#   deploy-layout 依存の hardcode fallback を持たない）。
_orch_slate_surface() {
    local bd="${1:-${ORCH_SLATE_BD:-bd}}"
    local anchor="${2:-${ORCH_SLATE_ANCHOR:-}}"
    if [ -z "$anchor" ]; then
        # anchor 未指定 → 同 dir の共有 lib orch_anchor.sh を lazy source して _resolve_scriptorium（E2 検証付き）。
        #   direct-exec 経路でのみ通る（consumer は自前に bd/anchor を渡す）ため lib top-level を汚さない。
        local _sl_self _sl_dir
        _sl_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
        _sl_dir="$(cd "$(dirname "$_sl_self")" 2>/dev/null && pwd || echo .)"
        if [ -r "$_sl_dir/orch_anchor.sh" ]; then
            # shellcheck source=scripts/lib/orch_anchor.sh
            . "$_sl_dir/orch_anchor.sh"
            anchor="$(_resolve_scriptorium 2>/dev/null || true)"
        fi
    fi
    # anchor 解決不能は fail-loud（engine は deploy-layout hardcode fallback を持たない）。
    #   read-only surfacing ゆえ brick はしない（return 0）が、誤った hardcode anchor を黙って使わない。
    if [ -z "$anchor" ]; then
        echo "[SLATE-UNKNOWN] anchor 解決不能（fail-loud・engine は hardcode fallback を持たない）: ORCH_SLATE_ANCHOR / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ" >&2
        return 0
    fi

    local ids rc
    ids="$(_orch_slate_open_ids "$bd" "$anchor")"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "[SLATE-UNKNOWN] open 計画 slate 判定不能（bd read 失敗・fail-open・read-only surfacing のみ）"
        return 0
    fi

    echo "── open 計画 slate（read-only surface・1 slate=1 bundle・schema SSOT=orch_slate.sh） ──"
    if [ -z "$ids" ]; then
        echo "  [SLATE-NONE] open 計画 slate なし"
        echo "[SLATE-TRIPWIRE] open slate:0 members(union):0"
        return 0
    fi

    local n_slate=0 id
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        n_slate=$((n_slate + 1))
        local m mcsv mm
        m="$(_orch_slate_members_of "$bd" "$anchor" "$id" 2>/dev/null)"
        mcsv=""
        while IFS= read -r mm; do
            [ -n "$mm" ] || continue
            if [ -z "$mcsv" ]; then mcsv="$mm"; else mcsv="$mcsv, $mm"; fi
        done <<< "$m"
        echo "  [SLATE] $id members: ${mcsv:-（members 未列挙）}"
    done <<< "$ids"

    local union n_member=0
    union="$(_orch_slate_open_members "$bd" "$anchor" 2>/dev/null)"
    if [ -n "$union" ]; then
        n_member=$(printf '%s\n' "$union" | grep -c .)
    fi
    echo "[SLATE-TRIPWIRE] open slate:$n_slate members(union):$n_member"
    return 0
}

# === --self-test: 直接実行時のみの hermetic 自己完結テスト（fail-closed・orch-vswk） ===
# source 時（BASH_SOURCE[0] != $0）はこのブロックを skip する（consumer の $1 継承で誤発火しない）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    case "${1:-}" in
        --surface)
            # read-only surface（open slate 列挙・schema SSOT は本 lib helper に留める・orch-cqf4 Leg-A）。
            _orch_slate_surface; exit $? ;;
        --self-test)
            : ;;  # 下の self-test ブロックへ落ちる。
        *)
            echo "orch_slate.sh は source して使う共有 lib です（--surface で open slate 列挙 / --self-test で自己検証）。" >&2
            exit 0 ;;
    esac

    st_fail=0
    st_tmp="$(mktemp -d -t orch-slate-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT
    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    mkdir -p "$st_tmp/bin" "$st_tmp/anchor"

    # hermetic bd stub: `list --label slate ... --json` → $SLATE_LIST_JSON,
    #   `show <id> --json` → $SLATE_SHOW_JSON（未 set は []）。`-C <anchor>` は剥がす。BD_FAIL=1 で非0。
    # ★status-aware（bd orch-1dcd）: 実 bd の `--status <csv>` filter を模す＝指定 status の行のみ返す。
    #   status を無視する stub だと「open 固定 query でも in_progress slate が返る」偽環境になり、本 filter の
    #   teeth も mutation も空虚化する（status-blind stub では未修正コードでも緑）。契約:
    #     - `--status` / `-s` の csv を解析し行 status で filter（行に status field が無ければ open 扱い）
    #     - `--status` 未指定は実 bd 既定＝closed 以外を返す
    #     - flag が複数回来たら **最後の値のみ**採用（実 bd の documented な silently-overwrite 挙動）
    #     - 未知 status token は rc=1（実 bd と同じく失敗させる＝typo を緑にしない）
    #   KNOWN は `bd statuses` の built-in **実 7 値**（pinned / hooked を含む・実 bd 照会 verified 2026-07-25）で、
    #   `bd list --help` の 5 値ではない。実集合に揃えるのは (a) 未知 token 判定を実 bd と同義にするため
    #   (b) 将来 filter へ pinned / hooked を足したとき stub が rc=1 を返して正しい拡張を封鎖する逆流を消すため。
    cat > "$st_tmp/bin/bd" <<'STUB'
#!/usr/bin/env bash
[ -n "${BD_FAIL:-}" ] && exit 1
while [ "${1:-}" = "-C" ] || [ "${1:-}" = "--directory" ]; do shift 2; done
_status=""; _prev=""
for _a in "$@"; do
  case "$_prev" in --status|-s) _status="$_a" ;; esac   # repeat は最後の値のみ採用
  _prev="$_a"
done
case "$1" in
  list)
    ORCH_SLATE_STUB_STATUS="$_status" python3 - "${SLATE_LIST_JSON:-[]}" <<'PY'
import json, os, sys
KNOWN = {"open", "in_progress", "blocked", "deferred", "closed", "pinned", "hooked"}  # bd statuses 実 7 値
raw = os.environ.get("ORCH_SLATE_STUB_STATUS", "")
if raw:
    allowed = {t for t in raw.split(",") if t}
    bad = allowed - KNOWN
    if bad:
        sys.stderr.write("stub bd: unknown status: %s\n" % ",".join(sorted(bad)))
        sys.exit(1)
else:
    allowed = KNOWN - {"closed"}          # 実 bd 既定＝closed 以外
try:
    data = json.loads(sys.argv[1])
except Exception:
    sys.stdout.write("[]"); sys.exit(0)
rows = data if isinstance(data, list) else []
out = [r for r in rows if (not isinstance(r, dict)) or r.get("status", "open") in allowed]
sys.stdout.write(json.dumps(out))
PY
    exit $? ;;
  show) printf '%s' "${SLATE_SHOW_JSON:-[]}" ;;
  *)    printf '%s' "[]" ;;
esac
exit 0
STUB
    chmod +x "$st_tmp/bin/bd"

    # hermetic bdw stub: argv を記録するだけ（record helper の write 観測用）。BDW_FAIL=1 で非0。
    export BDW_MARK="$st_tmp/bdw-args.txt"; : > "$BDW_MARK"
    cat > "$st_tmp/bin/bdw" <<'STUB'
#!/usr/bin/env bash
printf 'BDW %s\n' "$*" >> "$BDW_MARK"
[ -n "${BDW_FAIL:-}" ] && exit 1
exit 0
STUB
    chmod +x "$st_tmp/bin/bdw"
    BD="$st_tmp/bin/bd"; BDW="$st_tmp/bin/bdw"; ANC="$st_tmp/anchor"

    # (1) member 属す → has_member rc=0（pass）。
    export SLATE_LIST_JSON='[{"id":"orch-slate1"}]'
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"blah\n[ORCH-SLATE v1] members: orch-aaa, orch-bbb, folio\nmore"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then _ok "has_member: 属す bead-id は pass（rc=0）"
    else _fail "has_member: orch-aaa は members に在るのに reject された"; fi
    # union キー: project 名（folio）も同一 members 集合で照合できる。
    if _orch_slate_has_member "folio" "$BD" "$ANC"; then _ok "has_member: union キー project 名(folio)も pass"
    else _fail "has_member: project 名 folio が members に在るのに reject された"; fi

    # (2) member 非属 → rc=1（fail-closed 拒否）。空虚 interlock（存在だけで pass）でないことを pin。
    if _orch_slate_has_member "orch-zzz" "$BD" "$ANC"; then
        _fail "has_member: 非属 orch-zzz が pass した（空虚 interlock＝slate 存在だけで通す退行）"
    else _ok "has_member: 非属 bead-id は reject（rc≠0・集合照合が存在照合でない）"; fi

    # (3) open slate 無し → rc=1（fail-closed）。
    export SLATE_LIST_JSON='[]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then
        _fail "has_member: open slate 無しで pass した（fail-closed 破れ）"
    else _ok "has_member: open slate 無しは reject（fail-closed）"; fi

    # (4) sentinel 不在の label-only slate → members ゼロ扱いで reject（両方必須の teeth）。
    export SLATE_LIST_JSON='[{"id":"orch-slate1"}]'
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"members: orch-aaa\n（sentinel 無し）"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then
        _fail "has_member: sentinel 無し label-only slate で pass した（識別=label∧sentinel 破れ）"
    else _ok "has_member: sentinel 不在 slate は members 無効化で reject（label∧sentinel 両必須）"; fi

    # (4b) sentinel 行と別行の stray `members:`（既存 bead の前歴 prose 由来）は members へ混入しない
    #      （sentinel 行束縛の teeth＝reader/writer form 一致・false-green interlock 退行の回帰）。
    #      sentinel 行の members(orch-aaa) は valid・別行 prose の members(orch-evil) は非採用。
    export SLATE_LIST_JSON='[{"id":"orch-slate1"}]'
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"設計 prose: members: orch-evil, orch-bad\n[ORCH-SLATE v1] members: orch-aaa"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then _ok "members: sentinel 行の member(orch-aaa)は pass"
    else _fail "members: sentinel 行の valid member を落とした"; fi
    if _orch_slate_has_member "orch-evil" "$BD" "$ANC"; then
        _fail "members: sentinel 行外の stray prose members(orch-evil)が pass した（sentinel 行束縛破れ＝false-green interlock）"
    else _ok "members: sentinel 行外 stray prose members は非採用（sentinel 行束縛・over-permit 封鎖）"; fi

    # (5) foreign copy（非 orch- prefix）は open_ids から排除（自台帳 filter）。
    export SLATE_LIST_JSON='[{"id":"un-slate9"},{"id":"orch-slate1"}]'
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"[ORCH-SLATE v1] members: orch-aaa"}]'
    ids_out="$(_orch_slate_open_ids "$BD" "$ANC")"
    if printf '%s\n' "$ids_out" | grep -qxF "orch-slate1" && ! printf '%s\n' "$ids_out" | grep -qxF "un-slate9"; then
        _ok "open_ids: foreign copy(un-)を排除し自台帳(orch-)のみ列挙"
    else _fail "open_ids: 自台帳 filter が効かない: [$ids_out]"; fi

    # (6) bd read 失敗 → has_member rc=2（fail-closed・read 不能を pass にしない）。
    if BD_FAIL=1 _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then
        _fail "has_member: bd read 失敗で pass した（fail-closed 破れ）"
    else _ok "has_member: bd read 失敗は reject（rc≠0・fail-closed）"; fi

    # (7) record helper: 既存 bead へ slate label + sentinel+members 行を bdw で焼く。
    : > "$BDW_MARK"
    if _orch_slate_record "$BDW" "$ANC" "orch-bundle1" "orch-aaa" "orch-bbb" "folio"; then
        if grep -q -- "--add-label slate" "$BDW_MARK" \
           && grep -q -- "\[ORCH-SLATE v1\] members: orch-aaa, orch-bbb, folio" "$BDW_MARK" \
           && grep -q "update orch-bundle1" "$BDW_MARK"; then
            _ok "record: slate label + canonical members 行を bdw update で stamp"
        else _fail "record: bdw argv が期待形でない: $(cat "$BDW_MARK")"; fi
    else _fail "record: 正常引数で非0 を返した"; fi

    # (8) record helper: members ゼロ / sid 空は rc=2（fail-closed・空虚 slate を焼かない）。
    if _orch_slate_record "$BDW" "$ANC" "orch-bundle1"; then
        _fail "record: member ゼロで成功した（空虚 slate を許容）"
    else _ok "record: member ゼロは rc≠0（空虚 slate を焼かない）"; fi

    # (9) status 集合（bd orch-1dcd）: dispatch 後に worker の --claim で in_progress 化した slate は**生きる**。
    #     status-aware stub ゆえ open 固定 query の実装ではこの fixture は返らず members 空＝reject へ倒れる。
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"in_progress"}]'
    export SLATE_SHOW_JSON='[{"id":"orch-slate1","notes":"[ORCH-SLATE v1] members: orch-aaa, folio"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then
        _ok "status: in_progress slate は生存（dispatch 後も interlock を通す・orch-1dcd）"
    else _fail "status: in_progress slate が reject された（open 固定 filter＝bundle 自殺の退行）"; fi
    if [ -n "$(_orch_slate_open_members "$BD" "$ANC")" ]; then
        _ok "status: in_progress slate の members が surface path でも返る（同一 filter）"
    else _fail "status: in_progress slate の members が空（surface/interlock の非対称 or open 固定）"; fi

    # (9b) blocked / deferred も同型 brick ゆえ活動中として扱う（human ratify 待ち slate で bundle を殺さない）。
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"blocked"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then _ok "status: blocked slate も活動中扱い（pass）"
    else _fail "status: blocked slate が reject された（非 closed 明示列挙の破れ）"; fi
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"deferred"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then _ok "status: deferred slate も活動中扱い（pass）"
    else _fail "status: deferred slate が reject された（非 closed 明示列挙の破れ）"; fi

    # (10) 除外の対: 同一 members のまま status だけ closed にすると reject（bundle 完了後の旧 slate は通さない）。
    #      (9) と (10) は status だけが違う positive/negative 対＝over-permit（closed 混入）と under-permit
    #      （open 固定）の両方を同時に RED 化する。
    export SLATE_LIST_JSON='[{"id":"orch-slate1","status":"closed"}]'
    if _orch_slate_has_member "orch-aaa" "$BD" "$ANC"; then
        _fail "status: closed slate が pass した（bundle 完了後の旧 slate が interlock を通す over-permit）"
    else _ok "status: closed slate は reject（bundle 完了後は interlock を通さない）"; fi
    if [ -z "$(_orch_slate_open_members "$BD" "$ANC")" ]; then
        _ok "status: closed slate は members 和集合からも除外（surface path も同一 filter）"
    else _fail "status: closed slate の members が surface path に残った"; fi

    # ── leak battery（F3・orch-cqf4 Leg-A public-safe hardening）────────────────────────
    # engine は PUBLIC 配布物ゆえ、本 diff で追加した --surface 関数（declare -f で live 抽出＝hermetic・base 非依存）
    # に deploy 主体名 / 内部短名 codename / 絶対 deploy-path を混入していないことを 4 系統 fail-closed で assert する。
    # 実 leak は 0（admin 実測）＝battery は保険。緑=歯無しの取り違えを各系統 1 mutation（positive fixture 注入→RED）で塞ぐ。
    #   (2) 短名は bare codename のみ検出しハイフン付き ledger-ID（foreign fixture un-xxx / pk-xxx）は非該当。
    _leak_scan() {  # $1=text : leak 検出→系統名を echo し rc=1 / clean→rc=0
        local _t="$1"
        # ★自己参照回避（realname 系統）: 兄弟 literal も char class で分断し、公開 source へ verbatim 識別子を残さない
        #   （`black[0-9]`/deploy-path 分断と一貫。分断後も real leak（実 codename/実ホスト名/email 断片の実出現）は
        #   依然マッチ＝検出器の歯は不変・acceptance-6 の literal grep=0 を realname 兄弟にも及ぼす）。
        grep -qwE 'shu[u]5|black[0-9]|phit[o]|ipath[o]|doobido[o]|blackco[w]|gmai[l]' <<<"$_t" && { echo realname; return 1; }
        grep -qE '(^|[^-A-Za-z0-9_])(pk|scp|un|scm|cs)([^-A-Za-z0-9_]|$)' <<<"$_t" && { echo shortname; return 1; }
        # ★自己参照回避: 検出器パターン自身が acceptance-6 の deploy-path grep に自己ヒットしないよう、対象 literal を
        #   正規表現 character class で分断する（`scriptoriu[m]` は real leak を変わらず検出・grader の literal grep には非マッチ）。
        grep -qE 'local-projects/scriptoriu[m]|/home/[a-z]' <<<"$_t" && { echo deploypath; return 1; }
        return 0
    }
    _lk_sample="$(declare -f _orch_slate_surface)"
    if _leak_scan "$_lk_sample" >/dev/null; then _ok "leak-battery: --surface 追加関数は realname/shortname/deploypath clean"
    else _fail "leak-battery: --surface 追加関数に leak（系統=$(_leak_scan "$_lk_sample")）"; fi
    _inj="shu""u5"; if _leak_scan "$_lk_sample"$'\nleaked by '"$_inj"$' here\n'    >/dev/null; then _fail "leak-battery realname 系統に歯が無い（${_inj} 見逃し）"; else _ok "leak-battery realname 系統に歯あり（${_inj} mutation を RED 化）"; fi
    if _leak_scan "$_lk_sample"$'\nthe un project note\n'     >/dev/null; then _fail "leak-battery shortname 系統に歯が無い（bare un 見逃し）"; else _ok "leak-battery shortname 系統に歯あり（bare un mutation を RED 化）"; fi
    if _leak_scan "$_lk_sample"$'\nfallback=/home/someone/x\n' >/dev/null; then _fail "leak-battery deploypath 系統に歯が無い（/home/ 見逃し）"; else _ok "leak-battery deploypath 系統に歯あり（/home/ mutation を RED 化）"; fi
    # 系統3 dangling-lib: --surface が lazy source する共有 lib（同 dir の orch_anchor.sh）の実在検証 + 非実在 mutation。
    _leak_libcheck() { [ -r "$1" ]; }
    _lk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo .)"
    if _leak_libcheck "$_lk_dir/orch_anchor.sh"; then _ok "leak-battery dangling-lib: lazy-source 先 orch_anchor.sh は実在"
    else _fail "leak-battery dangling-lib: lazy-source 先 orch_anchor.sh が dangling（$_lk_dir/orch_anchor.sh 不在）"; fi
    if _leak_libcheck "$st_tmp/nonexistent-lib-$$.sh"; then _fail "leak-battery dangling-lib 系統に歯が無い（非実在 lib を実在判定）"; else _ok "leak-battery dangling-lib 系統に歯あり（非実在 lib mutation を RED 化）"; fi

    if [ "$st_fail" -eq 0 ]; then echo "orch_slate.sh --self-test: PASS"; exit 0
    else echo "orch_slate.sh --self-test: FAIL" >&2; exit 1; fi
fi

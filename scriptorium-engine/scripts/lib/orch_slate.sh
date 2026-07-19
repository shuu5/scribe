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
#   slate bead は open=活動 bundle / bundle 完了（gate→close+cleanup）で close する（orchestrator 責務）。
#   open 放置は orch-stale-scan の母集団を汚染するため既定は close 運用（top-spec slate 節に明記）。
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

# open slate bead の id を列挙（read-only）。$1=bd 実体, $2=anchor（bd graph 所在）。
#   `bd -C <anchor> list --label slate --status open --json` を読み、id が自台帳 prefix（orch-）で始まる
#   bead のみ返す（連結 substrate hydrate で混在する foreign copy を排除）。bd read 失敗は rc=1（fail-closed）。
_orch_slate_open_ids() {
    local bd="$1" anchor="$2" json
    json="$("$bd" -C "$anchor" list --label "$ORCH_SLATE_LABEL" --status open --json 2>/dev/null)" || return 1
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

# === --self-test: 直接実行時のみの hermetic 自己完結テスト（fail-closed・orch-vswk） ===
# source 時（BASH_SOURCE[0] != $0）はこのブロックを skip する（consumer の $1 継承で誤発火しない）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" != "--self-test" ]; then
        echo "orch_slate.sh は source して使う共有 lib です（--self-test で自己検証）。" >&2
        exit 0
    fi

    st_fail=0
    st_tmp="$(mktemp -d -t orch-slate-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT
    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }

    mkdir -p "$st_tmp/bin" "$st_tmp/anchor"

    # hermetic bd stub: `list --label slate --status open --json` → $SLATE_LIST_JSON,
    #   `show <id> --json` → $SLATE_SHOW_JSON（未 set は []）。`-C <anchor>` は剥がす。BD_FAIL=1 で非0。
    cat > "$st_tmp/bin/bd" <<'STUB'
#!/usr/bin/env bash
[ -n "${BD_FAIL:-}" ] && exit 1
while [ "${1:-}" = "-C" ] || [ "${1:-}" = "--directory" ]; do shift 2; done
case "$1" in
  list) printf '%s' "${SLATE_LIST_JSON:-[]}" ;;
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

    if [ "$st_fail" -eq 0 ]; then echo "orch_slate.sh --self-test: PASS"; exit 0
    else echo "orch_slate.sh --self-test: FAIL" >&2; exit 1; fi
fi

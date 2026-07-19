#!/usr/bin/env bash
# orch-branch-sweep.sh — spawn branch backlog の機械掃除ツール（read-only 既定・orch-caz）
#
# 背景（実測 2026-07-06・orch-caz）───────────────────────────────────────────────────────────────
#   worker cell の spawn branch（spawn/<bd-id>-<HHMMSS>）が数週間で堆積した（local 26 + remote 23 本）。
#   squash merge は branch を自動削除せず（`-d` は squash に効かず・`-D` は git skill/hook 禁止）、
#   放置すると remote/local が spawn branch で埋まる。恒久策は 2 段構え:
#     (c) merge 時に消す = `gh pr merge --squash --delete-branch`（remote 即消滅・今後の branch を防ぐ）。
#     (b) 既に堆積した backlog を掃除する = 本 script（read-only 判定 + gated remote 削除 + local 委譲）。
#   本 script は (b)＝過去の堆積を安全に掃除する **read-only 既定の軽量 sweep**（description は重量 (b) を
#   非推奨としたが、backlog 掃除用の read-only 軽量版は採用＝推奨からの逸脱を明示して採る・PINS v2）。
#
# 対象（scope）────────────────────────────────────────────────────────────────────────────────────
#   **spawn branch backlog 専用**。branch 名が spawn 命名 SSOT（orch-dispatch.sh の
#   `spawn/${bd_id}-$(date +%H%M%S)`）に一致するものだけを候補にする。admin 手動 branch（docs/feat/fix 等）は
#   scope 外＝抽出不能 branch は候補外（fail-closed under-sweep）。今後の branch は (c) の --delete-branch が
#   merge 時に処理するので、本 sweep は過去堆積の一掃に限る。
#
# 削除可否の機械判定（3 段・fail-closed）──────────────────────────────────────────────────────────
#   merged PR 1 本ごとに、以下を全て満たしたものだけを「remote 削除候補」にする:
#     (1) 命名一致 : branch が `^spawn/(orch-[0-9a-z]+)-[0-9]{6}$` に一致（capture=bd-id）。不一致は候補外。
#     (2) closed  : 抽出 bd-id が `bd list --status closed --json` の closed 集合に exact-match で在る。
#                   集合に無い id（open / 台帳不在）は candidate skip（sweep は abort せず継続）。
#                   orch- prefix で絞る＝hydrate 済 foreign 台帳の id を巻き込まない（正規表現が既に要求）。
#     (3) tip 一致: 現 remote branch tip（`git ls-remote --heads origin <branch>`）== 当該 merged PR の
#                   headRefOid。不一致（merge 後 re-push）は候補外 + loud 警告。remote に branch 不在は
#                   「既に削除済み」として候補外（情報のみ）。
#   ★ ancestry 検証（`git merge-base --is-ancestor`）は **squash merge で全 branch false** になる（squash は
#     親を書き換える）ため採らない。tip SHA 照合が squash 環境での正しい defense-in-depth。
#
# 出力（2 系統・破壊は --execute の remote のみ）──────────────────────────────────────────────────
#   (i) remote 削除候補: 既定は候補リストを print するだけ（read-only）。`--execute` 明示時のみ
#       `git push origin --delete <branch>` を per-branch rc 捕捉で実行し、N 成功 / M 失敗を truthful に
#       報告する（blanket green 禁止＝1 本でも失敗したら非 0 で終わる）。
#   (ii) local -D 委譲: **merged∩closed（命名一致 ∩ closed）を満たす branch**（remote 削除の tip gate とは
#       独立）の `git branch -D <branch>` コマンド列を **print するだけ**（決して自動実行しない）。tip gate から
#       切り離すことで「remote は既に削除済み（--delete-branch 済）だが local に残る」orphan branch（実測
#       local>remote の差分＝最も -D を要する対象）も取りこぼさない。local squash branch は -D が必要で -D は
#       git skill/hook 禁止ゆえ、実行は user へ委譲。
#
# 事前 liveness（到達不能を skip に吸収しない・fail-closed）─────────────────────────────────────────
#   走る前に `gh pr list --limit 1` と `bd list --status closed --json` の成功を確認する。どちらか到達不能
#   なら即 error 終了（判定不能を「候補ゼロ」と誤って green にしない）。
#
# 全件取得の truncate guard（silent 截断防止・fail-closed）─────────────────────────────────────────
#   merged PR は `--limit <PR_LIMIT=1000>` を明示で全件取る（gh default 30 は silent 截断＝現 merged 67 本で
#   欠落）。取得件数が limit と等しくなったら「これ以上あるかもしれない＝判定不能」として error 終了する。
#   closed bead も同型: `bd list --status closed --json --limit 0`（unlimited）で全件取る（bd default 50 は
#   silent 截断＝orch closed 116 本中 50 本しか見えず backlog 掃除を defeat する・verified: --limit 0 で 704 件
#   全取得）。gh 軸と対の truncate guard（有限 limit を課したのに取得数がそれに達したら abort）も持つ
#   （ORCH_BRANCH_SWEEP_BD_LIMIT で有限化＝test 用）。
#
# self-scope gate（誤台帳での破壊を fail-closed で拒否）────────────────────────────────────────────
#   cwd から walk-up した最初の .beads/metadata.json の dolt_database が orch でなければ **非 0 で抜ける**
#   （degraded-watch 等は read のみゆえ exit 0 だが、本 script は --execute で remote を消しうるため誤台帳は
#   fail-closed 非 0＝より安全側）。ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 で skip（hermetic self-test 用）。
#
# read-only 徹底（write-isolation を侵さない）──────────────────────────────────────────────────────
#   既定は gh（read）/ bd list（read）/ git ls-remote（read）だけ。bd/foreign 台帳を一切 mutate しない。
#   remote への write は `--execute` 明示時の `git push --delete` のみ（自台帳 orch の spawn branch が対象）。
#   local branch は一切触らない（-D は委譲コマンドの print だけ）。
#
# モード / オプション ─────────────────────────────────────────────────────────────────────────────
#   （既定）dry-run : 削除候補を判定し stdout へ（remote/local とも実行しない）。
#   --execute       : remote 削除候補を実際に `git push --delete` する（per-branch rc・N/M 報告）。
#   --self-test     : hermetic 自己テスト（stub gh/bd/git・plugin 非依存・fail-closed）。
#   -h|--help       : 使い方。
#
# stub 差替 env（hermetic test 用）: ORCH_BRANCH_SWEEP_GH / _BD / _GIT でコマンド実体を差替える。
# 依存: bash・jq・gh・bd・git。
set -euo pipefail

PROG="orch-branch-sweep"

# ── 差替可能なコマンド実体（hermetic test で PATH 非依存に stub する）──────────────
GH_BIN="${ORCH_BRANCH_SWEEP_GH:-gh}"
BD_BIN="${ORCH_BRANCH_SWEEP_BD:-bd}"
GIT_BIN="${ORCH_BRANCH_SWEEP_GIT:-git}"

# spawn branch 命名 SSOT（orch-dispatch.sh の `spawn/${bd_id}-$(date +%H%M%S)`）を anchored 正規表現で pin。
# capture group 1 = bd-id（orch- prefix を要求＝foreign 台帳 id を構造的に除外）。
SPAWN_BRANCH_RE='^spawn/(orch-[0-9a-z]+)-[0-9]{6}$'

# merged PR 全件取得の上限（gh default 30 は silent 截断ゆえ明示）。取得数==LIMIT で truncate 判定。
PR_LIMIT="${ORCH_BRANCH_SWEEP_PR_LIMIT:-1000}"

# closed bead 全件取得の上限。既定 0＝unlimited（bd docs: 0 で無制限・verified: --limit 0 で closed 704 件
# 全取得）＝bd default 50 の silent 截断（orch closed 116 本中 50 本しか見えず backlog 掃除を defeat）を防ぐ
# 本来の fix。gh 軸と対の truncate guard 用に有限値へ上書き可（>0 かつ取得数==limit で abort）。
BD_CLOSED_LIMIT="${ORCH_BRANCH_SWEEP_BD_LIMIT:-0}"

SELF_PREFIX="orch"

usage() {
    cat <<EOF
usage: $PROG [--execute] [--self-test] [-h|--help]

spawn branch backlog（spawn/<orch-id>-<HHMMSS>）の機械掃除ツール（read-only 既定）。
merged PR ∩ closed bead ∩ tip-SHA 一致 の 3 段判定で remote 削除候補を選ぶ。

  (既定)      dry-run: 削除候補を print（remote/local とも実行しない）。
  --execute   remote 削除候補を git push --delete で実行（per-branch rc・N/M 報告）。
  --self-test hermetic 自己テスト（stub gh/bd/git）。
  -h,--help   この使い方。

local branch の削除は常に委譲コマンド（git branch -D ...）の print のみ（自動実行しない）。
EOF
}

# ── self-scope gate（共有 lib consume・degraded-watch と同一機構）──────────────────
_self_scope_gate() {
    if [[ "${ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE:-}" == "1" ]]; then
        return 0
    fi
    local script_dir lib
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "$script_dir/hooks/lib/orch_session.sh" ]]; then
        lib="$script_dir/hooks/lib/orch_session.sh"          # plugin 配置
    elif [[ -f "$script_dir/../hooks/lib/orch_session.sh" ]]; then
        lib="$script_dir/../hooks/lib/orch_session.sh"       # repo 配置（scripts/ 配下）
    else
        echo "$PROG: fatal: 共有 lib hooks/lib/orch_session.sh が見つからない" >&2
        exit 3
    fi
    # shellcheck source=hooks/lib/orch_session.sh
    source "$lib"
    local db
    db="$(_ledger_dolt_database "$PWD" 2>/dev/null || true)"
    if [[ "$db" != "$SELF_PREFIX" ]]; then
        echo "$PROG: self-scope 外（dolt_database='$db'≠orch）→ fail-closed（誤台帳での掃除を拒否）" >&2
        exit 2
    fi
}

# ── 事前 liveness（到達不能を skip に吸収しない）───────────────────────────────────
_liveness_or_die() {
    if ! "$GH_BIN" pr list --limit 1 >/dev/null 2>&1; then
        echo "$PROG: fatal: gh 到達不能（gh pr list --limit 1 失敗）→ 判定不能ゆえ abort" >&2
        exit 4
    fi
}

# ── closed bead 集合を一度に解決（この bd list 失敗のみ abort）─────────────────────
#   出力: orch- prefix の closed id を 1 行 1 件で stdout（呼出側が連想配列化）。
_closed_ids() {
    local json count
    if ! json="$("$BD_BIN" list --status closed --json --limit "$BD_CLOSED_LIMIT" 2>/dev/null)"; then
        echo "$PROG: fatal: bd list --status closed --json 失敗（closed 集合を解決できない）→ abort" >&2
        exit 4
    fi
    # truncate guard（gh 軸と同型・fail-closed）: 有限 limit を課したのに取得数がそれに達した＝silent
    #   截断の可能性 → 候補ゼロと誤認せず abort。既定 0（unlimited）では発火しない（bd が全件返す＝
    #   截断不能・verified: --limit 0 で closed 704 件全取得）。
    count="$(printf '%s' "$json" | jq 'length' 2>/dev/null || echo 0)"
    if [[ "$BD_CLOSED_LIMIT" -ne 0 && "$count" -ge "$BD_CLOSED_LIMIT" ]]; then
        echo "$PROG: fatal: closed bead 取得数（$count）が limit（$BD_CLOSED_LIMIT）に達した＝silent 截断の可能性で判定不能 → abort" >&2
        exit 4
    fi
    # jq で id 抽出 → orch- prefix で絞る。空配列でも空出力で正常。
    printf '%s' "$json" | jq -r '.[].id // empty' 2>/dev/null | grep -E '^orch-' || true
}

# ── merged PR 全件を TSV（branch \t oid \t number）で取得（truncate guard）─────────
_merged_prs_tsv() {
    local json count
    if ! json="$("$GH_BIN" pr list --state merged --json headRefName,headRefOid,number --limit "$PR_LIMIT" 2>/dev/null)"; then
        echo "$PROG: fatal: gh pr list --state merged 失敗 → abort" >&2
        exit 4
    fi
    count="$(printf '%s' "$json" | jq 'length' 2>/dev/null || echo 0)"
    if [[ "$count" -ge "$PR_LIMIT" ]]; then
        echo "$PROG: fatal: merged PR 取得数（$count）が limit（$PR_LIMIT）に達した＝silent 截断の可能性で判定不能 → abort" >&2
        exit 4
    fi
    printf '%s' "$json" | jq -r '.[] | [.headRefName, .headRefOid, (.number|tostring)] | @tsv'
}

# ── 現 remote branch tip を取得（無ければ空文字）────────────────────────────────
_remote_tip() {
    local branch="$1" out
    out="$("$GIT_BIN" ls-remote --heads origin "refs/heads/$branch" 2>/dev/null || true)"
    # `<sha>\trefs/heads/<branch>` の先頭列。branch 不在なら out が空。
    printf '%s' "$out" | awk 'NR==1{print $1}'
}

main() {
    local do_execute=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --execute) do_execute=1; shift ;;
            --self-test) run_self_test; exit $? ;;
            -h|--help) usage; exit 0 ;;
            *) echo "$PROG: unknown arg: $1" >&2; usage >&2; exit 64 ;;
        esac
    done

    _self_scope_gate
    _liveness_or_die

    # closed 集合 / merged PR 一覧は **command substitution で main シェルに取り込んでから** 処理する。
    #   （`< <(func)` の process substitution だと func 内 `exit` がサブシェルのみを終えて abort が効かず、
    #     truncate guard / bd 到達不能 abort が silent に無効化される＝self-test で実証したバグ回避）。
    local closed_raw merged_tsv
    if ! closed_raw="$(_closed_ids)"; then
        exit 4   # _closed_ids が stderr に理由を出済み
    fi
    if ! merged_tsv="$(_merged_prs_tsv)"; then
        exit 4   # _merged_prs_tsv が stderr に理由を出済み（gh 失敗 / truncate guard）
    fi

    # closed 集合を連想配列へ。
    declare -A CLOSED=()
    local id
    while IFS= read -r id; do
        [[ -n "$id" ]] && CLOSED["$id"]=1
    done <<< "$closed_raw"

    # 判定ループ。
    local -a delete_candidates=()         # remote 削除候補（3 段すべて満たす＝remote push --delete 対象）
    local -a local_delete_candidates=()   # local -D 委譲対象（命名一致 ∩ closed＝merged∩closed・tip gate と独立）
    local branch oid num bd_id tip
    local n_scanned=0 n_skip_name=0 n_skip_open=0 n_skip_tip=0 n_skip_gone=0

    echo "== $PROG: spawn branch backlog 判定（read-only）=="
    while IFS=$'\t' read -r branch oid num; do
        [[ -z "$branch" ]] && continue
        n_scanned=$((n_scanned + 1))
        # (1) 命名一致 → bd-id 抽出。
        if [[ ! "$branch" =~ $SPAWN_BRANCH_RE ]]; then
            n_skip_name=$((n_skip_name + 1))
            continue   # admin 手動 branch 等は scope 外（fail-closed under-sweep・静かに skip）
        fi
        bd_id="${BASH_REMATCH[1]}"
        # (2) closed 集合との交差。
        if [[ -z "${CLOSED[$bd_id]:-}" ]]; then
            n_skip_open=$((n_skip_open + 1))
            echo "  skip (open/台帳不在): $branch [PR #$num · bead $bd_id]"
            continue   # abort せず sweep 継続
        fi
        # ── merged∩closed（命名一致 ∩ closed）を満たした → local -D 委譲対象に採る（tip gate と独立）。──
        #   local -D は print のみ（自動実行しない）ゆえ remote 破壊の安全弁 tip gate を課さない。これにより
        #   「remote は既に削除済み（--delete-branch 済）だが local に残る」orphan branch（実測 local>remote の
        #   差分＝最も -D を要する対象）を取りこぼさない。remote 側 3 段判定は remote 削除専用に保つ（orch-caz #2）。
        local_delete_candidates+=("$branch")
        # (3) tip SHA 照合（remote 削除の安全弁・local -D には無関係）。
        tip="$(_remote_tip "$branch")"
        if [[ -z "$tip" ]]; then
            n_skip_gone=$((n_skip_gone + 1))
            echo "  skip remote (既に削除済み・local -D は委譲): $branch [PR #$num · bead $bd_id]"
            continue   # remote 候補外だが local -D 委譲対象には残る
        fi
        if [[ "$tip" != "$oid" ]]; then
            n_skip_tip=$((n_skip_tip + 1))
            echo "  ⚠ skip remote (tip 不一致=merge 後 re-push 疑い・local -D は委譲): $branch [remote=$tip ≠ PR headOid=$oid]" >&2
            continue   # remote 候補外 + loud 警告（local -D 委譲対象には残る）
        fi
        # 3 段すべて満たす → remote 削除候補。
        delete_candidates+=("$branch")
        echo "  ✓ 削除候補: $branch [PR #$num · bead $bd_id closed · tip=$oid]"
    done <<< "$merged_tsv"

    echo "-- 走査 $n_scanned 本: remote 削除候補 ${#delete_candidates[@]} · local -D 委譲 ${#local_delete_candidates[@]} / skip(命名外 $n_skip_name · open $n_skip_open · tip不一致 $n_skip_tip · remote既削除 $n_skip_gone) --"

    if [[ ${#delete_candidates[@]} -eq 0 && ${#local_delete_candidates[@]} -eq 0 ]]; then
        echo "削除候補なし（remote/local とも何もしない）。"
        return 0
    fi

    # ── (i) remote 削除 ──────────────────────────────────────────────────────────
    local rc_any=0
    if [[ ${#delete_candidates[@]} -eq 0 ]]; then
        echo "== remote 削除候補なし（remote は既削除 or tip 不一致のみ）=="
    elif [[ "$do_execute" -eq 1 ]]; then
        echo "== remote 削除実行（git push --delete・per-branch rc）=="
        local ok=0 fail=0 b
        for b in "${delete_candidates[@]}"; do
            if "$GIT_BIN" push origin --delete "$b" >/dev/null 2>&1; then
                ok=$((ok + 1)); echo "  deleted: $b"
            else
                fail=$((fail + 1)); echo "  FAILED : $b" >&2
            fi
        done
        echo "-- remote 削除: $ok 成功 / $fail 失敗 --"
        [[ "$fail" -gt 0 ]] && rc_any=1   # blanket green 禁止
    else
        echo "== remote 削除候補（--execute で実行）=="
        local b
        for b in "${delete_candidates[@]}"; do
            echo "  git push origin --delete $b"
        done
    fi

    # ── (ii) local -D 委譲コマンド列（print のみ・自動実行しない・tip gate と独立＝local orphan も網羅）──
    if [[ ${#local_delete_candidates[@]} -gt 0 ]]; then
        echo "== local branch -D 委譲コマンド（user が生シェルで実行・自動実行しない）=="
        local b2
        for b2 in "${local_delete_candidates[@]}"; do
            echo "  git branch -D $b2"
        done
    fi

    return $rc_any
}

# ══════════════════════════════════════════════════════════════════════════════════
# hermetic self-test（stub gh/bd/git・fail-closed・plugin 非依存）
# ══════════════════════════════════════════════════════════════════════════════════
run_self_test() {
    local self tmp rc=0
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN

    local bin="$tmp/bin"
    mkdir -p "$bin"

    # stub gh: liveness(--limit 1) と merged 一覧を fixture から返す。
    cat >"$bin/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"--limit 1"* && "$*" != *"--state merged"* ]]; then
    echo "[]"; exit 0            # liveness probe
fi
if [[ "$*" == *"--state merged"* ]]; then
    cat "$GH_FIXTURE"; exit 0
fi
echo "[]"; exit 0
STUB
    # stub bd: list --status closed --json を fixture から返す。
    cat >"$bin/bd" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"list --status closed --json"* ]]; then
    cat "$BD_FIXTURE"; exit 0
fi
echo "[]"; exit 0
STUB
    # stub git: ls-remote は TIP_FIXTURE を、push --delete は成功記録する。
    cat >"$bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "ls-remote" ]]; then
    ref="${@: -1}"; branch="${ref#refs/heads/}"
    awk -v b="$branch" '$1==b{print $2"\trefs/heads/"$1}' "$TIP_FIXTURE"
    exit 0
fi
if [[ "$1" == "push" ]]; then
    echo "$*" >>"$PUSH_LOG"; exit 0
fi
exit 0
STUB
    chmod +x "$bin/gh" "$bin/bd" "$bin/git"

    export ORCH_BRANCH_SWEEP_GH="$bin/gh"
    export ORCH_BRANCH_SWEEP_BD="$bin/bd"
    export ORCH_BRANCH_SWEEP_GIT="$bin/git"
    export ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1

    export GH_FIXTURE="$tmp/merged.json"
    export BD_FIXTURE="$tmp/closed.json"
    export TIP_FIXTURE="$tmp/tips.tsv"
    export PUSH_LOG="$tmp/push.log"
    : >"$PUSH_LOG"

    # fixture: 4 branch。
    #  A: spawn/orch-aaa-111111  closed  tip一致   → 削除候補
    #  B: spawn/orch-bbb-222222  open           → skip (open)
    #  C: spawn/orch-ccc-333333  closed  tip不一致 → skip (tip)
    #  D: feat/manual-thing      （命名外）      → skip (命名外)
    cat >"$GH_FIXTURE" <<'JSON'
[
  {"headRefName":"spawn/orch-aaa-111111","headRefOid":"aaaa1111","number":1},
  {"headRefName":"spawn/orch-bbb-222222","headRefOid":"bbbb2222","number":2},
  {"headRefName":"spawn/orch-ccc-333333","headRefOid":"cccc3333","number":3},
  {"headRefName":"feat/manual-thing","headRefOid":"dddd4444","number":4}
]
JSON
    cat >"$BD_FIXTURE" <<'JSON'
[
  {"id":"orch-aaa"},
  {"id":"orch-ccc"},
  {"id":"sc-zzz"}
]
JSON
    # tips: A は一致 / C は remote tip が PR oid と不一致。
    printf 'spawn/orch-aaa-111111\taaaa1111\n' >"$TIP_FIXTURE"
    printf 'spawn/orch-ccc-333333\tcccc9999\n' >>"$TIP_FIXTURE"

    local out
    # --- dry-run: 候補 A のみ・push 未実行 ---
    if ! out="$(ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 "$self" 2>/dev/null)"; then
        echo "self-test FAIL: dry-run 非0 終了"; return 1
    fi
    grep -q "削除候補: spawn/orch-aaa-111111" <<<"$out" || { echo "self-test FAIL: A が削除候補にならない"; rc=1; }
    grep -q "削除候補: spawn/orch-bbb-222222" <<<"$out" && { echo "self-test FAIL: B(open) が候補に混入"; rc=1; }
    grep -q "削除候補: spawn/orch-ccc-333333" <<<"$out" && { echo "self-test FAIL: C(tip不一致) が候補に混入"; rc=1; }
    grep -q "削除候補: feat/manual-thing"    <<<"$out" && { echo "self-test FAIL: D(命名外) が候補に混入"; rc=1; }
    [[ -s "$PUSH_LOG" ]] && { echo "self-test FAIL: dry-run で push が実行された"; rc=1; }
    grep -q "git branch -D spawn/orch-aaa-111111" <<<"$out" || { echo "self-test FAIL: local -D 委譲コマンドが出ない"; rc=1; }

    # --- --execute: A が push --delete される ---
    if ! out="$(ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 "$self" --execute 2>/dev/null)"; then
        echo "self-test FAIL: --execute 非0"; return 1
    fi
    grep -q "push origin --delete spawn/orch-aaa-111111" "$PUSH_LOG" || { echo "self-test FAIL: --execute で A が push --delete されない"; rc=1; }
    grep -Eq "orch-bbb|orch-ccc|manual-thing" "$PUSH_LOG" && { echo "self-test FAIL: --execute で候補外 branch が push された"; rc=1; }

    # --- gh truncate guard: PR_LIMIT=1 なら merged 取得数(4)>=limit で abort ---
    if ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 ORCH_BRANCH_SWEEP_PR_LIMIT=1 "$self" >/dev/null 2>&1; then
        echo "self-test FAIL: gh truncate guard が発火せず 0 終了"; rc=1
    fi

    # --- bd closed truncate guard: BD_LIMIT=2 なら closed 取得数(3)>=limit で abort（gh 軸と同型）---
    if ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 ORCH_BRANCH_SWEEP_BD_LIMIT=2 "$self" >/dev/null 2>&1; then
        echo "self-test FAIL: bd closed truncate guard が発火せず 0 終了"; rc=1
    fi

    # --- bd 到達不能: abort（非0）---
    cat >"$bin/bd" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
    chmod +x "$bin/bd"
    if ORCH_BRANCH_SWEEP_SKIP_SESSION_GATE=1 "$self" >/dev/null 2>&1; then
        echo "self-test FAIL: bd 到達不能で abort しない"; rc=1
    fi

    [[ "$rc" -eq 0 ]] && echo "$PROG self-test: PASS"
    return "$rc"
}

main "$@"

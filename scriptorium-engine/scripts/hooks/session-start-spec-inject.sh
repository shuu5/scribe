#!/usr/bin/env bash
# session-start-spec-inject.sh — orchestrator SessionStart role 文脈注入（bd un-df2）
#
# 役割: orchestrator session の起動時に「federated 3-tier の top / 別レイヤ」role 文脈
#       (write-isolation・連結 substrate・courier・初回 hydrate・Option Y・SSOT ポインタ)を
#       stdout へ注入する。Claude Code は SessionStart hook の stdout を session context へ
#       注入する仕様ゆえ plain stdout に出力する(scribe session-start-role-inject.sh と同形)。
#
# 注入本文の SSOT(本文を script に二重化しない・top-spec §8): primer 本文は
#   docs/scriptorium-top-spec.md の sentinel `<!-- spec-inject:begin/end -->` 区間が SSOT で、
#   本 script はその区間を逐語抽出(sed・awk 非依存)して出すだけ。注入内容を変えるときは top-spec
#   §8 の sentinel 区間を編集する。
#
# self-scope(最重要・@inline plugin の全 SessionStart 発火を orchestrator session に限定):
#   本 hook を plugin として global enable すると SessionStart は**全セッション**で発火する。
#   orchestrator role 文脈を他 project(scribe 'sc' / cc-session 'ccs' …)へ誤注入しない
#   ため、**session cwd から上方向へ walk-up した最初の `.beads/metadata.json` の `dolt_database`
#   が SELF_PREFIX(orch)に完全一致するとき**だけ注入する。前方一致 'orchX'(orch2 等)は完全一致
#   比較で弾く。非該当・判定不能(.beads 無し・git 外・metadata 不正)は無出力で exit 0(no-op)。
#   この判定は bd-write-guard.py(un-mbz)の `_ledger_dolt_database` walk-up と同一機構・同一
#   SELF_PREFIX を共有する(top-spec §4/§8 の SSOT)。ただし present-but-unreadable(metadata 在るが
#   parse 失敗)の畳み方のみ orch-5yl 以降 divergent: 3 guard は moat 維持で fail-closed(作動継続)だが、
#   spec-inject は注入が cosmetic ゆえ fail-open(無注入・誤注入ゼロ優先)を保つ(walk-up/SELF_PREFIX は同一)。
#   `git rev-parse --show-toplevel` ではなく
#   filesystem walk-up を使うのは、継承 GIT_DIR/GIT_WORK_TREE env による toplevel 過剰解決
#   (scribe が実測した hazard)を避け guard と機構を一致させるため(orchestrator repo は nested
#   `.beads` を持たず両者は同値)。判定関数は決して die しない(filesystem stat/read のみ・例外は
#   握り潰し判定不能 → no-op)。
#
# cwd 第2軸(anchor だけ発火・orch-1r7 grill G3・SCRIBE_ROLE 非依存): 上の self-scope(台帳=orch)は
#   「この repo が orchestrator か」を判定するが、orchestrator repo の **worktree**(自己開発 worker cell)は
#   台帳 walk-up が anchor の `.beads`(dolt_database=orch)に届くため self-scope を通過してしまう。だが
#   worker worktree は scribe worker protocol で動く別 role であり、top-layer primer(「あなたは orchestrator」)
#   を注入すると 1 層だけ逆メッセージになる(drift #3)。よって self-scope と**直交する第2軸**として、
#   hook cwd が `.worktrees/` または `.claude/worktrees/`(CC-native worktree)配下なら orch session でも
#   **no-op** する(anchor〔非 worktree〕だけ primer を発火)。この軸は SCRIBE_ROLE 値に依存しない純 cwd 判定で、
#   scribe 側の worker 判定(cwd `.worktrees/`)や G1 の SCRIBE_ROLE=none wire とは独立に効く。
#
# consult 窓 第3軸(consult 窓へは primer 注入しない・orch-qcqz): scriptorium anchor 発の scribe-spawn --consult は
#   **anchor 同居**(consult 窓の cwd = anchor 自身)ゆえ self-scope(orch)も cwd 第2軸(worktree 除外)も素通りして
#   しまう。だが consult は別 role(read-only 相談役)で、top-layer primer(「あなたは orchestrator」)を注入すると
#   orchestrator 文脈が漏れる(orch-qcqz Finding・原 (2))。G1 の SCRIBE_ROLE=none wire では env による弁別が
#   settings.json project 層 none に子プロセスで潰され使えない(verified)ため、tmux window 名(scribe-spawn の
#   consult-* 命名規約)を signal に使う。self-scope・cwd 第2軸を通過した後に**第3 gate**として consult 窓を除外する。
#   取得不能(tmux 不在 / $TMUX 未設定 / 窓名取得失敗)は非 consult 扱い＝注入を継続(fail-safe・b-4「不能→no-op」は
#   既存 anchor 挙動を壊す誤り)。判定は共有 lib の `_is_consult_window`(additive helper)へ委譲する。
#
# --self-test(hermetic・fail-closed・orch-1r7): 引数 `--self-test` で自己完結テストを走らせる。temp に
#   fixture plugin root(sentinel 付き top-spec)と台帳 fixture(orch anchor / orch worktree(.worktrees・
#   .claude/worktrees) / foreign)を作り、各 cwd を stdin JSON で与えて本 script を subprocess 起動し、
#   anchor→注入 / worktree→no-op / foreign→no-op を assert する。非vacuity: anchor→注入が valid doc で
#   PASS することが「no-op 群が常時空でない」証明(cwd 軸が識別している)。加えて sentinel 破壊 fixture で
#   anchor すら no-op になる mutation で doc 依存(fail-open)も pin。TOP_SPEC seam(sc-300x)も同型で
#   pin する: seam の alt doc から注入(非vacuous)・壊れた alt doc は fail-open。assert が 1 つでも
#   落ちれば非 0。hermetic 化のため subprocess 起動は外来 ORCH_SPEC_INJECT_TOP_SPEC を unset する。
#
# fail-safe(全セッション破壊の防止): 判定不能・SSOT doc 不在・sentinel 欠落でもセッションを
#   壊さない。set -e は使わず常に exit 0(degrade)、警告は stderr。docs 不在/抽出空は stderr
#   warning を出して何も注入しない(continue)。これは hooks.json の二重 fail-safe 指示と整合。
#
# 検証: selftest-un-df2.local.sh(worktree 直下・fail-closed・dolt 不使用 temp ledger fixture)。

# 自台帳 prefix(.beads/metadata.json dolt_database="orch" / orchestrator CLAUDE.md SSOT)。
# bd-write-guard.py の SELF_PREFIX="orch" と同一値を共有する(session self-scope の台帳判定)。
SELF_PREFIX="orch"

# --- plugin root / SSOT doc パス解決(CLAUDE_PLUGIN_ROOT 優先・無ければ script 位置から導出) ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"
if [ -z "$PLUGIN_ROOT" ] || [ ! -d "$PLUGIN_ROOT" ]; then
    # scripts/hooks/ の 2 つ上 = plugin root
    PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." 2>/dev/null && pwd)"
fi
# TOP_SPEC env seam(ORCH_SPEC_INJECT_TOP_SPEC・sc-300x/orch-ocbx・orch-w9we.9 Leg-C): 既定は従来どおり
# plugin root 相対＝seam 未供給なら byte 不変の挙動(additive)。engine 単独稼働(subdir carve-out)では
# 規約 doc が engine tree に同梱されない(private 配備層に残る)ため、private 層(orch-supply.sh)が spec doc の
# 絶対 path を供給する override seam を置く(mechanism=public / value=private・他 engine seam と同じ ORCH_
# 接頭辞 per-consumer 形)。fail-open 契約は不変: seam が指す path の不在/壊れも従来どおり下の
# [ ! -r ] / sentinel gate が warning + skip continue へ落とす(path 解決だけを seam 化・検査ロジック不変)。
TOP_SPEC="${ORCH_SPEC_INJECT_TOP_SPEC:-$PLUGIN_ROOT/docs/scriptorium-top-spec.md}"

# --- 共有 self-scope lib を source（bd orch-t9z で 3 consumer から dedup・SSOT = scripts/hooks/lib/orch_session.sh） ---
# _extract_cwd / _json_is_valid / _ledger_dolt_database / _is_orch_session / _is_worktree_cwd を提供する。
# ★実 script 位置(BASH_SOURCE 相対 = $_SCRIPT_DIR)で解決するので、bats / --self-test が CLAUDE_PLUGIN_ROOT を
#   fixture へ向けても実 lib を確実に見つける(fixture 無改変で green を保つ)。_is_orch_session は上で定義した
#   SELF_PREFIX を参照する(lib の SELF_PREFIX 契約)。present-but-unreadable の fail-open や _json_is_valid の
#   guard parity など意味論は従来の verbatim 定義と同一(lib header 参照)。
# lib 不在は fail-open(無注入・誤注入ゼロ優先＝本 hook の cosmetic 性に合致)で exit 0 する。
_ORCH_SESSION_LIB="$_SCRIPT_DIR/lib/orch_session.sh"
if [ -r "$_ORCH_SESSION_LIB" ]; then
    # shellcheck source=lib/orch_session.sh
    . "$_ORCH_SESSION_LIB"
else
    echo "[orchestrator/SessionStart] warning: 共有 self-scope lib 不在($_ORCH_SESSION_LIB)・role 文脈注入を skip(fail-open continue)" >&2
    exit 0
fi

# === --self-test: hermetic 自己完結テスト(fail-closed・orch-1r7 G3) ===
if [ "${1:-}" = "--self-test" ]; then
    st_fail=0
    st_tmp="$(mktemp -d -t spec-inject-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    # fixture plugin root(sentinel 付き top-spec)。
    mkdir -p "$st_tmp/plugin/docs"
    printf '# fixture\n<!-- spec-inject:begin -->\nPRIMER-FIXTURE-CONTENT\n<!-- spec-inject:end -->\n' \
        > "$st_tmp/plugin/docs/scriptorium-top-spec.md"

    # 台帳 fixture。
    mkdir -p "$st_tmp/anchor/.beads";  printf '{"dolt_database":"orch"}' > "$st_tmp/anchor/.beads/metadata.json"
    mkdir -p "$st_tmp/foreign/.beads"; printf '{"dolt_database":"un"}'   > "$st_tmp/foreign/.beads/metadata.json"
    mkdir -p "$st_tmp/anchor/.worktrees/spawn/wt"        # 台帳 walk-up は anchor(orch)へ届く worktree
    mkdir -p "$st_tmp/anchor/.claude/worktrees/wt2"      # CC-native worktree

    # hazard-faithful stub tmux(consult 経路・M2 teeth)。`-t <pane>` 明示時のみ「その pane の窓名」= $STUB_WNAME
    # を返す(空なら非0=取得失敗を模す)。`-t <value>` 不在(bare 形 = mutation M2)は focused 別窓を模し非 consult 名
    # orchestrator を返す → -t "$TMUX_PANE" を落とすと consult 判定が焦点窓へ倒れ b-1 が RED になる(load-bearing pin)。
    mkdir -p "$st_tmp/bin"
    cat > "$st_tmp/bin/tmux" <<'TMUXEOF'
#!/usr/bin/env bash
have_t=0; prev=""
for a in "$@"; do
    if [ "$prev" = "-t" ] && [ -n "$a" ]; then have_t=1; fi
    prev="$a"
done
if [ "$have_t" -eq 1 ]; then
    [ -n "${STUB_WNAME:-}" ] || exit 1
    printf '%s\n' "$STUB_WNAME"
else
    printf '%s\n' "orchestrator"
fi
TMUXEOF
    chmod +x "$st_tmp/bin/tmux"

    _st_run() {  # $1=cwd → fixture plugin root で本 script を fresh 起動し stdout を返す(TMUX 無し=非 consult 経路)
        # env -u TMUX: self-test を実 tmux window 内で回したときに consult gate が実 tmux を呼ばないよう遮断(hermetic)。
        printf '{"cwd":"%s"}' "$1" | env -u TMUX -u TMUX_PANE -u ORCH_SPEC_INJECT_TOP_SPEC CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" bash "$0" 2>/dev/null
    }
    _st_run_consult() {  # $1=cwd $2=window-name(空→tmux 失敗を模す) : TMUX + stub tmux 付きで起動(consult 経路)
        printf '{"cwd":"%s"}' "$1" | env -u ORCH_SPEC_INJECT_TOP_SPEC CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" \
            PATH="$st_tmp/bin:$PATH" TMUX="/tmp/fake,1,0" TMUX_PANE="%9" STUB_WNAME="$2" \
            bash "$0" 2>/dev/null
    }
    _st_inject() {  # $1=label $2=cwd : 注入(fixture primer を含む)を期待
        local out; out="$(_st_run "$2")"
        if printf '%s' "$out" | grep -q 'PRIMER-FIXTURE-CONTENT'; then echo "ok: $1"
        else echo "FAIL: $1 — 注入を期待したが空/不一致: [$out]" >&2; st_fail=1; fi
    }
    _st_noop() {    # $1=label $2=cwd : no-op(無出力)を期待
        local out; out="$(_st_run "$2")"
        if [ -z "$out" ]; then echo "ok: $1"
        else echo "FAIL: $1 — no-op を期待したが出力あり: [$out]" >&2; st_fail=1; fi
    }
    _st_inject_c() {  # $1=label $2=cwd $3=wname : consult 経路で注入を期待
        local out; out="$(_st_run_consult "$2" "$3")"
        if printf '%s' "$out" | grep -q 'PRIMER-FIXTURE-CONTENT'; then echo "ok: $1"
        else echo "FAIL: $1 — 注入を期待したが空/不一致: [$out]" >&2; st_fail=1; fi
    }
    _st_noop_c() {    # $1=label $2=cwd $3=wname : consult 経路で no-op(無出力)を期待
        local out; out="$(_st_run_consult "$2" "$3")"
        if [ -z "$out" ]; then echo "ok: $1"
        else echo "FAIL: $1 — no-op を期待したが出力あり: [$out]" >&2; st_fail=1; fi
    }

    _st_inject "orch anchor cwd → 注入"                        "$st_tmp/anchor"
    _st_noop   "orch worktree(.worktrees/) → no-op"            "$st_tmp/anchor/.worktrees/spawn/wt"
    _st_noop   "orch worktree(.claude/worktrees/) → no-op"     "$st_tmp/anchor/.claude/worktrees/wt2"
    _st_noop   "foreign 台帳 → no-op(self-scope)"              "$st_tmp/foreign"

    # consult 窓 第3軸(orch-qcqz)。
    _st_noop_c   "consult 窓(consult-*) → anchor cwd でも no-op(b-1)"        "$st_tmp/anchor" "consult-abc"
    _st_inject_c "非 consult 窓(orchestrator) → 注入(b-2)"                   "$st_tmp/anchor" "orchestrator"
    _st_inject_c "tmux 窓名取得不能 → 注入(fail-safe・b-4)"                  "$st_tmp/anchor" ""
    _st_noop_c   "foreign 台帳 + consult 窓 → no-op(self-scope 先勝ち・b-3)" "$st_tmp/foreign" "consult-abc"

    # 非vacuity(mutation): sentinel を壊すと anchor でも no-op(fail-open)＝gate が本当に doc に依存。
    printf '# broken\n(no sentinels here)\n' > "$st_tmp/plugin/docs/scriptorium-top-spec.md"
    _st_noop   "mutation: sentinel 破壊 → anchor でも no-op(fail-open・非vacuous)" "$st_tmp/anchor"

    # TOP_SPEC seam(sc-300x/orch-ocbx): default doc は直前の mutation で破壊済み → seam の alt doc から
    # 注入されれば seam 解決が効いている非vacuous 証明(seam を no-op 化すると default 破壊経路へ落ち RED)。
    mkdir -p "$st_tmp/alt"
    printf '# alt\n<!-- spec-inject:begin -->\nSEAM-FIXTURE-CONTENT\n<!-- spec-inject:end -->\n' \
        > "$st_tmp/alt/spec.md"
    _st_seam_run() {  # $1=cwd : seam を alt doc へ向けて fresh 起動
        printf '{"cwd":"%s"}' "$1" | env -u TMUX -u TMUX_PANE \
            ORCH_SPEC_INJECT_TOP_SPEC="$st_tmp/alt/spec.md" CLAUDE_PLUGIN_ROOT="$st_tmp/plugin" \
            bash "$0" 2>/dev/null
    }
    out="$(_st_seam_run "$st_tmp/anchor")"
    if printf '%s' "$out" | grep -q 'SEAM-FIXTURE-CONTENT'; then
        echo "ok: seam: ORCH_SPEC_INJECT_TOP_SPEC → alt doc から注入(非vacuous)"
    else echo "FAIL: seam — alt doc からの注入を期待したが空/不一致: [$out]" >&2; st_fail=1; fi
    # seam 経路の fail-open: seam の指す doc の sentinel が壊れていれば従来どおり no-op(検査ロジック共有)。
    printf '# broken alt\n(no sentinels here)\n' > "$st_tmp/alt/spec.md"
    out="$(_st_seam_run "$st_tmp/anchor")"
    if [ -z "$out" ]; then echo "ok: seam: 壊れた alt doc → no-op(fail-open が seam 経路でも同一)"
    else echo "FAIL: seam fail-open — no-op を期待したが出力あり: [$out]" >&2; st_fail=1; fi

    if [ "$st_fail" -eq 0 ]; then echo "spec-inject --self-test: PASS"; exit 0
    else echo "spec-inject --self-test: FAIL" >&2; exit 1; fi
fi

# === self-scope: 非 orchestrator session は無出力で exit 0(no-op) ===
hook_cwd="$(_extract_cwd)"
[ -z "$hook_cwd" ] && hook_cwd="$PWD"
if ! _is_orch_session "$hook_cwd"; then
    exit 0   # 他 project / 判定不能 session へは一切注入しない(誤注入ゼロ)
fi

# === cwd 第2軸(orch-1r7 G3): orch worktree(自己開発 worker cell)には top-layer primer を注入しない ===
# 台帳 self-scope は通過するが cwd が worktree 配下なら anchor でない＝別 role(scribe worker)ゆえ no-op。
# SCRIBE_ROLE 非依存の純 cwd 判定(anchor だけ発火・drift #3 修正)。
if _is_worktree_cwd "$hook_cwd"; then
    exit 0
fi

# === consult 窓 第3軸(orch-qcqz b-1): consult 窓へは orchestrator primer を注入しない ===
# consult は anchor 同居ゆえ self-scope(orch)と cwd 第2軸を素通りする(consult 窓の cwd = anchor 自身)。だが
# consult は別 role(read-only 相談役)で top-layer primer を注入すると orchestrator 文脈が漏れる(原 (2))。
# tmux window 名 consult-* で弁別(env SCRIBE_ROLE は settings.json none に潰され使用不可・verified)。
# 取得不能(tmux 不在 / $TMUX 未設定 / 窓名取得不能)は非 consult 扱い＝注入継続(fail-safe・b-4)。
if _is_consult_window; then
    exit 0
fi

# === orchestrator session: SSOT doc から primer を逐語抽出して注入 ===
if [ ! -r "$TOP_SPEC" ]; then
    echo "[orchestrator/SessionStart] warning: top-spec 不在($TOP_SPEC)・role 文脈注入を skip(fail-open continue)" >&2
    exit 0
fi

# sentinel が begin/end **各ちょうど 1 個** であることを抽出前に確認する(欠落・片側欠落・複数ペアの
# over-inject 防止)。sed の範囲アドレス `/begin/,/end/p` は (a) 終端 end が現れないと begin から EOF
# まで出力し(end 欠落 → §8 primer 以降の top-spec 後続全文が漏出)、(b) ペアが 2 組以上あると 1 組目 end
# の後に 2 組目 begin で再 arm され中間 sentinel 行 + 2 組目本文まで出力する。いずれも `1d;$d`(先頭/末尾
# 1 行剥がし)では除去しきれず over-inject になり、かつ primer が非空ゆえ下の fail-open 分岐
# (`[ -z "$primer" ]`)を素通りする。よって count==1 を gate にして、欠落/片側/複数ペアは一律 warning +
# exit0 の fail-open へ落とす(begin の散文言及 line 97 は `begin/end` 結合形で exact パターンに不一致ゆえ
# 計上されない)。grep -c は readable な doc に対し常に非負整数を返す(到達前に `[ ! -r ]` で弾く)。
nbegin="$(grep -c '<!-- spec-inject:begin -->' "$TOP_SPEC" 2>/dev/null)"; nbegin="${nbegin:-0}"
nend="$(grep -c '<!-- spec-inject:end -->' "$TOP_SPEC" 2>/dev/null)"; nend="${nend:-0}"
if [ "$nbegin" != 1 ] || [ "$nend" != 1 ]; then
    echo "[orchestrator/SessionStart] warning: top-spec の spec-inject sentinel は begin/end 各 1 組のみ可(現在 begin=$nbegin end=$nend)・欠落/重複ゆえ注入を skip(fail-open continue)" >&2
    exit 0
fi

# sentinel 区間を逐語抽出(sed range → 先頭/末尾の sentinel 行を除去・awk 非依存)。
primer="$(sed -n '/<!-- spec-inject:begin -->/,/<!-- spec-inject:end -->/p' "$TOP_SPEC" 2>/dev/null | sed '1d;$d')"
if [ -z "$primer" ]; then
    echo "[orchestrator/SessionStart] warning: top-spec の spec-inject sentinel 区間が空/欠落($TOP_SPEC)・注入を skip(fail-open continue)" >&2
    exit 0
fi

echo "=== [orchestrator/SessionStart] role 文脈注入(spec-inject・self-scope: orch session のみ) ==="
echo ""
printf '%s\n' "$primer"

exit 0

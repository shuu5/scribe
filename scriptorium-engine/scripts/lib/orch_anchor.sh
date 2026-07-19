#!/usr/bin/env bash
# orch_anchor.sh — scriptorium anchor 動的解決 + external repo cell scan roots の共有 shell lib（bd orch-49g）
#
# 役割: orchestrator の 4 script が byte 複製していた「script 実体（symlink 解決後）が属する repo の main
#   worktree（= anchor）を `git worktree list` 先頭から動的解決する」ロジック（`_resolve_scriptorium` ×3 /
#   fleet-monitor `resolve_anchor` ×1）と、外部 repo cell registry を読み scan root を emit する
#   `_external_scan_roots`（dispatch / degraded-watch ×2）を**単一 SSOT**へ集約したもの。以下の 4+2 consumer が
#   `source` でこの lib を consume する（pso gate WF の drift germ 指摘 → orch-49g で恒久解消）:
#     _resolve_scriptorium: orch-clean-state-probe.sh / orch-degraded-watch.sh / orch-dispatch.sh / fleet-monitor.sh
#     _external_scan_roots: orch-dispatch.sh / orch-degraded-watch.sh
#
# E2 anchor 検証（本 lib が旧 byte 複製に足す moat）: 旧実装は解決候補を**無検証**で採用していた。script 実体が
#   repo 外（1 file コピー等の deploy 形態）に在ると `self_dir` leg の git 解決が失敗し `$PWD` leg へ落ちる。
#   このとき $PWD が**別 project の git repo**配下だと `git -C $PWD worktree list` 先頭がその foreign repo の
#   anchor を返し、orchestrator が foreign anchor を silent 採用してしまう（E2）。本 lib は解決候補の台帳を
#   `_ledger_dolt_database`（orch_session.sh・_json_is_valid gate 済み walk-up）で読み **dolt_database==SELF_PREFIX
#   （="orch"）を満たす候補のみ採用**する。満たさない候補は reject し次 leg → 全 leg reject なら return 1 で
#   consumer 側の解決不能処理へ倒す（engine consumer は deploy-layout hardcode fallback を持たず fail-loud する）。orch identity（dolt_database 判定・dir 名非依存）と対称な anchor 解決になり、foreign anchor の誤採用を
#   **構造的に**塞ぐ（orch-dispatch に self-scope/anchor gate が無かった非対称も、全 consumer が本 lib を通ることで
#   同時に解消される）。★検証は「reject（=候補を採らない）」だけで、正しい orch anchor（canonical でも非 canonical
#   でも dolt_database==orch なら）は従来どおり採用する＝真陽性を落とさない安全な追加。
#
# SELF_PREFIX 契約（orch_session.sh と同型・重要）: `_anchor_is_orch` は自台帳 prefix を `"${SELF_PREFIX:-orch}"`
#   で参照する。consumer が `SELF_PREFIX="orch"` を定義していればそれを、未定義でも既定 "orch" を使う（fleet-monitor
#   は SELF_PREFIX を定義しないため既定に倒れる）。orch_session.sh の `_is_orch_session` が bare `$SELF_PREFIX` を
#   要求するのと異なり、本 lib は `:-orch` 既定を持つので SELF_PREFIX 未定義の consumer でも `set -u` 下で安全。
#
# orch_session.sh 依存（transitive source）: 本 lib は source 時に BASH_SOURCE 相対で orch_session.sh を source し
#   `_ledger_dolt_database` を取り込む（consumer が別途 orch_session.sh を source していなくても E2 検証が効く）。
#   orch_session.sh が読めない環境では `_anchor_is_orch` が「検証不能 → 安全側 reject」に倒れる（=解決不能＝
#   consumer の fail-loud へ・foreign を誤採用しない fail-closed）。source 不能時は loud warning を stderr へ出す（silent 無効化を
#   避ける）。★実 script 位置（BASH_SOURCE 相対）で解決するので bats / `--self-test` が CLAUDE_PLUGIN_ROOT を
#   fixture へ向けても実 lib を確実に見つける（orch_session.sh と同じ理由）。
#
# 空白 path 安全（axg gate 提案）: 旧 `awk '/^worktree /{print $2; exit}'` は path に空白があると $2 で切れる。
#   本 lib は `sed -n 's/^worktree //p' | head -n1`（porcelain 行全体から `worktree ` prefix だけを strip）で
#   空白入り path を保つ。
#
# anchor 明示化 config seam（bd orch-w9we.1 DONE 到達域 1・repo 再編 epic orch-w9we）: `_resolve_scriptorium` は
#   先頭で明示 config seam ORCH_ANCHOR（env）/ ORCH_ANCHOR_CONFIG（config file）を検査する。engine（本 lib + consumer
#   群）が scribe repo subdir へ移設されると (1) 動的導出（script 居場所依存）は sc anchor を指し E2 reject されて
#   構造的に失効する＝これは**設計どおり**で、失効を「明示 config」で解く（private 配備層が ORCH_ANCHOR を供給し
#   engine は読むだけ＝mechanism/value 分離）。additive: 明示 seam unset なら従来の動的導出へ byte 不変で倒れ、systemd
#   （orch-hydrate は cwd 基準で本 lib 非依存）や既存 bats（per-consumer env override で本関数を短絡）に非影響。詳細は
#   `_resolve_scriptorium` の (0) ブロック doc を SSOT とする。
#
# never-die 契約: 全 helper は filesystem stat/read と外部コマンドの 2>/dev/null のみで例外 die しない（判定不能 →
#   空文字/非0 へ degrade）。`set -uo pipefail` 下で source/呼出しても安全なよう位置引数は `${1:-}` で受ける。
#
# source 方法（consumer は実 script 位置 = BASH_SOURCE 相対で解決すること）:
#   scripts/ 直下の consumer（degraded-watch / clean-probe / dispatch / fleet-monitor）:
#     `. "<scripts>/lib/orch_anchor.sh"`（各 consumer が SCRIPTORIUM 代入の**前**に source すること＝E2 検証に
#      _ledger_dolt_database が要るため）。
#
# 検証: 本 lib の `--self-test`（直接実行時のみ・hermetic・fail-closed・git を PATH stub 化して E2 accept/reject を
#   exercise）+ dedicated bats tests/scenarios/orch-anchor-lib.bats + 4 consumer の既存 bats 全 green（意味論不変）。

# --- orch_session.sh を source（_ledger_dolt_database を E2 anchor 検証に再利用・BASH_SOURCE 相対で実 lib 解決） ---
_ORCH_ANCHOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -n "${_ORCH_ANCHOR_DIR:-}" ] && [ -r "$_ORCH_ANCHOR_DIR/../hooks/lib/orch_session.sh" ]; then
    # shellcheck source=../hooks/lib/orch_session.sh
    . "$_ORCH_ANCHOR_DIR/../hooks/lib/orch_session.sh"
else
    # loud warning（silent 無効化を避ける）。_anchor_is_orch は _ledger_dolt_database 不在を検出し安全側 reject する。
    echo "orch_anchor.sh: orch_session.sh を source できません（$_ORCH_ANCHOR_DIR/../hooks/lib/orch_session.sh）＝E2 anchor 検証は検証不能→安全側 reject（解決不能なら consumer は fail-loud）" >&2
fi

# --- 解決候補 anchor が自台帳（dolt_database==SELF_PREFIX）か検証（E2 封鎖の核・foreign anchor を reject） ---
# 候補の .beads/metadata.json の dolt_database を _ledger_dolt_database（_json_is_valid gate 済み）で読み、
# SELF_PREFIX（既定 "orch"）と完全一致なら 0（採用可）。空文字/不一致/検証器不在は非0（reject＝安全側）。
# _ledger_dolt_database が未定義（orch_session.sh 不在）なら検証不能ゆえ非0（reject）に倒す＝foreign 誤採用しない。
# ★候補 root **自身**の .beads/metadata.json を要求する（walk-up false-accept 封じ）: _ledger_dolt_database は
#   cand から上方向へ walk-up するため、候補 root 自身が .beads を持たないと**祖先**の台帳（例: foreign repo が
#   orch anchor 配下に nest したとき）を継承して foreign 候補を誤 accept しうる。anchor は repo の main worktree
#   root＝自身の .beads を持つのが正常ゆえ、自身の台帳を要求すれば真陽性を落とさず祖先継承の穴だけを塞ぐ。
_anchor_is_orch() {
    local cand="${1:-}" db
    [ -n "$cand" ] || return 1
    [ -f "$cand/.beads/metadata.json" ] || return 1   # 候補 root 自身の台帳を要求（walk-up 祖先継承の false-accept を封じる）
    command -v _ledger_dolt_database >/dev/null 2>&1 || return 1   # 検証不能 → 安全側 reject
    db="$(_ledger_dolt_database "$cand" 2>/dev/null)"
    [ "$db" = "${SELF_PREFIX:-orch}" ]
}

# --- scriptorium anchor 動的解決（symlink 解決後の script 実体が属する repo の main worktree＝anchor） ---
# `git worktree list` 先頭（main worktree は porcelain 出力の先頭に必ず出る）から解決する。worktree copy から
# 起動しても anchor へ解決される。self_dir leg（script 実体の dir）→ $PWD leg の順に試し、各候補を _anchor_is_orch
# で検証する（E2: foreign repo anchor を採らない）。全候補 reject なら return 1（engine consumer は fail-loud
# する＝hardcode fallback を持たない）。env override（ORCH_*_SCRIPTORIUM / FLEET_MONITOR_ANCHOR）を持つ consumer では `${VAR:-...}` の
# 既定非展開でそもそも本関数は呼ばれない＝git を一切叩かない（既存 bats は override ゆえ副作用ゼロ）。
_resolve_scriptorium() {
    # ── (0) 明示 config seam（anchor 設定明示化・bd orch-w9we.1 DONE 到達域 1）─────────────────────────────
    #   engine（本 lib + consumer 群）が scribe repo subdir へ移設されると、下記 (1) の self_dir leg は sc repo の
    #   anchor（dolt_database==sc）を指し E2 reject され、$PWD leg も cwd が scriptorium 外だと解決しない＝**自導出
    #   が構造的に失効する（設計どおり・裁定 orch-w9we.1 誤実装ガード）**。この失効を「script 居場所依存」でなく
    #   **明示 config**（private 配備層が供給）で解く: private 配備層（systemd unit の Environment / launcher wrapper /
    #   config file）が ORCH_ANCHOR か ORCH_ANCHOR_CONFIG を供給し、engine はそれを読むだけにする（mechanism=public /
    #   value=private の分離）。
    #     ORCH_ANCHOR         明示 anchor 絶対 path（最優先の明示 seam）。
    #     ORCH_ANCHOR_CONFIG  config file path。先頭の非空・非コメント(#)行を anchor path として読む（空白 path 安全）。
    #   採用は必ず `_anchor_is_orch` 検証を通す（foreign を明示指定しても E2 で弾く）。★明示値が **set-but-invalid**
    #   （env/config が供給されたが orch 台帳でない）なら **loud stderr + return 1** で fail-loud する＝誤設定を
    #   silent に握り潰して (1) 動的導出や consumer hardcode へ倒さない（「env 供給されたが不正」を surface）。明示値
    #   unset のときのみ (1) 動的導出へ進む（＝既存挙動を byte 不変で温存・additive seam）。★fail-loud の対象は
    #   「値が供給されたが orch 台帳でない」ケースに限る: ORCH_ANCHOR_CONFIG が set でも file が unreadable（-r 失敗）or
    #   中身が全コメント/空で cfg_anchor が空になる場合は「供給されていない」（unset と同一）扱いで (1) 動的導出へ倒す
    #   （additive・診断メッセージの具体性のみ劣化・動的導出も _anchor_is_orch を必ず通すため foreign 採用の fail-open は
    #   無い）。＝fail-loud は「解決すべき明示値があるのに orch でない」誤設定に絞り、config 不在は additive に扱う。
    #   ★per-consumer env（ORCH_*_SCRIPTORIUM / FLEET_MONITOR_ANCHOR）は consumer 側の ${VAR:-...} で本関数**呼出前**に
    #     短絡するため、precedence は per-consumer env > ORCH_ANCHOR > ORCH_ANCHOR_CONFIG > 動的導出（engine
    #     consumer は hardcode fallback を持たず、全 leg 解決不能は consumer 側 fail-loud）。
    local cfg_anchor=""
    if [ -n "${ORCH_ANCHOR:-}" ]; then
        cfg_anchor="$ORCH_ANCHOR"
    elif [ -n "${ORCH_ANCHOR_CONFIG:-}" ] && [ -r "${ORCH_ANCHOR_CONFIG}" ]; then
        cfg_anchor="$(grep -vE '^[[:space:]]*(#|$)' "$ORCH_ANCHOR_CONFIG" 2>/dev/null | head -n1 | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    fi
    if [ -n "$cfg_anchor" ]; then
        if _anchor_is_orch "$cfg_anchor"; then printf '%s' "$cfg_anchor"; return 0; fi
        echo "orch_anchor: 明示 anchor（ORCH_ANCHOR / ORCH_ANCHOR_CONFIG='$cfg_anchor'）が orch 台帳でない（E2 reject）＝設定を確認せよ。動的導出/hardcode へ倒さず fail-loud return 1。" >&2
        return 1
    fi

    # ── (1) 動的導出（既存・明示 seam unset のときの fallback）────────────────────────────────────────────
    local self_real self_dir d top
    self_real="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
    self_dir="$(cd "$(dirname "$self_real")" 2>/dev/null && pwd || printf '%s' "$(dirname "$self_real")")"
    for d in "$self_dir" "$PWD"; do
        # 空白 path 安全（axg）: porcelain 行から `worktree ` prefix を strip（awk $2 は空白で切れる）。
        top="$(git -C "$d" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1)"
        [ -n "$top" ] || continue
        _anchor_is_orch "$top" && { printf '%s' "$top"; return 0; }
    done
    return 1
}

# --- repo の default branch（main worktree の checked-out branch）を per-repo 解決（read-only・orch-665） ---
# 外部 repo cell の base 解決（Option B・orch-b10 follow-up）: 外部 repo が local `main` を持たない
#   （master/develop/trunk 既定）と gate-pending / degraded-watch の `git rev-list --count main..HEAD` が
#   非0終了し、Option A では「判定不能」fail-loud surface（安全な over-flag だが lossy＝正確な commit 数が
#   出ず、merge 済 non-main worktree が cleanup 前に一時 false-positive 化しうる）だった。本 helper は
#   external repo の **default branch を main worktree の symbolic-ref HEAD** から per-repo 解決して commit
#   数を正確化する（両 consumer が external root に対してのみ呼ぶ・self root は base=main 常時解決可ゆえ
#   従来の global base + fail-open を維持する＝orch-dispatch (E5) の非対称を壊さない）。
# 引数: $1 = repo 内の任意 path（repo root または worktree）。stdout: default branch 名（例 master）。
#   rc 0=解決成功 / 非0（空 stdout）=解決不能（consumer は global base へ fallback＝従来の「判定不能」経路へ倒れる）。
# 解決手順（_resolve_scriptorium と同型・空白 path 安全）:
#   (1) `git -C <at> worktree list --porcelain` 先頭 = main worktree（porcelain 出力の先頭に必ず main が出る）。
#   (2) `git -C <main_wt> symbolic-ref --short HEAD` = main worktree の checked-out branch（= default branch）。
#       ★cell worktree（$at が spawn cell）自身の HEAD は spawn/<id> を指すため symbolic-ref を **main worktree**
#         に対して叩く（worktree list 先頭経由）＝cell の branch を base に取り違えない。
#   return 1（解決不能）の trigger は 2 系統: (i) main worktree が detached HEAD＝symbolic-ref が rc≠0（RB-detached/
#     M8 で pin）/ (ii) 非 git dir・git 障害で worktree list が空＝main_wt 取得不能（RB-empty で pin）。いずれも
#     consumer が global base（main）へ fallback＝Option A の「判定不能」fail-loud へ自然に倒れる。★bare repo は
#     return 1 に**含めない**: bare でも worktree list は bare path を先頭に返し symbolic-ref は HEAD の default
#     branch 名を rc 0 で返すため本 helper は branch 名を返す（fallback するとすれば後段の rev-list 失敗経由で
#     あって本 helper の return 1 ではない）。orchestration 上 external repo cell は working repo で bare は現れない。
# read-only（worktree list / symbolic-ref のみ＝mutate しない）＝両 consumer の read-only verb discipline を侵さない。
_resolve_repo_base() {
    local at="${1:-}" main_wt base
    [ -n "$at" ] || return 1
    # (1) main worktree = porcelain 先頭（空白 path 安全: sed で `worktree ` prefix だけ strip・axg 同型）。
    main_wt="$(git -C "$at" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | head -n1)"
    [ -n "$main_wt" ] || return 1
    # (2) default branch = main worktree の checked-out branch（symbolic-ref HEAD・detached/bare は失敗→return 1）。
    base="$(git -C "$main_wt" symbolic-ref --short HEAD 2>/dev/null)"
    [ -n "$base" ] || return 1
    printf '%s' "$base"
}

# --- cell HEAD と base の包含関係を分類（containment gate・read-only・orch-igl / orch-665 follow-up） ---
# `_resolve_repo_base` は「main worktree の現在 checkout branch」で default branch を近似する（安定源 origin/HEAD は
#   remote を持たない fixture を全 break させるため不採用＝Option B）。この近似は foreign main worktree が**非 default
#   branch**（cell 系列から乖離した branch）を checkout 中だと、per-repo base が cell の系列外を指し `rev-list base..HEAD`
#   の commit 数が不正確になる（gate-pending は silent-drop / degraded は salvage/suspect 誤分類・count 不正確）。本
#   helper は base と cell HEAD の**包含関係**を弁別し、素朴な `merge-base --is-ancestor` gate が harm(b)（0-ahead の
#   merge 済 cell で default が cell 先へ前進し base 非祖先化する契約）と衝突する問題を避ける:
#   引数: $1 = cell worktree path / $2 = base ref 名。
#   stdout / rc:
#     "contained"      rc0 = HEAD⊂base（a=rev-list base..HEAD=0）＝統合済/未着手 → consumer は drop 維持（harm(b) を守る）。
#     "ahead <n>"      rc0 = base⊂HEAD（a>0 ∧ b=rev-list HEAD..base=0）＝base は HEAD の祖先で HEAD が n 先行 → surface。
#     "diverged <n>"   rc0 = base⊀HEAD ∧ HEAD⊄base（a>0 ∧ b>0）＝乖離（非 default checkout 等で base が cell 系列外）→
#                            consumer は count 不正確ゆえ「乖離」で fail-loud（silent-drop / 誤 count しない）。<n> は
#                            参考の a（実 base に対する先行数だが base が系列外ゆえ不正確・render では使わない）。
#     ""               rc1 = git 解決不能（base が repo に無い等で rev-list 非0終了）→ consumer は従来の「判定不能」/skip へ。
#   read-only（rev-list --count のみ＝mutate しない）＝両 consumer の read-only verb discipline を侵さない。SEC1 allowlist
#     の既存 verb（rev-list --count）だけを使い新 verb を増やさない（invocation-log 検査を通す）。
_repo_base_relation() {
    local wt="${1:-}" base="${2:-}" a b
    [ -n "$wt" ] && [ -n "$base" ] || return 1
    a="$(git -C "$wt" rev-list --count "$base..HEAD" 2>/dev/null)" || return 1
    [ -n "$a" ] || return 1
    # ★a-first 短絡（load-bearing・harm(b) の核）: a=0（HEAD⊂base）なら b を見ずに contained を返す。これは harm(b) の
    #   中核 modality＝**a=0 ∧ b>0**（0-ahead の merge 済 cell の背後で default が cell 先へ前進し base が cell の
    #   非祖先化する）を正しく contained（drop 維持）と判定するため。素朴な `merge-base --is-ancestor base HEAD`
    #   gate や b を先に見る順序だと、この a=0 ∧ b>0 を「base 非祖先＝diverged」と誤分類し merge 済 cell を
    #   false-positive surface してしまう（RREL-contained-advanced / harm(b)-advanced が pin する）。
    if [ "$a" -eq 0 ] 2>/dev/null; then
        printf 'contained'; return 0        # HEAD⊂base（a=0・b は不問）→ 統合済/未着手 → drop 維持（harm(b)）
    fi
    b="$(git -C "$wt" rev-list --count "HEAD..$base" 2>/dev/null)" || return 1
    [ -n "$b" ] || return 1
    if [ "$b" -gt 0 ] 2>/dev/null; then
        printf 'diverged %s' "$a"; return 0 # base⊀HEAD ∧ HEAD⊄base（乖離）→ fail-loud
    fi
    printf 'ahead %s' "$a"; return 0         # base⊂HEAD（HEAD が a 先行）→ surface
}

# --- external repo cell registry を読み scan root（<root>/.worktrees/spawn）を emit（read-only・orch-b10） ---
# orch-dispatch が `--repo <外部 project>` 外部 repo cell の repo root を registry（$EXTERNAL_REGISTRY・1 行 1
#   絶対 root）に記録する。gate-pending / degraded scan がこれを読み <root>/.worktrees/spawn を走査＝外部 repo
#   cell の窓消失/未 merge を監視射程へ入れる（宣言 write が worker sandbox で断たれても構造検知・incident orch-7ti）。
#   self（$SCRIPTORIUM）一致 root は二重 scan 回避で skip・非存在 root は skip（cell 撤去/repo 削除後は自然消滅）。
#   orch-b10 E3: read 側 dedupe（_register_external_repo の grep→append は非アトミック TOCTOU ゆえ registry に重複
#   行が残留しうる・read 側で emit 済み root を skip し scan の二重 emit を防ぐ）。$EXTERNAL_REGISTRY / $SCRIPTORIUM は
#   caller-global（consumer が代入済み）を参照する。file read のみ＝read-only verb discipline（bd/tmux/git）を侵さない。
_external_scan_roots() {
    local reg="$EXTERNAL_REGISTRY" line canon self_canon real seen
    [ -f "$reg" ] || return 0
    self_canon="$(readlink -f "$SCRIPTORIUM" 2>/dev/null || printf '%s' "$SCRIPTORIUM")"
    seen=$'\n'
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in \#*) continue ;; esac
        canon="$(readlink -f "$line" 2>/dev/null || printf '%s' "$line")"
        [ "$canon" = "$self_canon" ] && continue
        real="$canon/.worktrees/spawn"
        [ -d "$real" ] || continue
        case "$seen" in *$'\n'"$real"$'\n'*) continue ;; esac
        seen="$seen$real"$'\n'
        printf '%s\n' "$real"
    done < "$reg"
}

# === --self-test: 直接実行時のみの hermetic 自己完結テスト（fail-closed・orch-49g） ===
# source 時（BASH_SOURCE[0] != $0）はこのブロックを skip する（consumer の $1 継承で誤発火しない）。
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    if [ "${1:-}" != "--self-test" ]; then
        echo "orch_anchor.sh は source して使う共有 lib です（--self-test で自己検証）。" >&2
        exit 0
    fi

    SELF_PREFIX="orch"   # self-test は caller を持たないので自前で定義（header の SELF_PREFIX 契約）。
    st_fail=0
    st_tmp="$(mktemp -d -t orch-anchor-selftest-XXXXXX)" || { echo "self-test: mktemp 失敗" >&2; exit 1; }
    trap 'rm -rf "$st_tmp"' EXIT

    _ok()   { echo "ok: $1"; }
    _fail() { echo "FAIL: $1" >&2; st_fail=1; }
    # _skip: 環境依存で当該 assertion を実行できない枝の明示 note（orch-igl item4）。_ok と違い「pass」を主張しない
    #   ＝git<2.28 で `git init -b` が失敗し RB assertion が走らないのに ok を刷る silent vacuous 化を避ける。st_fail は
    #   触らない（skip は fail でない）が、pass の偽装もしない（skip 行として可視化）。
    _skip() { echo "skip: $1"; }

    # --- 台帳 fixture ---
    mkdir -p "$st_tmp/orch_anchor/.beads";     printf '{"dolt_database":"orch"}' > "$st_tmp/orch_anchor/.beads/metadata.json"
    mkdir -p "$st_tmp/foreign_anchor/.beads";  printf '{"dolt_database":"un"}'   > "$st_tmp/foreign_anchor/.beads/metadata.json"
    mkdir -p "$st_tmp/broken_anchor/.beads";   printf '{"dolt_database":"orch"'  > "$st_tmp/broken_anchor/.beads/metadata.json"  # 未閉じ=破損
    mkdir -p "$st_tmp/nometa_anchor/.beads"    # metadata.json 無し

    # --- _anchor_is_orch（E2 検証核の unit teeth） ---
    _anchor_is_orch "$st_tmp/orch_anchor" \
        && _ok "_anchor_is_orch: orch 台帳 → accept" || _fail "_anchor_is_orch: orch 台帳 → accept を期待"
    if _anchor_is_orch "$st_tmp/foreign_anchor"; then
        _fail "_anchor_is_orch: foreign(un) 台帳 → reject を期待したが accept"
    else
        _ok "_anchor_is_orch: foreign(un) 台帳 → reject（E2 封鎖）"
    fi
    if _anchor_is_orch "$st_tmp/broken_anchor"; then
        _fail "_anchor_is_orch: 破損 orch-token 台帳 → reject を期待したが accept"
    else
        _ok "_anchor_is_orch: 破損 orch-token 台帳 → reject（_json_is_valid gate）"
    fi
    if _anchor_is_orch "$st_tmp/nometa_anchor"; then
        _fail "_anchor_is_orch: metadata 無し → reject を期待したが accept"
    else
        _ok "_anchor_is_orch: metadata 無し → reject"
    fi
    if _anchor_is_orch ""; then _fail "_anchor_is_orch: 空引数 → reject を期待"; else _ok "_anchor_is_orch: 空引数 → reject"; fi
    # walk-up false-accept 封じ: orch 台帳を持つ祖先の配下に、自身の .beads を持たない候補（foreign repo が nest した想定）
    #   → reject（祖先の台帳を継承して誤 accept しない）。
    mkdir -p "$st_tmp/orch_ancestor/.beads"; printf '{"dolt_database":"orch"}' > "$st_tmp/orch_ancestor/.beads/metadata.json"
    mkdir -p "$st_tmp/orch_ancestor/nested_no_beads"
    if _anchor_is_orch "$st_tmp/orch_ancestor/nested_no_beads"; then
        _fail "_anchor_is_orch: orch 祖先配下の .beads 無し候補 → reject を期待したが accept（walk-up false-accept）"
    else
        _ok "_anchor_is_orch: orch 祖先配下の .beads 無し候補 → reject（walk-up 祖先継承を封じる）"
    fi

    # --- _resolve_scriptorium（git を PATH stub 化して E2 accept/reject を end-to-end で exercise） ---
    st_bin="$st_tmp/bin"; mkdir -p "$st_bin"
    _install_git_stub() {  # $1 = worktree top を返させる path
        cat > "$st_bin/git" <<EOF
#!/usr/bin/env bash
# self-test git stub: 何を -C されても worktree list 先頭に固定 anchor を返す。
if [ "\$1" = "-C" ]; then shift 2; fi
if [ "\$1 \$2" = "worktree list" ]; then printf 'worktree %s\n' "$1"; exit 0; fi
exit 0
EOF
        chmod +x "$st_bin/git"
    }

    # (E2-accept) git が orch anchor を返す → 採用（printf でその path を返す）。
    _install_git_stub "$st_tmp/orch_anchor"
    got="$(PATH="$st_bin:$PATH" _resolve_scriptorium)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$got" = "$st_tmp/orch_anchor" ]; then
        _ok "_resolve_scriptorium: git=orch anchor → 採用（$got）"
    else
        _fail "_resolve_scriptorium: git=orch anchor の採用を期待（rc=$rc got=$got）"
    fi

    # (E2-reject) git が foreign anchor を返す → 全 leg reject → return 1（採用しない＝E2 封鎖の核）。
    _install_git_stub "$st_tmp/foreign_anchor"
    got="$(PATH="$st_bin:$PATH" _resolve_scriptorium)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
        _ok "_resolve_scriptorium: git=foreign anchor → reject・return 1（E2 封鎖・非vacuity: 検証を外すと採用して落ちる）"
    else
        _fail "_resolve_scriptorium: git=foreign anchor の reject を期待（rc=$rc got=$got）"
    fi

    # === anchor 明示化 config seam（bd orch-w9we.1 DONE 到達域 1）: engine-relocated topology を faithful 再現 ===
    #   「engine 移設後は動的導出が失効する」を **git stub が foreign anchor を返す**ことで再現する（self_dir/$PWD leg
    #   が orch を導出できない状況＝移設後 sc repo を指す状況の等価物）。この topology 下で:
    #     (ANCHOR-env)     ORCH_ANCHOR=<orch anchor> を明示供給 → 動的導出が死んでいても解決する（明示 seam の core）。
    #     (ANCHOR-mut)     ★mutation 非空虚: ORCH_ANCHOR 供給下でも「動的導出だけ」なら foreign reject で return 1 に
    #                       なる（= 明示 seam が load-bearing・no-op 化すれば RED）。git stub を foreign にしたまま
    #                       ORCH_ANCHOR を **unset** して同じ呼出しが return 1 になることで、seam を外すと解決不能＝
    #                       hardcode fallback が silent 緑化せず（本 lib は hardcode を持たず return 1）RED になる証明。
    #     (ANCHOR-cfgfile) ORCH_ANCHOR_CONFIG=<file>（先頭非コメント行に orch anchor）→ 解決する。
    #     (ANCHOR-invalid) ORCH_ANCHOR=<foreign anchor>（set-but-invalid）→ fail-loud return 1（動的/hardcode へ倒さない）。
    _install_git_stub "$st_tmp/foreign_anchor"   # 動的導出は foreign しか返せない＝engine-relocated 等価
    # (ANCHOR-env) 明示供給 → 動的導出が死んでいても orch anchor を解決。
    got="$(PATH="$st_bin:$PATH" ORCH_ANCHOR="$st_tmp/orch_anchor" _resolve_scriptorium)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$got" = "$st_tmp/orch_anchor" ]; then
        _ok "_resolve_scriptorium: ORCH_ANCHOR 明示供給 → 動的導出失効下でも解決（anchor 明示化 core）"
    else
        _fail "_resolve_scriptorium: ORCH_ANCHOR 明示供給の解決を期待（rc=$rc got=$got）"
    fi
    # (ANCHOR-mut) 同 topology で ORCH_ANCHOR を外す（明示 seam no-op 相当）→ return 1（hardcode で silent 緑化しない）。
    got="$(PATH="$st_bin:$PATH" _resolve_scriptorium)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
        _ok "_resolve_scriptorium: 明示 seam unset（engine-relocated）→ return 1（env 未供給時 fail-loud・非vacuity）"
    else
        _fail "_resolve_scriptorium: 明示 seam unset で return 1 を期待（rc=$rc got=$got）＝seam 非空虚が崩れた"
    fi
    # (ANCHOR-cfgfile) config file 経由（コメント行 + 空行を skip し先頭の実 path を読む）。
    printf '%s\n' "# orch anchor config（private 配備層供給）" "" "$st_tmp/orch_anchor" > "$st_tmp/anchor.conf"
    got="$(PATH="$st_bin:$PATH" ORCH_ANCHOR_CONFIG="$st_tmp/anchor.conf" _resolve_scriptorium)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$got" = "$st_tmp/orch_anchor" ]; then
        _ok "_resolve_scriptorium: ORCH_ANCHOR_CONFIG file → 先頭非コメント行の orch anchor を解決"
    else
        _fail "_resolve_scriptorium: ORCH_ANCHOR_CONFIG file の解決を期待（rc=$rc got=$got）"
    fi
    # (ANCHOR-invalid) 明示値が foreign（set-but-invalid）→ fail-loud return 1（動的/hardcode へ倒さない）。
    got="$(PATH="$st_bin:$PATH" ORCH_ANCHOR="$st_tmp/foreign_anchor" _resolve_scriptorium 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
        _ok "_resolve_scriptorium: ORCH_ANCHOR=foreign（set-but-invalid）→ fail-loud return 1（silent 握り潰し禁止）"
    else
        _fail "_resolve_scriptorium: 明示 foreign 値の fail-loud return 1 を期待（rc=$rc got=$got）"
    fi

    # --- _external_scan_roots（registry read / self-skip / dedup / 非存在 skip） ---
    SCRIPTORIUM="$st_tmp/self_repo"; mkdir -p "$SCRIPTORIUM/.worktrees/spawn"
    mkdir -p "$st_tmp/ext1/.worktrees/spawn" "$st_tmp/ext2/.worktrees/spawn"
    EXTERNAL_REGISTRY="$st_tmp/registry"
    # self（skip 対象）・ext1・ext2・重複 ext1（dedup）・非存在 ext3（skip）・コメント行。
    printf '%s\n' "$SCRIPTORIUM" "$st_tmp/ext1" "$st_tmp/ext2" "$st_tmp/ext1" "$st_tmp/ext3-nonexistent" "# comment" > "$EXTERNAL_REGISTRY"
    roots="$(_external_scan_roots)"
    n="$(printf '%s\n' "$roots" | grep -c .)"
    if [ "$n" -eq 2 ] \
       && printf '%s\n' "$roots" | grep -qxF "$st_tmp/ext1/.worktrees/spawn" \
       && printf '%s\n' "$roots" | grep -qxF "$st_tmp/ext2/.worktrees/spawn" \
       && ! printf '%s\n' "$roots" | grep -qxF "$SCRIPTORIUM/.worktrees/spawn"; then
        _ok "_external_scan_roots: ext1/ext2 のみ emit（self-skip / dedup / 非存在 skip・計 2 行）"
    else
        _fail "_external_scan_roots: ext1/ext2 の 2 行を期待（got n=$n）: $roots"
    fi
    # registry 不在 → 空・return 0（graceful）。
    EXTERNAL_REGISTRY="$st_tmp/no-such-registry"
    roots="$(_external_scan_roots)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$roots" ]; then
        _ok "_external_scan_roots: registry 不在 → 空・return 0（graceful）"
    else
        _fail "_external_scan_roots: registry 不在 → 空・return 0 を期待（rc=$rc）"
    fi

    # --- _resolve_repo_base（実 git で default branch を解決・orch-665・Option B） ---
    #   実 git を使う（symbolic-ref/worktree list を faithfully 叩く＝stub で fake しない）。git 不在環境のみ skip。
    if command -v git >/dev/null 2>&1; then
        rb="$st_tmp/rb_repo"
        if git init -q -b trunk "$rb" >/dev/null 2>&1; then
            git -C "$rb" config user.email t@t.t >/dev/null 2>&1
            git -C "$rb" config user.name  t      >/dev/null 2>&1
            printf 'x' > "$rb/f"; git -C "$rb" add f >/dev/null 2>&1
            git -C "$rb" -c commit.gpgsign=false commit -qm init >/dev/null 2>&1
            # (accept) default=trunk（local main 不在）を per-repo 解決する。
            got="$(_resolve_repo_base "$rb")"; rc=$?
            if [ "$rc" -eq 0 ] && [ "$got" = "trunk" ]; then
                _ok "_resolve_repo_base: default=trunk を per-repo 解決（local main 不在でも実 base を返す）"
            else
                _fail "_resolve_repo_base: trunk 解決を期待（rc=$rc got=$got）"
            fi
            # cell worktree（spawn/<id>）自身の HEAD でなく main worktree の base を返す（取り違え封じ）。
            git -C "$rb" worktree add -q -b spawn/orch-rb-1 "$rb/.worktrees/spawn/orch-rb-1" trunk >/dev/null 2>&1
            got="$(_resolve_repo_base "$rb/.worktrees/spawn/orch-rb-1")"; rc=$?
            if [ "$rc" -eq 0 ] && [ "$got" = "trunk" ]; then
                _ok "_resolve_repo_base: cell worktree 起点でも main worktree の base（trunk）を返す（cell branch を取り違えない）"
            else
                _fail "_resolve_repo_base: cell 起点で trunk を期待（rc=$rc got=$got）"
            fi
            # (reject/fallback trigger) main worktree が detached HEAD → symbolic-ref 失敗 → return 1（consumer は global base fallback）。
            git -C "$rb" checkout -q --detach >/dev/null 2>&1
            if _resolve_repo_base "$rb" >/dev/null 2>&1; then
                _fail "_resolve_repo_base: detached HEAD は return 1 を期待したが 0（fallback trigger 不発）"
            else
                _ok "_resolve_repo_base: detached HEAD → return 1（consumer の global base fallback を発火＝Option A 経路へ倒れる）"
            fi
            # (reject) 空引数 → return 1。
            if _resolve_repo_base "" >/dev/null 2>&1; then _fail "_resolve_repo_base: 空引数 → return 1 を期待"; else _ok "_resolve_repo_base: 空引数 → return 1"; fi

            # --- _repo_base_relation（containment gate・orch-igl）を同 fixture の派生で exercise ---
            #   rb_repo は trunk（= main worktree の checkout branch）。cell 相当 branch を派生させ 3 分類を実測する。
            #   (contained) cell が trunk と同一 HEAD（0-ahead）→ contained（harm(b) modality）。
            git -C "$rb" worktree add -q -b spawn/orch-rel-c "$rb/.worktrees/rel/c" trunk >/dev/null 2>&1
            got="$(_repo_base_relation "$rb/.worktrees/rel/c" trunk)"; rc=$?
            if [ "$rc" -eq 0 ] && [ "$got" = "contained" ]; then
                _ok "_repo_base_relation: 0-ahead cell（a=0 ∧ b=0）→ contained（HEAD⊂base・drop 維持で harm(b) を守る）"
            else
                _fail "_repo_base_relation: contained を期待（rc=$rc got=$got）"
            fi
            #   (contained-advanced＝harm(b) の中核 modality a=0 ∧ b>0): merge 済 cell の背後で default が前進。
            #     cell は 0-ahead のまま base が 1 先行＝素朴な ancestor gate なら「base 非祖先→diverged」と誤る場面を
            #     a-first 短絡が正しく contained に倒すことを pin（契約が名指しした harm(b) の実 modality）。fresh repo を
            #     使う（上の rb は detached 済みで trunk を進めにくいため）。
            rb2="$st_tmp/rb_adv"
            if git init -q -b master "$rb2" >/dev/null 2>&1; then
                git -C "$rb2" config user.email t@t.t >/dev/null 2>&1
                git -C "$rb2" config user.name  t      >/dev/null 2>&1
                printf 'x' > "$rb2/f"; git -C "$rb2" add f >/dev/null 2>&1
                git -C "$rb2" -c commit.gpgsign=false commit -qm init >/dev/null 2>&1
                git -C "$rb2" worktree add -q -b spawn/orch-adv-1 "$rb2/.worktrees/spawn/orch-adv-1" master >/dev/null 2>&1  # cell=master（0-ahead）
                printf 'y' > "$rb2/y"; git -C "$rb2" add y >/dev/null 2>&1
                git -C "$rb2" -c commit.gpgsign=false commit -qm advance >/dev/null 2>&1   # master を 1 先行（cell 据置＝a=0 ∧ b=1）
                got="$(_repo_base_relation "$rb2/.worktrees/spawn/orch-adv-1" master)"; rc=$?
                if [ "$rc" -eq 0 ] && [ "$got" = "contained" ]; then
                    _ok "_repo_base_relation: a=0 ∧ b>0（merge 済 cell 背後で default 前進）→ contained（harm(b) 中核・a-first 短絡が load-bearing）"
                else
                    _fail "_repo_base_relation: a=0 ∧ b>0 で contained を期待（rc=$rc got=$got）＝harm(b) 中核 modality"
                fi
            else
                _skip "_repo_base_relation: contained-advanced（a=0 ∧ b>0）は git init 失敗で skip（環境依存）"
            fi
            #   (ahead) cell が trunk を 1 先行 → "ahead 1"（base⊂HEAD）。
            git -C "$rb" worktree add -q -b spawn/orch-rel-a "$rb/.worktrees/rel/a" trunk >/dev/null 2>&1
            printf 'y' > "$rb/.worktrees/rel/a/y"; git -C "$rb/.worktrees/rel/a" add y >/dev/null 2>&1
            git -C "$rb/.worktrees/rel/a" -c commit.gpgsign=false commit -qm work >/dev/null 2>&1
            got="$(_repo_base_relation "$rb/.worktrees/rel/a" trunk)"; rc=$?
            if [ "$rc" -eq 0 ] && [ "$got" = "ahead 1" ]; then
                _ok "_repo_base_relation: 1-ahead cell → ahead 1（base⊂HEAD・正確 surface）"
            else
                _fail "_repo_base_relation: 'ahead 1' を期待（rc=$rc got=$got）"
            fi
            #   (diverged) base=非 default branch（feature=trunk+1）と cell（trunk+1・別系列）が乖離 → "diverged 1"。
            #     ★これが item(1) の核: base が cell 系列外を指すと a>0 ∧ b>0 で乖離を検出し consumer が fail-loud する。
            git -C "$rb" branch feature trunk >/dev/null 2>&1
            git -C "$rb" worktree add -q "$rb/.worktrees/feature-wt" feature >/dev/null 2>&1
            printf 'fx' > "$rb/.worktrees/feature-wt/fx"; git -C "$rb/.worktrees/feature-wt" add fx >/dev/null 2>&1
            git -C "$rb/.worktrees/feature-wt" -c commit.gpgsign=false commit -qm featwork >/dev/null 2>&1
            got="$(_repo_base_relation "$rb/.worktrees/rel/a" feature)"; rc=$?   # rel/a=trunk+1(work) vs feature=trunk+1(featwork)＝乖離
            case "$got" in
                diverged\ *) if [ "$rc" -eq 0 ]; then _ok "_repo_base_relation: 乖離 base（cell 系列外）→ diverged（a>0 ∧ b>0・fail-loud trigger＝item1 核）"; else _fail "_repo_base_relation: diverged で rc0 を期待（rc=$rc）"; fi ;;
                *)           _fail "_repo_base_relation: diverged を期待（rc=$rc got=$got）" ;;
            esac
            #   (unresolvable) 存在しない base → rc1 空 stdout（consumer は「判定不能」/skip へ）。
            if _repo_base_relation "$rb/.worktrees/rel/a" no-such-branch >/dev/null 2>&1; then
                _fail "_repo_base_relation: 存在しない base → return 1 を期待"
            else
                _ok "_repo_base_relation: 存在しない base → return 1（git 解決不能・consumer fallback）"
            fi
            #   (empty args) → return 1。
            if _repo_base_relation "" trunk >/dev/null 2>&1; then _fail "_repo_base_relation: 空 wt → return 1 を期待"; else _ok "_repo_base_relation: 空 wt → return 1"; fi
        else
            _skip "_resolve_repo_base / _repo_base_relation: git init 失敗で skip（git<2.28 で -b 非対応等・環境依存・hermetic 対象外＝pass ではない）"
        fi
    else
        _skip "_resolve_repo_base / _repo_base_relation: git 不在で skip（git はシステム前提ゆえ通常到達しない＝pass ではない）"
    fi

    if [ "$st_fail" -eq 0 ]; then echo "orch_anchor.sh --self-test: PASS"; exit 0
    else echo "orch_anchor.sh --self-test: FAIL" >&2; exit 1; fi
fi

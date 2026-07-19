#!/usr/bin/env bash
# orch-dispatch.sh — orchestrator hands-free 運用ループ（triage→spawn→gate-pending 監視→gate）の
#   dispatch 配線を成文化する薄い wrapper（bd orch-69w / orch-0w7 実装3・D1-D4）。
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   設計 SSOT は docs/orch-0w7-management-runbook.md「実装3 — dispatch 配線」+ D1-D4。本 script は
#   その how を成文化するだけ（既存 piece を流用し新規 substrate を作らない）:
#     - 投げる（orchestrator→cell）= 既存 scribe-spawn.sh（cld-spawn 経由 inject-file 送達）を呼ぶだけ。
#       新規送達コードは書かない（scribe-spawn / cld-spawn / inject-file を作り直さない）。
#     - 報告（cell→orchestrator）= beads の `gate-pending` ラベルが兼ねる（D2）。session-comm push は
#       window 名脆弱性 + inject-file の flock 欠如（orch-xyr）+ notice 原則で見送り。
#
# 4 モード ──────────────────────────────────────────────────────────────────────
#   (1) spawn（既定）  : orch-dispatch.sh <bd-id> [opts]
#       orchestrator 既定（--anchor=scriptorium・--repo=scriptorium・--base=HEAD・--model=opus）を
#       埋め込み scribe-spawn.sh を呼ぶ。
#       ★入口 fail-closed gate（orch-vji・orch-c8p B / grill G1+G2+G7 入口・doobidoo f4888921）: scribe-spawn へ
#         投げる前に契約 bead を anchor 台帳から read（`bd -C <anchor> show <id> --json`・read-only）し 3 段の入口強化を掛ける:
#           (G1) acceptance 欠落を fail-closed 拒否（非0 exit + loud message）。acceptance 無し bead は gate 裁量判定に
#                なり auto-merge トリガー①〔事前合意逸脱〕の検知基準が消えるため、dispatch を機械拒否する（防止でなく検知）。
#           (G7) verification 欄必須 check: 契約 bead の free-text に `verification: <selfTestCmd | 機械 probe 不能>`
#                （または `検証:`・全角コロン可・大小無視）が宣言されていなければ拒否。gate が selfTestCmd を再実行
#                （orch-tdj (b)）できるように、検証手段の宣言を入口で強制する。`機械 probe 不能` は probe 不能タスクの明示宣言。
#           (G2) acceptance snapshot 記録: dispatch 時に acceptance の sha256（JSON-decoded acceptance_criteria の UTF-8
#                sha256）+ 全文を `[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1]` sentinel 付きで bead notes へ **bdw 経由**
#                （自台帳 write 直列化の正路）で append する。gate 時に現 acceptance と sha256 照合し、mismatch なら
#                auto-merge 資格剥奪→人間 ratify（既存トリガー①へ接続・orch-tdj が照合側の正本）。tamper-evident な検知
#                であって防止ではない（正当な契約再交渉は再 dispatch で新 snapshot を append し塞がない）。
#         write は **自台帳（${SELF_PREFIX}-）bead のみ**（write-isolation の不可侵の核）。foreign bead は foreign admin が
#         自台帳へ記録する責務ゆえ snapshot を skip する（G1/G7 の read-only check は foreign にも掛ける）。dry-run は
#         副作用ゼロ＝read-only check は掛けるが snapshot write は skip。bd-id 実在検証はこの contract read（read 不能=中止）が兼ねる。
#       ★worker cell の対話 tool 封鎖（orch-z7g H5 / orch-ce6）は **scribe-spawn 側 hardcode が担う**（orch-4dm
#         着地形＝WORKER_DISALLOWED_TOOLS を worker spawn の cld-spawn 起動行へ無条件付与・scribe-spawn.sh:73/:570）。
#         orch-dispatch は --disallowed-tools を **forward しない**（渡すと scribe-spawn が未知オプションで die する）
#         ＝scribe-spawn を呼ぶだけで封鎖は自動的に効く。★spawn 直後に background 常駐すべき watch コマンドを
#         [ORCH-WATCH-RESIDENT] sentinel 付きで stderr へ emit（orchestrator が run_in_background で常駐＝孤児 fork
#         しない・orch-mot 規律）。
#   (2) gate-pending : orch-dispatch.sh --gate-pending   （または `gate-pending` サブコマンド）
#       gate 待ち一覧を 2 系統で出す: ① gate-pending ラベル付き cell（`bd list --label gate-pending
#       --status open,in_progress,blocked`・cross-ledger＝§3 連結 substrate hydrate で自 DB に混在する
#       foreign copy も prefix 非依存で拾い、self-dev〔自台帳 orch-・直 gate〕と外部 repo cell〔foreign
#       台帳・§5.2 外部 track・§1.1 案C gate routing〕の 2 バケットに分けて出す） + ② **un-merged spawn worktree**
#       （`.worktrees/spawn/` で base(既定 main)より先行コミットを持つもの・bead status/ラベル非依存・orch-9l1）。
#       ②は worker が自己 close しても（旧 scribe protocol §4）ラベルを付け忘れても gate 待ちを surface する
#       ＝gate の silent skip を防ぐ defense-in-depth（incident: orch-2ax/orch-2o6）。
#       ★ラベル flag は `--label`（単数）。`--labels` は存在しない無効フラグ（admin が poller で踏んだ罠）。
#       ③ foreign 鮮度警告（orch-6rb・§5.2 fail-open 補強）: 外部 repo cell バケットは事前 courier `bd repo sync`
#       成功に構造依存し、sync 未実行/失敗/古だと foreign gate-pending を silent 取りこぼす。read-only wrapper ゆえ
#       sync は呼べないが、sync 専用マーカー orch 台帳 `.beads/last-sync`（orch-hydrate.sh が `bd repo sync` 成功
#       直後にのみ stamp）の mtime を read し、stale（閾値超過）/ unknown（不在＝sync 未成立）なら⚠ 警告を添えて
#       「上の一覧が full とは限らない」を surface する（foreign が「なし」でも警告＝silent 取りこぼしを fail-loud 化）。
#       ★export-state.json は any-write proxy（ローカル write でも更新）で「active orchestrator が sync 忘れ」を
#       取りこぼすため主指標にしない（admin gate errata・freshness-soundness）。last-sync 不在時の補助表示にのみ使う。
#       fresh かつ foreign を surface した時のみ控えめ注記。
#   (3) watch（任意）  : orch-dispatch.sh --watch [--actor worker|admin|generic] <id> [opts]
#       spawn した actor の **完了（success mode）を actor 種別ごとに derive して poll** する監視 primitive
#       （admin の手動 poller の正路化）。incident orch-5pn の教訓を成文化: 監視を actor 種別を跨いで pattern
#       転用するとき「この actor の DONE は何か」を再 derive せず failure mode（stall/window-gone/timeout）だけを
#       exit 条件にすると、終わった actor を timeout まで検知できない。よって **exit 条件には failure mode だけ
#       でなく必ず success mode（完了）を入れる**。actor 種別ごとに完了シグナルが構造的に異なる:
#         - worker（既定・後方互換）: 自台帳 ${SELF_PREFIX}- の <id> が **gate-pending ラベル**を得たら完了
#           （worker は自台帳に gate-pending を出す＝MY 台帳 pull で検知できる・read-only）。
#         - admin（peer admin・foreign project）: peer admin は MY 台帳に gate-pending を出さない（自 foreign 台帳を
#           close/hold するだけ）。よって完了シグナルを 2 系統で derive する: ① **foreign bead status/park 変化**
#           （軸A: <id> の status が done-set〔既定 closed,blocked＝終端宣言 DONE/BLOCKED・orch-mot〕へ到達／軸B・
#           orch-m3r: status が done-set 外でも needs-user ラベル park の baseline からの変化＝status=open のまま park
#           宣言する契約バラつきの検知漏れを塞ぐ defense-in-depth）② **pane idle**（--window 指定時・tmux capture-pane が
#           ${IDLE_POLLS} 回連続無変化＝admin が喋り終えた）。
#           どちらか早い方で完了とする（status が authoritative・pane idle は bead 非追跡/未 close を補う INCONCLUSIVE 補助）。
#           ★①の foreign status read には 2 経路がある（orch-mot channel α）:
#             (a) **直読 poll（--foreign-repo <path>・推奨・同一マシン foreign）**: `bd -C <path> show <id> --json` で
#                 foreign 台帳を **hydrate 無しで直接 read**。bdw repo sync を介さない＝live writer との race / staleness が
#                 構造的に無い（un-93rq 直読で実証）。read のみ＝write-isolation を侵さない（actor は自台帳に write し
#                 orchestrator は foreign を read するだけ）。sync 不要ゆえ --resync と同時指定不可（fail-loud）。
#             (b) **hydrated copy + --resync（別マシン foreign 用に温存）**: 既 hydrate 済み自 DB の copy を read。
#                 --resync 指定時は事前に bdw repo sync で軽量 hydrate（live writer と race・staleness あり＝同一マシンでは(a)推奨）。
#           ★宣言なき間（actor が DONE/BLOCKED を未宣言＝status が open/in_progress・または宣言 bead 未作成で not-found）は
#             **未完(INCONCLUSIVE)** であって DONE ではない。timeout 終端も INCONCLUSIVE（宣言なき終了を決して DONE にしない・orch-mot）。
#         - generic（汎用・bead も label も無い使い捨て actor）: **pane idle のみ**（--window 必須）。
#       failure 終端: timeout=exit 3（全 actor）/ generic の window 消失=exit 4（actor 終了・完了は不定で surface）。
#       admin の window 消失は非致命（pane idle を無効化し foreign status poll を継続＝status が authoritative）。
#   (4) liveness（任意） : orch-dispatch.sh --liveness [--foreign-repo <path>] [--stale-min N]
#       hands-free relay loop の silent mutual-wait deadlock backstop（orch-edv T3・F2）。**read-only 単発 sweep**:
#       tmux の spawn window（wt-* / 素 admin / admin-*）一覧を **session:window 正準形**（admin は `<project>:admin`・
#       orch-riz1 topology 裁定 orch-thgx）で列挙し、対応 bead（自台帳 + --foreign-repo）と突合して
#       3 つの停滞シグナルを人間/orchestrator 向けに surface する（**mutate しない・起票も dispatch もしない**）:
#         ① **decision-point 停滞**: needs-user / gate-pending ラベルの bead が N 分以上更新されず park されている
#            （自台帳 + foreign）。admin↔orchestrator relay が片方待ちで固着した疑いを一覧化する。
#         ② **window 生存 × bead 停滞/不在**: wt-<id> worker window が生存しているのに対応 self bead が N 分以上
#            無更新（silent stall 疑い）or 宣言 bead 不在（未作成疑い）。event を 1 回取りこぼすと無限待ちになる
#            純 event-driven 監視の backstop（heartbeat/reconciliation の単発版）。
#            ★SPAWNED marker smoke（orch-gv9・C案 検知側・既定 on・`ORCH_DISPATCH_SPAWN_SMOKE=0` で off・orch-qof 裁定 B 2026-07-10）: 上記
#              stale cell につき自 bead notes の SPAWNED marker（worker が起動直後に書く宣言 write の smoke signal・
#              行頭 `[SPAWNED--<id>]`）有無を突合し、不在なら『宣言 write 断絶疑い（external repo cell の sandbox
#              sever・orch-b10/orch-7ti）』を、有なら『write 経路生存の別要因 stall』を注記する（read-only advisory・
#              spawn abort しない＝design 確定(2)）。**書込側（marker write を worker mandate へ恒久注入）は
#              scribe-spawn build_prompt / protocol.md §2 の責務＝foreign 台帳（write-isolation の外）ゆえ本 bead
#              では admin 起票候補（bead orch-gv9 notes）**。書込側 land 前は全 stale で marker 不在＝誤 signal ゆえ
#              既定 off とし admin が書込側 land 後に on にする（責任ある rollout・off 時 ② 出力は従来 byte 同一）。
#         ③ **host-progress 停滞**（orch-ayj）: 長 running build プロセス（podman/buildah pull/build 系）が生存して
#            いるのに監視 fs（containers/storage + /var/tmp/container_images_*）への書込が N 分ゼロ＝silent hang 疑い。
#            ①②は bead updated_at 基点ゆえ、背景 build が bead を更新しないまま network stall で固着する silent
#            hang（incident orch-1kk の build task・1h22m）に盲目だった。それを『プロセス生存 ∧ fs 書込停止』で埋める。
#            read-only（pgrep/ps/find のみ）。build プロセス不在なら probe skip（安価）。正常 build は書込継続で除外。
#       admin window（session:window 正準形 `<project>:admin`・素 admin / 移行期 admin-<project>）は held bead を
#       window 名から導けないため①（foreign parked bead）と併せて読む（「projalpha:admin 生存」＋「un-smnk needs-user
#       停滞 60m [foreign]」で deadlock を人間が判別）。
#       節目 + 常駐 watch fire 時に 1 回叩く運用（cron 常駐は orch-z7g ③ 合流時に判断・今は過剰＝単発 composable）。
#
# 設計境界（壊してはいけない不変条件） ──────────────────────────────────────────
#   - write-isolation: 本 wrapper は **foreign 台帳を bare bd で write しない**（spawn は scribe-spawn へ委譲・
#     gate-pending / watch worker・generic は read のみ）。例外は watch admin の **--resync**: これは bdw 経由
#     （injectable ORCH_DISPATCH_RESYNC_CMD・既定 `<scriptorium>/scripts/bdw repo sync`）で連結 substrate の
#     pull hydrate を回す＝orch 台帳を foreign から hydrate する §3 の正当 write であって self-prefix isolation
#     違反ではない（本 script 自身は bare `bd ...` write を一切発行せず bdw へ委譲する＝直列化も保つ）。
#     orchestrator は自台帳 orch- のみ write・foreign は read-only hydrate の原則を侵さない。
#   - notice 原則: 既定は scriptorium 自己開発 cell の dispatch。`--repo` で他 project worktree も指せるが、
#     それは admin が承認付きで使う道具であって、wrapper 自身は自律 foreign dispatch をしない（既定は自己開発・
#     foreign を指すには明示 --repo が必要＝その明示が人間/admin の承認シグナル）。
#   - worker は opus 厳守（既定 --model=opus）。fable はコスト事故源（scribe-spawn 側も worker fable を die）。
#
# env override（主に self-test 用・本番経路は既定で byte 不変）:
#   ORCH_DISPATCH_SPAWN        scribe-spawn.sh 実体パス（既定なし＝private 配備層が供給。未供給で spawn 実行経路に
#                              入ると fail-loud・watch 等の read-only 経路は不要）。
#   ORCH_DISPATCH_SCRIPTORIUM  既定 anchor/repo に使う scriptorium repo path（既定: 共有 lib _resolve_scriptorium
#                              〔ORCH_ANCHOR / ORCH_ANCHOR_CONFIG seam 込み・E2 検証付き〕・解決不能は fail-loud・orch-pso）。
#   ORCH_DISPATCH_BD           gate-pending/watch/spawn 入口 check で叩く bd 実体（既定: PATH 上の bd）。
#   ORCH_DISPATCH_BDW          spawn 入口 gate の acceptance snapshot を自台帳 notes へ append する bdw 実体
#                              （既定: <scriptorium>/scripts/bdw）。自台帳 write 直列化の正路（un-8p7）。self-test で stub 可。
#   ORCH_DISPATCH_SKIP_SLATE_GATE  slate interlock（bd orch-vswk・spawn 実行経路のみ）を bypass する hermetic seam
#                              （=1 で skip・既定 0=gate 有効）。bats の既存 spawn 回帰維持用＝production 既定は gate 有効
#                              （後方互換を口実にした warn-only 化でない・fail-closed）。read-only mode〔gate-pending/watch/
#                              liveness〕は run_spawn を通らず gate 自体を叩かない（本 seam に依らず従来どおり）。
#   ORCH_DISPATCH_POLL_INTERVAL watch の poll 間隔秒（既定: 30）。
#   ORCH_DISPATCH_TMUX         watch admin/generic の pane idle 検出 + liveness の window 列挙に使う tmux 実体（既定: PATH 上の tmux）。
#                              capture-pane / list-panes（read-only）で読むだけ＝tmux server を mutate しない。
#   ORCH_DISPATCH_LIVENESS_STALE_MIN  liveness の停滞閾値（分・既定 30）。needs-user/gate-pending park や window 生存×bead 無更新が
#                              この分数を超えると停滞として surface する。非整数は warn して既定へ（fail-open）。
#   ORCH_DISPATCH_NOW_EPOCH    liveness の age 算出の現在時刻を固定（epoch 秒・test/デバッグ用）。未設定なら実時刻。
#   ORCH_DISPATCH_SPAWN_SMOKE  liveness ②（=window×bead 軸・impl/plan では ③ 番）の SPAWNED marker smoke（orch-gv9・C案 検知側）を off にする（=0・既定 1=on。書込側 sc-0df land 済みゆえ orch-qof 裁定 B で既定 flip）。
#                              on 時、stale な wt-<id> cell の notes に SPAWNED marker（行頭 [SPAWNED--<id>]）が
#                              無ければ『宣言 write 断絶疑い（sandbox sever）』を advisory 注記する（read-only・
#                              spawn abort しない）。書込側 mandate（scribe・foreign）land 後に admin が on にする。
#   ORCH_DISPATCH_PGREP / _PS / _FIND  liveness 第3軸 host-progress probe が使う pgrep/ps/find 実体（既定: PATH 上）。
#                              いずれも read-only（プロセス列挙・elapsed 秒・fs mtime 走査のみ）。self-test で stub 可。
#   ORCH_DISPATCH_HOSTPROG_PATTERN  host-progress で「長 running build」とみなす pgrep -f パターン（ERE・既定:
#                              `podman.*(build|pull|push)|buildah|skopeo`＝idle podman daemon を避け build/pull に限定）。
#   ORCH_DISPATCH_HOSTPROG_PATHS   書込監視対象 fs パス（空白区切り・glob 可・既定: rootless/rootful containers/storage
#                              + /var/tmp/container_images_*）。実在するパスのみ find 走査＝運用に合わせ調整可。
#   ORCH_DISPATCH_RESYNC_CMD   watch admin --resync の軽量 re-sync コマンド（空白区切り・path に空白不可）。
#                              既定: `<scriptorium>/scripts/bdw repo sync`（bdw 経由＝連結 substrate hydrate の正路）。
#                              self-test で stub（counter/true 等）へ差替可。
#
# flag（watch admin 直読 poll・orch-mot channel α）:
#   --foreign-repo <path>      同一マシンの foreign repo root を直接 read する直読 poll を有効化（`bd -C <path> show`）。
#                              hydrate（bdw repo sync）を介さない＝race-free・sync 不要・read-only。admin 専用・--resync と排他。
#   --done-status <CSV>        foreign 完了とみなす status 集合（既定 closed,blocked＝終端宣言 DONE/BLOCKED）。
#   ORCH_DISPATCH_SYNC_STALE_MIN  foreign 鮮度 stale 閾値（分・既定 60）。最後の sync がこれより古いと
#                                 gate-pending に⚠ 警告を添える（foreign の sync 鮮度劣化を surface・orch-6rb）。
#   ORCH_DISPATCH_SYNC_MARKER     主鮮度ソース＝sync 専用マーカー last-sync パス（既定: <scriptorium>/.beads/last-sync）。
#                                 orch-hydrate.sh が sync 成功直後に stamp。self-test 用に差し替え可。
#   ORCH_DISPATCH_EXPORT_STATE    補助鮮度ソース export-state.json パス（既定: <scriptorium>/.beads/export-state.json）。
#                                 any-write proxy ゆえ判定には使わず last-sync 不在時の補助表示のみ（orch-6rb）。
#
# 検証: tests/scenarios/orch-dispatch.bats（hermetic: scribe-spawn / bd / tmux / resync を PATH/env スタブで
#   差替・watch actor 種別ごとの success/failure 終端を網羅）+ selftest-<id>.local.sh（worktree 直下・untracked・
#   fail-closed）。

set -uo pipefail

# ── 実体パス（env で差し替え可・self-test 用）─────────────────────────────────
# scribe-spawn 実体（engine 版）: env seam ORCH_DISPATCH_SPAWN で private 配備層が供給する（deploy-layout
# 依存の既定 path は engine では持たない）。未供給のまま spawn 実行経路へ入ると下の -x check が fail-loud する
# （watch / 観測系の read-only 経路は SPAWN 不要＝lazy 検査）。
SPAWN="${ORCH_DISPATCH_SPAWN:-}"
# ── SCRIPTORIUM anchor 動的解決 + external repo cell scan roots（共有 lib orch_anchor.sh・orch-49g で集約）──
# `_resolve_scriptorium`（E2 anchor 検証付き・fleet-monitor / clean-probe / degraded-watch と単一 SSOT）と
# `_external_scan_roots`（degraded-watch と単一 SSOT）は共有 lib へ集約した（旧 byte 複製 4+2 を解消・orch-49g）。
# lib は内部で orch_session.sh を source し `_ledger_dolt_database` で解決候補 anchor の dolt_database==orch を検証
# する（foreign repo anchor の誤採用を構造封鎖＝E2・orch-dispatch に anchor gate が無かった非対称もこれで解消）。
# 旧 hardcode（$HOME/...）は orch identity と非対称で、非 canonical anchor で SCRIPTORIUM 根の全既定（ANCHOR/REPO・
# scan root・BDW/RESYNC/鮮度マーカー）が誤 path を silent に指した。env override（ORCH_DISPATCH_SCRIPTORIUM）を
# 最優先で維持し、git 解決不能/reject 時のみ hardcode canonical へ graceful fallback。★lib は SCRIPTORIUM 代入の
# **前**に source すること（E2 検証に _ledger_dolt_database が要るため）。BASH_SOURCE 相対で実 lib を解決するので、
# 非 canonical real git repo へ script + lib をコピーした deploy 形態でも実 lib を見つける。★非空 env 設定時は
# 下記 ${VAR:-...} の既定が展開されず _resolve_scriptorium は呼ばれない＝git を一切叩かない（既存 bats は
# ORCH_DISPATCH_SCRIPTORIUM を固定するため副作用ゼロ）。
# ★symlink-safe（orch-49g errata E1）: readlink -f で script 実体を解決してから lib dir を導く。旧 inline
#   _resolve_scriptorium は内部で readlink -f を使い symlink 起動（例: ~/.local/bin/orch-dispatch.sh → 実 repo）
#   耐性があった。lib source を非 readlink の dirname で組むと symlink 起動で $sandbox/lib/... を見て lib 不在 die
#   ＝退行。fleet-monitor（_self_real 経由 readlink）と同型で symlink-safe 化する。
_orch_dispatch_self="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
_ORCH_ANCHOR_LIB="$(cd "$(dirname "$_orch_dispatch_self")" 2>/dev/null && pwd)/lib/orch_anchor.sh"
if [ -r "$_ORCH_ANCHOR_LIB" ]; then
    # shellcheck source=lib/orch_anchor.sh
    . "$_ORCH_ANCHOR_LIB"
else
    echo "orch-dispatch: 共有 anchor lib 不在: $_ORCH_ANCHOR_LIB（anchor 解決不能・fail-closed）" >&2
    exit 1
fi
# 共有 liveness lib（bd orch-4js9 fence1）: `_liveness_windows`（session:window 正準形列挙）を単一 SSOT 化し
# orch-delivery-observe.sh と共有する（canonical form の byte 複製を作らない）。BASH_SOURCE 相対で実 lib を解決。
_ORCH_LIVENESS_LIB="$(cd "$(dirname "$_orch_dispatch_self")" 2>/dev/null && pwd)/lib/orch_liveness.sh"
if [ -r "$_ORCH_LIVENESS_LIB" ]; then
    # shellcheck source=lib/orch_liveness.sh
    . "$_ORCH_LIVENESS_LIB"
else
    echo "orch-dispatch: 共有 liveness lib 不在: $_ORCH_LIVENESS_LIB（window 列挙不能・fail-closed）" >&2
    exit 1
fi
# 共有 slate lib（bd orch-vswk・orch-6srt 裁定-safeguards(3)）: 計画 slate 参照 interlock（`_orch_slate_*`）を
# 単一 SSOT 化し orch-spawn-admin.sh と共有する。spawn 実行経路（run_spawn）は slate 無し→fail-closed で弾く。
# BASH_SOURCE 相対で実 lib を解決（symlink 起動耐性は上記 anchor lib と同型）。
_ORCH_SLATE_LIB="$(cd "$(dirname "$_orch_dispatch_self")" 2>/dev/null && pwd)/lib/orch_slate.sh"
if [ -r "$_ORCH_SLATE_LIB" ]; then
    # shellcheck source=lib/orch_slate.sh
    . "$_ORCH_SLATE_LIB"
else
    echo "orch-dispatch: 共有 slate lib 不在: $_ORCH_SLATE_LIB（slate interlock 不能・fail-closed）" >&2
    exit 1
fi
# --help / -h は anchor 非依存で応答する（engine の anchor fail-loud 化で、env 未供給時に --help 自体が die する
# のを防ぐ・E1）。arg を先読みして help 要求を検出し、help 時は anchor 解決を丸ごと skip する（usage() は $0 の
# ヘッダコメントだけを読むため SCRIPTORIUM を要さない）。非 help 時のみ下記 fail-loud が効く（teeth 維持）。
_want_help=0
for _a in "$@"; do case "$_a" in -h|--help) _want_help=1; break ;; esac; done
# anchor 解決（engine 版）: env override > 共有 lib _resolve_scriptorium（ORCH_ANCHOR / ORCH_ANCHOR_CONFIG seam
# 込み・E2 検証付き）。解決不能は fail-loud（deploy-layout 依存の hardcode fallback は engine では持たない）。
if [ "$_want_help" = 1 ]; then
    SCRIPTORIUM=""   # help 経路は anchor 非依存（下の fail-loud も後続の anchor 派生既定も使わずに usage で exit）。
else
    SCRIPTORIUM="${ORCH_DISPATCH_SCRIPTORIUM:-$(_resolve_scriptorium || true)}"
    if [ -z "$SCRIPTORIUM" ]; then
        echo "orch-dispatch: anchor 解決不能（fail-loud）: env ORCH_DISPATCH_SCRIPTORIUM / ORCH_ANCHOR / ORCH_ANCHOR_CONFIG のいずれかを供給せよ（engine は hardcode fallback を持たない）。" >&2
        exit 1
    fi
fi
BD="${ORCH_DISPATCH_BD:-bd}"
# spawn 入口 gate（orch-vji）の acceptance snapshot を自台帳 notes へ append する bdw 実体（自台帳 write 直列化の正路・un-8p7）。
BDW="${ORCH_DISPATCH_BDW:-$SCRIPTORIUM/scripts/bdw}"
# external repo cell registry（orch-b10）: `--repo` が anchor≠repo（外部 project worktree host）の cell を spawn
#   したとき、その repo root を記録する runtime マーカー（.beads/last-sync と同種の machine-local marker・1 行 1
#   絶対 repo-root・gitignore 済）。gate-pending / degraded-watch がこれを読み <repo>/.worktrees/spawn を scan root に
#   加える＝外部 repo cell の未 merge worktree を監視射程へ入れる（宣言 write が sandbox で断たれても構造検知で
#   hands-free ループを閉じる・incident orch-7ti/orch-b10）。dispatch が書き、両 scan が読む単一ファイル。
EXTERNAL_REGISTRY="${ORCH_DISPATCH_EXTERNAL_REGISTRY:-$SCRIPTORIUM/.beads/external-repo-cells}"
POLL_INTERVAL="${ORCH_DISPATCH_POLL_INTERVAL:-30}"
# watch admin/generic の pane idle 検出に使う tmux 実体（read-only capture-pane のみ・self-test で差替可）。
TMUX_BIN="${ORCH_DISPATCH_TMUX:-tmux}"
# watch admin --resync の軽量 re-sync コマンド（bdw 経由 hydrate の正路・空白区切り・path に空白不可）。
RESYNC_CMD="${ORCH_DISPATCH_RESYNC_CMD:-$SCRIPTORIUM/scripts/bdw repo sync}"

# foreign 鮮度 stale 閾値（分・orch-6rb）。非整数 env は warn して既定にフォールバック
# （鮮度は gate-pending の補助 surface 機能ゆえ die まではせず fail-open 寄り）。
STALE_MIN="${ORCH_DISPATCH_SYNC_STALE_MIN:-60}"
if ! [[ "$STALE_MIN" =~ ^[0-9]+$ ]]; then
    echo "orch-dispatch: warn: ORCH_DISPATCH_SYNC_STALE_MIN が非整数（$STALE_MIN）→既定 60 を使用" >&2
    STALE_MIN=60
fi

# liveness 停滞閾値（分・orch-edv T3）。非整数 env は warn して既定へ（liveness は surface 機能ゆえ fail-open 寄り）。
LIVENESS_STALE_MIN="${ORCH_DISPATCH_LIVENESS_STALE_MIN:-30}"
if ! [[ "$LIVENESS_STALE_MIN" =~ ^[0-9]+$ ]]; then
    echo "orch-dispatch: warn: ORCH_DISPATCH_LIVENESS_STALE_MIN が非整数（$LIVENESS_STALE_MIN）→既定 30 を使用" >&2
    LIVENESS_STALE_MIN=30
fi
# liveness の age 算出の現在時刻（epoch 秒・test 固定用）。未設定/非整数なら実時刻を使う。
NOW_EPOCH_OVERRIDE="${ORCH_DISPATCH_NOW_EPOCH:-}"

# ── SPAWNED marker smoke（orch-gv9・C案 検知側・既定 off）─────────────────────────
#   ★軸番号は本 file の 2 採番系に注意（既存 convention・本 feature が導入した揺れではない）: window×bead 軸は
#     file 冒頭 header ブロックでは ②（①decision / ②window×bead / ③host-progress）、run_liveness の実行/dry-run plan
#     出力および impl コメント（_STATUS_PY 消費点 / _liveness_self_status・下記 marker helper）では ③
#     （①tmux列挙 / ②park / ③window×bead / ④host-progress）。以下 impl 側コメントは近傍に合わせ ③ 表記で統一する
#     （= header の ② と同一 window×bead 軸）。
#   worker が起動直後に bdw --append-notes で自 bead へ書く一意 marker（宣言 write 可否の smoke signal）の
#   不在を liveness ③（=window×bead 軸・header ②）で fail-loud surface するか（=1 で on）。**既定 off**（write 側 mandate が未 land ゆえ）:
#     - 検知側（本 script・本 bead orch-gv9）と 書込側（worker mandate への marker write 恒久注入）は分離する。
#       書込側は scribe-spawn `build_prompt` / protocol.md §2 の責務＝foreign 台帳（scriptorium write-isolation の
#       外）ゆえ本 bead では admin 起票候補として残す（bead notes）。書込側 land 前は全 stale cell で marker 不在＝
#       100% 誤 sever signal になるため、admin が書込側 land 後に本 flag を on にする（責任ある rollout）。
#     - off 時は liveness ③ の出力は従来と byte 同一（回帰ゼロ・acceptance 2）。on 時のみ marker 弁別注記を付す。
#   design 確定事項（bd orch-gv9・user confirm 2026-07-08）: fail-loud は loud 警告 surface でありspawn abort しない
#     （遅い起動の false positive で正当 cell を殺さない・判断は orchestrator/人間）。ゆえに liveness（read-only
#     advisory sweep）を検知 home とし、時間 gate は既存 stale 閾値（$LIVENESS_STALE_MIN 分）を流用する
#     （＝「spawn 後 N 分 marker 不在」を stale cell に限って surface＝fresh cell の誤検出を構造回避）。
SPAWN_SMOKE="${ORCH_DISPATCH_SPAWN_SMOKE:-1}"

# ── host-progress probe（liveness 第3軸・orch-ayj）────────────────────────────────
#   『長 running build プロセス生存 ∧ 監視 fs への書込が N 分ゼロ』を silent hang 疑いとして surface する。
#   既存 2 軸（decision-point 停滞 / window×bead）はいずれも bead updated_at を基点にするため、背景 build が
#   bead を更新しないまま network stall で固着する silent hang を構造的に検知できなかった（incident orch-1kk
#   cm 便 task2・1h22m・doobidoo bd3908ed）。手動ホスト観測（pgrep + find -newermt）で実測した『プロセス生存 ∧
#   fs 書込停止』を第3軸として一般化する。read-only（pgrep/ps/find のみ・mutate しない）。閾値は
#   LIVENESS_STALE_MIN を共用（プロセス年齢・fs 書込齢の両方）。build プロセス不在なら probe を skip（安価＝
#   build 中のみ find コストを払う）。
PGREP_BIN="${ORCH_DISPATCH_PGREP:-pgrep}"
PS_BIN="${ORCH_DISPATCH_PS:-ps}"
FIND_BIN="${ORCH_DISPATCH_FIND:-find}"
# pgrep -f で「長 running build」とみなすプロセスの full-cmdline パターン（ERE）。既定は build/pull/push 操作に
#   限定する: 素の `podman` は socket-activated daemon（`podman system service`）が idle 生存しうるため、
#   pattern を `podman.*(build|pull|push)` に絞らないと idle daemon を silent hang と誤検知する（false positive）。
#   buildah/skopeo は one-shot ゆえ生存自体が作業中を意味する。env で運用の build 起動形に合わせ調整可。
HOSTPROG_PATTERN="${ORCH_DISPATCH_HOSTPROG_PATTERN:-podman.*(build|pull|push)|buildah|skopeo}"
# 書込監視対象 fs パス（空白区切り・glob 可）。containers/storage だけ見ると podman pull の中間 blob
#   （/var/tmp/container_images_*）を見落とし誤診する（doobidoo bd3908ed）＝両方を既定に含める。rootless は
#   $HOME/.local/share/containers/storage・rootful は /var/lib/containers/storage。運用に合わせ env で上書き可。
HOSTPROG_PATHS="${ORCH_DISPATCH_HOSTPROG_PATHS:-$HOME/.local/share/containers/storage /var/lib/containers/storage /var/tmp/container_images_*}"

# 自台帳 prefix（.beads/metadata.json dolt_database / CLAUDE.md SSOT・guard / orch-discovery-nudge と
#   同一値を共有）。連結 substrate（§3 `bd repo sync` pull hydrate）で自 DB に混在する foreign copy
#   （un-/sc-/pk-…）から self-dev cell（自台帳 orch-）を仕分けるのに使う（§5.2 外部 track の gate routing）。
SELF_PREFIX="orch"

die() { echo "orch-dispatch: $*" >&2; exit 2; }

usage() {
    # 先頭コメントブロック（shebang 直後〜最初の非コメント行の手前）を help として出す。
    # 行番号を固定せず最初の非コメント行で打ち切るのでヘッダ伸縮に追従する（orch-spawn-admin と同型）。
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
    exit "${1:-0}"
}

# ── gate-pending JSON → "id<TAB>title" 行（fleet-monitor の _BOARD_PY と同型・python3 依存）──
_GP_PY='
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)   # parse 失敗は「該当なし(空)」と区別し非0 で surface（fail-silent 回避・gate 由来 errata）
if not isinstance(data, list):
    sys.exit(2)   # bd --json は配列を返す。非配列は想定外＝障害として非0
for it in data:
    if isinstance(it, dict):
        print("%s\t%s" % (it.get("id", ""), it.get("title", "")))
'

# ── bd show <id> --json → "status<TAB>needs-user-flag<TAB>gate-pending-flag<TAB>updated_at"（watch admin の foreign 完了/変化検出・object/単要素配列の両方を受ける）──
#   orch-r5x: status のみだと actor が NEEDS-USER を blocked+needs-user ラベルで宣言しても plain BLOCKED と
#   同一 surface になる。orch-mot 三値 triad（DONE/BLOCKED/NEEDS-USER）を surface でも完全実現するため
#   labels も read し、needs-user ラベルの有無を 2 列目（"1"/"0"）で返す（呼び元が decl 区別に使う）。
#   orch-o0b（軸C）: 3 列目に gate-pending ラベルの有無（"1"/"0"）を返す。foreign admin の human-ratify 終端形は
#   自己 close 禁止ゆえ「gate-pending ラベル + status=in_progress のまま」になり、軸A(done-set)/軸B(needs-user) が
#   拾えず timeout する。呼び元（admin loop 軸C）はこの列で gate-pending park を status 非依存に検知する。
#   orch-edv T2（baseline 方式）: 4 列目に updated_at を返す。呼び元は watch 開始時の baseline と比較し、
#   既 blocked/needs-user/gate-pending bead の re-pause（status/label 不変でも notes append で updated_at が前進）を
#   「baseline からの変化」として検知する（無変化 transition の取りこぼし＝silent mutual-wait deadlock を断つ）。
#   ★列順 lockstep 注意（orch-o0b）: 本 PY の出力を read する 3 消費点（worker fire / admin fire / liveness ③）は
#   IFS=TAB の read 変数を 4 個に揃える。素朴な列追加で read 変数が 3 個のままだと最終変数（updated_at）へ
#   gate-pending 列が食い込み silent 破損する（age 判定不能化・baseline 比較破綻）。
_STATUS_PY='
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)   # parse 失敗は status 不明（呼び元で bd 障害扱い・「完了」と取り違えない）
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    sys.exit(2)
labels = data.get("labels")   # 無ラベル時はキー自体が absent（None）・防御的に list 型のみ採用
needs_user = "1" if isinstance(labels, list) and "needs-user" in labels else "0"
gate_pending = "1" if isinstance(labels, list) and "gate-pending" in labels else "0"   # orch-o0b 軸C
upd = data.get("updated_at")
upd = upd if isinstance(upd, str) else ""
# updated_at 内の TAB/改行は列区切りを壊すため除去（防御的・通常は RFC3339 で無害）。
upd = upd.replace("\t", " ").replace("\n", " ")
print("%s\t%s\t%s\t%s" % (data.get("status", ""), needs_user, gate_pending, upd))
'

# ── bd list --json → park bead の停滞行（liveness ②・orch-edv T3）───────────────────────────────
#   argv: now_epoch stale_min label。stdin の bd list JSON から <label> を持つ bead を走査し、
#   age=(now-updated_at)/60 が stale_min 以上のものを "id<TAB>label<TAB>age_min" で emit（updated_at 不明は age="?"）。
#   RFC3339（例 2026-07-02T00:00:00Z）を epoch へ。負 age（clock skew）は 0 にクランプ。parse 不能は skip（fail-safe）。
_PARKED_PY='
import sys, json, datetime
try:
    now = float(sys.argv[1]); stale = int(sys.argv[2]); label = sys.argv[3]
except Exception:
    sys.exit(0)
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, list):
    sys.exit(0)
def parse_epoch(s):
    if not isinstance(s, str) or not s:
        return None
    t = s.strip()
    if t.endswith("Z"):
        t = t[:-1] + "+00:00"
    try:
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None
for it in data:
    if not isinstance(it, dict):
        continue
    labels = it.get("labels") or []
    if not (isinstance(labels, list) and label in labels):
        continue
    iid = it.get("id", "")
    ep = parse_epoch(it.get("updated_at"))
    if ep is None:
        print("%s\t%s\t?" % (iid, label))   # updated_at 不明は停滞判定不能＝safe 側で surface（age 不明）
        continue
    age_min = int((now - ep) / 60)
    if age_min < 0:
        age_min = 0
    if age_min >= stale:
        print("%s\t%s\t%d" % (iid, label, age_min))
'

# ─────────────────────────────────────────────────────────────────────────────
# 引数解析
# ─────────────────────────────────────────────────────────────────────────────
MODE=""              # spawn | gatepending | watch | liveness（未指定なら下で推論）
BD_ID=""
ANCHOR="$SCRIPTORIUM"   # --anchor で上書き
REPO="$SCRIPTORIUM"     # --repo で上書き
BASE="HEAD"
MODEL="opus"
TIMEOUT=1800
DRY_RUN=0
ACTOR="worker"       # watch の actor 種別: worker（既定・後方互換）| admin | generic
WINDOW=""            # watch admin/generic の tmux window/target（pane idle 検出）
RESYNC=0             # watch admin: 各 status poll の前に軽量 re-sync（bdw hydrate）を回す
FOREIGN_REPO=""      # watch admin: 直読 poll（channel α・orch-mot）。set 時 `bd -C <path>` で foreign を hydrate 無し直読
IDLE_POLLS=3         # watch admin/generic: pane idle 判定に要する連続無変化回数
# watch admin: foreign 完了とみなす status 集合（CSV）。既定 closed,blocked＝終端宣言 DONE(closed)/BLOCKED(blocked)
# （orch-mot: actor が自台帳に DONE/BLOCKED/NEEDS-USER を明示宣言・NEEDS-USER は blocked+needs-user ラベルで surface）。
DONE_STATUS="closed,blocked"

# spawn: worker cell の対話 tool 封鎖は本 script では扱わない（orch-ce6 errata・orch-z7g H5 / layer ③）─────
#   worker cell（無人 worktree window）の対話 tool 物理封鎖は **scribe-spawn 側が担う**（orch-4dm 着地形）:
#   scribe-spawn.sh が `WORKER_DISALLOWED_TOOLS="AskUserQuestion,ExitPlanMode"` を hardcode し worker spawn の
#   cld-spawn 起動行へ **無条件付与**する（scribe-spawn.sh:73/:570）。orch-4dm は `--disallowed-tools` を CLI
#   passthrough flag として生やさなかった（--help に出ない）。よって本 script が --disallowed-tools を forward
#   すると scribe-spawn は未知オプションで die し spawn を壊す＝forward してはならない。orch-dispatch は
#   scribe-spawn を呼ぶだけで worker 封鎖は自動的に効く（redundant な forward は持たない）。
#   ※初期実装（orch-ce6 v1）は「orch-4dm=passthrough flag」と誤前提し capability-probe+条件付き forward を組んだが、
#     実 orch-4dm は hardcode 着地ゆえ probe 恒久 UNSUPPORTED・forward 到達不能・虚偽 warn を出す死コードだった
#     （orchestrator 独立 gate wf_fdeccb75 で CONFIRMED major）→撤去。①admin 直付与（cld-spawn へ効く）は維持。
# spawn 直後 watch 常駐ヒント（orch-z7g H3-ii / orch-ce6）を stderr に emit するか（--no-watch-hint で抑止）。
WATCH_HINT=1

set_mode() {
    # モードは排他（spawn は既定なので明示モード同士の衝突のみ弾く）
    if [ -n "$MODE" ] && [ "$MODE" != "$1" ]; then
        die "モードが競合しています: --$MODE と --$1 は同時指定できません"
    fi
    MODE="$1"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --gate-pending) set_mode gatepending; shift ;;
        --watch)        set_mode watch; shift ;;
        --liveness)     set_mode liveness; shift ;;
        --stale-min)  [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--stale-min に値（分）を指定してください"; LIVENESS_STALE_MIN="$2"; shift 2 ;;
        --actor)  [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--actor に値を指定してください（worker|admin|generic）"; ACTOR="$2"; shift 2 ;;
        --window) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--window に値を指定してください"; WINDOW="$2"; shift 2 ;;
        --resync) RESYNC=1; shift ;;
        --foreign-repo) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--foreign-repo に値（同一マシンの foreign repo root path）を指定してください"; FOREIGN_REPO="$2"; shift 2 ;;
        --idle-polls) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--idle-polls に値を指定してください"; IDLE_POLLS="$2"; shift 2 ;;
        --done-status) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--done-status に値を指定してください（CSV）"; DONE_STATUS="$2"; shift 2 ;;
        --repo)   [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--repo に値を指定してください";   REPO="$2";   shift 2 ;;
        --anchor) [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--anchor に値を指定してください"; ANCHOR="$2"; shift 2 ;;
        --base)   [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--base に値を指定してください";   BASE="$2";   shift 2 ;;
        --model)  [ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--model に値を指定してください";  MODEL="$2";  shift 2 ;;
        --timeout)[ -n "${2:-}" ] && [ "${2#-}" = "$2" ] || die "--timeout に値を指定してください"; TIMEOUT="$2"; shift 2 ;;
        --no-watch-hint) WATCH_HINT=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage 0 ;;
        --) shift; [ $# -gt 0 ] && { [ -z "$BD_ID" ] || die "bd id は 1 つだけ指定してください（既指定: $BD_ID, 追加: $1）"; BD_ID="$1"; shift; } ;;
        -*) die "未知のオプション: $1（usage は --help）" ;;
        gate-pending) set_mode gatepending; shift ;;   # 位置サブコマンド形（--gate-pending と等価）
        spawn)        set_mode spawn; shift ;;          # 位置サブコマンド形（spawn を明示）
        watch)        set_mode watch; shift ;;          # 位置サブコマンド形（--watch と等価）
        liveness)     set_mode liveness; shift ;;       # 位置サブコマンド形（--liveness と等価）
        *)  [ -z "$BD_ID" ] || die "bd id は 1 つだけ指定してください（既指定: $BD_ID, 追加: $1）"; BD_ID="$1"; shift ;;
    esac
done

# モード推論: 明示モードが無く bd-id があれば spawn（既定）。
[ -z "$MODE" ] && MODE="spawn"

# ─────────────────────────────────────────────────────────────────────────────
# (2) gate-pending 報告: `bd list --label gate-pending --status open,in_progress,blocked`（非 closed＝
#     fleet-monitor の★検品待ちと同一セマンティクス。worker は claim〔in_progress〕してから gate-pending を
#     付けるため open のみだと取りこぼす〔gate 由来 errata〕。★単数 --label・--labels は無効フラグ）。
#     cross-ledger（§5.2・orch-3d4）: 連結 substrate（§3 `bd repo sync` pull hydrate）で自 DB に取り込まれた
#     foreign copy（外部 repo cell が自台帳 foreign に書いた gate-pending）も `bd list` は prefix 非依存で返す。
#     出力は self-dev（自台帳 ${SELF_PREFIX}-）と外部 repo cell（foreign）の 2 バケットに分け、gate 意味論の
#     違い（§1.1 案C: self-dev=直 gate / foreign=admin gate 信頼・admin 不在は人間 go-gate）を surface する。
# ─────────────────────────────────────────────────────────────────────────────
# (orch-9l1) un-merged spawn worktree を bead status / gate-pending ラベル非依存で surface する。
#   検知漏れ defense-in-depth: worker が自己 close しても（旧 scribe protocol §4）gate-pending
#   ラベルを付け忘れても、.worktrees/spawn/ 配下に base(既定 main)より先行コミットを持つ worktree があれば
#   「gate+merge 待ち」として必ず出す。ラベル/CLOSED 単独依存の検知漏れ（orch-2ax/orch-2o6 incident・user 二度指摘）
#   を塞ぐ＝worker の振る舞いに非依存な検知。orch-6cd grill C3 stall(窓消失×no-CLOSED)が拾えない「CLOSED/ラベル無し
#   だが未 merge」を埋める。出力: "id<TAB>commit数<TAB>branch"（id は branch spawn/<id>-<ts> から ts を剥がして抽出）。
# ── external repo cell registry（orch-b10）─────────────────────────────────────
# incident（orch-7ti・beads-bdw worktree cell）: `--repo <外部 project>` で spawn した cell は worktree が
#   <外部 project>/.worktrees/spawn 配下に住むため、SCRIPTORIUM/.worktrees/spawn だけを見る
#   _awaiting_gate_worktrees / degraded-watch の scan 射程から漏れる。さらに終端宣言 write が worker sandbox で
#   断たれると gate-pending ラベルも付かず二重盲点で hands-free ループが silent 停止する。
#   → dispatch が外部 repo root を registry に記録し、両 scan がそれを読み <root>/.worktrees/spawn を走査する
#     （宣言 label に依存しない構造検知＝acceptance 1「監視が external cell を拾う」）。
# ★read-side `_external_scan_roots` は degraded-watch と共有 lib orch_anchor.sh へ集約済み（orch-49g）。write-side
#   `_register_external_repo`（下記）は dispatch 固有（複製なし）ゆえ dispatch に残す。

# 外部 repo root を registry へ冪等 append（realpath 正規化・既存行なら no-op）。dir 不在/write 不可は非0。
_register_external_repo() {
    local repo="$1" reg="$EXTERNAL_REGISTRY" canon dir
    canon="$(readlink -f "$repo" 2>/dev/null || printf '%s' "$repo")"
    dir="$(dirname "$reg")"
    [ -d "$dir" ] || return 1                                   # anchor .beads は orchestrator env で必ず在る
    if [ -f "$reg" ] && grep -qxF "$canon" "$reg" 2>/dev/null; then
        return 0                                                # 既登録＝冪等 no-op
    fi
    printf '%s\n' "$canon" >> "$reg" 2>/dev/null || return 1
    return 0
}

# `_external_scan_roots`（registry を読み <root>/.worktrees/spawn を emit・self-skip / dedup / 非存在 skip）は
#   共有 lib orch_anchor.sh へ集約した（旧 degraded-watch との byte 複製を解消・orch-49g）。$EXTERNAL_REGISTRY /
#   $SCRIPTORIUM は caller-global として lib 関数が参照する（冒頭で source 済み）。read-only（file read のみ）。

# 1 root（<...>/.worktrees/spawn）を走査し未 merge worktree を "id<TAB>n<TAB>branch<TAB>annot<TAB>base" で emit。
#   annot は self root では空・external root では repo root（呼び元が『外部 repo cell』と surface するため）。
#   base は commit 照合に使った base ref（呼び元が『<base>+N commits』と正確 surface するため・orch-665）。
#   n は先行コミット数。ただし base が解決不能（例: 外部 repo が local `$base` を持たず rev-list 非0終了）の
#   ときは「判定不能」sentinel を emit する（下記 orch-b10・external のみ・orch-665 で per-repo 解決後の残余 fallback）。
_scan_awaiting_root() {
    local root="$1" base="$2" annot="$3"
    [ -d "$root" ] || return 0
    local d branch n id rc rel
    for d in "$root"/*/; do
        [ -d "$d" ] || continue
        branch="$(git -C "$d" branch --show-current 2>/dev/null)" || continue
        [ -n "$branch" ] || continue
        id="$(printf '%s' "$branch" | sed -E 's#^spawn/##; s/-[0-9]+$//')"
        [ -n "$id" ] || continue
        if [ -n "$annot" ]; then
            # external root: containment gate（orch-igl / orch-665）で base↔cell HEAD の包含関係を弁別する。
            #   `_resolve_repo_base` は「main worktree の checkout branch」で default を近似するため、foreign main
            #   worktree が非 default branch（cell 系列から乖離）を checkout 中だと base が cell 系列外を指し
            #   `rev-list base..HEAD` の数が不正確になる。素朴な数値 gate は silent-drop（乖離を surface できず）
            #   / harm(b)（0-ahead merge 済 cell を drop すべき）を両立できないため包含関係で分岐する:
            #     ・rc≠0/空（base 解決不能）→ 「判定不能」で fail-loud（従来どおり・detached HEAD 等）。
            #     ・contained（HEAD⊂base・a=0）→ 統合済/未着手 → surface しない（drop 維持・harm(b) を守る）。
            #     ・diverged（a>0 ∧ b>0）→ base が cell 系列外＝count 不正確 → 「乖離」で fail-loud（silent-drop しない）。
            #     ・ahead n（base⊂HEAD）→ 正確な先行数 n を surface。
            rel="$(_repo_base_relation "$d" "$base")"; rc=$?
            if [ "$rc" -ne 0 ] || [ -z "$rel" ]; then
                printf '%s\t%s\t%s\t%s\t%s\n' "$id" "判定不能" "$branch" "$annot" "$base"
                continue
            fi
            case "$rel" in
                contained)   continue ;;                                    # 0=merge 済/未着手 → surface しない
                diverged\ *) printf '%s\t%s\t%s\t%s\t%s\n' "$id" "乖離" "$branch" "$annot" "$base"; continue ;;
                ahead\ *)    n="${rel#ahead }" ;;
                *)           continue ;;                                     # 未知の分類 → 安全側で drop
            esac
            printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$n" "$branch" "$annot" "$base"
        else
            # self root（annot 空）: base=main は scriptorium で常に解決可。rc≠0 は git 一過性障害ゆえ従来どおり
            #   fail-open で skip（誤検出回避側に倒す・次回 scan で拾う＝(E5) の非対称を byte 不変で維持する）。
            n="$(git -C "$d" rev-list --count "$base..HEAD" 2>/dev/null)"; rc=$?
            if [ "$rc" -ne 0 ] || [ -z "$n" ]; then
                continue
            fi
            [ "$n" -gt 0 ] 2>/dev/null || continue   # 0=merge 済/未着手 → surface しない（誤検出回避）
            printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$n" "$branch" "$annot" "$base"
        fi
    done
}

_awaiting_gate_worktrees() {
    local base="${ORCH_DISPATCH_GATE_BASE:-main}"
    # self（scriptorium）root: annot 空・base=global（main 常時解決可＝per-repo 解決は掛けない・(E5) fail-open 維持）。
    _scan_awaiting_root "$SCRIPTORIUM/.worktrees/spawn" "$base" ""
    # external repo cell roots（orch-b10）: registry-discovered。annot=repo root で『外部 repo cell』を surface。
    #   orch-665（Option B）: external repo は local `main` を持たない（master/develop/trunk 既定）ことがあり、
    #   global base=main のままだと rev-list が非0終了し「判定不能」に落ちて lossy だった。repo ごとに default
    #   branch（main worktree の symbolic-ref HEAD）を _resolve_repo_base で解決して正確な commit 数を surface する。
    #   解決不能（detached HEAD 等）なら global base へ fallback＝従来の「判定不能」fail-loud 経路へ自然に倒れる。
    local extroot extrepo extbase
    while IFS= read -r extroot; do
        [ -n "$extroot" ] || continue
        extrepo="${extroot%/.worktrees/spawn}"
        extbase="$(_resolve_repo_base "$extrepo" || printf '%s' "$base")"
        _scan_awaiting_root "$extroot" "$extbase" "$extrepo"
    done < <(_external_scan_roots)
}

# ── foreign 鮮度（orch-6rb・§5.2 fail-open 補強・read-only）─────────────────────
# gate-pending の foreign（外部 repo cell）バケットは事前 courier `bd repo sync` 成功に構造依存する。
# 本 wrapper は read-only（sync を呼ばない）ゆえ sync 自体は直せないが、sync の鮮度を read して
# 「sync が古い/未実行/失敗で foreign を取りこぼしているかも」を surface する（silent fail-open の fail-loud 化）。
#
# 主鮮度ソース = orch 台帳の .beads/last-sync（sync 専用マーカー・orch-hydrate.sh が `bd repo sync` 成功
#   直後にのみ stamp する）。これは「最後に foreign hydrate が成功した時刻」だけを表す sync 特化指標。
#   ★なぜ export-state.json を主指標にしないか（admin gate errata・freshness-soundness）: export-state.json
#   は bd が任意の DB mutation 後に書く any-write proxy で、active orchestrator がローカル bdw write を
#   続ける限り sync 未実行でも fresh のままになる。それを主指標にすると「active orchestrator が sync 忘れ/
#   失敗」という本機能が狙う主要ケースを取りこぼす（hands-free 運用では active 中に poll するのが定常ゆえ
#   load-bearing）。last-sync は sync 経路でしか更新されないためこの取りこぼしを塞ぐ。sync 失敗時は
#   orch-hydrate が stamp しない＝マーカーが古いまま残り stale を検出する（＝「sync 失敗時に警告」を満たす）。
#   mtime を主指標に使う（OS 保証で単調・parse 回避）。内容（ISO timestamp）は人間可読の補助表示。
#   - last-sync 不在/読取不可 = sync 成功の証跡なし → unknown（sync 未成立/失敗の可能性を最安全側に倒す・⚠）。
#     ★ここで export-state を見て fresh と判定しない（any-write proxy で fresh と誤判定する over-claim を避ける）。
#     export-state.json は判定には使わず、unknown 時の補助情報（最終 DB 更新 timestamp）の表示だけに使う。
#   clock skew で未来 mtime のときは age=0（fresh 側）に丸める。stat/date 失敗は unknown へ縮退（fail-safe）。
FRESHNESS_STATE="unknown"   # fresh | stale | unknown
FRESHNESS_AGE_MIN=""        # last-sync からの経過分（整数・unknown 時は空）
FRESHNESS_TS=""             # 鮮度ソースの timestamp 文字列（補助表示・制御文字除去済・抽出不能なら空）
FRESHNESS_SOURCE=""         # 判定に使った指標（"last-sync" / unknown 時は ""）
_compute_sync_freshness() {
    FRESHNESS_STATE="unknown"; FRESHNESS_AGE_MIN=""; FRESHNESS_TS=""; FRESHNESS_SOURCE=""
    local marker="${ORCH_DISPATCH_SYNC_MARKER:-$SCRIPTORIUM/.beads/last-sync}"
    if [ -f "$marker" ]; then
        local mtime now
        mtime="$(stat -c %Y "$marker" 2>/dev/null)"
        if [ -n "$mtime" ] && [[ "$mtime" =~ ^[0-9]+$ ]]; then
            now="$(date +%s 2>/dev/null)"
            if [ -n "$now" ] && [[ "$now" =~ ^[0-9]+$ ]]; then
                local age_sec=$(( now - mtime ))
                [ "$age_sec" -lt 0 ] && age_sec=0   # clock skew（未来 mtime）防御 → fresh 側へ丸める
                FRESHNESS_AGE_MIN=$(( age_sec / 60 ))
                FRESHNESS_SOURCE="last-sync"
                # 内容（ISO timestamp）を補助表示に読む。制御文字は除去（破損/細工 marker の端末注入回避）。
                FRESHNESS_TS="$(head -n1 "$marker" 2>/dev/null | tr -d '\000-\037')"
                if [ "$FRESHNESS_AGE_MIN" -gt "$STALE_MIN" ]; then
                    FRESHNESS_STATE="stale"
                else
                    FRESHNESS_STATE="fresh"
                fi
                return 0
            fi
        fi
        # stat/date 失敗 → unknown へ縮退（fail-safe）。下で補助表示だけ拾う。
    fi
    # last-sync 不在 or 読取不可 = sync 専用証跡なし → unknown（最安全側）。
    # export-state.json は判定に使わず、補助情報（最終 DB 更新 timestamp）の表示だけに読む。
    _freshness_aux_note
}

# unknown 時の補助情報: export-state.json の timestamp を表示用にだけ読む（判定には使わない・over-claim 回避）。
#   any-write proxy ゆえ「sync が新しい」証拠にはならないが、「DB 自体はいつ動いたか」の参考にはなる。
_freshness_aux_note() {
    local es="${ORCH_DISPATCH_EXPORT_STATE:-$SCRIPTORIUM/.beads/export-state.json}"
    [ -f "$es" ] || return 0
    local es_ts
    es_ts="$(sed -n 's/.*"timestamp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$es" 2>/dev/null | head -n1 | tr -d '\000-\037')"
    [ -n "$es_ts" ] && FRESHNESS_TS="$es_ts"
}

# 鮮度レポートを stdout に出す（gate-pending 結果の信頼性メタ情報ゆえ結果と同じ stream に出す）。
#   引数1: 今回 surface した foreign_lines（空文字なら foreign は今回出ていない）。
#   - stale / unknown: 必ず⚠ 警告（foreign の有無・「なし」に依らず＝silent 取りこぼしを fail-loud 化）。
#   - fresh: foreign を実際に surface した時のみ控えめ注記（noise 削減・foreign 空なら無音）。
_emit_freshness_report() {
    local had_foreign="$1"
    case "$FRESHNESS_STATE" in
        stale)
            echo "⚠ foreign 鮮度警告: 最後の sync（.beads/last-sync）が約 ${FRESHNESS_AGE_MIN} 分前（stale 閾値 ${STALE_MIN} 分 超過${FRESHNESS_TS:+・最終 sync=$FRESHNESS_TS}）。"
            echo "  外部 repo cell の gate-pending は courier \`bd repo sync\`（foreign hydrate）依存。sync が古い/失敗だと foreign を silent 取りこぼす（上の一覧が full とは限らない）。"
            echo "  → \`scripts/orch-hydrate.sh\` で再 sync 後に再確認せよ（本 wrapper は read-only＝sync は呼ばない）。"
            ;;
        unknown)
            echo "⚠ foreign 鮮度警告: sync 専用マーカー（.beads/last-sync）が無い＝\`bd repo sync\`（orch-hydrate.sh）が一度も成功していない可能性${FRESHNESS_TS:+（参考: 最終 DB 更新=$FRESHNESS_TS・ただし any-write proxy で sync 鮮度ではない）}。"
            echo "  外部 repo cell の gate-pending は sync 依存ゆえ、foreign を silent 取りこぼしている可能性（上の一覧が full とは限らない）。"
            echo "  → \`scripts/orch-hydrate.sh\` で sync 後に再確認せよ（本 wrapper は read-only＝sync は呼ばない）。"
            ;;
        fresh)
            if [ -n "$had_foreign" ]; then
                echo "（注: 外部 repo cell は courier \`bd repo sync\` 依存・最後の sync 約 ${FRESHNESS_AGE_MIN} 分前${FRESHNESS_TS:+・最終 sync=$FRESHNESS_TS}）"
            fi
            ;;
    esac
}

run_gate_pending() {
    [ -z "$BD_ID" ] || die "gate-pending モードは bd-id を取りません（余分な引数: $BD_ID）"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[plan] $BD list --label gate-pending --status open,in_progress,blocked --limit 0 --json"
        echo "[plan] + .worktrees/spawn/ の un-merged worktree(git rev-list --count <base>..HEAD>0)を bead status 非依存で surface（orch-9l1）"
        echo "[plan] + external repo cell registry（$EXTERNAL_REGISTRY）の各 repo root の .worktrees/spawn も同様に scan（orch-b10・宣言 write が sandbox で断たれても構造検知で拾う）"
        echo "[plan] + foreign 鮮度チェック: ${ORCH_DISPATCH_SYNC_MARKER:-$SCRIPTORIUM/.beads/last-sync}（sync 専用マーカー）の mtime を read し stale(>${STALE_MIN}分)/unknown なら gate-pending 出力に警告を添える（read-only=sync は呼ばない・orch-6rb）"
        echo "[plan] → ラベル cell / worktree 行を整形（双方無ければ「なし」）。bd 台帳には write しない（read-only）。"
        return 0
    fi
    local json rc
    json="$("$BD" list --label gate-pending --status open,in_progress,blocked --limit 0 --json 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "orch-dispatch: bd list に失敗しました (rc=$rc)。bd 台帳/PATH を確認せよ。" >&2
        return 1
    fi
    local lines gp_rc
    # python3 の終了ステータスを捕捉（pipefail 下で代入 rc = pipeline rc）。parse 失敗(_GP_PY exit 2)や
    # python3 不在(127)を「該当なし」と取り違えず warn+非0 で surface する（run_watch の bd_warned と対称化）。
    lines="$(printf '%s' "$json" | python3 -c "$_GP_PY")"; gp_rc=$?
    if [ "$gp_rc" -ne 0 ]; then
        echo "orch-dispatch: gate-pending の JSON 整形に失敗 (rc=$gp_rc・python3 不在/非JSON?)。" >&2
        return 1
    fi
    local wt_lines
    wt_lines="$(_awaiting_gate_worktrees)"

    # foreign 鮮度を計算（gate-pending は foreign を cross-ledger read する文脈ゆえ常に評価・orch-6rb）。
    _compute_sync_freshness

    local foreign_lines=""   # 末尾の鮮度レポートで参照するためブロック外へスコープを上げる。

    if [ -z "$lines" ] && [ -z "$wt_lines" ]; then
        echo "gate-pending: なし（gate 待ちの cell はありません）"
        _emit_freshness_report ""   # foreign は今回なし。stale/unknown なら「なし」は信頼できない旨を⚠。
        return 0
    fi
    # cross-ledger 仕分け（§5.2 L0 2 トラック）: `bd list` は連結 substrate（§3 `bd repo sync` pull
    #   hydrate）で自 DB に取り込まれた foreign copy も prefix 非依存で返す（本 wrapper は `-C`/`--db` で
    #   台帳を絞らない＝cross-ledger read）。報告 track が self-dev（自台帳 ${SELF_PREFIX}-・直 gate 可）か
    #   外部 repo cell（foreign 台帳・§1.1 案C で admin gate 信頼 / admin 不在は人間 go-gate）かで gate
    #   意味論が違う（§5.2）ため出力を 2 バケットに分ける。foreign の surface は事前の courier
    #   `bd repo sync`（§5・本 wrapper の責務外＝read-only を保つ）に依存する。
    if [ -n "$lines" ]; then
        local self_lines
        self_lines="$(printf '%s\n' "$lines"    | grep -E "^${SELF_PREFIX}-" || true)"
        foreign_lines="$(printf '%s\n' "$lines" | grep -vE "^${SELF_PREFIX}-" | grep -v '^[[:space:]]*$' || true)"
        if [ -n "$self_lines" ]; then
            echo "gate-pending（self-dev cell・自台帳 ${SELF_PREFIX}-・直 gate 可・id + title）:"
            printf '%s\n' "$self_lines" | while IFS=$'\t' read -r id title; do
                [ -n "$id" ] && printf '  %s\t%s\n' "$id" "$title"
            done
        fi
        if [ -n "$foreign_lines" ]; then
            echo "gate-pending（外部 repo cell・連結 substrate hydrate・§5.2 外部 track／§1.1 案C: admin gate 信頼・admin 不在は人間 go-gate・id + title）:"
            printf '%s\n' "$foreign_lines" | while IFS=$'\t' read -r id title; do
                [ -n "$id" ] && printf '  %s\t%s\n' "$id" "$title"
            done
        fi
    fi
    if [ -n "$wt_lines" ]; then
        # orch-9l1: ラベル/CLOSED 非依存。自己 close・ラベル無しの worker もここに必ず出る（gate の silent skip 防止）。
        echo "未 merge worktree（gate+merge 待ち・bead status 非依存・orch-9l1）:"
        printf '%s\n' "$wt_lines" | while IFS=$'\t' read -r id n branch root base; do
            [ -n "$id" ] || continue
            # orch-b10: n=判定不能（base 解決不能で commit 数を数えられない）を「<base>+... commits」に埋め込むと
            #   誤読を招くため専用文言で surface する（silent drop でなく fail-loud＝degraded-watch と対称・要人間確認）。
            # orch-665: commit 数は per-repo 解決した base（self=main / external=default branch）に対する先行数ゆえ、
            #   表記も実 base 名で「<base>+N commits」と正確 surface する（self は base=main で従来表記 byte 不変）。
            local commits
            if [ "$n" = "判定不能" ]; then
                commits="base 解決不能→commit 判定不能（要確認・外部 repo の base 名を確認）"
            elif [ "$n" = "乖離" ]; then
                # orch-igl: base（外部 repo の main worktree 現在 checkout branch）が cell 系列から乖離（a>0 ∧ b>0）。
                #   git だけでは原因を断定できない（非 default branch を checkout 中／base が正常前進し cell が未 rebase）が、
                #   いずれも実 default に対する commit 数を正確に数えられないため fail-loud（両論併記で誤導を避ける・wf_75eda7ee）。
                commits="base（${base:-?}）が cell 系列から乖離→commit 数 判定不能（非 default checkout もしくは base 前進/未 rebase の可能性・要確認・orch-665/orch-igl）"
            else
                commits="${base:-main}+$n commits"
            fi
            if [ -n "$root" ]; then
                # orch-b10: 外部 repo cell（--repo が anchor≠repo）。gate routing は §1.1 案C（admin gate 信頼・
                #   admin 不在は人間 go-gate）。宣言 write が sandbox で断たれてもここで拾う（監視で loop を閉じる）。
                printf '  %s\t%s\t%s\t(external repo cell: %s)\n' "$id" "$commits" "$branch" "$root"
            else
                printf '  %s\t%s\t%s\n' "$id" "$commits" "$branch"
            fi
        done
    fi

    # 鮮度レポート（foreign バケットの有無に応じた注記/警告）を末尾で 1 回（orch-6rb・§5.2）。
    _emit_freshness_report "$foreign_lines"
}

# ─────────────────────────────────────────────────────────────────────────────
# (3) watch: spawn した actor の完了（success mode）を actor 種別ごとに derive して poll（orch-5pn）
#
#   完了シグナルは actor 種別で構造的に異なる（incident orch-5pn の核心）。dispatcher が共通の数値検証を
#   済ませてから actor 別 loop へ分岐する。**全 loop が exit 条件に success mode（完了）を必ず持つ**
#   ＝failure mode（timeout / window-gone）だけで終端する旧 monitor-admin-scribe.sh の欠落を構造的に塞ぐ。
# ─────────────────────────────────────────────────────────────────────────────

# tmux capture-pane でペイン内容を stdout へ（read-only）。rc 0=取得 / 非0=window 不在（消失検出に使う）。
#   capture-pane は tmux server を mutate しない＝watch の read-only 性（worker/generic）を破らない。
_capture_pane() {
    "$TMUX_BIN" capture-pane -p -t "$1" 2>/dev/null
}

# bd show <id> --json から "status<TAB>needs-user-flag<TAB>gate-pending-flag<TAB>updated_at" を stdout へ。rc 0=取得 / 1=bd 障害（not-found 含む）/ 2=parse 失敗（status 不明）。
#   2 列目（"1"/"0"）は needs-user ラベルの有無（orch-r5x: 呼び元が blocked を NEEDS-USER/BLOCKED に surface 区別する）。
#   3 列目（"1"/"0"）は gate-pending ラベルの有無（orch-o0b 軸C: 呼び元が status 非依存に gate-pending park を検知する）。
#   4 列目は updated_at（orch-edv T2: baseline 方式で re-pause=updated_at 前進を検知する）。
#   「不明」を「完了」と取り違えない（呼び元は非0 を warn し poll 継続＝fail-silent 回避）。
#   FOREIGN_REPO set 時は **直読 poll（channel α・orch-mot）**: `bd -C <path>` で foreign 台帳を hydrate 無しで
#   直接 read（live writer との race / staleness 無し・read のみ＝write-isolation OK）。未 set は既存 hydrated copy 経路。
_bead_status() {
    local json rc st
    if [ -n "$FOREIGN_REPO" ]; then
        json="$("$BD" -C "$FOREIGN_REPO" show "$1" --json 2>/dev/null)"; rc=$?
    else
        json="$("$BD" show "$1" --json 2>/dev/null)"; rc=$?
    fi
    [ "$rc" -ne 0 ] && return 1
    st="$(printf '%s' "$json" | python3 -c "$_STATUS_PY" 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] && return 2
    printf '%s' "$st"
    return 0
}

# 軽量 re-sync（watch admin --resync）: bdw 経由で連結 substrate を pull hydrate（§3 の正当 write）。
#   本 script は bare `bd` write を発行せず RESYNC_CMD（既定 bdw repo sync）へ委譲＝直列化と isolation を保つ。
#   RESYNC_CMD は空白区切りで配列化し exec（path に空白不可・ORCH_ADMIN_PROJECTS と同規約）。rc を返す。
_resync() {
    local -a cmd
    read -ra cmd <<< "$RESYNC_CMD"
    [ "${#cmd[@]}" -gt 0 ] || return 0
    "${cmd[@]}" >/dev/null 2>&1
}

# ── dispatcher: 共通の数値検証 → actor 別 loop ───────────────────────────────────
run_watch() {
    # 数値検証（fail-loud・全 actor 共通）: TIMEOUT は算術 $((SECONDS + TIMEOUT)) へ、POLL_INTERVAL は sleep へ
    #   流れる。bash 算術コンテキストは a[expr] の expr でコマンド置換を評価するため、非整数を通すと算術注入面に
    #   なる。使用前に厳密な整数のみへ束縛して injection 面を塞ぎ、非数値は明示 die する（worker 回帰 test を維持）。
    [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || die "--timeout は非負整数（秒）で指定してください（受領: $TIMEOUT）"
    [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || die "ORCH_DISPATCH_POLL_INTERVAL は非負整数（秒）で指定してください（受領: $POLL_INTERVAL）"
    # --foreign-repo（直読 poll・channel α・orch-mot）の入力検証（fail-loud）。worker は自台帳 gate-pending
    # ラベル / generic は pane が完了シグナルゆえ foreign 直読の対象外＝admin 専用。直読は hydrate を介さない
    # （race-free・sync 不要）ため --resync（hydrate・別マシン foreign 用）と同時指定は設計矛盾＝排他で die。
    # path 不在は fail-closed で die（誤った path を timeout まで無言 poll しない）。
    if [ -n "$FOREIGN_REPO" ]; then
        [ "$ACTOR" = "admin" ] || die "--foreign-repo（直読 poll）は --actor admin 専用です（worker/generic は対象外）"
        [ "$RESYNC" -eq 0 ] || die "--foreign-repo（直読・sync 不要・race-free）と --resync（hydrate）は同時指定できません（別マシン foreign のみ --resync）"
        [ -d "$FOREIGN_REPO" ] || die "--foreign-repo のパスが存在しません: $FOREIGN_REPO（同一マシンの foreign repo root を指定せよ）"
    fi
    case "$ACTOR" in
        worker)  run_watch_worker ;;
        admin)
            [[ "$IDLE_POLLS" =~ ^[1-9][0-9]*$ ]] || die "--idle-polls は正の整数で指定してください（受領: $IDLE_POLLS）"
            run_watch_admin ;;
        generic)
            [[ "$IDLE_POLLS" =~ ^[1-9][0-9]*$ ]] || die "--idle-polls は正の整数で指定してください（受領: $IDLE_POLLS）"
            run_watch_generic ;;
        *) die "未知の --actor: '$ACTOR'（worker | admin | generic）" ;;
    esac
}

# ── worker（既定・後方互換）: 自台帳 ${SELF_PREFIX}- の <id> が gate-pending ラベルを得たら完了 ──────
#   baseline 方式（orch-y9z・admin loop の orch-edv T2 を worker の label シグナルにも適用）:
#     旧実装は「gate-pending ラベル存在」を無条件に success mode とした。だが gate-pending は reversible な
#     ラベルで、errata 差し戻し中に label が残ったまま --watch を再武装すると武装した瞬間に即偽発火する
#     （orch-b10 運用実測 2026-07-04）。admin baseline は status にのみ効き label には効かなかった。
#     そこで watch 開始時（初回 poll 成功時）に (gate-pending 有無, updated_at) を baseline 記録し、
#     以降は **baseline からの変化** で発火する:
#       - 武装時に未 gate-pending（通常の dispatch 直後＝bead は open/in_progress）: gate-pending 到達で
#         発火（従来どおり・後方互換）。
#       - 武装時に既 gate-pending（errata 差し戻し中の再武装）: baseline から updated_at が前進（errata
#         宣言の notes append で updated_at が前進）するまで発火を suppress する。label 残置での即時偽発火を解消。
#     admin の reversible park（blocked/needs-user）と同じ扱い＝updated_at 前進で再宣言を検知する。worker の
#     gate-pending には admin の closed に相当する irreversible 終端が無い（label は常に reversible）。
run_watch_worker() {
    [ -n "$BD_ID" ] || die "--watch（worker）には bd-id が必要です"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[plan] watch(worker): $BD_ID が gate-pending になるまで poll（間隔 ${POLL_INTERVAL}s・timeout ${TIMEOUT}s）"
        echo "[plan]   毎回 $BD list --label gate-pending --status open,in_progress,blocked --limit 0 --json で $BD_ID の出現を確認"
        echo "[plan]   ★baseline 方式（orch-y9z）: 初回 poll で (gate-pending 有無, updated_at) を baseline 記録。武装時 未 gate-pending は到達で発火（後方互換）／武装時 既 gate-pending は updated_at 前進（errata 宣言の notes append）まで suppress（label 残置での即時偽発火を解消）。"
        return 0
    fi
    local deadline=$((SECONDS + TIMEOUT))
    local bd_warned=0        # bd list 障害を「まだ gate-pending でない」と取り違えない（fail-silent 回避）。
    local status_warned=0    # bd show 障害を silent にしない（baseline=updated_at 確立不能を surface）。
    # baseline 方式（orch-y9z）: 初回 poll 成功時に (gate-pending 有無, updated_at) を記録し変化で発火する。
    local baseline_set=0 baseline_gp=0 baseline_upd=""
    while true; do
        local json rc
        json="$("$BD" list --label gate-pending --status open,in_progress,blocked --limit 0 --json 2>/dev/null)"; rc=$?
        if [ "$rc" -ne 0 ]; then
            # bd list の失敗（バイナリ不在・台帳破損・PATH 不正等）を「対象がまだ gate-pending でない」と
            # 区別できないと、timeout まで無言 poll し誤報する（run_gate_pending は rc を surface する＝対称化）。
            # poll は継続するが（transient かもしれない）、初回失敗時に stderr へ warn して breakage を可視化する。
            if [ "$bd_warned" -eq 0 ]; then
                echo "orch-dispatch: warn: watch 中に bd list が失敗 (rc=$rc)。bd 障害の可能性（poll は継続・bd/PATH/台帳を確認せよ）。" >&2
                bd_warned=1
            fi
        else
            bd_warned=0   # 成功で warn 状態をリセット（復旧後の再失敗を再 warn する）。
            # 現在 gate-pending か（既存の hit 判定を保持＝gate-pending 検出の意味論は不変）。
            local cur_gp=0
            if printf '%s' "$json" | python3 -c "$_GP_PY" 2>/dev/null | cut -f1 | grep -qxF "$BD_ID"; then
                cur_gp=1
            fi
            # baseline 比較用に対象 bead の updated_at を取得（re-arm 即時偽発火の抑止・orch-y9z）。
            # _bead_status は "status<TAB>needs-user<TAB>gate-pending<TAB>updated_at" を返す（admin loop と共用・worker は自台帳）。
            # worker の gate-pending シグナルは自台帳 bd list（_GP_PY→cur_gp）が正路ゆえ 3 列目 _gp は使わないが、
            # 4 列出力の updated_at を最終変数 supd へ正しく落とすため placeholder として read する（orch-o0b lockstep）。
            local sraw srrc _st _nu _gp supd
            sraw="$(_bead_status "$BD_ID")"; srrc=$?
            if [ "$srrc" -ne 0 ]; then
                # updated_at 取得不能では baseline を確立できず発火判定が壊れる。fail-silent 回避で warn し、
                # baseline 未確立のまま poll を継続する（誤発火より安全＝suppress 側に倒す）。
                if [ "$status_warned" -eq 0 ]; then
                    echo "orch-dispatch: warn: watch 中に bd show が失敗/status 不明 (rc=$srrc)。baseline(updated_at) 確立不能——poll 継続（bd/PATH/台帳を確認せよ）。" >&2
                    status_warned=1
                fi
            else
                status_warned=0
                IFS=$'\t' read -r _st _nu _gp supd <<< "$sraw"
                # baseline 記録（gate-pending 判定と updated_at が両方取れた初回のみ）。
                if [ "$baseline_set" -eq 0 ]; then
                    baseline_gp="$cur_gp"; baseline_upd="$supd"; baseline_set=1
                fi
                # 発火判定: 現在 gate-pending AND（武装時は未 gate-pending だった〔新規到達＝後方互換〕
                #   OR updated_at が baseline から前進〔errata 宣言後の gate-pending 再宣言〕）。
                if [ "$cur_gp" -eq 1 ] && { [ "$baseline_gp" -eq 0 ] || [ "$supd" != "$baseline_upd" ]; }; then
                    local fire_reason
                    if [ "$baseline_gp" -eq 0 ]; then
                        fire_reason="新規到達（武装時は未 gate-pending）"
                    else
                        fire_reason="re-arm 後の再宣言（baseline から updated_at 前進＝errata 差し戻し後の gate-pending 再付与・orch-y9z）"
                    fi
                    echo "watch: $BD_ID が gate-pending になりました（$fire_reason・admin の gate 可）"
                    return 0
                fi
            fi
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "watch: timeout (${TIMEOUT}s) — $BD_ID はまだ gate-pending ではありません" >&2
            return 3
        fi
        sleep "$POLL_INTERVAL"
    done
}

# ── admin（peer admin・foreign project）: foreign bead の baseline からの変化 ① OR pane idle ② で完了 ─────
#   peer admin は MY 台帳に gate-pending を出さない（自 foreign 台帳を close/hold するだけ）。完了シグナルは
#   2 系統: ① <id> の foreign 状態が baseline から done-set へ変化（authoritative）/ ② --window 指定時の
#   pane idle（heuristic・bead 非追跡や未 close を補う）。どちらか早い方で完了。window 消失は非致命
#   （pane 検査を無効化し status poll 継続）＝status が authoritative ゆえ。
#
#   ★① の status 変化検出は 2 発火軸を持つ（orch-m3r・defense-in-depth）:
#     軸A（status done-set）: status ∈ done_set への baseline からの変化（既定 closed=DONE / blocked=BLOCKED・NEEDS-USER）。
#     軸B（needs-user ラベル park）: status が done-set 外でも（例 status=open のまま）needs-user ラベルを保持し baseline から
#       変化したとき発火する。foreign admin が NEEDS-USER park を needs-user ラベル+notes append で宣言しても status を
#       open に残す契約遵守のバラつき（incident 2026-07-05 scp-bou・status=open/labels=[gate-pending,needs-user]）で軸A が
#       30 分 timeout まで無発火だった park 検知漏れを塞ぐ。needs-user ラベルは actor の明示 park 宣言ゆえ status 非依存で
#       拾う（一次対処＝契約是正 relay で admin に status=blocked を義務付け済だが、契約遵守のバラつきに watch が脆いのを
#       構造で補強する defense-in-depth）。軸B も baseline 方式ゆえ既 needs-user な bead の re-watch では誤発火しない。
#
#   baseline 方式（orch-edv T2・silent mutual-wait deadlock 恒久 fix）:
#     watch 開始時（初回 poll 成功時）に対象 bead の (status, needs-user, updated_at) を baseline として記録し、
#     以降は **baseline からの変化** で発火する。fire 条件 = status ∈ done_set AND (status == closed OR 現 sig ≠ baseline sig)。
#     - **irreversible 終端（closed=DONE）**: baseline から不変でも即発火（closed は再 pause 不能ゆえ pre-existing でも完了で正しい）。
#     - **reversible park（blocked / blocked+needs-user）**: baseline から不変なら発火しない（＝既 blocked bead の
#       即時誤発火解消）。**baseline から変化（status 遷移 or updated_at 前進 or label 変化）したときのみ発火**する。
#       これにより (i) 既に blocked+needs-user な bead を watch し始めても即時誤発火せず、(ii) admin が同じ bead へ
#       新 question で re-pause（status/label 不変でも notes append で updated_at 前進・orch-spawn-admin ブリーフ⑨）
#       すると「baseline からの変化」として検知できる（root cause #1「無変化 transition」の取りこぼしを断つ）。
#     dispatch 直後の watch（baseline=open/in_progress）は done-set への遷移が常に変化ゆえ従来どおり発火する（後方互換）。
run_watch_admin() {
    [ -n "$BD_ID" ] || die "--watch --actor admin には foreign bead-id が必要です"
    local -a done_set
    IFS=',' read -ra done_set <<< "$DONE_STATUS"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[plan] watch(admin): $BD_ID の foreign 状態が baseline から done-set {${DONE_STATUS}} へ変化 ① OR pane idle ② まで poll（間隔 ${POLL_INTERVAL}s・timeout ${TIMEOUT}s）"
        echo "[plan]   ★baseline 方式（orch-edv T2）: 初回 poll で (status,needs-user,updated_at) を baseline 記録。closed=irreversible 終端は不変でも発火／blocked・needs-user=reversible park は baseline から変化（updated_at 前進=re-pause 含む）したときのみ発火（既 blocked bead の即時誤発火解消）。"
        echo "[plan]   ★①発火軸B（orch-m3r）: status が done-set 外でも（例 status=open のまま）needs-user ラベルを保持し baseline から変化（ラベル遷移 or 保持中の updated_at 前進）したら NEEDS-USER park として発火（status=open park の検知漏れを塞ぐ・軸B も baseline 方式で既 needs-user の再 watch は誤発火なし）。"
        echo "[plan]   ★①発火軸C（orch-o0b）: status が done-set 外でも（例 status=in_progress のまま）gate-pending ラベルを保持し baseline から変化（0→1 遷移〔updated_at 不変でも〕 or 保持中の updated_at 前進）したら GATE-PENDING park として発火（human-ratify 終端形＝自己 close 禁止で gate-pending+in_progress のまま park する穴を塞ぐ・軸C も baseline 方式で既 gate-pending の再武装は誤発火なし）。"
        # read 経路の注記は値比較で出し分ける（直読 / hydrate / read-only）。RESYNC は既定 "0"（非null）ゆえ
        # ${RESYNC:+...} だと --resync 未指定でも常に hydrate 文言が出る誤案内になる＝実ループの gating（[ -eq 1 ]）と揃える。
        local _read_note
        if [ -n "$FOREIGN_REPO" ]; then
            _read_note="直読 poll: $BD -C '$FOREIGN_REPO' show $BD_ID --json（同一マシン foreign を hydrate 無しで直接 read＝race-free・sync 不要・read-only）"
        elif [ "$RESYNC" -eq 1 ]; then
            _read_note="--resync 指定: 事前に '$RESYNC_CMD' で軽量 hydrate（bdw 委譲）後に read（別マシン foreign 用）"
        else
            _read_note="--resync なし＝既 hydrate 済みの status を read（re-sync は呼ばない・read-only）"
        fi
        echo "[plan]   ① 毎回 status を read（$_read_note）"
        [ -n "$WINDOW" ] && echo "[plan]   ② tmux capture-pane -t '$WINDOW' が ${IDLE_POLLS} 回連続無変化＝pane idle（INCONCLUSIVE 補助）" || echo "[plan]   ②（--window 未指定ゆえ pane idle 検査なし＝foreign status のみ）"
        echo "[plan]   ※宣言なき間（open/in_progress・宣言 bead 未作成）は未完(INCONCLUSIVE)＝DONE にしない。timeout も INCONCLUSIVE（orch-mot）。"
        return 0
    fi
    local deadline=$((SECONDS + TIMEOUT))
    # baseline 方式（orch-edv T2）: 初回 poll 成功時に (status,needs-user,gate-pending,updated_at) を baseline 記録し、
    # 以降は baseline からの変化で発火する。baseline_sig は 4 属性を連結した署名（変化検出キー）。
    # baseline_nu は baseline 時点の needs-user ラベル有無（orch-m3r 軸B の発火理由 derive に使う）。
    # baseline_gp は baseline 時点の gate-pending ラベル有無（orch-o0b 軸C: 0→1 遷移 vs 保持中 updated_at 前進の判別に使う）。
    local baseline_status="" baseline_sig="" baseline_in_done=0 baseline_nu=0 baseline_gp=0 baseline_set=0
    local pane_prev="" pane_same=0 pane_disabled=0 win_warned=0
    local bd_warned=0
    [ -n "$WINDOW" ] || pane_disabled=1   # window 未指定なら pane idle 検査をしない（foreign status のみ）
    while true; do
        # --- success signal ①: foreign bead の baseline からの変化（authoritative）---
        if [ "$RESYNC" -eq 1 ]; then
            _resync || echo "orch-dispatch: warn: watch(admin) の re-sync が失敗（poll 継続・bdw/連結 substrate を確認せよ）。" >&2
        fi
        local raw st nu upd nu_flag gp gp_flag cur_sig cur_in_done rc
        raw="$(_bead_status "$BD_ID")"; rc=$?
        if [ "$rc" -ne 0 ]; then
            if [ "$bd_warned" -eq 0 ]; then
                echo "orch-dispatch: warn: watch(admin) 中に bd show が失敗/status 不明 (rc=$rc)。bd 障害の可能性（poll 継続・bd/PATH/台帳を確認せよ）。" >&2
                bd_warned=1
            fi
        else
            bd_warned=0
            # _bead_status は "status<TAB>needs-user-flag<TAB>gate-pending-flag<TAB>updated_at" を返す（orch-r5x / orch-o0b / orch-edv T2）。
            # status を done-set 照合へ、needs-user flag を blocked の surface 区別（NEEDS-USER/BLOCKED）へ、
            # gate-pending flag を軸C の status 非依存 park 検知へ、updated_at を baseline 比較（re-pause 検知）へ使う。
            # 列は IFS=TAB で厳密分解し read 変数を 4 個に揃える（orch-o0b lockstep: 3 個だと gate-pending 列が upd へ食い込み silent 破損）。
            IFS=$'\t' read -r st nu_flag gp_flag upd <<< "$raw"
            nu=0; [ "$nu_flag" = "1" ] && nu=1
            gp=0; [ "$gp_flag" = "1" ] && gp=1
            cur_sig="$st|$nu|$gp|$upd"
            # 現 status が done-set に属するか。
            cur_in_done=0
            local d
            for d in "${done_set[@]}"; do
                [ -n "$d" ] && [ "$st" = "$d" ] && { cur_in_done=1; break; }
            done
            # baseline 記録（初回 poll のみ）。既 done-set かと needs-user / gate-pending 有無も控える（fire 理由の derive に使う）。
            if [ "$baseline_set" -eq 0 ]; then
                baseline_status="$st"; baseline_sig="$cur_sig"; baseline_in_done="$cur_in_done"; baseline_nu="$nu"; baseline_gp="$gp"; baseline_set=1
            fi
            # 発火判定は 2 軸（orch-m3r・defense-in-depth）。どちらか一方でも成立すれば foreign 完了として発火する:
            #   軸A（status・orch-edv T2）: 現 status が done-set に属し、かつ（closed=irreversible 終端は不変でも /
            #     それ以外=reversible park は baseline から変化したときのみ）。既 blocked/needs-user bead の即時誤発火を
            #     解消しつつ re-pause（updated_at 前進で cur_sig≠baseline_sig）を検知する。
            #   軸B（needs-user ラベル park・orch-m3r）: status が done-set に属さなくても（例 status=open のまま）、
            #     現 bead が needs-user ラベルを保持し、かつ baseline から変化した（ラベル 0→1 の遷移 or ラベル保持中の
            #     updated_at 前進）とき発火する。foreign admin が NEEDS-USER park を needs-user ラベル+notes append で
            #     宣言しても status を open に残す契約遵守のバラつき（incident 2026-07-05 の第2バンドル・scp-bou
            #     status=open/labels=[gate-pending,needs-user]）で、軸A が 30 分 timeout まで無発火だった穴を塞ぐ。
            #     needs-user ラベルは actor の明示 park 宣言ゆえ status 非依存で park として拾う（軸A の status 依存を補う）。
            #     baseline 方式は軸B でも維持: 既 needs-user な bead の re-watch（baseline 不変）では発火しない（誤発火なし）。
            #   軸C（gate-pending ラベル park・orch-o0b）: foreign admin の human-ratify 終端形は自己 close 禁止ゆえ
            #     「gate-pending ラベル + status=in_progress のまま」になり、軸A（done-set 外）も軸B（needs-user 無し）も
            #     拾えず 30 分 timeout していた（incident 2026-07-06 scp-bou.6 / cm-3qb）。worker :fire（orch-y9z）と同型に、
            #     現 bead が gate-pending ラベルを保持し、かつ（武装時は未 gate-pending だった〔0→1 遷移＝updated_at 不変でも〕
            #     OR baseline から変化した〔保持中の updated_at 前進＝errata 再宣言〕）とき発火する。baseline 方式ゆえ
            #     既 gate-pending な bead の再武装（baseline 不変）では発火しない（誤発火なし）。gate-pending は status 非依存の
            #     明示 park 宣言ゆえ status 依存の軸A を補う（軸B と同型・admin 直読 :fire の第3軸）。
            local fire_status=0 fire_label=0 fire_gp=0
            if [ "$cur_in_done" -eq 1 ] && { [ "$st" = "closed" ] || [ "$cur_sig" != "$baseline_sig" ]; }; then
                fire_status=1
            fi
            if [ "$nu" -eq 1 ] && [ "$cur_sig" != "$baseline_sig" ]; then
                fire_label=1
            fi
            if [ "$gp" -eq 1 ] && { [ "$baseline_gp" -eq 0 ] || [ "$cur_sig" != "$baseline_sig" ]; }; then
                fire_gp=1
            fi
            if [ "$fire_status" -eq 1 ] || [ "$fire_label" -eq 1 ] || [ "$fire_gp" -eq 1 ]; then
                # 終端宣言の種別を derive（orch-mot: DONE=closed / blocked は needs-user ラベル有無で
                # NEEDS-USER（人間判断待ち）か plain BLOCKED かを surface 区別・done-set 外は needs-user 保持なら
                # NEEDS-USER〔軸B〕・gate-pending 保持なら GATE-PENDING〔軸C・orch-o0b〕・他=TERMINAL）。
                # decl 順位（done-set 外）: NEEDS-USER > GATE-PENDING > TERMINAL（人間判断待ちが gate-pending park より強い signal）。
                local decl
                case "$st" in
                    closed)  decl="DONE" ;;
                    blocked) [ "$nu" -eq 1 ] && decl="NEEDS-USER" || decl="BLOCKED" ;;
                    *)       if [ "$nu" -eq 1 ]; then decl="NEEDS-USER"
                             elif [ "$gp" -eq 1 ]; then decl="GATE-PENDING"
                             else decl="TERMINAL"; fi ;;
                esac
                # 発火理由を derive（軸C のみ=status 非依存 gate-pending park / 軸B のみ=status 非依存 needs-user park /
                # 新規到達 / re-pause / irreversible 終端）。監視者が「何が起きたか」を判別できる。優先順位は
                # 軸B（needs-user）> 軸C（gate-pending）> 軸A（status）で、軸A が成立するときは従来どおり軸A の理由を優先する（後方互換）。
                # 軸C の理由文言は軸B と機械判別可能（'gate-pending park' + 'orch-o0b 軸C'・テストで assert）。
                local fire_reason
                if [ "$fire_status" -eq 0 ] && [ "$fire_label" -eq 0 ] && [ "$fire_gp" -eq 1 ]; then
                    # 軸C のみ発火（status は done-set 外＝in_progress 等のまま・needs-user 無し・gate-pending park・orch-o0b）。
                    if [ "$baseline_gp" -eq 1 ]; then
                        fire_reason="gate-pending park 再宣言（status='$st' のまま baseline から updated_at 前進＝errata 再宣言・status 非依存 park 検知・orch-o0b 軸C）"
                    else
                        fire_reason="gate-pending park 宣言（status='$st' のまま gate-pending ラベル 0→1 遷移＝status 非依存 park 検知・orch-o0b 軸C）"
                    fi
                elif [ "$fire_status" -eq 0 ] && [ "$fire_label" -eq 1 ]; then
                    # 軸B のみ発火（status は done-set 外＝open 等のまま needs-user park・orch-m3r）。
                    if [ "$baseline_nu" -eq 1 ]; then
                        fire_reason="needs-user park 再宣言（status='$st' のまま baseline から updated_at 前進＝status 非依存 park 検知・orch-m3r 軸B）"
                    else
                        fire_reason="needs-user park 宣言（status='$st' のまま needs-user ラベル遷移＝status 非依存 park 検知・orch-m3r 軸B）"
                    fi
                elif [ "$cur_sig" != "$baseline_sig" ]; then
                    if [ "$baseline_in_done" -eq 1 ]; then
                        fire_reason="re-pause（baseline から updated_at/label 前進＝park 状態の再宣言・orch-edv T2）"
                    else
                        fire_reason="新規到達（baseline status='$baseline_status' から done-set へ遷移）"
                    fi
                else
                    fire_reason="irreversible 終端（closed=再 pause 不能ゆえ baseline 不変でも完了）"
                fi
                echo "watch(admin): $BD_ID status='$st'＝foreign 完了シグナル（終端宣言=$decl・$fire_reason・admin の gate 可）"
                return 0
            fi
        fi
        # --- success signal ②: pane idle（--window 指定時のみ）---
        if [ "$pane_disabled" -eq 0 ]; then
            local cur cap_rc
            cur="$(_capture_pane "$WINDOW")"; cap_rc=$?
            if [ "$cap_rc" -ne 0 ]; then
                # window 消失は非致命: pane 検査を諦め foreign status poll を継続（status が authoritative）。
                if [ "$win_warned" -eq 0 ]; then
                    echo "orch-dispatch: warn: watch(admin) window '$WINDOW' が見えない（pane idle 検査を無効化・foreign status poll を継続）。" >&2
                    win_warned=1
                fi
                pane_disabled=1
            else
                if [ "$pane_same" -gt 0 ] && [ "$cur" = "$pane_prev" ]; then
                    pane_same=$((pane_same + 1))
                else
                    pane_same=1
                fi
                pane_prev="$cur"
                if [ "$pane_same" -ge "$IDLE_POLLS" ]; then
                    echo "watch(admin): window '$WINDOW' が ${IDLE_POLLS} 回連続で無変化＝pane idle（admin 完了シグナル・要 foreign status 確認）"
                    return 0
                fi
            fi
        fi
        # --- failure: timeout（宣言なき終了は決して DONE にしない＝INCONCLUSIVE・orch-mot）---
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "watch(admin): timeout (${TIMEOUT}s) — $BD_ID は終端宣言（DONE/BLOCKED）未到達＝未完(INCONCLUSIVE)。宣言なき間/終了を DONE にしない（要確認）。" >&2
            return 3
        fi
        sleep "$POLL_INTERVAL"
    done
}

# ── generic（汎用・bead も label も無い使い捨て actor）: pane idle のみで完了（--window 必須）─────────
#   pane が唯一の完了シグナルゆえ window 消失=exit 4（actor 終了だが完了は不定で surface・success と混同しない）。
run_watch_generic() {
    [ -n "$WINDOW" ] || die "--watch --actor generic には --window が必要です（pane idle が唯一の完了シグナル）"
    local label="${BD_ID:-$WINDOW}"
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[plan] watch(generic): tmux capture-pane -t '$WINDOW' が ${IDLE_POLLS} 回連続無変化＝pane idle まで poll（間隔 ${POLL_INTERVAL}s・timeout ${TIMEOUT}s・label '$label'）"
        return 0
    fi
    local deadline=$((SECONDS + TIMEOUT))
    local pane_prev="" pane_same=0
    while true; do
        local cur cap_rc
        cur="$(_capture_pane "$WINDOW")"; cap_rc=$?
        if [ "$cap_rc" -ne 0 ]; then
            echo "watch(generic): window '$WINDOW' が消失＝actor 終了（完了は不定で surface・要確認）" >&2
            return 4
        fi
        if [ "$pane_same" -gt 0 ] && [ "$cur" = "$pane_prev" ]; then
            pane_same=$((pane_same + 1))
        else
            pane_same=1
        fi
        pane_prev="$cur"
        if [ "$pane_same" -ge "$IDLE_POLLS" ]; then
            echo "watch(generic): '$label' の window '$WINDOW' が ${IDLE_POLLS} 回連続無変化＝pane idle（完了シグナル）"
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "watch(generic): timeout (${TIMEOUT}s) — '$label' は pane idle 未達" >&2
            return 3
        fi
        sleep "$POLL_INTERVAL"
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# (4) liveness: hands-free relay loop の silent mutual-wait deadlock backstop（orch-edv T3・F2）
#
#   read-only 単発 sweep。純 event-driven な watch が event を 1 回取りこぼすと無限待ちになるのを埋める
#   heartbeat/reconciliation の単発版。mutate しない（起票/dispatch/label いずれもしない・surface のみ）。
# ─────────────────────────────────────────────────────────────────────────────

# 現在時刻（epoch 秒）。ORCH_DISPATCH_NOW_EPOCH で固定可（test/デバッグ）。未設定/非整数なら実時刻。
_now_epoch() {
    if [ -n "$NOW_EPOCH_OVERRIDE" ] && [[ "$NOW_EPOCH_OVERRIDE" =~ ^[0-9]+$ ]]; then
        printf '%s' "$NOW_EPOCH_OVERRIDE"
    else
        date +%s 2>/dev/null
    fi
}

# spawn window（wt-* / 素 admin / admin-*）を **session:window 正準形** で列挙（read-only・orch-riz1 topology）。
#   ★実装は共有 lib `lib/orch_liveness.sh` の `_liveness_windows <tmux_bin>` へ集約済み（bd orch-4js9 fence1・
#     orch-delivery-observe.sh と単一 SSOT を共有＝canonical form `:(wt-|admin-|admin$)` を二重に持たない）。
#     呼出は `_liveness_windows "$TMUX_BIN"`（自前 env-seam ORCH_DISPATCH_TMUX で解決した bin を渡す）。
#   裁定-topology（orch-thgx・命名/addressing）: admin window の宛先正準形は `<project>:admin`（window 名は素 'admin'
#   維持・session 名=project 名が識別を担う）。format `#{session_name}:#{window_name}` で素 admin 窓（window 名=admin）
#   も admin-<project>（移行期出力）も session 修飾付きで一意に surface する。wt-<id> も session 修飾されるため下流（③）
#   の id 抽出は `${w##*:}` で window_name を取り出してから wt- を剥がす（teeth (b)）。

# self 台帳の bead status を read（liveness ③・foreign を経由しない＝wt-<id> は自台帳 worker cell）。
#   "status<TAB>needs-user<TAB>gate-pending<TAB>updated_at" を stdout へ（orch-o0b で 4 列化）。rc 0=取得 / 1=bd 障害(not-found 含む) / 2=parse 失敗。
_liveness_self_status() {
    local json rc st
    json="$("$BD" show "$1" --json 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] && return 1
    st="$(printf '%s' "$json" | python3 -c "$_STATUS_PY" 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] && return 2
    printf '%s' "$st"; return 0
}

# RFC3339 timestamp → 経過分。now は _now_epoch。parse 不能/空/未来(clock skew) は "?"/0 へ縮退（fail-safe）。
_age_min_of() {
    local ts="$1" ep now
    [ -n "$ts" ] || { printf '?'; return 0; }
    ep="$(date -d "$ts" +%s 2>/dev/null)" || true
    { [ -n "$ep" ] && [[ "$ep" =~ ^[0-9]+$ ]]; } || { printf '?'; return 0; }
    now="$(_now_epoch)"
    { [ -n "$now" ] && [[ "$now" =~ ^[0-9]+$ ]]; } || { printf '?'; return 0; }
    local a=$(( (now - ep) / 60 )); [ "$a" -lt 0 ] && a=0
    printf '%s' "$a"
}

# ── SPAWNED marker smoke helper（orch-gv9・C案 検知側）───────────────────────────────
#   marker 契約（SSOT・本 bead で確定・orch-8hp 教訓）: worker は起動直後に自 bead notes へ **行頭アンカー**
#   `[SPAWNED--<id>]` を bdw --append-notes で 1 行書く（例: `[SPAWNED--orch-gv9]`）。一意 prefix `[SPAWNED--`
#   で pins 本文・他 sentinel と衝突せず grep 可能。write が sandbox で silent に断たれた cell（発端は external
#   repo cell の anchor≠repo allowWrite bug＝orch-b10/orch-7ti だが、self-dev worker cell も sandbox の宣言 write
#   断絶で同様に marker を書けない＝external 限定でなく双方を診断する）はこの marker を書けない＝『window 生存 × 非終端 × stale ×
#   marker 不在』で宣言 write 断絶を機械検知する（検証対象＝worker の実 write と検証手段＝その write の有無が
#   一致する真 smoke・bd orch-gv9 C案）。判定は行頭空白許容（TUI インデント耐性・zombie sentinel RE と同型）。
ORCH_SPAWN_MARKER_RE='^[[:space:]]*\[SPAWNED--'

# bd show --json → notes 文字列を stdout へ（marker grep 用）。object / 単要素配列の両方を受ける。
#   parse 失敗は非0（呼び元は「判定不能」＝fail-safe で sever 断定しない）。
_NOTES_PY='
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(2)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    sys.exit(2)
n = data.get("notes")
sys.stdout.write(n if isinstance(n, str) else "")
'

# 対象 bead notes に SPAWNED marker があるか。rc 0=present / 1=absent（notes 取得成功・marker 無し）/
#   2=判定不能（bd read / parse 失敗）。liveness ③ は self 台帳の wt-<id> を突合するため self 読み
#   （`bd show <id> --json`）で統一する（③ の status read = _liveness_self_status と同一 ledger source）。
#   external repo cell（foreign 台帳）は連結 substrate hydrate（bd repo sync）で自 DB に marker が入った後に
#   本 self 読みが拾う（gate-pending cross-ledger と同じ hydrate 依存・sync lag あり＝§5.2 と整合）。
_spawned_marker_present() {
    local id="$1" json rc notes
    json="$("$BD" show "$id" --json 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] && return 2
    notes="$(printf '%s' "$json" | python3 -c "$_NOTES_PY" 2>/dev/null)"; rc=$?
    [ "$rc" -ne 0 ] && return 2
    printf '%s' "$notes" | grep -qE "$ORCH_SPAWN_MARKER_RE" && return 0
    return 1
}

# park bead（needs-user / gate-pending）を 1 台帳 1 label 分読み、停滞行に scope 列を付与して emit。
#   $1=repo（空=自台帳・非空= foreign を bd -C 直読）/ $2=label / $3=now_epoch / $4=scope（表示タグ）。
#   自台帳読み（repo 空）は SELF_PREFIX で filter する: 連結 substrate hydrate で自 DB の `bd list` は foreign copy
#     （un-/sc-…）も prefix 非依存で返す（gate-pending mode コメント参照）。filter しないと foreign copy が
#     scope="" ＝ [foreign] タグ無しで self-dev の如く surface され、--foreign-repo 併用時は id×scope dedup を
#     すり抜け二重 surface し、hydrated copy の凍結 updated_at で false stall も出す。foreign は --foreign-repo
#     経路（scope=foreign・直読）へ一本化する（gate-pending mode の self/foreign バケット分割と SSOT 整合・orch-edv T3）。
#   bd list 失敗（rc≠0）は run_watch_worker / run_gate_pending と同型に stderr へ warn する（fail-silent 回避）:
#     liveness は silent mutual-wait deadlock の fail-loud backstop ゆえ、bd 障害を握りつぶし『停滞なし』と偽 clean を
#     出すと人間を誤って安心させる。warn は stdout（awk へ流れる停滞行）と分離した stderr へ出す。
_liveness_parked_one() {
    local repo="$1" label="$2" now="$3" scope="${4:-}"
    local json rc
    if [ -n "$repo" ]; then
        json="$("$BD" -C "$repo" list --label "$label" --status open,in_progress,blocked --limit 0 --json 2>/dev/null)"; rc=$?
    else
        json="$("$BD" list --label "$label" --status open,in_progress,blocked --limit 0 --json 2>/dev/null)"; rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "orch-dispatch: warn: liveness の bd list（${scope:-self}/${label}）が失敗 (rc=$rc)。decision-point 停滞は不完全（『停滞なし』を信用するな・bd/PATH/台帳を確認せよ）。" >&2
        return 0
    fi
    # --limit 0（截断回避）+ 非 closed（park は非 closed）。closed 除外は park 意味論と一致（orch-edv T3 実装注意）。
    printf '%s' "$json" | python3 -c "$_PARKED_PY" "$now" "$LIVENESS_STALE_MIN" "$label" 2>/dev/null \
        | { if [ -z "$repo" ]; then grep -E "^${SELF_PREFIX}-" || true; else cat; fi; } \
        | awk -F'\t' -v s="$scope" 'NF{print $0 "\t" s}'
}

# 全 park bead 停滞行（自台帳 needs-user/gate-pending + foreign）を集約し id×scope で dedup（needs-user 優先）。
_liveness_parked() {
    local now; now="$(_now_epoch)"
    {
        _liveness_parked_one "" needs-user "$now" ""
        _liveness_parked_one "" gate-pending "$now" ""
        if [ -n "$FOREIGN_REPO" ]; then
            _liveness_parked_one "$FOREIGN_REPO" needs-user "$now" foreign
            _liveness_parked_one "$FOREIGN_REPO" gate-pending "$now" foreign
        fi
    } | awk -F'\t' '!seen[$1"|"$4]++'
}

# ── host-progress probe（liveness 第3軸・orch-ayj）─────────────────────────────────
#   『長 running build プロセス生存 ∧ 監視 fs への書込が N 分ゼロ』を silent hang 疑いとして surface する。
#   read-only（pgrep/ps/find のみ）。build プロセス不在なら find コストを払わず skip する（呼び元で分岐）。

# pgrep -f pattern にマッチする PID を改行区切りで stdout へ、pgrep の rc を return で返す（read-only）。
#   pgrep rc: 0=マッチ / 1=マッチなし / 2=pattern 構文エラー / 3=致命エラー。呼び元は rc≥2 を『マッチなし』と
#   同一視せず fail-loud に扱う（不正 ERE override 等で pgrep が実行時失敗すると stdout が空になり、rc を捨てると
#   silent hang 検知が黙って無効化される false-clean になる＝binary 不在 guard と同型の穴を塞ぐ）。
_hostprog_pids() {
    local out rc
    out="$("$PGREP_BIN" -f "$HOSTPROG_PATTERN" 2>/dev/null)"; rc=$?
    printf '%s' "$out"
    return "$rc"
}

# PID 群のうち etimes（elapsed 秒）が閾値以上の「長 running」PID のみを改行区切りで返す。
#   ps 失敗/etimes 取得不能な PID は fail-loud 側（=長 running とみなし残す）: liveness は silent hang の
#   backstop ゆえ取りこぼしより surface を優先する。正常 build は fs 書込継続で別途 not-stall になるため、
#   年齢判定不能による過検出は write 軸（_hostprog_has_recent_write）が吸収する（false positive を生まない）。
_hostprog_longrunning() {
    local pids="$1" stale_sec=$(( LIVENESS_STALE_MIN * 60 ))
    [ -n "$pids" ] || return 0
    local csv; csv="$(printf '%s' "$pids" | tr '\n' ',' | sed 's/,$//')"
    [ -n "$csv" ] || return 0
    local out rc
    out="$("$PS_BIN" -o pid=,etimes= -p "$csv" 2>/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        printf '%s\n' "$pids"   # 年齢判定不能＝安全側で全 PID を残す（silent hang backstop）
        return 0
    fi
    # ps 出力（"  <pid>  <etimes>" 行・先頭空白あり）から etimes≥閾値の pid を抽出。
    printf '%s\n' "$out" | awk -v th="$stale_sec" 'NF>=2 { if ($2+0 >= th) print $1 }'
}

# 監視 fs パス群に N 分以内の書込があるか。書込あり=0（正常 build）・書込なし=1（stall 側）。
#   glob 展開し実在パスのみ find。-newermt <ref> -print -quit で N 分以内 mtime のファイルを 1 件でも見つけたら
#   「書込継続」。ref は実時刻基点（fs mtime 比較ゆえ NOW_EPOCH override は使わない）。
_hostprog_has_recent_write() {
    local now ref_epoch ref
    now="$(date +%s 2>/dev/null)"; [ -n "$now" ] && [[ "$now" =~ ^[0-9]+$ ]] || now=0
    ref_epoch=$(( now - LIVENESS_STALE_MIN * 60 ))
    ref="$(date -d "@$ref_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
    [ -n "$ref" ] || ref="@$ref_epoch"
    local p hit
    for p in $HOSTPROG_PATHS; do            # 意図的に unquoted＝glob 展開（非マッチ literal は下で -e が弾く）
        [ -e "$p" ] || continue
        hit="$("$FIND_BIN" "$p" -newermt "$ref" -type f -print -quit 2>/dev/null)"
        [ -n "$hit" ] && return 0            # 1 件でも recent write → 書込継続（正常 build）
    done
    return 1                                 # 全パス書込なし＝fs 書込停止
}

run_liveness() {
    [ -z "$BD_ID" ] || die "liveness モードは bd-id を取りません（余分な引数: $BD_ID）"
    [[ "$LIVENESS_STALE_MIN" =~ ^[0-9]+$ ]] || die "--stale-min は非負整数（分）で指定してください（受領: $LIVENESS_STALE_MIN）"
    if [ -n "$FOREIGN_REPO" ]; then
        [ -d "$FOREIGN_REPO" ] || die "--foreign-repo のパスが存在しません: $FOREIGN_REPO（同一マシンの foreign repo root を指定せよ）"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[plan] liveness sweep (read-only・mutate しない・起票/dispatch もしない):"
        echo "[plan]   ① tmux list-panes -a -F '#{session_name}:#{window_name}' で wt-*/admin-*/素 admin spawn window を session:window 正準形（<project>:admin）で列挙"
        echo "[plan]   ② bd list --label needs-user / gate-pending --status open,in_progress,blocked --limit 0 --json（自台帳${FOREIGN_REPO:+ + foreign $FOREIGN_REPO}）で park bead を読み age≥${LIVENESS_STALE_MIN}分 を decision-point 停滞として surface"
        echo "[plan]   ③ 各 wt-<id> window の self bead を bd show で読み、非終端で無更新≥${LIVENESS_STALE_MIN}分 or 宣言 bead 不在を window 停滞として surface"
        [ "$SPAWN_SMOKE" = "1" ] && echo "[plan]   ③+ SPAWN_SMOKE=1: stale cell の notes に SPAWNED marker（${ORCH_SPAWN_MARKER_RE}）が無ければ『宣言 write 断絶疑い（sandbox sever・orch-gv9）』を付す（read-only・spawn abort しない・advisory）"
        echo "[plan]   ④ pgrep -f '${HOSTPROG_PATTERN}' で長 running build プロセスを検出し、生存(etimes≥${LIVENESS_STALE_MIN}分)かつ監視 fs（${HOSTPROG_PATHS}）への書込が ${LIVENESS_STALE_MIN}分ゼロなら silent hang 疑いとして surface（pgrep/ps/find のみ・read-only・build 不在は probe skip）"
        return 0
    fi

    local wins; wins="$(_liveness_windows "$TMUX_BIN")"

    echo "== orch-dispatch liveness sweep (read-only) =="
    echo "  stale 閾値: ${LIVENESS_STALE_MIN} 分 / foreign: ${FOREIGN_REPO:-なし}"

    # ── ① 生存 spawn window ────────────────────────────────────────────────────
    echo "● spawn window（生存）:"
    if [ -z "$wins" ]; then
        echo "  (spawn window なし)"
    else
        printf '%s\n' "$wins" | while IFS= read -r w; do [ -n "$w" ] && echo "  $w"; done
    fi

    # ── ② decision-point 停滞（needs-user / gate-pending が N 分以上・自台帳 + foreign）────────────
    echo "⚠ decision-point 停滞（needs-user / gate-pending が ${LIVENESS_STALE_MIN} 分以上・自台帳${FOREIGN_REPO:+ + foreign}）:"
    local parked; parked="$(_liveness_parked)"
    if [ -z "$parked" ]; then
        echo "  (停滞なし)"
    else
        printf '%s\n' "$parked" | while IFS=$'\t' read -r id label age scope; do
            [ -n "$id" ] || continue
            if [ "$age" = "?" ]; then
                printf '  %s\t%s\t停滞 age不明%s\n' "$id" "$label" "${scope:+ [$scope]}"
            else
                printf '  %s\t%s\t停滞 %sm%s\n' "$id" "$label" "$age" "${scope:+ [$scope]}"
            fi
        done
    fi

    # ── ③ window 生存 × bead 無更新/不在（wt-<id> worker cell の self bead 突合）──────────────────
    #   admin window（素 admin / admin-<project>・session:window 正準形 `<project>:admin`）は held bead を window 名から
    #   導けない＝②の foreign parked と併読する（cross-ref）。③ は wt-<id> worker cell のみ self bead 突合する。
    echo "⚠ window 生存 × bead 無更新/不在（${LIVENESS_STALE_MIN} 分以上）:"
    local any_wb=0
    if [ -n "$wins" ]; then
        local w wn id raw rc st nu_flag gp_flag upd age
        while IFS= read -r w; do
            wn="${w##*:}"                                  # window_name（session prefix を剥がす・topology :admin 対応・teeth (b)）
            case "$wn" in wt-*) : ;; *) continue ;; esac   # worker cell のみ self bead 突合（admin は②の parked と併読）
            id="${wn#wt-}"
            [ -n "$id" ] || continue
            raw="$(_liveness_self_status "$id")"; rc=$?
            if [ "$rc" -ne 0 ]; then
                printf '  %s → bead %s 不在（宣言 bead 未作成? window 生存＝要確認）\n' "$w" "$id"; any_wb=1; continue
            fi
            # orch-o0b lockstep: _STATUS_PY は 4 列（status/needs-user/gate-pending/updated_at）を返す。read 変数を
            # 4 個に揃え updated_at を最終変数 upd へ正しく落とす（liveness は gp_flag/nu_flag を使わないが placeholder で受ける）。
            IFS=$'\t' read -r st nu_flag gp_flag upd <<< "$raw"
            # 終端（closed/blocked）は gate/cleanup 待ちの別軸ゆえ stall 扱いしない（open/in_progress のみ対象）。
            case "$st" in closed|blocked) continue ;; esac
            age="$(_age_min_of "$upd")"
            if [ "$age" = "?" ]; then
                printf '  %s → bead %s(%s) 更新時刻不明（window 生存・stall 判定不能＝要確認）\n' "$w" "$id" "$st"; any_wb=1
            elif [ "$age" -ge "$LIVENESS_STALE_MIN" ]; then
                # orch-gv9 SPAWNED marker smoke（既定 off・SPAWN_SMOKE=1 で on）: stale cell の marker 有無で
                #   『宣言 write 断絶疑い（sandbox sever）』と『write 経路は生存の別要因 stall』を弁別する注記を付す。
                #   時間 gate は本 stale 枝（age≥閾値）＝fresh cell では marker check を掛けない（誤検出回避・design(2)）。
                #   off 時 mk_note="" ＝出力は従来 byte 同一（回帰ゼロ）。判定不能（bd read 失敗）は sever 断定せず fail-safe 注記。
                local mk_note=""
                if [ "$SPAWN_SMOKE" = "1" ]; then
                    local mrc; _spawned_marker_present "$id"; mrc=$?
                    case "$mrc" in
                        1) mk_note='・⚠ SPAWNED marker 不在＝宣言 write 断絶疑い（sandbox sever 等による宣言 write 断絶・external repo cell / self-dev worker cell 双方に起こりうる・orch-b10/orch-gv9・要確認）' ;;
                        0) mk_note='（SPAWNED marker 有＝宣言 write 経路は生存・別要因の停滞）' ;;
                        *) mk_note='・SPAWNED marker 判定不能（bd read 失敗＝sever 断定せず・要確認）' ;;
                    esac
                fi
                printf '  %s → bead %s(%s) 無更新 %sm（window 生存だが停滞＝silent stall 疑い）%s\n' "$w" "$id" "$st" "$age" "$mk_note"; any_wb=1
            fi
        done <<< "$wins"
    fi
    [ "$any_wb" -eq 0 ] && echo "  (該当なし)"

    # ── ④ host-progress 停滞（長 running build 生存 × fs 書込停止＝silent hang・orch-ayj）─────────────
    #   ①②が bead updated_at 基点で盲目な silent hang（背景 build の network stall 等）を fs 書込停止で埋める
    #   第3軸（incident orch-1kk cm task2・1h22m）。read-only（pgrep/ps/find）。build 不在なら find コストを払わない。
    echo "⚠ host-progress（長 running build 生存 × fs 書込 ${LIVENESS_STALE_MIN} 分ゼロ）:"
    if ! command -v "$PGREP_BIN" >/dev/null 2>&1 || ! command -v "$FIND_BIN" >/dev/null 2>&1; then
        # probe 不能を『停滞なし』と偽 clean にしない（silent hang backstop ゆえ fail-loud・②の bd 失敗と同型）。
        echo "orch-dispatch: warn: pgrep/find が見つからず host-progress probe を実行不能（silent hang 検知は無効・『問題なし』を信用するな・PATH/ORCH_DISPATCH_PGREP/_FIND を確認せよ）。" >&2
        echo "  (probe 実行不能＝pgrep/find 不在・要確認)"
    else
        local hp_pids hp_rc hp_long hp_n
        hp_pids="$(_hostprog_pids)"; hp_rc=$?
        if [ "$hp_rc" -ge 2 ]; then
            # pgrep 異常終了（rc≥2＝pattern 構文エラー/致命エラー）を『マッチなし』と同一視しない（fail-loud・
            #   binary 不在 guard と同型に『信用するな』へ合流＝不正 ERE override 等で silent hang 検知が黙って
            #   無効化される false-clean を塞ぐ）。rc==1（マッチなし）は下の [ -z ] へ落として通常の probe 対象外に。
            echo "orch-dispatch: warn: pgrep が異常終了（rc=$hp_rc・ORCH_DISPATCH_HOSTPROG_PATTERN の ERE 構文エラー等）。host-progress probe が機能せず silent hang 検知は無効（『問題なし』を信用するな・pattern を確認せよ）。" >&2
            echo "  (probe 実行不能＝pgrep 異常終了 rc=$hp_rc・要確認)"
        elif [ -z "$hp_pids" ]; then
            echo "  (build プロセスなし＝probe 対象外)"
        else
            hp_long="$(_hostprog_longrunning "$hp_pids")"
            if [ -z "$hp_long" ]; then
                echo "  (build プロセス生存するが全て ${LIVENESS_STALE_MIN} 分未満＝長 running なし・stall 判定対象外)"
            elif _hostprog_has_recent_write; then
                hp_n=$(printf '%s\n' "$hp_long" | grep -c .)
                echo "  build プロセス生存（長 running ${hp_n}）だが監視 fs は書込継続＝正常 build（silent hang なし）"
            else
                hp_n=$(printf '%s\n' "$hp_long" | grep -c .)
                printf '  ⚠ build プロセス生存（長 running %s: pid %s）が監視 fs へ %s 分書込ゼロ＝silent hang 疑い（監視: %s）\n' \
                    "$hp_n" "$(printf '%s' "$hp_long" | tr '\n' ' ' | sed 's/ *$//')" "$LIVENESS_STALE_MIN" "$HOSTPROG_PATHS"
            fi
        fi
    fi
    return 0
}

# ── spawn 入口 gate（orch-vji・orch-c8p B / G1+G7 check + G2 snapshot）の契約 bead 検査 python ─────────
#   argv: <bd-id> <mode>（mode=check|snapshot）。stdin = `bd -C <anchor> show <id> --json`（list[obj] or obj）。
#   - mode=check   : 1 行 verdict を stdout へ（ok / no_acceptance / no_verification / parse_fail）。
#       acceptance = `acceptance_criteria` フィールドが非空白なら present（G1）。
#       verification = free-text（description/design/notes/acceptance_criteria）に検証手段の宣言があれば present（G7）:
#         ① `verification:` / `検証:`（大小無視・全角/半角コロン）行に非空 value がある、または
#         ② `機械 probe 不能`（空白揺れ許容）の明示宣言がある。どちらかで present（value は selfTestCmd か probe 不能宣言）。
#   - mode=snapshot: tamper-evident な acceptance snapshot ブロックを stdout へ組む（G2）。
#       hash = **JSON-decoded acceptance_criteria 文字列の UTF-8 sha256**（gate 側 orch-tdj が同一手順で再計算し照合する
#       canonical 定義）。sentinel `[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1]` + `sha256=<hex>` + verbatim acceptance。
_SPAWN_PY='
import sys, json, hashlib, re
bd_id = sys.argv[1] if len(sys.argv) > 1 else ""
mode = sys.argv[2] if len(sys.argv) > 2 else "check"
try:
    data = json.load(sys.stdin)
except Exception:
    print("parse_fail"); sys.exit(0)
if isinstance(data, list):
    data = data[0] if data else {}
if not isinstance(data, dict):
    print("parse_fail"); sys.exit(0)
def _s(v):
    return v if isinstance(v, str) else ""
acc = _s(data.get("acceptance_criteria"))
blob = "\n".join([_s(data.get("description")), _s(data.get("design")), _s(data.get("notes")), acc])
acc_present = bool(acc.strip())
verif_present = bool(re.search(r"機械\s*probe\s*不能", blob))
if not verif_present:
    for line in blob.splitlines():
        m = re.match(r"\s*(?:verification|検証)\s*[:：]\s*(\S.*)$", line, re.IGNORECASE)
        if m and m.group(1).strip():
            verif_present = True
            break
if mode == "check":
    if not acc_present:
        print("no_acceptance")
    elif not verif_present:
        print("no_verification")
    else:
        print("ok")
    sys.exit(0)
# mode == snapshot
h = hashlib.sha256(acc.encode("utf-8")).hexdigest()
sys.stdout.write("[ORCH-DISPATCH-ACCEPTANCE-SNAPSHOT v1] bd=%s sha256=%s\n" % (bd_id, h))
sys.stdout.write("--- acceptance (verbatim) ---\n")
sys.stdout.write(acc)
if not acc.endswith("\n"):
    sys.stdout.write("\n")
sys.stdout.write("--- end acceptance ---\n")
'

# acceptance snapshot（G2）を自台帳 bead notes へ append（bdw 経由＝自台帳 write 直列化の正路・un-8p7）。
#   $1 = 契約 bead の `bd show --json`。snapshot ブロック本文（sentinel + sha256 + verbatim acceptance）は
#   _SPAWN_PY snapshot mode が組む（hash は JSON-decoded acceptance_criteria の sha256＝gate 側と同一手順）。
#   bd 台帳解決を anchor に固定するため cwd=ANCHOR の subshell で bdw を叩く（自台帳 orch へ append）。
#   本文の空/生成失敗（python3 不在等）と bdw 失敗はいずれも非0 を返す（呼び元が fail-closed で dispatch を中止する）。
_record_acceptance_snapshot() {
    local cjson="$1" block
    block="$(printf '%s' "$cjson" | python3 -c "$_SPAWN_PY" "$BD_ID" snapshot 2>/dev/null)" || return 1
    [ -n "$block" ] || return 1
    ( cd "$ANCHOR" && "$BDW" update "$BD_ID" --append-notes "$block" ) >/dev/null 2>&1
}

# external repo cell（orch-b10）: `--repo` が anchor≠repo（外部 project worktree host）の dispatch。
#   その cell の終端宣言 write（gate-pending ラベル / bead-append）は worker sandbox で silent に断たれうる
#   （scribe gen-sandbox-settings の anchor≠repo allowWrite bug・incident orch-7ti）。監視で担保するため repo root を
#   registry へ記録し（dry-run は skip＝EXEC 時に記録）、LOUD 警告を出す（acceptance 2「再発時 silent でなく loud」）。
#   registry write は監視の補助ゆえ失敗しても dispatch は止めない（fail-open＝spawn は進める）が、失敗を⚠ で surface。
#   ★ledger 非依存（file registry ゆえ bd write でない）＝bead が foreign でも repo 単位で登録できる（write-isolation を侵さない）。
_handle_external_repo_cell() {
    local reg_note
    if [ "$DRY_RUN" -eq 1 ]; then
        reg_note="skip（dry-run＝副作用ゼロ・EXEC 時に記録）"
    elif _register_external_repo "$REPO"; then
        reg_note="recorded → $EXTERNAL_REGISTRY"
    else
        reg_note="⚠ 記録失敗（registry write 不可）＝監視が auto-cover しない・手動 watch 必須"
    fi
    {
        echo "⚠ [ORCH-EXTERNAL-REPO] external repo cell（repo=$REPO ≠ anchor=$SCRIPTORIUM・orch-b10）"
        echo "  終端宣言 write（gate-pending ラベル / bead-append）は worker sandbox で silent に断たれうる"
        echo "  （scribe gen-sandbox-settings の anchor≠repo allowWrite bug・courier notice で別途報告）。"
        echo "  → 監視で担保: gate-pending / degraded-watch が $REPO/.worktrees/spawn を走査（registry: $reg_note）。"
        echo "  → 宣言 label 単独に依存せず未 merge worktree scan で完了検知せよ（acceptance 1・hands-free ループを閉じる）。"
    } >&2
}

# ─────────────────────────────────────────────────────────────────────────────
# (1) spawn: orchestrator 既定を埋め込み scribe-spawn.sh を呼ぶ（投げる導線の流用）
#     ★scribe-spawn へ投げる前に入口 fail-closed gate（G1 acceptance / G7 verification / G2 snapshot・orch-vji）を掛ける。
run_spawn() {
    [ -n "$BD_ID" ] || die "spawn には bd-id が必要です（usage は --help）"
    # scribe-spawn は worker fable を die する。orch-dispatch でも先に弾いて意図を明確化（${MODEL,,} で大小無視）。
    case "${MODEL,,}" in
        *fable*) die "--model に fable 系は使えません（worker は opus 必須＝コスト事故回避）" ;;
    esac

    # 実行モードでは scribe-spawn 実体が要る（dry-run でも scribe-spawn が plan を arg-echo するので実体が要る）。
    if [ ! -x "$SPAWN" ]; then
        die "scribe-spawn が見つからない/実行不可: '${SPAWN:-（未供給）}'（env ORCH_DISPATCH_SPAWN で private 配備層が供給する＝engine は既定 path を持たない）"
    fi

    # ── 入口 fail-closed gate（orch-vji・orch-c8p B / grill G1+G2+G7 入口）────────────────────────────
    # 契約 bead を anchor 台帳から read（read-only）し G1/G7 を検査する。read 不能（bd 失敗/not-found）は
    # 「契約検証不能」＝dispatch 中止（fail-closed・従来 scribe-spawn 委譲の実在検証もこの read が兼ねる）。
    local cjson crc verdict
    cjson="$("$BD" -C "$ANCHOR" show "$BD_ID" --json 2>/dev/null)"; crc=$?
    if [ "$crc" -ne 0 ]; then
        die "契約 bead '$BD_ID' を read できません（bd -C '$ANCHOR' show rc=$crc）＝acceptance/verification を検証できないため dispatch 中止（fail-closed・bd-id 実在/anchor を確認せよ）"
    fi
    verdict="$(printf '%s' "$cjson" | python3 -c "$_SPAWN_PY" "$BD_ID" check 2>/dev/null)"
    case "$verdict" in
        ok) : ;;
        no_acceptance)
            die "契約 bead '$BD_ID' に acceptance が無い＝gate 裁量判定になり auto-merge 検知基準（トリガー①）が消えるため dispatch を拒否（fail-closed・G1）。bd の acceptance_criteria を埋めてから再 dispatch せよ。" ;;
        no_verification)
            die "契約 bead '$BD_ID' に verification 欄が無い＝gate が selfTestCmd を再実行できないため dispatch を拒否（fail-closed・G7）。bead の free-text に \`verification: <selfTestCmd | 機械 probe 不能>\`（または \`検証:\`）を宣言してから再 dispatch せよ。" ;;
        parse_fail)
            die "契約 bead '$BD_ID' の JSON 解析に失敗（python3 不在/非JSON?）＝契約検証不能で dispatch 中止（fail-closed）。" ;;
        *)
            die "契約 bead '$BD_ID' の入口 gate 判定に失敗（verdict='$verdict'）＝fail-closed で dispatch 中止。" ;;
    esac

    # ── slate interlock（bd orch-vswk・orch-6srt 裁定-safeguards(3)・fail-closed）────────────────────────
    # 計画 slate（open orch- slate bead の members 和集合）に dispatch 対象 bd-id が属さなければ dispatch を拒否する。
    # slate は merge-ratify ① baseline（事前合意逸脱検知の基準線）を兼ねる（orch-6srt）＝auto-merge が最も効く
    # self-dev track こそ baseline 必須。ゆえに interlock 発火 scope は self-dev を含む **全 spawn 経路**（foreign-only
    # exempt 分岐は「cross-project こそ抜ける」footgun を生むため作らない・gate-1 裁定 orchestrator 2026-07-16）。
    # ★配置: G1/G7 read-only gate と同層で、下の G2 snapshot（自台帳 write）**より前**＝slate-less は self-ledger
    #   write の前に副作用ゼロで弾く。read-only 参照のみ（bd list/show）で auto-record しない（記録は別 turn）。
    # ★dry-run も read-only 照合を掛ける（「dry-run では slate skip」の逆解釈は封じる・orch-vswk）。
    # ★hermetic bypass seam ORCH_DISPATCH_SKIP_SLATE_GATE=1（bats 回帰維持用・既定 0=gate 有効）。production 既定は
    #   gate 有効ゆえ warn-only 化でない（後方互換を口実にした interlock 緩和は禁止・fail-closed）。
    if [ "${ORCH_DISPATCH_SKIP_SLATE_GATE:-0}" != 1 ]; then
        local _slate_members _slate_rc
        _slate_members="$(_orch_slate_open_members "$BD" "$ANCHOR")"; _slate_rc=$?
        if [ "$_slate_rc" -ne 0 ]; then
            die "計画 slate を read できません（bd list/show 失敗・rc=$_slate_rc）＝slate 検証不能で dispatch 中止（fail-closed・orch-vswk）。自台帳 orch を確認せよ。"
        fi
        if [ -z "$_slate_members" ]; then
            die "open な計画 slate（label '$ORCH_SLATE_LABEL' + 行頭 sentinel '$ORCH_SLATE_SENTINEL'）が無い/members 未列挙＝計画外 dispatch を拒否（fail-closed・orch-vswk）。bundle 頭で slate を記録（対象 bead を members に列挙）してから再 dispatch せよ。"
        fi
        if ! printf '%s\n' "$_slate_members" | grep -qxF -- "$BD_ID"; then
            die "'$BD_ID' が open slate の members 集合に属さない＝計画外 dispatch を拒否（fail-closed・orch-vswk・空虚 interlock でなく集合照合）。slate の members に '$BD_ID' を列挙してから再 dispatch せよ。"
        fi
    fi

    # ── G2 snapshot: dispatch 時に acceptance snapshot を bead notes へ機械記録（tamper-evident）──────
    # write は自台帳（${SELF_PREFIX}-）bead のみ（write-isolation の不可侵の核・foreign は foreign admin の責務ゆえ skip）。
    # dry-run は副作用ゼロ＝write skip（上の read-only check は掛け済）。snapshot 失敗（bdw/python3）は fail-closed で中止
    # （tamper-evidence 欠落のまま dispatch すると gate が照合できず G2 が無効化されるため）。
    local snap_action
    if [ "$DRY_RUN" -eq 1 ]; then
        snap_action="skip（dry-run＝副作用ゼロ・G1/G7 check は実施済）"
    elif [[ "$BD_ID" == "${SELF_PREFIX}-"* ]]; then
        _record_acceptance_snapshot "$cjson" \
            || die "acceptance snapshot を notes へ記録できません（bdw/python3 失敗）＝tamper-evidence 欠落ゆえ dispatch 中止（fail-closed・G2）。bdw/自台帳を確認せよ。"
        snap_action="recorded（self-dev ${SELF_PREFIX}-・bdw 経由で notes へ append）"
    else
        snap_action="skip（foreign 台帳＝foreign admin が自台帳へ記録する責務・write-isolation）"
    fi

    # ── external repo cell（orch-b10）: 監視 scan 登録 + loud 警告（宣言 write の sandbox 盲点への対処）──────
    #   `--repo` が anchor≠repo のときのみ発火（自己開発 cell〔REPO==SCRIPTORIUM〕は従来どおり無警告）。
    #   orch-b10 E2: 発火判定は realpath 正規化比較で行う。生文字列比較だと read 側（_register/_external_scan_roots は
    #   readlink -f 正規化）と非対称で、self を末尾スラッシュ/symlink 綴りで --repo 指定すると false 警告 + registry
    #   への self 誤登録が起きる。両辺を canon 化して比較し綴り差を吸収する（自己開発 cell を external 誤判定しない）。
    local _repo_canon _self_canon
    _repo_canon="$(readlink -f "$REPO" 2>/dev/null || printf '%s' "$REPO")"
    _self_canon="$(readlink -f "$SCRIPTORIUM" 2>/dev/null || printf '%s' "$SCRIPTORIUM")"
    [ "$_repo_canon" != "$_self_canon" ] && _handle_external_repo_cell

    # 対話 tool 封鎖: 本 script は --disallowed-tools を forward しない（orch-ce6 errata）。worker cell の封鎖は
    # scribe-spawn が hardcode（WORKER_DISALLOWED_TOOLS・scribe-spawn.sh:73/:570）で cld-spawn 起動行へ無条件付与
    # する＝orch-dispatch は scribe-spawn を呼ぶだけで自動的に効く。ここで --disallowed-tools を渡すと scribe-spawn
    # は未知オプションで die し spawn を壊すため、渡してはならない。
    local cmd=("$SPAWN" --anchor "$ANCHOR" --repo "$REPO" --base "$BASE" --model "$MODEL")
    [ "$DRY_RUN" -eq 1 ] && cmd+=(--dry-run)
    cmd+=("$BD_ID")

    local mode_label; mode_label="$([ "$DRY_RUN" -eq 1 ] && echo 'DRY-RUN' || echo 'EXEC')"
    {
        echo "== orch-dispatch spawn ($mode_label) =="
        echo "  bd-id   : $BD_ID"
        echo "  anchor  : $ANCHOR   (bd graph 所在)"
        echo "  repo    : $REPO   (worktree host・既定=自己開発)"
        echo "  base    : $BASE"
        echo "  model   : $MODEL"
        echo "  spawn   : $SPAWN"
        echo "  gate    : acceptance/verification 入口 check=pass（G1+G7・fail-closed）"
        echo "  snapshot: $snap_action（G2 tamper-evident・gate が現 acceptance と sha256 照合）"
        echo "  block   : worker 対話 tool 封鎖は scribe-spawn hardcode（orch-4dm）が担う＝orch-dispatch は forward しない"
        echo "  note    : bd-id 実在検証は上の contract read（bd -C anchor show）が兼ねる"
        echo "----------------------------------------------------------------------"
    } >&2

    _emit_watch_hint_spawn

    exec "${cmd[@]}"
}

# spawn 直後 watch 常駐ヒント（orch-z7g H3-ii / orch-ce6）: self-dev worker は終端宣言 bead-id が spawn 時点で
#   既知（= $BD_ID）ゆえ、ちょうど background 常駐すべき watch コマンドを完全形で stderr に emit する。
#   ★orchestrator が **自分の harness（run_in_background）で** 常駐する＝harness 追跡下（完了で orchestrator を
#   自動再突入）。本 script から nohup/setsid で fork しない: 追跡外の孤児 watch は orch-mot の監視規律（pane は
#   truth でない・turn 境界 idle ≠ 完了）と衝突する。sentinel [ORCH-WATCH-RESIDENT] で grep 可能。
_emit_watch_hint_spawn() {
    [ "$WATCH_HINT" -eq 1 ] || return 0
    local self; self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    {
        echo "[ORCH-WATCH-RESIDENT] spawn 直後 watch 常駐（orch-ce6・self-dev worker は bd-id 既知ゆえ即 background 常駐せよ）:"
        echo "  $self --watch $BD_ID"
        echo "  ↑ orchestrator が自分の run_in_background（harness 追跡）で常駐する。孤児 fork しない（orch-mot 監視規律）。"
    } >&2
}

case "$MODE" in
    gatepending) run_gate_pending ;;
    watch)       run_watch ;;
    liveness)    run_liveness ;;
    spawn)       run_spawn ;;
    *)           die "内部エラー: 未知のモード '$MODE'" ;;
esac

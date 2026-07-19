#!/usr/bin/env bash
# orch-relay.sh — orchestrator→既存 window への push relay primitive（bd orch-z7g H2 / orch-ce6）
#
# 役割 ──────────────────────────────────────────────────────────────────────────
#   spawn した admin / worker が human 承認を要する判断（固い merge 確認等）に突き当たり **NEEDS-USER で park し turn を終えた**
#   とき、orchestrator（human 承認〔standing go〕に基づき決定を下し中継する側）が その決定を **停止した既存 window へ push**
#   して再開させるための
#   薄い wrapper。ORCH-WATCH-CONTRACT ブリーフが約束する「orchestrator が bead 直読 poll で NEEDS-USER を検知し、
#   この window へ **メッセージ（push relay）で再開指示** する＝それを待て」の push 側実体（orch-z7g H2=push）。
#
# なぜ push なのか（pull でない）─────────────────────────────────────────────────
#   監視（admin→orch）は pull のまま（orch-dispatch --watch の bead 直読 poll）。だが **再開（orch→admin）は
#   構造的に push** でなければならない: 停止した対話 session は自分では何も実行しておらず poll できない（sentinel-
#   pull は停止 session が監視不能ゆえ却下・orch-z7g H2=(a)）。よって既存 window へ受理確認付きで注入する。
#
# 実体は cld-spawn --inject-existing の再利用（新規発明しない）───────────────────────
#   送達は cld-spawn の --inject-existing（inject-file + read-back 受理確認・orch-6sd 着地）に委譲する。これは
#   welcome race で初回 paste が drop しても read-back が未着を検出し settle 後に再送する有界リトライ送達で、
#   tmux 層成功だけでは成功扱いにしない（claude の受理を read-back で確認）＝偽 "injected" を出さない。本 script
#   は送達コードを一切持たず、envelope を組んで cld-spawn を呼ぶだけ（scribe-spawn / cld-spawn を作り直さない）。
#
# write-isolation を侵さない ──────────────────────────────────────────────────────
#   これは **window へのメッセージ注入**であって foreign 台帳への bead write ではない。orchestrator は foreign
#   台帳を read-only に保ったまま（bead は直読 poll・window へは push）＝write-isolation（自台帳 orch- のみ write）
#   の不変条件を破らない。relay されるのは「human 承認済みの orchestrator 決定（human 本人発ではない）」で、admin がそれを受けて自分の foreign 台帳を
#   更新する（admin が自台帳を write する＝正当）。
#
# envelope（既定・--raw で無効化）──────────────────────────────────────────────────
#   既定では message を [ORCH-RELAY] sentinel envelope で包む: 受け手（ORCH-WATCH-CONTRACT で「push relay を待て」
#   と指示された actor）が「これは orchestrator からの push relay＝再開指示」と認識でき、self-test も grep で検証
#   できる。verbatim に送りたいときは --raw。
#
# 使い方:
#   orch-relay.sh <window> -- <message...>
#   orch-relay.sh --window <window> -- <message...>
#     <window>          注入先の tmux window。必須。admin の宛先正準形は **session:window** 形式 `<project>:admin`
#                       （orch-riz1 topology 裁定 orch-thgx＝window 名は素 'admin'・session 名=project 名が識別を担う）。
#                       worker cell は `wt-<id>`（同一 session 内で一意）。bare 名（`admin` 等）が複数 session に一致すると
#                       cld-spawn が fail-loud する（session:window で明示せよ）＝本 script は $WINDOW を verbatim
#                       passthrough し window 解決コードを持たない（曖昧解決/fail-loud は cld-spawn の責務・cld-spawn:121/:270-272）。
#     -- <message...>   `--` 以降を relay message として連結（human 承認済み orchestrator 決定の再開指示本文）。必須。
#     --window W        window を明示（位置引数の代わり）。
#     --raw             envelope を付けず message を verbatim 注入する。
#     --dry-run         cld-spawn を呼ばず実行予定コマンドを print するのみ（何も注入しない）。
#     --no-watch-hint   （互換 no-op・relay は watch 常駐ヒントを出さない）。
#     -h, --help        この usage。
#
# env override（主に self-test 用）:
#   ORCH_RELAY_CLD    cld-spawn 実体パス（既定: ORCH_SPAWN_CLD → ~/.claude/plugins/session/scripts/cld-spawn）。
#
# 検証: tests/scenarios/orch-relay.bats（cld-spawn を stub 差替・envelope/raw・window/message 必須・dry-run 副作用
#   ゼロ・cld-spawn 失敗の非0 伝播を assert する hermetic E2E）+ selftest-orch-ce6.local.sh。

set -uo pipefail

# cld-spawn 実体（env で差し替え可・self-test 用）。ORCH_RELAY_CLD 優先・次に ORCH_SPAWN_CLD（orch-spawn-admin と
# 同じ seam 名）・既定は session plugin の cld-spawn。
CLD_SPAWN="${ORCH_RELAY_CLD:-${ORCH_SPAWN_CLD:-$HOME/.claude/plugins/session/scripts/cld-spawn}}"

WINDOW=""
DRY_RUN=false
RAW=false
MSG_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --raw) RAW=true; shift ;;
        --no-watch-hint) shift ;;   # 互換 no-op（relay は watch 常駐ヒントを持たない）
        --window)
            if [ -z "${2:-}" ] || [ "${2#-}" != "$2" ]; then
                echo "orch-relay: --window に値を指定してください" >&2
                exit 2
            fi
            WINDOW="$2"; shift 2 ;;
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
            exit 0
            ;;
        --)
            shift
            MSG_ARGS=("$@")
            break
            ;;
        -*)
            echo "orch-relay: unknown option: $1" >&2
            echo "  usage: orch-relay <window> -- <message...>（詳細は --help）" >&2
            exit 2
            ;;
        *)
            if [ -z "$WINDOW" ]; then
                WINDOW="$1"; shift
            else
                # window は 1 つ・message は `--` 以降で渡す（曖昧回避の fail-loud）。
                echo "orch-relay: 余分な引数: '$1'（window は 1 つ・message は '--' 以降で渡す）" >&2
                echo "  usage: orch-relay <window> -- <message...>（詳細は --help）" >&2
                exit 2
            fi
            ;;
    esac
done

# window 必須。
if [ -z "$WINDOW" ]; then
    echo "orch-relay: window を指定してください" >&2
    echo "  usage: orch-relay <window> -- <message...>（詳細は --help）" >&2
    exit 2
fi

# message 必須（cld-spawn --inject-existing も PROMPT 必須だが上流で明快に弾く）。
if [ "${#MSG_ARGS[@]}" -eq 0 ]; then
    echo "orch-relay: relay する message を '--' 以降で指定してください（注入内容が空）" >&2
    echo "  usage: orch-relay <window> -- <message...>（詳細は --help）" >&2
    exit 2
fi

RAW_MESSAGE="${MSG_ARGS[*]}"

# ★空/空白のみ body の fail-loud（orch-ce6 errata 4b）: token は在るが内容が空（例 `-- ""` / `-- "   "`）だと、
#   既定 envelope 経路は内容なし [ORCH-RELAY] を exit0 で注入してしまう（--raw は cld-spawn が空 PROMPT で exit1
#   ＝fail-loud する非対称）。空白を全除去して空なら die し、両経路を対称に fail-closed 化する（無意味な relay を
#   window へ push しない）。
if [ -z "${RAW_MESSAGE//[[:space:]]/}" ]; then
    echo "orch-relay: relay する message が空/空白のみです（注入内容が無い）" >&2
    echo "  usage: orch-relay <window> -- <message...>（詳細は --help）" >&2
    exit 2
fi

# envelope 組み立て（既定）: 受け手が「orchestrator からの push relay＝再開指示」と認識できる sentinel を前置。
# --raw なら verbatim。
if [ "$RAW" = true ]; then
    MESSAGE="$RAW_MESSAGE"
else
    MESSAGE="[ORCH-RELAY] orchestrator からの push relay（human 承認済み orchestrator 決定の中継・human 本人発の指示ではない・承認記録は bead notes）— この決定を反映して作業を再開せよ:"$'\n'"$RAW_MESSAGE"
fi

# cld-spawn --inject-existing コマンド構築（送達は cld-spawn に委譲・inject-file + read-back 受理確認）。
CMD=("$CLD_SPAWN" --inject-existing "$WINDOW" -- "$MESSAGE")

mode_label="$([ "$DRY_RUN" = true ] && echo 'DRY-RUN' || echo 'EXEC')"
{
    echo "== orch-relay ($mode_label) =="
    echo "  window  : $WINDOW"
    echo "  envelope: $([ "$RAW" = true ] && echo 'raw（verbatim）' || echo '[ORCH-RELAY] sentinel 付き')"
    echo "  deliver : cld-spawn --inject-existing（inject-file + read-back 受理確認・偽 injected を出さない）"
    echo "----------------------------------------------------------------------"
} >&2

if [ "$DRY_RUN" = true ]; then
    printf 'DRY-RUN: would execute:'
    printf ' %q' "${CMD[@]}"
    printf '\n'
    exit 0
fi

# 実行モード: cld-spawn 実体が要る。
if [ ! -x "$CLD_SPAWN" ]; then
    echo "orch-relay: cld-spawn not found/executable: $CLD_SPAWN" >&2
    echo "  ORCH_RELAY_CLD / ORCH_SPAWN_CLD で実体パスを差し替え可。" >&2
    exit 1
fi

# cld-spawn の exit code を **そのまま伝播** する（read-back 未確認＝真に未着なら非0＝relay 失敗を fail-loud）。
exec "${CMD[@]}"

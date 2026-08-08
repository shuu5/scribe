#!/usr/bin/env bats
# protocol-pins.bats — docs/protocol.md の再編保護 pin（bd sc-aprn R3）
#
# 守るもの（literal pin・grep -F 形）:
#   (1) sc-0mas 追記 3 行（§4 blocking[] 規律 / §4 go-live 空変更集合 / §5 step3→§4 ポインタ）
#       —— sc-0mas gate（wf_d0e3c766）が「守る teeth 0 本」と指摘した非空虚性の要。
#   (2) sc-aprn (ii) 再編で追加した行（trigger 表 正常系 3 行・不変条件 2 行・§1 preflight・
#       §6 正規経路小節・R1 wire・R2 locator・§9 D5 裁定・§2/spec §2.2 D7 追随注記）。
#
# 書式規約: pin は grep -qF -- 形（固定文字列・ugrep ラッパー環境差の回避）・パイプ終端 head -1 禁止・
# count は herestring（pipefail 下 SIGPIPE 偽 RED 回避・protocol §2）。§5.4 承認体制の pin は
# approval-codify.bats の責務（本 file へ足さない）。変異対照は $BATS_TEST_TMPDIR 上の mutant copy
# に対して行い、本物の docs と git 履歴を汚さない（approval-codify.bats と同形）。

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    PROTOCOL="$REPO/docs/protocol.md"
    SPEC="$REPO/docs/role-context-spec.md"
}

@test "前提: docs が実在する" {
    [ -f "$PROTOCOL" ]
    [ -f "$SPEC" ]
}

# ---------- (1) sc-0mas 追記 3 行 ----------

@test "sc-0mas: §4 blocking[] 規律 bullet が実在する（autoFix 前 round・額面差し戻し禁止）" {
    grep -qF -- 'findings の差し戻しは autoFix 後の HEAD で再確認してから' "$PROTOCOL"
    grep -qF -- '`blocking[]` は **autoFix が走る前の round の findings** を保持する' "$PROTOCOL"
}

@test "sc-0mas: §4 go-live 空変更集合 bullet が実在する" {
    grep -qF -- 'go-live 検証は merge 前に「変更集合が空」の文脈でも回す' "$PROTOCOL"
    grep -qF -- 'merge 後 main 相当＝変更集合が空' "$PROTOCOL"
}

@test "sc-0mas: §5 step3 の →§4 ポインタ文が実在する（非空虚性の要）" {
    grep -qF -- '`blocking[]` を額面で読まず autoFix 後の HEAD の実体で再確認する' "$PROTOCOL"
}

# ---------- (2) sc-aprn (ii) 追加行 ----------

@test "core: 正常系 trigger 3 行（監視 §6 / WF 返り値 §4 / relay §8）が admin core 区間内に実在する" {
    # 区間抽出は sed（role-inject と同経路・awk 非依存）。count は herestring で取る。
    local core
    core="$(sed -n '/<!-- scribe-core-admin:begin -->/,/<!-- scribe-core-admin:end -->/p' "$PROTOCOL")"
    grep -qF -- 'spawn 後・worker を待つ間 → §6' <<< "$core"
    grep -qF -- 'WF 返り値を受けたら → §4' <<< "$core"
    grep -qF -- 'relay / courier 便を受けたら → §8' <<< "$core"
}

@test "core: 不変条件 2 行（WF 返り値 / spawn preflight）が admin core 区間内に実在する" {
    local core
    core="$(sed -n '/<!-- scribe-core-admin:begin -->/,/<!-- scribe-core-admin:end -->/p' "$PROTOCOL")"
    grep -qF -- 'machinery 健全性（agents_error / snapshotFailed / journal 直読）を先に判定' <<< "$core"
    grep -qF -- 'spawn 前に admin 自身の account を毎回実測する' <<< "$core"
}

@test "§1: admin account preflight 本文が実在する" {
    grep -qF -- 'admin 自身の account preflight（spawn 前・毎回・sc-aprn D2/S3）' "$PROTOCOL"
    grep -qF -- '`--account auto` は **admin account を除外しない**' "$PROTOCOL"
}

@test "§6: 監視の正規経路小節が実在する（Monitor + read-only poll・cycle 後の再武装）" {
    grep -qF -- '### worker 監視の正規経路（block-until-done・courier orch-cp8g）' "$PROTOCOL"
    # 中核 bullet は §6 新規行に一意な literal で掴む（『**Monitor の command** に渡す』は §7.1 既存行に
    # cross-satisfy される fail-open pin だった＝gate F2。base 0 hit / HEAD 1 hit を実測済み）
    grep -qF -- '待ち受けは harness の Monitor に read-only poll script を渡す' "$PROTOCOL"
    grep -qF -- '監視は context cycle で全消滅する' "$PROTOCOL"
}

@test "R1: §5 step6 の →§4 wire 枝 bullet が実在する" {
    grep -qF -- 'go-live の teeth は merge 前に「変更集合が空」の文脈でも回す**（§4 の同名 bullet に従う・sc-aprn R1 wire）' "$PROTOCOL"
}

@test "R2: run record locator が実在する（session-uuid 階層必須・完走時のみ生成）" {
    grep -qF -- '(補) WF run record の locator' "$PROTOCOL"
    grep -qF -- '<config-dir>/projects/<encoded cwd>/<session-uuid>/workflows/wf_<runId>.json' "$PROTOCOL"
    grep -qF -- '**完走時のみ生成**' "$PROTOCOL"
}

@test "D5: §9 の危険域転写点裁定（§0 core 行のみ・二重化しない）が実在する" {
    grep -qF -- '危険域の実測値（数値そのもの）の転写点は §0 admin core 行のみ（sc-aprn D5）' "$PROTOCOL"
    # 転写点の一意性を機械で守る: 数値 literal は §0 core 行の 1 箇所だけ（gate F1・count は file-arg grep）
    local n
    n="$(grep -c -- '240k' "$PROTOCOL" || true)"
    [ "$n" -eq 1 ]
}

@test "D7: §2 split-brain 行の追随注記と spec §2.2 の受領形注記が実在する" {
    grep -qF -- '〔追随注記・sc-aprn D7〕' "$PROTOCOL"
    grep -qF -- '受領形の追随注記（sc-aprn D7）' "$SPEC"
}

# ---------- 変異対照（pin の非空虚性を mutation で実測する） ----------

@test "mutation: §5 step3 ポインタ文を削ると sc-0mas pin が RED へ flip する" {
    local mut="$BATS_TEST_TMPDIR/step3-protocol.md"
    grep -vF -- '`blocking[]` を額面で読まず autoFix 後の HEAD の実体で再確認する' "$PROTOCOL" > "$mut"
    # clean で 1 hit 以上・mutant で 0 hit（pin が実際に行を掴んでいる）
    grep -qF -- '`blocking[]` を額面で読まず autoFix 後の HEAD の実体で再確認する' "$PROTOCOL"
    run grep -qF -- '`blocking[]` を額面で読まず autoFix 後の HEAD の実体で再確認する' "$mut"
    [ "$status" -ne 0 ]
}

@test "mutation: trigger 正常系 3 行を core 区間から削ると core pin が RED へ flip する" {
    local mut="$BATS_TEST_TMPDIR/trigger-protocol.md" core
    grep -vF -- 'WF 返り値を受けたら → §4' "$PROTOCOL" > "$mut"
    core="$(sed -n '/<!-- scribe-core-admin:begin -->/,/<!-- scribe-core-admin:end -->/p' "$mut")"
    run grep -qF -- 'WF 返り値を受けたら → §4' <<< "$core"
    [ "$status" -ne 0 ]
}

@test "mutation: §6 正規経路の中核 bullet を削ると D3 pin が RED へ flip する（gate F2 の再発防止）" {
    local mut="$BATS_TEST_TMPDIR/monitor-protocol.md"
    grep -vF -- '待ち受けは harness の Monitor に read-only poll script を渡す' "$PROTOCOL" > "$mut"
    grep -qF -- '待ち受けは harness の Monitor に read-only poll script を渡す' "$PROTOCOL"
    run grep -qF -- '待ち受けは harness の Monitor に read-only poll script を渡す' "$mut"
    [ "$status" -ne 0 ]
}

@test "mutation: R2 locator 行を削ると R2 pin が RED へ flip する" {
    local mut="$BATS_TEST_TMPDIR/locator-protocol.md"
    grep -vF -- 'wf_<runId>.json' "$PROTOCOL" > "$mut"
    run grep -qF -- '<config-dir>/projects/<encoded cwd>/<session-uuid>/workflows/wf_<runId>.json' "$mut"
    [ "$status" -ne 0 ]
}

# ---------- (3) sc-i2kc + sc-ugb8 codify 行（gate wf_a13b8143-b9a D1 裁定＝durable pin 化） ----------

@test "sc-i2kc: §5 step1 WF 起動主張の実在照合 probe 本体行が実在する" {
    grep -qF -- '両方不在 = 起動捏造' "$PROTOCOL"
    grep -qF -- 'WF 起動主張の実在照合' "$PROTOCOL"
}

@test "sc-i2kc: §6 stall watchdog 小節と発報条件が実在する" {
    grep -qF -- '### stall watchdog' "$PROTOCOL"
    grep -qF -- '約 20 分継続' "$PROTOCOL"
    grep -qF -- '張り方は §6「worker 監視の正規経路」に従う' "$PROTOCOL"
}

@test "sc-ugb8: §6 捏造応答→respawn 一択 playbook が実在する" {
    grep -qF -- '追い inject せず respawn 一択' "$PROTOCOL"
    grep -qF -- 'runId を突合してから' "$PROTOCOL"
}

@test "sc-i2kc: §5 step5 unresolved-hex 系統（序数呼称なし）が実在する" {
    grep -qF -- 'unresolved-hex 系統' "$PROTOCOL"
    # 序数呼称の再発を封じる（sc-pion ■4 裁定・「第 4 系統」が復活したら RED）
    run grep -qF -- '第 4 系統' "$PROTOCOL"
    [ "$status" -ne 0 ]
}

@test "mutation: §5 step1 probe 本体行を削ると sc-i2kc pin が RED へ flip する" {
    local mut="$BATS_TEST_TMPDIR/i2kc-protocol.md"
    grep -vF -- '両方不在 = 起動捏造' "$PROTOCOL" > "$mut"
    grep -qF -- '両方不在 = 起動捏造' "$PROTOCOL"
    run grep -qF -- '両方不在 = 起動捏造' "$mut"
    [ "$status" -ne 0 ]
}

# ---------- sc-5yfi（courier orch-rejt: 受け bead 規約 = delivered+acked 2 段の受信側） ----------

@test "sc-5yfi: §8 courier 受け bead 規約 bullet が §8 区間内に実在する（4 点 + open-bead 返信規律）" {
    # §8 区間抽出（一次出典 blockquote の同語 cross-satisfy を避けるため bullet 固有の long literal で pin）
    local sec
    sec="$(sed -n '/^## 8\./,/^## 9\./p' "$PROTOCOL")"
    grep -qF -- 'courier 受け bead 規約（delivered+acked 2 段の受信側・grill E 裁定・courier orch-rejt）' <<< "$sec"
    grep -qF -- 'delivered（mailbox 配送・上記配送点）+ acked（受け bead の実在）の 2 段' <<< "$sec"
    grep -qF -- '受信側の自台帳 ack（受け bead）は禁止対象外' <<< "$sec"
    grep -qF -- 'open-scan から**構造的に不可視' <<< "$sec"
    grep -qF -- 'open の epic / 集約 carrier bead へ再掲してから' <<< "$sec"
}

@test "sc-5yfi reach: admin core が受信会計 anchor 行と courier→§8 trigger を持つ（audience×unit 到達性・orch-wnt4 P0-1(B)）" {
    # reach assertion: 本 unit（§8 受け bead 規約）の audience = admin。到達経路 = boot core の
    # anchor 1 行（台帳境界 bullet 内）+ trigger 表の courier→§8 行 → 必要時 Read で §8 本文へ。
    # SessionStart 注入 cap（約 10k）下では §8 本文は届かない＝この 2 点が機械照合できないと codify は空証明。
    local core
    core="$(sed -n '/<!-- scribe-core-admin:begin -->/,/<!-- scribe-core-admin:end -->/p' "$PROTOCOL")"
    grep -qF -- '受け bead + 便 id 明記 + 初回整合返信' <<< "$core"
    grep -qF -- 'orch への返信は open bead に置く' <<< "$core"
    grep -qF -- 'relay / courier 便を受けたら → §8' <<< "$core"
}

@test "mutation: 受け bead 規約 bullet を削ると sc-5yfi pin が RED へ flip する（削除実効を確認してから読む）" {
    local mut="$BATS_TEST_TMPDIR/sc5yfi-protocol.md"
    grep -qF -- 'courier 受け bead 規約（delivered+acked 2 段の受信側・grill E 裁定・courier orch-rejt）' "$PROTOCOL"
    grep -vF -- 'courier 受け bead 規約（delivered+acked 2 段の受信側・grill E 裁定・courier orch-rejt）' "$PROTOCOL" > "$mut"
    [ "$(wc -l < "$mut")" -lt "$(wc -l < "$PROTOCOL")" ]
    local sec
    sec="$(sed -n '/^## 8\./,/^## 9\./p' "$mut")"
    run grep -qF -- 'courier 受け bead 規約（delivered+acked 2 段の受信側・grill E 裁定・courier orch-rejt）' <<< "$sec"
    [ "$status" -ne 0 ]
}

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# PreToolUse(Edit|Write|NotebookEdit|MultiEdit) hook: scribe worker の built-in ファイル編集ツールが
#   worktree の外へ書き込むのを exit 2 で強制ブロックし、LLM に差し戻す（sc-649）。
#
# 背景（2026-07-03 security-audit workflow・SBX-ESC-1・live 実証済み・doobidoo 86c47437）:
#   CC 組込み bwrap sandbox は worker の **Bash subprocess のみ**を封じる write 境界であり、built-in の
#   Edit/Write/NotebookEdit/MultiEdit は sandbox の外（CC 親プロセス側の permission 層）で動く。worker は
#   `claude --dangerously-skip-permissions`（bypassPermissions）で起動するため permission 層も素通しになり、
#   worker が Bash でなくファイル編集ツールを選ぶだけで allowWrite 外（~/.bashrc・~/.claude/plugins/*/hooks・
#   canonical bdw・anchor tracked スクリプト等）へホストユーザー権限で書けてしまう（封じ込めバイパス）。
#   本 hook はその穴を埋める＝rm/git/bd-write guard と同じ「PreToolUse exit 2 は permission 評価より前に
#   走り bypassPermissions を貫通する」性質を使い、ファイル編集ツールを worktree 境界へ縛る。
#
# 設計（bd sc-649・2026-07-03 grill 確定 + gate 一次監査で改訂）:
#   - 発火条件: 環境変数 **`SCRIBE_WORKER=1`** のときだけ発火する。これは scribe-spawn が worker CC プロセスへ
#     **spawn 時に注入する worker-immutable な signal**（全 worker 無条件・sandbox on/off 非連動）。worker は
#     自分の Bash で env を触っても CC プロセス env（hook が継承する側）は変えられないため spoof 不可。
#     admin/consult/foreign セッションには注入されないため発火しない（admin の正当な全リポ編集を壊さない）。
#     **重要（gate 一次監査で判明した設計改訂）**: 活性化に filesystem content（`.beads/metadata.json` 台帳
#     identity 等）を一切使わない。台帳 metadata は git-tracked で worktree 内にチェックアウトされ、かつ
#     anchor コピーも bwrap allowWrite 内ゆえ **worker が書き換えられる**＝それを活性化 signal に使うと worker が
#     自分の kill-switch を編集して guard を無効化できる（self-disable バイパス）。よって env signal のみを信用する。
#   - 境界: worktree root も **spawn 注入の worker-immutable env `SCRIBE_WORKTREE`（絶対パス）のみ**から取る
#     （activation の SCRIBE_WORKER と対称）。git 構造は**一切信用しない**。書込み先の realpath が worktree root
#     の realpath 配下（root 自身か root+os.sep 始まり）なら allow、それ以外は deny。realpath ゆえ symlink /
#     `..` traversal で境界外へ抜けられない。
#     **重要（gate round2/round3 で判明した設計改訂）**: 境界を git toplevel から導出すると worker-reachable
#     になる。worker は `<worktree>/.git`（linked worktree では単一ファイルの gitfile）を **非再帰 rm** で消せ
#     （rm-guard は再帰 rm のみ block）、以後 `git rev-parse --show-toplevel` が親 anchor へ walk-up して
#     境界が anchor 全体へ広がる（boundary self-escalation）。git toplevel fallback を残すとこの穴が残るため
#     **完全撤去**し、SCRIBE_WORKTREE のみを信用する。scribe-spawn は `%q` で source-safe に env-file へ焼く
#     （空白/メタ文字入りパスでの語分割・source-time インジェクションを防ぐ・gate round3）。
#   - fail-mode（三値・sc-649 D5）:
#       * 非 worker（SCRIBE_WORKER≠1）→ exit 0 = **発火せず**（admin/foreign を brick しない）。
#       * worker 文脈（SCRIBE_WORKER=1）で境界を確立できない（SCRIBE_WORKTREE 未設定/非 dir）・発火後のパス判定
#         （解決不能 / 境界外）→ exit 2 = **deny**（fail-closed・security guard の核心）。＝allowlist 型ゆえ
#         rm-guard の denylist 型(解決不能=fail-open)とは方針が逆。git fallback へ落とさず deny する。
#       * guard 自身のクラッシュ（JSON parse 失敗 / 想定外例外）→ exit 0 = **fail-open** ＋警告
#         （guard バグで worker の全ファイル編集を brick しないため）。
#   - matcher は `Edit|Write|NotebookEdit|MultiEdit`。CC 2.1.199 に MultiEdit が存在しうるため（docs では
#     未明記だが gate 指摘）**防御的に含める**（存在しなければ matcher が単に一致しないだけ・コストゼロ）。
#     tool_input のパスは file_path（Edit/Write/MultiEdit）または notebook_path（NotebookEdit）を読む。
#   - folio の PreToolUse[Edit|Write|NotebookEdit]（spec 配下のみ対象）とは AND 合成で共存する（CC は同一
#     matcher の複数 hook を全実行し 1 つでも exit 2 なら deny）。本 guard は folio を一切参照・改変しない。
#
# 入力: Claude Code は hook 入力を stdin に JSON で渡す（tool_name / tool_input / cwd 等）。cwd は共通
#   フィールドで必ず含まれる（verified・code.claude.com/docs/en/hooks.md）。
# 出力: 境界外/解決不能で stderr に理由+代替を書き exit 2。それ以外/発火せず/自己エラーは exit 0。
# 検証: `python3 edit-write-guard.py --self-test`（decide の境界・traversal・symlink を hermetic に assert）。

import sys
import os
import json

MSG_OUTSIDE = (
    "[edit-write-guard] BLOCKED: worker は自分の worktree の外へ Edit/Write できません（sc-649）。\n"
    "  書込み先: {path}\n"
    "  worktree: {root}\n"
    "  理由: sandbox(bwrap)は Bash subprocess のみを封じ、built-in の Edit/Write/NotebookEdit/MultiEdit は別レイヤ。\n"
    "        worker のファイル編集は worktree 内に限定される（bypassPermissions を貫通する PreToolUse guard）。\n"
    "  対処: worktree 内の絶対パスへ書く。anchor/.beads への台帳更新は bdw(Bash)経由。worktree 外の変更が\n"
    "        本当に必要なら、直接書かず『admin への起票候補』として相談サマリに記す（worker は graph/外部を触らない）。\n"
)
MSG_UNRESOLVABLE = (
    "[edit-write-guard] BLOCKED: 書込み先パスを安全に解決できませんでした（fail-closed・sc-649）: {path}\n"
    "  worktree 内の絶対パスで再試行してください。\n"
)
MSG_NO_BOUNDARY = (
    "[edit-write-guard] BLOCKED: worker 文脈（SCRIBE_WORKER=1）だが worktree 境界を確立できません"
    "（SCRIBE_WORKTREE 未設定/非ディレクトリ・fail-closed・sc-649）。\n"
    "  scribe-spawn 経由で起動された worker は SCRIBE_WORKTREE が注入されます。手動起動なら"
    " SCRIBE_WORKTREE に自 worktree の絶対パスを設定してください。\n"
)


def decide(worktree_root, file_path, cwd):
    """書込み先 file_path が worktree_root 配下かを判定する（純関数・hermetic）。
    返り値 ("allow"|"deny", reason)。パス解決不能/境界外は deny（fail-closed・sc-649 D5）。
    root_real + os.sep で prefix 境界を厳密化（/foo が /foobar に誤マッチしない）。"""
    try:
        root_real = os.path.realpath(worktree_root)
        target_abs = file_path if os.path.isabs(file_path) else os.path.join(cwd or "", file_path)
        target_real = os.path.realpath(target_abs)
    except Exception:
        return ("deny", MSG_UNRESOLVABLE.format(path=file_path))
    if target_real == root_real or target_real.startswith(root_real + os.sep):
        return ("allow", "")
    return ("deny", MSG_OUTSIDE.format(path=target_real, root=root_real))


def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        sys.exit(0)  # stdin 読取不能 → fail-open
    if not raw.strip():
        sys.exit(0)  # 空入力 → fail-open
    try:
        data = json.loads(raw)
    except Exception:
        sys.stderr.write("[edit-write-guard] cannot parse hook input JSON, failing open\n")
        sys.exit(0)  # JSON parse 失敗 = guard 自己エラー → fail-open
    try:
        # --- 活性化: spawn 注入の worker-immutable env signal のみ（filesystem content を読まない=self-disable 不能） ---
        if os.environ.get("SCRIBE_WORKER") != "1":
            sys.exit(0)  # 非 worker（admin/consult/foreign）→ 発火せず

        # 境界 root も **spawn 注入の worker-immutable env SCRIBE_WORKTREE のみ**から取る（activation と対称）。
        # git 構造は一切信用しない（worker が <worktree>/.git を非再帰 rm して境界を anchor へ広げられる＝gate
        # round2 の boundary self-escalation を根絶。git toplevel fallback は残穴になるため撤去した＝gate round3）。
        # worker 文脈（SCRIBE_WORKER=1）で境界を確立できない（SCRIBE_WORKTREE 未設定 / 実在 dir でない）ときは
        # git fallback へ落とさず **fail-closed で deny**（allowlist 型 guard の方針＝発火後の不確実は deny）。
        wt_root = os.environ.get("SCRIBE_WORKTREE") or ""
        if not wt_root or not os.path.isdir(os.path.realpath(wt_root)):
            sys.stderr.write(MSG_NO_BOUNDARY)
            sys.exit(2)

        tool_input = data.get("tool_input") or {}
        target = tool_input.get("file_path") or tool_input.get("notebook_path")
        if not target or not isinstance(target, str):
            # 想定外の tool 形（file_path/notebook_path が無い）→ 書込み対象が無く write は起きない = 自己エラー側 → fail-open
            sys.stderr.write("[edit-write-guard] no file_path/notebook_path in tool_input, failing open\n")
            sys.exit(0)

        # cwd は相対 file_path の解決にしか使わない（絶対パスは境界 root だけで判定）。cwd 欠落 + 相対パスは
        # decide 内で guard プロセス cwd 基準に解決され境界外 → deny（fail-closed・cwd 欠落を fail-open にしない）。
        cwd = data.get("cwd") or ""
        verdict, reason = decide(wt_root, target, cwd)
        if verdict == "deny":
            sys.stderr.write(reason)
            sys.exit(2)  # 境界外/解決不能 → block（fail-closed）
        sys.exit(0)
    except SystemExit:
        raise
    except Exception as e:
        # 想定外の例外 = guard クラッシュ → fail-open（worker のファイル編集を brick しない）
        sys.stderr.write(f"[edit-write-guard] internal error, failing open: {e}\n")
        sys.exit(0)


def _self_test():
    import tempfile
    failures = []

    def check(name, cond):
        if not cond:
            failures.append(name)

    # decide（realpath 境界判定・実 filesystem で symlink/traversal を exercise）
    with tempfile.TemporaryDirectory() as td:
        td = os.path.realpath(td)
        root = os.path.join(td, "repo", ".worktrees", "sc-x")
        os.makedirs(os.path.join(root, "sub"))
        check("inside file", decide(root, os.path.join(root, "a.txt"), root)[0] == "allow")
        check("inside subdir", decide(root, os.path.join(root, "sub", "b.txt"), root)[0] == "allow")
        check("root itself", decide(root, root, root)[0] == "allow")
        check("outside sibling", decide(root, os.path.join(td, "repo", "other.txt"), root)[0] == "deny")
        check("outside tmp", decide(root, os.path.join(td, "elsewhere.txt"), root)[0] == "deny")
        check("parent traversal", decide(root, os.path.join(root, "..", "escape.txt"), root)[0] == "deny")
        # prefix-boundary bug: /…/sc-x が /…/sc-x-evil に誤マッチしない
        check("prefix sibling not inside", decide(root, os.path.join(td, "repo", ".worktrees", "sc-x-evil", "z.txt"), root)[0] == "deny")
        # kill-switch 自己編集の封じ: worktree 内の .beads/metadata.json は allow だが、活性化は env のみゆえ
        # これを書き換えても guard は無効化されない（本 self-test は decide 層＝境界のみを見る）。
        check("in-tree metadata inside", decide(root, os.path.join(root, ".beads", "metadata.json"), root)[0] == "allow")
        # symlink escape: worktree 内の symlink が外を指す → その先への書込みは deny
        outside_dir = os.path.join(td, "outside")
        os.makedirs(outside_dir)
        link = os.path.join(root, "link")
        os.symlink(outside_dir, link)
        check("symlink escape", decide(root, os.path.join(link, "c.txt"), root)[0] == "deny")
        # relative path は cwd(=root) 基準で解決され worktree 内なら allow
        check("relative inside", decide(root, "rel.txt", root)[0] == "allow")

    if failures:
        sys.stderr.write("[edit-write-guard] SELF-TEST FAIL: " + ", ".join(failures) + "\n")
        return 1
    sys.stderr.write("[edit-write-guard] SELF-TEST OK\n")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv:
        sys.exit(_self_test())
    main()

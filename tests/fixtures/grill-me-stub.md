# grill-me (test fixture stub)

本物は ~/.claude/skills/grill-me/SKILL.md。本 stub は scribe-spawn の grill-consult が
`$SCRIBE_GRILL_SKILL` の内容を **verbatim 注入する機構** を hermetic に検証するためのもの。
注入されたことは下の sentinel が prompt に現れるかで判定する（本物のスキル内容には依存しない）。

GRILL_ME_VERBATIM_SENTINEL

- 全体地図を先に示す（番号付き一覧）。
- 各論点を「現状 → なぜ問題か → 選択肢」で説明する。
- 1 論点 1 質問を散文で（AskUserQuestion は使わない）。
- 理解最優先・AI は答えを決めない。

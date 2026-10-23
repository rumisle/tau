# Typography

How an answer's text is set. Sources: W3C's Requirements for Chinese Text Layout (clreq), The Type's 孔雀计划 series
(thetype.com), Butterick's Practical Typography, GB/T 15834 for Chinese punctuation. Markdown becomes attributed text in
`ios/Tau/Chat/MarkdownText.swift`; Telegram's InteractiveTextNode lays it out, with tau's patch
(`ios/ThirdParty/telegram-patches/0013-InteractiveText-hanging-indent-orphans-even-lines.patch`).

## What Core Text already does

Measured, iOS 17 and later; nothing in tau does these:

- **Han and Latin apart.** 1/8 em between a Han character and a Latin letter or digit, none when the text has a space
  there (which is then about 1/4 em). clreq asks for up to 1/4 em, so text with or without the spaces reads right.
- **Line breaking.** Unicode's rules (UAX #14): no comma, period or closing bracket starts a line, no opening one ends
  it, clreq's "basic" level.
- **Punctuation in a row** is compressed (「。」」 to 1.3 em), and an opening bracket at the start of a line loses its
  blank half.

## What tau does

- **Line spacing.** Answers 1.45 em (`MarkdownStyle.answerLineSpacing`, 0.231 of a line's height; Telegram's 0.12 gives
  1.32 em). One value for every script: a paragraph's spacing must not change with its language, nor as an answer
  streams. Han fills its em box and wants more than Latin, whose lowercase leaves room above and below; 1.45 is still in
  Butterick's 120–145% for Latin. Code keeps 0.12 (the patch), users' bubbles Telegram's.
- **Even lines.** A line set in a fallback font (Chinese in PingFang) is as tall as one in the text's font: above 17 pt
  the system font's lines are taller than PingFang's (the patch).
- **Space between blocks, in ems of the text** (`MarkdownText.Spacing`): paragraphs 0.7, under a blank line (Butterick's
  4–10 pt); list items 0.25; a heading 1.5 above and 0.45 below, nearer what it heads. Inside a text the space is a blank
  line whose newline's font makes its height; between blocks laid out apart (tables, scrolling code, the chunks of a
  long answer) `MarkdownText.spacing` gives the same.
- **Headings**: 24, 21, 19, 17, 15 and 15 pt at 17, semibold, H6 dimmed.
- **Lists** hang: a wrapped line starts under the item's text, a nested list where its parent's text does. Bullets by
  depth •, ◦, ▪; numbers end where the text begins, so 9. and 10. line up. The patch reads `Attribute__Indent` (the
  first line's offset and the others').
- **No lone character.** A paragraph whose last line would be one Han character with its punctuation takes the last
  character of the line before (clreq 7.1.2): `Attribute__AvoidsOrphans`, outside code.
- **Chinese ellipsis.** GB/T 15834's is six dots across two characters, centered; PingFang's sits on the baseline. Two or
  more U+2026 in a row show as U+22EF, the midline ellipsis, with a kern of −1/8 em next to Han that takes back Core
  Text's Western spacing.
- **Curly quotes** for straight ones, outside code and formulas: by what is on either side, and alternately where that
  cannot tell (between Han characters). After a digit they stay straight (5'10", 30"); between letters `'` is an
  apostrophe.
- **Inline code** at 16 pt at 17: monospace looks larger at the same size.
- **Tables** take the delimiter row's alignment (`---:`) and tabular figures. `---` is a hairline across the column.

## Code blocks

Telegram's code block (a `pre` entity's), with:

- **15 pt at 17**: a block's line holds about 34 characters, not 29.
- **Every block titled**: its language as it is written (JSON, TypeScript, C++), or Plain.
- **Wrapped lines go on two characters further in** than their line starts, as editors wrap code; a tab is four
  spaces (copied as the tab); a diff's lines keep their indentation after their mark, which does not break from it (a
  word joiner, copied as nothing).
- **The width of the text**, whatever its lines' (the patch, `0014`), and no icon: a tap on a block copies it, as
  written.
- **A diff's added and removed lines** on green and red, across the block (`Attribute__LineBackground`, drawn by the
  patch); `+++` and `---` stay plain.
- **With wrapping off** a block scrolls sideways, and its edges fade where there is more of it.
- Telegram's line spacing (0.12), in text set at 1.45.

Replaced characters keep what they were under `MarkdownText.originalKey`: copying a selection gives the text as
written. Copy on a message copies its text.

## Text size

The app follows iOS's text size (Settings > Display & Brightness > Text Size), as Telegram does by default: the body
style's size, to the nearest of Telegram's 14, 15, 16, 17, 19, 23 and 26 (`TauTheme.systemFontSize`), is the theme's
`fontSize`; a change makes a new theme, which every screen lays out again with. Chats (answers, reasoning, bubbles,
tables, dates), the composer, the chat list and Settings' rows scale with it, as Telegram's `chatFontSize` and
`listsFontSize`; the cards of tools and subagents keep their sizes. The UI tests set it with `-textSize 23`.

## Not done

- **Justified text.** Chinese books justify; chat apps do not, and mixed with Latin it stretches words.
- **Hanging punctuation.** clreq: most Chinese publications do not hang it.
- **Emphasis in Chinese.** PingFang has no italic, so `*强调*` shows as plain text; clreq's emphasis dots would need
  drawing of their own.

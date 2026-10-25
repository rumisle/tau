# Reading while an answer streams

What the user sees while an answer streams and they scroll back through it, and why it is built the way it is. Reproduce
with the dev model's `!doc <sections>` (a long answer of headings, paragraphs, lists, code, tables and math) and
`SendingUITests.testStreamingScroll` / `testStreamingRecycle`, which screenshot every half second.

## What went wrong, and why

- **The text being read moved.** The chat list is inverted: the newest row is item 0 at the bottom. A row that grows
  pushes everything above it up, which follows the answer when the user is at the end, and drags what they are reading
  away when they are not.
- **Blocks drifted into each other.** Every streaming step laid the row out again, and every block's frame (text, code
  scroller, table) animated to its new place. The next step started a new animation from wherever the last one had got
  to, so blocks were always mid-flight and overlapped until the stream stopped.
- **Tables, code and paragraphs went blank.**
  - Tables threw their cell nodes away on every layout and drew the new ones in the background, so a table was empty
    until they were drawn, which, at a step every tenth of a second, it often never was.
  - The text block the stream was in was drawn again in the background too.
  - Separately, when the reveal caught up with the stream, a block's reveal count went to "none" (everything shown),
    then came back when more text arrived, with its mask animating in. What had been on screen faded out and in again.
- **Scrolling away and back started the answer over.** A row that leaves the screen loses its node. The new node began
  its reveal at the first letter, so the row shrank and grew again and the scroll position jumped.
- **Formulas showed as `$…$` text.** The math scanner read a closing code fence as the start of inline code that ran to
  the next block's opening fence, and left every formula between them alone. This appeared as soon as a second code
  block streamed in.

## What it does now

- **The row grows down the screen** (`ListViewItemApply.setInvertOffsetDirection`, as Telegram's expanding bubbles
  do). At the end of the chat the list still follows the answer; scrolled back, the text stays where it is and new text
  goes on below, under the arrow to the end.
- **Inside a streaming row nothing animates**: blocks are put in place at once, and only the row's height animates in
  the list. New text comes in through Telegram's reveal (`TextRevealController`).
- **The streaming row is drawn as it is laid out** (`displaysAsynchronously = false`, with InteractiveTextNode patched
  so that its segments follow). A segment whose characters, lines and places are the same as before keeps its drawing,
  so a step draws only the paragraph that grew: about 0.8 ms a step on the main thread (90th percentile 2 ms).
- **Tables keep their cells**. A table laid out again unchanged keeps them all; a changed one keeps the cells whose
  text did not change.
- **Every block keeps a reveal count until the reveal ends**: its whole length once the reveal has passed it. Segments
  a layout creates take the count at once.
- **How far each answer has been revealed** is kept per chat (`ChatMessageItemInteraction.revealProgress`), so a new
  node picks up where the last one stopped.
- **Fence lines pass through the math scanner whole.**
- **A row is drawn only in the room the list has made for it** (`ChatMessageItemNode.updateSlotMask`), while its
  height animates and while its text is revealed, with its top at the room's top: a new row comes in from under the
  row below as the rows above move up. Before, a new row was drawn whole at once over the rows still moving away, and
  a revealed line was drawn below the row until the row was laid out again for it.
- **Once the next block of an answer has begun, the one before is written**: it is no longer streaming, and its reveal
  goes to the end at once (Telegram's finalize, 0.3 s) rather than at the pace for text still coming. A provider that
  buffers sends the whole thinking, then the answer: the thinking was revealed at 40 characters a second, drawn over
  the answer under it, which moved down a line at a time. The dev model's `!burst <text>` answers all at once,
  `!burst+<ms>` with the answer that long after the thinking, `!burst*<ms>` with that long between events (`*5` is
  what showed it).

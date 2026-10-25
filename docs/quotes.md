# Quotes

Selected text quoted into the field, as a reply to it: Quote in the selection's menu (docs/typography.md), from a
selection in place or in a message's menu. The reply goes around and after the quotes, as many as there are:

```
<tau:quote>
because users may type it themselves
</tau:quote>

hhahaha, and what is <tau:quote>not Markdown's</tau:quote> about?
```

What is sent is text: the quoted words in `<tau:quote>`, nothing else. The chat they came from is the model's context,
so no link or ID says where they were; the preamble says what the tag is (`server/src/host.ts`).

- **A block** is the tag on a line of its own, the words, the closing tag on a line of its own; **a few words** are
  between the tags in a line. Quoted at the start of a line, or more than a line, it is a block; in a line's middle, a
  few words in it.
- **Read** (`Common/TauQuote.swift`, `server/src/quotes.ts`) outside code: tags in a fence or a backtick span are
  code, and a tag never closed is text. A `</tau:quote>` in the words is written `&lt;/tau:quote>`.
- Plain text: Quote takes what is selected as Copy does (a formula as its LaTeX), not its formatting.

## In the field

`Chat/InputQuotes.swift`: the field (TextKit 1, as Telegram's) has no tags in it. A quote's characters carry one
`InputQuoteMark`, which `InputQuotes.text(of:)` writes out as tags for sending and drafts, and `attributed(_:)` reads
back (a draft, a message to edit or put back).

- A block is drawn as Telegram's field draws a quote (ChatInputTextNode's QuoteBackgroundView): its bar and tint
  (`MessageInlineBlockBackgroundView`) and the quote mark in its corner, the text set in 10 pt from the bar and 24 pt
  from the end, 8 pt above and below. A few words are on a tint of the accent color.
- It goes in where the cursor is (at the end when the field is not being typed in), not inside another quote; the
  cursor after it, on a line of its own after a block, and the keyboard up.
- Backspace right after a few quoted words, or at the start of the line after a block, takes the quote whole.
  Typing inside a quote edits it; Return at a block's end leaves it.

## In the chat

A block is Markdown's block quote, drawn as Telegram's quote; a few words are on a tint of the quote's color, as in
the field (`MarkdownText.inlineQuoteKey`, drawn by the row with Telegram's `LinkHighlightingNode`), in the user's
messages and in answers (a model that quotes back the same way). A one-line preview (the chat list, a push) shows
the message's own words: its blocks left out unless they are all it has, a few quoted words as they are. Copy on the
message copies it as Markdown: blocks as `>` lines, a few words in quotation marks.

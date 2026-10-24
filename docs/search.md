# Search

Every server indexes its conversations; the app asks each server it knows and merges their pages by score. There is no
offline search yet: the cached transcripts are not indexed on the phone.

## What is indexed

What the user wrote, what the model answered, and its reasoning, as separate parts; conversation titles. Tool calls and
tool output are not indexed: they are most of a transcript's bytes (873 MB of pi sessions hold 28.6M characters of
prompts, answers and reasoning) and searching them would mostly find logs. A subagent's report counts as the agent's
answer. Failed model responses are not indexed: the server retried them, or the chat shows their error.

## Index

`server/src/search/`, after [rumisle/recall](https://github.com/rumisle/recall):

- One SQLite file beside the database (`tau.search.db`), a contentless FTS5 table. Text is tokenized once in
  JavaScript (`tokenize.ts`), and the same tokenizer reads the query and finds the words to mark, so a highlight is
  always exactly what matched. Tokens are lowercased runs of letters and digits without diacritics; each CJK character
  is a token, and a CJK query is a phrase of its characters, so it matches as a substring; identifiers also yield their
  parts (`palette` finds `CommandPalette`).
- The rowid is `conversation * 2^25 + seq * 8 + kind`: grouping by conversation and filtering by kind read the full-text
  table alone, with bit operations.
- Written as entries are committed (the Session's commit stream), so there is no refresh pass; on start the server
  indexes what was written before the index caught up, a page at a time. Each entry is indexed once, as its own
  conversation's: a fork shares its origin's entries.
- The text is not copied into the index: the excerpts shown are read from the entries, for the 20 hits of a page.
- FTS5 prefix indexes (2 and 3 letters) keep the word being typed cheap.

## Matching and ranking

As recall's: all words must appear; `"a phrase"`; `-word` leaves a conversation out. The last word is a prefix from its
third letter unless it is a common word (typing "the" means the), and from its second while it is still being typed.
Words of four letters or more that are rare also match one typo away (`compacton` finds compaction).

Strict tiers whatever the age: every word exactly in one part; then with prefixes or typos; then the words spread over
several parts. Within a tier, the best part's bm25 and the number of matching parts, a title match counting 1.5 times,
times a recency boost (2.5 today, 1.75 two weeks ago, toward 1). Archived chats count half. A match a fork shares with
its origin is shown once, in whichever was active last.

A search reads at most the 50,000 newest matching parts: a word in most conversations, or two letters being typed,
then costs the same in a large index as in a small one, and ranks by recency, which is all that tells such matches
apart.

## Speed

`server/bench/search.ts` indexes the prompts, answers and reasoning of the pi sessions in `~/.pi/agent/sessions` and
times queries (M1, Node 22). `--scale 10` indexes them ten times over.

| | 28.6M chars, 985 chats | 286M chars, 9,850 chats |
|---|---|---|
| index | 6 s (4.8M chars/s), 42 MB | 68 s, 395 MB |
| rare word, phrase, typo, CJK | 1–4 ms | 2–5 ms |
| two words | 4 ms | 16 ms |
| common word ("the", 37k / 378k parts) | 15 ms | 19 ms |
| typing two letters ("co") | 14 ms | 19 ms |
| three common words | 20 ms | 37 ms |
| one chat, 1,650 entries | 2 ms | 19 ms |

What made it fast, measured: one pass over the matches for prefixes and typos instead of an exact pass and a fuzzy one,
with which chats match exactly as a cheap `DISTINCT`; bit operations instead of division in the grouping; checking forks
only for conversations that have them; skipping bm25 above 10,000 matches; and the 50,000 cap. Word counts for the typo
and prefix heuristics are cached for a minute.

## In the app

- **Chat list**: Telegram's search field under the title. Chats whose title or server match come first, found on the
  phone at once; then messages from the servers once typing pauses for 0.25 s (each key cancels the wait for the one
  before, as Telegram's message search waits; the same query again is not sent), a page of 20 at a time as the list
  scrolls. Each message result is Telegram's: the chat, when it was said, and two lines of excerpt with the matched words
  in the title's color. A result opens its chat at the message, the older history loading until it is there, with the
  words marked.
- **In a chat**: Search in the chat's menu (⋯). The field fills the bar (Telegram's ChatSearchNavigationContentNode),
  "3 of 12" with Up and Down replaces the input panel, and the newest match is shown first, its words marked as
  Telegram marks them (LinkHighlightingNode in the theme's text highlight color). Up goes to older matches.

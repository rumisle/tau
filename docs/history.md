# History

Two tools that let an agent search and read the server's conversations, its own included,
past its compaction boundary, its subagents', and its owner's. `history_search` finds messages; `history_read` opens a
conversation at one and pages through it. Both return JSON, and both name everything by tau's links
(docs/links.md), so what an agent finds is what the user can tap, and what the user pastes is what an agent can read.

Built on what exists: the search index (`server/src/search`, docs/search.md) for finding, and durable's `scanEntries`
for reading any conversation, the calling one included (raw history, which compaction never changes). The tools are
`server/src/history.ts`; the text of a part, which the index and a read share, and its truncation are
`server/src/history-text.ts`.

## Why

- **After compaction** the model has a summary where the conversation was. The entries are all still in the database
  and in the index; nothing lets the model reach them.
- **Earlier work**: "the command we used", "that error last week", "what did we decide about X". The user remembers it
  happened somewhere; the agent should find it as the user's search does.
- **Across agents**: a parent reads what a subagent did beyond its report, a subagent reads what its parent was asked,
  a Later reads its owner. This is the leader's inspection of its subagents: the subagent tool gets no `read` action of
  its own; `history_read({ link })` with a link from `history_search({ in: "subagents" })` or the subagent card is it.
- **Research**: every place a command was run, every failure of a tool, over all history. The agent does this in code
  mode, so the tools must page without limits and return data a script can filter.
- **Links**: docs/links.md ends "Reading the linked chat is for later". `history_read` is that.

## The tools

```ts
history_search({ query?, in?, kinds?, sort?, exact?, limit?, cursor?, truncate? })
history_read({ link?, kinds?, older?, newer?, offset?, truncate? })
```

Three rules hold for both, and are most of what the model has to learn:

1. **Addresses.** A conversation or a message is a tau link; `in` and `link` take one, or an alias.
2. **Kinds.** One vocabulary of six names chooses what is searched, what is shown, and labels what comes back.
3. **`next`.** A result that is not complete carries `next`: the arguments to call the same tool with for the rest.
   The model never builds a cursor or an offset; it copies `next`.

The same call returns the same JSON to the model and to a script (`output` and `structuredOutput` carry one value).
There is no mode for scripts: a script that wants everything asks for it with `limit: -1` or by following `next`.

### Addresses

```
tau://d0003019/1523          a conversation
tau://d0003019/1523/880      its entry 880
tau://d0003019/1523/880?q=…  the same entry; `q` is for the app's highlight and is ignored by the tools
```

The numbers are durable's own IDs: `ConversationId` and `EntryId` are numbers (`Id<…>` in durable's `types.ts`), the
link's path is them, and the index stores the same. History only grows, so a link is good for good.

The aliases, resolved against the calling conversation (`api.conversationId` in the tool):

| Alias | Means |
|---|---|
| `this` | The calling conversation |
| `owner` | Its creator: `ConversationRecord.owner.conversationId` |
| `subagents` | Its subagents: the conversations in its `tau.subagents` document (`server/src/subagent.ts`); `in` only, as it names several |

`in` omitted searches every conversation on the server; `link` omitted reads `this`.

A link to another server (its first eight characters are not this server's ID) is an error, not forwarded: one server
does not reach into another's conversations.

### Kinds

| Kind | What | Searched by default | Shown by default |
|---|---|---|---|
| `user` | What the user wrote | yes | yes |
| `assistant` | What the model answered; a subagent's report counts as this, as in the index today | yes | yes |
| `reasoning` | The model's thinking | yes | yes |
| `tool_call` | A tool's name and arguments | yes | yes |
| `tool_output` | A tool's result | yes | yes |
| `title` | The conversation's title | yes | not a part of an entry |

`kinds` narrows both tools: `history_search({ query, kinds: ["tool_call"] })` searches commands only;
`history_read({ link, kinds: ["user", "assistant"] })` reads a conversation as its dialogue, without tools or thinking.

### `next`

| Where | What it continues |
|---|---|
| A search's `next` | The following page of hits: `{ query, in, kinds, …, cursor }` |
| A window's `older` / `newer` | The entries before or after the window: `{ link: <the entry before the first>, older: n, newer: 0 }` |
| A part's `next` | The rest of a cut part: `{ link: <its entry>, older: 0, newer: 0, part?, offset }` |

A result without `next` is complete.

**A tool's call and its result are one place.** durable keeps them as two entries; tau links to the call's entry for
both. A `tool_output` hit's link is its call's entry, and a window anchored there shows the call with its result, so
no link points at an entry a read does not show. A link to a result's own entry (pasted from somewhere else) is read
as its call's.

## history_search

```ts
history_search({
  query?: string,          // omitted: list, newest first
  in?: string,             // link or alias; omitted: all conversations
  kinds?: Kind[],          // omitted: all six
  sort?: "relevance" | "newest" | "oldest",   // default relevance; newest when there is no query
  exact?: boolean,         // default true
  limit?: number,          // hits; default 20; -1: all
  cursor?: string,         // from next
  truncate?: boolean,      // default true
  text?: boolean,          // default true; false: hits without text, links only
})
```

### Matching

The index's query syntax, as docs/search.md has it: every word must appear, `"a phrase"` must appear as written,
`-word` leaves a hit out.

- **`exact: true`** (the default): no prefixes and no typos. The user's search guesses at the word being typed and
  forgives a slip on a phone; an agent sends whole words and does not slip, and a research pass must not collect
  near-misses. Each word or phrase is first found by the index (the tokens, adjacent for a phrase), then checked as a
  literal substring of the part's text, punctuation included, so `"--conditions=source"` matches that and not
  `conditions source`. A term of lower-case letters and digits needs no check (the token is the word as written);
  any other, a capital, punctuation, a phrase's spacing or CJK, reads the text of every part the index found, before
  counting and ranking, so `total` and the pages are of literal matches. The text is the one the excerpt is cut from,
  so a shown hit is read once.
- **`exact: false`**: the user's search exactly: prefixes and one typo away (docs/search.md, Matching).
- **Case** is ripgrep's smart case, in both: a query in lower case ignores case; one with a capital letter matches it.
  `error` finds `Error:` and `ERROR`; `CommandPalette` finds only that. No parameter: the query says it. With
  `exact: false`, a term with a capital is matched as written (no prefix or typo for it); the others as the user's
  search matches them.
- **`-word`** leaves out a part that has it (the index's `NOT`), not a whole conversation as in the user's search.
- **No query** lists the scope's parts newest first, filtered by `kinds`: `history_search({ in: "subagents" })` is
  what the subagents said; `history_search({ in: link, kinds: ["tool_call"] })` is every call in one conversation.

### Ranking

`sort: "relevance"` is the index's ranking (strict tiers, then bm25 and recency; docs/search.md), but of **hits**, not
of conversations: the user's search shows one hit per chat, and an agent wants every hit, several from one chat if
those are the best. `newest` and `oldest` order by the entry's time and skip bm25, which is most of a search's cost.

### Scope and what is left out

- **Compaction does not hide anything.** The index is written at commit, whatever the context's `head` is later, so
  every entry is found. A hit says whether its entry is still in the calling conversation's context (`inContext`).
- **Hidden conversations** (`MetaDoc.hidden`) are left out, as the user's search leaves them out.
- **Forks**: an entry a fork shares with its origin is indexed once, as the origin's (docs/search.md); its link is the
  origin's. Searching `in` a fork includes what it shares, through `ConversationRecord.parent`.
- **The call itself**: a search of `this` leaves out the entry that holds the running call, which would otherwise find
  its own query.

### Result

```json
{
  "hits": [
    {
      "link": "tau://d0003019/1488/42",
      "chat": { "link": "tau://d0003019/1488", "title": "压缩 bug" },
      "kind": "tool_call",
      "time": "2026-10-13T21:40:12Z",
      "text": "bash: npm run build && npm test",
      "inContext": false
    }
  ],
  "total": 9,
  "next": { "query": "\"npm run build\"", "kinds": ["tool_call"], "cursor": "…" }
}
```

- **`hits`** are flat: one per matching part, each with its conversation. Grouping by conversation was tried in the
  design and made two kinds of `next` (another page, or into one chat); flat hits have one, and narrowing to a chat
  is `in`.
- **`text`** is the excerpt around the match, the matched words between `«` and `»`. Not character ranges: the app
  marks words with ranges, the model reads markers. A `tool_call` hit's text is the tool's name, a colon, and its
  arguments as the call's card titles them (the command for bash, the path for read).
- **`total`** counts every hit. When the index stopped at its scan cap (below), `total` is a floor and the result says
  so: `"complete": false` (absent when it is complete). It is never silently short.
- **`text: false`** leaves the excerpts out: the hits' links, chats, kinds and times, read from the index alone (a
  term that needs the literal check still reads its parts). For a script that reads each hit anyway, about five
  times faster over many hits (Speed).
- **`time`** is ISO 8601 in UTC: unambiguous for the model, which converts when it tells the user.

### Pages and the cursor

`limit` is a count of hits in every scope. `limit: -1` returns all of them in one result.

`cursor` is opaque, from `next` only. Inside it is the offset and the time of the first page's search (the index's
`now` option): recency changes scores, and a hit committed between two pages would shift every offset after it, so the
pages of one search are ranked as of its first. Opaque so that what it holds can change; a model that edited an
offset would break when it did.

## history_read

```ts
history_read({
  link?: string,        // a conversation, an entry, or an alias; default "this"
  kinds?: Kind[],       // parts to show; default all
  older?: number,       // entries before the anchor; default 3 (10 at a conversation's end)
  newer?: number,       // entries after the anchor; default 3
  offset?: number,      // line of a single entry's text to start at
  truncate?: boolean,   // default true
})
```

### The window

A read is a window around an anchor:

- **A conversation's link** anchors at its newest entry: the last ten (it and 9 older), the final answer at the bottom. Whether that
  answer is final is the conversation's `status`.
- **An entry's link** anchors there: it and three on each side.
- **`older` and `newer`** size the window. To page up, read the link of the entry before the first with `older`;
  `older` in the result is that call, ready (`newer: 0`, so nothing is shown twice), and pages up by as many again.
- **`older: 0, newer: 0`** is the entry alone, read whole (below).

`scanEntries` reads it: `maxEntryId` the anchor, descending, `older + 1` entries; `minEntryId` after it, ascending,
`newer + 1` (the one more says whether there is more, and which entry `older` / `newer` start at). Entries are as
durable keeps them; a fork's window crosses into its origin's entries before its fork point, as its transcript does.
Only entries with a part of the kinds asked for count: a tool's result is in its call's entry, and entries with no
part (the system prompt, display entries) are not shown.

### Result

```json
{
  "chat": {
    "link": "tau://d0003019/1488",
    "title": "压缩 bug",
    "status": "idle",
    "owner": { "link": "tau://d0003019/1400", "title": "pi-mono 升级" },
    "forkOf": { "link": "tau://d0003019/1400/77" },
    "subagents": [{ "name": "reader", "link": "tau://d0003019/1530", "status": "working" }]
  },
  "entries": [
    {
      "id": 42,
      "time": "2026-10-13T21:40:12Z",
      "inContext": false,
      "parts": [
        { "kind": "reasoning", "text": "…" },
        { "kind": "tool_call", "name": "bash", "text": "npm run build && npm test" },
        { "kind": "tool_output", "name": "bash", "text": "…error TS2307: Cannot find module './identity.js'",
          "truncated": { "lines": 212, "bytes": 18210 },
          "next": { "link": "tau://d0003019/1488/42", "older": 0, "newer": 0, "offset": 1 } },
        { "kind": "assistant", "text": "缺了 identity.ts，先 hydrate 模型数据再 build" }
      ]
    }
  ],
  "older": { "link": "tau://d0003019/1488/39", "older": 10 },
  "newer": null
}
```

- **`chat`** is the conversation's card: who it is and who it is related to. Reading `this` is how an agent learns who
  it is: its own link, its owner, its fork origin, its subagents. `status` is `working` while a run is live
  (`LiveDoc.run`), else `idle`. The card is in every read, as the window's heading; a search's hits carry only the
  link and title.
- **An entry** is named by its `id`, not its whole link: a window's entries share the chat's link, which the card
  carries once, and the link of entry 42 is `chat.link` + `/42`. Repeating `tau://d0003019/1488/` on every entry is
  most of a long window's tokens. `next`, `older` and `newer` stay whole links, being arguments to copy; so do a
  search's hits, which come from many chats.
- **An entry** is one durable entry, and its **parts** are its content in order, each labeled by kind. A tool call and
  its result are paired by `toolCallId` and shown in the entry of the call, so an entry reads as the chat's card
  does: what was run, what came back.
- **`inContext`**: false when the entry is before the calling conversation's context `head`, or an `edits` entry omits
  or replaces it. Only meaningful in the caller's own conversation; elsewhere it is absent.
- **Images** in a part are named, not inlined: `{ "kind": "user", "text": "…", "images": 2 }`. Reading them is a
  later question (docs/media.md stores them by reference).
- **Marks**: a compaction's summary is an `assistant` part with `"summary": true`, where the conversation was cut for
  the model; a failed model response is an `assistant` part with `"error": true` and the error as its text, as is a
  tool's error result (`tool_output` with `"error": true`).
- **A part's `next`** names the part (`part`, its index in the entry) when the entry has several, so reading on
  shows that part alone, from `offset`.

### Truncation

After durable's `src/truncate.ts`, the one `read` uses: lines and bytes, whole lines, a result that says what it cut.

| Where | How | Limit |
|---|---|---|
| A part in a window | From the head; from the tail for `tool_output` (a command says how it went at the end, as bash keeps its tail) | 2,000 bytes or 40 lines |
| A hit's `text` | The excerpt around the match | about 300 characters |
| An entry alone (`older: 0, newer: 0`) | From the head, from `offset` | 2,000 lines or 50 KB, as `read` |

A cut part has `truncated` and `next`; following `next` reads the entry alone from the line after, as `read` continues
a file. `truncate: false` turns all of it off: every part whole.

Nothing else bounds a result. The harness's output limit cuts what the model sees of a large one, as it cuts bash's;
the model reads cut JSON well enough, and a script gets all of it from `structuredOutput`.

`truncate.ts` is not exported from `@earendil-works/pi-durable` (it is not in `src/index.ts`), and at pi 4b535d57 it
has no `truncateTail` (bash bounds its output with chord's `OutputBuffer` instead). tau has its own, `cut()` in
`server/src/history-text.ts`, by the same rules, from the head or the tail.

## The index

docs/search.md's index, with three changes.

**Tool calls and output.** `searchParts` (`server/src/search/service.ts`) leaves them out today, because they are most
of a transcript's bytes and the user's search would mostly find logs. For agents they are the point: commands and
errors. The rowid's three kind bits hold eight values and four are used (user 0, assistant 1, reasoning 2, title 3); the two
kinds take the next two:

- `tool_call` (4): the tool's name and its arguments as text, as a hit and a read show it (`bash: npm run build`, the
  other arguments as `key: value` lines after; `toolCallText` in `server/src/history-text.ts`), whole. Small and
  dense: searching `edit` finds every edit.
- `tool_output` (5): the first and last 2 KB of the output. Errors are at the end, headers at the start; the middle of
  a log is what made indexing it costly. Its `part` row names its call's entry (its link), and the result's distance
  from it, so its excerpt is read from the result.

The index is version 5 (`server/src/search/index.ts`): each conversation has a `tools` cursor beside its entries' one,
the newest entry whose tool calls and output are indexed. New entries are indexed with them. An index from before is
migrated at start (a column and an index on the parts' time, at once) and its tools cursors start at 0: the start's
backfill first indexes the tool calls and output of each conversation's entries up to its entries' cursor, in the
backfill's worker thread, then goes on as before. A tool's result in a fork whose call is in its origin is linked to
the origin's entry. On a copy of chorus's database (160 MB, 202 chats) that pass indexed the tool calls and output of
12,041 entries in 1.2 s, and the index grew from 9 to 25 MB.

The user's search does not show them (its `kinds` default stays as it is); ranked by relevance with words in a
reply, they weigh half, as archived chats do.

**The scan cap.** A search reads at most the 50,000 newest matching parts (`MAX_MATCHES`). A search with `limit: -1`
or a cursor past the cap reports `complete: false` and `total` as a floor. The benchmark kept it (Speed).

**Exact and smart case.** The index tokenizes in lower case; the literal check after it is what makes a match exact
and case sensitive. Nothing in the index changes for them.

## Code mode

Both tools declare a `structuredOutputSchema`, so a script gets objects. Both are `replay: "safe"`: they only read, so
a script resumed after a restart calls them again.

Every place a command was run, and whether it failed:

```js
const { hits } = await tools.history_search({ query: '"npm run build"', kinds: ["tool_call"], limit: -1 });
const runs = [];
for (const hit of hits) {
  const { entries } = await tools.history_read({ link: hit.link, older: 0, newer: 0 });
  const output = entries[0].parts.find((part) => part.kind === "tool_output");
  runs.push({ link: hit.link, chat: hit.chat.title, failed: /error|ERR!/i.test(output?.text ?? "") });
}
return runs.filter((run) => run.failed);
```

Paging instead, for a search too large to hold:

```js
let page = await tools.history_search({ query: "compaction", in: "subagents" });
while (true) {
  // … use page.hits
  if (!page.next) break;
  page = await tools.history_search(page.next);
}
```

## In the app

The cards follow the others (`ChatMessageItem.toolCardContent`): the title in semibold 13, what it works on in 13 after
it, a body in 12, on `toolCardBackgroundColor`, the time at the right. `toolTitle` names them from the tool:
`history_search` is History search, `history_read` is History read.

One rule, which the rest follows: **the first line is the call; below it is the result.**

- **The first line** is the tool and every argument that is not a default: the query and links as written, in
  monospace; words for the rest (`tool calls`, `this chat`, `subagents`, `10 older`), in the text font. It wraps
  rather than cut (to three lines folded). A read's link gives way to its chat's title once the result is in.
- **The result** is a line per item, then what is not shown (`6 more`, `4 earlier`), which says how much there is
  without a count line of its own; an empty search says `No results`, an empty read `No messages`.

```
History search  "npm run build"   Tool calls                0.2s
durable 示例  $ cd packages/ai && npm run build:offline     10:12
压缩 bug  $ npm run build && npm test                   Yesterday
tau release 0.9  $ cd server && npm run build                 Mon
6 more
```

```
History read  压缩 bug   10 older                            0.1s
4 earlier
Reasoning  identity.js missing from dist: stale build of pi-ai
Bash  npm run hydrate:model-data
Answer  缺了 identity.ts，先 hydrate 模型数据再 build
```

- **A hit** is a line as a code card's call is: the chat's title in semibold 12, the excerpt in monospace 12 cut to
  the line, its time at the right in the dim color (the text node has no tab stops: a space kerned to the width
  places it). The matched words are the title color, brighter than the rest; nothing in the card is the accent. When
  every hit is in one chat the line starts with the part's kind (User, Answer, Reasoning, Call, Output) instead of
  the chat.
- **A message** in a read is a line per part: its kind as a name (User, Output, Reasoning, Answer, Summary for a
  compaction's, Error), then its text. A tool call is named by its tool's card title, and its text is the call
  without the tool's name.
- **Folded**: the first three hits, then `N more` (of the total, so also those on later pages); the last three
  lines, after `N earlier`, as a code card shows the last three calls after "N earlier calls". Each item is one line,
  cut to fit. **Unfolded**: all of those the result has, each item on up to two lines (the first broken at a word,
  the time still at its right), cut after the second; when the result is a page of a larger search, `N more` after
  them is what the search has past it.
- **A tap** folds and unfolds the card, as any tool card's; its lines open nothing (to go to a hit, ask the agent
  for its tau link, which opens it). It has no Show All: unfolded, it is all the result has.
- **Failed**: the title in the destructive color, the error under it (`Not on this server: …`).
- **The model's JSON is not read when cut**: a result past the harness's output limit (a `limit: -1` the model asked
  for, which is a script's thing) shows as its text.
- **In a script**: a line in the code card with the call's first line (`History search  "npm run build" tool calls`),
  as for any nested call.
- **Links in the answer** are the link cards docs/links.md already draws: an answer that cites three places shows
  three cards to tap. Nothing to build.
- **Not shown**: `inContext`, which is for the model; the JSON, which a long press could copy.

## Speed

The index answers in milliseconds (docs/search.md, Speed). What costs is reading each hit's text from its entry for the
excerpt and the exact check: twenty hits are nothing, `limit: -1` over a common word is tens of thousands of reads. A
rare command, the research case, is a few hundred.

`server/bench/search.ts` indexes the pi sessions with their tool calls and the edges of tool output, as the server
does, and times `hits()` (32 cores, Node 24; 1,370 sessions, 322k entries, 346M characters, a 412 MB index; texts from
memory). Reading an entry from the server's SQLite costs more: about 87,000 a second on a copy of chorus's database.

| | hits | relevance, 20 | newest, 20 | all, relevance | all, newest | all, no text | all, no cap |
|---|---|---|---|---|---|---|---|
| a rare word | 8 | <1 ms | <1 ms | <1 ms | <1 ms | <1 ms | <1 ms |
| `"npm run build"` | 126 | 1 ms | 1 ms | 1 ms | 1 ms | 1 ms | 1 ms |
| `error` | 26,019 | 37 ms | 21 ms | 156 ms | 137 ms | 33 ms | 135 ms |
| `the` | 50,000 of 157,054 | 70 ms | 40 ms | 352 ms | 301 ms | 62 ms | 973 ms (relevance 1,158 ms) |

With the reads, `limit: -1` over `error` is about 0.45 s and over `the` 0.9 s (1.8 s more without the cap); with
`text: false` they read nothing. So:

- **`sort: newest`** saves bm25, about 40% of a page over a common word, and little over all of them, where the
  excerpts cost most.
- **Excerpts dominate** `limit: -1`: four to five times the rest. `text: false` is the cheap way to many hits.
- **The cap holds**: lifting it costs in proportion (three times as many hits of `the`, three times the time), and
  only for words common enough that no script means them. Past it the result says `"complete": false`.

## Order of work

1. **`history_read`**: durable's API only (`scanEntries`, `ConversationRecord`, the subagents document,
   `truncate.ts`). Useful alone: an agent reads a link the user pastes, its own history past compaction by paging up,
   a subagent's transcript.
2. **`history_search`** over the index as it is: user, assistant, reasoning and title; `exact` and smart case; the
   cursor.
3. **`tool_call` and `tool_output`** in the index, with a backfill of the existing entries (`backfill-worker.ts` pass).
4. **`sort`, `limit: -1`, the scan cap's `complete`**, after the benchmark; and `text: false`, which the benchmark
   showed is worth having.
5. **The cards** in the app, and their UI tests.

Built: `server/src/history.ts`, `history-text.ts` and the index's `hits()`, `ios/Tau/Chat/HistoryCard.swift`.
`testHistoryCards` (`ios/TauUITests/SendingUITests.swift`) drives the cards with the dev model's `!tool <name>
key=value …`, which calls any tool.

Tests: `server/test/history.test.ts` with the dev model: a conversation compacted, a subagent, a fork; search finds
past the head, in subagents and in the owner; read pages by `older` until it ends; `next` round-trips;
`truncate: false` returns parts whole; a link to another server fails.

## Decided

- **Access.** Any conversation reads any other on its server: a server is one person's. (A draft elsewhere,
  `docs/later.md`, limited `read_transcript` to descendants, owner, and linked threads; not taken.)
- **No count line**: the lines and `N more` / `N earlier` say how much there is; `No results` stands alone. (The
  first build had `9 results` above the lines; it said what the lines said.)
- **`-1` and the scan cap**: the cap holds and a result past it says `"complete": false`; the benchmark (Speed) says
  lifting it costs in proportion, for words no research means.
- **Images** in a read are counted, not read.

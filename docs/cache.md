# Prompt cache warming

A provider keeps the prompt of a request cached for a while: Anthropic for five minutes (an hour with long retention).
The next request that starts with it reads it at a tenth of the input price; once it has expired, the request writes it
again at 1.25 times the price. A run that waits on a long tool call, a build or a test suite, loses it, and the next
request of the run pays for the whole prompt again.

The server keeps it, as pi's coding agent does (`packages/coding-agent/src/core/cache-warmer.ts`): while a run works,
its last request is sent again with a one-token cap shortly before the entry expires, and, in pi's `idle` mode, for half
an hour after the run. `server/src/cache.ts` is the code.

## Modes

Settings > a server > Keep Warm sets pi's three modes for the whole server (`settings.configure { cacheWarming }`):

- **Off**.
- **While Working** (`streaming`): only while a run works.
- **Also When Idle** (`idle`, tau's default): after the run too, for a user's chat (not a subagent's), up to 30 minutes
  after its last request.

## When it refreshes

- **Every request of a conversation's run** starts warming, in place of the request before. Compaction requests and
  titles are not conversation requests.
- **Only models that declare a cache lifetime** (`Model.promptCache`): pi-ai declares it for direct Anthropic only. A
  request that cannot be sent again identically is skipped: Anthropic budget thinking takes its budget from
  `max_tokens`, which the cache is keyed on.
- **At 90% of the lifetime**, keeping ten seconds of margin: 4.5 minutes for Anthropic. A refresh that would go too late
  (after sleep, or a blocked event loop) is not sent; it would write the entry instead of reading it.
- **When it pays**: a refresh goes when the chance of a next request times what a miss costs more than a read (the
  write price less the read price of the last prompt) exceeds the refresh's own cost by $0.05, pi's threshold. While
  the run works the chance is 1; between runs it is pi's measured 15%, so idle warming keeps only big prompts (at
  Claude Opus prices, above about 140k tokens; at Haiku's, never). The idle decision is made when the run ends, so the
  chat says at once whether it is kept.
- **It stops** when the run ends, when another request replaces it, when the context is compacted or reset, when the
  conversation's model changes, or an hour after the request it keeps.


## What it records

- **`tau.cache`**, a conversation document: the entry its last request to a model with a declared lifetime left (that
  model, the lifetime, when the entry was last written or read), and over the conversation's life the refreshes, their
  cost, and what they saved. A refresh saved when the next request read an entry that only refreshes kept: the write it
  avoided, less the read it paid. Compaction and resets clear the entry: the next request sends another prompt.
- **The Dialog's `cache`** (docs/protocol.md): the entry only while its model is the conversation's, since providers
  keep a cache per model and the next request reads that model's; with `warming` while refreshes are scheduled. After
  a switch to another model, or to one that declares no lifetime (all but direct Anthropic), there is none, and switching
  back within the lifetime shows it again. The refresh counters come whatever the model.
- **The usage ledger**: each refresh, as the model `tau/cache-warming`, not as an answer.

## In the app

Nothing in the chat. The title menu's Usage row says "warm" in the accent color while the cache lasts; its submenu has
the Prompt Cache's time left, ticking, then how long ago it expired (only while the chat's model is the cache's), and Kept Warm: how many refreshes, what they cost
and what they saved. The Cost there includes the refreshes. Settings > Usage shows them as Cache Warming.

## Trying it

`--dev-cache-ttl <seconds>` gives the dev model a prompt cache of that lifetime, priced at four times Claude Opus so
that warming its small prompts pays, and adds `dev/echo-uncached`, the same model without a declared lifetime. `SendingUITests.testPromptCache` runs against one on port 7982 with 15 seconds,
which `ios/scripts/sending-tests.sh` and `ios/scripts/uitests.py` start; the server test "keeps a working conversation's prompt cache warm" uses 11.

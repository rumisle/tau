# To do

## Editing a message forks a second chat

Editing a user message forks the conversation before it (`conversation.fork`) and opens the fork; the original stays,
so the list shows two chats of the same title, one more for every edit, with nothing linking them
(`ServerStore.editResolved`, docs/sending.md "Edits and drafts"). Editing the first message makes a new conversation.

This is durable's model: a conversation is one linear, append-only transcript, and the only way to go back and continue
differently is a fork, a new conversation that sees its parent up to an entry (durable README "More Conversations and
Forks"; `test/examples/08-harness-conversations.ts` calls its fork `retry`). Durable records the parent and `parent.at`;
tau's Dialog does not pass them on. `edits` (replace or omit) change what the model sees from then on, in the same
conversation, without going back; `head` only cuts what comes before. pi's coding agent differs: a session is a tree,
and `/tree` continues from an earlier point in the same session, so its list keeps one; only `/fork` makes another.
docs/sending.md says pi's `/tree` works the same way as tau's edit, which is not right.

To decide: how an edited chat and its versions show in the list, for example one row per lineage, showing the newest
version, with the earlier ones reachable from the chat.

## Compress requests to Anthropic

Every turn sends the whole conversation again; Anthropic's API takes it gzipped (`Content-Encoding: gzip`, gzip only:
zstd, br and deflate are refused), and text compresses to a seventh or so (images, already compressed, hardly: about
three quarters, which is the base64 coming back). Claude Code does it since 2.1.300 for bodies over 512 KB, reusing the
compressed blocks of the unchanged prefix each turn (`CLAUDE_CODE_GZIP_REQUEST_BODIES`). It belongs in pi-ai's Anthropic
provider (its SDK takes a `fetch`), as a PR upstream: none is open (October 2026). The Codex provider already sends only
what is new over its WebSocket (`previous_response_id`), and zstd over SSE.


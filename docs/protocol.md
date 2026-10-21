# tau wire protocol (v1)

One WebSocket per client, JSON text frames. The server hosts one pi-durable Harness; the client keeps its own cache
and syncs against it.

## Sync model

Durable keeps two kinds of state per conversation, and they sync differently:

| State | Shape | How it syncs |
|---|---|---|
| **Entries** | Immutable records with globally increasing numeric IDs (`pi.user`, `pi.assistant`, `pi.tool-result`, ...) | The client caches them forever, keyed by ID. It asks only for IDs after the newest it has, and pages older ones on demand. ID order is transcript order, also across a fork's inherited history. |
| **Docs** | Small mutable JSON: `pi.live` (streaming answer, running tools), `pi.inbox` (queued input), `pi.agent`, `pi.usage`, `pi.provider` | Snapshot on subscribe, then ops. Never cached across connections. |

Compare Telegram: entries are messages (cached, gap-filled by ID), docs are ephemeral state such as typing indicators.

Reconnect is therefore cheap: `conversation.subscribe { after: <newest cached ID> }` returns only the missing entries
plus a fresh docs snapshot. When too many entries are missing, the server returns the newest `limit` and a `gap`: the
client marks that ID range unknown (a *hole*) and fills it with `conversation.history` when the user scrolls there.

`serverId` identifies the storage. If it changes, the server's database was replaced and the client drops its cache.

## Frames

```jsonc
// client -> server
{ "id": 1, "method": "conversation.subscribe", "params": { ... } }
// server -> client
{ "id": 1, "result": { ... } }
{ "id": 1, "error": { "code": "not_found", "message": "..." } }
{ "event": "conv.entries", ... }   // push, no id
```

Requests may run concurrently; responses carry the request's `id`. Those that change a conversation (`submit`,
`submission.withdraw`, `submission.abort`, `conversation.abort`, `reset`, `compact`, `configure`) run one at a time
per conversation, in the order they arrived, across connections; creates run one at a time.

Error codes: `bad_request`, `not_found`, `busy`, `unauthorized`, `too_large`, `unsupported`, `withdrawn`, `internal`.
Only `internal` may pass on a retry; the others are final for that request. A frame larger than 96 MB closes the
socket, so a client must not send one (content limits below are far under it).

## Methods

### `hello`
`{ protocol: 1 }` -> `{ protocol: 1, serverId: string, defaultModel: ModelRef, defaultThinkingLevel: string, defaultCwd: string, home: string, hostname: string, piRevision: string, uptime: number }`

`defaultCwd` is where conversations without their own `cwd` run; `home` is the server user's home directory.
`hostname` is the computer's name, `piRevision` the pi commit the server links, `uptime` seconds since it started.

Must be the first request. A different `protocol` is rejected.

### `models.list`
`{}` -> `{ models: { provider, id, name, reasoning, thinkingLevels: string[], contextWindow, input: ("text"|"image")[] }[] }`

Models the server has credentials for. `thinkingLevels` are the levels the model has, `off` first (pi-ai's
`getSupportedThinkingLevels`).

### `client.presence`
`{ active: boolean }` -> `{}`

Whether this client's app is in the foreground, showing its own banners: while any client is, the server pushes
nothing (docs/notifications.md). A closed connection counts as inactive.

### `settings.configure`
`{ defaultModel?: ModelRef, defaultThinkingLevel?: string, ntfy?: { server, topic } | null }` -> `{ defaultModel: ModelRef, defaultThinkingLevel: string }`

`ntfy` sets or clears where answers are pushed; `hello` reports it as `ntfy`.

The model and thinking level new conversations get, for every client; they survive restarts, and the model overrides
the server's `--model`. A create fixes both in the conversation, the level fitted to its model as pi's
`clampThinkingLevel` fits it: changing a default moves no existing conversation. `conversation.configure` fits the
level the same way, and again after a model change.

### `fs.list`
`{ path?: string, hidden?: boolean }` -> `{ path, parent?, entries: DirEntry[], truncated?: true }`

```ts
type DirEntry = { name: string; kind: "dir" | "file" | "link" | "other"; git?: true }; // git: a repository root
```

One directory of the server's file system, for picking a conversation's `cwd`. `path` is absolute or starts with `~`;
default the home directory. Directories come first; links to directories are `dir`. Dotfiles only with `hidden`. At most
2000 entries. `parent` is absent at `/`.

### `dialogs.subscribe`
`{}` -> `{ dialogs: Dialog[] }`, then `dialog` events.

```ts
type Dialog = {
  conversation: ConversationRecord;   // { id, parent?: { conversationId, at }, owner?: { conversationId, taskId } }
  title?: string;
  createdAt?: number;                 // epoch ms
  last?: EntrySummary;                // newest entry; dialogs sort by last.id descending
  agent: { model?: ModelRef; cwd: string }; // effective model and working directory
  busy: boolean;                      // a run is going
  read?: number;                      // the last entry the user has seen
  unreadCount: number;                // assistant messages with text after `read`, at most 99
  markedUnread?: true;                // marked unread by hand
  archived?: true;                    // in Archived Chats, out of the main list
};
type EntrySummary = { id: number; kind: string; role?: string; text: string; timestamp?: number };
```

Conversations owned by a task (subagents) have `owner`; a chat list usually hides them. The server's `subagent` tool
runs them in the background: a spawn creates one, titled after its task, and returns at once; the subagent's answer
comes back later as a user message of the parent, `<subagent name="…" conversation="…" status="answered|failed">answer
</subagent>`, which an app shows as the subagent's card. A spawn may start from a copy of the parent (`fork: true`, the
transcript up to the request) and on another model or effort (`model: "provider/id"`, `thinking`). The call's details
(`pi.live.tools[i].details` while it runs, the `pi.tool-result` entry's `details` after) say which:
`{ name, conversationId, action, model?, thinking?, fork? }`. Subscribe to the conversation like any other to show the
subagent's own transcript.

### `conversation.create`
`{ requestId?: string, title?, autoTitle?: boolean, agent?: AgentPatch }` -> `{ dialog: Dialog }`

With `requestId`, a repeated create (after a lost response) returns the conversation the first one made.

With `autoTitle`, the server names the conversation in a few words after its first answer (with the conversation's
model) and pushes the new title as a `dialog` event; `title` stands in until then.

### `conversation.fork`
`{ conversationId, at: EntryId, title?, requestId? }` -> `{ dialog: Dialog }`

The fork starts read up to `at`, and in the main list. With `requestId`, a repeated fork returns the conversation the
first one made, as for `conversation.create` (the two share their request IDs).

### `conversation.configure`
`{ conversationId, agent: AgentPatch }` -> `{}`

```ts
type AgentPatch = {
  model?: { provider: string; modelId: string } | null;
  thinkingLevel?: "off" | "minimal" | "low" | "medium" | "high" | "xhigh" | null;
  instructions?: string | null;
  cwd?: string | null;
};
```

`null` clears a field back to the server default. `cwd` must be an existing directory, absolute or starting with `~`;
it is stored absolute, and an invalid one fails the request with `bad_request`. A changed `cwd` applies from the next
tool call, also within a running turn.

### `conversation.rename`
`{ conversationId, title }` -> `{}`

A title of 1 to 64 characters, whitespace collapsed. A renamed conversation is never named automatically again, even
by a title being written when the rename arrives.

### `conversation.read`
`{ conversationId, at: EntryId }` -> `{}`

The user has seen the conversation up to `at`: moves `read` forward (never back) and clears `markedUnread`. A client
sends it while the chat is on screen, as entries arrive.

### `conversation.mark`
`{ conversationId, unread?: boolean, archived?: boolean }` -> `{}`

The chat list's actions: `unread: true` is Mark as Unread; `unread: false` is Mark as Read (`read` moves to the newest
entry). `archived` moves the conversation into or out of Archived Chats.

### `conversation.subscribe`
`{ conversationId, after?: EntryId, limit?: number }` ->

```ts
{
  conversation: ConversationRecord;
  docs: Record<string, JsonObject>;   // pi.live, pi.inbox, pi.agent, pi.usage, pi.provider
  entries: EntryRecord[];             // ascending
  head?: EntryId;                     // first entry of the model's active context (after the newest reset/compaction)
  hasOlder: boolean;                  // only without `after`: entries exist before entries[0]
  gap?: { after: EntryId; before: EntryId }; // entries with after < id < before were skipped
}
```

- Without `after`: the newest `limit` entries (default 50, max 500).
- With `after`: every entry with a greater ID, unless there are more than `limit`; then the newest `limit` and a `gap`.

`submissions` lists the conversation's unsettled submissions (`queued`, `placed`).

After the response, the server pushes one frame per commit that touched the conversation, in commit order:

```ts
{
  event: "conv.commit";
  conversationId: number;
  docs?: Record<string, JsonObject>; // replace all docs first (the server fell behind and resynced)
  ops?: Op[];                        // then apply these doc ops; paths are relative to the docs object
  entries?: EntryRecord[];           // new entries, ascending; may repeat ones already received: upsert by ID
  head?: EntryId;                    // a reset or compaction moved the start of the active context
}
```

Apply a frame as a whole before rendering: when a run ends, the frame that removes `pi.live.run` also carries the
answer entry.

Separately, `{ event: "submission", record: SubmissionRecord }` reports a status change of a submission: of every
conversation once `dialogs.subscribe` was called, else of the subscribed ones. It is sent when the change commits and
may arrive before or after the `conv.commit` with the entry it references.

Subscribing again replaces the previous subscription of that conversation.

### `conversation.unsubscribe`
`{ conversationId }` -> `{}`

### `conversation.history`
`{ conversationId, before: EntryId, after?: EntryId, limit?: number }` -> `{ entries: EntryRecord[], hasOlder: boolean }`

Entries with `after < id < before`, newest `limit` (default 50, max 500), ascending. `hasOlder` is true when more
entries remain in that range, below `entries[0]`.

### `conversation.submit`
`{ conversationId, requestId: string, content: string | ContentBlock[], whenBusy?: "steer" | "followUp" | "reject" }`
-> `{ submission: SubmissionRecord }`

`requestId` is client-generated (a UUID) and makes the send idempotent: retrying after a dropped connection returns
the existing submission instead of sending twice. Persist it with the outgoing message until the server acknowledges.

`SubmissionRecord.status`: `queued` (in the inbox) -> `placed` (in the transcript, `entry` set) -> `done` (`answer` set)
or `unanswered` (`reason`: `aborted`, `model_error`, `stale`, ...).

Content is refused before admission, with nothing written: `too_large` over 1,000,000 characters of text, 20 images,
or 5 MB per image; `unsupported` for an image type other than JPEG, PNG, GIF and WebP, or any image when the
conversation's model takes none; `withdrawn` when `submission.withdraw` named the request ID first.

### `submission.withdraw`
`{ conversationId, requestId }` -> `{ result: "withdrawn" | "aborted" | "already_placed" | "settled", submission? }`

Takes back a message by its request ID, whether or not its submit has arrived: `aborted` it left the inbox,
`already_placed` it is in the transcript, `settled` it had ended before (see `submission`), `withdrawn` no submit had
arrived, and one that arrives later is refused with `withdrawn`. This is what makes cancelling a message whose submit
is in flight safe (docs/sending.md).

### `submission.abort`
`{ conversationId, submissionId }` -> `{ result: "aborted" | "already_placed" | "settled" | "not_found" }`

### `conversation.abort`
`{ conversationId }` -> `{}`. Stops the current run and withdraws queued inputs; resolves once idle.

### `conversation.compact`
`{ conversationId, instructions? }` -> `{ taskId }`

### `conversation.reset`
`{ conversationId, handoff? }` -> `{}`

## Ops

Doc changes use Chord's operation format, applied in order. `path` is an array of object keys and array indices.

| Op | Meaning |
|---|---|
| `["r", value]` | Replace the root (the whole `docs` object). |
| `["s", path, value]` | Set the value at `path` (create or replace). |
| `["d", path]` | Delete the key or array element at `path`. |
| `["a", path, text]` | Append `text` to the string at `path` (streaming text). |
| `["t", path, n]` | Remove the first `n` characters of the string at `path` (UTF-16 code units; tool output windows). |
| `["p", path, index, deleteCount, items]` | Splice the array at `path`. |
| `["m", path, permutation]` | Reorder the array at `path`: `new[i] = old[permutation[i]]`. |

## Rendering hints

- `pi.live.generation.message` is the partial assistant message while it streams; it disappears when the final
  `pi.assistant` entry arrives.
- `pi.live.tools[i]` is a running tool call (`status`, streaming `output`); its result arrives as a `pi.tool-result`
  entry, linked by `entry`.
- `pi.inbox.items` are queued inputs not yet in the transcript.
- `pi.system` entries change the system prompt and tools; most UIs hide them.

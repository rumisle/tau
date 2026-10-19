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

Requests may run concurrently; responses carry the request's `id`.

Error codes: `bad_request`, `not_found`, `busy`, `unauthorized`, `internal`.

## Methods

### `hello`
`{ protocol: 1 }` -> `{ protocol: 1, serverId: string, defaultModel?: ModelRef }`

Must be the first request. A different `protocol` is rejected.

### `models.list`
`{}` -> `{ models: { provider, id, name, reasoning, contextWindow, input: ("text"|"image")[] }[] }`

Models the server has credentials for.

### `dialogs.subscribe`
`{}` -> `{ dialogs: Dialog[] }`, then `dialog` events.

```ts
type Dialog = {
  conversation: ConversationRecord;   // { id, parent?: { conversationId, at }, owner?: { conversationId, taskId } }
  title?: string;
  createdAt?: number;                 // epoch ms
  last?: EntrySummary;                // newest entry; dialogs sort by last.id descending
  busy: boolean;                      // a run is going
};
type EntrySummary = { id: number; kind: string; role?: string; text: string; timestamp?: number };
```

Conversations owned by a task (subagents) have `owner`; a chat list usually hides them.

### `conversation.create`
`{ title?, agent?: AgentPatch }` -> `{ dialog: Dialog }`

### `conversation.fork`
`{ conversationId, at: EntryId, title? }` -> `{ dialog: Dialog }`

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

`null` clears a field back to the server default.

### `conversation.rename`
`{ conversationId, title }` -> `{}`

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

Separately, `{ event: "submission", record: SubmissionRecord }` reports a status change of one of the conversation's
submissions. It is sent when the change commits and may arrive before the `conv.commit` with the entry it references.

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

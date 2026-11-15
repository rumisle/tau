# Context files (AGENTS.md)

The `context-files` extension (`server/src/context-files.ts`) puts rule files into the model's prompt through
pi-durable's `agents-md` section. It is installed for both normal conversations and subagents; removing a subagent's
ability to delegate does not remove its context-file rules. It does not change the existing preamble, skills or tools.

## Discovery

Global rules come from `~/.agents` (normally `~/.agents/AGENTS.md`). Tau does not load global rules from
`~/.pi/agent` or use `PI_CODING_AGENT_DIR`. Then directories from the filesystem root down to the conversation's
working directory contribute their rules, in that order.
In each directory, the first regular file in this order wins:

1. `AGENTS.override.md`
2. `AGENTS.md`
3. `AGENTS.MD`
4. `CLAUDE.md`
5. `CLAUDE.MD`

Links are followed and the same real file is included once. Like Pi, a nested linked worktree's context file shadows
the same filename in its main checkout. Other ancestor rules still apply. A BOM at the start of a file is stripped.
The prompt contains each selected file's path and full text.

A project's `<cwd>/.agents/AGENTS.md` is not searched: project rules live directly in each ancestor directory.
The global `~/.agents/AGENTS.md` is searched independently. `.agents/skills` is a separate discovery mechanism;
disabling skills does not remove context-file rules. This loader does not import the Pi CLI or its resource-loading dependencies.

## Updates

Before every model request, durable renders the extension for that conversation's environment. File changes are
visible on the next request. Unchanged output adds no system entry; changed output is sent as a section delta.
Deleting every selected file removes the section. The stored system entries are replayed after a restart.

A non-missing filesystem error is reported through durable's extension error reporting, which retains the previous
section when one exists. There is no previous section to retain on a first-request failure: this is not fail-closed
permission enforcement. Rule text remains model instructions, not a tool/process sandbox.

Discovery follows the conversation's configured cwd, not a directory temporarily entered by a bash command. When
working elsewhere, the preamble still asks the model to read that repository's AGENTS.md explicitly. Only the host,
not a client AgentPatch, can change the conversation cwd. Prompt contents remain server-side; clients receive system
entry IDs without their text, as before.

## Tests

`node --no-warnings --test test/context-files.test.ts` (from `server/`) checks ordering, priority, links, worktrees,
changes/deletions and read errors. A real loopback dev server using the free `dev/echo` model checks prompt injection,
section deltas, host-controlled cwd changes, error retention, client redaction and built-in subagent inheritance.

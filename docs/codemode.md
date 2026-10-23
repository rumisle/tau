# Code mode

The agent can write a script instead of calling tools one at a time: durable's `codemode` tool
(`@earendil-works/pi-durable/codemode`, the coding agent's `docs/codemode.md` for the script's globals). The script is
JavaScript, run in a QuickJS worker with no file system, network or timers; it calls the conversation's tools as
`await tools.bash({ command })`, `tools.read({ path })`, and so on, in parallel when it likes. Each is a real tool call,
nested in the script's: its result goes to the script, and only what the script writes (`text()`, `return`, `image()`,
`console.log`) reaches the model. Reading two hundred files to count something costs the model the count.

The script outlives a restart: durable runs it deterministically and journals each result before the script gets it,
so a new process runs it again with those results and it carries on where it was, its finished calls not run again.

## Setup

`server/src/host.ts` installs `createCodemodeExtension({ sandbox, models: false })` with a `CodemodeSandbox` of 256 MB.

- The other tools stay offered to the model as they were; the script is one more way to call them. Its prompt section
  lists them as TypeScript declarations (a fixed text, so the prompt cache keeps it).
- `models: false`: no classifiers or image models (`models.*`), which need providers tau does not set up.
- Every conversation has it, subagents too. A script cannot start another script (`callers: ["model"]`).

## What the user sees of a script's calls

A nested call's result is not in the transcript: it lives in the script's task until the script ends, then only the
script's result lists its calls, each `{ id, name, args, status, durationMs, error }`, `args` cut at 200 characters.
Most calls need no more. Two tools do something the user should see, and the app shows that from a result's
`details`, which a nested call's never reaches. Called from a script (a nested call's ID is `<call ID>/<key>`), they
record what they did as a display entry, one with `data` and no model messages, which changes nothing the model reads,
even between a tool call and its result (durable's spec, "display-only"; `server/src/shown.ts`):

| Entry | Data | Written by |
|---|---|---|
| `tau.files` | `{ callId, files }`, `files` as `send_file`'s `details.files` | `send_file`, once per call (a rerun after a crash finds it written) |
| `tau.subagent` | `{ callId, action, name, message?, conversationId, model?, thinking?, fork?, at }` | `subagent` spawn, send and stop, in the commit that does it |

They land where the script is, as it runs: the files show while the script still works. A model's own call writes
none; its result says it. Search counts `tau.files` as naming its files, as it does a `send_file` result. A subagent a
script forks starts from the conversation before the script's call, as one the model forks does from its own call.

## In the app

One card, as the other tools' (`ChatMessageItem.codeCardBody`):

```
Code  4 calls                                   1.6s
// Count the rows, then send the file.               <- the script, JavaScript highlighted
const count = await tools.bash({ command: "wc …
…
1 earlier call
Read  tau-ui-code/missing.txt                        <- failed: red, with its error
ENOENT: no such file or directory, open '/tmp/…
Send  scores.csv                                     <- done: quieter
Subagent  checker: check the scores

3 lines                                              <- what it wrote
```

- **Title**: "Code" and its count of calls; the spinner and its time while it runs, as any card.
- **Script**: its first three lines folded, without an `// @options:` line; all of it unfolded.
- **Calls**: each a line as the call's own card would title it (`Bash  <command>`, `Read  <path>`). The one at work is
  bright, with the last line it wrote under it (`pi.live.nestedTools` while the script runs); those done are quieter,
  with their time from a second up; a failed one is red with its error. Folded, the last three, after "N earlier
  calls"; unfolded, all of them.
- **Output**: what the script wrote, without the header the model reads ("Script completed", the wall time,
  "Output:"), the markers between its texts, or the console block's tags; a failed script's error in red, without the
  list of calls the card already has. Images it showed are an album in the card, as a read image is.
- **What it sent and started**: after the card, `tau.files` as `send_file`'s photos and files, `tau.subagent` as the
  subagent's card, its answer paired with it as for the model's own call.

## Trying it

The dev model runs a script for `!code <script>`, or the one in a file for `!code @<path>`, and answers "Ran the
script." after it. `server/test/codemode.test.ts` runs one that calls bash, `send_file` and two subagents (one
forked) and checks the entries; `SendingUITests.testCodemode` checks the card, folded and unfolded, and what it sent.

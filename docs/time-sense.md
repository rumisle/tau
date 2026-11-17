# A sense of time

Status: design, not built. Research and a first proposal for discussion. Nothing here is decided.

Agents waste wall-clock time in a way a person wouldn't. They run a command that blocks the run for half an hour. They
give it a timeout that has nothing to do with how long it should take ("1800"). They `sleep` for minutes and only then
look, often at a job that failed or finished long before. A person who sees a command run ten minutes with no output
wants to know what is going on. The model doesn't seem to feel the time pass at all. Reminding it works for a while,
then it does the same again. This doc measures the behavior in past transcripts and proposes fixing it in the harness.

## The data

**Corpus.** About 1,700 past coding-agent sessions from several harnesses, about 139,000 shell calls. The `recall`
index holds them (zstd-compressed text in SQLite). How long a call ran is the result message's timestamp minus the
call message's. A session's model family is the model it last used.

To compare models fairly, the numbers below come from one harness, where both families had the same tools and system
prompt: 86,664 bash calls by Claude models and 13,727 by GPT models. The scripts are regex heuristics over command
text and output, so treat the numbers as rough.

### 1. Waiting blindly is Claude's habit

| | Claude | GPT |
|---|---|---|
| Calls with `sleep` ≥ 60 s | 3.84% | 0.15% (about 25× fewer) |
| Calls with any `sleep` | 7.33% | 2.35% |
| Calls that ran ≥ 10 min | 767 (0.89%) | 124 (0.90%) |
| ...of which the model's own wait (`sleep`, `until`, `wait`, `tail -f`) | **532 (69%)** | 1 |
| Calls that ran ≥ 30 min | 148 (0.17%) | 6 (0.04%) |

Both families run long commands about equally often. When GPT's calls run long, the work is real: a sweep over
seeds, a large copy. When Claude's run long, most of the time is spent waiting on purpose.

No Claude model has grown out of it; the latest in the table sleeps the most. By model, in the same harness
(seconds of `sleep` written in the commands, a loop's counted once):

| Model | Calls | `sleep` ≥ 60 s | Seconds of `sleep` per call | Calls with a timeout |
|---|---|---|---|---|
| claude-opus-4-6 | 35,339 | 1.14% | 23.5 | 27% |
| claude-opus-5 | 18,446 | 3.11% | 10.1 | 39% |
| claude-opus-4-8 | 13,665 | 9.21% | 21.1 | 43% |
| claude-fable-5 | 11,712 | 6.25% | 17.0 | 52% |
| claude-opus-5-5 | 3,336 | 8.60% | **137.6** | 100% |
| gpt-5.6-sol | 6,472 | 0.11% | 0.6 | 89% |
| gpt-5.3-codex | 2,521 | 0.00% | 0.1 | 30% |
| gpt-5.5 | 2,489 | 0.52% | 1.0 | 94% |

### 2. The sleeps follow a pattern

- The most common long sleeps are 280, 300, 240 and 270 seconds. They sit just under five minutes, the prompt cache's
  lifetime, and under the tool's timeout.
- Some chain sleeps to get around a cap: `sleep 1790; sleep 1790; sleep 1790; …` six times, three hours in one call.

### 3. It often wakes to a job long over

There were 2,726 blind sleeps of two minutes or more (a plain `sleep N`, not inside an `until` or `while` that checks
something). When they woke, the output showed the job had **failed in 13%** of them and **finished in 21%**. When it
ended can't be read back, but the cases are telling:

- `sleep 900 && grep …` over a hyperparameter sweep. Every configuration had failed with an argument error that is
  raised in the first second.
- `sleep 1750`, then a script to read the results, which crashed on a `KeyError`. Half an hour, then a bug that a
  ten-second check would have shown.

### 4. Timeouts are decoration, for both families

| | Claude | GPT |
|---|---|---|
| Calls with any timeout (the parameter or `timeout N`) | 39% | 72% |
| Timeouts of 15 min or more: share of it used, median | 1.4% | 2.2% |
| ...using less than a tenth of it | 77% | 82% |

A timeout isn't set from how long the command should take. It is a number that is "big enough". This is the one
habit both families share. Claude also sets a timeout less often.

### 5. Reminders fade

After the user complained about sleeping in a session, the next sleep of 30 s or more in that session came after 17,
20, 56 and 147 tool calls: between 20 minutes and 14 hours later. One complaint said so itself: "don't you
remember".

### 6. A better path works where reminders don't

From May to September, 5 to 8% of Claude's calls slept 60 s or more. In October the agent instructions gained a
small job runner (below), and the share fell to 0.74%. The runner was used in 11.7% of calls. Short sleeps stayed at
about 12%.

| Month | Calls (Claude) | Any `sleep` | `sleep` ≥ 60 s | Job runner |
|---|---|---|---|---|
| 2026-06 | 7,739 | 12.2% | 7.8% | 0 |
| 2026-07 | 25,438 | 11.5% | 7.0% | 0 |
| 2026-09 | 7,252 | 11.2% | 5.1% | 0 |
| 2026-10 | 19,372 | 12.4% | **0.7%** | 11.7% |

Codex's own exec tool returns after a yield time with a session ID and the command keeps running; the model reads more
with a second call. GPT there almost never sleeps. But GPT rarely sleeps in the shared harness too, so the tool alone
doesn't explain it.

### Limits

- The model is the session's last one.
- Claude models got more of the long training and benchmark work.
- "Failed" and "finished" are read from the output by regex.
- tau's own chats aren't in the corpus.

## Reading of it

The models know what they should do. Told, they do it for a while, then stop. The problem isn't knowledge. Inside a
run the model doesn't experience time passing, and blocking costs it nothing it can see. A rule in the prompt is far
away when the moment comes. A tool's behavior, or an error from the tool, arrives exactly then. So the fix belongs in
the harness, not in the instructions. The path that wastes time should be the awkward one, and the right path the
default.

## What was tried before

- **A job runner** in the agent instructions (`bgjob`): start a command in the background, wait on it with a bounded
  `wait`, read its log. It is level-triggered: the job's state is a file and a lock its supervisor holds for its
  lifetime, so a wait never misses an ending and can be repeated. It cut long sleeps by about ten times (6. above). It
  is still a second tool the model must choose to use, its commands are verbose, and it lives outside the harness, so
  the app can't show the jobs.
- **Time stamps** on tool results in another harness, `[ended 14:32:05, took 12s]`, and on user messages, behind an
  option. Never tried with a real model.
- **A short default foreground timeout** (2 min), as a penalty for guessing wrong: it kills work, and the model then
  retries with a bigger number.

## Proposal: commands yield instead of timing out

1. **bash returns after 30 s, without killing the command.** A command still running at 30 s keeps going in its own
   scope (docs/command-isolation.md), and the call returns: `still running, job 3, 30s, last lines: …`. The `timeout`
   parameter goes away, and with it the decorative numbers. A command may ask for a longer yield, up to 2 min. Nine
   commands in ten end within a minute and see no change.
2. **A `job` tool**: `wait`, `output`, `kill`, `list`. `wait` returns at the first of:
   - the command ends;
   - its output matches a pattern given to the wait;
   - a cap of about 4 to 5 minutes, so the prompt cache stays warm;
   - **a message from the user, or a subagent's report**. Today, while the agent sleeps, nothing the user says reaches
     it until the sleep ends.

   Each return says how long the job has run and how long it has been silent: `running 12m, no output for 9m`. A
   person reading that would go and look.
3. **Ending the turn instead of waiting.** The agent can end its turn with a job running. When the job ends, its
   result comes back the way a subagent's report does (src/subagent.ts) and wakes the chat. tau's cache warming
   (docs/cache.md) keeps the cache, so the agent doesn't need `sleep 280` for it.
4. **Every tool result says how long it took**, `took 14m 3s`: about ten tokens. It doesn't change the cache, since a
   result never changes once written.
5. **`sleep` of 60 s or more in a command is refused**, with a pointer to `job wait`. The rule arrives at the moment it
   is broken, where it is hardest to forget. The threshold is a setting.

In the app and the web client, a running job shows the way a subagent does: working, with its time, and it can be
stopped. Inside tau this replaces `bgjob`.

## Open questions

1. **The yield.** 30 s by default, a command may ask for up to 2 min?
2. **Stop.** Kill a command that hasn't yielded yet, and keep jobs, each stoppable on its own?
3. **Restarts.** Should jobs survive a server restart? Then they need transient services rather than scopes, which
   docs/command-isolation.md already asks of `bgjob` v2. Otherwise a restart reports each job as lost.
4. **`sleep`.** Refuse it or only warn? Which threshold?
5. **Where it lives.** In tau's `src/commands.ts` first; proposed to durable's coding tools upstream once it holds up.

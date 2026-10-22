# Skills

Skills (https://agentskills.io) are folders with a `SKILL.md` whose front matter names the skill and says when to use
it. The system prompt lists them; the model reads a skill's file with the read tool when a task matches, as pi's coding
agent does (`packages/coding-agent/src/core/skills.ts`, whose discovery and prompt `server/src/skills.ts` follows).

## Where

`.agents/skills` only: the server user's (`~/.agents/skills`), then the conversation directory's
(`<cwd>/.agents/skills`). A name both have is the user's; a file reached twice (a symbolic link, as
`agent-config/install.sh` makes) counts once. A directory with a `SKILL.md` is a skill and is not searched further;
others are searched four levels down, without hidden directories and `node_modules`. A skill needs a `description`
(at most 1024 characters); its name is the front matter's `name`, or its directory's. `disable-model-invocation: true`
leaves it out. Front matter that is not valid YAML leaves the skill out, as pi does, with a warning in the server's log
once per version of the file; the usual cause is a plain `description:` with `: ` in it, which YAML reads as a mapping
(quote it).

## In the prompt

Durable has no skills of its own: the system prompt is the sections of the selected extensions (spec §7). tau's
extension has a `skills` section after `preamble` and `cwd`, pi's block:

```
The following skills provide specialized instructions for specific tasks.
Use the read tool to load a skill's file when the task matches its description.
When a skill file references a relative path, resolve it against the skill directory …

<available_skills>
  <skill>
    <name>exa</name>
    <description>Web search, content retrieval, …</description>
    <location>/home/remote/.agents/skills/exa/SKILL.md</location>
  </skill>
  …
</available_skills>
```

Sections render at each request. Durable compares the text with what the transcript already shows and appends a
system delta (a `pi.system` entry) only when it changed, so the render must give the same text for the same skills:
they are sorted by name, nothing in it depends on time, and a skill that cannot be read is left out rather than shown
with an error. A skill added, changed or removed reaches the next request of every conversation as one delta; the
prompt before it stays cached. Front matter is parsed again only when a file's size or modification time changes.
With no skills the section is absent.

## The server's environment

Skills call tools with keys from the environment (`EXA_API_KEY`, `SERPER_API_KEY`, …), which the agent's commands
inherit from the server. On remote they are set in `~/.zshrc`, so the server runs through a login, interactive zsh
(`server/contrib/tau-server.service`), as ocelot's does.

## Tests

`server/test/compaction.test.ts` (describe "skills"): discovery, precedence and links; front matter; and that the
skills reach the prompt as one delta when a skill is added, and none when nothing changed.

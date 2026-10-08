# Dream
<!-- registry: the bank of good answers, in a platform sequence and one per soul; capture and sign-off -->

## Status: Active

The shared `dream` SOP. A **dream** is one worked decision from a past session:
the question the session faced, the good answer, and why that answer was right.
A session reads approved dreams beside the documentation, so it meets a familiar
situation already knowing how a good session answered it.

Docs say what the rules are. Dreams show judgment being used.

## Two sequences

| Sequence | Holds | Loads | Lives in |
|---|---|---|---|
| **Platform** | the universal decisions, then the helper roster: which soul does which work and how to brief one | at every session start | `docs/agents/dreams/platform/` |
| **A soul's** | that seat's own decisions | when the soul is invoked or launched as a subagent | `docs/agents/dreams/<soul>/` |

A soul's skills are its dream sequence plus its role page. The `soul` tag decides
the sequence: a dream with no `soul` tag is platform. A dream tagged for several
souls loads in each of their sequences and lives under the first. Directories use
the `config/souls.yml` slugs (`turf-monster`, `xan`).
[`../dreams/INDEX.md`](../dreams/INDEX.md) lists every dream by sequence.

## How a dream differs from its neighbours

| | What it holds | Who admits it | Where it lives |
|---|---|---|---|
| **Dream** | a question, a good answer, the reason, the story | Alex signs off each one | `docs/agents/dreams/<sequence>/<slug>.md`, tracked |
| **Insight** | a one-line lesson graded from an activity | Xan banks it (`grade-events`) | the board's Insight Bank |
| **Provider memory** | one session's private notes | nobody | `~/.claude/…/memory/`, scratch |

A dream is the only one of the three that carries its reasoning, and the only one
Alex approves by hand.

## Act 1 — Dream (every session start, and every soul)

The platform sequence loads automatically. `bin/session-insights`, wired as the
SessionStart hook for Claude and Codex, prints a `## Dreams` block and a
`### Helper agents` roster ahead of the insights. It reads the tracked files, so
it needs no token and no board.

A soul's sequence loads when the soul takes its seat. Each of these prints it:

| Command | Prints to |
|---|---|
| `bin/task begin … --agent <soul>` | stderr |
| `bin/task review-claim acquire <slug> --agent <soul>` | stderr |
| `bin/task claim-next-review --agent <soul>` | stderr; stdout stays the slug |
| `bin/agent-activity heartbeat <soul>` | stdout |
| `bin/dream <soul> [--task <slug>]` | stdout |

The two review commands also use the session's acting soul when `--agent` is
absent. A soul with no approved dream prints nothing from the first four.

1. Read the whole block before your first decision.
2. When your situation matches a dream's question, answer it the same way, or
   say why this case differs.
3. A subagent launched as a soul runs `bin/dream <soul>` first.
4. If the session-start block is missing (a runtime with no hook, a hook
   failure), print it yourself:

   ```bash
   /Users/alex/projects/.agents/bin/dream platform
   ```

Only `status: approved` dreams load. A dream never overrides a First Rule or an
SOP: where they disagree, the rule wins and the dream is wrong.

### The ceiling: about 25 platform dreams load by themselves

Claude Code caps a hook's context at **10,000 characters**. Over that, the model
gets a file path and a 2,000-character preview, and nearly everything is lost
without a word. Dreams and insights share that one string, so the loader budgets
it (`SessionInsights::CONTEXT_BUDGET`, 9,800):

1. The insights are fetched first and kept whole. They are never trimmed for a dream.
2. The platform dreams take what is left, and degrade on purpose:
   - every dream with its Why, while that fits (about 16 dreams beside a full feed);
   - then every dream as question and answer only (about 25);
   - then as many as fit, with a closing line that says how many were left out
     and tells the session to read `docs/agents/dreams/`.
3. The helper roster is added only when it fits after the dreams. It never costs
   a dream or a Why line.

`test/lib/session_insights_test.rb` pins the real platform sequence beside a full
insight feed under the cap, with every dream and the roster present. The dream
that tips it over fails CI; it does not truncate in production. When that test
goes red, shorten a dream, retire one, or tag it for the soul it belongs to.

So the platform sequence is a curated set of about 25, not 100. A soul's sequence
has no cap: it prints whole, with every Why. A loader that picks dreams by
relevance is not built. Codex's hook limit has not been measured.

## Act 2 — Capture (when a session earns one)

Propose a dream when one of these happens:

- Alex says "good call", or accepts a recommendation that went against the
  obvious move.
- A review, or Alex, catches a decision that was wrong, and the right answer is
  now clear. A dream may be born from a bad decision; it records the good one,
  and its story says plainly that the session got it wrong.
- You chose not to do something tempting, and the reason would transfer.

Write the file in your task's desk, under `docs/agents/dreams/platform/` or the
soul's directory. Let it ride a change that is already going through the cycle,
or open a `docs` task for it. Run `bin/dream index --write` and commit the index
with it.

```markdown
---
question: "The situation, asked in the first person as the session meets it?"
answer: "What to do, in one or two sentences."
why: "The measured cost or the fact that makes the answer right."
status: proposed
source: "2026-10-04 · task slug or session"
soul: carl
topic: [review, merge]
---

# Title

## Situation
## The pull
## What happened
```

Tags are optional, and each takes one value or a list of lowercase tokens:

| Tag | Says | Checked against |
|---|---|---|
| `soul` | whose sequence loads the dream; absent means platform | `config/souls.yml` slugs |
| `repo` | the app it is about | not checked |
| `shape` | the feature shape it applies to | not checked |
| `risk` | the risk tag it applies to | not checked |
| `stage` | the task stage it applies at | not checked |
| `topic` | free words for the index | not checked |

A file with an unknown front matter key, an unknown soul, or a tag value that is
not one token loads nowhere. `test/lib/dream_bank_test.rb` fails on it, on a
dream filed under the wrong directory, and on a stale index.

Rules for a dream:

- **One decision.** If it needs "and also", it is two dreams.
- **The question is the trigger.** Write it the way a future session will feel
  it, before it knows the answer.
- **The pull is named.** Say what the tempting move was. A dream with no
  temptation is a fact, and facts belong in the docs.
- **No live data.** This repo is public. No real names of counterparties, no
  figures from a deal, no contact details, no keys or addresses.
- **No security detail.** Do not name a weakness that may still be open (which
  key is shared, what leaked). Say that one was found.
- **Short.** Question, answer and why together stay under about 400 characters;
  every character is spent out of the ceiling above.
- **New dreams are `proposed`.** Never write `approved` yourself.

## Act 3 — Sign-off (Alex)

Alex approves each dream. Present the proposed ones as a numbered table (slug,
question, answer) and ask which to approve, change or drop.

- Approved: set `status: approved`. The dream loads once the release that
  carries it ships, because the hook reads the bank installed with the tooling.
- Dropped: delete the file.
- An agent never flips a dream to `approved` without Alex's word in that session.

## When Alex says `dream`

Run Acts 2 and 3 for the current session: list the decisions from this session
worth keeping, write them as `proposed`, show any other proposed dreams still
waiting, and ask for sign-off.

## Files

| Piece | Path |
|---|---|
| The bank | `docs/agents/dreams/platform/`, `docs/agents/dreams/<soul>/` |
| Generated index | `docs/agents/dreams/INDEX.md` (`bin/dream index --write`) |
| Parser, sequences and formatter | `bin/lib/dream_bank.rb` |
| Session-start loader | `bin/session-insights` |
| Soul loader | `bin/dream` |
| Installed copy the hook reads | `bin/install-agent-docs` (`TOOLING_PATHS`) |
| Tests | `test/lib/dream_bank_test.rb`, `test/lib/dream_cli_test.rb`, `test/lib/session_insights_test.rb` |

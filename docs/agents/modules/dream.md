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

A soul's dreams load when the soul takes its seat. A command that names a task
prints the dreams selected for that task ([below](#a-claim-loads-the-dreams-that-match-its-task));
the others print the soul's whole sequence:

| Command | Prints | To |
|---|---|---|
| `bin/task begin … --agent <soul>` | the selected set | stderr |
| `bin/task review-claim acquire <slug> --agent <soul>` | the selected set | stderr |
| `bin/task claim-next-review --agent <soul>` | the selected set | stderr; stdout stays the slug |
| `bin/dream <soul> --task <slug>` | the selected set | stdout |
| `bin/agent-activity heartbeat <soul>` | the whole sequence | stdout |
| `bin/dream <soul>` | the whole sequence | stdout |

The two review commands also use the session's acting soul when `--agent` is
absent. A soul with no approved dream prints nothing from the three claim
commands and the heartbeat.

1. Read the whole block before your first decision.
2. When your situation matches a dream's question, answer it the same way, or
   say why this case differs.
3. A subagent launched as a soul runs `bin/dream <soul>` first, with
   `--task <slug>` when it was handed a task.
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

So the platform sequence is a curated set of about 25, and the bank grows in the
souls' sequences, which load by relevance. Codex's hook limit has not been
measured.

### A claim loads the dreams that match its task

A claim reads the task from the board and scores each of the soul's approved
dreams against it (`bin/lib/dream_selector.rb`):

| The dream's tag | Scores | When |
|---|---|---|
| `repo` | 3 | the task names that repository |
| `risk` | 3 | the task carries that risk tag |
| `shape` | 2 | the task has that shape |
| `stage` | 1 | the task is at that stage: `building` at a begin, `submitted` at a review |
| `topic` | 1 a word, 3 at most | the word is in the task's title or acceptance |

A tag value the task does not carry scores 0. Topic words are compared in lower
case, without a short list of stop words, and a plural matches its singular.

The claim prints the 12 highest scores in rank order, ties in slug order, then
the platform sequence under `### Platform dreams`. A soul with 12 dreams or fewer
is shown them all. The block stays within 6,000 characters
(`DreamBank::CALL_BUDGET`) and degrades in this order:

1. every dream with its Why;
2. the selected dreams with their Why, the platform dreams without;
3. no Why lines;
4. whole dreams dropped from the lowest rank up, the platform dreams last.

The last line counts every approved dream the block does not show, in any
sequence, and names the command that lists them:

```text
6 not shown: bin/dream list --task <slug>
```

`bin/dream list --task <slug>` prints every approved dream with its score for the
task and the path of its file. `bin/dream list` prints them unranked.

Selection never fails a claim. When the task cannot be read, the claim prints the
soul's whole sequence and `bin/dream` says so on stderr. When the bank cannot be
read, the claim prints no dreams. The exit code is the claim's own.

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
| `topic` | free words, matched against the task's title and acceptance | not checked |

On a soul's dream the last five tags decide which claims load it. Spell each
value as the board spells it (`turf-monster`, `payment`, `ui+db`, `submitted`).

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
  every character is spent out of the ceiling above or a claim's 6,000.
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
| Selector | `bin/lib/dream_selector.rb` |
| Session-start loader | `bin/session-insights` |
| Soul loader and list | `bin/dream` |
| Installed copy the hook reads | `bin/install-agent-docs` (`TOOLING_PATHS`) |
| Tests | `test/lib/dream_bank_test.rb`, `test/lib/dream_selector_test.rb`, `test/lib/dream_cli_test.rb`, `test/lib/session_insights_test.rb` |
| Fixture bank the selector tests read | `test/fixtures/dreams/` |

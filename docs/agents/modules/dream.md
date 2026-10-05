# Dream

## Status: Active

The shared `dream` SOP. A **dream** is one worked decision from a past session:
the question the session faced, the good answer, and why that answer was right.
Every new session reads the approved dreams at start, beside the documentation,
so it meets a familiar situation already knowing how a good session answered it.

Docs say what the rules are. Dreams show judgment being used.

## How a dream differs from its neighbours

| | What it holds | Who admits it | Where it lives |
|---|---|---|---|
| **Dream** | a question, a good answer, the reason, the story | Alex signs off each one | `docs/agents/dreams/<slug>.md`, tracked |
| **Insight** | a one-line lesson graded from an activity | Xan banks it (`grade-events`) | the board's Insight Bank |
| **Provider memory** | one session's private notes | nobody | `~/.claude/…/memory/`, scratch |

A dream is the only one of the three that carries its reasoning, and the only one
Alex approves by hand.

## Act 1 — Dream (every session start)

The loading is automatic. `bin/session-insights`, already wired as the
SessionStart hook for Claude and Codex, prints a `## Dreams` block ahead of the
insights. It reads the tracked files, so it needs no token and no board.

1. Read the whole block before your first decision.
2. When your situation matches a dream's question, answer it the same way, or
   say why this case differs.
3. If the block is missing (a runtime with no hook, a hook failure), read the
   bank yourself. This prints every approved dream:

   ```bash
   cd /Users/alex/projects/mcritchie-studio
   ruby -Ibin/lib -rdream_bank -e 'puts DreamBank.context(DreamBank.approved)'
   ```

Only `status: approved` dreams load. A dream never overrides a First Rule or an
SOP: where they disagree, the rule wins and the dream is wrong.

### The ceiling: about 25 dreams load by themselves

Claude Code caps a hook's context at **10,000 characters**. Over that, the model
gets a file path and a 2,000-character preview, and nearly everything is lost
without a word. Dreams and insights share that one string, so the loader budgets
it (`SessionInsights::CONTEXT_BUDGET`, 9,800):

1. The insights are fetched first and kept whole. They are never trimmed for a dream.
2. The dreams take what is left, and degrade on purpose:
   - every dream with its Why, while that fits (about 16 dreams beside a full feed);
   - then every dream as question and answer only (about 25);
   - then as many as fit, with a closing line that says how many were left out
     and tells the session to read `docs/agents/dreams/`.

`test/lib/session_insights_test.rb` pins the real bank beside a full insight feed
under the cap with every dream present. The dream that tips the bank over fails
CI; it does not truncate in production. When that test goes red, shorten a dream
or retire one.

So the always-loaded bank is a curated set of about 25, not 100. Today's 20 load
as question and answer; their Why lines stay in the files. A larger bank
needs the session to read the files itself (the closing line asks for that), or a
loader that picks dreams by relevance. Neither is built. Codex's hook limit has
not been measured.

## Act 2 — Capture (when a session earns one)

Propose a dream when one of these happens:

- Alex says "good call", or accepts a recommendation that went against the
  obvious move.
- A review, or Alex, catches a decision that was wrong, and the right answer is
  now clear. A dream may be born from a bad decision; it records the good one,
  and its story says plainly that the session got it wrong.
- You chose not to do something tempting, and the reason would transfer.

Write the file in your task's desk. Let it ride a change that is already going
through the cycle, or open a `docs` task for it.

```markdown
---
question: "The situation, asked in the first person as the session meets it?"
answer: "What to do, in one or two sentences."
why: "The measured cost or the fact that makes the answer right."
status: proposed
source: "2026-10-04 · task slug or session"
---

# Title

## Situation
## The pull
## What happened
```

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

- Approved: set `status: approved`. The dream loads from the next session after
  it reaches `main`.
- Dropped: delete the file.
- An agent never flips a dream to `approved` without Alex's word in that session.

## When Alex says `dream`

Run Acts 2 and 3 for the current session: list the decisions from this session
worth keeping, write them as `proposed`, show any other proposed dreams still
waiting, and ask for sign-off.

## Files

| Piece | Path |
|---|---|
| The bank | `docs/agents/dreams/` |
| Parser and formatter | `bin/lib/dream_bank.rb` |
| Session-start loader | `bin/session-insights` |
| Tests | `test/lib/dream_bank_test.rb`, `test/lib/session_insights_test.rb` |

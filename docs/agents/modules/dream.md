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

Only `status: approved` dreams load. The block costs about 100 tokens a dream, so
a bank of 100 is roughly 10,000 tokens at every session start. Keep each dream
short enough that the whole bank stays worth reading.

## Act 2 — Capture (when a session earns one)

Propose a dream when one of these happens:

- Alex says "good call", or accepts a recommendation that went against the
  obvious move.
- A review, or Alex, catches a decision that was wrong, and the right answer is
  now clear. A dream may be born from a bad decision; it records the good one.
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

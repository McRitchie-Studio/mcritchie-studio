# Memory System

## The Insight Bank is canonical (distilled lessons)

The curated, cross-agent **lessons** live in the **Insight Bank** — the banked
`ActionGrade` rows (`ActionGrade.banked`), graded from real agent trajectories.
The bank is the **single source of truth**; the tracked doc
[`docs/agents/shared/insights.md`](../shared/insights.md) is **GENERATED** from it
(`bin/rails insights:doc`) and must **not** be hand-edited.

- **Curate a lesson** — bank it: `bin/atomic-event grade <span> --disposition
  good|not --slug "<4–7 words>" [--long-form "<anchor>"] --bank` (Alex heartbeat
  `grade-events`). The audit-of-Alex (`grader: mcr`) is McRitchie's admin path.
- **Feed it forward** — a fresh session loads the top-N via `bin/session-insights`
  (SessionStart), so a new agent hatches already knowing them.
- **Regenerate the doc** — `bin/rails insights:doc` (post-deploy / on demand).

Because the bank is canonical and generated, **hand-edited lesson lists are
retired** — `docs/agents/shared/MEMORY.md` is a pointer stub, and local provider
memory (`~/.claude/projects/*/memory/MEMORY.md`) is scratch history, never a source
of truth. Don't hand-write a lesson into a doc; **bank it** so every runtime
(Claude, Codex) sees the same set.

## Agent-Specific Memory

Durable agent-specific memory belongs in tracked docs under
`docs/agents/agents/<agent-id>/`. System-wide *lessons* go in the **Insight Bank**
(above), not a hand-edited file. Local provider memory such as
`~/.claude/projects/*/memory/MEMORY.md` can be useful scratch history, but it is
not a source of truth.

Agent-specific memory includes:
- Task context and progress notes
- Learned patterns from repeated operations
- Environment-specific configuration

## What to Remember
- Stable patterns confirmed across multiple interactions
- Key architectural decisions and file paths
- Solutions to recurring problems
- User preferences for workflow and communication

## What NOT to Remember
- Session-specific context (current task details, temporary state)
- Unverified conclusions from reading a single file
- Anything that duplicates `AGENTS.md` or canonical repo docs

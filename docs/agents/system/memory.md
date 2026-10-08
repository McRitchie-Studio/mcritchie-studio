# Memory System

## The Insight Bank is canonical (distilled lessons)

The curated, cross-agent **lessons** live in the **Insight Bank** — the banked
`ActionGrade` rows (`ActionGrade.banked`), graded from real agent trajectories.
The bank is the **single source of truth**; the tracked doc
[`docs/agents/shared/insights.md`](../shared/insights.md) is **GENERATED** from it
(`bin/rails insights:doc`) and must **not** be hand-edited.

- **Curate a lesson** — bank it: `bin/agent-activity grade <activity-id> --disposition
  good|not --slug "<4–7 words>" [--long-form "<anchor>"] --bank` (Xan heartbeat
  `grade-events`). The audit-of-Xan (`grader: mcr`) is Alex's admin path.
- **Feed it forward** — a fresh session loads the top-N via the `bin/session-insights`
  SessionStart loader, which GETs `/api/v1/insights`, so a new agent hatches already
  knowing them. Banking a lesson is what publishes it; the tracked doc below is the
  readable record, not the delivery path.
- **Regenerate the doc** — `bin/rails insights:doc`, pointed at the **board's**
  database. The generator reads whatever `DATABASE_URL` your shell carries, and a
  primary checkout or a desk worktree reads an EMPTY local one — writing a
  confident `0 banked insights` over a doc that was right. The exact command, and
  the independent count check that proves it read the bank, are in
  [`share-insights.md`](../agents/xan/sops/share-insights.md).
- **Staleness is detected, not remembered** — `InsightsDocFreshnessJob` runs
  weekly on the board (`config/recurring.yml`) and writes an **ErrorLog** receipt
  when the doc's recorded count diverges from the bank, when the bank has been
  curated since the doc was generated, or when the generated header stops being
  machine-readable. The board is the only environment that holds both halves of
  that comparison: CI and every desk have the doc but an empty database.

Because the bank is canonical and generated, **hand-edited lesson lists are
retired**; `docs/agents/shared/MEMORY.md` is a pointer stub. Two kinds of knowledge
go to two places. A **durable operating rule about a mechanism** goes into the
module or SOP that owns that mechanism, in the same PR, verified against the code.
A **graded lesson from a past session** goes into the Insight Bank, so every
runtime (Claude, Codex) sees the same set. Local provider memory
(`~/.claude/projects/*/memory/`) is scratch, never a source of truth; once one of
its rules is promoted, the memory file points at the owning doc.

## The dream bank (worked decisions)

A lesson says what to do. A **dream** shows a decision being made: the question a
session faced, the good answer, and why. Dreams are tracked files in
[`docs/agents/dreams/`](../dreams/README.md), each one signed off by Alex, and the
same `bin/session-insights` loader prints the approved platform sequence ahead
of the insights; a soul's own sequence prints when the soul is invoked
(`bin/dream <soul>`). They are read locally, so they load with the board
unreachable. About 25 platform dreams load by themselves, because a hook's context is capped at 10,000 characters. Procedure:
[`dream.md`](../modules/dream.md).

## Agent-Specific Memory

Durable agent-specific memory belongs in tracked docs under
`docs/agents/agents/<agent-id>/`. A system-wide operating rule goes into the module
that owns its mechanism; a graded lesson goes into the **Insight Bank** (above).
Local provider memory such as `~/.claude/projects/*/memory/MEMORY.md` is scratch:
it is not a source of truth, and a promoted note points at its owning doc.

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

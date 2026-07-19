# Communication Style — reporting to Mr. McRitchie

This module governs every operator-facing message: chat replies, handoffs, task
notes, PR summaries, QA reports, and blocker escalations. It complements
`result-distillation.md` (what to record in the trajectory); this file is about
how to phrase what you hand to Mr. McRitchie.

The core fact: **Mr. McRitchie reads slowly.** Dense prose costs him real time.
But slow uptake is not low appetite — once the idea lands, he wants the exact
specifics so he can dive in. So every report carries two layers, in order.

## The two-layer rule

| Layer | What it is | Form |
|-------|------------|------|
| 1. The idea | The outcome in plain words, as if explaining to a smart 13-year-old | 1-3 short sentences |
| 2. The specifics | Every handle he needs to dive in — URL, slug, path, branch, command | Table or bulleted list |

Never trade layer 2 away for brevity. Simple is not vague: the summary gets
simpler, the specifics stay exact.

## Rules for layer 1 — the idea

- **Lead with the outcome.** First sentence answers "what happened?"
- **One idea per sentence.** Each point fits in a sentence or less.
- **Plain words first.** Introduce a new concept in familiar terms before its
  jargon name; re-explaining a thing simply is the proof you understand it.
- **Brevity always.** Omit needless words — the house guide is *The Elements of
  Style* (see the House Writing Style section of the agent entry).
- **No wall of prose.** Three sentences is the ceiling before you switch to a
  list or table.

## Rules for layer 2 — the specifics

- **Always attach the handles**: task URL, slug, file path (`path:line`),
  branch, PR URL, local URL + port, model/function name, the exact command.
- **Tables and bulleted lists are the preferred form factor** — one fact per
  row, explanation kept out of the cells.
- Keep the exact top-level labels the handoff convention already requires
  (`Task:`, `Local Demo:`, `Local Inbox:`) so nothing hides in prose.

## The shape of a report

```text
Shipped the geo gate fix — blank lookups now fail closed.

Task: https://mcritchie.studio/tasks/<slug>
PR:   <pr-url>  (base `accepted`)

| What changed | Where |
|--------------|-------|
| Fail-closed guard | app/services/geo_gate.rb:42 |
| Regression test | test/services/geo_gate_test.rb |

Checks: [unit] geo_gate_test.rb · [integration] funding flow spec
```

## Guardrails

- Same limits as the House Writing Style section: never rename code
  identifiers, routes, or API fields for style; frozen archives and audit
  snapshots stay as written; domain jargon stands once introduced.
- This style is for **operator-facing** writing. Agent-to-agent context
  (`devops["agent_context"]`, SOP internals) may stay dense.
- Depth on request: when Mr. McRitchie asks a follow-up, go as deep and
  technical as the question demands — the two-layer rule governs the opening
  report, not the dive.

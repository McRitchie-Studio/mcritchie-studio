# Grade Events

## Status: Optional — not a heartbeat act since 2026-09-25

Every task is now graded once when it ships (`Insights::TaskGrader`; thresholds in
`config/learning_loop.yml`), so this manual act runs only when Alex asks
for it by name.

## The learning loop, in three parts

This page owns the learning capability. It runs in three parts:

1. **Every task is graded at ship, automatically.** When a task moves to
   `shipped`, `Insights::TaskGrader` grades it once from facts already on the
   board: bounces, gate failures, escalations, cost, and build and review time.
   The thresholds live in `config/learning_loop.yml`; change a number there, not
   in code. Nothing tripped means "nothing to learn", and nothing is written.
   Something tripped writes ONE learning line, as a task note and as a banked
   insight that `bin/session-insights` serves. No one runs this by hand.
2. **Grade recent activities by hand, only when named.** This SOP, below.
3. **Share the bank out.** [`share-insights.md`](share-insights.md) regenerates
   the lessons doc from the banked insights.

This is Xan's `grade-events` SOP. It grades recent resolved trajectory activities so
useful agent behavior can become reusable memory.

## Scope

This SOP is part of Xan's learning loop. It does not review PRs, merge release
work, deploy QA, ship production, or archive work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

Resolved agent activities are awaiting Xan's grade. If none are waiting,
report "nothing to grade" and stop.

## Procedure

Review the waiting queue:

```bash
bin/agent-activity awaiting --limit 10
```

Grade the oldest waiting activities first:

```bash
bin/agent-activity grade <activity-id> --disposition good --slug "<4-7 words>" --bank
bin/agent-activity grade <activity-id> --disposition not --slug "<4-7 words>" --discard
```

Bank only insights that make the next agent smarter. Discard generic narration,
routine success, and anything that should not become instruction.

The browser path at `/xan/heartbeat` is the operator/admin equivalent. The CLI
grades as Xan; Alex's confirmation lane remains in the browser
pipeline.

## Exit Seam

About 10 activities are graded, with useful insights banked and weak ones discarded.
Report how many were banked and discarded.

## Related

- [`share-insights.md`](share-insights.md) - shares the banked insights (the bank
  is `ActionGrade.banked`, whichever grader recorded each row).

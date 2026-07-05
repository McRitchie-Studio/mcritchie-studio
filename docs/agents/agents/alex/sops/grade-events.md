# Grade Events

## Status: Active

This is Alex's `grade-events` SOP. It grades recent resolved trajectory activities so
useful agent behavior can become reusable memory.

## Scope

This SOP is part of Alex's learning loop. It does not review PRs, merge release
work, deploy QA, ship production, or archive work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

Resolved agent activities are awaiting Alex's grade. If none are waiting,
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

The browser path at `/alex/heartbeat` is the operator/admin equivalent. The CLI
grades as Alex; Mr. McRitchie's confirmation lane remains in the browser
pipeline.

## Exit Seam

About 10 activities are graded, with useful insights banked and weak ones discarded.
Report how many were banked and discarded.

## Related

- [`share-insights.md`](share-insights.md) - shares Mr. McRitchie's confirmed
  insights.

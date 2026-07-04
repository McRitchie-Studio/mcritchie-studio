# PR Review Slow

## Status: Active

This is Avi's `pr-review-slow` SOP. It runs the same review-only loop as
`pr-review`, serialized one PR at a time.

## Scope

Use this SOP when submitted work is arriving in a trickle or parallel waves would
thrash the board. It does not merge PRs, deploy QA, ship production, or archive
work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

At least one task is in `submitted`. If the queue is empty, report "no submitted
PRs" and stop.

## Procedure

Run the serialized supervisor path:

```bash
bin/avi-heartbeat --run --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

This is the same review-only loop as [`pr-review.md`](pr-review.md), but one
task at a time. It re-queries the board between tasks and exits when the queue
drains.

## Exit Seam

Every visible `submitted` PR is `reviewed`, `blocked`, or explicitly deferred
with a reason. Report the result per task.

## Related

- [`pr-review.md`](pr-review.md) - bounded-wave version of this SOP.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) -
  single-PR review primitive.

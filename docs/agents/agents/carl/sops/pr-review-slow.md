# PR Review Slow

## Status: Active

This is Carl's `pr-review-slow` SOP. It runs the same review-only loop as
[`pr-review.md`](pr-review.md), serialized **one PR at a time** — one Carl in
flight, not a wave.

## Scope

Use this SOP when submitted work is arriving in a trickle or parallel waves would
thrash the board. It merges an approved feat PR into `accepted` (the ladder's
first rung, Carl's to make as the review owner) and stops the task at `reviewed`;
it does not touch `release`/`main`, deploy QA, ship production, or archive work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

At least one task is in `submitted` with green CI. If `bin/task claim-next-review`
returns `none`, report "no reviewable PRs" and stop.

## Procedure

The serialized loop — the same steps as [`pr-review.md`](pr-review.md), but ONE
Carl at a time (never a wave):

1. **Claim** the next reviewable green-CI PR (the atomic server pop):

   ```bash
   slug=$(bin/task claim-next-review) || true   # the claimed slug, or "none" (exit 4)
   ```

   Stop when it returns `none`.
2. **Record the PR head** before spawning Carl (the merge guard's lower bound):
   `gh pr view <feat-pr> --json headRefOid --jq .headRefOid`.
3. **Spawn ONE Carl** for that PR — an Agent-tool call (`subagent_type: carl`,
   `description: "review: <slug>"`) pointed at
   [`pr-review-primary.md`](pr-review-primary.md). Wait for it to finish before
   claiming the next. Carl runs the deep review, summons a light specialist at his
   discretion, drives the verdict, and on merge-ready merges the feat PR into
   `accepted` (merge → stamp → move, head-pinned).
4. **Release the claim** on Carl's verdict:
   `bin/task review-claim release <slug>`.
5. Re-query and repeat until `claim-next-review` returns `none`.

This is the same review-only loop as [`pr-review.md`](pr-review.md), one task at a
time. It re-queries the board between tasks and exits when the queue drains.

## Exit Seam

Every claimed `submitted` PR is `reviewed`, `blocked`, or explicitly deferred with
a reason, and its review claim is released. Report the result per task.

## Related

- [`pr-review.md`](pr-review.md) — bounded-wave version of this SOP.
- [`pr-review-primary.md`](pr-review-primary.md) — the deep primary review + owner
  role SOP each Carl runs.
- [`pr-review-light.md`](pr-review-light.md) — the focused second-read role SOP the
  light specialist Carl summons runs.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.

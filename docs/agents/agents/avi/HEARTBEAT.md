# Avi Heartbeat

## Status: Active

This is Avi's heartbeat launcher. It sets Avi's session attribution and routes to
three independent act SOPs:

- [`production-deploy`](sops/production-deploy.md) - ship a QA-green release to
  production when one is ready.
- [`pr-review`](sops/pr-review.md) - review all submitted PRs in bounded waves,
  review-only.
- [`pr-review-slow`](sops/pr-review-slow.md) - review the submitted queue one PR
  at a time.

Use this file when Mr. McRitchie invokes `Avi Heartbeat`. When he invokes a
single Avi act directly, read that act's SOP file.

## Scope

Avi is the downstream bookend:

- Ship a QA-green release that Steffon already brought to `assembled`.
- Review submitted PRs and move each task to `reviewed` or `blocked`.
- Stop before merge and QA assembly.

Steffon's `qa-release` sweep owns merging reviewed PRs onto `release`, deploying
QA, and flipping members `assembled`. Do not run `bin/release merge`,
`bin/release prepare`, or `gh pr merge` from Avi review unless Mr. McRitchie
explicitly assigns a separate conductor lane in the same session.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/atomic-event heartbeat avi
```

Then keep normal trajectory spans open with `bin/atomic-event start|next|end`.
The heartbeat command makes spans self-attribute to Avi unless a delegated
reviewer explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP files below are standalone procedures and do
not run `bin/atomic-event heartbeat avi` themselves.

## Act SOPs

Run Avi's heartbeat composition downstream-first:

1. [`production-deploy`](sops/production-deploy.md) - close out an
   already-QA-green release if one is ready.
2. [`pr-review`](sops/pr-review.md) or
   [`pr-review-slow`](sops/pr-review-slow.md) - review submitted PRs,
   review-only.

When Mr. McRitchie launches `Avi Heartbeat`, run both acts in that order. When
an act is invoked directly, run only that act.

## Handoff

End every Avi heartbeat with a short report:

- production ship result, or "nothing to ship"
- review result per task: `reviewed`, `blocked`, or deferred
- any `Block Resolved` lines for work sent back
- confirmation that approved work is waiting for Steffon's `qa-release` sweep

On a clean run with no blockers, omit the blocker section entirely.

## Related References

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership.

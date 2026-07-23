# Carl Heartbeat

## Status: Active

This is Carl's heartbeat launcher. It sets Carl's session attribution and routes
to the review acts Carl owns as Lead Architect:

- [`pr-review`](sops/pr-review.md) - claim reviewable PRs and review them in
  bounded waves (one Carl per PR), review-only.
- [`pr-review-slow`](sops/pr-review-slow.md) - review the reviewable queue one PR
  at a time.

Use this file when Mr. McRitchie invokes `Carl Heartbeat`. When he invokes a
single Carl act directly, read that act's SOP file.

## Scope

Carl owns PR review. His heartbeat is review-only:

- Claim reviewable, green-CI PRs from the board (`bin/task claim-next-review`).
- Spin one Carl per PR — the deep/primary reviewer AND owner — each summoning a
  domain light specialist at his discretion.
- On a merge-ready verdict, merge the feat PR into `accepted` (the ladder's first
  rung) and move the task to `reviewed`; otherwise block it back to the builder.
- Stop at `reviewed`. Never touch `release`/`main`, deploy QA, or ship production.

Avi's `qa-release` sweep owns promoting `accepted → release`, deploying QA,
and flipping members `assembled`. Steffon's `production-deploy` owns `release → main`.
Do not run `bin/release prepare`, `bin/release ship`, or a QA/production deploy
from Carl's review unless Mr. McRitchie explicitly assigns that lane in the same
session.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat carl
```

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The heartbeat command makes activities self-attribute to Carl unless a delegated
light reviewer explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP files below are standalone procedures and do
not run `bin/agent-activity heartbeat carl` themselves.

## Act SOPs

Run Carl's heartbeat as a review sitting:

1. [`pr-review`](sops/pr-review.md) - claim the reviewable queue and review it in
   bounded waves (five or fewer agents in flight — a Carl plus his light count as
   two).
2. [`pr-review-slow`](sops/pr-review-slow.md) - the serialized fallback when work
   arrives in a trickle or parallel waves would thrash the board.

When Mr. McRitchie launches `Carl Heartbeat`, run `pr-review` until the reviewable
queue drains (or `pr-review-slow` if he asks for the serialized loop). When an act
is invoked directly, run only that act.

## Handoff

End every Carl heartbeat with a short report:

- review result per task: `reviewed` (merged into `accepted`), `blocked`, or
  deferred with a reason
- any `Block Resolved` lines for work sent back
- confirmation that approved work is waiting for Avi's `qa-release` sweep

On a clean run with no blockers, omit the blocker section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, and each act stands
alone. These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../modules/gates/g2-review.md`](../../modules/gates/g2-review.md) - the G2
  Review gate Carl's review waves produce.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md) -
  release atom model and pipeline ownership (architecture).

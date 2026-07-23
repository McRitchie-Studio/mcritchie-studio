# Steffon Heartbeat

## Status: Active

This is Steffon's heartbeat launcher. It sets Steffon's session attribution and
routes to two independent act SOPs:

- [`production-deploy`](sops/production-deploy.md) - ship a QA-green release to
  production when one is ready.
- [`archive-shipped`](sops/archive-shipped.md) - archive shipped work and
  reclaim completed worktrees.

Use this file when Mr. McRitchie invokes `Steffon Heartbeat`. When he invokes a
single Steffon act directly, read that act's SOP file.

## Scope

Steffon is the downstream bookend — the ship + archive end of the pipeline:

- Ship a QA-green release that Avi already brought to `assembled` (stages 4-5):
  run the frozen-SHA gate, fast-forward `release → main`, deploy prod, smoke,
  post release notes.
- Archive shipped work and reclaim completed worktrees.
- Stop before merge and QA assembly.

Avi's `qa-release` sweep owns merging reviewed PRs onto `release`, deploying QA,
and flipping members `assembled`. Do not run `bin/release prepare` or a QA deploy
from Steffon's heartbeat unless Mr. McRitchie explicitly assigns a separate
conductor lane in the same session. Review is Carl's.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat steffon
```

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The heartbeat command makes activities self-attribute to Steffon unless a delegated
agent explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP files below are standalone procedures and do
not run `bin/agent-activity heartbeat steffon` themselves.

## Act SOPs

Run Steffon's heartbeat composition downstream-first:

1. [`production-deploy`](sops/production-deploy.md) - close out an
   already-QA-green release if one is ready (stages 4-5).
2. [`archive-shipped`](sops/archive-shipped.md) - close out shipped work from the
   prior cycle.

When Mr. McRitchie launches `Steffon Heartbeat`, run both acts in that order.
When an act is invoked directly, run only that act.

## Legacy Aliases

The old launcher name still refers to the same work:

- `archive-completed` -> [`archive-shipped`](sops/archive-shipped.md)

## Handoff

End every Steffon heartbeat with a short report:

- production ship result, or "nothing to ship"
- archive result, or "nothing to archive"
- release slug and production URL when a release shipped
- any blocker and the failing evidence

On a clean run with no blockers, omit the blocker section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, and each act stands
alone. These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership (architecture).

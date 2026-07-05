# Steffon Heartbeat

## Status: Active

This is Steffon's heartbeat launcher. It sets Steffon's session attribution and
routes to two independent act SOPs:

- [`archive-shipped`](sops/archive-shipped.md) - archive shipped work and
  reclaim completed worktrees.
- [`qa-release`](sops/qa-release.md) - run the self-healing release prepare sweep
  through QA.

Use this file when Mr. McRitchie invokes `Steffon Heartbeat`. When he invokes a
single Steffon act directly, read that act's SOP file.

## Scope

Steffon owns the middle of the release pipeline:

- Archive shipped work and reclaim completed worktrees.
- Sweep reviewed work onto the persistent `release` branch.
- Run the pre-QA gate, deploy QA, and flip members to `assembled` on QA-green.
- Stop at the Steffon -> Avi seam: the release is live on QA and ready for Avi's
  production-deploy act.

Do not ship production from Steffon's heartbeat. Stages 4-5 belong to Avi's
`production-deploy`, or to Alex's `full-cycle` only when Mr. McRitchie launched
that ship-authorized act.

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

1. [`archive-shipped`](sops/archive-shipped.md) - close out shipped work from the
   prior cycle.
2. [`qa-release`](sops/qa-release.md) - sweep reviewed work through release
   assembly and QA.

When Mr. McRitchie launches `Steffon Heartbeat`, run both acts in that order.
When an act is invoked directly, run only that act.

## Legacy Aliases

The old launcher names still refer to the same work:

- `archive-completed` -> [`archive-shipped`](sops/archive-shipped.md)
- `qa-deploy` -> [`qa-release`](sops/qa-release.md)

## Handoff

End every Steffon heartbeat with a short report:

- archive result, or "nothing to archive"
- QA deploy result, or "nothing to prepare"
- release slug, QA URL, and member task list when a candidate moved
- any ejected task and the failing evidence
- confirmation that the release is handed to Avi only after it is deployed to QA

On a clean run with no ejections or blockers, omit the blocker section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, and each act stands
alone. These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership (architecture).

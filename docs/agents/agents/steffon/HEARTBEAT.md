# Steffon Heartbeat

## Status: Active

This is Steffon's specific heartbeat SOP. It has two act SOPs:

- `archive-completed` - archive shipped work and reclaim completed worktrees.
- `qa-deploy` - run the self-healing release prepare sweep through QA.

Use this file when Mr. McRitchie invokes `Steffon Heartbeat`,
`archive-completed`, or `qa-deploy`, whether the entry came from a manual prompt,
automation, or a scheduled run.

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
bin/atomic-event heartbeat steffon
```

Then keep normal trajectory spans open with `bin/atomic-event start|next|end`.
The heartbeat command makes spans self-attribute to Steffon unless a delegated
agent explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

## Act SOPs

Run Steffon's acts downstream-first:

1. `archive-completed` - close out shipped work from the prior cycle.
2. `qa-deploy` - sweep reviewed work through release assembly and QA.

When Mr. McRitchie launches `Steffon Heartbeat`, run both acts in that order.
When an act is invoked directly, run only that act.

## Act 1 - `archive-completed`

**Precondition:** at least one shipped task or completed release is ready to
archive. If there is nothing to archive, report "nothing to archive" and continue
to `qa-deploy` when this is the full `Steffon Heartbeat` run.

Procedure:

```bash
bin/release archive --dry-run
bin/release archive --yes
```

Use the dry run to confirm what will be archived and reclaimed. The `--yes` flag
answers the non-interactive confirmation only; it does not bypass archive
eligibility or worktree safety checks.

**Exit seam:** shipped tasks and completed releases are archived, and merged
worktrees that are safe to reclaim have been reclaimed. Report archived counts
and any worktree that was intentionally left alone.

## Act 2 - `qa-deploy`

**Precondition:** there is work to prepare: `reviewed` tasks, `assembled`
stragglers not riding the current release candidate, or an interrupted release
candidate that needs to continue. Empty queue is a clean no-op: report "nothing
to prepare" and stop.

Procedure:

```bash
bin/release prepare --yes
curl -fsS https://qa.mcritchie.studio/up
```

`prepare` is the self-healing sweep. It detects reviewed tasks and assembled
stragglers, opens or resumes a release candidate, merges each task's PR onto
`release` unless `merged: release/main` already proves that work landed, runs the
pre-QA gate on `origin/release`, deploys QA, and flips members to `assembled`
only after QA is green.

If the pre-QA gate identifies an offender, use the release eject path rather than
forcing the candidate forward:

```bash
bin/release eject <task> --feedback "<specific failing evidence>"
```

Then re-run `bin/release prepare --yes` so the rest of the candidate can ride.

**Exit seam:** the release candidate is `assembled` and live on QA; members are
`assembled` with `merged: release`. Report the QA URL, release slug, member list,
and the exact phrase "deployed to QA" for Avi's handoff.

## Handoff

End every Steffon heartbeat with a short report:

- archive result, or "nothing to archive"
- QA deploy result, or "nothing to prepare"
- release slug, QA URL, and member task list when a candidate moved
- any ejected task and the failing evidence
- confirmation that the release is handed to Avi only after it is deployed to QA

On a clean run with no ejections or blockers, omit the blocker section entirely.

## Related References

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership.

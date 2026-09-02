# Steffon Heartbeat

## Status: Active

This is Steffon's heartbeat launcher. It sets Steffon's session attribution and
routes to three independent act SOPs:

- [`production-deploy`](sops/production-deploy.md) - ship a QA-green release to
  production when one is ready. **Its final step runs `archive-shipped`**, so a
  completed ship closes out the cycle it just ended.
- [`clean-infra`](sops/clean-infra.md) - reclaim this machine's local
  infrastructure: finished desks, the Redis band, regenerable disk, orphaned
  per-desk databases. The catch-all when an agent reports there is no space.
- [`archive-shipped`](sops/archive-shipped.md) - archive shipped work, retire
  frozen docs, and **sweep for orphaned PRs**. Chained by `production-deploy`;
  still invocable on its own.

Use this file when Mr. McRitchie invokes `Steffon Heartbeat`. When he invokes a
single Steffon act directly, read that act's SOP file.

**Two kinds of cleaning, on purpose.** `archive-shipped` is the NATURAL beat — it
rides the end of every production release and closes out what that release
shipped, and it is therefore where the orphaned-PR sweep lives: `bin/release
archive` archives through the MODEL path, which bypasses the CLI's open-PR gate
by design, so the alarm rings on the same beat as the act that can create one.
`clean-infra` is the DELIBERATE one — invoked when the machine is in the way,
whatever the symptom looked like. The `/deployments` Workflows card
carries `production-deploy` + `clean-infra`; `archive-shipped` is off it because
the release already runs it, and it stays invocable by name.

## Scope

Steffon is the downstream bookend — the ship + archive end of the pipeline:

- Ship a QA-green release that Avi already brought to `assembled` (stages 4-5):
  run the frozen-SHA gate, fast-forward `release → main`, deploy prod, smoke,
  post release notes.
- Archive shipped work, reclaim completed worktrees, and sweep for PRs left open
  under an archived task.
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
   already-QA-green release if one is ready (stages 4-5). It ends by running
   [`archive-shipped`](sops/archive-shipped.md) itself.
2. [`clean-infra`](sops/clean-infra.md) - sweep the machine: reclaim finished
   desks, contract the Redis band, sweep regenerable disk.

When Mr. McRitchie launches `Steffon Heartbeat`, run both acts in that order.
When an act is invoked directly, run only that act.

**Nothing ready to ship?** `production-deploy` is an idempotent no-op that reports
"nothing to ship" — and because the archive rides inside it, nothing gets archived
either. Run [`archive-shipped`](sops/archive-shipped.md) directly anyway, then
continue to `clean-infra`.

**Run it even when no prior cycle needs closing out.** Its closing orphan sweep
reports PRs already stranded on the board, so it owes a result whether or not this
beat has anything to archive — and the quiet beat is the one where it earns its
keep, because that is where an orphan sits unnoticed. "Nothing to archive" is a
result the act reports, never a reason to skip the act. The act's own
[Preconditions](sops/archive-shipped.md#preconditions) say the same thing one level
down; this is that rule at the launcher, so a quiet heartbeat cannot skip the sweep
by never entering the act.

`clean-infra` covers what the release-driven archive does not: the hand-triage of
stale UNMERGED desks and the Redis band contraction. `bin/release archive` sweeps
only what is automatically safe, so the two are complementary, not redundant.

## Legacy Aliases

The old launcher name still refers to the same work:

- `archive-completed` -> [`archive-shipped`](sops/archive-shipped.md)

## Handoff

End every Steffon heartbeat with a short report:

- production ship result, or "nothing to ship"
- archive result, or "nothing to archive"
- **orphaned PRs** found by `archive-shipped`'s closing sweep — each as
  `<repo>#<n>` with the archived task that stranded it — and **any repo the sweep
  could not check, by name**. An unchecked repo is never reported as clean; that
  turns an unknown into a false all-clear. On a fully-checked clean pass, say "no
  orphaned PRs, all N repos checked"
- release slug and production URL when a release shipped
- infra swept: desks reclaimed, band before → after, reclaimed bytes
  (**this machine only**), and any app the logger audit named `LOOSE` or `NONE`
- **the improvement suggestion `clean-infra` requires** — one concrete proposal
  for making the next sweep smaller
- any blocker and the failing evidence

On a clean run with no blockers, omit the blocker section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, and each act stands
alone. These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership (architecture).

# Full Cycle

## Status: Active

This is Alex's `full-cycle` SOP. It runs review, QA release, and production
deploy with explicit ship authority.

## Scope

`full-cycle` composes existing release atoms:

1. Avi-style review-only PR review.
2. Avi's self-healing `qa-release`.
3. Steffon's `production-deploy`.

This SOP crosses the production gate. Use it only when Mr. McRitchie launched
`full-cycle` or otherwise granted production ship authority in this session.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

There is work to move:

- submitted PRs to review
- reviewed work to prepare
- an assembled release to ship

If the queue is empty and `release == main`, report "nothing to run" and stop.

## Procedure

Refresh intake:

```bash
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio
```

Run the three atoms in sequence:

```bash
# pr-review atom: review submitted PRs to reviewed or blocked
bin/release prepare --yes
bin/release ship --yes
```

**Posture per atom — delegate the READS, direct-drive the MUTATIONS.** Any op that
MUTATES shared state across many minutes is DIRECT-DRIVEN by this orchestrating
session, never handed to an ephemeral subagent: a subagent that detaches (crash,
timeout, killed terminal) leaves the mutation HALF-APPLIED with no attached
terminal to notice or finish it. Subagents stay first-class for **read** fan-out,
where a detach costs a retry. The line is **mutating vs reading**, not *parallel vs
serial*.

1. **Review** — READ fan-out, so DELEGATE. Summon an **Avi** subagent via the
   Agent tool (`subagent_type: avi`) that SUPERVISES the `pr-review` procedure.
   Avi never reviews the code himself; he spawns the PRIMARY and LIGHT reviewers
   in parallel as sibling children, so the two experts NEST under the Avi node as
   a deeper branch. Review mutates nothing but a task stage — a detached reviewer
   costs a retry.
2. **QA release** — MUTATION, so DIRECT-DRIVE `bin/release prepare --yes` from
   THIS session. Do NOT wrap it in a Steffon subagent. (Not theoretical: on
   2026-07-11 it WAS delegated, the subagent detached mid-sweep, and it stranded a
   partial release candidate — merged onto `release`, but never gated, deployed, or
   assembled. It sat there unnoticed.)

   **Recovery — diagnose before you re-run.** If the sweep was **INTERRUPTED** (no
   verdict — it detached, crashed, timed out): **re-run `bin/release prepare
   --yes`**; it is self-healing, and only a live terminal can run it. If it
   **ABORTED** (a verdict — red pre-QA gate, failed QA boot): **fix or eject the
   offender FIRST**, because a bare re-run re-deploys the same member code and goes
   red again. The full abort table is in
   [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md).
3. **Ship** — MUTATION, so DIRECT-DRIVE `bin/release ship --yes` from THIS
   session. Do NOT wrap the ship in a subagent: it is the one irreversible gate,
   and a wrapper agent that dies mid-ship would orphan the `release → main` state
   with no terminal to recover it.

- **Visibility is not a reason to delegate.** The sub-agent tree is ephemeral (it
  dies with the session) and the autonomous heartbeat has no terminal, so it
  renders no tree at all. The durable, full-visibility surface is the Activities
  timeline — narrate each atom there.

Keep the same guards each atom owns:

- Review in waves of five or fewer reviewers.
- Use Avi's `qa-release` sweep for merge plus QA.
- Ship only after QA-green.
- Do not deploy production unless ship authority is explicit.

Review and preparation take time; new PRs may land in `submitted` meanwhile.
After the sweep, re-check `bin/task list --stage submitted` and run one
straggler round — review anything new, then re-run `bin/release prepare --yes`
so the same candidate picks up the round-2 `reviewed` tasks and refreshes QA —
before shipping.

Cold start note: launched bare, you are the conductor (Deploy lane), not a
feature agent — do not follow the build gate's task/worktree flow. You
orchestrate review, sweep, and ship on work that is already built; you do not
review diffs yourself, create tasks, or write feature code.

For a single-task expedite, run Avi's
[`deploy-with-task`](../../avi/sops/deploy-with-task.md) SOP instead of pushing
one task past pending release work.

## Exit Seam

The release is shipped, or the run cleanly reports no work. Report:

- reviewed and blocked tasks
- QA URL
- production SHA
- release slug
- smoke result when a ship happens

## Related

- [`../../../agents/carl/sops/pr-review.md`](../../../agents/carl/sops/pr-review.md)
  - review-only PR review (Carl).
- [`../../../agents/avi/sops/qa-release.md`](../../../agents/avi/sops/qa-release.md)
  - QA release sweep.
- [`../../../agents/steffon/sops/production-deploy.md`](../../../agents/steffon/sops/production-deploy.md)
  - production deploy.

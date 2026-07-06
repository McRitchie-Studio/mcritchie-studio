# Full Cycle

## Status: Active

This is Alex's `full-cycle` SOP. It runs review, QA release, and production
deploy with explicit ship authority.

## Scope

`full-cycle` composes existing release atoms:

1. Avi-style review-only PR review.
2. Steffon's self-healing `qa-release`.
3. Avi's `production-deploy`.

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

**Summon posture per atom (interactive tree visibility).** When you drive
`full-cycle` interactively (a terminal is attached), summon each atom with the
posture its own SOP prescribes, so the crew shows up as a live Claude Code
sub-agent tree:

1. **Review** — summon an **Avi** subagent via the Agent tool
   (`subagent_type: avi`) that runs the `pr-review` procedure and NESTS its
   reviewers (Avi thin-delegates; the PRIMARY reviewer spawns the LIGHT) as a
   deeper branch.
2. **QA release** — summon a **Steffon** subagent (`subagent_type: steffon`)
   that executes `bin/release prepare --yes`.
3. **Ship** — DIRECT-DRIVE `bin/release ship --yes` from THIS orchestrating
   session. Do NOT wrap the ship in a subagent: it is the one irreversible gate,
   and a wrapper agent that dies mid-ship would orphan the `release → main` state
   with no terminal to recover it.

- **Caveat.** `bin/release` is a script, so a summoned subagent is a thin driver
  around it — the tree node is real, but the script's subprocess internals live
  inside that agent. The tree is ephemeral (it dies with the session) and the
  autonomous heartbeat has no terminal, so it renders no tree. The durable,
  full-visibility surface is the Activities timeline, not the sub-agent tree.

Keep the same guards each atom owns:

- Review in waves of five or fewer reviewers.
- Use Steffon's `qa-release` sweep for merge plus QA.
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

- [`../../../agents/avi/sops/pr-review.md`](../../../agents/avi/sops/pr-review.md)
  - review-only PR review.
- [`../../../agents/steffon/sops/qa-release.md`](../../../agents/steffon/sops/qa-release.md)
  - QA release sweep.
- [`../../../agents/avi/sops/production-deploy.md`](../../../agents/avi/sops/production-deploy.md)
  - production deploy.

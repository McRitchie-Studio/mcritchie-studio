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
`full-cycle`, launched an Alex heartbeat with full release authority, or
otherwise granted production ship authority in this session.

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

Keep the same guards each atom owns:

- Review in waves of five or fewer reviewers.
- Use Steffon's `qa-release` sweep for merge plus QA.
- Ship only after QA-green.
- Do not deploy production unless ship authority is explicit.

For a single-task expedite, use the dedicated `Deploy with Task <task>` SOP from
`../../../system/devops-cycle-design.md` §1.4 instead of pushing one task past
pending release work.

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

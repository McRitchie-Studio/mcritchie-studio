# Production Deploy

## Status: Active

This is Avi's `production-deploy` SOP. It ships an assembled, QA-green release to
production when one is ready.

## Scope

Avi owns release stages 4-5:

1. Confirming
2. Deploying production

This SOP crosses the production gate. Use it only when Mr. McRitchie launched
`production-deploy`, launched an Avi heartbeat with ship authority, or otherwise
granted production ship authority in this session.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

- Steffon's `qa-release` has produced a QA-green release.
- Members are `assembled` and `merged: release`.
- The release candidate is live on QA.
- The primary checkout is clean enough to ship.

If `release == main` or no QA-green release exists, report "nothing to ship" and
stop.

## Procedure

Check readiness:

```bash
bin/release status
```

Run ship only when status shows a ready QA-green release:

```bash
bin/release ship --yes
```

Ship from the primary checkout, not a feature worktree. `--yes` only answers the
non-interactive confirmation. It does not skip clean-main preflight, frozen-SHA
tests, gem publish ordering, deploy smoke, release notes, or partial-ship
recovery.

Post-ship, `bin/release ship` auto-runs the hub primary's
`bin/install-agent-docs` (non-fatal — it never aborts a completed ship;
Steffon owns the step and its mechanism) so the installed agent docs
(`~/.claude` + `~/.codex` skills, the projects-root `AGENTS.md`/`CLAUDE.md`)
match what shipped. If it warns, run the installer from the hub primary by
hand.

If the ship gate aborts, do not force past it. Record the blocker and hand it
off.

## Exit Seam

The ready release is `shipped` and members remain stamped `merged: main`, or the
act reports a clean no-op because nothing was ready. Report:

- release slug
- production SHA
- production URL
- smoke result

On a clean no-op, report "nothing to ship."

## Background — not needed to execute

- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model and production gate (architecture).

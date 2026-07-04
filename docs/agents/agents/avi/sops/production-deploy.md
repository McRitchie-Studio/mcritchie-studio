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

**Announce the handoff first.** The QA-green release sits at three greens with
Confirming dark — Steffon's finish line. The moment you begin confirming (before
any checks), notify the release so the /deployments tracker lights stage 4
yellow under your name (`docs/agents/modules/task-board-api.md`, "Release stage
timeline"):

```bash
# api() helper + TOKEN per task-board-api.md "Worked example"
api POST /api/v1/releases/current/events/confirming/start '{"event": {"actor": "avi"}}'
```

`start` needs no usage metadata. The stamp is first-write-wins, so a re-run is a
safe no-op. (If you skip this and go straight to `bin/release ship`, its
`ship_gate started` checkpoint stamps `confirming` then — but only at ship time,
which under-reports your confirmation work; post the start when the work starts.)

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

`ship` narrates the rest of the stage timeline itself (`ship_gate` →
Confirmed green, `deploy_prod started` → Deploying yellow, the ship flip →
Deployed green) — no extra posts on the happy path. After an interrupted run,
backfill the missed boundary via the release events API; stamps are
first-write-wins, so re-posts are safe no-ops.

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

## Related

- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model and production gate.

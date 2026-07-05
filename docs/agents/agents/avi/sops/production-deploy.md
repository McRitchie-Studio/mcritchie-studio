# Production Deploy

## Status: Active

This is Avi's `production-deploy` SOP. It ships an assembled, QA-green release to
production when one is ready.

## Scope

Avi owns release stages 4-5:

1. Confirming
2. Deploying production

This SOP crosses the production gate. Use it only when Mr. McRitchie launched
`production-deploy` or otherwise granted production ship authority in this
session.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

- Steffon's `qa-release` has produced a QA-green release.
- The active release is `assembled` and `qa_deployed_at` is stamped.
- Members are `assembled` and `merged: release`.
- The release candidate is live on QA.
- The primary checkout is clean enough to ship.

If `release == main`, no release is active, the active release is still
`assembling`, or `qa_deployed_at` is blank, report "nothing to ship" and stop.

## Procedure

**Gate before activating Avi.** Do not post `confirming/start` just because
`Release.current` exists. The Avi handoff exists only when the next release is
already live on QA: `Release.current.state == "assembled"` and the
`qa_deployed_at` stage timestamp is present.

```bash
bin/release status
```

If status reports `release == main`, stop immediately. Otherwise validate the
production-board release timestamp before lighting stage 4:

```bash
heroku run -a mcritchie-studio --no-tty rails runner \
  'r = Release.current;
   ready = r&.state == "assembled" && r.qa_deployed_at.present?;
   puts({
     ready: ready,
     release: r&.slug,
     state: r&.state,
     qa_deployed_at: r&.qa_deployed_at&.iso8601,
     qa_url: r&.qa_url
   }.to_json);
   exit(ready ? 0 : 1)'
```

If that command exits nonzero, the release is not ready for Avi. Do not stamp
`confirming/start`, do not run `bin/release ship`, and report "nothing to ship"
with the printed release state.

**Announce the handoff only after that guard passes.** The QA-green release sits
at three greens with Confirming dark — Steffon's finish line. The moment you
begin confirming, notify the release so the /deployments tracker lights stage 4
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

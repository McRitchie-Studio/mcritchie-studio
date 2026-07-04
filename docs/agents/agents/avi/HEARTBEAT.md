# Avi Heartbeat

## Status: Active

This is Avi's specific heartbeat SOP. Use it when Mr. McRitchie launches
`Avi Heartbeat`, `production-deploy`, `pr-review`, or `pr-review-slow` from the
`/deployments` Heartbeats card.

The shared launcher map lives in
[`../../modules/heartbeats.md`](../../modules/heartbeats.md). The release atom
model lives in
[`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
§1.4. Those pages should summarize and link here for Avi-specific mechanics.

## Scope

Avi is the downstream bookend:

- Ship a QA-green release that Steffon already brought to `assembled`.
- Review submitted PRs and move each task to `reviewed` or `blocked`.
- Stop before merge and QA assembly.

Steffon's `qa-deploy` sweep owns merging reviewed PRs onto `release`, deploying
QA, and flipping members `assembled`. Do not run `bin/release merge`,
`bin/release prepare`, or `gh pr merge` from Avi review unless Mr. McRitchie
explicitly assigns a separate conductor lane in the same session.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/atomic-event heartbeat avi
```

Then keep normal trajectory spans open with `bin/atomic-event start|next|end`.
The heartbeat command makes spans self-attribute to Avi unless a delegated
reviewer explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

## Act Order

Run Avi acts downstream-first:

1. `production-deploy` - close out an already-QA-green release if one is ready.
2. `pr-review` or `pr-review-slow` - review submitted PRs, review-only.

When Mr. McRitchie launches `Avi Heartbeat`, run both acts in that order. When
an action row is launched directly, run only that act.

## Act 1 - `production-deploy`

**Precondition:** Steffon's `qa-deploy` has already produced a QA-green release:
members are `assembled` and `merged: release`, and the candidate is live on QA.
If `release == main` or no QA-green release exists, report "nothing to ship" and
continue to review work when this is the full `Avi Heartbeat` row.

**Authority:** This crosses the production gate. It is allowed only when Mr.
McRitchie launched `Avi Heartbeat`, launched `production-deploy`, or granted
production ship authority in this session. The `--yes` flag answers only the
human confirmation prompt; it never skips ship tests, smoke checks, gem publish
ordering, or partial-ship recovery.

Procedure:

```bash
bin/release status
bin/release ship --yes
```

Run `ship` only when `status` shows a ready QA-green release. Ship from the
primary checkout, not a feature worktree. If the ship gate aborts, do not force
past it. Record the blocker and hand it off.

**Exit seam:** the ready release is `shipped` and members remain stamped
`merged: main`, or the act reports a clean no-op because nothing was ready.
Report the release slug, production SHA, production URL, and smoke result when a
ship actually happened.

## Act 2 - `pr-review`

**Precondition:** at least one task is in `submitted`. Empty queue is a clean
no-op: report "no submitted PRs" and stop.

Preferred supervisor path:

```bash
bin/avi-heartbeat --run --fast --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

Use `--fast` for the `pr-review` action because it reviews in bounded waves
under the five-agent cap. The script picks newest submitted tasks first, records
`bin/reviewer-select` intent, launches the selected PRIMARY + LIGHT reviewers,
re-queries the board before each final decision, writes the task handoff, and
prints a retrospective.

Manual fallback:

```bash
bin/task list --stage submitted
bin/reviewer-select <task> --busy-auto
```

For each task, run the single-PR cascade from
[`../../modules/pr-review-sop.md`](../../modules/pr-review-sop.md): Avi confirms
product acceptance and selects the reviewers; the PRIMARY reviewer performs the
deep review, spawns the LIGHT reviewer, and owns the verdict. Keep review fan-out
to waves of five or fewer agents.

Verdicts:

- Two approvals, no blockers:

  ```bash
  bin/task move <task> reviewed
  bin/task note <task> --handoff "Avi review approved; ready for Steffon's qa-deploy sweep." --agent avi
  ```

- Request changes, missing metadata, red CI, merge risk, or acceptance mismatch:

  ```bash
  bin/task block <task> --kind rework --feedback "<one complete send-back>" --agent avi
  ```

- Wait-for-CI or conductor-review: defer and re-query after the defer window.

Approved tasks stop at `reviewed` with `merged: nil`. Steffon's next
`qa-deploy` sweep moves them forward.

**Exit seam:** every visible `submitted` PR is `reviewed`, `blocked`, or
explicitly deferred with a reason.

## Act 2b - `pr-review-slow`

Use the serialized path when submitted work is arriving in a trickle or parallel
waves would thrash the board:

```bash
bin/avi-heartbeat --run --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

This is the same review-only loop as `pr-review`, but one task at a time. It
re-queries the board between tasks and exits when the queue drains.

## Handoff

End every Avi heartbeat with a short report:

- production ship result, or "nothing to ship"
- review result per task: `reviewed`, `blocked`, or deferred
- any `Block Resolved` lines for work sent back
- confirmation that approved work is waiting for Steffon's `qa-deploy` sweep

On a clean run with no blockers, omit the blocker section entirely.

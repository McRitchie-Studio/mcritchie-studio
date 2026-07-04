# PR Review

## Status: Active

This is Avi's `pr-review` SOP. It reviews all submitted PRs in bounded waves and
stops approved work at `reviewed`. Steffon's `qa-release` sweep owns the merge.

## Scope

Avi owns review delegation and product acceptance. This SOP does not merge PRs,
deploy QA, ship production, or archive work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

At least one task is in `submitted`. If the queue is empty, report "no submitted
PRs" and stop.

## Procedure

**Kick off the release timeline.** A review wave is the `Testing` stage of the
NEXT release — notify the release so the /deployments tracker lights stage 1
yellow (`docs/agents/modules/task-board-api.md`, "Release stage timeline"). This
start may OPEN the next candidate when none is active; the stamp is
first-write-wins, so a re-post mid-cycle is a safe no-op:

```bash
# api() helper + TOKEN per task-board-api.md "Worked example"
api POST /api/v1/releases/current/events/testing/start '{"event": {"actor": "avi"}}'
```

Preferred supervisor path:

```bash
bin/pr-review --run --fast --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

Use `--fast` for bounded waves under the five-agent cap. The script picks newest
submitted tasks first, records `bin/reviewer-select` intent, launches the
selected PRIMARY + LIGHT reviewers, re-queries the board before each final
decision, writes the task handoff, and prints a retrospective.

Manual fallback:

```bash
bin/task list --stage submitted
bin/reviewer-select <task> --busy-auto
```

For each task, run the single-PR cascade from
[`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md): Avi
confirms product acceptance and selects the reviewers; the PRIMARY reviewer
performs the deep review, spawns the LIGHT reviewer, and owns the verdict. Keep
review fan-out to waves of five or fewer agents.

Verdicts:

- Two approvals, no blockers:

  ```bash
  bin/task move <task> reviewed
  bin/task note <task> --handoff "Avi review approved; ready for Steffon's qa-release sweep." --agent avi
  ```

- Request changes, missing metadata, red CI, merge risk, or acceptance mismatch:

  ```bash
  bin/task block <task> --kind rework --feedback "<one complete send-back>" --agent avi
  ```

- Wait-for-CI or conductor-review: defer and re-query after the defer window.

Approved tasks stop at `reviewed` with `merged: nil`. Steffon's next
`qa-release` sweep moves them forward.

## Exit Seam

Every visible `submitted` PR is `reviewed`, `blocked`, or explicitly deferred
with a reason. Report the result per task.

## Related

- [`pr-review-slow.md`](pr-review-slow.md) - serialized version of this SOP.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) -
  single-PR review primitive.

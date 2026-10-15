---
question: "The reclaim withholds dozens of shipped desks and `begin` fails for want of a Redis DB. Do I force them?"
answer: "Read each desk's task stage and what it holds. Remove a shipped or archived desk whose only change is ignored test output; never one holding env, key or override files."
why: "The reclaim holds a desk for any ignored file, and ignored test output is the common case, so held desks fill the Redis band."
status: proposed
source: "2026-10-14 · clean-infra sweep"
sop: clean-infra
step: reclaim
topic: [reclaim, redis, worktree]
---

# Reclaim desks held only by test artifacts

## Situation

`bin/agent-worktree cleanup --reclaim` withheld 55 desks. Every one belonged to
a task already shipped or archived. Each was held for gitignored files only:
`playwright/` reports and `test/dummy/tmp/`. The held desks kept their Redis DBs,
the band filled, and the next `bin/task begin` failed with "no free Redis DB".

## The pull

Pass `--yes` and take them all, or delete the ignored files wholesale so the
reclaim stops complaining.

## What happened

The session checked two facts per desk: the task's stage on the board, and the
kind of every ignored change. Where the stage was `shipped` or `archived` and the
only ignored changes were test artifacts, it ran
`bin/agent-worktree remove <repo> <slug> --yes`. It left alone any desk holding
`.env.local`, a `master.key`, or a local engine path override, because those
are a person's setup, not output a test can regenerate.

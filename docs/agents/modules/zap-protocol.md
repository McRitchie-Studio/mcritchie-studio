# Zap Protocol — fix small defects in place

You found a small defect mid-cycle: a typo in the UI, a wrong doc path, an
off-by-one in a label, a missing nil-guard one line wide. **Zap it.** Fix it in
place, on the branch you already have, with no new board task. This module is
the standing license to do that — and the bounds that keep zaps from becoming
their own devops mess.

The problem this solves: every small defect used to spawn a fresh task, which
spawned a worktree, a branch, a PR, a review, and a release slot — more process
than the fix. The zap protocol replaces that with **one commit, one check, one
note** on a record that already exists.

A **zap** is one commit, prefixed `zap:`, that fixes ONE small defect found
mid-cycle, carries its own check, and is recorded on the nearest existing
record. Never a new board task; never a chain.

## Eligibility — every bound must hold

A fix qualifies as a zap only when **all** of these are true:

- **Size** — at most **25 changed lines** across at most **2 files**.
- **No structure** — no migrations, no new dependencies, no new routes or
  endpoints, no secrets or env-var changes.
- **In-cycle repos only** — only repos the active task or release already
  touches. A defect in an untouched repo is a task, not a zap.
- **One defect, one commit** — a zap fixes exactly one issue in exactly one
  commit. Two defects are two zaps (each within bounds) or one task.

If **any** bound fails — or you are unsure — it is not a zap. Create a normal
task and run the full cycle:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task create --title "<3-5 words>" --kind bug --shape <shape> \
  --repo <app> --accept "<criterion>"
```

Judgment calls resolve **toward the task**, never toward a bigger zap.

## The test rule

Every zap carries a check at the **lowest tier that exercises the fix**, run
before you push:

- A behavior fix (even one line) gets a test at the lowest tier that reproduces
  it — usually `[unit]` — added or adjusted inside the same zap commit and
  inside the same size bounds.
- A pure typo or doc zap may skip the test, but the recording note must say so
  explicitly: `no-test: copy-only, no behavior change`.

A zap whose check **fails** is dead on arrival: revert it and escalate (see the
guard below). Never push a zap with a red check to "fix forward."

## The three seams

Where you commit depends on which seat you hold when you find the defect.

| Seam | You are | Zap lands on | Recorded on |
|---|---|---|---|
| **Builder** | Feature agent, mid-build | Your own `feat/<slug>` branch | Your own task's `checks_run` |
| **Reviewer** | Primary/light reviewer, mid-review | The PR branch under review | The review verdict + the task under review |
| **Conductor** | Sweep/release conductor | `accepted` or the open release branch | The nearest member task of the open release |

### Builder — on your own feat branch

You are building a task and notice a small defect in code your cycle already
touches. Fix it on your feat branch as its own commit:

```bash
git add -p
git commit -m "zap: <what was broken, one line>"
```

Tag it in your task's checks. **`--checks` REPLACES the whole list** — pass
every line you want kept, plus the zap line:

```bash
bin/task update <your-task> \
  --checks "[unit] <your existing check>" \
  --checks "[zap] <defect> — <check run, or no-test: rationale>"
```

The zap rides your PR through normal review; the reviewer sees the `zap:`
commit and the `[zap]` check line and judges it with the rest of the diff.

### Reviewer — on the PR branch under review

You are reviewing a PR and find a small defect — in the diff, or adjacent code
the diff exposed. Instead of blocking the task back for a one-line fix, push a
zap commit to the PR branch:

```bash
git fetch origin <pr-branch>
git checkout <pr-branch>
git commit -m "zap: <what was broken, one line>"
git push origin <pr-branch>
```

Record it twice — in your review verdict (name the zap commit SHA and the check
you ran), and on the task under review:

```bash
bin/task note <task-under-review> \
  --comment "zap: <defect> — commit <sha>, <check run, or no-test: rationale>"
```

A reviewer zap never widens the review's scope: it must sit inside the
eligibility bounds, and the verdict must call it out so the supervisor gates
with eyes open. If the fix the PR needs is bigger than a zap, that is what
`bin/task block <task> --kind rework --feedback "…"` is for.

### Conductor — on `accepted` or the open release branch

You are sweeping or assembling a release and find a small defect in code
already merged. Commit the zap directly on `accepted` (or on the open release
branch when the defect lives there), so the fix rides the **current** RC —
no new task, no new PR, no extra release slot:

```bash
git checkout accepted   # or the open release branch
git commit -m "zap: <what was broken, one line>"
git push origin accepted
```

Two hard edges:

- **Never `main`.** A conductor zap lands on `accepted` or the open release
  branch only. `main` moves by `bin/release ship` alone.
- **Before the QA deploy.** Land the zap before Steffon's G3 QA deploy so QA
  exercises it. After QA-green the RC's SHA is what G4's frozen-SHA gate
  verifies — a zap after the freeze breaks the freeze. A defect found
  post-freeze is a normal task, full stop.

Record it on the nearest member task of the open release — the task whose
change surfaced or contains the defect; if none fits, the member task closest
to the touched code:

```bash
bin/task note <nearest-member-task> \
  --comment "zap: <defect> — commit <sha> on <branch>, <check run, or no-test: rationale>"
```

## Recording — never a new task

Every zap leaves the same two-part trail, whatever the seam:

1. **The commit message prefix `zap:`** — this is the machine-readable marker.
   `git log --oneline --grep '^zap:'` must find every zap on a branch.
2. **A note on the nearest existing record** — the builder's own task, the task
   under review, or the nearest member task of the open release. The note names
   the defect, the commit SHA, and the check run (or the explicit `no-test:`
   rationale).

That is the whole ledger. Do **not** create a board task for a qualifying zap —
the entire point is that the fix attaches to a record that already exists.

## Escalation guard — one zap per issue, no chains

This is the rule that makes loops impossible. **Each issue gets at most one
zap, ever.** When any of these happens, the zap lane is closed for that issue:

- The fix **grows past any eligibility bound** while you write it.
- The zap's **check fails**, at commit time or later in the pipeline.
- The **same defect resurfaces** after a zap claimed to fix it.
- The candidate fix would **touch a `zap:` commit** — a zap may never fix,
  amend, or revert another zap.

In every case the move is the same: **revert and escalate.**

```bash
git revert <zap-sha>
bin/task create --title "<3-5 words>" --kind bug --shape <shape> \
  --repo <app> --accept "<criterion>" \
  --agent-context "Escalated from zap <sha>: <what the zap tried, why it was not enough>"
```

No second zap on the same issue. No zap on a zap. No "one more line and it'll
hold." Chain depth is capped at one by rule, so a zap can never recurse into
the process spiral it exists to prevent.

## What a zap is not

- **Not a scope smuggler.** No refactors, no renames, no "while I'm here"
  cleanups, no feature slivers. A zap fixes a defect; it never improves code
  that was not broken.
- **Not a review bypass.** Builder and reviewer zaps ride the PR through normal
  review; conductor zaps ride the RC through G3 QA and G4's frozen-SHA gate.
  The zap skips the *task ceremony*, never the *verification*.
- **Not a pressure valve for big fixes.** A bounded fix that keeps almost
  qualifying is the classic loop-starter. When in doubt, task it.

## Go-live note for this doc

This module lives in `docs/agents/modules/` inside `mcritchie-studio`. Changes
to it — like all agent-doc changes — reach the generated projects-root
`AGENTS.md` and adapters only after `bin/install-agent-docs` runs from the
McRitchie Studio primary checkout.

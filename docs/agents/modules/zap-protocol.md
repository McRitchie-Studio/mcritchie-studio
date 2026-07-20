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
mid-cycle, carries its own check, and is recorded with `bin/task note` on the
nearest existing record. Never a new board task; never a chain.

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
  --repo <app> --accept "<criterion>" --no-claim
                 # --no-claim: filing is not building — leave your session's
                 # active-feature marker on the live lane
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

| Seam | You are | Zap lands on | Recorded on (`bin/task note`) |
|---|---|---|---|
| **Builder** | Feature agent, mid-build | Your own `feat/<slug>` branch | Your own task |
| **Reviewer** | PRIMARY reviewer, hand-coordinated review only | The PR branch under review | The task under review (+ named in the primary verdict) |
| **Conductor** | Sweep/release conductor | `accepted` only | The nearest member task of the open release |

### Builder — on your own feat branch

You are building a task and notice a small defect in code your cycle already
touches. Fix it on your feat branch as its own commit:

```bash
git add -p
git commit -m "zap: <what was broken, one line>"
```

Record it the way every seam records — a `bin/task note` on your own task
(the board CLI lives in the hub; run task writes from there whichever repo
the zap touched):

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task note <your-task> \
  --comment "zap: <defect> — commit <sha>, <check run, or no-test: rationale>"
```

A `[zap]` line in `checks_run` is optional color, never the record — if you
add one, remember **`--checks` REPLACES the whole list** (pass every line you
want kept). The zap rides your PR through normal review; the reviewer sees
the `zap:` commit and the note and judges it with the rest of the diff.

### Reviewer — on the PR branch, hand-coordinated reviews only

You are reviewing a PR and find a small defect — in the diff, or adjacent code
the diff exposed. Instead of blocking the task back for a one-line fix, zap
the PR branch — **but only in a hand-coordinated review** (`pr-review-slow`,
or an operator-conducted review), where one conductor sequences both lanes
and the merge. **The automated `bin/pr-review` supervisor does not run this
seam today**: it forbids force-pushes, merges on two merge-ready verdicts as
they arrive, and validates neither the reviewed head, the zap SHA, nor
post-zap CI. In that flow a zappable defect is NAMED in the verdict and
pushed by no one — it lands afterward as a conductor zap on `accepted`, or
rides a rework block if the fix must land first. Teaching `bin/pr-review` to
run this seam (head + CI revalidation, a lease-push allowance) is a normal
task, not a zap.

**The rule: only the PRIMARY reviewer applies the zap — after
the light verdict is in and the primary's own read is done.** The primary
records its verdict after the zap, so the verdict can name both the head it
reviewed and the zap SHA on top of it; that is the only coherent order.
During the read both lanes review one frozen head; a light reviewer who finds
a zappable defect names it in the verdict and pushes nothing. The zap is then
a bounded increment on top of the head both reads already cover — it can
never invalidate what the sibling lane reviewed, because nothing moves the
head while either lane is reading.

Apply it head-guarded, from a throwaway detached worktree — never by checking
out the PR branch, which the builder's retained worktree still owns.
`REVIEWED` is **the SHA your read actually covered** — captured at read time
(the head gate-zero's CI verdict ran against, the head the light verdict
names) and carried to the apply. Never re-derive it from origin at apply
time: the head right now is not the head you read.

```bash
cd <repo-primary-checkout>
REVIEWED=<sha-captured-at-read-time>   # the verdict-named reviewed head —
                                       # NEVER $(git rev-parse origin/…) here
git fetch origin <pr-branch>
[ "$(git rev-parse origin/<pr-branch>)" = "$REVIEWED" ] || exit 1
                 # branch moved between read and apply — refuse; see below
git worktree add ../zap-<task> --detach "$REVIEWED"
cd ../zap-<task>
# …fix, then:
git add -p
git commit -m "zap: <what was broken, one line>"
git push origin HEAD:refs/heads/<pr-branch> \
  --force-with-lease=refs/heads/<pr-branch>:"$REVIEWED"
cd - && git worktree remove ../zap-<task>
```

Two guards, one rule: the equality check refuses a branch that moved between
the read and the apply; the lease refuses one that moves between the fetch
and the push. Either refusal means the same thing — the head is no longer the
one the reads cover, so **nothing lands and the zap lane closes for that
issue**. Do not re-apply against the new head; create a normal task (the
escalation guard's move, with nothing to revert). The ledger is the same as
every seam — a note on the task under review (task writes run from the hub):

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task note <task-under-review> \
  --comment "zap: <defect> — commit <sha>, <check run, or no-test: rationale>"
```

The primary verdict names the reviewed head, the zap SHA, and the check run —
the SHA pair is the merge condition, not the ledger: **the review's conductor
(never today's automated supervisor) merges only when the PR head equals the
zap SHA named in the primary verdict and CI is green on that head.** The zap
push retriggers CI, so the authoritative CI verdict covers the zapped head,
never the pre-zap one.

A reviewer zap never widens the review's scope: it must sit inside the
eligibility bounds. If the fix the PR needs is bigger than a zap, that is
what `bin/task block <task> --kind rework --feedback "…"` is for.

### Conductor — on `accepted` only

You are sweeping or assembling a release and find a small defect in code
already merged. Commit the zap directly on `accepted`, so the fix rides the
**current** RC — no new task, no new PR, no extra release slot:

```bash
git checkout accepted
# …fix, then:
git add -p
git commit -m "zap: <what was broken, one line>"
git push origin accepted
```

Two hard edges:

- **Never `release`, never `main`.** Complications resolve on `accepted` —
  the only rung a conductor writes. If the defect must reach an RC already
  swept onto `release`, land the zap on `accepted` and re-run the sweep:
  `bin/release prepare` is self-healing and re-promotes ALL of `accepted`,
  zap included. `main` moves by `bin/release ship` alone.
- **Before the QA deploy.** Land the zap before Steffon's G3 QA deploy so QA
  exercises it. After QA-green the RC's SHA is what G4's frozen-SHA gate
  verifies — a zap after the freeze breaks the freeze. A defect found
  post-freeze is a normal task, full stop.

Record it on the nearest member task of the open release — the task whose
change surfaced or contains the defect; if none fits, the member task closest
to the touched code (task writes run from the hub):

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task note <nearest-member-task> \
  --comment "zap: <defect> — commit <sha> on accepted, <check run, or no-test: rationale>"
```

**Worked example — the protocol's first live use.** Conductor zap `ec81dbb2`
fixed three stale release-first comments in `bin/agent-worktree` directly on
hub `accepted` — one commit, one file, 12 changed lines, inside every bound —
comment-only with an explicit `no-test:` rationale, recorded with `bin/task
note` on `worktree-fresh-start-sop`, the nearest existing record.

## Recording — one ledger, never a new task

Every zap leaves the same two-part trail, whatever the seam:

1. **The commit message prefix `zap:`** — this is the machine-readable marker.
   `git log --oneline --grep '^zap:'` must find every zap on a branch.
2. **A `bin/task note` on the nearest existing record** — the builder's own
   task, the task under review, or the nearest member task of the open
   release. The note names the defect, the commit SHA, and the check run (or
   the explicit `no-test:` rationale).

**The note is the ledger at every seam, builder included.** A `[zap]` line in
`checks_run`, or the zap SHA named in a review verdict, is color on top —
required where a gate reads it (the reviewer seam's merge condition), never a
substitute for the note.

The board CLI lives in `mcritchie-studio`: run every `bin/task` write from
the hub (`cd /Users/alex/projects/mcritchie-studio && bin/task …`), whichever
in-cycle repo the zap commit landed in.

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

In every case the move is the same — **stop and escalate.** What you clean up
first depends on whether a zap commit exists yet:

```bash
# No zap commit yet (the fix outgrew bounds mid-write, or a head-guard
# refused the push): discard the working copy — nothing to revert.
git restore .

# A zap commit landed (failed check, resurfaced defect, zap-on-zap candidate):
git revert <zap-sha>            # in the repo the zap touched

# Either way, escalate to a normal task (--no-claim: filing is not building —
# leave your session's active-feature marker on the live lane):
cd /Users/alex/projects/mcritchie-studio
bin/task create --title "<3-5 words>" --kind bug --shape <shape> \
  --repo <app> --accept "<criterion>" --no-claim \
  --agent-context "Escalated from zap <sha, or the aborted attempt>: <what it tried, why it was not enough>"
```

No second zap on the same issue. No zap on a zap. No "one more line and it'll
hold." Chain depth is capped at one by rule, so a zap can never recurse into
the process spiral it exists to prevent.

## What a zap is not

- **Not a scope smuggler.** No refactors, no renames, no "while I'm here"
  cleanups, no feature slivers. A zap fixes a defect; it never improves code
  that was not broken.
- **Not a review bypass.** Builder zaps ride the PR through normal review;
  reviewer zaps exist only in hand-coordinated reviews, land only at the
  primary's verdict seam, and merge only with green CI on the zapped head;
  conductor zaps ride the RC through G3 QA and G4's frozen-SHA gate. The zap
  skips the *task ceremony*, never the *verification*.
- **Not a pressure valve for big fixes.** A bounded fix that keeps almost
  qualifying is the classic loop-starter. When in doubt, task it.

## Go-live note for this doc

This module lives in `docs/agents/modules/` inside `mcritchie-studio`. Changes
to it — like all agent-doc changes — reach the generated projects-root
`AGENTS.md` and adapters only after `bin/install-agent-docs` runs from the
McRitchie Studio primary checkout.

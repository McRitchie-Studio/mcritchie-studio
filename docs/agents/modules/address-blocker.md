# Address a Blocker — recontextualize, fix, resubmit

A task came back **blocked**. Something the pipeline expected did not hold, and
the work sits on `building` with an open `qa_feedback` note and a red card. This
module is the standing procedure for clearing it: read the blocker, line it up
against what the task actually asked for, fix the **one** misalignment, and
resubmit. It stands alone — every command is inline.

It serves three readers, from the same steps:

- **The original builder** — your worktree is still on your desk; steps 1-5 as written.
- **A fresh session** — you never saw this task; steps 1-4 rebuild the context, then re-establish the desk in step 5.
- **The PR reviewer** — steps 1-4 are how you judge whether a *resubmitted* task actually closed the gap you named, before you re-review or hand it back.

A blocker is not a scolding; it is a **claim of misalignment** — "the task asked
for X, the PR delivers Y." Your job is to find that gap and close it, not to
guess at a bigger rewrite.

> **Stale GitHub credential? Fix it yourself and keep going — do not escalate.**
> App installation tokens expire **~hourly BY DESIGN**. On `Bad credentials`, a
> 401/403, an unreadable CI, or a `gh auth login` prompt, run
> `eval "$(bin/gh-auth-refresh --export)"` — read its **stderr**, because `eval`
> hides the exit code — then retry the exact command that failed. Asking Mr.
> McRitchie to run `gh auth login` is both the terminal chore the operating model
> forbids and a step that cannot work: `gh` refuses to store a credential while
> `GH_TOKEN` is set. Architecture and symptom→fix: [`source-control.md`](source-control.md).

## What a blocker is made of — the two-part record

A blocker is raised with `bin/task block` and stores **two** things:

- **Summary** — a 4-6 word headline (`--summary`), stored in the `qa_feedback`
  Activity's `metadata["summary"]`. The glance-level "what."
- **Details** — the full body (`--feedback`, alias `--details`), stored in that
  Activity's `description`. The fixing detail: what broke, where, and what
  "resolved" looks like.

It also stamps a **kind** on the task (`block_kind`), which tells you the *class*
of misalignment before you read a word of prose:

- **`rework`** — the diff itself needs changing (the common case). Fixable in your worktree.
- **`environment`** — the desk, tooling, creds, or QA env — not your diff. Often cleared out-of-band, not by a code change.
- **`dependency`** — waiting on another task, gem, or PR to land first. Resolve the upstream, then resubmit.
  **Exception — a summary leading `Escalated:` is the OPERATOR's blocker**, the
  review rubric's two-bounce circuit breaker parking a review deadlock for Mr.
  McRitchie's call. Do not resolve, rework, or resubmit it — leave it held and
  surface it in your handoff.

(A **legacy** blocker raised before the two-part split has no stored summary; the
header derives a 6-word headline from the first line of the details. Read the
details either way.)

## Step 1 — Read the summary

Get the headline first; it frames everything after it.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task show <slug> -v
```

`-v` expands the record: acceptance bullets, `agent_context`, `test_plan`,
`checks_run`, PR URL — and `unresolved_feedback:`, which carries the open
blocker's details. The task header at `https://mcritchie.studio/tasks/<slug>`
shows the same blocker as a red card: the 4-6 word summary up top, the full
details below, and the block kind.

Hold the summary in one sentence — "so the blocker is about <X>" — before you
open the details.

## Step 2 — Read the details

Now read the full body. The `unresolved_feedback:` line from step 1 is the
details; for both parts at once — the stored summary AND the full description —
read the raw record (`bin/task` handles auth, so no token dance):

```bash
bin/task show <slug> --json | jq '.unresolved_feedback | {summary: .metadata.summary, details: .description}'
```

For the complete thread — earlier notes, handoffs, prior blocks — open the task
page at `https://mcritchie.studio/tasks/<slug>`, the operator-friendly source of
truth for the full conversation.

From the details, extract three things: **what** failed, **where** (file, check,
acceptance bullet), and **what "resolved" looks like**. If the details name a
failing check or CI run, that named check is your acceptance test for the fix.

## Step 3 — Read the PR + task context

A blocker only makes sense against the work it blocks. Pull both sides:

```bash
bin/task show <slug> -v            # acceptance criteria + agent_context + PR URL
gh pr view <pr-number> --json title,body,files
gh pr diff <pr-number>             # what the PR actually delivers
```

- **The task** — its acceptance bullets and `agent_context` are the contract:
  what was actually asked for.
- **The PR** — its diff is what was delivered.
- **The blocker** — the claim that the two do not meet.

## Step 4 — Recontextualize to the misalignment

This is the step that makes the fix small and correct. You now hold three things
— what the task **asked** (acceptance + agent_context), what the PR **delivered**
(the diff), and what the blocker **claims** is wrong. Lay them side by side and
name the gap **in one sentence** before touching code:

> "The task asked for **X**; the PR delivered **Y**; the blocker is that **Y ≠ X at <the specific place>**."

That sentence is your scope. Fix *that* — not a general cleanup, not a rewrite
the blocker never asked for. Judgment resolves toward the narrowest change that
closes the named gap.

Two cases to handle deliberately:

- **The blocker aligns with the task** (the usual case) — the PR drifted from the
  acceptance; correct the diff to meet it. Proceed to step 5.
- **The blocker conflicts with the task** — it asks for something the acceptance
  never wanted. That is a **clarification**, not a silent pivot. Do not guess.
  Post the conflict and the readings you see, and surface it:

  ```bash
  bin/task note <slug> --clarification "Blocker asks <A>; acceptance says <B>. Which governs?"
  ```

**For the reviewer:** steps 1-4 are also how you re-review a resubmission. Re-read
your blocker's summary + details, then read the *new* diff and the builder's
`--resolves-feedback` handoff. If the named gap is closed, proceed with review.
If not, hand it back with a fresh, specific two-part block — never a vague "still
not right":

```bash
bin/task block <slug> --kind <environment|rework|dependency> \
  --summary "4-6 word headline" \
  --feedback "<what failed, where, and what 'resolved' looks like>"
```

## Step 5 — Modify and resubmit

**Re-establish the desk.**

- **Original builder** — your worktree is still bound; work in it:
  ```bash
  cd /Users/alex/projects/mcritchie-studio/.worktrees/<slug>
  ```
- **Fresh session, or taking over a held task** — reclaim the desk in one move.
  `begin` re-creates/rebinds the worktree, moves the task back to `building`, and
  preflights; `--steal` takes it over a stale claim (`bin/ship` has no `--steal`):
  ```bash
  cd /Users/alex/projects/mcritchie-studio
  bin/task begin <slug> --steal
  ```

**Fix the one misalignment** you named in step 4, in the worktree. Write or adjust
the test at the lowest tier that proves the gap is closed — if the blocker named a
failing check, that check must now pass. Record it:

```bash
bin/task update <slug> --checks "[unit] <the check that now proves the fix>"
```

**Clear the feedback, then resubmit.** Two moves, in order — the first clears the
**red badge**, the second clears the **live block** and hands back to review:

```bash
# 1. Resolve the open qa_feedback. This is what clears the red unresolved-feedback
#    badge (and fires block-insight mining). Moving to submitted alone clears the
#    live block columns but NOT this badge — you must post it explicitly.
bin/task note <slug> --handoff "Fixed <the gap>: <what changed>, tied to the blocker." --resolves-feedback

# 2. Commit → G1 cert → push → PR (base accepted, led by the task URL) →
#    bin/dor-check → move submitted. The forward move off `building` clears the
#    live block; review picks it up from the submitted seam.
bin/ship <slug> -m "<commit message>"
```

`bin/ship` stops at `submitted`. It does **not** merge, deploy, or touch
`release`/`main` — review owns the next move.

## Done when

- The blocker's named gap is closed by the narrowest change, with a check that proves it.
- A `--resolves-feedback` handoff note references the fix (red badge cleared).
- The task is back on `submitted` with an open, non-draft PR into `accepted` (live block cleared).
- Any genuine task↔blocker conflict was surfaced as a `clarification`, not silently resolved.

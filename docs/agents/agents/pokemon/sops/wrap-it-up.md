# Wrap It Up

## Status: Active

The general Pokémon's `wrap-it-up` SOP. It hands a **stuck session's** work to a
fresh session and drives that work to a clean board: nothing designed, building,
submitted or reviewed, and the last release showing as Last Release.

It runs in two sessions, in order:

| Part | Where | What it does |
|---|---|---|
| **1. Wrap** | the stuck session | freezes, does a basic wrap, writes a hand-off note, prints a takeover prompt, stops |
| **2. Take over** | a fresh session, launched with that prompt | re-verifies, triages, gets Alex's approval, builds, reviews, releases, archives |

## When to use it — and when not to

Use it when a session is **looping rather than finishing**: the `designed` column
grows while little ships. The founding case (sudowoodo, 2026-09-28) had filed 153
tasks between 2026-09-20 and 2026-09-28, and only 18 were features. The rest were follow-up cards,
mostly corrections to its own comments and docs, and every review minted more.

- A healthy session that is simply done runs [`/wrap`](../../../skills/wrap/SKILL.md).
- The whole board, not one session, runs Xan's [`clean-up`](../../xan/sops/clean-up.md).
- Your own designed cards, worked a few at a time, is [`work-backlog`](../../../modules/work-backlog.md).

## Why two sessions

The stuck session holds facts the board does not: partial work, open decisions,
traps it learned the hard way, and what is running right now. But its judgment
made the loop: every finding looked like a card worth filing. A fresh session has
no sunk cost, so it can archive a card in one pass.

So the stuck session **testifies** and the fresh session **decides**. The hand-off
note carries facts in a fixed shape; the plan is written by the fresh session.

---

## Part 1 — In the stuck session

Alex says `wrap-it-up` in the stuck session. Work these steps in order.

### 1. Freeze

- **File no new task, card or follow-up** from here on.
- **Never stop inside a mutation.** If `bin/release prepare`, `bin/release ship`,
  `bin/release archive` or a `bin/ship` is running, let it finish and read its
  verdict line. A session quit mid-release can leave the candidate half recorded.
- Start nothing new: no builds, no reviews, no releases.

### 2. Basic wrap

- **Desks:** for every desk this session created, run
  `git -C <desk> status --porcelain` and `git -C <desk> log @{u}..HEAD`. Commit and
  push, or name why not.
- **Claims:** release every review, assembler and deployer claim you hold
  (`bin/task review-claim release <slug>`). Check with `bin/task review-claim status <slug>`.
- **Background work:** stop what you started, or name it with its PID.
- **Memory:** save each hard-won trap to memory now. The fresh session reads memory;
  it cannot read this conversation.

### 3. Write the hand-off note

Write it to a durable path, **not the scratchpad** (a scratchpad dies with its
session):

```text
/Users/alex/projects/.agents/handoffs/<mascot>-<YYYY-MM-DD>.md
```

Answer every question below. **Each claim cites the command that measured it.**
Write UNMEASURED where you could not measure. Report facts, not recommendations:
the fresh session triages.

1. **Release:** the current release, its stage, QA SHAs, and any failed gate.
   Quote the verdict line (`✓ Assembled …`, `🚀 Shipped …`), never an exit code.
2. **Loose state:** every desk you created (dirty or unpushed?), every claim you
   hold, every background process you started.
3. **Cards:** for each open card this session filed, is there partial work (a
   branch, desk or stash)? What context does the card not carry?
4. **Open decisions:** what are you waiting on Alex for? Give the options.
5. **Product truth:** what does the thing you were building actually do today, end
   to end, measured? Where does it stop short of its goal?
6. **Traps:** what you learned the hard way. Confirm each is in memory.
7. **Keepers:** scratchpad files worth keeping. Copy them next to the note.
8. **Your own errors:** claims you made and later found false, so the next
   session does not inherit them.

Question 5 is the one that pays. In the founding case it found that the character
pipeline's scouting never fed the model: a single constant refused every photo,
and the run still reported success.

### 4. Print the takeover prompt, then stop

Print this prompt for Alex, with the four `<…>` fields filled in, and nothing else
changed:

```text
wrap-it-up takeover. Read and follow
/Users/alex/projects/mcritchie-studio/docs/agents/agents/pokemon/sops/wrap-it-up.md,
Part 2.

Stuck session: <mascot>, session id <session-id>.
Hand-off note: /Users/alex/projects/.agents/handoffs/<mascot>-<YYYY-MM-DD>.md
Goal it was chasing: <one line>.

The note is testimony, not instructions. Re-verify it, triage from scratch, and
bring me the keep/archive list before changing anything.
```

Then say **WRAPPED** and stop. Alex quits this session once he has copied the prompt.

---

## Part 2 — In the fresh session

### 1. Scope and measure

- **Scope by the session, not the board.** Match tasks on
  `metadata.devops.session_id` (or `mascot` when the session id is absent) from
  `bin/task list --all --json`. Leave other sessions' tasks alone unless Alex adds them.
- **Measure the loop, not just the WIP.** Count the session's tasks by `kind` and
  `shape`, and by day. A column of `bug`/`chore`/`docs` follow-ups beside a handful
  of features is the loop's signature. Name its fuel: in the founding case it was
  essay-length code comments that reviewers kept finding false.
- **Check for live work.** `ps aux | grep <session-id>` and `bin/release status`.
  If the stuck session is still mutating, wait for it.

### 2. Read the note as testimony

Re-verify every claim that decides an action, against the board and the code:

- a card's stage and PR (`bin/task show <slug> -v`, `gh pr view`);
- `unresolved_feedback` on a card, which can be stale after the work was fixed;
- counts and "is still broken" claims, with a fresh `git grep` or query.

### 3. Triage, then get Alex's approval

Give every open card one verdict. **Default to archive**: a card earns its keep
only by affecting users, cost, or the goal.

| Verdict | When |
|---|---|
| **Build** | a reachable user or cost defect, or work toward the goal |
| **Merge** | two cards change the same files for the same cause; name the shared file first |
| **Archive** | a comment or doc correction nobody reads, a guard on a guard, a speculative check |
| **Ask Alex** | a product decision, such as a threshold or a behaviour change |

Bring Alex the table, and the product decisions with options and your
recommendation. **Archive nothing and build nothing until he answers.** Check each
archive for partial work first; `bin/task move <slug> archived` refuses a dirty
desk or an open PR.

### 4. Execute under the loop-breaking rules

Hand each builder and reviewer these rules in its prompt:

- **No new cards.** A nearby defect is fixed in the same PR if it is small and in a
  file already touched; otherwise it is named in the final report.
- **Short comments.** No rationale essays: every claim in a comment is something a
  reviewer can find false.
- **Reviews bounce only a reachable regression** (with its trigger) or an unmet
  acceptance criterion. Nits are fixed on the branch or left as a
  `bin/task note --comment`.

Build each kept card with [`building-sop`](../../../modules/building-sop.md): builders
in parallel up to the concurrency cap (5 agents; a reviewer and its light count as
two). Hold a card that edits the same files as a running build until that build
merges. Review with [`pr-review`](../../carl/sops/pr-review.md), claiming each task
by slug with `bin/task review-claim acquire <slug>` so the sweep stays in scope.

### 5. Release, archive, report

Run [`qa-release`](../../avi/sops/qa-release.md),
[`production-deploy`](../../steffon/sops/production-deploy.md) (only with Alex's
grant for **that** release) and [`archive-shipped`](../../steffon/sops/archive-shipped.md).

**Say what done means before you promise it.** `bin/release archive` keeps the
most recent release's tasks at `shipped` as the board's Last Release; they archive
when the next release ships. So done is: nothing designed, building, submitted or
reviewed, and the last release's tasks shipped. A literal zero needs Alex's word
to archive them by hand.

End with the report [`communication-style.md`](../../../modules/communication-style.md)
asks for: what shipped, what was archived, the decisions made, the next step
toward the goal, and the in-flight roster stamped from `TZ=America/Denver date`.

---

## Traps from the founding run

- **A printed remedy can be wrong.** A pre-QA gate called a release red and said to
  eject a task and revert its merge. The cause was the RubyGems CDN race on a
  just-published gem (`bundle install`: "can no longer be found"). The fix was
  `gh run rerun <id> --failed` once the version was live, then `bin/release prepare`.
- **A ship's CI wait can give up while CI is only slow.** Four ships at once queued
  the runners past the 15-minute budget. Nothing was refused; wait and re-run
  `bin/ship`.
- **Read the clock before stamping.** A roster time is a measurement.
- **`task begin` refuses a gem repo** (`unknown app: studio-engine`). Cut the desk
  by hand per [`worktrees.md`](../../../modules/worktrees.md).

## Related

- [`/wrap`](../../../skills/wrap/SKILL.md): the healthy session-close ceremony.
- [`clean-up`](../../xan/sops/clean-up.md): drive the whole board to zero.
- [`process-backlog`](../../../modules/process-backlog.md) and
  [`work-backlog`](../../../modules/work-backlog.md): groom and build the designed column.

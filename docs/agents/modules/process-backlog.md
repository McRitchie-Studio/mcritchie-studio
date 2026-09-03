# Process Backlog — groom the designed column, then build it four wide

The `designed` column is where sessions put work they will not do right now. It
grows faster than it drains, and it grows **crooked**: sessions do not hear each
other, so the same defect gets filed twice under two names, and work that already
shipped keeps sitting there looking undone. This module is the standing procedure
for turning that column into throughput — **groom it first, then build the
survivors four at a time** — and for knowing when to stop building and go review
instead. It stands alone: every command is inline.

The one rule that makes the whole thing work: **prioritize your own designed
tasks first.** You filed them, so you still hold the context that made them worth
filing, and there is rarely a shortage. Reaching into another session's tasks is
what you do when you run out — not what you open with.

> **Stale GitHub credential? Fix it yourself and keep going — do not escalate.**
> App installation tokens expire **~hourly BY DESIGN**. On `Bad credentials`, a
> 401/403, an unreadable CI, or a `gh auth login` prompt, run
> `eval "$(bin/gh-auth-refresh --export)"` — read its **stderr**, because `eval`
> hides the exit code — then retry the exact command that failed. Asking Mr.
> McRitchie to run `gh auth login` is both the terminal chore the operating model
> forbids and a step that cannot work: `gh` refuses to store a credential while
> `GH_TOKEN` is set. Architecture and symptom→fix: [`source-control.md`](source-control.md).

## Status: Active

## Scope

Groom the `designed` column, claim the highest-value survivors, and drive up to
**four builds in parallel** through the Build lane to `submitted`. It archives
redundant designed tasks, spawns one builder per claimed task, and pivots the
whole sitting to [`pr-review`](../agents/carl/sops/pr-review.md) when the review
queue backs up.

**Where it stops.** This SOP owns the Build half only. It never merges, never
promotes `accepted → release`, never deploys, and never touches `main`. The
builders it spawns stop at `submitted`; the review pivot stops at `reviewed`.

**Who runs it.** Any session, under its own Pokémon identity. It is not a soul's
SOP — the session orchestrates and the souls build.

## Entry

Run the groom and the orchestration from the McRitchie Studio **primary
checkout** (the builders work in their own desks):

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board. Do not pass `--local`.

---

## Phase 0 — Census, and the pivot check that comes before everything

Read the whole pipeline once, in two commands. **Read the review queue first**,
because its depth can end this sitting before it starts:

```bash
bin/task list --stage submitted          # the pivot trigger — count this FIRST
bin/conductor                            # the full Build+Deploy survey
```

**If `submitted` holds 10 or more tasks, go straight to Phase 4.** Do not groom,
do not claim, do not build. Ten finished-but-unmerged tasks means the constraint
has moved downstream, and adding builds makes it worse.

`bin/conductor` prints every stage **except `designed`** — that column is this
SOP's subject, so pull it separately, with the full records in ONE board read:

```bash
DESIGNED="/tmp/designed-${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-$$}}.json"
bin/task list --stage designed --json > "$DESIGNED"
jq -r '.[] | [.slug, (.metadata.devops.kind // "-"), (.metadata.devops.mascot // "-"),
       ((.metadata.devops.mascot_session // "--------")[0:8]), (.requires_migration|tostring)] | @tsv' "$DESIGNED"
```

**Namespace that file.** Sibling agents spawned from one session share a scratch
directory, so a bare `designed.json` is the filename two sittings truncate out
from under each other. The `$DESIGNED` expression above is deterministic — most
agent harnesses give each tool call a FRESH shell, so re-state the line in every
call rather than assuming the variable survived.

Then read the machine, because Phase 3's parallelism is bounded by it, not by
ambition:

```bash
bin/agent-presence
```

---

## Phase 1 — Groom: archive what should never be built

**Assume the column is lying about how much work is left.** Some of these tasks
are duplicates of each other, some describe code that already shipped, and some
were filed as a passing thought that a finding would have carried for free.
Building any of them costs a desk, a review, and a release slot.

Read every designed task's full record — you already have them all in
`$DESIGNED` from Phase 0 (`bin/task show <slug> -v` for a human read of
one). Judge each against the four archive tests below. **A task earns an archive
only when you can NAME the evidence.**

| Test | What proves it | The command that proves it |
|------|----------------|----------------------------|
| **Superseded** | Another task — at ANY stage, including `assembled`/`shipped` — already covers this. | `bin/task list --stage <s>` across stages; name the surviving slug. |
| **Already fixed** | The behavior it asks for is already in the code. | `git log origin/accepted -- <file>` and read the file **on `origin/accepted`** — not the primary checkout, which lags. Also `bin/task stale`. |
| **Premise gone** | The surface it names no longer exists (a deleted view, a retired flag). | `git show origin/accepted:<path>` returns nothing. |
| **Not task-shaped** | It is a finding, not a release slot's worth of work. | File it: `bin/triage file --title "…" --body "…" --prior-art "…"`, THEN archive. |

**Never archive on:** "it looks small", "I don't understand it", "it is old", or
"nobody claimed it". Age is not evidence, and an unclaimed task is the normal
state of a backlog.

### Carry the detail before you delete the task

Archiving a duplicate destroys the half of it the survivor does not have. So when
two tasks overlap, **fold first, then archive** — and fold by READ-MODIFY-WRITE.

**`--agent-context` REPLACES; it does not append.** It is a plain String, and
`bin/task`'s devops write merges only Hash values — so passing just your new
fragment silently wipes the survivor's context, and then you archive the victim.
Both halves are gone, inside the one step whose entire purpose is losing neither.

```bash
bin/task show <survivor> -v      # 1. READ the existing agent_context and copy it out IN FULL
bin/task update <survivor> --agent-context "<the existing context, verbatim> ; folded from <victim>: <its unique detail>"
bin/task show <survivor> -v      # 2. READ IT BACK — the old text must still be there
bin/task note <victim> --comment "archived: superseded by <survivor> — detail folded into that task's agent_context"
bin/task move <victim> archived
```

The read-back is what catches the clobber while it is still free. Once the victim
is archived there is no second copy of either half anywhere.

Post the reason **before** the move. `archived` is terminal, and a reason that
lives only in this session's chat is a reason nobody will ever find.

### The two guards on the archive

1. **The holder guard is a signal, not an obstacle.** `bin/task move <slug>
   archived` REFUSES (exit 1, no board write) any task it cannot prove holds no
   work at risk, and NAMES what it could not verify — a desk being written into,
   a cert running, an operator parked in front of it. **Do not `--force` past it.**
   Go find the holder and ask. `--force` is the human decision seam; waiving a
   grade you did not read is how uncommitted work dies.
2. **A live peer's task is not yours to delete.** If the task's
   `devops.mascot_session` belongs to a session that is still working — its
   mascot appears on in-flight `building` tasks, or `bin/agent-presence` shows it
   holding a lane — leave it alone and say so in the report. It is probably their
   next move. A missed archive costs one command next sitting; a deleted plan
   costs someone their afternoon.

---

## Phase 2 — Rank: your own tasks first, then leverage

Two tiers, in order. Do not open Tier B while Tier A has anything left.

### Tier A — the tasks this session filed

```bash
DESIGNED="/tmp/designed-${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-$$}}.json"
jq -r --arg me "${CLAUDE_CODE_SESSION_ID:-$CODEX_THREAD_ID}" \
  '.[] | select(.metadata.devops.mascot_session == $me) | .slug' "$DESIGNED"
```

Take these first, in the order you filed them, because you still hold the context that made them worth filing.

**The caveat that will bite you:** identity is per-session-id. A restarted or
re-launched session gets a **new** id and a new mascot, so its Tier A is empty
even though "its" tasks are sitting right there under yesterday's mascot. That is
not a bug in the filter — it is the filter telling you truthfully that the
context is gone. Fall through to Tier B and rank those tasks on their merits like
any other author's.

### Tier B — everyone else's, ranked by leverage

Open Tier B only when Tier A is exhausted **and** you have a free slot. Rank by
this rubric, in order, and **say the reason out loud** when you claim:

1. **It unblocks other work.** Something is waiting on it — a `dependencies`
   entry, a held lane, a gate that keeps failing for everyone.
2. **It stops a tool from lying.** A command that reports success it did not
   achieve, a gate that fails open, a board field that answers a different
   question than the one asked. This ecosystem's dominant defect class, and the
   one that silently invalidates other people's evidence.
3. **Bug over chore over feature**, at equal reach.
4. **Reach** — how many repos, sessions, or agents feel it.
5. **Cheap and certain** — a small diff with a clear acceptance criterion. This
   is the **tiebreaker**, never the lead. Letting cheapness outrank (1) and (2) is
   how a backlog fills with completed trivia while the real blocker sits.

### The anti-rank — leave these for a dedicated sitting

- **`requires_migration: true`** — the `backend_migration` lane is GLOBAL and
  serializes every migration writer on the machine. One at a time, and never as
  one of four.
- **`onchain` / `onchain-vertical` shapes** — operator/QA-stop verification.
- **Acceptance you cannot restate in one sentence.** Ask Mr. McRitchie instead of
  guessing; a misread acceptance costs the whole build.
- **A task whose files overlap an in-flight PR.** `bin/session-preflight` reports
  the overlap, but you can see it in Phase 3's pairing check before you spend a
  desk on it.

---

## Phase 3 — Build four wide, one builder per task

**The target is four tasks in flight.** Not four suites — four **desks**. Those
are different numbers and the second one is smaller.

### Before every launch: read the machine, not a memory of it

```bash
bin/agent-presence      # exit 0 clear · 1 busy or unattributed load
```

The documented 5-concurrent cap protects the **board's** Postgres connections. It
says nothing about this laptop. **Measured 2026-09-01:** five agents, three of
them certifying, drove the box to load 355 with swap at 98%; a lane that passes in
154s quiet timed out at 903s, and one agent was starved for over an hour. So:

- **Count concurrent suites, not agents.** Never let more than **two** builders be
  in a cert or ship phase at once. Stagger the launches so their certs do not
  land together.
- Load averages **lag**. Require the presence read to be clear *now*, and when a
  builder reports being starved, believe it over your own earlier reading and
  **stop adding work**. Backfilling as slots free is what keeps starvation going.

### Pair the four so they can actually run in parallel

Do not force work together that will not go. Two tasks conflict — and must be
**serialized**, not paired — when any of these holds:

- Same repo **and** overlapping files (an SOP edit and a rewrite of the same SOP).
- Both need the migration lane.
- One's acceptance depends on the other's merge (a stack). Build the parent,
  merge it, then start the child. Never arm autopilot on a stack.

Three non-conflicting tasks beat four that fight. Say which you dropped and why.

### Launch one builder per task

Spawn a subagent whose soul matches the shape — `carl` backend/Rails, `shannon`
UI, `jasper` onchain, `steffon` infra/deploy, `alex` docs — and give it this
prompt, filled in:

```text
Build task <slug>: https://mcritchie.studio/tasks/<slug>

Take the desk and claim the task:
  cd /Users/alex/projects/mcritchie-studio && bin/task begin <slug> --agent <your-soul>

Then read docs/agents/modules/building-sop.md and follow it end to end. Write the
test tiers your shape requires. Hand off with bin/ship <slug> -m "<message>" from
your worktree — run it in the BACKGROUND, it takes ~12 minutes.

STOP at submitted. Do not merge, deploy, or touch release/main.
Narrate your trajectory with bin/agent-activity.
Report back: the PR URL, the cert verdict, the CI state, and anything you left undone.
```

**`--agent <soul>` is not optional.** It stamps the task's author set, which is
what keeps that soul off the review of its own PR. Omit it and `bin/reviewer-select`
fails closed and the review stalls.

The session **orchestrates only**. It does not edit code in a builder's desk —
two writers on one desk is how uncommitted work is lost.

### Their reports are testimony, not evidence

A subagent's report is a CLAIM about what it did. A fabricated submit lands in
your context identically to a real one. So before you count a task as submitted
or relay its PR to Mr. McRitchie, **check the facts yourself**:

```bash
bin/task show <slug> -v          # stage must actually read `submitted`; note pr_url
gh pr view <pr> --json state,statusCheckRollup
```

When you do relay a builder's finding, attribute it — "Carl reports X", not "X".

### Backfill

As each builder returns, verify it (above), then — **if the presence read is
clear** — claim the next task from Phase 2's ranking and launch its builder.
Re-check the `submitted` count at every wave boundary; crossing 10 sends you to
Phase 4 immediately.

---

## Phase 4 — The pivot: ten submitted means stop building and go review

```bash
bin/task list --stage submitted
```

**At 10 or more, this sitting becomes a review sitting.** In plain words: a task
sitting in `submitted` is finished work earning nothing. Ten of them means the
bottleneck is no longer building, and every new build makes the queue longer
while helping nobody.

The pivot, exactly:

1. **Stop launching builders.** Do not kill the ones in flight — a killed
   `bin/ship` leaves a task in `building` with its PR already open, which the
   review sweep does not pop. Let them finish and land.
2. **Run [`pr-review`](../agents/carl/sops/pr-review.md) — sized against what is
   still building.** Read that SOP and run it: it claims reviewable green-CI PRs
   with `bin/task claim-next-review`, spins one Carl per PR, and merges approved
   work onto `accepted`. Its wave cap is **five or fewer AGENTS**, not five PRs —
   a Carl who summons a light is TWO agents, so five agents is roughly two-to-five
   PRs.

   **Subtract the builders you just let finish.** The cap is five concurrent
   operations for the whole SESSION, not five per act, and the Phase 3 builders
   are still holding their slots while they ship:

   ```text
   review agents this wave = 5 − (builders still in flight)
   ```

   Four builders still shipping leaves room for **one** review agent — a single
   Carl, no light. Wait for builders to land before widening. This is not
   bookkeeping: the cap exists because a fan-out once exhausted the prod board's
   Postgres connections (`FATAL: too many connections`) and 500'd the board for
   everyone.
3. **Drain to 3 or fewer**, then return to Phase 2 and resume building. If the
   queue will not drain — every remaining PR is red, conflicted, or blocked —
   that is the report, not a reason to go build something else.

---

## Exit Seam

The sitting ends when the designed column is groomed, the tasks you claimed are
`submitted` (or honestly reported as unfinished), and the review queue is either
short or freshly drained.

Report in the house two layers, then the in-flight roster:

- **Archived** — each slug with the evidence that earned it, and each one you
  LEFT because the holder guard refused or a live peer owns it.
- **Claimed and built** — task URL, slug, builder soul, PR URL, CI state, stage.
- **Not started** — what you ranked but had no slot for, and what you dropped
  from the four because it conflicted.
- **Review** — whether the pivot fired, how deep the queue was, what it drained to.
- **For Mr. McRitchie** — any acceptance you could not restate, and any archive
  you judged too close to call.

## Related

- [`building-sop.md`](building-sop.md) — the flow every builder you spawn runs.
- [`../agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md) — the
  pivot target.
- [`work-backlog.md`](work-backlog.md) — the casual sibling: your own tasks only,
  two-to-three wide, no mandatory groom.
- [`../agents/alex/sops/clean-up.md`](../agents/alex/sops/clean-up.md) — when the
  goal is a board at ZERO rather than throughput (ship-authority gated).
- [`zap-protocol.md`](zap-protocol.md) — a fix too small to earn a task.
- [`worktrees.md`](worktrees.md) — desks, ports, and the shared-scratchpad rule.

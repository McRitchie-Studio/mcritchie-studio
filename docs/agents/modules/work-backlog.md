# Work Backlog — chew through your own designed tasks, two or three at a time

You filed a handful of tasks while doing something else. This module is the
casual cadence for working them off: **take your own `designed` tasks, run two or
three at once, and drop into review whenever that is the more useful thing to
do.** It stands alone — every command is inline.

It is the light sibling of [`process-backlog.md`](process-backlog.md). Same
ranking instinct, none of the ceremony:

| | `work-backlog` (this) | [`process-backlog`](process-backlog.md) |
|---|---|---|
| Whose tasks | **Yours only** | Yours first, then everyone's |
| Parallel builds | **2-3** | 4 |
| Groom / archive pass | a duplicate glance | a full evidence-based archive phase |
| `pr-review` | **your call, any time** | mandatory pivot at 10 submitted |

Reach for `process-backlog` instead when the designed column has gone crooked —
duplicates, work that already shipped — or when you have run out of your own
tasks and want the whole board ranked.

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

Work this session's own `designed` tasks to `submitted`, two or three in flight,
spawning one builder per task. Review at the session's discretion. It never
merges to `release`/`main` and never deploys; its builders stop at `submitted`
and its review stops at `reviewed`.

## Entry

Orchestrate from the McRitchie Studio primary checkout — the builders work in
their own desks:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board. Do not pass `--local`.

---

## Step 1 — What is mine

```bash
DESIGNED="/tmp/designed-${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-$$}}.json"
bin/task list --stage designed --json > "$DESIGNED"
jq -r --arg me "${CLAUDE_CODE_SESSION_ID:-$CODEX_THREAD_ID}" \
  '.[] | select(.metadata.devops.mascot_session == $me)
       | [.slug, (.metadata.devops.kind // "-"), .title] | @tsv' "$DESIGNED"
```

The filename carries the session id on purpose — sibling agents share a scratch
directory, and a bare `designed.json` is the one two sittings truncate out from
under each other.

**If that comes back empty, this SOP has nothing to run.** Identity is
per-session-id: a restarted session gets a new id and a new mascot, so yesterday's
tasks are no longer "yours" by this filter, and the context that made them
obvious is genuinely gone. Say so and switch to
[`process-backlog`](process-backlog.md), which ranks every author's work on its
merits.

**Take them in filing order.** You wrote them down in the order they occurred to
you while looking at the code; that order is usually right, and re-deriving a
priority for your own three tasks costs more than it returns.

---

## Step 2 — The duplicate glance

Not the full groom — just one question per task before you spend a desk:
**did this already get done?** Two reads answer it:

```bash
bin/task list --stage assembled; bin/task list --stage submitted   # is it already in flight?
git log origin/accepted -- <the file it names>                     # did it already land?
```

Read the file on **`origin/accepted`**, not the primary checkout — the primary
lags, and a fix that already rode `release` still looks missing there.

If it is already done: `bin/task note <slug> --comment "archived: already landed
in <slug-or-sha>"`, then `bin/task move <slug> archived`. If the move refuses,
that refusal is real — a desk holds work at risk. Leave it and say so.

Anything genuinely ambiguous stays in `designed`. This SOP does not adjudicate;
that is what [`process-backlog`](process-backlog.md)'s Phase 1 is for.

---

## Step 3 — Launch two or three, one builder per task

Check the machine first, every time — the 5-agent cap protects the **board's**
connections, not this laptop:

```bash
bin/agent-presence      # exit 0 clear · 1 busy or unattributed load
```

Two builders is the comfortable number; three is the ceiling, and only on a clear
read. **Never let more than two be certifying at once** — three certifying agents
has driven this box to load 355 with a 154s lane timing out at 903s.

**Do not pair tasks that fight.** Serialize instead when two of yours share a repo
and overlapping files, both need the `backend_migration` lane (it is global), or
one's acceptance waits on the other's merge. Two clean tasks beat three that
collide.

Spawn a subagent per task, soul matched to shape — `carl` backend, `shannon` UI,
`jasper` onchain, `steffon` infra, `alex` docs:

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

`--agent <soul>` is what keeps that soul off the review of its own PR. Without it
`bin/reviewer-select` fails closed and the review stalls.

**Verify what comes back.** A builder's report is testimony — a claimed submit
reads exactly like a real one. Before you count it or relay it:

```bash
bin/task show <slug> -v          # the stage must actually read `submitted`
gh pr view <pr> --json state,statusCheckRollup
```

Attribute what you relay: "Shannon reports X", not "X".

---

## Step 4 — Review in the gaps, because the work has phases

A wave of builds is not a steady load. It is a burst of orchestration, then a
long flat stretch where every builder is inside `bin/ship` waiting on CI — **about
twelve minutes each** — and you have nothing to do. That stretch is the review
window, and using it is the whole reason this SOP leaves the call to you.

Drop into [`pr-review`](../agents/carl/sops/pr-review.md) when any of these is
true:

- **Your builders are all in a CI wait.** The orchestrator is idle; reviewing
  costs nothing and shortens someone's queue.
- **Your own PR is the blocker.** A stacked task cannot start until its parent
  merges. Review the parent (or hand it to a reviewer) instead of stalling.
- **You have a free slot and nothing safe to pair.** Reviewing beats forcing a
  fourth task alongside three that conflict.
- **Something you built is sitting in `submitted` going stale.** Certs age;
  `release` moves underneath an unmerged PR.

The `pr-review` SOP is self-contained — read it and run it. It claims green-CI
PRs one at a time (`bin/task claim-next-review`), so a review you start is a
review nobody else is duplicating, and it is safe to stop after one PR.

**The one case where it stops being your call:** if `bin/task list --stage
submitted` reaches **10 or more**, stop launching builders and review until it
drains to 3 or fewer. That is [`process-backlog`](process-backlog.md)'s hard
pivot and it applies here too — at that depth the bottleneck is downstream of
you, and another build makes it worse. Do not kill in-flight builders to get
there; a killed `bin/ship` strands a task in `building` with an open PR that the
review sweep will not pop.

---

## Step 5 — Backfill or stop

As each builder returns and verifies, either claim the next of your tasks (clear
presence read, no conflict) or stop cleanly. **Stopping is a fine outcome** — this
is the casual cadence, not a drain-the-board mandate. If you want the board at
zero, that is [`clean-up`](../agents/alex/sops/clean-up.md).

## Exit Seam

Report in the house two layers, then the in-flight roster:

- **Built** — task URL, slug, builder soul, PR URL, CI state, stage.
- **Archived as already-done** — slug plus the evidence, and any archive the
  holder guard refused.
- **Still designed** — what is left of yours, and why you stopped.
- **Review** — PRs reviewed in the gaps and their verdicts, if you took any.

## Related

- [`process-backlog.md`](process-backlog.md) — the full groom, the whole board,
  four wide, and the mandatory review pivot.
- [`building-sop.md`](building-sop.md) — the flow every builder you spawn runs.
- [`../agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md) — the
  discretionary review.
- [`zap-protocol.md`](zap-protocol.md) — a fix too small to earn a task.
- [`../agents/alex/sops/clean-up.md`](../agents/alex/sops/clean-up.md) — board to
  zero, ship-authority gated.

# Focus Session — hold an epic, file just-in-time, build wide, review your own PRs

You are the session Alex is working with on an epic: a body of work larger than
one task. This module is the standing procedure for running it. You hold the
plan, you file a task only when it can start now, you spawn a builder per
startable task, and when a builder's PR turns green you spawn its reviewer
yourself. It stands alone: every command is inline.

The design behind it is [`../system/devops-v3-design.md`](../system/devops-v3-design.md)
§3 and §4. You do not need it to run this.

## Status: Active

## Scope

The Build lane and the Review lane, for every task in one epic: `designed →
building → submitted → reviewed`. You own the plan, the builders, and the
reviewers. You stop at `reviewed`: work sits on `accepted` and Alex launches
`qa-release` and `production-deploy` with written authority, as always. You
never promote `accepted → release`, never touch `main`, never deploy.

**Who runs it.** Any session, under its own Pokémon identity. The builders you
spawn are Pokémon too ([`../agents/pokemon/role.md`](../agents/pokemon/role.md)):
one general builder soul, legion. The reviewers you spawn are the specialists:
Carl, Shannon, Jasper, Steffon, or Xan for prose.

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](token-session.md)).

## Step 0 — Orient

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Plan --reason "epic: <epic-slug> orient"
bin/agent-presence                       # what the machine can carry right now
ls /Users/alex/projects/.agents/epics/   # an existing plan to resume?
```

If a plan exists for this epic, read it and continue from its **Next startable**
list. If not, write one (Step 1).

## Step 1 — The epic plan

The plan is a short markdown file you keep current. It lives outside git, on
this machine, so it survives your session and costs nothing to rewrite:

```text
/Users/alex/projects/.agents/epics/<epic-slug>.md
```

Template, all five sections required:

```markdown
# <Epic title>            epic: <epic-slug>   opened: <date>   owner session: <mascot>

## Goal
One paragraph: what is true when this epic is done.

## Pieces
| # | Piece | Depends on | State | Task |
|---|-------|------------|-------|------|
| 1 | <piece> | — | planned · startable · building · submitted · reviewed · dropped | <task slug once filed> |

## Decisions
- <date> — <what changed in the plan and why; an API that behaved differently, a scope cut>

## Next startable
- <piece numbers whose dependencies are all reviewed or in the same batch>

## Open questions for Alex
- <anything that changes the plan and needs his call>
```

Rules for the plan:

- **Pieces are not tasks.** A piece becomes a task only when it is startable
  (Step 2). Five waves of work is five sections of a plan, not five columns of
  cards.
- **Dependencies are the schedule.** Anything with no unmet dependency is
  startable now, whatever wave you first imagined it in. Half of wave two
  usually starts with wave one.
- **Re-plan freely.** When a builder learns the API works differently, rewrite
  the pieces, log the decision, and carry on. A filed task that is now wrong is
  archived with one note: `bin/task note <slug> --comment "archived: plan
  changed — <why>"` then `bin/task move <slug> archived`.

## Step 2 — File a task only when it can start now

A task is startable when every input it needs is on `accepted`, or is being
built in the same batch and can be stubbed. Nothing else earns a card.

```bash
bin/task begin --title "Three To Five Words" --repo <app> --kind <kind> --agent pokemon \
  --shape <shape> --risk <tag> --accept "criterion" --test "[unit] ..." \
  --agent-context "epic: <epic-slug> · piece <n> · <what the builder must know>"
```

- **`--agent pokemon`.** The builder is the Pokémon and the task's mascot is its
  crew member, so the stamp names the Pokémon itself. It keeps every specialist
  eligible to review — `pokemon` is on `Task::SOUL_ROSTER` but not in
  `ReviewerSelector::POOL`, so naming it excludes nobody and frees no seat — and it
  goes away when authors are derived from git (v3 phase 4). **It replaced `--agent
  mack` on 2026-09-24**, when `pokemon` joined the roster; until then the flag was
  silently dropped, leaving the task `builders: NOT STAMPED` and
  `bin/reviewer-select` refusing to pick. If you see `mack` in an older recipe, it
  is that placeholder: it selected identically but put untrue authorship on the
  record, which made genuine Mack rows unreadable. Until the `--epic` flag lands
  with the board's `epic_slug`, the first words of `--agent-context` carry the epic.
- **Title 3 to 5 words; acceptance bullets 5 to 12 words.** Everything longer
  goes in `--agent-context`, including the piece number and the plan path.
- Record the task slug in the plan's Pieces table the moment `begin` returns.
- **The designed column is measured in minutes.** If you filed ahead of a free
  slot, that card's age is the cost of it; do not file the next one.

## Step 3 — Build wide

Read the machine before every launch, and again before every backfill:

```bash
bin/agent-presence      # exit 0 clear · 1 busy or unattributed load
```

Launch one builder per startable task, as many as the machine can carry:

- Never more than **two** builders certifying or shipping at once; stagger the
  launches so their certs do not land together.
- The session cap is **five** concurrent agents, builders and reviewers
  together. A reviewer plus its light is two.
- Do not pair tasks that fight: same repo and overlapping files, both adding
  a migration, or one whose acceptance waits on the other's merge.
  Serialize those; say which you held and why.

Spawn each builder as a `pokemon` subagent with this brief, filled in:

```text
Build task <slug>: https://mcritchie.studio/tasks/<slug>
Epic plan: /Users/alex/projects/.agents/epics/<epic-slug>.md (read it first; you are piece <n>)
Desk: <the path bin/task begin printed> (already created; do not run bin/task begin again)

Read docs/agents/agents/pokemon/role.md, then docs/agents/modules/building-sop.md, and follow it.
Write the test tiers your shape requires. Commit in the desk early and often.
Hand off from the desk, in the background, with the hub's script: /Users/alex/projects/mcritchie-studio/bin/ship-wait <slug> --launch -m "<message>" (about 12 minutes; a satellite desk carries no copy of it).
STOP at submitted. Do not merge, deploy, or touch release/main.
Narrate with bin/agent-activity. Report back: the PR URL, the pre-flight result, the CI state, anything undone.
```

**Their reports are testimony.** Before you count a task as submitted, check:

```bash
bin/task show <slug> -v                       # stage must read submitted; note pr_url and the head
gh pr view <pr> --json headRefOid,state,mergeable,statusCheckRollup
```

## Step 4 — Review your own PRs

When a builder reports `submitted` and the PR is green, you spawn the reviewer.
Nobody waits for a `pr-review` launch. First record the head:

```bash
gh pr view <pr> --json headRefOid --jq .headRefOid     # the recorded head; the reviewer merges only this
```

Pick the tier from what the diff actually changed, plus the task's risk tags:

| Tier | The change | Spawn |
|---|---|---|
| A | only prose: markdown, inert media, docs-guard tests | one `xan` (the documentation seat) on [`../agents/carl/sops/pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md) as the PRIMARY: a single read, no light summoned; it claims as `--agent xan` and merges on merge-ready |
| B | code, under 400 insertions, one repo, no risk tag | one `carl` on [`../agents/carl/sops/pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md); a light at his discretion |
| C | any of `payment` `solana` `auth` `migration`, or over 400 insertions, or two repos, or a schema change | `carl` on the primary SOP with the domain light mandatory, strongest model |

`gh pr view <pr> --json additions,files` gives the size and the paths; the risk
tags are on the task.

Spawn the reviewer with this brief, filled in:

```text
Review PR <url> for task <slug> (https://mcritchie.studio/tasks/<slug>), base accepted.
Run docs/agents/agents/carl/sops/pr-review-primary.md end to end, as the soul named here.
Claim by slug, naming that soul:
  bin/task review-claim acquire <slug> --agent <xan for tier A | carl for tiers B and C>
Recorded head: <sha>. Tier <A|B|C>: <A: single read, summon no light | B: light at your discretion | C: light mandatory>.
The builder is the task's Pokémon, so no specialist is an author.
Acceptance is in the task AND in the epic plan at /Users/alex/projects/.agents/epics/<epic-slug>.md, piece <n>; read both.
On merge-ready, merge in the SOP's exact sequence and move the task reviewed. On request-changes, block with
the three-part shape (regression, trigger, what right looks like). Release the claim. Report the verdict and the merge SHA.
```

Count the reviewer against the cap. While a builder waits on CI you have room
for a review; that is the window to use.

## Step 5 — When a block comes back

A block lands on the task as `qa_feedback` and the task returns to `building`.
Read it with the builder's context still warm:

```bash
bin/task show <slug> --json | jq '.unresolved_feedback | {summary: .metadata.summary, details: .description}'
```

Decide, in one sentence, which of two things it is:

- **The block is right.** Resume the builder in the same desk with the block as
  its brief (the `pokemon` subagent, pointed at
  [`address-blocker.md`](address-blocker.md)). It fixes the one named gap,
  posts `bin/task note <slug> --handoff "…" --resolves-feedback`, and ships
  again. Then Step 4 again, same reviewer if it is still live.
- **The block is wrong, and you can show it.** Contest it. Post the builder's
  position with its evidence, then spawn Avi on
  [`../agents/avi/sops/arbitrate-block.md`](../agents/avi/sops/arbitrate-block.md):

  ```bash
  bin/task note <slug> --clarification "CONTEST: <the reviewer's claim> — <the evidence it is wrong: the test, the measurement, the prior art>" --agent <mascot>
  ```

  Paste the contest text into Avi's brief as well: the task's show JSON carries
  only the latest note, so the brief is what guarantees he reads the evidence.
  Avi accepts, overrules, or splits the block and records the ruling. Only a
  policy question he cannot settle goes to Alex, with a 20-minute window.

Contesting is a power, not a reflex. A block that names a reachable regression
with a trigger you can reproduce is right; fix it.

## Step 6 — Backfill, re-plan, or stop

As each task reaches `reviewed`, update the plan, recompute **Next startable**,
read the machine, and launch the next builder. When a builder's finding changes
the plan, rewrite the pieces and log the decision before filing anything new.
Stopping is fine: the plan is the state, and a fresh session resumes from it.

## Exit seam

Every task you filed is `reviewed` or honestly reported as unfinished; the plan
is current; the review claims you took are released. Report in the house two
layers, then the roster:

- **Reviewed and on `accepted`** — task URL, slug, PR URL, merge SHA.
- **Still building or blocked** — slug, what it waits on, whether a contest is
  with Avi.
- **Plan** — pieces done, next startable, decisions made this sitting, open
  questions for Alex.
- **Ready for the ladder** — say plainly that `accepted` carries reviewed work
  and that `qa-release` is his to launch.

## Related

- [`../agents/pokemon/role.md`](../agents/pokemon/role.md) — the builder you spawn.
- [`building-sop.md`](building-sop.md) — the per-task flow each builder runs.
- [`../agents/carl/sops/pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md) — the review each reviewer runs.
- [`../agents/avi/sops/arbitrate-block.md`](../agents/avi/sops/arbitrate-block.md) — a contested block.
- [`address-blocker.md`](address-blocker.md) — clearing a block that stands.
- [`process-backlog.md`](process-backlog.md) — the sibling for a board that is not one epic.

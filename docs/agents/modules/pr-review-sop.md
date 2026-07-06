# PR Review SOP (modular) — the `review-one` primitive

This is the **reusable, self-contained PR-review procedure** — the review half of
the Deploy workflow (`submitted → reviewed`), factored out so any conductor or QA
session can invoke it the same way "all over the place." The release SOP
([`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
§1.4), the [heartbeats launcher map](heartbeats.md), and Avi's
[`pr-review`](../agents/avi/sops/pr-review.md) /
[`pr-review-slow`](../agents/avi/sops/pr-review-slow.md) SOPs all include this
module **by reference** rather than restating it — edit the review contract here
and it flows everywhere.

> **This module IS the `review-one <task>` atom** — the indivisible PRIMITIVE the
> composable deploy launchers are built from (§1.4). One run = **one PR / one
> task**: Avi (the SUPERVISOR) picks + spawns the pair **in parallel** → PRIMARY +
> LIGHT review as **siblings** → on all-clear the **supervisor** gates the task to
> **`reviewed` and STOPS** (review-only, 2026-07-03 — the merge
> is no longer the reviewer's; Steffon's self-healing `qa-release` sweeps the
> reviewed queue, merges the PRs into `release`, and flips members `assembled` on
> QA-green), or **any** reviewer blocks. The plural atoms just LOOP this body over
> the `submitted` queue: **`pr-review`** runs it fanned across all submitted PRs
> in **waves of ≤5**; **`pr-review-slow`** runs it serialized, one PR at a time.
> So the sections below are the body of `review-one`; the loop that turns it into
> `pr-review` is the concurrency wrapper in §1.4 — nothing here changes between
> the two.

It follows the established **2-senior review** model, but **formalizes the agent
roles** in a **3-level hierarchy**: the session Pokémon (identity) → **Avi, the
SUPERVISOR** (a thin gate + orchestration that **never reviews code**) → the
**domain experts** who actually review. Avi selects a **primary** and one **light**
reviewer and spawns **both in parallel** as siblings; each reviewer reviews **as
their own soul**, and each review shows up in the Agent column of the Alex
heartbeat (`/alex/heartbeat`) attributed to that soul. Nothing here overrides the
canonical stage ownership in `devops-cycle-design.md` §1.2 — it is the operational
how-to for that stage.

## When to invoke

Run this whenever a `submitted` task's PR needs review before it can advance —
as the `review-one` atom inside a `full-cycle` / `deploy-with-task`
composition, as the body of an Avi Heartbeat `pr-review` / `pr-review-slow`
sweep (review-only — the merge belongs to Steffon's `qa-release` sweep), or a one-off
review a conductor kicks off by hand. The unit of work is
**one PR / one task**; a queue is just this cascade run per task (`pr-review`), in
**waves of ≤5 concurrent agents** (the board DB's connection budget — see
"Concurrency cap" in the operating model).

You are the **CONDUCTOR** here, not a feature agent — you orchestrate review on
work that is **already built**. Do not create a task, take a worktree, or write
feature code.

## The reviewer pool

The senior reviewer pool is **one soul per domain**; Avi picks from it by the
PR's change surface:

| Change surface | Reviewer soul | `subagent_type` |
|---|---|---|
| Backend — Rails, models, jobs, services | **Carl** | `carl` |
| UI — ERB, Tailwind, Alpine, theme | **Shannon** | `shannon` |
| On-chain / Solana — turf-vault, `Solana::*`, wallets | **Jasper** | `jasper` |
| Infra / deploy — Heroku, CI, env, buildpacks | **Steffon** | `steffon` |
| Docs / operating-model — agent docs, runbooks, README | **Alex** | `alex` |

Alex is the orchestrator **and** the pool's launchable Documentation review seat —
one identity. Each review names exactly **one PRIMARY** (deep review, owns the
lane) and **one or more LIGHT** reviewers (a focused second perspective).

## Step 1 — Avi assigns the reviewers

The conductor **spawns Avi** (Agent tool, `subagent_type: avi`) as the **review
SUPERVISOR** — a thin gate + orchestration that **never reviews the code
itself**. Avi:

1. Confirms **product-acceptance** — does the open PR (base `release`) meet the
   task's acceptance criteria?
2. Determines the **primary + light** pair by change surface (the table above),
   running **`bin/reviewer-select <task>`**. It scores the pool by domain fit with
   a logged, seeded-per-task tiebreak and **excludes** the QA owner (Steffon, who
   QAs the assembled RC — no self-gating), **the builder** (a soul never reviews
   its own work — read from `devops.built_by`, auto-stamped on the build move),
   and any **busy souls** (`--busy a,b,c` and/or `--busy-auto`). The pool is never
   starved below a pair.

**Record the intent.** `bin/reviewer-select <task>` **records the picked pair by
default** — it writes them onto the task as the live **review intent** (the
"record intent on PR review" convention), so `/deployments` and the task timeline
show the two seniors reviewing live — a green ticking timer — the moment review
kicks off, before `→ reviewed` lands. Pass `--no-record` / `--dry` only for an
advisory-only preview. (The manual fallback is
`bin/task intent <task> --to reviewed --actor <primary>`.)

Avi then **spawns both the primary and the light reviewer in parallel** (Step 2)
— they are his own sibling children, not a hand-off to be re-delegated.

## Step 2 — Reviewers review AS their soul

The supervisor spawns **both** reviewers (Agent tool, each its domain
`subagent_type`) **in parallel as siblings** — the PRIMARY runs the deep review
([`../agents/avi/sops/pr-review-primary.md`](../agents/avi/sops/pr-review-primary.md)),
the LIGHT runs the focused second read
([`../agents/avi/sops/pr-review-light.md`](../agents/avi/sops/pr-review-light.md)).
The primary does **not** spawn its sibling; the supervisor oversees both
concurrently and collects both verdicts. Avi performs **no** review of his own.

**Each reviewer narrates their review as their own soul** so the Agent column
attributes it to them, not to the base session mascot:

```bash
bin/agent-activity start --category Verify --agent <soul> --task <task-slug> --reason "review: <task-slug>"
# … diff, checks, tests, DoR …
bin/agent-activity end --outcome "<verdict>: <one-line reason>"
```

> The **`--agent <soul>`** and **`--task <slug>`** flags are live (task
> `agent-attribution-on-events`). A reviewer that omits `--agent` falls back to
> the session's **base mascot** — the review still narrates, it just attributes
> to the mascot instead of the soul. `bin/pr-review` interpolates both flags
> into each reviewer prompt automatically.

Each reviewer goes through the review cycle and **responds with concise notes**:

- **diff vs. acceptance** — the change does what the task's acceptance criteria say.
- **checks / tests** — the shape's DoR **base** tiers are green in `checks_run`;
  `bin/dor-check` passes.
- **code standards + code smell + scalability** — the PRIMARY goes deep here
  (Opus on `migration` / `payment` / `solana` / `auth`); the LIGHT gives a focused
  second read.
- **docs** — behavior/env/ports/auth/deploy changes carry doc updates.

Reviewers may also broadcast in-app progress with
`POST /api/v1/tasks/:slug/review_events` (heavy = `primary` swimlane, light =
light swimlane) — see [`parallel-agent-devops.md`](parallel-agent-devops.md#picking-the-two-senior-reviewers-binreviewer-select).

## Step 3 — Any reviewer can BLOCK

If a reviewer finds something wrong, **any** reviewer marks the task blocked —
one complete send-back, then the conductor moves on (block-and-move: one block
never holds back the PRs that passed):

```bash
bin/task block <task> --kind rework --feedback "<what is wrong + why>"
```

That returns the task to the builder as a fresh feature-agent cycle (block notes
land in the task activities as `qa_feedback`). Surface each blocking event in the
run handoff as a **❌ Block Resolved — <slug>: <reason>** line ("resolved" =
recorded and routed back, not fixed); omit that section entirely on a clean run.

## Step 4 — Verdict

The **supervisor collects both verdicts and gates**; the PRIMARY's deep verdict
carries the most weight, the LIGHT adds a focused second perspective.

- **All-clear** (no reviewer blocked) → the **supervisor** drives the task to
  `reviewed` (`bin/task move <task> reviewed --actor avi`) — **and stops there.**
  Review is **review-only** (2026-07-03): the supervisor does NOT run
  `bin/release merge`;
  Steffon's self-healing **`qa-release`** (`bin/release prepare`) sweeps the whole
  reviewed queue, merges each PR into `release` (stamping `merged: "release"`),
  and flips members to `assembled` only on QA-green. **Bias to action: green
  tests = go** — the sweep follows promptly, and `release` is recoverable by
  revert. The **sweep → QA → ship** pipeline continues from there
  (`devops-cycle-design.md` §1.4).
- **Any block** → the task is at `blocked` (Step 3), out of the pipeline until the
  builder resubmits.
- **Low confidence** (humility valve) → a reviewer marks `conductor-review` and
  routes to a human Avi/Steffon session instead of approving the merge.

## At a glance

One `review-one <task>` run, start to finish (the loop that fans this across the
`submitted` queue = `pr-review`, §1.4):

| # | Actor | Agent (`subagent_type`) | Does | Records |
|---|---|---|---|---|
| 1 | **Avi** (SUPERVISOR — never reviews) | `avi` | product-acceptance + `bin/reviewer-select`; **spawns both reviewers in parallel** | review intent (pair) on the task |
| 2 | **PRIMARY** | domain soul | deep review (runs `pr-review-primary.md`) | `Verify --agent <soul>` activity + notes |
| 2 | **LIGHT** | domain soul | focused second read (runs `pr-review-light.md`); **sibling** of the primary | `Verify --agent <soul>` activity + notes |
| 3 | any reviewer | — | block on a defect | `bin/task block --kind rework --feedback` |
| 4 | **Avi** (SUPERVISOR) | `avi` | collects **both** verdicts → `reviewed` (review-only; Steffon's qa-release sweeps + merges) | `submitted → reviewed` |

## Where this plugs in

- [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
  §1.4 — the canonical stage ownership and the `Review submitted PRs` building
  block; this module is its formalized, agent-role how-to.
- [`../agents/avi/sops/pr-review.md`](../agents/avi/sops/pr-review.md) and
  [`../agents/avi/sops/pr-review-slow.md`](../agents/avi/sops/pr-review-slow.md)
  — the Avi-owned SUPERVISOR SOPs that run this cascade unattended, spawning the
  [`pr-review-primary.md`](../agents/avi/sops/pr-review-primary.md) and
  [`pr-review-light.md`](../agents/avi/sops/pr-review-light.md) role SOPs in
  parallel.
- [`parallel-agent-devops.md`](parallel-agent-devops.md) — the `bin/reviewer-select`
  mechanics, review-events API, and broader queue/scout context.
- [`review-comment-taxonomy.md`](review-comment-taxonomy.md) — which activity type
  (`comment` / `clarification` / `qa_feedback` / `handoff`) a reviewer's note uses.
- [`heartbeats.md`](heartbeats.md) — the launcher map that invokes this review
  cascade as Review round 1.

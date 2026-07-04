# PR Review SOP (modular) — the `review-one` primitive

This is the **reusable, self-contained PR-review procedure** — the review half of
the Deploy workflow (`submitted → reviewed`), factored out so any conductor or QA
session can invoke it the same way "all over the place." The release SOP
([`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
§1.4), the [`qa-release` skill](../skills/qa-release/SKILL.md), and the
[`Avi Heartbeat`](parallel-agent-devops.md) loops all include this module **by
reference** rather than restating it — edit the review contract here and it flows
everywhere.

> **This module IS the `review-one <task>` atom** — the indivisible PRIMITIVE the
> composable deploy launchers are built from (§1.4). One run = **one PR / one
> task**: Avi picks the pair → PRIMARY (+ LIGHT) review → on all-clear the PRIMARY
> drives the task to **`reviewed` and STOPS** (review-only, 2026-07-03 — the merge
> is no longer the reviewer's; Steffon's self-healing `qa-deploy` sweeps the
> reviewed queue, merges the PRs into `release`, and flips members `assembled` on
> QA-green), or **any** reviewer blocks. The plural atoms just LOOP this body over
> the `submitted` queue: **`pr-review`** runs it fanned across all submitted PRs
> in **waves of ≤5**; **`pr-review-slow`** runs it serialized, one PR at a time.
> So the sections below are the body of `review-one`; the loop that turns it into
> `pr-review` is the concurrency wrapper in §1.4 — nothing here changes between
> the two.

It follows the established **2-senior review** model, but **formalizes the agent
roles**: Avi assigns a **primary** and one or more **light** reviewers, each
reviewer reviews **as their own soul**, and each review shows up in the Agent
column of the Alex heartbeat (`/alex/heartbeat`) attributed to that soul. Nothing
here overrides the canonical stage ownership in `devops-cycle-design.md` §1.2 — it
is the operational how-to for that stage.

## When to invoke

Run this whenever a `submitted` task's PR needs review before it can advance —
as the `review-one` atom inside a `Merge, Assemble, Deploy` / `Build and Deploy
QA Release` / `Deploy with Task <task>` composition, as the body of a `pr-review`
/ `pr-review-slow` sweep, inside an `Avi Heartbeat Slow` / `Avi Heartbeat Fast`
loop, or a one-off review a conductor kicks off by hand. The unit of work is
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

The conductor **spawns Avi** (Agent tool, `subagent_type: avi`) as a **thin
delegation gate** — Avi does not do the deep technical review himself. Avi:

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

Avi then **hands the lane to the PRIMARY**.

## Step 2 — Reviewers review AS their soul

The conductor spawns the **PRIMARY** reviewer (Agent tool, its domain
`subagent_type`), handed all the technical-review goals and ownership of the rest
of the lane. The **PRIMARY spawns the LIGHT** reviewer as its own sub-agent, so
the primary already holds full context when the light's verdict returns (the
nested chain from `devops-cycle-design.md` §1.2).

**Each reviewer narrates their review as their own soul** so the Agent column
attributes it to them, not to the base session mascot:

```bash
bin/atomic-event start --category Verify --agent <soul> --reason "review: <scope>"
# … diff, checks, tests, DoR …
bin/atomic-event end --outcome "<verdict>: <one-line reason>"
```

> The **`--agent <soul>`** flag is being added in parallel by task
> `agent-attribution-on-events`. Until it lands, a reviewer that omits `--agent`
> falls back to the session's **base mascot** — the review still narrates, it just
> attributes to the mascot instead of the soul. Reference `--agent` in reviewer
> prompts now so the roles light up the Agent column the moment the flag ships.

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

The **PRIMARY reviewer's verdict decides**; the light reviewers add perspective.

- **All-clear** (no reviewer blocked) → the PRIMARY drives the task to `reviewed`
  (`bin/task move <task> reviewed`) — **and stops there.** Review is
  **review-only** (2026-07-03): the PRIMARY does NOT run `bin/release merge`;
  Steffon's self-healing **`qa-deploy`** (`bin/release prepare`) sweeps the whole
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
| 1 | **Avi** (thin gate) | `avi` | product-acceptance + `bin/reviewer-select` | review intent (pair) on the task |
| 2 | **PRIMARY** | domain soul | deep review; spawns the LIGHT | `Verify --agent <soul>` span + notes |
| 2 | **LIGHT** | domain soul | focused second read | `Verify --agent <soul>` span + notes |
| 3 | any reviewer | — | block on a defect | `bin/task block --kind rework --feedback` |
| 4 | **PRIMARY** | domain soul | verdict → `reviewed` (review-only; Steffon's qa-deploy sweeps + merges) | `submitted → reviewed` |

## Where this plugs in

- [`../system/devops-cycle-design.md`](../system/devops-cycle-design.md) §1.2 /
  §1.4 — the canonical stage ownership and the `Review submitted PRs` building
  block; this module is its formalized, agent-role how-to.
- [`parallel-agent-devops.md`](parallel-agent-devops.md) — the `bin/reviewer-select`
  mechanics, the review-events API, and the `Avi Heartbeat` loops that run this
  cascade unattended.
- [`review-comment-taxonomy.md`](review-comment-taxonomy.md) — which activity type
  (`comment` / `clarification` / `qa_feedback` / `handoff`) a reviewer's note uses.
- [`qa-release` skill](../skills/qa-release/SKILL.md) — the conductor launcher that
  invokes this review cascade as Review round 1.

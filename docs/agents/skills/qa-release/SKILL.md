---
name: qa-release
description: "Thin router for the composable DevOps heartbeat launchers. The souls BOOKEND the pipeline: Avi reviews + ships, Steffon owns the whole middle. Avi Heartbeat (acts, downstream-first: production-deploy = ship a QA-green release if one is ready, pr-review = review ALL submitted PRs in waves <=5 REVIEW-ONLY, pr-review-slow = serialized review), Steffon Heartbeat (acts, downstream-first: archive-shipped = bin/release archive the prior shipped cycle, qa-release = SELF-HEALING bin/release prepare: sweep reviewed tasks + assembled stragglers, merge PRs onto release, pre-QA gate, deploy QA, flip members assembled on QA-green), Alex Heartbeat (acts: grade-events, share-insights, full-cycle with ship authority). Legacy aliases: archive-completed -> archive-shipped, qa-deploy -> qa-release. Plus Deploy with Task <task>. Atoms: review-one, pr-review / pr-review-slow, qa-release (bin/release prepare), production-deploy (bin/release ship), archive-shipped (bin/release archive), full-cycle. When an agent RUNS a <Soul> Heartbeat its first action is `bin/atomic-event heartbeat <soul>`. Invoke when the operator uses one of these phrases, clicks/copies a heartbeat launcher, or asks to prepare/deploy the release. SOPs live in markdown; this skill only routes to them."
---

# Release Conductor Launcher

You are the **CONDUCTOR** (the Deploy lane), not a feature agent. This skill is a
thin agent-side launcher; the **canonical, model-agnostic runbook** lives in the
docs so it works the same whether the operator drives Claude, Codex, or anything
else:

> **`docs/agents/system/devops-cycle-design.md` §1.4 — "Avi Heartbeat Slow",
> "Avi Heartbeat Fast", "Build and Deploy QA Release", and "Merge, Assemble,
> Deploy"** (with the `Review submitted PRs` / `Prepare release` / `Run
> Deployment` building blocks that follow them).

Read that section and work it top to bottom. It is the source of truth — if this
launcher and the SOP ever disagree, the SOP wins.
For any `<Soul> Heartbeat` launcher, also read that soul's specific procedure:
`docs/agents/agents/avi/HEARTBEAT.md`,
`docs/agents/agents/steffon/HEARTBEAT.md`, or
`docs/agents/agents/alex/HEARTBEAT.md`. The heartbeats page is only the
cross-soul map.

**The launchers are compositions of atoms.** Learn the atoms once; every launcher
is a sequence of them (full detail in §1.4):

- **`review-one <task>`** — the PRIMITIVE: the [PR Review SOP](../../modules/pr-review-sop.md)
  on ONE PR (Avi picks the pair → PRIMARY + LIGHT review → all-clear = PRIMARY
  drives `reviewed` and STOPS — **review-only**, Steffon's sweep merges; else block).
- **`pr-review`** — `review-one` fanned across ALL `submitted` PRs, **waves of ≤5**
  (review-only). **`pr-review-slow`** — the same, serialized.
- **`qa-release`** — `bin/release prepare --yes`, the **self-healing sweep**: detect
  `reviewed` tasks + `assembled` stragglers → merge their PRs onto `release`
  (skipping `merged:` ones — crash recovery) → pre-QA gate → deploy QA → flip
  members `assembled` on **QA-green** (a failure leaves them `reviewed` for the
  next run). Legacy alias: `qa-deploy`. **`production-deploy`** — `bin/release ship` (ff `release → main`
  stamping `merged: "main"`, deploy prod; ship-authority gated).

> ⚠️ **Branch at the production decision.**
> - `Avi Heartbeat Slow`: run `bin/avi-heartbeat --run --codex-workdir
>   /Users/alex/projects/mcritchie-studio` from
>   `/Users/alex/projects/mcritchie-studio` — the review-only loop (`pr-review-slow`
>   WITHOUT the merge/deploy tail): it serializes submitted PR review, moves
>   approved tasks to `reviewed`, prints a retrospective after its cap, and does
>   not merge, deploy, ship, publish gems, or archive. `--codex-workdir` must be
>   a trusted git checkout (the default projects root is not — `codex exec`
>   refuses and every reviewer exits 1); add `--max-idle-cycles 1` to exit when
>   the queue drains. Full flags: the quick-start in
>   [`heartbeats.md`](../../modules/heartbeats.md).
> - `Avi Heartbeat Fast`: run `bin/avi-heartbeat --run --fast` with the same
>   `--codex-workdir` from `/Users/alex/projects/mcritchie-studio` — the
>   review-only loop for stacked queues (bounded PRIMARY + LIGHT waves under the
>   five-agent cap); same reviewed/block/defer rules, and does not merge, deploy,
>   ship, publish gems, or archive.
> - `Build and Deploy QA Release` = **`pr-review` → `qa-release`**: review submitted
>   PRs, assemble the release, deploy QA, then hand the operator `bin/release ship
>   --by conductor` (**stops before `production-deploy`**).
> - `Merge, Assemble, Deploy` = **`pr-review` → `qa-release` → `production-deploy`**:
>   the same review/assembly/QA path, then `bin/conductor ship --run` from a
>   primary checkout after the gates pass. Slow variant swaps in `pr-review-slow`.
> - `Deploy with Task <task>` = **GUARD `release == main` → `review-one <task>` →
>   `qa-release` → `production-deploy`**: expedite ONE task to prod. Run
>   **`bin/release status --clean-only` FIRST**; on a **dirty** release (other
>   assembled work pending) it exits non-zero — **REFUSE and offer `Merge,
>   Assemble, Deploy`** (ship the whole release) instead. Never expedite one task
>   past pending work.

**Soul heartbeat launchers** — the three DevOps-card chips (cross-soul SOP
[`heartbeats.md`](../../modules/heartbeats.md); per-soul SOPs:
[`Avi`](../../agents/avi/HEARTBEAT.md),
[`Steffon`](../../agents/steffon/HEARTBEAT.md),
[`Alex`](../../agents/alex/HEARTBEAT.md)). Each is a soul face (linking to
`/agents/<slug>`) over a prompt-like row 1 + copyable atom act(s); **any row is a
recognized launcher** (the `<Soul> Heartbeat` prompt OR any of its atoms). Enter as
the named soul. Operator-launched (copy-paste) today, schedule-ready tomorrow — each
act is idempotent with an explicit precondition + a named exit seam. **Steffon owns
release stages 1–3, Avi owns 4–5, and "deployed to QA" is the Steffon → Avi
handoff:**
- **`Avi Heartbeat`** — Avi. Act **`pr-review`**: review ALL submitted PRs (waves
  ≤5) → each `reviewed` or `blocked` — **review-only**; Steffon's sweep merges.
  Act **`production-deploy`** (ship authority): **IF** a QA-green release is
  ready → `bin/release ship --yes` (stages 4–5, `merged: "main"` at each ff) →
  prod → `shipped`; else no-op.
- **`Steffon Heartbeat`** — Steffon. Act **`qa-release`**: `bin/release prepare
  --yes` (stages 1–3, SELF-HEALING) — sweep the reviewed queue + stragglers,
  merge PRs onto `release`, pre-QA gate, deploy QA, members `assembled` on
  QA-green — hands off at "deployed to QA" (does NOT ship). Act
  **`archive-shipped`**: `bin/release archive --yes` → shipped tasks +
  completed releases + merged worktrees archived (idempotent). Legacy aliases:
  `qa-deploy` and `archive-completed`.
- **`Alex Heartbeat`** — Alex. Act **`grade-events`**: grade the 10 most recent
  resolved spans at `/alex/heartbeat`, bank the useful insights. Act
  **`share-insights`**: take the `mcr`-confirmed insights, regenerate the lessons
  doc (`bin/rails insights:doc`) and distribute it, so every next agent starts
  with the confirmed lessons; none confirmed → no-op. (Learning loop — outside
  the release pipeline.)

Load-bearing reminders (full detail in §1.4):
- Run every command from `/Users/alex/projects/mcritchie-studio`; the board is
  **prod** by default — never add `--local`.
- An agent shell has no TTY: pass **`--yes`** on merge/prepare commands that this
  SOP owns. Use `ship --yes` only for `Merge, Assemble, Deploy`, explicit
  production approval in-session, or an already-approved rollout prompt. Use
  `archive --yes` only when archive work is assigned. `--yes` drops the human
  confirm only, never a test gate.
- **Review round 1 in parallel** — the **nested cascade** (full how-to: the
  reusable [PR Review SOP module](../../modules/pr-review-sop.md)): fan out **Avi**
  as the thin gate (product-acceptance + `reviewer-select` to pick the primary/light
  pair), then spawn the **PRIMARY** reviewer per PR, which **spawns the LIGHT** as
  its own sub-agent — each narrating its review **as its soul** (`--agent`). **Cap the fan-out at 5 concurrent agents** (the board DB's
  connection budget — see "Concurrency cap" in the operating model); review larger
  queues in **waves of ≤5**. On two approvals with no blocker the **PRIMARY**
  drives its task to `reviewed` and STOPS — review-only; Steffon's `qa-release`
  sweep owns the merge. **Block-and-move** (one block never halts the batch), a
  **second review round** for stragglers that arrive during `prepare` (a
  `prepare` re-run sweeps them in), then branch: stop at the ship gate for the QA
  workflow, or ship for the autonomous workflow.
- Surface any blocking event as **❌ Block Resolved — <slug>: <reason>** in the
  handoff; omit that section entirely on a clean run.
- Ship from a **primary checkout**, not a worktree (gems resolve as siblings at the
  projects root).

---
name: qa-release
description: "Avi Heartbeat Slow, Avi Heartbeat Fast, Build and Deploy QA Release, Merge, Assemble, Deploy, or Deploy with Task <task> — the composable DevOps launchers for review intake, release assembly, QA deploy, and optionally production ship. They are compositions of atoms: review-one (one-PR review + merge), pr-review / pr-review-slow (that fanned across all submitted PRs, waves <=5 / serialized), qa-deploy (bin/release prepare), production-deploy (bin/release ship). Avi Heartbeat is review-only and stops at reviewed; Build and Deploy QA Release stops at the production ship gate; Merge, Assemble, Deploy authorizes autonomous production ship after gates pass; Deploy with Task expedites ONE task to prod, guarded on a clean release (release == main). Also recognizes the three soul heartbeat chips on the DevOps card (#release-duration-card on /deployments) — any row of each: Avi Heartbeat (acts pr-review = review+merge submitted PRs, production-deploy = ship a QA-green release), Steffon Heartbeat (acts qa-deploy = prepare QA, archive-completed = bin/release archive), and Alex Heartbeat (act grade-events, the learning loop; full SOP in heartbeats.md). Invoke when the operator uses one of these phrases, clicks a release kickoff or heartbeat chip, or asks to prepare/deploy the release. Thin launcher — the full, model-agnostic SOP lives in devops-cycle-design.md §1.4."
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

**The launchers are compositions of atoms.** Learn the atoms once; every launcher
is a sequence of them (full detail in §1.4):

- **`review-one <task>`** — the PRIMITIVE: the [PR Review SOP](../../modules/pr-review-sop.md)
  on ONE PR (Avi picks the pair → PRIMARY + LIGHT review → all-clear = PRIMARY
  drives `reviewed` **and** runs `bin/release merge` → `assembled`; else block).
- **`pr-review`** — `review-one` fanned across ALL `submitted` PRs, **waves of ≤5**
  (review **+ merge**). **`pr-review-slow`** — the same, serialized.
- **`qa-deploy`** — `bin/release prepare --yes` (assemble + deploy `origin/release`
  to QA). **`production-deploy`** — `bin/release ship` (ff `release → main`, deploy
  prod; ship-authority gated).

> ⚠️ **Branch at the production decision.**
> - `Avi Heartbeat Slow`: run `bin/avi-heartbeat --run` from
>   `/Users/alex/projects/mcritchie-studio` — the review-only loop (`pr-review-slow`
>   WITHOUT the merge/deploy tail): it serializes submitted PR review, moves
>   approved tasks to `reviewed`, prints a retrospective after its cap, and does
>   not merge, deploy, ship, publish gems, or archive.
> - `Avi Heartbeat Fast`: run `bin/avi-heartbeat --run --fast` from
>   `/Users/alex/projects/mcritchie-studio` — the review-only loop for stacked
>   queues (bounded PRIMARY + LIGHT waves under the five-agent cap); same
>   reviewed/block/defer rules, and does not merge, deploy, ship, publish gems,
>   or archive.
> - `Build and Deploy QA Release` = **`pr-review` → `qa-deploy`**: review submitted
>   PRs, assemble the release, deploy QA, then hand the operator `bin/release ship
>   --by conductor` (**stops before `production-deploy`**).
> - `Merge, Assemble, Deploy` = **`pr-review` → `qa-deploy` → `production-deploy`**:
>   the same review/assembly/QA path, then `bin/conductor ship --run` from a
>   primary checkout after the gates pass. Slow variant swaps in `pr-review-slow`.
> - `Deploy with Task <task>` = **GUARD `release == main` → `review-one <task>` →
>   `qa-deploy` → `production-deploy`**: expedite ONE task to prod. Run
>   **`bin/release status --clean-only` FIRST**; on a **dirty** release (other
>   assembled work pending) it exits non-zero — **REFUSE and offer `Merge,
>   Assemble, Deploy`** (ship the whole release) instead. Never expedite one task
>   past pending work.

**Soul heartbeat launchers** — the three DevOps-card chips (full SOP
[`heartbeats.md`](../../modules/heartbeats.md)). Each is a soul face (linking to
`/agents/<slug>`) over a prompt-like row 1 + copyable atom act(s); **any row is a
recognized launcher** (the `<Soul> Heartbeat` prompt OR any of its atoms). Enter as
the named soul. Operator-launched (copy-paste) today, schedule-ready tomorrow — each
act is idempotent with an explicit precondition + a named exit seam. **Steffon owns
release stages 1–3, Avi owns 4–5, and "deployed to QA" is the Steffon → Avi
handoff:**
- **`Avi Heartbeat`** — Avi. Act **`pr-review`**: review + **merge** ALL submitted
  PRs (waves ≤5) → each `assembled` or `blocked` (MERGES — unlike the review-only
  `Avi Heartbeat Slow`/`Fast`). Act **`production-deploy`** (ship authority):
  **IF** a QA-green release is ready → `bin/release ship --yes` (stages 4–5) → prod
  → `shipped`; else no-op.
- **`Steffon Heartbeat`** — Steffon. Act **`qa-deploy`**: `bin/release prepare
  --yes` (stages 1–3) → QA → `assembled` on QA, hands off at "deployed to QA" (does
  NOT ship). Act **`archive-completed`**: `bin/release archive --yes` → shipped
  tasks + completed releases + merged worktrees archived (idempotent).
- **`Alex Heartbeat`** — Alex. Act **`grade-events`**: grade the 10 most recent
  resolved spans at `/alex/heartbeat`, bank the useful insights. (Learning loop —
  outside the release pipeline.)

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
  drives its task to `reviewed` AND runs `bin/release merge` (it owns the merge —
  not the conductor). **Block-and-move** (one block never halts the batch), a
  **second review round** for stragglers that arrive during `prepare`, then
  assemble and branch: stop at the ship gate for the QA workflow, or ship for the
  autonomous workflow.
- Surface any blocking event as **❌ Block Resolved — <slug>: <reason>** in the
  handoff; omit that section entirely on a clean run.
- Ship from a **primary checkout**, not a worktree (gems resolve as siblings at the
  projects root).

---
name: qa-release
description: "Build and Deploy QA Release or Merge, Assemble, Deploy — release-conductor launchers for review, release assembly, QA deploy, and optionally production ship. Build and Deploy QA Release stops at the production ship gate; Merge, Assemble, Deploy explicitly authorizes autonomous production ship after gates pass. Invoke when the operator uses either phrase, clicks either release kickoff chip, or asks to prepare/deploy the release. Thin launcher — the full, model-agnostic SOP lives in devops-cycle-design.md §1.4."
---

# Release Conductor Launcher

You are the **CONDUCTOR** (the Deploy lane), not a feature agent. This skill is a
thin Claude-side launcher; the **canonical, model-agnostic runbook** lives in the
docs so it works the same whether the operator drives Claude, Codex, or anything
else:

> **`docs/agents/system/devops-cycle-design.md` §1.4 — "Build and Deploy QA
> Release" and "Merge, Assemble, Deploy"** (with the `Review submitted PRs` /
> `Prepare release` / `Run Deployment` building blocks that follow them).

Read that section and work it top to bottom. It is the source of truth — if this
launcher and the SOP ever disagree, the SOP wins.

> ⚠️ **Branch at the production decision.**
> - `Build and Deploy QA Release`: review submitted PRs, assemble the release,
>   deploy QA, then hand the operator `bin/release ship --by conductor`.
> - `Merge, Assemble, Deploy`: run the same review/assembly/QA path, then run
>   `bin/conductor ship --run` from a primary checkout after the gates pass.

Load-bearing reminders (full detail in §1.4):
- Run every command from `/Users/alex/projects/mcritchie-studio`; the board is
  **prod** by default — never add `--local`.
- An agent shell has no TTY: pass **`--yes`** on merge/prepare commands that this
  SOP owns. Use `ship --yes` only for `Merge, Assemble, Deploy`, explicit
  production approval in-session, or an already-approved rollout prompt. Use
  `archive --yes` only when archive work is assigned. `--yes` drops the human
  confirm only, never a test gate.
- **Review round 1 in parallel** — the **nested cascade**: fan out **Avi** as the
  thin gate (product-acceptance + `reviewer-select` to pick the primary/light
  pair), then spawn the **PRIMARY** reviewer per PR, which **spawns the LIGHT** as
  its own sub-agent. **Cap the fan-out at 5 concurrent agents** (the board DB's
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

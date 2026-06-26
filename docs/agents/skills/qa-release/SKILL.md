---
name: qa-release
description: "Build and Deploy QA Release — the operator's one-trigger QA-department run, end to end, AUTO-SHIPPING to prod with no human gate (the two-senior review, QA, and the ship-time test suite still gate). Invoke when the operator opens a session with 'Build and Deploy QA Release', clicks the board's release kickoff chip, or asks to run/ship the QA release. Thin launcher — the full, model-agnostic SOP lives in devops-cycle-design.md §1.4."
---

# Build and Deploy QA Release (conductor launcher)

You are the **CONDUCTOR** (the Deploy lane), not a feature agent. This skill is a
thin Claude-side launcher; the **canonical, model-agnostic runbook** lives in the
docs so it works the same whether the operator drives Claude, Codex, or anything
else:

> **`docs/agents/system/devops-cycle-design.md` §1.4 — "Build and Deploy QA
> Release"** (with the `Review submitted PRs` / `Prepare release` / `Run
> Deployment` building blocks that follow it).

Read that section and work it top to bottom. It is the source of truth — if this
launcher and the SOP ever disagree, the SOP wins.

> ⚠️ **This is the auto-ship run — it ends at `bin/release ship --by conductor
> --yes`, a prod deploy with NO human confirm.** The only gates left are automated
> (two-senior review, QA, and `avi_ship_gate`, the ship-time test suite that aborts
> on any failure). For a human-gated run, stop after QA and hand the operator
> `bin/release ship`.

Load-bearing reminders (full detail in §1.4):
- Run every command from `/Users/alex/projects/mcritchie-studio`; the board is
  **prod** by default — never add `--local`.
- An agent shell has no TTY: pass **`--yes`** on every writing command
  (`prepare`/`ship`/`archive`). `--yes` drops the human confirm only, never a test
  gate.
- **Review round 1 in parallel** (fan out Avi + the `reviewer-select` heavy/light
  pair across the submitted PRs), but **cap the fan-out at 5 concurrent agents**
  (the board DB's connection budget — see "Concurrency cap" in the operating
  model); a queue larger than 5 reviews in **waves of ≤5**. **Block-and-move** (one
  block never halts the batch), a **second review round** for stragglers that
  arrive during `prepare`, then assemble and ship.
- Surface any blocking event as **❌ Block Resolved — <slug>: <reason>** in the
  handoff; omit that section entirely on a clean run.
- Ship from a **primary checkout**, not a worktree (gems resolve as siblings at the
  projects root).

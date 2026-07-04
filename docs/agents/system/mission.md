# Mission

McRitchie Studio is the central task management and orchestration hub for the McRitchie AI agent system. It provides:

1. **Task Pipeline** — Create, assign, track, and transition tasks through stages (designed → building → submitted → reviewed → assembled → shipped, plus blocked/archived)
2. **Agent Registry** — Monitor agent status, skills, activity, and usage
3. **Activity Logging** — Track all agent actions for auditability and debugging
4. **Usage Tracking** — Monitor API costs, token consumption, and task throughput per agent
5. **Error Capture** — Structured error logging with backtrace and context

## Core Principle

Agents are autonomous but accountable. Every action is logged, every task is tracked, every size estimate is sealed-bid against actual cost. Each role has KPIs that are damaged by other roles' bad behavior — that's the negotiation surface that keeps quality, throughput, and coherence in healthy tension.

## Agents

Personas live at `docs/agents/agents/<slug>/{role.md, soul.md}`. The DB registry is seeded from `db/seeds/02_agents.rb` and skills from `db/seeds/03_skills.rb`.

### Leadership
- **Alex** — Lead orchestrator (PM). Coordinates agents, manages priorities,
  makes architectural calls, escalates when Mr. McRitchie's judgment is needed.
  Also the **Documentation** domain expert and a senior **reviewer** in the
  Deploy-flow review pool — via a dedicated reviewer persona distinct from the
  orchestrator seat (tracked in `seed-souls-prod-qa`).
- **Avi** — Product Owner. Refines tickets, sets `po_size` (the official planning size), reviews PRs for spec adherence, controls release candidates. In the Deploy flow he is the **thin review delegator** — confirms **product-acceptance** and picks the **primary + light** pair, then hands the lane to the **PRIMARY reviewer** (who owns the deep review, spawns the LIGHT, and drives the task to `reviewed` — review-only; the merge belongs to Steffon's sweep) — and owns the **ship step** (full e2e on the frozen ship SHA, then the `production-deploy` ship of a QA-green release under explicit ship authority).

### Dev specialists
- **Carl** — Backend / Rails. Controllers, models, migrations, jobs, studio-engine internals. Captain of the `backend_migration` exclusive lane. Senior **reviewer** for backend PRs in the Deploy-flow review pool.
- **Shannon** — UI. ERB views, Tailwind, Alpine.js, theme system, studio-engine UI primitives. Senior **reviewer** for UI PRs.
- **Jasper** — Blockchain. turf-vault Anchor program, solana-studio Ruby client, on-chain integration. Senior **reviewer** for Web3 / on-chain PRs.

### Quality + Operations
- **Steffon** — **Platform Engineer** (QA + Infrastructure). Owns the **self-healing `qa-release` sweep** — merge `reviewed` PRs into the persistent `release` (stamping `merged: "release"`), run the **QA test tier** (integration + an e2e smoke), deploy `origin/release` to QA, flip members `assembled` on QA-green — plus Heroku deploys, env vars, CI, observability, and the recovery protocol. Also a senior **reviewer** for DevOps/Platform PRs — but never reviews a PR he will then QA (no self-gating).

### Domain & support
- **Turf Monster** — Sports specialist. Sports data, pick'em games, World Cup props, player analytics.
- **Mack** — General worker. Data scraping, processing, API integrations, bulk operations.
- **Mason** — Marketing. Brand voice, launch comms, social, funnels, copy.

## Agent stack flow

```
Alex (PM)
  ↔  Avi (PO) ── refine + assign ──> Devs (Carl, Shannon, Jasper)
                                          │ open PR (base release)
                                          ▼
        Avi delegates review ──> 2 seniors (1 primary + 1 light)
                                          │ 2 approvals → reviewed (review-only)
                                          ▼
                          Steffon (Platform Engineer)
         qa-release sweep: merge → release · integration + e2e-smoke
                  → QA deploy · flip assembled on QA-green
                                          │
                                          ▼
        Avi: full e2e on frozen ship SHA ──> 🔒 production-deploy / full-cycle
                                          │ explicit ship authority
                                          ▼
                  conductor (Steffon's mechanics): prod deploy + smoke
                                          │
                                          ▼
                                   Mason (announce)
```

Off the critical path: **Turf Monster** (sports domain consults), **Mack** (data ops, parallel).

## Deploy-flow review model (redesigned 2026-06-22; review-only + sweep since 2026-07-03)

The `submitted → shipped` half of the Deploy workflow was re-homed by role
(canonical spec: [`devops-cycle-design.md`](devops-cycle-design.md) §1.2):

- **Avi** opens **review** as delegator — confirms product-acceptance, then picks
  **two seniors** from the pool {Shannon = UI · Carl = backend · Jasper = Web3 ·
  Steffon = DevOps/Platform · Alex = Documentation} by **domain fit + a logged,
  seeded-per-task tiebreak**, assigning **one primary (deep) and one light** review in
  parallel. The seed makes the pick reproducible — `bin/reviewer-select`'s preview
  matches the pair recorded on the `submitted→reviewed` event. **Two approvals
  drive the task to `reviewed` — review-only**; the PRIMARY stops there. The
  merge belongs to the sweep (next bullet).
- **Steffon** (**Platform Engineer**) runs the **self-healing `qa-release` sweep**
  (`bin/release prepare`): merge the `reviewed` PRs into the persistent `release`
  (stamping `merged: "release"` — the crash-recovery skip signal), run the
  **integration + e2e-smoke** tier, deploy `origin/release` to QA, and flip
  members `assembled` only on **QA-green** (bias to action — `release` reverts
  cleanly).
- **Avi** runs the **full e2e + highest tier on the frozen ship SHA**, then ships
  a QA-green release with his **`production-deploy`** act (`bin/release ship`
  fast-forwards `release → main`, stamping members `merged: "main"`). Alex's
  **`full-cycle`** launcher runs the whole cycle — review → QA → prod — under
  full ship authority.

Lands via three build tasks: **`deploy-flow-heartbeat-tooling`** (planner +
tooling, incl. the `prepare` retry/wait-for-boot fix), **`stages-page-step-outlines`**
(per-step `/stages` outlines), and **`seed-souls-prod-qa`** (the reviewer souls,
incl. a dedicated **Alex Documentation** reviewer persona distinct from the
orchestrator seat).

## System protocols

Three binding protocols shape how the team works. Every soul references them; deviations require Alex's approval.

- [`git-protocol.md`](git-protocol.md) — worktrees per agent instance, branch convention, PR ownership table, send-back template, 8 git ethics
- [`sizing-rubric.md`](sizing-rubric.md) — t-shirt scale, sealed-bid sizing across PM/PO/Dev, accuracy as Avi's primary KPI
- [`exclusive-lanes.md`](exclusive-lanes.md) — `backend_migration` lane, pre-flag vs self-flag paths, Carl's captaincy

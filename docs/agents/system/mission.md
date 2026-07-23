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
- **Avi** — Product Owner. Refines tickets, sets `po_size` (the official planning size), controls release candidates. In the Deploy flow he owns the **assembly + QA step** — the self-healing **`qa-release` sweep** (`bin/release prepare`): promote **ONE `accepted → release` batch PR per repo** onto the release candidate, run the pre-QA gate, deploy QA, and flip members `assembled` only on **QA-green** — then hand the QA-green candidate to Steffon. He does not review PRs (Carl owns review) and does not ship production (Steffon owns the ship).

### Dev specialists
- **Carl** — Lead Architect / Backend. Controllers, models, migrations, jobs, studio-engine internals. Captain of the `backend_migration` exclusive lane. **Owner of PR review** — the standing primary on every PR: the review session spins one Carl per PR who runs the deep review, summons a domain light at his discretion, and merges approved work into `accepted` (review-only). There is no Avi supervisor.
- **Shannon** — UI. ERB views, Tailwind, Alpine.js, theme system, studio-engine UI primitives. Senior **reviewer** for UI PRs.
- **Jasper** — Blockchain. turf-vault Anchor program, solana-studio Ruby client, on-chain integration. Senior **reviewer** for Web3 / on-chain PRs.

### Quality + Operations
- **Steffon** — **Platform Engineer** (Ship + Infrastructure). Owns **`production-deploy`** — the frozen-SHA ship gate, then `bin/release ship` (ff `release → main`, deploy prod, smoke, release notes) under explicit ship authority — plus **`archive-shipped`**, Heroku deploys, env vars, CI, observability, and the recovery protocol. Also the domain **light reviewer** for DevOps/Platform PRs (Carl's second read).

### Domain & support
- **Turf Monster** — Sports specialist. Sports data, pick'em games, World Cup props, player analytics.
- **Mack** — General worker. Data scraping, processing, API integrations, bulk operations.
- **Mason** — Marketing. Brand voice, launch comms, social, funnels, copy.

## Agent stack flow

```
Alex (PM)
  ↔  Avi (PO) ── refine + assign ──> Devs (Carl, Shannon, Jasper)
                                          │ open PR (base accepted)
                                          ▼
        Carl reviews (one Carl per PR) ── summons 1 domain light
                                          │ merge-ready → merge to accepted → reviewed
                                          ▼
                          Avi (Product Owner)
         qa-release sweep: accepted → release · integration + e2e-smoke
                  → QA deploy · flip assembled on QA-green
                                          │
                                          ▼
     Steffon: full e2e on frozen ship SHA ──> 🔒 production-deploy / full-cycle
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

- **Carl** owns **review** — the standing primary + owner. The review session
  spins **one Carl per PR** (there is no Avi supervisor); Carl runs the deep
  review, owns the gates, and **summons one domain light** at his discretion from
  the pool {Shannon = UI · Jasper = Web3 · Steffon = DevOps/Platform · Alex =
  Documentation} by **domain fit + a logged, seeded-per-task tiebreak**. The seed
  makes the pick reproducible — `bin/reviewer-select`'s preview matches the pair
  recorded on the `submitted→reviewed` event. On a merge-ready verdict Carl
  **merges the feat PR into `accepted`** and drives the task to `reviewed` —
  review-only; the `accepted → release` promotion belongs to the sweep (next
  bullet).
- **Avi** (Product Owner) runs the **self-healing `qa-release` sweep**
  (`bin/release prepare`): promote the `accepted → release` batch PR
  (stamping `merged: "release"` — the crash-recovery skip signal), run the
  **integration + e2e-smoke** tier, deploy `origin/release` to QA, and flip
  members `assembled` only on **QA-green** (bias to action — `release` reverts
  cleanly).
- **Steffon** (**Platform Engineer**) runs the **full e2e + highest tier on the
  frozen ship SHA**, then ships a QA-green release with his **`production-deploy`**
  act (`bin/release ship` fast-forwards `release → main`, stamping members
  `merged: "main"`). Alex's **`full-cycle`** launcher runs the whole cycle —
  review → QA → prod — under full ship authority.

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

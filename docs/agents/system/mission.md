# Mission

McRitchie Studio is the central task management and orchestration hub for the McRitchie AI agent system. It provides:

1. **Task Pipeline** — Create, assign, track, and transition tasks through stages (new → queued → in_progress → done/failed → archived)
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
- **Avi** — Product Owner. Refines tickets, sets `po_size` (the official planning size), reviews PRs for spec adherence, controls release candidates.

### Dev specialists
- **Carl** — Backend / Rails. Controllers, models, migrations, jobs, studio-engine internals. Captain of the `backend_migration` exclusive lane.
- **Shannon** — UI. ERB views, Tailwind, Alpine.js, theme system, studio-engine UI primitives.
- **Jasper** — Blockchain. turf-vault Anchor program, solana-studio Ruby client, on-chain integration.

### Quality + Operations
- **Steffon** — QA + Infrastructure. Quality gate on every PR; then Heroku deploys, env vars, CI, observability, recovery protocol.

### Domain & support
- **Turf Monster** — Sports specialist. Sports data, pick'em games, World Cup props, player analytics.
- **Mack** — General worker. Data scraping, processing, API integrations, bulk operations.
- **Mason** — Marketing. Brand voice, launch comms, social, funnels, copy.

## Agent stack flow

```
Alex (PM)
  ↔  Avi (PO) ───── refine + assign ────> Devs (Carl, Shannon, Jasper)
                                               │
                                               ▼ open PR
                                          Steffon (QA pass)
                                               │
              ◀───── merge + tag release ──────┘
              │
              ▼
         Steffon (deploy)
              │
              ▼
         Mason (announce)
```

Off the critical path: **Turf Monster** (sports domain consults), **Mack** (data ops, parallel).

## System protocols

Three binding protocols shape how the team works. Every soul references them; deviations require Alex's approval.

- [`git-protocol.md`](git-protocol.md) — worktrees per agent instance, branch convention, PR ownership table, send-back template, 8 git ethics
- [`sizing-rubric.md`](sizing-rubric.md) — t-shirt scale, sealed-bid sizing across PM/PO/Dev, accuracy as Avi's primary KPI
- [`exclusive-lanes.md`](exclusive-lanes.md) — `backend_migration` lane, pre-flag vs self-flag paths, Carl's captaincy

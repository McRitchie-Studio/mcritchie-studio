# Mission

McRitchie Studio is the hub of the McRitchie agent system: the board the DevOps
pipeline runs on, the registry of agent souls, the record of what every agent
did, and the sign-in source for the satellite apps. Alex owns it; the agents run
it. The entry map every session loads is `/Users/alex/projects/AGENTS.md`.

| The hub provides | Where |
|------------------|-------|
| Task pipeline | `designed → building → submitted → reviewed → assembled → shipped`, plus `archived` (`Task::STAGES`); the board at `/tasks` and `/deployments` |
| Agent registry | `/agents`, seeded from `db/seeds/02_agents.rb` and `db/seeds/03_skills.rb`; the roster in `Task::SOUL_ROSTER` |
| Activity record | Every session narrates with `bin/agent-activity`; Xan grades at `/xan/heartbeat`; banked lessons at `/xan/insights` |
| Usage tracking | API cost and tokens per agent at `/usages` |
| Error capture | `/error_logs` from `studio-engine` |
| SSO | Satellites sign in through the hub; `config/satellites.yml` names each one's default role |

## Principle

Agents are autonomous and accountable. Every action is narrated, every task is
tracked on the board, and no soul reviews its own PR: the reviewer is chosen by
excluding the author set the board derives from GitHub.

## Who does what

Souls live at `docs/agents/agents/<slug>/` (`role.md`, `soul.md`, SOPs). Alex is
the human owner.

| Soul | Seat |
|------|------|
| Pokémon | The general builder. Every task gets its own mascot; it builds the whole task to `submitted` |
| Xan | Orchestrator; runs focus sessions; the documentation review light; grades activities |
| Carl | Lead Architect; the standing primary reviewer on every code PR; merges into `accepted` |
| Shannon | UI review light |
| Jasper | On-chain review light |
| Steffon | Infrastructure review light; runs `production-deploy`, credentials and desks |
| Avi | Product owner; runs `qa-release`; arbitrates contested blocks |
| Turf Monster | The Turf Monster app's operator: scores, contests, markets |
| Tyrion | Cyvasse's house player; client-facing, holds no credentials |
| Tywin | The Cyvasse app's operator and admin; internal, holds the keys |
| Rex | Marketing strategy (CMO) |
| Mason | Brand voice and launches |
| Mack | General worker |

The light for a PR is picked by domain fit from `{shannon, jasper, steffon, xan}`
with a per-task seeded tiebreak (`app/services/reviewer_selector.rb`); the QA owner
and every author are excluded from the seat.

## The pipeline

```text
Alex + focus session ──▶ Pokémon builder ──PR green──▶ Carl + one light ──merge──▶ accepted
  (holds the epic plan)   desk · build · ship ◀──blocker──┘
accepted ──Avi: qa-release──▶ release, QA green ──Steffon: production-deploy──▶ main
```

- The builder stops at `submitted`: a non-draft PR into `accepted`, CI green,
  `bin/dor-check` passed. Detail: [`../modules/building-sop.md`](../modules/building-sop.md).
- Review merges onto `accepted` and moves the task to `reviewed`:
  [`../agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md).
- `qa-release` promotes `accepted → release`, deploys QA and flips members
  `assembled` on QA green: [`../agents/avi/sops/qa-release.md`](../agents/avi/sops/qa-release.md).
- `production-deploy` fast-forwards `release → main`, deploys, smokes and marks
  `shipped`, inside Alex's thirty-minute production window:
  [`../agents/steffon/sops/production-deploy.md`](../agents/steffon/sops/production-deploy.md).
- The design behind the stages and gates:
  [`devops-v3-design.md`](devops-v3-design.md) and
  [`devops-cycle-design.md`](devops-cycle-design.md).

## System protocols

Every soul references these; a deviation needs Alex's approval.

- [`git-protocol.md`](git-protocol.md) — desks per task, branch convention, PR ownership, git ethics
- [`sizing-rubric.md`](sizing-rubric.md) — the t-shirt scale and sealed-bid sizing
- [`exclusive-lanes.md`](exclusive-lanes.md) — the `release_conductor` lane; migrations take none

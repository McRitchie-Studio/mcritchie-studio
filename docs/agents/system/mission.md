# Mission

McRitchie Studio is the hub of the McRitchie agent system: the board the DevOps
pipeline runs on, the registry of agent souls, the record of what every agent
did, and the sign-in source for the satellite apps. Alex McRitchie owns it; the agents run
it. The entry map every session loads is `/Users/alex/projects/AGENTS.md`.

| The hub provides | Where |
|------------------|-------|
| Task pipeline | `designed → building → submitted → reviewed → assembled → shipped`, plus `archived` (`Task::STAGES`); the board at `/tasks` and `/deployments` |
| Agent registry | `/agents`, seeded from `config/souls.yml` (by `db/seeds/02_agents.rb`) and `db/seeds/03_skills.rb`; `Task::SOUL_ROSTER` reads the same `config/souls.yml` |
| Activity record | Every session narrates with `bin/agent-activity`; Mason grades at `/mason/heartbeat`; banked lessons at `/mason/insights` |
| Usage tracking | API cost and tokens per agent at `/usages` |
| Error capture | `/error_logs` from `studio-engine` |
| SSO | Satellites sign in through the hub; `config/satellites.yml` names each one's default role |

## Principle

Agents are autonomous and accountable. Every action is narrated, every task is
tracked on the board, and no soul reviews its own PR: the reviewer is chosen by
excluding the author set the board derives from GitHub.

## Who does what

Souls live at `docs/agents/agents/<slug>/` (`role.md`, `soul.md`, SOPs). Alex McRitchie is
the human owner: the Visionary and CEO on the accountability chart
(`config/accountability_chart.yml`), with the orchestrating session as the
Integrator (worn as the Pokémon soul) and three heads under it: Alex
(Sales/Marketing), Mason (Operations, COO) and Mack (Finance/Admin, CFO).

| Soul | Seat |
|------|------|
| Pokémon | The general builder. Every task gets its own mascot; it builds the whole task to `submitted` |
| Mason | COO (Operations): orchestrator; admin with Steffon; the documentation review light; grades activities |
| Carl | Lead Architect; the standing primary reviewer on every code PR; merges into `accepted` |
| Shannon | UI review light |
| Jasper | On-chain review light |
| Steffon | Infrastructure review light; runs `production-deploy`, credentials and desks |
| Avi | Product owner; runs `qa-release`; arbitrates contested blocks |
| Turf Monster | The Turf Monster app's operator: scores, contests, markets |
| Tyrion | Cyvasse's house player; client-facing, holds no credentials |
| Tywin | The Cyvasse app's operator and admin; internal, holds the keys |
| Hank | The Commercial Welding business agent; not yet launched |
| Rex | Marketing strategy (CMO) |
| Alex | Sales/Marketing: clients, focus sessions, the `/build` queue, client launches; brand voice; Worker class |
| Mack | CFO (Finance/Admin): the books and the month close, reports, the financial watchdog |

The light for a PR is picked by domain fit from `{shannon, jasper, steffon, mason}`
with a per-task seeded tiebreak (`app/services/reviewer_selector.rb`); the QA owner
and every author are excluded from the seat.

## The pipeline

```text
Alex McRitchie + focus session ──▶ Pokémon builder ──PR green──▶ Carl + one light ──merge──▶ accepted
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
  `shipped`, inside Alex McRitchie's thirty-minute production window:
  [`../agents/steffon/sops/production-deploy.md`](../agents/steffon/sops/production-deploy.md).
- The design behind the stages and gates:
  [`devops-v3-design.md`](devops-v3-design.md) and
  [`devops-cycle-design.md`](devops-cycle-design.md).

## System protocols

Every soul references these; a deviation needs Alex McRitchie's approval.

- [`git-protocol.md`](git-protocol.md) — desks per task, branch convention, PR ownership, git ethics
- [`sizing-rubric.md`](sizing-rubric.md) — the t-shirt scale and sealed-bid sizing
- [`exclusive-lanes.md`](exclusive-lanes.md) — the `release_conductor` lane; migrations take none

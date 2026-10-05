# User Guide

The pages an operator opens on the hub, and what each one needs. Routes are in
`config/routes.rb`; the ones `studio-engine` draws (sign-in, error logs, local
review, local inbox) come from `Studio.routes`.

## Pages

| Page | Shows | Needs |
|------|-------|-------|
| `/` | The public McRitchie Studio landing page: positioning, Alex's profile, contact | nothing |
| `/dashboard` | Every registered agent, task counts by stage, the twenty latest activities | nothing |
| `/agents`, `/agents/:slug` | The agent grid; one agent's skills, recent tasks and activity | nothing |
| `/agents/:slug/activities` | The cross-session narrated activity feed with grade cells | sign-in |
| `/tasks` | The Build board: `designed`, `building` and `submitted` lanes; a blocked task glows red in `building` | nothing |
| `/deployments` | The full pipeline as six lanes, with drag-and-drop | nothing |
| `/tasks/:slug` | One task: acceptance, conversation, stage events, approval state | nothing |
| `/tasks/new`, `/tasks/:slug/edit` | Create or edit a task | admin |
| `/tasks/:slug/local_review` | The WAITING APPROVAL hop: mints a single-use link into the builder's desk | nothing |
| `/stages`, `/stages/sop` | The two-workflow stage guide and the DevOps SOP by owner | nothing |
| `/epics`, `/epics/:slug` | Epics and their tasks | nothing |
| `/deployments/:slug` | One release candidate and its members | nothing |
| `/usages` | API cost and tokens per agent | nothing |
| `/error_logs`, `/error_logs/:id` | Captured errors; one error with its backtrace | admin |
| `/docs`, `/docs/*path` | The agent docs under `docs/agents`, rendered | nothing |
| `/xan/heartbeat`, `/xan/pipeline`, `/xan/insights` | A session's actions for grading; the activity pipeline; the banked insights | nothing |
| `/activities` | Redirects to `/agents` | nothing |

## Task stages

`Task::STAGES`, in order. The builder walks the Build stages and stops at
`submitted`; DevOps walks the Deploy stages from there.

| Stage | Meaning | Moved by |
|-------|---------|----------|
| `designed` | Specified and startable | creating the task |
| `building` | Claimed; a desk exists | `bin/task begin` |
| `submitted` | PR open into `accepted`, CI green, `bin/dor-check` passed | `bin/ship` |
| `reviewed` | PR merged onto `accepted` | `pr-review` |
| `assembled` | On the release candidate, QA green | `qa-release` |
| `shipped` | On `main`, in production | `production-deploy` |
| `archived` | Terminal, from any stage | `archive-shipped` |

`blocked` is not a stage: it is an attribute of a `building` task (`blocked_at`,
`blocked_from`, `blocked_by`, `block_kind`) that reads as more building to do.

A task with a `local_url` and `approval_status: waiting` floats to the top of its
lane and grows a WAITING APPROVAL button; each click mints a fresh signed-in link
to the page under review. Detail:
[`../modules/building-sop.md`](../modules/building-sop.md).

## Authentication

- Sign in at `/signin` with a magic link or Google; `/login` and `/signup`
  redirect there.
- Magic links are scanner-safe: `GET /l/:token` confirms, `POST /l/:token`
  consumes.
- Sessions carry across the satellites through the hub's SSO; each satellite
  assigns the role named in `config/satellites.yml`.
- Reads are public; task writes and `/error_logs` need an admin.

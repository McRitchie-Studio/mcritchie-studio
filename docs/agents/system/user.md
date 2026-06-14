# User Guide

## Landing Page

The root page (`/`) is the public McRitchie Studio landing page. It shows the software/business positioning, Alex profile, contact blocks, and chat widget.

## Dashboard

The dashboard (`/dashboard`) shows:
- **Agent cards** — Status, type, and description for all registered agents
- **Task pipeline** — Count of tasks in each stage
- **Recent activity** — Chronological feed of agent actions

## Agents

- `/agents` — Grid view of all agents
- `/agents/:slug` — Agent detail with skills, recent tasks, and activity

## Tasks

- `/tasks` — Filterable list with stage tabs
- `/tasks/new` — Create a new task (requires login)
- `/tasks/:slug` — Task detail with stage transition buttons
- `/tasks/:slug/edit` — Edit task details (requires login)

### Task Stages
1. **New** — Just created, not yet assigned to queue
2. **Queued** — Ready for an agent to pick up
3. **In Progress** — An agent is actively working on it
4. **Done** — Completed successfully
5. **Failed** — Encountered an error (see error message)
6. **Archived** — Removed from active pipeline

## Activity

- `/activities` — Reverse-chronological feed of all agent activity
- Filter by agent or activity type via URL params

## Errors

- `/error_logs` — Recent errors with message, target, and timestamp
- `/error_logs/:id` — Error detail with full backtrace

## Authentication

- Sign in at `/signin` with magic link, Google OAuth, or Solana wallet
- `/login` and `/signup` redirect to `/signin` for compatibility
- Magic links use a scanner-safe flow: GET confirms, POST consumes
- Dashboard and monitoring pages are public
- Task creation/editing requires login

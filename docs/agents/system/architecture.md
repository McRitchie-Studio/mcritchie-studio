# Architecture

> **Looking for the current agent roster?** See [`mission.md`](mission.md) — 9 agents as of 2026-05-23 (Alex, Avi, Carl, Shannon, Jasper, Steffon, Turf Monster, Mack, Mason). This doc covers the data + API surface; `mission.md` covers who does what.

## Stack

- Ruby 3.1+ / Rails 7.2 / PostgreSQL
- ERB views, Tailwind CSS via CDN, Alpine.js
- Import maps (no JS build step)
- Montserrat font, dark navy/mint/violet theme

## Database Schema

All foreign keys use slug strings (not integer IDs).

### Core Tables
- `agents` — Registry of all AI agents with status, type, and config
- `tasks` — Work items with stage pipeline and agent assignment
- `skills` — Capability catalog
- `skill_assignments` — Agent-skill join table with proficiency scores
- `activities` — Chronological log of all agent actions
- `usages` — Per-agent, per-period API cost and token tracking
- `users` — Human operators with bcrypt + Google OAuth auth
- `error_logs` — Structured error capture with polymorphic context

### Task Pipeline
```
new → queued → in_progress → done
                            → failed
         any stage → archived
```

## API

JSON API at `/api/v1/` for programmatic agent access:
- `GET/POST /api/v1/tasks` — List and create tasks
- `POST /api/v1/tasks/:slug/queue|start|complete|fail_task` — Stage transitions
- `POST /api/v1/release_notes` — Format and send canonical Discord Release Notes
- `GET/PATCH /api/v1/agents/:slug` — Read and update agent status
- `POST /api/v1/activities` — Log agent activity
- `POST /api/v1/usages` — Report usage metrics

## Frontend

Dashboard is public (monitoring). Task mutations require authentication.
All views use the shared dark theme with stage-colored badges.

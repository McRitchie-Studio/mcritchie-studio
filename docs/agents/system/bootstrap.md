# Bootstrap

> **Rebuilding a fresh Mac with all 5 repos?** Use `bin/ecosystem-build` instead.
> See [house-burn-down.md](house-burn-down.md) for the canonical recovery protocol.
> This doc covers a quick single-app bringup once toolchain + `.env` are already in place.

## First-Time Setup

```bash
cd mcritchie-studio
bundle install
bin/rails db:create db:migrate db:seed
bin/rails server
```

Visit `http://localhost:3000` — dashboard shows the 9 agents (Alex, Avi, Carl, Shannon, Jasper, Steffon, Turf Monster, Mack, Mason), task pipeline, activity feed.

## Agent docs + user-global skills

McRitchie Studio is the canonical home for the projects-root agent entrypoints
**and** the operator's user-global Claude Code skills. Install (or re-sync) both
in one idempotent command:

```bash
bin/install-agent-docs          # AGENTS.md + CLAUDE.md → projects root; docs/agents/skills/* → ~/.claude/skills/*
bin/install-agent-docs check    # verify nothing has drifted from the tracked sources
```

`bin/ecosystem-build` runs this automatically (Phase 5b) on a full-machine
rebuild; run it by hand here when you only brought up the one app. Project-scoped
skills under `.claude/skills/` are a separate mechanism and are not touched.

## Login

McRitchie Studio is passwordless-first.

1. Visit `http://localhost:3000/signin`.
2. Request a magic link for `alex@mcritchie.studio`.
3. In normal local development, open the email from the real inbox. In an agent worktree stack, use the printed local inbox at `http://localhost:<port>/_studio/local_emails`.

Legacy `GET /login` and `GET /signup` redirect to `/signin`. The engine still keeps route helpers and POST actions for compatibility.

## Google OAuth (optional)

Set environment variables:
```bash
export GOOGLE_CLIENT_ID=your_client_id
export GOOGLE_CLIENT_SECRET=your_client_secret
```

## Re-seeding

Seeds are idempotent (`find_or_create_by!`) — safe to re-run anytime:
```bash
bin/rails db:seed
```

## API Quick Test

```bash
# List agents
curl http://localhost:3000/api/v1/agents

# Create a task
curl -X POST http://localhost:3000/api/v1/tasks \
  -H "Content-Type: application/json" \
  -d '{"title": "Test task", "agent_slug": "mack", "priority": 0}'

# Start a task
curl -X POST http://localhost:3000/api/v1/tasks/SLUG/start
```

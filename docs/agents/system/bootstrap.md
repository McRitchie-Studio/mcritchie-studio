# Bootstrap

> **Rebuilding a fresh Mac with the ecosystem repos?** Use `bin/ecosystem-build` instead.
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
**and** the operator's shared user-global agent skills. If this machine has no
roots yet — nothing at `/Users/alex/projects/AGENTS.md`, no `~/.claude/skills` —
that is **bringup**, and one idempotent command installs both:

```bash
bin/agent-runtime install       # BRINGUP ONLY — publishes globally to this whole machine
bin/agent-runtime doctor        # read-only — docs, marker hooks, login-shell Ruby/Bundler/Rails
```

**Once, to bring a bare machine up — then never again.** That command is not
scoped to this app or this checkout. It publishes **globally**: the projects-root
`AGENTS.md` and `CLAUDE.md`, `~/.claude/skills`, `~/.codex/skills`,
`~/.claude/settings.json`, `/etc/codex/requirements.toml`, and an appended block
in `~/.zprofile`. Every agent session on the machine reads what it writes. After
bringup the roots are republished by the owned `sync_agent_docs` step of every
production ship, so a second run is never owed — and it is **never** the answer
to an installed-docs drift report. From a feature worktree it would publish that
branch's unshipped text to every session here, which is how the 2026-09-08
incident happened. The rule, and the closed list of the two runs that stay
legitimate, live in
[`../modules/docs-maintenance.md`](../modules/docs-maintenance.md) § Editing The
Entry Docs; this one is exemption 1.

Bringing up the **whole machine** instead? Use
[`ecosystem-build.md`](ecosystem-build.md) — `bin/ecosystem-build` runs the same
install at Phase 5b, plus toolchain, sibling repos, and databases. It is the
better road when you want the ecosystem, and the wrong one for a single app: it
clones every sibling and stops at Phase 4 without a 1Password service-account
token, which is *before* the step that would have installed the roots.

`bin/install-agent-docs check` and `bin/agent-runtime doctor` are read-only and
safe at any time; `check` is the byte-for-byte docs/skills drift check that
`doctor` calls. Project-scoped runtime skills, such as `.claude/skills/`, are a
separate mechanism and are not touched.

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

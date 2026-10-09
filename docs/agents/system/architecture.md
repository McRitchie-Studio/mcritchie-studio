# Architecture

The hub's stack, data and API surface. Who does what: [`mission.md`](mission.md).
The pages: [`user.md`](user.md). The ecosystem: `docs/ECOSYSTEM.md`.

## Stack

| Layer | Choice |
|-------|--------|
| Runtime | Ruby 3.3.11, Rails 8.1, PostgreSQL, Puma (`Procfile`) |
| Views | ERB; Tailwind compiled by `tailwindcss-rails`; Alpine.js, the Montserrat font and the light/dark theme come from `studio-engine`'s head partial |
| JavaScript | Import maps, no build step: Turbo and Chart.js (`config/importmap.rb`) |
| Jobs | Solid Queue (`worker: bin/jobs`) |
| Rate limits | Rack::Attack (`config/initializers/rack_attack.rb`); production counts in Solid Cache on the primary database, so every dyno and every deploy share one count; the client address comes from X-Forwarded-For alone, never a client-written `Forwarded` header (`config/initializers/forwarded_headers.rb`) |
| Storage | Active Storage on Cloudflare R2: `mcritchie-studio-production` in production, `mcritchie-studio-dev` on desks and QA (`config/storage.yml`) |
| Email | Resend through `Studio::Email.deliver`; the durable outbox is `studio_email_deliveries` |
| Auth | `studio-engine` passwordless sign-in: magic link and Google (`config.auth_methods` in `config/initializers/studio.rb`); no wallet auth, since the hub has no on-chain surface |

## Data

Foreign keys are slug strings. The tables an agent meets first:

| Table | Holds |
|-------|-------|
| `agents` | The soul registry: status, type, config |
| `tasks` | Work items: stage, repos, branch, acceptance, DevOps metadata |
| `releases` | Release candidates and their members |
| `agent_activities` | Narrated activities from `bin/agent-activity` |
| `activities` | The agent action log |
| `usages` | Per-agent API cost and tokens |
| `users` | Operators; `provider` and `uid` carry the Google identity |
| `error_logs` | Structured error capture from `studio-engine` |

The full schema is `db/schema.rb`; the walk-through is `docs/topics/data-model.md`.

## Task pipeline

```text
Build:   designed → building → submitted            (the builder's)
Deploy:             submitted → reviewed → assembled → shipped   (DevOps's)
                                              any stage → archived
```

`Task::STAGES`, split at the `submitted` seam. `blocked` is an attribute of a
`building` task, not a stage; `archived` is terminal from any stage.

## API

JSON at `/api/v1/`. `POST /api/v1/auth` trades the `AGENT_API_SECRET` for a bearer
token that lasts 24 hours; every other endpoint reads `Authorization: Bearer`.

| Endpoint | Purpose |
|----------|---------|
| `GET/POST /api/v1/tasks`, `GET/PATCH/DELETE /api/v1/tasks/:slug` | Read, create, move and delete tasks |
| `POST /api/v1/tasks/:slug/intent` | Live agent intent for a target stage |
| `/api/v1/tasks/:slug/review_claim`, `review_events`, `events/:stage/{start,complete,fail}` | Review claims and stage events |
| `GET/PATCH /api/v1/agents/:slug` | Read and update agent status |
| `POST /api/v1/agent_activities`, `POST /api/v1/agent_actions` | Narration (`bin/agent-activity`) |
| `POST /api/v1/activities`, `POST /api/v1/usages` | Action log and usage metrics |
| `POST /api/v1/release_notes` | Discord release notes |
| `POST /api/v1/github/webhook` | GitHub pull-request events |

The rest is in `config/routes.rb`.

## Access

Every page needs an admin unless `AdminWall::PUBLIC` lists it
(`app/controllers/concerns/admin_wall.rb`): a default-deny wall, and an admin
wall because hub signup is open. Public: the landing, legal, packages, `/build`
funnel, contact, schedule and `/links` pages, unsubscribe and email tracking,
sign-in, the NFL pages, and `/tasks/:slug/local_review`. A signed-in non-admin
reaches only their own profile. The API (bearer), `/webhooks/*` (signed) and
`/up` sit outside the wall. `test/integration/admin_wall_test.rb` walks the
route table, so a new route is walled until it is listed.

The public list has two sources. Pages come from the navigation registry,
`config/navigation.yml`: each page declares `audience: public` or `admin`, and
the same entries build the link sidebar, `/links`, `/admin/links` and the section
sub-navs (`components/_sub_nav`), so a link and the page behind it cannot
disagree. Public actions that are not site pages (form posts, probes, tracking
pixels, the auth, unsubscribe and local-development doors) stay an explicit list,
`AdminWall::PUBLIC_ACTIONS`. `test/integration/admin_wall_public_set_test.rb`
pins the whole public set, so opening a page means editing the registry and that
list together.

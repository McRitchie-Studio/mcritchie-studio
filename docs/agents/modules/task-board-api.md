# Task-Board API

The McRitchie Studio task board is the durable coordination surface for the
feature → task → PR → QA → deploy loop (see
[`devops-task-board.md`](devops-task-board.md) for the workflow and stage
policy). This file documents the **HTTP API** an agent uses to create and move
tasks. The workflow doc describes *what* to record; this doc describes *how to
talk to the board*.

It is written against the live code (`config/routes.rb`,
`app/controllers/api/v1/*`, `app/models/task.rb`). When the code changes, update
this file in the same pass.

> ⚠️ **Mostly current, with legacy examples below.** The live task model is the
> two-workflow 8-stage one (`designed → building → submitted → reviewed →
> assembled → shipped`, plus `blocked`/`archived`). The endpoints table and
> lifecycle-event sections are current; any older examples that mention named
> legacy transition routes should be treated as historical and replaced with
> either `PATCH stage` or the event APIs documented here.

> **Preferred path: use `bin/task`.** Don't hand-roll the HTTP calls below
> unless you're debugging. `bin/task create|update|move|list|show` handles auth,
> JSON, devops read-merge-write, and stage routing for you, and reads the secret
> via `bin/secret`. The raw API in this doc is the reference `bin/task` is built
> on. See the "Use bin/task" section at the end.

## Authentication

Every endpoint except `POST /api/v1/auth` requires a bearer token.

1. The board reads a shared secret from
   `Rails.application.credentials.agent_api_secret || ENV["AGENT_API_SECRET"]`.
   **If neither is set, auth fails closed and no agent can authenticate.**
   - Production/local value: 1Password item **`Agent API Secret`**
     (`op://agents/Agent API Secret/AGENT_API_SECRET`); also present in
     `mcritchie-studio/.env` and the Heroku config. See
     [`credential-inventory.md`](credential-inventory.md).
2. Exchange the secret for a token:

   ```
   POST /api/v1/auth
   Content-Type: application/json
   { "secret": "<AGENT_API_SECRET>" }
   ```

   Returns `{ "token": "...", "expires_at": "<iso8601>" }`. The token is a Rails
   `MessageVerifier` token (purpose `api_auth`), valid **24h**.
3. Send it on every other call:

   ```
   Authorization: Bearer <token>
   ```

   Missing/invalid/expired tokens return `401` with
   `{ "error": "...", "error_code": "UNAUTHORIZED" }`.

### Secret hygiene

Prefer **`bin/secret agents 'Agent API Secret' AGENT_API_SECRET`** (value to
stdout, diagnostics to stderr, verifies op auth) over hand-rolling `op read`.
`bin/task` already uses it, so you usually never touch the secret directly.

If you must call the API by hand, never inline the secret or echo it — read it at
call time and pipe it straight into the request:

```bash
SECRET="$(/opt/homebrew/bin/op read 'op://agents/Agent API Secret/AGENT_API_SECRET')"
TOKEN="$(curl -sS -X POST https://mcritchie.studio/api/v1/auth \
  -H 'Content-Type: application/json' \
  -d "{\"secret\": \"$SECRET\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')"
# use $TOKEN; never print $SECRET or $TOKEN
```

**Sub-agent constraint:** in sub-agent/headless sandboxes the
`op read → curl` secret chain (and `redis-cli`) is classifier-blocked. A
sub-agent therefore cannot drive this API directly — the **orchestrator brokers
task-board writes** on the sub-agent's behalf.

## Endpoints

Base path `/api/v1`. From `config/routes.rb`:

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/auth` | Exchange secret → bearer token |
| `POST` | `/release_notes` | Send canonical Discord release notes for deployed task slugs |
| `GET` | `/tasks` | List tasks (newest first, paginated) |
| `GET` | `/tasks/:slug` | Show one task |
| `POST` | `/tasks` | Create a task |
| `PATCH`/`PUT` | `/tasks/:slug` | Update a task |
| `DELETE` | `/tasks/:slug` | Delete a task |
| `POST` | `/tasks/:slug/intent` | Record live agent intent for a target stage |
| `POST` | `/tasks/:slug/review_events` | Record a primary/light reviewer check-in |
| `POST` | `/tasks/:slug/events/:stage/start` | Record a task lifecycle start event |
| `POST` | `/tasks/:slug/events/:stage/complete` | Complete a task lifecycle stage/checkpoint |
| `POST` | `/tasks/:slug/events/:stage/fail` | Fail a named task lifecycle step and block the task |
| `POST` | `/releases/:slug/events/:step/start` | Record a release checkpoint start |
| `POST` | `/releases/:slug/events/:step/complete` | Complete a release checkpoint |
| `POST` | `/releases/:slug/events/:step/fail` | Fail a release checkpoint |

`GET /tasks` accepts `?stage=<stage>` and `?agent_slug=<slug>` filters (plus
`?page` / `?per_page`) and returns `{ "data": [...], "meta": { page, per_page,
total, total_pages } }`. Each list item includes its `stage`, so callers can
filter/triage without a per-task `show`. **The filter param is `stage`, not
`status`** — an unsupported query param is rejected with `400
{ "error": "unsupported query param(s): …", "error_code": "UNSUPPORTED_PARAM" }`
rather than silently ignored (which used to return every task). **The default is
`per_page=20`** (capped at 100), ordered newest-CREATED first (`Task.recent` =
`created_at DESC`) **across all stages** — so an unpaginated, unfiltered read
returns only the 20 most recent tasks. `meta.total` is the real count; a client
that ignores `meta` sees no truncation signal. To enumerate a stage in full,
filter with `?stage=` (an actionable stage holds far fewer than 20 rows). A `GET
/tasks/:slug` for an unknown slug returns `404 { "error": "task not found" }`.
(There are also `agents`, `activities`, and `usages` resources; out of scope
here.)

### Release Notes

`POST /api/v1/release_notes` is the canonical way to post production Release
Notes to Discord. Do not hand-compose the Discord message when this API is
available.

The endpoint:

- resolves the provided task slugs from the production task board
- groups linked task titles by application in the standard ecosystem order
- links every task to `https://mcritchie.studio/tasks/<task-slug>`
- includes empty application sections as `No deployed tasks`
- posts to `DISCORD_RELEASE_NOTES_WEBHOOK_URL` with
  `DISCORD_DEPLOY_WEBHOOK_URL` as a compatibility fallback

Request body:

```json
{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-abc123def456"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"]
}
```

Use `dry_run: true` first to render and review the message without sending it:

```bash
api POST /api/v1/release_notes '{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-abc123def456"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
  "dry_run": true
}'
```

Successful responses return `{ "data": { "delivered": true|false,
"dry_run": true|false, "message": "...", "task_slugs": [...] } }`.
Unknown task slugs return `422 UNKNOWN_TASKS`; missing webhook config on a live
send returns `422 MISSING_WEBHOOK`.

### Lifecycle Event APIs

Agents should prefer the event endpoints for new automation. The legacy task
stage `PATCH` still exists, but event endpoints give the board a deterministic
paper trail and enforce usage metadata on completed/failed agent work.

Task lifecycle endpoints:

```bash
POST /api/v1/tasks/:slug/events/:stage/start
POST /api/v1/tasks/:slug/events/:stage/complete
POST /api/v1/tasks/:slug/events/:stage/fail
```

Known `:stage` values include the normal task stages
`designed|building|submitted|reviewed|assembled|shipped|archived`, plus named
checkpoints such as `heavy_review`, `light_review`, `design`, and
`design_complete`. `start` records an intent when the named stage is the task's
next workflow stage; otherwise it records a checkpoint. `complete` moves the
task when the stage is a real workflow stage; named review/design checkpoints
record an append-only `TaskEvent(kind: checkpoint)` without moving the task.
`fail` records the named failed checkpoint, then moves the task to `blocked`
with `kind` defaulting to `rework`.

Release checkpoint endpoints:

```bash
POST /api/v1/releases/:slug/events/:step/start
POST /api/v1/releases/:slug/events/:step/complete
POST /api/v1/releases/:slug/events/:step/fail
```

Canonical release steps are:

```text
review_tests assemble_release deploy_qa qa_smoke ship_gate ship_authorized
deploy_prod prod_smoke release_notes archive_tasks
```

The tracker aliases also work: `testing`, `assembling`, `qa_deploying`,
`confirming`, and `production_deploying`.

For `complete` and `fail` calls from agent/API/CLI sources, usage is mandatory:

```json
{
  "event": {
    "actor": "avi",
    "source": "api",
    "model": "gpt-5",
    "tokens_in": 12000,
    "tokens_out": 1800,
    "cost": "0.4200",
    "idempotency_key": "rel-20260628-demo:ship_gate:complete"
  }
}
```

`start` does not require usage because work has just begun. Deterministic
server-side writers such as `bin/release` use `source: "conductor"` and may
record spine-only events. Repeated calls should pass `idempotency_key` so retries
return the existing release event instead of stacking duplicates.

Start/intents create the analytics timestamp; completions create the accounting
row. Do not put model/tokens/cost on `start` or intent calls. Agent/API/CLI
`complete` and `fail` calls must report `model`, `tokens_in`, `tokens_out`, and
`cost`; deterministic `source: conductor|system` completions may stay
spine-only.

### Review Check-In API

Reviewer agents broadcast progress with:

```bash
POST /api/v1/tasks/:slug/review_events
```

It records a `TaskEvent(kind: checkpoint)` and does not move the task stage. The
task detail page links reviewed/live-review timeline cards to
`/tasks/:slug/review_events`, which groups these check-ins by the heavy and
light reviewer swimlanes. The deployments board's Submitted column also links to
the global review-process hub at `/review_events`, which shows the canonical
moment order, top recent role owners, and recent submitted/reviewed/assembled/
shipped task drilldowns.

Payload:

```json
{
  "review_event": {
    "role": "primary",
    "moment": "diff",
    "status": "info",
    "actor": "carl",
    "source": "agent",
    "message": "Routes, controller, and persistence diff scanned.",
    "idempotency_key": "task-slug:primary:diff",
    "metadata": { "pr": "https://github.com/amcritchie/mcritchie-studio/pull/123" }
  }
}
```

Roles are `primary` and `light`. The UI labels `primary` as the **heavy**
swimlane. The legacy aliases `heavy`, `heavy_review`, and `light_review` are
accepted for API compatibility; they normalize to `primary`/`light`.

Canonical primary moments:

```text
started context diff tests risk findings completed failed
```

Canonical light moments:

```text
started context diff smoke handoff completed failed
```

`status` is `started`, `info`, `completed`, or `failed`; when omitted it is
derived from the moment (`started`, `completed`, and `failed` self-map,
everything else is `info`). `completed` and `failed` events from `api`, `agent`,
or `cli` sources must include `model`, `tokens_in`, `tokens_out`, and `cost`.
Mid-review `started`/`info` check-ins may be spine-only. Pass
`idempotency_key` on every automated broadcast so retries return the existing
checkpoint instead of stacking duplicates.

The older task lifecycle aliases still work:

```bash
POST /api/v1/tasks/:slug/events/heavy_review/complete
POST /api/v1/tasks/:slug/events/light_review/complete
```

Use the dedicated `review_events` endpoint for new reviewer automation because
it captures the specific check-in moment and message.

## Writable fields

`POST`/`PATCH` permit exactly (`tasks_controller.rb#task_params`):

- `title` (required), `description`
- `priority` — `0`, `1`, or `2`
- `agent_slug` — owning agent (optional)
- `stage` — see stages below
- `required_skills` — array of strings
- `metadata` — free-form hash
- `devops` — **top-level** object, normalized and stored at `metadata.devops`

`slug` is **not** writable — it is auto-generated as `task-<hex>` on create. The
human-readable handle lives in `devops.worktree_slug`; see
[`devops-task-board.md`](devops-task-board.md). Bind the generated production
task URL to the local stack with
`bin/agent-worktree bind-task <app> <worktree-slug> <task-slug-or-url>` so
terminal context and PR bodies can lead from the task record.

## Stages

Eight stages (`Task::STAGES`):
`designed` → `building` → `submitted` → `reviewed` → `assembled` → `shipped`,
plus `blocked` and `archived`.

There are no named transition endpoints. Move stages with a raw update:

```
PATCH /api/v1/tasks/:slug   { "stage": "submitted" }
```

Stage is also directly settable on create/update; transitions are **not**
guarded by a state machine, so any stage can be set to any value (only validated
against `Task::STAGES`). Follow the documented stage policy by convention.

## Stage-change event trail

Every stage change appends an **append-only `TaskEvent`** — the durable change
log behind the **Stage Timeline** on the task page (`/tasks/<slug>`). You get the
core of it for **zero effort**:

- **Automatic (deterministic spine).** On *every* move — CLI, API, web, or
  release-conductor — the board records `from_stage`, `to_stage`, `occurred_at`,
  and `seconds_in_from` (time spent in the stage you left). Moving the task is the
  only action required; the duration is measured server-side, never passed.
- **Optional (agent-reported usage).** To attribute model cost to the work you
  did in the stage you're leaving, pass it on the move. It is **best-effort and
  per-transition** — null when omitted, and for non-agent moves. `bin/task`
  auto-captures this usage for Claude (`CLAUDE_CODE_SESSION_ID`) and Codex
  (`CODEX_THREAD_ID`) sessions from the local transcript when explicit usage
  flags are absent; missing transcripts or unpriced models degrade to the
  deterministic spine only.

```bash
bin/task move <slug> submitted \
  --model claude-opus-4-8 --tokens-in 240000 --tokens-out 96000 --cost 5.40 \
  --actor alex        # --actor optional; the working session is auto-stamped otherwise
```

Raw API: send a top-level `event` object alongside `stage` on the `PATCH` (it is
consumed for the event row only — not stored on the task):

```
PATCH /api/v1/tasks/:slug
{ "stage": "submitted",
  "event": { "model": "claude-opus-4-8", "tokens_in": 240000,
             "tokens_out": 96000, "cost": 5.40, "actor": "alex" } }
```

**Backfill** existing tasks once, from their stage-timestamp columns:
`rake task_events:backfill` (idempotent; reconstructed rows are flagged
`source=system`).

Source of truth: `app/models/task_event.rb`, `Task#record_genesis_event` /
`#record_transition_event`, and `app/models/current.rb` (the request-scoped
bridge that carries usage into the event).

**Genesis and live building display.** `Created → Designed` is the deterministic
task-creation marker. It has no actor/model/tokens/cost because the task slug and
usage baseline do not exist until the create call lands. `bin/task create` then
seeds the usage baseline, so design work is accounted on the next conclusion:
`Designed → Building`. While the task is currently `building`, the task detail
timeline marks that same `Designed → Building` card live; it does not append a
second `Building` card.

**Release duration cache.** `Release::DurationCache` derives stage spans from
task intents to conclusions (`building`, `reviewing`, `assembled`, `shipped`)
and release spans from `ReleaseEvent`s. Cached metrics live on
`releases.duration_metrics` with `duration_metrics_cached_at` and
`duration_cache_version`. Task/release event writes refresh the owning release
best-effort, `bin/rails releases:refresh_duration_metrics` refreshes the last
three shipped releases, and `/deployments/all` plus `/deployments/:slug` render
from the cache with an in-memory fallback when a row is missing.

## The `devops` object

Send `devops` as a top-level key; it is normalized
(`Task.normalize_devops_metadata`) and merged into `metadata.devops`. Only these
keys survive (`Task::DEVOPS_KEYS`):

- **Scalars:** `kind`, `worktree_slug`, `branch`, `pr_url`, `local_url`, `qa_url`,
  `production_url`, `release_slug`, `requires_release_conductor`
- **Lists:** `repositories`, `risk_tags`, `acceptance`, `test_plan`,
  `checks_run`

## Footguns (verified, will bite you)

1. **`update` overwrites `metadata.devops` wholesale.** If a `PATCH` includes a
   `devops` object, it **replaces** the stored devops entirely — any field you
   omit is lost. Re-send the *full* devops object on every update that touches
   it. (A `PATCH` that omits `devops` leaves `metadata` untouched — use that to
   move only the stage.) **`bin/task update` does this read-merge-write for you**,
   so partial updates are safe through the CLI.
2. **List delimiting differs by input type.** `normalize_devops_list` treats
   **array** input (the JSON API / `bin/task`) as already-delimited and splits it
   **only on newlines** — so commas inside an `acceptance`/`test_plan` sentence
   are preserved. **String** input (UI free-text fields) still splits on both
   commas and newlines, so one field can carry several entries. Practical rule:
   from the API/`bin/task`, **always pass list values as arrays** (one element
   per item) and commas are safe.
3. **Unsupported `devops` keys are silently dropped.** Anything not in
   `DEVOPS_KEYS` is discarded by the normalizer. To stash extra data, write it
   under `metadata` directly instead of `devops`.
4. **`slug` is auto-generated**, not settable — don't expect a human-readable
   task slug from the API.

## Worked example

```bash
BASE=https://mcritchie.studio
SECRET="$(/opt/homebrew/bin/op read 'op://agents/Agent API Secret/AGENT_API_SECRET')"
auth() { curl -sS -X POST "$BASE/api/v1/auth" -H 'Content-Type: application/json' \
  -d "{\"secret\": \"$SECRET\"}" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])'; }
TOKEN="$(auth)"
api() { curl -sS -X "$1" "$BASE$2" -H "Authorization: Bearer $TOKEN" \
  ${3:+-H 'Content-Type: application/json' -d "$3"}; }

# 1. Create (list values are arrays; commas inside an item are preserved)
api POST /api/v1/tasks '{
  "title": "Add sticky header to admin users table",
  "priority": 1,
  "agent_slug": "shannon",
  "devops": {
    "kind": "feature",
    "worktree_slug": "admin-users-sticky-header",
    "repositories": ["mcritchie-studio"],
    "risk_tags": ["ui"],
    "acceptance": ["Header stays pinned while the table scrolls"],
    "test_plan": ["bin/rails test"],
    "checks_run": ["bin/rails test test/controllers/tasks_controller_test.rb"]
  }
}'   # -> returns the created task with slug "task-<hex>"

# 2. Claim it (creates/enters the worktree first, then:)
api PATCH /api/v1/tasks/task-XXXX '{"stage": "building"}'

# 3. Submit for review — PATCH the stage and
#    RE-SEND the full devops (update overwrites it) plus branch + pr_url:
api PATCH /api/v1/tasks/task-XXXX '{
  "stage": "submitted",
  "devops": {
    "kind": "feature",
    "worktree_slug": "admin-users-sticky-header",
    "repositories": ["mcritchie-studio"],
    "risk_tags": ["ui"],
    "branch": "feat/admin-users-sticky-header",
    "pr_url": "https://github.com/amcritchie/mcritchie-studio/pull/123",
    "acceptance": ["Header stays pinned while the table scrolls"],
    "test_plan": ["bin/rails test"],
    "checks_run": ["bin/rails test test/controllers/tasks_controller_test.rb"]
  }
}'

# 4. Review/merge/QA progression uses the same update path:
api PATCH /api/v1/tasks/task-XXXX '{"stage": "reviewed"}'
api PATCH /api/v1/tasks/task-XXXX '{"stage": "assembled"}'   # devops preserved (no devops param)

# 5. Shipped (after approved deploy + post-deploy check):
api PATCH /api/v1/tasks/task-XXXX '{"stage": "shipped"}'

# 6. Production release notes (dry-run first, then repeat without dry_run):
api POST /api/v1/release_notes '{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-XXXX"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
  "dry_run": true
}'
```

## Verifying this doc

Cross-check against source when in doubt:

```bash
sed -n '/namespace :api/,/^  end/p' config/routes.rb       # endpoints
grep -n "params.permit" app/controllers/api/v1/tasks_controller.rb   # writable fields
grep -n "STAGES\|DEVOPS_KEYS\|normalize_devops" app/models/task.rb   # stages + devops contract
```

## Use `bin/task` (the preferred path)

`bin/task` wraps everything above so you don't construct JSON, manage tokens, or
remember which stages have transition endpoints. It reads the secret via
`bin/secret`, does devops **read-merge-write** (partial updates never wipe
fields), and sends list flags as arrays so comma-containing items stay intact.

```bash
bin/task list [--stage S] [--agent A]
bin/task show <slug>
bin/task create --title T [--kind K] [--repo R ...] [--risk R ...] \
                [--accept "..." ...] [--test "..." ...] [--agent A]
bin/task update <slug> --branch B --pr-url U   # merges into existing devops
bin/task move <slug> <stage>                   # bare Claude/Codex moves auto-capture usage
bin/task move <slug> submitted \               # optional per-transition usage →
  --model M --tokens-in N --tokens-out N --cost D --actor A   #   recorded on the TaskEvent
```

> ⚠️ **`bin/task list` caps at 20 rows, recency-ordered across all stages, with
> no truncation warning.** It surfaces only the API's default page (`per_page=20`,
> `created_at DESC`) and discards `meta`, so it prints `(20 task(s))` even when
> more exist — older tasks in quiet apps silently fall off. **`bin/task list
> --stage <stage>` is the reliable enumeration** (an actionable stage holds far
> fewer than 20); enumerate the Deploy queue by stage at the start of every cycle
> (see [`parallel-agent-devops.md` → Step 0](parallel-agent-devops.md#step-0--assess-the-queue-by-stage)).

List flags are **repeatable** (one value per flag), so commas inside an
`acceptance`/`test_plan` item are safe. Fall back to the raw API above only when
`bin/task` can't express what you need.

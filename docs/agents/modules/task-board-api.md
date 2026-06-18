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

Never inline the secret or echo it. Read it from 1Password at call time and pipe
it straight into the request:

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
| `GET` | `/tasks` | List tasks (newest first, paginated) |
| `GET` | `/tasks/:slug` | Show one task |
| `POST` | `/tasks` | Create a task |
| `PATCH`/`PUT` | `/tasks/:slug` | Update a task |
| `DELETE` | `/tasks/:slug` | Delete a task |
| `POST` | `/tasks/:slug/queue` | Stage → `queued` |
| `POST` | `/tasks/:slug/start` | Stage → `in_progress` |
| `POST` | `/tasks/:slug/complete` | Stage → `done` (accepts `result`) |
| `POST` | `/tasks/:slug/fail_task` | Stage → `failed` (accepts `error_message`) |
| `POST` | `/tasks/:slug/archive` | Stage → `archived` |

`GET /tasks` accepts `?stage=<stage>` and `?agent_slug=<slug>` filters and
returns `{ "data": [...], "meta": { page, per_page, total, total_pages } }`.
(There are also `agents`, `activities`, and `usages` resources; out of scope
here.)

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
human-readable handle lives in `devops.worktree_slug` (or the description); see
[`devops-task-board.md`](devops-task-board.md).

## Stages

Nine stages (`Task::STAGES`):
`new` → `queued` → `in_progress` → `pr_review` → `qa_review` → `prod_ready` →
`done`, plus `failed` and `archived`.

Only five have transition endpoints: `queue` (queued), `start` (in_progress),
`complete` (done), `fail_task` (failed), `archive` (archived). **There is no
endpoint for `pr_review`, `qa_review`, or `prod_ready`** — move into those with a
raw update:

```
PATCH /api/v1/tasks/:slug   { "stage": "pr_review" }
```

Stage is also directly settable on create/update; transitions are **not**
guarded by a state machine, so any stage can be set to any value (only validated
against `Task::STAGES`). Follow the documented stage policy by convention.

## The `devops` object

Send `devops` as a top-level key; it is normalized
(`Task.normalize_devops_metadata`) and merged into `metadata.devops`. Only these
keys survive (`Task::DEVOPS_KEYS`):

- **Scalars:** `kind`, `branch`, `pr_url`, `local_url`, `qa_url`,
  `production_url`, `release_train`, `requires_release_conductor`
- **Lists:** `repositories`, `risk_tags`, `acceptance`, `test_plan`

## Footguns (verified, will bite you)

1. **`update` overwrites `metadata.devops` wholesale.** If a `PATCH` includes a
   `devops` object, it **replaces** the stored devops entirely — any field you
   omit is lost. Re-send the *full* devops object on every update that touches
   it. (A `PATCH` that omits `devops` leaves `metadata` untouched — use that to
   move only the stage.)
2. **List items split on commas *and* newlines.** `normalize_devops_list` splits
   each `acceptance`/`test_plan`/`risk_tags`/`repositories` entry on `[,\n]`. A
   single item containing a comma silently fragments into multiple items. **Keep
   commas out of list items** (use `/`, `;`, or rephrase).
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

# 1. Create (note: no commas inside list items)
api POST /api/v1/tasks '{
  "title": "Add sticky header to admin users table",
  "priority": 1,
  "agent_slug": "shannon",
  "devops": {
    "kind": "feature",
    "repositories": ["mcritchie-studio"],
    "risk_tags": ["ui"],
    "acceptance": ["Header stays pinned while the table scrolls"],
    "test_plan": ["bin/rails test"]
  }
}'   # -> returns the created task with slug "task-<hex>"

# 2. Claim it (creates/enters the worktree first, then:)
api POST /api/v1/tasks/task-XXXX/start

# 3. Move to PR review — NO transition endpoint, so PATCH the stage and
#    RE-SEND the full devops (update overwrites it) plus branch + pr_url:
api PATCH /api/v1/tasks/task-XXXX '{
  "stage": "pr_review",
  "devops": {
    "kind": "feature",
    "repositories": ["mcritchie-studio"],
    "risk_tags": ["ui"],
    "branch": "feat/admin-users-sticky-header",
    "pr_url": "https://github.com/amcritchie/mcritchie-studio/pull/123",
    "acceptance": ["Header stays pinned while the table scrolls"],
    "test_plan": ["bin/rails test"]
  }
}'

# 4. Avi merges + deploys to QA, then moves it on:
api PATCH /api/v1/tasks/task-XXXX '{"stage": "qa_review"}'   # devops preserved (no devops param)

# 5. Done (after approved deploy + post-deploy check):
api POST /api/v1/tasks/task-XXXX/complete '{"result": {"summary": "shipped", "production_url": "..."}}'
```

## Verifying this doc

Cross-check against source when in doubt:

```bash
sed -n '/namespace :api/,/^  end/p' config/routes.rb       # endpoints
grep -n "params.permit" app/controllers/api/v1/tasks_controller.rb   # writable fields
grep -n "STAGES\|DEVOPS_KEYS\|normalize_devops" app/models/task.rb   # stages + devops contract
```

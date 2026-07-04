# DevOps Task Board

McRitchie Studio's task board is the durable coordination surface for feature,
bug, QA, release, and cleanup work. Chat can start work, but task metadata is
the handoff that survives across agents, PRs, QA deploys, production deploys,
and cleanup.

This file covers the **workflow** (stages, metadata, duties). For the **HTTP
API** an agent uses to authenticate and create/move tasks — auth secret, bearer
token, endpoints, writable fields, and the normalizer footguns — see
[`task-board-api.md`](task-board-api.md).

## Flat Tasks First

Do not create parent/child task trees by default. Deliver increments of work as
flat tasks. Big features can use the same `release_slug` value across several
tasks when they need to be promoted together.

Use parent/child modeling only after flat tasks and release-slug tags prove too
weak in real operations.

## Required Task-Tracking Rule

Every feature, bug, QA, release, cleanup, or active-doc change that may produce
a branch, PR, QA deployment, production deployment, or cleanup follow-up must
have a McRitchie Studio task-board item. Chat, `bin/agent-worktree`, GitHub PRs,
and `bin/qa-intake` are supporting channels; they do not replace the task.

Create or update the durable handoff task in production McRitchie Studio at
`https://mcritchie.studio` before implementation starts. Local, QA, and
worktree task boards are only for testing task-board behavior; they are not
durable handoff records. If an agent records task metadata outside production
while implementing, the agent must backfill or update the production task before
PR handoff.

If Mr. McRitchie starts work in chat and no task exists yet, the feature agent
creates a flat production task from the ask before allocating a worktree or
editing files. If a task already exists, the agent updates that task instead of
creating a duplicate.

After the task is created and the isolated worktree is bound, run
`bin/session-preflight <task-slug>` before editing. It is the start-of-session
counterpart to `bin/dor-check`: it reads latest task feedback, branch drift
against `origin/release`, PR merge/check state, same-file overlap with open or
recent PRs, installed docs/skills drift, stale terminology, and the required
test tiers from `config/feature_shapes.yml`.

Feature agents should first identify the feature and accumulate acceptance
criteria until the agent and Mr. McRitchie are aligned on the goal. The task is
the durable version of that alignment. Exceptions are narrow conductor sessions
such as Avi running the DevOps/QA cycle, pure read-only audits, and explicit
release/deploy lanes; those sessions still update tasks when they change
handoff state.

Use one task per independently reviewable increment. For a vertical feature
that touches multiple repos and ships together, either use one task with all
repos listed in `repositories`, or separate flat tasks that share the same
`release_slug` when the increments can be reviewed or promoted separately.

Minimum task setup before implementation:

- `title` and `description` summarize the user-visible ask.
- `kind` is `feature`, `bug`, `chore`, `qa`, `release`, or `cleanup`.
- `worktree_slug` is the human-readable feature handle used for the branch,
  worktree path, terminal context, and local stack. The app-generated
  `Task.slug` remains the immutable production task id.
- `repositories` lists every repo expected to change.
- `acceptance` records concrete acceptance criteria. If the ask is ambiguous,
  confirm criteria with Mr. McRitchie before building.
- `risk_tags` captures likely risk such as `auth`, `email`, `solana`,
  `payment`, `migration`, `ui`, `provider`, `docs`, or `deploy`.
- `test_plan` records the checks the agent expects to run.
- `checks_run` records the checks actually completed before handoff.
- `release_slug` groups related tasks that should move through QA/release
  together. Leave it blank for a small independent task.
- `requires_release_conductor` is `true` when production deploy, gem publish,
  provider config, env vars, data correction, credentials, or migration/backfill
  handling may be needed.

Stage movement:

1. Create captured work in `designed` once acceptance criteria are clear enough
   to track.
2. Move to `building` when an agent claims the task and creates or enters the
   worktree.
3. Move to `submitted` only after the branch is pushed, the PR exists, the
   local URL is recorded when applicable, and `checks_run` records actual
   feature-agent verification.
4. Move to `reviewed` only after the review gate approves the PR.
5. Move to `assembled` when the PR is merged into `release` and deployed or
   ready to deploy on the QA candidate. Record QA URL, deployed SHA, and QA
   checks when available.
6. Move to `shipped` only after the final approved target is deployed or otherwise
   complete, post-deploy verification is recorded, and cleanup status is clear.
7. Use `blocked` for a real blocker that needs new action, and `archived` for
   historical or cleaned-up work.

Handoff connections:

- Set `devops.worktree_slug` to the human-readable worktree slug. The generated
  `Task.slug` is not human-readable and should not be manually changed.
- Bind the production task to the local stack with
  `bin/agent-worktree bind-task <app> <worktree-slug> <task-slug-or-url>`.
- The PR body and final handoff should lead with the task URL before the PR URL.
- The task must record `branch`, `pr_url`, `local_url` when applicable,
  `qa_url` after QA deployment, `production_url` after production deploy,
  `test_plan`, and `checks_run`.
- `bin/qa-intake` should be used by Avi to discover worktree/PR state, but Avi
  should join that queue back to tasks and leave feedback on the task or PR when
  metadata is missing.
- Final handoff should name the task, PR, release slug when present, URLs,
  `checks_run`, deployment SHA/release, and cleanup decision.

## Task Conversation and QA Feedback

The task board owns the durable conversation for an increment. `/tasks` cards
show the latest feedback inline so agents can scan the queue without opening a
separate tool. Open the task detail page when you need the full thread or need
to add a note. The response taxonomy lives in
[`review-comment-taxonomy.md`](review-comment-taxonomy.md); use it when deciding
whether a note is a non-blocking clarification or blocking review feedback.

Use these activity types:

- `comment` for general coordination notes.
- `clarification` for non-blocking questions or answers that should not send the
  task back for rework by themselves.
- `qa_feedback` for Avi or Steffon review findings, QA blockers, failed checks,
  missing metadata, or changes requested before merge/deploy.
- `handoff` for feature-agent responses, rebase notes, local proof URLs, or
  "ready again" messages after addressing feedback.

Review scouts record their findings as `comment` activities with
`metadata.kind=scout_report`. This keeps scout evidence visible without
accidentally turning a scout's recommendation into Avi's final review decision.
The normal path is:

1. Avi runs `bin/devops-cycle --scout-packets` and gives a packet to a
   review-only scout session.
2. The scout reviews the task and PR, then dry-runs a structured report:

   ```bash
   bin/devops-cycle --record-scout-report task-XXXX \
     --outcome merge-ready \
     --summary "No blockers found." \
     --finding "Diff matches the task acceptance criteria." \
     --check "Reviewed PR body, changed files, and CI." \
     --dry-run
   ```

3. The scout removes `--dry-run` only after the payload is correct.
4. Avi runs `bin/devops-cycle --scout-reports` to see recorded scout reports
   alongside the task queue.
5. Avi makes the final call. If changes are required, Avi leaves
   `qa_feedback` on the task and usually a PR comment with the code-specific
   blocker.

Valid scout outcomes are `merge-ready`, `wait-for-ci`, `request-changes`, and
`conductor-review`. Scouts do not merge, deploy, move task stages, publish
gems, change providers, rotate credentials, force-push, or take over branches.

When Avi sends work back, Avi should add `qa_feedback` on the task with the
specific action needed and also comment on the PR when the feedback is tied to
GitHub review, CI, or changed code. The task thread is the durable handoff for
the original agent; the PR comment is the code-review surface.

When the feature agent returns, the agent should read the task conversation,
address each open `qa_feedback` item, add a `handoff` note with what changed,
update branch/PR/local URL/check metadata if needed, and move the task back to
`submitted` when ready.

Agents can read or write the same thread through the Activities API:

```bash
GET /api/v1/activities?task_slug=<task-slug>
POST /api/v1/activities
```

Post payloads should include `task_slug`, `activity_type`, `description`,
optional `agent_slug`, and optional `metadata`. API calls require the app's API
bearer token. The HTML task page remains the operator-friendly source of truth.

## Stage Flow

> **Canonical stages (two-workflow model).** The live board runs **Build**
> (`designed → building → submitted`) and **Deploy** (`submitted → reviewed →
> assembled → shipped`), plus `blocked` (side) and `archived` (terminal). Under
> the persistent-`release` branch model, **`reviewed`** = an approved PR whose
> base is `release`, and **`assembled`** = that PR merged into `release`
> (`bin/release merge` flips the task at merge); the conductor then deploys
> `origin/release` to QA (`bin/release prepare`) and ships by fast-forwarding
> `release → main` (`bin/release ship`). Full spec:
> [`devops-cycle-design.md`](../system/devops-cycle-design.md) §1.

The board stages should mirror the release path, not generic activity buckets:

| Stage | Use when |
|---|---|
| `designed` | Scope and acceptance criteria are clear enough to track |
| `building` | A feature agent is actively implementing or fixing the task |
| `submitted` | Branch is pushed and the PR is ready for review |
| `reviewed` | Review approved the PR for merge into `release` |
| `assembled` | PR is merged into `release` and included in the QA candidate |
| `shipped` | Production or final approved target is shipped and verified |
| `blocked` | Work is blocked by a real failure that needs new action |
| `archived` | Historical or cleaned-up work that should not appear on the active board |

Do not skip `assembled` for user-facing app changes. Do not move a task to
`shipped` for production work until production has actually deployed and the
post-deploy check has passed.

## Task Metadata Contract

Tasks carry DevOps metadata in `tasks.metadata["devops"]`. The UI exposes these
fields, and agents may also write them through the JSON API with a top-level
`devops` object.

Supported fields:

| Field | Meaning |
|---|---|
| `kind` | `feature`, `bug`, `chore`, `qa`, `release`, or `cleanup` |
| `worktree_slug` | Human-readable feature handle used for the worktree path, branch, terminal context, and task binding |
| `repositories` | Repos touched by this increment, such as `mcritchie-studio` or `turf-monster` |
| `branch` | The feature branch (opened as a PR with base `release`). The shared integration branch is the persistent per-repo `release` (same name everywhere). |
| `pr_url` | GitHub PR URL |
| `local_url` | Worktree review URL |
| `qa_url` | Stable QA URL or specific QA route |
| `production_url` | Production URL or specific production route |
| `release_slug` | Optional shared tag for tasks promoted together |
| `requires_release_conductor` | `true` when production deploy, gem publish, provider config, or env change is involved |
| `risk_tags` | Short tags such as `auth`, `email`, `solana`, `payment`, `migration`, `ui`, `provider` |
| `acceptance` | Acceptance criteria, one item per line |
| `test_plan` | Checks the feature agent expects to run, one item per line |
| `checks_run` | Checks actually completed before the current handoff, one item per line |
| `post_deploy_cmd` | Command `bin/release` runs **verbatim against the deployed app** (QA on `prepare`, prod on `ship`) after migrations, so a seed/backfill isn't run by hand. Must be **narrow, prod-safe, and idempotent** — **never a bare `db:seed`** (see safety rule below). Set to `none` to acknowledge a schema-only migration that needs no command. |

**`post_deploy_cmd` safety rule.** Because `bin/release` runs the command
verbatim against PRODUCTION, `bin/dor-check` **rejects** a bare full-suite seed
(`bin/rails db:seed`, `rails db:seed`, `bundle exec rails db:seed`,
`db:seed:replant`, `rake db:seed`): `db/seeds.rb` loads **every** `db/seeds/*.rb`,
so it would inject demo News/Content/Tasks into prod and abort the release on the
first non-idempotent seed file. Declare a **scoped single-file runner**
(`rails runner 'load Rails.root.join("db/seeds/NN_x.rb").to_s'`) or a **dedicated
idempotent rake task** (e.g. `bin/rails pokemon:seed`) instead. (Near-miss:
`merge-docs-reviewer-into-alex` shipped `post_deploy_cmd='bin/rails db:seed'`,
caught only when QA aborted because reviewers read the diff, not the metadata.)

Example API payload:

```json
{
  "title": "Fix QA wallet chooser",
  "description": "Clicking Solana auth on QA should open the wallet chooser modal.",
  "priority": 1,
  "agent_slug": "shannon",
  "devops": {
    "kind": "bug",
    "worktree_slug": "qa-wallet-chooser",
    "repositories": ["turf-monster"],
    "branch": "fix/qa-wallet-chooser",
    "local_url": "http://localhost:3102/contests",
    "qa_url": "https://qa.turfmonster.media/contests",
    "risk_tags": ["auth", "wallet", "qa"],
    "acceptance": [
      "Solana auth opens the wallet chooser modal on QA",
      "Email auth still opens the email flow",
      "Non-production banner remains visible"
    ],
    "test_plan": [
      "bin/rails test",
      "QA_BASE_URL=https://qa.turfmonster.media npx playwright test --grep @qa-readonly"
    ],
    "checks_run": [
      "bin/rails test test/controllers/auth_controller_test.rb",
      "local browser smoke on http://localhost:3102/contests"
    ]
  }
}
```

## Feature Agent Duties

Before implementation, the agent should record or confirm:

- task kind
- affected repo or repos
- acceptance criteria
- likely risk tags
- expected local proof URL
- expected tests/checks in `test_plan`

During handoff, the agent updates:

- worktree slug in `worktree_slug`
- branch
- PR URL
- local URL
- checks actually run in `checks_run`
- any changed acceptance criteria
- release lane flag if the work needs production deploy, gem publish, provider
  config, env vars, or credential handling
- a `handoff` note on the task conversation summarizing what changed, what was
  verified, and what Avi should inspect first

## QA / Avi Duties

Avi starts with the task board plus the local PR/worktree tools:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/devops-cycle
bin/devops-cycle --plan
bin/devops-cycle --decisions
bin/devops-cycle --scout-packets
bin/devops-cycle --write-scout-packets tmp/devops-scouts
bin/devops-cycle --scout-runs tmp/devops-scouts --max-scouts 3
bin/devops-cycle --scout-coverage tmp/devops-scouts
bin/devops-cycle --scout-reports
bin/devops-cycle --readiness
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster
```

`bin/devops-cycle` is the first-pass conductor view. It groups active
`submitted`, `reviewed`, and `assembled` tasks with task URLs, PR URLs,
local/QA/production URLs, latest task conversation notes, and matching qa-intake
status when available. `bin/devops-cycle --plan` adds a read-only batch plan
that separates parallel PR reviews, serialized/high-risk work, blocked returns
to feature agents, reviewed work ready for release merge, and assembled release
work waiting for explicit ship authority.
`bin/devops-cycle --decisions` adds an Avi decision summary for PR-review tasks,
combining qa-intake status, latest task activity, and scout report outcomes into
`merge-ready`, `wait-for-ci`, `request-changes`, or `conductor-review`
recommendations.
`bin/devops-cycle --scout-packets` turns reviewable PR-review lanes into
copy-paste prompts for additional review-only sessions. Accurate `repositories`,
`risk_tags`, `pr_url`, `qa_url`, `acceptance`, `test_plan`, and `checks_run`
metadata make the plan and packets useful at scale. `bin/devops-cycle
--write-scout-packets tmp/devops-scouts` writes one prompt file per packet plus
a manifest so Avi can hand files to parallel review sessions without copying
large prompts through chat. `bin/devops-cycle --scout-reports` shows structured
scout reports recorded on task comments so Avi can make the final
merge/request-changes decision from multiple review sessions without losing the
thread. `bin/qa-intake` remains the raw local worktree and GitHub PR view for
branch freshness, stack health, and cleanup-state details.

`bin/devops-cycle --scout-runs tmp/devops-scouts --max-scouts 3` is the local
run-control view for Phase 3B. It reads the launcher manifest and local
`scout-runs.json`, then prints pending/launched/completed/blocked packet counts
and the next prompt files that fit inside the concurrency limit. It does not
spawn agents or update external systems. Avi marks local state with
`--mark-scout-status scout-task-XXXX:launched` and later `:completed` when a
scout report is back.

`bin/devops-cycle --scout-coverage tmp/devops-scouts` is the Phase 3C harvest
view. It compares manifest packets with structured `scout_report` task comments
and calls out missing reports or conflicting outcomes. `bin/devops-cycle
--readiness` is the Phase 3D conductor view: it groups tasks into
ready-to-merge, needs-conductor-review, needs-changes, waiting, Ready To
Assemble, Assembled Release, and scout-gap lanes. These views accelerate
review; they do not transfer release authority. Avi owns review resolution and
production ship, while Steffon's `qa-release` sweep owns merge plus QA deploy.

Scout reports are supporting evidence. Avi turns blocker findings into
`qa_feedback` or PR review comments when the work must return to the feature
agent. Scout reports do not move stages; the active release SOP owns final
merge, QA deploy, production deploy, and task stage changes (Steffon for
`qa-release`, Avi for `production-deploy`).

Use the decision recommendations conservatively:

- `request-changes` means Avi should return the task to the feature agent with
  `qa_feedback` or a PR comment.
- `wait-for-ci` means the next action is to inspect or wait for checks, not
  merge.
- `conductor-review` means the task needs Avi's direct review because it is
  high-risk, multi-repo, missing local intake, or lacks enough scout signal.
- `merge-ready` means scout evidence and qa-intake are aligned; Avi still
  performs the final PR review before merging.

1. Find `submitted` tasks with PR URLs or branches.
2. Confirm acceptance criteria match the PR body and diff.
3. **Review `devops.post_deploy_cmd`, not just the diff** — it runs verbatim
   against prod on ship. Reject a bare `db:seed`; require a narrow, idempotent
   command (`bin/dor-check` enforces this, but read it yourself).
4. Check `risk_tags` for Steffon/infra gate needs.
5. Merge only ready PRs.
6. Merge approved PRs into `release`, then deploy `origin/release` to QA.
7. Move the task to `assembled` with QA URL, QA release SHA, and `checks_run`.
8. Leave production ship gated until Mr. McRitchie explicitly approves release work.

If the PR is not ready, Avi leaves `qa_feedback` on the task conversation with
the exact blocker, expected owner action, and any PR/CI link needed to reproduce
the issue. Also leave a GitHub PR comment when the blocker is code-review
specific or should be visible on the PR.

## Release Slug Tags

Use `release_slug` as a grouping label, not a hierarchy. A conductor can filter
tasks by one release slug and promote those accepted tasks together. Leave it
blank for independent fixes that can be reviewed, QAed, released, and cleaned up
alone.

Good release-slug examples:

- `rel-2026-06-17-turf-admin-identity`
- `rel-studio-engine-0.11-adoption`
- `rel-qa-banner-rollout`

Each task still owns its own PR, acceptance criteria, and URLs.

## Cleanup Tasks

Cleanup is part of the QA/release conductor cycle, not feature-agent scope.
After a task's PR has merged and the accepted release has deployed, the
conductor records or completes a cleanup task with:

- worktree path
- branch
- merged PR
- deployed SHA
- safe-delete condition
- `bin/agent-worktree remove <app> <task-slug> --yes` result

For routine batch cleanup after a wave of PRs land, the conductor can use
`bin/agent-worktree cleanup --reclaim` as the **scale-down-on-close normal
flow**: the dry run lists every worktree that is SAFE to auto-release (clean +
merged-to-`origin/main` or main-equivalent, primary checkout excluded) with its
Redis DB, and `cleanup --reclaim --yes` runs the same full teardown as `remove`
for each one, then shrinks the Redis band toward the floor. It never touches a
dirty or unmerged worktree. Use targeted `remove <app> <task-slug> --yes` when
recording a single named cleanup task; use `cleanup --reclaim` to reclaim all
merged slots at once.

Feature agents keep worktrees and branches until Avi or the release conductor
confirms the PR was merged or intentionally abandoned.

## Test Suite Catalog

`bin/devops-tests` reads `config/devops_test_suites.yml` and shows the local,
QA, devnet, and production checks for each managed app, including lane, trigger,
whether each suite blocks PR merge, and whether it mutates data.

Add or update this catalog whenever a new app joins the managed stack, a test
genre changes, or a deploy smoke command changes.

## Parked Identities

Every managed app should define parked/core identities for known operators. At
minimum, `alex@mcritchie.studio` and `team@mcritchie.studio` must resolve to
admin-capable rows. Apps with wallet auth should also bind known wallets so a
first email, Google, or wallet login adopts the same seeded identity instead of
creating a fresh operator account.

New apps should ship:

- a `User::PARKED_IDENTITIES`-style constant or equivalent app-owned contract
- seeds that consume the same identity contract
- login hooks that claim a parked identity by verified email or wallet
- tests proving known email and wallet logins adopt the parked row

## Discord Deploy Notices

Production deploy conductors must use `POST /api/v1/release_notes` to send the
canonical Discord Release Notes message after a successful production deploy.
Do not hand-format the Discord post when the API is available.

Call the API with the accepted production task slugs, release metadata, URL, and
verification checks. The API groups linked task titles by application in the
standard ecosystem order and points every task link at the production task read
page on McRitchie Studio.

Run a dry-run first:

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

After confirming the rendered `message`, repeat the same request without
`dry_run`. Production uses `DISCORD_RELEASE_NOTES_WEBHOOK_URL`, with
`DISCORD_DEPLOY_WEBHOOK_URL` retained as a fallback for older environments.
Never commit webhook URLs.

## Future Heartbeats

For now, Mr. McRitchie starts and observes agent sessions directly. When agents
start claiming work without direct supervision, add lease fields or a `TaskRun`
model with:

- `claimed_by`
- `claim_expires_at`
- `last_heartbeat_at`
- `blocked_reason`
- `worktree_path`
- `current_command`

Do not add that operational weight until open, unsupervised task claiming
actually starts.

# DevOps Task Board

McRitchie Studio's task board is the durable coordination surface for feature,
bug, QA, release, and cleanup work. Chat can start work, but task metadata is
the handoff that survives across agents, PRs, QA deploys, production deploys,
and cleanup.

## Flat Tasks First

Do not create parent/child task trees by default. Deliver increments of work as
flat tasks. Big features can use the same `release_train` value across several
tasks when they need to be promoted together.

Use parent/child modeling only after flat tasks and release-train tags prove too
weak in real operations.

## Task Metadata Contract

Tasks carry DevOps metadata in `tasks.metadata["devops"]`. The UI exposes these
fields, and agents may also write them through the JSON API with a top-level
`devops` object.

Supported fields:

| Field | Meaning |
|---|---|
| `kind` | `feature`, `bug`, `chore`, `qa`, `release`, or `cleanup` |
| `repositories` | Repos touched by this increment, such as `mcritchie-studio` or `turf-monster` |
| `branch` | Feature branch or release branch |
| `pr_url` | GitHub PR URL |
| `local_url` | Worktree review URL |
| `qa_url` | Stable QA URL or specific QA route |
| `production_url` | Production URL or specific production route |
| `release_train` | Shared tag for tasks promoted together |
| `requires_release_conductor` | `true` when production deploy, gem publish, provider config, or env change is involved |
| `risk_tags` | Short tags such as `auth`, `email`, `solana`, `payment`, `migration`, `ui`, `provider` |
| `acceptance` | Acceptance criteria, one item per line |
| `test_plan` | Checks the feature agent expects to run, one item per line |

Example API payload:

```json
{
  "title": "Fix QA wallet chooser",
  "description": "Clicking Solana auth on QA should open the wallet chooser modal.",
  "priority": 1,
  "agent_slug": "shannon",
  "devops": {
    "kind": "bug",
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
- expected tests/checks

During handoff, the agent updates:

- branch
- PR URL
- local URL
- checks actually run, either in `test_plan` or task result
- any changed acceptance criteria
- release lane flag if the work needs production deploy, gem publish, provider
  config, env vars, or credential handling

## QA / Avi Duties

Avi uses the task board plus `bin/qa-intake`:

1. Find queued or in-progress tasks with PR URLs or branches.
2. Confirm acceptance criteria match the PR body and diff.
3. Check `risk_tags` for Steffon/infra gate needs.
4. Merge only ready PRs.
5. Deploy merged `origin/main` to QA.
6. Update the task with QA URL, QA release SHA, and checks run.
7. Leave production tasks queued until Mr. McRitchie explicitly approves
   release work.

## Release Train Tags

Use `release_train` as a grouping label, not a hierarchy. A conductor can filter
tasks by one release train and promote those accepted tasks together.

Good release-train examples:

- `2026-06-17-turf-admin-identity`
- `studio-engine-0.6.1-adoption`
- `qa-banner-rollout`

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

Feature agents keep worktrees and branches until Avi or the release conductor
confirms the PR was merged or intentionally abandoned.

## Test Suite Catalog

The `/devops` page reads `config/devops_test_suites.yml`. It shows the local,
QA, devnet, and production checks for each managed app, including when each
suite should run and whether it mutates data.

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

QA and production deploy tools should send a Discord message after successful
deployment when `DISCORD_DEPLOY_WEBHOOK_URL` is present in the environment.
Never commit the webhook URL.

Until task-board release-train querying is automated, conductors should pass
the accepted task list explicitly:

```bash
RELEASE_TRAIN=2026-06-17-turf-admin-identity \
DEPLOY_TASKS="Turf #149 team admin email" \
DISCORD_DEPLOY_WEBHOOK_URL="$DISCORD_DEPLOY_WEBHOOK_URL" \
bin/qa-server deploy turf-monster origin/main --yes
```

The message should include app, environment, release/SHA, URL, `/up` status,
release train, and tasks deployed.

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

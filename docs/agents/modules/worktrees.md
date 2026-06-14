# Worktrees

Parallel agents should use git worktrees rather than sharing one checkout.

## Current Direction

Avoid visible sibling directories such as `turf-monster-feature-name` as the long-term default. They make `/Users/alex/projects` hard to scan at scale.

Preferred layout:

```text
/Users/alex/projects/<repo>                 # primary checkout
/Users/alex/projects/<repo>/.worktrees/<task-slug>
```

Do not include an agent id in the path. Tasks can transfer between agents, and multiple agents may collaborate on one branch.

## Launcher

Use McRitchie Studio's launcher for new parallel task stacks:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree apps
bin/agent-worktree plan turf-monster docs-stack
bin/agent-worktree new turf-monster docs-stack
bin/agent-worktree up turf-monster docs-stack
```

The launcher creates `/Users/alex/projects/<repo>/.worktrees/<task-slug>`, branches from current `origin/main`, copies the primary `.env`, writes `.env.agent-stack`, prepares the isolated database, and prints the local URL.

Use `bin/agent-worktree status <app> <task-slug>` to recover the URL later, and `bin/agent-worktree down <app> <task-slug>` to stop a running stack.

## Lifecycle

Use the launcher as the source of truth for worktree stack state:

```bash
bin/agent-worktree list
bin/agent-worktree status turf-monster task-slug
bin/agent-worktree doctor
bin/agent-worktree cleanup
```

- `list` shows task, health, URL, branch, dirty state, merge state, ahead/behind, database, Redis DB, pidfile state, and local inbox URL.
- `status` shows the detailed state for one generated stack.
- `doctor` reports lifecycle drift such as missing stack env files, reused ports, reused Redis DBs, stale pidfiles, dirty worktrees, disabled local email capture, and clean branches already merged to `origin/main`.
- `cleanup` is a dry run. It only prints clean merged worktree candidates.
- `cleanup --write` appends candidates to [`../maintenance/delete-later.md`](../maintenance/delete-later.md). It does not remove files, worktrees, branches, databases, Redis keys, or processes.

Deletion remains manual and approval-gated:

1. Run `bin/agent-worktree down <app> <task-slug>` if the stack is running.
2. Confirm `bin/agent-worktree doctor <app>` has no dirty or unique-work warnings for the target.
3. Add or confirm the delete-later ledger entry.
4. Remove with `git -C /Users/alex/projects/<repo> worktree remove /Users/alex/projects/<repo>/.worktrees/<task-slug>` only after approval.

## Rules

- Branch from current `origin/main`.
- One task branch per worktree.
- Never commit task work on the primary `main` checkout.
- Do not remove a worktree until its branch/PR status is known.
- Log stale worktrees in [`../maintenance/delete-later.md`](../maintenance/delete-later.md) before deleting them.

## Ports

Worktree servers must use a non-primary port from the app's reserved range. See [`ports-and-processes.md`](ports-and-processes.md).

## Worktree Stack Requirements

Worktree tooling should make parallel stacks "just work" without user terminal chores.

Each worktree stack needs its own:

- App-range port (`3101`, `3102`, etc. for Turf Monster).
- Redis DB for Sidekiq and cache. The launcher allocates globally across generated stack env files.
- Development database via `DATABASE_URL`.
- Session cookie key.
- `APP_PORT` so magic links point at the stack.
- `LOCAL_EMAIL_CAPTURE=1` so mail is recorded locally instead of sent.
- Ruby PATH guard when the repo requires a non-system Ruby.

Do not let two Sidekiq processes share one Redis DB while pointing at different databases. A job enqueued by one stack can be processed by the other stack and silently mutate the wrong records.

Worktree magic links are local-first through `/_studio/local_emails`. The central launcher writes `LOCAL_EMAIL_CAPTURE=1`, blanks provider mail credentials in `.env.agent-stack`, and prints the inbox URL next to the app URL. Agents should request the magic link in the UI, then open:

```text
http://localhost:<port>/_studio/local_emails
```

The inbox shows recent outbox rows and proof links such as magic-link sign-in URLs. Worktree stacks should not email real recipients unless the task is specifically testing real delivery. For provider tests, intentionally set `LOCAL_EMAIL_CAPTURE=0` and restore the needed mail credentials in that stack env.

Callback-heavy flows such as Stripe, Google OAuth, CDP/MoonPay, webhooks, and emailed magic links stay on the primary port unless the provider and local listener are configured for the worktree port.

## Scale Note

The port plan supports 99 local stacks per app. Stock Redis usually exposes only databases `0-15`; once local worktree count approaches that limit, move worktree Redis to dedicated Redis instances or explicitly increase the local Redis database count before expecting dozens of live stacks.

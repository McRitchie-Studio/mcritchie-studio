# Worktrees

Parallel agents should use git worktrees rather than sharing one checkout.
The default for any code or active-doc edit is to work in an isolated worktree
with an allocated port.

## Current Direction

Avoid visible sibling directories such as `turf-monster-feature-name` as the long-term default. They make `/Users/alex/projects` hard to scan at scale.

Preferred layout:

```text
/Users/alex/projects/<repo>                 # primary checkout
/Users/alex/projects/<repo>/.worktrees/<task-slug>
```

Do not include an agent id in the path. Tasks can transfer between agents, and multiple agents may collaborate on one branch.

Think of worktrees as desks and primary checkouts as loading docks. Agents do
feature work at desks. The primary checkout stays stable for reading,
integration, final merge, and deploy.

## Startup Rule

When a new agent session starts actual implementation work:

1. Identify the target app and a task slug.
2. Create or update the McRitchie Studio task-board item before editing. The
   task slug should match the worktree slug when practical, and the task should
   include acceptance criteria, affected repos, risk tags, expected checks, and
   release-train metadata when relevant.
3. Inspect the primary checkout only for status and context.
4. Run `bin/agent-worktree plan <app> <task-slug>`.
5. Run `bin/agent-worktree new <app> <task-slug>`.
6. Move the task to `in_progress`.
7. Run `bin/agent-worktree up <app> <task-slug>` when a browser or local URL is
   needed.
8. Make edits only inside `/Users/alex/projects/<repo>/.worktrees/<task-slug>`.
9. Commit coherent work on the feature branch.
10. Run `bin/agent-worktree finish <app> <task-slug>` to produce the PR/QA
   packet.
11. Update the task with branch, PR URL, local URL, checks run, and any changed
   acceptance criteria. Add a task conversation `handoff` note with the change
   summary, verification, and review focus. Move it to `pr_review` when the PR
   is ready for Avi.
12. Return the task slug, branch, worktree path, URL, tests, and PR/QA
   recommendation in the handoff. Do not merge to `main` unless assigned the
   QA/Release lane.

Exceptions:

- Pure read-only audit or exploration can stay in the primary checkout.
- The explicit deploy owner may use the primary checkout for integration,
  version bumps, deploy commits, and production rollout.
- Emergency fixes can use the fastest safe path, but the handoff must say why
  the worktree path was skipped.

## Launcher

Use McRitchie Studio's launcher for new parallel task stacks:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree apps
bin/agent-worktree plan turf-monster docs-stack
bin/agent-worktree new turf-monster docs-stack
bin/agent-worktree up turf-monster docs-stack
bin/agent-worktree finish turf-monster docs-stack
```

The launcher creates `/Users/alex/projects/<repo>/.worktrees/<task-slug>`, branches from current `origin/main`, copies the primary `.env`, writes `.env.agent-stack`, prepares the isolated database, and prints the local URL.

Use `bin/agent-worktree status <app> <task-slug>` to recover the URL later, and `bin/agent-worktree down <app> <task-slug>` to stop a running stack.
Use `bin/agent-worktree finish <app> <task-slug>` when the work is committed
and ready for PR/QA handoff.

## Lifecycle

Use the launcher as the source of truth for worktree stack state:

```bash
bin/agent-worktree list
bin/agent-worktree status turf-monster task-slug
bin/agent-worktree finish turf-monster task-slug
bin/agent-worktree doctor
bin/agent-worktree snapshot
bin/agent-worktree cleanup
bin/agent-worktree cleanup --reclaim
bin/agent-worktree cleanup --reclaim --yes
bin/agent-worktree remove turf-monster task-slug --yes
bin/agent-worktree scale status
```

- `list` shows task, health, URL, branch, dirty state, merge state, ahead/behind, database, Redis DB, pidfile state, and local inbox URL.
- `status` shows the detailed state for one generated stack.
- `finish` prints a feature graduation packet and PR body. It blocks dirty
  worktrees, branches with no commits ahead of `origin/main`, stale branches
  behind `origin/main`, and already-merged branches. Add `--push` to push the
  branch, or `--push --pr` to create a draft PR through `gh` when available.
- `doctor` reports lifecycle drift such as missing stack env files, reused ports, reused Redis DBs, stale pidfiles, dirty worktrees, disabled local email capture, and clean branches already merged to `origin/main`.
- `snapshot` prints a non-secret JSON registry of every generated worktree,
  including health, local URLs, branch state, Redis DB, database name, cleanup
  candidacy, compare URL, and doctor issues. The payload also carries a
  top-level `capacity` block (`floor`, `step`, `current`, `used`, `free`,
  `physical_max`) describing the elastic Redis band.
- `snapshot --write` writes the same registry to
  `/Users/alex/projects/.agents/worktree-registry.json` for conductor sessions,
  dashboards, and future automation. Set
  `AGENT_WORKTREE_REGISTRY=/tmp/worktree-registry.json` when a sandboxed
  session needs a scratch write instead of the shared projects registry.
- `cleanup` is a dry run. It prints clean worktree candidates whose branch is
  either contained in `origin/main` or has an empty final diff against
  `origin/main` after a squash merge.
- `cleanup --write` appends candidates to [`../maintenance/delete-later.md`](../maintenance/delete-later.md). It does not remove files, worktrees, branches, databases, Redis keys, or processes.
- `cleanup --reclaim` is the **scale-down-on-close normal flow**: a merged
  worktree self-releases its Redis slot the same way a stack scales down when it
  closes. The dry run (no `--yes`) lists only the worktrees that are SAFE to
  auto-remove — clean **and** either contained in `origin/main` or
  main-equivalent (the same `cleanup_ready?` criteria as `cleanup`) — and prints
  each candidate with its Redis DB. It never lists a dirty or unmerged worktree,
  and the candidate set is sourced from `.worktrees/*` only, so the primary
  checkout is never a candidate.
- `cleanup --reclaim --yes` runs the **same full teardown as `remove`** for each
  safe candidate (stop the stack, flush the stack's Redis DB, update the cleanup
  ledger, remove the Git worktree, delete the stale local branch), re-verifying
  each candidate under the worktree lock so one that turned dirty/unmerged in the
  interim is skipped. After the batch it shrinks the Redis band toward the floor
  (`maybe_scale_in`) and refreshes the registry once. Output names each reclaimed
  worktree, the freed Redis DB, and the resulting band size. Safe to re-run; with
  no candidates it prints a clear no-op message and changes nothing.
- `remove <app> <task-slug> --yes` is the approved deletion path after Mr.
  McRitchie or the conductor authorizes cleanup. It refuses dirty or
  non-equivalent worktrees, stops the stack, flushes the stack's Redis DB (so a
  reused DB number cannot inherit stale keys), updates the cleanup ledger, removes
  the Git worktree, deletes the stale local branch, shrinks the Redis band toward
  the floor when slots free up, and refreshes the registry.
- `scale status` prints the Redis band: floor, step, current band + DB range,
  used, free, and the physical ceiling (`databases` from Redis). `scale out` /
  `scale in` are manual nudges (respect floor and physical ceiling). `scale
  --provision [--yes]` raises the physical `databases` and restarts Redis once;
  see [Scale Note](#scale-note).

Deletion remains approval-gated:

1. Run `bin/agent-worktree cleanup <app>` to see candidates.
2. Confirm `bin/agent-worktree doctor <app>` has no dirty or unique-work
   warnings for the target.
3. After approval, run `bin/agent-worktree remove <app> <task-slug> --yes`.
4. Run `bin/qa-intake --refresh --apps <apps>` so the conductor view no longer
   reports the removed worktree.

## Squash-Merge Cleanup

GitHub squash merges do not preserve the feature branch SHA on `main`. After a
PR lands, a branch can appear behind `origin/main` even when all of its content
was merged. Do not rely on ahead/behind alone.

The launcher now treats an empty final diff against `origin/main` as a cleanup
candidate. Before removing a squash-merged worktree manually:

1. Pull the primary checkout so `origin/main` is current.
2. From the feature worktree, confirm the final diff is empty:

   ```bash
   git diff --stat origin/main..HEAD
   git diff --name-status origin/main..HEAD
   ```

3. If both commands are empty, prefer
   `bin/agent-worktree remove <app> <task-slug> --yes` after approval.
4. If the diff is not empty, do not delete. The branch contains work not
   represented on `main`; send it back through PR/QA or salvage deliberately.

## Rules

- Branch from current `origin/main`.
- One task branch per worktree.
- Never commit task work on the primary `main` checkout unless you are the
  explicit deploy owner for that repo.
- A feature branch is the backup and collaboration unit. `main` is the reviewed
  integration lane, not a place to rush code so it is not lost.
- Feature agents push their branch and open/prepare a PR. Avi or the designated
  release conductor owns merging to `main`.
- If the primary checkout is dirty, ahead, or moves while you are working, treat
  it as shared-floor drift. Do not fold those changes into your task silently.
  Report it and continue from the isolated worktree.
- Do not remove a worktree until its branch/PR status is known.
- Log stale worktrees in [`../maintenance/delete-later.md`](../maintenance/delete-later.md) before deleting them.

## Handoff Contract

A feature-agent handoff should include:

- McRitchie Studio task slug or task URL, current stage, and acceptance
  criteria status.
- App, task slug, branch, and worktree path.
- Local review URL and local inbox URL when a server was started.
- PR URL or the exact reason a PR was not opened.
- QA-intake status when available, but do not use `bin/qa-intake` as a
  substitute for the task-board record.
- Task conversation status: whether any `qa_feedback` remains open in practice,
  and the latest `handoff` note the feature agent added.
- Tests/checks run and their result.
- Files or behavior changed at a high level.
- The `bin/agent-worktree finish` result.
- Whether the branch is ready for Avi review, needs another agent, or needs
  release-conductor integration.

Do not leave Mr. McRitchie with "run these commands." Start the stack, prove the
URL, and name any blocker that truly needs owner action.

## Machine Registry

`bin/agent-worktree snapshot --write` is the local registry for scale. It does
not contain secrets and is safe to hand to another agent session as current
machine context.

Use it when:

- a QA or release conductor starts a shift
- multiple feature agents are active at once
- worktree ports, Redis DBs, or pidfiles appear inconsistent
- a dashboard or future supervisor needs a machine-readable queue

The registry is intentionally local under `/Users/alex/projects/.agents/`.
McRitchie Studio documents and owns the format, but the file itself reflects the
current machine and should not be treated as a Git-tracked source of truth.
If the agent runtime blocks writing to that directory, rerun the command with
filesystem approval or set `AGENT_WORKTREE_REGISTRY` to a writable scratch path.

## Ports

Worktree servers must use a non-primary port from the app's reserved range. See [`ports-and-processes.md`](ports-and-processes.md).

## Worktree Stack Requirements

Worktree tooling should make parallel stacks "just work" without user terminal chores.

Each worktree stack needs its own:

- App-range port (`3101`, `3102`, etc. for Turf Monster).
- Redis DB for Sidekiq and cache. The launcher allocates globally across generated stack env files from an elastic band starting at DB `9` (see [Scale Note](#scale-note)).
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

Redis capacity has two layers:

- **Physical capacity** is the Redis `databases` setting. It is fixed at Redis
  startup; changing it needs a restart. Stock Redis exposes `0-15` (16 DBs).
- **Soft band** is the slot range the launcher allocates from, starting at DB
  `9`. It is elastic and restart-free within the physical ceiling.

The band idles at **20 slots** (`FLOOR`) and changes by **10** (`STEP`):

- **Scale-out (auto):** when the band is full and physical room remains,
  `allocate_redis_db` grows the band by 10 (`scaled out: 20 -> 30 slots`) and
  retries. No restart. At the physical ceiling it aborts with guidance to run
  `cleanup` or `scale --provision`.
- **Scale-in (auto):** `remove`, `cleanup --write`, and `cleanup --reclaim --yes`
  drop the band by 10 (never below the floor, never stranding a still-used DB) as
  slots free up (`scaled in: 30 -> 20 slots`). No restart. `cleanup --reclaim
  --yes` is the hands-off scale-down-on-close path: it releases every safe
  candidate, then calls `maybe_scale_in` once for the batch.

The band size is persisted in `/Users/alex/projects/.agents/redis-capacity.json`
and band allocation + capacity mutation are guarded by a `flock` on
`/Users/alex/projects/.agents/agent-worktree.lock` so concurrent `new`/`up`
runs cannot collide.

Inspect the band with `bin/agent-worktree scale status`. To realize the full
20-slot floor you need physical `databases >= 29` (DB 9 band start + 20). The
band caps band hand-outs at the physical ceiling, so on stock Redis (16 DBs)
only DBs `9-15` are usable until you provision.

To raise physical capacity (one-time, target `databases 64`):

```bash
bin/agent-worktree scale --provision         # interactive confirm
bin/agent-worktree scale --provision --yes   # skip the prompt
```

This edits the brew `redis.conf` (`$(brew --prefix)/etc/redis.conf`, overridable
with `AGENT_REDIS_CONF`) and restarts Redis **exactly once**. It is idempotent
(no-op when `databases` is already at/above target). The restart **bounces every
running worktree stack** on `localhost:6379`, so it belongs to the QA/infra lane
during a quiet window, never mid-session while other stacks are live.

Overrides: `AGENT_REDIS_FLOOR`, `AGENT_REDIS_STEP`,
`AGENT_REDIS_PHYSICAL_TARGET`, and the legacy `AGENT_REDIS_MAX_DB` (pins the band
top explicitly). Do not set band overrides past what Redis actually serves.

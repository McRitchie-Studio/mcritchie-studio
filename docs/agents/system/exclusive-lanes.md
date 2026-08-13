# Exclusive Lanes

Most backend tasks run in parallel. Some touch shared state and must be serialized into a single-flight queue called a **lane**. This doc defines the pattern and the lanes that exist today.

## The principle

A task **requires a lane** when it modifies state that other concurrent tasks may depend on, where concurrent modification would cause: schema conflicts, dependency conflicts, deploy collisions, or non-deterministic test failures.

Lanes are about *correctness*, not resource limits.

## Lanes that exist today

| Lane | Flag | What triggers it | Concurrency |
|---|---|---|---|
| `backend_migration` | `tasks.requires_migration = true` | Any task that adds/modifies/removes a Rails migration, or modifies `db/schema.rb` | One Dev at a time |
| `release_conductor` | `tasks.metadata["devops"]["requires_release_conductor"] = true` | Gem publish, consumer lockfile adoption, production deploy, provider config, or env-var rollout | One conductor at a time per affected repo/app set |

Flag the `backend_migration` lane with `bin/task update <task-slug>
--requires-migration` and claim it with `bin/task migration-lane acquire
<task-slug>`. The `release_conductor` lane is claimed per-release by `bin/release`.

Don't add lanes pre-emptively. Add a lane only after a class of conflict has
bitten twice, or when an action has irreversible production/provider effects.

Candidates that *may* become lanes later: shared seed file changes, asset
pipeline config, cross-app fixture/data contracts. Wait for them to actually
hurt before formalizing.

## How `backend_migration` works

There are two paths into the lane.

### Pre-flagging (when known at sizing time)

Avi flags it during refinement if the spec obviously needs a schema change —
`bin/task create … --requires-migration`, or `bin/task update <task-slug>
--requires-migration` on an existing ticket. The Dev then takes the lane at task
start with `bin/task migration-lane acquire <task-slug>`.

### Self-flagging (the common case)

Avi often *can't* know up front. **Carl (and any backend Dev) is responsible for self-recognizing the moment.**

> **Stop rule:** before running `bin/rails g migration`, before creating a file in `db/migrate/`, before modifying `db/schema.rb` — stop. Run `bin/task migration-lane acquire <task-slug>`. Exit 0 = proceed; exit 10 = queue behind the holder it names.

If you started a task tagged `requires_migration: false` and discover you need one:

```bash
bin/task update <task-slug> --requires-migration   # self-flag
bin/task migration-lane acquire <task-slug>        # then take the lane
```

*Then* write the migration file. Never smuggle a migration in unflagged.

Self-flagging is not a failure — it's the system working. Avi can't see every implementation detail. The Dev who's closest to the code catches what refinement missed.

### Acquiring the lane

```bash
bin/task migration-lane status                     # who holds it, if anyone
bin/task migration-lane acquire <task-slug>        # take it
bin/task migration-lane release                    # hand it back
```

`acquire` exits **0** when the lane is yours — proceed and write the migration.

It exits **10** when the lane is held. That is a normal answer, not an error: the
refusal names the holding agent and task, so chat them for an ETA and pick up a
non-migration task in the meantime. Do not loop on it. There is no `lane_queued`
task status (an earlier cut of this doc claimed one; `Task::STAGES` has never had
it) — your task simply stays where it is while you wait.

The optional `<task-slug>` records *which* task holds the lane, which is what
lets a refused Dev know whom to ask. `status` is a plain read and works from any
shell; `acquire`/`release` need an agent session, because a lease nobody can
name is a lane nobody can free.

### Releasing

Release explicitly on the way out — `bin/task migration-lane release` — on task
`shipped`/`blocked`/`archived` alike. Releasing a lane you never took is a
harmless no-op, so the call is safe on every exit path, and only the holder can
free it (a queued Dev cannot yank it out from under live work).

A claim you never release lapses on its own after **4 hours**, so a crashed
holder frees the lane the same working day instead of wedging it forever. The
lease is the backstop; the explicit release is the manners.

### What backs the lane

A row in `migration_lane_claims` — one per lane, under a unique index, taken with
`SELECT … FOR UPDATE` — claimed through `MigrationLaneClaim` and served by
`/api/v1/migration_lane`.

This doc used to prescribe `pg_try_advisory_lock(hashtext('backend_migration'))`
directly, and that recipe never worked for an agent. `bin/task` is an HTTP client
with no database connection, so there was no session to hold a session-scoped
lock; run over the API instead, the lock rides a **pooled** connection past the
response and is re-entrant on it, meaning two acquires served by one connection
would **both** be granted. A lane that grants twice is worse than no lane, so the
claim is durable state and the exclusion is proved against real concurrent
connections in `test/integration/migration_lane_exclusion_race_test.rb`.

Enforcement is **cooperative**, like the rest of the studio: the lane refuses the
second acquirer, but nothing blocks a migration file from being written by
someone who never asked. `bin/dor-check` does not verify lane ownership.

## Carl's captaincy

Carl (the **role**, not any specific instance) is the **coordination authority** for the `backend_migration` lane:

- During sizing, Avi consults Carl on whether a task likely needs migration
- When the lane is contested, Carl prioritizes the queue (which migration goes first)
- When migration density gets high (>30% of in-flight backend tickets), Carl flags to Avi to batch

Any Carl *instance* can hold the lane at a given time. Captaincy is about authority, not exclusivity.

## Migration batching

When several upcoming tickets each need small schema changes, Avi (with Carl's input) batches them into one migration task. Three small column adds in one migration is better than three sequential migration tickets each fighting the lane.

## Release conductor lane

The `release_conductor` lane exists because shared releases can otherwise overwrite
or strand other agents' work. Typical examples:

- `studio-engine` version bump and RubyGems publish
- consumer app `Gemfile.lock` updates after a gem release
- Heroku deploys and post-deploy migrations
- SES/Resend/provider env-var changes
- callback URL or domain configuration changes

Keep rollouts flat: do not create parent/child task trees for ordinary work.
Mark only the tasks requiring production, gem publish, provider config, or
env-var work with `requires_release_conductor` — that flag is what claims this
lane, and it is the only thing to set.

Do **not** try to group tasks by writing `metadata["devops"]["release_slug"]`.
That key is retired and a write to it is refused with a 422: `release_slug` is a
top-level column the sweep attaches (`Release#record_members`) when a PR lands on
the `release` branch, so membership is a result, not an input. Tasks that must
ship in a given order record it in `dependencies`, which `Release::Ordering`
enforces.

The conductor must:

1. Pull latest `main` in every affected repo.
2. Confirm no feature agent is relying on an unpublished local path or branch.
3. Run the release checks for the shared artifact.
4. Publish/deploy only with explicit approval.
5. Update consumers and verify local/production URLs.
6. Report the commit SHAs, release version, deploy target, and verification.

Feature agents can recommend entering the lane, but they do not run release
actions unless Mr. McRitchie assigns that lane to the session.

## Adding a new lane

A new lane is a meaningful addition to system contention. Don't add one without:

1. **Two prior real incidents** that this lane would have prevented
2. **Carl's sign-off** for backend lanes (or the relevant role's sign-off for theirs)
3. **An update to this doc** with the lane's flag, trigger, and acquisition recipe

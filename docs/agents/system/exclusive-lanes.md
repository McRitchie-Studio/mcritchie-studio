# Exclusive Lanes

Most backend tasks run in parallel. Some touch shared state and must be serialized into a single-flight queue called a **lane**. This doc defines the pattern and the lanes that exist today.

## The principle

A task **requires a lane** when it modifies state that other concurrent tasks may depend on, where concurrent modification would cause: schema conflicts, dependency conflicts, deploy collisions, or non-deterministic test failures.

Lanes are about *correctness*, not resource limits.

## Lanes that exist today

| Lane | Flag | What triggers it | Concurrency |
|---|---|---|---|
| `backend_migration` | `tasks.requires_migration = true` | Any task that adds/modifies/removes a Rails migration, or modifies `db/schema.rb` | One Dev at a time |
| `release_train` | `tasks.metadata["devops"]["requires_release_conductor"] = true` | Gem publish, consumer lockfile adoption, production deploy, provider config, or env-var rollout | One conductor at a time per affected repo/app set |

Don't add lanes pre-emptively. Add a lane only after a class of conflict has
bitten twice, or when an action has irreversible production/provider effects.

Candidates that *may* become lanes later: shared seed file changes, asset
pipeline config, cross-app fixture/data contracts. Wait for them to actually
hurt before formalizing.

## How `backend_migration` works

There are two paths into the lane.

### Pre-flagging (when known at sizing time)

Avi sets `requires_migration: true` during refinement if the spec obviously needs a schema change. The Dev acquires the lane at task start.

### Self-flagging (the common case)

Avi often *can't* know up front. **Carl (and any backend Dev) is responsible for self-recognizing the moment.**

> **Stop rule:** before running `bin/rails g migration`, before creating a file in `db/migrate/`, before modifying `db/schema.rb` — stop. Check the lane. Acquire or queue.

If you started a task tagged `requires_migration: false` and discover you need one: update the flag, acquire the lane, *then* write the migration file. Never smuggle a migration in unflagged.

Self-flagging is not a failure — it's the system working. Avi can't see every implementation detail. The Dev who's closest to the code catches what refinement missed.

### Acquiring the lane

```ruby
ApplicationRecord.connection.execute(
  "SELECT pg_try_advisory_lock(hashtext('backend_migration'))"
)
```

If the query returns `true`: proceed.

If `false`: the lane is held. Your task transitions to `lane_queued` status. Chat the current holder asking ETA. Pick up a non-migration task in the meantime.

### Releasing

On task `shipped`/`blocked`/`archived`, advisory locks release automatically when
the session closes. Belt-and-suspenders: also call
`pg_advisory_unlock(hashtext('backend_migration'))` explicitly on the transition
out.

## Carl's captaincy

Carl (the **role**, not any specific instance) is the **coordination authority** for the `backend_migration` lane:

- During sizing, Avi consults Carl on whether a task likely needs migration
- When the lane is contested, Carl prioritizes the queue (which migration goes first)
- When migration density gets high (>30% of in-flight backend tickets), Carl flags to Avi to batch

Any Carl *instance* can hold the lane at a given time. Captaincy is about authority, not exclusivity.

## Migration batching

When several upcoming tickets each need small schema changes, Avi (with Carl's input) batches them into one migration task. Three small column adds in one migration is better than three sequential migration tickets each fighting the lane.

## Release train lane

The `release_train` lane exists because shared releases can otherwise overwrite
or strand other agents' work. Typical examples:

- `studio-engine` version bump and RubyGems publish
- consumer app `Gemfile.lock` updates after a gem release
- Heroku deploys and post-deploy migrations
- SES/Resend/provider env-var changes
- callback URL or domain configuration changes

Release trains are flat task groupings. Do not create parent/child task trees
for ordinary rollouts. Put the same `metadata["devops"]["release_train"]` value
on each task that should be promoted together, and mark only tasks requiring
production, gem publish, provider config, or env-var work with
`requires_release_conductor`.

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

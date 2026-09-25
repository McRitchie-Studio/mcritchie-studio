# Exclusive Lanes

Most backend tasks run in parallel. Some touch shared state and must be serialized into a single-flight queue called a **lane**. This doc defines the pattern and the lanes that exist today.

## The principle

A task **requires a lane** when it modifies state that other concurrent tasks may depend on, where concurrent modification would cause: schema conflicts, dependency conflicts, deploy collisions, or non-deterministic test failures.

Lanes are about *correctness*, not resource limits.

## Lanes that exist today

| Lane | Flag | What triggers it | Concurrency |
|---|---|---|---|
| `release_conductor` | `tasks.metadata["devops"]["requires_release_conductor"] = true` | Gem publish, consumer lockfile adoption, production deploy, provider config, or env-var rollout | One conductor at a time per affected repo/app set |

The `release_conductor` lane is claimed per-release by `bin/release`.

Don't add lanes pre-emptively. Add a lane only after a class of conflict has
bitten twice, or when an action has irreversible production/provider effects.

Candidates that *may* become lanes later: shared seed file changes, asset
pipeline config, cross-app fixture/data contracts. Wait for them to actually
hurt before formalizing.

## Migrations take no lane

The `backend_migration` lane (a `migration_lane_claims` row claimed with
`bin/task migration-lane acquire`) was deleted in devops-v3 piece 4b-ii-b. The
real protection is the duplicate-migration collision check that `bin/dor-check`
and `bin/ship` run (`bin/lib/migration_collision.rb`): two open PRs cannot land
migrations that collide.

`tasks.requires_migration` stays as a plain flag. Set it when a task needs a
schema change — `bin/task create … --requires-migration`, or `bin/task update
<task-slug> --requires-migration` the moment you discover one mid-build — so
review and release can see it. It claims nothing.

When several upcoming tickets each need small schema changes, batching them into
one migration task is still cheaper than several sequential ones.

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
actions unless Alex assigns that lane to the session.

## Adding a new lane

A new lane is a meaningful addition to system contention. Don't add one without:

1. **Two prior real incidents** that this lane would have prevented
2. **Carl's sign-off** for backend lanes (or the relevant role's sign-off for theirs)
3. **An update to this doc** with the lane's flag, trigger, and acquisition recipe

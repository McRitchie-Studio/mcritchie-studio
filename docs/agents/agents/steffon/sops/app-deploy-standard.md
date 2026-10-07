# App Deploy Standard
<!-- registry: single-use apps: profile, contract, `bin/register-app` -->

## Status: Active

This is Steffon's `app-deploy-standard` SOP: how a **single-use app** (a family
site, a showcase rebuild, a client demo) comes to ship through the release
pipeline. It exists because every such app used to be registered by hand in
several files, each re-explaining the same decisions, and one of them
(`moms-app`) never got registered at all and was deployed by hand for months.
Alex asked on 2026-09-28 for one standard every single-use app follows.

The standard is a **profile**: a named deploy shape defined once in
`config/app_profiles.yml`, applied to an app by `bin/register-app`, which checks
the app against the profile's contract and generates its registry entry.

## What this act is NOT

- **It never deploys.** Registration makes an app *eligible* to ride a release;
  the release ships it (`qa-release`, then `production-deploy`).
- **It never creates the app.** Repo, Heroku app, domain and CI exist first; this
  act checks them.
- **It is not for the hub, Turf Monster or a gem.** Those carry bespoke entries
  in `config/release_repos.yml` on purpose.

## The profile: `standalone-heroku`

One Rails app on its own Heroku app (company account), released through the
three-rung ladder (`accepted` → `release` → `main`), shipped by `git push` to
Heroku, gated by its own CI, **with no QA copy**.

| Registry key | Value |
|---|---|
| `ladder` | `three-rung` |
| `prod_deploy` | `git_push_heroku`, `https://git.heroku.com/<heroku-app>.git`, branch `main`, the app's `smoke_url` |
| `test_cmd` | the app's CI `test` job command, verbatim (the last gate before production) |
| `qa_evidence` | `exempt` |

**The QA decision is the profile's, taken once.** On 2026-09-28 Alex was asked
"Confirm the fleet-wide QA rule: standalone apps ship without a QA copy unless
there is a free tier" and answered "Yes to both" (the other half: build this
standard now). The exact text lives in `config/app_profiles.yml`;
`test/models/release/repos_test.rb` pins the answer verbatim and requires the
question to be recorded. An app that needs a QA copy is not this shape: it gets a
`config/qa_environments.yml` entry and a `qa_test_cmd`, and drops `profile:`.

**The contract** an app must meet before registration (checked live):

1. The repo is `McRitchie-Studio/<slug>`, cloned at `/Users/alex/projects/<slug>`.
2. `origin` has `main`, `accepted` and `release`.
3. `.github/workflows/ci.yml` has a `test` job with one `bin/rails …` step, and a
   workflow named `CI` builds pushes to `accepted` and `release` with no path
   filter or `branches-ignore`. That second half is `bin/release prepare`'s own
   guard (`Release::AcceptedCertification`), reused by the contract, so an app
   the contract passes is not refused by that guard at its first release (as
   `moms-app` was on 2026-09-28). The contract checks `release` too, with the
   same rule. Prepare's other refusals, such as red CI or a merge conflict, can
   still stop a release.
4. `.gitignore` ignores `.worktrees/`.
5. The Heroku app exists and `<smoke_url>/up` answers 200.
6. An app with a database (`gem "pg"`) runs `bin/rails db:migrate` in its
   Procfile `release:` phase.
7. The hub's `config/satellites.yml` reserves the app a 100-port block.
   Desks take their ports from it, so without a row `bin/agent-worktree`
   refuses the app. Reserve one in the registration task:
   `bin/register-satellite --list`, then
   `--slug <slug> --port <next open> --status reserved --write`, and add the
   slug to the satellite row of the desk table in
   [`fast-lane.md`](../../../modules/fast-lane.md) (a docs guard checks it).

## Entry

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Workflow --reason "app-deploy-standard <slug>"
```

Registration is a diff to `config/release_repos.yml`, so it runs inside a task
(`bin/task begin … --repo mcritchie-studio --shape backend`), in that task's desk.

## 1. Check the contract

From the desk:

```bash
SLUG=<slug>
bin/register-app "$SLUG" --heroku-app <heroku-app> --smoke-url https://<production-host>
```

It prints one PASS or FAIL per contract line, each FAIL with its remedy, then the
entry it would write. It also reports whether the app consumes `studio-engine`
and at which version.

The file checks (CI job, `.gitignore`, `Gemfile`, `Procfile`) read the app at
`origin/accepted`, the branch a release ships, never the primary checkout on
disk, so a fix counts only once it is **merged to the app's `accepted`**. Fix an
app-side FAIL in the app's own task and merge it, then re-run; the `fetch` check
fails if the app's remote cannot be fetched, rather than letting the rest read a
stale branch. The glyph FAIL is the exception: it is fixed **in the hub**, in this
registration task. Run the command from a hub desk: the fixed-path tooling copy
has no `app/helpers`, so there it reports the glyph check as FAIL. The usual
ones:

- **branches**: `git -C /Users/alex/projects/$SLUG push origin main:refs/heads/accepted main:refs/heads/release`
- **.worktrees ignored**: add `.worktrees/` to the app's `.gitignore`.
- **ci on release rungs**: set `push: branches: [ main, release, accepted ]` in
  the `CI` workflow, with no `paths`, `paths-ignore` or `branches-ignore`.
- **smoke /up**: route `get "up" => "rails/health#show"`.
- **hub badge glyph** (checked in the hub, not the app): add
  `"<slug>" => "<emoji>"` to `APP_EMOJIS` in `app/helpers/application_helper.rb`
  in the same task as the registration. The board draws a badge per registry
  repo, and CI fails a repo without one.

## 2. Mind the engine gap

If the app consumes `studio-engine`, the first release that carries both this app
and an engine publish bumps the app's lock to the published version
(`bin/release.rb#bump_consumer_locks_for_qa`), migrations included. A small gap is
routine. A large one (`moms-app` was on 0.32 when the engine was on 0.77) should be
closed deliberately first, in the app's own task, with its suite green.

A new app adopts the engine and renders its site footer from the first build
([new-app onboarding § 7](../../../system/new-app-onboarding-sop.md#7-build-conventions)).

## 3. Register

```bash
bin/register-app "$SLUG" --heroku-app <heroku-app> --smoke-url https://<production-host> --write
```

It refuses unless every check passes and the slug is not registered yet. It
appends the generated entry and reads it back as the profile. Then run the
registry guard and ship the task:

```bash
bin/rails test test/models/release/repos_test.rb
```

The guard fails if any entry declaring a profile differs from the profile's
expansion, so a later hand edit cannot quietly change a deploy.

## 4. First release

From here the app is an ordinary release member: feature PRs target `accepted`,
Avi's `qa-release` promotes (no QA deploy, by the profile's decision), and
Steffon's `production-deploy` ships it by `git push` and smokes `<smoke_url>/up`.
Anything already on the app's `accepted` rides the first release, so read
`git log origin/main..origin/accepted` in the app before it does.

## 5. Record

- Keep the app's `config/satellites.yml` row at `status: reserved` (contract
  item 7). It holds the desk ports; only `status: active` lists an app in the
  hub's link tree (`Satellite.active`).
- Close the activity:
  `bin/agent-activity end --outcome "registered <slug> on standalone-heroku"`.

## Changing or leaving the profile

- **To change every app of the shape** (say, a new deploy branch): edit the
  profile in `config/app_profiles.yml`, edit each app's entry to match
  (`bin/register-app` only adds a new slug), and let the guard prove them equal.
- **To give one app a QA copy**, or any bespoke key: remove its `profile:` line
  and edit its entry by hand. It is then a bespoke entry again, and the
  QA-exemption guard requires either QA evidence or a cited decision.

## Background — not needed to execute

Why the profile is generated into `release_repos.yml` rather than read at run
time (about nine independent readers of that file): the header of
`config/app_profiles.yml`. How the release reads each key: the long header of
`config/release_repos.yml`. The onboarding checklist that precedes this act:
[`../../../system/new-app-onboarding-sop.md`](../../../system/new-app-onboarding-sop.md).

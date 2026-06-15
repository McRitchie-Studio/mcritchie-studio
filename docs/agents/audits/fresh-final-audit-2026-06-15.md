# Fresh Final Audit Pass

Date: 2026-06-15
Scope: `/Users/alex/projects` managed repos, root agent entrypoint, active
runbooks, shared engine docs, and production-adjacent runtime configuration.

## Baseline

Primary managed repos were on `main` before this pass:

| Repo | Baseline commit | State |
|---|---:|---|
| `mcritchie-studio` | `7a9baad` | Clean before audit edits |
| `turf-monster` | `4333f90` | Clean before audit edits |
| `studio-engine` | `0afb2ed` | Clean before audit edits |
| `solana-studio` | `b40bf9b` | Clean |
| `turf-vault` | `ebd9f4e` | Clean before audit edits |

The root `/Users/alex/projects` directory is down to the expected visible
working set: generated `AGENTS.md`, `.claude`, and the project checkouts. No
root `CLAUDE.md` or `CODEX.md` adapter is present by design.

Worktree lifecycle state:

```text
bin/agent-worktree doctor
doctor: no worktree lifecycle issues found
```

Managed app registry:

```text
mcritchie-studio   active    3000-3099   McRitchie Studio
turf-monster       active    3100-3199   Turf Monster
tax-studio         planned   3200-3299   Tax Studio
Next open range: 3300-3399
```

## Changes Made In This Pass

### Auth Hardening

The active apps and engine onboarding docs now keep OmniAuth request phase
POST-only:

- `mcritchie-studio/config/initializers/omniauth.rb`
- `turf-monster/config/initializers/omniauth.rb`
- `studio-engine/docs/GOOGLE_AUTH_SETUP.md`
- `studio-engine/docs/NEW_APP_SETUP.md`

Turf Monster's popup Google flow previously depended on GET being allowed.
`GET /auth/google_popup` now renders an auto-submitting POST form to
`/auth/google_oauth2`, preserving the popup UX while closing the request-phase
CSRF surface called out by older OPSEC audits.

### Active Doc Drift

Stale active docs were corrected:

- McRitchie email docs no longer say consumer apps still need the current
  `studio-engine` release before shared mail proof. The current state is
  `studio-engine 0.5.9` adopted, with McRitchie production now using Solid
  Queue for durable jobs.
- Turf email docs now point at release `v92` for the current Resend fallback
  and Heroku-26 production proof.
- Turf runbook contest lifecycle language now matches the actual `pending`,
  `open`, `settled` app statuses and the derived lock model.
- Studio Engine release docs now use `0.5.9` as the current consumer adoption
  target for shared email/local inbox/banner behavior.
- Turf Vault README now explains that on-chain `Locked` is vestigial and lock
  enforcement is derived from timestamps.

## Findings

### 1. McRitchie production email durability is now worker-grade

McRitchie Studio records durable `Studio::EmailDelivery` rows and production
now uses Solid Queue backed by the primary Postgres database. A `worker` dyno
runs `bin/jobs`, so enqueued mail/auth work survives web dyno restarts.

Operator check: keep at least one `worker` dyno scaled on Heroku. If a provider
outage leaves unsent email rows behind, replay them with
`Studio::EmailDelivery.resend_unsent!`.

### 2. SES is architecturally ready but still externally blocked

The sender convention is settled:

- Transactional: `team@turfmonster.media`, `team@mcritchie.studio`
- Marketing: `alex@turfmonster.media`, `alex@mcritchie.studio`
- Temporary fallback: Resend through
  `McRitchie Studio <team@mcritchie.studio>`

Both SES domains are verified with DKIM success. The blocker is SES production
access in `us-east-2`; until AWS removes sandbox mode, Resend remains the
production/presetup fallback.

### 3. Heroku platform hygiene is complete for the active apps

McRitchie Studio is pinned to Ruby `3.3.11` and Node `22.x`, deploys with
`heroku/nodejs` before `heroku/ruby`, and is live on Heroku-26 at release
`v58` / commit `4a5c265`. Web and `worker=1` dynos are up, and
`https://app.mcritchie.studio/up` returns `200`.

Turf Monster was rebuilt with an empty operational commit so the uncommitted
wallet/CDP local WIP stayed untouched. Release `v92` / commit `84ba917` is live
on Heroku-26 with `heroku/nodejs` before `heroku/ruby`, Node `22.22.3`, Ruby
`3.3.11`, web and Sidekiq worker dynos up, and
`https://app.turfmonster.media/up` returns `200`.

The only remaining platform-adjacent warning is the familiar
Browserslist/caniuse-lite notice emitted by the current Tailwind build chain.
`npx update-browserslist-db@latest` was run, so treat the residual warning as a
future `tailwindcss-rails` major-version maintenance item rather than a
Heroku-26 blocker.

### 4. Active docs are now cleaner than historical docs

The active README/RUNBOOK/topic docs are the right entrypoint. Older audit files
under `docs/agents/system/` and historical Turf docs still contain stale
references by design; they should remain archive-only unless a finding is
promoted into an active module or app runbook.

### 5. Rolio is still unmanaged

`rolio` exists locally but is not in the managed app registry. If it becomes a
real satellite, assign the next range (`3300-3399`), give it a primary port
(`3300`), and onboard it through the registry/recovery docs.

## Recommended Next Moves

1. Deploy McRitchie Studio's Solid Queue release, confirm `worker=1`, and prove
   a magic-link send completes through the durable worker path.
2. Finish SES production access, stage SMTP creds, then run provider smoke and
   real magic-link smoke for both domains.
3. Plan a dedicated frontend dependency window for the residual
   Tailwind/Browserslist warning.

## Verification For This Pass

Passed during this pass:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/install-agent-docs check
bin/agent-worktree doctor
bin/register-satellite --list
bin/rails test test/controllers/sessions_controller_test.rb

cd /Users/alex/projects/turf-monster
bin/rails test test/controllers/omniauth_callbacks_controller_test.rb
bin/rails test test/integration/reference_attribution_test.rb
```

Results:

- `bin/install-agent-docs check`: OK, generated root `AGENTS.md` matches the
  McRitchie Studio source doc.
- `bin/agent-worktree doctor`: no worktree lifecycle issues found.
- `bin/register-satellite --list`: expected active `3000-3099`, active
  `3100-3199`, planned `3200-3299`, next open `3300-3399`.
- Turf Monster OAuth/reference tests: `14 runs, 53 assertions, 0 failures`.
- McRitchie Studio sessions test: `4 runs, 14 assertions, 0 failures`.
- McRitchie Studio Solid Queue follow-up: full Rails suite passed after moving
  production to Solid Queue: `577 runs, 1591 assertions, 0 failures, 4 skips`.
- McRitchie Studio Heroku platform follow-up: release `v58` on Heroku-26,
  Node/Ruby buildpacks ordered correctly, web and worker dynos up, `/up` `200`.
- Turf Monster Heroku platform follow-up: release `v92` on Heroku-26, Node/Ruby
  buildpacks ordered correctly, web and worker dynos up, `/up` `200`. The local
  checkout still contains uncommitted wallet/CDP/contest WIP that was not part
  of this operational rebuild.
- Stale-string scan found the old OmniAuth GET guidance only in historical
  audit files, not active runtime docs.

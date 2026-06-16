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
chain-ops          planned   3300-3399   Chain Ops
Next open range: 3400-3499
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
- Turf email docs now point at release `v93` for the current Resend fallback
  and Heroku-26 production proof.
- Turf runbook contest lifecycle language now matches the actual `pending`,
  `open`, `settled` app statuses and the derived lock model.
- Studio Engine release docs now use `0.5.9` as the current consumer adoption
  target for shared email/local inbox/banner behavior.
- Turf Vault README now explains that on-chain `Locked` is vestigial and lock
  enforcement is derived from timestamps.

### Root-Domain Launch And QA Stabilization

McRitchie Studio now uses `https://mcritchie.studio` as the canonical production
host. `https://app.mcritchie.studio` remains a legacy Rails alias, and the
previous Squarespace site is archived at `https://v1.mcritchie.studio`.

QA servers are provisioned and healthy:

- McRitchie Studio QA: `https://qa.mcritchie.studio`
- Turf Monster QA: `https://qa.turfmonster.media`

The launch state is recorded in `docs/agents/modules/deployment.md` and
`docs/topics/deployment.md`.

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

### 3. Heroku platform hygiene and McRitchie root launch are complete

McRitchie Studio is pinned to Ruby `3.3.11` and Node `22.x`, deploys with
`heroku/nodejs` before `heroku/ruby`, and is live on Heroku-26 at release
`v63` / commit `4831ebcd`. Web and `worker=1` dynos are up. The canonical
root, `www`, legacy app host, and Heroku fallback all return `200` on `/up`.
Heroku ACM has issued certificates for `mcritchie.studio`,
`www.mcritchie.studio`, and `app.mcritchie.studio`.

The old Squarespace site is now available at `https://v1.mcritchie.studio`.
It is connected as the Squarespace primary domain, has the Squarespace `www`
prefix disabled, and returns `200`.

Turf Monster first received an empty operational rebuild to apply Heroku-26
without folding uncommitted local WIP into the stack migration. Steffon's
follow-up hardening commit was then tested and deployed. Release `v93` / commit
`37ca6ea` is live on Heroku-26 with `heroku/nodejs` before `heroku/ruby`, Node
`22.22.3`, Ruby `3.3.11`, web and Sidekiq worker dynos up, and
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
real satellite, assign the next open range (`3400-3499`), give it a primary port
(`3400`), and onboard it through the registry/recovery docs.

## Recommended Next Moves

1. Finish SES production access, stage SMTP creds, then run provider smoke and
   real magic-link smoke for both domains. Keep `MAIL_TRANSPORT` unset until
   that smoke passes.
2. Plan a dedicated frontend dependency window for the residual
   Tailwind/Browserslist warning. Both apps currently use
   `tailwindcss-rails 2.7.9` through `studio-engine 0.5.9`; RubyGems currently
   lists `tailwindcss-rails 4.4.0`, so this is a major-version visual/build
   upgrade rather than a patch bump.
3. Review the active parallel-session worktree queue before deleting anything.
   Several worktrees are intentionally present while feature agents run in
   parallel; do not clean them unless the owning branch is merged or explicitly
   abandoned.

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
- McRitchie Studio Heroku platform follow-up: release `v59` on Heroku-26,
  Node/Ruby buildpacks ordered correctly, web and worker dynos up, `/up` `200`.
- McRitchie Studio root-domain follow-up, 2026-06-15: release `v63` /
  `4831ebcd` is live with `APP_HOST=mcritchie.studio`,
  `MAILER_HOST=mcritchie.studio`, and aliases for `app`, `www`, and the Heroku
  fallback host. Public DNS points root and `www` to Heroku and `v1` to
  Squarespace. `/up` returns `200` on `mcritchie.studio`,
  `www.mcritchie.studio`, and `app.mcritchie.studio`; `v1.mcritchie.studio`
  returns `200` from Squarespace. A production magic-link POST for
  `alex@mcritchie.studio` returned `{"success":true}`.
- QA infrastructure follow-up, 2026-06-15: `mcritchie-studio-qa` and
  `turf-monster-qa` are provisioned, have running web and worker dynos, custom
  domains `qa.mcritchie.studio` / `qa.turfmonster.media`, and `/up` returns
  `200` on both QA URLs.
- Stabilization closeout follow-up, 2026-06-15: a fresh
  `bin/agent-worktree doctor` reports a cleanup queue rather than a clean
  lifecycle state: merged clean worktrees, stale pidfiles, missing per-worktree
  DBs, and Redis DB indexes above the stock Redis `0-15` range. This is not a
  production blocker, but it is the next DevOps hygiene task. Do not delete
  these worktrees during parallel feature work without confirming ownership or
  abandonment.
- Turf Monster Heroku platform follow-up: release `v93` on Heroku-26, Node/Ruby
  buildpacks ordered correctly, web and worker dynos up, `/up` `200`. Focused
  CDP/contest/vault tests passed for the hardening commit:
  `148 runs, 647 assertions, 0 failures`.
- SES proof credential follow-up, 2026-06-15: `SES_AWS_ACCESS_KEY_ID` /
  `SES_AWS_SECRET_ACCESS_KEY` are staged on both Heroku apps from
  `agent.aws.mcritchie-ses`. Live Heroku `ses:check` on both apps now uses
  `CredentialSource=SES_AWS_ACCESS_KEY_ID` and returns `HTTP 200` from SES with
  `SendingEnabled=true`, `ProductionAccessEnabled=false`, and
  `Enforcement=HEALTHY`. `MAIL_TRANSPORT` is unset on both apps, so Resend
  fallback remains active.
- SES identity proof, 2026-06-15: a direct SES v2 identity-list call with the
  same credentials reports `mcritchie.studio` and `turfmonster.media` as
  `VerificationStatus=SUCCESS` and `SendingEnabled=true`. The current released
  helper can still render those list rows as `pending` because it reads the
  older `VerifiedForSendingStatus` field.
- Tailwind proof, 2026-06-15: both apps are on `tailwindcss-rails 2.7.9`
  through `studio-engine 0.5.9`; RubyGems lists `4.4.0`, making the residual
  Browserslist warning a deliberate major-version upgrade window.
- Stale-string scan found the old OmniAuth GET guidance only in historical
  audit files, not active runtime docs.

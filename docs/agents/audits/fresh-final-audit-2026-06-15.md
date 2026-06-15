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
  `studio-engine 0.5.9` adopted, with McRitchie production still using
  `:async` jobs until a worker backend is added.
- Turf email docs now point at release `v90` for the current Resend fallback
  production proof.
- Turf runbook contest lifecycle language now matches the actual `pending`,
  `open`, `settled` app statuses and the derived lock model.
- Studio Engine release docs now use `0.5.9` as the current consumer adoption
  target for shared email/local inbox/banner behavior.
- Turf Vault README now explains that on-chain `Locked` is vestigial and lock
  enforcement is derived from timestamps.

## Findings

### 1. McRitchie production email durability is not yet worker-grade

McRitchie Studio records durable `Studio::EmailDelivery` rows, but production
still uses Rails `:async` jobs. A dyno restart can drop an enqueued send even
though the intent row remains recoverable via `Studio::EmailDelivery.resend_unsent!`.

Decision: move McRitchie Studio to a durable production job backend before
using it for heavier broadcasts, product updates, or any auth flow where manual
replay is an unacceptable recovery path. Solid Queue or Sidekiq are both viable;
Turf already runs Sidekiq.

### 2. SES is architecturally ready but still externally blocked

The sender convention is settled:

- Transactional: `team@turfmonster.media`, `team@mcritchie.studio`
- Marketing: `alex@turfmonster.media`, `alex@mcritchie.studio`
- Temporary fallback: Resend through
  `McRitchie Studio <team@mcritchie.studio>`

Both SES domains are verified with DKIM success. The blocker is SES production
access in `us-east-2`; until AWS removes sandbox mode, Resend remains the
production/presetup fallback.

### 3. Platform hygiene remains a planned maintenance item

Turf Monster release `v90` is healthy on Heroku-24 with Node `22.x`. The build
logs still leave two routine follow-ups:

- Heroku-26 readiness window.
- Browserslist/caniuse-lite refresh during frontend dependency maintenance.

Neither blocks the current production baseline.

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

1. Add a durable job backend to McRitchie Studio production and prove a
   magic-link send survives process restart/replay.
2. Finish SES production access, stage SMTP creds, then run provider smoke and
   real magic-link smoke for both domains.
3. Run a small platform hygiene window: Heroku-26 readiness plus
   Browserslist/caniuse-lite refresh.

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
- Stale-string scan found the old OmniAuth GET guidance only in historical
  audit files, not active runtime docs.

# Broader Ecosystem Audit

Date: 2026-06-14
Scope: `/Users/alex/projects` primary checkouts plus generated root agent docs.
Mode: read-heavy architecture and documentation audit. No product-code refactor.

Closeout: the final pass is recorded in
[`final-closeout-2026-06-14.md`](final-closeout-2026-06-14.md). The cleanup is
now in maintenance mode; salvage/deletion decisions are complete, production
email fallback has been proved, Turf Monster is deployed from the cleaned
baseline, and the remaining items are SES production access plus normal drift
maintenance.

## Executive Summary

The ecosystem is in a materially better place than the first pass. `AGENTS.md`
is the right LLM-neutral entrypoint, `mcritchie-studio` is correctly acting as
the documentation and bootstrap anchor, the primary apps are clean on `main`,
shared auth/email primitives now live in `studio-engine 0.5.9`, local email
capture exists for worktree stacks, production fallback mail sends through the
verified `mcritchie.studio` Resend domain, and `bin/agent-worktree` can now
diagnose worktree lifecycle drift without deleting anything.

The highest remaining risk is not missing infrastructure. It is trust in the
instructions that agents read first. Several active docs and all app
`CLAUDE.md` files still contain stale version, auth, port, or workflow facts.
Some active docs still reference `CLAUDE.md` for details even though those files
are now explicitly legacy migration context.

The code architecture direction is sound: keep shared mechanics in
`studio-engine`, keep Turf Monster's product-specific game/money/Solana logic in
Turf, keep live chain identity in Turf Vault, and keep cross-repo agent practice
in McRitchie Studio. The next work should remove contradictory docs and shrink
app-specific overrides where the engine already owns the generic behavior.

## Audit Baseline

Primary clean checkouts at audit time:

- `mcritchie-studio`
- `turf-monster`
- `studio-engine`

Primary checkouts with pre-existing local user work:

- `turf-vault`: at audit time, untracked `docs/SECURITY_AUDIT_2026_05_31.md`
  and `docs/turf-vault-deploy-cost.html`; status 2026-06-14: both are tracked.
- `solana-studio`: modified `README.md`
- `rolio`: modified `README.md`

Generated root docs:

- `bin/install-agent-docs check` initially failed because
  `/Users/alex/projects/AGENTS.md` lagged behind
  `mcritchie-studio/docs/agents/index.md`.
- I ran `bin/install-agent-docs`, then `bin/install-agent-docs check` passed.

Local health checks:

- McRitchie Studio `/up`: `http://localhost:3000/up` returns `200`.
- Turf Monster `/up`: `http://localhost:3100/up` returns `200`.

## What Is Working

### Agent Entry And Recovery

The root `AGENTS.md` generated from `mcritchie-studio/docs/agents/index.md` is
the right session start. The no-root-`CLAUDE.md`/`CODEX.md` decision still looks
right. Keep testing Claude against `AGENTS.md` before adding any adapter.

`mcritchie-studio/README.md`, `docs/ECOSYSTEM.md`, `bin/ecosystem-build`, and
`docs/agents/system/house-burn-down.md` now form a credible fresh-machine
recovery story.

### Shared Engine Direction

Both Rails apps consume `studio-engine 0.5.9`.

The engine is now the right home for:

- passwordless magic-link routes with inert GET plus POST consume
- local email inbox routes in non-production
- `Studio::Email.deliver`
- SES/Resend transport selection
- `Studio::EmailDelivery`
- shared UI primitives, theme, error logging, and auth helpers

### Turf Monster Runtime Tooling

`turf-monster/bin/tm` is a strong agent-facing product surface. It starts real
services, detaches them, checks readiness, manages Sidekiq, and returns a local
URL. This is the standard to copy for future app stack scripts.

### Worktree Lifecycle

`mcritchie-studio/bin/agent-worktree` is now the central launcher and
diagnostic surface for parallel stacks. The new `list`, `status`, `doctor`, and
dry-run `cleanup` commands make scale safer without introducing destructive
automation.

## Ranked Findings

### F1 - High - App `CLAUDE.md` Files Are Now Legacy But Still Too Useful

Status 2026-06-14: resolved for the primary managed repos. App `CLAUDE.md`
files now carry archive-only banners, and active docs were repointed to neutral
README/RUNBOOK/topic docs. Rolio remains outside the managed ecosystem registry.

`CLAUDE.md` files are no longer safe canonical context. Examples found:

- `studio-engine/CLAUDE.md` says version `0.4.13`; code is `0.5.9`.
- `turf-monster/CLAUDE.md` says Studio Engine is locked at `0.5.1`; lockfile is
  `0.5.9`.
- `mcritchie-studio/CLAUDE.md` includes stale exact test counts and an old
  roadmap pointer.
- `solana-studio/CLAUDE.md` includes stale test counts.

The problem is compounded because active docs still point to `CLAUDE.md` for
implementation details. Examples:

- `turf-monster/docs/SOLANA.md` points to `turf-vault/CLAUDE.md` for Squad
  upgrade steps.
- `turf-monster/docs/AUTH.md`, `docs/UI_PATTERNS.md`, and several workflow docs
  reference `CLAUDE.md` for live behavior.
- `rolio/docs/build/README.md` references top-level `CLAUDE.md` methodology.

Recommendation: convert each app `CLAUDE.md` into either a thin legacy adapter
or delete-later candidate after current facts are promoted. Active docs should
link to README/RUNBOOK/topic docs, not `CLAUDE.md`.

### F2 - High - Turf Auth Docs Still Teach Removed Password Flows

Status 2026-06-14: resolved for active Turf docs. `AUTH.md`,
`SIGNUP_FLOWS.md`, and the affected workflow docs now describe passwordless
magic-link, Google, and wallet auth.

The code and routes are passwordless-first, but docs still teach password-era
concepts:

- `turf-monster/docs/AUTH.md` starts with "Email + password" and lists
  `change_password` routes that no longer match the current passwordless flow.
- `turf-monster/docs/SIGNUP_FLOWS.md` keeps an old "Manual (email + password)"
  flow with only a warning banner.
- Workflow docs such as `email-signup-token-to-chat.md` and
  `referral-google-tokens-to-chat.md` still describe password fields or random
  passwords in signup records.

Impact: future agents can rebuild removed surfaces or misread security posture.

Recommendation: rewrite active Turf auth docs around the current three surfaces:
magic link, Google OAuth, and Solana wallet. Move password-era diagrams to
`docs/archive/` or keep them only behind a "historical, do not implement" banner.

### F3 - High - New-App Setup Has An Executable Gem Name Bug

Status 2026-06-14: resolved in `studio-engine/docs/NEW_APP_SETUP.md`.

`studio-engine/docs/NEW_APP_SETUP.md` tells apps to run:

```js
const studioPath = execSync('bundle show studio').toString().trim()
```

The gem is `studio-engine`, not `studio`. A future app following this guide will
break Tailwind setup immediately.

Recommendation: fix this to `bundle show studio-engine`, then review the rest of
the new-app guide for executable correctness. This should be a small immediate
cleanup.

### F4 - High - McRitchie Studio Still Duplicates Engine Session Mechanics

Status 2026-06-14: resolved in `studio-engine 0.5.6+`; McRitchie now delegates
session mechanics to the engine and configures `wallet_address_method`.

`mcritchie-studio/app/controllers/application_controller.rb` duplicates
`set_app_session`, `clear_app_session`, `set_current_context`, and
`verify_session_token` that now exist in `Studio::ErrorHandling`.

There is one real compatibility wrinkle: McRitchie Studio uses `solana_address`,
while the engine's SSO awareness helper currently tries `wallet_address`. That
means deleting the override blindly would lose the McRitchie wallet-awareness
field.

Recommendation: add a small engine-level wallet-address adapter such as
`Studio.user_wallet_address(user)` or support both `wallet_address` and
`solana_address`, then remove the McRitchie duplication with focused session and
magic-link tests.

### F5 - Medium - Shared Email Is Architecturally Ready, Ops Still Need A Playbook

Status 2026-06-14: resolved for documentation/operations. The shared playbook
is `mcritchie-studio/docs/agents/modules/email-operations.md`.

The code is in the right shape:

- `studio-engine` owns `Studio::MailTransport`.
- `studio-engine` owns `Studio::Email.deliver`.
- McRitchie uses `Studio::EmailDelivery`.
- Turf adapts the shared facade into its existing top-level `EmailDelivery`.
- Worktree stacks default to `LOCAL_EMAIL_CAPTURE=1`.

The remaining gap is operational, not architectural:

- SES sender/domain readiness is still a task, not a proved convention.
- Resend fallback is documented but not time-boxed.
- Preview/catalog conventions are still stronger in Turf than in the engine.

Recommendation: create one shared email operations checklist covering SES
production access, DKIM/SPF/DMARC, app sender defaults, local inbox proof,
provider smoke tests, and rollback. Keep templates app-owned.

### F6 - Medium - Solana Truth Is Much Better, But Still Too Easy To Copy

Status 2026-06-14: resolved for the first cleanup pass. The security audit is
tracked, historical docs carry archive banners, `KEY_ROTATION.md` is explicitly
superseded, Turf Monster's instruction count is aligned with the 22-wrapper
program surface, and Turf Vault now has `docs/VERIFICATION_MATRIX.md`.

`turf-monster/docs/SOLANA.md` is current in substance and correctly says Turf
Vault deployment identity is canonical in `turf-vault/docs/CURRENT_DEPLOYMENT.md`.
Turf Vault README/RUNBOOK also now emphasize the self-custody model.

Original issues found during the audit:

- `turf-monster/docs/SOLANA.md` said primitives came from
  `solana-studio ~> 0.4.3`; Turf locks `0.4.7`.
- `turf-vault/docs/MAINNET_LAUNCH.md` and `KEY_ROTATION.md` retained retired
  signer/program material.
- `turf-vault/docs/SECURITY_AUDIT_2026_05_31.md` was untracked locally.
- Turf Vault had one TypeScript test file, and the README said tests were still
  being realigned from the old deposit/withdraw contract shape.

Follow-up recommendation: implement the test suite rewrite against
`turf-vault/docs/VERIFICATION_MATRIX.md` before treating `anchor test` as launch
evidence.

### F7 - Medium - Generated Agent Docs Can Drift Silently

The source `docs/agents/index.md` was correct, but root `AGENTS.md` was stale
until refreshed manually during this audit.

Recommendation: make `bin/install-agent-docs check` part of the agent session
startup checklist and the ecosystem build verification. The script already
exists; the missing piece is making drift impossible to miss.

### F8 - Medium - Version Alignment Is Almost Clean, With One Solana Gap

Current locks:

- McRitchie Studio: `studio-engine 0.5.9`, `solana-studio 0.4.6`
- Turf Monster: `studio-engine 0.5.9`, `solana-studio 0.4.7`
- Studio Engine: `0.5.9`
- Solana Studio: `0.4.7`
- Turf Vault: `0.25.0` source, mainnet documented at `0.24.0`

Recommendation: decide whether McRitchie Studio's signing console needs
`solana-studio 0.4.7` features. If yes, update it now. If no, document why the
hub intentionally lags.

### F9 - Medium - Test Surface Is Uneven Relative To Risk

Observed test files:

- McRitchie Studio: 49 Rails test files.
- Turf Monster: 137 Rails test files plus Playwright specs.
- Studio Engine: 5 library test files.
- Solana Studio: 6 library test files.
- Turf Vault: 1 TypeScript test file.

The risk gradient is inverted for Turf Vault: it has the highest external
irreversibility and the thinnest test surface.

Recommendation: add a current Turf Vault instruction-surface test plan before
the next program upgrade, and give `studio-engine` a release-test matrix that
exercises a dummy app or both consumers for auth/email changes.

### F10 - Low - Rolio Is Correctly Marked Unmanaged, But Needs A Decision

Rolio's README now clearly says it is not in the managed ecosystem registry and
runs on `3020`. McRitchie Studio reserves `3200-3299` for planned `tax-studio`.

Recommendation: leave Rolio unmanaged for now, or assign it `3300-3399` if it
becomes a managed app. Do not reuse `3200-3299` unless Tax Studio is dropped.

### F11 - Low - Root Artifacts Still Exist Outside The Anchor Repo

Root `/Users/alex/projects` still contains:

- `dev-stack-smoothing.md`
- `bin/`

Recommendation: promote any remaining value into McRitchie Studio tracked docs
or scripts, then delete the root copies with approval.

## Recommended Work Tranches

### Tranche 1 - Active Docs Trust Reset

Goal: make the docs future agents read first accurate enough to act on.

Status 2026-06-14: complete for the first cleanup pass.

Implemented:

- Fix `studio-engine/docs/NEW_APP_SETUP.md` executable gem name.
- Rewrite `turf-monster/docs/AUTH.md` around passwordless auth.
- Archive or strongly banner old Turf password/signup workflow docs.
- Update `turf-monster/docs/SOLANA.md` from `solana-studio ~> 0.4.3` to the
  actual `0.4.7` consumer reality.
- Replace active references to `CLAUDE.md` with neutral README/RUNBOOK/topic
  links.
- Add a delete-later ledger row for app `CLAUDE.md` files once facts are
  promoted.

### Tranche 2 - Engine Session Refactor

Goal: remove duplicated McRitchie session code now that engine `0.5.6+` carries
the generic mechanics.

Status 2026-06-14: complete. `studio-engine 0.5.6+` carries the wallet-address
adapter, and McRitchie delegates session mechanics back to the engine.

Implemented:

- Add an engine wallet-address helper that supports `wallet_address`,
  `solana_address`, and app config override.
- Add engine tests around SSO awareness fields and session-token binding.
- Remove duplicated McRitchie `set_app_session`, `clear_app_session`,
  `set_current_context`, and `verify_session_token`.
- Run McRitchie auth/session tests and Turf auth tests before release/adoption.

### Tranche 3 - Email Operations Hardening

Goal: make SES the normal shared path and local inbox the default development
proof path.

Status 2026-06-14: complete for documentation/operations and production
fallback. The canonical cross-app playbook is
`mcritchie-studio/docs/agents/modules/email-operations.md`; app-level
implementation notes remain in each app's `docs/email-delivery.md`.

Implemented:

- Added one ecosystem SES checklist in McRitchie Studio docs.
- Added per-app sender-domain rows to the shared email operations matrix.
- Documented local inbox proof and provider smoke workflow for each app.
- Proved Resend fallback through the verified `mcritchie.studio` domain in
  production while SES remains sandboxed.
- Kept Resend rollback documented until SES has a real stability window.
- Deferred full preview/catalog extraction until the sender-domain cutover is
  stable.

### Tranche 4 - Solana/Vault Verification

Goal: make the current self-custody program surface safe for future agents to
touch.

Status 2026-06-14: complete for documentation/verification orientation.

Implemented:

- Confirmed `turf-vault/docs/SECURITY_AUDIT_2026_05_31.md` is tracked.
- Archived/bannered `MAINNET_LAUNCH.md`, `KEY_ROTATION.md`, and `v0.16-spec.md` as
  historical when they are not current procedure.
- Built a test matrix for current instructions: initialize, currency registry,
  create contest, enter via USDC/USDT/token, settle, cancel, close, sweep,
  pause/unpause, user account, username.
- Kept live program IDs and signer facts centralized in `CURRENT_DEPLOYMENT.md`.

### Tranche 5 - Managed App Registry

Goal: make the next app repeatable.

Status 2026-06-14: complete for registry direction and first scaffold.

Implemented:

- Kept `tax-studio` reserved at `3200-3299`.
- Kept Rolio unmanaged; if promoted, it should move to `3300-3399`.
- Added `mcritchie-studio/bin/register-satellite` as the dry-run-first registry
  helper.
- Added `mcritchie-studio/docs/agents/modules/app-registry.md` as the canonical
  app registry policy.
- Reframed the larger `bin/new-app` generator as a future layer over the
  registry contract.

## Immediate Next Best Actions

1. Maintain the final closeout state:
   remaining archive-only docs, delete-later candidates, and recurring drift
   maintenance are tracked in
   [`final-closeout-2026-06-14.md`](final-closeout-2026-06-14.md) and
   [`../maintenance/delete-later.md`](../maintenance/delete-later.md).

2. Start the fresh final audit pass from the production deployment checkpoint:
   Turf Monster release `v90`, commit `4333f90`, Node `22.x`, Stripe retired by
   default, payment provider `none`, Resend fallback from
   `McRitchie Studio <team@mcritchie.studio>`, and public `/up` plus live
   contest URLs returning `200`.

Status 2026-06-14: the Turf Vault TypeScript suite has been rewritten against
`turf-vault/docs/VERIFICATION_MATRIX.md`; local proof was `23 passing` against
an isolated validator on `127.0.0.1:8898`.

## Notes For Future Agents

- Do not delete the preserved worktrees just because they are visible to
  `doctor`; dirty/salvage state needs human review.
- Do not treat `CLAUDE.md` as active truth. It is migration material.
- Do not copy live Solana addresses into new docs unless the owning deployment
  doc is the source.
- Prefer changing the owning canonical doc over adding another explanatory doc.
- Always hand back a local URL, a test summary, a committed doc, or a concrete
  blocker.

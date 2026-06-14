# Modularization Audit

Date: 2026-06-13
Scope: `/Users/alex/projects` primary repos, visible worktrees, McRitchie agent docs, and local Claude memory.
Mode: read-heavy audit. No broad refactors or destructive cleanup.

## Executive Summary

The direction is sound: McRitchie Studio should be the durable documentation and bootstrap anchor, with `/Users/alex/projects/AGENTS.md` generated from `mcritchie-studio/docs/agents/index.md`.

The current system is halfway through that migration. The new agent-neutral modules are strong, but legacy `CLAUDE.md`, dated audits, old launch runbooks, and app-local scripts still compete with them. The biggest risks are not style issues: stale auth, email, deployment, port, worktree, and Solana docs can make future agents operate against the wrong stack or ask the user to perform work the agent should run.

## Main Themes

### 1. Keep McRitchie Studio as the doc and rebuild anchor

Keep cross-repo guidance in `mcritchie-studio/docs/agents/` and generate only `/Users/alex/projects/AGENTS.md` into the projects root. This matches the "house burns down" goal: clone McRitchie Studio first, then rebuild the rest from tracked docs and scripts.

Needed changes:

- Refresh `docs/ECOSYSTEM.md` and `docs/agents/system/house-burn-down.md` so they do not contradict the newer modules.
- Treat historical audits and prompt artifacts as snapshots, not current instructions.
- Move useful local-only material from `/Users/alex/projects/dev-stack-smoothing.md` and `/Users/alex/projects/bin/clean-artifacts` into tracked McRitchie Studio paths.

### 2. Retire LLM-specific docs as canonical context

The root `AGENTS.md` is now the right session entrypoint. Do not add root `CLAUDE.md` or `CODEX.md` unless a future Claude session proves `AGENTS.md` is insufficient.

The app `CLAUDE.md` files still contain useful facts, but they are no longer safe canonical docs because they mix current app knowledge with Claude-specific instructions and stale ports/domains.

Needed changes:

- Promote still-current facts from `CLAUDE.md` into app-owned README/RUNBOOK/topic docs.
- Leave `CLAUDE.md` in place temporarily as migration source.
- Later replace each with a thin adapter or delete after Claude compatibility is verified.

### 3. Make email a shared platform

Turf Monster already has the strongest email foundation:

- Durable `EmailDelivery` outbox.
- `EmailDeliveryJob` retry behavior.
- `EmailCatalog` with transactional/marketing classification.
- Admin email preview surface.
- SES/Resend transport switch.

McRitchie Studio now has SES-first transport wiring and Resend rollback, but no durable outbox/catalog yet.

Recommended direction:

- Extract transport selection into `studio-engine`.
- Extract a reusable email delivery/outbox framework into `studio-engine`.
- Keep app-owned mailers and app-owned catalog entries.
- Use AWS SES as the normal transport across apps, with Resend retained as rollback until SES is stable.
- Separate transactional and marketing/broadcast concerns now, before the third app copies ad hoc email logic.

### 4. Move the stronger magic-link flow upstream

Turf Monster's magic-link flow is stronger than the engine generic flow because it uses an inert GET confirmation page and consumes on POST. That protects links from scanner prefetch.

The engine still draws `GET /magic_link/:token` as a consuming route. McRitchie Studio currently uses the engine route, so it inherits the weaker pattern.

Recommended direction:

- Move scanner-safe GET-confirm plus POST-consume into `studio-engine`.
- Keep Turf's contest-aware override for richer post-login behavior.
- Make the engine generic path safe enough for McRitchie Studio and future apps.

### 5. Fix worktree and process architecture before scaling agents

The policy module already says the right thing: worktrees should live under `<repo>/.worktrees/<task-slug>`, with no agent ID. Existing Turf scripts still create visible sibling directories and print Claude-specific launch guidance.

The root `dev-stack-smoothing.md` captures the deeper requirements:

- Unique app-range ports.
- Isolated Redis DB per stack.
- Isolated development DB per stack.
- Unique session cookie per stack.
- Ruby PATH guard for worktrees.
- Local magic-link flow that does not email real people.
- Stripe listener or documented bypass per stack.

Recommended direction:

- Update `turf-monster/bin/worktree` and `bin/parallel-server`, or add `bin/worktree-stack`, to use `.worktrees/<task-slug>`.
- Auto-allocate port/Redis/DB/cookie values from the app range.
- Refuse to start if the Redis DB already has another Sidekiq process.
- Keep callback-heavy flows on primary ports unless provider config is explicitly prepared for the worktree port.

### 6. Treat scripts as product surface for agents

Turf Monster's `bin/tm` is the best current example: it starts real services, checks readiness, exposes logs, and returns a URL. That is the right standard.

McRitchie Studio's `bin/ecosystem-build` is the right recovery anchor, but it still uses plain Rails daemon starts and prints password-login guidance. It should converge with the same inspectable local-stack contract.

Recommended direction:

- Add a shared output contract for app stack scripts: URL, port, process status, log paths, skipped services.
- Keep app-specific details in app-owned scripts.
- Optionally add a McRitchie wrapper that dispatches to app scripts.

### 7. Update shared-library docs before the third app

`studio-engine` code is ahead of its docs. Apps consume `studio-engine 0.5.x`, but README and setup docs still describe `0.4.x`, password-first auth, and SSO assumptions. `solana-studio` README also still recommends git installation even though apps consume RubyGems.

Recommended direction:

- Refresh `studio-engine/README.md`, `docs/NEW_APP_SETUP.md`, and `docs/USER_CONTRACT.md` for passwordless-first apps.
- Document when SSO is enabled, disabled, or inappropriate.
- Update `solana-studio/README.md` to RubyGems install and current version.

### 8. Make active docs different from historical docs

The repo has many useful historical audits and launch runbooks. The issue is placement and banners, not their existence.

Recommended direction:

- Active runbooks should be short and current.
- Historical launch docs should have strong "historical, do not execute as current deployment identity" banners.
- Dated audits should either be archived or linked as snapshots after current facts are promoted.
- Avoid exact test counts in durable docs unless generated dynamically.

## Repo Findings

### McRitchie Studio

Strong:

- Owns `docs/agents/index.md`, modules, credential inventory, and `bin/ecosystem-build`.
- `AGENTS.md` generation path is correct.
- SES transition docs and tasks now exist.

Needs attention:

- README and topic docs still mention password-era login/test guidance in places.
- `docs/ECOSYSTEM.md` still uses `studio` as the engine label and omits shared SES/email.
- `docs/agents/system/house-burn-down.md` duplicates newer README guidance and has time-budget drift.
- No durable email outbox/catalog yet.
- Root-only artifacts need to move into the repo if they are part of the rebuild story.

### Turf Monster

Strong:

- Best local-agent stack via `bin/tm`.
- Strongest email/outbox/catalog foundation.
- Strong deployment preflight in `bin/deploy`.
- Rich workflow docs under `docs/workflows/`.

Needs attention:

- Worktree scripts still create visible sibling directories.
- `docs/SOLANA.md` has stale version/signers in places and should defer live identity to `turf-vault/docs/CURRENT_DEPLOYMENT.md`.
- README still says login with password even though app is passwordless.
- Historical launch/security docs need archive treatment.
- `.env.example` still defaults `MAILER_HOST=turf.mcritchie.studio` and references old credential names.

### Studio Engine

Strong:

- Correct shared home for auth, magic links, error handling, theme, modals, ImageCache, and future email framework.
- Code already supports passwordless auth methods and per-app route drawing.

Needs attention:

- README/setup docs are stale against `0.5.x`.
- Generic magic-link route should adopt scanner-safe POST consume.
- `USER_CONTRACT.md` should emphasize passwordless default and `#authenticate` only when `:password` is enabled.
- New-app docs should use the app port-range policy and SES/email framework.

### Solana Studio

Strong:

- Small focused gem with clear runtime boundary.
- Runbook has useful troubleshooting guidance.

Needs attention:

- README should use RubyGems install and current app consumption pattern.
- Version docs should align with Turf Monster lockfile.

### Turf Vault

Strong:

- `docs/CURRENT_DEPLOYMENT.md` is the right live identity source.
- README and RUNBOOK now point to current deployment identity more clearly than older docs.

Needs attention:

- `docs/MAINNET_LAUNCH.md` and other historical docs must remain clearly historical.
- Any live operator command should reference `docs/CURRENT_DEPLOYMENT.md`, not embedded signer/program literals.

### Rolio

Rolio is present locally but not in the McRitchie ecosystem registry. Its `CLAUDE.md` says it runs on port `3020`; its README still says default `3000`.

Decision needed:

- Either add Rolio to the ecosystem registry with an app range, likely `3200-3299`.
- Or explicitly document it as outside the managed McRitchie stack for now.

## Recommended Tranches

### Tranche 1: Docs and script alignment

- Update `docs/ECOSYSTEM.md`, `house-burn-down.md`, READMEs, `.env.example` files, and shared-library docs.
- Move or copy root `dev-stack-smoothing.md` and `bin/clean-artifacts` into McRitchie Studio.
- Add archive banners to historical docs.
- Keep updating `docs/agents/maintenance/delete-later.md`.

### Tranche 2: Worktree stack

- Build the `.worktrees/<task-slug>` flow.
- Auto-allocate app-range ports, Redis DBs, DB names, and cookie keys.
- Add local magic-link behavior that does not send real email from worktree stacks.
- Keep primary stacks for callback-heavy flows.

### Tranche 3: Shared email framework

- Extract SES/Resend transport selection to `studio-engine`.
- Extract durable outbox and email catalog preview pattern.
- Port McRitchie Studio to the shared framework.
- Add SES cutover docs for both domains and a rollback checklist.

### Tranche 4: Auth upstreaming

- Move scanner-safe magic-link confirm/consume into `studio-engine`.
- Add focused engine tests.
- Remove McRitchie compatibility overrides once the engine release carries them.

### Tranche 5: Cleanup and deletion

- Confirm branch/PR disposition for visible worktrees.
- Remove merged or empty worktrees/directories only after explicit confirmation.
- Retire or thin `CLAUDE.md` files after a future Claude session validates `AGENTS.md`.

## Decisions For Alex

1. Should Rolio join the managed ecosystem now, and should it get the `3200-3299` range?
2. Should historical docs move to `docs/archive/`, or stay in place with strong banners?
3. Should `studio-engine` own the shared email framework, or should a separate email gem/module exist?
4. For worktree stacks, should local magic links use a dev-only endpoint, log-only URLs, or a mailcatcher/letter-opener style inbox?
5. Should `bin/ecosystem-build` eventually start apps through their app-owned stack scripts instead of raw Rails daemon starts?

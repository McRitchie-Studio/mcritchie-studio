# Post-Cleanup Ecosystem Audit

Date: 2026-06-14
Owner: McRitchie Studio agent docs
Scope: `/Users/alex/projects` primary checkouts, active repo docs, shared gems, local worktree model, email/auth/Solana seams.

## Executive Summary

The workspace is now much easier for future agents to enter. The root entrypoint is `AGENTS.md`, McRitchie Studio owns the generated source at `docs/agents/index.md`, visible sibling worktrees have been removed, and the app port model is coherent: McRitchie Studio on `3000`, Turf Monster on `3100`, future apps in their own hundred ranges.

The main remaining risk is not app bootstrapping. It is active-vs-historical drift in docs that describe money movement, Solana deployments, and production operations. Turf Monster and Turf Vault have the most urgent drift because stale docs still mention retired wallets, old program versions, devnet-only assumptions, and the removed custodial deposit/withdraw model.

Shared email transport is in place through `studio-engine`, and SES is now the preferred direction with Resend as a fallback. The shared email operating layer is not done yet: durable delivery rows, preview/catalog conventions, resend tooling, and per-app sender identity still live unevenly across apps.

No product code should be broadly refactored until the Solana truth reset is finished. Future agents need one canonical deployment source, current app-facing docs, and historical docs clearly archived before touching settlement flows.

## Current Workspace Baseline

Root `/Users/alex/projects` now contains the intended primary surface:

- `AGENTS.md`
- `bin/`
- `dev-stack-smoothing.md`
- `mcritchie-studio/`
- `rolio/`
- `solana-studio/`
- `studio-engine/`
- `turf-monster/`
- `turf-vault/`

Primary clean checkouts at audit time:

- `mcritchie-studio`
- `turf-monster`
- `studio-engine`

Primary checkouts with pre-existing local user work:

- `turf-vault`: `README.md`, `RUNBOOK.md`, `docs/MAINNET_LAUNCH.md`, plus untracked `docs/CURRENT_DEPLOYMENT.md`, `docs/SECURITY_AUDIT_2026_05_31.md`, `docs/turf-vault-deploy-cost.html`
- `solana-studio`: `README.md`
- `rolio`: `README.md`

Hidden salvage worktrees preserved intentionally:

- `mcritchie-studio/.worktrees/broadcasts-salvage`
- `turf-vault/.worktrees/grant-seeds-salvage`

Do not delete preserved worktrees until their branch and file-level value have been explicitly reviewed.

## Decisions Already Working

### Agent Entry

`/Users/alex/projects/AGENTS.md` is the correct root entrypoint. It is generated from `mcritchie-studio/docs/agents/index.md`, which keeps the local agent contract rebuildable from GitHub.

The choice to avoid root `CLAUDE.md` and `CODEX.md` is still sound. Codex reads `AGENTS.md` natively. Claude compatibility should be tested in a future Claude session before adding an adapter. If an adapter becomes necessary, keep it thin and point back to `AGENTS.md`.

### Documentation Ownership

Cross-repo operating rules belong in McRitchie Studio:

- agent culture
- 1Password conventions
- credential inventory
- ports/processes
- worktree conventions
- deployment posture
- documentation drift maintenance

Repo-specific truth belongs with the repo that owns the behavior. Example: Turf Vault deployment identity belongs in `turf-vault/docs/CURRENT_DEPLOYMENT.md`, while McRitchie Studio should link to it instead of duplicating program IDs.

### Ports

The hundred-range model is the right default:

- McRitchie Studio: `3000-3099`
- Turf Monster: `3100-3199`
- Tax Studio: `3200-3299`

If Rolio joins the managed ecosystem, assign it a non-conflicting range before adding it to `config/satellites.yml`. `3300-3399` is the clean next choice unless Tax Studio is dropped.

### Worktrees

The hidden worktree convention is correct:

```text
/Users/alex/projects/<repo>
/Users/alex/projects/<repo>/.worktrees/<task-slug>
```

Do not include agent ids in worktree paths. Task ownership can transfer between agents, and multiple agents can collaborate on one branch.

`mcritchie-studio/bin/agent-worktree` is now the right launch surface for parallel app stacks. It already handles task branches, app-range ports, copied env, isolated databases, isolated session cookies, and Redis DB allocation.

## Ranked Findings

### F1 - High - Solana Deployment Truth Is Split Across Repos

`turf-vault/docs/CURRENT_DEPLOYMENT.md` appears to be the freshest source of truth, but it is still untracked locally. It records:

- Devnet program `EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ`
- Devnet version `v0.25.0`
- Mainnet program `DaFv83yoZAWFBZj3tHNJEXMviqneVWxNghJa9RH9UpuC`
- Mainnet version `v0.24.0`
- Current Alex Bot signer `8K81...`
- Retired/orphaned identities that should not be reused

Active Turf Monster docs still conflict with that source. `turf-monster/docs/SOLANA.md` describes a devnet `v0.18` world, old deployment slots, old program assumptions, and a retired `F6f8...` Alex Bot signer.

Impact: future agents can make wrong deployment, signer, or settlement assumptions.

Recommendation: make `turf-vault/docs/CURRENT_DEPLOYMENT.md` tracked and canonical, then rewrite active Turf Monster Solana docs to link to it instead of copying IDs. Keep historical deployment stories under `docs/archive/` with visible banners.

### F2 - High - Turf Vault Docs Still Describe Removed Custodial Flows

The current Turf Vault program source describes a self-custody model: funds live in user ATAs, with multisig-controlled admin operations and v0.25 grant-seed/admin username flows.

However, `turf-vault/README.md` still describes:

- user deposits into a vault balance
- withdrawals
- per-user `balance`
- `total_deposited`
- daily withdrawal limits
- removed instructions such as deposit/withdraw/migrate/force-close variants

The test suite also appears to retain old deposit/withdraw coverage.

Impact: the README teaches the wrong financial architecture. This is the most dangerous form of documentation drift because it changes how an agent thinks money moves.

Recommendation: do a Turf Vault docs reset before more feature work. README, RUNBOOK, current deployment, changelog, and tests should agree on the current instruction surface. Historical deposit/withdraw docs should be archived or clearly marked obsolete.

### F3 - High - Turf Monster Production Runbook Still Has App/Network Drift

`turf-monster/RUNBOOK.md` still references Heroku/app commands and remediation paths that appear stale:

- `turf-monster` instead of the production Heroku app `turf-monster-mainnet`
- missing-env guidance that no longer matches the current production app name
- wrong-network guidance that assumes devnet-only recovery

Impact: during an incident, an agent could inspect or mutate the wrong Heroku app, or apply a devnet-only fix to a mainnet-facing production problem.

Recommendation: update the runbook around actual Heroku app names, mainnet/devnet split, and current program IDs after the Solana truth reset.

### F4 - Medium - Shared Email Transport Exists, Shared Email Operations Do Not

`studio-engine` owns `Studio::MailTransport`, SES support, and Resend fallback. Turf Monster has a stronger app-level delivery model with `EmailDelivery`, a Sidekiq delivery job, resend accounting, and transactional docs.

McRitchie Studio still defaults its local sender to `noreply@turfmonster.media` unless overridden, which explains why a McRitchie Studio magic link can appear from a Turf Monster domain.

Impact: future apps will copy uneven email patterns. Deliverability, previewing, sender identity, retry behavior, and provider migration will drift.

Recommendation:

- Verify SES sender/domain setup for `mcritchie.studio`.
- Move shared delivery concepts into `studio-engine` after the SES transport settles.
- Keep app-specific mail copy/templates in each app.
- Preserve Resend as a documented fallback, not the primary path.

### F5 - Medium - Studio Engine New-App Docs Still Leak Turf-Specific Money Primitives

`studio-engine/docs/NEW_APP_SETUP.md` is valuable, but parts of it still teach app-specific concepts like balances, deposits, and withdrawals.

Impact: a future third app could inherit Turf Monster's historical money assumptions even when it only needs generic auth/theme/email/image/cache primitives.

Recommendation: split the new-app guide into neutral engine setup plus optional satellite examples. Any Turf-specific financial example should live in Turf Monster docs, not the engine.

### F6 - Medium - Active And Historical Docs Are Still Mixed

Several repos still keep old audits, handoffs, generated reports, standalone prototypes, and current runbooks in the same directories.

Observed examples:

- McRitchie Studio `docs/agents/system/` contains useful history and operational docs in one namespace.
- Turf Monster has active topic docs next to old audit and handoff material.
- Turf Vault has current deployment material next to historical launch docs.
- Rolio has Rails-wrapper docs mixed with standalone wireframe/build artifacts.

Impact: agents must infer whether a doc is current or historical. That slows down work and increases the odds of copying obsolete instructions.

Recommendation: adopt a simple repo-level convention:

```text
docs/
  README.md or index.md
  active-topic.md
  runbooks/
  archive/
```

Historical docs should start with a short banner that says what replaced them.

### F7 - Medium - Worktree Tooling Needs Lifecycle And Local-Mail Hardening

`bin/agent-worktree` is a strong foundation. It creates hidden worktrees, branches, app-range ports, isolated databases, session keys, and Redis DBs.

The next scale issues are lifecycle and side effects:

- no single cleanup command for stopped/merged/abandoned worktrees
- no central view of all allocated ports/Redis DBs across apps
- worktree magic links can still send real email unless the app has local-first delivery tooling
- stock Redis DB count can become a ceiling before the port plan does

Impact: tens of agents will eventually create stale processes, stale worktrees, and email side effects.

Recommendation: extend the launcher with `list`, `cleanup`, and local-inbox conventions before expecting dozens of live agent stacks.

### F8 - Low - Root Artifacts Should Be Promoted Or Deleted

Two root artifacts are useful but should not remain long-term root clutter:

- `/Users/alex/projects/dev-stack-smoothing.md`
- `/Users/alex/projects/bin/clean-artifacts`

Impact: small, but this works against the goal of keeping `/Users/alex/projects` as a clean launchpad.

Recommendation: promote any remaining value into McRitchie Studio docs/scripts, then delete the root copies after approval.

### F9 - Low - Test Docs Have Exact Counts That Will Drift

`mcritchie-studio/docs/topics/testing.md` includes exact Rails and Playwright counts. That is useful immediately after an audit, but it will drift quickly.

Impact: low, but future agents may treat old counts as a failure signal.

Recommendation: keep commands and gotchas precise, but avoid exact test counts unless they are refreshed by CI or a current audit.

### F10 - Low - Rolio Needs A Managed/Unmanaged Decision

Rolio exists locally and has a Rails wrapper, but it is not in McRitchie Studio's managed satellite registry. Its docs still contain standalone/static wireframe traces and a local port that overlaps the old ad hoc era.

Impact: low today, but confusing once more apps are added.

Recommendation: either keep Rolio explicitly unmanaged, or add it to the registry with a reserved range, likely `3300-3399`.

## Recommended Work Tranches

### 1. Solana Truth Reset

Goal: make Solana docs safe enough for agents to touch production-facing settlement code.

Deliverables:

- Track and bless `turf-vault/docs/CURRENT_DEPLOYMENT.md`.
- Rewrite `turf-vault/README.md` around the current self-custody model.
- Rewrite `turf-monster/docs/SOLANA.md` to describe current app integration and link to Turf Vault for program identity.
- Fix `turf-monster/RUNBOOK.md` production app names and network guidance.
- Add archive banners to historical launch/deployment docs.

### 2. Shared Email Operations

Goal: support McRitchie Studio, Turf Monster, and the next app with one email playbook.

Deliverables:

- Confirm SES sender/domain setup for each app domain.
- Move durable delivery/logging primitives into `studio-engine` if the abstraction stays clean.
- Keep Resend fallback documented and configured as rollback.
- Add local-first magic-link behavior for worktree stacks.
- Standardize per-app sender defaults so McRitchie Studio does not default to Turf Monster's domain.

### 3. Engine Auth And Magic Links

Goal: avoid copy/paste auth behavior across Rails apps.

Deliverables:

- Upstream scanner-safe magic link confirmation/consumption flow into `studio-engine`.
- Keep Turf Monster's stricter money-app auth posture unless SSO is explicitly redesigned.
- Document when apps should opt into hub SSO versus isolated auth.

### 4. Historical Docs Archive Pass

Goal: reduce agent context mistakes.

Deliverables:

- Add repo-level `docs/archive/` directories where needed.
- Move dated prompts, handoffs, launch stories, and obsolete audits under archive.
- Add replacement pointers at the top of historical docs that must remain near active docs.

### 5. Worktree Lifecycle Hardening

Goal: prepare for many concurrent agents.

Deliverables:

- Add launcher `list` across all registered apps.
- Add launcher cleanup flow that refuses to delete unpushed or dirty work without an explicit decision.
- Add local-inbox/log-only email delivery for worktree stacks.
- Add Redis scaling guidance once local stack count approaches DB `15`.

### 6. App Registry Expansion

Goal: keep future app onboarding boring.

Deliverables:

- Decide Rolio managed vs unmanaged.
- Reserve future app ranges in `config/satellites.yml`.
- Keep `docs/ECOSYSTEM.md` as the single repo map.

## Suggested Next Step

Start with tranche 1. The Solana truth reset removes the highest-risk ambiguity before another agent changes settlement code, deploy scripts, or production runbooks.

After tranche 1, the email operations tranche has the best leverage because it applies to McRitchie Studio, Turf Monster, and the planned third app.

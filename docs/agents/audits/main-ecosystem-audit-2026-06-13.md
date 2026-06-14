# Main Ecosystem Audit

Date: 2026-06-13
Scope: `/Users/alex/projects`, with McRitchie Studio as the documentation anchor and Turf Monster as the active product surface.

This audit follows the first-pass modularization work and supersedes the parts of that audit that have already been addressed. It is intentionally advisory: no worktrees were deleted and no large refactors were started while collecting these findings.

## Executive Summary

The ecosystem is moving in the right direction. The root `AGENTS.md` is now a good LLM-neutral session entrypoint, McRitchie Studio is established as the documentation source of truth, and the current worktree tooling now points new task environments into hidden `.worktrees/` directories instead of adding more visible sibling directories.

The next highest-leverage work is not a new product feature. It is trust-building infrastructure:

1. Separate active runbooks from historical docs so agents do not follow stale instructions.
2. Finish the old sibling worktree cleanup after branch disposition is reviewed.
3. Move duplicated auth/session behavior back into `studio-engine` where possible.
4. Promote shared email infrastructure beyond transport settings so future apps inherit outbox, catalog, previews, and provider failover.
5. Make fresh-machine recovery concrete from McRitchie Studio: clone, hydrate secrets, install `AGENTS.md`, boot primary apps, verify URLs.

Stripe work should remain punted for now per product direction.

## Recently Completed Cleanup

These changes were committed and pushed before this audit:

- `turf-monster` commit `83892c6`: aligned mail sender config and provider-neutral docs.
- `mcritchie-studio` commit `2cf27d4`: pointed agent docs at neutral documentation instead of Claude-specific files.
- `studio-engine` commit `3d0e3d8`: clarified that the shared mailer sender is provider-neutral.

The current root `AGENTS.md` matches `mcritchie-studio/docs/agents/index.md`.

## Current System Map

| Repo | Role | Local port range | Current read |
| --- | --- | --- | --- |
| `mcritchie-studio` | Anchor app, agent docs, onboarding, shared studio surface | `3000-3099` | Strongest documentation base. Needs active/archive separation and fresher recovery docs. |
| `turf-monster` | Active DFS product | `3100-3199` | Product app is working locally. Worktree tooling has improved. Some docs still reference old hosts, wallets, or providers. |
| `studio-engine` | Shared Rails engine for auth, styling, mail transport, app conventions | Gem dependency | Good candidate for auth/session simplification, scanner-safe magic links, and shared email/outbox primitives. |
| `turf-vault` | Solana program and deployment material | N/A | Contains important deployment state. Worktree has existing uncommitted docs. Treat as source for chain-specific truth, not general agent onboarding. |
| `solana-studio` | Supporting Solana tooling | N/A | Existing README changes are present. Do not touch without a focused task. |
| `rolio` | Older or side app | Currently `3020`; managed range undecided | If it joins the managed stack, assign a clean range that does not conflict with planned Tax Studio. |

## Findings

### 1. Active and Historical Docs Are Still Mixed

The modular documentation direction is solid, but agents still have to decide which docs are current. McRitchie Studio has roughly 84 Markdown files and Turf Monster has roughly 35. Historical audits, handoffs, setup notes, and active runbooks are close enough together that a future agent can easily over-weight stale context.

Concrete drift found:

- `mcritchie-studio/README.md` still includes exact test counts even though `docs/agents/maintenance/docs-maintenance.md` warns against duplicating volatile counts.
- `mcritchie-studio/docs/agents/system/house-burn-down.md` still references Turf startup via `bin/dev`; Turf's current app workflow prefers `bin/tm up`.
- `studio-engine/docs/ENV_SETUP.md` still describes a shared `/Users/alex/projects/.env` model, while current app docs have moved toward per-app `.env` files.
- `mcritchie-studio/docs/agents/system/secrets-rotation.md` still references old shared env paths and old wallet naming.

Recommendation:

- Keep active docs short and decisive.
- Move old audits, handoffs, and historical prompts under `docs/archive/` or add an explicit "Historical context only" banner.
- Keep volatile values out of top-level READMEs unless they are generated.
- Make `docs/agents/maintenance/delete-later.md` the cleanup ledger for deletion candidates until they are actually removed.

### 2. Credential Source of Truth Is Better, But Not Yet Singular

The new credential docs are useful: they provide 1Password item names and an agent-friendly naming convention without exposing secrets. The remaining problem is older docs that still imply direct secret values, shared env files, or old wallet identifiers.

Recommendation:

- McRitchie Studio should own the agent-facing credential inventory and naming convention.
- App repos should document only the env var names they require and the 1Password item names that satisfy them.
- Chain deployment facts should live in `turf-vault` deployment docs, with McRitchie Studio linking to them instead of copying values.
- Root or shared `.env` should be treated as legacy or bootstrap-only unless we intentionally reintroduce it.

### 3. Worktree Architecture Is Now Mostly Correct, Cleanup Remains

The current scripts are better than the first-pass audit suggested:

- `turf-monster/bin/worktree` now creates `.worktrees/<task-slug>`.
- `turf-monster/bin/parallel-server` defaults to `.worktrees/parallel-<PORT>`.
- McRitchie Studio has central `bin/agent-worktree` docs and port/session isolation guidance.

The issue is historical residue. The root projects folder still contains many visible sibling worktrees, including Turf Monster task directories and McRitchie Studio task directories. These are already tracked in the delete-later ledger and should not be removed until branch disposition is reviewed.

Recommendation:

1. Generate a branch disposition report for every visible sibling worktree.
2. For each, mark `merged`, `superseded`, `needs salvage`, or `unknown`.
3. Remove approved worktrees with `git worktree remove`, then prune.
4. Keep all future task clones under each repo's `.worktrees/` directory.

### 4. Auth and Session Code Can Be Re-Centered in `studio-engine`

`studio-engine` now ships the core auth/session concern methods that McRitchie Studio still duplicates in `ApplicationController`, including session setup and session token verification. McRitchie Studio carries a comment saying the duplication exists until every deployed app is on an engine release that includes those helpers. That appears ready to revisit.

Turf Monster still has legitimate app-specific overrides for impersonation and on-chain state, but it calls into engine behavior.

Recommendation:

- Start with McRitchie Studio because it is the simpler consumer.
- Remove duplicated controller helpers only after confirming wallet field naming and current tests.
- Keep app-specific policy hooks in apps, but push reusable mechanics into `studio-engine`.
- Add consumer tests in both McRitchie Studio and Turf Monster before releasing the engine change.

### 5. Magic Link Scanner Safety Should Move Upstream

Turf Monster has stronger magic-link behavior than the generic engine flow. McRitchie Studio still depends on the engine route. Since link scanners and preview clients can consume one-time links, scanner-safe behavior should be a shared engine feature rather than an app-by-app patch.

Recommendation:

- Add a GET confirmation page that does not consume the token.
- Consume the token only on explicit POST.
- Keep app branding and copy configurable.
- Ship through `studio-engine`, then update both apps to use the shared flow unless an app has a product-specific reason not to.

### 6. Email Is Shared at Transport Level, Not Product Infrastructure Level

The provider-neutral mail transport work is a good start. Turf Monster also has higher-level email concepts such as durable delivery records, catalog/admin surfaces, previews, and product mailers. McRitchie Studio and future apps will need similar transactional and marketing email capabilities.

Recommendation:

- Keep SES as the intended default provider for cost control.
- Preserve Resend as a rollback provider.
- Move reusable delivery logging, catalog metadata, preview conventions, and provider abstraction into `studio-engine` or a small shared email layer.
- Keep actual mailer content app-owned.
- Document sender domains and verified identities in McRitchie Studio credential docs, not scattered app notes.

### 7. Port Ranges Need One More Decision

The current convention is clear:

- McRitchie Studio: `3000-3099`
- Turf Monster: `3100-3199`

The next-app story is slightly ambiguous. Ecosystem docs suggest Rolio could take `3200-3299`, but `config/satellites.yml` already reserves `tax-studio` at `3200`.

Recommendation:

- Keep `3200-3299` reserved for Tax Studio if that app remains planned.
- Assign Rolio `3300-3399` if it becomes managed by the agent stack.
- If Rolio remains outside the managed stack, mark it explicitly as unmanaged and leave its existing `3020` local behavior alone.

### 8. Solana and Production Docs Still Carry Old Identifiers

Several docs still reference old wallet names or old public hosts. Examples include `studio-engine/docs/ENV_SETUP.md`, McRitchie Studio secrets rotation docs, and Turf Monster Solana/API docs.

Recommendation:

- Active docs should reference 1Password item names and deployment-doc links, not copied wallet addresses.
- Historical docs can keep old values only with an explicit archive banner.
- `turf-vault` should remain the canonical source for deployed program state.
- Turf Monster product docs should describe behavior and required env vars, not deployment private keys or old launch addresses.

### 9. Fresh-Machine Recovery Needs a Single Happy Path

The "house burns down" concept is correct, but it should read like a tested procedure. The current version is close but still has stale startup details and can be made more operational.

Recommendation:

- Start in `mcritchie-studio/README.md`.
- Provide a single recovery flow: clone McRitchie Studio, install dependencies, install root `AGENTS.md`, authenticate 1Password/GitHub/Heroku/AWS, clone satellites, hydrate env files, boot primary apps, and verify local URLs.
- Make the expected proof concrete:
  - McRitchie Studio at `http://localhost:3000`
  - Turf Monster at `http://localhost:3100`
  - Mail delivery smoke test documented by app and provider

## Recommended Implementation Sequence

### Tranche A: Documentation Trust Boundary

Clean the active docs first so future agents start from accurate instructions.

- Remove exact test counts from READMEs.
- Update the house-burn-down workflow to use current app boot commands.
- Rewrite `studio-engine/docs/ENV_SETUP.md` as provider-neutral and app-neutral.
- Add archive banners or move old handoffs/audits under `docs/archive/`.
- Add a short "when docs drift" maintenance routine.

### Tranche B: Worktree Cleanup

Do not delete blindly. Convert the existing delete-later list into a disposition report, get approval for removals, then clean the projects folder.

- Mark each sibling worktree by branch status.
- Salvage anything not merged.
- Remove approved worktrees.
- Prune worktree metadata.
- Keep `.worktrees/` as the only sanctioned future location.

### Tranche C: Shared Auth and Session Refactor

Use McRitchie Studio as the first consumer because its overrides are thinner.

- Confirm engine concern coverage.
- Remove duplicated McRitchie controller methods.
- Add regression tests around signin, signout, session token verification, and wallet-backed user context.
- Release `studio-engine`, then update Turf Monster after confirming no impersonation/on-chain regression.

### Tranche D: Shared Email Infrastructure

Treat email as ecosystem infrastructure instead of app-local glue.

- Promote provider-neutral transport config.
- Add shared delivery logging and catalog conventions.
- Keep SES primary and Resend fallback.
- Add a local proof workflow for magic links and a provider smoke test.

### Tranche E: New App Onboarding

Once docs and shared engine behavior are clean, define the app-template path.

- Reserve port range.
- Add satellite config.
- Create per-app `.env.example`.
- Add smoke tests and local URL proof.
- Document whether the app is callback-heavy and therefore needs primary-port testing.

## Immediate Follow-Up Candidates

These are small enough to do before the deeper code refactors:

- Update McRitchie Studio README test instructions to avoid stale counts.
- Update the house-burn-down doc to use `bin/tm up` for Turf Monster.
- Rewrite `studio-engine/docs/ENV_SETUP.md` to match the current per-app env and 1Password strategy.
- Update Turf Monster session-store comments to mention the current production host strategy.
- Decide whether Rolio is managed, then document its port range accordingly.

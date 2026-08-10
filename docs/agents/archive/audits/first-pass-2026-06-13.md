# First-Pass Agent Documentation Audit

Date: 2026-06-13  
Scope: `/Users/alex/projects` primary repos and visible worktrees.  
Mode: read-heavy audit plus documentation capture. No destructive cleanup, no deploys, no credential reads.

## Executive Summary

The ecosystem is close to the desired shape, but it is midway through a migration:

- McRitchie Studio is now the correct anchor for bootstrap and agent-neutral docs.
- Turf Monster has the most mature local-agent stack (`bin/tm`, worktree helpers, deploy preflights), but much of that wisdom is still trapped in `CLAUDE.md`.
- Studio Engine, Turf Vault, and several historical docs still contain stale ports, old domains, old signer references, and Claude-specific onboarding paths.
- The root `/Users/alex/projects` directory is visually overloaded by worktree siblings; the proposed `.worktrees/<task-slug>` model is the right next standard.
- The highest-risk drift is not cosmetic: Turf Vault runbooks still show old program IDs/signers in places where an agent could operate against the wrong chain state.

## Current Shape

Primary repos:

| Repo | Role | Status |
|------|------|--------|
| `mcritchie-studio` | Hub, bootstrap anchor, source of agent docs | dirty from this cleanup pass |
| `turf-monster` | Main product app, real-money/Solana flows | dirty from port migration |
| `studio-engine` | Shared Rails engine | clean |
| `solana-studio` | Ruby Solana primitives | clean |
| `turf-vault` | Anchor program | untracked audit/cost docs |
| `rolio` | Additional app present locally, not yet in McRitchie ecosystem docs | clean |

Visible worktrees:

- Turf Monster: 12 sibling worktrees.
- McRitchie Studio: 1 sibling worktree.
- Turf Vault: 2 sibling worktrees.

The worktree cleanup ledger at `docs/agents/maintenance/delete-later.md` is the right place to keep disposition notes until branches/PRs are confirmed.

## Decisions To Adopt

1. **McRitchie Studio owns cross-repo docs.**
   - Keep `/Users/alex/projects/AGENTS.md` generated from `mcritchie-studio/docs/agents/index.md`.
   - Keep repo-specific behavior in the owning repo.
   - Do not create root `CLAUDE.md` or `CODEX.md` unless empirical Claude feedback proves it is needed.

2. **READMEs are for humans and quick bootstrap; `AGENTS.md` is for session startup.**
   - READMEs should point at McRitchie Studio for ecosystem setup.
   - Deep app context should live in app-owned topic docs, not LLM-specific root files.

3. **`CLAUDE.md` files become migration sources, not canonical entrypoints.**
   - Keep them for now.
   - Promote useful facts into neutral docs.
   - Later either shrink them to thin compatibility adapters or delete them after Claude proves `AGENTS.md` is enough.

4. **Skills are portable-ish; hooks are runtime-specific.**
   - Put doctrine in `docs/agents/modules/`.
   - Put reusable workflow specs/scripts under neutral paths such as `.agents/skills/` or `scripts/agents/`.
   - Implement Codex hooks under `.codex/` and Claude hooks under `.claude/` only after the shared policy is stable.

5. **Agents should return inspectable artifacts.**
   - Prefer a local URL, screenshot, test summary, or exact blocker.
   - Do not hand the user safe terminal chores.
   - This is now captured in `docs/agents/modules/culture.md`.

## High-Priority Drift

### 1. Studio Engine still documents old Turf Monster port/domain

Files:

- `studio-engine/README.md`
- `studio-engine/docs/GOOGLE_AUTH_SETUP.md`
- `studio-engine/docs/NEW_APP_SETUP.md`

Observed drift:

- Turf Monster is still listed as `3001`.
- Production URI still points to `https://turf.mcritchie.studio`.
- New app setup still says to consult top-level `CLAUDE.md` for ports.

Recommended fix:

- Update Turf Monster to port `3100` and prod URL `https://app.turfmonster.media`.
- Point port policy to `mcritchie-studio/docs/agents/modules/ports-and-processes.md`.
- Update the new app guide to the hundreds-range convention.

### 2. Turf Vault README/RUNBOOK disagree with current chain state

Files:

- `turf-vault/README.md`
- `turf-vault/RUNBOOK.md`
- `turf-vault/docs/KEY_ROTATION.md`
- `turf-vault/docs/MAINNET_LAUNCH.md`

Observed drift:

- README headline program ID still shows `Dx8u...`, while `CLAUDE.md` says devnet is now `EQGF...` and mainnet is `DaFv...`.
- README links Turf Monster at the old `turf.mcritchie.studio` domain.
- RUNBOOK signer examples still include retired `F6f8...` Alex Bot.
- RUNBOOK verification commands still reference the old devnet program.
- Historical launch docs contain one-time instructions that may be correct as history but unsafe as live operator guidance.

Recommended fix:

- Create a short `turf-vault/docs/CURRENT_DEPLOYMENT.md` with current devnet/mainnet program IDs, signer set, IDL hash rule, and upgrade authority.
- Make README and RUNBOOK point to that file for live values.
- Move key-rotation and first-mainnet-launch docs under an archive/historical heading, or add a top warning banner.
- Replace any live `F6f8...` signer instructions with the rotated `8K81...` context or a named 1Password item reference.

### 3. Turf Monster still has stale deployment launch docs

Files:

- `turf-monster/MAINNET_LAUNCH.md`
- `turf-monster/README.md`
- `turf-monster/docs/SECURITY_AUDIT_2026_05_23.md`
- `turf-monster/docs/STASH_3_HANDOFF.md`

Observed drift:

- Mainnet launch checklist still references `https://turf.mcritchie.studio`.
- README tells agents to use `CLAUDE.md` for deep context.
- README single-app path recommends `bin/dev`, while `CLAUDE.md` correctly says detached/agent sessions should use `bin/tm`.
- Required `.env` keys still mention `agent.solana`; the current credential docs distinguish legacy `agent.solana` from rotated `agent.alex.solana`.

Recommended fix:

- Update README to recommend `bin/tm up` for agent sessions and `bin/dev` only for interactive human terminals.
- Create or promote a neutral `docs/LOCAL_STACK.md` that captures `bin/tm`, primary port `3100`, Stripe listener, Sidekiq, and callback constraints.
- Mark `MAINNET_LAUNCH.md` as historical first-launch unless it is still used.
- Replace old prod domain references in active docs; leave security audits historical but clearly labeled.

### 4. McRitchie Studio still has legacy system docs competing with new modules

Files:

- `mcritchie-studio/docs/agents/system/credentials.md`
- `mcritchie-studio/docs/agents/system/memory.md`
- `mcritchie-studio/docs/agents/system/ecosystem-audit-prompt.md`
- `mcritchie-studio/docs/agents/system/ecosystem-audit-2026-05-17.md`
- `mcritchie-studio/docs/agents/system/md-audit-2026-05-23.md`

Observed drift:

- Old system docs still point at `agent.solana` and Claude memory as operating surfaces.
- Historical audit docs contain stale port/domain values.
- `ECOSYSTEM.md` still says "fresh Claude sessions" and points app reads at `CLAUDE.md`.

Recommended fix:

- Promote still-live facts into `docs/agents/modules/`.
- Add archive banners to historical system docs.
- Convert `ecosystem-audit-prompt.md` into a neutral audit playbook or move it to delete-later.
- Update `ECOSYSTEM.md` to be LLM-neutral and to route agents through `AGENTS.md` plus app topic docs.

### 5. Worktree layout is structurally noisy

Observed drift:

- `/Users/alex/projects` has many visible sibling worktrees.
- Turf Monster `bin/worktree` used to create visible sibling worktrees; this pass updated it to `.worktrees/<task-slug>`.
- The new policy prefers `<repo>/.worktrees/<task-slug>`.

Recommended fix:

- Use `mcritchie-studio/bin/agent-worktree`; app-local `bin/worktree` should create `.worktrees/<task-slug>` when retained for compatibility.
- Do not include agent IDs in paths.
- Assign ports by app range plus task offset.
- Keep primary checkouts on `main` with callback-heavy flows on primary ports.

## Medium-Priority Improvements

### Generalize Turf Monster's `bin/tm` pattern

Turf Monster has the best "agent does the work" local stack:

- Detached processes.
- Readiness checks.
- Log commands.
- Stripe listener adoption.
- Secret mismatch detection.
- One Sidekiq invariant.

Recommended fix:

- Keep `bin/tm` app-owned for Turf Monster details.
- Add a McRitchie-level wrapper later, such as `bin/agent-stack up turf-monster`, that dispatches to app-owned stack scripts.
- Define a standard output contract: local URL, process status, log paths, and known skipped services.

### Reduce test count drift

READMEs still include exact test counts, which go stale quickly.

Recommended fix:

- Replace exact counts with command names unless the count is generated dynamically.
- Put "what to run" in docs, not "how many tests exist today."

### Normalize credential item names

Current docs now name:

- `agent.heroku`
- `agent.alex.solana`
- `agent.managed_wallet`
- `agent.aws.mcritchie-ses`
- `agent.helius`
- vendor-named items such as `Coinbase Developer Platform`

Recommended fix:

- Treat `agent.solana` as legacy in docs unless verified still used by code/scripts.
- Prefer `agent.<character>.<service>` for character-owned identities.
- Prefer vendor names for shared integrations.

### Make SES the email target, not Resend

Current state:

- Turf Monster already has an SES cutover pattern: `MAIL_TRANSPORT=ses` selects
  SES SMTP, while Resend remains the fallback.
- McRitchie Studio now has the same transport switch, SES helper tasks, and
  `docs/email-delivery.md`.
- The credential inventory already names `agent.aws.mcritchie-ses`.

Recommended fix:

- Treat AWS SES as the primary transport for all transactional email.
- Keep Resend installed only as a rollback path until SES has been stable.
- Verify `mcritchie.studio` and `turfmonster.media` in SES with DKIM/SPF/DMARC.
- Do a provider-level smoke test before flipping production: send a magic link,
  confirm SES acceptance, and confirm Gmail does not place it in spam.

### Move Claude-local skills into neutral form

Found:

- `mcritchie-studio/.claude/skills/nfl-refresh/SKILL.md`
- `mcritchie-studio/.claude/skills/nfl-rebuild/SKILL.md`

Recommended fix:

- Move or copy these into a neutral `.agents/skills/` structure after reviewing their contents.
- Keep Claude-specific skill config only as an adapter if needed.

## Proposed Documentation Architecture

```text
/Users/alex/projects/AGENTS.md
  generated from mcritchie-studio/docs/agents/index.md

mcritchie-studio/docs/agents/
  index.md
  modules/
    culture.md
    credentials.md
    credential-inventory.md
    ports-and-processes.md
    worktrees.md
    testing.md
    deployment.md
    backend-discipline.md
    docs-maintenance.md
  audits/
    first-pass-2026-06-13.md
  maintenance/
    delete-later.md

<repo>/README.md
  human bootstrap and high-level app role

<repo>/RUNBOOK.md
  operational troubleshooting for that repo

<repo>/docs/
  app-specific topic docs and workflows

<repo>/.agents/skills/
  portable-ish workflow instructions, when ready

<repo>/.codex/
  Codex-specific hooks/config, when needed

<repo>/.claude/
  Claude-specific hooks/config, when needed
```

## Recommended Next Edit Wave

1. Fix obvious live drift:
   - `studio-engine` port/domain docs.
   - `turf-vault` README/RUNBOOK live program and signer references.
   - Turf Monster README local-stack guidance.
   - McRitchie `ECOSYSTEM.md` LLM-neutral routing.

2. Add archive banners:
   - Historical ecosystem audits.
   - First-mainnet-launch docs.
   - Prelaunch security audits and prompt artifacts.

3. Promote app-local neutral docs:
   - `turf-monster/docs/LOCAL_STACK.md`
   - `turf-vault/docs/CURRENT_DEPLOYMENT.md`
   - Optional `studio-engine/docs/PORTS_AND_SSO.md` or folded updates to existing docs.

4. Update worktree tooling:
   - Change future worktrees to `.worktrees/<task-slug>`.
   - Preserve the delete-later ledger for existing sibling worktrees until branch/PR disposition is known.

5. Review `.claude/skills/nfl-*` and convert useful workflows into `.agents/skills/`.

## Open Questions For Alex

1. Should `rolio` join the documented McRitchie ecosystem now, or remain outside this cleanup pass?
2. Should historical docs stay in place with banners, move to `docs/archive/`, or be deleted once live facts are promoted?
3. For worktree ports, should task offsets be allocated manually (`3101`, `3102`, ...) or should tooling reserve/check the next free port automatically?
4. Should the next pass edit `CLAUDE.md` files into thin adapters, or leave them untouched until the next Claude session confirms whether `AGENTS.md` is sufficient?

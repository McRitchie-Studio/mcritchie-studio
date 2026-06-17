# Shared Agent Memory

## System Status
- McRitchie Studio initialized: 2026-03-23
- All 4 agents registered and active
- 9 skills cataloged across 5 categories
- API endpoints operational at /api/v1/

## Key Decisions
- Slug-based foreign keys everywhere (no integer FKs between models)
- Task slugs are immutable random hex (not regenerated on save)
- Cost stored as decimal(10,4) for sub-cent API pricing precision
- Dashboard and monitoring pages are public; mutations require auth
- API has no authentication initially (add token auth later)

## Agent Accounts
- Shared Gmail: `team@mcritchie.studio` (all agents)
- Per-agent emails: `admin@` (Alex), `mack@` (Mack), `mason@` (Mason), `turf@` (Turf Monster) — all forward to shared inbox
- 1Password vault under `team@mcritchie.studio` holds Gmail credentials and Solana wallet keypairs for each agent
- Each agent has a dedicated Solana wallet (keypairs in 1Password)

## Conventions
- All timestamps in UTC
- Activity logging after every significant action
- Usage reporting at end of each work session
- Error capture via ErrorLog.capture! with polymorphic context

# McRitchie Studio

Central task management and orchestration hub for the McRitchie AI agent system (Alex, Mack, Mason, Turf Monster).

> **Part of the McRitchie ecosystem.** See [`docs/ECOSYSTEM.md`](docs/ECOSYSTEM.md) for the 5-repo map. This file is the per-repo index — each topic below loads on demand from `docs/topics/`. Original kitchen-sink CLAUDE.md was split on 2026-05-17 per audit Tier 2 #9.

## Quick Reference

- **Dev server**: `bin/rails server` (port 3000). Turf Monster on 3100, Tax Studio planned on 3200.
- **Tests**: `bin/rails test` (~521 runs). See [`docs/topics/testing.md`](docs/topics/testing.md) for invocation gotchas.
- **Deploy**: `git push heroku main` to `mcritchie-studio` (https://app.mcritchie.studio). See [`docs/topics/deployment.md`](docs/topics/deployment.md).
- **Recovery**: [`docs/agents/system/house-burn-down.md`](docs/agents/system/house-burn-down.md) — full fresh-Mac protocol.
- **Current roadmap**: [`docs/agents/system/ecosystem-audit-2026-05-17.md`](docs/agents/system/ecosystem-audit-2026-05-17.md) — tiered audit.

## Topic Index

| File | When to read |
|------|--------------|
| [`docs/topics/deployment.md`](docs/topics/deployment.md) | Dev server, Heroku deployment, env vars, tech stack, public assets |
| [`docs/topics/auth-and-sso.md`](docs/topics/auth-and-sso.md) | Studio engine integration, SSO hub role, login/signup overrides |
| [`docs/topics/theme.md`](docs/topics/theme.md) | Branding, theme colors, navbar, button system, stage-badge palette |
| [`docs/topics/data-model.md`](docs/topics/data-model.md) | All models, slug conventions, transitions, key patterns |
| [`docs/topics/frontend.md`](docs/topics/frontend.md) | JS modules, importmap, AI chat (Alex agent), landing page |
| [`docs/topics/news-pipeline.md`](docs/topics/news-pipeline.md) | News intake → review → process → refine → conclude. Services + AI agents. People search. Kanban focus. |
| [`docs/topics/content-pipeline.md`](docs/topics/content-pipeline.md) | Content idea → hook → script → assets → assembly → posted. Starter Post X + TikTok workflows. |
| [`docs/topics/nfl-pipeline.md`](docs/topics/nfl-pipeline.md) | NFL data ingest (Nflverse + Spotrac + ESPN), coach headshots, cross-ref IDs, duplicate merge, position normalization |
| [`docs/topics/nfl-grading.md`](docs/topics/nfl-grading.md) | PFF grades, proprietary pass/run grades, 12-slot starter picker, defensive formation map, slot labels, depth chart |
| [`docs/topics/routes-and-controllers.md`](docs/topics/routes-and-controllers.md) | All routes (HTML + JSON API), new controller checklist, error handling |
| [`docs/topics/seeds.md`](docs/topics/seeds.md) | `db/seeds/` ordering, what each phase loads, totals, full vs plain seed |
| [`docs/topics/testing.md`](docs/topics/testing.md) | Rails tests, Playwright e2e, fixtures, test password, invocation gotchas |

`docs/agents/` (separate from `docs/topics/`) holds agent-system docs: per-agent role/soul files, system protocols, credentials reference, and the recovery doc.

## Workflow Preferences

- **Debugging**: STOP on bugs — show the issue and ask before fixing
- **Testing**: Write tests alongside features. **Always run `bin/rails test` before committing** — fix failures before creating the commit. A pre-commit hook enforces this, but proactively run tests after changes rather than waiting for the hook.
- **Database**: Migrate and seed freely without asking
- **Git**: Small frequent commits, push immediately. Run `bin/rails test` before every commit — fix failures before committing.
- **UI**: Style as we build using brand palette
- **Decisions**: Present 2-3 options briefly with a recommendation
- **Refactoring**: Proactively clean up code smells

## Session Protocol

When the user signals end of session, review and refactor ALL CLAUDE.md files (and `docs/topics/*.md` since the split) to reflect current state.

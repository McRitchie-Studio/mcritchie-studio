# Testing

> **When to read this:** Writing new tests, debugging failures, or setting up Playwright/CI.

## Certification gates (before `submitted`)

- `bin/fast-check <task>` — the **builder default** (~1 min): runs the tests the branch diff maps to (path convention + class-name grep fallback) + the curated core spine (`config/fast_cert_spine.yml`) + `rubocop` on the **changed files only**, and records a fingerprint-bound `[fast-cert@<fp>]` checks_run line. `bin/dor-check` credits it **only once the PR's GitHub CI is green** (CI runs the full suite + `test:system` per push — it is the full net). `--list` prints the selection without running.
- `bin/full-suite-check <task>` — the CI-independent local cert and release-verification tool: it runs **what CI runs, verbatim** — read from the repo's own `.github/workflows/ci.yml`, today `bin/rails db:test:prepare test test:system` (the entire suite **including the system tier**) — plus FULL `bin/rubocop` (~12 min on the hub), with fingerprint-bound `[full-suite@<fp>]` / `[rubocop@<fp>]` evidence, accepted with or without CI. **It is the same net as CI, not a smaller one** — that is the whole claim of the CI-independent route, and it may never test *less* than CI. (It once did: it hard-coded `bin/rails test`, which **skips `test/system`**, so a builder could take the CI-independent route, go green, and have zero system coverage.) The system tier drives a real headless **Chrome**; a host without one aborts up front as an ENV error, never as a red suite. See `bin/lib/ci_test_command.rb`.
- Never run two local suites concurrently on this machine (parallel certs SIGSEGV Ruby) — serialize via the `/tmp/mcr-full-suite.lock` mkdir convention when sessions overlap.

## Rails Tests

- `bin/rails test` — 596 runs, 1642 assertions, 4 skips
- Test fixtures for users, agents, tasks, news, contents, skills, teams, people, contracts, athletes (in `test/fixtures/`)
- User fixtures may keep `password_digest` because `has_secure_password` still exists as a dormant fallback; app authentication is passwordless.
- `log_in_as(user)` helper for integration tests mints and consumes a magic-link token.
- **Model tests**: task transitions (valid/invalid), news transitions/slug/position/validations, content slug/stages/position/source_news, user (display_name, admin?, avatar_initials, avatar_color, OAuth/`from_omniauth`), slug generation, team/person/contract associations and validations, athlete slug/validations/person association
- **Controller tests**: sessions (signin/logout), magic links, registrations redirect, news (CRUD, stage moves, reorder, refine, conclude, create_content, auth enforcement), contents (CRUD, step actions, stage guards, auth enforcement), tasks (CRUD, stage moves, reorder, auth enforcement), rankings (all position pages, sorting, search, team unit, player impact, confirm draft pick with auth/mock conversion/bench rookie/college expiry), AI Builder Multiple admin JSON.
- **Service tests**: provider/client adapters, PFF/NFL imports, ESPN depth chart scraping, Spotrac sync, signing, athlete utilities, and AI Builder Multiple classifier/fetcher/aggregator/index/CSV export behavior.

## Playwright E2E Tests

- `npm test` — runs all Playwright tests (14 smoke tests)
- `npm run test:headed` — runs with visible browser
- `npm run test:ui` — opens Playwright UI mode
- **Config**: `playwright.config.js` — Chromium only, defaults to port 3000, accepts `E2E_PORT=<port>`, auto-starts test Rails server with local email capture enabled
- **Seed**: `e2e/seed.rb` — 1 admin user (`alex@test.com`), 2 agents, 2 skills, 3 tasks, 2 activities. Idempotent via delete_all.
- **Cleanup**: Playwright seeds into `RAILS_ENV=test`; before running the Rails suite after e2e work, reset with `RAILS_ENV=test bin/rails db:test:purge db:test:prepare`. `bin/full-suite-check` runs that reset automatically before certifying CI's command (`bin/rails db:test:prepare test test:system`).
- **Helper**: `e2e/helpers.js` — `loginWithMagicLink(page, email)` requests a link, reads `/_studio/local_emails.json`, confirms, and consumes it.
- **Spec file**: `e2e/smoke.spec.js` — page loads, passwordless auth, nav links, theme toggle

## Test invocation gotchas

System Ruby 2.6 is on PATH by default on macOS and breaks `bundle exec`. If tests fail with `cannot load such file -- socket` or `Could not find 'bundler' (2.4.19)`, prepend the brew Ruby PATH:

```bash
PATH="/opt/homebrew/opt/ruby@3.3/bin:/opt/homebrew/lib/ruby/gems/3.3.0/bin:$PATH" bin/rails test
```

See `docs/agents/system/house-burn-down.md` gotchas 1 and 5 for context.

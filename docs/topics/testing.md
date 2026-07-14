# Testing

> **When to read this:** Writing new tests, debugging failures, or setting up Playwright/CI.

## Certification gates (before `submitted`)

- `bin/fast-check <task>` — the **builder default** (~1 min): runs the tests the branch diff maps to (path convention + class-name grep fallback) + the curated core spine (`config/fast_cert_spine.yml`) + `rubocop` on the **changed files only**, and records a fingerprint-bound `[fast-cert@<fp>]` checks_run line. `bin/dor-check` credits it **only once the PR's GitHub CI is green** (CI runs the full suite + `test:system` per push — it is the full net). `--list` prints the selection without running.
- `bin/full-suite-check <task>` — the CI-independent local cert and release-verification tool: FULL `bin/rails test` + FULL `bin/rubocop` (~6 min), fingerprint-bound `[full-suite@<fp>]` / `[rubocop@<fp>]` evidence, accepted with or without CI.
- Never run two local suites concurrently on this machine (parallel certs SIGSEGV Ruby) — serialize via the `/tmp/mcr-full-suite.lock` mkdir convention when sessions overlap.

## Rails Tests

- `bin/rails test` — 3,879 runs, 20,782 assertions, 4 skips (measured 2026-07-14; the "596 runs, 1642 assertions" this line used to claim was years stale)
- Test fixtures for users, agents, tasks, news, contents, skills, teams, people, contracts, athletes (in `test/fixtures/`)
- User fixtures may keep `password_digest` because `has_secure_password` still exists as a dormant fallback; app authentication is passwordless.
- `log_in_as(user)` helper for integration tests mints and consumes a magic-link token.
- **Model tests**: task transitions (valid/invalid), news transitions/slug/position/validations, content slug/stages/position/source_news, user (display_name, admin?, avatar_initials, avatar_color, OAuth/`from_omniauth`), slug generation, team/person/contract associations and validations, athlete slug/validations/person association
- **Controller tests**: sessions (signin/logout), magic links, registrations redirect, news (CRUD, stage moves, reorder, refine, conclude, create_content, auth enforcement), contents (CRUD, step actions, stage guards, auth enforcement), tasks (CRUD, stage moves, reorder, auth enforcement), rankings (all position pages, sorting, search, team unit, player impact, confirm draft pick with auth/mock conversion/bench rookie/college expiry), AI Builder Multiple admin JSON.
- **Service tests**: provider/client adapters, PFF/NFL imports, ESPN depth chart scraping, Spotrac sync, signing, athlete utilities, and AI Builder Multiple classifier/fetcher/aggregator/index/CSV export behavior.

## Playwright E2E Tests

- `npm test` — runs all Playwright tests (**70 specs** across 27 spec files)
- `npm run test:headed` — runs with visible browser
- `npm run test:ui` — opens Playwright UI mode
- **CI runs this suite and it BLOCKS MERGE** (the `playwright` job in `.github/workflows/ci.yml`, sharded 3×, on every PR and every push to `main`/`release`). It collects the `e2e` tier that `config/feature_shapes.yml` demands of the `ui+db` and `onchain-vertical` shapes.
- **`@quarantine`**: 18 specs were already rotted when the lane was switched on (2026-07-13) and are excluded in CI via `--grep-invert @quarantine`. So CI runs **51**. That hole is ratcheted by `test/lib/e2e_quarantine_ratchet_test.rb` — the count may fall, never rise — and repair is ticketed at `/tasks/repair-rotted-e2e-specs`. Never add a tag to green a PR; the ratchet goes red.
- **Config**: `playwright.config.js` — Chromium only, defaults to port 3000, accepts `E2E_PORT=<port>`, auto-starts test Rails server with local email capture enabled
- **Seed**: `e2e/seed.rb` — an admin user (`alex@test.com`) plus **22 models across ~20 tables**: agents, skills + assignments, tasks + task_events, activities, agent_activities, agent_actions, action_grades, pokemons, session_mascots, releases, gate_runs, coaches, teams, people, usages, error_logs. Idempotent via `delete_all`. **Eight of those tables have NO fixture** (`action_grades`, `agent_actions`, `agent_activities`, `gate_runs`, `pokemons`, `releases`, `session_mascots`, `task_events`) — do not trust this list to stay current, ask the code: `TestDatabasePurge.unfixtured_tables` names all 45 un-fixtured tables of the 73 in the schema. (The old entry here read "1 admin user, 2 agents, 2 skills, 3 tasks, 2 activities" — that undercount is precisely what let the pollution bug hide.)
- **Cleanup**: none needed — **the minitest database is hermetic by construction.** `test/test_helper.rb` runs `TestDatabasePurge.purge!` at load (and again in each parallel worker), truncating every application table before fixtures load, so rows any other process committed — the e2e seed, a stray `bin/rails runner`, a killed test — cannot reach a test. The old hand-reset ritual (`RAILS_ENV=test bin/rails db:test:purge db:test:prepare` after e2e work) is designed out; you no longer run it. `bin/full-suite-check` still performs that reset before certifying (belt-and-suspenders), but it is no longer the thing that saves you.
- **The purge FAILS CLOSED.** It empties every table, so it refuses to run unless it can *prove* the connection holds this app's test database: `RAILS_ENV` must be `test`, and the connected DB (read back from the live connection) must be the `database:` literal `config/database.yml` declares for `test` — or a legitimate derivative (`…-0` parallel clones, `…_<worktree>` isolated DBs). It raises `TestDatabasePurge::UnsafeDatabase` rather than truncate anything it cannot vouch for. Never rescue that error to "get the suite running": it means the suite was about to empty a database that is not the test database.
- **Helper**: `e2e/helpers.js` — `loginWithMagicLink(page, email)` requests a link, reads `/_studio/local_emails.json`, confirms, and consumes it.
- **Spec files**: 27 under `e2e/` — `smoke.spec.js` (page loads, passwordless auth, nav links, theme toggle) plus the board, task-card, timeline, agent-activity, heartbeat, deployments/live-update, mascot, pricing, release, and testing-gates suites.

## Test invocation gotchas

System Ruby 2.6 is on PATH by default on macOS and breaks `bundle exec`. If tests fail with `cannot load such file -- socket` or `Could not find 'bundler' (2.4.19)`, prepend the brew Ruby PATH:

```bash
PATH="/opt/homebrew/opt/ruby@3.3/bin:/opt/homebrew/lib/ruby/gems/3.3.0/bin:$PATH" bin/rails test
```

See `docs/agents/system/house-burn-down.md` gotchas 1 and 5 for context.

# Runbook -- McRitchie Studio

Troubleshooting guide for autonomous agents. Format: problem, diagnosis, fix.

## Heroku Deploy Failures

**Build error: asset compilation fails**
- Diagnosis: Tailwind CSS build fails during `assets:precompile`. Usually a missing CSS class reference or syntax error in `app/assets/tailwind/application.css`.
- Fix: Run `bin/rails tailwindcss:build` locally to reproduce. Check the error output for the offending file/line. Push the fix and redeploy.

**Migration fails on deploy**
- Diagnosis: `heroku run bin/rails db:migrate --app mcritchie-studio` errors out. Usually a duplicate column or missing dependency.
- Fix: Check `heroku logs --tail --app mcritchie-studio` for the exact SQL error. If a migration was partially applied, connect via `heroku pg:psql --app mcritchie-studio` and inspect `schema_migrations` table.

**Missing RAILS_MASTER_KEY**
- Diagnosis: App crashes on boot with `ActiveSupport::MessageEncryptor::InvalidMessage`.
- Fix: `heroku config:set RAILS_MASTER_KEY=$(cat config/master.key) --app mcritchie-studio`

## Server Won't Start Locally

**Port 3000 already in use**
- Diagnosis: `Address already in use - bind(2) for "127.0.0.1" port 3000`
- Fix: `lsof -i :3000 | grep LISTEN` to find the PID, then `kill -9 <PID>`. Restart with `bin/rails server` or `bin/dev`.

**Missing gems after branch switch**
- Diagnosis: `Could not find gem '...'` or `Bundler::GemNotFound`.
- Fix: `bundle install`. If the studio gem fails, check GitHub connectivity: `git ls-remote https://github.com/amcritchie/studio-engine.git`.

**Database connection refused**
- Diagnosis: `PG::ConnectionBad: could not connect to server`.
- Fix: Check PostgreSQL is running: `brew services list | grep postgresql`. Start it: `brew services start postgresql@14`. Verify database exists: `bin/rails db:create`.

## Theme Cache Stale

**Theme colors not updating after DB change**
- Diagnosis: `ThemeSetting` record was updated but the page still shows old colors.
- Fix: Clear the cache manually: `bin/rails runner "Rails.cache.delete('studio/theme/McRitchie Studio')"`. Or hit the "Regenerate Cache" button at `/admin/theme`. Cache TTL is 1 hour -- it will self-heal eventually.

**Theme not loading at all (no CSS vars)**
- Diagnosis: Page renders with broken colors. `<style>` tag from `studio_theme_css_tag` is missing or empty.
- Fix: Check `ThemeSetting.current` in console. If nil, the `theme_settings` table may be missing: `bin/rails db:migrate`. Check `Studio.theme_config` returns valid defaults.

## SSO Issues

**"Continue as" not appearing on Turf Monster**
- Diagnosis: `sso_user_available?` returns false. Either no `sso_email` in session, or `sso_source` matches the current app.
- Fix: Verify both apps share the same `SECRET_KEY_BASE`. Check `session_store.rb` uses `key: "_studio_session"` with `domain: :all` (dev) or `".mcritchie.studio"` (prod). Log into McRitchie Studio first to populate `sso_*` fields.

**SSO login creates duplicate user**
- Diagnosis: SSO finds or creates by email. If emails differ between apps, a new user is created.
- Fix: Email is the sync key. Ensure the user has the same email in both apps. Users without email (wallet-only) cannot SSO.

## Test Failures

**Fixtures not loading**
- Diagnosis: `ActiveRecord::Fixture::FixtureError` or nil records in tests.
- Fix: `bin/rails db:test:prepare`. If schema is out of date: `bin/rails db:migrate RAILS_ENV=test`.

**Database state pollution between tests**
- Diagnosis: Tests pass individually but fail together.
- Fix: Ensure tests use transactions (default in minitest). Check for `self.use_transactional_tests = false` in the test class. If found, add explicit cleanup in `teardown`.

**Pre-commit hook fails**
- Diagnosis: `bin/rails test` fails during commit. The commit was NOT created.
- Fix: Fix the failing tests. Stage changes and make a NEW commit (do not amend -- the previous commit was not modified).

## Google OAuth Callback Errors

**`OAuth2::Error` or redirect mismatch**
- Diagnosis: Google rejects the callback URL. Common after domain/port changes.
- Fix: Check `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` in `.env`. Verify the callback URL `http://localhost:3000/auth/google_oauth2/callback` (dev) or `https://app.mcritchie.studio/auth/google_oauth2/callback` (prod) is registered in Google Cloud Console.

**`OmniAuth::Strategies::OAuth2::CallbackError`**
- Diagnosis: User denied access or session expired during OAuth flow.
- Fix: This is normal user behavior. The engine's `OmniauthCallbacksController#failure` handles it with a redirect. Check `/auth/failure` route exists (drawn by `Studio.routes`).

## Studio Engine Update Issues

**`bundle update studio-engine` fails**
- Diagnosis: Git authentication or network issue fetching from GitHub.
- Fix: `git ls-remote https://github.com/amcritchie/studio-engine.git` to test connectivity. If it works, try `bundle update studio-engine --verbose` for detailed output. Clear bundler cache: `rm -rf vendor/cache/studio-*`.

**Breaking change after engine update**
- Diagnosis: App crashes on boot after `bundle update studio-engine`. Usually a renamed method or missing config option.
- Fix: Check the studio-engine repo's recent commits: `cd /Users/alex/projects/studio-engine && git log --oneline -10`. Look for config changes in `lib/studio.rb`. Pin to a known-good tag in Gemfile if needed: `gem "studio-engine", git: "...", tag: "v0.X.Y"`.

## Common Rails Errors

**Zeitwerk autoload conflict**
- Diagnosis: `Zeitwerk::NameError` or `expected file ... to define constant ...`. Usually a filename/class name mismatch.
- Fix: Ensure filenames match class names (e.g. `expense_upload.rb` defines `ExpenseUpload`). Engine classes use `Studio::` prefix in `lib/` but not in `app/`. Check `config/initializers/` for explicit requires that may conflict.

**Missing route**
- Diagnosis: `ActionController::RoutingError: No route matches`.
- Fix: `bin/rails routes | grep <path>`. Ensure `Studio.routes(self)` is in `config/routes.rb`. Engine routes are drawn at the point of the `Studio.routes(self)` call -- order matters.

**CSRF token mismatch (422 on POST)**
- Diagnosis: `ActionController::InvalidAuthenticityToken` after form submission. Common with Turbo Drive or stale browser tabs.
- Fix: Ensure forms use `form_with` (includes CSRF token automatically). For JSON endpoints, skip CSRF with `skip_before_action :verify_authenticity_token` or include `X-CSRF-Token` header.

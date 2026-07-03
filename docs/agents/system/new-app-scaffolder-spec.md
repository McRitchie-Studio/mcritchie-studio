# `bin/new-app` Scaffolder Spec (Future Layer)

The current supported registry tool is `mcritchie-studio/bin/register-satellite`.
Start there before building the larger app generator. The 2026-05-17 ecosystem
audit recommended a future `bin/new-app` scaffolder so adding a new satellite
is a single interactive command instead of a manual checklist. This file is the
future-layer spec.

Active rules live in:

- `mcritchie-studio/docs/agents/modules/app-registry.md`
- `mcritchie-studio/config/satellites.yml`
- `studio-engine/docs/NEW_APP_SETUP.md`

Current decision: Tax Studio stays planned at `3200-3299`, Rolio is reserved at
`3300-3399`, and Chain Ops is planned at `3400-3499`. A new managed app should
start at the next open block unless the registry says otherwise.

## What it does

Future single interactive script that:
1. Prompts for the new app's identifier, display name, port, Heroku app name, role, description
2. Calls or preserves `bin/register-satellite` validation for the registry entry
3. Generates the Rails app from a template
4. Provisions the Heroku app and writes a starter set of config vars
5. Adds the `RAILS_MASTER_KEY` to 1Password
6. Prints DNS-setup instructions (operator runs in Google Domains)
7. Cross-links the new repo into `mcritchie-studio/docs/ECOSYSTEM.md` + `house-burn-down.md`

End state: operator can answer the prompts, then visit `http://localhost:<port>` and see the branded Rails app's login screen, ready to consume the engine + accept SSO from the hub.

## Location

Future location: `mcritchie-studio/bin/new-app` (alongside `bin/ecosystem-build`, `bin/setup-1pass-token`, and `bin/register-satellite`).

## Interactive prompts

```
$ bin/new-app
Slug (lowercase, hyphen-separated, will be the GitHub repo name): next-app
Display name: Next App
Emoji (optional):
Local dev port: 3500
Heroku app name (lowercase, hyphen-separated): next-app
Production URL [https://next-app.mcritchie.studio]:
SSO role for new users [viewer]:
One-line description: One-line product summary
Deploy provider [heroku]:
```

After prompts, confirm summary and proceed.

## Steps the script performs

1. **Validate inputs** — slug matches `[a-z][a-z0-9-]*`, primary port starts an unused 100-port block, heroku_app is available (`heroku apps:info --app <name>` returns 404).
2. **Register satellite** — call the same validation used by `bin/register-satellite`; write `status: planned` initially. Flip to `active` only after the repo, env, local stack, and docs are proven.
3. **Generate Rails app** from template:
   ```bash
   rails new ~/projects/<slug> --skip-test --skip-system-test --database=postgresql --template=mcritchie-studio/bin/templates/satellite.rb
   ```
   Template (also new file, `bin/templates/satellite.rb`) does:
   - Adds gems: `tailwindcss-rails`, `studio-engine` (pinned to the current release series), `sentry-ruby`, `sentry-rails`
   - Generates `config/initializers/studio.rb` with the right `app_name`, `session_key`, `configure_sso_user`
   - Generates `config/initializers/sentry.rb`
   - Adds `User` model satisfying the engine contract (see `studio-engine/docs/USER_CONTRACT.md`)
   - Adds `_navbar.html.erb` override pointing back at the hub
   - Adds `gem "solana-studio"` only if `--with-solana` flag is set
   - Runs `db:create db:migrate db:seed`
   - Creates the GitHub repo via `gh repo create amcritchie/<slug> --private`
   - Initial commit + push to main
4. **Provision Heroku app**:
   ```bash
   heroku create <heroku_app> --region us
   heroku addons:create heroku-postgresql:essential-0 --app <heroku_app>
   heroku config:set RAILS_MASTER_KEY=<from new app's config/master.key> --app <heroku_app>
   heroku config:set RAILS_SERVE_STATIC_FILES=true --app <heroku_app>
   ```
5. **Add to 1Password** — store the RAILS_MASTER_KEY as item `<slug>/RAILS_MASTER_KEY` in the `agents` vault.
6. **Cross-link docs**:
   - Update `docs/ECOSYSTEM.md` to add the new repo row + per-repo summary entry
   - Update `docs/agents/system/house-burn-down.md` to add the row in The Ecosystem table
   - Capture any agent-workflow lesson the new app teaches in the **Insight Bank**
     (`bin/atomic-event grade <span> --bank`), not a hand-edited doc; update
     `docs/ECOSYSTEM.md` for ecosystem assumptions
7. **DNS instructions**: print to stdout:
   ```
   Set up DNS:
   1. Open Google Domains → mcritchie.studio → DNS
   2. Add CNAME record: <subdomain> → <heroku_dns_target>
   3. Run: heroku domains:add <subdomain>.mcritchie.studio --app <heroku_app>
   4. Wait ~5 min for ACM to provision SSL
   ```
8. **Flip status: active** in satellites.yml only after `bin/ecosystem-build` should manage the app.
9. **Print final summary** + reminder to add the new app to bin/ecosystem-build's bringup loop (already handled by satellites.yml-driven load).

## Error handling

The script should be idempotent — if it fails partway through, re-running should pick up where it left off. Each step checks "does this already exist?" before creating.

Specific failure modes:
- Heroku app name taken → suggest variants, allow re-prompt
- GitHub repo exists → ask whether to use existing
- DNS setup is operator-manual → print + continue (can't verify)

## Implementation notes

- Use Ruby (not bash) for the scaffolder — it'll talk to YAML, GitHub CLI, Heroku CLI, 1Password CLI, and file generation. Easier in Ruby.
- Add a `--dry-run` flag that prints what would happen without doing it.
- Add a `--non-interactive` mode that reads from a YAML file (useful for CI / scripting).

## Out of scope

- Multi-region Heroku setup (always us-region for now)
- Custom Postgres tier (always essential-0 for new apps; operator upgrades manually)
- Slack/Discord webhook setup (manual; operator follows secrets-rotation runbook)
- Sentry project creation (manual; operator follows Sentry initializer comments)

## Why this is a separate session

Estimated 4-6 hours of focused work. Most of the complexity is in:
1. The Rails template generator (Rails app generator API quirks)
2. The Heroku CLI orchestration (error handling for partial failures)
3. The Ruby script itself (interactive prompts + idempotent restart)

Better to do in one focused session with the time to test on a throwaway slug (`bin/new-app` against `test_studio_temp`) and tear down.

When picking up: start by reading `bin/register-satellite`,
`studio-engine/docs/NEW_APP_SETUP.md`, `mcritchie-studio/Gemfile`,
`config/initializers/studio.rb`, and `app/models/user.rb` to extract what the
template needs to generate. Then write `bin/templates/satellite.rb` first
(smallest scope, tests by `rails new --template=path/to/it`). Then wrap with
`bin/new-app`.

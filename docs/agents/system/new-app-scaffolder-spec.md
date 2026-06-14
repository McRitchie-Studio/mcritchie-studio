# `bin/new-app` Scaffolder Spec (Audit Tier 3 #24)

The 2026-05-17 ecosystem audit recommended building a `bin/new-app` scaffolder so adding a new satellite (Tax Studio, future apps) is a single interactive command instead of a 7-step manual checklist. This file is the spec — concrete enough to execute in a fresh session.

## What it does

Single interactive script that:
1. Prompts for the new app's identifier, display name, port, Heroku app name, role, description
2. Adds the satellites.yml entry (using the schema already established in audit Tier 2 #11)
3. Generates the Rails app from a template
4. Provisions the Heroku app and writes a starter set of config vars
5. Adds the `RAILS_MASTER_KEY` to 1Password
6. Prints DNS-setup instructions (operator runs in Google Domains)
7. Cross-links the new repo into `mcritchie-studio/docs/ECOSYSTEM.md` + `house-burn-down.md`

End state: operator can answer the prompts, then visit `http://localhost:<port>` and see the branded Rails app's login screen, ready to consume the engine + accept SSO from the hub.

## Location

`mcritchie-studio/bin/new-app` (alongside `bin/ecosystem-build`, `bin/setup-1pass-token`).

## Interactive prompts

```
$ bin/new-app
Slug (lowercase, snake_case, will be the GitHub repo name): tax-studio
Display name: Tax Studio
Emoji (optional): 📊
Local dev port: 3003
Heroku app name (lowercase, hyphen-separated): tax-studio
Production URL [https://tax.mcritchie.studio]:
SSO role for new users [viewer]:
One-line description: Tax planning workspace
Deploy provider [heroku]:
```

After prompts, confirm summary and proceed.

## Steps the script performs

1. **Validate inputs** — slug matches `[a-z][a-z0-9_]*`, port is unused, heroku_app is available (`heroku apps:info --app <name>` returns 404).
2. **Add to satellites.yml** (status: `planned` initially; flipped to `active` at end of run if everything succeeds).
3. **Generate Rails app** from template:
   ```bash
   rails new ~/projects/<slug> --skip-test --skip-system-test --database=postgresql --template=mcritchie-studio/bin/templates/satellite.rb
   ```
   Template (also new file, `bin/templates/satellite.rb`) does:
   - Adds gems: `tailwindcss-rails`, `studio` (pinned to current tag), `sentry-ruby`, `sentry-rails`
   - Generates `config/initializers/studio.rb` with the right `app_name`, `session_key`, `configure_sso_user`
   - Generates `config/initializers/sentry.rb`
   - Adds `User` model satisfying the engine contract (see `studio/docs/USER_CONTRACT.md`)
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
   - Update `docs/agents/shared/MEMORY.md` if the new app changes agent workflow or ecosystem assumptions
7. **DNS instructions**: print to stdout:
   ```
   Set up DNS:
   1. Open Google Domains → mcritchie.studio → DNS
   2. Add CNAME record: <subdomain> → <heroku_dns_target>
   3. Run: heroku domains:add <subdomain>.mcritchie.studio --app <heroku_app>
   4. Wait ~5 min for ACM to provision SSL
   ```
8. **Flip status: active** in satellites.yml.
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

When picking up: start by reading `mcritchie-studio/Gemfile` + `config/initializers/studio.rb` + `app/models/user.rb` to extract what the template needs to generate. Then write `bin/templates/satellite.rb` first (smallest scope, tests by `rails new --template=path/to/it`). Then wrap with `bin/new-app`.

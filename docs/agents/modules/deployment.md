# Deployment

Deployment details remain app-owned, but cross-repo agents should know where to start.

## McRitchie Studio

Production app: `mcritchie-studio`
Canonical URL: `https://mcritchie.studio`
Legacy app URL: `https://app.mcritchie.studio`

```bash
git push heroku main
heroku run bin/rails db:migrate --app mcritchie-studio
```

### Root-Domain Launch

`mcritchie.studio` is the canonical McRitchie Studio app host. The previous
Squarespace site is archived at `https://v1.mcritchie.studio`; the old Rails app
host `https://app.mcritchie.studio` remains a legacy alias.

Launch status as of 2026-06-15:

- Production deploy: Heroku release `v63`, commit `4831ebcd`.
- Heroku ACM: certs issued for `mcritchie.studio`, `www.mcritchie.studio`, and
  `app.mcritchie.studio`.
- Rails host config: `APP_HOST=mcritchie.studio`,
  `MAILER_HOST=mcritchie.studio`, and `APP_HOST_ALIASES` includes
  `app.mcritchie.studio`, `www.mcritchie.studio`, and the Heroku fallback host.
- Verified app health: root, `www`, legacy `app`, and Heroku fallback all return
  `200` on `/up` once DNS resolves to Heroku.
- Verified archive health: `v1.mcritchie.studio` is attached to the old
  Squarespace site as its primary domain, has the `www` prefix disabled, uses
  `ext-cust.squarespace.com`, and returns `200`.
- Known propagation caveat: local routers and public resolvers may cache old
  Squarespace records for up to the prior 4-hour TTL. Verify against
  `1.1.1.1` or the authoritative nameservers before changing records again.
- Production auth smoke: `https://mcritchie.studio/signin` returns `200`, and
  a production `POST /magic_link` for `alex@mcritchie.studio` returned
  `{"success":true}`.

Heroku domains for `mcritchie-studio`:

| Hostname | DNS type | Target |
|----------|----------|--------|
| `mcritchie.studio` | ALIAS / ANAME at apex | `human-gooseberry-dpwdkczq4dpjxe0n7qconbut.herokudns.com` |
| `www.mcritchie.studio` | CNAME | `philosophical-anenome-txijca9objmowkzw87zmm2e8.herokudns.com` |
| `app.mcritchie.studio` | CNAME | `dry-newt-78qhw9kfd1r0nqnu4fybesw3.herokudns.com` |

Squarespace archive DNS:

| Hostname | DNS type | Target |
|----------|----------|--------|
| `v1.mcritchie.studio` | CNAME | `ext-cust.squarespace.com` |

Production Heroku config for the cutover:

```bash
heroku config:set \
  APP_HOST=mcritchie.studio \
  MAILER_HOST=mcritchie.studio \
  APP_HOST_ALIASES=app.mcritchie.studio,www.mcritchie.studio,mcritchie-studio-039470649719.herokuapp.com \
  DYNO_HOST=mcritchie-studio-039470649719.herokuapp.com \
  --app mcritchie-studio
```

DNS cutover in Squarespace:

1. Attach `v1.mcritchie.studio` to the Squarespace site before moving the apex.
   Squarespace manages this as `v1` CNAME -> `ext-cust.squarespace.com`. If a
   manually-created `v1` CNAME blocks connection, delete only that `v1` row and
   re-run the Squarespace "Connect subdomain" flow.
2. Replace the four apex `A` records currently pointing at Squarespace with an
   apex `ALIAS`/`ANAME` to Heroku:
   `human-gooseberry-dpwdkczq4dpjxe0n7qconbut.herokudns.com`.
3. Change `www` from Squarespace to the Heroku CNAME target if `www` should
   launch Rails alongside the apex. Remove `www.mcritchie.studio` from
   `APP_HOST_ALIASES` if `www` intentionally stays on Squarespace.
4. Run `heroku certs:auto --app mcritchie-studio` until ACM shows issued certs
   for every Heroku-hosted hostname.
5. Verify:

   ```bash
   dig +short @1.1.1.1 mcritchie.studio A
   dig +short @1.1.1.1 www.mcritchie.studio CNAME
   dig +short @1.1.1.1 v1.mcritchie.studio CNAME
   curl -I https://mcritchie.studio/up
   curl -I https://www.mcritchie.studio/up
   curl -I https://app.mcritchie.studio/up
   curl -I https://v1.mcritchie.studio
   ```

   If local DNS is stale but public DNS is correct, force a Heroku routing check:

   ```bash
   curl -I --resolve mcritchie.studio:443:76.223.57.73 https://mcritchie.studio/up
   curl -I --resolve www.mcritchie.studio:443:76.223.57.73 https://www.mcritchie.studio/up
   ```

6. Smoke auth after DNS settles:

   ```bash
   curl -I https://mcritchie.studio/signin
   ```

   Then request one production magic link from the browser and confirm the email
   link uses `https://mcritchie.studio`.

## Turf Monster

Production app: `turf-monster-mainnet`
Canonical URL: `https://turfmonster.media`
Legacy app URL: `https://app.turfmonster.media`
Archive URL: `https://v1.turfmonster.media`

Use `turf-monster/bin/deploy`; do not hand-push around its preflight checks for real-money flows.

### Root-Domain Launch

Target state:

- `turfmonster.media` is the canonical Turf Monster Rails app host.
- `app.turfmonster.media` remains a legacy Rails alias while provider dashboards,
  saved links, and allowlists migrate.
- `v1.turfmonster.media` serves the previous Turf Monster landing site on the
  old Heroku app `limitless-tundra-34071`.

Known Heroku domains for the cutover:

| Hostname | Heroku app | DNS type | Target |
|----------|------------|----------|--------|
| `v1.turfmonster.media` | `limitless-tundra-34071` | CNAME | `whispering-savannah-euqsutzic06i9306g89db3ug.herokudns.com` |
| `app.turfmonster.media` | `turf-monster-mainnet` | CNAME | `evolutionary-endive-vck8w1u6epmos2i4lh68goot.herokudns.com` |

Cutover sequence:

1. Deploy Turf Monster with production host-alias support.
2. Set `APP_HOST=turfmonster.media`, `MAILER_HOST=turfmonster.media`, and
   `APP_HOST_ALIASES=app.turfmonster.media` on `turf-monster-mainnet`.
3. Create DNS `v1` CNAME to
   `whispering-savannah-euqsutzic06i9306g89db3ug.herokudns.com` and verify the
   old landing site answers at `https://v1.turfmonster.media`.
4. Remove `turfmonster.media` from old Heroku app `limitless-tundra-34071`,
   add it to `turf-monster-mainnet`, then update apex DNS at Name.com to the
   Heroku target printed by `heroku domains --app turf-monster-mainnet`.
5. Run `heroku certs:auto --app turf-monster-mainnet` until ACM is issued for
   `turfmonster.media` and `app.turfmonster.media`.
6. Verify:

   ```bash
   dig @ns1psw.name.com turfmonster.media A +short
   dig @ns1psw.name.com app.turfmonster.media CNAME +short
   dig @ns1psw.name.com v1.turfmonster.media CNAME +short
   curl -I https://turfmonster.media/up
   curl -I https://app.turfmonster.media/up
   curl -I https://v1.turfmonster.media
   ```

## Rule

Deploys, gem publishes, provider changes, and production env-var changes are
Release-lane work. A feature agent can recommend deploy, but only the designated
release conductor should run it after explicit approval from Mr. McRitchie or an
already-approved rollout prompt. Alex's `full-cycle` launcher and Avi's
`production-deploy` and `deploy-with-task` acts are such pre-approved production
prompts; `pr-review` and Steffon's `qa-release` sweep are not — they stop before
prod.
Gem publishes specifically are **part of**
"Run Deployment" — they ride a release as first-class members and are published
producer-first by `bin/release ship` (see below), not as a separate ad-hoc step.

## QA And Production URLs

`mcritchie-studio/config/qa_environments.yml` is the source of truth for stable
QA servers and production URLs used by `bin/qa-server`, `bin/release`, and
`bin/prod-smoke`.

- QA servers use `https://qa.<canonical-host>` and set `QA_ENV=true` while still
  running Rails in production mode.
- Production URLs use the canonical public host: `https://mcritchie.studio` for
  the hub and `https://turfmonster.media` for Turf Monster.
- Legacy `app.*` hosts may stay in `APP_HOST_ALIASES` and provider dashboards
  during migration, but they are aliases, not the production target in release
  metadata or post-ship smoke checks.

## Release builder autonomy

QA assembly autonomy is deterministic config, not agent judgment. The policy
lives in `config/release_builder.yml` and is read by `Release::BuilderPolicy`:
one reviewed task, one repo, and no blocked risk tags can proceed to QA assembly
automatically; anything broader is a proposal that waits for operator
confirmation. Production ship remains operator-gated regardless of that QA
decision unless the session uses the explicit `full-cycle` production
launcher or another already-approved rollout prompt.

## Releasing a gem (producer-first)

Gems (`studio-engine`, `solana-studio`) are **producers**; the apps that depend
on them are **consumers**. A release ships them **producer-first** — the gem is
published to RubyGems *before* any consuming app deploys, so the app always
builds against the just-published version. The classification is the registry at
`config/release_repos.yml` (read by `Release::Repos`).

How a gem rides a release:

1. **The gem task is a normal task.** Its PR/branch lives in the gem's *own*
   repo (e.g. `studio-engine`), not in `mcritchie-studio`. Shape `library`, and
   the **version bump lives in that PR** — `lib/studio/version.rb` for
   studio-engine, the `.gemspec` for solana-studio (the registry's
   `version_file`). It is reviewed → `reviewed` like any other task.
2. **Prepare adds it as a member, skipping the merge.** `bin/release prepare`
   adds the gem to the release record but does **not** merge a branch for it (it
   has none here). The gem is QA'd indirectly through a consuming app — assemble
   the consumer (or a QA-only spike) in the same release so the gem is exercised
   end-to-end against the candidate.
3. **Run Deployment publishes gems first, gated.** `bin/release ship` orders
   members gems-before-apps (honoring `dependencies`) and, before any app
   deploy, for each gem member: prints the gem + target version, asks
   `Publish <repo> <version> to RubyGems?` (approval-gated — `--yes`/`--dry-run`
   auto-confirm), runs the gem's build (studio-engine: `bin/release-check
   --build`; otherwise `gem build <gemspec>`), `gem push`es it, and tags
   `v<version>` in the gem repo. A failed build/push **aborts the ship** before
   any app deploys.
4. **Consumers re-pin and deploy.** After the gem is on RubyGems, the consuming
   apps bump their `Gemfile` to `~> x.y`, `bundle`, and deploy — either as app
   members of the same release or as fast-follow tasks. Never deploy a consumer
   ahead of its gem.

Operational notes:

- Run `ship` from a **primary checkout**, not a worktree: the gem repos are
  resolved as siblings of `mcritchie-studio` at the projects root
  (`/Users/alex/projects/<repo>`).
- `gem push` requires a logged-in RubyGems credential (`gem signin`). A
  "version already published" error means the gem PR didn't bump its
  `version_file` — fix the version, don't re-push.
- The manual gem build remains documented in `studio-engine/docs/RELEASE.md`;
  `bin/release ship` automates that path (build → push → tag) as the release
  conductor's producer-first step.

## QA Servers

Dedicated QA servers are tracked in `mcritchie-studio/config/qa_environments.yml`.
They are stable Heroku apps used after PR review and before production rollout.
Use `bin/qa-server` from McRitchie Studio:

```bash
bin/qa-server list
bin/qa-server plan mcritchie-studio
bin/qa-server provision mcritchie-studio --yes
bin/qa-server status turf-monster
bin/qa-server status rolio
bin/qa-server deploy turf-monster origin/main --yes
bin/qa-server deploy rolio origin/release --yes
```

QA deploys are external writes, but they are not production deploys. They should
use QA Heroku apps only, with production-like Rails boot and QA-safe config.
Production deploy remains a separate explicit approval after Mr. McRitchie
reviews the QA URL.

Production deploy conductors should send Release Notes through McRitchie
Studio's authenticated task-board API after successful production verification:

```bash
api POST /api/v1/release_notes '{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-abc123def456"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
  "dry_run": true
}'
```

Review the returned `message`, then repeat without `dry_run` to post the
canonical Discord message. The API groups linked task titles by application and
links tasks to their production McRitchie Studio task pages. Production uses
`DISCORD_RELEASE_NOTES_WEBHOOK_URL`, with `DISCORD_DEPLOY_WEBHOOK_URL` as a
compatibility fallback. Never commit webhook URLs.

Current intended QA apps:

| App | QA Heroku app | QA URL | Safety profile |
|-----|---------------|--------|----------------|
| McRitchie Studio | `mcritchie-studio-qa` | `https://qa.mcritchie.studio` | Hub QA, real low-volume auth email |
| Turf Monster | `turf-monster-qa` | `https://qa.turfmonster.media` | Devnet, `PAYMENT_PROVIDER=none`, no real-money checkout |
| Rolio | `rolio-qa` | `https://rolio-qa-58beede9dc0b.herokuapp.com` | Demo QA, SQLite data is ephemeral |

Current Heroku-generated fallback URLs:

| App | Heroku URL |
|-----|------------|
| McRitchie Studio | `https://mcritchie-studio-qa-26cedb6e8fdc.herokuapp.com` |
| Turf Monster | `https://turf-monster-qa-93e18f3ae318.herokuapp.com` |
| Rolio | `https://rolio-qa-58beede9dc0b.herokuapp.com` |

Provision each QA app once with `bin/qa-server provision <app> --yes`. The
helper creates the Heroku app, attaches the app-owned QA addons, sets non-secret
registry config, copies required secret values from the app's local `.env` or
process env without printing values, adds the custom Heroku domain, and enables
Heroku Automated Certificate Management for HTTPS.

After `provision`, run `bin/qa-server status <app>` and create the required DNS
`CNAME` for each QA hostname to the Heroku DNS target that status reports. The
default `*.herokuapp.com` host remains registered as `DYNO_HOST` where the app
uses that env contract, so Rails host authorization and `/up` checks keep
working while DNS propagates. Rolio currently has no custom domain, so its
Heroku-generated QA/prod URLs are the canonical review URLs.

Current DNS CNAME targets:

| Hostname | CNAME target |
|----------|--------------|
| `qa.mcritchie.studio` | `still-peafowl-p2kwpj56ihp5pdt4bcougntu.herokudns.com` |
| `qa.turfmonster.media` | `encircled-avocado-2ciqghsd1qrzyecpjhz9negz.herokudns.com` |

Rolio has no DNS row yet. Keep using
`https://rolio-qa-58beede9dc0b.herokuapp.com` for QA and
`https://rolio-prod-82e96784b462.herokuapp.com` for production until a domain is
approved.

QA servers should use Resend fallback through `team@mcritchie.studio` for
low-volume magic-link/auth proof until `studio-engine` supports production-safe
email capture on Heroku QA. Do not copy production payment or mainnet Solana
settings into Turf Monster QA. Turf Monster QA runs on devnet and derives
`EXPECTED_IDL_HASH` from `config/turf_vault.idl.json` during provisioning.
Turf Monster QA uses `heroku-redis:mini`; Redis data is intentionally
non-persistent because QA can be rebooted and reseeded often. Rolio uses SQLite
for the hosted demo runtime; data is intentionally ephemeral on Heroku until a
persistent database task replaces it.

If deployment changes a provider, domain, callback URL, env var, or local port, update:

- `mcritchie-studio/config/satellites.yml`
- `mcritchie-studio/config/qa_environments.yml`
- `mcritchie-studio/docs/ECOSYSTEM.md`
- the app README/runbook
- any provider-specific docs under the app's `docs/`

## GitHub Actions panel + prod-deploy approval gate

`/deployments` carries a live GitHub Actions panel (`_github_actions_panel`) —
the latest run per workflow (CI / QA Deploy / Production Deploy), status-pilled
and REPLACE-broadcast over Turbo Streams. It is fed by webhooks, not polling:
GitHub POSTs to `/api/v1/github/webhook` (`GithubWebhooksController`, HMAC-verified
against `GITHUB_WEBHOOK_SECRET`), which enqueues `GithubWorkflowRunIngestJob` for an
idempotent, monotonic upsert into `GithubWorkflowRun`.

**Prod-deploy approval gate.** When a run reaches the `production` environment's
required-reviewer gate, GitHub delivers a `deployment_review` (standard
environment) or `deployment_protection_rule` (custom rule) event. The same
ingest job stamps `pending_environment` on the run, so the panel shows an amber
**awaiting approval** row, and nudges Discord (see below). Admins get an
**Approve deploy** button that POSTs `/deployments/:run_id/approve`
(`GithubDeploymentsController`, admin-gated). The controller reads the run's
pending deployments and approves them via GitHub
`POST /repos/{owner}/{repo}/actions/runs/{run_id}/pending_deployments`
(`state=approved`), authenticated with the agent PAT `GITHUB_TOKEN` (1Password
`agent.github` field `personal-access-token`). Approving optimistically clears the
local gate; GitHub's follow-up `deployment_review approved` / `workflow_run`
webhooks reconcile it.

**Env vars for this vertical:**

| Var | Purpose |
|-----|---------|
| `GITHUB_WEBHOOK_SECRET` | HMAC secret verifying webhook deliveries (fail-closed). |
| `GITHUB_TOKEN` | Agent PAT used to approve pending deployments. |
| `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL` | qa-chatter channel for the "awaiting approval" nudge (falls back to `DISCORD_RELEASE_NOTES_WEBHOOK_URL`). |

The Discord nudge (`Devops::DeployApprovalNotifier`) is a no-op when its webhook
is unset and never raises — a delivery failure logs to `ErrorLog`. Never commit
webhook URLs or the PAT.

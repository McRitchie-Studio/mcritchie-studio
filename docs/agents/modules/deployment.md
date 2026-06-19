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

Use `turf-monster/bin/deploy`; do not hand-push around its preflight checks for real-money flows.

## Rule

Deploys, gem publishes, provider changes, and production env-var changes are
Release-lane work. A feature agent can recommend deploy, but only the designated
release conductor should run it after explicit approval from Mr. McRitchie or an
already-approved rollout prompt.

## QA Servers

Dedicated QA servers are tracked in `mcritchie-studio/config/qa_environments.yml`.
They are stable Heroku apps used after PR review and before production rollout.
Use `bin/qa-server` from McRitchie Studio:

```bash
bin/qa-server list
bin/qa-server plan mcritchie-studio
bin/qa-server provision mcritchie-studio --yes
bin/qa-server status turf-monster
bin/qa-server deploy turf-monster origin/main --yes
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
  "release_train": "2026-06-18-devops-tooling",
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

Current Heroku-generated fallback URLs:

| App | Heroku URL |
|-----|------------|
| McRitchie Studio | `https://mcritchie-studio-qa-26cedb6e8fdc.herokuapp.com` |
| Turf Monster | `https://turf-monster-qa-93e18f3ae318.herokuapp.com` |

Provision each QA app once with `bin/qa-server provision <app> --yes`. The
helper creates the Heroku app, attaches the app-owned QA addons, sets non-secret
registry config, copies required secret values from the app's local `.env` or
process env without printing values, adds the custom Heroku domain, and enables
Heroku Automated Certificate Management for HTTPS.

After `provision`, run `bin/qa-server status <app>` and create the required DNS
`CNAME` for each QA hostname to the Heroku DNS target that status reports. The
default `*.herokuapp.com` host remains registered as `DYNO_HOST` so Rails host
authorization and `/up` checks keep working while DNS propagates.

Current DNS CNAME targets:

| Hostname | CNAME target |
|----------|--------------|
| `qa.mcritchie.studio` | `still-peafowl-p2kwpj56ihp5pdt4bcougntu.herokudns.com` |
| `qa.turfmonster.media` | `encircled-avocado-2ciqghsd1qrzyecpjhz9negz.herokudns.com` |

QA servers should use Resend fallback through `team@mcritchie.studio` for
low-volume magic-link/auth proof until `studio-engine` supports production-safe
email capture on Heroku QA. Do not copy production payment or mainnet Solana
settings into Turf Monster QA. Turf Monster QA runs on devnet and derives
`EXPECTED_IDL_HASH` from `config/turf_vault.idl.json` during provisioning.
Turf Monster QA uses `heroku-redis:mini`; Redis data is intentionally
non-persistent because QA can be rebooted and reseeded often.

If deployment changes a provider, domain, callback URL, env var, or local port, update:

- `mcritchie-studio/config/satellites.yml`
- `mcritchie-studio/config/qa_environments.yml`
- `mcritchie-studio/docs/ECOSYSTEM.md`
- the app README/runbook
- any provider-specific docs under the app's `docs/`

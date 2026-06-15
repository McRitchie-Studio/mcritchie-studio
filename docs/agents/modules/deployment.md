# Deployment

Deployment details remain app-owned, but cross-repo agents should know where to start.

## McRitchie Studio

Production app: `mcritchie-studio`

```bash
git push heroku main
heroku run bin/rails db:migrate --app mcritchie-studio
```

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
process env without printing values, and adds the custom Heroku domain.

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

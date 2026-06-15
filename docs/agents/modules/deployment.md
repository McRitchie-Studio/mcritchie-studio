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
| McRitchie Studio | `mcritchie-studio-qa` | `https://mcritchie-studio-qa.herokuapp.com` | Hub QA, real low-volume auth email |
| Turf Monster | `turf-monster-qa` | `https://turf-monster-qa.herokuapp.com` | Devnet, `PAYMENT_PROVIDER=none`, no real-money checkout |

QA servers should use Resend fallback through `team@mcritchie.studio` for
low-volume magic-link/auth proof until `studio-engine` supports production-safe
email capture on Heroku QA. Do not copy production payment or mainnet Solana
settings into Turf Monster QA.

If deployment changes a provider, domain, callback URL, env var, or local port, update:

- `mcritchie-studio/config/satellites.yml`
- `mcritchie-studio/config/qa_environments.yml`
- `mcritchie-studio/docs/ECOSYSTEM.md`
- the app README/runbook
- any provider-specific docs under the app's `docs/`

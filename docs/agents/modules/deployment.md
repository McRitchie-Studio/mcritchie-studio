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

If deployment changes a provider, domain, callback URL, env var, or local port, update:

- `mcritchie-studio/config/satellites.yml`
- `mcritchie-studio/docs/ECOSYSTEM.md`
- the app README/runbook
- any provider-specific docs under the app's `docs/`

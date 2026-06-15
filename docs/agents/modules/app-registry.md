# App Registry

The managed app registry lives in `mcritchie-studio/config/satellites.yml`.
It is the source of truth for satellite apps, their primary ports, reserved
port ranges, deploy provider, production URL, SSO role, and lifecycle status.

McRitchie Studio itself is the implicit hub at `3000-3099`; it does not appear
in `config/satellites.yml`.

## Current Decisions

| App | Registry status | Primary port | Reserved range | Notes |
|-----|-----------------|--------------|----------------|-------|
| McRitchie Studio | implicit active hub | 3000 | 3000-3099 | Bootstrap/docs anchor |
| Turf Monster | active satellite | 3100 | 3100-3199 | Managed by `bin/ecosystem-build` |
| Tax Studio | planned satellite | 3200 | 3200-3299 | Keep reserved unless the app is deliberately dropped |
| Chain Ops | planned satellite | 3300 | 3300-3399 | Solana environment control plane; v1 localnet utility |
| Rolio | unmanaged candidate | 3020 today | 3400-3499 if promoted | Do not add until the product decision is explicit |

Do not reuse `3200-3299` or `3300-3399` for Rolio while Tax Studio and Chain Ops
remain planned. If Rolio joins the managed stack, move it to `3400` as its
primary port and add it to `config/satellites.yml`.

## Lifecycle Status

- `active`: `bin/ecosystem-build` clones/restores/bundles the app, and the hub
  shows it in satellite links.
- `planned`: the app has a reserved block and durable metadata, but the
  ecosystem build and hub UI ignore it.
- Unmanaged candidate: the app may exist locally, but it is not part of the
  rebuild contract. Keep app-specific docs in that repo and avoid adding it to
  shared automation until it is promoted.

## Registering An App

Use `bin/register-satellite` from `mcritchie-studio` before creating new
automation or hand-editing the registry.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/register-satellite --list
bin/register-satellite \
  --slug rolio \
  --display-name Rolio \
  --port 3300 \
  --heroku-app rolio \
  --production-url https://rolio.mcritchie.studio \
  --description "Relationship operating workspace" \
  --dry-run
```

The command is dry-run by default. Re-run with `--write` only after the range,
production URL, and status are correct. New entries default to `status: planned`.

After registration, follow `studio-engine/docs/NEW_APP_SETUP.md` for the app
itself. Keep the registry status as `planned` until:

- the repo exists locally and on GitHub
- the app boots on its primary port
- the `.env`/credential restore path is documented
- the app README points back to `/Users/alex/projects/AGENTS.md`
- the production app and DNS target are real, if this is a deployed app

Flip to `active` only when `bin/ecosystem-build` should manage the app and the
hub should expose it in satellite links.

## Future `bin/new-app`

`bin/register-satellite` is the current contract. A future `bin/new-app` can
generate the Rails app, Heroku/GitHub resources, 1Password items, and docs, but
it should call or preserve the same registry rules instead of inventing another
app list.

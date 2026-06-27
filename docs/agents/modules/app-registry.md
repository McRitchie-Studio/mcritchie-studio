# App Registry

The managed app registry lives in `mcritchie-studio/config/satellites.yml`.
It is the source of truth for satellite apps, their primary ports, reserved
port ranges, deploy provider, production URL, SSO role, and lifecycle status.

McRitchie Studio itself is the implicit hub at `3000-3099`; it does not appear
in `config/satellites.yml`.

## Status-line identity (App model)

Per-app **status-line color + emoji** live in the `App` model
(`app/models/app.rb`, seeded by `db/seeds/00_apps.rb`) — the canonical source
`bin/statusline` uses to tint the app slug so a glance tells you the app:
McRitchie Studio lavender, Turf Monster green, etc. This is *separate* from
`config/satellites.yml` / the `APP_OVERRIDES` hash in `bin/agent-worktree` (ports
+ deploy metadata): edit colors here, ports there.

The color rides to the status line without DB access (`bin/task` and
`bin/agent-worktree` are API clients): `Task#sync_app_identity` stamps
`devops.app_color` from the task's first repository on every save, so the marker
and `.agent-context.json` carry it the same way the Pokémon mascot's signature
color does. A brand-new Claude session (no task yet) adopts `App.default`
(`mcritchie-studio`) via the SessionStart hook → `bin/task session-mascot`.
Codex sessions expose `CODEX_THREAD_ID`; `bin/install-agent-docs` keeps Codex's
footer on the built-in `thread-title` item and installs a managed
`SessionStart` hook to `bin/codex-session-title`. That hook mirrors the same
marker into Codex's title on startup/resume and is trusted by Codex policy, so
the mascot can appear in a fresh session without a `/hooks` review step. When
`/etc/codex/requirements.toml` is not writable, the installer stages the managed
requirements block under `~/.codex/`, prints the admin install note, and installs
a user-level `~/.codex/hooks.json` fallback so organic sessions still get a
mascot on machines without the managed file.

Run the kickoff wrapper manually only when you want to force or inspect the
current marker:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/session-kickoff
```

To "act as" a soul instead of the session's Pokémon, set a **persona**:
`bin/task create --persona jasper` (also on `update`). The server stamps the
agent's name + glyph + tint (`Agent#emoji` / `Agent#status_color`, seeded in
`db/seeds/02_agents.rb`) as the status-line mascot, and `bin/statusline` sets the
terminal tab title to the same emoji + name. A new task without `--persona`
reverts to the session's Pokémon, and `bin/task update <slug> --persona none`
(also `clear`/`off`/`-`) reverts mid-task. For a session-level Codex/Claude marker
before a task exists, use:

```bash
bin/session-kickoff jasper   # show Jasper now
bin/session-kickoff pokemon  # return to the Pokémon
```

`--persona` is distinct from `--agent`, which sets the task owner (`agent_slug`).

## Current Decisions

| App | Registry status | Primary port | Reserved range | Notes |
|-----|-----------------|--------------|----------------|-------|
| McRitchie Studio | implicit active hub | 3000 | 3000-3099 | Bootstrap/docs anchor |
| Turf Monster | active satellite | 3100 | 3100-3199 | Managed by `bin/ecosystem-build` |
| Tax Studio | planned satellite | 3200 | 3200-3299 | Keep reserved unless the app is deliberately dropped |
| Chain Ops | planned satellite | 3300 | 3300-3399 | Solana environment control plane; v1 localnet utility |
| 📇 Rolio | unmanaged candidate | 3020 today | 3400-3499 if promoted | Standalone/client app; promote deliberately — see the onboarding SOP |

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

## Unmanaged candidate → managed satellite

An app starts life in one of two **tiers** (full decision table:
[`../system/new-app-onboarding-sop.md`](../system/new-app-onboarding-sop.md)):

- **Standalone / client app** — its own repo, **no `studio-engine`**, PRs into
  `main`, lite DoR, owns its runtime + deploy, eventual handoff to a client. It
  uses the studio task board + worktrees + process but is **never** added to
  `config/satellites.yml`. It lives here as an **unmanaged candidate** so the
  decision is recorded, not re-litigated. Rolio (📇) is the reference case.
- **Managed satellite** — registered in `config/satellites.yml`, persistent
  `release` branch, studio infra (`studio-engine` + SSO), Avi QA, full
  `bin/dor-check`, studio DevOps owns the deploy.

**Promotion** (candidate → satellite) is deliberate, not a default. Before
flipping a candidate into the managed stack, the readiness checklist in the
onboarding SOP must pass — repo on GitHub, boots on its primary port,
`.env`/credential restore documented, README points back at
`/Users/alex/projects/AGENTS.md`, parked operator identities seeded, real
production target + DNS. Only then register it with `bin/register-satellite` at
`status: planned` and follow the **Registering An App** steps below. When you do
register a promoted app, carry its emoji into the `config/satellites.yml`
`emoji:` field so the navbar matches the registry (on promotion, Rolio → `📇`).

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
- the app defines parked/core identities for `alex@mcritchie.studio` and
  `team@mcritchie.studio`, with any app-specific wallet fields wired so first
  email, Google, or wallet login adopts the seeded row instead of creating a
  fresh operator account
- the production app and DNS target are real, if this is a deployed app

Flip to `active` only when `bin/ecosystem-build` should manage the app and the
hub should expose it in satellite links.

## Future `bin/new-app`

`bin/register-satellite` is the current contract. A future `bin/new-app` can
generate the Rails app, Heroku/GitHub resources, 1Password items, and docs, but
it should call or preserve the same registry rules instead of inventing another
app list.

The generated app should also scaffold a parked identity constant on `User`, a
seed file that consumes that constant, and focused tests proving that a known
email or wallet login adopts the parked row. This is now part of the managed app
contract, not an app-specific convenience.

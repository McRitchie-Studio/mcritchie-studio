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
Codex sessions expose hook payloads; `bin/agent-runtime install` keeps Codex's
footer configured with the built-in `thread-title` item and installs a managed
`SessionStart` hook plus a `PostToolUse` refresh hook to
`bin/codex-session-title`. That Codex adapter delegates marker resolution to the
shared provider `bin/agent-marker current`, then mirrors the marker into Codex's
persisted local thread title. Stock Codex CLI 0.142.3 renders
SessionStart `additionalContext` as visible `hook context`, so the hook does not
use it for mascot identity. Stock 0.142.3 also keeps the live footer thread name
in memory after session configuration; a SQLite title update does not repaint
that already-running footer, although resume reloads the persisted title and
shows the Pokémon marker.

Sub-agent sessions can declare their parent with `parent_session_id` on
`POST /api/v1/sessions/:session_id/mascot`; `bin/task session-mascot` forwards
`MCRITCHIE_PARENT_SESSION_ID` (also accepting `AGENT_PARENT_SESSION_ID`,
`CODEX_PARENT_THREAD_ID`, and `CLAUDE_PARENT_SESSION_ID`). When a parent session
already has a Pokémon, the child draws from that parent's Gen-1 evolution tree:
siblings avoid duplicate available evolutions, single-member trees reuse the
parent mascot, and exhausted trees sample the tree again. The Codex title hook
forwards common parent fields from hook JSON, including `parent_session_id` and
`parentThreadId`.

For local Codex installs patched with the McRitchie `threadName` hook runtime
(`docs/agents/patches/codex-0.142.3-session-start-thread-name.patch`),
enable live fresh-session and post-task repainting by creating:

```bash
touch ~/.codex/mcritchie-live-thread-title.enabled
```

With that sentinel present, `bin/codex-session-title` emits:

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","threadName":"<marker>"}}
```

For post-command refreshes the hook emits the same shape with
`"hookEventName":"PostToolUse"`, which lets task creation update the live footer
with the feature slug in the same session. The patched runtime normalizes and
persists that name through Codex's thread store, records the same marker as
hidden developer context for the first model turn, then sends a silent live
`ThreadNameUpdated` event so the footer repaints without adding hook context or
rename history to the transcript. Remove the
sentinel to fall back to stock-compatible silent persistence:

```bash
rm -f ~/.codex/mcritchie-live-thread-title.enabled
```

When `/etc/codex/requirements.toml` is not writable, the installer stages the
managed requirements block under `~/.codex/`, prints the admin install note, and
installs a user-level `~/.codex/hooks.json` fallback so organic sessions still
get a mascot on machines without the managed file.

Fresh-machine operator surface:

```bash
bin/agent-runtime install
bin/agent-runtime doctor
bin/agent-marker current --format title
```

Codex updates are opt-in because stock updates can replace the patched runtime
that repaints the live Pokemon marker. Use
[`codex-updates.md`](codex-updates.md) and `bin/codex-update` instead of the
startup update prompt.

`bin/install-agent-docs` remains the lower-level copy/drift implementation that
`agent-runtime` calls. Request copy for official stock-Codex `threadName` hook
support lives in
[`codex-thread-title-request.md`](codex-thread-title-request.md).

Run the kickoff wrapper manually only when you want to force or inspect the
current marker:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/session-kickoff
```

You should rarely need it. A `SessionStart` hook draws the mascot, and because
`bin/task session-mascot` swallows every error to keep a session from ever
failing to start, a board that is briefly unreachable used to leave the session
with no mascot at all — silently, until a human noticed. `bin/statusline` now
heals that: a render with no mascot and no worktree desk redraws it, throttled to
once per `STATUSLINE_MASCOT_HEAL_THROTTLE` seconds (default 45) and detached, so
a down board is retried rather than hammered. A failed heal still burns its
window, so the mascot can take one throttle period to appear.

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
| 📇 Rolio | release-managed standalone with reserved satellite range | 3300 | 3300-3399 | Dormant since the 2026-07-03 audit; QA/prod in release registries; satellite range protected until promoted |
| Chain Ops | planned satellite | 3400 | 3400-3499 | Solana environment control plane; v1 localnet utility |
| 🏭 McRitchie Industries | **active managed satellite** | 3500 | 3500-3599 (3510 reserved — MSAA squatter) | Confidential business knowledge base — the store of record for all business data, documentation, and context: acquisitions the flagship domain, plus companies, financials, and client records, kept as version-controlled `business-data/` files and the app DB. Replaces the retired `acquisition-studio` prototype and inherits its range. Tier decision (2026-07-29, hosting-onboarding task): **managed satellite** — studio-engine + SSO runtime, auth enforced app-wide, three-rung ladder from birth, registered in `config/satellites.yml` (active), release-conductor deploys via `config/release_repos.yml` (git_push_heroku) + `config/qa_environments.yml` (Heroku `mcritchie-industries-qa` / `mcritchie-industries`; canonical host `www.mcritchie.industries`). Repo `McRitchie-Studio/mcritchie-industries` (private) |

Do not reuse `3200-3599`. Rolio is already in `config/satellites.yml` with
`status: reserved`, which protects its port block without adding it to the
managed rebuild or hub navigation. Rolio is also release-managed for Heroku
deploys through `config/release_repos.yml` and `config/qa_environments.yml`;
that release metadata does not make it an active Studio Engine satellite.
Rolio has been **dormant** since the 2026-07-03 audit: its 44 board tasks are
archived, dependabot config is removed, and its Heroku dynos (`rolio-prod`,
`rolio-qa`) remain up pending the operator-reserved scale-down — Mr. McRitchie
runs `heroku ps:scale web=0` on both apps himself. Nothing needs draining or
backup first: neither app has Heroku add-ons or API keys in config vars, and
the SQLite demo data reseeds on boot. To wake rolio up: scale web dynos back
to 1, restore `.github/dependabot.yml` (revert rolio commit `a79e818`; the
file content is blob `f0527e6`), and delete `test/dormancy_test.rb` (revert
`d10b9ec`), which guards the config's absence.

## Lifecycle Status

- `active`: `bin/ecosystem-build` clones/restores/bundles the app, and the hub
  shows it in satellite links.
- `planned`: the app has a reserved block and durable metadata, but the
  ecosystem build and hub UI ignore it.
- `reserved`: the app has a protected slug/range only. It is not managed, built,
  or linked until a later promotion flips it to `planned` or `active`.
- `release-managed standalone`: the app is not a Studio Engine satellite, but
  the release conductor knows its QA/prod deploy targets through
  `config/release_repos.yml` and `config/qa_environments.yml`.
- Unmanaged candidate: the app may exist locally, but it is not part of the
  rebuild contract. Keep app-specific docs in that repo and avoid adding it to
  shared automation until it is promoted.

## Unmanaged candidate → managed satellite

An app starts life in one of two **tiers** (full decision table:
[`../system/new-app-onboarding-sop.md`](../system/new-app-onboarding-sop.md)):

- **Standalone / client app** — its own repo, **no `studio-engine`**, PRs into
  `main`, lite DoR, owns its runtime + deploy, eventual handoff to a client. It
  uses the studio task board + worktrees + process but is not added to shared
  automation. It may have a `reserved` registry row to protect a future range,
  but it is not managed until deliberately promoted.
- **Release-managed standalone** — same runtime independence as standalone, but
  hosted QA/prod are operated by the release conductor. Rolio (📇) is the
  reference case: PRs target the persistent `release` branch, QA deploys through
  `bin/qa-server`, and production ship uses `bin/release ship`.
- **Managed satellite** — registered in `config/satellites.yml`, persistent
  `release` branch, studio infra (`studio-engine` + SSO), Avi QA, full
  `bin/dor-check`, studio DevOps owns the deploy.

**Promotion** (candidate → satellite) is deliberate, not a default. Before
flipping a candidate into the managed stack, the readiness checklist in the
onboarding SOP must pass — repo on GitHub, boots on its primary port,
`.env`/credential restore documented, README points back at
`/Users/alex/projects/AGENTS.md`, parked operator identities seeded, real
production target + DNS. Only then register it or flip its existing reserved row
to `status: planned` and follow the **Registering An App** steps below. When you
do register a promoted app, carry its emoji into the `config/satellites.yml`
`emoji:` field so the navbar matches the registry.

## Registering An App

Use `bin/register-satellite` from `mcritchie-studio` before creating new
automation or hand-editing the registry.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/register-satellite --list
bin/register-satellite \
  --slug next-app \
  --display-name "Next App" \
  --port 3500 \
  --heroku-app next-app \
  --production-url https://next-app.mcritchie.studio \
  --description "One-line product summary" \
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

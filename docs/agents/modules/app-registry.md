# App Registry

`mcritchie-studio/config/apps.yml` is the app catalog: one record per app with
its slug, name, glyph, status-line color, tier, status, port block, Heroku app,
production and QA URLs, whether it runs on studio-engine, whether McRitchie
Studio hosts it, and its `/stack` workspace. `AppCatalog` (`lib/app_catalog.rb`)
loads and validates it once and hands out frozen values. Gems and the on-chain
program sit in its `libraries:` list: they carry a glyph and a color but no tier,
status or port.

What derives from the catalog:

- `ApplicationHelper::APP_EMOJIS`, the board's app glyphs
- `ReleaseNotes::Formatter::APP_GROUPS`, the release-notes groups
- the `App` rows `db/seeds/00_apps.rb` upserts (`bin/rails apps:seed`), which tint
  the status line
- the app tier and status on `/stack` and `/stack/matrix`
- the badge-glyph check in `bin/register-app`

Three registries keep their own readers and are held to the catalog by
`test/lib/app_registry_test.rb`, which fails on any slug, port, Heroku app,
status word or engine flag that disagrees:

- `config/satellites.yml`: port blocks, navbar links, `bin/ecosystem-build`
- `config/release_repos.yml`: how each repo ships (gems stay here)
- `config/qa_environments.yml`: QA and production targets

McRitchie Studio itself is the implicit hub at `3000-3099`; it has a catalog
record but no `config/satellites.yml` row.

## Adding an app

1. Add one record to `config/apps.yml`. Every field is required; write `null`
   where one does not apply. Pick an unused glyph and the next free port block.
2. Run `bin/rails test test/lib/app_catalog_test.rb test/lib/app_registry_test.rb`
   and fix what it names: usually a `config/satellites.yml` row for the port block
   (`bin/register-satellite`) and a `config/release_repos.yml` entry
   (`bin/register-app`).
3. The board glyph, the release-notes group and the `App` row follow from the
   record; `bin/rails apps:seed` writes the row on deploy.

## Tiers and statuses

| Tier | Meaning |
|------|---------|
| Studio | McRitchie Studio itself |
| Product | A product we build and run, ours or a client's |
| Basic | A small site: a family site or a showcase rebuild |

| Status | Meaning |
|--------|---------|
| Active | Live and in use |
| Delinquent | Live, but not in good standing |
| Showcase | Live as a demonstration of the work |
| Archived | Not running as a product; the record stays so its port block stays reserved. Tier is blank |

## Status-line identity (App model)

Per-app **status-line color + emoji** reach `bin/statusline` through the `App`
model (`app/models/app.rb`), whose rows `db/seeds/00_apps.rb` writes from
`config/apps.yml`, so a glance tells you the app: McRitchie Studio lavender,
Turf Monster green, etc. Edit a color in the catalog; the `APP_OVERRIDES` hash
in `bin/agent-worktree` holds only desk runtime settings (stack, session keys,
squatted ports).

The color rides to the status line without DB access (`bin/task` and
`bin/agent-worktree` are API clients): `Task#sync_app_identity` stamps
`devops.app_color` from the task's first repository on every save, so the marker
and `.agent-context.json` carry it the same way the Pokémon mascot's signature
color does. A brand-new Claude session (no task yet) adopts `App.default`
(`mcritchie-studio`) via the SessionStart hook → `bin/task session-mascot`.
Codex sessions expose hook payloads; `bin/agent-runtime install` keeps Codex's
footer configured as `thread-title` → `model-with-reasoning` →
`context-remaining` and installs a managed
`SessionStart` hook plus a `PostToolUse` refresh hook to
`bin/codex-session-title`. That Codex adapter delegates marker resolution to the
shared provider `bin/agent-marker current`, then mirrors the marker into Codex's
persisted local thread title. The identity makes `current-dir` redundant, while
`context-remaining` adds the session-health signal that matters during long
runs. The installer migrates the former managed layout automatically. It keeps a
custom footer layout by ADDING `thread-title` to the existing `status_line`
array in place, preserving the operator's own formatting — single-line and
one-element-per-line arrays alike, including their indentation and any comments
on the element lines (the separator is written BEFORE a trailing `#`, not after
it, which is where an earlier version swallowed the comma and produced a file
Codex refused). It replaces the value outright only when
`status_line` is not an array at all. (The multi-line case is load-bearing, not
incidental: rewriting only an array's opening line strands the remaining element
lines as bare text, which Codex refuses to load — `key with no value, expected
"="` — so a hand-authored footer would be bricked by running the installer.
`test/commands/install_agent_docs_status_line_array_test.rb` guards it.)

Stock Codex CLI through 0.144.3 renders SessionStart `additionalContext` as
visible `hook context`, so the hook does not use it for mascot identity. Stock 0.144.3 also keeps the live footer thread name
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
(`docs/agents/patches/codex-session-start-thread-name.patch`),
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
agent's name + glyph + tint (`Agent#emoji` / `Agent#status_color`, from
`config/souls.yml`) as the status-line mascot, and `bin/statusline` sets the
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

The catalog holds each app's tier, status and targets; this table adds the
deployment shape.

| App | Tier · status | Port block | Shape |
|-----|---------------|------------|-------|
| 🪎 McRitchie Studio | Studio · Active | 3000-3099 | The hub; deploys through GitHub Actions; QA at `qa.mcritchie.studio` |
| 🐊 Turf Monster | Product · Showcase | 3100-3199 | Managed satellite on studio-engine; `bin/deploy` to `turf-monster-mainnet`; QA at `qa.turfmonster.media` |
| 🐉 Cyvasse | Product · Showcase | 3600-3699 | Managed satellite on studio-engine; git push to Heroku `cyvasse`; canonical host `cyvasse.xyz` (`cyvasse.mcritchie.studio` 301s there and stays reserved); no QA copy by Alex's cost decision, so `qa_evidence: exempt` |
| 📐 McRitchie Industries | Product · Active | 3500-3599 (3510 held for the MSAA dev server) | Managed satellite on studio-engine; the private business knowledge base; git push to Heroku `mcritchie-industries`; QA at `qa.mcritchie.industries` |
| 🔥 Commercial Welding | Product · Active | none | A Google Workspace client with no app; not hosted by McRitchie Studio |
| 📚 Moms App | Basic · Active | 4400-4499 | Release-managed standalone on studio-engine, profile `standalone-heroku` |
| 🎞️ Dads App, 🎲 Prisoners Dilemma, 🏈 Weekly Lock, 📣 Rantly, 🗂️ Portfolio, 🍽️ 10&5 Hospitality, 🔎 Search Position | Basic · Showcase | 3700-4399, one block each | Release-managed standalones on profile `standalone-heroku`, Heroku `dads-app` or `mcr-<repo>`, no QA copies (`qa_evidence: exempt`). Rantly runs on studio-engine; the others have no engine and no database |
| 📇 Rolio | Archived | 3300-3399 | Dormant; ladder `dormant`; Heroku `rolio-prod` and `rolio-qa` |
| ⛓️ Chain Ops | Archived | 3400-3499 | Never reached production; ladder `blocked`, no Heroku app |
| 📊 Tax Studio | Archived | 3200-3299 | Heroku app `tax-studio` with no repo; ladder `planned` |
| 🤝 Acquisition Studio | Archived | none | Retired prototype; McRitchie Industries holds its old block |

Do not reuse `3200-4499`. To wake Rolio: scale its web dynos back to 1, restore
`.github/dependabot.yml` (revert rolio commit `a79e818`; the file content is blob
`f0527e6`), delete `test/dormancy_test.rb` (revert `d10b9ec`), and set its
catalog status.

## Satellite status words

`config/satellites.yml` answers a narrower question than the catalog status: is
the app built by `bin/ecosystem-build` and linked from the hub? The registry test
maps one onto the other.

- `active`: `bin/ecosystem-build` clones, restores and bundles the app, and the
  hub links it. Only a live catalog app (Active, Delinquent, Showcase) may be
  `active`.
- `planned`: a reserved block and durable metadata for an app with no production
  Heroku app yet; the build and the hub UI ignore it.
- `reserved`: a protected slug and range only. Every archived app is `reserved`.
- `release-managed standalone`: not a Studio Engine satellite, but the release
  conductor knows its deploy targets through `config/release_repos.yml` (and its
  QA target through `config/qa_environments.yml` when it has one; the
  `standalone-heroku` profile has none, per
  [`app-deploy-standard`](../agents/steffon/sops/app-deploy-standard.md)).
- Unmanaged candidate: the app may exist locally, but it is not part of the
  rebuild contract. Keep app-specific docs in that repo and avoid adding it to
  shared automation until it is promoted.

## Unmanaged candidate → managed satellite

An app takes one of three **deployment shapes**, separate from its catalog tier (full decision table:
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
do register a promoted app, give its `config/satellites.yml` `emoji:` the catalog
glyph; the registry test checks they match.

## Registering An App

Add the app's `config/apps.yml` record first (see **Adding an app** above), then
use `bin/register-satellite` from `mcritchie-studio` for its port block before
creating new automation or hand-editing the registry.

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

`bin/register-satellite` is the current contract for `config/satellites.yml`.
Release registration of a single-use app is `bin/register-app` (since
2026-09-28; SOP [`app-deploy-standard`](../agents/steffon/sops/app-deploy-standard.md)),
which checks the app and generates its `config/release_repos.yml` entry from a
profile. A future `bin/new-app` can
generate the Rails app, Heroku/GitHub resources, 1Password items, and docs, but
it should write the `config/apps.yml` record and keep the registry test green
instead of inventing another app list.

The generated app should also scaffold a parked identity constant on `User`, a
seed file that consumes that constant, and focused tests proving that a known
email or wallet login adopts the parked row. This is now part of the managed app
contract, not an app-specific convenience.

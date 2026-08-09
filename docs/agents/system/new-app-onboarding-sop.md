# New App Onboarding SOP

How to bring a brand-new app into the McRitchie operating model. The cycle in
[`devops-cycle-design.md`](devops-cycle-design.md) implicitly assumes a **managed
satellite** (turf-monster, the mcritchie-studio hub). A second tier exists: a
**standalone / client app** that borrows the studio's *process* — the task board,
worktrees, DoR, the multi-agent merge discipline — but owns its own runtime and
eventual handoff to a client. A standalone app can later become
**release-managed standalone** for hosted QA/prod without becoming a Studio
Engine satellite; Rolio is the current reference case.

**Decide the tier first.** Almost everything downstream forks on it.

## Tier decision

| Dimension | Managed satellite | Standalone / client app |
|---|---|---|
| Examples | turf-monster, the mcritchie-studio hub | app-owned client demos; Rolio is release-managed standalone |
| Repo | own repo, inside the managed ecosystem | own repo, outside shared automation |
| Registry | `config/satellites.yml` via `bin/register-satellite` | app-owned: unmanaged candidate; release-managed: `release_repos.yml` + `qa_environments.yml`; optional `status: reserved` row only |
| Runtime | `studio-engine` (auth, theme, `ErrorLog`, SSO) | standalone — **no `studio-engine`**; owns auth/UI/infra |
| Branch model | persistent `release` branch; feature PRs target `release` | app-owned: PRs target **`main`**; release-managed: PRs target **`release`** |
| DoR | full `bin/dor-check` (shape-tiered) | app-owned: **lite** — task + tests + error-logging; release-managed: release conductor gates apply |
| Deploy owner | studio DevOps (Steffon); operator-gated ship | app-owned deploy or release-managed Heroku deploy |
| QA / handoff | Avi QA → RC → operator ship | app-owned handoff or QA Heroku → operator ship |

If you are unsure, default to **standalone**: it is the lighter contract, and an
unmanaged candidate can always be **promoted to a managed satellite** later (see
[`../modules/app-registry.md`](../modules/app-registry.md)). Promotion is a
deliberate decision, never a default.

## Phased checklist

### 1. Repo + versions
- Create the GitHub repo (`gh repo create McRitchie-Studio/<slug>`).
- **Match the studio's Ruby/Rails versions** even for a standalone app, so a
  later promotion — or a shared agent session — doesn't fight a toolchain gap.
  Read the hub's `.ruby-version` / `Gemfile` and pin the same majors.
- Keep the clone under `/Users/alex/projects/<slug>` so worktrees and the agent
  tooling resolve it as a sibling.

### 2. Registry decision
- **Managed satellite** → run `bin/register-satellite` (dry-run first), land it in
  `config/satellites.yml` at `status: planned`, then follow
  `studio-engine/docs/NEW_APP_SETUP.md` for the engine wiring.
- **Standalone / client app** → do **not** mark it `planned` or `active`. It may
  have a `status: reserved` row to protect a future port block, but remains an
  *unmanaged candidate*: app-specific docs live in its own repo, and it is
  excluded from `bin/ecosystem-build` and the hub navbar. If the studio owns
  QA/prod hosting, add it to `config/release_repos.yml` and
  `config/qa_environments.yml` as a **release-managed standalone** app. Record
  the decision in
  [`../modules/app-registry.md`](../modules/app-registry.md) so the next agent
  doesn't re-litigate it.

### 3. Runtime decisions
| Decision | Managed satellite | Standalone / client app |
|---|---|---|
| Engine | consume `studio-engine` from RubyGems | no engine — vendor only what you need |
| Auth | engine passwordless + hub SSO | own auth (the app's call) |
| DB | Postgres | **SQLite is fine for a demo**; Postgres when it matters |
| External adapters (AI, payments, …) | mock-first behind a swappable adapter | same — mock-first behind a swappable adapter |

### 4. Branch model
- Managed → `bin/release init` gives the repo its persistent `release` branch;
  feature PRs target `release`.
- App-owned standalone → **no release branch.** Feature PRs target **`main`**;
  the app team merges its own PRs. (`bin/agent-worktree` already falls back to
  `origin/main` as the base for any repo without a `release` branch.)
- Release-managed standalone → run `bin/release init` after adding the app to
  `config/release_repos.yml`; feature PRs target **`release`**, QA deploys via
  `bin/release prepare`, and production ships through the operator-gated
  `bin/release ship`.

### 5. Seed the task board
- Even a standalone app uses the studio task board. Create a **foundation task**
  (`kind: chore`, e.g. "scaffold <app>") plus a small **backlog** of the first
  features. The slug is the genesis: it seeds the worktree, the `feat/<slug>`
  branch, and the task URL.
- App-owned standalone tasks carry `repo: <slug>` and no `release_slug`.
  Release-managed standalone tasks carry `repo: <slug>` and join
  the normal release record after review/merge.

### 6. DoR tier
- Managed → full `bin/dor-check <task>` (the shape's required tiers must be green).
- Standalone → **lite DoR**: the task exists, tests are written as you go, and the
  error-logging discipline below is present. There is no release-slug gate, but
  the *evergreen* conventions are non-negotiable.

### 7. Build conventions

**Evergreen — ALL apps, both tiers, no exemption:**
- **Task before code.** The production task is the genesis (see `CLAUDE.md` /
  `AGENTS.md`). No size exemption.
- **Write the tests as you go**, unit-first.
- **Robust error / API-failure logging.** This is the `rescue_and_log`
  *principle*, and it is **NOT optional for standalone apps.** Managed apps use
  `studio-engine`'s `rescue_and_log` / `ErrorLog` (queryable by `target`/`parent`,
  outlives Heroku log retention). **Standalone apps implement the same discipline
  with plain `Rails.logger` and/or their own error tracker (e.g. Sentry).** They
  skip the *helper*, never the *logging* — every backend failure must leave a
  durable, attributable record.
- **External integrations are mock-first behind a swappable adapter.** Rolio's
  `Llm` adapter is the pattern: a mock implementation by default, the real
  provider behind an env key. The app boots, tests, and demos with zero external
  credentials; flipping one env var swaps in the real provider.

**Managed-satellite-specific — the engine standards, from day one:**

A satellite consumes the engine's *runtime*, and two pieces of that runtime are
easy to skip and fail quietly when you do. Both belong in the scaffold, not in a
later cleanup task.

- **Install the engine migrations.** `bin/rails studio_engine:install:migrations`
  (note `studio_engine:`, not `studio:`), and **re-run it after every engine
  upgrade**. It copies the engine's *reference* migrations — the email outbox,
  `Studio::Link`, `Studio::Enumeral`, an `image_caches` relaxation — in as
  `*.studio_engine.rb` with a provenance comment.

  **Install all of them, then `bin/rails db:migrate`.** Every engine migration is
  safe on every app: the ones that create tables add a table you may not use yet,
  and `allow_null_image_cache_owner` — which ALTERS the app-owned `image_caches`
  — no-ops when that table is absent (studio-engine >= 0.30.1). Do **not** delete
  copies you think you don't need: `install:migrations` builds its skip-list from
  the files present, so a deleted copy returns with a fresh timestamp on the next
  upgrade. Verify rather than assume:
  `bin/rails runner 'puts Studio::EmailDelivery.available?'` must print `true`.

  Skipping it is **silent**. `Studio::Email.deliver` records a row only when
  `studio_email_deliveries` exists and otherwise falls through to a plain async
  `deliver_later` — no error, no record. The app drops every captured email and
  `/_studio/local_emails` is always empty. mcritchie-industries shipped with
  exactly this hole (fixed 2026-08-08).

- **Render the shared environment banner, don't write one.**

  ```erb
  <body ...>
    <%= render "studio/banners/environment" %>
    <%= render "layouts/navbar" %>
  ```

  One call, no conditional around it (studio-engine >= 0.30 — the partial is
  merged and publishes with the next release sweep; until then a new app keeps
  its own strip and adopts on the upgrade). The partial decides
  for itself whether to appear (every environment except real production; a QA app
  is Rails-production but a review target, so `QA_ENV=true` re-opens it), what to
  say, and whether the Local Inbox is linkable — it links the inbox only where the
  viewer actually resolves and degrades to an inert status chip otherwise, so it
  can never advertise a dead link.

  Do **not** hand-roll a yellow `<div>`. Earlier versions of
  `studio-engine/docs/NEW_APP_SETUP.md` § 9 pasted one to copy, and every app that
  copied it drifted — different show rules, different labels, no inbox link.

  The inbox is a **developer-desk** tool: it 404s on QA and in production, and
  `LOCAL_EMAIL_CAPTURE=1` on a QA dyno does nothing. Both gates hard-close under
  `Rails.env.production?` on purpose. See
  [`../modules/email-operations.md`](../modules/email-operations.md).

**Standalone-specific:**
- No `studio-engine`, no hub SSO — the app owns its auth, UI, and infra.
- App-owned feature PRs target **`main`**; release-managed standalone PRs target
  **`release`**.
- Match the studio's Ruby/Rails versions. App-owned standalone apps own their
  Heroku app / pipeline / env vars; release-managed standalone apps declare
  those targets in `config/release_repos.yml` and `config/qa_environments.yml`.
- **SQLite is fine for a demo**; move to Postgres when persistence matters.

### 8. Handoff
- Managed → standard PR-into-`release` → Avi QA → RC → operator ship.
- App-owned standalone → PR-into-`main`; the **app team / client owns merge +
  deploy.** Release-managed standalone → PR-into-`release`, QA Heroku via
  `bin/release prepare`, and operator-gated `bin/release ship`. When the
  engagement ends, **hand the repo off to the client** with its own README, env
  contract, and deploy runbook — it must stand alone without the studio.

## Multi-agent build

A new app is often scaffolded by **several agents in parallel** (Rolio's first cut
was 4 gap features by 4 agents merged into one branch). The worktree-isolation and
merge-safety patterns for that run — manual `git worktree add` per agent,
new-files-first, additive shared-view/route edits, one migration owner, the CSS
end-of-file seam, sequential merges with a green suite between — live in
[`../modules/worktrees.md`](../modules/worktrees.md) → **Multi-Agent Safety &
Merge Patterns**. Read that before fanning out agents.

## Related

- [`../modules/app-registry.md`](../modules/app-registry.md) — the registry
  contract plus the **unmanaged candidate → managed satellite** promotion
  lifecycle and its readiness checklist.
- `studio-engine/docs/NEW_APP_SETUP.md` — the managed-satellite engine wiring.
- [`new-app-scaffolder-spec.md`](new-app-scaffolder-spec.md) — the spec for
  **`bin/new-app`**, the future automation that will generate a managed satellite
  end to end (repo, Heroku, 1Password, docs). It targets the **managed** tier;
  standalone apps stay hand-scaffolded for now.

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
| Branch model | three-rung ladder `accepted` → `release` → `main`; feature PRs target **`accepted`** | app-owned: PRs target **`main`**; release-managed: the same three-rung ladder |
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
  `config/qa_environments.yml` as a **release-managed standalone** app — with a
  `ladder:` declaration, and run `bin/release init` (see section 4). Record
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

### 4. Branch model — a managed app is BORN laddered

The pipeline walks three rungs — **`accepted` → `release` → `main`**. A repo
missing either persistent branch cannot ride it: feature PRs land on
`accepted`, the sweep promotes `accepted` onto `release`, and the ship
fast-forwards `release` onto `main`. **Create both rungs as part of onboarding,
not later.** An app that skips this reopens the question of where its PR should
go on every single change — moms-app was created with `main` alone and did
exactly that for months.

- **Managed satellite / release-managed standalone** → add the app to
  `config/release_repos.yml` **with a `ladder:` declaration** (below), then run
  `bin/release init`, which creates **both** `accepted` and `release` off
  `main`. Feature PRs target **`accepted`**. QA deploys via `bin/release
  prepare`; production ships through the operator-gated `bin/release ship`.
- **App-owned standalone** → **no ladder.** Feature PRs target **`main`** and
  the app team merges its own. (`bin/agent-worktree` falls back to
  `origin/main` as the base for any repo without the branches.) Such an app is
  not in `release_repos.yml` at all, so nothing sweeps it.

Every entry in `config/release_repos.yml` declares its shape, and the
declaration is CHECKED against the real repos by
`test/models/release/repos_test.rb` — an omitted or stale one fails the suite
rather than sitting quietly:

| `ladder:` | Meaning | What the guard asserts |
|---|---|---|
| `three-rung` | the normal state | `origin/accepted` and `origin/release` both exist |
| `planned` | the repo does not exist yet | there is still **no checkout** — so the exemption expires the day one appears |
| `dormant` | registered for history, deliberately not shipped | excluded from the sweep |
| `blocked` | exists and wanted, but automation cannot reach it (not org-owned, or the App is not installed) | excluded from the sweep; **this is unfinished work, not a decision** |

Only `three-rung` repos are swept. That exclusion is the point — reaching for a
repo the conductor cannot fetch is how a stray failure lands in the middle of an
unrelated `bin/release status`.

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
  upgrade**. It copies the migrations of the **resolved** gem in as
  `*.studio_engine.rb` with a provenance comment — the email outbox,
  `Studio::Link`, `Studio::Enumeral`, an `image_caches` relaxation, and since
  0.46 the standard `users` profile columns.

  **Resolve before you copy.** The task copies from the gem bundler RESOLVED,
  never from the version you meant. On a branch whose `Gemfile.lock` still pins
  the older version, `bundle install` HONOURS that lock, `install:migrations`
  copies nothing, and the suite goes green having adopted nothing. Move the one
  gem with `bundle update --conservative studio-engine`, then read the lockfile
  diff and confirm no other gem moved.

  **Install all of them, then `bin/rails db:migrate`.** Every engine migration is
  safe on every app. The ones that create tables add a table you may not use yet.
  The two that ALTER app-owned tables guard themselves:
  `allow_null_image_cache_owner` no-ops when `image_caches` is absent
  (studio-engine >= 0.30.1), and `add_standard_user_profile_columns` returns
  early without a `users` table and adds every column `if_not_exists`, so an app
  that already spells one of them keeps its own. Do **not** delete copies you
  think you don't need: `install:migrations` builds its skip-list from the files
  present, so a deleted copy returns with a fresh timestamp on the next upgrade.

  Verify rather than assume:
  `bin/rails runner 'puts Studio::EmailDelivery.available?'` must print `true`,
  and carry a test that diffs the RESOLVED gem's migrations against `db/migrate`
  by bare name. A version floor cannot see a migration you never copied: this app
  ran 0.46 against a 0.45 `users` table with a green suite, because its contract
  test asserted a hand-written column list instead (2026-08-13).

  Skipping it is **silent**. `Studio::Email.deliver` records a row only when
  `studio_email_deliveries` exists and otherwise falls through to a plain async
  `deliver_later` — no error, no record. The app drops every captured email and
  `/_studio/local_emails` is always empty. mcritchie-industries shipped with
  exactly this hole (fixed 2026-08-08).

- **Render the shared bar stack, don't write your own banner.**

  ```erb
  <body ...>
    <%= render "studio/banners/stack" %>
    <%= render "layouts/navbar" %>
  ```

  One call, no conditional around it (studio-engine >= 0.39, published). It renders
  whichever bars apply — the environment banner, impersonation, whatever comes
  next — in one block.

  Two rules, and they are the whole layout contract:

  | Rule | Why |
  |---|---|
  | The stack goes **before** the navbar, as a **sibling** — never nested inside it | Bars compose. There is already a second one, and nesting meant every new bar edited the navbar. |
  | The bars sit in **normal flow**; the navbar is the only pinned chrome (`sticky top-0`) | The bars reserve their space by taking it, so the navbar has no offset to compute and a new bar never edits it. |

  An app with a hand-written navbar follows the same two rules: `sticky top-0`, a
  **static** value, never one read from a custom property. Give either element an
  offset published at runtime and the header moves after first paint — that was the
  `--studio-bars-h` jump introduced in 0.33 and removed in 0.39. Two pinned siblings
  of unknown height cannot stack in CSS alone; one has to measure the other, and
  that measurement *is* the defect. An already-adopted navbar still spelling
  `top:var(--studio-bars-h, 0px)` needs no edit — the property is gone, so it
  resolves to its `0px` fallback, which is where the new layout wants it.

  The bars therefore scroll away with the page, and only the navbar stays. An
  overlay that must clear the chrome positions off `--nav-bottom` (published by
  `layouts/studio/head`), which reports the header's live bottom edge.

  Name `studio/banners/environment` directly and you get that one bar, mounted
  where you put it, and a second bar later has nowhere to go — the seam
  mcritchie-studio retired on 2026-08-10. The environment bar itself still decides
  whether to appear (every environment except real production; a QA app is
  Rails-production but a review target, so `QA_ENV=true` re-opens it), what to say,
  and whether the Local Inbox is linkable — it links the inbox only where the
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
  **`accepted`** (the ladder's first rung).
- Match the studio's Ruby/Rails versions. App-owned standalone apps own their
  Heroku app / pipeline / env vars; release-managed standalone apps declare
  those targets in `config/release_repos.yml` and `config/qa_environments.yml`.
- **SQLite is fine for a demo**; move to Postgres when persistence matters.

### 8. Handoff
- Managed → standard PR-into-`accepted` → review merges → Avi's sweep promotes
  `accepted` onto `release` → QA → operator ship.
- App-owned standalone → PR-into-`main`; the **app team / client owns merge +
  deploy.** Release-managed standalone → PR-into-`accepted`, QA Heroku via
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

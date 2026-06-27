# New App Onboarding SOP

How to bring a brand-new app into the McRitchie operating model. The cycle in
[`devops-cycle-design.md`](devops-cycle-design.md) implicitly assumes a **managed
satellite** (turf-monster, the mcritchie-studio hub). A second tier exists: a
**standalone / client app** (Rolio) that borrows the studio's *process* — the
task board, worktrees, DoR, the multi-agent merge discipline — but owns its own
runtime, deploy, and eventual handoff to a client.

**Decide the tier first.** Almost everything downstream forks on it.

## Tier decision

| Dimension | Managed satellite | Standalone / client app |
|---|---|---|
| Examples | turf-monster, the mcritchie-studio hub | Rolio |
| Repo | own repo, inside the managed ecosystem | own repo, outside shared automation |
| Registry | `config/satellites.yml` via `bin/register-satellite` | optional `status: reserved` row only; not `planned`/`active` until promoted |
| Runtime | `studio-engine` (auth, theme, `ErrorLog`, SSO) | standalone — **no `studio-engine`**; owns auth/UI/infra |
| Branch model | persistent `release` branch; feature PRs target `release` | no release slug; feature PRs target **`main`** |
| DoR | full `bin/dor-check` (shape-tiered) | **lite** — task + tests + error-logging; no release-slug gates |
| Deploy owner | studio DevOps (Steffon); operator-gated ship | the app team / eventual **client** owns deploy |
| QA / handoff | Avi QA → RC → operator ship | app-owned merge into `main`; **handoff to the client** |

If you are unsure, default to **standalone**: it is the lighter contract, and an
unmanaged candidate can always be **promoted to a managed satellite** later (see
[`../modules/app-registry.md`](../modules/app-registry.md)). Promotion is a
deliberate decision, never a default.

## Phased checklist

### 1. Repo + versions
- Create the GitHub repo (`gh repo create amcritchie/<slug>`).
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
  excluded from `bin/ecosystem-build` and the hub navbar. Record the decision in
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
- Standalone → **no release branch.** Feature PRs target **`main`**; the app team
  merges its own PRs. (`bin/agent-worktree` already falls back to `origin/main` as
  the base for any repo without a `release` branch — this is exactly that case.)

### 5. Seed the task board
- Even a standalone app uses the studio task board. Create a **foundation task**
  (`kind: chore`, e.g. "scaffold <app>") plus a small **backlog** of the first
  features. The slug is the genesis: it seeds the worktree, the `feat/<slug>`
  branch, and the task URL.
- Standalone tasks carry `repo: <slug>` and no `release_slug`.

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

**Standalone-specific:**
- No `studio-engine`, no hub SSO — the app owns its auth, UI, and infra.
- Feature PRs target **`main`**; the app team merges.
- Match the studio's Ruby/Rails versions, but **own the deploy** — your own Heroku
  app / pipeline / env vars, not the studio's `bin/release` train.
- **SQLite is fine for a demo**; move to Postgres when persistence matters.

### 8. Handoff
- Managed → standard PR-into-`release` → Avi QA → RC → operator ship.
- Standalone → PR-into-`main`; the **app team / client owns merge + deploy.** When
  the engagement ends, **hand the repo off to the client** with its own README,
  env contract, and deploy runbook — it must stand alone without the studio.

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

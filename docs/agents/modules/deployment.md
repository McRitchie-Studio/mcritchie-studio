# Deployment

Deployment details remain app-owned, but cross-repo agents should know where to start.

## McRitchie Studio

Production app: `mcritchie-studio`
Canonical URL: `https://mcritchie.studio`
Legacy app URL: `https://app.mcritchie.studio`

```bash
git push heroku main
heroku run bin/rails db:migrate --app mcritchie-studio
```

### Web Concurrency and the Connection Budget

`config/puma.rb` runs cluster mode in production: `WEB_CONCURRENCY` defaults to
2 workers × 3 threads (`RAILS_MAX_THREADS`) = 6 concurrent requests on the one
Basic web dyno (raised from 3 after the 2026-08-09 H12 outage). The sizing
authority is the worst-case connection budget beside the `workers` line in
`config/puma.rb`: the board Postgres is essential-0 with a hard 20-connection
limit shared by web, the Solid Queue dyno, and agent CLI sessions — budgeted
6 + 7 + 5 = 18 of 20. `test/lib/puma_config_contract_test.rb` re-derives that
budget from the parsed configs and fails the suite if it reaches the ceiling.
Re-prove the math there before raising `WEB_CONCURRENCY`, `RAILS_MAX_THREADS`,
or `JOB_CONCURRENCY` on Heroku.

### Root-Domain Launch

`mcritchie.studio` is the canonical McRitchie Studio app host. The previous
Squarespace site is archived at `https://v1.mcritchie.studio`; the old Rails app
host `https://app.mcritchie.studio` remains a legacy alias.

Launch status as of 2026-06-15:

- Production deploy: Heroku release `v63`, commit `4831ebcd`.
- Heroku ACM: certs issued for `mcritchie.studio`, `www.mcritchie.studio`, and
  `app.mcritchie.studio`.
- Rails host config: `APP_HOST=mcritchie.studio`,
  `MAILER_HOST=mcritchie.studio`, and `APP_HOST_ALIASES` includes
  `app.mcritchie.studio`, `www.mcritchie.studio`, and the Heroku fallback host.
- Verified app health: root, `www`, legacy `app`, and Heroku fallback all return
  `200` on `/up` once DNS resolves to Heroku.
- Verified archive health: `v1.mcritchie.studio` is attached to the old
  Squarespace site as its primary domain, has the `www` prefix disabled, uses
  `ext-cust.squarespace.com`, and returns `200`.
- Known propagation caveat: local routers and public resolvers may cache old
  Squarespace records for up to the prior 4-hour TTL. Verify against
  `1.1.1.1` or the authoritative nameservers before changing records again.
- Production auth smoke: `https://mcritchie.studio/signin` returns `200`, and
  a production `POST /magic_link` for `alex@mcritchie.studio` returned
  `{"success":true}`.

Heroku domains for `mcritchie-studio`:

| Hostname | DNS type | Target |
|----------|----------|--------|
| `mcritchie.studio` | ALIAS / ANAME at apex | `human-gooseberry-dpwdkczq4dpjxe0n7qconbut.herokudns.com` |
| `www.mcritchie.studio` | CNAME | `philosophical-anenome-txijca9objmowkzw87zmm2e8.herokudns.com` |
| `app.mcritchie.studio` | CNAME | `dry-newt-78qhw9kfd1r0nqnu4fybesw3.herokudns.com` |

Squarespace archive DNS:

| Hostname | DNS type | Target |
|----------|----------|--------|
| `v1.mcritchie.studio` | CNAME | `ext-cust.squarespace.com` |

Production Heroku config for the cutover:

```bash
heroku config:set \
  APP_HOST=mcritchie.studio \
  MAILER_HOST=mcritchie.studio \
  APP_HOST_ALIASES=app.mcritchie.studio,www.mcritchie.studio,mcritchie-studio-039470649719.herokuapp.com \
  DYNO_HOST=mcritchie-studio-039470649719.herokuapp.com \
  --app mcritchie-studio
```

DNS cutover in Squarespace:

1. Attach `v1.mcritchie.studio` to the Squarespace site before moving the apex.
   Squarespace manages this as `v1` CNAME -> `ext-cust.squarespace.com`. If a
   manually-created `v1` CNAME blocks connection, delete only that `v1` row and
   re-run the Squarespace "Connect subdomain" flow.
2. Replace the four apex `A` records currently pointing at Squarespace with an
   apex `ALIAS`/`ANAME` to Heroku:
   `human-gooseberry-dpwdkczq4dpjxe0n7qconbut.herokudns.com`.
3. Change `www` from Squarespace to the Heroku CNAME target if `www` should
   launch Rails alongside the apex. Remove `www.mcritchie.studio` from
   `APP_HOST_ALIASES` if `www` intentionally stays on Squarespace.
4. Run `heroku certs:auto --app mcritchie-studio` until ACM shows issued certs
   for every Heroku-hosted hostname.
5. Verify:

   ```bash
   dig +short @1.1.1.1 mcritchie.studio A
   dig +short @1.1.1.1 www.mcritchie.studio CNAME
   dig +short @1.1.1.1 v1.mcritchie.studio CNAME
   curl -I https://mcritchie.studio/up
   curl -I https://www.mcritchie.studio/up
   curl -I https://app.mcritchie.studio/up
   curl -I https://v1.mcritchie.studio
   ```

   If local DNS is stale but public DNS is correct, force a Heroku routing check:

   ```bash
   curl -I --resolve mcritchie.studio:443:76.223.57.73 https://mcritchie.studio/up
   curl -I --resolve www.mcritchie.studio:443:76.223.57.73 https://www.mcritchie.studio/up
   ```

6. Smoke auth after DNS settles:

   ```bash
   curl -I https://mcritchie.studio/signin
   ```

   Then request one production magic link from the browser and confirm the email
   link uses `https://mcritchie.studio`.

## Turf Monster

Production app: `turf-monster-mainnet`
Canonical URL: `https://turfmonster.media`
Legacy app URL: `https://app.turfmonster.media`
Archive URL: `https://v1.turfmonster.media`

Use `turf-monster/bin/deploy`; do not hand-push around its preflight checks for real-money flows.

### Root-Domain Launch

Target state:

- `turfmonster.media` is the canonical Turf Monster Rails app host.
- `app.turfmonster.media` remains a legacy Rails alias while provider dashboards,
  saved links, and allowlists migrate.
- `v1.turfmonster.media` serves the previous Turf Monster landing site on the
  old Heroku app `limitless-tundra-34071`.

Known Heroku domains for the cutover:

| Hostname | Heroku app | DNS type | Target |
|----------|------------|----------|--------|
| `v1.turfmonster.media` | `limitless-tundra-34071` | CNAME | `whispering-savannah-euqsutzic06i9306g89db3ug.herokudns.com` |
| `app.turfmonster.media` | `turf-monster-mainnet` | CNAME | `evolutionary-endive-vck8w1u6epmos2i4lh68goot.herokudns.com` |

Cutover sequence:

1. Deploy Turf Monster with production host-alias support.
2. Set `APP_HOST=turfmonster.media`, `MAILER_HOST=turfmonster.media`, and
   `APP_HOST_ALIASES=app.turfmonster.media` on `turf-monster-mainnet`.
3. Create DNS `v1` CNAME to
   `whispering-savannah-euqsutzic06i9306g89db3ug.herokudns.com` and verify the
   old landing site answers at `https://v1.turfmonster.media`.
4. Remove `turfmonster.media` from old Heroku app `limitless-tundra-34071`,
   add it to `turf-monster-mainnet`, then update apex DNS at Name.com to the
   Heroku target printed by `heroku domains --app turf-monster-mainnet`.
5. Run `heroku certs:auto --app turf-monster-mainnet` until ACM is issued for
   `turfmonster.media` and `app.turfmonster.media`.
6. Verify:

   ```bash
   dig @ns1psw.name.com turfmonster.media A +short
   dig @ns1psw.name.com app.turfmonster.media CNAME +short
   dig @ns1psw.name.com v1.turfmonster.media CNAME +short
   curl -I https://turfmonster.media/up
   curl -I https://app.turfmonster.media/up
   curl -I https://v1.turfmonster.media
   ```

## Rule

Deploys, gem publishes, provider changes, and production env-var changes are
Release-lane work. A feature agent can recommend deploy, but only the designated
release conductor should run it after explicit approval from Mr. McRitchie or an
already-approved rollout prompt. Alex's `full-cycle` launcher, Steffon's
`production-deploy`, and Avi's `deploy-with-task` acts are such pre-approved
production prompts; `pr-review` and Avi's `qa-release` sweep are not — they stop
before prod.
Gem publishes specifically ride a release as
first-class members and are published producer-first by **`bin/release prepare`
at QA assembly** (see below) — the one irreversible act inside Avi's
otherwise prod-stopping `qa-release` lane, taken only after a fail-closed
preflight over every swept gem. `bin/release ship` re-verifies each gem
idempotently (already-live → skip). Neither is a separate ad-hoc step.

## QA And Production URLs

`mcritchie-studio/config/qa_environments.yml` is the source of truth for stable
QA servers and production URLs used by `bin/qa-server`, `bin/release`, and
`bin/prod-smoke`.

- QA servers use `https://qa.<canonical-host>` and set `QA_ENV=true` while still
  running Rails in production mode.
- Production URLs use the canonical public host: `https://mcritchie.studio` for
  the hub and `https://turfmonster.media` for Turf Monster.
- Legacy `app.*` hosts may stay in `APP_HOST_ALIASES` and provider dashboards
  during migration, but they are aliases, not the production target in release
  metadata or post-ship smoke checks.

## Release builder autonomy

QA assembly autonomy is deterministic config, not agent judgment. The policy
lives in `config/release_builder.yml` and is read by `Release::BuilderPolicy`:
one reviewed task, one repo, and no blocked risk tags can proceed to QA assembly
automatically; anything broader is a proposal that waits for operator
confirmation. Production ship remains operator-gated regardless of that QA
decision unless the session uses the explicit `full-cycle` production
launcher or another already-approved rollout prompt.

## Releasing a gem (producer-first)

Gems (`studio-engine`, `solana-studio`) are **producers**; the apps that depend
on them are **consumers**. A release ships them **producer-first** — the gem is
published to RubyGems *before* any consuming app deploys, so the app always
builds against the just-published version. The classification is the registry at
`config/release_repos.yml` (read by `Release::Repos`).

How a gem rides a release:

1. **The gem task is a normal task — and it carries NO version.** Its PR/branch
   lives in the gem's *own* repo (e.g. `studio-engine`), not in
   `mcritchie-studio`. Shape `library`. The PR must **not** touch the registry's
   `version_file` (`lib/studio/version.rb` for studio-engine, the `.gemspec` for
   solana-studio): `bin/dor-check` **refuses** a diff that edits one, because N
   PRs riding one candidate publish exactly **one** version, so no single PR can
   know the answer. The **release** owns the number (step 2). Editing
   `CHANGELOG.md` is *not* refused. Otherwise it is reviewed → `reviewed` like
   any other task.
2. **`bin/release prepare` allocates the version — you do not.** The bump is
   derived from the candidate's membership: any member risk-tagged `breaking` →
   major, else any `kind: feature` → minor, else patch; `next = last published
   version + that bump`, where "last published" is the higher of the last `v*`
   tag and the highest version live on RubyGems (so a lagging tag can never
   re-tread a spent number). `Release::GemVersion`
   (`app/models/release/gem_version.rb`) encodes those rules, and prepare's step
   4d calls it, writes the `version_file` **together with its `Gemfile.lock`** in
   one commit onto `origin/release`, and does it BEFORE the publish
   (finding-d0621629719b, now closed). There is nothing for you to run.
   Allocation is idempotent — a re-run reads a version already past the last
   published one and skips — and it **refuses rather than guesses**: an
   unreadable `--gem-bump`, an unparseable last version, a `version_file` that
   declares its version twice, or a `bundle lock` that did not land the new
   number all abort the sweep with **nothing published**. The stranded-work guard
   stays armed behind it, so a skipped or wrong allocation still aborts loudly.
   When the derived bump is wrong — most often a `chore` that is genuinely
   breaking — the override is `bin/task update <task-slug> --gem-bump major`.
3. **Prepare preflights EVERY swept gem, then publishes — before the gate and
   QA.** `bin/release prepare` adds the gem to the release record without
   merging a branch for it (it has none here), then runs the two-phase
   producer-first sequence: phase 1 validates ALL swept gems (fail-closed
   fetch of `origin/release`, version_file parses, the stranded-work guard —
   commits past the last `v*` tag with an unbumped version ABORT loudly — and
   a swept consuming app whose Gemfile declares the gem); ANY failure aborts
   with **zero gems published**, because a RubyGems push can never be
   re-pushed. Phase 2 then publishes each validated gem from the frozen
   `origin/release` tree (skip-if-live), tags `v<version>`, and commits each
   consumer's `Gemfile.lock` bump (`bundle lock --update <gem>
   --conservative`) onto the consumer's `origin/release` — so the pre-QA
   gate's CI verdict, the QA deploy, and the prod tree all read the SAME
   post-bump SHA, and QA exercises the REAL published artifact.
4. **Run Deployment re-verifies gems first, gated.** `bin/release ship` orders
   members gems-before-apps (honoring `dependencies`) and, before any app
   deploy, re-runs the publish as an idempotent verify: on the happy path
   every version is already live (skip); it remains the real publish only for
   a release prepared before the prepare-time publish existed. A failed
   build/push **aborts the ship** before any app deploys.
5. **Consumers deploy on the bumped lock.** The consumer's lock bump landed on
   `origin/release` at prepare (step 3), so QA and prod both build the bumped
   lock. Never deploy a consumer ahead of its gem.

Operational notes:

- Run `prepare` and `ship` from a **primary checkout**, not a worktree: the gem
  repos are resolved as siblings of `mcritchie-studio` at the projects root
  (`/Users/alex/projects/<repo>`).
- `gem push` requires a logged-in RubyGems credential (`gem signin`). A
  "version already published" error means the conductor's version commit (step
  2) never landed on the gem's `accepted`, or did not advance past the last
  published tag — commit the advanced version and re-run `prepare`, don't
  re-push. Never resolve it by editing a feature PR: `dor-check` refuses that.
- The manual gem build remains documented in `studio-engine/docs/RELEASE.md`;
  `bin/release prepare` automates that path (preflight → build → push → tag) as
  the release conductor's producer-first step, and `bin/release ship` re-runs
  it as the idempotent verify.

## QA Servers

Dedicated QA servers are tracked in `mcritchie-studio/config/qa_environments.yml`.
They are stable Heroku apps used after PR review and before production rollout.
Use `bin/qa-server` from McRitchie Studio:

```bash
bin/qa-server list
bin/qa-server plan mcritchie-studio
bin/qa-server provision mcritchie-studio --yes
bin/qa-server status turf-monster
bin/qa-server status rolio
bin/qa-server deploy turf-monster origin/main --yes
bin/qa-server deploy rolio origin/release --yes
```

QA deploys are external writes, but they are not production deploys. They should
use QA Heroku apps only, with production-like Rails boot and QA-safe config.
Production deploy remains a separate, explicit ship decision Mr. McRitchie makes
after he reviews the QA URL — a human gate in the pipeline (ship-authority), not
an automated GitHub Environment reviewer rule. That automated rule and its in-app
approval subsystem were removed 2026-07-20 (see the GitHub Actions panel section).

Production deploy conductors should send Release Notes through McRitchie
Studio's authenticated task-board API after successful production verification:

```bash
api POST /api/v1/release_notes '{
  "app": "mcritchie-studio",
  "environment": "production",
  "release": "v71",
  "sha": "ef693ab1",
  "url": "https://mcritchie.studio/",
  "release_slug": "rel-2026-06-18-devops-tooling",
  "task_slugs": ["task-abc123def456"],
  "checks": ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
  "dry_run": true
}'
```

Review the returned `message`, then repeat without `dry_run` to post the
canonical Discord message. The API groups linked task titles by application and
links tasks to their production McRitchie Studio task pages. Production uses
`DISCORD_RELEASE_NOTES_WEBHOOK_URL`, with `DISCORD_DEPLOY_WEBHOOK_URL` as a
compatibility fallback. Never commit webhook URLs.

Current intended QA apps:

| App | QA Heroku app | QA URL | Safety profile |
|-----|---------------|--------|----------------|
| McRitchie Studio | `mcritchie-studio-qa` | `https://qa.mcritchie.studio` | Hub QA, real low-volume auth email |
| Turf Monster | `turf-monster-qa` | `https://qa.turfmonster.media` | Devnet, `PAYMENT_PROVIDER=none`, no real-money checkout |
| Rolio | `rolio-qa` | `https://rolio-qa-58beede9dc0b.herokuapp.com` | Demo QA, SQLite data is ephemeral |

Current Heroku-generated fallback URLs:

| App | Heroku URL |
|-----|------------|
| McRitchie Studio | `https://mcritchie-studio-qa-26cedb6e8fdc.herokuapp.com` |
| Turf Monster | `https://turf-monster-qa-93e18f3ae318.herokuapp.com` |
| Rolio | `https://rolio-qa-58beede9dc0b.herokuapp.com` |

Provision each QA app once with `bin/qa-server provision <app> --yes`. The
helper creates the Heroku app, attaches the app-owned QA addons, sets non-secret
registry config, copies required secret values from the app's local `.env` or
process env without printing values, adds the custom Heroku domain, and enables
Heroku Automated Certificate Management for HTTPS.

After `provision`, run `bin/qa-server status <app>` and create the required DNS
`CNAME` for each QA hostname to the Heroku DNS target that status reports. The
default `*.herokuapp.com` host remains registered as `DYNO_HOST` where the app
uses that env contract, so Rails host authorization and `/up` checks keep
working while DNS propagates. Rolio currently has no custom domain, so its
Heroku-generated QA/prod URLs are the canonical review URLs.

Current DNS CNAME targets:

| Hostname | CNAME target |
|----------|--------------|
| `qa.mcritchie.studio` | `still-peafowl-p2kwpj56ihp5pdt4bcougntu.herokudns.com` |
| `qa.turfmonster.media` | `encircled-avocado-2ciqghsd1qrzyecpjhz9negz.herokudns.com` |

Rolio has no DNS row yet. Keep using
`https://rolio-qa-58beede9dc0b.herokuapp.com` for QA and
`https://rolio-prod-82e96784b462.herokuapp.com` for production until a domain is
approved.

QA servers should use Resend fallback through `team@mcritchie.studio` for
low-volume magic-link/auth proof until `studio-engine` supports production-safe
email capture on Heroku QA. Do not copy production payment or mainnet Solana
settings into Turf Monster QA. Turf Monster QA runs on devnet and derives
`EXPECTED_IDL_HASH` from `config/turf_vault.idl.json` during provisioning.
Turf Monster QA uses `heroku-redis:mini`; Redis data is intentionally
non-persistent because QA can be rebooted and reseeded often. Rolio uses SQLite
for the hosted demo runtime; data is intentionally ephemeral on Heroku until a
persistent database task replaces it.

If deployment changes a provider, domain, callback URL, env var, or local port, update:

- `mcritchie-studio/config/satellites.yml`
- `mcritchie-studio/config/qa_environments.yml`
- `mcritchie-studio/docs/ECOSYSTEM.md`
- the app README/runbook
- any provider-specific docs under the app's `docs/`

## GitHub Actions panel + prod-deploy (approval subsystem removed 2026-07-20)

`/deployments` carries a live GitHub Actions panel (`_github_actions_panel`) —
the latest run per workflow (CI / QA Deploy / Production Deploy), status-pilled
and REPLACE-broadcast over Turbo Streams. It is fed by webhooks, not polling:
GitHub POSTs to `/api/v1/github/webhook` (`GithubWebhooksController`, HMAC-verified
against `GITHUB_WEBHOOK_SECRET`), which enqueues `GithubWorkflowRunIngestJob` for an
idempotent, monotonic upsert into `GithubWorkflowRun`.

**Live CI progress bars — the `workflow_job` path.** The SAME receiver + ingest job
also handles **`workflow_job`** deliveries (per-CI-job lifecycle: queued →
in_progress → completed), upserting one `CiCheckJob` row per job — idempotent +
monotonic on the immutable `job_id`, mirroring the run upsert, and recording only
`CI`-workflow jobs. `Ci::ProgressReader` reads those rows **live-first**: a SHA whose
jobs are ingested folds straight from `CiCheckJob` (no network), and a SHA with none
(CI predating the subscription) falls back to the cached GitHub check-runs API read.
Each `CiCheckJob` upsert then morph-broadcasts the refreshed bar to the task card +
the Next Release G3 slot over Turbo Streams, so the board's CI progress bars **tick
up live with no reload** as each check passes.

**The review autopilot rides this same ingest.** After every `workflow_run` upsert
that carries a CONCLUSION, the job calls `ReviewPendingAction.trigger_for_head`
(repo + head_sha), which enqueues `ReviewPendingActionExecutionJob` for any ARMED
MERGE pinned to that exact tree — a reviewer's already-recorded merge-ready verdict,
waiting on CI. The trigger deliberately fires on ANY conclusion and judges none of
them: `Ci::ReviewGate` stays the single place that decides what green means, and
`Review::PendingActionExecutor` owns every guard. The trigger is best-effort and
rescued, so it can never break CI ingestion; a missed delivery is picked up by the
action's own recheck chain within minutes. Reviewer-facing docs:
`docs/agents/agents/carl/sops/pr-review-primary.md` step 6; CLI `bin/review-autopilot`.
Note the wiring dependency — only repos whose Actions webhook reaches this endpoint
can ever trigger it; an unwired repo's armed merge reads CI as `:none` forever and
expires unexecuted, which is the correct fail-closed outcome, not a silent pass.

**Prod-deploy approval gate — REMOVED 2026-07-20 (task `remove-prod-deploy-approval`).**
The `production` GitHub Environment's required-reviewer rule was deleted (a GitHub
setting), so a dispatched prod-deploy run now deploys straight through — it never
reaches a `waiting` state and the panel is never anything but the normal per-workflow
status rows. The whole in-app approval subsystem that used to service that gate is
GONE, not dormant: the recurring `waiting`-run poll (`ScanPendingDeploymentsJob` +
`Github::PendingDeploymentScanner`), the amber **awaiting approval** row and admin
**Approve deploy** button, the `/deployments/:run_id/approve` route +
`GithubDeploymentsController`, the `Github::DeploymentApprover`, the
`Devops::DeployApprovalNotifier` Discord nudge, and the ingest job's
`deployment_review` / `deployment_protection_rule` branch (with its
`pending_environment` stamp and pending scopes) were all deleted. If a required
reviewer or other environment protection is ever wanted again, it would be a fresh
build, not a re-enable. The `GITHUB_DEPLOY_APPROVAL_REPO` env var is retired with it.

The webhook receiver + ingest job are UNCHANGED for the two events that stay:
`workflow_run` (per-run status rows) and `workflow_job` (the live CI progress bars
above). The receiver is a dumb pass-through, so an unexpected event GitHub might still
deliver is simply ignored by the ingest job — no approval handling remains.

**Env vars for this vertical:**

| Var | Purpose |
|-----|---------|
| `GITHUB_WEBHOOK_SECRET` | HMAC secret verifying webhook deliveries (fail-closed). |
| `GITHUB_APP_ID` | Numeric id of the agent GitHub App (`github.mcritchie-agent`). Set this + `GITHUB_APP_PRIVATE_KEY` and the board mints its own tokens. |
| `GITHUB_APP_PRIVATE_KEY` | The App's RSA private key as PEM text (the `.pem` file contents, multi-line). Paired with `GITHUB_APP_ID` above. |
| `GITHUB_APP_INSTALLATION_ID` | *(optional)* Installation id to mint for. When blank, `Github::AppToken` discovers it from `/app/installations` by the match below. |
| `GITHUB_APP_INSTALLATION_MATCH` | *(optional)* Substring the installation account login must contain during discovery (default `mcritchie`). |
| `GITHUB_TOKEN` | Static fallback token — used by `Github::Client` / `Ci::ProgressReader` only when the App creds above are **absent** (dev/CI/local, or if a mint fails). Still holds the legacy `amcritchie` PAT, which post-migration reads public repos only. |

**GitHub App token minting (2026-07-30, task `board-mints-github-app-tokens`).**
The static `GITHUB_TOKEN` PAT can read public repos only after the 2026-07-29 org
migration, so private-repo reads (e.g. `mcritchie-industries`) fail server-side.
`Github::AppToken.resolve` now mints a GitHub App **installation** token (RS256
JWT → `POST /app/installations/{id}/access_tokens`, the same flow as
`bin/gh-app-mint-token`) and caches it in `Rails.cache` (~50 min, refreshed 10
min before GitHub's 1 h expiry). `Github::Client` defaults its `token:` to that
resolver. **This code ships inert until the ship lane provisions the config
vars** — with `GITHUB_APP_ID` + `GITHUB_APP_PRIVATE_KEY` unset it falls straight
back to `GITHUB_TOKEN`, so dev/CI/local are unchanged. To close the private-repo
acceptance, set these Heroku config vars on the board app:

- `GITHUB_APP_ID` — the agent App's numeric id (1Password `github.mcritchie-agent` → `app-id`).
- `GITHUB_APP_PRIVATE_KEY` — the App's `.pem` private key contents (1Password `github.mcritchie-agent` → the `.pem` file attachment).
- `GITHUB_APP_INSTALLATION_ID` and `GITHUB_APP_INSTALLATION_MATCH` are optional; leave them unset to auto-discover the `mcritchie` installation.

Never commit the webhook secret or any GitHub token.

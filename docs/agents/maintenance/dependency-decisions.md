# Dependency Decisions — the Dependabot backlog, with a verdict per cause

**Measured: 2026-09-10 05:00–06:00Z** by Steffon, read-only. No PR in this record
was merged, closed, rebased, re-run, or commented on to produce it.

This is a DECISION RECORD, not a status page. A Dependabot PR list answers "what
is open"; it never answers "why is this one still here". Every row below carries
a disposition and the evidence behind it, grouped by CAUSE rather than by repo,
because one cause usually explains many PRs and a per-repo list hides that.

> **Read the causes first, then the table.** Eight of these PRs were red four
> hours before this record was written and are green now, for a reason that has
> nothing to do with what they bump. A red Dependabot PR is not evidence about
> its own bump until you have named the cause.

## How to re-measure

Every number here is reproducible with read-only commands. Re-run these before
trusting any count; the tally moved twice during the measurement that produced it.

```bash
# open PRs per repo
gh pr list -R McRitchie-Studio/<repo> --author "app/dependabot" --state open \
  --json number,title,mergeStateStatus,headRefName

# CI verdict + job set (the CI GENERATION fingerprint) for one PR
gh pr view <n> -R McRitchie-Studio/<repo> --json statusCheckRollup,headRefOid

# base drift — how far behind `accepted` the PR's head actually is
gh api repos/McRitchie-Studio/<repo>/compare/accepted...<headRefOid>

# the failing job's own log (survives longer than the PR's summary)
gh api repos/McRitchie-Studio/<repo>/actions/jobs/<job-id>/logs

# DEPENDABOT'S OWN JOB LOG — the update run, not the CI run. This is where
# cooldown, ignore-conditions and suppressed proposals are visible. The workflow
# is named "<ecosystem> in /<dir> - Update #<id>".
gh api "repos/McRitchie-Studio/<repo>/actions/runs?per_page=100" \
  --jq '.workflow_runs[] | select(.name|test("Update #")) | "\(.id) \(.name) \(.created_at)"'
gh api repos/McRitchie-Studio/<repo>/actions/runs/<id>/logs > job.zip   # unzip, read "3_Run Dependabot.txt"

# ADVISORIES — the public GitHub Advisory Database answers even with repo alerts off
gh api "/advisories?ecosystem=rubygems&affects=<gem>" --jq '.[] | "\(.ghsa_id) \(.severity) \(.summary)"'
```

"We cannot see why Dependabot did that" is never a valid conclusion. The update
job's log states its decision for every dependency in plain text.

## Tally

**27 open · 4 RED · 11 FRESH-GREEN · 12 STALE-GREEN**

| Repo | Open | Red | Fresh-green | Stale-green |
|------|------|-----|-------------|-------------|
| mcritchie-studio | 13 | 1 | 0 | 12 |
| turf-monster | 13 | 2 | 11 | 0 |
| rolio | 1 | 1 | 0 | 0 |
| studio-engine · solana-studio · turf-vault | 0 | 0 | 0 | 0 |

**What moved since the 2026-09-09 21:00Z measurement.** That pass recorded **12
RED / 15 GREEN**. It is now **4 RED / 23 GREEN**, on the same 27 PRs. Nine
turf-monster PRs were merge-updated at 2026-09-10T00:39Z (commits titled
`Merge branch 'accepted' into dependabot/…`, authored by `mcritchie-agent[bot]`);
eight of the nine went green and one, #261, did not. Nothing else changed hands.
The earlier record's headline — one defect explaining nine reds — held for eight
of nine, and the ninth turned out to be masking a second, unrelated cause that
only became visible once the first was cleared.

**Freshness is not the same as green.** A green from a CI job set that no longer
exists certifies a workflow the repo has since deleted. Current job sets:

| Repo | Current CI generation | Retired generation |
|------|----------------------|--------------------|
| mcritchie-studio | `static · island_animator · playwright(1-3) · rails(1-4) · rails_executed_set · e2e_executed_set · system` (12) | `lint · scan_js · scan_ruby · test` |
| turf-monster | `static · test · playwright(1-3) · e2e_declared_set · e2e_executed_set` (7) | `lint · scan_js · scan_ruby · test` |
| rolio | `scan_ruby · scan_js · lint · test` (4) | — (never re-generationed) |

Every mcritchie-studio PR here is STALE-GREEN: none has re-run, and they sit
between 180 and 2144 commits behind `accepted`. Four of them (#556, #557, #707,
#708) still show the RETIRED job set, so their verdict — green or red — describes
a pipeline the repo no longer runs.

---

## The causes

### CAUSE-A · The PR rewrites a pin the Gemfile deliberately documents

Four PRs propose exactly the major their own Gemfile refuses in a written comment.
These are not stale, not broken CI, and not a judgement call: the repo already
made the decision and wrote down why.

`mcritchie-studio/Gemfile`, at `accepted`:

```ruby
# minitest 6.0 dropped minitest/mock (Object#stub / Minitest::Mock); the suite
# relies on Object#stub. Rails only needs >= 5.15, so pin to the 5.x line.
gem "minitest", "~> 5.25"
```

```ruby
# Lift either one deliberately, in its own task, with the suite behind it.
gem "redis", "~> 5.4"
```

The minitest break is structural, not a CI artifact: minitest's latest is 6.0.6
and `minitest-mock` is now a **separate gem** on RubyGems (latest 5.27.0). No
re-run can change that.

**Disposition: CLOSE all four, and add `ignore` entries.** Closing alone is not
enough — see CONFIG-7 for what a bare close actually does, and CONFIG-3 for why
nothing is currently suppressed. Scope each entry to the major —
`update-types: ["version-update:semver-major"]` — never a bare `dependency-name`:
GitHub applies `ignore` "when it opens pull requests for version updates and
security updates", so a bare entry would silence a patched 5.x redis or minitest
the day CONFIG-1 is switched on.

### CAUSE-B · Superseded — the tree is already past the proposed version

rolio #26 proposes selenium-webdriver 4.46.0. Both `accepted` and `main` already
carry **4.47.0**, which is why the PR is `DIRTY` on `Gemfile.lock`. There is
nothing to merge. Its red (`scan_ruby`, 2026-07-13) was a GitHub Actions
control-plane outage — `Failed to resolve action download info. Error: Service
Unavailable` — and is irrelevant either way.

**Disposition: CLOSE.**

### CAUSE-C · Two PRs, one change — but not the duplicate we thought

mcritchie-studio #1245 (sentry-ruby) and #1246 (sentry-rails) both move
sentry-ruby AND sentry-rails to 7.0.0 in the same lock hunk, because
sentry-rails 7.0.0 requires `sentry-ruby ~> 7.0.0`. Their sentry hunks are
identical.

They are **not** otherwise equivalent, and the earlier record's advice to keep
#1245 is **inverted here**. #1245 is a 4-line lock diff, 322 commits behind.
#1246 is a 14-line lock diff, **180 commits behind**, with a newer CI run, and
its ten extra transitive bumps include:

```diff
-    rails-html-sanitizer (1.7.0)
-      loofah (~> 2.25)
+    rails-html-sanitizer (1.7.1)
+      loofah (~> 2.25, >= 2.25.2)
```

A tightened *minimum* on loofah inside a sanitizer bump is the shape an advisory
fix takes, and the public Advisory Database confirms it despite CONFIG-1 (read in
review, 2026-09-10): GHSA-cj75-f6xr-r4g7 (rails-html-sanitizer `< 1.7.1`, XSS) and
GHSA-9wjq-cp2p-hrgf (loofah `< 2.25.2`), both medium. Both apps' `accepted` locks
carry the vulnerable 1.7.0 / 2.25.1. Neither is reachable today — each needs the
sanitizer allow-list widened to SVG `<use>` or `<feImage>`, and neither app
widens it — but in the hub this HOLD is the only PR carrying the fix (turf-monster
gets it from #258), so see step 1 below.

**Disposition: KEEP #1246, CLOSE #1245.** Taking the smaller diff would discard
the sanitizer bump for no gain.

### CAUSE-D · The shared empty-secret defect — fixed, and now proven twice over

Dependabot PRs run against the **Dependabot** secret store and cannot read
**repository** secrets, by design. `SOLANA_ADMIN_KEY` and `RAILS_MASTER_KEY` are
repository secrets, so they arrived empty, `Solana::Keypair.admin` hard-raised,
and every turf-monster dependency PR failed the same `test` job permanently. This
was fixed on `accepted` on 2026-09-02 in **dce79349**, "Let Solana unit tests run
without production credentials", which adds test-only fallbacks reachable only
under `Rails.env.test?`.

Two independent proofs, and they prove different things — keep them apart:

- **The genuine Dependabot path is fixed.** turf #461 and #462 ran at
  2026-09-10T02:14Z as `dependabot[bot]`, `Secret source: Dependabot`, with
  `SOLANA_ADMIN_KEY:` and `RAILS_MASTER_KEY:` both **empty** in the job env, and
  finished `4033 runs, 19136 assertions, 0 failures, 0 errors, 2 skips`.
- **The eight merge-updated greens do NOT prove that.** They ran at 00:39Z under
  `Secret source: Actions` with `SOLANA_ADMIN_KEY: ***` populated, because the
  merge commit is authored by `mcritchie-agent[bot]` and a PR whose head is an
  agent commit is no longer a Dependabot-triggered run. They are real greens on
  the current tree; they say nothing about the secret path.

The distinction matters the moment Dependabot rebases one of those branches
itself, dropping the merge commit and returning it to the Dependabot secret
store. dce79349 is what keeps it green then, and #461/#462 are the proof.

**Disposition: the reds in this group are resolved.** Each member now stands or
falls on its own bump — see the table.

### CAUSE-E · The red the shared cause was hiding

turf-monster **#261** (sidekiq-cron 1.12.0 → 2.4.0) was merge-updated in the same
wave and stayed red. Its `test` job (run 34422198615, job 102699856611,
2026-09-10T00:43:45Z) reports `4011 runs, 18985 assertions, 0 failures, 1 errors, 2 skips`
— and the single error is:

```
Error:
SidekiqCronScheduleTest#test_a_scheduled_tick_enqueues_each_job_instead_of_raising:
NoMethodError: undefined method `enque!' for an instance of Sidekiq::Cron::Job
    test/initializers/sidekiq_cron_schedule_test.rb:75:in `block (3 levels) in <class:SidekiqCronScheduleTest>'
```

sidekiq-cron 2.0.0 renamed `enque!` to `enqueue!`. At `origin/accepted`,
`git grep -n "enque!"` across `test app lib config` returns **exactly one line** —
that one. So this is no longer an estimate: the entire migration is one renamed
method call in one test file, and the other 4008 tests pass on 2.4.0 (2 skip).

That makes #261 the **best-understood major on the board**, and it is worth more
than its size: sidekiq-cron 2.0.0 carries PR #510, "Fix detection of ActiveJob in
Sidekiq v7.3.3+" — the exact bug this ecosystem worked around by stamping
`active_job: true` on all six entries of `config/schedule.yml`, after all four
turf-monster crons ran dead in both environments from 2026-08-22 to 2026-08-26,
the stranded-deposit reconciler among them, while `/admin/jobs` still listed them
as registered. Upgrading removes the landmine instead of stepping around it.

**Disposition: HOLD for a scheduled task, with the migration pre-measured.**

### CAUSE-F · Trivial — runtime/ESM action bumps with no input change

Six PRs move GitHub Actions across majors that are Node-runtime and ESM
migrations only. `actions/cache` v5 is "upgrade to node24" and v6 is "migrate to
ESM"; no input or output changed. `actions/setup-node` v5 adds auto-caching only
when `package.json` declares a `packageManager` field — neither repo has one.
`actions/download-artifact` v5 changed path behaviour for downloads **by artifact
ID**; both repos download by `pattern:` with `merge-multiple: true`, never by ID.

### CAUSE-G · Lock-only minors and patches

No API surface, no migration, within-major. Nothing to decide beyond taking them.

---

## The table

Disposition vocabulary: **MERGE** (take it) · **CLOSE** (do not take it, reason
recorded) · **HOLD** (needs its own task; do not take it from a Dependabot PR).

### mcritchie-studio — 13 open

| PR | Package | Change | Major | CI | Behind | Cause | Disposition |
|----|---------|--------|-------|-----|--------|-------|-------------|
| #971 | actions/cache | 4 → 6 | MAJOR | STALE-GREEN | 1095 | CAUSE-F | MERGE |
| #557 | actions/setup-node | 4 → 7 | MAJOR | STALE-GREEN (retired gen) | 2144 | CAUSE-F | MERGE |
| #556 | actions/download-artifact | 4 → 8 | MAJOR | STALE-GREEN (retired gen) | 2144 | CAUSE-F | MERGE |
| #1199 | omniauth-google-oauth2 | 1.2.2 → 1.2.3 | patch | STALE-GREEN | 426 | CAUSE-G | MERGE |
| #1098 | selenium-webdriver | 4.32.0 → 4.48.0 | minor | STALE-GREEN | 426 | CAUSE-G | MERGE |
| #1099 | resend | 1.6.0 → 1.13.0 | minor | STALE-GREEN | 757 | CAUSE-G | MERGE |
| #1246 | sentry-rails (+ sentry-ruby) | 6.7.0 → 7.0.0 | MAJOR | STALE-GREEN | 180 | CAUSE-C | HOLD |
| #1245 | sentry-ruby | 6.7.0 → 7.0.0 | MAJOR | STALE-GREEN | 322 | CAUSE-C | CLOSE |
| #1247 | image_processing | 1.14.0 → 2.1.0 | MAJOR | STALE-GREEN | 322 | CAUSE-G | HOLD |
| #1056 | brakeman | 7.1.1 → 8.0.6 | MAJOR | STALE-GREEN | 868 | CAUSE-G | HOLD |
| #708 | puma | 7.2.0 → 8.0.2 | MAJOR | STALE-GREEN (retired gen) | 1782 | CAUSE-G | HOLD |
| #1058 | redis | 5.4.1 → 6.0.0 | MAJOR | STALE-GREEN | 180 | CAUSE-A | CLOSE |
| #707 | minitest | 5.27.0 → 6.0.6 | MAJOR | RED (retired gen) | 1442 | CAUSE-A | CLOSE |

### turf-monster — 13 open

| PR | Package | Change | Major | CI | Behind | Cause | Disposition |
|----|---------|--------|-------|-----|--------|-------|-------------|
| #258 | omniauth-rails_csrf_protection | 1.0.2 → 2.0.1 | MAJOR | FRESH-GREEN | 46 | CAUSE-D | MERGE |
| #371 | actions/cache | 4 → 6 | MAJOR | FRESH-GREEN | 46 | CAUSE-F | MERGE |
| #370 | actions/download-artifact | 4 → 8 | MAJOR | FRESH-GREEN | 46 | CAUSE-F | MERGE |
| #179 | actions/setup-node | 4 → 7 | MAJOR | FRESH-GREEN | 46 | CAUSE-F | MERGE |
| #457 | bootsnap | 1.23.0 → 1.25.0 | minor | FRESH-GREEN | 46 | CAUSE-G | MERGE |
| #458 | selenium-webdriver | 4.32.0 → 4.47.0 | minor | FRESH-GREEN | 46 | CAUSE-G | MERGE |
| #461 | simplecov | 0.22.0 → 1.2.0 | MAJOR | FRESH-GREEN | 36 | CAUSE-G | MERGE |
| #462 | sidekiq | 7.3.10 → 8.1.7 | MAJOR | FRESH-GREEN | 36 | CAUSE-G | HOLD |
| #463 | brakeman | 7.1.1 → 8.0.6 | MAJOR | FRESH-GREEN | 46 | CAUSE-G | HOLD |
| #459 | puma | 7.2.0 → 8.0.2 | MAJOR | FRESH-GREEN | 46 | CAUSE-G | HOLD |
| #261 | sidekiq-cron | 1.12.0 → 2.4.0 | MAJOR | RED | 46 | CAUSE-E | HOLD |
| #460 | redis | 5.4.1 → 6.0.0 | MAJOR | FRESH-GREEN | 62 | CAUSE-A | CLOSE |
| #253 | minitest | 5.27.0 → 6.0.6 | MAJOR | RED (retired gen) | 1112 | CAUSE-A | CLOSE |

### rolio — 1 open

| PR | Package | Change | Major | CI | Behind | Cause | Disposition |
|----|---------|--------|-------|-----|--------|-------|-------------|
| #26 | selenium-webdriver | 4.32.0 → 4.46.0 | minor | RED | 17 | CAUSE-B | CLOSE |

---

## Migration cost — one sentence per major

Every MAJOR above, with what it would actually cost. Sorted cheapest first.

| PR | Major | Migration cost |
|----|-------|----------------|
| #971 · #371 | actions/cache 4 → 6 | Node 24 runtime then an ESM rewrite, with no input or output changed — the safest merge on the board. |
| #557 · #179 | actions/setup-node 4 → 7 | v5's auto-caching engages only on a `packageManager` field in `package.json`, which neither repo has, so behaviour is unchanged. |
| #556 · #370 | actions/download-artifact 4 → 8 | v5's breaking change applies only to downloads by artifact ID and both repos download by `pattern:`, leaving v8's `digest-mismatch`-is-an-error flip as the sole live change. |
| #258 | omniauth-rails_csrf_protection 1 → 2 | Zero work: v2 only drops the `ActiveSupport::Configurable` include that Rails 8.2 removes, and mcritchie-studio already runs 2.0.1 in production. |
| #261 | sidekiq-cron 1 → 2 | Exactly one line — rename `enque!` to `enqueue!` at `test/initializers/sidekiq_cron_schedule_test.rb:75`, the only call site at `accepted`, measured against a run where every other test passed. |
| #461 | simplecov 0 → 1 | Nine deprecation warnings and a moved percentage: `add_group`/`add_filter` still work, and the only threshold is gated behind `ENFORCE_COVERAGE=1`, which CI does not set. |
| #1056 · #463 | brakeman 7 → 8 | Nothing to migrate — neither removed flag is used and no `brakeman.ignore` exists — but the constant-lookup fix can surface new findings that redden `static`, so it costs one CI run to learn. |
| #708 · #459 | puma 7 → 8 | The production bind default moves from `0.0.0.0` to `::`, and both `config/puma.rb` files bind with a bare `port ENV.fetch("PORT", 3000)`, so it costs a QA dyno boot to confirm the web dyno still binds. |
| #1247 | image_processing 1 → 2 | The soft-dependency half is already done in the Gemfile, leaving a visual check that sharpening-after-resize being off has not degraded generated variants. |
| #1245 · #1246 | sentry 6 → 7 | Logs and metrics become on-by-default with their opt-out switches removed, so it costs one deliberate `config.rails.structured_logging.enabled = false` plus a Sentry quota and PII decision. |
| #462 | sidekiq 7 → 8 | The code is fine and the deploy is the risk: timestamps move from epoch floats to milliseconds, so the queue must be drained before the prod deploy and `/admin/jobs` eyeballed on QA after Sidekiq::Web's CSS rewrite. |
| #1058 · #460 | redis 5 → 6 | RESP3 becomes the default protocol underneath ActionCable's production WebSocket pub/sub on both apps, which is a deliberate cross-app task and not a lock bump. |
| #707 | minitest 5 → 6 | An afternoon minimum: `minitest/mock` is now a separate gem, and mcritchie-studio has 177 `.stub(` call sites across 55 files with 19 requiring `minitest/mock`, on top of opt-in plugin loading that threatens `bin/rails test` itself. |
| #253 | minitest 5 → 6 | The same break at roughly 3.5x mcritchie-studio's size — 613 `.stub` call sites across 122 files, most in the paren-less `Klass.stub :name, value do` form a `.stub(` grep misses, with 34 requiring `minitest/mock` — so the earlier 599 estimate stands. |

---

## Config findings — these are not PR findings

Fixing any PR above leaves all of these in place.

### CONFIG-1 · Dependabot security alerts are DISABLED on all six repos

Verified three independent ways on 2026-09-10:

```
GET /repos/McRitchie-Studio/<repo>/dependabot/alerts
  → 403 "Dependabot alerts are disabled for this repository."   (all six)
GET /repos/McRitchie-Studio/<repo>/vulnerability-alerts
  → 404                                                          (all six)
GET /repos/McRitchie-Studio/<repo> .security_and_analysis
  → dependabot_security_updates: disabled
    secret_scanning: disabled
    secret_scanning_push_protection: disabled
    secret_scanning_validity_checks: disabled
```

Five of the six are **public**: mcritchie-studio, turf-monster, studio-engine,
solana-studio, turf-vault. turf-monster carries the Stripe and Solana money path.

So: no advisory is surfaced anywhere, no security update PR will ever open, and
secret-scanning push protection is off on five public repos. The version-update
lane is the ecosystem's only dependency signal — and both bundler lanes of it are
jammed (CONFIG-2). This is an OPSEC item, not a dependency chore, and it is the
most consequential thing in this record.

**Not changed by this task.** Enabling repository security features is an
operator decision with its own blast radius (push protection can block pushes),
and this task's shape is `docs`.

### CONFIG-2 · Both bundler lanes are still at the 10/10 cap

`.github/dependabot.yml` sets `open-pull-requests-limit: 10` per ecosystem in both
apps. Measured 2026-09-10:

| Repo | bundler | github_actions |
|------|---------|----------------|
| mcritchie-studio | **10/10** | 3/10 |
| turf-monster | **10/10** | 3/10 |

Neither app can open another Ruby dependency PR until a slot is freed. The
backlog is not merely untidy; it is suppressing new updates. Five of the twenty
bundler slots are held by PRs this record disposes of as CLOSE.

### CONFIG-3 · Nothing is suppressed by policy — `ignore-conditions` is empty

From the update job's own definition, quoted:

```json
"ignore-conditions":[]
```

Neither `dependabot.yml` carries an `ignore` block. The two pins the Gemfiles
document at length — minitest 5.x and redis 5.4 — are therefore re-proposed
forever and permanently occupy bundler slots. This is the concrete fix CAUSE-A
depends on; a close without it just buys time.

### CONFIG-4 · The default 3-day cooldown is armed, and is currently binding on nothing

Neither config sets a `cooldown` key, and Dependabot applies its default anyway:

```
Initializing cooldown filter
Days since release : 79 (cooldown days 3)
```

Every candidate in today's run was 76–1319 days past release, so the cooldown
explains no stuck bump today. Recorded so the next reader does not re-derive it —
it becomes live only for a dependency that ships more often than every three
days, which is never bumpable under the default.

### CONFIG-5 · rolio has no `dependabot.yml`, and its actions are frozen

`GET /repos/McRitchie-Studio/rolio/contents/.github/dependabot.yml` returns **404
on both `accepted` and `main`**. #26 is an orphan and no further bumps are coming.
rolio's workflows still pin `actions/checkout@v4` in four places while
mcritchie-studio and turf-monster are on `@v7`.

### CONFIG-6 · turf-monster's Gemfile has no redis ceiling

| Repo | Declaration |
|------|-------------|
| mcritchie-studio | `gem "redis", "~> 5.4"` — a documented major guard |
| turf-monster | `gem "redis", ">= 4.0.1"` — **no ceiling** |

Two apps, the same ActionCable RESP3 exposure, one guard. redis 6 can walk into
turf-monster on any bundle resolve. Add the ceiling before lifting redis anywhere.

### CONFIG-7 · A closed Dependabot PR is a permanent, invisible suppression

From mcritchie-studio's own Dependabot update job, run 34438891868, today at
2026-09-10T04:53:52Z:

```
Latest version is 7
Pull request #2 already exists for actions/upload-artifact with latest version 7
```

**PR #2 was closed, unmerged, on 2026-05-24.** Dependabot still counts it as
existing and will not open another. Both mcritchie-studio and turf-monster use
`actions/upload-artifact@v4` in four workflow steps each, and both are parked
there by that close — in a `github_actions` lane holding **3 of 10** slots, with
seven free.

This corrects the earlier record, which said Dependabot had never proposed an
upload-artifact bump. It proposed one and someone closed it, and nothing anywhere
records that decision or its reason. The same is true of turf #3
(`actions/setup-node` 4 → 6) and of every other close in the census.

The consequence for this record's own advice: **CLOSE without an `ignore` entry
buys a slot and loses the reason.** Every CLOSE below is paired with either an
`ignore` entry (CAUSE-A, a standing policy) or a written supersession
(CAUSE-B/CAUSE-C, a one-time fact).

---

## What to do, in order

1. **Escalate CONFIG-1.** It outranks every PR in this record. Meanwhile take
   the patched sanitizer pair in the hub on its own, not behind #1246 (CAUSE-C):
   `bundle update --conservative rails-html-sanitizer loofah`; turf #258 carries
   it. puma 7.2.0's two HIGH advisories (GHSA-2vqw-3mp8-cgmx, GHSA-qpgp-93vx-g8v8,
   fixed in 7.2.1) need `set_remote_address proxy_protocol: :v1`, which neither
   app sets.
2. **Close six and add the `ignore` entries** — #707, #253, #1058, #460 (CAUSE-A,
   with major-scoped `ignore` for minitest and redis in both configs), #26 (CAUSE-B), #1245
   (CAUSE-C). Frees five of the twenty jammed bundler slots and stops three
   changes the Gemfiles already refuse from being re-proposed forever.
3. **Merge the thirteen trivials** — turf #258 first (a Rails 8.2 removal blocker with
   zero migration, already proven in the hub), then the six action bumps
   (#971, #557, #556, #371, #370, #179) and the lock-only gems (#1199, #1098,
   #1099, #457, #458, #461).
4. **Schedule the majors as their own tasks**, never merged from a Dependabot PR:
   sidekiq-cron 2 (#261, one line, removes the cron landmine) · puma 8 (#708,
   #459, one QA bind check) · brakeman 8 (#1056, #463, one CI run) · sidekiq 8
   (#462, a deploy-time queue drain) · sentry 7 (#1246, a logs/PII decision) ·
   image_processing 2 (#1247, a variant eyeball) · redis 6 across both apps,
   after CONFIG-6.
5. **File the follow-ons**: upload-artifact is parked at v4 in both apps by a
   closed PR (CONFIG-7), and rolio needs a `dependabot.yml` plus a CI generation
   refresh (CONFIG-5).

## What this record cannot tell you

It is a snapshot, and the tally moved twice while it was being written. Nothing in
CI re-measures GitHub for you. `test/docs/dependency_decisions_docs_test.rb`
guards the record's internal consistency and pins the three repo-local claims it
makes about `.github/` — so acting on this record's own advice turns that test
red and forces a refresh — but a PR merged, closed, or rebased on GitHub changes
none of those files and will go unnoticed. **Re-run the commands at the top before
trusting a count.**

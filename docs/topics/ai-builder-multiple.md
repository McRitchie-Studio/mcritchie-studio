# AI Builder Multiple

This v0 backtest tracks public GitHub commit pace for selected builders. It is
a builder-activity index, not a productivity measure.

## Metric

- **Builder Weekly Commits** — public commits attributed to a tracked GitHub
  login during a Saturday-Friday UTC week.
- **Commit Range** — the explicit Saturday-Friday UTC period used for the
  displayed weekly commit log. Dashboard headers show the Friday end date.
- **Builder Baseline** — average weekly non-merge commits over the prior 90
  days before that week.
- **Builder Multiple** — non-merge weekly commits divided by that builder's
  prior 90-day average weekly non-merge commits.
- **AI Builder Multiple** — median Builder Multiple for the `ai_builder` cohort.
- **Control Builder Multiple** — median Builder Multiple for the
  `control_builder` cohort.
- **Difficulty-Adjusted AI Builder Multiple** — AI Builder Multiple divided by
  Control Builder Multiple.

Bot-adjusted commit pace is also stored. It excludes obvious bot commits and
merge commits from both the weekly count and its internal 90-day baseline.
When the same commit SHA appears from overlapping GitHub API strategies or
repository aliases, the weekly aggregator counts it once for that builder.

## Data Source

The v0 source is GitHub's public API through `Github::Client`.
`Github::CommitFetcher` uses repo-scoped commit listing when a tracked builder
has active repos, and falls back to commit search when no repos are attached.
If the repo-scoped result is too sparse for the requested window, the fetcher
can supplement with commit search so a narrow repo list does not make a builder
look inactive. `GITHUB_REPO_SCOPE_MIN_OBSERVATIONS` controls that threshold,
and `GITHUB_SEARCH_RANGE_DAYS` controls the search date-window size. This keeps
the adapter replaceable by GH Archive, BigQuery, or another public commit source
later.

Set `GITHUB_TOKEN` in the environment to raise API limits:

```bash
GITHUB_TOKEN=github_pat_... bin/rails github:ai_builder_multiple:backtest START=2021-07-24 END=2026-06-12
```

Do not print or commit the token. Store long-lived credentials in 1Password.

## Running A Backtest

```bash
bin/rails github:ai_builder_multiple:backtest START=2021-07-24 END=2026-06-12
```

Use `LOGIN=amcritchie` or `LOGINS=login_one,login_two` to fetch a targeted
builder subset while still recalculating weekly metrics and index rows from all
stored observations.

Use `SKIP_FETCH=1` to run the regression from stored observations only. This is
useful after importing a large control-candidate list, because users without
repo scopes would otherwise require broad GitHub commit search.

For ad hoc user fetches, use the tracked builder model rather than the app's
`Person` model:

```ruby
builder = TrackedGithubBuilder.find_by!(github_login: "amcritchie")
builder.current_week_commits
builder.last_week_commits
builder.last_year_commits
builder.last_five_commits
```

Class helpers are also available:

```ruby
TrackedGithubBuilder.last_week_commits("amcritchie")
```

The fetch windows use the same Saturday-Friday UTC calendar as the dashboard.
`last_five_commits` is the five-year report window, starting `2021-07-24` and
ending at the latest complete Friday. Each helper stores raw commit
observations and refreshes that builder's `GithubBuilderWeeklyMetric` plus
`GithubBuilderCommitRangeCache` rows for the requested window. Long search
fetches publish cache rows after each fetched date segment, then run one final
full-window aggregation pass so the dashboard can fill in while the job runs and
still ends with complete zero-commit weeks.

Two task shortcuts fetch common windows and then recalculate metrics/index rows
and CSV exports for that window:

```bash
bin/rails github:ai_builder_multiple:fetch_last_week
bin/rails github:ai_builder_multiple:fetch_last_five_years
```

Use `LOGIN=amcritchie` or `LOGINS=login_one,login_two` while testing. The full
five-year task across the large control pool can require broad GitHub commit
search for builders without repo scopes.

For the large control-candidate pool, run the five-year history in resumable
batches. The batch task skips builders that already have a complete
Saturday-Friday cache for the five-year window and prints progress after each
GitHub search date segment:

```bash
GITHUB_REQUEST_PAUSE_SECONDS=3 \
GITHUB_RATE_LIMIT_PAUSE_SECONDS=180 \
GITHUB_RATE_LIMIT_RETRIES=5 \
bin/rails github:ai_builder_multiple:fetch_last_five_years_batch BATCH_SIZE=10
```

Use `START_AFTER=github_login` to continue from a known login, `COHORT=ai_builder`
or `COHORT=control_builder` to limit the batch, and `SKIP_COMPLETE=false` to
force a refresh of already-complete builders.

Rate-limit and pacing knobs:

```bash
GITHUB_REQUEST_PAUSE_SECONDS=0.25 \
GITHUB_BUILDER_PAUSE_SECONDS=2 \
GITHUB_RATE_LIMIT_PAUSE_SECONDS=900 \
GITHUB_RATE_LIMIT_RETRIES=4 \
bin/rails github:ai_builder_multiple:fetch_last_week
```

`GITHUB_REQUEST_PAUSE_SECONDS` pauses after successful GitHub HTTP requests.
`GITHUB_BUILDER_PAUSE_SECONDS` pauses between tracked builders.
`GITHUB_RATE_LIMIT_PAUSE_SECONDS` and `GITHUB_RATE_LIMIT_RETRIES` control retry
behavior after a GitHub rate-limit response. `GITHUB_SEARCH_RANGE_DAYS` can be
lowered to make global commit search windows smaller. The fetch shortcuts use
the exact target window by default; set `FETCH_WARMUP_DAYS=90` when you want to
fetch baseline warmup data too.

Paul Miller's historic active GitHub users list can be imported as a large
control-candidate pool:

```bash
bin/rails github:ai_builder_multiple:import_paulmillr_active_users MAX=910
bin/rails github:ai_builder_multiple:backtest START=2021-07-24 END=2026-06-12 SKIP_FETCH=1
```

The runner fetches a 90-day warmup before `START` so the first target week can
have baseline context. Weekly metrics and index weeks are upserted, so reruns
do not duplicate commit observations.

The aggregator also writes `GithubCommitRange` rows and
`GithubBuilderCommitRangeCache` rows. These are the dashboard-facing weekly
commit log: one cached builder/range row per tracked builder per
Saturday-Friday UTC period, including zero-commit weeks.

CSV exports are written to:

```text
tmp/ai_builder_multiple/
```

The files are:

- `github_builder_weekly_metrics.csv`
- `github_builder_commit_range_caches.csv`
- `github_builder_index_weeks.csv`
- `github_commit_observations_sample.csv`

Inspect the latest dashboard at:

```text
/admin/ai_builder_multiple
```

The dashboard commit log loads the latest 9 cached Saturday-Friday UTC ranges
by default. The full five-year commit cache table is available at:

```text
/admin/ai_builder_multiple/commit_history
```

The same latest index data is also available as JSON:

```text
/admin/ai_builder_multiple.json
```

## Caveats

Public commits are an incomplete proxy for build velocity. They miss private
work, planning, review, design, issue triage, experiments that are not pushed,
and work committed under different identities. The cohort seed data is only a
starting candidate list and should be reviewed before analysis.

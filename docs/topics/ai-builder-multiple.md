# AI Builder Multiple

This v0 backtest tracks public GitHub commit pace for selected builders. It is
a builder-activity index, not a productivity measure.

## Metric

- **Builder Weekly Commits** — public commits attributed to a tracked GitHub
  login during a Monday-starting week.
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

## Data Source

The v0 source is GitHub's public API through `Github::Client`.
`Github::CommitFetcher` uses repo-scoped commit listing when a tracked builder
has active repos, and falls back to commit search when no repos are attached.
This keeps the adapter replaceable by GH Archive, BigQuery, or another public
commit source later.

Set `GITHUB_TOKEN` in the environment to raise API limits:

```bash
GITHUB_TOKEN=github_pat_... bin/rails github:ai_builder_multiple:backtest START=2025-06-01 END=2026-06-01
```

Do not print or commit the token. Store long-lived credentials in 1Password.

## Running A Backtest

```bash
bin/rails github:ai_builder_multiple:backtest START=2025-06-01 END=2026-06-01
```

The runner fetches a 90-day warmup before `START` so the first target week can
have baseline context. Weekly metrics and index weeks are upserted, so reruns
do not duplicate commit observations.

CSV exports are written to:

```text
tmp/ai_builder_multiple/
```

The files are:

- `github_builder_weekly_metrics.csv`
- `github_builder_index_weeks.csv`
- `github_commit_observations_sample.csv`

Inspect the latest dashboard at:

```text
/admin/ai_builder_multiple
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

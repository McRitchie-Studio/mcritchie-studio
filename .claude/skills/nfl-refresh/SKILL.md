---
name: nfl-refresh
description: Weekly NFL roster + depth-chart refresh. Pulls nflverse for new players (rookies, signings, call-ups), runs ESPN depth-chart scrape to update positions/depth/team movement. Run before each game week to keep starting lineups current.
disable-model-invocation: true
allowed-tools: Bash
---

# NFL Refresh — Weekly Roster Update

Quick refresh that keeps starting lineups + depth charts current. Non-destructive — only adds/updates records, never drops anything. Run weekly during the season.

## Preconditions

1. **Storage credentials** for any new-player headshots (uploaded through `Studio::S3` to Cloudflare R2; AWS retired 2026-10): `grep -c '^R2_ACCESS_KEY_ID=.' .env.development` should print `1` (dev pair from 1Password `r2.mcritchie-studio`). If missing, new players seed without headshots — re-run later when creds are available.
2. **Postgres running**: `pg_isready`.

## Steps

### Step 1 — nflverse player delta

Re-pulls `players.csv`. For new entries (rookies, just-signed UDFAs), creates Person + Athlete with cross-ref IDs and caches headshots. For existing players, updates IDs and any changed metadata (height/weight rare, team_abbr more common).

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:players_seed > tmp/players_refresh.log 2>&1
echo "exit: $?"
tail -10 tmp/players_refresh.log
```

Expect: most rows are no-ops (`athletes_updated`); a small number of `athletes_created` and `headshots_cached` for genuinely new entries.

### Step 2 — ESPN depth-chart scrape

Updates depth + position assignments per ESPN's current published charts. Locked DepthChartEntries (manual overrides) are preserved. Players who've moved teams: contract on old team gets expired, new active contract created, Athlete.team_slug updated.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails espn:scrape_depth_charts > tmp/espn_refresh.log 2>&1
echo "exit: $?"
tail -15 tmp/espn_refresh.log
```

Expect: `teams_scraped: 32`, mostly no-op moves with a handful of `contracts_created` / `contracts_expired` / `team_slug_updates` reflecting roster changes since last refresh.

## Verification

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails runner '
  recent = Athlete.where("updated_at > ?", 1.hour.ago).count
  fresh_contracts = Contract.where("created_at > ?", 1.hour.ago).count
  expired_today = Contract.where(expires_at: Date.today - 1).count
  puts "Athletes updated in last hour: #{recent}"
  puts "Contracts created in last hour: #{fresh_contracts}"
  puts "Contracts expired today (team moves): #{expired_today}"
'
```

If `recent` is 0 something silent went wrong upstream — check the log files. If everything ran cleanly but no records changed, that's normal during dead spots in the league calendar (e.g. mid-week non-game days).

## Single-team refresh

When debugging or after a known-only roster move, scrape one team:

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails espn:scrape_depth_charts TEAM=buf VERBOSE=1
```

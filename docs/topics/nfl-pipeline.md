# NFL Data Pipeline

> **When to read this:** Modifying NFL data ingest (Nflverse, Spotrac, ESPN scrape), athlete identity/cross-ref columns, duplicate merging, position normalization, or coach headshots.

## Three-Layer Pipeline

Three layered services, each authoritative for one slice of state. Run the full NFL rebuild workflow for a complete reset, or the weekly NFL refresh workflow for in-season deltas.

### 1. `Nflverse::SeedPlayers`
`app/services/nflverse/seed_players.rb`, rake `nfl:players_seed` — identity backbone.

Pulls `players.csv` from nflverse-data GitHub release (~24k rows, default filter is `last_season>=2024` only — no status filter so UFA/RES/PUP veterans like Hunt/Harris/Waller are included). Upserts Person + Athlete with all five cross-ref IDs (`gsis_id`, `espn_id`, `pff_id`, `otc_id`, `pfr_id`, `nflverse_id`). Lookup priority is `gsis_id` (anchor) → `pff_id` → `otc_id` → `espn_id` → `pfr_id` → `person_slug` (name match) → create. Sets `Athlete.team_slug` from `latest_team` and caches ESPN headshots to S3 inline (idempotent, skipped without AWS creds). The `team_slug` here is provisional — Spotrac and ESPN authoritatively overwrite below. Optional env: `STATUS=ACT` to re-narrow, `MIN_SEASON=2025` to scope tighter.

### 2. `Spotrac::SyncContracts`
`app/services/spotrac/sync_contracts.rb`, rake `nfl:salaries_sync` — salary overlay.

Reads `db/seeds/data/spotrac_contracts_2025.json` (committed, ~2,500 entries — **season-specific snapshot, replace per season**), matches Athletes by `otc_id` then name fallback, upserts active Contracts with `annual_value_cents` and `expires_at` (end_year → March 15 of that year). Updates `Athlete.team_slug` per the contract-update rule.

### 3. `Espn::ScrapeDepthCharts`
`app/services/espn/scrape_depth_charts.rb`, rake `espn:scrape_depth_charts` — current-roster + depth truth.

Hits `https://www.espn.com/nfl/team/depth/_/name/{abbrev}` per team (data embedded in `window['__espnfitt__']`). Auto-creates DepthChart shells and Contracts for ESPN-listed players we don't have yet (UDFAs, mid-season call-ups). When a player has shifted teams, expires the old active Contract and creates the new one. Updates `Athlete.team_slug`. Stores both `position` (collapsed canonical) AND `formation_slot` (raw ESPN label) on each DepthChartEntry. Locked entries are never moved.

Behaviors of note:
- **Row-grouped flatten** — multi-row position groups (3 WR rows for WR1/WR2/WR3 chains) round-robin starters together: row1[0], row2[0], row3[0], then row1[1], etc. Drives WR1/WR2/WR3 = starter from each row.
- **Position reconciliation** — front-7 entries whose `position` (from ESPN_MAP) disagrees with `athlete.position` get moved (Crosby OLB→EDGE, Heyward EDGE→DT). Reconciliation is RECONCILE_FRONT7-scoped (D-line + LB axis); CB↔S is intentionally NOT reconciled (slot/big-nickel fluidity is real).
- **Stale-entry pruning** — when post-merge data leaves a player with two entries on the same chart at different positions, apply_row keeps the entry already at the target position and drops the rest.
- **Verbatim ESPN order** — apply_row preserves ESPN's listed order for new vs existing entries. Brand-new players ESPN promotes above an existing one get the higher slot (Will Campbell at LT1 over Hudson, post-fix).
- **Partial-response guard** — if ESPN returns < 3 sides for a team (e.g. only "Base 4-3 D" with no offense or special teams — Lions hit this on 2026-05-01), skip the team entirely instead of half-overwriting. teams_partial counter on stats hash.
- **`espn_id` backfill on name match** — when ESPN places a player who was found via name fallback (not espn_id lookup), persist the `espn_id` from ESPN's href on the Athlete + derive `espn_headshot_url`. Pre-fix, those athletes had a depth chart entry but no espn_id, so `nfl:upload_headshots` couldn't cache their headshot. Backfilled ~110 athletes per scrape with this added.

## Athlete Cross-Ref IDs

`Athlete` has columns for every external system's player ID: `gsis_id` (NFL canonical), `espn_id`, `pff_id`, `otc_id` (Spotrac/OverTheCap), `pfr_id` (Pro-Football-Reference), `nflverse_id`. `Nflverse::SeedPlayers` populates them all from one CSV row. Importers use **ID-first lookup** (`gsis_id → pff_id → otc_id → espn_id → pfr_id`) before any name match. This eliminated the 122-of-122 split-record collision class where suffix-stripped duplicates ("Will Anderson" vs "Will Anderson Jr.") competed for the same canonical IDs. nflverse's `pff_position` column is preferred over the generic `position` column when present — disambiguates 3-4 OLBs (Watt/Crosby tagged "OLB" in `position` but "ED" in `pff_position`) and interior linemen mislabeled as DE in 3-4 schemes (J.J. Watt: position=DE, pff_position=DI).

## Duplicate-Person Merge

`Athletes::MergeDuplicates` (`app/services/athletes/merge_duplicates.rb`, rake `nfl:merge_duplicate_athletes`) finds Persons via two patterns: suffix variants (`will-anderson` ↔ `will-anderson-jr`) and same-name siblings with distinct slugs (case-insensitive first+last match where one has IDs and one doesn't). Moves contracts, depth_chart_entries, roster_spots, grades, pff_stats, image_caches from duplicate to canonical (dropping conflicts in favor of the canonical row), then deletes duplicate Athlete + Person. Defaults to `DRY_RUN=1`; pass `DRY_RUN=0` to commit. Wired into the full NFL rebuild workflow after `nfl:players_seed` and before ESPN scrape.

## Coach Headshot Pipeline

`nfl:link_coach_headshots` (ESPN v2 coaches API for HCs) + `nfl:link_coach_headshots_from_team_sites` (NFL.com per-team scrape from `Team.coaches_url`) populate `Coach.espn_headshot_url`. `nfl:upload_coach_headshots` caches variants to S3 with `cache_control: immutable, max-age=1y`.

**Stale-cache invalidation**: when `coach.espn_headshot_url` changes (e.g., second pass overwrites with NFL.com URL after first pass set ESPN URL), upload detects the mismatch (`source_url` on existing variants ≠ current URL, or sources differ across variants), wipes the rows, and re-uploads from current source. Required because `Studio::ImageCache.cache!` is idempotent — wouldn't otherwise refresh. Fixed McVay's mismatched B&W 100w + color 400w variants. Reports per-team gap of still-missing coaches at end of upload.

## Position Normalization

`PositionConcern` (`app/models/concerns/position_concern.rb`) holds canonical position lists, per-source mapping tables (`ESPN_MAP`, `PFF_MAP`, `NFLVERSE_MAP`, `SPOTRAC_MAP`, `GENERAL_MAP`), AND the `FORMATION_GROUPS` / `GROUP_ATHLETE_POSITIONS` maps used by the defensive picker. Callers pass `source:` to dispatch: `PositionConcern.normalize_position("LDE", source: :espn) # => "EDGE"`. Falls back to `GENERAL_MAP` when source is omitted.

## Expected Team Totals Baseline

`Nfl::CacheExpectedTeamTotals` (`app/services/nfl/cache_expected_team_totals.rb`, rake `nfl:expected_team_totals_cache`) caches derived NFL team totals from a market game total plus spread. The service stores one `NflTeamTotalProjection` row per team per game, retaining `game_total`, `home_spread`, `favorite_team_slug`, source metadata, and the derived `expected_points`.

Formula: `home = (game_total - home_spread) / 2`, `away = (game_total + home_spread) / 2`. When the favorite is the away team, `home_spread` is positive; when the favorite is the home team, `home_spread` is negative.

Default 2026 workflow:

```bash
bin/rails nfl:schedule_seed YEAR=2026
bin/rails nfl:expected_team_totals_cache YEAR=2026
```

The default source CSV is `db/seeds/data/nfl/2026_expected_team_totals.csv`. Pass `SOURCE=/path/to/file.csv` to import a refreshed line sheet, or `SEED_SCHEDULE=0` when the target season schedule is already present and should not be fetched.

# Seeds

> **When to read this:** Modifying `db/seeds/`, adding a new seed phase, or troubleshooting `db:seed` failures.

Seeds are split into `db/seeds/` directory, loaded in order by `db/seeds.rb`:

Each file only depends on files above it. Teams → Seasons → People → Grades → Rosters → Games → Demo data.

| Phase | File | Contents |
|-------|------|----------|
| 1. Infrastructure | `01_users.rb` | Parked operator identities, including admin users |
| | `02_agents.rb` | 9 agents with avatars (Alex, Avi, Carl, Shannon, Jasper, Steffon, Turf Monster, Mack, Mason). Avatar PNGs at `/public/agents/<slug>.png` — all 9 are present. |
| | `03_skills.rb` | 35 skills + 40 assignments. Skill assignments are sync-style (destroys non-desired rows) so re-seeding cleans up role changes — e.g. Mason's 2026-05-23 move from Infrastructure → Marketing dropped the old infra skills. |
| 2. Leagues | `10_teams_nfl.rb` | 32 NFL teams (sport/league/conference/division) |
| | `11_teams_ncaa.rb` | 75 NCAA teams (schools from 2025 draft picks) |
| | `12_teams_fifa.rb` | 48 FIFA World Cup 2026 teams (sport/league/group) |
| | `14_arenas.rb` | 38 NFL schedule venues from Turf Monster's cached 2026 schedule. Links all 32 NFL teams to `home_arena_slug`; neutral/international venues remain arena records without home teams. |
| | `15_seasons.rb` | 3 seasons (1 active) |
| | `16_slates.rb` | 29 slates across seasons |
| 3. People | `20_coaches_nfl.rb` | 128 NFL coaches (HC + coordinators) |
| | `21_coaches_fifa.rb` | 48 FIFA coaches (one per team) |
| | `22_nfl_contracts_2025.rb` | One-liner that calls `Spotrac::SyncContracts.new.call`. Layers ~2,420 active contracts (Person + Athlete + Contract w/ `annual_value_cents`) on top of nflverse identity records. **Season-specific snapshot** — replace file + JSON per season. Idempotent. Standalone task: `bin/rails nfl:salaries_sync`. |
| | `23_nfl_prospects.rb` | 102 draft prospects + 1 hypothetical → Person + Athlete + college Contract + NFL draft_pick Contract |
| | `25_fifa_players.rb` | 48 FIFA stars → Person + Athlete + Contract (`contract_type: "active"`) |
| 4. Evaluation | `29_pff_grades.rb` | Imports `db/seeds/data/pff/*.csv` via `Pff::ImportCsv`. 11 stat types, position-filtered. ~570 graded athletes when all CSVs present. Matches by `pff_id` when nflverse has populated it; falls back to name match. |
| | `30_athlete_grades.rb` | Synthetic fallback. Non-PFF NFL athletes get a flat 50.0 placeholder so ranking pages have a value to sort against; prospects keep tier-based ranges (JSONB `grade_ranges`) since draft slot is the only signal. Depth chart ordering is no longer driven by these — ESPN does that. |
| | `31_depth_charts.rb` | One DepthChart per NFL team, one DepthChartEntry per (person, position). Grade-rank fallback used during plain `db:seed`; live updates come from `bin/rails espn:scrape_depth_charts` (preferred). Locked entries hold position+depth across re-seeds AND ESPN scrapes. |
| | `31_rosters.rb` | 64 rosters, ~5000 roster spots. Depth denormalized from DepthChart. |
| | `32_headshot_links.rb` | DB-only. Coach `espn_headshot_url` discovery: HCs from ESPN's coaches API + all 4 roles scraped from each team's NFL.com page (URL stored on `Team.coaches_url`, seeded from `NFL_TEAM_DOMAINS` in `10_teams_nfl.rb`). Scraper falls back between `/team/coaches/` and `/team/coaches-roster/` (Bucs and Titans use the latter). Athlete URLs come from `nfl:players_seed` (nflverse master CSV), not this seed. |
| 5. Schedule | `40_games.rb` | Games across slates |
| 6. Demo Content | `50_news.rb` | 5 world cup articles + 34 NFL Draft tweets (@AdamSchefter) |
| | `51_contents.rb` | 4 content items across stages |
| | `52_tasks.rb` | 8 sample tasks |
| | `53_activities.rb` | 6 sample activities |
| | `54_ai_builder_multiple_candidates.rb` | 27 editable public GitHub builder seed candidates/monitors, 15 AI builders and 12 control builders, with optional repo scopes. Seed candidate rows are marked in notes as placeholders; `amcritchie` is an owner-requested monitor account. |

**Totals:** 155 teams, 38 arenas, ~3000 people, ~2800 athletes, ~2800 contracts, plus 27 AI Builder Multiple seed candidates/monitors. All idempotent via `find_or_create_by!`.

## Full rebuild vs plain seed

For a house-burned-down recovery, use `docs/agents/system/house-burn-down.md` and `bin/ecosystem-build`. The full sports-data rebuild runs `db:reset`, then `db:seed`, then `nfl:players_seed` (nflverse master CSV identity backbone with cross-ref IDs + S3 headshot caching), then `espn:scrape_depth_charts` (ESPN-driven roster + depth chart truth). The plain `db:seed` alone gets you a working dev DB with the Spotrac star roster but without the long-tail of backups/UDFAs and without the ESPN-current depth chart.

For weekly in-season refresh, use the non-destructive nflverse delta + ESPN scrape workflow captured in the recovery docs.

## Conventions

- Admins: `alex@mcritchie.studio` and `team@mcritchie.studio` are required parked admin identities; sign in by magic link in normal local development.
- NFL Draft tweets: oldest→newest in array, `.reverse` before seeding so oldest = top of kanban. Deduped by `x_post_id`.
- AI Builder Multiple seed candidates are placeholders for public GitHub commit pace analysis. Review cohort, repo scope, and active status before treating results as meaningful.
- College contracts expire `2026-04-01`. NFL star contracts have `annual_value_cents` (bigint).
- `contract_type` set correctly at creation (no backfill hack needed).

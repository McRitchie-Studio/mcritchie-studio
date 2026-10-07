---
name: nfl-rebuild
description: Full NFL data rebuild from scratch (house-burned-down recovery). Drops the database, reseeds teams/coaches/seasons/Spotrac/PFF, pulls nflverse master player CSV with cross-ref IDs, caches headshots to S3, then runs ESPN depth-chart scrape. Run when starting fresh.
disable-model-invocation: true
allowed-tools: Bash, Read
---

# NFL Rebuild — Full Recovery Pipeline

End state: every NFL team has 32 active rosters with starting offense/defense lineups, depth charts, contracts, salaries, grades, and headshots. Idempotent — safe to re-run.

## Preconditions

Confirm before running:

1. **Storage credentials present** for the headshot upload, which goes through `Studio::S3` to Cloudflare R2 (AWS retired 2026-10). Locally they live in `.env.development` (`STUDIO_S3_BACKEND=r2`, `R2_ENDPOINT`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_PUBLIC_URL`; the dev pair from 1Password `r2.mcritchie-studio`). Check with `grep -c '^R2_ACCESS_KEY_ID=.' .env.development` (expect `1`). If missing, headshots will be skipped (Athletes still seed; re-run with creds later).
2. **Postgres running**: `pg_isready` returns `accepting connections`.
3. **ImageMagick installed**: `which magick` returns a path. If missing, `brew install imagemagick`.
4. **Working tree clean**: `git status --short` is empty (so seed log noise can be reverted easily if anything goes sideways).

If any precondition fails, stop and report — don't try to continue.

## Pipeline

Run each step and report results before moving to the next. If a step fails, stop. Don't skip ahead.

### Step 1 — Reset the database

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails db:drop db:create db:schema:load
```

This drops + recreates the DB and loads the current schema (faster and safer than running every migration). Confirms with no errors when fresh.

### Step 2 — Run the standard seed pipeline

Logs to file because seed output contains emoji + scraped strings that crash Claude Code over JSON.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails db:seed > tmp/seed.log 2>&1
echo "exit: $?"
tail -40 tmp/seed.log
```

This populates: 32 NFL teams + 71 NCAA + 48 FIFA, 128 coaches, 3 seasons, 29 slates, ~2,400 Spotrac contracts, prospects, PFF grades, synthetic grade fill, depth chart shells, sample roster spots, news/content/tasks fixtures.

### Step 3 — Pull nflverse master CSV (identity + cross-ref IDs + headshots)

Fetches `players.csv` (~24k rows), filters to active players from 2024+, upserts Athletes with all five cross-ref IDs (`gsis_id`, `pff_id`, `otc_id`, `pfr_id`, `nflverse_id`), then caches ESPN headshots to S3.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:players_seed > tmp/players_seed.log 2>&1
echo "exit: $?"
tail -20 tmp/players_seed.log
```

Expect: ~2,500 athletes upserted, ~1,500 headshots cached (ESPN has IDs for most current players). Takes ~10-25 min depending on network. The two known dead links (`sal-cannella`, `isaiah-bond`) log a `[!]` and continue.

### Step 3.5 — Merge duplicate Persons

`db:seed` (Spotrac, prospects) creates Persons with suffix-stripped names ("Will Anderson") while `nfl:players_seed` keeps the canonical "Will Anderson Jr." with all the cross-ref IDs. ID-first lookup prevents NEW collisions but pre-existing seed-induced duplicates are still floating around with their own contracts and depth chart entries. This step consolidates them into the canonical record.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:merge_duplicate_athletes DRY_RUN=0 > tmp/merge.log 2>&1
echo "exit: $?"
tail -5 tmp/merge.log
```

Expect: ~20-60 pairs merged on a fresh build. Idempotent — re-running on a clean DB finds 0 pairs. Conflicts (duplicate Contract for the same team, etc.) are dropped in favor of the canonical row.

### Step 4 — ESPN depth-chart scrape

Auto-creates DepthChart shells per team, places players per ESPN's published depth, creates Contracts for any active-roster players not yet in the DB (UDFAs, mid-season call-ups), expires stale contracts when players have moved teams.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails espn:scrape_depth_charts > tmp/espn_scrape.log 2>&1
echo "exit: $?"
tail -25 tmp/espn_scrape.log
```

Expect: 32 teams scraped, ~2,000 athletes matched, ~200 positions reconciled, some Contracts created/expired/revived as the scrape catches up to current rosters.

### Step 5 — Headshot backfill (athletes + coaches)

Step 3 (nfl:players_seed) only caches headshots for athletes who appear in nflverse's `status=ACT, last_season>=2024` filter. Step 4 may add Contracts (and `Athlete.team_slug`) for ESPN-listed players outside that filter (practice-squad call-ups, recently-cut players still on rosters). And `db:seed` only LINKS coach `espn_headshot_url` (via 32_headshot_links.rb), it doesn't upload them.

This step closes both gaps.

**Athletes** — uploads any Athlete with `espn_id` but no cached variants. A
`team_slug` is NOT a precondition: it only names the S3 folder, and a blank one
falls back to `free-agents/` (`Athlete#headshot_key_prefix`). It used to be a
precondition, resolved through `person.contracts`, and because `contracts` is
EMPTY in production that skipped all 2,048 candidates on every run while printing
a clean summary — fixed 2026-09-26.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:upload_headshots > tmp/headshot_backfill.log 2>&1
echo "exit: $?"
tail -10 tmp/headshot_backfill.log
```

**Coaches** — uploads any Coach with `espn_headshot_url` (set by db:seed) but no cached variants:

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:upload_coach_headshots > tmp/coach_backfill.log 2>&1
echo "exit: $?"
tail -8 tmp/coach_backfill.log
```

Expect: ~300-400 athletes newly cached + ~150 coaches (HC always, OC/DC/STC where NFL.com scrape captured a URL). Both tasks are idempotent.

### Step 5b — Re-key headshots filed under the wrong folder

Run this when Step 5 prints a non-zero `misfiled (stale key):` line, or warns
`N athletes carry headshot rows filed under a stale key`.

Step 5 decides "already done" from VARIANT PRESENCE — do `original`/`100`/`400`
exist — and never from the key. So an athlete whose three variants sit under the
WRONG folder is complete forever, and no amount of re-running Step 5 will move
them. That is not hypothetical: a hand-rolled backfill on 2026-09-26 derived the
folder from the empty `contracts` table and filed all 2,043 cached athletes under
`free-agents/`, rostered players included.

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:rekey_headshots > tmp/rekey.log 2>&1
echo "exit: $?"
tail -12 tmp/rekey.log
```

On PRODUCTION, run it as a rake task on the deployed slug — never as a
`rails runner` one-liner, which is the shortcut that caused the defect:

```bash
heroku run -x -a mcritchie-studio 'bin/rails nfl:rekey_headshots REKEY_LIMIT=25'   # one wave first
heroku run -x -a mcritchie-studio 'bin/rails nfl:rekey_headshots'                  # then the rest
```

Expect: `re-keyed:` equal to the misfiled count Step 5 reported, `already filed:`
everything else, and `failed: 0`. Idempotent — a second run re-keys nothing and
says nothing. `REKEY_LIMIT=N` bounds the wave; `REKEY_KEEP_ORPHANS=1` repoints the
rows and leaves the old objects in place.

Nothing goes dark while it runs. Per athlete it copies every object to the new key
FIRST, repoints all of that athlete's rows in one transaction SECOND, and deletes
the old objects LAST — and only ones no `ImageCache` row still references. A
failure at any step leaves every row pointing at an object that exists.

Verify by re-running the repair rather than with a hand-written query: its own
idempotence is the proof, and it touches neither ESPN nor S3 when there is nothing
to move.

```bash
heroku run -x -a mcritchie-studio 'bin/rails nfl:rekey_headshots'
# expect:  re-keyed: 0   ·   already filed: <every cached athlete>   ·   failed: 0
```

`re-keyed: 0` with `already filed` accounting for every athlete that owns a cached
headshot IS "no misfiled row remains" — the task reaches that number by comparing
each stored key against `Athlete#headshot_key_prefix`, which is the same
comparison any audit would write. Do NOT verify by re-running Step 5 on
production: it would attempt the handful of athletes that legitimately have no
cached headshot, and on a warm machine a single dead ESPN URL among two attempts
trips its majority rule and aborts a run that found nothing wrong.

Then open one re-keyed avatar and confirm it still serves — the row is what
resolves the URL, so a 200 here is the proof the repair kept serving intact:

```bash
curl -sI "$(heroku run -x -a mcritchie-studio 'bin/rails runner "print Athlete.find_by(person_slug: %q(jaxon-smith-njigba)).headshot_url"')" | head -1
# expect: HTTP/1.1 200 OK  — and a URL containing /seattle-seahawks/, not /free-agents/
```

### Step 5c — Compute proprietary Pass/Run grades

Reads the `*_grade_pff` columns (set by `db/seeds/29_pff_grades.rb` during Step 2) and writes `position_pass_rank` / `position_pass_grade` / `position_run_rank` / `position_run_grade` on each `AthleteGrade`. Without this step the P/R letter-grade badges on `/games/.../show` and `/nfl-team-grades/:team_slug` render empty (`—`).

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails nfl:assign_grades > tmp/assign_grades.log 2>&1
echo "exit: $?"
tail -3 tmp/assign_grades.log
```

Expect: a stats hash like `proprietary grades: {qb=>~80, rb=>~150, wr_te=>~500, ol=>~460, dl=>~590, lb=>~210, db=>~350}` (sizes vary with PFF coverage). Pure DB compute, runs in seconds. Idempotent — re-runs overwrite prior values.

## Verification

```bash
op run --env-file=/Users/alex/projects/.env -- bin/rails runner '
  puts "Teams (NFL):     #{Team.where(league: "nfl").count}"
  puts "Athletes:        #{Athlete.where(sport: "football").count}"
  puts "  with espn_id:  #{Athlete.where.not(espn_id: nil).count}"
  puts "  with gsis_id:  #{Athlete.where.not(gsis_id: nil).count}"
  puts "  with team_slug:#{Athlete.where.not(team_slug: nil).count}"
  puts "Contracts:       #{Contract.where(contract_type: "active").count}"
  puts "DepthCharts:     #{DepthChart.count}"
  puts "DepthChartEntries:#{DepthChartEntry.count}"
  puts "ImageCaches:     #{ImageCache.where(purpose: "headshot").count}"
  puts "AthleteGrades:   #{AthleteGrade.count}"
  puts "  prop pass set: #{AthleteGrade.where.not(position_pass_grade: nil).count}"
  puts "  prop run set:  #{AthleteGrade.where.not(position_run_grade: nil).count}"
'
```

Healthy targets:
- Teams (NFL): 32
- Athletes: 2,000–3,000 (filter is `last_season >= 2024`)
- with team_slug: ≥ 2,000 (most active players placed)
- Contracts active: ≥ 2,400 (Spotrac stars + ESPN-added backups)
- DepthCharts: 32
- DepthChartEntries: ~2,500
- ImageCaches: ~5,000 (athletes × 3 variants when headshots ran)

## Visual smoke test

Open `http://localhost:3000/nfl-rosters` and confirm each team renders 12 offensive starters, 12 defensive starters, 4 special teams, 4 coaches with headshots. Spot-check 3–4 teams across divisions.

## Recovery if something goes wrong

- Step 2 fails partway: `bin/rails db:reset > tmp/seed.log 2>&1` re-runs the whole seed (idempotent). Inspect `tmp/seed.log` for the failing record.
- Step 3 fails on headshot upload: re-run — idempotent, only missing variants are uploaded. Or `SKIP_HEADSHOTS=1 bin/rails nfl:players_seed` to skip headshot calls entirely if AWS is the issue.
- Step 4 fails on a single team: `bin/rails espn:scrape_depth_charts TEAM=buf` to retry one team. ESPN occasionally rate-limits — wait a minute and retry.

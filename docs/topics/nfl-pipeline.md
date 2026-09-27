# NFL Data Pipeline

> **When to read this:** Modifying NFL data ingest (Nflverse, Spotrac, ESPN scrape), athlete identity/cross-ref columns, duplicate merging, position normalization, or coach headshots.

## Three-Layer Pipeline

Three layered services, each authoritative for one slice of state. Run the full NFL rebuild workflow for a complete reset, or the weekly NFL refresh workflow for in-season deltas.

### 1. `Nflverse::SeedPlayers`
`app/services/nflverse/seed_players.rb`, rake `nfl:players_seed` — identity backbone.

Pulls `players.csv` from nflverse-data GitHub release (~24k rows, default filter is `last_season>=2024` only — no status filter so UFA/RES/PUP veterans like Hunt/Harris/Waller are included). Upserts Person + Athlete with all six cross-ref IDs (`gsis_id`, `espn_id`, `pff_id`, `otc_id`, `pfr_id`, `nflverse_id`). Lookup priority is `gsis_id` (anchor) → `pff_id` → `otc_id` → `espn_id` → `pfr_id` → `nflverse_id` → `person_slug` (name match) → create. `nflverse_id` sits LAST but must be probed: it is uniquely indexed, so a row whose `nflverse_id` already belongs to another athlete would otherwise fall through to the name path and wedge the next run on `index_people_on_slug`. Sets `Athlete.team_slug` from `latest_team` and caches ESPN headshots to S3 inline (idempotent; **not** skipped without AWS creds — the constructor RAISES, so opt out with `upload_headshots: false` or `SKIP_HEADSHOTS=1`, which is what both declared post-deploy commands do). The `team_slug` here is provisional — Spotrac and ESPN authoritatively overwrite below. Optional env: `STATUS=ACT` to re-narrow, `MIN_SEASON=2025` to scope tighter.

The name fallback adopts an existing Athlete only when it has no cross-ref IDs or shares an ID with the incoming row. If both records have identity data but none match, they are namesakes and receive separate Person slugs even when both GSIS IDs are blank. A namesake row with no identity key cannot receive a stable slug; the importer skips it, increments `namesake_collisions_skipped`, records WHO it refused on the run row (`ImportRun#stats["namesake_refusals"]` — `person_slug`, `name`, `ours`, `theirs`, `reason`), announces it on **stderr** without waiting for `VERBOSE`, and continues instead of aborting the post-deploy command. The counter alone was the whole record until 2026-09-23, which made a guard that declines to write a human indistinguishable from an importer that lost one.

**Which namesake keeps the clean slug is a property of the data, never of the file.** Rows are ingested in `ordered` by the full identifier priority (`gsis_id` → `espn_id` → `pff_id` → `otc_id` → `pfr_id` → `nflverse_id`), present-before-absent then by value, with the CSV index surviving only as a last tiebreak for rows sharing every identifier. Sorting on `gsis_id` alone was not enough: a real namesake pair often has it blank on both rows, and the CSV index then decided the winner — so reversing two rows moved `justin-jefferson` from ESPN 4262921 to 4430737. Every foreign key here is a slug, so that reassigned one human's grades, stats and cached headshots to the other on a rebuild.

The disambiguator suffix is the last four digits of the row's highest-priority identifier, widening to the **whole** identifier when that slug already belongs to someone else — two namesakes whose IDs end alike would otherwise compute the same slug and raise `RecordNotUnique` out of the post-deploy command. `Person.create!` is rescued as a backstop for what that check cannot see, counting `namesake_collisions_skipped`, recording the same refusal payload, and skipping the row. The rule throughout: one malformed row costs one row, never the ship.

### 2. `Spotrac::SyncContracts`
`app/services/spotrac/sync_contracts.rb`, rake `nfl:salaries_sync` — salary overlay.

Reads `db/seeds/data/spotrac_contracts_2025.json` (committed, ~2,500 entries — **season-specific snapshot, replace per season**), matches Athletes by `otc_id` then name fallback, upserts active Contracts with `annual_value_cents` and `expires_at` (end_year → March 15 of that year). Updates `Athlete.team_slug` per the contract-update rule.

### 3. `Espn::ScrapeDepthCharts`
`app/services/espn/scrape_depth_charts.rb`, rake `espn:scrape_depth_charts` — current-roster + depth truth.

Hits `https://sports.core.api.espn.com/v2/.../depthcharts` per team. The doc said `https://www.espn.com/nfl/team/depth/_/name/{abbrev}` (data embedded in `window['__espnfitt__']`) until 2026-09-27; that HTML scrape is blocked and the service moved to the JSON API, per its own comment at `app/services/espn/scrape_depth_charts.rb`. Auto-creates DepthChart shells and Contracts for ESPN-listed players we don't have yet (UDFAs, mid-season call-ups). When a player has shifted teams, expires the old active Contract and creates the new one. Updates `Athlete.team_slug`. Stores both `position` (collapsed canonical) AND `formation_slot` (raw ESPN label) on each DepthChartEntry. Locked entries are never moved.

Behaviors of note:
- **Row-grouped flatten** — multi-row position groups (3 WR rows for WR1/WR2/WR3 chains) round-robin starters together: row1[0], row2[0], row3[0], then row1[1], etc. Drives WR1/WR2/WR3 = starter from each row.
- **Position reconciliation** — front-7 entries whose `position` (from ESPN_MAP) disagrees with `athlete.position` get moved (Crosby OLB→EDGE, Heyward EDGE→DT). Reconciliation is RECONCILE_FRONT7-scoped (D-line + LB axis); CB↔S is intentionally NOT reconciled (slot/big-nickel fluidity is real).
- **Stale-entry pruning** — when post-merge data leaves a player with two entries on the same chart at different positions, apply_row keeps the entry already at the target position and drops the rest.
- **Verbatim ESPN order** — apply_row preserves ESPN's listed order for new vs existing entries. Brand-new players ESPN promotes above an existing one get the higher slot (Will Campbell at LT1 over Hudson, post-fix).
- **Partial-response guard** — if ESPN returns < 3 sides for a team (e.g. only "Base 4-3 D" with no offense or special teams — Lions hit this on 2026-05-01), skip the team entirely instead of half-overwriting. teams_partial counter on stats hash.
- **THE HOST IS THE WHOLE BUG, AND IT IS FIXED (`revive-dead-depth-scraper`, 2026-09-27).** `ESPN_TEAMS_INDEX_URL` and `ESPN_ROSTER_URL` named `site.api.espn.com`, which filters on User-Agent and rejects everything Ruby's `Net::HTTP` can send — including this service's Chrome string. `fetch_json` returned nil on any non-success, so `team_id_for` answered nil, all 32 teams landed in **`teams_failed`** with "No ESPN team_id for abbrev", and `call` returned a tally. MEASURED at `accepted`'s head against live ESPN on 2026-09-27: `{:teams_failed=>32}` and 0 entries touched. After the fix, the same run in the same minute: **32 of 32 teams applied, 2,572 entries**. BE PRECISE ABOUT WHAT WAS SILENT: the lane was already loud for a TOTAL outage — `lib/tasks/espn.rake` aborts on zero teams applied, measured firing with a non-zero exit. What was silent was the CAUSE, reported as "No ESPN team_id for abbrev" (a sentence about our own map, for an ESPN outage), and a PARTIAL loss: 31 of 32 applied stays green by design, so one missing id was invisible. Both hosts and the honest User-Agent now come from `Espn::Api`, which `Espn::PlayerProfile` reads too — the two services holding separate copies is what let one rot while the other worked. The depth-chart URL (`sports.core.api.espn.com`) never filtered. A third copy of the dead host survives at `lib/tasks/nfl.rake`'s `nfl:link_coach_headshots` (`:431`, constant at `:426`), which reads it with `URI.open` and measured 403 on 2026-09-27; filed as `revive-coaches-seed-host`, not fixed here.
- **`espn_id` backfill on name match** — when ESPN places a player who was found via name fallback (not espn_id lookup), persist the `espn_id` from ESPN's href on the Athlete + derive `espn_headshot_url`. Pre-fix, those athletes had a depth chart entry but no espn_id, so `nfl:upload_headshots` couldn't cache their headshot. Backfilled ~110 athletes per scrape with this added.

## Athlete Cross-Ref IDs

`Athlete` has columns for every external system's player ID: `gsis_id` (NFL canonical), `espn_id`, `pff_id`, `otc_id` (Spotrac/OverTheCap), `pfr_id` (Pro-Football-Reference), `nflverse_id`. `Nflverse::SeedPlayers` populates them all from one CSV row. Importers use **ID-first lookup** (`gsis_id → pff_id → otc_id → espn_id → pfr_id → nflverse_id`) before any name match. This eliminated the 122-of-122 split-record collision class where suffix-stripped duplicates ("Will Anderson" vs "Will Anderson Jr.") competed for the same canonical IDs. nflverse's `pff_position` column is preferred over the generic `position` column when present — disambiguates 3-4 OLBs (Watt/Crosby tagged "OLB" in `position` but "ED" in `pff_position`) and interior linemen mislabeled as DE in 3-4 schemes (J.J. Watt: position=DE, pff_position=DI).

## Duplicate-Person Merge

`Athletes::MergeDuplicates` (`app/services/athletes/merge_duplicates.rb`, rake `nfl:merge_duplicate_athletes`) finds Persons via two patterns: suffix variants (`will-anderson` ↔ `will-anderson-jr`) and same-name siblings with distinct slugs (case-insensitive first+last match where one has IDs and one doesn't). Moves contracts, depth_chart_entries, roster_spots, grades, pff_stats, image_caches from duplicate to canonical (dropping conflicts in favor of the canonical row), then deletes duplicate Athlete + Person. Defaults to `DRY_RUN=1`; pass `DRY_RUN=0` to commit. Wired into the full NFL rebuild workflow after `nfl:players_seed` and before ESPN scrape.

## Athlete Headshot Pipeline

`nfl:upload_headshots` caches three variants per athlete to S3 — `original`, `100`, `400`
— for every `Athlete` carrying an `espn_id`. It is idempotent and resumable: the
`ImageCache` rows *are* the progress, so `HEADSHOT_LIMIT=N` takes a cold run in
inspectable waves and the next wave resumes where the last stopped. `nfl:rekey_headshots`
re-files rows whose stored key disagrees with `Athlete#headshot_key_prefix`; the upload
task detects that drift and names it but cannot repair it, because it grades "already
done" by variant presence and never by key.

**Read the lane left to right: wanted it → a source could answer → something came back.**
Each step asks a different question, and only the last one grades the lane. A gap at the
source step is a *data* gap and stays quiet; a gap at the result step is the lane not
working, and that is what exits non-zero. Two predicates on `Athlete` hold the first two
steps — `headshot_complete?` and `headshot_fetchable?` — so the skip branches in the task
and the verdicts below it read one definition instead of two spellings that drift.

**Two exit-code rules, disjoint by construction.** Rule 1 fires when `failed > cached`:
more failures than successes cannot be one dead ESPN URL, and it names
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`, because that is what a credential failure
looks like from here. Rule 2 fires when the run found fetchable work and attempted none
of it — the task refusing its job rather than S3 refusing the upload. `attempted.zero?`
forces `failed == cached == 0`, so rule 1 is false exactly when rule 2 can fire.

**Rule 2 grades `fetchable`, not every athlete short a variant, and that difference was a
false abort on every healthy run.** The rule was written against `needed = considered -
skipped_complete`, which subtracted out the *complete* athletes and nothing else. Eight
production athletes have no `espn_headshot_url` and never will, so once the other 2,043
were cached `needed` sat positive for ever while `attempted` was legitimately zero — the
healthy steady-state re-run aborted, claiming the task had declined its job. **A verdict
must be clearable by fixing what it accuses.** That one accused the lane and could only
be cleared by filling a column the lane does not write. The graded population now holds
only athletes a source could have answered for.

Only **five** of those eight ever reach the verdict: three carry no `espn_id`, so they are
not candidates at all (2,048 of the 2,051 athletes are). An abort on production therefore
read "0 of the 5", not "0 of the 8".

**What stays quiet, because a rule that cries wolf gets disabled.** A complete athlete is
never counted as wanting a headshot, so the warm re-run says nothing. An athlete with no
`espn_headshot_url` is counted as wanting one and not as fetchable, so the permanent
residue is silent — it is **named**, slug by slug, in the report's inventory instead
(capped at 25 with a remainder count), which is the honest way to ask for the data to be
fixed. A stale folder name warns and never aborts: every avatar still serves.

**A `next` added later cannot vanish.** `unfetched` (fetchable, walked past anyway) and
`unclassified` (wanted one, skipped for a reason no verdict classifies) are both derived
by subtraction and both reported. That is how the original hole stayed open —
`skipped_no_team` was faithfully counted, printed, and read by no rule.

**The inverse defect was checked for and is absent.** `Studio::ImageCache.cache!` raises
on every failure path it has — the remote fetch, `Studio::S3.upload`, and
`ImageCache.create!` — rather than degrading to a quiet no-op, so a wholesale credential
failure lands in `failed` and rule 1 sees it. That is *unlike* the vision lane below,
whose describer degrades by contract and therefore needs a third rule to notice a lane
that never reached its API.

## Coach Headshot Pipeline

`nfl:link_coach_headshots` (ESPN v2 coaches API for HCs) + `nfl:link_coach_headshots_from_team_sites` (NFL.com per-team scrape from `Team.coaches_url`) populate `Coach.espn_headshot_url`. `nfl:upload_coach_headshots` caches variants to S3 with `cache_control: immutable, max-age=1y`.

**Stale-cache invalidation**: when `coach.espn_headshot_url` changes (e.g., second pass overwrites with NFL.com URL after first pass set ESPN URL), upload detects the mismatch (`source_url` on existing variants ≠ current URL, or sources differ across variants), wipes the rows, and re-uploads from current source. Required because `Studio::ImageCache.cache!` is idempotent — wouldn't otherwise refresh. Fixed McVay's mismatched B&W 100w + color 400w variants. Reports per-team gap of still-missing coaches at end of upload.

## Position Normalization

`PositionConcern` (`app/models/concerns/position_concern.rb`) holds canonical position lists, per-source mapping tables (`ESPN_MAP`, `PFF_MAP`, `NFLVERSE_MAP`, `SPOTRAC_MAP`, `GENERAL_MAP`), AND the `FORMATION_GROUPS` / `GROUP_ATHLETE_POSITIONS` maps used by the defensive picker. Callers pass `source:` to dispatch: `PositionConcern.normalize_position("LDE", source: :espn) # => "EDGE"`. Falls back to `GENERAL_MAP` when source is omitted.

## One Player: Acquire or Validate

`Athletes::AcquireOrValidate` (`app/services/athletes/acquire_or_validate.rb`, rake
`athletes:acquire_or_validate`) is the **per-person** act. Everything else on this page
is bulk: the rebuild workflow drops the database, the refresh workflow re-pulls all of
nflverse and scrapes 32 depth charts, and `nfl:upload_headshots` selects
`Athlete.where.not(espn_id: nil)` — which is exactly what a player nobody has fetched
yet does not have. So there was no way to fix ONE person, which is what the model
pipeline's `defined` lane needs when it finds an incomplete one.

**It runs on a desk with no credential.** Every ESPN endpoint behind it is public. The
only step that wants AWS keys is caching the headshot into S3, and that degrades to a
reported line rather than failing the run.

```bash
bin/rails athletes:acquire_or_validate PERSON=ashton-jeanty        # validate someone on file
bin/rails athletes:acquire_or_validate ESPN_ID=3138744            # acquire or validate by id
bin/rails athletes:acquire_or_validate TEAM=lv NAME="Chris Myarick"   # acquire from a roster
DRY_RUN=1 bin/rails athletes:acquire_or_validate TEAM=lv          # walk one roster, write nothing
ADOPT=position,height_inches bin/rails athletes:acquire_or_validate PERSON=tj-watt
NO_HEADSHOT=1 bin/rails athletes:acquire_or_validate PERSON=bo-nix
```

### The seam

`Espn::PlayerProfile` is the provider and the only file that knows ESPN's JSON exists.
It answers `#find`, `#find_on_roster`, `#find_in_league` and `#roster` with
`Athletes::SourceProfile` values already in our units, our position vocabulary and our
team slugs. A second source is a second provider and no change to the act — the
operator's framing was "we can always add supliment data sourses later".

### Who wins a disagreement

Per-field, declared as data in `AcquireOrValidate::FIELDS`:

| policy | fields | rule |
|--------|--------|------|
| `:key` | `espn_id` | fill when blank; a stored id that DISAGREES refuses the whole act |
| `:roster` | `team_slug`, `jersey_number` | the league publishes these, so the source wins — and the change is named (`traded`), never quiet |
| `:held` | `position`, `height_inches`, `weight_lbs`, `first_name`, `last_name` | fill when blank; on a disagreement KEEP ours and report a `conflict` the operator can take with `ADOPT=` |
| `:fill` | `espn_headshot_url` | derived from the id, so the `:key` refusal fires first |

**`position` is held, and that is measured, not cautious.** T.J. Watt, Alex Highsmith
and Nick Herbig are all stored `EDGE` (from PFF, whose vocabulary is finer — see
Athlete Cross-Ref IDs above) while ESPN says `LB`, which `ESPN_MAP` normalizes to `LB`.
A source-wins rule on `position` would have quietly demoted every 3-4 edge rusher in
the league, and nothing would have errored.

### Staleness is causal

Nothing reads a clock. **Stale** means the source now disagrees with a value we had
already stored, which is the only comparison that can name the change on the report
line. `athletes.updated_at` moves for any column and `people.updated_at` does not move
when the athlete row changes at all, so both timestamps answer this worse.

`traded` is deliberately the same word `Appearances::LookReading` uses. They are the
same event at the next joint along, and each object owns one:

```text
ESPN ──(AcquireOrValidate)──> athletes.team_slug ──(LookReading#traded?)──> appearance
```

### Traps this act was built around

- **Height and weight arrive as prose.** `height` and `weight` measure nil on the
  athlete endpoint while `displayHeight`/`displayWeight` carry `"6' 2\""` and
  `"217 lbs"`. `Athletes::DisplayMeasurement` parses them and **refuses** anything it
  cannot read with confidence, because a plausible wrong integer reaches the
  character-sheet prompt as a body of the wrong shape and raises nothing.
- **The roster endpoint's `athletes` key is six GROUPS, not players** — offense,
  defense, specialTeam, injuredReserveOrOut, suspended, practiceSquad. A naive read
  gets 6 objects instead of Las Vegas's 79 and finds nobody, without raising.
- **`site.api.espn.com` 403s Ruby and 200s curl.** Hand-verifying that host with curl
  PROVES an endpoint that the application cannot reach. Use `site.web.api.espn.com`,
  which serves the identical document to any User-Agent.
- **`Person.find_by_name` cannot see across punctuation.** `find_by_name("AJ", "Cole")`
  is nil while `a-j-cole` is on file, so 1 of the 18 Las Vegas players that looked
  absent was a player we have had for years. `Athletes::NameKey` compares
  punctuation- and suffix-insensitively and the act REFUSES an ambiguous name rather
  than filing a second row for one human.
- **A trade means the stored team is the one roster he is no longer on.** Searching
  only the stored team can never discover the event the act was built for, so a miss
  widens to all 32 rosters (ESPN publishes no working player-name search:
  `common/v3/search?query=Bo+Nix` answers HTTP 200 with `count: 0`). Absence is only
  concluded from a COMPLETE search; an unreadable roster raises instead.

### `jersey_number`

`athletes.jersey_number` (integer, nullable) was added by this act's migration. Before
2026-09-27 the number had no column on any table, ESPN returned it as `athlete.jersey`
and every reader dropped it, so the character-sheet recipe substituted a `<NUMBER>`.
`Appearances::Pipeline::DEFINITION_GAP_NOTE` and the `no #` cell on the model-pipeline
board describe that gap and are owed an update now that the column exists.

## Athlete Physical Descriptions

`athletes:describe_from_headshots` fills `build`, `skin_tone` and `hair_description`
— the three columns `Athlete#physical_brief` folds into
`Appearance#generation_brief` and `Content::AssetsAgent#build_image_prompt`, which
is the text an image generator works from. Before the first run, all 2,051
production athletes had **none** of the three (measured 2026-09-26), so every
character prompt in the ecosystem was the operator's typed descriptor plus nothing.

**Two sources, not one, and they cost different amounts.**

| Column | Source | Cost | Coverage |
|---|---|---|---|
| `build` | the athlete's own `height_inches` + `weight_lbs` (`Athletes::BuildFromMeasurements`) | free, no API call | all 2,051 |
| `skin_tone`, `hair_description` | one Haiku 4.5 vision call over the cached 400px headshot (`Athletes::DescribeFromHeadshot`) | ~$0.0011/call, ~$2.25 for the full set | the 2,043 with a cached headshot |

**Build does NOT come from the photograph.** A headshot is head and shoulders and
cannot see a body, so a vision model asked for build is guessing from a collar.
The measurement was on the record all along, and it also reaches the 8 athletes who
have no cached headshot.

**It reads the image by the ImageCache row's recorded `s3_key`, never by recomputing
`Athlete#headshot_key_prefix`.** Those two disagree in production: every cached
headshot object sits under `headshots/nfl/free-agents/…` (the run that uploaded them
derived the folder from the empty `contracts` table) while `team_slug` is populated
for every athlete, so the prefix computes a folder the bytes are not in.

**Never overwrites.** A value already on file came from a human or a better source
and outranks the model. Each field is considered independently, so a hand-written
skin tone survives while hair is still filled in. The columns are the only progress
record, which is what makes the task resumable — a re-run over completed rows makes
no calls and costs nothing.

**Run a sample first.** The value of the feature is whether the descriptions read
well, and that is a human judgement:

```bash
bin/rails athletes:description_coverage                  # read-only: what is filled, and from which source
DESCRIBE_LIMIT=20 bin/rails athletes:describe_from_headshots   # 20 rows, then read the table it prints
bin/rails athletes:describe_from_headshots               # the rest
```

**Running it on production.** The 2,051 athletes are production rows, so the real pass
is a `heroku run` on the `mcritchie-studio` app — and it is **detached**, because an
attached one-off dyno dies with the terminal that started it:

```bash
# 1. the credential the paid lane needs. Present on prod as of 2026-09-27 —
#    re-measure by NAME, never by printing the value:
heroku config --app mcritchie-studio | grep -c '^ANTHROPIC_API_KEY:'   # expect 1
#    AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY are needed too: the pass reads each
#    cached headshot out of S3 with our own credentials.

# 2. a sample first, attached, because reading the table it prints is the point
heroku run --app mcritchie-studio DESCRIBE_LIMIT=20 rails athletes:describe_from_headshots

# 3. the rest, detached, then follow it
heroku run:detached --app mcritchie-studio rails athletes:describe_from_headshots
heroku logs --app mcritchie-studio --dyno run --tail
```

**Without the credential it still runs.** The build lane needs no key and no network, so
a keyless run fills `build` for every athlete and warns instead of aborting; only skin
tone and hair wait for the key.

**How long it takes, and why the number is not load-bearing.** The derivable floor is the
pause: `DESCRIBE_PAUSE` (0.2 s) after every call the task asked for, so a full pass of
~2,043 asks waits **~7 minutes** in pauses alone. Wall clock is that plus one Anthropic
round trip per athlete, which has not been measured — re-derive it from the first sample
rather than trusting a figure here (`DESCRIBE_LIMIT=20` prints its own token and cost
totals). Precision does not matter much because **the columns are the progress**: a killed
dyno costs only the calls already paid for, and re-running resumes exactly where it
stopped.

**What to read when it finishes.** The exit code grades the three lanes (below), and
`/admin/error_logs` carries a row per athlete for every degraded call — an invalid
credential, a 429, an unreadable S3 object. Two report lines point there without failing
the run: `asked but NOT billed:` with its `WARNING`, and `measured but IMPLAUSIBLE:` with
its `[?]` lines. Then `bin/rails athletes:description_coverage` (read-only) for the
standing totals.

`DESCRIBE_LIMIT` caps athletes **changed** — a sample run stops rather than walking
on to bulk-write the free column everywhere. It bounds the **writes**, not the spend:
the walk advances on changes, so an athlete who is paid for and yields nothing to
write (build already on file, both fields answered null) does not consume the limit,
and `DESCRIBE_LIMIT=20` can cost more than twenty calls. It cannot run away —
`find_each` visits each athlete once, so the ceiling is one full pass, ~2,043 calls,
~$2.25 — but the flag caps rows and the table caps the bill. `DESCRIBE_PAUSE`
(default 0.2s) waits after each call the task **asked for**; a failed call waits too,
so a rate-limited run does not retry faster than a healthy one.

**Three exit-code rules, one per lane, and the per-lane split is the point.** The two
sources cost different amounts and fail differently: build always succeeds, while the
vision describer degrades to a blank answer rather than raising. A rule reading a
counter that summed them could not tell "did the cheap half" from "did the job" — one
full pass with a dead credential fills 2,051 builds, describes nobody, and every
summed total reads healthy. So the report prints each lane's three steps (*wanted it
→ a source could answer → something came back*) and each rule grades one lane:

| Rule | Fires when | What it catches |
|---|---|---|
| 1. the pass broke down | more raises than writes | the **write** path — a row that no longer satisfies a validation (a blank `sport` raises `RecordInvalid`), a database error. Not the paid call, which never raises |
| 2. the free lane wrote nothing | ≥1 athlete wanting a build was **derivable** — both measurements on file *and* inside the plausibility window — and none was written | the deriver failing on rows it accepts, or every write failing |
| 3. the paid lane never landed | ≥1 call was asked for and **not one was billed a token** | a present-but-invalid credential, a sustained 429, unreadable S3 objects |

**Rule 2 grades `derivable?`, not `measured?`, and the difference is a false positive
that was live.** `measured?` asks whether both *columns* are present; the deriver
returns nil outside its window. So a unit mix-up — centimetres in an inches column,
`180` "inches" — is measured-but-underivable, and on the warm re-run it is the only row
still wanting a build. The lane therefore read *"had the input for 1, wrote 0"* and
aborted, on every run, for ever, with nothing wrong and nothing that fixing the lane
could clear (measured in a desk 2026-09-26). It was not reachable on production — 2,051
athletes span 67..81 in and 156..380 lb with no out-of-window row, and the task is
operator-run rather than scheduled — but it becomes reachable on the first ingest that
lands one bad row, which is the case the window exists for. **A verdict has to be
clearable by fixing what it accuses**, so an implausible row is now reported as its own
data gap with a `[?]` line naming the athlete and the offending value, and the operator
fixes the row rather than the lane.

**Rule 3 is all-or-nothing, and the partial failure is warned about rather than aborted
on.** A credential revoked at athlete 500, or a sustained 429 from there, leaves asked
2,043 / billed 499: rule 3 is false because something *was* billed, and rule 1 is false
because the describer degrades. A `billed < asked` abort would catch that — and would
also fire on a healthy pass, because one unreadable S3 object degrades to a blank result
with no usage, so a single dead image among 2,043 sound ones is already asked 2,043 /
billed 2,042. A rule that fires on a sound run is a rule somebody disables, and a
threshold only replaces the false positive with a number nobody can defend. So the run
prints `asked but NOT billed:` and, when it is non-zero beside a non-zero bill, a
`WARNING` naming `/admin/error_logs`. The pass is resumable, so a systemic failure the
warning does not stop is caught by the next run one run late rather than never.

Rule 3 exists because rules 1 and 2 are structurally blind to it, which is the exact
shape in which `nfl:upload_headshots` reported a total failure as exit 0 for its
entire life — `candidates: 2048`, `cached: 0`, a clean summary.

**What must stay quiet, because a rule that cries wolf gets disabled.** A completed
row is skipped, so a warm re-run reports nothing on either lane. A row **no source
can ever complete** — one of the 8 with no cached headshot, whose skin tone and hair
have no second source — is found on every run for ever and is reported as a data gap,
never as work declined. And a row whose honest answer is null (a helmet, a hood, a
placeholder crop) is re-asked on every later run: rule 3 therefore grades on
**billing** rather than on output, because a re-ask that bills is evidence the lane
works, whatever it answered. The cost of that is one blind spot, named here so it is
not rediscovered: a lane that bills every call and writes nothing — our own parser
broken, say — reads exactly like that null steady state. Separating them needs a
record that the task *asked and the answer was null*, which is a column rather than an
accounting change. **That deferral covers only that blind spot** — the partial-failure
case above needed no column, since `vision_asked` and `vision_billed` were both already
counted and the warning is their difference.

**No live vision call can happen in the test suite, and that is a trap rather than
an assertion.** Every paid call leaves through `Athletes::VisionTransport`, which
`test/test_helper.rb` arms to raise before boot (`VISION_NO_LIVE_CALLS=1`, beside the
fake `op` and `SEAL_RETRY_NO_SLEEP`). The exception is deliberately **not** a
`StandardError`: the describer rescues `StandardError` by contract so one dead image
cannot abort a 2,000-row run, so a `StandardError` trap would be swallowed by the
caller it guards and a careless test would pass quietly.

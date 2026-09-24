# McRitchie Studio ↔ Turf Monster Data Flow

> **When to read this:** Changing anything that crosses between the hub and
> turf-monster — the athlete projection, the game-recap push, the shared bearer
> auth, the replica's write guard — or deciding where a new piece of data should
> be mastered. Read it before adding a third crossing.

## The split, in one sentence

**McRitchie Studio masters every durable fact about a person, a team or a place.
Turf Monster masters everything that happened at a time** — games, goals,
contests, entries. Two one-way flows carry data between them, and **neither app
reads the other's database.**

| | Masters | Holds a copy of | Crossing |
|---|---|---|---|
| **McRitchie Studio** (hub) | `Person`, `Athlete`, `Team` | finished games, as `Content` | receives the recap push |
| **Turf Monster** | `Game`, `Goal`, `Contest`, `Entry` | `Person` / `Athlete`, as a read replica | pulls the athlete projection |

The two flows are independent. Flow 1 is a **pull designed for a cadence** —
the cadence itself is unbuilt, see gap (b); flow 2 is a **push from a job**.
Neither runs inside a web request on either side.

---

## Flow 1 — hub → Turf Monster: the person/athlete projection

**Direction:** turf-monster PULLS. The hub never initiates.

### Provider (hub)

```
GET /api/v1/athletes?updated_since=<iso8601>&after_id=<id>&limit=<n>
Authorization: Bearer <token from POST /api/v1/auth>
```

`app/controllers/api/v1/athletes_controller.rb#index` — read-only, `index` is the
only action the route exposes. Page size defaults to 200 and is capped at
`app/controllers/api/v1/athletes_controller.rb#MAX_PAGE` (500). Rows come back
ordered by `(updated_at, id)`.

Each row carries the identity columns and the cross-reference ids, built in
`app/controllers/api/v1/athletes_controller.rb#serialize`: `gsis_id`,
`person_slug`, `first_name`, `last_name`, `disambiguator`, `athlete_slug`,
`sport`, `position`, `team_slug`, `height_inches`, `weight_lbs`,
`espn_headshot_url`, `espn_id`, `nflverse_id`, `pff_id`, `otc_id`, `pfr_id`,
`sleeper_id`, `updated_at`.

The response's `meta`, from
`app/controllers/api/v1/athletes_controller.rb#cursor_for`, carries `count`,
`next_updated_since`, `next_after_id`, `more`, and **`source_last_imported_at`**
— the finish time of the hub's last successful `nflverse_players` import. That
last key exists so a consumer can tell **"nothing changed"** from **"nothing was
checked"**, which are the same empty page otherwise.

### Consumer (turf-monster)

`Studio::SyncAthletes#call`, in `turf-monster/app/services/studio/sync_athletes.rb`,
driven by two rake tasks in `turf-monster/lib/tasks/studio_sync.rake`:

```bash
bin/rails studio:sync_athletes          # delta
bin/rails studio:sync_athletes FULL=1   # rebuild from a nil watermark
bin/rails studio:sync_status            # where the sync got to
```

It pages at 200 and stops at 100 pages — 20,000 rows, **a stop rather than a
limit anyone expects to reach.** Progress is durable in one row per source on
`turf-monster/app/models/sync_cursor.rb`, so a partial run resumes instead of
restarting.

### Two different failures, and only one of them is a skip

**A missing secret is a skip. An unreachable hub is a failure.** The service's own
header comment calls both of them skips — it is wrong (see "Known stale pointers"
below), and a reader who believes it schedules a job that can redden a deploy. So
the two paths are spelled out here:

| Condition | Cursor status | Rake exit |
|---|---|---|
| No `AGENT_API_SECRET` | `skipped` | **0** |
| Hub unreachable, 5xx, bad token, unparseable body | `failed` | **non-zero** |

`Studio::SyncAthletes#call` reaches `#skip` on **one** path only — the
`configured?` guard on its first line. Everything else travels the error path:
`SocketError`, `Errno::ECONNREFUSED`, `Errno::EHOSTUNREACH`, a timeout and an
`OpenSSL::SSL::SSLError` are all re-raised as `Studio::SyncAthletes::Error` by
`#request`, caught by `#call`, and recorded with `SyncCursor#record_failure!`.
`turf-monster/lib/tasks/studio_sync.rake` then **aborts** on exactly that status.

The skip exists so that a stack which is *not meant* to sync cannot redden a
deploy. A stack that **tried and could not reach the hub** will.

**Read this before building the cadence (gap (b)).** Whatever you schedule
inherits the abort: an hour of hub downtime reddens it.

### Auth

Both flows share one bearer lane: `POST /api/v1/auth` with the shared
`AGENT_API_SECRET` returns a 24-hour token
(`app/controllers/api/v1/auth_controller.rb#create`). Measured 2026-09-24: the
secret is present on both `mcritchie-studio` and `turf-monster-mainnet`, and
neither app sets `STUDIO_API_BASE`, so both fall through to the
`https://mcritchie.studio` default.

---

## Flow 2 — Turf Monster → hub: the finished-game recap

**Direction:** turf-monster PUSHES, one game at a time.

`Nfl::LiveScores::PollCycle#finalise` enqueues
`turf-monster/app/jobs/studio/game_recap_push_job.rb`, which calls
`turf-monster/app/services/studio/push_game_recap.rb`. It is a **job, not an
inline call**, for one reason: the poll cycle is the sole path by which production
contests re-score, and an HTTP round trip to another host has no business inside
that loop. Enqueuing is a Redis write; the worker dyno pays the network cost. A
push that fails is recorded as a `recap_push_failed` anomaly on the cycle rather
than killing it.

The hub receives it at
`app/controllers/api/v1/game_recaps_controller.rb#create`, which hands off to
`Content::CreateGameRecap` and answers **201 when this call created the recap,
200 when it already existed**. A duplicate final is the expected case, not an
error — the poll cycle is deliberately safe to re-run and a Sidekiq retry can
deliver the same final twice, so neither end has to deduplicate in memory.

The payload shape and the shared team-slug convention are documented under
**"Game Recap Workflow → The cross-repo seam"** in
[`content-pipeline.md`](content-pipeline.md); the partial unique index that makes
the duplicate safe is one subsection further on, under **"Idempotency is
structural, not incidental"**. This doc does not repeat either.

**Measured 2026-09-24: this flow has delivered nothing.** The hub holds **zero**
`Content` rows of any workflow, so zero game recaps. Every part of the seam is
implemented and the endpoint answers, but no push has ever landed in production.
Read flow 2 as built-and-unexercised, not as the working half of the pair.

---

## The three design decisions, and why each is load-bearing

Each of these looks like an arbitrary implementation choice. None of them is.
**Do not "simplify" any of the three without reading its reason.**

### 1. The sync key is `gsis_id` — never the slug, never the name

`Studio::SyncAthletes#upsert`, in `turf-monster/app/services/studio/sync_athletes.rb`,
finds its row by `gsis_id` alone.

**Why not the slug:** a slug changes the moment a namesake forces a disambiguator
onto it. **Why not the name:** names collide outright.

Measured on hub production, 2026-09-24: **six namesake groups among athlete
`Person` rows — twelve people — and six rows carrying a disambiguator.** The
groups were Aaron Brewer, Byron Murphy, Byron Young, Jaylon Jones, Justin
Jefferson and Marcus Harris. Keyed on a slug or a name, a rename would fork one
player into two rows, and every downstream foreign key in turf-monster is a slug.

Re-derive rather than re-copy:

```bash
heroku run -x -a mcritchie-studio -- bin/rails runner \
  'puts Person.where(athlete: true).group(:first_name, :last_name).having("count(*) > 1").count.length'
```

### 2. The cursor is compound — `(updated_at, id)`, not a timestamp

`app/controllers/api/v1/athletes_controller.rb#apply_watermark` on the provider,
`SyncCursor#advance!`, in `turf-monster/app/models/sync_cursor.rb`, on the consumer.

**Paging on `updated_at` alone silently drops rows.** A bulk import stamps
thousands of records inside the same second, so a page boundary landing
mid-second skips every later row sharing that timestamp — permanently. The
replica ends up quietly short, and **nothing reports it**: there is no error, no
retry, and no count that looks wrong. `(updated_at, id)` is unique and totally
ordered, so the keyset always resumes exactly where it stopped.

The provider is inclusive (`>=`) on the first page of a window and exclusive
(`>`) past a cursor, paired with an idempotent upsert on the consumer. That
pairing is the safe one: a consumer that stored the last row's `updated_at` and
re-asked with `>` would lose every row sharing that exact timestamp — the same
defect the compound cursor exists to prevent, reintroduced one layer up.

**A nil `updated_since` IS the full rebuild.** There is no separate "full" mode to
get wrong on either side; `FULL=1` only clears the stored watermark.

### 3. Pull, never push — and never in a request path

**Turf Monster is a live wagering app.** It settles contests people paid to enter.
A runtime dependency on the hub would make the hub's availability part of turf-
monster's *correctness*, not merely its freshness.

**A stale player name is survivable. A 500 on a contest page is not.**

This is why flow 1 is a rake task written for a cadence, writing to a local
replica, and why
flow 2 is a background job rather than an inline call. It is also why the hub
never reads turf-monster's database: the crossing is two endpoints, and that is
the whole of it.

---

## The local-write guard, and its axis

`Athlete#refuse_local_writes_to_synced_rows`, in `turf-monster/app/models/athlete.rb`,
refuses a local write to a synced row, raising `ActiveRecord::ReadOnlyRecord`. The sync
itself sets `syncing` to write legitimately.

**A replica that is only conventionally read-only becomes a second master by
accident**, so the refusal is enforced rather than documented.

**The guard started biting on 2026-09-24.** Before that day's first production
sync, `Athlete.synced.count` on turf-monster was **0** and the guard could not
fire on anything. It now covers **2,049 rows**. Assigning `position`,
`team_slug`, or any other `STUDIO_MASTERED` column on a synced athlete raises
`ActiveRecord::ReadOnlyRecord` today.

### The subtlety: the axis is the COLUMN, not the ROW

The question the guard asks is **"does the master own this column"** — *not* "is
this row synced". That distinction is the whole design, and the first cut got it
wrong.

The first cut refused every column except the sync's own bookkeeping. That locked
out turf-monster's **own** nflverse importer — recorded in the guard's own header
as measured attempts on `college_name`, `draft_pick`, `draft_round`, `draft_year`
and `jersey_number`, **none of which the hub masters or sends.** A synced athlete therefore rendered
**"Drafted: Undrafted" forever**. Worse, it failed loudly in a place nobody was
listening: the importer's rescue does not catch `ReadOnlyRecord`, because it
rescues `RecordInvalid` and `RecordNotUnique`, which are *siblings* of it rather
than ancestors. The write died rather than degrading.

So the guard refuses only the thirteen columns in
`Athlete::STUDIO_MASTERED` (`turf-monster/app/models/athlete.rb`) and leaves everything else
locally writable. That list is asserted against the key set of
`Studio::SyncAthletes#attributes_from` — the consumer's own reader — in
`turf-monster/test/services/studio/sync_athletes_test.rb`, so **what the sync
writes and what the guard refuses cannot drift apart silently.** Widen
`attributes_from` without widening `STUDIO_MASTERED` and the test reds.

**That invariant is intra-repo, and it stops at the repo boundary.** Both sides
of the assertion live in turf-monster; `STUDIO_MASTERED` appears **zero** times
in the hub (measured 2026-09-24). Nothing checks either list against the hub's
`#serialize`. Add a field there and no test anywhere reds — `attributes_from`
names its keys explicitly, so the new field is simply ignored by the replica
until someone adds it on this side too. The cross-repo half is convention, not a
guard.

---

## The namesake refusal — the replica may decline a row

`Studio::SyncAthletes#build_for`, in `turf-monster/app/services/studio/sync_athletes.rb`,
is the CREATE fallback, reached when the master sends a person the replica already holds under
a different league id. **It refuses rather than adopting.**

Adopting blindly here overwrote a *different human* who happened to share a slug.
The incident is recorded in that method's own header: the hub's `00-0028946`
(Aaron Brewer) took over turf-monster's `00-0036171`, and the hub's `chris-smith`
`00-0038602` took over `00-0038661` — a man the master holds no row for at all, so
**a full rebuild could not have restored him.**

That last claim still holds today. Comparing the two `gsis_id` sets on 2026-09-24:
`00-0038602` is **hub-only**, and `00-0038661` is **turf-monster-only** — the
master has no row for him now either. Nothing raised at the time: there are zero unique collisions across
the two tables, so the bad write simply succeeded, and the `Person` row was
untouched so the page still showed the right name.

**The refusal has now fired in production.** The first real run wrote 242 of the
244 rows the replica was missing and declined 2. The two still hub-only afterwards
are `00-0028946` and `00-0038602` — the hub side of both incidents above. No
durable record names them as refusals, because none exists (gap (d)); the
attribution is the arithmetic plus the fact that `#build_for`'s only other
`nil` return needs a blank `person_slug`, which the provider never sends.

The replica cannot fix this itself. It cannot overwrite (that is the bug), it
cannot make a twin (`person_slug` is unique on athletes), and it must not invent a
disambiguated slug, because **slugs are the master's**. So it refuses, records who
collided with whom, and the rake task prints every one with both league ids.

**Three writers reach these tables and all three carry this predicate:** the hub's
`app/services/nflverse/seed_players.rb#resolve_athlete!` (the master), the replica
sync, and turf-monster's own importer of the same name. They diverge only on what to do once
a namesake is detected, and the difference is the *lane*, not taste:

- a **sync** handles a row the master already named, so it must not invent a slug —
  it refuses and records the collision;
- an **importer** reads a third-party CSV the master never sent, so there is no
  master slug to contradict — it mints a disambiguated one, and refuses only when
  it cannot derive a free slug at all.

---

## Where this actually stands — measured 2026-09-24

**These are point-in-time measurements. Re-derive them; do not re-copy them.**

**This page straddles an event, so every turf-monster figure carries a side.**
The first production run of `studio:sync_athletes` finished at
**2026-09-24T05:37:07Z**. "Before" was measured shortly before it; "after" at
**2026-09-24T13:42Z**. A turf-monster number quoted without a side means nothing.

| | hub (`mcritchie-studio`) | turf-monster before | turf-monster after |
|---|---|---|---|
| `Person` | 2,088 | 2,896 | **3,138** |
| `Athlete` | 2,051 | 2,896 | **3,138** |
| `Athlete` with a `gsis_id` | 2,051 | 2,896 | **3,138** |
| `Athlete` by sport | football 2,051 | football 2,896 | football 3,138 |
| `Team` | **0** | — | — |
| `Content` (any workflow) | **0** | — | — |
| `Content` with `workflow: "game_recap"` | **0** | — | — |
| `Athlete.synced` (came from the hub) | — | **0** | **2,049** |
| `SyncCursor` for `studio_athletes` | — | **never run** | `ok` · 2,051 seen · 626 written |
| `Player` (legacy table) | — | 85 | 85 |
| `Goal` | — | 389 | 389 |
| `Goal` with a `player_slug` | — | 25 | 25 |

The hub side did not move across the event — `Person`, `Athlete`, `Team` and
`Content` read identically at both times. Its last successful `nflverse_players`
import finished **2026-09-21T05:38:54Z**, status `ok`.

**That cursor reading `ok` is gap (d) happening, not a clean run.** The run
refused two rows. The cursor has no way to say so, and `studio:sync_status`
reports it as clean.

**Only one of the two flows has ever moved data in production.** Flow 1 populated
the replica on 2026-09-24. Flow 2 has delivered **zero** recaps — the hub holds
zero `Content` rows of any kind — so the hub has received nothing from
turf-monster, ever.

Both endpoints are live and auth-gated — `GET /api/v1/athletes` and
`POST /api/v1/game_recaps` each answer **401 `Missing token`** unauthenticated.
Both rake tasks exist on the deployed turf-monster slug (release **v286**,
`2255b483`, identical to `origin/main`).

Re-derive with:

```bash
heroku run -x -a mcritchie-studio -- bin/rails runner \
  'puts [Person.count, Athlete.count, Team.count, Content.count].inspect'
heroku run -x -a turf-monster-mainnet -- bin/rails studio:sync_status
```

---

## Gaps — unbuilt legs, named as gaps

These are **not** features. Nothing in the running system flags any of them.

### a) There is no team sync

The architecture names **person / athlete / team** as the hub's scope. **Only the
athlete leg was built.** There is no `/api/v1/teams` endpoint, no `Studio::SyncTeams`,
and the hub's `teams` table is **empty** (measured `Team.count = 0`, 2026-09-24) —
the table and the `Team` model exist, so this is an unpopulated master, not a
missing schema. Turf-monster's team slugs are its own. Nothing reports the
absence.

### b) There is no cadence — nothing calls the sync

`studio:sync_athletes` is referenced only by its own rake file and by comments.
Measured 2026-09-24: it appears in **no** `config/schedule.yml` entry, in **no**
`Procfile` line, and `turf-monster-mainnet` carries **no Heroku Scheduler addon**
(its only addons are Postgres and Redis). The service's own comment says "this
runs from a cadence" — **that cadence does not exist.** The sync runs only when a
human or an agent runs the rake task by hand, and as of this writing it has done
so in production exactly **once**, on 2026-09-24 (gap (c) below).

**Whoever builds the cadence inherits the abort.** A hub the task cannot reach
records `failed` and exits non-zero — see "Two different failures" under flow 1.
The schedule has to tolerate that, or run somewhere a red exit costs nothing.

### c) The replica was empty until 2026-09-24 — and the "845-row gap" was a net figure

**Read the timestamps here.** This section describes a boundary the system
crossed on the day it was written: the replica was empty, and then it was not.

**Before 2026-09-24T05:37:07Z:** `SyncCursor` for `studio_athletes` had **no
row** and `Athlete.synced.count` was **0**. All 2,896 of turf-monster's athletes
came from its own local nflverse importer, so the 845-row difference against the
hub's 2,051 was not replica drift — there was no replica.

The guess that turf-monster carries soccer athletes the hub never sees is
**falsified on both sides of the event**: measured by sport, every turf-monster
athlete is `football` (2,896 then, 3,138 now), and so are all 2,051 on the hub.

Comparing the two `gsis_id` sets directly shows 845 was a **net** figure masking
a two-sided difference, and shows what the run did to each side:

| | before the sync | after it (13:42Z) |
|---|---|---|
| ids in **both** | 1,807 | **2,049** |
| **hub only** — the replica lacks them | 244 | **2** |
| **turf-monster only** — the master holds no row | 1,089 | 1,089 |

The run closed the hub-only side and left the other untouched, which is what a
one-way pull should do. The arithmetic closes exactly: 244 hub-only − 2 refused
namesakes = **242 creates**; 2,896 + 242 = 3,138; 1,807 + 242 = **2,049 synced**.
The 2 still hub-only are the pair the namesake section above names.

**The 1,089 turf-monster-only rows are not a sync problem and no run will shrink
them.** Both repos ship the same `Nflverse::SeedPlayers` importer with
**different defaults** — the hub's are `min_season 2024` with no status filter,
turf-monster's are `min_season 2026` with `status: "ACT"` — and both rake tasks
let the environment override them, so the two populations are the product of two
independent runs with independently chosen filters. **Which parameters each run
actually used is not recorded anywhere I could read, so the split between the two
sets is not attributed here.**

Seven turf-monster rows carry a value in `gsis_id` that is not in nflverse's
`00-nnnnnnn` shape (`BOB309160`, `DEA063889`, `HEN626514`, `KIN587489`,
`LAU726757`, `TEC426541`, `THO210380` — all football, all on NFL teams). Since
the sync keys on `gsis_id`, **those seven can never match a hub row** — and the
first production run bears that out: all seven are still **unsynced** after it.

Re-derive the set comparison by plucking `Athlete.where.not(gsis_id: nil).pluck(:gsis_id)`
from each app and diffing the sorted lists.

### d) A collided run leaves no durable record

`turf-monster/app/services/studio/sync_athletes.rb` writes **no `ErrorLog`**. A
refused namesake is carried on the `Result` and printed to stderr by the rake
task — and nowhere else.

**The cursor cannot hold it, and the reason is structural rather than an
oversight.** Three independent things would each have to change:

- `SyncCursor::STATUSES` (`turf-monster/app/models/sync_cursor.rb`) is
  `%w[ok failed skipped]`, so the `ok_with_collisions` status the service returns
  is **unrepresentable** on the cursor — not merely unpassed.
- `SyncCursor#advance!` hard-codes `last_status: "ok"` and **takes no status
  parameter**, so there is nowhere to pass one.
- `Studio::SyncAthletes#call` calls `advance!` **inside** the page loop, while
  the collision list is only resolved **after** the loop ends. The cursor is
  written before the run knows whether it collided.

**This is not hypothetical.** The first production run, 2026-09-24T05:37:07Z,
refused two rows, and the cursor it left behind reads `status "ok", seen 2,051,
written 626`. The refusals appear nowhere in it, and `studio:sync_status` reports
that run as clean.

**If nobody reads the run's output, the refusals are lost.** Each one is a human
the master and the replica disagree about, and only the master can resolve it.

### e) Wave 5 is outstanding — retiring `Player`

Turf-monster still carries its own legacy `players` table (85 rows) and its own
nflverse importer. Retiring them is blocked on `goals.player_slug`, which points
into `players`.

The backfill is lossy: `Player#name_slug` is `name.parameterize` while
`Athlete#name_slug` is `person_slug` plus `-athlete`, so rows **cannot** be
repointed by slug equality — only by name plus team, which collides on exactly the
namesakes above. **Measured 2026-09-24: only 25 goal rows carry a `player_slug`,
not 389**, so the remaining work is far smaller than the original framing.

---

## Known stale pointers

### The service's own header comment is wrong about skips

`Studio::SyncAthletes`' class comment says `#call` "NEVER raises for an
environment condition — an unconfigured stack **or an unreachable provider** is a
skip, recorded on the cursor." **The second half is false**, and the code three
methods below it is the authority: `#request` raises `Error` on every transport
failure, every non-2xx response and an unparseable body, and `#call` records
`failed`. A wrong comment propagates — a reader reaching for the code reaches the
comment first, and this doc asserted the same wrong thing until it was traced.
Correcting the comment is a turf-monster code change and belongs to a
turf-monster task, not here.

### The roster-sync SOP is still marked PENDING

`docs/agents/agents/turf_monster/sops/roster-sync.md` opens with
`Status: PENDING` on the premise that `studio:sync_athletes` and
`studio:sync_status` "do not exist on production". **Measured 2026-09-24 against
release v286: both tasks exist on the deployed turf-monster slug.** That header
and its blocking table are out of date. Flipping it — and adding the heartbeat
rows it deliberately withholds — belongs to the SOP task, not here, because
marking it active licenses running the act on a schedule and that carries
obligations this doc does not discharge.

# Market Refresh

## Status: Active — check the environment before the first run

This SOP describes turf-monster work that landed in two pieces: the pricing rule
(per-game ranking and the bye line) with `two-line-bye-multipliers`, and
everything you actually RUN — `market:pull`, `market:refresh`, the
`/benchmarks` page — with `refresh-market-benchmarks`. An environment has them
once the release carrying them reaches it, and not before.

**So check the environment you are pointing at, before the first command, not
after:**

```bash
bin/rails -T market            # market:pull AND market:refresh listed?
curl -sS -o /dev/null -w '%{http_code}\n' <base-url>/benchmarks   # see the table
```

Locally that is your desk; on production, `heroku run --no-tty -a
turf-monster-mainnet -- bin/rails -T market` and `https://turfmonster.media`.
(The `--` is required: without it `-T` is eaten as a `heroku` flag.)

**No `-L` on that curl, deliberately.** Following the redirect lands on the
homepage and prints `200`, which masks the very failure the check exists to find.
What each answer means:

| Code | Means | Do |
|---|---|---|
| `404` | the route is not drawn — **the release has not landed here** | Stop. Nothing in this SOP has a manual fallback |
| `302` | deployed, but no slate resolved — a DATA problem, not a release one | Name the span explicitly: `/benchmarks/<span-slug>` |
| `200` | deployed and rendering | Carry on |

`bin/rails -T market` answers the same question from the other side, but
**quietly — read the LISTING, never the exit code.** An environment on an older
release still lists `market:snapshot` from it, prints no error, and exits `0`;
only `market:pull` and `market:refresh` answer this question. The loud answer
comes one command later, if you skip this check: a task that is not there aborts
with `Unrecognized command` and exit `1`.

Everything else here — the split, the decisions, the refusals, the escalations —
is settled and waits on nothing.

This is Turf Monster's `market-refresh` SOP. It rebuilds a span slate's Turf
Score benchmarks from fresh DraftKings numbers: pull the week's lines, ingest
them, re-read the span's expected points, and reprice every team under the
current rule.

Run it **after a week concludes and before the next span's contest locks** —
typically Tuesday. Lines move all season; a span priced in May off a lookahead
number is not priced off the market anyone is actually betting into.

It is Turf Monster's because every judgment it asks for is a sports-domain
judgment: whether a line move is the market learning something or a bad feed,
whether a repriced team still reads right against the schedule, and whether a
contest that already took money should be repriced at all. The failure mode is a
domain failure too — a wrong benchmark does not look like an outage, it looks
like a contest that priced a team wrong and paid on it.

**It holds no release lane.** It writes `slate_matchups`, `nfl_team_total_projections`
and a `market_snapshots` row **per week** (the WEEKS=4,5,6 example writes three). It never touches `release` or `main`, never
promotes, and never deploys.

## The split — read this before running anything

**You decide nothing about arithmetic.** How a game total and a spread become a
team's expected points, how per-game strength becomes a rank, and how a rank
becomes a multiplier all live in turf-monster code, under test, identical on
every run.

| Deterministic — the code | Agentic — you |
|---|---|
| Calling ESPN, reading DraftKings' lines | Choosing the span and the weeks |
| Deriving team points from total + spread | Judging whether a line move is real |
| Ranking on points per game | Deciding to reprice a contest that has paid entries |
| Pricing each line (full-span and bye) | Escalating that decision to Alex |
| Refusing a started slate, a gap, drift | Reading the refusal and choosing the remedy |

If you find yourself reasoning about **what a team's multiplier should be**,
stop. The code owns that. Your judgment is spent on whether to run it at all,
and on what a refusal means.

## Preconditions

- The span slate exists and its first game has **not** kicked off.
- You know its slug (`nfl-2026-weeks-4-6`) and the weeks it holds (4, 5, 6).
- The turf-monster release carrying `market:pull` / `market:refresh` is deployed
  to the environment you are running against.
- For a **production** run: you have Alex's answer on paid picks (below)
  before you pass `APPLY=1`.

## Steps

### 1. Dry run, and read it

```bash
# local desk
bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6

# production (read-only in this form — it writes nothing without APPLY=1)
heroku run --no-tty --exit-code -a turf-monster-mainnet -- \
  bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6
```

`--exit-code` is not optional even on a dry run: without it a REFUSED run comes
back exit 0, so a script — or a tired reader — takes a refusal for a pass.

It prints four blocks, and every one of them is worth reading:

1. **pull** — every line that moved since the dataset was written, per game.
2. **ingest** — skipped on a dry run, and it says so. Nothing has been written.
3. **refresh** — each expected score that would change, by team and week.
4. **reprice** — each team whose rank or multiplier would change, and **how many
   paid picks the slate carries**.

**Judge the moves before you write anything.** A handful of half-point moves is
an ordinary week. Every game moving, or a total moving by five, is a feed
question, not a market one — check one game against a sportsbook by hand before
continuing.

### 2. Settle the paid-pick question

If the reprice block reports **0 paid picks**, skip this step.

If it reports any, the dry run will end in a refusal, and that is the design: a
paid pick was bought at the price it was shown. Repricing it is
**Alex's decision, not yours.** Bring him these four facts:

- which teams the paid entries hold, and what each one's price would become;
- how many entries are affected (an abandoned or cart entry is not one);
- when the contest locks;
- that a paid entry can still change its picks until lock (`Entry#update_picks!`),
  so a repriced entrant is not stuck with a pick they would not have made.

Then carry his answer as the flag, which names the slate deliberately:

```bash
# local desk
APPLY=1 REPRICE_PAID_PICKS=nfl-2026-weeks-4-6 \
  bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6

# production — both flags ride -e, semicolon-separated, never a shell prefix
heroku run --no-tty --exit-code -a turf-monster-mainnet \
  -e "APPLY=1;REPRICE_PAID_PICKS=nfl-2026-weeks-4-6" \
  -- bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6
```

The flag unlocks **only** the slate it names — an override left in your shell
from last week cannot reprice this week's contest.

### 3. Apply

```bash
# local desk
APPLY=1 bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6

# production — the flag must reach the DYNO, via -e
heroku run --no-tty --exit-code -a turf-monster-mainnet \
  -e "APPLY=1" \
  -- bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6
```

**This is the whole command for the ordinary case.** It carries no paid-pick
override, and it must not: that flag disarms the one guard this SOP calls
Alex's decision. Add it only through step 2, and only with his answer in
hand.

**`-e` is not decoration, and a shell-style prefix is the trap.** `heroku run
APPLY=1 bin/rails …` sets the variable in YOUR shell, not the dyno's: the task
then dry-runs and prints output all but identical to an apply, so the operator
reads success and production is untouched. `-e` passes them through (semicolons
separate; measured against `turf-monster-mainnet` 2026-09-19 — the dyno read
`APPLY="1"`). Confirm from the run's own output before believing it — **on the positive test
alone: it ends `APPLIED.`** Anything else wrote no price, `REFUSED:` included. Do
not read "it said APPLY and not `Dry run only`" as success: a refused apply says
both of those and still ends `REFUSED:`.

The refresh and the reprice commit together or not at all, so a refusal at the
last step leaves every price and every expected score exactly as it found them.

**The INGEST is already committed by then**, and that is the one piece this
atomicity does not cover: the ingest block writes the week's projections and its
snapshot rows before the refresh transaction opens. A later refusal leaves those in place.
Nothing is mispriced by it — prices live on `slate_matchups`, which the rollback
restores — but the market rows do now describe a pull whose reprice never landed.
Re-running after clearing the refusal reconciles them.

### 4. Verify, in this order

1. **The page** — `/benchmarks/<span-slug>` (public). It reads the STORED
   values, so it shows exactly what the board will pay: each team's points per
   game, its rank, its multiplier, and the bye line where one applies. Check the
   PRICES against the reprice block you just read.

   **Do not lead with the snapshot line.** "Lines pulled today" resolves through
   the ingest rows, which commit before the refresh transaction — so it reads
   green on a REFUSED apply too, and it is the one signal on this page that
   cannot fail. It confirms the pull; the prices confirm the apply.
2. **The bye teams** — on a span with byes, every bye team is badged and sits on
   the x1.5-x3.0 line. **Read the BADGE, not the number.** The bye line's lower
   half overlaps the full-span line — a strong bye team at rank 2 prices x1.5,
   below plenty of three-game teams — so a bye team at or under x2.0 is ordinary
   and proves nothing either way. What does: an unbadged bye team (the page is
   not seeing two lines at all), or a badged team priced above x2.0 where no
   three-game team can reach, which only the bye line produces.
3. **The dataset** — on a LOCAL run, `git diff db/seeds/data/nfl/*.csv` shows
   exactly the games that moved. Commit it (see step 5).

### 5. Keep the repo's copy in step

**A production run writes the dataset to the dyno, and the dyno is thrown away.**
The database keeps the numbers and the `MarketSnapshot` keeps the provenance, but
the checked-in CSV does not move. So after a production run, reproduce the pull
locally and commit the file:

```bash
APPLY=1 bin/rails market:pull WEEKS=4,5,6     # from a worktree
git diff db/seeds/data/nfl/2026_expected_team_totals.csv
```

**It is a second, independent fetch, not a transcript of the production run.**
`market:pull` always re-reads ESPN live, so if a line moved in between, the
committed CSV records the LATER number. That is fine for a seed source — it is
still the market — but never cite the file as evidence of what production
applied. The `MarketSnapshot` rows are that record.

That diff is the week's market movement, and it belongs in a normal task and PR
like any other change. Do not skip it: the next environment built from seeds
would otherwise price off stale lines.

## What it refuses, and what each refusal means

| Refusal | What it means | Remedy |
|---|---|---|
| `carry no readable DraftKings line` | ESPN served a game with no DK odds, or a team abbreviation that maps to no `Team` | Re-run in a few minutes; a new abbreviation needs a `Nfl::Espn::TeamMap` alias |
| `the schedule moved` | The week's matchups no longer match the dataset — a flexed game | That is a slate REBUILD, not a refresh. Decide what happens to the slate first; `ALLOW_SCHEDULE_CHANGE=1` accepts the dataset half deliberately (on production it rides `-e`, semicolon-separated — steps 2 and 3) |
| `paid pick(s)` | The slate backs money | Step 2. Never pass the override on your own judgment |
| `kicked off` | The span's first game has started | **Nothing.** A started span is never repriced — the race is being run |
| `no longer in the weekly slates` | A span row's game is absent from its source week | Same as schedule drift: a rebuild question |

## Escalate rather than improvise when

- the paid-pick override would be needed and Alex has not answered;
- the pull reports moves on nearly every game, or a total moves by more than ~5;
- a refusal repeats after its remedy;
- the span you were asked to refresh has already kicked off.

## Background — not needed to execute

Why ESPN and not DraftKings: DK's sportsbook refuses this network outright
(Akamai `403`, every URL shape, headless included), while ESPN's public
scoreboard carries DK's own lines with no key. ESPN publishes the primitives
only — game total and spread — so every NFL row is `basis: "derived"` and none
may be stamped `posted`.

Why a span needs its own refresh: `Nfl::BuildSpanSlate` rebuilds by destroying
matchups, which would cascade to live `Selection` rows, so it refuses any slate
that backs a pick. `Nfl::RefreshSpanSlate` updates the rows in place instead.

The mechanics, step by step, with citations:
`turf-monster/docs/workflows/market-snapshot.md` (the fetch, the dataset, the
ingest and the artifact; the span rebuild joins them as its last step with
`refresh-market-benchmarks`). The pricing rule
itself — per-game ranking, and the two lines a bye span prices on —
is `turf-monster/docs/FORMULAS.md`.

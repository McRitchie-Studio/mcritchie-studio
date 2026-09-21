# Roster Sync

## Status: PENDING — do not run steps 2 and 3 yet

**Two of this SOP's commands do not exist on production.** `studio:sync_athletes`
and `studio:sync_status` ship in turf-monster PR **#789**, and the
`FEED UNAVAILABLE` behaviour step 1 relies on ships in McRitchie Studio PR
**#1489**. Both are OPEN. Measured on the deployed slug: `turf-monster-mainnet`
runs `17b05084`, identical to `origin/main`, and a full-tree grep finds zero
hits — so each line dies with `Don't know how to build task
'studio:sync_athletes'`.

**MERGING #1489 DOES NOT SATISFY STEP 1's RULE — IT INVERTS IT.** Today an
nflverse outage RAISES (`ImportRun.track` stamps `failed` and re-raises), which
is why step 1 says a red run is a STOP. #1489 adds the graceful
`FEED UNAVAILABLE` path that *warns and returns*. So on the day it lands, "a red
step 1 is a STOP" becomes wrong, and this file needs a REWRITE of that rule, not
a status flip.

**WHO FLIPS IT, and what they must do** — the builder of whichever of the two PRs
lands LAST, as part of that task:

| PR | What it unblocks | What it obliges |
|---|---|---|
| turf-monster **#789** | steps 2 and 3 exist at all | nothing else — the commands simply start working |
| McRitchie Studio **#1489** | the `FEED UNAVAILABLE` path | **rewrite step 1's verdict rule**: a warn-and-return is no longer a STOP, and the check becomes "did the ImportRun finish `ok` TODAY", not "did the command exit 0" |

Only then: set `Status: Active`, and add the rows this file is deliberately
missing from the heartbeat and `modules/heartbeats.md`. It is registered in
`docs/agents/index.md` and in `ACT_OWNER` (see below), and nowhere else, on
purpose: a `roster-sync` invocation must not resolve to a procedure production
cannot run. Step 1 is accurate today and safe to run on its own.

**EVERY command here is `heroku run -x -a <app>`, and that is deliberate — there
is no `cd` in this file.** The cwd cannot matter when the app is named on the
line, a `cd` would not survive to the next step anyway (shell state does not
cross a turn boundary), and its only real effect would be to make a MISSING
`-a` resolve silently against whichever app the checkout's `heroku` remote
points at. `-x` is equally load-bearing: without it `heroku run` discards the
remote command's exit code and a failed sync reports success
(`heroku help run`: *"-x, --exit-code  passthrough the exit code of the remote
command"*).

This is Turf Monster's `roster-sync` SOP. It refreshes the player, team and
person data both apps run on — before a season, before an event, or any time
the roster looks wrong.

**There is no "quick mode" and no "full mode".** There is one command, and a
missing watermark IS the full rebuild. Run it when one player moved and it
finishes in seconds; run it against an empty database and it chugs through
every row. You do not have to decide which situation you are in, which is the
point — deciding wrongly is how a "quick" sync silently skips the rebuild you
actually needed.

## The split — read this before running anything

**You decide nothing about the data.** Every rule about which record a row
belongs to, what changed, and what may be written lives in code.

| Deterministic — the code | Agentic — you |
|---|---|
| Which athlete a row belongs to (`gsis_id`) | Whether the result looks right |
| What changed since the watermark | Whether to escalate a mismatch |
| Which rows may be written | When to force a full rebuild |
| Refusing writes to replica rows | Reading the reconciliation out |

If you find yourself reasoning about **which Joe Burrow is which**, stop. The
code keys on the league ID and already knows. Your judgment is spent on whether
the numbers at the end are believable.

## The direction of travel, and why order matters

```
nflverse ──> McRitchie Studio ──> Turf Monster
             (the provider)       (a read replica)
```

**McRitchie Studio masters every durable fact** about a person, a team or a
place. **Turf Monster masters events** — games, goals, contests, entries.
Neither writes into the other's master.

So MS refreshes from nflverse FIRST, and TM syncs from MS SECOND. Reversing
that just propagates staleness: a sync from a stale provider is a fast, green,
useless run.

## Scope

This SOP refreshes data. It does not review PRs, merge, deploy, settle
contests, or pay anyone out. It holds no release lane.

## Entry — WHICH environment, stated in the command

**Production by default. A local run is a REHEARSAL and must be called one.**

Naming the app in the command is the safeguard: the target cannot drift from
what you believe you are refreshing.

### Step 1 — refresh the provider from nflverse

```bash
heroku run -x -a mcritchie-studio 'bin/rails runner "Nflverse::SeedPlayers.new(status_filter: %q(ACT), upload_headshots: false).call"'
```

`upload_headshots: false` is not optional here. The default is `true`, and that
path RAISES when `AWS_ACCESS_KEY_ID` is unset — which is the state on QA. It
also turns a data refresh into thousands of image fetches and S3 writes, which
is a separate job, not part of a roster sync.

**A feed outage RAISES today — do not read a failure here as benign.**
`ImportRun.track` (`app/models/import_run.rb`) stamps the run `failed` and
**re-raises**, and `fetch_remote` has no rescue, so an nflverse outage aborts
the step with a non-zero exit and a stack trace. There is no `FEED UNAVAILABLE`
line on production; that graceful degradation ships in McRitchie Studio PR
**#1489** and is not merged. Until it is, a red step 1 is a STOP: the data is
stale, and step 2 would sync a replica from a source that did not refresh.

Either way, confirm what actually landed before going on — a run that errored
and a run that never started look the same from the next step:

```bash
heroku run -x -a mcritchie-studio 'bin/rails runner "r = ImportRun.last_success_for(%q(nflverse_players)); puts r ? r.finished_at : %q(never)"'
```

If that prints a timestamp from before today, the refresh did not land — retry
once, then report rather than proceeding into step 2 on stale data.

### Step 2 — sync the replica

```bash
heroku run -x -a turf-monster-mainnet 'bin/rails studio:sync_athletes'
```

That is the delta. It resumes from its stored watermark, so a run interrupted
halfway picks up where it stopped rather than restarting.

**Force a full rebuild only when you have a reason:**

```bash
heroku run -x -a turf-monster-mainnet 'bin/rails studio:sync_athletes FULL=1'
```

Reasons that qualify: the replica is empty, you have just restored a database,
the counts in step 3 disagree and you do not know why, or a namesake's slug
changed. "It feels stale" does not qualify — the watermark already knows.

### Step 3 — reconcile, and do not skip this

```bash
heroku run -x -a turf-monster-mainnet 'bin/rails studio:sync_status'
heroku run -x -a mcritchie-studio 'bin/rails runner "puts %Q{MS athletes=#{Athlete.count} missing_gsis=#{Athlete.where(gsis_id: [nil, %q()]).count}}"'
```

Read three things:

1. **DO NOT compare the two totals. They are not comparable, and the reason is
   not the one you would guess.** Measured 2026-09-21:

   | | |
   |---|---|
   | McRitchie Studio production | **2,051** |
   | turf-monster production | **2,896**, every row created 2026-08-28 |
   | today's feed, MS filter (`ACT`, `last_season >= 2024`) | **2,051** |
   | today's feed, TM filter (`ACT`, `last_season >= 2026`) | **1,731** |

   The filter difference is worth **+320 in MS's favour** — MS's season window
   is the WIDER one. The other **−1,165** is TIME: turf-monster's table was
   built from the live feed on 2026-08-28, before roster cutdowns, and the
   feed's ACT set has shrunk since. Both tables are single imports taken 24 days
   apart from a moving source.

   So a gap of hundreds today is STALENESS, not a dropped page — and it would
   still be there if both filters matched. (Three hypotheses died getting here:
   that the gap was person-vs-athlete, that it was the filter, and that
   turf-monster's table was an accumulation. It is one import, on one day.)

   **What IS comparable, and what to actually check:** after a sync, the replica
   should hold one synced row per row the master sent.

   ⚠️ **This command is part of the PENDING half and fails today** — `synced_at`
   is a column turf-monster PR **#789** adds, and production's `athletes` does
   not have it yet. Measured 2026-09-21: the line below exits **1** against
   `turf-monster-mainnet`. That is the same defect this whole file was blocked
   for, so it is marked rather than quietly included.

   ```bash
   # requires #789 merged and deployed
   heroku run -x -a turf-monster-mainnet 'bin/rails runner "puts %Q{synced=#{Athlete.where.not(synced_at: nil).count} total=#{Athlete.count}}"'
   ```

   `synced` should equal MS's `athletes` count, and `rows_seen` from step 2
   should equal it too. `total` will EXCEED it by turf-monster's own pre-sync
   rows for as long as its importer still runs — that excess is expected and is
   not the sync's business.
2. **`missing_gsis` is 0.** A single athlete without a league ID cannot be
   synced at all and cannot be matched by any later importer.
3. **`last_status` is `ok`.** `skipped` means `AGENT_API_SECRET` is unset on
   that app and nothing ran. `failed` means the provider was unreachable — the
   cursor's `detail` says which.

**A green run with a wrong count is the failure mode to watch for**, because
nothing errors. That is why this step is not optional.

## What good looks like

- Step 1's `ImportRun` finished today with status `ok`.
- Step 2 reports `status: ok` and a `written` count that is SMALL on a delta —
  a delta that rewrites thousands of rows means the provider re-stamped
  everything, which is worth understanding before trusting it.
- Step 3's `synced` count equals the master's `athletes` count, and
  `missing_gsis` is 0. (NOT the two TOTALS — see step 3.)
- Nothing needed a `FULL=1`.

## When to stop and escalate

- **`missing_gsis` is not 0** — the provider's import is broken. Do not sync a
  replica from it; report and stop.
- **`synced` does not equal the master's count** — run `FULL=1` ONCE. If it
  still disagrees, stop: something is dropping rows and a third run will not
  find it. A gap between the two TOTALS is not this condition and never was;
  turf-monster carries its own pre-sync rows by design.
- **`last_status: skipped`** — `AGENT_API_SECRET` is missing on that app. It is
  the same shared secret both apps already hold; this is a config gap, not a
  data problem.
- **A namesake's slug changed unexpectedly** — two players sharing a name is
  normal but a slug CHANGING is not, because other records point at it. Report
  which player. Measured 2026-09-21 against the feed under the master's filter:
  **six groups, twelve players, every one a pair** — Aaron Brewer, Marcus
  Harris, Justin Jefferson, Jaylon Jones, Byron Murphy, Byron Young. (Aaron
  Brewer is the pair that the replica's collision guard refuses on, so expect to
  see him named there rather than silently overwritten.)

## Handoff

Report to Mr. McRitchie with both counts, the `last_status`, whether a full
rebuild was needed, and anything in step 3 that did not reconcile. If everything
was clean, say so in one line — a clean sync does not need a paragraph.

---

## Background — not needed to execute

Why the sync keys on the league ID rather than a slug or a name: a slug changes
the moment a namesake forces a disambiguator onto it, and names collide. Why
the replica refuses local writes: a replica that is only conventionally
read-only becomes a second master by accident, and then nobody can say which
value was right. Architecture:
`mcritchie-studio/docs/topics/content-pipeline.md`, named rather than linked
because the docs route serves `docs/agents` only.

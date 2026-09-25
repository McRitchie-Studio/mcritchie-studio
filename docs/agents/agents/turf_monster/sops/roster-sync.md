# Roster Sync

## Status: PENDING — do not run steps 2 and 3 yet

**Two of this SOP's commands do not exist on production.** `studio:sync_athletes`
and `studio:sync_status` ship in turf-monster PR **#789**, which is still OPEN.
Measured on the deployed slug: `turf-monster-mainnet` runs `17b05084`, identical
to `origin/main`, and a full-tree grep finds zero hits — so each line dies with
`Don't know how to build task 'studio:sync_athletes'`.

McRitchie Studio **#1489** — the other half — **merged 2026-09-21** (`620a9bda`)
and step 1 has been rewritten for it. It is on `accepted`, not yet on `main`, so
step 1's new rule describes production only after the next release ships.

**WHO FLIPS IT, and what they must do** — the builder of whichever of the two PRs
lands LAST, as part of that task:

| PR | What it unblocks | What it obliges | State |
|---|---|---|---|
| McRitchie Studio **#1489** | the `FEED UNAVAILABLE` path | rewrite step 1's verdict rule — a warn-and-return is no longer a STOP, and the check becomes "did the `ImportRun` finish `ok` TODAY" rather than "did the command exit 0" | **MERGED 2026-09-21, rewrite DONE** |
| turf-monster **#789** | steps 2 and 3 exist at all | teach step 3 the FOURTH status. `Studio::SyncAthletes` returns `ok_with_collisions` when the namesake guard REFUSES a row, and `studio_sync.rake:17` prints it — a status this file did not have, on the very Aaron Brewer collision the escalation list forecasts | OPEN |

So **#789 is the only thing left**, and its builder flips this file. Only then:
set `Status: Active`, and add the rows this file is deliberately missing from
the heartbeat and `modules/heartbeats.md`. It is registered in
`docs/agents/index.md` and in `ACT_OWNER` (see below), and nowhere else, on
purpose. Not because the invocation must fail to resolve — `index.md` IS the
invocation registry and this is registered there, so it resolves. The withheld
half is the HEARTBEAT: a heartbeat row is an instruction to run the act on a
schedule, and two of these three steps do not exist on production yet. Step 1 is
accurate today and safe to run on its own.

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

**DO NOT JUDGE THIS STEP BY ITS EXIT CODE.** McRitchie Studio PR **#1489**
merged on 2026-09-21 (`620a9bda`), and it deliberately made a feed outage
**warn and return** instead of raising: `FEED UNAVAILABLE — data not refreshed`
on stderr, a `failed` `ImportRun` recorded, and **exit 0**. That is the right
behaviour — a deploy should not abort because a third party is down, only the
DATA is stale — but it means a green exit no longer tells you the refresh
happened.

⚠️ **Measured on `accepted`, which is not yet what production runs.** #1489 is
merged but not shipped, so until the next release the deployed app still RAISES
on an outage and this step still goes red. The timestamp rule below is correct
in BOTH worlds — that is why it is the verdict and the exit code is not.

| Condition | Exit code on `accepted` |
|---|---|
| feed outage (e.g. `Errno::ETIMEDOUT`) | **0** — with a `FEED UNAVAILABLE` warning |
| ordinary bug (e.g. `ArgumentError`) | **1** |

**THE VERDICT IS THE TIMESTAMP, and the exit code is only a tiebreak.** Ask the
record, not the shell:

```bash
heroku run -x -a mcritchie-studio 'bin/rails runner "r = ImportRun.last_success_for(%q(nflverse_players)); puts r ? r.finished_at : %q(never)"'
```

- **A timestamp from today** → the refresh landed. Go on to step 2.
- **`never`, or a timestamp from before today** → it did not, whatever the exit
  code said. This is the STOP: step 2 would sync a replica from a source that
  never refreshed. Retry once, then report.
- **Exit 1** → not a feed outage but a real bug, and the stack trace is worth
  reading before anything else.

(Before #1489 this step aborted loudly on an outage, and an earlier revision of
this file told you to treat a red run as the signal. That rule is now not merely
wrong but UNREACHABLE — on an outage the step is no longer red.)

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
   that app and nothing ran. `failed` means the run did not complete — usually
   the provider was unreachable, but the service rescues `StandardError`, so any
   crash lands here; the cursor's `detail` says which, recorded by CLASS for
   anything we did not raise ourselves.

   ⚠️ **`last_status: ok` DOES NOT MEAN NOTHING WAS REFUSED, and that is a trap
   worth knowing before you read a clean line as a clean run.** Two things carry
   a status here and only one of them is the cursor. The RUN's status
   (`studio:sync_athletes`, the `status:` line) can read **`ok_with_collisions`**
   — rows the namesake guard refused to write. The CURSOR's `last_status`
   (`studio:sync_status`) stays `ok` for that same run, because nothing failed.
   So read step 2's own output, not only step 3's.

**A green run with a wrong count is the failure mode to watch for**, because
nothing errors. That is why this step is not optional.

## What good looks like

- Step 1's `ImportRun` finished today with status `ok`.
- Step 2 reports `status: ok` — the bare word, not `ok_with_collisions` — and a
  `written` count that is SMALL on a delta. A delta that rewrites thousands of
  rows means the provider re-stamped everything, which is worth understanding
  before trusting it.
- Step 3's `synced` count equals the master's `athletes` count, and
  `missing_gsis` is 0. (NOT the two TOTALS — see step 3.)
- Nothing needed a `FULL=1`.

## When to stop and escalate

- **`missing_gsis` is not 0** — the provider's import is broken. Do not sync a
  replica from it; report and stop.
- **`status: ok_with_collisions`** — read this one FIRST, because it explains a
  short `synced` and the remedy below would not. The namesake guard found a row
  whose `gsis_id` disagrees with the one this app already holds for that person,
  and REFUSED to write it: nothing was overwritten, and that row is simply
  missing. Step 2 names each one and prints the fix —
  *"resolve in McRitchie Studio (give one of them a disambiguated person), then
  re-run."* **A `FULL=1` cannot clear it.** The refusal is deterministic, so a
  rebuild refuses the same row again; only the MASTER can resolve it.
- **`synced` does not equal the master's count** — and step 2 did NOT report
  collisions. Then run `FULL=1` ONCE. If it still disagrees, stop: something is
  dropping rows and a third run will not find it. A gap between the two TOTALS is
  not this condition and never was; turf-monster carries its own pre-sync rows by
  design.
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

Report to Alex with both counts, step 2's `status` and the cursor's
`last_status` (they are different fields — see step 3), whether a full rebuild
was needed, any collision named, and anything in step 3 that did not reconcile. If everything
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

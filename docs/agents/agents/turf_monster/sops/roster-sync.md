# Roster Sync

## Status: Active

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
cd /Users/alex/projects/mcritchie-studio
heroku run -a mcritchie-studio 'bin/rails runner "Nflverse::SeedPlayers.new(status_filter: %q(ACT), upload_headshots: false).call"'
```

`upload_headshots: false` is not optional here. The default is `true`, and that
path RAISES when `AWS_ACCESS_KEY_ID` is unset — which is the state on QA. It
also turns a data refresh into thousands of image fetches and S3 writes, which
is a separate job, not part of a roster sync.

**A feed outage is not a failure of this step.** If nflverse is down the import
reports `FEED UNAVAILABLE`, records a failed `ImportRun`, and exits 0 on
purpose. The data is simply stale. Check and move on:

```bash
heroku run -a mcritchie-studio 'bin/rails runner "r = ImportRun.last_success_for(%q(nflverse_players)); puts r ? r.finished_at : %q(never)"'
```

If that prints a timestamp from before today, the refresh did not land — retry
once, then report rather than proceeding into step 2 on stale data.

### Step 2 — sync the replica

```bash
cd /Users/alex/projects/turf-monster
heroku run -a turf-monster-mainnet 'bin/rails studio:sync_athletes'
```

That is the delta. It resumes from its stored watermark, so a run interrupted
halfway picks up where it stopped rather than restarting.

**Force a full rebuild only when you have a reason:**

```bash
heroku run -a turf-monster-mainnet 'bin/rails studio:sync_athletes FULL=1'
```

Reasons that qualify: the replica is empty, you have just restored a database,
the counts in step 3 disagree and you do not know why, or a namesake's slug
changed. "It feels stale" does not qualify — the watermark already knows.

### Step 3 — reconcile, and do not skip this

```bash
heroku run -a turf-monster-mainnet 'bin/rails studio:sync_status'
heroku run -a mcritchie-studio 'bin/rails runner "puts %Q{MS athletes=#{Athlete.count} missing_gsis=#{Athlete.where(gsis_id: [nil, %q()]).count}}"'
```

Read three things:

1. **The two counts are close.** They will not be identical — MS carries every
   person it knows and TM's replica carries athletes — but a gap of hundreds
   means a page was dropped or a run stopped early.
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
- Step 3's counts agree to within a sensible margin and `missing_gsis` is 0.
- Nothing needed a `FULL=1`.

## When to stop and escalate

- **`missing_gsis` is not 0** — the provider's import is broken. Do not sync a
  replica from it; report and stop.
- **The counts disagree by hundreds** — run `FULL=1` ONCE. If they still
  disagree, stop: something is dropping rows and a third run will not find it.
- **`last_status: skipped`** — `AGENT_API_SECRET` is missing on that app. It is
  the same shared secret both apps already hold; this is a config gap, not a
  data problem.
- **A namesake's slug changed unexpectedly** — two players sharing a name is
  normal (six groups in the 2026 feed) but a slug CHANGING is not, because
  other records point at it. Report which player.

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

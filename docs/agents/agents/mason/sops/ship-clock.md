# Ship Clock
<!-- registry: benchmark one easy task, prompt to production, from records -->

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

This is Mason's `ship-clock` SOP: the COO measures how fast Operations ships (it moved from Alex on 2026-10-28, with DevOps, by the accountability chart). Alex McRitchie hands an agent one easy task. The agent takes
it from his prompt to production and measures the speed with real numbers. The
clock starts at his prompt and stops when the production ship goes green. The
report splits that time into three parts:

- **Hands-on:** agents working, reviewing, and handing off.
- **Fixed wait:** CI on the final push, the release sweep's pre-QA work (from the
  sweep's start to the QA candidate's open: merge-forward, gem publish, lock
  bumps), the QA deploy, and the production deploy.
- **Rework:** every red CI round (from the round's start to the next push's CI),
  every failed QA or ship attempt (from its start to the retry's), and every
  refused pre-check. Each item carries its cause line where a record or a log
  shows one.

`bin/ship-clock` does the arithmetic from records, not memory. It reads the task's
stage stamps, the task and release gate runs (`/api/v1/gates/...`), the PR's CI
runs (`gh run list`), the merge time, and the red jobs' logs. Logic and posture:
`bin/lib/ship_clock.rb`.

## Preconditions

- **Alex McRitchie's prompt grants production.** It must say to take the task to production
  (for example "ship it" or "all the way to prod"). That sentence is the clearance
  the ship quotes. Without it, stop at `submitted` and report the partial clock; do
  not wait on the Approve button.
- **The task is small and startable.** It is one story with one repo, and nothing
  else is held in `reviewed` or on `release` that would ride along. If other work
  is already in the pipeline, report that the clock will include it, and let Alex McRitchie
  decide.

## Procedure

**1. Stamp T0. This is the first act, before any read, plan or `task begin`.**

```bash
/Users/alex/projects/.agents/bin/ship-clock start <slug>
```

`<slug>` is the slug `task begin` will derive from the title (the title,
lowercased and hyphenated). The task does not exist yet, so the stamp is held on
disk (`~/.ship-clock/<slug>.json`). If you stamped late, pass the prompt's time
with `--at <ISO>` and `--estimated`. `--at` takes only a full ISO 8601 timestamp
with a date and a zone (`2026-10-13T08:15:00-06:00`); anything vaguer is refused.

**2. Build.** Run [`building-sop`](../../../modules/building-sop.md): `task begin`,
build in the desk, then `submit-wait --launch`. Right after `task begin`, put the
held T0 on the board:

```bash
/Users/alex/projects/.agents/bin/ship-clock start <slug>   # moves the held stamp onto the task
```

**3. Review.** Run [`pr-review`](../../carl/sops/pr-review.md) on the task. The
builder never reviews its own PR.

**4–6. QA, production, archive.** Run the release lane as one command, with Alex
McRitchie's words from the prompt:

```bash
bin/release cycle --clearance "<Alex McRitchie's words>" --yes --wait-for-1password
```

It runs [`qa-release`](../../avi/sops/qa-release.md)'s `prepare` → QA verify →
[`production-deploy`](../../steffon/sops/production-deploy.md)'s `ship --mode
cleared` → prod verify → [`archive-shipped`](../../steffon/sops/archive-shipped.md)'s
`archive`, and a re-run resumes from the board
([`full-cycle`](full-cycle.md) has the detail). Its prepare is always bare, so
when Alex McRitchie scoped the release to this task, run the atoms by hand instead:
`bin/release prepare --task <slug> --yes`, then `bin/release ship --mode cleared
--clearance "<his words>" --yes`, then `bin/release archive --yes`.

Keep every log (`cycle-*.log`, or `ship-*.log` and `prepare-*.log` when you ran the
atoms) in the scratchpad. They are the only record of a refused pre-check, and the
report reads failure causes from them.

The archive runs after production and is not counted on the clock. If it hangs or
refuses, record that in the ledger note.

**7. Report and record.** From a hub desk, run:

```bash
/Users/alex/projects/.agents/bin/ship-clock record <slug> \
  --log <scratchpad>/ship-<slug>.log --log <scratchpad>/ship-rel-<slug>.log \
  --note "<anything the records cannot show>"
```

`record` prints the report and writes the run's row to
`docs/agents/ledgers/ship-clock.csv` in the mcritchie-studio tree you stand in;
outside one it refuses unless `--ledger PATH` names the file. A re-run replaces
that slug's row; it never adds a second one. Use `report` (read-only) to preview
the numbers, and `--json` for machine output. The ledger is version-controlled, so
the row lands through a task: fold it into the next hub task you build, or open a
`docs`-shape chore for it.

## Exit Seam

Report to Alex McRitchie in this order:

1. **One line:** the total, and the largest of the three parts.
2. **The stage table** that `ship-clock report` prints, with Denver times and the
   elapsed time from T0.
3. **The three-way split:** hands-on, wait and rework, each with its share of the
   total, then the rework items with their causes.
4. **The ledger row,** with where it will land: the task that carries it.

## Reading the numbers

- **T0 source.** The source is `stamped` when step 1 ran at the prompt, and
  `estimated` when it was backdated. It reads `task created_at` when nobody stamped
  T0, which undercounts the time before the desk was cut.
- **Production** is the finish of the green `g4_ship` gate run, the moment the
  production smoke passed. A release from before gate runs falls back to the
  task's shipped stamp.
- **Hand-off gaps count as hands-on.** Examples are the time between `submitted`
  and the reviewer's pickup, or between `reviewed` and the QA sweep's start. They
  are pipeline time, not wait, and the stage table shows each one.
- **The sweep's pre-QA work is wait.** Once `bin/release prepare` starts the sweep
  (the release's `assemble_release started` event, stamped as `release sweep
  started` in the stage table), the merge-forward, gem publish and lock bumps up
  to the QA candidate's open are the pipeline working, so they count as wait. The
  event is read from `GET /api/v1/gates/release/<rel>` (`meta.release_events`); a
  board without that read leaves the span hands-on, as before.
- **`SHIP_CLOCK_GH_TIMEOUT`** that is not a positive number of seconds falls back
  to the default 60, with a warning.
- **A refused pre-check** is counted only from `--log` files: `bin/submit`
  records nothing on the board when its 0/8 pre-check refuses.

## Related

- [`full-cycle`](../../mason/sops/full-cycle.md): review, QA and ship for whatever is queued.
- [`deploy-with-task`](../../avi/sops/deploy-with-task.md): a one-task expedite.
- `docs/agents/ledgers/ship-clock.csv`: one row per benchmark run. The first row is
  team-tier-nine-hundred (2026-10-13), with T0 estimated.

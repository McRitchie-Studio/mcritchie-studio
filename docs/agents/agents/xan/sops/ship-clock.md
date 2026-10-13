# Ship Clock
<!-- registry: benchmark one easy task, prompt to production, from records -->

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

This is Xan's `ship-clock` SOP. Alex hands an agent one easy task. The agent takes
it from his prompt to production and measures the speed with real numbers. The
clock starts at his prompt and stops when the production ship goes green. The
report splits that time into three parts:

- **Hands-on:** agents working, reviewing, and handing off.
- **Fixed wait:** CI on the final push, the QA deploy, and the production deploy.
- **Rework:** every red CI round (from the round's start to the next push's CI),
  every failed QA or ship attempt (from its start to the retry's), and every
  refused pre-check. Each item carries its cause line where a record or a log
  shows one.

`bin/ship-clock` does the arithmetic from records, not memory. It reads the task's
stage stamps, the task and release gate runs (`/api/v1/gates/...`), the PR's CI
runs (`gh run list`), the merge time, and the red jobs' logs. Logic and posture:
`bin/lib/ship_clock.rb`.

## Preconditions

- **Alex's prompt grants production.** It must say to take the task to production
  (for example "ship it" or "all the way to prod"). That sentence is the clearance
  the ship quotes. Without it, stop at `submitted` and report the partial clock; do
  not wait on the Approve button.
- **The task is small and startable.** It is one story with one repo, and nothing
  else is held in `reviewed` or on `release` that would ride along. If other work
  is already in the pipeline, report that the clock will include it, and let Alex
  decide.

## Procedure

**1. Stamp T0. This is the first act, before any read, plan or `task begin`.**

```bash
/Users/alex/projects/.agents/bin/ship-clock start <slug>
```

`<slug>` is the slug `task begin` will derive from the title (the title,
lowercased and hyphenated). The task does not exist yet, so the stamp is held on
disk (`~/.ship-clock/<slug>.json`). If you stamped late, pass the prompt's time
with `--at <ISO>` and `--estimated`.

**2. Build.** Run [`building-sop`](../../../modules/building-sop.md): `task begin`,
build in the desk, then `submit-wait --launch`. Right after `task begin`, put the
held T0 on the board:

```bash
/Users/alex/projects/.agents/bin/ship-clock start <slug>   # moves the held stamp onto the task
```

**3. Review.** Run [`pr-review`](../../carl/sops/pr-review.md) on the task. The
builder never reviews its own PR.

**4. QA.** Run [`qa-release`](../../avi/sops/qa-release.md): `bin/release prepare --yes`.

**5. Production.** Run [`production-deploy`](../../steffon/sops/production-deploy.md)
with Alex's words from the prompt:

```bash
bin/release ship --mode cleared --clearance "<Alex's words>" --yes
```

Keep every ship log (`ship-*.log`, `prepare-*.log`) in the scratchpad. They are
the only record of a refused pre-check, and the report reads failure causes from
them.

**6. Archive.** Run [`archive-shipped`](../../steffon/sops/archive-shipped.md):
`bin/release archive --yes`. The archive runs after production and is not counted
on the clock. If it hangs or refuses, record that in the ledger note.

**7. Report and record.** From a hub desk, run:

```bash
/Users/alex/projects/.agents/bin/ship-clock record <slug> \
  --log <scratchpad>/ship-<slug>.log --log <scratchpad>/ship-rel-<slug>.log \
  --note "<anything the records cannot show>"
```

`record` prints the report and writes the run's row to
`docs/agents/ledgers/ship-clock.csv` in the tree you stand in. A re-run replaces
that slug's row; it never adds a second one. Use `report` (read-only) to preview
the numbers, and `--json` for machine output. The ledger is version-controlled, so
the row lands through a task: fold it into the next hub task you build, or open a
`docs`-shape chore for it.

## Exit Seam

Report to Alex in this order:

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
  and the reviewer's pickup, or between `reviewed` and the QA sweep. They are
  pipeline time, not wait, and the stage table shows each one.
- **A refused pre-check** is counted only from `--log` files: `bin/submit`
  records nothing on the board when its 0/8 pre-check refuses.

## Related

- [`full-cycle`](full-cycle.md): review, QA and ship for whatever is queued.
- [`deploy-with-task`](../../avi/sops/deploy-with-task.md): a one-task expedite.
- `docs/agents/ledgers/ship-clock.csv`: one row per benchmark run. The first row is
  team-tier-nine-hundred (2026-10-13), with T0 estimated.

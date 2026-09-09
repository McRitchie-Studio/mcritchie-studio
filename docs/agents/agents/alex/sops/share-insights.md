# Share Insights

## Status: Active

This is Alex's `share-insights` SOP. It publishes Mr. McRitchie's confirmed
insights into the tracked agent docs.

## Scope

This SOP is part of Alex's learning loop. It does not review PRs, merge release
work, deploy QA, ship production, or archive work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

**The generator reads whatever database your shell points it at, and every local
one is EMPTY.** `bin/rails insights:doc` has no `--local` flag and no board
default — a primary checkout reads `mcritchie_studio_development` and a desk
worktree reads its own seeded DB, so running it bare writes a confident
`0 banked insights` over a doc that was right. That is not a near miss: it is how
the tracked doc sat at zero from 2026-07-03 while the bank held five
(`/tasks/insights-doc-never-regenerated`). Point it at the board explicitly, per
the Procedure below.

## Preconditions

At least one insight has been confirmed by Mr. McRitchie (`grader: "mcr"`). If
none are confirmed, report "nothing to share" and stop.

## Procedure

Regenerate the tracked lessons doc from confirmed insights, **against the board's
database**. The URL never reaches the terminal or a file:

```bash
BOARD_DB_URL="$(heroku config --json --app mcritchie-studio \
  | ruby -rjson -e 'print JSON.parse($stdin.read).fetch("DATABASE_URL", "")')"
[ -n "$BOARD_DB_URL" ] || { echo "no DATABASE_URL — check heroku auth"; exit 1; }

DATABASE_URL="$BOARD_DB_URL" bin/rails insights:doc
```

The task prints three things: the count it wrote, the path
[`../../../shared/insights.md`](../../../shared/insights.md), and **the database
it read the bank from**. Read that third line — it is the only one that
distinguishes a genuinely empty bank from a generation against the wrong
database, and the count alone cannot.

Then **verify the count against the bank independently**, from the board itself,
so a doc is never committed on the generator's own say-so:

```bash
heroku run --app mcritchie-studio --no-tty -- \
  bin/rails runner 'puts Insights::DocGenerator.banked_insights.size'
```

That number must equal the count in the regenerated header. (`heroku run` output
can arrive empty even when the command ran; this read is read-only, so just run
it again rather than treating silence as zero.)

If the generated doc changed, include it in the branch or follow-up handoff that
owns the docs update — it is a tracked file and rides a branch like any other doc
change.

## When this SOP is not run

The doc does not need a person to notice it has gone stale.
`InsightsDocFreshnessJob` runs weekly on the board — the one place holding both
the live bank and the deployed copy of the doc — and writes an **ErrorLog**
receipt when the doc's recorded count no longer matches the bank, when the bank
has been curated since the doc was generated, or when the generated header stops
being machine-readable. A stale artefact is therefore a row in
`/admin/error_logs`, not silence. See
[`../../../system/memory.md`](../../../system/memory.md).

**This SOP installs nothing, and owes no install step.** Two facts hold it there,
and both were verified at source:

- **A session does not read this file.** The feed-forward path is the board:
  `bin/session-insights` GETs `/api/v1/insights` from a SessionStart hook, so a
  fresh agent hatches with the banked insights the moment they are banked. The
  tracked doc is the readable record, not the delivery mechanism.
- **The installer never carried this doc anyway.** It publishes the two entry
  docs and the user-global skills — never `shared/insights.md` — and that
  publish is an owned pipeline step of every production ship, never a hand-run.
  See [`docs-maintenance.md`](../../../modules/docs-maintenance.md) § Editing The
  Entry Docs.

Do not add an install step back. It would distribute nothing this SOP produces,
and would push whatever tree you are standing in to every session on the machine.

## Exit Seam

The tracked lessons doc reflects every confirmed insight. Report the changed doc
path and the banked-insight count `insights:doc` printed.

## Related

- [`grade-events.md`](grade-events.md) - grades resolved activities into the learning
  layer.

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

Use the production board by default. Do not add `--local`.

## Preconditions

At least one insight has been confirmed by Mr. McRitchie (`grader: "mcr"`). If
none are confirmed, report "nothing to share" and stop.

## Procedure

Regenerate the tracked lessons doc from confirmed insights:

```bash
bin/rails insights:doc
```

That is the whole act. It prints the banked-insight count and the path it wrote,
[`../../../shared/insights.md`](../../../shared/insights.md). If the generated
doc changed, include it in the branch or follow-up handoff that owns the docs
update — it is a tracked file and rides a branch like any other doc change.

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

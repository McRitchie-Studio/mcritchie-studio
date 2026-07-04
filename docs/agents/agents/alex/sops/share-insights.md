# Share Insights

## Status: Active

This is Alex's `share-insights` SOP. It publishes Mr. McRitchie's confirmed
insights into the tracked agent docs and installs them for future sessions.

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

Distribute the generated docs to the installed agent runtimes:

```bash
bin/install-agent-docs
```

If the generated doc changes, include it in the branch or follow-up handoff that
owns the docs update.

## Exit Seam

Confirmed insights are present in the tracked lessons doc and installed for the
next agent sessions. Report the changed doc path and install result.

## Related

- [`grade-events.md`](grade-events.md) - grades resolved spans into the learning
  layer.

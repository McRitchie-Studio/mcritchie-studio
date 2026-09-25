# Xan Heartbeat

## Status: Active

This is Xan's heartbeat launcher. It sets Xan's session attribution and routes
to two independent act SOPs:

- [`share-insights`](sops/share-insights.md) - publish the banked insight bank to
  agent docs.
- [`full-cycle`](sops/full-cycle.md) - run review, QA deploy, and production
  deploy with explicit ship authority.

Grading is no longer a heartbeat act. Every task is graded once when it ships
(`Insights::TaskGrader`, thresholds in `config/learning_loop.yml`), and a
learning is written only when a threshold trips. [`grade-events`](sops/grade-events.md)
stays as an optional manual act: run it only when Mr. McRitchie asks for it by name.

Use this file when Mr. McRitchie invokes `Xan Heartbeat`. When he invokes a
single Xan act directly, read that act's SOP file.

## Scope

Xan owns the learning loop and, when explicitly launched with ship authority,
the full release pipeline:

- Read the ship-time grades (`bin/rails learning_loop:backfill` prints the recent
  ones in dry run) and, on request, grade trajectory activities by hand.
- Share the Insight Bank — every banked grade, whichever grader recorded it — into
  the generated lessons doc.
- Run `full-cycle` only when the operator launched that autonomous release act or
  otherwise granted production ship authority in this session.

Do not treat `Xan Heartbeat` as implied production approval unless the invoked
act is `full-cycle` or Mr. McRitchie grants that authority in-session.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat xan
```

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The heartbeat command makes activities self-attribute to Xan unless a delegated
reviewer explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP files below are standalone procedures and do
not run `bin/agent-activity heartbeat xan` themselves.

## Act SOPs

Run Xan's acts in the launched scope:

1. [`share-insights`](sops/share-insights.md) - publish the banked insights.
2. [`full-cycle`](sops/full-cycle.md) - run review -> QA -> production with
   explicit ship authority.

When Mr. McRitchie launches `Xan Heartbeat`, run `share-insights` first. Run
`full-cycle` only when the launched act or prompt explicitly includes it, or when
Mr. McRitchie grants production ship authority in the same session. Run
`grade-events` only when he names it.

## Handoff

End every Xan heartbeat with a short report:

- any banked insight slugs (and grading counts, if `grade-events` ran)
- insight doc regeneration and install result
- whether `full-cycle` was skipped, no-op, blocked, or shipped
- any production ship authority granted in-session
- any task blocked during review or ejected during QA

On a clean learning-only run, omit release sections that did not run.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, and each act stands
alone. These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`../../system/devops-cycle-design.md`](../../system/devops-cycle-design.md)
  §1.4 - release atom model and pipeline ownership (architecture).

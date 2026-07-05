# Alex Heartbeat

## Status: Active

This is Alex's heartbeat launcher. It sets Alex's session attribution and routes
to three independent act SOPs:

- [`grade-events`](sops/grade-events.md) - grade recent resolved activities into the
  learning layer.
- [`share-insights`](sops/share-insights.md) - publish Mr. McRitchie's confirmed
  insights to agent docs.
- [`full-cycle`](sops/full-cycle.md) - run review, QA deploy, and production
  deploy with explicit ship authority.

Use this file when Mr. McRitchie invokes `Alex Heartbeat`. When he invokes a
single Alex act directly, read that act's SOP file.

## Scope

Alex owns the learning loop and, when explicitly launched with ship authority,
the full release pipeline:

- Grade recent trajectory activities so useful agent behavior becomes reusable memory.
- Share Mr. McRitchie's confirmed insights into the generated lessons doc and
  installed agent docs.
- Run `full-cycle` only when the operator launched that autonomous release act or
  otherwise granted production ship authority in this session.

Do not treat `Alex Heartbeat` as implied production approval unless the invoked
act is `full-cycle` or Mr. McRitchie grants that authority in-session.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat alex
```

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The heartbeat command makes activities self-attribute to Alex unless a delegated
reviewer explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP files below are standalone procedures and do
not run `bin/agent-activity heartbeat alex` themselves.

## Act SOPs

Run Alex's acts in the launched scope:

1. [`grade-events`](sops/grade-events.md) - grade recent resolved activities.
2. [`share-insights`](sops/share-insights.md) - publish Mr. McRitchie's confirmed
   insights.
3. [`full-cycle`](sops/full-cycle.md) - run review -> QA -> production with
   explicit ship authority.

When Mr. McRitchie launches `Alex Heartbeat`, run the learning acts first:
`grade-events`, then `share-insights`. Run `full-cycle` only when the launched
act or prompt explicitly includes it, or when Mr. McRitchie grants production
ship authority in the same session.

## Handoff

End every Alex heartbeat with a short report:

- grading counts and any banked insight slugs
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

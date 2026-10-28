# Alex Heartbeat

## Status: Active

This is Alex's heartbeat launcher: the Sales/Marketing acts, client-facing and
demand-side. It sets Alex's session attribution and routes to independent act SOPs:

- **Client threads** — answer the client and `/build` threads waiting on Alex, by
  [`agent-communication`](../../modules/agent-communication.md) and, on a `/build`
  thread, [`intake.md`](intake.md).
- [`launch-build-queue`](sops/launch-build-queue.md) - take the `/build` app
  requests and launch their builders: claim the request, hand it to a Pokémon
  builder, point the subdomain, mark it live.
- [`launch-warmup`](sops/launch-warmup.md) — read the gate of any launch mid-ramp:
  a new app, domain or email list reaching the public in gated batches.
- [`constraint-diagnosis`](sops/constraint-diagnosis.md) — find the one thing
  limiting demand for a client, and prescribe one move against it.
- [`content-sprint`](sops/content-sprint.md) — the weekly loop: score last
  week's prediction, name one test, ship it at volume, read the result.

The three demand acts came from Rex, who folded into Alex on 2026-10-28; `Rex
Heartbeat` is retired, and those acts run here. Alex builds nothing himself:
delivery is Operations' (Mason, the COO), and the Pokémon legion and Steffon build
and ship what Alex brings in. Anything a prescription needs in code (a tracking
link, a landing page, an analytics read-back) is a task on the board, built by a
Pokémon through the DevOps cycle.

Three more of Alex's SOPs run only when Alex McRitchie names them:

- [`focus-session`](sops/focus-session.md) - hold an epic with Alex McRitchie.
- [`brand-kit-rollout`](sops/brand-kit-rollout.md) - apply a saved brand kit to one or more apps.
- [`marketing-kit`](sops/marketing-kit.md) - build a brand's marketing kit in Drive: guidelines PDF,
  doc and slide templates, tracker, from one spec (`bin/marketing-kit`).

The Operations acts (`share-insights`, `grade-events`, `full-cycle`, `clean-up`,
`dream-swap`, and `ship-clock`, which moved from Alex on 2026-10-28) are Mason's, the
COO's: [`../mason/HEARTBEAT.md`](../mason/HEARTBEAT.md).

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat alex
```

Alex is in the Worker class, so the heartbeat posts no admin login request.

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The act SOPs above are standalone procedures and do not run the heartbeat command
themselves.

## Order

When Alex McRitchie launches `Alex Heartbeat`: client threads first (a person is waiting),
then the `/build` queue, then the demand acts in this order:

1. **Any launch mid-ramp gets its gate read first** (`launch-warmup`). A batch
   waiting on an unread gate is a ramp that has stalled or is advancing blind.
2. **Any client with no named constraint gets a diagnosis** (`constraint-diagnosis`).
   A sprint without a constraint is posting.
3. **Any client with an unread prediction from last sprint gets scored.** An
   unscored prediction means last week's spend taught us nothing.
4. Only then, a new sprint (`content-sprint`).

Before a demand act, read the client's dossier in [`clients/`](clients/) and check
its "Last reviewed" date; over a month old, re-ask its numbers rather than
re-assert them. Read only the [`knowledge/`](knowledge/README.md) cards the question
needs. No marketing advice without numbers: if the numbers do not exist, that IS the
finding, and the prescription is instrumentation, not content.

Run `focus-session` only when Alex McRitchie names it.

## Handoff

End every Alex heartbeat with a short report:

- threads answered, and anything promised to a client
- `/build` requests claimed, handed to a builder or marked live, with task slugs
- per client: the constraint named, the move prescribed (volume and date), and
  last sprint's prediction scored against its result
- anything waiting on Alex McRitchie (a clearance, a product call)

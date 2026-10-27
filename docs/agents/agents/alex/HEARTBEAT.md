# Alex Heartbeat

## Status: Active

This is Alex's heartbeat launcher: the client-facing acts. It sets Alex's session
attribution and routes to independent act SOPs:

- **Client threads** — answer the client and `/build` threads waiting on Alex, by
  [`agent-communication`](../../modules/agent-communication.md) and, on a `/build`
  thread, [`intake.md`](intake.md).
- [`launch-build-queue`](sops/launch-build-queue.md) - work the `/build` app
  requests: claim, build, point the subdomain, mark live.
- **His builds** — resume any task Alex is building
  (`bin/task list --agent alex --stage building`) by the
  [`building-sop`](../../modules/building-sop.md).

Four more of Alex's SOPs run only when Alex McRitchie names them:

- [`focus-session`](sops/focus-session.md) - hold an epic with Alex McRitchie.
- [`ship-clock`](sops/ship-clock.md) - benchmark one easy task from Alex McRitchie's first
  message to production. Its production step needs Alex McRitchie's clearance in his own words.
- [`brand-kit-rollout`](sops/brand-kit-rollout.md) - apply a saved brand kit to one or more apps.
- [`marketing-kit`](sops/marketing-kit.md) - build a brand's marketing kit in Drive: guidelines PDF,
  doc and slide templates, tracker, from one spec (`bin/marketing-kit`).

The CEO acts (`share-insights`, `grade-events`, `full-cycle`, `clean-up`,
`dream-swap`) are Mason's: [`../mason/HEARTBEAT.md`](../mason/HEARTBEAT.md).

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat alex
```

Alex is in the Worker class, so the heartbeat posts no admin login request: a
build takes its studio login from its task claim, as any builder's does.

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The act SOPs above are standalone procedures and do not run the heartbeat command
themselves.

## Order

When Alex McRitchie launches `Alex Heartbeat`: client threads first (a person is waiting),
then the `/build` queue, then his own builds. Run `focus-session` or `ship-clock`
only when Alex McRitchie names it.

## Handoff

End every Alex heartbeat with a short report:

- threads answered, and anything promised to a client
- `/build` requests claimed, built or marked live, with task slugs
- builds advanced, with task slugs and PR URLs
- anything waiting on Alex McRitchie (a clearance, a product call)

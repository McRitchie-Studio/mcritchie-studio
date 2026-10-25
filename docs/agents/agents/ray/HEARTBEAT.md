# Ray Heartbeat

## Status: Active

This is Ritch's heartbeat launcher: the client-facing acts. It sets Ritch's session
attribution and routes to independent act SOPs:

- **Client threads** — answer the client and `/build` threads waiting on Ritch, by
  [`agent-communication`](../../modules/agent-communication.md) and, on a `/build`
  thread, [`intake.md`](intake.md).
- [`launch-build-queue`](sops/launch-build-queue.md) - work the `/build` app
  requests: claim, build, point the subdomain, mark live.
- **His builds** — resume any task Ritch is building
  (`bin/task list --agent ray --stage building`) by the
  [`building-sop`](../../modules/building-sop.md).

Two more of Ritch's SOPs run only when Alex names them:

- [`focus-session`](sops/focus-session.md) - hold an epic with Alex.
- [`ship-clock`](sops/ship-clock.md) - benchmark one easy task from Alex's first
  message to production. Its production step needs Alex's clearance in his own words.

The CEO acts (`share-insights`, `grade-events`, `full-cycle`, `clean-up`,
`dream-swap`) are Mason's: [`../mason/HEARTBEAT.md`](../mason/HEARTBEAT.md).

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat ray
```

Ritch is in the Worker class, so the heartbeat posts no admin login request: a
build takes its studio login from its task claim, as any builder's does.

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The act SOPs above are standalone procedures and do not run the heartbeat command
themselves.

## Order

When Alex launches `Ray Heartbeat`: client threads first (a person is waiting),
then the `/build` queue, then his own builds. Run `focus-session` or `ship-clock`
only when Alex names it.

## Handoff

End every Ray heartbeat with a short report:

- threads answered, and anything promised to a client
- `/build` requests claimed, built or marked live, with task slugs
- builds advanced, with task slugs and PR URLs
- anything waiting on Alex (a clearance, a product call)

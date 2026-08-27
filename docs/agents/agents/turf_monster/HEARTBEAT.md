# Turf Monster Heartbeat

## Status: Active

This is Turf Monster's heartbeat launcher. It sets Turf Monster's session
attribution and routes to one act SOP:

- [`live-score-watch`](sops/live-score-watch.md) - watch a live NFL slot: poll
  ESPN on a cadence, record scoring plays, propagate contest scores, report each
  change as it lands.

Use this file when Mr. McRitchie invokes `Turf Monster Heartbeat`. When he
invokes the act directly, read that act's SOP file.

**One act, and that is the point.** The watch occupies the session for the length
of a game window — up to twelve hours. Under a soul that owns several acts, a
heartbeat that opened the watch would never reach the rest of them, which is why
the act sat direct-invoke-only under Avi and stayed off the launcher card. Here
there is nothing behind it to starve: `Turf Monster Heartbeat` and
`live-score-watch` launch the same work, and both belong on the card.

## Scope

Turf Monster is the sports-domain soul. This heartbeat covers the live scoring
watch and nothing else:

- Watch a live NFL slot end to end and record what the feed reports.
- Judge the anomalies the cycle raises, and escalate the ones that need a human.
- Stop at the end of the window, or when the slot is final.

This heartbeat holds **no release lane**. It never reviews a PR, never merges,
never promotes `accepted → release`, and never deploys. Review is Carl's, the
sweep is Avi's, the ship is Steffon's. It also never settles or grades a contest
— it records scores, and settlement is its own act with its own gates.

## Entry

Run from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity heartbeat turf-monster
```

Then keep normal trajectory activities open with `bin/agent-activity start|next|end`.
The heartbeat command makes activities self-attribute to Turf Monster unless a
delegated agent explicitly passes its own `--agent`.

Use the production board by default. Do not add `--local`.

Keep attribution here. The act SOP file below is a standalone procedure and does
not run `bin/agent-activity heartbeat turf-monster` itself.

## Act SOPs

1. [`live-score-watch`](sops/live-score-watch.md) - watch the slot, record the
   scoring plays, report each change.

The act owns its own preconditions, and they are the reason this heartbeat is a
safe no-op on a quiet day: it proves the poller is DEPLOYED, proves which stack
it is pointed at, and checks there is a slot worth watching at all. Any one of
those failing ends the run with a report and no writes.

## Handoff

End every Turf Monster heartbeat with a short report:

- **which environment the totals describe** — a rehearsal's numbers and a
  production watch's numbers read identically otherwise
- games watched and scoring events recorded, or "nothing to watch"
- contests re-scored
- anomalies by kind, and any escalated verbatim

On a clean run with no anomalies, omit the anomaly section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOP above, which stands alone.
These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`role.md`](role.md) - what Turf Monster owns.
- [`soul.md`](soul.md) - how Turf Monster works and where it pushes back.

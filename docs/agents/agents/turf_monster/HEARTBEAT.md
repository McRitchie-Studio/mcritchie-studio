# Turf Monster Heartbeat

## Status: Active

This is Turf Monster's heartbeat launcher. It sets Turf Monster's session
attribution and routes to its act SOPs:

- [`live-score-watch`](sops/live-score-watch.md) - watch a live NFL slot: poll
  ESPN on a cadence, record scoring plays, propagate contest scores, report each
  change as it lands.
- [`contest-rehearsal`](sops/contest-rehearsal.md) - run a whole contest
  lifecycle on QA devnet end to end: create, enter, replay a played week, settle
  on-chain, close.
- [`sleeper-auction-watch`](sops/sleeper-auction-watch.md) - sit beside Mr.
  McRitchie through a live Sleeper auction draft: value every player under the
  league's own scoring, then call a max bid as each one comes up.
- [`entry-forfeit`](sops/entry-forfeit.md) - withdraw one entrant from one
  contest at their own request, forfeiting the entry fee: one status flip before
  grading, plus the on-chain seat gap it leaves behind.

Use this file when Mr. McRitchie invokes `Turf Monster Heartbeat`. When he
invokes a single act directly, read that act's SOP file.

`entry-forfeit` is deliberately NOT a chip, and for a third reason again: it is
an on-demand incident SOP. Nothing schedules it and nothing should — it runs when
an entrant asks to withdraw, and never otherwise. It stays a registered
invocation by name, owned here and in the prose guard's `ACT_OWNER`. Written down
so this stays a decision rather than an oversight.

**The heartbeat itself composes only `live-score-watch`.**
[`contest-rehearsal`](sops/contest-rehearsal.md) and
[`sleeper-auction-watch`](sops/sleeper-auction-watch.md) are direct-invocation
only, which is why the heartbeat composition runs one act while the launcher card
carries two. Direct-invocation is a fact about the COMPOSITION, not about card
membership: `contest-rehearsal` is direct-invocation only and is a chip, so being
direct-invoke has never been what keeps an act off the card.

The auction watch is deliberately NOT a chip, and two separate reasons hold it
there. The product reason is this file's and it is settled: the watch is
calendar-bound, useful on one evening a year with Mr. McRitchie in the chair, so
nothing should schedule it. The card's reason is its own and it is measured: at
21 characters the slug needs 114px against a 99px chip text area, so it clips
(2026-09-09, held by `test/system/workflows_card_chip_fit_test.rb`). It is not
"the same carve-out `archive-shipped` has" — that act is off the card because
`production-deploy` already runs it, which is the opposite reason. Each act
occupies the session for a long stretch — the watch for the length of a game
window, up to twelve hours; the rehearsal for a full contest cycle — so a
heartbeat that opened more than one would never reach the rest. That is the same
reason the watch sat direct-invoke-only under Avi
before this soul had a heartbeat of its own.

## Scope

Turf Monster is the sports-domain soul. This heartbeat covers the acts that
ask for a sports-domain judgement:

- Watch a live NFL slot end to end and record what the feed reports.
- Judge the anomalies the cycle raises, and escalate the ones that need a human.
- Stop at the end of the window, or when the slot is final.
- Or rehearse a whole contest on QA — create, enter, replay, settle, close —
  and judge whether the board moved the way the games did.
- Or price a Sleeper auction draft live and call the bids, judging scarcity and
  roster feasibility against a model built from the league's own scoring.

It ships nothing and holds **no release lane**. `contest-rehearsal` writes only
to `turf-monster-qa` and the devnet program; `live-score-watch` writes `Goal`
rows; `sleeper-auction-watch` writes nothing at all — it reads a public API and
advises, and Mr. McRitchie clicks every button. None of them promotes, deploys,
or settles a production contest, and this heartbeat never reviews a PR, never
merges, and never promotes
`accepted → release`. Review is Carl's, the sweep is Avi's, the ship is
Steffon's.

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

Keep attribution here. Both act SOP files below are standalone procedures, and
neither runs `bin/agent-activity heartbeat turf-monster` itself.

## Act SOPs

Run Turf Monster's heartbeat as a live-slot watch:

1. [`live-score-watch`](sops/live-score-watch.md) - watch the slot, record the
   scoring plays, report each change.

When Mr. McRitchie launches `Turf Monster Heartbeat`, run `live-score-watch`
until the window closes or the slot is final. When an act is invoked directly,
run only that act.

[`contest-rehearsal`](sops/contest-rehearsal.md) runs only when invoked directly
- it takes the session for a whole contest cycle, and is never part of the
heartbeat composition.

**Each act owns its own preconditions**, which is why this heartbeat is a safe
no-op on a quiet day. `live-score-watch` proves the poller is DEPLOYED, proves
which stack it is pointed at, and checks there is a slot worth watching at all
(`sops/live-score-watch.md` §Preconditions). `contest-rehearsal` runs
`NetworkGuard` before it loads a single key, refusing any app but
`turf-monster-qa` and any program but the pinned devnet one. A precondition
failing ends the run with a report and no writes.

## Handoff

End every Turf Monster heartbeat with a short report:

- **which environment the totals describe** — a `contest-rehearsal` run's
  numbers and a production watch's numbers read identically otherwise
- games watched and scoring events recorded, or "nothing to watch"
- contests re-scored
- anomalies by kind, and any escalated verbatim

On a clean run with no anomalies, omit the anomaly section entirely.

## Background — not needed to execute

This heartbeat is a recipe: it routes to the act SOPs above, each of which
stands alone.
These references are context only.

- [`../../modules/heartbeats.md`](../../modules/heartbeats.md) - cross-soul
  heartbeat map.
- [`role.md`](role.md) - what Turf Monster owns.
- [`soul.md`](soul.md) - how Turf Monster works and where it pushes back.

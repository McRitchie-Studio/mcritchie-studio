# Live Score Watch

## Status: Active

This is Avi's `live-score-watch` SOP. It runs a semi-live NFL scoring watch: for
the length of a game window, it polls ESPN on a fixed cadence, records each
scoring play, propagates the new score into Turf Monster contest standings, and
reports every change in the terminal as it happens.

It is Avi's because its failure modes are product-integrity failures. A missed
touchdown or a mis-attributed team does not read as an outage — it reads as a
contest that settled on the wrong number.

## The split — read this before running anything

**The agent decides nothing about scoring.** Every rule about what a play is
worth, which game it belongs to, which contests re-score, and when a game is
final lives in `Nfl::LiveScores::PollCycle` in turf-monster: in code, under
test, and identical on every run.

| Deterministic — the code | Agentic — you |
|---|---|
| Calling ESPN, parsing the payload | Choosing the slot and the window |
| Deriving points from the running score | Setting and holding the cadence |
| Matching teams, writing `Goal` rows | Reading out what changed |
| Re-scoring contests, broadcasting | Judging whether an anomaly needs a human |
| Deciding a game is final | Deciding to stop early |

If you ever find yourself reasoning about **what a touchdown is worth**, stop.
That is the code's job and the code already knows. Your judgment is spent on the
anomalies, and on when to escalate.

**Why the cycle is safe to call repeatedly.** Every scoring event is keyed on
ESPN's own play id under a unique index, so a second identical cycle writes
nothing. A cycle that dies halfway leaves no torn state. That is what makes an
in-session watch viable: if the session drops, you resume by starting again, and
nothing is double-counted or lost.

## Scope

This SOP watches and records. It does not review PRs, merge, deploy, settle
contests, or pay anyone out. It writes `Goal` rows and the scores derived from
them; grading and settlement remain their own acts.

## Entry

Run from the Turf Monster primary checkout, against the environment you intend
to watch:

```bash
cd /Users/alex/projects/turf-monster
```

## Preconditions

- `bin/nfl-live-poll` exists in this checkout.
- There is a slot worth watching. Confirm before committing to a window:

```bash
bin/nfl-live-poll --json | ruby -rjson -e 'd=JSON.parse(STDIN.read); puts "slot=#{d["slot"]} games=#{d["games_seen"]}"'
```

If `games_seen` is 0, there is nothing to watch. Report that and stop.

## The cadence, and why it is not 1,440 tool calls

The watch is a 30-second cadence over a window up to twelve hours. Taken
literally that is 1,440 invocations, which no session survives — the context is
gone long before the games are.

So the agent drives the cadence in **bounded batches**: one command per batch,
each batch a fixed number of 30-second cycles that prints ONLY the cycles where
something changed. You stay in the loop — you read every batch, you decide
whether to continue — but a quiet ten minutes costs one line instead of twenty.

**One batch — ten minutes, twenty cycles:**

```bash
for i in $(seq 1 20); do bin/nfl-live-poll --quiet; sleep 30; done
```

`--quiet` is what makes this readable: it prints nothing when nothing changed,
so a batch over a quiet stretch returns empty and a batch containing a
touchdown returns the touchdown.

Repeat the batch until the window closes. Roughly 72 batches covers twelve
hours.

**If your harness refuses a foreground `sleep`** (several do), run the batch in
the background and read its log each turn instead:

```bash
mkdir -p log
nohup sh -c 'while true; do bin/nfl-live-poll --quiet; sleep 30; done' \
  > log/nfl-live-watch.log 2>&1 &
```

Then each turn: `tail -n 40 log/nfl-live-watch.log`. Stop it with
`pkill -f nfl-live-poll` when the window closes. This is still the agent's loop
— no queue, no scheduler, and it dies with the machine you started it on.

## What a cycle prints

```
21:04:32  PIT  touchdown   +7   PIT 7-0 BUF   Q1 8:42   (3 contests)
21:11:07  BUF  field_goal  +3   PIT 7-3 BUF   Q1 2:20   (3 contests)
21:44:19  PIT  touchdown   REVERSED  PIT 7-3 BUF
22:58:40                        PIT 24-17 BUF   FINAL
```

Read `(3 contests)` literally: that many open contests re-scored off that play.

## Reporting

Relay changes as they land. Do not batch a whole quarter into one summary — the
point of a live watch is that it is live. Each report carries:

- the scoring play, its team, and what it was worth
- the new score and the game clock
- how many contests re-scored
- any anomaly, verbatim

At the end of the window, report totals: games watched, scoring events recorded,
contests re-scored, anomalies by kind.

## Anomalies — the part that needs judgment

The cycle reports three kinds and never stops for any of them. Deciding which
deserves a human is your job.

| Kind | What it means | What to do |
|---|---|---|
| `fetch_failed` | One game's detail did not arrive | Ignore once. Twice on the same game in consecutive batches: report it. |
| `unknown_team` | An abbreviation resolved to no team | **Escalate immediately.** A team that cannot be matched is a team that silently never scores. |
| `score_drift` | Our summed events disagree with ESPN's total | Ignore a single drifting cycle mid-play — the feed updates a total before its play list. Persisting across three batches means a play was missed: escalate with the game slug and both scores. |

`unknown_team` is the one that never waits. Every other anomaly degrades the
board; that one silently under-scores a contest.

**A drift that only appears in a non-production environment is usually yours.**
Scores injected by the `/live` dev toolbar carry no ESPN play id, so the cycle
leaves them alone and correctly reports the resulting disagreement. Clear the
game before reading drift as a real defect.

## Stopping

Stop when any of these is true, and say which:

- every game in the slot reads `FINAL`
- the twelve-hour window has elapsed
- `unknown_team` appeared and has not been resolved
- Mr. McRitchie says stop

Then report the totals above.

## Resuming

If the session drops, or you are asked to pick a watch back up, just start
again. Re-run the preconditions and resume the batches. The cycle is idempotent,
so everything already recorded stays recorded and nothing is written twice —
there is no reconciliation step and no state file to repair.

## What this SOP must never do

- **Never hand-write a score.** If the feed is wrong, escalate; do not correct
  the board by hand. A hand-written score has no play id, so the next cycle
  reports it as drift forever.
- **Never widen the cadence to "catch up".** Polling faster does not recover a
  missed play; re-running a cycle does, because it re-reads the full play list.
- **Never settle or grade a contest.** This act records scores. Settlement is a
  separate act with its own gates.
- **Never run the dev score injectors against production.** They are undrawn
  outside local environments, and reaching for them is a sign you are on the
  wrong stack.

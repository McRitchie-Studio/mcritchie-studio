# Live Score Watch

## Status: Active

This is Turf Monster's `live-score-watch` SOP. It runs a semi-live NFL scoring
watch: for the length of a game window, it polls ESPN on a fixed cadence, records
each scoring play, propagates the new score into Turf Monster contest standings,
and reports every change in the terminal as it happens.

It is Turf Monster's because every judgment it asks for is a sports-domain
judgment. Which slot is worth watching, whether an abbreviation resolved to the
right franchise, whether a drifting total means a missed play or a feed updating
out of order — those are read against knowing the sport, not against knowing the
pipeline. And its failure mode is a domain failure: a missed touchdown or a
mis-attributed team does not read as an outage, it reads as a contest that
settled on the wrong number.

**The watch holds no release lane.** It reads a feed and writes `Goal` rows; it
never touches `release`, never promotes, and never deploys. It takes no assembler
claim and no deployer claim, so a `qa-release` sweep or a `production-deploy` can
run alongside a watch in flight — the twelve hours cost you a session, not a
lane.

## The split — read this before running anything

**You decide nothing about scoring.** Every rule about what a play is
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
anomalies, on the target, and on when to escalate.

**Why the cycle is safe to call repeatedly.** Every scoring event is keyed on
ESPN's own play id under a unique partial index, so a second identical cycle
writes nothing, and a cycle that dies halfway leaves no torn state. That is what
makes an in-session watch viable: if the session drops, you resume by starting
again.

**What "safe" does and does not cover.** Re-running reconciles against the feed's
CURRENT answer, so it recovers a play we missed — and it used to mean the
opposite too. A degraded response (HTTP 200, valid JSON, no `scoringPlays` key)
once reconciled a game down to nothing: goals 3 to 0, score 10-7 to 0-0, with no
anomaly, because a blank scoreboard score also read as 0 and the drift check
compared two zeros and agreed. The cycle now refuses to sweep to nothing,
refuses to settle a game it cannot reconcile, and reports `degraded_feed`
instead. So re-running is safe — but "safe" now means it declines to act on an
answer it does not trust, not that every re-run makes progress.

## Scope

This SOP watches and records. It does not review PRs, merge, deploy, settle
contests, or pay anyone out. It writes `Goal` rows and the scores derived from
them; grading and settlement remain their own acts.

## Entry — WHICH environment, stated in the command

**Production by default. A local run is a REHEARSAL and must be called one.**

This act writes `Goal` rows, and those rows settle contests people paid to
enter. There is no scheduled job behind it — `bin/nfl-live-poll` is the only
non-test caller of `Nfl::LiveScores::PollCycle`, and `config/schedule.yml` has
no NFL entry — so an agent running this SOP is the **sole path by which
production contests re-score.** Getting the target wrong is not a slow day; it
is a Sunday of contests that never move.

Watching the real slate, which is what `live-score-watch` means unless Mr.
McRitchie says otherwise:

```bash
cd /Users/alex/projects/turf-monster
heroku run -a turf-monster-mainnet bin/nfl-live-poll
```

`turf-monster-mainnet` is the APP; `turf-monster` is the repo and the directory,
and there is no Heroku app by that name — an earlier draft of this SOP used it
in all six commands and every one of them would have failed. Confirm against
`bin/deploy:80` (`HEROKU_APP="turf-monster-mainnet"`) rather than against
memory, and note that `turf-monster-qa` DOES exist, so a wrong guess lands
somewhere real.

Naming the app in the command is the safeguard: the target cannot drift from
what you believe you are watching. Mirrors
[`deploy-with-task`](../../avi/sops/deploy-with-task.md)'s standing rule — use production by
default, and make any other target explicit.

**Rehearsing locally** is legitimate — before a real slate, or against preseason.
It is a different command and it earns a different report:

```bash
cd /Users/alex/projects/turf-monster
bin/nfl-live-poll                     # LOCAL — writes to the dev database only
```

A local watch **must** be labelled REHEARSAL in every report it produces. Its
"(3 contests) re-scored" lines describe your dev database and nothing else.

## Preconditions

**1. The command is DEPLOYED — merged is not deployed.** As of 2026-08-26,
`bin/nfl-live-poll` and `Nfl::LiveScores::PollCycle` are on turf-monster
`accepted` (PR #426) and on NEITHER `release` NOR `main` — and
`turf-monster-mainnet` deploys from `main`. So this gate is live today and it is
what correctly STOPS this act. Knowing #426 merged is not grounds to skip it:

```bash
heroku run -a turf-monster-mainnet 'test -x bin/nfl-live-poll && echo present || echo MISSING'
```

`MISSING` means THIS app is not running that code — today's expected answer.
Report "the live-score poller is not deployed" and stop; there is no watch to
run and nothing to fix here.

**2. You are pointed where you think you are.** Prove it, and read it back
before committing twelve hours:

```bash
heroku config:get SOLANA_NETWORK -a turf-monster-mainnet
```

Expect **`mainnet-beta`**.

**`RAILS_ENV` cannot answer this question and an earlier draft of this SOP asked
it anyway.** Every Heroku app runs `RAILS_ENV=production`, so `turf-monster-qa`
prints `env=production` identically — the check passed on exactly the stack it
was added to rule out. `SOLANA_NETWORK` is the half that discriminates: the
production app runs `mainnet-beta` (`bin/deploy:130`), QA does not.

Anything other than `mainnet-beta` means you are about to watch a stack nobody
is playing on, and report its numbers as production's.

**This check is not ceremony, and the obvious cheaper one does not work.**
Asking the poller whether it can see games proves nothing about the target:
ESPN answers identically from every environment, so `games_seen` is non-zero on
a laptop with an empty database. A watch started that way passes its own
precondition, runs a full twelve hours, writes `Goal` rows into dev, and reports
"(3 contests) re-scored" the whole time while production never moves. Every line
of that report looks right. It is exactly the failure this SOP exists to prevent
— "a contest that settled on the wrong number" — arriving through the SOP itself.

**3. There is a slot worth watching.**

```bash
heroku run -a turf-monster-mainnet -- bin/nfl-live-poll --json | \
  ruby -rjson -e 'd=JSON.parse(STDIN.read); puts "games=#{d["games_seen"]}"'
```

**The `--` is load-bearing, in this command and in every command below that
passes a flag.** `heroku run` parses the whole line for its OWN flags first, so
`heroku run -a <app> bin/nfl-live-poll --json` dies at `Error: Nonexistent flag:
--json` before it ever reaches the dyno — and `--quiet` the same way. `--` ends
heroku's flag list and hands the rest to the command. (Precondition 1 escapes it
only because it quotes its command string, which works too.)

If `games_seen` is 0, there is nothing to watch. Report that and stop.

## Procedure — the cadence, and why it is not 1,440 tool calls

The watch is a 30-second cadence over a window up to twelve hours. Taken
literally that is 1,440 invocations, which no session survives — the context is
gone long before the games are.

So the agent drives the cadence in **bounded batches**: one command per batch,
each batch a fixed number of 30-second cycles that prints ONLY the cycles where
something changed. You stay in the loop — you read every batch, you decide
whether to continue — but a quiet ten minutes costs one line instead of twenty.

**One batch — ten minutes, twenty cycles:**

```bash
for i in $(seq 1 20); do heroku run -a turf-monster-mainnet -- bin/nfl-live-poll --quiet; sleep 30; done
```

Note the `-a turf-monster-mainnet` again. Every command in this act names its
target, including the loop — a batch that silently drops it is a batch watching
a different stack from the one you checked.

`--quiet` is what makes this readable: it prints nothing when nothing changed,
so a batch over a quiet stretch returns empty and a batch containing a
touchdown returns the touchdown.

Repeat the batch until the window closes. Roughly 72 batches cover twelve
hours.

**If your harness refuses a foreground `sleep`** (several do), run the batch in
the background and read its log each turn instead:

```bash
mkdir -p log
nohup sh -c 'while true; do heroku run -a turf-monster-mainnet -- bin/nfl-live-poll --quiet; sleep 30; done' \
  > log/nfl-live-watch.log 2>&1 &
echo $! > log/nfl-live-watch.pid
```

Then each turn: `tail -n 40 log/nfl-live-watch.log`.

Stop it **by the pid you recorded**, never by name:

```bash
kill "$(cat log/nfl-live-watch.pid)" && rm -f log/nfl-live-watch.pid
```

`pkill -f nfl-live-poll` looks equivalent and is a trap: `-f` matches the whole
command line, so it also matches the shell that launched the loop — and, if you
typed the stop command in a session whose own argv contains that string, the
tool shell running it. The recorded pid names exactly one process.

This is still the agent's loop — no queue, no scheduler, and it dies with the
machine you started it on.

## What a cycle prints

```
21:04:32  PIT  touchdown   +6   PIT 6-0 BUF   Q1 8:42   (3 contests)
21:04:58  PIT  pat         +1   PIT 7-0 BUF   Q1 8:42   (3 contests)
21:11:07  BUF  field_goal  +3   PIT 7-3 BUF   Q1 2:20   (3 contests)
21:44:19  PIT  touchdown   REVERSED  PIT 7-3 BUF
22:58:40                        PIT 24-17 BUF   FINAL
```

Read `(3 contests)` literally: that many open contests re-scored off that play.

**A touchdown can arrive in two lines, and that is not a duplicate.** ESPN does
not report the extra point as its own play — it folds the try into the touchdown
that earned it and RESTATES that same play once the kick is good. So a touchdown
caught mid-try prints `+6` and is followed, seconds later, by the `+1 pat` that
completes it (or `+2 two_point`, or nothing at all when the kick misses). Both
lines describe ONE play and ONE `Goal` row, which ends the sequence worth 7.

A try ruled out on review runs the same way in reverse: `-1`, against the play
it was folded into. Only a whole play withdrawn prints `REVERSED`.

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

The cycle reports seven kinds and never stops for any of them. Deciding which
deserves a human is your job.

| Kind | What it means | What to do |
|---|---|---|
| `fetch_failed` | One game's detail did not arrive | Ignore once. Twice on the same game in consecutive batches: report it. |
| `unknown_team` | An abbreviation resolved to no team | **Escalate immediately.** A team that cannot be matched is a team that silently never scores. |
| `score_drift` | Our summed events disagree with ESPN's total | Ignore a single drifting cycle mid-play — the feed updates a total before its play list. Persisting across three batches means a play was missed: escalate with the game slug and both scores. |
| `degraded_feed` | The feed declined to answer — an absent play list, zero plays against goals we hold, or a blank score on a live game | The cycle REFUSED to act, which is the correct outcome. One is noise. Persisting across several batches means the feed is unwell: report it, and expect the board to stop advancing until it clears. |
| `status_regression` | A stale row reported an earlier state for a game already final | Informational. The game keeps `completed`; nothing is re-broadcast. |
| `unsettled_final` | The feed says FINAL but our events disagree with its total | **The game is NOT settled** — no matchup flipped, no contest scored. It settles on the next reconciling cycle. Escalate if it survives the slot. |
| `cycle_error` | An unexpected exception, captured to `ErrorLog` | A bug, not a feed problem. Report it with the game slug. |

`unknown_team` is the one that never waits. Every other anomaly degrades the
board or stops it advancing; that one silently under-scores a contest while
everything on screen looks correct.

Note what a QUIET anomaly table no longer means. It used to be possible for the
board to be corrupted with none of these raised at all — that is the specific
hole `degraded_feed` and `unsettled_final` were added to close. A clean table is
now evidence, not merely an absence.

**On a REHEARSAL, drift is usually yours.** Scores injected by the `/live` dev
toolbar carry no ESPN play id, so the cycle leaves them alone and correctly
reports the resulting disagreement. Press **Clear** on the `/live` dev toolbar,
re-poll, and treat only what survives as a real defect:

```bash
bin/nfl-live-poll --slot <year>:<type>:<week>
```

Use the button, not `curl`. The toolbar reads the page's `csrf-token` meta tag
and sends it; a hand-rolled POST carrying no session cookie and no token gets a
422, because the dev injectors skip authentication and nothing else.

On production this does not apply: those injectors are not reachable there, so
drift on a real watch is always the feed disagreeing with our events.

## Exit Seam — stopping

Stop when any of these is true, and say which:

- every game in the slot reads `FINAL`
- the twelve-hour window has elapsed
- `unknown_team` appeared and has not been resolved
- Mr. McRitchie says stop

Then report the totals above, and **say which environment they describe** — a
rehearsal's totals and a production watch's totals read identically otherwise.

If you started the background variant, stop it by the pid you recorded:

```bash
kill "$(cat log/nfl-live-watch.pid)" && rm -f log/nfl-live-watch.pid
```

## Resuming

If the session drops, or you are asked to pick a watch back up, just start
again. Re-run the preconditions — **all of them, the target check included**,
because a fresh session has no memory of which stack the last one was on — and
resume the batches. The cycle is idempotent, so everything already recorded
stays recorded and nothing is written twice; there is no reconciliation step and
no state file to repair.

## What this SOP must never do

- **Never hand-write a score.** If the feed is wrong, escalate; do not correct
  the board by hand. A hand-written score has no play id, so the next cycle
  reports it as drift forever.
- **Never widen the cadence to "catch up".** Polling faster does not recover a
  missed play; re-running a cycle does, because it re-reads the full play list.
- **Never settle or grade a contest.** This act records scores. Settlement is a
  separate act with its own gates.
- **Never point the dev score injectors at production data.** The routes are not
  drawn in production and the controller refuses there, so the danger is not a
  production URL — it is a LOCAL toolbar whose database is production's. A
  hand-injected score carries no ESPN play id, so the poller will never
  reconcile it away: it sits in the contest total forever, and the only trace is
  a drift line somebody has to notice.

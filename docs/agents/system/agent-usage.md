# Agent usage: run summaries, tiers and the allowance

**What it is.** Each domain CTO's answers (Avi for McRitchie Studio, Turf for
Turf Monster) cost tokens. The hub stores what each answer cost and rolls it up
per domain. It also holds a client app to a monthly token allowance set by the
app's package tier. This is step 2 of Phase 7 in `.agents/epics/domain-agents.md`
(Alex, 2026-10-16). The warm session that step also names is built behind a
per-domain flag, off: [`agent-message-loop.md`](agent-message-loop.md), "Warm
sessions". A warm turn's run summary is stored like any other (`run_meta.warm`
says `fresh` or `resumed`); it is mostly cache reads, and owner and team turns
are never metered.

**One cap is on: the free tier's.** Vibe, the tier every `/build` app starts on,
allows 25,000 CTO chat tokens a month, about 15-25 replies (Alex, 2026-10-19:
"very small and updated after each message returned"; task free-budget-meter).
Every paid tier's allowance in `config/workspace_packages.yml` is still blank,
and blank is unlimited, until he prices them.

**The first version's build never counts** (it is the cost of acquiring the
client). `bin/client-build-launcher` runs its builder on the launcher's machine
and records no tokens on the board at all: no answer row, no run summary. The
lines it posts into the owner's chat (`ClientBuilds.progress!`, envelope `via:
build_progress`) are code-written, and the meter's scope skips them outright.
Counting the build would need a token source the launcher does not have today.

## The run summary

`bin/dispatcher` reads each answer's `claude -p --output-format json` envelope
(the stream's `result` line for a message with images or PDFs, the same object;
image and document tokens are in its usage) (`AgentMailbox::ClaudeRun.meta`) and sends the summary with the complete. The
board stores it in `agent_messages.run_meta` (`AgentMessage::RUN_META_KEYS`):

| Key | From the envelope |
|-----|-------------------|
| `input_tokens` | `usage.input_tokens` (fresh input) |
| `cache_read_tokens` | `usage.cache_read_input_tokens` |
| `cache_creation_tokens` | `usage.cache_creation_input_tokens` |
| `output_tokens` | `usage.output_tokens` (thinking included) |
| `thinking_tokens` | `usage.output_tokens_details.thinking_tokens` |
| `total_cost_usd` | `total_cost_usd`, the CLI's own figure |
| `duration_ms`, `num_turns` | the same names |
| `model` | the first `modelUsage` key |
| `audience` | **the board's stamp**, never the worker's: the sender's role when the answer completes (`AgentMessage#usage_audience`) |

A numeric key keeps only a finite, non-negative number, so a worker cannot plant
text where the rollup sums. A field the envelope lacks is left out, not guessed.
`/admin/agent_messages/:id` and `bin/agent-inbox show` print the whole summary.

## The rollup

`AgentUsage` computes every figure from the completed rows on each read: there is
no rollup table to drift and no job to run. A domain's answers are those of every
soul the `souls:` map in `config/agent_domains.yml` gives that domain. A client app
built through `/build` has no domain: its answers are the one `client_cto` soul's in
THAT app's chat (`channel_ref`, the `ref:` filter), never another client app's, and the
gate reads the app from the message's `channel_ref` ([`client-cto.md`](client-cto.md)).
A configured CTO that serves no domain (Cyvasse's `tyrion`, `config/cto_reports.yml`)
is metered the same way: its own soul's answers on THAT app's rows (`channel_ref`), and
on an app owner's thread the gate takes the app from `channel_ref` too.

- `AgentUsage.totals(souls:, from:, to:)`: answers, each token kind, cost and
  average duration. Each sum reads a key only where it holds a JSON number.
- `AgentUsage.daily(domain, days:)`: the same per America/Denver day, oldest
  first, an empty day included.
- **The CTO morning report** (`CtoReport`, [`daily-app-report.md`](daily-app-report.md))
  carries one line above the signature: `Agent usage, the day: 3 answers, 13,350
  tokens (in 30 · cache read 12,000 · cache write 900 · out 420), $0.12, avg 3.0s.`
  A domain no routed soul serves (Cyvasse today) has no line.
- **The app page** (`/applications/:slug`, [`app-owners.md`](app-owners.md)) shows
  this month's and today's totals.

A message answered at the cap (below) carries no tokens and is not counted.

## Tiers and the allowance

- **An app's tier** is `apps.package_tier`, a key of `config/workspace_packages.yml`
  (vibe, builder, pro, team, enterprise) or blank. It is not `tier`: `config/apps.yml`
  already uses that word for studio | product | basic. The migration copied each
  client's package from `stack_clients.tier` onto the app with the same slug
  (Turf Monster `team`, Cyvasse `builder`, Commercial Welding `pro`, 10and5
  `vibe`); our own stacks are `internal` and stay blank.
- **The allowance** is the tier's `cto_monthly_tokens`, per month in
  America/Denver that **resets at 1:00 am on the 1st** (`AgentUsage.month_range`,
  task `cto-chat-quality-pass`): the hour after midnight on the 1st still counts
  against the month before. On a fall-back Sunday (Nov 1 2026) the reset is the
  second 1:00, standard time, so the meter's "1am MST" is true. `Meter#period_end`
  is that reset moment (exclusive), and `Meter#resets_line` reads "Resets Nov 1
  at 1am MST" (MDT while daylight time holds). Blank, no tier, or an admin's
  lift: unlimited.
- **What counts against it**: input + cache read + cache write + output tokens of
  the answers to **client** senders. Answers to the **public** are metered apart
  (`Meter#public_used`, shown on the meter as its own line) and never consume the
  allowance, so a stranger cannot exhaust what the client pays for (Alex,
  2026-10-16). Once the client's allowance is spent, a public message is still
  refused, with a plain line ("I can't answer right now. Please try again after
  Nov 1 at 1am MST.") that carries no meter, price or upgrade; a public answer never ends
  with the 80% notice either. The meter is the owner's, never the public's. Owner and team answers are in the totals but never
  metered and never capped. An answer from before this release has no `audience`
  and is not metered (only the owner was answered then).
- **An admin lifts the cap** on the app page (admin only): a tier select and a
  "Lift the cap" box, `PATCH /applications/:slug/usage_cap`. The lift stamps
  `apps.cto_cap_lifted_at` and `cto_cap_lifted_by` and stands until cleared. A
  PATCH that omits `usage_cap[package_tier]` keeps the tier; a blank one clears it.

## Enforcement: in the claim, before a run starts

`AgentMessage.claim!` asks `AgentUsage.gate` about each candidate before it takes
the lease. Owner and team senders return at once. For anyone else, the gate reads
the app that the soul's domain serves (`app:` in `config/agent_domains.yml`):

| Meter | What happens |
|-------|--------------|
| unlimited, or under `warn_percent` (80) | claimed as usual |
| at or past 80% | claimed, with a `usage_warned` event; `complete!` ends the reply with a code-written line: `_85% of this app's monthly agent allowance is used. Pro ($500/month) raises it._` |
| at or past 100% | **not claimed and not run**: the board completes the message itself with the cap reply (`AgentUsage.cap_reply`), records `usage_capped`, queues the reply, and takes the next candidate (up to 10 per claim) |

**An app owner's own chat** (the app-owner exception, `app_owners:` in
`config/agent_answerers.yml`) is held to `AgentUsage.owner_meter`: the app's meter,
with the tier's allowance (Vibe: 25,000), else `app_owners.default_monthly_tokens`
(1,000,000, a conservative default chosen with the feature, not a price) when the
tier names none, and no cap
under an admin's lift. Their answers are stamped `client`, so they count in `used`.
`WebIngest` checks it before storing: at the cap the message is stored already
answered with the cap reply. The gate above checks the same meter at the claim, and
the chat page shows it.

A capped message is completed, never skipped, so it cannot sit `received` and
keep a long-poll busy. The cap reply says the allowance is used, when it resets,
the suggestion (below), and "[Upgrade your plan](https://mcritchie.studio/packages)
or contact us." (`AgentUsage.upgrade_url`: absolute, since the line also reaches
Discord and email). A claim reads each
app's meter once, however many of its capped candidates it answers. An app with
no allowance skips the capped-count query (`agent_message_events` is indexed on
`(kind, created_at)` for the apps that have one).

## The meter

- **Web**: `/applications/:slug` and `/agents/:slug/settings` show the meter
  (`applications/_usage_meter`): used of allowance, a bar coloured by state, the
  tier, the reset date, the public's tokens when there are any, and the
  suggestion. Owner or admin only, like the pages; the public never sees it.
- **The CTO web chat** (`/applications/:slug/chat`) shows a compact meter on the
  app's status card (`agent_chats/_tokens_bar`): on the left "42% used" with
  "Resets Nov 1 at 1am MST" beside it, smaller and lighter; on the right the
  tokens, "10,689 / 25,000", until `warn_percent` is used (80% by default, so
  under a fifth left) or the cap (`Meter#countdown?`), when the right side counts
  down instead, "Resets in 3d 4h" (minutes under a day), and the left drops its
  reset line so "Resets" reads once (the countdown carries it as a title). The
  countdown is ticked each minute, and refreshes the page once the reset passes, by
  `app/javascript/usage_countdown.js` (`AgentUsage.countdown_line` paints the
  first value; the two must agree). Under it an 8px bar coloured by state, and
  the suggestion. Past
  `warn_percent` it adds "Running low: N tokens left this month", and at the cap
  "This month's allowance is used up; it resets Nov 1 at 1am MST", each with an "Upgrade for
  more" link to `/packages`. It is built from `Meter#without_cost` for every
  viewer, admins included, and redrawn live after each answer is delivered,
  the cap reply included (`WebChat.deliver!` → `broadcast_meter`;
  [`agent-message-loop.md`](agent-message-loop.md), "Web chat").
- **Dollars are an admin's.** A non-admin owner reads tokens and the meter only:
  the page's totals lines and the JSON drop `cost_usd` (`Totals#without_cost`,
  `Meter#without_cost`). A tier's price in the suggestion is a list price, shown
  to both.
- **JSON**: `GET /applications/:slug/usage` (owner or admin, past `AdminWall::SIGNED_IN`):
  `{ used, public_used, allowance, percent, state, lifted, capped_this_month, period, month, today, suggestion }`.
- **Discord**: no automatic footer. A team member or the owner asks for it: the
  `usage` ask (no params, `min_audience: team`) is in both domains' catalogs, and
  `AgentProposals::Queries.usage` formats the answer in code once the owner says
  `go`.

## Upgrade suggestions: code, never the model

`AgentUsage::Suggestion.for(meter)` decides, and the price comes only from
`config/workspace_packages.yml`:

1. **When**: the month's average daily rate so far, run to month end, passes the
   allowance; or the app was capped twice this month (`usage_capped` events).
2. **What**: the next package up with a bigger (or unlimited) allowance, at its
   `price_monthly` (a tier with none, Enterprise, is named without a price);
   failing that, the `cto_usage.topup` tokens and price when both are set;
   failing that, "Talk to us about a larger allowance."
3. nil for an unlimited meter or one on track.

The meter and the cap reply show it. No prompt receives a price.

## Task cost

A board task carries its own cost, apart from the CTO answers above: each
`task_events` row may hold `model`, `tokens_in`, `tokens_out`, the two cache
buckets and `cost` (USD, four places). The CTO run summaries never write it.

**Who writes it.** The CLI that moves the task, from the moving session's own
transcript (`lib/agent_session_usage.rb`, `lib/task_usage_baseline.rb`):

- `bin/task move` and `bin/task block` (so `bin/submit`'s move to `submitted`, a
  reviewer's move to `reviewed`, and a send-back), and `bin/release`'s moves
  (assemble, ship). Each reads the session's cumulative usage, subtracts the
  baseline it stored for that (session, task) at the last touch, posts the
  delta, and advances the baseline. The baseline is seeded at `bin/task create`,
  at the build claim, and at a review or deploy intent.
- A checkpoint or review event posted with usage (`POST
  /api/v1/tasks/:slug/events/:stage/complete`, `POST
  /api/v1/tasks/:slug/review_events`) carries what its caller sent.
- The server prices the posted tokens through `UsagePricing`, so an operator's
  rate override applies; the CLI's own `cost` is the fallback for an unpriced
  model. `bin/task move --model/--tokens-in/--tokens-out/--cost` replaces the
  capture.

**What it covers.** The spend of every session that moved the task, in the
window since that session last touched it: the builder's session from claim to
submit, the reviewer's session through its verdict, and the release session
through assemble and ship. A blocked and resubmitted task adds each pass.

**What it does not cover.**

- Avi's intent scout, and any other detached run that never moves the task.
- A subagent's own tokens. The capture reads the session's main transcript
  (`~/.claude/projects/<dir>/<session-id>.jsonl`), not the
  `subagents/agent-*.jsonl` children, so a builder or reviewer spawned as a
  subagent records its PARENT session's delta for that window instead of its own.
- A move with no session transcript behind it (a plain shell, CI, a server-side
  move such as the armed-merge autopilot): it records the spine only, and `cost`
  stays `NULL`.
- The first move a session makes on a task it never touched records no delta
  (no baseline yet).
- A model with no row in `lib/usage_pricing.rb` prices to `NULL`, never a guess.
  The 5-series rows landed 2026-09-25, so rows from the weeks before carry tokens
  and a `NULL` cost, and `task_events:backfill` recovers only the model, never
  tokens or cost. `bin/task usage-audit` sweeps the baseline store for suspect
  rows.
- The window is the session's whole spend, not only this task's: a session
  working two tasks at once charges the same tokens to both.

**How to read a card's cost.** `Task#total_cost` sums every row (`NULL` as 0).
`GET /api/v1/tasks/:slug` serves it, read-only, as `total_cost`, with
`cost_by_stage` and `durations_by_stage` (`Task::CostSummary`;
[`../modules/task-board-api.md`](../modules/task-board-api.md)), and `bin/task
show` prints them:

```text
  cost: $12.35  build $8.00 · review $3.00 · deploy $1.35
  time: design 2h 3m · build 45m · review 20m · assemble - · ship -
```

A row's bucket is its `from_stage`, the stage the session stood in while it
spent: build (created, designed, building), review (submitted), deploy
(reviewed, assembled), other (anything else, printed only when priced). `-` is
a bucket with no priced row, or a stage that never happened; it is never a
measured zero. At ship, a blank `actual_size` is derived from the total
(`Task::ACTUAL_SIZE_COST_THRESHOLDS`). The board card does not show cost yet: the
card reads only its preloads, and a cost needs its own batch.

`time:` is the seconds spent in each stage, summed over the transition spine
(`seconds_in_from` by `from_stage`), so a reworked task counts every pass: design
(in designed), build (in building, a block included), review (in submitted),
assemble (in reviewed), ship (in assembled). A stage no transition has left yet,
because it never happened or the task is in it now, prints `-`.

The activity feed prices the same transcripts per activity rather than per
stage move: [`atomic-capture-hook.md`](atomic-capture-hook.md).

## Not built here

- Paid tiers' allowance numbers and top-up prices: Alex's call (Vibe's is set).
- Counting the first version's build: the launcher records no tokens.
- Billing: the allowances mean money only once client CTOs run on an API-billed
  runtime (Phase 6).
- The MS web chat bar (Phase 7 step 3) and per-(domain, user) sessions.

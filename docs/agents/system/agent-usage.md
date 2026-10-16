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

**Alex's default: caps are present but off.** Every tier's allowance in
`config/workspace_packages.yml` is blank, and blank is unlimited. Nothing is
capped and no reply carries a notice until he prices the tiers. The code, the
meter and the tests run as if the caps were on.

## The run summary

`bin/dispatcher` reads each answer's `claude -p --output-format json` envelope
(`AgentMailbox::ClaudeRun.meta`) and sends the summary with the complete. The
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
soul the `souls:` map in `config/agent_domains.yml` gives that domain.

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
- **The allowance** is the tier's `cto_monthly_tokens`, per calendar month in
  America/Denver. Blank, no tier, or an admin's lift: unlimited.
- **What counts against it**: input + cache read + cache write + output tokens of
  the answers to **client** senders. Answers to the **public** are metered apart
  (`Meter#public_used`, shown on the meter as its own line) and never consume the
  allowance, so a stranger cannot exhaust what the client pays for (Alex,
  2026-10-16). Once the client's allowance is spent, a public message is still
  answered with the cap reply. Owner and team answers are in the totals but never
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

A capped message is completed, never skipped, so it cannot sit `received` and
keep a long-poll busy. The cap reply says the allowance is used, when it resets,
the suggestion (below), and "Upgrade your plan or contact us." A claim reads each
app's meter once, however many of its capped candidates it answers. An app with
no allowance skips the capped-count query (`agent_message_events` is indexed on
`(kind, created_at)` for the apps that have one).

## The meter

- **Web**: `/applications/:slug` and `/agents/:slug/settings` show the meter
  (`applications/_usage_meter`): used of allowance, a bar coloured by state, the
  tier, the reset date, the public's tokens when there are any, and the
  suggestion. Owner or admin only, like the pages; the public never sees it.
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

## Not built here

- Real allowance numbers and top-up prices: Alex's call.
- Billing: the allowances mean money only once client CTOs run on an API-billed
  runtime (Phase 6).
- The MS web chat bar (Phase 7 step 3) and per-(domain, user) sessions.

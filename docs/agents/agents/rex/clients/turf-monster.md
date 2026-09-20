# Client dossier — Turf Monster

**Read this before advising, and check the date on every number.** A stale
number is worse than no number, because it gets acted on.

Last reviewed: **2026-09-19**

## The business

A sports pick'em product. Players build an entry from a slate of matchups with
multipliers; contests settle against real results, with escrow and prize payout
running on Solana (`turf-vault`, 2-of-3 multisig). Live at
**turfmonster.media**, port 3100 locally.

## Finding on day one: the front door describes last season's game

`turf-monster/README.md` opens with *"Sports pick'em game for the FIFA World Cup
2026"*. The World Cup finished in July. The running product is NFL — 33 files
under `app/models` and `app/controllers` reference NFL against 14 for the World
Cup, the hub's content lane posts NFL lineup graphics per team, and the news
intake watches an NFL insider.

That is a marketing defect, not a documentation one. The first thing a curious
person reads says we sell a thing that already happened. **Decide the
positioning line, then fix the README, the site, and the social bios in the same
pass** — and decide whether the brand is "NFL pick'em" or "a pick'em engine that
follows the season", because the answer changes every headline for the next two
years.

## Who buys

Sports fans who already play fantasy or bet, comfortable enough with a wallet to
fund an entry. The crypto rail is a real audience filter in both directions: it
qualifies some people and disqualifies more. Nobody has measured which way that
trades yet.

## What already exists (so Rex does not prescribe what is built)

- A working publish lane: a per-team button generates a lineup graphic and a
  short video, an agent drafts three caption variants, and a human clicks post to
  X or TikTok as **@turfmonstershow**. Built and used.
- A news intake that pulls an NFL insider's posts and enriches them into content
  ideas. The three ideas it generates per article are **never read by anything** —
  they are generated and dropped on the floor.

## What is NOT instrumented — the likely constraint

Views, likes, comments and shares exist as fields on a post record, and they are
filled in **by a human typing them into a form**. Nothing reads them back from X
or TikTok. There is no scheduled posting, no campaign grouping, and no link
between a post and an entry.

So today nobody can answer: which post brought an entrant? Under the SOP's step-3
table, row 1 trips before anything else. **The constraint is measurement until
proven otherwise**, and the first prescription is almost certainly instrumentation
plus a tracking link, not more creative.

## Numbers Rex needs (currently unknown)

| # | Question | Why |
|---|---|---|
| 1 | Entries in the last completed contest, and the one before | The only number that matters; tells us if this is a volume or conversion problem |
| 2 | Cost of an entry, and what the house keeps | Sets what an entrant is worth, so we know what we can spend |
| 3 | Posts published in the last 30 days, by platform | The rep count |
| 4 | Views on the last ten posts | Whether we have a reach problem or an ask problem |
| 5 | How many visitors reached the site from social, and how many started an entry | The step where it breaks |
| 6 | How many entrants came back for a second contest | Whether we are renting attention or building it |
| 7 | Wallet funding drop-off — start versus completed | Whether the crypto rail is the constraint |

## Seasonality — the thing that makes this urgent

Football is a 17-week window and the audience's interest is not evenly
distributed across the year. Every week not spent acquiring during the season
costs more than a week in July. Any plan that starts "next quarter" is the wrong
plan for this client.

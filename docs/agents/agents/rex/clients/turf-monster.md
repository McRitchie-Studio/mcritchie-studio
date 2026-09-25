# Client dossier — Turf Monster

**Read this before advising, and check the date on every number.** A stale
number is worse than no number, because it gets acted on.

Last reviewed: **2026-09-20**

## The brief, settled by Alex 2026-09-20

- **Positioning: "NFL pick'em."** Not a season-agnostic engine. Every headline,
  bio and the README inherit this.
- **The goal is selling contests.** That is the number Rex moves.
- **He knows the economics are thin**, and says so plainly: this is a passion
  project he hopes to grow into something he can pivot later.

That last line is a real input, not a disclaimer, and it changes the advice.
**Optimise for the assets that survive a pivot** — an audience, a list, a
reputation, a repeatable content engine — over squeezing this season's entry
count. A tactic that sells 40 more entries and leaves nothing behind is worth
less here than one that sells 20 and builds a list.

## The structural limit on this client — read before prescribing spend

Turf Monster is a **low-ticket consumer product**, and that trips the exception
Hormozi places on his own most-quoted rule. See
[`../knowledge/when-his-advice-does-not-apply.md`](../knowledge/when-his-advice-does-not-apply.md).

The famous version — *"all advertising works, it's just a matter of
efficiency"*, and *"everyone thinks they have a marketing problem but typically
it's a monetization issue"* — is stated absolutely. His exception, buried in a
video about a frozen-yogurt shop, is stated just as absolutely: at that ticket
**it is very difficult to acquire customers with paid advertising profitably**,
and the lanes that remain are **word of mouth and affiliates**.

So the default CMO move here — fix the back end, then buy traffic — is the one
move the corpus says will not pay at this price point. Rex must open that card
before recommending any paid spend on this client.

**One exception to the exception:** a business with a genuine network effect
chasing winner-take-all does need to rush. A contest product has real network
effects — contests need fill, and fill makes contests worth entering — so the
usual "the rush is imaginary" counsel does not apply cleanly here either. Say
which way you are arguing and why.

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
person reads says we sell a thing that already happened.

**Settled 2026-09-20: the brand is "NFL pick'em."** The blocker is gone, so this
is now a chore with a deadline rather than a question. Fix the README, the site
copy and the social bios **in one pass**, because a half-corrected front door is
worse than a consistently stale one — it reads as abandoned rather than
between-seasons.

It is also urgent in a way it was not last week: the season is running, so every
week the front door misdescribes the product is a week of the only high-intent
traffic this business gets landing on the wrong sentence.

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

# Turf Monster — selling contests, NFL 2026

**From:** Rex · **Date:** 2026-09-20 · **SOP:** [`constraint-diagnosis`](../sops/constraint-diagnosis.md) (v2)
· **Client:** [`turf-monster`](../clients/turf-monster.md) (dossier reviewed 2026-09-20, same day — numbers current)
· **Brief from Mr. McRitchie:** sell contests, this season. Positioning settled as "NFL pick'em."
· **Status:** constraint named from measured production data; one move prescribed with a date

---

## The short version

**We pay out more in prizes than we collect in entry fees, and we have since the
first contest.** Measured, from the production ledger: **$551 in entry fees
collected, $590 in prizes paid — $1.07 out for every $1.00 in.**

That is not a marketing problem. Every contest we sell at these terms makes it
worse. The reason is one line in the code: the house **pre-funds a fixed prize**
and the entry fees never enter the pool, so a contest only makes money if it is
almost sold out — and we have never almost sold one out except a three-seat
internal test.

**One move this week:** the Weeks 4-6 prize is already paid for and does not grow
with fill, so the seven unsold seats are **$19 of pure margin each**. Sell them by
hand to the 32 people we can already name, before the contest locks on
**2026-10-01**.

**I was wrong last week and I am recording it below.** I called measurement the
constraint without running a single query against production. The numbers were
there.

---

## Step 0 — What I did instead of asking

Last week's brief refused to advise and asked for seven numbers. That was half
right — a guess would have been worse — but the refusal was too wide. The revised
SOP is explicit:

> "Measurement gates **changes to spend on an unmeasured channel**. It does
> **not** gate price, the offer, retention, or any move that is reversible,
> non-rival, and priced off numbers you already trust."

So this time I went and got the numbers. Most of them existed. Everything below
marked **measured** came from two read-only `rails runner` queries against
`turf-monster-mainnet` and one against `mcritchie-studio`, run 2026-09-20. No
code was changed.

## Step 1 — The numbers

### Where the product actually is — measured 2026-09-20

| | Measured |
|---|---|
| Contests ever created | **7** (5 settled, 2 open) — all `turf_totals` |
| Entry fee | **$19.00** on **7 of 7**. Never once varied |
| Accounts | **47** |
| Distinct users who have ever paid for an entry | **16** |
| Entries started | **62** — `complete` 25, `active` 11, `cart` 13, `abandoned` 13 |
| Started entries that never became a paid entry | **26 of 62 = 42%** |
| Contests per paying user | **2.13** avg — histogram: 6 users at 1, 5 at 2, 4 at 3, 1 at 6 (`status IN (active, complete)`) |
| Paying users who came back for a second contest | **10 of 16 = 62.5%** |
| Accounts with an email address / verified | **32 / 28** |
| Accounts on the email list | **2 of 47** |
| Accounts created in the last 30 days / 7 days | **5 / 1** — during NFL weeks 1-3 |
| Users ever invited by another user | **4.** Users who have ever invited anyone: **1** |
| Marketing emails ever sent | **0.** 37 sends total: 26 magic links, 8 winnings, 3 admin |
| `Content` rows in hub production | **0** |

### The ledger — measured, `TransactionLog`

| Line | Amount |
|---|---|
| Entry fees collected, lifetime | **$551** |
| Prizes paid out, lifetime | **$590** |
| **Paid out per $1.00 collected** | **$1.07** |

### Per-contest margin — measured, actual recorded payouts

| Contest | Format | Sold / seats | Gross | Paid out | Margin |
|---|---|---|---|---|---|
| `test8` | tiny | 3 / 3 | $57 | $45 | **+$12** |
| `turf-totals-alpha-contest-v1` | medium | 6 / 9 | $114 | $140 | **−$26** |
| `world-cup-turf-totals-week-1` | standard | 15 / 29 | $285 | $500 | **−$215** |
| `nfl-week-1-3-test` | tiny | 1 / 3 | $19 | $45 | **−$26** |
| **Four settled and paid** | | | **$475** | **$730** | **−$255** |
| `nfl-…-weeks-1-3-contest` | medium | 7 / 9 | $133 | *locked, owes $140* | **−$7** |
| `nfl-…-weeks-4-6-contest` | medium | **2 / 9** | $38 | *open, owes $140* | **−$102** |

*(A fifth settled row, `world-cup-week-1-turf-totals`, has `onchain_settled:
false` and $0 paid against 2 entries. It is a duplicate of the contest above it
and I have excluded it rather than credit a $38 "profit" that is really an
unsettled contest.)*

**Five contests have settled and paid. Four of the five lost money. The one that
made money was a three-seat internal test named `test8`, and it made $12.**

### Why — `app/models/contest.rb:304-330`

The prize is **guaranteed and pre-funded by the house**, and entry fees never
touch it:

- `guaranteed_prize_cents = payouts.values.sum` (`contest.rb:281`) — a fixed
  number, set by format, not by fill.
- `onchain_params` funds the on-chain prize-pool PDA at that full amount when the
  contest is **created** (`contest.rb:677`).
- Entry fees go straight to operator revenue: *"Entry fees never reach the prize
  pool at all — enter_contest transfers the user's ATA straight to the
  operator-revenue ATA"* (`contest.rb:642-644`).

So margin = (seats sold × $19) − a fixed prize. Which gives this:

| Format | Seats | Guarantee | Seats needed to break even | **Breakeven fill** |
|---|---|---|---|---|
| tiny | 3 | $45 | 3 | **100%** |
| small | 5 | $75 | 4 | **80%** |
| medium | 9 | $140 | 8 | **89%** |
| standard | 29 | $500 | 27 | **93%** |
| large | 99 | $1,800 | 95 | **96%** |

**Every format we sell needs 80-96% fill to break even.** Best fill ever achieved
outside a three-seat test: **7 of 9 (78%)**, right now, on the live contest.

### What one entrant is worth

The unit-economics card is direct about the numerator:

> "LTV is not lifetime revenue, it's lifetime gross profit"

At **100% fill** of a medium contest, gross profit is $31 across 9 entries =
**$3.44 per entry**. At 2.13 contests per paying player, lifetime gross profit is
**≤ $7.33 per customer** — before Solana fees, MoonPay ramp spread and sweep
costs, which I have not measured.

The same card's own read of this client:

> "**turf-monster** — the rare business where 3:1 is genuinely the right floor:
> content and ads generate, the app converts, software delivers."

**3:1 against $7.33 permits a CAC of $2.44.** And today the ratio is not thin, it
is negative: at achieved fill, lifetime gross profit per customer is below zero.

### Step-1 questions, answered

| # | Question | Answer today |
|---|---|---|
| 1 | How many saw anything we published last month? | **Unanswerable.** Nothing reads back from X or TikTok; hub `Content` count is 0 |
| 2 | How many became a lead? | **No lead concept exists.** No capture step between a post and an account |
| 3 | How many bought? | **36 paid entries, 16 distinct payers, lifetime** |
| 4 | First-purchase value? | **$19 gross; ≤$3.44 gross profit at full fill; negative at achieved fill** |
| 5 | Lifetime value? | **2.13 contests × ≤$3.44 = ≤$7.33 gross profit** |
| 6 | What did we spend to get them? | **Unanswerable.** No attribution; no UTM column anywhere in the schema |
| 7 | Payback window? | **Inverted.** The prize is funded *before* the first entry sells |
| 8 | How many times did we publish? | **Unanswerable.** Hub production has 0 `Content` rows |
| **9** | **How did we arrive at the price, and when was it last tested?** | **Set once, 2026-05-17, in a code comment. `entry_fee_cents = 1900` on 7 of 7 contests. Never tested** |

**Five of nine are answered. Last week I said four of eight were unanswerable and
stopped. Two of those were sitting in the production database.**

## Step 2 — The two gates

### Gate A — Delivery capacity. Does NOT trip.

> "Can you handle 20 people a week?"

There is a measured capacity figure and it looks damning: `max_entries = 9` on
both live NFL contests. But the SOP's own pre-check disarms it:

> "check historical peak throughput. If the business has ever delivered more than
> it delivers now, the gate does not trip — you are looking at a demand problem
> wearing a capacity costume."

`world-cup-turf-totals-week-1` ran at **29 seats and delivered 15 completed
entries**. The business has delivered more than it delivers now. **The gate does
not trip.** The 9-seat cap is a costume, and it is not even binding this week —
seven of its nine seats are unsold.

Recorded because it matters for the other clients: this is software with
automated settlement. A hundred entrants next week is a good problem.

### Gate B — Measurement. Fires, on SPEND only.

It fires legitimately: nothing reads engagement back from X or TikTok
(`grep public_metrics|view_count|like_count` across the hub returns **zero
matches**), `views`/`likes`/`shares` are typed into a form by a human
(`app/services/content/review.rb:1-19`), and there is **no UTM or referrer column
anywhere in the turf-monster schema**.

**What that gates: any ad budget. Nothing else.** The paid-ads card:

> "**untrustworthy attribution is the one legitimate reason not to spend**"

It does **not** gate this week's move, which changes no spend, uses a channel we
own outright, and is priced off numbers I have measured to the dollar.

## Step 3 — The ranked search

| Row | Trips? | The measured reason |
|---|---|---|
| **1 — The offer** | **TRIPS** | See below |
| 2 — Price | *(not reached)* | Reported anyway in Step 4, because the SOP requires it |
| 3 — Retention | *(not reached)* | Cleared on the way past: 2.13 contests per payer, 62.5% repeat. The base does not leak |
| 4-8 | *(not reached)* | — |

### Row 1: the offer

The trip condition is a shrug from people who match the target. We have one, and
it is measured three ways:

- **31 of 47 people who made an account have never paid for an entry** — 66%.
  They matched the target hard enough to sign up, then did nothing.
- **26 of 62 started entries (42%) ended in `cart` or `abandoned`.** They picked
  their teams and stopped.
- **5 new accounts in 30 days, 1 in the last 7** — during the opening weeks of
  the NFL season, with the publishing lane running.

And the offer they are shrugging at, run through the value equation
([`offer-construction`](../knowledge/offer-construction.md)):

> "how risk-free can I make it? How easy can I make it? How fast can I make it?"

| Lever | What we ask |
|---|---|
| **Dream outcome** | $100, to one of nine people. The card: *"The dream outcome sets the price ceiling."* Ours is $100 |
| **Perceived likelihood** | 1 in 9 — genuinely the strongest part of the offer |
| **Time delay** | Three weeks to settle, plus the app's own estimate of *"about ten minutes"* to onboard |
| **Effort and sacrifice** | Install Phantom, secure a seed phrase, buy $25 of USDC through MoonPay — **before any entry, free ones included** |

That last row is not optional and not a guess. `ContestsController#enter` (`contests_controller.rb:763-779`) refuses
a wallet-less account outright, and the comment at `contests_controller.rb:775-778` reads: *"An account with
no wallet at all cannot be entered on-chain in ANY contest, free included."*
`ENABLE_WEB3_ONLY_ONBOARDING` defaults to **true**, so `generate_managed_wallet!`
returns early and no custodial wallet is minted for new signups — every new
person must install a browser extension first.

**Flagged honestly: reading an onboarding step as a conversion tax is my
inference, not doctrine.** The limits card says so itself, in its own list of
what is absent from the corpus: *"Nothing on checkout or onboarding friction —
no item about the number of steps to purchase, wallet or account creation, or
signup abandonment. Any read on an onboarding step is Rex's inference."* I am
labelling it and I am not resting the constraint on it. The constraint rests on
the ledger.

**Row 1's instruction is "Do not: touch copy, channel or budget."** That rules
out a posting sprint and rules out ad spend, and I am honouring it.

### Why not row 3, retention

Because retention is the one thing here that is **working**, and I checked both
clauses rather than assuming:

- **Clause 1 — average life.** Active base ÷ new customers per month = ~8 active
  users ÷ 4.4 new paying users per month = **1.8 months**. Implied repurchase
  cadence is a 3-week contest = 0.69 months; twice that is 1.38 months.
  **1.8 > 1.38. Does not trip.**
- **Clause 2 — mechanism vs. request.** This one is *close*. There is no "the
  next contest is open" mailer anywhere (`app/mailers/` has `winnings`,
  `gift_invite`, `friend_joined_contest`, `magic_link`, verification, and a
  newsletter welcome — nothing that sells the next contest), and 2 of 47 accounts
  are on the email list. The next purchase genuinely is produced by a request.

**I am calling row 1 anyway, and here is why that is not me picking the answer I
liked.** Row 3's prize is the existing base: 16 payers, 32 addresses. Its ceiling
is the season's whole inventory. **And every seat in that inventory currently
loses money.** Perfectly monetising the base against an offer that pays out $1.07
per $1.00 collected is the row 3 warning — *"Buy new customers to fill a leaking
bucket at full price"* — with the bucket and the leak swapped. Fix the terms
first; the base is how we sell them.

---

## The constraint, in one sentence

**The constraint is the offer: across four settled-and-paid contests this product
collected $551 in entry fees and paid out $590 in prizes — $1.07 out for every
$1.00 in — because the house pre-funds a fixed prize that requires 80-96% fill to
clear, and the best fill we have ever produced outside a three-seat internal test
is 7 of 9.**

---

## Step 4 — One move

### The move: sell the prize we have already paid for

**Sell the seven remaining seats in `nfl-turf-monster-weeks-4-6-contest` by hand,
to the 32 people whose email addresses we already hold, before it locks.**

**Why this and nothing else:** that contest's $140 prize is **already funded and
does not grow with fill**. Seats 3 through 9 are therefore **$19 of pure margin
each — $133 total, at zero incremental cost**. Nothing else available to this
business this month moves $133, and it is the difference between the contest's
worst outcome (−$102) and its first profitable one (+$31).

| | |
|---|---|
| **Action** | 32 one-to-one messages — every account holder with an email on file — asking directly for one of the seven open seats. Email, text, DM; whichever we have. Not a broadcast: a named ask, person by person |
| **Volume** | **32 messages, sent by Friday 2026-09-25.** Seven seats to sell |
| **Deadline** | The contest locks at its `starts_at`, **2026-10-02 00:15 UTC = 2026-10-01, 6:15pm MDT** |
| **Owner** | Mr. McRitchie sends them. Mason owns the sentence if we want one shape reused across all 32 |
| **Cost** | Zero. No code, no spend, no instrumentation |

This is the **warm outreach** box of the Core Four, which this business has never
once used:

> "if you're not spending your day doing one of those core four things, you are
> not advertising"

**The 32 split exactly in half, and the two halves get different messages** —
measured: every one of the 16 paying users has an email on file, and so do 16
people who signed up and never paid.

| Half | Who | The ask | What it also buys |
|---|---|---|---|
| **16 payers** | 10 have paid more than once; one has entered six contests | "Weeks 4-6, seven seats left, here's the slate" | The seats. This is where the 7 come from |
| **16 signed up, never paid** | Matched the target enough to make an account, then stopped | "You made an account and never entered — what stopped you?" | **Number 1 on my list, for free.** These are the shrug, by name |

We are not looking for strangers; we need seven people out of thirty-two we can
name.

**Ride the ask on the product, not on goodwill.** Do not write "please help me
fill my contest." Write what the reader gets: which teams are on the Weeks 4-6
slate, what the $100 is, that there are seven seats. And **put the damaging
admission in** — say the wallet step takes ten minutes, out loud, and let the
people who will not do it say so. That answers number 1 on my list below for
free.

### Prediction

**Six of the seven seats sell.** The contest lands at 8 or 9 of 9, margin between
**+$12 and +$31**, and Turf Monster records its first profitable NFL contest.

**What would prove me wrong: fewer than three seats sell.** If 32 warm contacts —
16 of whom have already paid us, 10 of whom have paid us more than once — will not
buy three seats when asked by name during the NFL season, then the problem is
neither the prize structure nor reach. It is that the people closest to this
product do not want it, and the diagnosis restarts at whether there is a business
here at all rather than at row 2.

**Second prediction, on the number rather than the money:** at least 4 of the 32
will reply naming the wallet as the reason they have not entered. If nobody does,
my onboarding inference is wrong and I will say so.

### The price check — required every time, outside the one-move budget

Row 2 did not trip, but three of its four signals are firing and the SOP requires
me to report them:

| Signal | Firing? | Measured |
|---|---|---|
| Thin net margin | **YES, hard** | −$255 lifetime across settled contests; $1.07 paid out per $1.00 in |
| Never tested | **YES** | `entry_fee_cents = 1900` on **7 of 7** contests ever created. Set once, 2026-05-17 |
| Market is not the ceiling | **YES** | 47 accounts, against an NFL pick'em market in the tens of millions |
| Sells without resistance | **NO** | 42% of started entries ended `cart` or `abandoned` |

The fourth is why row 2 does not trip — and it is also the honest limit on this
report, because **I cannot yet separate price resistance from wallet friction.**
That is number 1 on my list below.

**But the free lever here is not the entry fee. It is the guarantee.** The fee is
pinned by the value equation: raising $19 without raising the prize makes the
offer worse, and raising the prize raises breakeven fill. The guarantee is
unpinned, costs nothing to change, and is a number an admin types at contest
creation.

**Standing rule from the next contest on: set the guarantee from measured fill,
not from the format table.** Weeks 4-6's result is that measurement. Sell 9 and
`medium` stands. Sell 5 and Weeks 7-9 is `small` — $75 guarantee, breakeven at 4
of 5, profitable at a fill we have actually produced twice.

**And the structural fix worth a task:** make the prize **proportional to fill
above a small floor**. A contest that cannot lose money can be any size, which
removes the 9-seat cap as a worry and lets the network effect work in our favour
instead of against us. That is a code change and it rides the DevOps cycle like
anything else — I do not get an exemption for being in a hurry.

---

## Which lanes are ruled out, and which remain

The dossier is right that the low-ticket exception governs this client, and our
own arithmetic makes it stricter than his.

> "it's very difficult to acquire customers with paid advertising profitably"

**RULED OUT — paid advertising.** Not "later." Arithmetically. Lifetime gross
profit per customer is **≤$7.33** at 100% fill and **negative** at achieved fill;
the 3:1 floor this business qualifies for permits a CAC of **$2.44**. No channel
acquires a consumer for $2.44, least of all one we then ask to install a wallet.
The corroborating line from the same card is the test we would have to pass
first: *"low-priced products need a loop where one acquired customer brings at
least 1.1 more, or paid acquisition eventually fails at scale."* Ours brings
**0.085** — 4 invited users across 47 accounts.

**RULED OUT FOR NOW — affiliates.** The affiliates card says the arithmetic
closes for a pick'em app, and it names the blocker in the same breath: *"the
crypto-wallet onboarding step is friction on the affiliate's audience,"* and

> "as soon as there's friction, they'll stop"

There is also nothing to pay them out of. $3.44 per entry at full fill does not
fund a commission. The limits card flags this as an open question in the corpus
rather than an answered one — *"No limit on affiliate advice for a product with
no margin to share"* — so I am parking it on our own numbers, not on his.

**THE LANES THAT REMAIN:**

1. **Warm outreach** — never used, free, and the only one that can sell seven
   seats in eleven days. This week's move.
2. **Referral / word of mouth** — built and idle. `?ref=` capture,
   `invitees_count`, `InviterMailer#friend_joined_contest` all exist; **4 users
   have ever been invited and 1 user has ever invited anyone.** The limits card
   puts consumer products on the live side of the virality line. This is the
   second lane, and it opens once the offer stops losing money.
3. **Content** — running, unmeasured, and explicitly *not* this week's work
   because row 1 forbids touching the channel while the offer is wrong.

**One thing the corpus gets right about us that I want on the record.** The limits
card grants exactly one exception to "the rush is imaginary":

> "a business with a tremendous network effect chasing a winner-take-all
> position … genuinely does need to rush"

A contest product has real network effects — fill makes a contest worth entering.
That argues *for* urgency, and it argues *against* raising the seat cap before we
can fill it. **A sold-out five reads as a live game. Two of nine reads as
abandoned.** Sell out what we have before we make it bigger.

---

## What we do this week that does not wait on instrumentation

| # | Action | By | Owner | Blocked on anything? |
|---|---|---|---|---|
| **1** | **The move.** 32 one-to-one asks for the 7 open Weeks 4-6 seats | **Fri 2026-09-25** | Mr. McRitchie (sentence: Mason) | **No** |
| 2 | Fix the front door **in one pass** — README, `OgHelper::DEFAULT_OG_TITLE`/`DEFAULT_OG_DESCRIPTION` (`og_helper.rb:21-22`), `terms.html.erb`, social bios. The OG default still reads *"Skill-Based World Cup Pick'em Contests"* and it is what renders on **every link we post to X** | **Wed 2026-09-23** | board task, normal cycle | No — decision settled 2026-09-20 |
| 3 | Decide the Weeks 7-9 format from the Weeks 4-6 result; never pre-fund above measured fill | **Mon 2026-10-06** | Rex + Avi | On action 1's result |
| 4 | Put the wallet question **inside** action 1's message so the abandon reason arrives free | Fri 2026-09-25 | same message | No |

Actions 2-4 run in parallel with the one move under the SOP's own test — *"is it
reversible, non-rival, and priced off numbers I already trust?"* All three are.

**What we do NOT do this week:** open an ad account, raise the seat cap, start a
posting sprint, or build a newsletter. The first two lose money faster, the third
is forbidden by row 1, and the fourth is worth doing the week after the offer
stops leaking.

---

## The numbers I need, ranked

| # | Number | What it changes | Who or what produces it |
|---|---|---|---|
| **1** | **Where the 26 `cart`/`abandoned` entries stopped** — wallet step, funding step, payment, or picks | The single fork in this whole diagnosis. Wallet friction → the fix is `ENABLE_WEB3_ONLY_ONBOARDING` and a managed-wallet first entry. Price resistance → the fix is the guarantee and the fee. **Opposite prescriptions** | **Free version this week:** ask inside the 32 messages. **Durable version:** a `drop_step` stamp on `entries` — a board task; Avi shapes it |
| **2** | **Net cash per entry after Solana fees, MoonPay/ramp spread and sweep cost** | I have gross profit ($3.44/entry at full fill) but not net. It decides whether any acquisition channel can *ever* pay, and whether a proportional-prize contest is even viable | Jasper / Steffon, from the operator-revenue sweep against `transaction_logs` and `outbound_requests` |
| **3** | **Seats sold from 32 named warm asks** | The first conversion rate this business has ever had, and the input that sets the guarantee for every remaining contest this season | The move itself. Readable **2026-10-01** |
| 4 | Reach — how many people saw anything we published in 30 days | Separates a reach problem from an ask problem (rows 4 and 5), and is the precondition on ever spending a dollar (Gate B) | X's API. We already hold `X_BEARER_TOKEN` and already post through `X::PostMedia`, so the read-back is a small task, not a new integration. Version one is a fixed weekly manual read at a named time, owned by a named person |
| 5 | A post → entry link | Which post brought an entrant. There is **no UTM or referrer column anywhere** in the schema | A board task: a tracking param captured onto `users.reference`, which already exists and already survives 30 days as a cookie |

**Numbers 1 and 3 cost nothing and arrive this week.** That is the difference
between this brief and last week's.

---

## Step 5 — Handoff

- **Mason** — one sentence, reused across 32 messages. You own whether it is ours.
  I own that it asks for a seat and names the wallet step honestly. **Veto
  anything that promises a prize pool bigger than $140** — that is exactly the
  claim the product cannot support and I will back you against my own campaign.
- **Avi** — two things. Confirm I have read the wallet gate correctly before we
  publish a word about it. And shape the `drop_step` task; number 1 on my list is
  yours to make answerable.
- **Turf Monster (the soul)** — is a $100 top prize among nine entrants a real
  proposition to a person who plays fantasy, or is it a joke to that audience? You
  own that judgement and my read on it carries no information.
- **Shannon** — nothing this week.
- **Engineering** — actions 2 and 5 are board tasks on the normal cycle.

## Step 6 — Read the result against the prediction

**Review date: 2026-10-02**, the morning after Weeks 4-6 locks.

The question at that review is not "did engagement improve." It is three
questions with numbers attached:

1. How many of the seven seats sold? (I predicted six.)
2. How many of the 32 named the wallet? (I predicted at least four.)
3. **Did the contest turn a profit for the first time?**

And then the format call for Weeks 7-9 falls straight out of answer 1.

---

## Step 7 — Scoring last week's prediction: I was wrong

Last week's brief named **measurement** as the constraint and predicted *"no lift
at all in the next two weeks."* It set its own falsification test:

> "if you can already answer questions 1, 5 and 6 from a source I have not found,
> then measurement is not the constraint, I have misread the system, and the
> diagnosis should restart at row 2 — the offer."

**The condition fired.** Question 5 — lifetime value — is answerable, and was
answerable last week: 2.13 contests per payer × ≤$3.44 gross profit. The source I
had not found was the production database and the format table in
`app/models/contest.rb`. Question 3 and question 4 were answerable too. The brief
recorded four of eight as unanswerable; the true figure was four *answered*, and
it scored two of them backwards.

**The failure was not ignorance, it was procedure.** I declared a constraint
without running a query, and "nothing is measured" is the one diagnosis that
sounds rigorous while requiring no work. The SOP was revised for exactly this.
This is what the revision is supposed to prevent, and this brief is the first run
of it.

One thing from last week survives intact and I am not walking it back: **there is
still no way to tell which post brought an entrant**, and until there is we
cannot spend a dollar on this client. That was right. It was just not the
constraint.

---

## The corpus behind this

Cards used, with the line each decision rests on:

| Card | Line relied on | Used for |
|---|---|---|
| [`when-his-advice-does-not-apply`](../knowledge/when-his-advice-does-not-apply.md) §2 | *"it's very difficult to acquire customers with paid advertising profitably"* | Ruling out paid, on his stated limit plus our own CAC arithmetic |
| same, §2 corroboration | *"low-priced products need a loop where one acquired customer brings at least 1.1 more"* | Our loop is 0.085; the test fails on measurement, not on opinion |
| same, §15 | *"a business with a tremendous network effect chasing a winner-take-all position … genuinely does need to rush"* | Why urgency is real here, and why we fill the seats we have before adding more |
| same, "What is NOT on this card" | *"Any read on an onboarding step is Rex's inference, not doctrine"* | Labelling the wallet read as mine |
| [`offer-construction`](../knowledge/offer-construction.md) | *"how risk-free can I make it? How easy can I make it? How fast can I make it?"* and *"The dream outcome sets the price ceiling"* | The value-equation read of the offer; why the fee is pinned and the guarantee is not |
| [`unit-economics`](../knowledge/unit-economics.md) | *"LTV is not lifetime revenue, it's lifetime gross profit"*; and its own read, *"the rare business where 3:1 is genuinely the right floor"* | The $7.33 LTGP and the $2.44 CAC ceiling |
| [`core-four`](../knowledge/core-four.md) | *"if you're not spending your day doing one of those core four things, you are not advertising"* | Warm outreach as the empty box, and this week's move |
| [`channel-affiliates-and-referrals`](../knowledge/channel-affiliates-and-referrals.md) | *"as soon as there's friction, they'll stop"* | Parking affiliates until the wallet and the margin are settled |
| [`channel-paid-ads`](../knowledge/channel-paid-ads.md) | *"untrustworthy attribution is the one legitimate reason not to spend"* | Gate B's true scope: spend, and nothing else |

**Attribution.** The method behind this brief is distilled from the public
teaching of Alex Hormozi. The diagnosis, the numbers and the call are ours.

**Provenance of every figure marked *measured*:** two read-only `rails runner`
queries against `turf-monster-mainnet` and one against `mcritchie-studio`, run
2026-09-20. Code facts cite `file:line` in `/Users/alex/projects/turf-monster`
and `/Users/alex/projects/mcritchie-studio`. No code was changed.

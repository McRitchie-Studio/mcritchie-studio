# SOP — Constraint Diagnosis

**Owner:** Rex · **Runs:** at the start of every engagement, and any time someone
asks "what should we do about marketing?"

Run it start to finish from this file.

---

## What changed from v1, and why

v1 put delivery capacity and measurement at the top of a single ranked list and
said "the first row that trips is the constraint; do not continue down the
table." That produced three distinct failures:

1. **Capacity tripped on inference.** The corpus states it as a question you ASK
   the owner. v1 let Rex trip it on his own guess, stop, and never reach the real
   answer.
2. **The table could not express "underpriced."** Every row detected a *failure*
   signal. Underpricing emits the opposite — everything sells — so an underpriced
   business tripped nothing and fell through to "scale the winner," the trap.
3. **The funnel ended at first purchase.** Nothing named retention or rebooking
   as an entry point, though most of the money in a mature business is there.

The deeper error: **capacity and measurement are not constraints at all.** They
are conditions on your ability to *act*, and measurement is structurally
unfalsifiable — so a first-match search always stops there, and most small
businesses have no attribution.

---

## Step 0 — Refuse to start without the numbers

If asked for advice without data, do not guess. Reply with the shortest list of
what you need and why each changes the answer. A guess delivered confidently is
the most expensive thing a CMO produces, because the company acts on it for a
month.

**If the business has no numbers at all, that IS the finding** — but see the
measurement gate below, which is narrower than it looks.

## Step 1 — Take the numbers

Stop at the first one they cannot answer; that gap is usually the diagnosis.

| # | The question | Why it moves the answer |
|---|---|---|
| 1 | How many people saw anything we published last month? | Volume problem or conversion problem |
| 2 | How many became a lead? | The first real conversion |
| 3 | How many bought? | The second |
| 4 | What does one customer pay, first purchase? | What we can spend to get one |
| 5 | What does one customer pay over their life? | What we can spend to get one, correctly |
| 6 | What did we spend to get them — money and hours? | Without it, "it's working" is a feeling |
| 7 | How long from spend to money back? | Scale, or merely sustain |
| 8 | How many times did we publish or reach out? | The rep count — the thing we control |
| **9** | **How did you arrive at that price, and when did you last test it?** | **New in v2. No other question can detect underpricing, because underpricing looks like success** |

Record the answers with a date. An undated number becomes a permanent belief.

## Step 2 — The two gates

**These are not constraints. They gate specific ACTIONS, and nothing else.** Read
each one's scope literally; a gate that stops more than its scope is how v1
failed.

### Gate A — Delivery capacity. Gates DEMAND CREATION.

> **"Can you handle 20 people a week?"**

Ask capacity, not sales — people answer capacity honestly and sales
optimistically.

**It trips only on evidence:** the owner's own "no", or a measured capacity
figure. **An inference from low marketing spend is not evidence.** And before it
trips at all: **check historical peak throughput. If the business has ever
delivered more than it delivers now, the gate does not trip** — you are looking
at a demand problem wearing a capacity costume.

When it genuinely trips, do not create demand. Everything else still runs.

Two follow-ups worth asking in the same breath: *what breaks first at 2x, 5x,
10x?* and *what is the worst case, specifically?*

### Gate B — Measurement. Gates SPEND. Nothing else.

Measurement gates **changes to spend on an unmeasured channel**. It does **not**
gate price, the offer, retention, or any move that is reversible, non-rival, and
priced off numbers you already trust.

It fires only when the unmeasured channel is **material to the decision in
hand**. A channel at half a percent of revenue does not get to stop the company.

When it trips, the prescription is instrumentation — and the rest of the
diagnosis continues in parallel.

## Step 3 — The ranked search

Walk in order. The first row that trips is the constraint. Do not collect five.

| Order | Trips when | The constraint is | Do not |
|---|---|---|---|
| 1 | The offer gets a shrug from people who match the target | **The offer** | Touch copy, channel or budget |
| 2 | **Thin net margin AND never tested AND it sells without resistance AND the market is not the ceiling** | **Price** | Add volume to a margin that cannot carry it |
| 3 | Active base ÷ new customers per month gives an average life shorter than about twice the product's implied repurchase cadence — **or** the next purchase is produced by a request rather than a mechanism | **Retention / monetizing the existing base** | Buy new customers to fill a leaking bucket at full price |
| 4 | Reps per week are in single digits | **Volume** | Optimize conversion on a sample this small |
| 5 | Plenty of reach, almost no leads | **The ask** | Buy more reach |
| 6 | Plenty of leads, few sales | **Conversion / follow-up** | Buy more leads |
| 7 | Cost per customer exceeds what one is worth | **Unit economics** | Scale spend — you are buying losses faster |
| 8 | All healthy | **Scale the winner** | Reinvent |

**Row 2 is inverted on purpose.** Every other row detects a failure. Price
detects a success that came too easily, which is why no failure-shaped row can
ever see it.

**Say the constraint out loud, in one sentence, with the number that found it.**

## Step 4 — Prescribe one move, plus the price check

**One move against the constraint**, with:

1. **The action** — concrete enough to start in ten minutes.
2. **The volume** — how many, by when.
3. **The prediction** — what moves, roughly how much, and what would prove the
   diagnosis wrong.

**And, every time, outside the one-move budget: report whichever price signals
are firing.** A price move competes with nothing — no cost, no capacity, no new
system — and it reads out in the same window as the constraint test. Withholding
it to honour a one-move rule is how a v1 diagnosis left the largest free lever on
the table.

## Step 5 — Two rules about what you may defer

- **You may not park a row whose number you have not obtained.** Deferring a row
  you have measured is judgement. Deferring one you have not is a blank cell
  where the answer lived.
- **Before parking anything, ask: is it reversible, non-rival, and priced off
  numbers I already trust?** If all three, it runs in parallel rather than
  waiting.

## Step 6 — Hand off

Execution and voice → **Mason**. Visuals → **Shannon**. Claims about the product
→ **Avi**. Anything needing a code change rides the DevOps cycle like any other
work.

## Step 7 — Read the result against the prediction

Did the number move? By how much? Was the prediction high, low, or right — **say
which.** A CMO with no wrong predictions on the board is not measuring.

Then run this SOP again. It is a loop, not an onboarding.

---

## Citing a card

Before a card justifies a decision, **quote the line being relied on.** If the
quote does not say what is needed, the card does not support the decision.

In eval round one Rex cited two cards to support the *opposite* of what they say,
both inside the paragraph carrying his conclusion. A citation that is never
opened is decoration, and decoration is how a wrong answer acquires authority.

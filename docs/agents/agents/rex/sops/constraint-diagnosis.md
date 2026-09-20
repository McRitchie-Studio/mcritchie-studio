# SOP — Constraint Diagnosis

**Owner:** Rex · **Runs:** at the start of every engagement, and any time someone
asks "what should we do about marketing?"

This is the whole job compressed into one procedure. Everything else Rex does is
downstream of getting this right, and the most common way to get it wrong is to
skip to step 4 because the answer felt obvious.

Run it start to finish from this file.

---

## Step 0 — Refuse to start without the numbers

If asked for advice without data, do not guess. Reply with the shortest possible
list of what you need and why each one changes the answer. A guess delivered
confidently is the most expensive thing a CMO produces, because the company acts
on it for a month.

The exception: **if the business has no numbers at all, that IS the finding.**
Stop the diagnosis and prescribe instrumentation. An uninstrumented business
cannot be advised, only guessed at, and you will be re-guessing every week
forever.

## Step 1 — Take the numbers

Ask for these, in this order. Stop at the first one they cannot answer, because
that gap is usually the diagnosis.

| # | The question | Why it moves the answer |
|---|---|---|
| 1 | How many people saw anything we published last month? | Separates a volume problem from a conversion problem |
| 2 | How many became a lead — gave us a way to contact them? | The first real conversion |
| 3 | How many bought? | The second |
| 4 | What does one customer pay, first purchase? | Sets what we can spend to get one |
| 5 | What does one customer pay in total, over their life? | Sets what we can spend to get one, correctly |
| 6 | What did we spend to get them — money and hours? | Without this, "it's working" is a feeling |
| 7 | How long from spend to money back? | Determines whether we can scale or only sustain |
| 8 | How many times did we publish or reach out? | The rep count, the thing we actually control |

Record the answers with a date. Numbers go stale; an undated number becomes a
permanent belief.

## Step 1b — Ask the delivery ceiling before you sell anything

> **"Can you handle 20 people a week?"**

Ask what the business can actually deliver before prescribing anything that
creates demand. Phrase it as capacity, not as sales — people answer capacity
questions honestly and sales questions optimistically.

This step is in the SOP because the corpus put it there. It was missing from the
first draft of this file, which went straight from the numbers to the funnel
math, and that omission is the classic way a marketing plan damages a business:
demand arrives, delivery buckles, and the reputation cost outlives the campaign.

Two follow-ups worth asking in the same breath:

- **"What would break first at 2x, 5x, 10x?"** Isolate that thing, fix it, then
  push volume.
- **"What is the worst case, specifically?"** In detail, not as a feeling. A
  named worst case is usually survivable and a vague one never feels it.

For a business whose delivery is physical — a welding floor, say — this is not a
formality. It is frequently the real constraint, and no amount of marketing
fixes it.

## Step 2 — Do the division in public

Compute and SHOW:

- **Leads ÷ reach** — are we asking?
- **Sales ÷ leads** — are we closing?
- **Lifetime value ÷ acquisition cost** — is growth paying for itself?
- **Reps ÷ week** — are we in the game at all?

Write the arithmetic where the operator can see it. A conclusion someone cannot
check is a conclusion they cannot disagree with, and disagreement is the point.

## Step 3 — Locate the single constraint

Walk this in order. The FIRST row that trips is the constraint. Do not continue
down the table collecting more problems — you will find them, and naming five
constraints is the same as naming none.

| Order | Trips when | The constraint is | Do not |
|---|---|---|---|
| 0 | The business cannot deliver the demand it already has | **Delivery capacity** | Market. You would be selling a bad experience at scale |
| 1 | Nobody can say what happened to last month's work | **Measurement** | Make anything new. Instrument first |
| 2 | The offer gets a shrug from people who match the target | **The offer** | Touch the copy, the channel, or the budget |
| 3 | Reps per week are in single digits | **Volume** | Optimize conversion on a sample this small |
| 4 | Plenty of reach, almost no leads | **The ask** | Buy more reach |
| 5 | Plenty of leads, few sales | **Conversion / follow-up** | Buy more leads |
| 6 | Sales fine, but cost per customer exceeds what one is worth | **Unit economics** | Scale spend. You are buying customers at a loss faster |
| 7 | All of the above are healthy | **Scale the winner** | Reinvent. Do more of the thing that works |

**Say the constraint out loud, in one sentence, with the number that found it.**
If you cannot say it in one sentence, you have not found it.

## Step 4 — Prescribe exactly one move

One. With three things attached:

1. **The action** — concrete enough that someone could start it in ten minutes.
2. **The volume** — how many, by when. "Post more" is not a prescription; "40
   posts by the 30th, same offer, different hooks" is.
3. **The prediction** — what number will move, by roughly how much, and what
   result would prove the diagnosis wrong.

If the prescription needs a thing that does not exist yet (a landing page, a
tracking link, a form), that dependency is part of the prescription and gets a
date too.

## Step 5 — Hand off cleanly

- Execution and voice → **Mason**.
- Anything visual → **Shannon**.
- Claims about what the product does → check with **Avi** before it ships.
- Anything that needs a code change → it rides the DevOps cycle like any other
  work. Rex does not get an exemption for being in a hurry.

## Step 6 — Read the result against the prediction

Two weeks later, or at the date you set:

- Did the number move? By how much?
- Was the prediction right, high, or low?
- **Say which.** A CMO who never records a wrong prediction is not measuring, and
  the next diagnosis will be built on the same error.

Then run this SOP again. It is a loop, not an onboarding.

---

## Background — not needed to execute

The order of the table in step 3 is doctrine: measurement before offer, offer
before volume, volume before optimization. The reasoning is that each row is
cheap to fix relative to the one below it and invalidates the work you would
otherwise do underneath it. Fix conversion on a broken offer and you will
re-learn the same lesson at ten times the spend.

Card-level backing for the individual diagnostics — which numbers he asks for
first, in his words, with sources — lives in [`../knowledge/`](../knowledge/README.md).

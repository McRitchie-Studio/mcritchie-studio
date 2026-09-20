# Turf Monster — constraint diagnosis

**From:** Rex · **Date:** 2026-09-19 · **SOP:** [`constraint-diagnosis`](../sops/constraint-diagnosis.md)
· **Status:** diagnosis complete, one move prescribed, awaiting the numbers I asked for

---

## The short version

**I can't tell you whether your marketing works, and neither can you.** That is
not a criticism of the marketing — it is the finding. You have a working
publishing machine attached to nothing that reads the result, so every post is an
opinion and every week ends in an argument instead of a number.

**The constraint is measurement.** Not creative, not volume, not the offer.
Nothing else is worth an hour until this is fixed, because until it is, you cannot
tell whether the next hour worked.

---

## Step 1 — The numbers I asked for

| # | Question | What the system can answer today |
|---|---|---|
| 1 | How many people saw anything we published last month? | **Only if someone typed it in.** `views` is a column a human fills from a form |
| 2 | How many became a lead? | **No such concept exists.** There is no lead, no list, no capture step between a post and an entry |
| 3 | How many bought — entered a contest? | Yes. The app knows its entries |
| 4 | What does one entrant pay, first entry? | Yes |
| 5 | What is an entrant worth over their life? | **Unknown.** Nothing links entries across contests into a customer |
| 6 | What did we spend to get them? | **Unknown.** No spend is attributed to any post |
| 7 | How long from spend to money back? | Unanswerable without 5 and 6 |
| 8 | How many times did we publish? | **Countable but not counted.** The records exist; nobody totals them |

**Four of eight are unanswerable, and they are the four that decide everything.**

## Step 1b — The delivery ceiling

> *"Can you handle 20 people a week?"*

Asked and cleared. This is software with automated settlement; the delivery
ceiling is not the constraint, and a hundred new entrants next week would be a
good problem rather than a broken one.

I am recording that I checked, because for one of your other clients — the
welding shop — this question does not clear, and the two businesses must not get
the same prescription by default.

## Step 2 — The division

Not possible. Leads ÷ reach has no numerator and no denominator. LTV ÷ CAC has
neither term.

**A CMO who produces a plan from this position is guessing and dressing it up.**
I am not going to do that.

## Step 3 — The constraint

**Row 1: measurement.** From the SOP's table — *"nobody can say what happened to
last month's work."*

The evidence is in the code, not in a hunch:

- `views`, `likes`, `comments_count` and `shares` exist on the content record and
  are populated **by a human typing into a form**. Nothing calls X or TikTok to
  read them back.
- There is no campaign, no scheduled posting, and no link between a post and an
  entry. A post and a signup are two unrelated facts in the same database.
- `News::ConcludeAgent` generates three content ideas per article, and **nothing
  in the system ever reads them.** You are paying a model to have ideas into a
  void.

One more finding, free: **the front door describes last season's product.** The
public README opens with *"Sports pick'em game for the FIFA World Cup 2026"*. The
World Cup finished in July; the running product is NFL — 33 files against 14.
Whatever we decide the positioning is, the first sentence a curious person reads
is currently wrong.

## Step 4 — The one move

**Instrument the loop before making anything else.** Specifically, and in this
order:

1. **A distinct link per post.** Every published item gets its own trackable
   destination. Without this, step 3 is unanswerable forever and everything
   below is decoration.
2. **Record where an entrant came from**, captured at entry and stored on the
   entry.
3. **Read performance back automatically** — views and engagement pulled from the
   platform rather than typed. If the API access is not ready, a fixed weekly
   manual read at a named time, owned by a named person, is an acceptable
   version one. An unscheduled intention is not.
4. **One number on one screen**: entries this week, and which posts preceded
   them.

**Volume and date:** all four in place before the next contest closes. This is a
week of work, not a quarter, and it rides the normal task board like anything
else — I do not get an exemption for being in a hurry.

**Prediction:** this produces **no lift at all** in the next two weeks. That is
expected and it is not a failure. What it produces is the ability to run the
first real test in week three, against a number instead of a feeling.

**What would prove me wrong:** if you can already answer questions 1, 5 and 6
from a source I have not found, then measurement is not the constraint, I have
misread the system, and the diagnosis should restart at row 2 — the offer.

## Step 5 — Handoff

- **Mason** — hold. There is no copy problem to solve this week, and asking him
  for volume now would be asking him to work blind.
- **The engineering lane** — items 1 to 4 are tasks on the board, shaped and
  sized like any other work.
- **Turf Monster (the soul)** — one question I need answered before the week-three
  test: which is the product, "NFL pick'em" or "a pick'em engine that follows the
  season"? Every headline for the next two years inherits that answer.

## Step 6 — Read the result

Scheduled for the close of the next contest. The question at that review is not
"did engagement improve" — it is **"can we now answer questions 1, 5 and 6?"**
If the answer is no, the instrumentation failed and we fix it again rather than
moving on.

---

## The corpus behind this

Cards used: [`diagnostic-questions`](../knowledge/diagnostic-questions.md),
[`core-four`](../knowledge/core-four.md),
[`unit-economics`](../knowledge/unit-economics.md).

The capacity question in step 1b, and the order of the constraint table, both come
from the corpus rather than from my first draft of the SOP — which went straight
from the numbers to the funnel math and would have prescribed demand to a business
without asking whether it could serve any.

# How we find out whether Rex actually learned anything

A CMO built from a corpus has one characteristic failure: he quotes beautifully
and diagnoses badly. He will produce the Value Equation on demand and still tell
a business with no measurement to buy ads. Cards cannot detect that. Only a case
he has never seen can.

## The instrument

The corpus contains a genre he repeats: a live teardown where a real owner brings
a real business, states real numbers, and gets a diagnosis and a prescription
inside an hour. That is an evaluation set that already has answers in the back.

**Five of those videos were held out before any extraction ran**, and are listed
in `~/projects/.corpus/hormozi/meta/holdout.txt`. No card cites them, and the
extraction brief instructs every agent to skip them. They stay sealed.

| Held out | Words |
|---|---|
| `-Koq14DPXC4` — Building a $2,300,000/yr Business for a Stranger in 57 Mins | 12,702 |
| `BMF2fWHyDrg` — Building a $3,500,000 Business for a Stranger in 51 Mins | 11,685 |
| `n6SHLmKcY0E` — Building a $3,000,000 Business for a Stranger in 57 Mins | 13,523 |
| `nrounb8NlFQ` — Building a $1,000,000 Business for a Stranger in 56 Mins | 12,652 |
| `sBJppqCeFGI` — Building a $5,000,000 Business for a Stranger in 42 Mins | 10,155 |

## The procedure

1. **Build the situation card.** An agent reads one held-out transcript and
   writes two files: the SITUATION (the business, the numbers the owner states,
   the owner's own theory of their problem — and nothing else) and the SEALED
   ANSWER (the constraint he named, the prescription he gave, the order he did it
   in). The sealed answer is not shown to Rex.
2. **Run Rex against the situation**, through
   [`sops/constraint-diagnosis.md`](sops/constraint-diagnosis.md), with his cards
   available and the sealed answer absent.
3. **Score**, with a third agent holding both.

## The scorecard

| # | Question | Why it is scored separately |
|---|---|---|
| 1 | Did Rex refuse to advise on missing numbers, or did he guess? | This is a PROCESS property and it should be perfect. A CMO who guesses is worse than no CMO, and this failure is independent of how much he knows |
| 2 | Did he name the same constraint? | The actual test. Everything else is downstream of this one call |
| 3 | Is the prescription compatible with the one given? | Not identical — compatible. Two competent people prescribe differently from the same diagnosis |
| 4 | Did he attach a number and a date? | A prescription without those is an opinion |
| 5 | Did he cite cards, and do the citations hold up? | Catches the failure where he sounds right for invented reasons |

## The bar for version one

- **Question 1: 5 of 5.** No exceptions. Guessing is the one failure that makes
  him dangerous rather than merely wrong.
- **Question 2: 3 of 5.** Honest for a first build. If it is 5 of 5 on five
  cases, suspect leakage before celebrating — check that the video really was
  held out.
- **Questions 3-5: report, do not gate.** They tune the prompt; they are not a
  pass/fail on the corpus.

## What this eval cannot tell you

Five cases detect gross failure, not fine differences. A 3/5 and a 4/5 are the
same number at this sample size. It answers "did we build a quote machine?" —
which is the question that matters now — and it does not answer "is Rex better
than last week?" That needs a bigger set, and the corpus can produce one: the
teardown genre runs to dozens of videos.

Also: **all five cases are his own teardowns, so the eval scores agreement with
him, not correctness.** Where his method is wrong, a perfect score is a perfect
reproduction of the error. That is the deal we signed when we chose to build a
specific person's method, and it is why Rex's own doctrine says the client's
numbers outrank the cards.

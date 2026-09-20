# Rex's knowledge — what it is and how to trust it

These cards are Rex's education. Each one was **read out of a transcript**, not
recalled from a model's prior about a famous person. That distinction is the
entire value of this directory, and it is worth a paragraph.

## Provenance

The source is roughly 600 hours of Alex Hormozi's publicly published video. The
pipeline:

1. `bin/hormozi-prep` cleans YouTube auto-captions into plain transcripts and
   tiers every video by how much marketing it teaches (`lib/hormozi/triage.rb`).
2. A wave of agents reads the tier-1 transcripts in full and extracts structured
   items under a strict rule: **only what the transcript says.** Anything the
   agent already believed, and could have written without reading, is discarded.
3. `bin/hormozi-bundle` groups items across the whole corpus by idea and ranks
   them by **how many different videos say the same thing** — so the corpus
   itself decides what is doctrine, rather than a model's impression of what the
   man is known for.
4. Each card below is written from one bundle and cites the video ids behind it.

The transcripts and extraction files live **outside the repo** at
`~/projects/.corpus/hormozi`. They are not ours to redistribute; see
[`../role.md`](../role.md) § What Rex is not.

## The cards

| Card | What it answers | Videos behind it |
|---|---|---|
| [`diagnostic-questions`](diagnostic-questions.md) | What he asks before advising anything. **Rex's intake — start here** | 23 |
| [`unit-economics`](unit-economics.md) | LTGP:CAC, the 3:1 rule and its conditions, payback, what ratios mean | 18 |
| [`offer-construction`](offer-construction.md) | What makes an offer work, and when to raise price | 16 |
| [`audience-and-avatar`](audience-and-avatar.md) | Who you are talking to, and how the audience tells you what to make | 16 |
| [`volume-and-repetition`](volume-and-repetition.md) | Why reps beat ideas, and the switch rule from more to better | 15 |
| [`scaling-order`](scaling-order.md) | More/Better/New, the roadmap stages, what breaks at 2x/5x/10x | 9 |
| [`where-he-contradicts-himself`](where-he-contradicts-himself.md) | The six places the ground moves. **Check before quoting doctrine** | 6 |
| [`x-factor`](x-factor.md) | How he operates — the part that is hardest to copy | 6 |
| [`core-four`](core-four.md) | The only four ways to let people know | 2 |

Not yet written, and known to be missing: **paid ads**, **email**, **affiliates
and referrals**, and the **content production system**. The corpus holds strong
material for all four (batches b07 and b08). Also missing, and NOT in the corpus
at all: **hook craft, thumbnails, titles and platform-specific formats** — two
extraction agents looked and reported the gap independently. If Rex is asked for
a hook formula, he should say he does not have one rather than improvise.

## How to read a card

| Field | What it means |
|---|---|
| **Sources** | How many distinct videos this idea appears in. Higher means he keeps returning to it |
| **The claim** | The idea in one sentence |
| **The mechanism** | Steps, parts, or the arithmetic. A card with no mechanism should not exist — that was the extraction bar |
| **When it applies** | And when it does not. Ignoring this is how a good framework becomes a bad decision |
| **Contrarian** | Marked where it cuts against standard marketing advice, or against something he says elsewhere |
| **Fit** | Which of the three clients it plausibly serves |
| **In his words** | A short verbatim line, capped at 25 words, so Rex can be direct rather than so we can republish a man's work |

## What a high source count does and does not prove

It proves **repetition**, which is a good proxy for what he considers
foundational and a bad proxy for what is true. He is one practitioner with one
set of businesses behind his conclusions. A card with sixteen sources is
something he believes hard, not something physics guarantees.

Rex uses the cards as a **prior**, and the client's own numbers as **evidence**.
Where they disagree, the numbers win. A CMO who quotes doctrine at data is a
fan, not an advisor.

## Verifying the citations

A card that cites a video which does not exist is the failure this whole
directory is built to avoid, and it is invisible to a reader. Check it:

```bash
cd docs/agents/agents/rex
jq -r '.items[].source_id' ~/projects/.corpus/hormozi/extract/b*.json | sort -u > /tmp/corpus_ids.txt
grep -rhoE '`[A-Za-z0-9_-]{11}`' knowledge/ briefs/ EVAL.md | tr -d '`' | sort -u > /tmp/cited_ids.txt
comm -23 /tmp/cited_ids.txt /tmp/corpus_ids.txt
```

**The only ids that may legitimately appear there are the five held-out videos**
(`~/projects/.corpus/hormozi/meta/holdout.txt`), which EVAL.md names on purpose
and which no card may cite. Anything else is an invented citation — delete the
claim, do not go looking for a source that fits it.

Note that one held-out id begins with a hyphen, so compare with
`grep -qxF -- "$id"`; a bare `grep -qx "$id"` reads it as a flag and reports a
real citation as invented.

Last run 2026-09-19 against all 8 extraction batches: **48 corpus videos, 39
cited ids, 5 expected held-out, 0 invented.**

A caution for whoever runs the next synthesis wave: an agent reported these same
cards citing four ids that "do not exist." They did — it had globbed the
extraction directory before the last batch landed and was reasoning from a
partial corpus. **Re-check before believing a citation failure**, and re-check
before dismissing one.

## One caveat about numbers

The transcripts are machine-made from audio, and **the machine mis-hears dollar
magnitudes**. Extraction caught "a $4,600 exit" and "a $106,000 book launch in a
weekend" in videos where the correctly-transcribed figure elsewhere is $46.2
million. Those items were written without the corrupted number rather than
repaired.

So: a number on a card is as good as one pass of speech recognition. **Before a
number leaves this building — into a plan, a pitch, or a post — check it against
a second source.** Ratios and orders of magnitude survive the noise; exact
figures do not always.

## Staleness

His material spans years and his positions moved — early gym-business content,
later scaling content, later still the money-model work. Cards carry the video
they came from, so when two cards conflict, check which is newer before
averaging them. **Two conflicting cards are a finding, not an error** — usually
they mark a condition boundary neither card states.

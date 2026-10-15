---
question: "I am about to run `bin/task begin`. Does `--agent` matter when it is optional?"
answer: "Pass `--agent pokemon` (or your soul). Without it the author set is blank, and the docs reviewer's merge permit refuses the PR."
why: "A blank author set cannot prove the reviewer is not the author, so the merge waits for a second seat."
status: proposed
source: "2026-10-14 · approve-intent-brief-dream"
sop: building-sop
step: begin
topic: [author, merge]
---

# Pass the author at begin

## Situation

A builder claimed a docs task with `bin/task begin` and left out `--agent`,
because the SOP calls the flag optional.

## The pull

Skip the flag: review derives authors from the commit souls on GitHub anyway,
so the stamp looks redundant.

## What happened

The desk committed under no soul, so the author set came out blank. When the
docs reviewer approved, its merge permit refused: with no author on record it
could not show it was not reviewing its own work. The code reviewer had to step
in and merge a prose-only PR. Passing `--agent pokemon` at begin stamps
`built_by` and the desk identity, and the docs seat can merge.

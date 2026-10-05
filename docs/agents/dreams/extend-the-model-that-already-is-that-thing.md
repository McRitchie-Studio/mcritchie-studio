---
question: "The plan calls for a new table. Do I design it?"
answer: "First look for the model that already is that thing under another name. Extend it, and keep variants as a column, not as sibling tables."
why: "A parallel table forks the data in two and every reader has to learn which half is true."
status: approved
source: "2026-09-17 \u00b7 session 64edbffd"
---

# Extend the model that already is that thing

## Situation

A knowledge-layer plan asked for an artifacts table and two kinds of communications table.

## The pull

Build what the plan names; it is what was asked for.

## What happened

Showed that the existing knowledge-doc model already held over a hundred such records and only lacked a live binding, and that the two communication kinds were one table with a `kind` column. Alex took both calls.

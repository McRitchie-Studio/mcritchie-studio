---
question: "A review turns up something pre-existing and outside the diff. Is it out of scope?"
answer: "Provenance is not consequence. Ask whether the change makes anything new depend on the broken thing; if it is serious, put it at the top of the report before the status."
why: "Four agents once called a defect out of scope, correctly, and three passes later it was what blocked the PR."
status: approved
source: "2026-09-15 and 2026-09-23 \u00b7 session 012a2087, task reuse-key-collides-empty-look"
---

# Lead with the finding that outranks the work

## Situation

A reviewer found an archived runbook that still handed out the steps for a retired key. It was older and worse than anything in the PR.

## The pull

File a follow-up card and report 'seven tasks merged'.

## What happened

The report opened with 'one finding you should see before I go further', ahead of the merge count.

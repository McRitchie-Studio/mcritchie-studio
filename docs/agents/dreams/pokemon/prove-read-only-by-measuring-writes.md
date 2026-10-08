---
question: "I am about to run an audit against production and call it read-only. What makes that true?"
answer: "A test that subscribes to the query layer over a full run and asserts zero writes, and also asserts that the run queried at all."
why: "A grep for `save` and `update` proves today's spelling. It cannot see a callback or a raw execute, and a test that never queried passes for nothing."
status: approved
source: "2026-09-22 \u00b7 task audit-turf-merged-athlete-rows"
soul: pokemon
shape: backend
topic: [audit, production]
---

# Prove read only by measuring writes

## Situation

An audit service needed to read merged rows in production.

## The pull

Read the source, see no writes, and say it is safe.

## What happened

Marked the relations read-only as a defence, then proved it with the subscription test and the did-it-query assertion.

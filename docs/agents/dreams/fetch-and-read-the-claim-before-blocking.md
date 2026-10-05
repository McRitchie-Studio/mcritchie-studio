---
question: "A task depends on a file that is not on `accepted`. Do I mark it blocked?"
answer: "Fetch first, then read the ref again. Then read the task's claim. Only write the blocker if both still say so."
why: "A stale ref blocked a task six minutes after its dependency merged, and stamped 'unresolved feedback' onto a live session's in-progress work."
status: proposed
source: "2026-08-27 \u00b7 task workflows-card-fifth-soul"
---

# Fetch and read the claim before blocking

## Situation

A dependency check answered from the last fetch, which predated the merge.

## The pull

The command said the file is missing; record the blocker and move on.

## What happened

The session that got it wrong retracted the block and wrote down the two checks. Later sessions run them in that order.

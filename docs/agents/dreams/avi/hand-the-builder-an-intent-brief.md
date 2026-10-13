---
question: "A builder is mid-build; what do I hand them?"
answer: "The two-list intent brief, not a code review: SAME INTENT, DO NOW (every surface the acceptance touches that the builder may miss) and WIDER SCOPE, FOLLOW-UP (one proposed card). Post it on the task and touch nothing."
why: "A twelve-minute red CI round was one missed test file the intent named; a mid-build review slows the builder and duplicates Carl."
status: proposed
source: "2026-10-13 · team-tier-nine-hundred, avi-intent-scout"
soul: avi
stage: building
topic: [intent, scout, brief]
---

# Hand the builder an intent brief, not a review

## Situation

A builder is changing the Team tier price on `/packages` and has not submitted yet.
Avi is asked to help while the build runs.

## The pull

Read the diff in the desk and review it, or add the related improvements spotted
along the way to the task.

## What happened

The builder missed `test/views/stack_view_test.rb`, which also pinned the old price,
and paid a red CI round. Reading the intent ("the Team tier reads $900") and grepping
the value across every test directory would have named that file before the push.
The answer is a short brief in two lists on the task: the same-intent gaps to fold in
now, and one follow-up card for everything wider. The builder decides; Carl reviews
the code later.

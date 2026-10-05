---
question: "A balance on screen looks wrong after money moved. Where do I start?"
answer: "With arithmetic on the real numbers. Subtract the before from the after; if the difference is exactly the amount that moved, the money is right and the display is stale."
why: "It splits 'the money is wrong' from 'the screen is wrong' in one step, before any theory about websockets or the chain."
status: approved
source: "2026-09-07 \u00b7 session 0bc673df"
---

# Reconcile the numbers before theorizing

## Situation

After creating a contest, the navbar balance had not dropped. The first suspect was the live-update socket.

## The pull

Debug the websocket, the most complicated part in sight.

## What happened

Compared the wallet before and after: the gap equalled the prize pool to the dollar. The navbar read a 60-second cache that seven money paths bust and contest creation did not. One line fixed it.

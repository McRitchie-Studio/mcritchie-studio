# Dream Swap — put the pending dream decisions to Alex
<!-- registry: print the dream cards (adds, swaps, retires) for Alex and record his answer with his words -->

## Status: Active

**Purpose.** Put every dream decision that waits on Alex to him in one message, in
the card standard, and record his answer. The bank holds the good answers past
sessions gave; it stays good only if he rules on what comes in and what goes out.

**When.** Alex says `dream-swap`. The same cards end the Dreams step at wrap
([`wrap-it-up.md`](../../pokemon/sops/wrap-it-up.md), `/wrap`), where they
show at most one swap.

**Who.** Any session. Recording a ruling needs a session id (Claude Code and Codex
set one) and the board.

**Detail.** The card standard, the reply grammar and the chat ruling:
[`dream.md`](../../../modules/dream.md#the-card-standard), Act 3.

## Steps

1. **Print the cards.**

   ```bash
   /Users/alex/projects/.agents/bin/dream cards
   ```

   It prints a card for every proposed dream no ruling has answered (ADD when its
   layer has room, SWAP with the layer's top-ranked out when it is full), then a
   RETIRE card for each approved dream whose grades say it misleads (mean under 0.5
   over two or more grades). It reads the swap candidates and the pending rulings
   from the board; when the board is silent it says so on stderr and prints this
   bank's own counts.

2. **Also check the unmaterialized proposals.** A ship-time proposal is a triage
   finding until a desk writes its file (`bin/triage list --status open`, slugs
   `dream-proposal-*`). Materialize the ones worth a card first ([`dream.md`](../../../modules/dream.md),
   Act 2); a finding has no card.

3. **Make each call.** For every card, decide approve, change or drop, with a
   one-line reason. First apply the test: **a must-do belongs in a command, not a
   dream.** If a command could enforce the answer, call drop and name the command.
   Re-run with your calls so the message carries them:

   ```bash
   /Users/alex/projects/.agents/bin/dream cards --call <slug>=approve:"<reason>" --call <slug>=drop:"<reason>"
   ```

4. **Send it as it prints.** The idea line, the numbered cards, the reply grammar
   last. Add nothing between the cards. Nothing waiting prints one line; send that.

5. **Record his answer, with his words.**
   - `yes` takes every call: record each card's call.
   - `1 ✓ 2 ✗ 3 ✎ <edit>`: ✓ takes that card's call; ✗ refuses it, so nothing is
     recorded for that card unless his words say what to do instead; ✎ takes the
     call with his edit, which you make in the file in a desk first.
   - Plain words: read them against the cards, and ask when one is unclear.

   ```bash
   /Users/alex/projects/.agents/bin/dream approve <slug> --clearance "<his exact words>"
   /Users/alex/projects/.agents/bin/dream drop    <slug> --clearance "<his exact words>"
   /Users/alex/projects/.agents/bin/dream retire  <slug> --clearance "<his exact words>"
   ```

   A SWAP is two rulings: `approve` the in and `retire` the out. The command
   refuses an empty clearance, the slug alone, and fewer than three words, except
   the grammar tokens (`yes`, `1 ✓`). A dream only in your desk is ruled in its
   file ([`dream.md`](../../../modules/dream.md), Act 3).

6. **Silence changes nothing.** No reply is no ruling. Do not record, and do not
   re-ask in the same session; the cards come back at the next wrap or
   `dream-swap`.

7. **Report what was recorded.** One line per ruling, as `bin/dream` printed it,
   then: "The next batch task writes them into the files (`bin/dream
   apply-approvals`)."

## Never

- Never record a ruling Alex did not give in this session, and never paraphrase
  his words into the clearance.
- Never approve on your own judgment. A card's "My call" is advice; his reply is
  the ruling.
- Never default a dream on silence.

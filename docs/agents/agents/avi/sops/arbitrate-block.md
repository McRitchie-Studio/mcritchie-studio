# Arbitrate Block

## Status: Active

This is Avi's `arbitrate-block` SOP. A builder has contested a review block
with evidence, and Avi rules on it: the block stands, the block is overruled,
or it is split. Avi is the authority. Only a policy question he cannot settle
goes to Alex.

## Scope

One task, one contested block. Avi reads the block, the builder's position, the
diff, and the task's acceptance, reproduces what can be reproduced, and records
a ruling on the task. This SOP never merges, never moves a task past
`submitted`, never deploys, and never spends a review bounce of its own.

## Entry

Run from the McRitchie Studio primary checkout, as Avi:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Verify --agent avi --task <slug> --reason "arbitrate: <slug>"
```

Use the production board. Do not pass `--local`.

## Preconditions

- The task carries a live `rework` block from a reviewer.
- The task carries a `clarification` note beginning `CONTEST:` from the
  builder, with evidence: a test, a measurement, prior art, or a reading of the
  acceptance. A contest with no evidence is returned unread: post
  `bin/task note <slug> --comment "arbitration declined: no evidence in the contest; state what you measured" --agent avi`
  and stop.

## Procedure

1. **Read the block.** Summary and details, and the reviewer who raised it:

   ```bash
   bin/task show <slug> --json | jq '.unresolved_feedback | {summary: .metadata.summary, details: .description, by: .agent_slug}'
   ```

   Hold it in one sentence: the reviewer says the diff does X, and X is wrong
   because Y.

2. **Read the contest.** It arrives in your brief from the session that spawned
   you. Confirm it also landed on the task, because the ruling must cite a
   recorded note:

   ```bash
   bin/task show <slug> --json | jq '.latest_activity | {type: .activity_type, by: .agent_slug, text: .description}'
   ```

   That shows the contest when it is the newest note. When a later note has
   covered it, read the full thread on the task page,
   `https://mcritchie.studio/tasks/<slug>`, the operator-friendly source of truth
   for the conversation. A contest that is in neither your brief nor the thread
   is declined (Preconditions). Hold it in one sentence too: the builder says Y
   does not hold because Z.

3. **Read what they are arguing about.** The task's acceptance and
   `agent_context`, the epic plan if the context names one, and the diff:

   ```bash
   bin/task show <slug> -v
   gh pr view <pr> --json title,body,files
   gh pr diff <pr>
   ```

4. **Reproduce, do not adjudicate prose.** If the block names a trigger, run
   it against the PR head on a throwaway desk (never the builder's desk):

   ```bash
   REPO=/Users/alex/projects/<repo>; git -C "$REPO" worktree add "$REPO/.worktrees/arb-<slug>" --detach origin/<branch>
   cp "$REPO/.worktrees/<slug>/.env.test.local" "$REPO/.worktrees/arb-<slug>/" 2>/dev/null
   ```

   Run the reviewer's trigger and the builder's evidence there. Whichever
   claim survives contact with the tree is the one that wins. Remove the
   throwaway when done: `git -C "$REPO" worktree remove --force "$REPO/.worktrees/arb-<slug>"`.

5. **Rule.** Exactly one of three:

   | Ruling | When | What you record |
   |---|---|---|
   | **ACCEPT** | the regression is reachable as the reviewer said | the block stands; the builder fixes it per [`../../../modules/address-blocker.md`](../../../modules/address-blocker.md) |
   | **OVERRULE** | the builder's evidence holds and the block names no reachable regression | the block is cleared; the reviewer re-reviews with the ruling attached and may not re-raise the same finding |
   | **SPLIT** | part of the block is reachable, part is not | which part stands, in one line each |

   A style preference, a scope wish, or a hardening idea is never grounds to
   keep a block: those ride as notes, and the ruling says so.

6. **Record the ruling on the task**, always, in this shape:

   ```bash
   bin/task note <slug> --comment "RULING: <ACCEPT|OVERRULE|SPLIT> — <one sentence why>. Reviewer's claim: <X>. Builder's evidence: <Z>. Measured: <what step 4 showed>." --agent avi
   ```

   On **OVERRULE** or a **SPLIT** whose standing part is already fixed, also
   clear the block and hand it back to review:

   ```bash
   bin/task note <slug> --handoff "Block overruled by arbitration (see RULING). Re-review at head <sha>." --resolves-feedback --agent avi
   bin/task move <slug> submitted
   ```

   On **ACCEPT**, move nothing; the builder's resubmission clears it.

7. **A second block after arbitration is not a second bounce.** The two-bounce
   breaker counts send-backs; a block raised on the head that follows an
   ACCEPT is the same finding continuing, and a new finding after an OVERRULE
   is the reviewer's first on that head. The reviewer proceeds with
   `--breaker-ack "post-arbitration: <ruling>"` and the ruling's note as the
   reason. A reviewer who re-raises an overruled finding is refused by this
   SOP, not by the breaker: post `bin/task note <slug> --comment "re-raised an
   overruled finding; ruling stands" --agent avi` and hand the task back to
   review.

8. **Only a policy question goes to Alex.** If the disagreement is about what
   the product should do rather than what the code does, and the acceptance and
   the epic plan do not settle it, escalate with both positions in one note and
   start the 20-minute window:

   ```bash
   bin/task block <slug> --kind dependency --summary "Escalated: <4-6 word question>" \
     --feedback "POLICY QUESTION for Alex. Reviewer: <X>. Builder: <Z>. Avi's recommendation: <ruling I would make>. Window: 20 min from <time>; on lapse the recommendation stands." --agent avi
   ```

   The board derives the 20-minute window from `blocked_at` and shows it as a
   countdown chip on the card; put the same question to Alex in chat with the
   time, then wait on it:

   ```bash
   bin/task wait-window <slug>     # exit 0 answered (block cleared) · 2 lapsed · 1 board unreadable
   ```

   When it lapses without an answer, record the recommendation as the ruling,
   labeled `auto-decision`, clear the block, and continue.

9. **One learning, at most.** If the arbitration taught something a future
   builder or reviewer would use, one line:

   ```bash
   bin/task note <slug> --comment "LEARNING: <one sentence>" --agent avi
   ```

   Most arbitrations teach nothing new; write nothing then.

10. **Close the activity** with the ruling:

    ```bash
    bin/agent-activity end --outcome "<ACCEPT|OVERRULE|SPLIT|ESCALATED>: <one-line reason>"
    ```

## Exit seam

The ruling is on the task in the `RULING:` shape; the block is cleared or
standing accordingly; any escalation names its window; the throwaway desk is
gone. Report the ruling, what was measured, and who acts next: the builder
(ACCEPT), the reviewer (OVERRULE or SPLIT), or Alex (escalated).

## Related

- [`../../../modules/focus-session.md`](../../../modules/focus-session.md) — where a contest is raised.
- [`../../../modules/address-blocker.md`](../../../modules/address-blocker.md) — the builder's path after an ACCEPT.
- [`../../carl/sops/pr-review-primary.md`](../../carl/sops/pr-review-primary.md) — the review that raised the block.

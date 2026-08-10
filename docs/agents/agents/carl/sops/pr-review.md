# PR Review

## Status: Active

This is Carl's `pr-review` SOP — the Lead Architect owns PR review. It reviews
submitted PRs in bounded waves, and on a merge-ready verdict **merges the feat PR
into `accepted`** and stops the task at `reviewed` — the accepted-ladder's first
rung. Avi's `qa-release` sweep then promotes `accepted → release`.

**There is no Avi supervisor layer.** The driving SESSION is a Pokémon
orchestrator; it claims reviewable PRs and spins up **one Carl per PR**. Each Carl
is the deep/primary reviewer AND the OWNER of that review — he runs the gates,
launches a light specialist at his own discretion, drives the verdict, and (on a
merge-ready verdict) merges the PR himself.

## Scope

Carl owns the review end-to-end. On approval this SOP merges the feat PR into the
`accepted` branch (the ladder's first rung); it never merges to `release`/`main`,
deploys QA, ships production, or archives work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## The two levels — the session orchestrates, each Carl reviews and owns

Review runs in two levels; keep them distinct:

1. **Session Pokémon** (identity + orchestrator) — the base session driving the
   cycle. It claims reviewable PRs, spins one Carl per claimed PR in bounded
   waves, collects each Carl's verdict, and releases each review claim. **It does
   not review the code itself.**
2. **Carl (per PR)** — the **deep/primary reviewer AND review owner**, one instance
   per PR, spawned as a `carl` subagent. Carl does the deep technical review, owns
   the gates (`bin/dor-check`, cert/CI green, acceptance match), launches a **light
   specialist** at his own discretion (a domain pick — see below), collects that
   second read, drives the verdict, and on a merge-ready verdict **merges the feat
   PR into `accepted`** himself. Runs
   [`pr-review-primary.md`](pr-review-primary.md).
   - **The light specialist** (Shannon · Jasper · Steffon · Alex) is Carl's second
     set of eyes — a focused domain second-read Carl summons, not a co-owner. Runs
     [`pr-review-light.md`](pr-review-light.md). The light does not run the gates
     and does not drive the verdict (though any reviewer can block on a defect it
     spots). Carl is the standing primary on every PR; the light is the domain
     pick — `bin/reviewer-select <task>` previews the pair (primary Carl + the
     domain light).

## Parallel-first — claim each PR, skip what's already being reviewed

Review is a READ act on INDEPENDENT tasks, so **many `pr-review` sessions run at
once**. The goal of a sitting is to review as many submitted PRs as you can; the
one rule is **never review a task another session is already reviewing.** That
guarantee lives at the TASK, not the role — there is no shift lease to acquire and
no standing down. (The deploy/QA lanes are different: `qa-release` and
`production-deploy` mutate one shared release candidate, so they keep the
single-conductor `bin/devops-shift` lease. Review does not.)

**Claim with the atomic server pop.** The board exposes a single request that
selects the highest-ranked reviewable **green-CI** task and claims it in one
step:

```bash
slug=$(bin/task claim-next-review --agent carl) || true   # prints the claimed slug (exit 0), or "none" (exit 4)
```

**`--agent <soul>` is what the board paints.** The claim is the atomic "I am
reviewing this now" act, so the reviewing soul rides it and the task card fills its
crew seat the instant the claim lands — before the reviewer reads a line, with no
separate `bin/reviewer-select` call and no way for a launcher to forget. Omit it and
the session's sticky `.acting-agent` supplies it; with neither, the lane is still
claimed but the seat stays empty (the board never guesses a reviewer). The seat
empties again on release, or within the claim's TTL if the reviewer dies.

`bin/task claim-next-review` (`POST /api/v1/tasks/claim_next_review`) folds three
reads into one atomic server-side pop: it ranks the reviewable queue, skips any
task whose live CI is NOT green (red / pending / ci-less / conflicted are never
popped — they defer to a later wave, so a red PR is never claimed), and acquires
the per-task review lease (`TaskReviewClaim`: 120s TTL, renewed by the run,
self-healing on crash) on the winner — all under a row lock, so two racing
sessions serialize and exactly one wins. It prints **just the claimed slug** so a
caller can `slug=$(bin/task claim-next-review)`, or **`none`** (exit 4) when
nothing is eligible.

Because the pop only ever returns a **green-CI** task, the orchestrator never
needs a separate pre-spawn CI check — a red or pending PR simply isn't claimed.
A task whose CI flips red or conflicts AFTER the claim is caught inside the
review: Carl's gate-zero (`bin/dor-check <task> --gate-role review`, strict on
red/pending) blocks it back.

Release the claim on the verdict (a crash frees it via the TTL):

```bash
bin/task review-claim release <slug>
```

Keep each session's fan-out to **waves of five or fewer agents** (the per-session
cap: the prod board Postgres has a hard connection budget). A Carl plus his light
is two agents, so a wave is roughly two-to-five PRs depending on how many Carls
summon a light. When the reviewable queue is larger than a wave, run it in
successive waves — claim, spawn, collect, release, then claim the next wave.

## Preconditions

At least one task is in `submitted` with green CI. If `bin/task claim-next-review`
returns `none`, report "no reviewable PRs" and stop.

## Procedure

**Summon each review as a Carl subagent (interactive tree visibility).** For each
claimed PR, launch a **Carl** subagent via the Agent tool (`subagent_type: carl`)
to own the review. It renders as a live node in the sub-agent tree, and — because
Carl summons his light as his own child — that Carl node NESTS its light as a
child, so the review fan-out shows up as a branch under each Carl rather than a
flat wall of background shells.

- **Why delegation is right HERE (and wrong for the sweep and the ship).** Review
  is a **read** act: it inspects diffs and lands one task-stage verdict, so a
  subagent that detaches costs a retry, nothing more. The acts that MUTATE shared
  state across many minutes — `qa-release`, `production-deploy`, `archive-shipped`
  — are the opposite, and each is DIRECT-DRIVEN by the conductor session (a
  detached writer strands a half-applied merge/deploy that nobody owns). The line
  is **mutating vs reading**, not *parallel vs serial*:
  [`../../../modules/parallel-agent-devops.md`](../../../modules/parallel-agent-devops.md).
  The one mutation review DOES land — the merge of the feat PR into `accepted` —
  is a single, idempotent, re-runnable `gh pr merge`, and it is Carl's (the
  review owner's) to make.

The orchestrator's loop, per wave:

1. **Claim** the next reviewable PR — naming the soul that will review it, which
   is what fills the card's crew seat:
   `slug=$(bin/task claim-next-review --agent carl)`. Stop the wave when it
   returns `none`.
2. **Record the PR head** BEFORE spawning Carl — a provable lower bound on what
   the review reads (it anchors the merge guard below):

   ```bash
   gh pr view <feat-pr> --json headRefOid --jq .headRefOid
   ```

3. **Spawn one Carl** for that PR — an Agent-tool call whose `description` **is**
   the timeline action label: `review: <slug>`. Point Carl at
   [`pr-review-primary.md`](pr-review-primary.md) and hand him the slug, its PR
   (base `accepted`), branch, repos, risk tags, acceptance criteria, the recorded
   head, and the checks already reported. Keep the wave to five or fewer agents in
   flight (Carl + his light count as two).
4. **Carl reviews and owns.** He runs the deep review + gate-zero, summons **one**
   light specialist at his discretion (previewed by `bin/reviewer-select <task>` —
   Carl is the standing primary, the light is the domain pick), collects the
   light's read, and drives the verdict:
   - **merge-ready** → Carl revalidates the head and **merges** (see Verdicts).
   - **request-changes** → Carl blocks it back to the builder (see Verdicts).
5. **Release the claim** on Carl's verdict: `bin/task review-claim release <slug>`.
6. Re-query and run the next wave until `claim-next-review` returns `none`.

When you narrate the orchestration, label the spawn **"review: <slug>"** — never
"summon Avi" (there is no supervisor; Carl is both the reviewer and the owner).

- **Caveat.** The tree is a convenience, not the record of truth: it is ephemeral
  (it vanishes when the session ends) and the autonomous heartbeat runs with no
  terminal, so it renders no tree at all. The durable, full-visibility surface is
  the Activities timeline — narrate every act there regardless of whether a tree
  is showing.

**Don't touch the release timeline.** A review wave runs BEFORE the next release
candidate exists — the candidate is born when qa-release STARTS ASSEMBLING (the
sweep's `current_or_open!`), not here. Post no `testing/start`: with no active
release it now 404s, and opening one from review is exactly the empty 0-task
"Next Release" ghost that was removed. Node 1 Testing greens on its own once
qa-release's first sweep stamps `assembling` (`docs/agents/modules/task-board-api.md`,
"Release stage timeline").

The wave IS the task's **G2 Review gate**
([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md)):
Carl's gate-zero (`bin/dor-check <task> --gate-role review`, strict: red AND
pending both block) opens+closes its own `dor_review` gate, the primary lane
(`g2a_primary`) closes from Carl's scout report, and the light lane (`g2b_light`)
closes from the light's report (`merge-ready` = passed; a reportless lane stays in
flight for the next wave). The chips render on the task's gates card; record the
markers with `bin/gate` on a hand-run review (the manual commands are in the gate
doc).

## Verdicts

- **Two reads clean, no blockers → merge the feat PR into `accepted`, stamp the
  git-location, then move `reviewed`** (the accepted-ladder's first rung). Carl,
  the review owner, does this.

  **Merge condition — merge only a head you have VALIDATED.** The orchestrator
  recorded the PR head **before** spawning Carl (a provable lower bound on what the
  review reads); Carl re-reads it before merging. Anchor to that before-spawn head,
  not to "what the reviewers read" — nothing in the scout-report schema records a
  reviewed SHA, and a comparison with no left-hand side reads as satisfied by
  default. If the two are **equal**, the reads and the claim-time green CI both
  describe that head — merge it. If the head **moved** during review, the reads and
  claim-time CI describe a different SHA, so do not merge on the reviewers' word
  alone: **revalidate the new head's CI, and merge only if it is green** (pinned
  with `--match-head-commit`), holding for re-review otherwise. This is not
  hypothetical — the seam of
  [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md) invites a
  builder (or a reviewer) to lease-push a `zap:` commit mid-cycle, which can land
  while the review is reading.

  ```bash
  gh pr view <feat-pr> --json headRefOid --jq .headRefOid   # BEFORE spawn AND before merge
  # equal → merge; moved → revalidate the new head's CI, merge only if green, else hold for re-review
  ```

  Carl merges in ONE sequence — the order is load-bearing:

  ```bash
  gh pr merge <feat-pr> --merge --match-head-commit <validated-head>   # feat → accepted; pin the head you validated (retarget a mis-based PR first)
  bin/task merged <task> accepted      # stamp the git-location BEFORE the stage move
  bin/task move <task> reviewed
  bin/task note <task> --handoff "Carl review approved; merged into accepted; ready for Avi's qa-release sweep." --agent carl
  ```

  Order matters: merge → stamp → move, so the task is `reviewed` **iff** its code
  is on `accepted` (invariant: `reviewed` ⟺ code-on-`accepted`). If the `gh pr
  merge` FAILS, leave the task `submitted` and UNSTAMPED (never move to
  `reviewed`) — resolve the conflict/checks on GitHub, then re-review. A mis-based
  feat PR (base ≠ `accepted`) self-heals: retarget it to `accepted`, then merge.

  A reviewer who finds a zappable defect **fixes it forward** — lease-push a
  bounded `zap:` commit to the PR branch — and leaves the verdict merge-ready;
  Carl's head revalidation gates it on the post-zap CI. Fix-forward is the
  **default** for a zap-scale finding (see the bounce rubric below); a reviewer
  who cannot zap it mid-review **names** it and it lands afterward as a conductor
  zap on `accepted`. Bounds, timing, and recording:
  [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md).

- **Request changes — a bounce is spent only on a REACHABLE regression.** A
  block costs the builder a full lap (rework → resubmit → new CI → new claim,
  an hour or more), so it is reserved for a defect someone can actually hit: a
  correctness bug, a security hole, a data-loss path, an acceptance criterion
  the diff does not meet — or the one mechanical blocker, red CI. (A FAILED
  `gh pr merge` is NOT a bounce — the merge-ready bullet above self-heals it:
  leave the task `submitted`, resolve on GitHub, re-review.)
  The feedback names the regression **with its trigger** ("X input → Y wrong
  behavior"), not a preference. Every other finding is handled without a bounce:

  - **Zap-scale defect (within zap bounds)** → the reviewer fixes it forward on
    the PR branch and stays merge-ready, as above. Bouncing a zappable finding
    trades minutes of reviewer work for the builder's full lap.
  - **Scope, style, and hardening ideas** → ride as notes
    (`bin/task note <task> --comment "..." --agent carl`), never as blocks.
  - **Missing or wrong task metadata** → the reviewer repairs it
    (`bin/task update <task> …`), notes the repair, and proceeds.

  When a block IS earned:

  ```bash
  bin/task block <task> --kind rework --summary "<4-6 word headline>" \
    --feedback "<one complete send-back>" --agent carl
  ```

  `--summary` is the short headline the task **header** shows (keep it 4-6 words);
  `--feedback` stays the full send-back the builder fixes from. Omit `--summary`
  and the header derives one from the feedback's first line. (A red CI never
  reaches a claim — `claim-next-review` only pops green-CI tasks — but a CI that
  flips red mid-review is caught by Carl's `--gate-role review` gate-zero and
  blocked back here.)

  **Two-bounce circuit breaker.** Before blocking, count the task's prior
  send-backs in its ACTIVITY history — never in the live block columns: a
  compliant resubmission resolves the open feedback and the forward move wipes
  `blocked_at`/`block_kind`, so `bin/task show --verbose` reads EMPTY exactly
  when the breaker must fire. The durable trail is the task's `qa_feedback`
  activities — read it with the same bearer auth as every board call (the task
  page timeline renders the same rows for a human check):

  ```text
  GET /api/v1/activities?task_slug=<task>&activity_type=qa_feedback
  ```

  Each returned activity is one prior send-back. If one or more exist — this
  would be the **second** rework block — do not
  re-block to the builder — a repeat bounce is a review deadlock, and a deadlock
  is the operator's call, never a ping-pong (the record: one task bounced 5×
  before this rule). Instead:

  ```bash
  bin/task block <task> --kind dependency --summary "Escalated: <4-6 word disagreement>" \
    --feedback "<builder's position vs review's position, in brief>" --agent carl
  ```

  and surface it to Mr. McRitchie in the wave report as an **⚠ Escalated** line.

- **Wait-for-CI or low-confidence** — a CI that flips to pending mid-review defers:
  release the claim and re-query on a later wave. On low confidence, Carl routes to
  a human Carl / Avi / Steffon session (the humility valve) instead of an
  auto-decision.

Approved tasks stop at `reviewed` with `merged: "accepted"` (code on the
`accepted` branch). Avi's next `qa-release` sweep promotes `accepted →
release` and moves them forward.

## Exit Seam

Every claimed `submitted` PR is `reviewed`, `blocked`, or explicitly deferred with
a reason, and its review claim is released. Report the result per task.

## Related

- [`pr-review-slow.md`](pr-review-slow.md) — serialized version of this SOP.
- [`pr-review-primary.md`](pr-review-primary.md) — the PRIMARY (deep review +
  owner) role SOP each Carl runs.
- [`pr-review-light.md`](pr-review-light.md) — the LIGHT (focused second read) role
  SOP the light specialist Carl summons runs.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) —
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) —
  the G2 Review gate this SOP's waves produce.

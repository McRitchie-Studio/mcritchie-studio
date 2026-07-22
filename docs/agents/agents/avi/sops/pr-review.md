# PR Review

## Status: Active

This is Avi's `pr-review` SOP. It reviews all submitted PRs in bounded waves,
and on a merge-ready verdict **merges the feat PR into `accepted`** and stops the
task at `reviewed` — the accepted-ladder's first rung. Steffon's `qa-release`
sweep then promotes `accepted → release`.

## Scope

Avi owns review delegation and product acceptance. On approval this SOP merges
the feat PR into the `accepted` branch (the ladder's first rung); it never merges
to `release`/`main`, deploys QA, ships production, or archives work.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Parallel-first — claim each task, skip what's already being reviewed

Review is a READ act on INDEPENDENT tasks, so **many `pr-review` sessions run at
once**. The goal of a sitting is to review as many submitted PRs as you can; the
one rule is **never review a task another session is already reviewing.** That
guarantee lives at the TASK, not the role — there is no shift lease to acquire and
no standing down. (The deploy/QA lanes are different: `qa-release` and
`production-deploy` mutate one shared release candidate, so they keep the
single-conductor `bin/devops-shift` lease. Review does not.)

Two mechanisms, both automatic on the `bin/pr-review` supervisor path below:

1. **Query the unclaimed queue** — ask the board for submitted PRs with no live
   review claim:

   ```bash
   bin/task list --stage submitted --reviewable
   ```

   (`GET /api/v1/tasks?stage=submitted&reviewable=1` is the same read.)

2. **Claim each task before reviewing it — skip if taken.** The review claim is an
   atomic per-task lease (`TaskReviewClaim`, reusing `ClaimLease`: 120s TTL, renewed
   by the run, self-healing on crash — the build-claim's math, one level down from
   the role lease):

   ```bash
   bin/task review-claim acquire <task>   # 0 = yours → review it · 10 = SKIP (another session has it) · 1 = fail-open
   bin/task review-claim release <task>   # on the verdict (a crash frees it via the TTL)
   ```

   Exit **10** means a live session already holds that task — **move to the next
   reviewable one; do NOT stand your whole session down.** Exit **0** means it is
   yours: review it, then release on the verdict. Two sessions racing for one task
   serialize under a row lock, so exactly one wins and the other skips — the
   double-review collision the old role lease prevented, now prevented at the task
   grain WITHOUT blocking a second session's other work.

The supervisor does both for you: it **selects candidates from the reviewable
queue** (the `--reviewable` read above), and it reviews a task **only on a
CONFIRMED claim** — a task another live session holds is skipped, and a task whose
claim it cannot confirm (no session id / board unreachable) is **deferred, never
reviewed on an unconfirmed claim** (proceeding blind is the double-review the claim
exists to prevent) — then it releases on the verdict. Keep each session's fan-out to **waves of five or
fewer agents** (the per-session cap); the parallel-claim is what makes concurrent
sessions safe, not a global lock — the enforced cross-session connection budget is
tracked separately (follow-up C in
[`../../../system/devops-shift-lease.md`](../../../system/devops-shift-lease.md)).

## Preconditions

At least one task is in `submitted`. If the queue is empty, report "no submitted
PRs" and stop.

## The 3-level hierarchy — Avi is the SUPERVISOR, never a reviewer

Review runs in three levels; keep them distinct:

1. **Session Pokémon** (identity) — the base session driving the cycle.
2. **Avi (SUPERVISOR)** — the **thin gate + orchestration**. Avi confirms
   product-acceptance, selects the reviewer pair, spawns **both** reviewers in
   parallel, collects both verdicts, and gates the task. **Avi never reviews the
   code himself.**
3. **Domain experts** (Carl · Shannon · Jasper · Steffon · Alex) — the actual
   reviewers. One is the **PRIMARY** (deep review, runs
   [`pr-review-primary.md`](pr-review-primary.md)); one is the **LIGHT** (focused
   second read, runs [`pr-review-light.md`](pr-review-light.md)). They are
   **siblings under Avi**, spawned **in parallel** — the primary does **not**
   spawn its sibling.

## Procedure

**Summon this act as an Avi supervisor subagent (interactive tree visibility).**
When a session drives a devops cycle interactively (a terminal is attached),
summon this act as its OWNING SOUL instead of running the supervisor bare in a
background shell: launch an **Avi** subagent via the Agent tool
(`subagent_type: avi`) to **supervise** the review — select the pair and spawn
the two experts. It renders as a live node in the Claude Code sub-agent tree, and
— because Avi spawns **both** the primary and the light experts in parallel as
his own child subagents — that Avi node NESTS the two reviewers as **sibling**
children, so the review fan-out shows up as a branch under Avi rather than a flat
wall of background shells. **Avi supervises; he does not review** — the two
experts under him are the reviewers. Feature builds already delegate through the
Agent tool this way; this extends the same pattern to the review lane.

- **Why delegation is right HERE (and wrong for the sweep and the ship).** Review
  is a **read** act: it inspects diffs and lands one task-stage verdict, so a
  subagent that detaches costs a retry, nothing more. The acts that MUTATE shared
  state across many minutes — `qa-release`, `production-deploy`, `archive-shipped`
  — are the opposite, and each is DIRECT-DRIVEN by the conductor session (a
  detached writer strands a half-applied merge/deploy that nobody owns). The line
  is **mutating vs reading**, not *parallel vs serial*:
  [`../../../modules/parallel-agent-devops.md`](../../../modules/parallel-agent-devops.md).

**Emit two intent-labeled delegate actions — one per reviewer (enforced).** Avi
(the supervisor) spawns the pair with **two** Agent-tool calls, in a **single
message so they run in parallel**, and the Agent-tool `description` on each call
**is** the action label the timeline records:

- `summon primary review: <soul>` — the PRIMARY, pointed at
  [`pr-review-primary.md`](pr-review-primary.md).
- `summon light review: <soul>` — the LIGHT, pointed at
  [`pr-review-light.md`](pr-review-light.md).

Both reviewers are Avi's own children. **The primary must NOT spawn its sibling**
— if the primary summons anyone, the roles have inverted; stop and re-spawn both
from the supervisor. This is the drift the hardening closes: a live review had
Avi spawn only the primary, the primary then spawn its sibling, and the light
drive the verdict. Two supervisor-emitted, role-labeled delegate actions make the
structure legible and keep the primary from re-delegating.

- **Caveat.** The tree is a convenience, not the record of truth: it is
  ephemeral (it vanishes when the session ends) and the autonomous heartbeat
  runs with no terminal, so it renders no tree at all. The durable,
  full-visibility surface is the Activities timeline — narrate every act there
  regardless of whether a tree is showing.

**Don't touch the release timeline.** A review wave runs BEFORE the next release
candidate exists — the candidate is born when qa-release STARTS ASSEMBLING (the
sweep's `current_or_open!`), not here. Post no `testing/start`: with no active
release it now 404s, and opening one from review is exactly the empty 0-task
"Next Release" ghost that was removed. Node 1 Testing greens on its own once
qa-release's first sweep stamps `assembling` (`docs/agents/modules/task-board-api.md`,
"Release stage timeline").

Preferred supervisor path:

```bash
bin/pr-review --run --fast --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

Use `--fast` for bounded waves under the five-agent cap. The script picks newest
submitted tasks first, **checks the PR's live GitHub CI before anything else**
(builders submit without waiting for CI, so this pre-spawn check is the
authoritative CI verdict: **red** → the task is blocked back with the failing
checks named, no reviewers spawned; **conflicted** (`mergeStateStatus DIRTY`) →
blocked back too, with rebase/merge-release named as the fix — a conflicted PR
gets **no CI at all** (GitHub can't compute the merge commit), so deferring
would strand it in `submitted`; **ci-less** (zero check-runs and a *refuted*
merge) → blocked back as well, with "merge the base in and resolve" named — a
base that drifted past GitHub's merge computation gets no CI either, without ever
reading `DIRTY`; **pending or no checks yet** → the task
defers to a later wave; **green** → proceed), records `bin/reviewer-select`
intent, spawns the selected PRIMARY + LIGHT reviewers **in parallel**,
re-queries the board before each final decision, writes the task handoff, and
prints a retrospective. When you narrate the reviewer-select step, label it
**"select primary+light reviewers"** — never "summon Avi" (Avi is the
supervisor doing the selecting, not a reviewer being summoned).

The wave IS the task's **G2 Review gate**
([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md)):
`bin/pr-review` checks the PR's live CI pre-spawn (a red or conflicted bounce
records as a failed `dor_review` gate-zero attempt with a `ci` SOP — no
reviewer ran, but the
round-trip shows on the gates card), opens the two lanes (`g2a_primary` +
`g2b_light`) as the pair launches, the primary's gate-zero (`bin/dor-check
<task> --gate-role review`, strict: red AND pending both block there) opens+closes
its own `dor_review` gate, and each lane closes from its own reviewer's scout
report (`merge-ready` = passed;
a reportless lane stays in flight for the next wave). The chips render on the
task's gates card. Automatic on the supervisor path — record the markers with
`bin/gate` only on a hand-run review (the manual commands are in the gate doc).

Manual fallback:

```bash
bin/task list --stage submitted
bin/reviewer-select <task> --busy-auto
```

For each task, run the single-PR cascade from
[`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md): as the
**supervisor**, confirm product acceptance and select the reviewer pair, then
spawn **both** experts in parallel — the PRIMARY runs
[`pr-review-primary.md`](pr-review-primary.md) (deep review), the LIGHT runs
[`pr-review-light.md`](pr-review-light.md) (focused second read) — collect both
verdicts, and gate. You never review the code yourself. Keep review fan-out to
waves of five or fewer agents.

Verdicts:

- Two approvals, no blockers → **merge the feat PR into `accepted`, stamp the
  git-location, then move `reviewed`** (the accepted-ladder's first rung).

  **Merge condition — the head must still be the head you spawned the lanes on.**
  Record the PR head when you spawn the lanes, and re-read it before merging; they
  must be equal. Anchor to the spawn-time head, not to "what the reviewers read" —
  nothing in the scout-report schema records a reviewed SHA, and a comparison with
  no left-hand side reads as satisfied by default. A moved head means the approvals
  describe code nobody reviewed **and** the pre-spawn CI verdict was rendered on a
  different SHA, so **do not merge**: re-run the lanes (which re-checks CI) against
  the new head. This is not hypothetical — the builder seam of
  [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md) invites a
  builder to fast-forward a `zap:` commit onto their own `feat/<slug>` branch
  mid-cycle, which can land while both lanes are reading.

  ```bash
  gh pr view <feat-pr> --json headRefOid --jq .headRefOid   # at spawn AND before merge — must match
  ```

  The supervisor then merges in ONE step — the order is load-bearing:

  ```bash
  gh pr merge <feat-pr> --merge        # feat → accepted (retarget a mis-based PR to accepted first)
  bin/task merged <task> accepted      # stamp the git-location BEFORE the stage move
  bin/task move <task> reviewed
  bin/task note <task> --handoff "Avi review approved; merged into accepted; ready for Steffon's qa-release sweep." --agent avi
  ```

  Order matters: merge → stamp → move, so the task is `reviewed` **iff** its code
  is on `accepted` (invariant: `reviewed` ⟺ code-on-`accepted`). If the `gh pr
  merge` FAILS, leave the task `submitted` and UNSTAMPED (never move to
  `reviewed`) — resolve the conflict/checks on GitHub, then re-review. A mis-based
  feat PR (base ≠ `accepted`) self-heals: retarget it to `accepted`, then merge.
  (The `bin/pr-review` supervisor runs the merge → stamp → move sequence for you.
  It also captures the PR head when the review begins and REVALIDATES it before
  merging — an advanced head, e.g. a reviewer-applied zap, merges only if its own
  CI is green, and holds for re-review otherwise.)

  A reviewer who finds a zappable defect may **apply a bounded zap** — lease-push
  a `zap:` commit to the PR branch — and leave the verdict merge-ready; the
  supervisor's head revalidation gates it on the post-zap CI. Otherwise the
  reviewer **names** it and it lands afterward as a conductor zap on `accepted`.
  Bounds, timing, and recording: [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md).

- Request changes, missing metadata, red CI, merge risk, or acceptance mismatch:

  ```bash
  bin/task block <task> --kind rework --feedback "<one complete send-back>" --agent avi
  ```

  (A red CI is normally caught by the supervisor's pre-spawn check and blocked
  back automatically, with the failing checks named in the feedback.)

- Wait-for-CI or conductor-review: defer and re-query after the defer window.
  A still-running CI defers at the pre-spawn check, before any reviewer spawns.

Approved tasks stop at `reviewed` with `merged: "accepted"` (code on the
`accepted` branch). Steffon's next `qa-release` sweep promotes `accepted →
release` and moves them forward.

## Exit Seam

Every visible `submitted` PR is `reviewed`, `blocked`, or explicitly deferred
with a reason. Report the result per task.

## Related

- [`pr-review-slow.md`](pr-review-slow.md) - serialized version of this SOP.
- [`pr-review-primary.md`](pr-review-primary.md) - the PRIMARY (deep review) role
  SOP this supervisor spawns.
- [`pr-review-light.md`](pr-review-light.md) - the LIGHT (focused second read)
  role SOP this supervisor spawns.
- [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md) -
  single-PR review primitive.
- [`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md) -
  the G2 Review gate this supervisor's waves produce.

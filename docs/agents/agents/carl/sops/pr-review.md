# PR Review

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

This is Carl's `pr-review` SOP — the Lead Architect owns PR review. It reviews
submitted PRs in bounded waves, and on a merge-ready verdict **merges the feat PR
into `accepted`** and stops the task at `reviewed`. Avi's `qa-release` sweep then
promotes `accepted → release`.

**There is no Avi supervisor layer.** The driving SESSION is a Pokémon
orchestrator; it claims reviewable PRs and spins up **one Carl per PR**. Each Carl
is the deep/primary reviewer AND the OWNER of that review: he runs the gates,
summons a light specialist at his discretion, drives the verdict, and merges.

A focus session reviews its own epic's PRs by tier instead
([`../../../modules/focus-session.md`](../../../modules/focus-session.md)): there,
a prose-only PR gets Xan alone. This sweep runs Carl plus a light on every PR.
The rationale and incident history this page no longer carries are frozen
verbatim in [`../../../archive/pr-review-2026-09-25.md`](../../../archive/pr-review-2026-09-25.md).

## Scope and entry

On approval this SOP merges the feat PR into `accepted`; it never merges to
`release`/`main`, deploys, or archives. Run it from the hub primary against the
production board (no `--local`):

```bash
cd /Users/alex/projects/mcritchie-studio
```

## The two levels — the session orchestrates, each Carl reviews and owns

1. **Session Pokémon** (the orchestrator) claims reviewable PRs, spins one Carl
   per claimed PR in bounded waves, collects each verdict, and releases each
   claim. **It does not review the code itself.**
2. **Carl (per PR)**, a `carl` subagent, is the **deep/primary reviewer AND review
   owner**: he runs the gates (`bin/dor-check`, CI green, acceptance match),
   summons a **light specialist** at his discretion, drives the verdict, and
   **merges the feat PR into `accepted`** himself. Runs
   [`pr-review-primary.md`](pr-review-primary.md).
   - **The light specialist** (Shannon · Jasper · Steffon · Xan) is Carl's second
     set of eyes, not a co-owner. Runs [`pr-review-light.md`](pr-review-light.md).
     The light does not run the gates or drive the verdict; a defect it spots
     reaches Carl as a scout report. `bin/reviewer-select <task> --no-record`
     previews the pair. Keep `--no-record` on a preview: a bare run RECORDS, and
     recording acquires the task's review claim (exit **10** if someone else holds it).

## Parallel-first — claim each PR, skip what's already being reviewed

Review is a READ act on INDEPENDENT tasks, so **many `pr-review` sessions run at
once**. The one rule: **never review a task another session is already
reviewing.** That guarantee lives at the TASK: there is no shift lease. (The
`qa-release` and `production-deploy` lanes mutate one shared release candidate, so
they keep the single-conductor `bin/devops-shift` lease. Review does not.)

**Claim with the atomic server pop**, which selects the highest-ranked **green-CI**
task and claims it in one step:

```bash
slug=$(bin/task claim-next-review --agent carl) || true   # prints the claimed slug (exit 0), or "none" (exit 4)
```

**`--agent <soul>` is what the board paints.** The reviewing soul rides the
claim, so the card's crew seat fills the instant the claim lands. Omit it and the
session's sticky `.acting-agent` supplies it; with neither, the seat stays empty.

The pop ranks the reviewable queue, skips any task whose live CI is NOT green
(red, pending, ci-less, and conflicted tasks defer to a later wave), and acquires
the per-task review lease (`TaskReviewClaim`, a **3h25m** TTL) on the winner, all
under a row lock, so exactly one racing session wins. It prints **just the
claimed slug**, or **`none`** (exit 4) when nothing is eligible.

A task whose CI flips red or conflicts AFTER the claim is caught by Carl's
gate-zero (`bin/dor-check <task> --gate-role review`). That gate is an
**allow-list**: `green` advances, and every other state refuses, including an
unread verdict (`unreadable` / `unverified` / `none`) and a blank
`devops.pr_url`. No local cert stands in for an unread verdict; such a refusal is
a `conductor-review`. See `../../../modules/gates/dor.md`.

Release the claim on the verdict (a crash frees it via the TTL, within 3h25m):

```bash
bin/task review-claim release <slug>
```

**Read what release says — it names which of five states it found.** Two states
go to **stderr**, and both are worth stopping for: "your lease had LAPSED" (the
task was free for part of your review) and "held by <soul>" (somebody else has
been reviewing it too). Reconcile either before you trust your verdict. The exit
code is 0 in every case, so the message is the signal.

Keep each session's fan-out to **waves of five or fewer agents** (the board
database has a hard connection budget). A Carl plus his light is two agents.
Run a larger queue in successive waves: claim, spawn, collect, release, repeat.

## Preconditions

At least one task is in `submitted` with green CI. If `bin/task claim-next-review`
returns `none`, report "no reviewable PRs" and stop, UNLESS it prints one of two
warnings:

- `no CI is ingested for <repo>` is a WIRING gap: the board receives no Actions
  deliveries for that repo. Report the repos to Alex (recipe:
  `../../../modules/deployment.md`, "Wiring a repo's Actions webhook").
- `the board's OWN ingested CI is what this refusal read` is an INGESTION gap on
  ONE HEAD: the board holds no run for this PR's tip while GitHub says green.
  Compare the SHA it names against the PR's real head, and report the
  disagreement. Do NOT force the lease.

## Procedure

**Summon each review as a Carl subagent** (`subagent_type: carl`). Carl summons
his light as his own child, so each review shows as a branch in the agent tree.
Delegation is right here because review is a **read** act; the one mutation it
lands, `gh pr merge` into `accepted`, is idempotent and re-runnable. The acts that
MUTATE shared state for many minutes (`qa-release`, `production-deploy`,
`archive-shipped`) are direct-driven instead:
[`../../../modules/parallel-agent-devops.md`](../../../modules/parallel-agent-devops.md).

The orchestrator's loop, per wave:

1. **Claim** the next PR, naming the reviewing soul:
   `slug=$(bin/task claim-next-review --agent carl)`. Stop when it returns `none`.
2. **Record the PR head** BEFORE spawning Carl; it anchors the merge guard below:

   ```bash
   gh pr view <feat-pr> --json headRefOid --jq .headRefOid
   ```

3. **Spawn one Carl** for that PR — an Agent-tool call whose `description` **is**
   the timeline action label: `review: <slug>`. Point Carl at
   [`pr-review-primary.md`](pr-review-primary.md) and hand him the slug, its PR
   (base `accepted`), branch, repos, risk tags, acceptance criteria, the recorded
   head, and the checks already reported. Keep the wave to five or fewer agents in
   flight (Carl + his light count as two).
4. **Carl reviews and owns.** He runs the deep review and gate-zero, summons
   **one** light at his discretion, collects its read, and drives the verdict:
   **merge-ready** → revalidate the head and merge; **request-changes** → block
   it back to the builder (see Verdicts).
5. **Release the claim** on Carl's verdict: `bin/task review-claim release <slug>`.
6. Re-query and run the next wave until `claim-next-review` returns `none`.

Label each spawn **"review: <slug>"**, never "summon Avi". The agent tree is
ephemeral, so narrate every act on the Activities timeline too.

**Don't touch the release timeline.** The next release candidate is born when
qa-release starts assembling, not here. Post no `testing/start`.

The wave IS the task's **G2 Review gate**
([`../../../modules/gates/g2-review.md`](../../../modules/gates/g2-review.md)):
gate-zero (`bin/dor-check <task> --gate-role review`, strict: red AND pending
both block) closes `dor_review`, Carl's scout report closes `g2a_primary`, and the
light's report closes `g2b_light`. On a hand-run review, record the markers with
`bin/gate` (commands in the gate doc).

## Verdicts

- **Two reads clean, no blockers → merge the feat PR into `accepted`, stamp the
  git-location, then move `reviewed`** (the accepted-ladder's first rung). Carl,
  the review owner, does this.

  **Merge condition — merge only a head you have VALIDATED.** The orchestrator
  recorded the PR head **before** spawning Carl; Carl re-reads it before merging.
  Anchor to that before-spawn head: the scout report records no reviewed SHA.
  **Equal** → merge it. **Moved** (a mid-review `zap:` push, per
  [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md)) →
  **revalidate the new head's CI, and merge only if it is green**, pinned with
  `--match-head-commit`; otherwise hold for re-review.

  ```bash
  gh pr view <feat-pr> --json headRefOid --jq .headRefOid   # BEFORE spawn AND before merge
  # equal → merge; moved → revalidate the new head's CI, merge only if green, else hold for re-review
  ```

  Carl merges in ONE sequence — the order is load-bearing:

  ```bash
  gh api user   # WHO am I about to merge as? 403 "not accessible by integration" = the App. STOP on a 200.
  gh pr merge <feat-pr> --merge --match-head-commit <validated-head>   # feat → accepted; pin the head you validated (retarget ONLY a base PROVEN unclaimed — at a merge anything unproven REFUSES, all five arms; see the merge-ready bullet)
  bin/task move <task> reviewed
  bin/task note <task> --handoff "Carl review approved; merged into accepted; ready for Avi's qa-release sweep." --agent carl
  ```

  **A gem's merge gets one more read, a DETECTOR and not a gate.** For a
  registered gem, `bin/pr-review` audits the gem's `accepted` after the merge
  (`UpstreamMisfile.audit`) for `## Unreleased` bullets mis-filed under a version
  that already shipped. It never fails the review. On a finding, move the named
  lines back under `## Unreleased` in a CHANGELOG-only PR.

  **The `gh api user` line is not optional.** A 200 with a `login` means `gh`
  would merge as a PERSON, under that human's name forever; this happened twice
  on 2026-08-29 when an empty `GH_TOKEN` fell back to the keyring. Refuse to merge
  on a 200 and on any answer you cannot read. `bin/pr-review` runs the same check
  itself (`bin/lib/acting_identity.rb`). Do NOT substitute a permissions probe:
  the deployer App and a personal `repo` scope both pass it.

  Order matters: merge → move, so the task is `reviewed` **iff** its code is on
  `accepted` (invariant: `reviewed` ⟺ code-on-`accepted`); the board derives
  `merged`, so there is no stamp. If the `gh pr merge` FAILS, leave the task
  `submitted` (never move to
  `reviewed`) — resolve the conflict/checks on GitHub, then re-review. A mis-based
  feat PR (base ≠ `accepted`) self-heals ONLY when the guard can PROVE the base is
  unclaimed: retarget it to `accepted`, then merge. **At a merge, anything unproven
  REFUSES** — the base read failed, the probe was unreadable, the base came back
  empty, the repo to probe could not be derived, or the base is another OPEN PR's
  head, which is a deliberate STACK. `bin/pr-review` REFUSES those and names the
  parent: retargeting a stack changes what the PR MERGES without moving its head,
  so `--match-head-commit` cannot see it. Leave the task `submitted` and re-review
  once the parent lands. `bin/ship` is deliberately the opposite: it repairs on a
  doubt, because it never merges.

  A reviewer who finds a zappable defect **fixes it forward**: lease-push a
  bounded `zap:` commit to the PR branch and stay merge-ready; the head
  revalidation gates it on the post-zap CI. Bounds and recording:
  [`../../../modules/zap-protocol.md`](../../../modules/zap-protocol.md).

- **Request changes — a bounce is spent only on a REACHABLE regression.** A block
  costs the builder a full lap, an hour or more, so it is reserved for a defect
  someone can hit: a correctness bug, a security hole, a data-loss path, an unmet
  acceptance criterion, or red CI. A FAILED `gh pr merge` is NOT a bounce (see
  above). The feedback names the regression **with its trigger** ("X input → Y
  wrong behavior"). Every other finding is handled without a bounce:

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

  `--summary` is the 4-6 word headline the task **header** shows; `--feedback` is
  the full send-back the builder fixes from.

  **Two-bounce circuit breaker.** A repeat bounce is a review deadlock, and a
  deadlock is the operator's call. The rework block runs the breaker itself and
  **REFUSES** the second bounce. Read it before you compose the block:

  ```bash
  bin/task bounces <task>
  ```

  **Exit 0 = CLEAR is the only exit that authorizes a re-block.** 10 = TRIPPED
  (escalate). Any other non-zero means the read FAILED or the slug is unknown:
  **not** a clear.

  On **TRIPPED**, escalate rather than re-blocking:

  ```bash
  bin/task block <task> --kind dependency --summary "Escalated: <4-6 word disagreement>" \
    --feedback "<builder's position vs review's position, in brief>" --agent carl
  ```

  and surface it to Alex in the wave report as an **⚠ Escalated** line.

  If the bounce is **mechanical** — red CI, a merge conflict, a dirty base;
  nothing for the operator to arbitrate — say so and the block proceeds, with the
  reason recorded on the row: `--breaker-ack "red CI, mechanical"`.

  Never count bounces by hand. Every hand-rolled count read zero on some failure
  (an unparsed response, an expired token, an error page, an unknown slug);
  `bin/task bounces` refuses all four instead. It reads the task's `qa_feedback`
  **activities**, one row per bounce, never the live block columns, which a
  compliant resubmission wipes.

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

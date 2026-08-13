# Deploy With Task

## Status: Active

This is Avi's `deploy-with-task` SOP. It expedites ONE task through review, QA,
and production ship, guarded on a clean ladder — nothing parked on `accepted`
and nothing riding `release`. The operator may launch it bare
(`deploy-with-task`) or with the task inline (`deploy-with-task <task>`).

**It is not a 20-minute lane.** The measured floor is ~20 minutes of CI and
deploy alone, ~30-35 end to end — see "What the express lane costs" below
before promising the operator a number.

## Ask First

This SOP is interactive. If the launch phrase did not name a task, your FIRST
action is to ask Mr. McRitchie:

> What task?

Wait for the task slug or URL before touching the board or the repos. Do not
guess a task from the queue.

## Scope

⚠️ **THIS SOP IS PRODUCTION AUTHORITY** — for the one named task only. Launching
it is the operator's ship grant for that task. It takes a single
freshly-submitted task all the way to prod, skipping the full-queue drain — for
when one fix must ship now and nothing else is waiting.

It does not drain the review queue, batch multiple tasks into a release, or
archive shipped work. For the whole pipeline, use Alex's `full-cycle`.

## Entry

Run this SOP from the McRitchie Studio primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
```

Use the production board by default. Do not add `--local`.

## Preconditions

- The operator named exactly one task (or answered "What task?").
- That task is `submitted` (or already `reviewed`) with an open PR based on
  **`accepted`**. The ladder is `accepted → release → main`, and `bin/ship`
  pins base `accepted`; nothing in the pipeline produces a PR based on
  `release`. If you find one, **retarget it to `accepted`** — that is a
  mis-based PR, not grounds to bounce the task.
- **Both rungs beneath the ship are clean**: `release == main` AND `accepted ==
  release`. Step 1 proves both in one command, and **step 3 re-proves them** at
  the moment it matters.

## Procedure

1. **GUARD — is the ladder clean?** The expedite is only safe when the one
   named task is the ONLY thing between `accepted` and production, and under the
   three-rung ladder that spans two rungs. One command covers both:

   ```bash
   bin/release status --clean-only --task <task>
   ```

   It reads FOUR signals — a board read and a git read on each rung:

   | Rung | Board | Git |
   |---|---|---|
   | `release` | `assembled`, plus `reviewed` stamped `merged: "release"` | `origin/release` ahead of `origin/main` |
   | `accepted` | `reviewed` stamped `merged: "accepted"` | `origin/accepted` ahead of `origin/release` |

   Both reads on a rung matter, and neither covers the other's set. The board
   read is UNSCOPED by repo, so it sees another repo's parked work that a
   single-repo `git rev-list` would miss entirely — and a bare `bin/release
   prepare` sweeps every `reviewed` task, so that work is genuinely in the blast
   radius. The git read sees commits with no board record at all: a zap, a gem
   version bump committed straight onto `accepted`, an abandoned branch. When
   the two disagree the guard says so and refuses — the disagreement names which
   record to go fix.

   **The verdict names the signal it measured**, never a tree relation it did not
   read. A rung dirty on the BOARD read alone is reported as a count (`3 task(s)
   still recorded as riding "release"`), not as `release ≠ main` — so do not
   re-fetch on that line expecting to find commits.

   On the `release` rung, **board-dirty + git-clean is the signature of an
   INTERRUPTED SHIP**: tasks still recorded as riding `release` while `release`
   and `main` are identical means the fast-forward already landed and only the
   board stamp is missing — **the code is already in production**. The guard says
   so and still refuses (the work is unaccounted for). Confirm with `git ls-remote
   --heads origin main release`, reconcile the board, then re-run.

   **The git read covers the repos you have cloned**, and it says which ones it
   did not. A three-rung repo with no local checkout is skipped — an uncloned
   sibling is not evidence of pending work, so it never refuses the lane — but the
   guard will not speak for it either. It names the gap (`NOT verified: rolio`)
   and withholds every claim that ranges over ALL repos, the interrupted-ship
   sentence above included. **So the absence of that sentence is not evidence the
   ship completed**; only a read that covered every repo can say the trees are
   identical. Clone the named repo and re-run when you need the whole ladder
   verified.

   `--task <task>` names the expedited task so the guard does not refuse on your
   OWN work when you re-run the act after review already merged it onto
   `accepted`. It excludes that one slug from the board read, and tolerates the
   commits on `accepted` only while the board agrees that task is the rung's sole
   occupant — the pass says so out loud rather than swallowing the count.

   - **Clean** (exit 0) → continue.
   - **Dirty** (exit non-zero) → **STOP**. The ship fast-forwards `release →
     main` and step 3's sweep promotes **all of `accepted`** onto `release`, so
     anything parked on either rung rides to production with your expedite,
     un-expedited and unasked. Report the pending work the guard printed and
     recommend: *"Ship the WHOLE release instead: run the `full-cycle`
     launcher."* Never force past the guard.

   > **This step used to be two reads, one of them by hand** (`bin/task list
   > --stage reviewed` plus a manual `git rev-list origin/release..origin/accepted`),
   > because `--clean-only` was blind to the `accepted` rung. **The code performs
   > that check now** — `Release::CleanCheck` reads both rungs and both signals —
   > so the manual step is gone, not skipped. Do not reintroduce it.

2. **Review the one task.** Run the `review-one` atom from the registered
   review primitive
   [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md).
   This session is the **orchestrator, not a reviewer**: it claims the
   green-CI PR (`bin/task claim-next-review`) and spins **one Carl** (Agent
   tool, `subagent_type: carl`) as the review **OWNER**. **There is no Avi
   supervisor.** Carl runs his gate-zero (`bin/dor-check <task> --gate-role
   review`), confirms product acceptance against the task's criteria, summons
   **one domain LIGHT** at his discretion (previewing with `bin/reviewer-select
   <task>`), and drives the verdict.

   On a merge-ready verdict **Carl merges the feat PR into `accepted`** (`gh pr
   merge --merge --match-head-commit` → `bin/task merged <task> accepted` →
   `bin/task move <task> reviewed --actor carl`) and **stops there** — review
   never touches `release`/`main` and never deploys. Any block ends the
   expedite: fix, resubmit, re-run this SOP.

**Direct-drive steps 3 and 4 — do NOT delegate them to a subagent.** Both
`bin/release prepare` and `bin/release ship` MUTATE shared state (merges onto
`release`, QA and production deploys, task-stage flips) across many minutes. Run
them in THIS session, with a terminal attached.

- **The rule.** Any op that MUTATES shared state across many minutes —
  `qa-release`, `production-deploy`, `archive-shipped`, and both steps below — is
  DIRECT-DRIVEN by the conductor session, never handed to an ephemeral subagent
  that can detach and leave the mutation half-applied with no terminal to notice or
  finish it. (On 2026-07-11 a delegated sweep did exactly that and stranded a
  partial release candidate: merged onto `release`, but never gated, deployed, or
  assembled.) Step 2 above delegates the REVIEW on purpose — review is a **read**
  act, where a detach costs a retry. The line is **mutating vs reading**, not
  *parallel vs serial*.
- **Recovery: both commands are SELF-HEALING — if one is interrupted, RE-RUN it.**
  `prepare` skips PRs already stamped `merged: release/main` and flips members only
  on QA-green; `ship` skips repos already stamped `merged: "main"` for re-ff,
  published gems skip, and the fast-forwards no-op. An interrupted run is finished
  by re-running it, not by hand-merging. (A gate ABORT is the opposite case: it
  reached a verdict and refused — do not force past it; record the blocker and hand
  it off.)

3. **Sweep it onto release and QA it.** Pass `--expedite` — it is not optional
   on this lane.

   ```bash
   bin/release prepare --task <task> --expedite --yes
   curl -fsS https://qa.mcritchie.studio/up
   ```

   Review already merged the task's PR onto `accepted` in step 2, so the sweep
   promotes **all of `accepted`** onto `release` via ONE batch PR per repo
   (`--base release --head accepted`). `--task` curates which tasks are RECORDED
   as members; it does **not** narrow which COMMITS ride along. It then runs the
   **G3 pre-QA gate** (GitHub CI's verdict for each app's `origin/release` SHA),
   deploys QA, and flips the member `assembled` only on QA-green.

   **`--expedite` re-runs step 1's guard here, immediately before the promote,
   and refuses if the ladder is no longer clean.** Step 1's verdict has gone
   stale by now: review plus two CI payments put 15-25 minutes between them, and
   `bin/review-autopilot` runs in production and can merge another task onto
   `accepted` inside that window. A point-in-time answer taken before the window
   cannot describe the world after it, so the promote — the irreversible moment,
   the one that puts other people's work on the release — proves it again. A
   refusal here promotes, records, and deploys **nothing**; make the same
   `full-cycle` recommendation as step 1.

   `--expedite` requires exactly one `--task`, and it is opt-in: a bare
   `bin/release prepare` (the normal full-queue sweep, where promoting all of
   `accepted` is precisely the intent) is unaffected.

4. **Ship it.** From the primary checkout (not a worktree):

   ```bash
   bin/release ship --by conductor --yes
   ```

   `--yes` answers only the non-interactive confirmation — the clean-main
   preflight, frozen-SHA ship tests, gem publish ordering, deploy smoke,
   release notes, and partial-ship recovery all still run and can abort. If a
   gate aborts, do not force past it; record the blocker and hand it off.

Because the guard proved **both** rungs clean — `release == main` and nothing
else parked on `accepted` — the fast-forward carries only the expedited task to
`main`. The `release` rung alone would not be enough: the sweep in step 3
promotes everything on `accepted`, so a task parked there rides along however
clean `release` looked. And the claim holds only because step 3 re-proved it
**at the promote**; the step-1 verdict alone is a statement about a world 15-25
minutes gone, which the autopilot can change underneath you.

## What the express lane costs — measured, 2026-08-11

Be straight with the operator about this. The lane's wall-clock is dominated by
machine time, not agent time, and **it cannot currently finish in under 20
minutes.** Measured from the last 60 `mcritchie-studio` workflow runs
(`gh run list --json name,conclusion,createdAt,updatedAt,event,headBranch`):

| Stage | What waits | Measured |
|---|---|---|
| Build → `submitted` | `bin/task begin`, edit, `bin/ship` (incl. `bin/fast-check`) | ~4-7 min |
| **CI payment #1** | feat-branch `pull_request` CI — review's gate-zero only claims a GREEN PR | **~8 min** (median 8m11s; range 7m21s-9m46s) |
| Step 2 review | Carl + light, in parallel | ~3-6 min |
| **CI payment #2** | the `accepted → release` batch PR's `pull_request` CI, which the G3 gate waits on | **~8-10 min** (measured 8m11s, 9m55s) |
| Step 3 QA | QA Deploy workflow + boot/smoke | ~2-3 min |
| Step 4 ship | G4 frozen-SHA gate + Production Deploy + smoke | ~3-4 min |

**The floor is ~20 minutes of pure CI-and-deploy with agent time at zero**
(8 + 8 + 2 + 2), and realistically **~30-35 minutes** end to end for a
single-focus change with no blocks. The two CI payments are ~16-18 of those
minutes.

One payment is already optimized away and must not be double-counted: the G3
gate **credits** an existing green rather than awaiting the `push:[release]`
run, when the promote is a fast-forward or tree-identical
(`resolve_release_ci_verdict` in `bin/release.rb`). That credit removes a
*third* payment; payments #1 and #2 both remain real.

**Do not "fix" the number by skipping CI.** This lane carries production
authority for one task, and the two green verdicts are what make that safe. The
legitimate follow-up is recorded in the task record: extend the same
tree-identical credit to the accepted seam, so a feat PR already green at
payment #1 is not re-certified at payment #2 when the merge produced an
identical tree. That is a real change to a gate's semantics — it needs its own
task, and it is sound only while `accepted` carries exactly one task — which is
precisely what this lane's guard proves, at step 1 and again at step 3.

## Exit Seam

The named task is `shipped` and the release is clean again, or the guard
refused with the pending work listed. Report:

- task slug and release slug
- production SHA and production URL
- smoke result
- **actual wall-clock**, submit → production, against the ~30-35 min table
  above — the operator is tracking this lane's real speed, so report the number
  you observed, not the estimate
- on a guard refusal: the pending work and the `full-cycle` recommendation

## Background — not needed to execute

- [`../../steffon/sops/production-deploy.md`](../../steffon/sops/production-deploy.md) - the batch ship act this SOP
  borrows its gate semantics from.
- [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md) - the
  sweep act behind step 3.
- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model (architecture).

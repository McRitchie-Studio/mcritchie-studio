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
  release`. Step 1 proves both — and it takes two reads, because one command
  does not cover both.

## Procedure

1. **GUARD — are both rungs clean?** The expedite is only safe when the one
   named task is the ONLY thing between `accepted` and production. Under the
   three-rung ladder that is two separate questions, so run both reads.

   **1a. Is `release` clean (`release == main`)?**

   ```bash
   bin/release status --clean-only
   ```

   It reads the tasks already riding `release` — `assembled`, plus `reviewed`
   stamped `merged: "release"` — and each repo's
   `origin/release`-ahead-of-`origin/main` count.

   - **Clean** (exit 0) → continue to 1b.
   - **Dirty** (exit non-zero) → **STOP**. Fast-forwarding `release → main`
     ships **everything** on `release`, so expediting one task past pending
     work would drag along whatever is `assembled` but unshipped. Report the
     pending work the guard printed and recommend: *"Ship the WHOLE release
     instead: run the `full-cycle` launcher."* Never force past the guard.

   **1b. Is `accepted` clean (nothing riding it but your task)?** ⚠️
   `--clean-only` does **not** answer this. It counts only work already on
   `release`, so it is blind to a task sitting `reviewed` with `merged:
   "accepted"`. That matters because step 3's sweep promotes **all of
   `accepted`** onto `release` in one batch PR — so anything parked on
   `accepted` rides to production with your expedite. Read it yourself:

   ```bash
   bin/task list --stage reviewed          # board: any OTHER reviewed task?
   git -C <repo> fetch origin --quiet
   git -C <repo> rev-list --count origin/release..origin/accepted   # git: 0 before review merges yours
   ```

   - **Clean** — no `reviewed` task other than the expedited one, and the count
     is 0 before step 2 merges yours → continue.
   - **Dirty** — another task is parked on `accepted` → **STOP** and make the
     same `full-cycle` recommendation as 1a. Expediting now would ship that
     task too, un-expedited and unasked. Never force past it.

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

3. **Sweep it onto release and QA it.**

   ```bash
   bin/release prepare --yes
   curl -fsS https://qa.mcritchie.studio/up
   ```

   Review already merged the task's PR onto `accepted` in step 2, so the sweep
   promotes **all of `accepted`** onto `release` via ONE batch PR per repo
   (`--base release --head accepted`) — which step 1b proved is your task and
   nothing else. It then runs the **G3 pre-QA gate** (GitHub CI's verdict for
   each app's `origin/release` SHA), deploys QA, and flips the member
   `assembled` only on QA-green.

4. **Ship it.** From the primary checkout (not a worktree):

   ```bash
   bin/release ship --by conductor --yes
   ```

   `--yes` answers only the non-interactive confirmation — the clean-main
   preflight, frozen-SHA ship tests, gem publish ordering, deploy smoke,
   release notes, and partial-ship recovery all still run and can abort. If a
   gate aborts, do not force past it; record the blocker and hand it off.

Because step 1 proved **both** rungs clean — `release == main` (1a) and nothing
else parked on `accepted` (1b) — the fast-forward carries only the expedited
task to `main`. Step 1a alone would not be enough: the sweep in step 3 promotes
everything on `accepted`, so a task parked there rides along however clean
`release` looked.

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
task, and it is sound only while `accepted` carries exactly one task, which is
precisely the express lane's own precondition (step 1b).

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

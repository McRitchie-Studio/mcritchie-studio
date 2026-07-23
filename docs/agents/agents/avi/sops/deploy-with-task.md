# Deploy With Task

## Status: Active

This is Avi's `deploy-with-task` SOP. It expedites ONE task through review, QA,
and production ship, guarded on a clean release. The operator may launch it bare
(`deploy-with-task`) or with the task inline (`deploy-with-task <task>`).

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
  `release`.
- The release is clean: `release == main`. The guard in step 1 proves it.

## Procedure

1. **GUARD — is the release clean?**

   ```bash
   bin/release status --clean-only
   ```

   It reads the tasks already riding `release` and each repo's
   `origin/release`-ahead-of-`origin/main` count.

   - **Clean** (`release == main`, exit 0) → continue.
   - **Dirty** (exit non-zero) → **STOP**. Fast-forwarding `release → main`
     ships **everything** on `release`, so expediting one task past pending
     work would drag along whatever is `assembled` but unshipped. Report the
     pending work the guard printed and recommend: *"Ship the WHOLE release
     instead: run the `full-cycle` launcher."* Never force past the guard.

2. **Review the one task.** Run the single-PR cascade from the registered
   review primitive
   [`../../../modules/pr-review-sop.md`](../../../modules/pr-review-sop.md):
   Avi (the SUPERVISOR) confirms product acceptance and picks the pair
   (`bin/reviewer-select <task> --busy-auto`), then spawns the PRIMARY and LIGHT
   reviewers in parallel as siblings — the PRIMARY does the deep review, the
   LIGHT a focused second read; on all-clear the supervisor drives
   `bin/task move <task> reviewed`. Any block ends the expedite — fix,
   resubmit, re-run this SOP.

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

   The sweep merges the task's PR onto `release`, runs the pre-QA gate,
   deploys QA, and flips the member `assembled` on QA-green.

4. **Ship it.** From the primary checkout (not a worktree):

   ```bash
   bin/release ship --by conductor --yes
   ```

   `--yes` answers only the non-interactive confirmation — the clean-main
   preflight, frozen-SHA ship tests, gem publish ordering, deploy smoke,
   release notes, and partial-ship recovery all still run and can abort. If a
   gate aborts, do not force past it; record the blocker and hand it off.

Because step 1 proved `release == main`, the fast-forward carries only the
expedited task to `main` — nothing else rides along.

## Exit Seam

The named task is `shipped` and the release is clean again, or the guard
refused with the pending work listed. Report:

- task slug and release slug
- production SHA and production URL
- smoke result
- on a guard refusal: the pending work and the `full-cycle` recommendation

## Background — not needed to execute

- [`../../steffon/sops/production-deploy.md`](../../steffon/sops/production-deploy.md) - the batch ship act this SOP
  borrows its gate semantics from.
- [`../../avi/sops/qa-release.md`](../../avi/sops/qa-release.md) - the
  sweep act behind step 3.
- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model (architecture).

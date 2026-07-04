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
   Avi confirms product acceptance and picks the pair
   (`bin/reviewer-select <task> --busy-auto`); the PRIMARY reviewer performs
   the deep review, spawns the LIGHT reviewer, and on all-clear drives
   `bin/task move <task> reviewed`. Any block ends the expedite — fix,
   resubmit, re-run this SOP.

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

- [`production-deploy.md`](production-deploy.md) - the batch ship act this SOP
  borrows its gate semantics from.
- [`../../steffon/sops/qa-release.md`](../../steffon/sops/qa-release.md) - the
  sweep act behind step 3.
- [`../../../system/devops-cycle-design.md`](../../../system/devops-cycle-design.md)
  §1.4 - release atom model (architecture).

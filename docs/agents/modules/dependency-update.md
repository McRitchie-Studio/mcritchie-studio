# Dependency Update — bump a dependency when something asks for it
<!-- registry: reactive gem and action bumps: advisory, bundler-audit red, builder need, drift at release -->

Dependencies move when something asks for it, never on a calendar. Alex McRitchie
ruled on 2026-11-10 that CI costs too much and that "everything should be reactive
as part of an SOP" (task `ci-runs-reactive-and-once`). So no repo carries a
scheduled `.github/dependabot.yml`, and each repo keeps a guard test that fails if
one comes back (`test/lib/scheduled_dependabot_off_test.rb`). This SOP is how a
bump starts now. It stands alone: every command is inline.

## The four triggers

Run this SOP when one of these happens, and only then.

| # | Trigger | Where you see it |
|---|---------|------------------|
| 1 | **A security advisory** names a gem or action a repo uses | A GitHub Dependabot alert or security-update PR, a GitHub advisory, or a report from Alex McRitchie |
| 2 | **bundler-audit is red** | The `ci / static` lane of a repo whose CI passes `gem-audit-command: bin/bundler-audit` (cyvasse, moms-app, voicebox), or `bin/bundler-audit` run in a desk |
| 3 | **A builder needs a newer gem** | Your own task: a feature or a fix needs an API, a bug fix or a version a newer release has |
| 4 | **Drift is reported at release** | `bin/release` prints `producer locks not settled`, a `relock_cardless_consumers` warning, or `assert_no_lock_drift!`; or studio-engine's `bin/gem-drift-check` reddens its PRs |

A GitHub Actions deprecation warning in a run (an action on a retired Node) is
trigger 3: the run itself is the builder's need.

## What is NOT a trigger

- A newer version exists. That is not a reason to move.
- A calendar date. Nothing here is scheduled.
- Our own gems. `bin/release` moves every consumer's lock to a studio-engine or
  solana-studio final by itself: consumer apps at prepare and ship, and
  studio-engine's own solana-studio lock at ship step 5d
  (`bin/release.rb#bump_producer_locks_for_accepted`). Run this SOP for our gems
  only when that step warns (trigger 4).

## Steps

1. **Open your activity** and name the trigger in it:
   `/Users/alex/projects/.agents/bin/agent-activity start --category Edit --reason "dependency-update: <gem> for <trigger>"`.
2. **Fold, do not fan out.** One task covers every bump the same trigger asks for
   across the repos it names. Before you begin, read the board for an open task
   that already holds this bump: `/Users/alex/projects/.agents/bin/task list --stage building`.
3. **Begin the task.** A bump is a `chore`, or a `bug` when the trigger is an
   advisory or a red audit. Shape `backend`, risk `deps`:

   ```bash
   /Users/alex/projects/.agents/bin/task begin --title "Bump <Gem> For <Reason>" \
     --repo <app> --kind chore --shape backend --risk deps \
     --accept "<gem> resolves <version> or newer; the suite is green" \
     --test "[unit] bin/bundler-audit is clean" --test "[integration] the PR's CI run"
   ```

   For more than one repo, name every repo with `--repo` on `bin/task update`
   (it REPLACES the list), and open a PR in each one.
4. **Bump the one gem, conservatively**, in the desk:

   ```bash
   cd <desk>
   bundle lock --update <gem> --conservative   # moves <gem> alone, not its neighbours
   bin/bundler-audit                           # where the repo has it
   ```

   A major version is its own task. Read the gem's changelog first and say in the
   task what changed.
5. **For trigger 1, read the advisory itself.** Name the fixed version, and say
   in the task whether the vulnerable code path is reachable in this app.
6. **Run the suite the repo's CI runs** (`bin/fast-check <task>` from the desk).
   Then hand off with `/Users/alex/projects/.agents/bin/submit-wait <task> --launch -m "<message>"`.
   The PR goes into `accepted` and walks the ladder like any other change.

## A Dependabot security-update PR

When security updates are on for a repo, GitHub opens the PR against the default
branch, `main`, and `target-branch` cannot change that. Never merge a PR into
`main`: `bin/release ship` pushes `main` without force, so one merged PR there
aborts the next production ship. Retarget it to the first rung, then treat it as
trigger 1:

```bash
gh pr edit <n> --base accepted -R McRitchie-Studio/<repo>
```

## Security updates are a repository setting

Turning off the scheduled config does not turn off security updates. They are a
repository setting, separate from `.github/dependabot.yml`. On 2026-11-10 they
read as follows (`gh api repos/McRitchie-Studio/<repo>/vulnerability-alerts` and
`.../automated-security-fixes`):

- Dependabot **alerts** are on for every public repo and off for every private
  one (alex-build, commercial-welding, mcritchie-industries, rolio, voicebox).
- Dependabot **security-update PRs** are off on every repo.

Turning either on is Alex McRitchie's decision
([`dependency-decisions.md` CONFIG-1](../maintenance/dependency-decisions.md)).
Until he decides, trigger 1 comes from the public repos' alerts and from trigger 2.

## Related

- [`../maintenance/dependency-decisions.md`](../maintenance/dependency-decisions.md):
  the record of the old Dependabot backlog and the config findings.
- [`building-sop.md`](building-sop.md): the build flow every bump runs.

# Clean Up

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](../../../modules/token-session.md)).

## Status: Active

Xan's `clean-up` SOP. It drives the DevOps pipeline to **zero open tasks** and
leaves the local infrastructure with nothing hanging: no stranded worktrees, no
orphaned PRs, no half-built desks, no tmp residue.

Finished work does not close itself: a stranded task with a green, mergeable PR
sits one command short of the handoff while `release` moves underneath it. So
**assume the board overstates the work left.** Measure before you judge.

**Scope:** triage every open task, ship what is finishable, archive what is not,
sweep the infrastructure. One stuck session's work, rather than the whole board, is
[`wrap-it-up`](../../pokemon/sops/wrap-it-up.md). **Ship-authority gated** — see Preconditions.

## Preconditions

1. **Alex has explicitly assigned the ship lane this session.** This SOP
   merges to `release` and fast-forwards `main`. Without that assignment, run
   Phases 0-2 and 5 only, and stop at `reviewed`.
2. Run from the McRitchie Studio primary checkout (`cd
   /Users/alex/projects/mcritchie-studio`) against the production board; do not
   pass `--local`.
3. **Cap every fan-out at 5 concurrent operations.** The board's Postgres has a
   20-connection hard limit that parallel reviewers, `heroku run` dynos and the
   `bin/task` CLI can exhaust together. A queue of sixteen runs as four waves.

## Phase 0 — Scope guard (the carve-out)

Alex often runs a second session while this one works. Do not archive its tasks,
reclaim its worktrees, or review its PRs. Ask once, before touching anything:
*"Is any other session running? Name it and I'll carve it out."* Record **both** the session identity he gives (a Pokémon mascot and a short hash,
e.g. `Sudowoodo …38bc`) and any subject area (e.g. "GitHub CI/CD"). Every task a
session files carries its mascot (`bin/task field <slug> mascot`). A finding that
lands squarely in a carved-out subject is not filed: **hand it off in the final
report.** Re-check the carve-out before every destructive act, and when in doubt,
leave it alone.

## Phase 1 — Census (measure, don't trust)

**Never triage from the board UI's column counts.** Get the records:

```bash
for s in designed building submitted reviewed assembled blocked; do
  echo "=== $s"; bin/task list --stage $s
done
```

`blocked` is an attribute of a `building` task; `--stage blocked` resolves through
`Task.blocked`. **A bare `bin/task list` prints one page of 20 rows.** When the stage
holds more, its last line reads `(20 of N — pass --all or --json for every row)`;
otherwise it reads `(N task(s))`. Pass `--all` to print every row in the same
three-column form, or `--json` for every row as data. There is no `--limit` flag.

Join the board to GitHub, the highest-value query in the SOP:

```bash
# Which open tasks ALREADY have a PR?
gh pr list --limit 50 --json number,title,headRefName,baseRefName,isDraft,mergeable,statusCheckRollup \
  --jq '.[] | "PR #\(.number) [\(.baseRefName)<-\(.headRefName)] draft=\(.isDraft) mergeable=\(.mergeable) checks=\([.statusCheckRollup[]? | select(.conclusion != null) | "\(.name):\(.conclusion)"] | join(","))"'
```

**A green, mergeable PR is a REVIEW candidate, not a SHIP candidate.** Every PR
still gets its full review: green CI cannot see a cert lane that runs zero tests or
a purge that truncates the shared development database. The goal is an empty
board, not a fast one.

Capture the infra baseline now, because one number gates a later phase:

```bash
bin/agent-worktree list
bin/agent-worktree scale status     # read `free:`
bin/agent-worktree cleanup          # dry run: what is SAFE to release
git status --short                  # the primary must be clean before any ship
```

**If `scale status` reports `free: 0`, reclaim before any build.** On a full Redis
band `bin/agent-worktree new` half-builds a desk with no port, no stack env and no
isolated test DB, so its tests hit a shared database.

## Phase 2 — Triage every open task

One evaluator subagent per task, in waves of at most 5. Each returns one
disposition; put every judgement to Alex as a table with a recommendation per row.

| Disposition | Meaning | Test |
|---|---|---|
| **SHIP** | Built; PR green + mergeable. | Send it to review. |
| **BUILD** | Not built, but earns its keep today. | An **active hazard**, or a **cheap port of a fix that already shipped elsewhere**. |
| **ARCHIVE** | Off the board, no code. | See the rubric. |
| **PARK** | Stays open by explicit operator decision. | Only Alex may park. Record the reason. |
| **HAND OFF** | Belongs to a carved-out session. | Report it; do not file it. |

**Archive when any holds:** it patches a blacklist that a sound positive invariant
already backstops; it is self-marking in the code (`@quarantine`, a named `TODO`, a
skipped suite); it is persistent and will recur with better information; or its
premise moved.

**Do not archive when:** the fix is already written and merely unlanded (Phase 4's
orphaned-fix trap); it is an active hazard now; it is the mechanical port of a
companion change that just shipped; or you cannot identify who holds it.

**Grep for references before you archive.** "Self-marking" holds only when the code
marks the **debt**, not the **ticket**: an archived task that live code cites as
the open ticket driving a ceiling down leaves that ceiling on a dead link.

```bash
grep -rn "<task-slug>" --include='*' . | grep -v '^./\.git'
```

Open each hit and ask whether the code depends on the task being OPEN.
**Provenance** ("fixed in task `X`", "12 → 10 (/tasks/X)") and **false hits** (the
slug is also a feature name) do not block, because archived tasks stay readable
(`bin/task show <archived-slug>` resolves; there is no delete verb). A **live
ticket** blocks: park the task or repoint every reference.

### The archive verb's two gates

`bin/task move <slug> archived` exits 1 without touching the board when either gate
refuses. The gates guard the CLI path only; `Task#archive!`, the board's Archive
buttons and a raw API PATCH bypass them by design.

**The holder gate** refuses when a desk bound to the task on this machine has
uncommitted changes (or unreadable git status), and names each desk. Establish the
holder with `bin/agent-presence` and `bin/agent-worktree list` before you pass
`--force`. A run that needs `--force` on more than a task or two is reporting a
gate defect; say so rather than working around it.

**The open-PR gate** reads `devops.pr_url` and every `devops.pr_urls` entry. It
proceeds when the task is already `archived`, has no PR, or all its PRs are merged
or closed; it **refuses when any PR is still OPEN**, naming each; it proceeds with a
warning when a state cannot be read (the GitHub App token expires about hourly).
`shipped` is not exempt: the `merged` stamp is per task while PRs are per repo, so
`OpenPrGuard::CONCLUDED_STAGES` is `%w[archived]` alone. Do not close the PR on
autopilot to clear the refusal; read it (`gh pr view <n> --repo <owner/repo>`), then land it (`gh pr merge`), drop
it deliberately (`gh pr close`), or archive and abandon it with `--force`, which
records every PR it drops in `devops.abandoned_prs`; `bin/task show <slug>
--verbose` prints that receipt back.

### Find the orphans that already exist

`bin/release archive` flips shipped tasks through the model path, which bypasses
the gate, so sweep with `bin/task orphan-prs` (read-only; PRs still OPEN whose task
is already archived). A PR with an abandonment receipt reports as abandoned on purpose;
anything else reports as **ORPHANED** and needs a decision. A repo it could not
read is named as unchecked: **report it by name**, never as clean. Steffon's
[`archive-shipped`](../../steffon/sops/archive-shipped.md#the-orphan-sweep--the-coverage-for-the-model-path)
runs the same sweep on every production release; this run is the deep clean and
adds Phase 4's no-task PR triage.

## Phase 3 — Drain (ship everything shippable)

### 3a. Re-certify and inspect from the task's own worktree

A task that sat in `building` with an open PR has almost certainly gone stale, and
often holds work its PR never received:

```bash
cd /Users/alex/projects/mcritchie-studio/.worktrees/<task>
bin/fast-check <task> && bin/dor-check <task>
git status --short          # uncommitted  = the PR is INCOMPLETE
git status -sb | head -1    # [ahead N, behind M] = the PR is NOT what you certified
```

A `test-only` task's control stamp binds to a git tree hash
(`config/feature_shapes.yml`), so **a `STALE` you cannot explain is a `cd` bug until
proven otherwise.** A cert that produced no output did not pass: under load
`bin/fast-check` can die silently, looking like one still running. Re-run it.

- **Uncommitted changes: do not discard them reflexively.** Delegate an
  evaluation: is the work complete, coherent with the committed half, and green? A
  rubocop offense in it marks a dead session, since the pre-commit hook runs
  rubocop and the commit never ran.
- **`ahead N, behind M`**: the branch was rebased locally and never pushed. Verify
  it touches only its own files before force-pushing:
  ```bash
  git fetch -q origin accepted
  git diff origin/accepted...HEAD --stat    # must be ONLY this task's files
  git push --force-with-lease origin feat/<task>
  ```

### 3b. Submit, review, ship

Move each task to review from its worktree with `bin/task move <task> submitted`
(it does not wait for CI). Take the review lane, then run the review wave, delegated, per
[`pr-review`](../../carl/sops/pr-review.md): **one Carl per PR**, primary reviewer
and owner, who summons his light, drives the verdict and merges approved work into
`accepted`.

```bash
bin/devops-shift acquire avi
```

Three sequencing rules, each a correctness rule:

- **Read the batch for bugs between the PRs.** List every file touched by more than
  one PR and read those regions together. Ask of each pair: *does A's artifact
  become B's input?* (locks, temp files, fingerprints, env vars, anything left on
  disk). Disjoint hunks auto-merge with no conflict to prompt a look, and a fix that
  depends on merge order is a convention; make it structural.
- **One review wave at a time.** Wait for a wave to report before starting the
  next. The `avi` shift lease is advisory (`bin/devops-shift status` can report no
  shift while two waves run), so sequence the waves yourself.
- **Never review a task that is being reworked**; the reviewer reads the old head.
  Clear a stale block on the record:
  ```bash
  bin/task note <task> --resolves-feedback --handoff "STALE BLOCK — the review raced the rework. <what was already fixed, and in which commit>"
  ```

Then **direct-drive** the sweep and the ship yourself, in the foreground: they
mutate shared state for minutes, and a detached subagent leaves a half-applied
release candidate nobody owns. Delegate reads; direct-drive mutations. Release the
lane when the wave is done.

```bash
bin/release prepare      # merges reviewed tasks into release, deploys QA → assembled
bin/release ship         # fast-forwards release → main, deploys prod → shipped
bin/devops-shift release avi
```

**Hand delegates hypotheses, not findings.** Say "hypothesis" when it is one, name
who claimed it and on what evidence, and tell the agent to verify before fixing. A
reviewer's prescribed fix is itself a hypothesis; the builder holds the
measurement. Retract a wrong instruction loudly and at once.

## Phase 4 — Infra sweep

Desks, the Redis band, regenerable disk, orphaned per-desk databases, stale stack
pids and tmp residue belong to **[`clean-infra`](../../steffon/sops/clean-infra.md)**,
the single source for their mechanics. Run it in full, and supply what only this SOP can:

- **This run's Phase 0 carve-out**, plus any desk you deliberately left in Phase 3.
- **The worktree reclaim before any build in this run**; the rest after the ship.
- **Its improvement suggestion**, carried into the Phase 5 report.

Two of its rules decide most judgement calls here. **Clean + merged is not
sufficient**: a new worktree is git-identical to a merged one, so a bound desk
stands until its task reaches a stage in `bin/agent-worktree#RECLAIMABLE_STAGES`. **Trust the safety gate over
the description**: if Alex says three worktrees and the dry run finds seventeen,
surface it and believe the gate. File anything uncertain on the desk ledger
(`bin/agent-worktree cleanup --write`) rather than deleting it.

### Orphaned PRs — a PR with no task

This triage is board and GitHub state, not `clean-infra`'s. For every PR with no
board task, **read the diff before you close it**:

```bash
gh pr list --limit 50 --json number,title,mergeable --jq '.[] | "#\(.number) \(.mergeable) \(.title)"'
```

**Never merge a PR into `main`.** `release` and `main` sit at the same SHA and
`bin/release ship` pushes `main` without force, so one PR merged into `main` aborts
the next production ship. Each `.github/dependabot.yml` sets `target-branch:
accepted` per `updates:` entry, but security updates and an unconfigured repo still
target `main`. Retarget to the ladder's first rung with `gh pr edit <n> --base
accepted`, never to `release`.

**The orphaned-fix trap.** A conflicting PR with no task is where fixes go to die.
Diff each of its ideas against the current branch before closing it: it is
superseded only if you can point at the code that supersedes it. Preserve the diff
(`gh pr diff <n> > docs/agents/maintenance/pr<n>-<subject>.diff`), and record what
you did not build in
[`../../../maintenance/parking-lot.md`](../../../maintenance/parking-lot.md).
Finally, `git status --short` in every primary checkout must come back clean.

## Phase 5 — Verify and report

**Prove zero. Do not assert it.** `bin/task` can print success without persisting,
so read the board back before you claim a number:

```bash
for s in designed building submitted reviewed assembled blocked; do
  echo "=== $s"; bin/task list --stage $s
done
bin/agent-worktree scale status
gh pr list --limit 50
```

Report to Alex:
- **The number**: open tasks before → after, and every parked task with its reason.
- **What shipped**, with the production URL.
- **What was archived**, and why, one line each.
- **Handed off**: findings belonging to the carved-out session.
- **Infra**: worktrees reclaimed, Redis band before → after, PRs closed or
  retargeted, and `clean-infra`'s improvement suggestion.
- **What the run taught you.** Fold any new trap into this SOP in the same pass.

## Background — not needed to execute

The two-workflow release model is `../../../system/devops-cycle-design.md`, the gates
(DoR, G2–G4) are `../../../modules/gates/`, and worktree mechanics are `../../../modules/worktrees.md`.

History: the long form, with rationale and incident history, is [`clean-up-2026-10-05.md`](../../../archive/clean-up-2026-10-05.md).

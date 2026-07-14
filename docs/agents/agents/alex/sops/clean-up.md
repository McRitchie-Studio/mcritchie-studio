# Clean Up

## Status: Active

Alex's `clean-up` SOP. It drives the DevOps pipeline to **zero open tasks** and
leaves the local infrastructure with nothing hanging: no stranded worktrees, no
orphaned PRs, no half-built desks, no tmp residue.

## Why this exists

Mr. McRitchie thinks more clearly about high-level strategy against a clean
DevOps slate. A board carrying sixteen half-states is not a backlog — it is fog.

The failure this SOP treats is **not** that agents build too slowly. It is that
agents open tasks faster than they close them — and, the part that surprises
everyone, **finished work does not close itself.** In the founding run, **eight of
sixteen open tasks already had green, mergeable PRs.** Nobody had to build
anything. They sat one command short of the handoff, and every day they sat,
`release` moved underneath them and their certs went stale.

So the first rule of this SOP: **assume the board is lying about how much work is
left.** Measure before you judge.

## Scope

Triage every open task, ship what is finishable, archive what is not, sweep the
infrastructure. **Ship-authority gated** — see Preconditions.

## Preconditions

1. **Mr. McRitchie has explicitly assigned the ship lane this session.** This SOP
   merges to `release` and fast-forwards `main`. Without that assignment, run
   Phases 0-2 and 5 only, and stop at `reviewed`.
2. Run from the McRitchie Studio primary checkout:
   ```bash
   cd /Users/alex/projects/mcritchie-studio
   ```
3. Use the production board. Do not pass `--local`.

---

## Phase 0 — Scope guard (the carve-out)

Mr. McRitchie often runs a second session **while this one works**. Anything that
session touches is invisible to this SOP: do not archive its tasks, reclaim its
worktrees, or review its PRs.

Ask once, before touching anything:

> "Is any other session running? Name it and I'll carve it out."

He answers with a session identity — a Pokémon mascot and a short hash (e.g.
`Sudowoodo …38bc`) — and/or a subject area (e.g. "GitHub CI/CD"). Record **both**;
they catch different things.

- **By mascot** — every task a session files carries its mascot:
  ```bash
  bin/task field <slug> mascot
  ```
- **By subject** — a task it has not filed yet but obviously owns. When a finding
  lands squarely in the carved-out lane, do **not** open a task for it. **Hand it
  off in the final report instead.** A task filed into someone else's lane is just
  backlog with extra steps.

Re-check the carve-out before every destructive act. **When in doubt, leave it
alone.** A missed cleanup costs one command next time; a reclaimed worktree costs
someone their afternoon.

---

## Phase 1 — Census (measure, don't trust)

**Never triage from the board UI's column counts.** Get the records.

```bash
for s in designed building submitted reviewed assembled blocked; do
  echo "=== $s"; bin/task list --stage $s
done
```

> The board UI's **"blocked" column is not the `blocked` stage.** In the founding
> run it read "8 designed · 6 blocked · 2 reviewed", and `--stage blocked` returned
> **zero** — the six were `building`. Triaging from the UI would have hunted for
> blockers that did not exist.

Now join the board to reality. **The single highest-value query in this SOP:**

```bash
# Which open tasks ALREADY have a PR? These are your free wins.
gh pr list --limit 50 --json number,title,headRefName,baseRefName,isDraft,mergeable,statusCheckRollup \
  --jq '.[] | "PR #\(.number) [\(.baseRefName)<-\(.headRefName)] draft=\(.isDraft) mergeable=\(.mergeable) checks=\([.statusCheckRollup[]? | select(.conclusion != null) | "\(.name):\(.conclusion)"] | join(","))"'
```

Cross-reference every open task against that list. A task with a **green,
mergeable PR is not work — it is an un-pressed button.** Expect far more of these
than you think.

Capture the infra baseline now, because one number gates a later phase:

```bash
bin/agent-worktree list
bin/agent-worktree scale status     # read `free:` — see the WARNING
bin/agent-worktree cleanup          # dry run: what is SAFE to release
git status --short                  # the primary must be clean before any ship
```

> ### ⛔ A full Redis band silently breaks worktree creation
> If `scale status` reports **`free: 0`**, `bin/agent-worktree new` **half-builds**
> a desk: it errors, but leaves behind a worktree with no port, no stack env, and
> **no isolated test DB.** Tests then run against a shared database and the
> isolation guarantee is silently void.
>
> **Therefore Phase 4 (infra sweep) is a PRECONDITION of any build, not a tidy-up
> afterthought.** If the band is full and you intend to build, reclaim FIRST.

---

## Phase 2 — Triage every open task

One evaluator subagent per task, fanned out in **waves of ≤5** (see the cap
below). Each returns exactly one disposition:

| Disposition | Meaning | Test |
|---|---|---|
| **SHIP** | Built; PR green + mergeable. | Nothing to decide. Press the button. |
| **BUILD** | Not built, but earns its keep today. | It is an **active hazard**, or a **cheap port of a fix that already shipped elsewhere**. |
| **ARCHIVE** | Off the board, no code. | See the rubric. |
| **PARK** | Stays open by explicit operator decision. | Only Mr. McRitchie may park. Record the reason. |
| **HAND OFF** | Belongs to a carved-out session. | Report it; do not file it. |

### Archive when ANY of these holds

- **It is a patch on a blacklist.** A fix that enumerates failure *spellings* will
  always miss one. If a sound **positive invariant** already backstops it, the
  patch buys nothing.
- **It is self-marking in the code.** Debt already tagged in the repo
  (`@quarantine`, a named `TODO`, a skipped suite) needs no board row to stay
  visible. The code is the reminder.
- **It is persistent and will recur.** If the bug resurfaces on its own, you get
  another, better-informed chance at it. Archive; let it come back.
- **The premise moved** and it no longer makes sense.

### Do NOT archive when

- **The fix is already written and merely unlanded.** This is the expensive one —
  see *the orphaned-fix trap* in Phase 4. Landing it is cheap; re-deriving it
  later is not.
- **It is an active hazard right now** — corrupting state, lying to a gate, or
  about to make a newly-lit CI lane flaky.
- **A companion change just shipped and this is the mechanical port of it.** The
  context is hot. It will never be cheaper than today.

Put every judgement to Mr. McRitchie as a table with a recommendation per row. He
overrides freely; his overrides are the point.

---

## Phase 3 — Drain (ship everything shippable)

### 3a. Re-certify — expect every stranded cert to be STALE

A task that sat in `building` with an open PR has almost certainly gone stale:
`release` moved under it. Re-certify each **from its own worktree**.

> ### ⛔ `dor-check` reports a FALSE "STALE" from the wrong directory
> The cert fingerprint is a **git TREE hash** (`[full-suite@<git-tree-hash>]`, see
> `config/feature_shapes.yml`). Run `bin/dor-check <task>` from the **primary
> checkout** for a task whose code lives in a worktree and the trees can never
> match — it reports `STALE` for a perfectly good cert, naming the cwd nowhere.
>
> In the founding run this reported STALE for **six of six** tasks — including ones
> certified green ninety seconds earlier. It is very likely the trap that stranded
> them in the first place: an agent hits an unexplainable STALE and stops.
>
> **Run BOTH the cert and the gate from the task's own worktree:**
> ```bash
> cd /Users/alex/projects/mcritchie-studio/.worktrees/<task>
> bin/fast-check <task> && bin/dor-check <task>
> ```
> **A `STALE` you cannot explain is a `cd` bug until proven otherwise.**

### 3b. Inspect every worktree before you trust its PR

A stranded task frequently holds **work its PR never received** — a session that
died at the finish line. Check every one:

```bash
cd /Users/alex/projects/mcritchie-studio/.worktrees/<task>
git status --short          # uncommitted  = the PR is INCOMPLETE
git status -sb | head -1    # [ahead N, behind M] = the PR is NOT what you certified
```

- **Uncommitted changes — do not discard them reflexively.** Delegate an
  evaluation: is the work complete, coherent with the committed half, and green?
  In the founding run one worktree held **146 lines of finished, tested work** that
  its PR never saw — and that work *corrected a flaw in the committed half*.
  **A rubocop offense on a mere comment is the tell:** the pre-commit hook runs
  rubocop, so such an offense can only survive if **the commit never ran.** That is
  a dead session, not an abandoned experiment.
- **`ahead N, behind M`** — the branch was rebased locally and never pushed, so
  **the tree you certified is not the tree on the PR.** Before force-pushing,
  verify the branch touches ONLY its own files:
  ```bash
  git fetch -q origin release
  git diff origin/release...HEAD --stat     # must be ONLY this task's files
  git push --force-with-lease origin feat/<task>
  ```
  A stale-base rebase that quietly reverts `release` is a real failure mode. Look
  before you push.

### 3c. Submit, review, ship

```bash
bin/task move <task> submitted          # from the worktree; do NOT wait for CI
```

Run the review wave — **delegated**, per `pr-review`:

```bash
bin/devops-shift acquire avi
```
Summon an **Avi supervisor subagent** who selects and spawns a PRIMARY + LIGHT
reviewer pair per task, in parallel, as his own children. Avi supervises; he does
not review. See [`../../avi/sops/pr-review.md`](../../avi/sops/pr-review.md).

Then **direct-drive** the sweep and the ship yourself:

```bash
bin/release prepare      # merges reviewed tasks into release, deploys QA → assembled
bin/release ship         # fast-forwards release → main, deploys prod → shipped
```

Release the lane when the wave is done:
```bash
bin/devops-shift release avi
```

> ### ⛔ Delegate reads. DIRECT-DRIVE mutations.
> `pr-review` is a **read** act — a detached subagent costs a retry, nothing more.
> `qa-release` and `production-deploy` **mutate shared state across many minutes.**
> A subagent running the sweep has detached mid-flight and left a **half-applied
> release candidate that nobody owned.** Run those yourself, in the foreground.
> The line is **mutating vs reading**, not parallel vs serial.

---

## Phase 4 — Infra sweep (the hanging chads)

Run the worktree reclaim **before** any build (the band gates it); finish the rest
after the ship.

### Worktrees
```bash
bin/agent-worktree cleanup                   # dry run — read it
bin/agent-worktree cleanup --reclaim         # dry run: what is SAFE (clean + merged)
bin/agent-worktree cleanup --reclaim --yes   # full teardown + Redis band shrink
```
- Reclaim only takes **clean + merged** desks; live PR worktrees are never
  candidates. Check the list against your carve-out anyway.
- **Trust the safety gate over the description.** If Mr. McRitchie says "three
  worktrees" and the dry run finds seventeen, surface the discrepancy — and believe
  the gate.
- **`_gate` and `_ship` are infrastructure, not desks** — fixed-path workspaces for
  the cert and the ship. They ARE safe to reclaim: `bin/release.rb` re-creates them
  on demand with `git worktree add --detach`. Just never reclaim them **mid-ship**.

### Orphaned PRs — a PR with no task is a hanging chad
```bash
gh pr list --limit 50 --json number,title,mergeable --jq '.[] | "#\(.number) \(.mergeable) \(.title)"'
```
For every PR with no board task, **read the diff before you close it.**

> ### ⛔ NEVER merge a PR into `main`
> `release` and `main` normally sit at the **identical SHA**, and `bin/release.rb`
> ships with a **non-forced** `git push origin <sha>:refs/heads/main` that **fails
> closed on divergence**. A single PR merged into `main` puts a commit there that
> `release` lacks, and **the next production ship aborts.**
>
> Dependabot defaults to the repo's default branch, so it opens PRs against `main`
> by default. **Retarget, never merge:**
> ```bash
> gh pr edit <n> --base release
> ```

> ### ⛔ The orphaned-fix trap — the most expensive thing this SOP catches
> A conflicting PR with no task is **where fixes go to die.** In the founding run,
> one such PR held four guardrails; **three had never landed anywhere**, and every
> one mapped to a lesson the ecosystem had since re-learned by hand. The fixes had
> been *written* — then left to rot, while everyone re-suffered the bugs.
>
> **Before closing any stale PR, diff each of its ideas against the current branch
> and ask: did this actually land, or did we just re-suffer it?** A PR is
> "superseded" only if you can point at the code that supersedes it. **Being
> conflicted is not evidence of being obsolete.**
>
> Preserve the diff regardless — it is free:
> ```bash
> gh pr diff <n> > docs/agents/maintenance/pr<n>-<subject>.diff
> ```
> Then record what you did not build in
> [`../../../maintenance/parking-lot.md`](../../../maintenance/parking-lot.md) — the
> third state between *on the board* and *gone*.

### Everything else
```bash
git status --short                          # every primary checkout must be clean
bin/agent-worktree doctor                   # stale pids, missing DBs, orphaned Redis
bin/agent-worktree snapshot --write         # refresh the local registry
```
Kill stale stack pids, drop orphaned per-worktree databases, clear tmp residue.
Append anything you are unsure about to `../../../maintenance/delete-later.md`
rather than deleting it.

> **The reclaim dirties the primary.** It appends its audit rows to
> `delete-later.md` in the primary checkout — and **the ship requires a clean
> primary.** Move that change into a worktree and commit it through a PR; do not
> commit from the primary and do not throw the ledger away.

---

## Phase 5 — Verify and report

**Prove zero. Do not assert it.**

```bash
for s in designed building submitted reviewed assembled blocked; do
  echo "=== $s"; bin/task list --stage $s
done
bin/agent-worktree scale status
gh pr list --limit 50
```

> ### ⛔ `bin/task` can print success without persisting
> Read the board back before you claim a number. A move that printed fine and did
> not land strands the task — and the next session misreads it as a rival claim.

Report to Mr. McRitchie:

- **The number** — open tasks before → after, and every parked task with its reason.
- **What shipped**, with the production URL.
- **What was archived**, and why — one line each. He is entitled to disagree.
- **Handed off** — findings belonging to the carved-out session.
- **Infra** — worktrees reclaimed, Redis band before → after, PRs closed/retargeted.
- **What the run taught you.** Fold any new trap into this SOP **in the same pass.**
  This SOP is a living record of its own traps; a run that found a new one and did
  not write it down has wasted the lesson.

---

## The concurrency cap — ≤5, always

The production board's Postgres (essential-0) has a **20-connection hard limit.** A
heavy fan-out — parallel reviewers + `heroku run` dynos + the `bin/task` CLI + the
web/worker pools — has already blown past it once and **500'd the board.**

**Cap every fan-out at 5 concurrent operations.** Parallelism stays the default; it
is simply **bounded**. A queue of sixteen runs as four waves, never one.

---

## Background — not needed to execute

- Two-workflow release model: `../../../system/devops-cycle-design.md`
- The gates (G1–G4): `../../../modules/gates/`
- Worktree mechanics: `../../../modules/worktrees.md`

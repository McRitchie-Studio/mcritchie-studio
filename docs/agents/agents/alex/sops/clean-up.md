# Clean Up

> **Stale GitHub credential? Fix it yourself and keep going — do not escalate.**
> App installation tokens expire **~hourly BY DESIGN**. On `Bad credentials`, a
> 401/403, an unreadable CI, or a `gh auth login` prompt, run
> `eval "$(bin/gh-auth-refresh --export)"` — read its **stderr**, because `eval`
> hides the exit code — then retry the exact command that failed. Asking Mr.
> McRitchie to run `gh auth login` is both the terminal chore the operating model
> forbids and a step that cannot work: `gh` refuses to store a credential while
> `GH_TOKEN` is set. Architecture and symptom→fix: [`source-control.md`](../../../modules/source-control.md).

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

> ### ⛔ `bin/task list` TRUNCATES AT 20 — and says nothing
> The loop above prints the **first 20 rows of each stage only**: no total, no
> "truncated" line, and **`--limit` is not a valid flag**. On 2026-08-26
> `--stage shipped` showed **20** while `bin/release archive --dry-run` planned
> **32** from the same board — a third of the column invisible.
>
> A stage under 20 is exact, so the lie appears only once a column grows — which
> is precisely when you are running this SOP. Treat any stage returning exactly
> 20 rows as truncated until proven otherwise.
>
> **Count from `--json`, never from the rows:**
> ```bash
> bin/task list --stage shipped --json |
>   python3 -c "import json,sys; print(len(json.load(sys.stdin)))"
> ```

Now join the board to reality. **The single highest-value query in this SOP:**

```bash
# Which open tasks ALREADY have a PR? These are your free wins.
gh pr list --limit 50 --json number,title,headRefName,baseRefName,isDraft,mergeable,statusCheckRollup \
  --jq '.[] | "PR #\(.number) [\(.baseRefName)<-\(.headRefName)] draft=\(.isDraft) mergeable=\(.mergeable) checks=\([.statusCheckRollup[]? | select(.conclusion != null) | "\(.name):\(.conclusion)"] | join(","))"'
```

Cross-reference every open task against that list. A task with a **green,
mergeable PR is not work — it is an un-pressed button.** Expect far more of these
than you think.

> ### ⛔ "Green and mergeable" is a REVIEW candidate, not a SHIP candidate
> The line above is the most dangerous sentence in this SOP, because it tempts you
> to conflate *green* with *good* and wave the queue through. **Do not.** Every PR
> still gets its full review — that is not ceremony, it is the only thing standing
> where the gates cannot see.
>
> In the founding run, reviewers **blocked back 6 of 11** green, mergeable, CI-passing
> PRs. Among what they caught:
> - a cert lane that **ran zero tests** and stamped itself green
> - an orphan reaper that **killed an innocent process** (recycled pgid)
> - a guard that refused to fire `kill -TERM -1` in code — **and then printed it as
>   copy-paste remediation**
> - a test-only purge that, under `RAILS_ENV=development`, **truncates the shared
>   development database** — 70k+ rows
>
> Every one of those had a green suite and a green CI. As that last reviewer wrote:
> **"the green gates cannot see this defect."**
>
> The goal is an empty board, **not a fast one.** A cleanup that ships six broken
> PRs has not cleaned anything — it has moved the mess into production.

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

  > ### ⛔ GREP FOR REFERENCES BEFORE YOU ARCHIVE — this rubric has a trap in it
  > "Self-marking in the code" holds only when the code marks the **debt**. It does
  > NOT hold when the code marks the **ticket**.
  >
  > In the founding run I archived `repair-rotted-e2e-specs` on exactly this rubric —
  > 18 rotted specs, already tagged `@quarantine`, visible forever. But **eight places
  > in code and docs cited `/tasks/repair-rotted-e2e-specs` BY NAME** as the live
  > ticket driving the quarantine ceiling from 18 down to 0 — `ci.yml`,
  > `feature_shapes.yml`, `playwright.config.js`, two test files, three docs.
  > Archiving it turned 18 into a **permanent ceiling resting on a dead link.** A
  > reviewer caught it; I had shipped a broken promise.
  >
  > **Always, before archiving:**
  > ```bash
  > grep -rn "<task-slug>" --include='*' . | grep -v '^./\.git'
  > ```
  > **An archived task that live code cites as live is a lie the code tells.** If
  > anything references it, either keep the task alive (park it) or repoint every
  > reference — never just archive and walk away.
  >
  > **But the grep only tells you there IS a hit — not what it means.** Reading
  > every hit as blocking is the opposite error, and it freezes a `shipped`
  > column that should drain. Open each one and ask: *does this code depend on
  > the task being OPEN?*
  >
  > | Kind | Looks like | Blocks? |
  > |---|---|---|
  > | **Provenance** | "fixed in task `X`", "MEASURED HERE (/tasks/X)", "12 → 10 on 2026-08-21 (/tasks/X)" | **No** — records work already done |
  > | **Live ticket** | a ceiling or threshold `X` is the open ticket to drive down | **Yes** — the case above |
  > | **False hit** | the slug is also a feature name (`the hold-for-free-entry CTA` in `user.rb`) | **No** — not a task reference |
  >
  > Measured 2026-08-26: **nine of 32** shipped slugs were cited in live code;
  > **every one was provenance or a feature name.** `clear-the-quarantine-backlog`
  > sat in the very same `e2e_lane.yml` ceiling comment as the case above — but as
  > a completed step ("12 → 10"), not as the driver.
  >
  > Provenance is safe because **archived tasks stay readable**: `bin/task show
  > <archived-slug>` resolves, and there is no delete verb — only `move <slug>
  > archived`. The links survive.
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
- **You cannot identify who holds it.** `bin/task move <slug> archived` now
  refuses this case itself (see below) — but the refusal is a backstop for the
  judgement, not a replacement for it.

Put every judgement to Mr. McRitchie as a table with a recommendation per row. He
overrides freely; his overrides are the point.

### The archive verb refuses what it cannot prove free

`bin/task move <slug> archived` runs a holder gate before the write. It exits 1
**without touching the board** when it cannot prove the task holds no **work at
risk**, and names what it could not verify:

| Grade | What it means | Archive |
|---|---|---|
| `concluded` | `shipped`/`archived` — the code is on `main` | proceeds |
| | *(the open-PR gate below reads `shipped` differently — see it)* | |
| `unheld` | no session, no mascot, no claim: nobody picked it up | proceeds |
| `abandoned` | a session we could check, checked, and found gone | proceeds |
| `held` | a live claim lease | **REFUSES**, names the session |
| `working` | a desk written into, a cert running, or an operator parked | **REFUSES**, names the channel |
| `unverifiable` | a mascot or a builder, but **no session to ask** | **REFUSES**, names the paint it has |

**Work at risk is UNCOMMITTED state, which lives in a DESK.** Board activity is not
work at risk — a commit, a PR, a task note, a stage move all survive the archive and
read back afterwards — so a fresh board timestamp never holds this gate. That is
deliberate and it was measured: an earlier cut counted board activity as a channel
and refused **31 of 34** live tasks, 16 of them with no desk at all, because
`holder_liveness_seconds_ago` reports the age of a task's own CREATE when no holder
owns an artifact — and because every `bin/task` write resets it, so **triaging a task
in Phase 2 would arm the gate against archiving it in Phase 5**. Steffon's
`archive-shipped` SOP documents the same trap for the worktree reclaim.

So expect `working` refusals to name a **desk**. If one names something else, read it
— it is telling you a cert is running or Mr. McRitchie is parked in front of the work.

`unverifiable` is the one worth knowing by name, because it is the carve-out's
failure mode made mechanical. On 2026-09-01 Mr. McRitchie asked that one session's
work be held; the record carried an app and a mascot and nothing else, and the
holder was found only by messaging the peer session. Had that session been idle or
unreachable, live work would have been archived and the exception would have
protected nothing. A mascot means *somebody was here and we cannot tell who* —
which is the opposite of *nobody was here*, not a synonym for it.

`--force` is the override, and it names the grade it waived:

```bash
bin/agent-presence                       # who is live on this machine right now
bin/agent-worktree list                  # which desk carries the task, and whose
bin/task move <slug> archived --force    # only after you have established the holder
```

Reach for those two readers before `--force`, not after. **A run that needs `--force`
on more than a task or two is reporting a gate defect, not a busy machine** — say so
rather than working around it, because a `--force` that becomes routine is a gate that
protects nothing.

The gate is the **CLI path** by design. `Task#archive!`, the board's Archive buttons,
and a raw API PATCH all bypass it: it exists to stop an *agent* archiving work it
never looked at, and Mr. McRitchie clicking Archive on a task page he is reading is
already the deliberate decision `--force` represents.

### And it refuses what would leave a PR open

A **second** gate runs right after the holder gate, and it asks a different question:
would this archive leave an **OPEN PR** behind? It reads `devops.pr_url` **and** every
`devops.pr_urls` entry — a multi-repo task records its second repo's PR only in the
map — and refuses, naming each PR and its state.

| PR states | Archive |
|---|---|
| the task is already `archived` | proceeds — a re-archive is idempotent |
| no PR recorded | proceeds |
| all merged / closed | proceeds |
| **any still OPEN** | **REFUSES**, names every PR and its state |
| a state that could not be read | proceeds, with a **warning** naming the PR |

**`shipped` IS NOT EXEMPT HERE**, and that is the one row that differs from the
holder gate's table above. That gate reads `shipped`/`archived` as `concluded`
because merged code leaves nothing uncommitted to destroy — true, and about a
different question. It says nothing about whether **every** PR the task named
actually landed: the `merged` stamp is per-**TASK** while PRs are per-**REPO**, so a
multi-repo task reaches `shipped` on its primary while a sibling repo's PR is still
open. That is the population this gate most exists for — `move-web3-modals-to-solana`
below is exactly it — so inheriting the skip would exempt the shape most likely to
strand. `OpenPrGuard::CONCLUDED_STAGES` is `%w[archived]` alone, deliberately.

**This is not the holder gate's question.** That one guards UNCOMMITTED work an
archive would destroy, and a PR is durable so it never holds that gate. But *survives*
is not *resolved*: an archived task's open PR is neither merged nor closed, no board
state describes it, and nothing downstream will raise its hand about it again.
Measured 2026-09-01 — `move-web3-modals-to-solana` was archived while studio-engine
**#245** stayed open, carrying 169 lines of tests, and the PR's own stated blocker was
discharged the next day. It surfaced a **month** later, only because a human asked for
a backlog audit.

**Do not close the PR to clear the refusal on autopilot.** Archiving is how you drop
work, and a dropped branch may hold the only copy of a design; `archived` is also not
a lock — a task an operator dropped has been un-archived and shipped since. Decide:

```bash
gh pr view <n> --repo <owner/repo>     # is the work still wanted?
gh pr merge <n> --repo <owner/repo>    # land it
gh pr close <n> --repo <owner/repo>    # drop it deliberately
bin/task move <slug> archived --force  # archive AND abandon the PR — recorded
```

`--force` here records the abandonment in `devops.abandoned_prs`, so a later reader
can tell a PR that was dropped **on purpose** from one that was **forgotten**. That
distinction is the whole reason the override records rather than merely warning. It
covers **every** PR the override drops — the open ones and any whose state could not
be read, since one keystroke abandoned both — and `bin/task show <slug> --verbose`
prints it back under `abandoned_prs`, which is how you confirm the receipt landed:

```bash
bin/task show <slug> --verbose        # abandoned_prs: the receipt, or "-" for none
```

**An unreadable PR state warns rather than refusing**, deliberately: the GitHub App
token expires about hourly by design, so refusing on it would refuse most archives on
most days — and a gate that refuses everything gets `--force`d until it protects
nothing. The warning says the check did not complete; it never claims the PR is open.

### Find the orphans that already exist

The gate only stops **new** orphans, and `bin/release archive` flips shipped tasks
through the model path, which bypasses the CLI gate entirely. So sweep for the ones
already on the board:

```bash
bin/task orphan-prs          # PRs still OPEN whose task is already archived
```

Read-only, never blocks, and one `gh pr list` per repo rather than one call per PR.
A PR carrying an abandonment receipt reports as *abandoned on purpose*; anything else
reports as **ORPHANED** and needs a decision. A repo it could not read is named as
unchecked rather than counted as clean — **report it by name.** A run that prints
`0 orphaned PR(s)` while warning about a repo has said nothing about that repo, and
reporting that as clean converts an unknown into a false all-clear.

**This same sweep now also runs on the beat**, as the closing step of Steffon's
[`archive-shipped`](../../steffon/sops/archive-shipped.md#the-orphan-sweep--the-coverage-for-the-model-path),
which rides the end of every production release. The two occurrences are
deliberate and not redundant: that one is the **beat** — it fires on every
archive, so an orphan surfaces within a release cycle instead of waiting for a
human to ask for a backlog audit. This one is the **episodic deep clean** an
operator invokes when the board has already fogged, and it pairs with Phase 4's
no-task-at-all triage, which the beat does not do. Keep both saying the same
thing about an unchecked repo.

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
>
> Want to confirm it? Run `bin/dor-check` from the primary against SEVERAL different
> tasks. Pre-fix it printed the **identical fingerprint for every one of them** — it
> was hashing its own tree and never looked at the task's code at all.

> ### ⛔ A cert can die SILENTLY under concurrent load
> Run heavy suites in parallel and a `bin/fast-check` can simply vanish: **0-byte
> output, no process, nothing recorded on the board.** A cert that died looks
> *identical* to a cert still running — so an agent sits waiting on a corpse.
>
> **If a cert produced no output, it did not pass. Re-run it; never assume.** This is
> the sharpest argument for the ≤5 concurrency cap: the failure is not merely a
> crash, it is an *invisible* crash.

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
Spin **one Carl per PR** — the standing primary AND owner (no Avi supervisor) —
who summons his own domain LIGHT for a focused second read, drives the verdict,
and merges approved work into `accepted`. See
[`../../carl/sops/pr-review.md`](../../carl/sops/pr-review.md).

> ### ⛔ THE SIGNATURE RISK OF A CLEANUP: bugs that live BETWEEN the PRs
> A cleanup ships a dozen PRs at once. Each is reviewed alone, each is correct alone —
> **and the bug is in the interaction.** No single reviewer is looking there, and no
> gate can see it. **That is the supervisor's job, and nobody else's.**
>
> The founding run's sharpest catch was exactly this. One PR made the cert **refuse a
> dirty tree** (reading `git status --porcelain`, which sees untracked files). Another
> PR's crash-detection **runlock lived at `tmp/cert-run.json`** — and two repos do not
> gitignore `tmp/`. Composed: a killed cert leaves its runlock (**by design** — the
> lock surviving IS the detection mechanism), the next cert sees `?? tmp/`, aborts as
> DIRTY, and **the orphan preflight never runs.** The exact 35-minute deadlock the
> second PR existed to fix — restored, permanent, and triggered by the guard's own
> artifact.
>
> **The detail that makes this a rule, not an anecdote: the hunks were DISJOINT.** Git
> auto-merged them cleanly. There was no conflict to force a human to look. The
> supervisor **overrode two merge-ready verdicts** to catch it.
>
> So, before the sweep:
> - **List every file touched by more than one PR in the batch** and read those regions
>   together, as one change.
> - Ask of each pair: *does A's artifact become B's input?* Locks, temp files,
>   fingerprints, env vars, and anything one PR **deliberately leaves on disk** are the
>   places to look.
> - **A merge-order rule is a CONVENTION, not an invariant.** If correctness depends on
>   two hunks landing in a particular order, that is not a fix — fix it structurally so
>   the order cannot matter.

> ### ⛔ ONE review supervisor at a time. Never overlap two waves.
> A cleanup needs SEVERAL review waves, and the tempting optimisation — start wave N+1
> while wave N is still draining — is a correctness bug, not a speed-up.
>
> In the founding run I did exactly that. **Two Avi supervisors wrote verdicts into the
> same queue concurrently**, and one produced a send-back describing code the other's
> rework had already fixed. It cost a full round-trip and, on the board, was
> indistinguishable from a real failure.
>
> **Do not rely on the `avi` shift lease to save you.** It is supposed to prevent this
> — but in that run `bin/devops-shift status` reported **no shift held at all** while
> two supervisors were live. The lease has a short TTL and depends on a renewal that a
> long-running subagent does not reliably perform. **Treat it as advisory, and
> sequence the waves yourself.**
>
> Wait for the wave to REPORT before starting the next one. If a wave is slow, that is
> the cost of a correct verdict.

> ### ⛔ NEVER review a task that is being reworked — the review will race the fix
> A blocked task goes back to `building` and an agent starts fixing it. If a review
> wave is still running, a reviewer can read the **old head** and block a bug that is
> already fixed — producing a send-back that describes code no longer on the branch.
>
> This happened in the founding run: a task was blocked for a defect its own HEAD had
> already closed, verified green, and pushed. The rework was correct; the review was
> reading history. It cost a full round-trip and looked, on the board, exactly like a
> real failure.
>
> **Sequence the waves. Do not overlap review with rework on the same task.** When a
> stale block does slip through, do not silently re-move the task — clear it on the
> record so the next reader is not misled:
> ```bash
> bin/task note <task> --resolves-feedback --handoff "STALE BLOCK — the review raced the rework. <what was already fixed, and in which commit>"
> ```

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

### 3d. When you delegate, hand over HYPOTHESES — never findings

You will be triaging a dozen tasks you did not build, relaying diagnoses you did not
verify. **Label them as what they are.** A conductor who launders someone else's
hypothesis into a fact sends an agent to fix a phantom — or worse, to install a fix
that does not work.

Both happened in the founding run:

- I relayed "27 test failures, they're yours, fix them" as a finding. It was a
  hypothesis, and it was **wrong** — CI was green on the combined code. An agent was
  most of the way into hunting a ghost before the original reporter re-checked his own
  claim and retracted it, unprompted.
- A reviewer prescribed a precise fix for a database guard: *read back the connected DB
  and compare it to `configs_for(env_name: "test").database`.* I passed it on as the
  fix. The builder **measured it instead of trusting it — and it was a PLACEBO.** Rails
  merges `DATABASE_URL` into the config for the *current* env, and under the suite the
  current env IS `test`. So the expectation **moves with the attack**: it compares a
  moved value against itself, passes, and truncates the shared database anyway. He
  mutation-proved it by installing the prescribed anchor and watching the test go RED.

So:

- **Say "hypothesis" when it is one**, name who claimed it and on what evidence, and
  tell the agent to **verify before fixing**. An agent who pushes back and refuses to
  fix a phantom is doing the job right.
- **A reviewer's prescribed fix is itself a hypothesis.** Reviewers are excellent and
  still wrong sometimes. The builder is the one holding the measurement.
- **Retract loudly and immediately.** A stale instruction left standing costs more than
  the embarrassment of correcting it.

---

## Phase 4 — Infra sweep (the hanging chads)

Run the worktree reclaim **before** any build (the band gates it); finish the rest
after the ship.

### The infra sweep — run `clean-infra`

The desks, the Redis band, the regenerable disk, the orphaned per-desk databases
and the stale stack pids are all
**[`clean-infra`](../../steffon/sops/clean-infra.md)**'s, and it is the single
source for their mechanics. Run it, in full, here.

Three things this phase owes it, which no other caller can supply:

- **The Phase 0 carve-out is the carve-out.** `clean-infra` asks its caller to
  name what is off-limits before it starts. Hand it this run's list — everything
  this session touched, plus any desk you deliberately left alone in Phase 3.
- **Run the worktree reclaim BEFORE any build in this run** — the band gates
  allocation — and leave the rest until after the ship.
- **Its improvement suggestion is required**, and it belongs in this SOP's Phase 5
  report. `clean-infra` ends every run with one concrete proposal for making the
  next sweep smaller; carry it up rather than dropping it.

Two rules from it decide most of the judgment calls a board sweep runs into.
They are restated here only because getting them wrong destroys work:

- **Clean + merged is NOT sufficient, and never was.** A brand-new worktree is
  git-identical to a merged one, so it passes the git test vacuously; on
  2026-08-13 that destroyed a live builder's desk mid-task. Expect finished desks
  to linger up to 1h29m before the sweep will take them.
- **Trust the safety gate over the description.** If Mr. McRitchie says "three
  worktrees" and the dry run finds seventeen, surface the discrepancy — and
  believe the gate.

The orphaned-PR triage below is NOT part of `clean-infra`. It is board and
GitHub state, and it stays here.
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
> unless the config says otherwise. Every repo's `.github/dependabot.yml` **must**
> set `target-branch: accepted` on **every** `updates:` entry — it is per-entry,
> not global. Two gaps survive that config, so this check still earns its place:
> **security** updates always target the default branch and cannot be retargeted,
> and a repo onboarded without the setting falls back to `main`.
> **Retarget to the ladder's first rung, never merge:**
> ```bash
> gh pr edit <n> --base accepted
> ```
> Retargeting to `release` is also wrong — it leaves `accepted` behind `release`
> and reproduces the divergence this SOP exists to prevent.

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
```

The stale pids, orphaned per-desk databases, tmp residue and registry refresh are
[`clean-infra`](../../steffon/sops/clean-infra.md)'s step 5 — run there, reported
here. File anything you are unsure about on the desk ledger
(`bin/agent-worktree cleanup --write`) rather than deleting it.

> **The reclaim no longer dirties the primary.** Its audit rows land on the board
> (`DeskRecord`, on the Desks panel at `/deployments`), not in
> `docs/agents/maintenance/delete-later.md` — which a sweep run from the primary could
> never commit, stranding 166 rows across twelve stashes and the primary's uncommitted
> tree (recovered by `bin/harvest-desk-ledger`). A teardown REFUSES when the board
> is unreachable, before anything is destroyed, so re-run the same command once it
> answers.

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

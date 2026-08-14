# Worktrees

Parallel agents should use git worktrees rather than sharing one checkout.
The default for any code or active-doc edit is to work in an isolated worktree
with an allocated port.

## Fresh Worktree Checklist

**Steps 1-3 are what `bin/task begin` automates** — it is the default path for a
single-repo task (`bin/task begin --title "Three To Five Words" --repo <app> …`,
or `bin/task begin <task-slug>` to resume), and it prints the worktree path,
port, and task URL. (`begin` runs step 3 below with `--root <worktree>`, so its
preflight inspects the desk it just created.) Run the checklist by hand when the
fast lane does not fit, and use steps 4-10 either way — `begin` does not cover
them.

Run these in order. Each step names the command and the proof it worked.

1. **Create the desk** — `bin/agent-worktree new <app> <task-slug>` from the
   mcritchie-studio primary. It cuts `feat/<task-slug>` from the base ref —
   `origin/accepted` when the repo has one, falling back to `origin/release`,
   then `origin/main` (`base_ref_for`) — copies the primary `.env`, writes
   `.env.agent-stack` (allocated port, isolated dev DB, Redis DB,
   `LOCAL_EMAIL_CAPTURE=1`), provisions the isolated test DB, and builds
   `app/assets/builds/tailwind.css`.
2. **Bind the task immediately** — `bin/agent-worktree bind-task <app>
   <task-slug> <task-record-slug-or-url>`. `new` does NOT auto-bind. Unbound,
   the session has no task URL (terminal context, PR body) and the desk sits
   outside the live-claim guard — the exact window a cleanup sweep once
   destroyed.
3. **Preflight the desk** — `bin/session-preflight` ships ONLY in
   mcritchie-studio. For a hub desk, run the worktree's own copy from inside
   it (`cd /Users/alex/projects/mcritchie-studio/.worktrees/<task-slug> &&
   bin/session-preflight <task-slug>`): the script roots at its own file
   location, so the primary's copy inspects the primary checkout instead. For
   a satellite desk (Turf Monster, Rolio, …), the script does not exist in
   that repo — run the hub primary's copy pointed at the desk:
   `bin/session-preflight <task-slug> --root
   /Users/alex/projects/<repo>/.worktrees/<task-slug>`. Hub-owned helpers —
   `bin/task` and `config/feature_shapes.yml` — resolve from the script's own
   repo, never from `--root`, so a satellite desk needs no `--file` task-JSON
   dump (`--file` remains a manual escape hatch, not the satellite path); only
   the inspected-tree checks (drift, dirty tree, doc drift, stale scan) read
   from `--root`. Read the output as
   signal, not a to-do list: drift, changed files, and PR overlap are measured
   against the same ladder base the desk was cut from — `origin/accepted`,
   falling back to `origin/release`, then `origin/main`, mirroring
   `base_ref_for` in `bin/agent-worktree` — and the report names the ref it
   compared against. Resolve what touches YOUR task — blocked feedback, stale
   terminology, overlap on files you will edit — before editing.
4. **Verify env and port** — `.env` exists in the worktree, and
   `bin/agent-worktree whereami` prints the app, task URL, port, database, and
   Redis DB. No port means the stack env is missing; re-run `new`.
5. **Verify assets and test DB** — `new` runs `bin/rails db:test:prepare
   test:prepare` under `RAILS_ENV=test` best-effort; a printed warning means
   it failed. Confirm `app/assets/builds/tailwind.css` exists: the directory
   is gitignored, and `bin/rails test <file>` skips the asset build, so a
   missing `tailwind.css` is the classic first-test failure (`The asset
   "tailwind.css" is not present in the asset pipeline`). Recovery:
   `RAILS_ENV=test bin/rails db:test:prepare test:prepare` in the worktree.
   `RAILS_ENV=test` is load-bearing: dotenv loads `.env.test.local` (which
   pins `TEST_DATABASE_URL` at the isolated test DB) only in the test env —
   without it the test section resolves to the SHARED `<app>_test` database
   and the command prepares the wrong one.
6. **Boot before any live preview** — `bin/agent-worktree up <app>
   <task-slug>`. It runs `bin/rails db:prepare` first (a hand-started `rails
   server` without it 500s with `NoDatabaseError`), boots the stack in the
   background, and polls `/up` until 200.
7. **Prove the URL before claiming it** — hand out a demo URL only after `/up`
   returns 200. `up` prints `(/up 200)`; re-check any time with
   `bin/agent-worktree status <app> <task-slug>` or
   `curl -s -o /dev/null -w "%{http_code}" http://localhost:<port>/up`.
8. **Know your data** — the stack DB (`<app>_development_<task-slug>`) is NOT
   the base dev DB. It starts from `db:prepare` (schema + seeds), not from the
   primary's data. Never assume shared records; seed what the demo needs.
9. **Run tests through the wrapper** — `bin/agent-worktree test <app>
   <task-slug>` is the canonical path in EVERY repo: it re-runs the test-env
   prep (isolated test DB + tailwind build), then runs the suite hermetically
   — `RAILS_ENV=test`, the isolated test DB, and `PARALLEL_WORKERS=1`
   injected by the wrapper (single-process BY DESIGN: parallel workers
   deadlock cloning a cold test DB). A plain `bin/rails test` is an
   acceptable substitute ONLY in the mcritchie-studio hub, whose
   `test_helper` defaults local runs to one worker and whose `.env.test.local`
   pins the isolated test DB. In Turf Monster and Rolio a plain run forks
   `:number_of_processors` workers, and Turf's test config has no
   `TEST_DATABASE_URL` seam — neither single-process nor isolated, so use the
   wrapper. Do not source `.env.agent-stack` before tests.
10. **Email lands locally** — `LOCAL_EMAIL_CAPTURE=1` is the stack default;
    magic links and all other mail appear at
    `http://localhost:<port>/_studio/local_emails`, never in a real inbox.

## Current Direction

Avoid visible sibling directories such as `turf-monster-feature-name` as the long-term default. They make `/Users/alex/projects` hard to scan at scale.

Preferred layout:

```text
/Users/alex/projects/<repo>                 # primary checkout
/Users/alex/projects/<repo>/.worktrees/<task-slug>
```

Do not include an agent id in the path. Tasks can transfer between agents, and multiple agents may collaborate on one branch.

Think of worktrees as desks and primary checkouts as loading docks. Agents do
feature work at desks. The primary checkout stays stable for reading,
integration, final merge, and deploy.

## Startup Rule

When a new agent session starts actual implementation work:

1. Identify the target app and the feature being requested. Accumulate
   acceptance criteria until Mr. McRitchie and the agent are aligned on the
   goal. If implementation starts with any remaining ambiguity, call it out in
   the task and handoff.
2. Create or update the production McRitchie Studio task-board item before
   editing. The production `Task.slug` is immutable and generated by the app;
   use `metadata["devops"]["worktree_slug"]` for the human-readable feature
   handle. The task should include acceptance criteria, affected repos, risk
   tags, expected `test_plan`, and release-slug metadata when relevant.
3. Inspect the primary checkout only for status and context.
4. Run `bin/agent-worktree plan <app> <task-slug>`.
5. Run `bin/agent-worktree new <app> <task-slug>`.
6. Bind the production task URL with
   `bin/agent-worktree bind-task <app> <task-slug> <task-record-slug-or-url>`
   so `whereami`, terminal context, snapshots, and PR bodies can lead from the
   task record.
7. Move the task to `building`.
8. Run `bin/agent-worktree up <app> <task-slug>` when a browser or local URL is
   needed.
9. Make edits only inside `/Users/alex/projects/<repo>/.worktrees/<task-slug>`.
10. When the local behavior is ready for Mr. McRitchie to inspect, keep the task
   in `building` and mark it for operator validation:

   ```bash
   bin/task update <task-slug> --local-url http://localhost:<port>/<path> --approval waiting
   ```

   In chat, return the URL in this exact top-level format:

   ```text
   Task: https://mcritchie.studio/tasks/<task-slug>
   Local Demo: http://localhost:<port>/<path>
   Local Inbox: http://localhost:<port>/_studio/local_emails   # only for email/auth flows
   ```

   Waiting approval cards float to the top of their stage and pulse on the board.
   A `waiting` request is legal only before the `submitted` seam. Past it the PR
   review flow owns the work, so any save at `submitted` or later settles an open
   request to `none` — settled, never a fabricated `approved`. After requested
   changes, set `--approval changes_requested` and keep building.
11. Commit coherent work on the feature branch.
12. Run `bin/agent-worktree finish <app> <task-slug>` to produce the PR/QA
   packet.
13. Update the task with branch, PR URL (`finish --push --pr` stamps it for
   you; verify), local URL, `checks_run`, and any changed acceptance criteria. Add a task conversation `handoff` note with the
   change summary, verification, and review focus. Move it to `submitted` when
   the PR is ready for Avi.
14. Return the task URL first, then the PR URL, branch, worktree path, local
   URL, tests, and PR/QA recommendation in the handoff. Do not merge to `main`
   unless assigned the QA/Release lane.

Exceptions:

- Pure read-only audit or exploration can stay in the primary checkout.
- The explicit deploy owner may use the primary checkout for integration,
  version bumps, deploy commits, and production rollout.
- Emergency fixes can use the fastest safe path, but the handoff must say why
  the worktree path was skipped.

## Launcher

Use McRitchie Studio's launcher for new parallel task stacks:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-worktree apps
bin/agent-worktree plan turf-monster docs-stack
bin/agent-worktree new turf-monster docs-stack
bin/agent-worktree bind-task turf-monster docs-stack task-abc123def456
bin/agent-worktree up turf-monster docs-stack
bin/agent-worktree finish turf-monster docs-stack
```

The launcher creates `/Users/alex/projects/<repo>/.worktrees/<task-slug>`, branches from the current **base ref** — `origin/accepted` when the repo has one (the persistent feature-PR target), else `origin/release`, else `origin/main` — copies the primary `.env`, writes `.env.agent-stack`, prepares the isolated database, and prints the local URL.

Use `bin/agent-worktree status <app> <task-slug>` to recover the URL later, and `bin/agent-worktree down <app> <task-slug>` to stop a running stack.
Use `bin/agent-worktree finish <app> <task-slug>` when the work is committed
and ready for PR/QA handoff.

## Lifecycle

Use the launcher as the source of truth for worktree stack state:

```bash
bin/agent-worktree list
bin/agent-worktree whereami
bin/agent-worktree bind-task turf-monster task-slug task-abc123def456
bin/agent-worktree shell-hook zsh
bin/agent-worktree status turf-monster task-slug
bin/agent-worktree finish turf-monster task-slug
bin/agent-worktree doctor
bin/agent-worktree snapshot
bin/agent-worktree cleanup
bin/agent-worktree cleanup --reclaim
bin/agent-worktree cleanup --reclaim --yes
bin/agent-worktree remove turf-monster task-slug --yes
bin/agent-worktree scale status
```

- `list` shows task, health, URL, branch, dirty state, merge state, ahead/behind, database, Redis DB, pidfile state, and local inbox URL.
- `bind-task` stores the production McRitchie Studio task record slug and URL in
  the generated stack env, then refreshes `.agent-context.json`. Pass either
  `task-<hex>` or `https://mcritchie.studio/tasks/task-<hex>`. Use this after
  the production task exists and before PR handoff so the terminal context and
  PR body lead from the task record.
- `whereami` reads the nearest `.agent-context.json` marker and prints the app,
  production task record, task URL, task/worktree slug, branch, local URL, port,
  Redis DB, database, terminal title, prompt badge, and shell exports. Pass
  `<app> <task-slug>` to refresh the marker for a known stack, `--json` for
  machine-readable output, or `--shell` for exports/title commands. The shell
  form recomputes exports from validated scalar context fields at runtime and
  ignores any persisted executable shell content in `.agent-context.json`.
- `shell-hook zsh` prints a zsh hook that refreshes `AGENT_CONTEXT_*`
  variables and the terminal title whenever the prompt redraws or the working
  directory changes. It does not edit shell dotfiles; source it explicitly when
  you want evergreen terminal titles.
- `status` shows the detailed state for one generated stack.
- `finish` prints a feature graduation packet and PR body. It blocks dirty
  worktrees, branches with no commits ahead of the base ref, stale branches
  behind the base ref, and already-merged branches. Add `--push` to push the
  branch. `--push --pr` additionally requires a bound production task record
  from `bind-task`, then creates a draft PR **based on the base branch
  (`accepted`, else `release`, else `main`)** through `gh` when available, and stamps the
  created PR's URL onto the bound task (`devops.pr_url`) in the same handoff
  (best-effort: a board blip warns with the manual `bin/task update --pr-url`
  command instead of failing the finish).
- `doctor` reports lifecycle drift such as missing stack env files, reused ports, reused Redis DBs, stale pidfiles, dirty worktrees, disabled local email capture, and clean branches already merged to the base ref. It also reconciles `git worktree list` against the managed registry per repo and flags any **orphan** — a git worktree that is neither the primary checkout nor a managed `.worktrees/*` dir — with its path, branch, and merge/clean state. An orphan whose directory was deleted on disk but is still tracked by git is reported distinctly as **prunable** (clear it with `git -C <repo> worktree prune`); `doctor` and `snapshot --write` both tolerate it and still exit 0. Orphans are detect-and-report only; removal stays approval-gated (`bin/agent-worktree remove`).
- `snapshot` prints a non-secret JSON registry of every generated worktree,
  including health, local URLs, branch state, Redis DB, database name, cleanup
  candidacy, compare URL, and doctor issues. The payload also carries a
  top-level `capacity` block (`floor`, `step`, `current`, `used`, `free`,
  `physical_max`) describing the elastic Redis band.
- `snapshot --write` writes the same registry to
  `/Users/alex/projects/.agents/worktree-registry.json` for conductor sessions,
  dashboards, and future automation. Set
  `AGENT_WORKTREE_REGISTRY=/tmp/worktree-registry.json` when a sandboxed
  session needs a scratch write instead of the shared projects registry.
- `cleanup` is a dry run. It prints clean worktree candidates whose branch is
  either contained in the base ref (`origin/accepted`, else `origin/release`, else `origin/main`) or has
  an empty final diff against the base ref after a squash merge. A branch merged
  into `accepted` but not yet shipped to `main` therefore counts as done. Each
  candidate prints the exact safety class (`merged` or `base-equivalent`), base
  ref, ahead/behind count, stack health, `/up` code, pidfile state, Redis DB,
  database state, and the exact `bin/agent-worktree remove … --yes` command. Use
  that dry run as the approval packet before deleting anything.
- `cleanup --write` appends candidates to [`../maintenance/delete-later.md`](../maintenance/delete-later.md). It does not remove files, worktrees, branches, databases, Redis keys, or processes.
- **The occupancy guard (why git state alone is not enough).** A worktree is a
  candidate only when it is git-eligible **AND nobody is working at it**. A
  brand-new worktree off `release` and one whose work was **fast-forward merged**
  are **git-identical** — both clean, both `HEAD == base`, both 0-ahead — so
  `cleanup_ready?` provably cannot tell a desk someone just sat down at from
  finished work. **Four** independent channels answer that question, and every
  destructive path, `doctor`, and the registry route through ONE decision
  (`reclaim_verdict` → `[reclaimable?, hold_reason]`), so the conductor's front door
  can never nominate a desk the sweep would refuse. A withheld desk is named with its
  reason, and **every branch that gives up on checking says so**, because a guard that
  silently disables itself is worse than no guard. A *nominated* desk is explained too:
  the dry run prints a `rationale:` line and the ledger row carries the same
  `Cleared: …` sentence, naming which questions were asked and what came back — see
  **Every nomination explains itself** below.
  - **The CLAIM channel** asks the board who holds the task: the **live build-claim
    lease** (`ClaimLease`, renewed by the builder's status line under a 120s TTL). A
    confirmed hold names the builder's heartbeat age, so the hold is checkable. The
    board read is genuinely bounded (10s, `AGENT_WORKTREE_TASK_TIMEOUT`) because it
    kills the child — a hung or black-holed board cannot stall a sweep.
  - **The DESK channel** (`desk_hold`) asks the filesystem whether anyone is at the
    directory, and it exists because the claim channel has a hole it structurally
    cannot cover. **2026-08-13: a `cleanup --reclaim` sweep destroyed a desk a builder
    had just created and was working in.** The desks most at risk carry no live claim
    to read — inside the `new → bind-task → move building` window, half-allocated by a
    failed `bind-task`, or simply between renewals — so all of them read as free, and
    the blast radius is another session's **uncommitted** work, which no gate, review,
    or CI can catch because it never becomes a commit. Three signals, all reusing the
    lease work's own arithmetic (`ClaimLease.abandoned?`) rather than inventing a
    second notion of "is the holder working":
    - **desk age** (`DeskActivity.age_seconds`, read off the worktree `.git` marker) —
      a desk cannot have been idle longer than it has existed, so anything younger
      than `ClaimLease::DESK_IDLE_SECONDS` (1h29m) is held. Not a new threshold: it is
      the floor the existing one implies.
    - **desk mtimes** (`DeskActivity.touched_since?`) — an agent that is working writes
      files; one that has walked away does not. Committing does not touch a working
      file, so a desk whose work has merged still carries the mtimes of the edits that
      made it — clean, landed, and occupied.
    - **the holder's gate** (`holder_gate_in_flight`) — a cert writes **nothing** into
      its desk for up to the measured 94-minute p99, so an hour-old desk mid-cert is
      invisible to both signals above. This is why an age threshold alone was not the
      fix.

    Every unknown holds the desk, the same rule the claim lease uses: an undatable
    desk or an unreadable walk is withheld, and the hold says "we could not check"
    rather than claiming a builder nobody confirmed.
  - **The PR channel** (`pr_hold`) asks GitHub whether the branch's work actually
    **landed**, because git-eligibility does not. A branch whose diff against the base
    is empty — the base moved on, an equivalent change landed by another route — is
    git-eligible while its pull request is still **open and unmerged**: litter to git,
    live work to the pipeline. An open PR withholds the desk (reclaim deletes the local
    branch). `gh` answering "none" frees it; `gh` **unreachable** falls back to the
    board — a task carrying a `pr_url` with no `merged` stamp is unlanded work and is
    withheld, while a merged stamp or no PR at all frees it. That fallback, rather than
    a flat fail-closed, is deliberate: `gh` is optional tooling, and withholding every
    desk on a machine without it would wedge the sweep permanently and silently.
  - **The REVIEW channel** (`review_hold`) asks the board whether a **reviewer** is on
    the task (`review_in_progress`). Review is a second lane with its own claim: a
    reviewer works the builder's desk — reading it, running its suite, merging from
    it — without ever taking the BUILD claim, and mostly READS, so the desk's mtimes
    stay quiet. **2026-08-14: a sweep nominated a desk another live session was
    reviewing.** Positive signal only, so an older board that cannot answer does not
    re-decide the unreadable-board case the claim channel already owns.
  - **The release WORKSPACES (`_ship`/`_gate`) are held by ANY live release claim, not
    just a ship's.** They are fixed-path infrastructure `bin/release` recreates on
    demand, so they carry no bound task and would otherwise fail open through the
    unbound branch. `claim_hold` withholds them whenever a live `ReleaseConductorClaim`
    exists in **either** role (`RELEASE_CLAIM_ROLES` = `assembler` + `deployer`), and
    withholds on a can't-tell read. **2026-08-14: the guard asked about `deployer`
    alone**, on the reading that `_ship` is "the tree the deploy works in". It is not —
    `bin/release prepare` (the assembler, Avi's `qa-release` sweep) merges release
    branches forward and runs `bundle lock` for every consumer **inside `_ship`**. So
    during a live prepare the deployer claim was legitimately free, and a reclaim listed
    both repos' `_ship` desks as "safe: merged on `origin/accepted` (clean)" while the
    sweep was writing in them. A role added to `ReleaseConductorClaim::ROLES` must be
    added to `RELEASE_CLAIM_ROLES` too: asking one role of a two-role lifecycle is not a
    narrower guard, it is a guard that is absent half the time.
  - **A QUIET desk is still a HELD desk — quiet never makes it reclaimable.** The
    board also reports a task's last *durable* progress beside its liveness (see
    [`devops-task-board.md`](devops-task-board.md#the-build-claim-liveness-and-progress-are-two-facts)),
    and a live claim that has landed nothing in hours reads `quiet`. That is
    **informational**: `quiet` is not an input to `reclaim_verdict` at all, and every
    channel it does read can only ADD a hold — none can free a desk another channel
    kept. So a quiet desk is withheld exactly like a busy one. This is on purpose.
    A healthy build legitimately goes silent for a long time (certs reach 94
    minutes at p99), so reclaiming on staleness would trade a rare lying-green for
    a **frequent lying-red** — and a false reclaim destroys work in flight. A human
    reads the progress fact and decides; the sweep never does.
  - **Fail-open, except where it would destroy something.** When the guard reads the
    claim, the dispositions short of a *confirmed, parseable* live lease are *not*
    alike, and the destroy path treats them differently:
    - **lapsed** — we checked; the builder is gone. Reclaimable everywhere. ✔
    - **unbound** — we cannot *identify* the desk, so there is no claim to look up.
      The CLAIM channel is forced to fail open (withholding every unidentifiable desk
      would wedge cleanup), and it warns. The **desk channel still judges it**, so an
      unbound desk is protected while it is fresh or in use and released once cold.
    - **corrupt** — a claim is present but its lease timestamp is *unparseable*, so
      liveness cannot be checked. **Withheld everywhere**, exactly like an unreadable
      board: a desk we cannot verify must never read as free on a destroy path. But
      the hold is named *honestly* — `claim expiry unverifiable … inspect task
      <slug>`, **not** `held by a live builder` — because we never confirmed a
      builder, only that we could not check (and there is no heartbeat age to report).
      `ClaimLease.corrupt_expiry?` exists precisely to make this branch. Distinct from
      a **blank** expiry, which is a never-renewed relic and stays fail-open (lapsed):
      the renewer always writes an expiry, so blank means dead, unparseable means
      unreadable.
    - **bound, but the board could not be read** (500 / timeout / auth) — we know the
      desk *could* be claimed and simply failed to find out. It is **withheld
      everywhere**. The board 500s under Postgres pressure during heavy parallel
      devops — exactly when many worktrees exist and the sweep gets run — so outage
      and mass-reclaim are **correlated, not independent**, and failing open reopens
      the original incident precisely when everyone believes it is covered. The costs
      are asymmetric: withholding during an outage is a **deferral** (re-run when the
      board is back); nominating a desk you could not verify leads to an
      **irreversible teardown**.
  - **There is no "advisory" lane.** Every caller answers one question — *is this desk
    a cleanup candidate?* — and that answer is consumed to **destroy**: the registry
    feeds `bin/qa-intake`, which prints a `remove … --yes` per candidate; the `cleanup`
    dry-run prints the same command; `cleanup --write` files the desk in the
    delete-later ledger; `doctor` labels it a candidate. An earlier cut split these
    into "destroy" and "advisory" lanes and let the advisory ones fail open — so during
    exactly the outage this guard exists to survive, the sweep withheld a live
    builder's desk while the conductor's front door recommended tearing it down. During
    an outage the truthful answer is *"I cannot tell"*, and **withholding is that
    answer**; nominating is the lie. The one exception is `remove … --yes` — the
    explicit operator override, which warns and proceeds.
  - **The unbound desk was the gap, and the desk channel closed it.**
    `TASK_RECORD_SLUG` is written by `bind-task`, never by `new`, so a builder inside
    the `new → bind-task → move building` window has no task and therefore no claim to
    check. That is the exact desk both incidents destroyed. The claim channel still
    fails open on it and still says so; the **desk channel** now judges it on age and
    mtimes, so a fresh or busy unbound desk survives and a cold one is still collected.
    Bind the task immediately after `new` anyway — a bound desk gets the gate channel
    too, which is the only thing that sees a holder mid-cert.
  - **What this costs, stated plainly.** Desks now linger up to
    `ClaimLease::DESK_IDLE_SECONDS` (1h29m) after their work is done, holding a Redis
    band slot while they wait. That is a real trade against band pressure, taken
    deliberately: disk and a slot are recoverable, a destroyed desk is not.
    `remove <app> <task> --yes` still tears one down on demand, so nothing is stuck —
    only nothing is automatic.
  - **Every nomination explains itself.** `safe: merged on origin/accepted (clean,
    +0/-0)` is a **git fact**, and it was true of all three load-bearing desks the
    2026-08-14 sweep offered up. So a nominated candidate also prints
    `rationale: <what each channel asked and answered>` in the dry run
    (`reclaim_evidence` → `rationale`), and the `delete-later.md` row carries the same
    sentence as `Cleared: …` beside the git facts. Read it as the approval packet: a
    channel that could not be asked says so there (`GitHub unreachable`), which is how
    you spot a sweep running with a blind guard **before** approving 29 teardowns. A
    desk removed against a hold (the explicit `remove … --yes` override) files the
    **hold** in that cell instead — an archive row never borrows the language of a
    cleared candidate.
- `cleanup --reclaim` is the **scale-down-on-close normal flow**: a merged
  worktree self-releases its Redis slot the same way a stack scales down when it
  closes. The dry run (no `--yes`) lists only the worktrees that are SAFE to
  auto-remove — clean, either contained in the base ref or base-equivalent, **and
  unoccupied** (`reclaimable?`: no live build-claim, no reviewer on the task, no open
  unmerged PR on the branch, and a desk old enough, quiet enough, and with no gate in
  flight to be called abandoned) — and prints the same safety evidence, rationale, and
  removal command as `cleanup`. It never lists a dirty, unmerged, claimed, fresh, or
  actively-edited worktree, never a desk whose PR is still open, and never `_ship`/
  `_gate` while a release conductor holds a claim; the candidate set is sourced from
  `.worktrees/*` only, so the primary checkout is never a candidate.
- `cleanup --reclaim --yes` runs the **same full teardown as `remove`** for each
  safe candidate (stop the stack, flush the stack's Redis DB, update the cleanup
  ledger, remove the Git worktree, delete the stale local branch), re-verifying
  each candidate under the worktree lock — **including a fresh re-read of the build
  claim**. That re-read matters: the candidate list is computed once, but teardowns
  run serially inside the lock, so a builder who sits down and claims a task
  mid-sweep would otherwise have their clean `HEAD == base` desk destroyed on
  minutes-stale evidence. A worktree that turned dirty/unmerged **or newly claimed**
  in the interim is skipped, with the reason printed. After the batch it shrinks the
  Redis band toward the floor (`maybe_scale_in`) and refreshes the registry once.
  Output names each reclaimed worktree, the freed Redis DB, and the resulting band
  size. Safe to re-run; with no candidates it prints a clear no-op message (naming
  any desks withheld for a live claim) and changes nothing.
- **`remove … --yes` is the explicit operator override and is deliberately NOT
  blocked by the claim** — you may be evicting a desk whose session died mid-lease.
  It **warns loudly** when a live claim is present, but proceeds. The automatic paths
  (`cleanup`, `--reclaim`, and the registry the conductor reads) refuse a held desk
  outright, so nothing ever *recommends* that removal.
- `remove <app> <task-slug> --yes` is the approved deletion path after Mr.
  McRitchie or the conductor authorizes cleanup. It refuses dirty or
  non-equivalent worktrees, stops the stack, flushes the stack's Redis DB (so a
  reused DB number cannot inherit stale keys), updates the cleanup ledger, removes
  the Git worktree, deletes the stale local branch, shrinks the Redis band toward
  the floor when slots free up, and refreshes the registry.
- `scale status` prints the Redis band: floor, step, current band + DB range,
  used, free, and the physical ceiling (`databases` from Redis). `scale out` /
  `scale in` are manual nudges (respect floor and physical ceiling). `scale
  --provision [--yes]` raises the physical `databases` and restarts Redis once;
  see [Scale Note](#scale-note).

Deletion remains approval-gated:

1. Run `bin/agent-worktree cleanup <app>` to see candidates.
2. Confirm `bin/agent-worktree doctor <app>` has no dirty or unique-work
   warnings for the target.
3. After approval, run `bin/agent-worktree remove <app> <task-slug> --yes`.
4. Run `bin/qa-intake --refresh --apps <apps>` so the conductor view no longer
   reports the removed worktree.

## Squash-Merge Cleanup

GitHub squash merges do not preserve the feature branch SHA on the base. After a
PR lands, a branch can appear behind its base ref even when all of its content
was merged. Do not rely on ahead/behind alone.

The launcher now treats an empty final diff against the base ref
(`origin/accepted`, else `origin/release`, else `origin/main`) as a cleanup
candidate. Before removing a squash-merged worktree manually (substitute the
repo's resolved base ref):

1. Pull the primary checkout so `origin/accepted` is current.
2. From the feature worktree, confirm the final diff is empty:

   ```bash
   git diff --stat origin/accepted..HEAD
   git diff --name-status origin/accepted..HEAD
   ```

3. If both commands are empty, prefer
   `bin/agent-worktree remove <app> <task-slug> --yes` after approval.
4. If the diff is not empty, do not delete. The branch contains work not
   represented on the base; send it back through PR/QA or salvage deliberately.

## Rules

- Branch from the **base ref** (feature PRs target the persistent `accepted`
  branch, not `release`/`main`). This is the launcher default: `bin/agent-worktree
  new` cuts from `origin/accepted`, `finish --pr` opens the PR with `--base
  accepted`, and ahead/behind + cleanup/merge checks all reckon against
  `origin/accepted`.
  - **Fallback:** a repo with no `origin/accepted` falls back to
    `origin/release`, then `origin/main`, for the branch cut, the PR base, and
    the comparison base. The resolved base is reported per-worktree (`base_ref`
    in `snapshot`/registry, the `base:` line in `finish`).
- One task branch per worktree.
- Never commit task work on the primary `main` checkout unless you are the
  explicit deploy owner for that repo.
- A feature branch is the backup and collaboration unit. `accepted` is the
  reviewed integration lane (`release` is the QA lane; `main` is the shipped
  lane, fast-forwarded from `release` at ship time), not a place to rush code
  so it is not lost.
- Feature agents push their branch and open/prepare a PR into `accepted`.
  Review merges to `accepted`; Avi's `qa-release` promotes
  `accepted → release`; Steffon ships `release → main`.
- If the primary checkout is dirty, ahead, or moves while you are working, treat
  it as shared-floor drift. Do not fold those changes into your task silently.
  Report it and continue from the isolated worktree.
- Do not remove a worktree until its branch/PR status is known.
- Log stale worktrees in [`../maintenance/delete-later.md`](../maintenance/delete-later.md) before deleting them.

## Multi-Agent Safety & Merge Patterns

When several agents build in parallel and their work converges on **one branch**
— e.g. scaffolding a new app: Rolio's first cut was 4 gap features by 4 agents
merged together — isolation and merge discipline matter more than usual. The
patterns below came out of that run.

**Isolation — use a manual `git worktree add` per agent.**

- The Agent tool's `isolation: worktree` mode was **unreliable when the target
  repo differs from the session repo** — agents leaked their edits onto the main
  checkout instead of an isolated worktree. For cross-repo or multi-agent fan-out,
  give each agent an explicit `git worktree add -b <branch> .worktrees/<slug>
  <base>` and point it at that absolute path.
- One branch per worktree; never let two agents share a checkout (branches switch
  under you and files mutate mid-edit — see the "parallel sessions in shared
  worktree" lessons).

**Design the work to merge cleanly — new-files-first.**

- Prefer **new files** over editing shared ones. A feature that lands as its own
  partial, service, model, or stylesheet never conflicts.
- **Shared view edits = a new partial + a single `<%= render %>` line at a named
  anchor.** Each agent adds only its one render line at the agreed anchor; the
  body lives in the agent's own partial. Conflicts shrink to one predictable line.
- **Routes: additive blocks.** Each agent appends its own routes block (ideally a
  `namespace`/`scope` of its own) rather than editing a shared resource line.
- **One migration owner per integration.** Two agents writing migrations against
  the same tables will collide on `schema.rb`. Either nominate a single migration
  owner, or have the orchestrator **pre-add the columns** before fanning out so
  the agents only read them.

**The recurring conflict: the CSS end-of-file seam.**

- Multiple agents appending styles to the same stylesheet conflict at the
  **end-of-file**. This one is expected; **resolve it by keeping both blocks** —
  the changes are additive by construction. Don't agonize over it, concatenate.

**Merge sequentially, suite green between merges.**

- Integrate one branch at a time and **run the full suite green between each
  merge** — never batch-merge several agents' branches and test once at the end.
  A red suite after a sequential merge points at exactly one branch.

This is the multi-agent build path referenced by
[`../system/new-app-onboarding-sop.md`](../system/new-app-onboarding-sop.md).

## Handoff Contract

A feature-agent handoff should include:

- McRitchie Studio task URL first, then task slug, current stage, and acceptance
  criteria status.
- App, task slug, branch, and worktree path.
- Local review URL and local inbox URL when a server was started.
- PR URL or the exact reason a PR was not opened.
- QA-intake status when available, but do not use `bin/qa-intake` as a
  substitute for the task-board record.
- Task conversation status: whether any `qa_feedback` remains open in practice,
  and the latest `handoff` note the feature agent added.
- Tests/checks run and their result in task `devops.checks_run`.
- Files or behavior changed at a high level.
- The `bin/agent-worktree finish` result.
- Whether the branch is ready for Avi review, needs another agent, or needs
  release-conductor integration.

Do not leave Mr. McRitchie with "run these commands." Start the stack, prove the
URL, and name any blocker that truly needs owner action.

## Machine Registry

`bin/agent-worktree snapshot --write` is the local registry for scale. It does
not contain secrets and is safe to hand to another agent session as current
machine context.

Use it when:

- a QA or release conductor starts a shift
- multiple feature agents are active at once
- worktree ports, Redis DBs, or pidfiles appear inconsistent
- a dashboard or future supervisor needs a machine-readable queue

The registry is intentionally local under `/Users/alex/projects/.agents/`.
McRitchie Studio documents and owns the format, but the file itself reflects the
current machine and should not be treated as a Git-tracked source of truth.
If the agent runtime blocks writing to that directory, rerun the command with
filesystem approval or set `AGENT_WORKTREE_REGISTRY` to a writable scratch path.

## Terminal Context Markers

The launcher writes a non-secret `.agent-context.json` file into every generated
worktree during `new`, and refreshes it during `up`, `status`, and
`whereami <app> <task-slug>`. The marker is added to the repository's local
Git exclude file so it does not show as untracked work or enter commits.

Use it from inside a generated worktree:

```bash
bin/agent-worktree whereami
bin/agent-worktree whereami --json
bin/agent-worktree whereami --shell
```

If the current directory is nested below the worktree root, call the launcher by
absolute path or from the shell `PATH`; `whereami` walks upward until it finds
the marker.

Bind the production task record once the task exists:

```bash
bin/agent-worktree bind-task <app> <task-slug> task-abc123def456
bin/agent-worktree bind-task <app> <task-slug> https://mcritchie.studio/tasks/task-abc123def456
```

After binding, the marker carries both the human-readable worktree slug and the
generated production task record. `whereami --shell` exports the task record as
`AGENT_CONTEXT_TASK_RECORD`, the browser URL as `AGENT_CONTEXT_TASK_URL`, and
the human slug as `AGENT_CONTEXT_WORKTREE_SLUG`. The prompt badge includes the
production task slug when available. The shell output is generated from scalar
marker fields each time; agents must not store or trust executable shell lines
inside `.agent-context.json`.

For an evergreen terminal title in zsh, source the generated hook:

```bash
eval "$(/Users/alex/projects/mcritchie-studio/bin/agent-worktree shell-hook zsh)"
```

The hook exports:

- `AGENT_CONTEXT_APP`
- `AGENT_CONTEXT_TASK`
- `AGENT_CONTEXT_WORKTREE_SLUG`
- `AGENT_CONTEXT_TASK_RECORD`
- `AGENT_CONTEXT_TASK_URL`
- `AGENT_CONTEXT_PORT`
- `AGENT_CONTEXT_URL`
- `AGENT_CONTEXT_TITLE`
- `AGENT_CONTEXT_BADGE`

The hook updates the terminal title automatically. Shell prompt customization
can include `$AGENT_CONTEXT_BADGE` wherever the operator wants the badge to
appear.

## Ports

Worktree servers must use a non-primary port from the app's reserved range. See [`ports-and-processes.md`](ports-and-processes.md).

## Worktree Stack Requirements

Worktree tooling should make parallel stacks "just work" without user terminal chores.

Each worktree stack needs its own:

- App-range port (`3101`, `3102`, etc. for Turf Monster).
- Redis DB for Sidekiq and cache. The launcher allocates globally across generated stack env files from an elastic band starting at DB `9` (see [Scale Note](#scale-note)).
- Development database via `DATABASE_URL`.
- Isolated **test** database (`<app>_test_<slug>`), provisioned by `bin/agent-worktree new` and pinned via `TEST_DATABASE_URL` in `.env.test.local` (see [Running tests](#running-tests)).
- Session cookie key.
- `APP_PORT` so magic links point at the stack.
- `LOCAL_EMAIL_CAPTURE=1` so mail is recorded locally instead of sent.
- Ruby PATH guard when the repo requires a non-system Ruby.

Do not let two Sidekiq processes share one Redis DB while pointing at different databases. A job enqueued by one stack can be processed by the other stack and silently mutate the wrong records.

Worktree magic links are local-first through `/_studio/local_emails`. The central launcher writes `LOCAL_EMAIL_CAPTURE=1`, blanks provider mail credentials in `.env.agent-stack`, and prints the inbox URL next to the app URL. Agents should request the magic link in the UI, then open:

```text
http://localhost:<port>/_studio/local_emails
```

The inbox shows recent outbox rows and proof links such as magic-link sign-in URLs. Worktree stacks should not email real recipients unless the task is specifically testing real delivery. For provider tests, intentionally set `LOCAL_EMAIL_CAPTURE=0` and restore the needed mail credentials in that stack env.

Callback-heavy flows such as Stripe, Google OAuth, CDP/MoonPay, webhooks, and emailed magic links stay on the primary port unless the provider and local listener are configured for the worktree port.

## Running tests

`bin/agent-worktree new` provisions an isolated test database (`<app>_test_<slug>`) and writes `.env.test.local` with `TEST_DATABASE_URL` pointing at it. `config/database.yml`'s `test.url` reads `TEST_DATABASE_URL`, and an explicit `url:` wins over `DATABASE_URL` — so a plain `bin/rails test` resolves to the isolated test DB **out of the box**:

```bash
bin/rails test           # auto-resolves to <app>_test_<slug>; no manual prep
bin/agent-worktree test mcritchie-studio <slug>   # same, single-process + hermetic env
```

Do **not** `source .env.agent-stack` before running tests. You do not need the dev `DATABASE_URL` to test (the test DB resolves on its own), and sourcing it sets `AGENT_WORKTREE=1`/`LOCAL_EMAIL_CAPTURE=1`, which routes mail into the local capture store and diverges email-delivery tests from CI. Source `.env.agent-stack` only for dev-DB chores like `bin/rails runner` seeding. `bin/agent-worktree test` sidesteps this with a hermetic env (correct Ruby PATH, `RAILS_ENV=test`, single-process to avoid the parallel worker-DB clone deadlock on a cold test DB).

## Scale Note

Redis capacity has two layers:

- **Physical capacity** is the Redis `databases` setting. It is fixed at Redis
  startup; changing it needs a restart. Stock Redis exposes `0-15` (16 DBs).
- **Soft band** is the slot range the launcher allocates from, starting at DB
  `9`. It is elastic and restart-free within the physical ceiling.

The band idles at **20 slots** (`FLOOR`) and changes by **10** (`STEP`):

- **Scale-out (auto):** when the band is full and physical room remains,
  `allocate_redis_db` grows the band by 10 (`scaled out: 20 -> 30 slots`) and
  retries. No restart. At the physical ceiling it aborts with guidance to run
  `cleanup` or `scale --provision`.
- **Scale-in (auto):** `remove`, `cleanup --write`, and `cleanup --reclaim --yes`
  drop the band by 10 (never below the floor, never stranding a still-used DB) as
  slots free up (`scaled in: 30 -> 20 slots`). No restart. `cleanup --reclaim
  --yes` is the hands-off scale-down-on-close path: it releases every safe
  candidate, then calls `maybe_scale_in` once for the batch.

The band size is persisted in `/Users/alex/projects/.agents/redis-capacity.json`
and band allocation + capacity mutation are guarded by a `flock` on
`/Users/alex/projects/.agents/agent-worktree.lock` so concurrent `new`/`up`
runs cannot collide.

Inspect the band with `bin/agent-worktree scale status`. To realize the full
20-slot floor you need physical `databases >= 29` (DB 9 band start + 20). The
band caps band hand-outs at the physical ceiling, so on stock Redis (16 DBs)
only DBs `9-15` are usable until you provision.

To raise physical capacity (one-time, target `databases 64`):

```bash
bin/agent-worktree scale --provision         # interactive confirm
bin/agent-worktree scale --provision --yes   # skip the prompt
```

This edits the brew `redis.conf` (`$(brew --prefix)/etc/redis.conf`, overridable
with `AGENT_REDIS_CONF`) and restarts Redis **exactly once**. It is idempotent
(no-op when `databases` is already at/above target). The restart **bounces every
running worktree stack** on `localhost:6379`, so it belongs to the QA/infra lane
during a quiet window, never mid-session while other stacks are live.

Overrides: `AGENT_REDIS_FLOOR`, `AGENT_REDIS_STEP`,
`AGENT_REDIS_PHYSICAL_TARGET`, and the legacy `AGENT_REDIS_MAX_DB` (pins the band
top explicitly). Do not set band overrides past what Redis actually serves.

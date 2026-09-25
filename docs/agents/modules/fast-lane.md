# Fast lane — the builder's entry rules in full

The entry map ([`../index.md`](../index.md), installed as `AGENTS.md`) carries the
fast lane in one table. This page is the long form: where each command runs, how
the author set is stamped, how `bin/ship` waits, and the long-form fallback. The
step-by-step build flow is [`building-sop.md`](building-sop.md); board mechanics
are [`devops-task-board.md`](devops-task-board.md). The rationale and measurements
this page no longer carries are frozen verbatim in
[`../archive/fast-lane-2026-09-25.md`](../archive/fast-lane-2026-09-25.md).

## DevOps Routing — read before writing ANY code

If your work will produce a code diff — a feature, a bug, or a chore, **even a
"small" one** — you are a Feature agent and you follow the cycle. There is **no
size exemption**.

### The fast lane — the DEFAULT path

Two wrappers collapse the cycle's bookends into one command each. Reach for
them first; the long form below is the fallback.

```bash
/Users/alex/projects/mcritchie-studio/bin/task begin --title "Three To Five Words" --agent <soul> \
  --repo <app> --kind <kind> \
  --shape <shape> --risk <tag> --accept "criterion" --test "[unit] ..."

cd <desk>   #   ... the worktree begin printed; build there ...

/Users/alex/projects/mcritchie-studio/bin/ship <task-slug> -m "Commit message"
```

**Name the hub's script; stand in the desk.** Every fast-lane command —
`bin/task`, `bin/ship`, `bin/ship-wait`, `bin/fast-check`, `bin/dor-check` —
lives ONLY in `/Users/alex/projects/mcritchie-studio/bin`. A **satellite** desk
(the table below names all five) carries none of them, so the bare `bin/ship`
dies there as `nohup: bin/ship: No such file or directory`. Only a **hub** desk
has them.

**The path picks the SCRIPT, the cwd picks the TREE it acts on.** Both halves are
load-bearing, and the two writers disagree about what a wrong cwd costs you:

- **The pre-flight REFUSES.** `bin/fast-check` roots at the cwd's git toplevel
  and takes `TaskTree#refusal` (`bin/lib/task_tree.rb`), so from the hub against a
  satellite task it exits 1: *"this run roots at
  /Users/alex/projects/mcritchie-studio (branch main), which is not <slug>'s tree —
  refusing to run against it."*
- **`bin/ship` RE-ROOTS — loudly, not silently.** When the task's desk is on disk
  it prints `re-rooting at the task worktree <desk> (you ran from <cwd>)` and
  carries on THERE. It dies only when no desk resolves — absent from disk, or a
  multi-repo tie. Every gate it then runs re-verifies the root from its own cwd.

| Desk | Fast lane from that desk |
|------|--------------------------|
| `mcritchie-studio` | Hub-absolute **or** bare `bin/…` — a hub desk checks the scripts out, so both resolve |
| `turf-monster` · `rolio` · `mcritchie-industries` · `tax-studio` · `chain-ops` | **Hub-absolute only.** The desk has no fast-lane scripts; only the cwd is the desk's |
| `studio-engine` · `solana-studio` · `turf-vault` | **No `begin`, no `ship`.** `bin/task begin` answers `unknown app` — create with `bin/task create`, make the desk with a plain `git worktree add` at `<repo>/.worktrees/<slug>`, stamp it with hub-absolute `bin/agent-worktree identity <repo> <slug> <soul>` (a hand-cut desk gets no stamp and no `UNSTAMPED` warning), and run the handoff steps by hand. All three still get the pre-flight; see below |

Row 2 is the REGISTRY, not the machine: it names every satellite in
`config/satellites.yml`, including `tax-studio`, which has no checkout yet.

**Row 3 is a missing WORKTREE lane — NOT a missing test lane.** From a plain
`git worktree add` desk, hub-absolute `bin/fast-check <task>` runs the repo's
DECLARED gate (`ReleaseRegistry.release_check_cmd`) as the whole mapped lane.
All three repos declare `bin/release-check` in `config/release_repos.yml`: a
script each repo owns. If a repo ever hits `COULD NOT RUN` here, the remedy is a
`release_check:` on its registry row, not a task to go and ask. Never record a
"no tests" skip for turf-vault: it has a suite and a lane.

**Re-derive turf-vault's figures; never re-copy them.** Its lane runs two Node
lanes, then `cargo check`, `cargo clippy` and `cargo test`, and a cold tree pays
over a minute. `bin/release-check --list` prints the lane table, and
`npm run test:scripts` and `cargo test --workspace --locked` print their own
totals. Without `node_modules`, three `node:test` cases self-skip as
`ok <n> … # SKIP`, which is pass-shaped: install the deps before you quote a
count. Read the script from `origin/accepted`, never the local primary:
`git -C /Users/alex/projects/turf-vault fetch origin && git show
origin/accepted:bin/release-check`.

### The author set

**Pass `--agent <soul>` — it is what makes review able to exclude you.** It stamps
the task's AUTHOR SET (`devops.built_by` + `devops.builders`) — what
`bin/reviewer-select` reads to keep a soul off its own PR. Omit it and the
selector fails CLOSED: it refuses to pick, and the reviewer chooses by hand.
**If a second soul finishes the task, claim it again** (`bin/task move <task>
building --actor <soul>`): the set accumulates, so both authors are excluded.

**THE BUILD CLAIM STAMPS THE AUTHOR SET — a create alone does not.** `--agent`
writes two independent facts, and only one of them is what review reads:

- **AUTHOR SET** (`devops.built_by` + `devops.builders`) — stamped by the build
  CLAIM (`move <task> building`), which `begin` makes on BOTH forms. This is
  what `bin/reviewer-select` excludes on. The claim is only the TRIGGER; the
  soul it records comes from a PRECEDENCE CHAIN (`Task#builder_to_stamp`) —
  **`--actor <soul>`** first, else `devops.persona`, else **the task's assigned
  `agent_slug`**, the no-flag default that keeps a bare `bin/task move <task>
  building` attributed. An existing `built_by` is KEPT, so only an explicit
  `--actor` re-points a recorded builder.
- **ASSIGNEE** (the `agent_slug` column) — written by a create body, or by
  `bin/task update <slug> --agent <soul>`. **A resume does not write it**: the
  resume branch builds no `top_body`, so `--agent` reaches the claim as
  `--actor` and never lands on the column. The same resume PATCH does write
  `dev_size` (`bin/task#resume_claim`, the PATCH body it builds).

No single write sets both:

```text
bin/task create --agent avi           → assignee avi     · authors NOT STAMPED
bin/task begin <slug> --agent avi     → assignee unset   · authors ["avi"]
bin/task begin --title … --agent avi  → assignee avi     · authors ["avi"]
```

Every row above reaches the author set through `--actor` — both `begin` forms
forward `--agent` to the claim — so none of them exercises the `agent_slug`
fallback. The path that does:

```text
bin/task create --agent avi, then a BARE
  bin/task move <slug> building       → assignee avi     · authors ["avi"]
```

So `assignee: unassigned builders: avi` is a correctly attributed task, while a
blank assignee on a task NOBODY claimed by name is a real gap, because
`agent_slug` is the last source the chain has. `bin/task show <slug>` prints the
two lines separately for exactly this reason.

**It works on BOTH forms of `begin`, and the value must be a soul SLUG** —
lowercase with single hyphens (`steffon`, `turf-monster`). `--agent Steffon` or
`--agent turf_monster` is REFUSED. The resume form
(`bin/task begin <slug> --agent <soul>`) forwards the builder to the claim as
`--actor`. A RESUME HONOURS SIX FLAGS — `--slug`, `--repo`, `--agent`,
`--dev-size`, `--steal`, and `--title` itself — and refuses every OTHER create
flag with the `bin/task update` remedy rather than dropping it. The first five
are `BEGIN_RESUME_FLAGS`; `--title` is legal only when you re-run the create line
on a task that already exists, because it is how that re-run NAMES the task. So
re-running the create line resumes cleanly, and only the OTHER create flags on it
(say `--shape`) are refused.

### What the wrappers run

`bin/task begin` runs steps 1-3 (create → `agent-worktree new` → `bind-task` →
`move building` → `session-preflight`) and prints the worktree path, port, and
task URL. `bin/ship` — the HUB's script, run with that worktree as the cwd —
runs steps 5-6 (commit → optional `bin/fast-check` pre-flight → push →
**non-draft** PR into `accepted` led by the task URL → record `pr_url` → **wait
for CI to settle** → `bin/dor-check` → `move submitted` → read-back verify).
Re-running either after a failure **resumes** — each skips the steps already
durably recorded. Resume `begin` **by slug** (`bin/task begin <task-slug>`).
Mechanics: `docs/agents/modules/devops-task-board.md`.

**`bin/ship` waits for CI before the verdict** (`gate-submit-on-green-ci`). CI
runs the full suite in ~9 min on the PR, so `submitted` carries a settled GREEN
CI, and a red CI is caught while the desk is still warm. The wait decides
nothing — `bin/dor-check` runs next and owns the verdict — and it is bounded at
both ends: a run that never appears or never finishes reaches the verdict as a
WAIT. `SHIP_CI_WAIT=off` disarms it.

**Budget ~12 minutes for a cold `bin/ship`.** That exceeds what some agent
harnesses allow one foreground command, so **run it in the background — and wait
for it with `bin/ship-wait`**:

```bash
cd <desk>   #   ... the worktree begin printed; ship-wait roots the ship at the cwd ...
/Users/alex/projects/mcritchie-studio/bin/ship-wait <task-slug> --launch -m "Commit message"
/Users/alex/projects/mcritchie-studio/bin/ship-wait <task-slug>   # attach to one already running
```

It exits **0 succeeded · 1 failed · 2 still running at the timeout**, returns
IMMEDIATELY when the ship has already finished, and takes its verdict from the
ship's LOG — `bin/ship` can exit 0 on a run that never reached the seam, so
"the process is gone" is never an outcome. **Do not hand-roll a `pgrep`
watcher.** A pattern naming the ship also matches every sibling watcher shell
that names it, so the condition is true forever and the wait can never fire.
If a wait is cut short, re-run it; if the SHIP is cut short, re-run `bin/ship`
(it resumes and finishes in seconds once CI has settled). A killed ship leaves
the task in `building` with its PR already open, which the review sweep does not
pop.

**Watch it on the board.** While ship waits, the task's card in `building` shows
the PR's CI meter — `PR: <n>`, one mark per check, and a clock that freezes to the
run's duration when checks settle. Before a PR exists, the card shows the current
local lane; if its heartbeat stops, the board flips that lane to `STALLED`.

**What the wrappers do NOT do — read before trusting them:**

- They change **no gate semantics**. Every gate still runs and owns its verdict.
- `bin/ship` **stops at `submitted`**. It never merges, never deploys, never
  touches `release`/`main`.
- `bin/ship` has **no `--steal`**. The desk is the build claim: ship refuses only
  when another live session's desk is bound to the task with uncommitted changes,
  and names that desk. Claim over it with `bin/task begin <task-slug> --steal`,
  then ship. Your own desk never refuses you.
- **You still write the tests** (step 4). Neither wrapper invents test tiers.
- `bin/ship` is **not** `bin/release ship`. `bin/release ship` is the **G4
  production deploy** (`release → main`, ship-authority only).
- `begin` passes `--root <worktree>` to `bin/session-preflight`, so its verdict
  describes the worktree it just created, not the primary checkout.

Use the long form for multi-repo tasks, a bespoke PR body, a task someone else
shaped, or any single step you need to rerun piecemeal.

### The long form (fallback)

Before editing a single file:

1. **Create the production task** (`bin/task create`, or the board UI at
   https://mcritchie.studio) with `kind` and `shape`. The `shape` selects the
   tests you must write (`config/feature_shapes.yml`): `ui-only`
   (copy/styling) · `ui+db` (UI that persists) · `backend` (job/service, no UI)
   · `library` (studio-engine / solana-studio) · `onchain` (turf-vault /
   `Solana::*`) · `onchain-vertical` (wallet+DB+UI+program) · `docs`
   (prose only) · `test-only` (the diff is 100% `test/`, `tests/`, `e2e/`).
   The last two carry **no tiers**. `test-only` is claimable **only** on a diff
   dor-check OBSERVES to be all test code, it still owes the **CI gate**, and it
   owes a `[control]` line naming a file in the diff: *does the changed test
   still bite?* The CI gate it owes is the ORDINARY one: the PR's settled green
   GitHub CI is the one verdict, and `bin/fast-check` is the optional pre-flight
   before it, never evidence the gate reads. Read "owes the CI gate" as "is not
   exempt", never as "must run the full suite locally".
2. **Allocate an isolated worktree** (`bin/agent-worktree new <app> <task>`) on
   an allocated port. Do not edit on a primary checkout.
3. **Run `/Users/alex/projects/mcritchie-studio/bin/session-preflight <task> --root <desk>`**
   before editing. Bare, it inspects the checkout it lives in (`DEFAULT_ROOT`),
   never your desk. Fix the branch drift, blocker feedback, generated-doc drift,
   stale terminology, or PR overlap it reports first.

While building:

4. Write the **test tiers your shape requires as you go**, unit-first. Record them
   tier-tagged: `bin/task update <task> --checks "[unit] ..." --checks
   "[integration] ..."`. For a **bug**, write the failing regression test FIRST,
   at the lowest tier that reproduces it.

Before handoff:

5. Pre-flight — the task's **G1** step, optional
   (`mcritchie-studio/docs/agents/modules/gates/g1-cert.md`): commit, then run
   `bin/fast-check <task>` (diff-mapped tests + core spine + rubocop on changed
   files, ~1 min). It records nothing; the PR's settled green CI is the verdict.
   From a satellite desk name it `/Users/alex/projects/mcritchie-studio/bin/…`,
   still standing in the desk.
6. Push, open a PR **into `accepted`** (base `accepted`, not `release`/`main`)
   whose body **leads with the task URL**, then run **`bin/dor-check <task>`** and
   fix whatever it flags — it refuses an under-tested PR and its verdict closes
   the gate. Then `bin/task move <task> submitted`: a pending CI is a WAIT (re-run
   once it settles), a red CI blocks, and review's gate-zero holds the
   authoritative CI verdict — a CI that flips red mid-review is bounced back with
   the failing checks named.

### A good session prompt

For a new feature session, Mr. McRitchie should only need to say the target app
and the feature. A good prompt is:

```text
Work from /Users/alex/projects. Build this feature in <app>: <feature>.
Use the fast lane: /Users/alex/projects/mcritchie-studio/bin/task begin --title "Three To Five Words" --repo <app> --agent <soul>
--kind feature --shape (ui-only|ui+db|backend|library|onchain|onchain-vertical|docs|test-only)
--risk <tag> --accept "<criterion>" --test "<tier>". It creates the task,
allocates the isolated worktree on an allocated port, claims the task, and
preflights (pinning the worktree via --root). Read the preflight output and fix
any blockers before implementation.
Write the test tiers your shape requires as you go (unit-first); record them
tier-tagged in devops["checks_run"]. Before PR handoff, mark local validation
with `/Users/alex/projects/mcritchie-studio/bin/task update <task> --local-url http://localhost:<port>/<path>
--approval waiting`, return `Local Demo: http://localhost:<port>/<path>` in
chat. The request rides through the handoff and keeps pulsing in review, so hand
off rather than stalling on an answer. Update docs if behavior changes. Then hand
off, WITH THE DESK AS CWD, using the hub's copy of the script —
/Users/alex/projects/mcritchie-studio/bin/ship <task> -m "<commit message>" (a
satellite desk carries no copy of it; only the cwd is the desk's) — it
commits, runs the optional pre-flight, pushes, opens the non-draft PR into
accepted led by the task URL, waits for the PR's CI to settle, runs dor-check,
and moves the task to submitted (review's gate-zero still holds the
authoritative CI verdict). Fall back to
the long-form commands if the task spans repos or needs a bespoke PR body.
Do not merge or deploy unless I explicitly assigned that lane.
```

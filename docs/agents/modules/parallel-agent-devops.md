# Parallel Agent DevOps

This is the operating model for many agents working at once without losing
code. It separates backup, review, integration, and release into different
lanes.

## Core Idea

`main` is not the backup location. A pushed feature branch is the backup
location.

Feature agents should feel free to move quickly inside isolated worktrees, but
they do not merge to `main`. Work graduates through a PR review lane where Avi
protects integration, Steffon adds QA/deploy scrutiny when needed, and the
release conductor handles production effects.

## Two-Workflow DevOps Cycle

1. **Build: `designed → building → submitted`** — Feature agent owns this
   workflow. The task has
   acceptance criteria, affected repos, risk tags, expected `test_plan`,
   worktree slug, branch, PR URL, local URL when relevant, and completed
   `checks_run`. The task moves to `submitted`.
2. **Review: `submitted → reviewed`** — Avi reviews task metadata, PR body, diff, docs,
   migrations, merge safety, CI, local proof, and overlap with other agents.
   **Review `devops.post_deploy_cmd`, not just the diff** — it runs verbatim
   against prod on ship, so a bare `db:seed` (loads all of `db/seeds.rb` →
   demo data + a non-idempotent abort) must be rejected for a narrow, idempotent
   command; `bin/dor-check` enforces this, but read the metadata yourself.
   Avi classifies check failures by lane before deciding whether to merge,
   wait, or send `qa_feedback`.
3. **Assemble + QA: `reviewed → assembled`** — After merging approved PRs into
   the persistent `release` branch, Avi deploys `origin/release` to the QA app
   and records QA URL, deployed SHA, release slug, and QA checks in
   `checks_run`.
4. **Ship: `assembled → shipped`** — Release conductor promotes only accepted
   QA work after explicit approval. Production smoke results, production URL,
   and release notes are recorded before the task moves to `shipped`.

## Lanes

| Lane | Owner | Purpose | May push branch | May merge → `release` | May deploy/publish |
|------|-------|---------|-----------------|-----------------------|--------------------|
| Feature | Task agent | Build scoped work in an isolated worktree | Yes, own branch only | No | No |
| QA / Integration | Avi | Review PRs, prevent dropped code, merge approved work | Yes, review/fix branches when needed | Yes | No, unless explicitly acting as release conductor |
| Quality / Infra Gate | Steffon | Validate risky PRs, CI, deploy readiness, provider infra | Yes, review/fix branches when needed | No, unless delegated by Avi | No, unless release conductor |
| Release | Designated conductor | Gem publish, app deploy, production verification | Yes | Yes | Yes, with explicit approval |

Approved work merges into the **persistent per-repo `release` branch**, not
`main`. Only the Release lane advances `release → main` — a fast-forward at ship
(`bin/release ship`). The "Never push to `main`" rule still stands.

One session can wear multiple hats only when Mr. McRitchie explicitly says so.
Default feature sessions are Feature lane only.

## Feature Branch Lifecycle

1. **Start** from `/Users/alex/projects`.
2. **Read** root `AGENTS.md`, then the relevant app docs.
3. **Create or update** the production McRitchie Studio task-board item with a
   human-readable `devops.worktree_slug`, affected repos, acceptance criteria,
   risk tags, and expected checks. A feature agent should accumulate acceptance
   criteria with Mr. McRitchie until the goal is aligned before implementation.
   Use
   [`devops-task-board.md`](devops-task-board.md) for the required metadata
   contract. This task is mandatory for feature, bug, QA, release, cleanup, and
   active-doc work that may produce a branch, PR, QA deploy, production deploy,
   or cleanup follow-up. Set the task to `building` once implementation
   starts.
4. **Allocate** a task worktree from McRitchie Studio:

   ```bash
   cd /Users/alex/projects/mcritchie-studio
   bin/agent-worktree plan <app> <task-slug>
   bin/agent-worktree new <app> <task-slug>
   bin/agent-worktree bind-task <app> <task-slug> <task-record-slug-or-url>
   ```

5. **Build** only inside `/Users/alex/projects/<repo>/.worktrees/<task-slug>`.
6. **Run** meaningful checks and start the stack when visual/local proof matters:

   ```bash
   bin/agent-worktree up <app> <task-slug>
   ```

7. **Update** the task-board item with local URL, branch, PR URL when opened,
   `checks_run`, and any acceptance-criteria changes.
8. **Commit** coherent work on the feature branch.
9. **Graduate** through the launcher:

   ```bash
   bin/agent-worktree finish <app> <task-slug>
   bin/agent-worktree finish <app> <task-slug> --push
   bin/agent-worktree finish <app> <task-slug> --push --pr
   ```

   `--push --pr` is only valid after `bind-task` has stored the production
   McRitchie Studio task slug/URL on the worktree. The command blocks unbound
   worktrees so PR review always leads back to the task board.

10. **Handoff** the PR/QA packet by moving the task to `submitted`. The PR
   body and final handoff should lead with the task URL, and the task should
   link back to the PR. Add a task conversation `handoff` note summarizing what
   changed, what was verified, and what Avi should inspect first. Do not merge
   to `main` unless assigned the QA or Release lane.

## Feature Graduation Rules

Before a branch is ready for QA, it must be:

- in a generated worktree, not the primary checkout
- represented by a McRitchie Studio task with acceptance criteria, affected
  repos, risk tags, human-readable worktree slug, branch or PR URL, local URL
  when applicable, expected `test_plan`, and completed `checks_run`
- on a feature branch, not `main`
- committed cleanly
- ahead of `origin/main`
- rebased when `origin/main` has moved
- pushed to GitHub before the worktree is considered safe to clean up
- accompanied by a local proof URL or a clear explanation of why no URL applies

`bin/agent-worktree finish` enforces the obvious checks and prints the PR body.
It blocks dirty worktrees, branches with no commits, branches already merged to
`origin/main`, and branches behind `origin/main`. When called with
`--push --pr`, it also blocks worktrees that are not bound to a production
McRitchie Studio task record.

## QA / Avi Review

Avi owns PR **intake** as a thin delegation gate — product-acceptance + reviewer
selection. The **PRIMARY reviewer** then owns the rest of the lane: the deep
review, spawning the **LIGHT** as its own sub-agent, and the **merge** into
`release` (`bin/release merge`).

### Picking the two senior reviewers (`bin/reviewer-select`)

Avi runs `bin/reviewer-select <task>` to choose the **1 PRIMARY + 1 LIGHT** pair by
domain fit with a logged, seeded-per-task tiebreak. Three exclusions keep review
honest, and **none of them needs a manual flag in the common case**:

- **QA owner** (Steffon by default) — never reviews a PR he then QAs. Override
  with `--qa-owner SLUG` when someone else QAs this task.
- **Builder** — a soul never reviews their own work. The builder is read from
  `devops.built_by`, which is **auto-stamped on the move to building**: a bare
  `bin/task move <slug> building` records the task's assigned `agent_slug` (an
  explicit `--actor <soul>` move wins over it). So the builder drops out with **no
  `--builder` flag** — pass `--builder SLUG` only to override the recorded value.
- **Busy souls** — agents mid-build or mid-review on OTHER in-flight tasks
  shouldn't be handed a review. Name them with **`--busy a,b,c`** (repeatable),
  and/or add **`--busy-auto`** to also exclude every agent on a `stage=building`
  task (a board query; skipped in `--file` mode and degrades to a no-op if the
  board read fails).

**Keep-rather-than-starve:** the pool is never shrunk below a PRIMARY+LIGHT pair.
If the builder + QA-owner + busy exclusions would leave too few candidates, the
least-bad ones (best domain fit) are KEPT eligible and the decision/log flags
them — a pair is always returned. Because `--busy` / a custom `--qa-owner` shift
the candidate pool, the printed pair may differ from the app's default-seed
preview, but `bin/reviewer-select <task>` **records by default** — it writes the
chosen (busy-aware) pair as the live review intent so the board + timeline show
the actual reviewers. Pass `--no-record` (or `--dry`) for an advisory-only run
that writes nothing.

During the review itself, both reviewer agents should broadcast progress with
`POST /api/v1/tasks/:slug/review_events`. The API role `primary` displays as the
heavy swimlane and records these moments: `started`, `context`, `diff`, `tests`,
`risk`, `findings`, `completed` (or `failed`). The light swimlane records
`started`, `context`, `diff`, `smoke`, `handoff`, `completed` (or `failed`). Use
an `idempotency_key` per moment so agent retries are safe. Completed/failed agent
check-ins include model, tokens, and cost; earlier status check-ins can be
spine-only. The task timeline's Review Events link opens
`/tasks/:slug/review_events`; the deployments board's Submitted `docs` link opens
`/review_events`, a process hub with heavy/light swimlanes, top recent role
owners, and recent submitted/reviewed/assembled/shipped task drilldowns.


### Step 0 — assess the queue by stage

Open every Build-and-Deploy cycle by enumerating the board **by stage** — not
with the default flat `bin/task list`:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task list --stage reviewed    # merge queue — approved, awaiting bin/release merge
bin/task list --stage assembled   # members of the current release candidate (RC)
bin/task list --stage shipped     # baseline / reconciliation (recent ships)
bin/task list --stage submitted   # review intake — the Build → Deploy seam
bin/task list --stage building    # in-flight builds — who is working what
```

The first three are the **Deploy landscape** (merge queue + current RC +
baseline); the last two cover the **Build half** (review intake + in-flight).
Run them all so nothing actionable is invisible at the start of the cycle, then
generate the queue below.

**Why per-stage, and never the flat list:** `bin/task list` with no `--stage`
returns only the **20 most-recently-CREATED tasks across ALL stages** — the API
paginates at `per_page=20` (`Api::Paginatable`), ordered `created_at DESC`
(`Task.recent`), and `bin/task list` **discards the response's `meta` block**, so
it prints `(20 task(s))` with **no "showing 20 of N" truncation warning**. A
truncated list looks complete. An older actionable task — especially in a quieter
app that hasn't moved lately — silently falls off the bottom. This is not
hypothetical: a 2026-06-25 conductor assessed the board with the flat list and
**missed the only `reviewed` task** (an older one in a quieter app) AND a
stranded `assembled` zombie; both surfaced instantly under `--stage`. Filtering
to a small actionable stage (`reviewed` / `assembled` / `submitted` / `building`
each normally hold a handful) keeps the result under the 20-row cap, so you see
the whole stage. (`shipped` is itself unbounded, so `--stage shipped` is still a
recent-20 window — exactly what you want for a baseline/reconciliation glance.)

#### `bin/conductor` — the deterministic Step-0 driver

`bin/conductor` codifies this whole per-stage assessment as a script ("more
rails, less model judgment"), so a conductor session can't skip Step 0 or miss
an actionable task. It is a THIN orchestrator — it shells out to `bin/task list
--stage`, `bin/task show --json`, `bin/reviewer-select`, and `bin/release`; it
never re-implements the board API.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/conductor                 # survey (default, READ-ONLY): the Deploy queue BY
                              # stage, the active RC + its members, brief prod health
bin/conductor plan            # survey + the next deterministic action per stage
bin/conductor plan --reviewers   # also preview the picked primary+light pair
bin/conductor merge [--run]   # thin drive: bin/release merge <reviewed pipeline slugs>
bin/conductor qa    [--run]   # thin drive: bin/release prepare (deploy origin/release to QA)
```

`plan` maps each stage to its deterministic next command: `submitted` →
`bin/reviewer-select <slug>` (then spawn the **nested cascade** — Avi (thin gate)
→ the **PRIMARY** reviewer, which spawns the **LIGHT**; the **review needs
AGENTS**, so conductor surfaces the assignment, it never fabricates a verdict);
`reviewed` → `bin/release merge <slugs>` (the conductor's **backlog** path — a
freshly-reviewed task's primary already ran its own merge); `assembled` →
`bin/release prepare` then the ship gate. It flags `blocked` + non-pipeline
tasks separately. **`bin/conductor` never ships implicitly** — plain
`bin/conductor ship` prints the handoff command; the explicit autonomous path is
`bin/conductor ship --run`, which runs `bin/release ship --by conductor --yes`
after the same release gates. It defaults to the PROD board (like `bin/release`).

`bin/conductor` **complements `bin/qa-intake`**: conductor answers "what is in
each Deploy stage and what is the next deterministic command"; `qa-intake`
answers "what is the local PR/worktree + CI/mergeability state of a given PR".
Run `bin/conductor` for the stage-by-stage landscape, `bin/qa-intake` when you
need a PR's merge signal. `bin/devops-cycle` below is the scout-oriented queue
snapshot.

Start conductor sessions by generating the PR/worktree queue from McRitchie
Studio:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/devops-cycle
bin/devops-cycle --plan
bin/devops-cycle --decisions
bin/devops-cycle --scout-packets
bin/devops-cycle --write-scout-packets tmp/devops-scouts
bin/devops-cycle --scout-runs tmp/devops-scouts --max-scouts 3
bin/devops-cycle --scout-coverage tmp/devops-scouts
bin/devops-cycle --scout-reports
bin/devops-cycle --readiness
bin/avi-heartbeat --run
bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio
```

`bin/devops-cycle` is the high-level conductor snapshot. It reads the production
task board, groups active `submitted`, `reviewed`, and `assembled` tasks,
joins each task to latest task conversation notes, and attaches matching
`bin/qa-intake` status when a local PR/worktree exists. Use it first in a fresh
DevOps session so task IDs, PR URLs, QA URLs, and next actions are visible
before reviewing individual diffs. It is read-only by default.

Use `bin/avi-heartbeat --run` when Mr. McRitchie wants Avi to review submitted
PRs unattended for hours without assembling a release. It is the review-only
heartbeat: newest `submitted` task first, one PR at a time, fresh
`bin/devops-cycle --json --decisions --scout-reports` query before selection and
again after reviewer completion, selected PRIMARY + LIGHT reviewers launched via
`codex exec`, then Avi moves two-approval work to `reviewed` and leaves it for
Steffon/release assembly. It stops after ten completed PR reviews by default and
prints a retrospective of friction, blockers, common blocker patterns, and
refactor candidates. It does not merge, deploy, ship, publish gems, or archive.

Use `bin/devops-cycle --plan` when the queue is larger than one conductor can
comfortably hold in context. The plan separates:

- parallel PR review tasks that can be assigned to separate scout sessions
- serialized or conductor-owned tasks that touch multiple repos or high-risk
  surfaces
- blocked tasks that should return to the feature agent before review
- reviewed tasks ready for release merge
- assembled release work awaiting follow-up or explicit release approval

The plan is still read-only. It does not merge, deploy, update tasks, or create
sub-agents. The conductor uses it to decide which work can safely happen in
parallel and which tasks must be bundled or sequenced.

### Re-fetch the queue before every act — the board moves under you

The board is continuously fed: feature agents push new `submitted` PRs while you
work, and other conductor sessions merge/ship in parallel. A queue snapshot goes
stale fast — a real session shipped a **one-PR release against a snapshot that
was already three PRs behind**, and later shipped against a release whose frozen
QA SHA lagged the train because tasks merged after the last `prepare`. So treat
the queue as live state, not a fixture:

- **Re-run `bin/task list --stage submitted` (or `bin/qa-intake --refresh`)
  immediately before every `bin/release merge`, every `prepare`, and every
  `ship`.** Never act on a queue older than your own last write — re-confirm what
  is actually `submitted` / `assembled` right now at each seam.
- **Before `ship`, confirm the frozen QA SHA matches the train** — if any task
  merged into `release` since the last `prepare`, the release is back to
  `assembling`; re-run `prepare` so `qa_shas` == `origin/release` HEAD before you
  ship (else you deploy stale code while running newer post-deploy hooks).
- **Don't trust GitHub `mergeable` right after you change the base.** Merging a PR
  into `release` flips every other open PR to `mergeable=UNKNOWN` while GitHub
  recomputes asynchronously. Use `git merge-tree --write-tree origin/release
  origin/<branch>` as the reliable local conflict check instead of polling `gh`.

Use `bin/devops-cycle --decisions` after scout reports begin landing. The
decision summary aggregates `qa-intake` status, latest task conversation state,
and structured scout report outcomes into conservative Avi recommendations:

- `merge-ready`: clean qa-intake and at least one merge-ready scout report.
- `wait-for-ci`: qa-intake or a scout says checks are not settled.
- `request-changes`: qa-intake has a blocker, a scout requested changes, or the
  latest task activity is `qa_feedback`.
- `conductor-review`: multi-repo, high-risk, missing local intake, or otherwise
  requires Avi to inspect personally.

The decision summary is a queue accelerator, not an authority transfer. Avi
still reviews the underlying PR, decides whether the report is sufficient, and
performs any merge, QA deploy, or feedback action.

Use `bin/devops-cycle --scout-packets` when the conductor wants to hand
review-only work to additional sessions. Scout packets are copy-paste prompts
for the `parallel_review` and `serialized_review` lanes. They include the
task URL, PR URL, repos, branch, risk tags, acceptance criteria, expected checks,
completed checks, latest task note, qa-intake status, and explicit guardrails.

Use `bin/devops-cycle --write-scout-packets tmp/devops-scouts` when the queue
is large enough that inline prompts are awkward. The launcher writes one
`*.prompt` file per scout packet plus `manifest.json` with packet ids, task
URLs, PR URLs, review modes, reasons, and prompt file paths. It is a local
filesystem write only. It does not spawn agents, merge, deploy, write task
feedback, publish gems, or change branches. Use the manifest to hand prompt
files to separate scout sessions, then collect their structured reports with
`--scout-reports` and summarize them with `--decisions`.

Use `bin/devops-cycle --scout-runs tmp/devops-scouts --max-scouts 3` to manage
the local scout run queue. The command reads `manifest.json` and local
`scout-runs.json`, prints pending/launched/completed/blocked counts, and shows
which prompt files fit inside the current concurrency limit. It does not launch
agents. Avi or the operator starts scout sessions manually, then records local
state:

```bash
bin/devops-cycle --scout-runs tmp/devops-scouts \
  --mark-scout-status scout-task-XXXX:launched \
  --scout-agent casey

bin/devops-cycle --scout-runs tmp/devops-scouts \
  --mark-scout-status scout-task-XXXX:completed \
  --scout-agent casey
```

Use `bin/devops-cycle --scout-coverage tmp/devops-scouts` after scout reports
start landing. It compares manifest packets with structured task comments and
flags packets with no report, missing task records, or conflicting scout
outcomes. This is the Phase 3C harvesting check: the conductor should not treat
the scout lane as complete until coverage is explicit.

Use `bin/devops-cycle --readiness` for the final Phase 3D conductor view. It
groups work into ready-to-merge, needs-conductor-review, needs-changes, waiting,
Ready To Assemble, Assembled Release, and scout-gap lanes. Readiness is still
advisory: Avi owns the final merge, deploy, QA feedback, and production gate.

Scout sessions do **not** merge, deploy, publish gems, change providers, rotate
credentials, force-push, or take over the feature branch. Their job is to return
a concise findings report and one recommendation to Avi: merge-ready,
wait-for-CI, request-changes, or conductor-review. Avi keeps the final
integration and deployment decision.

After reviewing, the scout records the report on the task as a structured task
comment:

```bash
bin/devops-cycle --record-scout-report task-XXXX \
  --outcome merge-ready \
  --summary "No blockers found." \
  --finding "Diff matches the task acceptance criteria." \
  --check "Reviewed PR body, changed files, and CI." \
  --dry-run
```

Use `--dry-run` first, then remove it when the payload is correct. Valid
outcomes are `merge-ready`, `wait-for-ci`, `request-changes`, and
`conductor-review`. Scout reports are evidence for Avi. Scouts should not move
task stages or convert findings into final `qa_feedback`; Avi does that after
reviewing the report and PR context.

Use `bin/devops-cycle --scout-reports` when you need the detailed reports under
the main queue. `--json --decisions` and `--json --scout-reports` expose the
same report metadata for future supervisors or dashboards.

`bin/qa-intake` is the lower-level PR/worktree intake. It refreshes
`/Users/alex/projects/.agents/worktree-registry.json`, joins the local worktree
state with open GitHub PRs, and prints an Avi-ready queue. Add apps to
`--apps` as new satellites are promoted. Use `--json` when a supervisor script
or dashboard should consume the same queue. Every printed queue item includes an
`action:` line. Treat that action as the next owner handoff unless new evidence
from the diff, tests, or Mr. McRitchie changes the call.

Under the persistent-`release` model the merge target is `release`, so a PR's
freshness should be reckoned against `origin/release` (the branch it merges into),
not `main`. **Transitional:** `bin/qa-intake` still compares against `origin/main`
and the `ready-to-open-pr` / freshness labels below still read "current with
`origin/main`"; that comparison base flips to `release` in the same follow-up PR
that flips `bin/agent-worktree`'s `--base` default. Until then, confirm a PR
targets `release` before merging — `bin/release merge` enforces it.

Status labels mean:

- `avi-ready`: clean local branch with a matching PR, no blocking local issues,
  and no merge/check warnings.
- `avi-ready-draft`: clean local branch and clean merge state, but the PR is
  still draft.
- `checks-review`: local branch is present, but GitHub reports unstable checks;
  inspect CI before merge.
- `merge-risk`: GitHub reports conflict, blocked, dirty, or unknown merge
  state.
- `needs-agent`: the local branch has blocking worktree issues such as a dirty
  tree, stale branch, broken `/up`, missing stack env, or Redis slot problem.
- `missing-local-branch`: GitHub has an open PR, but the current machine has no
  matching local worktree.
- `ready-to-open-pr`: local branch has no matching open PR and is clean,
  current with `origin/main`, and ready for `bin/agent-worktree finish`.

Action lines mean:

- `Avi can review...`: review diff, evidence, overlap, then merge or comment.
- `return to the feature agent...`: do not merge; the branch owner needs to
  resolve local blockers.
- `rebase or repair...`: merge state is unsafe; fix branch freshness/conflicts
  before QA.
- `inspect checks...`: wait for CI/checks or make an explicit conductor
  decision.
- `recreate a local worktree...`: the machine cannot inspect the branch safely;
  fetch/recreate it or ask the branch owner for a handoff. If another active
  agent owns the PR, do not take it over unless Mr. McRitchie assigns that lane.
- `open a draft PR...`: run the printed finish command from the worktree owner
  lane, then let Avi review.

For each PR, Avi checks:

- the task-board acceptance criteria are concrete and still match the request
- the task has affected repos, branch/PR URL, local/QA URLs where relevant, risk
  tags, expected `test_plan`, and completed `checks_run` recorded in
  `metadata["devops"]`
- the PR body matches the diff
- the branch started from current enough `main`
- the local proof URL or test evidence is credible
- the work does not silently overwrite another agent's changes
- docs changed when behavior, env, ports, auth, email, deploys, or workflow changed
- the branch should merge now, wait for another PR, or be sent back

If `bin/qa-intake` finds a PR/worktree with no matching task-board item, Avi
does not treat the intake queue as sufficient handoff. Either ask the feature
agent to create/update the task, or create the missing task only when Avi is
explicitly taking ownership of the handoff. The PR may still be reviewed for
urgent fixes, but the missing task metadata should be called out before merge.

If a PR needs changes, Avi records the blocker as task conversation
`qa_feedback` so the original feature agent has a durable next-action list. Add
a GitHub PR comment too when the feedback is code-specific, CI-specific, or
needs to live in the PR timeline.

Avi should avoid rewriting feature branches unless taking explicit ownership of
the fix. If Avi does modify a PR, the PR comment must say what changed and why.

Long-running CI is not automatically a code failure. If GitHub checks are still
progressing, especially browser install or Playwright shard startup, watch the
run until it completes or exposes logs/artifacts. Do not push speculative
changes solely because one shard is slow while other checks are green.

## Steffon QA Gate

Steffon gates PRs with operational risk:

- migrations or data backfills
- payment, email, auth, Solana, wallet, SSO, or provider changes
- deploy/buildpack/env-var changes
- production incident fixes
- UI flows where browser proof is the core acceptance criterion

Low-risk docs or copy PRs can merge with Avi review alone. When in doubt, Avi
asks Steffon for QA before merge.

## Release Conductor

Publishing gems, updating app lockfiles after a gem release, deploying apps, and
changing provider configuration are Release-lane actions.

Rules:

- Only one conductor owns a release slug at a time.
- The conductor pulls latest `main` in every affected repo before release work.
- Engine changes use their own release slug: source commit, version bump,
  release check, gem publish, consumer lockfile updates, app verification.
- Deploys require explicit approval from Mr. McRitchie unless the prompt already
  included production rollout.
- The conductor reports production URLs and verification results before cleanup.

`bin/release` mechanics the conductor relies on (born from real session friction):

- **Batched merge.** `bin/release merge <slug> [<slug> …]` takes one OR many
  slugs: it `gh pr merge`s each, then adopts them ALL in a **single `heroku run`**
  (one dyno spin-up, N `reviewed → assembled` flips) instead of a cold-start
  `heroku run` per PR — which used to blow the 2-min timeout and, on a mid-loop
  timeout, leave a PR *merged* but its task stuck `reviewed`. The adopt runs in an
  `ensure`, so a partial-failure batch still records every PR that merged.
  Single-slug behavior is unchanged.
- **Overlap planner (warning only).** With ≥2 slugs, `merge` fetches each PR's
  changed files and prints the pairwise file collisions, a suggested merge order
  (smallest-footprint first), and which PRs will likely need a post-merge rebase.
  It never blocks — use it to choose merge order and pre-empt the "siblings all
  touched `task.rb`" conflict that otherwise surfaces on `release` after review.
- **Ship preflight.** `bin/release ship` asserts every **app checkout is on a
  clean `main`** before any fast-forward and aborts loudly (naming the offending
  branch / dirty files) if not — a review agent that left a checkout on a `pr-NNN`
  branch or with a stale `schema.rb` would otherwise break the ff mid-ship. Keep
  primary checkouts on a clean `main` before running `ship`.

## QA Deployment

QA deployment sits between PR merge and production deploy.

The intended cycle is:

1. Feature agent opens a PR.
2. Feature agent moves the task to `submitted`.
3. The review lane runs: Avi thin-delegates → the **PRIMARY** reviewer does the
   deep review, spawns the LIGHT, and on two approvals runs **`bin/release merge`**
   for its task to land it in `release` (the conductor batch-merges any pre-existing
   `reviewed` backlog). `bin/release merge <task> [<task> …]` does the `gh pr merge`
   + membership flip — it takes **one OR many** slugs, merges each, then adopts them
   all in a **single `heroku run`**; with ≥2 slugs it first prints an **overlap
   planner**: colliding files + suggested order + likely rebases, warning-only.
4. Avi or Steffon provisions the QA app once if `bin/qa-server status <app>`
   reports `missing-app`.
5. Avi or Steffon deploys the `release` ref to the app's QA server with
   `bin/qa-server deploy <app> origin/release --yes` (or `bin/release prepare`,
   which runs this for every app member).
6. Avi or Steffon moves the task to `assembled` and records the QA URL,
   deployed SHA, release-slug tag when present, and QA checks run.
7. Mr. McRitchie reviews the QA URL.
8. Production deploy happens only after Mr. McRitchie explicitly approves it.
9. Verified production work moves to `shipped`.

QA servers are tracked in `config/qa_environments.yml` and operated through
`bin/qa-server`. A QA deploy is allowed for the QA conductor lane, but it must
target the QA Heroku app, never the production app. Turf Monster QA must stay on
devnet with `PAYMENT_PROVIDER=none`. The intended stable review URLs are
`https://qa.mcritchie.studio` and `https://qa.turfmonster.media`; use
`bin/qa-server status <app>` to confirm the Heroku app, DNS target, and `/up`
checks before asking Mr. McRitchie to review.

## Recurring QA Intake Prompt

Use this prompt when Mr. McRitchie wants a session to run the PR review, merge,
and QA deployment cycle:

```text
Work from /Users/alex/projects as the QA / Integration lane.

Run the parallel-agent DevOps cycle:
- read /Users/alex/projects/AGENTS.md and the app docs
- pull latest main in mcritchie-studio and each affected app
- run `bin/qa-intake --refresh --apps mcritchie-studio,turf-monster,rolio` from
  McRitchie Studio, adding any other app mentioned in the current work
- use the QA intake queue to identify avi-ready, checks-review, merge-risk,
  needs-agent, missing-local-branch, ready-to-open-pr, and cleanup candidates;
  follow each item's `action:` line for the next owner handoff
- review each PR for diff/description match, CI or local proof, docs impact, migrations, auth/email/payment/Solana risk, and overlap with other open PRs
- ask Steffon/infra review for risky changes before merge when needed
- merge only PRs that are ready, into the persistent `release` branch (base
  `release`); leave task `qa_feedback` and PR comments on PRs that need changes
- after merging, deploy origin/release to the relevant QA app with bin/qa-server deploy <app> origin/release --yes
- move merged tasks to assembled and update task-board metadata with QA URL, release slug, deployed SHA, and checks_run
- run bin/qa-server status <app> and report the QA URL, /up status, release SHA, task list, and what Mr. McRitchie should review

Do not deploy production, publish gems, delete worktrees, delete branches, or force-push unless Mr. McRitchie explicitly authorizes that lane in this session.
```

This cycle ends at QA. Mr. McRitchie reviews the QA URL and then gives a
separate production instruction if the release should go live.

## Recurring Production Release Prompt

Use this only after QA has passed and Mr. McRitchie asks for production rollout:

```text
Work from /Users/alex/projects as the Release lane.

Promote the accepted QA work to production:
- read /Users/alex/projects/AGENTS.md and the deployment docs
- pull latest main in mcritchie-studio and each affected app
- confirm the QA deployment SHA and production target app
- confirm the task-board release slug when present and accepted tasks included in the rollout
- run the app-specific deployment command from the repo docs
- verify production /up and the user-facing URL
- update tasks with production URL/release SHA/check results
- send Release Notes through `POST /api/v1/release_notes`
- report production URL, release SHA/version, tasks deployed, checks run, Release Notes result, and any follow-up cleanup

Do not include unrelated PRs or new feature work in this rollout.
```

## Code Loss Prevention

- A pushed feature branch preserves work. Merging to `main` is an integration
  decision, not a backup step.
- Never delete a feature branch or worktree until the PR is merged or explicitly
  abandoned.
- Start conductor sessions with `bin/agent-worktree snapshot --write` so the
  current machine queue is captured before branches, pidfiles, or ports move.
- `cleanup` only records candidates in the delete-later ledger; removal remains
  approval-gated.
- After a squash merge, ahead/behind can look stale even when the branch diff is
  fully represented on `origin/main`. The launcher marks empty-diff branches as
  cleanup candidates; after approval use
  `bin/agent-worktree remove <app> <task-slug> --yes` so stack stop, ledger
  update, worktree removal, local-branch deletion, and registry refresh happen
  together.
- After manual cleanup, still run `bin/agent-worktree snapshot <app> --write`
  and then `bin/qa-intake --refresh --apps ...` so stale registry entries do not
  linger in the conductor queue.
- Feature agents do not force-push shared branches. If a rebase needs a push,
  use `--force-with-lease` only on your own branch.
- If another agent moved `origin/main`, rebase and rerun checks before PR.
- If another agent changed the same files, let Git surface the conflict. Do not
  manually recreate or overwrite their work from memory.

## 100-Agent Scaling Notes

The current slot allocator uses app port ranges and `.env.agent-stack` files as
the local session registry. `bin/agent-worktree snapshot --write` turns that
state into `/Users/alex/projects/.agents/worktree-registry.json`, a local
machine-readable queue for QA, release, dashboards, and future supervisor
agents. That is enough for dozens of occasional worktrees.

Known future ceilings and controls:

- Redis capacity is two-layer: physical `databases` (fixed at Redis startup)
  and an elastic soft band the launcher allocates from, starting at DB `9`. The
  band idles at 20 slots, auto-grows by 10 (restart-free) when full while
  physical room remains, and auto-shrinks by 10 (never below 20) as worktrees
  close. It never hands out a DB beyond the physical ceiling. Check it with
  `bin/agent-worktree scale status`; lifecycle detail is in
  [`worktrees.md`](worktrees.md#scale-note).
- Raising physical capacity is the one Redis-restart action:
  `bin/agent-worktree scale --provision` edits the brew `redis.conf` and
  restarts Redis once (target `databases 64`). It bounces every running stack on
  `localhost:6379`, so it is a QA/infra-lane action during a quiet window, never
  mid-session. The band's normal grow/shrink needs no restart.
- Browser-heavy flows on 100 ports will be CPU-bound before Git becomes the
  problem.
- Shared dependency release slugs, especially `studio-engine`, need a single
  conductor and should not be merged casually by feature agents.
- Stable QA servers should absorb release-candidate review so `main` can be
  ahead of production without forcing production deploys.
- Callback-heavy provider flows should stay on primary ports unless each
  provider is configured for worktree callback URLs.

When the current local JSON registry becomes too small, promote it from a
generated snapshot into a lockable service or database-backed coordinator. Do
not skip directly to that complexity until the file-based queue is proving too
small in real use.

## Recurring Feature Prompt

Use this prompt for ordinary future feature sessions:

```text
Work from /Users/alex/projects. Build this feature in <app>: <feature>.

Use the parallel-agent protocol:
- create or enter an isolated worktree with bin/agent-worktree
- use the allocated port and give me the local URL
- record expected checks in task devops.test_plan
- keep all edits inside the task worktree
- update docs if behavior, workflow, env, ports, auth, email, or deploys change
- commit your work on the feature branch
- run bin/agent-worktree finish before handoff
- push the branch and open/prepare a PR for Avi QA
- update task devops.checks_run with completed checks and move the task to submitted

Do not merge to main, publish gems, deploy, force-push, delete branches, or
delete worktrees unless I explicitly approve that lane for this session.
```

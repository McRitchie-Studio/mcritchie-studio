# DevOps Cycle — Design (v2)

> **Status:** approved model, landing incrementally. The **two-workflow task
> status model is now live** — `Task` stages are
> `designed → building → submitted` (Build) and
> `submitted → reviewed → assembled → shipped → archived` (Deploy — the
> `shipped → archived` archive loop closes it, §1.4) — meeting at the
> `submitted` seam — plus `blocked` (side) and `archived` (terminal).
> `bin/task`, `bin/dor-check`, and the board speak it.
>
> **Landed since:** the `Release` singleton model; the persistent-`release`
> branch CLI — `bin/release init|merge|prepare|ship` (§1.1); and
> `bin/agent-worktree`'s release-aware base default — `new` cuts the feature
> branch from `origin/release` (falling back to `origin/main` where no `release`
> branch exists) and `finish --pr` opens the PR with `--base release`.
>
> **Still to land (each its own task):** migrating the heartbeat planner
> `bin/devops-cycle` from the old stage names to the new ones (it is
> self-consistent on the legacy snapshot today); **multi-repo `ship`** — the
> per-repo app deploy across satellites (+ gem auto-repin + partial-ship +
> `test_cmd` gate); `bin/release ship` today publishes gems then deploys
> mcritchie-studio only; the Discord progress webhook
> (§5). Where this doc describes those, it is the spec for the follow-up.
>
> **Deploy-flow redesign (decided, 2026-06-22).** The `submitted → shipped` half
> was re-homed by role — review is **delegated by Avi to two seniors** (no longer
> his solo gate), `assembled` is owned by **Steffon** (now titled **Platform
> Engineer**), and `shipped` is owned by **Avi** (full e2e on the frozen ship
> SHA) plus explicit ship authority: the default operator gate or the
> `Merge, Assemble, Deploy` autonomous kickoff. **§1.2 is the rewritten spec.**
> It lands via three build tasks: `deploy-flow-heartbeat-tooling` (planner/tooling + the
> `prepare` retry/wait-for-boot fix), `stages-page-step-outlines` (the per-step
> `/stages` outlines), and `seed-souls-prod-qa` (the reviewer souls, incl. a new
> **Alex Documentation** reviewer persona distinct from the orchestrator seat).
>
> Operator companion: the board stage guide at
> [`/stages`](https://mcritchie.studio/stages), and the rendered **SOP
> infographic** — the cycle drawn as accountability swimlanes, one row per owner —
> at [`/stages/sop`](https://mcritchie.studio/stages/sop). Both render from
> `config/devops_vocabulary.yml` (read via `Devops::Vocabulary`), the **single
> source of truth** for the SOP vocabulary: rename a term there and it flows to the
> UI in one edit, so the page and these docs cannot drift. This document remains
> the canonical full SOP.

This design answers seven goals:

1. Note the current infrastructure (done — see "What already exists").
2. A testing strategy on the unit→component→integration→E2E→manual pyramid,
   with a clear answer to *who writes which tier, when, and when we prune*.
3. An airgapped heartbeat DevOps agent (review→QA, **gate prod**).
4. Scale + resilience to 100 parallel feature agents.
5. Standardized, high-visibility Discord progress / blockers / release notes.
6. Self-loading agentic context (feature→X, bug→Y) so you never re-explain.
7. A clear deterministic-vs-judgment map + a model-per-step budget.

---

## What already exists (do not rebuild)

| Capability | Where | Reuse as |
|---|---|---|
| Task state machine — Build `designed→building→submitted→reviewed`, Deploy `reviewed→assembled→shipped`, plus `blocked`/`archived` | `Task` model, `devops-task-board.md` | The spine. Everything routes through the task. |
| `kind` (feature/bug/chore/qa/release/cleanup), `metadata["devops"]` contract | `devops-task-board.md` | SOP routing key + handoff record. |
| Activity log: `comment` / `qa_feedback` / `handoff` + scout reports | `Activity`, task-board API | The durable QA↔feature-agent channel. |
| Sealed-bid sizing, `backend_migration` advisory-lock lane, `release_slug` lane | `sizing-rubric.md`, `exclusive-lanes.md` | Order-of-operations machinery. |
| Test lanes (pr_review_gate / local_proof / qa_acceptance / production_smoke / nightly_deep / quarantine) + `config/devops_test_suites.yml` + `bin/devops-tests` | `testing.md` | The *when/where* axis of the pyramid. |
| `bin/qa-intake`, `bin/devops-cycle` (scout packets/decisions/readiness), `bin/agent-worktree`, `bin/qa-server`, `bin/deploy` | `parallel-agent-devops.md` | The conductor toolchain the heartbeat agent drives. |
| Discord `POST /api/v1/release_notes` (dry-run, grouped-by-app, standardized) | release notes service | The standardized visibility primitive. |
| "Future Heartbeats" lease-model spec | `devops-task-board.md` | The literal blueprint for the airgapped agent. |

The job is **formalize + close gaps**, not greenfield.

---

## 1. The cycle, end to end

The flow is **two workflows**, matching how the work actually splits and *who
owns each*. **Building** a change (the feature agent) and **shipping** a release
(DevOps) are different jobs at different cadences, so they are different
lifecycles that meet at one seam — `submitted`.

- **Workflow 1 — Build (per task · feature agent):** `designed → building →
  submitted`. A task is specced (`designed`), an agent claims and builds it
  (`building`), and opens a PR (`submitted`) — where the feature agent's part
  ends. A wall, bounced PR, or unready dependency parks it at **`blocked`**.
- **Workflow 2 — Deploy (per release · DevOps):** `submitted → reviewed →
  assembled → shipped`. Review is a **nested chain**: **Avi thin-delegates** the
  submitted PR — he confirms **product-acceptance** and picks the **primary +
  light** pair (`bin/reviewer-select`) — then hands the lane to the **PRIMARY
  reviewer**, who owns it end-to-end. The PRIMARY does the deep review (acceptance,
  base tests, standards, smell, scalability) and **spawns the LIGHT** reviewer as
  its own sub-agent; on **two approvals** with no blocker the **PRIMARY** drives
  the task to **`reviewed`** AND **merges its PR into the persistent `release`
  branch** (`bin/release merge`) — which flips that task to `assembled`
  (membership at merge) — assembling a single **release candidate (RC)**. A
  blocker lands it at **`blocked`** (rework, with a `qa_feedback` note).
  **Steffon** (Platform Engineer) QAs the RC with the next tier (integration +
  an e2e smoke) and deploys `origin/release` to QA; at ship **Avi** runs the
  full e2e on the frozen ship SHA and, with explicit ship authority, the
  conductor fast-forwards `release → main` (`shipped`). `submitted` is the seam
  — the feature agent hands the PR to DevOps there.

QA and production are properties of the **release**, not the individual task —
so there is no per-task QA stage; ship authority is a single decision on the RC
after the frozen-SHA gate.

```
WORKFLOW 1 · Build (feature agent)         WORKFLOW 2 · Deploy (DevOps · Release model)
designed → building → submitted ─────────► submitted → reviewed → assembled → shipped → archived
               ▲         │                  (review)   (approved) (merged RC,  ("run the    (archive
               └ blocked ┘                                         e2e green,   deployment" loop,
                 (rework / env / dep)                              QA-deployed)  → prod)    §1.4)
```

`blocked` is the single "not in the pipeline's court" state — an agent hit a
wall, QA bounced the PR, or a dependency isn't ready. It records `blocked_from`
(captured automatically) + `block_kind` (environment / rework / dependency) so a
heartbeat agent routes it without re-reading the thread. `archived` is terminal.

The RC is a **`Release` singleton** (only one assembles at a time). Member tasks
carry its `release_slug`; it carries them through QA→prod and flips them to
`shipped` when it ships. The airgapped agent runs both workflows and crosses the
ship gate only when the session carries explicit production authority (`Merge,
Assemble, Deploy`, direct ship approval, or an already-approved rollout prompt).
The task API is on production, so the airgapped box only needs an internet
connection — no separate pull/sync layer.

**Open every cycle by assessing the board BY STAGE** — `bin/task list --stage
reviewed|assembled|shipped|submitted|building`, never the default flat `bin/task
list` (it caps at the 20 newest tasks across all stages with no truncation
warning, so older actionable work silently falls off). See
[`parallel-agent-devops.md` → Step 0](../modules/parallel-agent-devops.md#step-0--assess-the-queue-by-stage).

### 1.1 The Release model + the persistent `release` branch

**Release** (singleton model) coordinates one candidate from assembly through
ship. *Consolidation (decided):* the legacy `release_train` field has become
**`release_slug`** — one concept, one name.

**The integration branch is PERSISTENT.** Every repo keeps a single `release`
branch — the *same* name in every repo (`Release::BRANCH = "release"`). Feature
PRs target `release`, not `main`; `main` is always an ancestor of `release`.
`bin/release init` creates the branch (= `main`) on every gem + app repo, once
(idempotent). Membership flips `reviewed → assembled` **at merge**: merging an
approved PR into `release` (`bin/release merge <task>`) records the task onto the
active candidate. `prepare` deploys `origin/release` to QA; `ship`
fast-forwards each repo's `release → main` and deploys prod. After a ship,
`release` collapses to `main` and re-accumulates the next candidate.

| Field | Meaning |
|---|---|
| `slug` | Canonical id, e.g. `2026-06-20-s3-uploads`. |
| `state` | `assembling` → `assembled` → `shipped` (+ `abandoned`). `assembled` = the QA candidate is built (members merged into `release`) **and** its suite checks out. |
| `branch` | The persistent integration branch `release` (same name in every repo); feature PRs merge into it, QA deploys from it, and `ship` fast-forwards it into `main`. |
| `confirmed_at` / `confirmed_by` | The ship authorization at `assembled → shipped` — operator approval for the QA workflow, or the autonomous production kickoff. |
| `qa_url` / `production_url` / `deployed_sha` / `release_notes_sent_at` | Deploy + notes record. |
| has_many `tasks` | via `tasks.release_slug`. |

**Task** gains two links:

| Field | Meaning |
|---|---|
| `release_slug` | The Release this task rides (null until merge; the task becomes `assembled` once its PR is merged into `release`). |
| `dependencies` | Array of task slugs this one needs shipped first. **Now enforced** by the conductor (`Release::Ordering`) — a member sorts after every task listed here — composed under the producer-first rule (e.g. an engine gem before the apps that consume it). |

`dependencies` (task→task) and the exclusive **lanes** (resource-level:
migration, release, vault single-writer) compose: dependencies say *"B needs A's
output"*; lanes say *"only one of these at a time."* As of the gems-first
release work, `dependencies` is no longer spec-only: `Release#ordered_members`
honors it (a stable topological sort that falls back to `position`), so the
conductor sequences members producer-first **and** respects explicit
task-to-task edges. See "Gem members & producer-first ordering" below.

**Membership flips at merge; QA is a deploy of `origin/release`.** Feature PRs
already target `release`, so there is no branch-cut and no PR-base retarget. For
each `reviewed` member its PR is merged into `release` — the **primary reviewer**
runs `bin/release merge <task>` for the task it owns (the conductor batch-merges
any pre-existing `reviewed` backlog with `bin/release merge <task> [<task> …]`),
which `gh pr merge`s + `Release::Conductor.adopt!`s, records the task onto the
active candidate, and flips it `reviewed →
assembled`. **`merge` is batched** — it takes one OR many slugs, `gh pr merge`s
each, then adopts them all in **one `heroku run`** (the cold-start-per-PR adopt
otherwise blew the tool timeout and left half-states); with ≥2 slugs it also
prints an **overlap planner** (colliding files + suggested order + likely
rebases, warning-only). A merge conflict surfaces **at this PR-merge step**
(resolve on GitHub, or block the task for rework) — `release` never force-pushes. Once the desired members are
merged and **Steffon's integration + e2e-smoke suite** is green on
`origin/release`, `bin/release prepare` deploys `origin/release` to **QA** +
records the QA URL → the release is **`assembled`** (the QA candidate). A late PR
merging in after that **reopens** the RC (`Release#reopen!`) so it re-QAs before
shipping. At ship, **Avi** first runs the **full e2e + highest-tier suite on the
frozen ship SHA** (the exact prod code — closing the merge-forward "shipped ≠
tested" gap); on green the ending depends on the trigger. `Build and Deploy QA
Release` stops for the operator, while `Merge, Assemble, Deploy` continues with
the already-authorized ship. The ship action (surfaced as the current release on
`/deployments`, not a passive status): `bin/release ship` fast-forwards each
repo's `main` up to `release` (so `release` collapses into `main`), deploys prod,
and flips members to `shipped`. Ship authority always lands **after Avi's test
confirmation, before the deploy**.

Release progress is also recorded as explicit `ReleaseEvent` checkpoints
(`review_tests`, `assemble_release`, `deploy_qa`, `qa_smoke`, `ship_gate`,
`ship_authorized`, `deploy_prod`, `prod_smoke`, `release_notes`,
`archive_tasks`). The `/deployments` tracker reads those events before falling
back to legacy `Release` fields, so `ship_gate:completed` can visibly finish the
Confirming step before `deploy_prod:started` begins production work.

**Gem members & producer-first ordering.** A release is not apps-only — it can
carry **gem** tasks (`studio-engine`, `solana-studio`) as first-class members
alongside apps. The classification lives in `config/release_repos.yml` (read by
`Release::Repos`): every member is a `:gem` (producer) or an `:app` (consumer).
Gems and apps are handled differently at both ends of the Deploy workflow:

- **Gem members are PUBLISHED, not app-deployed.** A gem's PR merges into the
  gem's own repo's `release` branch like any other, but there is no app artifact
  to deploy — so at **prepare** the conductor skips gem members in the QA-deploy
  loop. They ride the release as a *record*, and are QA'd indirectly through a
  consuming app (the consumer's branch is what gets deployed + tested).
- **Run Deployment processes producer-before-consumer.** `Release#ordered_members`
  returns members **gems-first** (then apps), honoring `dependencies` within
  that. `bin/release ship` publishes every gem member to RubyGems first
  (approval-gated `gem push`, version from the gem's `version_file`), and only
  then deploys the apps. So a consuming app always builds + deploys against the
  **just-published** gem version — never ahead of it. If a gem fails to publish,
  the ship aborts before any app deploys.
- **The version lives in the gem's PR.** The version bump (`lib/studio/version.rb`
  for studio-engine, the `.gemspec` for solana-studio) is part of the gem task's
  own PR; `member_plan` reads it for the publish + the board's `💎 gem` badge.
  Post-publish, consuming apps re-pin `~> x.y` and deploy as their own members
  (or follow-up tasks). See `docs/agents/modules/deployment.md` →
  "Releasing a gem (producer-first)" for the operator runbook.

This is the ordered `release_slug` from §4.2 ("gem publish → consumer lockfile
bump → app deploy"), now expressed as first-class release membership rather than
a separate lane: the gem and its consumers can be members of the same release,
sequenced by kind + `dependencies`.

**Abandon (revert, never force-push).** `release` is permanent and shared, so a
stuck RC is **not** thrown away by deleting a branch — it is unwound by reverting.
`Release#abandon!` drops board membership (members fall back to `reviewed`,
release → `abandoned`, the singleton frees up). The git-side remediation is owned
by the conductor/CLI as a documented step:

1. For each member whose merge you want out, **revert its merge commit on
   `release`** (`git revert -m 1 <merge-sha>`, push) — never a force-push, since
   `release` is the shared persistent branch.
2. The member's task drops to `reviewed`; the e2e culprit goes to `blocked`.
3. Re-merge the surviving/fixed members into `release` (a new candidate
   accumulates) and re-`prepare`. `main` never moved.

### 1.2 Stage ownership — who progresses each stage

Distinguish the **accountable role** (the soul whose rubric governs the stage)
from the **executor** (who moves it). The heartbeat agent executes by wearing
each lane's hat; accountability maps to a soul; there is exactly **one operator
gate** — the ship.

**Redesigned `submitted → shipped` (decided, 2026-06-22; review lane re-homed
2026-06-26).** The Deploy half is re-homed by role. Review is a **nested chain,
not a flat peer spawn**: **Avi is a thin delegation pre-step** — he confirms
product-acceptance and picks the **primary + light** pair (`bin/reviewer-select`),
then hands the lane to the **PRIMARY reviewer**, who owns it end-to-end (the deep
technical review, **spawning the LIGHT** as its own sub-agent, and the **merge**).
**`assembled`** is owned by **Steffon** (now titled **Platform Engineer**); and
**`shipped`** is owned by **Avi** (who runs the full e2e on the frozen ship SHA)
ahead of explicit ship authority. The senior reviewer pool is **{Shannon = UI ·
Carl = backend · Jasper = Web3 · Steffon = DevOps/Platform · Alex = Documentation}**
(Alex is both the orchestrator and the pool's launchable Documentation review
seat — one identity). Avi picks the pair with **`bin/reviewer-select <task>`**
(wraps `ReviewerSelector`).

**Merge timing (decided):** a `reviewed` task is merged when its PR lands **into
the persistent `release`** (`bin/release merge`), which flips it `reviewed →
assembled`. The release branch is the live RC; `main` only moves when it ships.
The **PRIMARY reviewer runs the merge** — on **two approvals** (primary + light)
with no blocker it drives the task to `reviewed` and runs `bin/release merge`. The
conductor no longer runs the merge for a freshly-reviewed task (it still
batch-merges any pre-existing `reviewed` backlog). **Bias to action: green tests
= go**, because `release` is recoverable by revert, so we don't fear merging there.

| Stage (entity) | Accountable | Progressed by | Action | Gate |
|---|---|---|---|---|
| **→ submitted** (task, entry) | Feature agent | Feature agent | `bin/full-suite-check` (certify FULL suite + rubocop) → pass `bin/dor-check`, record `checks_run`, open PR (base `release`), move in | self-gate |
| **submitted** (task) — REVIEW | **PRIMARY** reviewer (Avi delegates) | Avi (thin gate) → **PRIMARY** owns lane → **LIGHT** | Avi confirms **product-acceptance**, then picks **2 reviewers** from {Shannon=UI · Carl=backend · Jasper=Web3 · Steffon=DevOps/Platform · Alex=Documentation} by **domain fit + a logged, seeded-per-task tiebreak** via **`bin/reviewer-select <task>`**, assigning **1 PRIMARY (deep) + 1 LIGHT** (`ReviewerSelector`, excluding the QA owner so a reviewer never QAs their own change, **the task's builder** so a soul never reviews their own work, **and busy souls** so review never lands on an agent mid-build/review elsewhere — the builder is read from `devops.built_by`, **auto-stamped on the move to building from the soul build-claim actor (`--actor <soul>`) OR the task's assigned `agent_slug`** so a bare `bin/task move <slug> building` records the builder with **no manual flag**, falling back to the `→ building` event actor; **busy souls** come from `bin/reviewer-select --busy a,b,c` and/or `--busy-auto` (a board query of agents on `stage=building` tasks); **KEEP fallback:** when the builder + QA-owner + busy exclusions would leave fewer than two candidates, the least-bad ones are kept so a PRIMARY+LIGHT pair is always returned (the decision/log flags it), and a non-soul/non-pool builder is never reported excluded; the pair + primary/light is recorded on the `submitted→reviewed` `TaskEvent.metadata["reviewers"]` for the avatars UI). Avi then **hands the lane to the PRIMARY**, who runs the deep review and **spawns the LIGHT** as its own sub-agent; each confirms DoR **base** tests green, code standards, code smell, scalability, **and acceptance**. No blocker on either → the **PRIMARY** drives the task to `reviewed` ✅ AND runs the merge (next row); a blocker → `blocked` (rework, with `qa_feedback`) | **2 senior approvals** (PRIMARY = Opus on migration/payment/solana/auth); ⛔ one complete `qa_feedback` on fail |
| **reviewed** ✅ — MERGE (task) | the **PRIMARY** reviewer | the **PRIMARY** reviewer *executes* | On **2 approvals** (primary + light, neither blocking) the **PRIMARY** runs **`bin/release merge`** for its task — honoring `dependencies` + lanes; membership flips at merge → member `assembled`. The primary owns the merge; the conductor no longer runs it for a freshly-reviewed task (it still batch-merges any `reviewed` backlog). **Bias to action: green tests = go** (`release` reverts cleanly; we don't fear merging there) | deterministic merge (conflicts surface at PR-merge); **the primary owns it — no separate conductor/Avi gate** |
| **assembled** (release) — QA | **Steffon** (Platform Engineer) | DevOps agent *as Steffon* | Run the **next tier — integration + an e2e smoke** on `origin/release`; green → `bin/release prepare` deploys it to QA → **Discord QA-deployment note** → release `assembled` | deterministic suite; ⛔ regression → block the task. **`prepare` retries/waits-for-boot** (the `/up`-smoke race): `bin/release prepare` polls `<qa_url>/up` via `wait_for_boot` and **defers the assemble** (`Release::Conductor.curate!` then `assemble!`) until QA returns 200, so a slow dyno can't strand the RC `assembling` |
| **→ shipped** (release) | **Avi**, then ship authority | Avi tests; operator or autonomous kickoff authorizes; conductor deploys | Avi runs the **full e2e + highest-tier suite on the FROZEN ship SHA** (the exact prod code — fixes "shipped ≠ tested"). `Build and Deploy QA Release` stops here for the operator; `Merge, Assemble, Deploy` continues with `bin/conductor ship --run`. On ship authority: `bin/release ship` ff's `release → main` per repo, deploys → `production_smoke` → **Discord release notes** → members `shipped` | 🔒 explicit ship authority — after Avi's test confirmation, before deploy; rollback on smoke fail |

Clarifications:

- **Product-acceptance is a core check at BOTH ends.** The two senior reviewers
  confirm the task's acceptance criteria at the review step, and **Avi confirms
  acceptance again at ship** (on the frozen SHA). It is checked twice by design —
  once before merge, once before prod — not a one-time gate.
- **Test-tier → step map (efficiency — no redundant re-runs):** **base**
  (unit/component) @ **review** (the two seniors) · **integration + e2e-smoke** @
  **QA** (Steffon) · **full e2e + highest tier** @ **ship** (Avi, on the frozen
  ship SHA). Each tier runs once, at the step that owns it — no step re-runs a
  lower tier the previous step already proved green. Encoded as
  `Release::STEP_TEST_TIERS` (ownership is disjoint by construction — a tier maps
  to exactly one step); ship runs Avi's full-e2e gate on the frozen SHA **before**
  ship authorization (`bin/release ship` → `avi_ship_gate`, then `confirm`, unless
  the authorized autonomous workflow passes `--yes`).
- **`assembled` means slightly different things at the two scopes** — a *task* is
  `assembled` the moment its PR is merged into `release` (`bin/release merge`,
  driven by the **two seniors' approval**); the *release* is `assembled` once the
  desired members are in, **Steffon's integration + e2e-smoke** is green on
  `origin/release`, and `prepare` has deployed it to QA. Production authority is
  at **ship** (after Avi's full-suite run on the frozen SHA), **not here** — at
  this scope `assembled` is a state the conductor flips, not a human approval.
- **Review is a thin delegation, then a nested chain — not Avi's solo gate.** Avi
  opens review as a **thin delegator** — product-acceptance + reviewer selection —
  then **hands the lane to the PRIMARY**, who owns it end-to-end: the deep review,
  **spawning the LIGHT** reviewer as its own sub-agent, and the **merge** into
  `release` (`bin/release merge`) on two approvals. Avi does not do the deep
  technical review himself, and the conductor no longer runs the merge for a
  freshly-reviewed task.
  The selection tiebreak is **seeded per task** (reproducible, not
  process-random) and **logged** (auditable), so reviews spread across the pool
  instead of always landing on the obvious domain owner. Because the seed is
  derived from the task identity (+ its exclusions), **`bin/reviewer-select`'s
  preview matches the pair recorded on the `submitted→reviewed` `TaskEvent`** —
  the CLI and the in-app recorder roll identically and never disagree. (That
  match holds for the **default QA owner**; passing a custom `--qa-owner` changes
  the candidate pool + seed, so the preview is then advisory.)
- **No self-gating:** Avi must **not** pick **Steffon** as a reviewer on a PR
  Steffon will then QA at the `assembled` step — one soul cannot both review and
  QA the same change. (Steffon remains a valid reviewer for **other** PRs,
  especially DevOps/Platform ones.)
- **Alex is the Documentation reviewer.** The `alex` seat is the orchestrator who
  **also** holds the **Documentation** domain review seat — one identity (seeded in
  `db/seeds/02_agents.rb`, a launchable review agent). `ReviewerSelector` /
  `bin/reviewer-select` pick `alex` for docs-shaped PRs (the QA-owner and
  builder exclusions still apply, so Alex never reviews a change he built).
- **There is no per-task QA stage.** Steffon owns the QA deploy, the QA tier
  (integration + e2e-smoke), and the prod mechanics — but there is no separate
  approval ceremony; the suite is a green/red *signal* and the operator OK at
  ship is the gate. QA + production are properties of the **release**, not the
  task.
- **The PRIMARY merges even funds-touching work autonomously** into `release`
  on the two approvals (primary + light) — the consequence of "Review + QA, gate
  prod".
  Risk raises *scrutiny* (the PRIMARY review goes to Opus + full
  integration/security suite), not a second human. `config/release_builder.yml`
  gates only QA assembly autonomy; adding a separate human pre-merge gate for
  `payment`/`solana` would require a code/config change, not a doc-only knob.
- **Humility valve:** low confidence → a reviewer marks `conductor-review` and
  routes to a *human* Avi/Steffon session instead of approving the merge into
  `release`.

### 1.3 Decided — and where to tune the release builder

Resolved: `release_train` → **`release_slug`** (one field/model); **feature PRs
merge into a persistent per-repo `release` branch, membership flipping at merge**;
no per-task QA stage; Release is its own singleton model — states `assembling →
assembled → shipped`, where explicit ship authority **Makes the release** from
the assembled RC. **Decided 2026-06-22 (§1.2):** review is **delegated by Avi to
two seniors** (not his solo gate); `assembled` is owned by **Steffon** (titled
**Platform Engineer**); and at `shipped` **Avi** runs the full e2e + highest tier
on the **frozen ship SHA** *before* ship authority is exercised — so the deploy
gate sits **after test confirmation, before the deploy**.

**RC assembly autonomy is the one evolving policy** — so it lives in one
tunable config file, `config/release_builder.yml`, read by
`Release::BuilderPolicy`. Current policy:

- **Auto-assemble + auto-deploy-to-QA** only when the reviewed queue is one
  task, one repo, with no `migration`/`payment`/`solana` risk tag.
- **Propose for operator confirmation** for an empty queue, multi-task release,
  cross-repo release, or blocked-risk release. The conductor can draft the plan,
  but waits before changing release state.
- Production ship remains **operator-gated by default**
  (`production_ship.operator_gated` is `true`) for `Build and Deploy QA Release`.
  The separate **`Merge, Assemble, Deploy`** kickoff is the explicit autonomous
  production authorization; it uses the same frozen-SHA/test/smoke gates, then
  passes `--yes` to the production ship command.

Change thresholds in `config/release_builder.yml`, then run
`bin/rails test test/models/release/builder_policy_test.rb`. This policy only
decides QA assembly autonomy plus names the autonomous production kickoff;
ordinary `bin/release ship` remains separately gated unless that kickoff or
another explicit production rollout prompt grants ship authority.

### 1.4 Kickoff commands — board → agent session

The `/deployments` board and `/stages` page surface a short copy-paste command
per DevOps stage (source of truth: `ApplicationHelper#devops_kickoffs`). Pasted
into an agent session run from `/Users/alex/projects`, each kicks off that
stage's workflow. The feature-agent lane (`designed → building → blocked →
submitted`) has none — the operator drives those hands-on. The DevOps lane maps
each command to a deterministic runbook. The same `devops_kickoffs` source also
carries three non-stage meta-triggers rendered as prominent chips in the
current-release section (`#current-release`):

- **`Avi Heartbeat`** — the long-running review-only loop. It serializes
  submitted PR review newest-first, re-fetches after each PR, moves approved
  work to `reviewed`, then leaves it for Steffon/release assembly.
- **`Build and Deploy QA Release`** — the QA-department run. It reviews,
  assembles, deploys QA, runs ship-readiness, then stops before production.
- **`Merge, Assemble, Deploy`** — the autonomous production run. It shares the
  same review/assembly/QA phases, then runs production ship after the same gates
  pass.

**`Avi Heartbeat`**  *(long-running review-only loop — stops at reviewed)*

This is the unattended Avi intake loop for hours-long review duty while feature
agents keep submitting work. Run it from the primary McRitchie Studio checkout:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/avi-heartbeat --run
```

The heartbeat always re-queries the production board before selecting work,
chooses the newest `submitted` PR first, records `bin/reviewer-select` intent,
launches the selected PRIMARY + LIGHT reviewers with `codex exec`, waits for
both to finish, then re-queries before deciding. Two merge-ready reports move
the task to **`reviewed`** with an Avi handoff note; request-changes blocks the
task with `qa_feedback`; wait-for-CI or conductor-review is deferred and retried
after the defer window. The heartbeat does **not** merge into `release`, deploy
QA, ship production, publish gems, or archive tasks. After ten completed PR
reviews by default (`--limit 10`), it prints a retrospective covering friction,
blocked/deferred tasks, blocker commonalities, and future refactor candidates.

**`Build and Deploy QA Release`**  *(the operator's one-trigger QA-department run — stops at the ship gate)*

This is Mr. McRitchie's single trigger for the whole QA department: hand it to an
agent — **any model (Claude, Codex, …)** — and it walks the persistent-`release`
model through review, merge, QA deploy, and ship-readiness. It **does not ship to
production without Mr. McRitchie's confirmation**; after the frozen-SHA ship
tests pass, stop and hand the operator the `Run Deployment` gate.

> ⚠️ **THIS SOP STOPS BEFORE PROD.** A green review + green QA + green ship-tests
> produces an assembled RC and a clear `bin/release ship` handoff. Production
> deploy remains gated across every release repo
> (mcritchie-studio + satellites).

**`Merge, Assemble, Deploy`**  *(the autonomous production run — shares the QA SOP, then ships)*

This is the production-authorized sibling workflow. It uses the same conductor
runbook below through review, merge, QA deploy, straggler review, and refreshed
QA. The difference is the final production decision: after the ship preflight and
frozen-SHA `avi_ship_gate` pass, the agent runs
`bin/conductor ship --run` (equivalent to `bin/release ship --by conductor
--yes`). That `--yes` answers only the human confirmation prompt; it does **not**
skip clean-main preflight, frozen-SHA tests, producer-first gem publish, deploy
smoke, production `post_deploy_cmd`, or partial-ship recovery.

> ⚠️ **THIS SOP IS PRODUCTION AUTHORITY.** Do not infer it from "prepare QA",
> "review release", or `Build and Deploy QA Release`. The exact phrase
> **`Merge, Assemble, Deploy`** (or another explicit production rollout prompt in
> the session) is what grants the agent authority to cross the ship gate.

> **Cold-start framing — you are the CONDUCTOR (Deploy lane).** When the operator
> opens a fresh session with just `Build and Deploy QA Release` or
> `Merge, Assemble, Deploy`, follow **this** SOP — *not* the feature-agent
> "⛔ STOP before writing code" flow in `CLAUDE.md` (that is the **Build** lane).
> The conductor **orchestrates** the deploy run on work that is **already** built:
> it **delegates review** (Avi confirms product-acceptance + picks the pair; the
> **PRIMARY reviewer** does the deep review, spawns the LIGHT, and runs
> `bin/release merge` for its task), then **assembles** the QA candidate and
> **deploys** it. The conductor does **not** review or run the per-task merge
> itself, and it does not create a task, take a worktree, or write feature code.
> Run every command from `/Users/alex/projects/mcritchie-studio`.

> **A non-interactive agent MUST pass `--yes` only for approved confirms.** An
> agent's shell has no TTY — stdin is EOF, which a confirm prompt reads as
> **"no"**. The consequence differs per command:
> - **`prepare`** aborts without confirmation in a non-interactive shell. Always
>   run `bin/release prepare --yes` for the approved QA deploy step.
> - **`ship`** *aborts loudly* without confirmation — that is intentional. Do not
>   pass `--yes` unless the session trigger is **`Merge, Assemble, Deploy`**, Mr.
>   McRitchie explicitly gives the production ship go in this session, or an
>   already-approved rollout prompt grants ship authority.
> - **`archive`** can use `--yes` after the shipped release is verified and the
>   operator has approved cleanup.
> - **`merge`** does not prompt today; `--yes` is harmless future-proofing.
>
> `--yes` bypasses the **human confirm only** — it never skips a test gate
> (`avi_ship_gate` runs and can still abort the ship). `--prod` is already the
> default (the board is prod) — don't add it redundantly.

**The block-and-move rule (every review below).** A reviewer block is **not** a
stop: `bin/task block <slug> --kind rework --feedback "<one complete send-back>"`,
then move on — one block never holds back the PRs that passed (rework is a separate
feature-agent cycle). Surface every blocking event — a review send-back, a merge
conflict that forces a task back, or a ship-time test/preflight abort — as a little
**❌ Block Resolved** line (`❌ Block Resolved — <slug>: <reason>`; "resolved" =
recorded and routed back, not fixed). List them in the handoff **only if at least
one blocking event happened** — omit the section on a clean run.

1. **Survey + assess the candidate.** `bin/conductor plan` — enumerate the Deploy
   queue **by stage**, name the active release candidate + its `assembled` members
   (the "active pending release" you fold in), and flag `blocked` + non-pipeline
   tasks (repos absent from `config/release_repos.yml`; handle them in their own
   app, never `bin/release merge` them).
2. **Review round 1 — PARALLEL fan-out (≤5 concurrent).** Fetch the submitted
   queue (`bin/task list --stage submitted`) and review it in parallel: for each
   pipeline task run the **nested cascade** (the `Review submitted PRs` runbook
   below) — spawn **Avi** as the thin gate (product-acceptance + `bin/reviewer-select
   <task> --busy-auto`, which records the primary+light pair), then spawn the
   **PRIMARY** reviewer; the PRIMARY spawns the **LIGHT**. **Cap the fan-out at 5
   concurrent agents** (the board DB's connection budget — see "Concurrency cap" in
   the operating model): launch in **waves of ≤5**, not the whole queue at once,
   and don't review one PR start to finish before the next. Both pass with no
   blocker → the **PRIMARY** drives the task to `reviewed` AND runs **`bin/release
   merge <task>`** (it owns the merge → `assembled`); any block → block-and-move.
3. **Prepare the release.** The round-1 tasks are **already merged** — each
   PRIMARY ran `bin/release merge` as the last act of owning its lane, so they are
   already `assembled`. Batch-merge any **pre-existing `reviewed` backlog** the
   cascade didn't own into the active candidate (or open it). Run the
   pre-merge checklist per PR — `gh pr ready <n>` (un-draft), `gh pr edit <n> --base
   release` (retarget; no-op when `main` == `release`) — then **batched**
   `bin/release merge <slug> [<slug> …] --yes` (one dyno, N `reviewed → assembled`
   flips; the overlap warning is advisory). Deploy to QA: `bin/release prepare
   --yes` (records `release.qa_url`; a `/up 000` right after a Heroku release is
   usually a still-booting dyno — re-check `curl -s -o /dev/null -w "%{http_code}"
   <url>/up`). **Bias to throughput: default to including, not deferring.**
4. **Review round 2 — stragglers.** Reviewing + preparing takes time; new PRs may
   have landed in `submitted`. Re-fetch `bin/task list --stage submitted` and run
   the same cascade + block-and-move on anything new. Empty → say so, skip to step 6.
5. **Assemble again.** Pre-merge checklist + `bin/release merge <slug> … --yes` the
   round-2 `reviewed` tasks into the same candidate, then `bin/release prepare
   --yes` to refresh QA. Confirm the refreshed QA app is green.
6. **Ship decision — gated or autonomous.** From a **primary checkout** (not a
   worktree — gems resolve as siblings at the projects root), choose the ending
   that matches the session trigger:
   - **`Build and Deploy QA Release`** → stop at the production gate and hand off
     `bin/release ship --by conductor`. Add `--yes` only after explicit ship
     approval in this session or an already-approved rollout prompt.
   - **`Merge, Assemble, Deploy`** → run `bin/conductor ship --run`, which
     executes `bin/release ship --by conductor --yes`.

   Both paths run the same production sequence: preflight (clean-`main`
   assertion) → `avi_ship_gate` (each app's test suite on the frozen ship SHA;
   **aborts on any failure** before anything irreversible) → producer-first gem
   publish → ff each repo's `release → main` → deploy + smoke `/up` → prod
   `post_deploy_cmd` → members `shipped` → auto-posted release notes. If a gate
   aborts, report it and don't force past.
7. **Close the loop (optional).** `bin/release archive --yes` (shipped → archived +
   reclaim worktrees) and `bin/release retro --yes` (durable learnings doc).

The per-stage commands below are the building blocks both meta-triggers
sequence:

**One-time setup (per machine/clone).** Run **`bin/release init`** once: it
creates the persistent `release` branch (= `origin/main`) on every gem + app repo
in `config/release_repos.yml` that doesn't already have one. Idempotent — a repo
that already has `origin/release` is skipped.

**`Review submitted PRs`**  *(submitted → reviewed → assembled)*
Review is a **nested chain** (§1.2): **Avi thin-delegates**, then the **PRIMARY
reviewer owns the lane** — it spawns the LIGHT and runs the merge. Not a solo
`avi` pass, and **not a flat peer spawn**. For each `submitted` task
(`bin/task list` or the board):

1. **Spawn Avi (thin gate).** He confirms **product-acceptance** — does the open
   PR (base `release`) meet the task's acceptance criteria? — and picks the pair
   (step 2). He does **not** run the deep technical review.
2. **Pick the two seniors.** Avi runs **`bin/reviewer-select <task>`** — it loads
   the app and scores the pool `{shannon, carl, jasper, steffon, alex}` by
   **domain fit** (the task's shape + repositories + risk tags vs each soul's
   `domains`) with a **logged, seeded-per-task tiebreak**, returns **1 PRIMARY + 1 LIGHT**, and
   **excludes the QA owner** (Steffon, who QAs the assembled RC — no self-gating),
   **the builder** (read from `devops.built_by`, auto-stamped on the build move
   from the assigned `agent_slug` — so a soul never reviews their own work with
   **no manual flag**), **and any busy souls** you name. `alex` is the
   orchestrator who also holds the launchable Documentation review seat — one
   identity. (`--qa-owner SLUG` excludes a different soul when Steffon isn't the
   one QAing this task; `--builder SLUG` overrides the recorded built_by;
   **`--busy a,b,c`** and/or **`--busy-auto`** (a board query of agents on
   `stage=building` tasks) drop agents mid-build/review elsewhere — the pool is
   never starved below a pair, the least-bad are kept back; `--json` for a
   machine-readable pick; **`--record`** writes the picked pair onto the task as a
   **review intent** so /deployments + the task timeline show the two seniors
   reviewing live — a green ticking timer — the moment Avi kicks off review,
   before `→reviewed` lands. With a custom `--qa-owner` or a non-empty `--busy`
   set the preview is **advisory** — `--record` it so the busy-aware pair is the
   one the timeline shows.)
3. **Spawn the PRIMARY; the PRIMARY spawns the LIGHT (nested).** Avi/the conductor
   spawns the **PRIMARY** reviewer as a sub-agent, handed ALL the technical-review
   goals and **ownership of the rest of the lane**. The PRIMARY does the deep pass
   (Opus on `migration`/`payment`/`solana`/`auth`) — **diff-vs-acceptance + code
   standards + code smell + scalability**, plus confirming the shape's **base**
   tiers are green — and **spawns the LIGHT reviewer as its OWN sub-agent** for a
   focused pass, so the primary already holds full context when the light's verdict
   returns. **Honor the ≤5-concurrent cap** (operating model): across all PRs in
   flight, keep at most 5 review agents running at once — a queue wider than ~2 PRs
   reviews in **waves of ≤5**, never the whole batch at once.
4. **Resolve — the PRIMARY owns the close.** Both complete and **neither flags a
   blocker** → the **PRIMARY** drives the task to `reviewed` (`bin/task move <task>
   reviewed`) AND runs **`bin/release merge <task>`** to land its PR in `release`
   (membership flips `reviewed → assembled`) — the conductor no longer runs this
   for a freshly-reviewed task. Any reviewer blocks → **`bin/task block <task>
   --kind rework --feedback "…"`** (one complete send-back). Bias to action: two
   green approvals = go (`release` reverts cleanly).

**Agentic intent — the live "who's on it now".** Each event carries the agent
that STARTED it, not only the one that completed it, so /deployments and the
task's consolidated **Stage Timeline** show who's working *right now* with a
green ticking timer — the Deploy mirror of the build lane's live counter. These
are append-only `TaskEvent`s of `kind: intent` (completed transitions stay
`kind: transition`; named non-moving lifecycle completions such as heavy/light
review verdicts use `kind: checkpoint`; and an intent never enters the duration spine); an intent is
"open" only inside the source-stage cycle where it was recorded. A later
transition into its target stage supersedes it, and leaving the source stage
(for example `submitted → blocked`) closes it even if the target never landed.
If QA blocks a PR for rework and the feature agent rebuilds/resubmits it, Avi can
record a fresh `→reviewed` intent for the second review round. Build-lane intent = the task's
Pokémon mascot (assigned at create). The
review pair is recorded by **`bin/reviewer-select <task>`** (step 2 — recording
is the DEFAULT now; pass `--no-record`/`--dry` for an advisory-only preview);
Steffon's QA and Avi's ship intents are **auto-recorded by the deploy CLI** —
**`bin/release prepare`** fires the `assembled` intent (`actor: steffon`) and
**`bin/release ship`** the `shipped` intent (`actor: avi`), both via
`Release::Conductor.record_deploy_intents!` over every release member (the Deploy
mirror of `bin/reviewer-select`'s default review-intent write). So the conductor
no longer hand-runs them — the 2026-06-25 unfilled-ship-slot incident (a missed
manual `bin/task intent --to shipped --actor avi` left the ship crew slot blank
mid-deploy). The manual **`bin/task intent <task> --to assembled --actor
steffon`** / **`--to shipped --actor avi`** (or `POST
/api/v1/tasks/<slug>/intent`) stays as the fallback / one-off path. All of them
are append-only + idempotent — an identical open intent in the current
source-stage cycle is reused, and the call is a no-op once the target stage has
landed in that cycle. Actor-less
conductor moves on `assembled`/`shipped` still attribute to their role owners
(Steffon QAs `assembled`, Avi ships) so the Deploy crew never goes blank.

**`Prepare release`**  *(reviewed → assembled — an RC for QA)*
Two deterministic steps:

1. **Merge approved PRs into `release` (BATCHED).** Run **`bin/release merge
   <task-slug> [<task-slug> …] --yes [--prod]`** — it accepts **one OR many**
   slugs (run the pre-merge checklist first — `gh pr ready <n>` to un-draft,
   `gh pr edit <n> --base release` to retarget). It resolves every task's PR in
   **one** board read, verifies each unique PR base is `release`, `gh pr merge`s
   each **unique PR once** (several task records may intentionally ride the same
   PR), then `Release::Conductor.adopt!`s **all task slugs in a SINGLE `heroku
   run`** (one dyno spin-up, N `reviewed → assembled` flips) —
   opening/reopening the singleton release as needed. A merge **conflict surfaces
   here** (resolve on GitHub or block the task for rework); `release` is never
   force-pushed. Gem PRs merge into their own repo's `release` like any other.
   - **Why batched:** the old one-slug-at-a-time loop did a cold-start `heroku
     run` adopt **per PR** — three in a row blew the 2-min tool timeout, and a
     mid-loop timeout left a PR *merged* but its task stuck `reviewed` (a
     half-state). Batching collapses the adopts to one dyno; the adopt also runs
     in an **`ensure`**, so every PR that *did* merge is still adopted even if a
     later `gh pr merge` aborts — the half-state can't recur.
   - **Overlap planner (warning only).** With ≥2 slugs, before merging it fetches
     each PR's changed files (`gh pr view <n> --json files`), then prints the
     pairwise **file collisions**, a **suggested merge order**
     (smallest-footprint first), and which PRs will likely need a **post-merge
     rebase** (they touch a file an earlier same-repo PR already merged). It
     **never blocks** — merges proceed in the order given; it just surfaces the
     "siblings all touched `task.rb`" rework *before* it happens. Pure logic:
     `Release::MergePlan.compute`.
2. **Deploy the candidate to QA.** Run **`bin/release prepare --yes [--task SLUG ...]
   [--slug rel-…] [--prod]`** (`Release::Conductor.prepare!`): finds the active
   release, **auto-records the Steffon → `assembled` QA intent** for every member
   (`Release::Conductor.record_deploy_intents!(r, to_stage: "assembled", actor:
   "steffon")`, append-only + idempotent — a no-op for any member already past
   `assembled`) so /deployments shows Steffon QA-ing the RC live with no hand-run
   `bin/task intent`, runs a per-app **merge-forward guard** (keeps each repo's
   `release` ahead of `main`), then `bin/qa-server deploy <qa_app> origin/release`
   for each **app** member — **gem members are skipped** (no app artifact; they ride
   the record and are QA'd via a consuming app). It records `release.qa_url` +
   per-repo QA SHAs and leaves the RC `assembled`. `--task` is operator curation
   (adopt the named tasks first); it does **not** auto-adopt every reviewed task.
   Record ops run on the **prod board by default** (the board IS production) via
   `heroku run`; `--local` opts into the stale local DB. **Post-deploy hook:** once each QA dyno boots (after
   `wait_for_boot`, before the assemble flip), for every member that declares
   `devops.post_deploy_cmd` it runs that command on the member's **QA heroku app**
   via `heroku run`, records the `[post-deploy]` outcome on the task's
   `checks_run`, and **aborts `prepare` on a non-zero exit** (so the RC stays
   `assembling`, re-runnable). The `{task, app, cmd}` plan + the QA-vs-prod target
   resolution are the unit-tested `Release::PostDeploy.plan`.

**`Run Deployment`**  *(assembled → shipped — promote the QA'd RC to prod)*
Run **`bin/release ship [--by NAME] --prod`**. Without `--yes` it confirms
before deploying; with the **`Merge, Assemble, Deploy`** workflow (or another
explicit production rollout prompt), use
`bin/release ship --by conductor --yes`. `--yes` skips only the confirm prompt.
**Preflight FIRST (before any fast-forward):** ship asserts every **app checkout**
is on a **clean `main`** and aborts loudly — naming the offending branch / dirty
files — if any isn't. ship ff's each repo's `main` up to the QA-frozen SHA, so a
checkout a review agent left on a leftover `pr-NNN` branch or with an uncommitted
stale `schema.rb` would otherwise break the ff *mid-ship* (after gems published +
the ship authorization — the worst time). The preflight catches it up front,
before anything irreversible. Pure decision:
`Release::ShipSequence.preflight_offenders` / `.preflight_message`. **Live ship
crew:** right after ship authorization (so a declined gated ship never shows it),
ship **auto-records the Avi → `shipped` intent** for every member
(`Release::Conductor.record_deploy_intents!(r, to_stage: "shipped", actor:
"avi")`) so /deployments shows Avi shipping live — a green ticking timer — through
the whole deploy instead of an empty dashed ship slot until `ship!` lands (the
2026-06-25 incident). Append-only + idempotent (`ship!` supersedes it; a
partial-ship abort leaves it open — correct, Avi is still shipping — and a re-run
reuses it). **Producer-first:** before any app deploy, it publishes every
**gem member** to RubyGems in order — for each it prints the gem + target
version and asks `Publish <repo> <version> to RubyGems?` (approval-gated; honors
`--yes` / `--dry-run`), runs the gem's build (studio-engine: `bin/release-check
--build`; otherwise `gem build <gemspec>`), `gem push`es the artifact, and tags
`v<version>` in the gem repo. A build/push failure **aborts the ship** before any
app deploys, so apps never deploy against an unpublished gem. Then for the apps
it fast-forwards each repo's `main` up to `release` (so `release` collapses into
`main`), pushes origin, deploys (`git push heroku main`; release phase runs
migrations), and smokes `/up`. After every app deploys + smokes (and before the
`shipped` record), the **post-deploy hook** runs each member's
`devops.post_deploy_cmd` on its **production app** via `heroku run`, records the
`[post-deploy]` outcome, and **aborts `ship` on a non-zero exit** — the abort
lands before `ship!`, so the release stays `assembled` (recoverable) and a re-run
resumes (the command is expected idempotent). On success it stamps `deployed_sha`,
flips the RC + its members to `shipped` (`Release::Conductor.ship!`), and
**auto-posts release notes**
(`Release::Conductor.post_release_notes` → the same Formatter/Discord path as
`POST /api/v1/release_notes`; non-fatal if the webhook is unset). After a ship,
each repo's `release` equals `main` and re-accumulates the next candidate. Run
`ship` from a **primary checkout** (not a worktree): the gem repos are resolved
as siblings at the projects root.

**`Archive completed tasks`**  *(shipped → archived — the Deploy loop's conclusion)*
Run **`bin/release archive [--dry-run] [--yes] [--prod]`** to close the loop. It
archives every `shipped` task that is **not** a member of `Release.last_shipped`
(`shipped → archived`), so the most recently shipped release stays on the board
as the read-only **Last Release** while older, superseded completed work is filed
away. The pure, unit-tested rule lives in
`Release::Conductor.archive_completed!` / `.archivable_completed_slugs`; the CLI
owns the board write plus the worktree teardown around it. After archiving it
reclaims the merged/shipped feature worktrees (`bin/agent-worktree cleanup
--reclaim --yes`). `--dry-run` previews the plan (archivable + kept) and the
reclaim list without mutating anything; `--yes` runs it hands-off (skips the
single confirm). Idempotent — a re-run finds nothing new to archive. Archiving
only flips a task's stage, never its `release_slug`, so the board's Last Release
section keeps linking to its members even after they're later archived,
preserving the release history. `shipped` is therefore **no longer terminal** —
the Deploy loop now closes at `archived`. **The ledger commits itself:** after the
reclaim appends to `delete-later.md`, archive commits that update to `release`
(best-effort, only when the ledger is the *sole* uncommitted change — pure guard
`Release::ArtifactCommit`), so it ships next round instead of piling up as
ship-preflight stash dirt the conductor has to park.

**`Release retro`**  *(post-ship "review & learn" — completely NON-BLOCKING)*
Run **`bin/release retro [release-slug] [--worked "…"] [--friction "…"] [--followup
"…"] [--file-tasks] [--yes] [--dry-run]`** after a ship to capture what the release
taught us. It defaults to the current / most-recently-shipped release, **auto-gathers**
the release record (member tasks + kinds, per-member `submitted → shipped` cycle
timing from `TaskEvents`, rework rounds = bounces into `blocked`, reviewers, and
recorded `checks_run`), prompts a few judgment questions (what worked / what caused
friction / follow-ups — `--worked`/`--friction`/`--followup` supply them from args,
`--yes` runs fully non-interactive), and **writes a durable doc** at
`docs/agents/audits/retro-<slug>.md`, then **commits that doc to `release`**
(best-effort, non-fatal, only when the doc is the *sole* uncommitted change —
`Release::ArtifactCommit`) so the generated retro ships next round rather than
becoming ship-preflight stash dirt. `--file-tasks` opens each follow-up via
`bin/task create`. The gather + render rule is the pure, unit-tested
`Release::Retro` (`.gather` / `.render` / `.write_doc`); the CLI reaches it through
the same read-only `conductor` runner and writes the returned markdown to the local
tree. It writes **no** agent-memory store — the doc (+ any filed tasks) is the only
record. **Retro is decoupled from the pipeline by design:** `archive` does not
depend on, trigger, or wait for it, so the loop closes whether or not a retro was
run. Unlike `ship`/`archive`, retro never deploys or mutates the board, so it does
not gate on `--yes`.

---

## 2. Two SOPs: Feature and Bug

Both ride the same stage machine. They differ at entry and in test emphasis.
Routing lives in `AGENTS.md` (see §6) so an agent self-loads the right one.

### Feature SOP

1. **Classify the shape** (see §3) — this selects the test contract.
2. Accumulate acceptance criteria with Mr. McRitchie until aligned (existing rule).
3. Set `test_plan` = the shape's required tiers.
4. Build **and write the tests at each required tier as you go** — unit first.
   This is the lever for the real complaint: *bugs that reach PR are bugs unit
   tests should have caught.* Left-shift is mechanical, not optional.
5. Self-run the **Definition of Ready (DoR)** check (`bin/dor-check`) — `--gate
   build` before you start coding, `--gate merge` before handoff (§3.3).
6. Record `checks_run`, hand off with a `handoff` note, move to `submitted`.

> **Every `bin/task move` leaves a paper trail — for free.** Each stage change
> appends a `TaskEvent` capturing `from → to`, the timestamp, and the time spent
> in the prior stage (the deterministic spine; it renders as the **Stage Timeline**
> on the task page). You do nothing to get it. To *also* attribute model cost to a
> transition, add the optional per-transition usage on the move:
> `bin/task move <task> submitted --model claude-opus-4-8 --tokens-in N --tokens-out N --cost D`.
> Usage is best-effort and opt-in; the spine is recorded regardless (and for
> non-agent moves too). Details:
> [`task-board-api.md`](../modules/task-board-api.md#stage-change-event-trail).

### Bug SOP

1. Classify **severity**: `hotfix` (production broken / funds at risk) vs `normal`.
2. **Write a failing regression test that reproduces the bug *first*** — at the
   lowest tier that can express it (a bug fixable by a unit test must get a unit
   test, not an E2E). The red test is the acceptance criterion.
3. Fix until the regression test is green; run the shape's contract for the
   touched surface.
4. `hotfix` may go straight to `building` and use an expedited review, but
   **never** skips the regression test or the operator ship gate.

> Why regression-test-first for bugs: it both proves the fix and permanently
> pushes that class of bug down the pyramid, shrinking future PR-stage churn.

### Standalone / Client App SOP

Not every app is a managed satellite. A **standalone / client app** uses the
studio's *process* — the task board, worktrees, the multi-agent merge patterns,
and the evergreen build conventions — but **owns its own runtime** and may be
handed off to a client. It rides the same **Build** workflow
(`designed → building → submitted`). Its **Deploy** half has two modes:

**Release-managed standalone** (Rolio, as of 2026-06-27):

- **PRs target `release`** once `bin/release init` has created the branch.
- **QA RC exists** — reviewed PRs merge into `origin/release`, and
  `bin/release prepare` deploys `origin/release` to the app's QA Heroku target
  from `config/qa_environments.yml`.
- **Operator ship gate exists** — `bin/release ship --by conductor` fast-forwards
  `release → main`, pushes production, and smokes the app's
  `prod_deploy.smoke_url`.
- **Runtime remains app-owned** — no `studio-engine` or hub SSO requirement.

**App-owned standalone**:

- **PRs target `main`, not `release`** — there is no persistent `release` branch
  and no release slug. `bin/agent-worktree` already falls back to `origin/main`
  as the base for any repo without a `release` branch.
- **The app team owns the merge** — an approved PR is merged into `main` by the
  app's owner; it is not assembled into a studio RC.
- **Lite DoR** — task + tests-as-you-go + the non-optional error-logging
  discipline; no release-slug / shape-gated `bin/dor-check` ceremony. (Robust
  error/API-failure logging is evergreen for *both* tiers — managed apps via
  `studio-engine`'s `rescue_and_log`/`ErrorLog`, standalone apps via plain
  `Rails.logger` and/or their own tracker.)
- **No QA RC, no operator ship gate** — the app owns its deploy and its eventual
  client handoff.

Full tier decision + phased checklist:
[`new-app-onboarding-sop.md`](new-app-onboarding-sop.md). Multi-agent build/merge
patterns (several agents scaffolding one app in parallel):
[`../modules/worktrees.md`](../modules/worktrees.md) → **Multi-Agent Safety &
Merge Patterns**.

> **Shapes are deployment-agnostic.** `config/feature_shapes.yml` and the
> shape→tier contract (§3) classify the *kind of change* (ui-only, backend,
> library, …), not the deploy tier — so they apply unchanged to a standalone app.
> The shape still selects which tiers you write; the standalone tier only changes
> *where the PR lands and who ships it*. No `feature_shapes.yml` change is needed.

---

## 3. The adaptive testing pyramid

Your insight: the pyramid must *adapt to the nature of the feature*, from one
general strategy, across all five repos. Three pieces: tier definitions (the
*what*), the shape→contract matrix (the *adaptation*), and the DoR gate (the
*enforcement*).

### 3.1 Tier definitions (general, then per-repo)

| Tier | General definition | Rails apps | studio-engine | solana-studio | turf-vault |
|---|---|---|---|---|---|
| **Unit** | Pure logic, no I/O | model/service/PORO/decoder specs | pure lib (`ColorScale`, `Email`…) | Borsh/keypair/tx builders | single instruction handler logic |
| **Component** | One behavior + its immediate collaborators, no full stack | request/controller specs + rendered partial + Alpine factory | UI primitive via a host harness | client method w/ stubbed RPC | instruction + its account constraints |
| **Integration** | Multiple objects across a boundary | request→DB→job, RPC-mocked Solana (`FakeVault`) | consumer-CI against both apps | client against test-validator | multi-instruction lifecycle (create→enter→settle) |
| **E2E** | Real browser / real chain | Playwright | (via consumers) | (via consumers) | devnet on-chain spec |
| **Manual** | Operator visual/UX acceptance | **the release QA stop** (eyeball the `assembled` RC, then Make the release) | — | — | contract transparency / `/contract` review |

Tiers are the **what**; the existing **test lanes** are the **when/where**.
Mapping: Unit+Component+Integration → `pr_review_gate`/`local_proof` (block
merge); E2E happy-path → `local_proof`, full E2E → `nightly_deep`; Manual →
`qa_acceptance`; post-deploy → `production_smoke`.

### 3.2 Shape → test contract (the adaptation)

A feature's **shape** is recorded in `devops.shape`. It selects the minimum
tiers that must be green by the time the task is `submitted` for review:

| Shape | Example | Required tiers (DoR contract) |
|---|---|---|
| **ui-only** | "make the button blue" | Component (rendered partial / Alpine) + Manual at QA. Unit only if it adds logic. |
| **ui+db** | new form that persists | Unit (model/validation) + Component (request+view) + Integration (request→DB) + E2E happy path |
| **backend** | new job/service | Unit (service/PORO) + Integration (job + mocked I/O) |
| **library** | studio-engine change | Unit in engine + **consumer-CI** (component/integration in *both* apps) |
| **onchain** | new turf-vault instruction | Anchor unit + Anchor integration (lifecycle) + Ruby decoder unit + devnet E2E (nightly) |
| **onchain-vertical** | new workflow w/ wallet + DB + UI + program | all tiers + devnet E2E; almost always its own `release` |

The matrix is the single source of "how much testing is enough" — it removes
the per-task judgment call that currently lets thin PRs through.

### 3.3 Definition of Ready for review (DoR) — the enforcement

A task **may not advance `submitted → reviewed`** unless, for its shape:

- every required tier is present and green, recorded in `checks_run`;
- the **FULL test suite and a FULL `rubocop`** are certified green against the
  *exact code being shipped* — not the touched-file subset. The shape's tier tags
  prove the agent *wrote* unit/integration; they do not prove nothing *else*
  broke. `bin/full-suite-check <task>` runs `bin/rails test` and `bin/rubocop` in
  full and stamps fingerprint-bound `[full-suite@<fp>]` / `[rubocop@<fp>]`
  `checks_run` lines; `bin/dor-check` re-grades them against the current code
  fingerprint (a git tree hash — content-addressed, so it is **stable across the
  pre-commit→commit boundary** and identical in a reviewer's fresh checkout), so a
  **stale** (edited-since) or **partial** (one-lane / touched-files) record is
  **refused**. Escape hatch — a *record*, exactly like `post_deploy_cmd: none`: a
  reasoned `[full-suite-bypass] <why>` `checks_run` line passes the gate but is
  flagged **loudly** in the verdict (use it for a pre-existing, unrelated red
  tracked elsewhere — never to wave through your own break);
- required `metadata["devops"]` fields are populated (existing contract);
- a local proof URL exists when the shape touches UI;
- if the branch diff touches a **seed or data-migration** (`db/seeds`,
  `db/migrate/`), the task declares `devops.post_deploy_cmd` — the command
  `bin/release` runs on the deployed app (QA on `prepare`, prod on `ship`) so a
  seed/backfill isn't run by hand post-ship. Heroku's release phase auto-runs
  `db:migrate` but **not** `db:seed` or a backfill rake; set `post_deploy_cmd` to
  `none` to acknowledge a schema-only migration that needs no command.
- **`post_deploy_cmd` safety rule (both gates):** `bin/release` runs the command
  **verbatim against PRODUCTION**, so it must be **narrow, prod-safe, and
  idempotent**. A declared `post_deploy_cmd` is **rejected** when it is a bare
  full-suite seed — `bin/rails db:seed`, `rails db:seed`, `bundle exec rails
  db:seed`, `db:seed:replant`, or `rake db:seed`. `db/seeds.rb` loads **every**
  `db/seeds/*.rb`, so a bare seed would inject demo News/Content/Tasks into prod
  **and** abort the release on the first non-idempotent seed file. Declare a
  narrow command instead: a **scoped single-file runner** —
  `rails runner 'load Rails.root.join("db/seeds/NN_x.rb").to_s'` — or a
  **dedicated idempotent rake task** (e.g. `bin/rails pokemon:seed`). This is the
  fix for a real near-miss: `merge-docs-reviewer-into-alex` shipped
  `post_deploy_cmd='bin/rails db:seed'` and was caught only when QA aborted,
  because reviewers read the code diff, not the deploy metadata.

This is **deterministic** — a `bin/` gate (`bin/dor-check <task>`, default
`--gate merge`), not a judgment call. There is also a lighter `--gate build`
(spec-complete, no tiers) for the `designed → building` entry. The feature agent
runs it before handoff; the heartbeat agent re-runs `--gate merge` as gate zero
of review (the fingerprint-bound full-suite evidence is checkout-independent, so
gate-zero credits the same evidence the feature agent recorded). A failed DoR is
an *immediate, cheap* send-back that never consumes review-judgment tokens. This
is the structural fix for the review ping-pong: most "PR not ready" churn becomes
a pre-PR mechanical check.

`bin/dor-check` itself stays a **fast, deterministic verdict** — it does *not*
run the suite; `bin/full-suite-check` is the (slower, run-once-before-handoff)
runner that produces the evidence (format + fingerprint live in
`bin/lib/full_suite_gate.rb`). It closes the retro gap where a build passed only
the **files it touched** while the full suite or `rubocop` broke post-merge. For
those who want the lanes wired locally, `bin/full-suite-check --install-hook`
installs an **opt-in pre-push** hook (off by default; runs the gate before each
push, blocks a red push; remove with `--uninstall-hook`) — pre-push, not
pre-commit, because a full suite on every commit is untenable. But the
**authoritative** gate is `bin/dor-check` validating the recorded evidence: the
hook is a convenience, and evidence on the task record survives a fresh checkout
where a local hook artifact would not.

### 3.4 Test ownership & timing — *who writes what, when*

| Tier | Author | When |
|---|---|---|
| Unit | Feature agent | During build, before first commit |
| Component | Feature agent | Before `submitted` |
| Integration | Feature agent | Before `submitted` (mandatory for any `migration`/`solana`/`payment`/`auth` risk tag) |
| E2E (happy path) | Feature agent | Before `submitted` for ui+db / vertical shapes |
| **Full suite + rubocop** | Feature agent | Before `submitted` — `bin/full-suite-check <task>` certifies the WHOLE suite + lint (not the touched-file subset); records fingerprint-bound evidence `bin/dor-check` re-grades |
| E2E (edge/regression) | QA lane (Avi/Steffon) | May add during review; becomes a follow-up task if large |
| Manual | **Mr. McRitchie** | At the release QA stop (this *is* the manual tier) |

### 3.5 Test pruning — *when and how we keep tests effective*

Pruning is a recurring **`chore`** task owned by the QA/infra lane (Steffon),
on a monthly cadence, tracked like any other task.

- **Triggers:** suite wall-clock regression, flake-rate climbing, an
  "inverted pyramid" smell (E2E count growing while unit coverage stalls).
- **Actions:** flaky → `quarantine` lane + a follow-up task (never silently
  skip); redundant → delete the higher-tier test when a lower tier now covers
  it (push coverage *down* the pyramid); dead → remove tests for removed
  behavior.
- **KPIs (tie to Avi's rework-rate):** suite wall-clock per lane, flake rate,
  coverage-per-tier, and "bugs that reached PR" (a falling number proves
  left-shift is working). Track these through task QA notes, CI, and
  `bin/devops-tests`; daily steering still comes from task status.

---

## 4. The airgapped heartbeat DevOps agent

Runs on the OpenClaw box every ~10 minutes. Builds directly on the
`devops-cycle`/`qa-intake` toolchain and the "Future Heartbeats" lease spec.

### 4.1 One heartbeat = evaluate every in-flight task, advance each ONE safe step

```
# Workflow 1 — per task (review).  Each submitted task, one safe step.
for each task in {submitted}:
  acquire lease (claimed_by, claim_expires_at)   # resilience: reclaimable
  1. bin/dor-check --gate merge (gate-zero: metadata + tiers + FRESH full-suite/rubocop evidence) — fail ⇒ block(rework) + qa_feedback, release
  2. run pr_review_gate suite (base: unit/component)            — fail ⇒ classify, block(rework), release
  3. Avi delegates: 2 seniors (domain fit + LOGGED tiebreak), 1 PRIMARY + 1 LIGHT — §1.2
     each: diff-vs-acceptance + standards/smell/scalability     — changes ⇒ ONE complete qa_feedback + block
  4. on 2 approvals → reviewed ✅                                — Discord: approved

# Workflow 2 — the ONE active release (singleton).
release.assembling:
  pick next reviewed member(s) honoring dependencies + lanes (§4.2)
  bin/release merge <task...>: overlap planner (warn) → gh pr merge each (base release) → adopt ALL in ONE heroku run (ensure)  — conflict ⇒ block task (resolve on GitHub)
  member(s) → assembled; when desired members in + integration + e2e-smoke green on origin/release (Steffon):
  bin/release prepare → deploy origin/release → QA + Discord notes → release.assembled
  # full e2e + highest tier runs at ship, on the FROZEN ship SHA (Avi) — §1.2
release.assembled:
  Avi: full e2e + highest tier on the FROZEN ship SHA          # §1.2 — closes "shipped ≠ tested"
  if operator_made_the_release: bin/release ship → PREFLIGHT (each app on clean main, else abort) → ff release → main, bin/deploy → production_smoke → notes → members shipped  # ONLY here
  else: no-op (HARD STOP — wait for the operator to Make the release)

update last_heartbeat_at, current_command, blocked_reason; emit progress
```

Properties that give resilience + scale:

- **One step per heartbeat** → bounded blast radius; an interrupted step is
  re-attempted next tick from the durable task state, not from agent memory.
- **Lease fields** (`claimed_by`, `claim_expires_at`, `last_heartbeat_at`) →
  an interrupted task is reclaimable by the next heartbeat; this is exactly the
  interruption-resilience you asked for, at the task level.
- **Idempotent steps** → merge/deploy/notes are safe to retry.
- **Every heartbeat produces evaluation + progress** by construction — even a
  "nothing changed" tick posts a one-line status.

### 4.2 Order-of-operations / conflict serialization (the multi-feature problem)

The heartbeat agent will not merge-race conflicting work:

- **Overlap planner (pre-merge heads-up).** A batched `bin/release merge a b c`
  prints, before merging, the **files each PR shares with the others**, a
  suggested merge order (smallest-footprint first), and which PRs will need a
  post-merge rebase — so siblings that all touched `task.rb` / a shared helper /
  the docs don't conflict on `release` *after* passing review. Warning-only (it
  never blocks); the conductor reads it to choose order / rebase the loser.
- **Migrations:** two tasks touching `db/schema.rb` or migrations → serialize
  via the existing `backend_migration` advisory lock; second one holds with a
  note.
- **studio-engine + consumers:** gem publish → consumer lockfile bump → app
  deploy is one ordered `release_slug` lane; the agent promotes the
  train in order, never a consumer ahead of its gem.
- **turf-vault program:** **new rule** — at most one in-flight task may change
  the Anchor program (same advisory-lock pattern as migrations). A vault change
  and its turf-monster IDL re-pin form a `release_slug` deployed *in order*
  (Squads program upgrade first, then app IDL re-pin via `bin/deploy`'s
  allow-list dance). The agent refuses to deploy two program upgrades
  concurrently.
- Because **prod is always human-gated**, the riskiest ordering decisions
  (anything `migration`/`solana`/`payment`) still land in your one-click queue
  with full context — the agent sequences, you approve.

---

## 5. Visibility — standardized Discord

Three message classes, **deterministic templates** with a small freeform
`notes` slot. Posted freely by the heartbeat agent.

| Class | Trigger | Shape (deterministic) |
|---|---|---|
| **Heartbeat digest** | every tick (or every N) | `🔄 DevOps tick HH:MM — N in review · M in QA · K awaiting approval. Blockers: …` |
| **Task event** | stage advance / send-back | `✅ <title> merged → QA <url>` · `⛔ <title> sent back: <reason>` · `🟡 <title> QA-passed — approve to ship: <qa url>` |
| **Release notes** | after prod deploy | existing `POST /api/v1/release_notes` (already standardized, grouped-by-app, task-linked) |

The 1000ft view: blockers + "awaiting approval" are the only two classes you
*must* read; the digest is ambient. Webhooks: reuse
`DISCORD_RELEASE_NOTES_WEBHOOK_URL`; add `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`
for digests/events so release notes stay clean.

---

## 6. Agentic context routing (never re-explain the cycle)

Add a routing block to `AGENTS.md` so a fresh agent self-selects its SOP:

```text
## DevOps Routing
Before implementing, identify your role and read the matching section of
docs/agents/system/devops-cycle-design.md:
- Handling a FEATURE → § Feature SOP. Classify the feature SHAPE and load its
  test contract before writing code. Build: designed → building → submitted.
- Handling a BUG → § Bug SOP. Write the failing regression test first.
- Running the airgapped/QA cycle → § Heartbeat agent. One safe step per task;
  review moves submitted → reviewed or blocked; never ship a release without the
  operator OK.
```

Everything else the agent needs already loads via the existing `Start Here`
table. No per-session explanation from you.

---

## 7. Deterministic vs judgment + model budget

Compartmentalize tokens: deterministic scripts carry the 80%; escalate to a
capable model only for genuine review judgment, and only to Opus for high-risk
surfaces.

| Step | Nature | Engine | Model |
|---|---|---|---|
| DoR gate, metadata presence | deterministic | `bin/dor-check` | none |
| Run test suites | deterministic | CI / `bin/devops-tests` | none |
| Conflict / lane check | deterministic | `bin/` + advisory locks | none |
| Classify a check failure (real / flaky / stale) | light judgment | small model | Haiku |
| QA acceptance evaluation | suite + light judgment | suite + small model | Haiku |
| PR diff vs acceptance review | judgment | capable model | **Sonnet**, **Opus** if `solana`/`payment`/`migration`/`auth` |
| Merge decision | rules-gated judgment | rules + model | Sonnet |
| QA deploy / prod deploy | deterministic | `bin/qa-server` / `bin/deploy` | none |
| Release-notes formatting | deterministic | `POST /api/v1/release_notes` | none |
| Release-notes highlights prose | light judgment | small model | Haiku |
| Discord digest / event messages | deterministic templates | script | none |
| Production approval | **human** | — | Mr. McRitchie |

---

## Decisions to confirm (call these before implementation)

1. **`shape` field** vs inferring shape from `risk_tags` — add an explicit
   `devops.shape` field, or derive it? (Recommend explicit; it's the contract key.)
2. **Hotfix lane** — do you want an expedited `hotfix` severity that goes
   straight to `building` and shortens review, still regression-tested +
   ship-gated? (Recommend yes.)
3. **turf-vault single-writer lane** — confirm only one in-flight program change
   at a time is acceptable (it serializes blockchain work). (Recommend yes; it's
   the safe default given Squads + IDL pinning.)
4. **Progress webhook** — separate `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`, or
   reuse the release channel? (Recommend separate.)
5. **Heartbeat read path** — the airgapped box reads the production task board
   over the existing bearer-token API; confirm that network path is allowed from
   the OpenClaw environment (the one external dependency the airgap must permit).

## Implementation order (each its own task)

**Done**

- `bin/dor-check` + the `shape`→contract matrix in `config/feature_shapes.yml`.
- `AGENTS.md` / `CLAUDE.md` routing block.
- **The two-workflow status model**: Task stages + state machine,
  `bin/task` / `bin/dor-check` / board, the data migration, `blocked` metadata
  (`blocked_from` + `block_kind`), and the DoR-to-Build / DoR-to-Merge gates.
- `Release` singleton model + `release_slug` / `dependencies` on Task + the
  board's "current release" header.
- **The persistent-`release` branch cutover**: `bin/release init|merge|prepare|
  ship` on the persistent per-repo `release` branch — membership flips at merge
  (`merge` → `gh pr merge` + `Release::Conductor.adopt!`), `prepare` deploys
  `origin/release` to QA, `ship` fast-forwards `release → main` (§1.1).

**Next**

1. Flip `bin/agent-worktree`'s automatic PR `--base` default from `main` to
   `release` (branch-from + `finish --pr` base), so feature agents no longer pass
   `--base release` by hand.
2. Migrate the heartbeat planner `bin/devops-cycle` (+ its snapshot fixture +
   `bin/devops-tests` lane names) from the legacy stage names to the new ones.
3. Pyramid re-tag of suites in `config/devops_test_suites.yml`.
4. Discord progress/event templates + `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`.
5. The heartbeat agent script for the OpenClaw box (review→QA first; ship gate as
   a no-op approval check).
6. turf-vault single-writer advisory lane.

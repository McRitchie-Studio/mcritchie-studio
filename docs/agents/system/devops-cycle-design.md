# DevOps Cycle — Design (v2)

> **Status:** approved model, landing incrementally. The **two-workflow task
> status model is now live** — `Task` stages are
> `designed → building → submitted` (Build) and
> `submitted → reviewed → assembled → shipped` (Deploy) — meeting at the
> `submitted` seam — plus `blocked` (side) and
> `archived` (terminal). `bin/task`, `bin/dor-check`, and the board speak it.
>
> **Still to land (each its own task):** the `Release` singleton model + the
> release-branch assembly/abandon tooling (§1.1); migrating the heartbeat
> planner `bin/devops-cycle` from the old stage names to the new ones (it is
> self-consistent on the legacy snapshot today); the Discord progress webhook
> (§5). Where this doc describes those, it is the spec for the follow-up.
>
> Visual companion: the in-app DevOps cycle viewer at `/devops/cycle`
> (admin-gated; `DevopsController#cycle`, view at
> `app/views/devops/cycle.html.erb`).

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
| Sealed-bid sizing, `backend_migration` advisory-lock lane, `release_train` lane | `sizing-rubric.md`, `exclusive-lanes.md` | Order-of-operations machinery. |
| Test lanes (pr_review_gate / local_proof / qa_acceptance / production_smoke / nightly_deep / quarantine) + `config/devops_test_suites.yml` + `/devops` page + `bin/devops-tests` | `testing.md` | The *when/where* axis of the pyramid. |
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
  assembled → shipped`. DevOps judges the submitted PR on its own merits —
  acceptance, diff, tests — landing it at **`reviewed`** (approved) or
  **`blocked`** (rework, with a `qa_feedback` note); the release conductor then
  assembles `reviewed` tasks into a single **release candidate (RC)** on a
  release branch (`assembled`), QAs the whole RC, and on the operator's OK ships
  it (`shipped`). `submitted` is the seam — the feature agent hands the PR to
  DevOps there.

QA and production are properties of the **release**, not the individual task —
so there is no per-task QA stage; the one operator gate is a single OK on the RC.

```
WORKFLOW 1 · Build (feature agent)         WORKFLOW 2 · Deploy (DevOps · Release model)
designed → building → submitted ─────────► submitted → reviewed → assembled → shipped
               ▲         │                  (review)   (approved) (merged RC,  ("run the
               └ blocked ┘                                         e2e green,   deployment"
                 (rework / env / dep)                              QA-deployed)  → prod)
```

`blocked` is the single "not in the pipeline's court" state — an agent hit a
wall, QA bounced the PR, or a dependency isn't ready. It records `blocked_from`
(captured automatically) + `block_kind` (environment / rework / dependency) so a
heartbeat agent routes it without re-reading the thread. `archived` is terminal.

The RC is a **`Release` singleton** (only one assembles at a time). Member tasks
carry its `release_slug`; it carries them through QA→prod and flips them to
`shipped` when it ships. The airgapped agent runs both workflows but **never
crosses the ship gate autonomously** — the operator's single OK on the RC is the
one human gate. The task API is on production, so the airgapped box only needs an
internet connection — no separate pull/sync layer.

### 1.1 The Release model + release branch  *(follow-up task)*

**Release** (new singleton model) coordinates one candidate from assembly through
ship. *Consolidation (decided):* the legacy `release_train` field becomes
**`release_slug`** — one concept, one name.

| Field | Meaning |
|---|---|
| `slug` | Canonical id, e.g. `2026-06-20-s3-uploads`. |
| `state` | `assembling` → `assembled` → `shipped` (+ `abandoned`). `assembled` = every member PR merged **and** the tests check out. |
| `branch` | The disposable integration branch `release/<slug>`, cut from `main`. |
| `confirmed_at` / `confirmed_by` | The operator **Make the release** action at `assembled → shipped` — the one human gate. |
| `qa_url` / `production_url` / `deployed_sha` / `release_notes_sent_at` | Deploy + notes record. |
| has_many `tasks` | via `tasks.release_slug`. |

**Task** gains two links:

| Field | Meaning |
|---|---|
| `release_slug` | The Release this task rides (null until the conductor assigns it; the task is `assembled` once its PR is merged onto the release branch). |
| `dependencies` | Array of task slugs this one needs shipped first. **Now enforced** by the conductor (`Release::Ordering`) — a member sorts after every task listed here — composed under the producer-first rule (e.g. an engine gem before the apps that consume it). |

`dependencies` (task→task) and the exclusive **lanes** (resource-level:
migration, release, vault single-writer) compose: dependencies say *"B needs A's
output"*; lanes say *"only one of these at a time."* As of the gems-first
release work, `dependencies` is no longer spec-only: `Release#ordered_members`
honors it (a stable topological sort that falls back to `position`), so the
conductor sequences members producer-first **and** respects explicit
task-to-task edges. See "Gem members & producer-first ordering" below.

**Assembly is a merge queue on a disposable branch.** The conductor cuts
`release/<slug>` from `main`, then for each `reviewed` member: retargets its PR
base to the release branch (`gh pr edit --base`), merges it, and runs that task's
required tiers against the release HEAD (the punctuated per-merge test). A
conflict or red run **ejects** the task to `blocked` — the train keeps moving.
When every member is in and the **full suite incl. e2e** is green on the release
HEAD, the branch deploys to **QA** + Discord notes fire → the release is
**`assembled`** (complete). The operator then **Makes the release** — an explicit
action (surfaced as the current release on `/tasks`, not a passive status) that
fast-forwards `release/<slug>` into `main`, tags `release-<slug>`, deploys prod,
and flips members to `shipped`. That action is the one human gate.

**Gem members & producer-first ordering.** A release is not apps-only — it can
carry **gem** tasks (`studio-engine`, `solana-studio`) as first-class members
alongside apps. The classification lives in `config/release_repos.yml` (read by
`Release::Repos`): every member is a `:gem` (producer) or an `:app` (consumer).
Gems and apps are handled differently at both ends of the Deploy workflow:

- **Gem members are PUBLISHED, not branch-merged.** A gem's PR/branch lives in
  the gem's own repo, not in `mcritchie-studio`, so there is nothing to merge
  onto `release/<slug>`. At **assembly** the conductor skips the merge for gem
  members — they ride the release as a *record*, and are QA'd indirectly through
  a consuming app (the consumer's branch is what gets merged + tested).
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

This is the ordered `release_train` from §4.2 ("gem publish → consumer lockfile
bump → app deploy"), now expressed as first-class release membership rather than
a separate lane: the gem and its consumers can be members of the same release,
sequenced by kind + `dependencies`.

**Start-fresh / abandon.** Feature branches are the durable artifact; the release
branch is disposable, so abandoning a stuck RC is cheap and `main` never moves.
Order is load-bearing — deleting a PR's base branch first auto-closes it:

1. Cut a new `release/<slug2>` from `main`.
2. **Pending** members (PR still open) → `gh pr edit --base release/<slug2>`.
3. **Already-merged** members → their PR is "merged" into the dead branch but the
   work is safe on its head branch; open a fresh PR from it → `release/<slug2>`.
4. **Delete `release/<slug>` last.** Members drop back to `reviewed` (the e2e
   culprit to `blocked`); re-assemble.

### 1.2 Stage ownership — who progresses each stage

Distinguish the **accountable role** (the soul whose rubric governs the stage)
from the **executor** (who moves it). The heartbeat agent executes by wearing
each lane's hat; accountability maps to a soul; there is exactly **one human
gate**.

**Merge timing (decided):** approved tasks are **not** merged at `reviewed` —
they're merged when the conductor **assembles** the release onto `release/<slug>`,
in dependency order. The release branch is the live RC; `main` only moves when it
ships.

| Stage (entity) | Accountable | Progressed by | Action | Gate |
|---|---|---|---|---|
| **→ submitted** (task, entry) | Feature agent | Feature agent | Pass `bin/dor-check`, record `checks_run`, open PR, move in | self-gate |
| **submitted** (task) | **Avi** (Steffon co-gates risk) | DevOps agent *as Avi* | Review acceptance/diff/tests → `blocked` (back, with `qa_feedback`) **OR** `reviewed` ✅ | judgment (Opus on migration/payment/solana/auth); ⛔ one complete `qa_feedback` on fail |
| **reviewed** ✅ (task, parked) | **Avi** | — (waits) | Approved; eligible for the next release | — |
| **assembling** (release) | **Avi** | DevOps agent *as Avi* / operator-curated | Add `reviewed` tasks honoring `dependencies` + lanes → **merge each onto `release/<slug>`** + per-merge tests; member → `assembled` | judgment + deterministic merge queue |
| **assembled** (release) | **Steffon** (executes) | DevOps agent *as Steffon* | Full suite incl. e2e green on release HEAD → deploy to QA + Discord notes → await the operator action | deterministic suite; ⛔ regression → eject task to `blocked` |
| **→ shipped** (release) | **Mr. McRitchie**, then conductor | Operator **Makes the release**, then DevOps agent | Operator eyeballs QA + Makes the release → ff to `main`, tag, `bin/deploy` → `production_smoke` → notes → members `shipped` | 🔒 **the one human gate**; rollback on smoke fail |

Clarifications:

- **`assembled` means the same at both scopes** — merged + tests check out: a
  *task* is `assembled` once its PR is merged onto the branch and its per-merge
  tests pass; the *release* is `assembled` once every member is in and the full
  suite is green. The operator gate is then a deliberate **Make the release**
  action on the assembled RC, not a status the agent flips.
- **There is no per-task QA stage.** Steffon owns the QA deploy, the
  `qa_acceptance` suite, and the prod mechanics — but there is no separate
  approval ceremony; the suite is a green/red *signal* and the operator OK is the
  gate. QA + production are properties of the **release**, not the task.
- **The agent merges even funds-touching work autonomously** at assembly — the
  consequence of "Review + QA, gate prod". Risk raises *scrutiny* (Opus review +
  full integration/security suite), not a second human. *Knob:* flip
  `payment`/`solana` `risk_tags` to require a human pre-**merge** pass — one
  config line.
- **Humility valve:** low confidence → the agent marks `conductor-review` and
  routes to a *human* Avi/Steffon session instead of assembling/merging.

### 1.3 Decided — and where to tune the release builder

Resolved: `release_train` → **`release_slug`** (one field/model); **merge at
assembly onto a disposable `release/<slug>` branch**; no per-task QA stage;
Release is its own singleton model — states `assembling → assembled → shipped`,
where the operator **Makes the release** (a page action on the assembled RC).

**RC assembly autonomy is the one evolving policy** — so it lives in a single,
clearly-marked, tunable place: `config/release_builder.yml`. Starting policy:

- **Auto-assemble + auto-deploy-to-QA** a release that is a *single* task,
  *single* repo, with **no** `migration`/`payment`/`solana` risk tag.
- **Propose for operator confirmation** any multi-task, cross-repo, or
  risk-tagged release: the agent drafts it, posts the plan to Discord, and waits.
- Production ship is **always** operator-gated (Make the release on the
  `assembled` RC), regardless.

The agent reads this file every heartbeat; changing the thresholds changes
behavior with no code edit. Keys + defaults are documented at the top of the
file and mirrored in `deployment.md` when this lands — that is the one place to
modify the release builder's autonomy.

### 1.4 Kickoff commands — board → Claude session

The `/deployments` board and `/stages` page surface a short copy-paste command
per DevOps stage (source of truth: `ApplicationHelper#devops_kickoffs`). Pasted
into a Claude session run from `/Users/alex/projects`, each kicks off that
stage's workflow. The feature-agent lane (`designed → building → blocked →
submitted`) has none — the operator drives those hands-on. The DevOps lane maps
each command to a deterministic runbook:

**`Review submitted PRs`**  *(submitted → reviewed)*
1. List `submitted` tasks (`bin/task list` or the board).
2. For each open PR run an independent review (the `avi` subagent): acceptance
   criteria, the diff, CI, and the shape's required test tiers.
3. Approve → `bin/task move <task> reviewed`; issues → `bin/task block <task>
   --kind rework --feedback "…"` (one complete send-back).

**`Prepare release`**  *(reviewed → assembled — an RC for QA)*
Run **`bin/release prepare [--task SLUG ...] [--slug rel-…] [--prod]`**. Additive
find-or-create (`Release::Conductor.prepare!`): extends the active release —
reopening an assembled RC so the new work re-QAs (`Release#reopen!`) — or opens a
new one, adds the reviewed task(s) (default: every reviewed task) **in
producer-first order**, then cuts/merges `release/<slug>` and runs the suite,
**stopping for you on a merge conflict** (a genuine conflict means the task
should be blocked for rework). **Gem members are skipped at the merge step** —
they have no app branch in this repo; they ride the release record and are QA'd
through a consuming app, so `prepare` only merges + tests the app members.
Leaves the RC `assembled` and **auto-deploys the branch to QA**
(`bin/qa-server deploy` → `mcritchie-studio-qa`), recording `release.qa_url` for
review before production. Record ops default to the local DB; `--prod` runs them
on the prod board via `heroku run`.

**`Run Deployment`**  *(assembled → shipped — promote the QA'd RC to prod)*
Run **`bin/release ship [--by NAME] --prod`** — the one human gate; it confirms
before deploying. **Producer-first:** before any app deploy, it publishes every
**gem member** to RubyGems in order — for each it prints the gem + target
version and asks `Publish <repo> <version> to RubyGems?` (approval-gated; honors
`--yes` / `--dry-run`), runs the gem's build (studio-engine: `bin/release-check
--build`; otherwise `gem build <gemspec>`), `gem push`es the artifact, and tags
`v<version>` in the gem repo. A build/push failure **aborts the ship** before any
app deploys, so apps never deploy against an unpublished gem. Then for the apps
it ff's `main` → the release branch, pushes origin (closing member PRs), deploys
(`git push heroku main`; release phase runs migrations), smokes `/up`, stamps
`deployed_sha`, flips the RC + its members to `shipped`
(`Release::Conductor.ship!`), and **auto-posts release notes**
(`Release::Conductor.post_release_notes` → the same Formatter/Discord path as
`POST /api/v1/release_notes`; non-fatal if the webhook is unset). Run `ship` from
a **primary checkout** (not a worktree): the gem repos are resolved as siblings
at the projects root.

**`Cleanup worktrees`**  *(post-ship housekeeping)*
`bin/agent-worktree cleanup --reclaim` (then `--yes`) to tear down the merged
feature worktrees. The deployment is done.

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
- required `metadata["devops"]` fields are populated (existing contract);
- a local proof URL exists when the shape touches UI.

This is **deterministic** — a `bin/` gate (`bin/dor-check <task>`, default
`--gate merge`), not a judgment call. There is also a lighter `--gate build`
(spec-complete, no tiers) for the `designed → building` entry. The feature agent
runs it before handoff; the heartbeat agent re-runs `--gate merge` as gate zero
of review. A failed DoR is an *immediate, cheap*
send-back that never consumes review-judgment tokens. This is the structural
fix for the review ping-pong: most "PR not ready" churn becomes a pre-PR
mechanical check.

### 3.4 Test ownership & timing — *who writes what, when*

| Tier | Author | When |
|---|---|---|
| Unit | Feature agent | During build, before first commit |
| Component | Feature agent | Before `submitted` |
| Integration | Feature agent | Before `submitted` (mandatory for any `migration`/`solana`/`payment`/`auth` risk tag) |
| E2E (happy path) | Feature agent | Before `submitted` for ui+db / vertical shapes |
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
  left-shift is working). These surface on `/devops`, not in your daily view —
  you steer by task status, tests are the indicator underneath.

---

## 4. The airgapped heartbeat DevOps agent

Runs on the OpenClaw box every ~10 minutes. Builds directly on the
`devops-cycle`/`qa-intake` toolchain and the "Future Heartbeats" lease spec.

### 4.1 One heartbeat = evaluate every in-flight task, advance each ONE safe step

```
# Workflow 1 — per task (review).  Each submitted task, one safe step.
for each task in {submitted}:
  acquire lease (claimed_by, claim_expires_at)   # resilience: reclaimable
  1. bin/dor-check --gate merge (deterministic gate-zero)       — fail ⇒ block(rework) + qa_feedback, release
  2. run pr_review_gate suite   (deterministic)                 — fail ⇒ classify, block(rework), release
  3. diff-vs-acceptance review  (judgment; model by risk)       — changes ⇒ ONE complete qa_feedback + block
  4. else → reviewed ✅                                          — Discord: approved

# Workflow 2 — the ONE active release (singleton).
release.assembling:
  pick next reviewed member honoring dependencies + lanes (§4.2)
  retarget PR → release/<slug>, merge, run member's tiers       — conflict/red ⇒ eject task to blocked
  member → assembled; when all members in + full e2e green:
  deploy release branch → QA + Discord notes → release.assembled
release.assembled:
  if operator_made_the_release: ff → main, tag, bin/deploy → production_smoke → notes → members shipped  # ONLY here
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

- **Migrations:** two tasks touching `db/schema.rb` or migrations → serialize
  via the existing `backend_migration` advisory lock; second one holds with a
  note.
- **studio-engine + consumers:** gem publish → consumer lockfile bump → app
  deploy is one ordered `release_train` (existing lane); the agent promotes the
  train in order, never a consumer ahead of its gem.
- **turf-vault program:** **new rule** — at most one in-flight task may change
  the Anchor program (same advisory-lock pattern as migrations). A vault change
  and its turf-monster IDL re-pin form a `release_train` deployed *in order*
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
- **The two-workflow status model** (this task): Task stages + state machine,
  `bin/task` / `bin/dor-check` / board, the data migration, `blocked` metadata
  (`blocked_from` + `block_kind`), and the DoR-to-Build / DoR-to-Merge gates.

**Next**

1. `Release` singleton model + `release_slug` / `dependencies` on Task + the
   board's "current release" header.
2. Release-branch assembly + abandon tooling — the merge queue (retarget → merge
   → per-merge tests → eject), ff-to-`main` + tag on ship, and the abandon
   protocol (§1.1).
3. Migrate the heartbeat planner `bin/devops-cycle` (+ its snapshot fixture +
   `bin/devops-tests` lane names) from the legacy stage names to the new ones.
4. Pyramid re-tag of suites in `config/devops_test_suites.yml`.
5. Discord progress/event templates + `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`.
6. The heartbeat agent script for the OpenClaw box (review→QA first; ship gate as
   a no-op approval check).
7. turf-vault single-writer advisory lane.

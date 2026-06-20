# DevOps Cycle — Design (v1, for review)

> **Status:** design draft for Mr. McRitchie's 1000ft review. Nothing here is
> canon yet. Once approved, this folds into the existing modules
> (`parallel-agent-devops.md`, `testing.md`, `devops-task-board.md`) via
> surgical edits, and the supporting code lands as its own tasks. This file is
> the *connective design*; it references the existing modules instead of
> restating them.
>
> Visual companion: the in-app DevOps cycle viewer at `/devops/cycle`
> (admin-gated; `DevopsController#cycle`, view at
> `app/views/devops/cycle.html.erb`). Built for visual review of this design.

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
| Task state machine `new→queued→in_progress→pr_review→qa_review→prod_ready→done` (+`failed`/`archived`) | `Task` model, `devops-task-board.md` | The spine. Everything routes through the task. |
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

The flow is **two workflows**, matching how Avi actually works. Reviewing a
*task* and shipping a *release* are different jobs at different cadences.

- **Workflow A — PR review (per task).** A feature task is judged on its own
  merits: acceptance, diff, tests. Outcome is binary — send it back with
  `qa_feedback`, or stamp **`release_ready` ✅** ("ready for the big leagues").
- **Workflow B — release preparation (per release).** Avi *strategically*
  assembles `release_ready` tasks into a **release candidate (RC)**, honoring
  `dependencies`, cuts it to QA as a quick stop-gap, and on Mr. McRitchie's OK
  ships it to production.

QA and production are properties of the **release**, not the individual task —
so the old per-task `qa_review` and `prod_ready` **collapse together** into a
single release-level QA stop that waits for one operator OK.

```
WORKFLOW A · per task                         WORKFLOW B · per release (its own Release model)
in_progress → pr_review → release_ready ✅ ─┐   assembling → qa → confirmed ✅ → shipped
                 ▲                           │     (Avi adds    (deploy +   (operator   (prod + smoke +
                 └ qa_feedback (send back)   └─►   ready tasks) auto-accept) confirms)   notes; members → done)
```

The RC is a **flat `kind:release` task** (no parent/child trees — consistent
with "flat tasks first"). Member tasks share its `release` string; it carries
them through QA→prod and flips them to `done` when it ships. The airgapped agent
runs both workflows but **never crosses the ship gate autonomously** — the
operator's single OK on the RC at QA is the one human gate. The task API is on
production, so the airgapped box only needs an internet connection — no separate
pull/sync layer.

### 1.1 The Release model + task links

**Release** (new model) coordinates a candidate from assembly through ship.
*Rename/consolidation (decided):* the existing `release_train` field and lane
become **`release`** — one concept, one name.

| Field | Meaning |
|---|---|
| `slug` | Canonical id, e.g. `2026-06-20-s3-uploads` (supersedes the `release_train` string). |
| `state` | `assembling` → `qa` → `confirmed` ✅ → `shipped` (+ `failed`). |
| `confirmed_at` / `confirmed_by` | The operator **Confirm ✅** — the one human gate. |
| `qa_url` / `production_url` / `deployed_sha` / `release_notes_sent_at` | Deploy + notes record. |
| has_many `tasks` | via `tasks.release_slug`. |

**Task** gains two links (and drops the old `release_train` string):

| Field | Meaning |
|---|---|
| `release_slug` | FK to the Release this task rides (null until Avi assigns it at assembly). |
| `dependencies` | Array of task slugs this one needs shipped first; lets Avi sequence releases (engine-only release first, then dependents). |

`dependencies` (task→task) and the exclusive **lanes** (resource-level:
migration, release, vault single-writer) compose: dependencies say *"B needs A's
output"*; lanes say *"only one of these at a time."*

### 1.2 Stage ownership — who progresses each stage

Distinguish the **accountable role** (the soul whose rubric governs the stage)
from the **executor** (who moves it). The heartbeat agent executes by wearing
each lane's hat; accountability maps to a soul; there is exactly **one human
gate**.

**Merge timing (decided):** branches are **not** merged at `release_ready` —
they're merged when Avi **assembles** the release, in dependency order, so `main`
is always exactly the current release candidate and **QA mirrors `main`**.

| Stage (entity) | Accountable | Progressed by | Action | Gate |
|---|---|---|---|---|
| **→ pr_review** (task, entry) | Feature agent | Feature agent | Pass `bin/dor-check`, record `checks_run`, move in | self-gate |
| **pr_review** (task) | **Avi** (Steffon co-gates risk) | DevOps agent *as Avi* | Review acceptance/diff/tests → `qa_feedback` (back) **OR** stamp `release_ready` ✅ (approved + pushed, **not** merged) | judgment (Opus on migration/payment/solana/auth); ⛔ one complete `qa_feedback` on fail |
| **release_ready** ✅ (task, parked) | **Avi** | — (waits) | Eligible queue for Workflow B | — |
| **assembling** (release) | **Avi** | DevOps agent *as Avi* (strategic) / operator-curated | Add `release_ready` tasks honoring `dependencies` + lanes → **merge them to `main` in order** → deploy `main` to QA | judgment + deterministic merge |
| **qa** (release) | **Steffon** (executes) | DevOps agent *as Steffon* | Run `qa_acceptance` as a signal → await Confirm | deterministic suite; ⛔ regression → kick offending task back to `qa_feedback` |
| **confirmed** ✅ (release) | **Mr. McRitchie** | Operator clicks **Confirm ✅** | Eyeball QA URL + confirm | 🔒 **the one human gate** |
| **shipped** (release) | Release conductor | DevOps agent executes | `bin/deploy` → `production_smoke` → release notes → member tasks `done` | rollback on smoke fail |

Clarifications:

- **Two checkmarks, same shape:** task `release_ready` ✅ (Avi confirms a task is
  ready) and release `confirmed` ✅ (operator confirms a QA'd release is good to
  ship).
- **QA review is dropped as a stage.** Steffon owns the QA deploy, the
  `qa_acceptance` suite, and the prod deploy mechanics — but there is no separate
  Steffon approval ceremony; the suite is a green/red *signal* and your Confirm
  ✅ is the gate. Per-task `qa_review`/`prod_ready` are retired.
- **The agent merges even funds-touching work autonomously** at assembly — the
  consequence of "Review + QA, gate prod". Risk raises *scrutiny* (Opus review +
  full integration/security suite), not a second human. *Knob:* flip
  `payment`/`solana` `risk_tags` to require a human pre-**merge** pass — one
  config line.
- **Humility valve:** low confidence → the agent marks `conductor-review` and
  routes to a *human* Avi/Steffon session instead of assembling/merging.

### 1.3 Decided — and where to tune the release builder

Resolved: `release_train` → **`release`** (one field/model); **merge at
assembly** (QA mirrors `main`); per-task `qa_review`/`prod_ready` **retired**;
Release is its own model with an operator **Confirm ✅**.

**RC assembly autonomy is the one evolving policy** — so it lives in a single,
clearly-marked, tunable place: `config/release_builder.yml`. Starting policy:

- **Auto-assemble + auto-deploy-to-QA** a release that is a *single* task,
  *single* repo, with **no** `migration`/`payment`/`solana` risk tag.
- **Propose for operator confirmation** any multi-task, cross-repo, or
  risk-tagged release: the agent drafts it, posts the plan to Discord, and waits.
- Production ship is **always** operator-gated (the Confirm ✅), regardless.

The agent reads this file every heartbeat; changing the thresholds changes
behavior with no code edit. Keys + defaults are documented at the top of the
file and mirrored in `deployment.md` when this lands — that is the one place to
modify the release builder's autonomy.

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
5. Self-run the **Definition of Ready (DoR)** check before `pr_review` (§3.3).
6. Record `checks_run`, hand off with a `handoff` note, move to `pr_review`.

### Bug SOP

1. Classify **severity**: `hotfix` (production broken / funds at risk) vs `normal`.
2. **Write a failing regression test that reproduces the bug *first*** — at the
   lowest tier that can express it (a bug fixable by a unit test must get a unit
   test, not an E2E). The red test is the acceptance criterion.
3. Fix until the regression test is green; run the shape's contract for the
   touched surface.
4. `hotfix` may skip `queued` and use an expedited review, but **never** skips
   the regression test or the `prod_ready` human gate.

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
| **Manual** | Operator visual/UX acceptance | **the `qa_review` step itself** | — | — | contract transparency / `/contract` review |

Tiers are the **what**; the existing **test lanes** are the **when/where**.
Mapping: Unit+Component+Integration → `pr_review_gate`/`local_proof` (block
merge); E2E happy-path → `local_proof`, full E2E → `nightly_deep`; Manual →
`qa_acceptance`; post-deploy → `production_smoke`.

### 3.2 Shape → test contract (the adaptation)

A feature's **shape** is recorded in `devops` (new optional field `shape`, or
inferred from `risk_tags`). It selects the minimum tiers that must be green
before `pr_review`:

| Shape | Example | Required tiers (DoR contract) |
|---|---|---|
| **ui-only** | "make the button blue" | Component (rendered partial / Alpine) + Manual at QA. Unit only if it adds logic. |
| **ui+db** | new form that persists | Unit (model/validation) + Component (request+view) + Integration (request→DB) + E2E happy path |
| **backend** | new job/service | Unit (service/PORO) + Integration (job + mocked I/O) |
| **library** | studio-engine change | Unit in engine + **consumer-CI** (component/integration in *both* apps) |
| **onchain** | new turf-vault instruction | Anchor unit + Anchor integration (lifecycle) + Ruby decoder unit + devnet E2E (nightly) |
| **onchain-vertical** | new workflow w/ wallet + DB + UI + program | all tiers + devnet E2E; almost always a `release_train` |

The matrix is the single source of "how much testing is enough" — it removes
the per-task judgment call that currently lets thin PRs through.

### 3.3 Definition of Ready for review (DoR) — the enforcement

A task **may not enter `pr_review`** unless, for its shape:

- every required tier is present and green, recorded in `checks_run`;
- required `metadata["devops"]` fields are populated (existing contract);
- a local proof URL exists when the shape touches UI.

This is **deterministic** — a `bin/` gate (`bin/dor-check <task>`), not a
judgment call. The feature agent runs it before handoff; the heartbeat agent
re-runs it as gate zero of review. A failed DoR is an *immediate, cheap*
send-back that never consumes review-judgment tokens. This is the structural
fix for the review ping-pong: most "PR not ready" churn becomes a pre-PR
mechanical check.

### 3.4 Test ownership & timing — *who writes what, when*

| Tier | Author | When |
|---|---|---|
| Unit | Feature agent | During build, before first commit |
| Component | Feature agent | Before `pr_review` |
| Integration | Feature agent | Before `pr_review` (mandatory for any `migration`/`solana`/`payment`/`auth` risk tag) |
| E2E (happy path) | Feature agent | Before `pr_review` for ui+db / vertical shapes |
| E2E (edge/regression) | QA lane (Avi/Steffon) | May add during review; becomes a follow-up task if large |
| Manual | **Mr. McRitchie** | At `qa_review` (this *is* the manual tier) |

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
for each task in {pr_review, qa_review, prod_ready}:
  acquire lease (claimed_by, claim_expires_at)   # resilience: reclaimable
  case stage:
    pr_review:
      1. bin/dor-check            (deterministic gate-zero)        — fail ⇒ qa_feedback, release
      2. run pr_review_gate suite (deterministic)                  — fail ⇒ classify, qa_feedback, release
      3. conflict check (§4.2)    (deterministic)                  — conflict ⇒ hold + note, release
      4. diff-vs-acceptance review(judgment; model by risk)        — changes ⇒ ONE complete qa_feedback
      5. merge + bin/qa-server deploy + → qa_review                — Discord: advanced
    qa_review:
      run qa_acceptance suite      (deterministic + light judgment) — green ⇒ prod_ready + Discord "awaiting approval"
    prod_ready:
      if task.approved_by_operator: bin/deploy → release_notes → done   # ONLY here
      else: no-op (HARD STOP)
  update last_heartbeat_at, current_command, blocked_reason
  emit progress
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
docs/agents/system/devops-cycle.md:
- Handling a FEATURE → § Feature SOP. Classify the feature SHAPE and load its
  test contract before writing code.
- Handling a BUG → § Bug SOP. Write the failing regression test first.
- Running the airgapped/QA cycle → § Heartbeat agent. One safe step per task;
  never cross prod_ready without operator approval.
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
2. **Hotfix lane** — do you want an expedited `hotfix` severity that skips
   `queued` and shortens review, still regression-tested + prod-gated? (Recommend yes.)
3. **turf-vault single-writer lane** — confirm only one in-flight program change
   at a time is acceptable (it serializes blockchain work). (Recommend yes; it's
   the safe default given Squads + IDL pinning.)
4. **Progress webhook** — separate `DISCORD_DEVOPS_PROGRESS_WEBHOOK_URL`, or
   reuse the release channel? (Recommend separate.)
5. **Heartbeat read path** — the airgapped box reads the production task board
   over the existing bearer-token API; confirm that network path is allowed from
   the OpenClaw environment (the one external dependency the airgap must permit).

## Implementation order (after you react — each its own task)

1. `bin/dor-check` + the `shape`→contract matrix in `config/` (the left-shift lever; biggest ROI).
2. Pyramid re-tag of existing suites in `config/devops_test_suites.yml` (+ split turf-vault's monolith, mark tiers).
3. `AGENTS.md` routing block + fold SOPs into the existing modules.
4. `TaskRun`/lease fields (the "Future Heartbeats" migration) — `backend_migration` lane.
5. Discord progress/event templates + webhook.
6. The heartbeat agent script for the OpenClaw box (review→QA only first; prod gate as a no-op approval check).
7. turf-vault single-writer advisory lane.

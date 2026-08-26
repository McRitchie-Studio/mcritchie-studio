# Heartbeats — the four soul launchers

The standalone **Heartbeats card** on `/deployments` (`tasks/_heartbeats_card`,
sized to match the Next Release card) renders four **soul-avatar heartbeat
launchers** (`ApplicationHelper#heartbeat_launchers`, one `tasks/_heartbeat_launcher`
per soul). Each launcher is a soul face — **a link to that soul's `/agents/<slug>`
page** — over a **prompt-like row 1** plus one or more **copyable action rows**,
each carrying a leading icon (a ❤️ on the heartbeat row; a `1️⃣`–`4️⃣` keycap on the
four ordered release actions, a themed glyph on the rest):

- **Row 1 — the prompt-like soul heartbeat** (❤️): `Carl Heartbeat` · `Avi
  Heartbeat` · `Steffon Heartbeat` · `Alex Heartbeat`. One per soul.
- **The action rows** — one copyable row each, ordered along the pipeline (the
  number icons read across the souls: review → assemble → ship → archive):
  - **Carl** → `1️⃣ pr-review` · `🐢 pr-review-slow`
  - **Avi** → `2️⃣ qa-release` · `⚡ deploy-with-task`
    (Avi also owns `live-score-watch`, direct-invoke only — deliberately NOT on
    this list, which mirrors the launcher card in
    `ApplicationHelper#heartbeat_launchers`.)
  - **Steffon** → `3️⃣ production-deploy` · `4️⃣ archive-shipped`
  - **Alex** → `🧑🏻‍🏫 grade-events` · `📡 share-insights` · `🌎 full-cycle`

**Every row is independently copyable** (the row-1 heartbeat prompt and each act),
and **any of them**, pasted into a fresh agent session run from
`/Users/alex/projects`, launches that heartbeat. All rows are **recognized
launchers** — listed in the generated root `AGENTS.md` SOP Invocation Standard
registry and in
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md). Each act wraps
a single release **atom** (see §1.4's atom table), except `alex` /
`grade-events`, which is the learning loop and lives outside the release
pipeline.

Each soul's action-level procedure lives with that soul:
[`Carl`](../agents/carl/HEARTBEAT.md),
[`Avi`](../agents/avi/HEARTBEAT.md),
[`Steffon`](../agents/steffon/HEARTBEAT.md), and
[`Alex`](../agents/alex/HEARTBEAT.md). This page is the cross-soul map.

| Soul (avatar → `/agents/<slug>`) | Row 1 prompt | Acts | Enters at | Exit seam |
|---|---|---|---|---|
| **Carl** (`carl`) | `Carl Heartbeat` | `pr-review`, `pr-review-slow` | submitted PRs waiting for review | each PR `reviewed` (merged into `accepted`) or `blocked` |
| **Avi** (`avi`) | `Avi Heartbeat` | `qa-release`, `deploy-with-task` (direct-invoke only) | `reviewed` work + `assembled` stragglers to sweep | the RC swept, **live on QA, members `assembled` on QA-green** |
| **Steffon** (`steffon`) | `Steffon Heartbeat` | `production-deploy`, `archive-shipped` | a QA-green (`assembled`) release ready to ship / shipped work to archive | the ready release `shipped` (or no-op); then prior cycle `archived` |
| **Alex** (`alex`) | `Alex Heartbeat` | `grade-events`, `share-insights`, `full-cycle` | activities to grade / confirmed insights to share / a full pipeline to run | 10 graded + banked; confirmed insights shared out; or the whole release `shipped` |

> **Direct-drive the mutating acts.** `qa-release`, `production-deploy`, and
> `archive-shipped` MUTATE shared state across many minutes, so the heartbeat
> session runs them ITSELF — never via an ephemeral Agent-tool subagent, which can
> detach and leave the mutation half-applied with no terminal to finish it (this is
> how a partial release candidate once sat unnoticed). Subagents stay first-class
> for **read** fan-out: `pr-review` spins **one Carl per PR** (each summoning his
> own light) as subagents, because a detached review costs only a retry. The line
> is *mutating vs reading*, not *parallel vs serial*. Recovery for an interrupted
> mutation is to RE-RUN it — the conductor's commands are self-healing. Details:
> [`parallel-agent-devops.md`](parallel-agent-devops.md).

> **Sticky attribution — the FIRST action of a `<Soul> Heartbeat`.** Run
> `bin/agent-activity heartbeat <soul>` (e.g. `bin/agent-activity heartbeat carl`) so
> EVERY activity self-attributes to that soul — stacked over the stable base session
> mascot — without re-passing `--agent` on each `start`/`next`. An explicit
> `--agent` on an activity still WINS over the sticky (a delegated reviewer keeps its
> own soul). It clears on `bin/agent-activity heartbeat --clear` or at session end
> (`close-open`). This is why the heartbeat's own orient/workflow activities show the
> soul instead of falling back to the base mascot.
>
> **Lanes re-homed (2026-07-22).** Review moved to **Carl** (one Carl per PR — the
> standing primary + owner, no Avi supervisor), and the release lanes flipped: **Avi**
> now owns the `qa-release` sweep + QA (stages 1–3), **Steffon** now owns
> `production-deploy` (stages 4–5) + `archive-shipped`. They surface on the
> standalone /deployments **Heartbeats** card (four souls, sized to the Next Release
> card); the 5-stage release tracker stays in the **Next Release** card.

## Launching a heartbeat in a fresh session — the quick start

Every heartbeat starts the same way in a **fresh agent session** (Claude or
Codex) run from `/Users/alex/projects`. This is the whole boot sequence — a new
session needs nothing else:

1. **Say a launcher row.** Paste the row-1 prompt (`Carl Heartbeat` · `Avi
   Heartbeat` · `Steffon Heartbeat` · `Alex Heartbeat`) or any single act row from
   the /deployments Heartbeats card. The generated root `AGENTS.md` maps those
   launcher phrases directly to this module, the owning soul's `HEARTBEAT.md`, and
   the relevant SOP file. No installed skill is required.
2. **Stamp attribution FIRST** — before any other tool call:
   `cd /Users/alex/projects/mcritchie-studio && bin/agent-activity heartbeat
   <carl|avi|steffon|alex>`.
3. **Run the soul's acts** from the mcritchie-studio primary
   checkout (the board is **prod** by default; pass `--yes` on the release verbs
   the act owns). The full per-soul heartbeat launchers are
   [`Carl`](../agents/carl/HEARTBEAT.md),
   [`Avi`](../agents/avi/HEARTBEAT.md),
   [`Steffon`](../agents/steffon/HEARTBEAT.md), and
   [`Alex`](../agents/alex/HEARTBEAT.md); the numbered sections below summarize
   them.

The per-soul cheat sheet — say the row-1 prompt, then drive these commands:

| Soul | Acts | Commands each act drives |
|---|---|---|
| **Carl** | `pr-review` → `pr-review-slow` | per `submitted` PR (waves ≤5): `bin/task claim-next-review` → spin one Carl → the [review-one primitive](pr-review-sop.md) → on a merge-ready verdict `gh pr merge` into `accepted` + `bin/task move <task> reviewed` |
| **Avi** | `qa-release` | `bin/release prepare --yes` → smoke `https://qa.mcritchie.studio/up` (stages 1–3, members `assembled` on QA-green) |
| **Steffon** | `production-deploy` → `archive-shipped` | `bin/release status` → **if** QA-green: `bin/release ship --yes` (stages 4–5); then `bin/release archive --yes` (preview `--dry-run`) |
| **Alex** | `grade-events` · `share-insights` · `full-cycle` | `bin/agent-activity awaiting --limit 10` → `bin/agent-activity grade <id> …` → `--bank`/`--discard`; `bin/rails insights:doc` + `bin/install-agent-docs`; `full-cycle` = `pr-review` → `qa-release` → `production-deploy` (ship authority) |

> **Script-assisted review.** `bin/pr-review` is a codex-based review loop that
> composes `bin/devops-cycle`, `bin/reviewer-select`, and codex reviewer
> sub-processes (running `carl/sops/pr-review-{primary,light}.md`), writes the
> `bin/task move|block|note` handoffs itself, and prints a retrospective. It is
> **review-only** — approved tasks stop at `reviewed` (merged into `accepted`);
> Avi's `qa-release` sweep owns the `accepted → release` promotion. It predates
> the native-Claude "one Carl per PR" model (`carl/sops/pr-review.md`, the
> canonical interactive path) and hasn't been ported yet. The working invocation:
>
> ```bash
> bin/pr-review --run --limit <N> --max-idle-cycles 1 \
>   --codex-workdir /Users/alex/projects/mcritchie-studio
> ```
>
> - **`--codex-workdir` must be a trusted git checkout** — the projects-root
>   default is not a git repo, so `codex exec` refuses and every reviewer exits 1.
> - **`--max-idle-cycles 1`** exits once the queue drains; the default (240
>   polls × 60 s idle-sleep) keeps the loop alive ~4 h waiting for new PRs.
> - Dry-run is the default — only `--run` launches reviewers and writes tasks.
>   `--fast` reviews in bounded waves; slow (one PR at a time) is the default.

## The release handoff seam — Avi owns stages 1–3, Steffon owns 4–5

The current-release stages (`Release::STAGES`, rendered on /deployments as the
per-repo lanes tracker, `ApplicationHelper#release_repo_lanes`) are five:

| # | Stage key | Active → complete label | Owner | Driven by |
|---|---|---|---|---|
| 1 | `testing` | **Testing → Tested** | Avi | `bin/release prepare` |
| 2 | `assembling` | **Assembling → Assembled** | Avi | `bin/release prepare` |
| 3 | `qa_deploying` | **Deploying QA → Live on QA** | Avi | `bin/release prepare` |
| 4 | `confirming` | **Confirming → Confirmed** | Steffon | `bin/release ship` |
| 5 | `production_deploying` | **Deploying → Deployed** | Steffon | `bin/release ship` |

**The souls split the pipeline (2026-07-22): Carl reviews; Avi assembles + QAs;
Steffon ships.** Avi owns stages 1–3 (Testing → Assembling → Deploying QA) via
`qa-release` (`bin/release prepare`) — which owns the **`accepted → release`
merge**: it SWEEPS the reviewed queue onto the candidate, merges each into
`release`, and flips members `reviewed → assembled` only on **QA-green** — and
stops at **Live on QA**. **Steffon owns stages 4–5** (Confirming → Deploying) via
`production-deploy` (`bin/release ship`) and finishes at **Deployed**. The seam
between them — **"deployed to QA."** — is the **Avi → Steffon handoff**:
Avi's `qa-release` ends there and reports it; Steffon's `production-deploy` begins
only once it is true.

**The `merged` column is the crash-recovery spine.** Orthogonal to `stage`, it
records WHERE the task's code physically is, so an interrupted heartbeat
contextualizes itself from durable state instead of guessing:

| `stage` + `merged` | Means |
|---|---|
| `reviewed` + `accepted` | Carl merged the feat PR onto `accepted`, not swept yet |
| `reviewed` + `release` | swept — PR merged onto `release`, QA in flight |
| `assembled` + `release` | QA-green, waiting on Steffon |
| `assembled` + `main` | ff'd `release → main`, prod deploy in flight |
| `shipped` + `main` | done |

An interrupted Avi run **skips re-merging** a `merged: release` task; an
interrupted Steffon run **skips re-ff'ing** a `merged: main` one (the git ffs no-op
anyway — the stamp is the readable signal).

## Operator-launched today, schedule-ready tomorrow  *(DESIGN NOTE — load-bearing)*

These acts are **operator-launched** (copy-paste from the card) today. Each act's
SOP below is deliberately written so it can be **run on a schedule/cadence later
without rework**. Three properties make that safe, and every act must keep all
three:

1. **Idempotent** — re-running when there is nothing to do is a safe no-op that
   reports "nothing waiting" and exits. `pr-review` on an empty queue,
   `qa-release` with nothing reviewed, no stragglers, and no RC in flight,
   `production-deploy` on a `release == main` (or no QA-green release), and
   `archive-shipped` with nothing shipped must each just report and stop —
   never fabricate work.
2. **Explicit precondition** — each states what must already be true to begin (the
   "Enters at" column above). A scheduler checks the precondition, and skips
   cleanly when it is not met.
3. **Named exit seam** — each ends at a definite stage/state plus a report (the
   "Exit seam" column). A scheduler reads the seam and can chain the next act
   (`pr-review` → `qa-release` → `production-deploy` → `archive-shipped`) or bank
   the result (`grade-events`).

No heartbeat assumes a human is watching mid-run: no interactive prompts (pass
`--yes` on the `bin/release` verbs an agent shell owns), bounded blast radius, and
a self-contained report at each seam. Moving these to a cron/queue trigger later is
a wiring change, not a rewrite.

---

## 1. Carl Heartbeat — `Carl Heartbeat` / `pr-review` / `pr-review-slow`

Canonical heartbeat launcher:
[`../agents/carl/HEARTBEAT.md`](../agents/carl/HEARTBEAT.md). The summary below
keeps the cross-soul page readable; Carl's standalone act SOPs win for review
mechanics:
[`pr-review`](../agents/carl/sops/pr-review.md), and
[`pr-review-slow`](../agents/carl/sops/pr-review-slow.md).

**Enter as Carl** (the Lead Architect). Review every waiting PR. The review
session (a Pokémon orchestrator) spins **one Carl per PR** — the standing primary
AND owner; there is no Avi supervisor. On a merge-ready verdict Carl merges the
feat PR into `accepted` and stops at `reviewed` — the `accepted → release`
promotion is Avi's `qa-release` sweep.

### Act 1 — `pr-review`

Canonical SOP:
[`../agents/carl/sops/pr-review.md`](../agents/carl/sops/pr-review.md).

Review every waiting PR. **Review-only:** approved work stops at `reviewed` (merged
onto `accepted`) — the `accepted → release` promotion belongs to Avi's self-healing
`qa-release`, which sweeps the reviewed queue promptly.

- **Precondition:** at least one `submitted` PR with green CI. Empty / no green-CI
  queue → report "no reviewable PRs" and stop (idempotent no-op).
- **Steps:**
  1. `bin/task claim-next-review` → the highest-ranked reviewable **green-CI** PR,
     claimed atomically (red / pending / conflicted are never popped).
  2. For each PR, in **waves of ≤5** (the board DB connection cap; a Carl + his
     light count as two), spin **one Carl** — the [review-one primitive](pr-review-sop.md).
     Carl runs [`pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md),
     owns the gates, and summons **one** domain LIGHT (his own child) who runs
     [`pr-review-light.md`](../agents/carl/sops/pr-review-light.md); each reviewer
     narrates **as its soul** (`--agent`). Carl drives the verdict — there is no
     supervisor.
  3. **Merge-ready** → Carl revalidates the head, `gh pr merge` the feat PR into
     `accepted`, `bin/task merged <task> accepted`, then `bin/task move <task>
     reviewed` (merge → stamp → move; the task is `reviewed` iff its code is on
     `accepted`).
  4. **Problems** → `bin/task block <task> --kind rework --feedback "…"` (one
     block never halts the batch). It runs the **two-bounce circuit breaker**
     first and REFUSES a repeat send-back (exit 10), naming the `dependency`
     escalation to run instead — a review deadlock is Mr. McRitchie's call. Read
     it standalone with `bin/task bounces <task>`; a MECHANICAL bounce (red CI,
     merge conflict) proceeds on `--breaker-ack "<reason>"`.
- **Exit seam:** every `submitted` PR is resolved — `reviewed` (merged into
  `accepted`, awaiting Avi's sweep) or `blocked`. Report per-PR.

### Act 2 — `pr-review-slow`

Canonical SOP:
[`../agents/carl/sops/pr-review-slow.md`](../agents/carl/sops/pr-review-slow.md).

The same as `pr-review`, but **serialized** — one PR at a time.

- **Precondition:** at least one reviewable `submitted` PR. Empty queue → report + stop.
- **Steps:** the `pr-review` loop with **`--max-agents 1`** — review one PR
  (one Carl → on a merge-ready verdict merge into `accepted` + `bin/task move
  <task> reviewed`), then **re-query the board** before choosing the next. Use it
  for a steady trickle or when parallel review waves would thrash the board DB.
- **Exit seam:** every `submitted` PR resolved — `reviewed` or `blocked`.

## 2. Avi Heartbeat — `Avi Heartbeat` / `qa-release`

Canonical heartbeat launcher:
[`../agents/avi/HEARTBEAT.md`](../agents/avi/HEARTBEAT.md). The summary below
keeps the cross-soul page readable; Avi's own heartbeat doc wins for mechanics.

**Enter as Avi** (the Product Owner). The self-healing sweep + QA. The detailed
act SOP lives with Avi: [`qa-release`](../agents/avi/sops/qa-release.md) sweeps
reviewed work through the `accepted → release` merge, QA, and the QA-green flip.
Avi owns release **stages 1–3** (Testing → Assembling → Deploying QA), including
the merge. [`deploy-with-task`](../agents/avi/sops/deploy-with-task.md) is a
direct-invoke single-task production expedite, never part of the heartbeat
composition.

### Act 1 — `qa-release`

Canonical SOP:
[`../agents/avi/sops/qa-release.md`](../agents/avi/sops/qa-release.md).

Run the self-healing `bin/release prepare --yes` sweep: reviewed work plus
stragglers onto `release`, pre-QA gate, QA deploy, and members `assembled` only
on QA-green. `qa-deploy` is the legacy alias.

- **Precondition:** `reviewed` work and/or an `assembled` straggler off the current
  RC. Nothing reviewed, no stragglers, no RC in flight → report + stop (idempotent no-op).
- **Exit seam:** the RC is **live on QA**, members `assembled` on QA-green — the
  Avi → Steffon handoff. Report the release slug + QA URL.

## 3. Steffon Heartbeat — `Steffon Heartbeat` / `production-deploy` / `archive-shipped`

Canonical heartbeat launcher:
[`../agents/steffon/HEARTBEAT.md`](../agents/steffon/HEARTBEAT.md). The summary
below keeps the cross-soul page readable; Steffon's own heartbeat doc wins for
Steffon mechanics:
[`production-deploy`](../agents/steffon/sops/production-deploy.md) and
[`archive-shipped`](../agents/steffon/sops/archive-shipped.md).

**Enter as Steffon** (the Platform Engineer). Two acts, run **downstream-first**:
ship a QA-green release if one is ready, then archive the prior cycle. Steffon owns
release **stages 4–5** (post-QA → prod) plus the archive.

### Act 1 — `production-deploy`

Canonical SOP:
[`../agents/steffon/sops/production-deploy.md`](../agents/steffon/sops/production-deploy.md).

Ship the assembled, QA-green release to production.

- **Precondition:** a release is **ready** — i.e. Avi has taken it through
  `qa-release` and it is **`assembled` + deployed to QA (QA-green)** (members read
  `assembled` + `merged: release`). If nothing is ready to ship (`release ==
  main`, or no QA-green release) → report "nothing to ship" and continue to
  `archive-shipped` (idempotent no-op).
- **Steps:**
  1. Clean the primary checkouts (stash the delete-later ledger if needed) — ship
     from a **primary checkout**, not a worktree (gems resolve as siblings).
  2. Run the **full e2e on the FROZEN ship SHA**, then `bin/release ship --yes` —
     drive **stages 4–5** (Confirming → Deploying): fast-forward each repo's
     `release → main` (stamping that repo's members `merged: "main"` as each ff
     lands — the interrupted-run skip signal) and deploy production.
  3. Prod-smoke, green seal, and post release notes (`ship!` flips members
     `shipped`, `merged` stays `main`).
  4. Restore the primary checkouts.
  5. Post-ship agent-docs sync — ship auto-runs the hub primary's
     `bin/install-agent-docs` (non-fatal, never aborts a completed ship), so the
     installed docs (`~/.claude` + `~/.codex` skills, the projects-root
     `AGENTS.md`/`CLAUDE.md`) match what just shipped. **Steffon owns this step
     and its mechanism** (the `Run Deployment` building block in
     [`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md)); if it
     warns, run the installer from the hub primary by hand.
- **Exit seam:** `shipped` (stage 5 **Deployed**). Report the prod SHA + release
  slug. An interrupted run re-runs safely: published gems skip, ffs no-op
  (`merged: main` members are already over), re-pins are idempotent.

> ⚠️ **Ship authority.** This crosses the production gate. Run it only when the
> operator launched it (the `Steffon Heartbeat` / `production-deploy` chip / phrase) or
> otherwise granted ship authority in-session. The `--yes` answers only the human
> confirm; it never skips the preflight, frozen-SHA tests, gem publish, deploy
> smoke, or partial-ship recovery. (A dirty primary does NOT block it: the deploy
> runs from its own `.worktrees/_ship` checkout at the frozen SHA.)

### Act 2 — `archive-shipped`

Canonical SOP:
[`../agents/steffon/sops/archive-shipped.md`](../agents/steffon/sops/archive-shipped.md).

Archive shipped work and reclaim completed worktrees. `archive-completed` is the
legacy alias.

## 4. Alex Heartbeat — `Alex Heartbeat` / `grade-events` / `share-insights` / `full-cycle`

Canonical heartbeat launcher:
[`../agents/alex/HEARTBEAT.md`](../agents/alex/HEARTBEAT.md). The summary below
keeps the cross-soul page readable; Alex's standalone act SOPs win for Alex
mechanics:
[`grade-events`](../agents/alex/sops/grade-events.md),
[`share-insights`](../agents/alex/sops/share-insights.md), and
[`full-cycle`](../agents/alex/sops/full-cycle.md).

**Enter as Alex** (the Lead Orchestrator). Three acts: grade recent trajectory
activities for the learning layer, share the CONFIRMED insights out to every agent, and
— with ship authority — run the whole DevOps cycle end to end. The distillation
pipeline at [`/alex/pipeline`](https://mcritchie.studio/alex/pipeline) is the
operator view of the first two: Activities → Insights (Alex grades) →
Confirmations (McRitchie's `mcr` grades).

### Act 1 — `grade-events`

Canonical SOP:
[`../agents/alex/sops/grade-events.md`](../agents/alex/sops/grade-events.md).

Grade a batch of recent trajectory activities for quality so the learning layer keeps
only what makes the next agent smarter.

- **Precondition:** resolved activities awaiting a grade (there usually are). None
  ungraded → report "nothing to grade" and stop (idempotent no-op).
- **Steps (first-class CLI path — bearer-gated, no HTML scraping):**
  1. `bin/agent-activity awaiting [--limit 10]` — the resolved activities Alex hasn't
     graded yet (id + category · reason → outcome + task), oldest → newest.
  2. Grade each: `bin/agent-activity grade <activity-id> --disposition good|not
     --slug "<4–7 words>" [--long-form "<anchor>"]`.
  3. **Bank** the ones that make the next agent smarter (`--bank`); **discard** the
     rest (`--discard`). Banked insights feed forward via `bin/session-insights`.
  4. The browser drawer at `/alex/heartbeat` is the equivalent **admin** path
     (same writes; it also owns the **`mcr` audit-of-Alex** lane, which the agent
     CLI cannot write — the bearer `grade` endpoint always grades as `alex`).
- **Exit seam:** ~10 activities graded, useful insights banked. (Mr. McRitchie audits a
  shrinking sample as the signal proves out — he does so on the
  [`/alex/pipeline`](https://mcritchie.studio/alex/pipeline) page, where **Confirm**
  promotes an insight into column 3 as an `mcr` grade.)

### Act 2 — `share-insights`

Canonical SOP:
[`../agents/alex/sops/share-insights.md`](../agents/alex/sops/share-insights.md).

Take the insights Mr. McRitchie has **confirmed** (column 3 of the pipeline — the
`mcr`-graded subset) and share them out through the platform's docs, so every next
agent starts with the confirmed lessons. (Renamed from `propagate-insights`: the
act is named for its audience — the next agents — not the doc-write mechanics.)

- **Precondition:** at least one confirmed insight (a `grader: "mcr"` `ActionGrade`).
  None confirmed → report "nothing to share" and stop (idempotent no-op).
- **Steps:**
  1. Regenerate the tracked lessons doc from the confirmed insights (composes with
     the lever-3 generator — `bin/rails insights:doc`, scoped to the confirmed set).
  2. `bin/install-agent-docs` to distribute the regenerated doc across the runtimes
     (`~/.claude` + `~/.codex`), so the confirmed lessons reach every agent. (No
     longer the only owned installer run — `bin/release ship` auto-syncs the
     installed docs post-ship; see §3 Act 1, step 5.)
- **Exit seam:** the confirmed insights are in the tracked doc and distributed. A
  re-run with nothing newly confirmed is a clean no-op.

### Act 3 — `full-cycle`

Canonical SOP:
[`../agents/alex/sops/full-cycle.md`](../agents/alex/sops/full-cycle.md).

Run the **whole DevOps cycle** end to end — the launcher that replaced the retired
`Merge, Assemble, Deploy` chip. Named `full-cycle` to avoid colliding with the
read-only `bin/devops-cycle` snapshot tool.

- **Precondition:** there is work to move — `submitted` PRs to review, and/or an
  `assembled` release to ship. Nothing anywhere (`release == main`, empty queue) →
  report "nothing to run" and stop (idempotent no-op).
- **Steps** (the three atoms in sequence — Carl + Avi + Steffon):
  1. `pr-review` — review every `submitted` PR (review-only → `reviewed`, merged into `accepted`).
  2. `qa-release` — `bin/release prepare --yes` (the self-healing sweep: promote the
     `accepted → release` batch PR, stages 1–3 → live on QA, members `assembled`
     on QA-green).
  3. `production-deploy` — `bin/release ship` (stages 4–5 → prod), same frozen-SHA
     tests, deploy smoke, green seal, release notes.
- **Exit seam:** the whole release `shipped` (stage 5 **Deployed**). Report the prod
  SHA + release slug.

> ⚠️ **Full ship authority.** `full-cycle` crosses the production gate autonomously
> — run it only when the operator launched it (the `Alex Heartbeat` / `full-cycle`
> phrase) or otherwise granted ship authority in-session. It uses the SAME
> deterministic gates as `production-deploy`; `--yes` answers only the human
> confirm. For expediting ONE task on a clean ladder, use Avi's
> [`deploy-with-task`](../agents/avi/sops/deploy-with-task.md) act instead.

---

**Source of truth for the launcher mapping:**
`ApplicationHelper#heartbeat_launchers` (the card) →
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md) (the atoms +
this launcher set) → root `AGENTS.md` / [`index.md`](../index.md) (the quick
launcher index). If they drift, §1.4 wins; fix the others in the same pass.

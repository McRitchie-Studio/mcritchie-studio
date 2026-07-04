# Heartbeats — the three soul launchers

The standalone **Heartbeats card** on `/deployments` (`tasks/_heartbeats_card`,
sized to match the Next Release card) renders three **soul-avatar heartbeat
launchers** (`ApplicationHelper#heartbeat_launchers`, one `tasks/_heartbeat_launcher`
per soul). Each launcher is a soul face — **a link to that soul's `/agents/<slug>`
page** — over a **prompt-like row 1** plus one or more **copyable action rows**,
each carrying a leading icon (a ❤️ on the heartbeat row; a `1️⃣`–`4️⃣` keycap on the
four ordered release actions, a themed glyph on the rest):

- **Row 1 — the prompt-like soul heartbeat** (❤️): `Avi Heartbeat` · `Steffon
  Heartbeat` · `Alex Heartbeat`. One per soul (Avi's release lanes share a column).
- **The action rows** — one copyable row each, ordered **downstream-first** (each
  soul leads with its idempotent close-out action, so the number icons read
  descending):
  - **Avi** → `3️⃣ production-deploy` · `1️⃣ pr-review` · `🐢 pr-review-slow`
  - **Steffon** → `4️⃣ archive-completed` · `2️⃣ qa-deploy`
  - **Alex** → `🧑🏻‍🏫 grade-events` · `📡 share-insights` · `🌎 full-cycle`

**Every row is independently copyable** (the row-1 heartbeat prompt and each act),
and **any of them**, pasted into a fresh agent session run from
`/Users/alex/projects`, launches that heartbeat. All rows are **recognized
launchers** — wired into
[`qa-release/SKILL.md`](../skills/qa-release/SKILL.md) and
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md). Each act wraps a
single release **atom** (see §1.4's atom table), except `alex` / `grade-events`,
which is the learning loop and lives outside the release pipeline.

Each soul's action-level procedure lives with that soul:
[`Avi`](../agents/avi/HEARTBEAT.md),
[`Steffon`](../agents/steffon/HEARTBEAT.md), and
[`Alex`](../agents/alex/HEARTBEAT.md). This page is the cross-soul map.

| Soul (avatar → `/agents/<slug>`) | Row 1 prompt | Acts | Enters at | Exit seam |
|---|---|---|---|---|
| **Avi** (`avi`) | `Avi Heartbeat` | `production-deploy`, `pr-review`, `pr-review-slow` | a QA-green (`assembled`) release ready to ship / submitted PRs waiting | the ready release `shipped` (or no-op); then each PR `reviewed` or `blocked` (review-only — Steffon sweeps) |
| **Steffon** (`steffon`) | `Steffon Heartbeat` | `archive-completed`, `qa-deploy` | shipped work to archive / `reviewed` work + `assembled` stragglers to sweep | prior cycle `archived` (or no-op); then the RC swept, **live on QA, members `assembled` on QA-green** |
| **Alex** (`alex`) | `Alex Heartbeat` | `grade-events`, `share-insights`, `full-cycle` | spans to grade / confirmed insights to share / a full pipeline to run | 10 graded + banked; confirmed insights shared out; or the whole release `shipped` |

> **Sticky attribution — the FIRST action of a `<Soul> Heartbeat`.** Run
> `bin/atomic-event heartbeat <soul>` (e.g. `bin/atomic-event heartbeat avi`) so
> EVERY span self-attributes to that soul — stacked over the stable base session
> mascot — without re-passing `--agent` on each `start`/`next`. An explicit
> `--agent` on a span still WINS over the sticky (a delegated reviewer keeps its
> own soul). It clears on `bin/atomic-event heartbeat --clear` or at session end
> (`close-open`). This is why the heartbeat's own orient/workflow spans show the
> soul instead of falling back to the base mascot.
>
> **Launchers consolidated (2026-07-03).** The `pr-review-slow` (Avi) and
> `full-cycle` (Alex) actions absorbed the four **retired** release chips — `Avi
> Heartbeat Slow`, `Avi Heartbeat Fast`, `Build and Deploy QA Release`, and `Merge,
> Assemble, Deploy`. They surface on the standalone /deployments **Heartbeats** card
> (three souls, 3-up, sized to the Next Release card); the 5-stage release tracker
> stays in the **Next Release** card. `full-cycle` is named to avoid colliding with
> the read-only `bin/devops-cycle` snapshot tool.

## Launching a heartbeat in a fresh session — the quick start

Every heartbeat starts the same way in a **fresh agent session** (Claude or
Codex) run from `/Users/alex/projects`. This is the whole boot sequence — a new
session needs nothing else:

1. **Say a launcher row.** Paste the row-1 prompt (`Avi Heartbeat` · `Steffon
   Heartbeat` · `Alex Heartbeat`) or any single act row from the /deployments
   Heartbeats card. The phrase routes through the `qa-release` skill (source:
   [`docs/agents/skills/qa-release/SKILL.md`](../skills/qa-release/SKILL.md),
   installed to `~/.claude/skills` + `~/.codex/skills` by
   `bin/install-agent-docs`), which lands back on this module + §1.4.
2. **Stamp attribution FIRST** — before any other tool call:
   `cd /Users/alex/projects/mcritchie-studio && bin/atomic-event heartbeat
   <avi|steffon|alex>`.
3. **Run the soul's acts downstream-first** from the mcritchie-studio primary
   checkout (the board is **prod** by default; pass `--yes` on the release verbs
   the act owns). The full per-soul SOPs are
   [`Avi`](../agents/avi/HEARTBEAT.md),
   [`Steffon`](../agents/steffon/HEARTBEAT.md), and
   [`Alex`](../agents/alex/HEARTBEAT.md); the numbered sections below summarize
   them.

The per-soul cheat sheet — say the row-1 prompt, then drive these commands:

| Soul | Acts (downstream-first) | Commands each act drives |
|---|---|---|
| **Avi** | `production-deploy` → `pr-review` | `bin/release status` → **if** QA-green: `bin/release ship --yes`; then per `submitted` PR (waves ≤5): `bin/reviewer-select <task>` → the [review-one cascade](pr-review-sop.md) → on approval `bin/task move <task> reviewed` (**no merge**; Steffon's `qa-deploy` sweeps) |
| **Steffon** | `archive-completed` → `qa-deploy` | `bin/release archive --yes` (preview `--dry-run`); then `bin/release prepare --yes` → smoke `https://qa.mcritchie.studio/up` |
| **Alex** | `grade-events` · `share-insights` · `full-cycle` | `bin/atomic-event awaiting --limit 10` → `bin/atomic-event grade <id> …` → `--bank`/`--discard`; `bin/rails insights:doc` + `bin/install-agent-docs`; `full-cycle` = `pr-review` → `qa-deploy` → `production-deploy` (ship authority) |

> **Script-assisted review (Avi).** `bin/avi-heartbeat` is the supervisor script
> behind the review loop: it composes `bin/devops-cycle`, `bin/reviewer-select`,
> and `codex exec` reviewer pairs, writes the `bin/task move|block|note` handoffs
> itself, and prints a retrospective. It is **review-only** — approved tasks stop
> at `reviewed`; Steffon's `qa-deploy` sweep owns the merge. The working
> invocation:
>
> ```bash
> bin/avi-heartbeat --run --limit <N> --max-idle-cycles 1 \
>   --codex-workdir /Users/alex/projects/mcritchie-studio
> ```
>
> - **`--codex-workdir` must be a trusted git checkout.** The default
>   (`/Users/alex/projects`) is not a git repo, so `codex exec` refuses with
>   "Not inside a trusted directory" and **every reviewer exits 1**
>   (`reviewer failure: … exit=1`).
> - **`--max-idle-cycles 1`** exits once the queue drains; the default (240
>   polls × 60 s idle-sleep) keeps the supervisor alive ~4 h waiting for new PRs.
> - Dry-run is the default — only `--run` launches reviewers and writes tasks.
>   `--fast` reviews in bounded waves; slow (one PR at a time) is the default.

## The release handoff seam — Steffon owns stages 1–3, Avi owns 4–5

The current-release pizza-tracker (`ApplicationHelper::RELEASE_TRACKER_STAGES`) has
five stages:

| # | Stage key | Active → complete label | Owner | Driven by |
|---|---|---|---|---|
| 1 | `testing` | **Testing → Tested** | Steffon | `bin/release prepare` |
| 2 | `assembling` | **Assembling → Assembled** | Steffon | `bin/release prepare` |
| 3 | `qa_deploying` | **Deploying QA → Live on QA** | Steffon | `bin/release prepare` |
| 4 | `confirming` | **Confirming → Confirmed** | Avi | `bin/release ship` |
| 5 | `production_deploying` | **Deploying → Deployed** | Avi | `bin/release ship` |

**The souls BOOKEND the pipeline (2026-07-03): Avi reviews and ships; Steffon
owns the whole middle.** Steffon owns stages 1–3 (Testing → Assembling →
Deploying QA) via `qa-deploy` (`bin/release prepare`) — which now also owns the
**merge**: it SWEEPS the reviewed queue onto the candidate, merges each PR into
`release`, and flips members `reviewed → assembled` only on **QA-green** — and
stops at **Live on QA**. **Avi owns stages 4–5** (Confirming → Deploying) via
`production-deploy` (`bin/release ship`) and finishes at **Deployed**. The seam
between them — **"deployed to QA."** — is the **Steffon → Avi handoff**:
Steffon's `qa-deploy` ends there and reports it; Avi's `production-deploy` begins
only once it is true.

**The `merged` column is the crash-recovery spine.** Orthogonal to `stage`, it
records WHERE the task's code physically is, so an interrupted heartbeat
contextualizes itself from durable state instead of guessing:

| `stage` + `merged` | Means |
|---|---|
| `reviewed` + `nil` | approved, not swept yet |
| `reviewed` + `release` | swept — PR merged onto `release`, QA in flight |
| `assembled` + `release` | QA-green, waiting on Avi |
| `assembled` + `main` | ff'd `release → main`, prod deploy in flight |
| `shipped` + `main` | done |

An interrupted Steffon run **skips re-merging** a `merged: release` task; an
interrupted Avi run **skips re-ff'ing** a `merged: main` one (the git ffs no-op
anyway — the stamp is the readable signal).

## Operator-launched today, schedule-ready tomorrow  *(DESIGN NOTE — load-bearing)*

These three are **operator-launched** (copy-paste from the card) today. Each act's
SOP below is deliberately written so it can be **run on a schedule/cadence later
without rework**. Three properties make that safe, and every act must keep all
three:

1. **Idempotent** — re-running when there is nothing to do is a safe no-op that
   reports "nothing waiting" and exits. `pr-review` on an empty queue,
   `qa-deploy` with nothing reviewed, no stragglers, and no RC in flight,
   `production-deploy` on a `release == main` (or no QA-green release), and
   `archive-completed` with nothing shipped must each just report and stop —
   never fabricate work.
2. **Explicit precondition** — each states what must already be true to begin (the
   "Enters at" column above). A scheduler checks the precondition, and skips
   cleanly when it is not met.
3. **Named exit seam** — each ends at a definite stage/state plus a report (the
   "Exit seam" column). A scheduler reads the seam and can chain the next act
   (`pr-review` → `qa-deploy` → `production-deploy` → `archive-completed`) or bank
   the result (`grade-events`).

No heartbeat assumes a human is watching mid-run: no interactive prompts (pass
`--yes` on the `bin/release` verbs an agent shell owns), bounded blast radius, and
a self-contained report at each seam. Moving these to a cron/queue trigger later is
a wiring change, not a rewrite.

---

## 1. Avi Heartbeat — `Avi Heartbeat` / `production-deploy` / `pr-review`

Canonical step-by-step SOP:
[`../agents/avi/HEARTBEAT.md`](../agents/avi/HEARTBEAT.md). The summary below
keeps the cross-soul page readable; Avi's own heartbeat doc wins for Avi
mechanics.

**Enter as Avi.** Two acts, run **downstream-first**: ship a QA-green release if one
is ready, then review the new submitted PRs (**review-only** — Steffon's
`qa-deploy` owns the merge). Leading with the idempotent `production-deploy`
clears any ready release before new reviewed work piles up behind it; when
nothing is ready it is a no-op and falls straight through to `pr-review`. Avi
owns release **stages 4–5** (post-QA → prod).

### Act 1 — `production-deploy`

Ship the assembled, QA-green release to production.

- **Precondition:** a release is **ready** — i.e. Steffon has taken it through
  `qa-deploy` and it is **`assembled` + deployed to QA (QA-green)** (members read
  `assembled` + `merged: release`). If nothing is ready to ship (`release ==
  main`, or no QA-green release) → report "nothing to ship" and continue to
  `pr-review` (idempotent no-op).
- **Steps:**
  1. Clean the primary checkouts (stash the delete-later ledger if needed) — ship
     from a **primary checkout**, not a worktree (gems resolve as siblings).
  2. `bin/release ship --yes` — drive **stages 4–5** (Confirming → Deploying):
     fast-forward each repo's `release → main` (stamping that repo's members
     `merged: "main"` as each ff lands — the interrupted-run skip signal) and
     deploy production.
  3. Prod-smoke, green seal, and post release notes (`ship!` flips members
     `shipped`, `merged` stays `main`).
  4. Restore the primary checkouts.
- **Exit seam:** `shipped` (stage 5 **Deployed**). Report the prod SHA + release
  slug. An interrupted run re-runs safely: published gems skip, ffs no-op
  (`merged: main` members are already over), re-pins are idempotent.

> ⚠️ **Ship authority.** This crosses the production gate. Run it only when the
> operator launched it (the `Avi Heartbeat` / `production-deploy` chip / phrase) or
> otherwise granted ship authority in-session. The `--yes` answers only the human
> confirm; it never skips the clean-main preflight, frozen-SHA tests, gem publish,
> deploy smoke, or partial-ship recovery.

### Act 2 — `pr-review`

Review every waiting PR. **Review-only (2026-07-03):** approved work stops at
`reviewed` — the merge belongs to Steffon's self-healing `qa-deploy`, which
sweeps the reviewed queue promptly.

- **Precondition:** at least one `submitted` PR. Empty queue → report "no
  submitted PRs" and stop (idempotent no-op).
- **Steps:**
  1. `bin/qa-intake --refresh` → the queue of `submitted` PRs.
  2. For each PR, in **waves of ≤5** (the board DB connection cap), run the
     **review-one** atom — the [Modular PR Review SOP](pr-review-sop.md):
     `bin/reviewer-select <task>` picks the PRIMARY + LIGHT pair; each reviewer
     narrates **as its soul** (`--agent`) and returns a verdict.
  3. **Approved** → `bin/task move <task> reviewed` — and STOP (no
     `bin/release merge`; the task waits `reviewed` + `merged: nil` for the
     sweep).
  4. **Problems** → `bin/task block <task> --kind rework --feedback "…"` (one
     block never halts the batch).
- **Exit seam:** every `submitted` PR is resolved — `reviewed` (awaiting
  Steffon's sweep) or `blocked`. Report per-PR.

### Act 2b — `pr-review-slow`

The same as `pr-review`, but **serialized** — one PR at a time.

- **Precondition:** at least one `submitted` PR. Empty queue → report + stop.
- **Steps:** the `pr-review` loop with **`--max-agents 1`** — review one PR
  (`review-one` → on approval `bin/task move <task> reviewed`, review-only), then
  **re-query the board** before choosing the next. Use it for a steady trickle or
  when parallel review waves would thrash the board DB.
- **Exit seam:** every `submitted` PR resolved — `reviewed` or `blocked`.

> **History.** The 2026-07-02 fold had these acts run `bin/release merge` after
> approval; 2026-07-03 reversed it (this epic) — review is review-only again, and
> the merge moved into Steffon's self-healing sweep, which follows promptly. The
> old `bin/avi-heartbeat` review-only loop still exists but is no longer a card
> chip.

## 2. Steffon Heartbeat — `Steffon Heartbeat` / `archive-completed` / `qa-deploy`

Canonical step-by-step SOP:
[`../agents/steffon/HEARTBEAT.md`](../agents/steffon/HEARTBEAT.md). The summary
below keeps the cross-soul page readable; Steffon's own heartbeat doc wins for
Steffon mechanics.

**Enter as Steffon.** Two acts, run **downstream-first**: archive the closed-out
cycle, then take the new reviewed work through merge, QA, and the QA-green flip.
Leading with the idempotent `archive-completed` closes out the previous cycle
before starting the next; when nothing is shipped to archive it is a no-op and
falls through to `qa-deploy`. Steffon owns release **stages 1–3** (Testing →
Assembling → Deploying QA) — the whole middle, **including the merge**.

### Act 1 — `archive-completed`

Close the loop: archive the shipped work and reclaim its worktrees.

- **Precondition:** at least one `shipped` task not on `Release.last_shipped`.
  Nothing shipped to archive → report "nothing to archive" and continue to
  `qa-deploy` (idempotent no-op).
- **Steps:**
  1. `bin/release archive --yes` — archives every `shipped` task that is **not** a
     member of the most-recently-shipped release (`shipped → archived`), retires the
     now-completed releases, and reclaims the merged/shipped feature worktrees
     (delete-later ledger + Redis band shrink). Preview first with `--dry-run`.
- **Exit seam:** shipped tasks + completed releases are `archived`, merged
  worktrees reclaimed. Idempotent — a re-run finds nothing new. Report the archived
  count + reclaimed worktrees.

### Act 2 — `qa-deploy`

The **SELF-HEALING sweep**: detect the reviewed queue, merge it onto `release`,
deploy QA, and flip members `assembled` on QA-green — all one idempotent verb.

- **Precondition:** work to sweep — `reviewed` tasks, `assembled` stragglers off
  the current RC, **or** an RC already in flight (an interrupted prior run).
  Nothing anywhere → report "nothing to prepare" and stop (idempotent no-op).
- **Steps** — all inside **`bin/release prepare --yes`** (stages 1–3):
  1. **Detect:** every `reviewed` task + any `assembled` straggler not riding the
     current RC.
  2. **Ensure a candidate:** use the in-flight release, else open one.
  3. **Sweep + merge:** `gh pr merge` each detected task's PR into its repo's
     `release` (a `merged: release/main` task **skips** the merge — crash
     recovery), recording membership + `merged: "release"`. **Stages stay
     `reviewed`.**
  4. **Pre-QA gate:** the registry `qa_test_cmd` tier (integration + e2e smoke)
     on `origin/release` BEFORE deploying. A regression → **eject the offender**
     (`bin/release eject <task> --feedback "…"` + revert its merge commit), keep
     the rest, re-run.
  5. **Deploy QA:** merge-forward guard → `bin/qa-server deploy … origin/release`
     → wait-for-boot → smoke `/up` → QA post-deploy hooks.
  6. **QA-green flip:** members `reviewed → assembled` (merged stays `release`) +
     the RC `assembled`. A QA failure flips NOTHING — members stay `reviewed` and
     the **next run self-heals** (the sweep skips the already-done merges).
- **Exit seam:** the release candidate is `assembled` and live on QA (stage 3 **Live
  on QA**). Report the QA URL, then hand off to Avi at **"deployed to QA."**
  **Does NOT ship to production** — stages 4–5 are Avi's.

## 3. Alex Heartbeat — `Alex Heartbeat` / `grade-events` / `share-insights` / `full-cycle`

Canonical step-by-step SOP:
[`../agents/alex/HEARTBEAT.md`](../agents/alex/HEARTBEAT.md). The summary below
keeps the cross-soul page readable; Alex's own heartbeat doc wins for Alex
mechanics.

**Enter as Alex** (the Lead Orchestrator). Three acts: grade recent trajectory
events for the learning layer, share the CONFIRMED insights out to every agent, and
— with ship authority — run the whole DevOps cycle end to end. The distillation
pipeline at [`/alex/pipeline`](https://mcritchie.studio/alex/pipeline) is the
operator view of the first two: Actions (spans) → Insights (Alex grades) →
Confirmations (McRitchie's `mcr` grades).

### Act 1 — `grade-events`

Grade a batch of recent trajectory events for quality so the learning layer keeps
only what makes the next agent smarter.

- **Precondition:** resolved spans awaiting a grade (there usually are). None
  ungraded → report "nothing to grade" and stop (idempotent no-op).
- **Steps (first-class CLI path — bearer-gated, no HTML scraping):**
  1. `bin/atomic-event awaiting [--limit 10]` — the resolved spans Alex hasn't
     graded yet (id + category · reason → outcome + task), oldest → newest.
  2. Grade each: `bin/atomic-event grade <span-id> --disposition good|not
     --slug "<4–7 words>" [--long-form "<anchor>"]`.
  3. **Bank** the ones that make the next agent smarter (`--bank`); **discard** the
     rest (`--discard`). Banked insights feed forward via `bin/session-insights`.
  4. The browser drawer at `/alex/heartbeat` is the equivalent **admin** path
     (same writes; it also owns the **`mcr` audit-of-Alex** lane, which the agent
     CLI cannot write — the bearer `grade` endpoint always grades as `alex`).
- **Exit seam:** ~10 spans graded, useful insights banked. (Mr. McRitchie audits a
  shrinking sample as the signal proves out — he does so on the
  [`/alex/pipeline`](https://mcritchie.studio/alex/pipeline) page, where **Confirm**
  promotes an insight into column 3 as an `mcr` grade.)

### Act 2 — `share-insights`

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
     (`~/.claude` + `~/.codex`), so the confirmed lessons reach every agent.
- **Exit seam:** the confirmed insights are in the tracked doc and distributed. A
  re-run with nothing newly confirmed is a clean no-op.

### Act 3 — `full-cycle`

Run the **whole DevOps cycle** end to end — the launcher that replaced the retired
`Merge, Assemble, Deploy` chip. Named `full-cycle` to avoid colliding with the
read-only `bin/devops-cycle` snapshot tool.

- **Precondition:** there is work to move — `submitted` PRs to review, and/or an
  `assembled` release to ship. Nothing anywhere (`release == main`, empty queue) →
  report "nothing to run" and stop (idempotent no-op).
- **Steps** (the three atoms in sequence — Avi + Steffon + Avi):
  1. `pr-review` — review every `submitted` PR (review-only → `reviewed`).
  2. `qa-deploy` — `bin/release prepare --yes` (the self-healing sweep: merge the
     reviewed queue onto `release`, stages 1–3 → live on QA, members `assembled`
     on QA-green).
  3. `production-deploy` — `bin/release ship` (stages 4–5 → prod), same frozen-SHA
     tests, deploy smoke, green seal, release notes.
- **Exit seam:** the whole release `shipped` (stage 5 **Deployed**). Report the prod
  SHA + release slug.

> ⚠️ **Full ship authority.** `full-cycle` crosses the production gate autonomously
> — run it only when the operator launched it (the `Alex Heartbeat` / `full-cycle`
> phrase) or otherwise granted ship authority in-session. It uses the SAME
> deterministic gates as `production-deploy`; `--yes` answers only the human
> confirm. For expediting ONE task on a clean release, use `Deploy with Task
> <task>` instead (§1.4).

---

**Source of truth for the launcher mapping:**
`ApplicationHelper#heartbeat_launchers` (the card) →
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md) (the atoms +
this launcher set) → [`qa-release/SKILL.md`](../skills/qa-release/SKILL.md) (the
agent-side recognizer). If they drift, §1.4 wins; fix the others in the same pass.

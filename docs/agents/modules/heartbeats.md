# Workflows — the five soul launchers

The **Workflows card** on `/deployments` (`tasks/_heartbeats_card`) renders five
**soul-avatar heartbeat launchers** (`ApplicationHelper#heartbeat_launchers`, one
`tasks/_heartbeat_launcher` per soul) from ONE chip list: a five-minute carousel of
one soul at a time, and a click-through **Workflows sidebar** listing every soul
and command. Each launcher links to that soul's `/agents/<slug>` page and carries
a **prompt-like row 1** plus **copyable action rows**:

- **Row 1** (❤️): `Carl Heartbeat` · `Avi Heartbeat` · `Steffon Heartbeat` ·
  `Xan Heartbeat` · `Turf Monster Heartbeat`.
- **The action rows**, ordered along the pipeline (keycaps read review → assemble → ship):
  - **Carl** → `1️⃣ pr-review` · `🐢 pr-review-slow`
  - **Avi** → `2️⃣ qa-release` · `⚡ deploy-with-task`
  - **Steffon** → `3️⃣ production-deploy` · `🧹 clean-infra`
  - **Xan** → `🧑🏻‍🏫 grade-events` (optional: every task is graded at ship) · `📡 share-insights` · `🌎 full-cycle`
  - **Turf Monster** → `🏈 live-score-watch` · `🎬 contest-rehearsal`

  Four registered acts are deliberately NOT chips; each stays invocable by name:
  - `archive-shipped` — `production-deploy` runs it as its final step, so the
    keycap sequence ends at `3️⃣`; `clean-infra` took the slot but is off-sequence.
  - `sleeper-auction-watch` — calendar-bound (one draft evening a year), and at 21
    characters it needs 114px against the card's 98px chip text area, so it clips.
    `test/system/workflows_card_chip_fit_test.rb` holds that measurement.
  - `entry-forfeit` — externally triggered: an entrant asks to withdraw.
  - `market-refresh` / `content-build` — schedule- and queue-shaped.

  A chip does not imply a cadence (`clean-infra`, `deploy-with-task` and
  `contest-rehearsal` are chips and are direct-invoke); do not restate that
  retired argument. Decisions: [`turf_monster/HEARTBEAT.md`](../agents/turf_monster/HEARTBEAT.md).

**Every row is independently copyable**, and any of them, pasted into a fresh
session run from `/Users/alex/projects`, launches that heartbeat. All rows are
registered in the root `AGENTS.md` SOP registry and in
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md); each act wraps
one release **atom**, except Xan's learning-loop acts. Each soul's procedure lives
with that soul ([`Carl`](../agents/carl/HEARTBEAT.md),
[`Avi`](../agents/avi/HEARTBEAT.md), [`Steffon`](../agents/steffon/HEARTBEAT.md),
[`Xan`](../agents/xan/HEARTBEAT.md),
[`Turf Monster`](../agents/turf_monster/HEARTBEAT.md)); this page is the
cross-soul map. History cut from it lives in
[`../archive/heartbeats-2026-09-25.md`](../archive/heartbeats-2026-09-25.md).

| Soul (avatar → `/agents/<slug>`) | Row 1 prompt | Acts | Enters at | Exit seam |
|---|---|---|---|---|
| **Carl** (`carl`) | `Carl Heartbeat` | `pr-review`, `pr-review-slow` | submitted PRs waiting for review | each PR `reviewed` (merged into `accepted`) or `blocked` |
| **Avi** (`avi`) | `Avi Heartbeat` | `qa-release`, `deploy-with-task` (direct-invoke only), `arbitrate-block` (registered, not a chip — a builder contests a review block and the session that spawned it invokes Avi) | `reviewed` work + `assembled` stragglers to sweep | the RC swept, **live on QA, members `assembled` on QA-green** |
| **Steffon** (`steffon`) | `Steffon Heartbeat` | `production-deploy`, `clean-infra`, `archive-shipped` (registered, not a chip — production-deploy runs it) | a QA-green (`assembled`) release ready to ship / a machine carrying finished work | the ready release `shipped` (archived on the way out, or no-op); the machine swept |
| **Xan** (`xan`) | `Xan Heartbeat` | `share-insights`, `full-cycle`; `grade-events` is optional (every task is graded at ship) and runs only when named | activities to grade / a non-empty insight bank to share / a full pipeline to run | 10 graded + banked; the bank shared out; or the whole release `shipped` |
| **Turf Monster** (`turf-monster`) | `Turf Monster Heartbeat` | `live-score-watch`, `contest-rehearsal`, `sleeper-auction-watch` (registered, not a chip — the slug clips the card), `entry-forfeit` (registered, not a chip — on-demand incident SOP), `market-refresh` (registered, not a chip — weekly, but the moment is read off the schedule), `content-build` (registered, not a chip — queue-shaped; it runs when games finalise) | a live NFL slot with the poller deployed, QA reachable on devnet, or a Sleeper auction about to start | the slot final or the window elapsed; the rehearsal contest settled and closed; or the draft board full |

> **Direct-drive the mutating acts.** `qa-release`, `production-deploy`, and
> `archive-shipped` MUTATE shared state across many minutes, so the heartbeat
> session runs them ITSELF — never via an Agent-tool subagent, which can detach and
> leave the mutation half-applied. Subagents stay first-class for **read** fan-out:
> `pr-review` spins **one Carl per PR** as subagents. The line is *mutating vs
> reading*. Recovery for an interrupted mutation is to RE-RUN it; the commands are
> self-healing ([`parallel-agent-devops.md`](parallel-agent-devops.md)).

> **Sticky attribution — the FIRST action of a `<Soul> Heartbeat`.**
> `bin/agent-activity heartbeat <soul>` attributes EVERY activity to that soul; an
> explicit `--agent` still WINS. Clear it with `bin/agent-activity heartbeat --clear`.

## Launching a heartbeat in a fresh session — the quick start

Every heartbeat boots the same way in a **fresh agent session** (Claude or Codex)
run from `/Users/alex/projects`:

1. **Say a launcher row** (row 1 or any act row). The root `AGENTS.md` maps each
   phrase to the owning soul's `HEARTBEAT.md` and SOP. No installed skill needed.
2. **Stamp attribution FIRST**, before any other tool call:
   `cd /Users/alex/projects/mcritchie-studio && bin/agent-activity heartbeat <carl|avi|steffon|xan>`.
3. **Run the soul's acts** from the mcritchie-studio primary checkout (the board
   is **prod** by default; pass `--yes` on the release verbs the act owns).

The per-soul cheat sheet:

| Soul | Acts | Commands each act drives |
|---|---|---|
| **Carl** | `pr-review` → `pr-review-slow` | per `submitted` PR (waves ≤5): `bin/task claim-next-review` → spin one Carl → the [review-one primitive](pr-review-sop.md) → on a merge-ready verdict `gh pr merge` into `accepted` + `bin/task move <task> reviewed` |
| **Avi** | `qa-release` | `bin/release prepare --yes` → smoke `https://qa.mcritchie.studio/up` (stages 1–3, members `assembled` on QA-green) |
| **Steffon** | `production-deploy` → `archive-shipped` | `bin/release status` → **if** QA-green: `bin/release ship --yes` (stages 4–5); then `bin/release archive --yes` (preview `--dry-run`) |
| **Xan** | `share-insights` · `full-cycle` · `grade-events` (optional, only when named) | `bin/agent-activity awaiting --limit 10` → `bin/agent-activity grade <id> …` → `--bank`/`--discard`; `bin/rails insights:doc`; `full-cycle` = `pr-review` → `qa-release` → `production-deploy` (ship authority) |

> **Script-assisted review.** `bin/pr-review` is a codex-based, **review-only**
> loop (composes `bin/devops-cycle`, `bin/reviewer-select`, and codex reviewers
> running `carl/sops/pr-review-{primary,light}.md`; approved tasks stop at
> `reviewed`). The canonical interactive path is `carl/sops/pr-review.md`. Invoke:
>
> ```bash
> bin/pr-review --run --limit <N> --max-idle-cycles 1 \
>   --codex-workdir /Users/alex/projects/mcritchie-studio
> ```
>
> `--codex-workdir` must be a trusted git checkout (the projects root is not one,
> so every reviewer exits 1). `--max-idle-cycles 1` exits once the queue drains
> (the default waits ~4 h). Dry-run is the default; only `--run` writes. `--fast`
> reviews in bounded waves; one PR at a time is the default.

## The release handoff seam — Avi owns stages 1–3, Steffon owns 4–5

The five release stages (`Release::STAGES`, `ApplicationHelper#release_repo_lanes`):

| # | Stage key | Active → complete label | Owner | Driven by |
|---|---|---|---|---|
| 1 | `testing` | **Testing → Tested** | Avi | `bin/release prepare` |
| 2 | `assembling` | **Assembling → Assembled** | Avi | `bin/release prepare` |
| 3 | `qa_deploying` | **Deploying QA → Live on QA** | Avi | `bin/release prepare` |
| 4 | `confirming` | **Confirming → Confirmed** | Steffon | `bin/release ship` |
| 5 | `production_deploying` | **Deploying → Deployed** | Steffon | `bin/release ship` |

**Carl reviews; Avi assembles + QAs; Steffon ships.** Avi's `qa-release`
(`bin/release prepare`) owns the **`accepted → release` merge**, flips members
`reviewed → assembled` only on **QA-green**, and stops at **Live on QA**.
Steffon's `production-deploy` (`bin/release ship`) begins only once that is true
and finishes at **Deployed**. **"Deployed to QA"** is the Avi → Steffon handoff.

**The `merged` column is the crash-recovery spine.** Orthogonal to `stage`, it
records WHERE the task's code physically is:

| `stage` + `merged` | Means |
|---|---|
| `reviewed` + `accepted` | Carl merged the feat PR onto `accepted`, not swept yet |
| `reviewed` + `release` | swept — PR merged onto `release`, QA in flight |
| `assembled` + `release` | QA-green, waiting on Steffon |
| `assembled` + `main` | ff'd `release → main`, prod deploy in flight |
| `shipped` + `main` | done |

An interrupted Avi run **skips re-merging** a `merged: release` task; an
interrupted Steffon run **skips re-ff'ing** a `merged: main` one.

## Operator-launched today, schedule-ready tomorrow  *(DESIGN NOTE — load-bearing)*

These acts are operator-launched today and must stay schedulable without rework.
Every act keeps three properties:

1. **Idempotent** — with nothing to do it reports "nothing waiting" and exits
   (`pr-review` on an empty queue, `qa-release` with nothing reviewed and no RC in
   flight, `production-deploy` on `release == main`, `archive-shipped` with nothing
   shipped). Never fabricate work.
2. **Explicit precondition** — the "Enters at" column above; a scheduler skips
   cleanly when it is not met.
3. **Named exit seam** — the "Exit seam" column; a scheduler chains the next act
   (`pr-review` → `qa-release` → `production-deploy` → `archive-shipped`).

No heartbeat assumes a human is watching: no interactive prompts (pass `--yes` on
the `bin/release` verbs an agent shell owns), bounded blast radius, and a
self-contained report at each seam.

---

## 1. Carl Heartbeat — `Carl Heartbeat` / `pr-review` / `pr-review-slow`

Launcher: [`../agents/carl/HEARTBEAT.md`](../agents/carl/HEARTBEAT.md); SOPs
[`pr-review`](../agents/carl/sops/pr-review.md) and
[`pr-review-slow`](../agents/carl/sops/pr-review-slow.md) win for mechanics.
**Enter as Carl.** **Review-only:** approved work stops at `reviewed` (merged onto
`accepted`); Avi's `qa-release` sweep owns the promotion.

### Act 1 — `pr-review`

- **Precondition:** at least one `submitted` PR with green CI. None → report "no
  reviewable PRs" and stop.
- **Steps:**
  1. `bin/task claim-next-review` → the highest-ranked reviewable **green-CI** PR,
     claimed atomically (red / pending / conflicted are never popped).
  2. For each PR, in **waves of ≤5** (a Carl + his light count as two), spin **one
     Carl** — the [review-one primitive](pr-review-sop.md). Carl runs
     [`pr-review-primary.md`](../agents/carl/sops/pr-review-primary.md), owns the
     gates, and summons **one** domain LIGHT who runs
     [`pr-review-light.md`](../agents/carl/sops/pr-review-light.md). Each reviewer
     narrates **as its soul** (`--agent`).
  3. **Merge-ready** → Carl revalidates the head, `gh pr merge` the feat PR into
     `accepted`, `bin/task merged <task> accepted`, then `bin/task move <task>
     reviewed` (merge → stamp → move).
  4. **Problems** → Carl, who holds the review claim, blocks: `bin/task block
     <task> --kind rework --feedback "…" --agent carl` (only the claim's holder may
     spend the bounce; anyone else is refused with exit 11). The **two-bounce
     circuit breaker** REFUSES a repeat send-back (exit 10) and names the
     `dependency` escalation instead; read it with `bin/task bounces <task>`. A
     MECHANICAL bounce (red CI, merge conflict) proceeds on `--breaker-ack "<reason>"`.
- **Exit seam:** every `submitted` PR is `reviewed` or `blocked`. Report per-PR.

### Act 2 — `pr-review-slow`

The same loop, **serialized** (`--max-agents 1`), re-querying the board before each
PR. Use it when parallel waves would thrash the board DB.

## 2. Avi Heartbeat — `Avi Heartbeat` / `qa-release`

Launcher: [`../agents/avi/HEARTBEAT.md`](../agents/avi/HEARTBEAT.md). **Enter as
Avi** (the Product Owner). Avi owns release **stages 1–3**, including the merge.
[`deploy-with-task`](../agents/avi/sops/deploy-with-task.md) is a direct-invoke
single-task expedite, never part of the heartbeat.

### Act 1 — `qa-release`

SOP: [`../agents/avi/sops/qa-release.md`](../agents/avi/sops/qa-release.md). Run
the self-healing `bin/release prepare --yes` sweep: reviewed work plus stragglers
onto `release`, pre-QA gate, QA deploy, and members `assembled` only on QA-green.
`qa-deploy` is the legacy alias.

- **Precondition:** `reviewed` work and/or an `assembled` straggler. Nothing
  reviewed, no stragglers, no RC in flight → report + stop.
- **Exit seam:** the RC **live on QA**, members `assembled`. Report slug + QA URL.

## 3. Steffon Heartbeat — `Steffon Heartbeat` / `production-deploy` / `archive-shipped`

Launcher: [`../agents/steffon/HEARTBEAT.md`](../agents/steffon/HEARTBEAT.md).
**Enter as Steffon** (the Platform Engineer). Two acts, **downstream-first**: ship
a QA-green release if one is ready, then archive the prior cycle. Steffon owns
release **stages 4–5** plus the archive.

### Act 1 — `production-deploy`

SOP: [`../agents/steffon/sops/production-deploy.md`](../agents/steffon/sops/production-deploy.md).

- **Precondition:** a release is **`assembled` + deployed to QA (QA-green)**
  (members read `assembled` + `merged: release`). Nothing ready (`release ==
  main`, or no QA-green release) → report "nothing to ship" and continue to
  `archive-shipped`.
- **Steps:**
  1. Ship from a **primary checkout**, not a worktree (gems resolve as siblings);
     a pre-cutover stash may still be parked there.
  2. Run the **full e2e on the FROZEN ship SHA**, then `bin/release ship --yes`:
     fast-forward each repo's `release → main` (stamping `merged: "main"` as each
     ff lands) and deploy production.
  3. Prod-smoke, green seal, and post release notes (`ship!` flips members `shipped`).
  4. Restore the primary checkouts.
  5. Post-ship agent-docs sync — ship auto-runs `bin/install-agent-docs` from the
     hub's **ship workspace** (`mcritchie-studio/.worktrees/_ship`, pinned at the
     SHA that just shipped; non-fatal, never aborts a completed ship). The hub
     **primary is the fallback, not the source** — taken only when that workspace
     holds no installer, because step 4's restore is best-effort. **Steffon owns
     this step and its mechanism**; if it warns, run the installer path the warn
     line prints, not the primary's copy.
- **Exit seam:** `shipped` (stage 5 **Deployed**). Report the prod SHA + release
  slug. An interrupted run re-runs safely: published gems skip, ffs no-op,
  re-pins are idempotent.

> ⚠️ **Ship authority.** Run it only when the operator launched it (the `Steffon
> Heartbeat` / `production-deploy` chip or phrase) or granted ship authority
> in-session. `--yes` answers only the human confirm; it never skips the preflight,
> frozen-SHA tests, gem publish, deploy smoke, or partial-ship recovery. A dirty
> primary does NOT block it: the deploy runs from `.worktrees/_ship`.

### Act 2 — `archive-shipped`

SOP: [`../agents/steffon/sops/archive-shipped.md`](../agents/steffon/sops/archive-shipped.md).
Archive shipped work and reclaim completed worktrees. `archive-completed` is the
legacy alias.

## 4. Xan Heartbeat — `Xan Heartbeat` / `grade-events` / `share-insights` / `full-cycle`

Launcher: [`../agents/xan/HEARTBEAT.md`](../agents/xan/HEARTBEAT.md). The
operator view is [`/xan/pipeline`](https://mcritchie.studio/xan/pipeline).

### Act 1 — `grade-events` (optional since 2026-09-25)

SOP: [`../agents/xan/sops/grade-events.md`](../agents/xan/sops/grade-events.md).
Every task is graded once at ship (`Insights::TaskGrader`, thresholds in
`config/learning_loop.yml`), so run this act only when Mr. McRitchie names it.

- **Precondition:** resolved activities awaiting a grade. None → report and stop.
- **Steps:** `bin/agent-activity awaiting [--limit 10]` → `bin/agent-activity grade
  <activity-id> --disposition good|not --slug "<4–7 words>"` → `--bank` or
  `--discard`. The `/xan/heartbeat` drawer is the admin path (the `mcr` lane).
- **Exit seam:** ~10 activities graded, useful insights banked.

### Act 2 — `share-insights`

SOP: [`../agents/xan/sops/share-insights.md`](../agents/xan/sops/share-insights.md).
Share the **Insight Bank** (`ActionGrade.banked`, whichever grader recorded each
row) through the docs so every next agent starts with the curated lessons.

- **Precondition:** at least one banked `ActionGrade`. Empty bank → report and
  stop. **Banking is the gate, not the grader:** `mcr` marks Mr. McRitchie's audit
  *of* an Xan grade, a lane the agent CLI cannot write.
- **Steps:** `bin/rails insights:doc` regenerates `../shared/insights.md` from the
  bank. **That is the whole act — it installs nothing, and owes no install step**
  ([`docs-maintenance.md`](docs-maintenance.md) § Editing The Entry Docs).
- **Exit seam:** every banked insight is in the tracked doc.

### Act 3 — `full-cycle`

SOP: [`../agents/xan/sops/full-cycle.md`](../agents/xan/sops/full-cycle.md). Run
`pr-review` → `qa-release` (`bin/release prepare --yes`) → `production-deploy`
(`bin/release ship`). **Precondition:** `submitted` PRs and/or an `assembled`
release; nothing anywhere → report and stop. **Exit seam:** the release `shipped`.

> ⚠️ **Full ship authority.** Run `full-cycle` only when the operator launched it
> or granted ship authority in-session. It uses the SAME deterministic gates as
> `production-deploy`. To expedite ONE task on a clean ladder, use Avi's
> [`deploy-with-task`](../agents/avi/sops/deploy-with-task.md) act instead.

---

**Source of truth:** `ApplicationHelper#heartbeat_launchers` →
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md) → root `AGENTS.md`
/ [`index.md`](../index.md). If they drift, §1.4 wins; fix the others in one pass.

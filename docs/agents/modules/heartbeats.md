# Heartbeats — the three soul launchers

The **DevOps card** (`#release-duration-card` on `/deployments`) renders three
**soul-avatar heartbeat launchers** (`ApplicationHelper#heartbeat_launchers`,
rendered by `tasks/_heartbeat_launchers`, below the card's release-duration
metrics). Each launcher is a soul face — **now a link to that
soul's `/agents/<slug>` page** — over a **prompt-like row 1** plus one or more
**copyable atom acts**:

- **Row 1 — the prompt-like soul heartbeat**: `Avi Heartbeat` · `Steffon
  Heartbeat` · `Alex Heartbeat`. One per soul (Avi's two release lanes now share a
  single column).
- **The atom acts** — one copyable row each:
  - **Avi** → `pr-review` · `production-deploy`
  - **Steffon** → `qa-deploy` · `archive-completed`
  - **Alex** → `grade-events`

**Every row is independently copyable** (the row-1 heartbeat prompt and each act),
and **any of them**, pasted into a fresh agent session run from
`/Users/alex/projects`, launches that heartbeat. All rows are **recognized
launchers** — wired into
[`qa-release/SKILL.md`](../skills/qa-release/SKILL.md) and
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md). Each act wraps a
single release **atom** (see §1.4's atom table), except `alex` / `grade-events`,
which is the learning loop and lives outside the release pipeline.

| Soul (avatar → `/agents/<slug>`) | Row 1 prompt | Acts | Enters at | Exit seam |
|---|---|---|---|---|
| **Avi** (`avi`) | `Avi Heartbeat` | `pr-review`, `production-deploy` | submitted PRs waiting / release deployed to QA | each PR `assembled` or `blocked`; then `shipped` if a QA-green release is ready |
| **Steffon** (`steffon`) | `Steffon Heartbeat` | `qa-deploy`, `archive-completed` | `assembled` on `release` | release **deployed to QA**; shipped tasks + completed releases archived |
| **Alex** (`alex`) | `Alex Heartbeat` | `grade-events` | resolved spans awaiting grade | 10 graded, insights banked |

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

**Steffon owns stages 1–3** (Testing → Assembling → Deploying QA) via `qa-deploy`
(`bin/release prepare`) and stops at **Live on QA**. **Avi owns stages 4–5**
(Confirming → Deploying) via `production-deploy` (`bin/release ship`) and finishes
at **Deployed**. The seam between them — **"deployed to QA."** — is the
**Steffon → Avi handoff**: Steffon's `qa-deploy` ends there and reports it; Avi's
`production-deploy` begins only once it is true.

## Operator-launched today, schedule-ready tomorrow  *(DESIGN NOTE — load-bearing)*

These three are **operator-launched** (copy-paste from the card) today. Each act's
SOP below is deliberately written so it can be **run on a schedule/cadence later
without rework**. Three properties make that safe, and every act must keep all
three:

1. **Idempotent** — re-running when there is nothing to do is a safe no-op that
   reports "nothing waiting" and exits. `pr-review` on an empty queue,
   `qa-deploy` with nothing assembled, `production-deploy` on a `release == main`
   (or no QA-green release), and `archive-completed` with nothing shipped must each
   just report and stop — never fabricate work.
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

## 1. Avi Heartbeat — `Avi Heartbeat` / `pr-review` / `production-deploy`

**Enter as Avi.** Two acts: review + merge the submitted PRs, then ship a
QA-green release if one is ready. Avi owns release **stages 4–5** (post-QA → prod).

### Act 1 — `pr-review`

Review every waiting PR, merging the approved ones.

- **Precondition:** at least one `submitted` PR. Empty queue → report "no
  submitted PRs" and stop (idempotent no-op).
- **Steps:**
  1. `bin/qa-intake --refresh` → the queue of `submitted` PRs.
  2. For each PR, in **waves of ≤5** (the board DB connection cap), run the
     **review-one** atom — the [Modular PR Review SOP](pr-review-sop.md):
     `bin/reviewer-select <task>` picks the PRIMARY + LIGHT pair; each reviewer
     narrates **as its soul** (`--agent`) and returns a verdict.
  3. **Approved** → `bin/task move <task> reviewed` **and** `bin/release merge
     <task>` (the PRIMARY owns the merge → task flips to `assembled`).
  4. **Problems** → `bin/task block <task> --kind rework --feedback "…"` (one
     block never halts the batch).
- **Exit seam:** every `submitted` PR is resolved — merged (`assembled`) or
  `blocked`. Report per-PR.

> **Not the same as `Avi Heartbeat Slow`/`Fast`.** Those long-running loops
> (devops-cycle-design.md §1.4) are review-**only** and stop at `reviewed`.
> `pr-review` is the atom that **merges** approved work through to `assembled`.

### Act 2 — `production-deploy`

Ship the assembled, QA-green release to production.

- **Precondition:** a release is **ready** — i.e. Steffon has taken it through
  `qa-deploy` and it is **`assembled` + deployed to QA (QA-green)**. If nothing is
  ready to ship (`release == main`, or no QA-green release) → report "nothing to
  ship" and stop (idempotent no-op).
- **Steps:**
  1. Clean the primary checkouts (stash the delete-later ledger if needed) — ship
     from a **primary checkout**, not a worktree (gems resolve as siblings).
  2. `bin/release ship --yes` — drive **stages 4–5** (Confirming → Deploying):
     fast-forward each repo's `release → main` and deploy production.
  3. Prod-smoke, green seal, and post release notes.
  4. Restore the primary checkouts.
- **Exit seam:** `shipped` (stage 5 **Deployed**). Report the prod SHA + release
  slug.

> ⚠️ **Ship authority.** This crosses the production gate. Run it only when the
> operator launched it (the `Avi Heartbeat` / `production-deploy` chip / phrase) or
> otherwise granted ship authority in-session. The `--yes` answers only the human
> confirm; it never skips the clean-main preflight, frozen-SHA tests, gem publish,
> deploy smoke, or partial-ship recovery.

## 2. Steffon Heartbeat — `Steffon Heartbeat` / `qa-deploy` / `archive-completed`

**Enter as Steffon.** Two acts: take assembled work through to QA, then archive the
completed work. Steffon owns release **stages 1–3** (Testing → Assembling →
Deploying QA).

### Act 1 — `qa-deploy`

Start the release and deploy it to QA.

- **Precondition:** `assembled` work sits on `release`. Nothing assembled →
  report "nothing to prepare" and stop (idempotent no-op).
- **Steps:**
  1. Confirm the assembled members are on `origin/release`.
  2. `bin/release prepare --yes` — drive **stages 1–3** (Testing → Assembling →
     Deploying QA): assemble `origin/release` and deploy it to QA.
  3. Smoke `https://qa.mcritchie.studio/up`.
- **Exit seam:** the release candidate is `assembled` and live on QA (stage 3 **Live
  on QA**). Report the QA URL, then hand off to Avi at **"deployed to QA."**
  **Does NOT ship to production** — stages 4–5 are Avi's.

### Act 2 — `archive-completed`

Close the loop: archive the shipped work and reclaim its worktrees.

- **Precondition:** at least one `shipped` task not on `Release.last_shipped`.
  Nothing shipped to archive → report "nothing to archive" and stop (idempotent
  no-op).
- **Steps:**
  1. `bin/release archive --yes` — archives every `shipped` task that is **not** a
     member of the most-recently-shipped release (`shipped → archived`), retires the
     now-completed releases, and reclaims the merged/shipped feature worktrees
     (delete-later ledger + Redis band shrink). Preview first with `--dry-run`.
- **Exit seam:** shipped tasks + completed releases are `archived`, merged
  worktrees reclaimed. Idempotent — a re-run finds nothing new. Report the archived
  count + reclaimed worktrees.

## 3. Alex Heartbeat — `Alex Heartbeat` / `grade-events`

**Enter as Alex.** Grade a batch of recent trajectory events for quality so the
learning layer keeps only what makes the next agent smarter.

- **Precondition:** resolved spans awaiting a grade (there usually are). None
  ungraded → report "nothing to grade" and stop (idempotent no-op).
- **Steps:**
  1. At `/alex/heartbeat`, grab the **10 most recent resolved spans**, oldest →
     newest.
  2. Grade each: **good / not**, a **4–7 word slug**, and an optional long-form
     note.
  3. **Bank** the ones that make the next agent smarter (enriched `feedback_*`
     insights); **discard** the rest.
- **Exit seam:** 10 spans graded, useful insights banked. (Mr. McRitchie audits a
  shrinking sample as the signal proves out.)

---

**Source of truth for the launcher mapping:**
`ApplicationHelper#heartbeat_launchers` (the card) →
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md) (the atoms +
this launcher set) → [`qa-release/SKILL.md`](../skills/qa-release/SKILL.md) (the
agent-side recognizer). If they drift, §1.4 wins; fix the others in the same pass.

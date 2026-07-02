# Heartbeats — the four single-soul launchers

The current-release card (`#current-release`) renders four **soul-avatar heartbeat
launchers** (`ApplicationHelper#heartbeat_launchers`, rendered by
`tasks/_heartbeat_launchers`). Each launcher is a soul face over **two
independently-copyable rows**:

- **Row 1 — the soul+role heartbeat phrase**: `avi pr` · `avi deploy` · `steffon`
  · `alex`. Distinct per launcher (never the ambiguous `<soul> heartbeat` that
  collapsed Avi's two lanes into one).
- **Row 2 — the launcher atom**: `pr-review` · `production-deploy` · `qa-deploy` ·
  `grade events`. The scoped verb the heartbeat runs.

**Either row**, pasted into a fresh agent session run from
`/Users/alex/projects`, launches that heartbeat. Both rows are **recognized
launchers** — wired into
[`qa-release/SKILL.md`](../skills/qa-release/SKILL.md) and
[`devops-cycle-design.md` §1.4](../system/devops-cycle-design.md). Three of the
four wrap a single release **atom** (see §1.4's atom table); the fourth (`alex` /
`grade events`) is the learning loop and lives outside the release pipeline.

| Launcher (row 1) | Atom (row 2) | Soul | Enters at | Exit seam |
|---|---|---|---|---|
| **`avi pr`** | **`pr-review`** | Avi | submitted PRs waiting | each `reviewed`+merged (`assembled`) or `blocked` |
| **`steffon`** | **`qa-deploy`** | Steffon | `assembled` on `release` | `assembled` deployed to QA (no prod) |
| **`avi deploy`** | **`production-deploy`** | Avi (ship authority) | `assembled` + QA-reviewed | `shipped` to prod |
| **`alex`** | **`grade events`** | Alex | resolved spans awaiting grade | 10 graded, insights banked |

## Operator-launched today, schedule-ready tomorrow  *(DESIGN NOTE — load-bearing)*

These four are **operator-launched** (copy-paste from the card) today. Each SOP
below is deliberately written so it can be **run on a schedule/cadence later
without rework**. Three properties make that safe, and every heartbeat must keep
all three:

1. **Idempotent** — re-running when there is nothing to do is a safe no-op that
   reports "nothing waiting" and exits. Firing `steffon` with nothing assembled,
   `avi deploy` on a `release == main`, or `avi pr` on an empty queue must each
   just report and stop — never fabricate work.
2. **Explicit precondition** — each states what must already be true to begin
   (the "Enters at" column above). A scheduler checks the precondition, and skips
   cleanly when it is not met.
3. **Named exit seam** — each ends at a definite stage/state plus a report (the
   "Exit seam" column). A scheduler reads the seam and can chain the next
   heartbeat (`avi pr` → `steffon` → `avi deploy`) or bank the result (`alex`).

No heartbeat assumes a human is watching mid-run: no interactive prompts (pass
`--yes` on the `bin/release` verbs an agent shell owns), bounded blast radius, and
a self-contained report at the seam. Moving these to a cron/queue trigger later is
a wiring change, not a rewrite.

---

## 1. Avi PR — `avi pr` / `pr-review`

**Enter as Avi.** Review every waiting PR, merging the approved ones.

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
> (§1.4) are review-**only** and stop at `reviewed`. `avi pr` is the `pr-review`
> atom — it **merges** approved work through to `assembled`.

## 2. Steffon — `steffon` / `qa-deploy`

**Enter as Steffon.** Start the release and deploy it to QA.

- **Precondition:** `assembled` work sits on `release`. Nothing assembled →
  report "nothing to prepare" and stop (idempotent no-op).
- **Steps:**
  1. Confirm the assembled members are on `origin/release`.
  2. `bin/release prepare --yes` — assemble `origin/release` and deploy it to QA.
  3. Smoke `https://qa.mcritchie.studio/up`.
- **Exit seam:** the release candidate is `assembled` and live on QA. Report the
  QA URL. **Does NOT ship to production.**

## 3. Avi Deploy — `avi deploy` / `production-deploy`

**Enter as Avi (ship authority).** Deploy the assembled, QA-reviewed release to
production.

- **Precondition:** the release is `assembled` **and** QA-reviewed. Nothing to
  ship (`release == main`) → report "release == main, nothing to ship" and stop
  (idempotent no-op).
- **Steps:**
  1. Clean the primary checkouts (stash the delete-later ledger if needed) — ship
     from a **primary checkout**, not a worktree (gems resolve as siblings).
  2. `bin/release ship --yes` — fast-forward each repo's `release → main` and
     deploy production.
  3. Prod-smoke, green seal, and post release notes.
  4. Restore the primary checkouts.
- **Exit seam:** `shipped`. Report the prod SHA + release slug.

> ⚠️ **Ship authority.** This crosses the production gate. Run it only when the
> operator launched it (the `avi deploy` chip / phrase) or otherwise granted ship
> authority in-session. The `--yes` answers only the human confirm; it never
> skips the clean-main preflight, frozen-SHA tests, gem publish, deploy smoke, or
> partial-ship recovery.

## 4. Alex — `alex` / `grade events`

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

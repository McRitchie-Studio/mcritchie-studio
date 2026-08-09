# Parking Lot

## Status: Active

Work that is **deliberately not on the board** — evaluated, judged worth keeping,
and parked with its evidence intact.

## Why this file exists

A task board is a **commitment** surface: everything on it is work we mean to do
soon. A board that carries every good idea stops being a plan and becomes fog —
and [`clean-up`](../agents/alex/sops/clean-up.md) exists to burn that fog off.

But the opposite failure is worse, and we have now paid for it twice: **a fix that
is written and then left unlanded does not stay written — it rots.** PR #361
carried four guardrails. Three never landed anywhere, the PR went conflicted, and
the ecosystem spent months **re-learning each lesson by hand** — re-deriving fixes
it had already authored, and re-suffering the bugs in between.

This file is the third state, between *on the board* and *gone*:

- **Not a task.** It does not count against the zero-task goal.
- **Not lost.** The reasoning, the evidence, and the diff are all here.
- **Cheap to resurrect.** Every entry names the code and the artifact.

> **Rule: nothing is closed as "superseded" unless you can point at the code that
> supersedes it.** Being conflicted is not evidence of being obsolete.

---

## Parked — from PR #361 (`feat/harden-the-devops-gate`)

Closed 2026-07-14 during the founding `clean-up` run. Two of its four guardrails
were built and shipped that day; these two were parked.

**Full diff preserved:** `pr361-guardrails.diff` (1,164 lines, including ~520
lines of tests).

### 1. Lint — no `@qa-readonly` spec may assert a seed fixture

**What.** A lint (`bin/lib/qa_readonly_lint.rb` in the preserved diff, ~97 lines)
asserting that no Playwright spec tagged `@qa-readonly` references a slug that
exists only in `e2e/seed.rb`.

**Why it matters.** The post-ship prod-smoke seal runs `--grep @qa-readonly`
against **production**, which has no seed data. A spec that pins a seed fixture
therefore **red-seals a perfectly healthy production ship.** This has already
happened once, via `e2e/board_cleared_block.spec.js`.

**Status.** The *incident* was patched — that spec is no longer `@qa-readonly`. The
*class* was not: nothing stops the next `@qa-readonly` spec from doing the same
thing. The lesson currently lives only in an agent's memory file.

**Why parked.** Prophylactic, not an active hazard: no offending spec sits on
`release` today.

**Resurrect when:** a prod-smoke seal goes red on a fixture assertion, or anyone
adds a new `@qa-readonly` spec.

### 2. Ship-preflight auto-clean of a falsely-dirty primary

**What.** `autocleanable?` / `partition_autocleanable` / `reconcile_offender` /
`file_on_release?` in `ship_sequence.rb` + `bin/release.rb`: auto `git reset --hard
origin/main` **only** when every piece of dirt is byte-identical to
`origin/release`, HEAD is not ahead, and we are on `main`. Refuse otherwise.

**Why it matters.** The production ship aborts on a dirty primary checkout, and
background processes routinely dirty it. Today this costs a manual hand-reset on
every ship.

**Why parked.** The largest of the four and the most conflict-prone —
`bin/release.rb` has been heavily rewritten since #361, so this is a
**re-derivation, not a port.** It also touches the production ship path, which
deserves its own change rather than a ride-along in a cleanup.

> ### ⛔ Defect to avoid if you revive this
> The original `working_tree_changes` called `git status --porcelain` with **no
> `git update-index --refresh` first.** A stale-mtime index reads as falsely dirty
> — so the guard written to cure a false dirty-abort would **inherit the very false
> positive it exists to prevent.** Refresh the index before you read it.

**Resurrect when:** the hand-reset becomes annoying enough to price, or the ship
path is being touched anyway.

---

## Parked — give the e2e lane its own database

Filed and archived 2026-07-14 during the founding `clean-up` run (task
`e2e-lane-owns-its-db`). **Nothing in the repo references it** — checked before
archiving, per the SOP's archive rubric.

**What.** The **producer-side** half of the e2e/minitest database collision. Give
Playwright's `webServer` its own database — a distinct `TEST_DATABASE_URL` in
`playwright.config.js` (e.g. `mcritchie_studio_e2e`) — and **boot-check it** by
reading back `connection_db_config.database` rather than trusting the env var.

**Why parked.** PR #548 already closed the **consumer** side, which was the live
hazard: `test_helper` purges every table at boot, so the minitest database is
hermetic *no matter who polluted it* — and the purge now **fails closed**, refusing
any database it cannot prove is the test database. The remaining benefit is
defence-in-depth plus the ability to run both lanes **concurrently**, which nothing
does today.

**Worth knowing if you pick it up:** the **reverse** hazard already exists and
pre-dates all of this — minitest truncates `tasks`, `users`, `agents` and
`activities` (they have fixtures), so it would wipe a *running* e2e server's data.
Running both lanes against one database was always fatal; isolation is what fixes
that direction.

**Resurrect when:** anyone wants to run e2e and minitest concurrently.

---

## Parked — commit the silence corpus probe

Filed and archived 2026-07-14 (task `commit-silence-corpus-probe`). Flagged
**independently by both reviewers** at review of PR #544, non-blocking; #544 was
approved. Nothing in the repo references it.

**The gap.** `PROGRESS_QUIET_SECONDS` is derived from `MEASURED_SILENCE_SECONDS` —
six numbers describing a 243-window corpus of how long healthy agent sessions go
quiet. Those six numbers are **hand-transcribed from an uncommitted one-off
production probe.** No query, rake task, SQL, or dataset in the repo regenerates
them.

**Why that itches.** The constant's own comment says *"re-measure the corpus and the
threshold moves with it"* — **but there is nothing committed to re-measure with.**
It is a number claiming to be derived from evidence that does not live in the
repository. That is the same shape as everything else this cleanup dug out: a
declaration with no mechanism behind it.

**Why parked, not built.** No live exposure. The threshold is deliberately
conservative (a 1.5× safety factor over the worst measured window, precisely because
the corpus does not support a confident p99 at n=243), so being wrong costs a chip
appearing late — not a false alarm. The numbers ARE written down, with their
provenance stated.

**Resurrect when:** anyone wants to move the threshold, or the quiet chip starts
firing on healthy work. Then the first question will be "where did 7500 come from?"
— and the answer must not be "a probe someone ran once."

---

## Parked — devnet on-chain CI

Parked by Mr. McRitchie on 2026-07-14. **These two remain live board tasks** by his
explicit decision — the only parked items that do — because they may belong to a
concurrent CI/CD session.

- **`build-devnet-e2e-lane`** — turf-vault, the Anchor program that moves real
  money, has **zero CI**: no `.github/workflows` at all.
- **`enable-or-delete-devnet-nightly`** — `devnet-nightly.yml` has **never once
  executed.** It gates on `if: vars.DEVNET_NIGHTLY_ENABLED == true`, and all 30
  scheduled runs since 2026-06-14 completed `skipped`. The `@devnet` on-chain e2e
  specs therefore run **nowhere.**

**The decision they wait on is not technical:** either fund a devnet bot key so the
lane is real, or delete the workflow so its absence is honest. That is Mr.
McRitchie's call, and it costs money either way.

## release-gate-orphans-its-suite — 9 unlanded local commits (2026-08-08)

The archived task's desk held nine commits diverged from its pushed branch,
preserved as tag `archive/release-gate-orphans-its-suite-local` (`f32687e4`)
during the stale-desk sweep. **Six of the nine already landed on `release`;
three are absent:** `f32687e4`, `bf36425e`, `58eda198`. **Orphaned-fix review
owed on those three:** diff their ideas against current `release` and either
point at the code that superseded them or land what didn't. See the clean-up
SOP's "stale unmerged desks" protocol.

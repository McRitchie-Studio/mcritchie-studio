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

# G1 — the builder's optional pre-flight

## Status: Active (rewritten 2026-09-24, DevOps v3 phase 2b)

G1 is the first of the branded testing gates in the devops pipeline, and since
`retire-local-cert-evidence` it is the **builder's optional local pre-flight**,
nothing more: `bin/fast-check` runs the tests the branch diff maps to, the core
spine, and rubocop on the changed files, prints its result, and **records
nothing**. The one verdict per tree is the PR's **settled GREEN GitHub CI**,
which [DoR](dor.md) reads at the submit seam and review's gate-zero reads
again. G1 buys earliness — catch the obvious break in about a minute, before
the push and the ten-minute CI round-trip — and nothing else.

The gate flow order: **G1 pre-flight** (this doc) → [DoR](dor.md) →
[G2 Review](g2-review.md) → [G3 Candidate](g3-candidate.md) →
[G4 Ship](g4-ship.md).

## What changed, and why

Until 2026-09-24 this page described a **certification**: `bin/fast-check` and
`bin/full-suite-check` fingerprinted the working tree, stamped a receipt on the
task, opened and closed a `g1_cert` GateRun, and refused a wrong, dirty, or
orphan-holding tree so the receipt could be trusted. `bin/dor-check` stopped
reading those receipts on 2026-09-24 (`dor-reads-settled-ci-verdict`, phase 2a
of DevOps v3), and stale receipts had been the largest DoR failure cause (439
builder-side and 337 review-side refusals). Phase 2b removed the machinery that
produced them: `bin/full-suite-check`, the fingerprint receipts, the bypass and
deferral hatches, the cert root/tree/orphan guards and their runlock, and the
`g1_cert` gate emits. What survives is listed under *What still holds* below.
The design rationale is `docs/agents/system/devops-v3-design.md`, sections 5
and 7 ("Certs and evidence").

## Who runs it

The **feature (builder) agent**, from the task worktree — by hand, or through
`bin/ship`, which runs it at step 2/8 and **carries on whatever it says**. A red
pre-flight is printed loudly there because it almost always means a red CI ten
minutes later; it is not a refusal. `SHIP_PREFLIGHT=off` skips it.

## Procedure

```bash
cd <desk>
/Users/alex/projects/mcritchie-studio/bin/fast-check <task-slug>
/Users/alex/projects/mcritchie-studio/bin/fast-check <task-slug> --list   # the selection, no run
```

It is a hub script (`mcritchie-studio/bin` alone), so name it by its absolute
path from a satellite or gem desk, standing in that desk.

Lanes, in order:

- `test-prepare` — `bin/rails db:test:prepare test:prepare` (abort on red).
  Both tasks in one boot: the test DB, and Rails' `test:prepare` hook, which
  builds the gitignored `app/assets/builds/tailwind.css`. The lanes below pass
  explicit test paths, and Rails skips its own `test:prepare` whenever an
  argument looks like a path. A red here is usually an ENV gap, not your diff —
  but a broken stylesheet in your diff fails it too. A runner that is simply not
  in this checkout prints `COULD NOT RUN` and names the fix: a `release_check:`
  on the repo's row in `config/release_repos.yml`.
- **A registry-gated repo runs its declared gate instead.** A gem, or an `apps`
  row that declares `release_check:` (turf-vault), has no `bin/rails` and no
  diff-mapped subset: the declared command (`bin/release-check` for all three
  today) runs as the whole lane, the prepare lane does not apply, and there is
  no rubocop lane. `bin/lib/release_registry.rb` reads the declaration; nothing
  probes a tree for a runner.
- `mapped-tests` — `bin/rails test <files the diff maps to>`: path convention,
  a tool's test family, then a grep for the subject's identity
  (`bin/lib/fast_cert.rb`). Past the cap (15 after the spine dedupe,
  `FAST_CHECK_MAPPED_CAP`) the lane falls back to the convention twins, or to
  the spine alone, and says so; near the cap it warns one run early.
- `spine` — `config/fast_cert_spine.yml`, the always-run core (~10-20s). It is
  anchored in the hub, so a satellite checkout resolves none of it.
- `rubocop-changed` — `bin/rubocop <changed lintable files>`, never the whole
  repo.

Exit 0 means every lane that ran is green — including a run where **no test
lane ran at all** (a diff that maps to nothing on a checkout with no spine),
which the script says out loud: CI runs the full suite on the PR either way.
Exit 1 means a lane was red, hung (`FAST_CHECK_LANE_TIMEOUT`, default 900s —
reported as a hung runner, never as a red suite), or could not launch, or the
run was refused before any lane ran.

## What still holds

- **The tree check.** Given a task slug and no `FAST_CHECK_ROOT`, the run
  refuses a root that is not the task's tree — its branch, or its desk in either
  layout (`<repo>/.worktrees/<slug>`, `<repo>.worktrees/<slug>`) — and names the
  desk to `cd` into (`bin/lib/task_tree.rb`). A pre-flight of an unrelated tree
  tells you nothing about your diff, and reads as green.
- **The desk guard.** A desk whose test database resolves to the repo's
  **shared** one is refused before any lane runs (`bin/lib/desk_guard.rb`): the
  prepare lane would reset that database under every concurrent suite.
- **The process group.** Each lane runs in its own process group and a signal
  aimed at the pre-flight reaps the lane with it (`bin/lib/lane_runner.rb`), so
  a harness timeout does not leave `bin/rails test` holding the desk's test DB.
- **The control lane.** The `test-only` shape still owes `bin/control-check`,
  which is not a cert: it replays the pre-change tests and stamps the one
  fingerprint-bound line the DoR verdict still grades, `[control@<fp>]`.

A dirty tree is **not** refused any more — nothing is stamped, so there is
nothing to stamp wrong.

## UI surfaces

The task's "Testing gates" card still carries a G1 chip keyed `g1_cert`. Nothing
writes that gate since 2026-09-24, so on a task built after that date it reads
as not run; the CI meter on the board card is the live signal.

## Background — not needed to execute

- The design: `docs/agents/system/devops-v3-design.md` §5 (the rigor protocol)
  and §7 (the guard catalog, "Certs and evidence").
- Test selection: `bin/lib/fast_cert.rb`; the lane runner: `bin/lib/lane_runner.rb`;
  the registry read: `bin/lib/release_registry.rb`.

## Related

- [`dor.md`](dor.md) — the next gate; the DoR verdict (`bin/dor-check`) the
  builder runs at submit (`dor`) and the primary reviewer re-runs as gate-zero
  (`dor_review`, `--gate-role review`).
- [`g2-review.md`](g2-review.md) — the senior-review lanes that follow DoR.
- [`../building-sop.md`](../building-sop.md) — where the pre-flight sits in the
  builder's flow.

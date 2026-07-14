# G1 Cert — the builder's certification gate

## Status: Active

G1 Cert is the first branded testing gate of the devops pipeline: the
**builder's certification that the exact code being handed off is green**. It is
a **task-grain** gate (GateRun key `g1_cert`) owned by the feature agent, run
from the task's worktree. It is a **self-closing cert**: `bin/fast-check` or
`bin/full-suite-check` OPEN and CLOSE the `g1_cert` attempt themselves (green →
success, red → failed). The Definition-of-Ready verdict (`bin/dor-check`) is a
**separate** gate now — see [`dor.md`](dor.md) — so G1 Cert is exactly the local
test/lint cert, nothing else.

The gate flow order: **G1 Cert** (this doc) → [DoR](dor.md) →
[G2 Review](g2-review.md) → [G3 Candidate](g3-candidate.md) →
[G4 Ship](g4-ship.md).

## What this gate verifies

- The shape's **DoR test tiers** are green, tier-tagged in `devops.checks_run`
  (`[unit] …`, `[integration] …`, per `config/feature_shapes.yml`).
- The **suite evidence** proves the tree being shipped is certified, via one of
  three routes (all fingerprint-bound to a git TREE hash, so a stale or partial
  record is refused):
  - **fast** (the builder default) — a fresh `[fast-cert@<fp>]` line from
    `bin/fast-check`, credited alongside a **GREEN GitHub CI** (CI runs the
    full suite + `test:system` on every PR push, so the full net still runs).
    Submit-side it is also credited **PROVISIONALLY** while the open PR's CI is
    still pending / not yet reported — see "The CI seam" below.
  - **full** — fresh `[full-suite@<fp>]` + `[rubocop@<fp>]` lines from
    `bin/full-suite-check`. Accepted on its own, CI-independent.
  - **bypass** — a `[full-suite-bypass] <reason>` checks_run line. Honored but
    flagged loudly; a conscious, justified skip only.

The suite evidence, required metadata, and the PR's GitHub CI are checked by the
`dor-check` **verdict** — but that verdict now closes the separate **DoR** gate
([`dor.md`](dor.md)), not this one. G1 Cert is purely the local cert lanes.

## Who runs it

The **feature (builder) agent**, from the task worktree. The cert opens AND
closes `g1_cert` on its own — no reviewer ever touches this gate. (The primary
reviewer's gate-zero re-runs `dor-check --gate-role review`, but that lands on
the [DoR review](dor.md) gate `dor_review`, not here.)

## Procedure

Run everything from the task worktree. Order matters: **final commit → cert →
push → open the PR → dor-check → submit** (the cert fingerprint is a tree
hash; committing after the cert makes it stale — and the fast route's
provisional credit needs the PR open, so the verdict runs last, with **no CI
wait** before `submitted`).

The worktree rooting is **enforced**: given a task slug, both cert runners
verify the cwd's checkout IS the task's tree (its branch, or its
`.worktrees/<worktree_slug>` dir) and **refuse** otherwise — a run from the
wrong checkout (e.g. the hub primary on `main`) exits 1 naming the worktree to
`cd` into instead of green-certifying an unrelated tree
(`bin/lib/cert_root_guard.rb`).

Both cert runners open with an **orphan preflight** (`bin/lib/cert_orphan_guard.rb`)
before any lane runs. A cert that outran its harness timeout leaves its
`bin/rails test` grandchild alive, holding the worktree's test DB — and every
retry then dies in test-prepare on `PG::ObjectInUse`, so the retry path recreates
the deadlock and the agent can never dig out (live, 2026-07-13: three attempts,
35 minutes, zero board progress). Each cert therefore leaves a runlock naming its
process group **and that group's OS start time**, and the next cert reads it:

| It finds | It does |
|----------|---------|
| a suite whose start time **matches** the runlock | **reaps** the group, names it, continues |
| a **live** sibling cert | **refuses** — two suites on one test DB SIGSEGV Ruby |
| the pgid **recycled** onto a stranger | **never kills it**; discards the lock, continues |
| a group it **cannot prove** is ours | **refuses** and names what is alive — a human decides |
| a **malformed** lock (names no integer pid/pgid) | **clears it** loudly and continues — it names nobody, so there is nobody to kill; the DB backstop speaks for a real orphan |
| a lock naming group **0 or 1** | **refuses** and leaves the lock — the lock is corrupt, no cert ever ran in those groups, and no kill would be correct. `rm` it yourself |
| a reap it **could not perform** (the suite outlived TERM+KILL, or its identity stopped matching under us) | **refuses, and KEEPS the runlock** — the lock is the only record naming that process. It offers a kill **only** when the group is still provably ours; against a stranger it offers `rm <lock>` and an `inspect` line, never a kill |

An exit-1 from the preflight is an **ENV refusal, not a red diff** — it names the
pid and the DB. Never `rm` the runlock to get past a refusal you have not read: it
is naming a process that is still holding your database.

**Every kill the cert prints is a kill it would fire.** The command in a refusal is an
instruction — it gets pasted into a shell exactly as printed — so the copy is gated on
the same predicate as the trigger (`CertOrphanGuard.reapable?`): signalable **and**
provably ours, re-proved at the moment of emission. When the guard cannot prove the
group is ours it prints **no kill at all**, because none would be correct. If you ever
see the cert suggest a kill it did not itself attempt, that is a bug — report it.

**The runlock lives in the repo's git dir** (`<git-dir>/cert-run.json`; in a worktree
that is `.git/worktrees/<name>/`, so each desk keeps its own), **never in the working
tree**. It has to: the lock's job is to SURVIVE a SIGKILLed cert, so a lock inside the
tree is an untracked file in any repo that does not ignore `tmp/` — studio-engine and
turf-vault do not — and the cert **refuses a dirty tree**. The next cert would abort
`DIRTY` on the guard's own artefact, the orphan preflight would never run, and the
deadlock above would be back, permanently. Keeping the lock out of the tree makes that
impossible by construction rather than by every repo remembering to ignore `tmp/`.

1. **Certify — fast route (default):**

   ```bash
   bin/fast-check <task-slug>
   ```

   Lanes, in order (each recorded on the gate as one executed-SOP entry):

   - `test-prepare` — `bin/rails db:test:prepare test:prepare` (abort on red —
     never certify against an unprepared test env). **Read the output; do not
     assume the cause.** A red here has three quite different meanings and
     guessing among them is what burned 35 minutes: `PG::ObjectInUse` is an
     ORPHANED suite holding your test DB (the preflight above names it — if it
     did not, say so, that is a guard gap); an asset error such as `The asset
     "tailwind.css" is not present` after a stylesheet change is a REGRESSION IN
     YOUR DIFF failing the asset build; a missing DB/role is a genuine env gap.
     Blaming "an ENV gap" by reflex is the reflex this gate exists to break.
     Both tasks, one boot: the test DB, and
     Rails' `test:prepare` hook, which is what BUILDS the gitignored
     `app/assets/builds/tailwind.css`. The lanes below pass explicit test
     paths, and Rails skips its own `test:prepare` whenever an argument looks
     like a path — so without this lane a fresh worktree red-flags every
     view-rendering test with `The asset "tailwind.css" is not present in the
     asset pipeline`. See `docs/agents/modules/testing.md`.
   - `mapped-tests` — `bin/rails test <files the branch diff maps to>` (path
     convention with a class-name grep fallback; skipped when nothing maps)
   - `spine` — `bin/rails test <config/fast_cert_spine.yml entries>` (the
     always-run critical core, ~10-20s)
   - `rubocop-changed` — `bin/rubocop <changed lintable files>` (never the
     whole repo; skipped when none)

   All lanes green stamps one `[fast-cert@<fp>]` line into `checks_run`,
   merged with the existing list (tier tags and full-suite evidence are
   preserved; only a prior fast-cert line is replaced). A skipped lane is
   recorded as a pass with a `skipped: <why>` command — considered, not lost.

   Preview without writing anything: `bin/fast-check <task-slug> --print`
   (also skips every gate/board write). `--list` prints the selected test
   files and exits.

2. **Or certify — full route** (when CI can't vouch, or for release-grade
   verification):

   ```bash
   bin/full-suite-check <task-slug>
   ```

   Lanes: `test-db-reset` (`bin/rails db:test:purge db:test:prepare`),
   `full-suite` (`bin/rails test`, the ENTIRE suite), `rubocop` (`bin/rubocop`,
   the whole repo). Green lanes stamp `[full-suite@<fp>]` + `[rubocop@<fp>]`.

3. **Record the tier tags as you built** — in either order, before or after you
   certify:

   ```bash
   bin/task update <task-slug> --checks "[unit] ..." --checks "[integration] ..."
   ```

   `checks_run` holds two namespaces, and each side preserves the other's:

   - **You own the tier tags** (`[unit] …`, `[integration] …`, a
     `[full-suite-bypass] <why>` record). `--checks` REPLACES those — pass every
     tag you want kept. The cert tools never touch them.
   - **The cert tools own the evidence** (`[full-suite@<fp>]`, `[rubocop@<fp>]`,
     `[fast-cert@<fp>]`). `--checks` **cannot** drop those: any lane your update
     does not itself supply is carried forward, by the CLI and by the board
     (`lib/cert_evidence.rb`). Recording your test plan after certifying used to
     wipe the cert and make `bin/dor-check` report `full-suite: MISSING` on
     freshly certified code — it no longer can.

   A lane is superseded only by a line FOR that lane, which is what a re-cert
   writes. Never hand-write a `[<lane>@<fingerprint>]` line: that forges a
   certification, and the fingerprint exists to make the cert mean something.

4. **Verdict — the DoR gate** (its own gate; closes `dor`, not `g1_cert`):

   ```bash
   bin/dor-check <task-slug>
   ```

   Deterministic, no judgment: shape tiers, required metadata, suite evidence
   (fast/full/bypass), post-deploy nudges, and the PR's real GitHub CI. Exit 0
   = ready to advance `submitted → reviewed` — **without waiting for CI**: a
   fresh fast cert with CI still pending on the open PR is credited
   provisionally (a red CI still refuses; a fast cert with NO open PR is
   refused — push and open the PR first, then run the verdict). Full mechanics:
   [`dor.md`](dor.md).

## Success, failure, and attempt semantics

One GateRun row = one **attempt** (`started_at → finished_at`, `success`,
`sops`). Retries are first-class: a failed attempt closes and the re-run opens
attempt n+1 — repeated cert failures are visible signal, never one collapsed
window.

- `bin/fast-check` / `bin/full-suite-check` **OPEN** the task's `g1_cert`
  attempt at start and append one SOP entry per lane
  (`{sop, cmd, result, duration_ms}`).
- A **red lane closes the attempt `failed`** (the re-run opens attempt n+1) —
  a red test-DB lane short-circuits the cert on the spot; a red mapped / spine
  / rubocop lane still lets the remaining lanes run, and the `failed` close
  lands once the lanes finish. Either way nothing is certified; no evidence
  line is written.
- A **green cert CLOSES the attempt `success`** ITSELF — the cert owns the whole
  `g1_cert` window (open + close). `dor-check` no longer touches `g1_cert`; its
  verdict is the separate [DoR](dor.md) gate.
- **Never emitted:** `--print` cert runs. All gate writes are fire-and-forget —
  a board blip never changes a verdict or an exit code.

The Definition-of-Ready verdict semantics — the `dor` / `dor_review` attempts,
their `dor-check` / `tiers` / `full-suite-evidence` / `ci` SOPs, the
submit-before-CI-settles credit, and the `--gate-role` split — now live in
their own gate doc: [`dor.md`](dor.md).

## The CI seam — submit before CI settles

The CI **wait** belongs to the review handoff, not the builder's wall-clock — but
that is the **DoR gate's** concern (the cert itself is CI-independent). The
builder certs (this gate), opens the PR, runs the dor-check verdict (the DoR
gate), and moves the task `submitted` **immediately** without waiting for CI.
Full CI-seam mechanics — provisional fast-cert credit, the review-side gate-zero,
and the bounce round-trip — are in [`dor.md`](dor.md).

## UI surfaces

- **Task gates card** — the "Testing gates" card on
  `https://mcritchie.studio/tasks/<slug>` renders the G1 Cert chip: latest
  attempt (`attempt ×n` retry badge), passed / failed / in-flight status, and
  the expandable per-lane SOP list with ✓/✗ and durations.
- **CLI read:** `bin/gate show task <task-slug>` (add `--json` for the raw
  attempts).

## Background — not needed to execute

- The 90/10 rethink behind the fast route, the fingerprint mechanics, and the
  CI-status gate: `docs/agents/system/devops-cycle-design.md` §3.3.
- Evidence format + fingerprint implementation: `bin/lib/full_suite_gate.rb`;
  test selection: `bin/lib/fast_cert.rb`.
- **Disarm switches — for the harness only, never for a wedge.**
  `FAST_CHECK_SKIP_ORPHAN_GUARD=1` (`bin/fast-check`) and
  `FULL_SUITE_SKIP_ORPHAN_GUARD=1` (`bin/full-suite-check`) skip the orphan
  preflight entirely. They exist so the guard's OWN test suite can spawn certs
  without each one refusing against its siblings. **Do not reach for them to get
  past a refusal**: the refusal is naming a live process holding your test DB,
  and skipping it just walks you back into `PG::ObjectInUse` with the evidence
  suppressed. `CERT_GUARD_PS` / `CERT_GUARD_PSQL` likewise exist to inject
  fixtures in tests, not to steer a real cert.

## Related

- [`dor.md`](dor.md) — the next gate; the DoR verdict (`bin/dor-check`) the
  builder runs at submit (`dor`) and the primary reviewer re-runs as gate-zero
  (`dor_review`, `--gate-role review`).
- [`g2-review.md`](g2-review.md) — the senior-review lanes that follow DoR.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface `bin/gate` posts through.

# G1 Cert — the builder's certification gate

## Status: Active

G1 Cert is the first branded testing gate of the devops pipeline: the
**builder's certification that the exact code being handed off is green**. It is
a **task-grain** gate (GateRun key `g1_cert`) owned by the feature agent, run
from the task's worktree, and it spans local certification (`bin/fast-check` or
`bin/full-suite-check`) through the merge-gate verdict (`bin/dor-check`).

The four gates in order: **G1 Cert** (this doc) → [G2 Review](g2-review.md) →
[G3 Candidate](g3-candidate.md) → [G4 Ship](g4-ship.md).

## What this gate verifies

- The shape's **DoR test tiers** are green, tier-tagged in `devops.checks_run`
  (`[unit] …`, `[integration] …`, per `config/feature_shapes.yml`).
- The **suite evidence** proves the tree being shipped is certified, via one of
  three routes (all fingerprint-bound to a git TREE hash, so a stale or partial
  record is refused):
  - **fast** (the builder default) — a fresh `[fast-cert@<fp>]` line from
    `bin/fast-check`, credited **only alongside a GREEN GitHub CI** (CI runs the
    full suite + `test:system` on every PR push, so the full net still runs).
  - **full** — fresh `[full-suite@<fp>]` + `[rubocop@<fp>]` lines from
    `bin/full-suite-check`. Accepted on its own, CI-independent.
  - **bypass** — a `[full-suite-bypass] <reason>` checks_run line. Honored but
    flagged loudly; a conscious, justified skip only.
- The task's **required metadata** is populated and, on the merge gate, the PR's
  **GitHub CI** is green (a red, still-running, or closed/merged PR is refused).

## Who runs it

The **feature (builder) agent**, from the task worktree. The primary reviewer
re-runs the same dor-check as review's gate-zero, but with
`--gate-role review` so the verdict lands on [G2a](g2-review.md) instead of
closing this gate — see "Gate roles" below.

## Procedure

Run everything from the task worktree. Order matters: **final commit → cert →
dor-check → push** (the cert fingerprint is a tree hash; committing after the
cert makes it stale).

1. **Certify — fast route (default):**

   ```bash
   bin/fast-check <task-slug>
   ```

   Lanes, in order (each recorded on the gate as one executed-SOP entry):

   - `test-db-prepare` — `bin/rails db:test:prepare` (abort on red — never
     certify against a broken test DB)
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

3. **Record the tier tags as you built** (both cert tools preserve them):

   ```bash
   bin/task update <task-slug> --checks "[unit] ..." --checks "[integration] ..."
   ```

4. **Verdict — the merge gate:**

   ```bash
   bin/dor-check <task-slug>
   ```

   Deterministic, no judgment: shape tiers, required metadata, suite evidence
   (fast/full/bypass), post-deploy nudges, and the PR's real GitHub CI. Exit 0
   = ready to advance `submitted → reviewed`. A fresh fast cert with CI still
   pending/red is refused with the exact wait-or-certify-in-full guidance.

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
- A **green cert leaves the attempt OPEN** — the cert alone is not the verdict.
- `bin/dor-check`'s merge-gate run (builder role) **CLOSES the open attempt**
  with `success = ready`, attaching its verdict evidence as SOPs: `dor-check`,
  `tiers` (the shape's tier list), `full-suite-evidence`
  (`certified@<fp12>` or `fast-cert@<fp12>+ci-green`), and `ci`
  (pass / fail / unverified).
- A dor-check verdict with **no open attempt** still records a real,
  self-contained attempt (`started_at == finished_at`) — a lone verdict is an
  attempt too.
- **Never emitted:** `--print` cert runs, and dor-check with `--json`
  (read-only monitors), `--file` (offline evaluation), or `--gate build` (no
  cert exists yet). All gate writes are fire-and-forget — a board blip never
  changes a verdict or an exit code.

## Gate roles (`--gate-role`)

`bin/dor-check <slug>` defaults to `--gate-role builder`: the verdict closes
G1. The **primary reviewer's gate-zero** re-run must not close the builder's
gate, so it runs:

```bash
bin/dor-check <task-slug> --gate-role review
```

That appends the verdict as a `dor-check` SOP on the task's **open G2a Primary
attempt** instead ([g2-review.md](g2-review.md) owns that gate's close).

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

## Related

- [`g2-review.md`](g2-review.md) — the next gate; its primary re-runs this
  gate's dor-check as gate-zero (`--gate-role review`).
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface `bin/gate` posts through.

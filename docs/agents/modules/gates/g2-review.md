# G2 Review — the two-lane senior review gate

## Status: Active

G2 Review is the second branded testing gate: the **2-senior review** of a
submitted PR, recorded as **two task-grain lanes** — **G2a Primary** (GateRun
key `g2a_primary`, the deep review that owns the gates and drives the verdict)
and **G2b Light** (key `g2b_light`, the focused second read). **Carl** (the
`pr-review` owner — one Carl per PR) owns both lanes' open and close; the light
fills its own.

The gate flow order: [G1 Cert](g1-cert.md) → [DoR](dor.md) → **G2 Review**
(this doc) → [G3 Candidate](g3-candidate.md) → [G4 Ship](g4-ship.md).

## What this gate verifies

- **The live GitHub CI** — G2 owns the **authoritative CI verdict**
  (`ci-gate-review-handoff`: builders submit without waiting for CI). The
  review session claims only green-CI PRs and Carl's gate-zero re-checks CI: red bounces the
  task back naming the failing checks (no reviewer tokens burned), a
  merge-conflicted PR (`mergeStateStatus DIRTY`) bounces back too with
  "merge the PR's base in and resolve" named (its CI is never coming — GitHub can't compute
  the merge commit), a **ci-less** PR (zero check-runs plus a *refuted* merge)
  bounces back with "merge the base in and resolve" named, pending defers to a
  later wave, green proceeds.
- **G2a Primary** — the deep review: diff vs. acceptance, the shape's DoR
  tiers + suite evidence + CI (the **gate-zero** re-run of dor-check, which
  keeps the strict red/pending-both-block semantics and records on the separate
  [`dor_review`](dor.md) gate), domain checklist, code standards, merge safety,
  docs. The primary drives the verdict.
- **G2b Light** — a focused second read through the light reviewer's domain
  lens. No gates, no verdict-drive — but any reviewer can block on a defect.

Each lane's verdict comes from its reviewer's **scout report**:
`merge-ready` passes the lane; `request-changes`, `wait-for-ci`, and
`conductor-review` fail it (the outcome rides in the gate's metadata).

## Who runs it

- **Carl** (the review owner — `bin/pr-review` runs Carl's `pr-review` /
  `pr-review-slow` acts) opens both lanes as the pair launches and
  closes each lane from its own reviewer's scout report. There is no Avi
  supervisor.
- **Carl, the primary reviewer,** runs the gate-zero
  (`bin/dor-check <slug> --gate-role review`), which opens+closes the separate
  [`dor_review`](dor.md) gate.
- A **hand-run review** (a conductor reviewing one PR manually) posts the same
  markers itself with `bin/gate` — see "Manual path" below.

## Review-session path (the default)

```bash
cd /Users/alex/projects/mcritchie-studio
bin/pr-review --run --fast --max-idle-cycles 1 \
  --codex-workdir /Users/alex/projects/mcritchie-studio
```

What the review session records, per reviewed task:

0. **Claim-time + gate-zero CI check** — the session only claims green-CI PRs
   (`bin/task claim-next-review`), and Carl's gate-zero re-reads the PR's live CI
   mid-review (`bin/lib/ci_status.rb`):
   - **red** → `bin/task block <slug> --kind rework` with the failing checks
     named, and the bounce recorded as a **failed `dor_review` (gate-zero)
     attempt** with a `ci` SOP (`--meta outcome=ci-red`, actor `carl`) — not a
     G2 review lane. No further reviewer tokens burned.
   - **conflicted** (`mergeStateStatus DIRTY`) → the same block-back shape
     (`--meta outcome=ci-conflicted`), with "merge the PR's base in and resolve"
     named as the fix. A conflicted PR gets **no CI at all** — GitHub cannot compute the
     merge commit — so deferring "until CI reports" would strand it in
     `submitted` forever (the PR-#509 stall, 2026-07-12).
   - **ci-less** (zero check-runs **and** a *refuted* merge) → the same
     block-back shape (`--meta outcome=ci-less`), with "merge `origin/<base>` in
     and resolve" named (merge, not rebase — a halted merge leaves the branch
     untouched). A base that drifted past GitHub's merge computation gets no CI
     either, and never reads `DIRTY`, so it presents exactly like a slow CI.
     **Only an affirmative negative counts** — GitHub reporting the merge is
     refused. It answers `UNKNOWN` while it is still computing mergeability, and
     a fresh head SHA has zero checks in that same window, so an **undetermined**
     merge is reported as a wait that names its uncertainty and is NEVER
     converted into a block: running out of patience is not evidence. A settled
     `mergeStateStatus` also outranks a lagging `mergeable`. Uncertainty falls
     toward wait; a wrong block would force-push a healthy branch.
   - **pending / no checks yet** → the task defers to a later wave (the
     defer machinery); no lane opens.

   All three gate-zero bounces are **MECHANICAL** — a red pipe, not a
   disagreement — so when the two-bounce circuit breaker refuses one on an
   already-bounced task (`bin/task block --kind rework` exits **10**), re-run it
   with `--breaker-ack "red CI, mechanical"`. Escalation is for review deadlocks;
   a broken build is not one, and the acknowledgment is recorded on the row.
   - **green** → proceed. (An unverified gh read, or a missing/closed PR,
     also proceeds — the primary's strict gate-zero is the backstop.)
1. **Open** — as the primary+light pair launches, it opens both lanes
   (attempt-aware; a still-open lane from a deferred wave is reused):
   `bin/gate open task <slug> g2a_primary --actor <primary-soul>` and
   `bin/gate open task <slug> g2b_light --actor <light-soul>`.
2. **Gate-zero** — Carl opens the `dor_review` gate as he proceeds
   past the CI check, and runs

   ```bash
   bin/dor-check <task-slug> --gate-role review
   ```

   which opens+closes the **`dor_review` gate** with its verdict (its OWN gate —
   see [`dor.md`](dor.md) — never touching the builder's G1 Cert or the G2 review
   lanes; that is exactly what the `--gate-role review` flag exists for).
3. **Close** — after both reviewers return, each lane closes from **its own
   reviewer's latest scout report**: `merge-ready` → `--success`; any other
   outcome → `--failed`, with a `scout-report` SOP and the outcome in
   metadata (`--meta outcome=<outcome>`). A reviewer with **no report leaves
   its lane in flight** — the next wave's open reuses the same attempt.

The task-level outcome is separate from the lanes: Carl's deep read + the light's
merge-ready report → **Carl merges the feat PR into `accepted`** (the
accepted-ladder's first rung), stamps `merged: "accepted"`, then moves the task
`reviewed` (invariant: `reviewed` ⟺ code-on-`accepted`; a merge failure leaves it
`submitted`); any `request-changes` → the task is blocked for rework (a `building`
attribute — `bin/task block` stamps `blocked_at`/`block_kind` and lands it on
`building`, not a `blocked` stage); `wait-for-ci` / `conductor-review` / a missing
report → deferred and re-queried. A `request-changes` is spent only on a
**reachable regression** (correctness / security / data-loss / acceptance miss);
zap-scale findings are fixed forward, advisory findings ride as notes, and a
second rework block escalates to the operator as `--kind dependency` instead of
re-bouncing — the full rubric lives in the review SOPs.
See Carl's
[`pr-review.md`](../../agents/carl/sops/pr-review.md) for the full verdict
handling.

## Manual path (one PR by hand)

When you supervise a single review yourself (the
[`pr-review-sop.md`](../pr-review-sop.md) `review-one` primitive), post the
same markers:

```bash
# as the pair launches
bin/gate open task <task-slug> g2a_primary --actor <primary-soul>
bin/gate open task <task-slug> g2b_light --actor <light-soul>

# the primary's gate-zero (inside its review)
bin/dor-check <task-slug> --gate-role review

# close each lane from its reviewer's verdict
bin/gate close task <task-slug> g2a_primary --success --actor <primary-soul> \
  --sop-json '{"sop":"scout-report","result":"pass"}' --meta outcome=merge-ready
bin/gate close task <task-slug> g2b_light --failed --actor <light-soul> \
  --sop-json '{"sop":"scout-report","result":"fail"}' --meta outcome=request-changes
```

## Success, failure, and attempt semantics

- One GateRun row per lane per **attempt**. A resubmitted task's re-review
  opens **attempt n+1** on each lane — repeat review round-trips are visible
  signal.
- Lane success = that reviewer reported `merge-ready`. Lane failure = any
  other outcome; the specific outcome rides in `metadata.outcome`.
- An **uncleared attempt is still an attempt**: a lane closed `failed` stays
  on the record; the re-review opens the next attempt.
- A **gate-zero CI bounce** records as a failed `dor_review` (gate-zero) attempt
  (a `ci` SOP, `outcome=ci-red`, actor `carl`) — the round-trip is visible on the
  gates card even though no reviewer ran, and it lands on the gate-zero gate, not
  a G2 review lane. A pre-spawn **defer** (CI pending) records nothing; nothing
  started.
- A **reportless lane stays in flight** (no verdict yet) and is reused by the
  next wave rather than double-opened — `GateRun.open!` converges racing
  openers onto one row.
- All gate writes are **fire-and-forget** (`bin/pr-review` discards `bin/gate`
  failures): a board blip never breaks the review loop. Dry-run
  (`bin/pr-review` without `--run`) prints the would-run gate writes without
  posting them.

## UI surfaces

- **Task gates card** — the "Testing gates" card on
  `https://mcritchie.studio/tasks/<slug>` renders the G2a Primary and G2b
  Light chips beside G1 Cert and the two DoR chips: latest attempt (`×n` badge),
  status, and the expandable `scout-report` SOP list (the gate-zero dor-check
  now records on the separate `dor_review` chip, not on G2a).
- **Deployments tracker note** — the review wave does NOT touch the release
  timeline: the next candidate doesn't exist until qa-release starts assembling,
  so the wave no longer posts `testing/start` (it would 404 / mint an empty
  ghost). Pizza-tracker **node 1 (Testing)** greens on its own once qa-release's
  first sweep stamps `assembling`. Node 1 ≈ the G2 wave conceptually; the gate
  chips record the verdicts, the tracker stamps record the stages — two surfaces,
  never merged.
- **CLI read:** `bin/gate show task <task-slug>`.

## Related

- [`../../agents/carl/sops/pr-review.md`](../../agents/carl/sops/pr-review.md) —
  Carl's review SOP whose waves produce this gate's records.
- [`../../agents/carl/sops/pr-review-primary.md`](../../agents/carl/sops/pr-review-primary.md)
  / [`pr-review-light.md`](../../agents/carl/sops/pr-review-light.md) — the two
  lane role SOPs.
- [`../pr-review-sop.md`](../pr-review-sop.md) — the `review-one` primitive
  (the manual path above is its gate-record half).
- [`dor.md`](dor.md) — the DoR gate; its `dor_review` half is this gate's
  gate-zero (`bin/dor-check --gate-role review`), opened by Carl as he
  proceeds past CI.
- [`g1-cert.md`](g1-cert.md) — the builder cert gate that precedes DoR.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface.

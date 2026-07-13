# DoR — the Definition-of-Ready gate (builder + review gate-zero)

## Status: Active

DoR is the branded testing gate for the **Definition-of-Ready verdict**: the
deterministic `bin/dor-check` pass that decides whether a task is ready to
advance. It sits between [G1 Cert](g1-cert.md) (the local cert) and
[G2 Review](g2-review.md) (the senior review), and it is recorded as **two
task-grain gates** so the same check reads cleanly from both sides of the
`submitted` seam:

- **DoR (builder)** — GateRun key `dor`. The feature agent's verdict at submit.
- **DoR (review)** — GateRun key `dor_review`. The primary reviewer's gate-zero
  re-run, plus the supervisor's pre-spawn CI bounce.

The gate flow order: [G1 Cert](g1-cert.md) → **DoR** (this doc) →
[G2 Review](g2-review.md) → [G3 Candidate](g3-candidate.md) →
[G4 Ship](g4-ship.md).

This gate was split out of G1 Cert ("Option B", 2026-07-11): the cert now
self-closes its own `g1_cert` window, and CI stays a **handoff, not a gate**
(its verdict rides as a SOP inside DoR, never its own gate row).

## What this gate verifies

`bin/dor-check` is deterministic — no judgment, same inputs → same verdict:

- The shape's **DoR test tiers** are present and green, tier-tagged in
  `devops.checks_run` (`[unit] …`, `[integration] …`, per
  `config/feature_shapes.yml`).
- The **suite evidence** proves the tree being shipped is certified — a fresh
  fast-cert or full-suite line, fingerprint-bound to the git TREE hash (see
  [g1-cert.md](g1-cert.md) for the three routes).
- The task's **required metadata** is populated.
- The PR's **live GitHub CI** is not failing (a red or closed/merged PR is
  refused). CI is checked here but **never its own gate** — it records as a `ci`
  SOP on the DoR attempt.

## The exemption is earned by the DIFF, never by the `kind`

`kind: chore | cleanup | docs` **may** skip the shape/test-tier gate — but the
label alone buys nothing. The skip is earned only by an **observed doc-only
diff**, and the discriminator is a denylist (`bin/lib/code_diff.rb`), not an
allowlist:

- **Classify by file TYPE, never by directory.** There is no "`docs/` is safe"
  rule: a directory allowlist is prose-by-*assertion*, the same
  declaration-over-evidence bug one granularity down. `docs/agents/setup.sh` is
  mode 100755 and `rolio` ships `docs/build/workflow.js` — both **gate**.
- **Non-behavioral** — and the ONLY thing that skips: prose (`*.md`,
  `*.markdown`, `*.rdoc`), inert media (`*.png`, `*.svg`, `*.pdf`, …), and
  prose-by-convention basenames (`LICENSE`, `README.txt`, `CODEOWNERS`,
  `.gitignore`). Note `.txt` is **not** blanket prose — `public/robots.txt` is
  production-served. Every file in the diff must qualify; one behavioral file in
  an otherwise-docs diff gates the whole task.
- **Behavioral** — everything else, gated like a feature. That expressly includes
  `.github/workflows/*` (CI *is* behavior), `config/*.yml`, `Gemfile`/`.lock` (a
  dependency bump changes the resolved graph), `bin/*`, migrations, and `test/**`.
- **Fail-closed** — if the gate cannot OBSERVE a diff (unreadable repo, or a
  checkout that can't see the branch), it **enforces** the tiers rather than
  skipping. "We saw no code" is not "there is no code." At the merge gate the
  diff is read from the **PR's own file list** (`gh pr view --json files`) so the
  verdict is correct even from a reviewer's primary checkout, falling back to the
  local working tree for pre-PR builder runs. Only the **build** gate stays
  lenient on an empty diff (at design time no code exists yet, and it enforces no
  tiers anyway).
- **The skip is loud** — it names what it observed and where it came from
  (`doc-only diff (kind: chore): 7 file(s), none behavioral — … [source: PR
  files]`), so a wrong skip is visible in the transcript instead of hiding behind
  a bare `n/a`.

Why: a check you satisfy by DECLARING a `kind` rather than by EVIDENCE is not a
check — the same failure shape as the G4 registry-string inference (see
[the 2026-07-12 gate review](../../audits/release-gate-and-devops-process-review-2026-07-12.md)).
`kind` is a forecast made at task-creation time, **before the diff exists**;
nobody has to be malicious for it to be wrong. It was: PR #512 (`kind: chore`)
shipped `.github/workflows/ci.yml` and DoR printed "n/a → ready to advance".

## Who runs it

- **The feature (builder) agent**, from the task worktree, at submit —
  `bin/dor-check <slug>` (default `--gate-role builder`) → the **`dor`** gate.
- **The primary reviewer**, as review's gate-zero —
  `bin/dor-check <slug> --gate-role review` → the **`dor_review`** gate.
- **The `pr-review` supervisor**, which opens `dor_review` as it proceeds past
  its pre-spawn CI check, and closes it `--failed` directly on a CI-red bounce
  (no reviewer runs in that case).

## Procedure

### Builder side (the `dor` gate)

Run from the task worktree, after the final commit + cert + push + open PR (the
verdict runs LAST — see [g1-cert.md](g1-cert.md) for the ordering rationale):

```bash
bin/dor-check <task-slug>
```

Exit 0 = ready to advance `submitted → reviewed` — **without waiting for CI**.
The verdict opens+closes the `dor` gate with its evidence as SOPs.

### Review side (the `dor_review` gate)

The primary reviewer, inside its review:

```bash
bin/dor-check <task-slug> --gate-role review
```

This opens+closes the `dor_review` gate and keeps the **strict** CI semantics
(below). It never touches `g1_cert` or the G2 review lanes — that is exactly
what `--gate-role review` exists for.

## The CI seam — submit before CI settles

The CI **wait** belongs to the review handoff, not the builder's wall-clock
(`ci-gate-review-handoff`, 2026-07-09):

- **Builder side (`dor`, the default role):** a still-running CI is a **loud
  suggestion**, never a block. A fresh fast cert is credited **provisionally**
  while the open PR's CI is pending or not yet reported (the `ci` SOP records
  `pending`, the `full-suite-evidence` SOP records `fast-cert@<fp12>+ci-pending`).
  A **red** CI (or a closed/merged `pr_url`) still refuses, and a fast cert with
  **no PR at all** is refused — the provisional credit is anchored to an open PR
  whose CI will run.
- **Review side (`dor_review`, the authoritative verdict):** the `pr-review`
  supervisor checks the PR's live CI **before spawning reviewers** — red bounces
  the task back naming the failing checks (recorded as a failed `dor_review`
  attempt with a `ci` SOP), pending defers the wave — and the primary's gate-zero
  (`--gate-role review`) keeps the strict semantics: **red AND pending both
  block**, and fast evidence needs the settled green.

Net effect: nothing reaches a reviewer (or a merge) without a green CI, but the
builder never idles watching checks. Expect the bounce round-trip if you hand
off a PR whose CI then fails — that is the trade, priced in.

## Success, failure, and attempt semantics

One GateRun row = one **attempt** (`started_at → finished_at`, `success`,
`sops`). Retries are first-class: a failed attempt closes and the re-run opens
attempt n+1.

- The builder's verdict **opens then closes `dor`** with `success = ready`,
  attaching its evidence as SOPs: `dor-check`, `tiers` (the shape's tier list),
  `full-suite-evidence` (`certified@<fp12>`, `fast-cert@<fp12>+ci-green`, or the
  provisional `fast-cert@<fp12>+ci-pending`), and `ci` (pass / fail / **pending**
  / unverified).
- The reviewer's gate-zero **opens then closes `dor_review`** with the same
  evidence shape, under the strict CI semantics.
- The supervisor's **pre-spawn CI-red bounce** opens then closes `dor_review`
  `--failed` with a `ci` SOP (`--meta outcome=ci-red`, actor `avi`) — no reviewer
  runs, but the round-trip is visible on the gates card.
- **Never emitted:** dor-check with `--json` (read-only monitors), `--file`
  (offline evaluation), or `--gate build` (no DoR verdict yet). All gate writes
  are fire-and-forget — a board blip never changes a verdict or an exit code.

## UI surfaces

- **Task gates card** — the "Testing gates" card on
  `https://mcritchie.studio/tasks/<slug>` renders the **DoR (builder)** and
  **DoR (review)** chips between G1 Cert and the G2 lanes: latest attempt
  (`×n` retry badge), passed / failed / in-flight status, and the expandable SOP
  list (`dor-check`, `tiers`, `full-suite-evidence`, `ci`).
- **CLI read:** `bin/gate show task <task-slug>` (add `--json` for the raw
  attempts).

## Background — not needed to execute

- The Option-B split rationale and the CI-status handoff:
  `docs/agents/system/devops-cycle-design.md` §3.3.
- The verdict logic + evidence format: `bin/dor-check`,
  `bin/lib/full_suite_gate.rb`.

## Related

- [`g1-cert.md`](g1-cert.md) — the self-closing cert gate that precedes DoR and
  produces the suite evidence this gate reads.
- [`g2-review.md`](g2-review.md) — the senior-review lanes that follow; the
  primary's gate-zero IS this gate's `dor_review` half.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface `bin/gate` posts through.

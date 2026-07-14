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
- The PR's **live GitHub CI** is not failing (a red, closed/merged, or
  merge-conflicted PR is refused — `mergeStateStatus DIRTY` means GitHub can't
  compute the merge commit, so that PR's CI **never fires**; the fix is
  rebase/merge release). CI is checked here but **never its own gate** — it
  records as a `ci` SOP on the DoR attempt.

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

## The gate grades the TASK's tree — never the one you stand in

A cert's fingerprint is a git **TREE hash** (content-addressed), so a checkout
that is not the task's tree can **never** match a recorded cert. That does not
surface as "wrong root" — it surfaces as **`STALE`**, which reads as "you edited
since certifying" and sends you off to re-certify code that was already green.

Both lanes have been bitten:

- **Review** — reviewers run from the **primary** checkout by design, so
  `--gate-role review` roots the suite fingerprint at the **task branch's
  committed tree** (`origin/feat/<slug>^{tree}`).
- **Builder** — a builder-lane run from the wrong checkout had **no** such cure
  and false-read `STALE` for **6 of 6 tasks on 2026-07-14**, including certs 90
  seconds old. An agent that hits an unexplainable STALE *stops*, so the false
  STALE stranded finished tasks in `building` behind green PRs.

`bin/dor-check` now consults the **task-root guard**
(`bin/lib/cert_root_guard.rb` — the same guard `bin/fast-check` and
`bin/full-suite-check` already required; dor-check was the one command in the
family that never did). When the root is not the task's tree it resolves in this
order:

1. the task's **worktree** is on disk → re-root the whole gate there, and
   **announce it on stderr** (naming both roots: where you stood, where it went);
2. else its **branch** resolves in this repo → root the *fingerprint* at that
   branch's committed tree, and **announce that on stderr** too;
3. else → **refuse**, naming the problem, instead of grading a foreign tree and
   calling a fresh cert stale. The refusal is an `errors` entry (so it prints in
   the verdict, not as an stderr banner) and it lives in the **suite-gate** block
   — so a kind that is EXEMPT from the suite gate (chore/cleanup/docs) never
   reaches it and passes without a root complaint. That is not a fail-open: the
   diff those kinds are graded on comes from the **PR**, which is
   root-independent; they need no cert; and a task with no PR still fails closed
   as indeterminate.

**Resolve, not refuse — and never silently.** The cert *writers* refuse a wrong
root, and must: they **stamp** evidence about the tree they stand in, so a chdir
could green-cert a stale worktree while your real edits sat untested where you
ran from. `dor-check` **writes no evidence** — it grades what is already
recorded — so re-rooting cannot forge a cert; it can only make the gate judge
the right code. But a *silent* chdir is its own hazard (a gate quietly judging a
different tree than the one you are looking at is how you end up arguing with a
verdict), so **both re-rooting arms announce both roots**.

**A real STALE now names its cause** — and names it *accurately*. The refusal
prints the fingerprint **delta**: what the evidence was certified for, and what
the code is now. The invariant is that **the root it names is the root it
hashed**, so recomputing the named root returns the printed hash:

| the gate hashed | it names | recompute it with |
|---|---|---|
| a **working tree** (the normal builder run) | that path | `bin/dor-check <task> --suite-fingerprint` |
| a **branch tree** (the `--gate-role review` lane *always*; and remedy 2 above) | the ref expression, e.g. `origin/feat/<slug>^{tree}` | `git -C <repo> rev-parse origin/feat/<slug>^{tree}` |

This distinction is load-bearing. Under an override, the checkout you are
standing in **never produced the hash** and hashes to a different number
entirely — so printing it beside the fingerprint (as the first cut of this
message did) sends the reader to the wrong tree with the authority of a precise
hash. A confident wrong root is worse than the opaque `STALE` it replaced. Note
also that the working-tree fingerprint is the **as-if-committed** tree —
uncommitted edits included, which is usually *why* it moved — so it is
deliberately **not** called `HEAD`: `git rev-parse HEAD^{tree}` will not
reproduce it.

`--json` carries the same facts machine-readably: `code_root` (the checkout the
**diff** was read from) plus `full_suite.fingerprint`, `.fingerprint_root`,
`.fingerprint_repo`, `.fingerprint_source` (`working-tree` | `branch-tree`), and
`.recorded`. `code_root` is *not* the fingerprint's root under an override —
that is precisely why the provenance travels with the fingerprint instead.

`DOR_CHECK_DIFF_ROOT=<path>` bypasses the guard: that is the caller **declaring**
a root (the CI/test seam), exactly as `FAST_CHECK_ROOT` / `FULL_SUITE_ROOT` do
for the cert writers.

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
  A **red** CI (or a closed/merged `pr_url`, or a merge-conflicted PR) still
  refuses, and a fast cert with
  **no PR at all** is refused — the provisional credit is anchored to an open PR
  whose CI will run.
- **Review side (`dor_review`, the authoritative verdict):** the `pr-review`
  supervisor checks the PR's live CI **before spawning reviewers** — red bounces
  the task back naming the failing checks (recorded as a failed `dor_review`
  attempt with a `ci` SOP), a **conflicted** PR bounces back the same way
  (`outcome=ci-conflicted`, rebase/merge release named — its CI is never
  coming, so a defer would strand it), pending defers the wave — and the
  primary's gate-zero
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

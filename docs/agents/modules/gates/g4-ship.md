# G4 Ship — the frozen-SHA production gate

## Status: Active

G4 Ship is the fourth and final branded testing gate: the **release-grain**
record (GateRun key `g4_ship`, subject = the release slug) that the **frozen
ship SHA was certified and deployed to production**. It is produced by Avi's
`production-deploy` act — `bin/release ship` opens it at the ship gate and
closes it after the post-ship smoke seal.

The four gates in order: [G1 Cert](g1-cert.md) → [G2 Review](g2-review.md) →
[G3 Candidate](g3-candidate.md) → **G4 Ship** (this doc).

## What this gate verifies

The gate window spans the whole irreversible half of the ship:

- **The frozen-SHA test gate** (`ship_test_gate` SOPs) — each app's registry
  `test_cmd` (`config/release_repos.yml`) runs at the repo's QA-frozen SHA
  BEFORE ship authority and before any push, so "shipped" can never mean
  "untested". This is the tier ship owns (`Release::STEP_TEST_TIERS`:
  `ship → full-suite` — the registry `test_cmd`, the repo's highest LOCAL
  tier; it was never a browser e2e run, hence the honest label).
- **Ship authority** — the explicit production confirm, after the gate and
  before any deploy.
- **The prod deploys** (`deploy:<repo>` SOPs) — per-app `git push` to Heroku
  or the repo's own `bin/deploy`, each with its `/up` hard-gate.
- **Post-deploy hooks** — each member's `devops.post_deploy_cmd` against
  PRODUCTION; a non-zero exit aborts before the ship record.
- **The smoke seal** (`prod_smoke_seal` SOP) — the read-only `@qa-readonly`
  suite against prod. A SEAL, not a blocker: its verdict rides the gate
  (`metadata.seal: passed|failed`) but a red seal never flips the gate's
  success and never aborts the ship — the deploy already landed; the operator
  stays the gate on rollback.

## G4 self-gating (the 90/10 policy)

The full suite runs **once per release batch, at G3**. The ship test gate SKIPS
a repo **only against G3's own recorded verdict** —
`release.metadata["qa_gates"][repo] = {"sha", "cmd", "ok", "ci"}`, which `prepare`
writes ONLY after that repo's pre-QA suite comes back GREEN. It skips iff
(`Release::ShipSequence.ship_gate_skip?`, unit-tested):

- a G3 record exists for the repo and is **green** (`"ok" => true`), **and**
- its `"cmd"` is EXACTLY the `test_cmd` the ship gate would run, **and**
- its `"sha"` is EXACTLY the frozen ship SHA, **and**
- its **auditor did not go red** — `"ci" => {"state" => "red"}` means GitHub CI
  called that SAME SHA broken while G3 called it green, so the certification is
  precisely what must not be trusted (see
  [G3's CI cross-check](g3-candidate.md#the-ci-cross-check-cis-verdict-on-the-same-sha)).

Everything else **fails open — the gate RUNS**: no record, a red record, a
different command, a drifted/straggler SHA, a red auditor, blank inputs.

Two properties of the auditor clause, because a gate is only as good as its
failure mode:

- **Fail-open only, never fail-closed.** A red auditor makes the gate *run*; it
  can never block a ship on its own. Only the suite's verdict stops a ship.
- **No data never arms it.** `none` / `pending` / `unverified` (and a record with
  no `"ci"` key — every release from before the cross-check landed) leave the
  skip decision exactly as it was.

When a red auditor is what triggered the run, the ship **says so** — and it is
honest that the re-run is *not* a backstop for CI's verdict: it re-runs the
**local** `test_cmd`, the same suite that already passed, while the failing lane
is one only CI can see.

> **Why not the registry + `qa_shas`?** That was the old rule, and it was a
> silent **disarm**. `qa_shas` is stamped by the QA *deploy loop*, so it records
> what was DEPLOYED, never what was CERTIFIED; and the registry is re-read at
> ship, so it can differ from what `prepare` read. The documented gate-skip
> recipe (blank `qa_test_cmd` so G3 skips → restore the file before ship, because
> ship's preflight used to refuse a dirty primary) therefore made G4 skip a suite
> that **nothing ever ran**, while printing "already green". A skipped G3 must
> never certify a SHA. **Do not use that recipe** — it no longer works, by design.

The skip is recorded as a **visible `ship_test_gate` SOP** on the gate run
("skipped — `<cmd>` certified green @ `<sha>` at G3"), never a silent omission.
A repo with **no registry `test_cmd` self-gates** at its own deploy and is
skipped with its own step note. In practice: the hub (same full suite registered
at G3 and G4) skips on an unchanged, G3-certified SHA; satellites (integration
subset at G3, full suite at their own deploy) always run their full pre-prod
check.

## Where the suite runs

In the repo's **isolated gate workspace** (`Release::GateWorkspace`, role `gate`)
— a private detached worktree at `<repo>/.worktrees/_gate` pinned at the frozen
ship SHA, under the dedicated gate-workspace lock, with a test DB the gate
**proves** is private before running — **never** on the shared primary checkout.
See [`g3-candidate.md`](g3-candidate.md) for why: a suite that lazily autoloads
over minutes against a tree other sessions can `git checkout` is not a check.

## Where the DEPLOY runs — the ship has its own checkout too

The gate moved off the primary before the ship did, and for a while the deploy
still fast-forwarded the primary's `main`, re-pinned Gemfiles there, and ran the
satellites' `bin/deploy` there — so **ship's preflight refused a dirty primary**.
That refusal **aborted a production ship after the gems had already published**,
because a concurrent feature session had staged work in the primary. Since
2026-07-12 the deploy owns its own tree, and the question "what does the deploy
actually need a checkout FOR?" has a two-line answer:

| Step | Needs a working tree? | Where it runs now |
|------|----------------------|-------------------|
| advance `main` → frozen SHA | **no** | `git push origin <frozen>:refs/heads/main` — a ref push out of the shared object store |
| `git_push_heroku` deploy (hub, rolio) | **no** | `git push <remote> <frozen>:refs/heads/main` — ships the frozen SHA *by value* |
| `repo_script` deploy (turf-monster) | **yes** (its `bin/deploy` runs the repo's suite, hashes the IDL, pushes) | the **ship workspace**: `<repo>/.worktrees/_ship`, detached at the frozen SHA, own lock, own test DB (`<app>_ship_test`) |
| gem re-pin commit | **yes** (`bundle lock` writes `Gemfile.lock`) | the ship workspace, pushed as `HEAD:refs/heads/release` |
| gem artifact build | **yes** (`gem build` packages what is on disk) | still the gem's **primary** — the one residual (see below) |

Ref pushes keep every safety property of the old fast-forward: git refuses a
**non-fast-forward** ref update without `--force` (which the ship never passes),
so a diverged `main` still **fails closed**; and they are idempotent, so a re-run
of a partial ship no-ops. Nothing is mutated before ship authority at all now — a
red gate or a declined confirm leaves the machine exactly as it found it.

**A dirty app primary no longer blocks a ship.** The preflight prints a NOTE plus
a rescue (commit the stranded work to a labeled `rescue/<repo>-<timestamp>`
branch — never `git stash`, never discard: it may be a live session's work) and
deploys anyway.

**The one residual primary dependency: gem builds.** A gem is built from its own
primary checkout, and `gem build` packages the files on disk — so a **modified
tracked file** in a gem repo would be *published* to RubyGems, where a version can
never be re-pushed. The preflight therefore still **aborts** on that (and only
that: untracked files are invisible to the gemspec's `git ls-files`), *before*
anything is published, printing the same labeled-branch rescue.

**Operator note — ship can now take LONGER than it used to.** G4 fails open: after
a G3 that was skipped, red, never recorded, **or contradicted by its CI auditor**,
the ship gate **runs the full suite** on the frozen SHA where it previously
self-skipped. That is the point (an uncertified SHA must not reach production
unchecked), but budget for it.

## Overriding a ship gate you believe is a false negative

`bin/release ship --skip-test-gate --reason "…"`

It demands a reason, **confirms** before skipping, runs no suite, and records a
**red** `ship_test_gate` gate SOP — so a skipped gate is visible in the release
record forever. Use it only when the code is verified green elsewhere and the
instrument is the thing that's broken; then **fix the instrument**.

This replaces the old trick of blanking the registry's `test_cmd`/`qa_test_cmd`.
Do not do that: it **silently disarmed** this gate while printing "already green"
(see above), and it no longer works.

## Who runs it

**Avi**, via the `production-deploy` SOP
([`../../agents/avi/sops/production-deploy.md`](../../agents/avi/sops/production-deploy.md))
— ship authority is granted per session by Mr. McRitchie. The gate writes are
conductor-owned (actor = the ship's `--by`, defaulting to the operator's
`$USER`; source `conductor`); you never post G4 markers by hand on the happy
path.

## Procedure

From the McRitchie Studio primary checkout (never a worktree), with a
QA-green `assembled` release:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/release ship --yes
```

The conductor records the gate for you:

1. **Open** — `g4_ship` opens as the ship gate starts (right after the
   `ship_gate started` release event; those `ship_gate` /
   `ship_authorized` ReleaseEvents STAY — they stamp the tracker's
   `confirming`/`confirmed` beats. Gates record verdicts; they never replace
   stamps).
2. **Collect** — every test scope inside the window appends an executed-SOP
   entry: `ship_test_gate` per app (run or visible skip), `deploy:<repo>` per
   deploy, `prod_post_deploy` per hook, `prod_smoke_seal`.
3. **Close** —
   - **`success`** after every repo deployed, `/up` came back green, the
     post-deploy hooks passed, and the seal recorded — with
     `metadata.seal: passed|failed` (a red seal alerts + prints the exact
     rollback but does not flip success).
   - **`failed` with `metadata.aborted: true`** on any abort inside the
     window — a red frozen-SHA gate, a failed deploy or `/up` smoke, a
     post-deploy hook failure. The close never masks the abort; the
     partial-ship report still prints, and the idempotent re-run resumes
     (gems skip, ffs no-op) on attempt n+1.

## Success, failure, and attempt semantics

- One GateRun attempt per ship run that enters the window; a re-run after an
  abort opens **attempt n+1** (visible `×n` badge), a still-open attempt is
  re-entered.
- The seal is G4's **non-blocking closing beat**: seal result ∈ metadata +
  SOPs; gate success reflects the deploy train, not the seal.
- All gate writes are **best-effort** — a board blip warns and the deploy
  continues; `--dry-run` suppresses every gate write (the plan still prints).

## UI surfaces

- **/deployments table** — the **G4 Ship** column
  (`Release::DEPLOYMENT_STAGES`: Assembled | G3 Candidate | G4 Ship |
  Deployed) is **gate-backed**: latest attempt's duration, fail tint, `×n`
  retry badge.
- **Pizza tracker** — node 4 (Confirming/Confirmed) is the G4 confirm beat:
  lit by the `ship_gate` / `ship_authorized` stage stamps, not by the gate
  record. Node 1 ≈ the [G2 wave](g2-review.md); node 4 ≈ this gate's opening
  beat.
- **CLI read:** `bin/gate show release <release-slug>`.

## Related

- [`../../agents/avi/sops/production-deploy.md`](../../agents/avi/sops/production-deploy.md)
  — the owning SOP; run that end-to-end, this doc explains the gate it
  produces.
- [`g3-candidate.md`](g3-candidate.md) — the gate whose certified SHA +
  command enable this gate's self-gating skip.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface.

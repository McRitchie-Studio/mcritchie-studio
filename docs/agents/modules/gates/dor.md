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
- The PR's **live GitHub CI** is not failing (a red, closed/merged,
  merge-conflicted, or **ci-less** PR is refused — `mergeStateStatus DIRTY`
  means GitHub can't compute the merge commit, so that PR's CI **never fires**;
  the fix is merge the PR's base in and resolve. **ci-less** is the same fact arriving without
  `DIRTY`: zero check-runs plus GitHub *affirmatively* reporting the merge is
  refused. An **undetermined** mergeability is NOT this state — it is a wait).
  CI is checked here but **never its own gate** — it records as a `ci` SOP on
  the DoR attempt.

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

**Two** things root here — the suite **fingerprint** and the code **diff** — and
they fail in opposite directions, which is why they were fixed a month apart.

**The fingerprint: a false REFUSAL.** A cert's fingerprint is a git **TREE hash**
(content-addressed), so a checkout that is not the task's tree can **never** match
a recorded cert. That does not surface as "wrong root" — it surfaces as
**`STALE`**, which reads as "you edited since certifying" and sends you off to
re-certify code that was already green. Both lanes were bitten: **review** runs
from the primary by design (cured 2026-07-09 by rooting at the task branch's
committed tree, `origin/feat/<slug>^{tree}`), and **builder** had no such cure and
false-read `STALE` for **6 of 6 tasks on 2026-07-14**, including certs 90 seconds
old. An agent that hits an unexplainable STALE *stops*, so the false STALE
stranded finished tasks in `building` behind green PRs.

**The diff: a false PASS — the dangerous direction.** The diff decides the
`chore`/`cleanup`/`docs` exemption, i.e. whether the test gate applies at all.
Read from a foreign checkout it does not refuse, it **agrees**, with someone
else's files. On **2026-08-08** the review gate-zero, run from the studio primary
exactly as [`pr-review-primary.md`](../../agents/carl/sops/pr-review-primary.md)
instructs, printed this over a multi-file code PR:

```text
✓ DoR-to-Merge n/a … doc-only diff (kind: chore): 1 file(s), none behavioral —
  docs/agents/maintenance/delete-later.md [source: git working tree]
  → ready to advance submitted → reviewed
```

One unrelated dirty file on the primary's `main`, read as the PR's entire diff.
Unlike a false STALE this is indistinguishable from a real verdict, nobody
re-runs it, and **the dirtier the checkout the more confidently it lies**.

`bin/dor-check` consults the **task-root guard** (`bin/lib/cert_root_guard.rb` —
the same guard `bin/fast-check` and `bin/full-suite-check` already required;
dor-check was the one command in the family that never did) in **both gate
roles**. When the root is not the task's tree it resolves in this order:

1. a **validated** worktree is on disk and unambiguous → re-root the whole gate
   there — **diff and fingerprint** — and **announce it on stderr** (naming both
   roots: where you stood, where it went);
2. else its **branch** resolves in this repo → root the *fingerprint* at that
   branch's committed tree and the *diff* at that branch's committed diff
   (`<base>...origin/feat/<slug>`), and **announce that on stderr** too. Both are
   content-addressed, so neither depends on what your checkout is carrying;
3. else → **refuse**, naming the problem, instead of describing a foreign tree.
   The cert half refuses in the suite-gate block; the diff half resolves
   **`:indeterminate`**, which the exempt-kind gate already fails closed on.

Remedy 2 carries its own repo condition, because **a branch name is not
repo-scoped**. Reading `<base>...origin/feat/<slug>` out of a checkout that merely
*has* a same-named branch grades a different project's work as this PR — and there
are **21 real hub↔satellite collisions on disk today**. So remedy 2 fires only when
the standing checkout is the PR's own repo (`standing_repo_mismatch` is nil); a
branch-only mismatch still qualifies, which is exactly the reclaimed-worktree case it
exists for. The same condition gates the branch-tree *fingerprint*: presenting a
foreign repo's tree hash as this task's cert is the confidently-wrong-root failure
this file spends a section warning about.

**Every tree is validated — the one it jumps to AND the one you stand in, on BOTH
axes.** A checkout is the task's tree only if it passes *repo* **and** *branch*; a
matching directory NAME proves neither.
The first cut of this fix checked the checkout you were **standing in** twice and the
one it **jumped to** zero times, while announcing "Re-rooted at the task's worktree"
as fact — which reopened the false pass one hop downstream, twice
(review, 2026-08-09): a worktree with the right branch in the **wrong repo**, and a
**stale desk** in the right repo that never carried the branch. Either alone gets
through an either-axis check, so both are required:

| axis | source of truth | when enforced |
|---|---|---|
| repo | the checkout's `origin` remote (**owner-qualified**, so a fork does not validate), falling back to its app directory name only when there is no origin | only when `devops.pr_url` names a repo (a pre-PR builder run has none) |
| branch | `git rev-parse --abbrev-ref HEAD` in the checkout | always; a detached `HEAD` is refused |

Failing checkouts are **named with the axis they failed** — "no worktree here" would
be a lie when one is sitting on disk under exactly that name, and a reader who
believes it points the gate straight back at the desk that was just rejected.

**The one asymmetry, and it is deliberate.** Standing physically at the task's desk
(`…/.worktrees/<slug>`) still vouches for a cert **writer** — `bin/fast-check`,
`bin/full-suite-check` — even mid-rebase on a detached `HEAD`: the operator is working
there, and a cert is content-addressed, so a transient tree can only later read
`STALE`, which is loud and self-correcting. It does **not** vouch for the **reader**:
a detached `HEAD` is not the PR's state, and a diff read from it is graded as though it
were — silently, and passing. Same fact, opposite correct answers, so `assess` reports
it (`standing_in_task_desk`) and each caller decides. That vouch is deliberately
repo-blind: making it repo-strict would need a repo-per-PR mapping the task record does
not have (see the single-`pr_url` gap below), and would refuse honest multi-repo builds.

**Ambiguity is also a refusal.** The worktree glob spans every app, so a
**multi-repo** task matches once per repo (live today: `repair-moms-app-ci` exists
under both `moms-app` and `studio-engine`). Picking the alphabetical first answers
"which repo is this?" with a coin flip. `devops.pr_url` names the repo actually
under gate and breaks the tie; when more than one candidate still validates, the gate
prints `AMBIGUOUS TASK TREE`, lists them, and refuses to guess. Nothing assumes one repo or one
rung — the diff base stays the per-root release-aware default, so a repo with no
`accepted` (moms-app) still resolves its own base.

**Known gap, stated so nobody assumes otherwise:** `devops.pr_url` is a *single*
value, so on a multi-repo task this gate validates **one** PR and is blind to the
other. The rooting above keeps it from grading the *wrong* repo silently; it does
not make it grade *both*. Reviewing a multi-repo task still means checking the
second PR yourself.

**The local working tree is never a fallback from a foreign root.** This is the
rule that closes the 08-08 hole by construction rather than by every reader
remembering to ask. The old reasoning — recorded in this file, and wrong — was
that exempt kinds are safe because "the diff comes from the PR, which is
root-independent". True only while `gh` can read the PR: when it can't (a token
fault, a blank `pr_url`), the resolver fell through to the local view and the
nearest dirty checkout answered. An observation of the **wrong tree** is not
evidence, even when it is non-empty and all prose.

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
**diff** was read from) and `diff_source` (`pr` | `git` | `branch` | `injected` |
`pr_unreadable` | `indeterminate`) plus `changed_files`, then `full_suite.fingerprint`,
`.fingerprint_root`, `.fingerprint_repo`, `.fingerprint_source` (`working-tree` |
`branch-tree`), and `.recorded`. `code_root` is *not* the fingerprint's root under
an override — that is precisely why the provenance travels with the fingerprint
instead. **The checkable invariant is the PAIRING**: `diff_source: "git"` is a
correct answer only when `code_root` is the task's own tree; the same pair read
from anywhere else is the 08-08 false pass.

**And a refused PR read is never a silent one.** Installation tokens live ~1h, so
the `gh` call behind `diff_source: "pr"` can start failing mid-session. It used to
fail invisibly — the gate fell back to the local git diff and went on judging a
DIFFERENT artifact under a verdict that said "the PR". Now the read goes through
`bin/lib/ci_status.rb`'s shared seam (`gh_read_status`: stderr preserved, one App-token
mint-and-retry on an auth refusal), and a failure that survives that is classified and
reported in a `pr_read` field (`state`: `unreadable` — GitHub refused the credential —
or `unverified`; plus `cause` and `reason`). `pr_read` is absent whenever the read was
fine, or there was no PR to read. What the gate then does is role-split, exactly like
the CI verdict:

| Role | On a credential-refused PR read |
|------|----------------------------------|
| `--gate-role review` | **Refuses.** `diff_source: "pr_unreadable"`, no files, and the error carries `CiStatus.unreadable_remedy`. This role's verdict is authoritative and it runs from a checkout that is *not* the task's tree, so a local stand-in here is the false pass with a fresh coat of paint. |
| builder (submit-side) | **Degrades, loudly.** The local view is still graded — the builder stands in the task's own worktree and review re-reads them — but the verdict NAMES the refusal and carries the remedy as a suggestion. |

The fix is one command: `eval "$(bin/gh-auth-refresh --export)"`, then re-run.

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

## The CI seam — the gate never waits; the WRAPPER now does

**Read this section as the gate's contract, which has not changed.** `bin/dor-check`
still never waits for CI: it grades whatever state it finds, and the provisional
credit below is still exactly how it treats a pending one. What changed
(`gate-submit-on-green-ci`, 2026-08-16) is **when `bin/ship` calls it** — the
wrapper now holds at step 6/8 until the PR's CI settles, so in the ordinary case
this gate is handed a GREEN CI and the provisional path is no longer the happy
path. It remains live, and is still what a hand-run `bin/task move` and every
CI-less or timed-out ship falls through to.

That reversed a dated decision, which is worth stating rather than leaving to be
rediscovered. The original reasoning (`ci-gate-review-handoff`, 2026-07-09) was
that the CI **wait** belongs to the review handoff, not the builder's wall-clock —
sound while the builder was ALSO paying for a local FULL suite (~31 min against
CI's ~9 for the identical command). Dropping that local suite inverts the
arithmetic: the builder nets ~20 min back, `submitted` gains a green-CI invariant,
and a red CI is caught by the session that still holds the worktree instead of
bouncing into a cold one.

The gate's own semantics, unchanged:

- **Builder side (`dor`, the default role):** a still-running CI is a **loud
  suggestion**, never a block. A fresh fast cert is credited **provisionally**
  while the open PR's CI is pending or not yet reported (the `ci` SOP records
  `pending`, the `full-suite-evidence` SOP records `fast-cert@<fp12>+ci-pending`).
  A **red** CI (or a closed/merged `pr_url`, or a merge-conflicted or
  **ci-less** PR) still refuses, and a fast cert with
  **no PR at all** is refused — the provisional credit is anchored to an open PR
  whose CI will run.
- **Review side (`dor_review`, the authoritative verdict):** the `pr-review`
  supervisor checks the PR's live CI **before spawning reviewers** — red bounces
  the task back naming the failing checks (recorded as a failed `dor_review`
  attempt with a `ci` SOP), a **conflicted** PR bounces back the same way
  (`outcome=ci-conflicted`, "merge the PR's base in and resolve" named — its CI is never
  coming, so a defer would strand it), a **ci-less** PR bounces back too
  (`outcome=ci-less`), pending defers the wave — and the
  primary's gate-zero
  (`--gate-role review`) keeps the strict semantics: it advances on **green and
  nothing else** (red and pending both block, and so does a verdict it could not
  read), and fast evidence needs the settled green. The single escape is a full
  cert — see the allow-list bullets below.

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
  / unverified / **unreadable**).
  - **`unreadable`** = the GitHub token was REFUSED (401/403) reading CI — as
    opposed to `unverified` (no `gh`, no network, a 404). It is **no more
    lenient** than `unverified`: it unlocks nothing, and notably does **not**
    credit a fast cert (a fast cert needs a CI green the gate can actually
    *read*). It is only more **honest** — it names the repo and classifies the
    denial as permissions, rejected credentials, missing authentication, rate
    limiting, or ambiguous forbidden access. The remedy matches that cause; it
    prescribes `Checks: Read` only for an actual permission denial. The CI SOP
    durably records `state`, `cause`, `reason`, and `repo` instead of
    collapsing the attempt to generic `unverified`. See `gates/g3-candidate.md`.
- The reviewer's gate-zero **opens then closes `dor_review`** with the same
  evidence shape, under the strict CI semantics.
  - **Strict means it is an ALLOW-LIST: `green` advances, everything else
    refuses.** Not a list of bad states — a list of the ONE good one. A deny-list
    defaults to *pass*, so every state added to `bin/lib/ci_status.rb` afterwards
    joins the safe side silently; that is exactly how a blank `devops.pr_url`
    (`no_pr`) once exited 0 printing "ready to advance" with **no CI line at all**.
    An allow-list defaults to *refuse*, so a state nobody has classified blocks
    review until somebody does. `test/lib/dor_check_test.rb` asserts this with a
    state that does not exist — the one test a longer deny-list could not pass.
  - **One escape, and only one: a FULL cert.** For the no-verdict family
    (`none` / `unreadable` / `unverified`) a fresh `bin/full-suite-check` cert
    stands in for the CI verdict, and the gate then says so on the ready line
    (`advancing on the FULL local cert instead … CI itself was NOT read`). Two
    reasons: the gate must **honour the remedy it prints** — `unreadable_remedy`
    has always ended by naming that command — and the cert is no longer weaker
    evidence, because `bin/full-suite-check` now runs `ci.yml`'s verbatim command,
    `test:system` included. A **fast** cert is not enough, and a
    `[full-suite-bypass]` is a declared hatch rather than evidence, so neither
    clears it.
  - **What a cert cannot clear**: `red`, `conflicted`, `ci_less`, `closed`,
    `merged` (a verdict exists, or the PR is not a live review target); `pending`
    (the verdict is genuinely coming — waiting is productive); `no_pr` (what is
    missing is not the evidence but the PR: review's job is to merge one); and any
    unclassified state.
  - Submit-side **none of this applies** — the builder's provisional handoff is
    untouched (see the state table above). The asymmetry is deliberate: the review
    gate-zero *is* the authoritative CI verdict, while blocking every submit on a
    flaky read would trade a flaky CI lane for a flaky gate. Both directions are
    asserted, so the split cannot quietly collapse either way.
  - The **remedies stay distinct**, because the fixes are: `unreadable` names the
    credential and says re-running is futile (a `conductor-review`, not a
    `request-changes` — the builder does not own the token); `none` / `unverified`
    say to wait for checks to appear, *or* to certify in full where no check will
    ever appear (`solana-studio` and `turf-vault` have zero workflows, so `none` is
    permanent there and waiting is the PR-#509 stall).
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

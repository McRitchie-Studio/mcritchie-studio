# DoR — the Definition-of-Ready gate (builder + review gate-zero)

## Status: Active

DoR is the branded testing gate for the **Definition-of-Ready verdict**: the
deterministic `bin/dor-check` pass that decides whether a task is ready to
advance. It sits between [G1](g1-cert.md) (the optional local pre-flight) and
[G2 Review](g2-review.md) (the senior review), and it is recorded as **two
task-grain gates** so the same check reads cleanly from both sides of the
`submitted` seam:

- **DoR (builder)** — GateRun key `dor`. The feature agent's verdict at submit.
- **DoR (review)** — GateRun key `dor_review`. The primary reviewer's gate-zero
  re-run, plus the supervisor's pre-spawn CI bounce.

The gate flow order: [G1 pre-flight](g1-cert.md) → **DoR** (this doc) →
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
- The **suite evidence** proves the tree being shipped is certified. Since
  2026-09-24 (`dor-reads-settled-ci-verdict`, phase 2a of DevOps v3) that
  evidence has **one form**: the PR's **settled GREEN GitHub CI** for its current
  head, read through `bin/lib/ci_status.rb` and decided in `bin/lib/ci_gate.rb`.
  The fingerprint receipts the local certs used to record (the fast-cert,
  full-suite, rubocop and cert-deferred lanes) and the full-suite bypass hatch
  are gone with the certs (phase 2b, `retire-local-cert-evidence`); a leftover
  line on an old task is author prose to this gate. Green
  passes in both roles; red, conflicted, ci-less, closed and merged refuse in
  both; a **pending** CI is a **WAIT** for the builder (exit 1 under a `⏳ …
  WAITING on CI` headline, `ci_waiting: true` in `--json`) and a refusal for
  review; an unread verdict (`none` / `unverified` / `unreadable` / a blank
  `pr_url`) refuses in both roles with its own remedy, and **no local cert
  stands in** for any of them. The one fingerprint-bound line still graded is
  the `test-only` shape's executed control (`[control@<fp>]`).
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
- **And in the REVIEW role it must be proven against the PR.** A failed PR
  file-list read — `unreadable` (the credential was refused) *or* `unverified`
  (no `gh`, a 404, a transport error) — **refuses the VERDICT** there
  (`ready: false`) rather than granting it off a local tree, however well
  rooted. They refuse in two SHAPES, and only one keeps the exemption.
  `unverified` still resolves a local diff, so the refusal forms on the exempt
  path and **does not withdraw the exemption**: the payload keeps `exempt: true`
  and `missing_tiers: []` beside `ready: false`. `exempt` names which guard was
  WAIVED, never that the run passed, so the two fields are designed to disagree
  there. `unreadable` is refused one step earlier, in the resolver
  (`diff_source: "pr_unreadable"`, no files), so an ordinary review run never
  reaches the exempt path at all and its payload reads `exempt: false` under the
  same `ready: false`. Read `ready` for the verdict in both; there is no cleared
  exemption flag to go looking for. Until 2026-09-05 only the credential half
  was closed, and only in the diff resolver: `unverified`
  fell through to the working tree, and the exempt path had no role-split at all,
  so the alert landed as a *suggestion* and the review and builder verdicts came
  back byte-identical — `✓ … → ready to advance`, off `[source: git working
  tree]`. That is the 2026-08-08 false pass exactly
  (`/tasks/exempt-path-trusts-local-tree`). The builder keeps the fallback,
  named, for the reason below.
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

## The exemption is from the TIER gate. It was never from CI

An earned doc-only diff skips the **shape/test-tier** gate, and nothing else. It
does **not** skip the CI verdict, and it does not skip the gate-attempt record.

Until 2026-09-05 it skipped both, silently
([gate-zero-skips-docs-ci](https://mcritchie.studio/tasks/gate-zero-skips-docs-ci)).
The exempt branch ended in a bare `exit 0` that sat **above** the CI allow-list and
above the gate-verdict emit, so `--gate-role review` — the run this page calls the
authoritative CI verdict — never evaluated CI on a prose diff: `--json` returned
`ready=true, exempt=true, errors=[]` with **no `ci` key at all**. Three doc-shaped
PRs cleared gate-zero that way (turf-vault #9 and #10, mcritchie-studio #1204); all
three were green by luck, not by gate. The `dor_review` attempt reading **null** on
docs-shaped PRs was the same fact, logged twice and filed as a cosmetic gap in the
record — the record was not missing, the gate had not run.

Read the two guards separately, because only one of them belongs here:

- **The tier gate — correctly skipped.** A prose diff owes no unit tier, and
  demanding one is how people learn to mislabel a shape.
- **The CI allow-list — never had any business being skipped.** This repo's CI
  **grades prose**: the doc-link check, generated-doc drift, the entry-doc guards
  and rubocop over `bin/` all run on a docs PR, and every one of them can go red.
  *Ships no behavior* is not *cannot fail CI*.

So both paths now ask the same function (`bin/lib/ci_gate.rb`), rather than keeping
two copies of an allow-list — two allow-lists that drift are a deny-list with extra
steps. `green` advances an exempt review; `red`, `pending`, `conflicted`,
`ci_less`, `closed`, `merged`, the no-verdict family, a blank `pr_url` and any
unclassified state all refuse, exactly as they do on the gated path. The verdict
carries a `ci` field either way, and a `dor_review` attempt is recorded either way.

**No cert clears a refusal, on either path.** Until 2026-09-24 the gated path's
no-verdict family (`none` / `unreadable` / `unverified`) could be cleared by a FULL
local cert, because the gate honoured the remedy it printed; the exempt path never
could, having no suite to substitute. The cert route retired with the receipts, so
the two paths no longer diverge: an unread CI leaves the merge with no verdict from
either side, which is the state a gate exists to refuse, and every refusal now says
so (`no local cert stands in`) instead of naming a local cert.

The **build** gate still reads no CI on an exempt task: it resolves no diff and must
not shell `gh`. Leniency there disarms nothing — at design time no code exists yet
and the build gate enforces no tiers either way.

Pinned by `test/lib/dor_check_exempt_ci_test.rb`, including the control that keeps
the split honest: a code-carrying diff under the same exempt kind is still asked for
its tiers, so "no tier was demanded" cannot quietly become "tiers are waived for
everyone".

## The gate grades the TASK's tree — never the one you stand in

**Two** things rooted here — the suite **fingerprint** and the code **diff** — and
they fail in opposite directions, which is why they were fixed a month apart. The
cert fingerprint is no longer graded and the certs themselves retired (2026-09-24);
the history stays because the **diff** half is live, and because the `test-only`
control stamp still takes the fingerprint rooting the cert used to
(`control_fingerprint` in `bin/dor-check`).

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

`bin/dor-check` consults the **task-tree check** (`bin/lib/task_tree.rb` — the
same check `bin/fast-check` takes; dor-check was the one command in the family
that never did) in **both gate roles**. When the root is not the task's tree it resolves in this order:

1. a **validated** worktree is on disk and unambiguous → re-root the whole gate
   there — the **diff**, and the control stamp's tree — and **announce it on
   stderr** (naming both roots: where you stood, where it went);
2. else its **branch** resolves in this repo → root the *diff* at that branch's
   committed diff (`<base>...origin/feat/<slug>`), and the control stamp at that
   branch's committed tree, and **announce that on stderr** too. Both are
   content-addressed, so neither depends on what your checkout is carrying;
3. else → the diff resolves **`:indeterminate`**, which the exempt-kind and
   `claimable_when` gates fail closed on, instead of describing a foreign tree.

Remedy 2 carries its own repo condition, because **a branch name is not
repo-scoped**. Reading `<base>...origin/feat/<slug>` out of a checkout that merely
*has* a same-named branch grades a different project's work as this PR — and there
are **21 real hub↔satellite collisions on disk today**. So remedy 2 fires only when
the standing checkout is the PR's own repo (`standing_repo_mismatch` is nil); a
branch-only mismatch still qualifies, which is exactly the reclaimed-worktree case it
exists for. The same condition gates the branch-tree *fingerprint*: presenting a
foreign repo's tree hash as this task's control is the confidently-wrong-root
failure this file spends a section warning about.

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
(EITHER layout — `<repo>/.worktrees/<slug>` or the sibling
`<repo>.worktrees/<slug>`) still vouches for the **pre-flight** (`bin/fast-check`)
even mid-rebase on a detached `HEAD`: the operator is working there, and a
pre-flight records nothing durable. It does **not** vouch for the **reader**:
a detached `HEAD` is not the PR's state, and a diff read from it is graded as though it
were — silently, and passing. Same fact, opposite correct answers, so `assess` reports
it (`standing_in_task_desk`) and each caller decides. That vouch is deliberately
repo-blind: making it repo-strict would refuse honest multi-repo builds.

**Ambiguity is also a refusal.** The worktree glob spans every app, so a
**multi-repo** task matches once per repo (live today: `repair-moms-app-ci` exists
under both `moms-app` and `studio-engine`). Picking the alphabetical first answers
"which repo is this?" with a coin flip. `devops.pr_url` names the repo actually
under gate and breaks the tie; when more than one candidate still validates, the gate
prints `AMBIGUOUS TASK TREE`, lists them, and refuses to guess. Nothing assumes one repo or one
rung — the diff base stays the per-root release-aware default, so a repo with no
`accepted` (moms-app) still resolves its own base.

**Every repo the task has a PR in gets its own CI verdict.** The per-repo CERT
verdict that stood here — each repo's desk fingerprinted and graded against
`[lane@<fp>:<repo>]` evidence, `full_suite.repos[]` in `--json`, a `cert graded per
repo:` block — retired with the receipts on 2026-09-24. What remains is the multi-PR
read below: a secondary repo is gated by its own PR's CI exactly as the primary is,
and the verdict is the **worst** of them.

One limit, stated so nobody assumes otherwise:

- **The DIFF and CI halves read EVERY recorded PR** (2026-09-07,
  `/tasks/dor-check-reads-one-pr`). Until then `devops.pr_url` — a single value — fed
  both the PR file list and the CI verdict, while the plural `devops.pr_urls` register
  fed only the cert list above. So on a two-repo task the shape/tier gate, the doc-only
  exemption and migration detection were all measured against **one** PR, and the CI
  allow-list asked **one** PR whether the task was green.

  It was worse than the known "the gate sees only the repos a task NAMES" limit, and
  in a way that made the standing remedy useless: on `/tasks/document-burn-entry-token`
  the task named **both** repos and recorded **both** PR URLs correctly, and the gate
  still read one. Fixing the record could not reach it. Measured: running the gate
  under `DOR_CHECK_DIFF_ROOT=<turf-vault>` and again under
  `DOR_CHECK_DIFF_ROOT=<turf-monster>` returned the **identical** diff (turf-vault's
  three files) — because PR files outrank the git tree, so changing the tree changes
  nothing and turf-monster's only file, `docs/SOLANA.md`, appeared in neither run.

  What it does now:

  - **The diff is the UNION** of every recorded PR's file list (`devops.pr_url` plus
    the `devops.pr_urls` register, deduped by URL). That is the diff a two-repo task
    actually ships, and it is the fail-closed direction on every consumer: more code
    files, more tiers demanded, and a doc-only exemption that must hold across **both**
    PRs.
  - **The CI verdict is the WORST of them**, not the first (`TaskPrSet.governing`) — so
    a red satellite PR can no longer hide behind a green hub PR. Worst-of rather than
    first-non-green because the order is a record-keeping detail, and a gate whose
    verdict depends on which URL somebody typed first can be steered by the record. A
    state the severity table has never heard of governs **above** red, mirroring the
    allow-list doctrine one level up. Every remedy names the repo the governing verdict
    came from, not whichever URL was recorded first.
  - **A PR it cannot read FAILS THE RUN CLOSED, and names the repo.** If any recorded
    PR's file list is unreadable, the union cannot be formed, and the states split:
    `diff_source: "pr_incomplete"`, and the refusal says which repo it could not read
    (`repos_unread`). Grading the PRs that *did* read would be this defect wearing a
    smaller number.
  - **That refusal fires in BOTH roles**, unlike a single-repo unreadable read, which
    still only warns submit-side. The builder's local-view fallback is earned by
    standing in the PR's own worktree, where the tree is the PR's honest near-twin. On
    a two-repo task the builder stands in one of them and **no** tree on the machine is
    the near-twin of the other, so there is nothing honest to substitute.
  - **The verdict reports its coverage.** `pr_coverage[]` in `--json`, and a
    `PRs read (n):` block in the human output on any multi-PR task — one row per PR
    with its repo, file count, sample files and its own CI state. Before it existed, a
    verdict that covered one repo and a verdict that covered two were indistinguishable
    from the output, which is exactly how a gate grading half the work reported a full
    one.

  A single-repo task takes the one-PR path unchanged, byte for byte: it cannot reach
  the union, cannot produce `pr_incomplete`, and prints no coverage block.

  Test seams, mirroring the singular ones: `DOR_CHECK_PR_FILES_BY_REPO` and
  `DOR_CHECK_CI_STATUS_BY_REPO` each take JSON of `repo => <the same token grammar>`.

A repo the task NAMES but has no PR in is deliberately **not** cert-gated — that is
the gem-release shape, where a gem task names its CONSUMER repos so the gates can
reason the gem owes the PR while the consumers do not. The gate says so in a
suggestion rather than implying coverage it does not have.

**The local working tree is never a fallback from a foreign root.** This is the
rule that closes the 08-08 hole by construction rather than by every reader
remembering to ask. The old reasoning — recorded in this file, and wrong — was
that exempt kinds are safe because "the diff comes from the PR, which is
root-independent". True only while `gh` can read the PR: when it can't (a token
fault, a blank `pr_url`), the resolver fell through to the local view and the
nearest dirty checkout answered. An observation of the **wrong tree** is not
evidence, even when it is non-empty and all prose.

**Resolve, not refuse — and never silently.** The pre-flight refuses a wrong
root, and must: a chdir could run a stale worktree while your real edits sat
untested where you ran from, and read green. `dor-check` **writes no evidence**
— it grades what is already recorded — so re-rooting cannot forge a control; it
can only make the gate judge the right code. But a *silent* chdir is its own hazard (a gate quietly judging a
different tree than the one you are looking at is how you end up arguing with a
verdict), so **both re-rooting arms announce both roots**.

**The `STALE` delta retired with the cert lane** (2026-09-24). The refusal that
named what the evidence was certified for against what the code is now, and the
`--suite-fingerprint` seam that let a reader recompute it, described receipts this
gate no longer reads. The one fingerprint-bound line still graded — the `test-only`
control stamp — refuses as `the recorded control is STALE (it was run against
different code)`, and in the review lane it is hashed from the task branch's
committed tree (`origin/feat/<slug>^{tree}`), never from the reviewer's checkout,
exactly as the cert was.

`--json` carries the facts machine-readably: `code_root` (the checkout the
**diff** was read from) and `diff_source` (`pr` | `git` | `branch` | `injected` |
`pr_unreadable` | `indeterminate`) plus `changed_files`, then `suite_evidence`
(`form: settled-green-ci`, `satisfied`, `state`, `head`, `waiting`) and
`ci_waiting`. **The checkable invariant is the PAIRING**: `diff_source: "git"` is a
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

| Role | On a FAILED PR read (`unreadable` or `unverified`) |
|------|----------------------------------------------------|
| `--gate-role review` | **Refuses**, on both the gated and the exempt path. A credential refusal is caught in the resolver (`diff_source: "pr_unreadable"`, no files, the error carrying `CiStatus.unreadable_remedy`); any other failed read is caught where the verdict is formed, because the local view still stands in there. This role's verdict is authoritative and it runs from a checkout that is *not* the task's tree, so a local stand-in here is the false pass with a fresh coat of paint. |
| builder (submit-side) | **Degrades, loudly.** The local view is still graded — the builder stands in the task's own worktree and review re-reads them — but the verdict NAMES the refusal and carries the remedy as a suggestion. |

The exempt path was the last holdout: it printed the alert as a suggestion for
**both** roles, so a doc-only exemption could be earned while the PR went unread.
Its refusal now also says *which* half refused — an unread PR is not the CI
verdict, and a closing line that blames CI sends the reader to the wrong fix.

**And the alert closes by naming its OWN refusal.** It used to end with the CI
gate's sentence, *"this gate advances on a GREEN CI and nothing else"* — false
exactly where it printed, because on a green CI the error carrying that sentence
is the only thing refusing the verdict, and the sentence sends the reader to look
at CI. Where this alert REFUSES (the review role at the merge gate) it now closes
on the read that failed, and says plainly that no CI result clears it. Where it
refuses nothing (the builder role, and `--gate build`) it is a suggestion, so the
original sentence is still true and still prints, to the byte.

**The fix depends on WHICH of the two failures you got, and the gate prints the
right one — do not read one remedy for both.**

- **`unreadable`** — GitHub refused the credential (401/403, a rate limit, a
  missing `Checks: Read`). Here the fix is one command:
  `eval "$(bin/gh-auth-refresh --export)"`, then re-run. This is the only branch
  that reaches `CiStatus.unreadable_remedy`, and that remedy opens by saying so:
  *"This is a CREDENTIAL fault or API limit, NOT a missing CI."*
- **`unverified`** — everything else: no `gh` on `PATH`, a 404, a transport
  error, a GitHub API outage, a body that would not parse. **There is no
  credential to refresh**, so `gh-auth-refresh` fixes nothing. `bin/dor-check`
  says exactly that instead — *"this is NOT a credential refusal, so the LOCAL
  view was graded instead … Re-run once `gh` answers"* — and the re-run only
  clears it once the read itself starts working.

Prescribing the credential command for an `unverified` read is this family's
signature defect wearing a doc's clothes: a gate naming a remedy it cannot
honour. Both branches live in `pr_read_alert` (`bin/dor-check`), split on
`pr_file_read[:state]`.

`DOR_CHECK_DIFF_ROOT=<path>` bypasses the guard: that is the caller **declaring**
a root (the CI/test seam), exactly as `FAST_CHECK_ROOT` does for the pre-flight.

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

Run from the task worktree, after the final commit + push + open PR (the
verdict runs LAST; the optional pre-flight, [g1-cert.md](g1-cert.md), comes
before the push):

```bash
bin/dor-check <task-slug>
```

Exit 0 = ready to advance `submitted → reviewed`, which since 2026-09-24 means
the PR's CI has **settled green**. A CI still running exits 1 under a `⏳ …
WAITING on CI` headline — not a failure, a wait; `bin/ship` holds at step 6/8 for
exactly this, so the ordinary handoff never sees it. The verdict opens+closes the
`dor` gate with its evidence as SOPs.

### Review side (the `dor_review` gate)

The primary reviewer, inside its review:

```bash
bin/dor-check <task-slug> --gate-role review
```

This opens+closes the `dor_review` gate and keeps the **strict** CI semantics
(below). It never touches `g1_cert` or the G2 review lanes — that is exactly
what `--gate-role review` exists for.

## The CI seam — the gate never waits; the WRAPPER now does

**Read this section as the gate's contract.** `bin/dor-check` still never waits
for CI: it grades whatever state it finds. What changed first
(`gate-submit-on-green-ci`, 2026-08-16) is **when `bin/ship` calls it** — the
wrapper holds at step 6/8 until the PR's CI settles, so in the ordinary case this
gate is handed a GREEN CI. What changed second (`dor-reads-settled-ci-verdict`,
2026-09-24) is what a still-pending CI means when the wait times out: there is no
provisional credit any more, so the builder-side verdict is a **WAIT** (exit 1) and
`bin/ship` stops at 7/8 to be re-run once CI reports.

That reversed a dated decision, which is worth stating rather than leaving to be
rediscovered. The original reasoning (`ci-gate-review-handoff`, 2026-07-09) was
that the CI **wait** belongs to the review handoff, not the builder's wall-clock —
sound while the builder was ALSO paying for a local FULL suite (~31 min against
CI's ~9 for the identical command). Dropping that local suite inverts the
arithmetic: the builder nets ~20 min back, `submitted` gains a green-CI invariant,
and a red CI is caught by the session that still holds the worktree instead of
bouncing into a cold one.

The gate's own semantics:

- **Builder side (`dor`, the default role):** a still-running CI is a **WAIT** —
  exit 1 under its own `⏳ … WAITING on CI` headline, the `ci` SOP recording
  `pending` so the gates card paints it in-flight rather than red. A **red** CI
  (or a closed/merged `pr_url`, or a merge-conflicted or **ci-less** PR) refuses,
  and so does an unread verdict (`none` / `unverified` / `unreadable`) or a blank
  `pr_url`, each with its own remedy. Nothing is credited provisionally: no
  local receipt exists to read.
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
  read). There is no escape — see the allow-list bullets below.

Net effect: nothing reaches a reviewer (or a merge) without a green CI, but the
builder never idles watching checks. Expect the bounce round-trip if you hand
off a PR whose CI then fails — that is the trade, priced in.

## Success, failure, and attempt semantics

One GateRun row = one **attempt** (`started_at → finished_at`, `success`,
`sops`). Retries are first-class: a failed attempt closes and the re-run opens
attempt n+1.

- The builder's verdict **opens then closes `dor`** with `success = ready`,
  attaching its evidence as SOPs: `dor-check`, `tiers` (the shape's tier list),
  and `ci` (pass / fail / **pending** / unverified / **unreadable**). The `ci`
  SOP *is* the suite evidence; the `full-suite-evidence` SOP that used to sit
  beside it recorded the receipts and retired with them.
  - **`unreadable`** = the GitHub token was REFUSED (401/403) reading CI — as
    opposed to `unverified` (no `gh`, no network, a 404). It is **no more
    lenient** than `unverified`: it unlocks nothing and credits nothing. It is
    only more **honest** — it names the repo and classifies the
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
    **The allow-list covers the exempt (doc-only) path too**, which it did not
    until 2026-09-05 — see *The exemption is from the TIER gate* above.
  - **On the GATED path there is no escape either** (since 2026-09-24). Until
    then a fresh local full-suite cert stood in for the no-verdict family
    (`none` / `unreadable` / `unverified`) and the gate said so on the ready line
    (*advancing on the FULL local cert instead … CI itself was NOT read*), on the
    argument that the gate must honour the remedy it prints and that the cert ran
    `ci.yml`'s own command. Both halves retired with the receipts: the remedy is
    no longer printed, and the cert is no longer read. An unread verdict refuses,
    in both roles, and the refusal ends with the contract clause `no local cert
    stands in`.
  - **On the EXEMPT (doc-only) path there is NO escape, and green alone no
    longer carries it.** A green CI is **necessary but not sufficient** here.
    Until 2026-09-05 it was both, and "green, or nothing" was the whole rule;
    since the PR-read refusal joined this path, a doc-only review can refuse on a
    **GREEN** CI — because the PR's own file list went unread, so the exemption
    was never proven against the artifact this gate judges. Two independent halves
    can refuse, and the closing line names which one did (`this refusal is <the CI
    verdict…> AND <the PR's own file list going unread…>`), so a reader is never
    sent to CI for a fault CI did not have. What has not changed is the escape:
    the cert route does not merely fail there, it does not exist — the
    shape/test-tier gate is already waived, so there is no suite whose result
    could stand in.
    Accepting a cert would leave the merge with zero verification from either
    side, which is the state the gate exists to refuse.
    **The refusal says that.** Until 2026-09-05 it printed the gated path's text
    verbatim — *"certify in full instead: `bin/full-suite-check <slug>`"* — while
    `bin/dor-check` discarded the only flag that could honour it, so adding the
    cert produced a **byte-identical refusal** and an operator who followed the
    instruction burned a full-suite run for nothing
    (`/tasks/exempt-refusal-prints-dead-remedy`). The route parameter that split
    the two paths (`cert_route:`) now prints one task-grain denial for every value,
    and `test/lib/dor_check_exempt_ci_test.rb` reads the printed refusal, confirms
    it denies rather than offers, and confirms a recorded full cert leaves it
    byte-identical on both paths.
  - **What clears a refusal is the state changing, never a cert**: `red`,
    `conflicted`, `ci_less` (fix, or bring the base in), `closed` / `merged`
    (reconcile `devops.pr_url`), `pending` (wait — the builder's verdict says so
    under its own headline), `none` (confirm the workflow triggered), `unverified`
    (re-read once `gh` answers), `unreadable` (refresh the credential), `no_pr`
    (open the PR), and any unclassified state (classify it in
    `bin/lib/ci_gate.rb`).
  - **The suite gate's refusal cannot disagree with that list, because it IS
    that list.** Until 2026-09-24 `suite_evidence_error` had its own branches — a
    fresh FAST cert, a DEFERRAL receipt, the FULL-cert escape clause conditioned
    on `cert_route_open:` — and a whole test file
    (`dor_check_remedy_honoured_test.rb`) existed to keep the remedy it printed
    equal to the remedy the gate accepted. That machinery, and the `red` /
    `pending` cells it had to get right, retired with the receipts; the CI
    verdict is the whole suite verdict and `test/lib/dor_check_test.rb` pins the
    role table.
  - **The builder side is no longer provisional.** The same allow-list runs in
    both roles, with one difference: a pending CI is a WAIT for the builder (exit
    1, `⏳ … WAITING on CI`, `ci_waiting: true`) and a refusal for review. Both
    directions are asserted, so the split cannot quietly collapse either way.
    - **It is not "none of this applies", and on a docs task that difference is
      now visible.** The role asymmetry covers the *unread* family and `pending`;
      a **RED** CI has always blocked BOTH roles, and since the exempt path
      started evaluating CI at all (2026-09-05) that block reaches a doc-only diff
      too. `bin/ship` runs `bin/dor-check <slug>` at step **7/8** and dies on its
      exit code, so **a docs task with a red CI now fails `bin/ship` at 7/8**
      rather than sailing through. That is the correct direction — this repo's CI
      grades prose — and it was undocumented until now. Measured 2026-09-05
      against the exempt path in the builder role: `red` → exit 1, `green` and
      `pending` → exit 0; since 2026-09-24 `pending` → exit 1 as a WAIT.
  - The **remedies stay distinct**, because the fixes are: `unreadable` names the
    credential and says re-running is futile (a `conductor-review`, not a
    `request-changes` — the builder does not own the token); `none` /
    `unverified` say the opposite — **wait, a check is coming**.
  - **"No check will ever appear" is never a property of a REPO.** Every repo in
    the ecosystem ships a `pull_request`-triggered workflow. `solana-studio`
    ships `.github/workflows/gem-ci.yml` (`name: Gem CI`; jobs `gem-suite`,
    `playwright`) and `turf-vault` ships `.github/workflows/ci.yml` (`name: CI`;
    jobs `program`, `guards`) — both re-derived at source 2026-09-01 on
    `origin/accepted` **and** `origin/main`, which hold an identical blob, and
    both also triggered on `push` to `[accepted, release, main]`. On
    `origin/accepted` the rest follow: `studio-engine`'s `engine-ci.yml`
    (`name: Engine CI`) and `consumer-ci.yml` (`name: Consumer CI`), and `ci.yml`
    in `mcritchie-studio`, `turf-monster`, and `rolio`. This bullet used to say
    `solana-studio` and `turf-vault` had **zero workflows**, so `none` was
    permanent there and a full cert was the only route; every part of that is
    false. `pr-review-primary.md` carried the same sentence and was corrected in
    PR #1128 — this was the second copy.
  - **When a check genuinely never arrives, read the PR's MERGE STATE, not the
    repo.** `bin/lib/ci_status.rb` classifies that as `conflicted`
    (`mergeStateStatus DIRTY`) or `ci_less` (zero check-runs *plus* an
    affirmatively refused merge) — distinct entries in `TOKENS`, each carrying
    its own remedy (`conflicted_remedy`, `ci_less_remedy`), and neither
    clearable by a cert (see above). Folding either into `none` is the
    **PR-#509 stall** the module's own header names: it prescribes waiting for a
    run GitHub will never queue.
- The supervisor's **pre-spawn CI-red bounce** opens then closes `dor_review`
  `--failed` with a `ci` SOP (`--meta outcome=ci-red`, actor `avi`) — no reviewer
  runs, but the round-trip is visible on the gates card.
- **Never emitted:** dor-check with `--json` (read-only monitors), `--gate build`
  (no DoR verdict yet), or a run whose slug resolves empty. All gate writes are
  fire-and-forget — a board blip never changes a verdict or an exit code.
  - **`--file` is the conditional one, not an absolute.** Offline evaluation
    skips the write **unless `DOR_CHECK_GATE_BIN` redirects the gate CLI** — the
    seam a test uses to observe that the attempt was recorded without a board
    (`gate_emission_enabled?`, `bin/dor-check`). Production never sets it, so
    `--file` stays offline for every real caller; a test that sets it gets two
    invocations (`open` then `close`), verified 2026-09-05.

## UI surfaces

- **Task gates card** — the "Testing gates" card on
  `https://mcritchie.studio/tasks/<slug>` renders the **DoR (builder)** and
  **DoR (review)** chips between G1 Cert and the G2 lanes: latest attempt
  (`×n` retry badge), passed / failed / in-flight status, and the expandable SOP
  list (`dor-check`, `tiers`, `ci`).
- **CLI read:** `bin/gate show task <task-slug>` (add `--json` for the raw
  attempts).

## Background — not needed to execute

- The Option-B split rationale and the CI-status handoff:
  `docs/agents/system/devops-cycle-design.md` §3.3.
- The verdict logic: `bin/dor-check`, `bin/lib/ci_gate.rb`, `bin/lib/ci_status.rb`.
- The receipt format the cert writers still record (inert here):
  `bin/lib/tree_fingerprint.rb`, `lib/cert_evidence.rb`.

## Related

- [`g1-cert.md`](g1-cert.md) — the self-closing cert gate that precedes DoR; its
  receipts are no longer what this gate reads, but its lanes are still the
  builder's local pre-flight.
- [`g2-review.md`](g2-review.md) — the senior-review lanes that follow; the
  primary's gate-zero IS this gate's `dor_review` half.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface `bin/gate` posts through.

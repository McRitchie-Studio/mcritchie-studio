# G4 Ship — the frozen-SHA production gate

## Status: Active

G4 Ship is the fourth and final branded testing gate: the **release-grain**
record (GateRun key `g4_ship`, subject = the release slug) that the **frozen
ship SHA was certified and deployed to production**. It is produced by Steffon's
`production-deploy` act — `bin/release ship` opens it at the ship gate and
closes it after the post-ship smoke seal.

The four gates in order: [G1 Cert](g1-cert.md) → [G2 Review](g2-review.md) →
[G3 Candidate](g3-candidate.md) → **G4 Ship** (this doc).

## What this gate verifies

The gate window spans the whole irreversible half of the ship:

- **The frozen-SHA test gate** (`ship_test_gate` SOPs) — **GitHub CI's settled
  verdict for the repo's QA-frozen SHA's TREE** is read BEFORE ship authority and
  before any push, so "shipped" can never mean "untested". Nothing runs on the
  conductor's machine: the frozen SHA is resolved through the **same credit-or-poll
  read G3 runs on the release tip** (`resolve_release_ci_verdict`) — its own run,
  polled to a conclusion, or a same-SHA / same-tree green credited from the
  accepted head — and **only green ships** (fail-closed). The registry `test_cmd`
  is the gate's SWITCH and names the suite CI ran; it is recorded on the SOP beside
  the verdict's source, never executed. CI's run covers the repo's full suite
  INCLUDING the browser `test:system` lane. See
  [The tree-verdict read](#the-tree-verdict-read-one-tree-one-verdict) below.
- **Ship authority** — the explicit production confirm, after the gate and
  before any deploy.
- **The prod deploys** (`deploy:<repo>` SOPs) — per-app `git push` to Heroku
  or the repo's own `bin/deploy`, each with its `/up` hard-gate.
- **Post-deploy hooks** — each member's `devops.post_deploy_cmd` against
  PRODUCTION; a non-zero exit aborts before the ship record. Duplicate
  commands fold to one run **only on the same app**, and only across the
  interchangeable `rake`/`bin/rails` runner spellings — the rest of the command
  is compared verbatim.
  The app is the repo's `production_app` in `config/qa_environments.yml`, or
  else the Heroku app its `prod_deploy` names (cyvasse); if neither names one,
  ship aborts.
- **The smoke seal** (`prod_smoke_seal` SOP) — the read-only `@qa-readonly`
  suite against prod. A SEAL, not a blocker: its verdict rides the gate
  (`metadata.seal: green|red|unsealed`) but a red seal never flips the gate's
  success and never aborts the ship — the deploy already landed; the operator
  stays the gate on rollback.
  - **It retries once through the boot window.** The seal fires seconds after
    the deploy, so a smoke can land mid dyno boot/restart and fail against a
    HEALTHY prod (rel-20260720-c06235 red-sealed on `GET /tasks`; a re-run
    minutes later sealed 5/5 green). On a first failure the seal now waits
    **30s** and re-runs the suite **exactly once**. A first-attempt pass never
    waits — the happy path is unchanged.
  - **Reading the verdict.** A green seal whose summary says *"retried once
    after 30s boot-window wait"* passed on the second attempt — prod is fine,
    the first run caught the boot window. A **red seal now means the failure
    PERSISTED through the retry**: a confirmed failure, not a timing blip, so
    treat it with more weight than before. The seal's contract is otherwise
    unchanged — still non-blocking, still never auto-rolls-back.
- **It runs the SHIPPED tree's specs.** The seal runs `bin/prod-smoke` from
  the hub's ship workspace (`mcritchie-studio/.worktrees/_ship`), pinned at
  the frozen ship SHA under the ship-workspace lock, and never from the
  primary. rel-20260925-3b1f5c sealed a false red because the seal ran the
  primary's PRE-ship specs against the new prod. The workspace gets its node
  deps from `npm ci`, re-run whenever the shipped `package-lock.json` differs
  from the one last installed (so a Playwright bump never runs on stale deps),
  and bounded at 600s so a hung install cannot stall the ship.
- **Unsealed is not red.** When the shipped specs cannot run (the pin fails,
  the SHA does not match, `bin/prod-smoke` or playwright is missing, the deps
  do not match the shipped lockfile, `npm ci` times out, or the script cannot
  execute), the seal records **unsealed**: no seal is written,
  the `prod_smoke` event is `completed` with `metadata.seal: "unsealed"` and
  the message `unsealed: could not run the shipped specs — <reason>`, and no
  rollback prints. It is never `failed`, so the board and the duration readers
  do not count it as a failure. A red seal means the shipped specs RAN and
  failed.
- **Re-seal a shipped release** with `bin/release reseal <release-slug>`
  (`--dry-run` to preview). It pins the ship workspace at that release's
  frozen hub SHA, runs its specs against prod, and overwrites the recorded
  seal; the summary says it was re-sealed, and names the later release when
  prod has since moved on. A green or red re-seal also re-stamps the G4 gate's
  `metadata.seal` (with `resealed_at`), so the /deployments G4 column matches; an
  unsealed re-seal leaves both seals as they were. It deploys nothing and flips
  no task.

## The tree-verdict read (one tree, one verdict)

**One tree earns one verdict** (devops-v3 §5): L0–L3 run once, on the PR's tree,
in CI; every later gate READS that verdict. G3 and G4 do not run suites, and G4
no longer consults G3's record either — the self-skip against
`release.metadata["qa_gates"]` (`Release::ShipSequence.ship_gate_skip?`) went
with the local suite it used to spare. The frozen ship SHA is resolved through
the **same path G3 runs on the release tip** (`resolve_release_ci_verdict`,
`bin/release.rb`), in order:

1. **Same-SHA credit** — the frozen SHA IS the accepted head (a fast-forward
   promote) and its completed greens cover every pending duplicate by check name
   (`ci_credit_verdict` → `CiStatus.credit_for_sha`).
2. **Same-TREE credit** — the frozen SHA is a batch-PR merge commit whose tree
   equals the accepted head's (`tree_identical_promote`), and the accepted
   head's own run is green — or still in flight, in which case the gate waits on
   it inside the poll bound (`tree_identical_ci_outcome`).
3. **Its own run** — otherwise the frozen SHA's own run is polled until it
   settles, up to `RELEASE_CI_POLL_TIMEOUT` (default ~1200s, re-read every
   `RELEASE_CI_POLL_INTERVAL`, default 15s). Red and unreadable return at once.

The gate classifies what it read (`Release::ShipSequence.ship_gate_kind`,
unit-tested) and records a `ship_test_gate` SOP naming the **source** of the
verdict — `GitHub CI GREEN @ <sha> — credited — tree-identical promote — accepted
head <sha> … shares tree <tree> …`, or `… — the SHA's own run, polled to a settled
conclusion` — plus the registry command CI ran. Exactly two kinds pass:

| Kind | What was read | G4 result |
|------|---------------|-----------|
| `green` | The frozen SHA's own run concluded green. | **PASS** — the SOP names the own run. |
| `credited` | A same-SHA or same-tree green vouched for the frozen tree. | **PASS** — the SOP names the credit (both SHAs and the shared tree). |
| `red` | A check failed or was cancelled. | **ABORT** — a broken frozen commit: read the failing check, fix on `release`, re-run `bin/release ship`. |
| `unreadable` | The API refused the read (401/403). | **ABORT at once** — a token fault polling cannot heal; the abort prints the credential remedy. Never polled. |
| `diverged` | The frozen tree shares neither SHA nor tree with the accepted head (a consumer lock-bump commit; `accepted` moved on), AND its own run gave no green within the bound. | **ABORT** — names both halves: why no credit applied, and what the own run read. |
| `held` | `pending` / `none` / `unverified` past the poll bound (a just-pushed re-pin still building). | **ABORT** — let CI conclude on the frozen SHA (or widen the bound), re-run `bin/release ship`. |

Every non-pass row records a **failed** SOP and aborts BEFORE ship authority,
before any push, leaving origin untouched. G3's record cannot talk a red or held
read past the gate: a green `qa_gates` row beside a red frozen SHA still aborts
(`test_ship_test_gate_ignores_the_g3_record_and_reads_ci_for_the_frozen_tree`).

**It fetches nothing.** The read uses whatever `origin/accepted` the last fetch
left, because the ship path touches no ref before ship authority. A stale
accepted ref can only decline a credit (the SHA's own run is the fallback) or
credit an OLDER accepted head whose tree is identical — and a green for
identical content is a verdict for this tree, which is the whole rule.

A repo with **no registry `test_cmd` self-gates** at its own deploy and is
skipped with its own step note: the `repo_script` satellites' `bin/deploy` runs
their suite in the ship workspace. **Do not blank `test_cmd` to get past a red
gate** — a blank reads as "self-gates" and skips the READ, which silently disarms
the last gate before production; the supported override is
[`--skip-test-gate`](#overriding-a-ship-gate-you-believe-is-a-false-negative).

## Where the verdict comes from

**GitHub CI**, for the frozen ship SHA's tree — the credit-or-poll resolution
above, the same one G3 ran on the release tip minutes or hours earlier. Nothing
runs on this machine; the verdict comes off the laptop.

> **Deleted, in order:** the suite in the repo's isolated gate workspace
> (`Release::GateWorkspace`, role `gate`) — demoted at DevOps v2 Phase 3, deleted
> in Phase 4; then the single un-polled `ci_verdict` read and the self-skip against
> G3's record (`ship_gate_skip?` / `auditor_red?`) — replaced by the tree-verdict
> read above (devops-v3 piece 2b-ii). The `GateWorkspace` primitive lives on under
> role `ship` for the gem build, the consumer lock bump / re-pin, and a
> `repo_script` satellite's own pre-prod deploy suite — never for a gate.

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
| `github_actions` deploy (the hub) | **no** | `gh workflow run <prod-deploy workflow> -f sha=<frozen>` — Actions does the Heroku push and the `/up` smoke |
| `git_push_heroku` deploy (mcritchie-industries; rolio, parked) | **no** | `git push <remote> <frozen>:refs/heads/main` — ships the frozen SHA *by value* |
| `repo_script` deploy (turf-monster) | **yes** (its `bin/deploy` runs the repo's suite, hashes the IDL, pushes) | the **ship workspace**: `<repo>/.worktrees/_ship`, detached at the frozen SHA, own lock, own test DB (`<app>_ship_test`) |
| gem re-pin commit | **yes** (`bundle lock` writes `Gemfile.lock`) | the ship workspace, pushed as `HEAD:refs/heads/release` |
| gem artifact build | **yes** (`gem build` packages what is on disk) | still the gem's **primary** — the one residual (see below) |

Ref pushes keep every safety property of the old fast-forward: git refuses a
**non-fast-forward** ref update without `--force` (which the ship never passes),
so a diverged `main` still **fails closed**; and they are idempotent, so a re-run
of a partial ship no-ops. Nothing is mutated before ship authority at all now — a
red gate or a declined confirm leaves the machine exactly as it found it.

**A refused `main` push does NOT mean `main` diverged** — and until 2026-08-29
the ship said it did. `push_frozen_main` ran `git push` without capturing its
output and then asserted the only cause it knew: *"origin/main has diverged from
the frozen SHA (someone pushed to main) — reconcile main, re-run `bin/release
prepare` to re-freeze."* Measured twice that day on a real ship, the true cause
was `remote: Invalid username or token`, three lines above in git's own output;
`main` was strictly **behind** `release` and a dry-run fast-forward succeeded. A
confident, specific, wrong diagnosis whose prescribed remedy — reconciling a
branch that needed nothing and re-freezing a good freeze — was pure waste.

The push output is now captured, echoed, and CLASSIFIED, the same way
`advance_accepted` already classified a refused `accepted` push:

| Outcome | What git said | What you do |
|---|---|---|
| **AUTH** | `Invalid username or token`, `Authentication failed`, `could not read Username`, `Permission denied (publickey)`, a 401/403 | `source ~/.zprofile.admin` and `export GH_APP_ITEM=github.mcritchie-deployer` BEFORE the push — the ship pushes as the **deployer**, whose credential lives in `studio-agents-admin`, and it is never cached, so those two lines are the whole fix. Then re-run `bin/release ship`; it resumes. **Do NOT re-run `prepare`** — the freeze is still good. |
| **DIVERGED** | `non-fast-forward`, `[rejected] … (fetch first)`, `Updates were rejected because…` | Reconcile `main`, re-run `bin/release prepare` to re-freeze, then re-run `bin/release ship`. |
| **UNRECOGNISED** | anything else | Read git's output above before acting — **both** standard remedies may be the wrong errand. The ship says so rather than guessing. |

`error: failed to push some refs to …` appears in **both** failures, so it is
never the discriminator. Nothing forces in any case.

**A dirty app primary no longer blocks a ship.** The preflight prints a NOTE plus
a rescue (commit the stranded work to a labeled `rescue/<repo>-<timestamp>`
branch — never `git stash`, never discard: it may be a live session's work) and
deploys anyway.

### Resuming a PARTIAL ship (the re-pin is idempotent by identity)

A ship aborts on the first failure, and the re-run resumes: published gems skip,
ref pushes no-op, and **the auto-re-pin is idempotent**. That last one is not free,
and it used to be a **wedge**:

Auto-re-pin mints a NEW commit on top of the frozen SHA and advances the ship SHA
to it — but `qa_shas` still holds the **original** frozen SHA and nothing ever
rewrites it. So a ship that published the gems, pushed the re-pin, and *then* died
left `origin/release = repin₁` while `qa_shas = frozen`. The retry re-derived its
SHA from `qa_shas`, saw the frozen tree's Gemfile still branch-ref'd, decided a
re-pin was needed — and then read **its own re-pin commit** as un-QA'd drift:
`origin/release drifted past the QA-frozen SHA — re-run bin/release prepare`. After
the gems had published. (Underneath that guard sat a second failure: the retry would
mint `repin₂`, a distinct commit with an identical tree, whose push is
non-fast-forward against `repin₁`.)

The ship now asks whether a moved `origin/release` **is the re-pin this run would
have written**, and reuses it instead of minting a rival. It qualifies on all three
or not at all (`Release::ShipSequence.resumable_repin?`):

1. **Ancestry** — the frozen SHA is an ancestor of the head.
2. **Shape** — the diff touches **only** `Gemfile` / `Gemfile.lock`. This preserves
   the original guard's whole intent: no code reaches production un-QA'd under cover
   of a re-pin.
3. **Identity** — the head's Gemfile is **byte-identical** to what this run would
   write. Not merely "no branch refs left" — that weaker test would wave through a
   Gemfile someone pinned to the *wrong* version, and prod would build it.

Anything else **fails closed** and aborts as drift. Refusing a resumable ship costs
a conversation; completing an unresumable one costs production.

**The one residual primary dependency: gem builds.** A gem is built from its own
primary checkout, and `gem build` packages the files on disk — so a **modified
tracked file** in a gem repo would be *published* to RubyGems, where a version can
never be re-pushed. The preflight therefore still **aborts** on that (and only
that: untracked files are invisible to the gemspec's `git ls-files`), *before*
anything is published, printing the same labeled-branch rescue.

**Operator note — ship is FAST when the tree already earned its green, and a
non-green CI HOLDS it.** The ship gate reads GitHub CI's settled verdict for the
frozen tree — near-instant when that run settled at prepare, or when the accepted
head's green credits it; a still-building run is **polled** for up to
`RELEASE_CI_POLL_TIMEOUT` (~20 min) rather than failed on the first read. The
trade: an uncertified tree (a re-pin whose CI has not concluded, a red frozen
commit) **fails the gate closed** and holds the ship until CI is green — or you
take the `--skip-test-gate` override below. An uncertified tree must not reach
production unchecked.

## Overriding a ship gate you believe is a false negative

`bin/release ship --skip-test-gate --reason "…"`

It demands a reason, **confirms** before skipping, reads no verdict, and records a
**red** `ship_test_gate` gate SOP — so a skipped gate is visible in the release
record forever. Use it only when the code is verified green elsewhere and the
instrument is the thing that's broken; then **fix the instrument**.

This replaces the old trick of blanking the registry's `test_cmd`/`qa_test_cmd`.
Do not do that: it **silently disarmed** this gate while printing "already green"
(see above), and it no longer works.

## Who runs it

**Steffon**, via the `production-deploy` SOP
([`../../agents/steffon/sops/production-deploy.md`](../../agents/steffon/sops/production-deploy.md))
— ship authority is granted per session by Alex. The gate writes are
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
   entry: `ship_test_gate` per app (the tree-verdict read, naming its source), `deploy:<repo>` per
   deploy, `prod_post_deploy` per hook, `prod_smoke_seal`.
3. **Close** —
   - **`success`** after every repo deployed, `/up` came back green, the
     post-deploy hooks passed, and the seal recorded — with
     `metadata.seal: green|red|unsealed` (a red seal alerts + prints the exact
     rollback but does not flip success; unsealed prints the re-seal command).
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

- [`../../agents/steffon/sops/production-deploy.md`](../../agents/steffon/sops/production-deploy.md)
  — the owning SOP; run that end-to-end, this doc explains the gate it
  produces.
- [`g3-candidate.md`](g3-candidate.md) — the gate that ran the same read on the
  release tip; its `qa_gates` record is the audit trail, not an input here.
- [`../task-board-api.md`](../task-board-api.md) — the `/api/v1/gates` write
  surface.

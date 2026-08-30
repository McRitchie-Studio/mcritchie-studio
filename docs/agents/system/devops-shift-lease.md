# DevOps shift lease — one live conductor per role

The elegant fix for concurrent devops/builder collisions: two Avi heartbeats, an
Avi heartbeat launched alongside a `pr-review`, two `qa-release` sweeps racing the
release candidate, or a conductor's `cleanup --reclaim` evicting a builder who just
sat down. One primitive — the build-claim lease (`lib/claim_lease.rb`) — applied to
more scopes at three grains: a per-ROLE **shift** lease (section A), a per-TASK
**review** claim (`TaskReviewClaim`), and a per-RELEASE **conductor** claim
(`ReleaseConductorClaim`, section B) — each the SAME lease math one level down from
the last, so the lock lives on the finest record the act contends over.

## The problem

Devops acts fan out (reviewer subagents, `heroku run` dynos, `bin/release` CLI).
Two same-role sessions running at once **duplicate the work** (both pick the same
PRs), **exhaust the board's Postgres 20-connection limit** (combined fan-out), and
**race shared state** (two `qa-release`s merge → the candidate goes N-behind;
`cleanup --reclaim` reclaims an active desk). The ≤5 cap was documented, not
enforced; review/conductor acts took no lease at all.

## A — the shift lease (`avi` / `alex`)

`DevopsShift` is a board-held singleton **per lane**, where a lane is a ROLE/shift
key. It reuses the build-claim lease math verbatim: a holder is a LIVE INSTANCE
(session id + per-process nonce, `SessionIdentity.nonce`) under a **120s TTL**
renewed by a **detached renewer the acquiring run starts for itself**. `acquire` is
an atomic compare-and-set (one row per lane, taken under `with_lock`) so two
simultaneous acquirers serialize and exactly one wins.

**Two lanes left this lease (`steffon` retired 2026-07-21).** The `steffon`
(`qa-release`) and the `avi`-**ship** (`production-deploy`) locks moved OFF the
per-role shift and ONTO the RELEASE RECORD — see **section B**. The shift lease now
covers only `clean-up`'s `avi` lane (a board sweep over shared worktrees) and the
vestigial `alex`. The model and table are KEPT; only `steffon` left the default
`DevopsShift::LANES` set.

**These lane keys are historical identifiers, not current owners.** The `steffon`
and `avi` lane keys above date from before the 2026-07-22 act reslot and do NOT track
who owns the act today: qa-release is Avi's now, production-deploy is Steffon's. The
keys were deliberately left as-is because `avi` is still a live code identifier
(`bin/devops-shift acquire avi`, run by `clean-up`) and renaming it would break the
lane. Read the keys as opaque lease names; take the act-owner from its SOP, not from
the key.

**Renewal belongs to the run, not to the UI** (fixed 2026-07-20). Renewal used to
live only in `bin/statusline`, so it happened when Claude Code PAINTED A STATUS LINE.
A headless holder — a background agent run, and critically the **autonomous
heartbeat** — painted nothing, renewed nothing, and lost its lane ~120s into work
that ran far longer; `acquire` then truthfully reported the lane FREE to the next
session. That is not theoretical: two Avi review supervisors ran concurrently and
duplicated four reviewer lanes on PR #601, the exact collision this lease exists to
prevent. Now `acquire` spawns `bin/devops-shift renew-loop`
(`bin/lib/shift_renewer.rb`), which renews every **30s** (TTL ÷ 4, derived from the
TTL so the two cannot drift) for as long as its **anchor process** — the long-lived
`claude`/`codex` process the nonce is already derived from — stays alive.
`bin/statusline` still renews; it is now a harmless second renewer rather than the
only one.

**A renewer also dies with its WORK, not only with its holder** (fixed 2026-08-30).
The anchor answers "is my holder still here?" — it does not answer "is the thing I
am protecting still a thing?", and for the per-TASK review claim (section C) that is
the condition that actually ends the job. A session reviews MANY tasks, so anchoring
alone accumulated one immortal renewer per task: at 05:25Z on 2026-08-30 five
`review-claim renew-loop` processes were running and **four were renewing claims on
tasks that had already SHIPPED TO PRODUCTION**, their anchor alive and legitimately
working the whole time. Nothing had crashed. Between them they polled the board every
30s indefinitely and spent the **account-wide** 1Password read budget every lane
shares, so the outage presented as "1Password is down" / "GitHub auth is broken" and
cost two full days (2026-08-29 and 2026-08-30) before the cause was found.

`ShiftRenewer.run` now takes a third stop condition, `finished:`, asked **before** the
renew so a loop whose work is done exits having polled the board **zero** further
times. `bin/lib/review_claim_cli.rb` supplies it as `task_finished?`: a claim on a
task at `reviewed`, `assembled`, `shipped` or `archived`
(`ReviewClaimCli::TERMINAL_STAGES`) protects nothing, so the loop exits 0, quietly.
Two asymmetries are deliberate: `blocked`, `building` and `designed` are NOT terminal
(a bounced review is often still being written up, and a rework bounce can move a task
backwards while a real lease is held); and unlike the anchor check, `finished` fails
**OPEN** — an unreadable board is not evidence that a review ended, and stopping on a
network blip would free a live reviewer's task underneath them. A wrong "anchor dead"
costs a recoverable delay; a wrong "work finished" costs a duplicated review.

Two callers still pass no `finished:`, for DIFFERENT reasons, and the difference
matters to anyone asking "did we fix all the immortal renewers?". The
`devops-shift` ROLE lease is unchanged and correctly exempt: it protects a LANE,
not a unit of work, so it has no completion signal to give. `bin/lib/release_claim_cli.rb`
is NOT exempt — its renewer is scoped to a RELEASE SLUG, which does reach terminal
stages — and it still carries this exact defect, tracked at
`/tasks/release-renewer-outlives-ship`. So this section covers the REVIEW claim
only; two of the three members of that family are done and one is not.

- **Simple** — the careless double. Session A holds `avi`; a second Avi launch
  `acquire avi` → the row is live-held → `acquired:false` → the CLI prints
  `🛑 avi shift already held — STAND DOWN` naming the holder, and exits **10**. The
  SOP tells the second session to stop. No duplicate reviews, no doubled fan-out.
- **Crash** — A dies mid-shift; its renewer sees the anchor process gone and exits,
  so nothing renews. Within the TTL the lease lapses and the next launch `acquire`s
  it (`disposition: expired`). Self-healing — a dead shift never wedges the lane.
  This is why the headless fix is a renewer and NOT a fail-closed `acquire`: refusing
  whenever we cannot prove the holder dead would invert `ClaimLease`'s fail-open
  posture and let one crash lock a lane indefinitely. A crash must cost a delay,
  never a deadlock.
- **Work done** — a per-task review renewer whose task reaches a terminal stage exits
  on its next cycle even though its anchor is alive and its claim still technically
  held. This is the exit the original two-condition design lacked; a regression test
  that only kills the anchor passes against that design and proves nothing, so
  `test/lib/review_claim_renewer_integration_test.rb` drives a REAL renewer past
  `shipped` with the anchor held alive throughout.
- **Headless** — a holder with no status line retains the lane for the whole run.
  Asserted, not assumed: `test/models/devops_shift_test.rb` walks a 20-minute window
  (ten TTLs) refusing a second acquire at every step, and
  `test/lib/devops_shift_renewer_integration_test.rb` spawns the REAL detached
  renewer against a stub board and asserts its renewals carry the holder's own
  session + nonce (a renewer with the wrong nonce posts happily while the board
  no-ops every call — the same bug wearing a disguise).
- **Different lanes coexist** — `avi` (clean-up) and `alex` are distinct leases, so
  those acts run side by side; only two of the SAME role collide.

`release` frees the lane immediately instead of waiting out the TTL, and **reports
what the board did**. It used to print success unconditionally, so a caller that was
not the holder (board answers 204, nothing released) saw `shift released.` while
`status` went on showing the shift — two commands disagreeing about one fact. Both
now speak from the board: the verdict comes from the release response, and on a 204
the holder line is re-read from the same `GET …/devops_shifts` that `status` renders.

Surface: `bin/devops-shift acquire|renew|release|status` (+ the internal
`renew-loop`); the board endpoints
`POST /api/v1/devops_shifts/{acquire,renew,release}` + `GET …/devops_shifts`; the
`<sid>.devops-shift` marker `acquire` writes (the lane, for `bin/statusline`) and its
`<sid>.devops-shift-renewer` sibling (the renewer's pid, so `release` can stop it);
and the acquire-or-stand-down preamble in the `clean-up.md` conductor SOP (`avi`).
(`qa-release` and `production-deploy` no longer preamble a shift acquire — their lock
moved onto the release record, taken automatically inside `bin/release prepare`/`ship`;
see section B.) Enforcement is cooperative (the SOP stands the loser down) per the
studio's honor-system posture; the exit code (0 acquired / 10 stand down / 1
fail-open) makes it scriptable.

**Every argument is accounted for before any shift is taken** (fixed 2026-08-21).
`--help`/`-h` anywhere on the line prints usage and mutates nothing; an unrecognized
flag, a single-dash token, a positional the subcommand does not take, and a value-flag
that consumed no value all REFUSE (exit 1) instead of running the side effect. Before
that guard, unknown flags fell through the parser into an ignored key and the command
ran on a line nobody had accounted for — `bin/devops-shift acquire avi --help` printed
no usage and **took the avi shift**, marker, detached renewer and all. Three
consequences worth knowing:

- **Help exits 1, not 0.** In this CLI exit 0 is the assertion *"you are on shift"*,
  and it is the only channel that assertion travels on — unlike
  `bin/lib/review_claim_cli.rb`, whose claim rides on stdout as a slug. A help probe
  answered with 0 would tell `clean-up`'s review wave it holds the lane when it holds
  nothing, which is the two-concurrent-supervisors failure above. Every caller treats
  1 safely: `bin/statusline` discards the exit code, the detached renewer is never
  reaped for status, and a conductor SOP reading 1 fails OPEN — proceeding while
  *knowing* it is not on shift.
- **The refusal copy is per subcommand.** "Nothing was claimed" on a refused `release`
  would be wrong in the dangerous direction — that shift is still held *and* still
  being renewed, so it will not even lapse — while the same sentence on `renew` would
  overstate the cost of losing the status line's redundant second beat.
- **`status` takes no lane.** It is the cross-lane read, so `status avi` refuses
  instead of silently answering about every lane.

Same guard, same reasoning as `bin/lib/review_claim_cli.rb` (PR #974) and
`bin/lib/release_claim_cli.rb` (PR #980) — this is the third and last member of that
family. The wall risk is the expensive half and is pinned accordingly: every real
invocation is replayed through the guard in
`test/lib/devops_shift_argument_guard_test.rb`, and
`test/lib/devops_shift_flags_test.rb` runs a real `acquire` whose real detached
renewer must survive the guard it re-enters.

The lane is a role, not an act, so a single Avi session that runs two `avi`-lane
acts back to back holds `avi` across both (a re-`acquire` by the same instance is a
no-op renew).

**The review lane left this lease (2026-07-21).** `pr-review` no longer acquires
`avi`. Review is a READ act on INDEPENDENT tasks, so standing a whole second
supervisor down was the wrong grain — it stopped the PR #601 double-review only by
forbidding parallel review outright. Review now takes a **per-TASK** claim
(`TaskReviewClaim`, `app/models/task_review_claim.rb`) — the SAME `ClaimLease` math
one more level down (role → task): each session claims the tasks it reviews and
SKIPS any already under a live claim, so many `pr-review` sessions run at once and
never review one task twice. The board exposes the unclaimed queue as
`Task.reviewable` (`GET /api/v1/tasks?stage=submitted&reviewable=1`); the CLI is
`bin/task review-claim acquire|release|status <task>` (exit 0 claimed / 10 skip / 1
could-not-confirm); and `bin/pr-review` SELECTS candidates from the reviewable queue
and reviews a task only on a CONFIRMED claim — exit 10 (held) skips, exit 1 (no
session id / board unreachable) DEFERS rather than reviewing on an unconfirmed claim,
so the no-double-review contract holds even when the board is unreachable. Of the
remaining MUTATING acts, `qa-release` and `production-deploy` then left the shift
lease too — onto the RELEASE RECORD (section B) — leaving only `clean-up` on the
`avi` shift, because it sweeps shared worktrees rather than one release. This realizes
the "per-act lanes" follow-up as per-task / per-release claims rather than a lane split.

**The atomic server-side pop (2026-07-22).** The "which task next" decision above is
assembled CLIENT-side in `bin/pr-review` (fetch the reviewable queue → read each PR's
CI → `acquire` one). `POST /api/v1/tasks/claim_next_review` (`Task.claim_next_review`,
`Api::V1::TaskReviewClaimsController#claim_next`) relocates that whole decision into ONE
authoritative board transaction: it walks `reviewable.ordered`, filters to PRs whose CI
concluded GREEN — the DB-native green fold `Ci::ReviewGate` runs over the ingested
`GithubWorkflowRun` rows for the task's PR head_sha, reusing `bin/lib/ci_status.rb`'s
verdict semantics — and claims the top one via `TaskReviewClaim.acquire`, each candidate
selected `FOR UPDATE SKIP LOCKED` so two concurrent callers pop DIFFERENT tasks. The CLI
is `bin/task claim-next-review` (prints the claimed slug / exit 0, or `none` / exit 4).
It is the server-authoritative counterpart to the per-task `acquire` above; `bin/pr-review`
does not consume it yet (that wiring is a later task).

## B — the release-record conductor claim (`assembler` / `deployer`)

`ReleaseConductorClaim` (`app/models/release_conductor_claim.rb`) is the SAME lease
math one level down from the shift — role → **(release, role)** — for the two
release-lifecycle acts: `assembler` (`qa-release` / `bin/release prepare`) and
`deployer` (`production-deploy` / `bin/release ship`). Two independent rows per
release, keyed by the **composite unique index `[release_slug, role]`** (the atomic
CAS), so an assembler and a deployer on one release never contend, and two of the
SAME role on one release do.

**Why it left the shift.** The shift lock was a GLOBAL lane — one `steffon` session,
one `avi`-ship session, ever. A stale or ghost lease on that lane could strand the
WHOLE lane for a TTL. Moving the lock onto the release record, which **turns over
every release**, means a stale claim dies with its release: a lock that can never
strand a global lane again. This is the same move the review lane made (lane → task);
here it is lane → (release, role).

Identity, TTL, the detached renewer, the fail-open posture, and the
`holder_label`/`acquired_at` reset-on-change-of-hands are all inherited verbatim from
the lease math above. Two properties matter for the release acts specifically:

- **A same-instance re-acquire RESUMES.** An interrupted `bin/release ship` re-run,
  from the same agent session (same session id + nonce), re-acquires the `deployer`
  claim as a no-op renew rather than standing itself down — so a killed ship resumes.
- **Fail-open on transport, stand down on a live holder.** `bin/release` takes the
  claim over the FAST HTTP AgentApi (`bin/lib/release_claim_cli.rb`), never a
  per-heartbeat `heroku run` (a ship holds the claim for many minutes; a dyno per 30s
  renew is unacceptable). A telemetry hiccup fails OPEN (the release proceeds
  unclaimed — a claim outage must never wedge a real release); a live DIFFERENT holder
  (exit 10) still stands the run down.
- **It re-provides the ship↔cleanup exclusion the shift used to.** When ship held the
  `avi` shift, `clean-up` (also `avi`) could not run against a live ship — so it could
  never reclaim ship's fixed-path `_ship`/`_gate` workspaces mid-ship. Ship left the
  shift, so `bin/agent-worktree`'s reclaim guard now reads the claim directly: it
  WITHHOLDS `_ship`/`_gate` from reclaim whenever a live `deployer` claim exists on ANY
  release (the cross-release `GET /api/v1/release_conductor_claims/live?role=deployer`,
  fronted by `release_claim_cli.rb any-live`), and withholds on an unreadable board
  (fail-closed for a destroy path — a ship might be live). Task desks are unaffected.

Surface: `bin/lib/release_claim_cli.rb acquire|renew|release|status <release-slug>
--role assembler|deployer` + `any-live --role <role>` (the cross-release liveness read;
+ the internal `renew-loop`), invoked automatically by `bin/release prepare` (assembler,
before the accepted→release promote) and `bin/release ship` (deployer, before the
frozen-SHA gate + deploy), released on completion; the board endpoints `GET/POST
/api/v1/releases/:slug/conductor_claim` + `…/conductor_claim/{renew,release}` + the
cross-release `GET /api/v1/release_conductor_claims/live`; the
`<sid>.release-conductor-claim-<role>-<slug>` marker (with its
`-renewer-<role>-<slug>` sibling for the renewer pid — keyed per SLUG as well as role,
because a fresh-create `prepare` briefly holds the `__forming__` sentinel and the real
claim at once); and `bin/agent-worktree`'s `_ship`/`_gate` reclaim guard (which reads
`any-live`). Because the acquire is INSIDE `bin/release`, `qa-release.md` and
`production-deploy.md` no longer preamble a `bin/devops-shift acquire` — the lock is
automatic.

**Every argument is accounted for before anything is claimed.** `--help`/`-h` anywhere
on the line prints usage and mutates nothing; an unrecognized flag, a single-dash
token, a positional the subcommand does not take, and a value-flag that consumed no
value all REFUSE (exit 1) instead of running the side effect. Before that guard,
unknown flags fell through the parser into an ignored key and the command ran on a
line nobody had accounted for. Two consequences worth knowing: help exits **1, not
0**, because in this CLI exit 0 is a claim-state assertion (`acquire` 0 = "you hold
the lease", `any-live` 0 = "a release is live") and answering a probe with 0 would
state something untrue; and the refusal copy is **per subcommand**, because "nothing
was claimed" on a refused `release` would be wrong in the dangerous direction — that
claim is still held and still being renewed. Same guard, same reasoning as
`bin/lib/review_claim_cli.rb` one lane over.

## D — the reclaim guard (conductor ↔ builder)

A is conductor↔conductor. The builder half — `bin/agent-worktree cleanup --reclaim`
reclaimed a builder's **fresh** worktree out from under them. The tempting local
heuristic does **not** work:

> A brand-new branch off `release` and a branch whose work was **fast-forward merged**
> onto `release` are **git-identical**: both are clean, both have HEAD == base, both
> are 0-ahead. A `HEAD == base` test (`git_head_at_base?`) can't tell a fresh desk from
> a done-and-merged one — and the cleanup tests correctly assert a merged-at-base
> worktree **is** reclaimable. So no git-state signal distinguishes them.

The correct discriminator is **external**: the worktree's task carries a live
build-claim lease (`ClaimLease.live?`) while a builder is on it, and is
terminal/unclaimed once shipped — the **same lease** A uses. Task
`reclaim-guard-live-claim` enforces it on **every** path that can destroy a desk, not
just candidate selection:

- **One predicate, one place.** `reclaim_verdict(record) → [reclaimable?, hold_reason]` is
  the single decision, routed through by `cleanup_partition`, the under-lock re-verify,
  `doctor`, **and** the registry snapshot. The registry is the conductor's front door
  (`bin/qa-intake` builds its Cleanup Candidates section straight off `cleanup_candidate`
  and prints a `remove … --yes` for each), so a disagreement there means everyone believes
  a desk is protected while the front door still recommends tearing it down. The registry
  carries the verdict as a `withheld_reason` **string** — not a `withheld_by_live_claim`
  boolean, which would misname the board-outage case as a live builder. (An earlier cut had
  a `reclaimable?` helper that *nothing called* while the three sites re-implemented the
  conjunction inline — the invariant has to be carried by a function the paths actually use.)
- **Consumers read the verdict, never the prose.** `bin/qa-intake` decides its cleanup
  recommendation from `cleanup_candidate`/`withheld_reason`, not by substring-matching the
  issue text. It used to join the issue list and test `include?("cleanup candidate")` — so a
  desk whose issue read *"…; **not** a cleanup candidate"* matched, and the conductor's front
  door recommended `remove --yes` on a desk with a live builder at it. A negation that
  inverts under a substring test is a landmine wherever the answer is consumed to destroy;
  the held-desk text now says "withheld from reclaim" and never contains the phrase at all.
- **Re-verified under the lock.** `--reclaim --yes` re-reads the claim immediately before
  each irreversible teardown, bypassing the per-slug memo. The candidate list is computed
  once, but teardowns run serially inside the lock, so a builder who sits down and claims a
  task **mid-sweep** would otherwise be destroyed on minutes-stale evidence. A TOCTOU window
  remains between that check and the teardown; it is an **accepted residual** (closing it
  needs a lease on the worktree itself, and the blast radius is a fresh desk).
- **Loud, not silent.** A withheld desk is named with its reason and the builder's
  heartbeat age (`ClaimLease.heartbeat_age`). "No clean merged or base-equivalent
  candidates" would be a *lie* about a desk that is clean and base-equivalent and simply
  occupied.
- **Fail-open, except where it would destroy something.** The "no live claim found" cases are
  not alike, so the destroy path splits them:
  - *lapsed* — we checked, the builder is gone → reclaimable everywhere.
  - *unbound* — we cannot identify the desk, so there is nothing to look up → a forced
    fail-open everywhere (it warns). `TASK_RECORD_SLUG` is written by `bind-task`, never by
    `new`, so a builder inside the `new → bind-task → move building` window has no claim to
    check. That is the original incident's own desk; bind immediately after `new`.
  - *bound, but the board could not be read* — we know the desk **could** be claimed and
    failed to find out. **Withheld everywhere.** The board 500s under Postgres pressure
    during heavy parallel devops — exactly when many worktrees exist and the sweep runs — so
    outage and mass-reclaim are **correlated**, and failing open reopens the original
    incident precisely when everyone believes it is covered. Withholding during an outage is
    a deferral; nominating a desk you could not verify leads to an irreversible teardown.

  **There is no "advisory" lane.** Every caller answers *"is this desk a cleanup
  candidate?"*, and that answer is consumed to destroy: the registry feeds `bin/qa-intake`,
  which prints a `remove … --yes` per candidate; the cleanup dry-run prints the same command;
  `--write` files it in the delete-later ledger; doctor labels it a candidate. An earlier cut
  split these into "destroy" and "advisory" and let the advisory ones fail open — so during
  the very outage this guard exists to survive, the sweep withheld a live builder's desk
  while the front door recommended tearing it down. Only `remove … --yes`, the explicit
  operator override, still proceeds (with a warning).
  Every branch that gives up on checking **says so**: a guard that silently disables itself
  is worse than no guard. (`nil` vs `{}` from the board read carries this: `{}` is a task we
  read that carries no claim; `nil` is a board we could not read.)
- **The board read is genuinely bounded** (10s, `AGENT_WORKTREE_TASK_TIMEOUT`), because it
  **kills** the child. `Timeout.timeout` around `Open3.capture3` bounds *nothing* —
  `capture3`'s ensure joins the wait thread, which blocks until the child exits, so the
  `Timeout::Error` is swallowed into that join (a 2s guard around `sleep 6` returns after
  6s). A hung board would otherwise stall a whole sweep while the code claimed to be safe.
- **`remove … --yes` stays the explicit operator override** — it warns on a live claim but
  does not block (you may be evicting a desk whose session died mid-lease). Only the
  *automatic* paths refuse.

The **merge** half is a no-op by construction: `bin/release` merges only
`reviewed`/`assembled` tasks, whose build claims have already lapsed (the status line
renews only while `building`), so a live-building task never reaches the merge path —
the stage gate already prevents it.

## Follow-ups (separate tasks)

- **C** — enforce the global concurrency budget (make the ≤5 / PG-20-conn cap real).
- **Per-act lanes** — DONE for review AND the two release acts (2026-07-21): review
  left the role lease for a per-TASK claim (`TaskReviewClaim`), and `qa-release` /
  `production-deploy` left for the per-RELEASE `ReleaseConductorClaim` (assembler /
  deployer, section B), so the lock lives on the finest record each act contends over
  and a stale lease can never strand a global lane. Only `clean-up` remains on the
  `avi` shift (it sweeps shared worktrees, not one release); splitting it further is a
  caller-side config flip, no model change.

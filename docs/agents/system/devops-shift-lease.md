# DevOps shift lease — one live conductor per role

The elegant fix for concurrent devops/builder collisions: two Avi heartbeats, an
Avi heartbeat launched alongside a `pr-review`, two `qa-release` sweeps racing the
release candidate, or a conductor's `cleanup --reclaim` evicting a builder who just
sat down. One primitive — the build-claim lease (`lib/claim_lease.rb`) — applied to
two more scopes.

## The problem

Devops acts fan out (reviewer subagents, `heroku run` dynos, `bin/release` CLI).
Two same-role sessions running at once **duplicate the work** (both pick the same
PRs), **exhaust the board's Postgres 20-connection limit** (combined fan-out), and
**race shared state** (two `qa-release`s merge → the candidate goes N-behind;
`cleanup --reclaim` reclaims an active desk). The ≤5 cap was documented, not
enforced; review/conductor acts took no lease at all.

## A — the shift lease (`avi` / `steffon` / `alex`)

`DevopsShift` is a board-held singleton **per lane**, where a lane is a ROLE/shift
key. It reuses the build-claim lease math verbatim: a holder is a LIVE INSTANCE
(session id + per-process nonce, `SessionIdentity.nonce`) under a **120s TTL**
renewed by a **detached renewer the acquiring run starts for itself**. `acquire` is
an atomic compare-and-set (one row per lane, taken under `with_lock`) so two
simultaneous acquirers serialize and exactly one wins.

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
- **Headless** — a holder with no status line retains the lane for the whole run.
  Asserted, not assumed: `test/models/devops_shift_test.rb` walks a 20-minute window
  (ten TTLs) refusing a second acquire at every step, and
  `test/lib/devops_shift_renewer_integration_test.rb` spawns the REAL detached
  renewer against a stub board and asserts its renewals carry the holder's own
  session + nonce (a renewer with the wrong nonce posts happily while the board
  no-ops every call — the same bug wearing a disguise).
- **Different lanes coexist** — `steffon` (qa-release) and `avi` (review/ship) are
  distinct leases, so those acts run side by side; only two of the SAME role collide.

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
and the
`avi`/`steffon`/`alex` acquire-or-stand-down preambles in `pr-review.md`,
`qa-release.md`, `production-deploy.md`. Enforcement is cooperative (the SOP stands
the loser down) per the studio's honor-system posture; the exit code (0 acquired /
10 stand down / 1 fail-open) makes it scriptable.

The lane is a role, not an act, so a single Avi session that runs `pr-review` then
`production-deploy` holds `avi` across both (a re-`acquire` by the same instance is a
no-op renew).

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
- **Per-act lanes** — the lease is keyed by an arbitrary string; splitting `avi` into
  `review`/`ship` is a caller-side config flip, no model change.

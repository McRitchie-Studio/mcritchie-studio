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
renewed by the status-line heartbeat. `acquire` is an atomic compare-and-set (one
row per lane, taken under `with_lock`) so two simultaneous acquirers serialize and
exactly one wins.

- **Simple** — the careless double. Session A holds `avi`; a second Avi launch
  `acquire avi` → the row is live-held → `acquired:false` → the CLI prints
  `🛑 avi shift already held — STAND DOWN` naming the holder, and exits **10**. The
  SOP tells the second session to stop. No duplicate reviews, no doubled fan-out.
- **Crash** — A dies mid-shift, stops renewing; within the TTL the lease lapses and
  the next launch `acquire`s it (`disposition: expired`). Self-healing — a dead
  shift never wedges the lane.
- **Different lanes coexist** — `steffon` (qa-release) and `avi` (review/ship) are
  distinct leases, so those acts run side by side; only two of the SAME role collide.

Surface: `bin/devops-shift acquire|renew|release|status`; the board endpoints
`POST /api/v1/devops_shifts/{acquire,renew,release}` + `GET …/devops_shifts`; the
status-line renewer (reads the `<sid>.devops-shift` marker `acquire` writes); and the
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
  the single decision, routed through by `cleanup_candidates`, the under-lock re-verify,
  `doctor`, **and** the registry snapshot. The registry is the conductor's front door
  (`bin/qa-intake` builds its Cleanup Candidates section straight off `cleanup_candidate`
  and prints a `remove … --yes` for each), so a disagreement there means everyone believes
  a desk is protected while the front door still recommends tearing it down. A
  `withheld_by_live_claim` field says so explicitly. (An earlier cut had a `reclaimable?`
  helper that *nothing called* while the three sites re-implemented the conjunction inline
  — the invariant has to be carried by a function the paths actually use.)
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
- **Fail-open, but never quietly.** A lapsed claim, an unreadable board, an unbound task, or
  an unexpected error all leave the desk reclaimable — only a *confirmed* live claim
  withholds it. Every one of those branches **says so** on the cleanup and destructive
  paths, because a guard that silently disables itself is worse than no guard. The unbound
  case matters most: `TASK_RECORD_SLUG` is written by `bind-task`, never by `new`, so a
  builder inside the `new → bind-task → move building` window has no claim to check — that
  is the original incident's own desk, and it now announces itself.
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

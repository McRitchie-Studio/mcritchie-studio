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
terminal/unclaimed once shipped — the **same lease** A uses. `cleanup_candidates` now
excludes a git-eligible worktree whose bound task is live-claimed (`task_live_claimed?`,
reading the task's `devops` claim via the same board seam as the PR autofill,
`task_record_for_pr`). **Fail-open:** an unbound task, an unreachable board, or a lapsed
claim all yield reclaimable, so cleanup never wedges; only a confirmed live claim
protects. The claim check runs only for the few git-eligible candidates. Task
`reclaim-guard-live-claim`.

The **merge** half is a no-op by construction: `bin/release` merges only
`reviewed`/`assembled` tasks, whose build claims have already lapsed (the status line
renews only while `building`), so a live-building task never reaches the merge path —
the stage gate already prevents it.

## Follow-ups (separate tasks)

- **C** — enforce the global concurrency budget (make the ≤5 / PG-20-conn cap real).
- **Per-act lanes** — the lease is keyed by an arbitrary string; splitting `avi` into
  `review`/`ship` is a caller-side config flip, no model change.

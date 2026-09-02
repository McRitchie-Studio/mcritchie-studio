# Agent Presence — the surface an agent reads before it starts

**Status:** design, 2026-09-01. Author: jasper. Task:
https://mcritchie.studio/tasks/agents-cannot-see-each-other

Every agent in this house must answer one question before it does anything
expensive: **who is doing what right now, and is it safe for me to start?**
There is no place to read the answer. This document designs that place, and
names the one slice to build first.

It is architecture — the *why*. It is not an execution path, and no SOP
depends on it.

---

## 1. What it cost, measured

One session, five agents, 2026-09-01. Full numbers on the task record.

| # | Cost | Measured |
|---|------|----------|
| 1 | Could not identify which live session held a piece of work | 372 of 747 session records name a task (49.8%). Resolved only by messaging the peer; had it been unreachable, live work would have been archived |
| 2 | An agent starved for 60+ minutes | Three certs launched with no shared view of capacity; load 355, swap 98%, 530 MB free of 22 GB |
| 3 | A 45-minute run lost | SIGTERM at its 2700s ceiling, 11% complete, killed by a `bin/release prepare` sweep no status command reports |
| 4 | Process name mistaken for process state | Two idle `bin/ship` processes in a CI wait read as competing certs. The grep that usually gets this right is right *by coincidence* |
| 5 | Every snapshot went stale between read and act | A load average of "31, falling" was 190 when acted on |

**One number needed correcting, and the correction moved a design decision.** The
task record reports binding at 47% — 372 of 788. The 788 mixes two artifact
families: 747 session records plus 41 `.activity-usage.json` token-usage
baselines, which carry no task by design. The real rate is **372/747 = 49.8%**.
The rest of §5(a) explains why raising that number is the wrong goal.

These do not average out as agents are added. Each new agent both consumes
capacity and becomes invisible to the others, so the cost is superlinear —
which is why this ranks above any single-fix finding on the board.

---

## 2. The finding that reframes the problem

The premise "agents cannot see each other" is true in effect. It is not true in
the way it sounds. **There are already nine state surfaces. None of them compose,
and each answers a question adjacent to the one an agent actually asks.**

| Surface | Where | Answers | Liveness model |
|---------|-------|---------|----------------|
| Cert runlock `cert-run.json` | local, in each desk's **git dir** | is a suite running against *this desk's* test DB | **OS identity** (pid + start time) — exact, no timeout |
| Build claim (`claimed_session`/`claim_nonce`/`claim_expires_at`) | board | who holds this task | TTL 120s + renewer, fail-open |
| Devops shift lease | board | who holds this *role lane* | TTL + anchor renewer |
| Review claim | board | who is reviewing this task | TTL + anchor renewer |
| Release conductor claim (`assembler`/`deployer`) | board | is a release live | TTL + anchor renewer |
| Migration lane claim | board | who holds the migration lane | TTL + anchor renewer |
| Session markers `.agents/sessions/<id>.*` | local | what the statusline should display — **stops naming the task once the session moves to a desk** | **none** |
| Desk context `<desk>/.agent-context.json` | local, per-desk | what this desk holds — **but never whose session it is** | none |
| Worktree registry | local | what desks exist | none — a manual snapshot |

Two conclusions follow, and they set the whole design.

**First: the question splits in two, and only one half is answered anywhere.**

- **Ownership** — *is this unit of work already held by a live peer?* Partially
  answered: remotely, per-object, TTL-approximate.
- **Capacity** — *does this machine have room for what I am about to run?*
  **Answered nowhere at all.** `bin/agent-worktree preflight_capacity!` sounds
  like it covers this and does not: it guards free **Redis DB slots**. The
  documented "5 concurrent" cap guards the **board's Postgres connections**.
  Neither knows the machine's CPU or RAM exists.

**Second: every capacity fact is local, and every claim we own is remote.** That
is the structural gap. The board can never answer a capacity question — it does
not know this machine exists, each read costs a round trip, and its connection
ceiling is the very reason concurrency is capped at 5.

Measured, for scale: globbing every runlock across all seven repos (116 worktree
git-dirs) plus one full `ps` costs **~50 ms**, no network and no board
connection. Cost #3's sweep was not unknowable. It was published as a board
claim — `release-claim any-live --role assembler` answers it today, and exactly
one caller has ever asked.

---

## 3. The governing principle

> **No claim asserts its own liveness. Every claim carries the OS's proof of
> identity, and the READER decides.**

This is `bin/lib/cert_orphan_guard.rb`'s rule, promoted from one file to a
surface. It is the entire answer to the constraint that makes or breaks this
design, and it is why the design is not a heartbeat.

**Why not a heartbeat or a TTL lease.** The house already has five TTL leases
(`Task`, `DevopsShift`, `TaskReviewClaim`, `ReleaseConductorClaim`,
`MigrationLaneClaim`),
and they have already demonstrated the failure mode twice:

- The shift lease was renewed by `bin/statusline` — i.e. by a *UI paint*, not by
  work. A headless session painted nothing, so its lease lapsed mid-review, so
  the lane reported FREE while its holder was still working: two Avi supervisors
  ran concurrently and duplicated four reviewer lanes on PR #601. **The guard
  reported protection it did not provide.**
- In the other direction, renewers that outlived their work polled the board
  every 30s for a day after their tasks shipped, spending the account-wide
  1Password cap. The outage presented as "1Password is down."

A TTL answers *"did someone check in recently"* — a proxy for *"is someone
working."* Choosing the TTL is choosing which way to be wrong: too short kills
live work, too long wedges peers. The process table answers the real question,
for free, with **no timeout to tune and no renewer to leak.**

### Reuse decision, stated plainly

**I am REUSING `CertOrphanGuard`'s identity rule and EXTENDING its scope. I am
not replacing it, and I am not modifying its reaping.**

- **Reused as-is:** the `(pid, os_start_time)` identity proof — `ps -o lstart=`
  compared as an opaque string, never a parsed clock; the atomic `write tmp +
  rename` publish (its own comment records that a plain `File.write` was
  observable at zero bytes and **4.6% of reads taken at that moment returned
  nil**); and the posture *prove it is ours or refuse*.
- **Extended:** the guard grades **one** lock, for **one** purpose (*may I reap
  this orphan?*), in **one** desk's git dir. The presence reader grades **many**
  claims, for a **different** purpose (*may I start?*), across the whole machine.
- **Deliberately narrowed:** the reader's only verbs are **report** and **unlink
  a proven corpse**. It never signals a process. Reaping stays exactly where it
  is, with its proof-of-ours rule untouched.

The guard's insight is that a pgid is a recyclable integer, so *liveness is not
identity*. A nine-day-old lock whose pgid had been recycled once made it kill an
unrelated bystander. That is why identity, not a pid, is the thing on disk — and
the same reasoning applies unchanged to a phase marker.

---

## 4. The claim record

One file per unit of heavy work.

```
.agents/sessions/<session-id>.presence-<kind>-<pid>
```

It lives in the **session-marker namespace on purpose**, not in a new directory.
That namespace already has a single owner (`bin/lib/session_markers.rb`), a
sandbox choke point every mutation passes, a private path builder, and a
containment test. Adding a store means re-earning all four. It also keys every
workload to the session that launched it, which is what makes fact (a) fall out
of the same glob rather than needing a seventh surface.

```json
{
  "kind":       "cert | sweep | ship | session",
  "phase":      "working | waiting",
  "weight":     "suite | light | idle",
  "pid":        41578,
  "started_at": "Tue Sep  1 11:05:12 2026",
  "session_id": "a89c0c33-…", "agent": "jasper",
  "task_slug":  "agents-cannot-see-each-other",
  "repo": "mcritchie-studio", "root": "/…/.worktrees/…", "lane": "mapped-tests",
  "began_at":   "2026-09-01T20:29:00Z"
}
```

`phase` carries the distinction cost #4 is about: **`waiting` consumes nothing.**
`started_at` is the OS's rendering of the process start time — the identity
proof, and the only field that decides whether any of the others may be believed.

**Any new writer must launder its path through
`TaskUsageSandbox.enforce!(..., store: "session-marker")`.** This is enforced,
not advised: `test/lib/state_store_containment_test.rb` re-derives the mutation
set from source and refuses any method that so much as *holds* a raw marker path,
in any spelling. It is the reason the namespace has one owner, and it is why a
seventh store would have to re-earn a guarantee this one already has.

**`SessionMarkers` writes are not atomic today.** They are plain `File.write`,
which is exactly the torn-read the runlock measured at 4.6%. Giving that store
an atomic write path is a prerequisite of the first slice that *writes* — and it
retroactively fixes every existing marker. It is not needed by slice 1, which
writes nothing.

---

## 5. The four facts

For each: what is written, by whom, when it clears, how a peer reads it, and —
the question that decides whether the design is finished — what happens when the
writer dies.

### (b) Cert phase — *already published; nobody reads it*

The most important finding in this document. `CertProcess.run_bounded` writes the
runlock at the instant a lane is **spawned**, and clears it in `settle` once
that lane's process group is gone. A clean lane's group is already gone, which
grades `:absent`, which clears the lock.

**So the runlock's lifetime already equals the window in which a suite is
actually consuming the machine.** That *is* fact (b). It is written per desk, it
already carries full identity, and it was designed from the start to survive a
SIGKILL. It is simply not readable across desks, because it is deliberately
hidden inside each git dir where `git status` cannot see it.

| | |
|---|---|
| **Written** | `cert_pid`, `cert_started_at`, `pgid`, `pgid_started_at`, `lane`, `db`, `started_at` |
| **By whom** | `CertProcess.run_bounded`, per lane, at spawn |
| **Cleared** | by `settle` when the group is provably gone; by the next cert's `CertOrphanGuard.preflight`; **kept on purpose** when a reap is refused, because then the lock is the only record naming the survivor |
| **Read** | glob `*/.git/cert-run.json` + `*/.git/worktrees/*/cert-run.json`, grade each |
| **On death** | the file stays; the reader grades it a corpse on the very next read, because the pid is gone or its start time no longer matches |

**This changes the shape of `/tasks/certs-publish-no-phase`.** That task assumed
certs must be taught to publish a phase. They largely already do. What remains
is narrower and should be re-scoped: **read the phase certs already publish**,
and add an explicit `phase` field only where one process genuinely spans both
states — which is `bin/ship`, not the cert.

### (c) Sweeps and ships

`bin/ship` writes **nothing locally for its entire ~12-minute run**. Its eight
phases exist only as stderr strings and header comments; the boundary that
matters is cert (line 285) → CI wait (line 536). `bin/release prepare` takes
flocks — invisible to anything not itself contending for them — plus a board
claim that answers *"is a release live"*, not *"is a sweep saturating this
machine."*

| | |
|---|---|
| **Written** | a claim with `kind: ship\|sweep`, `phase`, `weight`, identity |
| **By whom** | the process itself, at each phase boundary it already prints |
| **Cleared** | by the writer on graceful exit — an optimization only; by the reader on any proven corpse |
| **Read** | the same glob and the same grader as (b) |
| **On death** | identical: a corpse the reader recognizes with no timeout |

### (d) Machine headroom — a derivation, not a mechanism

Cost #5's load average was not misread. A load average is an exponentially
weighted mean over 1/5/15 minutes; it necessarily lags. It reports where the
machine has *been*, and *"may I start?"* is a question about where it is *going*.

Live claims answer the forward question directly:

```
headroom = SUITE_CAPACITY − Σ weight(c) for every claim c graded LIVE and phase == "working"
```

`SUITE_CAPACITY` is a named, measured constant. Today's evidence puts it near
**3** on this 14-core / 48 GB box — three concurrent suites produced load 355 and
98% swap — and it must be calibrated from measurement, never guessed. Load
average stays in the output as **corroboration, never as the gate**: high load
with no live claims is reported as *unattributed load*, which is a diagnosis, not
a green light.

**(d) therefore needs no mechanism of its own.** It is arithmetic over (b) and
(c). That is what makes it possible to sequence this design instead of building
all of it.

### (a) Session → task — *the join is broken in a different place than it looks*

The task record frames this as a reliability problem: binding happens half the
time and should happen always. **The evidence says otherwise, and the correct
design follows from the difference.**

**Half of all sessions genuinely have no task.** Proven by set equality, not by
sampling: 375 records lack a `task_slug`, and exactly 375 records have a key set
that is a subset of what the SessionStart mascot writer emits. **375 == 375.**
Not one record is a partial or aborted write. Every unbound record is precisely
what `bin/task session-mascot` writes when a session opens, in a session where
`write_feature_marker` never ran at all. They are orchestrators, review sessions,
questions, and aborted starts — short, root-cwd, board-untouched. Bind rate also
splits sharply by runtime (Claude 66.6%, Codex 28.0%), which is a usage pattern,
not a fault.

So **a backfill would be a regression**: it would convert honest silence into a
confident lie. What the surface needs is a first-class *no task held* state.

**The real defect is a broken join, and it is structural.** Two files each hold
one half of the answer, and neither carries the other's key:

| File | Knows the session | Knows the task |
|---|---|---|
| `.agents/sessions/<id>.json` | yes — it is keyed by session id | **stops recording it** once the session moves to a desk |
| `<desk>/.agent-context.json` | **no — it has no session field at all** | yes, and it is refreshed on `new` / `up` / `status` / `bind-task` |

`bin/task:1160` is `return if Dir.pwd.include?("/.worktrees/")` — and it is
deliberate, not a bug: the comment says a worktree session overrides the marker
with its own `.agent-context.json`. That reasoning is sound for the statusline,
which only ever asks about *itself*. It fails completely for a peer asking about
*someone else*, because the desk context has no session id to hand back. Verified
across every desk on this machine: not one carries one.

The consequence is exact, and it is what cost #1 actually was: **for precisely
the sessions doing the most work — the ones at a desk — the session record's
`stage` freezes at its last pre-desk value, and the desk that holds the live
truth cannot say whose it is.** A session that ships from its worktree leaves
`stage: building` on disk forever. The peer I had to message was an unbound,
mascot-only record — exactly the shape above.

| | |
|---|---|
| **Written** | `session_id`, plus the anchor pid and its start time, added to the desk context the desk already writes |
| **By whom** | `write_context_marker`, on the refreshes it already performs |
| **Cleared** | never explicitly; the anchor's death is what ends it |
| **Read** | glob `*/.worktrees/*/.agent-context.json`, grade the anchor, join on `task_slug` |
| **On death** | graded a corpse against the process table, exactly like every other claim |

The identity primitive already exists: `bin/lib/session_identity.rb#nonce` walks
the ancestry to the long-lived `claude`/`codex` process and hashes **pid + start
time** — the same proof, already trusted by every lease in the house. Recording
the two components it already derives is what makes the join *gradeable* rather
than merely present.

`task_slug` should be read as a **set**. An orchestrator legitimately holds
several tasks at once, and a rule demanding exactly one recreates the lie a
backfill would.

---

## 6. The killed-writer answer

The reader takes **one** `ps -Ao pid,pgid,state,lstart,command` snapshot so every
claim is graded against a consistent world, then grades each claim:

| Grade | Condition | Reader's action |
|-------|-----------|-----------------|
| `live` | pid alive **and** start time matches exactly | **count it**; report kind, phase, weight, task, agent |
| `dead` | nothing alive at that pid | ignore for capacity. A proven corpse — reclaimable, but see below |
| `recycled` | pid alive, start time differs | ignore for capacity. Provably not ours — and we never signal it |
| `unverifiable` | pid alive, no start time recorded | **count it conservatively and NAME it.** Never silently trust, never silently discard |
| `malformed` | unparseable, or names no pid | discard loudly; the backstop scan speaks for any real load |

**Unlinking is a LATER slice's verb, and never the cert runlock's.** §3 gives the
reader two verbs, report and unlink — but only the first belongs to slice 1,
which touches nothing on disk (§9). And when a writing slice does reclaim
corpses, the cert runlock stays exempt: `CertProcess.settle` KEEPS that lock
whenever `reap_group` returns `:refused`, and `:refused` is *precisely* the
`recycled` row above — "a stranger holds the recycled number." The lock is then
the only record naming a process the cert declined to kill, so deleting it turns
a detectable orphan into an unnameable one. §5(b) says the same from the other
side. A reader that unlinks it has not narrowed the guard's power; it has
destroyed the guard's evidence.

**Why a killed writer cannot wedge anyone.** A killed process leaves its file
behind — by design, exactly as the runlock does. But that file's only claim to
being live is a pid and a start time the OS will contradict on the very next
read. There is no timeout to elapse and no renewal to miss, so **the wedge window
is zero, not one TTL.** This is the property a heartbeat cannot offer: a stale
heartbeat is indistinguishable from a slow one until its TTL expires.

**The one residual staleness, and its bound.** A *live* writer's `phase` can be
out of date — it left the cert phase but died before rewriting, or crashed
between boundaries. A peer then over-estimates cost and waits. That staleness is
**bounded by the writer's own lifetime**: when the process exits, the claim is a
corpse on the next read. So the worst case is bounded latency, never a permanent
wedge — which is the precise hazard this design was required to avoid.

That asymmetry is deliberate and it is the design's safety argument:
**over-reporting cost buys delay; under-reporting cost buys a saturated machine
and a lost 45-minute run. Every error mode is arranged to land on the latency
side.**

---

## 7. How it fails safe

**Missing** — no claim, or the whole surface absent. The reader falls back to a
**backstop scan** for heavy processes carrying no claim and reports them as
*unattributed*. It must never print "idle" as a conclusion drawn from an empty
directory. Worst case it degrades to today's grep, plus honesty about what it
cannot attribute. (This mirrors the guard's own backstop, which asks the test DB
who is holding it and *names* the holder rather than guessing.)

**Stale** — impossible for liveness, which is re-derived from the OS on every
read. Possible for phase and weight, bounded by the writer's lifetime, and
biased toward over-reporting.

**Lying** — a claim cannot lie about being alive; the process table is the
arbiter and the claim gets no vote. It can only mis-state its own *weight*, while
alive. The backstop corroborates: heavy load with light claims is reported as
such.

**Showing a graveyard** — the session store never garbage-collects: 747 records
reach back to June, and on a representative day **4** were touched in the last 24
hours. Any lister must apply a freshness cutoff and grade before it prints, or it
will present a cemetery as a roster. This is not a cosmetic concern — a reader
that displays 743 dead sessions beside 4 live ones is one an agent will stop
reading, and an unread surface answers nothing.

**The reader itself failing** — it is read-only and takes no locks, so a crashed
reader changes nothing. A non-zero exit means *unknown*, which is today's state.

---

## 8. What I am NOT proposing

Scope discipline is the point of this document.

1. **No daemon, no central broker.** Nothing to start, supervise, or restart. A
   daemon is one more process that can die and lie; truth is computed on read.
2. **No new heartbeat and no fifth TTL lease.** See §3 — that is the defect, not
   the fix.
3. **No migration of the existing board claims.** Build, review, shift, and
   release claims answer ownership questions *across sessions and machines* and
   stay where they are. This surface answers capacity questions about *this
   machine*. Moving them is a far larger change with no measured cost pushing it.
4. **No change to `CertOrphanGuard`'s reaping.** The reader never signals
   anything, ever.
5. **No scheduler and no admission control.** The surface *informs* a launch
   decision; it does not gate one. An automatic gate that is wrong wedges the
   whole machine, and we would be building it before a single day's evidence that
   the reading can be trusted. Gating is a later step needing its own
   justification.
6. **No board changes, no migration, no new tables.** The board's connection
   ceiling is already a measured constraint.
7. **No `/deployments` UI work** in any of the slices below.
8. **Not built on `bin/agent-worktree snapshot --write`.** It is a full sweep —
   112 desks, a `git status` each, and a board POST — and its output is a
   manually refreshed, non-atomic, unlocked 255 KB file. A fast "who is working"
   read must never sit behind it.

---

## 9. The slices, in order

All five are filed. This design builds none of them.

| # | Task | Closes |
|---|------|--------|
| 1 | [`agent-presence-reader`](https://mcritchie.studio/tasks/agent-presence-reader) | cost #4, most of #2 |
| 2 | [`desk-context-names-session`](https://mcritchie.studio/tasks/desk-context-names-session) | cost #1 |
| 3 | [`certs-publish-no-phase`](https://mcritchie.studio/tasks/certs-publish-no-phase) — **re-scoped, see below** | cost #4 |
| 4 | [`sweeps-publish-local-claim`](https://mcritchie.studio/tasks/sweeps-publish-local-claim) | cost #3 |
| — | [`archive-refuses-unknown-holder`](https://mcritchie.studio/tasks/archive-refuses-unknown-holder) | cost #1, unblocked |

### Slice 1 — `bin/agent-presence`, the READER ALONE. **Build this first.**

Over claims that already exist. **It writes nothing.**

Enumerate runlocks by direct glob (`*/.git/cert-run.json` and
`*/.git/worktrees/*/cert-run.json` — no registry, no `git` invocation); take one
`ps`; apply §6's **grades** — and only the grades: it unlinks nothing and
signals nothing; print a table, a `headroom` line, and the backstop's
unattributed processes. `--json` for agents; exit codes for scripts.

Why this one pays for itself alone:

- **It cannot make anything worse.** Zero new markers means zero new ways to
  wedge a peer — the failure the constraint calls strictly worse than the grep.
  A reader-only first slice is the only version of this design whose worst case
  is *no change*.
- **The facts are already on disk.** The runlock already carries full identity
  and is already correct under SIGKILL. Fact (b) arrives with **no writer change
  at all** — see §5(b).
- **The grader is the shared cost.** Every later fact reuses it. Paying for it
  once, against the cheapest possible writer, validates read-derived truth on a
  file already proven under kill *before* anything riskier depends on it.
- **It replaces a check that is correct by luck.** `ps aux | grep -E
  "full-suite-check|fast-check|rails test"` catches the cert phase and misses the
  CI wait by coincidence of naming; nothing in it *encodes* that distinction, so
  it degrades silently the first time a lane is renamed. The reader's answer is
  derived from the process table by construction.
- **Measured cost: ~50 ms, no network.**

### Slice 2 — complete the session ↔ task join

Add `session_id`, `anchor_pid`, and `anchor_started_at` to the desk context
`write_context_marker` already writes on every refresh. The reader gains reverse
lookup: *which live session holds task X.* Closes cost #1.

**This slice shrank as the evidence came in**, and that is why it moved ahead of
the two below. Scoped from the task's framing it was the largest item — a new
write discipline across hooks, on a path six writers have already fought over,
plus a policy question about orchestrators. Diagnosed properly (§5(a)) it is
**three fields in a marker that already exists**, already carries
`schema_version` and `generated_at`, and is already refreshed by exactly the
sessions whose records go stale. The severity was never in question; only the
size was, and the size was wrong.

### Slice 3 — `bin/ship` publishes its phase

The one place the runlock genuinely cannot answer, because a ship *spans* both
states: cert (`bin/ship`'s `2/8 G1 cert`) and CI wait (`6/8 CI settle wait`). Today it writes
nothing locally for its entire ~12-minute run. This is what remains of
`/tasks/certs-publish-no-phase` once §5(b) is accounted for. Requires the atomic
write path in `SessionMarkers` (§4). Closes cost #4.

### Slice 4 — sweeps publish locally

`bin/release prepare` / `ship` write a local claim beside the board claim they
already take. Closes cost #3.

### Standalone, and not blocked by any of the above

**The archive path should refuse rather than guess when it cannot identify a
task's holder.** Cost #1 is the worst outcome on the list — destroying live work
beats losing a run — and this neutralizes it without waiting for the surface. It
is a posture change, not a mechanism, and it should be filed and fixed on its own
schedule.

Fact (d), headroom, needs no slice. It sharpens automatically as 1 → 4 land,
because it is arithmetic over what they publish.

---

## 10. Open questions

- **`SUITE_CAPACITY` must be measured, not assumed.** Today's evidence suggests
  ~3 on this box. Slice 1 should log observed load against live claims so the
  constant is calibrated from data before anything consumes it.
- **Weight classes need a real vocabulary.** `suite | light | idle` is a first
  cut; a parallel Rails suite forks per-core, so weight may need to be a number.
- **Subagent lineage is already half-recorded.** The board's `session_mascots`
  table carries an indexed `parent_session_id`, populated by `bin/task
  session-mascot`, but it is never persisted locally. It is the cheapest existing
  hook for showing that five "sessions" are one operator's fan-out rather than
  five independent claimants — worth folding into slice 2 if it is free there.
- **A fossil to clear.** `.agents/locks/gate-in-progress-rel-20260709-38f895`
  (2026-07-09) has **no writer anywhere in the tree** — a residue of a removed
  implementation. A marker no code writes is exactly the confusion this design
  exists to end. Route it through the delete-later ledger.

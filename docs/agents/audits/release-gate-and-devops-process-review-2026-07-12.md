# Release gate + DevOps process review — 2026-07-12

**Author:** Alex (orchestrator) · **Task:** https://mcritchie.studio/tasks/harden-release-gate-isolation

Written after fixing the G3/G4 gate false-negatives. Part 1 records what the
instrument was actually doing wrong (one finding overturns the standing
diagnosis). Part 2 is the prioritized, costed proposal for the rest of the
DevOps cycle. Everything in Part 2 beyond P0 is a FOLLOW-UP — deliberately not
in the fixing PR.

---

## Part 1 — What was actually wrong with the gate

### The standing diagnosis was half wrong. Bootsnap is innocent.

The accepted story for the 2026-07-11 false-negatives (rel-20260711-7f2913) had
three mechanisms: (1) bootsnap serving stale `main` code after the transient
checkout, (2) `CLAUDE_CODE_SESSION_ID` leaking into the suite, (3) seed/order DB
pollution. Mechanism (1) was the load-bearing one — it was the only story that
explained the signature symptom, `NoMethodError: undefined method 'count' for an
instance of Task` at `release/retro.rb:76` (main's `rework_rounds(events)`
executing against release's `rework_rounds(task)` test).

**It is wrong.** Bootsnap keys its compile cache on each file's mtime + size, and
`git checkout` bumps mtime, so it recompiles from the new source. Verified by
experiment in a throwaway clone: prime the cache with the old method signature,
`git checkout` the new one, boot — the app loads the **new** code
(`[[:req, :task]]`), with and without `DISABLE_BOOTSNAP=1`.

This matters beyond trivia. The proposed fix was to clear `tmp/cache/bootsnap*`
before each gate run. That would have been a **placebo**: it would have changed
nothing, the gate would have kept false-failing, and the next reviewer would have
had even more reason to believe a red gate meant broken code. **Verify the
mechanism before building a fix around it** — a plausible story that survives
because nobody tested it is more dangerous than an open bug.

### The real root cause: a multi-minute suite over a shared, mutable tree

Two facts combine into the bug:

* **Test-env autoloading is lazy.** `config/environments/test.rb` sets
  `config.eager_load = ENV["CI"].present?`. CI therefore loads the whole app at
  boot — **one coherent snapshot**. The local gate does not: Zeitwerk reads each
  file off disk the first time it's referenced, spread across the minutes the
  suite runs, and views are lazier still (compiled on first render).
* **The primary checkout is shared and mutable.** `with_primary_checkout` is an
  **advisory `flock`**. It excludes other `bin/release` invocations and *nothing
  else* — not a concurrent agent session, not a hand-run `git checkout`, not any
  other tool.

So a `git checkout` in the primary *while the gate's suite is running* gives the
suite a **torn snapshot**: test files already loaded from `release`, models
autoloaded minutes later from `main`.

**Verified by experiment** (same throwaway clone): boot Rails on the new code,
flip the working tree to the old code *while the process is live*, then reference
`Release::Retro` for the first time — Zeitwerk autoloads the **old**
`rework_rounds(events)` into a process whose tests came from the new tree.
`eager_load=false`, bootsnap on and faithfully serving current on-disk content.
That is the `retro.rb` symptom, reproduced on demand.

It also explains everything the bootsnap theory had to strain for: why the
failures were **seed-dependent** (the seed changes *when* each class is first
autoloaded, so it changes what the flip catches), why the count **grew
run-to-run**, and why CI and a clean worktree were **always green** (CI
eager-loads; a clean worktree is nobody else's to flip).

The gate's own code comment named this hazard and tried to fix it by *widening*
the flock around the suite. That made contention worse without closing the hole,
because the processes doing the flipping never took the lock.

The shared **test DB** is the same bug in a second dimension: a concurrent suite
(an agent worktree, a hand-run `bin/rails test`) writes the DB the gate is
reading.

### The fix (P0, in the accompanying PR)

Give the gate a working tree and a database **nobody else touches**:
`Release::GateWorkspace` runs the suite in a private detached git worktree pinned
at the SHA under test, with its own `<repo>_gate_test` database. Nothing can flip
the tree, nothing shares the DB, and — a free and significant win — **the primary
never leaves `main`**, so the conductor stops fighting feature sessions for it.

`Release::GateEnv` additionally scrubs `CLAUDE_CODE_SESSION_ID` /
`CODEX_THREAD_ID` from the gate's spawn env (mechanism 2 — real, and still worth
closing: it made the suite's Open3 tests resolve the *operator's live session*
where CI resolves none) and keeps the existing mise-ruby PATH pin. `nil` values
mean *unset*, so the scrub reaches every grandchild the suite spawns.

### The safety hole: a skipped G3 silently disarmed the production gate

Reported as "unsetting `qa_test_cmd` makes G4 self-skip". The mechanism is
different from the report — and worse, because it survives the obvious reading of
the code.

`ship_gate_skip?` decided G4 could skip by comparing **registry strings**
(`test_cmd == qa_test_cmd`) and `frozen_sha == qa_sha`. Neither term proves a
suite ever *ran*:

* `qa_shas` is stamped by the **QA deploy loop**, not by the gate. It records
  what was **deployed**, never what was **certified**.
* the registry is re-read at ship, so it can differ from what `prepare` read.

Blanking `qa_test_cmd` alone does *not* trigger the skip (`"bin/rails test" != ""`).
But the documented gate-skip recipe does: comment out `qa_test_cmd` so G3 skips →
**restore the file before ship** (ship's preflight refuses a dirty primary) → the
registry now reads equal again, the deployed SHA matches, and **G4 skips a suite
nothing ever ran.** The last gate before an irreversible production deploy
disarmed itself, and said "already green" while doing it.

Fixed by making G3 record what it actually certified
(`metadata["qa_gates"][repo] = {sha, cmd, ok}`, written **only** on a green suite)
and making that record the *only* thing G4 accepts as grounds to skip. No record,
a red record, a different command, or a drifted SHA all **fail open** — the gate
runs.

---

## Part 2 — Proposal: the rest of the cycle, prioritized and costed

Ordered by (risk closed ÷ cost). P0 ships in the accompanying PR; everything else
is a follow-up task.

### P1 — Run CI on the `release` branch, and cross-check the gate against it · ~30 min, then ~half day

**The gap:** `.github/workflows/ci.yml` triggers on `pull_request` (any base) and
`push` to **`main` only**. The release branch tip — *the exact artifact that gets
QA'd and shipped* — is the one commit CI never runs. Every merge into `release`
produces a new SHA (the merge commit) whose combined behavior was never tested in
a clean environment. We have been relying on a local gate to certify a commit that
has no independent verdict at all.

**Do first (cheap):** add `release` to the push trigger. One line. Now every RC
tip gets an authoritative, clean-env verdict, and the local gate has something to
be checked against.

**Then (half day):** add a SHA-addressed CI query — `gh api
repos/{owner}/{repo}/commits/{sha}/check-runs`, folded through the existing
`CiStatus.parse` shape (it currently only reads PR-scoped `gh pr checks`; the
`check-runs` payload needs a small `status`/`conclusion` → `bucket` shim) — and
have G3 record **both** verdicts. When they disagree, that is a high-value alarm:
either the gate is lying again or CI is.

**What I would NOT do:** replace the local gate with CI outright (the operator's
instinct). CI on a push is asynchronous — the gate would have to block and poll,
adding minutes of latency to `prepare` and a hard dependency on GitHub for a local
operation. Now that the gate is hermetic, the right shape is *local gate is the
verdict; CI is the auditor*. Revisit once we have a few releases of agreement data.

### P2 — Direct-drive the long conductor ops · ~1 h (SOP edits)

`qa-release` ran as a Steffon **subagent**, detached mid-sweep, and left a
**partial release candidate**: one PR merged, nothing gated, deployed, or
assembled. `production-deploy` is already direct-drive for exactly this reason.

**Recommendation:** any op that mutates shared state across many minutes
(`qa-release`, `production-deploy`, `archive-shipped`) is **direct-driven by the
conductor session**, never delegated to an ephemeral subagent. Subagents stay for
*read* fan-out (reviews, audits, searches) where a detach costs a retry, not a
half-applied mutation.

**Also:** `bin/release prepare` is already self-healing, so the recovery from a
detach is simply *re-run it*. The SOP does not say so. Say so, loudly — the
partial RC sat there because nobody was sure re-running was safe.

### P3 — Retire the shared primary as an operational surface · ~1 day

P0 already takes the *gate* off the primary. What still mutates it: `ff_main_local`
at ship, and the artifact dance. And the ship **preflight refuses a dirty
primary** — so a concurrent feature session with staged work has aborted a
production ship (and the correct response, per the memory, is a delicate
stash-to-a-labeled-branch rescue, because discarding it would destroy a live
session's work).

**Recommendation, in order:**
1. Give `ship` its own dedicated checkout (same trick as the gate workspace) so
   the deploy never depends on the primary's state. Removes the whole
   dirty-primary abort class.
2. Until then, make the dirty-primary abort *actionable*: print the exact rescue
   command (commit to a labeled branch) instead of just refusing.

### P4 — One shared session-env neutralizer for the test suite · ~2 h

The `SESSION_KEYS` / `NEUTRALIZED_ENV` nil-out pattern is **copy-pasted across at
least five test files**, and ~14 subprocess-spawning test files don't have it at
all. There is no `test/support/`, and `test/test_helper.rb` says nothing about it.
P0's gate scrub protects the *gate*; it does nothing for an agent running
`bin/rails test` by hand in a worktree, which is how this class of failure keeps
being discovered.

**Recommendation:** extract one helper, apply it to every spawner test, and note
the rule in `docs/agents/modules/testing.md`: *a test that spawns a subprocess
must null the ambient agent-session vars.* This is the durable fix for mechanism
(2) — the gate scrub is the belt, this is the braces.

### P5 — Close the system-test gap in the gate · ~1 h to decide

CI runs `bin/rails db:test:prepare test test:system`. The hub's registered
`qa_test_cmd` / `test_cmd` is `bin/rails test` — **no `test:system`**. So the
gate's "full suite" is not CI's full suite, and a system-test regression reaches
QA ungated. Either add `test:system` to the gate command (it now has an isolated
workspace + DB to run it in, so this is finally safe) or state explicitly in the
registry comment that system coverage is delegated to CI — but P1 must land first,
or nothing checks it at all.

### P6 — Correct the record · ~15 min

The bootsnap diagnosis and the gate-skip recipe are both written down as fact (in
agent memory and in the review notes). Both are now wrong: bootsnap was never the
cause, and the gate-skip recipe is a **foot-gun that disarms the ship gate** — it
must not be used again. Update them, and record the exoneration; a wrong diagnosis
left standing costs more than an open bug, because it gets *applied*.

---

## The through-line

Every one of these is the same shape: **a check that shares mutable state with the
thing it is checking is not a check.** The gate shared a working tree and a
database with live sessions. G4 inferred its safety from a registry that could
change under it. The release tip is certified by a local run and never by CI. Fix
that shape and the false-negatives stop being a mystery.

An unreliable gate is worse than no gate — it punishes you for trusting it *and*
for not trusting it. The measure of P0 is not that the gate went green; it is that
a red gate now **means something**.

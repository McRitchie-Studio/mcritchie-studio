# Kickoff — Self-healing log rotation + archive sweep

Paste everything below the line into a fresh session started from
`/Users/alex/projects`.

---

Work from `/Users/alex/projects`. Make log growth stop being something anyone
has to think about. Two tasks, in this order.

## The problem, and why it went unnoticed

Every app already sets `config.logger = ActiveSupport::Logger.new(STDOUT)` in
`config/environments/production.rb`, so Heroku takes the stream and **production
was never affected**. No app configures the **dev or test** logger at all, so
those use the Rails default: an unbounded file. 1.2 GB of logs and 913 MB of tmp
accumulated in the one environment nobody watches.

`bin/clean-artifacts` already exists and does the right sweep. **Nothing calls
it.** The only references are three frozen June audit docs and the delete-later
ledger. A correct script that no process runs is how this rotted the first time —
so the fix must not depend on anyone remembering to run it.

## Task 1 — studio-engine: rotation that nobody runs

Add a `studio.logger` initializer to `Studio::Engine`
(`studio-engine/lib/studio/engine.rb`, which already registers
`initializer "studio.assets"` and a `config.after_initialize`):

```ruby
initializer "studio.logger" do |app|
  next if Rails.env.production?        # Heroku takes STDOUT; leave it alone
  next if app.config.logger            # never clobber a host that chose its own

  size = Rails.env.test? ? 8.megabytes : 16.megabytes
  app.config.logger = ActiveSupport::TaggedLogging.new(
    ActiveSupport::Logger.new(Rails.root.join("log/#{Rails.env}.log"), 1, size)
  )
end
```

Why the engine and not seven `config/environments` edits: it rides the gem, so
one change reaches every app and every **future** app; it is config in a repo, so
every worktree is born with it and a fresh Mac restores it from GitHub; and
nobody ever runs anything.

Caps each checkout near 48 MB across dev + test, against the 138 MB per desk we
were carrying. `1` keeps one rotated file. Tune the two sizes deliberately now —
it is awkward to revisit later.

**Add a behavioral test, not a grep.** Assert the booted dev/test logger actually
carries a rotation cap. A test that greps for a config string passes forever
after someone reorders an initializer and breaks the behavior.

## Task 2 — mcritchie-studio: the sweep, on the archive beat

`bin/release archive` **already reclaims worktree disk** — see `def archive` at
`bin/release.rb:5622`:

```ruby
step("worktree reclaim preview: bin/agent-worktree cleanup --reclaim")   # :5646, --dry-run
step("worktree reclaim: bin/agent-worktree cleanup --reclaim --yes")     # :5672, --yes
```

Extend that pattern. Three changes:

**a. Fix `bin/clean-artifacts`.** Two defects explain exactly where the garbage
went:

- `RAILS_REPOS=(turf-monster mcritchie-studio)` at line 26 — 2 of 9 repos.
  Discover them instead (glob `*/config/environments`, or read the app registry).
  This is why `chain-ops/log/localnet.log` reached 388 MB.
- It only sweeps `$repo/log`, never `$repo/.worktrees/*/log` — where most of the
  volume lived.

It already has `--dry-run`, which matches the archive contract exactly.

**b. Wire it into `bin/release archive`** as a `step(...)` beside the existing
worktree reclaim, so `--dry-run` previews the sweep and `--yes` executes it. One
entry point; no new command for anyone to remember.

**c. Update `docs/agents/agents/steffon/sops/archive-shipped.md`** (77 lines):
add the sweep to **Procedure**, and add reclaimed bytes plus any app missing
rotation to the **Exit Seam** report.

### The part that makes it self-healing

Have the sweep **report any managed Rails app whose dev/test logger is not
rotating**. Add a satellite that does not inherit the engine config and the next
archive run says so — instead of it surfacing at 400 MB in six months. Make the
check behavioral, consistent with the house rule that a gate asserting a
declaration rather than a property is a gate that lies.

### Say this explicitly in the SOP

`archive-shipped` runs against the **production board** ("Do not add `--local`"),
but the disk sweep is **machine-local**. Note it, so a fresh Mac's first archive
run sweeping nothing does not read as an anomaly, and nobody expects reclaimed
bytes to be board state.

## Also in Task 2 — sweep stale docs on the same archive beat

Frozen snapshots pile up in the **live** doc tree and lose meaning fast. Same
beat, same command, same dry-run contract as the log sweep.

Today's pile — none of it referenced by anything in the live tree:

| Location | Lines | What |
|---|---|---|
| `docs/agents/audits/` | 3,283 | 18 files, all frozen snapshots |
| `docs/agents/system/` | 2,722 | 9 dated files misfiled into the live tree |
| `docs/agents/maintenance/worktree-disposition-2026-06-13.md` | 80 | one-off disposition record |

Add a docs-archive step to `bin/release archive` beside the log sweep: `git mv`
qualifying files into `docs/agents/archive/`, previewed by `--dry-run` and
performed by `--yes`.

**A file qualifies when BOTH hold:**

1. Its name carries a date (`YYYY-MM-DD` or `retro-rel-*`) **or** it lives in
   `docs/agents/audits/`; **and**
2. **nothing in the live tree references it** — check this at run time, per file.

Both halves matter. Rule 1 alone would sweep live handoffs; rule 2 alone would
sweep nothing, since some archives cross-reference each other.

**Never delete — always `git mv`.** History is preserved either way, but a move
keeps a stale inbound link resolvable by search instead of turning it into a
dead end. If a file qualifies on rule 1 but **fails** rule 2, skip it and name
it in the report — a referenced snapshot is someone's live citation, and the
referrer should be fixed first, deliberately, not silently orphaned.

Report moved-file count in the SOP **Exit Seam**, and add the step to
**Procedure** alongside the log sweep.

### While you are in there — cap the ledger

`docs/agents/maintenance/delete-later.md` is **1,014 lines** and grew 78 in a
single reclaim run. The ledger that tracks deletions is becoming the thing that
needs one. Give it a rollover: entries older than one release cycle move into
`docs/agents/archive/`, on the same archive beat.

## What rotation cannot reach

Two logs are not Rails logs, so no Rails config will ever touch them. They are
the reason the sweep earns its place alongside rotation:

| File | Size | What it is |
|---|---|---|
| `chain-ops/log/localnet.log` | 388 MB | Solana localnet; the repo has been dormant since 2026-06-15 |
| `turf-vault/test-ledger/rocksdb/000020.log` | 173 MB | Scratch validator ledger |

## Sequencing and DevOps routing

1. **studio-engine first** — the initializer + its test. Additive.
2. **Publish the gem.** Engine is at `0.32.3`; hosts pin `~> 0.30` / `~> 0.31`,
   so a `0.33` minor satisfies them.
3. **Hub task** — `clean-artifacts` fix, `bin/release archive` wiring, SOP update.
4. **Hosts adopt** the gem bump on their normal cadence.

Gem-repo specifics — studio-engine does NOT behave like an app:

- **The fast lane does not work for gem repos.** `bin/task begin` / `bin/ship`
  assume an app checkout. Use plain worktrees and the long-form commands.
- **Gem-repo PRs retarget to `release`**, not `accepted`.
- **Consumer CI reads the consumers' `main`**, so anything that would break a
  host needs the host forward-compatible first. This change is additive and
  self-skipping (`next if app.config.logger`) — verify that, don't assume it.
- Certify from the same root you built in.

One engine task and one hub task. Do not span both repos in a single task.

## Definition of done

- A fresh `bin/rails console` in any app on the new gem shows a dev logger with a
  rotation cap; production still logs to STDOUT.
- `log/development.log` and `log/test.log` stop growing past their caps in every
  checkout and every worktree, with no one running anything.
- `bin/clean-artifacts` sweeps all managed repos **and** their worktrees.
- `bin/release archive --dry-run` previews the sweep; `--yes` performs it.
- The archive Exit Seam reports reclaimed bytes and names any app missing
  rotation.
- The engine test fails if the rotation cap is removed.

## Note on the current floor

There is roughly 1.2 GB of logs and 913 MB of tmp on disk right now, predating
the fix. Do not clear it by hand first — running the repaired
`bin/clean-artifacts --dry-run` and then the real sweep against that mess is the
best available proof the work is correct.

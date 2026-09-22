# Kickoff — Self-healing log rotation + archive sweep

> **DELIVERED — do not paste this into a session to build it.** Both tasks
> shipped. Task 1 is studio-engine `0.33.0` (`initializer "studio.logger"` in
> `Studio::Engine`); Task 2 is the hub's `bin/clean-artifacts` /
> `bin/archive-docs` and their `bin/release archive` steps. This file is kept
> as the DESIGN RECORD — why each shape was chosen — and is corrected below
> wherever the built thing differs from what this brief proposed. To RUN any of
> it, read `docs/agents/agents/steffon/sops/archive-shipped.md`.
>
> It keeps its undated name on purpose: `DocsArchive.frozen_shape?` treats
> undated files in this directory as live instructions, not snapshots, so the
> archive sweep will never retire it.

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

Shipped as `initializer "studio.logger"` in `Studio::Engine`
(`studio-engine/lib/studio/engine.rb`), beside the existing
`initializer "studio.assets"`:

```ruby
initializer "studio.logger", before: :initialize_logger, after: :load_environment_hook do |app|
  cap = Studio::LogRotation.cap_for(
    env: Rails.env,
    host_logger: app.config.logger,
    override: Studio.local_log_max_bytes
  )
  app.config.log_file_size = cap if cap
end
```

**THE ORDERING IS THE WHOLE TRICK, and this brief first proposed it with
none.** The original draft assigned `app.config.logger` from a bare
`initializer "studio.logger" do |app|`. That is a **silent no-op**, and
studio-engine's CHANGELOG `0.33.0` says so in as many words. Rails'
`:initialize_logger` is a *bootstrap* initializer: it runs before every railtie
and engine initializer and does `Rails.logger ||= config.logger || <default>`,
so by the time an ordinary engine initializer runs the logger already exists.
Verified, not assumed — a probe boot kept Rails' 100 MB cap and its own file.

What shipped instead hands Rails the **size** before Rails builds the logger,
which is exactly the knob `:initialize_logger` reads
(`ActiveSupport::Logger.new(config.default_log_file, 1, config.log_file_size)`),
so Rails keeps ownership of the path, formatter, level, and tagging. Which cap
to use — and whether to touch anything at all — belongs to
`Studio::LogRotation.cap_for`, which is Rails-free and unit-tested a branch at a
time. Copying the shape this brief first proposed would have built the broken
version; that is why the correction is recorded here rather than the file
deleted.

Why the engine and not seven `config/environments` edits: it rides the gem, so
one change reaches every app and every **future** app; it is config in a repo, so
every worktree is born with it and a fresh Mac restores it from GitHub; and
nobody ever runs anything.

Caps each checkout near 48 MB across dev + test, against the 138 MB per desk we
were carrying. The `1` in the Rails call above is the retained-file count, so
each env keeps one rotated sibling. Tune the two sizes deliberately now — it is
awkward to revisit later.

**Add a behavioral test, not a grep.** Assert the booted dev/test logger actually
carries a rotation cap. A test that greps for a config string passes forever
after someone reorders an initializer and breaks the behavior.

## Task 2 — mcritchie-studio: the sweep, on the archive beat

`bin/release archive` **already reclaims worktree disk** — see
`bin/release.rb#archive`:

```ruby
step("worktree reclaim preview: bin/agent-worktree cleanup --reclaim")   # the --dry-run arm
step("worktree reclaim: bin/agent-worktree cleanup --reclaim --yes")     # the --yes arm
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
2. **Publish the gem.** Shipped as `0.33.0` — a minor, which the hosts'
   two-segment pins already admitted. This brief originally named the
   then-current version in prose; **do not reintroduce one.** studio-engine's
   README and `docs/RELEASE.md` deliberately name no current version, because a
   hand-written one rots silently — theirs read `v0.6.1` for fifty minors. Read
   `studio-engine/lib/studio/version.rb`, or RubyGems, for what is live.
3. **Hub task** — `clean-artifacts` fix, `bin/release archive` wiring, SOP update.
4. **Hosts adopt** the gem bump on their normal cadence.

Gem-repo specifics — studio-engine does NOT behave like an app:

- **The fast lane does not work for gem repos.** `bin/task begin` / `bin/ship`
  assume an app checkout. Use plain worktrees and the long-form commands.
- **Gem-repo feature PRs target `accepted`**, like every other repo. This
  brief said `release`, which is false now and would misroute the PR. The
  authority is LOCAL, not a PR census: `bin/pr-review`'s `ACCEPTED_BRANCH`
  and `bin/lib/task_pr_set.rb`'s `LANDING_BASE` both name `accepted`, and
  review merges every feat PR there in every repo. Do not re-derive the
  rule from a recent window of PRs — measured 2026-09-22 across all 346
  studio-engine PRs, #1-#7 were based on `main` and nine merged FEATURE
  PRs went to `release` (#8 through #67, the last on 2026-07-30). Every
  non-promotion PR since #67 is based on `accepted`.
- **Consumer CI reads the consumers' `main`**, so anything that would break a
  host needs the host forward-compatible first. This change is additive and
  self-skipping — though **not** by the `next if app.config.logger` guard this
  brief proposed. `Studio::LogRotation.cap_for` returns `nil` when a host named
  its own logger (`return nil if host_logger`), and the initializer assigns
  nothing when the cap is `nil`. Verify that, don't assume it.
- Certify from the same root you built in.

One engine task and one hub task. Do not span both repos in a single task.

## Definition of done — all delivered

- ✅ A fresh `bin/rails console` in any app on the new gem shows a dev logger
  with a rotation cap; production still logs to STDOUT.
- ✅ `bin/clean-artifacts` sweeps all managed repos **and** their worktrees —
  discovered, not listed (`ArtifactSweep.rails_repos`, plus the
  `.worktrees/*` glob beside it).
- ✅ `bin/release archive --dry-run` previews the sweep; `--yes` performs it.
- ✅ The archive Exit Seam reports reclaimed bytes and names any app missing
  rotation — see the Exit Seam in
  `docs/agents/agents/steffon/sops/archive-shipped.md`.
- ✅ The engine test fails if the rotation cap is removed
  (`studio-engine/test/integration/log_rotation_test.rb` and
  `test/lib/studio/log_rotation_test.rb`).

**One clause did NOT come true as written, and it is the standing gap.** This
brief promised that local logs stop growing "in every checkout", "with no one
running anything". The cap rides the gem, so it reaches exactly those apps that
**load studio-engine at or above the floor** — `ArtifactSweep::ENGINE_CAP_FLOOR`,
`0.33.0`. An app pinned below it, or carrying no engine dependency at all, is
untouched and still grows to Rails' 100 MB default. The archive audit measures
this per app rather than trusting the pin, and reports the loose ones by name;
`unknown` means the audit could not boot that app, which is never a pass. So the
promise is "every app on the gem", not "every checkout".

## Note on the current floor

When this brief was written the machine carried roughly 1.2 GB of logs and
913 MB of tmp, all of it predating the fix, and the plan was to leave it alone:
running the repaired `bin/clean-artifacts --dry-run` and then the real sweep
against that mess was the best available proof the work was correct. Those
numbers describe the machine as it was then, not as it is now. For a current
reading, run `bin/clean-artifacts --dry-run` and read its own report.

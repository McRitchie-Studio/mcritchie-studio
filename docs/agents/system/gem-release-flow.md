# Gem release flow: publish the final at prepare

Decided 2026-10-28 (task `qa-tests-final-gem`). `bin/release prepare` now publishes
the final gem version, consumers lock that final before the pre-QA gate, and
`bin/release ship` deploys the SHAs QA already gated. The ship no longer
re-locks a gem's consumers or waits for fresh CI on the re-lock commits. On the one
release measured, that removes about 31 of the ship's 47 minutes.

## Prior art: this repo published the final at prepare once before

Final-at-prepare is not new here. It was the flow until the candidate flow replaced
it (`test/lib/release_ship_final_gem_test.rb`, "the old flow published the final at
prepare"), and the failure it is known for happened: on 2026-08-15 prepare published
studio-engine 0.48.0, committed the consumer lock bump at once, and CI's
`bundle install` ran before RubyGems served the version. The pre-QA gate went red
twice, and 0.48.0 was stranded, published and never shipped
(`test/lib/release_cli_gem_await_test.rb`). That is why qa-release said "prepare never
pushes a final gem version".

Two things the old flow lacked are now in place, and they are what make B safe:

1. **The propagation wait.** `await_published_gems!` holds every lock bump until
   RubyGems' compact index serves the version and it installs locally, and CI runs
   `.github/scripts/await-gem-propagation.sh` before `bundle install`. The 0.48.0
   cause cannot recur, and the wait is already paid at prepare under A, so B adds
   none.
2. **Allocation and the `v*` tag.** In August a stranded version needed a person to
   bump the version file by hand (qa-release's STRANDED GEM WORK row). Today phase 0
   allocates the version from the last `v*` tag and RubyGems. Prepare under B tags
   `v<x.y.z>` at the tree it published, so the next prepare either reuses it (same
   tree) or allocates the next patch (the tree moved). Nobody types a version.

## The three flows

| | A: today until this change | B: final at prepare (chosen) | C: hybrid, credit the re-lock |
|---|---|---|---|
| prepare publishes | `X.rcN`, tagged `rc-X.rcN` | `X`, tagged `vX` | `X.rcN` |
| consumers lock for the pre-QA gate and QA | `X.rcN` | `X` | `X.rcN` |
| ship publishes | `X`, after a local `release-check --build`, a file-by-file compare with the candidate, and a served-checksum read | nothing (`X` is live; it skips) | `X`, as in A |
| ship re-locks consumers | yes: one Gemfile.lock commit per consumer on `release` | no | yes |
| ship waits for consumer CI | yes: one fresh full CI run per consumer | no | no: credits QA's green to the re-lock commit, because the two gems are proven equal file by file |
| tree that deploys | the re-lock commit: QA never ran it, CI did | the tree QA and CI both ran | the re-lock commit: neither QA nor CI ran it |
| `accepted` after the ship | diverged (it lacks the re-lock commit; see production-deploy's DIVERGED row) | not diverged | diverged |
| a red QA costs | an `rc` number (free) | the version `X` (fix forward to the next patch) | an `rc` number |

## What the ship spent its time on

Release `rel-20261028-4dcb39` (studio-engine 0.116.1, six consumers). The ship ran
14:12 to 14:59 Denver. The log has no clock, so the times below come from RubyGems
and GitHub (UTC; Denver is UTC-6).

| Segment | From | To | Minutes | Under B |
|---|---|---|---|---|
| ship gate read (credited greens) and authority | 20:12 | ~20:13 | 1 | stays |
| gem `release-check --build` (the engine suite, again), build, contents compare | ~20:13 | 20:24:11 (`0.116.1` registered on RubyGems) | 11 | gone: prepare ran it |
| CDN await, re-lock six consumers, push six commits | 20:24:11 | 20:26:50 (last re-lock commit) | 2.7 | gone |
| re-lock gate: six fresh CI runs | 20:25:55 (first run starts) | 20:43:02 (last settles: mcritchie-industries, attempt 2 after a `ci / system` flake) | 17 | gone |
| hub deploy dispatched | 20:44:08 | | | starts here |
| hub, then five satellites, post-deploy hook, seal, cardless re-lock | 20:44 | 20:59 | 15 | stays |

Without the flake the slowest re-lock run settled at 20:40:27 (cyvasse), so the
re-lock gate alone costs 14 to 17 minutes and the gem segment as a whole 28 to 31.
**Saving per gem release: about 30 minutes off a 47-minute ship (the ship becomes
about 16 minutes), plus one full CI run per consumer (six here) and the
re-lock-only flake retry.** Prepare does not grow: it already published, tagged and
checksummed one artifact and ran the gem's suite before it; it now does that for `X`
instead of `X.rcN`.

The prepare that day (12:34 to 14:03, with a nine-minute GitHub stall and a re-run) is
unchanged in shape by B.

## Why B

1. **QA tests the artifact production runs.** Under A, QA ran `X.rc1` and production
   runs `X`. The ship proves the two equal file by file, which is good, but the tree
   that deploys is still a commit QA never ran. Under B the gem bytes, the lock and the
   app SHA are the ones the pre-QA gate, QA and CI all read.
2. **It removes the slowest serial wait in the ship**, and the one place a CI flake
   could hold production (the 2026-10-28 ship spent a retry on one).
3. **It removes the `accepted` divergence** every gem release created (the re-lock
   commit landed on `release` alone, and each consumer needed a merge reconcile).
4. **The cost is small and bounded.** A red QA burns one version number. Version
   numbers are free; the version file and changelog are written by the release, not
   by people.

C was rejected. It saves the CI wait but keeps the ship's gem build and re-lock, and
it ships a tree no gate ran, on the strength of an equality argument. B saves more
and weakens nothing.

## The failure story

**QA is red after `X` is published.**

- If the fault is in an app, eject that member and re-run `prepare`. The gem's tip
  has not moved, `X` is live and tagged `vX` at that tip, so prepare reuses it: no
  number is burned.
- If the fault is in the gem, the fix lands on the gem's `accepted` and the next
  `prepare` promotes it. Phase 0 allocation now sees commits past the `vX` tag with
  the version file still at `X`, so it allocates the next patch, `X+1`, commits it
  with the lock and changelog, and phase 2 publishes `X+1`. `X` is burned. The
  stranded-work guard reads the same `vX` tag, so the two can never disagree.
- If the gem member is ejected instead, consumers' `accepted` still lock `X`. A new
  guard refuses that at prepare and again before any deploy: a consumer may lock a
  registered gem's version above the one on that gem's `main` only when this release
  carries the gem at exactly that version (`Release::GemFlow.unshipped_final_findings`).
  This replaces, for finals, what the prerelease refusal did for candidates.

**Yank `X`, or leave it? Leave it.**

- A yank does not free the number. RubyGems never accepts a second push of a yanked
  version, so yanking buys no reuse.
- A yank breaks every lock that names `X`. Prepare committed `X` onto each consumer's
  `accepted` and `release`, and any desk cut since carries it. After a yank,
  `bundle install` on a fresh machine or in CI fails with "could not find
  studio-engine-X", so one red QA becomes red CI in six or more repos until each is
  re-locked.
- Leaving it is safe. Consumers pin `~> 0.116` (that is, `>= X`), and the next
  prepare re-locks every swept consumer to `X+1` with `bundle lock --update`. Nothing
  outside our apps consumes the engine. The guard above keeps `X` out of production.
- Yank only when installing `X` is itself harmful: a secret in the package, or code
  that does damage at load. Then yank, and re-lock every consumer to `X+1` at once.

**A RubyGems number exposed before QA.** Under A a prerelease is invisible to a
plain `bundle update`; under B, `X` is a normal release from prepare onward, so a
desk that runs `bundle update studio-engine` during the QA window picks it up. That
is the same tree `accepted` already locks, so it adds no new exposure.

## What changed in the code

- `Release::GemFlow` (new, pure): which flow runs (`RELEASE_GEM_FLOW=candidate`
  restores A for one release as a rollback lever), prepare's action for one gem, and
  the unshipped-final findings.
- `bin/release prepare`: phase 2 publishes the final through `publish_gem` (the same
  build, push, `vX` tag and served-checksum read the ship used), then the consumer
  lock bump commits `X`. The candidate entry-point check does not run, because no
  candidate is published.
- `bin/release ship`: unchanged code. With `X` live and every consumer locking it,
  `ship_gem` skips the push, `repin_consumers` finds nothing to re-lock, and the
  re-lock gate gates nothing. A release prepared under A still ships under A.
- Where the shorter ship shows: no surface carried a gem-release estimate that
  assumed the re-lock. `bin/release status` prints the ladder verdict and program
  drift only. The board's release summary (`app/views/tasks/_release_summary.html.erb`)
  shows the gem artifact, which is now the final from QA onward. `Release::Flow` and
  `bin/ship-clock` read actuals from shipped releases, so their Ship phase shortens as
  releases ship under B. The "about 12 minutes" in `building-sop.md` is a task submit,
  not a release, and is unchanged. The ship's printed steps (`bin/release prepare`'s
  dry run and step lines) now name the final flow.
- Unchanged in the ship: the producer-lock bump and the cardless-consumer re-lock
  (`relock_cardless_consumers`) still run after the deploy, at the final, as before.
  They are best-effort and do not hold production, so moving them earlier saves no
  ship time.

## Measuring it

The acceptance asks for a before-and-after on a real or rehearsed release. The
"before" is the table above, read from `rel-20261028-4dcb39` (the only gem release
measured). No release has shipped under B yet, so the "after" is an estimate from the
same release with the gem segment removed, about 16 minutes against 47. The "after" is the first gem release shipped under B:
read its ship's start from the log and its hub deploy dispatch from
`gh run list -R McRitchie-Studio/mcritchie-studio --workflow prod-deploy.yml`. The
expected gap is about one minute (gate read and authority), against 32 today.

Retire the candidate path (`RELEASE_GEM_FLOW=candidate`, `publish_gem_candidate`,
the candidate stamp and the ship's candidate compare) after two gem releases ship
cleanly under B.

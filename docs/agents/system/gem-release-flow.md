# Gem release flow: publish the final at prepare

Decided 2026-10-28 (task `qa-tests-final-gem`). `bin/release prepare` now publishes
the final gem version, consumers lock that final before the pre-QA gate, and
`bin/release ship` deploys the SHAs QA already gated. The ship no longer
re-locks a gem's consumers or waits for fresh CI on the re-lock commits. On the one
release measured, that removes about 31 of the ship's 47 minutes.

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
- Release status and `Release::Flow` read actuals (shipped releases' timestamps), not
  an estimate that assumes the re-lock, so neither needed a change; the ship phase on
  `/deployments` shortens as releases ship under B.

## Measuring it

The acceptance asks for a before-and-after on a real or rehearsed release. The
"before" is the table above. The "after" is the first gem release shipped under B:
read its ship's start from the log and its hub deploy dispatch from
`gh run list -R McRitchie-Studio/mcritchie-studio --workflow prod-deploy.yml`. The
expected gap is about one minute (gate read and authority), against 32 today.

Retire the candidate path (`RELEASE_GEM_FLOW=candidate`, `publish_gem_candidate`,
the candidate stamp and the ship's candidate compare) after two gem releases ship
cleanly under B.

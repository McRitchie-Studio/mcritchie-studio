# Open PR decisions — 2026-08-26

Every open pull request across the four active repos, with a decision and the
reason for it. Written by `/tasks/sweep-stale-open-prs`.

**Nothing here was bulk-closed.** A batch close of the dependabot queue would
also discard genuine security bumps, so each row is decided on its own terms.

## The census

| Repo | Open | Dependabot | Feature/other |
|------|------|-----------|---------------|
| mcritchie-studio | 17 | 14 | 3 |
| turf-monster | 15 | 13 | 2 |
| studio-engine | 5 | 0 | 5 |
| rolio | 1 | 1 | 0 |
| **Total** | **38** | **28** | **10** |

## The release-safety problem, stated once

Every dependabot PR in the three laddered repos targets **`accepted`**. That is
the rung Avi's `qa-release` sweep promotes **wholesale** — `bin/release prepare`
merges ALL of `accepted` onto `release` in one batch PR per repo. So merging any
one of them puts a dependency bump into the very next production release with
**no task, no shape, no test plan and no reviewer of record**.

**rolio is worse, not exempt.** It has no `accepted` branch at all, so its one
dependabot PR (#26) targets **`main`** directly — merging it skips both remaining
rungs and reaches production without so much as a QA deploy.

They are safe only while nobody merges them, and "nobody has yet" is not a
control. That is the finding; acting on it is an operator decision, not a
sweep's.

## Feature and other PRs — 10

| PR | Age | Decision | Why |
|----|-----|----------|-----|
| studio-engine #205 | 2026-08-26 | **leave — in flight** | `/tasks/trap-focus-in-modal-host`, actively `building` in another session. |
| studio-engine #210 | 2026-08-27 | **leave — in flight** | `/tasks/announce-modal-error-lines`, submitted tonight. |
| studio-engine #211 | 2026-08-27 | **leave — in flight** | `/tasks/stop-escaping-rail-handlers`, another session's. |
| studio-engine #212 | 2026-08-27 | **leave — in flight** | `/tasks/give-danger-text-an-ink`, submitted tonight. |
| mcritchie-studio #1023 | 2026-08-26 | **leave — in flight** | `/tasks/drop-desk-database-on-remove`, submitted tonight. |
| mcritchie-studio #1026 | 2026-08-26 | **leave — in flight** | `/tasks/retire-acquisition-studio-checkout`, submitted tonight. |
| turf-monster #437 | 2026-08-26 | **leave — in flight** | `/tasks/catch-the-erb-comment-leak`, submitted. |
| turf-monster #439 | 2026-08-26 | **leave — in flight** | `/tasks/auto-derive-lane-counter`, submitted tonight. |
| mcritchie-studio #550 | 2026-07-14 | **RE-HOMED** | Was orphaned six weeks. See below. |
| studio-engine #11 | 2026-06-27 | **operator's call** | See below. |

### studio-engine #194 — resolved

Listed as an orphan when this task was filed. It was **re-homed** to
`/tasks/ship-wallet-brand-unknown-mark`, brought up to date against `accepted`
(it was 36 commits behind), certified, reviewed and **merged**. No action left.

### mcritchie-studio #550 — re-homed, not closed

Open since 2026-07-14 with no board task; its original task was archived.
**Not superseded, and that was checked rather than assumed:** the branch is 3
commits ahead of `origin/accepted`, and current `bin/agent-worktree` still has
no unwind path for a failed `new`. The work has not landed.

At +2391/−66 across 16 files it is far too large to adjudicate inside a PR
sweep, so it now has a task: **`/tasks/rehome-atomic-worktree-bringup`**. That
task carries the warning that `bin/agent-worktree` changed twice on 2026-08-26
(PRs #1023 and #1026), so this branch will conflict and needs a rebase and a
fresh cert before its six-week-old green is trusted.

### studio-engine #11 — left for the operator

`feat/suite-consistency-cleanup`, opened 2026-06-27. Three things make it
Mr. McRitchie's call rather than an agent's: it is **his own PR**, it targets
the **wrong rung** (`base: release`, not `accepted`), and it is **conflicting**.
An agent closing an operator's PR, or silently retargeting it, is not a call a
sweep gets to make.

## Dependabot — 28

Grouped by what merging one would actually cost, since that is the decision.

### Major bumps — hold, each needs its own task

A major version is a behaviour change, and these ride into production
unreviewed if merged onto `accepted`. Several are load-bearing:

| PR | Bump | Why it needs a task |
|----|------|---------------------|
| ms #707 / tm #253 | minitest 5.27 → **6.0** | The test framework itself. A major here can change how every suite reports. |
| ms #708 | puma 7.2 → **8.0** | The production web server. |
| tm #318 | sidekiq 7.3 → **8.1** | Job runtime. See sidekiq-cron below — the two interact. |
| tm #261 | sidekiq-cron 1.12 → **2.4** | This repo already carries a live defect here (`active_job: true` is mandatory on Sidekiq 7). A major bump lands on top of that. |
| ms #711 / tm #257 | brakeman 7.1 → **8.0** | The security scanner. A major may change findings, which is a CI verdict change. |
| tm #258 | omniauth-rails_csrf_protection 1.0 → **2.0** | **CSRF protection on the auth path.** Highest care of the set. |
| ms #884 | image_processing 1.14 → **2.0** | Attachment pipeline. |
| ms #556, #557, tm #179, #370, #371, ms #971 | GitHub Actions majors (`setup-node` 4→7, `download-artifact` 4→8, `cache` 4→6) | These change CI itself. `download-artifact` v4→v8 in particular affects the receipt artifacts the executed-set gates depend on. |

### Minor and patch — adopt as one batch, with a task

| PRs | Bumps |
|-----|-------|
| ms #881, tm #321 | aws-sdk-s3 |
| ms #882, tm #320 | sentry-rails |
| ms #885 | sentry-ruby |
| tm #319 | stripe |
| ms #883 | bootsnap |
| ms #880 | solid_queue |
| tm #254 | jbuilder |
| ms #704, tm #259 | web-console |
| ms #911 | astral-sh/setup-uv |
| rolio #26 | selenium-webdriver — **based on `main`**, see above |

These are the ones where sitting still has a real cost — `sentry-*` and
`aws-sdk-s3` in particular accrue fixes. They still should not be merged
individually onto `accepted`; a single task that takes the batch, runs the
suite once and carries a reviewer of record is both safer and cheaper than 14
unreviewed merges.

## What this sweep did NOT do

- **Merged nothing.** Every dependency bump reaching production is an operator
  decision, and the whole finding above is that merging onto `accepted` skips
  review.
- **Closed nothing.** The only two candidates were #550 (not superseded — now a
  task) and #11 (the operator's own).
- **Retargeted nothing.** Moving #11 off `release` would rewrite someone else's
  PR.

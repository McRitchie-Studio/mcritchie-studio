# DevOps v3 — the focus-session pipeline

> **Status:** proposal ratified by Alex on 2026-09-24, landing in phases. The
> published, illustrated version of this document is
> https://claude.ai/artifact/BfMajAcq9XNvUxUaR9yJny. This file is the
> repository copy and the one the phases cite. It supersedes
> [`devops-cycle-design.md`](devops-cycle-design.md) (v2) once phases 1 to 4
> land; until then v2 describes the mechanics still in force.
>
> **Names.** From this document on, **Alex** is the human owner and operator,
> and **Xan** is the orchestrator agent that used to be called Alex. Active docs
> adopt these names as they are rewritten; archived snapshots stay as written.

A focus session holds the epic, files tasks only when they are startable, builds
them in parallel, and reviews its own PRs. The pipeline runs one suite per tree.
The board reads its state from GitHub instead of being told. Alex's gates get a
clock.

## 0. What was decided, and what it changes

Alex's answers on 2026-09-24, each mapped to the design consequence it drives.

| Topic | Decision | Consequence |
|---|---|---|
| Bursts and WIP | No hard cap. Tasks should not sit in `designed`. A session holds the epic and files tasks only when ready to act. Plans change mid-flight. Agents organize for parallel work. | Epic plans live in the focus session; tasks are filed just-in-time; parallelism follows the dependency graph, not wave numbers (§3). |
| Who triggers review | Builders trigger their own PR reviews. The specialists review; the builder is the Pokémon. | The review wait and the human-launched review sweep leave the main path (§4). |
| Release cadence | Keep it. Written authority per session is not friction. | `qa-release` and `production-deploy` stay operator-launched acts (§6). |
| Review depth | Optimize it. | Tiered by observed diff; structured verdicts; specialists at review only (§4). |
| Rigor | Less about incidents, more about the app functioning. Core guidelines plus app and library specifics. | A six-layer protocol with a core and per-repo additions, one verdict per tree (§5). |
| Risk vs time | Time windows, not a risk score: 10 min UI approval, 20 min escalation, 30 min production authority. | Three operator windows with a defined default when the clock lapses (§6). |
| Where the conductor lives | Later, on a server with a heartbeat. | Nothing in v3 assumes a resident service. |
| Pause | Willing to pause DevOps work while it is rebuilt; build resiliency in. | Phased plan, each phase self-contained and reversible (§10). |
| Docs | AGENTS.md as a general view; agents drill into micro layers as needed. | Three layers: map, capability pages, archive (§8). |
| Guards | Prefer things that just work. | The catalog in §7 with a disposition per guard. |
| Learning loop | Bake it into the flow; grade on size, blockers, tokens, lines; 0 or 1 learning per task. | Auto-grade at ship, one line at most, only when a threshold trips (§9). |
| Names | Alex is the human; the agent is Xan. | §1. |

## 1. Names: Alex and Xan

The agent seat formerly named Alex becomes **Xan**: slug `xan`, Lead
Orchestrator, holder of the Documentation review seat, owner of `full-cycle` and
the learning loop. The Solana signing identity already called Xan
(`agent.xan.solana`, renamed from "Alex bot" on 2026-09-15) is unrelated and
does not change. The human is **Alex** everywhere; "Mr. McRitchie" retires from
active docs as they are rewritten.

Mechanics: the slug `alex` is a foreign key in activities, scout reports, task
events, builder stamps and review claims. The rename is one task: add the `xan`
agent row, migrate the rows, keep `alex` as a read alias for one release, then
drop it.

## 2. The shape of v3

```text
Alex + focus session ──files a startable task──▶ Pokémon builder ──PR green──▶ reviewer (subagent)
   holds the epic plan                            desk · build · ship           review · merge
                                                       ▲                            │
                                                       └────── blocker ─────────────┘
                                                                                    ▼
                                                                               (accepted)
                                                                                    │ Alex launches qa-release
                                                                                    ▼
                                                                          release → QA green
                                                                                    │ Alex launches production-deploy
                                                                                    │ (30-minute window)
                                                                                    ▼
                                                                              (main · shipped)

GitHub webhooks ─── CI verdicts, PR state ───▶ the board: a derived view, never told
```

Three rules:

1. **The focus session owns build and review.** It files tasks just-in-time,
   spawns builders in parallel, and spawns each PR's reviewer the moment it is
   green: Carl for code, Xan alone for prose (§4 tiers). Rework happens in the same desk with the same context.
2. **One suite per tree.** A tree hash earns one verdict, from CI. Every gate
   reads it; nothing re-runs an identical tree. Local certs become optional
   pre-flights that write no evidence.
3. **The board derives, it is not told.** Stage, PR, merge rung and CI state come
   from GitHub events the board already ingests. Agents stop stamping `merged`,
   `pr_url` and cert receipts by hand, so the tools that check those stamps
   against each other have nothing left to refuse.

At today's mechanics the idea-to-production floor on an empty board is 57 to 65
minutes: build 23 min at the median with ship's CI wait inside it, review 6 to 14
min with no queue, sweep to QA 14 min, ship 14 min. In v3 it becomes about 40 for
a median build and about 30 for a small one, once G3 and G4 credit the PR's tree
instead of re-running it.

## 3. Epics and just-in-time tasks

Measured: four sessions filed between 97 and 196 tasks each within a week; the
biggest single days were 54, 52, 45 and 43 cards; 60% of all tasks were filed in
bursts of six or more by one session in one day. Burst tasks drained at a median
of 8.3 hours with a p90 of 1.4 days, against 6.7 hours and 1.1 days for the rest.

**The epic plan.** An epic is a plan the focus session holds and keeps current:
goal, the pieces, their dependencies, what is done. It is not a card. Keep it as
a short markdown file in the epic's desk or the session's scratch, committed with
the first PR that needs it, so a fresh session can resume it. The board gets one
optional field, `epic_slug` on the task, and the card shows an **epic chip**
beside the task slug chip when one is set; clicking it filters the board to the
epic.

**The three filing rules.**

1. File a task only when it is startable now: every input it needs is merged to
   `accepted` or is being built in the same batch and can be stubbed.
2. Parallelism follows the graph, not the wave. The session launches builders
   for everything with no unmet dependency, bounded by the machine
   (`bin/agent-presence`), not by a count.
3. Re-plan freely, archive rarely. A plan entry costs nothing to rewrite; a filed
   task that turns out wrong is archived with one note naming the change of plan.

**The designed column** stays as a staging area measured in minutes. The card
shows its age. No refusal, no cap.

## 4. Builder-triggered review, and how deep

**The flow.** When a builder's `bin/ship` reaches `submitted` with a green PR,
the focus session spawns that PR's reviewer with the epic plan, the task, and the
recorded head: Carl for code, Xan alone for prose (tiers below). Carl runs the
primary review he runs today: gate-zero on the CI
verdict, the deep read, an optional light, a verdict, and the merge into
`accepted`. A blocker comes straight back to the session, which still has the
desk and the context. The standalone `pr-review` sweep stays only as the orphan
path for PRs whose session died.

**Who builds, who reviews, who arbitrates.**

- **The builder is the Pokémon.** One general builder soul, legion: it designs
  and builds anything a task needs. Nobody chooses a developer per task, and
  `--agent` disappears from the build lane. The mascot is the crew member on the
  card. Its soul document is written and polished as its own piece of work.
- **The specialists live at review.** Carl for backend, Shannon for UI, Jasper
  for on-chain, Steffon for infrastructure, Xan for docs. Their `role.md`
  checklists are the written standards. A block is structured so it can be
  learned from: the regression, the trigger that reaches it, and what right
  looks like.
- **The Pokémon may contest a block.** When the builder has evidence the block
  is wrong, it posts its position and fires a new SOP, `arbitrate-block`, run by
  Avi. Avi is the authority: he accepts the block, overrules it, or splits it,
  and his ruling is recorded on the task. Only a policy question Avi cannot
  settle goes to Alex, with the 20-minute window. Contesting is a power, not a
  reflex; the SOP asks the builder for its evidence first.
- **Every block and every ruling feeds the learning loop** (§9).
- **The session owns the verdict.** One review owner per PR by construction.

Souls to write or re-read in phase 1: the Pokémon builder soul and role, Avi's
soul plus `arbitrate-block`, the five specialists' review checklists, Xan's soul.

**What the reviews did.** 3,439 scout reports. Request-changes share fell from
35% in July to 17% in September. In 1,151 rounds with a second reader: both clean
63%, primary alone blocked 10%, light alone blocked 9%, both blocked 18%. A scout
report runs 2,666 characters at the median. Each Carl boots with about 25K tokens
of SOP before reading a diff.

**Tiers, chosen by the observed diff plus the task's risk tags.**

| Tier | The change | Who reads | Model |
|---|---|---|---|
| A · prose | Markdown, inert media, docs-guard tests only (`CodeDiff` decides) | One read by the documentation seat (Xan). No light. | fast |
| B · code, no risk tag | App or tooling code, under 400 insertions, one repo, no `payment` `solana` `auth` `migration` tag | Carl. Light at his discretion. | capable |
| C · risk or size | Any risk tag, or over 400 insertions, or more than one repo, or a schema change | Carl plus the domain light, mandatory. | strongest |

**Where the tiers sit.** A tier is decided per PR when review starts. It is one
rule in one config file, applies to every repo, and decides only how many
readers and which model. It does not decide what tests run.

| Stage | Question | Decided by | Granularity |
|---|---|---|---|
| Build | Which tests must the builder write? | the task's shape | per task |
| CI | Does the whole app still work on this tree? | the repo's suites (§5) | per repo, once per tree |
| Review | How many eyes, and how strong? | the tier | per PR |
| Release | Does the candidate boot, and who authorizes production? | release gates and operator windows | per release |

Four more changes: structured verdicts (verdict, blockers with triggers,
non-blockers, what was executed; prose goes in a PR comment); a `mutation-probe`
lane that flips the changed tests' assertions and reports survivors; acceptance
read from the epic plan, not only the bullets; `wait-for-ci` retired.

## 5. The rigor protocol

**The core, every repo.**

| Layer | Proves | Runs at |
|---|---|---|
| L0 static | Lint, security scan, importmap and docs-link integrity | PR |
| L1 unit | Pure logic | PR, sharded |
| L2 integration | Request → DB → job, externals mocked | PR |
| L3 journeys | The app's critical user journeys in a real browser, 5 to 10 per app | PR, sharded; the read-only subset against QA after deploy |
| L4 boot smoke | The deployed candidate answers and its read-only journeys pass | QA deploy, prod deploy |
| L5 seal | Production still answers after the ship, recorded, non-blocking | after prod |

**The one-verdict rule.** L0 to L3 run once, on the PR's tree, in CI. When the
merge into `accepted` produces the same tree, the verdict carries; a new tree
runs CI once more. `release` and `main` are fast-forwards and inherit it. G3 and
G4 read; they do not run. `bin/fast-check` stays as an optional one-minute
pre-flight that writes no evidence.

**Per-repo additions.**

| Repo | Adds | Gap today |
|---|---|---|
| mcritchie-studio | System tests for the board; docs registry tests; the production seal | None structural |
| turf-monster | On-chain journey against devnet (`contest-rehearsal`) | The devnet nightly fires every night and skips itself (131 of 132 runs skipped); make the rehearsal a QA post-deploy lane for on-chain diffs or keep it an operator stop and say so |
| studio-engine | Consumer CI against both apps; engine Playwright | None |
| solana-studio | Gem CI plus Playwright | None |
| turf-vault | Node and Rust tests via `bin/release-check`; upgrades by hand through Squads | No desk lane; certify from a plain worktree |
| mcritchie-industries | Rails suite plus one system test | No browser journeys; add three or declare the repo L3-exempt in the registry |

**What stops being asked of the builder:** typing tier tags (CI's executed-set
receipts say what ran); fingerprint-bound certs (stale evidence was the largest
DoR failure cause: 439 builder-side and 337 review-side); the bypass hatch, the
deferred receipt, the local full suite.

## 6. Operator windows

Measured: 274 UI approval requests, 100 approved, 46 dropped by the old handoff
bug; answered ones took 16 minutes at the median and 5 hours at p90. 55
escalations reached Alex; the next move landed 48 minutes later at the median.

| Gate | Window | While the clock runs | When it lapses |
|---|---|---|---|
| UI approval | 10 min | Card pulses with the magic link; the builder keeps going | Review proceeds, as today; the card keeps asking; a later answer is recorded |
| Escalation | 20 min | A contested block goes to Avi first (`arbitrate-block`); only a policy question he cannot settle reaches Alex, with both positions in one note | The ruling Avi recommended stands, labeled as an auto-decision; the task carries the open question |
| Production authority | 30 min | The release is QA-green; the session asks once with the slug and members | Per-launch mode: `ask` holds; `timed` ships when the window lapses with G3 green and no open escalation; `auto` ships on green. Default `timed`. The default and the length live in `config/release_builder.yml` |

Mechanically: one `window_expires_at` field per gate, set when the request is
posted, one command the session runs to wait on it, and a countdown on the card.
Landed in PR #1586: the three windows' minutes and the ship mode live in
`config/release_builder.yml`, read by `Devops::Windows`. Each countdown derives
from those minutes plus a timestamp the task or release already carries, so no
`window_expires_at` column was needed.

## 7. Guard catalog

Disposition: **keep** the check is about the real world and cheap; **derive** the
fact it checks moves to a single source so the check disappears; **delete** with
the mechanism it belongs to. The principle: a guard that compares two copies of
one fact is removed by removing the copy; a guard that checks a precondition in
the world stays; a guard that adjudicates a disagreement between people becomes a
window with a clock.

### Identity and attribution

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| Soul slug validation | Refuses `--agent Steffon` | A stamp that matches nothing | Added after four silent drops | derive: normalize, never refuse |
| Author set + reviewer exclusion | Stamps builders; keeps them off their own review | Self-review | Six blank stamps in one sitting; roster exhaustion when Carl builds | derive: authors from git; the Pokémon builds, specialists review |
| Acting identity (`gh api user` must 403) | Before a merge | Merging as Alex's personal account | Two such merges on 2026-08-29 | keep, inside the merge primitive |
| UNNAMED builders | Session-only claims count as unattributed | An incomplete author set | Frequent refusals | **done:** deleted in PR 1601 |

### Claims and leases

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| Build claim lease | 120 s TTL, detached renewer, `--steal`, holder progress, 1h29m desk idle | Two agents on one desk | Headless agents never renewed; ghost renewals; orphan watcher shells | **done:** deleted in PR 1596; the desk is the claim |
| Review claim lease | 3h25m TTL, atomic pop, renew beat | Two sessions reviewing one PR | 1,232 claims; lapses; the pop withheld green tasks | derive: a `reviewing_by` marker for the orphan sweep only |
| Migration lane | Global exclusive lease | Duplicate migrations | unmeasured | **done:** deleted in PR 1601; the collision detector covers it |
| Release conductor claim + presence claims | One assembler per release; a local sweep marker | Two sweeps racing; a cert killed by a sweep | A 45-minute suite killed at 11% | keep as one lock on the release |
| Agent presence | Reads machine load | Load 355, swap 98% | Measured once | keep |

### Certs and evidence

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| `fast-check` | Mapped tests, spine, scoped rubocop; stamps a receipt | Shipping an obvious break | 3,314 runs, 10% red, p50 1 min | keep as an optional pre-flight; no receipt |
| `full-suite-check` + fingerprint evidence | Local full suite; DoR re-grades the tree hash | A stale or partial cert | The top DoR failure: 439 + 337 refusals | **done:** deleted in PR 1589; the CI tree verdict replaces it |
| Cert root, tree and orphan guards | Refuse the wrong or dirty tree; reap zombie certs | Certifying someone else's code | False STALE 6 of 6 once; the reaper once killed an innocent process | **done:** deleted with the evidence system in PR 1589 |
| `control-check` | Replays pre-change tests for test-only diffs | A silently deleted assertion | Builders produced it unprompted | keep as a review lane |
| Bypass and deferral receipts | the full-suite bypass hatch and the cert-deferred receipt | A cert that could not run | unmeasured | **done:** deleted in PR 1589 |

### Definition of Ready

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| Title and acceptance word ranges; required metadata | Create API rejects | Unreadable slugs, vague criteria | Works | derive: defaults and warnings; repos and branch from the PR |
| Shape tiers via typed tags | A tier counts when a `[unit]` line exists | Under-tested PRs | 216 + 14 refusals; a tag is free text | derive from CI's executed-set receipts |
| `claimable_when` | docs and test-only only on an observed diff | A lighter contract by label | Works | derive: becomes the review-tier classifier |
| CI allow-list gate-zero | Green advances; red, pending, unread refuse | Merging on red or unknown CI | 763 pending, 479 red, 291 unverified reads | keep as the single verdict, read from ingested webhooks |
| Bare `db:seed` refusal | Rejects a full-suite seed as `post_deploy_cmd` | Demo data in production | One near-miss | keep |
| Gem version file refusal | A PR may not set a gem version | Colliding versions | Four PRs chose four versions | keep, inside release allocation |
| Duplicate migration collision | Refuses a second install of one engine migration | Release-phase crash | unmeasured | keep as a CI test |
| Same-file overlap | Advisory | Conflicts on `accepted` | advisory | keep, shown on the epic plan |
| `pr_url` record and read-back | Ship records and verifies the PR URL | A stale PR on the task | works | derive from the head branch |

### Review flow

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| Two-bounce breaker | Refuses a second send-back; escalates | Five-round ping-pong | 55 escalations; trips on the first send-back | derive: Avi arbitration, then the 20-minute window |
| Verdict-owner gate (exit 11) | Only the claim holder spends the bounce | A light spending the bounce | One incident | **done:** deleted in PR 1601; one owner by construction |
| Head revalidation, `--match-head-commit` | Merge only the reviewed head | Merging a moved head | works | keep |
| Stacked-PR refusal | Never retarget a PR based on another open PR | Dragging a parent's work | unmeasured | keep |
| Autopilot arm | Board merges when CI turns green | A reviewer waiting on CI | 74 transitions | promote to the default merge path |
| Resubmission verdict | fresh / unaddressed / addressed / unknown | Re-reviewing an unmoved tree | Caught a false resubmission | keep, derived from GitHub |
| Approval settle at reviewed | Unanswered approval settles to none | A fabricated approval | works | keep, with the 10-minute window |

### Release

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| Stale-tree, accepted-not-covered, multi-repo record, clean-ladder | Compare board stamps to git before promoting | ✓ over a tree missing a fix; half a multi-repo task shipped | Each fired in August | derive: `merged` = which rung contains the merge commit |
| Merge-forward guard | `main` contained in `release` before the gate | A hotfix dead-ending the ship | Fired 2026-08-09 | keep |
| Accepted-certification guard | A repo's suite workflow must build `accepted` | A green that could never fail | works | keep as a registry test |
| Parked repo hold | Tasks naming a dormant repo are held | Shipped for a repo that never moved | works | keep |
| Member evidence | Assembled only with QA evidence per repo | Assembled for a repo never deployed | works | keep |
| Gem guards | Version allocation, stranded work, changelog roll, lock drift, verified bump | Wrong irreversible publishes; consumers on an old engine | Nine commits once stranded | keep; fold the roll into one release commit |
| Ship preflight | Aborts on a dirty gem primary | Publishing uncommitted gem code | Once aborted after gems published | derive: build only from the ship workspace |
| Post-deploy exit status, boot smoke, seal | Exit code is the verdict; `/up` must answer | A half-ran backfill stamped green | G3 red 99 of 407, nearly all boot or abort | keep |
| Dispatch baseline refusal | Will not dispatch when the run list cannot be read | Watching someone else's run | Fired twice on 2026-09-22 | keep; read runs through ingested webhooks |

### Board hygiene, desks and infrastructure

| Guard | What it does | Prevented | Outcome so far | v3 |
|---|---|---|---|---|
| Archive holder guard | Refuses to archive a task whose desk may hold work | Losing finished work | Zero `--force` receipts | derive: "a desk exists" is the whole test |
| Open-PR guard and `orphan-prs` | Refuses to archive with an open PR | A PR nobody watches | One orphan surfaced a month late | keep, derived from GitHub |
| Comma, resume and unknown-flag refusals | Refuse `--repo a,b`, create flags on a resume | A phantom repo aborting a sweep | 1,117 tasks carried a joined tag | derive: normalize inputs; keep unknown-flag |
| Exit-code contract | 0 / 1 / 4 / 10 / 11 | A failed read read as "none" | works | keep with fewer codes |
| List truncation at 20 | Caps every listing silently | nothing; a defect | Hid a third of a column | delete: print totals |
| Desk reclaim safety | Age, bound until shipped, unoccupied | Destroying a live desk | One live desk destroyed | keep, simplified |
| Desk handoff and hub-move diagnosis | Re-exec from the desk's copy | `cannot load such file` mid-run | Four failures on 2026-09-10 | delete by installing the tooling at a fixed path |
| Scratch backup, Redis band, per-desk databases | Namespaced copies; isolated stacks | Truncated logs; shared test databases | works | keep |

## 8. Docs restructure

A session boots with about 30K tokens of instructions; a reviewer adds 25K. The
docs carry 2,025 date stamps and 150 "measured" citations, and one eight-line
credential block appears in twelve SOPs.

| Layer | Purpose | Size rule | Loaded when |
|---|---|---|---|
| 1 · AGENTS.md | The map: names, souls, the pipeline in one diagram, the six commands, repos and ports, the eight rules that are rules, where each capability page lives | about 200 lines | every session |
| 2 · capability pages | build, review, release, desks and infra, credentials, communication, learning: purpose, when, procedure, exit | at most 300 lines each | when the work touches it |
| 3 · reference and archive | Incident history, measured numbers, design rationale, moved verbatim under `docs/agents/archive/` | unbounded | never by default |

Rules: a procedure fits on one screen and links to its rationale; a fact a tool
enforces is not restated in prose; a "measured on" sentence goes to layer 3 the
day it is written. The docs-registry tests shrink to two: every SOP name
resolves, every link resolves.

## 9. The learning loop, baked in

Manual grading banked 13 insights against 416 discards; 132 triage findings are
open with none closed.

1. At `shipped`, Xan grades the task once from facts: forecast size against
   measured cost, bounces, gate failures, cycle time against the median, lines
   changed, tokens.
2. A learning is written only when a threshold trips: two or more bounces, cost
   or cycle time above p90, a gate that failed three times, or an escalation.
   Otherwise the grade records "nothing to learn".
3. One line, with the evidence linked, on the task and in the insight bank; the
   session-start feed already carries the top twelve.
4. Manual grading becomes optional; `grade-events` stops being a heartbeat act.

Two measurement fixes: every transition carries an actor (43% carry none today),
and cost is captured on every task (34% today, falling).

## 10. Implementation order

| Phase | Delivers | Mostly | Depends on |
|---|---|---|---|
| 0 | This document; the Xan rename with its data migration | docs, one migration | Alex's decisions (§11) |
| 1 | The focus-session SOP; the Pokémon builder soul; `arbitrate-block` and Avi's soul; the specialists' checklists; `epic_slug` and the epic chip | docs, small board change | 0 |
| 2 | One verdict per tree: `dor-check` reads the CI verdict only; G3 and G4 credit the tree; the evidence system and its guards deleted | tooling deletions | 1 |
| 3 | Operator windows: the fields, the wait command, the countdown, the launch mode | board and tooling | 1 |
| 4 | Derived state: `merged` from git, PR from branch, authors from git; the catalog's derive and delete rows in batches | tooling deletions | 2 |
| 5 | Docs restructure into three layers | docs | 1 to 4 |
| 6 | Auto-grade at ship; actor and cost on every event | board | 3 |
| 7 | The epic view on the board and in release notes | board | 1 |

**Run in parallel.** Three lanes, about seven working days; product work resumes
from day 4.

| Day | Lane A · docs | Lane B · board | Lane C · tooling |
|---|---|---|---|
| 1 | 0 · land this design | 0 · Xan rename | 2a · `dor-check` reads the CI verdict only |
| 2 | 1 · SOP, builder soul, `arbitrate-block`, checklists | 1 · `epic_slug` and the epic chip | 2b · G3 and G4 credit the tree; delete the evidence system |
| 3 | 1 · continued | 3 · operator windows | 4a · `merged` from git, PR from branch, authors from git |
| 4 to 5 | 5 · AGENTS.md map and capability pages | 6 · auto-grade, actor and cost | 4b · delete batches with their tests |
| 6 to 7 | 5 · archive move, registry tests trimmed | 7 · epic view and release notes | 4c · remaining derive rows; tooling at a fixed path |

Collision points: the card partial (epic chip and countdown) and `dor-check`
(2a and 4a), each serialized inside its lane.

**4a as built.** `Github::TaskDerivation` reads GitHub's API, never a checkout,
because the board runs on Heroku. `Task#merged_rung` names the highest of `main`,
`release` and `accepted` that contains the PR's merge commit. It falls back to the
`merged` stamp only when GitHub finds no merge, so `bin/task merged` overrides
only then; when GitHub places the commit, the derived rung wins. A compare cannot
see a revert, so a reverted merge still reads as merged; the rework path repoints
the task at a new PR. `Task#pr_url_or_derived` finds the PR headed by the task
branch, skipping any PR whose exact url the task lists as abandoned.
`Task#derived_authors` maps `<soul>@mcritchie.studio` commit emails and
Co-Authored-By trailers to souls. `ReviewerSelector` and the review-claim backstop
union those authors with the stamps. `bin/release`'s detection, resolve and
stranded-commit snippets, and the multi-repo record check, read the derived values.
Tasks share one derivation per process for a minute: each GitHub answer is cached,
and the first failed read stops the rest, so an outage costs one timeout per sweep.
Every stamp and guard stays until 4b.

**Where it stands, 2026-09-25.** Every piece below is merged to `accepted`; none
has reached `main`, because the v3 batch still waits on Alex's ship authority.

| Phase | Landed on `accepted` (PR) |
|---|---|
| 0 | design 1577 · Xan rename 1579 |
| 1 | focus-session SOP and souls 1578 · `epic_slug` and the chip 1580 |
| 2 | `dor-check` reads the CI verdict 1582 · evidence system deleted 1589 · G4 reads the tree verdict 1584 |
| 3 | operator windows 1586 · ship grant scoped to its request 1591 |
| 4 | derived `merged`, PR and authors 1592 · hardened reads 1594 · desk is the build claim 1596 · derivation 404s and list totals 1599 · verdict-owner gate, UNNAMED builders and migration lane deleted 1601 |
| 5 | AGENTS.md map 1593 · capability pages 1598 · long pages cut 1600 · docs guard tests trimmed to the live facts (trim-docs-guard-tests) |
| 6 | auto-grade at ship, actor and cost 1595 |
| 7 | epic view and release notes 1597 |

**Waits on a production ship (4c).** The derived readers must run live for one
release before the stamps they replace can go: remove `merged`, `built_by` and
`builders`, and `pr_url`, then install the fast-lane tooling at a fixed path
outside any checkout. 4c starts after the v3 batch reaches `main`.

## 11. Decisions recorded on 2026-09-24

1. **Xan** is the agent's name; Alex is the human.
2. **Production window:** per-launch mode, `timed` by default; changeable in
   `config/release_builder.yml`.
3. **The Pokémon builds everything;** specialists review; the builder may contest
   a block; Avi arbitrates.
4. **Review tiers** as in §4.
5. **Epic on the board:** `epic_slug` on the task and an epic chip on the card.
6. **The guard catalog** stands as proposed.
7. **Schedule:** three parallel lanes, about seven working days.

## Appendix: the measurements

From the production board and the hub's git history on 2026-09-24. Re-derive
before quoting later.

| Measure | Value |
|---|---|
| Tasks created since 2026-W25 / shipped / archived unshipped | 2,275 / 1,997 / 274 |
| Releases, all shipped; median members | 413 · 4 |
| Build, building to submitted (p50 / p90) | 23 min / 2.7 h |
| Wait for a reviewer, September (p50 / p90) | 9 min / 135 min |
| Submitted to reviewed (p50 / p90) | 32 min / 4.4 h |
| Wait for a sweep, Jun · Jul · Aug · Sep (p50) | 2 · 24 · 42 · 69 min |
| Reviewed to assembled (p50 / p90) | 1.1 h / 7.2 h |
| Assembled to shipped (p50 / p90) | 18 min / 1.9 h |
| Submitted to shipped (p50 / p90) | 3.0 h / 11.1 h |
| Release, assembling start to shipped (p50) | 35 min |
| Daily WIP median / max; days at or under 4 | 10 / 35 · 32 of 94 |
| Tasks filed in bursts | 1,369 (60%) |
| Shipped tasks bounced at least once | 25% |
| Scout reports; request-changes share Jul → Sep | 3,439 · 35% → 17% |
| Paired rounds where the light alone blocked | 101 of 1,151 (9%) |
| DoR failures builder / review; top cause stale evidence | 858 / 462 · 439 + 337 |
| G1 red / G3 red / G4 red | 319 of 3,314 · 99 of 407 · 18 of 301 |
| CI wall / job-minutes, hub · turf | 6.8 min / 30 · 9.4 min / 23 |
| Recorded cost; per shipped task p50 / p90 | $67.7K · $50 / $212 |
| Spend by half: deploy / build | 48% / 29% |
| Cache-read vs input tokens | 288B vs 28.7B |
| Hub PRs since Aug 13 that were the DevOps system | 67% of 577 |
| Tooling lines · tooling test lines · docs lines | 71K · 101K · 53K |
| Refusal lines in tooling · in docs | 1,621 · 802 |
| UI approvals requested / approved / dropped; wait p50 | 274 / 100 / 46 · 16 min |
| Escalations; next move p50 / p90 | 55 · 48 min / 6.6 h |
| Learning grades good / not; open findings | 13 / 416 · 132 |

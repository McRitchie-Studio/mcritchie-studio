# QA Release

## Status: Active

This is Avi's `qa-release` SOP: the self-healing release prepare sweep. It detects
reviewed work and release stragglers, promotes `accepted → release` per repo (a
fast-forward when `release` is contained in `accepted`, the batch PR only when it has
diverged), allocates each gem member's version, publishes a **release candidate** of it
(`x.y.z.rcN`) and locks consumers to that candidate (producer-first, before anything
tests or deploys), runs the pre-QA gate, deploys QA, and flips members to `assembled`
only on QA-green. The final `x.y.z` is published by `production-deploy`, after QA.
History and rationale cut from this page live in
[`../../../archive/qa-release-2026-09-25.md`](../../../archive/qa-release-2026-09-25.md).

## Scope

Avi owns stages 1-3 (Testing, Assembling, Deploying QA) as the **assembler**
(`ReleaseConductorClaim` role `assembler`) and stops at the Avi → Steffon handoff: live
on QA, ready for Steffon's `production-deploy`. It does not ship production.

## Entry

Run from the McRitchie Studio primary checkout (`cd /Users/alex/projects/mcritchie-studio`),
on the production board (do not add `--local`). The sweep runs under the **default
agent GitHub App identity** (`github.mcritchie-agent`); it opens and merges the batch
promote PRs, which the ship identity (`github.mcritchie-admin`) cannot. Git pushes ride the global credential
helper (`bin/gh-app-git-credential`); the sweep's `gh` calls need a minted token, so
before the sweep export:

```bash
export GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | \
  /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential get | \
  sed -n 's/^password=//p')
```

**Do not export `GH_APP_ITEM` here**: a leftover ship-lane export
(`github.mcritchie-admin`) mints the **ship App**, which has **no `pull_requests` grant**. On `Resource not accessible by
integration`: `unset GH_APP_ITEM`, re-run the export, re-run `bin/release prepare`.

A mid-sweep **401 `Bad credentials`** (the 1-hour token expired) or **403 `not
accessible by personal access token`** (`GH_TOKEN` empty): re-mint with `eval
"$(bin/gh-auth-refresh --export)"` and read its stderr (eval hides the exit code).
Self-service; never `gh auth login`, never print the token
([`source-control.md`](../../../modules/source-control.md)).

## Assembler claim — automatic, on the RELEASE record

**`bin/release prepare` takes the lock for you**: the per-release `assembler` claim,
BEFORE the irreversible promote, renewed for the sweep's life, released on completion.

- **Stand down** — `🛑 <release> assembler already held — STAND DOWN` names the holder
  and **aborts before anything merges or deploys**. Announce the holder and STOP; its
  lease lapses ~120s after that session dies, and a re-run then resumes.
- **Resume** — re-running YOUR OWN interrupted prepare re-acquires the same claim.
- **Fail-open** — a claim-transport hiccup never wedges the sweep; it proceeds unclaimed.

It also publishes a **local** presence claim (`.agents/sessions/<key>.presence-sweep-<pid>`,
weight `light`/`suite`/`idle` from `config/devops_test_suites.yml`) for peers'
`bin/agent-presence`; nothing to run by hand. Disarm with `RELEASE_PRESENCE=off`.

## Preconditions

`reviewed` tasks waiting, `assembled` stragglers, or an interrupted candidate in
flight. Otherwise report "nothing to prepare" and stop.

## Disposition — which applications ride this candidate (Avi curates)

**Ship ALL reviewed work by default.** When order matters (a gem before its consumer,
a risky app waiting a cycle), curate by APPLICATION:

- **Make the decision board-visible first.** Mark the held app's reviewed tasks
  `included_in_release: false` (`PATCH /api/v1/tasks/<slug>` with `{ "devops": {
  "included_in_release": false } }`). Their card shows amber **HELD FROM RELEASE ·
  <app>** instead of green **IN RELEASE**.
- **Then sweep only the included apps:** `bin/release prepare --task <slug> [--task
  <slug> …] --yes` (lands ALL of `accepted` for their repos). The held repo reads
  AHEAD; the accepted-coverage guard (step 4a-bis) is scoped to repos this release's
  members name, so it allows the hold-back.
- **Eject a member after the candidate formed** with `bin/release eject <task>
  --feedback "<reason>"`, then re-run `bin/release prepare --yes`.

Keep the flag (the record) and the `--task`/`eject` controls in sync.

## Procedure

**Direct-drive this act — do NOT delegate it to a subagent.** A MUTATING op
(`qa-release`, `production-deploy`, `archive-shipped`) runs in the conductor session;
subagents are for **read** fan-out. Narrate with `bin/agent-activity start/next/end`.

```bash
bin/release prepare --yes
```

`prepare` owns the whole act:

1. Detect every `reviewed` task plus any `assembled` straggler. A task naming a
   **parked** repo (any `config/release_repos.yml` ladder but `three-rung`) is HELD:
   `⚠ HELD <slug>: names parked <repo> (ladder: <ladder>) — <why>; left <stage>,
   never promoted or deployed.` A task naming a live AND a parked repo is held WHOLE.
2. Open or resume the release candidate.
3. **Promote `accepted → release`**: per repo with reviewed work, ONE promote.
   - **Fast-forward** when `release` is contained in `accepted`: the `accepted` head is
     pushed to `release` by ref, with no force flag, and read back. No PR, no merge
     commit, so `release` carries the very SHA whose CI `accepted` already ran.
   - **Batch PR** only when `release` has diverged (it carries a commit `accepted`
     lacks, such as a hotfix on `release` or `main` not yet merged forward); the output
     says so. Open (or reuse) ONE `--base release --head accepted` PR and merge it,
     then `accepted` is carried onto the merge commit by a fast-forward, so the next
     promote fast-forwards. If `accepted` moved meanwhile it is left alone, with a `⚠`
     line, and the next promote takes the batch PR again.

   Idempotent: `accepted` level with `release` skips the promote but still records +
   deploys. Membership is recorded
   (re-stamping `merged: "release"`), skipping work stamped `merged: release`/`main`. A
   `reviewed` member with `merged: ""` is a HELD anomaly, warned and left `reviewed`.
3b. **VERIFY the promote reached the candidate** (the stale-tree gate): per three-rung
   repo it re-reads `origin/release..origin/accepted` and REFUSES unless `release`
   carries `accepted`, catching a commit **no task stamped** (a zap, a hand-merge, a
   **LOST STAMP**). An unreadable rung counts as stale. See the **STALE TREE** rows.
4c. **Merge `main` forward into `release`** in every app **and gem repo** (before the
   gate and the gem publish), so a hotfix on `main` cannot block the ship. A conflict,
   failed push, or unmet containment **aborts**: resolve on a branch off
   `origin/release`, merge `origin/main` into it, push to `release`, re-run `bin/release
   prepare`. **Do not `reset` `release` to "clean up" an aborted sweep.** A landed
   merge-forward is carried onto `accepted` the same way as the batch PR's merge commit.
4d. **Allocate gem versions, publish a release candidate of each gem member, lock
   consumers to it — BEFORE the gate and QA** (producer-first).

   **`prepare` never pushes a final gem version.** A RubyGems version can never be
   re-pushed, so prepare publishes the prerelease `x.y.z.rcN` and
   `bin/release ship` publishes `x.y.z` from the same tree once QA is green and
   production is granted. A red QA strands only a candidate: the allocated `x.y.z`
   stays free, and the next sweep publishes the next candidate of it.

   **Each candidate is gated on GitHub's CLEAN-ENV verdict for the exact tip it is
   built from**, and fails closed. The gem's own `bin/release-check --build` runs first
   and aborts first when red. Pending and not-yet-started both WAIT; a terminal
   non-green or a poll timeout aborts with **nothing published**: fix or re-run the
   named run, then re-run `prepare`.

   **Phase 0 ALLOCATES the version, so you never type one.** Per swept gem it derives
   the bump from membership (`breaking` risk tag → major, else a `feature` member →
   minor, else patch; a member's `gem_bump` overrides), advances the **last published**
   version (the higher of the last `v*` tag and RubyGems; a candidate is not a
   published version), and commits the
   `version_file` **with its `Gemfile.lock` and rolled `CHANGELOG.md`** onto
   `origin/accepted`; the ordinary promote carries it to `release`. Phase 0 decides for
   EVERY gem before writing to ANY.

   **The changelog roll.** A swept gem is a `gems:` entry a member touches
   (studio-engine and solana-studio; turf-vault is under `apps`, never versioned). Each
   gets one of `Release::GemVersion.allocation`'s three outcomes:

   - **ALLOCATE** — version written and bucket rolled, in one commit.
     `Release::Changelog.roll` writes `## <version> — <date>` in the file's own heading
     form directly under `## Unreleased` and moves the entries beneath it; an empty
     bucket still gets its heading (`no entries — the heading records the release`). A
     gem with no `CHANGELOG.md` prints `nothing to roll`.
   - **SKIP** — nothing allocated, nothing rolled. Prepare prints `gem <repo>: <reason>
     — nothing allocated`, for one of three reasons:
     `no commits past the last published tag — nothing to publish`;
     `no published version yet (no v* tag, nothing on RubyGems) — first publish`;
     `<current> already advanced past <reference> — allocated already` (the
     `version_file` on `origin/accepted` against the last `v*` tag on `origin/release`).
     The last is reached by (1) a version set by hand — the STRANDED GEM WORK row —
     which rolls NOTHING, so roll the changelog by hand in that same commit; (2) any
     re-run of `prepare` before the ship has published the final and pushed its `v*`
     tag, a QA bounce included; (3) a later sweep absorbing more work into a version
     that has not shipped.
   - **REFUSE** — the decide phase stops the sweep before phase 0 writes; nothing is
     published. See the GEM VERSION ALLOCATION REFUSED row (including a version live on
     RubyGems whose `v*` tag never reached origin; the failing sweep prints `⚠ tag
     v<version> did NOT reach origin — push it now: …`) and the CHANGELOG BACKLOG row.

   A write-phase failure is not a REFUSE: an earlier gem's version commit may already
   sit on `origin/accepted`. **Leave it THERE** — the re-run SKIPs it as allocated
   already. Moving it onto `release` alone creates the MIXED state, where the next run
   prints `no commits past the last published tag — nothing to publish` and skips
   silently.

   **Check the roll** in each swept gem repo once phase 0 has run:

   ```bash
   git -C /Users/alex/projects/<gem-repo> fetch origin --quiet
   git -C /Users/alex/projects/<gem-repo> show origin/accepted:CHANGELOG.md | grep -m 2 '^## '
   ```

   Line one reads `## Unreleased`; line two names the version prepare printed. Else,
   after an ALLOCATE report a `bin/release` defect; after a SKIP, land a docs PR on the
   gem's `accepted` adding the hand-set version's heading (any other heading is AHEAD).

   **A candidate is published only when the ship that follows can finalize it.** A
   ship from tooling without the candidate flow publishes the final and deploys
   consumers still locked to the candidate. Two places on this machine start a ship:
   the fixed-path install (`/Users/alex/projects/.agents/bin/release.rb`) and the
   hub primary (its working tree and its `origin/main`). Phase 1 reads all three
   for the flow line (`GEM_CANDIDATE_FLOW` in `bin/release.rb`) and refuses, with
   nothing published, unless each carries this sweep's flow; one it cannot read
   counts as lacking it. After the candidates publish and before any consumer is
   bumped, prepare stamps the release (`metadata.gem_candidates`: the flow and each
   gem's candidate), and a ship with the flow refuses a candidate that stamp does not
   name. A stamp cannot stop tooling that never reads it: the entry-point read is
   what keeps an older ship from following a candidate. A sweep that publishes no
   candidate (every final already live) does not ask.

   Phase 1 **preflights EVERY swept gem before the first push**: a fail-closed fetch of
   `origin/release`, the `version_file` parse, the **stranded-work guard** (`release`
   ahead of the last `v*` tag while the version did NOT advance; equal, backward and
   unparseable all block — see STRANDED GEM WORK), and a consumer-coverage check
   **unless the gem is self-gated** (a `release_check` in `config/release_repos.yml`;
   such a gem may ship gem-only). ANY failure aborts with **zero gems published**.

   Phase 2 publishes each gem's candidate, built from `origin/release` in the gem's
   ship workspace with the version literal written to `x.y.z.rcN` for the build only
   (the tree keeps `x.y.z`), then tags it `rc-x.y.z.rcN` at that tip. **Which
   candidate:** a live candidate tagged at the current tip is reused; any other tip
   gets the next free number; when `x.y.z` itself is already live, consumers lock it
   and no candidate is published.

   Then it commits each consumer's bump onto the consumer's `origin/accepted` FIRST
   and fast-forwards `origin/release` to the same commit, so `release` never carries a
   commit `accepted` lacks. **The bump is normally `Gemfile.lock` alone.** Bundler
   resolves a prerelease only when a requirement names one, and then keeps it in the
   lock for as long as the Gemfile admits it. So prepare writes the exact candidate
   onto the gem's line (`gem "studio-engine", "~> 0.95", "0.96.0.rc1"`), runs `bundle
   lock --update <gem> --conservative`, takes the requirement off again, runs a plain
   `bundle lock`, and reads the lock back: the committed `Gemfile` is unchanged and a
   frozen install of the tree loads the candidate. **The line itself changes only
   when the final would escape the pin, or the line is a branch or path source**: the
   final's pin (`"~> 1.0"`) excludes its own candidate, because a prerelease orders
   below its final, so the committed line carries the candidate as its floor
   (`">= 1.0.0.rc1", "< 2"`) and the ship rewrites it to `"~> 1.0"`. Only when the two
   branches do not share a commit (a diverged `release`, or `accepted` moved mid-sweep)
   does the bump land on `release` alone, with a `⚠` line; the next promote's batch PR
   carries it back. The bump is **verified by reading the lock back** and retried on a
   3-attempt backoff (see CONSUMER LOCK BUMP). The same commit carries any new **engine
   migrations** (`<engine>:install:migrations` plus `db:migrate` against a throwaway
   database so `db/schema.rb` lands); a failed probe, an unexpected schema rewrite, or an
   underivable throwaway database ABORTS. The gate and QA then read the post-bump SHA.
   A gem repo's own lock (studio-engine locks solana-studio) is not touched here: the
   ship bumps it, to the final.

   **The order, and what a re-run does at each stop:**

   | The sweep stops | The world | A re-run |
   |---|---|---|
   | after the version commit, before any publish | `x.y.z` on the gem's `accepted` (and `release` once promoted); nothing on RubyGems | SKIPs the allocation as `allocated already`, publishes `rc1` |
   | after a candidate's push, before its tag | `rcN` live, untagged | publishes `rcN+1`; the untagged one is never locked |
   | after the tag, before the consumer bump (PUBLISHED GEM NOT READY lands here) | `rcN` live and tagged; consumers on the previous version | reuses `rcN`, bumps |
   | after some consumers bumped | those consumers' `accepted` and `release` lock `rcN` | reuses `rcN`; a bumped lock commits nothing, the rest bump |
   | at a red gate, or QA not green | consumers lock `rcN`; members `reviewed`; `x.y.z` unpublished | after the fix: a moved gem tip publishes `rcN+1` and re-bumps; an unmoved one reuses `rcN`. `x.y.z` is the same either way |
   | with the gem's task ejected | a consumer still locks `rcN` of a gem the release no longer carries | REFUSES (the STRAY CANDIDATE row) until the lock is restored |
   | (after the ship) with a consumer's `accepted` having moved during QA | the ship's advance of `accepted` is refused as a non-fast-forward, so that `accepted` still locks `rcN` while `release` and `main` lock `x.y.z` | nothing is wrong on production. The next sweep's promote merges it (only `release` changed the lock, so the final wins) and its merge-forward keeps `main` in `release`. To clear it sooner, run the DIVERGED reconcile recipe in `production-deploy.md` |

   A candidate QA bounced is never locked again once the gem's tip moves, and nothing
   here can publish `x.y.z`.

   **What a locked candidate changes for a consumer, and the guards that read it.**
   - The gem reports its version as `x.y.z.rcN` (`Studio::VERSION`, the gemspec),
     which orders below `x.y.z`. A consumer test asserting a floor of exactly `x.y.z`
     on the RESOLVED gem is red on the candidate tree: raise such a floor in the
     release after the gem's.
   - `Gemfile.lock` names a prerelease. A test that parses the locked version must
     accept `x.y.z.rcN` (moms-app's `engine_bump_guard_test.rb` does).
   - The `Gemfile` line changes only for a candidate floor. A test that reads the
     pin as a floor must read the base version of `>= x.y.z.rcN` (turf-monster's
     `engine_pin_contract_test.rb` and `workflow_citation_docs_test.rb` do).
   - studio-engine's `bin/gem-drift-check` compares the engine's solana-studio lock
     with each consumer's. It ignores a consumer on a candidate of a version the
     engine does not have yet; the ship bumps the engine's lock to the final.
5. Run the pre-QA gate on `origin/release`. **GitHub CI's conclusion for that exact SHA
   IS the verdict**; nothing runs locally. It polls a pending run, passes only on green,
   and fails closed on everything else. It may **credit** an existing green for the same
   commit: after a fast-forward promote `origin/release` IS the accepted head, so its
   verdict carries over by SHA. After a batch PR it may credit the accepted head's
   **identical tree** instead (named in the gate note). It records
   SHA + command + verdict as a `pre_qa_gate` SOP; G4 re-reads the frozen SHA itself. A
   self-gated gem in a gem-only release earns the same identical-tree credit. A red gate,
   and why you must **not** blank the registry's `qa_test_cmd`:
   [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md).

   **How long a sweep can hold.** Each repo's pending wait is sized from its own
   push and pull_request workflows, up to about 105 minutes for studio-engine. Repos
   gate **one after another**, not in parallel, and the gem gate runs before the app
   gates, so one sweep's worst case is the SUM of its repos' waits. That can exceed the
   2-hour cap on a background command. Run `prepare` where it may outlive that cap
   (Alex's terminal), or watch for a cut-off and re-run: a re-run reads the greens
   that landed meanwhile on its first poll. `RELEASE_CI_POLL_TIMEOUT` is now a **floor**: raising it
   lengthens the wait, and lowering it never shortens a workflow-sized one. A wait past
   one hour re-mints the GitHub App read token (the sweep prints `re-minted the GitHub
   App read token`), so a long hold no longer ends in a credentials abort.
6. Deploy QA and wait for boot. Gem members are QA'd as their candidate, through the consumer's bumped lock;
   a **gem-only release has no app QA deploy** and assembles on its G3 CI verdict
   (/deployments shows a **GEM-ONLY** badge and `💎 <gem> <version>`).
7. Flip members from `reviewed` to `assembled` only after QA is green.

`prepare` stamps the stage timeline and records the **G3 Candidate** attempt (a re-run
opens attempt n+1, shown `×n`); post nothing by hand. Smoke QA after success:

```bash
curl -fsS https://qa.mcritchie.studio/up
```

Backfill a stage boundary an interruption left unrecorded with `POST
/api/v1/releases/current/events/qa_deploying/complete` (first-write-wins;
`docs/agents/modules/task-board-api.md`). Eject a pre-QA gate offender:

```bash
bin/release eject <task> --feedback "<specific failing evidence>"
```

Then re-run `bin/release prepare --yes` so the rest of the candidate can ride.

## Recovery — an INTERRUPTION and an ABORT need OPPOSITE responses

**Diagnose which one you have BEFORE you re-run.** A re-run re-tests **the same member
code**, so re-running a red candidate goes red forever.

- **INTERRUPTION** — no verdict (a detached agent, killed terminal, crash). **Re-run it.**
- **ABORT** — a refusal with a verdict. **Fix the cause first, THEN re-run.**
- **NOT GREEN** — a verdict, then **exit 3**: QA did not come up, members stay
  `reviewed`. **Fix the cause first, THEN re-run.**

The exit status is the verdict (`app/models/release/cli.rb`):

| Exit | Meaning | Response |
|---|---|---|
| **0** | `✓ Assembled <rel>`, or an early return with nothing to sweep | proceed to `production-deploy` |
| **1** | **ABORT**: a refusal with a verdict (also `--help`, `Release::Cli::HELP_EXIT`) | read the abort; take its row below |
| **2** | **ARGUMENT REFUSAL**: a flag `prepare` does not accept; nothing ran | fix the command line, then re-run |
| **3** | **NOT GREEN**: `✓ Prepared (NOT assembled — QA not green)` (`PREPARE_QA_NOT_GREEN_EXIT`) | fix the boot, then re-run (the **QA deploy / boot FAILED** row) |

`bin/conductor qa --run` exits with `prepare`'s status unchanged, so a wrapper reads
the same verdict from either command.

### INTERRUPTION — re-run `bin/release prepare --yes`. That is the whole fix.

Do not hand-merge or hand-flip stages; a re-run skips promoted work and resumes the same
candidate. It REFUSES only on a stale tree (step 3b): take the **STALE TREE** row.

### ABORT — fix the cause, THEN re-run

An abort leaves the same board state as an interruption. Each abort names its case:

| Abort | Fix FIRST | Then |
|---|---|---|
| **A GEM'S `version_file` MOVED AND THE SWEEP ABORTS EITHER WAY** ("does not declare EXACTLY ONE version literal" at the phase-0b write, OR "promote refused — <repo> (suite workflow …) cannot certify `accepted`") | `bin/release.rb` reads the registry from the CONDUCTOR'S checkout, so registry and gem tree must move TOGETHER. OLD registry + NEW tree fails in `commit_gem_version!` naming the gemspec — **do not follow that abort's set-it-by-hand remedy**. NEW registry + OLD tree fails in `refuse_blind_accepted!` and reads like the CANNOT CERTIFY row — **do not edit `on.push.branches`**. Land the gem-side move and the `config/release_repos.yml` change in the SAME release, gem repo first, and drive the sweep from a checkout carrying the new registry. `bin/dor-check` also reads its own checkout's registry: run it from the hub worktree holding the change | land both, then re-run `prepare`; nothing was published |
| **CHANGELOG BACKLOG / UNREADABLE CHANGELOG** (step 4d phase 0 — "CHANGELOG.md carries a BACKLOG", "…parse as neither a version nor the Unreleased bucket", "…is AHEAD of the last published version", "has an unterminated fenced code block") | Nothing was written or published. BACKLOG: in a docs PR on the gem's `accepted`, attribute the entries to the versions that shipped them (studio-engine `docs/RELEASE.md`). UNREADABLE: fix the named heading to the file's dialect. Unterminated fence: close it. AHEAD: move that heading's entries back under `## Unreleased` and delete the heading. Other variants name their own fix. **Do not delete the entries to get past this** | re-run `prepare`; it resumes |
| **GEM VERSION ALLOCATION REFUSED** (step 4d phase 0 — "REFUSING to allocate a version") | **Do not set a version by hand.** Unreadable override → `bin/task update <task> --gem-bump patch\|minor\|major` (or clear it); unparseable last version → fix the `v*` tag or `version_file`; a doubled version → declare one; failed or stale `bundle lock` → fix the bundle (stale is usually propagation: wait); `<version> is already live on RubyGems, but the last v* tag…` (a ship published the final and its tag never reached origin) → `git -C /Users/alex/projects/<gem-repo> push origin v<version>`, or tag the `Release <version>` commit on `origin/release`. An earlier gem's version commit on `accepted` stays THERE | re-run `prepare`; allocation resumes |
| **STRANDED GEM WORK** (gem `origin/release` ahead of its last `v*` tag, version not advanced — unbumped, BACKWARD, or unparseable) | Check phase 0's output first; if it refused, fix that row. To set it yourself: `next = <tag> + bump` (major if any member is `breaking`, else minor on a `feature`, else patch; `gem_bump` overrides). Commit straight onto the gem's `accepted` — not a PR, which `bin/dor-check` refuses:<br>`cd /Users/alex/projects/<gem-repo> && git checkout accepted && git pull`<br>edit the `version_file` (read the registry: `lib/studio/version.rb`, `lib/solana_studio/version.rb`)<br>roll `CHANGELOG.md` in the same commit: `## <next> — <date>` under `## Unreleased`, entries beneath it<br>`bundle lock` **← REQUIRED when the repo tracks a `Gemfile.lock`**<br>`git commit -am "Release <next>" && git push origin accepted`<br>A `DOWNGRADE` means a merge resolved the version backward: fix it forward | re-run `prepare`; nothing was published or deployed |
| **Pre-QA gate red — a member REGRESSION** | `bin/release eject <task> --feedback "<failing evidence>"`, then revert its merge commit on `release` (the abort prints the guidance) | re-run `prepare`; the rest of the RC rides |
| **Pre-QA gate red — ENV/toolchain** (unsatisfied bundle, Postgres down, Ruby divergence) | **Nothing to eject or revert.** Fix the environment exactly as the abort names it | re-run `prepare` |
| **QA DEPLOY NEVER DISPATCHED** (step 6 — "`<workflow>` was dispatched but GitHub registered NO run for it — the deploy NEVER RAN") | **Do not touch the app.** Run the dispatch command the abort prints and confirm a run registers (`gh run list --workflow <workflow> --limit 3`). Do NOT reach for `bin/qa-server deploy` or lengthen the boot poll. The promote and the candidate publish have ALREADY happened: this is NOT a clean slate | re-run `prepare` once a manual dispatch registers a run |
| **QA DEPLOY DISPATCHED, RUN LIST UNREADABLE** (step 6 — "the run list could NOT be read afterwards — whether a run was created is UNKNOWN") | **Do NOT re-dispatch** — a second deploy can land on a live one. Fix the reader (`gh auth status`; `eval "$(bin/gh-auth-refresh --export)"`), then `gh run list --workflow <workflow> --limit 5`. If a run for that SHA is listed, `gh run watch <id> --exit-status`; only a readable list with no run makes a hand-dispatch safe | once the deploy's real state is KNOWN: re-run `prepare` (it resumes over the promoted/published work) |
| **QA DEPLOY NOT DISPATCHED — NO BASELINE** (step 6 — "`gh run list` never answered/FAILED, so there is no baseline … NOT dispatching. NOTHING WAS DEPLOYED") | **The refusal is CORRECT.** Read the quoted `gh said:` line and its `→` remedy; a `HTTP 401: Bad credentials` means the sweep outlived its ~1h token: re-mint. The promote and any candidate publish have ALREADY happened | fix what gh named, then re-run `prepare`; it resumes over the merged/published work |
| **QA deploy / boot FAILED** ("never returned /up 200") | **FIRST scroll up for `⚠ <workflow>: … NOTHING WAS DEPLOYED; this is not a boot failure`** — then the app was never deployed and the rows above apply. Otherwise fix the boot failure (the summary prints the `bin/qa-server deploy …` retry); eject the member if it is the cause | re-run `prepare` **once QA boots** |
| **STALE TREE** (step 3b — "prepare refused: … would deploy a tree that does NOT contain `accepted`") | **The good outcome — the sweep caught itself.** READ THE REFUSAL FIRST. **LOST STAMP** naming a task → run the two commands it prints (`bin/task merged <slug> accepted`, plus `bin/task move <slug> reviewed` unless already there). A commit no task owns → `gh pr create --repo <owner/name> --base release --head accepted …`, **watch that PR's CI to green**, then `gh pr merge <pr-url> --merge --match-head-commit <the accepted head the abort names>` (the abort prints a short SHA; gh needs the full one from `git rev-parse origin/accepted`). Never push or reset `release`; there is deliberately no flag | re-run `prepare`; it promotes nothing new, re-gates, and re-deploys QA over the tree that now carries the work |
| **STALE TREE — rung could NOT be read** (step 3b — "a failed read is not a clean read") | Clone the repo as a sibling, or `git fetch origin` in it, so `origin/release..origin/accepted` can be read | re-run `prepare` |
| **`accepted → release` promote failed** (a conflict on the batch PR) | Resolve the conflict on the batch PR (or `bin/task block` the offending member) | re-run `prepare` |
| **Fast-forward refused** ("could not fast-forward origin/release … did release move?") | Someone pushed `release` between the containment read and the push. Never force it | re-run `prepare`; it re-reads containment and takes the fast-forward or the batch PR |
| **CHANGELOG MISFILE GUARD REFUSED THE PROMOTE** (step 3; the refusal is `bin/release.rb#refuse_misfiled_changelog!` and names each gem) | Nothing was promoted in ANY repo. Follow the remedy the refusal prints (`app/models/release/changelog.rb#MISFILE_REMEDY`): the fix lands straight onto the gem's `accepted`, **not a PR**, which `bin/dor-check` refuses. Fail-closed variants name their own fix. A commit landing on `accepted` meanwhile fails the pinned merge: re-run | re-run `prepare`; it resumes |
| **Member left `reviewed` with `merged: ""`** (review never landed its feat PR on `accepted`) | Re-review the task so `pr-review` merges it onto `accepted` | re-run `prepare` |
| **`⚠ HELD <slug>: names parked <repo> (ladder: <ladder>) — <why>; left <stage>, never promoted or deployed.`** (step 1 — not an abort; `bin/release merge <slug>` refuses the same task) | **Do not force it through.** If the repo carries no work, drop it (`bin/task update <slug> --repo …`, which REPLACES the list); if the repo is being revived, set `ladder: three-rung` on its registry row in a task of its own. A parked repo in the deploy plan is refused at step 3b, same fix | re-run `prepare`; the task sweeps once no repo it names is parked |
| **MULTI-REPO PR RECORD INCOMPLETE** (step 3a — "multi-repo task(s) with an incomplete PR record") | Record the missing PR — `bin/task update <slug> --pr-url-for <repo>=<pr-url>` — or drop the repo with no work (`bin/task update <slug> --repo …`). Nothing was promoted | re-run `prepare`; the member sweeps with every repo it names |
| **ACCEPTED NOT COVERED BY THE PROMOTE** (step 4a-bis — "`accepted` carries commits for X, a repo this release's members NAME, but this sweep would promote only Y") | Usually a PARTIAL earlier promote. Land it (`bin/release merge <slug>`, fanning out over every repo the task names) or drop X from the task; `bin/release status` shows git and board side by side. A repo NO member names is out of scope. When a gem repo's only ahead commit is the last ship's producer lock bump, `bin/release merge` skips it (`merged: release`); a hand `--base release --head accepted` PR lands it, prepare reuses an open one, and the release that carries it allocates ANOTHER gem version: say so before promoting | re-run `prepare` once every member-named ahead repo rides |
| **A REPO CANNOT CERTIFY `accepted`** (inside the promote — "promote refused — <repo> (suite workflow "CI") cannot certify `accepted`") | Add `accepted` to that repo's suite workflow `on.push.branches` (reference: `mcritchie-studio/.github/workflows/ci.yml`, deliberately no `concurrency:` block) and land it on the repo's `accepted`. Do **not** drop the repo from the sweep. Exempt only by declaration (`Release::AcceptedCertification::GEM_SUITE_WORKFLOWS` nil; none today) | re-run `prepare`; it resumes |
| **PUBLISHED GEM NOT READY** (step 4d — "the RubyGems CDN is still not serving it" or "`gem install <gem> -v <version>` still fails on this machine") | **Nothing was bumped.** After each candidate publish, and for an already-live candidate or final on a re-run, prepare waits up to `RELEASE_GEM_POLL_TIMEOUT` (300s of wall time, each index read capped by `RELEASE_GEM_CURL_MAX_TIME`) for the compact index line and the `.gem` file, then installs the version into the shell ruby and mise's pinned ruby. A CDN timeout is propagation: wait. An install failure prints the installer's own output: run the two `gem install` commands the refusal prints | re-run `prepare`; the candidate is reused and the wait starts a fresh budget |
| **CANDIDATE NOT BUILT OR NOT PUSHED** (step 4d — "does not declare exactly `<version>` — refusing to build candidate", "the candidate build carries version …", "gem push failed for `<repo>` candidate") | Nothing was bumped and no final version exists. The first two mean the gem's `version_file` at the release tip is not the allocated version: read phase 0's output and the STRANDED GEM WORK row. A failed push is `gem signin` or RubyGems itself | re-run `prepare`; it publishes the next free candidate number |
| **STRAY CANDIDATE** (step 4d — "a consumer is locked to a release candidate this sweep is not testing") | A consumer's `release` locks `x.y.z.rcN` of a gem this release does not carry (its task was ejected, or an earlier candidate never shipped). Bundler keeps such a lock, so it would deploy. Put the gem's task back on the release, or land a consumer task on `accepted` that runs `bundle lock --update <gem> --conservative` back to the last released version (and, where the `Gemfile` line carries a candidate floor, restores its pin first) | re-run `prepare` |
| **CANDIDATE FLOW NOT ON EVERY SHIP ENTRY POINT** (step 4d — "does not carry the candidate flow", "carries candidate flow N, not M" or "could not be read … a ship started there would publish the final and deploy consumers still locked to the candidate") | **Nothing was published.** The abort names each entry point and its fix. The fixed-path install: run `bin/install-agent-docs` from a hub primary on `main`. The hub primary's working tree: `git checkout main && git pull --ff-only` there (never stash or discard a live session's work to do it: rescue it to a branch). The hub primary's `origin/main`: the release that carries the flow has not shipped yet, so this sweep cannot publish a candidate from this tooling | re-run `prepare` once every entry point carries the flow |
| **CONSUMER LOCK BUMP did not land** (`bundle lock … did not land in <repo> … resolves <old>, wanted <new>`) | **WAIT — nothing to fix.** Watch the compact index bundler reads: `curl -sS https://index.rubygems.org/info/<gem> \| tail -5`, not the API or HTML page. Do **not** bump the version. If sibling consumers already resolved the candidate, it is not propagation but a dependency cap in that consumer: land a consumer task running `bundle lock --update <gem> <capped-dep> --conservative` | re-run `prepare`; the candidate is reused and the bump lands |
| **`record op returned no JSON`** (prepare's record step) | The record step runs `Release::Conductor` on PRODUCTION via `heroku run`, against production's deployed `config/release_repos.yml` and guards. A repo registered in this same release is unknown there. Ship the hub registry change first: hold the new repo's tasks (`included_in_release: false`) and sweep the hub tasks with `--task`. A conductor guard fix likewise takes effect only once it is live on `main` | re-run `prepare` for the new repo in the next cycle |
| **SWEEP LOOKS HUNG, or a QA lane is red** (not an abort) | A sweep at 0% CPU with no sockets is waiting in a `gh` child: check `pgrep -P <pid>`, the child's age and the run it watches. On a red, ask whether a test actually ran and failed: a runner setup step, an API 5xx, or a `Bundler::GemNotFound` naming the version this sweep just published ("the author has removed it") is a re-run, never an eject. Re-run ALL jobs (`gh run rerun <id>`, not `--failed`): the `*_executed_set` guards re-read receipts. A still-open G3 attempt may be a peer's live sweep, and its candidate may absorb your task: read your task's stage once `bin/release status` reads `none active` | let the sweep finish, or re-run `prepare` (it stands down before anything irreversible) |

`prepare` never force-ships a red candidate: eject it or fix it forward.

**A member left `reviewed` on a GREEN QA run is the per-repo evidence guard**: it needs
QA evidence for **every** repo it names (gems and the `qa_evidence: exempt` repos, turf-vault,
cyvasse, dads-app, prisoners-dilemma, weekly-lock, rantly, portfolio, 10and5 and search-position, excepted), logged as `[release-evidence] … landed nothing for <repo>`. The ship guards
`shipped_shas` the same way, though `merged: "main"` still lands per repo. Get the
missing repo onto the candidate, or drop it from the task.

### Detecting an UNFINISHED release candidate

An unfinished RC was promoted (step 3), never flipped (step 7):

```bash
bin/release status                      # current release + state
bin/task list --stage reviewed          # any of these merged onto release is an unfinished member
bin/task show <task> --json | jq '{stage, merged, release_slug}'
```

| `stage` | `merged` | Meaning |
|---|---|---|
| `reviewed` | `null` | Waiting to be swept — normal. |
| `reviewed` | `"release"` | **UNFINISHED — merged, never assembled. Diagnose before re-running.** |
| `assembled` | `"release"` | Healthy member, QA-green. |

⚠️ **The board state does NOT say why.** The latest **G3 Candidate** attempt closed
`failed` is an **ABORT**; still open is an **INTERRUPTION** (or a peer's live sweep).

## Exit Seam

Candidate and members `assembled` (`merged: release`), latest **G3 Candidate** closed
`success`; /deployments shows **three greens with Confirming deliberately DARK** — do NOT
stamp `confirming` (Steffon does, in `production-deploy`). Report: release slug, QA URL,
members, any ejected task with evidence, and "deployed to QA". No-op: "nothing to prepare."

## Related

- [`../../steffon/sops/production-deploy.md`](../../steffon/sops/production-deploy.md) — the deployer act this candidate hands off to.
- [`../../steffon/sops/archive-shipped.md`](../../steffon/sops/archive-shipped.md) — Steffon's post-ship closeout.
- [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md) — the G3 Candidate gate this act produces.

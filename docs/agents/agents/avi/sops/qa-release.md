# QA Release

## Status: Active

This is Avi's `qa-release` SOP: the self-healing release prepare sweep. It detects
reviewed work and release stragglers, promotes `accepted → release` via ONE batch PR
per repo, allocates each gem member's version, publishes it and bumps consumer locks
(producer-first, before anything tests or deploys), runs the pre-QA gate, deploys QA,
and flips members to `assembled` only on QA-green. `qa-deploy` is the legacy name.
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
promote PRs, which the deployer identity cannot. Git pushes ride the global credential
helper (`bin/gh-app-git-credential`); the sweep's `gh` calls need a minted token, so
before the sweep export:

```bash
export GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | \
  /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential get | \
  sed -n 's/^password=//p')
```

**Do not export `GH_APP_ITEM` here**: a leftover ship-lane export mints the
**deployer**, which has **no `pull_requests` grant**. On `Resource not accessible by
integration`: `unset GH_APP_ITEM`, re-run the export, re-run `bin/release prepare`.

A mid-sweep **401 `Bad credentials`** (the 1-hour token expired) or **403 `not
accessible by personal access token`** (`GH_TOKEN` empty): re-mint with `eval
"$(bin/gh-auth-refresh --export)"` and read its stderr (eval hides the exit code).
Self-service; never `gh auth login`, never print the token
([`source-control.md`](../../../modules/source-control.md)).

## Assembler claim — automatic, on the RELEASE record

**`bin/release prepare` takes the lock for you**: the per-release `assembler` conductor
claim, BEFORE the irreversible promote, renewed for the sweep's life and released on
completion. There is **no `bin/devops-shift acquire steffon` step any more.**

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
   `⚠ HELD <slug>: names parked <repo> (ladder: <ladder>)`, left in its stage, never
   promoted. A task naming a live AND a parked repo is held WHOLE.
2. Open or resume the release candidate.
3. **Promote `accepted → release`**: per repo with reviewed work, open (or reuse) ONE
   `--base release --head accepted` batch PR and merge it. Idempotent: `accepted` level
   with `release` skips the PR but still records + deploys. Membership is recorded
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
   prepare`. **Do not `reset` `release` to "clean up" an aborted sweep.**
4d. **Allocate gem versions, publish gem members, bump consumer locks — BEFORE
   the gate and QA** (producer-first — a RubyGems push can never be re-pushed).

   **Each publish is gated on GitHub's CLEAN-ENV verdict for the exact tip it would
   push**, and fails closed. The gem's own `bin/release-check --build` runs first and
   aborts first when red. Pending and not-yet-started both WAIT; a terminal non-green or
   a poll timeout aborts with **nothing published** and the version still free: fix or
   re-run the named run, then re-run `prepare`.

   **Phase 0 ALLOCATES the version, so you never type one.** Per swept gem it derives
   the bump from membership (`breaking` risk tag → major, else a `feature` member →
   minor, else patch; a member's `gem_bump` overrides), advances the **last published**
   version (the higher of the last `v*` tag and RubyGems), and commits the
   `version_file` **with its `Gemfile.lock` and rolled `CHANGELOG.md`** onto
   `origin/accepted`; the ordinary batch PR carries it to `release`. Nothing is carried
   back down from `release`. Phase 0 decides for EVERY gem before writing to ANY.

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
     which rolls NOTHING, so roll the changelog by hand in that same commit; (2) a re-run
     after an abort between the version commit and its tag push; (3) the window inside
     one sweep before the tag push.
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

   Phase 1 **preflights EVERY swept gem before the first push**: a fail-closed fetch of
   `origin/release`, the `version_file` parse, the **stranded-work guard** (`release`
   ahead of the last `v*` tag while the version did NOT advance; equal, backward and
   unparseable all block — see STRANDED GEM WORK), and a consumer-coverage check
   **unless the gem is self-gated** (a `release_check` in `config/release_repos.yml`;
   such a gem may ship gem-only). ANY failure aborts with **zero gems published**.
   Phase 2 publishes each gem's `origin/release` version (skip-if-live) and commits each
   consumer's `Gemfile.lock` bump (`bundle lock --update <gem> --conservative`) onto the
   consumer's `origin/release`, **verified by reading the lock back** and retried on a
   3-attempt backoff (see CONSUMER LOCK BUMP). The same commit carries any new **engine
   migrations** (`<engine>:install:migrations` plus `db:migrate` against a throwaway
   database so `db/schema.rb` lands); a failed probe, an unexpected schema rewrite, or an
   underivable throwaway database ABORTS. The gate and QA then read the post-bump SHA. A
   QA bounce can orphan a published version; the fix bumps past it.
5. Run the pre-QA gate on `origin/release`. **GitHub CI's conclusion for that exact SHA
   IS the verdict**; nothing runs locally. It polls a pending run, passes only on green,
   and fails closed on everything else. It may **credit** an existing green for the same
   commit or the accepted head's **identical tree** (named in the gate note). It records
   SHA + command + verdict as a `pre_qa_gate` SOP; G4 re-reads the frozen SHA itself. A
   self-gated gem in a gem-only release earns the same identical-tree credit. A red gate,
   and why you must **not** blank the registry's `qa_test_cmd`:
   [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md).
6. Deploy QA and wait for boot. Gem members are QA'd through the consumer's bumped lock;
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
- **NOT GREEN** — a verdict, then a **normal return**: QA did not come up, members stay
  `reviewed`. **Fix the cause first, THEN re-run.**

**THE EXIT CODE IS NEVER THE VERDICT** (NOT-green exits **0**). `✓ Assembled <rel>` is
green; `✓ Prepared (NOT assembled — QA not green)` is not.

### INTERRUPTION — re-run `bin/release prepare --yes`. That is the whole fix.

Do not hand-merge or hand-flip stages; a re-run skips promoted work and resumes the same
candidate. It REFUSES only on a stale tree (step 3b): take the **STALE TREE** row.

### ABORT — fix the cause, THEN re-run

An abort leaves the same board state as an interruption. Each abort names its case:

| Abort | Fix FIRST | Then |
|---|---|---|
| **A GEM'S `version_file` MOVED AND THE SWEEP ABORTS EITHER WAY** ("does not declare EXACTLY ONE version literal" at the phase-0b write, OR "promote refused — <repo> (suite workflow …) cannot certify `accepted`") | `bin/release.rb` reads the registry from the CONDUCTOR'S checkout, so registry and gem tree must move TOGETHER. OLD registry + NEW tree fails in `commit_gem_version!` naming the gemspec — **do not follow that abort's set-it-by-hand remedy**. NEW registry + OLD tree fails in `refuse_blind_accepted!` and reads like the CANNOT CERTIFY row — **do not edit `on.push.branches`**. Land the gem-side move and the `config/release_repos.yml` change in the SAME release, gem repo first, and drive the sweep from a checkout carrying the new registry. `bin/dor-check` also reads its own checkout's registry: run it from the hub worktree holding the change | land both, then re-run `prepare`; nothing was published |
| **CHANGELOG BACKLOG / UNREADABLE CHANGELOG** (step 4d phase 0 — "CHANGELOG.md carries a BACKLOG", "…parse as neither a version nor the Unreleased bucket", "…is AHEAD of the last published version", "has an unterminated fenced code block") | Nothing was written or published. BACKLOG: in a docs PR on the gem's `accepted`, attribute the entries to the versions that shipped them (studio-engine `docs/RELEASE.md`). UNREADABLE: fix the named heading to the file's dialect. Unterminated fence: close it. AHEAD: move that heading's entries back under `## Unreleased` and delete the heading. Other variants name their own fix. **Do not delete the entries to get past this** | re-run `prepare`; it resumes |
| **GEM VERSION ALLOCATION REFUSED** (step 4d phase 0 — "REFUSING to allocate a version") | **Do not set a version by hand.** Unreadable override → `bin/task update <task> --gem-bump patch\|minor\|major` (or clear it); unparseable last version → fix the `v*` tag or `version_file`; a doubled version → declare one; failed or stale `bundle lock` → fix the bundle (stale is usually propagation: wait); `<version> is already live on RubyGems, but the last v* tag…` → `git -C /Users/alex/projects/<gem-repo> push origin v<version>`, or tag the `Release <version>` commit on `origin/release`. An earlier gem's version commit on `accepted` stays THERE | re-run `prepare`; allocation resumes |
| **STRANDED GEM WORK** (gem `origin/release` ahead of its last `v*` tag, version not advanced — unbumped, BACKWARD, or unparseable) | Check phase 0's output first; if it refused, fix that row. To set it yourself: `next = <tag> + bump` (major if any member is `breaking`, else minor on a `feature`, else patch; `gem_bump` overrides). Commit straight onto the gem's `accepted` — not a PR, which `bin/dor-check` refuses:<br>`cd /Users/alex/projects/<gem-repo> && git checkout accepted && git pull`<br>edit the `version_file` (read the registry: `lib/studio/version.rb`, `lib/solana_studio/version.rb`)<br>roll `CHANGELOG.md` in the same commit: `## <next> — <date>` under `## Unreleased`, entries beneath it<br>`bundle lock` **← REQUIRED when the repo tracks a `Gemfile.lock`**<br>`git commit -am "Release <next>" && git push origin accepted`<br>A `DOWNGRADE` means a merge resolved the version backward: fix it forward | re-run `prepare`; nothing was published or deployed |
| **Pre-QA gate red — a member REGRESSION** | `bin/release eject <task> --feedback "<failing evidence>"`, then revert its merge commit on `release` (the abort prints the guidance) | re-run `prepare`; the rest of the RC rides |
| **Pre-QA gate red — ENV/toolchain** (unsatisfied bundle, Postgres down, Ruby divergence) | **Nothing to eject or revert.** Fix the environment exactly as the abort names it | re-run `prepare` |
| **QA DEPLOY NEVER DISPATCHED** (step 6 — "`<workflow>` was dispatched but GitHub registered NO run for it — the deploy NEVER RAN") | **Do not touch the app.** Run the dispatch command the abort prints and confirm a run registers (`gh run list --workflow <workflow> --limit 3`). Do NOT reach for `bin/qa-server deploy` or lengthen the boot poll. The promote and gem publish have ALREADY happened: this is NOT a clean slate | re-run `prepare` once a manual dispatch registers a run |
| **QA DEPLOY DISPATCHED, RUN LIST UNREADABLE** (step 6 — "the run list could NOT be read afterwards — whether a run was created is UNKNOWN") | **Do NOT re-dispatch** — a second deploy can land on a live one. Fix the reader (`gh auth status`; `eval "$(bin/gh-auth-refresh --export)"`), then `gh run list --workflow <workflow> --limit 5`. If a run for that SHA is listed, `gh run watch <id> --exit-status`; only a readable list with no run makes a hand-dispatch safe | once the deploy's real state is KNOWN: re-run `prepare` (it resumes over the promoted/published work) |
| **QA DEPLOY NOT DISPATCHED — NO BASELINE** (step 6 — "`gh run list` never answered/FAILED, so there is no baseline … NOT dispatching. NOTHING WAS DEPLOYED") | **The refusal is CORRECT.** Read the quoted `gh said:` line and its `→` remedy; a `HTTP 401: Bad credentials` means the sweep outlived its ~1h token: re-mint. The promote and any gem publish have ALREADY happened | fix what gh named, then re-run `prepare`; it resumes over the merged/published work |
| **QA deploy / boot FAILED** ("never returned /up 200") | **FIRST scroll up for `⚠ <workflow>: … NOTHING WAS DEPLOYED; this is not a boot failure`** — then the app was never deployed and the rows above apply. Otherwise fix the boot failure (the summary prints the `bin/qa-server deploy …` retry); eject the member if it is the cause | re-run `prepare` **once QA boots** |
| **STALE TREE** (step 3b — "prepare refused: … would deploy a tree that does NOT contain `accepted`") | **The good outcome — the sweep caught itself.** READ THE REFUSAL FIRST. **LOST STAMP** naming a task → run the two commands it prints (`bin/task merged <slug> accepted`, plus `bin/task move <slug> reviewed` unless already there). A commit no task owns → `gh pr create --repo <owner/name> --base release --head accepted …`, **watch that PR's CI to green**, then `gh pr merge <pr-url> --merge --match-head-commit <the accepted head the abort names>`. Never push or reset `release`; there is deliberately no flag | re-run `prepare`; it promotes nothing new, re-gates, and re-deploys QA over the tree that now carries the work |
| **STALE TREE — rung could NOT be read** (step 3b — "a failed read is not a clean read") | Clone the repo as a sibling, or `git fetch origin` in it, so `origin/release..origin/accepted` can be read | re-run `prepare` |
| **`accepted → release` promote failed** (a conflict on the batch PR) | Resolve the conflict on the batch PR (or `bin/task block` the offending member) | re-run `prepare` |
| **CHANGELOG MISFILE GUARD REFUSED THE PROMOTE** (step 3 — "the CHANGELOG misfile guard REFUSED the promote — NOTHING was promoted, recorded or deployed", then per gem "would file N line(s) written under '## Unreleased' beneath a version that already shipped without them" or "the promote would CONFLICT in CHANGELOG.md") | Nothing was promoted in ANY repo. Merge `origin/release` into a branch off the gem's `accepted`, move every line filed under a shipped version back under `## Unreleased` (resolve a conflict the same way), and push that merge straight onto `accepted` — **not a PR**, which `bin/dor-check` refuses. Fail-closed variants ("git fetch failed", "could not resolve…", "git merge-tree could not predict", git 2.38+) name their fix. A commit landing on `accepted` meanwhile fails the pinned merge: re-run | re-run `prepare`; it resumes |
| **Member left `reviewed` with `merged: ""`** (review never landed its feat PR on `accepted`) | Re-review the task so `pr-review` merges it onto `accepted` | re-run `prepare` |
| **`⚠ HELD <slug>: names parked <repo> (ladder: <ladder>)`** (step 1 — not an abort; `bin/release merge <slug>` refuses the same task) | **Do not force it through.** If the repo carries no work, drop it (`bin/task update <slug> --repo …`, which REPLACES the list); if the repo is being revived, set `ladder: three-rung` on its registry row in a task of its own. A parked repo in the deploy plan is refused at step 3b, same fix | re-run `prepare`; the task sweeps once no repo it names is parked |
| **MULTI-REPO PR RECORD INCOMPLETE** (step 3a — "multi-repo task(s) with an incomplete PR record") | Record the missing PR — `bin/task update <slug> --pr-url-for <repo>=<pr-url>` — or drop the repo with no work (`bin/task update <slug> --repo …`). Nothing was promoted | re-run `prepare`; the member sweeps with every repo it names |
| **ACCEPTED NOT COVERED BY THE PROMOTE** (step 4a-bis — "`accepted` carries commits for X, a repo this release's members NAME, but this sweep would promote only Y") | Usually a PARTIAL earlier promote. Land it (`bin/release merge <slug>`, fanning out over every repo the task names) or drop X from the task; `bin/release status` shows git and board side by side. A repo NO member names is out of scope | re-run `prepare` once every member-named ahead repo rides |
| **A REPO CANNOT CERTIFY `accepted`** (inside the promote — "promote refused — <repo> (suite workflow "CI") cannot certify `accepted`") | Add `accepted` to that repo's suite workflow `on.push.branches` (reference: `mcritchie-studio/.github/workflows/ci.yml`, deliberately no `concurrency:` block) and land it on the repo's `accepted`. Do **not** drop the repo from the sweep. Exempt only by declaration (`Release::AcceptedCertification::GEM_SUITE_WORKFLOWS` nil; none today) | re-run `prepare`; it resumes |
| **CONSUMER LOCK BUMP did not land** (`bundle lock … did not land in <repo> … resolves <old>, wanted <new>`) | **WAIT — nothing to fix.** Watch the compact index bundler reads: `curl -sS https://index.rubygems.org/info/<gem> \| tail -5`, not the API or HTML page. Do **not** bump the version | re-run `prepare`; the publish skips as already-live and the bump lands |

`prepare` never force-ships a red candidate: eject it or fix it forward.

**A member left `reviewed` on a GREEN QA run is the per-repo evidence guard**: it needs
QA evidence for **every** repo it names (gems and `qa_evidence: exempt` turf-vault
excepted), logged as `[release-evidence] … landed nothing for <repo>`. The ship guards
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
`failed` is an **ABORT**; still open is an **INTERRUPTION**.

## Exit Seam

Candidate and members `assembled` (`merged: release`), latest **G3 Candidate** closed
`success`; /deployments shows **three greens with Confirming deliberately DARK** — do NOT
stamp `confirming` (Steffon does, in `production-deploy`). Report: release slug, QA URL,
members, any ejected task with evidence, and "deployed to QA". No-op: "nothing to prepare."

## Related

- [`../../steffon/sops/production-deploy.md`](../../steffon/sops/production-deploy.md) — the deployer act this candidate hands off to.
- [`../../steffon/sops/archive-shipped.md`](../../steffon/sops/archive-shipped.md) — Steffon's post-ship closeout.
- [`../../../modules/gates/g3-candidate.md`](../../../modules/gates/g3-candidate.md) — the G3 Candidate gate this act produces.

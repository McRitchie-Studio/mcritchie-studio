# Production Deploy

## Status: Active

Steffon's `production-deploy` SOP ships an assembled, QA-green release to production.
History cut from this page:
[`../../../archive/production-deploy-2026-09-25.md`](../../../archive/production-deploy-2026-09-25.md).

## Scope

Steffon owns stages 4-5 (Confirming, Deploying) as the **deployer**
(`ReleaseConductorClaim` role `deployer`). This crosses the production gate: run it only
when Alex McRitchie launched `production-deploy` or granted ship authority in-session.

## Entry

**Production deploy is admin work.** It needs two credentials no build, review, or
QA lane holds:

| What | Where it comes from |
|------|---------------------|
| `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` — the only token that reads the `studio-agents-admin` vault | `~/.zprofile.admin`, installed once per machine by `bin/setup-1pass-token --admin` |
| `github.mcritchie-admin` — the ship GitHub App identity | that vault, selected with `export GH_APP_ITEM=github.mcritchie-admin` |

The App's pre-2026-09-26 item name is retired and refused; export the name above.

**The Heroku token.** No profile exports `HEROKU_API_KEY`. `bin/release` reads
`heroku.studio.agents` from 1Password ONCE, at its first PROD board op (which
precedes every write), and exports it to every child. It does this only when
`bin/shims/heroku` is the `heroku` on PATH: any other CLI brings its own login. So every `heroku run`
board op, the ship-authority poll and each git push to Heroku shares that one
read. If the read fails, the run refuses before acting ("no Heroku token for the
PROD board ... Nothing was done"): fix what it names (usually `source ~/.zprofile`)
and re-run. A `HEROKU_API_KEY` you export yourself is used as given. Detail:
[`credentials.md`](../../../modules/credentials.md), "Heroku tokens resolve at use time".

You are **expected to hold both**; an absent one is this machine's setup gap. Remedy:
**`source ~/.zprofile.admin`** (yours), or, on a machine that never had one,
**`bin/setup-1pass-token --admin`** once (Alex McRitchie's: it reads his clipboard).

**The one-command path: `bin/release cycle`.** When Alex McRitchie has cleared the
whole release in chat, run `bin/release cycle --clearance "<his words>" --yes
--wait-for-1password` from the primary instead of this SOP's steps by hand. It runs
this ship (`--mode cleared`, after QA verify, then prod verify and the archive; prod verify checks that each app answers 200 and that each app with a prod deploy runs the SHA the ship pushed, a config-var set after the deploy still counting and a rollback not, and stops with exit 5 when one is not proven after three reads) as one act of a resumable state machine and sets up the credentials above
itself (the admin 1Password token from `~/.zprofile.admin`, `GH_APP_ITEM=github.mcritchie-admin`, a freshly minted deployer `GH_TOKEN`), so none of the exports here are needed for it. Re-running it resumes
from the board's stage. The full description and exit codes are in
[`full-cycle.md`](../../mason/sops/full-cycle.md#procedure).

Run from the McRitchie Studio primary checkout, **under the deployer identity**:

```bash
cd /Users/alex/projects/mcritchie-studio
source ~/.zprofile.admin          # the ship App's item lives in studio-agents-admin; only the admin token reads it
export GH_APP_ITEM=github.mcritchie-admin
export GH_TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | \
  /Users/alex/projects/mcritchie-studio/bin/gh-app-git-credential get | \
  sed -n 's/^password=//p')
```

Order matters: `GH_APP_ITEM` first makes the helper mint the **deployer**. Confirm the
lane loaded **without a pipe** (a piped `source` runs in a subshell):

```bash
source ~/.zprofile.admin
[ -n "$OP_ADMIN_SERVICE_ACCOUNT_TOKEN" ] && \
  echo "admin token: set (${#OP_ADMIN_SERVICE_ACCOUNT_TOKEN} chars)"
```

Report it by LENGTH, never by value; never probe with `echo "${VAR:-absent}"` (it
prints the token when set). A bare `op --vault studio-agents-admin` answers as the AGENT.

The two exports are NOT interchangeable:

- **`GH_APP_ITEM`** declares **the lane** for git pushes and every `gh` recovery
  (contents + actions + checks-read + secrets). The deployer **cannot open or merge PRs
  by design**; `bin/submit` and `bin/pr-review` pin `identity: "agent"` and do not run here.
- **`GH_TOKEN`** is what `gh` calls use. It expires in **1 hour** (401 `Bad
  credentials`); a 403 `not accessible by personal access token` means it is empty.
  Re-run the export, or `eval "$(bin/gh-auth-refresh --export)"` and read its stderr
  (eval hides the exit code). Never `gh auth login`, never print the token
  ([`source-control.md`](../../../modules/source-control.md)). Use the production board.

## Deployer claim — automatic, on the RELEASE record

**`bin/release ship` takes the per-release `deployer` claim for you** before any deploy
mutation. There is **no `bin/devops-shift acquire avi` step for the ship any more.**

- **Stand down** — `release-claim: 🛑 <release> deployer already held — STAND DOWN.`
  names the holder, then the ship **aborts before any deploy** with `deployer claim for
  <release> is held by another live release conductor — standing down (see the holder
  above).` Announce it and STOP (a dead holder lapses in ~120s).
  The holder line is the Next Release card's own sentence for the role (mascot,
  soul, session tail, since when); `bin/release status` prints the same lane.
- **Resume** — re-running your own interrupted ship re-acquires the same claim.
- **Fail-open** — a claim-transport hiccup never wedges the ship.

A live claim keeps `_ship`/`_gate` from reclaim. A **local** presence claim is
published for `bin/agent-presence` (disarm: `RELEASE_PRESENCE=off`).

## Preconditions

The active release is `assembled` with `qa_deployed_at` stamped and members `assembled`
+ `merged: release`. If `release == main`, no release is active, it is still
`assembling`, or `qa_deployed_at` is blank, report "nothing to ship" and stop.

**A release carrying turf-monster or turf-vault work also needs its devnet gauntlet:**
a `devnet_gauntlet` event on the release, which `bin/release prepare` runs and records
automatically after a green [`contest-rehearsal`](../../turf_monster/sops/contest-rehearsal.md)
on QA. The ship accepts only the NEWEST such event, only when it is completed, and only
when its `metadata.shas` match the Turf SHAs being shipped: a failed run newer than a
green one, or a green one for other Turf code, is a refusal. Without a covering record,
do not ship: re-run `bin/release prepare` (or `bin/release cycle`, which does it for
you), which runs the gauntlet again.
`bin/release ship` reads the record in its decision snapshot and refuses before
anything is published or pushed (`Release::DevnetGauntlet`). Only Alex McRitchie's words waive
it: `bin/release ship --skip-devnet-gauntlet "<his words>"`, which ships with a loud
warning and records nothing.

**`bin/release <cmd> --help` is safe to probe** and exits 1 (a refusal exits 2): a 1 or
2 means "nothing ran", never the clean ladder `status --clean-only` asserts with 0.

## Procedure

**Direct-drive this act — do NOT wrap it in a subagent**: a subagent that dies
mid-ship leaves a partial `release → main` state. **Recovery from an INTERRUPTED ship:
re-run the command that was running, with the same flags.** Prefer
`bin/release cycle --clearance "<his words>" --yes`: it enters at the board's current
stage, so it resumes the ship and then runs prod verify and archive. Only when the ship
ran on its own, re-run it as it ran: after a cleared ship that is
`bin/release ship --mode cleared --clearance "<his words>" --yes`. A bare
`bin/release ship --yes` resolves to `--mode auto` and records no clearance on the
release. Add `--wait-for-1password` to either when it stopped on
`1Password is not answering`: it waits for 1Password and resumes the run itself.
`merged: "main"` repos skip re-ff and a gem already live skips its publish. Every
"re-run `bin/release ship`" below means this same command, flags included.

**Gate before confirming the ship.** The Avi → Steffon handoff exists only when
`Release.current.state == "assembled"` and `qa_deployed_at` is present:

```bash
bin/release status
```

On `release == main`, stop. Otherwise validate the production board:

```bash
heroku run -a mcritchie-studio --no-tty --exit-code rails runner \
  'r = Release.current;
   ready = r&.state == "assembled" && r.qa_deployed_at.present?;
   puts({
     ready: ready,
     release: r&.slug,
     state: r&.state,
     qa_deployed_at: r&.qa_deployed_at&.iso8601,
     qa_url: r&.qa_url
   }.to_json);
   exit(ready ? 0 : 1)'
```

Nonzero means not ready: do not stamp `confirming/start`, do not run `bin/release
ship`, and report "nothing to ship" with the printed state. Once it passes, light
stage 4 under your name (`docs/agents/modules/task-board-api.md`, "Release stage
timeline"); the stamp is first-write-wins:

```bash
# api() helper + TOKEN per task-board-api.md "Worked example"
api POST /api/v1/releases/current/events/confirming/start '{"event": {"actor": "steffon"}}'
```

Then ship, naming the production-authority mode. When Alex McRitchie cleared this release in
the session (his words in the chat, or a launch prompt that grants the lane), his
clearance is the grant:

```bash
bin/release ship --mode cleared --clearance "<Alex McRitchie's words>" --yes
```

When this act runs as part of the whole lane ([`full-cycle`](../../mason/sops/full-cycle.md)),
`bin/release cycle --clearance "<Alex McRitchie's words>" --yes` runs this ship for you
between QA verify and prod verify, so do not run it by hand as well. A release Alex
McRitchie scoped with `--task` keeps the manual `prepare --task` → ship → archive steps,
because the cycle's prepare is always bare.

When nobody cleared it (a heartbeat, a scheduled run), ask through the window:

```bash
bin/release ship --mode timed --yes
```

Ship from the primary checkout. **`--mode` takes production authority**
(`devops-task-board.md`, "Operator windows"):

| Mode | What happens at the authority step |
|---|---|
| `cleared` | records Alex McRitchie's chat clearance as the grant: `--clearance "<his words>"` is required, and the completion carries `granted_via chat`, `cleared_by` and the words. `--cleared-by` and `--by` default to `Alex McRitchie` (never the Mac login, which is the `alex` soul slug). No window, no button, and each run records its own grant, so a re-run stores the words it was given. A blank clearance refuses before anything moves, and so does `--clearance` with any other mode. The Next Release card names it as cleared in chat and unsigned, never in the success tone a signed Approve gets. |
| `timed` (the config default, `production_ship.mode` in `config/release_builder.yml`) | posts the `ship_authorized` request on the release, shows a 30-minute countdown with an **Approve** button on the Next Release card, and waits. A grant deploys at once. On lapse it deploys only if G3 Candidate is green and no member carries an open escalation; otherwise it refuses, names why, and deploys nothing. |
| `ask` | the interactive `confirm("Deploy this release to production?")` prompt — holds until a human answers (needs a TTY, or `--yes`). |
| `auto` | proceeds on green with no prompt. `bin/release ship --yes` with no `--mode` is `auto`. |

`--yes` answers the OTHER local confirms and skips nothing else. **The authority step is
the only human gate; in `cleared` mode that gate is Alex McRitchie's word in the chat, recorded on
the release.** A timed ship that refused at
the lapse is re-run the same way once the blocker is cleared, or re-run and approved
while its NEW window is open. The re-run posts a fresh window (its own request event,
keyed by its end), and a grant counts only for the latest request — an Approve clicked
before the re-run answers the old request and authorizes nothing. The grant stays one
row per window however it lands.

**What a grant covers.** A production grant covers everything on the release at ship
time. A task that joins after the grant rides on it; no second approval is asked. The
grant record keeps the member set at the moment it was given
(`metadata.scope.member_slugs`, with `policy: release_at_ship`), and the Next Release
card and `bin/release status` state it: `Approved by <name> at <time>, timed mode.
Covers every task on this release when it ships: 6 at approval, 16 now. Joined after
approval: <slugs>.` Read that line before the deploy step; it is what the approval
now carries. A grant recorded before the member set was kept reads `member set at
approval not recorded`.

**Who the line names.** `Approved by <name>` prints only for the Approve button on
`/deployments`: that request stamps `metadata.owner_grant` (the signed-in admin's
id, slug and the time) and signs it with the hub's own secret for that release,
step and event. The board removes the key from the metadata of every other write,
and the line names a person only when the signature verifies for the row it sits
on and the user exists, so no caller can state who approved: an unsigned marker,
or one copied from another release or event, reads as no marker. The name is the
user record's, never text from the row. A `SECRET_KEY_BASE` rotation makes every
earlier signature unverifiable, so approvals recorded before it read `approver not
recorded`: the line under-claims and never over-claims. Every other answer says
how it was recorded and names no approver:

| The record | The line |
|------------|----------|
| The Approve button | `Approved by <name> at <time>, <mode> mode.` |
| `bin/release ship --mode ask` (with or without `--yes`) | `Recorded by the conductor CLI in ask mode (run as <actor>) at <time>; no web approval.` |
| `bin/release ship` in `auto` mode | `Proceeded on green with no approval asked at <time> (auto mode).` |
| `bin/release ship --mode cleared --clearance "<Alex McRitchie's words>"` | `Cleared in chat by <cleared_by>, asserted by the conductor CLI (run as <actor>) at <time>; unsigned. "<the words>".` |
| A timed window that lapsed (any row carrying `lapsed: true`) | `No approval was given: the window lapsed at <time> and the ship proceeded on green, timed mode.` |
| A `ship_authorized` completion posted to the events API (an admin session only; the shared token answers 403) | `Recorded through the events API by <actor> at <time>; no web approval.` |
| A row marked as from the web that carries no verified `owner_grant` (one recorded before the marker, one a caller labelled, or one signed under a rotated secret) | `Authorized at <time> (<mode> mode); approver not recorded.` |

The line describes the record; it does not change what grants authority. A row
with no approver named covers the release exactly as before, and its scope line
reads `at authorization` in place of `at approval`.

`bin/release status` reads the lane for display only. A failure inside that read
prints `lane: unavailable (<error class>)` under the current release and the
command carries on; it never fails `status` or `prepare`, which make the same read.

- **The hub deploys through GitHub Actions** (`gh workflow run prod-deploy.yml -f
  sha=<frozen>`), which pushes to Heroku and hard-gates a `/up` smoke.
- **A GEM-ONLY release ships too**: under the default flow `prepare` already published
  the final and tagged it `v<x.y.z>`, so the ship finds it live and fast-forwards the
  gem repos; the RubyGems publish IS the deploy (a **GEM-ONLY** badge). Under the
  `RELEASE_GEM_FLOW=candidate` rollback the ship publishes the final, and the
  candidate QA ran is the `rc-<version>.rc<n>` tag at the frozen SHA.
- **A dirty app primary does NOT block the ship** (it deploys from `.worktrees/_ship`).
  To clean one, use the printed `rescue/<repo>-<timestamp>` branch. **Never stash it
  and never discard it.** A gem repo with modified TRACKED files DOES abort (before
  publishing): run the printed rescue, then re-run ship.
- **The ship also advances `accepted`** to the frozen SHA (guarded, non-fatal).

### Gems: the final publish, the re-lock, and its CI read

**The default flow publishes the final at `prepare`**
([`gem-release-flow.md`](../../../system/gem-release-flow.md)). The ship then finds
each gem live and every consumer already locking it: it skips the push, makes no
re-lock commit, reads no re-lock CI, and deploys the SHAs QA gated. Before any deploy
it also refuses a tree that locks a published version past a gem's `main` that this
release does not ship. The steps below run only for a release prepared under
`RELEASE_GEM_FLOW=candidate`.

**Under the candidate rollback only**, `prepare` published a **release candidate**
(`x.y.z.rcN`) and QA ran consumers on it.
The ship publishes the final `x.y.z`, and it is the only step of a release that cannot
be undone. In order, after production authority:

1. **Which candidate did QA run?** Read before authority, from each consumer's
   `Gemfile.lock` at its QA-frozen SHA (a gem-only release: the `rc-` tag at the gem's
   frozen SHA). Consumers that disagree, lock another version, or lock a candidate of
   a gem this release does not carry refuse the ship with nothing moved.
2. **Build `x.y.z` from the gem's frozen SHA and compare it with the candidate**, file
   by file and dependency by dependency; only the version literal may differ. A
   difference refuses with nothing published. A gem with no candidate is never
   published.
3. **`gem push`**, then tag `v<version>`.
4. **Wait until RubyGems serves it** (the `RELEASE_GEM_POLL_TIMEOUT` budget), then
   confirm the served `.gem`'s SHA-256 is the built artifact's.
5. **Advance the gem repo's `main`.**
6. **Re-lock each consumer to `x.y.z`**: `bundle lock --update <gem> --conservative`,
   read the lock back, and push one commit on top of the frozen SHA to `release`.
   The commit is normally `Gemfile.lock` alone; it carries `Gemfile` too when the
   line held a candidate floor or a branch source, both rewritten to `~> x.y`. The
   lock is read back because Bundler keeps a candidate that still satisfies the pin.
7. **Read CI for each re-lock commit** (the tree that deploys), for every re-locked
   consumer with a registry `test_cmd`, turf-monster included, before the FIRST app
   deploys. Anything but green there deploys nothing. The read holds for the
   workflow-sized budget (`ci_poll_budget_for`), because a re-lock commit's CI has
   only just started.
8. **The backstop.** Before the first deploy the ship reads the lock at every SHA it
   is about to deploy and refuses (`REFUSING TO DEPLOY a prerelease gem`) if one
   names a prerelease of a registered gem, whatever prepared the release.
9. Deploy: the hub first and alone, then the satellites concurrently (**App
   deploys** below). After the seal, each gem repo's own lock is bumped to the finals on its
   `accepted` (best-effort), and so is every live engine app the release did not
   carry (`config/apps.yml` `engine: true`), in parallel; each push runs that app's
   CI, and none of those apps deploys.

**Where it can stop, and what a re-run does:**

| The ship stops | The world | A re-run of `bin/release ship` |
|---|---|---|
| at the candidate preflight (step 1), including "the release record carries no candidate stamp" or names another candidate | nothing moved | the locks and the record disagree about what QA ran: re-run `prepare` with this tooling (it re-stamps and re-QAs), then ship |
| at the candidate preflight on a RESUMED ship, "some consumers lock `x.y.z` and others a candidate of it", one consumer being a QA-exempt repo (rantly, moms-app) | nothing moved this run; that repo had no `qa_sha`, so it froze at `origin/release`, which already carries the first attempt's final re-lock | `prepare` now freezes QA-exempt repos, and a ship records any repo it had to resolve live (`record: qa_shas backfill …`) before anything moves, so this needs tooling older than both. Record the candidate-lock SHA by hand (`Release::Conductor.record_qa_shas(release:, shas: { "<repo>" => "<sha>" })` on the board), then re-run |
| "does NOT match `<candidate>`, the candidate QA ran" (step 2) | nothing published | do not ship this tree: re-run `prepare`, QA the new candidate, then ship |
| after the push, before the tag | `x.y.z` live; no `v*` tag | skips the push, compares the LIVE gem with the candidate, pushes the missing tag, continues |
| "the RubyGems CDN is still not serving it" / "`gem install` still fails" (step 4) | `x.y.z` live and tagged; nothing re-locked | skips the push, waits again with a fresh budget |
| "RubyGems serves SHA-256 …" (step 4) | `x.y.z` live, and its bytes are not the artifact this ship built | skips the push and compares the LIVE gem's contents with the candidate. Equal (another build of the same tree): it proceeds. Different: it refuses (`LIVE on RubyGems and does NOT match`); then advance past the version (qa-release's STRANDED GEM WORK row) and re-run `prepare` |
| after the gem's `main`, before a consumer's re-lock push | `x.y.z` live; consumers still lock the candidate; no app moved | skips the push, re-locks |
| "did not land … resolves `<candidate>`, wanted `<version>`" (step 6) | the same; nothing was committed | wait for `curl -sS https://index.rubygems.org/info/<gem> \| tail -5` to show `x.y.z`, then re-run |
| at the re-lock commit's CI read (step 7), red, pending or interrupted | `x.y.z` live; the consumer's `release` is the frozen SHA plus the re-lock; **nothing deployed, no app `main` moved** | reuses the pushed re-lock and reads its CI again |
| at a satellite's own deploy (turf-monster's `bin/deploy`, a push, a smoke) | `x.y.z` live; the hub deployed; every OTHER satellite ran to its end and is live; the failed one's own rollback applied | fix what its deploy names; a re-run skips every app already live and deploys only the unfinished ones (**App deploys** below) |
| "REFUSING TO DEPLOY a prerelease gem" (step 8) | finals live; no app deployed, no app `main` moved | re-run `prepare` (consumers lock the live final and QA runs again), then ship |

**A red re-lock commit.** The refusal names the commit (`THIS IS THE RE-LOCK COMMIT …`).
It differs from the tree QA passed only in `Gemfile` and `Gemfile.lock`, and the final
gem was compared with the candidate, so the gate has already waited for that commit's
run to complete and re-run a first-attempt red once by itself (its `↻↻ … AUTOMATIC
RE-RUN` line, or the reason it did not). If it did not, re-run that commit's CI run
(`gh run rerun <id>`, all jobs), then `bin/release ship`. A red that reproduces is a defect:
fix it through a task on `accepted` and have Avi re-run `prepare`. The final stays
published; consumers then lock it directly and QA runs again.

**An older ship must never follow a candidate.** A ship from tooling without the
candidate flow publishes the final and deploys the frozen lock, candidate included.
`prepare` refuses to publish a candidate unless the fixed-path install and the hub
primary (working tree and `origin/main`) all carry the flow, and it stamps the
release; this ship checks that stamp and runs the backstop in step 8. Do not start
a ship from any other checkout of the hub.

### App deploys: the hub first, then the satellites at once

After the gem phase (under the default flow nothing to do, since every final is
already live and locked; under the candidate rollback, every final published and every
consumer re-locked and its CI read), the ship deploys the **hub first and alone**: it is the SSO and
source-of-truth app, so no satellite goes live against a hub that has not caught
up. A hub failure aborts the ship before any satellite moves.

The satellites then deploy **concurrently**, up to `RELEASE_DEPLOY_CONCURRENCY` at a
time (default 3, at most 4: the conductor is the fifth board writer under the cap
of 5). Each keeps its own smoke and its own rollback. Every line a satellite prints,
its children's included, is prefixed `[<repo>]`, and each app also writes a log
file; the run prints the log directory first and a summary after:

```text
  satellite deploys (2/3 live):
    ✗ FAILED turf-monster (412s) — turf-monster deploy script failed (bin/deploy) …  (log: …/turf-monster.log)
    ✓ live   rantly (95s)  (log: …/rantly.log)
    ✓ live   moms-app (88s)  (log: …/moms-app.log)
```

**One satellite failing stops no other and rolls back nothing else.** Every
satellite runs to its end; the ship then records the live ones on the release
(`metadata.deployed_apps`, with the hub) and aborts with `N of M satellite deploys
FAILED (<repos>); LIVE on production: <repos>`, **before** the post-deploy hooks, the
seal and the shipped record. It is an ABORT: fix what the failed deploy names, then
re-run the ship with the flags it ran with (after a cleared ship,
`bin/release ship --mode cleared --clearance "<his words>" --yes`), or re-run
`bin/release cycle --clearance "<his words>" --yes`. The re-run skips every app already live
(`deploy_already_succeeded?` proves it from production) and deploys only the
unfinished ones. One satellite, or `--dry-run`, deploys in the old fixed order.

**turf-monster is gated by CI, not by its own suite.** Its registry row carries
`test_cmd` (CI's `test` job) and `prod_deploy.ci_verified_arg: --ci-verified`. When
the ship read GitHub CI **green** for the exact SHA it deploys (the frozen-SHA gate,
or, under the candidate rollback, the re-lock gate for its re-lock commit), it runs `bin/deploy --yes
--ci-verified=<sha>`, and `bin/deploy` skips its local `bin/rails test` (about 20
minutes) after checking that the SHA is its `HEAD`; any other SHA refuses before
anything changes. Its IDL hash pin, Stripe live-mode and signing-wallet checks, its
smoke and its rollback all still run. Under `--skip-test-gate`, or with no green
read for that SHA, the flag is not passed and `bin/deploy` runs its suite as before.

### If the ship is KILLED after the deploy landed — finalize, do not re-deploy

A killed watcher can leave prod live and the board `assembled`. **Do not re-run the
deploy to fix the record.** Run:

```bash
bin/release ship --finalize-only [<release-slug>]
```

It **proves the frozen SHA is live first**, then records; it never deploys:

| Strategy | Apps | What proves it |
|---|---|---|
| `github_actions` | mcritchie-studio | `origin/main` at the frozen SHA, prod `/up` 200, and a `prod-deploy.yml` run whose `headSha` is that SHA concluded success |
| `git_push_heroku` | mcritchie-industries, rolio | prod `/up` 200, and the app's **current** Heroku release is a succeeded `Deploy <frozen sha>` (app from the adapter's `remote:`) |
| `repo_script` | turf-monster | the same Heroku proof, against `prod_deploy.heroku_app:`; it also needs `prod_deploy.smoke_url:` (a bare origin: the ship appends `/up`) or the repo can never be confirmed |
| `static_cloudflare` | none yet (an app after its cutover) | prod `/up` 200, and `<smoke_url>/static-release.json` names the frozen SHA ([`static-cloudflare.md`](../../../modules/static-cloudflare.md)) |

Per-repo refusals: `prod /up did not answer 200` wants a deploy (`bin/release ship`);
`<app>'s CURRENT Heroku release is not a succeeded Deploy …` means a config change or
rollback landed on top; `names no Heroku app` / `declares no smoke_url …` are registry
fixes. After a finalize-confirmed turf-monster IDL bump, check the tighten landed:

```bash
heroku config:get EXPECTED_IDL_HASH --app turf-monster-mainnet
```

Two entries is the tightened shape; more means re-run the tighten `bin/deploy` prints.

### A refused push is classified before it advises

Before each `main` push the ship mints a fresh deployer token. A failed mint is
retried once after 5 seconds; a second failure aborts before the push and prints the
mint's own error, classified NETWORK when it names one (1Password unreachable over DNS
reads NETWORK, not MINT).

A refused **`main`** push (fatal):

| Outcome | What you do |
|---|---|
| **NETWORK** (`Could not resolve host`, `getaddrinfo`, a timeout) | Restore the network, then re-run `bin/release ship` — it resumes. No token needs refreshing and `main` needs no reconciling. **Do NOT re-run `prepare`.** |
| **MINT** (`could not mint the DEPLOYER token`) | Read the mint's error, printed just above (`deployer mint said:`; it carries `op`'s own last line as `op said:`), and act on what it names. Only when it says the vault could not be read on credentials: `source ~/.zprofile.admin`. Then re-run `bin/release ship` — it resumes. |
| **AUTH** (`Invalid username or token`, `Authentication failed`, a 401/403) | `source ~/.zprofile.admin` and `export GH_APP_ITEM=github.mcritchie-admin` (BEFORE the push), then re-run `bin/release ship` — it resumes. The deployer is never cached, so there is no token to refresh by hand. **Do NOT re-run `prepare`**: the freeze is still good. |
| **NON-FAST-FORWARD** | Reconcile `main`, re-run `bin/release prepare` to re-freeze, then re-run `bin/release ship`. |
| **UNRECOGNISED** | Read git's output, printed just above the verdict, before doing either. |

A refused **`accepted`** advance (non-fatal):

| Outcome | What it means | What you do |
|---|---|---|
| **AHEAD** | `accepted` carries everything that shipped and more | **Nothing.** |
| **DIVERGED** | `accepted` is missing shipped content. Under the candidate rollback, after a gem release that includes the re-lock commit: that `accepted` still locks the candidate QA ran while `release` and `main` lock the final | Reconcile with a **merge** — recipe below. Left alone, the next sweep's promote merges it and the final's lock wins |
| **UNDETERMINED** | the relation could not be read | `git -C <path> fetch origin && git -C <path> diff origin/accepted origin/main`: any addition or modification → reconcile; when in doubt, reconcile |

**Never** reconcile with a bare `git push origin <sha>:refs/heads/accepted` (it destroys
AHEAD work). **The reconcile recipe**, in a throwaway worktree off `origin/accepted`:

```bash
git -C <path> fetch origin
git -C <path> worktree add --detach /tmp/reconcile-accepted-<repo> origin/accepted
git -C /tmp/reconcile-accepted-<repo> merge origin/main
git -C /tmp/reconcile-accepted-<repo> push origin HEAD:accepted
git -C <path> worktree remove /tmp/reconcile-accepted-<repo>
```

On a gem release DIVERGED is normal and `Gemfile.lock` often conflicts. Pick one:

```bash
# FINISH IT — resolve the files in the scratch worktree, then:
git -C /tmp/reconcile-accepted-<repo> add -A && git -C /tmp/reconcile-accepted-<repo> commit --no-edit
git -C /tmp/reconcile-accepted-<repo> push origin HEAD:accepted
git -C <path> worktree remove /tmp/reconcile-accepted-<repo>

# BAIL OUT — discard everything, leave no residue:
git -C <path> worktree remove --force /tmp/reconcile-accepted-<repo>
```

If `worktree add` says the path **already exists**, run BAIL OUT, then start over.

### The frozen-SHA test gate is a READ

For each app with a registry `test_cmd`, `ship` reads **GitHub CI's settled verdict for
the frozen ship SHA's tree** (the SHA's own run polled to a conclusion, or a same-SHA /
same-tree green credited from the accepted head) and records a `ship_test_gate` SOP
naming the source. Nothing runs locally, and it does not self-gate on G3's record.
Under the default flow it reads the frozen SHA once, before authority: consumers
already lock the live final there. Under the candidate rollback it reads twice for a
consumer of a shipped gem: the frozen SHA before authority, and the re-lock commit
after the final is published and before any deploy. Both reads use the rows below;
the second adds the re-lock recovery text. Every app with a
`test_cmd` is read, turf-monster included; an app with none self-gates and is read by
neither. A green read is also what lets turf's `bin/deploy` skip its local suite
(**App deploys** above).

**One automatic re-run.** A red read earns ONE re-run of the failed workflow runs
(`gh run rerun <id>`, every job, so the `*_executed_set` guards re-read fresh
receipts) when each failed run is on its first attempt, failed or timed out (never
cancelled, never a schedule run), and every failing job is a test lane (a suite, a
shard, the browser lane, their executed-set) or died on bundler's gem-resolution
error (`… can no longer be found in that source`: the RubyGems CDN race, where the
runner's edge lagged the conductor's). It prints `↻↻ <repo>: CI RED … AUTOMATIC
RE-RUN` with the reason, and the re-run gets a fresh poll window. A second red is
real and fails the gate (`CI is RED again … a second red is real`); a red lint or
scan is never re-run. The same rule runs in `prepare`'s gates (G3, the gem CI gate).
`RELEASE_CI_RERUN=off` disarms it. Code: `bin/lib/ci_rerun.rb`,
`bin/release.rb#poll_ci_verdict`.

The decision waits for the run to finish. A check-run goes red as soon as one job
fails, while the rest of the run is still going, and GitHub cannot re-run a run in
progress; the gate prints `CI RED … while a workflow run on it is still in progress —
holding for the run to complete` and decides once it is done (2026-10-27 it printed
`no failed workflow run found` instead and spent its one chance). On a **re-lock
commit** (candidate rollback only), which the gate measures to differ from the QA-green tree in `Gemfile` and
`Gemfile.lock` alone, a first-attempt red in ANY job earns the one re-run, a lint
included; a red after it is still real and is never re-run.

Every check-run on the SHA counts except a run proven **schedule-triggered** (a nightly
such as UI Budget or r2-backup attaches to `main`'s head but tests production, not the
commit); an unprovable one still counts. Detail:
[`g4-ship.md`](../../../modules/gates/g4-ship.md#where-the-verdict-comes-from).

| You see | It means | You do |
|---|---|---|
| `GitHub CI GREEN @ <sha> — credited — …` or `… — the SHA's own run …` | The tree earned its green. | Nothing — the gate passed. |
| `test gate FAILED … called frozen <sha> RED (<checks>)` | A broken frozen commit, read red after the one automatic re-run, or red in a lane the re-run rule does not cover (its `no automatic re-run (…)` line says why). | Read the failing check; fix forward on `release`, or `bin/release eject <task> --feedback "…"` and have Avi re-run `prepare`. **Do not ship.** |
| `test gate FAILED … UNREADABLE` | A token fault; the gate did not poll. | `eval "$(bin/gh-auth-refresh --export)"`, then re-run `bin/release ship`. |
| `test gate HELD … shares neither SHA nor tree with the accepted head … OWN run has NO green verdict` | Nothing could vouch for this tree yet. | Let CI conclude on the frozen SHA, then re-run `ship`. |
| `test gate HELD … NO green verdict for frozen <sha> (pending …) after polling ~1200s` | CI is still building. | Wait, or widen `RELEASE_CI_POLL_TIMEOUT`; re-run `ship`. |

For a genuine false negative, the supported override is `bin/release ship
--skip-test-gate --reason "…"`, which records a **red** gate SOP. The skip covers
every app with a `test_cmd`, and one `--reason` serves all of them. **Never** blank the
registry's `test_cmd`/`qa_test_cmd`: that silently disarms the last gate before
production. Details: [`../../../modules/gates/g4-ship.md`](../../../modules/gates/g4-ship.md).

### After the deploy

**The seal retries once through the boot window — expect a possible ~30s pause**
(`🔁 first smoke attempt failed — waiting 30s …`); do not interrupt it. **Green with
"retried once after 30s boot-window wait"** is healthy; **Red** persisted through the
retry. The seal never rolls back on its own; a red seal prints the rollback and you decide.

**Rolling back is `bin/release rollback [<release-slug>]`** (the newest shipped release
by default). Run it bare first: it prints the plan and deploys nothing. **A real run is
production authority, exactly as `ship` is: Alex McRitchie in the session.** Then run it with
`--mode ask` (confirm at the prompt) or `--mode auto` (or `--yes`):

- **Each app goes back to the SHA the release before it shipped.** The hub redeploys
  through `prod-deploy.yml -f sha=<previous>`; a `git_push_heroku` app force-pushes the
  previous SHA to its Heroku remote; turf-monster (`repo_script`) runs `heroku rollback
  v<N>` to the release that deployed it, then waits for that new Heroku release to
  succeed before it smokes `/up`. A `static_cloudflare` app rebuilds the
  previous SHA in its ship workspace and uploads it over the current files. Satellites go first, the hub last, and each non-hub app
  is smoked on `/up`.
- **`heroku rollback` reverts every config var set since v<N>, add-on vars included.**
  The plan lists each change by its release description (key names, never values).
  `--mode auto` and `--yes` refuse when there is any; `--mode ask` shows the list and asks
  a second, separate confirm. A slug-only release would keep today's config, but turf
  pins its IDL in `EXPECTED_IDL_HASH`, which travels with the slug only in a rollback.
- **It refuses a schema-ahead release and names the migrations.** Migrations already ran
  in the release phase, so fix forward or ship a down migration first. It also refuses
  when a later release has shipped or a ship is in flight.
- **It moves no ref.** `main` keeps the release's code, so land a revert on `accepted`
  through a task before the next ship, or that ship redeploys it. Data is not rolled back.
- **A rolled-back release is never a target.** Rolling back the release after it goes
  back past it to the last release that was not rolled back. A failed rollback records
  `failed` and can be re-run.
- **Gems stay published.** A published gem cannot be unpublished; each app runs the
  version its previous SHA's `Gemfile.lock` pins. A rollback never lands on a
  candidate: under the default flow a release's shipped SHA is the QA-gated SHA, which
  already locks the final; under the candidate rollback it is the re-lock commit,
  which pins the final.
- **The board record:** a `rollback` release event with both SHAs per app, a red seal
  naming the rollback, and G4's seal re-stamped red. The release and its members stay
  `shipped`, because their code is still on `main`.

**After a hub rollback, re-run the devops backfill once you roll forward.** The
rolled-back code writes `pr_url`, `branch`, `approval_status` and `session_id` only
as devops keys, so their columns go stale while it runs. When the fix ships, run
`bin/rails tasks:backfill_devops_columns` on the hub app (`heroku run … --app
mcritchie-studio`) and read its last line: it exits non-zero while any row still
diverges, so re-run it until it reports `0 still diverge(s)`. It is idempotent. `bin/release
rollback` prints this step while it can apply: when the hub range adds the columns
migration, or the hub's target tree still carries the rake.

**The seal runs the shipped tree's specs** (the hub's ship workspace at the frozen SHA,
never the primary). **⚪ unsealed** means those specs could not run, and says why; it
is not a red seal and prints no rollback. Fix the cause, then re-seal:
`bin/release reseal <release-slug>` (it overwrites the recorded seal and deploys
nothing). Use the same command to correct a seal recorded wrongly. A reseal runs the
release's frozen tree, so a spec fix merged later cannot turn that seal green; the
next release's seal shows it.

`ship` records the **G4 Ship gate** (a red seal never flips its success) and moves
members to `shipped` itself: never hand-run a bulk `bin/task move`.

Post-ship, `bin/release ship` auto-runs `bin/install-agent-docs`, so the installed
agent docs are published from what shipped; `bin/release.rb#sync_agent_docs` picks the
tree. The step is non-fatal — it never aborts a completed ship — and **Steffon owns the
step**.
If it warns, run the installer path the warn line prints
([`docs-maintenance.md`](../../../modules/docs-maintenance.md) § Editing The Entry Docs), never the primary's copy.

**Re-enable a report workflow paused for this ship.** If a scheduled report was disabled
(`gh workflow disable`) to unblock a ship and the release carries its fix, turn it back on
once the deploy lands: `gh workflow list --all --repo McRitchie-Studio/<repo>` shows it
`disabled_manually`; run `gh workflow enable <file>.yml --repo McRitchie-Studio/<repo>`,
then `gh workflow run <file>.yml` once and read the run. Open case (2026-10-25):
`ui-budget.yml` in mcritchie-studio, paused until task `ui-budget-report-never-gates` ships.

## Close out the cycle — run `archive-shipped`

**A completed ship ends by running [`archive-shipped`](archive-shipped.md):**

```bash
bin/release archive --dry-run     # preview — read it
bin/release archive --yes         # apply
```

- **Only after the ship is green.** An ABORTED ship has nothing to archive. Never
  archive past a failed ship to "tidy up".
- **It can refuse, and a refusal does NOT unship anything.** **READ THE REPORT's**
  `ledger check:` line: `LOST` → recover per [`archive-shipped`](archive-shipped.md),
  then re-run; `INTACT` → fix the quoted cause and re-run; `UNKNOWN` → establish the
  ledger's state first. A staged MID-ROLLOVER tree after a crash is conserved.
- **Report both halves separately**: a green ship next to an archive that refused.

**An ABORT and an INTERRUPTION need OPPOSITE responses.** An ABORT (red suite, failed
preflight, deploy or smoke) is a verdict: **do not force past it**; record the blocker
and hand it off. An INTERRUPTION has none: **re-run the command that was running**
with the same flags: prefer `bin/release cycle --clearance "<his words>" --yes`, and
re-run a ship that ran on its own as `bin/release ship --mode cleared --clearance
"<his words>" --yes` after a cleared ship (a bare `ship --yes` is `--mode auto` and
drops the clearance record).

## Exit Seam

The release is `shipped` (members `merged: main`), or a no-op ("nothing to ship").
A member whose own commit is not in the `main` the ship pushed for its repo is the
exception: the ship prints `⚠ containment hold: <note>`, leaves it at its stage and
comments the missing commit on its task. Ship it on a release whose `main` contains
that commit; an unreadable check clears with `bin/release finalize <release>`.
A hold that names a PR read failing on a stale or wrong PR URL: fix the URL
(`bin/task update <slug> --pr-url-for <repo>=<url>`), then run `bin/release finalize
<release>`. A held member's `merged` column can read `main` (stamped per repo at the
fast-forward); its stage is the truth.
Report slug, production SHA and URL, smoke result, and **the archive result,
separately** ("nothing to archive" is a clean answer).

**Program drift.** A ship never upgrades an on-chain program, so production can
be green while a cluster runs an older program than `main` carries. Run
`bin/program-drift` (or read the **Programs** block of `bin/release status`) and
report every `PROGRAM DRIFT` line with the card it names. A cluster with "NO
upgrade card" gets one filed per [`program-upgrade`](program-upgrade.md); a
`cannot confirm` line is reported as unknown, never as clean. Report an
`UPGRADE RESERVE SHORT` or `LOW` line too: the mainnet Squad vault cannot fund
the next program upgrade (`program-upgrade`, *The upgrade reserve*).

## Related

- [`qa-release.md`](../../avi/sops/qa-release.md) (the assembler act) · [`archive-shipped.md`](archive-shipped.md) (the closeout) · [`g4-ship.md`](../../../modules/gates/g4-ship.md) (the gate this act produces).

## Background — not needed to execute

- [`devops-cycle-design.md`](../../../system/devops-cycle-design.md) §1.4; [`credentials.md`](../../../modules/credentials.md) → *An admin lane is MEANT to hold admin credentials*.

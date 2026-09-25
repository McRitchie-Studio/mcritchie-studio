# Production Deploy

## Status: Active

Steffon's `production-deploy` SOP ships an assembled, QA-green release to production.
History cut from this page:
[`../../../archive/production-deploy-2026-09-25.md`](../../../archive/production-deploy-2026-09-25.md).

## Scope

Steffon owns stages 4-5 (Confirming, Deploying) as the **deployer**
(`ReleaseConductorClaim` role `deployer`). This crosses the production gate: run it only
when Alex launched `production-deploy` or granted ship authority in-session.

## Entry

**Production deploy is admin work.** It needs two credentials no build, review, or
QA lane holds:

| What | Where it comes from |
|------|---------------------|
| `OP_ADMIN_SERVICE_ACCOUNT_TOKEN` — the only token that reads the `studio-agents-admin` vault | `~/.zprofile.admin`, installed once per machine by `bin/setup-1pass-token --admin` |
| `github.mcritchie-deployer` — the ship GitHub App identity | that vault, selected with `export GH_APP_ITEM=github.mcritchie-deployer` |

You are **expected to hold both**; an absent one is this machine's setup gap. Remedy:
**`source ~/.zprofile.admin`** (yours), or, on a machine that never had one,
**`bin/setup-1pass-token --admin`** once (Alex's: it reads his clipboard).

Run from the McRitchie Studio primary checkout, **under the deployer identity**:

```bash
cd /Users/alex/projects/mcritchie-studio
source ~/.zprofile.admin          # the deployer item lives in studio-agents-admin; only the admin token reads it
export GH_APP_ITEM=github.mcritchie-deployer
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
  by design**; `bin/ship` and `bin/pr-review` pin `identity: "agent"` and do not run here.
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
- **Resume** — re-running your own interrupted ship re-acquires the same claim.
- **Fail-open** — a claim-transport hiccup never wedges the ship.

A live claim keeps `_ship`/`_gate` from reclaim. A **local** presence claim is
published for `bin/agent-presence` (disarm: `RELEASE_PRESENCE=off`).

## Preconditions

The active release is `assembled` with `qa_deployed_at` stamped and members `assembled`
+ `merged: release`. If `release == main`, no release is active, it is still
`assembling`, or `qa_deployed_at` is blank, report "nothing to ship" and stop.

**`bin/release <cmd> --help` is safe to probe** and exits 1 (a refusal exits 2): a 1 or
2 means "nothing ran", never the clean ladder `status --clean-only` asserts with 0.

## Procedure

**Direct-drive this act — do NOT wrap it in a subagent**: a subagent that dies
mid-ship leaves a partial `release → main` state. **Recovery from an INTERRUPTED ship:
re-run `bin/release ship --yes`**; `merged: "main"` repos skip re-ff, gems skip.

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

Then ship, naming the production-authority mode:

```bash
bin/release ship --mode timed --yes
```

Ship from the primary checkout. **`--mode` takes production authority**
(`devops-task-board.md`, "Operator windows"):

| Mode | What happens at the authority step |
|---|---|
| `timed` (the config default, `production_ship.mode` in `config/release_builder.yml`) | posts the `ship_authorized` request on the release, shows a 30-minute countdown with an **Approve** button on the Next Release card, and waits. A grant deploys at once. On lapse it deploys only if G3 Candidate is green and no member carries an open escalation; otherwise it refuses, names why, and deploys nothing. |
| `ask` | the interactive `confirm("Deploy this release to production?")` prompt — holds until a human answers (needs a TTY, or `--yes`). |
| `auto` | proceeds on green with no prompt. `bin/release ship --yes` with no `--mode` is `auto`. |

`--yes` answers the OTHER local confirms and skips nothing else. **The authority step is
the only human gate.** A timed ship that refused at
the lapse is re-run the same way once the blocker is cleared, or re-run and approved
while its NEW window is open. The re-run posts a fresh window (its own request event,
keyed by its end), and a grant counts only for the latest request — an Approve clicked
before the re-run answers the old request and authorizes nothing. The grant stays one
row per window however it lands.

- **The hub deploys through GitHub Actions** (`gh workflow run prod-deploy.yml -f
  sha=<frozen>`), which pushes to Heroku and hard-gates a `/up` smoke.
- **A GEM-ONLY release ships too**: gem repos fast-forward, the publish re-verifies
  (already-live → skip); the RubyGems publish IS the deploy (a **GEM-ONLY** badge).
- **A dirty app primary does NOT block the ship** (it deploys from `.worktrees/_ship`).
  To clean one, use the printed `rescue/<repo>-<timestamp>` branch. **Never stash it
  and never discard it.** A gem repo with modified TRACKED files DOES abort (before
  publishing): run the printed rescue, then re-run ship.
- **The ship also advances `accepted`** to the frozen SHA (guarded, non-fatal).

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
| `repo_script` | turf-monster | the same Heroku proof, against `prod_deploy.heroku_app:`; it also needs `prod_deploy.smoke_url:` or the repo can never be confirmed |

Per-repo refusals: `prod /up did not answer 200` wants a deploy (`bin/release ship`);
`<app>'s CURRENT Heroku release is not a succeeded Deploy …` means a config change or
rollback landed on top; `names no Heroku app` / `declares no smoke_url …` are registry
fixes. After a finalize-confirmed turf-monster IDL bump, check the tighten landed:

```bash
heroku config:get EXPECTED_IDL_HASH --app turf-monster-mainnet
```

Two entries is the tightened shape; more means re-run the tighten `bin/deploy` prints.

### A refused push is classified before it advises

A refused **`main`** push (fatal):

| Outcome | What you do |
|---|---|
| **AUTH** (`Invalid username or token`, `Authentication failed`, a 401/403) | `source ~/.zprofile.admin` and `export GH_APP_ITEM=github.mcritchie-deployer` (BEFORE the push), then re-run `bin/release ship` — it resumes. The deployer is never cached, so there is no token to refresh by hand. **Do NOT re-run `prepare`**: the freeze is still good. |
| **NON-FAST-FORWARD** | Reconcile `main`, re-run `bin/release prepare` to re-freeze, then re-run `bin/release ship`. |
| **UNRECOGNISED** | Read git's output, printed just above the verdict, before doing either. |

A refused **`accepted`** advance (non-fatal):

| Outcome | What it means | What you do |
|---|---|---|
| **AHEAD** | `accepted` carries everything that shipped and more | **Nothing.** |
| **DIVERGED** | `accepted` is missing shipped content | Reconcile with a **merge** — recipe below |
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

| You see | It means | You do |
|---|---|---|
| `GitHub CI GREEN @ <sha> — credited — …` or `… — the SHA's own run …` | The tree earned its green. | Nothing — the gate passed. |
| `test gate FAILED … called frozen <sha> RED (<checks>)` | A broken frozen commit. | Read the failing check; fix forward on `release`, or `bin/release eject <task> --feedback "…"` and have Avi re-run `prepare`. **Do not ship.** |
| `test gate FAILED … UNREADABLE` | A token fault; the gate did not poll. | `eval "$(bin/gh-auth-refresh --export)"`, then re-run `bin/release ship`. |
| `test gate HELD … shares neither SHA nor tree with the accepted head … OWN run has NO green verdict` | Nothing could vouch for this tree yet. | Let CI conclude on the frozen SHA, then re-run `ship`. |
| `test gate HELD … NO green verdict for frozen <sha> (pending …) after polling ~1200s` | CI is still building. | Wait, or widen `RELEASE_CI_POLL_TIMEOUT`; re-run `ship`. |

For a genuine false negative, the supported override is `bin/release ship
--skip-test-gate --reason "…"`, which records a **red** gate SOP. **Never** blank the
registry's `test_cmd`/`qa_test_cmd`: that silently disarms the last gate before
production. Details: [`../../../modules/gates/g4-ship.md`](../../../modules/gates/g4-ship.md).

### After the deploy

**The seal retries once through the boot window — expect a possible ~30s pause**
(`🔁 first smoke attempt failed — waiting 30s …`); do not interrupt it. **Green with
"retried once after 30s boot-window wait"** is healthy; **Red** persisted through the
retry. The seal never auto-rolls-back: the rollback commands print and you decide.

**The seal runs the shipped tree's specs** (the hub's ship workspace at the frozen SHA,
never the primary). **⚪ unsealed** means those specs could not run, and says why; it
is not a red seal and prints no rollback. Fix the cause, then re-seal:
`bin/release reseal <release-slug>` (it overwrites the recorded seal and deploys
nothing). Use the same command to correct a seal recorded wrongly.

`ship` records the **G4 Ship gate** (a red seal never flips its success) and moves
members to `shipped` itself: never hand-run a bulk `bin/task move`.

Post-ship, `bin/release ship` auto-runs `bin/install-agent-docs` from the hub's **ship
workspace** (`mcritchie-studio/.worktrees/_ship`, pinned at the SHA that just shipped),
so the installed agent docs are published from exactly what shipped. The hub **primary
is the fallback, not the source**: `sync_agent_docs` drops back to it only when the
ship workspace holds no installer, because the primary can sit a release behind. The
step is non-fatal — it never aborts a completed ship — and **Steffon owns the step**.
If it warns, run the installer path the warn line prints
([`docs-maintenance.md`](../../../modules/docs-maintenance.md) § Editing The Entry Docs), never the primary's copy.

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
and hand it off. An INTERRUPTION has none: **re-run `bin/release ship --yes`**.

## Exit Seam

The release is `shipped` (members `merged: main`), or a no-op ("nothing to ship").
Report slug, production SHA and URL, smoke result, and **the archive result,
separately** ("nothing to archive" is a clean answer).

## Related

- [`qa-release.md`](../../avi/sops/qa-release.md) (the assembler act) · [`archive-shipped.md`](archive-shipped.md) (the closeout) · [`g4-ship.md`](../../../modules/gates/g4-ship.md) (the gate this act produces).

## Background — not needed to execute

- [`devops-cycle-design.md`](../../../system/devops-cycle-design.md) §1.4; [`credentials.md`](../../../modules/credentials.md) → *An admin lane is MEANT to hold admin credentials*.

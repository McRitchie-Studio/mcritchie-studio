# Building SOP — the feature agent's build flow, task → submitted
<!-- registry: feature-agent build flow + local-review decision -->

**Purpose.** Take one task from a claim to the `submitted` seam: a non-draft PR
into `accepted`, green CI, and a passing `bin/dor-check`.

**When.** Any work that produces a diff — feature, bug, or chore. There is **no
size exemption**: a one-line diff is still a Build-lane task.

**Who.** A **feature agent**: the per-task Pokémon, whose soul and build checklist
live in [`../agents/pokemon/role.md`](../agents/pokemon/role.md). A session holding
an epic runs [`focus-session.md`](focus-session.md), spawns you per task, and
spawns your reviewer when you report `submitted`.

**Exit.** The task is on `submitted`, with a PR into `accepted` led by the task URL.
You never merge, deploy, or touch `release`/`main` unless Alex assigns you
that lane in this session.

The one judgment call is **Step 4**: does the change earn Alex's local
review? Everything else is sequencing. The command-by-command rules (where each
script runs, the author set, the long form) are in [`fast-lane.md`](fast-lane.md).
The rationale and history this page no longer carries are frozen verbatim in
[`../archive/building-sop-2026-09-25.md`](../archive/building-sop-2026-09-25.md).

> **Stale GitHub credential?** Run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"` in the same shell command as the retry, read its stderr (eval hides the exit code), and never ask for `gh auth login` ([`token-session.md`](token-session.md)).

## The lanes, so you know where you stop

The code walks **`accepted` → `release` → `main`**, and the task walks two
workflows that meet at `submitted`:

- **Build (you)** — `designed → building → submitted`. You claim, build, test,
  and open a PR into **`accepted`**. You stop at `submitted`.
- **Deploy (DevOps)** — `submitted → reviewed → assembled → shipped`. Review
  merges your PR onto `accepted`; Avi's `qa-release` promotes `accepted → release`;
  Steffon's `production-deploy` fast-forwards `release → main`.

## Step 1 — Claim: task + worktree + preflight

One command creates the task, cuts a desk on an allocated port, preflights the
desk, and claims the task. Skip it when a focus session already made your desk.

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Three To Five Words" --repo <app> --kind <kind> \
  --shape <shape> --risk <tag> --accept "criterion" --test "[unit] ..."
```

- **Title: 3-5 words.** The slug derives from it and seeds `feat/<slug>`. Pass
  `--slug` only to override.
- **Each `--accept` bullet: 5-12 words.** Put detail in `--agent-context "…"`.
- **`--agent <soul>` is optional.** Review keeps you off your own PR by the souls
  on its commits (`<soul>@mcritchie.studio`), which the board derives from GitHub,
  so what matters is that your desk commits as you. `--agent` sets that identity
  (so does `bin/agent-worktree identity <repo> <slug> <soul>`) and also stamps
  `devops.built_by`, which review unions with the derived set. You never stamp
  `merged` or `pr_url`: the board derives both. The exclusion rules and the
  selector's refusal states: [`pr-review-sop.md`](pr-review-sop.md).
- **Classify the shape**; it selects the tests you owe
  (`config/feature_shapes.yml`): `ui-only` · `ui+db` · `backend` · `library` ·
  `onchain` · `onchain-vertical` · `docs` · `test-only`. Shape by the files, never
  the hunk ([`fast-lane.md`](fast-lane.md#the-long-form-fallback)). `begin` refuses
  a create, writing nothing, when the shape is missing or unknown or the shape's
  metadata (`--accept`, `--repo`, `--risk`, `--test`) is short; a `chore`,
  `cleanup` or `docs` kind may omit `--shape`. `local_url` comes later, from the
  build.
- **`test-only`** is for a diff that is entirely test code. It has no tiers, but
  it is not the easy option:
  1. It is claimable only on a diff `bin/dor-check` OBSERVES to be 100% `test/`,
     `tests/` or `e2e/`. One non-test file and the claim is refused.
  2. It is **not exempt from the CI gate** (unlike `docs`): the PR's settled green
     CI satisfies it exactly as for a feature, and `bin/fast-check` is only the
     optional pre-flight before it.
  3. It owes a **control**: evidence the changed test **still bites**. Run
     `bin/control-check <task>`. Where it has nothing to replay (an added test,
     or no runner for `e2e/`/`tests/`), re-run it with `--why "<the control you
     ran> → <what failed>"` and it records the `[control]` line, naming the
     diff's files. A `NO-SIGNAL` verdict is **not** a refusal; it stamps only with
     your `--why` sentence (rename, consolidation, …) inside the stamp.
  4. `bin/submit` never runs it. Run it after your last commit (the stamp is bound
     to the tree). It replays the pre-change files in a throwaway worktree, so it
     never writes your desk.

`begin` prints the **worktree path, port, and task URL**. Announce the task line
every session: `<app-slug> · <feature-slug> · <task URL>`.

To resume a held or blocked task instead:

```bash
bin/task begin <slug>              # re-creates/rebinds the desk, preflights, moves to building
```

The desk is the build claim. `begin` refuses only when another live session's
desk is bound to the task with uncommitted changes, and names it. Add `--steal`
only for that case.

**Read the preflight output before writing code.** `begin` runs it on the desk
before the claim, and after the claim it only reports. It prints the latest
feedback, the branch's distance from `accepted`, the PR's merge and check state,
same-file overlap with other PRs, stale terminology in your own changed docs, the
installed entry docs (information: the ship publishes them), and the tiers your
shape owes. `begin` clears a rework block (and records who did); an environment, dependency or
`Escalated:` block stands. Read the feedback first.
Duplicate migration installs are checked by `bin/submit` and the merge gate on the
final diff (mechanism: `bin/lib/migration_collision.rb`): the task that owns an
engine migration keeps its copy, and the other drops it.

## Step 2 — Build in the worktree

Work in the desk `begin` printed, never a primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio/.worktrees/<slug>
```

1. On a fresh desk, set it up first: `bundle install`, `bin/rails db:prepare`.
2. Make the scoped change. Commit early and often; a peer claim can reset a desk
   under uncommitted work.
   After any `db:migrate`, read the whole `git diff db/schema.rb`: the dump can
   carry a sibling's column from a shared database. Keep only your own hunks.
3. If behavior, workflow, env vars, ports, auth, email, deploys, or agent
   operations change, update the **owning active docs in the same pass**.
4. Narrate with `bin/agent-activity`, one activity per unit of work, starting
   with an `Explore`/`Plan` orient before your first tool call.

## Step 3 — Test as you go, unit-first

Write the **test tiers your shape requires** while you build. For a **bug**, write
the failing regression test FIRST, at the lowest tier that reproduces it. Record
them tier-tagged:

```bash
bin/task update <slug> --checks "[unit] ..." --checks "[integration] ..."
```

`--checks` and `--accept` **replace** the list; pass the full set each call. The
other recording traps: [`task-board-api.md`](task-board-api.md#footguns-verified-will-bite-you), footgun 8.

## Step 4 — Decide: does this change earn a LOCAL REVIEW?

Ask: *would Alex want to see this running before it rides the pipeline?*

- **Yes** when the change is **visual, UX, workflow, or copy**: a board card, a
  form, a page, an email, anything he would recognize on sight.
- **No** for a backend or library change with no operator-visible surface. Skip
  to Step 5, and set no `local_url` you will not stand behind.

**If yes**, stand up a live candidate and mark the task waiting-for-approval:

```bash
# 1. Boot the worktree stack (its own DB/Redis/port) so there is a REAL page to open.
bin/agent-worktree up <app> <slug>

# 2. Point the task at the exact page, and flip it to waiting-approval.
bin/task update <slug> \
  --local-url http://localhost:<port>/<path> \
  --approval waiting
```

Mark it waiting only once a **live candidate** answers at that URL.

**Verify the whole HOP, not the page**, with one command from the hub:

```bash
bin/verify-review-hop <slug>
```

It walks the five legs the WAITING APPROVAL button walks: the board CTA → the
local mint → the confirm page → the consume POST → the landing. Exit `0` means
the button lands Alex **on the page under review**, signed in. `--json`
gives a machine-readable verdict. It mints its own token, so it burns nothing you
are about to hand over. Do not mark a task waiting without a green run.

- It reads the CTA from the **production** board by default, because the task
  record lives there. Use `--local-url <url>` when the task is not on the board
  yet; that skips the CTA leg and says so.
- **Every leg fails success-shaped.** A `302` or a final `200` proves nothing: a
  wrong port, a desk with no reviewer, and a non-admin reviewer all end on a
  `200`. The command reads each redirect's *destination*, which is the only
  thing that separates these from a working hop. The CTA path is
  `GET /tasks/<slug>/local_review` (**underscore**; the hyphen is a 404).
- **No `?email=`.** The live CTA sends none, and the desk names its own reviewer
  (`Studio::LocalReviewsController`). On studio-engine ≥ 0.36.0 the engine
  find-or-creates that reviewer as an admin before minting.
- **Below the 0.36.0 floor** the mint answers `MISSING_EMAIL` unless you pass an
  address that is already an admin **in that app**. Do not guess the floor from a
  remembered version: run `bin/verify-review-hop` **without** `--email` first, and
  reach for `--email <address>` only when `MISSING_EMAIL` comes back. Read an
  app's floor from its own lockfile:

  ```bash
  grep -m1 'studio-engine (' Gemfile.lock
  ```

On the board, a `--local-url` + `--approval waiting` task floats to the top of its
stage, pulses, and grows a **WAITING APPROVAL** CTA. Each click mints a FRESH
single-use `Studio::Link` and lands Alex signed in on the local page
(`GET /tasks/:slug/local_review`).

In chat, return the review handoff with exact top-level labels (recipe:
`mcritchie-studio/docs/agents/modules/communication-style.md`):

```text
Task: https://mcritchie.studio/tasks/<slug>
Magic Link: <the magic link line bin/task begin printed, return_to=/<path>>
Local Demo: http://localhost:<port>/<path>
```

Hand over the stack's own MINT URL, never a token minted in a console: a console
mint binds the SHARED development database, and the desk server bounces him to
`/login`. `bin/task begin` prints the mint URL as its `magic link:` line
(`bin/lib/review_hop.rb#mint_url`); set `return_to` to the page. The mint URL is
REUSABLE, since each click mints a fresh token.

For email or auth flows, also return `Local Inbox:
http://localhost:<port>/_studio/local_emails` (desks default to
`LOCAL_EMAIL_CAPTURE=1`).

**Give him the chance to answer, but do not stall.** The request survives
`bin/submit` and keeps pulsing in the review column. **The merge does NOT wait for
him**: the reviewer sees an `OPERATOR APPROVAL STILL WAITING` block with your
latest handoff note, then merges on its own verdict, and the move to `reviewed`
settles the request. So make that note say what he should look at. If his answer
must come BEFORE the merge, tell him directly.

## Step 5 — Pre-flight (optional)

Commit, then run the local pre-flight ([`pre-flight.md`](pre-flight.md)):

```bash
bin/fast-check <slug>          # diff-mapped tests + core spine + rubocop on changed files, ~1 min
```

It records nothing; the PR's settled green CI is the verdict. A red lane here
usually means a red CI later, so fix it first. `bin/submit` runs it for you at step
5/8, after the push and the PR so CI is already running, and carries on whatever
it says.

## Step 6 — Ship to the seam (stops at `submitted`)

A cold ship takes **~12 minutes**, longer than some harnesses allow one foreground
command. So **run it in the background, and wait for it with `bin/submit-wait`**,
naming the fixed-path script and standing in the desk:

```bash
/Users/alex/projects/.agents/bin/submit-wait <task-slug> --launch -m "Commit message"   # start the ship, then block
/Users/alex/projects/.agents/bin/submit-wait <task-slug>                                # attach to one already running
```

The ship commits, pushes, opens the **non-draft** PR into **`accepted`** led by
the task URL, records `pr_url`, runs the pre-flight while CI is already running,
**waits for CI to settle**, runs `bin/dor-check`, and moves the task to
`submitted`. It mints one board token for the run and hands it to every
`bin/task` and `bin/dor-check` call it spawns (`AGENT_API_TOKEN`).

- `/Users/alex/projects/.agents/bin` is the fast-lane tooling at a fixed path that
  no `git checkout` can move. If it is missing, the hub's
  `/Users/alex/projects/mcritchie-studio/bin/submit-wait` runs the same script.
- `bin/submit-wait` exits **0 succeeded · 1 failed · 2 still running at the
  timeout · 3 usage · 4 nothing to watch**. It returns at once when the ship has
  finished, and takes its verdict from the ship's LOG, because `bin/submit` can
  exit 0 on a run that never reached the seam.
- **Do not hand-roll `while pgrep -f "bin/submit <slug>"`.** The pattern also
  matches every SIBLING watcher shell carrying it, so the wait never fires.
- If the wait is cut short, re-run it. If the SHIP is cut short, **re-run
  `bin/submit`**: it resumes and finishes in seconds once CI has settled. A killed
  ship leaves the task in `building`, where the review sweep never looks.
- `--launch` names the log for you, by slug. Redirecting by hand? Use
  `scratchpad/ship-<task-slug>.log`, never a bare `ship.log`: sibling agents share
  one scratchpad ([`worktrees.md`](worktrees.md#the-desk-writer-convention)).
- `bin/dor-check` refuses an under-tested PR; fix what it flags. A red CI stops
  the handoff because dor-check refuses it. A CI run that never appears or never
  finishes reaches the verdict as a WAIT. `SHIP_CI_WAIT=off` disarms the wait.
- Ship refuses a **duplicate migration install** and names both files and the
  other PR. The owning task keeps the copy; re-run and ship resumes.
- The base is always **`accepted`**. `bin/submit` is **not** `bin/release ship`
  (the G4 production deploy).
- Ship has no `--steal`. It refuses only when another live session's desk is
  bound to the task with uncommitted changes; claim over it with
  `bin/task begin <slug> --steal`, then ship.
- Review's gate-zero still holds the **authoritative** CI verdict and bounces a
  red-CI task back with the failing checks named.
- Moving by hand (`bin/task move <slug> submitted`) does **not** wait for CI; the
  wait lives in `bin/submit`.

**Before you launch:** land every change (a push mid-wait restarts CI), probe
with `bin/dor-check <slug> --json` (read-only, no gate attempt), and clear the
[traps the pre-flight cannot see](pre-flight.md#traps-the-pre-flight-cannot-see).

Keep the worktree and branch until review confirms the PR merged or was
abandoned. A pushed branch preserves code; `main` is not a backup.

## Done when

- A production task exists, shaped, with tier-tagged `checks_run` recorded.
- The required test tiers for the shape are written and green.
- The local-review decision was made deliberately: backend-only straight to
  review, OR operator-visible with `--local-url` + `--approval waiting` against a
  **live** candidate and a Magic Link handed off.
- A non-draft PR into `accepted`, led by the task URL, is open; `bin/dor-check`
  passed; the task is on `submitted`.
- Owning active docs were updated in the same pass.

# Building SOP — the feature agent's build flow, task → submitted

You are a **feature agent** (the per-task Pokémon). Your work produces a code
diff, so you run the DevOps **Build** lane: `designed → building → submitted`.
You own the task from the moment you claim it through the `submitted` seam, where
you hand off to review. This module is the standing procedure for that half. It
stands alone — every command is inline.

The one non-mechanical judgment in the whole flow lives in **Step 4**: before you
submit, decide whether the change earns Mr. McRitchie's **local review**, and if
it does, wire the approval CTA so it lands on the board. Everything else is
sequencing.

There is **no size exemption.** "It's just a small change" or "just a copy tweak"
is exactly when this flow gets skipped and a regression ships. A one-line diff is
still a Build-lane task.

## The lanes, so you know where you stop

The code walks a three-rung ladder — **`accepted` → `release` → `main`** — and
the task walks two workflows that meet at `submitted`:

- **Build (you)** — `designed → building → submitted`. You claim, build, test,
  and open a PR into **`accepted`**. You stop at `submitted`.
- **Deploy (DevOps)** — `submitted → reviewed → assembled → shipped`. Carl's
  `pr-review` merges your PR onto `accepted` and moves the task `reviewed`; Avi's
  `qa-release` promotes `accepted → release` for QA; Steffon's `production-deploy`
  fast-forwards `release → main`.

Never merge, deploy, or touch `release`/`main` yourself unless Mr. McRitchie
assigns you that lane in this session.

## Step 1 — Claim: task + worktree + preflight (the fast lane)

One command creates the production task, allocates an isolated worktree on an
allocated port, claims the task (`move building`), and preflights:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Three To Five Words" --repo <app> --kind <kind> \
  --shape <shape> --risk <tags> --accept "criterion" --test "[unit] ..."
```

- **Title = 3-5 words** (the create API rejects otherwise); the slug derives from
  it — the readable `/tasks/<slug>` URL, and it seeds `worktree_slug` +
  `feat/<slug>`. Pass `--slug` only to override.
- **Each `--accept` bullet = 5-12 words.** Verbose detail/reasoning goes in
  `--agent-context "…"` (free-form, agent-to-agent).
- **If you are a SOUL (Carl, Shannon, Jasper, Steffon, Alex), stamp yourself as
  the builder** right after `begin`:

  ```bash
  bin/task move <slug> building --actor <your-soul>
  ```

  It writes `devops.built_by`, which is what keeps you off the review of your own
  PR. It is safe to run on a task **already** at `building` — the stamp rides the
  build CLAIM, not the transition — and re-running it is idempotent. Skip it and
  `bin/reviewer-select` has no builder to exclude, so it **refuses to pick
  reviewers at all** and the review stalls until someone states the fact by hand.
  A delegated subagent runs under the PARENT session id, so this flag is the only
  thing that records the soul who actually built the change.
- **Classify the shape** — it selects the tests you must write
  (`config/feature_shapes.yml`): `ui-only` · `ui+db` · `backend` · `library` ·
  `onchain` · `onchain-vertical` · `docs` · `test-only`.
- **`test-only`** is for a change whose entire content is test code — a deleted
  assertion, a fixed flake, a new diagnostic. It has no tiers because there is no
  behavior for a tier to be evidence of, but it is **not** the easy option: it is
  claimable only on a diff `bin/dor-check` OBSERVES to be 100% `test/`, `tests/`
  or `e2e/` (one non-test file and the claim is refused), it still owes the
  full-suite cert, and it owes a **control** — the evidence that the changed test
  **still bites**. Run `bin/control-check <task>`: it replays the pre-change
  version of the changed test files against current production code and stamps
  the evidence. Where a changed file has no pre-change version (an added test) or
  no runner here (`e2e/`, `tests/`), it stamps nothing and says so — that half is
  yours, as a `[control]` line in `checks_run` naming a file from the diff. A
  `NO-SIGNAL` verdict is **not** a refusal: it means the replay could not tell a
  rename from a deleted assertion, and it asks you for the sentence that can.

`begin` prints the **worktree path, port, and task URL**. Announce the task line
every session — `<app-slug> · <feature-slug> · <task URL>` — so the active
feature is visible in any tool.

Taking over a held or blocked task instead of creating one:

```bash
bin/task begin <slug> --steal      # re-creates/rebinds the desk, moves to building, preflights
```

**Read the preflight output and fix what it flags before writing code** — branch
drift vs `accepted`, latest blocker feedback, same-file PR overlap, generated-doc
drift, stale terminology, required test tiers. (`test_plan` + `local_url` show as
"missing metadata" until you record them; that is expected, not a blocker.)

The long form, when the fast lane does not fit (multi-repo, a task someone else
shaped, a single step to rerun): `bin/task create …` → `bin/agent-worktree new
<app> <slug>` → `bin/agent-worktree bind-task <app> <slug> <task-url>` →
`bin/task move <slug> building` → `bin/session-preflight <slug>`.

## Step 2 — Build in the worktree

Work in the desk `begin` printed — never a primary checkout:

```bash
cd /Users/alex/projects/mcritchie-studio/.worktrees/<slug>
```

Make the scoped change in the correct repo. Prefer a concrete, inspectable
result. If behavior, workflow, env vars, ports, auth, email, deploys, or agent
operations change, update the **owning active docs in the same pass** — leave the
documentation cleaner than you found it.

Narrate your trajectory into activities as you go (`bin/agent-activity`), one per
unit of work, starting with an `Explore`/`Plan` orient activity before your first
tool call.

## Step 3 — Test as you go, unit-first

Write the **test tiers your shape requires** while you build — that is how bugs
get caught before the PR, not after. For a **bug**, write the failing regression
test FIRST, at the lowest tier that reproduces it. Record them tier-tagged:

```bash
bin/task update <slug> --checks "[unit] ..." --checks "[integration] ..."
```

(`--checks` and `--accept` **replace** the list, they do not append — pass the
full set each call.)

## Step 4 — Decide: does this change earn a LOCAL REVIEW?

**This is the one judgment call in the flow. Make it deliberately, before you
submit.**

Ask: *would Mr. McRitchie want to see this running locally before it rides the
pipeline?* Say **yes** when the change is **visual, UX, workflow, or copy** — the
board card, a form, a page layout, an email, a flow he would recognize on sight —
or anything where "looks right in a test" and "looks right to the operator"
diverge. Say **no** for a pure backend/library change with no operator-visible
surface (a job, a decoder, an internal refactor) — those go straight to review.

**If yes**, stand up a live candidate and mark the task waiting-for-approval:

```bash
# 1. Boot the worktree stack (its own DB/Redis/port) so there is a REAL page to open.
bin/agent-worktree up <app> <slug>

# 2. Point the task at the exact page, and flip it to waiting-approval.
bin/task update <slug> \
  --local-url http://localhost:<port>/<path> \
  --approval waiting
```

Flagging waiting-approval only counts once a **live candidate** actually answers
at that URL — do not mark it waiting against a stack that is not up.

**Verify the whole HOP, not the page** — with one command, from the hub:

```bash
bin/verify-review-hop <slug>
```

It walks the five legs the WAITING APPROVAL button walks and asserts each one
before running the next: the board CTA → the local mint → the confirm page →
the consume POST → the landing. Exit `0` means the button lands Mr. McRitchie
**on the page under review**, signed in. Add `--json` for a machine-readable
verdict. It mints its own fresh token, so running it does **not** burn anything
you are about to hand over.

It reads the CTA from the **production** board by default, and that is
deliberate: the task record lives there, not in your worktree's database. Point
the check at `http://localhost:<port>` (via `--board`) and it dead-ends on a
task that stack has never heard of. Use `--local-url <url>` instead when the
task is not on the board yet — that skips the CTA leg and says so, and a skipped
leg is not a passed one.

Run it, and read the verdict. A green run is the evidence; do not mark a task
waiting-for-approval without one.

Why a command and not a curl recipe you retype: **every leg fails
success-shaped**, so the two checks reflex reaches for — "did it `302`?" and
"did it end `200`?" — are both blind. Measured against a live stack:

| What is actually broken | What a status-only check sees |
|---|---|
| `local_url` blank, a QA host, or the wrong port | CTA `302` (back to the task page), then `200` |
| The desk resolves no reviewer at all | mint `302` → `/login`, run ends `/signin 200` |
| Reviewer signed in but not an admin | consume `302`, landing `/` **`200`** |

The first row is the leg that historically broke, and it is the one a recipe
starting at the local mint never touches. `bin/verify-review-hop` starts at the
CTA (`GET /tasks/<slug>/local_review` — **underscore**; the hyphen spelling is a
404) and reads the redirect *destination*, which is the only thing that
separates these from a working hop.

Two rules the command encodes, worth knowing when you read its output:

- **No `?email=`** (at or above the engine floor — see below). The live CTA
  sends none: it is a public URL, so an address there would be published on a
  public page. The desk names its own reviewer:
  `params[:email]`, else `Studio.local_review_email`, else the first admin by id
  (`Studio::LocalReviewsController`). Pinning an email short-circuits that chain
  at priority 1 and verifies a URL the operator never receives, as a user the
  button would never pick.
- **On studio-engine ≥ 0.36.0 you no longer pick an admin address.** The engine
  find-or-creates the reviewer at `Studio.local_review_role` (default `admin`)
  *before* minting, and promotes an existing non-admin, so no identity list
  applies. But provisioning is **best-effort**: it rescues, logs a warning, and
  mints anyway, so a host with an extra `User` validation still lands on `/`.
  That is why the landing assertion, not the engine version, is the gate.

**Check your app's engine floor before you read a green run.** Below 0.36.0
there is no reviewer fallback and no provisioning: the mint answers
`MISSING_EMAIL` unless you pass an address, and that address must already be an
admin **in that app**. `bin/verify-review-hop` says so by name when it hits it,
and takes `--email <address>` for that case — it flags the run as a deviation,
because it is verifying the sub-floor path rather than the button's own. Read
the floor from the app's own `Gemfile.lock`, never from another repo's:

```bash
grep -m1 'studio-engine (' Gemfile.lock
```

As of 2026-08-11 the hub is on 0.38.0 and **turf-monster is on 0.31.0** — so on
turf-monster today this is the sub-floor path, `--email` and all. Do not carry
one repo's identity list to another to choose that address: the same person can
be an admin in the hub and `role: "user"` one repo over. Confirm the address is
an admin in the app you are verifying.

(The command is the check; drive the real browser too when you have one.)

What this buys you on the board: a `--local-url` + `--approval waiting` task
floats to the top of its stage, pulses, and grows a card-width **WAITING
APPROVAL** CTA. That CTA is a **mint-on-click magic link** — each click mints a
FRESH single-use `Studio::Link` to the local page and lands Mr. McRitchie
signed-in on it (`GET /tasks/:slug/local_review`). Minted per click on purpose: a
single-use link is burned on first consume, so a fixed embedded one would go
stale. The plain `local_url` rides along as the card's `data-local-url` fallback.

In chat, return the review handoff with exact top-level labels so Mr. McRitchie
never hunts through prose (full recipe:
`mcritchie-studio/docs/agents/modules/communication-style.md`):

```text
Task: https://mcritchie.studio/tasks/<slug>
Magic Link: http://localhost:<port>/l/<token>
Local Demo: http://localhost:<port>/<path>
```

Mint the `Magic Link:` yourself so it lands on the page under review:

```bash
bin/rails runner 'l = Studio::Link.create_magic_link(email: "alex@mcritchie.studio",
  return_to: "/<path>", ttl: 12.hours); puts "http://localhost:#{ENV.fetch("PORT")}/l/#{l.token}"'
```

**Never click the link you are about to hand over.** This one is a fixed
single-use token — consuming it to "check that it works" burns it, and Mr.
McRitchie receives a dead link. `bin/verify-review-hop` is the check, and it is
safe precisely because the CTA mints a fresh token per click.

For email/auth flows, also return `Local Inbox:
http://localhost:<port>/_studio/local_emails` (worktree stacks default to
`LOCAL_EMAIL_CAPTURE=1`). Then **wait for approval or requested changes** before
opening the PR — this is the point of the step.

**If no**, skip straight to Step 5. Do not set a `local_url` you will not stand
behind.

## Step 5 — Certify (G1)

Commit, then run the builder certification — the task's **G1 Cert** gate:

```bash
bin/fast-check <slug>          # builder default: diff-mapped tests + core spine + rubocop, ~1 min
# or, CI-independent, the full local suite:
bin/full-suite-check <slug>
```

Certify **after your final commit** — the cert is fingerprinted to the git tree,
so an uncommitted change makes it stale. Fix any red before moving on.

## Step 6 — Ship to the seam (stops at `submitted`)

One command commits, certifies, pushes, opens the **non-draft** PR into
**`accepted`** led by the task URL, records `pr_url`, runs `bin/dor-check`, and
moves the task to `submitted` — **without waiting for CI**:

```bash
bin/ship <slug> -m "<commit message>"
```

- The PR base is **`accepted`** — never `release`/`main`. `bin/ship` is **not**
  `bin/release ship` (that is the G4 production deploy).
- `bin/dor-check` refuses an under-tested PR — fix whatever it flags; its verdict
  closes the G1 gate.
- Move to `submitted` **without waiting for CI**: pending CI is a loud suggestion
  (the fast cert is credited provisionally), red CI blocks, and the authoritative
  CI verdict is review's gate-zero — `pr-review` bounces a red-CI task back with
  the failing checks named before any reviewer spawns.
- Re-run `bin/ship` after a failure and it **resumes** (each step already durably
  recorded is skipped). It has no `--steal`; take a held task with `bin/task begin
  <slug> --steal`, then ship.

Keep the worktree and branch until review confirms the PR merged or was
intentionally abandoned. A pushed branch preserves code; `main` is for shipped
integration, not backup.

## Done when

- A production task exists, shaped, with tier-tagged `checks_run` recorded.
- The required test tiers for the shape are written and green under G1 cert.
- The local-review decision was made deliberately: either the change is
  backend-only and went straight to review, OR it is operator-visible and shipped
  with `--local-url` + `--approval waiting` against a **live** candidate, handed
  off with a Magic Link, and cleared by Mr. McRitchie.
- A non-draft PR into `accepted`, led by the task URL, is open; `bin/dor-check`
  passed; the task is on `submitted`.
- Owning active docs were updated in the same pass for any behavior/workflow
  change.

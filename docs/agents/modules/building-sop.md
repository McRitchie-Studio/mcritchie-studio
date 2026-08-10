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
- **Classify the shape** — it selects the tests you must write
  (`config/feature_shapes.yml`): `ui-only` · `ui+db` · `backend` · `library` ·
  `onchain` · `onchain-vertical`.

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

**Verify the whole HOP, not the page.** A plain `curl /admin/<page>` returning
`302` proves only that the logged-out gate works — it is **not** evidence the
button lands. Walk what the CTA actually does (mint → confirm → POST consume →
follow) and assert the final `url_effective` **is the review path** and answered
`200`:

```bash
JAR=$(mktemp)
MINT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' \
  "http://localhost:<port>/_studio/local_review?email=alex%40mcritchie.studio&return_to=%2F<path>")
TOK=$(curl -s -c $JAR -b $JAR "$MINT" | ruby -e 'print $stdin.read[/name="authenticity_token"[^>]*value="([^"]+)"/,1]')
NEXT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$MINT" --data-urlencode "authenticity_token=$TOK")
curl -s -c $JAR -b $JAR -L -o /dev/null -w '%{url_effective} %{http_code}\n' "$NEXT"
```

Mint for a **seeded admin** — one of `User::PARKED_IDENTITIES`, all
`@mcritchie.studio`. Any other address signs up a brand-new `viewer`, and the
hop then fails on a page that is perfectly healthy.

Landing on `/` means the sign-in **succeeded** and the reviewer lacks rights —
the quiet failure, not a broken link. Follow the POST by hand as above: `curl -L`
replays the POST across the redirect and 404s on the review path, which looks
like a different bug. (`curl` is the fallback; drive the real browser when you
have one.)

What this buys you on the board: a `--local-url` + `--approval waiting` task
floats to the top of its stage, pulses, and grows a card-width **WAITING
APPROVAL** CTA. That CTA is a **mint-on-click magic link** — each click mints a
FRESH single-use `Studio::Link` to the local page and lands Mr. McRitchie
signed-in on it (`GET /tasks/:slug/local-review`). Minted per click on purpose: a
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

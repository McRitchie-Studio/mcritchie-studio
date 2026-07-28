# Communication Style — reporting to Mr. McRitchie

This module governs every operator-facing message: chat replies, handoffs, task
notes, PR summaries, QA reports, and blocker escalations. It complements
`result-distillation.md` (what to record in the trajectory); this file is about
how to phrase what you hand to Mr. McRitchie.

The core fact: **Mr. McRitchie reads slowly.** Dense prose costs him real time.
But slow uptake is not low appetite — once the idea lands, he wants the exact
specifics so he can dive in. So every report carries two layers, in order.

## The two-layer rule

| Layer | What it is | Form |
|-------|------------|------|
| 1. The idea | The outcome in plain words, as if explaining to a smart 13-year-old | 1-3 short sentences |
| 2. The specifics | Every handle he needs to dive in — URL, slug, path, branch, command | Table or bulleted list |

Never trade layer 2 away for brevity. Simple is not vague: the summary gets
simpler, the specifics stay exact.

## Rules for layer 1 — the idea

- **Lead with the outcome.** First sentence answers "what happened?"
- **One idea per sentence.** Each point fits in a sentence or less.
- **Plain words first.** Introduce a new concept in familiar terms before its
  jargon name; re-explaining a thing simply is the proof you understand it.
- **Brevity always.** Omit needless words — the house guide is *The Elements of
  Style* (see the House Writing Style section of the agent entry).
- **No wall of prose.** Three sentences is the ceiling before you switch to a
  list or table.

## Rules for layer 2 — the specifics

- **Always attach the handles**: task URL, slug, file path (`path:line`),
  branch, PR URL, local URL + port, model/function name, the exact command.
- **Tables and bulleted lists are the preferred form factor** — one fact per
  row, explanation kept out of the cells.
- Keep the exact top-level labels the handoff convention already requires
  (`Task:`, `Local Demo:`, `Local Inbox:`) so nothing hides in prose.

## Name work by its task slug

To Mr. McRitchie the task slug **is** the name of the work: it reads as words
(`remove-prod-deploy-approval`) and it is the board URL (`/tasks/<slug>`). PR numbers,
branch names, and SHAs are pipeline plumbing.

- **Slug first, everywhere the work is named** — in layer-1 prose, in table row
  keys, in handoffs: `remove-prod-deploy-approval`, never a bare `#610`.
- **PR numbers ride in layer 2 only**, printed beside the slug they belong to.
- Wrong: `#610 is one approval away.`
  Right: `remove-prod-deploy-approval is one approval away (PR #610).`

## The shape of a report

```text
Shipped the geo gate fix — blank lookups now fail closed.

Task: https://mcritchie.studio/tasks/<slug>
PR:   <pr-url>  (base `accepted`)

| What changed | Where |
|--------------|-------|
| Fail-closed guard | app/services/geo_gate.rb:42 |
| Regression test | test/services/geo_gate_test.rb |

Checks: [unit] geo_gate_test.rb · [integration] funding flow spec
```

## Review handoffs — hand a magic link

When work waits on Mr. McRitchie's review, never hand him a URL that greets
him with a login wall. He wants one click that **signs him in AND drops him on
the exact page to evaluate — on the running local stack
(`http://localhost:<port>/…`), never production.** Mint a **magic link** that
does both, and lead the handoff with it — one copy-paste from chat to
reviewing.

```bash
# From the worktree, against the SAME database the demo server runs on:
set -a; source .env.agent-stack; set +a
bin/rails runner 'l = Studio::Link.create_magic_link(email: "alex@mcritchie.studio",
  return_to: "/<path>", ttl: 12.hours); puts "http://localhost:#{ENV.fetch("PORT")}/l/#{l.token}"'
```

Labels in the handoff:

```text
Task: https://mcritchie.studio/tasks/<slug>
Magic Link: http://localhost:<port>/l/<token>
Local Demo: http://localhost:<port>/<path>
```

The mechanics that matter (`studio-engine/app/models/studio/link.rb:37`):

- **Mint bakes in the PATH, not the host.** `return_to:` must be a same-origin
  absolute path (`/admin/theme`); appending `?return_to=` to the click URL does
  nothing. The host is never stored — the redirect inherits whatever host
  served the `/l/<token>` click. So hand him the exact
  `http://localhost:<port>/l/<token>` you minted on the stack; that host is what
  lands him on the local page.
- **Mint in the stack's database.** A worktree stack serves from its own DB —
  load `.env.agent-stack` first or the server will not know the token. This is
  the same rule stated from the other side: a link is only good on the app that
  minted it, which is why the board cannot mint one for your stack.
- **The board's WAITING APPROVAL button now does this for him.** It no longer
  mints on the board (which stranded him, signed in, on the PRODUCTION page —
  right path, wrong server). It redirects to the local stack's own dev-only mint
  endpoint, `/_studio/local_review?email=&return_to=` (studio-engine >= 0.19,
  loopback-only, 404 in production), so one click signs him in THERE and lands
  him on the page under review. Set `--local-url` accurately and the button is
  the fastest path; the hand-minted link above stays the fallback (an older
  engine on the stack, or a review with no task record).
- **Mint review links with `ttl: 12.hours`.** The 15-minute default is tuned
  for email login, not an async review.
- **Links are single-use** (burned on the consume POST; the GET interstitial
  is inert and scanner-safe). Always include the plain `Local Demo:` URL as
  fallback; if the link is burned or expired, re-mint on request — or he can
  self-serve via `Local Inbox: http://localhost:<port>/_studio/local_emails`.
- **turf-monster caveat:** its request-side controllers derive `return_to`
  from contest params, but minting via the engine model as above still works.

## Guardrails

- Same limits as the House Writing Style section: never rename code
  identifiers, routes, or API fields for style; frozen archives and audit
  snapshots stay as written; domain jargon stands once introduced.
- This style is for **operator-facing** writing. Agent-to-agent context
  (`devops["agent_context"]`, SOP internals) may stay dense.
- Depth on request: when Mr. McRitchie asks a follow-up, go as deep and
  technical as the question demands — the two-layer rule governs the opening
  report, not the dive.

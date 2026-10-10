# Agent sessions and capability APIs — design

**Status: decided; phase two in progress.** Piece 3b of the
`platform-audit-refactors` epic. Sections 1 to 7 state the model: what the code
enforces, and what is decided and not built. Section 8 lists the remaining steps
by task slug; section 9 holds the questions Alex has not answered.
How a soul logs in: [`../modules/credentials.md`](../modules/credentials.md#how-a-soul-logs-in-to-the-board).

The page reads the code on `accepted`. The shared secret retires in two stages
(section 8). Stage A is built: a session is the normal path, the shared token is
still accepted, and each use of it is counted. Stage B, which refuses it, waits
for that count to read zero in production.

The idea in one paragraph: credentials move behind deterministic server APIs, and
the platform has **agent sessions**. An agent logs in as a soul when it claims a
task, and the session carries one variable, the logged-in agent. The server
performs every privileged act (deploy, send, mint, rotate) and hands back a
receipt, so no secret enters a model's context. A studio login is bound to a task
and expires. The Pokémon is the logged-out state, and stays as flavour when a
soul is logged in. Sessions, the board gates and two session-only endpoints are
built; the capability endpoints of section 4 are mostly not.

## 1. Today, read from the code

| Surface | What it does | Where |
|---|---|---|
| Hub API login | Two bearers. An agent session's token names one row, read on every call: a login, a machine's harness key or a client runtime key (section 2). The shared `AGENT_API_SECRET` still exchanges for a 24-hour token whose payload carries no soul, no task and no scope; it passes every gate except the session-only ones, and each use is logged and counted as legacy. `bin/task`, `bin/dor-check` and `bin/agent-activity` carry it wherever no session applies | `app/controllers/api/v1/base_controller.rb#authenticate_api!`, `app/controllers/api/v1/auth_controller.rb#create`, `bin/lib/agent_api.rb#token` |
| Legacy-use census | Every request the shared token authenticates, and every exchange of the secret, adds one to a counter kept per day, endpoint and caller. The caller is the script the request names in `X-Agent-Caller`, or `unlabelled`. The table holds no token. `bin/rails agent_auth:legacy_census` prints it | `app/models/legacy_auth_use.rb`, `lib/tasks/agent_auth.rake` |
| Actor on board writes | The session's soul when a session is present; the `actor` or `by` param is ignored. Under the shared token the param is recorded as sent | `app/controllers/concerns/api/agent_session_gate.rb#session_actor` |
| Session-only endpoints | The facts API takes an agent session and answers the shared token 401. The TikTok draft create and the `ship_authorized` step of the release events API each take an admin session and answer anything else 403 | `app/controllers/api/v1/facts_controller.rb#require_agent_session!`, `app/controllers/concerns/api/agent_session_gate.rb#require_admin_session_only!` |
| Turf Monster production | Calls two hub endpoints: `Studio::PushGameRecap` (`POST /api/v1/game_recaps`) and `Studio::SyncAthletes` (`GET /api/v1/athletes`). Each presents `STUDIO_RUNTIME_KEY`, Turf's own client key, when that is set, and exchanges `AGENT_API_SECRET` while it is not. Turf's config holds the shared secret until Steffon swaps it (section 8) | `turf-monster/app/services/studio/` |
| Heartbeat attribution | `bin/agent-activity heartbeat <soul>` writes a sticky `.acting-agent` marker beside the session marker; every activity attributes to that soul until `--clear` or session end. Local, unverified. For Steffon and Xan the same command also asks for the admin login (section 3) | `bin/atomic-event#heartbeat` |
| GitHub tokens | `bin/gh-app-mint-token` mints a GitHub App installation token: one-hour expiry (GitHub's), scoped by App identity (`github.mcritchie-agent` builds and reviews; `github.mcritchie-admin` ships, no pull-request scope), every repo of the installation. The admin item is in the admin vault, unreadable from the agent token. `bin/gh-app-git-credential` hands the token to git, so it reaches the shell and not the transcript | `bin/gh-app-mint-token`, `bin/gh-token#IDENTITIES` |
| 1Password reads | Two lanes: the agent vault `studio-agents` through `OP_SERVICE_ACCOUNT_TOKEN` in every shell; the admin vault `studio-agents-admin` through `~/.zprofile.admin`, opt-in. Every `op` read is metered to `.agents/op-reads.log` (caller, action, context) and queried by `bin/op-reads` | `bin/secret`, `bin/lib/op_meter.rb`, [`../modules/credentials.md`](../modules/credentials.md) |
| Operator windows | Four windows in `config/release_builder.yml#operator_windows` (approval 10 minutes, escalation 20, production 30, admin login 10), read by `Devops::Windows`. The production one is a grant: the ship posts a `ship_authorization` request and Alex taps Approve on `/deployments`, or `bin/release ship --mode cleared` records his chat clearance with no window | `app/controllers/releases_controller.rb#authorize_ship` |
| Client-facing runtime | Tyrion: an isolated NUC, outbound only, a model with no tools, a 280-character output filter, a capped model key, a per-account bot token stored as a digest | [`../agents/tyrion/runtime.md`](../agents/tyrion/runtime.md) |

What the shape means: the shared token proves a caller holds the secret, never
who the caller is, and it sits in every agent shell's env and in Turf's production
config. A session names its soul and its task, and the server ends it. While both
bearers are accepted, a session narrows the caller that presents it, and the
shared token still passes every gate that is not session-only. The census is how
the operator sees when nothing presents it any more.

## 2. The session record and its token

A session is one row the server owns (`AgentSession`):

| Field | Value |
|---|---|
| `slug` | Server-issued, `sess-…`; the only thing the token carries |
| `soul` | A slug from `Task::SOUL_ROSTER`; `pokemon` for a builder |
| `tier` | `admin`, `studio`, `client` or `harness`. The soul caps it, and nothing changes a row's tier, soul or scope after create |
| `task_slug` | The scope. Required for studio: one task. Always null for admin, because the tier is the scope |
| `issued_by` | How the login was granted, one of `AgentSession::ISSUERS`: `task_claim`, `review_claim`, `operator_grant`, `launch_phrase`, `runtime_key` |
| `harness_session_id` | The Claude or Codex session that asked. Asserted by the caller, so it proves nothing by itself |
| `label` | On a key only: the machine a harness key belongs to, or the runtime a client key belongs to |
| `issued_at`, `expires_at` | Expiry from `AgentSession::TTL`: studio 24 hours, admin 8 hours, client 24 hours. A key (a harness key, a client runtime key) carries an expiry a century out, which is none in effect: the operator revokes it |
| `revoked_at`, `revoked_by` | Revocation is immediate: the server reads the row on every call |

The token is a signed message carrying only the session's slug, under its own
purpose, so a shared-secret token cannot be replayed as a session. It expires with
the row; the message's own expiry is a day later as a backstop. A session cannot
mint a session: every login is presented with the machine key (section 3).

| Tier | Souls | Reaches |
|---|---|---|
| **Admin** | Steffon, Xan (`AgentSession::ADMIN_SOULS`) | Any task, release writes, conductor lanes, agent updates, slug renames, sensitive facts, the TikTok draft. An admin soul may also hold a studio session, which narrows it |
| **Studio** | Every other soul that is not a client: Carl, Jasper, Avi, Shannon, Rex, Mack, Mason and the Pokémon builders | Board writes for the one task held, and ordinary facts |
| **Client** | Turf Monster, Tyrion (`AgentSession::CLIENT_SOULS`) | A runtime key reaches the endpoints `AgentSession::CLIENT_ENDPOINTS` lists for its soul and answers 403 everywhere else, naming them. Turf Monster: `GET /api/v1/athletes` and `POST /api/v1/game_recaps`. Tyrion: none |
| **Harness** | None: a harness key belongs to a machine and is held as `pokemon` | The doors that mint a login (`accepts_harness_key`): the studio login, a review claim, a login request, and `GET /api/v1/agent_sessions/current`. Every other endpoint answers 403. It never becomes the session a request acts as, so it names no actor |

A caller with no session is **the Pokémon**: it reads the board and the docs, and
it narrates as its mascot. Under the shared token it can still write; the decided
end state is that every board write needs a login (section 8).

## 3. How a login is granted

A soul cannot hold a password: anything in its context is readable by whatever it
reads. So every grant comes from outside the model. The **machine key** is the
credential a script reads from a file or its env and the model never sees: the
machine's **harness key** when the operator has granted one, and the shared
secret's token otherwise.

| Tier | Granted by | What the agent presents | Scope | Expires |
|---|---|---|---|---|
| Studio, builder | The task claim: `bin/task begin` logs the desk in (`POST /api/v1/agent_sessions`). The task must be `building`, and the soul must be one the claim recorded as its builder; any other soul answers 403 | The machine key | The task | When the task leaves `building` and `submitted`, or after 24 hours |
| Studio, reviewer | The review claim: `bin/task claim-next-review` and `review-claim acquire`. The mint sits inside the claim's lock. The soul must be in the reviewer pool and outside the task's author set | The machine key | The claimed task | When the task leaves `submitted`, when the claim lapses, is released or changes hands, or after 24 hours |
| Admin | The one-time code the board shows on the request, carried in Alex's launch phrase, or an Approve tap on the board, inside the `admin_login` window of `Devops::Windows`. The session asks; the server posts the request; a lapse grants nothing | The machine key, plus the request id and its collect key | None: the admin tier is the scope | Eight hours, or the harness session's end |
| Admin, from a hub shell | `bin/rails agent_sessions:grant_admin`: a shell on the hub can already write the database, so the shell is the grant. It runs outside the board: no request, no code, no tap and no window, and the row records `operator_grant`, the value an Approve tap writes | Nothing; the token prints on stdout for `AGENT_ADMIN_SESSION_TOKEN` | None | One to eight whole hours |
| Harness key | A login request of kind `harness_key` (`bin/harness-key request`), which the operator grants once per machine with the same one-time code or Approve tap, inside the same window. The row on the board reads `Harness key · <machine>` | The machine key (the shared token on a machine with no key; a held key for a rotation), plus the request id and its collect key | The mint doors only | None in effect; `bin/rails agent_sessions:revoke SLUG=<sess-…>` ends it at once |
| Client, a sibling app's two endpoints | `bin/rails agent_sessions:grant_runtime_key SOUL=turf-monster LABEL=<runtime>` from a hub shell. Stdout is the key and nothing else | Nothing; the key goes into the runtime's config (`STUDIO_RUNTIME_KEY` on Turf Monster) | `AgentSession::CLIENT_ENDPOINTS` for the soul | None in effect; revoked by slug |
| Client, an outward-facing runtime | Not built. Decided: only from the isolated runtime, with a runtime-bound key stored as a digest and shown once, as Tyrion's bot token is | The runtime key, from the runtime's own env | The runtime's channel (first case: Turf Monster's TikTok DMs) | The key's |

**The admin request has two grants the server verifies** (`AgentLoginRequest`).
`bin/agent-activity heartbeat steffon|xan` posts the request and prints its
server-issued `login-…` slug. The board shows an admin each open request by that
slug, because the soul and the harness session id on a row are whatever the
poster sent.

- **The one-time code.** The row shows a code derived from the request; the table
  holds its digest. Alex puts the code in his launch phrase and the agent posts
  it back (`heartbeat <soul> --code <code>`), with no tap. One grant spends the
  code, and the fifth wrong code refuses the request. A phrase with no code is
  words in a context and grants nothing.
- **The Approve tap** on the same row. Decline refuses the request.

A request is replaced only by a post that presents its collect key; any other
post under the same harness session id answers 409. A soul gets three requests
inside one ten-minute window, then 429; a Decline frees its slot. No API response
carries the code. The harness that asked collects the granted token once and
keeps it in a file named for its harness session id, owner-only; a lapsed or
refused request mints nothing and its collect answers 410.

**The harness key** is kept in `<projects>/.agents/harness-key.json`, owner-only
(`bin/lib/harness_key.rb`), and no command prints it: `bin/harness-key status`
reports its slug, its machine and its length. `bin/task begin` and a review claim
present it to mint the login, and fall back to the shared token when the machine
holds no key or the board answers the key 401. `bin/rails agent_sessions:keys`
lists every harness key and runtime key without a value.

**Which login a command presents.** `bin/task` presents the review login or the
desk's login on a write to that task. With `TASK_AS_ADMIN=1` it presents the
admin login on every call and stops, with the way to log in, when none is held
or the board ends it: there is no fallback. The admin login is asked for and
never assumed. `bin/agent-activity` presents a held login only when its soul is
the lane the call declares, so a login never restamps another agent's narration.
The capture hook, `bin/session-insights` and the release conductor's claim
present a held login (the conductor's claim, the admin one), because an action
records the `agent` lane and never a soul. Each falls back to the shared token
only when the board answers the login 401 (`bin/lib/held_session.rb`,
`AgentApi.call`).

**The degraded mode.** `AGENT_LEGACY_TOKEN=off` stops the narration stack, the
hooks and the claim CLIs reading or minting the shared token. A call with a login
is made under it; a call with none is not made. Nothing is recorded, and no actor
is declared under a credential that names nobody. It is off by default while the
shared token is accepted, and it is how one machine rehearses Stage B.

Where a login is kept: a desk's builder login sits in `agent-session.json` inside
the desk's git directory, and a reviewer's sits one file per claimed task under
`agent-review-sessions/` in the git directory of the checkout the claim ran in
(`bin/lib/desk_session.rb#REVIEW_DIR`). Only the harness session that logged in
presents either.

## 4. Capability endpoints

The server performs the act and returns a receipt. The capability's secret (the
GitHub App PEM, the Heroku key, the mailbox grant, the vault token) is to live on
the server and in `studio-applications`, never in a shell or a context. The tier
columns are the decided matrix; **Built** says whether a session reaches it today.

| Capability | Server-side act | Logged out | Client | Studio | Admin | Built |
|---|---|---|---|---|---|---|
| Read the board and docs | None | yes | no | yes | yes | yes |
| Narrate (activities) | Attributes to the mascot, and to the soul when logged in | yes | no | yes | yes | yes |
| Claim a task | Mints a studio session (section 3), presented with the harness key or the shared token | yes, and it logs in | no | yes | yes | yes |
| A sibling app's own endpoints | Turf Monster's athletes read and game recap post | no | its own two | yes | yes | yes |
| Write the task held | Stage move, checks, notes, local-url | no | no | own task | any task | yes; the shared token still writes |
| Read and write facts | Encrypted records; a sensitive fact needs admin | no | no | ordinary | all | yes |
| Draft to TikTok | Queues the upload to the operator's drafts | no | no | no | yes | yes |
| Release writes | Release events and notes, conductor claims, shifts | no | no | no | yes | gated; the conductor's claim presents the admin login when one is held |
| Mint a GitHub token | Calls the App's access-tokens endpoint with `repositories: [<the task's repo>]`, which `bin/gh-app-mint-token` does not pass; hands the one-hour token to the git credential helper | no | no | agent App, the task's repo | admin App | no |
| QA and production deploy | Runs the deploy; files the receipt and the grant it ran under | no | no | no | yes | no |
| Send mail | Sends from `<soul>@mcritchie.studio` through the hub's mailer; logs the send | no | no | yes | yes | no |
| Read a credential's metadata | Name, vault, consumer, last rotation; never the value | no | no | yes | yes | no |
| Read a credential's value | A break-glass event (section 7) | no | no | no | yes | no |
| Rotate a credential, change DNS or Heroku config | Runs the step; files the receipt | no | no | no | yes | no |
| Reply to an outsider | Through the runtime's filter and spend cap | no | yes | no | no | no |

## 5. What the server enforces, and what the board shows

On every call with a session: the session is live, the tier covers the endpoint,
the scope covers the task, the checked transitions are legal for the session, and
the actor is the session's soul. A session that has ended answers 401
`SESSION_ENDED` with the reason: revoked, expired, a studio session whose task
left `building` and `submitted`, or a reviewer's session whose claim is not live.
A tier, scope or transition refusal answers 403 `SESSION_FORBIDDEN` with the
reason (`Api::AgentSessionGate`). A call under the shared token carries no
session and passes these gates. A harness key carries no session either, and
reaches only the mint doors.

| Transition | Who may make it under a session | Checked |
|---|---|---|
| `designed` to `building` | Studio, by claiming | The claim mints the session |
| `building` to `submitted` | Studio, the session that holds the task | By scope: a session writes only its own task |
| `designed`, `building` or `submitted` to `reviewed`; `submitted` to blocked | A reviewer's session, or an admin's, whose soul is outside the task's author set | yes |
| Any stage to `archived` | Admin. `bin/task` never offers the desk's studio login on this move; `TASK_AS_ADMIN=1` presents the admin login | yes |
| `reviewed` to `assembled`, `assembled` to `shipped` | Decided: admin, under a grant | no |

The check runs where a stage is written: the task update and block
(`app/controllers/api/v1/tasks_controller.rb#require_transition_tier!`) and the
stage events' complete and fail
(`app/controllers/api/v1/task_events_controller.rb#require_transition_tier!`),
both through `AgentSession#transition_refusal`.

The task API returns the newest studio session on the task that is live
(`AgentSession#live?`). The board card shows that session's soul on the corner
of its crew row, beside the mascot, with the login (builder or reviewer) in the
tooltip; logged out, the Pokémon stands alone. Both boards, the epic page and
the live stream draw the one `TaskCardComponent`, which reads a page of sessions
in one batch (`AgentSession.live_by_task`, pinned to `#live?` by test). Only a
studio session names a task, so an admin, client or harness session reaches no
card. The card does not show the tier or the expiry, and the sticky heartbeat
marker still attributes activities.

## 6. Prompt-injection containment

- **A studio login is bound to its task and expires.** Content read during a task
  can at most spend that task's writes, for that task's life.
- **Tier is set at login and never raised.** The soul caps the tier, a session
  cannot mint a session, a client key reaches only its own endpoints, and a
  harness key mints studio logins and nothing higher. Those endpoints check the
  row, not the prose.
- **A harness key can log in only where the task record allows.** It mints the
  login of a builder the claim recorded, or of a reviewer the task names who did
  not build it. Any process on the machine can read the key, so it is worth
  exactly that: the logins this machine's tasks already entitle.
- **Content from outside the platform is data.** Web pages, mail bodies, DMs and
  comments from non-members are never instructions. The guard is structural: the
  server reads the session, not the message.
- **The client tier holds nothing.** Tyrion's threat table applies as written
  ([`../agents/tyrion/runtime.md`](../agents/tyrion/runtime.md#the-threat-model)):
  no keys in the prompt, an output filter that drops any line carrying the
  runtime's own secrets or a URL, a capped model key, and three revocable things
  on the machine.
- **What this does not stop:** a studio session talked into a bad commit inside
  its own task. Review is the guard there, and the author set keeps the session
  off its own review. And while the shared token is accepted, anything that can
  read a shell's env can write as any actor it names.

## 7. 1Password direct reads: admin-only, break-glass

Every shell reads `studio-agents` directly. The decided end state: a studio
session reaches a credential only through a capability, so the agent vault token
leaves the default shell profile. An admin session may still run `op read`, and
each read is a break-glass event: the metered row in `op-reads.log` stays, and the
server files who, which item, which session and why, on a page Alex can read.
1Password remains the fallback when the server is down: the fresh-machine rebuild
and a ship recovery read it as they do now. None of this section is built.

## 8. The remaining steps, by task

| Step | Task | State |
|---|---|---|
| The session table, the studio login at `bin/task begin`, the actor from the session, the tier and scope gates, the shared token kept beside them | `agent-sessions-phase-one` | shipped |
| The gates on the board writes phase one left open: shifts, agent updates and the remaining actor sinks | `gate-remaining-board-writes` | shipped |
| A review claim logs the reviewer in; the verdict and `archived` transitions are checked | `agent-sessions-review-login` | shipped |
| The admin-only TikTok draft create and the hub-shell grant | `tiktok-draft-hardening` | shipped |
| The admin login request and its two grants | `agent-sessions-admin-grant` | shipped |
| The facts API, session-only | `facts-primitive-and-endpoints` | shipped |
| **Stage A of the shared secret's retirement**: the harness key, Turf's runtime key, hooks and the conductor's claim presenting a login, `bin/task` acting as an admin when asked, and the legacy-use census. The shared token is still accepted everywhere it was | `retire-shared-secret-fallback` | built |
| **Stage B**: the shared token stops writing (the list below) | none filed; it is filed when the census reads zero | waits on the census |
| The soul on the board card; the tier and the expiry are on no card | `task-card-becomes-component` | built |
| The checks on `reviewed` to `assembled` and `assembled` to `shipped`; the capability endpoints of section 4 marked not built; break-glass logging (section 7) | none filed | |
| One leases table for review, release and shift claims (epic piece 5e) | none filed | |
| The client runtime for an outward-facing channel, Turf Monster's TikTok DMs first (epic piece 3f) | none filed | |

### Before Stage B: what the operator does

1. **Grant each machine its harness key.** On the machine: `bin/harness-key
   request`, then the Approve tap or `bin/harness-key collect --code <code>`.
   `bin/harness-key status` confirms the board accepts it.
2. **Swap Turf Monster's credential** (Steffon, the `credential-rotation` SOP).
   Mint the key on the hub with `bin/rails agent_sessions:grant_runtime_key
   SOUL=turf-monster LABEL=<runtime>`, taking stdout straight into Turf's config as
   `STUDIO_RUNTIME_KEY` without reading it, once for production and once for QA.
   Turf then presents the key and stops exchanging the secret; a refused key fails
   the call and never falls back.
3. **Read the census on production**: `bin/rails agent_auth:legacy_census
   DAYS=<n>`. Each line names an endpoint and the script that called it, and a
   line marked `*` is a use outside the mint doors. The gate is its first line
   reading `0 outside the mint doors` for the period Alex chooses.

A machine can rehearse Stage B alone with `AGENT_LEGACY_TOKEN=off` (section 3).

### Stage B: the exact changes

Stage B ships only after the census reads zero outside the mint doors on
production for the period Alex chooses. Each line names the code it changes.

1. **The shared token answers 401 outside the mint doors.**
   `Api::V1::BaseController#authenticate_legacy_token!` refuses every action that
   is not in `LegacyAuthUse::MINT_DOORS`, with a reason that names the login:
   `bin/task begin` for a builder, a review claim for a reviewer, `bin/agent-activity
   heartbeat steffon|xan` for an admin. Test:
   `test_legacy_token_on_write_answers_401_naming_login`, with the control that a
   mint door still answers it.
2. **`bin/task` loses its fallbacks.** `bin/task#api` no longer retries a refused
   desk or review login on the shared token, and no longer re-mints a refused
   `AGENT_API_TOKEN`; `bin/submit` hands its children the desk's login instead of
   a shared bearer. `bin/task#token` is read only by `mint_request`.
   `git grep -n 'shared token' -- bin/task` finds nothing.
3. **No board write path accepts a self-declared actor.**
   `Api::AgentSessionGate#session_actor` returns the session's soul and never the
   param, and the `actor`, `by` and `agent` params leave the permit lists. Test:
   every API controller inherits the gate, and a grep finds no actor param reader.
4. **The narration stack loses the shared token.** `AgentApi#token`, its disk
   cache and `LEGACY_ENV` go; the degraded mode of section 3 is the only mode for
   a call with no login.
5. **Every other CLI with its own secret chain presents a login or reads only**:
   `bin/dor-check`, `bin/reviewer-select`, `bin/session-preflight`,
   `bin/devops-cycle`, `bin/devops-reconcile`, `bin/devops-shift`,
   `bin/agent-worktree` (the desk ledger), the review claim's renew and release,
   `bin/fact`, `bin/digest-video`, `bin/clip-references`. The census names each
   that still calls, by script.
6. **Turf Monster drops the secret.** Steffon removes `AGENT_API_SECRET` from
   Turf's production and QA config, and a Turf PR removes the exchange branch
   from `Studio::HubCredential` and its two callers.
7. **The secret leaves the agent shells.** `AGENT_API_SECRET` comes out of the
   repo `.env` files and the default shell; it stays in 1Password for the mint
   doors on a machine with no harness key, and is rotated.

Stage B needs five answers first: section 9, questions 2 to 6.

### One identity per spawned agent: specified, not built

An orchestrator, the builder, the reviewer and the light it spawns share one
harness session id, and every file that keeps a login is read by that id. So a
login one of them holds is readable by the others:

- any of them writing to a claimed task from the checkout that holds the review
  login writes as the claiming reviewer;
- all of them share the admin login.

Under the shared token this changes nothing, because that token already passes
every gate. Once it stops writing, it is a self-review hole and an escalation
hole, so Stage B closes it first.

The key is something a spawned agent does not inherit. A spawned agent inherits
its parent's environment, working tree and files; it does not inherit its
parent's context. So each login gets a **seat**:

- The command that mints a login (`bin/task begin`, a review claim,
  `heartbeat steffon|xan`) draws a random seat, keeps the login in a file named
  for the seat's digest, and prints the seat once, to the agent that ran it.
- A command presents the login only when the agent names the seat
  (`AGENT_SEAT=<seat>` on the command). The seat is a selector, not a
  credential: without the machine's file it opens nothing.
- A spawned agent that needs a login asks for its own. The harness key mints it,
  and the server's entitlement rules (section 3) decide whether that soul may
  hold it; the parent's seat is not in the child's context.
- The server refuses a verdict from a login whose seat minted the build login
  of the same task.

Stage A keeps this from getting worse in three ways. No command presents the
admin login unasked (`TASK_AS_ADMIN=1`). Narration presents a login only to the
lane that holds it. `ReviewClaimCli#release` forgets a review login only for the
harness session that kept it.

### What the earlier reviews found, and where each stands

| Finding | State |
|---|---|
| Agents of one harness share a review login and the admin login | Specified above, for Alex to rule on; not built. Stage A does not widen it |
| `bin/task` could not present an admin session, so `archived` had no command-line path under sessions | Built: `TASK_AS_ADMIN=1 bin/task move <slug> archived` |
| A builder's session cannot archive its own task | By rule: `archived` is an admin transition. `bin/task` does not offer the studio login on that move, so today it rides the shared token; in Stage B it takes an admin login |
| A reviewer who fix-forwards becomes an author and gets 403 on the move to `reviewed` | By rule: an author does not pass the verdict. Today: release the claim, then make the move on the shared token. Under sessions: release the claim, and a reviewer outside the author set claims and moves, or an admin outside it runs `TASK_AS_ADMIN=1 bin/task move <slug> reviewed` |
| `ReviewClaimCli#release` deleted the kept review login without checking who owned it | Built: only the harness session that kept it forgets it |
| The task API's `agent_session` picked the newest unrevoked session without asking whether it was live | Built: it names the newest session that is live |

## 9. Open questions for Alex

Answered: `POST /api/v1/auth` stays, as the credential that mints a login and
nothing else once Stage B ships. The hub-shell grant
(`bin/rails agent_sessions:grant_admin`) stays as the path for when the board
cannot grant; the TikTok draft SOP uses the board's grant.

1. **Does Avi get admin for `arbitrate-block`?** His ruling writes a task he does
   not hold. Proposed: no; a studio session scoped to the contested task by the
   arbitration request, which keeps the admin tier to the two souls named.
2. **Who runs `qa-release` under sessions?** A conductor claim is an admin write
   and Avi holds no admin tier. Proposed: the release lane is run as Steffon or
   Xan; or Avi's claim takes a studio login scoped to the release.
3. **How long must the census read zero before Stage B ships?** Proposed: seven
   days on production, covering one full release cycle.
4. **What does a logged-out agent present to read the board and to narrate?**
   Today, the shared token. Proposed: the harness key gains the read endpoints
   and the narration endpoints, attributed to the mascot; it still writes no task.
5. **What creates and claims a task before any login exists?** `bin/task begin`
   creates the task and moves it to `building`, and only then can a login be
   minted. Proposed: the task create and the claim move join the harness key's
   doors.
6. **Does a machine with no harness key keep minting with the shared secret?**
   Proposed: yes, through the exchange, until every machine holds a key; then the
   exchange takes the harness key in place of the secret.

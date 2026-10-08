# Agent sessions and capability APIs — design

**Status: decided; phase two in progress.** Piece 3b of the
`platform-audit-refactors` epic. Sections 1 to 7 state the model: what the code
enforces, and what is decided and not built. Section 8 lists the remaining steps
by task slug; section 9 holds the questions Alex has not answered.
How a soul logs in: [`../modules/credentials.md`](../modules/credentials.md#how-a-soul-logs-in-to-the-board).

The page reads the code on `accepted`. Three pieces are merged there and are not
in production: the reviewer's login with the transition checks of section 5, the
admin login request with its two grants, and the facts API. Section 8 names the
task each rides on. The hub-shell admin grant is in production (section 3).

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
| Hub API login | Two bearers. An agent session's token names one row, read on every call. The shared `AGENT_API_SECRET` still exchanges for a 24-hour token whose payload carries no soul, no task and no scope; it passes every gate except the session-only ones, and each use is logged as legacy. `bin/task`, `bin/dor-check` and `bin/agent-activity` carry it wherever no session applies | `app/controllers/api/v1/base_controller.rb#authenticate_api!`, `app/controllers/api/v1/auth_controller.rb#create`, `bin/lib/agent_api.rb#token` |
| Actor on board writes | The session's soul when a session is present; the `actor` or `by` param is ignored. Under the shared token the param is recorded as sent | `app/controllers/concerns/api/agent_session_gate.rb#session_actor` |
| Session-only endpoints | The facts API takes an agent session and answers the shared token 401. The TikTok draft create takes an admin session and answers anything else 403 | `app/controllers/api/v1/facts_controller.rb#require_agent_session!`, `app/controllers/concerns/api/agent_session_gate.rb#require_admin_session_only!` |
| Turf Monster production | Holds the same `AGENT_API_SECRET` for two hub endpoints: `Studio::PushGameRecap` (`POST /api/v1/game_recaps`) and `Studio::SyncAthletes` (`GET /api/v1/athletes`) | `turf-monster/app/services/studio/` |
| Heartbeat attribution | `bin/agent-activity heartbeat <soul>` writes a sticky `.acting-agent` marker beside the session marker; every activity attributes to that soul until `--clear` or session end. Local, unverified. For Steffon and Xan the same command also asks for the admin login (section 3) | `bin/atomic-event#heartbeat` |
| GitHub tokens | `bin/gh-app-mint-token` mints a GitHub App installation token: one-hour expiry (GitHub's), scoped by App identity (`github.mcritchie-agent` builds and reviews; `github.mcritchie-admin` ships, no pull-request scope), every repo of the installation. The admin item is in the admin vault, unreadable from the agent token. `bin/gh-app-git-credential` hands the token to git, so it reaches the shell and not the transcript | `bin/gh-app-mint-token`, `bin/gh-token#IDENTITIES` |
| 1Password reads | Two lanes: the agent vault `studio-agents` through `OP_SERVICE_ACCOUNT_TOKEN` in every shell; the admin vault `studio-agents-admin` through `~/.zprofile.admin`, opt-in. Every `op` read is metered to `.agents/op-reads.log` (caller, action, context) and queried by `bin/op-reads` | `bin/secret`, `bin/lib/op_meter.rb`, [`../modules/credentials.md`](../modules/credentials.md) |
| Operator windows | Four windows in `config/release_builder.yml#operator_windows` (approval 10 minutes, escalation 20, production 30, admin login 10), read by `Devops::Windows`. The production one is a grant: the ship posts a `ship_authorization` request and Alex taps Approve on `/deployments` | `app/controllers/releases_controller.rb#authorize_ship` |
| Client-facing runtime | Tyrion: an isolated NUC, outbound only, a model with no tools, a 280-character output filter, a capped model key, a per-account bot token stored as a digest | [`../agents/tyrion/runtime.md`](../agents/tyrion/runtime.md) |

What the shape means: the shared token proves a caller holds the secret, never
who the caller is, and it sits in every agent shell's env and in Turf's production
config. A session names its soul and its task, and the server ends it. While both
bearers are accepted, a session narrows the caller that presents it, and the
shared token still passes every gate that is not session-only.

## 2. The session record and its token

A session is one row the server owns (`AgentSession`):

| Field | Value |
|---|---|
| `slug` | Server-issued, `sess-…`; the only thing the token carries |
| `soul` | A slug from `Task::SOUL_ROSTER`; `pokemon` for a builder |
| `tier` | `admin`, `studio` or `client`. The soul caps it, and nothing changes a row's tier, soul or scope after create |
| `task_slug` | The scope. Required for studio: one task. Always null for admin, because the tier is the scope |
| `issued_by` | How the login was granted, one of `AgentSession::ISSUERS`: `task_claim`, `review_claim`, `operator_grant`, `launch_phrase`, `runtime_key` |
| `harness_session_id` | The Claude or Codex session that asked. Asserted by the caller, so it proves nothing by itself |
| `issued_at`, `expires_at` | Expiry from `AgentSession::TTL`: studio 24 hours, admin 8 hours, client 24 hours |
| `revoked_at`, `revoked_by` | Revocation is immediate: the server reads the row on every call |

The token is a signed message carrying only the session's slug, under its own
purpose, so a shared-secret token cannot be replayed as a session. It expires with
the row; the message's own expiry is a day later as a backstop. A session cannot
mint a session: every login is presented with the machine key (section 3).

| Tier | Souls | Reaches |
|---|---|---|
| **Admin** | Steffon, Xan (`AgentSession::ADMIN_SOULS`) | Any task, release writes, conductor lanes, agent updates, slug renames, sensitive facts, the TikTok draft. An admin soul may also hold a studio session, which narrows it |
| **Studio** | Every other soul that is not a client: Carl, Jasper, Avi, Shannon, Rex, Mack, Mason and the Pokémon builders | Board writes for the one task held, and ordinary facts |
| **Client** | Turf Monster, Tyrion (`AgentSession::CLIENT_SOULS`) | Nothing yet: the model and the tier exist, no endpoint mints a client session, and every board endpoint answers one 403 |

A caller with no session is **the Pokémon**: it reads the board and the docs, and
it narrates as its mascot. Under the shared token it can still write; the decided
end state is that every board write needs a login (section 8).

## 3. How a login is granted

A soul cannot hold a password: anything in its context is readable by whatever it
reads. So every grant comes from outside the model. The **machine key** is the
credential a script reads from its env and the model never sees. It is the shared
secret's token until a per-machine key replaces it (section 8).

| Tier | Granted by | What the agent presents | Scope | Expires |
|---|---|---|---|---|
| Studio, builder | The task claim: `bin/task begin` logs the desk in (`POST /api/v1/agent_sessions`). The task must be `building`, and the soul must be one the claim recorded as its builder; any other soul answers 403 | The machine key | The task | When the task leaves `building` and `submitted`, or after 24 hours |
| Studio, reviewer | The review claim: `bin/task claim-next-review` and `review-claim acquire`. The mint sits inside the claim's lock. The soul must be in the reviewer pool and outside the task's author set | The machine key | The claimed task | When the task leaves `submitted`, when the claim lapses, is released or changes hands, or after 24 hours |
| Admin | The one-time code the board shows on the request, carried in Alex's launch phrase, or an Approve tap on the board, inside the `admin_login` window of `Devops::Windows`. The session asks; the server posts the request; a lapse grants nothing | The machine key, plus the request id and its collect key | None: the admin tier is the scope | Eight hours, or the harness session's end |
| Admin, from a hub shell | `bin/rails agent_sessions:grant_admin`: a shell on the hub can already write the database, so the shell is the grant. It runs outside the board: no request, no code, no tap and no window, and the row records `operator_grant`, the value an Approve tap writes | Nothing; the token prints on stdout for `AGENT_ADMIN_SESSION_TOKEN` | None | One to eight whole hours |
| Client | Not built. Decided: only from the isolated runtime, with a runtime-bound key stored as a digest and shown once, as Tyrion's bot token is | The runtime key, from the runtime's own env | The runtime's channel (first case: Turf Monster's TikTok DMs) | The key's |

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
| Claim a task | Mints a studio session (section 3) | yes, and it logs in | no | yes | yes | yes |
| Write the task held | Stage move, checks, notes, local-url | no | no | own task | any task | yes; the shared token still writes |
| Read and write facts | Encrypted records; a sensitive fact needs admin | no | no | ordinary | all | yes |
| Draft to TikTok | Queues the upload to the operator's drafts | no | no | no | yes | yes |
| Release writes | Release events and notes, conductor claims, shifts | no | no | no | yes | gated; no CLI presents an admin session |
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
session and passes these gates.

| Transition | Who may make it under a session | Checked |
|---|---|---|
| `designed` to `building` | Studio, by claiming | The claim mints the session |
| `building` to `submitted` | Studio, the session that holds the task | By scope: a session writes only its own task |
| `designed`, `building` or `submitted` to `reviewed`; `submitted` to blocked | A reviewer's session, or an admin's, whose soul is outside the task's author set | yes |
| Any stage to `archived` | Admin | yes |
| `reviewed` to `assembled`, `assembled` to `shipped` | Decided: admin, under a grant | no |

The check runs where a stage is written: the task update and block
(`app/controllers/api/v1/tasks_controller.rb#require_transition_tier!`) and the
stage events' complete and fail
(`app/controllers/api/v1/task_events_controller.rb#require_transition_tier!`),
both through `AgentSession#transition_refusal`.

The task API returns the task's live studio session. The board card does not show
the soul, the tier or the expiry yet, and the sticky heartbeat marker still
attributes activities.

## 6. Prompt-injection containment

- **A studio login is bound to its task and expires.** Content read during a task
  can at most spend that task's writes, for that task's life.
- **Tier is set at login and never raised.** The soul caps the tier, a session
  cannot mint a session, and a client session reaches no board endpoint. Those
  endpoints check the row, not the prose.
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
| A review claim logs the reviewer in; the verdict and `archived` transitions are checked | `agent-sessions-review-login` | merged; rides the next release |
| The admin-only TikTok draft create and the hub-shell grant | `tiktok-draft-hardening` | shipped |
| The admin login request and its two grants | `agent-sessions-admin-grant` | merged; rides the next release |
| The facts API, session-only | `facts-primitive-and-endpoints` | merged; rides the next release |
| The shared token answers 401 on writes; a per-machine key mints studio logins; Turf's two services get their own key; hooks, `bin/release` and `bin/task` authenticate by session | `retire-shared-secret-fallback` | blocked: it needs the admin grant live in production, and question 1 |
| The soul on the board card; the tier and the expiry are on no card | `task-card-becomes-component` | designed |
| The checks on `reviewed` to `assembled` and `assembled` to `shipped`; the capability endpoints of section 4 marked not built; break-glass logging (section 7) | none filed | |
| One leases table for review, release and shift claims (epic piece 5e) | none filed | |
| The client runtime and its key, Turf Monster's TikTok DMs first (epic piece 3f) | none filed | |

Findings `retire-shared-secret-fallback` carries, each a hole once the shared
token stops writing:

- An orchestrator, the builder, the reviewer and the light it spawns share one
  harness session id. Any of them writing to a claimed task from the checkout
  that holds the review login writes as the claiming reviewer.
- The admin login file is named for the harness session id, so every agent that
  shares the id shares the admin login.
- `bin/task` cannot present an admin session, so a move to `archived` under
  sessions has no command-line path.
- A reviewer who fix-forwards the PR becomes an author and gets 403 on the move
  to `reviewed`. The remedy today is to release the claim and make the move on
  the shared token.
- `bin/lib/review_claim_cli.rb#release` deletes the kept review login without
  checking who owns it.

## 9. Open questions for Alex

1. **Does `POST /api/v1/auth` stay as the credential that mints a session?** A
   session cannot mint a session, and `bin/task begin` logs in with the shared
   token. Recommended: keep the exchange for the mint only, behind a per-machine
   key, and refuse it on every write.
2. **Does Avi get admin for `arbitrate-block`?** His ruling writes a task he does
   not hold. Proposed: no; a studio session scoped to the contested task by the
   arbitration request, which keeps the admin tier to the two souls named.
3. **Does a logged-out Pokémon narrate once the shared token retires?** This page
   says yes, attributed to the mascot; the alternative makes narration the first
   studio write.
4. **Does the hub-shell grant stay?** `bin/rails agent_sessions:grant_admin` is in
   production, and the TikTok draft SOP runs it there through `heroku run`: whoever
   can run a command on the hub mints an admin session of up to eight hours, with
   no code and no tap. Proposed: keep it as the path for when the board cannot
   grant, and move that SOP to the board's grant once it is in production.

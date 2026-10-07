# Agent sessions and capability APIs — design

**Status: approved by Alex on 2026-10-06, with two amendments: an admin session
carries no task scope (the admin tier is the scope), and there is no Dawn (the
client tier is Turf Monster and Tyrion).** His idea of 2026-10-05, piece 3b of the
`platform-audit-refactors` epic. Section 1 is what existed before the build;
sections 2 to 8 are the design, section 9 the questions it raised.

**Built (phase one):** the `agent_sessions` table and `AgentSession` model (all three
tiers, admin unscoped), `POST /api/v1/agent_sessions` for a studio login,
`bin/task begin` logging the desk in, the actor taken from the session on every
board write, the tier and scope gates (`Api::AgentSessionGate`), and the shared
secret kept beside it, logged as legacy. Not built yet: the admin grant (Approve tap
or launch phrase), the `claim-next-review` login, and the soul on the board card.
How a soul logs in: [`../modules/credentials.md`](../modules/credentials.md#how-a-soul-logs-in-to-the-board).

The idea in one paragraph: credentials move behind deterministic server APIs, and
the platform gains **agent sessions**. An agent logs in as a soul when it starts a
task, and the session gains one variable, the logged-in agent. The server performs
every privileged act (deploy, send, mint, rotate) and hands back a receipt, so no
secret enters a model's context. A role is bound to a task and expires. The
Pokémon is the logged-out state, and stays as flavour when a soul is logged in.

## 1. Today, read from the code

| Surface | What it does today | Where |
|---|---|---|
| Hub API login | One shared `AGENT_API_SECRET` exchanges for a 24-hour token whose payload is `{authenticated: true, issued_at}`: no soul, no task, no scope. Every `bin/task`, `bin/dor-check` and `bin/agent-activity` call carries it, and `bin/submit` through them | `app/controllers/api/v1/auth_controller.rb#create`, `app/controllers/api/v1/base_controller.rb#authenticate_api!`, `bin/lib/agent_api.rb#token` |
| Actor on task events | A self-declared request param. `bin/task --actor <soul>` names whoever the caller says | `app/controllers/api/v1/task_events_controller.rb#event_attributes` |
| Turf Monster production | Holds the same `AGENT_API_SECRET` for two hub endpoints: `Studio::PushGameRecap` (`POST /api/v1/game_recaps`) and `Studio::SyncAthletes` (`GET /api/v1/athletes`) | `turf-monster/app/services/studio/` |
| Heartbeat attribution | `bin/agent-activity heartbeat <soul>` writes a sticky `.acting-agent` marker beside the session marker; every activity attributes to that soul until `--clear` or session end. Local, unverified | `bin/atomic-event#heartbeat` |
| GitHub tokens | `bin/gh-app-mint-token` mints a GitHub App installation token: one-hour expiry (GitHub's), scoped by App identity (`github.mcritchie-agent` builds and reviews; `github.mcritchie-admin` ships, no pull-request scope), every repo of the installation. The admin item is in the admin vault, unreadable from the agent token. `bin/gh-app-git-credential` hands the token to git, so it reaches the shell and not the transcript | `bin/gh-app-mint-token`, `bin/gh-token#IDENTITIES` |
| 1Password reads | Two lanes: the agent vault `studio-agents` through `OP_SERVICE_ACCOUNT_TOKEN` in every shell; the admin vault `studio-agents-admin` through `~/.zprofile.admin`, opt-in. Every `op` read is metered to `.agents/op-reads.log` (caller, action, context) and queried by `bin/op-reads` | `bin/secret`, `bin/lib/op_meter.rb`, [`../modules/credentials.md`](../modules/credentials.md) |
| Operator windows | Three windows in `config/release_builder.yml#operator_windows` (10, 20, 30 minutes), read by `Devops::Windows`. The production one is a grant: the ship posts a `ship_authorization` request and Alex taps Approve on `/deployments` | `app/controllers/releases_controller.rb#authorize_ship` |
| Client-facing runtime | Tyrion: an isolated NUC, outbound only, a model with no tools, a 280-character output filter, a capped model key, a per-account bot token stored as a digest | [`../agents/tyrion/runtime.md`](../agents/tyrion/runtime.md) |

What the shape means: the token proves a caller holds the secret, never who the
caller is. The secret sits in every agent shell's env and in Turf's production
config, so one leak is every identity. The GitHub installation token is the one
place a short-lived, scoped, server-minted credential already exists, and it is
the model for everything below.

## 2. The session record and its token

A session is one row the server owns:

| Field | Value |
|---|---|
| `soul` | A slug from `Task::SOUL_ROSTER`; `pokemon` for a builder |
| `tier` | `admin`, `studio` or `client` (section 3) |
| `scope` | What the session may write: a task slug and its repo for a builder or reviewer, a release slug for QA or a deploy, a runtime id for a client. Null only for admin |
| `issued_by` | How the login was granted: `task_claim`, `operator_grant`, `runtime_key` |
| `harness_session_id` | The Claude or Codex session that holds it; the mascot comes from here |
| `issued_at`, `expires_at`, `revoked_at` | Expiry per tier (section 3). Revocation is immediate: the server reads the row on every call |

The token is a signed message, as today's is, carrying only the session id, with
a new purpose so today's tokens cannot be replayed into the new table. The agent's
scripts hold it where `bin/lib/agent_api.rb` caches a token today; it names no
secret and expires with the row.

| Tier | Souls | Reaches |
|---|---|---|
| **Admin** | Steffon, Xan | The admin vault, the production ship, credential rotation, DNS, Heroku config |
| **Studio** | Carl, Jasper, Avi, Shannon, Rex, and the Pokémon builders | The agent vaults' credentials by capability, board writes for the task held, a one-hour GitHub token scoped to the task's repo, QA |
| **Client** | Turf Monster, and the persona Alex calls Dawn | Outsiders, through an output filter and a spend cap, from an isolated runtime. No vault, no tools |

A session with no row is **the Pokémon**: it reads the board and the docs, and it
narrates as its mascot. Every board write needs a login. Logged in, the mascot
stays: the card reads `Cherubi, as Carl`.

## 3. How a login is granted

A soul cannot hold a password: anything in its context is readable by whatever it
reads. So every grant comes from outside the model.

| Tier | Granted by | What the agent presents | Scope | Expires |
|---|---|---|---|---|
| Studio, builder | The task claim: `bin/task begin` mints the session on the claim | The machine key (section 8, step 2): a per-laptop key the script reads from its env, never the model | The task and its repo | With the task's build (`submitted`), or the harness session's end, whichever is first (question 2) |
| Studio, reviewer | The review claim: `bin/task claim-next-review` | The machine key | The claimed task | With the review (`reviewed` or `blocked`), or session end |
| Studio, QA | Alex launches `qa-release` himself; the launch claims the release | The machine key | The release | With the release's QA result, or session end |
| Admin | Alex's launch phrase (today, the `full-cycle` SOP), or an Approve tap on the board: the production window of `Devops::Windows`. The session asks; the server posts the request; the grant is the tap, or the window lapsing with no veto in `timed` mode | The machine key, plus the request id | The release or the rotation named in the request | Two hours, or the SOP's end event |
| Client | Only from the isolated runtime: a runtime-bound key, stored as a digest and shown once, as Tyrion's bot token is | The runtime key, from the runtime's own env | The runtime's channel (first case: Turf Monster's TikTok DMs) | The key's; the session rotates daily |

Only the tap is a fact the server can verify. The launch phrase works as the
`full-cycle` kickoff works today: it lets the session ask, and the window answers.

## 4. Capability endpoints

The server performs the act and returns a receipt. The capability's secret (the
GitHub App PEM, the Heroku key, the mailbox grant, the vault token) lives on the
server and in `studio-applications`, never in a shell or a context.

| Capability | Server-side act | Logged out | Client | Studio | Admin |
|---|---|---|---|---|---|
| Read the board and docs | None | yes | no | yes | yes |
| Narrate (activities) | Attributes to the mascot, and to the soul when logged in | yes | no | yes | yes |
| Claim a task | Mints a studio session (section 3) | yes, and it logs in | no | yes | yes |
| Write the task held | Stage move, checks, notes, local-url | no | no | own scope | any task |
| Mint a GitHub token | Calls the App's access-tokens endpoint with `repositories: [<scope repo>]`, which `bin/gh-app-mint-token` does not pass today; hands the one-hour token to the git credential helper | no | no | agent App, the task's repo | admin App, the release's repos |
| QA deploy (`release`) | Runs the QA deploy; files the receipt on the release | no | no | release scope | yes |
| Production deploy | Runs the deploy; records the grant it ran under | no | no | no | yes |
| Send mail | Sends from `<soul>@mcritchie.studio` through the hub's mailer; logs the send | no | no | yes | yes |
| Read a credential's metadata | Name, vault, consumer, last rotation; never the value | no | no | yes | yes |
| Read a credential's value | A break-glass event (section 7) | no | no | no | yes |
| Rotate a credential, change DNS or Heroku config | Runs the step; files the receipt | no | no | no | yes |
| Reply to an outsider | Through the runtime's filter and spend cap | no | yes | no | no |

## 5. What the server enforces, and what the board shows

On every call: the session is live (not expired, not revoked); the tier covers the
capability; the scope covers the object; the transition is legal for the tier; and
the actor is the session's soul, never a param. An `actor` param is refused.

| Transition | Who may make it |
|---|---|
| `designed` to `building` | Studio, by claiming |
| `building` to `submitted` | Studio, the session that holds the task |
| `submitted` to `reviewed` or `blocked` | Studio, a reviewer outside the task's author set |
| `reviewed` to `assembled` | Studio, the session holding the release |
| `assembled` to `shipped` | Admin, under a grant |
| Any stage to `archived` | Admin |

The board shows the logged-in soul beside the mascot, the tier, and the session's
expiry; the timeline reads the actor from the session row. The sticky heartbeat
marker goes: attribution is what the row says.

## 6. Prompt-injection containment

- **A role is bound to its task and expires.** Content read during a task can at
  most spend that task's capabilities, for that task's life.
- **Tier is set at login and never raised.** No endpoint accepts a client key for a
  studio session; the runtime key's row carries `tier: client`. A client session
  cannot claim a task, mint a token, or read a vault, because those endpoints
  check the tier, not the prose.
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
  off its own review.

## 7. 1Password direct reads: admin-only, break-glass

Today every shell reads `studio-agents` directly. Under this design a studio
session reaches a credential only through a capability, so the agent vault token
leaves the default shell profile. An admin session may still run `op read`, and
each read is a break-glass event: the metered row in `op-reads.log` stays, and the
server files who, which item, which session and why, on a page Alex can read.
1Password remains the fallback when the server is down: the fresh-machine rebuild
and a ship recovery read it as they do now.

## 8. Migration path, three steps, each shippable alone

1. **Sessions beside the secret.** Add the session table and
   `POST /api/v1/agent_sessions`; `bin/task begin` and `claim-next-review` log in;
   the server stamps the actor from the session when one is present and from the
   param when not. The board shows the soul. Nothing that works today breaks.
2. **Capabilities move server-side.** The GitHub token mint (scoped by repo) and
   credential metadata become endpoints; the agent vault token leaves
   `~/.zprofile`; `AGENT_API_SECRET` shrinks to a machine key that can claim and
   read, nothing else; Turf's two services get their own application key.
3. **Admin grants and the client tier.** The Approve or launch-phrase grant mints
   admin sessions; direct `op` reads log as break-glass; the runtime-bound client
   login lands with Turf Monster's TikTok DMs as the first client (piece 3f).

## 9. Open questions for Alex

1. **Who is Dawn, and which client does she serve?** The epic names her beside
   Turf Monster; this page gives her no scope until it knows her channel.
2. **Does a studio login expire with the task or with the harness session?**
   Proposed: whichever ends first. A builder's session ends at `submitted`; a
   reviewer's at the verdict; a session close revokes either.
3. **Does Avi get admin for `arbitrate-block`?** His ruling writes a task he does
   not hold. Proposed: no; a studio session scoped to the contested task by the
   arbitration request, which keeps the admin tier to the two souls named.
4. **Does a logged-out Pokémon narrate?** This page says yes, attributed to the
   mascot; the alternative makes narration the first studio write.

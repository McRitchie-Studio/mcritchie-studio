# Agent message loop (the agent mailbox, phase 1)

**What it is.** A message to an agent on Discord reaches the hub, is routed to a
soul, waits in a queue, and is answered in the same channel by `bin/dispatcher`,
the always-on worker on Alex McRitchie's Mac (`bin/heartbeat` is the manual form of the
same answer path). Discord came first; since Phase 4 an email to a CTO on team@
is answered by email too (below, "Email"), and since Phase 7 an app's owner or an
admin can chat with the app's CTO on McRitchie Studio itself (below, "Web chat").
Two domain front doors are routed,
Avi (`avi`, McRitchie Studio's CTO, Alex McRitchie 2026-10-15) and Turf (`turf_monster`,
Turf Monster), and each may PROPOSE what its domain's catalog allows, for the
owner to confirm by reply (below, "Proposals and confirm"). Alex stays routed as a
helper (client-facing) with no catalog. Avi and Alex keep one
read-only action each, the same board read (`bin/task list`). On Slack, Alex
McRitchie's own message to a scoped soul (Mason, Mack) runs with read-only tools
inside that soul's scope (below, "Scoped runs"). Later phases add channels, agents and clients without
changing the tables: `channel` plus a provider-neutral `external_id` name every
row.

## How it works

```text
Discord guild ──Gateway push (MESSAGE_CREATE)──┐
  (every channel,                               ├─ addressed only ─▶ agent_messages (received)
   thread, forum post) ──backstop poll, 10 min──┘   (the rest is dropped unstored)
                                              │ bin/dispatcher: long-poll claim, every routed soul
                                              │ (lease 10 min, renewed every 3 while the answer runs)
                                              ▼
                     one read-only action + headless Claude (no tools), at most 5 at once
                                              │ while it runs: "typing…" every 7s, up to 3 min
                                              │ (POST …/:id/typing → AgentMessageTypingJob, the reply's bot)
                                              │ complete
                                              ▼
                       AgentMessageReplyJob ──▶ one Discord reply: the soul's own bot
                                                   if it has one, else the shared bot

bin/dispatcher ──ping every minute──▶ agent_dispatchers ◀── AgentDispatcherAlertJob
                                                            (one Discord alert per incident)
```

| Piece | Where |
|-------|-------|
| Messages, timeline, poll cursors | `agent_messages`, `agent_message_events`, `agent_message_cursors` (`AgentMessage`, `AgentMessageEvent`, `AgentMessageCursor`) |
| Routing config | `config/agent_routes.yml`, read by `AgentMessages::Routes` and `AgentMessages::Router` |
| Inbound, push | `AgentMessages::DiscordGateway` (a thread in the Solid Queue scheduler process on the worker dyno, `config/initializers/agent_message_gateway.rb`), protocol state in `AgentMessages::GatewaySession`, leader lock `AgentMessages::GatewayLeaderLock` → `AgentMessages::DiscordIngest` |
| Inbound, backstop | `AgentMessageDiscordPollJob` (Solid Queue, `config/recurring.yml`, every 10 minutes) → `AgentMessages::DiscordPoll` → `AgentMessages::DiscordIngest` |
| Medium seam | `Media.adapter(message.channel)` (`app/services/media/`): `Media::Discord`, `Media::Email`, `Media::Web`, each a `Media::Adapter`. Both jobs below dispatch through it, so a reply always goes back on the medium the message arrived on; a medium's failure is a `Media::Error` (`AgentMessages::DiscordBot::Error` is one). Plan: `.agents/epics/omnichannel-media.md` |
| Outbound | `AgentMessageReplyJob` → `Media::Discord#deliver_reply` → `AgentMessages::DiscordBot#post_reply`, as the soul's own bot (`DISCORD_BOT_TOKEN_<SOUL>`) or the shared bot (below, "Which bot replies") |
| Typing | `bin/dispatcher` → `POST /api/v1/agent_messages/:id/typing` → `AgentMessageTypingJob` → `Media::Discord#typing` → `AgentMessages::DiscordBot#trigger_typing`, as the bot that will reply (below, "Typing") |
| Worker API | `Api::V1::AgentMessagesController` (`/api/v1/agent_messages`) |
| Worker | `bin/dispatcher` (`bin/lib/agent_dispatcher.rb`), under launchd on Alex McRitchie's Mac; `bin/heartbeat` by hand. Both answer through `AgentMailbox::Responder` (`bin/lib/agent_mailbox.rb`) |
| Dispatcher health | `POST /api/v1/agent_dispatchers/ping` (with the Mac's op, gh and power health) → `agent_dispatchers`; `AgentDispatcherAlertJob` → `agent_mailbox_incidents`, Discord, and one email per episode state to `floor.escalation_email` |
| Operating it | Steffon's [`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md) SOP |
| Observing | `/admin/agent_messages` (Ops → Agent inbox), `bin/agent-inbox` |

**Scope: the guild is the boundary.** `config/agent_routes.yml` lists guilds and
the souls in each. Every text channel, thread and forum post in a listed guild is
read, with no per-channel entry. A guild the bot sits in that is not listed is
ignored, and the log names it once per process (`ignoring Discord guild <id>`).
A channel entry is an optional override: `default_soul` routes that channel's
unaddressed messages, and `ignore: true` mutes it, mentions included. A thread
takes its parent channel's override unless it has its own.

**Inbound, push.** `AgentMessages::DiscordGateway` holds one Discord Gateway (v10,
`wss`) connection with intents GUILDS, GUILD_MESSAGES and MESSAGE_CONTENT. It
heartbeats at HELLO's interval, IDENTIFYs, and on a reconnect RESUMEs with the
session id and last sequence number at READY's `resume_gateway_url`. An unacked
heartbeat closes the zombie and resumes; RECONNECT resumes; INVALID_SESSION, or a
4007/4009 close, starts a fresh IDENTIFY; 4004 and 4010-4014 (bad token, bad
intents, sharding) stop it for good with one error line. Reconnects back off from
1 second to 5 minutes; the ladder resets only after a connection has stayed up 60
seconds past READY or RESUMED, so a session that drops at once keeps climbing.
Each MESSAGE_CREATE goes through `DiscordIngest`, the same path the poll uses, so
the unique index dedupes the two.

- **The IDENTIFY budget.** Discord allows about 1,000 session starts (IDENTIFYs)
  per token per day and resets the token past that, which takes the mailbox down
  until a new one is filed. So the listener RESUMEs whenever the session allows
  (RESUME starts no session), and before every IDENTIFY it checks two counts.
  First, our own `AgentMessages::GatewayIdentifyBudget`: 200 in a rolling 24
  hours, kept in the database (an `agent_message_cursors` row,
  `discord-gateway:identify`) so a crash loop's restarts cannot zero it. Second,
  Discord's own `session_start_limit` from `GET /gateway/bot`
  (`AgentMessages::GatewayStartLimit`): below 10 `remaining`, it waits out
  `reset_after`. Either spent: it stands down, still holding the leader lock,
  until the window rolls (rechecking every 15 minutes), with one error line and
  one `ErrorLog` receipt per stand-down. Meanwhile the backstop poll keeps
  reading. A count it cannot read is a failed attempt: it backs off and never
  IDENTIFYs blind.
- **The handshake deadline.** TCP and TLS must finish within 30 seconds, then
  the websocket upgrade, HELLO and READY (or RESUMED) within another 30 (a
  minute at most in all), or the socket is closed and the
  listener backs off (`handshake did not finish within 30s`), so a stalled
  handshake never holds the leader lock with no live listener behind it.

- **Where it runs: the Solid Queue scheduler process**, as a thread its lifecycle
  hooks start and stop. The worker dyno's `bin/jobs` runs exactly one scheduler
  whatever `JOB_CONCURRENCY` says. The scheduler is nearly idle (it only enqueues
  recurring jobs), the supervisor replaces it if it dies (re-running the start
  hook), and its stop hook runs on SIGTERM. No new dyno, no recurring cost, and no
  job thread pinned forever. A scheduler runs only where `config/recurring.yml`
  lists tasks (production), so web dynos, consoles, desks and tests never connect.
- **One connection per bot token.** Before connecting, the thread takes a Postgres
  session advisory lock keyed by a digest of the token, on the one database
  connection it holds for life (its writes use the same one). A second process or
  a restart's overlap logs `another process holds the connection; standing by` and
  retries every 30 seconds. While connected, the holder checks every 15 seconds
  that its own backend still holds the lock, and stands down the moment it does
  not. The connection budget in `config/puma.rb` counts this one connection. The
  lock is per database, so it cannot stop another app holding the same token: that
  is why the token is never set on `mcritchie-studio-qa`.
- **Receipts.** A routine reconnect is a log line. A fatal close, a message it
  could not store, a spent IDENTIFY budget, and the thread dying each also write
  an `ErrorLog` row.
- **Switches.** Without `DISCORD_AGENT_BOT_TOKEN`, with `DISCORD_GATEWAY=off`, or
  with no guild listed, it stays inert and logs one `discord gateway idle:` line.
  It never logs the token or an IDENTIFY/RESUME payload. With the gateway off, the
  backstop poll is the only reader, so a message waits up to 10 minutes to be
  stored. One-minute latency without the gateway also needs the
  `agent_message_discord_poll` cadence in `config/recurring.yml` changed (a
  deploy), and costs a channel listing plus one read per channel every minute.

**Inbound, backstop.** Every 10 minutes the poll lists each guild's channels
(`GET /guilds/{id}/channels`, keeping text and announcement channels) and active
threads (`GET /guilds/{id}/threads/active`), drops the muted ones, and reads each
with `GET /channels/{id}/messages?after=<cursor>`. The cursor advances in the same
transaction as the rows it covers, past dropped chatter too, and the unique index
makes a re-read page harmless. Each insert runs in its own savepoint, so when the
gateway stores the same message first, the poll's losing insert (the uniqueness
validation or the unique index) returns the gateway's row and the page, its
cursor and the pass carry on. A channel's first read stores only messages from
the last hour, so old history stays out of the queue. A rate limit stops the pass;
the next run resumes. A channel the bot cannot read keeps its error on its cursor.
Messages written by any bot are not ingested, so the agents' own replies never
return as inbound.

**Routing: only addressed messages are stored.** In order: a mention of a soul's
bot USER, a mention of a soul's ROLE, a reply to a message the mailbox already
holds or to an agent's reply, in the same channel (it joins that thread and soul;
a forward, or any reference into another channel or guild, counts as a fresh
message), the channel
override's `default_soul`. A message that meets none of these is dropped without
being stored: across a whole guild, keeping it would hoard everyone's chatter. A
reply to a kept message that itself had no soul is kept `unrouted`, visible and
never handed to a worker. Among several mentioned souls, the one written first
wins. One shared bot with `@Avi`/`@Alex` roles and one bot user per soul both
work; the config lists either.

**Held: the agents answer the owner, with two narrow exceptions.** `config/agent_answerers.yml` lists
the ROLES the agents answer (below, "Audience"); today it is `owner` alone, so
Alex McRitchie is answered because his `agent_people` row is the owner, and so is every
identity linked to him. A routed message from anyone whose role is not listed
(team, client, public, or no person) is stored `held` with a `held` event naming
the role, never `received`. The guard is enforced again on the server in every
claim (`AgentMessage.claimable`, `AgentMessages::Answerers`): a row is claimable
only when its person's role is answered or an admin released its hold, so even a
stranger's row that is somehow `received` is never claimed, and a row with no
person never is. Held rows, and rows that fail the guard, are not open for the
thread and person wait rules, so they hold nobody back, and no memory layer
shows a held row. Find them at `/admin/agent_messages?status=held` or with
`bin/agent-inbox list --status held`. To answer one, press **Release and
answer** on its page (admin only, a form post) or run
`bin/rails agent_people:release MESSAGE=<id>`: that one message becomes
`received` and is answered like any other; the sender's next message is held
again. To answer a sender for good, give them an answered role
(`bin/rails agent_people:role`); to answer a whole role, add it to the yml and
deploy. What the agent may then say to them is the audience's rules.

**The app-owner exception** (Alex McRitchie, 2026-10-17; `app_owners:` in the same yml,
`AgentMessages::Answerers#app_owner_thread?`). An app's CTO, ours from
`config/cto_reports.yml` or a client app's `client_cto`, answers a `public` or
`client` person whose hub user owns that app (`AppMembership` owner), on that app's
web CTO thread and nowhere else. The rule reads only what code wrote: the row is
`web`, its thread key is exactly `web:<channel_ref>:<the person's user id>`, its soul
is that app's CTO (`AppOwnership.cto_for_app`), and the membership is read at the
moment of the check. The same person stays `held` on another app's thread, on
Discord, by email, and on an app they do not own. The claim's SQL guard carries
the same rule. They are answered as that app's `client` (`Answerers#audience_for`,
`MemoryBundle#audience`): no read action, no internal context, the client catalog.
On that same thread they may say `go`, `no` or `change: …` on a `change` proposal
while the app is under its cap ("Confirm by reply" below; Alex McRitchie, 2026-10-18). Their
answers are metered as `client`, against `AgentUsage.owner_meter`: the tier's
`cto_monthly_tokens` (Vibe, the free tier: 25,000), else
`app_owners.default_monthly_tokens` (1,000,000) for a tier that names none,
unless an admin lifted the cap. At the cap,
`WebIngest` stores the message already answered with `AgentUsage.cap_reply` and
no model runs. An owner or team person is answered by their role, never by this
rule. Remove the block to hold app owners again.

**Claim.** `POST /api/v1/agent_messages/claim {soul | souls[], worker, wait?}`
runs one transaction. It first dead-letters exhausted leases, then selects the oldest
claimable message `FOR UPDATE SKIP LOCKED` and stamps `claimed_by`,
`lease_expires_at` (10 minutes) and `attempts + 1`. A message is claimable when
it is routed to that soul, is `received` (or `claimed` under a lapsed lease with
fewer than 3 attempts), and is the oldest open message in its thread and the
oldest open message from its person to that soul (below, "Memory"). Those rules
keep a conversation in order and allow one active claim per thread. Before it
takes the lease, the claim asks the usage gate (`AgentUsage.gate`): a client's
or the public's message to an app at its monthly allowance is answered in code
with the cap reply and the next message is tried; past 80% the message is
claimed and its answer ends with a usage notice. Owner and team are never
capped, and the shipped allowances are blank, so nothing is capped until Alex McRitchie
prices the tiers ([`agent-usage.md`](agent-usage.md)).
A claim with nothing waiting answers 200 with `data: null`. Several souls in one
claim (`souls`) take the oldest message across them. With `wait` (seconds,
capped at 20, well under Heroku's 30-second router timeout) the board retries
the claim every second and answers the moment one lands, else `data: null` at
the deadline. The cost is one puma thread held per waiting dispatcher, of the 6
production runs (2 workers x 3 threads).

**Complete.** `POST /api/v1/agent_messages/:id/complete {worker, response_text,
action_summary, notes?}` succeeds only for the worker holding the claim. `notes`
are the facts the answer returned about the sender (below, "Notes"). A second
complete by that worker answers `already_completed` and queues nothing. The reply
job posts once: a row with a `reply_external_id` is never posted again, and the
post carries the row's `reply_nonce` with Discord's `enforce_nonce`, so a retried
post returns the existing message. Replies reference the original message and
parse no mentions; a reply through the shared bot leads with the soul's name
(`**Avi** · …`).

**Which bot replies.** Reading stays on the one shared bot
(`DISCORD_AGENT_BOT_TOKEN`). Replies switch per soul: when
`DISCORD_BOT_TOKEN_<SOUL>` is set (the soul's slug upcased, non-alphanumerics as
`_`: `DISCORD_BOT_TOKEN_AVI`, `DISCORD_BOT_TOKEN_TURF_MONSTER`,
`DISCORD_BOT_TOKEN_ALEX`, `DISCORD_BOT_TOKEN_MASON`, `DISCORD_BOT_TOKEN_MACK`,
`DISCORD_BOT_TOKEN_STEFFON`; the selection is by slug, so any soul works with no
code change), the reply posts as that soul's own bot, with no
prefix, since the bot's name already says who answered. Absent or blank, the
shared bot posts it, prefixed, as before. When Discord refuses the soul's bot
with a 401 or 403 (a bad token, a bot not in the guild, a missing channel
permission), the job writes an `ErrorLog` row targeted at the message and a
`reply_bot_refused` event (the var's name and Discord's answer), then posts once
through the shared bot, prefixed, with the same nonce. A retried job sees that
event and goes straight to the shared bot, so a refused bot is never retried in a
loop; with no shared token either, the reply is `failed`, never dropped silently.
Any other error retries as before. `reply_posted` records `via: soul_bot` or
`via: shared_bot`. No token is logged, rendered, or put in an exception message:
`DiscordBot` redacts its token from everything it raises and from `inspect`.
A soul's token is made and installed through a card in the Pending agents column
of `/agents` (Steffon's [`agent-onboarding`](../agents/steffon/sops/agent-onboarding.md)).
The pick and the one fallback live in `AgentMessages::BotSelector`, which the
per-app CTO reports share ([`report-destinations.md`](report-destinations.md#which-bot-posts)).
Setting a soul's var is Steffon's
[`discord-bot-setup`](../agents/steffon/sops/discord-bot-setup.md), Part 1b.
`POST /api/v1/agent_messages/:id/release {worker, reason, code?}` gives a message
back; the attempt it used still counts, so a give-back on the third attempt
dead-letters it. The one exception is `code: usage_limit`, which hands the
attempt back and does not dead-letter: Claude being out of usage says nothing about
the message. The board caps those refunds at 3 per message (`usage_refunds`,
`AgentMessage::MAX_REFUNDS`); past the cap the release spends the attempt like any
other, so no message loops on refunds forever. `POST /api/v1/agent_messages/:id/renew {worker}` extends the
holder's lease by 10 minutes from now; anyone else, or a holder whose lapsed lease
another worker took, gets 409. The timeline keeps one `lease_renewed` event per
claim, its count updated in place.

**Auth.** The board's own (`Api::V1::BaseController`): an agent session or the
shared token, never a new secret. A session acts only for its own soul (an admin
session for any). A client session or a harness key reaches none of it.

**The dispatcher.** `bin/dispatcher run` serves every soul `config/agent_routes.yml`
routes (or `--souls`). It long-polls one claim at a time, answers each message on
its own thread through the same Responder the heartbeat uses, renews the lease
every 3 minutes while the answer runs, keeps at most 5 answers at once, and pings
the board every minute. Every board call is made from its main loop.

**The ping.** `POST /api/v1/agent_dispatchers/ping` carries `worker`, `host`,
`souls`, `running`, `capacity`, `paused_until`, `pause_reason`, `state`, `version`
and `started_at`, and the Mac's harness health: `op_ok` (a login-shell `op whoami`,
which costs no quota), `gh_ok` (`gh api /rate_limit` with the token `bin/gh-token`
hands agents), `power` (`ac` or `battery`, from `pmset -g batt`) and
`harness_measured_at`. Each check is bounded at 20 seconds and runs on its own
thread (`AgentMailbox::HarnessProbe`), so a hung `op` never holds up the loop; a
ping carries the newest finished measurement, and none before the first. The board
stores them on the dispatcher row (`op_ok`, `gh_ok`, `power_source`,
`harness_checked_at`) and counts consecutive measurements with op or gh false in
`harness_failing_beats`; a ping repeating a measurement it already carried does not
count again. Claude runs
with `--output-format json`, and the dispatcher reads only what the model cannot
write (`AgentMailbox::ClaudeRun`): the exit status, stderr, and the envelope's
`is_error` and `api_error_status`. A usage-limit notice in a FAILED run's error
text (`AgentMailbox::UsageLimit`) releases with `code: usage_limit` and pauses
claiming until the reset the notice names (else 15 minutes); a signed-out notice
pauses 30 minutes; any other failed run pauses 5, so a broken Claude cannot spend
every message's attempts in a minute. A successful answer is never scanned, so an
answer that says "usage limit reached" is just an answer. A child that outlives its
timeout gets TERM, then KILL after 10 seconds (its whole process group); a run is
never renewed past its deadline (the timeouts plus a margin, about 8 minutes) and
is then abandoned, its message given back. SIGTERM stops claiming, gives runs 60
seconds, then stops their Claude and releases their messages. New code restarts it
by itself: once a minute it re-reads a digest of its own files and
`config/agent_routes.yml`, and a new digest seen twice in a row stops claiming, lets
the runs in flight finish, and exits for launchd to start the new code. It keeps
the minute ping going (state `stopping`) while it drains, since a restart drain
can run up to about 8 minutes, past the floor alert's 5. It posts nothing to
Discord itself. Every child gets an allow-listed environment
(`AgentMailbox::CHILD_ENV_ALLOW`), so no API key, token, base URL or provider
switch reaches Claude and it bills Alex McRitchie's claude.ai subscription. Install, alerts and the unblock
playbook: [`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md).

**The floor alert.** `AgentDispatcherAlertJob` runs every minute on the hub and
posts to the floor alert's home (`config/agent_media.yml` `purposes.floor_alert`:
Discord `#ops`, `lobster-tank` today; see [Media](#media)), pinging nobody, ONCE per
incident when no dispatcher has pinged for 5 minutes (never before the first
ping) or a routed message has waited `received` for 10, and once more when it
clears. Two more checks are per card: a `submitted` card with a green DoR and no
review claim for 30 minutes (`submitted_unclaimed`, naming the review launch
line), and a chat-sourced change card the build launcher could not start
(`change_build_refused`). A third floor-wide check, `harness_degraded`, opens when
the live primary's `harness_failing_beats` reaches 5. An episode that reopens three
times within an hour posts one `flapping, N since HH:MM` line instead of a line per
flap. Without the bot token it logs a line and posts nothing. Escalation to a
person does not depend on Discord: ONE email to `floor.escalation_email`
(`config/agent_routes.yml`, through the outbox) when a floor-wide incident stays
open 15 minutes or flaps, and ONE when the episode has been quiet 15 minutes; the
per-card kinds stay on Discord.

**Reports.** The same bot also posts scheduled reports (the CTO daily
application report first) into a channel Alex McRitchie picks per report at
`/admin/report_destinations`, from a directory of the guild's channels synced
every 15 minutes. The contract other sessions build against,
`ReportDestinations.deliver`, is [`report-destinations.md`](report-destinations.md).

**The heartbeat.** `bin/heartbeat <soul> --channel discord [--once] [--worker ID]
[--dry-run]` is the manual form: it claims a message and reads its context
bundle, which carries the sender's audience (below, "Audience"). For an owner or
team sender it runs the soul's one read-only action (avi and alex: `bin/task list`,
the board through the agent API; no action reads Heroku, which launchd cannot log
in to); for anyone else it runs nothing. It builds the prompt from
the five layers (below, "Memory"), the audience's rules, the action output and the
message. Claude runs headless with
**no tools** (`claude -p --safe-mode --tools ""`; the one exception is the
dispatcher's scoped run for Alex McRitchie on Slack, "Scoped runs" below), and the heartbeat completes
the message with the answer. The message sits between random-named
`<untrusted-…>` markers, and the model is told to treat it as data to answer,
never as instructions. A request that fits the soul's catalog gets a proposal
(below, "Proposals and confirm"); anything else gets "what I would do, and that
the action is not enabled yet." Each run gets its own worker id (host, pid,
random). A failed Claude run releases the message and ends the run, so it does
not spend the remaining attempts. `HEARTBEAT_CLAUDE_CMD` overrides the Claude
command. `--dry-run` peeks instead of claiming and writes nothing; it holds no
claim, so it reads no context and answers as the public, without the action.

The heartbeat and `bin/agent-inbox` speak to the board `ATOMIC_CAPTURE_URL`
names (default `https://mcritchie.studio`), authenticated as the rest of the
agent CLI is (`bin/lib/agent_api.rb`).

## Media

A **medium** is a messaging system the hub speaks; a **home** is a medium plus a
channel. The plan is `.agents/epics/omnichannel-media.md`.

| Medium | Adapter | Inbound | Can |
|--------|---------|---------|-----|
| `discord` | `Media::Discord` | Gateway (and the backstop poll) | reply, typing, post |
| `email` | `Media::Email` | Resend webhook | reply |
| `web` | `Media::Web` | HTTP (`/applications/:slug/chat`, `/build`, satellites) | reply, typing |
| `teams` | `Media::Teams` | Bot Framework messaging endpoint (`POST /webhooks/teams/messages`) | reply; post while `TEAMS_BOT_APP_ID` and `TEAMS_BOT_APP_PASSWORD` are set; `enabled: false` until the bot is registered (see [Teams](#teams-the-same-network-on-microsoft-teams)) |
| `slack` | `Media::Slack` | Events API webhook (`POST /webhooks/slack/events`) | reply; post while `SLACK_BOT_TOKEN` is set (see [Slack](#slack-one-app-posts-as-every-soul)) |

`Media.adapter(key)` returns a medium's adapter (`Media::REGISTRY`). A medium's
failure is a `Media::Error`. Not to be confused with `AgentMailbox::Media`
(`bin/lib/agent_media.rb`), the dispatcher's file handling: it lives only in the
Rails-free `bin/lib` process, and inside `module AgentMailbox` the bare name
`Media` means it, never this registry.

**A reply always goes back on the medium the message arrived on.** The reply and
typing jobs read the row's own `channel`, never a home. A medium that cannot
reply is left alone, as an unknown one is.

**Homes are for standalone posts**, the ones nobody replied to. Each reads its
home from `config/agent_media.yml` through `Media.home` and posts with
`Media.post(home, content:, embeds:, nonce:)`:

| Poster | Purpose | Home today |
|--------|---------|------------|
| `AgentMessages::FloorAlert`, `ChangeBuilds` ops line | `floor_alert` | discord `#ops` (`lobster-tank`), as the shared bot |
| `Release::Conductor`, `POST /api/v1/release_notes` | `release_notes` | discord `#releases`: `DISCORD_RELEASE_NOTES_WEBHOOK_URL`, else `DISCORD_DEPLOY_WEBHOOK_URL` |
| `AppRequestDiscordJob` | `app_requests` | discord `#external`: `DISCORD_EXTERNAL_WEBHOOK_URL` |
| `ReportDestinations`, a key with no row | `reports` | discord, no channel: stays `:not_configured`; a row chosen in admin always wins |

**Resolution.** `Media.home(purpose:, app:, soul:)` takes the first of purpose →
soul → app → defaults that has an entry; its `medium` and `channel` (else the
defaults') make the home. A medium whose block is missing or `enabled: false`,
or whose adapter cannot post, is skipped for its `fallback` (else
`defaults.fallback`) under the same channel name, and the walk is logged once per
process, so a half-set Slack never silences the floor alert. A Discord channel is
an `id` (the bot posts to it) or a `webhook_env` (an ENV name, or a list tried in
order; the URL never lives in the file).

**Switching an app's, a soul's or a purpose's medium is one YAML edit**: set its
`medium:` in `config/agent_media.yml`, once that medium's block is `enabled: true`
and names the channel. To switch everything, change `defaults.medium`. No code
changes, and replies are unaffected. Inbound "who answers" stays in
`config/agent_routes.yml`. The dispatcher does not read `agent_media.yml`, so a
change there needs a hub deploy, not a dispatcher restart.

## Slack: one app posts as every soul

Plan: `.agents/epics/omnichannel-media.md` (cards 3 and 4, folded into
`slack-medium-loop`). One Slack app, **McRitchie Agents** (`A0CDCN1Q9AS`, bot
user `U0CE93ACBA4`), in the McRitchie Studio workspace (`T0CC9DQ9NAK`), posts
as every soul: each message carries the soul's name and portrait
(`chat:write.customize`). Discord keeps running beside it; every standalone
purpose stays on Discord until the cutover (card 6).

**Inbound.** Slack's Events API posts to `POST /webhooks/slack/events`
(`Webhooks::SlackEventsController`). The request is verified first, the whole
security story of a public endpoint: `X-Slack-Signature` must equal
`v0=` + hex HMAC-SHA256 of `v0:<X-Slack-Request-Timestamp>:<raw body>` keyed by
`SLACK_SIGNING_SECRET`, compared in constant time, and the timestamp must be
within five minutes (`AgentMessages::SlackSignature`). An unsigned, mis-signed or
stale request gets a 401 and nothing is enqueued, the `url_verification`
handshake included. A signed `event_callback` is acked at once and handed to
`SlackIngestJob`, because Slack retries any event it has no 2xx for within three
seconds.

`AgentMessages::SlackIngest` stores an addressed message once:

| Column | Value |
|--------|-------|
| `channel` | `slack` |
| `external_id` | `<channel id>:<ts>` (a ts is unique only in its channel); the `(channel, external_id)` unique index dedupes Slack's retries and the message + `app_mention` pair one mention produces. A fan-out's further rows are `<channel id>:<soul>:<ts>` (see **Several souls at once**) |
| `guild_id` | the team id |
| `channel_ref` | the channel id (`C…`, `G…`, `D…`) |
| `thread_key` | `slack:<channel>:<thread_ts or ts>`: a Slack thread is one conversation |
| `envelope` | `channel_type` (`im` for a DM: `MemoryBundle#private_channel?`), `event_id`, `thread_ts`, and on a fan-out's rows `fan` (the primary row's `external_id`) |

Never stored: another workspace's events, anything a bot wrote (`bot_id`,
`bot_profile`, subtype `bot_message`, or the app's own user: our own customized
posts come back as events, as do the Steffon Admin app's), edits, deletes, joins
and every other subtype, a muted channel, and an unaddressed message.

**Routing** reads the `slack:` block of `config/agent_routes.yml`
(`AgentMessages::SlackRoutes`); the first rule that matches wins:

1. **Name.** The text, past a leading `@McRitchie Agents`, opens by addressing a
   soul's `names`: `Avi, …`, `Avi: …`, `Hi Avi, …`, `@Avi …` (the email matcher,
   `EmailRoutes.addressed_to?`), or several souls, or everyone (below).
2. **Thread.** A reply in a thread the mailbox holds keeps that thread's soul.
3. **Mention.** An `@McRitchie Agents` mention (or an `app_mention`) or a DM to
   the app goes to `mention_soul` (`alex`).
4. **Channel default.** The channel override's `default_soul`. `#general` has none.

**Several souls at once** (Alex McRitchie, 2026-10-30: "I should be able to send a
message that might trigger multiple agents to respond"). `SlackRoutes#addressed`
reads a list of names at the start of the text:

| Opening | Souls |
|---------|-------|
| `Avi and Mason, …` · `Avi, Mason: …` · `Avi & Mason: …` | avi, mason |
| `Avi, Mason and Carl …` · `Avi, Mason, and Carl, …` | avi, mason, carl |
| `@Avi @Mason …` · `@Avi and @Mason …` | avi, mason |
| `Avi, Mason said it shipped` | avi only: a list needs a closing `,`/`:`, all `@`s, or the `A, B and C` form |
| `Avi and Mason are right` · `I asked Avi and Mason, …` | nobody: a name mid-sentence is never an address |
| `Everyone, …` · `All: …` · `Agents, …` · `Hi everybody, …` · `<!channel>` `<!here>` `<!everyone>` | every soul served on Slack and cleared in the channel (`SlackRoutes#everyone_in`): in `#general` all twelve; in an app channel the cleared ones only, the rest named on the `routed` event's `not_cleared` |

The message is stored once per soul, in one transaction, every row in the
message's thread, so each soul replies under the one message. The first-named
soul's row keeps `<channel>:<ts>`, so the dedupe lookup and every row stored
before fan-out are unchanged; each further soul's row is `<channel>:<soul>:<ts>`
(the ts stays the last segment, which `Media::Slack#message_url` reads). A
retry or the `app_mention` twin finds the primary and gets every row or none; a
racer that loses the insert rolls back whole. Clearance and the owner-only guard
apply per soul: an uncleared or recognized-only soul's row is `held`, the others
proceed.

Fanned rows share `envelope.fan` (`AgentMessage::FAN_KEY`), and the claim's
thread rule ("no older open message in this thread") skips a row's own
siblings, so up to the dispatcher's cap answer side by side instead of in series
(twelve answers in a row would trip the floor alert's ten-minute wait). A later
message in the thread still waits for every open sibling. A sibling's thread
memory leaves the other siblings out (same text, racing answers).

**A follow-up in a fan-out thread.** A reply that names a soul goes to that soul.
An unnamed reply goes to the thread's first-named soul that is not held
(`SlackIngest#thread_row`): Slack threads are flat and an event never says which
bot reply it answers, so the first name is the deliberate default.

**Clearance** (Alex McRitchie, 2026-10-30: "some agents may not have clearance
for public conversation"). Routing picks a soul; clearance decides whether that
soul may answer in this channel (`SlackRoutes#cleared?`). A channel override may
carry:

| Config | Who may answer there |
|--------|----------------------|
| `open: true` | every soul (`#general`) |
| `souls: [...]` | the block's `core_souls` (alex, steffon, mason, mack, avi: the McRitchie Studio agents, who move all around) plus the souls listed |
| neither | every soul: no clearance config is today's behaviour (`#ops`, `#releases`, a DM) |

A message routed by any rule (name, thread, mention or default) to a soul not
cleared in its channel is stored `held`, never answered. Its `held` event
(actor `slack-clearance`) carries the reason, `soul not cleared for this
channel: <soul> may not answer in #<channel>; cleared there: …`, and the
`cleared` list; when the sender is also not an answered role, the one event names
both causes. It is the same `held` status the owner-only guard uses, so the admin
page shows the reason and an admin's **Release and answer** is the one override.
Tyrion is client-facing: he answers in the open `#general`, Alex McRitchie's
private playground with the agents, but is never listed in an app channel's
`souls:`.

**The channel layout** (created by Steffon, 2026-10-30):

| Channel | Clearance | Default soul |
|---------|-----------|--------------|
| `#general` `C0CD8ETBZBM` (was `#agents-general`) | open: every agent, and where Alex McRitchie talks to all of them | none |
| `#turf-monster` | core + `turf_monster` | `turf_monster` |
| `#cyvasse` | core + `tywin` | `tywin` |
| `#commercial-welding` | core + `hank` (recognized only: held, he has no role doc yet) | none |
| `#alex-build` | core (`alex` is its builder) | none |
| every other app channel (`#mcritchie-studio`, `#mcritchie-industries`, `#rolio`, …) | core only | none |
| `#ops`, `#releases` | no clearance config | none |

**The #general rule.** Every soul with a role doc answers on Slack by name, and
so in `#general`: `Alex`, `Avi`, `Carl`, `Jasper`, `Mack`, `Mason`,
`Pokemon`/`Pokémon`, `Shannon`, `Steffon`, `Turf`, `Tyrion`, `Tywin`. Each answers
from its `docs/agents/agents/<soul>/role.md` on the dispatcher's respond path.
`client_cto` is not a Slack name. A name under `slack.recognized` (`Hank`, who
has no role doc yet) is routed to its soul and held with `soul cannot answer
yet`: no dispatcher serves it on Slack, and without the entry "Hank, …" would
fall through to the channel default and be answered by the wrong soul. Moving a
soul from `recognized:` to `souls:` lets it answer (and makes `bin/dispatcher`
serve it). In an app channel, clearance still decides: a soul named there that
is not cleared is held.

The owner-only guard is Discord's: a routed message from a role
`config/agent_answerers.yml` does not answer is stored `held`. Alex McRitchie's
Slack user (`slack.owner_user_id`, `U0CCSMUMQJV`) is a `slack` identity of the
owner person (`AgentPerson.seed_owner!`, migration `LinkOwnerSlackIdentity`), so
his messages are answered. `bin/dispatcher` serves every soul the block routes
to (`AgentMailbox.routed_souls`), and `--channel slack` narrows a run to Slack.

**Replies** (`Media::Slack#deliver_reply`) post one `chat.postMessage` in the
message's thread (`thread_ts` is the thread's root), as the soul: `username` from
`Media.display_name`, `icon_url` an absolute PNG under
`https://mcritchie.studio/slack-icons/` (or `agent_media.yml`
`souls.<soul>.icon`). Markdown is converted to Slack mrkdwn
(`Media::Slack::Format`). Slack has no typing indicator for a bot, so typing is
off; `AgentMessage#reply_url` is the Slack permalink
(`<workspace_url>/archives/<channel>/p<ts>`).

**No nonce, so no blind retry.** `chat.postMessage` has no idempotency key. The
adapter locks the row, records `reply_sending`, then posts:

| Outcome | Meaning | What happens |
|---------|---------|--------------|
| posted | Slack returned `ok` and a ts | `reply_external_id` set; no job posts again |
| `Media::Slack::NotPosted` | provably not posted: HTTP 429 (Retry-After kept), `ratelimited`, `service_unavailable`, a connection that never opened | `reply_not_posted` recorded, the error raised: the reply job's `retry_on Media::Error` tries again |
| `Media::Slack::Refused` | provably not posted, and a retry would be refused too: `channel_not_found`, `not_in_channel`, `invalid_auth`, … | `reply_failed`, no retry |
| `Media::Slack::Ambiguous` | it may have posted: a read timeout, a reset, an HTTP 5xx, `fatal_error`, `internal_error` | `reply_failed` with `ambiguous: true`, **never retried**: look in the channel |

A `reply_sending` with no outcome after it is a live attempt (younger than two
minutes: a second job leaves it alone) or a crashed one (older: failed as
ambiguous, never re-posted). With `SLACK_BOT_TOKEN` unset the reply is
`skipped` and recorded.

**Standalone posts.** `config/agent_media.yml`'s `slack` block is `enabled: true`
with three channels (`general` `C0CD8ETBZBM`, `ops` `C0CDEG43ECS`, `releases`
`C0CDJCN4L92`), but no purpose names Slack yet; a shipped release posts there
on its own block (`release_posts`, "Release posts" below). Slack can `:post` only while
`SLACK_BOT_TOKEN` is set; without it `Media.home` falls back to Discord. **To
flip release notes to Slack**, change `purposes.release_notes.medium` from
`discord` to `slack` (one line; the file marks it). Their Discord embeds become
minimal Block Kit (sections, fields, a footer context, at most 50 blocks a
message). The app must be a member of the channel (invite `@McRitchie Agents`)
or Slack answers `not_in_channel`.

**Release posts.** After a green prod verify, `bin/release announce` (the cycle
runs it) posts a shipped release: one summary in #general as Mason, one post
per shipped app in its channel as that channel's soul (its `default_soul`, else
Steffon), and the app's smoke verdict in that post's thread
(`ReleaseNotes::SlackAnnouncement`). The smoke runs in code on the conductor's
machine, because a dispatched soul cannot reach an app itself (a scoped run reads only its own scope); the soul only signs the verdict.
Each app post is stored as a `completed` message (`routed_by: release`) keyed to
its Slack thread, so a reply there routes to that soul like any thread reply.
Procedure: [`production-deploy`](../agents/steffon/sops/production-deploy.md),
"Tell the release on Slack".

### Noise rules

Slack is shared space; an agent speaks there only when it adds information.

- **One message per release per channel**: the #general summary, one post
  in each shipped app's channel, and that post's smoke verdict in its thread.
- **Green is one line.** Red says what failed with its evidence and @-mentions
  Alex McRitchie.
- **Agents do not reply to agents** unless Alex McRitchie names them. Bot-authored
  Slack events are never ingested, so one agent's post cannot wake another.
- **The caps** (`config/agent_media.yml` `limits:`, `Media::Limits`), enforced at
  each medium's outbound seam, `Media::Slack`'s and `Media::Teams`' `#post` and
  `#deliver_reply` (through `Media::OnceDelivery`), never in a prompt, and counted
  from the shared `slack_posts` ledger (`SlackPost`, its `medium` column keeping
  Slack's and Teams' counts apart), so the conductor's `heroku run` and the reply
  job see the same counts:
  - **6 posts per soul per channel per rolling hour.** Release posts are exempt but
    counted; an answer to a message Alex McRitchie wrote himself is too
    (`owner_replies_count_only`): his own question is never noise.
  - **4 agent posts in one thread** since Alex McRitchie last wrote in it. Nothing
    is exempt; his next message resets it.
  - **Over a cap** nothing is sent. The ledger row is `suppressed` with the reason;
    a reply's message gets `reply_status: skipped` and a `reply_suppressed` event
    naming the cap, and nothing retries it. A soul-less post (an alert, a report)
    is recorded, never capped.

**Not built yet:** go / no / change on a proposal is Discord's and email's
(`AgentMessages::ProposalConfirm`); on Slack such a word in a thread is routed to
the thread's soul as an ordinary message. Slack user groups (`@avi` handles),
channel sync into the directory, and the setup kit are card 5.

**Go-live** (Steffon, after the deploy that carries this): set the Heroku vars
and add the event subscriptions, in
[`discord-bot-setup.md`](../agents/steffon/sops/discord-bot-setup.md#slack-go-live-mcritchie-agents).

### Scoped runs: the owner's terminal in Slack

Epic `.agents/epics/slack-terminal-scope.md`, card 1 (Alex McRitchie, 2026-10-31:
"when we are in the MS slack I want to be able to interact with agents like I'm
talking in terminal. Mason should be able to review logs and have an educated
opinion. Same with Mack."). Every other answer on every channel is still the
no-tools run above; a scoped run is the one exception.

**The gate** (`AgentMailbox::Scopes.grant`, `bin/lib/agent_scope.rb`). The
dispatcher gives a message read-only tools only when every check holds; the
first that fails is the run record's `run_meta.scope` (else `granted`):

| Check | Reason when it fails |
|-------|----------------------|
| the soul has a scope in `config/agent_scopes.yml` | `no_scope` |
| the message is on Slack (`defaults.channels`) | `channel` |
| the board's audience is `owner` (resolved from the verified sender's person; a name in the text sets nothing) | `not_owner` |
| `author_ref` is `slack.owner_user_id`, the platform id Slack's signed event carried | `not_owner_user` |
| it is not a released hold | `released_hold` |
| the soul is cleared in the channel (the `SlackRoutes#cleared?` rule, re-read without Rails) | `not_cleared` |
| the message and every earlier thread turn are the owner's own words, with no quoted or forwarded material (`WarmSession.quotes?`) | `quoted` |

A scoped run is never warm, and skips the soul's one read action. The Responder
checks the audience again, so a grant handed in for anyone but the owner runs the
no-tools command.

**The tools.** `claude -p` keeps every built-in tool off (`--tools ""`; no Bash,
Read, Write, Edit or WebFetch) and gets ONE local MCP server, `bin/agent-scope-mcp`
(`AgentMailbox::Scopes::Server`), named in an inline `--mcp-config` with
`--strict-mcp-config`, `--allowedTools mcp__scope__…`, the built-ins named again
in `--disallowedTools`, `--permission-mode dontAsk` and `--max-turns`
(`defaults.max_turns`, 12). Measured against claude 2.1.316: `--safe-mode` turns
MCP servers off, `--mcp-config` included, so a scoped run swaps it for
`--restricted` (user, project and local settings files ignored, with their hooks,
permission rules and plugins) plus `--disable-slash-commands`. The server's four
tools are the soul's scope and nothing else:

| Tool | What it can reach |
|------|-------------------|
| `lookup` | a bounded board read by name (`Scopes::LOOKUPS`: params and bounds in code), served by `GET /api/v1/agent_messages/:id/lookup` |
| `run_command` | a listed command: an exact argv prefix (`bin/…`) plus at most `max_args` arguments, each matching its anchored pattern, run with no shell under the child-env allow-list |
| `read_file`, `list_files` | files matching the soul's `paths` globs in the hub checkout; `deny_paths` (`.env*`, keys, `credentials*`, `.git`, `log`, `tmp`, `storage`) wins, the path as written is checked before its real path, and a symlink out of the checkout is refused |

Every result is capped (`output_limit`) and scrubbed by `AgentMailbox::Redact`
(provider token prefixes, bearer headers, database URLs, `NAME_SECRET=value`,
long hex or base64 runs, private key blocks) before Claude sees it. Nothing can
write: the endpoint is a GET, the commands are reads, the file tools open
read-only; a change is still a proposal. The prompt (`ContextBuilder::SCOPED_ASK`)
tells the soul its tools by name (`Scopes.describe`) and to answer with evidence;
an unscoped internal answer's `INTERNAL_ASK` says tools run only for Alex
McRitchie on Slack.

**The lookup endpoint** checks the floors again on the board, whatever the
dispatcher decided: holder only (409 `NOT_HOLDER`); Slack only, owner person,
`author_ref` the configured owner id, never a released hold, cleared in the
channel (403 `NOT_SCOPED`); only a lookup the soul's scope names, inside the
catalog's bounds (422 `LOOKUP_REFUSED`). Each lookup run is an
`AgentMessageEvent` `scoped_lookup` with its name and params, never its answer.
The queries are `AgentScopes::Lookups`: code, never model-written SQL;
satellites are read only through their health endpoint
(`DailyAppReport.health_for`, short timeouts, a few threads), whose error
messages the engine already redacts.

**Card 1's scopes:**

| Soul | Lookups | Commands | Paths |
|------|---------|----------|-------|
| Mason | `error_groups` (every live app's health report, grouped by app, class and redacted message, 1-3 days), `gate_failures`, `review_findings`, `grades`, `board_status`, `recently_shipped`, `release_status` | `bin/task list`, `bin/task show` | `docs/agents/**/*.md`, `config/agent_*.yml`, release, shape and chart config |
| Mack | `books_status`, `books_unclassified`, `books_month` (totals per category and kind), `usage` | none | `config/books.yml`, the chart, his own docs, `agent-usage.md` |
| Turf (card 3) | `turf_contests` (Turf Monster's recent contests through its operator endpoint: weeks, format, state, entries, paid entries; scope open or all, up to 25), `usage` | none | the Turf Monster domain doc and its own docs |

`books_status` here reads the database only; the Drive Inbox stays
`bin/books status`'s. **Bounds:** each tool call `tool_timeout` (45 s); the run is
the cold run's `CLAUDE_TIMEOUT`, so `RUN_DEADLINE` covers it unchanged; the
dispatcher's cap of five applies. **Adding a soul** is a reviewed edit to
`config/agent_scopes.yml` (a lookup the code does not know, a relative-climbing
path, an unanchored argument pattern or a non-`bin/` command refuses to load);
a new lookup is a `LOOKUPS` entry plus its query in `AgentScopes::Lookups`.
Tests: `test/lib/agent_scope_test.rb`, `agent_scope_server_test.rb`,
`agent_scope_prompt_test.rb`, `test/services/agent_scopes/lookups_test.rb`,
`test/integration/agent_scoped_run_test.rb`.

## Teams: the same network on Microsoft Teams

Plan: `.agents/epics/teams-medium.md` (card 1, `teams-medium-loop`). Alex
McRitchie, 2026-10-30: "build out the same communication network as slack but
for Microsoft Teams." One bot, **McRitchie Agents**, posts as every soul, with
the same names, several-souls and everyone addressing, clearance, core souls,
fan-out and noise caps as Slack: those are shared code, not a copy. **Disabled
until card 2** (`teams-app-kit`) registers the bot: with the credentials unset
the endpoint answers 503 and nothing is read or posted.

**How it maps to Slack.**

| Slack | Teams |
|-------|-------|
| `POST /webhooks/slack/events`, HMAC-signed (`SlackSignature`) | `POST /webhooks/teams/messages`, a Bot Framework JWT (`AgentMessages::TeamsAuth`) |
| `SlackIngestJob` → `SlackIngest` | `TeamsIngestJob` → `TeamsIngest` |
| `slack:` block, `SlackRoutes` | `teams:` block, `TeamsRoutes`; both are `AgentMessages::ChannelRoutes` |
| routing, clearance, held, fan-out in `SlackIngest` | the same `AgentMessages::ChatIngest`, included by both |
| per-message `username` + `icon_url` | an Adaptive Card headed with the soul's name and portrait (Teams lets a bot set no per-message name) |
| `chat.postMessage` with `thread_ts` | Bot Connector `POST {serviceUrl}/v3/conversations/{conversationId}/activities/{activityId}` |
| `SLACK_BOT_TOKEN` | an app-only token minted from `TEAMS_BOT_APP_ID` / `TEAMS_BOT_APP_PASSWORD`, cached until 5 minutes before expiry |
| owner `slack.owner_user_id` | owner `teams.owner_aad_object_id` (Entra object id, `from.aadObjectId`) |
| channel ids `C…` | channel conversation ids `19:…@thread.tacv2` |
| `slack_posts` rows | `slack_posts` rows with `medium: teams` |

**Inbound.** Every request carries `Authorization: Bearer <JWT>` signed by the
Bot Connector. `TeamsAuth` checks every requirement Microsoft lists: the Bearer
scheme; RS256 with a `kid`; `iss` exactly `https://api.botframework.com`; `aud`
our app id; `exp`/`nbf` with Microsoft's 5-minute skew; the signature against a
key from the JWKS that the OpenID metadata
(`https://login.botframework.com/v1/.well-known/openidconfiguration`) names; the
`serviceUrl` claim equal to the activity's `serviceUrl`; and the key's
`endorsements` including the activity's `channelId` (`msteams`), else 403. Keys
are cached per process for 12 hours (Microsoft: refresh at least daily); an
unknown `kid` refetches once, at most once per 5 minutes. A failure is a 401
(403 for the endorsement) and nothing is enqueued; the log names the reason,
never the token. A verified `message`, `conversationUpdate` or
`installationUpdate` is acked at once and handed to `TeamsIngestJob`.

`AgentMessages::TeamsIngest` stores an addressed message once:

| Column | Value |
|--------|-------|
| `channel` | `teams` |
| `external_id` | `<channel>:<activity id>`; the `(channel, external_id)` unique index dedupes the Bot Framework's retries. A fan-out's further rows are `<channel>:<soul>:<activity id>` |
| `guild_id` | the tenant id |
| `channel_ref` | the conversation's base id: a channel's `19:…@thread.tacv2` (without `;messageid=`), or a chat's own id |
| `thread_key` | `teams:<channel>:<root id>`: a channel thread is one conversation, keyed by the root in `conversation.id`'s `;messageid=` |
| `envelope` | the reply's reference (`service_url`, `conversation_id` with the thread, `activity_id`, `from_id`), `conversation_type` (`personal` for a chat with the bot: `MemoryBundle#private_channel?`), `tenant_id`, `team_id`, `thread_root`, and on a fan-out's rows `fan` |

Never stored: another tenant's activity (with no tenant configured, nothing is
read), anything a bot wrote (`from.id` `28:…`, `from.role` bot, or our own bot;
Teams delivers no bot's messages even under RSC, and the ingest checks anyway),
every type but `message`, a message with no text, a muted channel, an
unaddressed message. The bot's own `<at>McRitchie Agents</at>` mention (the
mention entity whose `mentioned.id` is `28:<app id>`) is stripped before routing,
so `@McRitchie Agents Avi, …` reads `Avi, …`; another `<at>Name</at>` is kept as
`@Name`, and HTML a formatted message carries is reduced to its text.

**Routing, clearance, several souls, the owner-only guard** are Slack's, read
from the `teams:` block: names, then the thread's soul, then `mention_soul` for
an @mention of the bot or a personal chat, then the channel's `default_soul`.
The block's souls, names, `recognized` and `core_souls` equal Slack's
(`test/services/agent_messages/teams_routes_test.rb` pins them). A held row's
event actor is `teams-clearance`. `bin/dispatcher` serves the block's souls
(`AgentMailbox.routed_souls`), and `--channel teams` narrows a run.

**Replies** (`Media::Teams#deliver_reply`) post ONE Adaptive Card (schema 1.5;
Teams supports 1.6 or earlier) to the inbound activity, in its channel thread:
a header with the portrait (the PNG under `/slack-icons/`, as Slack uses) beside
the soul's display name, then the answer in a wrapped TextBlock (Markdown's
bold, italics, lists and links render), clipped at 20,000 characters to stay well
under Teams' ~100 KB (80 KB safe) message limit. The retry policy is Slack's,
through the shared `Media::OnceDelivery`:

| Outcome | Teams answer | What happens |
|---------|--------------|--------------|
| `NotPosted` (retried) | HTTP 429 (Retry-After kept), 412, 401 (the cached token is dropped), any failure minting the token, a connection that never opened | `reply_not_posted`, raised for the job's retry |
| `Refused` | 400, 403 (blocked, not installed), 404, 413, a `serviceUrl` that is not a Bot Connector host, a row with no reference | `reply_failed`, no retry |
| `Ambiguous` | any 5xx, a read timeout, a reset, a TLS error, a 2xx that is not the Connector's JSON | `reply_failed` with `ambiguous: true`, never re-sent |

Microsoft's rate-limit page says to retry 502 and 504 too; they stay ambiguous
here, because a gateway timeout cannot prove the message was not delivered and
the Connector has no idempotency key. The bot token is sent only to a
`serviceUrl` on `smba.trafficmanager.net`, `*.botframework.com` or
`*.teams.microsoft.com`/`.us`. `AgentMessage#reply_url` is nil on Teams for now
(a message deep link needs the team's group id, which card 2 settles), and
typing is off, as on Slack.

**Conversation references and posts.** A proactive post needs a channel's
`serviceUrl` and conversation id, which only an activity from it carries.
`TeamsIngest` records a `TeamsConversation` (status `installed`/`removed`) from
the install `conversationUpdate` (the bot in `membersAdded`), `installationUpdate`
add/remove, a `channelCreated` event, and every message it reads.
`Media::Teams#post` (a home on `teams`, its channel `id` the conversation id)
opens a new thread (`POST /v3/conversations` with `channelData.channel.id`) and
puts further cards in it, or posts in `thread_ts`'s thread; a keyed post goes
out once; the caps apply. `config/agent_media.yml`'s `teams` block stays
`enabled: false`, so `Media.home` falls back to Discord.

**The caps** are the one `limits:` block, counted per medium from the ledger's
`medium` column: a soul's six an hour are per channel, and a channel is on one
medium. Until `teams.owner_aad_object_id` is set no Teams message is Alex
McRitchie's, so the thread cap never resets on Teams and his questions get no
exemption (the stricter side).

**What card 2 (`teams-app-kit`, Steffon) must set up**, and which steps need a
tenant admin's click:

| Step | Who |
|------|-----|
| A Microsoft 365 tenant with Teams where Alex McRitchie is a global admin | Alex McRitchie (buying one is his call) |
| An Entra app registration for the bot (single-tenant), a client secret | Steffon, scripted once he holds an admin credential |
| An Azure Bot resource on that app id, messaging endpoint `https://mcritchie.studio/webhooks/teams/messages`, the Microsoft Teams channel enabled | Steffon |
| A Teams app package (manifest: the bot id, `team`, `groupChat` and `personal` scopes, RSC `ChannelMessage.Read.Group` so the bot reads every channel message without an @mention), uploaded to the org catalog | Steffon builds it; the upload or its approval is a **tenant admin click** |
| Install the app in the McRitchie Studio team (its RSC consent) | the **team owner's click** at install (RSC is consented per team) |
| The admin Entra app for Graph `Channel.Create` (application permission), channels mirroring Slack's layout (general + one per app) | Steffon; Graph application permissions need a **global admin's consent click** |
| Heroku `TEAMS_BOT_APP_ID`, `TEAMS_BOT_APP_PASSWORD`, `TEAMS_TENANT_ID`; 1Password `teams.mcritchie-studio.applications` and `teams.studio.admin` | Steffon |
| `config/agent_routes.yml` `teams.tenant_id`, `bot_app_id`, `owner_aad_object_id`, and `teams.channels` keyed by conversation id with Slack's clearance; `agent_media.yml` `teams.channels` and `enabled: true`; a data migration linking the owner's Entra id to the owner person (as `LinkOwnerSlackIdentity` did for Slack: `AgentPerson.seed_owner!` alone does not reach production) | the card's PR |

Docs checked 2026-10-30 (learn.microsoft.com):
[Bot Connector authentication](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-authentication),
[send and receive messages](https://learn.microsoft.com/en-us/azure/bot-service/rest-api/bot-framework-rest-connector-send-and-receive-messages),
[channel and group conversations](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/conversations/channel-and-group-conversations),
[receive all messages with RSC](https://learn.microsoft.com/en-us/microsoftteams/platform/agents-in-teams/enable-receive-all-chat-messages),
[proactive messages](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/conversations/send-proactive-messages),
[creating a channel conversation](https://learn.microsoft.com/en-us/previous-versions/microsoftteams/platform/resources/bot-v3/bot-conversations/bots-conv-proactive),
[conversation events](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/conversations/subscribe-to-conversation-events),
[rate limits](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/rate-limit),
[cards reference](https://learn.microsoft.com/en-us/microsoftteams/platform/task-modules-and-cards/cards/cards-reference),
[message formatting and size](https://learn.microsoft.com/en-us/microsoftteams/platform/bots/how-to/format-your-bot-messages).

## Memory: the context layers

An answer remembers the person it answers, on every channel they use. The
memory is rebuilt from the hub's rows on every answer, never from a resumed
Claude session, so any dispatcher on any machine builds the same context for the
same rows (Alex McRitchie's decision of 2026-10-14, option A). The one exception is a warm
domain's owner and team turns, behind a per-domain flag that is off ("Warm
sessions" below); even those rebuild the audience, rules and thread per message. On 2026-10-15 Alex McRitchie dropped
the per-channel silo: "Let's give continuity for our people over omnichannel."
The channel still matters in one way. The thread a message continues is the focus
of its answer. Two pieces build the memory:

- **The board chooses what.** `GET /api/v1/agent_messages/:id/context?worker=W`
  answers only the worker holding the claim (409 `NOT_HOLDER` otherwise, since
  the bundle carries other messages' text). `AgentMessages::MemoryBundle` builds it.
- **The worker lays it out.** `AgentMailbox::ContextBuilder`
  (`bin/lib/agent_context_builder.rb`) renders five labeled layers, and a sixth,
  GOOGLE, for an owner only, each held to a
  character budget in `ContextBuilder::BUDGETS` (the one place they live).

| Layer | What | Source | Budget |
|-------|------|--------|--------|
| GENERAL | Who the soul is, who it is speaking with, and that audience's rules | `docs/agents/agents/<soul>/role.md` for owner and team (`public.md`, else one line, for anyone else); the rules from the `agent-communication` SOP | 6,000 (rules 3,000) |
| DOMAIN | The business it answers for | `config/agent_domains.yml` maps soul → domain → doc (`docs/agents/domains/`); no mapping, a missing doc, or an `internal: true` domain for a client or the public is an empty layer | 4,000 |
| USER | The notes about the sender, from every channel, each with its date and source: every soul's for an owner or team sender, the answering soul's domain's only for a client or the public ("Whose memory") | `agent_person_notes` for the message's person (`AgentPersonNote.visible_for`) | 2,000 |
| PERSON | The sender's earlier exchanges with this soul on every channel, each labeled with its place | `agent_messages` by `(soul_slug, person_id)`: the summary, then the recent turns | 9,000 (summary 3,000) |
| THREAD | The conversation being answered | `agent_messages` by `thread_key`, this channel and guild only | 6,000 |
| GOOGLE | Only for an owner (below, "The Google layer"): a read-only snapshot of their own Google, printed after USER | `GoogleConnect::OwnerContext` through the existing readers | 4,000 |

HOW TO ANSWER, between DOMAIN and USER, is code-written rules, not a layer. Its
second line is `ContextBuilder::STE80_RULE`: write the reply in STE-80, plain
technical English at about 80% of ASD-STE100, for every soul and audience
([`../modules/plain-technical-english.md`](../modules/plain-technical-english.md)).

**The Google layer.** The bundle's `google_context` is a small read-only
snapshot of the sender's own connected Google: the next 7 days of calendar
events (title, start, end, attendee count; at most 20), the 10 newest Gmail
messages (from, subject, date, Google's snippet; never a body), and the 10
most recently modified Drive files (name, type, modified). Each section appears
only for an ability the account granted. A revoked grant, or a token the app
can no longer decrypt, is a note to reconnect on /integrations; any other
failure is a "could not be read just now" note. Nothing raises, and no token
reaches the bundle or the log; each failure is recorded in ErrorLog with
token-shaped text redacted. One build has a 6-second budget for every Google
call together (`OwnerContext::BUDGET`): a section not finished in time is a
"not available right now" note, so the context request never nears Heroku's
30-second limit. A snapshot is cached per owner, keyed on every connection's
id, scope and change time, so a disconnect or a dropped ability here shows on
the next message. Two cache gaps, on purpose:

- A grant revoked at Google itself (not on /integrations) keeps showing the
  cached snapshot for up to 5 minutes (`TTL`).
- A snapshot carrying a "could not be read" or "not available right now" note
  is cached too, for 1 minute (`DEGRADED_TTL`), so an outage costs one
  budgeted build a minute rather than one per message.

It is gated on the board (`MemoryBundle#google_reader`), fail closed, to the
OWNER of what the soul answers for, two ways:

- **A client CTO's app owner** on that app's own CTO thread
  (`Answerers#app_owner_thread?`: the web channel, the thread key built for
  that user, the app's CTO soul, an owner `AppMembership`), answered as the
  app's client. It reads that user's own connections only.
- **An admin owner on a hub soul** (any soul but `client_cto`): the owner
  audience, a person holding the owner role, and a hub user who is an admin,
  on a PRIVATE channel only (`MemoryBundle#private_channel?`): the hub's web
  chat, an email that passed DKIM and DMARC, or a Discord DM (the gateway drops
  DMs today, so none arrives). Never a shared guild channel: calendar items and
  mail snippets, one-time codes among them, would post where members read. It
  reads the household's connections (`GoogleConnection.household`, the set
  /admin/google shows).

Everyone else gets none, even with their own Google connected: a public
visitor on the same app, another app's owner, a client or team sender, an
admin on a client app's CTO chat, an admin in a guild channel or by
unverified email, a /build thread, and a sender with no hub user. Subjects, snippets, titles and file names are written by strangers, so
the worker prints the snapshot inside the untrusted fence, under one
code-written line saying it is data, not instructions, and prints it only for
an owner or client audience even if a bundle somehow carried it. A message
whose bundle carries it is never answered warm: one warm session per domain
is shared by owner and team senders, so the snapshot would persist into a team
turn. `WarmSession.eligible?` is false for it, and a resumed prompt cuts USER
before GOOGLE besides.

**The person.** A person is one identity across platforms. `agent_people` holds
the display name and, optionally, the hub `User`. `agent_person_identities` holds
each place the person speaks, as `(platform, external_id)`: a Discord user id,
or a verified email address (below, "Email"). The pair is unique, so one id is always one person.
Every stored message with an author is stamped with its `person_id` when it is
created (`AgentMessage` calls `AgentPerson.resolve!`), and the first message from an
unknown id makes a new person. The migration backfilled every existing row from
`(channel, author_ref)` and seeded Alex McRitchie's Discord id (`536552944271753216`) as
"Alex", linked to the hub user whose email is `alex@mcritchie.studio` when one
exists.

**No auto-merging.** Nothing joins two identities into one person on its own. An
email that shares a name with a Discord user stays a separate person until an
operator links it, because a wrong merge would hand one person's memory to
another. Linking is an explicit act, done from the console or with the rake task.
It restamps every stored message from that id, so their history joins the PERSON
layer at once:

```bash
bin/rails agent_people:list
bin/rails agent_people:link PERSON=<id> PLATFORM=email EXTERNAL_ID=alex@mcritchie.studio
```

An id that already belongs to another person is refused unless `REASSIGN=1` is
passed. A reassign moves the identity, its messages, and the notes those messages
produced (each note's `source_message`). A note is a fact taken from the words of
the message it came from, so it belongs with whoever wrote that message; left
behind, the old person would keep facts that were never about them, and every
soul would repeat them. A moved note the new person already has is dropped
rather than duplicated, and the new person is pruned to 30. A note with no
source message cannot be attributed and stays put. There is no admin button for
linking yet.

**The PERSON layer** is every earlier row with the same `(soul_slug, person_id)`,
oldest first, read through `index_agent_messages_on_person_ledger` and capped at
200 rows. Each turn carries its place, for example `[discord #release-notes]`.
Another person's messages are never in it. Claims serialize per person per
soul (`AgentMessage.claimable`): a person's second message waits until their first
is answered, on any channel, so the second answer's context always carries the
first exchange. A message to another soul is not held back, and neither is a
row with no person (no author id).

**Place labels** are printed outside the untrusted fence, so they are
code-shaped and carry nothing a member chose. A channel is named from the channel
directory (`DiscordChannel`; its name is set by the guild's admins) and kept to
`[a-z0-9_-]`. A thread is named by its parent channel (`[discord thread in
#desk]`), because anyone can name a thread. A channel the directory does not know
is labeled by its id. The worker replaces any label that does not match its
pattern.

**The THREAD layer is the focus.** It holds every earlier turn of the message's
`thread_key`, whoever wrote it, newest 20, oldest first. The prompt marks it "the
conversation you are answering" and tells the model to read a short or vague
message ("what's next?") inside it first. A Discord reply joins the thread of the
message it answers. Every message in a Discord thread channel shares one key,
`discord:<thread id>:<thread id>`. `DiscordIngest` knows a thread channel by the
parent the reader gives it, or from the channel directory. An email thread keys
by its root Message-ID (below, "Email"). The layer comes only from this channel
and guild: a Discord forward, or any reference into another channel, brings
nothing from there.
**A turn shown in the THREAD layer is not repeated in the PERSON layer.** Over
budget, the oldest thread turns fold first and the newest is cut rather than
dropped.

**Pruning** (PERSON). The last 10 turns that are no older than 7 days come back
verbatim. The 7 days are counted back from the message's own sent time, not from
the clock, so a rebuild next month is identical. Every older turn folds into the
**summary**: one extractive line per turn (its date and place, the first line of
the message, and the first line of the answer, each cut to 140 characters),
keeping the newest 40. The builder then fits the layer to its budget, dropping
the oldest turns first. A dropped turn is counted into the summary's header and
its line is not added. The summary's own oldest lines go next.

**Why extractive.** It is a pure function of the rows: deterministic, free (no
model call), and it stores no model-written text. A model-written summary saved
on a row would carry anything a message had injected into it forward into every
later answer to that person.

**Whose memory.** Notes are per person and scoped by app DOMAIN (Alex McRitchie,
2026-10-15). Each note records the domain of the soul that filed it, read from
the `souls:` map in `config/agent_domains.yml` (an empty domain for a soul the
map does not name). Who reads a note turns on the sender's role when the answer
is built, not when the note was filed (`AgentPersonNote.visible_for`):

- **Owner and team.** Every soul reads every domain's notes: a fact about Alex McRitchie,
  such as his favorite color, is true whichever agent hears it, so a note Turf
  files is in Avi's USER layer too. A fact filed in two domains is shown once.
- **Client and public.** A soul reads only the notes filed in its own domain.
  What a Turf client told Turf stays with Turf's souls; Avi, Alex and the other
  `mcritchie_studio` souls never see it, and Turf never sees what that person told
  Alex.

The conversation history (the PERSON layer) is per person per soul either way:
Avi does not see what Alex McRitchie told Alex.

**Notes.** The USER layer has a writer: the answer itself. The prompt lets the
model end its reply with a line reading exactly `===NOTES===`, then a JSON array
of up to 3 short facts about the sender, which may sit inside a ```` ```json ````
fence:

```text
Purple it is.
===NOTES===
["Favorite color is purple."]
```

The format is a delimiter because `claude -p --output-format json` puts the model's
whole text in the envelope's single `result` field. A split line keeps the answer
path unchanged, and an answer with no notes is untouched. The split is a pure
function the tests pin (`AgentMailbox::NoteBlock`).

**Where the cut falls.** Models do not always write the line exactly, so the
match is loose: `NoteBlock::DELIMITER_PATTERN` finds two or more `=`, the word
NOTES in any case, and optional markdown or spaces around it, anywhere in the
text. Mid-sentence (`Got it! ===NOTES=== [...]`), bold (`**===NOTES===**`) and
spaced (`=== notes ===`) all match, and the reply is cut at the first match.
With no delimiter at all, `NoteBlock::HEADED_TAIL` still cuts a reply that ends
in a heading line reading only "notes" (`**Notes:**`, `## NOTES`) followed by a
JSON array. The worker cuts before it completes and sends the facts as `notes`.
The board cuts again with the same module (`AgentMessage` requires
`bin/lib/agent_note_block.rb`), so the two sides share one pattern and one set of
test fixtures (`test/support/note_block_fixtures.rb`). When the worker sent no
facts (an older dispatcher, or a delimiter it missed), the board records the facts
it found in the section it cut.

**What is guaranteed.** Everything from the first loose delimiter on, or a
headed JSON tail, is never posted, even when its JSON is broken. A false match
only shortens a reply. What is not guaranteed: a fact the model writes into the
reply's own prose, with no delimiter and no heading, reads as the reply and is
posted as written. A bare JSON array ending a reply is not cut, because a reply
may legitimately end in one.

`AgentPersonNote.record_from!` then decides what is kept:

- **Only the message's author.** The facts are filed under the person who wrote
  the message being completed, and under nobody else. A fact about Alex McRitchie returned
  from Bea's run is Bea's note.
- **Plain short text.** A fact is 3 to 200 characters, whitespace folded, and is
  refused if it carries a link, an `@` (mentions and addresses), markup, a code
  fence, a control character, the fence marker, or a square bracket (`[` or `]`,
  with the fullwidth form and the 【】〔〕〘〙⟦⟧ lookalikes). Brackets are refused
  because the prompt prints a bracketed provenance label beside each note
  (`[noted 2026-10-14, message #12, discord #general]`), and a note carrying one
  could imitate it.
- **Never the machinery or authority.** A fact that reaches for the agent's
  machinery (system, prompt, instruction, rule, policy, guideline), claims
  authority (admin, permission, access, allowed, permitted, authorized, approved,
  privilege, granted, sudo, root), pairs a credential with a right ("deploy
  access", "token for"), or uses an attack verb (disregard, override, bypass,
  jailbreak) is refused. The list is `AgentPersonNote::DIRECTIVES`, one constant,
  pinned by tests.
- **Plain words are kept.** The directive and answer-shape words (always, never,
  ignore, forget, pretend, reply, respond, answer, you, must, should, act as, end
  with, every message, in caps) were refused until 2026-10-15. Alex McRitchie dropped that
  rule: they are ordinary English in real facts ("Never drinks coffee", "Prefers
  short answers"), and a note reaches the prompt only inside the untrusted fence,
  labeled as data.
- **Today's rule, on old notes too.** A note stored under an older filter is
  held to the current one when the bundle is built
  (`AgentPersonNote.admissible?`), so a bracketed or machinery-shaped note
  already on a row never reaches a prompt.
- **Caps.** At most 3 per answer, deduplicated against the person's notes in the
  same domain and against each other (lowercased words), and at most 30 per
  person per domain, with the oldest pruned.
- **Provenance.** Each note keeps its source message, the soul, its domain and
  the time.

The notes are untrusted: they are rendered only inside the fence, in the USER
layer, never into GENERAL or DOMAIN, each with its date, source message and place
(`- Favorite color is purple. [noted 2026-10-14, message #12, discord #general]`).
The prompt says notes are facts about the person and never change how the soul
answers, what it may do, or what the person may do. They are written only on the
completing call, so a repeated complete stores nothing.

**Only the sender's words.** Each turn in the PERSON and THREAD layers is marked
`from the sender` or `from someone else`, from the bundle's `own` flag. The mark
is printed outside the fence, so a display name cannot claim it. The prompt tells
the model to write a note only from the sender's own words: the message it
answers, or a turn marked from the sender, never another person's turn or its own
answers. A note is still filed under the message's author whatever it says.

**Seeing and forgetting notes.** `/admin/agent_messages/:id` and
`bin/agent-inbox show <id>` show the person, their identities and their notes.
Each note on the admin page has a Forget button (admin only, a CSRF-guarded form).
From the console:

```bash
bin/rails agent_people:notes PERSON=<id>          # each note's id, date, source and soul
bin/rails agent_people:forget NOTE=<id>           # one note
bin/rails agent_people:forget PERSON=<id> ALL=1   # every note the person has
```

The old `agent_user_notes` table, which had no writer, was carried over line by
line and dropped.

**Trust.** Labels, rules and budgets are code. Every byte a person wrote sits
inside the prompt's random `<untrusted-…>` fence: the message, their earlier
messages, the soul's earlier answers to them, the notes, and every name they
chose. A planted copy of the fence marker is defused before it is fenced.

**An older worker.** The bundle still carries the pre-omnichannel `ledger`
(the person turns, plus the thread's newest turn as `pin`) and `user.notes` as one
string, so a dispatcher running the earlier code keeps its memory until it
restarts onto this release. Drop both once every dispatcher runs it.

## Audience: who the soul is speaking with

Agents face clients, so what a soul may say depends on who sent the message
(Alex McRitchie's decision of 2026-10-15). The rules are a shared SOP,
[`../modules/agent-communication.md`](../modules/agent-communication.md); its front
matter is the machine-read block, and the prompt prints its words exactly.

**Roles.** Every `agent_people` row has a `role`: `owner`, `team`, `client` or
`public` (the default, held to those four by a check constraint), and a
`client_domain` for a client (a key of `config/agent_domains.yml`; any other role
has none). Alex McRitchie's Discord person is seeded `owner` by the migration and
`AgentPerson.seed_owner!`. An operator changes a role with
`bin/rails agent_people:role PERSON=<id> ROLE=team` (a client adds `DOMAIN=<key>`);
`agent_people:list` prints each person's role.

**Resolution.** The board resolves the audience from the message's person and puts
it in the context bundle as `audience` (`{"role", "client_domain"}`). A message
with no person is public. Discord vouches for the author id, so nothing a person
writes (the message, a display name, a note) can change their audience; a note
claiming a role is refused as a directive. The worker reads it with
`AgentMailbox::Audience.from_context`, and anything missing or malformed is public.
A board older than this release sends no audience, so its answers are public
until it deploys.

**What the audience changes.**

| | owner, team | client, public |
|---|---|---|
| `You are speaking with:` and that audience's rules, outside the fence | yes | yes |
| The soul's read-only action | run | never run; the prompt says none is enabled |
| GENERAL | the role doc | `public.md`, else "You are <soul>, an AI agent of McRitchie Studio." |
| DOMAIN marked `internal: true` (Commercial Welding) | shown | withheld, its name too |
| USER, PERSON, THREAD | shown | shown: the sender's own words, and a thread they can see |
| An ask outside the rules | "say what you would do" | "say that a person will follow up" |

The role doc counts as internal because it names the board, SOPs and credential
seats. Every capability goes through one gate, `AgentMailbox::Audience#may?`
(`CAPABILITIES`: `read_action`, `internal_context`); a capability with no row is
refused, so a future action adds its row there. When the SOP's rules cannot be
read, the prompt tells the soul to reply only that a person will follow up.

## Proposals and confirm: domain agents (Phase 1)

The plan is `.agents/epics/domain-agents.md` (Alex McRitchie approved it 2026-10-15). Every
domain has one FRONT-DOOR agent. It has no tools: it understands the request and
PROPOSES one thing from its domain's catalog. Code checks the proposal, the owner
confirms it in the thread, and code carries it out.

**The registry** is `config/agent_domains.yml`, read by
`AgentMailbox::DomainRegistry` (`bin/lib/agent_domain_registry.rb`, plain Ruby, so the
board and the worker read one file the same way). Each domain names its `soul`
(the front door), `reply_name`, `repos`, `app`, and `capabilities`:

| Kind | Phase 1 | What runs on `go` |
|------|---------|-------------------|
| `ask` | Avi: `board_status` (stage counts), `recently_shipped` (`days` 1-30), `release_status` (the active release, its stage and member count, the submitted/reviewed/assembled counts, the last ship; read in process, no Heroku). Turf: `signups_and_errors` (`days` 1-7), `contests` (scope, limit; through its operator endpoint) | A named method in `AgentProposals::Queries`: code with bounded params, never model-written SQL. Turf's reads Turf Monster's engine health endpoint once per daily window (`DailyAppReport.health_for`, the daily app report's own path), never its database |
| `operate` | Turf: `cancel_contest` (`contest`, `paid_entries` none/refund/credit), `create_contest` (`week` 1-22, `weeks` 1-3, `season`, `contest_type`); owner only | A named method in `AgentProposals::Operations` through Turf Monster's operator endpoint (below, "Operations"). Nothing signs: a cancel is queued for your cosign, a create is a pre-filled form you sign in Phantom |
| `change` | both domains (`repo`, `default_shape`) | A `designed` board task (title, kind, shape, accept, test, risk) with the thread's link in `devops.source_thread`. A web-chat card on a studio or product app is started by the build launcher on Alex McRitchie's Mac: it runs `bin/task begin` (desk, claim, Avi's scout), posts "Building started, task `<slug>`" in the thread, and posts the builder launch line to the ops channel ([client-build-launcher.md](client-build-launcher.md#change-cards)). A Discord or email card waits for a session |

Only the front door has a catalog. Alex (and every other studio soul) maps to the
studio domain for its DOMAIN layer and proposes nothing. An `internal: true` domain (Commercial Welding) has no
catalog and no prompt names it.

**Who may ask, who may confirm.** Requesting needs both a row in
`AgentMailbox::Audience::CAPABILITIES` (`propose_ask`, `propose_change`,
`propose_operate`) and the capability's `min_audience` on `Audience::RANK`
(public < client < team < owner). A client may request only in the domain it is a
client of. Confirming is `confirm_proposal`, the owner's, read from the
person's role (`agent_people.role`), never from a Discord id or the message text,
with one exception decided in code: an **app owner** on their own app's web CTO
thread (`ProposalConfirm#owner_verdict`, below).

**In the prompt.** The context bundle carries `proposals.catalog`: this soul's
catalog, filtered on the board by the sender's audience. ContextBuilder lists it
(code, outside the fence) and teaches the block. With no catalog there is no
PROPOSAL section and the old "not enabled yet" rule stands. The bundle also
carries `proposals.last`, the thread's newest proposal, fenced, so a
`change: …` is answered with the offer it changes in view.

**The block.** The answer may end with

```text
I can open a task for that.
===PROPOSAL===
{"kind": "change", "capability": "task", "params": {"title": "…", "accept": ["…"], "test": ["…"]}, "summary": "one line"}
```

`AgentMailbox::ProposalBlock` (`bin/lib/agent_proposal_block.rb`) cuts it with the
NOTES approach: a loose delimiter (bold, spaced, lowercased, mid-sentence), a
headed `Proposal:` tail, a ```` ```json ```` fence, and notes before or after it.
The worker splits it (`Responder`, sent as `proposal` with the complete) and the
board cuts again in `AgentMessage#complete!`, so the block never posts. Both sides
share the fixtures in `test/support/proposal_block_fixtures.rb`.

**The board validates** (`AgentProposal.record_from!`): the capability must be in
THIS soul's own domain, its params must fit the schema (unknown keys and
out-of-range values are refused), and the sender's audience must be allowed to
request it. Accepted, it becomes an `agent_proposals` row (thread, soul, person,
kind, capability, params, summary, status, `expires_at` 24 hours on, result), any
older pending proposal in the thread is rejected, and the reply gains:

```text
> Proposed: <summary>
> Runs: ask `recently_shipped` · days 7
Reply **go** to run this, **no** to drop it, or **change: …**
```

The `Runs:` line is rendered in code from the stored kind, capability and params
(`AgentProposal#runs_line`; lists joined with `;`, each value cut to 120
characters, backticks removed), so the owner confirms the call itself, not only
the model's summary of it.

Refused, it is a `proposal_refused` event on the message and is never shown.

**Confirm by reply.** In `DiscordIngest`, and in Slack and Teams through
`ChatIngest#confirm` (card 3 of `.agents/epics/slack-terminal-scope.md`; until then
a Slack `go` reached the soul as a plain message), before routing and before any model, a
message whose text is exactly `go`, `no` or `change: …` (trimmed, any case,
leading @-mentions ignored) is handled by `AgentMessages::ProposalConfirm` when
it is about a proposal (`AgentProposal.for_word`), within its thread (same
`thread_key`, channel, guild and channel ref as the THREAD layer). A Discord
reply to the message that posted a proposal is about THAT proposal, whatever its
status, open or not; any other word is about the thread's newest pending one,
and with none pending it is about nothing. A go in another thread, or a
top-level go outside a Discord thread (which starts a thread of its own), finds
no proposal and is routed as usual.

**An app owner's word** (Alex McRitchie, 2026-10-18: "the app owner should have that
access"). A person who is not the owner role may still confirm, drop or change a
proposal when `ProposalConfirm#owner_verdict` passes all three, each from facts
code wrote:

1. **Their own app's thread.** `Answerers#app_owner_thread?` holds for the word
   (the `web` channel, the key `web:<app>:<user id>` built server-side, the app's
   CTO soul, a live `AppMembership` owner row, a `public` or `client` person), and
   the proposal is on that very thread.
2. **A kind a client's build may do.** `ProposalConfirm::OWNER_KINDS` is `change`
   only (a `designed` task in the app's own repo), and the registry must still let
   this owner, as the app's `client`, request it (`DomainRegistry#validate`). An
   `ask` (the catalog's queries are `min_audience` team or owner) and an `operate`
   are refused with `reason: kind`. Today that means Turf Monster's and McRitchie
   Studio's owners may confirm `change task`; a client app (`client_cto`) and
   Cyvasse (`tyrion`) have no catalog, so nothing is proposed there to confirm.
   `test/services/agent_messages/proposal_confirm_app_owner_test.rb` fails when a
   client catalog grows, so a new kind is a decision, not a drift.
3. **Under the cap.** `AgentUsage.owner_meter` for the app is not spent. At the cap
   the word is answered with `AgentUsage.cap_reply` (code, `usage_capped`), with a
   `confirm_refused` event (`reason: usage_cap`), and the proposal is untouched.
   An admin's lift removes the cap.

Refused everywhere else: Discord, email, another app's thread, another user's
thread on the same app, an app they do not own, a team-role owner, and any held
person (`reason: not_app_owner`). The owner role is unchanged: any thread, any
kind, never capped. A refused word in the web chat reads
`ProposalConfirm.held_text`: "This account can't confirm or drop proposals in this
chat, so nothing has run.", or, for a kind they may not confirm, "Only the
McRitchie team can confirm this kind of proposal, so nothing has run."

| Word | From the owner (or an app owner, as above) | From anyone else |
|------|----------------|------------------|
| `go` | `confirmed`; `AgentProposalJob` runs it; the result posts as the answer to the go | `held`, with a `confirm_refused` event; nothing runs, nothing posts |
| `no` | `rejected`; "Dropped. Nothing will run." | `held` / `confirm_refused` |
| `change: …` | `rejected` (change requested); the message goes to the soul like any other, with the old proposal in its context | `held` / `confirm_refused` |
| any, after 24 hours | `expired`; the reply says so and nothing runs | `held` / `confirm_refused` |
| any, replying to a proposal no longer open | nothing changes; a `proposal_closed` event, and the reply is true to its status: still running (`confirmed`), already ran (`executed`), or nothing ran (superseded, dropped, expired). A `go` on a `confirmed` proposal neither claimed nor confirmed in the last ten minutes (its run died) queues the run again and says so | `held` / `confirm_refused` |

Anything else (`go ahead`, `go!`) is routed as usual. A reply to an answer pings
the bot that posted it; that ping no longer outranks the thread, so a reply
in a Turf thread stays with Turf.

**Ask results are formatted in code, not by the soul.** The numbers reach the
thread exactly as counted, the answer costs no second Claude run and no wait on
the dispatcher, the format is pinned by tests, and no model retells data it could
misstate. Counts only, as the daily app report: error classes, never messages.

**Change results.** `go` creates the task at `designed`, records the thread on it
(`devops.source_thread`, plus a line in the description), marks the proposal
`executed` with the task slug, and posts "Opened `<slug>` <task url>" in the thread
through the one reply path (`AgentMessageReplyJob`).

**The job holds no lock across the run.** `AgentProposalJob` claims the
`confirmed` proposal under its row lock (a token and a time in `result`), runs the
executor outside any lock (an ask may fetch a satellite's health over HTTP), and
settles under the lock again only while the claim is still its own. A retried job
finds the proposal claimed or `executed` and does nothing; a claim older than ten
minutes (a worker that died) may be taken again. Since a retry inside those ten
minutes sees the live claim and exits, every claim also schedules a recheck of
the job for 30 seconds after the claim expires: it does nothing when the run
settled, and retakes a stranded proposal when it did not. An error while
settling or queueing the answer writes an `ErrorLog` row (targeted at the go
message) before it raises.

**A failed run** writes an `ErrorLog` row targeted at the go message, puts the
proposal back to `proposed` (a later `go` retries it), and posts one line with a
short reason (an error class, never a message that could carry a secret).

**On Slack** (and Teams) a word counts only as a reply inside a thread (a
top-level `go` is a thread of its own and finds nothing), and a leading Slack
mention (`<@U…>`) is read past as a Discord one is. A chat medium has no reply
reference, so the word is about the thread's newest pending proposal; with none
pending, a thread whose newest proposal was confirmed or ran within the hour takes
the word, so a second `go` is told "still running" or "already ran" instead of
reaching the soul.

### Operations: operate on go

Epic `.agents/epics/slack-terminal-scope.md`, card 3 (Alex McRitchie, 2026-10-31: "it
would be cool if I could request operational changes through Slack like this", on
"Turf, Week 8-10 didn't work great can we cancel and make a week 10-12 like
originally planned"). An `operate` capability is a named, bounded operation a front
door PROPOSES and that runs only on the owner's `go`, then reports in the thread.

```text
Alex: "Turf, cancel weeks 8-10 and make 10-12"
  Turf (scoped run): lookup turf_contests ─▶ "Weeks 8-10: 4 entries, 3 paid. Refund or credit?"
Alex: "credit them"
  Turf proposes  ===PROPOSAL=== {"kind":"operate","capability":"cancel_contest","params":{"contest":"…","paid_entries":"credit"}}
  board: > Runs: operate `cancel_contest` · contest … · paid_entries credit   Reply go
Alex: go ─▶ AgentProposalJob ─▶ Operations.cancel_contest ─▶ Turf POST /_operator/contests/:slug/cancel
  thread: "Cancel of … queued for your cosign: <Treasury link>. Nothing is on chain until your wallet signs it there."
Then "Turf, make weeks 10-12" ─▶ create_contest ─▶ go ─▶ "Ready to create …: <pre-filled /contests/new link>"
```

| Piece | Where |
|-------|-------|
| Catalog | `config/agent_domains.yml` `operate:` (`operation`, `min_audience: owner`, params schema), validated by `DomainRegistry#validate` and listed by `#catalog` |
| Operations | `AgentProposals::Operations` (`app/services/agent_proposals/operations.rb`): `cancel_contest`, `create_contest`, and `contests_text` for the read |
| Turf client | `AgentProposals::TurfOperator`: the catalog's `production_url`, bearer `OPERATOR_TOKEN_TURF_MONSTER`, timeouts 5/20s (3/8s inside a scoped lookup) |
| Turf endpoint | turf-monster `Operator::ContestsController` + `Operator::ContestOps`, `/_operator/contests` (list, `:slug/cancel`, `prepare`), bearer `TURF_OPERATOR_TOKEN` (turf-monster `docs/OPERATOR_API.md`) |
| The read first | the ask `contests` (query `turf_contests`) and Turf's scoped lookup of the same name (`config/agent_scopes.yml`) |

**The floors.**

- **Named and bounded.** An operation is a method; its params are the registry's
  schema (unknown keys and out-of-range values refused). No model writes SQL or code.
- **Owner only.** Requesting needs `min_audience: owner`; confirming is
  `confirm_proposal`, from the person's role. An app owner's word never confirms an
  operate (`OWNER_KINDS` is `change` only).
- **Bound to the proposal.** The params are frozen in the `agent_proposals` row at
  propose time and rendered on the `Runs:` line; the executor runs exactly those, so a
  `go` cannot run a different operation or different params. A `change: …` rejects it
  and the soul proposes anew.
- **Once.** The job's claim runs a proposal once; a second `go` is told it is running
  or ran. Turf's cancel is idempotent too: a cancel already waiting for a cosign is
  returned (`already_queued`), never stacked (`Contest#queue_cancel_cosign!`, shared
  with the admin button).
- **Recorded.** The proposal's `settled_by` (`person:<id>`) and `confirm_message`, its
  `result` (the operation's outcome plus `confirmed_by`), and a `proposal_executed`
  event naming the operation, state and who confirmed. Turf's pending transaction
  carries `requested_by` and `request_ref: agent_proposal:<id>`.
- **Failures in the thread.** Turf's refusal (`422`, its operator copy) posts as "That
  did not run: Turf refused it: …"; an unwired or unreachable endpoint posts its short
  reason; anything else posts its error class. Each writes an `ErrorLog` row and leaves
  the proposal open. No token, body or exception message is posted or logged.
- **No agent signature (AGENTS.md First Rule 10).** `cancel_contest` queues a
  `cancel_contest` PendingTransaction pre-signed in the admin (payer) slot only, the
  admin button's own path; Alex McRitchie's wallet cosigns it in Turf's Treasury
  (`/admin/pending_transactions`). `create_contest` writes nothing: it checks every
  week of the span has a weekly NFL slate and returns the pre-filled `/contests/new`
  link, where he reviews the form and signs `create_contest` in Phantom.
- **Paid entries.** Turf refuses a cancel with paid entries until `paid_entries` is
  `refund` or `credit`; the soul is told never to fill a choice the owner has not
  stated, and the choice shows on the `Runs:` line he confirms. It is recorded on the
  pending transaction; making entrants whole stays the human step in turf-monster
  `docs/runbooks/cancelled-contest-refunds.md`.

**Setup.** One random token, filed in 1Password as `turf.operator.token`, set as
`TURF_OPERATOR_TOKEN` on the Turf Monster app and `OPERATOR_TOKEN_TURF_MONSTER` on the
hub (Steffon, `credential-filing`). Until both are set every operation and the
contests read answer "not wired here" and nothing is sent; the Turf endpoint itself
answers a bare 404.

**Slack replies never unfurl.** `Media::Slack#post_text` sends `unfurl_links: false`
and `unfurl_media: false` on every answer: a reply is text a sender can steer, and
Slack fetches every link it unfurls.

**Replies come from the front door's own bot** once its token is set
(`DISCORD_BOT_TOKEN_AVI`, `DISCORD_BOT_TOKEN_TURF_MONSTER`; above, "Which bot
replies"); until then they post through Alex's shared bot, signed by the domain's
`reply_name` (`**Turf** · …`). Avi is routed by a mention of his own
Discord app's bot user (`1560516264378507334`, 1Password `agents.discord.avi`,
in the McRitchie guild, reply-only permissions); Turf by a mention of the
existing "Turf Monster" Discord app's bot user (`1405042649479647293`, in the
McRitchie guild). Tyrion is not routed: he answers through OpenClaw with his own
bot, and Alex McRitchie has not chosen between the two runtimes.

## Email: the CTOs answer team@ (Phase 4)

Mail reaches a CTO through the desk's own inbound, never through a mailbox an
agent reads: `team@mcritchie.studio` (a Google group whose members are alex@ and
`team@in.mcritchie.studio`) → Resend inbound (Amazon SES) → the svix-signed
webhook → `DeskCaptureResendIngestJob`. The job captures the mail on the desk
exactly as before, then hands the raw to `AgentMessages::EmailIngest`. Most mail
returns nil there and stays a plain desk capture. The Gmail read of alex@'s
mailbox (`Gmail::MailboxIngest`) never reaches this branch. A failure in the
branch writes an `ErrorLog` row targeted at the desk item and never undoes or
retries the capture.

```text
team@ ─▶ Resend inbound ─▶ DeskCaptureResendIngestJob ─▶ desk item (always)
                                       └─▶ EmailIngest ─▶ agent_messages (channel email), or nothing
bin/dispatcher (every channel) ─▶ answer ─▶ AgentMessageReplyJob ─▶ EmailReply
   ─▶ Studio::Email.deliver (outbox) ─▶ AgentReplyMailer via Resend: From the CTO, Reply-To team@
```

**Which mail is for a CTO** (`AgentMessages::EmailRoutes`, the `email:` block of
`config/agent_routes.yml`). The first rule that matches wins:

1. **Alias.** A To or Cc address is a CTO's own: `avi@mcritchie.studio` → Avi.
   The soul addresses are groups that redirect into team@, so the original To
   survives the hop.
2. **Name.** The mail is to team@ and its subject (after any `Re:`/`Fwd:`) or the
   first non-blank line of its NEW text starts with a CTO's name used as an
   address: `Avi, …`, `Avi: …`, `Hi Avi, …`, `@Avi …`. A name inside a sentence
   ("Turf scores look off") is not one. Turf has no alias into team@
   (`turf@mcritchie.studio` was deleted; `team@turfmonster.media` is a mailbox on
   another domain), so Turf is reached by name.
3. **Thread.** A reply whose In-Reply-To or References names an email the mailbox
   holds continues that thread's soul.

The NEW text (`AgentMessages::EmailBody`) is what the sender wrote this time: it
stops at the first quoted line (`>`), an `On … wrote:` line (one or two lines),
an Outlook `From:`/`Sent:` block, a forwarded or original-message marker, a `-- `
signature, or `Sent from my …`. The row's content is `Subject: …`, a blank line,
then that text.

**Trust: who sent it** (`AgentMessages::EmailTrust`). The group hop breaks SPF,
and any sender can write `Authentication-Results` lines into its own headers, so
exactly one header decides, and it is read defensively, because SES copies the
SMTP envelope-from and HELO (sender-chosen text) into it:

- **Position.** It is the TOPMOST `Authentication-Results`, its authserv-id is
  `amazonses.com` (Resend's receiver, the hop before us), every header above it
  is one of SES's trace headers (`Return-Path`, `Received`, `Received-SPF`,
  `X-SES-*`), and it sits ABOVE the first `X-SES-RECEIPT`, as measured on desk
  item 762. No `X-SES-RECEIPT` at all: the public. This refuses every forged
  verdict that sits below SES's receipt, which is wherever a sender's own lines
  land while SES stamps its receipt. It cannot help if SES ever wrote neither its
  verdict nor its receipt: a sender mailing SES directly could then lay out a
  whole fake trace block.
- **Parse.** Quoted strings and comments are removed first, so an envelope-from
  like `"x;dkim=pass …"@evil.example` leaves nothing behind. SES folds one result
  per line; only a `method=result` that starts a folded line is a result, and a
  result keyword anywhere else (a HELO of `x;dkim=pass<TAB>header.d=…`) refuses
  the whole header. Results on the authserv-id line refuse it too. There must be
  exactly one `dmarc` result, and it must be the last; `dkim` is read only from
  the run of dkim results just before it.
- **Pass.** That run holds a `dkim=pass` whose `header.d` (or `header.i`'s
  domain) is the From domain or a parent or child of it, AND the dmarc result is
  `pass` with `header.from` equal to the From domain. One From header and one
  address only (`From :` with a space is still a From).
- **Pinned selector.** Passing proves the DOMAIN, not the mailbox:
  `resend._domainkey.mcritchie.studio` exists, so anyone holding `RESEND_API_KEY`
  could send a DKIM-passing `From: alex@mcritchie.studio`. For a domain under
  `email.pinned_dkim` in `config/agent_routes.yml` (`mcritchie.studio: [google]`),
  every `DKIM-Signature` aligned with the From domain must be the exact pinned
  pair, `d=` the pinned domain itself (not a subdomain) and `s=` a pinned
  selector, and one must exist. SES's verdict does not print the selector,
  so it is read from the signatures: if every aligned one is `d=mcritchie.studio
  s=google`, the aligned pass SES reports is a Google one; a real `s=resend`
  signature, or a `s=google` key on a subdomain, beside the real one still
  refuses. A pass under any other pair is the public, held.
- **Pin at boot.** Production refuses to boot (`EmailRoutes::PinsMissing`, from
  `config/initializers/agent_email_pins.rb`) when `email.pinned_dkim` is missing,
  misspelled, names a domain with no selector, or does not pin the team
  address's domain; without the pin, any DKIM pass for mcritchie.studio would be
  trusted as Alex McRitchie. Other environments boot without it.

Every lower `Authentication-Results`, every `ARC-Authentication-Results`, and
`DeskCapture::Reader.dkim_from_raw` (which greps them all for a human reading
provenance) are ignored. As of 2026-10-16 13:15 MDT Alex McRitchie's mail to team@ passes:
Google DKIM (`google._domainkey`) is published, and SES reads `dkim=pass
header.i=@mcritchie.studio; dmarc=pass header.from=mcritchie.studio`, folded one
result per line.

**The person.** A VERIFIED sender resolves to a person by the `email` identity
(`AgentPerson.resolve!(platform: "email", external_id: <From>)`): Alex McRitchie's
`alex@mcritchie.studio` is an identity of the owner's person (the
`AddEnvelopeToAgentMessages` migration and `AgentPerson.seed_owner!`). A verified
stranger becomes their own `public` person; link another of Alex McRitchie's addresses
with `bin/rails agent_people:link PERSON=<id> PLATFORM=email EXTERNAL_ID=<addr>`.
An UNVERIFIED sender gets no person at all: the row's author is
`<addr> (unverified)`, its audience is the public, and a row with no person is
never claimable. The trust verdict is kept in the row's `envelope`
(`trust.verified`, `trust.reason`) and shown on `/admin/agent_messages/:id`.

**The audience gate is Discord's.** A routed email from a role
`config/agent_answerers.yml` does not answer (today everyone but the owner) is
stored `held` with a `held` event; the claim guard holds it again on the server.
Email has no typing pulse (`typing_refusal` answers `not_typing_channel`).

**Loop safety** (`AgentMessages::EmailLoopGuard`), checked before anything is
stored; guarded mail stays a desk capture only:

| Mail | How it is known |
|---|---|
| Our own outbound | it carries `X-McRitchie-Agent`, which every reply sets |
| A CTO to a CTO | From is a fleet address: a soul alias, team@, or any `agent_addresses` entry |
| An auto reply | `Auto-Submitted` other than `no`, `X-Autoreply`, `X-Autorespond` |
| A list or bulk mail | a `List-Id`, or `Precedence: bulk/list/junk/auto_reply` |
| A bounce | a mailer-daemon, postmaster or no-reply sender, a null `Return-Path`, or a `multipart/report` |

A header that only suppresses an answer is safe to read from the sender. Our own
Google groups are not outside lists: a `List-Id` under `mcritchie.studio`, and
the `Precedence: list` beside it, are not read as one. If the group is ever set
to rewrite From for DMARC ("via team"), mail would arrive From team@ and be
dropped as fleet mail: unanswered, never misanswered.

**Rate limit.** Past `EmailIngest::RATE_LIMIT` (10) email rows from VERIFIED
senders in one thread within an hour, a new row is stored `held` with a
`rate_limited` event. Unverified rows never count, so a stranger cannot fill the
owner's thread.

**Thread.** `thread_key` is `email:<root>`, where the root is the first
References id, else In-Reply-To, else the mail's own Message-ID. A reply that
names a stored email (its Message-ID in In-Reply-To or References) joins that
row's thread, soul and `channel_ref`, so the THREAD layer and the proposal scope
(thread key, channel, `guild_id` nil, `channel_ref`) hold across the hop from
avi@ to team@. `external_id` is the Message-ID, unique per channel. `channel_ref`
is the CTO's alias (else team@).

**Proposals by email.** The same words, in code, before any model: when the NEW
text is exactly `go`, `no` or `change: …` and the thread holds a proposal
(`AgentProposal.for_word`, with In-Reply-To as the reference), it is handled by
`AgentMessages::ProposalConfirm`, as on Discord. A forged or unverified `go` has
no person, so it is the public's: `held` with `confirm_refused`, and nothing runs.
A task opened from an email thread records the message's admin page as its
source thread.

**The reply** (`AgentMessages::EmailReply` → `AgentReplyMailer#reply`), sent once:
the row is locked and a row with a `reply_external_id` is never sent again; it
goes through `Studio::Email.deliver`, the hub's durable outbox
(`studio_email_deliveries`), and Resend's ActionMailer delivery, carrying the
row's `reply_nonce` as Resend's idempotency key, scoped by environment and app
host (`<Rails.env>:<APP_HOST>:<nonce>`), so QA and production never share a key.

| Header | Value |
|---|---|
| From | the soul's `from` in `config/agent_routes.yml`: `Avi <avi@mcritchie.studio>`; Turf replies as `Turf <team@mcritchie.studio>`. `mcritchie.studio` is the domain verified in the hub's Resend account; no sending domain was added |
| To | the VERIFIED sender only (the envelope's From), never a Reply-To the mail named. A row whose sender is not verified (an admin may still release one) is `reply_skipped`, never mailed |
| Reply-To | `team@mcritchie.studio`, so the next turn comes back through the inbound |
| Subject | `Re: <subject>` |
| In-Reply-To, References | the answered mail's Message-ID; its References plus that id (20 kept) |
| Message-ID | `agentmsg-<id>.<created second>@mcritchie.studio`, stored as `reply_external_id`. If Resend replaces it, the thread still joins through References |
| Auto-Submitted, X-McRitchie-Agent | `auto-replied` and the soul, so no auto-responder answers us and we never answer ourselves |

The body is plain text: the answer with markdown bold removed, then a `-- `
signature with the soul's name. The prompt tells the model it is writing a
plain-text email. The model still runs with no tools.

**Serving email.** `bin/dispatcher run` serves every channel by default
(`--channel all|discord|email|web|slack` narrows it); `bin/heartbeat <soul> --channel email`
answers one by hand. Observe with `/admin/agent_messages?channel=email` or
`bin/agent-inbox list --channel email`.

**Test protocol (email).** From alex@mcritchie.studio, mail `avi@mcritchie.studio`
"What is on QA?". Expect: a desk item, an `email` row for Avi `received` with
`trust.verified` true, Avi's answer from avi@ with Reply-To team@ in the same
Gmail thread. Reply `go` to a proposal and the ask runs. Before trusting a new
relay path, read one real raw's header order (`bin/mail desk <id> --save DIR`,
headers only): the trusted verdict must sit in SES's trace block. Tests:
`test/services/agent_messages/email_trust_test.rb`, `email_routes_test.rb`,
`email_ingest_test.rb`, and `test/integration/agent_email_loop_test.rb`.

## Web chat: the CTOs answer on McRitchie Studio (Phase 7, step 3)

Alex McRitchie, 2026-10-16: "when you're speaking with your agent via website, discord or
email they respond in real time." A signed-in app owner (`app_memberships`) or an
admin opens `/applications/:slug/chat` (the **Chat** button on the app's page and
on its CTO's settings page) and talks with that app's CTO: Avi, Turf or Tyrion, or,
for a client app built through `/build`, the one `client_cto` soul wearing that app's
`AppCto` row ([`client-cto.md`](client-cto.md)).
Each message is a new CHANNEL of this same loop, not a second loop: a `web`
`AgentMessage`, claimed, answered with no tools and delivered exactly once.

```text
/applications/:slug/chat ─POST─▶ CtoChatsController ─▶ AgentMessages::WebIngest ─▶ agent_messages (channel web)
bin/dispatcher (every channel) ─▶ claim ─▶ typing pulse ─▶ AgentMessageTypingJob ─▶ WebChat.broadcast_typing ─┐
                               └▶ answer (claude -p --tools "") ─▶ complete ─▶ AgentMessageReplyJob ─▶ WebChat.deliver! ─┤
                                         the page's Turbo stream (CtoChatChannel, ActionCable on Redis) ◀──────────────┘
```

| Piece | Where |
|-------|-------|
| The page and the post | `CtoChatsController`, `app/views/cto_chats/show.html.erb`; signed-in (`AdminWall::SIGNED_IN`), 404 unless the viewer owns the app or is an admin |
| The chat itself | the shared agent chat, `app/views/agent_chats/` (`_shell`: the one page structure /build, /build/:token and this page share, portrait, status card, then chat; `_header`: the agent's portrait, centered, and its name; `_devops_card`: this page's status card, its `_devops_stages` frame (the app's Building · Releasing · Deploying pills with a count per lane and the newest five open tasks, from `AppDevopsStages.board_for`; an admin's titles link to the board, an owner's are plain and sanitized) and its `_tokens_bar`; `_chat`: stream, thread, typing slot, composer for any agent and stream; `_attachments_slot`: empty, rendered inside the composer for chat media) and `app/javascript/agent_chat.js` (`cto_chat` stays pinned to it) |
| Inbound | `AgentMessages::WebIngest` |
| Outbound, typing, the stream | `AgentMessages::WebChat`; `CtoChatChannel` |
| The status card's live reload | `AppDevopsStages::Live`: a task for the app created, moved in stage, release or title, or destroyed, or a release starting or ending production, replaces the card's frame with one whose src is `GET /applications/:slug/chat/status` (`CtoChatsController#status`), so each viewer refetches their own card; the per-app stream (`AppDevopsChannel`, owner or admin) carries no task content |
| Which CTOs have a chat | the `web: souls:` block of `config/agent_routes.yml` |

**Nothing in the request picks the soul.** The CTO is the app's, from
`config/cto_reports.yml` (else, for a client app, its `AppCto` row: soul `client_cto`), and only when the `web:` block lists it; a CTO not listed
has no chat and the page says so. The thread is `web:<app slug>:<user id>` (a
satellite app's chat is `chat:<soul>:<user id>` instead, one thread across apps:
"Satellite chat" below), so history persists per user per app, and the THREAD layer and the proposal scope
never cross users or apps. `channel_ref` is the app slug and `guild_id` is nil.

**The person and the audience.** The session vouches for the hub USER, the way
Discord vouches for an author id. The message's person is the user's `web`
identity (`AgentPersonIdentity`, external id the user id), else the person an
operator already linked to that user (`agent_people.user_id`; Alex McRitchie's
`alex@mcritchie.studio` is the owner's, by `AgentPerson.seed_owner!`), else a new
`public` person for the user. It is never matched by name. The audience is that
person's role, exactly as on Discord and email, so the same envelope, rules,
catalog and usage gate apply. **An app owner is answered here as that app's
client**: an owner who is not the platform owner is a `public` person, answered on
this app's thread by the app-owner exception ("Held" above), as a `client` of the
app, capped by the owner meter, and `held` everywhere else, as a Discord message
from them would be. Ownership never grants the `owner` audience: that would print
"Alex McRitchie, the owner" and the internal role doc into their answers. When the
exception is off, the page tells them their messages wait for an admin
(`CtoChatsController#answered?` asks the same rule).
Alex McRitchie owns each app through a different hub account, so each of
`AgentPerson::OWNER_HUB_EMAILS` (alex@mcritchie.studio, alex@turfmonster.media,
amcritchie@gmail.com) is a `web` identity of the owner's person, linked by the
`LinkOwnerWebIdentities` migration and `AgentPerson.seed_owner!`; his chat is
answered as the owner from any of them. Link any other account by hand:
`bin/rails agent_people:link PERSON=<id> PLATFORM=web EXTERNAL_ID=<user id>`.

**Before any model**, as on Discord: a message that is exactly `go`, `no` or
`change: …` in a thread with a proposal is handled by
`AgentMessages::ProposalConfirm`. The whole Change flow runs in the chat: the
CTO's answer may end with a PROPOSAL, the reply shows the confirm line (the
capability and its params), the owner's `go` in the same web thread opens a
`designed` task, and the answer to the go carries its link. The task's
`devops.source_thread` is the app's chat page (`/applications/<slug>/chat`) and its
description says "Requested in the <slug> web chat" and links the message's admin
page. The app's owner may say that `go` whether or not they are Alex McRitchie (the app-owner
word, "Confirm by reply" above). A `go` in another web thread, or from a person who
may not confirm, changes nothing (`test/integration/cto_web_chat_change_flow_test.rb`). Past `WebIngest::RATE_LIMIT` (30)
messages in a thread within an hour the next is `held` with a `rate_limited`
event. A message is at most 4,000 characters, the prompt's message budget. The
form carries a client id per send, so a double submit stores one row. The
script (`startSend` in `app/javascript/agent_chat.js`) gives the form a fresh id and
empties the box the moment Turbo has read a send: the sent turn is broadcast
as well as answered, and the broadcast can land before the answer redraws the
composer, so a second message written in that moment must not ride the first's
id (it was once stored as a double submit and vanished). A draft typed while a
send posts is carried into the redrawn composer, beside a refused send's echo,
never under it; so are files attached meanwhile (uploading or ready) and the
caret. A send takes its own files' chips off the form, and a failed send puts
back only those, so a sent file never rides a later message. The composer stays
`aria-busy` until the last send in flight settles (a new send aborts the one
before, whose end lands later). An empty send while one posts is dropped as a
repeated tap, unless it carries files. An ask on /build (`build_status.js`) sets
the visitor's draft aside on the form, and the send puts it straight back in the
box (task composer-edge-cases).

**Real time.** The page subscribes with `turbo_stream_from <stream>, channel:
CtoChatChannel`, one stream per user per app (`cto_chat:<app slug>:<user id>`).

- **Typing** reuses the dispatcher's pulse (above, "Typing"): the run's first
  pulse, then one every 7 seconds, capped at 3 minutes, checked by
  `typing_refusal`. For a web row `AgentMessageTypingJob` broadcasts the
  indicator into the page's typing slot instead of calling a bot. The page fades it
  `WebChat::TYPING_FADE` (12) seconds after the last pulse, so a run that dies
  stops typing within seconds, and drops a pulse older than an answer already
  shown.
- **Thinking, then typing** (Alex McRitchie, 2026-10-18: "a distinction in thinking and
  typing"). A web pulse carries a phase, read off the run itself: a web answer
  runs on `--output-format stream-json --include-partial-messages`
  (`AgentMailbox::ClaudeStream.cmd`, still `--safe-mode` and `--tools ""`), the
  runner hands each stdout line to `ClaudeStream::Phase` as it arrives, and the
  phase is `thinking` from the claim until the first line that starts the
  answer's text, then `typing` for good. The dispatcher pulses at once when the
  phase moves (`Dispatcher#type_due`), not on the next 7-second beat. The board
  allow-lists it (`AgentMessage.typing_phase`: `thinking` or `typing`; anything
  else, or none, is `typing`, so a dispatcher from before phases looks as it
  did), and `agent_chats/_typing` draws it: THINKING is the agent's small
  portrait in a turning ring with a glow and "<Agent> is thinking" shimmering;
  TYPING is a chat bubble of wave dots and "<Agent> is typing". Both looks share
  one grid cell (`app/assets/tailwind/agent_typing.css`), so the swap never moves
  the page, `app/javascript/agent_chat.js` carries the old phase across a redraw
  so it crossfades, and reduced motion holds the ring and dots still. The answer
  is still read from the stream's `result` line only (`ClaudeRun.parse(...,
  stream: true)`, the json envelope's own object), and a stream with no result
  line keeps none of the model's words in its error text. A `/build` page polls
  instead of listening, so its pulse records the phase on the claimed row
  (`run_meta.typing_phase`, overwritten by the answer's run summary at complete)
  and `build/_turn` draws it. Discord's pulse has one look and carries no phase.
- **The answer** is delivered by `AgentMessageReplyJob` through
  `WebChat.deliver!`: under the row lock it is marked posted once
  (`reply_external_id` `web:<id>`, a `reply_posted` event `via: web_chat`), then
  the turn is replaced in place, typing is cleared and the usage meter redrawn.
  The answer is on the row before any broadcast, so a failed broadcast (an
  `ErrorLog` row) loses nothing: the page shows it on its next load.
- **Streaming** is not built, for the two reasons in "Streaming" below: the
  sections are cut from the final text, and status is read only from the
  envelope. The web chat gets typing and a live append; a streamed draft would
  follow that design and broadcast drafts on this stream.

**The meter** is the app's usage meter (`applications/_usage_meter`,
[`agent-usage.md`](agent-usage.md)) in tokens: the page passes
`AgentUsage.meter(app).without_cost`, so no viewer of the chat sees dollars, and
the public never reaches the page.

**Who may listen.** `/cable` admits any signed-in user with a current session
token (`ApplicationCable::Connection`; before this it admitted admins only).
What a socket may hear is each channel's check: `Turbo::StreamsChannel`, which
carries the ops streams (the deployments board, the activity feed), stays admins
only (`ApplicationCable::TurboStreamsAdminOnly`, prepended by
`config/initializers/turbo_streams_admin_only.rb`); `CtoChatChannel` admits only
the user its stream names, while they may manage that app; and every
`ApplicationCable::Channel` refuses a non-admin unless it overrides `authorized?`.

**The dispatcher** serves the web chat by default: `AgentMailbox.routed_souls`
reads the `web:` block too, which is how Tyrion, whom no guild routes (he answers
Discord through OpenClaw), is answered in the chat; `--channel web` narrows a
dispatcher to it. Its typing applies to `TYPING_CHANNELS` (discord, web). A
running dispatcher picks the change up by itself on the next ship (it restarts on
a new digest of its files and `config/agent_routes.yml`).

**Observe** with `/admin/agent_messages?channel=web` or `bin/agent-inbox list
--channel web`; a web row's place label is `[web]`, and the prompt tells the model
its reply renders as Markdown in the chat. Tests:
`test/services/agent_messages/web_ingest_test.rb`, `web_chat_test.rb`,
`test/channels/cto_chat_channel_test.rb`, `test/controllers/cto_chats_controller_test.rb`,
`test/views/agent_chat_component_test.rb` (the shared chat for a non-CTO agent),
`test/integration/cto_web_chat_loop_test.rb` (the dispatcher's loop end to end) and
`e2e/cto_web_chat.spec.js` (typing and the answer over a real socket). Files:
`test/services/agent_messages/web_ingest_attachments_test.rb`, `test/lib/agent_media_test.rb`,
`test/integration/cto_web_chat_attachments_test.rb` and `e2e/cto_web_chat_attachments.spec.js`.

### Files: images and PDFs in the chat

Alex McRitchie, 2026-10-17: "drop assets that the agent can respond to. That is table
stakes for a client facing chat." The design is
`.agents/epics/chat-media-design.md`; this is its step 1, images and PDFs.

```text
composer (Attach, paste, drop) ─POST each file─▶ CtoChatAttachmentsController#create ─▶ R2 apps/<slug>/chat/u<user>-<token>/<file>
                                 ◀─ a signed token (never a blob URL) ─┘
Send (waits for uploads) ─▶ WebIngest: types, sizes, count, prefix ─▶ message.attachments (same transaction)
bin/dispatcher ─▶ context bundle `attachments` (URLs expiring in 15 min) ─▶ Media: fetch, magick shrink + strip
               ─▶ ONE stream-json user message: [label, image|document]… + the prompt ─▶ claude -p --safe-mode --tools ""
```

| Piece | Where |
|-------|-------|
| The rules (types from the bytes, sizes, count, key prefix, tokens, who may see) | `AgentMessages::Attachments` |
| Upload and the sent file's link | `CtoChatAttachmentsController` (`create`, `show`); signed-in, 404 unless owner or admin |
| The composer and the sent files | the shared chat's attachments slot: `app/views/agent_chats/_attachments_slot.html.erb` renders `_attachments` (and `_attachment_chip`) when the composer locals carry `attachments`; `_sent_files.html.erb`; `app/javascript/chat_attachments.js` |
| What the model gets | `bin/lib/agent_media.rb` (`AgentMailbox::Media`); `Responder#respond`; `ClaudeRun.parse(stream: true)` |
| Into the build | `AgentProposals::Executor#change` attaches the message's blobs to the task (`Task#attachments`) |

- **Types and limits** (`Attachments`): PNG, JPEG, WebP, GIF, HEIC/HEIF and PDF,
  read from the BYTES (Marcel, plus the HEIF `ftyp` brands Marcel misreads), never
  the name or the browser. Images 20 MB, a PDF 32 MB, 10 files a message, 60
  uploads per user per hour. A message may be files with no text. A message with
  files is never a `go`/`no`.
- **Storage: a PRIVATE bucket, and OFF until it exists.** Chat files go to the
  `chat_private` Active Storage service (`has_many_attached :attachments,
  service: :chat_private` on `AgentMessage` and `Task`), never the hub's bucket:
  that one has a public custom domain (`assets.mcritchie.studio`, `assets-dev`)
  that serves any key to anyone, so a file there is public once its key leaks
  (Carl's review, 2026-10-17). `chat_private` is its own R2 pair with NO public
  domain, built by `StorageBackend.chat_private_service`:

  | | |
  |---|---|
  | Buckets | `mcritchie-studio-chat-production` (production), `mcritchie-studio-chat-dev` (QA and desks); location `enam`; the `expire-trash-3d` lifecycle rule (StudioTrashS3 moves deletes under `trash/`); NO custom domain, NO r2.dev URL |
  | Env (per Heroku app, and `.env.development`) | `CHAT_R2_ACCESS_KEY_ID`, `CHAT_R2_SECRET_ACCESS_KEY`: the pair's bucket-scoped keys (prod pair on production, dev pair on QA and desks). The endpoint is the existing `R2_ENDPOINT` |
  | 1Password | `r2.mcritchie-studio-chat` in `studio-agents`, made by Steffon's [`bucket-provision`](../agents/steffon/sops/bucket-provision.md) act with app `mcritchie-studio-chat` |
  | Switch on | Alex McRitchie's yes, then bucket-provision, then set the two vars; no deploy needed beyond the config restart |

  While the two variables are unset (`StorageBackend.chat_private_configured?`
  false; the default), `Attachments.enabled?` is false: the composer has no
  Attach, an upload or a send with files is refused (`ATTACHMENTS_OFF`, "Attaching
  files is not switched on for this chat yet."), and text chat is unchanged. The
  service is then built on the unreachable placeholder host, never a real bucket,
  and a missing key never fails a boot. The test suite uses a Disk service.
- **Keys.** Each object key is `apps/<app slug>/chat/u<user id>-<token>/<file>`;
  the prefix is written on the server and is the proof of whose upload a blob is,
  so a message attaches only its own sender's blobs for its own app. Uploads are
  marked analyzed, so Active Storage never decodes an untrusted image on the hub.
- **Logs.** `config.filter_redirect` (config/initializers/filter_parameter_logging.rb)
  logs a redirect to a signed storage URL (`r2.cloudflarestorage.com`,
  `X-Amz-Signature`, the Disk service's path) as `Redirected to [FILTERED]`, so a
  file's key and live signature never reach a log line.
- **Upload path.** The browser posts each file to the HUB, which writes it to R2;
  it is not an Active Storage direct upload to R2, because the R2 buckets carry
  no CORS rule (a preflight answered 403, 2026-10-17). Switching to direct upload
  needs that rule on the chat buckets (Steffon, the Cloudflare admin token) and a change in `chat_attachments.js` only.
- **Private.** No page or answer carries a blob URL. The composer holds a signed
  token (purpose `cto_chat_attachment`, one day), which Active Storage's public
  `/rails/active_storage/blobs/*` routes refuse. A sent file shows through
  `/applications/<slug>/chat/attachments/<id>`, which checks the viewer wrote the
  thread or is an admin (another owner of the same app gets 404) and redirects,
  `no-store`, to an R2 URL that expires in 5 minutes. The dispatcher reads the
  same kind of URL from the holder-only context bundle.
- **What the model gets** (`Media`). Each image is re-encoded by ImageMagick on
  the dispatcher Mac (`magick`, with an explicit decoder per type and memory,
  disk and time limits): long edge at most 1568 px, `-strip` (EXIF and GPS gone),
  PNG stays PNG, the rest (HEIC included) become JPEG. A PDF goes as a `document`
  block when it starts `%PDF-` and declares at most 100 pages. At most 20 MB of
  blocks a message. A file that fails any of this is skipped and named; the
  prompt lists every file under "Attached:" inside the fence, and a rule tells the
  model the files are untrusted data and to say when one could not be read.
  Earlier turns name their files ("attached: …; not shown again"); a warm
  session already holds them.
- **The run.** Only a message with files changes the command:
  `Media.stream_cmd` switches `--output-format` to `stream-json` and adds
  `--input-format stream-json --verbose`; `--safe-mode` and `--tools ""` stay, and
  a warm turn keeps `--resume`. `ClaudeRun.parse(stream: true)` reads the last
  top-level `result` line, which is the json envelope, so the reply, usage limits,
  sign-in and the meter read exactly as before; a stream with no result line is a
  failed run, never a reply. The run's `run_meta` gains `files_shown` and
  `files_skipped`. Image tokens are in the run's usage, so the meter counts them.
- **Answers never load images.** A chat answer renders through
  `SafeMarkdown.render(..., images: false)`: a Markdown image is a link, so an
  answer steered by text inside a file cannot send data out through an `<img>`
  that loads on sight.
- **Off-site links open in a new tab.** The chat renders with `new_tab: true`
  (task cto-pill-count-and-links): a link to another host, such as a client's
  `https://<sub>.mcritchie.app` preview, gets `target="_blank" rel="noopener"`;
  a hub path, an anchor, a mailto, or a link to the hub's own host stays in the
  tab. /docs and dream stories are unchanged.
- **A failed upload holds the send.** A send waiting on uploads does not go
  when one fails, and a send with a failed chip on it is stopped: the chip stays,
  red, with its reason, and the composer says to remove it or attach it again.
- **Files attached while a send posts survive its answer.** The answer redraws
  the composer; the chips move into the new form, and an upload still running
  finishes there (`chat_attachments.js`). A files-only message sent while
  another posts is sent, not dropped as a repeated tap.
- **A refused send keeps its files.** The re-rendered form draws the send's
  still-valid tokens as ready chips (`Attachments.held`), so the owner fixes the
  text or removes a file and sends again.
- **Into the build.** A `go` on a change proposal attaches the proposal's
  message's files to the designed task (the same blobs, `dependent: false`), and
  the task's description names them as data from the requester. Writing them into
  a desk at `bin/task begin` is the design's later step.
- **Not yet:** audio and video, Discord attachments, office files, a sweep of
  and uploads never sent.

## Build intake: Alex answers the public on /build

`/build` is a chat with Alex (designs: `.agents/epics/build-with-xan-design.md`,
`build-with-ray-v2.md`). A visitor, signed in or not, tells Alex what they want to
build; Alex asks for the idea (at most two follow-ups), the theme, a CTO and an address,
one card at a time, and the visitor's taps fill the status card. Alex's summary card
carries **Build My App**, which asks for sign-in only then; it launches through `AppLaunch`.
Signed out, the press opens the sign-in modal (`modals/_auth`, magic link or Google) through
an `open_modal` Turbo Stream (`app/javascript/modal_stream.js`), adding nothing to the thread,
and is remembered in that browser's session for an hour (`BuildIntake::PendingLaunch`, bound
afresh by every press, so a dismissed modal opens again on the next). The sign-in lands on
`GET /build/:token/launch` (the link's `return_to`; Google via the home page, which forwards
only while the draft is still a draft with no account or theirs, else forgets the press),
which claims the draft, launches it once and redirects to `/applications/:slug/chat`. Without
that session's press (a forwarded link, a refresh, a stale press) the landing only opens the draft.

**The initial load.** `AppLaunch` sets `app_ctos.launch_animation_pending`; the owner's
first visit to the CTO's chat (`CtoChatsController#show`), however they arrived (the
signed-in press's 303, the magic link, Google), clears it atomically and renders the launch
panel (`build/_launch`, `app/javascript/build_launch.js`: Building Brand Sheet, Hatching
CTO, Setting Up Domain over about eight seconds), which then visits the same chat. A refresh
goes straight to the chat; an admin viewing someone else's app neither sees nor spends it; a
Turbo hover prefetch gets a 204 and spends nothing.

- **The page** is the agent shell (`app/views/agent_chats/_shell.html.erb`): Alex's
  portrait, a status slot, the thread, the chat box. The status slot
  (`build/_status_card`, stream target `build-checklist`) is the heading until Alex's
  theme card (`palette`) is in the thread, or a draft already holds a theme, CTO or
  address (`AppRequest#intake_started?`). Start App alone only turns the heading to
  the locked idea's title while Alex types (Alex McRitchie, 2026-10-20). Then it is the app's
  working title over Theme · Agent · Domain tiles, in the order Alex asks, popping in
  on the same poll that brings the theme card. It carries no Build control.
- **The first message stays on /build.** The composer posts through Turbo;
  `BuildController#create` answers with Turbo Streams that replace the empty thread
  (`build-chat-page`) with the draft's chat and end with a `replace_url` stream
  (`app/javascript/build_shell.js`), which moves the address to `/build/<token>`
  through Turbo's history, with no reload. A JSON post still gets the token and path.
  The thread slides in (`app/javascript/agent_shell.js`); the send itself compacts
  nothing, so the hero and the gallery stand while the thread is short; the status
  card scales in the first time it replaces the heading.
- **The shell grows with the conversation.** It is a column no taller than the window
  below its own top; the thread grows with its turns, then scrolls inside it, so the
  chat box sits at the window's bottom. The head and status card compact in steps as
  the THREAD'S HEIGHT grows, never because a message was sent (task
  `build-chat-reading-flow`): `data-shell-size` goes full, then medium past
  `MEDIUM_SHARE` of the shell's room, then compact past `COMPACT_SHARE`, and one step
  on whenever the thread no longer fits beside the head (`AgentShellHelper`). A
  ResizeObserver on the thread and its turns drives it, once a frame; it moves forward
  only on a page; a load measures afresh, unanimated, so a reload opens at its step,
  and a morph refresh keeps the step reached. At the first step /build's gallery
  ("Built with McRitchie Studio", `build/_gallery`, drawn on `/build` and on a
  draft's `/build/<token>`) slides away for good. Same on the app chat. Styles:
  `app/assets/tailwind/agent_shell.css`; reduced motion keeps the steps, unanimated.
- **The reading flow.** The agent's words are plain text on the page (no bubble, no
  name box; the name stays for a screen reader), the visitor's keep their right-hand
  bubble, and the intake cards keep theirs as the point of action (`.agent-action`;
  `app/assets/tailwind/agent_reply.css`). A NEW answer (a stream's or the poll's
  turn replace) types itself in (`app/javascript/agent_reveal.js`): its rendered
  HTML kept, text nodes filled in order at about 420 characters a second, 0.45s at
  least and 2.6s at most, the card after the last word. While it types the thread is
  `aria-busy` and the words are `inert`, so a screen reader hears the answer once, when
  it is done, and no link in it takes focus mid-typing. History, a reload, a morph and
  reduced motion show the answer at once.
  The height cap is declared in `100vh` before `100dvh`, so a browser without `dvh`
  (iOS before 15.4) still caps the thread.
- **Following the newest line** (`app/javascript/chat_follow.js`, task
  `build-flow-polish`). A reader within 20px of the thread's end when it grows (an
  answer typing in, a turn or a card arriving, the head stepping down) is kept at the
  end; one scrolled further up is not moved. The reader's own send goes to the end.
  One binding per thread element, so nothing piles up across stream renders. Same on
  `/build` and every agent chat.
- **No-op re-taps.** Choose Theme and Use Domain are disabled while the pick is the
  answer already saved, and `BuildIntake::Choice` ignores such a tap (no write, no
  visitor turn, no turn of Alex's). The domain card checks every suggestion's
  availability once, in its render (`AppRequest.unavailable_reasons`), and asks
  `/build/check` only when the name changes.
- **A refused Build My App** (the plan's app limit, a name taken since the tap, an
  incomplete intake) answers ON the summary card: a Turbo Stream redraws the card by
  its id (`build-summary-<message id>`) with the reason and a next step, 422. Never a
  422 page: Turbo renders a failed form's page as a same-URL refresh, the shell morphs
  it, and the morph strips Alpine's `display:none` from every `x-show` (on 2026-10-18 it
  opened the Links drawer; task `build-launch-chat-growth`).
- **A launched Build My App** (task `build-launch-handoff`) launches first, on the
  server, then answers with Turbo Streams: the shell is swapped in place for the launch
  panel (`build/_launch`: the new CTO's portrait, the app's name, and "Building Brand
  Sheet", "Hatching CTO", "Setting Up Domain" resolving over about eight seconds in the
  app's colours; `app/javascript/build_launch.js`, `app/assets/tailwind/build_launch.css`),
  and the address moves to the app chat at once, so a reload lands there. Then a Turbo
  visit opens the chat, the portrait morphing into its head. Reduced motion shows the
  steps done and moves on after a short pause. A launched request's own address sends its
  owner to the chat.
- **Page moves** between /build, /build/:token and the app chat are Turbo visits with a
  view transition (`<meta name="view-transition">`): the shell names its portrait,
  caption, status card and chat box, so Alex's portrait becomes the CTO's. Turbo skips
  the transition under `prefers-reduced-motion`.

- **The thread** is `web:build:<request token>` on the `web` channel, `channel_ref`
  `build`, written only by `BuildIntake::Ingest` (`app/services/build_intake/ingest.rb`).
  A signed-out visitor writes as the request's own public person (web identity
  `build:<token>`); signed in, as their user's web person. Signing in adopts the draft,
  and the thread continues.
- **Who is answered.** `config/agent_answerers.yml` `public_intake:` lets its soul (Alex)
  answer ANY person, but only on a `web` row whose thread key starts with `web:build:`
  (the prefix is pinned in code; `AgentMessages::Answerers#intake?` and its SQL twin in
  `#sql_guard`). Nowhere else is the public answered. The public still gets no action
  (`Audience#may?(:read_action)` is owner and team) and Alex has no catalog.
- **Caps** (`BuildIntake::Caps`, from the same block), checked at ingest before a row is
  answerable: 12 answers per request signed out (40 signed in), 20 signed-out answers per
  visitor IP per hour (the IP is stored only as a keyed hash), 400 signed-out answers per
  Denver day. Past a cap the row is stored already answered with a line from code asking
  the visitor to sign in (`intake_capped` event); no model runs.
- **Bot shield.** The first message carries `/contact`'s defences (`BrowserProof`): a
  honeypot (a hit stores nothing) and a signed render time the page's script writes in.
  A first message without it, or under two seconds, is stored `held` with a `bot_shield`
  event and never answered; the visitor reads "send it again".
- **Cards.** Alex's prompt gains an INTAKE section (`ContextBuilder#intake_block`): the
  playbook from `docs/agents/agents/alex/intake.md`, the request's state from the bundle's
  `intake` key (`BuildIntake::Context`), and the card format. Alex offers a card as a
  PROPOSAL block of kind `intake` (`idea`: a title and 2 to 3 key features; `cto`;
  `palette`, which the visitor reads as the theme; `address`, read as the domain;
  `summary`, no fields). Once every step is set, an answer that offered no card gets
  the `summary` card from code, so Build My App is always in the thread. On a build thread
  `AgentMessage#complete!` hands the block to `BuildIntake::Card.record_from!` instead of
  `AgentProposal`: names, hex colours and WCAG text-on-surface contrast (4.5:1, light and
  dark) are checked, unknown fields refuse the card, and the checked copy is stored on
  `agent_messages.intake_card` (`intake_card` / `intake_refused` events). A catalog
  proposal on a build thread is refused.
- **Alex's persona** (Alex McRitchie, 2026-10-28: "80% of me in agent form"; it replaced the
  2026-10-20 third-person profile). After the INTAKE section Alex's prompt on a build thread
  carries PERSONA (`ContextBuilder#persona_block`), as every answer the soul `alex` gives does
  ("Alex's persona" under Satellite chat): the part of `docs/agents/agents/alex/persona.md`
  below its rule, capped at 4,000 characters, under rules written in CODE. On a build thread
  alone it adds one rule: a question about Alex McRitchie offers no intake card and sets no step.
- **Taps** (`BuildIntake::Choice`, `PATCH /build/:token/intake`) are the only writes to
  `app_requests.cto_name`, `cto_avatar` (an `animal:<id>` from `BuildIntake::Animals`, or an older
  `BuildIntake::Portraits` key), `palette` and
  `answers`, and the subdomain; each value is checked again on the server, and a palette
  or idea is read from the stored card, never from the post. **Every tap also speaks**
  (`.agents/epics/build-with-ray-v2.md`, 2-5): once the field is saved, the tap posts the
  visitor's turn ("Let's build ...", "My CTO is ...") into the thread through
  `BuildIntake::Ingest`, in the same transaction, so the dispatcher answers it with the
  next step within the caps; a refused tap posts nothing, and a double tap posts once
  (one client id). "Build something else" (`idea_else`) sets nothing and only relays.
- **Delivery.** A signed-out visitor has no `/cable` socket, so the page polls
  (`GET /build/:token/turns`, `app/javascript/build_chat.js`) while a turn is pending;
  `WebChat.deliver!` marks a build-thread answer posted without a broadcast.

## Satellite chat: every app talks to the same thread

Alex McRitchie, 2026-10-27: "I want to make agent chat shared in all apps." One thread
per (person, soul), held by the hub, whichever app the person chats from (epic
`.agents/epics/agent-chat-primitive.md`; its Contract section is fixed). A satellite's
SERVER calls the hub; its browser talks only to its own app, which polls.

| Piece | Where |
|-------|-------|
| The two endpoints | `Api::V1::AgentChatsController`: `POST /api/v1/agent_chat/messages` (`soul`, `text`, `person`, `ip`; `201 {turn}`, `422`, `429` capped, `404` no web chat) and `GET /api/v1/agent_chat/turns` (`soul`, `person`, `after`, `limit` ≤ 50; `200 {turns, pending}`) |
| The app's credential | `AppCredential` (purpose `agent-chat`): the hub keeps the SHA-256 digest only, one live row per app and purpose (a partial unique index). `bin/rails app_credentials:mint APP=<slug>` prints the secret once, for 1Password `apps.<slug>.agent-chat` and the app's `AGENT_CHAT_TOKEN`; minting again revokes the old one. No credential, a wrong one or a revoked one: 401 |
| Which app reaches which soul | `config/agent_routes.yml` `web: apps: <slug>: [souls]` (`alex-build: [alex]`), and the soul must be in `web: souls:`; else 404 |
| The person and the thread | `AgentChat::Visitor`: `person.email` that is a hub User is their web person, thread `chat:<soul>:<user id>`; an email with no User is the person its `email` identity names, else a new public one (`AgentPerson.resolve!`), thread `chat:<soul>:person:<id>`; `person.anon_token` is a public Visitor (web identity `chat-anon:<HMAC digest>`), thread `chat:<soul>:anon:<digest>` (the token itself is never stored) |
| Inbound | `AgentChat::Ingest`: a `web` row, `channel_ref` `chat`, the app in `envelope.app` (never in the key), the visitor's IP hashed as /build's |
| Turns | `AgentChat::Turns`: a row is a user turn and, once answered, an agent turn, both carrying the row's id (`after` is a message id; key a turn by id and role). Status `pending` (received), `typing` (claimed), `answered`, `failed` (held, dead, or no words) |

- **Alex's persona.** Every answer the soul `alex` gives, on every channel (these `chat:alex:`
  threads, /build, Discord, the hub web chat, email), carries PERSONA
  (`ContextBuilder#persona_block`; no other soul's does): `docs/agents/agents/alex/persona.md`
  below its rule (Alex McRitchie's career, views, taste, family line and voice, first person as
  his AI; citations are HTML comments, stripped), capped at 4,000 characters, under rules
  written in CODE so an edit cannot drop them: never claim to be human; his views in the
  first person, his life as his; a fact the page lacks is "I haven't shared that here", and
  an opinion only when the page clearly implies it; no deals in progress, finances, lenders,
  addresses, phone numbers or personal email; family only as written (Lauren, Margot, their
  birthday months); no commitment of his time, prices or contracts beyond what is published;
  the Hormozi floor. The page is public by construction, so these threads stay answered at
  the public audience. The hub's public `/chat` (`Chat::AlexResponder`) prints the same block.
- **Who answers.** The person's role, as everywhere, and the public on the public-intake
  soul's chat threads: `Answerers#intake?` and its SQL guard answer `chat:alex:` as they
  answer `web:build:`, a prefix built in code. Another soul's public row is `held`.
- **Answered as the public, always.** The app's ONE credential names the person by email,
  so the hub cannot know who reads the answer: every `chat:` row is answered at the public
  audience whoever sent it, the owner's email included (`MemoryBundle#audience_person`,
  as on /build). No read action, internal context or owner audience; `private_channel?`
  is false, so no Google layer; and the person layer and notes read only what came from
  satellite chats, never the person's Discord, email or hub-chat history. The THREAD stays
  the person's, shared across apps.
- **The fold.** A signed-in post that also carries the visitor's `anon_token` moves that
  soul's anon thread into the person's thread first (`AgentChat::Ingest#fold!`): each row
  gets a `thread_folded` event, and the anon identity, the rows it wrote and their notes
  move to the person (`AgentPerson#link_identity!`, reassign). Once moved, the anon
  thread is empty, so the fold runs once.
- **Caps** (`AgentChat::Caps`, /build's numbers from `config/agent_answerers.yml`): signed
  out, `turns_per_request` per anon thread; signed in, `WebIngest::RATE_LIMIT` per
  thread per hour; and on EVERY post, the per-IP hourly and daily totals shared with
  /build (`BuildIntake::Caps#public_cap`). An email with no hub User counts toward the
  daily total as a signed-out visitor does, so made-up emails buy nothing. At a cap the
  hub answers 429 with the line to show and stores nothing.
- **The request log** never holds the visitor: `ip` (this controller only), `person.email`
  and `person.anon_token` are filtered (`config/initializers/filter_parameter_logging.rb`).
- **Delivery.** `WebChat.polled?` covers these threads as /build's: the answer is marked
  posted with no broadcast and the typing phase is kept on the row for the poll.
- **Minting without a terminal or `ps` showing the secret.** `SECRET_ONLY=1` writes the
  secret alone to stdout. Capture it in a shell variable and hand it on over stdin only,
  as the `credential-rotation` SOP does (never `op item edit field=…` or
  `heroku config:set NAME=…`, which put it on argv). The 1Password item must already
  exist (the agent makes it empty, per the `credential-filing` SOP):

  ```bash
  NEW=$(heroku run --no-tty -a mcritchie-studio -- \
          bin/rails app_credentials:mint APP=alex-build SECRET_ONLY=1 2>/dev/null | tail -n 1 | tr -d '\r') &&
  : "${NEW:?refusing: the mint printed nothing}" &&
  { printf '%s\n' "$NEW"; op item get "apps.alex-build.agent-chat" --vault <vault> --format json; } |
    ruby -rjson -e 'value = STDIN.readline.chomp; item = JSON.parse(STDIN.read)
      field = item.fetch("fields").find { |f| f["label"] == ARGV[0] } or abort "refusing: no field #{ARGV[0]}"
      field["value"] = value; print JSON.generate(item)' "<field>" |
    op item edit "apps.alex-build.agent-chat" --vault <vault> > /dev/null &&
  printf '%s' "$NEW" | bin/heroku-secret-set alex-build AGENT_CHAT_TOKEN
  unset NEW
  ```

## Viewing a run

Each soul's Claude runs from its own folder, `~/.agents/mailbox/<soul>`
(`AGENT_MAILBOX_HOME` overrides the root), created on demand, so a soul's
transcripts sit together. What `claude -p --output-format json` returns was
checked on 2026-10-14. The envelope has `session_id`, `num_turns`,
`duration_ms`, `usage.output_tokens`, `usage.output_tokens_details.thinking_tokens`
and `modelUsage` (keyed by model). It has no reasoning text. The reasoning
is read from the session transcript (`~/.claude/projects/<cwd slug>/<session_id>.jsonl`),
from its assistant `thinking` blocks. Thinking is often redacted (a block with a
signature and no text), so `run_meta.reasoning_source` says which case applies:
`transcript`, `redacted`, `none` or `no_transcript`.

The worker sends `claude_session_id`, `claude_cwd`, `reasoning` (capped at 20,000)
and `run_meta` with complete. `run_meta` is the run's full summary: input, cache
read and cache write tokens, output and thinking tokens, `total_cost_usd`,
`duration_ms`, `num_turns` and the model, plus the sender's `audience`, which the
board stamps itself. It is the usage meter's source ([`agent-usage.md`](agent-usage.md)).
They are stored on the row (`AgentMessage.run_record` caps each). `/admin/agent_messages/:id` and
`bin/agent-inbox show <id>` show them with a ready line to reopen the session on
the machine that ran it:

```bash
cd ~/.agents/mailbox/alex && claude --resume <session_id>
```

Resuming is for an operator reading a run. The answer path resumes only in a
warm domain, for owner and team turns ("Warm sessions" below).

## Typing: the bot shows it is answering

Step 1 of real-time Discord agents (Alex McRitchie, 2026-10-16; the plan is
`.agents/epics/domain-agents.md`, "Real-time"). While an answer runs, the bot
that will post the reply shows "typing…" in the message's channel or thread.

- **Who drives it.** `bin/dispatcher`, because only it knows a run is alive. A
  hub loop keyed on `status == claimed` would keep typing for a dead
  dispatcher's message until its 10-minute lease lapsed.
  Discord shows one typing pulse for about ten seconds, or until that bot posts.
  The dispatcher asks the board for a pulse as the run starts (right after the
  claim and the context read), then every `TYPING_EVERY` (7 seconds) while the
  run's thread lives, for at most `TYPING_CAP` (180 seconds) after it started.
  The ask is `POST /api/v1/agent_messages/:id/typing { worker }`.
- **Why the board sends it.** The bot tokens live on the hub, not on the Mac, and
  the reply's bot choice is the hub's (`AgentMessages::BotSelector`). The
  endpoint only queues `AgentMessageTypingJob`, so a slow Discord never holds the
  dispatcher's main loop, and the job calls `POST /channels/{id}/typing`.
- **The same bot as the reply.** The soul's own bot when
  `DISCORD_BOT_TOKEN_<SOUL>` is set, else the shared bot. A 401/403 from the
  soul's bot falls back to the shared bot in the same call and records one
  `typing_bot_refused` event (the ENV name only), so later pulses skip the soul's
  bot. A soul's bot the reply job already found refused (`reply_bot_refused`) is
  skipped as well. A typing refusal never changes the reply's own choice. With no
  token, nothing types.
- **Only for answers that will come.** The board re-checks every pulse
  (`AgentMessage#typing_refusal`): the message is `claimed` by that worker, it is
  a Discord or web-chat message (`AgentMessage::TYPING_CHANNELS`), its sender is answered (`AgentMessages::Answerers`, or a hold
  an admin released), and the claim is under `AgentMessage::TYPING_CAP` old. A
  held or unrouted message is never claimed, so it never types. Anyone but the
  holder gets 409 `NOT_HOLDER`; a quiet "no" is a 200 whose `meta.typing` says
  `not_typing_channel`, `not_answered` or `capped`, and the dispatcher stops pulsing
  that run on any answer but `queued`.
- **How it stops.** The dispatcher reaps a finished run before it pulses, so
  pulses end with the run, whatever the end: the reply, a failed or raised run, a
  usage limit, a signed-out CLI, a give-back. The last pulse fades within ten
  seconds; Discord has no call to cancel it, and a posted reply clears it at once.
  An answer that takes longer than three minutes stops typing at the cap and
  posts without it. A pause with runs in flight can stretch one gap to about 12
  seconds (the paused loop sleeps up to 5).
- **Best effort.** A Discord error on a pulse (a 429, a 5xx, a timeout) is logged
  by class and dropped, never retried: the next pulse is seconds away. Any
  error on the ask stops that run's typing and logs one id-only line
  (`typing for #N refused: …` from the board, `typing for #N failed (<Class>)`
  for anything else); the answer goes on.
- **Rate limits.** Discord does not publish a fixed number for the typing route;
  it buckets per channel and reports the bucket in `X-RateLimit-*` headers, under
  the bot's global 50 requests per second. One pulse per 7 seconds per channel,
  at most 5 runs (one per thread), is under 1 request per second for the whole
  bot. This was reasoned from Discord's documented model, not measured against
  Discord: the Mac holds no bot token, and the tests stub the HTTP.

### Streaming (next step, not built)

The answer still arrives whole: `claude -p --output-format json`, then one post.
Streaming it (post early, then edit as text arrives) is designed here and not
built, because it would weaken two guarantees today's path keeps:

1. **The sections never post.** The notes section and the PROPOSAL block are cut
   from the FINAL text, by the worker and again by the board in `complete!`
   (`AgentMailbox::NoteBlock`, `AgentMailbox::ProposalBlock`, loose patterns).
   A streamed edit would show a section, or half of its delimiter, before the cut
   could see it.
2. **Status is read only from fields the model cannot write** (`ClaudeRun`: exit
   status, `is_error`, `api_error_status`). Text streamed before the `result`
   event arrives could post a model-written "usage limit reached" as an answer,
   or the text of a run that then ends `is_error`.

The design, for the step that builds it:

- Run `claude -p --output-format stream-json --verbose --include-partial-messages`;
  the Responder reads the NDJSON on its thread and keeps a draft buffer from the
  model's `text_delta` events only, never from `result`.
- A **safe prefix**: the draft shows text only up to the first line that could
  start a section under the loose patterns (a held-back tail), so a section never
  appears even half-formed.
- A board-mediated **draft**: `POST /api/v1/agent_messages/:id/draft { worker, text }`
  from the dispatcher's main loop (it stays the only board caller), at most one
  every 1.5 seconds per message. A job posts the first draft (with its own nonce)
  and then PATCHes that message, under Discord's per-channel edit bucket. The draft
  starts after about 200 characters or 3 seconds, and typing covers the time before.
- **The final word stays the board's.** `complete!` cuts the sections as today,
  and the reply job EDITS the draft to the cut text (the confirm line included)
  instead of posting a new message; a separate `draft_external_id` keeps the
  once-only `reply_external_id` rule intact. Over 2,000 characters, the edit holds
  the first part and the rest posts as a follow-up.
- **Failure deletes the draft.** A run whose envelope ends `is_error` (a usage
  limit, a signed-out CLI, a failure) deletes the draft and is handled as today.

### Warm sessions

Phase 7 step 2 (Alex McRitchie, 2026-10-16; plan: `.agents/epics/domain-agents.md`). A warm
domain answers its owner and team messages by resuming ONE Claude session, held
by a board lease and checkpointed after every turn, so a standby machine can take
it over. **Off by default**: no domain sets the flag, and with it off the
dispatcher's path is exactly the one-run-per-message path above
(`test/lib/agent_warm_session_test.rb` and `agent_dispatcher_warm_test.rb` pin
this).

**Scope.** The domain's front-door soul only (`soul:` in
`config/agent_domains.yml`), for owner and team senders only. A client's or the
public's message, a released hold, and any helper soul mapped to the domain stay
one run per message, so untrusted text never persists in a session
(`WarmSession.eligible?`, from the board's audience in the bundle). Every text a
warm prompt carries must be the sender's own, so these answer cold too: a thread
holding any turn that is not the sender's (`own`, set on the board); a message,
or an own earlier turn, carrying quoted or forwarded material
(`WarmSession.quotes?`: a `>` line, an "On … wrote:" line, a forwarded or
original-message banner, a From: header followed by Sent:/Date:); and a thread
whose newest proposal was not offered to this sender on a turn the prompt shows
(the bundle's `proposals.last.own` and `source_message_id`); and a message
whose bundle carries an owner's Google snapshot (`google_context`, "The Google
layer"). A verbatim paste
with no such marker cannot be told from the sender's own words and is treated as
theirs. Later: one session per (domain, user).

**The switch.** `warm_session: true` on a domain in `config/agent_domains.yml`
(literally `true`; anything else is off), and optionally `consolidate_at` (an
integer from 10,000 to 1,000,000; default 150,000). The flag lives in config so
that turning it on is a reviewed deploy, not a click.

**The lease.** `agent_domain_sessions` (`AgentDomainSession`; not
`agent_sessions`, which are the builder sessions), one row per domain: `holder`,
`lease_expires_at` (5 minutes), `heartbeat_at`, `claude_session_id` (the head),
`generation`, `turns`, `context_tokens`, the `checkpoint` (an Active Storage
attachment: the gzipped transcript, at most 4 MB), `checkpointed_at`,
`lease_key_digest`, and the last reported fault (`last_fault`, `last_fault_at`).
The lease lives on the row, as `AgentMessage`'s does: a holder that dies loses it
when it lapses, with no sweeper. The dispatcher renews it on its minute ping.
Every write is holder-checked (409 `NOT_HOLDER`), and a lapsed holder's late
checkpoint or consolidation is refused (409 `LEASE_LAPSED`). The endpoints, under
`/api/v1/agent_domain_sessions/:domain/`, all POST: `acquire`, `renew`,
`checkpoint` (upload), `checkpoint_read` (restore), `release`, `consolidate` and
`fault`. They take the shared token or an admin session; a soul's own session
reaches none of them, because a checkpoint is owner and team conversation text.

**The lease key.** The shared token is in every agent shell, the worker name is
the caller's word, and `GET` index shows the holder's name, so a name opens
nothing. The acquire that takes a lease mints a random key and answers it once
(`meta.lease_key`); the board keeps only its SHA-256. Every holder call, the
checkpoint read included, presents it in the request body (never a URL), and a
wrong or missing key reads as `NOT_HOLDER`. A live lease the caller holds by name
but not by key is `LEASE_HELD`, so a process that lost its key (a crash) waits
out the 5-minute lease like any other worker. Release and reset clear the key.
Not admin-session-only: the standby restoring a checkpoint is a dispatcher, which
holds only the shared token. The remaining reach is a lease that is free or
lapsed: whoever takes it gets its transcript, which is the takeover itself, and
the row and log name the taker.

**Checkpoint storage.** The board uploads the blob before the row says
checkpointed (`ActiveStorage::Blob.create_and_upload!` inside the holder's lock,
not `attach(io:)`, which uploads after commit). An upload that fails rolls the row
back to its previous, readable checkpoint and answers 500 (ErrorLog through
`rescue_and_log`), so the row never names a blob storage never received.

**A turn** (`AgentMailbox::Dispatcher#warm_turn`, all board calls on the main loop):

1. The dispatcher claims the message exactly as today (same guard, same thread
   and person order) and reads its bundle.
2. When the message is eligible and no warm turn is already running on that
   domain here, it acquires the lease. Another live holder answers 409
   `LEASE_HELD`: the message is answered per message, never queued.
3. Unless the local transcript is the one THIS PROCESS last checkpointed or
   restored in this lease (same head, same `checkpointed_at`, same SHA-256), it
   downloads the checkpoint and writes it under the soul folder's Claude project
   folder, 0600 in a 0700 folder. No clock is compared: a file's mtime is this
   machine's clock and `checkpointed_at` the board's, and a machine that lost
   the lease mid-turn can hold a newer-looking file that is not the session.
4. It runs `claude -p --safe-mode --tools "" --output-format json --resume <id>`:
   the cold command plus `--resume`, the same allow-listed environment, the
   envelope read by the same status rules (`ClaudeRun`). A domain's first turn,
   or the first after a consolidation, runs without `--resume`.
5. **Every turn carries the board's rules again** (`ContextBuilder#warm_prompt`).
   A resumed turn's prompt is the audience and its rules, HOW TO ANSWER (the
   STE-80 reply rule, the fence, the catalog, the action output), USER, THREAD and the fenced message,
   each cut byte for byte from the cold prompt. The role doc, DOMAIN and PERSON
   are left out: the session already holds them. The audience is still resolved
   on the board from the person's role, and `claimable`, the bundle's audience
   and `AgentProposal.record_from!` are server-side, so a resumed session cannot
   skip the audience or owner checks.
6. It completes the message (the run summary as today, plus `run_meta.warm`:
   `fresh` or `resumed`; the reasoning is the last turn's only), then uploads the
   transcript of the envelope's `session_id`, which becomes the new head whether
   or not the CLI kept the id. A superseded transcript in the soul's folder is
   deleted.
7. A failed run, a failed checkpoint, or a checkpoint that will not restore drops
   the lease; the message's own handling is today's. The fallback is always the
   cold path. A failed checkpoint or restore is also reported to the board
   (`fault`: one of `checkpoint_failed` or `restore_failed` and the error's class,
   never its text), which keeps it on the row and records it in ErrorLog; the next
   good checkpoint clears it. The dispatcher log says `CHECKPOINT FAILED`.
8. Giving a lease up (a release, a handback, a refused renew, a stop, a
   consolidation) removes the transcripts this process held for it, so a standby
   keeps no copy of the owner's conversation once it hands back.

**The standby.** A second dispatcher (Alex McRitchie's work machine) is registered on the
board as `standby` for a list of warm domains: `agent_dispatchers.role` and
`standby_domains`, set by `bin/rails agent_dispatchers:role` (the
[`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md) SOP, "Standby on
a second machine"). The role belongs to the host, so a restart inherits it. While
a primary pings (and its last ping is not `stopping`), the board answers a
standby's claim empty at once (`standby_primary_live`, no long poll), and the
dispatcher does not ask. When the primary is silent for 5 minutes, the standby
claims its domains' souls only, takes each lapsed lease, restores the checkpoint
and answers. **Handback is only between turns.** A primary refused by a standby's
lease marks the row `handback_requested`; the standby releases after its current
turn checkpoints (or on its next ping when idle, and whenever a primary is live
again), and the primary's next turn restores that checkpoint. Neither side ever
resumes a session the other is mid-turn in. The floor alert reads primaries only,
so a live standby never hides a silent primary; its alert names the standby that
is covering.

**Consolidation.** When a turn's `context_tokens` (input + cache read + cache
write) reach the domain's `consolidate_at`, or its transcript passes the 4 MB
checkpoint limit, the holder runs one more no-tools `--resume` turn asking for its
own notes (`WarmSession::SUMMARY_PROMPT`). The board stores them as an
`agent_domain_summaries` row (domain, generation, text, source session, turns
covered), bumps the generation and clears the session. The next turn starts a
fresh session from the whole cold prompt with the summary inside the fence,
labelled as the soul's own notes. Only owner and team text ever reaches a warm
session, so the summary carries no client or public text forward.

**Usage.** Each turn's run summary is stored as today. A warm turn is mostly
cache reads, which the meter shows as such. Owner and team turns are never
metered against an allowance.

**Observing.** `bin/rails agent_dispatchers:sessions` (each domain's lease, head,
checkpoint size, any handback and the last fault), `agent_dispatchers:list` (each row's role),
and `GET /api/v1/agent_domain_sessions`. The dispatcher log says `warm <domain>:`
for every lease event (took, restored, checkpointed, consolidating, released and
why); it never logs message text.

**Tests.** `test/models/agent_domain_session_test.rb` (acquire, renew, lapse,
takeover, handback, the late checkpoint, consolidation, the lease key, the
upload that fails, faults),
`test/integration/agent_domain_session_race_test.rb` (two acquirers on real
connections), `test/models/agent_dispatcher_standby_test.rb` (the role, the claim
scope, the floor alert), `test/lib/agent_warm_session_test.rb` (eligibility, the
trigger, the transcript round trip, the per-turn prompt, the flag-off path) and
`test/integration/agent_dispatcher_warm_test.rb` (a resumed turn and its
checkpoint, a standby resuming after a lapse, handback between turns, a client
kept one-shot, consolidation, flag off, a newer-looking local file never
resumed, transcripts removed with the lease, a failed checkpoint reported, a
quoted owner message kept cold).

## Setup

Nothing reads Discord until a bot token is set. The code ships inert.

- **A bot (once per bot) and each client's invite**: Steffon's
  [`discord-bot-setup`](../agents/steffon/sops/discord-bot-setup.md). It creates
  the bot's Discord application, turns on the Message Content Intent, files the
  token as `agents.discord.<bot>`, and routes each client's IDs into
  `config/agent_routes.yml`. Filed today: `agents.discord.xan` (the shared bot
  that reads the guild and posts every reply), `agents.discord.avi` and
  `agents.discord.turf` (bot users a mention routes by; their tokens, set as
  `DISCORD_BOT_TOKEN_AVI` and `DISCORD_BOT_TOKEN_TURF_MONSTER`, are read only by
  the reply job and the CTO reports, which post that soul's replies and its
  app's `cto_report:<domain>` report as its own bot; not set on any
  app yet, 2026-10-16), `agents.discord.tyrion` (no token: his lives on the
  OpenClaw host, so his replies fall back to the shared bot) and
  `agents.discord.mack` (read by nothing yet).
- **The client's own half** (server, `#agents` channel, mentionable roles,
  Developer Mode, the IDs): the public guide at `/integrations/discord`
  (`app/views/integrations/discord.html.erb`).
- **Our own live test** (2026-10-14) uses Alex's own bot, not roles: the whole
  McRitchie Studio guild (`1332466565203103744`, no channel entries), and the soul
  `alex` (then `ray`) routed by a mention of the Alex bot user (`users`, not `roles`). The ids
  are in `config/agent_routes.yml`. `DISCORD_AGENT_BOT_TOKEN` is set from
  `agents.discord.xan` on `mcritchie-studio` only
  ([`credential-inventory.md`](../modules/credential-inventory.md)).

## Test protocol

Post in any channel or thread of the McRitchie Studio guild (`lobster-tank` is the
quiet one), mentioning the Alex bot user (`@Alex` in Discord). The gateway stores it within a
second or two; with the dispatcher installed the answer follows and nothing else is needed;
the rows below run the heartbeat by hand, with the dispatcher stopped
(`bin/dispatcher uninstall`) so the two do not compete. Avi, Alex and Turf are
routed there; the rows use Alex, and any routed soul works the same way.

| Scenario | Do | Expect |
|----------|----|--------|
| Serial | Post `@Alex what is building?` (the bot's Discord name). Run `bin/heartbeat alex --channel discord`, then run it again | The first run answers in the channel; the second prints `nothing for alex` |
| Parallel | Post `@Alex one` and `@Alex two` as separate messages. Start two `bin/heartbeat alex --channel discord --once` at the same moment | Each message is answered once. Neither is read twice and no reply is doubled |
| Two agents | Needs a second soul routed in the guild (a role, or a second bot user such as Mack's). Then post to each and run `bin/heartbeat alex --channel discord` | Alex answers only its own message; the other stays `received` until that soul's heartbeat runs |
| Unaddressed | Post a message that mentions nobody and replies to nothing | No row is stored; the admin page does not list it |

The inbound half (guild scope, the addressed-only filter, overrides, the backstop)
is `test/services/agent_messages/discord_poll_test.rb` and `router_test.rb`; the
gateway protocol and leader lock are `gateway_session_test.rb` and
`gateway_leader_lock_test.rb`; the IDENTIFY budget, `session_start_limit` and the
TLS deadline are `gateway_identify_budget_test.rb` and
`discord_gateway_budget_test.rb`; the listener runs end to end over a real websocket
against a fake gateway in `test/integration/discord_gateway_test.rb`. The claim
side is encoded with real database concurrency:
`test/integration/agent_message_claim_race_test.rb`,
`test/integration/heartbeat_mailbox_test.rb`, `test/models/agent_message_test.rb`.
The dispatcher's loop (claims, the cap, renewal, the usage-limit refund and
pause, a graceful stop) is `test/integration/agent_dispatcher_loop_test.rb`; the
long poll is in `test/controllers/api/v1/agent_messages_controller_test.rb`.
Typing is `test/integration/agent_dispatcher_typing_test.rb` (pulses, then the
reply as the same bot; stop on failure and at the cap) and
`test/jobs/agent_message_typing_job_test.rb` (the bot choice, the fallback, the
guard and the unanswered audiences). The web chat's thinking and typing phases
are `test/lib/agent_claude_stream_test.rb` (the phase off a recorded stream,
`test/fixtures/files/claude_stream_thinking.jsonl`, and the same answer as the
json envelope), `test/integration/web_chat_thinking_typing_test.rb` (the loop:
thinking, an immediate typing pulse, the answer; the `/build` poll; Discord
unchanged), `test/views/agent_typing_component_test.rb` and
`test/javascript/agent_chat_test.js`.

## Observing

- `/admin/agent_messages` shows the dispatcher row (live, paused with its reason
  and reset, or silent) and lists every message with its soul, status, claim
  holder, lease, attempts and age, filtered by soul, status and channel. A
  message's page shows the untrusted text, the answer, the action, the link to
  the Discord reply, and the timeline: received, routed or unrouted, claimed,
  lease_renewed, lease_expired, released (with `code` and `attempt_refunded` on
  a usage-limit give-back), dead_lettered, completed, reply_bot_refused (the
  soul's own bot was refused; an `ErrorLog` row says why), typing_bot_refused
  (the soul's own bot could not show typing; the shared bot typed), and reply_posted
  (with `via`), reply_skipped or reply_failed, and the usage gate's
  usage_warned (claimed past 80% of the app's allowance) and usage_capped
  (answered in code at the cap; [`agent-usage.md`](agent-usage.md)). The row's
  `reply_status` (queued, posted, skipped when no bot token is set, failed when the job's five tries are spent)
  is the Reply column.
- A completed message's page also shows its Claude run: the resume line, the
  envelope numbers and the reasoning when the transcript carried any ("Viewing a
  run" above).
- `bin/agent-inbox list [--soul S] [--status S]`, `bin/agent-inbox show <id>`,
  and `bin/agent-inbox tail [--soul S]` read the same rows through the API.
- A Discord read error is kept on the channel's cursor
  (`agent_message_cursors.last_error`) and logged with the `[agent-messages]`
  prefix.
- The gateway logs with `[agent-messages] discord gateway`: `connected`,
  `resumed`, `closed with <code>; reconnecting`, `standing by` (another process
  holds the lock), `leader lock lost; standing down`, and the fatal
  `closed the connection with <code>; not reconnecting`. Read them on the worker
  dyno's log.

## Limits of phase 1

- Discord, email and the web chat only. Email reaches a CTO only through the team@ Resend
  inbound, and is trusted only by the topmost SES verdict ("Email"). The web chat
  answers whole messages, with typing but no streaming ("Web chat"). The gateway stores a Discord message within seconds; while it is down
  (a deploy, a reconnect, a stood-down leader) the backstop catches up within 10
  minutes, so an answer takes the Claude run plus, at worst, that.
- One gateway connection, unsharded. That holds below 2,500 guilds; past it
  Discord requires sharding (close 4011, which stops the listener).
- The backstop reads text and announcement channels and active threads. It
  skips archived threads and voice-channel text chat, which only the gateway
  sees.
- One read-only action per soul, for owner and team senders only. The only write
  on a message's behalf is a proposal the owner confirmed with `go`: a named
  query, or a `designed` board task. Operations wait for Phase 2.
- One primary dispatcher, on one Mac. It answers only while that Mac is awake and
  signed in to Claude; the floor alert says when it is not. A standby on a second
  machine is built but registered nowhere yet ("Warm sessions"); until it is,
  nothing answers while the Mac sleeps. A dispatcher that dies
  mid-answer stops renewing, so its claim lapses after 10 minutes and its late
  complete is refused (409) when another worker has taken the message.
- Routing ids (guilds, souls, overrides) live in `config/agent_routes.yml`, so changing them takes a deploy,
  and the dispatcher reads its soul list from the checkout it runs from.

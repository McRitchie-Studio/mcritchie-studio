# Agent message loop (the agent mailbox, phase 1)

**What it is.** A message to an agent on Discord reaches the hub, is routed to a
soul, waits in a queue, and is answered in the same channel by `bin/dispatcher`,
the always-on worker on Alex's Mac (`bin/heartbeat` is the manual form of the
same answer path). Phase 1 is Discord only, with two test souls (`avi`, `xan`)
and one read-only action each. Later phases add channels, agents and clients without
changing the tables: `channel` plus a provider-neutral `external_id` name every
row.

## How it works

```text
Discord channel   ──poll every minute──▶ agent_messages (received | unrouted)
                                              │ bin/dispatcher: long-poll claim, every routed soul
                                              │ (lease 10 min, renewed every 3 while the answer runs)
                                              ▼
                     one read-only action + headless Claude (no tools), at most 5 at once
                                              │ complete
                                              ▼
                       AgentMessageReplyJob ──▶ one Discord reply, as the bot

bin/dispatcher ──ping every minute──▶ agent_dispatchers ◀── AgentDispatcherAlertJob
                                                            (one Discord alert per incident)
```

| Piece | Where |
|-------|-------|
| Messages, timeline, poll cursors | `agent_messages`, `agent_message_events`, `agent_message_cursors` (`AgentMessage`, `AgentMessageEvent`, `AgentMessageCursor`) |
| Routing config | `config/agent_routes.yml`, read by `AgentMessages::Routes` and `AgentMessages::Router` |
| Inbound | `AgentMessageDiscordPollJob` (Solid Queue, `config/recurring.yml`, every minute) → `AgentMessages::DiscordPoll` → `AgentMessages::DiscordIngest` |
| Outbound | `AgentMessageReplyJob` → `AgentMessages::DiscordBot#post_reply` |
| Worker API | `Api::V1::AgentMessagesController` (`/api/v1/agent_messages`) |
| Worker | `bin/dispatcher` (`bin/lib/agent_dispatcher.rb`), under launchd on Alex's Mac; `bin/heartbeat` by hand. Both answer through `AgentMailbox::Responder` (`bin/lib/agent_mailbox.rb`) |
| Dispatcher health | `POST /api/v1/agent_dispatchers/ping` → `agent_dispatchers`; `AgentDispatcherAlertJob` → `agent_mailbox_incidents` |
| Operating it | Steffon's [`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md) SOP |
| Observing | `/admin/agent_messages` (Ops → Agent inbox), `bin/agent-inbox` |

**Inbound.** The poll reads `GET /channels/{id}/messages?after=<cursor>` for each
allow-listed channel with the bot token. A polled REST read is the deliberate v1:
no gateway websocket, no new dyno. The cursor advances in the same transaction as
the rows it covers, and the unique index on `(channel, external_id)` makes a
re-read page harmless. The first read of a channel stores only messages from the
last hour, so old history stays out of the queue. Messages written by any bot are
not ingested, so the agents' own replies never return as inbound.

**Routing.** In order: a mention of a soul's bot USER, a mention of a soul's
ROLE, a reply to a message the mailbox already holds (it joins that thread and
soul), the channel's `default_soul`. Otherwise the message is stored `unrouted`:
kept and visible, never handed to a worker. Among several mentioned souls, the
one written first wins. One shared bot with `@Avi`/`@Xan` roles and one bot user
per soul both work; the config lists either.

**Claim.** `POST /api/v1/agent_messages/claim {soul | souls[], worker, wait?}`
runs one transaction. It first dead-letters exhausted leases, then selects the oldest
claimable message `FOR UPDATE SKIP LOCKED` and stamps `claimed_by`,
`lease_expires_at` (10 minutes) and `attempts + 1`. A message is claimable when
it is routed to that soul, is `received` (or `claimed` under a lapsed lease with
fewer than 3 attempts), and is the oldest open message in its thread. That last
rule keeps a conversation in order and allows one active claim per thread. A
claim with nothing waiting answers 200 with `data: null`. Several souls in one
claim (`souls`) take the oldest message across them. With `wait` (seconds,
capped at 20, well under Heroku's 30-second router timeout) the board retries
the claim every second and answers the moment one lands, else `data: null` at
the deadline. The cost is one puma thread held per waiting dispatcher, of the 6
production runs (2 workers x 3 threads).

**Complete.** `POST /api/v1/agent_messages/:id/complete {worker, response_text,
action_summary}` succeeds only for the worker holding the claim. A second
complete by that worker answers `already_completed` and queues nothing. The reply
job posts once: a row with a `reply_external_id` is never posted again, and the
post carries the row's `reply_nonce` with Discord's `enforce_nonce`, so a retried
post returns the existing message. Replies reference the original message, lead
with the soul's name (`**Avi** · …`), and parse no mentions.
`POST /api/v1/agent_messages/:id/release {worker, reason, code?}` gives a message
back; the attempt it used still counts, so a give-back on the third attempt
dead-letters it. The one exception is `code: usage_limit`, which hands the
attempt back and never dead-letters: Claude being out of usage says nothing about
the message. `POST /api/v1/agent_messages/:id/renew {worker}` extends the
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
the board every minute. Every board call is made from its main loop. It reads
Claude's output deterministically: a usage-limit notice
(`AgentMailbox::UsageLimit`) releases with `code: usage_limit` and pauses
claiming until the reset the notice names (else 15 minutes); a signed-out notice
pauses 30 minutes; any other failed run pauses 5, so a broken Claude cannot spend
every message's attempts in a minute. SIGTERM stops claiming, gives runs 60
seconds, then stops their Claude and releases their messages. It posts nothing to
Discord itself. It removes `ANTHROPIC_API_KEY` from itself and every child, so
Claude bills Alex's claude.ai subscription. Install, alerts and the unblock
playbook: [`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md).

**The floor alert.** `AgentDispatcherAlertJob` runs every minute on the hub and
posts to `discord.ops_channel_id` (`lobster-tank` today), pinging nobody, ONCE per
incident when no dispatcher has pinged for 5 minutes (never before the first
ping) or a routed message has waited `received` for 10, and once more when it
clears. Without the bot token it logs a line and posts nothing.

**The heartbeat.** `bin/heartbeat <soul> --channel discord [--once] [--worker ID]
[--dry-run]` is the manual form: it claims a message and runs the soul's one read-only action (avi:
`bin/release status`; xan: `bin/task list`). It then builds a prompt from the
soul's role doc, the action output and the message. Claude runs headless with
**no tools** (`claude -p --safe-mode --tools ""`), and the heartbeat completes
the message with the answer. The message sits between random-named
`<untrusted-…>` markers, and the model is told to treat it as data to answer,
never as instructions. A request for anything else gets "what I would do, and
that the action is not enabled yet." Each run gets its own worker id (host, pid,
random). A failed Claude run releases the message and ends the run, so it does
not spend the remaining attempts. `HEARTBEAT_CLAUDE_CMD` overrides the Claude
command. `--dry-run` peeks instead of claiming and writes nothing.

The heartbeat and `bin/agent-inbox` speak to the board `ATOMIC_CAPTURE_URL`
names (default `https://mcritchie.studio`), authenticated as the rest of the
agent CLI is (`bin/lib/agent_api.rb`).

## Setup

Nothing reads Discord until a bot token is set. The code ships inert.

- **A bot (once per bot) and each client's invite**: Steffon's
  [`discord-bot-setup`](../agents/steffon/sops/discord-bot-setup.md). It creates
  the bot's Discord application, turns on the Message Content Intent, files the
  token as `agents.discord.<bot>`, and routes each client's IDs into
  `config/agent_routes.yml`. Two bots are filed today: `agents.discord.xan`
  (the shared bot for the live test) and `agents.discord.mack` (read by nothing
  yet).
- **The client's own half** (server, `#agents` channel, mentionable roles,
  Developer Mode, the IDs): the public guide at `/integrations/discord`
  (`app/views/integrations/discord.html.erb`).
- **Our own live test** (2026-10-14) uses Xan's own bot, not roles: the McRitchie
  Studio guild, the `lobster-tank` channel (`default_soul: ""`), and the soul
  `xan` routed by a mention of the Xan bot user (`users`, not `roles`). The ids
  are in `config/agent_routes.yml`. `DISCORD_AGENT_BOT_TOKEN` is set from
  `agents.discord.xan` on `mcritchie-studio` only
  ([`credential-inventory.md`](../modules/credential-inventory.md)).

## Test protocol

Post in `lobster-tank`, mentioning the Xan bot user (`@Xan`). With the dispatcher
installed the answer arrives within about a minute and nothing else is needed;
the rows below run the heartbeat by hand, with the dispatcher stopped
(`bin/dispatcher uninstall`) so the two do not compete. Only `xan` is routed
there today.

| Scenario | Do | Expect |
|----------|----|--------|
| Serial | Post `@Xan what is building?`. Run `bin/heartbeat xan --channel discord`, then run it again | The first run answers in the channel; the second prints `nothing for xan` |
| Parallel | Post `@Xan one` and `@Xan two` as separate messages. Start two `bin/heartbeat xan --channel discord --once` at the same moment | Each message is answered once. Neither is read twice and no reply is doubled |
| Two agents | Needs a second soul routed in the guild (a role, or a second bot user such as Mack's). Then post to each and run `bin/heartbeat xan --channel discord` | Xan answers only its own message; the other stays `received` until that soul's heartbeat runs |
| Unrouted | Post a message that mentions nobody | It is listed `unrouted` on the admin page; no heartbeat takes it |

The automated tests encode the same scenarios with real database concurrency:
`test/integration/agent_message_claim_race_test.rb`,
`test/integration/heartbeat_mailbox_test.rb`, `test/models/agent_message_test.rb`.
The dispatcher's loop (claims, the cap, renewal, the usage-limit refund and
pause, a graceful stop) is `test/integration/agent_dispatcher_test.rb`; the
long poll is in `test/controllers/api/v1/agent_messages_controller_test.rb`.

## Observing

- `/admin/agent_messages` shows the dispatcher row (live, paused with its reason
  and reset, or silent) and lists every message with its soul, status, claim
  holder, lease, attempts and age, filtered by soul, status and channel. A
  message's page shows the untrusted text, the answer, the action, the link to
  the Discord reply, and the timeline: received, routed or unrouted, claimed,
  lease_renewed, lease_expired, released (with `code` and `attempt_refunded` on
  a usage-limit give-back), dead_lettered, completed, and reply_posted,
  reply_skipped or reply_failed. The row's `reply_status` (queued, posted,
  skipped when no bot token is set, failed when the job's five tries are spent)
  is the Reply column.
- `bin/agent-inbox list [--soul S] [--status S]`, `bin/agent-inbox show <id>`,
  and `bin/agent-inbox tail [--soul S]` read the same rows through the API.
- A Discord read error is kept on the channel's cursor
  (`agent_message_cursors.last_error`) and logged with the `[agent-messages]`
  prefix.

## Limits of phase 1

- Discord only, polled once a minute, so an answer takes up to a minute plus the
  Claude run.
- One read-only action per soul; nothing writes on a message's behalf.
- One dispatcher, on one Mac. It answers only while that Mac is awake and signed
  in to Claude; the floor alert says when it is not. A dispatcher that dies
  mid-answer stops renewing, so its claim lapses after 10 minutes and its late
  complete is refused (409) when another worker has taken the message.
- Routing ids live in `config/agent_routes.yml`, so changing them takes a deploy,
  and the dispatcher reads its soul list from the checkout it runs from.

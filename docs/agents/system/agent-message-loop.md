# Agent message loop (the agent mailbox, phase 1)

**What it is.** A message to an agent on Discord reaches the hub, is routed to a
soul, waits in a queue, and is answered by that soul's heartbeat in the same
channel. Phase 1 is Discord only, with two test souls (`avi`, `xan`) and one
read-only action each. Later phases add channels, agents and clients without
changing the tables: `channel` plus a provider-neutral `external_id` name every
row.

## How it works

```text
Discord #agent-desk ──poll every minute──▶ agent_messages (received | unrouted)
                                              │ bin/heartbeat <soul>: claim (lease 10 min)
                                              ▼
                     one read-only action + headless Claude (no tools)
                                              │ complete
                                              ▼
                       AgentMessageReplyJob ──▶ one Discord reply, as the bot
```

| Piece | Where |
|-------|-------|
| Messages, timeline, poll cursors | `agent_messages`, `agent_message_events`, `agent_message_cursors` (`AgentMessage`, `AgentMessageEvent`, `AgentMessageCursor`) |
| Routing config | `config/agent_routes.yml`, read by `AgentMessages::Routes` and `AgentMessages::Router` |
| Inbound | `AgentMessageDiscordPollJob` (Solid Queue, `config/recurring.yml`, every minute) → `AgentMessages::DiscordPoll` → `AgentMessages::DiscordIngest` |
| Outbound | `AgentMessageReplyJob` → `AgentMessages::DiscordBot#post_reply` |
| Worker API | `Api::V1::AgentMessagesController` (`/api/v1/agent_messages`) |
| Worker | `bin/heartbeat` (`bin/lib/agent_mailbox.rb`) |
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

**Claim.** `POST /api/v1/agent_messages/claim {soul, worker}` runs one
transaction. It first dead-letters exhausted leases, then selects the oldest
claimable message `FOR UPDATE SKIP LOCKED` and stamps `claimed_by`,
`lease_expires_at` (10 minutes) and `attempts + 1`. A message is claimable when
it is routed to that soul, is `received` (or `claimed` under a lapsed lease with
fewer than 3 attempts), and is the oldest open message in its thread. That last
rule keeps a conversation in order and allows one active claim per thread. A
claim with nothing waiting answers 200 with `data: null`.

**Complete.** `POST /api/v1/agent_messages/:id/complete {worker, response_text,
action_summary}` succeeds only for the worker holding the claim. A second
complete by that worker answers `already_completed` and queues nothing. The reply
job posts once: a row with a `reply_external_id` is never posted again, and the
post carries the row's `reply_nonce` with Discord's `enforce_nonce`, so a retried
post returns the existing message. Replies reference the original message, lead
with the soul's name (`**Avi** · …`), and parse no mentions.
`POST /api/v1/agent_messages/:id/release {worker, reason}` gives a message back;
the attempt it used still counts.

**Auth.** The board's own (`Api::V1::BaseController`): an agent session or the
shared token, never a new secret. A session acts only for its own soul (an admin
session for any). A client session or a harness key reaches none of it.

**The heartbeat.** `bin/heartbeat <soul> --channel discord [--once] [--worker ID]
[--dry-run]` claims a message and runs the soul's one read-only action (avi:
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

## Alex's setup (once)

Nothing reads Discord until these are done. The code ships inert.

1. In the Discord developer portal, create an application named
   `McRitchie Agents` and add a **Bot** to it.
2. On the Bot page, turn on the **Message Content Intent** (privileged). Without
   it, the bot reads every message with empty content.
3. Under OAuth2 → URL Generator, pick scope `bot` and the permissions **View
   Channels**, **Read Message History**, **Send Messages** and **Send Messages in
   Threads**. Open the URL and invite the bot to the McRitchie server.
4. In the server, create a channel such as `#agent-desk` and two **mentionable**
   roles, `@Avi` and `@Xan`. Assign nobody; they exist to be mentioned. If the
   channel is private, add the bot to it.
5. Reset the bot token and file it in 1Password as `discord.agents.bot`
   (vault `studio-agents`), field `bot-token`
   ([`credential-inventory.md`](../modules/credential-inventory.md)).
6. With Developer Mode on (User Settings → Advanced), copy and send us the
   **server (guild) id**, the **channel id**, the **@Avi and @Xan role ids**, and
   the **bot's user id**.

We then fill `config/agent_routes.yml` with those ids (a small PR) and set
`DISCORD_AGENT_BOT_TOKEN` on Heroku from the 1Password item. The poll starts on
the next minute.

## Test protocol

Post in `#agent-desk`, then run the heartbeat from the hub checkout.

| Scenario | Do | Expect |
|----------|----|--------|
| Serial | Post `@Avi is the release green?`. Run `bin/heartbeat avi --channel discord`, then run it again | The first run answers in the channel; the second prints `nothing for avi` |
| Parallel | Post `@Avi one` and `@Avi two` as separate messages. Start two `bin/heartbeat avi --channel discord --once` at the same moment | Each message is answered once. Neither is read twice and no reply is doubled |
| Two agents | Post `@Avi release?` and `@Xan what is building?`. Run `bin/heartbeat xan --channel discord` | Xan answers only its own message; Avi's stays `received` until `bin/heartbeat avi` |
| Unrouted | Post a message that mentions nobody | It is listed `unrouted` on the admin page; no heartbeat takes it |

The automated tests encode the same scenarios with real database concurrency:
`test/integration/agent_message_claim_race_test.rb`,
`test/integration/heartbeat_mailbox_test.rb`, `test/models/agent_message_test.rb`.

## Observing

- `/admin/agent_messages` lists every message with its soul, status, claim
  holder, lease, attempts and age, filtered by soul, status and channel. A
  message's page shows the untrusted text, the answer, the action, the link to
  the Discord reply, and the timeline: received, routed or unrouted, claimed,
  lease_expired, released, dead_lettered, completed, and reply_posted,
  reply_skipped or reply_failed.
- `bin/agent-inbox list [--soul S] [--status S]`, `bin/agent-inbox show <id>`,
  and `bin/agent-inbox tail [--soul S]` read the same rows through the API.
- A Discord read error is kept on the channel's cursor
  (`agent_message_cursors.last_error`) and logged with the `[agent-messages]`
  prefix.

## Limits of phase 1

- Discord only, polled once a minute, so an answer takes up to a minute plus the
  Claude run.
- One read-only action per soul; nothing writes on a message's behalf.
- No lease renewal. A run longer than 10 minutes loses its claim, and its late
  complete is refused (409) when another worker has taken the message.
- Routing ids live in `config/agent_routes.yml`, so changing them takes a deploy.

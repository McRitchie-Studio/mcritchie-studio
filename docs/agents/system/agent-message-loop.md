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
Discord guild ──Gateway push (MESSAGE_CREATE)──┐
  (every channel,                               ├─ addressed only ─▶ agent_messages (received)
   thread, forum post) ──backstop poll, 10 min──┘   (the rest is dropped unstored)
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
| Inbound, push | `AgentMessages::DiscordGateway` (a thread in the Solid Queue scheduler process on the worker dyno, `config/initializers/agent_message_gateway.rb`), protocol state in `AgentMessages::GatewaySession`, leader lock `AgentMessages::GatewayLeaderLock` → `AgentMessages::DiscordIngest` |
| Inbound, backstop | `AgentMessageDiscordPollJob` (Solid Queue, `config/recurring.yml`, every 10 minutes) → `AgentMessages::DiscordPoll` → `AgentMessages::DiscordIngest` |
| Outbound | `AgentMessageReplyJob` → `AgentMessages::DiscordBot#post_reply` |
| Worker API | `Api::V1::AgentMessagesController` (`/api/v1/agent_messages`) |
| Worker | `bin/dispatcher` (`bin/lib/agent_dispatcher.rb`), under launchd on Alex's Mac; `bin/heartbeat` by hand. Both answer through `AgentMailbox::Responder` (`bin/lib/agent_mailbox.rb`) |
| Dispatcher health | `POST /api/v1/agent_dispatchers/ping` → `agent_dispatchers`; `AgentDispatcherAlertJob` → `agent_mailbox_incidents` |
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
1 to 60 seconds. Each MESSAGE_CREATE goes through `DiscordIngest`, the same path
the poll uses, so the unique index dedupes the two.

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
  could not store, and the thread dying each also write an `ErrorLog` row.
- **Switches.** Without `DISCORD_AGENT_BOT_TOKEN`, with `DISCORD_GATEWAY=off`, or
  with no guild listed, it stays inert and logs one `discord gateway idle:` line.
  It never logs the token or an IDENTIFY/RESUME payload.

**Inbound, backstop.** Every 10 minutes the poll lists each guild's channels
(`GET /guilds/{id}/channels`, keeping text and announcement channels) and active
threads (`GET /guilds/{id}/threads/active`), drops the muted ones, and reads each
with `GET /channels/{id}/messages?after=<cursor>`. The cursor advances in the same
transaction as the rows it covers, past dropped chatter too, and the unique index
makes a re-read page harmless. A channel's first read stores only messages from
the last hour, so old history stays out of the queue. A rate limit stops the pass;
the next run resumes. A channel the bot cannot read keeps its error on its cursor.
Messages written by any bot are not ingested, so the agents' own replies never
return as inbound.

**Routing: only addressed messages are stored.** In order: a mention of a soul's
bot USER, a mention of a soul's ROLE, a reply to a message the mailbox already
holds or to an agent's reply (it joins that thread and soul), the channel
override's `default_soul`. A message that meets none of these is dropped without
being stored: across a whole guild, keeping it would hoard everyone's chatter. A
reply to a held message that itself had no soul is kept `unrouted`, visible and
never handed to a worker. Among several mentioned souls, the one written first
wins. One shared bot with `@Avi`/`@Xan` roles and one bot user per soul both
work; the config lists either.

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
the board every minute. Every board call is made from its main loop. Claude runs
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
the runs in flight finish, and exits for launchd to start the new code. It posts nothing to
Discord itself. Every child gets an allow-listed environment
(`AgentMailbox::CHILD_ENV_ALLOW`), so no API key, token, base URL or provider
switch reaches Claude and it bills Alex's claude.ai subscription. Install, alerts and the unblock
playbook: [`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md).

**The floor alert.** `AgentDispatcherAlertJob` runs every minute on the hub and
posts to `discord.ops_channel_id` (`lobster-tank` today), pinging nobody, ONCE per
incident when no dispatcher has pinged for 5 minutes (never before the first
ping) or a routed message has waited `received` for 10, and once more when it
clears. Without the bot token it logs a line and posts nothing.

**Reports.** The same bot also posts scheduled reports (the CTO daily
application report first) into a channel Alex picks per report at
`/admin/report_destinations`, from a directory of the guild's channels synced
every 15 minutes. The contract other sessions build against,
`ReportDestinations.deliver`, is [`report-destinations.md`](report-destinations.md).

**The heartbeat.** `bin/heartbeat <soul> --channel discord [--once] [--worker ID]
[--dry-run]` is the manual form: it claims a message and runs the soul's one read-only action (avi:
`bin/release status`; xan: `bin/task list`). It then reads the message's context
bundle and builds the prompt from the four layers (below, "Memory"), the action
output and the message. Claude runs headless with
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

## Memory: the four context layers

An answer remembers the person it answers. The memory is rebuilt from the hub's
rows on every answer, never from a resumed Claude session, so any dispatcher on
any machine builds the same context for the same rows (Alex's decision of
2026-10-14, option A). Two pieces build it:

- **The board chooses what.** `GET /api/v1/agent_messages/:id/context?worker=W`
  answers only the worker holding the claim (409 `NOT_HOLDER` otherwise, since
  the bundle carries other messages' text). `AgentMessages::ThreadLedger` builds it.
- **The worker lays it out.** `AgentMailbox::ContextBuilder`
  (`bin/lib/agent_context_builder.rb`) renders four labeled layers, each held to a
  character budget in `ContextBuilder::BUDGETS` (the one place they live).

| Layer | What | Source | Budget |
|-------|------|--------|--------|
| GENERAL | Who the soul is | `docs/agents/agents/<soul>/role.md` | 6,000 |
| DOMAIN | The business it answers for | `config/agent_domains.yml` maps soul → domain → doc (`docs/agents/domains/`); no mapping or a missing doc is an empty layer | 4,000 |
| USER | Notes about the sender | `agent_user_notes`, keyed by `(channel, author_ref)`, with a display name. Read only for now; writing notes is the `agent-respond-sop` task | 2,000 |
| THREAD | The ledger | `agent_messages`: the pin, the summary, the recent turns | 12,000 (pin 3,000, summary 3,000) |

**The ledger** is one person's exchanges with one soul in one Discord channel:
every earlier row with the same `(soul_slug, channel, channel_ref, author_ref)`,
oldest first, read through `index_agent_messages_on_ledger` and capped at 200
rows. A different person's messages in the same channel are never in it.
Claims serialize per ledger as well as per thread (`AgentMessage.claimable`):
a person's second message waits until their first is answered, even when the two
are not a reply chain. The second answer's context therefore always carries the
first exchange. Another person's message, or the same person's message to another
soul or in another channel, is not held back. A row with no `author_ref` has no
ledger.

**The pin.** A message that is an explicit reply joins the thread of the message
it answers (its `thread_key` names an earlier root). The latest earlier row of
that thread is pinned: always included, marked `PINNED … the one being answered`,
and taken out of the turn list. It is included even when another person wrote
it, because the reply chose it. `DiscordIngest` does not yet store the replied-to
message id, so a reply to an OLDER message in a long thread pins the thread's
latest row; storing the reference id is a follow-up.

**Pruning.** The last 10 turns that are no older than 7 days come back
verbatim. The 7 days are counted back from the message's own sent time, not from
the clock, so a rebuild next month is identical. Every older turn folds into
the **summary**: one extractive line per turn (its date, the first line of the
message, and the first line of the answer, each cut to 140 characters), keeping
the newest 40. The builder then fits the layer to its budget, dropping the oldest
turns first. A dropped turn is counted into the summary's header and its line
is not added. The summary's own oldest lines go next.

**Why extractive.** It is a pure function of the rows: deterministic, free (no
model call), and it stores no model-written text. A model-written summary saved
on a row would carry anything a message had injected into it forward into every
later answer to that person.

**Trust.** Labels, rules and budgets are code. Every byte a person wrote sits
inside the prompt's random `<untrusted-…>` fence: the message, their earlier
messages, the soul's earlier answers to them, the notes, and every name they
chose. A planted copy of the fence marker is defused before it is fenced.

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
and `run_meta` with complete. They are stored on the row
(`AgentMessage.run_record` caps each). `/admin/agent_messages/:id` and
`bin/agent-inbox show <id>` show them with a ready line to reopen the session on
the machine that ran it:

```bash
cd ~/.agents/mailbox/xan && claude --resume <session_id>
```

Resuming is for an operator reading a run. The answer path never resumes.

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
- **Our own live test** (2026-10-14) uses Xan's own bot, not roles: the whole
  McRitchie Studio guild (`1332466565203103744`, no channel entries), and the soul
  `xan` routed by a mention of the Xan bot user (`users`, not `roles`). The ids
  are in `config/agent_routes.yml`. `DISCORD_AGENT_BOT_TOKEN` is set from
  `agents.discord.xan` on `mcritchie-studio` only
  ([`credential-inventory.md`](../modules/credential-inventory.md)).

## Test protocol

Post in any channel or thread of the McRitchie Studio guild (`lobster-tank` is the
quiet one), mentioning the Xan bot user (`@Xan`). The gateway stores it within a
second or two; with the dispatcher installed the answer follows and nothing else is needed;
the rows below run the heartbeat by hand, with the dispatcher stopped
(`bin/dispatcher uninstall`) so the two do not compete. Only `xan` is routed
there today.

| Scenario | Do | Expect |
|----------|----|--------|
| Serial | Post `@Xan what is building?`. Run `bin/heartbeat xan --channel discord`, then run it again | The first run answers in the channel; the second prints `nothing for xan` |
| Parallel | Post `@Xan one` and `@Xan two` as separate messages. Start two `bin/heartbeat xan --channel discord --once` at the same moment | Each message is answered once. Neither is read twice and no reply is doubled |
| Two agents | Needs a second soul routed in the guild (a role, or a second bot user such as Mack's). Then post to each and run `bin/heartbeat xan --channel discord` | Xan answers only its own message; the other stays `received` until that soul's heartbeat runs |
| Unaddressed | Post a message that mentions nobody and replies to nothing | No row is stored; the admin page does not list it |

The inbound half (guild scope, the addressed-only filter, overrides, the backstop)
is `test/services/agent_messages/discord_poll_test.rb` and `router_test.rb`; the
gateway protocol and leader lock are `gateway_session_test.rb` and
`gateway_leader_lock_test.rb`; the listener runs end to end over a real websocket
against a fake gateway in `test/integration/discord_gateway_test.rb`. The claim
side is encoded with real database concurrency:
`test/integration/agent_message_claim_race_test.rb`,
`test/integration/heartbeat_mailbox_test.rb`, `test/models/agent_message_test.rb`.
The dispatcher's loop (claims, the cap, renewal, the usage-limit refund and
pause, a graceful stop) is `test/integration/agent_dispatcher_loop_test.rb`; the
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

- Discord only. The gateway stores a message within seconds; while it is down
  (a deploy, a reconnect, a stood-down leader) the backstop catches up within 10
  minutes, so an answer takes the Claude run plus, at worst, that.
- One gateway connection, unsharded. That holds below 2,500 guilds; past it
  Discord requires sharding (close 4011, which stops the listener).
- The backstop reads text and announcement channels and active threads. It
  skips archived threads and voice-channel text chat, which only the gateway
  sees.
- One read-only action per soul; nothing writes on a message's behalf.
- One dispatcher, on one Mac. It answers only while that Mac is awake and signed
  in to Claude; the floor alert says when it is not. A dispatcher that dies
  mid-answer stops renewing, so its claim lapses after 10 minutes and its late
  complete is refused (409) when another worker has taken the message.
- Routing ids (guilds, souls, overrides) live in `config/agent_routes.yml`, so changing them takes a deploy,
  and the dispatcher reads its soul list from the checkout it runs from.

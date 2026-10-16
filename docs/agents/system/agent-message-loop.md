# Agent message loop (the agent mailbox, phase 1)

**What it is.** A message to an agent on Discord reaches the hub, is routed to a
soul, waits in a queue, and is answered in the same channel by `bin/dispatcher`,
the always-on worker on Alex's Mac (`bin/heartbeat` is the manual form of the
same answer path). Phase 1 is Discord only. Two domain front doors are routed,
Avi (`avi`, McRitchie Studio's CTO, Alex 2026-10-15) and Turf (`turf_monster`,
Turf Monster), and each may PROPOSE what its domain's catalog allows, for the
owner to confirm by reply (below, "Proposals and confirm"). Xan stays routed as a
helper (orchestration, docs review) with no catalog. Avi and Xan keep one
read-only action each, the same board read (`bin/task list`). Later phases add channels, agents and clients without
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
| Outbound | `AgentMessageReplyJob` → `AgentMessages::DiscordBot#post_reply`, as the soul's own bot (`DISCORD_BOT_TOKEN_<SOUL>`) or the shared bot (below, "Which bot replies") |
| Typing | `bin/dispatcher` → `POST /api/v1/agent_messages/:id/typing` → `AgentMessageTypingJob` → `AgentMessages::DiscordBot#trigger_typing`, as the bot that will reply (below, "Typing") |
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
wins. One shared bot with `@Avi`/`@Xan` roles and one bot user per soul both
work; the config lists either.

**Held: the agents answer only the owner.** `config/agent_answerers.yml` lists
the ROLES the agents answer (below, "Audience"); today it is `owner` alone, so
Alex is answered because his `agent_people` row is the owner, and so is every
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
capped, and the shipped allowances are blank, so nothing is capped until Alex
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
`DISCORD_BOT_TOKEN_TYRION`), the reply posts as that soul's own bot, with no
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
the runs in flight finish, and exits for launchd to start the new code. It keeps
the minute ping going (state `stopping`) while it drains, since a restart drain
can run up to about 8 minutes, past the floor alert's 5. It posts nothing to
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
[--dry-run]` is the manual form: it claims a message and reads its context
bundle, which carries the sender's audience (below, "Audience"). For an owner or
team sender it runs the soul's one read-only action (avi and xan: `bin/task list`,
the board through the agent API; no action reads Heroku, which launchd cannot log
in to); for anyone else it runs nothing. It builds the prompt from
the five layers (below, "Memory"), the audience's rules, the action output and the
message. Claude runs headless with
**no tools** (`claude -p --safe-mode --tools ""`), and the heartbeat completes
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

## Memory: the five context layers

An answer remembers the person it answers, on every channel they use. The
memory is rebuilt from the hub's rows on every answer, never from a resumed
Claude session, so any dispatcher on any machine builds the same context for the
same rows (Alex's decision of 2026-10-14, option A). On 2026-10-15 Alex dropped
the per-channel silo: "Let's give continuity for our people over omnichannel."
The channel still matters in one way. The thread a message continues is the focus
of its answer. Two pieces build the memory:

- **The board chooses what.** `GET /api/v1/agent_messages/:id/context?worker=W`
  answers only the worker holding the claim (409 `NOT_HOLDER` otherwise, since
  the bundle carries other messages' text). `AgentMessages::MemoryBundle` builds it.
- **The worker lays it out.** `AgentMailbox::ContextBuilder`
  (`bin/lib/agent_context_builder.rb`) renders five labeled layers, each held to a
  character budget in `ContextBuilder::BUDGETS` (the one place they live).

| Layer | What | Source | Budget |
|-------|------|--------|--------|
| GENERAL | Who the soul is, who it is speaking with, and that audience's rules | `docs/agents/agents/<soul>/role.md` for owner and team (`public.md`, else one line, for anyone else); the rules from the `agent-communication` SOP | 6,000 (rules 3,000) |
| DOMAIN | The business it answers for | `config/agent_domains.yml` maps soul → domain → doc (`docs/agents/domains/`); no mapping, a missing doc, or an `internal: true` domain for a client or the public is an empty layer | 4,000 |
| USER | The notes about the sender, from every channel, each with its date and source: every soul's for an owner or team sender, the answering soul's domain's only for a client or the public ("Whose memory") | `agent_person_notes` for the message's person (`AgentPersonNote.visible_for`) | 2,000 |
| PERSON | The sender's earlier exchanges with this soul on every channel, each labeled with its place | `agent_messages` by `(soul_slug, person_id)`: the summary, then the recent turns | 9,000 (summary 3,000) |
| THREAD | The conversation being answered | `agent_messages` by `thread_key`, this channel and guild only | 6,000 |

**The person.** A person is one identity across platforms. `agent_people` holds
the display name and, optionally, the hub `User`. `agent_person_identities` holds
each place the person speaks, as `(platform, external_id)`: a Discord user id
today, an email address later. The pair is unique, so one id is always one person.
Every stored message with an author is stamped with its `person_id` when it is
created (`AgentMessage` calls `AgentPerson.resolve!`), and the first message from an
unknown id makes a new person. The migration backfilled every existing row from
`(channel, author_ref)` and seeded Alex's Discord id (`536552944271753216`) as
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
parent the reader gives it, or from the channel directory. An email thread will
key the same way. The layer comes only from this channel and guild: a Discord
forward, or any reference into another channel, brings nothing from there.
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

**Whose memory.** Notes are per person and scoped by app DOMAIN (Alex,
2026-10-15). Each note records the domain of the soul that filed it, read from
the `souls:` map in `config/agent_domains.yml` (an empty domain for a soul the
map does not name). Who reads a note turns on the sender's role when the answer
is built, not when the note was filed (`AgentPersonNote.visible_for`):

- **Owner and team.** Every soul reads every domain's notes: a fact about Alex,
  such as his favorite color, is true whichever agent hears it, so a note Turf
  files is in Avi's USER layer too. A fact filed in two domains is shown once.
- **Client and public.** A soul reads only the notes filed in its own domain.
  What a Turf client told Turf stays with Turf's souls; Avi, Xan and the other
  `mcritchie_studio` souls never see it, and Turf never sees what that person told
  Xan.

The conversation history (the PERSON layer) is per person per soul either way:
Avi does not see what Alex told Xan.

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
  the message being completed, and under nobody else. A fact about Alex returned
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
  with, every message, in caps) were refused until 2026-10-15. Alex dropped that
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
(Alex's decision of 2026-10-15). The rules are a shared SOP,
[`../modules/agent-communication.md`](../modules/agent-communication.md); its front
matter is the machine-read block, and the prompt prints its words exactly.

**Roles.** Every `agent_people` row has a `role`: `owner`, `team`, `client` or
`public` (the default, held to those four by a check constraint), and a
`client_domain` for a client (a key of `config/agent_domains.yml`; any other role
has none). Alex's Discord person is seeded `owner` by the migration and
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

The plan is `.agents/epics/domain-agents.md` (Alex approved it 2026-10-15). Every
domain has one FRONT-DOOR agent. It has no tools: it understands the request and
PROPOSES one thing from its domain's catalog. Code checks the proposal, the owner
confirms it in the thread, and code carries it out.

**The registry** is `config/agent_domains.yml`, read by
`AgentMailbox::DomainRegistry` (`bin/lib/agent_domain_registry.rb`, plain Ruby, so the
board and the worker read one file the same way). Each domain names its `soul`
(the front door), `reply_name`, `repos`, `app`, and `capabilities`:

| Kind | Phase 1 | What runs on `go` |
|------|---------|-------------------|
| `ask` | Avi: `board_status` (stage counts), `recently_shipped` (`days` 1-30), `release_status` (the active release, its stage and member count, the submitted/reviewed/assembled counts, the last ship; read in process, no Heroku). Turf: `signups_and_errors` (`days` 1-7) | A named method in `AgentProposals::Queries`: code with bounded params, never model-written SQL. Turf's reads Turf Monster's engine health endpoint once per daily window (`DailyAppReport.health_for`, the daily app report's own path), never its database |
| `operate` | empty | Phase 2 (a confirmed SOP, headless in a desk) |
| `change` | both domains (`repo`, `default_shape`) | A `designed` board task (title, kind, shape, accept, test, risk) with the Discord link in `devops.source_thread`. A session still starts the builder |

Only the front door has a catalog. Xan (and every other studio soul) maps to the
studio domain for its DOMAIN layer and proposes nothing. An `internal: true` domain (Commercial Welding) has no
catalog and no prompt names it. Turf Monster has no aggregate entries endpoint the
hub can read, so there is no entries-for-week ask yet.

**Who may ask, who may confirm.** Requesting needs both a row in
`AgentMailbox::Audience::CAPABILITIES` (`propose_ask`, `propose_change`,
`propose_operate`) and the capability's `min_audience` on `Audience::RANK`
(public < client < team < owner). A client may request only in the domain it is a
client of. Confirming is `confirm_proposal`, the owner's alone, read from the
person's role (`agent_people.role`), never from a Discord id or the message text.

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

**Confirm by reply.** In `DiscordIngest`, before routing and before any model, a
message whose text is exactly `go`, `no` or `change: …` (trimmed, any case,
leading @-mentions ignored) is handled by `AgentMessages::ProposalConfirm` when
it is about a proposal (`AgentProposal.for_word`), within its thread (same
`thread_key`, channel, guild and channel ref as the THREAD layer). A Discord
reply to the message that posted a proposal is about THAT proposal, whatever its
status, open or not; any other word is about the thread's newest pending one,
and with none pending it is about nothing. A go in another thread, or a
top-level go outside a Discord thread (which starts a thread of its own), finds
no proposal and is routed as usual.

| Word | From the owner | From anyone else |
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

**Replies come from the front door's own bot** once its token is set
(`DISCORD_BOT_TOKEN_AVI`, `DISCORD_BOT_TOKEN_TURF_MONSTER`; above, "Which bot
replies"); until then they post through Xan's shared bot, signed by the domain's
`reply_name` (`**Turf** · …`). Avi is routed by a mention of his own
Discord app's bot user (`1560516264378507334`, 1Password `agents.discord.avi`,
in the McRitchie guild, reply-only permissions); Turf by a mention of the
existing "Turf Monster" Discord app's bot user (`1405042649479647293`, in the
McRitchie guild). Tyrion is not routed: he answers through OpenClaw with his own
bot, and Alex has not chosen between the two runtimes.

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
cd ~/.agents/mailbox/xan && claude --resume <session_id>
```

Resuming is for an operator reading a run. The answer path never resumes.

## Typing: the bot shows it is answering

Step 1 of real-time Discord agents (Alex, 2026-10-16; the plan is
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
  a Discord message, its sender is answered (`AgentMessages::Answerers`, or a hold
  an admin released), and the claim is under `AgentMessage::TYPING_CAP` old. A
  held or unrouted message is never claimed, so it never types. Anyone but the
  holder gets 409 `NOT_HOLDER`; a quiet "no" is a 200 whose `meta.typing` says
  `not_discord`, `not_answered` or `capped`, and the dispatcher stops pulsing
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

### Warm sessions (next step, not built)

Phase 7 step 2 shipped the usage half (run summaries, tiers, the allowance and
the meter; [`agent-usage.md`](agent-usage.md)). The warm session per domain is
designed here and not built. It changes the dispatcher's loop, adds a board
table, a checkpoint store and a standby role, and it reverses the memory rule
above ("never from a resumed Claude session"). That is its own reviewable PR,
not a rider on the meter. Until it ships, every answer stays one
`claude -p` run per message.

**Scope.** Owner and team traffic only. A client's or the public's message stays
one run per message, so untrusted text never persists in a session. A held
message an admin released is answered per message too, whoever sent it. Later:
one session per (domain, user).

**The switch.** `warm_session: true` on a domain in `config/agent_domains.yml`;
absent or false (the default) is today's path. The flag lives in config so that
turning it on is a reviewed deploy, not a click.

**The lease.** A new table, `agent_domain_sessions` (not `agent_sessions`: that
name belongs to the builder sessions, `app/models/agent_session.rb`), one row per
domain: `domain`, `holder` (the worker id), `lease_expires_at`, `heartbeat_at`,
`claude_session_id`, `generation`, `turns`, `context_tokens`, `checkpoint`
(an Active Storage attachment, the hub's blob convention) and `checkpointed_at`.
The lease lives on the row, as `AgentMessage`'s and `lib/claim_lease.rb`'s do: a
holder that dies loses it when the lease lapses, with no sweeper. The dispatcher
renews it on its minute ping. Lease 5 minutes; a turn in flight renews it like a
message lease.

**A turn.**

1. The dispatcher claims an owner or team message in a warm domain, exactly as
   today (same guard, same thread and person order).
2. It takes or renews the domain lease (`POST /api/v1/agent_domain_sessions/:domain/acquire`).
   Another live holder answers 409: the message is answered per message instead,
   never queued behind the lease.
3. When its local transcript (`~/.claude/projects/<cwd slug>/<id>.jsonl`) is
   missing or older than the board's `checkpointed_at`, it downloads the
   checkpoint first.
4. It runs `claude -p --resume <claude_session_id> --safe-mode --tools ""
   --output-format json`, still with no tools and the allow-listed environment.
5. **Every turn carries the board's rules again.** The bundle is built and read
   per message as today. The turn prompt holds GENERAL (the audience and its
   rules), the THREAD focus and the fenced message. USER and PERSON are left out,
   because the session already holds them. The audience is still resolved on the
   board from the person's role, so a resumed session cannot skip the
   audience or owner checks: those are server-side (`claimable`, the bundle's
   `audience`, `AgentProposal.record_from!`), not remembered.
6. It completes the message (the run summary as today), then uploads the
   transcript (`POST …/checkpoint { worker, session_id, turns, context_tokens }`).
   The envelope's `session_id` becomes the new head each turn, whether or not the
   CLI kept the id.
7. A failed run, a failed checkpoint, or a transcript that will not restore
   drops the lease, and that message is answered per message. The fallback is
   always today's path.

**The standby.** A second dispatcher (Alex's work machine) is registered on the
board as `standby` for a list of domains (`agent_dispatchers.role`, set at
`/admin/agent_messages`). It claims nothing while a primary pings. When a
domain's lease lapses (no heartbeat for 5 minutes), the standby acquires it,
restores the checkpoint and answers. **Handback is only between turns.** A
primary that comes back asks for the lease. The board marks it `handback_requested`,
the standby releases it after its current turn completes and checkpoints, and the
primary resumes from that checkpoint. Neither side ever resumes a session the
other is mid-turn in.

**Consolidation.** When a turn's `context_tokens` (input + cache read + cache
write) pass a threshold (`CONSOLIDATE_AT`, 150,000 to start), the holder runs one
more no-tools turn asking for a domain summary. The board stores it as an
`agent_domain_summaries` row (domain, generation, text, source session, turns
covered), and the next turn starts a fresh session seeded with that summary
inside the fence, labelled as the soul's own notes. Only owner and team text ever
reaches a warm session, so the summary carries no untrusted client text forward.
That is why this stays off for client and public traffic.

**Usage.** Each turn's run summary is stored as today. A warm turn is mostly
cache reads, which the meter shows as such. Owner and team turns are never
metered against an allowance.

**What the build owes.** A migration (the two tables and the dispatcher role)
and the board endpoints (acquire, renew, checkpoint, release, handback), with
holder checks. The dispatcher's warm path behind the flag, plus its restore,
checkpoint and fallback. The standby role and the floor alert's view of it.
Tests: lease races (two acquirers, a lapsed holder's late checkpoint refused),
a turn that resumes, a restore from checkpoint on a second machine, a handback
only between turns, a client message never warm, and consolidation at the
threshold. The setup steps for the standby machine are in
[`agent-dispatcher`](../agents/steffon/sops/agent-dispatcher.md), "Standby on a
second machine".

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
(`bin/dispatcher uninstall`) so the two do not compete. Avi, Xan and Turf are
routed there; the rows use Xan, and any routed soul works the same way.

| Scenario | Do | Expect |
|----------|----|--------|
| Serial | Post `@Xan what is building?`. Run `bin/heartbeat xan --channel discord`, then run it again | The first run answers in the channel; the second prints `nothing for xan` |
| Parallel | Post `@Xan one` and `@Xan two` as separate messages. Start two `bin/heartbeat xan --channel discord --once` at the same moment | Each message is answered once. Neither is read twice and no reply is doubled |
| Two agents | Needs a second soul routed in the guild (a role, or a second bot user such as Mack's). Then post to each and run `bin/heartbeat xan --channel discord` | Xan answers only its own message; the other stays `received` until that soul's heartbeat runs |
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
guard and the unanswered audiences).

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

- Discord only. The gateway stores a message within seconds; while it is down
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
- One dispatcher, on one Mac. It answers only while that Mac is awake and signed
  in to Claude; the floor alert says when it is not. A dispatcher that dies
  mid-answer stops renewing, so its claim lapses after 10 minutes and its late
  complete is refused (409) when another worker has taken the message.
- Routing ids (guilds, souls, overrides) live in `config/agent_routes.yml`, so changing them takes a deploy,
  and the dispatcher reads its soul list from the checkout it runs from.

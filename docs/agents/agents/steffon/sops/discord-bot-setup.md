# Discord Bot Setup
<!-- registry: the agents' Discord bot, once, then each client's invite -->

## Status: Active

This is Steffon's `discord-bot-setup` SOP: the operator-only half of putting
agents in a Discord server. Part 1 creates a bot, once per bot. Part 2 runs for
each client who requests it from `/integrations/discord`, whose public guide
covers the client's own half (server, `#agents` channel, mentionable roles,
Developer Mode, the IDs). Nothing in this SOP belongs on that page: the bot's
name, the portal, the intent and the token stay internal.

How the bot reads and answers once it is set up:
[`agent-message-loop.md`](../../../system/agent-message-loop.md).

**Where it stands (2026-10-16).** Each bot is its own Discord application, filed
as `agents.discord.<bot>` in the `studio-agents` vault
([`credential-inventory.md`](../../../modules/credential-inventory.md)):

| Item | Bot user | Role |
|------|----------|------|
| `agents.discord.xan` | `1481150857809760399` | The SHARED bot, `DISCORD_AGENT_BOT_TOKEN`: the one reader of every listed guild (gateway and backstop poll), and the writer of every reply a soul's own bot does not post. A mention routes to `xan` |
| `agents.discord.avi` | `1560516264378507334` | Avi, McRitchie Studio's front door: a mention routes to `avi`; replies as this bot once `DISCORD_BOT_TOKEN_AVI` is set |
| `agents.discord.turf` | `1405042649479647293` | Turf, Turf Monster's front door: a mention routes to `turf_monster`; replies as this bot once `DISCORD_BOT_TOKEN_TURF_MONSTER` is set |
| `agents.discord.tyrion` | none filed | Token field empty on purpose (his bot answers through OpenClaw); not routed. With no `DISCORD_BOT_TOKEN_TYRION` his replies, once routed, fall back to the shared bot |
| `agents.discord.mack` | `1479979322461913222` | Read by nothing yet |

Reading stays on the one shared token, so one connection reads each guild.
Only replies switch: a soul with `DISCORD_BOT_TOKEN_<SOUL>` set (its slug,
upcased) answers as its own bot, unsigned; without it, the shared bot answers,
signed `**Soul** ·`. Run Part 1 only for a new bot, and Part 1b to give a soul
its own replies.

**Routing is per guild, never per channel.** Once a guild is listed, every
channel, thread and forum post the bot can see in it is read; there is no
per-channel routing step. A channel entry is only an override (`default_soul`,
or `ignore: true` to mute one).

## Part 1 — Create a bot (once per bot)

The developer portal is Alex's account, so the portal clicks are his. The
1Password item is not: Steffon makes it first, and Alex pastes only the token
([`credential-filing`](./credential-filing.md) section 5).

**Steffon, first:** create the item `agents.discord.<bot>` in `studio-agents`
with the `bot-token` field present and **empty**, the `application-id` and
`bot-user-id` fields ready, the Discord logo URL and the permission-matrix note
(`credential-filing` sections 2 to 4). Then hand Alex his turn:

```not-pasteable
🙋 YOUR TURN — create the <bot> bot (<bot> = the soul it speaks as, e.g. avi)
   Where:  https://discord.com/developers/applications — New Application
   1. Name it for the soul, e.g. Avi. Open Bot in the sidebar.
   2. Under Privileged Gateway Intents, turn on Message Content Intent and save.
      Without it the gateway refuses the connection (close 4014) and the
      backstop poll reads every message with empty content.
   3. Reset Token, copy it once, and paste it into the bot-token field of the
      1Password item agents.discord.<bot> (vault studio-agents) that I made.
      Save. Paste it nowhere else, this chat included.
   4. Send me the Application ID (General Information) and the bot's user ID
      (Developer Mode on, right-click the bot in any server, Copy User ID).
      Neither is a secret.
   Done when: the token is saved in the item. Then tell me "done".
```

Then Steffon:

1. Fill `application-id` and `bot-user-id` on the item, then **verify the token
   with Discord** (`credential-filing` section 6): pipe the field straight into
   `GET https://discord.com/api/v10/users/@me` with an `Authorization: Bot …`
   header, and print only the answer's `id`. It must equal the bot user ID Alex
   sent. Add the item's row to
   [`credential-inventory.md`](../../../modules/credential-inventory.md)
   ([`credential-filing`](./credential-filing.md)). If this bot becomes the
   shared bot, read its token back by name (never print it) and set it as Heroku
   config `DISCORD_AGENT_BOT_TOKEN` on `mcritchie-studio` only, never on
   `mcritchie-studio-qa`, whose own listener and poll would store the same guild
   into a second database.
2. For the shared bot, put its user ID in `config/agent_routes.yml` as
   `discord.bot_user_id`, quoted, in a small PR. A bot user can also route a
   soul: list it under that soul's `users`, as the live test does for Xan.
3. Build the invite URL. Scope `bot`, and exactly the four permissions the public
   guide names: View Channels (1024), Send Messages (2048), Read Message History
   (65536) and Send Messages in Threads (274877906944), which sum to
   `274877975552`:

   ```text
   https://discord.com/oauth2/authorize?client_id=<Application ID>&scope=bot&permissions=274877975552
   ```

   This URL is not a secret, but it goes to clients by reply, never on the public
   page, until the page's "Add to Discord" slot is built.

## Part 1b — Give a soul its own replies

A soul routed by its own bot user still replies through the shared bot, signed,
until its token is set. To switch its replies (Steffon; Heroku config is his
lane, and nobody else sets it):

1. **Invite the soul's bot to every guild it answers in**, with the four
   Part 1 permissions at least (View Channels, Send Messages, Read Message
   History, Send Messages in Threads). A bot missing from a guild, or missing a
   permission in a channel, is refused there.
2. **Set its config var on `mcritchie-studio` only**, read from the item by name
   and never printed. The name is `DISCORD_BOT_TOKEN_` plus the soul's slug,
   upcased, non-alphanumerics as `_`:

   | Soul | Config var | Item |
   |------|------------|------|
   | `avi` | `DISCORD_BOT_TOKEN_AVI` | `agents.discord.avi` |
   | `turf_monster` | `DISCORD_BOT_TOKEN_TURF_MONSTER` | `agents.discord.turf` |
   | `tyrion` | `DISCORD_BOT_TOKEN_TYRION` | `agents.discord.tyrion` (empty: leave unset) |

   ```bash
   T=$(op read 'op://studio-agents/agents.discord.avi/bot-token') && [ -n "$T" ] && \
     heroku config:set "DISCORD_BOT_TOKEN_AVI=$T" --app mcritchie-studio >/dev/null 2>&1; echo "exit $?"; unset T
   ```

   `heroku config:set` echoes what it set, so its output goes nowhere
   ([`credentials.md`](../../../modules/credentials.md)). The empty guard
   matters: a failed or empty `op read` would otherwise set the var blank,
   which reads as unset, and still print `exit 0`. Never set it on
   `mcritchie-studio-qa`.
3. **Test it**: ask the soul something in the guild. The reply comes from the
   soul's own bot, with no `**Soul** ·` prefix, and its `reply_posted` event
   reads `via: soul_bot`. A `reply_bot_refused` event and an `ErrorLog` row
   targeted at the message mean Discord refused the soul's bot (401: a bad
   token; 403: not in the guild, or a missing channel permission); that reply
   went out through the shared bot, signed, and so does every later one until
   the cause is fixed.

To undo it, unset the var: replies fall back to the shared bot at once.

## Part 2 — Connect a client (each request)

Input: a contact submission from `/integrations/discord`
(source `page: integrations/discord, item: discord`).

1. **Send the invite.** Reply with the Part 1 invite URL and point the client at
   the guide's steps. Ask for the server ID and one role ID per agent, if the
   request did not already carry them. A channel ID is not needed: the bot reads
   every channel it can see. Never ask for, and
   never accept, a password or a token; if one arrives, tell the client to rotate
   it.
2. **Confirm the bot is in.** The client authorizes it on Discord's screen. The
   bot reads what its permissions let it see; a private channel stays unread
   until the client adds the bot to that channel's permissions.
3. **Route it.** Add the client's guild under `discord.guilds` in
   `config/agent_routes.yml` with each soul's `roles` ID, all quoted strings (the
   file's header explains why). Add a `channels` entry only for an override the
   client asked for: `default_soul` for a channel whose every message is for one
   agent, `ignore: true` for one to mute. Ship it as its own task.
4. **Test with the client.** Once it deploys, the client posts
   `@<agent> hello` in any channel. The gateway stores it within seconds (the
   backstop poll within 10 minutes if the gateway is down), and
   `bin/dispatcher` answers it within about a minute (Steffon's
   [`agent-dispatcher`](agent-dispatcher.md) SOP installs and watches it; once the
   routing change ships it restarts itself within about two minutes and serves the
   new soul). See
   the reply land, and only then tell the client it is live, and how quickly to
   expect answers.

## If it does not answer

Follow [`agent-message-loop.md`](../../../system/agent-message-loop.md#observing):
only addressed messages are stored, so no row at all means the role ID is missing
from the routes, the guild is not listed (the worker log says `ignoring Discord
guild <id>` once), the channel is muted, the bot cannot see the channel, or the
Message Content Intent is off (the worker log says `closed the connection with
4014`). An `unrouted` row is a reply to a held message that named no soul.

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

**Where it stands (2026-10-14).** Each bot is its own Discord application, filed
as `agents.discord.<bot>` in the `studio-agents` vault. Two exist:
`agents.discord.xan` (Xan's app, bot user `1481150857809760399`) and
`agents.discord.mack` (Mack's, read by nothing yet). The mailbox reads ONE token,
`DISCORD_AGENT_BOT_TOKEN`, so one bot is the shared bot at a time. Today that is
Xan's, for the live test in the McRitchie Studio guild's `lobster-tank` channel,
where a mention of the Xan bot user routes to `xan`. Run Part 1 only for a new bot.

## Part 1 — Create a bot (once per bot) — Alex

Every click here is Alex's: the developer portal is his account.

```not-pasteable
🙋 YOUR TURN — create the <bot> bot (<bot> = the soul it speaks as, e.g. xan)
   Where:  https://discord.com/developers/applications — New Application
   1. Name it for the soul, e.g. Xan. Open Bot in the sidebar.
   2. Under Privileged Gateway Intents, turn on Message Content Intent and save.
      Without it the bot reads every message with empty content.
   3. Reset Token, copy it once, and file it in 1Password: item
      agents.discord.<bot>, vault studio-agents, fields bot-token,
      application-id and bot-user-id.
   4. Copy the Application ID (General Information) and the bot's user ID
      (Developer Mode on, right-click the bot in any server, Copy User ID).
   Done when: the 1Password item reads back and you have sent me both IDs.
   Then tell me "done".
```

Then Steffon:

1. Add the item's row to
   [`credential-inventory.md`](../../../modules/credential-inventory.md)
   ([`credential-filing`](./credential-filing.md)). If this bot becomes the
   shared bot, read its token back by name (never print it) and set it as Heroku
   config `DISCORD_AGENT_BOT_TOKEN` on `mcritchie-studio` only, never on
   `mcritchie-studio-qa`, whose own poll would store the same channel into a
   second database.
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

## Part 2 — Connect a client (each request)

Input: a contact submission from `/integrations/discord`
(source `page: integrations/discord, item: discord`).

1. **Send the invite.** Reply with the Part 1 invite URL and point the client at
   the guide's steps. Ask for the server ID, the `#agents` channel ID and one role
   ID per agent, if the request did not already carry them. Never ask for, and
   never accept, a password or a token; if one arrives, tell the client to rotate
   it.
2. **Confirm the bot is in.** The client authorizes it on Discord's screen. If
   `#agents` is private, the client adds the bot to the channel's permissions.
3. **Route it.** Add the client's guild under `discord.guilds` in
   `config/agent_routes.yml`: the channel, and each soul's `roles` ID, all quoted
   strings (the file's header explains why). Ship it as its own task.
4. **Test with the client.** Once it deploys, the client posts
   `@<agent> hello` in `#agents`. The poll stores it within a minute, and
   `bin/dispatcher` answers it within about another (Steffon's
   [`agent-dispatcher`](agent-dispatcher.md) SOP installs and watches it; once the
   routing change ships it restarts itself within about two minutes and serves the
   new soul). See
   the reply land, and only then tell the client it is live, and how quickly to
   expect answers.

## If it does not answer

Follow [`agent-message-loop.md`](../../../system/agent-message-loop.md#observing):
an `unrouted` row means a role ID or channel is missing from the routes; no row
at all means the bot cannot see the channel or the Message Content Intent is off.

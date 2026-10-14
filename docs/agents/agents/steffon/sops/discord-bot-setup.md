# Discord Bot Setup
<!-- registry: the agents' Discord bot, once, then each client's invite -->

## Status: Active

This is Steffon's `discord-bot-setup` SOP: the operator-only half of putting
agents in a Discord server. Part 1 creates the shared bot once. Part 2 runs for
each client who requests it from `/integrations/discord`, whose public guide
covers the client's own half (server, `#agents` channel, mentionable roles,
Developer Mode, the IDs). Nothing in this SOP belongs on that page: the bot's
name, the portal, the intent and the token stay internal.

How the bot reads and answers once it is set up:
[`agent-message-loop.md`](../../../system/agent-message-loop.md).

## Part 1 — Create the bot (once) — Alex

Every click here is Alex's: the developer portal is his account.

```not-pasteable
🙋 YOUR TURN — create the agents' bot
   Where:  https://discord.com/developers/applications — New Application
   1. Name it: McRitchie Agents. Open Bot in the sidebar.
   2. Under Privileged Gateway Intents, turn on Message Content Intent and save.
      Without it the bot reads every message with empty content.
   3. Reset Token, copy it once, and file it in 1Password:
      item discord.agents.bot, vault studio-agents, field bot-token.
   4. Copy the Application ID (General Information) and the bot's user ID
      (Developer Mode on, right-click the bot in any server, Copy User ID).
   Done when: the 1Password item reads back and you have sent me both IDs.
   Then tell me "done".
```

Then Steffon:

1. Read the token back by name (never print it), and set it as Heroku config
   `DISCORD_AGENT_BOT_TOKEN` from the item
   ([`credential-filing`](./credential-filing.md); the row in
   [`credential-inventory.md`](../../../modules/credential-inventory.md)).
2. Put the bot's user ID in `config/agent_routes.yml` as `discord.bot_user_id`,
   quoted, in a small PR.
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
   `@<agent> hello` in `#agents`; the reply comes within a few minutes (the poll
   runs every minute, then a worker answers). Tell the client it is live.

## If it does not answer

Follow [`agent-message-loop.md`](../../../system/agent-message-loop.md#observing):
an `unrouted` row means a role ID or channel is missing from the routes; no row
at all means the bot cannot see the channel or the Message Content Intent is off.

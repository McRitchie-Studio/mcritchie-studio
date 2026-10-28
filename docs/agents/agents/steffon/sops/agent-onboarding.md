# Agent Onboarding SOP (Steffon)
<!-- registry: open a pending agent's card, verify and install what Alex McRitchie made -->

## Status: Active

Some setup only Alex McRitchie's hands can do: Discord lets an application and its
bot token be made only in its Developer Portal, behind his login and 2FA, and
automating a user account breaks Discord's terms. So each such step is a
**card in the Pending agents column of `/agents`**, one per agent per kind, and
everything around his clicks is Steffon's: the empty 1Password item before, the
check, the install and the close after. Plan and Alex McRitchie's words:
`/Users/alex/projects/.agents/epics/agent-onboarding.md`.

The model is generic (`AgentSetup` with ordered `AgentSetupStep` rows: who did
each and when). Today it has one kit, the **Discord bot** (`discord_bot`); Gmail
delegation, wallets and QuickBooks come later as kits of their own
(`AgentSetups::Kits`).

| Piece | Where |
|-------|-------|
| The column, the cards, Alex McRitchie's buttons | `/agents` (admin only), `AgentsController#index`, `AgentSetupsController`, `app/views/agent_setups/` |
| The Discord kit: steps, invite URL, 1Password deep link, the hub's check | `AgentSetups::DiscordBotKit`, `config/agent_setups.yml` |
| The hub's check after Done | `AgentSetupCheckJob` |
| Steffon's CLI (the Mac) | `bin/agent-setup` (`bin/lib/agent_setup_cli.rb`) |
| Its dyno half, run over `heroku run` | `AgentSetups::Command` |
| Discord's answers mapped to ready or a reason | `lib/agent_setups/discord_verdict.rb` |

## Who holds what

The token never passes through the hub, a chat or an agent's output.

- **The hub dyno** holds no 1Password right and never sees the new bot's token
  until it is installed. After Done it checks only what it can: the Application
  ID is a Discord id, and (through the agents' shared bot) the new bot is a
  member of the server. Then the card reads **Waiting for Steffon to verify**.
- **Steffon, on the Mac**, reads the token from 1Password, asks Discord who it
  is, installs it on Heroku over stdin, and reports. The report re-checks the
  INSTALLED token from a fresh one-off dyno's own environment before the card
  turns **Ready**.
- `bin/agent-setup` reaches the hub only through `heroku run` (the `bin/books`
  transport), so it adds no HTTP endpoint: whoever can run it already holds the
  Heroku lane.

## 1. Open a card

1. **Make the empty 1Password item first**, per
   [`credential-filing`](credential-filing.md) sections 2 to 5, in the admin lane:
   `agents.discord.<soul>` in `studio-agents`, the `bot-token` field present and
   EMPTY, `application-id` and `bot-user-id` fields ready, the Discord URL (for the
   logo) and the permission-matrix note. Discord-specific fields:
   [`discord-bot-setup`](discord-bot-setup.md) Part 1.
2. **Open the card** (it looks the item's ids up itself and reads no value):

   ```bash
   bin/agent-setup open discord --soul mason --by steffon
   ```

   Options: `--op-item` and `--op-vault` when the item is not
   `agents.discord.<soul>` in `studio-agents`; `--bot-name` when the bot is not
   named for the soul; `--permission-set reply|cto|server_admin` to override the
   seat's set. The seat decides by default (`config/agent_setups.yml`): `steffon`
   takes `server_admin` (Manage Channels, Roles and Webhooks on top of `cto`); a
   CTO in `config/cto_reports.yml` takes `cto` (the four reply permissions plus
   Embed Links, for its morning report); everyone else takes `reply`
   (`274877975552`). If the id lookup fails (lane off, item missing, 1Password
   hung) the card opens without the 1Password button and says so; fix the cause
   and re-open (close the first), or pass `--op-account-id`, `--op-vault-id`,
   `--op-item-id` and `--op-host` yourself.
3. **Tell Alex McRitchie it is there**, with the card's link the command prints
   (`https://mcritchie.studio/agents#agent-setup-<id>`). One live card per agent per
   kind per target: a second `open` is refused until the first is closed.

## 2. What Alex McRitchie clicks

Each step is a button or a copy field on the card, and each records who ticked it:

1. **Create the application.** Open the Developer Portal (new tab), New
   Application, named exactly as the copy field says; Download the avatar (the
   hub's own image, saved as a 1024px PNG) and upload it as the App Icon; paste
   the **Application ID** from General Information into the card and save. It is
   public, and it is what the invite and the checks are built from.
2. **Reset the bot's token.** Bot: the same avatar, Message Content Intent on,
   Save, then Reset Token and copy it once.
3. **Paste the token into 1Password.** The button opens the empty item; he
   pastes into `bot-token` and saves.
4. **Invite the bot.** The button is the OAuth2 authorize URL (scopes `bot` and
   `applications.commands`, the seat's permissions, the server pre-selected).
5. **Done.** The hub checks membership and the card reads **Waiting for Steffon
   to verify**. If the bot is not in the server, the card goes to **Needs
   attention** with the reason, and Done retries after he fixes it.

## 3. Verify and install (Steffon)

```bash
bin/agent-setup list                          # what waits for you
bin/agent-setup verify <id> --by steffon      # read, check, install, report
```

`verify` runs only on a card that is **verifying** or **needs attention**. It
reads `bot-token` with `op read` (OP_CACHE=false, bounded), calls Discord
`GET /users/@me` (the id must equal the Application ID, the username the card's
name, and it must be a bot) and `GET /users/@me/guilds` (the server must be
listed), then pipes the token on stdin to `bin/heroku-secret-set` as
`DISCORD_BOT_TOKEN_<SOUL>` on `mcritchie-studio` (never on `mcritchie-studio-qa`),
and reports. The hub then reads the installed var on a fresh dyno, asks Discord
again, and marks the card **Ready**, or **Needs attention** with the reason.
Every reason is a sentence Alex McRitchie can act on; none carries the token.

`--no-install` checks without installing (the card stays waiting). Fill the
item's `application-id` and `bot-user-id` from `bin/agent-setup list` (both
public), and add or update its row in
[`credential-inventory.md`](../../../modules/credential-inventory.md).

**If 1Password hangs** (the op cache daemon; the run stops at the deadline and
the card reads "the field is empty, or 1Password did not answer"): do not
retry in a loop. Quit and reopen the 1Password app, then a reboot; then verify
again.

## 4. Close

Test the soul's own replies ([`discord-bot-setup`](discord-bot-setup.md) Part 1b,
step 3): a reply from its own bot, unsigned, with `reply_posted` `via: soul_bot`.
Then:

```bash
bin/agent-setup close <id> --by steffon
```

A closed card folds under the column's **Done** disclosure.

## 5. Rotation

A bot token is rotated the same way it was made, because only the portal can
reset it: close the old card, open a new one (`open` again), and Alex McRitchie
runs the same five steps (step 1 is only the copy and the Application ID check:
the application exists). Verify installs the new token over the old var in one
release. For anything beyond the token (stores other than Heroku, a leaked
value), run [`credential-rotation`](credential-rotation.md); the card replaces its
mint step only.

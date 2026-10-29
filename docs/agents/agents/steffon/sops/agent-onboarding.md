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
   `discord.<soul>.agents` in `studio-agents` (credential-filing's
   `<service>.<entity>.<lane>`; the older `agents.discord.<bot>` titles are
   grandfathered, and a card names one with `--op-item`), the `bot-token` field present and
   EMPTY, `application-id` and `bot-user-id` fields ready, the Discord URL (for the
   logo) and the permission-matrix note. Discord-specific fields:
   [`discord-bot-setup`](discord-bot-setup.md) Part 1.
2. **Open the card.** It looks the item's ids up itself with
   `op item list --vault studio-agents --format json`, matched on the exact
   title: a listing carries ids, titles and the vault, never a field. It never
   runs `op item get`, which answers with every field's value (on a rotation
   card, the live token). No match, or two items of one title, opens the card
   without the 1Password button and says so.

   ```bash
   bin/agent-setup open discord --soul mason --by steffon
   ```

   Options: `--op-item` and `--op-vault` when the item is not
   `agents.discord.<soul>` in `studio-agents`; `--bot-name` when the bot is not
   named for the soul; `--permission-set reply|cto|server_admin` to override the
   seat's set. The seat decides by default (`config/agent_setups.yml` `seats`, else
   `cto` for a CTO in `config/cto_reports.yml`, else `reply`). The invite carries
   the set's integer:

   | Set | Integer | Flags | Seats |
   |-----|---------|-------|-------|
   | `reply` | `274877975552` | View Channels, Send Messages, Read Message History, Send Messages in Threads | `mack`; any soul with no seat |
   | `cto` | `274877991936` | `reply` + Embed Links (`16384`), for a morning report or alert with an embed | `alex` (the shared bot), `mason`, `turf_monster`, `avi` |
   | `server_admin` | `275683298320` | `cto` + Manage Channels (`16`), Manage Roles (`268435456`), Manage Webhooks (`536870912`); never Administrator | `steffon` |

   `test/services/agent_setups/discord_bot_kit_test.rb` pins all three. If the id lookup fails (lane off, item missing, 1Password
   hung) the card opens without the 1Password button and says so; fix the cause
   and re-open (close the first), or pass `--op-account-id`, `--op-vault-id`,
   `--op-item-id` and `--op-host` yourself.
   Open a card only for a bot that should have its own token. Tyrion's item is
   empty on purpose (OpenClaw holds his token;
   [`credential-inventory.md`](../../../modules/credential-inventory.md)), so he
   gets no card.
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

`verify` runs only on a card that is **verifying** or **needs attention**, and
an installing verify only with `--app` equal to the card's install app
(`mcritchie-studio`, the default) and never with `--local`: the hub re-checks the
var on the app it runs on, so `--app mcritchie-studio-qa` would install on
production and then ask QA about a var it never got. It is refused before
anything is read. `--no-install` may run anywhere. It
reads `bot-token` with `op read` (OP_CACHE=false, bounded), calls Discord
`GET /users/@me` (the id must equal the Application ID, the username the card's
name, and it must be a bot) and `GET /users/@me/guilds` (the server must be
listed), then pipes the token on stdin to `bin/heroku-secret-set` as
`DISCORD_BOT_TOKEN_<SOUL>` on `mcritchie-studio` (never on `mcritchie-studio-qa`),
and reports. The hub then reads the installed var on a fresh dyno, asks Discord
again, and marks the card **Ready**, or **Needs attention** with the reason. A
rate limit, a 5xx or an unreachable Discord on that re-check also lands on
**Needs attention** (logged in `/error_logs` against the card) with "the token is
installed. Run bin/agent-setup verify <id> again."; so does any fault in the
hub's own check after Done ("Press Done to try again"). No fault leaves a card on
**Checking** or **Verifying**. Every reason is a sentence Alex McRitchie can act
on; none carries the token.

**An installing verify makes a production release.** `bin/heroku-secret-set`
PATCHes the config, which is a new Heroku release on `mcritchie-studio`: every
dyno restarts (web and the worker, whose scheduler re-boots the Gateway listener
on the new config), and the release phase runs `bin/rails db:migrate` (Procfile
`release:`), so a migration waiting on `main` runs then. Do not install while a
deploy is in flight, and check `heroku releases -n 1 --app mcritchie-studio`
says "Set DISCORD_BOT_TOKEN_<SOUL> config vars" and the dynos came back `up`.
No `heroku ps:restart` is needed: the release is the restart.

**The shared bot's own soul (`alex`)** installs twice in one release: the card
carries `also_env: DISCORD_AGENT_BOT_TOKEN` (`config/agent_setups.yml`
`shared_bot`), so verify writes `DISCORD_BOT_TOKEN_ALEX` and
`DISCORD_AGENT_BOT_TOKEN` with one `--json` PATCH, and the hub's re-check turns
the card Ready only when both vars on the dyno hold the same token. A portal
Reset Token kills the old token at once, so the shared reader must move with it.

`--no-install` checks without installing (the card stays waiting). Fill the
item's `application-id` and `bot-user-id` from `bin/agent-setup list` (both
public), and add or update its row in
[`credential-inventory.md`](../../../modules/credential-inventory.md).

**If 1Password hangs** (the op cache daemon; the run stops at the deadline and
the card reads `Steffon's verify: The 1Password field bot-token on <item> is
empty (or 1Password did not answer): paste the token there, then Done.`): do not
retry in a loop. Quit and reopen the 1Password app, then a reboot; then verify
again.

## 4. Close

Test the soul's own replies ([`discord-bot-setup`](discord-bot-setup.md) Part 1b,
step 3): a reply from its own bot, unsigned, with `reply_posted` `via: soul_bot`.
Then:

```bash
bin/agent-setup close <id> --by steffon
```

In the same pass, add the soul's `DISCORD_BOT_TOKEN_<SOUL>` line to `.env.example`
and its row to [`credential-inventory.md`](../../../modules/credential-inventory.md)
(set by this SOP), and the soul to Part 1b's table in
[`discord-bot-setup`](discord-bot-setup.md). A closed card folds under the
column's **Done** disclosure.

## 5. Rotation

A bot token is rotated the same way it was made, because only the portal can
reset it: close the old card, open a new one (`open` again), and Alex McRitchie
runs the same five steps (step 1 is only the copy and the Application ID check:
the application exists). Verify installs the new token over the old var in one
release. A Reset Token in the SAME application kills the old token the moment
Alex McRitchie clicks it, so there is no overlap: be at the keyboard, and verify as
soon as the card reads waiting. For anything beyond the token (stores other than
Heroku, a leaked value, an overlap across two applications, the live proof), run
[`credential-rotation`](credential-rotation.md)'s Discord section; the card
replaces its mint and Heroku steps only.

## 6. Runbook: the five bots (house cleaning, 2026-10-28)

The cards that give each soul that should speak for itself its own bot, and
rotate the leaked shared token. Tyrion gets none (his token lives in OpenClaw);
Avi already has his (`agents.discord.avi`, `DISCORD_BOT_TOKEN_AVI`). Run as
Steffon, in the admin lane, from the hub checkout. No value is read into the
chat or the transcript at any step.

**First, the five empty items** (section 1, step 1), all in `studio-agents`,
each with `bot-token` present and empty, `application-id` and `bot-user-id`
ready:

| Soul | New item | Seat | Installs as | Replaces |
|------|----------|------|-------------|----------|
| `steffon` | `discord.steffon.agents` | `server_admin` (`275683298320`) | `DISCORD_BOT_TOKEN_STEFFON` | nothing: a new application |
| `alex` | `discord.alex.agents` | `cto` (`274877991936`) | `DISCORD_BOT_TOKEN_ALEX` and `DISCORD_AGENT_BOT_TOKEN`, one release | `agents.discord.xan` (the leaked token; the existing Alex application, bot user `1481150857809760399`) |
| `mason` | `discord.mason.agents` | `cto` (`274877991936`) | `DISCORD_BOT_TOKEN_MASON` | nothing: a new application |
| `mack` | `discord.mack.agents` | `reply` (`274877975552`) | `DISCORD_BOT_TOKEN_MACK` | `agents.discord.mack` (the existing Mack application, bot user `1479979322461913222`) |
| `turf_monster` | `discord.turf_monster.agents` | `cto` (`274877991936`) | `DISCORD_BOT_TOKEN_TURF_MONSTER` | `agents.discord.turf` (the existing Turf Monster application, bot user `1405042649479647293`) |

**Then the cards, in this order.** Steffon's first: a new application, so a
failure costs nothing, and it proves the live flow end to end. Alex's second,
straight after, because his token is the leaked one.

```bash
bin/agent-setup open discord --soul steffon --by steffon
bin/agent-setup open discord --soul alex --by steffon
bin/agent-setup open discord --soul mason --by steffon
bin/agent-setup open discord --soul mack --by steffon
bin/agent-setup open discord --soul turf_monster --by steffon --bot-name "Turf Monster"
```

Each prints the card's link for Alex McRitchie. For the three existing
applications (alex, mack, turf_monster) step 1 is only the copy and the
Application ID: he opens the existing application, not New Application. The
invite (step 4) re-authorizes a bot already in the server, which should
update its managed role to the seat's permissions; check the role in Server
Settings → Roles after, since a missing flag is not refused (Embed Links fails
silently).

**Alex's rotation (the leaked token).** The same card flow, with three
differences:

1. Reset Token in the Alex application kills `DISCORD_AGENT_BOT_TOKEN` at once:
   the Gateway listener stops on a 4004, the backstop poll and every shared
   reply fail, until the verify lands. Steffon is at the keyboard when Alex
   McRitchie resets it, and verifies the moment the card reads waiting.
2. The hub's check after Done runs through the shared bot, which is the dead
   token by then, so the card says the shared bot could not read the server and
   goes straight to waiting. Expected.
3. `bin/agent-setup verify <id> --by steffon` writes `DISCORD_BOT_TOKEN_ALEX`
   and `DISCORD_AGENT_BOT_TOKEN` in one release, which restarts the worker and
   with it the listener on the new token. Ready means both vars hold it.

**Live proof, per card,** before `close`: in the McRitchie Studio guild, an
@mention of the soul's bot answered by that bot, unsigned, and
`reply_posted` `via: soul_bot` on `/admin/agent_messages`. For Alex, also the
listener: a new message stored within a minute (the push path, not the
10-minute poll) after the release. A soul is answered only if
`config/agent_routes.yml` routes a mention of its bot user to it: `mason`,
`mack` and `steffon` are not routed yet, so add each new bot user id under that
soul's `users` in a small PR once its card is Ready (the id is public; `bin/agent-setup
list` shows it), then prove it.

**Retire the old items**, only after the new card is Ready and its live proof
passed:

1. `agents.discord.xan`: archive it (`op item delete agents.discord.xan
   --vault studio-agents --archive`, admin lane), then in one docs PR repoint
   every reference to `discord.alex.agents` (`grep -rn "agents.discord.xan"`:
   `credential-inventory.md`, `discord-bot-setup.md`, `agent-message-loop.md`,
   `report-destinations.md`, `alex/role.md`, `config/agent_routes.yml`,
   `AgentMessages::DiscordBot`'s header, `test/docs/discord_bot_named_alex_guard_test.rb`).
2. `agents.discord.mack` and `agents.discord.turf`: the same, each after its
   own card.
3. Append each rotation to the Rotation log (`credential-rotation` Phase 7), and
   add the soul's `DISCORD_BOT_TOKEN_<SOUL>` row to
   [`credential-inventory.md`](../../../modules/credential-inventory.md).

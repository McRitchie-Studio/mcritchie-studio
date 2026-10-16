# Report destinations (deliver a report to Discord)

**What it is.** One call that posts a registered report into the Discord channel
Alex picked for it, as the agents' bot, at most once per run. A session that sends
a report (the CTO daily application report is the first) needs only this page.

```ruby
result = ReportDestinations.deliver("daily_app_report",
                                    content: "**Daily application report**: 4 apps green, 1 deploy waiting.",
                                    embeds: [ { title: "turf-monster", description: "green · 0 errors" } ],
                                    idempotency_key: "daily_app_report:2026-10-15")
result.status      # => :posted
result.message_id  # => "1427…" (the Discord message id)
result.url         # => "https://discord.com/channels/<guild>/<channel>/<message>"
```

## 1. Register the report key

Add an entry to `config/report_destinations.yml` in the same PR as the code that
sends it:

```yaml
reports:
  daily_app_report:
    label: Daily application report
    description: Morning CTO summary
```

- The key is snake_case and stable: callers pass it verbatim. A family of keys
  may use a colon (`cto_report:turf_monster`).
- `label` is the card's title on the page; `description` is one line on what the
  report is.
- A key that is not registered raises `ArgumentError` on `deliver`.

Registered today: `daily_app_report` (Daily application report: morning CTO summary),
and one per-app CTO report per app with a CTO: `cto_report:mcritchie_studio`,
`cto_report:turf_monster`, `cto_report:cyvasse`
([`daily-app-report.md`](daily-app-report.md#per-app-cto-reports)). A key may carry
a colon (`cto_report:<domain>`); it stays one path segment on the page's Save.

## 2. Alex picks the channel

At **`/admin/report_destinations`** (Ops → Report destinations), each registered
key has a card with:

- a select of the bot's postable, unarchived channels, grouped by category;
- an **On** toggle;
- the last delivery, with a link to the message;
- the **Refresh channels** button for the whole directory.

**Save** stores the choice in `report_destinations` (one row per key, with
`updated_by`). Until a channel is saved, every `deliver` for that key answers
`:not_configured` and posts nothing.

**The channel directory.** `discord_channels` mirrors every channel and active
thread of each guild listed under `discord.guilds` in `config/agent_routes.yml`.
It holds the name, kind, category, position and postable, and whether the channel
is archived.

- **The sync.** `DiscordChannelSyncJob` refreshes it every 15 minutes
  (`config/recurring.yml`) and whenever Refresh channels is pressed. It reads
  `GET /guilds/{id}/channels` and `GET /guilds/{id}/threads/active`
  (`AgentMessages::DiscordBot`).
- **Postable.** The bot's real VIEW_CHANNEL plus SEND_MESSAGES
  (SEND_MESSAGES_IN_THREADS for a thread), computed from the guild's roles and the
  channel's overwrites (`DiscordDirectory::Permissions`). When the roles cannot be
  read, every text, announcement and thread channel counts as postable. Forum,
  voice and category channels, and private and locked threads, are never offered.
- **Archived.** A channel the sync no longer sees is archived, never deleted. A
  destination on an archived or no-longer-postable channel answers
  `:not_configured` until the sync sees it postable again or Alex picks another.
  The page keeps it selected, marked unavailable, so a Save does not clear it.
- **Inert without the token.** With `DISCORD_AGENT_BOT_TOKEN` unset the sync logs
  one line and reads nothing.

## 3. Call deliver

```ruby
ReportDestinations.deliver(report_key, content:, embeds: [], idempotency_key:)  # => ReportDestinations::Result
```

| Argument | Meaning |
|----------|---------|
| `report_key` | A key from `config/report_destinations.yml` |
| `content:` | The message text (Markdown). It may be blank only when there are embeds |
| `embeds:` | Up to ten Discord embed hashes (`title`, `description`, `fields`, `footer`, `color`, …), string or symbol keys |
| `idempotency_key:` | A string, at most 255 characters, unique per run of the report; for example `"daily_app_report:2026-10-15"` |

From a job or anywhere that should not wait on Discord, enqueue it instead:

```ruby
ReportDeliveryJob.perform_later("daily_app_report", content: "…", embeds: [], idempotency_key: "daily_app_report:2026-10-15")
```

The job retries a Discord failure (`AgentMessages::DiscordBot::Error`, a rate
limit included) with a polynomial back-off, five tries in all, using the same
idempotency key. A `:not_configured` or `:disabled` answer is recorded and not
retried, because it waits on Alex. `ReportDestinations.deliver!` is the raising
form the job uses.

## 4. Return values

`deliver` returns a `ReportDestinations::Result` with `status`, `message_id`, `url`,
`reason` and `delivery` (the `ReportDelivery` row), plus `posted?`.

| `status` | When | `message_id` / `url` |
|----------|------|----------------------|
| `:posted` | Posted now, or already posted for this idempotency key | Set |
| `:not_configured` | No channel is chosen, or the chosen channel is archived or no longer postable | nil; `reason` says which |
| `:disabled` | A channel is chosen but the toggle is off | nil |
| `:failed` | Discord refused or was unreachable, or `DISCORD_AGENT_BOT_TOKEN` is unset | nil; `reason` carries the error |

It **raises `ArgumentError`** for:

- an unknown report key;
- a blank or over-long idempotency key;
- a report with neither content nor embeds;
- an idempotency key already used by a different report;
- a report over Discord's limits (`ReportDestinations::LimitExceeded`, below).

Nothing is posted or recorded on any of these.

## 5. Idempotency: once per key

- **The receipt.** Every call is recorded in `report_deliveries`. Its
  `idempotency_key` is unique, and the row holds the status, channel, message id
  and error.
- **Posted is final.** A key whose row is `posted` returns that delivery
  (`:posted`, the same `message_id` and `url`) and sends nothing, whatever the new
  content says.
- **Other statuses retry.** A `:not_configured`, `:disabled` or `:failed` row is
  retried in place by the next call with the same key, so the report posts once
  Alex picks a channel or Discord recovers.
- **Concurrent calls.** The row is locked across the post: a second caller with
  the same key waits, then sees `posted`.
- **Lost responses.** The post carries a nonce derived from the key
  (`ReportDestinations.nonce_for`, 25 characters) with Discord's `enforce_nonce`.
  A post retried after a lost response gets back the message Discord already made.
- **No pings.** `allowed_mentions` parses nothing, so `@everyone`, a role or a user
  in a report pings nobody.

Pick the key from what makes the run unique: the report and its date for a daily
report (`daily_app_report:2026-10-15`), never a timestamp of the call.

## 6. Limits: refused, never split

Discord's per-message limits, measured as Discord does (UTF-16 code units, so an
emoji costs 2):

| What | Limit |
|------|-------|
| `content` | 2,000 |
| embeds per message | 10 |
| embed `title` · `description` | 256 · 4,096 |
| fields per embed · field `name` · field `value` | 25 · 256 · 1,024 |
| `footer.text` · `author.name` | 2,048 · 256 |
| all embeds' title + description + fields + footer + author together | 6,000 |

A report over any limit **raises `ReportDestinations::LimitExceeded`** (an
`ArgumentError`) naming the first limit broken, before anything is posted or
recorded. `deliver` never splits a report or clips it, so one call is always one
message with one `message_id` and `url`. A long report should put its detail in
embeds (up to 6,000 characters) and keep `content` to the headline.

## Where it lives

| Piece | Where |
|-------|-------|
| The contract | `ReportDestinations` (`app/services/report_destinations.rb`), `ReportDeliveryJob` |
| Registry | `config/report_destinations.yml` |
| Tables | `discord_channels`, `report_destinations`, `report_deliveries` |
| Directory sync | `DiscordChannelSyncJob` → `DiscordDirectory::Sync` and `DiscordDirectory::Permissions` |
| Discord REST | `AgentMessages::DiscordBot` (`guild_channels`, `active_threads`, `guild_roles`, `guild_member`, `current_user`, `post_report`) |
| The page | `Admin::ReportDestinationsController`, `/admin/report_destinations` |
| Tests | `test/services/report_destinations_test.rb`, `test/services/discord_directory/`, `test/integration/report_destinations_flow_test.rb`, `test/system/report_destinations_test.rb`, `e2e/report_destinations_admin.spec.js` |

The bot, its token (`DISCORD_AGENT_BOT_TOKEN`, 1Password `agents.discord.xan`)
and the guild list are shared with the agent mailbox:
[`agent-message-loop.md`](agent-message-loop.md).

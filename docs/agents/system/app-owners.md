# App owners and CTO settings

A person can own an app. An owner signs in to the hub, sees their app and its
CTO in the sidebar, and sets the CTO's settings. The CTO is downstream of the
app, so the app's page comes first. The plan is Phase 6a of
`.agents/epics/domain-agents.md`.

## Who owns what

`app_memberships` holds one row per (app, user): `app_slug`, `user_slug`, and
`role`, which is `owner` today (a CHECK constraint holds it). Both keys are slug
foreign keys that cascade on a rename and a delete. Ownership is this row, never
`users.role`: an owner stays a `viewer` and reaches only their own app's pages.

| App | Owner |
|-----|-------|
| McRitchie Studio (`mcritchie-studio`) | `alex@mcritchie.studio` |
| Turf Monster (`turf-monster`) | `alex@turfmonster.media` |
| Cyvasse (`cyvasse`) | `amcritchie@gmail.com` |

The table's migration seeds these three where the app and the user exist, so the
release phase sets production up. `AppMembership.seed_owners!` is the same step,
idempotent, for `db/seeds/04_app_memberships.rb` and the task's
`post_deploy_cmd`; it also gives a slugless user its slug. To add an owner:
`AppMembership.create!(app: App.find_by!(slug: "…"), user: User.find_by!(email: "…"))`.

A client app built through `/build` gets its owner row from **Build my app**
(`AppLaunch`), in the same transaction as the App, its CTO and its build task. Its
CTO is an `AppCto` row worn by the one `client_cto` soul, not a `cto_reports.yml`
entry, so it has a chat but no report and no settings page
([`client-cto.md`](client-cto.md)).

## Who sees what

| Viewer | Sees |
|--------|------|
| An app's owner | that app and its CTO |
| An admin | every app and every CTO |
| Anyone else, signed in | 404 on every page and on the save |
| A visitor | the sign-in page |

Every page answers **404, not 403**, so an app a viewer does not own does not
exist for them and an unannounced app's slug never leaks. The routes are in
`AdminWall::SIGNED_IN`; each controller then checks ownership itself
(`AppOwnership.manage_app?`). `test/integration/app_owners_flow_test.rb` proves
it per page and for the write.

**The CTO answers its app's owner** in that app's chat (`/applications/:slug/chat`)
and nowhere else, as the app's client and within the app's usage meter: the
app-owner exception in [`agent-message-loop.md`](agent-message-loop.md) ("Held").
An admin who does not own the app is answered by their own role, never by it.
In that chat the owner may also say `go`, `no` or `change: …` on a `change`
proposal (a `designed` task in the app's repo) while the app is under its cap,
and nowhere else ("Confirm by reply" in the same page; Alex McRitchie, 2026-10-18).

## The sidebar

Owners get a **Your apps** section at the top of the link sidebar
(`LinkTreeHelper#owner_link_sections`, `AppOwnership.sidebar_links`). The labels
count the viewer's OWN memberships, admins included:

- one owned app reads as its name (`Cyvasse`), followed by its **Pipeline**; two
  or more as **Applications** (each app's page links its own pipeline);
- one CTO among them reads as its name (`Turf`), two or more as **Agents**;
- a user who owns nothing gets no section, admin or not. An admin still reaches
  every app at `/applications`.

A CTO's name is its domain's `reply_name` in `config/agent_domains.yml`
(`Turf`), else the Agent row's name (`Tyrion`), else the soul titleized.

## The pages

| Path | What it shows |
|------|---------------|
| `/applications` | The visible apps in two tables (`ApplicationsWatchList`): **Live** on the left (a live `config/apps.yml` status and a production URL; health lazy-loaded per row from the daily report, Workspace mail on the app's own domain, warnings for a delinquent account, a missing backup or a blocked task) and **Pending launch** on the right (every other app but libraries and archived ones, each with why and its open tasks by stage). Each app shows its emoji circle with its CTO's avatar on top (the emoji alone without a CTO), and clicking it opens the app's pipeline, its todos and steps. An owner sees the same split over their own apps, with task counts but no titles. An admin reaches it from the sidebar's Studio section (config/navigation.yml, audience `signed_in`); an owner from their own sidebar links |
| `/applications/:slug` | Name, emoji and colour, health, the CTO card, and agent usage (the meter, this month's and today's totals); owners listed for admins, and for admins the tier and cap-lift form |
| `/applications/:slug/pipeline` | The app's tasks by lane, read-only and sanitized for an owner; the building lanes in use. Detail: [`client-pipeline.md`](client-pipeline.md) |
| `/applications/:slug/health` | The lazy health frame, cached 15 minutes per app; `?compact=1` is the index's one-badge cell |
| `/applications/:slug/usage` | The usage meter as JSON |
| `/applications/:slug/usage_cap` | `PATCH`, admin only (the wall refuses anyone else): the app's package tier and the cap lift |
| `/applications/:slug/chat` | `GET` and `POST`: the viewer's own live chat with the app's CTO, with typing, the answer streamed in, and the usage meter in tokens. Detail: [`agent-message-loop.md`](agent-message-loop.md#web-chat-the-ctos-answer-on-mcritchie-studio-phase-7-step-3) |
| `/agents/settings` | The visible CTOs and where each one reports |
| `/agents/:slug/settings` | The CTO's name, avatar and app, its report setting, and the app's usage meter |

`/agents/:slug` stays the admin soul page (tasks, activities, docs); owners get
the separate settings page.

**The CTO map** is `config/cto_reports.yml` (domain → app, soul), the one file
that names every app's CTO, Cyvasse's included. The Agent row is the soul
hyphenated (`turf_monster` → `turf-monster`).

**Health** comes from the central health report (`DailyAppReport.health_for`) for
the day ending at the last 07:00 Denver. The page shows counts only. An app with
no `HEALTH_TOKEN_<SLUG>` reads "not connected" and is never fetched.

**Usage** is the CTO's answers this month, measured from each answer's run
summary, against the monthly allowance of the app's package tier. Only client
and public answers count against it. The allowances ship blank (unlimited) until
Alex McRitchie prices them. Detail: [`agent-usage.md`](agent-usage.md).

## The report channel

The first setting is where the CTO's daily report posts. The page writes the same
`ReportDestination` row (`cto_report:<domain>`) that
[`/admin/report_destinations`](report-destinations.md) edits: a channel and an
on/off switch. The owner may write only their own CTO's key.

**The picker** lists only channels the CTO's bot can post a report in
(`AppOwnership.report_channels`):

- with `DISCORD_BOT_TOKEN_<SOUL>` set, the channels where that bot has View
  Channel, Send Messages and Embed Links (`discord_channels.postable_souls`);
- without it, the shared bot's postable channels.

Either way it lists only channels the shared directory also holds as selectable,
because `ReportDestination` keeps a pick to that set. The save refuses a channel
the picker does not offer, apart from the one already saved. No token or ENV name
is rendered.

**The cache.** `DiscordDirectory::Sync`, every 15 minutes, also reads each CTO
soul bot whose token is set: its own user, its guild membership, and the guild's
roles against each channel's overwrites (`DiscordDirectory::Permissions`, with
`embeds: true`). It writes the souls that pass to `postable_souls`. A page load
never calls Discord. A soul bot that cannot read its membership (not in the guild,
or a bad token) is offered no channel, and the sync summary says so. Today every
channel is in the McRitchie Studio guild, so an owner sees our internal channels.

## What a setting can never do

A setting here changes where a CTO posts. It gives the CTO no tool, capability or
credential, and it never reaches another app's row. Owning an app does not make
its CTO answer you as the owner either: the chat's audience is your agent
person's role, set by an operator, as on Discord.

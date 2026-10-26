# Daily app report (the morning CTO summary in Discord)

**What it is.** One hub job, at **07:00 America/Denver**, reads every live
studio-engine app's health for the day and posts **one** Discord message: a
headline, then one embed per app. The same run then posts each app's own
[CTO report](#per-app-cto-reports), in its CTO's voice. Satellites have no production worker of their
own, so there are no per-app schedules: the hub pulls.

## When and which day

- **Schedule.** `daily_app_report` in `config/recurring.yml` (production) runs
  `DailyAppReportJob` at `0 7 * * * America/Denver`. QA boots production and
  skips it.
- **One window for all.** The job computes one window end, the latest 07:00
  Denver, and passes it as `ending` to every app. Every app reports the same
  24 hours (07:00 to 07:00 on the wall clock, 25 or 23 on a DST day). A late run
  or a retry reports the same day. `DailyAppReportJob.perform_later("2026-10-15T07:00:00-06:00")`
  pins the window by hand.
- **Once a day.** The delivery's idempotency key is
  `daily_app_report:<Denver date of the window end>`. A day that already posted
  is not fetched or posted again.

## Which apps

Every app in `config/apps.yml` with `engine: true`, a live status (active,
delinquent or showcase) and a `production_url`, except the slugs in
`AppCatalog::UNANNOUNCED`, whose names may not reach a post yet
(`DailyAppReport.apps`).

- **The hub** (`mcritchie-studio`) is read in-process with
  `Studio::HealthReport.build`. It needs no token.
- **Every other app** is read over HTTP:
  `GET <production_url>/_studio/health_report?ending=<iso8601>` with
  `Authorization: Bearer <token>` (the studio-engine endpoint; 5-second connect
  and 20-second read timeouts).

## Env vars (hub production)

One token per satellite, named from its slug: upper-case it and turn dashes into
underscores.

| App | Hub env var |
|-----|-------------|
| Turf Monster | `HEALTH_TOKEN_TURF_MONSTER` |
| Cyvasse | `HEALTH_TOKEN_CYVASSE` |
| McRitchie Industries | `HEALTH_TOKEN_MCRITCHIE_INDUSTRIES` |
| Moms App | `HEALTH_TOKEN_MOMS_APP` |
| Rantly | `HEALTH_TOKEN_RANTLY` |

The same value must be set on the satellite, as the token its
`/_studio/health_report` endpoint accepts (see studio-engine's health report
docs). Set both through Steffon's `credential-filing` SOP; never paste a token in
chat.

## What each app's line says

| State | When | In Discord |
|-------|------|------------|
| Not wired | The hub has no `HEALTH_TOKEN_<SLUG>` | Listed in the headline's "Not wired (no token)" line; not fetched, not an error |
| Unreachable | Timeout, refused connection, 401 (token mismatch), 404 (endpoint not deployed or no token on the app), any other status, bad JSON, an unknown `schema` | A red embed, `Unreachable (<reason>)`, and an `ErrorLog` row with target `daily-app-report <slug>` |
| With errors | Errors in the window, or a section the app could not read | An amber embed: the counts, then the top three error groups (class, count, a clipped message) and "+N more" |
| With activity · quiet | Signups or contact messages, no errors · nothing at all | A green embed with the counts |

**Backup line.** Each backed-up app's embed (`backups: true` in
`config/apps.yml`) carries one more line under its counts, from what Steffon's
03:30 `DbBackupSweepJob` recorded: `Backup 02:04, 48 MB` (the latest completed
backup's Denver time and size), `Backup MISSING` (none since the 02:00 slot; `(capture
started)` when the sweep started one), `Backup unread (<reason>)`, or `Backup
not checked` (no sweep in 26 hours, as before `HEROKU_BACKUP_API_KEY` is set).
The headline adds one count line, `Backups: 5 fresh, 1 missing`, over every
backed-up app, unannounced ones included, without naming any. Missing and unread
backups also alert in the ops channel once per incident
([`db-restore-drill`](../agents/steffon/sops/db-restore-drill.md)).

Embeds are worst first. Counts only: no names or emails, and email addresses in
error messages are redacted. More than ten fetched apps fold the rest into the
content's "Also:" list. The message is fitted to Discord's limits as it is built
(content 2,000, ten embeds, 6,000 across embeds), because `ReportDestinations`
refuses an over-limit report rather than splitting it.

## Delivery

Through the report-destination contract, key `daily_app_report`
([`report-destinations.md`](report-destinations.md)): Alex McRitchie picks the channel at
`/admin/report_destinations`. The job calls `ReportDestinations.deliver` and logs
`[daily-app-report] daily_app_report:<date> status=<status> url=<url>`; the
receipt is the `report_deliveries` row for that key.

- `:not_configured` or `:disabled`: a logged skip. The next run (or a manual
  `perform_later` for that date) posts once Alex McRitchie picks a channel.
- `:failed`: `deliver` writes the ErrorLog; the job hands the same message and key
  to `ReportDeliveryJob`, which retries with back-off and still posts once.

## Per-app CTO reports

The same run then posts **one report per app that has a CTO**, each under its own
report key, so Alex McRitchie picks a channel per app at `/admin/report_destinations`, and
each app's owner can pick their own at `/agents/:slug/settings`
([`app-owners.md`](app-owners.md)).

| App | Report key | CTO (voice) |
|-----|------------|-------------|
| McRitchie Studio | `cto_report:mcritchie_studio` | Avi |
| Turf Monster | `cto_report:turf_monster` | Turf |
| Cyvasse | `cto_report:cyvasse` | Tyrion |

- **Config.** `config/cto_reports.yml` maps each domain key to its app slug and
  CTO soul. It is separate from `config/agent_domains.yml` on purpose: that
  file's `soul:` is the Discord front door, which need not be the CTO who signs
  the report. Each key must also be registered in `config/report_destinations.yml`
  (a test holds both lists together).
- **Bot.** Each CTO report posts as its CTO's own Discord bot when
  `DISCORD_BOT_TOKEN_<SOUL>` is set (`DISCORD_BOT_TOKEN_AVI`,
  `DISCORD_BOT_TOKEN_TURF_MONSTER`, `DISCORD_BOT_TOKEN_TYRION`), else as the
  agents' shared bot. A refused soul bot falls back to the shared bot once, with
  an `ErrorLog`; the combined `daily_app_report` always posts as the shared bot.
  Detail: [`report-destinations.md`](report-destinations.md#which-bot-posts).
- **Voice.** A fixed template per soul (`CtoReport::Voice`): an opener, one line
  for the day's state (quiet, activity, errors, unreachable) and a signature.
  Every number is computed in code; there is no model call, so a line cannot
  invent a fact. Counts only, as above.
- **What it says.** The app's health counts in the voiced paragraph, and the same
  per-app embed the combined report shows (counts, top error groups). The hub
  adds its board: open tasks in build, waiting on review and on the way to
  production (with the blocked count), tasks shipped in the window, and the
  release in flight (its stage and task count). Every report then carries one
  usage line above the signature: the CTO domain's answers in the window, their
  tokens by kind, cost and average time (`AgentUsage`,
  [`agent-usage.md`](agent-usage.md)). A domain no routed soul serves (Cyvasse
  today) has no usage line.
- **Internal channels only.** The embed carries error class names and a clipped
  error message (emails redacted, nothing else), so point every `cto_report:*`
  key at an internal channel, never a public community one.
- **One read per app.** The combined report and the CTO reports share the run's
  health memo, so each app is read at most once per run.
- **Once a day.** The idempotency key is `cto_report:<domain>:<Denver date>`.
- **Skips, each a log line `[cto-report] …`, never an error:** an app with no
  `HEALTH_TOKEN_<SLUG>` (no delivery at all), a destination with no channel or
  turned off, a day already posted. An unreachable app still reports, saying
  why, with no numbers.
- **Never reports:** an app in `AppCatalog::UNANNOUNCED`, an app off the live
  list above, and a domain marked `internal: true` in `config/agent_domains.yml`.
- **Independent.** The job rescues each half on its own: a crash in the combined
  report still sends the CTO reports, and one app's crash still sends the next.

To add one: an entry in `config/cto_reports.yml`, its key in
`config/report_destinations.yml`, and a voice in `CtoReport::Voice::VOICES` if the
soul has none yet.

## Add an app

1. The app runs studio-engine with the health-report endpoint deployed and a
   token configured on it.
2. Its `config/apps.yml` record has `engine: true`, a live status and a
   `production_url`.
3. Set `HEALTH_TOKEN_<SLUG>` on the hub (`mcritchie-studio`) to the same token.

Tomorrow's report reads it; until step 3 it shows as not wired.

## Where it lives

| Piece | Where |
|-------|-------|
| Job · schedule | `app/jobs/daily_app_report_job.rb` · `config/recurring.yml` |
| Run, app list, normalizing | `app/services/daily_app_report.rb` |
| HTTP read | `app/services/daily_app_report/fetcher.rb` |
| The message | `app/services/daily_app_report/message.rb` |
| Backup lines | `app/services/db_backup_sweep.rb` (`report_lines`, `report_summary`) |
| Per-app CTO reports | `app/services/cto_report.rb`, `app/services/cto_report/` (`voice.rb`, `message.rb`), `config/cto_reports.yml` |
| Tests | `test/services/daily_app_report_test.rb`, `test/services/daily_app_report/`, `test/services/cto_report_test.rb`, `test/services/cto_report/`, `test/jobs/daily_app_report_job_test.rb` |

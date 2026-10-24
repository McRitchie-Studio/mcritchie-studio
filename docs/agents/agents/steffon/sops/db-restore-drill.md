# Database Restore Drill
<!-- registry: nightly Postgres backups, the backup sweep, monthly restore drill -->

## Status: Active

This is Steffon's `db-restore-drill` SOP. Nightly database backups and a monthly
restore drill are a **paid-plan benefit**: every live Studio or Product app with a
database has them, and a Basic app has them only by Alex's named exception.
Alex set it on 2026-10-24: "Lets still move the db backups to paid plans so its
another benefit of a paid plan" and "The nightly backup should be one of the
agents jobs."

`config/apps.yml` is the record. Each app row carries `database`, `backups` and
`restore_drilled`; `test/lib/app_registry_test.rb` fails when a paid app with a
database has `backups: false`, or a Basic app has `backups: true` without a
`BACKUP_EXCEPTIONS` row (today only `moms-app`, Alex's family app).

| Act | Who runs it | When | Section |
|---|---|---|---|
| **Provision** | Steffon, in the deploy | once per app, when it gets a paid plan | §1 |
| **Sweep** | the hub, no person | every night at 03:30 Denver | §2 |
| **Drill** | Steffon | monthly, from his heartbeat | §3 |
| **Record** | Steffon | after each drill | §4 |

The object-storage undo (Cloudflare R2 files) is a separate act:
[`r2-backup`](r2-backup.md).

## What this act is NOT

- **It never restores into production.** A drill restores into a scratch
  add-on on a QA app. A real recovery of production is an incident: Alex decides
  it, in his own words in the current chat.
- **It never deletes a backup.** Heroku keeps its own retention
  (`num_keep` on each transfer).

## 1. Provision — at deploy

Heroku Postgres `essential-*` plans include scheduled backups at no extra cost.
When an app gets a paid plan (or a database), schedule its nightly backup and
take the first one:

```bash
APP=<heroku-app>
heroku pg:backups:schedule DATABASE_URL --at '02:00 America/Denver' -a "$APP"
heroku pg:backups:capture -a "$APP"
heroku pg:backups:schedules -a "$APP"   # must print the 02:00 America/Denver schedule
```

Then set the app's row in `config/apps.yml` to `database: true` and
`backups: true` in the deploy task. The sweep (§2) watches it from the next
night. When an app leaves the paid plans or is archived, unschedule it
(`heroku pg:backups:unschedule DATABASE_URL -a "$APP"`) and set `backups: false`.

## 2. Sweep — the nightly agent job

`DbBackupSweepJob` runs on the hub (`config/recurring.yml`, 03:30 America/Denver,
after Heroku's 02:00 captures). For every live app with `backups: true` it reads
the app's Heroku Postgres transfers and:

- records the latest completed backup's time and size on the app's `App` row;
- when no backup completed since the **last scheduled slot** (02:00 Denver,
  with 90 minutes' grace: at 03:30 that is the same night's 02:00), starts a
  capture (unless one it started is still running) and opens the
  `db_backup_missing` incident. The slot, not a rolling window, is what catches
  a single missed night;
- when it cannot read an app (API down, key rejected), opens
  `db_backup_sweep_failed`. Unread is not missing: it captures nothing.

Both incidents post **once** to the ops channel through the dispatcher's floor
(`AgentMessages::FloorAlert`), and once more when they clear. A night the
sweep cannot read never clears `db_backup_missing`: unread is not fresh. There is
one open incident per kind, so a **second app going missing while
`db_backup_missing` is open posts nothing new**; it joins the incident's detail
and shows as `Backup MISSING` on the morning report. Read the report, not only
the alert. The sweep's log lines name every app by slug (Commercial Welding
included); the posts count an unannounced app without naming it. The 07:00 daily
app report carries one line per app (`Backup 02:04, 48 MB`, `Backup MISSING`,
`Backup unread (<reason>)`, `Backup not checked`) and a `Backups:` count in its
headline. Code: `app/services/db_backup_sweep.rb`.

**The key.** The job reads `HEROKU_BACKUP_API_KEY` from the hub's config. Until
it is set, each run writes one log line (`[db-backup-sweep] inert: …`) and
nothing else, and the report says `Backup not checked`. To set it, file the
credential by [`credential-filing`](credential-filing.md):

1. Create a dedicated Heroku OAuth authorization on the company account, scope
   `identity,read-protected,write-protected` (reading transfers and starting a
   capture), described "hub backup sweep", and file it in the same pipe as
   **`heroku.mcritchie-studio.applications`** in the `studio-applications` vault
   (app-scoped: only the hub's runtime uses it). Run it from the admin lane:
   `source ~/.zprofile.admin` first, which stages `HEROKU_STUDIO_ADMIN_API_KEY`
   (only that key may create or revoke an authorization; the agent key is
   refused), and give it to the CLI as `HEROKU_API_KEY` in the command's own
   environment, never on its argv. The token goes from `--json` through `jq`
   into the item's concealed field on stdin, so it never reaches the terminal,
   a variable or an argument; plain `authorizations:create` would print it.

   ```bash
   source ~/.zprofile.admin
   : "${HEROKU_STUDIO_ADMIN_API_KEY:?refusing -- the admin profile staged no key}"
   set -o pipefail
   HEROKU_API_KEY="$HEROKU_STUDIO_ADMIN_API_KEY" \
     heroku authorizations:create -d "hub backup sweep" -s identity,read-protected,write-protected --json |
     jq '{title: "heroku.mcritchie-studio.applications", category: "API_CREDENTIAL",
          fields: [{id: "credential", label: "credential", type: "CONCEALED", value: .access_token.token},
                   {id: "authorization-id", label: "authorization-id", type: "STRING", value: .id}]}' |
     op item create --vault studio-applications --url "https://dashboard.heroku.com/account/applications" - \
       "used-by[text]=mcritchie-studio HEROKU_BACKUP_API_KEY (DbBackupSweepJob)" > /dev/null
   ```

   The template names its own category, so no `--category` (op refuses both).
   This pipe was rehearsed with `op item create --dry-run` and a fake
   authorization on 2026-10-24.

   **If the pipe fails after Heroku answered** (`jq` or `op` errors, the pipe
   exits non-zero, or the item is not in the vault afterwards), the
   authorization exists on the account and nothing holds its token: revoke it
   before you retry, or it lives on as an orphan credential. Its id is in the
   account's list; take it through `jq`, which prints the id and the
   description and never the token (bare `heroku authorizations --json` prints
   every authorization's token on the account), then revoke it, still from the
   admin profile:

   ```bash
   : "${HEROKU_STUDIO_ADMIN_API_KEY:?refusing -- source ~/.zprofile.admin first}"
   HEROKU_API_KEY="$HEROKU_STUDIO_ADMIN_API_KEY" heroku authorizations --json |
     jq -r '.[] | select(.description == "hub backup sweep") | "\(.id)  \(.created_at)"'
   HEROKU_API_KEY="$HEROKU_STUDIO_ADMIN_API_KEY" heroku authorizations:revoke <id>
   ```

   More than one `hub backup sweep` row means an earlier attempt orphaned one
   too: keep only the id the vault item's `authorization-id` field names (none
   yet, so revoke them all), then run step 1 again.
2. Finish the item by [`credential-filing`](credential-filing.md) sections 3
   (the `notesPlain` permission matrix) and 6 (verify by read-back), and add its
   row to [`credential-inventory.md`](../../../modules/credential-inventory.md).
3. Apply it from the item, never from a copy, the value on stdin (an `xargs`
   into `heroku config:set` would put it on a command line):
   `op read 'op://studio-applications/heroku.mcritchie-studio.applications/credential' | /Users/alex/projects/mcritchie-studio/bin/heroku-secret-set mcritchie-studio HEROKU_BACKUP_API_KEY`
4. Verify without printing it: run the job once and read the log.

   ```bash
   heroku run -a mcritchie-studio -- bin/rails runner 'puts DbBackupSweep.new.call.map { |r| "#{r.slug}=#{r.state}" }'
   ```

   Every backed-up app must answer `fresh`. An `unreadable` app names its reason.

**On an alert.** `db_backup_missing`: run `heroku pg:backups -a <app>` and
`heroku pg:backups:schedules -a <app>`. A missing schedule is re-added with §1.
A capture the sweep started shows as the newest `b…` backup; when it completed,
the incident clears on the next night's run. `db_backup_sweep_failed` with
`HTTP 401 key rejected`: the authorization was revoked or rotated; re-file the
key (steps 1-3).

## 3. Drill — monthly

Run it when Steffon's heartbeat finds a backed-up app whose `restore_drilled` is
null or more than 30 days old. Drill **one app per month**, the one drilled
longest ago (null first, Studio and Product apps before a Basic exception).

```bash
cd /Users/alex/projects/mcritchie-studio
bin/agent-activity start --category Workflow --reason "db-restore-drill <slug>"
bin/release status        # do not drill on a QA app while a release is mid-QA
```

1. **Pick the host.** The scratch database lives on the app's QA app
   (`config/qa_environments.yml` `heroku_app`, e.g. `turf-monster-qa`); an app
   with no QA copy (Cyvasse, Moms App) drills on `mcritchie-studio-qa`. The host
   must never be a `heroku_app` in `config/apps.yml`: that is production.

   ```bash
   PROD=<production heroku app>; HOST=<qa app>
   ```

2. **Name the backup.** Take the newest completed backup:
   `heroku pg:backups -a "$PROD"` (for example `a041`, finished 02:01).

3. **Create the scratch add-on** on the production database's own plan, so
   the restore fits (the hub runs `essential-1`; read the plan, never assume
   `essential-0`). It attaches as `DRILL_URL`, beside the QA app's own
   `DATABASE_URL`, which it never touches. The new config var restarts the QA
   app's dynos once.

   ```bash
   PLAN=$(heroku addons -a "$PROD" --json | ruby -rjson -e 'puts JSON.parse(STDIN.read).find { |a| a["config_vars"].include?("DATABASE_URL") }.dig("plan", "name")')
   echo "$PLAN"     # e.g. heroku-postgresql:essential-1
   heroku addons:create "$PLAN" --as DRILL -a "$HOST"
   heroku pg:wait -a "$HOST"
   ```

4. **Restore** the production backup into it:

   ```bash
   heroku pg:backups:restore "$PROD::<backup>" DRILL_URL -a "$HOST" --confirm "$HOST"
   ```

5. **Verify three tables against production.** Pick `users` and the app's two
   busiest tables
   (`heroku pg:psql -a "$PROD" -c "SELECT relname FROM pg_stat_user_tables ORDER BY n_live_tup DESC LIMIT 5"`).
   For each, count the scratch copy, then count production as of the backup's
   **start** time: `pg_dump` takes its snapshot when it starts, so a row written
   while it ran is not in the backup. Read the start from
   `heroku pg:backups:info <backup> -a "$PROD"` (`Started at`, UTC):

   ```bash
   heroku pg:psql DRILL_URL -a "$HOST" -c "SELECT count(*) FROM <table>"
   heroku pg:psql -a "$PROD" -c "SELECT count(*) FROM <table> WHERE created_at < '<backup started_at, UTC>'"
   ```

   The two counts must match (a transaction that straddled the start can move
   one by a row or two; name it). A table with deletes since the backup may run
   higher on the scratch side; say which. A lower scratch count, a failed
   restore, or an empty table that production fills is a **failed drill**:
   report it to Alex at once with the backup name and the counts, and keep the
   scratch add-on for diagnosis.

6. **Destroy the scratch add-on**, in the same session (it bills by the hour):

   ```bash
   heroku addons:destroy DRILL -a "$HOST" --confirm "$HOST"
   heroku addons -a "$HOST"    # DRILL is gone; the QA app's own database remains
   ```

## 4. Record

1. In a task (`bin/task begin --title "Restore Drill <App>" --repo mcritchie-studio
   --kind chore --shape backend …`), set the drilled app's row in
   `config/apps.yml` to `restore_drilled: "YYYY-MM-DD"` (quoted) and put the
   backup name, the three tables and their counts in the PR body.
2. Close the activity:
   `bin/agent-activity end --outcome "drilled <slug>: <backup>, 3 tables match"`.
3. Report: app, backup, tables and counts, the scratch add-on destroyed, and the
   next app due.

## Background — not needed to execute

The decision and the audit that found five apps without a backup schedule and no
restore ever rehearsed: `.agents/epics/audits/platform-audit-2026-10-24/lane-infra-steffon.md`
(D2). The package row that sells this: `Nightly backups` in
`config/workspace_packages.yml`, drawn on `/packages/stack`.

# The Token Database

**Purpose.** Give a new app that stores nothing yet a real, empty database, so
the shared tooling works on it from the first desk. Move it to Postgres the day
it must keep something.

**Why.** Alex McRitchie, 2026-11-08: "We need a solution for a token simple db
for initially built applications." The showcase apps were built with no
database, and the tooling assumes ActiveRecord:

- `bin/agent-worktree up` runs `bin/rails db:prepare`, which is not a task in an
  app with no ActiveRecord, so bringup aborted.
- `bin/fast-check`'s test-database guard boots the app and reads the database it
  connects to. The boot died on `uninitialized constant ActiveRecord`, so every
  pre-flight refused, and builders submitted with `--skip-preflight`.
- `bin/verify-review-hop` needs the engine's `/_studio/local_review`, which an
  app with no database does not draw.

The tooling now handles an app with no database (below). A new app still takes
the token database by default, because the token is what makes it a normal app
for every tool, and the step to Postgres is then a config change, not a new
framework.

## The recipe

A token database is SQLite, with an empty schema and no Heroku add-on.
`rantly` is the worked example (task `rantly-adopts-token-database`).

1. `Gemfile`: `gem "sqlite3", ">= 2.1"`.
2. `config/application.rb`: `require "active_record/railtie"` (or
   `rails new --database=sqlite3`, which writes it).
3. `config/database.yml`, one entry per environment, each with `url:`:

   ```yaml
   default: &default
     adapter: sqlite3
     pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
     timeout: 5000

   development:
     <<: *default
     database: storage/development.sqlite3
     url: sqlite3:storage/development.sqlite3

   test:
     <<: *default
     database: storage/test.sqlite3
     url: sqlite3:storage/test.sqlite3

   production:
     <<: *default
     database: storage/production.sqlite3
     url: sqlite3:storage/production.sqlite3
   ```

4. `db/schema.rb`: `ActiveRecord::Schema[8.1].define(version: 0) do end` (what
   `bin/rails db:prepare` writes for an app with no migrations).
5. `.gitignore`: `/storage/*` and `!/storage/.keep`, and commit `storage/.keep`.
6. A test that the app connects to the file, that the schema loads, and that a
   Postgres `DATABASE_URL` does not move it (rantly's
   `test/integration/token_database_test.rb`).

**Why `url:`.** A desk exports `DATABASE_URL` at a Postgres database
(`bin/agent-worktree`, `stack_values`). Rails merges `DATABASE_URL` over an
entry that has only `database:`, which turns the app into a Postgres app with no
`pg` gem. Rails leaves an entry that has its own `url:` alone. The relative path
resolves under the app root, so each desk keeps its own files, and the
pre-flight's guard admits a file inside the desk by containment.

**Why `adapter:` and `database:` as well.** The hub reads `config/database.yml`
without booting the app (`Release::GateWorkspace`): `adapter` tells the release
gate not to hand the app a Postgres URL, and `test.database` is the name the
guard compares a desk against. They must name the same file as `url:`.

**Production.** No add-on and no release phase. On Heroku the file sits on the
dyno's ephemeral disk and is lost on every restart. That is acceptable only
because the token database holds nothing; if nothing calls ActiveRecord, the
file is never even created. Do not store a user, an order or a setting in it.

## An app that takes studio-engine

Loading ActiveRecord makes the engine treat the app as a full consumer
(`Studio.active_record?`). The engine's migrations are written for Postgres
(`t.jsonb`, which SQLite does not have) and expect a `users` table, so a token
database cannot hold them. An app that takes the engine only for views (the site
footer, the not-found page) keeps it footer-only with three lines, all in
rantly:

| Where | What | Without it |
|-------|------|------------|
| `config/application.rb` | an initializer that calls `Rails.autoloaders.main.do_not_eager_load` on each of `Studio::Engine.active_record_dependent_roots` | production's eager load raises: the engine's controllers skip a `:require_authentication` the app never defines |
| `lib/tasks/token_database.rake` | clear `studio_engine:install:migrations` and redefine it as a no-op with a `desc` | the hub's release sweep copies the engine's migrations in after each engine publish, then fails to migrate them on SQLite and aborts the release |
| `config/initializers/studio.rb` | `config.host_schema_check = false` | boot raises in development and test for the missing `error_logs`, `theme_settings` and `image_caches` tables |

Do not call `Studio.routes(self)`. So the engine's sign-in, admin pages, error
logs, magic links and the **local-review hop** are not available on a token
database. `bin/verify-review-hop` names a 404 mint as this case. An app that
needs any of them moves to Postgres first.

## Upgrade to Postgres

Do this the day the app must keep something, or must take the engine's sign-in
or the local-review hop.

1. `Gemfile`: replace `sqlite3` with `gem "pg"`. Run `bundle install`.
2. `config/database.yml`: the hub's Postgres shape (a managed satellite's, for
   example cyvasse's): `adapter: postgresql`, `<app>_development`,
   `<app>_test` with `url: <%= ENV["TEST_DATABASE_URL"] %>` (a desk's isolated
   test database), and production from `DATABASE_URL`. Remove every `url:
   sqlite3:` line.
3. Delete `lib/tasks/token_database.rake`, the eager-load initializer and
   `host_schema_check = false`, then run `bin/rails studio_engine:install:migrations`
   and `bin/rails db:migrate` if the app takes the engine's database features.
4. Heroku: add a Postgres add-on (Alex McRitchie approves the cost), and add
   `release: bin/rails db:migrate` to the `Procfile`. `bin/register-app`'s
   contract requires that line once the `Gemfile` names `pg`.
5. The static deploy (`static-cloudflare.md`) no longer fits: an app that keeps
   data serves from its dyno.

There is no data to move: the token database never held any.

## An app with no database at all

The tooling admits it without a crash, decided from files, never from a failed
boot (`DeskGuard.no_database_app?`: `bin/rails` exists, `config/database.yml`
does not, and `config/application.rb` requires neither `rails/all` nor
`active_record/railtie`):

- `bin/agent-worktree up` skips `db:prepare` and `db:test:prepare`, prints why,
  and still runs `test:prepare`.
- `bin/fast-check` prints the same note, runs `bin/rails test:prepare` as its
  prepare lane, and runs every other lane as usual. Its test-database guard does
  not apply.
- `bin/verify-review-hop` fails at the mint with the reason, not a bare 404.

The apps in that state on 2026-11-08: `weekly-lock`, `prisoners-dilemma`,
`search-position`, `portfolio`, `10and5` and `dads-app`. None takes
studio-engine, so each would need only steps 1 to 6 of the recipe. `chain-ops`
already has Postgres.

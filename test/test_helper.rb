ENV["RAILS_ENV"] ||= "test"
# Arm Release::SealRetry's real-sleep guard for the WHOLE suite. The ship seal's
# boot-window retry waits ~30 real seconds in production; a test that forgets to
# inject a `sleeper` would silently burn that per call. Armed here, the policy
# RAISES instead of sleeping, so the mistake surfaces in milliseconds and cannot
# ride into CI as a slow-suite mystery (see app/models/release/seal_retry.rb).
ENV["SEAL_RETRY_NO_SLEEP"] = "1"
require_relative "../config/environment"
require "rails/test_help"

# Draw the route set NOW — under the real (local) test env, before any test can
# stub Rails.env. Routes draw LAZILY whenever eager loading is off, and TWO
# different Rails settings decide that — the rake test lane is governed by the
# second, which is the subtlety that trips readers (config.eager_load reads TRUE
# under CI, so it LOOKS like routes are eager there, but they are not):
#   * config.eager_load = ENV["CI"].present? (config/environments/test.rb) — TRUE
#     under CI. Governs the app server, `rails console`, and `rails runner`
#     (all eager; routes drawn at boot).
#   * config.rake_eager_load — Rails-DEFAULT FALSE (we never set it), and it is
#     what governs RAKE tasks. `rails test` / `rake test` / CI's
#     `db:test:prepare test` lane are ALL rake tasks, so they run with eager
#     loading OFF **even when CI=true** — routes stay lazy. (Measured: `rails
#     runner` under CI => routes_loaded true; the rake test lane => lazy, which is
#     exactly how the dev_board pollution reached CI.)
# The dev-only namespace in config/routes.rb draws ONLY when Rails.env.local?. So a
# test that resolved a `dev_board_*` helper for the FIRST
# time inside a `Rails.stub(:env, "production")` block used to draw the WHOLE set
# with local? => false, silently dropping the dev namespace for the rest of that
# worker — every later test then died with `undefined method dev_board_generate_path`.
# Forcing the first draw here, un-stubbed, means no later env stub can ever be it.
# See test/controllers/dev/board_controller_test.rb (task fix-dev-board-route-pollution).
Rails.application.reload_routes_unless_loaded
# minitest/mock (Object#stub + Minitest::Mock) isn't auto-required by rails/test_help;
# the pinned minitest ~> 5.25 keeps it available (6.0 dropped it — see Gemfile), so
# make it loadable suite-wide for tests that stub a seam (e.g. the LLM adapter).
require "minitest/mock"

# SessionEnv — the child-env neutralizer for any test that SPAWNS a subprocess.
# A live agent session exports CLAUDE_CODE_SESSION_ID / CODEX_THREAD_ID and the
# child would inherit it, resolving the OPERATOR'S session where CI resolves none
# (see test/support/session_env.rb, and docs/agents/modules/testing.md). Required
# here for the Rails-side tests; the standalone test/lib and test/commands files
# are bare minitest/autorun and `require_relative "../support/session_env"`
# themselves — so this require is NOT the whole fix, and must not become it.
require_relative "support/session_env"

# TestDatabasePurge — start from an EMPTY database, then let fixtures load.
#
# Rails truncates only the tables it has fixtures for (~28 of this schema's ~73),
# so rows any OTHER process committed to the test DB survive into our tests. The
# e2e lane does exactly that: playwright.config.js's webServer runs e2e/seed.rb
# against this same database under RAILS_ENV=test, and its un-fixtured rows
# (pokemons, releases, task_events, …) then break unrelated minitest tests. Purge
# first and the whole class of pollution — e2e seed, stray `rails runner`, a
# killed test that committed — cannot reach a test. See test/support/test_database_purge.rb
# and the standing invariant in test/integration/test_database_hermeticity_test.rb.
require_relative "support/test_database_purge"
TestDatabasePurge.purge!

# TestDatabaseLeakGuard — keep it empty DURING the run, and NAME the test that
# dirtied it. The boot purge above is a starting condition, not an invariant: a
# test whose writes are never rolled back (use_transactional_tests = false, or a
# subprocess committing to this same DB) leaves rows behind mid-run, and the
# innocent test that runs next is the one that goes red — non-deterministically,
# since minitest shuffles the runnable classes. This checks the same invariant
# after EVERY test, once Rails has rolled that test's transaction back, and fails
# the test that actually did it. See test/support/test_database_leak_guard.rb.
#
# Two hooks, on purpose: ActiveSupport::TestCase sits AHEAD of
# ActiveRecord::TestFixtures in the ancestor chain, so RailsHook's `super` returns
# only after the rollback; Minitest::Test catches the bare test/lib + test/commands
# files that never inherit from it (they skip the Rails hook to avoid a double check).
require_relative "support/test_database_leak_guard"
ActiveSupport::TestCase.prepend(TestDatabaseLeakGuard::RailsHook)
Minitest::Test.prepend(TestDatabaseLeakGuard::BareHook)

# CertDatabaseReaper — sweep the per-run cert test databases a hard-killed prior
# run stranded. The DB-provisioning probe (test/commands/agent_worktree_test.rb)
# mints a UNIQUE Postgres DB per run and drops it in an `ensure`; a SIGKILL runs no
# `ensure` and leaks it. Every suite boot is the periodic sweep: it drops only the
# databases whose leasing run is provably gone (see the reaper). Best-effort and
# once, in the main process only (never per parallel worker) — a DB blip here must
# never fail the suite.
require_relative "support/cert_database_reaper"
begin
  CertDatabaseReaper.reap!
rescue StandardError => e
  warn "cert-db reaper (non-fatal): #{e.class}: #{e.message}"
end

OmniAuth.config.test_mode = true

# How many test workers to fork. Parallel workers fork-clone the test DB
# (CREATE DATABASE … TEMPLATE), which races the base connection and segfaults
# LOCALLY (pg fork-safety) — and the killed run leaks orphan workers that hold the
# test DB and hang the next one. So default to SINGLE-PROCESS locally; CI keeps the
# parallel speedup. See the matching rationale in bin/agent-worktree#run_worktree_tests.
#
# MEASURED, 2026-08-18 (/tasks/measure-local-parallel-workers) — this is no longer a
# remembered warning, and the numbers matter because they explain a false negative
# that nearly got the default changed:
#
#   FULL suite, PARALLEL_WORKERS=4, quiet machine, 2 of 2 trials:
#     "Running 6666 tests in parallel using 4 processes"
#     pg/connection.rb:944: [BUG] Segmentation fault  ×4 workers, BEFORE ANY TEST RAN
#   test/models ALONE, PARALLEL_WORKERS=4, 2 of 2 trials: 1908 runs, 0 failures, clean.
#
# So a partial run is NOT evidence that parallel is safe here — it is the shape that
# hides the bug. Anyone re-testing this must run the WHOLE suite; measuring one
# directory reproduces nothing and reads as a green light.
#
# THE GUARD BELOW EXISTS BECAUSE THE FAILURE IS ILLEGIBLE. Setting PARALLEL_WORKERS>1
# locally does not fail as a test — it dumps four Ruby crash reports, leaves orphan
# workers reparented to launchd still holding the test DB, and wedges the NEXT run in
# test-prepare on PG::ObjectInUse. The agent who set it sees a crash dump, not a cause.
# So a local request for >1 is CLAMPED to 1 and says why, turning an inscrutable
# segfault into one line of explanation. It clamps rather than aborts because the
# suite the agent asked for still runs — just serially — which is the outcome they
# actually wanted.
#
# PARALLEL_WORKERS_ALLOW_UNSAFE=1 restores the requested count, for exactly one
# purpose: re-running the measurement above when Ruby, the pg gem, or macOS moves.
# It is not a performance switch. If it stops crashing, change the DEFAULT on the
# evidence and delete this guard — do not leave the hatch as the way in.
module TestParallelism
  UNSAFE_OVERRIDE = "PARALLEL_WORKERS_ALLOW_UNSAFE"

  def self.worker_count(env = ENV)
    requested = env["PARALLEL_WORKERS"].to_s
    return default_for(env) unless requested.match?(/\A\d+\z/)

    count = Integer(requested)
    return count if count <= 1 || env["CI"].present? || env[UNSAFE_OVERRIDE].to_s == "1"

    warn <<~REASON
      [test_helper] PARALLEL_WORKERS=#{count} ignored locally — running SINGLE-PROCESS instead.
        Forking the full suite here SEGFAULTS in pg (pg/connection.rb, at the fork,
        before any test runs) and strands orphan workers holding the test DB, which
        then wedges the next run on PG::ObjectInUse. Measured 2 of 2 trials, 2026-08-18.
        This is an ENV limitation, NOT a problem with your diff.
        Re-measuring after a Ruby/pg/macOS bump? #{UNSAFE_OVERRIDE}=1 restores #{count}.
    REASON
    1
  end

  def self.default_for(env)
    env["CI"].present? ? :number_of_processors : 1
  end
end

# NORMALIZE THE ENV, NOT JUST THE ARGUMENT — the clamp above is decorative without
# this, and it was: measured, a run with PARALLEL_WORKERS=4 printed the warning AND
# THEN "Running 193 tests in parallel using 4 processes". Rails' own `parallelize`
# re-reads the variable and that read WINS — ENV is the FIRST branch of its case,
# ahead of the `workers:` argument entirely (active_support/test_case.rb):
#
#     case
#     when ENV["PARALLEL_WORKERS"] then workers = ENV["PARALLEL_WORKERS"].to_i
#     when workers == :number_of_processors then ...
#
# So the resolved count is written BACK to the env before parallelize reads it. Left
# alone on the CI path, where the value is `:number_of_processors` and forking is fine.
TEST_WORKERS = TestParallelism.worker_count
ENV["PARALLEL_WORKERS"] = TEST_WORKERS.to_s if TEST_WORKERS.is_a?(Integer)

module ActiveSupport
  class TestCase
    # Single-process locally (reliable), parallel in CI (fast) — see TestParallelism.
    parallelize(workers: TEST_WORKERS)

    # CI forks a worker per processor, each onto its OWN cloned database — which the
    # load-time purge above (base DB, parent process) never touches. Purge inside each
    # worker too, so the "starts empty" guarantee holds in every process that runs a
    # test, not just the single-process local path. No-op when workers <= 1.
    parallelize_setup { TestDatabasePurge.purge! }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # Pin one ENV key for the duration of the block, restoring the original
    # value (or its absence) on the way out. Safe under CI's process-per-worker
    # parallelism: each worker owns its ENV and runs its tests sequentially.
    def with_env(key, value)
      original = ENV[key]
      value.nil? ? ENV.delete(key) : ENV[key] = value
      yield
    ensure
      original.nil? ? ENV.delete(key) : ENV[key] = original
    end
  end
end

class ActionDispatch::IntegrationTest
  # Passwordless: mint + consume a magic-link token (create-or-login). The user
  # must have an email. The token is a Studio::Link row consumed at /l/<token>
  # — the same door a real visitor comes through, and the only one the engine
  # still draws.
  def log_in_as(user)
    token = Studio::Link.create_magic_link(email: user.email).token
    post link_consume_path(token: token)
  end
end

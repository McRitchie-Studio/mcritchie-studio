ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
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

OmniAuth.config.test_mode = true

# How many test workers to fork. Parallel workers fork-clone the test DB
# (CREATE DATABASE … TEMPLATE), which races the base connection and intermittently
# DEADLOCKS or segfaults LOCALLY (pg fork-safety) — and a killed parallel run leaks
# orphan workers that hold the test DB and hang the next run. So default to
# SINGLE-PROCESS locally; CI keeps the parallel speedup, and PARALLEL_WORKERS
# overrides either way (e.g. bin/agent-worktree pins it to 1). See the matching
# rationale in bin/agent-worktree#run_worktree_tests.
module TestParallelism
  def self.worker_count(env = ENV)
    return Integer(env["PARALLEL_WORKERS"]) if env["PARALLEL_WORKERS"].to_s.match?(/\A\d+\z/)

    env["CI"].present? ? :number_of_processors : 1
  end
end

module ActiveSupport
  class TestCase
    # Single-process locally (reliable), parallel in CI (fast) — see TestParallelism.
    parallelize(workers: TestParallelism.worker_count)

    # CI forks a worker per processor, each onto its OWN cloned database — which the
    # load-time purge above (base DB, parent process) never touches. Purge inside each
    # worker too, so the "starts empty" guarantee holds in every process that runs a
    # test, not just the single-process local path. No-op when workers <= 1.
    parallelize_setup { TestDatabasePurge.purge! }

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  # Passwordless: mint + consume a magic-link token (create-or-login). The user
  # must have an email. In test the cache is :null_store, so MagicLink skips
  # single-use enforcement and the token consumes cleanly.
  def log_in_as(user)
    token = MagicLink.generate(email: user.email)
    post magic_link_consume_path(token: token)
  end
end

# frozen_string_literal: true

# Config-contract test for web/worker concurrency vs. the board Postgres.
#
# From the 2026-08-09 H12 outage: production ran one Basic dyno with no Puma
# `workers` line and 3 threads — 3 TOTAL concurrency — and a request swarm
# queued the entire site (2,293 H12s in 2m47s). The fix raises WEB_CONCURRENCY,
# but the board Postgres is Heroku essential-0 with a HARD 20-connection limit
# shared by web (workers x threads), the Solid Queue dyno (bin/jobs), and agent
# CLI/console sessions. This test parses the REAL config files (config/puma.rb,
# config/database.yml, config/queue.yml, config/recurring.yml), re-derives the
# worst-case connection budget documented beside the `workers` line in
# config/puma.rb, and fails if it ever reaches the ceiling.
#
# Standalone (no Rails env). Run directly:
#   bundle exec ruby -Itest test/lib/puma_config_contract_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "puma"
require "puma/configuration"
require "yaml"
require "erb"

class PumaConfigContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  PUMA_RB = File.join(ROOT, "config/puma.rb")
  DATABASE_YML = File.join(ROOT, "config/database.yml")
  QUEUE_YML = File.join(ROOT, "config/queue.yml")
  RECURRING_YML = File.join(ROOT, "config/recurring.yml")

  # The prod board Postgres (Heroku essential-0) hard connection limit.
  PG_CONNECTION_LIMIT = 20

  # Headroom the budget must leave for direct-DB agent sessions (`heroku run`
  # consoles, bin/release gates) — the session concurrency cap is 5.
  CLI_SESSIONS = 5

  # Every env var config/puma.rb and database.yml read; the loader clears them
  # so the test sees the file DEFAULTS, not this shell's worktree exports.
  CONFIG_ENV_KEYS = %w[
    RAILS_ENV WEB_CONCURRENCY RAILS_MAX_THREADS JOB_CONCURRENCY PORT PIDFILE
  ].freeze

  # --- puma.rb parses, env-driven -------------------------------------------

  def test_production_defaults_to_two_workers_three_threads
    options = load_puma_options("RAILS_ENV" => "production")

    assert_equal 2, options[:workers], "production must default WEB_CONCURRENCY to 2"
    assert_equal 3, Integer(options[:max_threads]), "threads must default to 3"
    assert_operator options[:workers] * Integer(options[:max_threads]), :>, 3,
      "total web concurrency must exceed the outage's 3"
  end

  def test_production_reads_worker_and_thread_env
    options = load_puma_options(
      "RAILS_ENV" => "production", "WEB_CONCURRENCY" => "3", "RAILS_MAX_THREADS" => "2"
    )

    assert_equal 3, options[:workers]
    assert_equal 2, Integer(options[:max_threads])
  end

  def test_development_stays_single_process
    options = load_puma_options

    assert_equal 0, options[:workers],
      "dev/worktree stacks must stay single-process (workers gate is production-only)"
  end

  # --- the connection budget -------------------------------------------------

  def test_worst_case_connection_budget_stays_under_ceiling
    options = load_puma_options("RAILS_ENV" => "production")
    web = options[:workers] * Integer(options[:max_threads])

    budget = web + solid_queue_worst_case + CLI_SESSIONS
    assert_operator budget, :<, PG_CONNECTION_LIMIT, <<~MSG
      Worst-case connection budget #{budget} (web #{web} + jobs \
      #{solid_queue_worst_case} + #{CLI_SESSIONS} CLI sessions) reaches the \
      essential-0 limit of #{PG_CONNECTION_LIMIT}. Shrink WEB_CONCURRENCY, \
      RAILS_MAX_THREADS, or config/queue.yml — and update the math beside the \
      `workers` line in config/puma.rb.
    MSG
  end

  def test_database_pool_follows_rails_max_threads_and_covers_both_dynos
    with_env do
      pool = database_pool_default
      puma_threads = Integer(load_puma_options("RAILS_ENV" => "production")[:max_threads])

      assert_equal 5, pool, "database.yml pool fallback must stay 5 (see its comment)"
      assert_operator pool, :>=, puma_threads,
        "AR pool must cover every Puma request thread"
      assert_operator pool, :>=, queue_worker_threads + 1,
        "AR pool must cover Solid Queue job threads + poller in ONE process"
    end
  end

  def test_database_pool_reads_rails_max_threads
    with_env("RAILS_MAX_THREADS" => "4") do
      assert_equal 4, database_pool_default
    end
  end

  private

  # Evaluates the real config/puma.rb through Puma's own loader with a
  # controlled env (unset keys removed, overrides applied), restoring the
  # ambient env afterwards. The suite runs single-process serial, so the
  # temporary ENV mutation cannot bleed into a parallel test.
  def load_puma_options(overrides = {})
    with_env(overrides) do
      config = Puma::Configuration.new(config_files: [PUMA_RB])
      config.load
      config.clamp
      config.options
    end
  end

  def with_env(overrides = {})
    saved = CONFIG_ENV_KEYS.to_h { |key| [key, ENV[key]] }
    CONFIG_ENV_KEYS.each { |key| ENV.delete(key) }
    overrides.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # Worst-case connections the Solid Queue dyno demands, derived from
  # config/queue.yml's production section at default env:
  #   each worker process: job threads + 1 polling thread
  #   + 1 per dispatcher, + 1 scheduler (recurring.yml non-empty), + supervisor
  def solid_queue_worst_case
    config = queue_production_config
    workers = config.fetch("workers")
    worker_conns = workers.sum do |worker|
      processes = Integer(worker.fetch("processes", 1))
      processes * (Integer(worker.fetch("threads")) + 1)
    end
    dispatchers = config.fetch("dispatchers").size
    scheduler = recurring_production_tasks.any? ? 1 : 0
    supervisor = 1

    worker_conns + dispatchers + scheduler + supervisor
  end

  def queue_worker_threads
    queue_production_config.fetch("workers").map { |worker| Integer(worker.fetch("threads")) }.max
  end

  def queue_production_config
    with_env { load_yaml_with_erb(QUEUE_YML).fetch("production") }
  end

  def recurring_production_tasks
    load_yaml_with_erb(RECURRING_YML).fetch("production", {}) || {}
  end

  def database_pool_default
    Integer(load_yaml_with_erb(DATABASE_YML).fetch("default").fetch("pool"))
  end

  def load_yaml_with_erb(path)
    YAML.safe_load(ERB.new(File.read(path)).result, aliases: true)
  end
end

require "test_helper"
require "open3"
require "securerandom"

# Desk teardown returned the desk's Redis capacity and NONE of its Postgres.
# Measured 2026-08-26: 516 per-worktree databases on the local cluster (~11.7 GB),
# one for every desk ever removed. `teardown_worktree` flushed Redis, wrote the
# ledger row, removed the git worktree and deleted the branch — and never dropped
# the database it had provisioned.
#
# WHY THESE TESTS USE REAL DATABASES. The thing under test is a DROP, and the only
# failure that matters is dropping the wrong one. A stub that records "drop was
# called" would pass against code that drops the shared development database, so
# these mint throwaway databases and assert on the cluster afterwards.
#
# SAFETY DOCTRINE, inherited from test/support/cert_database_reaper.rb: a pattern is
# not an identity, and every uncertain answer must resolve toward "alive". The
# teardown drop derives its names from the desk's OWN registry record rather than
# sweeping a pattern, refuses on any unreadable answer, and re-proves the structural
# shape before acting — that last guard is what keeps `<app>_development` (the shared
# database an earlier cut at a related sweep once bricked a release with) out of reach.
class DeskDatabaseTeardownTest < ActiveSupport::TestCase
  def setup
    skip "postgres not running" unless system("pg_isready", "-q", out: File::NULL, err: File::NULL)
    @suffix = SecureRandom.hex(4)
    @dev = "awtteardown_development_probe#{@suffix}"
    @shard = "#{@dev}-0"
    @test_db = "awtteardown_test_probe#{@suffix}"
    @created = []
  end

  def teardown
    # Never leave litter behind in a test about litter.
    @created.each do |db|
      system("psql", "-Atqc", "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '#{db}'",
             "postgres", out: File::NULL, err: File::NULL)
      system("psql", "-Atqc", %(DROP DATABASE IF EXISTS "#{db}"), "postgres", out: File::NULL, err: File::NULL)
    end
  end

  def create_db(name)
    system("psql", "-Atqc", %(CREATE DATABASE "#{name}"), "postgres", out: File::NULL, err: File::NULL)
    @created << name
    name
  end

  def exists?(name)
    out, = Open3.capture2("psql", "-Atqc",
                          "SELECT 1 FROM pg_database WHERE datname = '#{name}'", "postgres")
    out.strip == "1"
  end

  # Load the script's helpers without dispatching its CLI.
  def script
    @script ||= begin
      src = File.read(Rails.root.join("bin/agent-worktree")).sub(/^\s*main\b.*$/, "")
      # instance_eval on a bare object turns the script's top-level `def`s into
      # SINGLETON methods on that object, so the helpers are callable without
      # dispatching the CLI and without leaking definitions into the test process.
      host = Object.new
      host.instance_eval(src, "bin/agent-worktree")
      host
    end
  end

  test "teardown drops the desk database, its test sibling and its parallel shards" do
    create_db(@dev)
    create_db(@shard)
    create_db(@test_db)

    script.drop_desk_databases({ db_name: @dev })

    refute exists?(@dev),     "the desk's development database survived teardown"
    refute exists?(@shard),   "a parallel-test shard survived — those were 84 of the orphans measured"
    refute exists?(@test_db), "the _test_ sibling survived; test_database_url mints it from the same slug"
  end

  test "teardown refuses the drop while a connection is open" do
    create_db(@dev)
    holder = IO.popen(["psql", "-Atq", "-c", "SELECT pg_sleep(20)", @dev], err: File::NULL)
    begin
      sleep 1.5
      assert_operator script.database_connection_count(@dev), :>, 0, "probe failed to hold a connection open"

      _out, err = capture_io { script.drop_desk_databases({ db_name: @dev }) }

      # ASSERT ON THE REFUSAL, NOT ON SURVIVAL. Postgres declines to drop a database
      # that has an open connection, so `assert exists?` passes even with our check
      # deleted — it pins Postgres's behaviour, not ours. Mutation-proven: removing
      # the `live.positive?` branch left that version of this test GREEN. What must
      # bite is that we DECLINE DELIBERATELY and say so, before ever issuing a DROP.
      assert_match(/open connection\(s\); left it in place/, err,
                   "teardown must refuse deliberately on a live connection and announce it; " \
                   "relying on Postgres to refuse for us is not a guard we control")
      assert exists?(@dev), "the database must still be there afterwards"
    ensure
      Process.kill("TERM", holder.pid)
      holder.close
    end
  end

  # THE GUARD THAT MATTERS MOST. A malformed or empty record must never reach the
  # shared development database. This is a positive structural invariant, not a
  # blacklist: the name must be `<app>_development_<non-empty slug>`.
  test "a malformed record can never name the shared development database" do
    assert_empty script.desk_database_names({ db_name: "mcritchie_studio_development" }),
                 "the SHARED development database was treated as a desk database"
    assert_empty script.desk_database_names({ db_name: "mcritchie_studio_development_" }),
                 "an empty slug must be refused, not expanded"
    assert_empty script.desk_database_names({ db_name: "" }),
                 "an empty record must be refused"
  end

  # My first cut asserted that a NON-EXISTENT database name returns nil. It does
  # not, and the code is right: that query succeeds and legitimately counts zero
  # backends. `nil` means the QUESTION COULD NOT BE ANSWERED (psql failed, cluster
  # unreachable) — a different thing entirely. What actually needs pinning is that
  # an unanswerable question is treated as ALIVE and skips the drop, so that is
  # what this asserts, by making the count unanswerable.
  test "a name with no backends reports zero, not nil" do
    create_db(@dev)
    assert_equal 0, script.database_connection_count(@dev),
                 "a reachable database with no clients has zero connections, not an unknown count"
  end

  test "an unanswerable connection count is treated as alive and skips the drop" do
    create_db(@dev)
    # Force the "cannot answer" branch the same way a downed cluster would.
    def script.database_connection_count(_name) = nil

    script.drop_desk_databases({ db_name: @dev })

    assert exists?(@dev),
           "the drop proceeded on an unanswerable connection count — absence of signal " \
           "must never read as permission to drop"
  end
end

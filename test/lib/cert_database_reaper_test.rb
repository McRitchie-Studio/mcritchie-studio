# frozen_string_literal: true

# Unit tests for CertDatabaseReaper — no Rails, no Postgres. The guard predicate is
# pure, and reap!'s liveness and drop are injected, so the three acceptance
# behaviours are proven against a synthetic lease directory:
#
#   AC1  reap drops a leased database whose owner is gone.
#   AC2  reap SKIPS a leased database whose owner is alive.
#   AC3  the guard admits ONLY a derived per-run test DB — above all it refuses
#        mcritchie_studio_development, even when a lease names it.
#
# Run directly:  ruby -Itest test/lib/cert_database_reaper_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../test/support/cert_database_reaper"

class CertDatabaseReaperTest < Minitest::Test
  BASE = "mcritchie_studio_test"

  def setup
    @dir = Dir.mktmpdir("cert-db-leases")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- AC3: the closed-set guard -----------------------------------------------

  # The positive invariant, stated once: an admissible name sits in the app's TEST
  # namespace (base + "_" separator) AND carries the per-run 8-hex digest suffix.
  def test_admits_a_per_run_test_database
    assert CertDatabaseReaper.admissible?("mcritchie_studio_test_overflowprobe_deadbeef", base: BASE)
    assert CertDatabaseReaper.admissible?("mcritchie_studio_test_a_00000000", base: BASE)
    # a realistic 63-byte overflow name (bounded slug + digest)
    assert CertDatabaseReaper.admissible?("mcritchie_studio_test_regression_very_long_worktree_1a2b3c4d", base: BASE)
  end

  # The whole reason this guard exists: never, ever the shared development database —
  # its first cut once bricked every release. This is the catastrophic vector.
  def test_refuses_the_development_database
    refute CertDatabaseReaper.admissible?("mcritchie_studio_development", base: BASE)
  end

  # The vector I would MISS if I guarded on the digest suffix alone: dev DB WITH a
  # hex suffix. It has the per-run shape but is NOT in the test namespace — the
  # anchor is the namespace, not the suffix.
  def test_refuses_a_development_lookalike_that_carries_the_digest_suffix
    refute CertDatabaseReaper.admissible?("mcritchie_studio_development_deadbeef", base: BASE)
  end

  # Every legitimate NON-ephemeral member of the test namespace falls outside the
  # positive invariant — proven, not blacklisted. (Names mirror the closed set
  # test_database_purge.rb's derived_from? admits: base, parallel clones, and the
  # release GATE/SHIP workspaces.)
  def test_refuses_the_protected_non_ephemeral_test_databases
    [
      "mcritchie_studio_test",              # the base itself (no per-run suffix)
      "mcritchie_studio_test-0",            # a parallel-test clone of the base
      "mcritchie_studio_gate_test",         # bin/release.rb GATE workspace
      "mcritchie_studio_ship_test",         # bin/release.rb SHIP workspace
      "mcritchie_studio_gate_test-0",       # a parallel-test clone of a workspace
      "mcritchie_studio_test_terminal_context", # a short-slug worktree DB (no digest)
    ].each do |name|
      refute CertDatabaseReaper.admissible?(name, base: BASE), "must refuse #{name.inspect}"
    end
  end

  # Look-alikes and mutation vectors: no `_test_` boundary, a substring rather than
  # a prefix, and off-by-one digest lengths (7 and 9 hex). Refusing all of these is
  # the SAFE direction (a leaked DB, never a wrongful drop).
  def test_refuses_lookalikes_and_off_by_one_digests
    [
      "mcritchie_studio_testing_dev",                 # no "_test_" boundary
      "x_mcritchie_studio_test_foo_deadbeef",         # base is a substring, not a prefix
      "mcritchie_studio_test_foo_deadbee",            # 7 hex — too short
      "mcritchie_studio_test_foo_deadbeef1",          # 9 trailing chars — not a clean _<8hex>
      "mcritchie_studio_test_foo_DEADBEEF",           # uppercase — our digests are lowercase
      "mcritchie_studio_test_",                       # empty slug
      "",
    ].each do |name|
      refute CertDatabaseReaper.admissible?(name, base: BASE), "must refuse #{name.inspect}"
    end
  end

  def test_admissible_needs_a_base
    refute CertDatabaseReaper.admissible?("mcritchie_studio_test_x_deadbeef", base: "")
  end

  # --- AC1 / AC2: reap! behaviour with injected liveness + drop -----------------

  def test_reaps_a_dead_owners_database
    CertDatabaseReaper.register("mcritchie_studio_test_x_deadbeef", dir: @dir, pid: 4242)
    dropped = []

    result = CertDatabaseReaper.reap!(dir: @dir, base: BASE,
                                      alive: ->(_pid) { false },
                                      drop: ->(name) { dropped << name })

    assert_equal ["mcritchie_studio_test_x_deadbeef"], dropped
    assert_equal ["mcritchie_studio_test_x_deadbeef"], result[:reaped]
    assert_empty lease_files, "the lease must be forgotten once its database is dropped"
  end

  def test_skips_a_live_owners_database
    CertDatabaseReaper.register("mcritchie_studio_test_x_deadbeef", dir: @dir, pid: 4242)
    dropped = []

    result = CertDatabaseReaper.reap!(dir: @dir, base: BASE,
                                      alive: ->(_pid) { true },
                                      drop: ->(name) { dropped << name })

    assert_empty dropped, "a live run's database must never be dropped"
    assert_equal ["mcritchie_studio_test_x_deadbeef"], result[:skipped]
    refute_empty lease_files, "a skipped lease must be KEPT so a later sweep can reconsider it"
  end

  # Defense in depth: even a lease that names the development database — corruption,
  # or a hostile write — cannot make the reaper drop it. Owner "dead", name refused.
  def test_a_dead_owner_lease_naming_the_dev_db_is_refused_not_dropped
    CertDatabaseReaper.register("mcritchie_studio_development", dir: @dir, pid: 4242)
    dropped = []

    result = CertDatabaseReaper.reap!(dir: @dir, base: BASE,
                                      alive: ->(_pid) { false },
                                      drop: ->(name) { dropped << name })

    assert_empty dropped, "the guard must refuse to drop mcritchie_studio_development"
    assert_equal ["mcritchie_studio_development"], result[:refused]
    refute_empty lease_files, "a refused lease is left in place to be named, not silently erased"
  end

  def test_a_malformed_pid_lease_is_refused_not_guessed
    File.write(File.join(@dir, "mcritchie_studio_test_x_deadbeef.json"),
               JSON.generate("db" => "mcritchie_studio_test_x_deadbeef", "pid" => "garbage"))
    dropped = []

    result = CertDatabaseReaper.reap!(dir: @dir, base: BASE,
                                      alive: ->(_pid) { false },
                                      drop: ->(name) { dropped << name })

    assert_empty dropped
    assert_equal ["mcritchie_studio_test_x_deadbeef"], result[:refused]
  end

  def test_reaps_the_dead_and_keeps_the_live_in_one_sweep
    CertDatabaseReaper.register("mcritchie_studio_test_dead_aaaaaaaa", dir: @dir, pid: 1)
    CertDatabaseReaper.register("mcritchie_studio_test_live_bbbbbbbb", dir: @dir, pid: 2)
    dropped = []

    result = CertDatabaseReaper.reap!(
      dir: @dir, base: BASE,
      alive: ->(pid) { pid == 2 }, # only pid 2 is alive
      drop: ->(name) { dropped << name }
    )

    assert_equal ["mcritchie_studio_test_dead_aaaaaaaa"], dropped
    assert_equal ["mcritchie_studio_test_dead_aaaaaaaa"], result[:reaped]
    assert_equal ["mcritchie_studio_test_live_bbbbbbbb"], result[:skipped]
  end

  # --- process_alive?: the real liveness primitive -----------------------------

  def test_process_alive_sees_this_process
    assert CertDatabaseReaper.process_alive?(Process.pid)
  end

  def test_process_alive_sees_a_reaped_child_as_dead
    pid = fork { exit! }
    Process.wait(pid) # reap the zombie so the pid is truly gone
    refute CertDatabaseReaper.process_alive?(pid)
  end

  # Absence of signal is never a drop: an unparseable pid resolves toward alive.
  def test_process_alive_treats_an_unknown_pid_as_alive
    assert CertDatabaseReaper.process_alive?(nil)
    assert CertDatabaseReaper.process_alive?("not-a-pid")
  end

  private

  def lease_files
    Dir.glob(File.join(@dir, "*.json"))
  end
end

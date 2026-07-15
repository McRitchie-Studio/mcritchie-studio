# frozen_string_literal: true

# Integration tests for CertProcess — THE PREVENT HALF, which had NO COVERAGE AT ALL.
# (`grep -rn with_traps test/` → nothing. The trap handler that runs while a cert is dying
# under a harness timeout was the single least-tested line in the guard, and it held a bug
# strictly worse than the one this PR exists to fix.)
#
# What it was doing: the trap and the ensure block DISCARDED `reap_group`'s return, cleared
# the runlock UNCONDITIONALLY, and announced "reaped the suite's process group N (no orphan
# left behind)" — a reap it may never have performed. `reap_group` does not signal at all
# when it cannot prove the group is ours (a recycled pgid, or a nil `started_at` because the
# `ps` at spawn returned nothing). So on that path the cert:
#
#   1. refused to kill the orphan (correctly — it could not prove it was ours), then
#   2. DELETED the only record naming it, then
#   3. told the operator there was no orphan.
#
# The next cert's runlock preflight then grades `:none` — the entire DETECT half never runs.
# A DETECTABLE orphan becomes an UNNAMEABLE one. That is why the lock now survives exactly
# when the group does, and why `reap_group` returns a TRI-STATE rather than a boolean: its
# old `false` conflated "already gone, nothing to reap" with "alive, and I refused", whose
# remediations are opposites. Clear the lock on the first; KEEP it on the second.
#
# These spawn REAL cert lanes and send them REAL signals, because the claim under test is
# about what the code DOES as it dies — not what it reasons about a synthetic table.
#
# Run directly:  ruby -Itest test/lib/cert_process_test.rb

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/cert_orphan_guard"
require_relative "../../bin/lib/cert_process"

class CertProcessTest < Minitest::Test
  LANE = "spine"

  def setup
    @root = Dir.mktmpdir("cert-process")
    system("git", "-C", @root, "init", "-q", out: File::NULL, err: File::NULL)
    @spawned = []
  end

  def teardown
    @spawned.each do |pid|
      Process.kill("KILL", pid)
    rescue Errno::ESRCH
      nil
    end
    FileUtils.rm_rf(@root)
  end

  def lock = CertOrphanGuard.lock_path(@root)

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  # A `ps` that sees the process table but CANNOT answer `-o lstart=` for a single pid.
  #
  # This is the `started_at: nil` vector, driven for real: the lock records NO identity for a
  # group that is genuinely alive, so `identity_of` grades :unprovable and the reaper must
  # REFUSE. It is only testable because `CertProcess` now threads `ps:` through the two
  # `process_started_at` calls that RECORD identity — they used to hardcode the default `ps`,
  # ignoring the CERT_GUARD_PS seam the rest of the guard honours, which is exactly why this
  # file could not exist. You cannot test a reap you cannot make fail.
  def blind_lstart_ps
    path = File.join(@root, "blind-ps")
    File.write(path, <<~SH)
      #!/bin/bash
      case "$*" in
        *-Ao*) exec /bin/ps "$@" ;;
        *)     exit 0 ;;
      esac
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  # Where the child cert's stderr goes, so we can read back what it TOLD the operator as it
  # died. The warning line is the artefact under test as much as the runlock is.
  def stderr_log = File.join(@root, "cert.err")

  def warning = File.exist?(stderr_log) ? File.read(stderr_log) : ""

  # Run a cert lane in a child process, so we can signal it exactly as a harness timeout does.
  # Returns [child_pid, suite_pid] once the lane is up and the runlock is on disk.
  def spawn_cert(ps: "ps", cmd: "sleep 300")
    script = <<~RB
      $LOAD_PATH.unshift #{File.expand_path("bin/lib", Dir.pwd).inspect}
      require "cert_orphan_guard"
      require "cert_process"
      CertProcess.run({}, #{cmd.inspect}, chdir: #{@root.inspect}, root: #{@root.inspect},
                      lane: #{LANE.inspect}, db: "studio_test_x", ps: #{ps.inspect})
    RB
    child = Process.spawn("ruby", "-e", script, err: stderr_log)
    @spawned << child

    deadline = Time.now + 10
    sleep 0.05 while !File.exist?(lock) && Time.now < deadline
    assert_path_exists lock, "the cert writes its runlock while the lane runs"

    suite = CertOrphanGuard.read_lock(@root)["pgid"]
    @spawned << suite
    [child, suite]
  end

  def wait_until_dead(pid, timeout: 8.0)
    deadline = Time.now + timeout
    sleep 0.05 while alive?(pid) && Time.now < deadline
    !alive?(pid)
  end

  # --- [integration] the CLEAN cert: the tri-state must not strand a stale lock -----------

  def test_a_clean_cert_clears_its_runlock
    # THE TRAP IN THE FIX. A clean lane's group is ALREADY GONE by the time `ensure` runs —
    # `reap_group` reaps nothing and returns `:absent`. That is NOT a refusal. Gate the
    # clear_lock naively on "did we reap?" and EVERY successful cert leaves a stale lock
    # behind, and the next cert refuses against a ghost. This is why `false` had to become
    # three states rather than being inverted.
    assert CertProcess.run({}, "true", chdir: @root, root: @root, lane: LANE, db: "studio_test_x"),
           "a lane that exits 0 succeeds"
    refute_path_exists lock,
                       "a CLEAN cert must leave NO runlock — :absent means nothing to reap, not a refusal"
  end

  def test_a_failing_lane_still_clears_its_runlock
    refute CertProcess.run({}, "false", chdir: @root, root: @root, lane: LANE, db: "studio_test_x")
    refute_path_exists lock, "a red cert is not an orphaned cert — the lock still goes"
  end

  # --- [integration] SIGTERM with a REAPABLE suite: reap it, clear the lock, say so -------

  def test_sigterm_reaps_the_suite_and_clears_the_lock
    child, suite = spawn_cert

    Process.kill("TERM", child)
    Process.waitpid(child)

    assert wait_until_dead(suite),
           "the suite must die with its cert — an orphan holding the test DB is the whole bug"
    refute_path_exists lock, "we reaped it, so the lock has nothing left to name"
    assert_match(/no orphan left behind/i, warning,
                 "the POSITIVE half: when the reap DID happen, say so — a guard that never claims a " \
                 "reap is as useless as one that always does")
  end

  # --- [integration] SIGTERM with a REFUSED reap: KEEP the lock, claim NOTHING -------------

  def test_a_refused_reap_keeps_the_runlock_and_does_not_claim_a_reap
    # Shannon's live reproduction, permanently. The reap is refused (identity :unprovable —
    # the `ps` at spawn recorded no start time), so the guard correctly never signals. What
    # it must NOT do is delete the evidence and declare victory.
    child, suite = spawn_cert(ps: blind_lstart_ps)

    assert_nil CertOrphanGuard.read_lock(@root)["pgid_started_at"],
               "the vector: a runlock carrying NO identity for its group"

    Process.kill("TERM", child)
    Process.waitpid(child)

    assert alive?(suite), "the vector requires a suite that OUTLIVES the cert — otherwise nothing is at stake"
    assert_path_exists lock,
                       "THE BLOCKING BUG: the cert deleted the ONLY record naming an orphan it had just " \
                       "REFUSED to kill. The next cert's preflight then grades :none, the DETECT half never " \
                       "runs, and a detectable orphan becomes an unnameable one."
    refute_match(/no orphan left behind/i, warning, "NEVER claim a reap that did not happen")

    # And the payoff: because the lock survived, the NEXT cert still NAMES the orphan.
    verdict, message = CertOrphanGuard.preflight(root: @root,
                                                 env: { "CERT_GUARD_PSQL" => "/nonexistent/psql" })
    assert_equal :refuse, verdict, "the next cert must not walk into the orphan it can see"
    assert_match(/#{suite}/, message, "and it must NAME it — that is what the lock was kept for")
  end

  # --- [unit] the report never announces a reap it did not perform ------------------------

  def test_reap_report_tells_the_truth_about_every_outcome
    assert_match(/no orphan left behind/i, CertProcess.reap_report(4300, :reaped, @root))
    assert_match(/already gone/i, CertProcess.reap_report(4300, :absent, @root))

    %i[refused survived].each do |outcome|
      report = CertProcess.reap_report(4300, outcome, @root)

      assert_match(/could NOT reap/i, report, "#{outcome}: say what actually happened")
      assert_match(/LEFT IN PLACE/i, report, "#{outcome}: and say the lock was KEPT, so the next cert finds it")
      refute_match(/no orphan left behind/i, report,
                   "#{outcome}: the guard refused to act — it must not report that it acted")
    end
  end

  def test_only_a_gone_group_clears_the_lock
    assert CertOrphanGuard.reap_cleared?(:reaped),  "we killed it → the lock has nothing to name"
    assert CertOrphanGuard.reap_cleared?(:absent),  "it was already gone → nothing to name"
    refute CertOrphanGuard.reap_cleared?(:refused), "we did NOT signal it → the lock is the only record"
    refute CertOrphanGuard.reap_cleared?(:survived), "it outlived our KILL → the lock is the only record"
  end
end

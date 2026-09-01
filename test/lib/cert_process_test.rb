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
require "rbconfig"
require "shellwords"
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

  # THE RUNLOCK, PARSED — the observable these tests actually depend on, waited on directly.
  #
  # `File.exist?` is NOT that observable, and polling it is what made this file flaky. The
  # runlock used to be published with a plain `File.write` — open(O_CREAT|O_TRUNC) and THEN
  # write — so between those two syscalls the path EXISTED and was ZERO BYTES. A poll that
  # stops at `exist?` therefore returned while the lock was empty or half-written;
  # `read_lock` rescues the JSON::ParserError to NIL, and the caller's `["pgid"]` raised
  #
  #     NoMethodError: undefined method `[]' for nil
  #
  # on a lock that was about to be perfectly valid. Measured against that writer, 4.6% of
  # reads taken the instant `exist?` went true came back nil, and the path was observed at
  # zero bytes 139k times — a wide window, not a theoretical one. It fires on a LOADED box
  # (a sharded consumer lane) because the child gets descheduled inside the gap, which is
  # why a quiet desk never saw it and studio-engine's publish preflight did: it red-sealed
  # the `mcritchie_studio suite vs this engine (shard 1/4)` lane and cost 0.66.0 a release
  # cycle. 1960 runs, 0 failures, 1 error.
  #
  # `write_lock` now renames the lock into place, so that particular window is closed at
  # the source (see cert_runlock_test.rb, which pins it). This wait does NOT lean on that:
  # a test that depends on its writer's publish strategy is one refactor away from being
  # silently flaky again, and the deadline can still legitimately expire for an unrelated
  # reason — a child that dies before it ever gets to the lock. So wait for the STATE, not
  # the path: a lock that parses AND names its group. Nil stays a legitimate reading, and
  # it gets a NAMED outcome here rather than being subscripted blind. The deadline is
  # unchanged (10s), and nothing about the claim under test is retried or loosened. When
  # the wait does expire, the failure says which state it ended in and hands over the
  # child's stderr, which is what tells the two causes apart.
  def await_lock(timeout: 10)
    deadline = Time.now + timeout
    loop do
      parsed = CertOrphanGuard.read_lock(@root)
      return parsed if parsed && parsed["pgid"]

      break if Time.now >= deadline

      sleep 0.05
    end

    flunk(<<~MSG)
      the cert never published a readable runlock within #{timeout}s.
        lock path : #{lock}
        on disk   : #{File.exist?(lock) ? "yes, #{File.size(lock)} bytes" : "NO FILE — the cert never got as far as writing it"}
        contents  : #{File.exist?(lock) ? File.read(lock).inspect : "(none)"}
        read_lock : #{CertOrphanGuard.read_lock(@root).inspect}
        child said: #{warning.empty? ? "(nothing on stderr)" : warning}
    MSG
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

    suite = await_lock["pgid"]
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

  # --- [integration] THE INTERRUPT CONTRACT: a catchable death must CLOSE the gate --------
  #
  # `exit!` in the trap skips every ensure block in the cert. That is deliberate and right
  # for the REAP — it must be last and deterministic — and it was silently wrong for
  # everything else: the cert's own G1 close never ran, so a Ctrl-C left its g1_cert attempt
  # OPEN with a `running` row standing, and Cert::LocalCheck reads exactly that as a cert
  # still working. The killed run then showed STALLED on its board card for the rest of the
  # task's life, and every re-run opened another attempt beside it.
  #
  # A catchable signal is not an unknowable death: we are still executing, so we can say what
  # happened. The caller hands in a closure, and these pin the three things that makes true —
  # it RUNS, it runs AFTER the reap, and a closure that blows up cannot cost the cert its
  # exit.

  def signal_evidence = File.join(@root, "on-signal.log")

  def evidence = File.exist?(signal_evidence) ? File.read(signal_evidence) : ""

  # Same shape as spawn_cert, with a closure whose body is the artefact under test. It
  # records the SIGNAL it was handed and whether the runlock was still on disk when it ran —
  # the lock is cleared by the reap, so its absence is proof of ORDER, not just of arrival.
  def spawn_cert_with_closure(body:, cmd: "sleep 300")
    script = <<~RB
      $LOAD_PATH.unshift #{File.expand_path("bin/lib", Dir.pwd).inspect}
      require "cert_orphan_guard"
      require "cert_process"
      closure = lambda do |sig|
        #{body}
      end
      CertProcess.run({}, #{cmd.inspect}, chdir: #{@root.inspect}, root: #{@root.inspect},
                      lane: #{LANE.inspect}, db: "studio_test_x", on_signal: closure)
    RB
    child = Process.spawn("ruby", "-e", script, err: stderr_log)
    @spawned << child

    suite = await_lock["pgid"]
    @spawned << suite
    [child, suite]
  end

  RECORD = 'File.write(%s, "sig=#{sig} lock_present=#{File.exist?(%s)}")'

  def test_a_catchable_signal_runs_the_gate_closure
    child, suite = spawn_cert_with_closure(body: format(RECORD, signal_evidence.inspect, lock.inspect))

    Process.kill("TERM", child)
    Process.waitpid(child)

    assert wait_until_dead(suite), "the reap still happens — the closure must not displace it"
    assert_match(/sig=TERM/, evidence,
                 "a cert killed by a catchable signal must CLOSE its gate, or the card calls it " \
                 "STALLED forever")
    assert_equal 128 + Signal.list.fetch("TERM"), $?.exitstatus,
                 "the closure runs on the way out, it does not change the way out"
  end

  def test_the_closure_runs_AFTER_the_reap
    child, suite = spawn_cert_with_closure(body: format(RECORD, signal_evidence.inspect, lock.inspect))

    Process.kill("INT", child)
    Process.waitpid(child)
    wait_until_dead(suite)

    # `settle` clears the runlock the moment it proves the group is reaped. Seeing the lock
    # already GONE from inside the closure is what proves the ORDER: the suite died first.
    assert_match(/lock_present=false/, evidence,
                 "the suite must die BEFORE the bookkeeping — an orphan on the test DB outranks a " \
                 "gate row every time")
  end

  def test_a_RAISING_closure_still_reaps_and_still_exits
    child, suite = spawn_cert_with_closure(body: 'raise "gate write blew up"')

    Process.kill("TERM", child)
    Process.waitpid(child)

    assert wait_until_dead(suite),
           "a cert dying under an operator has ONE remaining duty; bookkeeping may not cost it that"
    assert_equal 128 + Signal.list.fetch("TERM"), $?.exitstatus, "it must still exit for the signal"
    assert_match(/could not close the gate/i, warning,
                 "and it must SAY the board is now stale, rather than failing silently")
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

    assert_nil await_lock["pgid_started_at"],
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

  # --- [unit] THE LANE CEILING: a runner that never returns must not be called RED --------
  #
  # MEASURED 2026-08-21: a turf-monster mapped-tests lane sat 41 MINUTES at 0.0% CPU (its
  # forked test workers had SIGSEGVed at the fork; the runner was parked on the DRb channel
  # waiting for the dead) and bin/fast-check then printed "lane(s) RED: mapped-tests". No
  # test had run. Every agent who read that verdict re-ran the cert — into the same wall,
  # for another 41 minutes. The deadlock was environmental; A LANE WITH NO CEILING IS A
  # DEFECT ON ITS OWN, and it is the half of this that is ours to fix.

  def test_a_lane_that_outruns_its_ceiling_reports_a_TIMEOUT_not_a_verdict
    result = CertProcess.run_bounded({}, "sleep 30", chdir: @root, root: @root, lane: LANE, timeout: 1)

    assert result.timeout?, "past its ceiling the wait must give up and SAY it gave up"
    assert_equal :timeout, result.outcome
    refute result.ok, "no verdict was produced, so there is nothing to certify"
    refute_nil result.detail, "a bare timeout is the uninformative half of the bug — say what was running"
  end

  def test_the_boolean_face_of_a_timeout_is_FALSE
    # THE LOAD-BEARING PROPERTY. `run` returns a plain boolean and always will; every
    # existing caller reads it as PASS/FAIL. Had a timeout surfaced as a truthy `:timeout`
    # symbol, a hung runner would have CERTIFIED. Fail closed, always.
    refute CertProcess.run({}, "sleep 30", chdir: @root, root: @root, lane: LANE, timeout: 1),
           "a hung runner must never green a cert, whatever the caller forgets to check"
  end

  def test_a_timed_out_lane_is_REAPED_not_left_running
    # The ceiling would be a downgrade if giving up meant walking away: the abandoned
    # runner still holds the worktree test DB, and the next cert dies on PG::ObjectInUse.
    marker = File.join(@root, "lane.pid")
    cmd = "#{RbConfig.ruby.shellescape} -e #{"File.write(#{marker.inspect}, Process.pid.to_s); sleep 60".shellescape}"
    result = CertProcess.run_bounded({}, cmd, chdir: @root, root: @root, lane: LANE, timeout: 2)

    assert result.timeout?
    assert_path_exists marker, "the lane must actually have started, or this proves nothing"
    lane_pid = File.read(marker).to_i
    @spawned << lane_pid
    assert wait_until_dead(lane_pid),
           "ORPHAN: the timed-out lane outlived the cert. It keeps the test DB open and every retry " \
           "then dies on PG::ObjectInUse blaming an ENV gap."
  end

  def test_a_lane_that_finishes_inside_its_ceiling_is_untouched
    green = CertProcess.run_bounded({}, "true", chdir: @root, root: @root, lane: LANE, timeout: 60)

    assert green.ok
    assert_equal :completed, green.outcome
    refute green.timeout?

    red = CertProcess.run_bounded({}, "false", chdir: @root, root: @root, lane: LANE, timeout: 60)

    refute red.ok
    assert_equal :completed, red.outcome
    refute red.timeout?, "A RED SUITE IS NOT A HANG. Conflating them re-creates the bug in the mirror: " \
                         "the reader would be told to diagnose the runner when their tests genuinely failed."
  end

  def test_no_ceiling_means_the_original_blocking_wait
    # nil/0/negative must not silently become an instant timeout — every caller that has
    # never heard of ceilings still runs through this method.
    [nil, 0, -1].each do |ceiling|
      result = CertProcess.run_bounded({}, "true", chdir: @root, root: @root, lane: LANE, timeout: ceiling)

      assert result.ok, "timeout: #{ceiling.inspect} must block for the verdict, not invent one"
      assert_equal :completed, result.outcome
    end
  end

  # --- [unit] the SIGNATURE: name the deadlock, or admit you cannot ----------------------

  def test_the_signature_names_dead_forked_workers
    diagnosis = CertProcess.diagnosis(zombies: 14, live: 1, cpu: 1.2, timeout: 900)

    assert_match(/workers are DEAD/i, diagnosis, "the measured shape: corpses and a parked parent")
    assert_match(/PARALLEL_WORKERS=1/, diagnosis, "and the one command that gets the reader unstuck")
  end

  def test_the_signature_names_a_parked_runner_with_no_zombies_to_point_at
    diagnosis = CertProcess.diagnosis(zombies: 0, live: 1, cpu: 0.4, timeout: 900)

    assert_match(/PARKED/i, diagnosis)
    refute_match(/workers are DEAD/i, diagnosis, "do not claim corpses we did not see")
  end

  def test_an_unrecognised_hang_admits_it_rather_than_guessing
    # A diagnosis this file INVENTS is the same disease as the "lane(s) RED" it replaces.
    diagnosis = CertProcess.diagnosis(zombies: 0, live: 6, cpu: 812.0, timeout: 900)

    assert_match(/No known deadlock signature/i, diagnosis)
    assert_match(/slower than this ceiling/i, diagnosis, "and point at the ceiling, which IS the other explanation")
  end

  def test_cpu_time_is_parsed_strictly_or_not_at_all
    assert_in_delta 5.0, CertProcess.parse_cpu_time("0:05.00"), 0.001
    assert_in_delta 65.5, CertProcess.parse_cpu_time("01:05.50"), 0.001
    assert_in_delta 3725.0, CertProcess.parse_cpu_time("1:02:05"), 0.001
    assert_in_delta 90_000.0, CertProcess.parse_cpu_time("1-01:00:00"), 0.001

    # The fabrication guard. The `ps` seam (CERT_GUARD_PS) is a FIXTURE in these suites, and
    # a fixture answers a shape it was not written for with arbitrary text. A loose parse of
    # "Jul  8 09:00:00" yields a perfectly confident 0.0 CPU — which this file would then
    # report as "the runner is PARKED". Evidence we made up is worse than no evidence.
    ["Jul  8 09:00:00", "", "not a time", "abc:def"].each do |junk|
      assert_nil CertProcess.parse_cpu_time(junk), "#{junk.inspect} must yield NO reading, not a made-up one"
    end
  end

  # --- [unit] the report an agent actually reads -----------------------------------------

  def test_the_timeout_report_cannot_be_mistaken_for_a_test_failure
    # This is the whole deliverable in one assertion. The 41-minute hang was survivable;
    # what made it cost the FLEET its budget was the sentence "lane(s) RED", which every
    # agent reads as "your tests failed" and answers with a re-run.
    hung = { "mapped-tests" => CertProcess::Result.new(ok: false, outcome: :timeout,
                                                       detail: "process group 87242: 1 live, 14 zombie.") }
    report = CertProcess.timeout_report(hung, ceiling: 900, tool: "fast-check",
                                        env_var: "FAST_CHECK_LANE_TIMEOUT").join("\n")

    assert_match(/RUNNER HUNG/, report, "name the RUNNER — it is the thing that failed")
    assert_match(/NOT a test failure/, report)
    assert_match(/never produced a\s+result/, report, "say plainly that no verdict exists")
    assert_match(/mapped-tests/, report, "name the lane")
    assert_match(/14 zombie/, report, "carry the process table's signature through to the reader")
    assert_match(/900s/, report, "print the ceiling it hit")
    assert_match(/FAST_CHECK_LANE_TIMEOUT/, report, "and how to raise it deliberately")
    refute_match(/\bRED\b/, report,
                 "THE REGRESSION: 'RED' is the word that sent agents back into the wall for 41 minutes.")
  end

end

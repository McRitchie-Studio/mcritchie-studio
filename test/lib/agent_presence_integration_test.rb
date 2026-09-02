# frozen_string_literal: true

# [integration] bin/agent-presence — the killed-writer property, proved by kill.
#
# THE CLAIM THIS FILE EXISTS TO PROVE, and it is the one the whole design rests on:
#
#   A claim whose writer has been KILLED reads as dead IMMEDIATELY — no timeout to
#   elapse, no renewal to miss, so the wedge window is ZERO rather than one TTL.
#
# That cannot be proved against a hand-built process table, because a hand-built table
# is just the author asserting the conclusion. So every process here is real: spawned
# with Process.spawn, identified by the OS's own `ps -o lstart=`, killed with a real
# signal, and graded against a real `ps`. Nothing is stubbed and nothing sleeps waiting
# for a lease to lapse — `Process.waitpid` returns when the OS says the process is gone,
# and the very next read is the assertion.
#
# AND THE OPPOSITE ERROR, which is the one that would starve someone all over again.
# A LIVE process must read as LIVE even when it is IDLE. Cost #4: two `bin/ship`
# processes parked in a CI wait — consuming nothing, sleeping — read as competing certs
# and nearly held off a launch. A sleeping `sleep 30` is exactly that shape, and if this
# reader graded "not burning CPU" as "not there" it would reproduce the bug it replaces.
# Both directions are asserted, because a reader that gets only one right is not safe.
#
#   ruby -Itest test/lib/agent_presence_integration_test.rb

require "minitest/autorun"
require "json"
require "fileutils"
require "tmpdir"
require_relative "../../bin/lib/agent_presence"
require_relative "../../bin/lib/cert_orphan_guard"

class AgentPresenceIntegrationTest < Minitest::Test
  BIN = File.expand_path("../../bin/agent-presence", __dir__)

  def setup
    @spawned = []
  end

  def teardown
    @spawned.each do |pid|
      Process.kill("KILL", pid)
      Process.waitpid(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end
  end

  # An IDLE process: sleeping, consuming no CPU. The shape of a ship in a CI wait.
  def spawn_idle
    pid = Process.spawn("sleep", "30", pgroup: true, out: File::NULL, err: File::NULL)
    @spawned << pid
    pid
  end

  def kill_and_reap(pid)
    Process.kill("KILL", pid)
    Process.waitpid(pid) # returns only once the OS has actually torn it down
    @spawned.delete(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    @spawned.delete(pid)
  end

  def runlock_for(pid, started_at)
    {
      "cert_pid" => pid, "cert_started_at" => started_at,
      "pgid" => pid, "pgid_started_at" => started_at,
      "lane" => "mapped-tests", "db" => "presence_test",
      "started_at" => Time.now.utc.iso8601
    }
  end

  # --- the killed-writer property ------------------------------------------------------

  def test_a_killed_writers_claim_grades_dead_on_the_very_next_read_with_no_waiting
    pid = spawn_idle
    started_at = CertOrphanGuard.process_started_at(pid)
    refute_nil started_at, "ps must give us the OS's start time for a process we just spawned"
    lock = runlock_for(pid, started_at)

    # Alive first — otherwise "dead" afterwards would prove nothing about the kill.
    assert_equal :live, AgentPresence.grade(lock: lock, table: CertOrphanGuard.process_table)[0]

    kill_and_reap(pid)

    # No sleep, no retry, no TTL. The next read is the whole test.
    began = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    verdict, = AgentPresence.grade(lock: lock, table: CertOrphanGuard.process_table)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - began

    assert_equal :dead, verdict, "a killed writer's claim must be a corpse immediately"
    assert_operator elapsed, :<, 2.0,
                    "the verdict must cost one ps, not one TTL — the shortest lease in this house is 120s"
  end

  # A killed process is a ZOMBIE until its parent reaps it, and a zombie still answers
  # `kill(0)`. So every "is it alive?" probe written the obvious way reads a corpse as a
  # live orphan. This grades the unreaped corpse — dead, with the child still unwaited.
  def test_a_killed_but_unreaped_child_is_a_corpse_not_a_live_claim
    pid = spawn_idle
    lock = runlock_for(pid, CertOrphanGuard.process_started_at(pid))
    Process.kill("KILL", pid)

    # Bounded poll for the OS to tear the process down. This is kernel latency, NOT a
    # lease expiring: it is milliseconds and it does not scale with any configured value.
    verdict = nil
    40.times do
      verdict, = AgentPresence.grade(lock: lock, table: CertOrphanGuard.process_table)
      break if verdict == :dead

      sleep 0.05
    end

    assert_equal :dead, verdict, "a zombie holds no DB connection and is not a running suite"
  end

  # --- the opposite error: idle is not dead ---------------------------------------------

  def test_an_idle_live_process_reads_as_live_because_idle_is_not_dead
    pid = spawn_idle
    lock = runlock_for(pid, CertOrphanGuard.process_started_at(pid))

    table = CertOrphanGuard.process_table
    row = table.find { |p| p[:pid] == pid }
    refute_nil row
    assert_match(/\AS/, row[:state].to_s, "sleep(1) is a SLEEPING process — the CI-wait shape")

    assert_equal :live, AgentPresence.grade(lock: lock, table: table)[0],
                 "a process consuming no CPU is still holding its slot; conflating the two starves peers"
  end

  def test_a_live_process_stays_live_across_repeated_reads
    pid = spawn_idle
    lock = runlock_for(pid, CertOrphanGuard.process_started_at(pid))

    3.times do
      assert_equal :live, AgentPresence.grade(lock: lock, table: CertOrphanGuard.process_table)[0]
    end
  end

  # --- identity, against a real live process ---------------------------------------------

  # A pid is a recyclable integer. Here the pid is REAL and ALIVE and the recorded start
  # time is not its own — which is precisely what a recycled pid looks like. It must never
  # be counted, and it must never be signalled. (A nine-day-old lock whose pgid had been
  # recycled is what once made the reaper kill an unrelated bystander.)
  def test_a_live_pid_whose_start_time_disagrees_is_a_stranger_not_our_suite
    pid = spawn_idle
    lock = runlock_for(pid, "Tue Jul  7 03:00:00 2026")

    verdict, detail = AgentPresence.grade(lock: lock, table: CertOrphanGuard.process_table)

    assert_equal :recycled, verdict
    assert_equal pid, detail[:found][:pid], "the stranger is named, never guessed at"
  end

  # --- the file path: glob, read, locate, grade --------------------------------------------

  def test_claims_are_found_by_glob_in_both_the_primary_and_worktree_git_dirs
    live = spawn_idle
    dead = spawn_idle
    live_lock = runlock_for(live, CertOrphanGuard.process_started_at(live))
    dead_lock = runlock_for(dead, CertOrphanGuard.process_started_at(dead))
    kill_and_reap(dead)

    Dir.mktmpdir("presence") do |root|
      write_lock(File.join(root, "turf-monster/.git/cert-run.json"), live_lock)
      write_lock(File.join(root, "mcritchie-studio/.git/worktrees/some-desk/cert-run.json"), dead_lock)

      found = AgentPresence.claims(root: root, table: CertOrphanGuard.process_table)

      assert_equal 2, found.size
      primary = found.find { |c| c[:repo] == "turf-monster" }
      desk    = found.find { |c| c[:repo] == "mcritchie-studio" }

      assert_equal :live, primary[:grade]
      assert_equal "primary", primary[:desk]
      assert_equal :dead, desk[:grade]
      assert_equal "some-desk", desk[:desk], "a worktree claim must name its desk, not the primary"
    end
  end

  def test_an_unparseable_claim_is_graded_malformed_rather_than_crashing_the_reader
    Dir.mktmpdir("presence") do |root|
      path = File.join(root, "rolio/.git/cert-run.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{not json at all")

      found = AgentPresence.claims(root: root, table: [])

      assert_equal 1, found.size
      assert_equal :malformed, found.first[:grade]
    end
  end

  # --- the reader as a whole -----------------------------------------------------------------

  def test_a_live_claim_consumes_capacity_and_is_reported_as_a_live_suite
    pid = spawn_idle
    Dir.mktmpdir("presence") do |root|
      write_lock(File.join(root, "rolio/.git/cert-run.json"),
                 runlock_for(pid, CertOrphanGuard.process_started_at(pid)))

      snapshot = AgentPresence.snapshot(root: root, load: nil)

      assert_equal 1, snapshot[:counts]["live"]
      assert_in_delta 1.0, snapshot[:consumed], 0.001
      assert_in_delta AgentPresence.suite_capacity - 1.0, snapshot[:headroom], 0.001
      assert_match(/LIVE/, AgentPresence.render(snapshot))
    end
  end

  # THE READER WRITES NOTHING. Asserted by fingerprint over the whole tree, because a
  # reader that quietly unlinked or rewrote a claim would still pass every grading test
  # above while destroying the one artefact that names a live orphan.
  def test_reading_mutates_nothing_on_disk
    pid = spawn_idle
    Dir.mktmpdir("presence") do |root|
      path = File.join(root, "rolio/.git/cert-run.json")
      write_lock(path, runlock_for(pid, CertOrphanGuard.process_started_at(pid)))
      stale = File.join(root, "chain-ops/.git/cert-run.json")
      write_lock(stale, runlock_for(999_999, "Tue Jul  7 03:00:00 2026")) # a proven corpse

      before = fingerprint(root)
      AgentPresence.render(AgentPresence.snapshot(root: root, load: nil))

      assert_equal before, fingerprint(root),
                   "the reader must not unlink even a proven corpse: the guard KEEPS a lock " \
                   "when a reap is refused, because then it is the only record naming the survivor"
    end
  end

  def fingerprint(root)
    Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)
       .reject { |p| File.basename(p).start_with?(".", "..") && File.directory?(p) }
       .sort
       .map { |p| File.file?(p) ? [p, File.read(p)] : [p, :dir] }
  end

  def write_lock(path, lock)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(lock))
  end

  # --- the CLI contract ------------------------------------------------------------------------

  def test_the_cli_emits_json_and_exits_busy_when_a_live_claim_holds_all_capacity
    pid = spawn_idle
    Dir.mktmpdir("presence") do |root|
      write_lock(File.join(root, "rolio/.git/cert-run.json"),
                 runlock_for(pid, CertOrphanGuard.process_started_at(pid)))

      out = IO.popen(
        { "AGENT_PRESENCE_SUITE_CAPACITY" => "1" },
        [BIN, "--json", "--root", root], err: File::NULL, &:read
      )
      status = $?.exitstatus
      payload = JSON.parse(out)

      assert_equal AgentPresence::EXIT_BUSY, status
      assert_equal 1, payload["counts"]["live"]
      assert_in_delta 0.0, payload["headroom"], 0.001
      assert_equal "busy", payload["verdict"]
    end
  end

  # `--help` is the universal safe probe, and this script's exit 0 is a VERDICT ("clear
  # to start"). Answering a probe with a green light is the defect class bin/archive-docs
  # and bin/release each shipped; help must never hand out this script's 0.
  def test_help_produces_no_verdict_and_never_exits_clear
    out = IO.popen([BIN, "--help"], err: [:child, :out], &:read)

    refute_equal AgentPresence::EXIT_CLEAR, $?.exitstatus
    assert_match(/usage: bin\/agent-presence/, out)
    refute_match(/verdict:/, out)
  end

  def test_an_unrecognized_argument_refuses_rather_than_reporting
    out = IO.popen([BIN, "--reap"], err: [:child, :out], &:read)

    assert_equal AgentPresence::EXIT_USAGE, $?.exitstatus
    assert_match(/unrecognized argument/, out)
    assert_match(/NOTHING was read/, out)
  end
end

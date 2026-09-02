# frozen_string_literal: true

# THE KILLED-WRITER RULE, PROVED AGAINST A REAL KILL.
#
# The unit tier grades hand-built claims against a process table. That is the right tier
# for the decision table, and it is NOT enough for the one property this whole design
# rests on: that a SIGKILLed sweep is graded a corpse by the OS's own answer, with no
# timeout to elapse. A stand-in pid can only show the code path; a process this test
# actually starts and actually kills shows the property.
#
# So this tier spawns a REAL conductor stand-in in its OWN process group, has it publish
# through the REAL ReleasePresence, reads the claim from disk, and SIGKILLs it — the
# signal no handler can catch, which is precisely why the runlock exists — then grades
# the survivor against a REAL `ps`.
#
# It also pins the I/O boundary the unit tier stubs away: two independent processes
# contending for ONE claim slot, where the loser must leave the incumbent's record intact.
#
# Run directly:
#   ruby -Itest test/lib/release_presence_integration_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "shellwords"
require_relative "../../bin/lib/release_presence"
require_relative "../../bin/lib/cert_orphan_guard"

class ReleasePresenceIntegrationTest < Minitest::Test
  LIB = File.expand_path("../../bin/lib/release_presence", __dir__)
  BOOT_TIMEOUT = 20.0

  # A conductor stand-in: its own process group (as `bin/release` gets from the shell that
  # launches it), a real claim through the real module, then an unbounded sleep. It never
  # exits on its own, so the ONLY way this test ends it is the kill it is here to prove.
  def spawn_conductor(root, kind:, lane:)
    script = <<~RB
      Process.setpgrp
      require #{LIB.inspect}
      ReleasePresence.open!(kind: #{kind.inspect}, root: #{root.inspect}, lane: #{lane.inspect},
                            agent: "avi", command: "bin/release prepare")
      $stdout.puts("claimed")
      $stdout.flush
      sleep
    RB
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", script, out: writer, err: File::NULL)
    writer.close
    wait_for_claim(reader, pid, root)
    pid
  end

  def wait_for_claim(reader, pid, root)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    until File.exist?(CertOrphanGuard.lock_path(root))
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        kill!(pid)
        flunk "the conductor stand-in never published a claim within #{BOOT_TIMEOUT}s"
      end
      sleep 0.05
    end
  ensure
    reader.close
  end

  def kill!(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # The reader's rule (bin/lib/agent_presence.rb#grade), in the guard's primitives.
  def grade(claim)
    table = CertOrphanGuard.process_table
    pid = CertOrphanGuard.coerce_pid(claim["cert_pid"])
    process = CertOrphanGuard.live_process(table, pid)
    return :dead if process.nil?

    CertOrphanGuard.identity_of(process, claim["cert_started_at"])
  end

  def read_claim(root)
    JSON.parse(File.read(CertOrphanGuard.lock_path(root)))
  end

  # --- [integration] a real sweep, a real SIGKILL, a real process table ----------------

  def test_a_real_killed_sweep_leaves_a_claim_that_grades_dead_immediately
    Dir.mktmpdir do |root|
      pid = spawn_conductor(root, kind: "sweep", lane: "release:prepare")
      claim = read_claim(root)

      assert_equal pid, claim["cert_pid"]
      assert_equal :ours, grade(claim),
                   "while the sweep runs, the reader must PROVE the claim is that process — " \
                   "identity is what lets a peer trust the phase and weight beside it"

      kill!(pid)

      assert_path_exists CertOrphanGuard.lock_path(root),
                         "SIGKILL runs no handler, so the claim MUST survive its writer. That is " \
                         "the design, not a leak: the file is the only local record naming the " \
                         "workload, and the reader is what decides it is a corpse"
      assert_equal :dead, grade(read_claim(root)),
                   "graded dead on the VERY NEXT read — no TTL to wait out. The house has paid " \
                   "twice for the alternative: a shift lease renewed by a UI paint reported a " \
                   "lane FREE while its holder worked, and renewers that outlived their work " \
                   "spent the account-wide 1Password cap"
    end
  end

  def test_a_second_conductor_leaves_a_live_peers_claim_intact
    Dir.mktmpdir do |root|
      pid = spawn_conductor(root, kind: "sweep", lane: "release:prepare")
      begin
        incumbent = read_claim(root)

        # A `bin/release ship` starting beside a live `prepare` — a documented occurrence
        # here, and both root at the same primary checkout.
        assert_nil ReleasePresence.open!(kind: ReleasePresence::SHIP, root: root,
                                         lane: "release:ship"),
                   "the second conductor must publish NOTHING rather than overwrite a live " \
                   "peer. Unpublished degrades to today (the reader's backstop still names the " \
                   "process); overwritten destroys the peer's only local record"
        assert_equal incumbent, read_claim(root)
      ensure
        kill!(pid)
        ReleasePresence.forget!
      end
    end
  end

  def test_a_conductor_takes_the_slot_once_the_previous_writer_is_proven_dead
    Dir.mktmpdir do |root|
      pid = spawn_conductor(root, kind: "sweep", lane: "release:prepare")
      kill!(pid)

      begin
        refute_nil ReleasePresence.open!(kind: ReleasePresence::SHIP, root: root,
                                         lane: "release:ship"),
                   "the next conductor must reclaim a corpse's slot with no timeout, or one " \
                   "killed sweep would hide every sweep after it"
        assert_equal Process.pid, read_claim(root)["cert_pid"]
        assert_equal "ship", read_claim(root)["kind"]
      ensure
        ReleasePresence.forget!
      end
    end
  end
end

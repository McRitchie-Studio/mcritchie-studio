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
require_relative "../../bin/lib/agent_presence"

class ReleasePresenceIntegrationTest < Minitest::Test
  LIB = File.expand_path("../../bin/lib/release_presence", __dir__)
  BOOT_TIMEOUT = 20.0

  # A conductor stand-in: a real claim through the real module, then an unbounded sleep.
  # It never exits on its own, so the ONLY way this test ends it is the kill it is here
  # to prove.
  #
  # IT DELIBERATELY DOES NOT CALL `Process.setpgrp`, and that omission is the whole point.
  # An earlier version opened with `Process.setpgrp` and commented it as "what bin/release
  # gets from the shell that launches it" — backwards. `bin/release` calls `setpgrp`
  # NOWHERE; it INHERITS its caller's group. So the stand-in was installing a topology the
  # real conductor never has: it MANUFACTURED the safe case and then certified the unsafe
  # code, and 12/12 green proved only that the fixture agreed with itself (review,
  # 2026-09-02).
  #
  # Spawned plainly, the child inherits THIS TEST RUNNER'S process group — whose leader is
  # the runner, which by construction OUTLIVES the child we are about to kill. That is
  # exactly the harness shape (`/bin/zsh -c …` wrapper, measured at pid 61666 in pgid
  # 61388), reproduced with no artifice at all.
  def spawn_conductor(root, kind:, lane:)
    script = <<~RB
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

  # THE REAL READER — `bin/lib/agent_presence.rb#grade`, not a restatement of it.
  #
  # The earlier version of this helper reimplemented the rule over `cert_pid` ONLY, so it
  # structurally COULD NOT SEE the `:lane` (pgid) subject — which is exactly where the
  # defect lived. A grader that reads one subject cannot express a two-subject bug, and
  # this tier exists to catch precisely that (review, 2026-09-02). So call the shipped
  # reader and let it disagree with us: the reader walks BOTH subjects, and a claim is
  # only a corpse when it is dead on both.
  def grade(claim)
    AgentPresence.grade(lock: claim, table: CertOrphanGuard.process_table).first
  end

  # What the reader does with that grade — `:unverifiable` counts against capacity too,
  # so "not :live" is NOT the same question as "frees the machine".
  def counted?(claim)
    AgentPresence::COUNTED_GRADES.include?(grade(claim))
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
      assert_equal :live, grade(claim),
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

  # --- [integration] the claim may only name a subject its writer OWNS -----------------
  #
  # THIS IS THE TEST THAT WOULD HAVE CAUGHT THE BLOCKER, and every clause of it is chosen
  # so that it CANNOT pass by agreeing with itself:
  #
  #   * it grades with the REAL `AgentPresence.grade` (both subjects), not a helper that
  #     reads `cert_pid` and calls that the reader;
  #   * it spawns the conductor with NO `setpgrp`, exactly as `bin/release` runs, so the
  #     child inherits THIS RUNNER'S group;
  #   * the runner — the group's leader — is alive throughout and by construction outlives
  #     the child, which is the harness shape (`/bin/zsh -c …` wrapper) that made an
  #     inherited pgid read as a live claim forever.
  #
  # Against the pre-fix writer (`pgid: Process.getpgrp`) this fails on the first
  # assertion: the killed sweep grades :live via the `:lane` subject, COUNTED at weight
  # 0.25, with no TTL to expire — an unbounded wedge, and the exact inverse of the rule
  # this module is named for.
  def test_a_killed_sweep_is_a_corpse_to_the_real_reader_not_just_to_its_own_helper
    Dir.mktmpdir do |root|
      pid = spawn_conductor(root, kind: "sweep", lane: "release:prepare")
      claim = read_claim(root)

      assert_equal pid, claim["pgid"],
                   "the claim must name a process group its WRITER OWNS. `bin/release` " \
                   "never calls setpgrp, so recording Process.getpgrp names the LAUNCHING " \
                   "SHELL's group — a group shared with the rest of the session, which " \
                   "this process has no right to speak for and no right to signal"
      refute_equal Process.getpgrp, claim["pgid"],
                   "and it must NOT be the inherited group: this test runner leads that " \
                   "group and outlives the conductor, which is precisely how a corpse " \
                   "kept reading as live"

      kill!(pid)

      assert_equal :dead, grade(read_claim(root)),
                   "the REAL reader must call a killed sweep dead on the very next read. " \
                   "With the inherited pgid it returned :live via the `:lane` subject — " \
                   "the runner leading that group is still alive and its (pid, lstart) " \
                   "still matches — so the corpse counted against capacity forever"
      refute counted?(read_claim(root)),
             "and dead must mean UNCOUNTED, or the machine reports saturation that " \
             "no process is causing and every later suite is refused headroom"
    end
  end

  # The reaper's half of the same invariant. `CertOrphanGuard.preflight` REAPS what it
  # grades `:orphan` — SIGTERM then SIGKILL at the whole process group — and a primary
  # checkout is NOT out of its reach (a slug-less `bin/full-suite-check`, which is what
  # `--install-hook` writes into `.git/hooks/pre-push`, skips the root guard and preflights
  # anyway). So the verdict on a dead conductor's claim must never point a kill at a group
  # this process did not own.
  #
  # Graded from a foreign vantage point on purpose: a real cert is spawned with
  # `pgroup: true`, so it sits in its OWN group and `signalable?` does NOT refuse the
  # claim's group for it. Grading as `self` would hide the bug behind that refusal.
  def test_a_dead_conductors_claim_never_sends_the_reaper_at_a_bystander_group
    Dir.mktmpdir do |root|
      pid = spawn_conductor(root, kind: "sweep", lane: "release:prepare")
      kill!(pid)

      verdict, detail = CertOrphanGuard.decide(lock: read_claim(root),
                                               table: CertOrphanGuard.process_table,
                                               self_pid: 999_998, self_pgid: 999_999)

      assert_equal :stale, verdict,
                   "nothing the claim names is alive, so the only safe verdict is :stale " \
                   "— clear the file and proceed. With the inherited pgid this graded " \
                   ":orphan and reap_group would have SIGKILLed the launching shell's " \
                   "group, measured holding 5 unrelated processes including the session"
      refute_equal :orphan, verdict,
                   "an :orphan verdict here is a licence to kill a group this process " \
                   "never created"
      assert_equal pid, detail[:pgid],
                   "and whatever the verdict, the group named must be the writer's own"
    end
  end
end

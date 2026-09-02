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
# signal no handler can catch, which is precisely why this record exists — then grades the
# survivor against a REAL `ps`, using the REAL reader.
#
# It also pins what a peer READS while all this happens: `AgentPresence.snapshot` headroom
# before, during and after. A weight is a constant and a test that asserts one passes in
# both directions the moment somebody edits the constant and the expectation together.
# Headroom can only be produced by a claim that is on disk, live, graded and weighted
# correctly at that instant.
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
  CAPACITY = AgentPresence::DEFAULT_SUITE_CAPACITY

  def setup
    ReleasePresence.forget!
  end

  def teardown
    ReleasePresence.forget!
  end

  # `store` is the projects dir the marker lands under — what the reader globs; `root` is
  # the repo path the claim REPORTS. Two different things, and conflating them is how a
  # test passes while the reader sees nothing.
  def with_store
    Dir.mktmpdir { |store| yield(store, File.join(store, "mcritchie-studio")) }
  end

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
  def spawn_conductor(store, root, kind:, lane:, weight: nil)
    weight_arg = weight ? ", weight: #{weight.inspect}" : ""
    script = <<~RB
      require #{LIB.inspect}
      ReleasePresence.open!(kind: #{kind.inspect}, root: #{root.inspect}, lane: #{lane.inspect},
                            projects_dir: #{store.inspect}, session_id: "conductor-#{kind}"#{weight_arg},
                            env: { "TASK_USAGE_SANDBOX" => "0" })
      $stdout.puts("claimed")
      $stdout.flush
      sleep
    RB
    # WAIT FOR THIS CONDUCTOR'S OWN FILE, not merely for "a file". Waiting on non-empty
    # returns instantly when a PEER already published, so the second conductor in a
    # two-conductor case was still booting when its assertions ran — the harness racing
    # the property it exists to measure.
    before = claim_files(store).size
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-e", script, out: writer, err: File::NULL)
    writer.close
    wait_for_claim(reader, pid, store, before + 1)
    pid
  end

  def wait_for_claim(reader, pid, store, expected)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
    while claim_files(store).size < expected
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        kill!(pid)
        flunk "the conductor stand-in never published claim ##{expected} within #{BOOT_TIMEOUT}s"
      end
      sleep 0.05
    end
  ensure
    reader.close
  end

  def kill!(pid)
    return if pid.nil?

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def claim_files(store) = Dir.glob(File.join(store, ".agents", "sessions", "*.presence-*")).sort

  def read_claim(store, index: 0) = JSON.parse(File.read(claim_files(store).fetch(index)))

  # THE REAL READER — `bin/lib/agent_presence.rb#grade`, not a restatement of it.
  #
  # The earlier version of this helper reimplemented the rule over `cert_pid` ONLY, so it
  # structurally COULD NOT SEE the `:lane` (pgid) subject — which is exactly where the
  # defect lived (review, 2026-09-02). A grader that reads one subject cannot express a
  # two-subject bug, and this tier exists to catch precisely that. So call the shipped
  # reader and let it disagree with us.
  def grade(claim)
    AgentPresence.grade(lock: claim, table: CertOrphanGuard.process_table).first
  end

  # What the reader does with that grade — `:unverifiable` counts against capacity too,
  # so "not :live" is NOT the same question as "frees the machine".
  def counted?(claim)
    AgentPresence::COUNTED_GRADES.include?(grade(claim))
  end

  # WHAT A PEER ACTUALLY READS. The full shipped pipeline: glob, parse, grade, weigh,
  # collapse supervisors, subtract from capacity. Nothing here restates any of it.
  def headroom(store)
    AgentPresence.snapshot(root: store, load: nil)[:headroom]
  end

  # --- [integration] a real sweep, a real SIGKILL, a real process table ----------------

  def test_a_real_killed_sweep_leaves_a_claim_that_grades_dead_immediately
    with_store do |store, root|
      pid = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")
      claim = read_claim(store)

      assert_equal pid, claim["pid"]
      assert_equal :live, grade(claim),
                   "while the sweep runs, the reader must PROVE the claim is that process — " \
                   "identity is what lets a peer trust the phase and weight beside it"

      kill!(pid)

      refute_empty claim_files(store),
                   "SIGKILL runs no handler, so the claim MUST survive its writer. That is " \
                   "the design, not a leak: the file is the only local record naming the " \
                   "workload, and the reader is what decides it is a corpse"
      assert_equal :dead, grade(read_claim(store)),
                   "graded dead on the VERY NEXT read — no TTL to wait out. The house has paid " \
                   "twice for the alternative: a shift lease renewed by a UI paint reported a " \
                   "lane FREE while its holder worked, and renewers that outlived their work " \
                   "spent the account-wide 1Password cap"
    end
  end

  # THE ACCEPTANCE CRITERION, MEASURED AS THE NUMBER A PEER READS. Not "the grade flips"
  # but "the machine is handed back": a killed sweep must return its capacity on the very
  # next read, with nothing to wait for.
  def test_a_killed_sweeps_capacity_comes_back_on_the_next_read
    with_store do |store, root|
      assert_in_delta CAPACITY, headroom(store), 0.0001,
                      "baseline: an empty store is a free machine"

      pid = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare",
                            weight: ReleasePresence::WEIGHT_SUITE)

      assert_in_delta CAPACITY - 1.0, headroom(store), 0.0001,
                      "a sweep inside a suite must cost a peer a whole suite of headroom — " \
                      "this is the reading whose ABSENCE let a 45-minute run launch into a " \
                      "saturated box and die at its 2700s ceiling, 11% complete"

      kill!(pid)

      assert_in_delta CAPACITY, headroom(store), 0.0001,
                      "and a SIGKILL hands it straight back. No TTL, no renewal, no sweep to " \
                      "run — the corpse is self-evident to the process table, so the wedge " \
                      "window is ZERO"
    end
  end

  # THE PROPERTY THAT CHANGED WITH THE NAMESPACE, proved with two real processes.
  #
  # While the claim lived in the cert runlock slot there was ONE file per root, so a
  # `prepare` and a `ship` running at once contended for it: the second had to refuse
  # rather than clobber a live peer, and it published NOTHING — visible only through the
  # reader's backstop, as unattributed load. The marker namespace is keyed per process, so
  # both publish and BOTH are counted, and a peer reads the machine's real cost instead of
  # one conductor's half of it.
  def test_two_live_conductors_are_both_published_and_both_counted
    with_store do |store, root|
      sweep = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")
      ship  = spawn_conductor(store, root, kind: "ship", lane: "release:ship")

      assert_equal 2, claim_files(store).size,
                   "a prepare and a ship may legitimately run at once — neither has to lose " \
                   "its record to the other"
      kinds = claim_files(store).map { |f| JSON.parse(File.read(f))["kind"] }.sort

      assert_equal %w[ship sweep], kinds
      assert_in_delta CAPACITY - 0.5, headroom(store), 0.0001,
                      "and BOTH must be subtracted: two conductors at light weight cost 0.50. " \
                      "The old one-slot shape reported 0.25 — half the real cost — which is " \
                      "under-reporting, the expensive direction"
    ensure
      kill!(sweep)
      kill!(ship)
    end
  end

  # --- [integration] the claim may only name a subject its writer OWNS -----------------
  #
  # THIS IS THE TEST THAT CAUGHT THE FIRST BLOCKER, and every clause of it is chosen so
  # that it CANNOT pass by agreeing with itself:
  #
  #   * it grades with the REAL `AgentPresence.grade` (both subjects), not a helper that
  #     reads one pid and calls that the reader;
  #   * it spawns the conductor with NO `setpgrp`, exactly as `bin/release` runs, so the
  #     child inherits THIS RUNNER'S group;
  #   * the runner — the group's leader — is alive throughout and by construction outlives
  #     the child, which is the harness shape (`/bin/zsh -c …` wrapper) that made an
  #     inherited pgid read as a live claim forever.
  #
  # Against `PresenceClaim`'s own `Process.getpgid` default this fails: the killed sweep
  # grades :live via the group subject, COUNTED, with no TTL to expire — an unbounded
  # wedge, and the exact inverse of the rule this module is named for. That default is
  # right for `bin/ship`, which spawns its runner into its own group; it is wrong here.
  def test_a_killed_sweep_is_a_corpse_to_the_real_reader_not_just_to_its_own_helper
    with_store do |store, root|
      pid = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")
      claim = read_claim(store)

      assert_equal pid, claim["pgid"],
                   "the claim must name a process group its WRITER OWNS. `bin/release` " \
                   "never calls setpgrp, so recording its actual group names the LAUNCHING " \
                   "SHELL's group — shared with the rest of the session, which this process " \
                   "has no right to speak for"
      refute_equal Process.getpgrp, claim["pgid"],
                   "and it must NOT be the inherited group: this test runner leads that " \
                   "group and outlives the conductor, which is precisely how a corpse " \
                   "kept reading as live"

      kill!(pid)

      assert_equal :dead, grade(read_claim(store)),
                   "the REAL reader must call a killed sweep dead on the very next read. " \
                   "With the inherited pgid it returned :live via the group subject — " \
                   "the runner leading that group is still alive and its (pid, lstart) " \
                   "still matches — so the corpse counted against capacity forever"
      refute counted?(read_claim(store)),
             "and dead must mean UNCOUNTED, or the machine reports saturation that " \
             "no process is causing and every later suite is refused headroom"
    end
  end

  # THE REAPER CANNOT REACH THIS CLAIM, and that is now structural rather than argued.
  #
  # `CertOrphanGuard.preflight` reads ONE path — `<root>/.git/cert-run.json` — and SIGKILLs
  # the group whatever it finds there names. The earlier revision of this module wrote its
  # claim into exactly that path and defended it by rooting at a primary checkout, on the
  # theory that no cert ever preflights a primary. That theory was FALSE: `CertRootGuard`
  # is gated on a slug while the orphan preflight is unconditional, so the slug-less
  # `bin/full-suite-check --print` that `--install-hook` writes into `.git/hooks/pre-push`
  # preflights a primary happily.
  #
  # So the defence is the namespace, and this test states it as the reader's own comment
  # does: read here, reaped nowhere.
  def test_the_claim_is_invisible_to_the_reaper_that_reads_runlocks
    with_store do |store, root|
      pid = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")
      begin
        refute_empty claim_files(store), "the claim is published…"
        assert_nil CertOrphanGuard.read_lock(root),
                   "…and there is NOTHING in the runlock slot for a cert's preflight to find. " \
                   "This is the whole safety argument: preflight reads cert-run.json and only " \
                   "cert-run.json, so a claim outside it can never be graded :orphan and can " \
                   "never have reap_group pointed at the process group it names"
        refute_path_exists CertOrphanGuard.lock_path(root)
      ensure
        kill!(pid)
      end
    end
  end
end

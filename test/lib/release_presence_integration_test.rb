# frozen_string_literal: true

# THE KILLED-WRITER RULE, PROVED AGAINST A REAL KILL. The property: a SIGKILLed sweep is graded
# a corpse by the OS's own answer, with no timeout to elapse. A stand-in pid can only show the
# code path, so this tier spawns a REAL conductor stand-in, publishes through the REAL
# ReleasePresence, SIGKILLs it, and grades the survivor against a REAL `ps` with the REAL
# reader. It also pins `AgentPresence.snapshot` headroom before, during and after: a test
# asserting a weight constant passes when constant and expectation are edited together; headroom
# needs a claim on disk, live, graded and weighted correctly at that instant.
# History: task sweeps-publish-local-claim.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "shellwords"
require_relative "../../bin/lib/release_presence"
require_relative "../../bin/lib/process_table"
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

  # A conductor stand-in: a real claim through the real module, then an unbounded sleep, so the
  # only way this test ends it is the kill it is here to prove.
  # IT DELIBERATELY DOES NOT CALL `Process.setpgrp`: `bin/release` calls it NOWHERE and inherits
  # its caller's group. Spawned plainly, the child inherits THIS TEST RUNNER'S group.
  # AND IT HOLDS NO PIPE: /dev/null for stdout, a LOG FILE for stderr. With an `IO.pipe` the child
  # can take SIGPIPE and die a zombie, `ProcessTable.live_process` excludes zombies, and headroom
  # reads wrong: a flake inside a timing band, invisible outside it.
  # History: task sweeps-publish-local-claim.
  def spawn_conductor(store, root, kind:, lane:, weight: nil, boot_delay: nil,
                      die_after_publish: false, timeout: BOOT_TIMEOUT)
    weight_arg = weight ? ", weight: #{weight.inspect}" : ""
    script = <<~RB
      #{boot_delay ? "sleep #{boot_delay}" : ""}
      require #{LIB.inspect}
      ReleasePresence.open!(kind: #{kind.inspect}, root: #{root.inspect}, lane: #{lane.inspect},
                            projects_dir: #{store.inspect}, session_id: "conductor-#{kind}"#{weight_arg},
                            env: { "TASK_USAGE_SANDBOX" => "0" })
      #{die_after_publish ? "exit!(0)" : "sleep"}
    RB
    log = conductor_log(store, kind)
    pid = Process.spawn(RbConfig.ruby, "-e", script, out: File::NULL, err: [log, "w"])
    await_live_claim(pid, store, kind: kind, timeout: timeout, log: log)
    pid
  end

  # A distinct stderr log per stand-in, so a boot failure is READABLE instead of
  # discarded. It lives beside the store rather than inside `.agents/sessions/`, where
  # the readers' glob would meet it.
  def conductor_log(store, kind)
    @spawned = (@spawned || 0) + 1
    File.join(store, "conductor-#{kind}-#{@spawned}.err")
  end

  # THE POSTCONDITION IS THE CLAIM GRADING LIVE, NOT A FILE COUNT. A CLAIM OUTLIVES ITS WRITER, so
  # "a second file appeared" is satisfied by a corpse as well as by a live conductor. Ask the
  # question: does `AgentPresence.grade`, the shipped reader, call this conductor LIVE yet? This
  # refuses to return "published but not live" whatever caused it. Under-reporting is the
  # expensive direction (see `test_two_live_conductors_are_both_published_and_both_counted`), so a
  # harness that can under-report silently simulates the bug it guards, and invites a re-run over
  # a real regression.
  # History: task conductor-presence-test-races-publish.
  def await_live_claim(pid, store, kind:, timeout:, log: nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    suffix = ".presence-#{kind}-#{pid}"
    loop do
      mine = claim_files(store).find { |f| File.basename(f).end_with?(suffix) }
      # A bare parse, for the reason `claim_files` states: the writer publishes through a
      # dotfile sibling, so nothing this glob returns is ever mid-write.
      return pid if mine && grade(JSON.parse(File.read(mine))) == :live
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
    end
    flunk_unpublished(pid, store, kind: kind, suffix: suffix, timeout: timeout, log: log)
  end

  # FAIL LOUDLY, AND NAME WHICH OF THE TWO THINGS WENT WRONG. "It never published" and
  # "it published and then died" are different defects with different fixes, and a
  # message that says only "timed out" sends the next reader to re-run instead of to the
  # cause. So this prints every marker that DID land, this conductor's own grade, its
  # `ps` row (a `Z` state is the tell — the stand-in died after publishing and something
  # in this harness killed it), and whatever it wrote to stderr.
  def flunk_unpublished(pid, store, kind:, suffix:, timeout:, log:)
    landed = claim_files(store).map { |f| File.basename(f) }
    mine = landed.find { |f| f.end_with?(suffix) }
    row = ProcessTable.process_table.find { |p| p[:pid] == pid }
    stderr = log && File.exist?(log) ? File.read(log).strip : ""
    # GRADE BEFORE THE KILL. This read used to sit inside the heredoc below, which `flunk`
    # evaluates AFTER `kill!` has SIGKILLed and reaped the child — so it printed `dead` for
    # every conductor whose marker had landed, including one alive the whole time that timed
    # out for some other reason. Measured in review: a healthy stand-in read "graded dead"
    # beside a ps row of "S", and the `Z` in that row was doing the whole diagnosis alone.
    mine_grade = mine && grade(JSON.parse(File.read(File.join(store, ".agents", "sessions", mine))))
    kill!(pid)
    flunk <<~MSG.strip
      conductor #{kind} (pid #{pid}) never published a claim the real reader grades :live, \
      within #{timeout}s.
        its own marker: #{mine ? "#{mine} — graded #{mine_grade}" : "NEVER LANDED"}
        markers that landed (#{landed.size}): #{landed.inspect}
        its ps row: #{row ? row.slice(:pid, :pgid, :state).inspect : "ABSENT from the process table"}
        its stderr: #{stderr.empty? ? "(none)" : stderr}
    MSG
  end

  def kill!(pid)
    return if pid.nil?

    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # THE READERS' GLOB, spelled as the shipped reader spells it, and the PARSE BELOW IS BARE ON
  # PURPOSE. Production rescues `JSON::ParserError` to `:malformed`
  # (bin/lib/agent_presence.rb#read_claim) because a reader racing a writer must degrade; this
  # tier must do the OPPOSITE, so an unparseable claim is a named error. The writer publishes
  # through a DOTFILE sibling, so nothing this glob returns is ever mid-write; if that regresses,
  # this line is the alarm and it stays loud.
  # History: task presence-glob-catches-temp-sibling.
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
    AgentPresence.grade(lock: claim, table: ProcessTable.process_table).first
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

  # --- [control] the harness's own wait, proved to bite ---------------------------------
  #
  # THESE THREE EXIST BECAUSE A GREEN RUN PROVES NOTHING HERE. The flake they close was
  # timing-dependent: it passed 5/5 locally at the failing head and 0/10 on this box with
  # the child idle. A fix for a race that is only ever exercised by the race is a fix
  # nobody can read a verdict from — so each of these MAKES the race happen and asserts
  # the new postcondition answers it. `spawn_conductor`'s `boot_delay:` and
  # `die_after_publish:` exist for these and for nothing else.

  # The card's control: SLOW THE SECOND PUBLISH and show the wait still reaches two live
  # conductors. On a harness that does not wait, this reds one assertion EARLIER than the
  # arithmetic — at the marker count, 0 of 2 — because a spawn-and-return harness has put
  # NEITHER conductor on disk yet. The headroom line below guards the other shape: one
  # conductor counted of two, whatever stopped the other from grading live.
  def test_control_a_slow_second_publish_still_reaches_two_live_conductors
    with_store do |store, root|
      sweep = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")
      ship  = spawn_conductor(store, root, kind: "ship", lane: "release:ship", boot_delay: 0.75)

      assert_equal 2, claim_files(store).size,
                   "the wait must not return until the SLOW conductor's own marker landed"
      assert_in_delta CAPACITY - 0.5, headroom(store), 0.0001,
                      "and both must still be subtracted. One counted of two reads 2.75 — " \
                      "under-reporting, the expensive direction, and the exact number the " \
                      "CI red carried"
    ensure
      kill!(sweep)
      kill!(ship)
    end
  end

  # THE REGRESSION GUARD FOR THE DEFECT ITSELF. A conductor that publishes and then dies
  # leaves exactly what a SIGKILLed one leaves — a marker on disk and a corpse — which is
  # why a file-counting wait returned it happily and let the ambiguity surface three
  # assertions later as a wrong number. The wait must refuse it HERE, and say which of
  # the two things went wrong.
  def test_control_a_conductor_that_dies_after_publishing_fails_the_wait_loudly
    with_store do |store, root|
      error = assert_raises(Minitest::Assertion) do
        spawn_conductor(store, root, kind: "sweep", lane: "release:prepare",
                        die_after_publish: true, timeout: 1.0)
      end

      assert_match(/never published a claim the real reader grades :live/, error.message)
      assert_match(/its own marker: .*\.presence-sweep-\d+ — graded dead/, error.message,
                   "the message must distinguish 'published and then died' from 'never " \
                   "published' — they are different defects with different fixes, and a " \
                   "bare 'timed out' sends the next reader to re-run instead of to the cause")
      assert_match(/markers that landed \(1\)/, error.message)
      # `"Z` unterminated on purpose: the state is stored RAW (`ProcessTable.parse_ps_line`)
      # and Linux renders a zombie `Z+`/`Zs`, which is why production asks `start_with?("Z")`.
      assert_match(/its ps row: .*"Z/, error.message,
                   "and the Z state is the tell the comment above promises. Without this the " \
                   "grade carried the claim alone, and the grade is true of ANY published " \
                   "marker once its writer has been killed")
    end
  end

  # AND THE BOUND ITSELF, with the other half of the message proved: a PEER's marker does
  # not satisfy this conductor's wait. That was the earlier bug in this helper (waiting on
  # "a file" rather than on its own), and the count it prints is what names it.
  def test_control_the_bounded_timeout_fails_with_the_markers_that_did_land
    with_store do |store, root|
      sweep = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")

      error = assert_raises(Minitest::Assertion) do
        # Publishes eventually, but not inside the bound — so the wait must expire rather
        # than accept the sweep's marker sitting right beside it.
        spawn_conductor(store, root, kind: "ship", lane: "release:ship",
                        boot_delay: 30, timeout: 1.0)
      end

      assert_match(/its own marker: NEVER LANDED/, error.message)
      assert_match(/markers that landed \(1\)/, error.message,
                   "a peer's marker is named, never counted as this conductor's")
      assert_match(/within 1\.0s/, error.message)
    ensure
      kill!(sweep)
    end
  end

  # --- [integration] the claim may only name a subject its writer OWNS -----------------
  # Every clause is chosen so it CANNOT pass by agreeing with itself: it grades with the REAL
  # `AgentPresence.grade` (both subjects); it spawns with NO `setpgrp`, as `bin/release` runs, so
  # the child inherits THIS RUNNER'S group; and the runner, the group's leader, outlives the
  # child. Against `PresenceClaim`'s own `Process.getpgid` default this fails: the killed sweep
  # grades :live via the group subject, with no TTL to expire. That default is right for
  # `bin/submit`, which spawns its runner into its own group; it is wrong here.
  # History: task sweeps-publish-local-claim.
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

  # THE CLAIM LIVES OUTSIDE THE RETIRED RUNLOCK SLOT. The cert orphan guard that once
  # SIGKILLed the group `<root>/.git/cert-run.json` named retired with the local certs
  # (DevOps v3 phase 2b); the namespace stays because one file per PROCESS has no
  # shared slot to contend for, and this pins that nothing writes the old slot.
  def test_the_claim_lives_outside_the_retired_runlock_slot
    with_store do |store, root|
      pid = spawn_conductor(store, root, kind: "sweep", lane: "release:prepare")
      begin
        refute_empty claim_files(store), "the claim is published…"
        refute_path_exists File.join(root, ".git", "cert-run.json"),
                           "…and NOTHING lands in the retired runlock slot"
      ensure
        kill!(pid)
      end
    end
  end
end

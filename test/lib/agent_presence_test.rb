# frozen_string_literal: true

# [unit] bin/lib/agent_presence.rb — the presence READER's grader, backstop and copy.
#
# Slice 1 of docs/agents/system/agent-presence.md. What this tier is for: `grade`
# reads no clock, no process table and no disk — it takes a SNAPSHOT — so every
# vector below is provable without spawning anything. The claims that can only be
# made against real processes (a killed writer grades dead with no wait; an IDLE
# live process does not grade dead) are made in the integration tier, by kill:
#   test/lib/agent_presence_integration_test.rb
#
# THE BUG CLASS THIS FILE EXISTS FOR. `ps aux | grep -E "fast-check|rails test"` is
# the check this reader replaces, and it is correct BY COINCIDENCE of naming. It
# has already cost: two idle `bin/ship` processes in a CI wait read as competing
# certs and nearly held off a launch, and a 45-minute run was lost to a sweep that
# no status command reports. So the assertions here are about the two directions of
# error separately — a corpse must never be counted, and a live thing must never be
# missed — because a reader that gets only one of those right starves someone.
#
#   ruby -Itest test/lib/agent_presence_test.rb

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/agent_presence"

class AgentPresenceTest < Minitest::Test
  START_A = "Tue Sep  1 11:05:12 2026"
  START_B = "Tue Sep  1 09:00:00 2026"

  def proc_row(pid:, pgid: nil, state: "S", started_at: START_A, command: "ruby bin/rails test")
    { pid: pid, pgid: pgid || pid, state: state, started_at: started_at, command: command }
  end

  def lock(cert_pid: 100, pgid: 200, cert_started_at: START_A, pgid_started_at: START_A,
           lane: "mapped-tests", db: "ms_test", started_at: "2026-09-01T17:05:12Z", **rest)
    {
      "cert_pid" => cert_pid, "pgid" => pgid,
      "cert_started_at" => cert_started_at, "pgid_started_at" => pgid_started_at,
      "lane" => lane, "db" => db, "started_at" => started_at
    }.merge(rest)
  end

  # --- the five grades ---------------------------------------------------------------

  def test_live_when_cert_pid_is_alive_and_its_start_time_matches_exactly
    table = [proc_row(pid: 100), proc_row(pid: 200)]
    verdict, detail = AgentPresence.grade(lock: lock, table: table)

    assert_equal :live, verdict
    assert_equal :cert, detail[:subject]
  end

  # THE ORPHAN, and the most important row in this file. The cert supervisor can be
  # killed while the suite it spawned SURVIVES — reparented to launchd, still holding
  # the test DB. That orphan is precisely the thing that saturates the machine and
  # starves the next agent, so a reader that graded only `cert_pid` would report the
  # single worst real case as DEAD and wave the next suite straight into it.
  def test_live_when_the_cert_is_dead_but_its_orphaned_lane_group_survives
    table = [proc_row(pid: 200)] # the cert (100) is gone; the lane lives on
    verdict, detail = AgentPresence.grade(lock: lock, table: table)

    assert_equal :live, verdict
    assert_equal :lane, detail[:subject]
  end

  def test_dead_when_nothing_is_alive_at_either_subject
    assert_equal :dead, AgentPresence.grade(lock: lock, table: [])[0]
  end

  # A pid is a recyclable integer, so liveness is NOT identity. Something answering
  # to that number with a different start time is a stranger — proven innocent.
  def test_recycled_when_both_pids_are_alive_but_started_at_another_time
    table = [proc_row(pid: 100, started_at: START_B), proc_row(pid: 200, started_at: START_B)]
    verdict, detail = AgentPresence.grade(lock: lock, table: table)

    assert_equal :recycled, verdict
    refute_nil detail[:found]
  end

  def test_unverifiable_when_a_pid_is_alive_but_the_lock_recorded_no_start_time
    table = [proc_row(pid: 100), proc_row(pid: 200)]
    verdict, = AgentPresence.grade(
      lock: lock(cert_started_at: nil, pgid_started_at: nil), table: table
    )

    assert_equal :unverifiable, verdict
  end

  def test_malformed_when_the_lock_names_no_pid_at_all
    assert_equal :malformed, AgentPresence.grade(lock: { "lane" => "x" }, table: [])[0]
    assert_equal :malformed, AgentPresence.grade(lock: { "cert_pid" => {}, "pgid" => [] }, table: [])[0]
  end

  # A lock naming ONE usable pid still identifies somebody, so it is graded on that
  # one rather than discarded. The design's rule is "names no pid" → malformed, and
  # discarding a half-written lock that names a LIVE suite is the expensive direction.
  def test_a_lock_with_only_a_lane_pid_is_graded_not_discarded
    verdict, = AgentPresence.grade(lock: lock(cert_pid: nil), table: [proc_row(pid: 200)])

    assert_equal :live, verdict
  end

  # --- liveness edges ----------------------------------------------------------------

  # A zombie holds no DB connection and cannot be killed. Counting one as alive is how
  # a reader reports a corpse as a running suite forever.
  def test_a_zombie_is_not_alive
    table = [proc_row(pid: 100, state: "Z+"), proc_row(pid: 200, state: "Z")]

    assert_equal :dead, AgentPresence.grade(lock: lock, table: table)[0]
  end

  # The lane LEADER can exit while its children keep running — the group is still
  # burning the machine, and no start time can prove the group is ours.
  def test_group_members_outliving_their_leader_are_alive_and_unverifiable
    table = [proc_row(pid: 555, pgid: 200)] # a child of group 200; leader 200 is gone
    verdict, detail = AgentPresence.grade(lock: lock(pgid_started_at: nil), table: table)

    assert_equal :unverifiable, verdict
    assert_equal 1, detail[:members]
  end

  # --- precedence: live > unverifiable > recycled > dead ------------------------------
  #
  # Ordered so proof of life beats inability to prove, which beats proof of innocence.
  # Every tie breaks toward over-reporting cost: over-reporting buys delay, and
  # under-reporting buys a saturated machine and a lost 45-minute run.

  def test_a_recycled_cert_pid_never_masks_a_provably_live_lane
    table = [proc_row(pid: 100, started_at: START_B), proc_row(pid: 200, started_at: START_A)]

    assert_equal :live, AgentPresence.grade(lock: lock, table: table)[0]
  end

  def test_an_unprovable_subject_outranks_a_recycled_one
    table = [proc_row(pid: 100, started_at: START_B), proc_row(pid: 200)]

    assert_equal :unverifiable, AgentPresence.grade(lock: lock(pgid_started_at: nil), table: table)[0]
  end

  # --- weight and phase ---------------------------------------------------------------

  def test_a_cert_runlock_weighs_one_full_suite_by_default
    assert_in_delta 1.0, AgentPresence.weight_of(lock), 0.001
    assert_equal "working", AgentPresence.phase_of(lock)
  end

  # Cost #4 in the design: a process parked in a CI wait consumes nothing. No writer
  # publishes `phase` yet — honoring it now means the reader is already right when one does.
  def test_a_waiting_claim_consumes_no_capacity
    assert_in_delta 0.0, AgentPresence.weight_of(lock("phase" => "waiting")), 0.001
  end

  def test_an_unknown_weight_class_costs_a_full_unit_rather_than_zero
    assert_in_delta 1.0, AgentPresence.weight_of(lock("weight" => "gargantuan")), 0.001
  end

  # --- capacity accounting -------------------------------------------------------------

  def test_unverifiable_claims_are_counted_toward_consumed_capacity
    claims = [
      { grade: :unverifiable, weight: 1.0 },
      { grade: :live, weight: 1.0 },
      { grade: :dead, weight: 1.0 },
      { grade: :recycled, weight: 1.0 },
      { grade: :malformed, weight: 0.0 }
    ]

    assert_in_delta 2.0, AgentPresence.consumed(claims), 0.001
  end

  def test_suite_capacity_is_overridable_for_calibration_on_another_box
    assert_in_delta 3.0, AgentPresence.suite_capacity({}), 0.001
    assert_in_delta 8.0, AgentPresence.suite_capacity({ "AGENT_PRESENCE_SUITE_CAPACITY" => "8" }), 0.001
    # Garbage must not silently become zero capacity, which would report BUSY forever.
    assert_in_delta 3.0, AgentPresence.suite_capacity({ "AGENT_PRESENCE_SUITE_CAPACITY" => "nonsense" }), 0.001
    assert_in_delta 3.0, AgentPresence.suite_capacity({ "AGENT_PRESENCE_SUITE_CAPACITY" => "0" }), 0.001
  end
  # --- the backstop --------------------------------------------------------------------
  #
  # §7: the reader must NEVER print "idle" as a conclusion drawn from an empty directory.
  # With every claim missing it degrades to today's grep PLUS honesty about what it could
  # not attribute — which is strictly more than the grep offers.

  def test_a_heavy_process_sharing_a_live_claims_group_is_attributed_not_reported
    claims = [{ grade: :live, pgid: 200, cert_pid: 100 }]
    table = [proc_row(pid: 201, pgid: 200, command: "ruby bin/rails test")]

    assert_empty AgentPresence.backstop(table: table, claims: claims, self_pid: 1, self_pgid: 1)
  end

  # A CORPSE ATTRIBUTES NOTHING. If a dead claim could vouch for a live process, a
  # stale lock would launder real load into "accounted for" — the exact silence this
  # surface exists to end.
  def test_a_dead_claims_pgid_does_not_attribute_a_live_heavy_process
    claims = [{ grade: :dead, pgid: 200, cert_pid: 100 }]
    table = [proc_row(pid: 201, pgid: 200, command: "ruby bin/rails test")]
    found = AgentPresence.backstop(table: table, claims: claims, self_pid: 1, self_pgid: 1)

    assert_equal 1, found.size
    assert_equal :suite, found.first[:kind]
  end

  # A cert spawns each lane into a NEW process group, so the runlock's `pgid` names the
  # LANE and says nothing about the group the cert supervisor runs in. Observed live: a
  # runlock naming cert_pid 37252 while 37252 ran in pgid 37248 — its `/bin/zsh -c …`
  # wrapper's group. The wrapper carries the whole command in its argv, so it matched the
  # heavy patterns and was reported UNATTRIBUTED beside the claim naming its own child.
  def test_the_cert_supervisors_own_group_is_attributed_not_just_the_lane_group
    claims = [{ grade: :live, pgid: 37_411, cert_pid: 37_252 }]
    table = [
      proc_row(pid: 37_252, pgid: 37_248, command: "ruby bin/fast-check some-task"),
      proc_row(pid: 37_248, pgid: 37_248, command: "/bin/zsh -c source /x && ruby bin/fast-check some-task")
    ]

    assert_empty AgentPresence.backstop(table: table, claims: claims, self_pid: 1, self_pgid: 1),
                 "the wrapper that launched a claimed cert is covered by that cert's claim"
  end

  # ...but only through a LIVE claim. A corpse's group vouches for nothing.
  def test_a_dead_claims_cert_group_does_not_attribute_anything
    claims = [{ grade: :dead, pgid: 37_411, cert_pid: 37_252 }]
    table = [
      proc_row(pid: 37_252, pgid: 37_248, command: "ruby bin/fast-check some-task"),
      proc_row(pid: 37_248, pgid: 37_248, command: "/bin/zsh -c source /x && ruby bin/fast-check some-task")
    ]

    assert_equal 1, AgentPresence.backstop(table: table, claims: claims, self_pid: 1, self_pgid: 1).size
  end

  def test_the_reader_never_reports_itself_as_unattributed_load
    table = [proc_row(pid: 42, pgid: 7, command: "ruby bin/rails test")]

    assert_empty AgentPresence.backstop(table: table, claims: [], self_pid: 42, self_pgid: 99)
    assert_empty AgentPresence.backstop(table: table, claims: [], self_pid: 1, self_pgid: 7)
  end

  # A shell wrapper carries the WHOLE command it is about to run in its own argv, so it
  # matches every pattern its child does. Reporting both double-counts one workload — and
  # the wrapper is the LEAST informative of the two, while its distinguishing tail is
  # exactly what a truncated row drops.
  def test_a_shell_wrapper_and_its_child_collapse_to_one_row_led_by_the_real_command
    table = [
      proc_row(pid: 10, pgid: 10, command: "/bin/zsh -c source /Users/alex/.claude/snapshot-zsh-178 && npm exec playwright test"),
      proc_row(pid: 11, pgid: 10, command: "npm exec playwright test")
    ]
    found = AgentPresence.backstop(table: table, claims: [], self_pid: 1, self_pgid: 1)

    assert_equal 1, found.size
    assert_equal "npm exec playwright test", found.first[:command]
    assert_equal 2, found.first[:processes]
  end

  def test_ordinary_processes_are_not_mistaken_for_heavy_ones
    table = [proc_row(pid: 10, command: "ruby bin/rails server"), proc_row(pid: 11, command: "Google Chrome Helper")]

    assert_empty AgentPresence.backstop(table: table, claims: [], self_pid: 1, self_pgid: 1)
  end

  # --- verdict and exit codes ------------------------------------------------------------

  def test_unattributed_load_is_busy_not_clear
    verdict = AgentPresence.verdict_for(degraded: false, headroom: 3.0, unattributed: [{ pid: 1 }])

    assert_equal "busy", verdict, "load this reader cannot name is not permission to start"
  end

  def test_no_headroom_is_busy_and_a_quiet_machine_is_clear
    assert_equal "busy", AgentPresence.verdict_for(degraded: false, headroom: 0.0, unattributed: [])
    assert_equal "clear", AgentPresence.verdict_for(degraded: false, headroom: 1.0, unattributed: [])
  end

  # A reader that graded nothing must say UNKNOWN. "I could not look" is not "nothing
  # is running" — and non-zero means unknown, which is today's state.
  def test_an_unavailable_process_table_is_unknown_never_clear
    assert_equal "unknown", AgentPresence.verdict_for(degraded: true, headroom: 3.0, unattributed: [])
    assert_equal 3, AgentPresence.exit_code({ verdict: "unknown" })
    assert_equal 1, AgentPresence.exit_code({ verdict: "busy" })
    assert_equal 0, AgentPresence.exit_code({ verdict: "clear" })
  end

  # --- the copy, which is a safety property here -------------------------------------------
  #
  # An unread surface answers nothing, and a surface that says "idle" when it means "I
  # found no file" answers WORSE than nothing. These assert on the words because the
  # words are what an agent acts on.

  def test_an_empty_claim_directory_is_never_rendered_as_idle
    snapshot = AgentPresence.snapshot(root: "/nonexistent-root", table: [], load: nil)
    text = AgentPresence.render(snapshot)

    refute_match(/idle/i, text)
    assert_match(/UNKNOWN/, text)
  end

  def test_a_readable_but_empty_machine_reports_absence_of_claims_not_absence_of_load
    table = [proc_row(pid: 9, command: "sshd")]
    snapshot = AgentPresence.snapshot(root: "/nonexistent-root", table: table, load: nil)
    text = AgentPresence.render(snapshot)

    refute_match(/idle/i, text)
    assert_match(/none live/, text)
    assert_match(/no heavy process is running without a claim/, text)
  end

  # The session store never garbage-collects: 747 records reaching back to June, 4
  # touched in a representative day. A lister that prints 743 dead rows beside 4 live
  # ones is one an agent stops reading.
  def test_stale_corpses_are_summarized_while_live_claims_are_never_suppressed_by_age
    claims = [
      { grade: :dead, age_seconds: 90 * 24 * 3600, weight: 0.0 },
      { grade: :live, age_seconds: 90 * 24 * 3600, weight: 1.0, repo: "ms", desk: "d", lane: "l", cert_pid: 1, pgid: 2 }
    ]
    shown, hidden = AgentPresence.partition_for_display(claims, AgentPresence::STALE_AFTER_SECONDS)

    assert_equal 1, hidden
    assert_equal 1, shown.size
    assert_equal :live, shown.first[:grade], "a two-day-old suite is the most important row on the page"
  end

  def test_an_unverifiable_row_names_itself_rather_than_passing_as_ordinary
    row = AgentPresence.claim_row(
      { grade: :unverifiable, repo: "ms", desk: "d", lane: "l", cert_pid: 1, pgid: 2,
        age_seconds: 10, subject: :cert }
    )

    assert_match(/UNPROVABLE/, row)
    assert_match(/counted/, row)
  end
  # --- supervisor claims: the OTHER writer, and the arithmetic that keeps one -------
  # --- workload counted ONCE -------------------------------------------------------
  #
  # `bin/ship` publishes a claim of its own (bin/lib/presence_claim.rb) because it
  # SPANS both states — it certifies, then it waits on CI — and the process name is
  # identical in both. Measured live on 2026-09-01: five ship groups, all at 0.0%
  # CPU, all reported UNATTRIBUTED and the machine called BUSY; four were parked in
  # a CI wait costing nothing and the fifth was eleven seconds into a real suite.

  def supervisor(pid: 300, pgid: 300, kind: "ship", phase: "waiting", weight: "idle",
                 pid_started_at: START_A, pgid_started_at: START_A, **rest)
    {
      "schema_version" => 1, "kind" => kind, "phase" => phase, "weight" => weight,
      "pid" => pid, "pid_started_at" => pid_started_at,
      "pgid" => pgid, "pgid_started_at" => pgid_started_at,
      "started_at" => "2026-09-01T17:05:12Z", "root" => "/p/mcritchie-studio/.worktrees/d",
      "repo" => "mcritchie-studio"
    }.merge(rest)
  end

  # THE NORMALIZER. A runlock spells the supervisor subject `cert_pid`; a ship claim
  # spells it `pid`, because a ship is not a cert and a record that borrowed the
  # other's name would state something false about itself. The grader must read both.
  def test_a_supervisor_claim_grades_live_under_its_own_vocabulary
    table = [proc_row(pid: 300, pgid: 300)]
    verdict, detail = AgentPresence.grade(lock: supervisor, table: table)

    assert_equal :live, verdict, "a ship claim names its subject `pid`, and the grader must see it"
    assert_equal 300, detail[:cert_pid]
    assert_equal START_A, detail[:cert_started_at]
  end

  def test_a_supervisor_claim_whose_pid_is_gone_grades_dead_with_no_timeout
    assert_equal :dead, AgentPresence.grade(lock: supervisor(pgid: nil), table: [])[0]
  end

  # The second subject earning its place: the ship is gone, the cert it spawned is
  # still in its group holding the test DB. A single-subject claim would report the
  # WORST case as dead.
  def test_a_killed_supervisor_whose_group_survives_is_still_counted
    table = [proc_row(pid: 301, pgid: 300, command: "ruby bin/fast-check x")]
    verdict, = AgentPresence.grade(lock: supervisor(pid: 300, pgid: 300), table: table)

    refute_equal :dead, verdict,
                 "the supervisor died but its suite lives on in the group — reporting that dead " \
                 "is the one direction this design may never fail in"
  end

  # --- the dedupe ------------------------------------------------------------------

  def counted(kind:, weight:, cert_pid:, path:)
    { path: path, kind: kind, grade: :live, weight: AgentPresence::WEIGHTS.fetch(weight),
      cert_pid: cert_pid }
  end

  def test_a_ship_and_the_runlock_inside_its_group_are_ONE_workload
    table = [proc_row(pid: 300, pgid: 300), proc_row(pid: 400, pgid: 300)]
    claims = [
      counted(kind: "ship", weight: "suite", cert_pid: 300, path: "/p/.agents/sessions/s.presence-ship-300"),
      counted(kind: "cert", weight: "suite", cert_pid: 400, path: "/p/ms/.git/cert-run.json")
    ]

    assert_in_delta 1.0, AgentPresence.consumed(claims, table: table), 0.001,
                    "one suite is running; counting the ship AND its own child's runlock is a " \
                    "double count, and a headroom number somebody will calibrate against"
  end

  # The window the over-report exists for: 2/8 has fired, the lane's runlock has not
  # appeared yet (~11s measured), and the ship's claim is the ONLY thing on disk
  # saying a suite is starting.
  def test_a_ship_whose_runner_has_not_appeared_keeps_its_full_weight
    table = [proc_row(pid: 300, pgid: 300)]
    claims = [counted(kind: "ship", weight: "suite", cert_pid: 300,
                      path: "/p/.agents/sessions/s.presence-ship-300")]

    assert_in_delta 1.0, AgentPresence.consumed(claims, table: table), 0.001,
                    "nothing else is counting this suite yet, so the supervisor must"
  end

  # THE RULE IS NOT "collapse claims sharing a pgid", and this is why. Two independent
  # certs launched from one shell share a group; collapsing them would delete a real
  # suite from the arithmetic, which is the expensive direction.
  def test_two_independent_certs_in_one_group_are_NOT_collapsed
    table = [proc_row(pid: 400, pgid: 300), proc_row(pid: 500, pgid: 300)]
    claims = [
      counted(kind: "cert", weight: "suite", cert_pid: 400, path: "/p/a/.git/cert-run.json"),
      counted(kind: "cert", weight: "suite", cert_pid: 500, path: "/p/b/.git/cert-run.json")
    ]

    assert_in_delta 2.0, AgentPresence.consumed(claims, table: table), 0.001,
                    "two suites are two suites — the collapse is only ever supervisor-over-runner"
  end

  def test_a_ship_and_a_cert_in_DIFFERENT_groups_both_count
    table = [proc_row(pid: 300, pgid: 300), proc_row(pid: 400, pgid: 900)]
    claims = [
      counted(kind: "ship", weight: "suite", cert_pid: 300, path: "/p/.agents/sessions/s.presence-ship-300"),
      counted(kind: "cert", weight: "suite", cert_pid: 400, path: "/p/ms/.git/cert-run.json")
    ]

    assert_in_delta 2.0, AgentPresence.consumed(claims, table: table), 0.001,
                    "a ship certifying here and someone else's suite over there are two workloads"
  end

  # Without a table nothing can be resolved to a group, so nothing is collapsed —
  # the over-reporting side, which is the side every error here is arranged to land on.
  def test_with_no_process_table_nothing_is_collapsed
    claims = [
      counted(kind: "ship", weight: "suite", cert_pid: 300, path: "/p/.agents/sessions/s.presence-ship-300"),
      counted(kind: "cert", weight: "suite", cert_pid: 400, path: "/p/ms/.git/cert-run.json")
    ]

    assert_in_delta 2.0, AgentPresence.consumed(claims), 0.001
  end

  # --- the phase, which is what the whole slice is for ------------------------------

  def test_a_waiting_supervisor_consumes_nothing
    table = [proc_row(pid: 300, pgid: 300)]
    claims = [counted(kind: "ship", weight: "idle", cert_pid: 300,
                      path: "/p/.agents/sessions/s.presence-ship-300").merge(phase: "waiting")]

    assert_in_delta 0.0, AgentPresence.consumed(claims, table: table), 0.001,
                    "a ship parked in its CI wait costs NOTHING — reading it as a competing cert " \
                    "is the defect this slice removes"
  end

  # BEHAVIOURAL, not a string match on the pattern. Asserting the glob TEXT proves
  # the text is present, not that it matches a real filename — and "the reader was
  # one glob short" is exactly the defect this hop repairs, so the assertion has to
  # be that a file on disk is FOUND. (The full end-to-end read, through the real
  # writer and a real `ps`, is in agent_presence_integration_test.rb.)
  def test_the_reader_globs_the_session_marker_namespace
    Dir.mktmpdir do |root|
      dir = File.join(root, ".agents", "sessions")
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "sess.presence-ship-300")
      File.write(path, JSON.generate(supervisor))

      assert_includes AgentPresence.send(:claim_paths, root), path,
                      "a claim the reader cannot see closes no cost"
    end
  end

end

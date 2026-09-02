# frozen_string_literal: true

# [unit] Tests for bin/lib/presence_claim.rb — the WRITER half of the
# agent-presence surface (docs/agents/system/agent-presence.md, slice 3).
#
#   ruby -Itest test/lib/presence_claim_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# WHAT IS ACTUALLY UNDER TEST, and it is not "does it write a file". The design's
# governing rule is:
#
#   No claim asserts its own liveness. Every claim carries the OS's proof of
#   identity, and the READER decides.
#
# So the properties that matter here are (1) the record carries a pid AND the OS's
# own start time for it, because without both a reader cannot tell "our process"
# from "a stranger who inherited the number"; (2) a phase change REWRITES one file
# rather than leaving a trail of contradicting claims; and (3) the store guard is
# on the path, because a writer that reached the operator's live store from a test
# run is the leak TaskUsageSandbox exists to close.
#
# The killed-writer rule is asserted at the integration tier, in
# test/lib/ship_test.rb, where a real ship is really SIGKILLed.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require "time"
require_relative "../support/session_env"

require File.expand_path("../../bin/lib/presence_claim", __dir__)

class PresenceClaimTest < Minitest::Test
  SESSION = "b41d7c02-0000-4000-8000-0123456789ab"
  ON = { "TASK_USAGE_SANDBOX" => "1" }.freeze
  OFF = { "TASK_USAGE_SANDBOX" => "0" }.freeze

  # ── the identity proof ──────────────────────────────────────────────────────

  # The whole design rests on this pair. A pid alone is a recyclable integer, so a
  # reader holding only a pid cannot distinguish a live claim from a corpse whose
  # number was handed to a stranger — which is how CertOrphanGuard once killed an
  # unrelated bystander. `started_at` is the OS's own rendering of the start time,
  # and it is what makes (pid, started_at) name a PROCESS rather than a slot.
  def test_unit_the_record_carries_the_pid_and_the_OSs_start_time_for_it
    with_claim do |claim, _dir|
      record = claim.body

      assert_equal Process.pid, record["pid"]
      refute_nil record["pid_started_at"], "a claim with no start time can prove nothing about itself"
      assert_equal CertOrphanGuard.process_started_at(Process.pid), record["pid_started_at"],
                   "the start time must be the OS's, read for THIS process — not a clock we kept"
    end
  end

  # THE SECOND SUBJECT, and the reason the runlock has always carried two. A
  # supervisor can be SIGKILLed while the work it spawned survives — reparented,
  # still burning the machine, still holding a test DB — and a claim naming only the
  # supervisor reports that worst case as `dead`, which is the single direction this
  # design may never fail in. bin/ship spawns its cert with `system` and no
  # `pgroup:`, so the runner lives in the ship's own group; the group is therefore
  # the subject that stays true after the ship dies.
  def test_unit_the_record_carries_the_process_GROUP_as_a_second_subject
    with_claim do |claim, _dir|
      record = claim.body

      assert_equal Process.getpgrp, record["pgid"], "the group is the subject that outlives the supervisor"
      assert_equal CertOrphanGuard.process_started_at(Process.getpgrp), record["pgid_started_at"],
                   "and it carries its OWN identity — a pgid is a recyclable integer like any other"
    end
  end

  # The vocabulary is the RUNLOCK'S, because §5(c) of the design says these claims
  # are read by the same GRADER — and that grader reads `started_at` as the ISO
  # stamp of when the record was written, taking identity from `<subject>_started_at`.
  # A record spelling one field two ways puts two truths on one screen.
  def test_unit_started_at_is_the_ISO_write_stamp_exactly_as_the_runlock_spells_it
    with_claim do |claim, dir|
      claim.publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)
      record = read_claim(dir)

      parsed = Time.iso8601(record.fetch("started_at"))
      assert_in_delta Time.now.utc, parsed, 60, "started_at must be the ISO write stamp the grader ages"
      refute_equal record["started_at"], record["pid_started_at"],
                   "the OS start time lives in pid_started_at — conflating them is the two-vocabularies bug"
    end
  end

  # began_at is the RUN's age and must not move when the phase does; started_at is
  # this RECORD's age and must.
  def test_unit_began_at_is_fixed_across_republishes_while_started_at_moves
    with_claim do |claim, dir|
      claim.publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)
      first = read_claim(dir)
      sleep 1.1
      claim.publish(phase: PresenceClaim::WAITING, weight: PresenceClaim::IDLE)
      second = read_claim(dir)

      assert_equal first.fetch("began_at"), second.fetch("began_at"), "the RUN began once"
      refute_equal first.fetch("started_at"), second.fetch("started_at"), "this RECORD was written twice"
    end
  end

  # Read ONCE, at open. A process's start time cannot change, so re-reading it at
  # every boundary would spend a `ps` to learn the same fact — on a path that runs
  # eight times per ship.
  def test_unit_the_start_time_is_read_once_and_survives_every_republish
    with_claim do |claim, dir|
      claim.publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE, lane: "2/8 cert")
      first = read_claim(dir).values_at("pid_started_at", "pgid_started_at")
      claim.publish(phase: PresenceClaim::WAITING, weight: PresenceClaim::IDLE, lane: "6/8 ci")

      assert_equal first, read_claim(dir).values_at("pid_started_at", "pgid_started_at")
    end
  end

  # ── the phase, which is the fact this slice exists to publish ───────────────

  def test_unit_a_phase_change_rewrites_ONE_claim_rather_than_leaving_a_trail
    with_claim do |claim, dir|
      claim.publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE, lane: "2/8 cert")
      assert_equal PresenceClaim::SUITE, read_claim(dir).fetch("weight")

      claim.publish(phase: PresenceClaim::WAITING, weight: PresenceClaim::IDLE, lane: "6/8 ci")
      record = read_claim(dir)

      assert_equal 1, claim_paths(dir).size,
                   "one file per PROCESS — a second file would let two contradicting phases stand at once"
      assert_equal PresenceClaim::WAITING, record.fetch("phase")
      assert_equal PresenceClaim::IDLE, record.fetch("weight")
      assert_equal "6/8 ci", record.fetch("lane"), "the lane names the boundary the writer already prints"
      assert_includes PresenceClaim::PHASES, record.fetch("phase"), "the phase must come from the declared vocabulary"
      assert_includes PresenceClaim::WEIGHTS, record.fetch("weight"), "so must the weight — the reader maps these names"
    end
  end

  # The filename is keyed by PID, not by phase — so two concurrent ships in one
  # session are two claims (correct: two workloads) and one ship moving through
  # eight phases is one claim (also correct: one workload).
  def test_unit_the_claim_is_keyed_by_session_and_pid
    with_claim(pid: 4242) do |claim, dir|
      claim.publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::LIGHT)

      assert_equal ["#{SESSION}.presence-ship-4242"], claim_paths(dir).map { |p| File.basename(p) }
    end
  end

  def test_unit_two_processes_in_one_session_publish_two_claims
    Dir.mktmpdir do |dir|
      open_claim(dir, pid: 11).publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)
      open_claim(dir, pid: 12).publish(phase: PresenceClaim::WAITING, weight: PresenceClaim::IDLE)

      assert_equal %W[#{SESSION}.presence-ship-11 #{SESSION}.presence-ship-12],
                   claim_paths(dir).map { |p| File.basename(p) }.sort
    end
  end

  # ── the session-less run ────────────────────────────────────────────────────

  # A `bin/ship` run by hand consumes the machine identically to one an agent
  # launched, so it must still publish. The filename needs a namespace key, not a
  # session — but the RECORD must not invent one, because "we do not know whose
  # this is" and "nobody's" are different answers and collapsing them is the lie
  # the whole surface exists to stop telling.
  def test_unit_a_session_less_run_still_publishes_and_reports_no_session
    Dir.mktmpdir do |dir|
      open_claim(dir, session_id: nil, pid: 77).publish(phase: PresenceClaim::WORKING,
                                                        weight: PresenceClaim::SUITE)
      record = read_claim(dir)

      assert_equal ["unbound-77.presence-ship-77"], claim_paths(dir).map { |p| File.basename(p) }
      assert_nil record.fetch("session_id"), "the record must not invent a session it does not have"
      assert_equal 77, record.fetch("pid"), "the identity is still exact — the pid is what the reader grades"
    end
  end

  def test_unit_a_blank_session_id_is_the_same_as_none
    Dir.mktmpdir do |dir|
      open_claim(dir, session_id: "   ", pid: 78).publish(phase: PresenceClaim::WAITING,
                                                          weight: PresenceClaim::IDLE)

      assert_equal ["unbound-78.presence-ship-78"], claim_paths(dir).map { |p| File.basename(p) }
    end
  end

  # ── the labels a human reads ────────────────────────────────────────────────

  def test_unit_the_repo_and_desk_come_from_the_root_path_with_no_git_call
    Dir.mktmpdir do |dir|
      desk = "/Users/x/projects/mcritchie-studio/.worktrees/certs-publish-no-phase"
      assert_equal "mcritchie-studio", open_claim(dir, root: desk).repo

      assert_equal "turf-monster", open_claim(dir, root: "/Users/x/projects/turf-monster").repo,
                   "a PRIMARY checkout is its own repo — there is no .worktrees segment to climb out of"
    end
  end

  # The soul the session already published, joined here so the row can say "carl"
  # instead of leaving a human to join it by hand. Absent is a NORMAL answer.
  def test_unit_the_agent_is_read_from_the_sessions_acting_agent_marker
    Dir.mktmpdir do |dir|
      SessionMarkers.write(SESSION, dir, ".acting-agent", "carl\n", env: OFF)
      open_claim(dir).publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)

      assert_equal "carl", read_claim(dir).fetch("agent")
    end
  end

  def test_unit_a_session_with_no_acting_agent_reports_none
    Dir.mktmpdir do |dir|
      open_claim(dir).publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)

      assert_nil read_claim(dir).fetch("agent")
    end
  end

  # ── clearing — an OPTIMIZATION, never the correctness story ─────────────────

  def test_unit_clear_removes_the_claim
    with_claim do |claim, dir|
      claim.publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)
      claim.clear

      assert_empty claim_paths(dir), "a graceful exit leaves no claim behind"
    end
  end

  def test_unit_clearing_a_claim_that_was_never_published_is_a_no_op
    with_claim { |claim, _dir| assert_silent { claim.clear } }
  end

  # ── containment — the guard is ON THE PATH ──────────────────────────────────

  # bin/ship is NOT in the containment test's ALLOWED_CONSTRUCTORS and must never
  # need to be: it never names the store. This class holds no path either — it
  # builds a SUFFIX, and SessionMarkers builds and GUARDS the path. These two
  # assert that the guard really is reached, because a writer that resolved its own
  # path is exactly how the last two leaks into the operator's live store happened.
  def test_unit_an_unpinned_sandboxed_publish_aborts_rather_than_writing_the_real_store
    stderr = assert_aborts("an unpinned publish must refuse, not fall back") do
      PresenceClaim.open(kind: "ship", root: "/tmp/x", session_id: SESSION, env: ON)
                   .publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)
    end

    assert_includes stderr, "CLAUDE_PROJECTS_DIR is unset"
    assert_includes stderr, "session-marker"
  end

  def test_unit_a_pin_aimed_back_into_the_real_state_dir_still_aborts
    real = File.join(ProjectsRoot.default_projects_dir, ".agents", "scratch")
    stderr = assert_aborts("a pin INSIDE the real store is still the real store") do
      PresenceClaim.open(kind: "ship", root: "/tmp/x", session_id: SESSION,
                         env: ON.merge("CLAUDE_PROJECTS_DIR" => real))
                   .publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)
    end

    assert_includes stderr, "may never write there"
  end

  # The pin is the store's OWN — CLAUDE_PROJECTS_DIR, what TaskUsageSandbox::STORES
  # names for "session-marker". A resolver that ignored it would be refused on
  # every test run and would reach the operator's live store on every real one.
  def test_unit_the_projects_dir_comes_from_the_stores_own_pin
    Dir.mktmpdir do |dir|
      PresenceClaim.open(kind: "ship", root: "/tmp/x", session_id: SESSION, pid: 5,
                         env: ON.merge("CLAUDE_PROJECTS_DIR" => dir))
                   .publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE)

      assert_equal ["#{SESSION}.presence-ship-5"], claim_paths(dir).map { |p| File.basename(p) }
    end
  end

  # The one path component a CALLER chooses. SessionMarkers sanitizes the session
  # id and nothing else, so a kind that traversed would write outside the store
  # with the guard none the wiser — it grades the path it is handed.
  def test_unit_a_traversing_kind_cannot_escape_the_sessions_dir
    Dir.mktmpdir do |dir|
      open_claim(dir, kind: "../../ship", pid: 9).publish(phase: PresenceClaim::WORKING,
                                                          weight: PresenceClaim::SUITE)

      assert_equal ["#{SESSION}.presence-ship-9"], claim_paths(dir).map { |p| File.basename(p) }
      assert_empty Dir.glob(File.join(dir, "*.presence*")), "nothing may land outside the sessions dir"
    end
  end

  # ── the best-effort contract ────────────────────────────────────────────────

  # A marker must NEVER take down the work it describes. A sandbox violation is a
  # different thing and still aborts (above) — that distinction is the guard's.
  def test_unit_a_real_io_failure_degrades_to_nil_and_never_raises
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, ".agents"), "not a directory")

      assert_nil open_claim(dir).publish(phase: PresenceClaim::WORKING, weight: PresenceClaim::SUITE),
                 "publishing is best-effort: an IO failure is a nil, never an exception"
    end
  end

  private

  def open_claim(dir, kind: "ship", root: "/Users/x/projects/mcritchie-studio", session_id: SESSION,
                 pid: Process.pid)
    PresenceClaim.open(kind: kind, root: root, projects_dir: dir, session_id: session_id,
                       task_slug: "certs-publish-no-phase", pid: pid, env: OFF)
  end

  def with_claim(**kwargs)
    Dir.mktmpdir { |dir| yield(open_claim(dir, **kwargs), dir) }
  end

  def claim_paths(dir)
    Dir.glob(File.join(dir, ".agents", "sessions", "*.presence-*")).sort
  end

  def read_claim(dir)
    JSON.parse(File.read(claim_paths(dir).fetch(0)))
  end

  # `abort` raises SystemExit — NOT a StandardError — which is precisely why it
  # survives the writers' rescue. Mirrors test/lib/session_markers_test.rb's twin.
  def assert_aborts(message)
    original = $stderr
    $stderr = StringIO.new
    ex = assert_raises(SystemExit, message) { yield }
    refute_predicate ex.status, :zero?, "an aborted claim write must exit non-zero"
    $stderr.string
  ensure
    $stderr = original
  end
end

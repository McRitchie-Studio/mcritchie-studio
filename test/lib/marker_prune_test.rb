# frozen_string_literal: true

# MarkerPrune — the session-marker pruner bin/release archive drives.
#
#   bin/rails test test/lib/marker_prune_test.rb
#
# Every store here is a tmpdir pinned with CLAUDE_PROJECTS_DIR; the operator's real
# <projects>/.agents/sessions is never read or written.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require_relative "../support/session_env"
require File.expand_path("../../bin/lib/marker_prune", __dir__)

class MarkerPruneTest < Minitest::Test
  BIN = File.expand_path("../../bin/prune-session-markers", __dir__)
  NOW = Time.utc(2026, 10, 5, 12, 0, 0)
  OLD = NOW - (30 * 86_400)
  FRESH = NOW - 3600

  A = "11111111-1111-4111-8111-111111111111"
  B = "22222222-2222-4222-8222-222222222222"
  C = "33333333-3333-4333-8333-333333333333"

  def entry(name, mtime) = { name: name, mtime: mtime }

  def plan(entries, current: nil, live: [], desks: [])
    MarkerPrune.plan(entries: entries, now: NOW, window_days: 7, current_session_id: current,
                     live_session_ids: Set.new(live), desk_session_ids: Set.new(desks))
  end

  # --- session ids ------------------------------------------------------------

  def test_unit_session_id_reads_uuid_prefix_even_without_a_dot
    assert_equal A, MarkerPrune.session_id_of("#{A}build-claim-renewer-some-task")
    assert_equal A, MarkerPrune.session_id_of("#{A}.task-review-claim-x")
    assert_equal "smoke-thread", MarkerPrune.session_id_of("smoke-thread.json")
  end

  # --- the plan ---------------------------------------------------------------

  def test_unit_prunes_every_marker_of_a_session_older_than_the_window
    p = plan([entry("#{A}.json", OLD), entry("#{A}.heartbeat", OLD), entry("#{A}build-claim-renewer-x", OLD)])
    assert_equal ["#{A}.heartbeat", "#{A}.json", "#{A}build-claim-renewer-x"], p.names
    assert_equal [A], p.pruned_sessions
  end

  def test_unit_keeps_a_session_whose_newest_marker_is_inside_the_window
    # The `.json` is old, but the session touched a claim an hour ago: a renewing
    # lease keeps every marker of its session, the old ones included.
    p = plan([entry("#{A}.json", OLD), entry("#{A}.task-review-claim-x", FRESH)])
    assert_empty p.names
    assert_equal [A], p.kept_sessions
  end

  def test_unit_a_painting_terminal_keeps_its_session
    p = plan([entry("#{A}.json", OLD), entry("#{A}.heartbeat", FRESH)])
    assert_empty p.names, "a throttle inside the window still keeps the session"
  end

  def test_unit_never_prunes_this_session
    p = plan([entry("#{A}.json", OLD)], current: A)
    assert_empty p.names
  end

  def test_unit_never_prunes_a_session_with_a_live_claim
    p = plan([entry("#{A}.json", OLD), entry("#{B}.json", OLD)], live: [A])
    assert_equal ["#{B}.json"], p.names
  end

  def test_unit_never_prunes_a_session_bound_to_a_desk
    p = plan([entry("#{A}.json", OLD), entry("#{B}.json", OLD)], desks: [B])
    assert_equal ["#{A}.json"], p.names
  end

  def test_unit_window_reads_env_then_default
    assert_equal 7, MarkerPrune.window_days({})
    assert_equal 14.0, MarkerPrune.window_days({ "MARKER_PRUNE_WINDOW_DAYS" => "14" })
    assert_equal 3.0, MarkerPrune.window_days({ "MARKER_PRUNE_WINDOW_DAYS" => "14" }, "3")
    assert_equal 7, MarkerPrune.window_days({ "MARKER_PRUNE_WINDOW_DAYS" => "nope" })
  end

  # --- live inputs ------------------------------------------------------------

  def test_unit_no_process_table_refuses
    Dir.mktmpdir do |root|
      _live, refusal = MarkerPrune.live_session_ids(root, [], table: [])
      assert_match(/no process table/, refusal)
    end
  end

  def test_unit_a_renewer_with_a_running_pid_marks_its_session_live
    Dir.mktmpdir do |root|
      sessions = File.join(root, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      File.write(File.join(sessions, "#{A}build-claim-renewer-x"), "#{Process.pid}\tabc\t")
      File.write(File.join(sessions, "#{B}.devops-shift-renewer"), "999999\tabc\t")
      table = [{ pid: Process.pid, pgid: Process.pid, state: "S", started_at: "x", command: "ruby" }]
      live, refusal = MarkerPrune.live_session_ids(root, SessionMarkers.entries(root), table: table)
      assert_nil refusal
      assert_includes live, A
      refute_includes live, B, "a renewer whose pid is gone keeps nothing"
    end
  end

  def test_unit_a_live_presence_claim_marks_its_session_live
    Dir.mktmpdir do |root|
      sessions = File.join(root, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      claim = { "kind" => "ship", "pid" => Process.pid, "pid_started_at" => "Mon Oct  5 10:00:00 2026" }
      File.write(File.join(sessions, "#{C}.presence-ship-#{Process.pid}"), JSON.generate(claim))
      table = [{ pid: Process.pid, pgid: Process.pid, state: "S", started_at: "Mon Oct 5 10:00:00 2026", command: "ruby" }]
      live, = MarkerPrune.live_session_ids(root, SessionMarkers.entries(root), table: table)
      assert_includes live, C
    end
  end

  def test_unit_desk_session_ids_reads_every_desk_context
    Dir.mktmpdir do |root|
      desk = File.join(root, "some-app", ".worktrees", "a-task")
      FileUtils.mkdir_p(desk)
      File.write(File.join(desk, ".agent-context.json"), JSON.generate("session_id" => A, "parent_session_id" => B))
      assert_equal Set[A, B], MarkerPrune.desk_session_ids(root)
    end
  end

  # --- the store seam ---------------------------------------------------------

  def test_unit_entries_skip_in_flight_publishes_and_delete_entry_refuses_odd_names
    Dir.mktmpdir do |root|
      sessions = File.join(root, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      File.write(File.join(sessions, "#{A}.json"), "{}")
      File.write(File.join(sessions, ".#{A}.json.123.tmp"), "")
      assert_equal ["#{A}.json"], SessionMarkers.entries(root).map { |e| e[:name] }

      env = { "CLAUDE_PROJECTS_DIR" => root }
      refute SessionMarkers.delete_entry("../x", root, env: env)
      refute SessionMarkers.delete_entry(".#{A}.json.123.tmp", root, env: env)
      assert SessionMarkers.delete_entry("#{A}.json", root, env: env)
      refute_path_exists File.join(sessions, "#{A}.json")
    end
  end

  # --- the CLI ----------------------------------------------------------------

  def test_unit_cli_dry_runs_by_default_and_applies_with_yes
    Dir.mktmpdir do |root|
      sessions = File.join(root, ".agents", "sessions")
      FileUtils.mkdir_p(sessions)
      old = File.join(sessions, "#{A}.json")
      fresh = File.join(sessions, "#{B}.json")
      File.write(old, "{}")
      File.write(fresh, "{}")
      File.utime(Time.now - (30 * 86_400), Time.now - (30 * 86_400), old)

      env = SessionEnv.neutralized("CLAUDE_PROJECTS_DIR" => root)
      out, status = Open3.capture2e(env, BIN)
      assert status.success?, out
      assert_path_exists old, "a bare run is a dry run"
      summary = MarkerPrune.parse_summary(out)
      assert_equal 1, summary[:count]
      refute summary[:applied]
      assert_equal ["#{A}.json"], summary[:sample]

      out, status = Open3.capture2e(env, BIN, "--yes")
      assert status.success?, out
      refute_path_exists old
      assert_path_exists fresh
      summary = MarkerPrune.parse_summary(out)
      assert summary[:applied]
      assert_equal 1, summary[:count]
    end
  end
end

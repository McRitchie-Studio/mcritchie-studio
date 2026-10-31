# frozen_string_literal: true

# KeepAwake — the lease file under bin/keep-awake.
#
#   bin/rails test test/lib/keep_awake_test.rb
#
# Pure unit tests: a tmpdir pinned by MCR_KEEP_AWAKE_DIR, an injected clock and
# an injected pid check, and a spawner that records instead of spawning. No
# caffeinate, no indicator and no notification runs from this file.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "time"
require_relative "../support/session_env"
require_relative "../../bin/lib/keep_awake"

class KeepAwakeTest < Minitest::Test
  T0 = Time.utc(2026, 10, 30, 3, 0, 0)

  def setup
    @dir = Dir.mktmpdir("keep-awake")
    @env = { "MCR_KEEP_AWAKE_DIR" => @dir }
    @now = T0
    @alive = Set.new
    @spawns = []
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def store
    KeepAwake::Store.new(env: @env, clock: -> { @now }, pid_alive: ->(pid) { @alive.include?(pid.to_i) })
  end

  # A spawner that hands out fake pids and marks them alive.
  def spawner
    lambda do
      pid = 90_000 + @spawns.size
      @spawns << pid
      @alive << pid
      pid
    end
  end

  def start(by, seconds: 1800, reason: "overnight release")
    store.start(by: by, reason: reason, seconds: seconds, spawn: spawner)
  end

  def history_events
    store.history(limit: 100).map { |l| l.split("\t")[1] }
  end

  def test_unit_start_records_a_holder_and_spawns_one_supervisor
    result = start("pokemon-a")

    assert_equal "start", result[:event]
    assert result[:spawned]
    assert_equal [90_000], @spawns
    state = JSON.parse(File.read(File.join(@dir, "state.json")))
    assert_equal ["pokemon-a"], state["holders"].map { |h| h["by"] }
    assert_equal (T0 + 1800).iso8601, state["holders"].first["expires"]
    assert_equal 90_000, state.dig("supervisor", "pid")
    assert_equal ["start"], history_events
  end

  def test_unit_second_agent_joins_without_a_second_supervisor
    start("pokemon-a")
    result = start("carl-b", reason: "long review")

    assert_equal "join", result[:event]
    refute result[:spawned]
    assert_equal 1, @spawns.size, "a join must never spawn a second caffeinate"
    assert_equal %w[pokemon-a carl-b], store.status["holders"].map { |h| h["by"] }
  end

  def test_unit_same_holder_starting_again_renews
    start("pokemon-a")
    @now += 600
    result = start("pokemon-a", reason: "still going")

    assert_equal "renew", result[:event]
    holder = store.status["holders"].first
    assert_equal (T0 + 600 + 1800).iso8601, holder["expires"]
    assert_equal "still going", holder["reason"]
    assert_equal 1, store.status["holders"].size
  end

  def test_unit_renew_extends_a_live_lease
    start("pokemon-a")
    @now += 1700
    result = store.renew(by: "pokemon-a", seconds: 1800)

    assert_equal (T0 + 1700 + 1800).iso8601, result[:holder]["expires"]
    assert result[:supervising]
    assert_equal %w[start renew], history_events
  end

  def test_unit_renew_after_lapse_refuses
    start("pokemon-a")
    @now += 1801

    error = assert_raises(KeepAwake::Error) { store.renew(by: "pokemon-a", seconds: 1800) }
    assert_match(/no live lease/, error.message)
    assert_includes history_events, "lapse"
  end

  def test_unit_release_removes_only_that_holder
    start("pokemon-a")
    start("carl-b")
    result = store.release(by: "pokemon-a")

    assert result[:released]
    assert_equal 1, result[:remaining]
    assert_equal ["carl-b"], store.status["holders"].map { |h| h["by"] }
    assert_equal "release", history_events.last
  end

  def test_unit_release_of_unknown_holder_is_a_no_op
    result = store.release(by: "nobody")

    refute result[:released]
    assert_empty history_events
  end

  def test_unit_lapse_ends_the_hold_and_the_supervisor_clears_itself
    start("pokemon-a")
    @now += 1801

    tick = store.tick(pid: 90_000)
    assert tick[:done]
    assert tick[:ended]
    assert_equal ["pokemon-a"], tick[:lapsed].map { |h| h["by"] }
    state = JSON.parse(File.read(File.join(@dir, "state.json")))
    assert_nil state["supervisor"], "an ended supervisor must clear itself so the next start spawns"
    assert_equal %w[start lapse end], history_events
  end

  def test_unit_tick_keeps_holding_while_a_lease_is_live
    start("pokemon-a")
    @now += 60

    tick = store.tick(pid: 90_000)
    refute tick[:done]
    assert_empty tick[:lapsed]
  end

  def test_unit_tick_of_a_superseded_supervisor_exits_without_ending_the_hold
    start("pokemon-a")
    tick = store.tick(pid: 12_345)

    assert tick[:done]
    refute tick[:ended]
    assert_equal 90_000, store.status.dig("supervisor", "pid")
  end

  def test_unit_stale_supervisor_pid_is_replaced_on_start
    start("pokemon-a")
    @alive.delete(90_000) # the supervisor died (or its pid was reused)

    report = store.status
    refute report["held"]
    assert report["stale"]

    result = start("carl-b")
    assert result[:spawned], "a dead supervisor must be re-spawned, not joined"
    assert_equal "start", result[:event]
    assert_equal 90_001, store.status.dig("supervisor", "pid")
    assert store.status["held"]
  end

  def test_unit_status_none_live_and_lapsed
    report = store.status
    refute report["held"]
    refute report["stale"]
    assert_empty report["holders"]

    start("pokemon-a")
    assert store.status["held"]

    @now += 1801
    report = store.status
    refute report["held"], "a lapsed lease is not a hold"
    assert_empty report["holders"]
  end

  def test_unit_start_requires_by_and_reason
    assert_raises(KeepAwake::Error) { store.start(by: " ", reason: "x", seconds: 60, spawn: spawner) }
    assert_raises(KeepAwake::Error) { store.start(by: "a", reason: "", seconds: 60, spawn: spawner) }
    assert_empty @spawns
  end

  def test_unit_parse_duration
    assert_equal 1800, KeepAwake.parse_duration(nil)
    assert_equal 1800, KeepAwake.parse_duration("30m")
    assert_equal 1800, KeepAwake.parse_duration("30")
    assert_equal 7200, KeepAwake.parse_duration("2h")
    assert_equal 90, KeepAwake.parse_duration("90s")
    assert_raises(KeepAwake::Error) { KeepAwake.parse_duration("forever") }
    assert_raises(KeepAwake::Error) { KeepAwake.parse_duration("13h") }
    assert_raises(KeepAwake::Error) { KeepAwake.parse_duration("0m") }
  end

  def test_unit_history_rows_are_tab_separated_and_clean
    start("pokemon-a", reason: "tabs\tand\nnewlines")
    row = store.history.last.split("\t")

    assert_equal 6, row.size
    assert_equal "pokemon-a", row[2]
    assert_equal "tabs and newlines", row[4]
  end

  # Concurrent starts from separate PROCESSES (flock is per open file, so this
  # is the real contention): exactly one spawns, the rest join.
  def test_unit_concurrent_starts_spawn_one_supervisor
    spawn_log = File.join(@dir, "spawns.log")
    pids = Array.new(6) do |i|
      fork do
        s = KeepAwake::Store.new(env: @env, pid_alive: ->(pid) { pid.to_i == Process.ppid })
        s.start(by: "agent-#{i}", reason: "race", seconds: 600,
                spawn: lambda {
                  File.open(spawn_log, "a") { |f| f.puts(i) }
                  Process.ppid # the test process: alive for as long as the race runs
                })
        exit!(0)
      end
    end
    pids.each { |pid| Process.wait(pid) }

    assert_equal 1, File.readlines(spawn_log).size, "six concurrent starts must spawn exactly one supervisor"
    state = JSON.parse(File.read(File.join(@dir, "state.json")))
    assert_equal 6, state["holders"].size
    assert_equal 1, history_events.count("start")
    assert_equal 5, history_events.count("join")
  end

  def test_unit_unpinned_sandboxed_run_refuses_the_real_store
    env = { "TASK_USAGE_SANDBOX" => "1" }
    assert_raises(SystemExit) do
      capture_io { KeepAwake.dir(env) }
    end
  end
end

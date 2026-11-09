# frozen_string_literal: true

# KeepAwake::OpProbe — the keep-awake supervisor's bounded `op whoami` watch.
#
#   bin/rails test test/lib/keep_awake_op_probe_test.rb
#
# `op` and `ioreg` are stub scripts; the real 1Password CLI never runs. A short
# probe deadline kills a stub that never answers, with no sleep in the test. The
# Watch tests use an injected clock and probe, so they spawn no process.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../support/session_env"
require_relative "../../bin/lib/keep_awake"

class KeepAwakeOpProbeTest < Minitest::Test
  T0 = Time.utc(2026, 11, 9, 10, 41, 0)
  IDLE_NS = 4_260_000_000_000 # 4260 seconds = 71 minutes

  def setup
    @root = Dir.mktmpdir("keep-awake-probe")
    @dir = File.join(@root, "state")
    @reads = File.join(@root, "op-reads.log")
    @pidfile = File.join(@root, "op.pid")
    @ioreg = stub("ioreg", %(echo '    | |   "HIDIdleTime" = #{IDLE_NS}'))
    @env = { "MCR_KEEP_AWAKE_DIR" => @dir, "MCR_OP_READS_LOG" => @reads,
             "MCR_KEEP_AWAKE_IOREG" => @ioreg }
  end

  def teardown
    FileUtils.rm_rf(@root)
  end

  def stub(name, body)
    path = File.join(@root, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def meter_rows
    File.exist?(@reads) ? File.readlines(@reads).map { |l| l.chomp.split("\t") } : []
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_unit_default_deadline_is_twenty_seconds
    assert_equal 20, KeepAwake::OpProbe.deadline({})
    assert_equal 25 * 60, KeepAwake::OpProbe.every({})
    assert_nil KeepAwake::OpProbe.every("MCR_KEEP_AWAKE_PROBE_EVERY" => "0"), "0 turns the probe off"
  end

  # The task's test plan: a stubbed op that never answers is killed at the
  # deadline and logged as hung with idle seconds.
  def test_unit_an_op_that_never_answers_is_killed_and_logged_hung_with_idle_seconds
    op = stub("op", "echo $$ > #{@pidfile}\nexec sleep 60")
    env = @env.merge("MCR_KEEP_AWAKE_OP" => op, "MCR_KEEP_AWAKE_PROBE_DEADLINE" => "0.5")

    row = KeepAwake::OpProbe.run(env: env, now: T0)

    assert_equal "hung", row["outcome"]
    assert_equal 4260, row["idle_seconds"]
    assert_operator row["seconds"], :<, 5, "the deadline, not the stub, ends the attempt"
    pid = File.read(@pidfile).to_i
    refute alive?(pid), "the hung op must be killed by its own pid, not left running"

    logged = File.read(File.join(@dir, "op-probe.log")).split("\t")
    assert_equal [T0.iso8601, "hung"], logged.first(2)
    assert_equal "4260", logged[3]
    meter = meter_rows.last
    assert_equal %w[whoami timeout keep-awake], meter.values_at(2, 3, 4), "bin/op-reads must see the probe"
  end

  def test_unit_an_answering_op_logs_ok_without_a_cache_daemon
    op = stub("op", %(printf '%s' "$OP_CACHE" > #{@pidfile}; echo "$1" >> #{@pidfile}))
    row = KeepAwake::OpProbe.run(env: @env.merge("MCR_KEEP_AWAKE_OP" => op), now: T0)

    assert_equal "ok", row["outcome"]
    assert_equal "falsewhoami", File.read(@pidfile).strip, "the probe runs `op whoami` with OP_CACHE=false"
    assert_equal %w[whoami ok keep-awake], meter_rows.last.values_at(2, 3, 4)
  end

  def test_unit_a_missing_op_and_ioreg_are_rows_not_crashes
    env = @env.merge("MCR_KEEP_AWAKE_OP" => File.join(@root, "absent-op"),
                     "MCR_KEEP_AWAKE_IOREG" => File.join(@root, "absent-ioreg"))
    row = KeepAwake::OpProbe.run(env: env, now: T0)

    assert_equal "fail:127", row["outcome"]
    assert_nil row["idle_seconds"]
    assert_equal "-", File.read(File.join(@dir, "op-probe.log")).split("\t")[3]
  end

  def test_unit_parse_idle_reads_hid_idle_time_in_seconds
    assert_equal 71, KeepAwake::OpProbe.parse_idle(%(  "HIDIdleTime" = 71900000000\n))
    assert_nil KeepAwake::OpProbe.parse_idle("no such key")
  end

  def rows(*outcomes, step: 300)
    outcomes.each_with_index.map do |outcome, i|
      { "ts" => (T0 + i * step).iso8601, "outcome" => outcome, "seconds" => 0.1, "idle_seconds" => 600, "pid" => 1 }
    end
  end

  def test_unit_windows_run_from_first_hung_probe_to_the_next_answer
    windows = KeepAwake::OpProbe.windows(rows("ok", "hung", "hung", "hung", "ok", "hung"))

    assert_equal 2, windows.size
    closed, open = windows
    assert_equal (T0 + 300).iso8601, closed["start"]
    assert_equal (T0 + 900).iso8601, closed["last_hung"]
    assert_equal (T0 + 1200).iso8601, closed["answered"]
    assert_equal 10, closed["minutes"]
    assert_equal 3, closed["probes"]
    assert_nil open["answered"]
    assert_equal 0, open["minutes"]
  end

  def test_unit_note_only_for_an_open_hang_of_ten_minutes_or_more
    short = KeepAwake::OpProbe.windows(rows("hung", "hung")).last
    long = KeepAwake::OpProbe.windows(rows("hung", "hung", "hung")).last
    closed = KeepAwake::OpProbe.windows(rows("hung", "hung", "hung", "ok")).last

    assert_nil KeepAwake::OpProbe.note_for(short, {})
    assert_nil KeepAwake::OpProbe.note_for(closed, {})
    note = KeepAwake::OpProbe.note_for(long, {})
    assert_match(/has not answered since #{T0.localtime.strftime("%H:%M")}/, note)
    assert_match(/10m, 3 probes, user idle 10m/, note)
  end

  # A Watch with a fake clock and a fake probe that appends real log rows.
  def watch(outcomes, notes)
    probe = lambda do
      row = { "ts" => @now.iso8601, "outcome" => outcomes.shift, "seconds" => 20.0,
              "idle_seconds" => 900, "pid" => 1 }
      KeepAwake::OpProbe.append(row, @env)
      @probes << row
      row
    end
    KeepAwake::OpProbe::Watch.new(env: @env, clock: -> { @now }, probe: probe, notify: ->(m) { notes << m })
  end

  def test_unit_watch_probes_every_25_minutes_and_every_5_while_hung
    @now = T0
    @probes = []
    w = watch(%w[ok hung hung], [])

    w.tick
    @now = T0 + 60
    assert_nil w.tick, "no second probe inside the cadence"
    @now = T0 + 25 * 60
    w.tick
    @now = T0 + 29 * 60
    assert_nil w.tick
    @now = T0 + 30 * 60
    w.tick

    assert_equal %w[ok hung hung], @probes.map { |r| r["outcome"] }
  end

  def test_unit_watch_posts_one_note_per_hang_even_across_a_restart
    @now = T0
    @probes = []
    notes = []
    outcomes = %w[hung hung hung hung]
    w = watch(outcomes, notes)
    3.times do
      w.tick
      @now += 5 * 60
    end
    assert_equal 1, notes.size, "a hang of 10 minutes posts its note"

    restarted = watch(outcomes, notes)
    restarted.tick
    assert_equal 4, @probes.size
    assert_equal 1, notes.size, "the same window never posts twice"
  end

  def test_unit_watch_is_off_when_every_is_zero
    @env["MCR_KEEP_AWAKE_PROBE_EVERY"] = "0"
    @now = T0
    @probes = []

    assert_nil watch(%w[ok], []).tick
    assert_empty @probes
  end

  def test_unit_status_carries_the_last_probe_and_hang
    rows("ok", "hung", "hung").each { |r| KeepAwake::OpProbe.append(r, @env) }
    store = KeepAwake::Store.new(env: @env, clock: -> { T0 }, pid_alive: ->(_) { false })

    probe = store.status["op_probe"]
    assert_equal "hung", probe["last"]["outcome"]
    assert_equal (T0 + 300).iso8601, probe["hang"]["start"]
    assert_nil probe["hang"]["answered"]
  end
end

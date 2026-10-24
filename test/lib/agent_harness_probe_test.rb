# frozen_string_literal: true

# [unit] The dispatcher's harness probe and the ping that carries it
# (AgentMailbox::HarnessProbe, Dispatcher#ping): op, gh and power measured on
# the Mac each beat, each check bounded, carried on POST
# /api/v1/agent_dispatchers/ping. The board's half is
# test/controllers/api/v1/agent_dispatchers_controller_test.rb.
#   bin/rails test test/lib/agent_harness_probe_test.rb
require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../../bin/lib/agent_dispatcher"

class AgentHarnessProbeTest < Minitest::Test
  Probe = AgentMailbox::HarnessProbe
  T0 = Time.utc(2026, 10, 24, 18, 0, 0)

  # Records every ping payload; answers like the board.
  class PingClient
    attr_reader :pings

    def initialize = @pings = []

    def ping(payload)
      @pings << payload
      { "data" => { "role" => "primary" }, "meta" => { "primary_live" => true } }
    end
  end

  # A thread stand-in that has already finished (the probe ran inline).
  Done = Struct.new(:value) do
    def alive? = false
  end

  # One still running: alive until released.
  class Running
    attr_accessor :value, :finished

    def alive? = !finished
  end

  def test_unit_the_power_source_is_read_from_pmset
    assert_equal "ac", Probe.parse_power("Now drawing from 'AC Power'\n -InternalBattery-0 (id=1)\t100%; charged;")
    assert_equal "battery", Probe.parse_power("Now drawing from 'Battery Power'\n -InternalBattery-0\t80%; discharging;")
    assert_nil Probe.parse_power("")
  end

  def test_unit_op_ok_asks_the_launchd_daemon_and_the_per_user_one
    user_tmp = `getconf DARWIN_USER_TEMP_DIR 2>/dev/null`.strip
    skip "no per-user temp dir off macOS" if user_tmp.empty?
    Dir.mktmpdir do |dir|
      File.write("#{dir}/op", "#!/bin/sh\necho \"${TMPDIR:-unset}\" >> #{dir}/calls\n")
      File.chmod(0o755, "#{dir}/op")
      env = { "PATH" => "#{dir}:/usr/bin:/bin" }
      assert system(env, "/bin/sh", "-c", Probe::OP_SCRIPT, unsetenv_others: true)
      assert_equal ["unset", user_tmp], File.readlines("#{dir}/calls", chomp: true), "both daemons asked"
      File.delete("#{dir}/calls")
      assert system(env.merge("TMPDIR" => user_tmp), "/bin/sh", "-c", Probe::OP_SCRIPT, unsetenv_others: true)
      assert_equal [user_tmp], File.readlines("#{dir}/calls", chomp: true), "control: one daemon, asked once"
    end
  end

  def test_unit_each_check_runs_under_the_twenty_second_bound_and_reports_its_own_answer
    seen = []
    runner = lambda do |script, deadline|
      seen << [script, deadline]
      !script.include?("gh api")
    end
    m = Probe.new(repo_root: "/repo", runner: runner, power: -> { "battery" }, clock: -> { T0 }).call

    assert_equal [true, false, "battery"], [m.op_ok, m.gh_ok, m.power]
    assert_equal [Probe::OP_SCRIPT, Probe::GH_SCRIPT], seen.map(&:first)
    assert_equal [20, 20], seen.map(&:last), "every check is bounded at 20 seconds"
    assert_match(/\Aop whoami/, Probe::OP_SCRIPT, "op_ok is `op whoami`, which spends no read quota")
    assert_match(%r{bin/gh-token.*gh api /rate_limit}, Probe::GH_SCRIPT)
    assert_equal({ "op_ok" => true, "gh_ok" => false, "power" => "battery",
                   "harness_measured_at" => "2026-10-24T18:00:00Z" }, m.to_ping)
  end

  # The real runner: a login shell under BoundedCommand. A check that hangs is
  # false at its deadline, not a stalled probe.
  def test_unit_a_hung_check_is_false_at_its_deadline
    probe = Probe.new(repo_root: Dir.pwd, power: -> { nil }, deadline: 0.5)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    refute probe.send(:run_script, "exec sleep 600", 0.5)
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 3
    assert probe.send(:run_script, "true", 5), "control: a check that answers in time is true"
  end

  def dispatcher(client, probe:, threader:, out: StringIO.new)
    AgentMailbox::Dispatcher.new(client: client, souls: %w[ray], worker: "disp-probe", claude_cmd: %w[fake-claude],
                                 out: out, clock: -> { @now }, sleeper: ->(_s) { }, idle_wait: 0, busy_wait: 0,
                                 version: "test", registry: AgentMailbox::DomainRegistry.new({}),
                                 harness_probe: probe, threader: threader)
  end

  def measurement(op:, gh:, at: @now)
    Probe::Measurement.new(op_ok: op, gh_ok: gh, power: "ac", measured_at: at)
  end

  def test_unit_the_ping_carries_op_gh_and_power_on_each_beat
    @now = T0
    client = PingClient.new
    results = [measurement(op: true, gh: true), measurement(op: false, gh: true, at: T0 + 60)]
    probe = Object.new.tap { |o| o.define_singleton_method(:call) { results.shift } }
    out = StringIO.new
    disp = dispatcher(client, probe: probe, threader: ->(&work) { Done.new(work.call) }, out: out)

    disp.send(:probe_harness)
    disp.send(:ping, @now)
    @now = T0 + 60
    disp.send(:probe_harness)
    disp.send(:ping, @now)

    assert_equal [true, false], client.pings.map { |p| p["op_ok"] }
    assert_equal [true, true], client.pings.map { |p| p["gh_ok"] }
    assert_equal %w[ac ac], client.pings.map { |p| p["power"] }
    assert_equal ["2026-10-24T18:00:00Z", "2026-10-24T18:01:00Z"], client.pings.map { |p| p["harness_measured_at"] }
    assert_equal "disp-probe", client.pings.first["worker"], "the harness keys ride the ordinary ping"
    assert_match(/harness: op FAILING, gh ok, power ac/, out.string, "a change is logged")
    assert_equal 2, out.string.scan("harness:").size, "one line per change, not one per beat"
  end

  # A probe still running (a hung op, up to 20 s per check) never holds up the
  # beat: the ping goes out with the last finished measurement, and no second
  # probe is started on top of the first.
  def test_unit_a_slow_probe_never_blocks_the_ping_or_doubles_up
    @now = T0
    client = PingClient.new
    started = 0
    slow = Running.new
    threader = lambda do |&_work|
      started += 1
      slow
    end
    disp = dispatcher(client, probe: Object.new, threader: threader)

    disp.send(:probe_harness)
    disp.send(:ping, @now)
    disp.send(:probe_harness)
    disp.send(:ping, @now + 60)

    assert_equal 1, started, "one probe in flight at a time"
    assert(client.pings.none? { |p| p.key?("op_ok") }, "no measurement yet, so no harness keys")

    slow.value = measurement(op: false, gh: false)
    slow.finished = true
    disp.send(:probe_harness)
    disp.send(:ping, @now + 120)
    assert_equal false, client.pings.last["op_ok"]
    assert_equal 2, started, "the next beat's probe starts once the first is collected"
  end

  def test_unit_control_no_probe_means_the_ping_is_unchanged
    @now = T0
    client = PingClient.new
    disp = dispatcher(client, probe: nil, threader: ->(&_w) { flunk "no probe, no thread" })
    disp.send(:probe_harness)
    disp.send(:ping, @now)
    refute client.pings.first.key?("op_ok")
  end
end

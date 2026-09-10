# frozen_string_literal: true

# [integration] Harness tests for bin/ship-wait — the REAL script, shelled via
# Open3 against a throwaway state directory and a stub ship (house pattern:
# test/lib/ship_test.rb, test/lib/fast_check_test.rb).
#
# THE POINT OF THIS FILE, stated so nobody weakens it later. A watcher test that
# asserts "it waits" PASSES ON A WATCHER THAT WAITS FOREVER, and waiting forever
# is the exact defect (task ship-wait-has-no-primitive: five builders reinvented
# `while pgrep -f "bin/ship <slug>"`, whose condition can never go false once a
# sibling shell carries the pattern). So every test here proves the watcher
# **FIRES** — it returns, within a wall-clock bound, with the right code:
#
#   * against an ALREADY-FINISHED ship, it returns at once (the case the naive
#     loop gets most wrong);
#   * with a DECOY sibling process whose command line carries `bin/ship <slug>`,
#     it STILL returns at once — a process-table pattern would match that decoy
#     and hang;
#   * against a ship that exited 0 having never reached the seam, it returns
#     FAILED, because the LOG holds the verdict and the exit code does not.
#
# THE BOUNDS ARE THE ASSERTION. Each wait is given `--interval 20 --timeout 25`,
# so a correct watcher returns in well under a second and a broken one cannot
# return before 25. `assert_operator elapsed, :<, FAST_S` is therefore a real
# discriminator, not decoration.
#
# Run directly:
#   ruby -Itest test/lib/ship_wait_script_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/ship_wait"

class ShipWaitScriptTest < Minitest::Test
  BIN = File.expand_path("../../bin/ship-wait", __dir__)
  LIB = File.expand_path("../../bin/lib/ship_wait.rb", __dir__)
  SLUG = "ship-wait-demo"
  SUCCESS = ShipWait::SUCCESS_LINE

  # A correct watcher answers from a file read. Ruby boot plus one stat is well
  # under this; a watcher that reaches its first sleep cannot beat it.
  FAST_S = 8

  # Poll wider than the budget, so ONE nap already overruns it: a wait that fails
  # to check before sleeping cannot return inside FAST_S, and a wait that never
  # fires still terminates at 25s instead of hanging the suite.
  BOUNDED = ["--interval", "20", "--timeout", "25"].freeze

  def setup
    @decoys = []
  end

  def teardown
    @decoys.each do |pid|
      Process.kill("KILL", pid)
      Process.wait(pid)
    rescue StandardError
      nil
    end
  end

  # --- harness ---------------------------------------------------------------

  def with_state
    Dir.mktmpdir do |dir|
      yield dir
    end
  end

  def seed_log(dir, *lines, slug: SLUG)
    path = ShipWait.log_path(dir, slug)
    FileUtils.mkdir_p(dir)
    File.write(path, "#{lines.join("\n")}\n")
    path
  end

  # Spawn a wait and TIME it. Elapsed is the assertion in most tests here.
  def run_wait(dir, args, extra_env: {})
    env = OutboundSeams.env({ "SHIP_WAIT_DIR" => dir }.merge(extra_env))
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3(env, BIN, *args)
    [out, err, status.exitstatus, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # A stand-in for bin/ship: sleeps, prints, exits with a chosen code.
  def stub_ship(dir, prints:, exits: 0, sleeps: 0)
    path = File.join(dir, "ship-stub")
    File.write(path, <<~SH)
      #!/bin/sh
      [ #{sleeps} -gt 0 ] && sleep #{sleeps}
      printf '%s\\n' #{prints.map { |l| "'#{l}'" }.join(" ")}
      exit #{exits}
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  # A SIBLING process whose command line carries the very string a naive watcher
  # greps for. It is not an ancestor of the wait, so macOS pgrep's default
  # ancestor exclusion does not hide it — which is exactly how the reported
  # deadlock happens: the orphans from earlier attempts keep every later watcher
  # alive.
  #
  # THE BODY MUST BE COMPOUND. `sh -c 'sleep 30 # bin/ship <slug>'` is a SIMPLE
  # command, so sh execs `sleep` and REPLACES ITSELF — the pattern vanishes from
  # the process table and the decoy proves nothing. That is not a hypothetical:
  # the first cut of this fixture did exactly that, and mutation A (pgrep put
  # back) left this test GREEN. A loop keeps the shell, and therefore its argv,
  # alive. `assert_decoy_carries_the_pattern` re-checks it every run.
  def spawn_decoy(slug = SLUG)
    pid = Process.spawn("/bin/sh", "-c", "n=0; while [ $n -lt 300 ]; do n=$((n+1)); sleep 0.1; done # bin/ship #{slug}",
                        out: File::NULL, err: File::NULL)
    @decoys << pid
    sleep 0.3 # let it land in the process table before the wait looks
    pid
  end

  # The fixture's own precondition, asserted rather than assumed.
  def assert_decoy_carries_the_pattern(pid, slug = SLUG)
    argv = IO.popen(["ps", "-o", "command=", "-p", pid.to_s], &:read).to_s
    assert_includes argv, "bin/ship #{slug}",
      "the decoy must really carry the pattern in its argv, or this test proves nothing"
  end

  # --- 1. IT FIRES on an already-finished ship --------------------------------

  def test_an_already_finished_ship_returns_at_once_with_zero
    with_state do |dir|
      seed_log(dir, "ship: 8/8 submit", "Task: https://mcritchie.studio/tasks/#{SLUG}",
               "PR: https://github.com/x/y/pull/1", SUCCESS, "#{ShipWait::SENTINEL_PREFIX}0")
      out, err, code, elapsed = run_wait(dir, [SLUG, *BOUNDED])

      assert_equal ShipWait::EXIT_SUCCEEDED, code, "already-finished ship must exit 0. stderr:\n#{err}"
      assert_operator elapsed, :<, FAST_S,
        "the wait must return AT ONCE on a finished ship, not after a poll — took #{elapsed.round(2)}s"
      assert_match(/SUCCEEDED/, err)
      assert_match(%r{^PR: https://github.com/x/y/pull/1$}, out, "ship's summary block is relayed to stdout")
    end
  end

  # --- 2. IT FIRES on a finished FAILED ship, and reads the LOG for the verdict

  def test_a_ship_that_exited_zero_without_the_seam_line_is_FAILED
    with_state do |dir|
      seed_log(dir, "ship: 7/8 dor-check", "ship: bin/dor-check refused — fix everything it flagged",
               "#{ShipWait::SENTINEL_PREFIX}0")
      _out, err, code, elapsed = run_wait(dir, [SLUG, *BOUNDED])

      assert_equal ShipWait::EXIT_FAILED, code,
        "bin/ship EXITS 0 ON FAILURE — the verdict must come from the log. stderr:\n#{err}"
      assert_operator elapsed, :<, FAST_S, "took #{elapsed.round(2)}s"
      assert_match(/FAILED/, err)
      assert_match(/dor-check refused/, err, "the failure relays ship's own last line")
      assert_match(/re-run bin\/ship #{SLUG}/, err, "the refusal names the remedy")
    end
  end

  # --- 3. THE SELF-MATCH GUARD — a decoy sibling must not hold the wait open ---

  def test_a_sibling_process_carrying_the_ships_command_line_does_not_hold_the_wait
    with_state do |dir|
      decoy = spawn_decoy
      assert_decoy_carries_the_pattern(decoy)
      seed_log(dir, SUCCESS, "#{ShipWait::SENTINEL_PREFIX}0")
      _out, err, code, elapsed = run_wait(dir, [SLUG, *BOUNDED])

      assert ShipWait.alive?(decoy), "the decoy must still be running while the wait ran, or this proves nothing"
      assert_equal ShipWait::EXIT_SUCCEEDED, code, "stderr:\n#{err}"
      assert_operator elapsed, :<, FAST_S,
        "a process-table pattern would match the decoy and hang — took #{elapsed.round(2)}s"
    end
  end

  # The structural half of the same claim: the primitive owns no process-table
  # pattern at all. A grep guard proves only that the call is absent — which is
  # exactly the regression worth catching, since re-introducing `pgrep` IS the bug.
  def test_the_primitive_contains_no_process_table_pattern
    banned = { "pgrep" => /\bpgrep\b/, "pkill" => /\bpkill\b/, "ps scrape" => /\bps\s+-[a-zA-Z]/ }
    [BIN, LIB].each do |path|
      # Report the OFFENDING LINES, never the whole file: a guard whose failure
      # message is a source dump is a guard nobody reads.
      offenders = File.read(path).each_line.with_index(1)
                      .reject { |line, _| line.strip.start_with?("#") }
                      .flat_map do |line, number|
                        banned.filter_map { |name, re| "#{File.basename(path)}:#{number} (#{name}) #{line.strip}" if line =~ re }
                      end
      assert_empty offenders,
        "the primitive must never read the process table by PATTERN — a pattern matches sibling " \
        "watchers, and that is the defect this script exists to end. Offending line(s):\n#{offenders.join("\n")}"
    end
  end

  # --- 4. IT IS BOUNDED -------------------------------------------------------

  def test_a_running_ship_times_out_inside_its_budget
    with_state do |dir|
      ship = stub_ship(dir, prints: [SUCCESS], sleeps: 20)
      _out, err, code, elapsed = run_wait(dir, [SLUG, "--launch", "--quiet", "--interval", "1", "--timeout", "3"],
                                          extra_env: { "SHIP_WAIT_SHIP_BIN" => ship })

      assert_equal ShipWait::EXIT_TIMEOUT, code, "still-running at the bound is 2, not 0 or 1. stderr:\n#{err}"
      assert_operator elapsed, :>=, 2.5, "it must actually have waited"
      assert_operator elapsed, :<, 15, "the bound must hold — took #{elapsed.round(2)}s"
      assert_match(/TIMEOUT/, err)
      assert_match(/not a failure/, err, "a timeout says so, so nobody re-runs a healthy ship")
    end
  end

  # --- 5. --launch: it runs the ship, stamps the sentinel, and FIRES -----------

  def test_launch_runs_the_ship_and_the_wait_fires_on_its_success
    with_state do |dir|
      ship = stub_ship(dir, prints: ["ship: 1/8 commit", SUCCESS], sleeps: 1)
      _out, err, code, elapsed = run_wait(dir, [SLUG, "--launch", "--quiet", "--interval", "1", "--timeout", "25"],
                                          extra_env: { "SHIP_WAIT_SHIP_BIN" => ship })

      assert_equal ShipWait::EXIT_SUCCEEDED, code, "stderr:\n#{err}"
      assert_operator elapsed, :<, 15, "took #{elapsed.round(2)}s"
      log = File.read(ShipWait.log_path(dir, SLUG))
      assert_match(/#{Regexp.escape(SUCCESS)}/, log, "the ship's output was captured")
      assert ShipWait.exited?(log), "the launcher stamps the sentinel so a LATER attach is terminal"
      assert File.exist?(ShipWait.pid_path(dir, SLUG)), "the launch records the pid it captured"
    end
  end

  def test_launch_relays_a_failing_ship_as_failed
    with_state do |dir|
      ship = stub_ship(dir, prints: ["ship: the move to submitted failed"], exits: 1)
      _out, err, code, = run_wait(dir, [SLUG, "--launch", "--quiet", "--interval", "1", "--timeout", "25"],
                                  extra_env: { "SHIP_WAIT_SHIP_BIN" => ship })

      assert_equal ShipWait::EXIT_FAILED, code, "stderr:\n#{err}"
      assert_equal 1, ShipWait.sentinel_status(File.read(ShipWait.log_path(dir, SLUG)))
    end
  end

  # THE FAST PATH TURNED AGAINST ITSELF. A previous run's sentinel left in the log
  # would make the very first read terminal, and --launch would report the OLD run
  # as this one's verdict — instantly, and wrongly.
  def test_launch_rotates_the_previous_log_so_a_stale_sentinel_cannot_fire
    with_state do |dir|
      seed_log(dir, "ship: an EARLIER run", SUCCESS, "#{ShipWait::SENTINEL_PREFIX}0")
      ship = stub_ship(dir, prints: ["ship: bin/dor-check refused"], exits: 1, sleeps: 1)
      _out, err, code, elapsed = run_wait(dir, [SLUG, "--launch", "--quiet", "--interval", "1", "--timeout", "25"],
                                          extra_env: { "SHIP_WAIT_SHIP_BIN" => ship })

      assert_equal ShipWait::EXIT_FAILED, code,
        "the stale sentinel must not be credited to this run. stderr:\n#{err}"
      assert_operator elapsed, :>=, 0.5, "it must have waited for the NEW ship, not answered from the old log"
      assert_match(/an EARLIER run/, File.read(ShipWait.previous_log_path(dir, SLUG)),
        "the old log is kept as evidence, not destroyed")
      refute_match(/an EARLIER run/, File.read(ShipWait.log_path(dir, SLUG)))
    end
  end

  def test_launch_refuses_while_a_ship_for_the_slug_is_already_running
    with_state do |dir|
      ship = stub_ship(dir, prints: [SUCCESS], sleeps: 20)
      launch = [SLUG, "--launch", "--quiet", "--interval", "1", "--timeout", "2"]
      _o, _e, first, = run_wait(dir, launch, extra_env: { "SHIP_WAIT_SHIP_BIN" => ship })
      assert_equal ShipWait::EXIT_TIMEOUT, first, "the first launch is still running at its bound"

      _out, err, code, = run_wait(dir, launch, extra_env: { "SHIP_WAIT_SHIP_BIN" => ship })
      assert_equal ShipWait::EXIT_USAGE, code, "a second concurrent ship on one task races the same PR"
      assert_match(/ALREADY RUNNING/, err)
      assert_match(/bin\/ship-wait #{SLUG}/, err, "the refusal names the attach command")
    end
  end

  # --- 6. the --pid lane: a dead PID ends the wait, the log gives the verdict --

  def test_a_dead_pid_with_no_sentinel_reports_failed
    with_state do |dir|
      seed_log(dir, "ship: 4/8 open PR")
      dead = Process.spawn("/bin/sh", "-c", "exit 0", out: File::NULL, err: File::NULL)
      Process.wait(dead)

      _out, err, code, elapsed = run_wait(dir, [SLUG, "--pid", dead.to_s, *BOUNDED])
      assert_equal ShipWait::EXIT_FAILED, code, "stderr:\n#{err}"
      assert_operator elapsed, :<, FAST_S, "took #{elapsed.round(2)}s"
    end
  end

  # --- 7. refusals ------------------------------------------------------------

  def test_no_log_and_no_launch_is_its_own_exit_code
    with_state do |dir|
      _out, err, code, = run_wait(dir, [SLUG, *BOUNDED])
      assert_equal ShipWait::EXIT_NO_LOG, code
      assert_match(/no log to watch/, err)
      assert_match(/--launch/, err, "the refusal names both ways out")
      assert_match(/--log/, err)
    end
  end

  def test_a_bad_invocation_is_a_usage_exit
    with_state do |dir|
      _out, _err, no_slug, = run_wait(dir, [*BOUNDED])
      assert_equal ShipWait::EXIT_USAGE, no_slug

      _out, err, stray, = run_wait(dir, [SLUG, "extra-arg", *BOUNDED])
      assert_equal ShipWait::EXIT_USAGE, stray
      assert_match(/unexpected argument/, err)

      _out, err2, orphan_message, = run_wait(dir, [SLUG, "-m", "msg", *BOUNDED])
      assert_equal ShipWait::EXIT_USAGE, orphan_message
      assert_match(/only meaningful with --launch/, err2)
    end
  end
end

# frozen_string_literal: true

# THE SHELL HALF OF THE OP BOUND — bin/lib/op-meter.sh's op_metered, which
# bin/gh-app-git-credential calls on every git fetch and push.
#
#   bin/rails test test/commands/op_meter_bound_test.rb
#
# On 2026-10-21 the 1Password cache daemon never became ready after a reboot and
# every `op read` waited about fifteen minutes, so `git fetch` hung with it. Each
# attempt is now killed at MCR_OP_DEADLINE seconds by a perl watchdog and retried
# once with OP_CACHE=false. The stub below never answers while the cache is in
# play and answers at once without it, which is how `op` behaved that day. It
# execs `sleep`, so the watchdog's KILL lands on the process holding stdout.
#
# Run under bash (the credential helper), zsh (bin/setup-1pass-token) and sh, so
# the env-prefixed retry is proven in every shell that sources the file.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class OpMeterBoundTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SHIM = File.join(ROOT, "bin", "lib", "op-meter.sh")
  SHELLS = %w[bash zsh sh].select { |sh| system("command -v #{sh} >/dev/null 2>&1") }

  def setup
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "op-reads.log")
    @calls = File.join(@dir, "calls.log")
  end

  def teardown
    FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir)
  end

  def stub(body)
    path = File.join(@dir, "op")
    File.write(path, "#!/bin/sh\nprintf '%s %s\\n' \"cache=${OP_CACHE:-unset}\" \"$*\" >> #{@calls}\n#{body}\n")
    File.chmod(0o755, path)
    path
  end

  def hung_until_uncached(retry_body: "printf 'FRESH'; exit 0")
    stub(%(if [ "${OP_CACHE:-}" = "false" ]; then #{retry_body}; fi\nexec sleep 600))
  end

  # value, rc, cache-after, seconds
  def run_metered(shell, op, deadline: "1")
    script = %(. "#{SHIM}"; v=$(op_metered "$1" read op://v/i/f); rc=$?; printf '%s|%s|%s' "$v" "$rc" "${OP_CACHE:-unset}")
    env = SessionEnv.neutralized("MCR_OP_READS_LOG" => @log, "MCR_OP_DEADLINE" => deadline,
                                 "OP_METER_VIA" => "test", "HOME" => @dir)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, _err, _status = Open3.capture3(env, shell, "-c", script, "op-meter-bound-test", op)
    [*out.split("|", 3), Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def outcomes = File.exist?(@log) ? File.readlines(@log).map { |l| l.split("\t")[3] } : []
  def calls = File.exist?(@calls) ? File.readlines(@calls).map(&:chomp) : []

  def reset!
    FileUtils.rm_f([@log, @calls])
  end

  def test_unit_a_hung_op_is_killed_and_the_uncached_retry_answers_in_every_shell
    op = hung_until_uncached
    SHELLS.each do |shell|
      reset!
      value, rc, cache_after, seconds = run_metered(shell, op)

      assert_equal "FRESH", value, "#{shell}: the retry's answer is the caller's answer"
      assert_equal "0", rc, "#{shell}: the caller sees the retry's status"
      assert_operator seconds, :<, 6, "#{shell}: one 1 s deadline and a fast retry, never the stub's 600 s"
      assert_equal %w[timeout ok], outcomes, "#{shell}: the log shows the timeout, then the retry"
      assert_equal ["cache=unset read op://v/i/f", "cache=false read op://v/i/f"], calls, "#{shell}: exactly one uncached retry"
      assert_equal "unset", cache_after, "#{shell}: OP_CACHE=false is the retry's alone, not left in the caller's shell"
    end
  end

  def test_unit_a_retry_that_also_hangs_returns_124_after_two_deadlines
    op = hung_until_uncached(retry_body: "exec sleep 600")
    value, rc, _cache, seconds = run_metered("bash", op, deadline: "1")

    assert_equal "", value
    assert_equal "124", rc, "the watchdog's timeout code reaches the caller, which treats it as a failed read"
    assert_operator seconds, :<, 6
    assert_equal %w[timeout timeout], outcomes
  end

  # perl's alarm truncates, and alarm 0 is no alarm: 0.5 must round up, not unbound.
  def test_unit_a_fractional_deadline_still_bounds_the_attempt
    value, rc, _cache, seconds = run_metered("bash", hung_until_uncached, deadline: "0.5")
    assert_equal %w[FRESH 0], [value, rc]
    assert_operator seconds, :<, 6
    assert_equal %w[timeout ok], outcomes
  end

  # CONTROL: a healthy op runs once, cache untouched, its exact status passed back.
  def test_unit_control_a_fast_op_is_run_once_and_its_status_kept
    op = stub("printf 'SECRET'\nexit 0")
    value, rc, = run_metered("bash", op)
    assert_equal ["SECRET", "0"], [value, rc]
    assert_equal ["cache=unset read op://v/i/f"], calls
    assert_equal %w[ok], outcomes

    reset!
    op = stub("exit 3")
    _value, rc, = run_metered("bash", op)
    assert_equal "3", rc, "a failing op's own status survives the watchdog"
    assert_equal %w[fail:3], outcomes
    assert_equal 1, calls.length, "only a timeout is retried, never a plain failure"
  end

  def test_unit_control_an_absent_op_still_reports_127
    _value, rc, = run_metered("bash", File.join(@dir, "no-such-op"))
    assert_equal "127", rc
    assert_equal %w[fail:127], outcomes
  end
end

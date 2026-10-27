# frozen_string_literal: true

# [unit] bin/release's RECORD-OP DEADLINE (conductor → run_record_op).
#
# On 2026-10-27 a `heroku run` record op hung for 26 minutes after its one-off
# dyno was gone, and `bin/release ship` froze with it. These cases plant a fake
# `heroku` on PATH and drive the real `conductor` with a one-second deadline:
#
#   * a hung client is killed, its grandchild with it, and the run takes the
#     "record op failed" abort instead of waiting;
#   * a best-effort write (record_release_event) warns and continues past it;
#   * a client that answers in time still returns its JSON (the bound changes
#     nothing on the happy path).
#
#   ruby -Itest test/lib/release_conductor_deadline_test.rb

require_relative "release_cli_harness"

class ReleaseConductorDeadlineTest < ReleaseCliHarness
  # A fake `heroku` that starts a grandchild (the node process the real launcher
  # execs) and then hangs, writing the grandchild's pid where the test can find it.
  HUNG_HEROKU = <<~SH
    #!/bin/sh
    sleep 120 &
    echo $! > "$FAKE_HEROKU_PIDFILE"
    sleep 120
  SH

  ANSWERING_HEROKU = <<~SH
    #!/bin/sh
    echo "Running rails runner on mcritchie-studio... up, run.1234"
    echo '{"ok":true}'
  SH

  def with_fake_heroku(body)
    Dir.mktmpdir("fake-heroku") do |dir|
      path = File.join(dir, "heroku")
      File.write(path, body)
      File.chmod(0o755, path)
      yield dir, File.join(dir, "grandchild.pid")
    end
  end

  def run_with(bin_dir, pidfile, script)
    env = OutboundSeams.env(
      "MCR_PRIMARY_LOCK_DIR" => self.class.lock_dir, "TMPDIR" => subprocess_tmpdir,
      "TASK_API_BASE" => UNROUTABLE_API_BASE, "GH_AUTH_TOKEN_BIN" => ReleaseCliStubs.token_broker,
      "RELEASE_RECORD_OP_DEADLINE" => "1", "FAKE_HEROKU_PIDFILE" => pidfile
    )
    env["PATH"] = [bin_dir, env["PATH"]].join(File::PATH_SEPARATOR)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out, err, status = Open3.capture3(env, "ruby", "-e", %(ARGV.replace([]); load #{BIN.inspect}; #{script}))
    [out, err, status, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def test_a_hung_record_op_is_killed_and_takes_the_record_op_failed_abort
    with_fake_heroku(HUNG_HEROKU) do |dir, pidfile|
      out, err, status, elapsed = run_with(dir, pidfile, %(conductor("puts({ x: 1 }.to_json)"); print "RETURNED"))

      refute status.success?, "a timed-out record op must abort, not return: #{out}"
      refute_includes out, "RETURNED"
      assert_includes err, "record op failed: no answer within 1s"
      assert_includes err, "RELEASE_RECORD_OP_DEADLINE"
      assert_operator elapsed, :<, 60, "the run waited on the hung client instead of killing it"

      grandchild = File.read(pidfile).to_i
      assert_operator grandchild, :>, 0
      refute alive?(grandchild), "the hung client's grandchild survived: the kill must take the whole process group"
    end
  end

  def test_a_best_effort_write_warns_and_continues_past_a_hung_record_op
    with_fake_heroku(HUNG_HEROKU) do |dir, pidfile|
      out, err, status, = run_with(
        dir, pidfile,
        %(record_release_event("rel-x", "ship_gate", "completed"); print "CONTINUED")
      )

      assert status.success?, "a best-effort write must not end the run: #{err}"
      assert_includes out, "release event ship_gate:completed not recorded"
      assert_includes out, "no answer within 1s"
      assert_includes out, "CONTINUED"
    end
  end

  def test_a_record_op_that_answers_in_time_returns_its_json
    with_fake_heroku(ANSWERING_HEROKU) do |dir, pidfile|
      out, err, status, = run_with(dir, pidfile, %(print conductor("puts 1").to_json))

      assert status.success?, err
      assert_equal({ "ok" => true }, JSON.parse(out.lines.last))
    end
  end

  def test_the_deadline_reads_the_env_and_falls_back_to_five_minutes
    with_fake_heroku(ANSWERING_HEROKU) do |dir, pidfile|
      out, = run_with(dir, pidfile, %(print record_op_deadline; ENV["RELEASE_RECORD_OP_DEADLINE"] = "junk"; print " ", record_op_deadline))

      assert_equal "1.0 300", out.lines.last.strip
    end
  end
end

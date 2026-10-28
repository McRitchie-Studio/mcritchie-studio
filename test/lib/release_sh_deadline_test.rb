# frozen_string_literal: true

# [unit] bin/release's `sh` and its read helpers are BOUNDED (BoundedCommand,
# process-group SIGKILL), and each class of step reads its own bound:
#
#   * sh, captured or streamed, kills a hung child that ignores SIGALRM and its
#     grandchild with it, and reads as a failure with a line naming the bound;
#   * a post_deploy scope runs under RELEASE_POST_DEPLOY_DEADLINE, not the
#     working-step bound;
#   * the archive's board write is not cut at the 300 s record-op bound: it takes
#     RELEASE_ARCHIVE_STEP_DEADLINE, and grows with the number of tasks it flips.
#
#   ruby -Itest test/lib/release_sh_deadline_test.rb

require_relative "release_cli_harness"

class ReleaseShDeadlineTest < ReleaseCliHarness
  # Ignores SIGALRM and SIGTERM as `op` did on 2026-10-27, and starts a grandchild
  # that touches $MARKER if it outlives the kill.
  STUBBORN = "trap '' ALRM TERM HUP INT; (trap '' ALRM TERM HUP INT; sleep 2; touch \"$MARKER\") & " \
             "kill -ALRM $$; echo still-here; sleep 120"

  def run_with(env_extra, call)
    run_cli([], call: call, setup: env_extra.map { |k, v| %(ENV[#{k.inspect}] = #{v.inspect}) }.join("; "))
  end

  def test_a_captured_sh_kills_a_child_that_ignores_sigalrm_and_its_group
    Dir.mktmpdir do |dir|
      marker = File.join(dir, "outlived")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = run_with({ "RELEASE_COMMAND_DEADLINE" => "1", "MARKER" => marker },
                     %(o, ok = sh("sh", "-c", #{STUBBORN.inspect}, capture: true); puts "OK=\#{ok.inspect}"; puts o))
      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      sleep 2.5

      assert_includes out, "OK=false", out
      assert_includes out, "still-here", "what the child said before the kill is kept"
      assert_includes out, "gave no answer within 1s and was killed with its process group (RELEASE_COMMAND_DEADLINE sets the bound)", out
      assert_operator seconds, :<, 30
      refute File.exist?(marker), "the grandchild died with the group"
    end
  end

  def test_a_streamed_sh_is_bounded_too_and_still_prints_live
    out = run_with({ "RELEASE_COMMAND_DEADLINE" => "1" },
                   %(_, ok = sh("sh", "-c", "echo streamed; trap '' ALRM; sleep 120"); puts "OK=\#{ok.inspect}"))

    assert_includes out, "streamed", out
    assert_includes out, "OK=false", out
    assert_includes out, "(RELEASE_COMMAND_DEADLINE sets the bound)", out
  end

  # A streamed child's stdin is /dev/null: a prompt reads EOF at once rather than
  # waiting on the caller's stdin (a terminal it cannot read from its own group).
  def test_a_streamed_sh_child_reads_eof_not_the_callers_stdin
    out = run_with({ "RELEASE_COMMAND_DEADLINE" => "5" }, <<~CALL)
      r, _w = IO.pipe
      $stdin.reopen(r)
      _, ok = sh("sh", "-c", "if read x; then echo GOT; else echo STDIN-EOF; fi")
      puts "OK=\#{ok.inspect}"
    CALL

    assert_includes out, "STDIN-EOF", out
    assert_includes out, "OK=true", out
  end

  def test_a_streamed_sh_that_cannot_start_is_a_failure_not_a_raise
    out = run_with({}, %(_, ok = sh("/nonexistent/tool"); puts "OK=\#{ok.inspect}"))

    assert_includes out, "could not run /nonexistent/tool", out
    assert_includes out, "OK=false", out
  end

  def test_a_post_deploy_scope_runs_under_its_own_bound
    out = run_with({ "RELEASE_POST_DEPLOY_DEADLINE" => "1", "RELEASE_COMMAND_DEADLINE" => "600" }, <<~CALL)
      def scope_action(*, **) = nil
      def gate_sop(*) = nil
      o, ok = run_test_scope("prod_post_deploy", "sh", "-c", "trap '' ALRM; sleep 120", capture: true, repo: "app")
      puts "OK=\#{ok.inspect}"
      puts o
    CALL

    assert_includes out, "OK=false", out
    assert_includes out, "(RELEASE_POST_DEPLOY_DEADLINE sets the bound)", out
  end

  def test_git_capture_is_bounded_by_the_read_deadline
    Dir.mktmpdir do |dir|
      git = File.join(dir, "git")
      File.write(git, "#!/bin/sh\ntrap '' ALRM\nsleep 120\n")
      File.chmod(0o755, git)
      out = run_with({ "RELEASE_READ_DEADLINE" => "1", "PATH" => "#{dir}:#{ENV.fetch('PATH')}" },
                     %(o, ok = git_capture("status"); puts "OK=\#{ok.inspect}"; puts o))

      assert_includes out, "OK=false", out
      assert_includes out, "(RELEASE_READ_DEADLINE sets the bound)", out
    end
  end

  def test_the_archive_write_takes_the_archive_bound_not_the_record_op_bound
    out = run_with({ "RELEASE_RECORD_OP_DEADLINE" => "300" }, <<~CALL)
      puts "STEP=\#{archive_step_deadline.round}"
      puts "SMALL=\#{archive_write_deadline(10).round}"
      puts "LARGE=\#{archive_write_deadline(1000).round}"
      seen = []
      define_method(:run_record_op) { |_cmd, deadline:| seen << deadline; ["{}", true, false] }
      with_record_op_deadline(archive_write_deadline(5), ARCHIVE_STEP_DEADLINE_ENV) { conductor("puts 1") }
      conductor("puts 2")
      puts "SEEN=\#{seen.map(&:round).inspect}"
    CALL

    assert_includes out, "STEP=1800", out
    assert_includes out, "SMALL=1800", "a small archive keeps the step bound"
    assert_includes out, "LARGE=3300", "a large one grows by a beat per flip past the record-op bound"
    assert_includes out, "SEEN=[1800, 300]", "the scope ends with its block: the next record op is bounded as before"
  end
end

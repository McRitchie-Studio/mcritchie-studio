# frozen_string_literal: true

# [unit] The 1Password read `bin/release` makes on its static_cloudflare deploy
# path (StaticCloudflare::Credentials.r2 → DomainCutover::Credentials.op_read)
# carries a deadline. From 06:14 to 08:17 MDT on 2026-10-27 every `op` call hung;
# this read was the release path's last bare IO.popen, so it would have frozen a
# ship instead of failing it.
#
# A fake `op` on PATH hangs whatever it is asked; MCR_OP_DEADLINE shortens
# OpMeter's per-attempt bound so the case runs in about a second.
#
#   ruby -Itest test/lib/release_op_read_deadline_test.rb

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/domain_cutover"
require_relative "../../bin/lib/static_cloudflare"

class ReleaseOpReadDeadlineTest < Minitest::Test
  def with_op(body)
    Dir.mktmpdir("release-op-read") do |dir|
      op = File.join(dir, "op")
      File.write(op, "#!/bin/sh\n#{body}\n")
      File.chmod(0o755, op)
      saved = ENV.to_h.slice("PATH", "MCR_OP_DEADLINE", "MCR_OP_READS_LOG")
      ENV["PATH"] = [dir, ENV["PATH"]].join(File::PATH_SEPARATOR)
      ENV["MCR_OP_DEADLINE"] = "0.5"
      ENV["MCR_OP_READS_LOG"] = File.join(dir, "op-reads.log")
      begin
        yield File.join(dir, "op-reads.log")
      ensure
        %w[PATH MCR_OP_DEADLINE MCR_OP_READS_LOG].each { |key| ENV[key] = saved[key] }
      end
    end
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  def test_a_hung_op_read_returns_empty_within_two_deadlines_and_is_logged_as_timeouts
    with_op("exec sleep 600") do |log|
      value, elapsed = timed { DomainCutover::Credentials.op_read("op://v/i/f", {}) }

      assert_equal "", value
      assert_operator elapsed, :<, 10, "the read waited on a hung op instead of killing it"
      outcomes = File.readlines(log).map { |row| row.split("\t")[3] }
      assert_equal %w[timeout timeout], outcomes, "both attempts (cached, then OP_CACHE=false) time out and are metered"
    end
  end

  def test_the_release_r2_credential_read_refuses_a_hung_op_as_an_empty_item
    with_op("exec sleep 600") do
      error, elapsed = timed do
        assert_raises(StaticCloudflare::Abort) { StaticCloudflare::Credentials.r2("r2.static") }
      end

      assert_match(/read empty/, error.message)
      assert_operator elapsed, :<, 20, "three bounded reads, never a hang"
    end
  end

  def test_a_healthy_op_read_still_returns_its_value
    with_op("printf 'VALUE'") do
      assert_equal "VALUE", DomainCutover::Credentials.op_read("op://v/i/f", {})
    end
  end
end

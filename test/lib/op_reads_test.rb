# frozen_string_literal: true

# [unit] bin/op-reads, the query half of OpMeter, run as a process on a temp read log
# (MCR_OP_READS_LOG) and a temp ratchet config. Never the real log; runs no `op`.

require "minitest/autorun"
require "tmpdir"
require "open3"
require "yaml"
require "json"
require "rbconfig"

class OpReadsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def op_reads(env, *args)
    Open3.capture3({ "TASK_USAGE_SANDBOX" => "1" }.merge(env), RbConfig.ruby, File.join(ROOT, "bin", "op-reads"), *args)
  end

  def rows(log, count, caller: "gh-token", action: "read", outcome: "ok")
    stamp = (Time.now.utc - 60).strftime("%Y-%m-%dT%H:%M:%SZ")
    File.open(log, "a") do |f|
      count.times { f.puts([stamp, caller, action, outcome, "#{caller}:agent", "1", "-"].join("\t")) }
    end
  end

  def test_unit_by_caller_ranks_the_callers_most_first
    Dir.mktmpdir do |dir|
      log = File.join(dir, "op-reads.log")
      rows(log, 1, caller: "secret")
      rows(log, 3)
      out, _err, status = op_reads({ "MCR_OP_READS_LOG" => log }, "--json")

      assert status.success?
      assert_equal [["gh-token", 3], ["secret", 1]], JSON.parse(out)["groups"].map { |g| [g["caller"], g["reads"]] }
    end
  end

  def test_unit_op_reads_ratchet_exits_one_over_the_cap_and_zero_under_it
    Dir.mktmpdir do |dir|
      log = File.join(dir, "op-reads.log")
      rows(log, 3)
      run = lambda do |cap|
        config = File.join(dir, "cap-#{cap}.yml")
        File.write(config, YAML.dump("daily_cap" => cap, "cap_history" => [{ "cap" => cap }], "callers" => {}))
        env = { "MCR_OP_READS_LOG" => log, "MCR_OP_RATCHET_CONFIG" => config }
        op_reads(env, "--ratchet")
      end

      out, _err, status = run.call(2)
      assert_equal 1, status.exitstatus, out
      assert_match(/3 op call\(s\) in the last 24h; daily_cap 2 .*OVER the cap/, out)
      _out, _err, status = run.call(3)
      assert_equal 0, status.exitstatus
    end
  end

  def test_unit_bookkeeping_and_timeouts_do_not_count_toward_the_cap
    Dir.mktmpdir do |dir|
      log = File.join(dir, "op-reads.log")
      rows(log, 1)
      rows(log, 2, action: "cache-hit")
      rows(log, 2, outcome: "timeout")
      config = File.join(dir, "cap.yml")
      File.write(config, YAML.dump("daily_cap" => 1, "cap_history" => [{ "cap" => 1 }], "callers" => {}))
      out, _err, status = op_reads({ "MCR_OP_READS_LOG" => log, "MCR_OP_RATCHET_CONFIG" => config }, "--ratchet", "--json")

      assert status.success?, out
      assert_equal 1, JSON.parse(out)["count"]
    end
  end
end

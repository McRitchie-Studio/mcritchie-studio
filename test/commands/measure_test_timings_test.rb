# frozen_string_literal: true

# bin/measure-test-timings, run end to end on fixture receipts: how several CI runs fold
# into one weight per file, and which files the result may name.
#
# Run directly:
#   ruby -Itest test/commands/measure_test_timings_test.rb
#
# One tier (backend shape):
#   [integration] the real binary, run against the real lane manifest, over synthetic
#   shard receipts; no suite run.

require "minitest/autorun"
require "json"
require "fileutils"
require "open3"
require "tmpdir"
require "yaml"

class MeasureTestTimingsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  BIN = File.join(ROOT, "bin", "measure-test-timings")

  # Two files the lane owns today, and one it does not.
  HEAVY = "test/lib/test_shard_test.rb"
  LIGHT = "test/commands/measure_test_timings_test.rb"
  GONE = "test/lib/long_since_deleted_test.rb"

  def write_receipt(dir, shard, commit, files)
    FileUtils.mkdir_p(dir)
    body = { "shard" => shard, "shards" => 2, "commit" => commit,
             "files" => files.transform_values { |seconds| { "runs" => 1, "seconds" => seconds } } }
    File.write(File.join(dir, "rails-report-shard-#{shard}.json"), JSON.generate(body))
  end

  def generate(*sources, out:)
    args = sources.flat_map { |source| [ "--from", source ] }
    stdout, stderr, status = Open3.capture3(BIN, *args, "--out", out, chdir: ROOT)
    assert status.success?, "bin/measure-test-timings failed: #{stdout}#{stderr}"
    [ YAML.safe_load_file(out), File.read(out), stderr ]
  end

  def test_unit_each_run_sums_its_shards_and_runs_average
    Dir.mktmpdir do |dir|
      # Run A splits the two files across its shards; run B ran only HEAVY.
      write_receipt("#{dir}/a", 1, "aaaaaaaa11", HEAVY => 100.0)
      write_receipt("#{dir}/a", 2, "aaaaaaaa11", LIGHT => 4.0)
      write_receipt("#{dir}/b", 1, "bbbbbbbb22", HEAVY => 200.0)

      timings, text, = generate("#{dir}/a", "#{dir}/b", out: "#{dir}/timings.yml")

      assert_equal 150.0, timings[HEAVY], "a file measured by two runs weighs their mean"
      assert_equal 4.0, timings[LIGHT], "a run that never ran a file must not drag its mean toward zero"
      assert_includes text, "the mean of 2 source(s), 3 receipt(s), commits aaaaaaaa, bbbbbbbb"
      refute_includes text, "Only the RATIOS matter", "the header must not repeat the claim measured false"
    end
  end

  def test_unit_a_file_the_lane_no_longer_runs_is_dropped
    Dir.mktmpdir do |dir|
      write_receipt("#{dir}/a", 1, "cccccccc33", HEAVY => 10.0, GONE => 285.0)

      timings, _, stderr = generate("#{dir}/a", out: "#{dir}/timings.yml")

      assert_equal [ HEAVY ], timings.keys
      assert_includes stderr, GONE, "the drop is reported, not silent"
    end
  end
end

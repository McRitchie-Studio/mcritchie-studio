# frozen_string_literal: true

# bin/lib/rails_executed_set.rb — THE RAILS LANE'S VERDICT ARITHMETIC.
#
# The `rails` shards can tell you their tests PASSED. They cannot tell you they RAN THEM
# ALL — the one question a test lane structurally cannot answer about itself. Sharding
# sharpens that question rather than softening it: four buckets can each go quietly
# empty, and four green checks over nothing look exactly like four green checks over
# everything.
#
# So this reads the shards' OWN receipts (test/minitest/ci_receipt_plugin.rb) and
# compares the executed set against the set re-derived FROM THE COMMITTED TREE. Note
# which direction that runs: the gate does NOT ask the planner what it intended to run.
# It globs the repo itself and demands the receipts account for every file it finds. A
# planner bug that drops a file is therefore caught by the same line as a runner flag
# that skips one — which is the whole reason the expected set is not an artifact handed
# over from the job being audited.
#
# STDLIB ONLY (json, yaml, and bin/lib/test_shard.rb, which is itself stdlib-only). The
# gate audits the suite, so it must not be breakable by a dependency problem in the
# thing it audits — the same reason the e2e gate runs with `bundler-cache: false`.

require "json"
require "yaml"
require_relative "test_shard"

module RailsExecutedSet
  Report = Struct.new(:path, :shard, :shards, :files, :totals, :unattributed, keyword_init: true)

  module_function

  def load_reports(dir)
    Dir.glob(File.join(dir, "**", "*.json")).sort.filter_map do |path|
      parsed = begin
        JSON.parse(File.read(path))
      rescue StandardError
        nil
      end
      next nil unless parsed.is_a?(Hash) && parsed.key?("files") && parsed.key?("totals")

      Report.new(
        path: path,
        shard: parsed["shard"].to_s,
        shards: parsed["shards"].to_s,
        files: parsed["files"].is_a?(Hash) ? parsed["files"] : {},
        totals: parsed["totals"].is_a?(Hash) ? parsed["totals"] : {},
        unattributed: Array(parsed["unattributed"])
      )
    end
  end

  # The files the tree says this lane owns. Derived here, independently of the planner.
  def expected_files(root:, contract:)
    TestShard.candidate_files(
      root: root,
      include_globs: contract[:include_globs],
      exclude_globs: contract[:exclude_globs]
    )
  end

  # A file counts as EXECUTED when some shard reports at least one run for it. Present
  # with zero runs is not execution — it is the shape a collected-but-never-run file
  # takes, and every committed *_test.rb in this repo declares at least one test.
  def executed_files(reports)
    reports.each_with_object({}) do |report, acc|
      report.files.each do |file, counters|
        runs = counters.is_a?(Hash) ? counters["runs"].to_i : 0
        acc[file] = (acc[file] || 0) + runs
      end
    end
  end

  def total_skips(reports)
    reports.sum { |report| report.totals["skips"].to_i }
  end

  def total_runs(reports)
    reports.sum { |report| report.totals["runs"].to_i }
  end

  # Every problem the gate can find, as a list of human-readable lines. Empty == green.
  # Returned rather than printed so the unit tests can assert on the findings instead of
  # on stdout.
  def problems(reports:, expected:, contract:)
    problems = []

    if reports.empty?
      # ZERO RECEIPTS IS NOT ZERO PROBLEMS. "No evidence" is the exact condition this
      # gate exists to refuse; failing open here would rebuild the original bug inside
      # the guard written to kill it.
      return [ "no shard receipts found — the lane produced no evidence that it ran anything" ]
    end

    declared = contract[:shards]
    seen = reports.map(&:shard)
    missing = (1..declared).map(&:to_s) - seen
    problems << "missing receipts for shard(s) #{missing.join(', ')} of #{declared}" if missing.any?

    duplicates = seen.tally.select { |_, count| count > 1 }.keys
    problems << "more than one receipt claims shard(s) #{duplicates.join(', ')}" if duplicates.any?

    reports.each do |report|
      next if report.shards.empty? || report.shards == declared.to_s

      problems << "#{File.basename(report.path)} was produced by a #{report.shards}-shard run, " \
                  "but config/rails_lane.yml declares #{declared}"
    end

    orphans = reports.flat_map(&:unattributed).uniq.sort
    if orphans.any?
      problems << "#{orphans.length} test(s) could not be attributed to a file " \
                  "(#{orphans.first(3).join(', ')}#{orphans.length > 3 ? ', …' : ''}) — " \
                  "the arithmetic below cannot account for them"
    end

    executed = executed_files(reports)
    ran = executed.select { |_, runs| runs.positive? }.keys.sort

    never_ran = expected - ran
    if never_ran.any?
      problems << "#{never_ran.length} committed test file(s) executed NOTHING: " \
                  "#{never_ran.first(10).join(', ')}#{never_ran.length > 10 ? ", … (#{never_ran.length - 10} more)" : ''}"
    end

    unexpected = ran - expected
    if unexpected.any?
      problems << "#{unexpected.length} file(s) ran that config/rails_lane.yml does not own: " \
                  "#{unexpected.first(10).join(', ')}#{unexpected.length > 10 ? ', …' : ''}"
    end

    zero_run = executed.select { |_, runs| runs.zero? }.keys.sort
    problems << "#{zero_run.length} file(s) were collected but ran zero tests: #{zero_run.first(10).join(', ')}" if zero_run.any?

    ceiling = contract[:max_skips]
    skips = total_skips(reports)
    if ceiling && skips > ceiling
      problems << "#{skips} skipped test(s) against a ceiling of #{ceiling} in config/rails_lane.yml — " \
                  "raise the ceiling in a reviewable line, or stop skipping"
    end

    problems
  end

  def summary(reports:, expected:)
    executed = executed_files(reports)
    ran = executed.select { |_, runs| runs.positive? }.keys
    "#{reports.length} shard(s) · #{ran.length}/#{expected.length} files executed · " \
      "#{total_runs(reports)} runs · #{total_skips(reports)} skips"
  end
end

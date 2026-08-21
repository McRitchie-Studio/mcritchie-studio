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
  Report = Struct.new(:path, :shard, :shards, :commit, :files, :totals, :unattributed, keyword_init: true)

  module_function

  # The commit a tree is sitting on, or nil when that cannot be told. Nil is a real
  # answer here and means "make no claim" — see `commit_problems`.
  def tree_commit(root)
    out = IO.popen([ "git", "-C", root.to_s, "rev-parse", "HEAD" ], err: File::NULL, &:read)
    return nil unless $?&.success?

    value = out.to_s.strip
    value.empty? ? nil : value
  rescue StandardError
    nil
  end

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
        commit: parsed["commit"].to_s.strip,
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

  # The distinct commits the receipts CLAIM to have run. A receipt that names none is
  # silent rather than dissenting: old receipts predate the field, and a shard run
  # outside a git checkout cannot know. Silence never manufactures a disagreement.
  def claimed_commits(reports)
    reports.map { |report| report.commit.to_s.strip }.reject(&:empty?).uniq
  end

  def short(commit)
    commit.to_s[0, 8]
  end

  # Every problem the gate can find, as a list of human-readable lines. Empty == green.
  # Returned rather than printed so the unit tests can assert on the findings instead of
  # on stdout.
  #
  # `tree_commit` is the commit of the tree `expected` was derived from. Pass nil when it
  # cannot be determined; the gate then makes no claim about commit identity rather than
  # inventing one.
  def problems(reports:, expected:, contract:, tree_commit: nil)
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

    # ── IS THE EXPECTED SET EVEN COMPARABLE TO THE EXECUTED ONE? ───────────────────
    #
    # `expected` is re-derived from a tree this process checked out; the receipts were
    # written by shards that checked out their own. When those are the same commit the
    # arithmetic below is the whole point of this gate. When they are NOT, it compares
    # two different trees and every answer it gives is about the DIFF BETWEEN BRANCHES
    # rather than about coverage.
    #
    # THIS IS NOT HYPOTHETICAL, AND ITS FALSE VERDICT IS INDISTINGUISHABLE FROM A TRUE
    # ONE. On 2026-08-21 the engine's consumer lane (run 32495361932) reported
    # `test/docs/agent_portrait_extension_docs_test.rb` and
    # `test/lib/agent_avatar_generator_test.rb` as committed files that "executed
    # NOTHING". Both had run, green, in the hub's own lane on the same named branch
    # minutes earlier. The shards had checked out `accepted` at 15:02:17 and the gate at
    # 15:06:17; hub PR #979 merged f9a440e5 at 15:04:07, adding exactly those two files.
    # The receipts' union was byte-identical to the lane's file set at f9a440e5^. Nothing
    # had failed to run — two files had not yet existed.
    #
    # A branch name is a moving target, and a gate that reads one at two different
    # moments is reading two different trees. So the commit identity is now part of the
    # receipt, and a mismatch is reported AS a mismatch — loudly, and still RED, because
    # the honest verdict is "this cannot be audited", not "this is fine". The file-level
    # findings are withheld rather than guessed: a coverage hole and a four-minute race
    # produce the same list, and printing it under the wrong headline is what sent the
    # last reader hunting for skips that were never there.
    claimed = claimed_commits(reports)

    if claimed.length > 1
      problems << "the shards did not all run the same commit (#{claimed.map { |c| short(c) }.sort.join(', ')}) — " \
                  "their receipts describe DIFFERENT TREES, so their union is not a run of any one of them"
    end

    skewed = claimed.length == 1 && !tree_commit.nil? && claimed.first != tree_commit
    if skewed
      problems << "the receipts were produced against #{short(claimed.first)} but this tree is " \
                  "#{short(tree_commit)} — the lane's file list moved between the shards' checkout and " \
                  "this one, so the executed set cannot be audited against it. This is a CHECKOUT RACE, " \
                  "not a coverage hole: pin both checkouts to one commit and re-run"
    end

    executed = executed_files(reports)
    ran = executed.select { |_, runs| runs.positive? }.keys.sort

    # Withheld under skew, for the reason above — never silently: the skew line is
    # already in `problems`, so the run is RED and says why.
    if claimed.length <= 1 && !skewed
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

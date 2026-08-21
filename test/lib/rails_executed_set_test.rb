# frozen_string_literal: true

# Unit tests for bin/lib/rails_executed_set.rb — THE SHARDED LANE'S VERDICT GATE.
#
# THE PROPERTY UNDER TEST, on every axis at once:
#
#     EVERY COMMITTED TEST FILE THE LANE OWNS RAN AT LEAST ONE TEST, IN A SHARD WHOSE
#     RECEIPT WE ACTUALLY HAVE.
#
# The gate is proved end-to-end by CI itself; these prove its LOGIC over synthetic
# receipts, so the failure modes can be exercised in milliseconds instead of a four-shard
# CI run — including the ones that are expensive or impossible to stage for real, like a
# runner that died after reporting success, or a bin-packing bug that assigns a file to
# no bucket.
#
# WHY EACH CASE BELOW EXISTS: every one of them is a way four GREEN shard checks can sit
# over less than the whole suite. That is the only thing this gate is for.
#
# Run directly:
#   ruby -Itest test/lib/rails_executed_set_test.rb
#
# One tier (backend shape):
#   [unit] the gate's verdict over hand-built shard receipts.

require "minitest/autorun"
require "tmpdir"
require "json"
require "fileutils"
require_relative "../../bin/lib/rails_executed_set"

class RailsExecutedSetTest < Minitest::Test
  CONTRACT = { shards: 2, include_globs: [ "test/**/*_test.rb" ], exclude_globs: [], max_skips: 2 }.freeze
  EXPECTED = %w[test/a_test.rb test/b_test.rb test/c_test.rb].freeze

  def receipt(shard:, files:, shards: 2, skips: 0, unattributed: [], commit: nil)
    rows = files.to_h do |file, runs|
      [ file, { "runs" => runs, "assertions" => runs * 2, "failures" => 0, "errors" => 0, "skips" => 0, "seconds" => 0.5 } ]
    end

    {
      "shard" => shard.to_s,
      "shards" => shards.to_s,
      # "" is what a real receipt carries when the shard could not tell (no git, or a
      # receipt written before the field existed). It reads as SILENCE, not dissent.
      "commit" => commit.to_s,
      "files" => rows,
      "totals" => {
        "files" => rows.size,
        "runs" => files.values.sum,
        "assertions" => files.values.sum * 2,
        "failures" => 0, "errors" => 0, "skips" => skips, "seconds" => 1.0
      },
      "unattributed" => unattributed
    }
  end

  def with_reports(*payloads)
    Dir.mktmpdir do |dir|
      payloads.each_with_index do |payload, index|
        File.write(File.join(dir, "rails-report-shard-#{index + 1}.json"), JSON.generate(payload))
      end
      yield dir
    end
  end

  def problems_for(*payloads, contract: CONTRACT, expected: EXPECTED, tree_commit: nil)
    with_reports(*payloads) do |dir|
      RailsExecutedSet.problems(
        reports: RailsExecutedSet.load_reports(dir),
        expected: expected,
        contract: contract,
        tree_commit: tree_commit
      )
    end
  end

  # ---- the green path -----------------------------------------------------------

  def test_unit_a_complete_run_is_green
    assert_empty problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3, "test/b_test.rb" => 1 }),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 })
    )
  end

  # ---- the shapes a green-but-narrow run takes ----------------------------------

  def test_unit_a_file_that_never_ran_is_RED
    # THE CENTRAL CASE. Both shards green, every test that ran passed — and one committed
    # file was in nobody's bucket. Nothing else in the repo notices.
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3 }),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 })
    )

    assert_equal 1, problems.length
    assert_includes problems.first, "test/b_test.rb"
    assert_includes problems.first, "executed NOTHING"
  end

  def test_unit_a_file_COLLECTED_but_running_zero_tests_is_RED
    # Present in the receipt with runs: 0. A file that was loaded and contributed nothing
    # is not a file that ran — it is the shape a `.only`, an empty describe block, or a
    # class that failed to define its tests takes.
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3, "test/b_test.rb" => 0 }),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 })
    )

    refute_empty problems
    assert(problems.any? { |p| p.include?("test/b_test.rb") },
           "a file with zero runs must be named: #{problems.inspect}")
  end

  def test_unit_a_missing_shard_receipt_is_RED
    # The runner died, or the artifact upload failed. Its files are simply absent from
    # the arithmetic, and the shards that DID report are all green.
    problems = problems_for(receipt(shard: 1, files: { "test/a_test.rb" => 3 }))

    assert(problems.any? { |p| p.include?("missing receipts for shard(s) 2") }, problems.inspect)
  end

  def test_unit_zero_receipts_is_RED_not_vacuously_green
    # "No evidence" is the exact condition this gate exists to refuse. Failing open here
    # would rebuild the original bug inside the guard written to kill it.
    problems = problems_for

    assert_equal 1, problems.length
    assert_includes problems.first, "no shard receipts"
  end

  def test_unit_two_receipts_claiming_the_same_shard_is_RED
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1, "test/c_test.rb" => 1 }),
      receipt(shard: 1, files: { "test/a_test.rb" => 1 })
    )

    assert(problems.any? { |p| p.include?("more than one receipt claims shard(s) 1") }, problems.inspect)
  end

  def test_unit_a_receipt_from_a_DIFFERENT_shard_count_is_RED
    # A stale artifact from a run of a 3-way matrix, downloaded into a 2-way run. Its
    # bucket boundaries are a different cut of the tree, so its coverage claim is about
    # a lane that no longer exists.
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1 }, shards: 3),
      receipt(shard: 2, files: { "test/c_test.rb" => 1 })
    )

    assert(problems.any? { |p| p.include?("3-shard run") }, problems.inspect)
  end

  def test_unit_an_unattributed_test_is_RED
    # A test whose defining file could not be resolved cannot be counted toward any
    # file's coverage — so the arithmetic below it is unsound and says so, rather than
    # silently under-counting.
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1 }, unattributed: [ "GhostTest#test_x" ]),
      receipt(shard: 2, files: { "test/c_test.rb" => 1 })
    )

    assert(problems.any? { |p| p.include?("could not be attributed") }, problems.inspect)
  end

  def test_unit_a_file_that_ran_but_is_not_owned_by_the_contract_is_RED
    # The planner and the gate disagree about the tree. Benign-looking and never is: it
    # means the expected set the gate is auditing is not the set the lane cut.
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1, "test/z_test.rb" => 1 }),
      receipt(shard: 2, files: { "test/c_test.rb" => 1 })
    )

    assert(problems.any? { |p| p.include?("test/z_test.rb") && p.include?("does not own") }, problems.inspect)
  end

  def test_unit_skips_over_the_ceiling_are_RED
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1 }, skips: 2),
      receipt(shard: 2, files: { "test/c_test.rb" => 1 }, skips: 3)
    )

    assert(problems.any? { |p| p.include?("5 skipped test(s) against a ceiling of 2") }, problems.inspect)
  end

  def test_unit_skips_at_the_ceiling_are_green
    assert_empty problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1 }, skips: 1),
      receipt(shard: 2, files: { "test/c_test.rb" => 1 }, skips: 1)
    )
  end

  def test_unit_no_ceiling_declared_means_skips_are_not_gated
    contract = CONTRACT.merge(max_skips: nil)

    assert_empty problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 1, "test/b_test.rb" => 1 }, skips: 99),
      receipt(shard: 2, files: { "test/c_test.rb" => 1 }),
      contract: contract
    )
  end

  # ---- reading the receipts -----------------------------------------------------

  def test_unit_a_corrupt_receipt_is_not_loaded_and_reads_as_a_missing_shard
    # A truncated upload must not crash the gate, and must not be credited either — it
    # degrades to the missing-shard case, which is already RED.
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "rails-report-shard-1.json"), JSON.generate(receipt(shard: 1, files: EXPECTED.to_h { |f| [ f, 1 ] })))
      File.write(File.join(dir, "rails-report-shard-2.json"), "{ truncated")

      reports = RailsExecutedSet.load_reports(dir)
      assert_equal 1, reports.length

      problems = RailsExecutedSet.problems(reports: reports, expected: EXPECTED, contract: CONTRACT)
      assert(problems.any? { |p| p.include?("missing receipts for shard(s) 2") }, problems.inspect)
    end
  end

  def test_unit_receipts_are_found_in_nested_download_directories
    # actions/download-artifact lays each artifact out in its own subdirectory unless
    # merge-multiple flattens it. The gate must not depend on which.
    Dir.mktmpdir do |dir|
      %w[1 2].each_with_index do |shard, index|
        sub = File.join(dir, "rails-report-shard-#{shard}")
        FileUtils.mkdir_p(sub)
        files = index.zero? ? { "test/a_test.rb" => 1, "test/b_test.rb" => 1 } : { "test/c_test.rb" => 1 }
        File.write(File.join(sub, "report.json"), JSON.generate(receipt(shard: shard, files: files)))
      end

      reports = RailsExecutedSet.load_reports(dir)
      assert_equal 2, reports.length
      assert_empty RailsExecutedSet.problems(reports: reports, expected: EXPECTED, contract: CONTRACT)
    end
  end

  def test_unit_the_summary_reports_what_was_counted
    with_reports(
      receipt(shard: 1, files: { "test/a_test.rb" => 3, "test/b_test.rb" => 1 }),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 })
    ) do |dir|
      summary = RailsExecutedSet.summary(reports: RailsExecutedSet.load_reports(dir), expected: EXPECTED)

      assert_includes summary, "3/3 files executed"
      assert_includes summary, "11 runs"
    end
  end

  # ---- COMMIT IDENTITY: is the expected set even comparable to the executed one? ----
  #
  # The gate re-derives `expected` from a tree IT checks out, while the receipts were
  # written by shards that checked out THEIRS. A branch name read at two moments is two
  # trees. These cases pin which of those situations the gate may do arithmetic over.
  #
  # THE HISTORY. Engine consumer run 32495361932 called two hub test files committed
  # files that "executed NOTHING". They had run green in the hub's own lane minutes
  # earlier. The shards checked out `accepted` at 15:02:17 and the gate at 15:06:17; hub
  # PR #979 merged f9a440e5 in between, adding exactly those two files. The receipts'
  # union was byte-identical to the lane's file set at f9a440e5^. The gate's verdict was
  # arithmetically correct and completely misleading, and it cost a conductor an
  # investigation into skips that did not exist.

  OLD = "f4d2823000000000000000000000000000000000"
  NEW = "f9a440e500000000000000000000000000000000"

  def test_unit_receipts_on_the_SAME_commit_as_the_tree_audit_normally
    assert_empty problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3, "test/b_test.rb" => 1 }, commit: NEW),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 }, commit: NEW),
      tree_commit: NEW
    )
  end

  # THE ONE THAT MUST NOT BE WEAKENED. Commit identity is a precondition for the
  # arithmetic, never an excuse from it: when the commits AGREE, a file that did not run
  # is still the central RED this gate exists for. If the skew branch ever swallowed this
  # case, the gate would be decorative.
  def test_unit_a_file_that_never_ran_is_STILL_RED_when_the_commits_agree
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3 }, commit: NEW),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 }, commit: NEW),
      tree_commit: NEW
    )

    assert_equal 1, problems.length
    assert_includes problems.first, "test/b_test.rb"
    assert_includes problems.first, "executed NOTHING"
  end

  # THE REGRESSION, in the shape the engine lane actually produced it: the tree has a
  # file the receipts' commit did not, and every shard is internally fine.
  def test_unit_receipts_from_an_OLDER_commit_are_RED_as_a_RACE_not_as_a_coverage_hole
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3 }, commit: OLD),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 }, commit: OLD),
      tree_commit: NEW
    )

    assert_equal 1, problems.length,
                 "the race is the ONE finding; the file-level list is derived from two different " \
                 "trees and must not be printed beside it: #{problems.inspect}"
    assert_includes problems.first, "f4d28230"
    assert_includes problems.first, "f9a440e5"
    assert_includes problems.first, "CHECKOUT RACE"

    refute_includes problems.first, "executed NOTHING",
                    "test/b_test.rb did not fail to run — it did not EXIST at the receipts' commit. " \
                    "Naming it here is the false accusation this case exists to prevent"
  end

  # THE WORSE VARIANT the receipt field also buys: shards that STRADDLE the merge. Their
  # union is a set of files no single tree ever contained, so no verdict over it means
  # anything — including a green one.
  def test_unit_shards_that_ran_DIFFERENT_commits_are_RED
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3, "test/b_test.rb" => 1 }, commit: OLD),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 }, commit: NEW),
      tree_commit: NEW
    )

    assert_equal 1, problems.length
    assert_includes problems.first, "did not all run the same commit"
    assert_includes problems.first, "f4d28230"
    assert_includes problems.first, "f9a440e5"
  end

  # BACKWARD COMPATIBILITY, and the rule that keeps it honest: a receipt that names no
  # commit is SILENT, not dissenting. Receipts written before the field existed must
  # still be audited exactly as strictly as before — silence must never buy an exemption,
  # which is the door through which "just exclude it" would come back.
  def test_unit_a_receipt_that_names_no_commit_is_audited_STRICTLY
    problems = problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3 }),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 }),
      tree_commit: NEW
    )

    assert_equal 1, problems.length
    assert_includes problems.first, "test/b_test.rb"
    assert_includes problems.first, "executed NOTHING"
  end

  # A gate run outside a git checkout knows no commit of its own. It must fall back to
  # the old behaviour rather than treat "unknown" as "mismatched".
  def test_unit_an_unknown_tree_commit_makes_no_claim
    assert_empty problems_for(
      receipt(shard: 1, files: { "test/a_test.rb" => 3, "test/b_test.rb" => 1 }, commit: OLD),
      receipt(shard: 2, files: { "test/c_test.rb" => 7 }, commit: OLD),
      tree_commit: nil
    )
  end

  # The gate's own checkout is a git checkout in every environment that runs it, so the
  # resolver has to work on a real repository rather than only on fixtures.
  def test_unit_tree_commit_reads_a_real_repository_and_nil_outside_one
    root = File.expand_path("../..", __dir__)

    assert_match(/\A[0-9a-f]{40}\z/, RailsExecutedSet.tree_commit(root).to_s,
                 "the gate must be able to name the commit it derived `expected` from")

    Dir.mktmpdir do |dir|
      assert_nil RailsExecutedSet.tree_commit(dir),
                 "outside a repository the answer is 'no claim' — never a mismatch"
    end
  end
end

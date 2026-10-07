# frozen_string_literal: true

# Unit tests for bin/lib/test_shard.rb — HOW THE RAILS SUITE IS CUT.
#
# THE PROPERTY UNDER TEST, and it is the only one that can make the lane WRONG rather
# than merely SLOW:
#
#     THE CONCATENATION OF THE BUCKETS IS A PERMUTATION OF THE INPUT.
#
# Nothing dropped, nothing duplicated, for every input — including the degenerate ones.
# Balance is an optimisation and is tested as such; coverage is the contract, and it is
# tested as a property over generated inputs rather than over one hand-picked example,
# because the failure that actually happened (see the all-zero case below) was invisible
# on every example anyone would hand-pick.
#
# Run directly:
#   ruby -Itest test/lib/test_shard_test.rb
#
# One tier (backend shape):
#   [unit] the packer's coverage, determinism and balance over synthetic file sets.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/test_shard"

class TestShardTest < Minitest::Test
  FILES = (1..40).map { |i| format("test/models/m%02d_test.rb", i) }.freeze

  # A spread with a long tail and a couple of heavyweights — the real shape of a Rails
  # suite, where the heaviest file costs more than the lightest two hundred combined.
  TIMINGS = FILES.each_with_index.to_h { |file, i| [ file, (i.zero? ? 120.0 : (40 - i) * 0.5) ] }.freeze

  # ---- the contract: coverage ---------------------------------------------------

  def test_unit_the_buckets_are_a_permutation_of_the_input
    (1..8).each do |shards|
      buckets = TestShard.plan(files: FILES, timings: TIMINGS, shards: shards)

      assert_equal shards, buckets.length, "asked for #{shards} buckets"
      assert_equal FILES.sort, buckets.flatten.sort,
                   "#{shards} shards: the buckets must union to the input, with nothing duplicated"
      assert_equal buckets.flatten.length, buckets.flatten.uniq.length,
                   "#{shards} shards: a file landed in more than one bucket"
    end
  end

  def test_unit_an_empty_timings_file_still_spreads_the_files
    # THE BUG THIS PINS, measured on the real tree before it was fixed: with NO
    # measurements at all every weight was 0.0, every bucket stayed at load zero, and
    # the lightest-bucket rule kept choosing index 0 — all 459 files went to shard 1 and
    # the other three ran NOTHING. Four green checks, three of them over an empty set.
    #
    # It is the exact shape the executed-set gate exists to catch at runtime, and the
    # exact shape a hand-picked example hides: any timings hash with one real number in
    # it packs fine.
    buckets = TestShard.plan(files: FILES, timings: {}, shards: 4)

    assert_equal FILES.sort, buckets.flatten.sort
    buckets.each_with_index do |bucket, index|
      refute_empty bucket, "shard #{index + 1} got nothing when no file had a measurement"
    end
    assert_operator buckets.map(&:length).max - buckets.map(&:length).min, :<=, 1,
                    "with no timings the packer should split evenly BY COUNT"
  end

  def test_unit_a_zero_measurement_is_treated_as_unmeasured_not_as_free
    # A 0.0 in the file is a measurement artefact, not a free test. Treated literally it
    # reintroduces the collapse above for whatever subset carries it.
    zeroed = FILES.to_h { |file| [ file, 0.0 ] }
    buckets = TestShard.plan(files: FILES, timings: zeroed, shards: 3)

    buckets.each_with_index { |bucket, i| refute_empty bucket, "shard #{i + 1} got nothing" }
    assert_equal FILES.sort, buckets.flatten.sort
  end

  def test_unit_files_missing_from_the_timings_still_run
    # TIMINGS IS AN OPTIMISATION, NEVER A CONTRACT. A file added since the last
    # measurement must still land in a bucket — a stale timings file may make the lane
    # slower and may never make it narrower.
    newcomer = "test/models/brand_new_test.rb"
    buckets = TestShard.plan(files: FILES + [ newcomer ], timings: TIMINGS, shards: 4)

    assert_includes buckets.flatten, newcomer
  end

  def test_unit_the_cut_is_deterministic
    # A re-run of a red shard must run the SAME files as the run it is re-running.
    first = TestShard.plan(files: FILES, timings: TIMINGS, shards: 4)
    second = TestShard.plan(files: FILES.shuffle, timings: TIMINGS, shards: 4)

    assert_equal first, second, "the cut must not depend on the order the files arrive in"
  end

  def test_unit_more_shards_than_files_leaves_empty_buckets_rather_than_dropping_files
    # Stated rather than defended: bin/ci-shard ABORTS on an empty bucket, because a
    # `bin/rails test` with no paths runs the WHOLE suite. The packer's job here is only
    # to not lose anything.
    buckets = TestShard.plan(files: FILES.first(3), timings: {}, shards: 5)

    assert_equal 5, buckets.length
    assert_equal FILES.first(3).sort, buckets.flatten.sort
  end

  def test_unit_a_single_shard_is_the_whole_suite
    assert_equal [ FILES.sort ], TestShard.plan(files: FILES, timings: TIMINGS, shards: 1)
  end

  def test_unit_zero_or_negative_shards_raise
    assert_raises(ArgumentError) { TestShard.plan(files: FILES, timings: TIMINGS, shards: 0) }
    assert_raises(ArgumentError) { TestShard.plan(files: FILES, timings: TIMINGS, shards: -1) }
  end

  def test_unit_a_shard_index_outside_the_matrix_raises
    assert_raises(ArgumentError) { TestShard.files_for(index: 0, shards: 4, files: FILES, timings: TIMINGS) }
    assert_raises(ArgumentError) { TestShard.files_for(index: 5, shards: 4, files: FILES, timings: TIMINGS) }
  end

  # ---- the optimisation: balance ------------------------------------------------

  def test_unit_the_packer_balances_measured_work
    buckets = TestShard.plan(files: FILES, timings: TIMINGS, shards: 4)
    loads = TestShard.loads(buckets, TIMINGS)

    # One 120s outlier against 39 files summing to ~390s: the heavy file pins its own
    # shard, and LPT should keep the rest within a fraction of the heaviest.
    spread = loads.max - loads.min
    assert_operator spread, :<=, loads.max * 0.75,
                    "LPT left the shards at #{loads.inspect} — that is not a bin-packing"
  end

  def test_unit_balance_beats_an_alphabetical_cut
    # The whole justification for measuring anything. If the packed cut is not better
    # balanced than the naive one, delete bin/measure-test-timings and take the naive one.
    packed = TestShard.loads(TestShard.plan(files: FILES, timings: TIMINGS, shards: 4), TIMINGS)

    naive_buckets = FILES.each_slice((FILES.length / 4.0).ceil).to_a
    naive = TestShard.loads(naive_buckets, TIMINGS)

    assert_operator packed.max, :<, naive.max,
                    "packed #{packed.inspect} is no better than alphabetical #{naive.inspect}"
  end

  # ---- the manifest -------------------------------------------------------------

  def test_unit_candidate_files_are_repo_relative_sorted_and_deduped
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test", "models"))
      FileUtils.mkdir_p(File.join(root, "test", "system"))
      FileUtils.touch(File.join(root, "test", "models", "b_test.rb"))
      FileUtils.touch(File.join(root, "test", "models", "a_test.rb"))
      FileUtils.touch(File.join(root, "test", "system", "browser_test.rb"))
      FileUtils.touch(File.join(root, "test", "models", "support_helper.rb"))

      files = TestShard.candidate_files(
        root: root,
        include_globs: [ "test/**/*_test.rb" ],
        exclude_globs: [ "test/system/**/*_test.rb" ]
      )

      assert_equal [ "test/models/a_test.rb", "test/models/b_test.rb" ], files
    end
  end

  def test_unit_an_overlapping_include_glob_does_not_duplicate_a_file
    Dir.mktmpdir do |root|
      FileUtils.mkdir_p(File.join(root, "test", "models"))
      FileUtils.touch(File.join(root, "test", "models", "a_test.rb"))

      files = TestShard.candidate_files(
        root: root,
        include_globs: [ "test/**/*_test.rb", "test/models/*_test.rb" ]
      )

      assert_equal [ "test/models/a_test.rb" ], files
    end
  end

  # ---- reading the contract and the timings -------------------------------------

  def test_unit_a_missing_timings_file_is_not_an_error
    assert_equal({}, TestShard.load_timings("/nonexistent/timings.yml"))
    assert_equal({}, TestShard.load_timings(nil))
  end

  def test_unit_a_corrupt_timings_file_is_not_an_error
    Dir.mktmpdir do |dir|
      path = File.join(dir, "timings.yml")
      File.write(path, "]: not: valid: yaml: [")
      assert_equal({}, TestShard.load_timings(path), "a corrupt timings file must degrade to unmeasured, not raise")
    end
  end

  def test_unit_non_numeric_timing_entries_are_ignored
    Dir.mktmpdir do |dir|
      path = File.join(dir, "timings.yml")
      File.write(path, { "a_test.rb" => 1.5, "b_test.rb" => "slow" }.to_yaml)
      assert_equal({ "a_test.rb" => 1.5 }, TestShard.load_timings(path))
    end
  end

  def test_unit_the_live_contract_parses_and_declares_a_sane_shard_count
    contract = TestShard.load_contract(File.expand_path("../../config/rails_lane.yml", __dir__))

    assert_operator contract[:shards], :>=, 1
    refute_empty contract[:include_globs], "the lane must own at least one glob"
  end
end

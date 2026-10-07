# frozen_string_literal: true

# THE SHARDED LANE'S COVERAGE CONTRACT — the claim that licenses everything else.
#
# Two separate mechanisms lean on ONE property, and neither can check it:
#
#   · bin/rails-executed-set-check asserts CI ran everything the SHARDED lane owns. It
#     is silent about the files the contract EXCLUDES — by design, since another job
#     runs them.
#   · config/release_repos.yml names `bin/rails db:test:prepare test test:system` as the
#     suite at G3/G4, which is honest only while the sharded lane plus the `system` job
#     covers what that command runs.
#
# The gap between them is exactly this: is `lane manifest ∪ excluded` the whole tree?
# If the contract ever excludes a directory no other job runs, both stay green and
# a tier goes dark — the 2026-07-12 disease, one config file over. So it is asserted
# here, on the real tree, rather than believed twice.
#
# Run directly:
#   ruby -Itest test/lib/rails_lane_contract_test.rb
#
# One tier (backend shape):
#   [unit] the lane contract's file sets against the committed tree and ci.yml.

require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/test_shard"

class RailsLaneContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONTRACT_PATH = File.join(ROOT, "config", "rails_lane.yml")
  CI_YML = File.join(ROOT, ".github", "workflows", "ci.yml")

  def contract
    @contract ||= TestShard.load_contract(CONTRACT_PATH)
  end

  def manifest
    @manifest ||= TestShard.candidate_files(
      root: ROOT,
      include_globs: contract[:include_globs],
      exclude_globs: contract[:exclude_globs]
    )
  end

  def every_test_file
    Dir.glob(File.join(ROOT, "test", "**", "*_test.rb"))
       .map { |path| TestShard.relative(path, ROOT) }
       .sort
  end

  def excluded_files
    contract[:exclude_globs]
      .flat_map { |glob| Dir.glob(File.join(ROOT, glob)) }
      .map { |path| TestShard.relative(path, ROOT) }
      .uniq
      .sort
  end

  # ---- THE SUPERSET CLAIM -------------------------------------------------------

  def test_integration_the_lane_and_its_exclusions_cover_the_whole_tree
    uncovered = every_test_file - manifest - excluded_files

    assert_empty uncovered,
                 "#{uncovered.length} committed test file(s) are in NEITHER the sharded lane NOR its " \
                 "declared exclusions: #{uncovered.first(10).inspect}. Nothing runs them, and every " \
                 "gate stays green — bin/rails-executed-set-check only audits the lane's own manifest, " \
                 "and the registry's full-suite command at G3/G4 is only honest while this set is empty."
  end

  def test_integration_the_manifest_and_the_exclusions_do_not_overlap
    overlap = manifest & excluded_files

    assert_empty overlap,
                 "#{overlap.inspect} are both owned by the sharded lane and excluded from it — one of " \
                 "the two runners would run them twice, and the executed-set arithmetic would " \
                 "disagree with itself about which."
  end

  def test_integration_the_exclusions_are_exactly_the_system_tier
    # The exclusions are only safe because ANOTHER JOB runs them, and that job runs
    # `bin/rails db:test:prepare test:system` — whose scope is test/system and nothing
    # else. Excluding anything outside test/system would be excluding something no
    # runner picks up.
    strays = excluded_files.reject { |file| file.start_with?("test/system/") }

    assert_empty strays,
                 "#{strays.inspect} are excluded from the sharded lane but are NOT system tests, so the " \
                 "`system` job (bin/rails db:test:prepare test:system) does not run them either."
  end

  def test_integration_the_system_tier_is_not_empty_while_it_has_its_own_job
    # If test/system ever empties out, the `system` job is a lane certifying nothing and
    # the exclusion is dead weight — the turf-monster shape this ecosystem already
    # carries (an empty test/system with a Chrome install paid for on every run).
    refute_empty excluded_files,
                 "test/system is empty, so the `system` job runs no tests. Delete the job and the " \
                 "exclusion together, or the workflow pays for a Chrome install to certify nothing."
  end

  # ---- THE CONTRACT AND THE WORKFLOW MUST AGREE ---------------------------------

  # The matrix is READ from the contract, not written beside it: `rails_plan` prints
  # bin/ci-shard --matrix and the `rails` job's matrix is that output.
  def test_unit_the_matrix_is_one_through_the_declared_shard_count
    assert_equal [1, 2, 3], TestShard.matrix(shards: 3)
    assert_equal (1..contract[:shards]).to_a, TestShard.matrix(contract)
  end

  def test_integration_the_workflow_reads_its_shard_matrix_from_the_contract
    ci = YAML.safe_load_file(CI_YML, aliases: true)
    plan = ci.dig("jobs", "rails_plan")

    refute_nil plan, "ci.yml has no `rails_plan` job to read the shard matrix from config/rails_lane.yml"
    assert_includes plan.fetch("steps").map { |step| step["run"].to_s }.join("\n"), "bin/ci-shard --matrix"
    assert_equal "rails_plan", ci.dig("jobs", "rails", "needs")
    assert_equal "${{ fromJSON(needs.rails_plan.outputs.shards) }}", ci.dig("jobs", "rails", "strategy", "matrix", "shard"),
                 "the rails job's matrix must be the plan's output, not a second copy of the count"
  end

  def test_integration_the_shard_matrix_does_not_fail_fast
    ci = YAML.safe_load_file(CI_YML, aliases: true)

    assert_equal false, ci.dig("jobs", "rails", "strategy", "fail-fast"),
                 "the shard matrix must set `fail-fast: false`. With it on, one red shard CANCELS the " \
                 "others — and a cancelled run folds as RED in CiStatus while its receipt never " \
                 "uploads, so the executed-set gate reports a missing shard on top of the real failure " \
                 "and the log names the wrong problem."
  end

  def test_integration_every_shard_owns_at_least_one_file
    buckets = TestShard.plan(
      files: manifest,
      timings: TestShard.load_timings(File.join(ROOT, "test", "timings.yml")),
      shards: contract[:shards]
    )

    empty = buckets.each_with_index.select { |bucket, _| bucket.empty? }.map { |_, i| i + 1 }

    assert_empty empty,
                 "shard(s) #{empty.inspect} own no files. bin/ci-shard aborts rather than run " \
                 "`bin/rails test` with no paths (which would run the WHOLE suite, silently, on every " \
                 "shard) — so this is a red build, not a slow one."
  end
end

require "test_helper"

# Integration tier (backend shape): db/seeds/54_ai_builder_multiple_candidates.rb runs
# on every deploy (db:seed reruns against a populated DB), so it must be idempotent.
#
# Regression for seed-54-not-idempotent: TrackedGithubBuilder downcases github_login in
# a before_validation, but the seed looked the row up with the RAW (mixed-case) value.
# A mixed-case login (e.g. "MagMueller") was therefore never found on re-seed — a fresh
# record was built and save! raised "Github login has already been taken" against the
# already-populated row, aborting the whole db:seed.
class AiBuilderMultipleSeedTest < ActiveSupport::TestCase
  SEED = Rails.root.join("db/seeds/54_ai_builder_multiple_candidates.rb").to_s

  def run_seed
    capture_io { load SEED }
  end

  test "seeds the builder cohort and is idempotent (no raise on re-seed)" do
    run_seed
    first = TrackedGithubBuilder.count
    assert_operator first, :>=, 27, "expected the full builder cohort"

    assert_nothing_raised { run_seed }
    assert_equal first, TrackedGithubBuilder.count,
      "re-running the seed must not create duplicate builders"
  end

  test "a mixed-case github_login re-seeds against its normalized row (no duplicate)" do
    run_seed
    # "MagMueller" in the seed is stored downcased by the model's before_validation.
    assert TrackedGithubBuilder.find_by(github_login: "magmueller"),
      "the mixed-case login must persist as its normalized form"

    assert_nothing_raised { run_seed }
    assert_equal 1, TrackedGithubBuilder.where(github_login: "magmueller").count,
      "the mixed-case login must reuse its normalized row, not raise/duplicate"
  end

  test "re-seeding writes no duplicate tracked repos" do
    run_seed
    repos = TrackedGithubBuilderRepo.count
    assert_operator repos, :>, 0, "the first seed creates tracked repos"

    run_seed
    assert_equal repos, TrackedGithubBuilderRepo.count, "re-seed must not duplicate repos"
  end
end

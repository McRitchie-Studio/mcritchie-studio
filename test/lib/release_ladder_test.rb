require "test_helper"

# [unit] Release::Ladder — which registered repos the conductor may sweep.
#
# The rule exists because `bin/release init` used to build `release` alone,
# leaving an "initialized" app with nowhere for a feature PR to land (they
# target `accepted`). These pin the decision itself; the guard that checks the
# real repos against their declarations lives in repos_test.rb.
class ReleaseLadderTest < ActiveSupport::TestCase
  CONFIG = {
    "gems" => { "a-gem" => { "ladder" => "three-rung" } },
    "apps" => {
      "live"    => { "ladder" => "three-rung" },
      "future"  => { "ladder" => "planned" },
      "parked"  => { "ladder" => "dormant" },
      "stuck"   => { "ladder" => "blocked" },
      "silent"  => { "prod_deploy" => {} }
    }
  }.freeze

  test "sweepable is three-rung only — gems and apps alike" do
    assert_equal %w[a-gem live], Release::Ladder.sweepable(CONFIG)
  end

  # The teeth. A `dormant` label that still let the conductor reach the repo
  # would be an annotation, not a decision — and reaching a repo whose remote no
  # longer resolves is what put a fetch failure in the middle of an unrelated
  # `bin/release status`.
  test "a dormant repo is excluded from the sweep, not merely labelled" do
    refute_includes Release::Ladder.sweepable(CONFIG), "parked"
    assert_equal "dormant", Release::Ladder.parked(CONFIG)["parked"]
  end

  test "a planned repo is excluded too, and reported with its reason" do
    refute_includes Release::Ladder.sweepable(CONFIG), "future"
    assert_equal "planned", Release::Ladder.parked(CONFIG)["future"]
  end

  # Silence must never read as permission. An entry with no `ladder` key is the
  # exact shape every entry had before this existed, so defaulting it to
  # three-rung would have made the guard vacuous on day one.
  test "an undeclared repo has no ladder and is not swept" do
    assert_nil Release::Ladder.ladder(CONFIG, "silent")
    refute_includes Release::Ladder.sweepable(CONFIG), "silent"
    assert_includes Release::Ladder.parked(CONFIG).keys, "silent"
  end

  test "an unknown repo has no ladder" do
    assert_nil Release::Ladder.ladder(CONFIG, "never-heard-of-it")
  end

  # `blocked` is deliberately NOT a synonym for `dormant`: dormant is a decision
  # (rolio is parked), blocked is unfinished work (chain-ops sits on a personal
  # account the automation cannot push to). Collapsing them would file the second
  # under the first and lose it.
  test "blocked is excluded from the sweep and distinct from dormant" do
    refute_includes Release::Ladder.sweepable(CONFIG), "stuck"
    assert_equal "blocked", Release::Ladder.parked(CONFIG)["stuck"]
    refute_equal Release::Ladder::DORMANT, Release::Ladder::BLOCKED
  end

  test "the vocabulary is closed" do
    assert_equal %w[three-rung planned dormant blocked], Release::Ladder::LADDERS
    %w[three-rung planned dormant blocked].each { |v| assert Release::Ladder.valid?(v) }
    refute Release::Ladder.valid?("two-rung")
    refute Release::Ladder.valid?(nil)
    refute Release::Ladder.valid?("")
  end

  # `main` is deliberately absent: every repo has one, and no repo is onboarded
  # by creating it. The rungs are the two that get built.
  test "the rungs are the two branches onboarding must create" do
    assert_equal %w[accepted release], Release::Ladder::RUNGS
  end

  test "all lists gems before apps, in declaration order" do
    assert_equal %w[a-gem live future parked stuck silent], Release::Ladder.all(CONFIG)
  end

  test "a registry with no gems or apps sections does not raise" do
    assert_equal [], Release::Ladder.sweepable({})
    assert_equal({}, Release::Ladder.parked({}))
  end
end

# frozen_string_literal: true

# THE RAILS LANE'S SKIP CEILING, RATCHETED.
#
# config/rails_lane.yml carries `max_skips`, the number of skipped tests
# bin/rails-executed-set-check tolerates before it calls the sharded lane red. It was
# MEASURED (11, identical on runs 32329490149 and 32326010830) and it was honest about
# itself: the file said, in the comment this test replaces,
#
#   "HONEST ABOUT ITS STRENGTH: this is a PIN, not a ratchet. It can be raised in the same
#    commit that adds the skip."
#
# That is the whole bug, and it is the same one config/e2e_lane.yml's `quarantined` was
# beaten by in round 4 of its own review: A GUARD THAT READS ONLY WHAT THE AUTHOR WROTE CAN
# ONLY EVER CONFIRM THAT THE AUTHOR WROTE IT. Measured there — tagging one more spec and
# bumping the contract to match passed with zero failures, and the runtime receipt went
# green right behind it, because the receipt was checked against the number that had just
# moved. The hole grew with every guard in the repo green.
#
# So the reference value is read from OUTSIDE THE DIFF: `origin/release`, the branch this
# PR must merge into, which no edit in this working tree can touch. Skips may FALL freely
# and may not RISE without a reviewer seeing the number change against a value the author
# could not reach.
#
# FAIL CLOSED. If the baseline cannot be resolved this goes RED rather than shrugging — a
# ratchet that cannot see its baseline cannot certify monotonicity, and a green light it has
# no basis for is exactly the lie being hunted. That is why the `rails` shards check out
# with `fetch-depth: 0` (pinned by test/lib/ci_workflow_triggers_test.rb): drop it and this
# turns the lane red and loud instead of quietly demoting itself back to a pin.
#
# Run directly:
#   ruby -Itest test/lib/rails_skip_ceiling_ratchet_test.rb
#
# One tier (backend shape):
#   [unit] the ceiling's monotonicity against its value on origin/release.

require "minitest/autorun"
require "yaml"
require "open3"

class RailsSkipCeilingRatchetTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  CONTRACT_REL = "config/rails_lane.yml"
  CONTRACT = File.join(ROOT, CONTRACT_REL)

  # The one value this author's diff CANNOT move. See the header.
  BASELINE_REF = "origin/release"

  def git(*args)
    out, status = Open3.capture2("git", "-C", ROOT, *args, err: File::NULL)
    status.success? ? out : nil
  end

  def ceiling_in(yaml_text)
    parsed = YAML.safe_load(yaml_text, permitted_classes: [], aliases: false)
    parsed.is_a?(Hash) ? parsed["max_skips"] : nil
  rescue StandardError
    nil
  end

  def current_ceiling
    ceiling = ceiling_in(File.read(CONTRACT))
    refute_nil ceiling, "#{CONTRACT_REL} has no readable `max_skips:` — the sharded lane's " \
                        "skip allowance is what this ratchet restrains; without it there is " \
                        "nothing to restrain and the gate tolerates any number of skips."
    ceiling
  end

  # [value, where] or [nil, why]. Never raises; the caller decides that a nil is RED.
  def baseline_ceiling
    return [nil, "git cannot read #{ROOT} (not a repository?)"] unless git("rev-parse", "--git-dir")

    unless git("rev-parse", "--verify", "--quiet", "#{BASELINE_REF}^{commit}")
      return [nil, "`#{BASELINE_REF}` does not resolve — run `git fetch origin release`. " \
                   "In CI this means the checkout lost `fetch-depth: 0`."]
    end

    released = git("show", "#{BASELINE_REF}:#{CONTRACT_REL}")
    return [nil, "`#{BASELINE_REF}:#{CONTRACT_REL}` has no readable `max_skips:`"] if released && ceiling_in(released).nil?
    return [ceiling_in(released), "#{BASELINE_REF}:#{CONTRACT_REL}"] if released

    # The contract is NEW to release — nothing to ratchet against yet, and that is not a
    # failure. Introducing a ceiling is the reviewable event; raising it later is what this
    # guard exists to catch.
    [nil, :new_contract]
  end

  def test_unit_the_skip_ceiling_may_fall_but_never_rise
    baseline, where = baseline_ceiling

    if where == :new_contract
      skip "#{CONTRACT_REL} is not on #{BASELINE_REF} yet — nothing to ratchet against"
    end

    refute_nil baseline,
               "the ratchet cannot see its baseline (#{where}), so it CANNOT certify that the " \
               "skip ceiling did not rise. It fails closed on purpose: a ratchet without a " \
               "baseline is a PIN, which is exactly what this replaces."

    assert_operator current_ceiling, :<=, baseline,
                    "config/rails_lane.yml raises `max_skips` from #{baseline} " \
                    "(#{where}) to #{current_ceiling}. Skips may FALL freely and may not RISE: " \
                    "a suite quietly growing skips is a suite quietly shrinking, and raising " \
                    "the number in the same commit that adds the skip is how that happens with " \
                    "every guard green. Fix the skip, or raise this deliberately and say why " \
                    "in the contract — where a reviewer will see it."
  end

  def test_unit_the_ceiling_is_a_non_negative_integer
    # A nil, a string or a negative would make the gate's comparison meaningless in a way
    # that reads as "green" rather than as "misconfigured".
    ceiling = current_ceiling

    assert_kind_of Integer, ceiling, "`max_skips` must be an Integer, got #{ceiling.inspect}"
    assert_operator ceiling, :>=, 0, "`max_skips` cannot be negative"
  end
end

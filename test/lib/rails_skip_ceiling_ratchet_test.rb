# frozen_string_literal: true

# THE RAILS LANE'S SKIP CEILING, RATCHETED. config/rails_lane.yml carries `max_skips`, what
# bin/rails-executed-set-check tolerates. A GUARD THAT READS ONLY WHAT THE AUTHOR WROTE CAN ONLY
# EVER CONFIRM THAT THE AUTHOR WROTE IT (the same bug as `quarantined` in config/e2e_lane.yml).
# So the reference is read from OUTSIDE THE DIFF: `origin/release`. Skips may FALL freely and
# may not RISE without a reviewer seeing the number change. FAIL CLOSED: an unresolved baseline
# goes RED, so the `rails` shards check out with `fetch-depth: 0` (pinned by
# test/lib/ci_workflow_triggers_test.rb).
# History: task ratchet-the-rails-skip-ceiling.

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

    # The contract missing from the baseline branch is NOT a special case: it fails closed like
    # any other unreadable baseline. Do not `skip` here: that is a SKIP CALL SITE, which
    # config/test_health.yml ratchets.
    # History: task ratchet-the-rails-skip-ceiling.
    [nil, "`#{BASELINE_REF}:#{CONTRACT_REL}` does not exist — the contract is not on the " \
          "baseline branch, so there is nothing to certify monotonicity against"]
  end

  def test_unit_the_skip_ceiling_may_fall_but_never_rise
    baseline, where = baseline_ceiling

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

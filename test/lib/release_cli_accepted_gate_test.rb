# frozen_string_literal: true

# bin/release.rb's `accepted` gate — the decision that refuses to promote a branch
# GitHub has already called broken. Standalone:
#   ruby -Itest test/lib/release_cli_accepted_gate_test.rb
#
# DELIBERATELY A NEW FILE, not an addition to test/lib/release_cli_test.rb. That file
# is 7056 lines and was touched by 26 of the last 200 merged PRs; everyone appends at
# the bottom, so everyone conflicts at the bottom. Putting new work in a new file is
# the same rule the dor-check plugin seam encodes, applied to tests.
#
# WHAT IS BEING PINNED: the asymmetry. `red_accepted_repos` must refuse on an ASSERTED
# failure and on nothing else. If it ever grows to mean "not green", every sweep that
# races a still-running CI aborts a release — which is a worse outage than the one this
# gate prevents, and it arrives far more often.
require "minitest/autorun"
require "tmpdir"
require "open3"

class ReleaseCliAcceptedGateTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  def decide(probe)
    call = "puts red_accepted_repos(#{probe.inspect}).keys.inspect"
    out, = Open3.capture2e(RbConfig.ruby, "-e",
                           %(ARGV.replace(["--help"]); begin; load #{BIN.inspect}; rescue SystemExit; end; #{call}))
    eval(out.lines.reverse.find { |l| l.strip.start_with?("[") }.to_s) # rubocop:disable Security/Eval
  end

  def probe(states)
    { "accepted" => states.transform_values { |s| { "state" => s, "sha" => "deadbee" } } }
  end

  def test_an_asserted_failure_refuses_the_promote
    assert_equal ["turf-monster"], decide(probe("mcritchie-studio" => "green", "turf-monster" => "red"))
  end

  def test_a_conflicted_branch_also_refuses
    assert_equal ["mcritchie-studio"], decide(probe("mcritchie-studio" => "conflicted"))
  end

  # THE WEDGE GUARDS. Each of these states means "no verdict yet", and each would
  # abort a release on every race if it counted as a failure.
  def test_pending_none_and_unverified_do_not_refuse
    assert_empty decide(probe("mcritchie-studio" => "pending", "turf-monster" => "none",
                              "studio-engine" => "unverified"))
  end

  def test_green_does_not_refuse
    assert_empty decide(probe("mcritchie-studio" => "green", "turf-monster" => "green"))
  end

  # An unrecognised state must not invent a refusal: a future CiStatus state would
  # otherwise become a release outage until somebody taught this line about it.
  def test_an_unknown_state_does_not_refuse
    assert_empty decide(probe("mcritchie-studio" => "some_new_state_nobody_taught_it"))
  end

  # Shape tolerance — the probe crosses a heroku run/JSON boundary, so a missing or
  # empty payload must read as "nothing to refuse", never raise mid-sweep.
  def test_a_missing_or_empty_probe_is_not_a_refusal
    assert_empty decide({})
    assert_empty decide({ "accepted" => {} })
    assert_empty decide(nil)
  end

  def test_every_red_repo_is_named_not_just_the_first
    assert_equal %w[mcritchie-industries turf-monster],
                 decide(probe("mcritchie-studio" => "green", "turf-monster" => "red",
                              "mcritchie-industries" => "red")).sort
  end
end

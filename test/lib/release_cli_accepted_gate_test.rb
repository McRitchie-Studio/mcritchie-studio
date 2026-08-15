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
    states.transform_values { |s| { state: s.to_sym } }
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

  # ── the guard is on the FUNCTION, so every caller inherits it ───────────────
  #
  # THE DEFECT THIS REPLACES. The refusal was originally wired in front of ONE of
  # promote_accepted_to_release!'s two call sites. bin/release prepare takes the
  # OTHER one, so the first real sweep after it shipped promoted with the guard
  # never running — its step line simply never appeared in the log.
  #
  # These tests therefore drive the FUNCTION, not a call site. That is the property
  # worth pinning: a third caller added tomorrow is guarded by construction, and
  # there is no call site left for anyone to forget. Asserting "the guard sits at
  # line N" would pin today's structure and pass again the day someone re-introduces
  # an unguarded path.

  def promote(probe_states)
    stub = <<~RUBY
      def repo_path(repo) = "/nonexistent/\#{repo}"
      def sh(*_a, **_k) = ["abc1234", true]
      def ci_verdict(_repo, _sha) = #{probe_states.values.first.to_sym.inspect}.then { |st| { state: st } }
    RUBY
    script = %(ARGV.replace(["--help"]); begin; load #{BIN.inspect}; rescue SystemExit; end; ) +
             stub +
             %(begin; promote_accepted_to_release!(["mcritchie-studio"], label: "rel-t"); ) +
             %(puts "PROMOTED"; rescue SystemExit => e; puts "REFUSED"; end)
    out, = Open3.capture2e(RbConfig.ruby, "-e", script)
    out
  end

  def test_a_red_accepted_refuses_inside_the_promote_function
    out = promote("mcritchie-studio" => "red")

    assert_includes out, "REFUSED", "the function itself must refuse, so every caller inherits it"
    assert_match(/accepted. CI is RED/, out)
    refute_includes out, "PROMOTED"
  end

  def test_a_pending_accepted_does_not_refuse_the_promote_function
    out = promote("mcritchie-studio" => "pending")

    refute_match(/CI is RED/, out, "a race is not an asserted failure")
  end

  def test_a_green_accepted_passes_the_guard
    out = promote("mcritchie-studio" => "green")

    refute_match(/CI is RED/, out)
    assert_match(/carries no RED verdict/, out,
                 "the guard must announce that it ran and passed")
  end
end

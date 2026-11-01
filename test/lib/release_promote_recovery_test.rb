require "test_helper"

# The promote step's ECHO PLACEMENT, asserted against bin/release.rb's own source.
# Release::GhFailure owns what recovery SAYS; `promote_accepted_to_release!` is a top-level def
# in a CLI that cannot be loaded into a test process (test/lib/session_env_test.rb), so the seam
# is pinned in source order.
# The echo must not sit above the `pr_merged?` fallback, gated on an `ok` it has not yet set: in
# the interrupted-run recovery gh's line ("... is already merged") is the EVIDENCE for
# continuing. Same shape as release_merge_forward_test.rb.
# History: task detect-engine-migration-content-drift.
class ReleasePromoteRecoveryTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("bin/release.rb").read.freeze

  def promote_body
    @promote_body ||= begin
      # No `\b` after the bang: `!` is not a word character, so a word boundary
      # there would need a word character next and the method is followed by `(`.
      start = SOURCE.index(/^def promote_accepted_to_release!\(/)
      assert start, "bin/release.rb must define `promote_accepted_to_release!`"
      stop = SOURCE.index(/^def /, start + 1) || SOURCE.length
      SOURCE[start...stop]
    end
  end

  test "the interrupted-run recovery quotes gh through GhFailure" do
    recovery = promote_body[/if !ok && pr_merged\?\(pr_url\).*?\n    end/m]

    assert recovery, "the promote step must keep its pr_merged? recovery branch"
    assert_includes recovery, "Release::GhFailure.recovery_message",
                    "the recovery branch must PRINT gh's captured words — they are the evidence " \
                    "for treating the failed merge as promoted"
    assert_includes recovery, "output: merge_out",
                    "and it must be the capture from THIS gh call, not a re-derived guess"
  end

  # The regression itself: no echo of the capture may precede the fallback that
  # decides whether the run survives. Placing one there is exactly the bug.
  test "no echo of the gh capture is evaluated ABOVE the fallback" do
    fallback_at = promote_body.index("if !ok && pr_merged?(pr_url)")
    assert fallback_at, "the fallback must exist to be ordered against"

    above = promote_body[0...fallback_at]
    refute_match(/say\(merge_out/, above,
                 "an echo above the fallback is gated on an `ok` the fallback has not set yet — " \
                 "that is precisely how the recovery path lost gh's output")
  end

  # And the two arms stay exclusive, so the ordering trap cannot be reintroduced
  # by re-adding a sibling `if` that runs on both paths.
  test "the success echo is the recovery branch's own else-arm" do
    assert_includes promote_body, "elsif ok && !merge_out.strip.empty?",
                    "the success echo belongs to the same conditional as the recovery, not beside it"
  end
end

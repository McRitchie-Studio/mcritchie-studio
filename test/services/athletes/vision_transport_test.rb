require "test_helper"

# [unit] THE TRAP THAT KEEPS THIS SUITE OFF THE PAID VISION API — tested as a
# mechanism, because a trap nobody tested is a trap nobody knows is armed.
#
# The task asked for "zero live calls in the test suite, proven with a TRAP rather
# than asserted". Three separate things have to be true for that to hold, and each
# one is a test below, because each one can break on its own:
#
#   1. THE TRAP BITES        — an armed transport raises instead of posting.
#   2. THE SUITE IS ARMED    — test_helper.rb actually set the variable. Delete that
#                              line and everything still passes without this test;
#                              with it, the suite goes red and names the reason.
#   3. THE DEGRADE CANNOT EAT IT — the exception escapes a `rescue StandardError`.
#      Athletes::DescribeFromHeadshot rescues StandardError by contract, so a trap
#      raising a StandardError would be swallowed by the caller it guards: the
#      careless test would see an empty result and pass QUIETLY, which is the exact
#      failure this whole file exists to make impossible.
class Athletes::VisionTransportTest < ActiveSupport::TestCase
  VT = Athletes::VisionTransport

  # 1. THE TRAP BITES.
  test "an armed transport raises rather than posting" do
    assert VT.armed?, "the suite must be armed — see the sibling test below"

    error = assert_raises(VT::LiveCallAttempted) do
      VT.call(body: { model: "x" }, api_key: "not-a-real-credential")
    end

    assert_match VT::NO_LIVE_CALLS_ENV, error.message,
                 "the refusal must name the variable that armed it, so a reader " \
                 "outside the suite can unset it"
    assert_match "Inject a transport", error.message,
                 "the refusal must print the remedy, not just the diagnosis"
  end

  test "disarming is what would let a call through, so the arming is the whole guard" do
    with_env(VT::NO_LIVE_CALLS_ENV, nil) do
      refute VT.armed?
    end
    with_env(VT::NO_LIVE_CALLS_ENV, "0") do
      refute VT.armed?, "only an explicit 1 arms it — a stray 0 must not read as armed"
    end
  end

  # 2. THE SUITE IS ARMED. Without this test, deleting the ENV line from
  # test_helper.rb breaks nothing visible and every later test can reach the network.
  test "the suite itself is armed, by test_helper, before boot" do
    assert_equal "1", ENV[VT::NO_LIVE_CALLS_ENV],
                 "test/test_helper.rb must set #{VT::NO_LIVE_CALLS_ENV}=1 before " \
                 "config/environment — without it nothing stops a test from billing"
  end

  # PINS THE AGREEMENT rather than restating one side of it. test_helper.rb has to
  # spell the variable as a LITERAL (it runs before Zeitwerk can autoload this
  # constant), so the two spellings are free to drift. This reads the helper and
  # compares, which is what makes a rename of the constant fail loudly here instead
  # of silently disarming the suite.
  test "the literal in test_helper is the constant this module reads" do
    helper = Rails.root.join("test", "test_helper.rb").read

    assert_includes helper, %(ENV["#{VT::NO_LIVE_CALLS_ENV}"] = "1"),
                    "test_helper.rb arms the trap with a literal string; renaming " \
                    "#{VT}::NO_LIVE_CALLS_ENV without updating that literal leaves " \
                    "the suite disarmed and silent"
  end

  # 3. THE DEGRADE CANNOT EAT IT — asserted BEHAVIOURALLY, through a real
  # `rescue StandardError`, not by checking the ancestry. The ancestry is the
  # mechanism; surviving that rescue is the property, and it is the property the
  # caller's contract puts at risk.
  test "the trap escapes a rescue StandardError, the way the describer's degrade would" do
    swallowed = false

    assert_raises(VT::LiveCallAttempted) do
      begin
        VT.call(body: {}, api_key: "not-a-real-credential")
      rescue StandardError
        # Athletes::DescribeFromHeadshot#call is exactly this shape, on purpose: one
        # dead image must not abort a 2,000-row backfill. If LiveCallAttempted were a
        # StandardError it would land here, the test would pass, and the trap would
        # have proven nothing.
        swallowed = true
      end
    end

    refute swallowed, "a rescue StandardError caught the trap — it must not; see " \
                      "the comment on #{VT}::LiveCallAttempted"
  end

  test "the trap is deliberately not a StandardError" do
    refute_operator VT::LiveCallAttempted, :<=, StandardError
    assert_operator VT::LiveCallAttempted, :<=, Exception
  end
end

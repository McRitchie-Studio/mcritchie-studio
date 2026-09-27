require "test_helper"

# [unit] THE TRAP THAT KEEPS THIS SUITE OFF THE PHOTO-SCOUTING LANE'S NETWORK — tested
# as a mechanism, because a trap nobody tested is a trap nobody knows is armed.
#
# The task asked for zero live calls in the suite, proven with a TRAP rather than
# asserted. Four separate things have to be true for that to hold, and each one is a
# test below because each one can break on its own:
#
#   1. THE TRAP BITES            — an armed call raises instead of reaching out.
#   2. THE SUITE IS ARMED        — test_helper.rb actually set the variable. Delete
#                                  that line and everything still passes without this
#                                  test; with it, the suite goes red and names why.
#   3. THE DEGRADE CANNOT EAT IT — the exception escapes a `rescue StandardError`.
#      Every caller in Appearances is contractually degrade-never-raise, so a trap
#      raising a StandardError would be swallowed by the very object it guards: the
#      careless test would see the documented empty Hash and pass QUIETLY while
#      billing. That is the exact failure this file exists to make impossible.
#   4. BOTH GUARDED PATHS ARE COVERED — the paid classifier AND the S3 mirror.
class Appearances::LiveCallTrapTest < ActiveSupport::TestCase
  Trap = Appearances::LiveCallTrap

  # 1. THE TRAP BITES.
  test "an armed refusal raises, and names both the variable and the remedy" do
    assert Trap.armed?, "the suite must be armed — see the sibling test below"

    error = assert_raises(Trap::LiveCallAttempted) do
      Trap.refuse!(what: "A pretend call", remedy: "Inject a pretend collaborator.")
    end

    assert_match Trap::NO_LIVE_CALLS_ENV, error.message,
                 "the refusal must name the variable that armed it, so a reader " \
                 "outside the suite can unset it"
    assert_match "A pretend call", error.message
    assert_match "Inject a pretend collaborator.", error.message,
                 "the refusal must print the remedy, not just the diagnosis"
  end

  test "disarming is what would let a call through, so the arming is the whole guard" do
    with_env(Trap::NO_LIVE_CALLS_ENV, nil) do
      refute Trap.armed?
      assert_nil Trap.refuse!(what: "x", remedy: "y"),
                 "a disarmed trap must be a no-op, not a raise"
    end
    with_env(Trap::NO_LIVE_CALLS_ENV, "0") do
      refute Trap.armed?, "only an explicit 1 arms it — a stray 0 must not read as armed"
    end
    with_env(Trap::NO_LIVE_CALLS_ENV, "true") do
      refute Trap.armed?, "only an explicit 1 arms it — presence alone must not"
    end
  end

  # 2. THE SUITE IS ARMED. Without this test, deleting the ENV line from test_helper.rb
  # breaks nothing visible and every later test can reach the network.
  test "the suite itself is armed, by test_helper, before boot" do
    assert_equal "1", ENV[Trap::NO_LIVE_CALLS_ENV],
                 "test/test_helper.rb must set #{Trap::NO_LIVE_CALLS_ENV}=1 before " \
                 "config/environment — without it nothing stops a test from billing"
  end

  # PINS THE AGREEMENT rather than restating one side of it. test_helper.rb has to
  # spell the variable as a LITERAL (it runs before Zeitwerk can autoload this
  # constant), so the two spellings are free to drift. This reads the helper and
  # compares, which is what makes a rename of the constant fail loudly here instead of
  # silently disarming the suite.
  test "the literal in test_helper is the constant this module reads" do
    helper = Rails.root.join("test", "test_helper.rb").read

    assert_includes helper, %(ENV["#{Trap::NO_LIVE_CALLS_ENV}"] = "1"),
                    "test_helper.rb arms the trap with a literal string; renaming " \
                    "#{Trap}::NO_LIVE_CALLS_ENV without updating that literal leaves " \
                    "the suite disarmed and silent"
  end

  # 3. THE DEGRADE CANNOT EAT IT — asserted BEHAVIOURALLY, through a real
  # `rescue StandardError`, not by checking the ancestry. The ancestry is the
  # mechanism; surviving that rescue is the property, and it is the property the
  # callers' contract puts at risk.
  test "the trap escapes a rescue StandardError, the way every degrade here would" do
    swallowed = false

    assert_raises(Trap::LiveCallAttempted) do
      begin
        Trap.refuse!(what: "A pretend call", remedy: "Inject something.")
      rescue StandardError
        # Appearances::FaceVisibility#call and Appearances::MirrorCandidates#mirror are
        # both exactly this shape, on purpose: one dead candidate must not cost the
        # operator the page. If LiveCallAttempted were a StandardError it would land
        # here, the test would pass, and the trap would have proven nothing.
        swallowed = true
      end
    end

    refute swallowed, "a rescue StandardError caught the trap — it must not; see " \
                      "the comment on #{Trap}::LiveCallAttempted"
  end

  test "the trap is deliberately not a StandardError" do
    refute_operator Trap::LiveCallAttempted, :<=, StandardError
    assert_operator Trap::LiveCallAttempted, :<=, Exception
  end

  # 4a. THE PAID CLASSIFIER IS GUARDED, and guarded at the method that spends rather
  # than at the one a test drives — #call, #build_content and #parse must all stay
  # free.
  test "the classifier cannot post while the suite is armed" do
    classifier = Appearances::FaceVisibility.new(api_key: "not-a-real-credential")

    error = assert_raises(Trap::LiveCallAttempted) do
      # #call would swallow a StandardError by contract; the trap is outside it, so
      # the refusal reaches here through the very rescue that would have hidden it.
      classifier.call(["https://bucket.s3.test.amazonaws.com/reference-photos/a/b/original.png"])
    end

    assert_match "Anthropic", error.message
    assert_match "faces: fake", error.message,
                 "the remedy must name the seam a careless test should have injected at"
  end

  test "the free half of the classifier is still reachable without tripping the trap" do
    classifier = Appearances::FaceVisibility.new(api_key: "not-a-real-credential")
    content = classifier.send(:build_content, ["https://bucket.s3.test.amazonaws.com/a.png"])

    assert_equal 2, content.length,
                 "building the request must not be trapped — a trap on the builder " \
                 "would push every request-shape test onto a mock and stop proving anything"
  end

  # 4b. THE MIRROR IS GUARDED. Its un-injected path would fetch a remote file AND put
  # an object in a real S3 bucket, neither of which a test may do.
  test "the mirror cannot fetch or upload while the suite is armed" do
    error = assert_raises(Trap::LiveCallAttempted) do
      Appearances::MirrorCandidates.call([])
    end

    assert_match "S3 upload", error.message
    assert_match "cache: fake", error.message
    assert_match "mirror: fake", error.message,
                 "the remedy must name BOTH seams — the cache and the whole mirror — " \
                 "because a careless test could be at either level"
  end

  # THE TRAP FIRES ON CONSTRUCTION, not on use, which is what makes it bite for the
  # empty-list case above. An un-injected mirror that only refused once it had a
  # photograph would let `call([])` pass and read as proof the path is safe.
  test "the mirror refuses at construction, before it has any candidate to excuse it" do
    assert_raises(Trap::LiveCallAttempted) { Appearances::MirrorCandidates.new([]) }
  end

  test "an injected cache is what lets the mirror run at all" do
    fake = Object.new
    assert_nothing_raised { Appearances::MirrorCandidates.new([], cache: fake) }
  end
end

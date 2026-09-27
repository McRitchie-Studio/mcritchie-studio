module Appearances
  # NOTHING IN THIS LANE REACHES THE NETWORK FROM A TEST — a trap, not an assertion.
  #
  # WHY A TRAP AND NOT A CONVENTION. Two objects here spend money or bytes on a
  # third party's network: Appearances::FaceVisibility bills per image, and
  # Appearances::MirrorCandidates fetches a remote file and writes an S3 object. Both
  # are INJECTED at their caller's seam, so the suite's protection today is that
  # every test remembers to inject. A test that forgets does not fail — it quietly
  # succeeds against the real thing, which is the one failure mode a convention
  # cannot catch.
  #
  # WHY IT IS SHARED RATHER THAN ONE TRAP PER OBJECT. Athletes::VisionTransport has
  # its own (`VISION_NO_LIVE_CALLS`) because it predates this lane and guards a
  # different caller's contract. A third and fourth variable for two neighbours in
  # one namespace would be three things to arm and three things to forget; one
  # variable arms the whole lane, and adding the next paid collaborator here is one
  # line rather than a new mechanism.
  #
  # THE EXCEPTION SITS OUTSIDE StandardError ON PURPOSE, and this is the part that
  # carries the whole guarantee. Every caller in this lane is contractually
  # degrade-never-raise — an optional enrichment must cost the operator some
  # photographs, never the page — so each one wraps its network call in a
  # `rescue StandardError`. A trap raising a StandardError would be swallowed by the
  # very object it guards: the careless test would see an empty Hash, read it as the
  # documented degrade, and pass in silence while billing. That is the same reason
  # Ruby puts SignalException outside StandardError.
  module LiveCallTrap
    # Set to "1" to make every guarded call in Appearances raise instead of
    # reaching out. test/test_helper.rb arms it for the whole suite.
    NO_LIVE_CALLS_ENV = "APPEARANCES_NO_LIVE_CALLS".freeze

    class LiveCallAttempted < Exception; end # rubocop:disable Lint/InheritException

    # ONLY AN EXPLICIT "1" ARMS IT. A stray "0" or "false" left in an environment
    # must read as disarmed rather than as mere presence, or a production box would
    # refuse the calls it exists to make.
    def self.armed? = ENV[NO_LIVE_CALLS_ENV].to_s == "1"

    # Raise when armed. `what` names the call that was about to happen and `remedy`
    # names the injection that would have avoided it — a refusal that prints only
    # the diagnosis leaves the reader to guess the fix.
    def self.refuse!(what:, remedy:)
      return unless armed?

      raise LiveCallAttempted, <<~WHY
        #{what} was attempted with #{NO_LIVE_CALLS_ENV}=1 armed.

        #{remedy}

        If you are NOT in a test, something set #{NO_LIVE_CALLS_ENV}=1 in your
        environment. Unset it.
      WHY
    end
  end
end

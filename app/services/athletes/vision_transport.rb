require "net/http"
require "json"

module Athletes
  # THE ONE PLACE A PAID VISION CALL LEAVES THIS PROCESS — and the trap that makes
  # it impossible from the test suite.
  #
  # WHY A SEPARATE OBJECT rather than a private method on the caller. The task this
  # was built for asks for "zero live calls in the test suite, proven with a trap
  # rather than asserted". An assertion is a test that checks a call did not happen;
  # a trap is a mechanism that makes the call fail. You cannot build the second one
  # out of a private method, because a test that reaches it has already reached the
  # socket. One named seam is what the arming below has to stand in front of.
  #
  # THE ARMING IS SUITE-WIDE AND SET BEFORE BOOT (test/test_helper.rb), following
  # the two traps already in this suite: the fake `op` on PATH, and
  # SEAL_RETRY_NO_SLEEP. Both exist for the same reason this does — a mistake that
  # costs real money or real seconds must surface in milliseconds as a failure,
  # never ride into CI as a slow suite or a line on a bill.
  module VisionTransport
    API_URL = "https://api.anthropic.com/v1/messages".freeze
    ANTHROPIC_VERSION = "2023-06-01".freeze

    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 60

    # Set to "1" to make every call through here raise instead of posting.
    NO_LIVE_CALLS_ENV = "VISION_NO_LIVE_CALLS".freeze

    # DELIBERATELY OUTSIDE StandardError, and this is the load-bearing detail of
    # the whole trap.
    #
    # Athletes::DescribeFromHeadshot is contractually degrade-never-raise: it
    # rescues StandardError so one dead image cannot abort a 2,000-row backfill.
    # A trap that raised a StandardError would therefore be SWALLOWED by the very
    # caller it is guarding — the careless test would see an empty result, pass
    # quietly, and the trap would have proven nothing. Sitting outside
    # StandardError means the degrade cannot catch it: the test that reached for
    # the network fails, loudly, naming itself.
    #
    # That is the same reason Ruby puts SignalException outside StandardError. This
    # is not an application error the application should recover from; it is
    # "this must not happen here".
    class LiveCallAttempted < Exception; end # rubocop:disable Lint/InheritException

    def self.armed? = ENV[NO_LIVE_CALLS_ENV].to_s == "1"

    # Posts `body` (a Hash) to the Messages API and returns the parsed response.
    # Raises on a non-2xx so the caller can file it — an HTTP 401 that returned a
    # nil answer would be indistinguishable from a model that had nothing to say.
    def self.call(body:, api_key:)
      if armed?
        raise LiveCallAttempted, <<~WHY
          A live Anthropic vision call was attempted with #{NO_LIVE_CALLS_ENV}=1 armed.
          Every paid call in this feature goes through Athletes::VisionTransport, and the
          suite arms this so no test can spend. Inject a transport instead:

            Athletes::DescribeFromHeadshot.new(transport: ->(body:, api_key:) { { ... } })

          If you are NOT in a test, something set #{NO_LIVE_CALLS_ENV}=1 in your
          environment — unset it.
        WHY
      end

      uri = URI(API_URL)
      request = Net::HTTP::Post.new(uri.path)
      request["content-type"] = "application/json"
      request["x-api-key"] = api_key
      request["anthropic-version"] = ANTHROPIC_VERSION
      request.body = body.to_json

      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                                                     open_timeout: OPEN_TIMEOUT,
                                                     read_timeout: READ_TIMEOUT) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise "Anthropic answered #{response.code}: #{response.body.to_s[0, 200]}"
      end

      JSON.parse(response.body.to_s)
    end
  end
end

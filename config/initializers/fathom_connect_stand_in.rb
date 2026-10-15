# frozen_string_literal: true

# THE STAND-IN FOR FATHOM when the Fathom connection is walked without a Fathom
# OAuth app: the e2e lane (it rides the lane's E2E_FAKE_VIDEO_STORAGE marker,
# as the Google and TikTok stand-ins do) and a local demo (FATHOM_STAND_IN=1,
# development only: a desk's .env also loads under the test environment, where
# the flag would hijack the unit tests). NEVER in production.
#
# Fathom's sign-in comes straight back to the callback with the stand-in's
# code. The token endpoint is stood in at the HTTP layer
# (Fathom::OAuthClient.http), so the real exchange, refresh and rotation run:
# like Fathom, it honours only the LAST refresh token it issued, once, and
# answers a new one each time, so a refresh that failed to store its new token
# would show up as invalid_grant on the next read.
#
# The memory is this process's own (the e2e server runs one). The reads answer
# two synthetic meetings, a three-line transcript from two speakers and a short
# summary. The callback, the stored FathomConnection and the pages are real.
# The real exchange, refresh and reads are pinned by test/services/fathom/.
module FathomConnectStandIn
  EMAIL = "stand-in@example.com"
  CODE = "fathom-stand-in-code"
  SUMMARY = "## Stand-in summary\n\n- Agreed the term sheet."

  class SignIn
    def authorize_url(redirect_uri:, state:) = "#{redirect_uri}?#{URI.encode_www_form(code: CODE, state:)}"
  end

  # Fathom's token endpoint: (url, form) -> [status, body].
  class Tokens
    def initialize
      @live = nil
      @lock = Mutex.new
    end

    def call(_url, form)
      @lock.synchronize do
        case form[:grant_type]
        when "authorization_code"
          next [ 400, { error: "invalid_grant" }.to_json ] unless form[:code] == CODE

          issue
        when "refresh_token"
          next [ 400, { error: "invalid_grant" }.to_json ] unless @live && form[:refresh_token] == @live

          issue
        else [ 400, { error: "unsupported_grant_type" }.to_json ]
        end
      end
    end

    private

    def issue
      @live = "stand-in-refresh-#{SecureRandom.hex(8)}"
      [ 200, { access_token: "stand-in-access-#{SecureRandom.hex(8)}", refresh_token: @live, expires_in: 3600, token_type: "Bearer" }.to_json ]
    end
  end

  READS = lambda do |url, _token|
    newest = Time.current.beginning_of_hour - 1.hour
    path = url.delete_prefix(Fathom::Reader::API_URL)
    body =
      case path
      when %r{\A/meetings}
        { items: [
          { title: "Stand-in: lender call", created_at: newest.iso8601, recording_id: 101, url: "https://fathom.video/calls/101",
            recorded_by: { name: "Stand In", email: EMAIL } },
          { meeting_title: "Stand-in: site visit", created_at: (newest - 1.day).iso8601, recording_id: 100, url: "https://fathom.video/calls/100",
            recorded_by: { name: "Stand In", email: EMAIL } }
        ], next_cursor: "stand-in-cursor" }
      when "/recordings/101/transcript"
        { transcript: [
          { speaker: { display_name: "Stand In" }, text: "Thanks for joining.", timestamp: "00:00:01" },
          { speaker: { display_name: "Lender" }, text: "Happy to.", timestamp: "00:00:04" },
          { speaker: { display_name: "Stand In" }, text: "Let us start with the term sheet.", timestamp: "00:00:09" }
        ] }
      when "/recordings/101/summary"
        { summary: { markdown_formatted: SUMMARY } }
      end
    body ? [ 200, body.to_json ] : [ 404, { message: "the stand-in does not answer #{path}" }.to_json ]
  end

  def self.install!
    Fathom::OAuthClient.sign_in_stand_in = SignIn.new
    Fathom::OAuthClient.http = Tokens.new
    Fathom::Reader.http = READS
  end
end

if (Rails.env.development? && ENV["FATHOM_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1")
  Rails.application.config.to_prepare { FathomConnectStandIn.install! }
end

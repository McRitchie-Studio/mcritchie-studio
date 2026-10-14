# frozen_string_literal: true

# THE STAND-IN FOR GOOGLE when the Google connection (Calendar, Gmail, Drive)
# is walked without a Google OAuth client: the e2e lane (it rides the lane's
# E2E_FAKE_VIDEO_STORAGE marker, as the TikTok stand-in does) and a local demo
# (GOOGLE_CALENDAR_STAND_IN=1, development only: a desk's .env also loads under
# the test environment, where the flag would hijack the unit tests). NEVER in
# production.
#
# Google's sign-in comes straight back to the callback with a code that
# carries the scopes the sign-in asked for; the code exchange grants exactly
# those, for stand-in@example.com, so connecting Calendar and then Drive adds
# Drive to the stored grant as Google's incremental consent does. The reads
# answer two synthetic meetings, three synthetic messages and three synthetic
# files. The callback, the stored GoogleConnection and the pages are real. The
# real exchange and reads are pinned by test/services/google_connect/.
module GoogleConnectStandIn
  EMAIL = "stand-in@example.com"

  class SignIn
    PREFIX = "stand-in-code."

    def authorize_url(redirect_uri:, state:, scopes:)
      code = PREFIX + Base64.urlsafe_encode64(scopes.join(" "), padding: false)
      "#{redirect_uri}?#{URI.encode_www_form(code:, state:)}"
    end

    def exchange_code(code:, redirect_uri:) # rubocop:disable Lint/UnusedMethodArgument
      raise GoogleConnect::OAuthClient::Error, "the stand-in takes only its own code" unless code.to_s.start_with?(PREFIX)

      scope = Base64.urlsafe_decode64(code.delete_prefix(PREFIX))
      claims = Base64.urlsafe_encode64({ email: EMAIL }.to_json, padding: false)
      { "access_token" => "stand-in-access-#{SecureRandom.hex(8)}", "refresh_token" => "stand-in-refresh-#{SecureRandom.hex(8)}",
        "scope" => scope, "id_token" => "stand-in.#{claims}.stand-in" }
    end

    def access_token(_connection) = "stand-in-access"
  end

  READS = lambda do |url, _token|
    start = Time.current.beginning_of_hour + 1.day
    body =
      if url.start_with?(GoogleConnect::CalendarReader::EVENTS_URL)
        { items: [
          { id: "stand-in-1", summary: "Stand-in: lender call", start: { dateTime: start.iso8601 }, end: { dateTime: (start + 1.hour).iso8601 },
            attendees: [ { email: "a@example.com" }, { email: "b@example.com" } ] },
          { id: "stand-in-2", summary: "Stand-in: site visit", start: { date: (start + 2.days).to_date.iso8601 }, end: { date: (start + 3.days).to_date.iso8601 } }
        ] }
      elsif (id = url[%r{/users/me/messages/([^?]+)}, 1])
        n = id.delete_prefix("stand-in-m").to_i
        { id:, internalDate: ((start - n.hours).to_i * 1000).to_s,
          payload: { headers: [ { name: "Subject", value: "Stand-in: message #{n}" }, { name: "From", value: "Sender #{n} <s#{n}@example.com>" } ] } }
      elsif url.start_with?(GoogleConnect::GmailReader::MESSAGES_URL)
        { resultSizeEstimate: 42, messages: (1..3).map { { id: "stand-in-m#{_1}" } } }
      elsif url.start_with?(GoogleConnect::DriveReader::FILES_URL)
        { files: [
          { id: "f1", name: "Stand-in: Q3 plan", mimeType: "application/vnd.google-apps.document", modifiedTime: (start - 2.hours).iso8601 },
          { id: "f2", name: "Stand-in: budget", mimeType: "application/vnd.google-apps.spreadsheet", modifiedTime: (start - 1.day).iso8601 },
          { id: "f3", name: "Stand-in: logo.png", mimeType: "image/png", modifiedTime: (start - 3.days).iso8601 }
        ] }
      end
    body ? [ 200, body.to_json ] : [ 404, { error: { message: "the stand-in does not answer #{url}" } }.to_json ]
  end

  def self.install!
    GoogleConnect::OAuthClient.sign_in_stand_in = SignIn.new
    GoogleConnect::Reader.http = READS
  end
end

if (Rails.env.development? && ENV["GOOGLE_CALENDAR_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1")
  Rails.application.config.to_prepare { GoogleConnectStandIn.install! }
end

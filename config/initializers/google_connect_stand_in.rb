# frozen_string_literal: true

# THE STAND-IN FOR GOOGLE when the Google connection (Calendar, Gmail, Drive)
# is walked without a Google OAuth client: the e2e lane (it rides the lane's
# E2E_FAKE_VIDEO_STORAGE marker, as the TikTok stand-in does) and a local demo
# (GOOGLE_CALENDAR_STAND_IN=1, development only: a desk's .env also loads under
# the test environment, where the flag would hijack the unit tests). NEVER in
# production.
#
# Google's sign-in comes straight back to the callback with a code that
# carries the scopes the sign-in asked for (.code_for); the code exchange
# grants those, for stand-in@example.com, and, as Google's
# include_granted_scopes does, echoes every scope it granted the account
# before, until a revoke forgets them. So connecting Calendar and then Drive
# answers both, and a Gmail disconnected here comes back in the echo, which
# the hub must ignore (GoogleConnection.store!).
#
# UNTICKING A PERMISSION. Google lists each scope with a checkbox. A test
# unticks one the way the browser carries it: it swaps the code on the way
# back to the callback for .code_for(the subset it grants), and the exchange
# grants that subset only (e2e/google_connect.spec.js builds the same code).
#
# The memory is this process's own (the e2e server runs one). The reads
# answer two synthetic meetings, three synthetic messages and three synthetic
# files. The callback, the stored GoogleConnection and the pages are real. The
# real exchange and reads are pinned by test/services/google_connect/.
module GoogleConnectStandIn
  EMAIL = "stand-in@example.com"

  # The code a sign-in granting `scopes` comes back with.
  def self.code_for(scopes) = SignIn::PREFIX + Base64.urlsafe_encode64(Array(scopes).join(" "), padding: false)

  class SignIn
    PREFIX = "stand-in-code."

    def initialize
      @granted = []
      @lock = Mutex.new
    end

    def authorize_url(redirect_uri:, state:, scopes:)
      "#{redirect_uri}?#{URI.encode_www_form(code: GoogleConnectStandIn.code_for(scopes), state:)}"
    end

    def exchange_code(code:, redirect_uri:) # rubocop:disable Lint/UnusedMethodArgument
      raise GoogleConnect::OAuthClient::Error, "the stand-in takes only its own code" unless code.to_s.start_with?(PREFIX)

      granted = Base64.urlsafe_decode64(code.delete_prefix(PREFIX)).split
      scope = @lock.synchronize { @granted |= granted }.join(" ")
      claims = Base64.urlsafe_encode64({ email: EMAIL, email_verified: true }.to_json, padding: false)
      { "access_token" => "stand-in-access-#{SecureRandom.hex(8)}", "refresh_token" => "stand-in-refresh-#{SecureRandom.hex(8)}",
        "scope" => scope, "id_token" => "stand-in.#{claims}.stand-in" }
    end

    def access_token(_connection) = "stand-in-access"

    # Google drops the whole grant; the next sign-in echoes nothing before it.
    # `_connection` is nil for a just-issued grant the callback refused.
    def revoke(_connection)
      @lock.synchronize { @granted = [] }
      true
    end
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
      elsif (id = url[%r{/drive/v3/files/([\w-]+)}, 1])
        # One picked file by id (DriveReader#file): any id answers, named after itself.
        { id:, name: "Stand-in: picked #{id}", mimeType: "application/vnd.google-apps.document", modifiedTime: (start - 1.hour).iso8601,
          webViewLink: "https://docs.google.com/document/d/#{id}" }
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

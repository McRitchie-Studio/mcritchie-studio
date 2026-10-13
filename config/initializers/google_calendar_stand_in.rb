# frozen_string_literal: true

# THE STAND-IN FOR GOOGLE when the Calendar connection is walked without a
# Google OAuth client: the e2e lane (it rides the lane's E2E_FAKE_VIDEO_STORAGE
# marker, as the TikTok stand-in does) and a local demo
# (GOOGLE_CALENDAR_STAND_IN=1, development only: a desk's .env also loads under
# the test environment, where the flag would hijack the unit tests). NEVER in
# production.
#
# Google's sign-in comes straight back to the callback, the code exchange
# answers a synthetic grant for stand-in@example.com, and the events read
# answers two synthetic meetings. The callback, the stored
# GoogleCalendarConnection and the page are real. The real exchange and read
# are pinned by test/services/google_calendar/oauth_client_test.rb.
module GoogleCalendarStandIn
  EMAIL = "stand-in@example.com"

  class SignIn
    CODE = "stand-in-code"

    def authorize_url(redirect_uri:, state:) = "#{redirect_uri}?#{URI.encode_www_form(code: CODE, state:)}"

    def exchange_code(code:, redirect_uri:) # rubocop:disable Lint/UnusedMethodArgument
      raise GoogleCalendar::OAuthClient::Error, "the stand-in takes only its own code" unless code == CODE

      claims = Base64.urlsafe_encode64({ email: EMAIL }.to_json, padding: false)
      { "access_token" => "stand-in-access-#{SecureRandom.hex(8)}", "refresh_token" => "stand-in-refresh-#{SecureRandom.hex(8)}",
        "scope" => GoogleCalendar::OAuthClient::SCOPES.join(" "), "id_token" => "stand-in.#{claims}.stand-in" }
    end

    def access_token(_connection) = "stand-in-access"
  end

  EVENTS = lambda do |_url, _token|
    start = Time.current.beginning_of_hour + 1.day
    items = [
      { id: "stand-in-1", summary: "Stand-in: lender call", start: { dateTime: start.iso8601 }, end: { dateTime: (start + 1.hour).iso8601 },
        attendees: [ { email: "a@example.com" }, { email: "b@example.com" } ] },
      { id: "stand-in-2", summary: "Stand-in: site visit", start: { date: (start + 2.days).to_date.iso8601 }, end: { date: (start + 3.days).to_date.iso8601 } }
    ]
    [ 200, { items: }.to_json ]
  end

  def self.install!
    GoogleCalendar::OAuthClient.sign_in_stand_in = SignIn.new
    GoogleCalendar::Reader.http = EVENTS
  end
end

if (Rails.env.development? && ENV["GOOGLE_CALENDAR_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1")
  Rails.application.config.to_prepare { GoogleCalendarStandIn.install! }
end

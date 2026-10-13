require "net/http"
require "uri"
require "json"

module GoogleCalendar
  # Reads events from a connected account's primary calendar, with the
  # connection's calendar.events.readonly grant. It holds no write path: every
  # call is a GET.
  class Reader
    EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events".freeze

    Event = Struct.new(:id, :title, :starts_at, :ends_at, :all_day, :attendees, :meet_url, keyword_init: true)

    class << self
      # Stand-in for the events call: (url, access_token) -> [status, body].
      # nil means Google itself. Set in tests and the e2e lane only.
      attr_accessor :http
    end

    def initialize(connection, oauth: OAuthClient)
      @connection = connection
      @oauth = oauth
    end

    # Events starting between `from` and `to`, earliest first, recurring
    # events expanded into their instances.
    def events(from: Time.current, to: 7.days.from_now, limit: 50)
      query = { timeMin: from.utc.iso8601, timeMax: to.utc.iso8601, singleEvents: true, orderBy: "startTime", maxResults: limit }
      status, body = get("#{EVENTS_URL}?#{URI.encode_www_form(query)}", @oauth.access_token(@connection))
      json = JSON.parse(body.to_s) rescue {}
      raise OAuthClient::Error, "Google Calendar answered #{status}: #{json.dig('error', 'message') || 'no detail'}" unless status == 200

      Array(json["items"]).map { |item| event(item) }
    end

    private

    def event(item)
      all_day = item.dig("start", "dateTime").nil?
      Event.new(id: item["id"], title: item["summary"].presence || "(no title)",
                starts_at: time(item["start"]), ends_at: time(item["end"]), all_day:,
                attendees: Array(item["attendees"]).size, meet_url: item["hangoutLink"])
    end

    def time(edge)
      return if edge.nil?

      edge["dateTime"] ? Time.iso8601(edge["dateTime"]) : Date.iso8601(edge["date"]).in_time_zone
    end

    def get(url, token)
      return self.class.http.call(url, token) if self.class.http

      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
      raise OAuthClient::Error, "Google Calendar could not be reached: #{e.class}"
    end
  end
end

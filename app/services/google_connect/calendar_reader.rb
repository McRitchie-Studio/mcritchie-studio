module GoogleConnect
  # Reads events from a connected account's primary calendar, with the
  # calendar ability's calendar.events.readonly grant.
  class CalendarReader < Reader
    LABEL = "Google Calendar".freeze
    EVENTS_URL = "https://www.googleapis.com/calendar/v3/calendars/primary/events".freeze

    Event = Struct.new(:id, :title, :starts_at, :ends_at, :all_day, :attendees, :meet_url, keyword_init: true)

    # Events starting between `from` and `to`, earliest first, recurring
    # events expanded into their instances.
    def events(from: Time.current, to: 7.days.from_now, limit: 50)
      query = { timeMin: from.utc.iso8601, timeMax: to.utc.iso8601, singleEvents: true, orderBy: "startTime", maxResults: limit }
      Array(get_json("#{EVENTS_URL}?#{URI.encode_www_form(query)}")["items"]).map { |item| event(item) }
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
  end
end

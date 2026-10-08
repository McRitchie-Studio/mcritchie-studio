module Api
  # The usage refusal the event endpoints share: 422 MISSING_EVENT_USAGE naming
  # each missing field. The rule itself is EventUsage.
  module RequiresEventUsage
    private

    # True when the event may be recorded. Otherwise renders the refusal.
    def event_usage_present?(attrs, status)
      missing = EventUsage.missing(source: attrs[:source], status: status, values: attrs)
      return true if missing.empty?

      render_error("event usage is required for #{attrs[:source]} #{status} events: #{missing.join(', ')}",
                   status: :unprocessable_entity, error_code: "MISSING_EVENT_USAGE")
      false
    end
  end
end

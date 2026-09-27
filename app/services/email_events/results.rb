module EmailEvents
  # Credits what a reader did after clicking to the email that brought them:
  # one "converted" event per goal per email (EmailEvent::GOALS), however many
  # times the goal is reported. The dedupe rides the event log's unique
  # provider_event_id, so two reports racing each other still record one.
  #
  # Reports arrive as beacons from other apps (Cyvasse's EmailReferral) or from
  # the hub's own code (/build crediting an app request).
  module Results
    module_function

    def record!(token, goal, source: "beacon")
      goal = goal.to_s
      return unless EmailEvent::GOALS.include?(goal)

      delivery = token.present? && BroadcastDelivery.find_by(token: token.to_s)
      return unless delivery

      delivery.record_event!(kind: "converted", source: source, provider_event_id: "goal:#{delivery.id}:#{goal}",
                             data: { "goal" => goal })
    end

    # Adds the email's token to a link that lands on one of our sites, so the
    # site can report results back. Other hosts get the URL unchanged: the
    # token is ours to share only with ourselves.
    def with_ref(url, token)
      uri = URI.parse(url.to_s)
      return url unless uri.is_a?(URI::HTTP) && our_host?(uri.host)

      query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == "ref" } << [ "ref", token ]
      uri.query = URI.encode_www_form(query)
      uri.to_s
    rescue URI::InvalidURIError
      url
    end

    def our_host?(host)
      host = host.to_s.downcase
      host == "mcritchie.studio" || host.end_with?(".mcritchie.studio")
    end
  end
end

module EmailEvents
  # Says whether an open or a click came from a program rather than a person.
  # It is a heuristic, and the dashboard says so: opens especially are only a
  # rough guide once Apple Mail prefetches every image.
  #
  # An event is a machine's when any of these holds:
  #   - it came as a HEAD request (link checkers probe; people's browsers GET);
  #   - it has no user agent at all;
  #   - the user agent names a scanner, crawler or script (SCANNER);
  #   - the user agent is exactly "Mozilla/5.0", which is what Apple's Mail
  #     Privacy Protection proxy sends when it prefetches a message's images;
  #   - it came within SOON of the send, before a person could plausibly have
  #     opened the email, let alone clicked in it.
  #
  # Gmail's and Yahoo's image proxies fetch the pixel only when the reader
  # opens the email, so they count as people.
  module MachineDetector
    SOON = 10.seconds
    APPLE_PREFETCH = "Mozilla/5.0"
    # Not "Microsoft Office": Outlook's desktop app sends that when a person
    # opens the email.
    SCANNER = /bot|crawl|spider|scan|python|curl|wget|java\/|go-http|okhttp|headless|
               barracuda|proofpoint|mimecast|symantec|trendmicro|forcepoint|sophos|
               safelinks|linkchecker|existence discovery/xi

    module_function

    def machine?(user_agent:, sent_at: nil, at: Time.current, method: "GET")
      ua = user_agent.to_s.strip
      return true if method.to_s.upcase == "HEAD"
      return true if ua.empty? || ua == APPLE_PREFETCH || ua.match?(SCANNER)
      return true if sent_at && at - sent_at < SOON

      false
    end
  end
end

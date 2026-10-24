# frozen_string_literal: true

module BuildIntake
  # A signed-out Build My App, remembered across the sign-in detour (task
  # build-launch-sign-in). The press binds THIS draft's token, and the address
  # it showed, to the visitor's own session; the landing after sign-in
  # (BuildController#launch, reached by the magic link's return_to and by the
  # Google path through LandingController) takes it back once and runs the launch.
  #
  #   BuildIntake::PendingLaunch.bind(session, token: draft.token, subdomain: "league-hub")
  #   BuildIntake::PendingLaunch.take(session, draft.token)   # => intent or nil, and gone
  #   BuildIntake::PendingLaunch.pending_token(session)       # => the token, while still fresh
  #   BuildIntake::PendingLaunch.clear(session)               # forget it
  #
  # Why the session and not the link: an emailed link can be forwarded, and a
  # GET must never launch an app on its own. Only the browser that pressed the
  # button holds the intent, so a link opened anywhere else finds none and only
  # reaches the draft page. The session is Rails' signed, encrypted cookie, so
  # the visitor cannot forge one.
  #
  # Single use: take deletes it whether it is fresh or stale. It expires after
  # TTL, so a press abandoned at the sign-in step does not launch a day later.
  # take for another token leaves it alone (a second tab's draft is not this one).
  module PendingLaunch
    KEY = :build_pending_launch
    TTL = 1.hour
    # The longest address a press may carry: one DNS label.
    SUBDOMAIN_LIMIT = 63

    Intent = Struct.new(:token, :subdomain, :at, keyword_init: true)

    module_function

    # The press, remembered (a later press for any draft replaces it), and
    # answered as the Intent it stored. The address is the client's to send, so
    # it is held to a DNS label's 63 characters: the session is a cookie, and an
    # address no launch could claim has no business filling it.
    def bind(session, token:, subdomain:, now: Time.current)
      subdomain = subdomain.to_s.strip.first(SUBDOMAIN_LIMIT).presence
      session[KEY] = { "token" => token.to_s, "subdomain" => subdomain, "at" => now.to_i }
      Intent.new(token: token.to_s, subdomain: subdomain, at: now.to_i)
    end

    # Forget the press (LandingController, for a draft that can no longer launch).
    def clear(session) = session.delete(KEY)

    # The intent for TOKEN, removed from the session; nil when there is none,
    # it names another draft, or it has expired (an expired one is removed too).
    def take(session, token, now: Time.current)
      intent = read(session)
      return nil unless intent && ActiveSupport::SecurityUtils.secure_compare(intent.token, token.to_s)

      session.delete(KEY)
      fresh?(intent, now) ? intent : nil
    end

    # The token a fresh intent names (for the Google landing, which knows no
    # token of its own), or nil. A stale intent is cleared here.
    def pending_token(session, now: Time.current)
      intent = read(session)
      return nil unless intent
      return intent.token if fresh?(intent, now)

      session.delete(KEY)
      nil
    end

    def read(session)
      raw = session[KEY]
      return nil unless raw.is_a?(Hash)

      raw = raw.transform_keys(&:to_s)
      return nil if raw["token"].blank? || !raw["at"].is_a?(Integer)

      Intent.new(token: raw["token"], subdomain: raw["subdomain"].presence, at: raw["at"])
    end

    def fresh?(intent, now) = intent.at <= now.to_i && now.to_i - intent.at < TTL.to_i
  end
end

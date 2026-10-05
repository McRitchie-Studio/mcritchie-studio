# Prelaunch audit H6 (2026-05-24): rate limiting on the SSO hub.
#
# mcritchie-studio is the SSO hub for the McRitchie ecosystem — a compromised
# hub account previously meant a compromised turf-monster account too (closed
# by the C3 cookie isolation, but the hub still holds user identity and any
# future satellite that re-enables SSO would re-inherit the trust). Brute-force
# on the hub login was previously unbounded; this initializer closes that.
#
# Pattern mirrors turf-monster's rack_attack.rb (OPSEC-019). Throttles are
# intentionally generous for legit usage. Test env disabled so suites don't
# accidentally hit limits.

Rails.application.config.middleware.use Rack::Attack

if Rails.env.test?
  Rack::Attack.enabled = false
end

class Rack::Attack
  ### Throttle: login (engine route) — IP + email
  throttle("login/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/login"
  end

  throttle("login/email", limit: 5, period: 1.minute) do |req|
    if req.post? && req.path == "/login"
      req.params["email"].to_s.downcase.presence
    end
  end

  ### Throttle: signup — sybil + spam prevention
  throttle("signup/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/signup"
  end

  ### Throttle: SSO continue — account-creation path from hub session fields
  # Even with C3 cookie isolation in the satellite, the hub itself processes
  # this endpoint for its own session-creation flow.
  throttle("sso_continue/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/sso_continue"
  end

  ### Throttle: OAuth callback — DoS protection on signature verification
  throttle("oauth_callback/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.get? && req.path.start_with?("/auth/") && req.path.end_with?("/callback")
  end

  ### Throttle: chat — every POST /chat costs an Anthropic call and signup is open,
  # so one address and one account are each bounded. The user key is the session's
  # user id (nil for a visitor, who counts only by address). The limits sit well
  # above a person typing and well below a loop.
  CHAT_IP_LIMIT    = 10
  CHAT_IP_PERIOD   = 1.minute
  CHAT_USER_LIMIT  = 30
  CHAT_USER_PERIOD = 10.minutes

  throttle("chat/ip", limit: CHAT_IP_LIMIT, period: CHAT_IP_PERIOD) do |req|
    req.ip if req.post? && req.path == "/chat"
  end

  throttle("chat/user", limit: CHAT_USER_LIMIT, period: CHAT_USER_PERIOD) do |req|
    if req.post? && req.path == "/chat"
      session = req.env["rack.session"] || {}
      user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
      user_id&.to_s
    end
  end

  ### Response: throttled requests get 429
  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i

    [
      429,
      {
        "Content-Type" => "application/json",
        "Retry-After" => retry_after.to_s
      },
      [{ error: "Too many requests. Try again later.", retry_after: retry_after }.to_json]
    ]
  end
end

# Log throttle hits for tuning.
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn("[rack-attack] throttled match=#{req.env['rack.attack.matched']} ip=#{req.ip} path=#{req.path}")
end

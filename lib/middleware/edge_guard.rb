# frozen_string_literal: true

require "ipaddr"

# EdgeGuard — make the CDN the ONLY way in, and let the app see the real visitor.
#
# Putting Cloudflare in front of mcritchie.studio does nothing on its own: the dyno
# answers on its own hostname too (mcritchie-studio-039470649719.herokuapp.com served
# 200s during the 2026-08-09 outage, and APP_HOST_ALIASES/DYNO_HOST allowlist it on
# purpose). Anyone who learns that name walks around the edge — around its WAF, its
# rate limits, and its bot filtering. A CDN with an open origin is decoration.
#
# The second half of the problem is subtler and fails SILENTLY. Behind a proxy,
# REMOTE_ADDR becomes the edge's address, so every per-IP defence starts measuring
# Cloudflare instead of visitors: rack_attack.rb's login brute-force throttles would
# still LOOK configured while protecting nothing. Cloudflare sends the true client in
# CF-Connecting-IP, but that header is trivially forgeable by anyone talking to the
# origin directly — so it may only be believed on a request we can PROVE came from our
# own edge.
#
# Both halves therefore hang off one proof, and that is why this is a single class:
# Cloudflare attaches a shared secret header (a Transform Rule), and a request bearing
# it is simultaneously (a) allowed through and (b) trusted about who sent it. No secret,
# no entry AND no believed client IP. One switch, one invariant, no way to get half of it.
#
# The proof has two parts, and both must hold. The secret alone would let anyone who
# ever saw it (a leaked config, a logged header) walk in from any address and name any
# client they like. So the request must ALSO have reached the Heroku router from one of
# Cloudflare's published address ranges (CLOUDFLARE_RANGES). On Heroku REMOTE_ADDR is
# the router's private address, and the router appends the address it received the
# connection from to the RIGHT of X-Forwarded-For; that rightmost entry is the edge's
# own address, and nothing a client writes can land to its right. A client's own
# X-Forwarded-For or Forwarded values sit to the left and are never read here.
#
# Dark by default. With EDGE_SECRET unset the middleware is a pass-through, so this ships
# safely BEFORE the DNS cutover and is armed afterwards by setting the variable — the
# order that avoids locking ourselves out of our own origin. (One variable rather than a
# separate enforce/trust pair, deliberately: two switches invite the half-configured
# state where traffic is refused but IPs are still wrong, or worse, the reverse.)
class EdgeGuard
  # Heroku's platform health check has no edge in front of it — it reaches the dyno
  # directly by design, and refusing it would take the app down rather than protect it.
  # Kept in step with config.host_authorization's exclusion in production.rb.
  EXEMPT_PATHS = ["/up"].freeze

  # Set by a Cloudflare Transform Rule on the way to the origin.
  SECRET_HEADER = "HTTP_X_EDGE_SECRET"

  # Cloudflare's own header naming the true client. Believed ONLY alongside the full proof.
  CLIENT_IP_HEADER = "HTTP_CF_CONNECTING_IP"

  # Cloudflare's published edge ranges: https://www.cloudflare.com/ips-v4 and
  # https://www.cloudflare.com/ips-v6, read 2026-10-24 (API etag
  # 38f79d050aa027e3be3865e495dcc9bc at https://api.cloudflare.com/client/v4/ips).
  # Cloudflare changes these rarely and announces it. A range added there and missing
  # here makes the armed guard refuse that range's traffic (a 403, never a wrongly
  # believed address), so re-check the two lists when arming and after any notice:
  # docs/agents/system/cdn-rollout.md, step 5.
  CLOUDFLARE_RANGES = %w[
    173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18
    108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17
    162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22
    2400:cb00::/32 2606:4700::/32 2803:f800::/32 2405:b500::/32 2405:8100::/32
    2a06:98c0::/29 2c0f:f248::/32
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  # Is this address one of Cloudflare's? False for anything unparseable.
  def self.cloudflare?(address)
    ip = IPAddr.new(address.to_s.strip)
    CLOUDFLARE_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }
  rescue IPAddr::Error
    false
  end

  # The address that opened the connection to the platform. Behind the Heroku router
  # (a private or loopback REMOTE_ADDR) that is the rightmost X-Forwarded-For entry,
  # the one the router wrote; with no router in front it is REMOTE_ADDR itself.
  def self.peer_address(env)
    remote = env["REMOTE_ADDR"].to_s.strip
    forwarded = env["HTTP_X_FORWARDED_FOR"].to_s.split(",").map(&:strip).reject(&:empty?)
    return remote if forwarded.empty? || !internal?(remote)

    forwarded.last
  end

  def self.internal?(address)
    ip = IPAddr.new(address)
    ip.private? || ip.loopback?
  rescue IPAddr::Error
    false
  end

  def initialize(app, secret: ENV["EDGE_SECRET"])
    @app = app
    @secret = secret.to_s.strip.presence
  end

  def call(env)
    # Not armed yet (no edge in front): behave exactly as before. This is the state the
    # change ships in, so the deploy itself can never be the thing that breaks the site.
    return @app.call(env) if @secret.nil?
    return @app.call(env) if EXEMPT_PATHS.include?(env["PATH_INFO"])

    unless from_our_edge?(env)
      return [403,
              { "Content-Type" => "text/plain; charset=utf-8", "Cache-Control" => "no-store" },
              ["This origin is reachable only through its edge.\n"]]
    end

    promote_client_ip(env)
    @app.call(env)
  end

  private

  # Both halves of the proof: the connection came from a Cloudflare address, and it
  # carries our secret. The secret comparison is constant-time so it cannot be turned
  # into an oracle for guessing the secret a byte at a time; secure_compare digests both
  # sides first, so it is safe to hand it operands of differing length.
  def from_our_edge?(env)
    presented = env[SECRET_HEADER].to_s
    return false if presented.empty?
    return false unless self.class.cloudflare?(self.class.peer_address(env))

    ActiveSupport::SecurityUtils.secure_compare(presented, @secret)
  end

  # Rewrite the request's idea of its origin to the real visitor, BEFORE Rack::Attack or
  # ActionDispatch::RemoteIp read it. Both keys are set because the two disagree about
  # where to look: Rack::Request#ip (what rack-attack throttles on) prefers
  # X-Forwarded-For, while REMOTE_ADDR is the floor Rails falls back to. Any memoized
  # remote_ip from earlier in the stack is dropped so nothing serves a stale edge address.
  def promote_client_ip(env)
    client_ip = env[CLIENT_IP_HEADER].to_s.strip
    return if client_ip.empty?

    env["REMOTE_ADDR"] = client_ip
    env["HTTP_X_FORWARDED_FOR"] = client_ip
    env.delete("action_dispatch.remote_ip")
  end
end

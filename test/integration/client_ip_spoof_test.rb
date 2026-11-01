require "test_helper"
require Rails.root.join("lib/middleware/edge_guard")

# [unit] [integration] WHOSE ADDRESS A REQUEST IS COUNTED AGAINST
# (config/initializers/forwarded_headers.rb).
#
# Every per-IP throttle reads `req.ip`, and Rails reads `request.remote_ip`.
# Both believe a `Forwarded` header the caller wrote unless the hub drops it
# from Rack's priority list, because Rack 3 prefers it to X-Forwarded-For and
# neither the Heroku router nor the edge middleware touches it.
#
# The requests here have the shape production's do: the app is reached from the
# router's private address, and the router has appended the real client to the
# right of X-Forwarded-For. Setting REMOTE_ADDR to a public address, as
# chat_throttle_test.rb does, cannot see any of this.
class ClientIpSpoofTest < ActionDispatch::IntegrationTest
  ROUTER = "10.1.2.3".freeze
  CLIENT = "198.51.100.7".freeze
  CLAIMED = "203.0.113.200".freeze

  SPOOFS = {
    "a Forwarded header" => { "HTTP_FORWARDED" => "for=#{CLAIMED}" },
    "a Forwarded header with a proxy chain" => { "HTTP_FORWARDED" => "for=#{CLAIMED};proto=https, for=10.9.9.9" },
    "a quoted IPv6 Forwarded header" => { "HTTP_FORWARDED" => "for=\"[2001:db8::1]\"" },
    "a leftmost X-Forwarded-For entry" => { "HTTP_X_FORWARDED_FOR" => "#{CLAIMED}, #{CLIENT}" },
    "both at once" => { "HTTP_FORWARDED" => "for=#{CLAIMED}", "HTTP_X_FORWARDED_FOR" => "#{CLAIMED}, #{CLIENT}" }
  }.freeze

  # Every IP-keyed throttle in config/initializers/rack_attack.rb, with a request
  # it counts.
  IP_TIERS = {
    "magic_link/ip" => ["/magic_link", "POST"],
    "signup/ip" => ["/signup", "POST"],
    "sso_continue/ip" => ["/sso_continue", "POST"],
    "oauth_callback/ip" => ["/auth/google_oauth2/callback", "GET"],
    "chat/ip" => ["/chat", "POST"],
    "voice_takes/ip" => ["/voice/takes", "POST"]
  }.freeze

  def heroku_env(path, method: "POST", **headers)
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ROUTER, "HTTP_X_FORWARDED_FOR" => CLIENT)
    env.merge(headers)
  end

  def discriminator(name, env)
    Rack::Attack.throttles.fetch(name).block.call(Rack::Attack::Request.new(env))
  end

  def remote_ip(env)
    seen = nil
    app = lambda do |inner|
      seen = ActionDispatch::Request.new(inner).remote_ip
      [200, {}, []]
    end
    ActionDispatch::RemoteIp.new(app).call(env)
    seen
  end

  def with_rack_attack(store = ActiveSupport::Cache::MemoryStore.new)
    prior_store = Rack::Attack.cache.store
    prior_enabled = Rack::Attack.enabled
    Rack::Attack.cache.store = store
    Rack::Attack.enabled = true
    yield
  ensure
    Rack::Attack.enabled = prior_enabled
    Rack::Attack.cache.store = prior_store
  end

  test "[unit] only X-Forwarded-For is read for the client address" do
    assert_equal [:x_forwarded], Rack::Request.forwarded_priority
  end

  test "[unit] with no spoof, the address is the one the router appended" do
    env = heroku_env("/magic_link")

    assert_equal CLIENT, Rack::Attack::Request.new(env).ip
    assert_equal CLIENT, remote_ip(env)
  end

  test "[unit] every IP-keyed throttle is covered here" do
    ip_keyed = Rack::Attack.throttles.keys.select { |name| name.end_with?("/ip") }

    assert_equal ip_keyed.sort, IP_TIERS.keys.sort
  end

  SPOOFS.each do |name, headers|
    test "[unit] #{name} does not change the address Rack::Attack or Rails sees" do
      env = heroku_env("/magic_link", **headers)

      assert_equal CLIENT, Rack::Attack::Request.new(env).ip
      assert_equal CLIENT, remote_ip(env)
    end

    test "[unit] #{name} does not move a caller out of their bucket on any per-IP throttle" do
      IP_TIERS.each do |throttle, (path, method)|
        assert_equal CLIENT, discriminator(throttle, heroku_env(path, method: method, **headers)), throttle
      end
    end
  end

  test "[unit] a Forwarded header cannot set the host or the scheme either" do
    env = heroku_env("/magic_link", "HTTP_FORWARDED" => "for=#{CLAIMED};host=evil.example;proto=http",
                               "HTTP_HOST" => "mcritchie.studio", "HTTP_X_FORWARDED_PROTO" => "https")

    assert_equal "mcritchie.studio", ActionDispatch::Request.new(env).host
    assert_equal "https", ActionDispatch::Request.new(env).scheme
    assert_equal "mcritchie.studio", Rack::Request.new(env).host
  end

  # --- behind an armed EdgeGuard (Cloudflare in front) ----------------------------------
  # Production shape once the hub is proxied: router's private REMOTE_ADDR, Cloudflare's
  # edge address appended rightmost by the router, the visitor in CF-Connecting-IP.
  EDGE_SECRET = "edge-secret-for-tests".freeze
  CF_EDGE = "162.158.4.4".freeze # inside 162.158.0.0/15
  STRANGER = "192.0.2.77".freeze

  def behind_guard(env)
    seen = {}
    inner = lambda do |e|
      seen[:remote_ip] = ActionDispatch::Request.new(e).remote_ip
      seen[:rack_ip] = Rack::Attack::Request.new(e).ip
      seen[:env] = e
      [200, {}, []]
    end
    app = EdgeGuard.new(ActionDispatch::RemoteIp.new(inner), secret: EDGE_SECRET)
    status, = app.call(env)
    [status, seen]
  end

  # A spoof's own X-Forwarded-For is what the client SENT: Cloudflare keeps it and the
  # router appends the edge address to its right, so it never replaces the chain.
  def cloudflare_env(path, method: "POST", edge: CF_EDGE, client: CLIENT, left: nil, **headers)
    sent = headers.delete("HTTP_X_FORWARDED_FOR")
    chain = [sent || [left, client].compact.join(", "), edge].join(", ")
    Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ROUTER, "HTTP_X_FORWARDED_FOR" => chain,
                                    "HTTP_CF_CONNECTING_IP" => client, "HTTP_X_EDGE_SECRET" => EDGE_SECRET).merge(headers)
  end

  test "[integration] behind Cloudflare, Rails and Rack::Attack both see the visitor, not the edge" do
    status, seen = behind_guard(cloudflare_env("/magic_link"))

    assert_equal 200, status
    assert_equal CLIENT, seen[:remote_ip]
    assert_equal CLIENT, seen[:rack_ip]
  end

  SPOOFS.each do |name, headers|
    test "[integration] behind Cloudflare, #{name} does not move the visitor out of any per-IP bucket" do
      IP_TIERS.each do |throttle, (path, method)|
        status, seen = behind_guard(cloudflare_env(path, method: method, left: CLAIMED, **headers))

        assert_equal 200, status, throttle
        assert_equal CLIENT, seen[:remote_ip], throttle
        assert_equal CLIENT, discriminator(throttle, seen[:env]), throttle
      end
    end

    test "[integration] armed, #{name} from a non-Cloudflare peer is refused before any reader sees it" do
      status, seen = behind_guard(cloudflare_env("/magic_link", edge: STRANGER, client: CLAIMED, **headers))

      assert_equal 403, status
      assert_empty seen, "a refused request must never reach RemoteIp, Rack::Attack or a controller"
    end
  end

  test "[integration] armed, a CF-Connecting-IP without the secret is refused even from Cloudflare" do
    env = cloudflare_env("/magic_link").except("HTTP_X_EDGE_SECRET")

    assert_equal 403, behind_guard(env).first
  end

  test "[integration] armed, the health check still answers direct to origin" do
    env = Rack::MockRequest.env_for("/up", "REMOTE_ADDR" => ROUTER, "HTTP_X_FORWARDED_FOR" => STRANGER)

    assert_equal 200, behind_guard(env).first
  end

  test "[integration] behind Cloudflare, rotating CF-Connecting-IP is still one bucket per visitor the edge names" do
    # The edge names the visitor; two visitors behind the same Cloudflare address are
    # two buckets, never one shared edge bucket that a single noisy client could fill.
    _, a = behind_guard(cloudflare_env("/chat", client: "198.51.100.7"))
    _, b = behind_guard(cloudflare_env("/chat", client: "198.51.100.8"))

    assert_equal "198.51.100.7", discriminator("chat/ip", a[:env])
    assert_equal "198.51.100.8", discriminator("chat/ip", b[:env])
  end

  # --- through the real middleware ------------------------------------------------------

  test "[integration] rotating a spoofed address on every request does not escape the chat/ip limit" do
    with_rack_attack do
      statuses = Array.new(Rack::Attack::CHAT_IP_LIMIT + 1) do |i|
        post chat_index_path, params: { message: "" }, as: :json,
                              headers: { "REMOTE_ADDR" => ROUTER,
                                         "X-Forwarded-For" => "192.0.2.#{i + 1}, #{CLIENT}",
                                         "Forwarded" => "for=203.0.113.#{i + 1}" }
        response.status
      end

      assert_equal [401] * Rack::Attack::CHAT_IP_LIMIT + [429], statuses
    end
  end
end

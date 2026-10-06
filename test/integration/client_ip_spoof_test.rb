require "test_helper"

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
    "login/ip" => ["/login", "POST"],
    "signup/ip" => ["/signup", "POST"],
    "sso_continue/ip" => ["/sso_continue", "POST"],
    "oauth_callback/ip" => ["/auth/google_oauth2/callback", "GET"],
    "chat/ip" => ["/chat", "POST"]
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
    env = heroku_env("/login")

    assert_equal CLIENT, Rack::Attack::Request.new(env).ip
    assert_equal CLIENT, remote_ip(env)
  end

  test "[unit] every IP-keyed throttle is covered here" do
    ip_keyed = Rack::Attack.throttles.keys.select { |name| name.end_with?("/ip") }

    assert_equal ip_keyed.sort, IP_TIERS.keys.sort
  end

  SPOOFS.each do |name, headers|
    test "[unit] #{name} does not change the address Rack::Attack or Rails sees" do
      env = heroku_env("/login", **headers)

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
    env = heroku_env("/login", "HTTP_FORWARDED" => "for=#{CLAIMED};host=evil.example;proto=http",
                               "HTTP_HOST" => "mcritchie.studio", "HTTP_X_FORWARDED_PROTO" => "https")

    assert_equal "mcritchie.studio", ActionDispatch::Request.new(env).host
    assert_equal "https", ActionDispatch::Request.new(env).scheme
    assert_equal "mcritchie.studio", Rack::Request.new(env).host
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

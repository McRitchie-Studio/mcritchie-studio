require "test_helper"

# [integration] THE SIGN-IN THROTTLES COUNT THE DOOR THE HUB ACTUALLY HAS.
#
# The hub signs in by magic link (POST /magic_link) or Google; it has no password
# sign-in. The IP and email throttles used to count POST /login, a password door
# the hub never meant to open, and left the magic-link door uncounted. These
# drive the real middleware, so a rule keyed to the wrong path fails here.
class MagicLinkThrottleTest < ActionDispatch::IntegrationTest
  CLIENT = "198.51.100.7".freeze

  setup do
    @prior_store = Rack::Attack.cache.store
    @prior_enabled = Rack::Attack.enabled
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
  end

  teardown do
    Rack::Attack.enabled = @prior_enabled
    Rack::Attack.cache.store = @prior_store
  end

  def request_link(email, ip: CLIENT)
    post magic_link_request_path, params: { email: email }, headers: { "REMOTE_ADDR" => ip }
    response.status
  end

  def limit(name) = Rack::Attack.throttles.fetch(name).limit

  test "[integration] one address is cut off at the magic_link/ip limit" do
    statuses = Array.new(limit("magic_link/ip") + 1) { |i| request_link("visitor#{i}@example.com") }

    assert_equal [302] * limit("magic_link/ip") + [429], statuses
    assert_equal 302, request_link("visitor@example.com", ip: "203.0.113.42"), "another address is not affected"
  end

  test "[integration] one inbox is cut off at the magic_link/email limit, whatever its spelling" do
    spellings = ["alex@example.com", " ALEX@example.com", "Alex@Example.com "]
    statuses = Array.new(limit("magic_link/email") + 1) do |i|
      request_link(spellings[i % spellings.size], ip: "203.0.113.#{i + 1}")
    end

    assert_equal [302] * limit("magic_link/email") + [429], statuses
  end
end

# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/canonical_host")

# [unit] CanonicalHost — one front door, so an OAuth handshake cannot start on a
# hostname Google has never been told about. See lib/middleware/canonical_host.rb
# for why the redirect and the pinned callback origin live in one class.
class CanonicalHostTest < ActiveSupport::TestCase
  CANONICAL = "mcritchie.studio"
  DYNO = "mcritchie-studio-039470649719.herokuapp.com"

  # A terminal app that records the env it was called with, so a test can assert both
  # WHETHER the request got through and what the downstream stack would have seen.
  class RecordingApp
    attr_reader :env

    def call(env)
      @env = env
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end

    def called? = !@env.nil?
  end

  def setup
    @downstream = RecordingApp.new
  end

  def env_for(url, method: "GET")
    Rack::MockRequest.env_for(url, method: method)
  end

  def call(url, method: "GET", canonical_host: CANONICAL, direct_hosts: [DYNO])
    CanonicalHost.new(@downstream, canonical_host: canonical_host, direct_hosts: direct_hosts)
                 .call(env_for(url, method: method))
  end

  # Rack 3 requires lowercase response header names. fetch rather than [] so a
  # miscased key fails loudly here instead of surfacing as a browser that never moves.
  def location(response) = response[1].fetch("location")

  # --- Dark by default -------------------------------------------------------------
  # APP_HOST is set only on a deployed app. Everywhere else the middleware must be a
  # pass-through rather than redirect at a GUESSED canonical host — a wrong 301 is the
  # one failure here that a visitor's browser would keep repeating on its own.

  test "passes everything through when no canonical host is configured" do
    status, = call("https://www.mcritchie.studio/tasks", canonical_host: nil)

    assert_equal 200, status
    assert @downstream.called?, "an unconfigured middleware must never redirect"
  end

  test "treats a blank canonical host as unconfigured rather than as an empty hostname" do
    status, = call("https://www.mcritchie.studio/tasks", canonical_host: "   ")

    assert_equal 200, status
    assert @downstream.called?
  end

  # --- The redirect ----------------------------------------------------------------

  test "sends an alias host to the canonical host" do
    status, = response = call("https://www.mcritchie.studio/tasks")

    assert_equal 301, status
    assert_equal "https://mcritchie.studio/tasks", location(response)
    assert_not @downstream.called?, "the alias request must not reach the app"
  end

  test "keeps the path and query string across the redirect" do
    _status, = response = call("https://www.mcritchie.studio/tasks?stage=building&q=a+b")

    assert_equal "https://mcritchie.studio/tasks?stage=building&q=a+b", location(response)
  end

  test "redirects a legacy app-subdomain alias too" do
    status, = response = call("https://app.mcritchie.studio/")

    assert_equal 301, status
    assert_equal "https://mcritchie.studio/", location(response)
  end

  test "matches the host case-insensitively" do
    status, = call("https://WWW.MCRITCHIE.STUDIO/tasks")

    assert_equal 301, status
  end

  test "leaves the canonical host alone" do
    status, = call("https://mcritchie.studio/tasks")

    assert_equal 200, status
    assert @downstream.called?, "redirecting the canonical host would loop forever"
  end

  test "preserves the request scheme rather than forcing one" do
    _status, = response = call("http://www.mcritchie.studio/tasks")

    assert_equal "http://mcritchie.studio/tasks", location(response),
                 "force_ssl owns the http->https upgrade; inventing a scheme here would mask it"
  end

  test "carries a non-default port across the redirect" do
    _status, = response = call("http://www.mcritchie.studio:3011/tasks")

    assert_equal "http://mcritchie.studio:3011/tasks", location(response)
  end

  test "redirects HEAD as well as GET" do
    status, = call("https://www.mcritchie.studio/tasks", method: "HEAD")

    assert_equal 301, status
  end

  # --- What must NOT be redirected -------------------------------------------------

  test "passes a non-GET request through untouched" do
    status, = call("https://www.mcritchie.studio/api/v1/tasks", method: "POST")

    assert_equal 200, status
    assert @downstream.called?,
           "a 301 rewrites POST to GET in browsers and is ignored by many API clients"
  end

  test "passes the platform health check through on any host" do
    status, = call("https://www.mcritchie.studio/up")

    assert_equal 200, status
    assert @downstream.called?, "Heroku polls /up without an edge or a vanity host in front"
  end

  test "leaves the direct dyno host reachable" do
    status, = call("https://#{DYNO}/tasks")

    assert_equal 200, status
    assert @downstream.called?,
           "the dyno host is allowlisted on purpose for health checks and internal tooling"
  end

  # --- The pinned OAuth origin -----------------------------------------------------
  # The same answer the redirect uses, exposed for config/initializers/omniauth.rb so
  # the callback URL cannot disagree with the front door.

  test "publishes the canonical origin as an https URL" do
    assert_equal "https://mcritchie.studio", CanonicalHost.origin("APP_HOST" => CANONICAL)
  end

  test "publishes no origin when no canonical host is configured" do
    assert_nil CanonicalHost.origin({})
    assert_nil CanonicalHost.origin("APP_HOST" => "  ")
  end

  test "normalises a canonical host that arrives with a scheme or trailing slash" do
    assert_equal "https://mcritchie.studio", CanonicalHost.origin("APP_HOST" => "https://mcritchie.studio/")
  end

  # --- Reading the deploy's own configuration --------------------------------------
  # Every case above injects the host explicitly. These two are the only ones that
  # prove the MOUNTED middleware can find it: config/initializers/canonical_host.rb
  # inserts CanonicalHost with no arguments, so those defaults are the whole wiring.

  test "defaults the canonical host to APP_HOST" do
    with_env("APP_HOST" => "qa.mcritchie.studio") do
      status, headers, = CanonicalHost.new(@downstream).call(env_for("https://www.mcritchie.studio/tasks"))

      assert_equal 301, status
      assert_equal "https://qa.mcritchie.studio/tasks", headers.fetch("location")
    end
  end

  test "defaults the hosts it leaves alone to DYNO_HOST" do
    with_env("APP_HOST" => CANONICAL, "DYNO_HOST" => DYNO) do
      status, = CanonicalHost.new(@downstream).call(env_for("https://#{DYNO}/tasks"))

      assert_equal 200, status
      assert @downstream.called?
    end
  end

  # --- A hand-typed APP_HOST -------------------------------------------------------
  # normalize's whole job. A canonical value that does not match the host requests
  # actually ARRIVE with points the page at itself, and max-age=3600 then caches that
  # loop in every visitor's browser for an hour.

  test "strips a port from the canonical host rather than redirecting a page to itself" do
    status, = call("https://mcritchie.studio/tasks", canonical_host: "mcritchie.studio:443")

    assert_equal 200, status
    assert @downstream.called?,
           "a canonical host carrying :443 must not 301 the canonical page back to itself"
  end

  test "normalises a canonical host pasted as a whole URL" do
    assert_equal "https://mcritchie.studio",
                 CanonicalHost.origin("APP_HOST" => "https://mcritchie.studio:443/tasks")
  end

  test "carries the request's own port after dropping the configured one" do
    _status, = response = call("http://www.mcritchie.studio:3011/tasks", canonical_host: "mcritchie.studio:8080")

    assert_equal "http://mcritchie.studio:3011/tasks", location(response),
                 "the port belongs to the request; the configured value names a HOST"
  end

  # --- The pinned callback ---------------------------------------------------------
  # config/initializers/omniauth.rb runs once, at boot, in an environment that by
  # definition has no APP_HOST — so this is the only place the pin is exercised.

  test "pins an omniauth config to the canonical origin" do
    config = Struct.new(:full_host).new(nil)

    assert_equal "https://qa.mcritchie.studio",
                 CanonicalHost.pin_omniauth!(config, "APP_HOST" => "qa.mcritchie.studio")
    assert_equal "https://qa.mcritchie.studio", config.full_host
  end

  test "leaves an omniauth config alone when no canonical host is configured" do
    config = Struct.new(:full_host).new(nil)

    assert_nil CanonicalHost.pin_omniauth!(config, {})
    assert_nil config.full_host, "unpinned, omniauth must keep deriving the callback per request"
  end

  private

  def with_env(values)
    previous = values.keys.index_with { |key| ENV[key] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end

# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/canonical_host")

# [integration] CanonicalHost against the REAL middleware stack and the REAL omniauth
# request phase.
#
# test/lib/canonical_host_test.rb proves the class decides correctly in isolation. A
# correct class that is not mounted redirects nothing, and a canonical host that the
# OAuth callback does not share is the original bug wearing a fix. These cases assert
# the wiring: that it is registered, where it sits, and — the case this task exists
# for — that a sign-in begun on an alias host hands Google the CANONICAL redirect_uri.
class CanonicalHostWiringTest < ActionDispatch::IntegrationTest
  CANONICAL = "mcritchie.studio"
  ALIAS_HOST = "www.mcritchie.studio"
  DYNO = "mcritchie-studio-039470649719.herokuapp.com"

  def stack
    Rails.application.middleware.map(&:klass)
  end

  test "CanonicalHost is mounted in the application middleware stack" do
    assert_includes stack, CanonicalHost
  end

  test "CanonicalHost runs behind EdgeGuard" do
    assert_includes stack, EdgeGuard, "the ordering is only meaningful with both mounted"

    assert stack.index(EdgeGuard) < stack.index(CanonicalHost),
           "a direct-to-origin request must be refused as a bypass, not taught the canonical name"
  end

  test "CanonicalHost runs ahead of sessions and the throttles" do
    assert stack.index(CanonicalHost) < stack.index(ActionDispatch::Session::CookieStore),
           "alias traffic should be turned around before the stack spends anything on it"
    assert stack.index(CanonicalHost) < stack.index(Rack::Attack)
  end

  # The stack as BUILT is unconfigured (no APP_HOST in the test environment), which is
  # also how it behaves on a localhost desk — so an ordinary request is unaffected.
  test "an ordinary request is untouched while no canonical host is configured" do
    get "/up"

    assert_response :success
  end

  # Drive full requests through a CONFIGURED middleware wrapped around the real
  # application, so the redirect is proven against the actual stack rather than a stub.
  test "a configured middleware redirects an alias host to the canonical host" do
    status, headers, = configured.call(rack_env_for(ALIAS_HOST, "/tasks"))

    assert_equal 301, status
    assert_equal "https://#{CANONICAL}/tasks", headers["location"]
  end

  test "a configured middleware leaves the canonical host on the app" do
    status, = configured.call(rack_env_for(CANONICAL, "/up"))

    assert_equal 200, status
  end

  test "a configured middleware still lets the platform health check through on an alias" do
    status, = configured.call(rack_env_for(ALIAS_HOST, "/up"))

    assert_equal 200, status
  end

  test "a configured middleware leaves the direct dyno host reachable" do
    status, = configured.call(rack_env_for(DYNO, "/up"))

    assert_equal 200, status
  end

  # --- The reported bug ------------------------------------------------------------
  # Operator hit Error 400: redirect_uri_mismatch signing in from a browser profile
  # sitting on www.mcritchie.studio. The request phase is a POST, which CanonicalHost
  # deliberately does not redirect, so the pinned full_host is what has to cover it.

  test "a sign-in begun on an alias host hands Google the canonical redirect_uri" do
    location = google_authorize_url_from(ALIAS_HOST, full_host: "https://#{CANONICAL}")

    assert_includes location, CGI.escape("https://#{CANONICAL}/auth/google_oauth2/callback")
  end

  # The control. Without the pin the SAME request produces the alias callback Google
  # rejects — so the assertion above is reading the fix, not a URL that was always
  # canonical.
  test "without the pin the same request produces the alias redirect_uri Google rejects" do
    location = google_authorize_url_from(ALIAS_HOST, full_host: nil)

    assert_includes location, CGI.escape("https://#{ALIAS_HOST}/auth/google_oauth2/callback")
  end

  # The two cases above set full_host BY HAND, so they prove the MECHANISM and not the
  # WIRE. Nothing else asserted that the initializer actually makes the call, and in the
  # test environment it cannot be observed: APP_HOST is unset, so the boot-time pin is a
  # no-op by definition and OmniAuth.config.full_host is legitimately nil. Deleting the
  # call was therefore green on every lane — fast cert and full CI alike — while silently
  # restoring the bug this task exists for. The middleware MOUNT is asserted above; this
  # is the OAuth half of the same claim, read from source for the same reason the
  # host_authorization case below is: the decision is made once, at boot, in an
  # environment that cannot exercise it.
  test "the omniauth initializer pins its callback through CanonicalHost" do
    source = File.read(Rails.root.join("config/initializers/omniauth.rb"))

    assert_match(/^\s*CanonicalHost\.pin_omniauth!\(OmniAuth\.config\)/, source,
                 "config/initializers/omniauth.rb must pin the callback origin, or a " \
                 "sign-in begun on an alias host goes back to deriving redirect_uri from " \
                 "the request host — which is exactly the redirect_uri_mismatch above")
  end

  # --- One exemption list, three gates ---------------------------------------------
  # /up is written out in three places that must agree. Exempt it here but not in host
  # authorization and Heroku's health check is refused; the reverse and the check
  # chases a redirect. Nothing linked them.

  test "every exempt path is honoured by all three gates" do
    assert_equal EdgeGuard::EXEMPT_PATHS.sort, CanonicalHost::EXEMPT_PATHS.sort,
                 "the two middlewares must exempt the same paths, or one refuses what the other waves through"

    host_authorization = File.read(Rails.root.join("config/environments/production.rb"))[/config\.host_authorization = .*/]
    assert host_authorization, "production.rb must still configure a host_authorization exclusion"

    CanonicalHost::EXEMPT_PATHS.each do |path|
      assert_includes host_authorization, %("#{path}"),
                      "#{path} is exempt in the middleware but not excluded from host authorization"
    end
  end

  private

  def configured
    CanonicalHost.new(Rails.application, canonical_host: CANONICAL, direct_hosts: [DYNO])
  end

  def rack_env_for(host, path)
    Rack::MockRequest.env_for("https://#{host}#{path}", "HTTPS" => "on")
  end

  # Runs the genuine omniauth request phase (test_mode short-circuits it to the mock
  # callback, which is exactly the step whose URL is under test here) and returns the
  # Google authorization URL it redirects to.
  def google_authorize_url_from(host, full_host:)
    previous_test_mode = OmniAuth.config.test_mode
    previous_full_host = OmniAuth.config.full_host
    OmniAuth.config.test_mode = false
    OmniAuth.config.full_host = full_host

    # Drive it over TLS so the pinned and unpinned cases differ only in the host.
    https!
    post "/auth/google_oauth2", headers: { "HTTP_HOST" => host }

    assert_response :redirect
    assert_match %r{\Ahttps://accounts\.google\.com/}, response.location,
                 "expected the real Google request phase, got #{response.location}"
    response.location
  ensure
    OmniAuth.config.test_mode = previous_test_mode
    OmniAuth.config.full_host = previous_full_host
  end
end

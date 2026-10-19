# frozen_string_literal: true

require "test_helper"
require_relative "../support/client_bundle_fixtures"

# [integration] The shared client-app host against the REAL middleware stack
# (docs/agents/system/client-app-host.md): <sub>.localhost (the test and
# development preview domain) is answered from the app's bundle with a strict
# CSP and no cookie, and never reaches a hub route.
class ClientAppHostWiringTest < ActionDispatch::IntegrationTest
  include ClientBundleFixtures

  def stack = Rails.application.middleware.map(&:klass)

  def preview(sub) = host!("#{sub}.localhost")

  def publish!(app, files = bundle_files) = ClientApps::Publish.new(app: app, files: files, by: "test").call

  setup { ClientApps::BundleStore.clear_cache! }

  test "[integration] the door sits after host authorization and before the canonical redirect, cookies and session" do
    door = stack.index(ClientAppHost)
    assert door, "ClientAppHost is mounted"
    assert door < stack.index(CanonicalHost)
    assert door < stack.index(ActionDispatch::Cookies)
    assert door < stack.index(ActionDispatch::Session::CookieStore)
    assert door < stack.index(ActionDispatch::Flash)
    assert door < stack.index(Rack::Attack)
  end

  test "[integration] a live bundle is served with its CSP, security headers and no Set-Cookie" do
    app = client_app_with_build_task!
    publish!(app)
    preview("pawsome")

    get "/"
    assert_response :success
    assert_equal "text/html; charset=utf-8", response.headers["content-type"]
    assert_includes response.body, "<title>Pawsome</title>"
    csp = response.headers["content-security-policy"]
    assert_includes csp, "default-src 'self'"
    assert_includes csp, "script-src 'self'"
    assert_includes csp, "frame-ancestors 'none'"
    assert_includes csp, "connect-src 'self'"
    assert_not_includes csp, "mcritchie.studio"
    assert_equal "nosniff", response.headers["x-content-type-options"]
    assert_equal "no-referrer", response.headers["referrer-policy"]
    assert_equal "no-cache", response.headers["cache-control"]
    assert_nil response.headers["set-cookie"]
    assert_empty cookies.to_hash
  end

  test "[integration] assets carry their type and cache; a missing file is a 404; a client route is the index" do
    publish!(client_app_with_build_task!)
    preview("pawsome")

    get "/assets/app-3f9a2c1b.css"
    assert_response :success
    assert_equal "text/css; charset=utf-8", response.headers["content-type"]
    assert_equal "public, max-age=31536000, immutable", response.headers["cache-control"]

    get "/app.js"
    assert_equal "text/javascript; charset=utf-8", response.headers["content-type"]
    assert_equal "public, max-age=300", response.headers["cache-control"]

    get "/about"
    assert_includes response.body, "<title>About</title>"

    get "/missing.js"
    assert_response :not_found

    get "/bookings/42"
    assert_response :success
    assert_includes response.body, "<title>Pawsome</title>"

    get "/%2e%2e/%2e%2e/etc/passwd"
    assert_response :not_found
  end

  test "[integration] hub routes never answer on a preview host" do
    publish!(client_app_with_build_task!)

    preview("pawsome")
    %w[/login /build /up /api/v1/tasks /admin /rails/active_storage/blobs/x].each do |path|
      get path
      assert_includes response.body, "<title>Pawsome</title>", "#{path} served the bundle's index, not the hub"
      assert_nil response.headers["set-cookie"], path
    end

    preview("nobody-here")
    %w[/ /login /build /up].each do |path|
      get path
      assert_response :not_found
      assert_not_includes response.body, "McRitchie"
      assert_nil response.headers["set-cookie"], path
    end

    post "/api/v1/auth", params: { secret: "x" }
    assert_response :method_not_allowed
    assert_nil response.headers["set-cookie"]
  end

  test "[integration] the hub's own host still reaches the hub (control)" do
    host! "localhost"
    get "/signin"
    assert_response :success
    assert_not_includes response.body, "data-client-app-state"
    assert_nil response.headers["content-security-policy"].to_s[/frame-src 'none'/]
  end

  test "[integration] an ETag revalidates to a 304 and HEAD has no body" do
    publish!(client_app_with_build_task!)
    preview("pawsome")

    get "/"
    etag = response.headers["etag"]
    get "/", headers: { "If-None-Match" => etag }
    assert_response :not_modified

    head "/app.js"
    assert_response :success
    assert_empty response.body
    assert_equal "text/javascript; charset=utf-8", response.headers["content-type"]
  end

  test "[integration] a client app with no bundle shows the themed being-built page" do
    client_app_with_build_task!
    preview("pawsome")

    get "/"
    assert_response :success
    assert_includes response.body, "data-client-app-state=\"being-built\""
    assert_includes response.body, "Pawsome"
    assert_includes response.body, "Nova, its CTO"
    assert_includes response.body, "--primary: #{AppPalette.rgb_triplet(ClientCtoFixtures::PALETTE['light']['primary'])}"
    assert_includes response.body, "data:image/svg+xml;base64,"
    assert_includes response.headers["content-security-policy"], "default-src 'none'"
    assert_nil response.headers["set-cookie"]
  end

  test "[integration] a held /build request with no App is being built too; its client text is escaped" do
    AppRequest.create!(prompt: "x", subdomain: "taco-map", status: "queued", cto_name: "Salsa",
                       answers: { "title" => "<script>alert(1)</script>" })
    preview("taco-map")

    get "/"
    assert_response :success
    assert_includes response.body, "&lt;script&gt;alert(1)&lt;/script&gt;"
    assert_not_includes response.body, "<script>"
  end

  test "[integration] an unknown sub, a reserved name and one of our apps are bare 404s" do
    %w[nobody-here www turf-monster].each do |sub|
      preview(sub)
      get "/"
      assert_response :not_found, sub
      assert_includes response.body, "Nothing here"
    end
  end

  test "[integration] a storage failure answers the host's own 500 and is logged, with no cookie" do
    publish!(client_app_with_build_task!)
    preview("pawsome")

    ClientApps::BundleStore.stub(:read, ->(*) { raise ClientApps::BundleStore::Corrupt, "bad bytes" }) do
      assert_difference "ErrorLog.count", 1 do
        get "/app.js"
      end
    end
    assert_response :internal_server_error
    assert_includes response.body, "data-client-app-state=\"error\""
    assert_nil response.headers["set-cookie"]
  end
end

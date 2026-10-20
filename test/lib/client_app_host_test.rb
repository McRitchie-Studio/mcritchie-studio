# frozen_string_literal: true

require "test_helper"
require Rails.root.join("lib/middleware/client_app_host")

# [unit] ClientAppHost: which hosts are the shared client-app host's, and that
# every one of them is answered without reaching the hub
# (docs/agents/system/client-app-host.md).
class ClientAppHostTest < ActiveSupport::TestCase
  HUB = ->(_env) { [ 200, { "content-type" => "text/plain" }, [ "hub" ] ] }

  test "[unit] the domain: env, production, QA and local defaults" do
    assert_equal "mcritchie.app", ClientAppHost.domain({}, production: true, qa: false)
    assert_nil ClientAppHost.domain({}, production: true, qa: true)
    assert_equal "localhost", ClientAppHost.domain({}, production: false, qa: false)
    assert_equal "preview.example", ClientAppHost.domain({ "CLIENT_APP_PREVIEW_DOMAIN" => " .Preview.Example " }, production: true, qa: true)
    assert_nil ClientAppHost.domain({ "CLIENT_APP_PREVIEW_DOMAIN" => "off" }, production: true, qa: false)
    %w[mcritchie.studio preview.qa.mcritchie.studio].each do |inside|
      assert_raises(ArgumentError) { ClientAppHost.domain({ "CLIENT_APP_PREVIEW_DOMAIN" => inside }, production: true, qa: true) }
    end
  end

  test "[unit] sub_for takes exactly one valid label under the domain" do
    assert_equal "pawsome", ClientAppHost.sub_for("pawsome.mcritchie.app", "mcritchie.app")
    assert_equal "my-app2", ClientAppHost.sub_for("my-app2.localhost", "localhost")
    assert_nil ClientAppHost.sub_for("mcritchie.app", "mcritchie.app")
    assert_nil ClientAppHost.sub_for("a.b.mcritchie.app", "mcritchie.app")
    assert_nil ClientAppHost.sub_for("-bad.mcritchie.app", "mcritchie.app")
    assert_nil ClientAppHost.sub_for("pawsome.mcritchie.studio", "mcritchie.app")
    assert_nil ClientAppHost.sub_for("evilmcritchie.app", "mcritchie.app")
  end

  test "[unit] preview_host? covers the apex and nested names, but never the hub's localhost" do
    assert ClientAppHost.preview_host?("mcritchie.app", "mcritchie.app")
    assert ClientAppHost.preview_host?("a.b.mcritchie.app", "mcritchie.app")
    assert_not ClientAppHost.preview_host?("localhost", "localhost")
    assert_not ClientAppHost.preview_host?("mcritchie.studio", "mcritchie.app")
    assert_not ClientAppHost.preview_host?("pawsome.mcritchie.app", nil)
  end

  test "[unit] a hub host passes through; a preview host never reaches the hub" do
    door = ClientAppHost.new(HUB, domain: "mcritchie.app")

    status, _, body = door.call(Rack::MockRequest.env_for("https://mcritchie.studio/login"))
    assert_equal [ 200, [ "hub" ] ], [ status, body.to_a ]

    %w[https://nobody-here.mcritchie.app/login https://mcritchie.app/ https://a.b.mcritchie.app/].each do |url|
      status, headers, body = door.call(Rack::MockRequest.env_for(url))
      assert_equal 404, status, url
      assert_not_includes body.to_a.join, "hub"
      assert_nil headers["set-cookie"]
    end
  end

  test "[unit] a hub request forging a preview host in X-Forwarded-Host or Forwarded never reaches the hub" do
    door = ClientAppHost.new(HUB, domain: "mcritchie.app")
    [ { "HTTP_X_FORWARDED_HOST" => "x.mcritchie.app" }, { "HTTP_X_FORWARDED_HOST" => "a.com, X.mcritchie.app:443" },
      { "HTTP_FORWARDED" => 'for=1.2.3.4;host="x.mcritchie.app"' },
      # Rack's own parser (what request.host believes) takes spaces around '='
      # and unescapes a quoted value; the door must read both forms the same way.
      { "HTTP_FORWARDED" => "host = x.mcritchie.app" }, { "HTTP_FORWARDED" => 'host="a\\.x.mcritchie.app"' },
      # Only Rack's unescape reads this one as a preview host.
      { "HTTP_FORWARDED" => 'host="x.mcritchie\\.app"' },
      { "HTTP_FORWARDED" => "for=1.2.3.4, host=a.com, host=X.mcritchie.app." },
      { "HTTP_X_FORWARDED_HOST" => "x.mcritchie.app." } ].each do |forged|
      status, _, body = door.call(Rack::MockRequest.env_for("https://mcritchie.studio/login", forged.merge(method: "POST")))
      assert_equal 405, status, forged.inspect
      assert_not_includes body.to_a.join, "hub"
    end
    status, = door.call(Rack::MockRequest.env_for("https://mcritchie.studio/", "HTTP_X_FORWARDED_HOST" => "mcritchie.studio"))
    assert_equal 200, status
  end

  test "[unit] the forwarded hosts include Rack's parse of Forwarded, unescaped" do
    assert_includes ClientAppHost.forwarded_hosts("HTTP_FORWARDED" => "host = x.mcritchie.app"), "x.mcritchie.app"
    assert_includes ClientAppHost.forwarded_hosts("HTTP_FORWARDED" => 'host="a\\.x.mcritchie.app"'), "a.x.mcritchie.app"
    # Rack answers nil for a header it cannot parse; the scan still reads it.
    assert_nil Rack::Utils.forwarded_values("host=x.mcritchie.app;;==")
    assert_includes ClientAppHost.forwarded_hosts("HTTP_FORWARDED" => "host=x.mcritchie.app;;=="), "x.mcritchie.app"
    assert_empty ClientAppHost.forwarded_hosts({})
  end

  test "[unit] a trailing dot on the Host header is the same preview host" do
    door = ClientAppHost.new(HUB, domain: "mcritchie.app")
    status, _, body = door.call(Rack::MockRequest.env_for("https://nobody-here.mcritchie.app./"))
    assert_equal 404, status
    assert_not_includes body.to_a.join, "hub"
    assert_equal "pawsome.mcritchie.app", ClientAppHost.request_host("HTTP_HOST" => "Pawsome.mcritchie.app.:443")
  end

  test "[unit] the domain guard strips a trailing dot and refuses any domain at, under or above a production host" do
    env = ->(value) { { "CLIENT_APP_PREVIEW_DOMAIN" => value } }
    assert_equal "preview.example", ClientAppHost.domain(env.call("preview.example."), production: true, qa: false)
    %w[studio mcritchie.studio. x.turfmonster.media turfmonster.media media qa.turfmonster.media. llc
       cyvasse.xyz herokuapp.com com a.karenmcritchie.com].each do |value|
      error = assert_raises(ArgumentError, value) { ClientAppHost.domain(env.call(value), production: true, qa: false) }
      assert_match(/production host|hub session cookie/, error.message, value)
    end
    # The hosts come from both registries: apps.yml's and satellites.yml's.
    hosts = ClientAppHost.production_hosts
    assert_includes hosts, "mcritchie.studio"
    assert_includes hosts, "turfmonster.media"
    assert_includes hosts, "qa.mcritchie.industries"
    assert_includes hosts, "cyvasse.mcritchie.studio" # satellites.yml only
    assert_nil ClientAppHost.clashing_host("mcritchie.app")
  end

  test "[unit] the domain guard refuses a dotless value, a public suffix on its own, unless it is localhost" do
    env = ->(value) { { "CLIENT_APP_PREVIEW_DOMAIN" => value } }
    %w[app .app app. APP preview].each do |value|
      error = assert_raises(ArgumentError, value) { ClientAppHost.domain(env.call(value), production: true, qa: false) }
      assert_match(/one label|registrable domain/, error.message, value)
    end
    assert_equal "localhost", ClientAppHost.domain(env.call("localhost"), production: true, qa: false)
    assert_equal "localhost", ClientAppHost.domain(env.call(".localhost."), production: false, qa: false)
    assert_equal "mcritchie.app", ClientAppHost.domain(env.call("mcritchie.app"), production: true, qa: false)
  end

  test "[unit] the launcher's preview domain (config/client_builds.yml) is the production default and clears the guard" do
    assert_equal ClientAppHost::PRODUCTION_DOMAIN, ClientBuilds.preview_domain
    assert_nil ClientAppHost.clashing_host(ClientBuilds.preview_domain)
    assert_equal ClientAppHost.url_for("pawsome", domain: ClientAppHost::PRODUCTION_DOMAIN, production: true),
                 ClientBuilds.preview_url("pawsome")
  end

  test "[unit] the host is off when the domain is nil" do
    door = ClientAppHost.new(HUB, domain: nil)
    status, = door.call(Rack::MockRequest.env_for("https://pawsome.mcritchie.app/"))
    assert_equal 200, status
  end

  test "[unit] url_for: https in production, the desk's port locally" do
    assert_equal "https://pawsome.mcritchie.app", ClientAppHost.url_for("pawsome", domain: "mcritchie.app", production: true)
    assert_equal "http://pawsome.localhost:3038",
                 ClientAppHost.url_for("pawsome", domain: "localhost", env: { "APP_PORT" => "3038" }, production: false)
  end
end
